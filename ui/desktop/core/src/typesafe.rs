//! Jev — TypeSafe's System One model (`api.typesafe.ai`), the classifier behind
//! triage (label, priority, space). One request carries the thread as `state`
//! plus typed `questions`; the response carries one typed answer per question.
//! Contract: `docs/Triage.md`. The questions themselves are built in
//! [`crate::triage::jev_questions`].

use std::collections::HashMap;
use std::sync::OnceLock;
use std::time::Duration;

use serde::{Deserialize, Serialize};

/// Where System One lives. Tests point the engine at a mock server instead
/// (see `SyncEngine::set_jev_endpoint`).
pub const ENDPOINT: &str = "https://api.typesafe.ai/v1/systemone";

/// The pinned model. The space threshold was set on this model; `jev-latest`
/// moves on release, so bump this deliberately (and re-run the eval).
pub const MODEL: &str = "jev-1.13.0";

/// Why a Jev call failed. The worker treats each differently: `Unauthorized`
/// stops calling until the key changes, `Blocked` pauses the whole queue and
/// probes once a minute, `Transient` defers + retries, `Invalid` is a bug in our
/// request (logged, not retried).
#[derive(Debug, Clone, PartialEq, thiserror::Error)]
pub enum JevError {
    #[error("Jev rejected the API key (401)")]
    Unauthorized,
    /// 402/403: the key is fine but the account can't be used right now
    /// (credits ran out, plan or billing). Not in TypeSafe's documented error
    /// table — the account's state, not ours, so nothing is skipped over it.
    #[error("{0}")]
    Blocked(String),
    #[error("Jev transient error: {0}")]
    Transient(String),
    #[error("Jev rejected the request: {0}")]
    Invalid(String),
}

/// Whether triage can call Jev right now (from the engine's key state).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum JevStatus {
    /// No key pushed: rules only, ambiguous threads stay unlabelled.
    Missing,
    Ok,
    /// Jev answered 401: calls stop until the key changes.
    Unauthorized,
}

impl JevStatus {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Missing => "missing",
            Self::Ok => "ok",
            Self::Unauthorized => "unauthorized",
        }
    }
}

/// One typed answer. Unknown extra fields (`legend`, score `probabilities`) are ignored.
#[derive(Debug, Clone, Deserialize)]
#[serde(tag = "type", rename_all = "lowercase")]
pub enum Answer {
    Choice {
        choice: String,
        #[serde(default)]
        probabilities: HashMap<String, f64>,
        #[serde(default)]
        confidence: f64,
    },
    Score {
        score: f64,
        #[serde(default)]
        confidence: f64,
    },
    Noul {
        noul: f64,
    },
}

/// The response body: the model that answered (echoed) + answers keyed by question name.
#[derive(Debug, Clone, Deserialize)]
pub struct JevResponse {
    pub model: String,
    #[serde(default)]
    pub answers: HashMap<String, Answer>,
}

#[derive(Serialize)]
struct Request<'a, S: Serialize, Q: Serialize> {
    state: &'a S,
    model: &'a str,
    questions: &'a Q,
}

fn http() -> &'static reqwest::Client {
    static CLIENT: OnceLock<reqwest::Client> = OnceLock::new();
    CLIENT.get_or_init(|| {
        reqwest::Client::builder()
            .connect_timeout(Duration::from_secs(5))
            .timeout(Duration::from_secs(20))
            .build()
            .expect("reqwest client builds")
    })
}

/// Ask Jev `questions` about `state`.
pub async fn ask<S: Serialize, Q: Serialize>(
    endpoint: &str,
    key: &str,
    state: &S,
    questions: &Q,
) -> Result<JevResponse, JevError> {
    let resp = http()
        .post(endpoint)
        .bearer_auth(key)
        .json(&Request { state, model: MODEL, questions })
        .send()
        .await
        .map_err(|e| JevError::Transient(e.to_string()))?;
    let status = resp.status();
    if status.is_success() {
        return resp
            .json::<JevResponse>()
            .await
            .map_err(|e| JevError::Transient(format!("unreadable response: {e}")));
    }
    let body: String = resp.text().await.unwrap_or_default().chars().take(500).collect();
    Err(match status.as_u16() {
        401 => JevError::Unauthorized,
        402 | 403 => JevError::Blocked(blocked_message(status.as_u16(), &body)),
        429 | 529 => JevError::Transient(format!("{status}: {body}")),
        s if s >= 500 => JevError::Transient(format!("{status}: {body}")),
        _ => JevError::Invalid(format!("{status}: {body}")),
    })
}

/// What the user sees for a 402/403: TypeSafe's own `message`/`error` text when
/// the body carries one, else a generic line by status.
fn blocked_message(status: u16, body: &str) -> String {
    let from_body = serde_json::from_str::<serde_json::Value>(body).ok().and_then(|v| {
        let e = v.get("error");
        [v.get("message"), e.and_then(|e| e.get("message")), e]
            .into_iter()
            .flatten()
            .find_map(|m| m.as_str().map(str::to_string))
    });
    from_body.unwrap_or_else(|| match status {
        402 => "TypeSafe account is out of credits".into(),
        _ => "TypeSafe refused the request (403)".into(),
    })
}

/// Check a key with the smallest real call (one Noul question). `Err` carries a
/// message a settings screen can show as-is.
pub async fn validate_key(endpoint: &str, key: &str) -> Result<(), String> {
    let key = key.trim();
    if key.is_empty() {
        return Err("enter a Jev API key".into());
    }
    let questions = serde_json::json!({ "ok": { "type": "noul", "instructions": "Is this a test message?" } });
    match ask(endpoint, key, &"inbox2 key check", &questions).await {
        Ok(_) => Ok(()),
        Err(JevError::Unauthorized) => Err("Jev rejected this API key".into()),
        Err(e) => Err(e.to_string()),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use wiremock::matchers::{header, method};
    use wiremock::{Mock, MockServer, ResponseTemplate};

    #[tokio::test]
    async fn maps_statuses_and_parses_answers() {
        let server = MockServer::start().await;
        Mock::given(method("POST"))
            .and(header("authorization", "Bearer good"))
            .respond_with(ResponseTemplate::new(200).set_body_json(serde_json::json!({
                "model": "jev-1.13.0",
                "answers": {
                    "label": {"type": "choice", "choice": "fyi", "probabilities": {"fyi": 0.9}, "confidence": 0.8},
                    "priority": {"type": "score", "score": 1.2, "legend": {"0": "x"}, "confidence": 0.5},
                    "ok": {"type": "noul", "noul": 0.99}
                },
                "usage": {"input_tokens": 1, "output_tokens": 1}
            })))
            .mount(&server)
            .await;
        Mock::given(method("POST"))
            .and(header("authorization", "Bearer bad"))
            .respond_with(ResponseTemplate::new(401))
            .mount(&server)
            .await;
        Mock::given(method("POST"))
            .and(header("authorization", "Bearer busy"))
            .respond_with(ResponseTemplate::new(529))
            .mount(&server)
            .await;
        Mock::given(method("POST"))
            .and(header("authorization", "Bearer broken"))
            .respond_with(ResponseTemplate::new(422).set_body_string("bad question"))
            .mount(&server)
            .await;

        let url = server.uri();
        let r = ask(&url, "good", &"s", &serde_json::json!({})).await.unwrap();
        assert_eq!(r.model, "jev-1.13.0");
        assert!(matches!(&r.answers["label"], Answer::Choice { choice, .. } if choice == "fyi"));
        assert!(matches!(r.answers["priority"], Answer::Score { score, .. } if score == 1.2));
        assert!(validate_key(&url, "good").await.is_ok());

        assert_eq!(ask(&url, "bad", &"s", &()).await.unwrap_err(), JevError::Unauthorized);
        assert!(validate_key(&url, "bad").await.unwrap_err().contains("rejected"));
        assert!(matches!(ask(&url, "busy", &"s", &()).await, Err(JevError::Transient(_))));
        assert!(matches!(ask(&url, "broken", &"s", &()).await, Err(JevError::Invalid(m)) if m.contains("bad question")));
    }
}
