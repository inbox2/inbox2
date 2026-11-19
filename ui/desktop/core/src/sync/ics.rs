//! Minimal RFC 5545 (iCalendar) reader for emailed meeting invites, plus a
//! `METHOD:REPLY` writer for RSVPing back to the organizer.
//!
//! We only need a handful of VEVENT fields to show an Outlook-style invite
//! banner and to answer it — not a general calendar engine (that already lives
//! in `calendar.rs`, syncing straight from the Google/Graph APIs). So this is a
//! deliberately tiny hand parser: line-unfold, then `NAME;params:value` split.
//!
//! ponytail: hand-rolled, ~1 field per line. If we ever need full VCALENDAR
//! round-tripping (VALARM, RRULE expansion, timezone VTIMEZONE resolution) reach
//! for the `icalendar` crate instead of growing this.

use serde::{Deserialize, Serialize};

/// The subset of a VEVENT an invite banner needs, plus the enclosing `METHOD`.
#[derive(Debug, Clone, Serialize, PartialEq)]
pub struct InviteInfo {
    /// VCALENDAR `METHOD` (REQUEST for an invite, REPLY, CANCEL, PUBLISH…).
    pub method: Option<String>,
    pub uid: String,
    pub summary: Option<String>,
    pub description: Option<String>,
    pub location: Option<String>,
    /// RFC 3339 best-effort; falls back to the raw ICS value if unparseable.
    /// A `TZID` form stays as a naive local wall-clock string — read it together
    /// with `timezone`, never on its own.
    pub start: Option<String>,
    pub end: Option<String>,
    /// The IANA zone `start`/`end` are expressed in: DTSTART's `TZID` param, or
    /// `UTC` for a `Z`-suffixed value. `None` for an all-day date and for a
    /// floating time (RFC 5545 says those mean "wherever the reader is").
    ///
    /// This is the whole reason the event lands at the right hour: both Google and
    /// Graph take `dateTime` + a separate `timeZone`, so we hand the zone straight
    /// through and let the provider do the arithmetic rather than resolving the tz
    /// database ourselves. Dropping it (as this parser used to) silently reinterprets
    /// the wall clock in whatever zone the device happens to be in.
    pub timezone: Option<String>,
    pub organizer_email: Option<String>,
    pub organizer_name: Option<String>,
    pub sequence: i64,
    pub all_day: bool,
}

/// Parse the first VEVENT out of a `text/calendar` payload. Returns `None` when
/// there is no VEVENT with a UID (not an invite we can act on).
pub fn parse_ics(raw: &str) -> Option<InviteInfo> {
    let lines = unfold(raw);
    let method = lines
        .iter()
        .find_map(|l| prop(l, "METHOD").map(|(_, v)| v.to_string()));
    let tz_aliases = vtimezone_locations(&lines);

    let mut in_event = false;
    let mut inv = InviteInfo {
        method,
        uid: String::new(),
        summary: None,
        description: None,
        location: None,
        start: None,
        end: None,
        timezone: None,
        organizer_email: None,
        organizer_name: None,
        sequence: 0,
        all_day: false,
    };
    for line in &lines {
        if line.eq_ignore_ascii_case("BEGIN:VEVENT") {
            in_event = true;
            continue;
        }
        if line.eq_ignore_ascii_case("END:VEVENT") {
            break; // first event only
        }
        if !in_event {
            continue;
        }
        let Some((name, params, value)) = split_prop(line) else { continue };
        match name.as_str() {
            "UID" => inv.uid = value.clone(),
            "SUMMARY" => inv.summary = Some(unescape(&value)),
            "DESCRIPTION" => inv.description = Some(unescape(&value)),
            "LOCATION" => inv.location = Some(unescape(&value)),
            "SEQUENCE" => inv.sequence = value.trim().parse().unwrap_or(0),
            "DTSTART" => {
                let (ts, all_day, tz) = parse_dt(&params, &value);
                inv.start = Some(ts);
                inv.all_day = all_day;
                inv.timezone = tz.and_then(|t| normalize_tzid(&t, &tz_aliases));
            }
            // DTEND's own TZID is ignored: an event that starts and ends in
            // different zones isn't a thing any of these senders emit, and DTSTART's
            // zone is the one both calendar APIs want for the pair.
            "DTEND" => inv.end = Some(parse_dt(&params, &value).0),
            "ORGANIZER" => {
                inv.organizer_email = mailto(&value);
                inv.organizer_name = param(&params, "CN");
            }
            _ => {}
        }
    }
    if inv.uid.is_empty() {
        return None;
    }
    Some(inv)
}

/// What the invite banner needs: the parsed VEVENT, whether it maps to a synced
/// calendar event, the current RSVP status (to preselect the answered button),
/// and the attachment id it came from (echoed back on respond).
#[derive(Debug, Clone, Serialize)]
pub struct ClientInvite {
    #[serde(flatten)]
    pub info: InviteInfo,
    pub matched_event_key: Option<String>,
    pub current_status: Option<String>,
    pub attachment_id: String,
    /// No ICS at all: the summary lane found the meeting in the body
    /// (`messages.detected_meeting`). The banner marks it as detected, and "Add to
    /// calendar" goes through `add_detected_meeting_to_calendar`.
    pub detected: bool,
}

/// A meeting the summary lane read out of an email body (no ICS attached) —
/// stored as JSON on `messages.detected_meeting`. `start`/`end` are the sender's
/// wall clock, `YYYY-MM-DDTHH:MM:SS`, no zone (a floating time).
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct DetectedMeeting {
    pub title: String,
    pub start: String,
    pub end: Option<String>,
    pub location: Option<String>,
}

impl DetectedMeeting {
    /// Validate the model's `meeting` object. `None` unless it names a real date
    /// AND clock time — a deadline or a vague "next week" is not a meeting.
    pub fn from_model(v: &serde_json::Value) -> Option<Self> {
        use chrono::NaiveDateTime;
        let text = |k: &str| v.get(k).and_then(|x| x.as_str()).map(str::trim).filter(|x| !x.is_empty());
        // "2026-10-07T16:30", also with a space for the T or no separator at all
        // (Apple Intelligence writes "2026-10-0716:30"), and seconds or an offset the
        // model added anyway (dropped: the time is the sender's wall clock).
        let parse = |s: &str| {
            let (date, time) = (s.get(..10)?, s.get(10..)?);
            let time = time.trim_start_matches(['T', ' ']);
            NaiveDateTime::parse_from_str(&format!("{date}T{}", time.get(..5)?), "%Y-%m-%dT%H:%M").ok()
        };
        let start = parse(text("start")?)?;
        let end = text("end").and_then(parse).filter(|e| *e > start);
        let fmt = |d: NaiveDateTime| d.format("%Y-%m-%dT%H:%M:00").to_string();
        Some(Self {
            title: text("title").unwrap_or("Meeting").to_string(),
            start: fmt(start),
            end: end.map(fmt),
            location: text("location").map(str::to_string),
        })
    }

    /// As an event: `PUBLISH` (nothing to answer) with a UID stable per message,
    /// so adding it twice is caught by the `ics_added` marker.
    pub fn into_info(self, message_key: &str) -> InviteInfo {
        InviteInfo {
            method: Some("PUBLISH".into()),
            uid: format!("detected-{message_key}@inbox2"),
            summary: Some(self.title),
            description: None,
            location: self.location,
            start: Some(self.start),
            end: self.end,
            timezone: None,
            organizer_email: None,
            organizer_name: None,
            sequence: 0,
            all_day: false,
        }
    }
}

/// Build a `METHOD:REPLY` VCALENDAR answering an invite. `partstat` is the RFC
/// 5545 attendee status — `ACCEPTED` | `DECLINED` | `TENTATIVE`. `dtstamp` is an
/// RFC 5545 UTC timestamp (`20240115T120000Z`) — passed in so the caller owns
/// the clock (the core forbids `Utc::now()` in some contexts, and tests need it
/// deterministic).
pub fn build_reply(
    inv: &InviteInfo,
    attendee_email: &str,
    attendee_name: Option<&str>,
    partstat: &str,
    dtstamp: &str,
) -> String {
    let organizer = inv.organizer_email.as_deref().unwrap_or("");
    let cn = attendee_name
        .map(|n| format!(";CN={}", n))
        .unwrap_or_default();
    // Reply echoes the request's UID + SEQUENCE so the organizer's client
    // correlates it to the right event/version.
    format!(
        "BEGIN:VCALENDAR\r\n\
         VERSION:2.0\r\n\
         PRODID:-//inbox2//invite//EN\r\n\
         METHOD:REPLY\r\n\
         BEGIN:VEVENT\r\n\
         UID:{uid}\r\n\
         SEQUENCE:{seq}\r\n\
         DTSTAMP:{stamp}\r\n\
         ORGANIZER:mailto:{org}\r\n\
         ATTENDEE;PARTSTAT={ps}{cn}:mailto:{att}\r\n\
         SUMMARY:{summary}\r\n\
         END:VEVENT\r\n\
         END:VCALENDAR\r\n",
        uid = inv.uid,
        seq = inv.sequence,
        stamp = dtstamp,
        org = organizer,
        ps = partstat,
        cn = cn,
        att = attendee_email,
        summary = escape(inv.summary.as_deref().unwrap_or("")),
    )
}

/// Map the client-facing response verb to the RFC 5545 PARTSTAT + a subject
/// prefix ("Accepted"/"Declined"/"Tentative"). Single source so the FFI, the
/// reply body, and the subject stay in lockstep.
pub fn response_to_partstat(response: &str) -> Option<(&'static str, &'static str)> {
    match response {
        "accepted" => Some(("ACCEPTED", "Accepted")),
        "declined" => Some(("DECLINED", "Declined")),
        "tentative" => Some(("TENTATIVE", "Tentative")),
        _ => None,
    }
}

// ── internals ───────────────────────────────────────────────────────────────

/// RFC 5545 line unfolding: a CRLF (or LF) followed by a space/tab continues the
/// previous line.
fn unfold(raw: &str) -> Vec<String> {
    let mut out: Vec<String> = Vec::new();
    for line in raw.split('\n') {
        let line = line.strip_suffix('\r').unwrap_or(line);
        if let Some(rest) = line.strip_prefix([' ', '\t']) {
            if let Some(last) = out.last_mut() {
                last.push_str(rest);
                continue;
            }
        }
        out.push(line.to_string());
    }
    out
}

/// Split `NAME;PARAM=x;PARAM2=y:VALUE` into (`NAME` upper, params-string, value).
fn split_prop(line: &str) -> Option<(String, String, String)> {
    let colon = line.find(':')?;
    let (head, value) = line.split_at(colon);
    let value = value[1..].to_string();
    let (name, params) = match head.find(';') {
        Some(i) => (&head[..i], &head[i + 1..]),
        None => (head, ""),
    };
    Some((name.to_ascii_uppercase(), params.to_string(), value))
}

/// Match a bare `NAME:value` (no params) — used for top-level METHOD.
fn prop<'a>(line: &'a str, name: &str) -> Option<(&'a str, &'a str)> {
    let (n, v) = line.split_once(':')?;
    if n.eq_ignore_ascii_case(name) {
        Some((n, v))
    } else {
        None
    }
}

/// Extract a parameter value (e.g. CN, TZID) from a params-string.
fn param(params: &str, key: &str) -> Option<String> {
    params.split(';').find_map(|p| {
        let (k, v) = p.split_once('=')?;
        if k.eq_ignore_ascii_case(key) {
            Some(v.trim_matches('"').to_string())
        } else {
            None
        }
    })
}

fn mailto(value: &str) -> Option<String> {
    let v = value.trim();
    let addr = v.strip_prefix("mailto:").or_else(|| v.strip_prefix("MAILTO:")).unwrap_or(v);
    if addr.contains('@') {
        Some(addr.to_string())
    } else {
        None
    }
}

/// Parse a DTSTART/DTEND value. Returns (ts, all_day, timezone).
///
/// `VALUE=DATE` (no time) is an all-day event. A trailing `Z` is UTC. A `TZID`
/// param names the zone the wall clock is in — kept naive and reported alongside,
/// because resolving it here would need the full tz database while both calendar
/// APIs accept the pair directly.
fn parse_dt(params: &str, value: &str) -> (String, bool, Option<String>) {
    use chrono::{NaiveDate, NaiveDateTime, TimeZone, Utc};
    let v = value.trim();
    let is_date = param(params, "VALUE").as_deref() == Some("DATE") || v.len() == 8;
    if is_date {
        if let Ok(d) = NaiveDate::parse_from_str(v, "%Y%m%d") {
            return (d.format("%Y-%m-%d").to_string(), true, None);
        }
        return (v.to_string(), true, None);
    }
    // UTC form: 20240115T130000Z. Kept as an absolute RFC 3339 instant so existing
    // client rendering is unchanged; `wall_clock` strips the offset back off for
    // the calendar-API write path.
    if let Some(stripped) = v.strip_suffix('Z') {
        if let Ok(dt) = NaiveDateTime::parse_from_str(stripped, "%Y%m%dT%H%M%S") {
            return (Utc.from_utc_datetime(&dt).to_rfc3339(), false, Some("UTC".to_string()));
        }
    }
    // Zoned or floating form: 20240115T130000, optionally with TZID=Europe/Amsterdam.
    if let Ok(dt) = NaiveDateTime::parse_from_str(v, "%Y%m%dT%H%M%S") {
        return (dt.format("%Y-%m-%dT%H:%M:%S").to_string(), false, param(params, "TZID"));
    }
    (v.to_string(), false, param(params, "TZID"))
}

/// Map each `VTIMEZONE`'s `TZID` to its `X-LIC-LOCATION`, the IANA name libical
/// (and ical.net, and anything that copied them) writes alongside a non-IANA id.
/// It is the sender telling us what its own zone id means, so it beats any table
/// we could keep.
fn vtimezone_locations(lines: &[String]) -> Vec<(String, String)> {
    let mut out = Vec::new();
    let mut tzid: Option<String> = None;
    let mut in_vtimezone = false;
    for line in lines {
        if line.eq_ignore_ascii_case("BEGIN:VTIMEZONE") {
            in_vtimezone = true;
            tzid = None;
            continue;
        }
        if line.eq_ignore_ascii_case("END:VTIMEZONE") {
            in_vtimezone = false;
            tzid = None;
            continue;
        }
        if !in_vtimezone {
            continue;
        }
        // Only the VTIMEZONE's own two properties; the nested STANDARD/DAYLIGHT
        // blocks carry TZNAME, which is a display label, not a zone id.
        let Some((name, _, value)) = split_prop(line) else { continue };
        match name.as_str() {
            "TZID" => tzid = Some(value.trim().to_string()),
            "X-LIC-LOCATION" => {
                if let Some(id) = &tzid {
                    out.push((id.clone(), value.trim().to_string()));
                }
            }
            _ => {}
        }
    }
    out
}

/// Turn whatever a sender put in `TZID` into a name Google and Graph will accept,
/// or `None` to fall back to the reader's own zone.
///
/// Google 400s ("Invalid time zone definition for start time") on anything that
/// isn't an IANA id, and Outlook-lineage senders routinely write Windows names —
/// the appointment confirmation that prompted this carried
/// `TZID:W. Europe Standard Time`. Three sources, best first:
///
/// 1. the file's own `X-LIC-LOCATION` for that TZID (authoritative — the sender
///    is telling us the IANA equivalent),
/// 2. the id itself when it already looks IANA (a `Region/City` pair, after
///    stripping a `/vendor/version/` prefix as Mozilla and Citadel emit),
/// 3. the CLDR Windows→IANA table, for the Outlook files that ship neither.
fn normalize_tzid(tzid: &str, aliases: &[(String, String)]) -> Option<String> {
    let raw = tzid.trim().trim_matches('"');
    if raw.is_empty() {
        return None;
    }
    if let Some((_, iana)) = aliases.iter().find(|(id, _)| id == raw) {
        if !iana.is_empty() {
            return Some(iana.clone());
        }
    }
    // `/mozilla.org/20050126_1/Europe/Amsterdam` → `Europe/Amsterdam`.
    let trimmed = if raw.starts_with('/') {
        let parts: Vec<&str> = raw.trim_start_matches('/').split('/').collect();
        if parts.len() >= 2 { parts[parts.len() - 2..].join("/") } else { raw.to_string() }
    } else {
        raw.to_string()
    };
    // IANA ids are `Region/City`; the only common ones without a slash are these.
    if trimmed.contains('/') || matches!(trimmed.as_str(), "UTC" | "GMT") {
        return Some(trimmed);
    }
    windows_to_iana(&trimmed).map(str::to_string)
}

/// CLDR `windowsZones` defaults (territory `001`) — the Windows zone names Outlook
/// and friends write into `TZID`, mapped to the IANA id the calendar APIs want.
///
/// ponytail: a flat table, not a CLDR dependency. It only has to move when Windows
/// adds a zone, which is roughly never; an unlisted name falls back to the reader's
/// zone rather than failing the add.
pub(crate) fn windows_to_iana(name: &str) -> Option<&'static str> {
    Some(match name {
        "Dateline Standard Time" => "Etc/GMT+12",
        "UTC-11" => "Etc/GMT+11",
        "Aleutian Standard Time" => "America/Adak",
        "Hawaiian Standard Time" => "Pacific/Honolulu",
        "Marquesas Standard Time" => "Pacific/Marquesas",
        "Alaskan Standard Time" => "America/Anchorage",
        "UTC-09" => "Etc/GMT+9",
        "Pacific Standard Time (Mexico)" => "America/Tijuana",
        "UTC-08" => "Etc/GMT+8",
        "Pacific Standard Time" => "America/Los_Angeles",
        "US Mountain Standard Time" => "America/Phoenix",
        "Mountain Standard Time (Mexico)" => "America/Chihuahua",
        "Mountain Standard Time" => "America/Denver",
        "Yukon Standard Time" => "America/Whitehorse",
        "Central America Standard Time" => "America/Guatemala",
        "Central Standard Time" => "America/Chicago",
        "Easter Island Standard Time" => "Pacific/Easter",
        "Central Standard Time (Mexico)" => "America/Mexico_City",
        "Canada Central Standard Time" => "America/Regina",
        "SA Pacific Standard Time" => "America/Bogota",
        "Eastern Standard Time (Mexico)" => "America/Cancun",
        "Eastern Standard Time" => "America/New_York",
        "Haiti Standard Time" => "America/Port-au-Prince",
        "Cuba Standard Time" => "America/Havana",
        "US Eastern Standard Time" => "America/Indianapolis",
        "Turks And Caicos Standard Time" => "America/Grand_Turk",
        "Paraguay Standard Time" => "America/Asuncion",
        "Atlantic Standard Time" => "America/Halifax",
        "Venezuela Standard Time" => "America/Caracas",
        "Central Brazilian Standard Time" => "America/Cuiaba",
        "SA Western Standard Time" => "America/La_Paz",
        "Pacific SA Standard Time" => "America/Santiago",
        "Newfoundland Standard Time" => "America/St_Johns",
        "Tocantins Standard Time" => "America/Araguaina",
        "E. South America Standard Time" => "America/Sao_Paulo",
        "SA Eastern Standard Time" => "America/Cayenne",
        "Argentina Standard Time" => "America/Buenos_Aires",
        "Montevideo Standard Time" => "America/Montevideo",
        "Magallanes Standard Time" => "America/Punta_Arenas",
        "Saint Pierre Standard Time" => "America/Miquelon",
        "Bahia Standard Time" => "America/Bahia",
        "UTC-02" => "Etc/GMT+2",
        "Greenland Standard Time" => "America/Godthab",
        "Mid-Atlantic Standard Time" => "Etc/GMT+2",
        "Azores Standard Time" => "Atlantic/Azores",
        "Cape Verde Standard Time" => "Atlantic/Cape_Verde",
        "UTC" => "Etc/UTC",
        "GMT Standard Time" => "Europe/London",
        "Greenwich Standard Time" => "Atlantic/Reykjavik",
        "Sao Tome Standard Time" => "Africa/Sao_Tome",
        "Morocco Standard Time" => "Africa/Casablanca",
        "W. Europe Standard Time" => "Europe/Berlin",
        "Central Europe Standard Time" => "Europe/Budapest",
        "Romance Standard Time" => "Europe/Paris",
        "Central European Standard Time" => "Europe/Warsaw",
        "W. Central Africa Standard Time" => "Africa/Lagos",
        "Jordan Standard Time" => "Asia/Amman",
        "GTB Standard Time" => "Europe/Bucharest",
        "Middle East Standard Time" => "Asia/Beirut",
        "Egypt Standard Time" => "Africa/Cairo",
        "E. Europe Standard Time" => "Europe/Chisinau",
        "Syria Standard Time" => "Asia/Damascus",
        "West Bank Standard Time" => "Asia/Hebron",
        "South Africa Standard Time" => "Africa/Johannesburg",
        "FLE Standard Time" => "Europe/Kiev",
        "Israel Standard Time" => "Asia/Jerusalem",
        "South Sudan Standard Time" => "Africa/Juba",
        "Kaliningrad Standard Time" => "Europe/Kaliningrad",
        "Sudan Standard Time" => "Africa/Khartoum",
        "Libya Standard Time" => "Africa/Tripoli",
        "Namibia Standard Time" => "Africa/Windhoek",
        "Arabic Standard Time" => "Asia/Baghdad",
        "Turkey Standard Time" => "Europe/Istanbul",
        "Arab Standard Time" => "Asia/Riyadh",
        "Belarus Standard Time" => "Europe/Minsk",
        "Russian Standard Time" => "Europe/Moscow",
        "E. Africa Standard Time" => "Africa/Nairobi",
        "Volgograd Standard Time" => "Europe/Volgograd",
        "Iran Standard Time" => "Asia/Tehran",
        "Arabian Standard Time" => "Asia/Dubai",
        "Astrakhan Standard Time" => "Europe/Astrakhan",
        "Azerbaijan Standard Time" => "Asia/Baku",
        "Russia Time Zone 3" => "Europe/Samara",
        "Mauritius Standard Time" => "Indian/Mauritius",
        "Saratov Standard Time" => "Europe/Saratov",
        "Georgian Standard Time" => "Asia/Tbilisi",
        "Caucasus Standard Time" => "Asia/Yerevan",
        "Afghanistan Standard Time" => "Asia/Kabul",
        "West Asia Standard Time" => "Asia/Tashkent",
        "Qyzylorda Standard Time" => "Asia/Qyzylorda",
        "Ekaterinburg Standard Time" => "Asia/Yekaterinburg",
        "Pakistan Standard Time" => "Asia/Karachi",
        "India Standard Time" => "Asia/Calcutta",
        "Sri Lanka Standard Time" => "Asia/Colombo",
        "Nepal Standard Time" => "Asia/Katmandu",
        "Central Asia Standard Time" => "Asia/Almaty",
        "Bangladesh Standard Time" => "Asia/Dhaka",
        "Omsk Standard Time" => "Asia/Omsk",
        "Myanmar Standard Time" => "Asia/Rangoon",
        "SE Asia Standard Time" => "Asia/Bangkok",
        "Altai Standard Time" => "Asia/Barnaul",
        "W. Mongolia Standard Time" => "Asia/Hovd",
        "North Asia Standard Time" => "Asia/Krasnoyarsk",
        "N. Central Asia Standard Time" => "Asia/Novosibirsk",
        "Tomsk Standard Time" => "Asia/Tomsk",
        "China Standard Time" => "Asia/Shanghai",
        "North Asia East Standard Time" => "Asia/Irkutsk",
        "Singapore Standard Time" => "Asia/Singapore",
        "W. Australia Standard Time" => "Australia/Perth",
        "Taipei Standard Time" => "Asia/Taipei",
        "Ulaanbaatar Standard Time" => "Asia/Ulaanbaatar",
        "Aus Central W. Standard Time" => "Australia/Eucla",
        "Transbaikal Standard Time" => "Asia/Chita",
        "Tokyo Standard Time" => "Asia/Tokyo",
        "North Korea Standard Time" => "Asia/Pyongyang",
        "Korea Standard Time" => "Asia/Seoul",
        "Yakutsk Standard Time" => "Asia/Yakutsk",
        "Cen. Australia Standard Time" => "Australia/Adelaide",
        "AUS Central Standard Time" => "Australia/Darwin",
        "E. Australia Standard Time" => "Australia/Brisbane",
        "AUS Eastern Standard Time" => "Australia/Sydney",
        "West Pacific Standard Time" => "Pacific/Port_Moresby",
        "Tasmania Standard Time" => "Australia/Hobart",
        "Vladivostok Standard Time" => "Asia/Vladivostok",
        "Lord Howe Standard Time" => "Australia/Lord_Howe",
        "Bougainville Standard Time" => "Pacific/Bougainville",
        "Russia Time Zone 10" => "Asia/Srednekolymsk",
        "Magadan Standard Time" => "Asia/Magadan",
        "Norfolk Standard Time" => "Pacific/Norfolk",
        "Sakhalin Standard Time" => "Asia/Sakhalin",
        "Central Pacific Standard Time" => "Pacific/Guadalcanal",
        "Russia Time Zone 11" => "Asia/Kamchatka",
        "New Zealand Standard Time" => "Pacific/Auckland",
        "UTC+12" => "Etc/GMT-12",
        "Fiji Standard Time" => "Pacific/Fiji",
        "Chatham Islands Standard Time" => "Pacific/Chatham",
        "UTC+13" => "Etc/GMT-13",
        "Tonga Standard Time" => "Pacific/Tongatapu",
        "Samoa Standard Time" => "Pacific/Apia",
        "Line Islands Standard Time" => "Pacific/Kiritimati",
        _ => return None,
    })
}

/// Strip any zone suffix from a timestamp, leaving the bare local wall clock
/// (`2024-01-15T13:00:00+01:00` → `2024-01-15T13:00:00`).
///
/// Both calendar APIs want `dateTime` *without* an offset plus a separate
/// `timeZone` — Graph rejects an offset outright, and Google silently lets the
/// offset win over `timeZone`. So every value we send goes through here, paired
/// with the zone it belongs to.
pub fn wall_clock(ts: &str) -> &str {
    let date_len = "0000-00-00T00:00:00".len();
    if ts.len() <= date_len {
        return ts;
    }
    match ts[date_len..].find(['Z', '+']) {
        Some(i) => &ts[..date_len + i],
        // A negative offset only: '-' also appears inside the date, so look after it.
        None => match ts[date_len..].find('-') {
            Some(i) => &ts[..date_len + i],
            None => ts,
        },
    }
}

/// RFC 5545 TEXT unescape (`\,` `\;` `\n` `\\`).
fn unescape(s: &str) -> String {
    let mut out = String::with_capacity(s.len());
    let mut chars = s.chars();
    while let Some(c) = chars.next() {
        if c == '\\' {
            match chars.next() {
                Some('n') | Some('N') => out.push('\n'),
                Some(other) => out.push(other),
                None => {}
            }
        } else {
            out.push(c);
        }
    }
    out
}

/// RFC 5545 TEXT escape for the values we write back (SUMMARY).
fn escape(s: &str) -> String {
    s.replace('\\', "\\\\")
        .replace(';', "\\;")
        .replace(',', "\\,")
        .replace('\n', "\\n")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn detected_meeting_needs_a_date_and_a_clock_time() {
        let m = DetectedMeeting::from_model(&serde_json::json!({
            "title": "Viewing", "start": "2026-10-07T16:30", "end": "2026-10-07T16:00", "location": " Rotterdam "
        }))
        .unwrap();
        assert_eq!(m.start, "2026-10-07T16:30:00");
        let glued = DetectedMeeting::from_model(&serde_json::json!({"start": "2026-10-0716:30", "end": "2026-10-07THH:MM"})).unwrap();
        assert_eq!((glued.start.as_str(), glued.end), ("2026-10-07T16:30:00", None));
        let spaced = DetectedMeeting::from_model(&serde_json::json!({"start": "2026-10-07 16:30:00+02:00"})).unwrap();
        assert_eq!(spaced.start, "2026-10-07T16:30:00");
        assert_eq!(m.end, None, "an end before the start is dropped");
        assert_eq!(m.location.as_deref(), Some("Rotterdam"));
        assert_eq!(m.clone().into_info("msg_1").uid, "detected-msg_1@inbox2");
        assert!(DetectedMeeting::from_model(&serde_json::json!({"start": "2026-10-07"})).is_none());
        assert!(DetectedMeeting::from_model(&serde_json::json!({"start": "next Friday"})).is_none());
        assert!(DetectedMeeting::from_model(&serde_json::Value::Null).is_none());
    }

    const REQUEST: &str = "BEGIN:VCALENDAR\r\nVERSION:2.0\r\nMETHOD:REQUEST\r\nBEGIN:VEVENT\r\nUID:abc-123@example.com\r\nSEQUENCE:2\r\nSUMMARY:Sprint planning\\, week 3\r\nLOCATION:Room 4\r\nDTSTART:20240115T130000Z\r\nDTEND:20240115T140000Z\r\nORGANIZER;CN=Alice:mailto:alice@example.com\r\nATTENDEE;PARTSTAT=NEEDS-ACTION:mailto:me@example.com\r\nEND:VEVENT\r\nEND:VCALENDAR\r\n";

    #[test]
    fn parses_request_and_builds_reply() {
        let inv = parse_ics(REQUEST).expect("an invite");
        assert_eq!(inv.method.as_deref(), Some("REQUEST"));
        assert_eq!(inv.uid, "abc-123@example.com");
        assert_eq!(inv.summary.as_deref(), Some("Sprint planning, week 3")); // unescaped
        assert_eq!(inv.location.as_deref(), Some("Room 4"));
        assert_eq!(inv.sequence, 2);
        assert!(!inv.all_day);
        assert!(inv.start.as_deref().unwrap().starts_with("2024-01-15T13:00:00"));
        assert_eq!(inv.organizer_email.as_deref(), Some("alice@example.com"));
        assert_eq!(inv.organizer_name.as_deref(), Some("Alice"));

        let (ps, prefix) = response_to_partstat("accepted").unwrap();
        assert_eq!((ps, prefix), ("ACCEPTED", "Accepted"));
        let reply = build_reply(&inv, "me@example.com", Some("Me"), ps, "20240110T090000Z");
        assert!(reply.contains("METHOD:REPLY"));
        assert!(reply.contains("UID:abc-123@example.com"));
        assert!(reply.contains("SEQUENCE:2")); // echoes the request version
        assert!(reply.contains("ATTENDEE;PARTSTAT=ACCEPTED;CN=Me:mailto:me@example.com"));
        assert!(reply.contains("ORGANIZER:mailto:alice@example.com"));
    }

    #[test]
    fn all_day_and_folded_lines() {
        let ics = "BEGIN:VCALENDAR\nMETHOD:REQUEST\nBEGIN:VEVENT\nUID:d1\nDTSTART;VALUE=DATE:20240115\nSUMMARY:Off-\n site day\nEND:VEVENT\nEND:VCALENDAR\n";
        let inv = parse_ics(ics).unwrap();
        assert!(inv.all_day);
        assert_eq!(inv.start.as_deref(), Some("2024-01-15"));
        assert_eq!(inv.summary.as_deref(), Some("Off-site day")); // unfolded
    }

    /// The bug this guards: a `TZID` DTSTART used to parse to a bare wall clock with
    /// the zone thrown away, so pushing it to a calendar API booked the hour in
    /// whatever zone the device (or the API default) happened to be.
    #[test]
    fn keeps_the_tzid_off_dtstart() {
        let ics = "BEGIN:VCALENDAR\nMETHOD:PUBLISH\nBEGIN:VEVENT\nUID:tz1\n\
                   DTSTART;TZID=Europe/Amsterdam:20250916T100000\n\
                   DTEND;TZID=Europe/Amsterdam:20250916T110000\nSUMMARY:Haircut\nEND:VEVENT\nEND:VCALENDAR\n";
        let inv = parse_ics(ics).unwrap();
        assert_eq!(inv.timezone.as_deref(), Some("Europe/Amsterdam"));
        // Naive on purpose — the zone travels beside it, it is not baked in.
        assert_eq!(inv.start.as_deref(), Some("2025-09-16T10:00:00"));
        assert_eq!(inv.end.as_deref(), Some("2025-09-16T11:00:00"));
        assert_eq!(inv.method.as_deref(), Some("PUBLISH"));
    }

    #[test]
    fn utc_and_floating_forms_report_their_zone() {
        let utc = parse_ics(REQUEST).unwrap();
        assert_eq!(utc.timezone.as_deref(), Some("UTC"));

        // No Z, no TZID: RFC 5545 floating — whoever reads it uses their own zone.
        let floating = parse_ics(
            "BEGIN:VCALENDAR\nBEGIN:VEVENT\nUID:f1\nDTSTART:20250916T100000\nEND:VEVENT\nEND:VCALENDAR\n",
        )
        .unwrap();
        assert_eq!(floating.timezone, None);
        assert_eq!(floating.start.as_deref(), Some("2025-09-16T10:00:00"));

        // An all-day date carries no zone at all.
        let all_day = parse_ics(
            "BEGIN:VCALENDAR\nBEGIN:VEVENT\nUID:a1\nDTSTART;VALUE=DATE:20250916\nEND:VEVENT\nEND:VCALENDAR\n",
        )
        .unwrap();
        assert_eq!(all_day.timezone, None);
        assert!(all_day.all_day);
    }

    /// Graph rejects a `dateTime` carrying an offset and Google lets the offset
    /// override `timeZone`, so the write path must hand over a bare wall clock.
    #[test]
    fn wall_clock_strips_every_offset_form() {
        assert_eq!(wall_clock("2025-09-16T10:00:00+02:00"), "2025-09-16T10:00:00");
        assert_eq!(wall_clock("2025-09-16T10:00:00-05:00"), "2025-09-16T10:00:00");
        assert_eq!(wall_clock("2025-09-16T10:00:00Z"), "2025-09-16T10:00:00");
        assert_eq!(wall_clock("2025-09-16T10:00:00"), "2025-09-16T10:00:00");
        assert_eq!(wall_clock("2025-09-16"), "2025-09-16"); // all-day date, untouched
    }

    /// The real appointment confirmation that surfaced this (Timely / ical.net):
    /// a Windows zone id in TZID, the IANA name only in X-LIC-LOCATION. Sending the
    /// TZID verbatim is what made Google answer
    /// "Invalid time zone definition for start time".
    #[test]
    fn windows_tzid_resolves_through_x_lic_location() {
        let ics = "BEGIN:VCALENDAR\r\nMETHOD:PUBLISH\r\nBEGIN:VTIMEZONE\r\n\
                   TZID:W. Europe Standard Time\r\nX-LIC-LOCATION:Europe/Berlin\r\n\
                   BEGIN:STANDARD\r\nTZNAME:W. Europe Standard Time\r\nTZOFFSETTO:+0100\r\nEND:STANDARD\r\n\
                   END:VTIMEZONE\r\nBEGIN:VEVENT\r\nUID:BG438296294\r\n\
                   DTSTART;TZID=W. Europe Standard Time:20260916T100000\r\n\
                   DTEND;TZID=W. Europe Standard Time:20260916T110000\r\n\
                   SUMMARY:Chop Men\r\nEND:VEVENT\r\nEND:VCALENDAR\r\n";
        let inv = parse_ics(ics).unwrap();
        assert_eq!(inv.timezone.as_deref(), Some("Europe/Berlin"));
        assert_eq!(inv.start.as_deref(), Some("2026-09-16T10:00:00"));
    }

    /// Outlook writes the same Windows id with no X-LIC-LOCATION at all, so the
    /// table has to carry it. Same zone, reached the other way.
    #[test]
    fn windows_tzid_resolves_through_the_table() {
        let ics = "BEGIN:VCALENDAR\r\nMETHOD:REQUEST\r\nBEGIN:VEVENT\r\nUID:o1\r\n\
                   DTSTART;TZID=W. Europe Standard Time:20260916T100000\r\nEND:VEVENT\r\nEND:VCALENDAR\r\n";
        assert_eq!(parse_ics(ics).unwrap().timezone.as_deref(), Some("Europe/Berlin"));
    }

    #[test]
    fn tzid_normalisation_covers_the_other_shapes() {
        let none: Vec<(String, String)> = Vec::new();
        // Already IANA — passed through untouched.
        assert_eq!(normalize_tzid("Europe/Amsterdam", &none).as_deref(), Some("Europe/Amsterdam"));
        assert_eq!(normalize_tzid("UTC", &none).as_deref(), Some("UTC"));
        // Mozilla/Citadel-style prefixed ids keep only the Region/City tail.
        assert_eq!(
            normalize_tzid("/mozilla.org/20050126_1/Europe/Amsterdam", &none).as_deref(),
            Some("Europe/Amsterdam")
        );
        // Quoted values appear in the wild too.
        assert_eq!(normalize_tzid("\"Romance Standard Time\"", &none).as_deref(), Some("Europe/Paris"));
        // Unrecognised and slash-less: no guess — the caller falls back to the
        // reader's own zone, which beats a 400.
        assert_eq!(normalize_tzid("Some Made Up Zone", &none), None);
        assert_eq!(normalize_tzid("", &none), None);
        // An X-LIC-LOCATION for a DIFFERENT tzid must not be borrowed.
        let aliases = vec![("Other Zone".to_string(), "Asia/Tokyo".to_string())];
        assert_eq!(normalize_tzid("W. Europe Standard Time", &aliases).as_deref(), Some("Europe/Berlin"));
    }

    #[test]
    fn non_invite_returns_none() {
        assert!(parse_ics("just some text").is_none());
        assert!(parse_ics("BEGIN:VCALENDAR\nEND:VCALENDAR\n").is_none()); // no VEVENT/UID
    }
}
