// Native LLM Sidecar — manages a local llama.cpp-compatible inference server.
// Downloads and runs a GGUF model via an embedded llama-server binary.
// Falls back to this path on: Windows, Linux, or macOS without Apple Foundation Models.

use std::fs;
use std::net::TcpListener;
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Stdio};
use std::sync::Mutex;
use std::time::Duration;

use serde::{Deserialize, Serialize};

// ─── Configuration ───────────────────────────────────────────────────────────

/// The free NLU lane's default desktop artifact in the shared model manifest —
/// the same Qwen2.5-1.5B-Instruct checkpoint mobile runs via LiteRT, as a Q4_K_M
/// GGUF for the llama-server sidecar. The manifest also carries an alternate
/// variant (Gemma 3 1B GGUF — smaller and faster, English-only); the provider is
/// constructed with whichever id the user picked. Single-sourcing ids/URLs/sizes
/// in the manifest keeps desktop and mobile on the same weights by construction.
pub const DEFAULT_MANIFEST_MODEL_ID: &str = "qwen2.5-1.5b-instruct-gguf";

/// A manifest entry's download URL and file name.
fn manifest_model(model_id: &str) -> (String, String) {
    let manifest = inbox2_core::bridge::models::Manifest::embedded();
    let entry = manifest
        .by_id(model_id)
        .unwrap_or_else(|| panic!("{model_id} missing from the shared model manifest"));
    let url = entry.files[0].url.clone();
    let file = url.rsplit('/').next().expect("model URL has a file name").to_string();
    (url, file)
}

// ─── Types ───────────────────────────────────────────────────────────────────

#[derive(Serialize)]
struct CompletionRequest {
    model: String,
    messages: Vec<ChatMessage>,
    temperature: f32,
    max_tokens: u32,
    stream: bool,
}

#[derive(Serialize, Clone)]
struct ChatMessage {
    role: String,
    content: String,
}

#[derive(Deserialize)]
struct CompletionResponse {
    choices: Vec<Choice>,
}

#[derive(Deserialize)]
struct Choice {
    message: ChoiceMessage,
}

#[derive(Deserialize)]
struct ChoiceMessage {
    content: String,
}

// ─── Native LLM Manager ─────────────────────────────────────────────────────

pub struct NativeLLMProvider {
    process: Mutex<Option<Child>>,
    server_url: String,
    model_id: String,
    models_dir: PathBuf,
    server_binary: PathBuf,
    model_path: PathBuf,
    ready: bool,
}

impl NativeLLMProvider {
    /// Create a new provider for a manifest GGUF (the user's free-lane variant
    /// choice — Qwen by default, or Gemma). Does not start the server.
    pub fn new(app_data_dir: &Path, model_id: &str) -> Self {
        let (_, model_file) = manifest_model(model_id);
        // Core model-manager layout (`models/<manifest id>/<file>` + `.complete`
        // marker) — the SAME install the Settings lane picker manages through
        // core's DownloadManager, so "installed" means one thing.
        let models_dir = app_data_dir.join("models").join(model_id);
        let model_path = models_dir.join(&model_file);
        // Migrate a pre-lane-picker install (models/generative/<file>) in place so
        // existing machines don't re-download the ~1.1 GB GGUF.
        let legacy = app_data_dir.join("models").join("generative").join(&model_file);
        if legacy.exists() && !model_path.exists() {
            if fs::create_dir_all(&models_dir).is_ok() && fs::rename(&legacy, &model_path).is_ok() {
                let _ = fs::write(models_dir.join(".complete"), "");
                log::info!("migrated generative GGUF into the model-manager layout");
            }
        }

        // The llama-server binary is expected in the app's bundled resources
        // or downloaded alongside the model.
        let server_binary = app_data_dir.join("bin").join(server_binary_name());

        Self {
            process: Mutex::new(None),
            server_url: String::new(),
            model_id: model_id.to_string(),
            models_dir,
            server_binary,
            model_path,
            ready: false,
        }
    }

    /// The manifest id of the GGUF this provider serves.
    pub fn model_id(&self) -> &str {
        &self.model_id
    }

    /// Check if the model file exists.
    pub fn is_model_downloaded(&self) -> bool {
        self.model_path.exists()
    }

    /// Check if the server binary is available.
    pub fn is_server_available(&self) -> bool {
        self.server_binary.exists()
    }

    /// Download this provider's GGUF model.
    pub async fn download_model(&self) -> Result<(), String> {
        fs::create_dir_all(&self.models_dir)
            .map_err(|e| format!("Failed to create models dir: {e}"))?;

        let (url, _) = manifest_model(&self.model_id);

        let mut response = reqwest::get(&url)
            .await
            .map_err(|e| format!("Download failed: {e}"))?;

        if !response.status().is_success() {
            return Err(format!("HTTP {}", response.status()));
        }

        // Stream to a temp file rather than buffering the whole (~1 GB) GGUF in
        // memory. Download to `.part` and rename on success so a crash or
        // truncated transfer never leaves a half-written model at the real path.
        use std::io::Write as _;
        let part_path = self.model_path.with_extension("gguf.part");
        let mut file = fs::File::create(&part_path)
            .map_err(|e| format!("Failed to create model file: {e}"))?;
        let mut written: u64 = 0;
        let mut magic = Vec::new();
        while let Some(chunk) = response
            .chunk()
            .await
            .map_err(|e| format!("Failed to read model stream: {e}"))?
        {
            if magic.len() < 4 {
                magic.extend_from_slice(&chunk[..chunk.len().min(4 - magic.len())]);
            }
            file.write_all(&chunk)
                .map_err(|e| format!("Failed to write model file: {e}"))?;
            written += chunk.len() as u64;
        }
        file.flush().map_err(|e| format!("Failed to flush model file: {e}"))?;
        drop(file);

        // Integrity check: a real GGUF starts with the "GGUF" magic. A truncated
        // download or an HTML error page won't, so reject it rather than handing
        // the sidecar a corrupt model that fails opaquely at load time.
        if written < 1024 || magic != b"GGUF" {
            let _ = fs::remove_file(&part_path);
            return Err(format!(
                "Downloaded model failed integrity check (size {written} bytes, bad magic)"
            ));
        }

        fs::rename(&part_path, &self.model_path)
            .map_err(|e| format!("Failed to finalize model file: {e}"))?;
        // The core DownloadManager's installed marker — keeps the Settings lane
        // picker's "installed" state truthful regardless of which path downloaded.
        fs::write(self.models_dir.join(".complete"), "")
            .map_err(|e| format!("Failed to write install marker: {e}"))?;

        Ok(())
    }

    /// Start the llama-server process.
    pub fn start_server(&mut self) -> Result<(), String> {
        if !self.server_binary.exists() {
            return Err(format!(
                "Server binary not found at {}",
                self.server_binary.display()
            ));
        }
        if !self.model_path.exists() {
            return Err("Model not downloaded".to_string());
        }

        // Find a free port
        let port = find_free_port().ok_or("No free port available")?;
        self.server_url = format!("http://127.0.0.1:{port}");

        let child = Command::new(&self.server_binary)
            .args([
                "--model",
                self.model_path.to_str().unwrap_or(""),
                "--host",
                "127.0.0.1",
                "--port",
                &port.to_string(),
                "--ctx-size",
                &inbox2_core::bridge::ON_DEVICE_CONTEXT_TOKENS.to_string(),
                "--threads",
                &num_cpus().to_string(),
            ])
            .stdin(Stdio::null())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .spawn()
            .map_err(|e| format!("Failed to start server: {e}"))?;

        *self.process.lock().unwrap() = Some(child);

        // Wait for server to be ready (poll health endpoint)
        self.wait_for_ready(Duration::from_secs(30))?;
        self.ready = true;
        Ok(())
    }

    /// Wait for the server to be ready by polling.
    fn wait_for_ready(&self, timeout: Duration) -> Result<(), String> {
        let start = std::time::Instant::now();
        let health_url = format!("{}/health", self.server_url);

        loop {
            if start.elapsed() > timeout {
                return Err("Server startup timeout".to_string());
            }

            if let Ok(resp) = reqwest::blocking::get(&health_url) {
                if resp.status().is_success() {
                    return Ok(());
                }
            }

            std::thread::sleep(Duration::from_millis(200));
        }
    }

    /// Check if the server is running and ready.
    pub fn is_ready(&self) -> bool {
        self.ready
    }

    /// Generate text via the OpenAI-compatible API.
    pub async fn generate(
        &self,
        system: &str,
        prompt: &str,
        temperature: f32,
        max_tokens: u32,
    ) -> Result<String, String> {
        if !self.ready {
            return Err("Server not ready".to_string());
        }

        let request = CompletionRequest {
            model: "local".to_string(),
            messages: vec![
                ChatMessage {
                    role: "system".to_string(),
                    content: system.to_string(),
                },
                ChatMessage {
                    role: "user".to_string(),
                    content: prompt.to_string(),
                },
            ],
            temperature,
            max_tokens,
            stream: false,
        };

        let client = reqwest::Client::new();
        let response = client
            .post(format!("{}/v1/chat/completions", self.server_url))
            .json(&request)
            .send()
            .await
            .map_err(|e| format!("Request failed: {e}"))?;

        if !response.status().is_success() {
            let status = response.status();
            let body = response.text().await.unwrap_or_default();
            return Err(format!("HTTP {status}: {body}"));
        }

        let resp: CompletionResponse = response
            .json()
            .await
            .map_err(|e| format!("Parse error: {e}"))?;

        resp.choices
            .first()
            .map(|c| c.message.content.clone())
            .ok_or_else(|| "No response from model".to_string())
    }

    /// Generate smart reply suggestions.
    pub async fn smart_replies(&self, email: &str, sender: &str) -> Result<Vec<String>, String> {
        let system = inbox2_core::bridge::prompts::smart_replies_instructions();
        let prompt = format!("From: {sender}\n\n{email}");

        let text = self.generate(&system, &prompt, 0.7, 256).await?;

        // Parse JSON array
        serde_json::from_str::<Vec<String>>(&text)
            .or_else(|_| {
                // Try to find array in response
                if let Some(start) = text.find('[') {
                    if let Some(end) = text.rfind(']') {
                        return serde_json::from_str(&text[start..=end]);
                    }
                }
                Err(serde_json::Error::io(std::io::Error::new(
                    std::io::ErrorKind::InvalidData,
                    "No JSON array found",
                )))
            })
            .map(|v| v.into_iter().take(3).collect())
            .map_err(|e| format!("Failed to parse replies: {e}"))
    }

    /// Summarize text.
    pub async fn summarize(&self, text: &str) -> Result<String, String> {
        let system = inbox2_core::bridge::prompts::summarize_instructions();
        self.generate(&system, text, 0.3, 200).await
    }

    /// Stop the server process.
    pub fn stop(&self) {
        let mut guard = self.process.lock().unwrap();
        if let Some(mut child) = guard.take() {
            let _ = child.kill();
            let _ = child.wait();
        }
    }

    /// Get model file size on disk.
    pub fn model_size_mb(&self) -> u64 {
        if self.model_path.exists() {
            fs::metadata(&self.model_path)
                .map(|m| m.len() / (1024 * 1024))
                .unwrap_or(0)
        } else {
            0
        }
    }

    /// Remove the downloaded model.
    pub fn remove_model(&self) -> Result<(), String> {
        if self.models_dir.exists() {
            fs::remove_dir_all(&self.models_dir)
                .map_err(|e| format!("Failed to remove model: {e}"))?;
        }
        Ok(())
    }
}

impl Drop for NativeLLMProvider {
    fn drop(&mut self) {
        self.stop();
    }
}

// ─── Helpers ─────────────────────────────────────────────────────────────────

/// Get the platform-specific server binary name.
fn server_binary_name() -> &'static str {
    if cfg!(target_os = "windows") {
        "llama-server.exe"
    } else {
        "llama-server"
    }
}

/// Find a free TCP port.
fn find_free_port() -> Option<u16> {
    TcpListener::bind("127.0.0.1:0")
        .ok()
        .map(|l| l.local_addr().unwrap().port())
}

/// Get number of physical CPUs (capped for inference).
fn num_cpus() -> usize {
    std::thread::available_parallelism()
        .map(|n| n.get().min(8))
        .unwrap_or(4)
}
