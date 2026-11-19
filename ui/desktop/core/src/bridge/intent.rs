//! The Bridge intent layer: a spoken request → one structured, confidence-scored
//! intent. The catalog is the single source of truth — [`intent_prompt`] renders it
//! into the model prompt (so adding an intent updates the prompt automatically), and
//! the same shape is mirrored by the iOS `@Generable IntentResult` for
//! Apple-Intelligence guided generation.
//!
//! The model returns STRICT JSON:
//! `{"intent":"<key>","confidence":0.0-1.0,"slots":{...},"say":"<clarify or empty>"}`.
//! [`parse_intent`] reads it tolerantly. Dispatch + the confidence gate live in
//! [`crate::bridge::agent`].

use chrono::{DateTime, Local};
use serde_json::Value;

/// Below this self-reported confidence (or `unknown`), the agent asks to clarify
/// rather than act — so the Bridge never guesses at a destructive/ambiguous request.
pub const CONFIDENCE_FLOOR: f64 = 0.55;

/// One intent in the catalog: its key, what it means, its slot shape, and example
/// utterances the model learns the mapping from.
struct IntentSpec {
    key: &'static str,
    desc: &'static str,
    slots: &'static str,
    examples: &'static [&'static str],
}

/// The intent catalog — single source for both the prompt and the dispatcher.
const CATALOG: &[IntentSpec] = &[
    // ── Queries (read-only, spoken answer) ──
    IntentSpec {
        key: "agenda_today",
        desc: "What's on the user's calendar / agenda today.",
        slots: "{}",
        examples: &["what's on my agenda today", "what does my day look like", "what meetings do I have today", "am I busy today"],
    },
    IntentSpec {
        key: "needs_response",
        desc: "Which emails are waiting on the user to reply.",
        slots: "{}",
        examples: &["anything I need to respond to", "what needs my reply", "who's waiting on me", "what should I answer"],
    },
    IntentSpec {
        key: "missed_last_week",
        desc: "What the user may have missed over the past week (unread + needing a response).",
        slots: "{}",
        examples: &["anything from last week I missed", "what did I miss this week", "catch me up on last week"],
    },
    IntentSpec {
        key: "meeting_detail",
        desc: "Details about a specific meeting at a given day/time. Resolve the date and time to absolute values using the current time given below.",
        slots: "{\"date\":\"YYYY-MM-DD\",\"hour\":0-23,\"minute\":0-59}  (hour/minute optional)",
        examples: &["what's the meeting tomorrow at 11am about", "what's my 2pm about", "tell me about the standup today", "what's the 9:30 meeting"],
    },
    IntentSpec {
        key: "read_email",
        desc: "Read an email thread aloud (summary of previous + latest message).",
        slots: "{\"target\":\"last_unread|latest|current\"}",
        examples: &["read my latest email", "read the last unread message", "what's my newest email", "read it to me"],
    },
    IntentSpec {
        key: "brief",
        desc: "A general catch-up / situation report across inbox and calendar.",
        slots: "{}",
        examples: &["catch me up", "what's going on", "brief me", "what do I need to know"],
    },
    // ── Actions (local, reversible — executed) ──
    IntentSpec {
        key: "mark_read",
        desc: "Mark an email as read.",
        slots: "{\"target\":\"last_unread|latest|current\"}",
        examples: &["mark it as read", "mark the last unread as read"],
    },
    IntentSpec {
        key: "archive",
        desc: "Archive an email.",
        slots: "{\"target\":\"last_unread|latest|current\"}",
        examples: &["archive it", "archive this one"],
    },
    IntentSpec {
        key: "trash",
        desc: "Move an email to trash / delete it.",
        slots: "{\"target\":\"last_unread|latest|current\"}",
        examples: &["delete it", "trash this", "bin that email"],
    },
    // ── Drafts (NEVER sent/saved — surfaced on screen for the user to commit) ──
    IntentSpec {
        key: "draft_reply",
        desc: "Draft a reply to an email. NEVER send — only draft. Capture what the user wants to say.",
        slots: "{\"target\":\"current|last_unread|latest\",\"instruction\":\"what to say / the gist\"}",
        examples: &["draft a reply", "reply saying I'll be there", "tell them I'll get back next week", "draft a response to John saying thanks"],
    },
    IntentSpec {
        key: "schedule_meeting",
        desc: "Draft a calendar meeting. NEVER save — only draft. Resolve start/end to absolute times using the current time below; default 30 minutes if no end given.",
        slots: "{\"title\":\"...\",\"attendee_names\":[\"...\"],\"start\":\"RFC3339\",\"end\":\"RFC3339\",\"location\":\"...\"}",
        examples: &["schedule a meeting with John and Sarah tomorrow at 3", "set up a call with Alex next Monday at 10", "book 30 minutes with the design team Friday afternoon"],
    },
    IntentSpec {
        key: "add_reminder",
        desc: "Add a reminder / todo to the user's Lore list (no email is sent). Put the task in text, any time phrase in when.",
        slots: "{\"text\":\"...\",\"when\":\"...\"}",
        examples: &["remind me to call the bank tomorrow", "add a reminder to send the invoice on Friday"],
    },
    // ── Fallbacks ──
    IntentSpec {
        key: "chat",
        desc: "A general question or chit-chat that isn't one of the above.",
        slots: "{}",
        examples: &["how are you", "what can you do", "thanks"],
    },
    IntentSpec {
        key: "unknown",
        desc: "The request is unclear or doesn't match any intent. Put a short clarifying question in \"say\".",
        slots: "{}",
        examples: &["(anything ambiguous or unintelligible)"],
    },
];

/// All catalog keys, for tests / validation.
pub fn intent_keys() -> Vec<&'static str> {
    CATALOG.iter().map(|s| s.key).collect()
}

/// Build the classifier system prompt: the `[intent]` template from
/// [`crate::bridge::prompts`] with `{now}` filled (so the model resolves
/// "tomorrow at 11" to an absolute date/time) and `{intents}` rendered from the
/// catalog (so adding an intent updates the prompt automatically).
pub fn intent_prompt(now: DateTime<Local>) -> String {
    let now_fmt = format!("{} ({})", now.to_rfc3339(), now.format("%A"));
    let mut intents = String::new();
    for spec in CATALOG {
        intents.push_str(&format!("- {}: {} slots: {}\n", spec.key, spec.desc, spec.slots));
        intents.push_str(&format!("    e.g. {}\n", spec.examples.join(" | ")));
    }
    crate::bridge::prompts::intent_instructions(&now_fmt, intents.trim_end())
}

/// A parsed intent.
#[derive(Debug, Clone)]
pub struct ParsedIntent {
    pub intent: String,
    pub confidence: f64,
    pub slots: Value,
    pub say: String,
}

impl ParsedIntent {
    /// A string slot, or `""`.
    pub fn slot_str(&self, key: &str) -> String {
        self.slots.get(key).and_then(|v| v.as_str()).unwrap_or("").to_string()
    }
    /// A `u32` slot if present (accepts a number or numeric string).
    pub fn slot_u32(&self, key: &str) -> Option<u32> {
        self.slots.get(key).and_then(|v| v.as_u64().or_else(|| v.as_str().and_then(|s| s.parse().ok()))).map(|n| n as u32)
    }
    /// A string-array slot (e.g. attendee names).
    pub fn slot_list(&self, key: &str) -> Vec<String> {
        self.slots
            .get(key)
            .and_then(|v| v.as_array())
            .map(|a| a.iter().filter_map(|x| x.as_str().map(str::to_string)).collect())
            .unwrap_or_default()
    }
}

/// Parse the model's intent JSON, tolerating surrounding prose by extracting the first
/// `{…}` block. Returns `None` only when no JSON object is present at all.
pub fn parse_intent(raw: &str) -> Option<ParsedIntent> {
    let slice = first_json_object(raw)?;
    let v: Value = serde_json::from_str(slice).ok()?;
    let intent = v.get("intent").and_then(|x| x.as_str()).unwrap_or("unknown").trim().to_string();
    let confidence = v.get("confidence").and_then(|x| x.as_f64()).unwrap_or(0.0).clamp(0.0, 1.0);
    let slots = v.get("slots").cloned().unwrap_or_else(|| Value::Object(Default::default()));
    let say = v.get("say").and_then(|x| x.as_str()).unwrap_or("").to_string();
    Some(ParsedIntent { intent, confidence, slots, say })
}

/// Extract the first balanced-ish `{…}` block (first `{` to last `}`), tolerating
/// chatter a model may wrap around the JSON. Shared with the agent's action parser.
pub fn first_json_object(raw: &str) -> Option<&str> {
    match (raw.find('{'), raw.rfind('}')) {
        (Some(a), Some(b)) if b > a => Some(&raw[a..=b]),
        _ => None,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use chrono::TimeZone;

    #[test]
    fn prompt_lists_every_intent() {
        let now = Local.with_ymd_and_hms(2024, 6, 10, 9, 0, 0).unwrap();
        let p = intent_prompt(now);
        for key in intent_keys() {
            assert!(p.contains(key), "prompt missing intent {key}");
        }
        assert!(p.contains("2024-06-10"), "prompt should embed the current date");
    }

    #[test]
    fn parses_clean_and_prose_wrapped_json() {
        let pi = parse_intent(r#"{"intent":"agenda_today","confidence":0.9,"slots":{},"say":""}"#).unwrap();
        assert_eq!(pi.intent, "agenda_today");
        assert!(pi.confidence > 0.8);

        let pi2 = parse_intent("Sure! {\"intent\":\"draft_reply\",\"confidence\":0.7,\"slots\":{\"instruction\":\"I'll be there\"},\"say\":\"\"}\nDone")
            .unwrap();
        assert_eq!(pi2.intent, "draft_reply");
        assert_eq!(pi2.slot_str("instruction"), "I'll be there");
    }

    #[test]
    fn reads_typed_slots() {
        let pi = parse_intent(r#"{"intent":"meeting_detail","confidence":0.8,"slots":{"date":"2024-06-11","hour":11,"minute":0},"say":""}"#).unwrap();
        assert_eq!(pi.slot_str("date"), "2024-06-11");
        assert_eq!(pi.slot_u32("hour"), Some(11));

        let pi2 = parse_intent(r#"{"intent":"schedule_meeting","confidence":0.8,"slots":{"attendee_names":["John","Sarah"]},"say":""}"#).unwrap();
        assert_eq!(pi2.slot_list("attendee_names"), vec!["John", "Sarah"]);
    }

    #[test]
    fn no_json_returns_none() {
        assert!(parse_intent("no json here at all").is_none());
    }
}
