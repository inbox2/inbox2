use std::fs;
use std::path::{Path, PathBuf};

use serde::{Deserialize, Serialize};
use tauri::{AppHandle, Emitter};

/// A model download request from the frontend.
#[derive(Debug, Deserialize)]
pub struct ModelDownloadRequest {
    pub key: String,
    pub repo: String,
    pub name: String,
    pub task: String,
}

/// Progress event emitted during download.
#[derive(Debug, Clone, Serialize)]
pub struct DownloadProgress {
    pub model_name: String,
    pub percent: u32,
    pub overall: u32,
}

/// Result of a batch model download.
#[derive(Debug, Serialize)]
pub struct DownloadResult {
    pub success: bool,
    pub errors: Vec<String>,
}

/// Disk usage info for the AI models directory.
#[derive(Debug, Serialize)]
pub struct DiskUsage {
    #[serde(rename = "totalMB")]
    pub total_mb: u64,
    pub models: Vec<ModelDiskEntry>,
}

#[derive(Debug, Serialize)]
pub struct ModelDiskEntry {
    pub name: String,
    #[serde(rename = "sizeMB")]
    pub size_mb: u64,
}

/// Get the models directory path within app data.
pub fn models_dir(app_data_dir: &Path) -> PathBuf {
    app_data_dir.join("models")
}

/// Download all requested models to the app data directory.
/// Emits progress events via Tauri's event system.
///
/// Models are downloaded from Hugging Face Hub via HTTP.
/// Each model gets its own subdirectory: models/{key}/
pub async fn download_models(
    app_handle: &AppHandle,
    app_data_dir: &Path,
    models: Vec<ModelDownloadRequest>,
) -> DownloadResult {
    let dir = models_dir(app_data_dir);
    if let Err(e) = fs::create_dir_all(&dir) {
        return DownloadResult {
            success: false,
            errors: vec![format!("Failed to create models directory: {e}")],
        };
    }

    let total = models.len() as u32;
    let mut errors = Vec::new();

    for (i, model) in models.iter().enumerate() {
        let model_dir = dir.join(&model.key);
        let _ = fs::create_dir_all(&model_dir);

        // Construct the Hugging Face download URL for the ONNX model
        let base_url = format!(
            "https://huggingface.co/{}/resolve/main/onnx/model_quantized.onnx",
            model.repo
        );

        match download_file(&base_url, &model_dir.join("model.onnx")).await {
            Ok(_) => {
                // The tokenizer + config are required at warmup; a missing one
                // makes the model load fail opaquely later. Surface these
                // failures instead of swallowing them with `let _ =`.
                let tokenizer_url = format!(
                    "https://huggingface.co/{}/resolve/main/tokenizer.json",
                    model.repo
                );
                if let Err(e) =
                    download_file(&tokenizer_url, &model_dir.join("tokenizer.json")).await
                {
                    errors.push(format!("{} (tokenizer.json): {e}", model.name));
                }

                let config_url = format!(
                    "https://huggingface.co/{}/resolve/main/config.json",
                    model.repo
                );
                if let Err(e) =
                    download_file(&config_url, &model_dir.join("config.json")).await
                {
                    errors.push(format!("{} (config.json): {e}", model.name));
                }
            }
            Err(e) => {
                errors.push(format!("{}: {e}", model.name));
            }
        }

        let overall = ((i as u32 + 1) * 100) / total;
        let _ = app_handle.emit("ai-model-download-progress", DownloadProgress {
            model_name: model.name.clone(),
            percent: 100,
            overall,
        });
    }

    DownloadResult {
        success: errors.is_empty(),
        errors,
    }
}

/// Download a single file from a URL to a local path, streaming to disk and
/// verifying integrity: the transfer must be non-empty and, when the server
/// advertises `Content-Length`, match it exactly. A truncated transfer or an
/// HTML error page is rejected and the partial file removed, rather than being
/// left to fail opaquely at model-load time.
async fn download_file(url: &str, dest: &Path) -> Result<(), String> {
    use std::io::Write as _;

    let mut response = reqwest::get(url)
        .await
        .map_err(|e| format!("HTTP request failed: {e}"))?;

    if !response.status().is_success() {
        return Err(format!("HTTP {}: {url}", response.status()));
    }

    let expected = response.content_length();
    let mut file = fs::File::create(dest).map_err(|e| format!("Failed to create file: {e}"))?;
    let mut written: u64 = 0;
    while let Some(chunk) = response
        .chunk()
        .await
        .map_err(|e| format!("Failed to read response: {e}"))?
    {
        file.write_all(&chunk).map_err(|e| format!("Failed to write file: {e}"))?;
        written += chunk.len() as u64;
    }
    file.flush().map_err(|e| format!("Failed to flush file: {e}"))?;
    drop(file);

    if written == 0 {
        let _ = fs::remove_file(dest);
        return Err(format!("empty download: {url}"));
    }
    if let Some(expected) = expected {
        if written != expected {
            let _ = fs::remove_file(dest);
            return Err(format!(
                "truncated download ({written} of {expected} bytes): {url}"
            ));
        }
    }
    Ok(())
}

/// Remove all downloaded AI models.
pub fn remove_models(app_data_dir: &Path) -> Result<(), String> {
    let dir = models_dir(app_data_dir);
    if dir.exists() {
        fs::remove_dir_all(&dir).map_err(|e| format!("Failed to remove models: {e}"))?;
    }
    Ok(())
}

/// Calculate disk usage for downloaded models.
pub fn get_disk_usage(app_data_dir: &Path) -> DiskUsage {
    let dir = models_dir(app_data_dir);
    if !dir.exists() {
        return DiskUsage {
            total_mb: 0,
            models: vec![],
        };
    }

    let mut total_bytes: u64 = 0;
    let mut models = Vec::new();

    if let Ok(entries) = fs::read_dir(&dir) {
        for entry in entries.flatten() {
            if entry.path().is_dir() {
                let size = dir_size(&entry.path());
                let size_mb = size / (1024 * 1024);
                models.push(ModelDiskEntry {
                    name: entry.file_name().to_string_lossy().to_string(),
                    size_mb,
                });
                total_bytes += size;
            }
        }
    }

    DiskUsage {
        total_mb: total_bytes / (1024 * 1024),
        models,
    }
}

/// Recursively compute directory size in bytes.
fn dir_size(path: &Path) -> u64 {
    let mut total = 0;
    if let Ok(entries) = fs::read_dir(path) {
        for entry in entries.flatten() {
            let p = entry.path();
            if p.is_file() {
                total += entry.metadata().map(|m| m.len()).unwrap_or(0);
            } else if p.is_dir() {
                total += dir_size(&p);
            }
        }
    }
    total
}
