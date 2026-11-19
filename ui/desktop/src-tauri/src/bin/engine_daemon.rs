//! engine_daemon — headless host for the shared engine bus.
//!
//! Runs the real Rust sync engine against the desktop app's live SQLite DB +
//! credential key, and serves the engine bus (events + RPC) over a Unix socket so
//! the Python TUI (and any other client) can attach. Exactly one engine runs at a
//! time: if a host already exists (the desktop app, or another daemon), this
//! process attaches-then-exits and the caller talks to the existing host instead.
//!
//! Usage:
//!   engine_daemon [--source-dir <dir>] [--api-base <url>] [--jwt <token>] [--create-store]
//!
//!   --source-dir  Live app data dir holding inbox2.db + .credential_key + engine.sock
//!                 (default: ~/Library/Application Support/com.inbox2.desktop)
//!   --api-base    Rails proxy base for OAuth refresh (e.g. http://localhost:4000/api/v1)
//!   --jwt         Rails JWT for the proxy (or env INBOX2_JWT)

// The bus is Unix-domain sockets; off Unix this binary is a stub (Cargo builds
// every bin for every target, so it has to compile).
#[cfg(not(unix))]
fn main() {
    eprintln!("engine_daemon needs Unix-domain sockets");
    std::process::exit(1);
}

#[cfg(unix)]
fn main() {
    daemon::main();
}

#[cfg(unix)]
mod daemon {
use std::path::PathBuf;
use std::sync::Arc;

use tokio::runtime::Handle;
use tokio::sync::Mutex;

use app_lib::ai::inference::AIInferenceEngine;
use app_lib::sync::engine::SyncEngine;
use app_lib::sync::ipc::{self, BroadcastSink, BusRole};
use app_lib::sync::rpc::EngineRpc;
use app_lib::sync::store::SyncStore;

struct Args {
    source_dir: PathBuf,
    api_base: Option<String>,
    jwt: Option<String>,
    /// First sign-in on a machine with no store yet (`inbox2 login`).
    create_store: bool,
}

fn parse_args() -> Args {
    let default_source = app_lib::default_data_dir();
    let mut a = Args {
        source_dir: default_source,
        api_base: None,
        jwt: std::env::var("INBOX2_JWT").ok(),
        create_store: false,
    };
    let mut it = std::env::args().skip(1);
    while let Some(arg) = it.next() {
        match arg.as_str() {
            "--source-dir" => a.source_dir = PathBuf::from(it.next().unwrap_or_default()),
            "--api-base" => a.api_base = it.next(),
            "--jwt" => a.jwt = it.next(),
            "--create-store" => a.create_store = true,
            "-h" | "--help" => {
                eprintln!("{USAGE}");
                std::process::exit(0);
            }
            other => {
                eprintln!("unknown argument: {other}\n{USAGE}");
                std::process::exit(2);
            }
        }
    }
    a
}

const USAGE: &str = "engine_daemon [--source-dir <dir>] [--api-base <url>] [--jwt <token>] [--create-store]";

#[tokio::main]
pub async fn main() {
    env_logger_init();
    let args = parse_args();

    let db_path = args.source_dir.join("inbox2.db");
    if !db_path.exists() && !args.create_store {
        eprintln!(
            "No database at {} — connect an account in the desktop app first, or pass --source-dir.",
            db_path.display()
        );
        std::process::exit(2);
    }

    // Election decides whether we host the engine or defer to an existing host.
    let (listener, registry, sock_path) = match ipc::start_or_attach(&args.source_dir) {
        Ok(BusRole::Host { listener, registry, sock_path }) => (listener, registry, sock_path),
        Ok(BusRole::Client { sock_path }) => {
            // Some other process (likely the desktop app) is already the host.
            // Print the socket so the CLI knows where to attach, and exit cleanly.
            println!("ATTACH {}", sock_path.display());
            eprintln!("engine_daemon: an engine is already running; attaching to {}", sock_path.display());
            return;
        }
        Err(e) => {
            eprintln!("engine_daemon: failed to bind engine socket: {e}");
            std::process::exit(2);
        }
    };

    let store = match SyncStore::new(&db_path, &args.source_dir) {
        Ok(s) => Arc::new(s),
        Err(e) => {
            eprintln!("engine_daemon: failed to open store: {e}");
            std::process::exit(2);
        }
    };

    let sink = Arc::new(BroadcastSink(registry.clone()));
    let engine = Arc::new(SyncEngine::new(store, sink));
    // Direct (proxy-free) token refresh when OAuth client credentials are in
    // the env or were baked in at build.
    engine.load_oauth_clients_from_env();

    if let Some(base) = &args.api_base {
        match &args.jwt {
            Some(jwt) => engine.set_api_context(base.clone(), jwt.clone()).await,
            // An empty token would sign the stored session out.
            None => engine.override_api_base(base.clone()).await,
        }
    }

    // Long-running sync loop (polling + write-back + event broadcast).
    {
        let run_engine = engine.clone();
        tokio::spawn(async move {
            if let Err(e) = run_engine.run().await {
                log::error!("engine loop exited: {e}");
            }
        });
    }

    // Boot stored accounts: connect + initial/incremental sync.
    {
        let boot_engine = engine.clone();
        tokio::spawn(async move { boot_engine.boot_all_accounts().await });
    }

    // Agentic filters — scan local-channel mail and trigger local CLI agents.
    // Hosted here too so rule triggering works headless, not only in the GUI.
    // Warm the on-device AI engine for Tier-1 gates if the models are present
    // (the user set up On-device AI in the app); otherwise run Tier-0 rules only.
    {
        let ai_engine = {
            let mut e = AIInferenceEngine::new(&args.source_dir);
            match e.warmup() {
                Ok(()) => Some(Arc::new(Mutex::new(e))),
                Err(err) => {
                    log::info!(
                        "on-device AI unavailable ({err}); Tier-1 gated rules will be skipped"
                    );
                    None
                }
            }
        };
        // Semantic search over the bus (vector::commands::HOSTED) + keeping the
        // embeddings current, on the same warmed engine — as setup.rs does.
        if let Some(ai) = &ai_engine {
            let conn = engine.store().connection();
            let vstore = Arc::new(app_lib::vector::store::VectorStore::new(conn.clone()));
            let _ = app_lib::vector::commands::HOSTED.set(app_lib::vector::commands::VectorState {
                store: vstore.clone(),
                engine: ai.clone(),
                db_conn: conn,
            });
            let pipeline = Arc::new(app_lib::vector::pipeline::EmbeddingPipeline::new(vstore, ai.clone(), 50));
            tokio::spawn(async move { pipeline.run().await });
        }
        let (_store, runner) =
            app_lib::local_agents::build_runner(engine.clone(), &args.source_dir, ai_engine);
        tokio::spawn(async move { runner.run().await });
    }

    // The background AI the desktop host runs too (setup.rs), so CLI-only use
    // still gets Jev triage, summaries, the Lore ontology and WhatsApp Lore:
    // the saved Jev key, and the user's OpenAI key as the summary lane.
    {
        let secret = |name: &str| {
            engine
                .store()
                .get_app_secret(&format!("{}{name}", app_lib::sync::commands::SECRET_KV_PREFIX))
                .ok()
                .flatten()
                .filter(|v| !v.trim().is_empty())
        };
        if let Some(key) = secret("typesafe_api_key") {
            engine.set_jev_key(Some(key));
        }
        // Only when the user's lane allows it: with on-device AI chosen, mail never
        // goes to OpenAI here — the daemon has no on-device model, so triage runs
        // rules + Jev without summaries until the desktop app hosts.
        if let Some(key) = secret("openai_api_key").filter(|_| app_lib::sync::commands::openai_allowed(engine.store())) {
            engine.set_ai_config(inbox2_core::bridge::agent::BridgeConfig {
                generation: inbox2_core::bridge::agent::GenSource::OpenAi,
                openai_key: Some(key),
                model: inbox2_core::bridge::prompts::openai_chat_model(),
                on_device_model: None,
                concise: false,
                weather: None,
            });
        }
        let e1 = engine.clone();
        tokio::spawn(async move { inbox2_core::ai_worker::TriageWorker::new(e1).run().await });
        let e2 = engine.clone();
        tokio::spawn(async move { inbox2_core::ontology::run(e2).await });
        app_lib::whatsapp_lore::arm();
        let e3 = engine.clone();
        tokio::spawn(async move { app_lib::whatsapp_lore::run(e3).await });
    }

    let dispatcher = EngineRpc::new(engine.clone(), Handle::current());
    println!("HOST {}", sock_path.display());
    eprintln!("engine_daemon: host listening on {}", sock_path.display());

    // Serve the accept loop on the blocking pool so the runtime keeps driving the
    // engine's async tasks. RPC handlers run on these blocking threads and
    // `Handle::block_on` into the engine — safe, since they aren't runtime workers.
    let _ = tokio::task::spawn_blocking(move || ipc::serve(listener, registry, dispatcher)).await;

    // If we ever fall through, tidy up the socket file.
    let _ = std::fs::remove_file(&sock_path);
}

fn env_logger_init() {
    // Lightweight: honor RUST_LOG-ish via a simple stderr logger if available.
    // The crate doesn't depend on env_logger, so just use tauri-plugin-log's
    // underlying `log` with a default level via a tiny logger.
    use log::LevelFilter;
    let _ = log::set_logger(&STDERR_LOGGER);
    log::set_max_level(
        std::env::var("INBOX2_LOG")
            .ok()
            .and_then(|v| v.parse::<LevelFilter>().ok())
            .unwrap_or(LevelFilter::Info),
    );
}

struct StderrLogger;
static STDERR_LOGGER: StderrLogger = StderrLogger;
impl log::Log for StderrLogger {
    fn enabled(&self, meta: &log::Metadata) -> bool {
        // html5ever (via ammonia's HTML sanitizing) spams unactionable
        // "foster parenting not implemented" WARNs on tables/malformed markup.
        !meta.target().starts_with("html5ever")
    }
    fn log(&self, record: &log::Record) {
        // `log` gates on max_level before calling us, but not on `enabled`.
        if !self.enabled(record.metadata()) {
            return;
        }
        eprintln!("[{}] {}", record.level(), record.args());
    }
    fn flush(&self) {}
}
}
