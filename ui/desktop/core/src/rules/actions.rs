// Built-in "perform action" outcomes for a matched rule — the non-agent half of a
// rule's action (see RuleAction). Executed inline by the AgentRunner when a message
// matches, so they run wherever the engine is hosted: the GUI and the headless
// engine_daemon (and therefore the CLI, which talks to that engine). See
// docs/Agentic-Filters.md.
//
// Mutations (archive / delete / mark-read / labels / priority) go through the sync
// engine's durable write-back queue, so they're retried and survive offline and
// restart. The AI-backed actions (auto-triage / auto-label) use the on-device
// Tier-A engine and fail closed when the models aren't loaded.

use std::sync::Arc;

use crate::sync::engine::SyncEngine;
use crate::sync::model::Quadrant;

use super::ai::OnDeviceAi;
use super::conditions::MessageFields;

/// The built-in action a "perform_action" rule runs. Mirrors BUILTIN_ACTIONS in
/// ui/web/src/lib/localAgents.js — keep the keys in sync.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum BuiltinAction {
    Archive,
    Delete,
    MarkRead,
    AutoTriage,
    AutoLabel,
    AutoReply,
}

impl BuiltinAction {
    pub fn from_key(s: &str) -> Option<Self> {
        Some(match s {
            "archive" => Self::Archive,
            "delete" => Self::Delete,
            "mark_read" => Self::MarkRead,
            "auto_triage" => Self::AutoTriage,
            "auto_label" => Self::AutoLabel,
            "auto_reply" => Self::AutoReply,
            _ => return None,
        })
    }

    pub fn as_key(&self) -> &'static str {
        match self {
            Self::Archive => "archive",
            Self::Delete => "delete",
            Self::MarkRead => "mark_read",
            Self::AutoTriage => "auto_triage",
            Self::AutoLabel => "auto_label",
            Self::AutoReply => "auto_reply",
        }
    }
}

/// Map an on-device intent (+ negative sentiment) to an Eisenhower priority
/// (urgent, important). Pure so it's unit-testable; the runner feeds it the
/// classifier output.
pub fn triage_priority(intent: &str, negative: bool) -> (bool, bool) {
    let (mut urgent, important) = match intent {
        "complaint" => (true, true),  // DO_FIRST
        "request" => (false, true),   // SCHEDULE
        "question" => (false, true),
        "scheduling" => (true, false), // DELEGATE
        "FYI" => (false, false),       // LATER
        _ => (false, false),
    };
    // A negative-sentiment message is treated as time-sensitive.
    if negative {
        urgent = true;
    }
    (urgent, important)
}

/// Map an auto_triage quadrant choice to (urgent, important). Unknown keys are
/// treated as LATER.
pub fn quadrant_to_priority(q: &str) -> (bool, bool) {
    Quadrant::from_str(q).unwrap_or(Quadrant::Later).priority()
}

/// Human-friendly label for an on-device intent (applied as a provider label).
pub fn label_for_intent(intent: &str) -> &'static str {
    match intent {
        "question" => "Question",
        "request" => "Request",
        "complaint" => "Complaint",
        "scheduling" => "Scheduling",
        "FYI" => "FYI",
        _ => "Other",
    }
}

/// Classify a message with the on-device engine → (intent, negative_sentiment).
/// Fail-closed: returns Err when the engine is missing or its models aren't loaded.
async fn classify(
    ai: Option<&dyn OnDeviceAi>,
    fields: &MessageFields,
) -> Result<(String, bool), String> {
    let ai = ai.ok_or("on-device AI engine unavailable")?;
    if !ai.is_ready().await {
        return Err("on-device AI models not loaded".into());
    }
    let text = format!("From: {} | Subject: {} | {}", fields.from, fields.subject, fields.body);
    let intent = ai.intent(&text).await?;
    let negative = ai.sentiment_negative(&text).await;
    Ok((intent, negative))
}

/// Run a built-in action against a matched message's conversation. Returns a short
/// summary for the log/audit, or an error string the caller records.
#[allow(clippy::too_many_arguments)]
pub async fn execute(
    action: BuiltinAction,
    engine: &Arc<SyncEngine>,
    ai: Option<&dyn OnDeviceAi>,
    account_key: &str,
    conversation_key: &str,
    fields: &MessageFields,
    // Follow-up config (see RuleAction): triage target quadrant, reply body.
    quadrant: Option<&str>,
    reply: Option<&str>,
) -> Result<String, String> {
    if conversation_key.is_empty() {
        return Err("message has no conversation".into());
    }
    let convs = [conversation_key.to_string()];
    match action {
        BuiltinAction::Archive => {
            engine
                .perform_conversation_action(account_key, &convs, "archive")
                .await
                .map_err(|e| e.to_string())?;
            Ok("archived".into())
        }
        BuiltinAction::Delete => {
            engine
                .perform_conversation_action(account_key, &convs, "trash")
                .await
                .map_err(|e| e.to_string())?;
            Ok("moved to trash".into())
        }
        BuiltinAction::MarkRead => {
            engine
                .perform_conversation_action(account_key, &convs, "mark_read")
                .await
                .map_err(|e| e.to_string())?;
            Ok("marked read".into())
        }
        BuiltinAction::AutoTriage => {
            // A fixed quadrant is deterministic (no AI); "auto"/none falls back to
            // the on-device classifier.
            let (urgent, important, how) = match quadrant {
                Some(q) if q != "auto" && !q.is_empty() => {
                    let (u, i) = quadrant_to_priority(q);
                    (u, i, q.to_string())
                }
                _ => {
                    let (intent, negative) = classify(ai, fields).await?;
                    let (u, i) = triage_priority(&intent, negative);
                    (u, i, format!("auto:{intent}"))
                }
            };
            engine
                .set_conversation_priority(account_key, &convs, urgent, important)
                .await
                .map_err(|e| e.to_string())?;
            Ok(format!("triaged ({how}) → urgent={urgent}, important={important}"))
        }
        BuiltinAction::AutoLabel => {
            let (intent, _) = classify(ai, fields).await?;
            let label = label_for_intent(&intent).to_string();
            engine
                .add_conversation_label(account_key, &convs, label.clone())
                .await
                .map_err(|e| e.to_string())?;
            Ok(format!("labeled \"{label}\""))
        }
        BuiltinAction::AutoReply => {
            // The reply body is configured on the rule; actually sending mail
            // unattended needs the outbound send path + loop guards, so it's
            // deliberately deferred. Tracked, not silent.
            let _ = reply;
            Err("auto-reply is not sent automatically yet (the reply template is saved)".into())
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn fields() -> MessageFields {
        MessageFields {
            from: "sender@example.com".into(),
            to: "me@example.com".into(),
            subject: "Hello".into(),
            body: "body".into(),
            has_attachment: false,
        }
    }

    fn test_engine() -> Arc<SyncEngine> {
        Arc::new(SyncEngine::new(
            Arc::new(crate::sync::store::SyncStore::new_in_memory().unwrap()),
            Arc::new(crate::sync::events::NullSink),
        ))
    }

    #[test]
    fn builtin_action_keys_round_trip() {
        for key in ["archive", "delete", "mark_read", "auto_triage", "auto_label", "auto_reply"] {
            assert_eq!(BuiltinAction::from_key(key).unwrap().as_key(), key);
        }
        assert!(BuiltinAction::from_key("nope").is_none());
        assert!(BuiltinAction::from_key("").is_none());
    }

    #[test]
    fn triage_priority_maps_intents_to_quadrants() {
        assert_eq!(triage_priority("complaint", false), (true, true));
        assert_eq!(triage_priority("request", false), (false, true));
        assert_eq!(triage_priority("question", false), (false, true));
        assert_eq!(triage_priority("scheduling", false), (true, false));
        assert_eq!(triage_priority("FYI", false), (false, false));
        assert_eq!(triage_priority("other", false), (false, false));
    }

    #[test]
    fn negative_sentiment_forces_urgent() {
        assert_eq!(triage_priority("FYI", true), (true, false));
        assert_eq!(triage_priority("request", true), (true, true));
    }

    #[test]
    fn quadrant_to_priority_maps_quadrants() {
        assert_eq!(quadrant_to_priority("DO_FIRST"), (true, true));
        assert_eq!(quadrant_to_priority("DELEGATE"), (true, false));
        assert_eq!(quadrant_to_priority("SCHEDULE"), (false, true));
        assert_eq!(quadrant_to_priority("LATER"), (false, false));
        assert_eq!(quadrant_to_priority("???"), (false, false));
    }

    #[test]
    fn label_for_intent_covers_all_intents() {
        assert_eq!(label_for_intent("question"), "Question");
        assert_eq!(label_for_intent("request"), "Request");
        assert_eq!(label_for_intent("complaint"), "Complaint");
        assert_eq!(label_for_intent("scheduling"), "Scheduling");
        assert_eq!(label_for_intent("FYI"), "FYI");
        assert_eq!(label_for_intent("anything-else"), "Other");
    }

    #[tokio::test]
    async fn classify_fails_closed_without_engine() {
        assert!(classify(None, &fields()).await.is_err());
    }

    #[tokio::test]
    async fn auto_triage_fails_closed_without_ai_engine() {
        // No engine + "auto" quadrant must fall back to the classifier and error.
        let engine = test_engine();
        let r = execute(
            BuiltinAction::AutoTriage,
            &engine,
            None,
            "acc",
            "conv_x",
            &fields(),
            Some("auto"),
            None,
        )
        .await;
        assert!(r.is_err());
    }

    #[tokio::test]
    async fn empty_conversation_is_rejected() {
        let engine = test_engine();
        let r = execute(
            BuiltinAction::Archive,
            &engine,
            None,
            "acc",
            "",
            &fields(),
            None,
            None,
        )
        .await;
        assert!(r.unwrap_err().contains("conversation"));
    }

    #[tokio::test]
    async fn auto_reply_is_not_executed() {
        let engine = test_engine();
        let r = execute(
            BuiltinAction::AutoReply,
            &engine,
            None,
            "acc",
            "conv_x",
            &fields(),
            None,
            Some("thanks!"),
        )
        .await;
        assert!(r.unwrap_err().contains("auto-reply"));
    }
}
