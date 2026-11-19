// Apple Foundation Models Bridge
// Manages a Swift subprocess that wraps the macOS 26 FoundationModels framework.
// Communicates via JSON over stdin/stdout.

use std::io::{BufRead, BufReader, Write};
use std::path::PathBuf;
use std::process::{Child, Command, Stdio};
use std::sync::Mutex;

use serde::{Deserialize, Serialize};

// ─── Protocol Types ──────────────────────────────────────────────────────────

#[derive(Serialize)]
struct BridgeRequest {
    cmd: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    system: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    prompt: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    email: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    sender: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    text: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    max_tokens: Option<u32>,
}

#[derive(Deserialize)]
struct CheckResponse {
    available: bool,
    reason: Option<String>,
}

#[derive(Deserialize)]
pub struct GenerateResponse {
    pub text: Option<String>,
    pub error: Option<String>,
}

#[derive(Deserialize)]
pub struct SmartRepliesResponse {
    pub replies: Option<Vec<String>>,
    pub error: Option<String>,
}

#[derive(Deserialize)]
pub struct SummarizeResponse {
    pub summary: Option<String>,
    pub error: Option<String>,
}

// ─── Bridge Manager ──────────────────────────────────────────────────────────

pub struct AppleFoundationModelsBridge {
    process: Mutex<Option<Child>>,
    binary_path: PathBuf,
    available: bool,
}

impl AppleFoundationModelsBridge {
    /// Create a new bridge instance.
    /// The binary_path should point to the compiled FoundationModelsBridge executable.
    pub fn new(binary_path: PathBuf) -> Self {
        Self {
            process: Mutex::new(None),
            binary_path,
            available: false,
        }
    }

    /// Resolve the expected binary path within the app bundle.
    pub fn resolve_binary_path(app_data_dir: &std::path::Path) -> PathBuf {
        // In production, the Swift binary is bundled alongside the app.
        // During development, it may be at a relative path from the project root.
        let bundled = app_data_dir.join("FoundationModelsBridge");
        if bundled.exists() {
            return bundled;
        }

        // Development fallback: look in the swift-bridge build directory
        let dev_path = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
            .join("swift-bridge")
            .join(".build")
            .join("release")
            .join("FoundationModelsBridge");
        dev_path
    }

    /// Start the subprocess and check availability.
    pub fn initialize(&mut self) -> Result<bool, String> {
        if !self.binary_path.exists() {
            return Ok(false);
        }

        let child = Command::new(&self.binary_path)
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::null())
            .spawn()
            .map_err(|e| format!("Failed to spawn Foundation Models bridge: {e}"))?;

        *self.process.lock().unwrap() = Some(child);

        // Send check command
        match self.send_request::<CheckResponse>(&BridgeRequest {
            cmd: "check".to_string(),
            system: None,
            prompt: None,
            email: None,
            sender: None,
            text: None,
            max_tokens: None,
        }) {
            Ok(resp) => {
                self.available = resp.available;
                if !resp.available {
                    if let Some(reason) = &resp.reason {
                        log::info!("Apple Foundation Models not available: {reason}");
                    }
                    self.shutdown();
                }
                Ok(resp.available)
            }
            Err(e) => {
                self.shutdown();
                Err(e)
            }
        }
    }

    /// Check if Apple Foundation Models are available and the bridge is running.
    pub fn is_available(&self) -> bool {
        self.available
    }

    /// Generate text using Foundation Models.
    pub fn generate(
        &self,
        system: &str,
        prompt: &str,
        max_tokens: u32,
    ) -> Result<String, String> {
        let resp = self.send_request::<GenerateResponse>(&BridgeRequest {
            cmd: "generate".to_string(),
            system: Some(system.to_string()),
            prompt: Some(prompt.to_string()),
            email: None,
            sender: None,
            text: None,
            max_tokens: Some(max_tokens),
        })?;

        if let Some(err) = resp.error {
            return Err(err);
        }
        resp.text.ok_or_else(|| "No text in response".to_string())
    }

    /// Generate smart reply suggestions.
    pub fn smart_replies(&self, email: &str, sender: &str) -> Result<Vec<String>, String> {
        let resp = self.send_request::<SmartRepliesResponse>(&BridgeRequest {
            cmd: "smart_replies".to_string(),
            system: None,
            prompt: None,
            email: Some(email.to_string()),
            sender: Some(sender.to_string()),
            text: None,
            max_tokens: None,
        })?;

        if let Some(err) = resp.error {
            return Err(err);
        }
        resp.replies.ok_or_else(|| "No replies in response".to_string())
    }

    /// Summarize text.
    pub fn summarize(&self, text: &str) -> Result<String, String> {
        let resp = self.send_request::<SummarizeResponse>(&BridgeRequest {
            cmd: "summarize".to_string(),
            system: None,
            prompt: None,
            email: None,
            sender: None,
            text: Some(text.to_string()),
            max_tokens: None,
        })?;

        if let Some(err) = resp.error {
            return Err(err);
        }
        resp.summary.ok_or_else(|| "No summary in response".to_string())
    }

    /// Send a JSON request to the subprocess and read the response.
    ///
    /// NOTE: the response read is a blocking `read_line` on the child's stdout.
    /// If the child has *exited*, we detect that up front via `try_wait` and
    /// fail fast (and an EOF read is reported clearly) so a dead subprocess can't
    /// wedge every caller on a closed pipe. A child that is *alive but never
    /// responds* would still block here — a hard wall-clock timeout needs the
    /// bridge IPC reworked around a persistent reader thread (or a kill-by-pid
    /// watchdog), which is tracked separately.
    fn send_request<T: for<'de> Deserialize<'de>>(
        &self,
        request: &BridgeRequest,
    ) -> Result<T, String> {
        let mut guard = self.process.lock().unwrap_or_else(|e| e.into_inner());
        let child = guard
            .as_mut()
            .ok_or("Bridge process not running")?;

        // Fail fast if the subprocess already exited, instead of writing to and
        // reading from a dead pipe.
        if let Ok(Some(status)) = child.try_wait() {
            return Err(format!("Bridge subprocess exited ({status})"));
        }

        let stdin = child.stdin.as_mut().ok_or("No stdin pipe")?;
        let stdout = child.stdout.as_mut().ok_or("No stdout pipe")?;

        // Write request
        let json = serde_json::to_string(request)
            .map_err(|e| format!("Serialize error: {e}"))?;
        writeln!(stdin, "{json}").map_err(|e| format!("Write error: {e}"))?;
        stdin.flush().map_err(|e| format!("Flush error: {e}"))?;

        // Read response
        let mut reader = BufReader::new(stdout);
        let mut line = String::new();
        let n = reader
            .read_line(&mut line)
            .map_err(|e| format!("Read error: {e}"))?;
        if n == 0 {
            return Err("Bridge subprocess closed its output (no response)".to_string());
        }

        serde_json::from_str(&line).map_err(|e| format!("Parse error: {e}"))
    }

    /// Shutdown the subprocess.
    pub fn shutdown(&self) {
        let mut guard = self.process.lock().unwrap();
        if let Some(mut child) = guard.take() {
            let _ = child.kill();
            let _ = child.wait();
        }
    }
}

impl Drop for AppleFoundationModelsBridge {
    fn drop(&mut self) {
        self.shutdown();
    }
}
