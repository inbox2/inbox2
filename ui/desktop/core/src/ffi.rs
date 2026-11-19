//! The UniFFI surface for the native iOS / Android apps.
//!
//! A thin, host-agnostic facade over [`SyncEngine`]: the native app constructs an
//! [`InboxEngine`] with a data directory and an [`EngineEventListener`] callback,
//! and drives sync / actions through it. Events the engine emits (the `sync`
//! lifecycle backbone, `new-message`, `calendar-changed`) flow back to the
//! listener as `(event, payload_json)` pairs — the same shape the desktop webview
//! and the IPC bus already consume, so the contract is identical across hosts.
//!
//! This module is compiled only under the `mobile-ffi` feature, so the desktop
//! (Tauri) build never pulls UniFFI.
//!
//! Methods are synchronous-blocking over an owned tokio runtime: the native side
//! calls them off the main thread. (A later iteration can switch hot paths to
//! UniFFI async once the call patterns settle.)

use std::path::PathBuf;
use std::sync::Arc;

use crate::bridge::models::{self, Capability, DeviceProfile, Lane, ModelManager};
use crate::bridge::{agent, prompts, tools, LocalGenerator};
use crate::sync::engine::SyncEngine;
use crate::sync::error::SyncError;
use crate::sync::events::EventSink;
use crate::sync::interactive::{OutgoingAttachment, OutgoingMessage};
use crate::sync::model::{AccountStatus, AuthMethod, ExternalAccount, MetaCredentials, ProviderCredentials, ProviderType};
use crate::sync::store::SyncStore;
use async_trait::async_trait;

/// Route the core's `log::*` output to the unified logging system (Console.app /
/// `log stream`) under subsystem `com.inbox2.core`, so engine internals
/// (connect / sync / send / write-back) are debuggable on-site. Idempotent.
fn init_logging() {
    use std::sync::Once;
    static INIT: Once = Once::new();
    INIT.call_once(|| {
        #[cfg(any(target_os = "ios", target_os = "macos"))]
        {
            let _ = oslog::OsLogger::new("com.inbox2.core")
                .level_filter(log::LevelFilter::Info)
                // ammonia's HTML sanitizing pulls in html5ever, which spams
                // unactionable "foster parenting not implemented" WARNs on email
                // with tables/malformed markup. Mute that target.
                .category_level_filter("html5ever::tree_builder", log::LevelFilter::Off)
                .init();
        }
        // Android's analog: route `log::*` to logcat under the `com.inbox2.core`
        // tag (filter with `adb logcat -s com.inbox2.core`).
        #[cfg(target_os = "android")]
        {
            android_logger::init_once(
                android_logger::Config::default()
                    .with_max_level(log::LevelFilter::Info)
                    // Mute html5ever's "foster parenting not implemented" WARN
                    // flood (via ammonia HTML sanitizing) while keeping Info for
                    // everything else.
                    .with_filter(
                        android_logger::FilterBuilder::new()
                            .parse("info,html5ever=off")
                            .build(),
                    )
                    .with_tag("com.inbox2.core"),
            );
        }
    });
}

/// An outgoing attachment passed across the FFI (filename + bytes).
#[derive(uniffi::Record)]
pub struct FfiAttachment {
    pub filename: String,
    pub mime_type: Option<String>,
    pub data: Vec<u8>,
}

/// Callback the native app implements to receive engine events. Each event is the
/// bus event name (e.g. `"sync"`, `"new-message"`, `"calendar-changed"`) plus its
/// JSON payload as a string — the native side decodes what it needs.
#[uniffi::export(callback_interface)]
pub trait EngineEventListener: Send + Sync {
    fn on_event(&self, event: String, payload_json: String);
}

/// Bridges engine events to the native [`EngineEventListener`].
struct ListenerSink {
    listener: Box<dyn EngineEventListener>,
}

impl EventSink for ListenerSink {
    fn emit(&self, event: &str, payload: serde_json::Value) {
        self.listener.on_event(event.to_string(), payload.to_string());
    }
}

/// Errors surfaced across the FFI boundary.
#[derive(Debug, thiserror::Error, uniffi::Error)]
pub enum FfiError {
    #[error("{0}")]
    Engine(String),
}

impl From<SyncError> for FfiError {
    fn from(e: SyncError) -> Self {
        FfiError::Engine(e.to_string())
    }
}

impl From<serde_json::Error> for FfiError {
    fn from(e: serde_json::Error) -> Self {
        FfiError::Engine(e.to_string())
    }
}

impl From<std::io::Error> for FfiError {
    fn from(e: std::io::Error) -> Self {
        FfiError::Engine(e.to_string())
    }
}

/// On-device text generation the native app provides (Apple Foundation Models on
/// iOS). Sync across the FFI — the Swift impl blocks on its async model call.
/// Adapted to the core's async [`LocalGenerator`] seam.
#[uniffi::export(callback_interface)]
pub trait OnDeviceLlm: Send + Sync {
    fn is_available(&self) -> bool;
    /// `model` is the engine to run (`FfiBridgeConfig::on_device_model` — a manifest
    /// model id, or `apple-fm` for the OS model); `None` routes by the host's own
    /// preference. Forced runs (the reader's "Process with") rely on it being honored.
    fn generate(&self, system: String, user: String, model: Option<String>) -> Result<String, FfiError>;
    /// Structured intent JSON (see `bridge::intent`). Hosts back this with guided
    /// generation on Apple Foundation Models (`@Generable`) for schema-valid output;
    /// other on-device engines (e.g. Qwen via LiteRT) just run plain text-JSON generation.
    fn generate_intent(&self, system: String, user: String, model: Option<String>) -> Result<String, FfiError>;
}

struct LlmAdapter {
    inner: Arc<dyn OnDeviceLlm>,
}

#[async_trait]
impl LocalGenerator for LlmAdapter {
    async fn is_available(&self) -> bool {
        self.inner.is_available()
    }
    async fn generate(&self, system: String, user: String, model: Option<String>) -> Result<String, String> {
        // The Swift callback blocks for the whole model call. Run it on the blocking
        // pool, not the async executor — otherwise it pins a runtime worker thread and
        // a `tokio::time::timeout` around this call (the triage worker's per-job bound)
        // can never fire, since the timer branch can't be polled while the task is stuck
        // inline. Off-thread, a hung generation frees the drain to time out and move on.
        let inner = self.inner.clone();
        tokio::task::spawn_blocking(move || inner.generate(system, user, model))
            .await
            .map_err(|e| format!("on-device generation task failed: {e}"))?
            .map_err(|e| e.to_string())
    }
    async fn generate_intent(&self, system: String, user: String, model: Option<String>) -> Result<String, String> {
        let inner = self.inner.clone();
        tokio::task::spawn_blocking(move || inner.generate_intent(system, user, model))
            .await
            .map_err(|e| format!("on-device generation task failed: {e}"))?
            .map_err(|e| e.to_string())
    }
}

/// Host config for a Bridge call. `generation` is "openai" or "apple".
/// `on_device_model` is the engine the host's on-device generator runs (a manifest
/// model id, or `apple-fm` for the OS model) — handed back to the `OnDeviceLlm`
/// callback per call and recorded as triage provenance (`triage_source`).
#[derive(uniffi::Record)]
pub struct FfiBridgeConfig {
    pub generation: String,
    pub openai_key: Option<String>,
    pub model: Option<String>,
    pub on_device_model: Option<String>,
    /// Non-car ("normal") mode: speak a terse headline brief instead of the full
    /// rundown. Applies to the daily brief only; ignored by other Bridge calls.
    pub concise: bool,
    /// Short current-weather line to append to the END of a MORNING brief (e.g.
    /// "Currently 14°C and cloudy in Amsterdam."). `None`/empty appends nothing; the
    /// core only appends it when the brief's window is morning.
    pub weather: Option<String>,
}

impl FfiBridgeConfig {
    fn into_core(self) -> agent::BridgeConfig {
        let generation = if self.generation == "openai" {
            agent::GenSource::OpenAi
        } else {
            agent::GenSource::OnDevice
        };
        agent::BridgeConfig {
            generation,
            openai_key: self.openai_key,
            model: self.model.unwrap_or_else(prompts::openai_chat_model),
            on_device_model: self.on_device_model,
            concise: self.concise,
            weather: self.weather.filter(|w| !w.trim().is_empty()),
        }
    }
}

/// A Bridge reply: spoken `text`, or an `openai_error` to surface with guidance.
#[derive(uniffi::Record)]
pub struct FfiBridgeReply {
    pub text: String,
    pub openai_error: Option<String>,
}

impl From<agent::Outcome> for FfiBridgeReply {
    fn from(o: agent::Outcome) -> Self {
        match o {
            agent::Outcome::Ok(text) => FfiBridgeReply { text, openai_error: None },
            agent::Outcome::OpenAiError(e) => FfiBridgeReply { text: String::new(), openai_error: Some(e) },
        }
    }
}

/// The result of a voice command. `spoken` is always what to say; `kind` tells the host
/// what to do — `speak`/`clarify` just speak, while `draft_email`/`draft_event` carry a
/// `payload_json` of draft slots the host opens on screen (never sent/saved). The Bridge
/// never commits — the user taps Send / Add.
#[derive(uniffi::Record)]
pub struct FfiBridgeAction {
    pub spoken: String,
    pub kind: String,
    pub payload_json: Option<String>,
    pub openai_error: Option<String>,
}

impl From<agent::CommandOutcome> for FfiBridgeAction {
    fn from(o: agent::CommandOutcome) -> Self {
        use agent::CommandOutcome as C;
        let mk = |spoken: String, kind: &str, payload: Option<String>, err: Option<String>| FfiBridgeAction {
            spoken,
            kind: kind.to_string(),
            payload_json: payload,
            openai_error: err,
        };
        match o {
            C::Speak(t) => mk(t, "speak", None, None),
            C::Clarify(t) => mk(t, "clarify", None, None),
            C::DraftEmail { spoken, payload } => mk(spoken, "draft_email", Some(payload.to_string()), None),
            C::DraftEvent { spoken, payload } => mk(spoken, "draft_event", Some(payload.to_string()), None),
            C::OpenAiError(e) => mk(String::new(), "speak", None, Some(e)),
        }
    }
}

/// The device the host runs on, used to resolve which native model lanes exist.
/// `os` is `ios` | `android` | `macos` | `windows` | `linux`.
#[derive(uniffi::Record)]
pub struct FfiDeviceProfile {
    pub os: String,
    pub os_major: u32,
    pub os_minor: u32,
    pub apple_intelligence: bool,
    pub android_native_speech: bool,
}

impl From<FfiDeviceProfile> for DeviceProfile {
    fn from(p: FfiDeviceProfile) -> Self {
        DeviceProfile {
            os: p.os,
            os_major: p.os_major,
            os_minor: p.os_minor,
            apple_intelligence: p.apple_intelligence,
            android_native_speech: p.android_native_speech,
        }
    }
}

/// One lane's status for a capability, for the three-lane settings picker. `lane`
/// is `native` | `free` | `openai`; `state` is `installed` | `absent` |
/// One editable section of the prompt template file. `key` is the TOML table
/// name (`chat`, `brief`, …, `openai`); `text` is the section's system prompt —
/// except `openai`, where it is the chat model name.
#[derive(uniffi::Record)]
pub struct FfiPromptSection {
    pub key: String,
    pub text: String,
}

/// `downloading` | `n/a` (native/openai carry no download state).
#[derive(uniffi::Record)]
pub struct FfiLaneInfo {
    pub lane: String,
    pub id: String,
    pub available: bool,
    pub reason: Option<String>,
    pub state: String,
    pub total_bytes: u64,
    pub license: String,
}

impl From<models::LaneInfo> for FfiLaneInfo {
    fn from(l: models::LaneInfo) -> Self {
        FfiLaneInfo {
            lane: l.lane.as_str().to_string(),
            id: l.id,
            available: l.available,
            reason: l.reason,
            state: l.state,
            total_bytes: l.total_bytes,
            license: l.license,
        }
    }
}

/// The mobile entry point. Owns the sync engine and the runtime its background
/// loops run on.
#[derive(uniffi::Object)]
pub struct InboxEngine {
    engine: Arc<SyncEngine>,
    rt: tokio::runtime::Runtime,
    local: Option<Arc<dyn LocalGenerator>>,
    models: Arc<ModelManager>,
}

/// What one [`InboxEngine::mx_sync`] pass did.
#[derive(uniffi::Record)]
pub struct FfiMxReport {
    pub pulled: u32,
    pub deleted: u32,
    pub backfilled: u32,
    pub hydrated: u32,
    pub removed: u32,
    pub backfill_done: bool,
    /// History, hydration or an undrained delta is still queued: call again.
    pub more: bool,
}

/// One E2EE domain keypair, base64.
#[derive(uniffi::Record)]
pub struct FfiDomainKey {
    pub version: i64,
    pub public_key: String,
    pub secret_key: String,
}

#[uniffi::export]
impl InboxEngine {
    /// Open the local store under `data_dir`, start the engine (poll loop +
    /// write-back drain) and boot every stored account. Events flow to `listener`.
    #[uniffi::constructor]
    pub fn new(
        data_dir: String,
        listener: Box<dyn EngineEventListener>,
        llm: Option<Box<dyn OnDeviceLlm>>,
        cloud_api_base: Option<String>,
    ) -> Result<Arc<Self>, FfiError> {
        init_logging();
        let rt = tokio::runtime::Builder::new_multi_thread()
            .enable_all()
            .build()?;

        let dir = PathBuf::from(&data_dir);
        let store = Arc::new(SyncStore::new(&dir.join("inbox2.db"), &dir)?);
        let sink: Arc<dyn EventSink> = Arc::new(ListenerSink { listener });
        // The model manager shares the host's event bus (for `model-download`
        // progress) and the data dir's `models/` subtree.
        let models = Arc::new(ModelManager::new(&dir, sink.clone()));
        let engine = Arc::new(SyncEngine::new(store, sink));
        // OAuth client credentials (env or baked in at build) let token refresh
        // go directly to the provider; mobile stores seeded from a desktop dump
        // already carry them, so this is usually a no-op here.
        engine.load_oauth_clients_from_env();

        // The device's reachable Rails base overrides the one seeded from a desktop
        // dump (a dev `localhost` URL the phone can't reach). Apply it *before*
        // booting accounts, or the first token refresh races against the stale base.
        if let Some(base) = cloud_api_base {
            rt.block_on(engine.override_api_base(base));
        }

        // The on-device generator (Apple FM / Qwen) is shared by the Bridge and
        // the background triage worker. Inject it into the engine so the worker
        // can reach it, and keep a handle for the synchronous Bridge calls.
        let local: Option<Arc<dyn LocalGenerator>> =
            llm.map(|l| Arc::new(LlmAdapter { inner: Arc::from(l) }) as Arc<dyn LocalGenerator>);
        if let Some(gen) = local.clone() {
            engine.set_generator(gen);
        }

        // Background poll loop + write-back drain.
        let run_engine = engine.clone();
        rt.spawn(async move {
            if let Err(e) = run_engine.run().await {
                log::error!("[ffi] engine run loop exited: {e}");
            }
        });
        // Connect every stored account.
        let boot_engine = engine.clone();
        rt.spawn(async move {
            boot_engine.boot_all_accounts().await;
        });
        // Background triage + multi-level summary worker. Idles until the host
        // pushes the AI config via `set_ai_config`.
        let triage_engine = engine.clone();
        rt.spawn(async move {
            crate::ai_worker::TriageWorker::new(triage_engine).run().await;
        });

        Ok(Arc::new(Self { engine, rt, local, models }))
    }

    // ---- Bridge: shared brief + agent (generation routed per `config`) ----

    /// Generate the spoken daily brief.
    pub fn bridge_brief(&self, config: FfiBridgeConfig) -> Result<FfiBridgeReply, FfiError> {
        let cfg = config.into_core();
        let outcome = self
            .rt
            .block_on(agent::brief_text(&self.engine, self.local.as_ref(), &cfg));
        Ok(outcome.into())
    }

    /// Pre-compose the daily brief into the engine cache (no announcement side effects)
    /// so the next `bridge_brief` speaks instantly. Call on a timer while the app is
    /// active; cheap when nothing changed (skips the compose if already warm).
    pub fn bridge_brief_prewarm(&self, config: FfiBridgeConfig) {
        let cfg = config.into_core();
        self.rt
            .block_on(agent::brief_prewarm(&self.engine, self.local.as_ref(), &cfg));
    }

    /// Generate tomorrow's spoken calendar preview.
    pub fn bridge_tomorrow(&self, config: FfiBridgeConfig) -> Result<FfiBridgeReply, FfiError> {
        let cfg = config.into_core();
        let outcome = self
            .rt
            .block_on(agent::tomorrow_text(&self.engine, self.local.as_ref(), &cfg));
        Ok(outcome.into())
    }

    /// Generate the spoken "highlights of the week" rundown.
    pub fn bridge_week_highlights(&self, config: FfiBridgeConfig) -> Result<FfiBridgeReply, FfiError> {
        let cfg = config.into_core();
        let outcome = self
            .rt
            .block_on(agent::week_highlights_text(&self.engine, self.local.as_ref(), &cfg));
        Ok(outcome.into())
    }

    /// Conversational reply to a voice command (no tool execution).
    pub fn bridge_reply(&self, config: FfiBridgeConfig, transcript: String) -> Result<FfiBridgeReply, FfiError> {
        let cfg = config.into_core();
        let outcome = self
            .rt
            .block_on(agent::reply_text(self.local.as_ref(), &cfg, &transcript));
        Ok(outcome.into())
    }

    /// Interpret a voice command into one confidence-scored intent and act: speak an
    /// answer, ask to clarify, or return a DRAFT (email / event) for the host to put on
    /// screen. NEVER sends or saves — the user commits with Send / Add.
    pub fn bridge_command(&self, config: FfiBridgeConfig, transcript: String) -> Result<FfiBridgeAction, FfiError> {
        let cfg = config.into_core();
        let outcome = self
            .rt
            .block_on(agent::command(&self.engine, self.local.as_ref(), &cfg, &transcript));
        Ok(outcome.into())
    }

    /// Back-compat text-only voice turn for clients that haven't adopted
    /// `bridge_command` yet (the Android app). Delegates to the same intent layer and
    /// flattens any draft to its spoken line — such clients can't surface draft sheets,
    /// and the Bridge still never sends/saves.
    pub fn bridge_agent_turn(&self, config: FfiBridgeConfig, transcript: String) -> Result<FfiBridgeReply, FfiError> {
        let cfg = config.into_core();
        let action = self
            .rt
            .block_on(agent::command(&self.engine, self.local.as_ref(), &cfg, &transcript));
        use agent::CommandOutcome as C;
        let reply = match action {
            C::OpenAiError(e) => FfiBridgeReply { text: String::new(), openai_error: Some(e) },
            C::Speak(t) | C::Clarify(t) | C::DraftEmail { spoken: t, .. } | C::DraftEvent { spoken: t, .. } => {
                FfiBridgeReply { text: t, openai_error: None }
            }
        };
        Ok(reply)
    }

    /// Spoken read-out of one email thread — voices the pregenerated MEDIUM summary
    /// (`full = true`), since the email-detail audio button is an explicit "read this
    /// email aloud". The agent's voice path shares the same core fn at the requested depth.
    pub fn bridge_email_voice(&self, config: FfiBridgeConfig, conversation_key: String) -> Result<FfiBridgeReply, FfiError> {
        let cfg = config.into_core();
        let outcome = self.rt.block_on(agent::email_voice_text(
            &self.engine,
            self.local.as_ref(),
            &cfg,
            &conversation_key,
            true,
        ));
        Ok(outcome.into())
    }

    /// Clear the tool-using agent's voice-dialog history — call when starting a new
    /// interaction (e.g. requesting a daily brief) or on user cancel.
    pub fn bridge_reset_dialog(&self) {
        self.engine.reset_bridge_dialog();
    }

    /// Validate an OpenAI key (Settings "Test & save").
    pub fn bridge_validate_openai(&self, key: String) -> Result<(), FfiError> {
        self.rt
            .block_on(agent::validate_openai(&key))
            .map_err(FfiError::Engine)
    }

    /// OpenAI text-to-speech → MP3 bytes for the natural agent voice. `voice` is the
    /// chosen tts-1 voice (alloy/echo/fable/onyx/nova/shimmer); empty = alloy.
    pub fn bridge_openai_tts(&self, key: String, text: String, voice: String) -> Result<Vec<u8>, FfiError> {
        self.rt
            .block_on(agent::tts(&key, &text, &voice))
            .map_err(FfiError::Engine)
    }

    /// OpenAI speech-to-text — transcribe WAV `audio` bytes (the paid STT lane).
    pub fn bridge_openai_transcribe(&self, key: String, audio: Vec<u8>) -> Result<String, FfiError> {
        self.rt
            .block_on(agent::transcribe(&key, audio))
            .map_err(FfiError::Engine)
    }

    /// Execute a single tool by name with JSON args.
    pub fn bridge_execute_tool(&self, name: String, args_json: String) -> Result<String, FfiError> {
        let args = serde_json::from_str(&args_json).unwrap_or(serde_json::Value::Null);
        self.rt
            .block_on(tools::execute(&self.engine, &name, &args))
            .map_err(FfiError::Engine)
    }

    // ---- Async triage + multi-level summaries ----

    /// Push the user's selected AI generation lane (from Settings) to the
    /// background triage worker, so it classifies/summarizes with the same model
    /// the Bridge speaks with. Call at launch and whenever the selection changes.
    pub fn set_ai_config(&self, config: FfiBridgeConfig) {
        self.engine.set_ai_config(config.into_core());
        // Nudge the worker so a freshly-configured model starts draining at once.
        self.engine.ai_scan_notify().notify_one();
    }

    /// Re-run triage for ONE conversation — the reader's "Process with" action.
    /// `config` picks the SUMMARY lane (set `config.on_device_model` or the OpenAI
    /// lane to compare engines); classification is Jev when a key is set. The
    /// result is written with full provenance and `triage-updated` fires.
    /// Returns the recorded `triage_source` tag. Blocking — call off the main
    /// thread (it runs a model generation).
    pub fn reprocess_conversation(
        &self,
        config: FfiBridgeConfig,
        conversation_key: String,
    ) -> Result<String, FfiError> {
        let cfg = config.into_core();
        self.rt
            .block_on(crate::ai_worker::reprocess_conversation(
                &self.engine,
                self.local.as_ref(),
                Some(&cfg),
                &conversation_key,
            ))
            .map_err(FfiError::Engine)
    }

    /// Move a thread into a Space by hand — one of the effective Spaces (org +
    /// personal) or the holding pen `triage`. It sticks: re-filing and the
    /// worker leave it alone until `reprocess_conversation`. Emits `space-updated`.
    pub fn set_conversation_space(&self, conversation_key: String, slug: String) -> Result<(), FfiError> {
        crate::ai_worker::set_conversation_space(&self.engine, &conversation_key, &slug).map_err(FfiError::Engine)
    }

    /// Set a thread's triage label by hand (an enabled label slug;
    /// `triage_source` = `manual`). Holds until a new message arrives in the
    /// thread. Emits `triage-updated`.
    pub fn set_conversation_label(&self, conversation_key: String, label: String) -> Result<(), FfiError> {
        crate::ai_worker::set_conversation_label(&self.engine, &conversation_key, &label).map_err(FfiError::Engine)
    }

    /// The configured processing window (`1_month` | `3_months` | `6_months` |
    /// `1_year` | `everything`).
    pub fn get_processing_window(&self) -> Result<String, FfiError> {
        Ok(self.engine.store().processing_window().as_str().to_string())
    }

    /// Set the processing window. Widening it backfills newly-in-window
    /// conversations and wakes the worker. Returns an error for an unknown value.
    pub fn set_processing_window(&self, window: String) -> Result<(), FfiError> {
        let w = crate::triage::ProcessingWindow::from_str(&window)
            .ok_or_else(|| FfiError::Engine(format!("unknown window: {window}")))?;
        self.engine.store().set_processing_window(w)?;
        self.engine.store().backfill_triage_queue()?;
        self.engine.ai_scan_notify().notify_one();
        log::info!("[ffi] set_processing_window {window}");
        Ok(())
    }

    /// Whether the on-device Space classifier is enabled.
    pub fn get_space_classify_enabled(&self) -> Result<bool, FfiError> {
        Ok(self.engine.store().space_classify_enabled())
    }

    /// Toggle the on-device Space classifier. Enabling backfills every in-window
    /// thread that has no Space yet (already-triaged threads take the worker's
    /// space-only fast path — one classify call, no summary re-run) and wakes
    /// the worker. Off by default: local-channel volume is high.
    pub fn set_space_classify_enabled(&self, enabled: bool) -> Result<(), FfiError> {
        self.engine.store().set_space_classify_enabled(enabled)?;
        if enabled {
            self.engine.store().backfill_space_queue()?;
            self.engine.ai_scan_notify().notify_one();
        }
        log::info!("[ffi] set_space_classify_enabled {enabled}");
        Ok(())
    }

    /// Push the org's classifiable Spaces for Jev to file into — JSON
    /// `[{slug,name,description,not_for},…]` (legacy `[["slug","description"],…]`
    /// also accepted). Invalid JSON is rejected. Jev files into these plus the
    /// personal Spaces (see `get_personal_spaces`).
    pub fn set_space_taxonomy(&self, spaces_json: String) -> Result<(), FfiError> {
        let requeued = self.engine.store().set_space_taxonomy(&spaces_json)?;
        if requeued > 0 {
            self.engine.ai_scan_notify().notify_one();
        }
        log::info!("[ffi] set_space_taxonomy ({} bytes, {requeued} re-filed)", spaces_json.len());
        Ok(())
    }

    /// Triage progress snapshot as JSON `{inWindow, done, pending, currentDate,
    /// jevStatus}` for a cold start (live updates arrive as `triage-progress`
    /// events). `jevStatus` is `missing` | `ok` | `unauthorized` (Jev said 401).
    pub fn triage_progress(&self) -> Result<String, FfiError> {
        let p = self.engine.store().triage_progress()?;
        Ok(crate::ai_worker::progress_json(&self.engine, &p).to_string())
    }

    // ---- Jev (TypeSafe) triage classification ----

    /// Push the user's Jev key (secret `typesafe_api_key`; `None`/empty clears).
    /// Held in memory only — the host persists it and pushes it at every launch.
    /// A new key re-enqueues in-window threads still missing a label, priority
    /// or space and wakes the worker.
    pub fn set_jev_key(&self, key: Option<String>) {
        self.engine.set_jev_key(key);
    }

    /// Check a Jev key with one minimal real call ("Test & save"). `Err` carries a
    /// message to show as-is.
    pub fn validate_jev_key(&self, key: String) -> Result<(), FfiError> {
        let endpoint = self.engine.jev_endpoint();
        self.rt
            .block_on(crate::typesafe::validate_key(&endpoint, &key))
            .map_err(FfiError::Engine)
    }

    /// The triage labels (built-ins + custom) as JSON
    /// `[{slug,name,description,not_for,color,builtin,enabled},…]`, position order.
    pub fn get_triage_labels(&self) -> Result<String, FfiError> {
        Ok(serde_json::to_string(&self.engine.store().triage_labels())?)
    }

    /// Replace the triage label list (same JSON shape). Validated: slugs
    /// `[a-z0-9_]{1,40}`, unique, not `no_match`; every built-in present; `fyi`
    /// enabled; name + description required. `builtin` is recomputed. Returns
    /// the list as stored.
    pub fn set_triage_labels(&self, labels_json: String) -> Result<String, FfiError> {
        let labels: Vec<crate::triage::TriageLabelDef> = serde_json::from_str(&labels_json)?;
        let stored = self.engine.store().set_triage_labels(labels)?;
        Ok(serde_json::to_string(&stored)?)
    }

    /// This device's personal Spaces as JSON `[{slug,name,description,not_for},…]`
    /// (defaults: Reading, Personal). Jev files into the org's Spaces plus these;
    /// they are never shown to the team.
    pub fn get_personal_spaces(&self) -> Result<String, FfiError> {
        Ok(serde_json::to_string(&self.engine.store().personal_spaces())?)
    }

    /// Replace the personal Spaces (same JSON shape). Validated: slugs
    /// `[a-z0-9_-]{1,40}`, unique, not `triage`/`no_match`; a name on each. A
    /// changed list re-files Spaces like an org taxonomy change and wakes the
    /// worker. Returns the list as stored.
    pub fn set_personal_spaces(&self, spaces_json: String) -> Result<String, FfiError> {
        let spaces: Vec<crate::triage::SpaceDef> = serde_json::from_str(&spaces_json)?;
        let (stored, requeued) = self.engine.store().set_personal_spaces(spaces)?;
        if requeued > 0 {
            self.engine.ai_scan_notify().notify_one();
        }
        Ok(serde_json::to_string(&stored)?)
    }

    // ---- Bridge model manager (three-lane TTS / STT / NLU) ----

    /// Tell the manager what device it's on (drives native-lane availability). Call
    /// once at launch before reading lanes.
    pub fn set_device_profile(&self, profile: FfiDeviceProfile) {
        self.models.set_device_profile(profile.into());
    }

    /// Provide a HuggingFace access token used to fetch gated model repos (none in
    /// the current manifest). Pass `None`/empty to clear. Held in memory only — the
    /// host persists it.
    pub fn set_hf_token(&self, token: Option<String>) {
        self.models.set_hf_token(token);
    }

    /// Install a user-edited prompt template file (TOML, see [`default_prompts`]);
    /// `None` reverts to the embedded defaults. Sections absent from the override
    /// keep their defaults. Errors (bad TOML, unknown section, an `[intent]` prompt
    /// without `{intents}`) leave the active prompts untouched, so the host can show
    /// the message and keep running. Held in memory only — the host persists the
    /// file and re-installs it at launch.
    pub fn set_prompt_overrides(&self, toml_text: Option<String>) -> Result<(), FfiError> {
        prompts::set_overrides(toml_text.as_deref()).map_err(FfiError::Engine)
    }

    /// The embedded default prompt template file — the starting point for a user's
    /// edits and the "reset to defaults" content for a Settings editor.
    pub fn default_prompts(&self) -> String {
        prompts::DEFAULT_TOML.to_string()
    }

    /// Per-section view of a prompt override file (or the embedded defaults with
    /// `None`): one entry per template section, the override's text where present,
    /// the default otherwise. Raw template texts — placeholders like `{now}`
    /// are NOT substituted. Drives the mobile per-section prompt editors.
    pub fn prompt_sections(&self, toml_text: Option<String>) -> Result<Vec<FfiPromptSection>, FfiError> {
        prompts::sections(toml_text.as_deref())
            .map(|v| v.into_iter().map(|(key, text)| FfiPromptSection { key, text }).collect())
            .map_err(FfiError::Engine)
    }

    /// Build a validated override TOML from edited section texts (the inverse of
    /// [`Self::prompt_sections`]). Sections matching the embedded defaults are
    /// omitted; an empty result means "no overrides" — the host should pass `None`
    /// to [`Self::set_prompt_overrides`] and delete its persisted file. Building
    /// does NOT install.
    pub fn build_prompt_overrides(&self, sections: Vec<FfiPromptSection>) -> Result<String, FfiError> {
        let pairs: Vec<(String, String)> = sections.into_iter().map(|s| (s.key, s.text)).collect();
        prompts::build_overrides(&pairs).map_err(FfiError::Engine)
    }

    /// Run the triage eval harness ([`crate::triage_eval`]) over `fixtures_json`
    /// (an array of cases or `{"cases": [...]}`): the rules, then Jev with the
    /// engine's key and labels — what this device's triage would produce. Returns
    /// the `EvalReport` as JSON. Blocking; call off the main thread (one Jev call
    /// per case).
    pub fn run_triage_eval(&self, fixtures_json: String) -> Result<String, FfiError> {
        let cases = crate::triage_eval::parse_cases(&fixtures_json).map_err(FfiError::Engine)?;
        let (key, endpoint) = (self.engine.jev_key(), self.engine.jev_endpoint());
        let lane = key.as_deref().map(|key| crate::triage_eval::JevLane { endpoint: &endpoint, key });
        let labels = self.engine.store().triage_labels();
        let report = self.rt.block_on(crate::triage_eval::run(cases, lane, &labels));
        Ok(serde_json::to_string(&report)?)
    }

    /// The embedded starter eval fixtures (JSON) — seeds the debug screen's editor.
    pub fn default_eval_fixtures(&self) -> String {
        crate::triage_eval::STARTER_FIXTURES.to_string()
    }

    /// The three lanes (native / free / openai) for a capability (`tts` | `stt` |
    /// `nlu`), with availability + download state, for the settings picker.
    pub fn model_lanes(&self, capability: String, has_valid_key: bool) -> Result<Vec<FfiLaneInfo>, FfiError> {
        let cap = Capability::from_str(&capability)
            .ok_or_else(|| FfiError::Engine(format!("unknown capability: {capability}")))?;
        Ok(self.models.lanes(cap, has_valid_key).into_iter().map(Into::into).collect())
    }

    /// Resolve the lane to route to for a capability given the host's preference
    /// (`native` | `free` | `openai`). Returns `native` | `free` | `openai` |
    /// `needs-download` (offline with no native lane and the free model not yet down).
    pub fn effective_lane(&self, capability: String, user_pref: String, has_valid_key: bool) -> Result<String, FfiError> {
        let cap = Capability::from_str(&capability)
            .ok_or_else(|| FfiError::Engine(format!("unknown capability: {capability}")))?;
        let pref = Lane::from_str(&user_pref)
            .ok_or_else(|| FfiError::Engine(format!("unknown lane: {user_pref}")))?;
        Ok(self.models.effective_lane(cap, pref, has_valid_key).as_str().to_string())
    }

    /// Start (or resume) downloading a free model by id. Returns immediately; progress
    /// flows over the event bus as `model-download` events.
    pub fn model_download(&self, id: String) -> Result<(), FfiError> {
        let entry = self.models.entry_for_download(&id).map_err(FfiError::Engine)?;
        let models = self.models.clone();
        self.rt.spawn(async move { models.downloads().run(entry).await });
        Ok(())
    }

    /// Delete a downloaded free model, reclaiming its disk.
    pub fn model_delete(&self, id: String) -> Result<(), FfiError> {
        self.models.delete(&id).map_err(FfiError::Engine)
    }

    /// The verified on-disk directory for an installed model (for the native
    /// inference engine), or `None` if not installed.
    pub fn model_path(&self, id: String) -> Option<String> {
        self.models.path(&id).map(|p| p.to_string_lossy().into_owned())
    }

    /// Every connected account, as a JSON array (`ExternalAccount` shape). Meta
    /// accounts also carry a non-secret `meta_app_id` so the UI can group
    /// channels by app and offer credential reuse (the app secret + token stay
    /// encrypted and are never included).
    pub fn list_accounts_json(&self) -> Result<String, FfiError> {
        let accounts = self.engine.store().list_accounts()?;
        let enriched: Vec<serde_json::Value> = accounts
            .into_iter()
            .map(|a| {
                let mut v = serde_json::to_value(&a).unwrap_or_default();
                if a.provider_type.is_meta() {
                    if let Ok(Some(ProviderCredentials::Meta(c))) =
                        self.engine.store().get_credentials(&a.key)
                    {
                        if !c.app_id.is_empty() {
                            if let Some(obj) = v.as_object_mut() {
                                obj.insert(
                                    "meta_app_id".to_string(),
                                    serde_json::Value::String(c.app_id),
                                );
                            }
                        }
                    }
                }
                v
            })
            .collect();
        Ok(serde_json::to_string(&enriched)?)
    }

    /// True at most once per 5 minutes per account: gates the interrupting
    /// "sign-in expired" prompt so an account with a dead token doesn't re-prompt
    /// on every sync tick, foreground, and relaunch. Passive indicators (badges,
    /// Settings banner) ignore this and stay accurate.
    pub fn claim_reauth_prompt(&self, account_key: String) -> bool {
        self.engine.store().claim_reauth_prompt(&account_key)
    }

    // ---- MX mirror: inbox2-hosted mail kept in local SQLite (docs/MX-Sync.md) ----
    //
    // The host reads the `mx_*` tables directly (each row's `payload` is the API's
    // own JSON, so the existing cloud DTOs decode it); these are the verbs.

    /// The signed-in inbox2 session, or `None` on sign-out. The engine needs it to
    /// mirror MX mail and replay queued actions; without one it does neither.
    pub fn set_cloud_session(&self, api_base: String, token: Option<String>) {
        self.rt.block_on(self.engine.set_api_context(api_base, token.unwrap_or_default()));
    }

    /// Mirror `org` as `user_key` and run one bounded pass now. Call on sign-in, on
    /// foreground, and on a push wake; while `more` is true, call again. The engine
    /// also runs a pass for every mirrored org on its own 60s beat while alive.
    pub fn mx_sync(&self, org: String, user_key: String, directory: bool, reconcile: bool) -> Result<FfiMxReport, FfiError> {
        let opts = crate::sync::mx_sync::MxSyncOptions { directory, reconcile };
        let r = self.rt.block_on(self.engine.mx_sync(&org, &user_key, opts))?;
        Ok(FfiMxReport {
            pulled: r.pulled as u32,
            deleted: r.deleted as u32,
            backfilled: r.backfilled as u32,
            hydrated: r.hydrated as u32,
            removed: r.removed as u32,
            backfill_done: r.backfill_done,
            more: r.more,
        })
    }

    /// Send queued actions and run a pass for every org mirrored on this device —
    /// for a push wake in a cold process, where no session object exists yet to say
    /// which orgs those are. The engine knows (and rehydrates its bearer from its own
    /// store).
    pub fn mx_tick(&self) {
        self.rt.block_on(self.engine.mx_tick());
    }

    /// archive / trash / spam / open / mark_read / mark_unread on MX threads: in the
    /// mirror before this returns, queued durably, sent as soon as the network allows.
    /// Offline is not an error.
    pub fn mx_action(&self, org: String, threads: Vec<String>, action: String) -> Result<(), FfiError> {
        Ok(self.rt.block_on(self.engine.mx_action(&org, &threads, &action))?)
    }

    /// Sign-out / org removed: its mail, queued actions and domain keys leave the device.
    pub fn mx_forget(&self, org: String) -> Result<(), FfiError> {
        Ok(self.rt.block_on(self.engine.mx_forget(&org))?)
    }

    /// E2EE: the domain keypairs the member unlocked (base64), held in memory only so
    /// the engine can open mirrored sealed mail. An empty list takes them back
    /// (lock). Returns how many messages were opened.
    pub fn mx_set_domain_keys(&self, org: String, keys: Vec<FfiDomainKey>) -> Result<u32, FfiError> {
        let keys = keys
            .iter()
            .map(|k| crate::sync::seal::DomainKey::from_b64(k.version, &k.public_key, &k.secret_key))
            .collect::<Result<Vec<_>, _>>()?;
        Ok(self.engine.mx_set_domain_keys(&org, keys) as u32)
    }

    /// Sealed mail on phones: the identity key, opened with the account password.
    /// `None` is a wrong password. The app keeps it only in its secure store.
    pub fn mx_unlock_identity(&self, password: String) -> Result<Option<String>, FfiError> {
        Ok(self.rt.block_on(self.engine.mx_unlock_identity(&password))?.map(|k| k.to_string()))
    }

    /// Open this org's sealed domain keys with the identity key. Returns how many
    /// mirrored messages opened.
    pub fn mx_unlock_org(&self, org: String, identity_key: String) -> Result<u32, FfiError> {
        Ok(self.rt.block_on(self.engine.mx_unlock_org(&org, &identity_key))? as u32)
    }

    /// Sync one account now (connect → list → initial/incremental). Idempotent: a
    /// sync already in flight for the account is coalesced.
    pub fn start_sync(&self, account_key: String) -> Result<(), FfiError> {
        self.rt
            .block_on(self.engine.connect_and_sync(&account_key))?;
        Ok(())
    }

    /// Ingest a buffered Meta webhook event by its relay key — the mobile silent-push
    /// entry point (the `meta_event` data push carries `event_key`). Fetches, verifies
    /// the HMAC against the local app_secret, normalizes, and applies. See
    /// docs/Cloud-Push.md (Meta).
    pub fn ingest_meta_event(&self, event_key: String) -> Result<bool, FfiError> {
        Ok(self.rt.block_on(self.engine.ingest_meta_event(&event_key))?)
    }

    /// Apply a conversation action (archive / trash / mark_read / … and their
    /// reverses). Optimistic locally, then queued as a durable provider write-back.
    pub fn perform_action(
        &self,
        account_key: String,
        conversation_keys: Vec<String>,
        action: String,
    ) -> Result<(), FfiError> {
        self.rt.block_on(self.engine.perform_conversation_action(
            &account_key,
            &conversation_keys,
            &action,
        ))?;
        Ok(())
    }

    /// Compose + send a message from `account_key`. Persists it to the outbox and
    /// attempts immediate delivery; returns a JSON `OutboxSendResult`
    /// (`outbox_key`, `status`, `provider_message_id`, `error_message`). The send
    /// is durable — a transient failure stays queued and retries, so the native
    /// side treats a non-`sent` status as "queued", not an error.
    #[allow(clippy::too_many_arguments)]
    pub fn send_message(
        &self,
        account_key: String,
        from_address: String,
        to_address: String,
        cc_address: Option<String>,
        bcc_address: Option<String>,
        subject: Option<String>,
        body_html: Option<String>,
        body_plain: Option<String>,
        attachments: Vec<FfiAttachment>,
        reply_to_message_key: Option<String>,
    ) -> Result<String, FfiError> {
        let msg = OutgoingMessage {
            from_address,
            to_address,
            cc_address: cc_address.filter(|s| !s.is_empty()),
            bcc_address: bcc_address.filter(|s| !s.is_empty()),
            subject: subject.filter(|s| !s.is_empty()),
            body_html: body_html.filter(|s| !s.is_empty()),
            body_plain,
            attachments: attachments
                .into_iter()
                .map(|a| OutgoingAttachment {
                    filename: a.filename,
                    mime_type: a.mime_type,
                    data: a.data,
                })
                .collect(),
            // The engine hydrates In-Reply-To/References/threadId from this key
            // at enqueue time (see SyncEngine::hydrate_reply_context).
            reply_to_message_key: reply_to_message_key.filter(|s| !s.is_empty()),
            in_reply_to: None,
            references: None,
            provider_thread_id: None,
            ..Default::default()
        };
        log::info!(
            "[ffi] send_message from {} to {} (cc={:?} bcc={:?} atts={})",
            msg.from_address,
            msg.to_address,
            msg.cc_address,
            msg.bcc_address,
            msg.attachments.len()
        );
        let result = self.rt.block_on(self.engine.enqueue_send(&account_key, msg))?;
        Ok(serde_json::to_string(&result)?)
    }

    /// Fetch a message's full body + attachment metadata from the provider (live
    /// network call). Returns JSON `{ body_html, body_plain, attachments:
    /// [{ attachment_id, filename, mime_type, size }] }`. Used to enrich the reader
    /// and list a message's attachments.
    pub fn fetch_message(&self, account_key: String, message_key: String) -> Result<String, FfiError> {
        let provider = self.engine.interactive_provider(&account_key)?;
        let fetched = self.rt.block_on(provider.fetch_message(&message_key))?;
        log::info!("[ffi] fetch_message {message_key}: {} attachment(s)", fetched.attachments.len());
        // Fold the now-known attachment filenames into the search index. Sync
        // only persists filenames for providers that expose them in the list
        // payload (Gmail); IMAP/Microsoft/Meta backfill here on first open.
        let names = fetched
            .attachments
            .iter()
            .map(|a| a.filename.as_str())
            .filter(|f| !f.is_empty())
            .collect::<Vec<_>>()
            .join(" ");
        // Largest attachment rides along for the `larger:`/`smaller:` filters.
        let max_size = fetched.attachments.iter().map(|a| a.size as i64).max();
        if let Err(e) = self
            .engine
            .store()
            .backfill_attachment_names(&message_key, &names, max_size)
        {
            log::warn!("[ffi] backfill_attachment_names {message_key}: {e}");
        }
        Ok(serde_json::to_string(&fetched)?)
    }

    /// Download one attachment's bytes from the provider (live network call).
    pub fn download_attachment(
        &self,
        account_key: String,
        message_key: String,
        attachment_id: String,
    ) -> Result<Vec<u8>, FfiError> {
        let provider = self.engine.interactive_provider(&account_key)?;
        let bytes = self.rt.block_on(provider.download_attachment(&message_key, &attachment_id))?;
        log::info!("[ffi] download_attachment {attachment_id}: {} bytes", bytes.len());
        Ok(bytes)
    }

    /// Add a connected account (after the native OAuth/IMAP flow obtained
    /// credentials) and kick its initial connect+sync. `auth_method` is `xoauth2`
    /// for OAuth providers (Gmail/Microsoft) or `plain` for IMAP password. Returns
    /// the new account key. The IMAP-only fields are ignored for OAuth providers.
    #[allow(clippy::too_many_arguments)]
    pub fn add_account(
        &self,
        provider_type: String,
        email: String,
        display_name: String,
        auth_method: String,
        access_token: Option<String>,
        refresh_token: Option<String>,
        password: Option<String>,
        host: Option<String>,
        port: Option<u16>,
        use_tls: Option<bool>,
        smtp_host: Option<String>,
        smtp_port: Option<u16>,
        smtp_use_tls: Option<bool>,
        cloud_backup: Option<bool>,
    ) -> Result<String, FfiError> {
        let pt = ProviderType::from_str(&provider_type)
            .ok_or_else(|| FfiError::Engine(format!("unknown provider: {provider_type}")))?;
        let is_imap = matches!(pt, ProviderType::Imap);

        // `auth_method` is persisted verbatim on the account; only the credential
        // shape is derived here (xoauth2 is an OAuth2 synonym — see AuthMethod).
        let credentials = if AuthMethod::from_str(&auth_method).is_oauth() {
            ProviderCredentials::OAuth2 {
                username: email.clone(),
                access_token: access_token.unwrap_or_default(),
                refresh_token,
            }
        } else {
            ProviderCredentials::Password {
                username: email.clone(),
                password: password.unwrap_or_default(),
            }
        };

        let account = ExternalAccount {
            key: String::new(),
            display_name: if display_name.is_empty() { email.clone() } else { display_name },
            email_address: email.clone(),
            provider_type: pt,
            host: if is_imap { host } else { None },
            port: if is_imap { Some(port.unwrap_or(993)) } else { None },
            use_tls: use_tls.unwrap_or(true),
            smtp_host: if is_imap { smtp_host } else { None },
            smtp_port: if is_imap { Some(smtp_port.unwrap_or(465)) } else { None },
            smtp_use_tls: smtp_use_tls.unwrap_or(true),
            auth_method,
            status: AccountStatus::Disconnected,
            error_message: None,
            last_connected_at: None,
            sort_order: 0,
            avatar_url: None,
        };

        let key = self.engine.store().create_account(&account)?;
        self.engine.store().store_credentials(&key, &credentials)?;
        // Cloud credential backup (docs/E2EE.md): flag the account + mark it dirty so
        // the engine's backup drain uploads it once the vault is unlocked. No-op if
        // backup is off / not opted in.
        if cloud_backup.unwrap_or(false) {
            let _ = self.engine.store().set_account_backup_enabled(&key, true);
            let _ = self.engine.store().mark_backup_dirty(&key);
        }
        log::info!("[ffi] add_account {email} ({provider_type}) -> {key}");

        // Register (or, on a *reconnect*, re-register) the live account state from
        // the credentials we just stored. create_account upserts by email, so a
        // reconnect reuses the existing key — and that account is already in the
        // engine's in-memory map with an adapter + TokenManager built from the OLD
        // (now-revoked) tokens. `connect_and_sync`'s registration is fast-path-only
        // (it won't reload an already-registered account), so without this the next
        // sync would refresh with the dead refresh token → Google `invalid_grant`.
        // `engine.add_account` overwrites the map entry with a fresh adapter from
        // these credentials and resets the status (clearing a stale needs_reauth).
        let host_str = account.host.clone().unwrap_or_default();
        let port_val = account.port.unwrap_or(993);
        self.rt.block_on(self.engine.add_account(
            &key,
            &account.provider_type,
            &host_str,
            port_val,
            account.use_tls,
            credentials,
        ))?;

        // Connect + initial sync in the background; the listener gets sync events.
        let engine = self.engine.clone();
        let k = key.clone();
        self.rt.spawn(async move {
            if let Err(e) = engine.connect_and_sync(&k).await {
                log::error!("[ffi] add_account initial sync failed: {e}");
            }
        });
        Ok(key)
    }

    /// Add a Meta BYOK account (Instagram/Messenger/WhatsApp). The app secret +
    /// System User token are stored encrypted on-device and never sent to Rails;
    /// connect (token validation + webhook subscription + relay registration)
    /// runs in the background. See docs/Cloud-Push.md (Meta).
    #[allow(clippy::too_many_arguments)]
    pub fn add_meta_account(
        &self,
        channel: String,
        display_name: Option<String>,
        app_id: String,
        app_secret: String,
        system_user_token: String,
        facebook_page_id: Option<String>,
        instagram_account_id: Option<String>,
        whatsapp_phone_number_id: Option<String>,
        whatsapp_business_account_id: Option<String>,
        reuse_credentials_from: Option<String>,
        cloud_backup: Option<bool>,
    ) -> Result<String, FfiError> {
        let pt = ProviderType::from_str(&channel)
            .filter(ProviderType::is_meta)
            .ok_or_else(|| FfiError::Engine(format!("unknown Meta channel: {channel}")))?;

        // App-level credentials: reuse an existing Meta account's on-device bundle
        // (the operator only enters the new asset id), or take them from the args.
        let (app_id, app_secret, system_user_token) = match reuse_credentials_from
            .as_deref()
            .filter(|s| !s.is_empty())
        {
            Some(source_key) => match self.engine.store().get_credentials(source_key)? {
                Some(ProviderCredentials::Meta(c)) => (c.app_id, c.app_secret, c.system_user_token),
                Some(_) => {
                    return Err(FfiError::Engine(
                        "Meta: the selected account to reuse credentials from is not a Meta account".into(),
                    ))
                }
                None => {
                    return Err(FfiError::Engine(
                        "Meta: couldn't find the account to reuse credentials from".into(),
                    ))
                }
            },
            None => {
                if app_secret.is_empty() || system_user_token.is_empty() {
                    return Err(FfiError::Engine(
                        "Meta: app_secret and System User token are required".into(),
                    ));
                }
                (app_id, app_secret, system_user_token)
            }
        };

        let nz = |s: Option<String>| s.filter(|v| !v.is_empty());
        let partial = MetaCredentials {
            app_id,
            app_secret,
            system_user_token,
            facebook_page_id: nz(facebook_page_id),
            instagram_account_id: nz(instagram_account_id),
            whatsapp_phone_number_id: nz(whatsapp_phone_number_id),
            whatsapp_business_account_id: nz(whatsapp_business_account_id),
            ..Default::default()
        };
        // Auto-derive the secondary asset id (WABA→phone, Page→Instagram account)
        // so the form only needs one id per channel.
        let channel = pt
            .meta_channel()
            .ok_or_else(|| FfiError::Engine("provider is not a Meta channel".into()))?;
        let (creds, suggested_name) = self.rt.block_on(self.engine.discover_meta_assets(channel, partial));

        // Required primary asset, post-discovery (send target / routing key).
        let (primary, missing) = match pt {
            ProviderType::WhatsApp => (&creds.whatsapp_phone_number_id, "WhatsApp phone number"),
            ProviderType::Instagram => (&creds.instagram_account_id, "Instagram account"),
            ProviderType::Messenger => (&creds.facebook_page_id, "Facebook Page"),
            _ => (&None, "asset"),
        };
        let primary_asset = primary
            .clone()
            .filter(|s| !s.is_empty())
            .ok_or_else(|| FfiError::Engine(format!(
                "Meta: couldn't auto-detect the {missing} — check the System User token's permissions and asset assignment"
            )))?;

        let email = format!("{}:{}", pt.as_str(), primary_asset);
        let account = ExternalAccount {
            key: String::new(),
            display_name: display_name.filter(|s| !s.is_empty()).or(suggested_name).unwrap_or_else(|| email.clone()),
            email_address: email.clone(),
            provider_type: pt.clone(),
            host: None,
            port: None,
            use_tls: false,
            smtp_host: None,
            smtp_port: None,
            smtp_use_tls: false,
            auth_method: "meta".to_string(),
            status: AccountStatus::Disconnected,
            error_message: None,
            last_connected_at: None,
            sort_order: 0,
            avatar_url: None,
        };

        let credentials = ProviderCredentials::Meta(creds);
        let key = self.engine.store().create_account(&account)?;
        self.engine.store().store_credentials(&key, &credentials)?;
        if cloud_backup.unwrap_or(false) {
            let _ = self.engine.store().set_account_backup_enabled(&key, true);
            let _ = self.engine.store().mark_backup_dirty(&key);
        }
        log::info!("[ffi] add_meta_account {} -> {key}", pt.as_str());

        self.rt.block_on(self.engine.add_account(&key, &pt, "", 0, false, credentials))?;

        let engine = self.engine.clone();
        let k = key.clone();
        self.rt.spawn(async move {
            if let Err(e) = engine.connect_and_sync(&k).await {
                log::error!("[ffi] add_meta_account connect failed: {e}");
            }
        });
        Ok(key)
    }

    /// Remove a connected account: disconnect its adapter, deregister cloud push,
    /// and delete all of its local data (conversations, messages, calendars,
    /// events, credentials, folders, outbox, write-back queue). Idempotent.
    pub fn remove_account(&self, account_key: String) -> Result<(), FfiError> {
        self.rt.block_on(self.engine.remove_account(&account_key))?;
        log::info!("[ffi] remove_account {account_key}");
        Ok(())
    }

    // -----------------------------------------------------------------------
    // Credential vault — zero-knowledge cloud backup (see docs/E2EE.md)
    // -----------------------------------------------------------------------

    /// Enable cloud backup with the inbox2 account password (creates the vault +
    /// backs up existing accounts). Returns the vault public id.
    pub fn enable_cloud_backup(&self, password: String) -> Result<String, FfiError> {
        Ok(self.rt.block_on(self.engine.enable_cloud_backup(&password))?)
    }

    /// Turn off cloud backup: delete the vault + all blobs server-side, clear local.
    pub fn disable_cloud_backup(&self) -> Result<(), FfiError> {
        self.rt.block_on(self.engine.disable_cloud_backup())?;
        Ok(())
    }

    /// Unlock the vault on this device with the inbox2 password.
    pub fn unlock_vault(&self, password: String) -> Result<(), FfiError> {
        self.rt.block_on(self.engine.unlock_vault(&password))?;
        Ok(())
    }

    /// Re-encrypt all backed-up credentials under a new password (call after the
    /// inbox2 account password changes).
    pub fn rotate_vault(&self, new_password: String) -> Result<(), FfiError> {
        self.rt.block_on(self.engine.rotate_vault(&new_password))?;
        Ok(())
    }

    /// Drop the vault session (DEK + local state). Call on sign-out / account switch.
    pub fn clear_vault_session(&self) {
        self.engine.clear_vault_session();
    }

    /// `{ enabled, unlocked, accountCount }` JSON for UI gating.
    pub fn vault_status_json(&self) -> Result<String, FfiError> {
        let status = self.engine.vault_status()?;
        serde_json::to_string(&status).map_err(|e| FfiError::Engine(e.to_string()))
    }

    /// Metadata of every cloud-backed credential (JSON array) — drives the restore
    /// offer + management UI.
    pub fn list_cloud_backed_credentials_json(&self) -> Result<String, FfiError> {
        let metas = self.rt.block_on(self.engine.list_cloud_backups())?;
        serde_json::to_string(&metas).map_err(|e| FfiError::Engine(e.to_string()))
    }

    /// Restore all cloud-backed credentials with the inbox2 password (a new device).
    /// Returns how many accounts were restored. No OAuth needed.
    pub fn restore_from_cloud(&self, password: String) -> Result<u32, FfiError> {
        Ok(self.rt.block_on(self.engine.restore_from_cloud(&password))?)
    }

    /// Toggle cloud backup for a single already-connected account.
    pub fn set_account_cloud_backup(
        &self,
        account_key: String,
        enabled: bool,
    ) -> Result<(), FfiError> {
        self.engine.store().set_account_backup_enabled(&account_key, enabled)?;
        if enabled {
            self.engine.store().mark_backup_dirty(&account_key)?;
        }
        Ok(())
    }

    /// Enable/disable open tracking for a local channel + set its custom tracking
    /// host (None = the inbox2 default). See docs/Open-Tracking.md.
    pub fn set_open_tracking(
        &self,
        account_key: String,
        enabled: bool,
        track_domain: Option<String>,
    ) -> Result<(), FfiError> {
        let td = track_domain.map(|s| s.trim().to_lowercase()).filter(|s| !s.is_empty());
        self.engine.store().set_open_tracking(&account_key, enabled, td.as_deref())?;
        Ok(())
    }

    /// Current open-tracking settings for a channel: JSON `{ enabled, track_domain }`.
    pub fn open_tracking_settings_json(&self, account_key: String) -> Result<String, FfiError> {
        let s = self.engine.store().open_tracking_settings(&account_key)?;
        Ok(serde_json::json!({ "enabled": s.enabled, "track_domain": s.track_domain }).to_string())
    }

    /// Open history for a sent message (who/when/where), resolved via the tracking
    /// token embedded in its body. JSON array of opens; empty when untracked.
    pub fn message_opens_json(&self, message_key: String) -> Result<String, FfiError> {
        let body = self.engine.store().message_body_html(&message_key)?.unwrap_or_default();
        let opens = self.engine.message_opens(&body);
        Ok(serde_json::to_string(&opens)?)
    }

    /// Conversation keys matching an FTS5 expression (JSON array, newest first). The
    /// Android client's own SQLite has no FTS5 module, so its search runs the MATCH
    /// through the core and joins the keys locally.
    pub fn fts_conversation_keys_json(&self, match_expr: String, limit: u32) -> Result<String, FfiError> {
        let keys = self.engine.store().fts_conversation_keys(&match_expr, limit as usize)?;
        Ok(serde_json::to_string(&keys)?)
    }

    /// The provider's own search (Gmail `q`, Graph `$search`), which reads inside
    /// attachments; the local conversation keys it hit, as a JSON array (live
    /// network call). `[]` for IMAP/Meta. Mobile appends these after its FTS rows.
    pub fn provider_search_json(&self, account_key: String, query: String) -> Result<String, FfiError> {
        let provider = self.engine.interactive_provider(&account_key)?;
        let keys = self.rt.block_on(provider.search_conversations(&query))?;
        log::info!("[ffi] provider_search {account_key}: {} conversation(s)", keys.len());
        Ok(serde_json::to_string(&keys)?)
    }

    /// Re-queue a failed/exhausted outbox message for immediate delivery: resets
    /// its status to pending, clears the backoff, and kicks the send loop.
    pub fn retry_outbox(&self, account_key: String, outbox_key: String) -> Result<(), FfiError> {
        self.rt.block_on(self.engine.retry_outbox_message(&account_key, &outbox_key))?;
        log::info!("[ffi] retry_outbox {outbox_key}");
        Ok(())
    }

    /// Cancel a queued/failed send by deleting its outbox entry. Returns whether it existed.
    pub fn delete_outbox(&self, account_key: String, outbox_key: String) -> Result<bool, FfiError> {
        let existed = self.rt.block_on(self.engine.delete_outbox_message(&account_key, &outbox_key))?;
        log::info!("[ffi] delete_outbox {outbox_key} (existed={existed})");
        Ok(existed)
    }

    /// Add an email-less Lore todo ("+ Add todo"). Returns the new row as JSON
    /// `{id, title, created_at, done_at, source}`.
    pub fn lore_add_todo(&self, title: String) -> Result<String, FfiError> {
        let todo = self.engine.store().add_lore_todo(&title, crate::sync::store::LORE_SOURCE_MANUAL)?;
        Ok(serde_json::to_string(&todo)?)
    }

    // ── Send to… (docs/MCP-Client.md). The phone owns the browser and the loopback;
    // the core does the protocol. `mcp_create` runs only when the person presses Create.

    pub fn mcp_presets_json(&self) -> Result<String, FfiError> {
        Ok(serde_json::to_string(&crate::mcp_client::presets())?)
    }

    pub fn mcp_connections_json(&self) -> Result<String, FfiError> {
        let rows = crate::mcp_client::list_connections(self.engine.store()).map_err(FfiError::Engine)?;
        Ok(serde_json::to_string(&rows)?)
    }

    /// `{ connected: Connection }` or `{ state, authorize_url }`: open the browser, then `mcp_finish_connect`.
    pub fn mcp_begin_connect(
        &self, name: String, url: String, token: Option<String>, client_id: Option<String>, client_secret: Option<String>, redirect_uri: String,
    ) -> Result<String, FfiError> {
        let client = client_id.filter(|s| !s.trim().is_empty()).map(|id| (id.trim().to_string(), client_secret.filter(|s| !s.trim().is_empty())));
        let v = self.rt.block_on(crate::mcp_client::begin_connect(self.engine.store(), &name, &url, token.as_deref(), client, &redirect_uri)).map_err(FfiError::Engine)?;
        Ok(v.to_string())
    }

    pub fn mcp_begin_reauth(&self, id: String, token: Option<String>, redirect_uri: String) -> Result<String, FfiError> {
        let v = self.rt.block_on(crate::mcp_client::begin_reauth(self.engine.store(), &id, token.as_deref(), &redirect_uri)).map_err(FfiError::Engine)?;
        Ok(v.to_string())
    }

    pub fn mcp_finish_connect(&self, state: String, code: String) -> Result<String, FfiError> {
        let conn = self.rt.block_on(crate::mcp_client::finish_connect(self.engine.store(), &state, &code)).map_err(FfiError::Engine)?;
        Ok(serde_json::to_string(&conn)?)
    }

    pub fn mcp_remove_connection(&self, id: String) -> Result<(), FfiError> {
        crate::mcp_client::remove_connection(self.engine.store(), &id).map_err(FfiError::Engine)
    }

    /// The connection's tools, ranked, each with its form fields prefilled from the
    /// Lore item (`item_json`: `{subject, detail, from, address, domain}`).
    pub fn mcp_drafts_json(&self, id: String, item_json: String) -> Result<String, FfiError> {
        let conn = crate::mcp_client::get_connection(self.engine.store(), &id).map_err(FfiError::Engine)?;
        let tools = self.rt.block_on(crate::mcp_client::list_tools(self.engine.store(), &id)).map_err(FfiError::Engine)?;
        let item: crate::mcp_client::draft::Item = serde_json::from_str(&item_json)?;
        Ok(serde_json::to_string(&crate::mcp_client::draft::drafts(&conn.url, tools, &item))?)
    }

    /// Create: the only call that invokes a tool. Returns `{ summary, is_error }`;
    /// `summary` is the result's first text block, untrusted, plain text only.
    pub fn mcp_create(&self, id: String, tool: String, values_json: String) -> Result<String, FfiError> {
        use crate::mcp_client as mc;
        let store = self.engine.store();
        let tools = self.rt.block_on(mc::list_tools(store, &id)).map_err(FfiError::Engine)?;
        let schema = tools.into_iter().find(|t| t.name == tool).map(|t| t.input_schema).ok_or_else(|| FfiError::Engine("That tool is gone from the server.".into()))?;
        let values: serde_json::Map<String, serde_json::Value> = serde_json::from_str(&values_json)?;
        let args = mc::draft::build_arguments(&schema, &values).map_err(FfiError::Engine)?;
        let r = self.rt.block_on(mc::call_tool(store, &id, &tool, args)).map_err(FfiError::Engine)?;
        Ok(serde_json::json!({ "summary": mc::draft::first_text(&r.content), "is_error": r.is_error }).to_string())
    }

    /// Store what Send to… made for a Lore item (the chip); returns the row as JSON.
    pub fn lore_sent_add(&self, item_key: String, connection_name: String, summary: String) -> Result<String, FfiError> {
        Ok(serde_json::to_string(&self.engine.store().add_lore_sent(&item_key, &connection_name, &summary)?)?)
    }

    /// Every stored reference, newest first — JSON array.
    pub fn lore_sent_list_json(&self) -> Result<String, FfiError> {
        Ok(serde_json::to_string(&self.engine.store().lore_sent()?)?)
    }

    /// Open Lore todos (manual + voice `add_reminder`), oldest first — JSON array.
    pub fn lore_list_todos_json(&self) -> Result<String, FfiError> {
        Ok(serde_json::to_string(&self.engine.store().open_lore_todos()?)?)
    }

    /// Tick a Lore todo off (sets `done_at`). Returns whether an open row matched.
    pub fn lore_complete_todo(&self, id: String) -> Result<bool, FfiError> {
        Ok(self.engine.store().complete_lore_todo(&id)?)
    }

    /// Local Lore ontology entities (docs/Ontology.md), as the Tauri `lore_entities`
    /// command and Rails `/lore/entities`: `{ entities: [...] }` JSON. Catches the
    /// header pass up first so a fresh install has entities before the miner ticks.
    pub fn lore_entities_json(&self, kind: Option<String>, q: Option<String>) -> Result<String, FfiError> {
        let conn = self.engine.store().connection();
        let c = conn.lock();
        let ffi = |e: rusqlite::Error| FfiError::Engine(e.to_string());
        crate::ontology::mine_headers(&c).map_err(ffi)?;
        Ok(crate::ontology::entities(&c, kind.as_deref(), q.as_deref()).map_err(ffi)?.to_string())
    }

    /// One entity with its facts and conversations (`{ entity: {...} }`), or nil.
    pub fn lore_entity_json(&self, id: String) -> Result<Option<String>, FfiError> {
        let conn = self.engine.store().connection();
        let c = conn.lock();
        let ffi = |e: rusqlite::Error| FfiError::Engine(e.to_string());
        Ok(crate::ontology::entity(&c, &id).map_err(ffi)?.map(|v| v.to_string()))
    }

    /// Toggle a local rule's `enabled` flag. Returns whether a row matched.
    pub fn set_rule_enabled(&self, rule_key: String, enabled: bool) -> Result<bool, FfiError> {
        let changed = self.engine.store().set_local_rule_enabled(&rule_key, enabled)?;
        log::info!("[ffi] set_rule_enabled {rule_key} = {enabled} (matched={changed})");
        Ok(changed)
    }

    /// Create a built-in local rule. `conditions_json` is a JSON array of
    /// `{field, op, value}`; `action_json` is `{"type":"perform_action","builtin":…}`.
    /// `run_agent` rules are desktop-only and not creatable here. Returns the key.
    pub fn create_builtin_rule(
        &self,
        name: String,
        conditions_json: String,
        action_json: String,
        account_key: Option<String>,
        enabled: bool,
    ) -> Result<String, FfiError> {
        let key = self.engine.store().create_local_rule(
            &name,
            &conditions_json,
            &action_json,
            account_key.as_deref(),
            enabled,
        )?;
        log::info!("[ffi] create_builtin_rule '{name}' -> {key}");
        Ok(key)
    }

    /// Update a built-in rule's name + conditions + action. Returns whether a row matched.
    pub fn update_builtin_rule(
        &self,
        rule_key: String,
        name: String,
        conditions_json: String,
        action_json: String,
    ) -> Result<bool, FfiError> {
        let changed = self.engine.store().update_local_rule(
            &rule_key,
            &name,
            &conditions_json,
            &action_json,
        )?;
        log::info!("[ffi] update_builtin_rule {rule_key} '{name}' (matched={changed})");
        Ok(changed)
    }

    /// Delete a local rule by key. Returns whether a row matched.
    pub fn delete_rule(&self, rule_key: String) -> Result<bool, FfiError> {
        let changed = self.engine.store().delete_local_rule(&rule_key)?;
        log::info!("[ffi] delete_rule {rule_key} (matched={changed})");
        Ok(changed)
    }

    /// Create a calendar event from a JSON `EventDraft`
    /// (`{title, description?, location?, start_at, end_at, all_day?, timezone?,
    /// attendees?[]}`). Writes through to the provider then re-syncs. Returns the
    /// new provider event id.
    pub fn create_calendar_event(
        &self,
        account_key: String,
        calendar_provider_id: String,
        draft_json: String,
    ) -> Result<String, FfiError> {
        let draft: crate::sync::calendar::EventDraft = serde_json::from_str(&draft_json)?;
        let id = self.rt.block_on(self.engine.create_calendar_event(
            &account_key,
            &calendar_provider_id,
            draft,
        ))?;
        log::info!("[ffi] create_calendar_event in {calendar_provider_id} -> {id}");
        Ok(id)
    }

    /// RSVP to an event by its local key. `response` is `accepted` | `declined` |
    /// `tentative`. Writes through to the provider then re-syncs.
    pub fn respond_to_event(
        &self,
        account_key: String,
        event_key: String,
        response: String,
    ) -> Result<(), FfiError> {
        self.rt.block_on(self.engine.respond_calendar_event_by_key(
            &account_key,
            &event_key,
            &response,
        ))?;
        log::info!("[ffi] respond_to_event {event_key} = {response}");
        Ok(())
    }

    /// Detect + parse an emailed meeting invite from a message's `text/calendar`
    /// attachment. Returns a JSON `ClientInvite` (method/summary/start/end/
    /// organizer/matched event/current status), or `None` if it isn't an invite.
    /// The client gates this on already seeing a `text/calendar` attachment, so
    /// it's only called for real invites (one live attachment fetch).
    pub fn invite_for_attachment(
        &self,
        account_key: String,
        message_key: String,
        attachment_id: String,
    ) -> Result<Option<String>, FfiError> {
        let inv = self.rt.block_on(self.engine.invite_from_attachment(
            &account_key,
            &message_key,
            &attachment_id,
        ))?;
        Ok(inv.map(|i| serde_json::to_string(&i)).transpose()?)
    }

    /// RSVP to an emailed invite. `response` is `accepted` | `declined` |
    /// `tentative`. Writes back to the source: the calendar API when the event is
    /// synced (Gmail/Microsoft), else an emailed `METHOD:REPLY` to the organizer.
    pub fn respond_to_invite(
        &self,
        account_key: String,
        message_key: String,
        attachment_id: String,
        response: String,
    ) -> Result<(), FfiError> {
        self.rt.block_on(self.engine.respond_invite(
            &account_key,
            &message_key,
            &attachment_id,
            &response,
        ))?;
        log::info!("[ffi] respond_to_invite {message_key}/{attachment_id} = {response}");
        Ok(())
    }

    /// Add an emailed `text/calendar` event to the account's calendar — the
    /// "Add to calendar" action for ICS attachments that aren't asking for an RSVP
    /// (`METHOD:PUBLISH` and friends). Writes through the provider's calendar API
    /// (Google/Graph) onto `calendar_provider_id`, or the account's primary writable
    /// calendar when that's `None`. Returns the local event key (empty if the resync
    /// hasn't landed the row yet — the add still succeeded).
    ///
    /// `device_timezone` (an IANA name) is used only when the ICS time is *floating*,
    /// i.e. carries neither a `Z` nor a `TZID`; a zoned ICS keeps its own zone.
    pub fn add_invite_to_calendar(
        &self,
        account_key: String,
        message_key: String,
        attachment_id: String,
        calendar_provider_id: Option<String>,
        device_timezone: Option<String>,
    ) -> Result<String, FfiError> {
        let key = self.rt.block_on(self.engine.add_invite_to_calendar(
            &account_key,
            &message_key,
            &attachment_id,
            calendar_provider_id,
            device_timezone,
        ))?;
        log::info!("[ffi] add_invite_to_calendar {message_key}/{attachment_id} -> {key}");
        Ok(key)
    }

    /// The meeting the summary lane found in a message body with no ICS attached,
    /// as `ClientInvite` JSON (`detected: true`, method PUBLISH), or `None`.
    /// Local SQLite only — no provider fetch.
    pub fn detected_invite(&self, account_key: String, message_key: String) -> Result<Option<String>, FfiError> {
        let inv = self.engine.detected_invite(&account_key, &message_key)?;
        Ok(inv.map(|i| serde_json::to_string(&i)).transpose()?)
    }

    /// "Add to calendar" for a detected meeting. Its time is floating (the sender's
    /// wall clock), so `device_timezone` is always the zone it's read in.
    pub fn add_detected_meeting_to_calendar(
        &self,
        account_key: String,
        message_key: String,
        calendar_provider_id: Option<String>,
        device_timezone: Option<String>,
    ) -> Result<String, FfiError> {
        let key = self.rt.block_on(self.engine.add_detected_meeting_to_calendar(
            &account_key,
            &message_key,
            calendar_provider_id,
            device_timezone,
        ))?;
        log::info!("[ffi] add_detected_meeting_to_calendar {message_key} -> {key}");
        Ok(key)
    }

    /// Update an event by its local key from a JSON `EventDraft` (same shape as
    /// `create_calendar_event`). Writes through to the provider then re-syncs.
    pub fn update_calendar_event(
        &self,
        account_key: String,
        event_key: String,
        draft_json: String,
    ) -> Result<(), FfiError> {
        let draft: crate::sync::calendar::EventDraft = serde_json::from_str(&draft_json)?;
        self.rt.block_on(self.engine.update_calendar_event_by_key(
            &account_key,
            &event_key,
            draft,
        ))?;
        log::info!("[ffi] update_calendar_event {event_key}");
        Ok(())
    }

    /// The repeat rule (RRULE body, e.g. `FREQ=WEEKLY;BYDAY=MO,WE`) of the series
    /// a synced instance belongs to, read live off the provider — the editor's
    /// prefill for a series edit. None for a one-off.
    pub fn calendar_series_rule(&self, account_key: String, event_key: String) -> Result<Option<String>, FfiError> {
        Ok(self.rt.block_on(self.engine.calendar_series_rule(&account_key, &event_key))?)
    }

    /// Delete an event by its local key. Writes through to the provider, removes
    /// the local row, then notifies clients.
    pub fn delete_calendar_event(
        &self,
        account_key: String,
        event_key: String,
    ) -> Result<(), FfiError> {
        self.rt.block_on(self.engine.delete_calendar_event_by_key(
            &account_key,
            &event_key,
        ))?;
        log::info!("[ffi] delete_calendar_event {event_key}");
        Ok(())
    }

    /// Tear the engine down (disconnect adapters, stop the loop). Call on app exit.
    pub fn shutdown(&self) {
        self.rt.block_on(self.engine.shutdown());
    }
}

/// FREE-LANE sampling constants exported over the FFI so the mobile LiteRT
/// engines read the very same values the desktop sidecar uses (see the
/// `bridge::ON_DEVICE_*` constants) instead of hand-mirroring literals.
#[uniffi::export]
pub fn on_device_temperature() -> f32 {
    crate::bridge::ON_DEVICE_TEMPERATURE
}

/// See [`on_device_temperature`].
#[uniffi::export]
pub fn on_device_top_k() -> i32 {
    crate::bridge::ON_DEVICE_TOP_K
}

/// See [`on_device_temperature`]. Total context budget (input + output).
#[uniffi::export]
pub fn on_device_context_tokens() -> u32 {
    crate::bridge::ON_DEVICE_CONTEXT_TOKENS
}
