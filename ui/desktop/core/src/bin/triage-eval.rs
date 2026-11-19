//! `triage-eval` — score triage fixtures through the production classification
//! path from the command line.
//!
//! ```sh
//! # Rules only (ambiguous cases report "no Jev key"):
//! cargo run --bin triage-eval -- fixtures/triage-eval.json
//!
//! # Jev lane (key from --jev-key or $TYPESAFE_API_KEY):
//! cargo run --bin triage-eval -- fixtures/triage-eval.json --jev-key ts-…
//! ```
//!
//! Labels are the eight built-ins. `--json` dumps the full `EvalReport` for
//! diffing runs. Exits non-zero when any scored case fails or errors, so it can
//! gate CI.

use std::process::ExitCode;

use inbox2_core::triage_eval::{self, JevLane};
use inbox2_core::{triage, typesafe};

const USAGE: &str = "usage: triage-eval <fixtures.json> [--jev-key KEY] [--json]";

#[tokio::main(flavor = "current_thread")]
async fn main() -> ExitCode {
    let mut fixtures = None;
    let mut key = std::env::var("TYPESAFE_API_KEY").ok().filter(|k| !k.is_empty());
    let mut json = false;
    let mut args = std::env::args().skip(1);
    while let Some(a) = args.next() {
        match a.as_str() {
            "--jev-key" => key = args.next(),
            "--json" => json = true,
            _ if fixtures.is_none() && !a.starts_with('-') => fixtures = Some(a),
            _ => {
                eprintln!("{USAGE}");
                return ExitCode::from(2);
            }
        }
    }
    let Some(path) = fixtures else {
        eprintln!("{USAGE}");
        return ExitCode::from(2);
    };
    let cases = match std::fs::read_to_string(&path).map_err(|e| format!("cannot read {path}: {e}")).and_then(|t| triage_eval::parse_cases(&t)) {
        Ok(c) => c,
        Err(e) => {
            eprintln!("{e}");
            return ExitCode::from(2);
        }
    };

    let lane = key.as_deref().map(|key| JevLane { endpoint: typesafe::ENDPOINT, key });
    let lane_name = if lane.is_some() { format!("jev ({})", typesafe::MODEL) } else { "rules only (no Jev key)".into() };
    eprintln!("triage-eval: {} cases, lane: {lane_name}", cases.len());

    let report = triage_eval::run(cases, lane, &triage::builtin_labels()).await;

    if json {
        println!("{}", serde_json::to_string_pretty(&report).expect("report serializes"));
    } else {
        for r in &report.results {
            let mark = match r.pass {
                Some(true) => "PASS",
                Some(false) => "FAIL",
                None if r.error.is_some() => "ERR ",
                None => "  — ",
            };
            let priority = r.priority.map(|p| format!("p={p:.2}")).unwrap_or_default();
            println!(
                "{mark}  {:<28} expected {:<18} got {:<18} {priority:<7} [{}] {}",
                r.name,
                r.expected.as_deref().unwrap_or("-"),
                r.predicted.as_deref().unwrap_or("-"),
                r.source,
                r.signals
            );
            if let Some(e) = &r.error {
                println!("      ! {e}");
            }
        }
        println!(
            "\n{}/{} correct ({} by rules, {} by Jev, {} errors)",
            report.correct, report.scored, report.by_rules, report.by_model, report.errors
        );
    }

    let failed = report.results.iter().any(|r| r.pass == Some(false)) || report.errors > 0;
    if failed {
        ExitCode::from(1)
    } else {
        ExitCode::SUCCESS
    }
}
