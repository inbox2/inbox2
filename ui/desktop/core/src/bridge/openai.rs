//! Minimal OpenAI REST client for the Bridge — chat completions (brief + replies)
//! and key validation. Uses the user's own key, passed in by the host (stored in the
//! platform Keychain, never in core). Async `reqwest` on the engine's runtime.

use serde::{Deserialize, Serialize};
use serde_json::{json, Value};

pub struct OpenAiClient {
    key: String,
    http: reqwest::Client,
}

/// A tool call the model wants run.
pub struct ToolCall {
    pub id: String,
    pub name: String,
    pub arguments: String,
}

/// Outcome of a tool-enabled chat turn.
pub enum ChatOutcome {
    Text(String),
    ToolCalls(Vec<ToolCall>),
}

#[derive(Serialize)]
struct ChatMessage<'a> {
    role: &'a str,
    content: &'a str,
}

#[derive(Serialize)]
struct ChatRequest<'a> {
    model: &'a str,
    messages: Vec<ChatMessage<'a>>,
    temperature: f32,
}

#[derive(Deserialize)]
struct ChatResponse {
    choices: Vec<ChatChoice>,
}

#[derive(Deserialize)]
struct ChatChoice {
    message: ChatChoiceMessage,
}

#[derive(Deserialize)]
struct ChatChoiceMessage {
    content: String,
}

#[derive(Deserialize)]
struct ApiErrorEnvelope {
    error: ApiError,
}

#[derive(Deserialize)]
struct ApiError {
    message: String,
}

impl OpenAiClient {
    pub fn new(key: String) -> Self {
        // A stalled request must not hang the caller forever — the triage worker
        // drains on a single task, and a wedged HTTP call freezes its progress bar.
        // Bound both the connect and the overall request; on builder failure (a rare
        // TLS-backend init issue) fall back to a default client rather than panic.
        let http = reqwest::Client::builder()
            .connect_timeout(std::time::Duration::from_secs(15))
            .timeout(std::time::Duration::from_secs(60))
            .build()
            .unwrap_or_default();
        Self { key, http }
    }

    /// Chat completion → assistant text. `Err` carries the OpenAI error message
    /// (e.g. "Incorrect API key provided: …") so the host can surface it verbatim.
    pub async fn generate(&self, system: &str, user: &str, model: &str) -> Result<String, String> {
        let body = ChatRequest {
            model,
            messages: vec![
                ChatMessage { role: "system", content: system },
                ChatMessage { role: "user", content: user },
            ],
            temperature: 0.5,
        };
        let resp = self
            .http
            .post("https://api.openai.com/v1/chat/completions")
            .bearer_auth(&self.key)
            .json(&body)
            .send()
            .await
            .map_err(|e| e.to_string())?;
        if !resp.status().is_success() {
            return Err(read_api_error(resp).await);
        }
        let parsed: ChatResponse = resp.json().await.map_err(|e| e.to_string())?;
        parsed
            .choices
            .into_iter()
            .next()
            .map(|c| c.message.content.trim().to_string())
            .ok_or_else(|| "OpenAI chat returned no content".to_string())
    }

    /// Tool-enabled chat turn over a raw message history. Returns either assistant
    /// text or the tool calls the model wants executed. `messages` is the running
    /// JSON history (system/user/assistant/tool roles); `tools` is the function
    /// schema array, or `None` for a plain completion.
    pub async fn chat(
        &self,
        model: &str,
        messages: &[Value],
        tools: Option<&Value>,
    ) -> Result<ChatOutcome, String> {
        let mut body = json!({ "model": model, "messages": messages, "temperature": 0.3 });
        if let Some(t) = tools {
            body["tools"] = t.clone();
        }
        let resp = self
            .http
            .post("https://api.openai.com/v1/chat/completions")
            .bearer_auth(&self.key)
            .json(&body)
            .send()
            .await
            .map_err(|e| e.to_string())?;
        if !resp.status().is_success() {
            return Err(read_api_error(resp).await);
        }
        let v: Value = resp.json().await.map_err(|e| e.to_string())?;
        let msg = &v["choices"][0]["message"];
        if let Some(calls) = msg["tool_calls"].as_array() {
            if !calls.is_empty() {
                let parsed = calls
                    .iter()
                    .filter_map(|c| {
                        Some(ToolCall {
                            id: c["id"].as_str()?.to_string(),
                            name: c["function"]["name"].as_str()?.to_string(),
                            arguments: c["function"]["arguments"].as_str().unwrap_or("{}").to_string(),
                        })
                    })
                    .collect();
                return Ok(ChatOutcome::ToolCalls(parsed));
            }
        }
        Ok(ChatOutcome::Text(msg["content"].as_str().unwrap_or("").trim().to_string()))
    }

    /// Text-to-speech → MP3 bytes for the spoken reply (natural voice).
    pub async fn speak(&self, text: &str, voice: &str, model: &str) -> Result<Vec<u8>, String> {
        let body = json!({ "model": model, "voice": voice, "input": text, "response_format": "mp3" });
        let resp = self
            .http
            .post("https://api.openai.com/v1/audio/speech")
            .bearer_auth(&self.key)
            .json(&body)
            .send()
            .await
            .map_err(|e| e.to_string())?;
        if !resp.status().is_success() {
            return Err(read_api_error(resp).await);
        }
        let bytes = resp.bytes().await.map_err(|e| e.to_string())?;
        Ok(bytes.to_vec())
    }

    /// Transcribe WAV/MP3 `audio` bytes via OpenAI (`/v1/audio/transcriptions`).
    /// `model` e.g. `gpt-4o-transcribe`. Returns the recognized text.
    pub async fn transcribe(&self, audio: Vec<u8>, model: &str) -> Result<String, String> {
        let part = reqwest::multipart::Part::bytes(audio)
            .file_name("audio.wav")
            .mime_str("audio/wav")
            .map_err(|e| e.to_string())?;
        let form = reqwest::multipart::Form::new()
            .text("model", model.to_string())
            .text("response_format", "text")
            .part("file", part);
        let resp = self
            .http
            .post("https://api.openai.com/v1/audio/transcriptions")
            .bearer_auth(&self.key)
            .multipart(form)
            .send()
            .await
            .map_err(|e| e.to_string())?;
        if !resp.status().is_success() {
            return Err(read_api_error(resp).await);
        }
        // response_format=text ⇒ the body is the transcript, not JSON.
        Ok(resp.text().await.map_err(|e| e.to_string())?.trim().to_string())
    }

    /// Cheap key check (lists models). `Err` carries the OpenAI error message.
    pub async fn validate(&self) -> Result<(), String> {
        let resp = self
            .http
            .get("https://api.openai.com/v1/models")
            .bearer_auth(&self.key)
            .send()
            .await
            .map_err(|e| e.to_string())?;
        if resp.status().is_success() {
            Ok(())
        } else {
            Err(read_api_error(resp).await)
        }
    }
}

/// Extract OpenAI's `{ "error": { "message": … } }`, else an HTTP status note.
async fn read_api_error(resp: reqwest::Response) -> String {
    let status = resp.status().as_u16();
    let text = resp.text().await.unwrap_or_default();
    match serde_json::from_str::<ApiErrorEnvelope>(&text) {
        Ok(env) => env.error.message,
        Err(_) => format!("OpenAI request failed (HTTP {status})"),
    }
}
