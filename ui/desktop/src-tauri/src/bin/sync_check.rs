//! sync-check — drive a full, end-to-end sync against a throwaway database using
//! the real stored credentials, then report sync-integrity.
//!
//! It reads accounts + encrypted tokens from the live desktop database, runs the
//! real Rust sync engine (headless) against a fresh temporary SQLite DB, and
//! prints folder/message/calendar counts plus integrity invariants. Because it
//! exercises the actual adapters + store against the real providers, it catches
//! regressions that the wiremock unit tests can't (provider quirks, token
//! refresh, threading/dedup at scale).
//!
//! Usage:
//!   sync-check [--source-dir <dir>] [--account <email|key>] [--api-base <url>]
//!              [--jwt <token>] [--keep-db] [--json]
//!
//!   --source-dir  Live app data dir holding inbox2.db + .credential_key
//!                 (default: ~/Library/Application Support/com.inbox2.desktop)
//!   --account     Only sync the account whose email or key matches
//!   --api-base    Rails proxy base for OAuth refresh (e.g. http://localhost:4000/api/v1)
//!   --jwt         Rails JWT for the proxy (or env INBOX2_JWT)
//!   --keep-db     Don't delete the temp DB afterwards (prints its path)
//!   --json        Emit the integrity report as JSON

use std::path::PathBuf;
use std::sync::Arc;
use std::time::Instant;

use app_lib::sync::engine::SyncEngine;
use app_lib::sync::model::{ExternalAccount, IntegrityReport};
use app_lib::sync::store::SyncStore;

struct Args {
    source_dir: PathBuf,
    account: Option<String>,
    api_base: Option<String>,
    jwt: Option<String>,
    keep_db: bool,
    json: bool,
}

fn parse_args() -> Args {
    let default_source = app_lib::default_data_dir();
    let mut a = Args {
        source_dir: default_source,
        account: None,
        api_base: None,
        jwt: std::env::var("INBOX2_JWT").ok(),
        keep_db: false,
        json: false,
    };
    let mut it = std::env::args().skip(1);
    while let Some(arg) = it.next() {
        match arg.as_str() {
            "--source-dir" => a.source_dir = PathBuf::from(it.next().unwrap_or_default()),
            "--account" => a.account = it.next(),
            "--api-base" => a.api_base = it.next(),
            "--jwt" => a.jwt = it.next(),
            "--keep-db" => a.keep_db = true,
            "--json" => a.json = true,
            "-h" | "--help" => {
                eprintln!("{}", USAGE);
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

const USAGE: &str = "sync-check [--source-dir <dir>] [--account <email|key>] \
[--api-base <url>] [--jwt <token>] [--keep-db] [--json]";

#[tokio::main]
async fn main() {
    let args = parse_args();

    // ── Open the live store (to read accounts + decrypt credentials) ────────
    let source_db = args.source_dir.join("inbox2.db");
    if !source_db.exists() {
        eprintln!(
            "No database at {} — is --source-dir correct?",
            source_db.display()
        );
        std::process::exit(2);
    }
    let source = match SyncStore::new(&source_db, &args.source_dir) {
        Ok(s) => s,
        Err(e) => {
            eprintln!("Failed to open source store: {e}");
            std::process::exit(2);
        }
    };

    let accounts = source.list_accounts().unwrap_or_default();
    let selected: Vec<ExternalAccount> = accounts
        .into_iter()
        .filter(|a| match &args.account {
            Some(f) => a.email_address == *f || a.key == *f,
            None => true,
        })
        .collect();

    if selected.is_empty() {
        eprintln!("No matching accounts in {}", source_db.display());
        std::process::exit(2);
    }

    // ── Fresh temp store + headless engine ──────────────────────────────────
    let stamp = Instant::now().elapsed().as_nanos();
    let temp_dir = std::env::temp_dir().join(format!("inbox2-synccheck-{}", std::process::id()));
    let _ = std::fs::create_dir_all(&temp_dir);
    let temp_db = temp_dir.join("inbox2.db");
    let _ = stamp;

    let temp_store = match SyncStore::new(&temp_db, &temp_dir) {
        Ok(s) => Arc::new(s),
        Err(e) => {
            eprintln!("Failed to create temp store: {e}");
            std::process::exit(2);
        }
    };
    // headless: drop events
    let engine = SyncEngine::new(
        temp_store.clone(),
        Arc::new(app_lib::sync::events::NullSink),
    );
    if let Some(base) = &args.api_base {
        engine
            .set_api_context(base.clone(), args.jwt.clone().unwrap_or_default())
            .await;
    }

    println!("sync-check — full sync into {}", temp_db.display());
    println!("source: {}", source_db.display());
    println!("accounts: {}", selected.len());
    if args.api_base.is_none() {
        println!(
            "note: no --api-base given — expired OAuth tokens can't be refreshed.\n      \
             Pass e.g. --api-base http://localhost:4000/api/v1 --jwt <token> to refresh."
        );
    }
    println!();

    // ── Run a full connect+sync for each account ────────────────────────────
    let mut had_error = false;
    for acct in &selected {
        let creds = match source.get_credentials(&acct.key) {
            Ok(Some(c)) => c,
            Ok(None) => {
                println!("• {} [{}] — SKIP: no stored credentials", acct.email_address, acct.provider_type.as_str());
                continue;
            }
            Err(e) => {
                println!("• {} — SKIP: credential decrypt failed ({e}); wrong --source-dir?", acct.email_address);
                continue;
            }
        };

        // Recreate the account (and its creds) in the temp store, then sync.
        let temp_key = match temp_store.create_account(acct) {
            Ok(k) => k,
            Err(e) => {
                println!("• {} — ERROR creating temp account: {e}", acct.email_address);
                had_error = true;
                continue;
            }
        };
        let _ = temp_store.store_credentials(&temp_key, &creds);

        let host = acct.host.clone().unwrap_or_default();
        let port = acct.port.unwrap_or(993);
        let started = Instant::now();
        print!("• {} [{}] … ", acct.email_address, acct.provider_type.as_str());

        if let Err(e) = engine
            .add_account(&temp_key, &acct.provider_type, &host, port, acct.use_tls, creds)
            .await
        {
            println!("ERROR add_account: {e}");
            had_error = true;
            continue;
        }
        match engine.connect_and_sync(&temp_key).await {
            Ok(()) => {
                let folders = temp_store.get_folders_for_account(&temp_key).unwrap_or_default();
                let cals = temp_store.get_calendars_for_account(&temp_key).unwrap_or_default();
                println!(
                    "OK in {:.1}s — {} folders, {} calendars",
                    started.elapsed().as_secs_f64(),
                    folders.len(),
                    cals.len()
                );
            }
            Err(e) => {
                println!("ERROR sync: {e}");
                had_error = true;
            }
        }
    }

    // ── Integrity report ────────────────────────────────────────────────────
    let report = temp_store.integrity_report().unwrap_or_default();
    println!();
    if args.json {
        println!("{}", serde_json::to_string_pretty(&report).unwrap_or_default());
    } else {
        print_report(&report);
    }

    let violations = report.violations();
    if !violations.is_empty() {
        eprintln!("\n✗ INTEGRITY FAILED:");
        for v in &violations {
            eprintln!("  - {v}");
        }
    } else if had_error {
        // Don't claim a clean bill of health when no account actually synced.
        eprintln!("\n✗ sync errors occurred (see above) — integrity check is inconclusive");
    } else {
        println!("\n✓ integrity OK — no violations");
    }

    // ── Cleanup ──────────────────────────────────────────────────────────────
    if args.keep_db {
        println!("\n(temp DB kept at {})", temp_db.display());
    } else {
        let _ = std::fs::remove_dir_all(&temp_dir);
    }

    if had_error || !violations.is_empty() {
        std::process::exit(1);
    }
}

fn print_report(r: &IntegrityReport) {
    println!("── totals ───────────────────────────────");
    println!("  accounts              {}", r.accounts);
    println!("  folders               {}  ({} sync-enabled, {} with cursor)", r.folders, r.sync_enabled_folders, r.folders_with_cursor);
    println!("  conversations         {}", r.conversations);
    println!("  messages              {}", r.messages);
    println!("  provider states       {}", r.provider_states);
    println!("  calendars             {}", r.calendars);
    println!("  calendar events       {}", r.calendar_events);
    println!("── integrity (want 0) ───────────────────");
    println!("  orphan provider rows  {}", r.orphan_provider_states);
    println!("  msgs w/o conversation {}", r.messages_missing_conversation);
    println!("  msgs w/o provider st. {}", r.messages_without_provider_state);
    println!("  duplicate Message-IDs {}", r.duplicate_message_ids);
    println!("  events w/o calendar   {}", r.events_missing_calendar);
}
