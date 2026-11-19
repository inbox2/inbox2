//! Three-lane on-device model manager for the Bridge.
//!
//! Each Bridge capability (TTS / STT / NLU) has exactly three selectable **lanes**:
//! `native` (the OS engine — free, private, hidden when the device can't do it),
//! `free` (one downloadable open model — consistent quality on any modern device),
//! and `openai` (the user's own key, cloud). This module is the single source of
//! truth shared by every client: the embedded [`Manifest`], the pure
//! [availability](ModelManager::lanes) resolver, the pure [selection](effective_lane)
//! rule, and the on-demand [`download`](download::DownloadManager) machinery.
//!
//! The host (iOS/Android/desktop) supplies a [`DeviceProfile`] over FFI and owns the
//! per-capability preference + audio I/O + the inference engines. The manager only
//! decides *which* lane to run and guarantees a verified model directory on disk.

pub mod download;

use serde::Deserialize;
use std::path::{Path, PathBuf};
use std::sync::Arc;

use crate::sync::events::EventSink;

/// A Bridge capability.
#[derive(Clone, Copy, PartialEq, Eq, Debug, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum Capability {
    Tts,
    Stt,
    Nlu,
}

impl Capability {
    pub fn as_str(self) -> &'static str {
        match self {
            Capability::Tts => "tts",
            Capability::Stt => "stt",
            Capability::Nlu => "nlu",
        }
    }
    pub fn from_str(s: &str) -> Option<Self> {
        match s {
            "tts" => Some(Capability::Tts),
            "stt" => Some(Capability::Stt),
            "nlu" => Some(Capability::Nlu),
            _ => None,
        }
    }
}

/// Where a capability runs.
#[derive(Clone, Copy, PartialEq, Eq, Debug, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum Lane {
    Native,
    Free,
    Openai,
}

impl Lane {
    pub fn as_str(self) -> &'static str {
        match self {
            Lane::Native => "native",
            Lane::Free => "free",
            Lane::Openai => "openai",
        }
    }
    pub fn from_str(s: &str) -> Option<Self> {
        match s {
            "native" => Some(Lane::Native),
            "free" => Some(Lane::Free),
            "openai" => Some(Lane::Openai),
            _ => None,
        }
    }
}

/// The runtime engine that backs a lane (informational; the host picks the impl).
#[derive(Clone, Copy, PartialEq, Eq, Debug, Deserialize)]
#[serde(rename_all = "kebab-case")]
pub enum Engine {
    Native,
    SherpaOnnx,
    Whisperkit,
    Coreml,
    Litert,
    LlamaCpp,
    Openai,
}

/// One downloadable file of a free model.
#[derive(Clone, Debug, Deserialize)]
pub struct ModelFile {
    pub url: String,
    /// Hex sha256. Empty ⇒ unverified (provisional manifest entry; logs a warning).
    #[serde(default)]
    pub sha256: String,
    pub bytes: u64,
    /// Archive format to unpack after download, e.g. `tar.bz2` (sherpa-onnx bundles).
    /// `None` ⇒ the file is installed as-is. The single top-level directory the
    /// archive carries is stripped, so the install dir holds the model files directly.
    #[serde(default)]
    pub archive: Option<String>,
}

/// Native-lane availability gates. Ignored for `free`/`openai` lanes.
#[derive(Clone, Debug, Default, Deserialize)]
pub struct AvailabilityReqs {
    /// Minimum iOS major version (e.g. 26 for Apple Foundation Models).
    #[serde(default)]
    pub min_ios: Option<u32>,
    /// Requires Apple Intelligence hardware + opt-in.
    #[serde(default)]
    pub requires_apple_intelligence: bool,
    /// Android native engine must be present (e.g. an STT recognizer).
    #[serde(default)]
    pub android_native: bool,
}

/// One (capability × lane) manifest entry.
#[derive(Clone, Debug, Deserialize)]
pub struct ModelEntry {
    pub id: String,
    pub capability: Capability,
    pub lane: Lane,
    /// Informational in Rust (the hosts read it from the JSON to pick their
    /// runtime); kept so the embedded manifest's schema stays validated by the
    /// tests below.
    #[allow(dead_code)]
    pub engine: Engine,
    /// Empty for native/openai lanes.
    #[serde(default)]
    pub files: Vec<ModelFile>,
    #[serde(default)]
    pub total_bytes: u64,
    pub license: String,
    pub platforms: Vec<String>,
    #[serde(default)]
    pub availability_reqs: AvailabilityReqs,
    #[serde(default)]
    pub langs: Vec<String>,
    #[serde(default)]
    pub voices: Vec<String>,
}

/// The model catalog.
#[derive(Clone, Debug, Deserialize)]
pub struct Manifest {
    /// Schema version, for the planned remote-manifest override; unread until
    /// that lands.
    #[allow(dead_code)]
    pub version: u32,
    pub models: Vec<ModelEntry>,
}

/// The embedded manifest, shipped in the binary. Remotely overridable later by
/// caching a fetched copy under `<models_dir>/manifest.json`; for now this is the
/// single source.
const EMBEDDED_MANIFEST: &str = include_str!("models.json");

impl Manifest {
    /// Parse the embedded manifest. Panics only on a malformed embedded asset (a
    /// build-time error caught by the manifest test), never on user input.
    pub fn embedded() -> Manifest {
        serde_json::from_str(EMBEDDED_MANIFEST).expect("embedded models.json is valid")
    }

    pub fn entry(&self, cap: Capability, lane: Lane) -> Option<&ModelEntry> {
        self.models.iter().find(|m| m.capability == cap && m.lane == lane)
    }

    /// Platform-aware entry resolution: a (capability × lane) may ship different
    /// artifacts per platform (NLU free: the same Qwen checkpoint as a LiteRT
    /// `.task` on mobile, a GGUF for the desktop sidecar). Prefers the entry whose
    /// `platforms` carries `os`, falling back to the first entry for the pair (so
    /// an unconfigured "unknown" profile still resolves to something displayable).
    pub fn entry_for(&self, cap: Capability, lane: Lane, os: &str) -> Option<&ModelEntry> {
        self.models
            .iter()
            .find(|m| m.capability == cap && m.lane == lane && m.platforms.iter().any(|p| p == os))
            .or_else(|| self.entry(cap, lane))
    }

    /// Every entry for a (capability × lane) on `os`, in manifest order — the first
    /// is the default variant (NLU free: Qwen, then the alternate Gemma). Falls back
    /// to the unfiltered pair like [`entry_for`] so an "unknown" profile still
    /// resolves to something displayable.
    pub fn entries_for(&self, cap: Capability, lane: Lane, os: &str) -> Vec<&ModelEntry> {
        let platform: Vec<&ModelEntry> = self
            .models
            .iter()
            .filter(|m| m.capability == cap && m.lane == lane && m.platforms.iter().any(|p| p == os))
            .collect();
        if !platform.is_empty() {
            return platform;
        }
        self.entry(cap, lane).into_iter().collect()
    }

    pub fn by_id(&self, id: &str) -> Option<&ModelEntry> {
        self.models.iter().find(|m| m.id == id)
    }
}

/// The current device, supplied by the host once at launch.
#[derive(Clone, Debug)]
pub struct DeviceProfile {
    /// `ios` | `android` | `macos` | `windows` | `linux`.
    pub os: String,
    pub os_major: u32,
    pub os_minor: u32,
    pub apple_intelligence: bool,
    pub android_native_speech: bool,
}

impl Default for DeviceProfile {
    fn default() -> Self {
        // Conservative default before the host configures: a generic device with no
        // Apple Intelligence and no Android native speech.
        DeviceProfile {
            os: "unknown".into(),
            os_major: 0,
            os_minor: 0,
            apple_intelligence: false,
            android_native_speech: false,
        }
    }
}

/// One lane's status for a capability, rendered in the settings UI.
#[derive(Clone, Debug)]
pub struct LaneInfo {
    pub lane: Lane,
    pub id: String,
    pub available: bool,
    /// Human reason when `available == false` (e.g. "Needs iOS 26 + Apple Intelligence").
    pub reason: Option<String>,
    /// `installed` | `absent` | `downloading` (free lane only; native/openai are `n/a`).
    pub state: String,
    pub total_bytes: u64,
    pub license: String,
}

/// Selection outcome: the lane to route to, or a prompt to download the free model.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum Selected {
    Native,
    Free,
    Openai,
    /// Offline + no native lane + free not downloaded — the UI must prompt a download.
    NeedsDownload,
}

impl Selected {
    pub fn as_str(self) -> &'static str {
        match self {
            Selected::Native => "native",
            Selected::Free => "free",
            Selected::Openai => "openai",
            Selected::NeedsDownload => "needs-download",
        }
    }
}

/// Whether the native lane for `cap` runs on `device`, with a human reason when not.
/// Pure — unit-tested.
pub fn native_availability(
    manifest: &Manifest,
    cap: Capability,
    device: &DeviceProfile,
) -> (bool, Option<String>) {
    let entry = match manifest.entry(cap, Lane::Native) {
        Some(e) => e,
        None => return (false, Some("No native engine for this capability".into())),
    };
    if !entry.platforms.iter().any(|p| p == &device.os) {
        return (false, Some("Not supported on this platform".into()));
    }
    let reqs = &entry.availability_reqs;
    if let Some(min) = reqs.min_ios {
        if device.os == "ios" && device.os_major < min {
            // For the on-device LLM lane (Apple Foundation Models) the gate is really
            // "Apple Intelligence", which is the iOS 26 framework — say so, since the
            // Apple Intelligence *feature* predates the developer API.
            let reason = if reqs.requires_apple_intelligence {
                format!("On-Device needs Apple Intelligence (iOS {min}+)")
            } else {
                format!("On-Device needs iOS {min} or later")
            };
            return (false, Some(reason));
        }
    }
    if reqs.requires_apple_intelligence && !device.apple_intelligence {
        return (false, Some("On-Device needs Apple Intelligence — not available here (e.g. Simulator)".into()));
    }
    if reqs.android_native && device.os == "android" && !device.android_native_speech {
        return (false, Some("No on-device engine on this Android device".into()));
    }
    (true, None)
}

/// The default preference for a capability — native where available, except TTS
/// which defaults to the (downloadable) free Kokoro voice since native voices are
/// robotic. Used by the host to seed a first-run preference.
pub fn default_pref(cap: Capability) -> Lane {
    match cap {
        Capability::Tts => Lane::Free,
        Capability::Stt | Capability::Nlu => Lane::Native,
    }
}

/// The pure selection rule. `free_downloaded` is whether the free model for `cap`
/// is installed on disk. Mirrors the design doc exactly. Unit-tested.
pub fn effective_lane(
    manifest: &Manifest,
    cap: Capability,
    user_pref: Lane,
    device: &DeviceProfile,
    has_valid_key: bool,
    free_downloaded: bool,
) -> Selected {
    let native_ok = native_availability(manifest, cap, device).0;
    if user_pref == Lane::Openai && has_valid_key {
        return Selected::Openai;
    }
    if user_pref == Lane::Native && native_ok {
        return Selected::Native;
    }
    if free_downloaded {
        return Selected::Free;
    }
    if native_ok {
        return Selected::Native;
    }
    Selected::NeedsDownload
}

/// The model manager: the manifest, the on-disk model store, the host device
/// profile, and the download machinery. Held by the FFI `InboxEngine`.
pub struct ModelManager {
    manifest: Manifest,
    downloads: download::DownloadManager,
    device: parking_lot::RwLock<DeviceProfile>,
}

impl ModelManager {
    /// Build over the data directory's `models/` subdir. Events (`model-download`)
    /// are emitted through `sink` — the same bus the host already consumes.
    pub fn new(data_dir: &Path, sink: Arc<dyn EventSink>) -> Self {
        let models_dir = data_dir.join("models");
        ModelManager {
            manifest: Manifest::embedded(),
            downloads: download::DownloadManager::new(models_dir, sink),
            device: parking_lot::RwLock::new(DeviceProfile::default()),
        }
    }

    /// Host sets the device profile once at launch (drives native-lane availability).
    pub fn set_device_profile(&self, profile: DeviceProfile) {
        *self.device.write() = profile;
    }

    /// Host provides (or clears) the HuggingFace token used for gated model downloads.
    pub fn set_hf_token(&self, token: Option<String>) {
        self.downloads.set_hf_token(token);
    }

    /// Whether the free lane for `cap` is usable: ANY of its variants is fully
    /// installed on disk (NLU free ships Qwen + the alternate Gemma — the host
    /// runs whichever the user picked, so either satisfies the lane).
    pub fn free_downloaded(&self, cap: Capability) -> bool {
        let os = self.device.read().os.clone();
        self.manifest
            .entries_for(cap, Lane::Free, &os)
            .iter()
            .any(|e| self.downloads.is_installed(e))
    }

    /// The three lanes for `cap`, with availability + state, for the settings UI.
    pub fn lanes(&self, cap: Capability, has_valid_key: bool) -> Vec<LaneInfo> {
        let device = self.device.read();
        let mut out = Vec::new();
        for lane in [Lane::Native, Lane::Free, Lane::Openai] {
            // The free lane can have several variants: surface the installed one
            // (else a downloading one, else the default) so the row reflects what
            // the lane would actually run.
            let entry = if lane == Lane::Free {
                let variants = self.manifest.entries_for(cap, lane, &device.os);
                variants
                    .iter()
                    .find(|e| self.downloads.is_installed(e))
                    .or_else(|| variants.iter().find(|e| self.downloads.is_downloading(&e.id)))
                    .copied()
                    .or_else(|| variants.first().copied())
            } else {
                self.manifest.entry_for(cap, lane, &device.os)
            };
            let entry = match entry {
                Some(e) => e,
                None => continue,
            };
            let (available, reason, state) = match lane {
                Lane::Native => {
                    let (ok, why) = native_availability(&self.manifest, cap, &device);
                    (ok, why, "n/a".to_string())
                }
                Lane::Free => {
                    let supported = entry.platforms.iter().any(|p| p == &device.os);
                    let reason = if supported {
                        None
                    } else {
                        Some("Not supported on this platform".into())
                    };
                    let state = if self.downloads.is_installed(entry) {
                        "installed"
                    } else if self.downloads.is_downloading(&entry.id) {
                        "downloading"
                    } else {
                        "absent"
                    };
                    (supported, reason, state.to_string())
                }
                Lane::Openai => {
                    let reason = if has_valid_key {
                        None
                    } else {
                        Some("Add a validated OpenAI key".into())
                    };
                    (has_valid_key, reason, "n/a".to_string())
                }
            };
            out.push(LaneInfo {
                lane,
                id: entry.id.clone(),
                available,
                reason,
                state,
                total_bytes: entry.total_bytes,
                license: entry.license.clone(),
            });
        }
        out
    }

    /// Every free-lane variant for `cap` on this device, in manifest order (the
    /// first is the default), each with its install state — drives the variant
    /// picker UIs (NLU free: Qwen vs the smaller/faster Gemma).
    pub fn free_variants(&self, cap: Capability) -> Vec<LaneInfo> {
        let device = self.device.read();
        self.manifest
            .entries_for(cap, Lane::Free, &device.os)
            .into_iter()
            .map(|entry| {
                let state = if self.downloads.is_installed(entry) {
                    "installed"
                } else if self.downloads.is_downloading(&entry.id) {
                    "downloading"
                } else {
                    "absent"
                };
                LaneInfo {
                    lane: Lane::Free,
                    id: entry.id.clone(),
                    available: true,
                    reason: None,
                    state: state.to_string(),
                    total_bytes: entry.total_bytes,
                    license: entry.license.clone(),
                }
            })
            .collect()
    }

    /// Resolve the lane to route to for `cap` given the host's preference.
    pub fn effective_lane(&self, cap: Capability, user_pref: Lane, has_valid_key: bool) -> Selected {
        let device = self.device.read();
        effective_lane(
            &self.manifest,
            cap,
            user_pref,
            &device,
            has_valid_key,
            self.free_downloaded(cap),
        )
    }

    /// Start (or resume) downloading a free model by id. Returns the entry's files to
    /// fetch; the caller spawns [`DownloadManager::run`] on its runtime so the call
    /// returns immediately and progress flows over the event bus.
    pub fn entry_for_download(&self, id: &str) -> Result<ModelEntry, String> {
        let entry = self
            .manifest
            .by_id(id)
            .ok_or_else(|| format!("unknown model: {id}"))?;
        if entry.lane != Lane::Free {
            return Err(format!("{id} is not a downloadable model"));
        }
        if entry.files.is_empty() {
            // e.g. WhisperKit — the engine fetches + caches its own model.
            return Err(format!("{id} is managed by its engine, not the download manager"));
        }
        Ok(entry.clone())
    }

    pub fn downloads(&self) -> &download::DownloadManager {
        &self.downloads
    }

    /// Delete a downloaded free model, reclaiming its disk.
    pub fn delete(&self, id: &str) -> Result<(), String> {
        let entry = self
            .manifest
            .by_id(id)
            .ok_or_else(|| format!("unknown model: {id}"))?;
        self.downloads.delete(entry)
    }

    /// The verified on-disk directory for a model, for the native inference engine.
    pub fn path(&self, id: &str) -> Option<PathBuf> {
        let entry = self.manifest.by_id(id)?;
        if self.downloads.is_installed(entry) {
            Some(self.downloads.install_dir(&entry.id))
        } else {
            None
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn ios26_ai() -> DeviceProfile {
        DeviceProfile {
            os: "ios".into(),
            os_major: 26,
            os_minor: 0,
            apple_intelligence: true,
            android_native_speech: false,
        }
    }
    fn ios17_no_ai() -> DeviceProfile {
        DeviceProfile {
            os: "ios".into(),
            os_major: 17,
            os_minor: 0,
            apple_intelligence: false,
            android_native_speech: false,
        }
    }
    fn android() -> DeviceProfile {
        DeviceProfile {
            os: "android".into(),
            os_major: 14,
            os_minor: 0,
            apple_intelligence: false,
            android_native_speech: true,
        }
    }

    #[test]
    fn embedded_manifest_parses_and_is_complete() {
        let m = Manifest::embedded();
        // Every capability ships a native + openai lane. Stt has no free lane —
        // WhisperKit was dropped for SpeechAnalyzer/native (see dd0dc228) — so the
        // free lane is asserted only where one is actually shipped.
        for cap in [Capability::Tts, Capability::Stt, Capability::Nlu] {
            for lane in [Lane::Native, Lane::Openai] {
                assert!(
                    m.entry(cap, lane).is_some(),
                    "missing {cap:?}/{lane:?} in manifest"
                );
            }
        }
        for cap in [Capability::Tts, Capability::Nlu] {
            assert!(
                m.entry(cap, Lane::Free).is_some(),
                "missing {cap:?}/Free in manifest"
            );
        }
        assert!(
            m.entry(Capability::Stt, Lane::Free).is_none(),
            "an stt/free lane reappeared — assert its files below before shipping it"
        );
        // Free entries carry files; native/openai must not.
        for e in &m.models {
            match e.lane {
                Lane::Free => assert!(!e.files.is_empty(), "free {} has no files", e.id),
                _ => assert!(e.files.is_empty(), "non-free {} has files", e.id),
            }
        }
    }

    #[test]
    fn nlu_free_resolves_per_platform_to_the_same_checkpoint() {
        let m = Manifest::embedded();
        // Mobile gets the LiteRT .task bundle; desktop gets the GGUF for the
        // llama-server sidecar — both the same Qwen2.5-1.5B-Instruct weights.
        let ios = m.entry_for(Capability::Nlu, Lane::Free, "ios").unwrap();
        assert_eq!(ios.engine, Engine::Litert);
        assert!(ios.id.starts_with("qwen2.5-1.5b-instruct"));
        let android = m.entry_for(Capability::Nlu, Lane::Free, "android").unwrap();
        assert_eq!(android.id, ios.id);
        for os in ["macos", "windows", "linux"] {
            let e = m.entry_for(Capability::Nlu, Lane::Free, os).unwrap();
            assert_eq!(e.engine, Engine::LlamaCpp, "{os} should get the GGUF entry");
            assert!(e.id.starts_with("qwen2.5-1.5b-instruct"));
        }
        // The DEFAULT free entry (first per platform) must stay ungated so the
        // out-of-the-box download works anonymously — gated variants (Gemma) may
        // only be alternates the user opts into.
        for os in ["ios", "android", "macos", "windows", "linux"] {
            let default = m.entry_for(Capability::Nlu, Lane::Free, os).unwrap();
            assert_ne!(default.license, "Gemma", "{os}: gated model is the default");
        }
    }

    #[test]
    fn nlu_free_carries_a_gemma_variant_per_platform() {
        let m = Manifest::embedded();
        // Every platform has exactly two NLU free variants: Qwen (default, first)
        // then the smaller/faster Gemma 3 1B alternate.
        for os in ["ios", "android"] {
            let variants = m.entries_for(Capability::Nlu, Lane::Free, os);
            assert_eq!(variants.len(), 2, "{os} variant count");
            assert!(variants[0].id.starts_with("qwen2.5-1.5b-instruct"));
            assert_eq!(variants[1].id, "gemma3-1b-it-int4");
            assert_eq!(variants[1].engine, Engine::Litert);
        }
        for os in ["macos", "windows", "linux"] {
            let variants = m.entries_for(Capability::Nlu, Lane::Free, os);
            assert_eq!(variants.len(), 2, "{os} variant count");
            assert!(variants[0].id.starts_with("qwen2.5-1.5b-instruct"));
            assert_eq!(variants[1].id, "gemma3-1b-it-gguf");
            assert_eq!(variants[1].engine, Engine::LlamaCpp);
        }
    }

    #[test]
    fn tts_native_available_everywhere_apple() {
        let m = Manifest::embedded();
        assert!(native_availability(&m, Capability::Tts, &ios17_no_ai()).0);
        // Android has no Apple AVSpeech entry → native unavailable for our manifest.
        assert!(!native_availability(&m, Capability::Tts, &android()).0);
    }

    #[test]
    fn nlu_native_needs_ios26_and_apple_intelligence() {
        let m = Manifest::embedded();
        assert!(native_availability(&m, Capability::Nlu, &ios26_ai()).0);
        let (ok, why) = native_availability(&m, Capability::Nlu, &ios17_no_ai());
        assert!(!ok);
        assert!(why.unwrap().contains("iOS 26"));
        // Android has no native NLU entry at all → unavailable.
        assert!(!native_availability(&m, Capability::Nlu, &android()).0);
    }

    #[test]
    fn selection_openai_wins_only_with_key() {
        let m = Manifest::embedded();
        let d = ios26_ai();
        assert_eq!(
            effective_lane(&m, Capability::Tts, Lane::Openai, &d, true, false),
            Selected::Openai
        );
        // No key → falls through; pref openai, not native → free not downloaded → native.
        assert_eq!(
            effective_lane(&m, Capability::Tts, Lane::Openai, &d, false, false),
            Selected::Native
        );
    }

    #[test]
    fn selection_native_pref_falls_to_free_then_needs_download() {
        let m = Manifest::embedded();
        // Older iPhone, NLU native unavailable, pref native, free not downloaded,
        // no native → needs download.
        assert_eq!(
            effective_lane(&m, Capability::Nlu, Lane::Native, &ios17_no_ai(), false, false),
            Selected::NeedsDownload
        );
        // Same, but free downloaded → free.
        assert_eq!(
            effective_lane(&m, Capability::Nlu, Lane::Native, &ios17_no_ai(), false, true),
            Selected::Free
        );
    }

    #[test]
    fn tts_default_pref_is_free() {
        assert_eq!(default_pref(Capability::Tts), Lane::Free);
        assert_eq!(default_pref(Capability::Stt), Lane::Native);
        assert_eq!(default_pref(Capability::Nlu), Lane::Native);
    }

    #[test]
    fn tts_free_default_falls_back_to_native_until_downloaded() {
        let m = Manifest::embedded();
        // TTS default pref = free, not yet downloaded, native (Apple) available →
        // speaks offline via native; UI nudges the download separately.
        assert_eq!(
            effective_lane(&m, Capability::Tts, Lane::Free, &ios17_no_ai(), false, false),
            Selected::Native
        );
        assert_eq!(
            effective_lane(&m, Capability::Tts, Lane::Free, &ios17_no_ai(), false, true),
            Selected::Free
        );
    }
}
