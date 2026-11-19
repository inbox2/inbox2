//! `SyncStore` — calendars and calendar events.

use super::*;

/// A synced calendar event matched to an emailed invite by iCalendar UID.
pub struct MatchedInviteEvent {
    pub key: String,
    pub response_status: Option<String>,
    /// tz-correct absolute times from the sync (RFC 3339 with offset/Z).
    pub start_at: String,
    pub end_at: String,
    pub all_day: bool,
}

/// Pull the self attendee's RSVP out of a calendar event's `metadata` JSON
/// (`{attendees:[{email,responseStatus}]}`). Google writes `needsAction`,
/// Microsoft writes `needs_action`; both are normalized here.
fn self_attendee_status(metadata_json: &str, email: &str) -> Option<String> {
    let v: serde_json::Value = serde_json::from_str(metadata_json).ok()?;
    for a in v.get("attendees")?.as_array()? {
        let Some(ae) = a.get("email").and_then(|x| x.as_str()) else { continue };
        if ae.eq_ignore_ascii_case(email) {
            let s = a.get("responseStatus").and_then(|x| x.as_str()).unwrap_or("needsAction");
            return Some(if s == "needsAction" { "needs_action".into() } else { s.to_string() });
        }
    }
    None
}

impl SyncStore {
    /// Busy periods on this device's calendars touching `[from_day, to_day]`
    /// (ISO dates) — the busy-only upload behind MX free/busy (docs/Calendar.md
    /// "External busy"). Returns `(start_at, end_at, all_day)` as stored.
    ///
    /// Counts: the user's own calendars plus Google ICS subscriptions (a work
    /// calendar imported by URL). Skips: holidays, birthdays and colleagues'
    /// shared calendars (all not owned), hidden calendars, cancelled events, and
    /// invitations the user declined.
    // ponytail: every @import calendar counts; a subscribed sports schedule would
    // read as busy too. Add a per-calendar "counts as busy" toggle if that bites.
    pub fn busy_periods(&self, from_day: &str, to_day: &str) -> Result<Vec<(String, String, bool)>> {
        let conn = self.conn.lock();
        let mut stmt = conn.prepare(
            "SELECT e.start_at, e.end_at, e.all_day, e.metadata, a.email_address
             FROM calendar_events e
             JOIN calendars c ON c.key = e.calendar_key
             LEFT JOIN external_accounts a ON a.key = e.account_key
             WHERE e.status != 'cancelled' AND c.is_visible = 1
               AND (c.is_owned = 1 OR c.provider_id LIKE '%@import.calendar.google.com')
               AND substr(e.end_at, 1, 10) >= ?1 AND substr(e.start_at, 1, 10) <= ?2",
        )?;
        let rows = stmt.query_map(params![from_day, to_day], |r| {
            Ok((
                r.get::<_, String>(0)?,
                r.get::<_, String>(1)?,
                r.get::<_, Option<i64>>(2)?.unwrap_or(0) != 0,
                r.get::<_, Option<String>>(3)?,
                r.get::<_, Option<String>>(4)?,
            ))
        })?;
        let mut out = Vec::new();
        for row in rows {
            let (start, end, all_day, metadata, email) = row?;
            let declined = match (metadata, email) {
                (Some(m), Some(e)) => self_attendee_status(&m, &e).as_deref() == Some("declined"),
                _ => false,
            };
            if !declined {
                out.push((start, end, all_day));
            }
        }
        Ok(out)
    }


    // -----------------------------------------------------------------------
    // Calendars + events
    // -----------------------------------------------------------------------

    pub fn upsert_calendar(
        &self,
        account_key: &str,
        source: &str,
        cal: &crate::sync::calendar::UnifiedCalendar,
    ) -> Result<()> {
        let conn = self.conn.lock();
        let now = Utc::now().to_rfc3339();
        // Preserve sync_token on conflict (re-listing must not wipe the cursor).
        conn.execute(
            "INSERT INTO calendars
             (key, account_key, name, color, source, provider_id, is_primary, is_visible, is_writable,
              conference_providers, is_owned, status, created_at, updated_at)
             VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, 1, ?9, ?10, ?11, 'active', ?8, ?8)
             ON CONFLICT(key) DO UPDATE SET
               name = excluded.name, color = excluded.color,
               provider_id = excluded.provider_id, is_primary = excluded.is_primary,
               is_writable = excluded.is_writable,
               conference_providers = excluded.conference_providers,
               is_owned = excluded.is_owned,
               updated_at = excluded.updated_at",
            params![
                cal.key,
                account_key,
                cal.name,
                cal.color,
                source,
                cal.provider_id,
                cal.is_primary as i32,
                now,
                cal.is_writable as i32,
                cal.conference_providers.join(","),
                cal.is_owned as i32,
            ],
        )?;
        Ok(())
    }

    pub fn get_calendars_for_account(
        &self,
        account_key: &str,
    ) -> Result<Vec<crate::sync::calendar::UnifiedCalendar>> {
        let conn = self.conn.lock();
        let mut stmt = conn.prepare(
            "SELECT key, provider_id, name, color, is_primary, is_writable, conference_providers, is_owned \
             FROM calendars WHERE account_key = ?1",
        )?;
        let rows = stmt.query_map(params![account_key], |row| {
            Ok(crate::sync::calendar::UnifiedCalendar {
                key: row.get(0)?,
                provider_id: row.get::<_, Option<String>>(1)?.unwrap_or_default(),
                name: row.get(2)?,
                color: row.get::<_, Option<String>>(3)?.unwrap_or_else(|| "#3B82F6".into()),
                is_primary: row.get::<_, i32>(4)? != 0,
                is_writable: row.get::<_, Option<i32>>(5)?.unwrap_or(1) != 0,
                conference_providers: row
                    .get::<_, Option<String>>(6)?
                    .unwrap_or_default()
                    .split(',')
                    .filter(|s| !s.is_empty())
                    .map(str::to_string)
                    .collect(),
                is_owned: row.get::<_, Option<i32>>(7)?.unwrap_or(1) != 0,
            })
        })?;
        rows.collect::<std::result::Result<Vec<_>, _>>().map_err(Into::into)
    }

    /// The local key of an account's calendar, addressed by its provider id.
    /// `None` when that calendar hasn't been synced into this store yet.
    pub fn calendar_key_for_provider_id(
        &self,
        account_key: &str,
        provider_id: &str,
    ) -> Result<Option<String>> {
        let conn = self.conn.lock();
        conn.query_row(
            "SELECT key FROM calendars WHERE account_key = ?1 AND provider_id = ?2",
            params![account_key, provider_id],
            |row| row.get(0),
        )
        .optional()
        .map_err(Into::into)
    }

    pub fn get_calendar_cursor(&self, calendar_key: &str) -> Result<Option<String>> {
        let conn = self.conn.lock();
        conn.query_row(
            "SELECT sync_token FROM calendars WHERE key = ?1",
            params![calendar_key],
            |row| row.get(0),
        )
        .optional()
        .map(|o| o.flatten())
        .map_err(Into::into)
    }

    pub fn update_calendar_cursor(&self, calendar_key: &str, token: Option<&str>) -> Result<()> {
        let conn = self.conn.lock();
        conn.execute(
            "UPDATE calendars SET sync_token = ?1, last_synced_at = ?2 WHERE key = ?3",
            params![token, Utc::now().to_rfc3339(), calendar_key],
        )?;
        Ok(())
    }

    /// Remove calendars (and their events) for a source not in `keep_keys`.
    pub fn prune_calendars(
        &self,
        account_key: &str,
        source: &str,
        keep_keys: &[String],
    ) -> Result<()> {
        let mut conn = self.conn.lock();
        let tx = conn.transaction()?;
        let existing: Vec<String> = {
            let mut stmt = tx.prepare(
                "SELECT key FROM calendars WHERE account_key = ?1 AND source = ?2",
            )?;
            let rows = stmt
                .query_map(params![account_key, source], |row| row.get(0))?
                .collect::<std::result::Result<Vec<_>, _>>()?;
            rows
        };
        for key in existing {
            if !keep_keys.contains(&key) {
                tx.execute(
                    "DELETE FROM calendar_events WHERE calendar_key = ?1 AND account_key = ?2",
                    params![key, account_key],
                )?;
                tx.execute("DELETE FROM calendars WHERE key = ?1", params![key])?;
            }
        }
        tx.commit()?;
        Ok(())
    }

    pub fn upsert_event(
        &self,
        account_key: &str,
        calendar_key: &str,
        ev: &crate::sync::calendar::UnifiedEvent,
    ) -> Result<()> {
        let conn = self.conn.lock();
        let now = Utc::now().to_rfc3339();
        let key = format!("cev_{account_key}_{}", ev.provider_id);
        conn.execute(
            "INSERT INTO calendar_events
             (key, calendar_key, account_key, title, description, location,
              start_at, end_at, all_day, timezone, status, provider_id, provider_etag,
              ical_uid, recurrence_rule, organizer_email, organizer_name, metadata,
              created_at, updated_at)
             VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13, ?14, ?15, ?16, ?17, ?18, ?19, ?19)
             ON CONFLICT(key) DO UPDATE SET
               title = excluded.title, description = excluded.description,
               location = excluded.location, start_at = excluded.start_at,
               end_at = excluded.end_at, all_day = excluded.all_day,
               timezone = excluded.timezone, status = excluded.status,
               provider_etag = excluded.provider_etag, ical_uid = excluded.ical_uid,
               recurrence_rule = excluded.recurrence_rule,
               organizer_email = excluded.organizer_email,
               organizer_name = excluded.organizer_name, metadata = excluded.metadata,
               updated_at = excluded.updated_at",
            params![
                key,
                calendar_key,
                account_key,
                ev.title,
                ev.description,
                ev.location,
                ev.start_at,
                ev.end_at,
                ev.all_day as i32,
                ev.timezone,
                ev.status,
                ev.provider_id,
                ev.etag,
                ev.ical_uid,
                ev.recurrence_rule,
                ev.organizer_email,
                ev.organizer_name,
                ev.metadata,
                now,
            ],
        )?;
        Ok(())
    }

    /// Set one event's times — a move the provider just accepted, shown before
    /// the resync rewrites the row in the provider's own form.
    pub fn set_event_times(&self, account_key: &str, event_key: &str, start_at: &str, end_at: &str) -> Result<()> {
        let conn = self.conn.lock();
        conn.execute(
            "UPDATE calendar_events SET start_at = ?1, end_at = ?2 WHERE key = ?3 AND account_key = ?4",
            params![start_at, end_at, event_key, account_key],
        )?;
        Ok(())
    }

    pub fn delete_event_by_provider_id(&self, account_key: &str, provider_id: &str) -> Result<()> {
        let conn = self.conn.lock();
        conn.execute(
            "DELETE FROM calendar_events WHERE provider_id = ?1 AND account_key = ?2",
            params![provider_id, account_key],
        )?;
        Ok(())
    }

    /// Resolve a local event key to the `(calendar_provider_id, event_provider_id)`
    /// pair the provider APIs address events by. Returns `None` if the event is
    /// unknown for this account or has no provider id (a purely local event).
    /// Used to RSVP / mutate an offline-synced event from its local key without
    /// leaking provider ids to the frontend.
    pub fn event_provider_ids(
        &self,
        account_key: &str,
        event_key: &str,
    ) -> Result<Option<(String, String)>> {
        let conn = self.conn.lock();
        conn.query_row(
            "SELECT c.provider_id, e.provider_id
             FROM calendar_events e
             JOIN calendars c ON c.key = e.calendar_key
             WHERE e.key = ?1 AND e.account_key = ?2",
            params![event_key, account_key],
            |row| {
                let cal: Option<String> = row.get(0)?;
                let ev: Option<String> = row.get(1)?;
                Ok((cal, ev))
            },
        )
        .optional()
        .map(|opt| opt.and_then(|(cal, ev)| Some((cal?, ev?))))
        .map_err(Into::into)
    }

    /// What a series edit needs about one synced instance: its calendar's and
    /// its own provider ids, its stored start, and the provider id of the
    /// series master it belongs to (None for a one-off). Rows synced before
    /// `metadata.seriesId` existed fall back to Google's `<series>_<start>`
    /// instance-id form, as the web calendar does.
    pub fn event_series_info(
        &self,
        account_key: &str,
        event_key: &str,
    ) -> Result<Option<(String, String, String, Option<String>)>> {
        let conn = self.conn.lock();
        let row = conn
            .query_row(
                "SELECT c.provider_id, e.provider_id, e.start_at, e.metadata, c.source
                 FROM calendar_events e
                 JOIN calendars c ON c.key = e.calendar_key
                 WHERE e.key = ?1 AND e.account_key = ?2",
                params![event_key, account_key],
                |row| {
                    Ok((
                        row.get::<_, Option<String>>(0)?,
                        row.get::<_, Option<String>>(1)?,
                        row.get::<_, String>(2)?,
                        row.get::<_, Option<String>>(3)?,
                        row.get::<_, Option<String>>(4)?,
                    ))
                },
            )
            .optional()?;
        let Some((Some(cal), Some(ev), start, metadata, source)) = row else { return Ok(None) };
        let series = metadata
            .and_then(|m| serde_json::from_str::<serde_json::Value>(&m).ok())
            .and_then(|m| m.get("seriesId").and_then(|v| v.as_str()).map(str::to_string))
            .or_else(|| {
                if source.as_deref() != Some("google") {
                    return None;
                }
                let (series, stamp) = ev.rsplit_once('_')?;
                let digits = stamp.trim_end_matches('Z').replace('T', "");
                (stamp.len() >= 8 && digits.chars().all(|c| c.is_ascii_digit())).then(|| series.to_string())
            });
        Ok(Some((cal, ev, start, series)))
    }

    /// Match an emailed invite's iCalendar UID to an already-synced calendar
    /// event for this account. Returns the matched event's key, the attendee's
    /// current RSVP, and the event's tz-correct absolute times (the sync already
    /// resolved the timezone the ICS may only express via a TZID we can't map).
    /// `None` when the invite isn't on any synced calendar (IMAP, or an unsynced
    /// calendar) — the caller then RSVPs by emailing a REPLY.
    ///
    /// `near_date` (an ISO `YYYY-MM-DD`, or "") disambiguates a recurring series:
    /// prefer the occurrence on the invite's own date rather than the latest.
    pub fn event_by_ical_uid(
        &self,
        account_key: &str,
        ical_uid: &str,
        attendee_email: &str,
        near_date: &str,
    ) -> Result<Option<MatchedInviteEvent>> {
        let conn = self.conn.lock();
        // The RSVP lives in the event's `metadata` JSON (attendees[].responseStatus)
        // — the `calendar_attendees` table is unused by the sync. Read it there and
        // map the self attendee's status. (Never the event's `status` column, which
        // is confirmed/cancelled and would show a bogus "You responded: confirmed".)
        let row = conn
            .query_row(
                "SELECT e.key, e.start_at, e.end_at, e.all_day, e.metadata
                 FROM calendar_events e
                 WHERE e.account_key = ?1 AND e.ical_uid = ?2
                 ORDER BY (substr(e.start_at, 1, 10) = ?3) DESC, e.start_at DESC
                 LIMIT 1",
                params![account_key, ical_uid, near_date],
                |row| {
                    Ok((
                        row.get::<_, String>(0)?,
                        row.get::<_, String>(1)?,
                        row.get::<_, String>(2)?,
                        row.get::<_, i64>(3)? != 0,
                        row.get::<_, Option<String>>(4)?,
                    ))
                },
            )
            .optional()?;
        let Some((key, start_at, end_at, all_day, metadata)) = row else {
            return Ok(None);
        };
        let response_status = metadata
            .as_deref()
            .and_then(|m| self_attendee_status(m, attendee_email));
        Ok(Some(MatchedInviteEvent { key, response_status, start_at, end_at, all_day }))
    }

    /// Remove events in a calendar whose provider id was not seen in a full sync.
    pub fn prune_unseen_events(
        &self,
        account_key: &str,
        calendar_key: &str,
        seen: &std::collections::HashSet<String>,
    ) -> Result<usize> {
        let mut conn = self.conn.lock();
        let tx = conn.transaction()?;
        let ids: Vec<String> = {
            let mut stmt = tx.prepare(
                "SELECT provider_id FROM calendar_events
                 WHERE calendar_key = ?1 AND account_key = ?2 AND provider_id IS NOT NULL",
            )?;
            let rows = stmt
                .query_map(params![calendar_key, account_key], |row| row.get(0))?
                .collect::<std::result::Result<Vec<_>, _>>()?;
            rows
        };
        let mut removed = 0;
        for id in ids {
            if !seen.contains(&id) {
                tx.execute(
                    "DELETE FROM calendar_events WHERE provider_id = ?1 AND account_key = ?2",
                    params![id, account_key],
                )?;
                removed += 1;
            }
        }
        tx.commit()?;
        Ok(removed)
    }
}
