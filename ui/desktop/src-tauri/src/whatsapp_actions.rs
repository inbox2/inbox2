//! Acting on local WhatsApp (desktop, macOS): open a chat, mark it read, send
//! text and attachments — through WhatsApp Desktop itself, never around it.
//!
//! - **Open a chat** by its JID with WhatsApp's own widget link
//!   `whatsapp://widget-open-app/open-chat?chatJid=…` (groups and LID-only
//!   contacts too; `whatsapp://send?phone=` reaches neither). No permission needed.
//! - **Mark read** = the pane's WhatsApp button (green while the chat has
//!   unread messages): it shows the chat in WhatsApp, which reads it there
//!   (blue ticks go out as usual).
//! - **Send** types / pastes into WhatsApp's own window and presses its Send
//!   button (whatsapp_ax.rs): needs Accessibility, asked for on the first
//!   send. Everything happens in the background; if WhatsApp ignores
//!   keys while it isn't the active app, it is shown for a moment and Inbox2
//!   comes back to the front.
//!
//! Every action is checked against WhatsApp's database afterwards
//! (whatsapp.rs reader): a send counts only when exactly the expected number of
//! new outgoing messages appear in that chat. An attachment preview holding
//! more than one item is cancelled, never sent (a repeating ⌘V once sent an
//! album of ~100 copies during testing).

use crate::whatsapp::with_conn;
#[cfg(target_os = "macos")]
use crate::whatsapp_ax::{self as ax, Ax};
use rusqlite::{params, OptionalExtension};
use serde::Serialize;
use std::io::{Read, Seek, SeekFrom};
use std::path::{Path, PathBuf};
use std::sync::Mutex;
use std::time::Duration;

/// Errors starting with this mean "Inbox2 needs Accessibility": the UI shows a
/// button to the right pane of System Settings.
pub const NO_AX: &str = "no_ax: Sending needs Inbox2 under System Settings › Privacy & Security › Accessibility. Turn it on, then try again.";

/// One action at a time: two sends must never interleave in WhatsApp's window.
static BUSY: Mutex<()> = Mutex::new(());

const COMPOSER: &str = "ChatBar_ComposerTextView";
const HEADER: &str = "NavigationBar_HeaderViewButton";
const SEND: &str = "ChatBar_SendButton";
const MESSAGES: &str = "ChatMessagesTableView";
const BUBBLE: &str = "WAMessageBubbleTableViewCell";
const PREVIEW_SEND: [&str; 3] = ["WAMultiSendBottomBarView_SendButton", "DocumentShareView_SendButton", "CaptionBar_SendButton"];
const PREVIEW_ITEM: &str = "MultiSend_MediaBrowserItem";
const PREVIEW_BACK: &str = "MultiSend_BackButton";

#[derive(Serialize)]
pub struct WaActionsStatus {
    /// Inbox2 may use Accessibility (sending works).
    pub trusted: bool,
    /// WhatsApp Desktop is running.
    pub running: bool,
}

#[tauri::command]
pub fn wa_actions_status() -> WaActionsStatus {
    #[cfg(target_os = "macos")]
    return WaActionsStatus { trusted: ax::trusted(false), running: ax::pid().is_some() };
    #[cfg(not(target_os = "macos"))]
    WaActionsStatus { trusted: false, running: false }
}

/// Ask macOS for Accessibility: adds Inbox2 to the list and shows the system
/// prompt. Only the first WhatsApp send calls this. → trusted now?
#[tauri::command]
pub fn wa_request_accessibility() -> bool {
    #[cfg(target_os = "macos")]
    return ax::trusted(true);
    #[cfg(not(target_os = "macos"))]
    false
}

#[tauri::command]
pub fn wa_open_accessibility_settings(app: tauri::AppHandle) -> Result<(), String> {
    use tauri_plugin_opener::OpenerExt;
    app.opener()
        .open_url("x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility", None::<&str>)
        .map_err(|e| e.to_string())
}

/// Show the chat in WhatsApp itself (brings WhatsApp to the front).
#[tauri::command]
pub async fn wa_open_in_whatsapp(chat_id: i64) -> Result<(), String> {
    // Under the same lock as sends: switching chats between a send's check and
    // its Send press would deliver it to the wrong chat.
    run(move || {
        let jid = chat(chat_id)?.jid;
        #[cfg(target_os = "macos")]
        let log = LogTail::start();
        open_link(&jid, false)?;
        #[cfg(target_os = "macos")]
        scroll_to_latest(&log, &jid);
        Ok(())
    })
    .await
}

/// WhatsApp opens an unread chat at its first unread message: bring the newest
/// one into view. Best effort, only with Accessibility already granted (opening
/// never prompts for it).
/// ponytail: AXScrollToVisible on the last bubble the table exposes; WhatsApp's
/// own jump-to-bottom button if a long unread run turns out not to reach it.
#[cfg(target_os = "macos")]
fn scroll_to_latest(log: &LogTail, jid: &str) {
    if !ax::trusted(false) || ax::wait_for(Duration::from_secs(3), || log.selected(jid).then_some(())).is_none() {
        return;
    }
    let Some(pid) = ax::pid() else { return };
    let last = ax::wait_for(Duration::from_secs(2), || {
        let table = window(pid)?.find(MESSAGES)?;
        table.children().into_iter().rev().find(|c| c.identifier().as_deref() == Some(BUBBLE))
    });
    if let Some(cell) = last {
        let _ = cell.perform("AXScrollToVisible");
    }
}

/// Send attachments (one message each, in order) and then the text, if any.
#[tauri::command]
pub async fn wa_send(chat_id: i64, text: Option<String>, files: Vec<String>) -> Result<(), String> {
    let text = text.map(|t| t.trim().to_string()).filter(|t| !t.is_empty());
    if text.is_none() && files.is_empty() {
        return Err("Nothing to send".into());
    }
    for f in &files {
        if !Path::new(f).is_file() {
            return Err(format!("{f} is not a file"));
        }
    }
    run(move || send(chat_id, text, files)).await
}

/// The native file picker for attachments. → chosen paths (empty = cancelled).
#[tauri::command]
pub async fn wa_pick_files(window: tauri::WebviewWindow) -> Result<Vec<String>, String> {
    let (tx, rx) = tokio::sync::oneshot::channel();
    let win = window.clone();
    window
        .run_on_main_thread(move || {
            let _ = tx.send(rfd::FileDialog::new().set_parent(&win).pick_files());
        })
        .map_err(|e| e.to_string())?;
    Ok(rx
        .await
        .map_err(|e| e.to_string())?
        .unwrap_or_default()
        .into_iter()
        .map(|p| p.to_string_lossy().into_owned())
        .collect())
}

async fn run(f: impl FnOnce() -> Result<(), String> + Send + 'static) -> Result<(), String> {
    tauri::async_runtime::spawn_blocking(move || {
        let _one = BUSY.lock().map_err(|e| e.to_string())?;
        f()
    })
    .await
    .map_err(|e| e.to_string())?
}

// ── The database side: what the chat is, and what happened ──────────────────

struct Chat {
    jid: String,
    /// What WhatsApp's chat header shows (`ZPARTNERNAME`).
    name: String,
}

fn chat(chat_id: i64) -> Result<Chat, String> {
    with_conn(|c| {
        c.query_row(
            "SELECT ZCONTACTJID, coalesce(ZPARTNERNAME, '') FROM ZWACHATSESSION WHERE Z_PK = ?1",
            params![chat_id],
            |r| Ok(Chat { jid: r.get(0)?, name: r.get(1)? }),
        )
        .optional()
    })?
    .filter(|c| !c.jid.is_empty())
    .ok_or_else(|| "This chat is no longer in WhatsApp".into())
}

/// Does another chat end in the same four digits + domain? Then WhatsApp's
/// masked log line (`******1234@g.us`) can't tell them apart.
fn suffix_shared(jid: &str) -> Result<bool, String> {
    let (user, domain) = jid.split_once('@').unwrap_or((jid, ""));
    let tail = &user[user.len().saturating_sub(4)..];
    let pattern = format!("*{tail}@{domain}");
    with_conn(|c| {
        c.query_row(
            "SELECT count(*) FROM ZWACHATSESSION WHERE ZCONTACTJID GLOB ?1 AND ZCONTACTJID <> ?2",
            params![pattern, jid],
            |r| r.get::<_, i64>(0),
        )
    })
    .map(|n| n > 0)
}

/// The newest message row anywhere: new messages land above it.
fn head() -> Result<i64, String> {
    with_conn(|c| c.query_row("SELECT coalesce(max(Z_PK), 0) FROM ZWAMESSAGE", [], |r| r.get(0)))
}

/// What a send must produce, so a message the person sends in WhatsApp
/// meanwhile isn't taken for ours.
enum Sent<'a> {
    /// A text message (or link message, type 7) with exactly this text.
    Text(&'a str),
    /// An attachment: a message of the file's own kind (a photo for a .jpg, a
    /// video for a .mp4, …; WhatsApp re-encodes media, so bytes can't match),
    /// and for anything else a document carrying the file's name.
    File(&'a str),
}

/// Outgoing messages in this chat newer than `after` that match `what`.
fn sent_since(chat_id: i64, after: i64, what: &Sent) -> Result<i64, String> {
    let (filter, arg) = match what {
        Sent::Text(t) => ("ZMESSAGETYPE IN (0, 7) AND trim(ZTEXT) = trim(?3)", t.to_string()),
        Sent::File(path) => {
            let p = Path::new(path);
            let name = p.file_name().map(|n| n.to_string_lossy().into_owned()).unwrap_or_default();
            let ext = p.extension().map(|e| e.to_string_lossy().to_lowercase()).unwrap_or_default();
            let filter = match ext.as_str() {
                "jpg" | "jpeg" | "png" | "heic" | "heif" | "webp" => "ZMESSAGETYPE = 1",
                "gif" => "ZMESSAGETYPE IN (1, 11)",
                "mp4" | "mov" | "m4v" | "3gp" => "ZMESSAGETYPE = 2",
                "mp3" | "m4a" | "aac" | "ogg" | "opus" | "wav" => "ZMESSAGETYPE IN (3, 8)",
                // A document's text is its file name (behind a direction mark).
                _ => "ZMESSAGETYPE = 8 AND instr(ZTEXT, ?3) > 0",
            };
            (filter, name)
        }
    };
    with_conn(|c| {
        c.query_row(
            // `?3 IS NOT NULL` keeps the parameter count fixed for filters that don't use it.
            &format!("SELECT count(*) FROM ZWAMESSAGE WHERE ZCHATSESSION = ?1 AND ZISFROMME = 1 AND Z_PK > ?2
                        AND ({filter}) AND ?3 IS NOT NULL"),
            params![chat_id, after, arg],
            |r| r.get(0),
        )
    })
}

/// Wait for exactly `n` new outgoing messages matching `sent`; more is
/// reported, never hidden.
fn confirm_sent(chat_id: i64, after: i64, n: i64, sent: Sent, what: &str) -> Result<(), String> {
    let mut seen = 0;
    for _ in 0..60 {
        seen = sent_since(chat_id, after, &sent)?;
        if seen >= n {
            break;
        }
        std::thread::sleep(Duration::from_millis(250));
    }
    // A moment more, so a duplicate landing right after shows up too.
    std::thread::sleep(Duration::from_millis(500));
    seen = seen.max(sent_since(chat_id, after, &sent)?);
    match seen.cmp(&n) {
        std::cmp::Ordering::Equal => Ok(()),
        std::cmp::Ordering::Less => Err(format!("WhatsApp didn't confirm the {what}. Check the chat in WhatsApp.")),
        std::cmp::Ordering::Greater => Err(format!("WhatsApp sent {seen} messages for one {what}. Check the chat in WhatsApp.")),
    }
}

// ── Opening a chat ───────────────────────────────────────────────────────────

/// `background`: open without bringing WhatsApp to the front.
fn open_link(jid: &str, background: bool) -> Result<(), String> {
    // A JID is digits, `-`, `.` and `@`: nothing that could reshape the URL.
    if !jid.chars().all(|c| c.is_ascii_alphanumeric() || matches!(c, '@' | '.' | '-' | '_')) {
        return Err("Unexpected WhatsApp chat id".into());
    }
    let url = format!("whatsapp://widget-open-app/open-chat?chatJid={jid}");
    let mut cmd = std::process::Command::new("/usr/bin/open");
    if background {
        cmd.arg("-g");
    }
    let ok = cmd.arg(&url).status().map_err(|e| e.to_string())?.success();
    ok.then_some(()).ok_or_else(|| "WhatsApp Desktop is not installed on this Mac".into())
}

/// WhatsApp's own log: it records which chat it selected (`select-row/ chatJID:
/// <******1234@g.us>`, only the last four digits kept). Half of how a send knows
/// the right chat is on screen; the header's name is the other half (`open_chat`).
struct LogTail {
    file: Option<PathBuf>,
    from: u64,
}

impl LogTail {
    fn start() -> LogTail {
        let file = newest_log();
        let from = file.as_ref().and_then(|f| std::fs::metadata(f).ok()).map_or(0, |m| m.len());
        LogTail { file, from }
    }

    fn selected(&self, jid: &str) -> bool {
        let (user, domain) = jid.split_once('@').unwrap_or((jid, ""));
        let tail: String = user.chars().rev().take(4).collect::<Vec<_>>().into_iter().rev().collect();
        let needle = format!("select-row/ chatJID: <******{tail}@{domain}>");
        // WhatsApp starts a new log file now and then: read the newest one.
        let Some(file) = newest_log() else { return false };
        let from = if Some(&file) == self.file.as_ref() { self.from } else { 0 };
        let mut buf = Vec::new();
        let Ok(mut f) = std::fs::File::open(&file) else { return false };
        if f.seek(SeekFrom::Start(from)).is_err() || f.read_to_end(&mut buf).is_err() {
            return false;
        }
        // The latest selection since our link, not any earlier one.
        let text = String::from_utf8_lossy(&buf);
        let marker = "select-row/ chatJID: <";
        text.rfind(marker).is_some_and(|i| text[i..].starts_with(&needle))
    }
}

fn newest_log() -> Option<PathBuf> {
    let home = std::env::var_os("HOME")?;
    let logs = PathBuf::from(home).join("Library/Group Containers/group.net.whatsapp.WhatsApp.shared/Logs");
    std::fs::read_dir(logs)
        .ok()?
        .flatten()
        .filter(|d| d.file_name().to_string_lossy().starts_with("WhatsApp_"))
        .flat_map(|d| std::fs::read_dir(d.path()).into_iter().flatten().flatten())
        .filter(|f| f.path().extension().is_some_and(|e| e == "log"))
        .max_by_key(|f| f.metadata().and_then(|m| m.modified()).ok())
        .map(|f| f.path())
}

// ── Actions (macOS) ──────────────────────────────────────────────────────────

#[cfg(not(target_os = "macos"))]
fn send(_: i64, _: Option<String>, _: Vec<String>) -> Result<(), String> {
    Err("WhatsApp on this computer works on macOS only".into())
}

#[cfg(target_os = "macos")]
fn send(chat_id: i64, text: Option<String>, files: Vec<String>) -> Result<(), String> {
    if !ax::trusted(false) {
        return Err(NO_AX.into());
    }
    let chat = chat(chat_id)?;
    for file in &files {
        let opened = open_chat(&chat)?;
        let before = head()?;
        let pressed = objc::rc::autoreleasepool(|| send_file(&opened, file));
        landed(pressed, || confirm_sent(chat_id, before, 1, Sent::File(file), "attachment"))?;
    }
    if let Some(text) = text {
        let opened = open_chat(&chat)?;
        let before = head()?;
        let pressed = send_text(&opened, &text);
        landed(pressed, || confirm_sent(chat_id, before, 1, Sent::Text(&text), "message"))?;
    }
    Ok(())
}

/// Once Send was pressed, the database decides: a message that landed counts
/// even if the button lingered (`PRESS_UNSEEN`), so the item leaves the reply box
/// and a retry can't send it twice. A step that failed before any press keeps
/// its own error (nothing can have been sent).
#[cfg(target_os = "macos")]
fn landed(pressed: Result<(), String>, confirm: impl FnOnce() -> Result<(), String>) -> Result<(), String> {
    match pressed {
        Ok(()) => confirm(),
        Err(e) if e == PRESS_UNSEEN => confirm(),
        Err(e) => Err(e),
    }
}

/// `press_until_gone` pressed Send but never saw the button go.
const PRESS_UNSEEN: &str = "WhatsApp didn't take the Send press";

/// Open the chat in the background and wait until it is provably the one on
/// screen: WhatsApp's log names it as selected, by JID suffix. When another chat
/// shares that suffix the header must also show this chat's name (the header
/// isn't the check on its own: it shows your own name on "Message yourself",
/// where the database says "You"). → WhatsApp's pid.
#[cfg(target_os = "macos")]
fn open_chat(chat: &Chat) -> Result<Opened, String> {
    ensure_window()?;
    let log = LogTail::start();
    open_link(&chat.jid, true)?;
    let pid = ax::pid().ok_or("WhatsApp isn't running")?;
    ax::wait_for(Duration::from_secs(5), || log.selected(&chat.jid).then_some(()))
        .ok_or("WhatsApp didn't open the chat. Is it signed in?")?;
    let opened = Opened { pid, log, jid: chat.jid.clone(), name: suffix_shared(&chat.jid)?.then(|| plain(&chat.name)) };
    ax::wait_for(Duration::from_secs(3), || opened.header_matches().then_some(()))
        .ok_or("Couldn't make sure WhatsApp is showing this chat, so nothing was sent")?;
    ax::wait_for(Duration::from_secs(3), || window(pid).and_then(|w| w.find(COMPOSER)))
        .ok_or("This chat has no message box in WhatsApp (an announcement group or a left group?)")?;
    Ok(opened)
}

/// A chat `open_chat` proved is on screen, re-checked right before every Send
/// press: the person can switch chats in WhatsApp while Inbox2 types.
#[cfg(target_os = "macos")]
struct Opened {
    pid: i32,
    log: LogTail,
    jid: String,
    /// The name the header must show, when the JID suffix alone is ambiguous.
    name: Option<String>,
}

#[cfg(target_os = "macos")]
impl Opened {
    fn header_matches(&self) -> bool {
        match &self.name {
            None => true,
            Some(name) => !name.is_empty()
                && window(self.pid).and_then(|w| w.find(HEADER)).and_then(|h| h.description()).is_some_and(|shown| plain(&shown) == *name),
        }
    }

    /// Still this chat: WhatsApp's latest selection since our link is it.
    fn still(&self) -> bool {
        self.log.selected(&self.jid) && self.header_matches()
    }
}

/// A chat name without the invisible direction marks WhatsApp puts around it.
#[cfg(target_os = "macos")]
fn plain(s: &str) -> String {
    s.chars()
        .filter(|c| !matches!(c, '\u{200E}' | '\u{200F}' | '\u{202A}'..='\u{202E}' | '\u{2066}'..='\u{2069}'))
        .collect::<String>()
        .trim()
        .to_string()
}

#[cfg(target_os = "macos")]
fn window(pid: i32) -> Option<Ax> {
    Ax::app(pid).windows().into_iter().next()
}

/// WhatsApp launched in the background, or with its window closed, has no
/// window to type into: show it once, then come back.
#[cfg(target_os = "macos")]
fn ensure_window() -> Result<(), String> {
    if ax::pid().and_then(window).is_some() {
        return Ok(());
    }
    with_whatsapp_shown(|| {
        ax::wait_for(Duration::from_secs(8), || ax::pid().and_then(window))
            .map(|_| ())
            .ok_or_else(|| "WhatsApp didn't open a window".to_string())
    })
}

/// Bring WhatsApp to the front for `f`, then Inbox2 again.
#[cfg(target_os = "macos")]
fn with_whatsapp_shown<T>(f: impl FnOnce() -> Result<T, String>) -> Result<T, String> {
    std::process::Command::new("/usr/bin/open")
        .args(["-b", ax::BUNDLE_ID])
        .status()
        .map_err(|e| e.to_string())?;
    std::thread::sleep(Duration::from_millis(600));
    let out = f();
    ax::activate_self();
    out
}

/// Type the text, then press Send. Setting the box's value alone doesn't
/// register with WhatsApp: a typed space + delete makes it notice (and swap
/// the mic button for Send).
#[cfg(target_os = "macos")]
fn send_text(opened: &Opened, text: &str) -> Result<(), String> {
    let pid = opened.pid;
    no_draft(pid)?;
    let try_once = || -> Result<Option<Ax>, String> {
        let w = window(pid).ok_or("WhatsApp has no window")?;
        let box_ = w.find(COMPOSER).ok_or("WhatsApp's message box is gone")?;
        box_.focus()?;
        box_.set_value(text)?;
        ax::tap(pid, ax::KEY_SPACE)?;
        ax::tap(pid, ax::KEY_DELETE)?;
        Ok(ax::wait_for(Duration::from_secs(1), || window(pid).and_then(|w| w.find(SEND))))
    };
    // Right after an attachment WhatsApp drops the first keys: a few tries in
    // the background before showing it.
    let mut took = false;
    for _ in 0..3 {
        if try_once()?.is_some() {
            took = true;
            break;
        }
    }
    if !took {
        // Keys didn't reach it in the background: once more with WhatsApp shown.
        with_whatsapp_shown(|| try_once()?.ok_or_else(|| "WhatsApp didn't take the text".to_string()))?;
    }
    press_until_gone(opened, &[SEND], 3)
}

/// Press Send until the button goes away (WhatsApp took it). Right after a
/// previous send WhatsApp can ignore a press: in testing the text after an
/// attachment sat in the box with Send showing. Pressed again only while the
/// button is still there 1.5 s later (`tries`; an attachment gets one press,
/// a re-press could upload it twice); `confirm_sent` reports any duplicate.
#[cfg(target_os = "macos")]
fn press_until_gone(opened: &Opened, ids: &[&str], tries: usize) -> Result<(), String> {
    let pid = opened.pid;
    let find = || window(pid).and_then(|w| ids.iter().find_map(|id| w.find(id)));
    let wait = Duration::from_millis(if tries > 1 { 1500 } else { 5000 });
    for _ in 0..tries {
        let Some(button) = find() else { return Ok(()) };
        if !opened.still() {
            return Err("You switched chats in WhatsApp while Inbox2 was typing, so nothing was sent".into());
        }
        button.press()?;
        if ax::wait_for(wait, || find().is_none().then_some(())).is_some() {
            return Ok(());
        }
    }
    Err(PRESS_UNSEEN.into())
}

/// Paste one file and send it from WhatsApp's preview — only when the preview
/// holds exactly that one file. The person's clipboard is put back after.
#[cfg(target_os = "macos")]
fn send_file(opened: &Opened, file: &str) -> Result<(), String> {
    let saved = ax::save_clipboard();
    let mut ours = None;
    let out = paste_and_send(opened, file, &mut ours);
    // Put the person's clipboard back only if it still holds our file: anything
    // they copied meanwhile stays.
    if ours.is_none_or(|n| n == ax::clipboard_changes()) {
        ax::restore_clipboard(saved);
    }
    out
}

/// Refuse to touch a chat whose WhatsApp message box holds an unsent draft:
/// typing would replace it, a paste would make it a caption.
#[cfg(target_os = "macos")]
fn no_draft(pid: i32) -> Result<(), String> {
    // Fails closed: a box that can't be read might hold a draft.
    let draft = window(pid).and_then(|w| w.find(COMPOSER)).ok_or("WhatsApp's message box is gone")?.text()?;
    if draft.trim().is_empty() {
        Ok(())
    } else {
        Err("This chat has an unsent draft in WhatsApp. Send or clear it there first, so it isn't lost".into())
    }
}

#[cfg(target_os = "macos")]
fn paste_and_send(opened: &Opened, file: &str, ours: &mut Option<isize>) -> Result<(), String> {
    let pid = opened.pid;
    no_draft(pid)?;
    let preview_send = || window(pid).and_then(|w| PREVIEW_SEND.iter().find_map(|id| w.find(id)));
    let mut try_once = || -> Result<Option<Ax>, String> {
        let w = window(pid).ok_or("WhatsApp has no window")?;
        w.find(COMPOSER).ok_or("WhatsApp's message box is gone")?.focus()?;
        ax::copy_file(file);
        *ours = Some(ax::clipboard_changes());
        ax::paste(pid)?;
        Ok(ax::wait_for(Duration::from_secs(3), preview_send))
    };
    if try_once()?.is_none() {
        with_whatsapp_shown(|| try_once()?.ok_or_else(|| "WhatsApp didn't take the attachment".to_string()))?;
    }
    // A ⌘V that repeats keeps adding copies: give it a moment, then count.
    std::thread::sleep(Duration::from_millis(700));
    let items = window(pid).map_or(0, |w| w.count(PREVIEW_ITEM));
    if items > 1 {
        if let Some(back) = window(pid).and_then(|w| w.find(PREVIEW_BACK)) {
            let _ = back.press();
        }
        return Err(format!("WhatsApp's preview held {items} copies of the file, so nothing was sent"));
    }
    press_until_gone(opened, &PREVIEW_SEND, 1)
}

#[cfg(all(test, target_os = "macos"))]
mod tests {
    use super::*;

    #[test]
    fn header_names_compare_without_direction_marks() {
        assert_eq!(plain("\u{200E}You"), "You");
        assert_eq!(plain(" \u{2068}Gluon 👾\u{2069} "), "Gluon 👾");
        assert_ne!(plain("Gluon"), plain("Gluon 👾"));
    }

    /// Live: sends into the chat named by `WA_TEST_CHAT` (a `ZWACHATSESSION.Z_PK` —
    /// use your own "Message yourself" chat) through the real WhatsApp Desktop.
    /// `WA_TEST_FILE` adds an attachment. Never runs by default:
    /// `WA_TEST_CHAT=<id> cargo test --release --lib whatsapp_actions -- --ignored --nocapture`
    #[test]
    #[ignore]
    fn sends_into_whatsapp() {
        let chat: i64 = std::env::var("WA_TEST_CHAT").expect("WA_TEST_CHAT").parse().unwrap();
        let files: Vec<String> = std::env::var("WA_TEST_FILE").into_iter().collect();
        let text = format!("inbox2 send test {}", chrono::Local::now().format("%H:%M:%S"));
        let t = std::time::Instant::now();
        send(chat, Some(text), files).unwrap();
        eprintln!("sent in {:?}", t.elapsed());
    }
}
