//! The daily brief — assembled from the local store, shared by all clients.
//!
//! Greeting + time-of-day window logic, plus three tracked sections:
//!   - unread: the total count, and a one-line summary of each NEW unread thread
//!     ("mail from X, subject Y, briefly about Z") — announced once, never repeated.
//!   - urgent / important triage: announced when the set changes, otherwise only
//!     repeated in the morning (with a "how long ago" cue).
//! Produces both a deterministic spoken fallback and a structured facts prompt.

use crate::sync::model::ConversationStatus;
use crate::sync::store::SyncStore;
use crate::sync::threading::normalize_subject;
use crate::triage::TriageLabel;
use chrono::{DateTime, Duration, Local, TimeZone, Timelike};
use rusqlite::params;
use std::collections::HashSet;
use std::sync::OnceLock;

/// `WHERE` fragment excluding conversations hidden from the brief. Built from
/// [`ConversationStatus`] so the filter can't drift from the enum's strings.
fn status_filter() -> &'static str {
    static FILTER: OnceLock<String> = OnceLock::new();
    FILTER.get_or_init(|| {
        format!(
            "status NOT IN ('{}','{}','{}')",
            ConversationStatus::Archived.as_str(),
            ConversationStatus::Trash.as_str(),
            ConversationStatus::Spam.as_str(),
        )
    })
}

/// Excludes phantom shells — rows a provider sync ghost left with neither subject
/// nor sender. They can never be announced sensibly: the phrasing LLM turns
/// `"" from nobody` into invented mail ("you have an urgent request").
const CONTENT_FILTER: &str =
    "(COALESCE(subject,'') <> '' OR COALESCE(from_address,'') <> '')";

#[derive(Clone, Copy, PartialEq, Eq)]
pub enum Window {
    Morning,
    Afternoon,
    Evening,
}

impl Window {
    fn from_hour(hour: u32) -> Self {
        if hour < 12 {
            Window::Morning
        } else if hour < 17 {
            Window::Afternoon
        } else {
            Window::Evening
        }
    }
    fn greeting(self) -> &'static str {
        match self {
            Window::Morning => "Good morning",
            Window::Afternoon => "Good afternoon",
            Window::Evening => "Good evening",
        }
    }
    fn label(self) -> &'static str {
        match self {
            Window::Morning => "morning",
            Window::Afternoon => "afternoon",
            Window::Evening => "evening",
        }
    }
    fn meetings_empty(self) -> &'static str {
        // Morning/afternoon look ahead to tomorrow when today's done, so an empty set
        // here means nothing on either day.
        match self {
            Window::Morning => "Nothing is on your calendar today or tomorrow.",
            Window::Afternoon => "Nothing else is on your calendar today, and tomorrow is clear.",
            Window::Evening => "Nothing else is scheduled today or tomorrow.",
        }
    }
    fn signoff(self) -> &'static str {
        match self {
            Window::Morning => "Have a great day.",
            Window::Afternoon => "Have a productive afternoon.",
            Window::Evening => "That's your evening and tomorrow at a glance.",
        }
    }
}

struct UnreadItem {
    sender: String,
    subject: String,
    about: String,
}

struct TriageItem {
    key: String,
    subject: String,
    sender: String,
    summary: Option<String>,
}

struct Meeting {
    time_label: String,
    title: String,
}

/// One triage category as it should appear in the brief. `items` empty = suppressed.
struct Section {
    items: Vec<TriageItem>,
    since_last_secs: Option<i64>,
    is_repeat: bool,
}

pub struct Brief {
    window: Window,
    unread_count: i64,
    /// New unread threads to summarise this time (already-announced ones excluded).
    unread_new: Vec<UnreadItem>,
    urgent: Section,
    important: Section,
    /// Open questions from the last week still waiting on the OWNER's reply
    /// (triage = needs_answer). Ordered most-important first.
    awaiting_you: Vec<TriageItem>,
    /// Open questions from the last week we're waiting on SOMEONE ELSE to answer
    /// (triage = waiting_reply or needs_answer_other). Ordered most-important first.
    awaiting_others: Vec<TriageItem>,
    meetings: Vec<Meeting>,
    /// The listed meetings are TOMORROW's — today had nothing left, so we looked
    /// ahead. Drives "Tomorrow you have…" phrasing instead of "Today…".
    meetings_are_tomorrow: bool,
    /// Today has more timed events than the trailing 61-day daily average.
    busy_day: bool,
}

/// How far back the "open questions" follow-up scan reaches.
const FOLLOWUP_DAYS: i64 = 7;

impl Brief {
    /// Deterministic spoken brief — used when no LLM is available.
    pub fn spoken_fallback(&self) -> String {
        let mut parts: Vec<String> = vec![format!("{}.", self.window.greeting())];
        parts.push(if self.unread_count == 0 {
            "Your inbox is clear — no unread messages.".into()
        } else {
            format!("You have {} unread message{}.", self.unread_count, plural(self.unread_count))
        });
        if !self.unread_new.is_empty() {
            let lines: Vec<String> = self
                .unread_new
                .iter()
                .map(|u| format!("from {}, subject {}, about {}", u.sender, u.subject, u.about))
                .collect();
            parts.push(format!(
                "{} new since last time: {}.",
                self.unread_new.len(),
                lines.join("; ")
            ));
        }
        if let Some(s) = self.spoken_section(&self.urgent, "urgent") {
            parts.push(s);
        }
        if let Some(s) = self.spoken_section(&self.important, "important") {
            parts.push(s);
        }
        if let Some(s) = self.spoken_followups() {
            parts.push(s);
        }
        if self.meetings.is_empty() {
            parts.push(self.window.meetings_empty().into());
        } else {
            if self.busy_day {
                parts.push("You have a busy day ahead.".into());
            }
            let lead = if self.meetings_are_tomorrow {
                "Tomorrow"
            } else {
                match self.window {
                    Window::Morning => "Today",
                    Window::Afternoon => "Later today",
                    Window::Evening => "Coming up",
                }
            };
            // Sequential, easy-to-follow phrasing: "Today, first at 11 AM you have the
            // standup. After that, at noon you have lunch. Then at 2 PM you have review."
            let sentences: Vec<String> = self
                .meetings
                .iter()
                .take(4)
                .enumerate()
                .map(|(idx, m)| match idx {
                    0 => format!("{}, first at {} you have {}.", lead, m.time_label, m.title),
                    1 => format!("After that, at {} you have {}.", m.time_label, m.title),
                    _ => format!("Then at {} you have {}.", m.time_label, m.title),
                })
                .collect();
            parts.push(sentences.join(" "));
        }
        parts.push(self.window.signoff().into());
        parts.join(" ")
    }

    /// True when this brief is for the morning window — gates the weather line append.
    pub fn is_morning(&self) -> bool {
        self.window == Window::Morning
    }

    /// A terse spoken brief for non-car ("normal") mode — a headline, not a rundown.
    /// Greeting + unread count, then at most the single most-pressing triage item and
    /// the next meeting. Never enumerates threads or open-question status the way
    /// [`spoken_fallback`] does.
    pub fn spoken_concise(&self) -> String {
        let mut parts: Vec<String> = vec![format!("{}.", self.window.greeting())];
        parts.push(if self.unread_count == 0 {
            "Your inbox is clear.".into()
        } else {
            format!("{} unread message{}.", self.unread_count, plural(self.unread_count))
        });
        // The single most-pressing item: urgent first, else important.
        if let Some(top) = self.urgent.items.first().or_else(|| self.important.items.first()) {
            let label = if self.urgent.items.is_empty() { "important" } else { "urgent" };
            parts.push(format!("Most {}: {} from {}.", label, top.subject, top.sender));
        }
        // The next meeting only.
        if let Some(m) = self.meetings.first() {
            let lead = if self.meetings_are_tomorrow { "Tomorrow" } else { "Next up" };
            parts.push(format!("{} at {}, {}.", lead, m.time_label, m.title));
        }
        parts.join(" ")
    }

    /// Structured facts for an LLM to phrase.
    pub fn facts_prompt(&self) -> String {
        let mut s = format!("Open with: \"{}\".\n", self.window.greeting());
        s.push_str(&format!("Unread messages: {}.\n", self.unread_count));
        if self.unread_new.is_empty() {
            s.push_str("New unread since last time: none.\n");
        } else {
            s.push_str("New unread since last time (give one short clause each — \"mail from X with subject Y, briefly about Z\"):\n");
            for u in &self.unread_new {
                s.push_str(&format!("- from {}, subject \"{}\", about: {}\n", u.sender, u.subject, u.about));
            }
        }
        s.push_str(&self.facts_section(&self.urgent, "URGENT"));
        s.push_str(&self.facts_section(&self.important, "IMPORTANT"));
        s.push_str(&self.facts_followups());
        if self.busy_day {
            s.push_str("Today is busier than usual — open the meetings part by warning them they have a busy day ahead.\n");
        }
        let horizon = if self.meetings_are_tomorrow { "tomorrow" } else { self.window.label() };
        s.push_str(&format!("Meetings to cover ({horizon} horizon):\n"));
        if self.meetings_are_tomorrow {
            s.push_str("(Today is done — these are TOMORROW's meetings. Say \"tomorrow\", not \"today\".)\n");
        }
        if self.meetings.is_empty() {
            s.push_str("- none\n");
        } else {
            for m in self.meetings.iter().take(8) {
                s.push_str(&format!("- {} {}\n", m.time_label, m.title));
            }
        }
        s
    }

    fn spoken_section(&self, sec: &Section, label: &str) -> Option<String> {
        if sec.items.is_empty() {
            return None;
        }
        let names: Vec<String> = sec
            .items
            .iter()
            .take(3)
            .map(|i| format!("{} from {}", i.subject, i.sender))
            .collect();
        let count = sec.items.len();
        if sec.is_repeat {
            if let Some(secs) = sec.since_last_secs {
                return Some(format!(
                    "Still {} {}, unchanged since {}: {}.",
                    count,
                    label,
                    relative(secs),
                    names.join("; ")
                ));
            }
        }
        Some(format!("{} {}: {}.", count, label, names.join("; ")))
    }

    fn facts_section(&self, sec: &Section, label: &str) -> String {
        if sec.items.is_empty() {
            return format!("{label}: nothing new to mention.\n");
        }
        let mut s = format!("{} ({}", label, sec.items.len());
        if sec.is_repeat {
            if let Some(secs) = sec.since_last_secs {
                s.push_str(&format!(", unchanged since {}", relative(secs)));
            }
        }
        s.push_str("):\n");
        for i in sec.items.iter().take(6) {
            let summary = i.summary.as_deref().map(|x| format!(" — {x}")).unwrap_or_default();
            s.push_str(&format!("- \"{}\" from {}{}\n", i.subject, i.sender, summary));
        }
        s
    }

    /// A natural, non-exhaustive spoken line about open questions: just the count on
    /// each side and the single most-important thread named — never the whole list.
    fn spoken_followups(&self) -> Option<String> {
        let you = self.awaiting_you.first().map(|top| {
            let n = self.awaiting_you.len();
            if n == 1 {
                format!("One email is still waiting on your reply — {} from {}.", top.subject, top.sender)
            } else {
                format!(
                    "{} emails are still waiting on your reply, the most pressing being {} from {}.",
                    n, top.subject, top.sender
                )
            }
        });
        let others = self.awaiting_others.first().map(|top| {
            let n = self.awaiting_others.len();
            let lead = if you.is_some() { "And you're " } else { "You're " };
            if n == 1 {
                format!("{lead}still waiting to hear back on one — {} from {}.", top.subject, top.sender)
            } else {
                format!("{lead}also waiting to hear back on {n} threads, like {} from {}.", top.subject, top.sender)
            }
        });
        let parts: Vec<String> = [you, others].into_iter().flatten().collect();
        if parts.is_empty() {
            None
        } else {
            Some(parts.join(" "))
        }
    }

    /// Structured open-question facts: counts on each side plus the single most
    /// important thread, with an explicit instruction not to read every subject.
    fn facts_followups(&self) -> String {
        if self.awaiting_you.is_empty() && self.awaiting_others.is_empty() {
            return format!("Open questions (last {FOLLOWUP_DAYS} days): none — nothing is hanging.\n");
        }
        let mut s = format!(
            "Open questions from the last {FOLLOWUP_DAYS} days. Summarise these naturally as a quick \
             status — give the count on each side and name ONLY the single most important thread \
             (the one listed under each side is the most important); do NOT read out every subject:\n",
        );
        s.push_str(&format!("Waiting on YOU to reply: {}.\n", self.awaiting_you.len()));
        if let Some(top) = self.awaiting_you.first() {
            let summary = top.summary.as_deref().map(|x| format!(" — {x}")).unwrap_or_default();
            s.push_str(&format!("  most important: \"{}\" from {}{}\n", top.subject, top.sender, summary));
        }
        s.push_str(&format!("Waiting on SOMEONE ELSE to reply: {}.\n", self.awaiting_others.len()));
        if let Some(top) = self.awaiting_others.first() {
            let summary = top.summary.as_deref().map(|x| format!(" — {x}")).unwrap_or_default();
            s.push_str(&format!("  most important: \"{}\" from {}{}\n", top.subject, top.sender, summary));
        }
        s
    }
}

/// Assemble the brief from the store at the current local time.
pub fn assemble_now(store: &SyncStore) -> rusqlite::Result<Brief> {
    assemble(store, Local::now())
}

/// Assemble the brief from the store at `now`, committing the announcement gating —
/// i.e. recording what's been said so the next brief's "new since last time" /
/// "unchanged" logic is correct. This is the real "speak the brief" path.
pub fn assemble(store: &SyncStore, now: DateTime<Local>) -> rusqlite::Result<Brief> {
    assemble_impl(store, now, true)
}

/// Assemble the brief WITHOUT committing the gating — identical content, no side
/// effects. Used to pre-warm the spoken brief on a timer so a tap is instant: the
/// preview can run repeatedly without consuming the "new since last time" state, which
/// only the real [`assemble`] (on tap) records.
pub fn assemble_preview(store: &SyncStore, now: DateTime<Local>) -> rusqlite::Result<Brief> {
    assemble_impl(store, now, false)
}

fn assemble_impl(store: &SyncStore, now: DateTime<Local>, commit: bool) -> rusqlite::Result<Brief> {
    let window = Window::from_hour(now.hour());
    let conn = store.connection();
    let conn = conn.lock();

    // Unread: total count + the NEW threads (not announced before).
    let unread_rows = query_unread(&conn)?;
    let unread_count = unread_rows.len() as i64;
    let unread_new = gate_unread(&conn, &unread_rows, now, commit)?;

    let urgent_items = query_triage(&conn, "priority_urgent = 1")?;
    let important_items = query_triage(&conn, "priority_important = 1 AND priority_urgent = 0")?;

    // Meetings: today (morning/afternoon) or today+tomorrow (evening).
    let end_of_today = now
        .date_naive()
        .and_hms_opt(23, 59, 59)
        .and_then(|d| Local.from_local_datetime(&d).single())
        .unwrap_or(now);
    let horizon_end = if window == Window::Evening {
        end_of_today + Duration::days(1)
    } else {
        end_of_today
    };
    // Only meetings that haven't started yet — query_meetings filters start_at >= now,
    // so a meeting already underway/past is never spoken.
    let mut meetings = query_meetings(&conn, &now, &horizon_end)?;
    // Nothing left today (morning/afternoon)? Look ahead to tomorrow so the brief stays
    // useful instead of just saying "nothing today". Evening already spans tomorrow.
    let mut meetings_are_tomorrow = false;
    if meetings.is_empty() && window != Window::Evening {
        let start_of_tomorrow = (now + Duration::days(1))
            .date_naive()
            .and_hms_opt(0, 0, 0)
            .and_then(|d| Local.from_local_datetime(&d).single())
            .unwrap_or(end_of_today);
        let end_of_tomorrow = end_of_today + Duration::days(1);
        meetings = query_meetings(&conn, &start_of_tomorrow, &end_of_tomorrow)?;
        meetings_are_tomorrow = !meetings.is_empty();
    }

    let busy_day = is_busy_day(&conn, &now)?;

    let is_morning = window == Window::Morning;
    let urgent = gate(&conn, "urgent", urgent_items, is_morning, now, commit)?;
    let important = gate(&conn, "important", important_items, is_morning, now, commit)?;

    // Open questions over the trailing week. Unlike urgent/important these aren't
    // gated — every brief is a fresh status check on what's still hanging.
    let since = (now - Duration::days(FOLLOWUP_DAYS)).to_rfc3339();
    let awaiting_you = query_followups(&conn, &[TriageLabel::NeedsAnswer], &since)?;
    let awaiting_others = query_followups(
        &conn,
        &[TriageLabel::WaitingReply, TriageLabel::NeedsAnswerOther],
        &since,
    )?;

    Ok(Brief {
        window,
        unread_count,
        unread_new,
        urgent,
        important,
        awaiting_you,
        awaiting_others,
        meetings,
        meetings_are_tomorrow,
        busy_day,
    })
}

/// Conversations triaged into one of `labels` whose latest activity is on or after
/// `since` (an RFC3339 instant), most-important first (urgent, then important, then
/// most recent). The label set is single-sourced from [`TriageLabel`] so the SQL
/// `IN (…)` list can never drift from the taxonomy.
fn query_followups(
    conn: &rusqlite::Connection,
    labels: &[TriageLabel],
    since: &str,
) -> rusqlite::Result<Vec<TriageItem>> {
    let in_list = labels
        .iter()
        .map(|l| format!("'{}'", l.as_str()))
        .collect::<Vec<_>>()
        .join(",");
    let status_filter = status_filter();
    let sql = format!(
        "SELECT key, COALESCE(subject,'(no subject)'), COALESCE(from_address,''), \
                COALESCE(ai_summary_short, ai_summary)
         FROM conversations
         WHERE triage_label IN ({in_list}) AND updated_at >= ?1 AND {status_filter} AND {CONTENT_FILTER}
         ORDER BY priority_urgent DESC, priority_important DESC, updated_at DESC
         LIMIT 50"
    );
    let mut stmt = conn.prepare(&sql)?;
    let rows = stmt.query_map(params![since], |r| {
        Ok(TriageItem {
            key: r.get(0)?,
            subject: normalize_subject(&r.get::<_, String>(1)?),
            sender: sender_name(&r.get::<_, String>(2)?),
            summary: r.get(3)?,
        })
    })?;
    rows.collect()
}

// ── Tomorrow's agenda ──────────────────────────────────────────────────────

/// A spoken preview of tomorrow's calendar (timed meetings + all-day events).
pub struct TomorrowAgenda {
    weekday: String,
    meetings: Vec<Meeting>,
    all_day: Vec<String>,
    /// Tomorrow has more timed events than the trailing 61-day daily average.
    busy: bool,
}

impl TomorrowAgenda {
    /// Deterministic spoken preview — used when no LLM is available.
    pub fn spoken_fallback(&self) -> String {
        let mut parts = vec![format!("Here's tomorrow, {}.", self.weekday)];
        if self.meetings.is_empty() && self.all_day.is_empty() {
            parts.push("Your calendar is completely clear — nothing scheduled.".into());
            parts.push("Enjoy the open day.".into());
            return parts.join(" ");
        }
        if self.busy {
            parts.push("It's looking like a full day.".into());
        }
        if !self.meetings.is_empty() {
            let last = self.meetings.len().min(5) - 1;
            let sentences: Vec<String> = self
                .meetings
                .iter()
                .take(5)
                .enumerate()
                .map(|(i, m)| match i {
                    0 => format!("You start at {} with {}.", m.time_label, m.title),
                    i if i == last => format!("And finally at {} you have {}.", m.time_label, m.title),
                    1 => format!("Then at {} you have {}.", m.time_label, m.title),
                    _ => format!("After that, at {} you have {}.", m.time_label, m.title),
                })
                .collect();
            parts.push(sentences.join(" "));
        }
        if !self.all_day.is_empty() {
            parts.push(format!("All day, you've got {}.", join_and(&self.all_day)));
        }
        parts.push("That's tomorrow at a glance.".into());
        parts.join(" ")
    }

    /// Structured facts for an LLM to phrase.
    pub fn facts_prompt(&self) -> String {
        let mut s = format!("This is a warm spoken preview of TOMORROW ({}).\n", self.weekday);
        if self.busy {
            s.push_str("Tomorrow is busier than usual — open by mentioning it's a full day.\n");
        }
        if self.meetings.is_empty() && self.all_day.is_empty() {
            s.push_str("Calendar: completely clear, nothing scheduled.\n");
            return s;
        }
        if self.meetings.is_empty() {
            s.push_str("Timed meetings: none.\n");
        } else {
            s.push_str("Timed meetings (walk through them in order):\n");
            for m in self.meetings.iter().take(8) {
                s.push_str(&format!("- {} {}\n", m.time_label, m.title));
            }
        }
        if !self.all_day.is_empty() {
            s.push_str(&format!("All-day events: {}.\n", self.all_day.join(", ")));
        }
        s
    }
}

/// Assemble tomorrow's agenda from the store at `now` (local time).
pub fn tomorrow_agenda(store: &SyncStore, now: DateTime<Local>) -> rusqlite::Result<TomorrowAgenda> {
    let conn = store.connection();
    let conn = conn.lock();
    let day = now.date_naive() + Duration::days(1);
    let (start, end) = day_bounds(day, &now);
    let events = query_events_between(&conn, &start, &end)?;
    let recurring = recurring_all_day_keys(&conn, &now)?;
    let mut meetings = Vec::new();
    let mut all_day = Vec::new();
    for ev in &events {
        if ev.all_day {
            // Recurring all-day events (standing blocks, birthdays, holidays) are noise
            // in a one-day preview — only announce one-off ones.
            if !is_recurring_all_day(ev, &recurring) {
                all_day.push(ev.title.clone());
            }
        } else {
            meetings.push(Meeting { time_label: natural_time(&ev.start), title: ev.title.clone() });
        }
    }
    let busy = day_is_busy(&conn, day, &now)?;
    Ok(TomorrowAgenda { weekday: day.format("%A").to_string(), meetings, all_day, busy })
}

// ── Highlights of the week ─────────────────────────────────────────────────

/// One day's load in the coming-week rundown.
struct DayLoad {
    /// "tomorrow" for the first day, else the weekday name ("Wednesday").
    label: String,
    count: usize,
    total_minutes: i64,
    /// The single longest meeting, only if it clears the "long meeting" bar.
    longest: Option<(String, i64)>,
    /// Busier than the trailing two-week daily average (an anomaly worth a mention).
    busy: bool,
}

/// A one-off all-day event worth calling out (recurring ones are filtered away).
struct NotableAllDay {
    label: String,
    title: String,
}

/// A spoken rundown of the coming 7 days, framed against the prior two weeks.
pub struct WeekHighlights {
    days: Vec<DayLoad>,
    coming_total: usize,
    /// Mean timed meetings per day across the previous 14 days (0 = no history).
    baseline_avg: f64,
    /// One-off all-day events in the coming week (recurring ones excluded).
    all_day_notable: Vec<NotableAllDay>,
}

/// Meetings at or above this many minutes are flagged as "long".
const LONG_MEETING_MIN: i64 = 90;

impl WeekHighlights {
    /// Deterministic spoken rundown — used when no LLM is available.
    pub fn spoken_fallback(&self) -> String {
        let mut parts = vec!["Here's how your week is shaping up.".to_string()];
        if self.coming_total == 0 {
            if let Some(s) = self.notable_all_day_sentence() {
                parts.push("No meetings on the books for the next seven days.".into());
                parts.push(s);
            } else {
                parts.push("The next seven days are wide open — nothing on the calendar yet.".into());
                parts.push("A clean slate.".into());
            }
            return parts.join(" ");
        }
        let coming_avg = self.coming_total as f64 / 7.0;
        if self.baseline_avg > 0.0 {
            if coming_avg > self.baseline_avg * 1.25 {
                parts.push("It's shaping up busier than your last couple of weeks.".into());
            } else if coming_avg < self.baseline_avg * 0.75 {
                parts.push("It's lighter than usual — a bit more breathing room than the last fortnight.".into());
            } else {
                parts.push("Overall it's a pretty typical week.".into());
            }
        }
        if let Some(busiest) = self.days.iter().filter(|d| d.count > 0).max_by_key(|d| d.count) {
            let hours = busiest.total_minutes / 60;
            let hrs = if hours >= 2 { format!(", around {hours} hours booked") } else { String::new() };
            parts.push(format!(
                "{} looks like your heaviest day with {} meeting{}{}.",
                cap(&busiest.label),
                busiest.count,
                plural(busiest.count as i64),
                hrs
            ));
        }
        let longs: Vec<String> = self
            .days
            .iter()
            .filter_map(|d| d.longest.as_ref().map(|(t, m)| format!("{} on {}, which runs {}", t, d.label, duration_words(*m))))
            .take(2)
            .collect();
        if !longs.is_empty() {
            parts.push(format!("Keep an eye out for {}.", join_and(&longs)));
        }
        let clear: Vec<String> = self.days.iter().filter(|d| d.count == 0).map(|d| cap(&d.label)).take(3).collect();
        if !clear.is_empty() {
            let verb = if clear.len() == 1 { "is" } else { "are" };
            parts.push(format!("{} {} clear, so you'll get some breathing room.", join_and(&clear), verb));
        }
        if let Some(s) = self.notable_all_day_sentence() {
            parts.push(s);
        }
        parts.push("That's your week ahead.".into());
        parts.join(" ")
    }

    /// "Also worth noting: a conference on Wednesday and a holiday on Friday." — the
    /// one-off all-day events, or None when there are none.
    fn notable_all_day_sentence(&self) -> Option<String> {
        if self.all_day_notable.is_empty() {
            return None;
        }
        let items: Vec<String> = self
            .all_day_notable
            .iter()
            .take(3)
            .map(|n| format!("{} on {}", n.title, n.label))
            .collect();
        Some(format!("Also worth noting: {}.", join_and(&items)))
    }

    /// Structured facts for an LLM to phrase.
    pub fn facts_prompt(&self) -> String {
        let mut s = String::from(
            "This is a warm, conversational \"highlights of the week\" rundown comparing the COMING 7 days to the previous two weeks. \
             Be brief and friendly. Call out anomalies (busier or quieter than usual), the busiest days, any unusually long meetings, and the clear days.\n",
        );
        if self.baseline_avg > 0.0 {
            s.push_str(&format!("Over the last two weeks you averaged {:.1} timed meetings a day.\n", self.baseline_avg));
        } else {
            s.push_str("No meeting history for the last two weeks to compare against.\n");
        }
        s.push_str(&format!("The coming 7 days have {} timed meetings in total.\n", self.coming_total));
        s.push_str("Day by day:\n");
        for d in &self.days {
            if d.count == 0 {
                s.push_str(&format!("- {}: clear, nothing scheduled.\n", d.label));
                continue;
            }
            let mut line = format!("- {}: {} meeting{}", d.label, d.count, plural(d.count as i64));
            if d.total_minutes >= 60 {
                line.push_str(&format!(", about {} booked", duration_words(d.total_minutes)));
            }
            if d.busy {
                line.push_str(", busier than usual");
            }
            if let Some((t, m)) = &d.longest {
                line.push_str(&format!(", longest is \"{}\" at {}", t, duration_words(*m)));
            }
            line.push('\n');
            s.push_str(&line);
        }
        if self.all_day_notable.is_empty() {
            s.push_str("Notable all-day events (one-off, recurring ones already filtered out): none.\n");
        } else {
            s.push_str("Notable all-day events (one-off; recurring ones already filtered out — mention these as highlights):\n");
            for n in self.all_day_notable.iter().take(4) {
                s.push_str(&format!("- {} on {}\n", n.title, n.label));
            }
        }
        s
    }
}

/// Assemble the coming-week highlights from the store at `now` (local time).
pub fn week_highlights(store: &SyncStore, now: DateTime<Local>) -> rusqlite::Result<WeekHighlights> {
    let conn = store.connection();
    let conn = conn.lock();

    let recurring = recurring_all_day_keys(&conn, &now)?;
    let mut days = Vec::new();
    let mut coming_total = 0;
    let mut all_day_notable = Vec::new();
    for offset in 1..=7 {
        let day = now.date_naive() + Duration::days(offset);
        let (start, end) = day_bounds(day, &now);
        let events = query_events_between(&conn, &start, &end)?;
        let label = if offset == 1 { "tomorrow".to_string() } else { day.format("%A").to_string() };
        let timed: Vec<&RawEvent> = events.iter().filter(|e| !e.all_day).collect();
        let count = timed.len();
        coming_total += count;
        let mut total_minutes = 0i64;
        let mut longest: Option<(String, i64)> = None;
        for e in &timed {
            let mins = e.end.map(|end| (end - e.start).num_minutes().max(0)).unwrap_or(0);
            total_minutes += mins;
            if mins >= LONG_MEETING_MIN && longest.as_ref().map(|l| mins > l.1).unwrap_or(true) {
                longest = Some((e.title.clone(), mins));
            }
        }
        // One-off all-day events are genuine highlights; recurring ones are noise.
        for e in events.iter().filter(|e| e.all_day && !is_recurring_all_day(e, &recurring)) {
            all_day_notable.push(NotableAllDay { label: label.clone(), title: e.title.clone() });
        }
        days.push(DayLoad { label, count, total_minutes, longest, busy: false });
    }

    // Baseline: mean timed meetings per day over the previous 14 days.
    let past_start = day_bounds(now.date_naive() - Duration::days(14), &now).0;
    let past_end = day_bounds(now.date_naive() - Duration::days(1), &now).1;
    let past = query_events_between(&conn, &past_start, &past_end)?;
    let past_timed = past.iter().filter(|e| !e.all_day).count();
    let baseline_avg = past_timed as f64 / 14.0;

    for d in &mut days {
        d.busy = baseline_avg > 0.0 && d.count as f64 > baseline_avg && d.count >= 2;
    }

    Ok(WeekHighlights { days, coming_total, baseline_avg, all_day_notable })
}

// ── Spoken answers for the voice intent layer ───────────────────────────────
// Deterministic (no LLM) so they're instant and predictable for a hands-free
// assistant; they reuse the same private query helpers as the daily brief.

/// "What's on my agenda today" — today's remaining timed meetings, spoken.
pub fn agenda_today_spoken(store: &SyncStore, now: DateTime<Local>) -> rusqlite::Result<String> {
    let conn = store.connection();
    let conn = conn.lock();
    let (_, end_of_today) = day_bounds(now.date_naive(), &now);
    let meetings = query_meetings(&conn, &now, &end_of_today)?;
    if meetings.is_empty() {
        return Ok("You've nothing left on your calendar today.".into());
    }
    let sentences: Vec<String> = meetings
        .iter()
        .take(6)
        .enumerate()
        .map(|(i, m)| {
            if i == 0 {
                format!("First, at {} you have {}.", m.time_label, m.title)
            } else {
                format!("Then at {} you have {}.", m.time_label, m.title)
            }
        })
        .collect();
    let n = meetings.len();
    Ok(format!(
        "You have {} thing{} left on your agenda today. {}",
        n,
        plural(n as i64),
        sentences.join(" ")
    ))
}

/// "Anything I need to respond to?" — open threads awaiting the owner's reply.
pub fn needs_response_spoken(store: &SyncStore, now: DateTime<Local>) -> rusqlite::Result<String> {
    let conn = store.connection();
    let conn = conn.lock();
    let since = (now - Duration::days(FOLLOWUP_DAYS)).to_rfc3339();
    let items = query_followups(&conn, &[TriageLabel::NeedsAnswer], &since)?;
    let Some(top) = items.first() else {
        return Ok("Nothing's waiting on your reply right now.".into());
    };
    if items.len() == 1 {
        Ok(format!("One email is waiting on your reply — {} from {}.", top.subject, top.sender))
    } else {
        Ok(format!(
            "{} emails are waiting on your reply. The most pressing is {} from {}.",
            items.len(),
            top.subject,
            top.sender
        ))
    }
}

/// "Anything from last week I missed?" — unread + things needing a response in 7d.
pub fn missed_last_week_spoken(store: &SyncStore, now: DateTime<Local>) -> rusqlite::Result<String> {
    let conn = store.connection();
    let conn = conn.lock();
    let since = (now - Duration::days(7)).to_rfc3339();
    let unread: i64 = conn
        .query_row(
            &format!("SELECT COUNT(*) FROM conversations WHERE read = 0 AND {} AND {CONTENT_FILTER} AND updated_at >= ?1", status_filter()),
            params![since],
            |r| r.get(0),
        )
        .unwrap_or(0);
    let need = query_followups(&conn, &[TriageLabel::NeedsAnswer, TriageLabel::NeedsAnswerOther], &since)?;
    if unread == 0 && need.is_empty() {
        return Ok("You're all caught up from the past week — nothing unread and nothing waiting.".into());
    }
    let mut parts = Vec::new();
    if unread > 0 {
        parts.push(format!("{} unread message{} from the past week", unread, plural(unread)));
    }
    if !need.is_empty() {
        parts.push(format!("{} still needing a response", need.len()));
    }
    let lead = format!("From the last week, you have {}.", join_and(&parts));
    match need.first() {
        Some(top) => Ok(format!("{lead} The one to look at first is {} from {}.", top.subject, top.sender)),
        None => Ok(lead),
    }
}

/// "What's the meeting at <time> about?" — the event nearest the requested time on
/// `date`, described (title, time, organiser, location, a snippet of the notes).
pub fn meeting_detail_spoken(
    store: &SyncStore,
    now: DateTime<Local>,
    date: chrono::NaiveDate,
    hour: Option<u32>,
    minute: Option<u32>,
) -> rusqlite::Result<String> {
    let conn = store.connection();
    let conn = conn.lock();
    let (start, end) = day_bounds(date, &now);
    let mut stmt = conn.prepare(
        "SELECT title, start_at, COALESCE(location,''), COALESCE(description,''), COALESCE(organizer_name, organizer_email, '')
         FROM calendar_events
         WHERE all_day = 0 AND status != 'cancelled' AND start_at >= ?1 AND start_at <= ?2
         ORDER BY start_at",
    )?;
    let rows = stmt.query_map(params![start.to_rfc3339(), end.to_rfc3339()], |r| {
        Ok((
            r.get::<_, String>(0)?,
            r.get::<_, String>(1)?,
            r.get::<_, String>(2)?,
            r.get::<_, String>(3)?,
            r.get::<_, String>(4)?,
        ))
    })?;
    let mut events: Vec<(DateTime<Local>, String, String, String, String)> = Vec::new();
    for row in rows {
        let (title, start_at, loc, desc, who) = row?;
        if let Ok(parsed) = DateTime::parse_from_rfc3339(&start_at) {
            events.push((parsed.with_timezone(&Local), title, loc, desc, who));
        }
    }
    if events.is_empty() {
        return Ok(format!("I don't see any meetings on {}.", date.format("%A")));
    }
    // Closest event to the requested time, else the first of the day.
    let chosen = match hour.map(|h| (h * 60 + minute.unwrap_or(0)) as i64) {
        Some(t) => events
            .iter()
            .min_by_key(|(s, ..)| ((s.hour() * 60 + s.minute()) as i64 - t).abs())
            .unwrap(),
        None => &events[0],
    };
    let (s, title, loc, desc, who) = chosen;
    let mut out = format!("At {}, you have {}.", natural_time(s), title);
    if !who.is_empty() {
        out.push_str(&format!(" Organised by {who}."));
    }
    if !loc.is_empty() {
        out.push_str(&format!(" Location: {loc}."));
    }
    if !desc.is_empty() {
        let clean = desc.split_whitespace().collect::<Vec<_>>().join(" ");
        let snippet: String = clean.chars().take(220).collect();
        out.push_str(&format!(" It's about: {snippet}"));
    }
    Ok(out)
}

/// True when today has more timed events than the trailing 61-day daily average.
/// Counts the whole of today (incl. earlier events) so the "busy day" cue reflects
/// the day overall, not just what's left. Cold start (no history) is never "busy".
fn is_busy_day(conn: &rusqlite::Connection, now: &DateTime<Local>) -> rusqlite::Result<bool> {
    day_is_busy(conn, now.date_naive(), now)
}

/// True when `day` has more timed events than the trailing 61-day daily average.
/// `fallback` only supplies a sane instant if the date arithmetic ever fails.
fn day_is_busy(
    conn: &rusqlite::Connection,
    day: chrono::NaiveDate,
    fallback: &DateTime<Local>,
) -> rusqlite::Result<bool> {
    let (start_of_today, end_of_today) = day_bounds(day, fallback);
    let window_start = start_of_today - Duration::days(61);

    let count = |from: &DateTime<Local>, to_excl: bool, to: &DateTime<Local>| -> rusqlite::Result<i64> {
        let op = if to_excl { "<" } else { "<=" };
        conn.query_row(
            &format!(
                "SELECT COUNT(*) FROM calendar_events
                 WHERE all_day = 0 AND status != 'cancelled' AND start_at >= ?1 AND start_at {op} ?2"
            ),
            params![from.to_rfc3339(), to.to_rfc3339()],
            |r| r.get(0),
        )
    };

    let today_count = count(&start_of_today, false, &end_of_today)?;
    let prior_count = count(&window_start, true, &start_of_today)?;
    let avg = prior_count as f64 / 61.0;
    Ok(avg > 0.0 && today_count as f64 > avg)
}

/// Speakable clock time: "11 AM", "noon", "2:30 PM". The old 24-hour "%-H:%M" form
/// ("11:00") gets read aloud as "eleven zero zero", which is what this avoids.
fn natural_time(dt: &DateTime<Local>) -> String {
    let (h24, m) = (dt.hour(), dt.minute());
    if m == 0 && h24 == 12 {
        return "noon".into();
    }
    if m == 0 && h24 == 0 {
        return "midnight".into();
    }
    let (h12, ampm) = match h24 {
        0 => (12, "AM"),
        12 => (12, "PM"),
        1..=11 => (h24, "AM"),
        _ => (h24 - 12, "PM"),
    };
    if m == 0 {
        format!("{h12} {ampm}")
    } else {
        format!("{h12}:{m:02} {ampm}")
    }
}

struct UnreadRow {
    key: String,
    subject: String,
    sender: String,
    about: String,
}

fn query_unread(conn: &rusqlite::Connection) -> rusqlite::Result<Vec<UnreadRow>> {
    let status_filter = status_filter();
    let sql = format!(
        "SELECT key, COALESCE(subject,'(no subject)'), COALESCE(from_address,''), COALESCE(ai_summary, snippet, '')
         FROM conversations
         WHERE read = 0 AND {status_filter} AND {CONTENT_FILTER}
         ORDER BY updated_at DESC LIMIT 100"
    );
    let mut stmt = conn.prepare(&sql)?;
    let rows = stmt.query_map([], |r| {
        Ok(UnreadRow {
            key: r.get(0)?,
            subject: normalize_subject(&r.get::<_, String>(1)?),
            sender: sender_name(&r.get::<_, String>(2)?),
            about: about_phrase(&r.get::<_, String>(3)?),
        })
    })?;
    rows.collect()
}

/// New unread = threads not in the previously-announced set. Records the current
/// unread key set so the same thread is never summarised twice.
fn gate_unread(
    conn: &rusqlite::Connection,
    rows: &[UnreadRow],
    now: DateTime<Local>,
    commit: bool,
) -> rusqlite::Result<Vec<UnreadItem>> {
    let prev_sig: String = conn
        .query_row(
            "SELECT signature FROM bridge_announce WHERE category = 'unread'",
            [],
            |r| r.get(0),
        )
        .unwrap_or_default();
    let prev: HashSet<&str> = prev_sig.split('|').filter(|s| !s.is_empty()).collect();

    let new_items: Vec<UnreadItem> = rows
        .iter()
        .filter(|r| !prev.contains(r.key.as_str()))
        .take(5)
        .map(|r| UnreadItem {
            sender: r.sender.clone(),
            subject: r.subject.clone(),
            about: r.about.clone(),
        })
        .collect();

    // Persist the current unread set as the new "announced" baseline — only when
    // committing (a real brief). A preview leaves the baseline untouched so the next
    // real brief still sees these as new.
    if commit {
        let mut keys: Vec<&str> = rows.iter().map(|r| r.key.as_str()).collect();
        keys.sort_unstable();
        let sig = keys.join("|");
        conn.execute(
            "INSERT INTO bridge_announce (category, signature, announced_at) VALUES ('unread', ?1, ?2)
             ON CONFLICT(category) DO UPDATE SET signature = ?1, announced_at = ?2",
            params![sig, now.to_rfc3339()],
        )?;
    }

    Ok(new_items)
}

fn query_triage(conn: &rusqlite::Connection, where_clause: &str) -> rusqlite::Result<Vec<TriageItem>> {
    let status_filter = status_filter();
    let sql = format!(
        "SELECT key, COALESCE(subject,'(no subject)'), COALESCE(from_address,''), ai_summary
         FROM conversations
         WHERE {where_clause} AND {status_filter} AND {CONTENT_FILTER}
         ORDER BY updated_at DESC LIMIT 10"
    );
    let mut stmt = conn.prepare(&sql)?;
    let rows = stmt.query_map([], |r| {
        Ok(TriageItem {
            key: r.get(0)?,
            subject: normalize_subject(&r.get::<_, String>(1)?),
            sender: sender_name(&r.get::<_, String>(2)?),
            summary: r.get(3)?,
        })
    })?;
    rows.collect()
}

fn query_meetings(
    conn: &rusqlite::Connection,
    now: &DateTime<Local>,
    horizon_end: &DateTime<Local>,
) -> rusqlite::Result<Vec<Meeting>> {
    let now_iso = now.to_rfc3339();
    let mut stmt = conn.prepare(
        "SELECT title, start_at FROM calendar_events
         WHERE all_day = 0 AND status != 'cancelled' AND start_at >= ?1
         ORDER BY start_at LIMIT 50",
    )?;
    let rows = stmt.query_map(params![now_iso], |r| {
        Ok((r.get::<_, String>(0)?, r.get::<_, String>(1)?))
    })?;
    let mut out = Vec::new();
    for row in rows {
        let (title, start_at) = row?;
        if let Ok(parsed) = DateTime::parse_from_rfc3339(&start_at) {
            let local = parsed.with_timezone(&Local);
            if local <= *horizon_end {
                out.push(Meeting { time_label: natural_time(&local), title });
            }
        }
    }
    Ok(out)
}

/// Announce a triage category only if its set changed or it's morning; track the
/// signature + last-announced time in `bridge_announce`.
fn gate(
    conn: &rusqlite::Connection,
    category: &str,
    items: Vec<TriageItem>,
    is_morning: bool,
    now: DateTime<Local>,
    commit: bool,
) -> rusqlite::Result<Section> {
    let mut keys: Vec<&str> = items.iter().map(|i| i.key.as_str()).collect();
    keys.sort_unstable();
    let sig = keys.join("|");

    let prev: Option<(String, Option<String>)> = conn
        .query_row(
            "SELECT signature, announced_at FROM bridge_announce WHERE category = ?1",
            params![category],
            |r| Ok((r.get(0)?, r.get(1)?)),
        )
        .ok();
    let prev_sig = prev.as_ref().map(|p| p.0.clone()).unwrap_or_default();
    let prev_at = prev
        .as_ref()
        .and_then(|p| p.1.as_ref())
        .and_then(|s| DateTime::parse_from_rfc3339(s).ok())
        .map(|d| d.with_timezone(&Local));

    let changed = sig != prev_sig;
    let announce = (changed || is_morning) && !items.is_empty();
    let announced_at = if announce { Some(now) } else { prev_at };

    // Only a real brief records the announcement; a preview must not, or it would mark
    // the category "seen" and suppress it on the next real brief.
    if commit {
        conn.execute(
            "INSERT INTO bridge_announce (category, signature, announced_at) VALUES (?1, ?2, ?3)
             ON CONFLICT(category) DO UPDATE SET signature = ?2, announced_at = ?3",
            params![category, sig, announced_at.map(|d| d.to_rfc3339())],
        )?;
    }

    let since_last_secs = prev_at.map(|p| (now - p).num_seconds());
    Ok(Section {
        items: if announce { items } else { Vec::new() },
        since_last_secs,
        is_repeat: announce && !changed && is_morning,
    })
}

/// Display name from a raw "Name <email>" address.
pub(crate) fn sender_name(raw: &str) -> String {
    let raw = raw.trim();
    if let Some(idx) = raw.find('<') {
        let name = raw[..idx].trim().trim_matches('"').trim();
        if !name.is_empty() {
            return name.to_string();
        }
        return raw[idx + 1..].trim_end_matches('>').trim().to_string();
    }
    raw.to_string()
}

/// A few words capturing the core of a message, from its summary or snippet.
fn about_phrase(text: &str) -> String {
    let clean = text.split_whitespace().collect::<Vec<_>>().join(" ");
    if clean.is_empty() {
        return "no preview".into();
    }
    let words: Vec<&str> = clean.split(' ').take(10).collect();
    let phrase = words.join(" ");
    if phrase.len() < clean.len() {
        format!("{phrase}…")
    } else {
        phrase
    }
}

fn relative(secs: i64) -> String {
    let hours = secs / 3600;
    if hours < 1 {
        "a little earlier".into()
    } else if hours < 24 {
        format!("{} hour{} ago", hours, if hours == 1 { "" } else { "s" })
    } else {
        let days = hours / 24;
        if days == 1 {
            "yesterday".into()
        } else {
            format!("{days} days ago")
        }
    }
}

fn plural(n: i64) -> &'static str {
    if n == 1 {
        ""
    } else {
        "s"
    }
}

/// A calendar event with resolved local times, used by the tomorrow / week views.
struct RawEvent {
    title: String,
    start: DateTime<Local>,
    end: Option<DateTime<Local>>,
    all_day: bool,
    ical_uid: Option<String>,
    recurrence_rule: Option<String>,
}

/// All non-cancelled events whose start falls within `[from, to]`, ordered by start.
fn query_events_between(
    conn: &rusqlite::Connection,
    from: &DateTime<Local>,
    to: &DateTime<Local>,
) -> rusqlite::Result<Vec<RawEvent>> {
    let mut stmt = conn.prepare(
        "SELECT title, start_at, end_at, all_day, ical_uid, recurrence_rule FROM calendar_events
         WHERE status != 'cancelled' AND start_at >= ?1 AND start_at <= ?2
         ORDER BY start_at",
    )?;
    let rows = stmt.query_map(params![from.to_rfc3339(), to.to_rfc3339()], |r| {
        Ok((
            r.get::<_, String>(0)?,
            r.get::<_, String>(1)?,
            r.get::<_, Option<String>>(2)?,
            r.get::<_, i64>(3)?,
            r.get::<_, Option<String>>(4)?,
            r.get::<_, Option<String>>(5)?,
        ))
    })?;
    let mut out = Vec::new();
    for row in rows {
        let (title, start_at, end_at, all_day, ical_uid, recurrence_rule) = row?;
        if let Ok(start) = DateTime::parse_from_rfc3339(&start_at) {
            let end = end_at
                .as_deref()
                .and_then(|s| DateTime::parse_from_rfc3339(s).ok())
                .map(|d| d.with_timezone(&Local));
            out.push(RawEvent {
                title,
                start: start.with_timezone(&Local),
                end,
                all_day: all_day != 0,
                ical_uid,
                recurrence_rule,
            });
        }
    }
    Ok(out)
}

/// Stable key for grouping instances of one all-day event: its iCal UID if present,
/// else a normalised title. Lets us spot a series that a provider expanded into one
/// row per day (which is when the recurrence rule itself goes missing).
fn all_day_key(ev: &RawEvent) -> String {
    match ev.ical_uid.as_deref().map(str::trim).filter(|s| !s.is_empty()) {
        Some(uid) => format!("uid:{}", uid.to_lowercase()),
        None => format!("title:{}", ev.title.trim().to_lowercase()),
    }
}

/// Keys of all-day events that recur — the same event (by UID, else title) landing on
/// two or more distinct days across a wide window (≈1 year back, 2 months ahead). An
/// explicit recurrence rule is also honoured per-event. Recurring all-day events
/// (standing blocks, focus time, birthdays, holidays) add little to a brief, so
/// callers drop them.
fn recurring_all_day_keys(
    conn: &rusqlite::Connection,
    now: &DateTime<Local>,
) -> rusqlite::Result<HashSet<String>> {
    let from = day_bounds(now.date_naive() - Duration::days(370), now).0;
    let to = day_bounds(now.date_naive() + Duration::days(60), now).1;
    let events = query_events_between(conn, &from, &to)?;
    let mut days_per_key: std::collections::HashMap<String, HashSet<chrono::NaiveDate>> =
        std::collections::HashMap::new();
    for ev in &events {
        if !ev.all_day {
            continue;
        }
        days_per_key.entry(all_day_key(ev)).or_default().insert(ev.start.date_naive());
    }
    Ok(days_per_key
        .into_iter()
        .filter(|(_, days)| days.len() >= 2)
        .map(|(k, _)| k)
        .collect())
}

/// Whether an all-day event recurs — by an explicit rule, or by repeating across the
/// detection window (`recurring` from [`recurring_all_day_keys`]).
fn is_recurring_all_day(ev: &RawEvent, recurring: &HashSet<String>) -> bool {
    let has_rule = ev.recurrence_rule.as_deref().map(|s| !s.trim().is_empty()).unwrap_or(false);
    has_rule || recurring.contains(&all_day_key(ev))
}

/// Local midnight → 23:59:59 for `day`; `fallback` covers the (practically
/// impossible) case where the local datetime can't be resolved.
fn day_bounds(day: chrono::NaiveDate, fallback: &DateTime<Local>) -> (DateTime<Local>, DateTime<Local>) {
    let start = day
        .and_hms_opt(0, 0, 0)
        .and_then(|d| Local.from_local_datetime(&d).single())
        .unwrap_or(*fallback);
    let end = day
        .and_hms_opt(23, 59, 59)
        .and_then(|d| Local.from_local_datetime(&d).single())
        .unwrap_or(*fallback);
    (start, end)
}

/// Spoken duration: "2 hours", "1 hour 30 minutes", "45 minutes".
fn duration_words(mins: i64) -> String {
    if mins >= 60 {
        let (h, m) = (mins / 60, mins % 60);
        let hours = format!("{} hour{}", h, if h == 1 { "" } else { "s" });
        if m == 0 {
            hours
        } else {
            format!("{hours} {m} minutes")
        }
    } else {
        format!("{mins} minutes")
    }
}

/// Join into a spoken list: "A", "A and B", "A, B, and C".
fn join_and(items: &[String]) -> String {
    match items {
        [] => String::new(),
        [a] => a.clone(),
        [a, b] => format!("{a} and {b}"),
        _ => {
            let (last, rest) = items.split_last().unwrap();
            format!("{}, and {}", rest.join(", "), last)
        }
    }
}

/// Capitalise the first character (so "tomorrow" reads as "Tomorrow").
fn cap(s: &str) -> String {
    let mut c = s.chars();
    match c.next() {
        Some(f) => f.to_uppercase().collect::<String>() + c.as_str(),
        None => String::new(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::sync::store::SyncStore;

    /// Insert a conversation with an explicit triage label, priority, and age.
    fn seed(
        conn: &rusqlite::Connection,
        key: &str,
        subject: &str,
        from: &str,
        label: TriageLabel,
        urgent: bool,
        now: DateTime<Local>,
        days_ago: i64,
    ) {
        let updated = (now - Duration::days(days_ago)).to_rfc3339();
        // read = 1: a follow-up is "awaiting a reply" regardless of read state, and it
        // keeps these seeds out of the unread section so the test isolates follow-ups.
        conn.execute(
            "INSERT INTO conversations
               (key, organization_id, subject, from_address, triage_label, priority_urgent, read, updated_at)
             VALUES (?1, 'org', ?2, ?3, ?4, ?5, 1, ?6)",
            params![key, subject, from, label.as_str(), urgent as i64, updated],
        )
        .unwrap();
    }

    #[test]
    fn followups_count_per_side_and_name_only_the_top_thread() {
        let store = SyncStore::new_in_memory().unwrap();
        let now = Local.with_ymd_and_hms(2024, 6, 10, 9, 0, 0).unwrap();
        {
            let conn = store.connection();
            let conn = conn.lock();
            // Waiting on YOU (needs_answer): two in-window, the urgent one must lead.
            seed(&conn, "you_urgent", "Budget question", "Alice <a@x.com>", TriageLabel::NeedsAnswer, true, now, 1);
            seed(&conn, "you_plain", "Lunch?", "Carol <c@x.com>", TriageLabel::NeedsAnswer, false, now, 2);
            // Outside the 7-day window — must be excluded from the count.
            seed(&conn, "you_old", "Ancient ask", "Old <o@x.com>", TriageLabel::NeedsAnswer, false, now, 30);
            // Waiting on OTHERS: one waiting_reply + one needs_answer_other.
            seed(&conn, "other_a", "Contract", "Bob <b@x.com>", TriageLabel::WaitingReply, false, now, 1);
            seed(&conn, "other_b", "Vendor quote", "Dan <d@x.com>", TriageLabel::NeedsAnswerOther, false, now, 3);
            // Noise: fyi is never a follow-up.
            seed(&conn, "noise", "Newsletter", "News <n@x.com>", TriageLabel::Fyi, false, now, 1);
        }

        let brief = assemble(&store, now).unwrap();

        // Counts respect the 7-day window (you_old excluded) and label sets.
        assert_eq!(brief.awaiting_you.len(), 2);
        assert_eq!(brief.awaiting_others.len(), 2);
        // Most-important-first: the urgent thread leads its side.
        assert_eq!(brief.awaiting_you[0].subject, "Budget question");

        let facts = brief.facts_prompt();
        assert!(facts.contains("Waiting on YOU to reply: 2."), "{facts}");
        assert!(facts.contains("Waiting on SOMEONE ELSE to reply: 2."), "{facts}");
        assert!(facts.contains("Budget question"), "{facts}");
        // Don't enumerate every subject — the non-top "Lunch?" stays out of the facts.
        assert!(!facts.contains("Lunch?"), "{facts}");

        let spoken = brief.spoken_fallback();
        assert!(spoken.contains("2 emails are still waiting on your reply"), "{spoken}");
        assert!(spoken.contains("Budget question from Alice"), "{spoken}");
        assert!(spoken.contains("waiting to hear back on 2 threads"), "{spoken}");
    }

    #[test]
    fn phantom_shells_never_reach_the_brief() {
        // A provider sync ghost: no subject, no sender — but unread, urgent, AND
        // triaged needs_answer. It must not surface in any section: the phrasing
        // LLM turns `"" from nobody` into invented mail ("you have an urgent
        // request") even when every real count is zero.
        let store = SyncStore::new_in_memory().unwrap();
        let now = Local.with_ymd_and_hms(2024, 6, 10, 9, 0, 0).unwrap();
        {
            let conn = store.connection();
            let conn = conn.lock();
            conn.execute(
                "INSERT INTO conversations
                   (key, organization_id, subject, from_address, triage_label, priority_urgent, read, updated_at)
                 VALUES ('ghost', 'org', NULL, '', ?1, 1, 0, ?2)",
                params![TriageLabel::NeedsAnswer.as_str(), now.to_rfc3339()],
            )
            .unwrap();
        }

        let brief = assemble(&store, now).unwrap();
        assert_eq!(brief.unread_count, 0);
        assert!(brief.unread_new.is_empty());
        assert!(brief.urgent.items.is_empty());
        assert!(brief.awaiting_you.is_empty());
        assert!(brief.facts_prompt().contains("Unread messages: 0."));
    }

    #[test]
    fn preview_does_not_consume_new_unread_but_commit_does() {
        let store = SyncStore::new_in_memory().unwrap();
        let now = Local.with_ymd_and_hms(2024, 6, 10, 14, 0, 0).unwrap(); // afternoon (not morning)
        {
            let conn = store.connection();
            let conn = conn.lock();
            conn.execute(
                "INSERT INTO conversations (key, organization_id, subject, from_address, snippet, read, status, updated_at)
                 VALUES ('u1', 'org', 'Budget', 'Alice <a@x.com>', 'about the budget', 0, 'open', '2024-06-10T09:00:00+00:00')",
                [],
            )
            .unwrap();
        }
        // Pre-warm twice: both still see the thread as new (no gating consumed).
        assert!(assemble_preview(&store, now).unwrap().facts_prompt().contains("subject \"Budget\""));
        assert!(assemble_preview(&store, now).unwrap().facts_prompt().contains("subject \"Budget\""));
        // The real brief still reports it as new...
        assert!(assemble(&store, now).unwrap().facts_prompt().contains("subject \"Budget\""));
        // ...and now it's recorded as announced, so the next real brief doesn't repeat it.
        assert!(assemble(&store, now).unwrap().facts_prompt().contains("New unread since last time: none"));
    }

    #[test]
    fn followups_silent_when_nothing_is_hanging() {
        let store = SyncStore::new_in_memory().unwrap();
        let now = Local.with_ymd_and_hms(2024, 6, 10, 9, 0, 0).unwrap();
        let brief = assemble(&store, now).unwrap();
        assert!(brief.awaiting_you.is_empty());
        assert!(brief.awaiting_others.is_empty());
        // The spoken brief simply omits the section rather than saying "zero".
        assert!(!brief.spoken_fallback().to_lowercase().contains("waiting on your reply"));
        assert!(brief.facts_prompt().contains("Open questions (last 7 days): none"));
    }

    #[test]
    fn is_morning_tracks_the_window() {
        let store = SyncStore::new_in_memory().unwrap();
        let morning = Local.with_ymd_and_hms(2024, 6, 10, 9, 0, 0).unwrap();
        let afternoon = Local.with_ymd_and_hms(2024, 6, 10, 14, 0, 0).unwrap();
        assert!(assemble_preview(&store, morning).unwrap().is_morning());
        assert!(!assemble_preview(&store, afternoon).unwrap().is_morning());
    }

    #[test]
    fn concise_brief_is_a_headline_not_a_rundown() {
        let store = SyncStore::new_in_memory().unwrap();
        let now = Local.with_ymd_and_hms(2024, 6, 10, 9, 0, 0).unwrap();
        {
            let conn = store.connection();
            let conn = conn.lock();
            // Two unread threads, one urgent + needs-answer (so the full brief would
            // enumerate them and the open-questions status).
            conn.execute(
                "INSERT INTO conversations
                   (key, organization_id, subject, from_address, snippet, read, status, triage_label, priority_urgent, updated_at)
                 VALUES ('u1', 'org', 'Budget question', 'Alice <a@x.com>', 'about the budget', 0, 'open', ?1, 1, ?2)",
                params![TriageLabel::NeedsAnswer.as_str(), now.to_rfc3339()],
            )
            .unwrap();
            conn.execute(
                "INSERT INTO conversations
                   (key, organization_id, subject, from_address, snippet, read, status, updated_at)
                 VALUES ('u2', 'org', 'Lunch plans', 'Bob <b@x.com>', 'lunch?', 0, 'open', ?1)",
                params![now.to_rfc3339()],
            )
            .unwrap();
        }
        let brief = assemble_preview(&store, now).unwrap();
        let concise = brief.spoken_concise();
        let full = brief.spoken_fallback();

        // The headline carries the greeting + the count.
        assert!(concise.contains("Good morning"), "{concise}");
        assert!(concise.contains("2 unread messages"), "{concise}");
        // It names at most the single most-pressing item, never the second thread.
        assert!(!concise.contains("Lunch plans"), "{concise}");
        // And it omits the open-questions rundown the full brief produces.
        assert!(!concise.to_lowercase().contains("waiting on your reply"), "{concise}");
        // It is genuinely terser than the full brief.
        assert!(concise.len() < full.len(), "concise={concise:?} full={full:?}");
    }
}
