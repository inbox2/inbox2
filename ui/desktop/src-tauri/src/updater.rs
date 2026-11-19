// Self-hosted auto-update flow.
//
// The updater plugin polls `plugins.updater.endpoints` (latest.json served by
// the Rails app, see docs/Desktop-Release.md) for a build newer than the
// running version whose signature verifies against `plugins.updater.pubkey`.
// That signature is the whole security model: a compromised download host can
// serve any bytes it likes and the client refuses them.
//
//   check_for_updates            → Option<UpdateInfo>  (manual "Check" button)
//   download_and_install_update  → downloads (emitting progress), installs,
//                                  relaunches. On deb/rpm this hands off to a
//                                  privileged installer prompt (see UI copy).
//   check_on_startup             → fire-and-forget poll; emits `update://available`
//                                  so the chrome can grow its Update tag.
//
// The updater config lives in tauri.release.conf.json only — a release build
// carries it, and so does a local `yarn install:app` (install-local.mjs reads
// the same block, and stamps the same bin/version, so this Mac's own build
// stays in the update stream). lib.rs registers the plugin on that condition
// and `updates_supported` is the same test, so a dev build never offers to
// replace itself with a prod one.

use serde::Serialize;
use tauri::{AppHandle, Emitter};
use tauri_plugin_updater::UpdaterExt;

/// Update metadata handed to the frontend. Mirrors the latest.json entry plus
/// the running version so the UI can render "X.Y.Z → A.B.C".
#[derive(Serialize, Clone)]
pub struct UpdateInfo {
    pub version: String,
    pub current_version: String,
    pub notes: Option<String>,
    pub date: Option<String>,
}

/// Download progress, emitted on `update://progress` while installing.
#[derive(Serialize, Clone)]
struct DownloadProgress {
    downloaded: usize,
    content_length: Option<u64>,
}

fn to_info(update: &tauri_plugin_updater::Update) -> UpdateInfo {
    UpdateInfo {
        version: update.version.clone(),
        current_version: update.current_version.clone(),
        notes: update.body.clone(),
        date: update.date.map(|d| d.to_string()),
    }
}

/// True when this build can update itself at all.
pub fn updates_supported(app: &AppHandle) -> bool {
    app.config().plugins.0.contains_key("updater")
}

async fn check(app: &AppHandle) -> Result<Option<UpdateInfo>, String> {
    // Without the plugin, `app.updater()` reaches for state that was never
    // managed and panics — inside an async command that is a promise that
    // never settles, which the web side shows as "checking…" forever.
    if !updates_supported(app) {
        return Err("this build has no updater (a dev build)".into());
    }
    let updater = app.updater().map_err(|e| e.to_string())?;
    let found = updater.check().await.map_err(|e| e.to_string())?;
    Ok(found.as_ref().map(to_info))
}

/// Manual check. Returns None when already up to date (not an error), Some when
/// a newer signed build is published.
#[tauri::command]
pub async fn check_for_updates(app: AppHandle) -> Result<Option<UpdateInfo>, String> {
    check(&app).await.map_err(|e| {
        log::warn!("[updater] check failed: {e}");
        e
    })
}

/// Download + install the pending update, then relaunch. Emits `update://progress`
/// during the download so the UI can show a bar. Errors propagate to the caller.
#[tauri::command]
pub async fn download_and_install_update(app: AppHandle) -> Result<(), String> {
    if !updates_supported(&app) {
        return Err("this build has no updater".into());
    }
    let updater = app.updater().map_err(|e| e.to_string())?;
    let update = updater
        .check()
        .await
        .map_err(|e| e.to_string())?
        .ok_or_else(|| "no update available".to_string())?;

    log::info!(
        "[updater] installing {} → {}",
        update.current_version,
        update.version
    );

    let mut downloaded = 0usize;
    let app_for_progress = app.clone();
    let app_for_done = app.clone();
    update
        .download_and_install(
            move |chunk, content_length| {
                downloaded += chunk;
                let _ = app_for_progress.emit(
                    "update://progress",
                    DownloadProgress {
                        downloaded,
                        content_length,
                    },
                );
            },
            // The last chunk's event can lose the race with the restart; say
            // "all of it" once, explicitly, so the UI reads restarting.
            move || {
                log::info!("[updater] download complete, installing");
                let _ = app_for_done.emit(
                    "update://progress",
                    DownloadProgress { downloaded: 1, content_length: Some(1) },
                );
            },
        )
        .await
        .map_err(|e| {
            log::error!("[updater] install failed: {e}");
            e.to_string()
        })?;

    log::info!("[updater] installed, relaunching");
    app.restart();
}

/// Look for an update without blocking startup, and keep looking while the app
/// is open. Every push to main is a new build, so a client left open for a day
/// would otherwise never learn about any of them. On a hit it emits
/// `update://available`; the web client decides how loudly to mention it.
pub fn check_on_startup(app: &AppHandle) {
    if !updates_supported(app) {
        log::info!("[updater] no updater in this build, not polling");
        return;
    }
    let app = app.clone();
    // A plain OS thread for the wait, not the async runtime: sleeping on a
    // runtime worker would park a thread the plugins share.
    std::thread::spawn(move || {
        // Let the window paint and the first sync start first.
        std::thread::sleep(std::time::Duration::from_secs(3));
        loop {
            let app = app.clone();
            tauri::async_runtime::spawn(async move {
                match check(&app).await {
                    Ok(Some(info)) => {
                        log::info!(
                            "[updater] update available {} → {}",
                            info.current_version,
                            info.version
                        );
                        let _ = app.emit("update://available", info);
                    }
                    Ok(None) => log::debug!("[updater] up to date"),
                    // Offline, or nothing published yet. Neither is worth a
                    // word to the user.
                    Err(e) => log::debug!("[updater] check skipped ({e})"),
                }
            });
            // Two minutes: one small GET against our own server, and a push
            // lands as an Update tag before anyone has to ask.
            std::thread::sleep(std::time::Duration::from_secs(2 * 60));
        }
    });
}
