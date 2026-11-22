//! Disk in Finder, the app's side (docs/Disk-Sync.md).
//!
//! The File Provider extension inside Inbox2.app does the syncing. This app:
//!   * writes `config.json` into the App Group container (API base, token,
//!     settings and, only while FileVault is on, the member's identity key
//!     for sealed shares);
//!   * registers the Finder location (`NSFileProviderManager.addDomain`) and
//!     removes it, keeping any edits that didn't upload yet;
//!   * signals the extension every 30 seconds so it pulls server changes;
//!   * on every tick, drops the identity key and evicts downloaded sealed
//!     files when FileVault is off.

use serde::{Deserialize, Serialize};
use std::path::PathBuf;

use inbox2_core::disk::engine::{read_config, write_config, DiskConfig, DiskEngine};

const TEAM_ID: &str = "KF53B4S5HD";
const TICK_SECS: u64 = 30;

#[derive(Debug, Default, Serialize)]
pub struct DiskFinderStatus {
    /// macOS 15 or later.
    pub supported: bool,
    /// A Finder location is registered.
    pub enabled: bool,
    /// The member allowed it in System Settings.
    pub approved: bool,
    pub paused: bool,
    pub filevault: bool,
    /// The identity key is on this Mac, so sealed shares open.
    pub sealed_open: bool,
    pub org: Option<String>,
    pub path: Option<String>,
    pub items: u64,
    pub uploading: u64,
    pub last_sync_at: Option<i64>,
    pub last_error: Option<String>,
    pub keep_downloaded: bool,
    pub hidden_drives: Vec<String>,
    pub upload_kbps: u32,
    pub download_kbps: u32,
    pub local_bytes: u64,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct EnableArgs {
    pub org: String,
    pub org_name: String,
    pub member_id: String,
    pub api_base: String,
    pub web_base: String,
    pub token: String,
    pub member_name: String,
    pub identity_secret: Option<String>,
    pub identity_public: Option<String>,
}

/// Everything optional: only what is set changes.
#[derive(Debug, Deserialize, Default)]
#[serde(rename_all = "camelCase")]
pub struct UpdateArgs {
    pub token: Option<String>,
    pub identity_secret: Option<String>,
    pub identity_public: Option<String>,
    pub keep_downloaded: Option<bool>,
    pub hidden_drives: Option<Vec<String>>,
    pub upload_kbps: Option<u32>,
    pub download_kbps: Option<u32>,
}

fn group_dir(app_id: &str) -> PathBuf {
    let home = std::env::var("HOME").unwrap_or_default();
    PathBuf::from(home).join("Library/Group Containers").join(format!("{TEAM_ID}.{app_id}")).join("Disk")
}

/// Sealed files opened in Finder sit decrypted on this disk, so sealed
/// shares open only while the startup disk is encrypted.
pub fn filevault_on() -> bool {
    std::process::Command::new("/usr/bin/fdesetup")
        .arg("status")
        .output()
        .map(|o| String::from_utf8_lossy(&o.stdout).contains("FileVault is On"))
        .unwrap_or(false)
}

fn macos_15_or_later() -> bool {
    std::process::Command::new("/usr/bin/sw_vers")
        .arg("-productVersion")
        .output()
        .ok()
        .and_then(|o| String::from_utf8_lossy(&o.stdout).split('.').next().and_then(|m| m.trim().parse::<u32>().ok()))
        .is_some_and(|major| major >= 15)
}

fn app_id(app: &tauri::AppHandle) -> String {
    app.config().identifier.clone()
}

#[cfg(target_os = "macos")]
mod fp {
    //! Thin wrappers over NSFileProviderManager. Each waits for its
    //! completion handler, so call them off the main thread.
    use block2::RcBlock;
    use objc2::rc::Retained;
    use objc2::AllocAnyThread;
    use objc2_file_provider::{
        NSFileProviderDomain, NSFileProviderDomainRemovalMode, NSFileProviderManager, NSFileProviderManagerDisconnectionOptions,
        NSFileProviderRootContainerItemIdentifier, NSFileProviderWorkingSetContainerItemIdentifier,
    };
    use objc2_foundation::{NSArray, NSError, NSString, NSURL};
    use std::ptr::NonNull;
    use std::sync::mpsc;
    use std::time::Duration;

    const WAIT: Duration = Duration::from_secs(20);

    fn err(e: *mut NSError) -> Option<String> {
        // SAFETY: the handler hands us a valid NSError or null.
        unsafe { e.as_ref() }.map(|e| e.localizedDescription().to_string())
    }

    fn wait<T>(rx: mpsc::Receiver<T>) -> Result<T, String> {
        rx.recv_timeout(WAIT).map_err(|_| "Finder didn't answer. Try again.".to_string())
    }

    pub fn domains() -> Result<Vec<Retained<NSFileProviderDomain>>, String> {
        let (tx, rx) = mpsc::channel();
        let block = RcBlock::new(move |list: NonNull<NSArray<NSFileProviderDomain>>, e: *mut NSError| {
            // SAFETY: a valid array for the duration of the call.
            let list = unsafe { list.as_ref() };
            let _ = tx.send(match err(e) {
                Some(m) => Err(m),
                None => Ok(list.iter().collect::<Vec<_>>()),
            });
        });
        unsafe { NSFileProviderManager::getDomainsWithCompletionHandler(&block) };
        wait(rx)?
    }

    pub fn find(org: &str) -> Result<Option<Retained<NSFileProviderDomain>>, String> {
        Ok(domains()?.into_iter().find(|d| unsafe { d.identifier() }.to_string() == org))
    }

    pub fn add(org: &str, display: &str) -> Result<(), String> {
        let domain = unsafe {
            NSFileProviderDomain::initWithIdentifier_displayName(NSFileProviderDomain::alloc(), &NSString::from_str(org), &NSString::from_str(display))
        };
        let (tx, rx) = mpsc::channel();
        let block = RcBlock::new(move |e: *mut NSError| {
            let _ = tx.send(err(e));
        });
        unsafe { NSFileProviderManager::addDomain_completionHandler(&domain, &block) };
        wait(rx)?.map_or(Ok(()), Err)
    }

    /// Removes the location. Edits that didn't upload are moved to a folder
    /// macOS returns, never deleted.
    pub fn remove(domain: &NSFileProviderDomain) -> Result<Option<String>, String> {
        let (tx, rx) = mpsc::channel();
        let block = RcBlock::new(move |url: *mut NSURL, e: *mut NSError| {
            let kept = unsafe { url.as_ref() }.and_then(|u| u.path()).map(|p| p.to_string());
            let _ = tx.send(err(e).map_or(Ok(kept), Err));
        });
        unsafe {
            NSFileProviderManager::removeDomain_mode_completionHandler(domain, NSFileProviderDomainRemovalMode::PreserveDirtyUserData, &block)
        };
        wait(rx)?
    }

    fn manager(domain: &NSFileProviderDomain) -> Result<Retained<NSFileProviderManager>, String> {
        unsafe { NSFileProviderManager::managerForDomain(domain) }.ok_or_else(|| "no manager for the domain".to_string())
    }

    pub fn signal(domain: &NSFileProviderDomain) -> Result<(), String> {
        let (tx, rx) = mpsc::channel();
        let block = RcBlock::new(move |e: *mut NSError| {
            let _ = tx.send(err(e));
        });
        let m = manager(domain)?;
        unsafe { m.signalEnumeratorForContainerItemIdentifier_completionHandler(NSFileProviderWorkingSetContainerItemIdentifier, &block) };
        wait(rx)?.map_or(Ok(()), Err)
    }

    pub fn root_path(domain: &NSFileProviderDomain) -> Result<String, String> {
        let (tx, rx) = mpsc::channel();
        let block = RcBlock::new(move |url: *mut NSURL, e: *mut NSError| {
            let path = unsafe { url.as_ref() }.and_then(|u| u.path()).map(|p| p.to_string());
            let _ = tx.send(err(e).map_or_else(|| path.ok_or_else(|| "no path".to_string()), Err));
        });
        let m = manager(domain)?;
        unsafe { m.getUserVisibleURLForItemIdentifier_completionHandler(NSFileProviderRootContainerItemIdentifier, &block) };
        wait(rx)?
    }

    /// Removes and adds the location again: every downloaded copy goes (edits
    /// that didn't upload are kept), and macOS lists it afresh from the store.
    pub fn readd(domain: &NSFileProviderDomain) -> Result<(), String> {
        let id = unsafe { domain.identifier() }.to_string();
        let name = unsafe { domain.displayName() }.to_string();
        remove(domain)?;
        add(&id, &name)
    }

    pub fn set_paused(domain: &NSFileProviderDomain, paused: bool, reason: &str) -> Result<(), String> {
        let (tx, rx) = mpsc::channel();
        let block = RcBlock::new(move |e: *mut NSError| {
            let _ = tx.send(err(e));
        });
        let m = manager(domain)?;
        unsafe {
            if paused {
                m.disconnectWithReason_options_completionHandler(&NSString::from_str(reason), NSFileProviderManagerDisconnectionOptions(0), &block)
            } else {
                m.reconnectWithCompletionHandler(&block)
            }
        };
        wait(rx)?.map_or(Ok(()), Err)
    }

    pub fn user_enabled(domain: &NSFileProviderDomain) -> bool {
        unsafe { domain.userEnabled() }
    }

    pub fn disconnected(domain: &NSFileProviderDomain) -> bool {
        unsafe { domain.isDisconnected() }
    }
}

/// The Finder location's name: the product, then the team.
fn display_name(org_name: &str) -> String {
    format!("inbox2 ({org_name})")
}

#[cfg(target_os = "macos")]
fn status_inner(app: &tauri::AppHandle) -> Result<DiskFinderStatus, String> {
    let dir = group_dir(&app_id(app));
    let mut s = DiskFinderStatus { supported: macos_15_or_later(), filevault: filevault_on(), ..Default::default() };
    let Ok(cfg) = read_config(&dir) else { return Ok(s) };
    s.org = Some(cfg.org.clone());
    s.sealed_open = cfg.identity_secret.is_some();
    s.keep_downloaded = cfg.keep_downloaded;
    s.hidden_drives = cfg.hidden_drives.clone();
    s.upload_kbps = cfg.upload_kbps;
    s.download_kbps = cfg.download_kbps;
    if let Some(domain) = fp::find(&cfg.org)? {
        s.enabled = true;
        s.approved = fp::user_enabled(&domain);
        s.paused = fp::disconnected(&domain);
        s.path = fp::root_path(&domain).ok();
        s.local_bytes = s.path.as_deref().map(dir_size).unwrap_or(0);
    }
    if let Ok(engine) = DiskEngine::open(&dir) {
        let st = engine.status();
        s.items = st.items;
        s.uploading = st.uploading;
        s.last_sync_at = st.last_sync_at;
        s.last_error = st.last_error;
    }
    Ok(s)
}

/// Bytes on this Mac under the location (online-only files count 0).
#[cfg(target_os = "macos")]
fn dir_size(path: &str) -> u64 {
    use std::os::macos::fs::MetadataExt;
    fn walk(p: &std::path::Path) -> u64 {
        let Ok(rd) = std::fs::read_dir(p) else { return 0 };
        rd.flatten()
            .map(|e| match e.metadata() {
                Ok(m) if m.is_dir() => walk(&e.path()),
                // st_blocks: what the file really occupies; a dataless file is 0.
                Ok(m) => m.st_blocks() * 512,
                Err(_) => 0,
            })
            .sum()
    }
    walk(std::path::Path::new(path))
}

#[cfg(target_os = "macos")]
fn update_inner(app: &tauri::AppHandle, args: UpdateArgs) -> Result<(), String> {
    let dir = group_dir(&app_id(app));
    let mut cfg = read_config(&dir).map_err(|e| e.to_string())?;
    let before = cfg.clone();
    // An empty token is a sign-out: the extension answers "signed out" until
    // the next sign-in writes a new one.
    if let Some(t) = args.token {
        cfg.token = t;
    }
    match args.identity_secret.as_deref() {
        Some("") => {
            cfg.identity_secret = None;
            cfg.identity_public = None;
        }
        Some(_) if filevault_on() => {
            cfg.identity_secret = args.identity_secret;
            cfg.identity_public = args.identity_public;
        }
        _ => {}
    }
    if let Some(k) = args.keep_downloaded {
        cfg.keep_downloaded = k;
    }
    if let Some(h) = args.hidden_drives {
        cfg.hidden_drives = h;
    }
    if let Some(u) = args.upload_kbps {
        cfg.upload_kbps = u;
    }
    if let Some(d) = args.download_kbps {
        cfg.download_kbps = d;
    }
    write_config(&dir, &cfg).map_err(|e| e.to_string())?;
    // Drives shown or hidden, and the roots for "Keep on this Mac", are read again.
    let changed: Vec<String> = before
        .hidden_drives
        .iter()
        .chain(cfg.hidden_drives.iter())
        .filter(|d| before.hidden_drives.contains(d) != cfg.hidden_drives.contains(d))
        .cloned()
        .collect();
    let roots = before.keep_downloaded != cfg.keep_downloaded || !changed.is_empty();
    if let Ok(engine) = DiskEngine::open(&dir) {
        if !changed.is_empty() || roots {
            engine.settings_changed(&changed, roots).map_err(|e| e.to_string())?;
        }
        if before.identity_secret != cfg.identity_secret {
            if cfg.identity_secret.is_none() {
                drop_sealed(&engine, &cfg.org)?;
            } else {
                let _ = engine.reopen_sealed();
            }
        }
    }
    if let Some(domain) = fp::find(&cfg.org)? {
        let _ = fp::signal(&domain);
    }
    Ok(())
}

/// The key has left this Mac: lock sealed rows locally (no server needed),
/// then re-add the location so macOS drops every downloaded copy.
#[cfg(target_os = "macos")]
fn drop_sealed(engine: &DiskEngine, org: &str) -> Result<(), String> {
    engine.lock_sealed().map_err(|e| e.to_string())?;
    if let Some(domain) = fp::find(org)? {
        fp::readd(&domain)?;
    }
    Ok(())
}

/// One tick: FileVault check, then a nudge to pull.
#[cfg(target_os = "macos")]
fn tick(app_id: &str) {
    let dir = group_dir(app_id);
    let Ok(mut cfg) = read_config(&dir) else { return };
    let Ok(Some(domain)) = fp::find(&cfg.org) else { return };
    if cfg.identity_secret.is_some() && !filevault_on() {
        log::warn!("disk: FileVault is off; removing the sealed-share key and downloaded sealed files");
        cfg.identity_secret = None;
        cfg.identity_public = None;
        if write_config(&dir, &cfg).is_ok() {
            if let Err(e) = DiskEngine::open(&dir).map_err(|e| e.to_string()).and_then(|engine| drop_sealed(&engine, &cfg.org)) {
                log::error!("disk: could not clear sealed files: {e}");
            }
        }
    }
    let _ = fp::signal(&domain);
}

/// Starts the 30-second tick. Cheap when Disk in Finder is off.
pub fn start(app: &tauri::AppHandle) {
    #[cfg(target_os = "macos")]
    {
        let id = app_id(app);
        std::thread::Builder::new()
            .name("disk-finder".into())
            .spawn(move || loop {
                tick(&id);
                std::thread::sleep(std::time::Duration::from_secs(TICK_SECS));
            })
            .ok();
    }
    #[cfg(not(target_os = "macos"))]
    let _ = app;
}

/// Opens a `.page` file from Finder: its link goes to the browser, where Disk lives.
pub fn open_page_file(path: &std::path::Path) {
    let url = std::fs::read_to_string(path)
        .ok()
        .and_then(|raw| serde_json::from_str::<serde_json::Value>(&raw).ok())
        .and_then(|v| v["url"].as_str().map(str::to_string))
        .filter(|u| u.starts_with("https://") || u.starts_with("http://localhost"));
    match url {
        Some(u) => {
            let _ = std::process::Command::new("/usr/bin/open").arg(u).status();
        }
        None => log::warn!("disk: {} is not an inbox2 page", path.display()),
    }
}

// ── commands ─────────────────────────────────────────────────────────────

#[tauri::command]
pub async fn disk_finder_status(app: tauri::AppHandle) -> Result<DiskFinderStatus, String> {
    #[cfg(target_os = "macos")]
    return tauri::async_runtime::spawn_blocking(move || status_inner(&app)).await.map_err(|e| e.to_string())?;
    #[cfg(not(target_os = "macos"))]
    {
        let _ = app;
        Ok(DiskFinderStatus::default())
    }
}

#[tauri::command]
pub async fn disk_finder_enable(app: tauri::AppHandle, args: EnableArgs) -> Result<DiskFinderStatus, String> {
    #[cfg(target_os = "macos")]
    return tauri::async_runtime::spawn_blocking(move || {
        if !macos_15_or_later() {
            return Err("Disk in Finder needs macOS 15 or later.".to_string());
        }
        let dir = group_dir(&app_id(&app));
        // One org at a time: a different org replaces the location.
        if let Ok(old) = read_config(&dir) {
            if old.org != args.org {
                if let Some(d) = fp::find(&old.org)? {
                    fp::remove(&d)?;
                }
            }
        }
        let keep = read_config(&dir).ok().filter(|c| c.org == args.org && c.member_id == args.member_id);
        let sealed = filevault_on();
        let cfg = DiskConfig {
            api_base: args.api_base,
            web_base: args.web_base,
            org: args.org.clone(),
            member_id: args.member_id,
            token: args.token,
            member_name: args.member_name,
            identity_secret: args.identity_secret.filter(|_| sealed),
            identity_public: args.identity_public.filter(|_| sealed),
            keep_downloaded: keep.as_ref().is_some_and(|c| c.keep_downloaded),
            hidden_drives: keep.as_ref().map(|c| c.hidden_drives.clone()).unwrap_or_default(),
            upload_kbps: keep.as_ref().map_or(0, |c| c.upload_kbps),
            download_kbps: keep.as_ref().map_or(0, |c| c.download_kbps),
        };
        write_config(&dir, &cfg).map_err(|e| e.to_string())?;
        if fp::find(&args.org)?.is_none() {
            fp::add(&args.org, &display_name(&args.org_name))?;
        }
        if let Some(d) = fp::find(&args.org)? {
            let _ = fp::signal(&d);
        }
        status_inner(&app)
    })
    .await
    .map_err(|e| e.to_string())?;
    #[cfg(not(target_os = "macos"))]
    {
        let _ = (app, args);
        Err("Disk in Finder is only on macOS for now.".into())
    }
}

#[tauri::command]
pub async fn disk_finder_update(app: tauri::AppHandle, args: UpdateArgs) -> Result<DiskFinderStatus, String> {
    #[cfg(target_os = "macos")]
    return tauri::async_runtime::spawn_blocking(move || {
        update_inner(&app, args)?;
        status_inner(&app)
    })
    .await
    .map_err(|e| e.to_string())?;
    #[cfg(not(target_os = "macos"))]
    {
        let _ = (app, args);
        Ok(DiskFinderStatus::default())
    }
}

/// Removes the Finder location. Returns where macOS put edits that didn't
/// upload, if any.
#[tauri::command]
pub async fn disk_finder_disable(app: tauri::AppHandle) -> Result<Option<String>, String> {
    #[cfg(target_os = "macos")]
    return tauri::async_runtime::spawn_blocking(move || {
        let dir = group_dir(&app_id(&app));
        let mut kept = None;
        for d in fp::domains()? {
            kept = kept.or(fp::remove(&d)?);
        }
        let _ = std::fs::remove_dir_all(&dir);
        Ok(kept)
    })
    .await
    .map_err(|e| e.to_string())?;
    #[cfg(not(target_os = "macos"))]
    {
        let _ = app;
        Ok(None)
    }
}

#[tauri::command]
pub async fn disk_finder_pause(app: tauri::AppHandle, paused: bool, reason: String) -> Result<(), String> {
    #[cfg(target_os = "macos")]
    return tauri::async_runtime::spawn_blocking(move || {
        let cfg = read_config(&group_dir(&app_id(&app))).map_err(|e| e.to_string())?;
        let d = fp::find(&cfg.org)?.ok_or("Disk in Finder is off")?;
        fp::set_paused(&d, paused, &reason)
    })
    .await
    .map_err(|e| e.to_string())?;
    #[cfg(not(target_os = "macos"))]
    {
        let _ = (app, paused, reason);
        Ok(())
    }
}

#[tauri::command]
pub async fn disk_finder_open(app: tauri::AppHandle) -> Result<(), String> {
    #[cfg(target_os = "macos")]
    return tauri::async_runtime::spawn_blocking(move || {
        let cfg = read_config(&group_dir(&app_id(&app))).map_err(|e| e.to_string())?;
        let d = fp::find(&cfg.org)?.ok_or("Disk in Finder is off")?;
        let path = fp::root_path(&d)?;
        std::process::Command::new("/usr/bin/open").arg(path).status().map_err(|e| e.to_string())?;
        Ok(())
    })
    .await
    .map_err(|e| e.to_string())?;
    #[cfg(not(target_os = "macos"))]
    {
        let _ = app;
        Ok(())
    }
}

/// System Settings › General › Login Items & Extensions, where macOS asks
/// the member to allow the extension.
#[tauri::command]
pub async fn disk_finder_open_system_settings() -> Result<(), String> {
    std::process::Command::new("/usr/bin/open")
        .arg("x-apple.systempreferences:com.apple.LoginItems-Settings.extension")
        .status()
        .map_err(|e| e.to_string())?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn group_dir_is_team_prefixed() {
        let d = group_dir("com.inbox2.desktop");
        assert!(d.ends_with("Library/Group Containers/KF53B4S5HD.com.inbox2.desktop/Disk"));
    }

    #[test]
    fn location_name() {
        assert_eq!(display_name("Kunba Labs"), "inbox2 (Kunba Labs)");
    }
}
