//! UI sounds (new-mail ping, sent swoosh) on macOS.
//!
//! The webview's `<audio>` counts as media playback, so macOS's automatic
//! AirPods switching pulls the buds over to the Mac on every ping — away from
//! the iPhone that's playing music. System sounds (AudioToolbox) play on the
//! alert channel like macOS's own notification sounds and don't trigger the
//! switch. They follow the system alert volume, not a per-sound one.

/// Every sound in ui/web/src/lib/soundCatalog.js, keyed by its web path.
#[cfg(target_os = "macos")]
const SOUNDS: &[(&str, &[u8])] = &[
    ("/sounds/notification.mp3", include_bytes!("../../../web/public/sounds/notification.mp3")),
    ("/sounds/mixkit-unlock-game-notification.mp3", include_bytes!("../../../web/public/sounds/mixkit-unlock-game-notification.mp3")),
    ("/sounds/mixkit-epic-orchestra-transition.mp3", include_bytes!("../../../web/public/sounds/mixkit-epic-orchestra-transition.mp3")),
    ("/sounds/mixkit-mysterious-bass-pulse.mp3", include_bytes!("../../../web/public/sounds/mixkit-mysterious-bass-pulse.mp3")),
    ("/sounds/mixkit-trumpet-fanfare.mp3", include_bytes!("../../../web/public/sounds/mixkit-trumpet-fanfare.mp3")),
    ("/sounds/mixkit-vintage-telephone-ringtone.mp3", include_bytes!("../../../web/public/sounds/mixkit-vintage-telephone-ringtone.mp3")),
    ("/sounds/mixkit-air-woosh.mp3", include_bytes!("../../../web/public/sounds/mixkit-air-woosh.mp3")),
    ("/sounds/mixkit-melodical-flute-notification.mp3", include_bytes!("../../../web/public/sounds/mixkit-melodical-flute-notification.mp3")),
    ("/sounds/mixkit-martial-arts-fast-punch.mp3", include_bytes!("../../../web/public/sounds/mixkit-martial-arts-fast-punch.mp3")),
    ("/sounds/mixkit-technological-futuristic-hum.mp3", include_bytes!("../../../web/public/sounds/mixkit-technological-futuristic-hum.mp3")),
    ("/sounds/zone-chime.mp3", include_bytes!("../../../web/public/sounds/zone-chime.mp3")),
];

#[cfg(target_os = "macos")]
mod ffi {
    use std::ffi::c_void;

    #[link(name = "CoreFoundation", kind = "framework")]
    extern "C" {
        pub fn CFURLCreateFromFileSystemRepresentation(
            alloc: *const c_void,
            buf: *const u8,
            len: isize,
            is_dir: u8,
        ) -> *const c_void;
        pub fn CFRelease(cf: *const c_void);
    }

    #[link(name = "AudioToolbox", kind = "framework")]
    extern "C" {
        pub fn AudioServicesCreateSystemSoundID(url: *const c_void, out: *mut u32) -> i32;
        pub fn AudioServicesPlaySystemSound(id: u32);
    }
}

/// System sounds need a file on disk, so each sound is written to the temp dir
/// once and its SystemSoundID kept for the life of the process.
#[cfg(target_os = "macos")]
fn sound_id(file: &str) -> Result<u32, String> {
    use std::collections::HashMap;
    use std::sync::{Mutex, OnceLock};

    static IDS: OnceLock<Mutex<HashMap<String, u32>>> = OnceLock::new();
    let mut ids = IDS.get_or_init(Default::default).lock().map_err(|e| e.to_string())?;
    if let Some(id) = ids.get(file) {
        return Ok(*id);
    }

    let bytes = SOUNDS
        .iter()
        .find(|(k, _)| *k == file)
        .map(|(_, b)| *b)
        .ok_or_else(|| format!("unknown sound: {file}"))?;
    let name = file.rsplit('/').next().unwrap_or("sound.mp3");
    let path = std::env::temp_dir().join(format!("inbox2-{name}"));
    std::fs::write(&path, bytes).map_err(|e| e.to_string())?;

    let p = path.to_string_lossy();
    let mut id = 0u32;
    let status = unsafe {
        let url = ffi::CFURLCreateFromFileSystemRepresentation(
            std::ptr::null(),
            p.as_ptr(),
            p.len() as isize,
            0,
        );
        if url.is_null() {
            return Err("CFURL create failed".into());
        }
        let s = ffi::AudioServicesCreateSystemSoundID(url, &mut id);
        ffi::CFRelease(url);
        s
    };
    if status != 0 {
        return Err(format!("AudioServicesCreateSystemSoundID: {status}"));
    }
    ids.insert(file.to_string(), id);
    Ok(id)
}

/// Play a catalog sound (`file` = its web path, e.g. `/sounds/notification.mp3`).
/// macOS only; the frontend keeps `<audio>` on Windows/Linux.
#[tauri::command]
pub fn play_alert_sound(file: String) -> Result<(), String> {
    #[cfg(target_os = "macos")]
    {
        let id = sound_id(&file)?;
        unsafe { ffi::AudioServicesPlaySystemSound(id) };
        Ok(())
    }
    #[cfg(not(target_os = "macos"))]
    {
        let _ = file;
        Err("play_alert_sound is macOS-only".into())
    }
}
