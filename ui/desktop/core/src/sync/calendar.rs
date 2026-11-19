//! Calendar sync — a parallel adapter stack to the mail `ProviderAdapter`.
//!
//! Ported from the JS `google-calendar-sync.js` / `microsoft-calendar-sync.js`.
//! Google uses `nextSyncToken`; Microsoft uses an `@odata.deltaLink`. Both are
//! stored opaquely in `calendars.sync_token`. The engine drives these on the
//! same 60s poll tick as mail.

use std::collections::HashSet;
use std::sync::Arc;

use async_trait::async_trait;
use serde_json::Value;

use crate::sync::adapters::util::http_status_error;
use crate::sync::error::{Result, SyncError};
use crate::sync::oauth::TokenManager;
use crate::sync::util::{json_str, urlencode};

const GCAL_API: &str = "https://www.googleapis.com/calendar/v3";
const GRAPH_API: &str = "https://graph.microsoft.com/v1.0";

/// Persisted `calendars.source` discriminators, named per the "no duplicated
/// enums" rule. NOTE: these deliberately do NOT match the mail-side
/// [`crate::sync::model::ProviderType`] strings (`"gmail"`/`"microsoft"`).
/// `source` is written to `calendars.source` and matched on by
/// `SyncStore::prune_calendars` (`WHERE source = ?`). The historical values are
/// `"google"`/`"microsoft"`; renaming `"google"` → `"gmail"` would orphan every
/// existing calendar row (prune would no longer match it), so the value is kept
/// as-is and only promoted to a constant. (The string is never read by any
/// frontend, so the divergence from ProviderType is invisible outside this DB.)
pub(crate) mod source {
    pub const GOOGLE: &str = "google";
    pub const MICROSOFT: &str = "microsoft";
}

/// The video meetings a calendar's own provider can mint for an event on it,
/// as stored in `calendars.conference_providers` and read by the clients'
/// "Video call" picker. Same two slugs the Rails side uses
/// (`MeetLink::CONFERENCE_MEET` / `_TEAMS`), so one vocabulary spans both.
pub(crate) mod conference {
    pub const MEET: &str = "meet";
    pub const TEAMS: &str = "teams";
    /// Google `conferenceProperties.allowedConferenceSolutionTypes` entry for
    /// Meet. The other two (`eventHangout`, `eventNamedHangout`) are the retired
    /// classic Hangouts and cannot be created any more.
    pub const GOOGLE_MEET_SOLUTION: &str = "hangoutsMeet";
    /// Graph `allowedOnlineMeetingProviders` entry for Teams. The Skype ones are
    /// not something we create.
    pub const MS_TEAMS_PROVIDER: &str = "teamsForBusiness";
}
const MS_EVENT_SELECT: &str = "id,subject,body,start,end,location,isAllDay,\
organizer,attendees,iCalUId,recurrence,seriesMasterId,showAs,sensitivity,webLink,lastModifiedDateTime,\
isOnlineMeeting,onlineMeetingProvider,onlineMeeting,onlineMeetingUrl";

#[derive(Debug, Clone)]
pub struct UnifiedCalendar {
    pub key: String,
    pub provider_id: String,
    pub name: String,
    pub color: String,
    pub is_primary: bool,
    /// The user can create/edit/delete events here — Google `accessRole` is
    /// owner/writer, or Microsoft `canEdit`. Read-only calendars (shared, subscribed,
    /// holidays) are `false`, so the clients hide event Edit/Delete (provider 403s).
    pub is_writable: bool,
    /// This account owns the calendar, rather than having been given write
    /// access to someone else's (Google `accessRole: owner`, Graph `canShare` —
    /// only an owner may share). A calendar you can write but do not own is a
    /// poor place to create your own meetings, so the clients keep those out of
    /// the "which calendar?" picker while still showing their events.
    pub is_owned: bool,
    /// Video meetings this calendar can mint (`conference::MEET` / `TEAMS`).
    /// Empty is a real answer — a mailbox without Teams, a calendar with
    /// conferencing switched off — and the clients then offer no video call
    /// rather than letting the create 400 on a provider it doesn't have.
    pub conference_providers: Vec<String>,
}

#[derive(Debug, Clone, Default)]
pub struct UnifiedEvent {
    pub provider_id: String,
    pub title: String,
    pub description: Option<String>,
    pub location: Option<String>,
    pub start_at: String,
    pub end_at: String,
    pub all_day: bool,
    pub timezone: String,
    pub status: String,
    pub etag: Option<String>,
    pub ical_uid: Option<String>,
    pub recurrence_rule: Option<String>,
    pub organizer_email: Option<String>,
    pub organizer_name: Option<String>,
    /// JSON blob (attendees + provider web link), stored in calendar_events.metadata.
    pub metadata: Option<String>,
}

#[derive(Debug, Clone, Default)]
pub struct CalendarCursor {
    pub token: Option<String>,
}

/// User-supplied fields for creating or updating an event. Times are RFC3339
/// in `timezone`'s own offset at that moment (`2026-10-26T14:00:00+01:00`; the
/// web, iOS and Android all write them so) or a bare wall clock in `timezone`,
/// for timed events, and `YYYY-MM-DD` when `all_day`. Graph needs the wall
/// clock, so a UTC instant labelled with another zone would land off by the
/// offset there.
#[derive(Debug, Clone, Default, serde::Deserialize)]
pub struct EventDraft {
    pub title: String,
    #[serde(default)]
    pub description: Option<String>,
    #[serde(default)]
    pub location: Option<String>,
    pub start_at: String,
    pub end_at: String,
    #[serde(default)]
    pub all_day: bool,
    #[serde(default)]
    pub timezone: Option<String>,
    /// Attendee email addresses. Empty means "no change" on an update — the
    /// providers' bodies leave the list out — so a sheet that didn't load the
    /// guests can't wipe them; `attendees_cleared` is the explicit "remove
    /// everyone". Clients send the list only when it changed, and a changed
    /// list is merged with the event's own entries so kept guests keep their
    /// RSVPs (`merged_attendees`).
    #[serde(default)]
    pub attendees: Vec<String>,
    #[serde(default)]
    pub attendees_cleared: bool,
    /// Ask the provider to attach its own video meeting: Google Meet on Google,
    /// Teams on Microsoft. Only meaningful on create — the providers mint the
    /// link once and the next sync brings it back in `metadata.conference`.
    #[serde(default)]
    pub conference: bool,
    /// Repeat rule as an RRULE body (`FREQ=WEEKLY;BYDAY=MO,WE;COUNT=2`, no
    /// `RRULE:` prefix). Google takes it as is; Graph gets it translated into
    /// its pattern + range by `ms_recurrence`. On a series edit it is the rule
    /// the series should have afterwards; None there means "no longer repeats".
    #[serde(default)]
    pub recurrence: Option<String>,
    /// Update only — which part of a series the edit is for: `this` (the
    /// default: the one instance), `following` (this instance onwards, split
    /// off as a new series) or `all` (the series itself).
    #[serde(default)]
    pub scope: Option<String>,
    /// `description` is HTML, not text — set by the engine when it copies a
    /// Graph series' own body onto a split-off half; never from a client.
    #[serde(skip)]
    pub description_is_html: bool,
    /// Google `recurrence` lines besides the RRULE (EXDATE/RDATE) — set by the
    /// engine when a split-off half keeps the old series' slots, so dates the
    /// old series excluded stay excluded; never from a client.
    #[serde(skip)]
    pub extra_recurrence: Vec<String>,
}

impl EventDraft {
    fn tz(&self) -> String {
        self.timezone.clone().unwrap_or_else(|| "UTC".to_string())
    }
}

/// A drag-to-reschedule: new times for one event, or for its whole series.
/// Only the times are sent — a full `EventDraft` PATCH would rewrite the guest
/// list and wipe everyone's RSVP.
#[derive(Debug, Clone, Default, serde::Deserialize)]
pub struct Reschedule {
    /// The instance's new times: RFC3339, or `YYYY-MM-DD` when `all_day`.
    pub start_at: String,
    pub end_at: String,
    #[serde(default)]
    pub all_day: bool,
    #[serde(default)]
    pub timezone: Option<String>,
    /// Set to move the whole series: the provider id of its master event.
    #[serde(default)]
    pub series_id: Option<String>,
    /// How far the instance's start moved. Applied to the master's own start,
    /// so the series keeps its wall-clock time in the master's zone.
    #[serde(default)]
    pub shift_seconds: i64,
    /// Mail guests the change. Google only — Graph always notifies them.
    #[serde(default)]
    pub notify: bool,
}

impl Reschedule {
    fn tz(&self) -> String {
        self.timezone.clone().unwrap_or_else(|| "UTC".to_string())
    }

    /// The instance's new length; the series takes the same.
    fn duration(&self) -> chrono::Duration {
        span(&self.start_at, &self.end_at)
    }
}

/// Seconds since the epoch of a time as the clients and the store write them:
/// RFC3339, a bare wall clock (Graph rows, read as UTC — which is how Graph
/// hands them back), or a `YYYY-MM-DD` date (midnight UTC).
pub(crate) fn instant(s: &str) -> Option<i64> {
    chrono::DateTime::parse_from_rfc3339(s).map(|t| t.timestamp()).ok()
        .or_else(|| {
            chrono::NaiveDateTime::parse_from_str(s, "%Y-%m-%dT%H:%M:%S%.f")
                .ok()
                .map(|t| t.and_utc().timestamp())
        })
        .or_else(|| {
            chrono::NaiveDate::parse_from_str(s.get(..10)?, "%Y-%m-%d")
                .ok()
                .map(|d| d.and_hms_opt(0, 0, 0).unwrap().and_utc().timestamp())
        })
}

fn span(start: &str, end: &str) -> chrono::Duration {
    chrono::Duration::seconds(instant(end).unwrap_or(0) - instant(start).unwrap_or(0))
}

/// A series master as the series edits read it: the provider's own JSON (its
/// `start`/`end` in the series' zone, Google's full `recurrence` lines) and its
/// rule as an RRULE body — None when the provider reports none.
#[derive(Debug, Clone)]
pub struct SeriesMaster {
    pub raw: Value,
    pub rule: Option<String>,
    /// Guest addresses (not the organizer) and notes, so a split-off "this and
    /// following" series keeps them when the editor sent none (the mobile sheets
    /// have no notes field and iOS opens with no guest list).
    pub attendees: Vec<String>,
    pub description: Option<String>,
    /// `description` is HTML (Graph's body usually is).
    pub description_is_html: bool,
}

/// A series PATCH's attendee list for the guests the editor wants, reusing the
/// master's own entries (RSVP and all) for everyone still on it: a list of
/// bare addresses would reset every reply. None when the list is unchanged —
/// the PATCH then leaves attendees out entirely.
fn merged_attendees(existing: Option<&Value>, wanted: &[String], email: fn(&Value) -> Option<String>, fresh: fn(&str) -> Value) -> Option<Value> {
    let existing: Vec<&Value> = existing.and_then(|a| a.as_array()).map(|a| a.iter().collect()).unwrap_or_default();
    let key = |e: &str| e.trim().to_ascii_lowercase();
    let have: Vec<String> = existing.iter().filter_map(|a| email(a)).map(|e| key(&e)).collect();
    let want: Vec<String> = wanted.iter().map(|e| key(e)).collect();
    // The organizer is on the master's list but never in the editor's.
    if want.iter().all(|w| have.contains(w)) && existing.iter().all(|a| {
        email(a).is_none_or(|e| want.contains(&key(&e)))
            || a.get("organizer").and_then(|o| o.as_bool()).unwrap_or(false)
    }) {
        return None;
    }
    let mut out: Vec<Value> = existing
        .iter()
        .filter(|a| {
            a.get("organizer").and_then(|o| o.as_bool()).unwrap_or(false)
                || email(a).is_some_and(|e| want.contains(&key(&e)))
        })
        .map(|a| (*a).clone())
        .collect();
    out.extend(wanted.iter().filter(|w| !have.contains(&key(w))).map(|w| fresh(w)));
    Some(Value::Array(out))
}

/// Where a "this and following" split falls: the PATCH body that ends the old
/// series, and the split instance's ORIGINAL slot (RFC3339 or a date) — an
/// occurrence that was moved still belongs to the slot it was generated for.
#[derive(Debug, Clone)]
pub struct SeriesEnd {
    pub body: Value,
    pub cutoff: String,
    /// Occurrences of the old series before the cutoff — deleted ones too,
    /// since they used up their place in a COUNT. Only read for a COUNT rule.
    pub done: usize,
}

/// A Google instance's original slot (its place in the series), as an instant.
fn original_slot(item: &Value) -> Option<i64> {
    item.get("originalStartTime")
        .or_else(|| item.get("start"))
        .and_then(|s| json_str(s, "dateTime").or_else(|| json_str(s, "date")))
        .and_then(|s| instant(&s))
}

/// How many days from `start` up to (not including) `cutoff` a Graph
/// `recurrencePattern` generates — what a split-off half's COUNT must
/// subtract (deleted occurrences included: they used up their place).
fn graph_count_before(pattern: &Value, start: chrono::NaiveDate, cutoff: chrono::NaiveDate) -> usize {
    let mut n = 0;
    graph_pattern_days(pattern, start, |d| {
        if d >= cutoff {
            return false;
        }
        n += 1;
        true
    });
    n
}

/// The day of a Graph pattern's `count`-th occurrence from `start` — where a
/// numbered series really ends, deleted tail occurrences included.
fn graph_nth_day(pattern: &Value, start: chrono::NaiveDate, count: u64) -> Option<chrono::NaiveDate> {
    let mut seen = 0;
    let mut last = None;
    graph_pattern_days(pattern, start, |d| {
        seen += 1;
        last = Some(d);
        seen < count
    });
    last.filter(|_| seen == count)
}

/// Walk the days a Graph `recurrencePattern` generates from `start`, in
/// order, while `visit` says go on. Day by day: Graph patterns are date-based
/// (the time of day is the event's own); capped at a century.
fn graph_pattern_days(pattern: &Value, start: chrono::NaiveDate, mut visit: impl FnMut(chrono::NaiveDate) -> bool) {
    use chrono::Datelike;
    let interval = pattern.get("interval").and_then(|v| v.as_u64()).unwrap_or(1).max(1) as i64;
    let days: Vec<u32> = pattern
        .get("daysOfWeek")
        .and_then(|d| d.as_array())
        .map(|a| {
            a.iter()
                .filter_map(|d| d.as_str())
                .filter_map(|n| RRULE_DAYS.iter().position(|(_, name)| n.eq_ignore_ascii_case(name)).map(|i| i as u32))
                .collect()
        })
        .unwrap_or_default();
    let num = |k: &str| pattern.get(k).and_then(|v| v.as_u64()).map(|v| v as u32);
    // Graph's week starts on Sunday unless the pattern says otherwise.
    let first_dow = json_str(pattern, "firstDayOfWeek")
        .and_then(|n| RRULE_DAYS.iter().position(|(_, name)| n.eq_ignore_ascii_case(name)))
        .unwrap_or(6) as i64;
    // Which of the month's matching days a relative pattern takes: 1-4, or -1 (last).
    let index = match json_str(pattern, "index").as_deref() {
        Some("second") => 2,
        Some("third") => 3,
        Some("fourth") => 4,
        Some("last") => -1,
        _ => 1,
    };
    let months = |d: chrono::NaiveDate| (d.year() - start.year()) as i64 * 12 + d.month() as i64 - start.month() as i64;
    let years = |d: chrono::NaiveDate| (d.year() - start.year()) as i64;
    let week_start = |d: chrono::NaiveDate| {
        d - chrono::Duration::days((d.weekday().num_days_from_monday() as i64 - first_dow).rem_euclid(7))
    };
    let on_weekday = |d: chrono::NaiveDate| days.contains(&d.weekday().num_days_from_monday());
    let kind = json_str(pattern, "type").unwrap_or_default();
    let limit = start + chrono::Duration::days(36_525);
    // Relative patterns make ONE occurrence per period: the index-th (or the
    // last) day of the month whose weekday is any of `daysOfWeek` — not one
    // per weekday. So they step month by month and pick it.
    if kind == "relativeMonthly" || kind == "relativeYearly" {
        let yearly = kind == "relativeYearly";
        let mut month = chrono::NaiveDate::from_ymd_opt(start.year(), start.month(), 1).unwrap();
        while month < limit {
            let wanted_month = !yearly || num("month") == Some(month.month());
            let in_step = if yearly { years(month) % interval == 0 } else { months(month) % interval == 0 };
            if wanted_month && in_step {
                let hits: Vec<chrono::NaiveDate> = month
                    .iter_days()
                    .take_while(|d| d.month() == month.month())
                    .filter(|d| on_weekday(*d))
                    .collect();
                let pick = if index == -1 { hits.last() } else { hits.get(index as usize - 1) };
                if let Some(&d) = pick {
                    if d >= start && !visit(d) {
                        return;
                    }
                }
            }
            month = month.checked_add_months(chrono::Months::new(1)).unwrap();
        }
        return;
    }
    let mut d = start;
    while d < limit {
        let hit = match kind.as_str() {
            "daily" => (d - start).num_days() % interval == 0,
            "weekly" => on_weekday(d) && ((week_start(d) - week_start(start)).num_days() / 7) % interval == 0,
            "absoluteMonthly" => num("dayOfMonth") == Some(d.day()) && months(d) % interval == 0,

            "absoluteYearly" => num("month") == Some(d.month()) && num("dayOfMonth") == Some(d.day()) && years(d) % interval == 0,
            _ => return,
        };
        if hit && !visit(d) {
            return;
        }
        d += chrono::Duration::days(1);
    }
}

/// The instant a calendar day ends (midnight after it) in a named zone, or in
/// UTC for a zone neither table knows.
fn end_of_day(day: chrono::NaiveDate, zone: &str) -> i64 {
    use chrono::TimeZone;
    let next = (day + chrono::Duration::days(1)).and_hms_opt(0, 0, 0).unwrap();
    named_zone(zone)
        .and_then(|tz| tz.from_local_datetime(&next).earliest())
        .map(|t| t.timestamp())
        .unwrap_or_else(|| next.and_utc().timestamp())
}

/// The parts of an RRULE body, upper-cased keys, `RRULE:` prefix dropped.
fn rrule_parts(rule: &str) -> Vec<(String, String)> {
    rule.trim()
        .trim_start_matches("RRULE:")
        .split(';')
        .filter_map(|p| p.split_once('='))
        .map(|(k, v)| (k.trim().to_ascii_uppercase(), v.trim().to_string()))
        .collect()
}

/// `rule` ending just before an instance: its COUNT/UNTIL replaced by an UNTIL
/// one second before `cutoff` (UTC), or the day before for an all-day series —
/// RFC 5545 wants a DATE UNTIL when DTSTART is a DATE.
/// A named zone, IANA or Windows (Graph, Outlook), as chrono-tz knows it.
fn named_zone(name: &str) -> Option<chrono_tz::Tz> {
    crate::sync::ics::windows_to_iana(name).unwrap_or(name).parse().ok()
}

/// Google's EXDATE/RDATE lines split at a series cutoff: the dates before it
/// stay with the old half, the rest go to the new one, so no extra or
/// excluded date ends up on both (or neither). A line's values may be a
/// comma list, UTC (`…Z`), in a `TZID`, floating (read in `series_zone`), or
/// a `VALUE=DATE`. A value that can't be read stays with both halves.
fn split_date_lines(lines: &[String], cutoff: i64, series_zone: &str) -> (Vec<String>, Vec<String>) {
    let mut before = Vec::new();
    let mut after = Vec::new();
    for line in lines {
        let Some((head, values)) = line.rsplit_once(':') else { continue };
        let zone = head.split(';').find_map(|p| p.strip_prefix("TZID=")).unwrap_or(series_zone);
        let at = |v: &str| -> Option<i64> {
            let v = v.trim();
            if v.len() == 8 {
                return chrono::NaiveDate::parse_from_str(v, "%Y%m%d").ok().map(|d| d.and_hms_opt(0, 0, 0).unwrap().and_utc().timestamp());
            }
            let wall = chrono::NaiveDateTime::parse_from_str(v.trim_end_matches('Z'), "%Y%m%dT%H%M%S").ok()?;
            if v.ends_with('Z') {
                return Some(wall.and_utc().timestamp());
            }
            use chrono::TimeZone;
            named_zone(zone).and_then(|tz| tz.from_local_datetime(&wall).earliest()).map(|t| t.timestamp())
        };
        let (mut old, mut new) = (Vec::new(), Vec::new());
        for v in values.split(',') {
            match at(v) {
                Some(t) if t < cutoff => old.push(v),
                Some(_) => new.push(v),
                None => {
                    old.push(v);
                    new.push(v);
                }
            }
        }
        if !old.is_empty() {
            before.push(format!("{head}:{}", old.join(",")));
        }
        if !new.is_empty() {
            after.push(format!("{head}:{}", new.join(",")));
        }
    }
    (before, after)
}

fn rrule_until(rule: &str, cutoff: i64, all_day: bool) -> Option<String> {
    let until = if all_day {
        (chrono::DateTime::from_timestamp(cutoff, 0)?.date_naive() - chrono::Duration::days(1))
            .format("%Y%m%d")
            .to_string()
    } else {
        chrono::DateTime::from_timestamp(cutoff - 1, 0)?.format("%Y%m%dT%H%M%SZ").to_string()
    };
    let mut parts: Vec<String> = rrule_parts(rule)
        .into_iter()
        .filter(|(k, _)| k != "COUNT" && k != "UNTIL")
        .map(|(k, v)| format!("{k}={v}"))
        .collect();
    parts.push(format!("UNTIL={until}"));
    Some(parts.join(";"))
}

/// Move a provider `{dateTime|date, timeZone}` by `by`, keeping its zone and
/// form: Google's offset-carrying `dateTime`, Graph's bare one, or a `date`.
fn shift_when(when: &Value, by: chrono::Duration) -> Option<Value> {
    let mut out = when.clone();
    if let Some(d) = json_str(when, "date") {
        let d = chrono::NaiveDate::parse_from_str(&d, "%Y-%m-%d").ok()? + by;
        out["date"] = Value::String(d.format("%Y-%m-%d").to_string());
        return Some(out);
    }
    let s = json_str(when, "dateTime")?;
    let shifted = match chrono::DateTime::parse_from_rfc3339(&s) {
        Ok(t) => (t + by).to_rfc3339(),
        Err(_) => (chrono::NaiveDateTime::parse_from_str(&s, "%Y-%m-%dT%H:%M:%S%.f").ok()? + by)
            .format("%Y-%m-%dT%H:%M:%S")
            .to_string(),
    };
    out["dateTime"] = Value::String(shifted);
    Some(out)
}

/// The series master's `{start, end}` moved by the reschedule: start shifted,
/// end at start plus the instance's new length.
fn shifted_series_times(master: &Value, r: &Reschedule) -> Result<(Value, Value)> {
    let start = master.get("start").ok_or_else(|| SyncError::Other("series master has no start".into()))?;
    let shift = chrono::Duration::seconds(r.shift_seconds);
    let new_start = shift_when(start, shift);
    let new_end = shift_when(start, shift + r.duration());
    new_start
        .zip(new_end)
        .ok_or_else(|| SyncError::Other("series master time is unreadable".into()))
}

#[derive(Debug, Clone, Default)]
pub struct CalendarSyncResult {
    pub upserts: Vec<UnifiedEvent>,
    pub deletions: Vec<String>,
    /// Set of provider ids seen during a FULL sync, for orphan pruning. `None`
    /// for incremental delta syncs (which carry deletions explicitly).
    pub seen_provider_ids: Option<HashSet<String>>,
    pub next_token: Option<String>,
}

#[async_trait]
pub trait CalendarAdapter: Send + Sync {
    fn source(&self) -> &'static str;
    async fn list_calendars(&self) -> Result<Vec<UnifiedCalendar>>;
    /// Full sync when `cursor.token` is None, otherwise incremental. Drains all
    /// pages internally. Returns `CursorExpired` when the token is stale.
    async fn sync_calendar(&self, cal: &UnifiedCalendar, cursor: &CalendarCursor)
        -> Result<CalendarSyncResult>;

    /// Create an event in `calendar_provider_id`; returns the new provider id.
    async fn create_event(&self, calendar_provider_id: &str, draft: &EventDraft) -> Result<String>;

    /// Add an event that came from an iCalendar file, keeping its original `UID`.
    ///
    /// Plain `create_event` lets the provider mint a fresh iCalUID, which breaks the
    /// only handle we have on "is this emailed event already on the calendar?" — so
    /// the banner would offer to add it forever and a second tap would duplicate it.
    /// Google has a dedicated import call that preserves the UID (and is idempotent
    /// on it); the default here is a plain create, for providers that don't.
    async fn import_event(
        &self,
        calendar_provider_id: &str,
        draft: &EventDraft,
        _ical_uid: &str,
    ) -> Result<String> {
        self.create_event(calendar_provider_id, draft).await
    }
    /// Update an existing event.
    async fn update_event(
        &self,
        calendar_provider_id: &str,
        event_provider_id: &str,
        draft: &EventDraft,
    ) -> Result<()>;
    /// Move an event, or its whole series when `r.series_id` is set — times only.
    async fn reschedule_event(
        &self,
        calendar_provider_id: &str,
        event_provider_id: &str,
        r: &Reschedule,
    ) -> Result<()>;
    /// Delete an event.
    async fn delete_event(&self, calendar_provider_id: &str, event_provider_id: &str) -> Result<()>;
    /// RSVP to an event: `response` is `accepted` | `declined` | `tentative`.
    async fn respond_event(
        &self,
        calendar_provider_id: &str,
        event_provider_id: &str,
        response: &str,
    ) -> Result<()>;
    /// Every event (recurrences expanded) overlapping `[time_min, time_max)`, live
    /// from the provider. For ranges outside the synced `time_window`.
    async fn list_events(&self, cal: &UnifiedCalendar, time_min: &str, time_max: &str)
        -> Result<Vec<UnifiedEvent>>;

    /// Read a series master: synced rows are expanded instances, so the rule
    /// only lives on the provider.
    async fn get_series(&self, calendar_provider_id: &str, master_id: &str) -> Result<SeriesMaster>;
    /// Edit the whole series from an edited instance: the draft's fields and
    /// rule, with the master's own start moved by `shift` (how far the instance
    /// moved) so earlier occurrences stay where they were.
    async fn update_series(
        &self,
        calendar_provider_id: &str,
        master_id: &str,
        master: &SeriesMaster,
        draft: &EventDraft,
        shift: chrono::Duration,
    ) -> Result<()>;
    /// The PATCH body that ends the series just before one of its instances
    /// (`instance_id`, which started at `instance_start`), without sending it.
    /// None when that instance is the first — nothing would be left, and "this
    /// and following" is then the whole series.
    async fn ended_recurrence(
        &self,
        calendar_provider_id: &str,
        master: &SeriesMaster,
        instance_id: &str,
        instance_start: &str,
    ) -> Result<Option<SeriesEnd>>;
    /// Copy the old series' moved, retitled or cancelled occurrences from
    /// `cutoff` on onto the new series, whose slots are the same. Before the
    /// old half is ended, so a failure leaves nothing lost.
    async fn carry_exceptions(
        &self,
        calendar_provider_id: &str,
        old_master_id: &str,
        new_master_id: &str,
        master: &SeriesMaster,
        cutoff: &str,
    ) -> Result<()>;
    /// PATCH a series master with a body built by `ended_recurrence`.
    async fn patch_series(&self, calendar_provider_id: &str, master_id: &str, body: &Value) -> Result<()>;
}

/// A series edit from one of its instances: `all` PATCHes the master, moved by
/// how far the instance moved; `following` ends the series before the instance
/// and creates the rest as a new series; "all → does not repeat" replaces the
/// series with a one-off. Nothing is taken away before its replacement exists.
pub(crate) async fn apply_series_edit(
    adapter: &dyn CalendarAdapter,
    calendar_provider_id: &str,
    series_id: &str,
    event_provider_id: &str,
    instance_start: &str,
    scope: &str,
    draft: &EventDraft,
) -> Result<()> {
    let master = adapter.get_series(calendar_provider_id, series_id).await?;
    // A split-off or replacement series is a new event: it keeps the
    // meeting's guests and notes when the editor sent none (the mobile
    // sheets have no notes field; iOS opens an edit with no guest list).
    let mut fresh = draft.clone();
    if fresh.attendees.is_empty() && !fresh.attendees_cleared {
        fresh.attendees = master.attendees.clone();
    }
    if fresh.description.is_none() {
        fresh.description = master.description.clone();
        fresh.description_is_html = master.description_is_html;
    }
    let ended = if scope == "following" {
        adapter.ended_recurrence(calendar_provider_id, &master, event_provider_id, instance_start).await?
    } else {
        None
    };
    if let Some(SeriesEnd { body: ending, cutoff, done }) = ended {
        // Same rule and the split instance still on its own slot: the new
        // series' slots are the old ones, so its exceptions can follow.
        // The cadence, not its end: a new COUNT or UNTIL keeps the slots that
        // remain (an exception past the new end finds no slot and stays out).
        let same = |r: &str| {
            let mut p = rrule_parts(r);
            p.retain(|(k, _)| k != "COUNT" && k != "UNTIL");
            p.sort();
            p
        };
        let slots_align = fresh.recurrence.as_deref().zip(master.rule.as_deref()).is_some_and(|(a, b)| same(a) == same(b))
            && instant(&fresh.start_at) == instant(&cutoff);
        // The new half first: if it's refused, nothing has been taken
        // away yet. If ending the old half then fails, take the new one
        // back so the calendar isn't left with both.
        // An unchanged COUNT counts what's left, not the whole series again.
        let count = |r: &str| rrule_parts(r).into_iter().find(|(k, _)| k == "COUNT").and_then(|(_, v)| v.parse::<u32>().ok());
        if let (Some(rule), Some(total)) = (fresh.recurrence.clone(), master.rule.as_deref().and_then(count)) {
            if count(&rule) == Some(total) {
                let left = total.saturating_sub(done as u32).max(1);
                let parts: Vec<String> = rrule_parts(&rule)
                    .into_iter()
                    .map(|(k, v)| if k == "COUNT" { format!("COUNT={left}") } else { format!("{k}={v}") })
                    .collect();
                fresh.recurrence = Some(parts.join(";"));
            }
        }
        if slots_align {
            // Google's EXDATE/RDATE lines (Graph keeps none in this form).
            let dates: Vec<String> =
                string_list(master.raw.get("recurrence")).into_iter().filter(|l| !l.starts_with("RRULE:")).collect();
            let zone = master.raw.get("start").and_then(|s| json_str(s, "timeZone")).unwrap_or_else(|| "UTC".into());
            let carried = split_date_lines(&dates, instant(&cutoff).unwrap_or(0), &zone).1;
            // An RDATE makes an occurrence of its own, past the rule's end too:
            // when the edit sets a new UNTIL or COUNT, only those up to that
            // end come along (EXDATEs past it are harmless). A DATE UNTIL
            // means through that whole day.
            // A DATE UNTIL ends with its day in the series' zone (an all-day
            // series' DATE RDATEs are read as UTC midnights, so it ends in UTC
            // for them).
            let all_day_series = master.raw.get("start").and_then(|s| s.get("date")).is_some();
            let until = fresh.recurrence.as_deref().and_then(|r| {
                let u = rrule_parts(r).into_iter().find(|(k, _)| k == "UNTIL")?.1;
                let t = if u.len() == 8 {
                    let day = chrono::NaiveDate::parse_from_str(&u, "%Y%m%d").ok()?;
                    end_of_day(day, if all_day_series { "UTC" } else { &zone })
                } else {
                    chrono::NaiveDateTime::parse_from_str(u.trim_end_matches('Z'), "%Y%m%dT%H%M%S").ok()?.and_utc().timestamp() + 1
                };
                Some(t)
            });
            // A COUNT ends on its counted day: read the rule as a Graph pattern
            // (the editors' rules all fit one) and walk it. A rule that doesn't
            // fit keeps its RDATEs, as the RFC has them.
            let counted = || {
                let r = fresh.recurrence.as_deref()?;
                let count: u64 = rrule_parts(r).into_iter().find(|(k, _)| k == "COUNT")?.1.parse().ok()?;
                let start = ms_when(&fresh.start_at, fresh.all_day, &fresh.tz());
                let pattern = ms_recurrence(r, &start, draft_offset(&fresh))?.get("pattern")?.clone();
                let first = chrono::NaiveDate::parse_from_str(json_str(&start, "dateTime")?.get(..10)?, "%Y-%m-%d").ok()?;
                let last = graph_nth_day(&pattern, first, count)?;
                Some(end_of_day(last, if all_day_series { "UTC" } else { &zone }))
            };
            // Only when the edit moved the end: an RDATE is an occurrence of
            // its own (the recurrence is RRULE ∪ RDATE), so a title-only split
            // keeps every one. The editor's rule as given — before its COUNT
            // was cut to what's left — against the old series' own.
            let end_of = |r: Option<&str>| {
                let mut p: Vec<(String, String)> =
                    r.map(rrule_parts).unwrap_or_default().into_iter().filter(|(k, _)| k == "COUNT" || k == "UNTIL").collect();
                p.sort();
                p
            };
            let end_moved = end_of(draft.recurrence.as_deref()) != end_of(master.rule.as_deref());
            let until = if end_moved { until.or_else(counted) } else { None };
            fresh.extra_recurrence = match until {
                Some(end) => {
                    let (rdates, rest): (Vec<String>, Vec<String>) = carried.into_iter().partition(|l| l.starts_with("RDATE"));
                    rest.into_iter().chain(split_date_lines(&rdates, end, &zone).0).collect()
                }
                None => carried,
            };
        }
        let new_id = adapter.create_event(calendar_provider_id, &fresh).await?;
        let carried = if slots_align {
            adapter.carry_exceptions(calendar_provider_id, series_id, &new_id, &master, &cutoff).await
        } else {
            // A new rule or time makes new slots; the old exceptions have no
            // occurrence to land on (Google drops them the same way).
            Ok(())
        };
        if let Err(e) = match carried {
            Ok(()) => adapter.patch_series(calendar_provider_id, series_id, &ending).await,
            Err(e) => Err(e),
        } {
            let _ = adapter.delete_event(calendar_provider_id, &new_id).await;
            return Err(e);
        }
    } else if draft.recurrence.as_deref().is_none_or(|r| r.trim().is_empty()) {
        // ponytail: "all events → does not repeat" replaces the series with
        // a one-off at this instance's time; guests get a cancel + a new
        // invite rather than an in-place edit. One-off first, as above.
        let new_id = adapter.create_event(calendar_provider_id, &fresh).await?;
        if let Err(e) = adapter.delete_event(calendar_provider_id, series_id).await {
            let _ = adapter.delete_event(calendar_provider_id, &new_id).await;
            return Err(e);
        }
    } else {
        let shift = chrono::Duration::seconds(
            instant(&draft.start_at).unwrap_or(0)
                - instant(instance_start).unwrap_or(0),
        );
        adapter.update_series(calendar_provider_id, series_id, &master, draft, shift).await?;
    }
    Ok(())
}

/// Build a Google `events` resource body from a draft.
fn google_event_body(draft: &EventDraft) -> Value {
    let (start, end) = if draft.all_day {
        (
            serde_json::json!({ "date": draft.start_at }),
            serde_json::json!({ "date": draft.end_at }),
        )
    } else {
        (
            serde_json::json!({ "dateTime": draft.start_at, "timeZone": draft.tz() }),
            serde_json::json!({ "dateTime": draft.end_at, "timeZone": draft.tz() }),
        )
    };
    let attendees: Vec<Value> = draft
        .attendees
        .iter()
        .map(|e| serde_json::json!({ "email": e }))
        .collect();
    let mut body = serde_json::json!({
        "summary": draft.title,
        "start": start,
        "end": end,
    });
    if let Some(d) = &draft.description {
        body["description"] = Value::String(d.clone());
    }
    if let Some(l) = &draft.location {
        body["location"] = Value::String(l.clone());
    }
    if !attendees.is_empty() || draft.attendees_cleared {
        body["attendees"] = Value::Array(attendees);
    }
    if let Some(rule) = draft.recurrence.as_deref().filter(|r| !r.trim().is_empty()) {
        let mut lines = vec![format!("RRULE:{}", rule.trim())];
        lines.extend(draft.extra_recurrence.iter().cloned());
        body["recurrence"] = serde_json::json!(lines);
    }
    if draft.conference {
        // requestId is the caller's idempotency key; a fresh one per body is fine
        // because a retry of the same create would be a new event anyway.
        body["conferenceData"] = serde_json::json!({
            "createRequest": {
                "requestId": nanoid::nanoid!(),
                "conferenceSolutionKey": { "type": "hangoutsMeet" },
            }
        });
    }
    body
}

/// Build a Microsoft Graph `event` body from a draft.
fn ms_event_body(draft: &EventDraft) -> Value {
    let attendees: Vec<Value> = draft
        .attendees
        .iter()
        .map(|e| serde_json::json!({ "emailAddress": { "address": e }, "type": "required" }))
        .collect();
    let start = ms_when(&draft.start_at, draft.all_day, &draft.tz());
    let mut body = serde_json::json!({
        "subject": draft.title,
        "isAllDay": draft.all_day,
        "end": ms_when(&draft.end_at, draft.all_day, &draft.tz()),
    });
    if let Some(d) = &draft.description {
        let kind = if draft.description_is_html { "html" } else { "text" };
        body["body"] = serde_json::json!({ "contentType": kind, "content": d });
    }
    if let Some(l) = &draft.location {
        body["location"] = serde_json::json!({ "displayName": l });
    }
    if !attendees.is_empty() || draft.attendees_cleared {
        body["attendees"] = Value::Array(attendees);
    }
    if let Some(rec) = draft.recurrence.as_deref().and_then(|r| ms_recurrence(r, &start, draft_offset(draft))) {
        body["recurrence"] = rec;
    }
    body["start"] = start;
    if draft.conference {
        body["isOnlineMeeting"] = Value::Bool(true);
        body["onlineMeetingProvider"] = Value::String("teamsForBusiness".into());
    }
    body
}

/// A Graph `dateTimeTimeZone`: a bare wall clock plus the zone it is read in.
/// Graph reads `dateTime` in `timeZone`, so it never goes out with an offset or
/// `Z` on it (2026-10-25: creates sent a UTC instant labelled with the local
/// zone, so a 14:00 meeting in Amsterdam could land at 13:00). Every caller
/// writes a timed draft in its own zone's offset (see `EventDraft`), so the
/// offset is dropped and the wall clock kept — `Z` included: that is London's
/// own winter offset, and re-homing it in UTC would slide a repeating 14:00
/// to 15:00 once summer time starts.
fn ms_when(at: &str, all_day: bool, tz: &str) -> Value {
    const WALL: &str = "%Y-%m-%dT%H:%M:%S";
    if all_day {
        // An all-day event runs midnight to midnight in its zone.
        return serde_json::json!({ "dateTime": format!("{}T00:00:00", at.get(..10).unwrap_or(at)), "timeZone": tz });
    }
    match chrono::DateTime::parse_from_rfc3339(at) {
        Ok(t) => serde_json::json!({ "dateTime": t.naive_local().format(WALL).to_string(), "timeZone": tz }),
        Err(_) => serde_json::json!({ "dateTime": at, "timeZone": tz }),
    }
}

/// The UTC offset a draft's start was written in, when it carries one.
fn draft_offset(draft: &EventDraft) -> Option<chrono::FixedOffset> {
    chrono::DateTime::parse_from_rfc3339(&draft.start_at).ok().map(|t| *t.offset())
}

const RRULE_DAYS: [(&str, &str); 7] = [
    ("MO", "monday"), ("TU", "tuesday"), ("WE", "wednesday"), ("TH", "thursday"),
    ("FR", "friday"), ("SA", "saturday"), ("SU", "sunday"),
];
const GRAPH_INDEX: [(&str, &str); 5] =
    [("1", "first"), ("2", "second"), ("3", "third"), ("4", "fourth"), ("-1", "last")];

/// Why Graph's `patternedRecurrence` can't hold this rule, or None when it
/// can: one frequency, plain weekdays for a weekly rule, one "nth weekday" or
/// one day of the month (and one month) for a monthly/yearly one.
fn ms_unsupported(rule: &str) -> Option<String> {
    let parts = rrule_parts(rule);
    let part = |key: &str| parts.iter().find(|(k, _)| k == key).map(|(_, v)| v.as_str());
    const KNOWN: [&str; 9] = ["FREQ", "INTERVAL", "BYDAY", "COUNT", "UNTIL", "WKST", "BYMONTHDAY", "BYMONTH", "BYSETPOS"];
    if let Some((k, _)) = parts.iter().find(|(k, _)| !KNOWN.contains(&k.as_str())) {
        return Some(format!("{k} has no Outlook equivalent"));
    }
    let freq = part("FREQ").unwrap_or_default().to_ascii_uppercase();
    if !["DAILY", "WEEKLY", "MONTHLY", "YEARLY"].contains(&freq.as_str()) {
        return Some(format!("FREQ={freq} has no Outlook equivalent"));
    }
    if part("COUNT").is_some() && part("UNTIL").is_some() {
        return Some("COUNT and UNTIL together".into());
    }
    let single = |k: &str| part(k).is_none_or(|v| !v.contains(','));
    if !single("BYMONTHDAY") || !single("BYMONTH") || !single("BYSETPOS") {
        return Some("more than one day of the month, month or position".into());
    }
    let days: Vec<(String, String)> = part("BYDAY")
        .unwrap_or_default()
        .split(',')
        .filter(|d| !d.trim().is_empty())
        .map(|d| {
            let d = d.trim().to_ascii_uppercase();
            let split = d.len().saturating_sub(2);
            (d[..split].trim_start_matches('+').to_string(), d[split..].to_string())
        })
        .collect();
    if days.iter().any(|(_, code)| !RRULE_DAYS.iter().any(|(c, _)| c == code)) {
        return Some("an unknown weekday".into());
    }
    let ordinal = |n: &str| GRAPH_INDEX.iter().any(|(i, _)| *i == n);
    match freq.as_str() {
        "DAILY" if !days.is_empty() || part("BYMONTHDAY").is_some() || part("BYMONTH").is_some() || part("BYSETPOS").is_some() => {
            Some("a daily rule with day filters".into())
        }
        "WEEKLY" if days.iter().any(|(n, _)| !n.is_empty()) || part("BYMONTHDAY").is_some() || part("BYMONTH").is_some() || part("BYSETPOS").is_some() => {
            Some("a weekly rule limited to positions, month days or months".into())
        }
        // Graph's month is the yearly pattern's own; a monthly rule can't be
        // limited to some months.
        "MONTHLY" if part("BYMONTH").is_some() => Some("a monthly rule limited to some months".into()),
        "MONTHLY" | "YEARLY" => {
            let numbered: Vec<&String> = days.iter().map(|(n, _)| n).filter(|n| !n.is_empty()).collect();
            if !days.is_empty() && part("BYMONTHDAY").is_some() {
                Some("both weekdays and a day of the month".into())
            } else if numbered.len() > 1 {
                // 2MO,2TU is two dates (the 2nd Monday AND the 2nd Tuesday);
                // Graph's relative pattern would make it one — the 2nd of
                // either.
                Some("more than one weekday at a position".into())
            } else if !numbered.is_empty() && (numbered.len() != days.len() || !ordinal(numbered[0])) {
                Some("weekdays at different or unsupported positions".into())
            } else if numbered.is_empty() && !days.is_empty() && !part("BYSETPOS").is_some_and(ordinal) {
                Some("every such weekday of the month (Outlook only has the nth one)".into())
            } else if part("BYSETPOS").is_some() && (days.is_empty() || !numbered.is_empty() || !part("BYSETPOS").is_some_and(ordinal)) {
                Some("a position without one set of plain weekdays".into())
            } else {
                None
            }
        }
        _ => None,
    }
}

/// The Graph adapter's guard: a rule it would have to drop is refused, with
/// the reason, rather than saving the event with some other schedule.
fn ms_check_rule(draft: &EventDraft) -> Result<()> {
    match draft.recurrence.as_deref().filter(|r| !r.trim().is_empty()).and_then(ms_unsupported) {
        Some(why) => Err(SyncError::Other(format!("Outlook can't repeat this way: {why}"))),
        None => Ok(()),
    }
}

/// A series master's new {start, end} for an edit from one of its instances:
/// the master's own start moved by `shift`, in its own form — unless the edit
/// flips all-day ↔ timed, when the form and length come from the draft on the
/// master's (moved) first day. `google` picks Google's `date` for all-day;
/// Graph wants a midnight wall clock instead.
fn series_times(master_start: &Value, master_all_day: bool, shift: chrono::Duration, draft: &EventDraft, google: bool) -> Result<(Value, Value)> {
    let unreadable = || SyncError::Other("series master time is unreadable".into());
    let length = span(&draft.start_at, &draft.end_at);
    if master_all_day == draft.all_day {
        let start = shift_when(master_start, shift).ok_or_else(unreadable)?;
        let end = shift_when(master_start, shift + length).ok_or_else(unreadable)?;
        return Ok((start, end));
    }
    let moved = shift_when(master_start, shift).ok_or_else(unreadable)?;
    let first = json_str(&moved, "date")
        .or_else(|| json_str(&moved, "dateTime"))
        .and_then(|d| chrono::NaiveDate::parse_from_str(d.get(..10)?, "%Y-%m-%d").ok())
        .ok_or_else(unreadable)?;
    let tz = draft.tz();
    if draft.all_day {
        let days = ((length.num_seconds() + 86_399) / 86_400).max(1);
        let last = first + chrono::Duration::days(days);
        let when = |d: chrono::NaiveDate| {
            if google {
                serde_json::json!({ "date": d.format("%Y-%m-%d").to_string() })
            } else {
                serde_json::json!({ "dateTime": format!("{}T00:00:00", d.format("%Y-%m-%d")), "timeZone": tz })
            }
        };
        return Ok((when(first), when(last)));
    }
    // Timed again: the draft's own time of day (its wall clock) on that day.
    let time_of_day = chrono::DateTime::parse_from_rfc3339(&draft.start_at)
        .map(|t| t.naive_local().time())
        .or_else(|_| chrono::NaiveDateTime::parse_from_str(&draft.start_at, "%Y-%m-%dT%H:%M:%S%.f").map(|t| t.time()))
        .unwrap_or(chrono::NaiveTime::MIN);
    let start = first.and_time(time_of_day);
    let wall = |t: chrono::NaiveDateTime| serde_json::json!({ "dateTime": t.format("%Y-%m-%dT%H:%M:%S").to_string(), "timeZone": tz });
    Ok((wall(start), wall(start + length)))
}

/// An RRULE body as a Graph `patternedRecurrence`, for a series starting at
/// `start` (a Graph `dateTimeTimeZone` — its date is `range.startDate` and its
/// zone the series' zone). Covers DAILY / WEEKLY(BYDAY) / MONTHLY (by date, or
/// `BYDAY=2TU` → relativeMonthly) / YEARLY, INTERVAL, COUNT or UNTIL — the
/// rules the editors write and `graph_rrule` reads back, plus `BYSETPOS=n`
/// with one weekday (the same "nth weekday"). A rule Graph can't express is
/// None here and refused by the Graph adapter up front (`ms_unsupported`), so
/// a schedule is never silently changed. `offset` is the client's own UTC
/// offset, the fallback for placing a timed UNTIL on its local day.
fn ms_recurrence(rule: &str, start: &Value, offset: Option<chrono::FixedOffset>) -> Option<Value> {
    if ms_unsupported(rule).is_some() {
        return None;
    }
    use chrono::Datelike;
    let wall = json_str(start, "dateTime")?;
    let start_day = chrono::NaiveDate::parse_from_str(wall.get(..10)?, "%Y-%m-%d").ok()?;
    let parts = rrule_parts(rule);
    let part = |key: &str| parts.iter().find(|(k, _)| k == key).map(|(_, v)| v.clone());
    let day_name = |code: &str| RRULE_DAYS.iter().find(|(c, _)| code.eq_ignore_ascii_case(c)).map(|(_, n)| *n);
    // `2TU` → ("2", "tuesday"); `TU` → ("", "tuesday").
    let by_day: Vec<(String, &str)> = part("BYDAY")
        .unwrap_or_default()
        .split(',')
        .filter(|d| !d.trim().is_empty())
        .filter_map(|d| {
            let d = d.trim();
            let split = d.len().checked_sub(2)?;
            Some((d[..split].trim_start_matches('+').to_string(), day_name(&d[split..])?))
        })
        .collect();
    let interval: u32 = part("INTERVAL").and_then(|i| i.parse().ok()).unwrap_or(1).max(1);
    let mut pattern = serde_json::json!({ "interval": interval });
    let relative = by_day
        .first()
        .map(|(n, _)| n.clone())
        .filter(|n| !n.is_empty())
        .or_else(|| part("BYSETPOS"))
        .and_then(|n| GRAPH_INDEX.iter().find(|(i, _)| *i == n).map(|(_, name)| *name));
    match part("FREQ")?.to_ascii_uppercase().as_str() {
        "DAILY" => pattern["type"] = "daily".into(),
        "WEEKLY" => {
            let days: Vec<&str> = if by_day.is_empty() {
                vec![RRULE_DAYS[start_day.weekday().num_days_from_monday() as usize].1]
            } else {
                by_day.iter().map(|(_, d)| *d).collect()
            };
            pattern["type"] = "weekly".into();
            pattern["daysOfWeek"] = serde_json::json!(days);
            // The rule's own week start (WKST) — it decides which weeks an
            // every-N-weeks series falls in. Monday when the rule names none.
            pattern["firstDayOfWeek"] = part("WKST")
                .and_then(|w| RRULE_DAYS.iter().find(|(c, _)| w.eq_ignore_ascii_case(c)).map(|(_, n)| *n))
                .unwrap_or("monday")
                .into();
        }
        "MONTHLY" | "YEARLY" => {
            let yearly = part("FREQ")?.eq_ignore_ascii_case("YEARLY");
            if let Some(index) = relative {
                pattern["type"] = if yearly { "relativeYearly" } else { "relativeMonthly" }.into();
                pattern["daysOfWeek"] = serde_json::json!(by_day.iter().map(|(_, d)| *d).collect::<Vec<_>>());
                pattern["index"] = index.into();
            } else {
                pattern["type"] = if yearly { "absoluteYearly" } else { "absoluteMonthly" }.into();
                let day = part("BYMONTHDAY").and_then(|d| d.parse::<u32>().ok()).unwrap_or(start_day.day());
                pattern["dayOfMonth"] = day.into();
            }
            if yearly {
                let month = part("BYMONTH").and_then(|m| m.parse::<u32>().ok()).unwrap_or(start_day.month());
                pattern["month"] = month.into();
            }
        }
        _ => return None,
    }
    let mut range = serde_json::json!({
        "type": "noEnd",
        "startDate": start_day.format("%Y-%m-%d").to_string(),
        "recurrenceTimeZone": json_str(start, "timeZone").unwrap_or_else(|| "UTC".into()),
    });
    if let Some(count) = part("COUNT").and_then(|c| c.parse::<u32>().ok()) {
        range["type"] = "numbered".into();
        range["numberOfOccurrences"] = count.into();
    } else if let Some(until) = part("UNTIL") {
        // `20261130` is the day itself. `20261130T225959Z` is an instant: the
        // end date is the last day whose occurrence (at the event's own time
        // of day) starts by then, read in the series' zone with its real DST
        // rules — a Windows name off Graph through the CLDR table. Only a zone
        // neither knows falls back to the client's offset at the start.
        let end = if until.len() > 8 {
            let at = chrono::NaiveDateTime::parse_from_str(until.trim_end_matches('Z'), "%Y%m%dT%H%M%S").ok()?.and_utc();
            let zone = json_str(start, "timeZone").unwrap_or_default();
 let local = match named_zone(&zone) {
                Some(tz) => at.with_timezone(&tz).naive_local(),
                None => at.naive_utc() + chrono::Duration::seconds(offset.map_or(0, |o| o.local_minus_utc() as i64)),
            };
            let time_of_day = chrono::NaiveDateTime::parse_from_str(&wall, "%Y-%m-%dT%H:%M:%S%.f")
                .map(|t| t.time())
                .unwrap_or(chrono::NaiveTime::MIN);
            if local.time() >= time_of_day { local.date() } else { local.date() - chrono::Duration::days(1) }
        } else {
            chrono::NaiveDate::parse_from_str(until.get(..8)?, "%Y%m%d").ok()?
        };
        range["type"] = "endDate".into();
        range["endDate"] = end.format("%Y-%m-%d").to_string().into();
    }
    Some(serde_json::json!({ "pattern": pattern, "range": range }))
}

/// A Graph `patternedRecurrence` as an RRULE body — what the editors prefill a
/// series edit with. The inverse of `ms_recurrence`; an endDate comes back as a
/// DATE UNTIL, which is all `ms_recurrence` reads of it anyway.
fn graph_rrule(rec: &Value) -> Option<String> {
    let pattern = rec.get("pattern")?;
    let range = rec.get("range");
    let kind = json_str(pattern, "type")?;
    let days: Vec<&str> = pattern
        .get("daysOfWeek")
        .and_then(|d| d.as_array())
        .map(|a| {
            a.iter()
                .filter_map(|d| d.as_str())
                .filter_map(|n| RRULE_DAYS.iter().find(|(_, name)| n.eq_ignore_ascii_case(name)).map(|(c, _)| *c))
                .collect()
        })
        .unwrap_or_default();
    let index = json_str(pattern, "index")
        .and_then(|i| GRAPH_INDEX.iter().find(|(_, name)| *name == i).map(|(n, _)| *n))
        .unwrap_or("1");
    let num = |k: &str| pattern.get(k).and_then(|v| v.as_u64());
    let mut parts = vec![match kind.as_str() {
        "daily" => "FREQ=DAILY".to_string(),
        "weekly" => {
            // Monday is what `ms_recurrence` writes without one, so only
            // another week start needs saying.
            let wkst = json_str(pattern, "firstDayOfWeek")
                .and_then(|n| RRULE_DAYS.iter().find(|(_, name)| n.eq_ignore_ascii_case(name)).map(|(c, _)| *c))
                .filter(|c| *c != "MO");
            match wkst {
                Some(w) => format!("FREQ=WEEKLY;BYDAY={};WKST={w}", days.join(",")),
                None => format!("FREQ=WEEKLY;BYDAY={}", days.join(",")),
            }
        }
        "absoluteMonthly" => format!("FREQ=MONTHLY;BYMONTHDAY={}", num("dayOfMonth")?),
        "relativeMonthly" => format!("FREQ=MONTHLY;BYDAY={}", days.iter().map(|d| format!("{index}{d}")).collect::<Vec<_>>().join(",")),
        "absoluteYearly" => format!("FREQ=YEARLY;BYMONTH={};BYMONTHDAY={}", num("month")?, num("dayOfMonth")?),
        "relativeYearly" => format!("FREQ=YEARLY;BYMONTH={};BYDAY={}", num("month")?, days.iter().map(|d| format!("{index}{d}")).collect::<Vec<_>>().join(",")),
        _ => return None,
    }];
    if let Some(n) = num("interval").filter(|n| *n > 1) {
        parts.push(format!("INTERVAL={n}"));
    }
    match range.and_then(|r| json_str(r, "type")).as_deref() {
        Some("numbered") => parts.push(format!("COUNT={}", range?.get("numberOfOccurrences")?.as_u64()?)),
        Some("endDate") => parts.push(format!("UNTIL={}", json_str(range?, "endDate")?.replace('-', ""))),
        _ => {}
    }
    Some(parts.join(";"))
}

/// Map a standard RSVP verb to the Microsoft Graph action path segment.
fn ms_response_action(response: &str) -> Result<&'static str> {
    match response {
        "accepted" => Ok("accept"),
        "declined" => Ok("decline"),
        "tentative" => Ok("tentativelyAccept"),
        other => Err(SyncError::Other(format!("unknown RSVP response: {other}"))),
    }
}

// ── Shared helpers ─────────────────────────────────────────────────────────

/// A JSON array of strings as a Vec. Absent / not an array / non-string members
/// all reduce to what is actually there, which for a provider field we don't
/// control is the only safe reading.
fn string_list(v: Option<&Value>) -> Vec<String> {
    v.and_then(|v| v.as_array())
        .map(|a| a.iter().filter_map(|e| e.as_str().map(str::to_string)).collect())
        .unwrap_or_default()
}

fn sanitize(s: &str) -> String {
    s.chars()
        .map(|c| if c.is_ascii_alphanumeric() || matches!(c, '@' | '.' | '_' | '-') { c } else { '_' })
        .collect()
}

/// The span a full calendar sync stores locally: 180 days back, a year ahead.
pub fn time_window() -> (String, String) {
    let now = chrono::Utc::now();
    let min = now - chrono::Duration::days(180);
    let max = now + chrono::Duration::days(365);
    (min.to_rfc3339(), max.to_rfc3339())
}

// ===========================================================================
// Google Calendar
// ===========================================================================

pub struct GoogleCalendarAdapter {
    token: Arc<TokenManager>,
    account_key: String,
    api_base: String,
}

impl GoogleCalendarAdapter {
    pub fn new(token: Arc<TokenManager>, account_key: String) -> Self {
        Self { token, account_key, api_base: GCAL_API.to_string() }
    }

    #[cfg(test)]
    pub fn with_base(mut self, base: String) -> Self {
        self.api_base = base;
        self
    }

    async fn get(&self, url: &str) -> Result<(Value, reqwest::StatusCode)> {
        let resp = self.token.request(reqwest::Method::GET, url, None).await?;
        let status = resp.status();
        if status.is_success() {
            Ok((resp.json().await?, status))
        } else {
            Ok((Value::Null, status))
        }
    }

    /// Occurrences whose ORIGINAL slot is before `cutoff`, cancelled ones
    /// included. Fetched by current time up to a year past the cutoff, so an
    /// occurrence moved later than it is still seen and placed by its slot.
    async fn count_original_before(&self, calendar_provider_id: &str, master_id: &str, cutoff: i64) -> Result<usize> {
        let until = chrono::DateTime::from_timestamp(cutoff + 366 * 86_400, 0)
            .map(|t| t.format("%Y-%m-%dT%H:%M:%SZ").to_string())
            .unwrap_or_default();
        let mut n = 0;
        let mut page: Option<String> = None;
        loop {
            let mut url = format!(
                "{}/calendars/{}/events/{}/instances?showDeleted=true&maxResults=2500&timeMax={}",
                self.api_base,
                urlencode(calendar_provider_id),
                urlencode(master_id),
                urlencode(&until)
            );
            if let Some(p) = &page {
                url.push_str(&format!("&pageToken={}", urlencode(p)));
            }
            let (data, status) = self.get(&url).await?;
            if !status.is_success() {
                return Err(http_status_error("Google series instances", status, ""));
            }
            n += data.get("items").and_then(|i| i.as_array()).map_or(0, |items| {
                items.iter().filter(|i| original_slot(i).is_some_and(|t| t < cutoff)).count()
            });
            page = json_str(&data, "nextPageToken");
            if page.is_none() {
                return Ok(n);
            }
        }
    }

    /// Paginated `events.list` over a window, recurrences expanded. Also returns
    /// the last page's `nextSyncToken`.
    async fn events_in(&self, cal_id: &str, time_min: &str, time_max: &str)
        -> Result<(Vec<UnifiedEvent>, Option<String>)> {
        let mut page_token: Option<String> = None;
        let mut upserts = Vec::new();
        let mut next_token = None;
        loop {
            let mut url = format!(
                "{}/calendars/{cal_id}/events?maxResults=250&singleEvents=true&orderBy=startTime\
                 &timeMin={}&timeMax={}",
                self.api_base,
                urlencode(time_min),
                urlencode(time_max)
            );
            if let Some(t) = &page_token {
                url.push_str(&format!("&pageToken={}", urlencode(t)));
            }
            let (data, status) = self.get(&url).await?;
            if !status.is_success() {
                return Err(http_status_error("Google events", status, ""));
            }
            for ev in data.get("items").and_then(|i| i.as_array()).cloned().unwrap_or_default() {
                upserts.push(google_event(&ev));
            }
            if let Some(t) = json_str(&data, "nextSyncToken") {
                next_token = Some(t);
            }
            page_token = json_str(&data, "nextPageToken");
            if page_token.is_none() {
                break;
            }
        }
        Ok((upserts, next_token))
    }
}

#[async_trait]
impl CalendarAdapter for GoogleCalendarAdapter {
    fn source(&self) -> &'static str {
        source::GOOGLE
    }

    async fn list_calendars(&self) -> Result<Vec<UnifiedCalendar>> {
        let url = format!("{}/users/me/calendarList", self.api_base);
        let (data, status) = self.get(&url).await?;
        if !status.is_success() {
            return Err(http_status_error("Google calendarList", status, ""));
        }
        let mut cals = Vec::new();
        for c in data.get("items").and_then(|i| i.as_array()).cloned().unwrap_or_default() {
            let id = json_str(&c, "id").unwrap_or_default();
            if id.is_empty() {
                continue;
            }
            // accessRole is owner | writer | reader | freeBusyReader; only the first
            // two can mutate events (others 403 on create/update/delete).
            let access = json_str(&c, "accessRole");
            let writable = matches!(access.as_deref(), Some("owner") | Some("writer"));
            let owned = access.as_deref() == Some("owner");
            cals.push(UnifiedCalendar {
                conference_providers: string_list(
                    c.get("conferenceProperties").and_then(|p| p.get("allowedConferenceSolutionTypes")),
                )
                .iter()
                .filter(|t| t == &conference::GOOGLE_MEET_SOLUTION)
                .map(|_| conference::MEET.to_string())
                .collect(),
                key: format!("cal_gcal_{}_{}", self.account_key, sanitize(&id)),
                provider_id: id.clone(),
                name: json_str(&c, "summary").unwrap_or(id),
                color: json_str(&c, "backgroundColor").unwrap_or_else(|| "#3B82F6".into()),
                is_primary: c.get("primary").and_then(|p| p.as_bool()).unwrap_or(false),
                is_writable: writable,
                is_owned: owned,
            });
        }
        Ok(cals)
    }

    async fn sync_calendar(
        &self,
        cal: &UnifiedCalendar,
        cursor: &CalendarCursor,
    ) -> Result<CalendarSyncResult> {
        let cal_id = urlencode(&cal.provider_id);

        if let Some(token) = &cursor.token {
            // Incremental: events?syncToken=...
            let url = format!("{}/calendars/{cal_id}/events?syncToken={}", self.api_base, urlencode(token));
            let (data, status) = self.get(&url).await?;
            if status == reqwest::StatusCode::GONE {
                return Err(SyncError::CursorExpired);
            }
            if !status.is_success() {
                return Err(http_status_error("Google events", status, ""));
            }
            let mut upserts = Vec::new();
            let mut deletions = Vec::new();
            for ev in data.get("items").and_then(|i| i.as_array()).cloned().unwrap_or_default() {
                let id = json_str(&ev, "id").unwrap_or_default();
                if json_str(&ev, "status").as_deref() == Some("cancelled") {
                    deletions.push(id);
                } else {
                    upserts.push(google_event(&ev));
                }
            }
            return Ok(CalendarSyncResult {
                upserts,
                deletions,
                next_token: json_str(&data, "nextSyncToken"),
                ..Default::default()
            });
        }

        // Full sync, paginated, time-windowed.
        let (time_min, time_max) = time_window();
        let (upserts, next_token) = self.events_in(&cal_id, &time_min, &time_max).await?;
        let seen = upserts.iter().map(|e| e.provider_id.clone()).collect();
        Ok(CalendarSyncResult {
            upserts,
            seen_provider_ids: Some(seen),
            next_token,
            ..Default::default()
        })
    }

    async fn list_events(&self, cal: &UnifiedCalendar, time_min: &str, time_max: &str)
        -> Result<Vec<UnifiedEvent>> {
        Ok(self.events_in(&urlencode(&cal.provider_id), time_min, time_max).await?.0)
    }

    async fn get_series(&self, calendar_provider_id: &str, master_id: &str) -> Result<SeriesMaster> {
        let url = format!("{}/calendars/{}/events/{}", self.api_base, urlencode(calendar_provider_id), urlencode(master_id));
        let (raw, status) = self.get(&url).await?;
        if !status.is_success() {
            return Err(http_status_error("Google get series", status, ""));
        }
        let rule = string_list(raw.get("recurrence"))
            .into_iter()
            .find_map(|l| l.strip_prefix("RRULE:").map(str::to_string));
        let attendees = raw
            .get("attendees")
            .and_then(|a| a.as_array())
            .map(|a| {
                a.iter()
                    .filter(|g| !g.get("organizer").and_then(|o| o.as_bool()).unwrap_or(false))
                    .filter_map(|g| json_str(g, "email"))
                    .collect()
            })
            .unwrap_or_default();
        let description = json_str(&raw, "description");
        Ok(SeriesMaster { raw, rule, attendees, description, description_is_html: false })
    }

    async fn update_series(
        &self,
        calendar_provider_id: &str,
        master_id: &str,
        master: &SeriesMaster,
        draft: &EventDraft,
        shift: chrono::Duration,
    ) -> Result<()> {
        let start = master.raw.get("start").ok_or_else(|| SyncError::Other("series master has no start".into()))?;
        let mut body = google_event_body(draft);
        body.as_object_mut().map(|b| b.remove("attendees"));
        if let Some(a) = Some(&draft.attendees).filter(|w| !w.is_empty() || draft.attendees_cleared).and_then(|w| {
            merged_attendees(master.raw.get("attendees"), w, |a| json_str(a, "email"), |e| serde_json::json!({ "email": e }))
        }) {
            body["attendees"] = a;
        }
        let (new_start, new_end) = series_times(start, start.get("date").is_some(), shift, draft, true)?;
        body["start"] = new_start;
        body["end"] = new_end;
        // Keep the series' own EXDATE/RDATE lines; only the rule is the editor's.
        if let Some(rule) = draft.recurrence.as_deref() {
            let mut lines: Vec<String> =
                string_list(master.raw.get("recurrence")).into_iter().filter(|l| !l.starts_with("RRULE:")).collect();
            lines.insert(0, format!("RRULE:{}", rule.trim()));
            body["recurrence"] = serde_json::json!(lines);
        }
        let url = format!(
            "{}/calendars/{}/events/{}?sendUpdates=all",
            self.api_base,
            urlencode(calendar_provider_id),
            urlencode(master_id)
        );
        let resp = self.token.request(reqwest::Method::PATCH, &url, Some(&body)).await?;
        if !resp.status().is_success() {
            let status = resp.status();
            let detail = resp.text().await.unwrap_or_default();
            return Err(http_status_error("Google update series", status, &detail));
        }
        Ok(())
    }

    async fn ended_recurrence(
        &self,
        calendar_provider_id: &str,
        master: &SeriesMaster,
        instance_id: &str,
        instance_start: &str,
    ) -> Result<Option<SeriesEnd>> {
        let start = master.raw.get("start");
        let all_day = start.and_then(|s| json_str(s, "date")).is_some();
        let first = start
            .and_then(|s| json_str(s, "dateTime").or_else(|| json_str(s, "date")))
            .and_then(|s| instant(&s));
        // The instance's own slot: a moved occurrence keeps its original one.
        let url = format!("{}/calendars/{}/events/{}", self.api_base, urlencode(calendar_provider_id), urlencode(instance_id));
        let (instance, status) = self.get(&url).await?;
        if !status.is_success() {
            return Err(http_status_error("Google get instance", status, ""));
        }
        let cutoff_at = instance
            .get("originalStartTime")
            .and_then(|s| json_str(s, "dateTime").or_else(|| json_str(s, "date")))
            .unwrap_or_else(|| instance_start.to_string());
        let cutoff = instant(&cutoff_at).ok_or_else(|| SyncError::Other("instance time is unreadable".into()))?;
        if first.is_none_or(|f| cutoff <= f) {
            return Ok(None);
        }
        let rule = master.rule.as_deref().ok_or_else(|| SyncError::Other("series has no rule".into()))?;
        let until = rrule_until(rule, cutoff, all_day).ok_or_else(|| SyncError::Other("bad cutoff".into()))?;
        // The series' own EXDATE/RDATE dates before the cutoff stay; the rest
        // belong to the new half (an RDATE left here would recur on both).
        let zone = start.and_then(|s| json_str(s, "timeZone")).unwrap_or_else(|| "UTC".into());
        let dates: Vec<String> =
            string_list(master.raw.get("recurrence")).into_iter().filter(|l| !l.starts_with("RRULE:")).collect();
        let mut lines = split_date_lines(&dates, cutoff, &zone).0;
        lines.insert(0, format!("RRULE:{until}"));
        let done = if rule.to_ascii_uppercase().contains("COUNT=") {
            let master_id = json_str(&master.raw, "id").unwrap_or_default();
            self.count_original_before(calendar_provider_id, &master_id, cutoff).await?
        } else {
            0
        };
        Ok(Some(SeriesEnd { body: serde_json::json!({ "recurrence": lines }), cutoff: cutoff_at, done }))
    }

    async fn carry_exceptions(
        &self,
        calendar_provider_id: &str,
        old_master_id: &str,
        new_master_id: &str,
        master: &SeriesMaster,
        cutoff: &str,
    ) -> Result<()> {
        let cal = urlencode(calendar_provider_id);
        let from = instant(cutoff);
        let same = |item: &Value, key: &str| item.get(key) == master.raw.get(key);
        // Everything an occurrence can override besides its time. ponytail:
        // conferenceData isn't carried — a new series mints its own link.
        const OVERRIDES: [&str; 8] =
            ["summary", "location", "description", "attendees", "reminders", "colorId", "transparency", "visibility"];
        let mut page: Option<String> = None;
        loop {
            // timeMin filters by an occurrence's CURRENT time; one moved to
            // before the cutoff still belongs after it by its slot, so look a
            // year back and sort by `originalStartTime` below.
            let since = from
                .and_then(|f| chrono::DateTime::from_timestamp(f - 366 * 86_400, 0))
                .map(|t| t.format("%Y-%m-%dT%H:%M:%SZ").to_string())
                .unwrap_or_else(|| cutoff.to_string());
            let mut url = format!(
                "{}/calendars/{cal}/events/{}/instances?showDeleted=true&maxResults=2500&timeMin={}",
                self.api_base,
                urlencode(old_master_id),
                urlencode(&since)
            );
            if let Some(p) = &page {
                url.push_str(&format!("&pageToken={}", urlencode(p)));
            }
            let (data, status) = self.get(&url).await?;
            if !status.is_success() {
                return Err(http_status_error("Google series instances", status, ""));
            }
            for item in data.get("items").and_then(|i| i.as_array()).into_iter().flatten() {
                let Some(orig) = item.get("originalStartTime") else { continue };
                let orig_at = json_str(orig, "dateTime").or_else(|| json_str(orig, "date")).unwrap_or_default();
                let Some(orig_t) = instant(&orig_at) else { continue };
                if from.is_some_and(|f| orig_t < f) {
                    continue;
                }
                let cancelled = json_str(item, "status").as_deref() == Some("cancelled");
                let moved = item
                    .get("start")
                    .and_then(|s| json_str(s, "dateTime").or_else(|| json_str(s, "date")))
                    .and_then(|s| instant(&s))
                    != Some(orig_t);
                let edited = OVERRIDES.iter().any(|k| !same(item, k));
                if !cancelled && !moved && !edited {
                    continue;
                }
                // Google addresses an occurrence as <series>_<its original slot>.
                let stamp = if json_str(orig, "date").is_some() {
                    orig_at.replace('-', "")
                } else {
                    chrono::DateTime::from_timestamp(orig_t, 0).map(|t| t.format("%Y%m%dT%H%M%SZ").to_string()).unwrap_or_default()
                };
                let target = format!("{}/calendars/{cal}/events/{}?sendUpdates=all", self.api_base, urlencode(&format!("{new_master_id}_{stamp}")));
                let resp = if cancelled {
                    self.token.request(reqwest::Method::DELETE, &target, None).await?
                } else {
                    // Only what this occurrence changed: copying its title back
                    // would undo a retitle the split itself is making.
                    let mut body = serde_json::json!({});
                    if moved {
                        for key in ["start", "end"] {
                            if let Some(v) = item.get(key) {
                                body[key] = v.clone();
                            }
                        }
                    }
                    for key in OVERRIDES {
                        if !same(item, key) {
                            body[key] = item.get(key).cloned().unwrap_or(Value::Null);
                        }
                    }
                    self.token.request(reqwest::Method::PATCH, &target, Some(&body)).await?
                };
                let status = resp.status();
                // No such slot on the new series (a COUNT ran out first): nothing to carry.
                if !status.is_success() && status != reqwest::StatusCode::NOT_FOUND && status != reqwest::StatusCode::GONE {
                    let detail = resp.text().await.unwrap_or_default();
                    return Err(http_status_error("Google carry exception", status, &detail));
                }
            }
            page = json_str(&data, "nextPageToken");
            if page.is_none() {
                return Ok(());
            }
        }
    }

    async fn patch_series(&self, calendar_provider_id: &str, master_id: &str, body: &Value) -> Result<()> {
        let url = format!(
            "{}/calendars/{}/events/{}?sendUpdates=all",
            self.api_base,
            urlencode(calendar_provider_id),
            urlencode(master_id)
        );
        let resp = self.token.request(reqwest::Method::PATCH, &url, Some(body)).await?;
        if !resp.status().is_success() {
            let status = resp.status();
            let detail = resp.text().await.unwrap_or_default();
            return Err(http_status_error("Google end series", status, &detail));
        }
        Ok(())
    }

    async fn create_event(&self, calendar_provider_id: &str, draft: &EventDraft) -> Result<String> {
        // sendUpdates: without it Google puts the event on the attendees'
        // calendars but mails nobody, so an invited external address never
        // hears about the meeting. conferenceData is ignored unless the
        // request opts into version 1.
        let url = format!(
            "{}/calendars/{}/events?sendUpdates=all{}",
            self.api_base,
            urlencode(calendar_provider_id),
            if draft.conference { "&conferenceDataVersion=1" } else { "" }
        );
        let body = google_event_body(draft);
        let resp = self.token.request(reqwest::Method::POST, &url, Some(&body)).await?;
        if !resp.status().is_success() {
            let status = resp.status();
            let detail = resp.text().await.unwrap_or_default();
            return Err(http_status_error("Google create event", status, &detail));
        }
        let data: Value = resp.json().await?;
        json_str(&data, "id").ok_or_else(|| SyncError::Other("created event has no id".into()))
    }

    /// `events.import` — "add a private copy of an existing event to a calendar",
    /// which is exactly what an emailed .ics is. Unlike `insert` it takes `iCalUID`
    /// and keeps it, so the event stays matchable against the mail it came from, and
    /// importing the same UID twice updates the one event instead of making a second.
    async fn import_event(
        &self,
        calendar_provider_id: &str,
        draft: &EventDraft,
        ical_uid: &str,
    ) -> Result<String> {
        let url = format!("{}/calendars/{}/events/import", self.api_base, urlencode(calendar_provider_id));
        let mut body = google_event_body(draft);
        body["iCalUID"] = Value::String(ical_uid.to_string());
        let resp = self.token.request(reqwest::Method::POST, &url, Some(&body)).await?;
        if !resp.status().is_success() {
            let status = resp.status();
            let detail = resp.text().await.unwrap_or_default();
            return Err(http_status_error("Google import event", status, &detail));
        }
        let data: Value = resp.json().await?;
        json_str(&data, "id").ok_or_else(|| SyncError::Other("imported event has no id".into()))
    }

    async fn update_event(
        &self,
        calendar_provider_id: &str,
        event_provider_id: &str,
        draft: &EventDraft,
    ) -> Result<()> {
        let url = format!(
            "{}/calendars/{}/events/{}",
            self.api_base,
            urlencode(calendar_provider_id),
            urlencode(event_provider_id)
        );
        let mut body = google_event_body(draft);
        if body.get("attendees").is_some() {
            // Kept guests keep their RSVPs: reuse the event's own entries.
            let (current, status) = self.get(&url).await?;
            if !status.is_success() {
                return Err(http_status_error("Google get event", status, ""));
            }
            match merged_attendees(current.get("attendees"), &draft.attendees, |a| json_str(a, "email"), |e| serde_json::json!({ "email": e })) {
                Some(a) => body["attendees"] = a,
                None => {
                    body.as_object_mut().map(|b| b.remove("attendees"));
                }
            }
        }
        let resp = self.token.request(reqwest::Method::PATCH, &url, Some(&body)).await?;
        if !resp.status().is_success() {
            let status = resp.status();
            let detail = resp.text().await.unwrap_or_default();
            return Err(http_status_error("Google update event", status, &detail));
        }
        Ok(())
    }

    async fn reschedule_event(
        &self,
        calendar_provider_id: &str,
        event_provider_id: &str,
        r: &Reschedule,
    ) -> Result<()> {
        let event_url = |id: &str| {
            format!("{}/calendars/{}/events/{}", self.api_base, urlencode(calendar_provider_id), urlencode(id))
        };
        let (target, body) = match &r.series_id {
            Some(master_id) => {
                let (master, status) = self.get(&event_url(master_id)).await?;
                if !status.is_success() {
                    return Err(http_status_error("Google get series", status, ""));
                }
                let (start, end) = shifted_series_times(&master, r)?;
                (master_id.as_str(), serde_json::json!({ "start": start, "end": end }))
            }
            None => {
                let when = |at: &str| {
                    if r.all_day {
                        serde_json::json!({ "date": at })
                    } else {
                        serde_json::json!({ "dateTime": at, "timeZone": r.tz() })
                    }
                };
                (event_provider_id, serde_json::json!({ "start": when(&r.start_at), "end": when(&r.end_at) }))
            }
        };
        let send = if r.notify { "all" } else { "none" };
        let url = format!("{}?sendUpdates={send}", event_url(target));
        let resp = self.token.request(reqwest::Method::PATCH, &url, Some(&body)).await?;
        if !resp.status().is_success() {
            let status = resp.status();
            let detail = resp.text().await.unwrap_or_default();
            return Err(http_status_error("Google reschedule event", status, &detail));
        }
        Ok(())
    }

    async fn delete_event(&self, calendar_provider_id: &str, event_provider_id: &str) -> Result<()> {
        let url = format!(
            "{}/calendars/{}/events/{}",
            self.api_base,
            urlencode(calendar_provider_id),
            urlencode(event_provider_id)
        );
        let resp = self.token.request(reqwest::Method::DELETE, &url, None).await?;
        // Google returns 204 No Content; 410 Gone means already deleted.
        let status = resp.status();
        if !status.is_success() && status != reqwest::StatusCode::GONE {
            return Err(http_status_error("Google delete event", status, ""));
        }
        Ok(())
    }

    async fn respond_event(
        &self,
        calendar_provider_id: &str,
        event_provider_id: &str,
        response: &str,
    ) -> Result<()> {
        // Google RSVP = update the calling user's attendee responseStatus, so
        // GET the event, find the attendee flagged `self`, patch the array.
        let google_status = match response {
            "accepted" => "accepted",
            "declined" => "declined",
            "tentative" => "tentative",
            other => return Err(SyncError::Other(format!("unknown RSVP response: {other}"))),
        };
        let cal = urlencode(calendar_provider_id);
        let ev = urlencode(event_provider_id);
        let get_url = format!("{}/calendars/{cal}/events/{ev}", self.api_base);
        let (data, status) = self.get(&get_url).await?;
        if !status.is_success() {
            return Err(http_status_error("Google get event", status, ""));
        }
        let mut attendees = data
            .get("attendees")
            .and_then(|a| a.as_array())
            .cloned()
            .unwrap_or_default();
        let mut found = false;
        for att in attendees.iter_mut() {
            if att.get("self").and_then(|s| s.as_bool()).unwrap_or(false) {
                att["responseStatus"] = Value::String(google_status.to_string());
                found = true;
            }
        }
        if !found {
            return Err(SyncError::Other("not an attendee of this event".into()));
        }
        // sendUpdates: without it Google records the answer but mails nobody, so
        // the organizer never hears a decline (Graph's sendResponse: true twin).
        let patch_url = format!("{}/calendars/{cal}/events/{ev}?sendUpdates=all", self.api_base);
        let body = serde_json::json!({ "attendees": attendees });
        let resp = self.token.request(reqwest::Method::PATCH, &patch_url, Some(&body)).await?;
        if !resp.status().is_success() {
            let status = resp.status();
            let detail = resp.text().await.unwrap_or_default();
            return Err(http_status_error("Google RSVP", status, &detail));
        }
        Ok(())
    }
}

// The join link the provider itself recorded, as `{url, label, code}` on
// `calendar_events.metadata.conference`. Clients prefer it over scraping the
// description — an invite forwarded through three mail clients keeps the
// structured field long after the body has been mangled. `label`/`code` are
// optional; only `url` is load-bearing.
fn google_conference(ev: &Value) -> Option<Value> {
    let cd = ev.get("conferenceData");
    let url = cd
        .and_then(|c| c.get("entryPoints"))
        .and_then(|e| e.as_array())
        // Entry points also cover phone/sip/more — "video" is the one you click.
        .and_then(|arr| {
            arr.iter()
                .find(|p| json_str(p, "entryPointType").as_deref() == Some("video"))
                .and_then(|p| json_str(p, "uri"))
        })
        // Events created before conferenceData (and Meet links added by the old
        // "add video call" button) carry only hangoutLink.
        .or_else(|| json_str(ev, "hangoutLink"))?;
    // Not always Meet: a Zoom/Webex add-on writes its own solution here, which is
    // exactly why reading the field beats assuming the brand.
    Some(serde_json::json!({
        "url": url,
        "label": cd.and_then(|c| c.get("conferenceSolution")).and_then(|s| json_str(s, "name")),
        "code": cd.and_then(|c| json_str(c, "conferenceId")),
    }))
}

// Same shape from Graph. `onlineMeeting` is populated for Teams/Skype meetings;
// `onlineMeetingUrl` is the deprecated single-field form some tenants still send.
fn ms_conference(ev: &Value) -> Option<Value> {
    let meeting = ev.get("onlineMeeting");
    let url = meeting
        .and_then(|m| json_str(m, "joinUrl"))
        .or_else(|| json_str(ev, "onlineMeetingUrl"))?;
    let label = match json_str(ev, "onlineMeetingProvider").as_deref() {
        Some("teamsForBusiness") => Some("Microsoft Teams"),
        Some("skypeForBusiness") | Some("skypeForConsumer") => Some("Skype"),
        _ => None,
    };
    Some(serde_json::json!({
        "url": url,
        "label": label,
        "code": meeting.and_then(|m| json_str(m, "conferenceId")),
    }))
}

fn google_event(ev: &Value) -> UnifiedEvent {
    let start_obj = ev.get("start");
    let end_obj = ev.get("end");
    let start = start_obj
        .and_then(|s| json_str(s, "dateTime").or_else(|| json_str(s, "date")))
        .unwrap_or_default();
    let end = end_obj
        .and_then(|e| json_str(e, "dateTime").or_else(|| json_str(e, "date")))
        .unwrap_or_default();
    let all_day = start_obj.and_then(|s| s.get("dateTime")).is_none();
    let timezone = start_obj.and_then(|s| json_str(s, "timeZone")).unwrap_or_else(|| "UTC".into());

    let attendees: Vec<Value> = ev
        .get("attendees")
        .and_then(|a| a.as_array())
        .map(|arr| {
            arr.iter()
                .map(|a| {
                    serde_json::json!({
                        "email": json_str(a, "email"),
                        "name": json_str(a, "displayName"),
                        "responseStatus": json_str(a, "responseStatus").unwrap_or_else(|| "needsAction".into()),
                        "organizer": a.get("organizer").and_then(|o| o.as_bool()).unwrap_or(false),
                    })
                })
                .collect()
        })
        .unwrap_or_default();
    let metadata = serde_json::json!({
        "attendees": attendees,
        "htmlLink": json_str(ev, "htmlLink"),
        "conference": google_conference(ev),
        // The series this instance belongs to — what "all events" moves.
        "seriesId": json_str(ev, "recurringEventId"),
    });

    let recurrence = ev.get("recurrence").and_then(|r| r.as_array()).map(|arr| {
        arr.iter().filter_map(|v| v.as_str()).collect::<Vec<_>>().join("\n")
    });

    UnifiedEvent {
        provider_id: json_str(ev, "id").unwrap_or_default(),
        title: json_str(ev, "summary").unwrap_or_else(|| "(No title)".into()),
        description: json_str(ev, "description"),
        location: json_str(ev, "location"),
        start_at: start,
        end_at: end,
        all_day,
        timezone,
        status: json_str(ev, "status").unwrap_or_else(|| "confirmed".into()),
        etag: json_str(ev, "etag"),
        ical_uid: json_str(ev, "iCalUID"),
        recurrence_rule: recurrence,
        organizer_email: ev.get("organizer").and_then(|o| json_str(o, "email")),
        organizer_name: ev.get("organizer").and_then(|o| json_str(o, "displayName")),
        metadata: Some(metadata.to_string()),
    }
}

// ===========================================================================
// Microsoft Calendar
// ===========================================================================

pub struct MicrosoftCalendarAdapter {
    token: Arc<TokenManager>,
    account_key: String,
    api_base: String,
}

impl MicrosoftCalendarAdapter {
    pub fn new(token: Arc<TokenManager>, account_key: String) -> Self {
        Self { token, account_key, api_base: GRAPH_API.to_string() }
    }

    #[cfg(test)]
    pub fn with_base(mut self, base: String) -> Self {
        self.api_base = base;
        self
    }

    /// Paginated `calendarView` over a window (recurrences expanded). Also returns
    /// a `deltaLink` if Graph handed one out.
    async fn calendar_view(&self, cal: &UnifiedCalendar, time_min: &str, time_max: &str)
        -> Result<(Vec<UnifiedEvent>, Option<String>)> {
        let mut url = format!(
            "{}/me/calendars/{}/calendarView?startDateTime={}&endDateTime={}&$select={}&$top=100",
            self.api_base,
            cal.provider_id,
            urlencode(time_min),
            urlencode(time_max),
            MS_EVENT_SELECT
        );
        let mut upserts = Vec::new();
        let mut next_token = None;
        loop {
            let (data, status) = self.get(&self.resolve(&url)).await?;
            if !status.is_success() {
                return Err(http_status_error("Graph calendarView", status, ""));
            }
            for ev in data.get("value").and_then(|v| v.as_array()).cloned().unwrap_or_default() {
                upserts.push(ms_event(&ev));
            }
            if let Some(d) = json_str(&data, "@odata.deltaLink") {
                next_token = Some(d);
            }
            match json_str(&data, "@odata.nextLink") {
                Some(next) => url = next,
                None => break,
            }
        }
        Ok((upserts, next_token))
    }

    fn resolve(&self, path_or_url: &str) -> String {
        if path_or_url.starts_with("http") {
            path_or_url.to_string()
        } else {
            format!("{}{}", self.api_base, path_or_url)
        }
    }

    /// An event with its times in its own `originalStartTimeZone` (Graph hands
    /// them back in UTC unless asked).
    async fn get_in_own_zone(&self, url: &str) -> Result<Value> {
        let (zone, status) = self.get(&format!("{url}?$select=originalStartTimeZone")).await?;
        if !status.is_success() {
            return Err(http_status_error("Graph get series", status, ""));
        }
        let tz = json_str(&zone, "originalStartTimeZone").unwrap_or_else(|| "UTC".into());
        let resp = self.token.get_with_prefer(url, &format!("outlook.timezone=\"{tz}\"")).await?;
        if !resp.status().is_success() {
            return Err(http_status_error("Graph get series", resp.status(), ""));
        }
        Ok(resp.json().await?)
    }

    async fn get(&self, url: &str) -> Result<(Value, reqwest::StatusCode)> {
        let resp = self.token.request(reqwest::Method::GET, url, None).await?;
        let status = resp.status();
        if status.is_success() {
            Ok((resp.json().await?, status))
        } else {
            let body = resp.text().await.unwrap_or_default();
            if body.contains("syncStateNotFound") {
                return Err(SyncError::CursorExpired);
            }
            Ok((Value::Null, status))
        }
    }
}

#[async_trait]
impl CalendarAdapter for MicrosoftCalendarAdapter {
    fn source(&self) -> &'static str {
        source::MICROSOFT
    }

    async fn list_calendars(&self) -> Result<Vec<UnifiedCalendar>> {
        let url = format!("{}/me/calendars", self.api_base);
        let (data, status) = self.get(&url).await?;
        if !status.is_success() {
            return Err(http_status_error("Graph calendars", status, ""));
        }
        let mut cals = Vec::new();
        for c in data.get("value").and_then(|v| v.as_array()).cloned().unwrap_or_default() {
            let id = json_str(&c, "id").unwrap_or_default();
            if id.is_empty() {
                continue;
            }
            let short: String = id.chars().take(32).collect();
            // Graph exposes `canEdit`; shared/subscribed calendars without write access
            // are false (create/update/delete 403). Absent → assume writable.
            let writable = c.get("canEdit").and_then(|v| v.as_bool()).unwrap_or(true);
            // Only an owner may share a calendar, so `canShare` is Graph's
            // closest answer to "is this mine?"; absent → fall back to write.
            let owned = c.get("canShare").and_then(|v| v.as_bool()).unwrap_or(writable);
            cals.push(UnifiedCalendar {
                conference_providers: string_list(c.get("allowedOnlineMeetingProviders"))
                    .iter()
                    .filter(|p| p == &conference::MS_TEAMS_PROVIDER)
                    .map(|_| conference::TEAMS.to_string())
                    .collect(),
                key: format!("cal_ms_{}_{}", self.account_key, sanitize(&short)),
                provider_id: id.clone(),
                name: json_str(&c, "name").unwrap_or_else(|| "Calendar".into()),
                color: ms_color_to_hex(json_str(&c, "color").as_deref().unwrap_or("auto")),
                is_primary: c.get("isDefaultCalendar").and_then(|p| p.as_bool()).unwrap_or(false),
                is_writable: writable,
                is_owned: owned,
            });
        }
        Ok(cals)
    }

    async fn sync_calendar(
        &self,
        cal: &UnifiedCalendar,
        cursor: &CalendarCursor,
    ) -> Result<CalendarSyncResult> {
        if let Some(token) = &cursor.token {
            // Delta sync.
            let mut url = token.clone();
            let mut upserts = Vec::new();
            let mut deletions = Vec::new();
            let next_token;
            loop {
                let (data, status) = self.get(&self.resolve(&url)).await?;
                if status == reqwest::StatusCode::GONE {
                    return Err(SyncError::CursorExpired);
                }
                if !status.is_success() {
                    return Err(http_status_error("Graph delta", status, ""));
                }
                for ev in data.get("value").and_then(|v| v.as_array()).cloned().unwrap_or_default() {
                    let id = json_str(&ev, "id").unwrap_or_default();
                    if ev.get("@removed").is_some() {
                        deletions.push(id);
                    } else {
                        upserts.push(ms_event(&ev));
                    }
                }
                match json_str(&data, "@odata.nextLink") {
                    Some(next) => url = next,
                    None => {
                        next_token = json_str(&data, "@odata.deltaLink");
                        break;
                    }
                }
            }
            return Ok(CalendarSyncResult { upserts, deletions, next_token, ..Default::default() });
        }

        // Full sync via calendarView (expands recurrences), then seed a deltaLink.
        let (time_min, time_max) = time_window();
        let (upserts, mut next_token) = self.calendar_view(cal, &time_min, &time_max).await?;
        let seen = upserts.iter().map(|e| e.provider_id.clone()).collect();

        // Seed a delta link for future incremental syncs if not already present.
        if next_token.is_none() {
            let delta_url = format!(
                "{}/me/calendars/{}/events/delta?$select={}&$top=1",
                self.api_base, cal.provider_id, MS_EVENT_SELECT
            );
            if let Ok((data, status)) = self.get(&delta_url).await {
                if status.is_success() {
                    next_token = json_str(&data, "@odata.deltaLink");
                }
            }
        }

        Ok(CalendarSyncResult {
            upserts,
            seen_provider_ids: Some(seen),
            next_token,
            ..Default::default()
        })
    }

    async fn list_events(&self, cal: &UnifiedCalendar, time_min: &str, time_max: &str)
        -> Result<Vec<UnifiedEvent>> {
        Ok(self.calendar_view(cal, time_min, time_max).await?.0)
    }

    async fn get_series(&self, _calendar_provider_id: &str, master_id: &str) -> Result<SeriesMaster> {
        // In the series' own zone, as the drag-move reads it: written back in
        // UTC the series would be re-homed and drift an hour across DST.
        let raw = self.get_in_own_zone(&format!("{}/me/events/{}", self.api_base, master_id)).await?;
        let rule = raw.get("recurrence").and_then(graph_rrule);
        let attendees = raw
            .get("attendees")
            .and_then(|a| a.as_array())
            .map(|a| a.iter().filter_map(|g| g.get("emailAddress").and_then(|e| json_str(e, "address"))).collect())
            .unwrap_or_default();
        // The full body, in its own content type — `bodyPreview` is a cut-off
        // plain-text excerpt and would mangle the notes.
        let body = raw.get("body");
        let description = body.and_then(|b| json_str(b, "content")).filter(|d| !d.trim().is_empty());
        let description_is_html = body
            .and_then(|b| json_str(b, "contentType"))
            .is_some_and(|t| t.eq_ignore_ascii_case("html"));
        Ok(SeriesMaster { raw, rule, attendees, description, description_is_html })
    }

    async fn update_series(
        &self,
        _calendar_provider_id: &str,
        master_id: &str,
        master: &SeriesMaster,
        draft: &EventDraft,
        shift: chrono::Duration,
    ) -> Result<()> {
        ms_check_rule(draft)?;
        let start = master.raw.get("start").ok_or_else(|| SyncError::Other("series master has no start".into()))?;
        let master_all_day = master.raw.get("isAllDay").and_then(|v| v.as_bool()).unwrap_or(false);
        let (new_start, new_end) = series_times(start, master_all_day, shift, draft, false)?;
        let mut body = ms_event_body(&EventDraft { recurrence: None, ..draft.clone() });
        body.as_object_mut().map(|b| b.remove("attendees"));
        if let Some(a) = Some(&draft.attendees).filter(|w| !w.is_empty() || draft.attendees_cleared).and_then(|w| {
            merged_attendees(
                master.raw.get("attendees"),
                w,
                |a| a.get("emailAddress").and_then(|e| json_str(e, "address")),
                |e| serde_json::json!({ "emailAddress": { "address": e }, "type": "required" }),
            )
        }) {
            body["attendees"] = a;
        }
        body["end"] = new_end;
        if let Some(rec) = draft.recurrence.as_deref().and_then(|r| ms_recurrence(r, &new_start, draft_offset(draft))) {
            body["recurrence"] = rec;
        }
        body["start"] = new_start;
        let url = format!("{}/me/events/{}", self.api_base, master_id);
        let resp = self.token.request(reqwest::Method::PATCH, &url, Some(&body)).await?;
        if !resp.status().is_success() {
            let status = resp.status();
            let detail = resp.text().await.unwrap_or_default();
            return Err(http_status_error("Microsoft update series", status, &detail));
        }
        Ok(())
    }

    async fn ended_recurrence(
        &self,
        _calendar_provider_id: &str,
        master: &SeriesMaster,
        instance_id: &str,
        instance_start: &str,
    ) -> Result<Option<SeriesEnd>> {
        // Graph's range ends on a date in the series' zone, so read the
        // instance there too rather than guessing its local day from UTC.
        let tz = master.raw.get("start").and_then(|s| json_str(s, "timeZone")).unwrap_or_else(|| "UTC".into());
        let resp = self
            .token
            .get_with_prefer(&format!("{}/me/events/{}", self.api_base, instance_id), &format!("outlook.timezone=\"{tz}\""))
            .await?;
        if !resp.status().is_success() {
            return Err(http_status_error("Graph get instance", resp.status(), ""));
        }
        let instance: Value = resp.json().await?;
        let wall = |ev: &Value| {
            ev.get("start")
                .and_then(|s| json_str(s, "dateTime"))
                .and_then(|d| chrono::NaiveDateTime::parse_from_str(&d, "%Y-%m-%dT%H:%M:%S%.f").ok())
        };
        let (Some(first), Some(moved_wall)) = (wall(&master.raw), wall(&instance)) else {
            return Err(SyncError::Other("series time is unreadable".into()));
        };
        // The split falls on the instance's ORIGINAL slot (UTC on Graph), read
        // in the series' zone with the same offset its current start has.
        let original = json_str(&instance, "originalStart").unwrap_or_else(|| instance_start.to_string());
        let original_at = instant(&original)
            .and_then(|t| chrono::DateTime::from_timestamp(t, 0))
            .ok_or_else(|| SyncError::Other("instance time is unreadable".into()))?;
        // Its day in the series' zone at that instant, with that date's own
        // DST rules — the moved occurrence's offset can be the other side of
        // a clock change. Only a zone neither table knows falls back to it.
        let cutoff_day = match named_zone(&tz) {
            Some(zone) => original_at.with_timezone(&zone).date_naive(),
            None => {
                let offset = moved_wall.and_utc().timestamp() - instant(instance_start).unwrap_or(moved_wall.and_utc().timestamp());
                (original_at + chrono::Duration::seconds(offset)).date_naive()
            }
        };
        if cutoff_day <= first.date() {
            return Ok(None);
        }
        let mut rec = master.raw.get("recurrence").cloned().ok_or_else(|| SyncError::Other("series has no rule".into()))?;
        // Counted off the pattern, not the instance list: Graph lists no
        // deleted occurrences, and those used up their place in the COUNT too.
        let done = match (rec.get("pattern"), json_str(&rec["range"], "startDate")) {
            (Some(pattern), Some(start)) if json_str(&rec["range"], "type").as_deref() == Some("numbered") => {
                let start = chrono::NaiveDate::parse_from_str(&start, "%Y-%m-%d").unwrap_or(first.date());
                graph_count_before(pattern, start, cutoff_day)
            }
            _ => 0,
        };
        rec["range"]["type"] = "endDate".into();
        rec["range"]["endDate"] = (cutoff_day - chrono::Duration::days(1)).format("%Y-%m-%d").to_string().into();
        if let Some(r) = rec["range"].as_object_mut() {
            r.remove("numberOfOccurrences");
        }
        Ok(Some(SeriesEnd { body: serde_json::json!({ "recurrence": rec }), cutoff: original, done }))
    }

    async fn carry_exceptions(
        &self,
        _calendar_provider_id: &str,
        old_master_id: &str,
        new_master_id: &str,
        master: &SeriesMaster,
        cutoff: &str,
    ) -> Result<()> {
        // Graph's v1.0 instance list leaves deleted occurrences out, so they're
        // found by absence: a slot the new series has (the slots are the
        // same) that no old occurrence was generated for was deleted there,
        // and is deleted on the new series too.
        let from = chrono::DateTime::from_timestamp(instant(cutoff).unwrap_or(0), 0)
            .ok_or_else(|| SyncError::Other("bad cutoff".into()))?;
        // Up to the series' end date, else ten years out.
        let to = master
            .raw
            .get("recurrence")
            .and_then(|r| r.get("range"))
            .and_then(|r| json_str(r, "endDate"))
            .and_then(|d| chrono::NaiveDate::parse_from_str(&d, "%Y-%m-%d").ok())
            .map(|d| (d + chrono::Duration::days(2)).and_hms_opt(0, 0, 0).unwrap().and_utc())
            // ponytail: an open-ended series is read ten years out — Graph has
            // no unbounded instance list, and an edited occurrence further
            // ahead than that is not one anybody has.
            .unwrap_or(from + chrono::Duration::days(3653));
        let window = |id: &str, select: &str, since: chrono::DateTime<chrono::Utc>, until: chrono::DateTime<chrono::Utc>| {
            format!(
                "{}/me/events/{}/instances?startDateTime={}&endDateTime={}&$select={select}&$top=999",
                self.api_base,
                id,
                urlencode(&since.format("%Y-%m-%dT%H:%M:%SZ").to_string()),
                urlencode(&until.format("%Y-%m-%dT%H:%M:%SZ").to_string())
            )
        };
        let list = |url: String| async move {
            let mut out = Vec::new();
            let mut next = Some(url);
            while let Some(u) = next.take() {
                let (data, status) = self.get(&u).await?;
                if !status.is_success() {
                    return Err(http_status_error("Graph series instances", status, ""));
                }
                out.extend(data.get("value").and_then(|v| v.as_array()).cloned().unwrap_or_default());
                next = json_str(&data, "@odata.nextLink");
            }
            Ok::<_, SyncError>(out)
        };
        // The window filters by an occurrence's CURRENT time; one moved to
        // before the cutoff still belongs after it by its slot, so look a year
        // back and keep those whose `originalStart` is at or after the cutoff.
        let year = chrono::Duration::days(366);
        let old = list(window(old_master_id, "type,start,end,originalStart,subject,location,body,attendees", from - year, to + year)).await?;
        let start_of = |i: &Value| i.get("start").and_then(|s| json_str(s, "dateTime")).and_then(|s| instant(&s));
        // Each old occurrence's own slot: an exception's original one, an
        // ordinary occurrence's start.
        let slot_of = |i: &Value| json_str(i, "originalStart").and_then(|s| instant(&s)).or_else(|| start_of(i));
        let old_slots: HashSet<i64> = old.iter().filter_map(slot_of).collect();
        // A slot only counts as deleted where the old series reached: its
        // endDate, else (a COUNT) its last listed occurrence; open-ended has
        // no limit. A new half with a later end has slots the old one never
        // had, and they aren't deletions.
        let range = master.raw.get("recurrence").and_then(|r| r.get("range"));
        // The old series' last day, ended in its own recurrence zone: an
        // endDate as given; a COUNT's from the pattern, so deleted tail
        // occurrences still count as the old series'.
        // Without a recurrenceTimeZone, Graph reads the range in the event's
        // own zone (the master's start), and only then UTC.
        let rec_zone = range
            .and_then(|r| json_str(r, "recurrenceTimeZone"))
            .or_else(|| master.raw.get("start").and_then(|s| json_str(s, "timeZone")))
            .unwrap_or_else(|| "UTC".into());
        let date = |k: &str| range.and_then(|r| json_str(r, k)).and_then(|d| chrono::NaiveDate::parse_from_str(&d, "%Y-%m-%d").ok());
        let last_day = match range.and_then(|r| json_str(r, "type")).as_deref() {
            Some("endDate") => date("endDate"),
            Some("numbered") => {
                let count = range.and_then(|r| r.get("numberOfOccurrences")).and_then(|v| v.as_u64()).unwrap_or(0);
                master.raw.get("recurrence").and_then(|r| r.get("pattern")).zip(date("startDate"))
                    .and_then(|(p, s)| graph_nth_day(p, s, count))
            }
            _ => None,
        };
        let old_end: i64 = last_day.map_or(i64::MAX, |d| end_of_day(d, &rec_zone));
        let exceptions: Vec<Value> = old
            .into_iter()
            .filter(|i| json_str(i, "type").as_deref() == Some("exception"))
            .filter(|i| slot_of(i).is_some_and(|t| t >= from.timestamp()))
            .collect();
        let fresh = list(window(new_master_id, "id,start", from, to)).await?;
        for gone in fresh.iter().filter(|i| start_of(i).is_some_and(|t| t >= from.timestamp() && t < old_end && !old_slots.contains(&t))) {
            let Some(id) = json_str(gone, "id") else { continue };
            let resp = self.token.request(reqwest::Method::DELETE, &format!("{}/me/events/{}", self.api_base, id), None).await?;
            if !resp.status().is_success() && resp.status() != reqwest::StatusCode::NOT_FOUND {
                return Err(http_status_error("Microsoft carry deletion", resp.status(), ""));
            }
        }
        for exc in exceptions {
            let Some(orig) = json_str(&exc, "originalStart").and_then(|s| instant(&s)) else { continue };
            let Some(target) = fresh.iter().find(|i| start_of(i) == Some(orig)).and_then(|i| json_str(i, "id")) else { continue };
            // Only what this occurrence changed, so the split's own edits stand.
            let mut body = serde_json::json!({});
            if start_of(&exc) != Some(orig) {
                for key in ["start", "end"] {
                    if let Some(v) = exc.get(key) {
                        body[key] = v.clone();
                    }
                }
            }
            for key in ["subject", "location", "body", "attendees"] {
                if exc.get(key) != master.raw.get(key) {
                    body[key] = exc.get(key).cloned().unwrap_or(Value::Null);
                }
            }
            if body.as_object().is_some_and(|b| b.is_empty()) {
                continue;
            }
            let url = format!("{}/me/events/{}", self.api_base, target);
            let resp = self.token.request(reqwest::Method::PATCH, &url, Some(&body)).await?;
            if !resp.status().is_success() {
                let status = resp.status();
                let detail = resp.text().await.unwrap_or_default();
                return Err(http_status_error("Microsoft carry exception", status, &detail));
            }
        }
        Ok(())
    }

    async fn patch_series(&self, _calendar_provider_id: &str, master_id: &str, body: &Value) -> Result<()> {
        let url = format!("{}/me/events/{}", self.api_base, master_id);
        let resp = self.token.request(reqwest::Method::PATCH, &url, Some(body)).await?;
        if !resp.status().is_success() {
            let status = resp.status();
            let detail = resp.text().await.unwrap_or_default();
            return Err(http_status_error("Microsoft end series", status, &detail));
        }
        Ok(())
    }

    async fn create_event(&self, calendar_provider_id: &str, draft: &EventDraft) -> Result<String> {
        ms_check_rule(draft)?;
        let url = format!("{}/me/calendars/{}/events", self.api_base, calendar_provider_id);
        let body = ms_event_body(draft);
        let resp = self.token.request(reqwest::Method::POST, &url, Some(&body)).await?;
        if !resp.status().is_success() {
            let status = resp.status();
            let detail = resp.text().await.unwrap_or_default();
            return Err(http_status_error("Microsoft create event", status, &detail));
        }
        let data: Value = resp.json().await?;
        json_str(&data, "id").ok_or_else(|| SyncError::Other("created event has no id".into()))
    }

    async fn update_event(
        &self,
        _calendar_provider_id: &str,
        event_provider_id: &str,
        draft: &EventDraft,
    ) -> Result<()> {
        ms_check_rule(draft)?;
        // Graph addresses events globally by id, independent of calendar.
        let url = format!("{}/me/events/{}", self.api_base, event_provider_id);
        let mut body = ms_event_body(draft);
        if body.get("attendees").is_some() {
            // Kept guests keep their RSVPs: reuse the event's own entries.
            let (current, status) = self.get(&format!("{url}?$select=attendees")).await?;
            if !status.is_success() {
                return Err(http_status_error("Graph get event", status, ""));
            }
            match merged_attendees(
                current.get("attendees"),
                &draft.attendees,
                |a| a.get("emailAddress").and_then(|e| json_str(e, "address")),
                |e| serde_json::json!({ "emailAddress": { "address": e }, "type": "required" }),
            ) {
                Some(a) => body["attendees"] = a,
                None => {
                    body.as_object_mut().map(|b| b.remove("attendees"));
                }
            }
        }
        let resp = self.token.request(reqwest::Method::PATCH, &url, Some(&body)).await?;
        if !resp.status().is_success() {
            let status = resp.status();
            let detail = resp.text().await.unwrap_or_default();
            return Err(http_status_error("Microsoft update event", status, &detail));
        }
        Ok(())
    }

    async fn reschedule_event(
        &self,
        _calendar_provider_id: &str,
        event_provider_id: &str,
        r: &Reschedule,
    ) -> Result<()> {
        // ponytail: Graph mails attendees on every organizer change; `r.notify`
        // has no Graph equivalent, so the client doesn't offer "Don't send" here.
        let (target, body) = match &r.series_id {
            Some(master_id) => {
                // Graph hands times back in UTC unless asked for a zone. Shifting
                // and writing back UTC would re-home the series in UTC, and every
                // occurrence across a DST change would land an hour off — so read
                // the master in its own zone and write it back in that zone.
                let master = self.get_in_own_zone(&format!("{}/me/events/{}", self.api_base, master_id)).await?;
                let (start, end) = shifted_series_times(&master, r)?;
                (master_id.as_str(), serde_json::json!({ "start": start, "end": end }))
            }
            None => {
                // Graph wants a bare wall clock plus its zone; an all-day event
                // runs midnight to midnight in that zone.
                let when = |at: &str| {
                    let wall = if r.all_day {
                        format!("{at}T00:00:00")
                    } else {
                        chrono::DateTime::parse_from_rfc3339(at)
                            .map(|t| t.naive_utc().format("%Y-%m-%dT%H:%M:%S").to_string())
                            .unwrap_or_else(|_| at.to_string())
                    };
                    let tz = if r.all_day { r.tz() } else { "UTC".to_string() };
                    serde_json::json!({ "dateTime": wall, "timeZone": tz })
                };
                (event_provider_id, serde_json::json!({ "start": when(&r.start_at), "end": when(&r.end_at) }))
            }
        };
        let url = format!("{}/me/events/{}", self.api_base, target);
        let resp = self.token.request(reqwest::Method::PATCH, &url, Some(&body)).await?;
        if !resp.status().is_success() {
            let status = resp.status();
            let detail = resp.text().await.unwrap_or_default();
            return Err(http_status_error("Microsoft reschedule event", status, &detail));
        }
        Ok(())
    }

    async fn delete_event(&self, _calendar_provider_id: &str, event_provider_id: &str) -> Result<()> {
        let url = format!("{}/me/events/{}", self.api_base, event_provider_id);
        let resp = self.token.request(reqwest::Method::DELETE, &url, None).await?;
        let status = resp.status();
        if !status.is_success() && status != reqwest::StatusCode::NOT_FOUND {
            return Err(http_status_error("Microsoft delete event", status, ""));
        }
        Ok(())
    }

    async fn respond_event(
        &self,
        _calendar_provider_id: &str,
        event_provider_id: &str,
        response: &str,
    ) -> Result<()> {
        let action = ms_response_action(response)?;
        let url = format!("{}/me/events/{}/{}", self.api_base, event_provider_id, action);
        let body = serde_json::json!({ "sendResponse": true });
        let resp = self.token.request(reqwest::Method::POST, &url, Some(&body)).await?;
        if !resp.status().is_success() {
            let status = resp.status();
            let detail = resp.text().await.unwrap_or_default();
            return Err(http_status_error("Microsoft RSVP", status, &detail));
        }
        Ok(())
    }
}

fn ms_event(ev: &Value) -> UnifiedEvent {
    let start_obj = ev.get("start");
    let start = start_obj.and_then(|s| json_str(s, "dateTime")).unwrap_or_default();
    let end = ev.get("end").and_then(|e| json_str(e, "dateTime")).unwrap_or_default();
    let all_day = ev.get("isAllDay").and_then(|v| v.as_bool()).unwrap_or(false);
    let timezone = start_obj.and_then(|s| json_str(s, "timeZone")).unwrap_or_else(|| "UTC".into());

    let attendees: Vec<Value> = ev
        .get("attendees")
        .and_then(|a| a.as_array())
        .map(|arr| {
            arr.iter()
                .map(|a| {
                    let ea = a.get("emailAddress");
                    serde_json::json!({
                        "email": ea.and_then(|e| json_str(e, "address")),
                        "name": ea.and_then(|e| json_str(e, "name")),
                        "responseStatus": ms_response_to_standard(
                            a.get("status").and_then(|s| json_str(s, "response")).as_deref()
                        ),
                        "type": json_str(a, "type"),
                    })
                })
                .collect()
        })
        .unwrap_or_default();
    let metadata = serde_json::json!({
        "attendees": attendees,
        "webLink": json_str(ev, "webLink"),
        "conference": ms_conference(ev),
        "seriesId": json_str(ev, "seriesMasterId"),
    });

    let organizer = ev.get("organizer").and_then(|o| o.get("emailAddress"));

    UnifiedEvent {
        provider_id: json_str(ev, "id").unwrap_or_default(),
        title: json_str(ev, "subject").unwrap_or_else(|| "(No title)".into()),
        description: ev.get("body").and_then(|b| json_str(b, "content")),
        location: ev.get("location").and_then(|l| json_str(l, "displayName")),
        start_at: start,
        end_at: end,
        all_day,
        timezone,
        status: "confirmed".into(),
        etag: None,
        ical_uid: json_str(ev, "iCalUId"),
        recurrence_rule: None,
        organizer_email: organizer.and_then(|o| json_str(o, "address")),
        organizer_name: organizer.and_then(|o| json_str(o, "name")),
        metadata: Some(metadata.to_string()),
    }
}

fn ms_color_to_hex(color: &str) -> String {
    match color {
        "lightBlue" => "#60A5FA",
        "lightGreen" => "#4ADE80",
        "lightOrange" => "#FB923C",
        "lightGray" => "#9CA3AF",
        "lightYellow" => "#FDE047",
        "lightTeal" => "#2DD4BF",
        "lightPink" => "#F472B6",
        "lightRed" => "#EF4444",
        "maxGreen" => "#22C55E",
        "maxRed" => "#DC2626",
        _ => "#3B82F6",
    }
    .to_string()
}

fn ms_response_to_standard(response: Option<&str>) -> &'static str {
    match response {
        Some("organizer") | Some("accepted") => "accepted",
        Some("tentativelyAccepted") => "tentative",
        Some("declined") => "declined",
        _ => "needs_action",
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::sync::model::ProviderType;
    use crate::sync::store::SyncStore;
    use tokio::sync::RwLock;
    use wiremock::matchers::{method, path, query_param};
    use wiremock::{Mock, MockServer, ResponseTemplate};

    fn google_adapter(server: &MockServer) -> GoogleCalendarAdapter {
        let store = Arc::new(SyncStore::new_in_memory().unwrap());
        let creds = crate::sync::model::ProviderCredentials::OAuth2 {
            username: "u@gmail.com".into(),
            access_token: "tok".into(),
            refresh_token: None,
        };
        let token = Arc::new(TokenManager::new(
            "acc".into(),
            ProviderType::Gmail,
            store,
            Arc::new(RwLock::new(None)),
            &creds,
        ));
        GoogleCalendarAdapter::new(token, "acc".into()).with_base(format!("{}/calendar/v3", server.uri()))
    }

    #[tokio::test]
    async fn google_list_calendars() {
        let server = MockServer::start().await;
        Mock::given(method("GET"))
            .and(path("/calendar/v3/users/me/calendarList"))
            .respond_with(ResponseTemplate::new(200).set_body_json(serde_json::json!({
                "items": [
                    { "id": "primary@gmail.com", "summary": "Me", "primary": true, "backgroundColor": "#fff",
                      "accessRole": "owner",
                      "conferenceProperties": { "allowedConferenceSolutionTypes": ["hangoutsMeet"] } },
                    { "id": "team@group.calendar.google.com", "summary": "Team",
                      "conferenceProperties": { "allowedConferenceSolutionTypes": ["eventHangout"] } },
                    { "id": "ali@work.com", "summary": "Transferred from ali", "accessRole": "writer" }
                ]
            })))
            .mount(&server)
            .await;
        let cals = google_adapter(&server).list_calendars().await.unwrap();
        assert_eq!(cals.len(), 3);
        assert!(cals[0].is_primary);
        assert_eq!(cals[0].provider_id, "primary@gmail.com");
        // Meet is offerable here; the retired classic Hangouts is not a video
        // call we can create, so that calendar offers nothing.
        assert_eq!(cals[0].conference_providers, vec![conference::MEET]);
        assert!(cals[1].conference_providers.is_empty());
        // Someone else's calendar shared with write access: writable, not ours.
        assert!(cals[0].is_owned);
        assert!(cals[2].is_writable);
        assert!(!cals[2].is_owned);
    }

    fn ms_adapter(server: &MockServer) -> MicrosoftCalendarAdapter {
        let store = Arc::new(SyncStore::new_in_memory().unwrap());
        let creds = crate::sync::model::ProviderCredentials::OAuth2 {
            username: "u@outlook.com".into(),
            access_token: "tok".into(),
            refresh_token: None,
        };
        let token = Arc::new(TokenManager::new(
            "acc".into(),
            ProviderType::Microsoft,
            store,
            Arc::new(RwLock::new(None)),
            &creds,
        ));
        MicrosoftCalendarAdapter::new(token, "acc".into()).with_base(format!("{}/v1.0", server.uri()))
    }

    #[tokio::test]
    async fn microsoft_list_calendars_reads_teams_availability() {
        let server = MockServer::start().await;
        Mock::given(method("GET"))
            .and(path("/v1.0/me/calendars"))
            .respond_with(ResponseTemplate::new(200).set_body_json(serde_json::json!({
                "value": [
                    { "id": "cal1", "name": "Calendar", "isDefaultCalendar": true, "canEdit": true,
                      "allowedOnlineMeetingProviders": ["teamsForBusiness"] },
                    // A consumer mailbox: writable, but Teams is not on offer —
                    // asking for one would 400 the whole create.
                    { "id": "cal2", "name": "Personal", "canEdit": true,
                      "allowedOnlineMeetingProviders": ["skypeForConsumer"] }
                ]
            })))
            .mount(&server)
            .await;
        let cals = ms_adapter(&server).list_calendars().await.unwrap();
        assert_eq!(cals[0].conference_providers, vec![conference::TEAMS]);
        assert!(cals[1].conference_providers.is_empty());
    }

    fn sample_draft() -> EventDraft {
        EventDraft {
            title: "Sync".into(),
            start_at: "2026-05-30T14:00:00Z".into(),
            end_at: "2026-05-30T15:00:00Z".into(),
            attendees: vec!["a@x.com".into()],
            ..Default::default()
        }
    }

    #[tokio::test]
    async fn google_create_event_returns_id() {
        let server = MockServer::start().await;
        Mock::given(method("POST"))
            .and(path("/calendar/v3/calendars/primary/events"))
            .respond_with(ResponseTemplate::new(200).set_body_json(serde_json::json!({ "id": "newid" })))
            .mount(&server)
            .await;
        let id = google_adapter(&server).create_event("primary", &sample_draft()).await.unwrap();
        assert_eq!(id, "newid");
        // Attendees only hear about the event when the insert asks for it.
        let q = server.received_requests().await.unwrap()[0].url.query().unwrap().to_string();
        assert!(q.contains("sendUpdates=all"), "query was {q}");
    }

    #[tokio::test]
    async fn google_delete_event_ok() {
        let server = MockServer::start().await;
        Mock::given(method("DELETE"))
            .and(path("/calendar/v3/calendars/primary/events/e1"))
            .respond_with(ResponseTemplate::new(204))
            .mount(&server)
            .await;
        google_adapter(&server).delete_event("primary", "e1").await.unwrap();
    }

    #[tokio::test]
    async fn google_rsvp_patches_self_attendee() {
        let server = MockServer::start().await;
        Mock::given(method("GET"))
            .and(path("/calendar/v3/calendars/primary/events/e1"))
            .respond_with(ResponseTemplate::new(200).set_body_json(serde_json::json!({
                "id": "e1",
                "attendees": [
                    { "email": "u@gmail.com", "self": true, "responseStatus": "needsAction" },
                    { "email": "other@x.com" }
                ]
            })))
            .mount(&server)
            .await;
        Mock::given(method("PATCH"))
            .and(path("/calendar/v3/calendars/primary/events/e1"))
            .respond_with(ResponseTemplate::new(200).set_body_json(serde_json::json!({ "id": "e1" })))
            .mount(&server)
            .await;
        google_adapter(&server).respond_event("primary", "e1", "accepted").await.unwrap();
    }

    #[tokio::test]
    async fn microsoft_create_event_returns_id() {
        let server = MockServer::start().await;
        Mock::given(method("POST"))
            .and(path("/v1.0/me/calendars/cal1/events"))
            .respond_with(ResponseTemplate::new(201).set_body_json(serde_json::json!({ "id": "msid" })))
            .mount(&server)
            .await;
        let id = ms_adapter(&server).create_event("cal1", &sample_draft()).await.unwrap();
        assert_eq!(id, "msid");
    }

    #[tokio::test]
    async fn microsoft_rsvp_posts_accept() {
        let server = MockServer::start().await;
        Mock::given(method("POST"))
            .and(path("/v1.0/me/events/ev9/accept"))
            .respond_with(ResponseTemplate::new(202))
            .mount(&server)
            .await;
        ms_adapter(&server).respond_event("cal1", "ev9", "accepted").await.unwrap();
    }

    #[tokio::test]
    async fn google_full_sync_collects_events_and_sync_token() {
        let server = MockServer::start().await;
        Mock::given(method("GET"))
            .and(path("/calendar/v3/calendars/primary/events"))
            .respond_with(ResponseTemplate::new(200).set_body_json(serde_json::json!({
                "items": [
                    { "id": "e1", "summary": "Standup", "start": { "dateTime": "2024-01-01T09:00:00Z" }, "end": { "dateTime": "2024-01-01T09:30:00Z" }, "status": "confirmed" },
                    { "id": "e2", "summary": "All day", "start": { "date": "2024-01-02" }, "end": { "date": "2024-01-03" } }
                ],
                "nextSyncToken": "sync-1"
            })))
            .mount(&server)
            .await;
        let cal = UnifiedCalendar {
            key: "cal_gcal_acc_primary".into(),
            provider_id: "primary".into(),
            name: "Me".into(),
            color: "#fff".into(),
            is_primary: true,
            is_writable: true,
            is_owned: true,
            conference_providers: vec![],
        };
        let r = google_adapter(&server).sync_calendar(&cal, &CalendarCursor::default()).await.unwrap();
        assert_eq!(r.upserts.len(), 2);
        assert_eq!(r.next_token.as_deref(), Some("sync-1"));
        assert!(r.seen_provider_ids.as_ref().unwrap().contains("e1"));
        let allday = r.upserts.iter().find(|e| e.provider_id == "e2").unwrap();
        assert!(allday.all_day);
    }

    #[tokio::test]
    async fn google_incremental_handles_cancelled_and_410() {
        let server = MockServer::start().await;
        // Incremental call with syncToken returns a cancelled event.
        Mock::given(method("GET"))
            .and(path("/calendar/v3/calendars/primary/events"))
            .and(query_param("syncToken", "sync-1"))
            .respond_with(ResponseTemplate::new(200).set_body_json(serde_json::json!({
                "items": [ { "id": "e1", "status": "cancelled" } ],
                "nextSyncToken": "sync-2"
            })))
            .mount(&server)
            .await;
        let cal = UnifiedCalendar {
            key: "k".into(),
            provider_id: "primary".into(),
            name: "Me".into(),
            color: "#fff".into(),
            is_primary: true,
            is_writable: true,
            is_owned: true,
            conference_providers: vec![],
        };
        let cursor = CalendarCursor { token: Some("sync-1".into()) };
        let r = google_adapter(&server).sync_calendar(&cal, &cursor).await.unwrap();
        assert_eq!(r.deletions, vec!["e1"]);
        assert_eq!(r.next_token.as_deref(), Some("sync-2"));

        // Expired token → 410 → CursorExpired.
        let server2 = MockServer::start().await;
        Mock::given(method("GET"))
            .and(path("/calendar/v3/calendars/primary/events"))
            .respond_with(ResponseTemplate::new(410))
            .mount(&server2)
            .await;
        let expired = CalendarCursor { token: Some("old".into()) };
        assert!(matches!(
            google_adapter(&server2).sync_calendar(&cal, &expired).await.unwrap_err(),
            SyncError::CursorExpired
        ));
    }

    #[test]
    fn recurrence_reaches_both_providers() {
        // Mon 26 Oct and Wed 28 Oct at 14:00 Amsterdam, then stop.
        let draft = EventDraft {
            title: "Musa".into(),
            start_at: "2026-10-26T14:00:00+01:00".into(),
            end_at: "2026-10-26T14:30:00+01:00".into(),
            timezone: Some("Europe/Amsterdam".into()),
            recurrence: Some("FREQ=WEEKLY;BYDAY=MO,WE;COUNT=2".into()),
            ..Default::default()
        };
        assert_eq!(google_event_body(&draft)["recurrence"], serde_json::json!(["RRULE:FREQ=WEEKLY;BYDAY=MO,WE;COUNT=2"]));
        let m = ms_event_body(&draft);
        assert_eq!(m["start"], serde_json::json!({ "dateTime": "2026-10-26T14:00:00", "timeZone": "Europe/Amsterdam" }));
        assert_eq!(m["recurrence"]["pattern"]["type"], "weekly");
        assert_eq!(m["recurrence"]["pattern"]["daysOfWeek"], serde_json::json!(["monday", "wednesday"]));
        assert_eq!(m["recurrence"]["range"], serde_json::json!({
            "type": "numbered", "numberOfOccurrences": 2, "startDate": "2026-10-26",
            "recurrenceTimeZone": "Europe/Amsterdam",
        }));
        // Read back off Graph, it is the same rule.
        assert_eq!(graph_rrule(&m["recurrence"]).as_deref(), Some("FREQ=WEEKLY;BYDAY=MO,WE;COUNT=2"));

        let monthly = EventDraft { recurrence: Some("FREQ=MONTHLY;INTERVAL=2;UNTIL=20270331T225959Z".into()), ..draft.clone() };
        let r = &ms_event_body(&monthly)["recurrence"];
        assert_eq!(r["pattern"], serde_json::json!({ "type": "absoluteMonthly", "interval": 2, "dayOfMonth": 26 }));
        assert_eq!(r["range"]["endDate"], "2027-03-31");
        assert_eq!(graph_rrule(r).as_deref(), Some("FREQ=MONTHLY;BYMONTHDAY=26;INTERVAL=2;UNTIL=20270331"));

        // "Until 30 Nov" written in New York is 04:59Z on 1 Dec; Graph's local
        // endDate must still be the 30th, or a 1 Dec occurrence sneaks in.
        let new_york = EventDraft {
            start_at: "2026-10-26T09:00:00-04:00".into(),
            end_at: "2026-10-26T09:30:00-04:00".into(),
            timezone: Some("America/New_York".into()),
            recurrence: Some("FREQ=DAILY;UNTIL=20261201T045959Z".into()),
            ..draft.clone()
        };
        assert_eq!(ms_event_body(&new_york)["recurrence"]["range"]["endDate"], "2026-11-30");
        // A just-after-midnight series whose UNTIL is its last start keeps that day.
        let night = EventDraft {
            start_at: "2026-10-26T00:30:00+01:00".into(),
            end_at: "2026-10-26T01:00:00+01:00".into(),
            timezone: Some("Europe/Amsterdam".into()),
            recurrence: Some("FREQ=DAILY;UNTIL=20261030T233000Z".into()), // 31 Oct 00:30 CET
            ..draft.clone()
        };
        assert_eq!(ms_event_body(&night)["recurrence"]["range"]["endDate"], "2026-10-31");
        // …and one ending at 23:59 the day before does not reach into it.
        let night_before = EventDraft { recurrence: Some("FREQ=DAILY;UNTIL=20261030T225959Z".into()), ..night.clone() };
        assert_eq!(ms_event_body(&night_before)["recurrence"]["range"]["endDate"], "2026-10-30");
        // A Graph series in a Windows zone, summer start, ending after the clocks
        // go back: 30 Nov 23:59:59 CET is 22:59:59Z, still the 30th there (the
        // summer offset would read 1 Dec 00:59 and add a 1 Dec 00:30 occurrence).
        let windows = serde_json::json!({ "dateTime": "2026-06-01T00:30:00", "timeZone": "W. Europe Standard Time" });
        let r = ms_recurrence("FREQ=DAILY;UNTIL=20261130T225959Z", &windows, chrono::FixedOffset::east_opt(7200)).unwrap();
        assert_eq!(r["range"]["endDate"], "2026-11-30");

        // "Last Friday of the month" survives the round trip instead of
        // collapsing into "the 26th".
        let last_friday = EventDraft { recurrence: Some("FREQ=MONTHLY;BYDAY=-1FR".into()), ..draft.clone() };
        let r = &ms_event_body(&last_friday)["recurrence"];
        assert_eq!(r["pattern"]["type"], "relativeMonthly");
        assert_eq!(r["pattern"]["index"], "last");
        assert_eq!(graph_rrule(r).as_deref(), Some("FREQ=MONTHLY;BYDAY=-1FR"));

        let one_off = EventDraft { recurrence: None, ..draft };
        assert!(google_event_body(&one_off).get("recurrence").is_none());
        assert!(ms_event_body(&one_off).get("recurrence").is_none());
    }

    #[test]
    fn graph_gets_a_bare_wall_clock_in_its_own_zone() {
        // London's winter offset is zero: 14:00Z is 14:00 London, and stays in
        // London's zone so a repeat keeps 14:00 after the clocks change.
        assert_eq!(ms_when("2026-10-26T14:00:00Z", false, "Europe/London"),
            serde_json::json!({ "dateTime": "2026-10-26T14:00:00", "timeZone": "Europe/London" }));
        assert_eq!(ms_when("2026-10-26T14:00:00+01:00", false, "Europe/Amsterdam"),
            serde_json::json!({ "dateTime": "2026-10-26T14:00:00", "timeZone": "Europe/Amsterdam" }));
        assert_eq!(ms_when("2026-10-26", true, "Europe/Amsterdam"),
            serde_json::json!({ "dateTime": "2026-10-26T00:00:00", "timeZone": "Europe/Amsterdam" }));
    }

    #[test]
    fn extra_dates_split_at_the_cutoff() {
        let lines = vec![
            "EXDATE;TZID=Europe/Amsterdam:20261102T140000,20261111T140000".to_string(),
            "RDATE:20261020T130000Z".to_string(),
            "RDATE;VALUE=DATE:20261201".to_string(),
        ];
        let cutoff = instant("2026-11-04T14:00:00+01:00").unwrap();
        let (before, after) = split_date_lines(&lines, cutoff, "Europe/Amsterdam");
        assert_eq!(before, vec!["EXDATE;TZID=Europe/Amsterdam:20261102T140000", "RDATE:20261020T130000Z"]);
        assert_eq!(after, vec!["EXDATE;TZID=Europe/Amsterdam:20261111T140000", "RDATE;VALUE=DATE:20261201"]);
    }

    #[test]
    fn graph_refuses_what_it_cant_repeat() {
        let start = serde_json::json!({ "dateTime": "2026-10-13T10:00:00", "timeZone": "Europe/Amsterdam" });
        // "2nd Tuesday" written with BYSETPOS is still the nth weekday.
        let r = ms_recurrence("FREQ=MONTHLY;BYDAY=TU;BYSETPOS=2", &start, None).unwrap();
        assert_eq!(r["pattern"]["type"], "relativeMonthly");
        assert_eq!(r["pattern"]["index"], "second");
        for rule in ["FREQ=MONTHLY;BYDAY=TU", "FREQ=MONTHLY;BYDAY=1TU,3TH", "FREQ=WEEKLY;BYDAY=MO;BYHOUR=9",
                     "FREQ=MONTHLY;BYDAY=2MO,2TU", "FREQ=WEEKLY;BYDAY=MO;BYMONTH=1", "FREQ=MONTHLY;BYMONTH=1",
                     "FREQ=MONTHLY;BYMONTHDAY=1,15", "FREQ=HOURLY", "FREQ=DAILY;BYDAY=MO,TU"] {
            assert!(ms_unsupported(rule).is_some(), "{rule} should be refused");
            assert!(ms_recurrence(rule, &start, None).is_none());
        }
        let draft = EventDraft { recurrence: Some("FREQ=MONTHLY;BYDAY=TU".into()), ..Default::default() };
        assert!(ms_check_rule(&draft).unwrap_err().to_string().contains("Outlook can't repeat this way"));
    }

    #[test]
    fn a_series_edit_can_flip_all_day_on_both_providers() {
        let timed = serde_json::json!({ "dateTime": "2026-10-26T14:00:00+01:00", "timeZone": "Europe/Amsterdam" });
        let to_all_day = EventDraft {
            start_at: "2026-11-09".into(), end_at: "2026-11-10".into(), all_day: true,
            timezone: Some("Europe/Amsterdam".into()), ..Default::default()
        };
        let (s, e) = series_times(&timed, false, chrono::Duration::zero(), &to_all_day, true).unwrap();
        assert_eq!((s, e), (serde_json::json!({ "date": "2026-10-26" }), serde_json::json!({ "date": "2026-10-27" })));
        let graph_timed = serde_json::json!({ "dateTime": "2026-10-26T14:00:00.0000000", "timeZone": "W. Europe Standard Time" });
        let (s, _) = series_times(&graph_timed, false, chrono::Duration::zero(), &to_all_day, false).unwrap();
        assert_eq!(s, serde_json::json!({ "dateTime": "2026-10-26T00:00:00", "timeZone": "Europe/Amsterdam" }));

        // And back: the draft's own time of day on the series' first day.
        let all_day = serde_json::json!({ "date": "2026-10-26" });
        let to_timed = EventDraft {
            start_at: "2026-11-09T09:30:00+01:00".into(), end_at: "2026-11-09T10:00:00+01:00".into(),
            timezone: Some("Europe/Amsterdam".into()), ..Default::default()
        };
        let (s, e) = series_times(&all_day, true, chrono::Duration::zero(), &to_timed, true).unwrap();
        assert_eq!(s, serde_json::json!({ "dateTime": "2026-10-26T09:30:00", "timeZone": "Europe/Amsterdam" }));
        assert_eq!(e["dateTime"], "2026-10-26T10:00:00");
    }

    #[test]
    fn a_numbered_graph_series_ends_on_its_counted_day() {
        let d = |s: &str| chrono::NaiveDate::parse_from_str(s, "%Y-%m-%d").unwrap();
        let weekly = serde_json::json!({ "type": "weekly", "interval": 1, "daysOfWeek": ["monday", "wednesday"], "firstDayOfWeek": "monday" });
        // Mon 26, Wed 28, Mon 2, Wed 4 — the 4th is the end even if it was deleted.
        assert_eq!(graph_nth_day(&weekly, d("2026-10-26"), 4), Some(d("2026-11-04")));
        // End of 4 Nov in Amsterdam (CET) is 23:00Z, not UTC midnight.
        assert_eq!(end_of_day(d("2026-11-04"), "W. Europe Standard Time"), instant("2026-11-04T23:00:00Z").unwrap());
    }

    #[test]
    fn graph_week_start_round_trips() {
        let start = serde_json::json!({ "dateTime": "2026-10-25T10:00:00", "timeZone": "Europe/Amsterdam" });
        let r = ms_recurrence("FREQ=WEEKLY;INTERVAL=2;BYDAY=SU;WKST=SU", &start, None).unwrap();
        assert_eq!(r["pattern"]["firstDayOfWeek"], "sunday");
        assert_eq!(graph_rrule(&r).as_deref(), Some("FREQ=WEEKLY;BYDAY=SU;WKST=SU;INTERVAL=2"));
    }

    #[test]
    fn ending_a_series_swaps_count_for_until() {
        let cutoff = instant("2026-10-28T13:00:00Z").unwrap();
        assert_eq!(rrule_until("FREQ=WEEKLY;BYDAY=MO,WE;COUNT=6", cutoff, false).as_deref(),
            Some("FREQ=WEEKLY;BYDAY=MO,WE;UNTIL=20261028T125959Z"));
        assert_eq!(rrule_until("FREQ=DAILY;UNTIL=20261231", instant("2026-10-28").unwrap(), true).as_deref(),
            Some("FREQ=DAILY;UNTIL=20261027"));
    }

    #[test]
    fn conference_request_only_when_the_draft_asks() {
        let plain = EventDraft {
            title: "Sync".into(),
            start_at: "2026-09-18T14:30:00Z".into(),
            end_at: "2026-09-18T15:00:00Z".into(),
            ..Default::default()
        };
        assert!(google_event_body(&plain).get("conferenceData").is_none());
        assert!(ms_event_body(&plain).get("isOnlineMeeting").is_none());

        let with_call = EventDraft { conference: true, ..plain };
        let g = google_event_body(&with_call);
        assert_eq!(g["conferenceData"]["createRequest"]["conferenceSolutionKey"]["type"], "hangoutsMeet");
        assert!(g["conferenceData"]["createRequest"]["requestId"].as_str().is_some_and(|r| !r.is_empty()));
        let m = ms_event_body(&with_call);
        assert_eq!(m["isOnlineMeeting"], true);
        assert_eq!(m["onlineMeetingProvider"], "teamsForBusiness");
    }

    #[test]
    fn conference_link_read_from_provider_fields() {
        // Google: the video entry point wins over the phone one.
        let ev = serde_json::json!({
            "conferenceData": {
                "conferenceId": "abc-defg-hij",
                "conferenceSolution": { "name": "Google Meet" },
                "entryPoints": [
                    { "entryPointType": "phone", "uri": "tel:+31-20-000" },
                    { "entryPointType": "video", "uri": "https://meet.google.com/abc-defg-hij" }
                ]
            }
        });
        let c = google_conference(&ev).unwrap();
        assert_eq!(c["url"], "https://meet.google.com/abc-defg-hij");
        assert_eq!(c["label"], "Google Meet");
        assert_eq!(c["code"], "abc-defg-hij");

        // A Zoom add-on writes its own solution into the same field.
        let zoom = serde_json::json!({
            "conferenceData": {
                "conferenceSolution": { "name": "Zoom Meeting" },
                "entryPoints": [{ "entryPointType": "video", "uri": "https://zoom.us/j/9?pwd=x" }]
            }
        });
        assert_eq!(google_conference(&zoom).unwrap()["url"], "https://zoom.us/j/9?pwd=x");

        // Legacy events carry only hangoutLink.
        let legacy = serde_json::json!({ "hangoutLink": "https://meet.google.com/old-link" });
        assert_eq!(google_conference(&legacy).unwrap()["url"], "https://meet.google.com/old-link");
        assert!(google_conference(&serde_json::json!({ "summary": "no call" })).is_none());

        // Microsoft: onlineMeeting, then the deprecated flat field.
        let teams = serde_json::json!({
            "onlineMeetingProvider": "teamsForBusiness",
            "onlineMeeting": { "joinUrl": "https://teams.microsoft.com/l/meetup-join/19%3a1", "conferenceId": "123" }
        });
        let c = ms_conference(&teams).unwrap();
        assert_eq!(c["url"], "https://teams.microsoft.com/l/meetup-join/19%3a1");
        assert_eq!(c["label"], "Microsoft Teams");
        let flat = serde_json::json!({ "onlineMeetingUrl": "https://teams.microsoft.com/l/x" });
        assert_eq!(ms_conference(&flat).unwrap()["url"], "https://teams.microsoft.com/l/x");
        assert!(ms_conference(&serde_json::json!({ "isOnlineMeeting": false })).is_none());
    }

    #[test]
    fn ms_color_and_response_mapping() {
        assert_eq!(ms_color_to_hex("lightGreen"), "#4ADE80");
        assert_eq!(ms_color_to_hex("unknown"), "#3B82F6");
        assert_eq!(ms_response_to_standard(Some("accepted")), "accepted");
        assert_eq!(ms_response_to_standard(Some("declined")), "declined");
        assert_eq!(ms_response_to_standard(None), "needs_action");
    }

    fn patch_body(reqs: &[wiremock::Request]) -> (String, Value) {
        let r = reqs.iter().find(|r| r.method.as_str() == "PATCH").expect("a PATCH");
        (r.url.to_string(), serde_json::from_slice(&r.body).unwrap())
    }

    #[tokio::test]
    async fn google_reschedule_one_sends_times_only() {
        let server = MockServer::start().await;
        Mock::given(method("PATCH"))
            .and(path("/calendar/v3/calendars/primary/events/e1_20261020T070000Z"))
            .and(query_param("sendUpdates", "none"))
            .respond_with(ResponseTemplate::new(200).set_body_json(serde_json::json!({})))
            .mount(&server)
            .await;
        let r = Reschedule {
            start_at: "2026-10-20T10:00:00+02:00".into(),
            end_at: "2026-10-20T11:00:00+02:00".into(),
            timezone: Some("Europe/Amsterdam".into()),
            ..Default::default()
        };
        google_adapter(&server).reschedule_event("primary", "e1_20261020T070000Z", &r).await.unwrap();
        let (_, body) = patch_body(&server.received_requests().await.unwrap());
        // No summary/attendees: a full body would reset every guest's RSVP.
        assert_eq!(
            body,
            serde_json::json!({
                "start": { "dateTime": "2026-10-20T10:00:00+02:00", "timeZone": "Europe/Amsterdam" },
                "end": { "dateTime": "2026-10-20T11:00:00+02:00", "timeZone": "Europe/Amsterdam" },
            })
        );
    }

    #[tokio::test]
    async fn google_reschedule_series_shifts_the_master() {
        let server = MockServer::start().await;
        Mock::given(method("GET"))
            .and(path("/calendar/v3/calendars/primary/events/e1"))
            .respond_with(ResponseTemplate::new(200).set_body_json(serde_json::json!({
                "id": "e1",
                "start": { "dateTime": "2026-06-01T09:00:00+02:00", "timeZone": "Europe/Amsterdam" },
                "end": { "dateTime": "2026-06-01T09:30:00+02:00", "timeZone": "Europe/Amsterdam" },
            })))
            .mount(&server)
            .await;
        Mock::given(method("PATCH"))
            .and(path("/calendar/v3/calendars/primary/events/e1"))
            .and(query_param("sendUpdates", "all"))
            .respond_with(ResponseTemplate::new(200).set_body_json(serde_json::json!({})))
            .mount(&server)
            .await;
        // An instance dragged an hour later and stretched to an hour long.
        let r = Reschedule {
            start_at: "2026-10-20T10:00:00+02:00".into(),
            end_at: "2026-10-20T11:00:00+02:00".into(),
            series_id: Some("e1".into()),
            shift_seconds: 3600,
            notify: true,
            ..Default::default()
        };
        google_adapter(&server).reschedule_event("primary", "e1_20261020T070000Z", &r).await.unwrap();
        let (_, body) = patch_body(&server.received_requests().await.unwrap());
        assert_eq!(body["start"]["dateTime"], "2026-06-01T10:00:00+02:00");
        assert_eq!(body["end"]["dateTime"], "2026-06-01T11:00:00+02:00");
        assert_eq!(body["start"]["timeZone"], "Europe/Amsterdam");
    }

    #[tokio::test]
    async fn google_series_edits_keep_exdates_and_split_at_the_instance() {
        let server = MockServer::start().await;
        Mock::given(method("GET"))
            .and(path("/calendar/v3/calendars/primary/events/e1"))
            .respond_with(ResponseTemplate::new(200).set_body_json(serde_json::json!({
                "id": "e1",
                "start": { "dateTime": "2026-10-26T14:00:00+01:00", "timeZone": "Europe/Amsterdam" },
                "end": { "dateTime": "2026-10-26T14:30:00+01:00", "timeZone": "Europe/Amsterdam" },
                "recurrence": ["RRULE:FREQ=WEEKLY;BYDAY=MO,WE;COUNT=6", "EXDATE;TZID=Europe/Amsterdam:20261102T140000"],
            })))
            .mount(&server)
            .await;
        Mock::given(method("PATCH"))
            .and(path("/calendar/v3/calendars/primary/events/e1"))
            .respond_with(ResponseTemplate::new(200).set_body_json(serde_json::json!({})))
            .mount(&server)
            .await;
        Mock::given(method("GET"))
            .and(path("/calendar/v3/calendars/primary/events/e1_20261026T130000Z"))
            .respond_with(ResponseTemplate::new(200).set_body_json(serde_json::json!({
                "id": "e1_20261026T130000Z", "originalStartTime": { "dateTime": "2026-10-26T14:00:00+01:00" },
            })))
            .mount(&server)
            .await;
        Mock::given(method("GET"))
            .and(path("/calendar/v3/calendars/primary/events/e1_20261028T130000Z"))
            .respond_with(ResponseTemplate::new(200).set_body_json(serde_json::json!({
                "id": "e1_20261028T130000Z", "originalStartTime": { "dateTime": "2026-10-28T14:00:00+01:00" },
            })))
            .mount(&server)
            .await;
        Mock::given(method("GET"))
            .and(path("/calendar/v3/calendars/primary/events/e1/instances"))
            .respond_with(ResponseTemplate::new(200).set_body_json(serde_json::json!({ "items": [
                { "originalStartTime": { "dateTime": "2026-10-26T14:00:00+01:00" } },
                { "originalStartTime": { "dateTime": "2026-10-28T14:00:00+01:00" } },
            ]})))
            .mount(&server)
            .await;
        let g = google_adapter(&server);
        let master = g.get_series("primary", "e1").await.unwrap();
        assert_eq!(master.rule.as_deref(), Some("FREQ=WEEKLY;BYDAY=MO,WE;COUNT=6"));

        // The first instance: nothing would be left before it.
        assert!(g.ended_recurrence("primary", &master, "e1_20261026T130000Z", "2026-10-26T14:00:00+01:00").await.unwrap().is_none());
        // Wednesday's, moved to Thursday: the series stops before its
        // ORIGINAL slot, so it isn't left in the old half too. The EXDATE is
        // after it, so it goes with the new half, not this one.
        let end = g.ended_recurrence("primary", &master, "e1_20261028T130000Z", "2026-10-29T14:00:00+01:00").await.unwrap().unwrap();
        assert_eq!(end.cutoff, "2026-10-28T14:00:00+01:00");
        assert_eq!(end.done, 1, "only Monday's slot is before Wednesday's");
        let body = end.body;
        assert_eq!(body["recurrence"], serde_json::json!(["RRULE:FREQ=WEEKLY;BYDAY=MO,WE;UNTIL=20261028T125959Z"]));
    }

    #[tokio::test]
    async fn following_creates_first_and_takes_it_back_if_the_old_half_wont_end() {
        let server = MockServer::start().await;
        Mock::given(method("GET"))
            .and(path("/calendar/v3/calendars/primary/events/e1"))
            .respond_with(ResponseTemplate::new(200).set_body_json(serde_json::json!({
                "id": "e1",
                "description": "Bring the car seat",
                "attendees": [
                    { "email": "me@x.com", "organizer": true, "self": true },
                    { "email": "oma@x.com" },
                ],
                "start": { "dateTime": "2026-10-26T14:00:00+01:00", "timeZone": "Europe/Amsterdam" },
                "end": { "dateTime": "2026-10-26T14:30:00+01:00", "timeZone": "Europe/Amsterdam" },
                "recurrence": ["RRULE:FREQ=WEEKLY;BYDAY=MO,WE"],
            })))
            .mount(&server)
            .await;
        Mock::given(method("POST"))
            .and(path("/calendar/v3/calendars/primary/events"))
            .respond_with(ResponseTemplate::new(200).set_body_json(serde_json::json!({ "id": "tail" })))
            .mount(&server)
            .await;
        Mock::given(method("PATCH"))
            .and(path("/calendar/v3/calendars/primary/events/e1"))
            .respond_with(ResponseTemplate::new(500))
            .mount(&server)
            .await;
        Mock::given(method("DELETE"))
            .and(path("/calendar/v3/calendars/primary/events/tail"))
            .respond_with(ResponseTemplate::new(204))
            .mount(&server)
            .await;
        Mock::given(method("GET"))
            .and(path("/calendar/v3/calendars/primary/events/e1_20261028T130000Z"))
            .respond_with(ResponseTemplate::new(200).set_body_json(serde_json::json!({
                "id": "e1_20261028T130000Z", "originalStartTime": { "dateTime": "2026-10-28T14:00:00+01:00" },
            })))
            .mount(&server)
            .await;
        // A mobile draft: no guests, no notes.
        let draft = EventDraft {
            title: "Musa".into(),
            start_at: "2026-10-28T14:00:00+01:00".into(),
            end_at: "2026-10-28T14:30:00+01:00".into(),
            timezone: Some("Europe/Amsterdam".into()),
            recurrence: Some("FREQ=WEEKLY;BYDAY=WE".into()),
            ..Default::default()
        };
        let g = google_adapter(&server);
        let err = apply_series_edit(&g, "primary", "e1", "e1_20261028T130000Z", "2026-10-28T14:00:00+01:00", "following", &draft).await;
        assert!(err.is_err());

        let reqs = server.received_requests().await.unwrap();
        let order: Vec<&str> = reqs.iter().map(|r| r.method.as_str()).collect();
        assert_eq!(order, vec!["GET", "GET", "POST", "PATCH", "DELETE"], "the new half is made before the old one is cut");
        let created: Value = serde_json::from_slice(&reqs[2].body).unwrap();
        assert_eq!(created["attendees"], serde_json::json!([{ "email": "oma@x.com" }]));
        assert_eq!(created["description"], "Bring the car seat");
    }

    #[tokio::test]
    async fn following_carries_later_exceptions_onto_the_new_half() {
        let server = MockServer::start().await;
        Mock::given(method("GET"))
            .and(path("/calendar/v3/calendars/primary/events/e1"))
            .respond_with(ResponseTemplate::new(200).set_body_json(serde_json::json!({
                "id": "e1", "summary": "Musa",
                "start": { "dateTime": "2026-10-26T14:00:00+01:00", "timeZone": "Europe/Amsterdam" },
                "end": { "dateTime": "2026-10-26T14:30:00+01:00", "timeZone": "Europe/Amsterdam" },
                "recurrence": ["RRULE:FREQ=WEEKLY;BYDAY=MO,WE", "EXDATE;TZID=Europe/Amsterdam:20261111T140000", "RDATE:20261230T130000Z"],
            })))
            .mount(&server)
            .await;
        Mock::given(method("GET"))
            .and(path("/calendar/v3/calendars/primary/events/e1_20261028T130000Z"))
            .respond_with(ResponseTemplate::new(200).set_body_json(serde_json::json!({
                "id": "e1_20261028T130000Z", "originalStartTime": { "dateTime": "2026-10-28T14:00:00+01:00" },
            })))
            .mount(&server)
            .await;
        // After the split: Mon 2 Nov cancelled, Wed 4 Nov moved an hour, Mon 9 as is.
        Mock::given(method("GET"))
            .and(path("/calendar/v3/calendars/primary/events/e1/instances"))
            .respond_with(ResponseTemplate::new(200).set_body_json(serde_json::json!({ "items": [
                { "summary": "Musa", "start": { "dateTime": "2026-10-28T14:00:00+01:00" }, "originalStartTime": { "dateTime": "2026-10-28T14:00:00+01:00" } },
                { "status": "cancelled", "originalStartTime": { "dateTime": "2026-11-02T14:00:00+01:00" } },
                { "summary": "Musa", "start": { "dateTime": "2026-11-04T15:00:00+01:00" }, "end": { "dateTime": "2026-11-04T15:30:00+01:00" },
                  "originalStartTime": { "dateTime": "2026-11-04T14:00:00+01:00" }, "attendees": [{ "email": "oma@x.com" }] },
                { "summary": "Musa", "start": { "dateTime": "2026-11-09T14:00:00+01:00" }, "originalStartTime": { "dateTime": "2026-11-09T14:00:00+01:00" } },
            ]})))
            .mount(&server)
            .await;
        Mock::given(method("POST"))
            .and(path("/calendar/v3/calendars/primary/events"))
            .respond_with(ResponseTemplate::new(200).set_body_json(serde_json::json!({ "id": "tail" })))
            .mount(&server)
            .await;
        Mock::given(method("DELETE"))
            .and(path("/calendar/v3/calendars/primary/events/tail_20261102T130000Z"))
            .respond_with(ResponseTemplate::new(204))
            .mount(&server)
            .await;
        Mock::given(method("PATCH"))
            .respond_with(ResponseTemplate::new(200).set_body_json(serde_json::json!({})))
            .mount(&server)
            .await;
        // A retitle from Wednesday on, rule and time unchanged.
        let draft = EventDraft {
            title: "Musa ophalen".into(),
            start_at: "2026-10-28T14:00:00+01:00".into(),
            end_at: "2026-10-28T14:30:00+01:00".into(),
            timezone: Some("Europe/Amsterdam".into()),
            // A retitle that also ends it after ten more: Wed 28 Oct … Mon 30 Nov.
            recurrence: Some("FREQ=WEEKLY;BYDAY=MO,WE;COUNT=10".into()),
            ..Default::default()
        };
        let g = google_adapter(&server);
        apply_series_edit(&g, "primary", "e1", "e1_20261028T130000Z", "2026-10-28T14:00:00+01:00", "following", &draft)
            .await
            .unwrap();
        let reqs = server.received_requests().await.unwrap();
        let calls: Vec<String> = reqs.iter().map(|r| format!("{} {}", r.method, r.url.path())).collect();
        let carried = calls.iter().position(|c| c == "PATCH /calendar/v3/calendars/primary/events/tail_20261104T130000Z").expect("moved one carried");
        let deleted = calls.iter().position(|c| c == "DELETE /calendar/v3/calendars/primary/events/tail_20261102T130000Z").expect("cancelled one carried");
        let ended = calls.iter().position(|c| c == "PATCH /calendar/v3/calendars/primary/events/e1").expect("old half ended");
        assert!(carried < ended && deleted < ended, "exceptions move over before the old half ends: {calls:?}");
        assert!(!calls.iter().any(|c| c.contains("tail_20261109")), "an untouched occurrence isn't rewritten");
        let moved: Value = serde_json::from_slice(&reqs[carried].body).unwrap();
        assert_eq!(moved["start"]["dateTime"], "2026-11-04T15:00:00+01:00");
        assert!(moved.get("summary").is_none(), "the new title isn't overwritten by the old one");
        assert_eq!(moved["attendees"], serde_json::json!([{ "email": "oma@x.com" }]), "that day's own guest comes along");
        let created: Value = serde_json::from_slice(&reqs.iter().find(|r| r.method.as_str() == "POST").unwrap().body).unwrap();
        assert_eq!(created["recurrence"][1], "EXDATE;TZID=Europe/Amsterdam:20261111T140000", "excluded dates stay excluded");
        assert!(!created["recurrence"].to_string().contains("RDATE"), "an extra date past the new end stays out");
    }

    #[test]
    fn graph_counts_past_occurrences_off_the_pattern() {
        let d = |s: &str| chrono::NaiveDate::parse_from_str(s, "%Y-%m-%d").unwrap();
        let weekly = serde_json::json!({ "type": "weekly", "interval": 1, "daysOfWeek": ["monday", "wednesday"], "firstDayOfWeek": "monday" });
        // Mon 26, Wed 28, Mon 2 — even if one of them was deleted since.
        assert_eq!(graph_count_before(&weekly, d("2026-10-26"), d("2026-11-04")), 3);
        let fortnightly = serde_json::json!({ "type": "weekly", "interval": 2, "daysOfWeek": ["monday"], "firstDayOfWeek": "monday" });
        assert_eq!(graph_count_before(&fortnightly, d("2026-10-26"), d("2026-11-24")), 3); // 26 Oct, 9 Nov, 23 Nov
        // Two weekdays, one occurrence a month: the 2nd Monday-or-Tuesday.
        let second_mon_or_tue = serde_json::json!({ "type": "relativeMonthly", "interval": 1, "daysOfWeek": ["monday", "tuesday"], "index": "second" });
        assert_eq!(graph_count_before(&second_mon_or_tue, d("2026-11-01"), d("2027-01-01")), 2);
        assert_eq!(graph_nth_day(&second_mon_or_tue, d("2026-11-01"), 2), Some(d("2026-12-07")));
        let last_friday = serde_json::json!({ "type": "relativeMonthly", "interval": 1, "daysOfWeek": ["friday"], "index": "last" });
        assert_eq!(graph_count_before(&last_friday, d("2026-10-30"), d("2027-01-01")), 3); // 30 Oct, 27 Nov, 25 Dec
        let monthly = serde_json::json!({ "type": "absoluteMonthly", "interval": 1, "dayOfMonth": 26 });
        assert_eq!(graph_count_before(&monthly, d("2026-10-26"), d("2027-01-26")), 3);
    }

    #[tokio::test]
    async fn a_single_edit_keeps_guests_rsvps_and_can_clear_them() {
        let server = MockServer::start().await;
        Mock::given(method("GET"))
            .and(path("/calendar/v3/calendars/primary/events/ev"))
            .respond_with(ResponseTemplate::new(200).set_body_json(serde_json::json!({ "attendees": [
                { "email": "me@x.com", "organizer": true },
                { "email": "oma@x.com", "responseStatus": "accepted" },
            ]})))
            .mount(&server)
            .await;
        Mock::given(method("PATCH"))
            .and(path("/calendar/v3/calendars/primary/events/ev"))
            .respond_with(ResponseTemplate::new(200).set_body_json(serde_json::json!({})))
            .mount(&server)
            .await;
        let g = google_adapter(&server);
        let base = EventDraft { title: "Musa".into(), start_at: "2026-10-26T14:00:00+01:00".into(), end_at: "2026-10-26T14:30:00+01:00".into(), ..Default::default() };
        g.update_event("primary", "ev", &EventDraft { attendees: vec!["oma@x.com".into(), "new@x.com".into()], ..base.clone() }).await.unwrap();
        g.update_event("primary", "ev", &EventDraft { attendees_cleared: true, ..base }).await.unwrap();
        let patches: Vec<Value> = server.received_requests().await.unwrap().iter()
            .filter(|r| r.method.as_str() == "PATCH").map(|r| serde_json::from_slice(&r.body).unwrap()).collect();
        assert_eq!(patches[0]["attendees"][1], serde_json::json!({ "email": "oma@x.com", "responseStatus": "accepted" }));
        assert_eq!(patches[0]["attendees"][2], serde_json::json!({ "email": "new@x.com" }));
        // Cleared: only the organizer stays.
        assert_eq!(patches[1]["attendees"], serde_json::json!([{ "email": "me@x.com", "organizer": true }]));
    }

    #[tokio::test]
    async fn graph_carries_an_exception_moved_to_before_the_cutoff() {
        let server = MockServer::start().await;
        // Old series: the 4 Nov occurrence was pulled forward to 27 Oct.
        Mock::given(method("GET"))
            .and(path("/v1.0/me/events/old/instances"))
            .respond_with(ResponseTemplate::new(200).set_body_json(serde_json::json!({ "value": [
                { "type": "occurrence", "start": { "dateTime": "2026-10-28T13:00:00.0000000", "timeZone": "UTC" } },
                { "type": "exception", "originalStart": "2026-11-04T13:00:00Z", "subject": "Musa",
                  "start": { "dateTime": "2026-10-27T13:00:00.0000000", "timeZone": "UTC" },
                  "end": { "dateTime": "2026-10-27T13:30:00.0000000", "timeZone": "UTC" } },
                { "type": "exception", "originalStart": "2026-10-26T13:00:00Z", "subject": "Before the split",
                  "start": { "dateTime": "2026-10-26T15:00:00.0000000", "timeZone": "UTC" } },
            ]})))
            .mount(&server)
            .await;
        Mock::given(method("GET"))
            .and(path("/v1.0/me/events/new/instances"))
            .respond_with(ResponseTemplate::new(200).set_body_json(serde_json::json!({ "value": [
                { "id": "n1", "start": { "dateTime": "2026-10-28T13:00:00.0000000", "timeZone": "UTC" } },
                { "id": "n2", "start": { "dateTime": "2026-11-04T13:00:00.0000000", "timeZone": "UTC" } },
                // 2 Nov: the old series has nothing for this slot — it was deleted there.
                { "id": "n3", "start": { "dateTime": "2026-11-02T13:00:00.0000000", "timeZone": "UTC" } },
                // 16 Nov: past the old series' end — a slot it never had, not a deletion.
                { "id": "n4", "start": { "dateTime": "2026-11-16T13:00:00.0000000", "timeZone": "UTC" } },
            ]})))
            .mount(&server)
            .await;
        Mock::given(method("PATCH"))
            .respond_with(ResponseTemplate::new(200).set_body_json(serde_json::json!({})))
            .mount(&server)
            .await;
        Mock::given(method("DELETE"))
            .respond_with(ResponseTemplate::new(204))
            .mount(&server)
            .await;
        let master = SeriesMaster {
            raw: serde_json::json!({ "subject": "Musa", "recurrence": { "range": { "type": "endDate", "endDate": "2026-11-04" } } }),
            rule: Some("FREQ=WEEKLY;BYDAY=MO,WE".into()),
            attendees: vec![],
            description: None,
            description_is_html: false,
        };
        ms_adapter(&server).carry_exceptions("cal", "old", "new", &master, "2026-10-28T13:00:00Z").await.unwrap();
        let reqs = server.received_requests().await.unwrap();
        let old_query = reqs.iter().find(|r| r.url.path().ends_with("/old/instances")).unwrap().url.query().unwrap().to_string();
        assert!(old_query.contains("startDateTime=2025-"), "looks back past the cutoff: {old_query}");
        let patches: Vec<String> = reqs.iter().filter(|r| r.method.as_str() == "PATCH").map(|r| r.url.path().to_string()).collect();
        assert_eq!(patches, vec!["/v1.0/me/events/n2"], "the moved one lands on its own slot; the earlier one stays behind");
        let deletes: Vec<String> = reqs.iter().filter(|r| r.method.as_str() == "DELETE").map(|r| r.url.path().to_string()).collect();
        assert_eq!(deletes, vec!["/v1.0/me/events/n3"], "a deleted occurrence stays deleted");
    }

    #[tokio::test]
    async fn a_title_only_split_keeps_every_extra_date() {
        let server = MockServer::start().await;
        Mock::given(method("GET"))
            .and(path("/calendar/v3/calendars/primary/events/e1"))
            .respond_with(ResponseTemplate::new(200).set_body_json(serde_json::json!({
                "id": "e1", "summary": "Musa",
                "start": { "dateTime": "2026-10-26T14:00:00+01:00", "timeZone": "Europe/Amsterdam" },
                "end": { "dateTime": "2026-10-26T14:30:00+01:00", "timeZone": "Europe/Amsterdam" },
                // Ends after six; the RDATE in January is one more, of its own.
                "recurrence": ["RRULE:FREQ=WEEKLY;BYDAY=MO,WE;COUNT=6", "RDATE:20270105T130000Z"],
            })))
            .mount(&server)
            .await;
        Mock::given(method("GET"))
            .and(path("/calendar/v3/calendars/primary/events/e1_20261028T130000Z"))
            .respond_with(ResponseTemplate::new(200).set_body_json(serde_json::json!({
                "id": "e1_20261028T130000Z", "originalStartTime": { "dateTime": "2026-10-28T14:00:00+01:00" },
            })))
            .mount(&server)
            .await;
        Mock::given(method("GET"))
            .and(path("/calendar/v3/calendars/primary/events/e1/instances"))
            .respond_with(ResponseTemplate::new(200).set_body_json(serde_json::json!({ "items": [
                { "originalStartTime": { "dateTime": "2026-10-26T14:00:00+01:00" } },
            ]})))
            .mount(&server)
            .await;
        Mock::given(method("POST"))
            .and(path("/calendar/v3/calendars/primary/events"))
            .respond_with(ResponseTemplate::new(200).set_body_json(serde_json::json!({ "id": "tail" })))
            .mount(&server)
            .await;
        Mock::given(method("PATCH"))
            .respond_with(ResponseTemplate::new(200).set_body_json(serde_json::json!({})))
            .mount(&server)
            .await;
        let draft = EventDraft {
            title: "Musa ophalen".into(),
            start_at: "2026-10-28T14:00:00+01:00".into(),
            end_at: "2026-10-28T14:30:00+01:00".into(),
            timezone: Some("Europe/Amsterdam".into()),
            recurrence: Some("FREQ=WEEKLY;BYDAY=MO,WE;COUNT=6".into()),
            ..Default::default()
        };
        apply_series_edit(&google_adapter(&server), "primary", "e1", "e1_20261028T130000Z", "2026-10-28T14:00:00+01:00", "following", &draft)
            .await
            .unwrap();
        let reqs = server.received_requests().await.unwrap();
        let created: Value = serde_json::from_slice(&reqs.iter().find(|r| r.method.as_str() == "POST").unwrap().body).unwrap();
        // The count carries what's left (5); the January date still comes along.
        assert_eq!(created["recurrence"], serde_json::json!(["RRULE:FREQ=WEEKLY;BYDAY=MO,WE;COUNT=5", "RDATE:20270105T130000Z"]));
    }

    #[test]
    fn series_edits_keep_guests_rsvps() {
        let existing = serde_json::json!([
            { "email": "me@x.com", "organizer": true, "responseStatus": "accepted" },
            { "email": "oma@x.com", "responseStatus": "accepted" },
            { "email": "opa@x.com", "responseStatus": "declined" },
        ]);
        let email: fn(&Value) -> Option<String> = |a| json_str(a, "email");
        let fresh: fn(&str) -> Value = |e| serde_json::json!({ "email": e });
        // Same guests (any case): leave the list out, so nobody's reply resets.
        assert!(merged_attendees(Some(&existing), &["OMA@x.com".into(), "opa@x.com".into()], email, fresh).is_none());
        // One dropped, one added: the kept guest keeps their reply.
        let merged = merged_attendees(Some(&existing), &["oma@x.com".into(), "new@x.com".into()], email, fresh).unwrap();
        assert_eq!(merged, serde_json::json!([
            { "email": "me@x.com", "organizer": true, "responseStatus": "accepted" },
            { "email": "oma@x.com", "responseStatus": "accepted" },
            { "email": "new@x.com" },
        ]));
    }

    #[tokio::test]
    async fn following_carries_only_the_remaining_count() {
        let server = MockServer::start().await;
        Mock::given(method("GET"))
            .and(path("/calendar/v3/calendars/primary/events/e1"))
            .respond_with(ResponseTemplate::new(200).set_body_json(serde_json::json!({
                "id": "e1",
                "start": { "dateTime": "2026-10-26T14:00:00+01:00", "timeZone": "Europe/Amsterdam" },
                "end": { "dateTime": "2026-10-26T14:30:00+01:00", "timeZone": "Europe/Amsterdam" },
                "recurrence": ["RRULE:FREQ=WEEKLY;BYDAY=MO,WE;COUNT=6"],
            })))
            .mount(&server)
            .await;
        Mock::given(method("GET"))
            .and(path("/calendar/v3/calendars/primary/events/e1_20261104T130000Z"))
            .respond_with(ResponseTemplate::new(200).set_body_json(serde_json::json!({
                "id": "e1_20261104T130000Z", "originalStartTime": { "dateTime": "2026-11-04T14:00:00+01:00" },
            })))
            .mount(&server)
            .await;
        // Mon 26, Wed 28, Mon 2 have happened; the edit is on Wed 4 Nov.
        Mock::given(method("GET"))
            .and(path("/calendar/v3/calendars/primary/events/e1/instances"))
            .respond_with(ResponseTemplate::new(200).set_body_json(serde_json::json!({ "items": [
                { "start": { "dateTime": "2026-10-26T14:00:00+01:00" } },
                { "start": { "dateTime": "2026-10-28T14:00:00+01:00" } },
                { "status": "cancelled", "originalStartTime": { "dateTime": "2026-11-02T14:00:00+01:00" } },
                { "start": { "dateTime": "2026-11-04T14:00:00+01:00" } },
            ]})))
            .mount(&server)
            .await;
        Mock::given(method("POST"))
            .and(path("/calendar/v3/calendars/primary/events"))
            .respond_with(ResponseTemplate::new(200).set_body_json(serde_json::json!({ "id": "tail" })))
            .mount(&server)
            .await;
        Mock::given(method("PATCH"))
            .and(path("/calendar/v3/calendars/primary/events/e1"))
            .respond_with(ResponseTemplate::new(200).set_body_json(serde_json::json!({})))
            .mount(&server)
            .await;
        let draft = EventDraft {
            title: "Musa".into(),
            start_at: "2026-11-04T15:00:00+01:00".into(),
            end_at: "2026-11-04T15:30:00+01:00".into(),
            timezone: Some("Europe/Amsterdam".into()),
            recurrence: Some("FREQ=WEEKLY;BYDAY=MO,WE;COUNT=6".into()),
            ..Default::default()
        };
        let g = google_adapter(&server);
        apply_series_edit(&g, "primary", "e1", "e1_20261104T130000Z", "2026-11-04T14:00:00+01:00", "following", &draft)
            .await
            .unwrap();
        let reqs = server.received_requests().await.unwrap();
        let created: Value = serde_json::from_slice(&reqs.iter().find(|r| r.method.as_str() == "POST").unwrap().body).unwrap();
        assert_eq!(created["recurrence"], serde_json::json!(["RRULE:FREQ=WEEKLY;BYDAY=MO,WE;COUNT=3"]));
    }

    #[tokio::test]
    async fn ms_series_edit_moves_the_master_and_rewrites_its_rule() {
        let server = MockServer::start().await;
        Mock::given(method("GET"))
            .and(path("/v1.0/me/events/master"))
            .respond_with(ResponseTemplate::new(200).set_body_json(serde_json::json!({
                "originalStartTimeZone": "W. Europe Standard Time",
                "start": { "dateTime": "2026-10-26T14:00:00.0000000", "timeZone": "W. Europe Standard Time" },
                "end": { "dateTime": "2026-10-26T14:30:00.0000000", "timeZone": "W. Europe Standard Time" },
                "recurrence": {
                    "pattern": { "type": "weekly", "interval": 1, "daysOfWeek": ["monday"], "firstDayOfWeek": "monday" },
                    "range": { "type": "noEnd", "startDate": "2026-10-26", "recurrenceTimeZone": "W. Europe Standard Time" },
                },
            })))
            .mount(&server)
            .await;
        Mock::given(method("PATCH"))
            .and(path("/v1.0/me/events/master"))
            .respond_with(ResponseTemplate::new(200).set_body_json(serde_json::json!({})))
            .mount(&server)
            .await;
        let m = ms_adapter(&server);
        let master = m.get_series("cal", "master").await.unwrap();
        assert_eq!(master.rule.as_deref(), Some("FREQ=WEEKLY;BYDAY=MO"));

        // A later instance moved from 14:00 to 15:00 and given Wednesdays too.
        let draft = EventDraft {
            title: "Musa".into(),
            start_at: "2026-11-09T15:00:00+01:00".into(),
            end_at: "2026-11-09T15:30:00+01:00".into(),
            timezone: Some("Europe/Amsterdam".into()),
            recurrence: Some("FREQ=WEEKLY;BYDAY=MO,WE".into()),
            ..Default::default()
        };
        m.update_series("cal", "master", &master, &draft, chrono::Duration::hours(1)).await.unwrap();
        let (_, body) = patch_body(&server.received_requests().await.unwrap());
        assert_eq!(body["start"], serde_json::json!({ "dateTime": "2026-10-26T15:00:00", "timeZone": "W. Europe Standard Time" }));
        assert_eq!(body["end"]["dateTime"], "2026-10-26T15:30:00");
        assert_eq!(body["recurrence"]["pattern"]["daysOfWeek"], serde_json::json!(["monday", "wednesday"]));
        assert_eq!(body["recurrence"]["range"]["startDate"], "2026-10-26");
        assert_eq!(body["recurrence"]["range"]["recurrenceTimeZone"], "W. Europe Standard Time");
    }

    #[tokio::test]
    async fn ms_reschedule_series_stays_in_its_own_zone() {
        let server = MockServer::start().await;
        // One mock answers both reads: the zone lookup and the zoned master.
        Mock::given(method("GET"))
            .and(path("/v1.0/me/events/master"))
            .respond_with(ResponseTemplate::new(200).set_body_json(serde_json::json!({
                "originalStartTimeZone": "W. Europe Standard Time",
                "start": { "dateTime": "2026-06-01T09:00:00.0000000", "timeZone": "W. Europe Standard Time" },
                "end": { "dateTime": "2026-06-01T09:30:00.0000000", "timeZone": "W. Europe Standard Time" },
            })))
            .mount(&server)
            .await;
        Mock::given(method("PATCH"))
            .and(path("/v1.0/me/events/master"))
            .respond_with(ResponseTemplate::new(200).set_body_json(serde_json::json!({})))
            .mount(&server)
            .await;
        let r = Reschedule {
            start_at: "2026-10-20T07:30:00Z".into(),
            end_at: "2026-10-20T08:00:00Z".into(),
            series_id: Some("master".into()),
            shift_seconds: 1800,
            ..Default::default()
        };
        ms_adapter(&server).reschedule_event("cal", "occ", &r).await.unwrap();
        let (_, body) = patch_body(&server.received_requests().await.unwrap());
        assert_eq!(
            body["start"],
            serde_json::json!({ "dateTime": "2026-06-01T09:30:00", "timeZone": "W. Europe Standard Time" })
        );
        assert_eq!(body["end"]["dateTime"], "2026-06-01T10:00:00");
        let prefer = server.received_requests().await.unwrap().iter()
            .filter_map(|r| r.headers.get("prefer").map(|v| v.to_str().unwrap().to_string()))
            .next();
        assert_eq!(prefer.as_deref(), Some("outlook.timezone=\"W. Europe Standard Time\""));
    }

    #[tokio::test]
    async fn ms_reschedule_one_sends_utc_wall_clock() {
        let server = MockServer::start().await;
        Mock::given(method("PATCH"))
            .and(path("/v1.0/me/events/occ"))
            .respond_with(ResponseTemplate::new(200).set_body_json(serde_json::json!({})))
            .mount(&server)
            .await;
        let r = Reschedule {
            start_at: "2026-10-20T10:00:00+02:00".into(),
            end_at: "2026-10-20T11:00:00+02:00".into(),
            ..Default::default()
        };
        ms_adapter(&server).reschedule_event("cal", "occ", &r).await.unwrap();
        let (_, body) = patch_body(&server.received_requests().await.unwrap());
        assert_eq!(body["start"], serde_json::json!({ "dateTime": "2026-10-20T08:00:00", "timeZone": "UTC" }));
    }
}
