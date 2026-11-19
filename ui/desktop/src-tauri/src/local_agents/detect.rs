// Detection — probe PATH for each shipped agent and read its version. See
// docs/Agentic-Filters.md §5.2 (the settings "Local agents" card).

use std::collections::HashSet;
use std::ffi::{OsStr, OsString};
use std::path::PathBuf;
use std::process::Command;
use std::time::Duration;

use super::adapter::DetectedAgent;
use super::adapters::all_adapters;
use super::runner::run_with_timeout;

/// A version probe is a `--version` print — it should return in well under a
/// second. Kill it past this so a CLI that stalls (first-run setup, a prompt it
/// reads from stdin) can never freeze detection.
const VERSION_TIMEOUT: Duration = Duration::from_secs(4);

/// The process PATH plus the per-user/toolchain bin dirs a desktop app launched
/// from Finder/Dock would otherwise miss: a GUI process inherits a slim PATH
/// (`/usr/bin:/bin:/usr/sbin:/sbin`) that excludes Homebrew, npm-global, bun, etc.
/// — exactly where these CLIs live. Existing PATH entries win; extras are appended
/// and the whole thing de-duped (first occurrence kept).
///
/// Used both to *detect* agents and (via the runner) as the `PATH` an agent
/// process is spawned with, so an agent we can find is also one we can run.
pub fn search_path() -> OsString {
    let mut dirs: Vec<PathBuf> = Vec::new();
    if let Some(path) = std::env::var_os("PATH") {
        dirs.extend(std::env::split_paths(&path));
    }
    dirs.extend(extra_bin_dirs());
    let mut seen = HashSet::new();
    dirs.retain(|d| seen.insert(d.clone()));
    std::env::join_paths(dirs).unwrap_or_else(|_| std::env::var_os("PATH").unwrap_or_default())
}

/// Common bin dirs absent from a slim GUI PATH. Unix-only: on Windows a GUI app
/// already inherits the full machine/user PATH.
#[cfg(unix)]
fn extra_bin_dirs() -> Vec<PathBuf> {
    let mut v: Vec<PathBuf> = ["/opt/homebrew/bin", "/usr/local/bin", "/opt/local/bin"]
        .iter()
        .map(PathBuf::from)
        .collect();
    if let Some(home) = std::env::var_os("HOME").map(PathBuf::from) {
        for rel in [
            ".local/bin",
            ".npm-global/bin",
            ".bun/bin",
            ".deno/bin",
            ".volta/bin",
            ".cargo/bin",
            "bin",
        ] {
            v.push(home.join(rel));
        }
    }
    v
}

#[cfg(not(unix))]
fn extra_bin_dirs() -> Vec<PathBuf> {
    Vec::new()
}

/// Resolve an executable against an explicit PATH value (testable without mutating
/// the process environment). Honors PATHEXT on Windows.
pub fn which_in(binary: &str, path: Option<&OsStr>) -> Option<PathBuf> {
    let path = path?;
    let exts: Vec<String> = if cfg!(windows) {
        std::env::var("PATHEXT")
            .unwrap_or_else(|_| ".EXE;.CMD;.BAT".to_string())
            .split(';')
            .map(|s| s.to_string())
            .collect()
    } else {
        vec![String::new()]
    };
    for dir in std::env::split_paths(path) {
        for ext in &exts {
            let candidate = dir.join(format!("{binary}{ext}"));
            if candidate.is_file() {
                return Some(candidate);
            }
        }
    }
    None
}

/// Run the version command and return its first non-empty line (some CLIs print to
/// stderr, so fall back to that). Delegates the spawn/drain/kill to the runner's
/// `run_with_timeout`, so the subprocess-timeout safety logic lives in one place:
/// stdin is closed and the probe is killed past `VERSION_TIMEOUT`, so a CLI that
/// prompts or stalls can't hang detection.
pub fn detect_version(path: &std::path::Path, args: &[&str]) -> Option<String> {
    let mut cmd = Command::new(path);
    cmd.args(args);
    let out = run_with_timeout(cmd, VERSION_TIMEOUT);
    let text = if out.stdout.trim().is_empty() {
        out.stderr
    } else {
        out.stdout
    };
    text.lines()
        .map(str::trim)
        .find(|l| !l.is_empty())
        .map(|s| s.to_string())
}

/// Probe every shipped adapter, concurrently. Pure read — never spawns an agent
/// run. The search PATH is built once, and each agent's `--version` probe runs on
/// its own thread, so a stalled CLI (killed at `VERSION_TIMEOUT`) costs ~4s total
/// rather than 4×4s serial. Results preserve adapter display order.
pub fn detect_all() -> Vec<DetectedAgent> {
    let path = search_path();
    let handles: Vec<_> = all_adapters()
        .into_iter()
        .map(|a| {
            let resolved = which_in(a.binary(), Some(path.as_os_str()));
            let version_args = a.version_args();
            let adapter_id = a.id().to_string();
            let display_name = a.display_name().to_string();
            let binary = a.binary().to_string();
            let install_url = a.install_url().to_string();
            let supports_allowlist = a.supports_allowlist();
            std::thread::spawn(move || {
                let version = resolved.as_ref().and_then(|p| detect_version(p, version_args));
                DetectedAgent {
                    adapter_id,
                    display_name,
                    binary,
                    install_url,
                    installed: resolved.is_some(),
                    binary_path: resolved.map(|p| p.display().to_string()),
                    version,
                    supports_allowlist,
                }
            })
        })
        .collect();
    handles.into_iter().filter_map(|h| h.join().ok()).collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn detect_all_returns_every_adapter() {
        let detected = detect_all();
        assert_eq!(detected.len(), 4);
        let ids: Vec<&str> = detected.iter().map(|d| d.adapter_id.as_str()).collect();
        for want in ["claude-code", "codex", "opencode", "gemini"] {
            assert!(ids.contains(&want), "missing {want}");
        }
        // OpenCode is the one that can't honor allowlist cleanly.
        let oc = detected.iter().find(|d| d.adapter_id == "opencode").unwrap();
        assert!(!oc.supports_allowlist);
    }

    #[test]
    fn which_in_finds_executable_on_a_fake_path() {
        let tmp = tempfile::tempdir().unwrap();
        let bin = tmp.path().join("faketool");
        std::fs::write(&bin, b"#!/bin/sh\necho hi\n").unwrap();
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            let mut perms = std::fs::metadata(&bin).unwrap().permissions();
            perms.set_mode(0o755);
            std::fs::set_permissions(&bin, perms).unwrap();
        }
        let found = which_in("faketool", Some(tmp.path().as_os_str()));
        assert_eq!(found.as_deref(), Some(bin.as_path()));
        assert!(which_in("does-not-exist-xyz", Some(tmp.path().as_os_str())).is_none());
    }

    #[cfg(unix)]
    #[test]
    fn detect_version_reads_first_line() {
        let tmp = tempfile::tempdir().unwrap();
        let bin = tmp.path().join("vertool");
        std::fs::write(&bin, b"#!/bin/sh\necho 'vertool 9.9.9'\n").unwrap();
        use std::os::unix::fs::PermissionsExt;
        let mut perms = std::fs::metadata(&bin).unwrap().permissions();
        perms.set_mode(0o755);
        std::fs::set_permissions(&bin, perms).unwrap();
        let v = detect_version(&bin, &["--version"]);
        assert_eq!(v.as_deref(), Some("vertool 9.9.9"));
    }
}
