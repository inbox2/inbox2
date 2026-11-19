//! Local WhatsApp: reads WhatsApp Desktop's own database on this Mac, live and
//! read-only. Nothing is copied into inbox2's store, and nothing is ever
//! written to WhatsApp's files.
//!
//! Why this does not disturb the WhatsApp client: `ChatStorage.sqlite` runs in
//! WAL mode. A read-only reader never blocks WhatsApp's writer and is never
//! blocked by it; the one thing an open read transaction does is stop
//! WhatsApp's checkpoint from moving past the reader's snapshot. So every query
//! here is a single short statement (autocommit, no explicit transaction), and
//! the connection never uses `immutable=1` (that skips the WAL and reads torn
//! pages while WhatsApp writes).
//!
//! Media and avatars are served to the webview through the `wamedia://`
//! protocol (see [`serve_media`]), which only resolves paths inside the
//! WhatsApp container.

use std::path::{Path, PathBuf};
use std::sync::Mutex;

use rusqlite::{params, Connection, OpenFlags, OptionalExtension};
use serde::Serialize;

/// Seconds between the Unix epoch and Core Data's 2001-01-01 reference date.
const APPLE_EPOCH: f64 = 978_307_200.0;

/// 1:1 chats and groups. Broadcast lists, Status and communities stay out.
const SESSION_TYPES: &str = "(0, 1)";
const SESSION_GROUP: i64 = 1;
/// ZMESSAGETYPE of a group event (joined, removed, renamed, …) and of a 1:1
/// chat notice (number changed, encryption); both carry ZGROUPEVENTTYPE.
const SYSTEM_KIND: i64 = 6;
const NOTICE_KIND: i64 = 10;

/// WhatsApp Desktop's shared group container, macOS only.
fn root() -> Option<PathBuf> {
    if !cfg!(target_os = "macos") {
        return None;
    }
    let home = std::env::var_os("HOME")?;
    Some(PathBuf::from(home).join("Library/Group Containers/group.net.whatsapp.WhatsApp.shared"))
}

/// The error the UI recognises to offer the Full Disk Access settings (lib/localWhatsApp.js).
pub const NO_ACCESS: &str = "no_access: macOS blocked Inbox2 from reading WhatsApp's data. Turn on Inbox2 under System Settings › Privacy & Security › Full Disk Access, then try again.";

/// Open System Settings at Privacy & Security › Full Disk Access.
#[tauri::command]
pub fn wa_open_privacy_settings(app: tauri::AppHandle) -> Result<(), String> {
    use tauri_plugin_opener::OpenerExt;
    app.opener()
        .open_url("x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles", None::<&str>)
        .map_err(|e| e.to_string())
}

// ponytail: one cached connection behind a global lock; queries are a few ms each.
static CONN: Mutex<Option<Connection>> = Mutex::new(None);

fn open() -> Result<Connection, String> {
    let root = root().ok_or("WhatsApp Desktop is only read on macOS")?;
    let db = root.join("ChatStorage.sqlite");
    if !db.exists() {
        return Err("WhatsApp Desktop is not installed on this Mac".into());
    }
    // macOS guards other apps' containers: the file is visible but opening it is
    // refused until Inbox2 has Full Disk Access (SQLite only says "unable to open").
    if let Err(e) = std::fs::File::open(&db) {
        return Err(if e.kind() == std::io::ErrorKind::PermissionDenied { NO_ACCESS.into() } else { e.to_string() });
    }
    let ro = OpenFlags::SQLITE_OPEN_READ_ONLY | OpenFlags::SQLITE_OPEN_NO_MUTEX;
    let conn = Connection::open_with_flags(&db, ro).map_err(|e| e.to_string())?;
    // WhatsApp holds the write lock for short bursts; wait rather than fail.
    conn.busy_timeout(std::time::Duration::from_secs(2)).map_err(|e| e.to_string())?;
    // Address-book names. Attached databases inherit the read-only flag.
    let contacts = root.join("ContactsV2.sqlite");
    conn.execute("ATTACH DATABASE ?1 AS c", params![contacts.to_string_lossy()])
        .map_err(|e| format!("WhatsApp contacts: {e}"))?;
    // LID ↔ phone number pairs (the owner's own pair included).
    conn.execute("ATTACH DATABASE ?1 AS l", params![root.join("LID.sqlite").to_string_lossy()])
        .map_err(|e| format!("WhatsApp LIDs: {e}"))?;
    Ok(conn)
}

/// Run `f` on the cached connection, reopening once if it went stale (the
/// app was reinstalled, the database replaced, macOS revoked access).
pub(crate) fn with_conn<T>(f: impl Fn(&Connection) -> rusqlite::Result<T>) -> Result<T, String> {
    let mut guard = CONN.lock().map_err(|e| e.to_string())?;
    if guard.is_none() {
        *guard = Some(open()?);
    }
    match f(guard.as_ref().unwrap()) {
        Ok(v) => Ok(v),
        Err(_) => {
            *guard = Some(open()?);
            f(guard.as_ref().unwrap()).map_err(|e| e.to_string())
        }
    }
}

/// A relative container path, only when the file is really on disk (media that
/// was never downloaded on this Mac has a row but no file).
fn on_disk(rel: Option<String>) -> Option<String> {
    let rel = rel.filter(|r| !r.is_empty())?;
    let root = root()?;
    root.join(&rel).is_file().then_some(rel)
}

/// Message media paths in the database (`ZMEDIALOCALPATH`, `ZXMPPTHUMBPATH`) are
/// relative to the container's `Message/` folder (`Media/<chat>/…` lives at
/// `Message/Media/<chat>/…`); profile pictures are relative to the container.
fn message_media(rel: Option<String>) -> Option<String> {
    rel.filter(|r| !r.is_empty()).map(|r| format!("Message/{}", r.trim_start_matches('/')))
}

/// Profile pictures are stored without an extension: `<ZPATH>.jpg` (full) next
/// to `<ZPATH>.thumb`.
fn avatar(rel: Option<String>) -> Option<String> {
    let rel = rel.filter(|r| r.starts_with("Media/"))?;
    on_disk(Some(format!("{rel}.jpg"))).or_else(|| on_disk(Some(format!("{rel}.thumb"))))
}

fn ms(apple_secs: Option<f64>) -> i64 {
    apple_secs.map(|s| ((s + APPLE_EPOCH) * 1000.0) as i64).unwrap_or(0)
}

// Display name for a sender JID: address book (by LID or phone JID) → the
// group member row → their own push name (prefixed "~", as WhatsApp shows it)
// → the bare number.
const SENDER_NAME: &str = "coalesce(
    (SELECT nullif(a.ZFULLNAME, '') FROM c.ZWAADDRESSBOOKCONTACT a WHERE a.ZLID = g.ZMEMBERJID OR a.ZWHATSAPPID = g.ZMEMBERJID LIMIT 1),
    nullif(g.ZCONTACTNAME, ''),
    (SELECT '~' || p.ZPUSHNAME FROM ZWAPROFILEPUSHNAME p WHERE p.ZJID = g.ZMEMBERJID AND p.ZPUSHNAME <> '' LIMIT 1),
    -- Known only by LID: the phone number LID.sqlite pairs with it (its address-book name first).
    (SELECT coalesce((SELECT nullif(a.ZFULLNAME, '') FROM c.ZWAADDRESSBOOKCONTACT a WHERE a.ZWHATSAPPID = z.ZPHONENUMBER || '@s.whatsapp.net' LIMIT 1),
                     '+' || z.ZPHONENUMBER)
       FROM l.ZWAZACCOUNT z WHERE z.ZIDENTIFIER = g.ZMEMBERJID AND z.ZPHONENUMBER <> '' LIMIT 1),
    -- A LID isn't a phone number: only a phone JID shows as +number.
    CASE WHEN g.ZMEMBERJID LIKE '%@lid' THEN 'Unknown' ELSE '+' || substr(g.ZMEMBERJID, 1, instr(g.ZMEMBERJID, '@') - 1) END)";

/// Mentions are stored as `@<number>` (a phone number or a LID) in the text;
/// this turns them into `@Name` the way WhatsApp shows them (address book →
/// push name → group member row; the owner is "You"). Unknown numbers stay.
struct Mentions<'a> {
    c: &'a Connection,
    me: Vec<String>,
    cache: std::collections::HashMap<String, Option<String>>,
}

impl<'a> Mentions<'a> {
    fn new(c: &'a Connection) -> rusqlite::Result<Self> {
        let me = own_jids(c)?;
        let me = me.iter().filter_map(|j| j.split('@').next().map(str::to_string)).collect();
        Ok(Self { c, me, cache: Default::default() })
    }

    fn name(&mut self, digits: &str) -> Option<String> {
        if self.me.iter().any(|m| m == digits) {
            return Some("You".into());
        }
        if let Some(hit) = self.cache.get(digits) {
            return hit.clone();
        }
        let lid = format!("{digits}@lid");
        let mut found = self.lookup(&lid, &format!("{digits}@s.whatsapp.net"));
        // Someone known only by LID (no address-book entry, push name or member
        // name): WhatsApp shows the phone number LID.sqlite pairs with it.
        if found.is_none() {
            if let Some(phone) = paired_jid(self.c, &lid).ok().flatten() {
                let number = phone.split('@').next().unwrap_or_default().to_string();
                found = self.lookup(&lid, &phone).or(Some(format!("+{number}")));
            }
        }
        self.cache.insert(digits.to_string(), found.clone());
        found
    }

    fn lookup(&self, lid: &str, phone: &str) -> Option<String> {
        self.c
            .query_row(
                "SELECT coalesce(
                   (SELECT nullif(ZFULLNAME, '') FROM c.ZWAADDRESSBOOKCONTACT WHERE ZLID = ?1 OR ZWHATSAPPID = ?2 LIMIT 1),
                   (SELECT nullif(ZPUSHNAME, '') FROM ZWAPROFILEPUSHNAME WHERE ZJID IN (?1, ?2) AND ZPUSHNAME <> '' LIMIT 1),
                   (SELECT nullif(ZCONTACTNAME, '') FROM ZWAGROUPMEMBER WHERE ZMEMBERJID IN (?1, ?2) AND ZCONTACTNAME <> '' LIMIT 1))",
                params![lid, phone],
                |r| r.get(0),
            )
            .ok()
            .flatten()
    }

    /// A JID as a person: their name, else their number, else "someone".
    fn person(&mut self, jid: &str) -> String {
        let (digits, kind) = jid.split_once('@').unwrap_or((jid, ""));
        self.name(digits).unwrap_or_else(|| if kind == "s.whatsapp.net" { format!("+{digits}") } else { "someone".into() })
    }

    /// A group event (message type 6) as WhatsApp words it. The row's text holds
    /// the subject for a rename, or the JIDs it concerns (`;`-separated); the
    /// actor is the group member row. Wordings were read off WhatsApp's own
    /// chat view; types not confirmed there show only who it concerns.
    fn event(&mut self, kind: i64, event: Option<i64>, text: Option<&str>, member: Option<&str>, from_me: bool) -> Option<String> {
        let actor = if from_me { "You".to_string() } else { member.map_or_else(|| "Someone".into(), |j| self.person(j)) };
        let people: Vec<String> = text
            .unwrap_or_default()
            .split(';')
            .filter(|t| t.contains('@'))
            .map(|j| self.person(j.trim()))
            .collect();
        let people = people.join(", ");
        if kind == NOTICE_KIND {
            return match event {
                Some(5) if !people.is_empty() => Some(format!("{people} changed their phone number to a new number")),
                Some(6) if !people.is_empty() => Some(format!("{people} changed their phone number. You're currently chatting with their new number")),
                Some(91) => Some("Your personal messages are end-to-end encrypted".into()),
                _ if !people.is_empty() => Some(people),
                _ => text.map(|t| self.fix(t)),
            };
        }
        Some(match event? {
            1 => format!("{actor} changed the group name to “{}”", text?),
            4 => format!("{actor} changed this group's icon"),
            // The text names who did it; the member row is who was removed
            // (WhatsApp: "Nadeem Aftab removed +92 332 …").
            7 if !people.is_empty() => format!("{people} removed {actor}"),
            9 => format!("{actor} changed their phone number to a new number"),
            10 => "You're now an admin".into(),
            20 => format!("{actor} changed this group's settings to allow only admins to send messages"),
            _ if !people.is_empty() => people,
            _ => return text.filter(|t| !t.starts_with('{')).map(|t| self.fix(t)),
        })
    }

    fn fix(&mut self, text: &str) -> String {
        if !text.contains('@') {
            return text.to_string();
        }
        let mut out = String::with_capacity(text.len());
        let mut rest = text;
        while let Some(at) = rest.find('@') {
            out.push_str(&rest[..at]);
            let after = &rest[at + 1..];
            let n = after.bytes().take_while(u8::is_ascii_digit).count();
            match (n >= 6).then(|| self.name(&after[..n])).flatten() {
                Some(name) => {
                    out.push('@');
                    out.push_str(&name);
                    rest = &after[n..];
                }
                None => {
                    out.push('@');
                    rest = after;
                }
            }
        }
        out.push_str(rest);
        out
    }

    fn fix_opt(&mut self, text: Option<String>) -> Option<String> {
        text.map(|t| self.fix(&t))
    }
}

#[derive(Serialize)]
pub struct WaStatus {
    pub available: bool,
    pub error: Option<String>,
    /// Highest message row id: changes whenever a message lands, so the UI can
    /// poll this one cheap number instead of reloading lists.
    pub head: i64,
    pub unread: i64,
    /// Moves on any change the views show: a new message, and also an archived
    /// chat, an unread count, an edited/deleted recent message. Core Data bumps a
    /// row's Z_OPT on every update, so the sums over chats and recent messages move.
    pub version: String,
}

#[derive(Serialize)]
pub struct WaChat {
    pub id: i64,
    pub jid: String,
    pub name: String,
    pub is_group: bool,
    pub archived: bool,
    pub unread: i64,
    /// Pinned in WhatsApp: it keeps pins on top by pushing ZLASTMESSAGEDATE
    /// thousands of years ahead (year 8026, 9026, … in pin order).
    pub pinned: bool,
    pub last_text: Option<String>,
    pub last_at: i64,
    pub avatar: Option<String>,
}

#[derive(Serialize)]
pub struct WaMedia {
    /// Relative to the container; `None` when not downloaded on this Mac.
    pub path: Option<String>,
    pub thumb: Option<String>,
    pub title: Option<String>,
    /// The file's name (a document's own name, else the stored file's).
    pub name: Option<String>,
    /// Width ÷ height when WhatsApp knows it (0 otherwise): bubbles reserve the space.
    pub aspect: f64,
    pub size: i64,
    pub duration: f64,
    pub latitude: f64,
    pub longitude: f64,
}

#[derive(Serialize)]
pub struct WaMessage {
    pub id: i64,
    pub chat_id: i64,
    pub from_me: bool,
    pub at: i64,
    pub kind: i64,
    pub text: Option<String>,
    pub sender: Option<String>,
    pub sender_avatar: Option<String>,
    pub media: Option<WaMedia>,
    /// ZGROUPEVENTTYPE of a group event (kind 6): worded into `text` by `Mentions::event`.
    #[serde(skip)]
    pub event: Option<i64>,
    /// The group member row's JID (a group event's actor or subject).
    #[serde(skip)]
    pub member: Option<String>,
}

#[derive(Serialize)]
pub struct WaPage {
    pub messages: Vec<WaMessage>,
    /// Older messages exist before the first one returned.
    pub has_earlier: bool,
}

#[derive(Serialize)]
pub struct WaHit {
    pub id: i64,
    pub chat_id: i64,
    pub chat_name: String,
    pub chat_avatar: Option<String>,
    pub is_group: bool,
    pub from_me: bool,
    pub sender: Option<String>,
    pub at: i64,
    pub text: String,
}

fn head_and_unread(c: &Connection) -> rusqlite::Result<(i64, i64)> {
    c.query_row(
        &format!(
            "SELECT (SELECT coalesce(max(Z_PK), 0) FROM ZWAMESSAGE),
                    (SELECT count(*) FROM ZWACHATSESSION
                      WHERE ZUNREADCOUNT <> 0 AND coalesce(ZARCHIVED, 0) = 0
                        AND coalesce(ZREMOVED, 0) = 0 AND ZSESSIONTYPE IN {SESSION_TYPES})"
        ),
        [],
        |r| Ok((r.get(0)?, r.get(1)?)),
    )
}

/// Whether the database is readable, plus the change marker and the number of
/// unread chats (WhatsApp's own badge counts chats, not messages).
/// How many of the newest messages are watched for edits and deletions.
const RECENT_EDITS: i64 = 2_000;

#[tauri::command]
pub async fn wa_status() -> WaStatus {
    let down = |e: String| WaStatus { available: false, error: Some(e), head: 0, unread: 0, version: String::new() };
    tauri::async_runtime::spawn_blocking(move || {
        match with_conn(|c| {
            let (head, unread) = head_and_unread(c)?;
            let opt: (i64, i64) = c.query_row(
                "SELECT (SELECT total(Z_OPT) FROM ZWACHATSESSION),
                        (SELECT total(Z_OPT) FROM ZWAMESSAGE WHERE Z_PK > ?1)",
                [head - RECENT_EDITS],
                |r| Ok((r.get::<_, f64>(0)? as i64, r.get::<_, f64>(1)? as i64)),
            )?;
            Ok((head, unread, format!("{head}.{}.{}", opt.0, opt.1)))
        }) {
            Ok((head, unread, version)) => WaStatus { available: true, error: None, head, unread, version },
            Err(e) => down(e),
        }
    })
    .await
    .unwrap_or_else(|_| down("reader crashed".into()))
}

#[tauri::command]
pub async fn wa_chats() -> Result<Vec<WaChat>, String> {
    blocking(|| {
        with_conn(|c| {
            let picture = avatar_of("s.ZCONTACTJID");
            let sql = format!(
                "SELECT s.Z_PK, s.ZCONTACTJID, s.ZPARTNERNAME, s.ZSESSIONTYPE, coalesce(s.ZARCHIVED, 0),
                        s.ZUNREADCOUNT,
                        -- ZLASTMESSAGETEXT is an encoded blob and ZLASTMESSAGEDATE is pushed far
                        -- into the future for pinned chats (that keeps them on top, which the ORDER
                        -- BY below wants): show the last message's own text and date instead.
                        CASE lm.ZMESSAGETYPE WHEN 0 THEN lm.ZTEXT WHEN 7 THEN lm.ZTEXT
                          WHEN 1 THEN '📷 ' || coalesce(nullif(li.ZTITLE, ''), 'Photo')
                          WHEN 2 THEN '🎥 ' || coalesce(nullif(li.ZTITLE, ''), 'Video')
                          WHEN 3 THEN '🎤 Voice message' WHEN 8 THEN '📄 ' || coalesce(lm.ZTEXT, 'Document')
                          WHEN 15 THEN 'Sticker' WHEN 5 THEN '📍 Location' WHEN 4 THEN '👤 Contact'
                          WHEN 14 THEN 'This message was deleted' ELSE lm.ZTEXT END,
                        coalesce(lm.ZMESSAGEDATE, s.ZLASTMESSAGEDATE),
                        coalesce(gi.ZPICTUREPATH, {picture}),
                        lm.ZMESSAGETYPE, lm.ZGROUPEVENTTYPE, coalesce(lm.ZISFROMME, 0),
                        g.ZMEMBERJID,
                        s.ZLASTMESSAGEDATE > (strftime('%s', 'now') - {APPLE_EPOCH}) + 100 * 365 * 86400
                   FROM ZWACHATSESSION s
                   LEFT JOIN ZWAGROUPINFO gi ON gi.Z_PK = s.ZGROUPINFO
                   LEFT JOIN ZWAMESSAGE lm ON lm.Z_PK = s.ZLASTMESSAGE
                   LEFT JOIN ZWAGROUPMEMBER g ON g.Z_PK = lm.ZGROUPMEMBER
                   LEFT JOIN ZWAMEDIAITEM li ON li.ZMESSAGE = lm.Z_PK
                  WHERE coalesce(s.ZREMOVED, 0) = 0 AND coalesce(s.ZHIDDEN, 0) = 0
                    AND s.ZSESSIONTYPE IN {SESSION_TYPES} AND s.ZLASTMESSAGEDATE IS NOT NULL
                  ORDER BY s.ZLASTMESSAGEDATE DESC"
            );
            let mut stmt = c.prepare_cached(&sql)?;
            let rows = stmt.query_map([], |r| {
                // A group event / chat notice as the last message: (kind, event type, from me, actor).
                let kind: Option<i64> = r.get(9)?;
                let event: Option<(i64, Option<i64>, bool, Option<String>)> = matches!(kind, Some(SYSTEM_KIND | NOTICE_KIND))
                    .then(|| Ok::<_, rusqlite::Error>((kind.unwrap_or_default(), r.get(10)?, r.get::<_, i64>(11)? != 0, r.get(12)?)))
                    .transpose()?;
                Ok((event, WaChat {
                    id: r.get(0)?,
                    jid: r.get::<_, Option<String>>(1)?.unwrap_or_default(),
                    name: r.get::<_, Option<String>>(2)?.unwrap_or_default(),
                    is_group: r.get::<_, i64>(3)? == SESSION_GROUP,
                    archived: r.get::<_, i64>(4)? != 0,
                    unread: r.get::<_, Option<i64>>(5)?.unwrap_or(0),
                    pinned: r.get::<_, Option<bool>>(13)?.unwrap_or(false),
                    last_text: r.get(6)?,
                    last_at: ms(r.get(7)?),
                    avatar: avatar(r.get(8)?),
                }))
            })?;
            let rows: Vec<_> = rows.collect::<Result<_, _>>()?;
            let mut m = Mentions::new(c)?;
            Ok(rows
                .into_iter()
                .map(|(event, mut chat)| {
                    chat.last_text = match event {
                        Some((kind, ev, me, actor)) => m.event(kind, ev, chat.last_text.as_deref(), actor.as_deref(), me),
                        None => m.fix_opt(chat.last_text.take()),
                    };
                    chat
                })
                .collect())
        })
    })
    .await
}

/// SQL for a JID's profile picture path. Newer WhatsApp files the picture under
/// the contact's LID (`…@lid`) while the chat names their phone JID, or the
/// other way round: the pair LID.sqlite records (`l.ZWAZACCOUNT`) is tried too.
/// Each lookup is written to hit an index (ZPHONENUMBER / ZIDENTIFIER / ZJID):
/// matching on a concatenated `ZPHONENUMBER || '@…'` scanned the table per row.
fn avatar_of(jid: &str) -> String {
    format!(
        "coalesce(
           (SELECT pp.ZPATH FROM ZWAPROFILEPICTUREITEM pp WHERE pp.ZJID = {jid} AND pp.ZPATH IS NOT NULL LIMIT 1),
           (SELECT pp.ZPATH FROM l.ZWAZACCOUNT z JOIN ZWAPROFILEPICTUREITEM pp ON pp.ZJID = z.ZIDENTIFIER
             WHERE {jid} LIKE '%@s.whatsapp.net' AND z.ZPHONENUMBER = substr({jid}, 1, instr({jid}, '@') - 1)
               AND pp.ZPATH IS NOT NULL LIMIT 1),
           (SELECT pp.ZPATH FROM l.ZWAZACCOUNT z JOIN ZWAPROFILEPICTUREITEM pp ON pp.ZJID = z.ZPHONENUMBER || '@s.whatsapp.net'
             WHERE {jid} LIKE '%@lid' AND z.ZIDENTIFIER = {jid} AND z.ZPHONENUMBER <> '' AND pp.ZPATH IS NOT NULL LIMIT 1))"
    )
}

const MESSAGE_COLUMNS: &str = "m.Z_PK, m.ZCHATSESSION, m.ZISFROMME, m.ZMESSAGEDATE, m.ZMESSAGETYPE, m.ZTEXT,
    CASE WHEN g.Z_PK IS NULL THEN NULL ELSE {SENDER} END,
    {AVATAR},
    i.Z_PK, i.ZMEDIALOCALPATH, i.ZXMPPTHUMBPATH, i.ZTITLE, i.ZFILESIZE, i.ZMOVIEDURATION, i.ZLATITUDE, i.ZLONGITUDE,
    i.ZASPECTRATIO, m.ZGROUPEVENTTYPE, g.ZMEMBERJID";

fn message_row(r: &rusqlite::Row) -> rusqlite::Result<WaMessage> {
    let kind: i64 = r.get::<_, Option<i64>>(4)?.unwrap_or(0);
    let stored: Option<String> = r.get(9)?;
    let media = match r.get::<_, Option<i64>>(8)? {
        None => None,
        Some(_) => Some(WaMedia {
            // A document's text is its file name (WhatsApp prefixes a direction mark).
            name: if kind == 8 { r.get::<_, Option<String>>(5)?.map(|t| t.trim_start_matches('\u{200e}').to_string()) } else { None }
                .or_else(|| stored.as_deref().and_then(|p| p.rsplit('/').next()).map(str::to_string)),
            aspect: r.get::<_, Option<f64>>(16)?.unwrap_or(0.0),
            path: on_disk(message_media(stored.clone())),
            thumb: on_disk(message_media(r.get(10)?)),
            title: r.get::<_, Option<String>>(11)?.filter(|t| !t.is_empty()),
            size: r.get::<_, Option<i64>>(12)?.unwrap_or(0),
            duration: r.get::<_, Option<f64>>(13)?.unwrap_or(0.0),
            latitude: r.get::<_, Option<f64>>(14)?.unwrap_or(0.0),
            longitude: r.get::<_, Option<f64>>(15)?.unwrap_or(0.0),
        }),
    };
    Ok(WaMessage {
        id: r.get(0)?,
        chat_id: r.get(1)?,
        from_me: r.get::<_, Option<i64>>(2)?.unwrap_or(0) != 0,
        at: ms(r.get(3)?),
        kind: r.get::<_, Option<i64>>(4)?.unwrap_or(0),
        text: r.get(5)?,
        sender: r.get(6)?,
        sender_avatar: avatar(r.get(7)?),
        media,
        event: r.get(17)?,
        member: r.get(18)?,
    })
}

/// A page of a chat, oldest first. `before` (a message id) pages backwards;
/// `around` centres the page on a message (opening a search hit).
#[tauri::command]
pub async fn wa_messages(chat_id: i64, before: Option<i64>, around: Option<i64>, limit: Option<i64>) -> Result<WaPage, String> {
    let limit = limit.unwrap_or(200).clamp(1, 1000);
    blocking(move || {
        with_conn(|c| {
            let cols = MESSAGE_COLUMNS.replace("{SENDER}", SENDER_NAME).replace("{AVATAR}", &avatar_of("g.ZMEMBERJID"));
            let from = "FROM ZWAMESSAGE m
                LEFT JOIN ZWAGROUPMEMBER g ON g.Z_PK = m.ZGROUPMEMBER
                LEFT JOIN ZWAMEDIAITEM i ON i.ZMESSAGE = m.Z_PK
               WHERE m.ZCHATSESSION = ?1";
            // Pages are cut on (date, row id), the sort order: messages sharing a
            // timestamp fall on one side of the cut, never between pages.
            let cursor_of = |id: i64| -> rusqlite::Result<Option<(f64, i64)>> {
                c.query_row("SELECT ZMESSAGEDATE, Z_PK FROM ZWAMESSAGE WHERE Z_PK = ?1 AND ZMESSAGEDATE IS NOT NULL", [id], |r| Ok((r.get(0)?, r.get(1)?)))
                    .optional()
            };
            let older = |(d, pk): (f64, i64), n: i64| -> rusqlite::Result<Vec<WaMessage>> {
                let mut stmt = c.prepare_cached(&format!(
                    "SELECT {cols} {from} AND (m.ZMESSAGEDATE < ?2 OR (m.ZMESSAGEDATE = ?2 AND m.Z_PK < ?3))
                     ORDER BY m.ZMESSAGEDATE DESC, m.Z_PK DESC LIMIT ?4"
                ))?;
                let mut v: Vec<WaMessage> = stmt.query_map(params![chat_id, d, pk, n], message_row)?.collect::<Result<_, _>>()?;
                v.reverse();
                Ok(v)
            };
            let mut messages = match (around.map(cursor_of).transpose()?.flatten(), before.map(cursor_of).transpose()?.flatten()) {
                (Some(at), _) => {
                    let mut v = older(at, limit / 2)?;
                    let mut stmt = c.prepare_cached(&format!(
                        "SELECT {cols} {from} AND (m.ZMESSAGEDATE > ?2 OR (m.ZMESSAGEDATE = ?2 AND m.Z_PK >= ?3))
                         ORDER BY m.ZMESSAGEDATE, m.Z_PK LIMIT ?4"
                    ))?;
                    v.extend(stmt.query_map(params![chat_id, at.0, at.1, limit - limit / 2], message_row)?.collect::<Result<Vec<_>, _>>()?);
                    v
                }
                (None, Some(cut)) => older(cut, limit)?,
                (None, None) => older((f64::MAX, i64::MAX), limit)?,
            };
            messages.dedup_by_key(|m| m.id);
            let mut names = Mentions::new(c)?;
            for m in &mut messages {
                m.text = if matches!(m.kind, SYSTEM_KIND | NOTICE_KIND) {
                    names.event(m.kind, m.event, m.text.as_deref(), m.member.as_deref(), m.from_me)
                } else {
                    names.fix_opt(m.text.take())
                };
                if let Some(media) = &mut m.media {
                    media.title = names.fix_opt(media.title.take());
                }
            }
            let has_earlier = match messages.first().map(|m| cursor_of(m.id)).transpose()?.flatten() {
                Some((d, pk)) => c.query_row(
                    "SELECT EXISTS(SELECT 1 FROM ZWAMESSAGE WHERE ZCHATSESSION = ?1
                       AND (ZMESSAGEDATE < ?2 OR (ZMESSAGEDATE = ?2 AND Z_PK < ?3)))",
                    params![chat_id, d, pk],
                    |r| r.get(0),
                )?,
                None => false,
            };
            Ok(WaPage { messages, has_earlier })
        })
    })
    .await
}

/// Escape LIKE wildcards in a user term (`\` is the ESCAPE char).
fn like_term(t: &str) -> String {
    let esc = t.replace('\\', "\\\\").replace('%', "\\%").replace('_', "\\_");
    format!("%{esc}%")
}

/// Every word must appear in the message text or the media caption/filename.
/// ponytail: LIKE scan (~120k rows, tens of ms) and ASCII-only case folding;
/// an FTS index of our own if it gets slow or umlauts matter.
#[tauri::command]
pub async fn wa_search(query: String, limit: Option<i64>) -> Result<Vec<WaHit>, String> {
    let terms: Vec<String> = query.split_whitespace().map(like_term).take(8).collect();
    if terms.is_empty() {
        return Ok(vec![]);
    }
    let limit = limit.unwrap_or(100).clamp(1, 500);
    blocking(move || {
        with_conn(|c| {
            let wheres: Vec<String> = (0..terms.len())
                .map(|i| format!("(m.ZTEXT LIKE ?{n} ESCAPE '\\' OR i.ZTITLE LIKE ?{n} ESCAPE '\\')", n = i + 1))
                .collect();
            let picture = avatar_of("s.ZCONTACTJID");
            let sql = format!(
                "SELECT m.Z_PK, s.Z_PK, s.ZPARTNERNAME, s.ZSESSIONTYPE, m.ZISFROMME,
                        CASE WHEN g.Z_PK IS NULL THEN NULL ELSE {SENDER_NAME} END,
                        m.ZMESSAGEDATE,
                        -- Both when both exist: the hit may be in the caption or filename.
                        CASE WHEN nullif(m.ZTEXT, '') IS NOT NULL AND nullif(i.ZTITLE, '') IS NOT NULL AND i.ZTITLE <> m.ZTEXT
                             THEN m.ZTEXT || ' · ' || i.ZTITLE ELSE coalesce(nullif(m.ZTEXT, ''), i.ZTITLE, '') END,
                        coalesce(gi.ZPICTUREPATH, {picture})
                   FROM ZWAMESSAGE m
                   JOIN ZWACHATSESSION s ON s.Z_PK = m.ZCHATSESSION
                   LEFT JOIN ZWAGROUPINFO gi ON gi.Z_PK = s.ZGROUPINFO
                   LEFT JOIN ZWAGROUPMEMBER g ON g.Z_PK = m.ZGROUPMEMBER
                   LEFT JOIN ZWAMEDIAITEM i ON i.ZMESSAGE = m.Z_PK
                  WHERE s.ZSESSIONTYPE IN {SESSION_TYPES} AND coalesce(s.ZREMOVED, 0) = 0
                    AND coalesce(s.ZHIDDEN, 0) = 0
                    AND {}
                  ORDER BY m.ZMESSAGEDATE DESC LIMIT {limit}",
                wheres.join(" AND ")
            );
            let mut stmt = c.prepare(&sql)?;
            let rows = stmt.query_map(rusqlite::params_from_iter(terms.iter()), |r| {
                Ok(WaHit {
                    id: r.get(0)?,
                    chat_id: r.get(1)?,
                    chat_name: r.get::<_, Option<String>>(2)?.unwrap_or_default(),
                    is_group: r.get::<_, i64>(3)? == SESSION_GROUP,
                    from_me: r.get::<_, Option<i64>>(4)?.unwrap_or(0) != 0,
                    sender: r.get(5)?,
                    at: ms(r.get(6)?),
                    text: r.get(7)?,
                    chat_avatar: avatar(r.get(8)?),
                })
            })?;
            let mut hits: Vec<WaHit> = rows.collect::<Result<_, _>>()?;
            let mut names = Mentions::new(c)?;
            for h in &mut hits {
                h.text = names.fix(&h.text);
            }
            Ok(hits)
        })
    })
    .await
}

// ─── Reads for the Lore worker (whatsapp_lore.rs) ───────────────────────────

/// The newest message row id (the change marker).
pub(crate) fn head() -> Result<i64, String> {
    with_conn(|c| head_and_unread(c).map(|(h, _)| h))
}

/// The last message row id older than `days` — where a first scan starts, so
/// turning Lore on doesn't judge years of history.
pub(crate) fn head_before_days(days: i64) -> Result<i64, String> {
    let cut = (chrono::Utc::now().timestamp() as f64) - APPLE_EPOCH - (days * 86_400) as f64;
    with_conn(|c| c.query_row("SELECT coalesce(max(Z_PK), 0) FROM ZWAMESSAGE WHERE ZMESSAGEDATE < ?1", [cut], |r| r.get(0)))
}

pub(crate) struct LoreChat {
    pub id: i64,
    pub name: String,
    pub jid: String,
    pub is_group: bool,
    pub avatar: Option<String>,
}

/// 1:1 chats and groups with a message newer than `after` (a row id).
pub(crate) fn changed_chats(after: i64) -> Result<Vec<LoreChat>, String> {
    lore_chats("s.Z_PK IN (SELECT DISTINCT ZCHATSESSION FROM ZWAMESSAGE WHERE Z_PK > ?1)", after)
}

/// One chat by id (still a 1:1 chat or group, not removed), or None.
pub(crate) fn lore_chat(chat_id: i64) -> Result<Option<LoreChat>, String> {
    Ok(lore_chats("s.Z_PK = ?1", chat_id)?.pop())
}

/// An ask's change marker: how many messages it spans and the sum of the Core
/// Data versions (Z_OPT moves on any edit or delete of a row) of the messages
/// AND their media rows, where captions and quote metadata live.
pub(crate) fn ask_signature(chat_id: i64, from: i64, through: i64) -> Result<String, String> {
    with_conn(|c| {
        c.query_row(
            "SELECT count(*) || '.' || CAST(total(m.Z_OPT) AS INTEGER) || '.' || CAST(total(i.Z_OPT) AS INTEGER)
               FROM ZWAMESSAGE m LEFT JOIN ZWAMEDIAITEM i ON i.ZMESSAGE = m.Z_PK
              WHERE m.ZCHATSESSION = ?1 AND m.Z_PK BETWEEN ?2 AND ?3",
            params![chat_id, from, through],
            |r| r.get(0),
        )
    })
}

/// How many messages of an ask still make it one: incoming, with something to
/// say, and needing the owner (every message in a 1:1 chat; in a group only one
/// that still @mentions or quotes them). A deleted message stays as a "deleted"
/// row and an edit can drop the mention, so neither still counts.
pub(crate) fn ask_remaining(chat_id: i64, from: i64, through: i64) -> Result<usize, String> {
    ask_messages(chat_id, from, through).map(|m| m.len())
}

/// The messages of an ask that still make it one (see `ask_remaining`), oldest first.
pub(crate) fn ask_messages(chat_id: i64, from: i64, through: i64) -> Result<Vec<LoreMessage>, String> {
    with_conn(|c| {
        let me = own_jids(c)?;
        let jid = |i: usize| me.get(i).cloned().unwrap_or_default();
        let sql = format!("{} AND m.Z_PK BETWEEN ?2 AND ?5", lore_select());
        let mut rows: Vec<LoreMessage> = c
            .prepare_cached(&sql)?
            .query_map(params![chat_id, from, jid(0), jid(1), through], lore_row)?
            .collect::<Result<_, _>>()?;
        rows.retain(|m| !m.from_me && m.needs_me && !m.text.is_empty());
        rows.sort_by_key(|m| (m.at_ms, m.id));
        let mut names = Mentions::new(c)?;
        for m in &mut rows {
            m.text = names.fix(&m.text);
        }
        Ok(rows)
    })
}

fn lore_chats(filter: &str, arg: i64) -> Result<Vec<LoreChat>, String> {
    with_conn(|c| {
        let picture = avatar_of("s.ZCONTACTJID");
        let mut stmt = c.prepare_cached(&format!(
            "SELECT s.Z_PK, coalesce(s.ZPARTNERNAME, ''), coalesce(s.ZCONTACTJID, ''), s.ZSESSIONTYPE,
                    coalesce(gi.ZPICTUREPATH, {picture})
               FROM ZWACHATSESSION s LEFT JOIN ZWAGROUPINFO gi ON gi.Z_PK = s.ZGROUPINFO
              WHERE {filter}
                AND s.ZSESSIONTYPE IN {SESSION_TYPES} AND coalesce(s.ZREMOVED, 0) = 0"
        ))?;
        let rows = stmt.query_map([arg], |r| {
            Ok(LoreChat {
                id: r.get(0)?,
                name: r.get(1)?,
                jid: r.get(2)?,
                is_group: r.get::<_, i64>(3)? == SESSION_GROUP,
                avatar: avatar(r.get(4)?),
            })
        })?;
        rows.collect()
    })
}

pub(crate) struct LoreMessage {
    pub id: i64,
    pub from_me: bool,
    pub at_ms: i64,
    pub sender: Option<String>,
    pub text: String,
    /// Group messages: it @mentions the owner or quotes one of theirs. 1:1: always.
    pub needs_me: bool,
}

// The owner's own JIDs (phone and LID). WhatsApp keeps its own number encrypted
// (`OwnPhoneNumber` in the shared plist), so it's read from evidence instead:
//
// 1. Candidates: group members that never authored a message (the owner's group
//    messages carry no member row) in the groups the owner wrote in.
// 2. Proof: when someone quotes one of the owner's own messages, the quote
//    metadata carries that message's stanza id AND the owner's JID. The candidate
//    named in such quotes is the owner.
// 3. Its other half (LID ↔ phone) comes from LID.sqlite's account pairs.
//
// Without a proof (nobody ever quoted the owner) only an account pair stands in:
// a LID and its phone JID, paired in LID.sqlite, both in ¾ of those groups.
// Otherwise no JID is the owner and no group message counts as one for them.
const ME_CANDIDATES: &str = "WITH mine AS (
    SELECT DISTINCT m.ZCHATSESSION s FROM ZWAMESSAGE m JOIN ZWACHATSESSION cs ON cs.Z_PK = m.ZCHATSESSION
     WHERE cs.ZSESSIONTYPE = 1 AND m.ZISFROMME = 1),
  cand AS (
    SELECT g.ZMEMBERJID j, count(DISTINCT g.ZCHATSESSION) n FROM ZWAGROUPMEMBER g
     WHERE g.ZCHATSESSION IN (SELECT s FROM mine)
       AND NOT EXISTS (SELECT 1 FROM ZWAMESSAGE x WHERE x.ZGROUPMEMBER = g.Z_PK)
     GROUP BY 1 ORDER BY n DESC LIMIT 12),
  my AS (SELECT ZSTANZAID st FROM ZWAMESSAGE WHERE ZISFROMME = 1 AND length(ZSTANZAID) > 8 ORDER BY Z_PK DESC LIMIT 200),
  quoting AS (
    SELECT i.ZMETADATA md FROM ZWAMESSAGE m JOIN ZWAMEDIAITEM i ON i.ZMESSAGE = m.Z_PK
     WHERE m.ZISFROMME = 0 AND i.ZMETADATA IS NOT NULL AND m.Z_PK > (SELECT max(Z_PK) - 20000 FROM ZWAMESSAGE)
       AND EXISTS (SELECT 1 FROM my WHERE instr(i.ZMETADATA, CAST(my.st AS BLOB)) > 0))
  SELECT j, n, (SELECT count(*) FROM mine),
         (SELECT count(*) FROM quoting WHERE instr(md, CAST(j AS BLOB)) > 0)
    FROM cand";

/// The other half of a JID's LID ↔ phone pair, from LID.sqlite.
fn paired_jid(c: &Connection, jid: &str) -> rusqlite::Result<Option<String>> {
    let (id, kind) = jid.split_once('@').unwrap_or((jid, ""));
    if kind == "lid" {
        c.query_row("SELECT ZPHONENUMBER FROM l.ZWAZACCOUNT WHERE ZIDENTIFIER = ?1 AND ZPHONENUMBER <> '' LIMIT 1", [jid], |r| r.get::<_, String>(0))
            .optional()
            .map(|p| p.map(|p| format!("{p}@s.whatsapp.net")))
    } else {
        c.query_row("SELECT ZIDENTIFIER FROM l.ZWAZACCOUNT WHERE ZPHONENUMBER = ?1 AND ZIDENTIFIER LIKE '%@lid' LIMIT 1", [id], |r| r.get(0))
            .optional()
    }
}

/// See above; cached for ten minutes.
fn own_jids(c: &Connection) -> rusqlite::Result<Vec<String>> {
    static CACHE: Mutex<Option<(std::time::Instant, Vec<String>)>> = Mutex::new(None);
    if let Some((at, jids)) = CACHE.lock().unwrap().as_ref() {
        if at.elapsed() < std::time::Duration::from_secs(600) {
            return Ok(jids.clone());
        }
    }
    let rows: Vec<(String, i64, i64, i64)> = c
        .prepare_cached(ME_CANDIDATES)?
        .query_map([], |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?, r.get(3)?)))?
        .collect::<Result<_, _>>()?;
    let proven = rows.iter().filter(|r| r.3 > 0).max_by_key(|r| r.3).map(|r| r.0.clone());
    let jids = match proven {
        Some(me) => {
            let mut v = vec![me.clone()];
            v.extend(paired_jid(c, &me)?);
            v
        }
        // No quote proves it: only a LID and a phone JID that LID.sqlite records as
        // ONE account, both silent members of (nearly) every group the owner wrote
        // in, stand in. Silent strangers are never one account, so they can't pass.
        None => {
            let wide: Vec<&String> = rows.iter().filter(|r| r.2 > 0 && r.1 * 4 >= r.2 * 3).map(|r| &r.0).collect();
            let mut pair = Vec::new();
            for j in &wide {
                if let Some(other) = paired_jid(c, j)? {
                    if wide.iter().any(|w| **w == other) {
                        pair = vec![(*j).clone(), other];
                        break;
                    }
                }
            }
            pair
        }
    };
    *CACHE.lock().unwrap() = Some((std::time::Instant::now(), jids.clone()));
    Ok(jids)
}

/// `?3`/`?4` (own JIDs): does a group message ask the owner? Its FIRST @mention
/// (text or media caption, from the first `@` on) is that whole number (not one
/// that merely starts with it), or it quotes the owner without @-addressing
/// anyone. "Hi @X, following up on @You's message" (a quote of the owner's, with
/// the owner mentioned too) asks X. ZMETADATA holds the quoted author AND every
/// mentioned JID, so it only counts when the text mentions no one. An empty JID
/// matches nothing.
/// ponytail: first-mention rule; "@X and @You, can you both…" is missed — let the
/// model judge the addressee if that turns up.
const MENTIONS_ME: &str = "(?3 <> '' AND (substr((coalesce(m.ZTEXT, '') || ' ' || coalesce(i.ZTITLE, '') || ' '), instr((coalesce(m.ZTEXT, '') || ' ' || coalesce(i.ZTITLE, '') || ' '), '@')) GLOB '@' || substr(?3, 1, instr(?3, '@') - 1) || '[^0-9]*'
        OR (instr((coalesce(m.ZTEXT, '') || ' ' || coalesce(i.ZTITLE, '') || ' '), '@') = 0 AND instr(i.ZMETADATA, CAST(?3 AS BLOB)) > 0)))
    OR (?4 <> '' AND (substr((coalesce(m.ZTEXT, '') || ' ' || coalesce(i.ZTITLE, '') || ' '), instr((coalesce(m.ZTEXT, '') || ' ' || coalesce(i.ZTITLE, '') || ' '), '@')) GLOB '@' || substr(?4, 1, instr(?4, '@') - 1) || '[^0-9]*'
        OR (instr((coalesce(m.ZTEXT, '') || ' ' || coalesce(i.ZTITLE, '') || ' '), '@') = 0 AND instr(i.ZMETADATA, CAST(?4 AS BLOB)) > 0)))";

/// Lore's message columns (`?3`/`?4` = own JIDs for MENTIONS_ME); filters follow.
fn lore_select() -> String {
    format!(
        "SELECT m.Z_PK, m.ZISFROMME, m.ZMESSAGEDATE, m.ZMESSAGETYPE,
                CASE WHEN g.Z_PK IS NULL THEN NULL ELSE {SENDER_NAME} END,
                m.ZTEXT, i.ZTITLE,
                coalesce(s.ZSESSIONTYPE <> {SESSION_GROUP} OR {MENTIONS_ME}, 0)
           FROM ZWAMESSAGE m
           JOIN ZWACHATSESSION s ON s.Z_PK = m.ZCHATSESSION
           LEFT JOIN ZWAGROUPMEMBER g ON g.Z_PK = m.ZGROUPMEMBER
           LEFT JOIN ZWAMEDIAITEM i ON i.ZMESSAGE = m.Z_PK
          WHERE m.ZCHATSESSION = ?1"
    )
}

/// A [`lore_select`] row as the text the models read (media named in brackets).
fn lore_row(r: &rusqlite::Row) -> rusqlite::Result<LoreMessage> {
    let kind: i64 = r.get::<_, Option<i64>>(3)?.unwrap_or(0);
    let text: Option<String> = r.get(5)?;
    let title: Option<String> = r.get(6)?;
    let text = match kind {
        0 | 7 => text.unwrap_or_default(),
        1 => format!("[photo] {}", title.unwrap_or_default()),
        2 => format!("[video] {}", title.unwrap_or_default()),
        3 => "[voice message]".into(),
        8 => format!("[document: {}]", text.or(title).unwrap_or_default()),
        5 => "[location]".into(),
        4 => "[contact card]".into(),
        _ => String::new(),
    };
    Ok(LoreMessage {
        id: r.get(0)?,
        from_me: r.get::<_, Option<i64>>(1)?.unwrap_or(0) != 0,
        at_ms: ms(r.get(2)?),
        sender: r.get(4)?,
        text: text.trim().to_string(),
        needs_me: r.get(7)?,
    })
}

/// A tracked group's messages after row `after` (the newest `keep`), oldest
/// first, mentions resolved: what its to-do list is updated from.
pub(crate) fn lore_messages_after(chat_id: i64, after: i64, keep: i64) -> Result<Vec<LoreMessage>, String> {
    with_conn(|c| {
        let me = own_jids(c)?;
        let jid = |i: usize| me.get(i).cloned().unwrap_or_default();
        let sql = format!("{} AND m.Z_PK > ?2 ORDER BY m.ZMESSAGEDATE DESC, m.Z_PK DESC LIMIT ?5", lore_select());
        let mut rows: Vec<LoreMessage> = c
            .prepare_cached(&sql)?
            .query_map(params![chat_id, after, jid(0), jid(1), keep], lore_row)?
            .collect::<Result<_, _>>()?;
        rows.retain(|m| !m.text.is_empty());
        let mut names = Mentions::new(c)?;
        for m in &mut rows {
            m.text = names.fix(&m.text);
        }
        rows.reverse();
        Ok(rows)
    })
}

/// A group's messages sent in `[from_ms, to_ms)` (the newest `keep`, so a busy
/// day's summary still reaches its latest), oldest first, mentions resolved:
/// what a day summary is written from.
pub(crate) fn lore_messages_between(chat_id: i64, from_ms: i64, to_ms: i64, keep: i64) -> Result<Vec<LoreMessage>, String> {
    let apple = |ms: i64| ms as f64 / 1000.0 - APPLE_EPOCH;
    with_conn(|c| {
        let me = own_jids(c)?;
        let jid = |i: usize| me.get(i).cloned().unwrap_or_default();
        let sql = format!(
            "{} AND m.ZMESSAGEDATE >= ?2 AND m.ZMESSAGEDATE < ?5 ORDER BY m.ZMESSAGEDATE DESC, m.Z_PK DESC LIMIT ?6",
            lore_select()
        );
        let mut rows: Vec<LoreMessage> = c
            .prepare_cached(&sql)?
            .query_map(params![chat_id, apple(from_ms), jid(0), jid(1), apple(to_ms), keep], lore_row)?
            .collect::<Result<_, _>>()?;
        rows.retain(|m| !m.text.is_empty());
        let mut names = Mentions::new(c)?;
        for m in &mut rows {
            m.text = names.fix(&m.text);
        }
        rows.reverse();
        Ok(rows)
    })
}

/// Most messages after the owner's last reply that Lore reads in one chat (an
/// ask longer than this is judged on its newest part).
const LORE_AFTER_REPLY: i64 = 500;
/// Message kinds that say something (a reply counts only when it is one of these).
const CONTENT_KINDS: &str = "(0, 1, 2, 3, 4, 5, 7, 8, 11, 15)";

/// A chat as Lore reads it, oldest first, as text the models read (media named
/// in brackets; protocol rows left out): every message after the owner's last
/// reply (the ask lives there, however many arrived since) plus `context`
/// messages up to and including that reply.
pub(crate) fn lore_messages(chat_id: i64, context: i64) -> Result<Vec<LoreMessage>, String> {
    with_conn(|c| {
        // Computed once per call: inside the row query it would rerun per message.
        let me = own_jids(c)?;
        let jid = |i: usize| me.get(i).cloned().unwrap_or_default();
        // The owner's last reply, as a (date, row id) cut; none = before everything.
        let cut: (f64, i64) = c
            .query_row(
                &format!(
                    "SELECT ZMESSAGEDATE, Z_PK FROM ZWAMESSAGE WHERE ZCHATSESSION = ?1 AND ZISFROMME = 1
                       AND ZMESSAGETYPE IN {CONTENT_KINDS} AND ZMESSAGEDATE IS NOT NULL
                     ORDER BY ZMESSAGEDATE DESC, Z_PK DESC LIMIT 1"
                ),
                [chat_id],
                |r| Ok((r.get(0)?, r.get(1)?)),
            )
            .optional()?
            .unwrap_or((f64::MIN, i64::MIN));
        let select = lore_select();
        // After the reply (newest LORE_AFTER_REPLY), and the context up to and including it.
        let after = format!("{select} AND (m.ZMESSAGEDATE > ?5 OR (m.ZMESSAGEDATE = ?5 AND m.Z_PK > ?6))
                             ORDER BY m.ZMESSAGEDATE DESC, m.Z_PK DESC LIMIT ?2");
        let before = format!("{select} AND (m.ZMESSAGEDATE < ?5 OR (m.ZMESSAGEDATE = ?5 AND m.Z_PK <= ?6))
                              ORDER BY m.ZMESSAGEDATE DESC, m.Z_PK DESC LIMIT ?2");
        let read = |sql: &str, n: i64| -> rusqlite::Result<Vec<LoreMessage>> {
            c.prepare_cached(sql)?
                .query_map(params![chat_id, n, jid(0), jid(1), cut.0, cut.1], lore_row)?
            .collect()
        };
        // Newest first from both reads; reversed to oldest first below.
        let mut rows = read(&after, LORE_AFTER_REPLY)?;
        rows.extend(read(&before, context)?);
        rows.retain(|m| !m.text.is_empty());
        let mut names = Mentions::new(c)?;
        for m in &mut rows {
            m.text = names.fix(&m.text);
        }
        rows.reverse();
        Ok(rows)
    })
}

#[derive(Serialize)]
pub struct WaMediaItem {
    pub id: i64,
    pub kind: i64,
    pub path: String,
    pub thumb: Option<String>,
    pub at: i64,
    pub from_me: bool,
    pub sender: Option<String>,
    pub name: Option<String>,
}

/// A chat's downloaded photos, videos and GIFs, oldest first: the media
/// viewer's ← → order.
#[tauri::command]
pub async fn wa_chat_media(chat_id: i64) -> Result<Vec<WaMediaItem>, String> {
    blocking(move || {
        with_conn(|c| {
            let sql = format!(
                "SELECT m.Z_PK, m.ZMESSAGETYPE, i.ZMEDIALOCALPATH, i.ZXMPPTHUMBPATH, m.ZMESSAGEDATE, m.ZISFROMME,
                        CASE WHEN g.Z_PK IS NULL THEN NULL ELSE {SENDER_NAME} END
                   FROM ZWAMESSAGE m
                   JOIN ZWAMEDIAITEM i ON i.ZMESSAGE = m.Z_PK
                   LEFT JOIN ZWAGROUPMEMBER g ON g.Z_PK = m.ZGROUPMEMBER
                  WHERE m.ZCHATSESSION = ?1 AND m.ZMESSAGETYPE IN (1, 2, 11) AND i.ZMEDIALOCALPATH IS NOT NULL
                  ORDER BY m.ZMESSAGEDATE, m.Z_PK LIMIT 5000"
            );
            let mut stmt = c.prepare_cached(&sql)?;
            let rows = stmt.query_map([chat_id], |r| {
                let stored: Option<String> = r.get(2)?;
                Ok((
                    on_disk(message_media(stored.clone())),
                    WaMediaItem {
                        id: r.get(0)?,
                        kind: r.get(1)?,
                        path: String::new(),
                        thumb: on_disk(message_media(r.get(3)?)),
                        at: ms(r.get(4)?),
                        from_me: r.get::<_, Option<i64>>(5)?.unwrap_or(0) != 0,
                        sender: r.get(6)?,
                        name: stored.as_deref().and_then(|p| p.rsplit('/').next()).map(str::to_string),
                    },
                ))
            })?;
            // Only what is on disk: the rest has nothing to show.
            Ok(rows
                .filter_map(|r| r.ok())
                .filter_map(|(path, item)| path.map(|path| WaMediaItem { path, ..item }))
                .collect())
        })
    })
    .await
}

/// A media path the webview handed back → the absolute file, refused unless it
/// is an attachment or avatar inside the container.
/// `media_file` for the engine bus: a client on the same machine (the CLI) opens
/// or copies the file itself. Same container guard as every other media call.
pub fn media_file_path(path: &str) -> Result<String, String> {
    Ok(media_file(path)?.to_string_lossy().into_owned())
}

fn media_file(path: &str) -> Result<PathBuf, String> {
    is_media(path).then(|| resolve(path)).flatten().ok_or_else(|| "File not found".into())
}

/// `name` → a name not yet taken in `dir` ("photo.jpg", "photo (1).jpg", …).
fn free_name(dir: &Path, name: &str) -> PathBuf {
    let first = dir.join(name);
    if !first.exists() {
        return first;
    }
    let (stem, ext) = match name.rsplit_once('.') {
        Some((s, e)) if !s.is_empty() => (s.to_string(), format!(".{e}")),
        _ => (name.to_string(), String::new()),
    };
    (1..).map(|n| dir.join(format!("{stem} ({n}){ext}"))).find(|p| !p.exists()).unwrap()
}

/// Copy an attachment out of WhatsApp's folder (the original is never moved):
/// to ~/Downloads, or where the person picks when `ask`. The saved path, or
/// None when the dialog was cancelled.
#[tauri::command]
pub async fn wa_save_media(window: tauri::WebviewWindow, path: String, name: Option<String>, ask: bool) -> Result<Option<String>, String> {
    use tauri::Manager;
    let src = media_file(&path)?;
    // A name from the message, kept to its last segment so it can't point elsewhere.
    let name = name
        .as_deref()
        .and_then(|n| Path::new(n).file_name())
        .or_else(|| src.file_name())
        .map(|n| n.to_string_lossy().into_owned())
        .unwrap_or_else(|| "attachment".into());
    let dest = if ask {
        let (tx, rx) = tokio::sync::oneshot::channel();
        let win = window.clone();
        let suggested = name.clone();
        window
            .run_on_main_thread(move || {
                let _ = tx.send(rfd::FileDialog::new().set_file_name(&suggested).set_parent(&win).save_file());
            })
            .map_err(|e| e.to_string())?;
        match rx.await.map_err(|e| e.to_string())? {
            Some(p) => p,
            None => return Ok(None),
        }
    } else {
        let dir = window.app_handle().path().download_dir().map_err(|e| e.to_string())?;
        free_name(&dir, &name)
    };
    std::fs::copy(&src, &dest).map_err(|e| e.to_string())?;
    Ok(Some(dest.to_string_lossy().into_owned()))
}

/// Show an attachment in Finder.
#[tauri::command]
pub fn wa_reveal_media(app: tauri::AppHandle, path: String) -> Result<(), String> {
    use tauri_plugin_opener::OpenerExt;
    app.opener().reveal_item_in_dir(media_file(&path)?).map_err(|e| e.to_string())
}

/// Open a downloaded attachment (video, voice note, document) in its default app.
#[tauri::command]
pub fn wa_open_media(app: tauri::AppHandle, path: String) -> Result<(), String> {
    let file = is_media(&path).then(|| resolve(&path)).flatten().ok_or("File not found")?;
    crate::commands::open_path_default(&app, &file)
}

async fn blocking<T: Send + 'static>(f: impl FnOnce() -> Result<T, String> + Send + 'static) -> Result<T, String> {
    tauri::async_runtime::spawn_blocking(f).await.map_err(|e| e.to_string())?
}

/// A container-relative path → an absolute file, refusing anything that
/// escapes the WhatsApp container (`..`, symlinks out).
fn resolve(rel: &str) -> Option<PathBuf> {
    let root = root()?.canonicalize().ok()?;
    let file = root.join(rel.trim_start_matches('/')).canonicalize().ok()?;
    (file.starts_with(&root) && file.is_file()).then_some(file)
}

fn percent_decode(s: &str) -> String {
    let b = s.as_bytes();
    let mut out = Vec::with_capacity(b.len());
    let mut i = 0;
    while i < b.len() {
        let hex = |c: u8| (c as char).to_digit(16);
        if b[i] == b'%' && i + 2 < b.len() {
            if let (Some(h), Some(l)) = (hex(b[i + 1]), hex(b[i + 2])) {
                out.push((h * 16 + l) as u8);
                i += 3;
                continue;
            }
        }
        out.push(b[i]);
        i += 1;
    }
    String::from_utf8_lossy(&out).into_owned()
}

fn content_type(path: &Path) -> &'static str {
    match path.extension().and_then(|e| e.to_str()).map(str::to_ascii_lowercase).as_deref() {
        // WhatsApp's thumbnails are JPEGs under their own extensions.
        Some("jpg" | "jpeg" | "thumb" | "mmsthumb") => "image/jpeg",
        Some("png") => "image/png",
        Some("webp") => "image/webp",
        Some("gif") => "image/gif",
        Some("mp4" | "m4v") => "video/mp4",
        Some("mov") => "video/quicktime",
        // Voice notes are Ogg Opus.
        Some("opus" | "ogg") => "audio/ogg",
        Some("m4a" | "aac") => "audio/mp4",
        Some("mp3") => "audio/mpeg",
        Some("pdf") => "application/pdf",
        _ => "application/octet-stream",
    }
}

/// Only attachments and avatars are served — never the databases or anything
/// else in the container.
fn is_media(rel: &str) -> bool {
    let rel = rel.trim_start_matches('/');
    (rel.starts_with("Message/Media/") || rel.starts_with("Media/Profile/")) && !rel.contains("..")
}

/// The app's own webview origins (production bundle and the dev server).
fn is_app_origin(origin: &str) -> bool {
    matches!(origin, "tauri://localhost" | "http://tauri.localhost" | "https://tauri.localhost")
        || origin.strip_prefix("http://localhost:").is_some_and(|p| p.chars().all(|c| c.is_ascii_digit()))
}

/// Video and audio up to this size go out whole when no range is asked; bigger
/// ones in chunks. Other files always go out whole.
const WHOLE_MAX: u64 = 32 * 1024 * 1024;
/// The most a whole (non-range) response holds: a bigger document isn't read
/// into memory for a preview (413); "Open" hands it to its own app instead.
const DOC_MAX: u64 = 128 * 1024 * 1024;

/// Largest slice served for an open-ended range (`bytes=N-`): WebKit asks for
/// video and audio a piece at a time and comes back for more.
const RANGE_CHUNK: u64 = 4 * 1024 * 1024;

/// `bytes=a-b` / `bytes=a-` / `bytes=-n` against a file of `len` bytes →
/// the inclusive (start, end), or None when it doesn't fit.
fn parse_range(header: &str, len: u64) -> Option<(u64, u64)> {
    let spec = header.trim().strip_prefix("bytes=")?.split(',').next()?.trim();
    let (a, b) = spec.split_once('-')?;
    let (start, end) = match (a.trim(), b.trim()) {
        ("", n) => {
            let n: u64 = n.parse().ok()?;
            (len.saturating_sub(n), len.checked_sub(1)?)
        }
        (a, "") => (a.parse().ok()?, len.checked_sub(1)?),
        (a, b) => (a.parse().ok()?, b.parse::<u64>().ok()?.min(len.checked_sub(1)?)),
    };
    // Every range, explicit ones too, is served in at most one chunk (players ask
    // for the rest): a `bytes=0-<huge>` must not pull a whole video into memory.
    let end = end.min(start.saturating_add(RANGE_CHUNK - 1));
    (start <= end && start < len).then_some((start, end))
}

/// `wamedia://localhost/<container-relative path>` → the file's bytes, with
/// byte ranges (206) so the webview can play and seek video and audio.
pub fn serve_media(request: &tauri::http::Request<Vec<u8>>) -> tauri::http::Response<Vec<u8>> {
    use std::io::{Read, Seek, SeekFrom};
    let not_found = || tauri::http::Response::builder().status(404).body(Vec::new()).unwrap();
    let rel = percent_decode(request.uri().path());
    let Some(path) = is_media(&rel).then(|| resolve(&rel)).flatten() else { return not_found() };
    let Ok(mut file) = std::fs::File::open(&path) else { return not_found() };
    let len = file.metadata().map(|m| m.len()).unwrap_or(0);
    // A big video or voice note asked for whole (no Range) is served from its
    // start in one bounded chunk (206): it never lands in memory all at once, and
    // players ask for the rest by range. Everything else (documents the preview
    // engine reads in one fetch) always goes out whole.
    let streams = content_type(&path).starts_with("video/") || content_type(&path).starts_with("audio/");
    let range = match request.headers().get("range").and_then(|v| v.to_str().ok()) {
        Some(h) => Some(parse_range(h, len)),
        None if streams && len > WHOLE_MAX => Some(parse_range("bytes=0-", len)),
        None => None,
    };
    let mut builder = tauri::http::Response::builder()
        .header("Content-Type", content_type(&path))
        .header("Accept-Ranges", "bytes")
        .header("Cache-Control", "max-age=3600");
    // The preview renderers fetch() the bytes (PDF, Office, waveform): allow the
    // app's own pages, and only them.
    if let Some(origin) = request.headers().get("origin").and_then(|v| v.to_str().ok()).filter(|o| is_app_origin(o)) {
        builder = builder.header("Access-Control-Allow-Origin", origin).header("Vary", "Origin");
    }
    match range {
        // Asked for a range that isn't there.
        Some(None) => tauri::http::Response::builder()
            .status(416)
            .header("Content-Range", format!("bytes */{len}"))
            .body(Vec::new())
            .unwrap(),
        Some(Some((start, end))) => {
            let mut buf = vec![0; (end - start + 1) as usize];
            if file.seek(SeekFrom::Start(start)).and_then(|_| file.read_exact(&mut buf)).is_err() {
                return not_found();
            }
            builder.status(206).header("Content-Range", format!("bytes {start}-{end}/{len}")).body(buf).unwrap()
        }
        None if len > DOC_MAX => tauri::http::Response::builder().status(413).body(Vec::new()).unwrap(),
        None => {
            let mut buf = Vec::with_capacity(len as usize);
            if file.read_to_end(&mut buf).is_err() {
                return not_found();
            }
            builder.body(buf).unwrap()
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn app_origins_only() {
        assert!(is_app_origin("tauri://localhost"));
        assert!(is_app_origin("http://localhost:4173"));
        assert!(!is_app_origin("http://localhost:4173.evil.com"));
        assert!(!is_app_origin("https://evil.example"));
    }

    #[test]
    fn free_names_never_overwrite() {
        let dir = std::env::temp_dir().join(format!("wa-free-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        assert_eq!(free_name(&dir, "a.jpg"), dir.join("a.jpg"));
        std::fs::write(dir.join("a.jpg"), b"x").unwrap();
        assert_eq!(free_name(&dir, "a.jpg"), dir.join("a (1).jpg"));
        std::fs::remove_dir_all(&dir).unwrap();
    }

    #[test]
    fn parses_byte_ranges() {
        assert_eq!(parse_range("bytes=0-1", 10), Some((0, 1)));
        assert_eq!(parse_range("bytes=4-", 10), Some((4, 9)));
        assert_eq!(parse_range("bytes=-3", 10), Some((7, 9)));
        assert_eq!(parse_range("bytes=0-99", 10), Some((0, 9)));
        assert_eq!(parse_range("bytes=10-", 10), None);
        assert_eq!(parse_range("bytes=0-", 0), None);
        assert_eq!(parse_range("items=0-1", 10), None);
        let big = 10 * RANGE_CHUNK;
        assert_eq!(parse_range("bytes=0-", big), Some((0, RANGE_CHUNK - 1)));
        assert_eq!(parse_range(&format!("bytes=0-{}", big - 1), big), Some((0, RANGE_CHUNK - 1)));
        assert_eq!(parse_range(&format!("bytes={}-{}", u64::MAX - 1, u64::MAX), big), None);
    }

    #[test]
    fn decodes_and_escapes() {
        assert_eq!(percent_decode("/Media/a%20b/c%40g.us/x.jpg"), "/Media/a b/c@g.us/x.jpg");
        assert_eq!(percent_decode("/50%"), "/50%");
        assert_eq!(like_term("50%_off\\"), "%50\\%\\_off\\\\%");
    }

    /// Runs against this Mac's real WhatsApp database when there is one.
    #[test]
    fn reads_this_macs_whatsapp() {
        if !root().is_some_and(|r| r.join("ChatStorage.sqlite").exists()) {
            return;
        }
        tauri::async_runtime::block_on(async {
            let t = std::time::Instant::now();
            let s = wa_status().await;
            assert!(s.available, "{:?}", s.error);
            let chats = wa_chats().await.unwrap();
            assert!(!chats.is_empty());
            // Previews are message text (not the encoded blob) and dates are real.
            let year = |ms: i64| chrono::DateTime::from_timestamp_millis(ms).unwrap().format("%Y").to_string().parse::<i32>().unwrap();
            assert!(chats.iter().take(20).all(|c| year(c.last_at) <= 2100), "a chat date is in the far future");
            assert!(chats.iter().take(20).all(|c| !c.last_text.as_deref().unwrap_or("").contains("//////")));
            let page = wa_messages(chats[0].id, None, None, Some(50)).await.unwrap();
            let first = page.messages.first().expect("newest chat has messages").id;
            let around = wa_messages(chats[0].id, None, Some(first), Some(10)).await.unwrap();
            assert!(around.messages.iter().any(|m| m.id == first));
            let hits = wa_search("de".into(), Some(20)).await.unwrap();
            assert!(hits.iter().all(|h| h.text.to_lowercase().contains("de")));
            eprintln!("head {} unread {} chats {} page {} hits {} in {:?}", s.head, s.unread, chats.len(), page.messages.len(), hits.len(), t.elapsed());
        });
    }

    /// Load-earlier walks a whole chat with no gaps or repeats, ties included.
    #[test]
    fn pages_cover_a_chat_exactly() {
        if !root().is_some_and(|r| r.join("ChatStorage.sqlite").exists()) {
            return;
        }
        tauri::async_runtime::block_on(async {
            let chat = wa_chats().await.unwrap().into_iter().next().unwrap();
            let total: i64 = with_conn(|c| c.query_row("SELECT count(*) FROM ZWAMESSAGE WHERE ZCHATSESSION = ?1 AND ZMESSAGEDATE IS NOT NULL", [chat.id], |r| r.get(0))).unwrap();
            let mut seen = std::collections::HashSet::new();
            let mut page = wa_messages(chat.id, None, None, Some(7)).await.unwrap();
            loop {
                for m in &page.messages {
                    assert!(seen.insert(m.id), "message {} paged twice", m.id);
                }
                if !page.has_earlier {
                    break;
                }
                page = wa_messages(chat.id, Some(page.messages[0].id), None, Some(7)).await.unwrap();
            }
            assert_eq!(seen.len() as i64, total);
        });
    }

    /// `@<number>` mentions resolve to names on this Mac; the owner reads as "You".
    #[test]
    fn resolves_mentions() {
        if !root().is_some_and(|r| r.join("ChatStorage.sqlite").exists()) {
            return;
        }
        with_conn(|c| {
            // The owner is proven by quotes of their own messages, both halves of the pair found.
            let own = own_jids(c)?;
            assert!(own.iter().any(|j| j.ends_with("@lid")) && own.iter().any(|j| j.ends_with("@s.whatsapp.net")), "{own:?}");
            let mut m = Mentions::new(c)?;
            let me = m.me.first().cloned().unwrap_or_default();
            if !me.is_empty() {
                assert_eq!(m.fix(&format!("[photo] @{me} siiiii")), "[photo] @You siiiii");
            }
            assert_eq!(m.fix("mail me @ 10 or @home, e-mail a@b.nl"), "mail me @ 10 or @home, e-mail a@b.nl");
            assert_eq!(m.fix("@123"), "@123");
            // The SQL mention check needs the whole number: @<me>7 is someone else.
            if !me.is_empty() {
                let hit = |t: String| -> rusqlite::Result<bool> {
                    c.query_row(
                        "SELECT (?1 || ' ') GLOB '*@' || ?2 || '[^0-9]*'",
                        params![t, me],
                        |r| r.get(0),
                    )
                };
                assert!(hit(format!("hoi @{me}, kijk"))?);
                assert!(hit(format!("@{me}"))?);
                assert!(!hit(format!("hoi @{me}7"))?);
            }
            Ok(())
        })
        .unwrap();
    }

    /// Chat previews name people: no raw JIDs from group events, and a LID
    /// mention that LID.sqlite pairs with a phone shows a name or that number.
    #[test]
    fn previews_name_people() {
        if !root().is_some_and(|r| r.join("ChatStorage.sqlite").exists()) {
            return;
        }
        let chats = tauri::async_runtime::block_on(wa_chats()).unwrap();
        let raw: Vec<_> = chats
            .iter()
            .filter_map(|c| c.last_text.as_deref())
            .filter(|t| t.contains("@lid") || t.contains("@s.whatsapp.net") || t.contains("@g.us"))
            .collect();
        assert!(raw.is_empty(), "{raw:?}");
        // Pinned chats are the ones WhatsApp keeps on top.
        let unpinned = chats.iter().position(|c| !c.pinned).unwrap_or(chats.len());
        assert!(chats[unpinned..].iter().all(|c| !c.pinned), "a pinned chat below an unpinned one");
        with_conn(|c| {
            let paired: Option<String> = c
                .query_row("SELECT ZIDENTIFIER FROM l.ZWAZACCOUNT WHERE ZIDENTIFIER LIKE '%@lid' AND ZPHONENUMBER <> '' LIMIT 1", [], |r| r.get(0))
                .optional()?;
            let mut m = Mentions::new(c)?;
            if let Some(lid) = paired {
                let digits = lid.split('@').next().unwrap();
                assert!(!m.fix(&format!("hi @{digits}")).contains(digits), "{lid} stayed a number");
            }
            assert_eq!(m.event(SYSTEM_KIND, Some(7), Some("1@lid"), Some("31600000000@s.whatsapp.net"), false).as_deref(), Some("someone removed +31600000000"));
            assert_eq!(m.event(SYSTEM_KIND, Some(4), None, None, true).as_deref(), Some("You changed this group's icon"));
            assert_eq!(m.event(NOTICE_KIND, Some(91), Some("1@lid"), None, false).as_deref(), Some("Your personal messages are end-to-end encrypted"));
            assert_eq!(m.event(SYSTEM_KIND, Some(12), Some("{\"x\":1}"), None, false), None);
            Ok(())
        })
        .unwrap();
    }

    /// Downloaded photos resolve to files on disk (they live under `Message/`).
    #[test]
    fn downloaded_photos_resolve() {
        if !root().is_some_and(|r| r.join("ChatStorage.sqlite").exists()) {
            return;
        }
        let rels: Vec<String> = with_conn(|c| {
            c.prepare("SELECT ZMEDIALOCALPATH FROM ZWAMEDIAITEM WHERE ZMEDIALOCALPATH LIKE '%.jpg' ORDER BY Z_PK DESC LIMIT 20")?
                .query_map([], |r| r.get(0))?
                .collect()
        })
        .unwrap();
        let found = rels.into_iter().filter_map(|r| on_disk(message_media(Some(r)))).collect::<Vec<_>>();
        assert!(!found.is_empty(), "no downloaded photo resolved");
        assert!(found.iter().all(|p| is_media(p)), "{found:?}");
    }

    #[test]
    fn serves_media_only() {
        assert!(is_media("/Message/Media/x@g.us/8/5/a.jpg"));
        assert!(is_media("/Media/Profile/3164-1.jpg"));
        assert!(!is_media("/ChatStorage.sqlite"));
        assert!(!is_media("/Message/Media/../../ChatStorage.sqlite"));
    }

    #[test]
    fn refuses_escaping_the_container() {
        assert!(resolve("../../../../etc/passwd").is_none());
    }
}
