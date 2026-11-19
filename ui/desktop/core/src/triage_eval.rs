//! Triage eval harness — score fixture messages through the EXACT production
//! triage path, on any platform.
//!
//! Each fixture case is seeded into an ephemeral in-memory [`SyncStore`] and read
//! back through [`SyncStore::conversation_triage_input`], so the deterministic
//! rule SQL (`detect_label`), the thread-text assembly, and the body caps all run
//! precisely as they do over synced mail. Then, with a Jev key, the worker's own
//! [`ai_worker::jev_classify`] call runs (label when no rule fired, priority
//! always) — so a score measured here is the score the app would produce.
//! Summaries aren't scored (the deterministic pair is reported for context).
//!
//! Consumers: the `triage-eval` CLI (`--jev-key` / `$TYPESAFE_API_KEY`), the
//! desktop Triage Lab (Tauri command over the engine's live key and labels), and
//! the mobile debug screens (FFI `run_triage_eval`).

use serde::{Deserialize, Serialize};

use crate::ai_worker;
use crate::sync::store::{EvalSeedMessage, SyncStore};
use crate::triage::TriageLabelDef;

/// Where the Jev stage goes: the API endpoint and the key.
#[derive(Debug, Clone, Copy)]
pub struct JevLane<'a> {
    pub endpoint: &'a str,
    pub key: &'a str,
}

/// One message of a fixture thread (array order = oldest first).
#[derive(Debug, Clone, Deserialize, Serialize)]
pub struct EvalMessage {
    /// Sender address/name as it would appear in `from_address`.
    #[serde(default)]
    pub from: Option<String>,
    /// `Message-ID` header — the ESP-domain rules match against it.
    #[serde(default)]
    pub message_id: Option<String>,
    pub body: String,
    /// HTML part (unsubscribe footers usually live only here).
    #[serde(default)]
    pub html: Option<String>,
    /// `true` = the inbox owner sent this message.
    #[serde(default)]
    pub sent_by_owner: bool,
}

/// One fixture case: a thread plus the label it should get.
#[derive(Debug, Clone, Deserialize, Serialize)]
pub struct EvalCase {
    pub name: String,
    #[serde(default)]
    pub subject: Option<String>,
    /// Expected label (wire string, e.g. `needs_answer`). Omit to just observe.
    #[serde(default)]
    pub expected: Option<String>,
    pub messages: Vec<EvalMessage>,
}

/// The verdict for one case.
#[derive(Debug, Clone, Serialize)]
pub struct EvalCaseResult {
    pub name: String,
    pub expected: Option<String>,
    /// The label the production path produced (absent on error / no key).
    pub predicted: Option<String>,
    /// Jev's priority score (0.0–4.0), when Jev ran.
    pub priority: Option<f64>,
    /// Provenance: `rule:*`, `jev:*` or `rule:*+jev:*` — which stages ran.
    pub source: String,
    /// Raw deterministic signals that fired (for rule tuning).
    pub signals: String,
    pub medium: String,
    pub short: String,
    /// `Some(true/false)` when the case carries an expectation; `None` otherwise.
    pub pass: Option<bool>,
    pub error: Option<String>,
}

/// The whole run's outcome.
#[derive(Debug, Clone, Serialize)]
pub struct EvalReport {
    pub results: Vec<EvalCaseResult>,
    pub total: usize,
    /// Cases that carried an expectation.
    pub scored: usize,
    pub correct: usize,
    /// Cases the deterministic rules decided.
    pub by_rules: usize,
    /// Cases Jev labelled (name kept for the Triage Lab / mobile report readers).
    pub by_model: usize,
    pub errors: usize,
}

/// The embedded starter fixture set (`core/fixtures/triage-eval.json`) — every
/// rule path, all 8 labels, Dutch cases. The Triage Lab and the mobile debug
/// screens seed their editors with this; grow the on-disk copy with real-world
/// misclassifications.
pub const STARTER_FIXTURES: &str = include_str!("../fixtures/triage-eval.json");

/// Parse a fixtures JSON document: either a top-level array of cases or
/// `{ "cases": [...] }`.
pub fn parse_cases(json: &str) -> Result<Vec<EvalCase>, String> {
    #[derive(Deserialize)]
    struct Wrapper {
        cases: Vec<EvalCase>,
    }
    if let Ok(cases) = serde_json::from_str::<Vec<EvalCase>>(json) {
        return Ok(cases);
    }
    serde_json::from_str::<Wrapper>(json)
        .map(|w| w.cases)
        .map_err(|e| format!("invalid fixtures JSON: {e}"))
}

/// Run every case through the production triage path. With no Jev lane the
/// deterministic cases still score and ambiguous ones report "no Jev key" —
/// exactly the worker's rules-only split. `labels` is the label set Jev chooses
/// from (and that `expected` must name).
pub async fn run(cases: Vec<EvalCase>, jev: Option<JevLane<'_>>, labels: &[TriageLabelDef]) -> EvalReport {
    let mut results = Vec::with_capacity(cases.len());
    for case in &cases {
        results.push(run_case(case, jev, labels).await);
    }
    let total = results.len();
    let scored = results.iter().filter(|r| r.expected.is_some()).count();
    let correct = results.iter().filter(|r| r.pass == Some(true)).count();
    let by_rules = results.iter().filter(|r| r.source.starts_with("rule:")).count();
    let by_model = results.iter().filter(|r| r.source.starts_with("jev:")).count();
    let errors = results.iter().filter(|r| r.error.is_some()).count();
    EvalReport { results, total, scored, correct, by_rules, by_model, errors }
}

async fn run_case(case: &EvalCase, jev: Option<JevLane<'_>>, labels: &[TriageLabelDef]) -> EvalCaseResult {
    let mut out = EvalCaseResult {
        name: case.name.clone(),
        expected: case.expected.clone(),
        predicted: None,
        priority: None,
        source: String::new(),
        signals: String::new(),
        medium: String::new(),
        short: String::new(),
        pass: None,
        error: None,
    };

    // Seed the fixture into an ephemeral store and read it back through the
    // production input assembly (runs the deterministic rule SQL).
    let input = match seed_and_read(case) {
        Ok(i) => i,
        Err(e) => {
            out.error = Some(e);
            return out;
        }
    };
    out.signals = input.signals.clone();
    (out.medium, out.short) = ai_worker::deterministic_summaries(&input);
    out.predicted = input.deterministic.map(|l| l.as_str().to_string());
    out.source = input.det_source.to_string();

    match jev {
        Some(lane) => {
            let ask_label = input.deterministic.is_none();
            match ai_worker::jev_classify(lane.endpoint, lane.key, &input, labels, &[], ask_label).await {
                Ok(v) => {
                    if ask_label {
                        out.predicted = v.label;
                    }
                    out.priority = v.priority;
                    let jev = format!("jev:{}", v.model);
                    out.source = if out.source.is_empty() { jev } else { format!("{}+{jev}", out.source) };
                }
                Err(e) => out.error = Some(e.to_string()),
            }
        }
        None if input.deterministic.is_none() => out.error = Some("ambiguous case and no Jev key".into()),
        None => {}
    }

    if let Some(expected) = &case.expected {
        // An unknown expected label is a fixture bug — surface it, don't score it.
        // An errored case isn't a wrong answer either; it stays unscored.
        if !labels.iter().any(|l| &l.slug == expected) {
            out.error = Some(format!("unknown expected label: {expected}"));
        } else if out.error.is_none() {
            out.pass = Some(out.predicted.as_deref() == Some(expected.as_str()));
        }
    }
    out
}

/// Seed one case into a fresh in-memory store and assemble its triage input.
fn seed_and_read(case: &EvalCase) -> Result<crate::sync::store::TriageInput, String> {
    let store = SyncStore::new_in_memory().map_err(|e| e.to_string())?;
    let msgs: Vec<EvalSeedMessage<'_>> = case
        .messages
        .iter()
        .map(|m| EvalSeedMessage {
            from: m.from.as_deref(),
            message_id_header: m.message_id.as_deref(),
            body_plain: &m.body,
            body_html: m.html.as_deref(),
            sent_by_owner: m.sent_by_owner,
        })
        .collect();
    store
        .seed_eval_thread("eval_conv", case.subject.as_deref(), &msgs)
        .map_err(|e| e.to_string())?;
    store
        .conversation_triage_input("eval_conv")
        .map_err(|e| e.to_string())?
        .ok_or_else(|| "fixture has no messages".into())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn case(name: &str, subject: &str, expected: &str, body: &str) -> EvalCase {
        EvalCase {
            name: name.into(),
            subject: Some(subject.into()),
            expected: Some(expected.into()),
            messages: vec![EvalMessage {
                from: Some("someone@example.com".into()),
                message_id: None,
                body: body.into(),
                html: None,
                sent_by_owner: false,
            }],
        }
    }

    #[tokio::test]
    async fn deterministic_cases_score_without_a_model() {
        let cases = vec![
            case("bill", "Your bill", "payment_due", "Your monthly bill for account 123 is ready. Amount due: $40"),
            case("invite", "Invitation: Sync", "scheduling", "Sam has invited you to the following event"),
            case("ambiguous", "Re: lunch?", "needs_answer", "Are you free for lunch tomorrow?"),
        ];
        let report = run(cases, None, &crate::triage::builtin_labels()).await;
        assert_eq!(report.total, 3);
        assert_eq!(report.by_rules, 2);
        assert_eq!(report.correct, 2);
        // The ambiguous one needs Jev — with no key it errors.
        assert_eq!(report.errors, 1);
        let amb = &report.results[2];
        assert!(amb.error.as_deref().unwrap().contains("no Jev key"));
        // The deterministic ones carry provenance + summaries.
        assert_eq!(report.results[0].source, "rule:payment");
        assert!(!report.results[0].short.is_empty());
    }

    #[tokio::test]
    async fn jev_labels_ambiguous_cases_and_scores_every_case() {
        use wiremock::{matchers::method, Mock, MockServer, ResponseTemplate};
        let server = MockServer::start().await;
        Mock::given(method("POST"))
            .respond_with(ResponseTemplate::new(200).set_body_json(serde_json::json!({
                "model": "jev-1.13.0",
                "answers": {
                    "label": {"type": "choice", "choice": "needs_answer", "probabilities": {}, "confidence": 1.0},
                    "priority": {"type": "score", "score": 2.0, "confidence": 1.0}
                }
            })))
            .mount(&server)
            .await;
        let cases = vec![
            case("bill", "Your bill", "payment_due", "Your monthly bill for account 123 is ready. Amount due: $40"),
            case("ambiguous", "Re: lunch?", "needs_answer", "Are you free for lunch tomorrow?"),
        ];
        let lane = JevLane { endpoint: &server.uri(), key: "k" };
        let report = run(cases, Some(lane), &crate::triage::builtin_labels()).await;
        assert_eq!((report.correct, report.errors, report.by_rules, report.by_model), (2, 0, 1, 1));
        assert_eq!(report.results[0].source, "rule:payment+jev:jev-1.13.0");
        assert_eq!(report.results[1].source, "jev:jev-1.13.0");
        assert_eq!(report.results[1].priority, Some(2.0));
    }

    #[test]
    fn parses_both_fixture_shapes() {
        let arr = r#"[{"name":"a","messages":[{"body":"x"}]}]"#;
        let wrapped = r#"{"cases":[{"name":"a","messages":[{"body":"x"}]}]}"#;
        assert_eq!(parse_cases(arr).unwrap().len(), 1);
        assert_eq!(parse_cases(wrapped).unwrap().len(), 1);
        assert!(parse_cases("{}").is_err());
    }

    #[tokio::test]
    async fn unknown_expected_label_is_a_fixture_error() {
        let report =
            run(vec![case("bad", "Your bill", "banana", "invoice attached, amount due")], None, &crate::triage::builtin_labels())
                .await;
        assert_eq!(report.results[0].pass, None);
        assert!(report.results[0].error.as_deref().unwrap().contains("unknown expected label"));
    }
}
