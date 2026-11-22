//! Server-sent "Disk changed" signals, so Finder updates within seconds
//! (docs/Disk-Sync.md). An ActionCable socket on OrganizationChannel: every
//! Disk write on the API broadcasts `{ type: "sync", scope: "disk" }` there.
//! It runs in the host's Rust process (the desktop app's backend), not in a
//! webview, so it keeps working with every window closed. A hint only: it
//! carries no data, and a lost one costs the host's 30-second check.

use std::net::TcpStream;
use std::time::Duration;

use serde_json::{json, Value};
use tungstenite::client::IntoClientRequest;
use tungstenite::http::HeaderValue;
use tungstenite::stream::MaybeTlsStream;
use tungstenite::{Message, WebSocket};

use super::model::{DiskError, DiskResult};

/// ActionCable pings every 3 s; this long without any frame means the socket is dead.
const SILENT_FOR: Duration = Duration::from_secs(12);

/// What arrived on the socket.
#[derive(Debug, PartialEq, Eq)]
pub enum Signal {
    /// Subscribed (first time or after a reconnect): signals may have been missed, so pull.
    Subscribed,
    /// A Disk write on the server.
    DiskChanged,
    /// Anything else: pings, welcome, mail and directory hints.
    Other,
}

/// `https://api.inbox2.com/api/v1` → `wss://api.inbox2.com/cable`.
pub fn cable_url(api_base: &str) -> String {
    let base = api_base.trim_end_matches('/');
    let host = base.strip_suffix("/api/v1").unwrap_or(base);
    let ws = host.replacen("https://", "wss://", 1).replacen("http://", "ws://", 1);
    format!("{ws}/cable")
}

fn identifier(org: &str) -> String {
    json!({ "channel": "OrganizationChannel", "key": org }).to_string()
}

pub fn parse(frame: &str, org: &str) -> Signal {
    let Ok(v) = serde_json::from_str::<Value>(frame) else { return Signal::Other };
    let ours = v["identifier"].as_str().and_then(|i| serde_json::from_str::<Value>(i).ok()).is_some_and(|i| i["key"] == org);
    if v["type"] == "confirm_subscription" && ours {
        return Signal::Subscribed;
    }
    let m = &v["message"];
    if ours && m["type"] == "sync" && m["scope"] == "disk" {
        return Signal::DiskChanged;
    }
    Signal::Other
}

/// Connects, subscribes to the org and calls `on_signal` for each frame until
/// the socket drops or `keep_going` says the config changed. Returns why it stopped;
/// the caller waits and calls again.
pub fn listen(
    api_base: &str,
    web_base: &str,
    org: &str,
    token: &str,
    keep_going: &dyn Fn() -> bool,
    on_signal: &mut dyn FnMut(Signal),
) -> DiskResult<()> {
    let mut req = format!("{}?token={}", cable_url(api_base), urlencode(token))
        .into_client_request()
        .map_err(|e| DiskError::Other(format!("cable url: {e}")))?;
    let h = req.headers_mut();
    h.insert("Sec-WebSocket-Protocol", HeaderValue::from_static("actioncable-v1-json"));
    // Production allows only listed origins; the web app's is one of them.
    if let Ok(o) = HeaderValue::from_str(web_base.trim_end_matches('/')) {
        h.insert("Origin", o);
    }
    let (mut ws, _) = tungstenite::connect(req).map_err(|e| DiskError::Offline(format!("cable: {e}")))?;
    set_timeout(&ws);
    let subscribe = json!({ "command": "subscribe", "identifier": identifier(org) }).to_string();
    ws.send(Message::text(subscribe)).map_err(|e| DiskError::Offline(format!("cable: {e}")))?;
    while keep_going() {
        match ws.read() {
            Ok(Message::Text(t)) => on_signal(parse(t.as_str(), org)),
            Ok(Message::Close(_)) => return Err(DiskError::Offline("cable closed".into())),
            Ok(_) => {}
            Err(e) => return Err(DiskError::Offline(format!("cable: {e}"))),
        }
    }
    let _ = ws.close(None);
    Ok(())
}

fn set_timeout(ws: &WebSocket<MaybeTlsStream<TcpStream>>) {
    let tcp = match ws.get_ref() {
        MaybeTlsStream::Plain(s) => s,
        MaybeTlsStream::Rustls(s) => s.get_ref(),
        _ => return,
    };
    let _ = tcp.set_read_timeout(Some(SILENT_FOR));
}

fn urlencode(s: &str) -> String {
    s.bytes()
        .map(|b| match b {
            b'A'..=b'Z' | b'a'..=b'z' | b'0'..=b'9' | b'-' | b'_' | b'.' | b'~' => (b as char).to_string(),
            _ => format!("%{b:02X}"),
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn cable_url_from_api_base() {
        assert_eq!(cable_url("https://api.inbox2.com/api/v1"), "wss://api.inbox2.com/cable");
        assert_eq!(cable_url("http://localhost:4000/api/v1/"), "ws://localhost:4000/cable");
    }

    #[test]
    fn only_this_orgs_disk_hints_count() {
        let id = identifier("org_a").replace('"', "\\\"");
        let disk = format!(r#"{{"identifier":"{id}","message":{{"type":"sync","scope":"disk"}}}}"#);
        let mail = format!(r#"{{"identifier":"{id}","message":{{"type":"sync","scope":"mail"}}}}"#);
        let other = disk.replace("org_a", "org_b");
        assert_eq!(parse(&disk, "org_a"), Signal::DiskChanged);
        assert_eq!(parse(&mail, "org_a"), Signal::Other);
        assert_eq!(parse(&other, "org_a"), Signal::Other);
        assert_eq!(parse(&format!(r#"{{"identifier":"{id}","type":"confirm_subscription"}}"#), "org_a"), Signal::Subscribed);
        assert_eq!(parse(r#"{"type":"ping","message":1}"#, "org_a"), Signal::Other);
        assert_eq!(parse("not json", "org_a"), Signal::Other);
    }

    /// `DISK_LIVE_DIR=<group container>/Disk cargo test -- --ignored live_subscribes`
    #[test]
    #[ignore]
    fn live_subscribes() {
        let dir = std::env::var("DISK_LIVE_DIR").expect("DISK_LIVE_DIR");
        let cfg = crate::disk::engine::read_config(std::path::Path::new(&dir)).unwrap();
        let done = std::cell::Cell::new(false);
        let mut seen = vec![];
        listen(&cfg.api_base, &cfg.web_base, &cfg.org, &cfg.token, &|| !done.get(), &mut |s| {
            if s == Signal::Subscribed { done.set(true) }
            seen.push(s);
        })
        .unwrap();
        assert!(seen.contains(&Signal::Subscribed));
    }

    #[test]
    fn tokens_are_escaped() {
        assert_eq!(urlencode("ink_a+b/c="), "ink_a%2Bb%2Fc%3D");
    }
}
