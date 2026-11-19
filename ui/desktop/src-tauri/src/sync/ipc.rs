//! Cross-process engine bus over a Unix-domain socket.
//!
//! The sync engine runs in exactly **one** process (the *host*). Whoever starts
//! first wins; everyone else *attaches* as a *client*. Election is the socket
//! file itself — the classic single-instance trick, so no lockfile/flock dep:
//!
//!   1. `connect(engine.sock)` succeeds  → a live host exists → become a Client.
//!   2. connect fails (refused/missing)  → unlink any stale socket, then `bind`.
//!      `bind` wins → become the Host; `bind` loses a race → retry connect.
//!
//! Wire protocol — one JSON object per line (`\n`-delimited), both directions:
//!   • event   (host→client): `{"type":"event","event":"sync","payload":{…}}`
//!   • rpc     (client→host): `{"type":"rpc","id":N,"method":"…","params":{…}}`
//!   • result  (host→client): `{"type":"rpc_result","id":N,"ok":true,"result":…}`
//!                            or `{… ,"ok":false,"error":"…"}`
//!
//! The server is blocking + thread-per-connection (mirrors the OAuth listener and
//! the tiny_http MCP server already in this crate), so it needs no extra tokio
//! features. RPC handlers run on plain std threads, so they can `Handle::block_on`
//! into the engine's async methods without nesting inside a runtime worker.

use std::path::{Path, PathBuf};

/// Socket filename inside the app data dir.
pub const SOCKET_NAME: &str = "engine.sock";

/// Resolve the engine socket path for a given data dir.
pub fn socket_path(data_dir: &Path) -> PathBuf {
    data_dir.join(SOCKET_NAME)
}

// ───────────────────────────── RPC dispatch ─────────────────────────────────

/// Handles an RPC method on the host side. Implemented by `rpc::EngineRpc`.
pub trait RpcDispatch: Send + Sync {
    fn call(&self, method: &str, params: serde_json::Value) -> Result<serde_json::Value, String>;
}

// No engine bus off Unix — std has no Unix-domain sockets there. The desktop
// app then runs its engine in-process (setup::init_engine's "bus unavailable"
// path) and the CLI's daemon is not built. `BusClient` exists only so
// `Option<Arc<BusClient>>` is a type everywhere; it is never constructed.
#[cfg(not(unix))]
pub enum BusRole {}
#[cfg(not(unix))]
pub struct BusClient(std::convert::Infallible);
#[cfg(not(unix))]
impl BusClient {
    pub fn call(&self, _method: &str, _params: serde_json::Value) -> Result<serde_json::Value, String> {
        match self.0 {}
    }
}
#[cfg(not(unix))]
pub fn start_or_attach(_data_dir: &Path) -> std::io::Result<BusRole> {
    Err(std::io::Error::new(std::io::ErrorKind::Unsupported, "engine bus needs Unix-domain sockets"))
}

#[cfg(unix)]
pub use bus::*;

#[cfg(unix)]
mod bus {
use super::*;
use std::collections::HashMap;
use std::io::{BufRead, BufReader, Write};
use std::os::unix::net::{UnixListener, UnixStream};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex};

use crate::sync::events::EventSink;

// ─────────────────────────── connected clients ──────────────────────────────

/// One connected client's writable half, behind a mutex so the broadcast path
/// and that client's RPC-reply path don't interleave bytes on the stream.
struct ClientConn {
    id: u64,
    stream: Arc<Mutex<UnixStream>>,
}

/// The set of currently connected clients. Shared between the accept loop (adds
/// clients), each reader thread (removes on disconnect), and the broadcast sink.
#[derive(Default)]
pub struct ClientRegistry {
    clients: Mutex<Vec<ClientConn>>,
    next_id: AtomicU64,
}

impl ClientRegistry {
    pub fn new() -> Arc<Self> {
        Arc::new(Self::default())
    }

    fn add(&self, stream: Arc<Mutex<UnixStream>>) -> u64 {
        let id = self.next_id.fetch_add(1, Ordering::Relaxed);
        self.clients.lock().unwrap_or_else(|e| e.into_inner()).push(ClientConn { id, stream });
        id
    }

    fn remove(&self, id: u64) {
        self.clients.lock().unwrap_or_else(|e| e.into_inner()).retain(|c| c.id != id);
    }

    /// Write a line to every client; drop any that error.
    fn broadcast(&self, line: &str) {
        // Poison-tolerant like the sibling add/remove/write_line paths: a panic
        // in another client thread must not wedge all future event broadcasts.
        let mut clients = self.clients.lock().unwrap_or_else(|e| e.into_inner());
        clients.retain(|c| write_line(&c.stream, line).is_ok());
    }
}

/// An [`EventSink`] that fans engine events out to all connected socket clients.
pub struct BroadcastSink(pub Arc<ClientRegistry>);

impl EventSink for BroadcastSink {
    fn emit(&self, event: &str, payload: serde_json::Value) {
        let msg = serde_json::json!({ "type": "event", "event": event, "payload": payload });
        if let Ok(line) = serde_json::to_string(&msg) {
            self.0.broadcast(&line);
        }
    }
}

fn write_line(stream: &Mutex<UnixStream>, line: &str) -> std::io::Result<()> {
    let mut s = stream.lock().unwrap_or_else(|e| e.into_inner());
    s.write_all(line.as_bytes())?;
    s.write_all(b"\n")?;
    s.flush()
}

// ──────────────────────────────── election ──────────────────────────────────

/// Result of [`start_or_attach`]: this process is either the host (owns the
/// listener + client registry) or a client (knows where to connect).
pub enum BusRole {
    Host {
        listener: UnixListener,
        registry: Arc<ClientRegistry>,
        sock_path: PathBuf,
    },
    Client {
        sock_path: PathBuf,
    },
}

/// Elect this process as host or client for `data_dir`'s engine socket.
pub fn start_or_attach(data_dir: &Path) -> std::io::Result<BusRole> {
    let sock_path = socket_path(data_dir);

    // 1. A live host already listening?
    if UnixStream::connect(&sock_path).is_ok() {
        return Ok(BusRole::Client { sock_path });
    }

    // 2. No live host. Clear any stale socket file and try to become the host.
    let _ = std::fs::remove_file(&sock_path);
    match UnixListener::bind(&sock_path) {
        Ok(listener) => {
            // Restrict the socket to the owner — it accepts unauthenticated RPCs
            // including get_secret/get_rails_token, so a co-resident process must
            // not be able to connect to it.
            #[cfg(unix)]
            {
                use std::os::unix::fs::PermissionsExt;
                let _ = std::fs::set_permissions(
                    &sock_path,
                    std::fs::Permissions::from_mode(0o600),
                );
            }
            Ok(BusRole::Host {
                listener,
                registry: ClientRegistry::new(),
                sock_path,
            })
        }
        Err(_) => {
            // Lost a race — someone bound between our connect and our bind.
            // They're the host; attach to them.
            UnixStream::connect(&sock_path)?;
            Ok(BusRole::Client { sock_path })
        }
    }
}

// ──────────────────────────────── server ────────────────────────────────────

/// Run the host accept loop (blocking). For each connection, register the client
/// for broadcasts and spawn a reader thread that answers its RPC requests.
///
/// Call this on a dedicated thread (the daemon blocks the main thread on it; the
/// desktop app spawns it).
pub fn serve(
    listener: UnixListener,
    registry: Arc<ClientRegistry>,
    dispatcher: Arc<dyn RpcDispatch>,
) {
    for incoming in listener.incoming() {
        let stream = match incoming {
            Ok(s) => s,
            Err(e) => {
                log::warn!("engine bus: accept failed: {e}");
                continue;
            }
        };
        let read_half = match stream.try_clone() {
            Ok(s) => s,
            Err(e) => {
                log::warn!("engine bus: clone failed: {e}");
                continue;
            }
        };
        let write_half = Arc::new(Mutex::new(stream));
        let id = registry.add(write_half.clone());
        let registry = registry.clone();
        let dispatcher = dispatcher.clone();

        std::thread::spawn(move || {
            handle_client(read_half, write_half, &dispatcher);
            registry.remove(id);
        });
    }
}

fn handle_client(
    read_half: UnixStream,
    write_half: Arc<Mutex<UnixStream>>,
    dispatcher: &Arc<dyn RpcDispatch>,
) {
    let reader = BufReader::new(read_half);
    for line in reader.lines() {
        let line = match line {
            Ok(l) => l,
            Err(_) => break, // client gone
        };
        if line.trim().is_empty() {
            continue;
        }
        let msg: serde_json::Value = match serde_json::from_str(&line) {
            Ok(v) => v,
            Err(e) => {
                log::warn!("engine bus: bad request: {e}");
                continue;
            }
        };
        if msg.get("type").and_then(|t| t.as_str()) != Some("rpc") {
            continue;
        }
        let id = msg.get("id").cloned().unwrap_or(serde_json::Value::Null);
        let method = msg.get("method").and_then(|m| m.as_str()).unwrap_or("");
        let params = msg.get("params").cloned().unwrap_or(serde_json::Value::Null);

        let reply = match dispatcher.call(method, params) {
            Ok(result) => serde_json::json!({
                "type": "rpc_result", "id": id, "ok": true, "result": result,
            }),
            Err(error) => serde_json::json!({
                "type": "rpc_result", "id": id, "ok": false, "error": error,
            }),
        };
        if let Ok(line) = serde_json::to_string(&reply) {
            if write_line(&write_half, &line).is_err() {
                break;
            }
        }
    }
}

// ──────────────────────────────── client ────────────────────────────────────

type Pending = Arc<Mutex<HashMap<u64, std::sync::mpsc::Sender<Result<serde_json::Value, String>>>>>;

/// A connected client of the engine bus. Used by the desktop app when it loses
/// the election (the Python TUI has its own asyncio client). Receives events via
/// the `on_event` callback and issues blocking RPC calls via [`BusClient::call`].
pub struct BusClient {
    write: Arc<Mutex<UnixStream>>,
    pending: Pending,
    next_id: AtomicU64,
}

impl BusClient {
    /// Connect to the host at `sock_path`; `on_event(event, payload)` fires for
    /// every broadcast on a background reader thread.
    pub fn connect<F>(sock_path: &Path, on_event: F) -> std::io::Result<Arc<Self>>
    where
        F: Fn(String, serde_json::Value) + Send + 'static,
    {
        let stream = UnixStream::connect(sock_path)?;
        let read_half = stream.try_clone()?;
        let client = Arc::new(Self {
            write: Arc::new(Mutex::new(stream)),
            pending: Arc::new(Mutex::new(HashMap::new())),
            next_id: AtomicU64::new(1),
        });

        let pending = client.pending.clone();
        std::thread::spawn(move || {
            let reader = BufReader::new(read_half);
            for line in reader.lines() {
                let line = match line {
                    Ok(l) => l,
                    Err(_) => break,
                };
                let msg: serde_json::Value = match serde_json::from_str(&line) {
                    Ok(v) => v,
                    Err(_) => continue,
                };
                match msg.get("type").and_then(|t| t.as_str()) {
                    Some("event") => {
                        let event = msg.get("event").and_then(|e| e.as_str()).unwrap_or("").to_string();
                        let payload = msg.get("payload").cloned().unwrap_or(serde_json::Value::Null);
                        on_event(event, payload);
                    }
                    Some("rpc_result") => {
                        let id = msg.get("id").and_then(|i| i.as_u64()).unwrap_or(0);
                        let result = if msg.get("ok").and_then(|o| o.as_bool()).unwrap_or(false) {
                            Ok(msg.get("result").cloned().unwrap_or(serde_json::Value::Null))
                        } else {
                            Err(msg.get("error").and_then(|e| e.as_str()).unwrap_or("rpc error").to_string())
                        };
                        if let Some(tx) = pending.lock().unwrap_or_else(|e| e.into_inner()).remove(&id) {
                            let _ = tx.send(result);
                        }
                    }
                    _ => {}
                }
            }
        });

        Ok(client)
    }

    /// Issue an RPC call and block (up to 60s) for the result.
    pub fn call(&self, method: &str, params: serde_json::Value) -> Result<serde_json::Value, String> {
        let id = self.next_id.fetch_add(1, Ordering::Relaxed);
        let (tx, rx) = std::sync::mpsc::channel();
        self.pending.lock().unwrap_or_else(|e| e.into_inner()).insert(id, tx);

        let req = serde_json::json!({ "type": "rpc", "id": id, "method": method, "params": params });
        let line = serde_json::to_string(&req).map_err(|e| e.to_string())?;
        write_line(&self.write, &line).map_err(|e| e.to_string())?;

        match rx.recv_timeout(std::time::Duration::from_secs(60)) {
            Ok(result) => result,
            Err(_) => {
                self.pending.lock().unwrap_or_else(|e| e.into_inner()).remove(&id);
                Err("rpc timed out".to_string())
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    struct EchoDispatch;
    impl RpcDispatch for EchoDispatch {
        fn call(&self, method: &str, params: serde_json::Value) -> Result<serde_json::Value, String> {
            if method == "boom" {
                return Err("kaboom".into());
            }
            Ok(serde_json::json!({ "method": method, "params": params }))
        }
    }

    #[test]
    fn election_picks_one_host_then_client() {
        let dir = tempfile::tempdir().unwrap();
        let role1 = start_or_attach(dir.path()).unwrap();
        assert!(matches!(role1, BusRole::Host { .. }), "first is host");

        // Spin up the host's accept loop so the second election can connect.
        if let BusRole::Host { listener, registry, .. } = role1 {
            let dispatcher: Arc<dyn RpcDispatch> = Arc::new(EchoDispatch);
            std::thread::spawn(move || serve(listener, registry, dispatcher));
        }
        // Give the listener a moment.
        std::thread::sleep(std::time::Duration::from_millis(50));

        let role2 = start_or_attach(dir.path()).unwrap();
        assert!(matches!(role2, BusRole::Client { .. }), "second is client");
    }

    #[test]
    fn rpc_roundtrip_and_broadcast() {
        let dir = tempfile::tempdir().unwrap();
        let (listener, registry, _sock) = match start_or_attach(dir.path()).unwrap() {
            BusRole::Host { listener, registry, sock_path } => (listener, registry, sock_path),
            _ => panic!("expected host"),
        };
        let reg_for_serve = registry.clone();
        let dispatcher: Arc<dyn RpcDispatch> = Arc::new(EchoDispatch);
        std::thread::spawn(move || serve(listener, reg_for_serve, dispatcher));
        std::thread::sleep(std::time::Duration::from_millis(50));

        let got_events = Arc::new(Mutex::new(Vec::<(String, serde_json::Value)>::new()));
        let sink = got_events.clone();
        let sock = socket_path(dir.path());
        let client = BusClient::connect(&sock, move |ev, payload| {
            sink.lock().unwrap().push((ev, payload));
        })
        .unwrap();
        std::thread::sleep(std::time::Duration::from_millis(50));

        // RPC success
        let ok = client.call("hello", serde_json::json!({ "x": 1 })).unwrap();
        assert_eq!(ok["method"], "hello");
        assert_eq!(ok["params"]["x"], 1);

        // RPC error
        let err = client.call("boom", serde_json::Value::Null).unwrap_err();
        assert_eq!(err, "kaboom");

        // Broadcast reaches the client.
        BroadcastSink(registry.clone()).emit("sync", serde_json::json!({ "accountKey": "a" }));
        std::thread::sleep(std::time::Duration::from_millis(50));
        let events = got_events.lock().unwrap();
        assert_eq!(events.len(), 1);
        assert_eq!(events[0].0, "sync");
        assert_eq!(events[0].1["accountKey"], "a");
    }
}
}
