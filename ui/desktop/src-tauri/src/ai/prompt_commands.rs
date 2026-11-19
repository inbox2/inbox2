//! Tauri commands for the user-editable prompt template file
//! (`<app data dir>/prompts.toml` — see `inbox2_core::bridge::prompts`).
//!
//! `prompts_set` validates BEFORE persisting and applies the override in-process
//! immediately (the triage worker and Bridge pick it up on their next call), so
//! the Triage Lab's edit → save → re-run loop needs no restart.

use inbox2_core::bridge::prompts;
use tauri::Manager;

fn prompts_path(app: &tauri::AppHandle) -> Result<std::path::PathBuf, String> {
    Ok(app
        .path()
        .app_data_dir()
        .map_err(|e| e.to_string())?
        .join("prompts.toml"))
}

/// The active prompt file text: the user's override when one exists, else the
/// embedded defaults. Carries both so an editor can offer "reset to defaults".
#[tauri::command]
pub fn prompts_get(app: tauri::AppHandle) -> Result<serde_json::Value, String> {
    let path = prompts_path(&app)?;
    let override_text = std::fs::read_to_string(&path).ok();
    Ok(serde_json::json!({
        "text": override_text.clone().unwrap_or_else(|| prompts::DEFAULT_TOML.to_string()),
        "isOverride": override_text.is_some(),
        "defaultText": prompts::DEFAULT_TOML,
        "path": path.display().to_string(),
    }))
}

/// Validate, apply, and persist an edited prompt file. A rejected file (bad TOML,
/// unknown section, `[triage]` without `{labels}`) changes nothing — the error
/// message is returned for the editor to show inline.
#[tauri::command]
pub fn prompts_set(app: tauri::AppHandle, text: String) -> Result<(), String> {
    prompts::set_overrides(Some(&text))?;
    let path = prompts_path(&app)?;
    std::fs::write(&path, &text).map_err(|e| format!("write {}: {e}", path.display()))?;
    Ok(())
}

/// Remove the override file and revert to the embedded defaults.
#[tauri::command]
pub fn prompts_reset(app: tauri::AppHandle) -> Result<(), String> {
    let path = prompts_path(&app)?;
    if path.exists() {
        std::fs::remove_file(&path).map_err(|e| e.to_string())?;
    }
    prompts::set_overrides(None)
}
