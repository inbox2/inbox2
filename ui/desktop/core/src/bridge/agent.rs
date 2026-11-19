//! Bridge orchestration — turns the brief facts / a voice command into spoken text,
//! routing generation between OpenAI (in-Rust) and the host's on-device model, and
//! running the tool loop for action commands. Shared by all clients.

use super::{brief, email_voice, intent, openai::OpenAiClient, prompts, tools, LocalGenerator};
use crate::sync::engine::SyncEngine;
use chrono::{DateTime, Local, NaiveDate};
use rusqlite::params;
use serde_json::{json, Value};
use std::sync::Arc;

/// Which engine generates text.
#[derive(Clone, Copy, PartialEq, Eq)]
pub enum GenSource {
    OpenAi,
    OnDevice,
}

/// Per-call config supplied by the host (key + routing; the key lives in the
/// platform Keychain, never in core). Clone so the engine can hold it behind a
/// lock and hand a snapshot to the background triage worker without holding the
/// lock across an await.
#[derive(Clone)]
pub struct BridgeConfig {
    pub generation: GenSource,
    pub openai_key: Option<String>,
    pub model: String,
    /// The engine the host's on-device generator runs for `OnDevice` calls — a
    /// manifest model id (e.g. `qwen2.5-1.5b-instruct-q8`) or `apple-fm`. Handed
    /// to the generator as a per-call hint (so a forced run can't be shifted by a
    /// Settings change mid-flight) and recorded as triage provenance.
    pub on_device_model: Option<String>,
    /// Non-car ("normal") mode: produce a terse headline brief. Daily brief only.
    pub concise: bool,
    /// Short current-weather line appended to the end of a MORNING brief (already
    /// trimmed/empty-filtered by the FFI layer). `None` outside morning or when absent.
    pub weather: Option<String>,
}

impl BridgeConfig {
    fn key(&self) -> Option<&str> {
        self.openai_key.as_deref().filter(|k| !k.is_empty())
    }
}

/// Either spoken text, or an OpenAI error to surface verbatim with guidance.
pub enum Outcome {
    Ok(String),
    OpenAiError(String),
}

/// Generate the spoken daily brief.
pub async fn brief_text(
    engine: &SyncEngine,
    local: Option<&Arc<dyn LocalGenerator>>,
    config: &BridgeConfig,
) -> Outcome {
    // Real brief: assemble + commit the announcement gating.
    let b = match brief::assemble(engine.store(), Local::now()) {
        Ok(b) => b,
        Err(e) => return Outcome::Ok(format!("I couldn't read your inbox just now: {e}")),
    };
    let facts = b.facts_prompt();
    let cache_key = brief_cache_key(config.concise, &facts);
    // Append a morning weather line (outside the cache, so it never pollutes the
    // cached LLM text and refreshes each tap as the weather changes).
    let finish = |text: String| -> String {
        match (b.is_morning(), config.weather.as_deref()) {
            (true, Some(w)) if !w.is_empty() => format!("{text} {w}"),
            _ => text,
        }
    };
    // Use the pre-warmed text if it was composed for these exact facts (instant tap).
    if let Some(text) = engine.brief_cache_get(&cache_key) {
        return Outcome::Ok(finish(text));
    }
    let (instructions, fallback) = brief_prompt(&b, config.concise);
    let outcome = generate(local, config, &instructions, &facts, Some(fallback)).await;
    if let Outcome::Ok(text) = &outcome {
        engine.brief_cache_set(cache_key, text.clone());
        return Outcome::Ok(finish(text.clone()));
    }
    outcome
}

/// Cache key for the pre-warmed brief — verbosity-tagged so the concise (normal-mode)
/// and full (car-mode) variants can't serve each other's cached text for the same facts.
fn brief_cache_key(concise: bool, facts: &str) -> String {
    let tag = if concise { "concise" } else { "full" };
    format!("{tag}\n{facts}")
}

/// The (system instruction, deterministic fallback) for a brief at the given verbosity:
/// concise (normal mode) speaks a headline, full (car mode) the rundown. Shared by
/// `brief_text` and `brief_prewarm` so the two stay in lockstep (they share a cache key).
fn brief_prompt(b: &brief::Brief, concise: bool) -> (String, String) {
    if concise {
        (prompts::brief_instructions_concise(), b.spoken_concise())
    } else {
        (prompts::brief_instructions(), b.spoken_fallback())
    }
}

/// Pre-compose the spoken daily brief into the engine's cache WITHOUT committing the
/// announcement gating, so a subsequent tap ([`brief_text`]) speaks instantly. Called
/// on a timer while the app is active. Skips the (LLM) compose when the cache is
/// already warm for the current facts, so a quiet inbox costs nothing after the first.
pub async fn brief_prewarm(
    engine: &SyncEngine,
    local: Option<&Arc<dyn LocalGenerator>>,
    config: &BridgeConfig,
) {
    let b = match brief::assemble_preview(engine.store(), Local::now()) {
        Ok(b) => b,
        Err(_) => return,
    };
    let facts = b.facts_prompt();
    let cache_key = brief_cache_key(config.concise, &facts);
    if engine.brief_cache_get(&cache_key).is_some() {
        return; // already warm for these facts (+ verbosity)
    }
    let (instructions, fallback) = brief_prompt(&b, config.concise);
    if let Outcome::Ok(text) = generate(local, config, &instructions, &facts, Some(fallback)).await {
        engine.brief_cache_set(cache_key, text);
    }
}

/// Generate the spoken read-out of one email thread's latest message — a PREGENERATED
/// summary, never the raw body and never a bespoke prompt. `full` selects the depth:
/// `false` voices the one-line `ai_summary_short` (a quick "what's my latest email");
/// `true` voices the fuller `ai_summary_medium` ("read the full email aloud" — "full" is
/// the keyword). The triage worker precomputes both, so a current cache is voiced as-is
/// (instant). On a miss we regenerate with the SAME triage summarizer
/// ([`crate::ai_worker::summarize_conversation`]) and pick the requested tier. Shared by
/// the email-detail audio button and the read-aloud command path.
pub async fn email_voice_text(
    engine: &SyncEngine,
    local: Option<&Arc<dyn LocalGenerator>>,
    config: &BridgeConfig,
    conversation_key: &str,
    full: bool,
) -> Outcome {
    let readout = match email_voice::assemble(engine.store(), conversation_key) {
        Ok(Some(r)) => r,
        Ok(None) => return Outcome::Ok("That conversation has no messages to read.".into()),
        Err(e) => return Outcome::Ok(format!("I couldn't read that conversation just now: {e}")),
    };
    let tier = if full { "medium" } else { "short" };

    // Cache first: voice the triage worker's PREGENERATED summary (short/medium) when it's
    // current — but only when it's good. Regenerate (below) when the cache is a `rule:*`
    // snippet, or the user selected OpenAI but the cache came from on-device/a rule.
    let cached = if full { readout.fresh_medium() } else { readout.fresh_short() };
    if let Some(cached) = cached {
        let openai_wants_better =
            config.generation == GenSource::OpenAi && config.key().is_some() && !readout.cached_from_openai();
        let prefer_regen = !readout.cached_is_model() || openai_wants_better;
        if !prefer_regen {
            log::info!(
                "[bridge] email_voice: voicing CACHED {tier} (source={}) for \"{}\" — {}",
                readout.cache_source(),
                readout.subject,
                preview(cached)
            );
            return Outcome::Ok(sanitize_spoken(cached));
        }
        log::info!(
            "[bridge] email_voice: ignoring {tier} cache (source={}, openai_wants_better={}); regenerating for \"{}\"",
            readout.cache_source(),
            openai_wants_better,
            readout.subject
        );
    } else {
        log::info!("[bridge] email_voice: no fresh {tier} cache; regenerating for \"{}\"", readout.subject);
    }
    // Cache miss — run the SAME triage summarizer inline (returns (medium, short); falls
    // back to a deterministic summary when no model is reachable), then voice the tier.
    match crate::ai_worker::summarize_conversation(engine, local, config, conversation_key).await {
        Some((medium, short)) => {
            let text = if full { medium } else { short };
            log::info!("[bridge] email_voice: voicing REGENERATED {tier} for \"{}\" — {}", readout.subject, preview(&text));
            Outcome::Ok(sanitize_spoken(&text))
        }
        None => Outcome::Ok("That conversation has no messages to read.".into()),
    }
}

/// Whether the user asked to read the FULL email (the fuller medium summary) vs a quick
/// one-line summary. "full" is the keyword; a few natural synonyms also escalate.
fn wants_full(transcript: &str) -> bool {
    let s = transcript.to_lowercase();
    s.contains("full") || s.contains("whole") || s.contains("entire") || s.contains("in detail")
}

/// First ~80 chars of a summary on one line, for log lines.
fn preview(s: &str) -> String {
    let one_line: String = s.split_whitespace().collect::<Vec<_>>().join(" ");
    let truncated: String = one_line.chars().take(80).collect();
    if one_line.chars().count() > 80 {
        format!("\"{truncated}…\"")
    } else {
        format!("\"{truncated}\"")
    }
}

/// Generate tomorrow's spoken calendar preview.
pub async fn tomorrow_text(
    engine: &SyncEngine,
    local: Option<&Arc<dyn LocalGenerator>>,
    config: &BridgeConfig,
) -> Outcome {
    let a = match brief::tomorrow_agenda(engine.store(), Local::now()) {
        Ok(a) => a,
        Err(e) => return Outcome::Ok(format!("I couldn't read your calendar just now: {e}")),
    };
    generate(local, config, &prompts::tomorrow_instructions(), &a.facts_prompt(), Some(a.spoken_fallback())).await
}

/// Generate the spoken "highlights of the week" rundown.
pub async fn week_highlights_text(
    engine: &SyncEngine,
    local: Option<&Arc<dyn LocalGenerator>>,
    config: &BridgeConfig,
) -> Outcome {
    let w = match brief::week_highlights(engine.store(), Local::now()) {
        Ok(w) => w,
        Err(e) => return Outcome::Ok(format!("I couldn't read your calendar just now: {e}")),
    };
    generate(local, config, &prompts::week_instructions(), &w.facts_prompt(), Some(w.spoken_fallback())).await
}

/// Conversational reply to a voice command (no tool execution).
pub async fn reply_text(
    local: Option<&Arc<dyn LocalGenerator>>,
    config: &BridgeConfig,
    transcript: &str,
) -> Outcome {
    let t = transcript.trim();
    if t.is_empty() {
        return Outcome::Ok("I didn't catch that — hold the orb and try again.".into());
    }
    let system = prompts::chat_instructions(Local::now());
    generate(local, config, &system, t, Some(format!("You said: {t}."))).await
}

/// One inbox action parsed from a command (the fast keyword path + the mark/archive/
/// trash intents).
struct LocalAction {
    action: String,
    target: String,
}

/// The result of a voice command: speak something, ask to clarify, or hand a DRAFT to
/// the host to put on screen. The Bridge NEVER sends/saves — drafts are surfaced only.
pub enum CommandOutcome {
    /// Speak this and we're done.
    Speak(String),
    /// We weren't confident — speak this clarifying question, take no action.
    Clarify(String),
    /// Open a prefilled email compose screen (payload = draft slots). Not sent.
    DraftEmail { spoken: String, payload: Value },
    /// Open a prefilled new-event screen (payload = draft slots). Not saved.
    DraftEvent { spoken: String, payload: Value },
    /// OpenAI failed — surface verbatim with guidance.
    OpenAiError(String),
}

/// Interpret a voice command into one confidence-scored intent and act on it.
///
/// Flow: (1) a fast keyword pre-pass handles the trivial inbox verbs instantly; (2) else
/// classify into a structured intent ([`intent`]) via the configured lane — OpenAI or
/// the on-device `generate_intent` (Apple guided generation / Qwen text-JSON); (3) a
/// confidence gate asks to clarify rather than guess; (4) dispatch — queries speak an
/// answer, actions run locally, and reply/meeting intents return a DRAFT for the host to
/// show (never sent/saved).
pub async fn command(
    engine: &SyncEngine,
    local: Option<&Arc<dyn LocalGenerator>>,
    config: &BridgeConfig,
    transcript: &str,
) -> CommandOutcome {
    let t = transcript.trim();
    if t.is_empty() {
        return CommandOutcome::Clarify("I didn't catch that — hold the orb and try again.".into());
    }
    let current = engine.bridge_current_conv();

    // 1) Fast, model-free path for the common inbox verbs (read/mark/archive/trash).
    let acts = heuristic_actions(t, current.is_some());
    if !acts.is_empty() {
        return execute_inbox_actions(engine, local, config, acts, wants_full(t)).await;
    }

    // 2) Classify into a structured intent.
    let prompt = intent::intent_prompt(Local::now());
    let json = match classify_intent(local, config, &prompt, t).await {
        Ok(j) => j,
        Err(e) => {
            if config.generation == GenSource::OpenAi && config.key().is_some() {
                return CommandOutcome::OpenAiError(e);
            }
            return CommandOutcome::Speak(
                "I can't reach the assistant right now. Add an OpenAI key in Settings, or enable the \
                 on-device assistant under Brief writing."
                    .into(),
            );
        }
    };
    let Some(pi) = intent::parse_intent(&json) else {
        return CommandOutcome::Clarify("I didn't quite catch that — could you say it another way?".into());
    };

    // 3) Confidence gate — clarify rather than guess.
    if pi.intent == "unknown" || pi.confidence < intent::CONFIDENCE_FLOOR {
        let say = if pi.say.trim().is_empty() {
            "I'm not sure what you'd like me to do — you can ask about your agenda, what needs a reply, \
             or say something like \"draft a reply\" or \"schedule a meeting\"."
                .to_string()
        } else {
            sanitize_spoken(&pi.say)
        };
        return CommandOutcome::Clarify(say);
    }

    // 4) Dispatch.
    dispatch(engine, local, config, &pi, t).await
}

/// Route the chosen intent to a query answer, a local action, or a draft descriptor.
async fn dispatch(
    engine: &SyncEngine,
    local: Option<&Arc<dyn LocalGenerator>>,
    config: &BridgeConfig,
    pi: &intent::ParsedIntent,
    transcript: &str,
) -> CommandOutcome {
    let store = engine.store();
    let now = Local::now();
    match pi.intent.as_str() {
        // ── Read-only spoken answers ──
        "agenda_today" => speak_result(brief::agenda_today_spoken(store, now)),
        "needs_response" => speak_result(brief::needs_response_spoken(store, now)),
        "missed_last_week" => speak_result(brief::missed_last_week_spoken(store, now)),
        "meeting_detail" => {
            let date = pi
                .slot_str("date")
                .parse::<NaiveDate>()
                .ok()
                .or_else(|| NaiveDate::parse_from_str(&pi.slot_str("date"), "%Y-%m-%d").ok())
                .unwrap_or_else(|| now.date_naive());
            speak_result(brief::meeting_detail_spoken(store, now, date, pi.slot_u32("hour"), pi.slot_u32("minute")))
        }
        "read_email" => {
            let target = nonempty_or(pi.slot_str("target"), "last_unread");
            match resolve_target(engine, &target) {
                Some(key) => {
                    engine.set_bridge_current_conv(Some(key.clone()));
                    // Quick query → short summary; "read the full email" → medium.
                    outcome_to_command(email_voice_text(engine, local, config, &key, wants_full(transcript)).await)
                }
                None => CommandOutcome::Speak("There's no matching email to read.".into()),
            }
        }
        "brief" => outcome_to_command(brief_text(engine, local, config).await),
        // ── Local, reversible actions ──
        "mark_read" | "archive" | "trash" => {
            let target = nonempty_or(pi.slot_str("target"), "current");
            let acts = vec![LocalAction { action: pi.intent.clone(), target }];
            execute_inbox_actions(engine, local, config, acts, false).await
        }
        // ── Drafts (never sent/saved) ──
        "draft_reply" => draft_reply(engine, local, config, pi).await,
        "schedule_meeting" => draft_event(pi, now),
        // A Lore todo — local, sends nothing (the Bridge stays draft-only).
        "add_reminder" => add_reminder(store, pi, transcript),
        // ── Fallbacks ──
        "chat" => outcome_to_command(reply_text(local, config, transcript).await),
        _ => CommandOutcome::Clarify("I'm not sure what you meant — could you rephrase?".into()),
    }
}

/// The todo title an `add_reminder` intent names: its `text`, with `when` appended
/// when the model split it out ("Call the bank — tomorrow"). Falls back to the
/// transcript minus a leading "remind me to" when the model left `text` empty.
fn reminder_title(text: &str, when: &str, transcript: &str) -> String {
    let mut title = text.trim().trim_end_matches('.').to_string();
    if title.is_empty() {
        let t = transcript.trim().trim_end_matches('.');
        let lower = t.to_lowercase();
        title = ["remind me to ", "remind me ", "add a reminder to ", "add a todo to ", "add a reminder ", "add a todo "]
            .iter()
            .find(|p| lower.starts_with(*p))
            .and_then(|p| t.get(p.len()..))
            .map(str::to_string)
            .unwrap_or_else(|| t.to_string());
    }
    let when = when.trim();
    if !when.is_empty() && !title.to_lowercase().contains(&when.to_lowercase()) {
        title = format!("{title} — {when}");
    }
    let mut chars = title.chars();
    match chars.next() {
        Some(c) => c.to_uppercase().chain(chars).collect(),
        None => title,
    }
}

/// `add_reminder` → an email-less Lore todo (`lore_todos`). ponytail: `when` is kept
/// as text in the title, not parsed into a due date — add a column when Lore sorts by it.
fn add_reminder(store: &crate::sync::store::SyncStore, pi: &intent::ParsedIntent, transcript: &str) -> CommandOutcome {
    let title = reminder_title(&pi.slot_str("text"), &pi.slot_str("when"), transcript);
    if title.is_empty() {
        return CommandOutcome::Clarify("What should I add to your list?".into());
    }
    match store.add_lore_todo(&title, crate::sync::store::LORE_SOURCE_VOICE) {
        Ok(todo) => CommandOutcome::Speak(format!("Added: {}.", sanitize_spoken(&todo.title))),
        Err(e) => CommandOutcome::Speak(format!("I couldn't add that just now: {e}")),
    }
}

/// Classify the transcript into intent JSON via the configured lane. On-device uses
/// `generate_intent` (guided generation on Apple FM, text-JSON on Qwen).
async fn classify_intent(
    local: Option<&Arc<dyn LocalGenerator>>,
    config: &BridgeConfig,
    system: &str,
    user: &str,
) -> Result<String, String> {
    match config.generation {
        GenSource::OpenAi => {
            let key = config.key().ok_or("no OpenAI key configured")?;
            OpenAiClient::new(key.to_string()).generate(system, user, &config.model).await
        }
        GenSource::OnDevice => on_device_or_openai(local, config, system, user, true).await.map(|(t, _)| t),
    }
}

/// Generate via the on-device model, falling back to OpenAI when the on-device model is
/// unavailable or errors AND the host supplied a key. The key is passed in the config
/// regardless of the selected lane for exactly this reason — so the Bridge and the triage
/// worker keep working when Apple Intelligence is disabled or no local model is installed,
/// instead of silently degrading to deterministic snippets. `intent` selects the
/// guided-intent entry point over plain generation.
async fn on_device_or_openai(
    local: Option<&Arc<dyn LocalGenerator>>,
    config: &BridgeConfig,
    system: &str,
    user: &str,
    intent: bool,
) -> Result<(String, RanOn), String> {
    let available = match local {
        Some(g) => g.is_available().await,
        None => false,
    };
    if available {
        let g = local.expect("available implies Some");
        let model = config.on_device_model.clone();
        let r = if intent {
            g.generate_intent(system.to_string(), user.to_string(), model).await
        } else {
            g.generate(system.to_string(), user.to_string(), model).await
        };
        match r {
            Ok(t) if !t.trim().is_empty() => return Ok((t, RanOn::OnDevice)),
            // Empty or errored on-device — fall back to OpenAI if we can, else surface.
            Ok(_) if config.key().is_none() => return Err("on-device generator returned nothing".into()),
            Err(e) if config.key().is_none() => return Err(e),
            _ => log::warn!("[bridge] on-device generation failed; falling back to OpenAI"),
        }
    } else if config.key().is_none() {
        return Err("on-device generator unavailable (enable Apple Intelligence, install a local model, or add an OpenAI key)".into());
    } else {
        log::info!("[bridge] on-device model unavailable; using OpenAI key fallback");
    }
    let key = config.key().ok_or("no OpenAI key configured")?;
    let text = OpenAiClient::new(key.to_string()).generate(system, user, &config.model).await?;
    Ok((text, RanOn::OpenAi))
}

/// Run the fast-path inbox verbs (read/mark/archive/trash), focusing the conversation
/// for follow-ups; returns a spoken confirmation. Multi-turn "it" resolves via focus.
async fn execute_inbox_actions(
    engine: &SyncEngine,
    local: Option<&Arc<dyn LocalGenerator>>,
    config: &BridgeConfig,
    actions: Vec<LocalAction>,
    full: bool,
) -> CommandOutcome {
    let mut pieces: Vec<String> = Vec::new();
    let mut did_read = false;
    let mut did_destructive = false;
    for a in &actions {
        let Some(key) = resolve_target(engine, &a.target) else {
            pieces.push("I couldn't find that email.".into());
            continue;
        };
        engine.set_bridge_current_conv(Some(key.clone()));
        match a.action.as_str() {
            "read" => {
                did_read = true;
                if let Outcome::Ok(text) = email_voice_text(engine, local, config, &key, full).await {
                    pieces.push(text);
                }
            }
            "mark_read" => {
                let _ = tools::execute(engine, "mark_read", &json!({ "conversationId": key })).await;
                pieces.push("I've marked it as read.".into());
            }
            "archive" => {
                did_destructive = true;
                match tools::execute(engine, "archive", &json!({ "conversationId": key })).await {
                    Ok(_) => pieces.push("Archived.".into()),
                    Err(_) => pieces.push("I couldn't archive it.".into()),
                }
            }
            "trash" => {
                did_destructive = true;
                match tools::execute(engine, "trash", &json!({ "conversationId": key })).await {
                    Ok(_) => pieces.push("Moved it to trash.".into()),
                    Err(_) => pieces.push("I couldn't move it to trash.".into()),
                }
            }
            _ => {}
        }
    }
    if did_read && !did_destructive {
        pieces.push("Want me to archive it, or move it to trash?".into());
    }
    if pieces.is_empty() {
        return CommandOutcome::Clarify("I'm not sure which email you meant.".into());
    }
    CommandOutcome::Speak(pieces.join(" "))
}

/// Draft a reply to the focused/target conversation — composes a body via the LLM and
/// returns a `draft_email` descriptor. NEVER sends; the host opens the Compose screen.
async fn draft_reply(
    engine: &SyncEngine,
    local: Option<&Arc<dyn LocalGenerator>>,
    config: &BridgeConfig,
    pi: &intent::ParsedIntent,
) -> CommandOutcome {
    let target = nonempty_or(pi.slot_str("target"), "current");
    let Some(key) = resolve_target(engine, &target) else {
        return CommandOutcome::Clarify("Which email would you like to reply to?".into());
    };
    let Some((account_key, to, subject)) = reply_target(engine, &key) else {
        return CommandOutcome::Clarify("I couldn't work out who to reply to — open the thread and I'll help.".into());
    };
    // Compose a body from the thread + the user's gist.
    let instruction = pi.slot_str("instruction");
    let context = match email_voice::assemble(engine.store(), &key) {
        Ok(Some(readout)) => readout.summary_user_prompt(),
        _ => String::new(),
    };
    let user = format!(
        "Thread so far:\n{context}\n\nWrite a reply on the user's behalf. The user wants to say: {}",
        if instruction.is_empty() { "(no specifics given — write a brief, natural holding reply)" } else { &instruction }
    );
    let body = match generate_text(local, config, &prompts::draft_reply_instructions(), &user).await {
        Ok(b) => b,
        // No LLM available — hand over an empty draft rather than failing; the user writes it.
        Err(e) => {
            if config.generation == GenSource::OpenAi && config.key().is_some() {
                return CommandOutcome::OpenAiError(e);
            }
            String::new()
        }
    };
    engine.set_bridge_current_conv(Some(key.clone()));
    let payload = json!({
        "conversationId": key,
        "accountKey": account_key,
        "to": to,
        "subject": subject,
        "body": body,
    });
    CommandOutcome::DraftEmail {
        spoken: "Here's a draft reply — review it on screen and send when you're ready.".into(),
        payload,
    }
}

/// Build a `draft_event` descriptor from a schedule_meeting intent. NEVER saves; the
/// host opens the New Event screen prefilled (resolving attendee names to addresses).
fn draft_event(pi: &intent::ParsedIntent, now: chrono::DateTime<Local>) -> CommandOutcome {
    let title = nonempty_or(pi.slot_str("title"), "Meeting");
    // Default to one hour from now / 30 minutes if the model didn't resolve times.
    let start = pi.slot_str("start");
    let start = if start.is_empty() { (now + chrono::Duration::hours(1)).to_rfc3339() } else { start };
    let end = pi.slot_str("end");
    let end = if end.is_empty() {
        DateTime::parse_from_rfc3339(&start)
            .map(|s| (s + chrono::Duration::minutes(30)).to_rfc3339())
            .unwrap_or_else(|_| start.clone())
    } else {
        end
    };
    let payload = json!({
        "title": title,
        "startISO": start,
        "endISO": end,
        "allDay": false,
        "location": pi.slot_str("location"),
        "attendeeNames": pi.slot_list("attendee_names"),
    });
    CommandOutcome::DraftEvent {
        spoken: "Here's a draft meeting — check the details and add it when you're ready.".into(),
        payload,
    }
}

/// (account_key, reply-to address, "Re: subject") for a conversation — for draft_reply.
fn reply_target(engine: &SyncEngine, conversation_key: &str) -> Option<(String, String, String)> {
    let conn = engine.store().connection();
    let conn = conn.lock();
    let (account_key, to, subject): (String, String, Option<String>) = conn
        .query_row(
            "SELECT m.account_key, COALESCE(m.from_address,''), c.subject
             FROM messages m JOIN conversations c ON c.key = m.conversation_key
             WHERE m.conversation_key = ?1 AND m.account_key IS NOT NULL AND m.is_inbound = 1
             ORDER BY m.created_at DESC LIMIT 1",
            params![conversation_key],
            |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?)),
        )
        .ok()?;
    let subject = subject.unwrap_or_default();
    let subject = if subject.to_lowercase().starts_with("re:") { subject } else { format!("Re: {subject}") };
    Some((account_key, to, subject))
}

/// `s` if non-empty (after trim), else `fallback`.
fn nonempty_or(s: String, fallback: &str) -> String {
    if s.trim().is_empty() { fallback.to_string() } else { s }
}

/// Map a query helper's `Result<String>` to a spoken outcome. These strings are
/// deterministic (no model) but may carry user content — e.g. a calendar event's
/// markdown description — so sanitise emphasis/markup before it reaches TTS.
fn speak_result(r: rusqlite::Result<String>) -> CommandOutcome {
    match r {
        Ok(text) => CommandOutcome::Speak(sanitize_spoken(&text)),
        Err(_) => CommandOutcome::Speak("I couldn't read that just now — try again in a moment.".into()),
    }
}

/// Map a generation [`Outcome`] to a [`CommandOutcome`].
fn outcome_to_command(o: Outcome) -> CommandOutcome {
    match o {
        Outcome::Ok(text) => CommandOutcome::Speak(text),
        Outcome::OpenAiError(e) => CommandOutcome::OpenAiError(e),
    }
}

/// Deterministic keyword parse of a spoken inbox command — no model needed. Covers the
/// common verbs (read / mark read / archive / trash) and target (the unread one, the
/// latest, or the one in focus for "it"/"this"). Returns no actions when nothing
/// recognisable is present, so the caller can fall back to the model or to chat.
fn heuristic_actions(transcript: &str, has_current: bool) -> Vec<LocalAction> {
    let s = transcript.to_lowercase();

    let latest_word = s.contains("latest")
        || s.contains("newest")
        || s.contains("most recent")
        || s.contains("last email")
        || s.contains("last message")
        || s.contains("last received");
    let target = if s.contains("unread") {
        "last_unread"
    } else if latest_word {
        "latest"
    } else if has_current && (s.contains(" it") || s.starts_with("it ") || s == "it" || s.contains("this") || s.contains("that")) {
        "current"
    } else {
        "last_unread"
    };

    // "read" as the read-aloud verb — guarded so "mark as read" / "unread" don't match.
    let explicit_read = s.starts_with("read ")
        || s.contains("read the")
        || s.contains("read out")
        || s.contains("read me")
        || s.contains("read it")
        || s.contains("read this")
        || s.contains("read that")
        || s.contains("read my")
        || s.contains("read aloud");
    // Question / request phrasings about mail also mean "read it to me", e.g.
    // "what's my latest email", "show me the last unread", "any new messages".
    let mentions_mail = s.contains("email") || s.contains("message") || s.contains("mail") || s.contains("inbox");
    let asks = s.contains("what")
        || s.contains("show")
        || s.contains("tell")
        || s.contains("any")
        || s.contains("which")
        || s.contains("catch me up");
    let read_aloud = explicit_read || (mentions_mail && (asks || latest_word));
    let mark = s.contains("mark");
    let archive = s.contains("archive");
    let trash = s.contains("trash") || s.contains("delete") || s.contains(" bin");

    let mut actions = Vec::new();
    let push = |actions: &mut Vec<LocalAction>, action: &str| {
        actions.push(LocalAction { action: action.to_string(), target: target.to_string() });
    };
    if read_aloud {
        push(&mut actions, "read");
    }
    if mark {
        push(&mut actions, "mark_read");
    }
    if archive {
        push(&mut actions, "archive");
    }
    if trash {
        push(&mut actions, "trash");
    }
    actions
}

/// Resolve an action's `target` to a conversation key.
fn resolve_target(engine: &SyncEngine, target: &str) -> Option<String> {
    match target {
        "current" => engine.bridge_current_conv(),
        "latest" => email_voice::latest_key(engine.store()),
        _ => email_voice::latest_unread_key(engine.store()),
    }
}

/// Validate an OpenAI key (used by Settings "Test & save").
pub async fn validate_openai(key: &str) -> Result<(), String> {
    OpenAiClient::new(key.to_string()).validate().await
}

/// OpenAI text-to-speech → MP3 bytes (the natural agent voice). `voice` is one of the
/// OpenAI tts-1 voices (alloy/echo/fable/onyx/nova/shimmer); empty falls back to alloy.
pub async fn tts(key: &str, text: &str, voice: &str) -> Result<Vec<u8>, String> {
    let voice = if voice.is_empty() { "alloy" } else { voice };
    OpenAiClient::new(key.to_string()).speak(text, voice, "tts-1").await
}

/// OpenAI speech-to-text — transcribe WAV bytes (the paid STT lane).
pub async fn transcribe(key: &str, audio: Vec<u8>) -> Result<String, String> {
    OpenAiClient::new(key.to_string()).transcribe(audio, "gpt-4o-transcribe").await
}

/// Which engine actually produced a generation — the on-device lane falls back to
/// OpenAI (unavailable / errored / empty), so the configured lane alone would lie
/// in the provenance trail.
#[derive(Clone, Copy, PartialEq, Eq)]
pub enum RanOn {
    OpenAi,
    OnDevice,
}

/// Provenance tag for a generation that ran on OpenAI (the exact chat model).
pub fn openai_source(config: &BridgeConfig) -> String {
    format!("model:openai:{}", config.model)
}

/// Provenance tag for a generation that ran on the host's on-device engine — the
/// exact model when the host declared one, the bare lane otherwise.
pub fn on_device_source(config: &BridgeConfig) -> String {
    match config.on_device_model.as_deref().filter(|m| !m.is_empty()) {
        Some(m) => format!("model:on_device:{m}"),
        None => "model:on_device".to_string(),
    }
}

/// Route a plain generation through the configured lane, returning the raw text
/// or an error string. This is the single source of lane routing (OpenAI in-Rust
/// vs the host's on-device model) shared by the Bridge ([`generate`]) and the
/// background triage worker ([`crate::ai_worker`]) — so both honor exactly the
/// AI model the user selected in Settings.
pub async fn generate_text(
    local: Option<&Arc<dyn LocalGenerator>>,
    config: &BridgeConfig,
    system: &str,
    user: &str,
) -> Result<String, String> {
    generate_text_traced(local, config, system, user).await.map(|(t, _)| t)
}

/// [`generate_text`] plus the provenance tag of the engine that actually produced
/// the text (`model:openai:…` / `model:on_device:…`) — honest about the on-device
/// lane's OpenAI fallback. The triage paths record this alongside the summaries.
pub async fn generate_text_traced(
    local: Option<&Arc<dyn LocalGenerator>>,
    config: &BridgeConfig,
    system: &str,
    user: &str,
) -> Result<(String, String), String> {
    match config.generation {
        GenSource::OpenAi => {
            let key = config.key().ok_or("no OpenAI key configured")?;
            let text = OpenAiClient::new(key.to_string())
                .generate(system, user, &config.model)
                .await?;
            Ok((text, openai_source(config)))
        }
        GenSource::OnDevice => {
            let (text, ran) = on_device_or_openai(local, config, system, user, false).await?;
            let source = match ran {
                RanOn::OnDevice => on_device_source(config),
                RanOn::OpenAi => openai_source(config),
            };
            Ok((text, source))
        }
    }
}

/// Numbers above this aren't worth listening to — order numbers, tracking codes,
/// ticket IDs — the voice reads them digit by digit for seconds. Spoken text drops
/// any unbroken digit run valued above it; grouped figures like "15,000" survive
/// because the separator splits them into small runs. Mirrored by the mobile
/// Speakers, which voice stored summaries without passing through core.
const MAX_SPOKEN_NUMBER: u64 = 10_000;

/// Remove unbroken digit runs whose numeric value exceeds [`MAX_SPOKEN_NUMBER`]
/// (a run too long to even parse counts as large).
fn drop_large_numbers(s: &str) -> String {
    let mut out = String::with_capacity(s.len());
    let mut chars = s.chars().peekable();
    while let Some(c) = chars.next() {
        if c.is_ascii_digit() {
            let mut run = String::from(c);
            while let Some(d) = chars.peek().copied().filter(char::is_ascii_digit) {
                run.push(d);
                chars.next();
            }
            if run.parse::<u64>().is_ok_and(|n| n <= MAX_SPOKEN_NUMBER) {
                out.push_str(&run);
            }
        } else {
            out.push(c);
        }
    }
    out
}

/// Normalize model output for the TTS voice. Small on-device models leak literal
/// escape sequences into their "plain text" answers — a `\n` that arrives as the two
/// characters backslash+n gets read aloud as "backslash n" — along with markdown
/// emphasis the prompt asked them not to use. Strip both, drop unspeakably large
/// numbers, and collapse whitespace (speech has no use for layout); deterministic
/// fallbacks pass through unchanged.
pub fn sanitize_spoken(s: &str) -> String {
    let mut t = s
        .replace("\\n", " ")
        .replace("\\r", " ")
        .replace("\\t", " ")
        .replace("\\\"", "\"")
        .replace("\\'", "'")
        .replace('\\', " ");
    // Longest-first so "**"/"__" are removed before the single-char emphasis.
    for tok in ["**", "__", "`", "*", "_"] {
        t = t.replace(tok, "");
    }
    drop_large_numbers(&t).split_whitespace().collect::<Vec<_>>().join(" ")
}

/// Route a plain generation for the Bridge. When the host chose OpenAI (with a
/// key) and it fails, surface the error (don't silently fall back). Otherwise —
/// on-device, or OpenAI without a key — degrade to the fallback text.
async fn generate(
    local: Option<&Arc<dyn LocalGenerator>>,
    config: &BridgeConfig,
    system: &str,
    user: &str,
    fallback: Option<String>,
) -> Outcome {
    match generate_text(local, config, system, user).await {
        Ok(text) => Outcome::Ok(sanitize_spoken(&text)),
        Err(e) => {
            if config.generation == GenSource::OpenAi && config.key().is_some() {
                Outcome::OpenAiError(e)
            } else {
                Outcome::Ok(fallback.unwrap_or_default())
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn brief_cache_key_separates_verbosity() {
        let facts = "Open with: \"Good morning\".\nUnread messages: 3.\n";
        let concise = brief_cache_key(true, facts);
        let full = brief_cache_key(false, facts);
        assert_ne!(concise, full, "concise and full must not share a cache slot");
        assert!(concise.starts_with("concise\n"));
        assert!(full.starts_with("full\n"));
        assert!(concise.ends_with(facts) && full.ends_with(facts));
    }

    #[test]
    fn heuristic_reads_and_marks_the_unread_one() {
        let a = heuristic_actions("read the last unread message and mark it", false);
        assert_eq!(a.len(), 2);
        assert_eq!(a[0].action, "read");
        assert_eq!(a[0].target, "last_unread");
        assert_eq!(a[1].action, "mark_read");
        assert_eq!(a[1].target, "last_unread");
    }

    #[test]
    fn heuristic_mark_as_read_does_not_trigger_read_aloud() {
        // "as read" / "unread" must NOT be read-aloud.
        let a = heuristic_actions("mark it as read", true);
        assert_eq!(a.len(), 1);
        assert_eq!(a[0].action, "mark_read");
        assert_eq!(a[0].target, "current");
    }

    #[test]
    fn heuristic_follow_up_resolves_it_to_current() {
        assert_eq!(heuristic_actions("archive it", true).first().map(|a| (a.action.as_str(), a.target.as_str())), Some(("archive", "current")));
        assert_eq!(heuristic_actions("delete this one", true).first().map(|a| a.action.clone()), Some("trash".to_string()));
    }

    #[test]
    fn heuristic_reads_question_and_latest_phrasings() {
        // The exact phrasing that previously fell through to the slow model path.
        let a = heuristic_actions("what's my latest email that I received", false);
        assert_eq!(a.len(), 1);
        assert_eq!(a[0].action, "read");
        assert_eq!(a[0].target, "latest");
        // Other natural phrasings.
        assert_eq!(heuristic_actions("show me the last unread message", false).first().map(|a| (a.action.as_str(), a.target.as_str())), Some(("read", "last_unread")));
        assert_eq!(heuristic_actions("any new emails", false).first().map(|a| a.action.clone()), Some("read".to_string()));
    }

    #[test]
    fn heuristic_empty_for_non_command() {
        // A question with no mail mention is not an inbox command.
        assert!(heuristic_actions("what's the weather like", false).is_empty());
    }

    #[test]
    fn sanitize_spoken_strips_escapes_and_markdown() {
        // Literal backslash-escapes (two characters) leaked by small models — the
        // field bug: the voice read "backslash n" aloud.
        assert_eq!(sanitize_spoken("Hi.\\nYou have **3** new emails.\\n"), "Hi. You have 3 new emails.");
        assert_eq!(sanitize_spoken("a `code` thing \\\"quoted\\\""), "a code thing \"quoted\"");
        assert_eq!(sanitize_spoken("stray \\ backslash"), "stray backslash");
        // Single-char emphasis (e.g. a calendar event's markdown notes) must not be
        // read aloud as "asterisk" — strip it like the double-char form.
        assert_eq!(sanitize_spoken("It's about: *Q3 planning* and _budget_"), "It's about: Q3 planning and budget");
        assert_eq!(sanitize_spoken("agenda: * intro * demo"), "agenda: intro demo");
        // Plain prose (including real newlines) just gets whitespace-normalized.
        assert_eq!(sanitize_spoken("Good morning.\nTwo meetings today."), "Good morning. Two meetings today.");
        assert_eq!(sanitize_spoken("already clean"), "already clean");
    }

    #[test]
    fn sanitize_spoken_drops_unspeakable_numbers() {
        // IDs / tracking codes the voice would read digit by digit.
        assert_eq!(sanitize_spoken("Order 4827261934 has shipped."), "Order has shipped.");
        assert_eq!(sanitize_spoken("ref INV-99999881234567890123 is overdue"), "ref INV- is overdue");
        // Small and ceiling-value numbers stay; separators keep grouped figures speakable.
        assert_eq!(sanitize_spoken("room 4021 at 10000 feet"), "room 4021 at 10000 feet");
        assert_eq!(sanitize_spoken("a $15,000 budget for 2026"), "a $15,000 budget for 2026");
    }

    #[test]
    fn lore_reminder_title_from_slots_or_transcript() {
        assert_eq!(reminder_title("call the bank", "tomorrow", ""), "Call the bank — tomorrow");
        assert_eq!(reminder_title("send the invoice on Friday", "Friday", ""), "Send the invoice on Friday");
        assert_eq!(reminder_title("", "", "Remind me to water the plants."), "Water the plants");
        assert_eq!(reminder_title("", "", ""), "");
    }

    #[test]
    fn lore_add_reminder_creates_a_todo() {
        let store = crate::sync::store::SyncStore::new_in_memory().unwrap();
        let pi = intent::parse_intent(
            r#"{"intent":"add_reminder","confidence":0.9,"slots":{"text":"call the bank","when":"tomorrow"},"say":""}"#,
        )
        .unwrap();
        match add_reminder(&store, &pi, "remind me to call the bank tomorrow") {
            CommandOutcome::Speak(s) => assert_eq!(s, "Added: Call the bank — tomorrow."),
            _ => panic!("expected a spoken confirmation"),
        }
        let open = store.open_lore_todos().unwrap();
        assert_eq!(open.len(), 1);
        assert_eq!(open[0].source, "voice");
    }

    #[test]
    fn nonempty_or_falls_back() {
        assert_eq!(nonempty_or(String::new(), "x"), "x");
        assert_eq!(nonempty_or("  ".into(), "x"), "x");
        assert_eq!(nonempty_or("y".into(), "x"), "y");
    }
}
