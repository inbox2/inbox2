//! Shared LLM prompt templates for the Bridge. Single source across all clients.
//!
//! The prompt TEXTS live in `prompts.toml`, embedded at compile time as the default
//! set. Hosts may inject a user-edited override file at runtime via [`set_overrides`]
//! (desktop loads `<app data dir>/prompts.toml`; mobile passes the text over FFI).
//! Sections missing from an override fall back to the embedded defaults, so an
//! override file only needs the prompts the user actually changed.
//!
//! Placeholders substituted at render time: `{now}` (chat — the spelled-out local
//! clock) and `{now}`/`{intents}` (intent). Triage classification isn't prompted:
//! Jev does it (`docs/Triage.md`); the retired `[triage]` section is ignored when
//! an old override file still carries it.

use chrono::{DateTime, Local};
use serde::Deserialize;
use std::sync::{OnceLock, RwLock};

/// The embedded default template file — also what a Settings editor shows as the
/// starting point / "reset to defaults" content.
pub const DEFAULT_TOML: &str = include_str!("prompts.toml");

/// One `[section]` of the template file.
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Section {
    system: String,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct OpenAiSection {
    chat_model: Option<String>,
}

/// The parsed template file. Every field is optional so an override file may carry
/// only the sections it changes; the embedded default file carries all of them
/// (enforced by `defaults()` and the unit tests).
#[derive(Deserialize, Default)]
#[serde(deny_unknown_fields)]
struct PromptFile {
    chat: Option<Section>,
    brief: Option<Section>,
    tomorrow: Option<Section>,
    week: Option<Section>,
    draft_reply: Option<Section>,
    summary: Option<Section>,
    /// Retired (Jev classifies now). Accepted and ignored so a user's saved
    /// override file from before the switch still loads.
    triage: Option<toml::Value>,
    intent: Option<Section>,
    smart_replies: Option<Section>,
    summarize: Option<Section>,
    openai: Option<OpenAiSection>,
}

impl PromptFile {
    fn parse(text: &str) -> Result<Self, String> {
        toml::from_str(text).map_err(|e| format!("invalid prompts file: {e}"))
    }
}

fn defaults() -> &'static PromptFile {
    static DEFAULTS: OnceLock<PromptFile> = OnceLock::new();
    DEFAULTS.get_or_init(|| {
        PromptFile::parse(DEFAULT_TOML).expect("embedded prompts.toml must parse")
    })
}

fn overrides() -> &'static RwLock<Option<PromptFile>> {
    static OVERRIDES: RwLock<Option<PromptFile>> = RwLock::new(None);
    &OVERRIDES
}

/// Parse + validate an override file's text (the same rules [`set_overrides`]
/// enforces): valid TOML, known sections only, `[intent]` keeps `{intents}`.
fn validate(text: &str) -> Result<PromptFile, String> {
    let mut file = PromptFile::parse(text)?;
    if file.triage.take().is_some() {
        log::info!("[prompts] ignoring the retired [triage] section (Jev classifies now; see [summary])");
    }
    if let Some(intent) = &file.intent {
        if !intent.system.contains("{intents}") {
            return Err(
                "the [intent] prompt must contain the {intents} placeholder — \
                 the intent catalog is fixed by the app"
                    .into(),
            );
        }
    }
    Ok(file)
}

/// Install (or with `None` clear) a user-edited prompt override file. Validates
/// before installing — on `Err` the previously active prompts stay in effect, so a
/// broken edit can never take the assistant down. Sections absent from the override
/// keep their embedded defaults.
pub fn set_overrides(toml_text: Option<&str>) -> Result<(), String> {
    let parsed = toml_text.map(validate).transpose()?;
    *overrides().write().expect("prompts override lock poisoned") = parsed;
    Ok(())
}

/// The template file's section keys, in display order — the per-section editor's
/// menu. `openai` carries the chat model name; every other section a system prompt.
pub const SECTION_KEYS: [&str; 10] = [
    "chat",
    "brief",
    "tomorrow",
    "week",
    "draft_reply",
    "summary",
    "intent",
    "smart_replies",
    "summarize",
    "openai",
];

/// One section's raw text in a parsed file (`openai` → `chat_model`, else `system`).
fn file_section_text(f: &PromptFile, key: &str) -> Option<String> {
    match key {
        "chat" => f.chat.as_ref().map(|s| s.system.clone()),
        "brief" => f.brief.as_ref().map(|s| s.system.clone()),
        "tomorrow" => f.tomorrow.as_ref().map(|s| s.system.clone()),
        "week" => f.week.as_ref().map(|s| s.system.clone()),
        "draft_reply" => f.draft_reply.as_ref().map(|s| s.system.clone()),
        "summary" => f.summary.as_ref().map(|s| s.system.clone()),
        "intent" => f.intent.as_ref().map(|s| s.system.clone()),
        "smart_replies" => f.smart_replies.as_ref().map(|s| s.system.clone()),
        "summarize" => f.summarize.as_ref().map(|s| s.system.clone()),
        "openai" => f.openai.as_ref().and_then(|o| o.chat_model.clone()),
        _ => None,
    }
}

/// Per-section view of an override file (or the embedded defaults with `None`):
/// every key in [`SECTION_KEYS`] with the override's text where present, the
/// embedded default otherwise. Raw template texts — placeholders like `{now}`
/// are NOT substituted. Drives the mobile per-section editors.
pub fn sections(toml_text: Option<&str>) -> Result<Vec<(String, String)>, String> {
    let over = toml_text.map(validate).transpose()?;
    Ok(SECTION_KEYS
        .iter()
        .map(|k| {
            let text = over
                .as_ref()
                .and_then(|f| file_section_text(f, k))
                .or_else(|| file_section_text(defaults(), k))
                .unwrap_or_default();
            (k.to_string(), text)
        })
        .collect())
}

/// Build a validated override file from per-section texts (the inverse of
/// [`sections`]). Sections equal to the embedded default are omitted — override
/// semantics: absent = default — so the file only carries real edits. Returns an
/// empty string when nothing differs (the host should clear its override). Does
/// not install; pass the result to [`set_overrides`].
pub fn build_overrides(edited: &[(String, String)]) -> Result<String, String> {
    let mut root = toml::value::Table::new();
    for (key, text) in edited {
        let default_text = file_section_text(defaults(), key)
            .ok_or_else(|| format!("unknown prompt section: {key}"))?;
        if *text == default_text {
            continue;
        }
        let mut table = toml::value::Table::new();
        let field = if key == "openai" { "chat_model" } else { "system" };
        table.insert(field.into(), toml::Value::String(text.clone()));
        root.insert(key.clone(), toml::Value::Table(table));
    }
    if root.is_empty() {
        return Ok(String::new());
    }
    let text = toml::to_string_pretty(&toml::Value::Table(root))
        .map_err(|e| format!("cannot serialize prompts: {e}"))?;
    validate(&text)?;
    Ok(text)
}

/// Resolve one section's text: the override file if it carries the section, the
/// embedded default otherwise.
fn section(pick: fn(&PromptFile) -> Option<&Section>) -> String {
    let guard = overrides().read().expect("prompts override lock poisoned");
    if let Some(text) = guard.as_ref().and_then(|f| pick(f)).map(|s| s.system.clone()) {
        return text;
    }
    pick(defaults())
        .expect("embedded prompts.toml must carry every section")
        .system
        .clone()
}

/// System instruction for conversational voice replies / commands. `{now}` is filled
/// with the device clock so the model answers "what time is it" / "what's the date"
/// accurately; every OTHER off-topic general-knowledge question is redirected back to
/// the inbox/calendar rather than answered freely.
pub fn chat_instructions(now: DateTime<Local>) -> String {
    let now_fmt = now.format("%A, %B %-d, %Y at %-I:%M %p").to_string();
    section(|f| f.chat.as_ref()).replace("{now}", &now_fmt)
}

/// System instruction for turning the assembled brief facts into spoken English.
pub fn brief_instructions() -> String {
    section(|f| f.brief.as_ref())
}

/// System instruction for tomorrow's spoken calendar preview.
pub fn tomorrow_instructions() -> String {
    section(|f| f.tomorrow.as_ref())
}

/// Concise variant of [`brief_instructions`] for non-car ("normal") mode: layers a
/// brevity directive over the user's brief prompt so it stays a one-or-two sentence
/// headline rather than a full rundown. Reuses the editable brief prompt as the base.
pub fn brief_instructions_concise() -> String {
    format!(
        "{}\n\nKeep it extremely brief — at most two short sentences. Give only the \
         headline: the greeting, the unread count, and at most the single most pressing \
         item. Do NOT enumerate individual messages, meetings, or open questions.",
        brief_instructions()
    )
}

/// System instruction for the conversational "highlights of the week" rundown.
pub fn week_instructions() -> String {
    section(|f| f.week.as_ref())
}

// Email read-out summaries are NOT generated here — the read-out uses the triage worker's
// pregenerated `ai_summary_short` / `ai_summary_medium`, falling back to the same
// `[summary]` summarizer (`ai_worker::summarize_conversation`) on a cache miss.

/// System instruction for composing a DRAFT reply body (the `draft_reply` intent). The
/// result is shown on the Compose screen for the user to review and send — it is never
/// sent automatically, so it's fine to produce a complete, ready-to-edit draft.
pub fn draft_reply_instructions() -> String {
    section(|f| f.draft_reply.as_ref())
}

/// System instruction for the voice-command intent classifier
/// ([`crate::bridge::intent`]). `{now}` is the spelled-out current time and
/// `{intents}` the rendered intent catalog — the catalog stays single-sourced
/// from `intent::CATALOG`, so adding an intent updates the prompt automatically.
pub fn intent_instructions(now: &str, intents: &str) -> String {
    section(|f| f.intent.as_ref()).replace("{now}", now).replace("{intents}", intents)
}

/// System instruction for the Tier B smart-reply suggestions. The model must
/// answer with a JSON array of exactly 3 strings — the caller parses it as such.
pub fn smart_replies_instructions() -> String {
    section(|f| f.smart_replies.as_ref())
}

/// System instruction for the Tier B one-shot thread summarization.
pub fn summarize_instructions() -> String {
    section(|f| f.summarize.as_ref())
}

/// Default chat model for the OpenAI generation path (overridable via `[openai]`).
pub const OPENAI_CHAT_MODEL: &str = "gpt-4o-mini";

/// The chat model for the OpenAI generation path: the override file's
/// `[openai] chat_model` when set, [`OPENAI_CHAT_MODEL`] otherwise.
pub fn openai_chat_model() -> String {
    let guard = overrides().read().expect("prompts override lock poisoned");
    guard
        .as_ref()
        .and_then(|f| f.openai.as_ref())
        .and_then(|o| o.chat_model.clone())
        .or_else(|| defaults().openai.as_ref().and_then(|o| o.chat_model.clone()))
        .unwrap_or_else(|| OPENAI_CHAT_MODEL.to_string())
}

/// System instruction for the triage worker's summaries ([`crate::ai_worker`]):
/// one strict-JSON `{"medium","short"}` response. Summary only — Jev classifies.
pub fn summary_instructions() -> String {
    section(|f| f.summary.as_ref())
}

#[cfg(test)]
mod tests {
    use super::*;
    use chrono::TimeZone;
    use std::sync::Mutex;

    /// The override registry is process-global; tests that touch it (or read
    /// through it) serialize on this lock so they can't observe each other's state.
    static TEST_LOCK: Mutex<()> = Mutex::new(());

    #[test]
    fn embedded_defaults_carry_every_section() {
        let f = PromptFile::parse(DEFAULT_TOML).expect("default file parses");
        for (name, s) in [
            ("chat", &f.chat),
            ("brief", &f.brief),
            ("tomorrow", &f.tomorrow),
            ("week", &f.week),
            ("draft_reply", &f.draft_reply),
            ("summary", &f.summary),
            ("intent", &f.intent),
            ("smart_replies", &f.smart_replies),
            ("summarize", &f.summarize),
        ] {
            assert!(s.is_some(), "default prompts.toml missing [{name}]");
        }
        assert!(f.chat.unwrap().system.contains("{now}"));
        assert!(f.triage.is_none(), "the retired [triage] section is gone from the defaults");
        let intent = f.intent.unwrap().system;
        assert!(intent.contains("{intents}") && intent.contains("{now}"));
        assert_eq!(f.openai.unwrap().chat_model.as_deref(), Some(OPENAI_CHAT_MODEL));
    }

    #[test]
    fn chat_instructions_embed_time_and_redirect_rule() {
        let _g = TEST_LOCK.lock().unwrap();
        let now = Local.with_ymd_and_hms(2026, 6, 9, 14, 14, 0).unwrap();
        let p = chat_instructions(now);
        // The natural-language clock is embedded so time/date questions answer accurately.
        assert!(p.contains("Tuesday, June 9, 2026 at 2:14 PM"), "missing embedded time: {p}");
        // Off-topic general-knowledge questions are redirected, not answered freely.
        assert!(p.contains("inbox and calendar"));
        assert!(p.to_lowercase().contains("do not answer") || p.contains("do NOT answer"));
    }

    #[test]
    fn summary_prompt_asks_for_summaries_only() {
        let _g = TEST_LOCK.lock().unwrap();
        let p = summary_instructions();
        assert!(p.contains("\"medium\"") && p.contains("\"short\""));
        assert!(p.contains("\"title\""), "the Lore to-do title rides on the same call");
        assert!(!p.contains("\"label\""), "classification is Jev's job");
    }

    #[test]
    fn sections_and_build_round_trip() {
        let _g = TEST_LOCK.lock().unwrap();

        // Defaults view: every key present, texts = the embedded file's.
        let all = sections(None).unwrap();
        assert_eq!(all.len(), SECTION_KEYS.len());
        assert_eq!(all[0].0, "chat");
        assert!(all.iter().find(|(k, _)| k == "summary").unwrap().1.contains("\"medium\""));
        assert!(all.iter().all(|(k, _)| k != "triage"));
        assert_eq!(all.iter().find(|(k, _)| k == "openai").unwrap().1, OPENAI_CHAT_MODEL);

        // Unedited sections build to "no override".
        assert_eq!(build_overrides(&all).unwrap(), "");

        // Edit one section: the built file carries ONLY that section, parses,
        // installs, and round-trips through sections().
        let mut edited = all.clone();
        edited.iter_mut().find(|(k, _)| k == "brief").unwrap().1 = "Speak like a pirate.".into();
        let toml_text = build_overrides(&edited).unwrap();
        assert!(toml_text.contains("[brief]"));
        assert!(!toml_text.contains("[chat]"), "unedited sections must be omitted: {toml_text}");
        let view = sections(Some(&toml_text)).unwrap();
        assert_eq!(view.iter().find(|(k, _)| k == "brief").unwrap().1, "Speak like a pirate.");
        set_overrides(Some(&toml_text)).unwrap();
        assert_eq!(brief_instructions(), "Speak like a pirate.");
        set_overrides(None).unwrap();

        // An intent edit that drops {intents} is rejected at build time.
        let mut bad = all.clone();
        bad.iter_mut().find(|(k, _)| k == "intent").unwrap().1 = "just guess".into();
        assert!(build_overrides(&bad).is_err());

        // Unknown keys are rejected, and a quote-heavy edit serializes safely.
        assert!(build_overrides(&[("nope".into(), "x".into())]).is_err());
        let mut quoted = all.clone();
        quoted.iter_mut().find(|(k, _)| k == "week").unwrap().1 = "say '''hi''' \"ok\"".into();
        let toml_text = build_overrides(&quoted).unwrap();
        let view = sections(Some(&toml_text)).unwrap();
        assert_eq!(view.iter().find(|(k, _)| k == "week").unwrap().1, "say '''hi''' \"ok\"");
    }

    #[test]
    fn overrides_replace_validate_and_clear() {
        let _g = TEST_LOCK.lock().unwrap();

        // A partial override changes its section and leaves the rest on defaults.
        set_overrides(Some(
            "[brief]\nsystem = 'Speak like a pirate.'\n[openai]\nchat_model = 'gpt-test'",
        ))
        .unwrap();
        assert_eq!(brief_instructions(), "Speak like a pirate.");
        assert_eq!(openai_chat_model(), "gpt-test");
        assert!(tomorrow_instructions().contains("tomorrow's calendar"));

        // Invalid TOML is rejected and the active prompts stay untouched.
        assert!(set_overrides(Some("not [valid toml")).is_err());
        assert_eq!(brief_instructions(), "Speak like a pirate.");

        // Unknown keys (typos) are rejected, not silently ignored.
        assert!(set_overrides(Some("[breif]\nsystem = 'x'")).is_err());

        // A saved override from before Jev still loads; its [triage] is ignored.
        set_overrides(Some("[triage]\nsystem = 'Pick a label from {labels}'\n[brief]\nsystem = 'Arr.'")).unwrap();
        assert_eq!(brief_instructions(), "Arr.");
        assert!(sections(Some("[triage]\nsystem = 'x'")).is_ok());

        // An intent override must keep the {intents} placeholder.
        assert!(set_overrides(Some("[intent]\nsystem = 'just guess an intent'")).is_err());

        // Clearing restores the embedded defaults.
        set_overrides(None).unwrap();
        assert!(brief_instructions().contains("spoken briefing"));
        assert_eq!(openai_chat_model(), OPENAI_CHAT_MODEL);
    }
}
