// Tier-0 static rule matching — pure, deterministic predicates over a message's
// envelope. The cheap first gate of the funnel (docs/Agentic-Filters.md §1).
//
// Tier-1 (the on-device LLM gate) is represented by `LocalRule.ai_gate` and is
// evaluated separately by the runner before dispatch; it is a no-op when null.

use serde::{Deserialize, Serialize};

/// The fields a Tier-0 condition can test.
#[derive(Debug)]
pub struct MessageFields {
    pub from: String,
    pub to: String,
    pub subject: String,
    pub body: String,
    pub has_attachment: bool,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Condition {
    pub field: String, // from | to | subject | body | has_attachment
    pub op: String,    // equals | contains | starts_with | ends_with | is_true | is_false
    #[serde(default)]
    pub value: String,
}

/// All conditions must hold (AND). An empty condition set never matches — a rule
/// with no conditions would fire on every message, which is never intended.
pub fn conditions_match(conditions: &[Condition], m: &MessageFields) -> bool {
    if conditions.is_empty() {
        return false;
    }
    conditions.iter().all(|c| condition_match(c, m))
}

fn condition_match(c: &Condition, m: &MessageFields) -> bool {
    if c.field == "has_attachment" {
        return match c.op.as_str() {
            "is_true" => m.has_attachment,
            "is_false" => !m.has_attachment,
            // tolerate value-style booleans
            "equals" => (c.value == "true") == m.has_attachment,
            _ => false,
        };
    }

    let haystack = match c.field.as_str() {
        "from" => &m.from,
        "to" => &m.to,
        "subject" => &m.subject,
        "body" => &m.body,
        _ => return false,
    }
    .to_lowercase();
    let needle = c.value.to_lowercase();

    match c.op.as_str() {
        "equals" => haystack == needle,
        "contains" => haystack.contains(&needle),
        "starts_with" => haystack.starts_with(&needle),
        "ends_with" => haystack.ends_with(&needle),
        _ => false,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn msg() -> MessageFields {
        MessageFields {
            from: "Billing <billing@acme.com>".into(),
            to: "me@example.com".into(),
            subject: "Invoice #42 — June".into(),
            body: "Please find the invoice attached.".into(),
            has_attachment: true,
        }
    }

    fn cond(field: &str, op: &str, value: &str) -> Condition {
        Condition {
            field: field.into(),
            op: op.into(),
            value: value.into(),
        }
    }

    #[test]
    fn empty_conditions_never_match() {
        assert!(!conditions_match(&[], &msg()));
    }

    #[test]
    fn the_invoice_example_matches() {
        let rule = vec![
            cond("from", "contains", "billing@acme.com"),
            cond("has_attachment", "is_true", ""),
            cond("subject", "contains", "invoice"),
        ];
        assert!(conditions_match(&rule, &msg()));
    }

    #[test]
    fn all_conditions_must_hold() {
        let rule = vec![
            cond("from", "contains", "billing@acme.com"),
            cond("subject", "contains", "receipt"), // not present
        ];
        assert!(!conditions_match(&rule, &msg()));
    }

    #[test]
    fn operators_are_case_insensitive() {
        assert!(condition_match(&cond("subject", "starts_with", "INVOICE"), &msg()));
        assert!(condition_match(&cond("from", "ends_with", "ACME.COM>"), &msg()));
        assert!(condition_match(&cond("subject", "equals", "invoice #42 — june"), &msg()));
    }

    #[test]
    fn has_attachment_false_branch() {
        let mut m = msg();
        m.has_attachment = false;
        assert!(condition_match(&cond("has_attachment", "is_false", ""), &m));
        assert!(!condition_match(&cond("has_attachment", "is_true", ""), &m));
    }

    #[test]
    fn unknown_field_or_op_does_not_match() {
        assert!(!condition_match(&cond("nonsense", "contains", "x"), &msg()));
        assert!(!condition_match(&cond("subject", "regex", "x"), &msg()));
    }

    #[test]
    fn address_fields_are_from_and_to_only() {
        assert!(condition_match(&cond("from", "contains", "billing@acme.com"), &msg()));
        assert!(condition_match(&cond("to", "contains", "me@example.com"), &msg()));
        // `sender`/`recipient` are not field names — those belong to View filters.
        assert!(!condition_match(&cond("sender", "contains", "billing@acme.com"), &msg()));
        assert!(!condition_match(&cond("recipient", "contains", "me@example.com"), &msg()));
    }
}
