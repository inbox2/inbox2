// The four shipped adapters + the registry.
//
// Invocations verified against current docs (mid-2026) — see docs/Agentic-Filters.md
// §2.2. Re-pin these against the installed version when a CLI ships a breaking change.

use std::process::Command;

use super::adapter::{AgentAdapter, PermissionMode, RunContext};

// ─── Claude Code ─────────────────────────────────────────────────────────────
// claude -p --output-format json {--dangerously-skip-permissions | --permission-mode dontAsk --allowedTools …}
//        --append-system-prompt-file <task.md> "<task>"
// `-p` is non-interactive. By default it uses the user's existing login (keychain
// OAuth) — we deliberately do NOT pass --bare, which would skip the keychain and
// demand ANTHROPIC_API_KEY. The scratch dir has no CLAUDE.md, so cwd interference
// is minimal.
pub struct ClaudeCode;

impl AgentAdapter for ClaudeCode {
    fn id(&self) -> &'static str {
        "claude-code"
    }
    fn display_name(&self) -> &'static str {
        "Claude Code"
    }
    fn binary(&self) -> &'static str {
        "claude"
    }
    fn install_url(&self) -> &'static str {
        "https://claude.com/claude-code"
    }
    fn supports_allowlist(&self) -> bool {
        true
    }
    fn build_command(&self, ctx: &RunContext, mode: PermissionMode) -> Command {
        let mut cmd = Command::new(self.binary());
        cmd.current_dir(&ctx.scratch_dir);
        cmd.arg("-p");
        cmd.args(["--output-format", "json"]);
        match mode {
            PermissionMode::Allowlist => {
                cmd.args(["--permission-mode", "dontAsk"]);
                cmd.args(["--allowedTools", "Read,Write,Edit,Bash"]);
            }
            PermissionMode::ApprovalFirst | PermissionMode::FullAuto => {
                cmd.arg("--dangerously-skip-permissions");
            }
        }
        cmd.arg("--append-system-prompt-file").arg(&ctx.preamble_file);
        if let Some(model) = &ctx.model {
            cmd.args(["--model", model]);
        }
        // The prompt is positional and must come last. `--` guards against a task
        // that begins with a dash being parsed as a flag.
        cmd.arg("--").arg(&ctx.task);
        cmd
    }
}

// ─── OpenAI Codex ────────────────────────────────────────────────────────────
// codex exec --json --cd <scratch> --skip-git-repo-check
//      {--dangerously-bypass-approvals-and-sandbox | --sandbox workspace-write --ask-for-approval never} "<prompt>"
// --skip-git-repo-check is required: the scratch dir is not a git repo.
pub struct Codex;

impl AgentAdapter for Codex {
    fn id(&self) -> &'static str {
        "codex"
    }
    fn display_name(&self) -> &'static str {
        "Codex"
    }
    fn binary(&self) -> &'static str {
        "codex"
    }
    fn install_url(&self) -> &'static str {
        "https://developers.openai.com/codex/cli"
    }
    fn supports_allowlist(&self) -> bool {
        true
    }
    fn build_command(&self, ctx: &RunContext, mode: PermissionMode) -> Command {
        let mut cmd = Command::new(self.binary());
        cmd.current_dir(&ctx.scratch_dir);
        cmd.arg("exec");
        cmd.arg("--json");
        cmd.arg("--cd").arg(&ctx.scratch_dir);
        cmd.arg("--skip-git-repo-check");
        match mode {
            PermissionMode::Allowlist => {
                cmd.args(["--sandbox", "workspace-write"]);
                cmd.args(["--ask-for-approval", "never"]);
            }
            PermissionMode::ApprovalFirst | PermissionMode::FullAuto => {
                cmd.arg("--dangerously-bypass-approvals-and-sandbox");
            }
        }
        if let Some(model) = &ctx.model {
            cmd.args(["-m", model]);
        }
        cmd.arg(&ctx.full_prompt);
        cmd
    }
}

// ─── OpenCode ────────────────────────────────────────────────────────────────
// opencode run --format json --dir <scratch> [--dangerously-skip-permissions] "<prompt>"
// No clean per-call allowlist: a permission prompt aborts the run, so Allowlist
// mode simply omits the skip flag and may fail. supports_allowlist == false.
pub struct OpenCode;

impl AgentAdapter for OpenCode {
    fn id(&self) -> &'static str {
        "opencode"
    }
    fn display_name(&self) -> &'static str {
        "OpenCode"
    }
    fn binary(&self) -> &'static str {
        "opencode"
    }
    fn install_url(&self) -> &'static str {
        "https://opencode.ai"
    }
    fn supports_allowlist(&self) -> bool {
        false
    }
    fn build_command(&self, ctx: &RunContext, mode: PermissionMode) -> Command {
        let mut cmd = Command::new(self.binary());
        cmd.current_dir(&ctx.scratch_dir);
        cmd.arg("run");
        cmd.args(["--format", "json"]);
        cmd.arg("--dir").arg(&ctx.scratch_dir);
        if mode.is_full_access() {
            cmd.arg("--dangerously-skip-permissions");
        }
        if let Some(model) = &ctx.model {
            cmd.args(["--model", model]);
        }
        cmd.arg(&ctx.full_prompt);
        cmd
    }
}

// ─── Gemini CLI ──────────────────────────────────────────────────────────────
// gemini -p "<prompt>" --output-format json --include-directories <scratch>
//        {--yolo | --approval-mode auto_edit}
// Only --yolo guarantees no stall; auto_edit can hang on shell tools, so the
// runner's timeout is the backstop. supports_allowlist == true (best-effort).
pub struct Gemini;

impl AgentAdapter for Gemini {
    fn id(&self) -> &'static str {
        "gemini"
    }
    fn display_name(&self) -> &'static str {
        "Gemini CLI"
    }
    fn binary(&self) -> &'static str {
        "gemini"
    }
    fn install_url(&self) -> &'static str {
        "https://github.com/google-gemini/gemini-cli"
    }
    fn supports_allowlist(&self) -> bool {
        true
    }
    fn build_command(&self, ctx: &RunContext, mode: PermissionMode) -> Command {
        let mut cmd = Command::new(self.binary());
        cmd.current_dir(&ctx.scratch_dir);
        cmd.arg("-p").arg(&ctx.full_prompt);
        cmd.args(["--output-format", "json"]);
        cmd.arg("--include-directories").arg(&ctx.scratch_dir);
        match mode {
            PermissionMode::Allowlist => {
                cmd.args(["--approval-mode", "auto_edit"]);
            }
            PermissionMode::ApprovalFirst | PermissionMode::FullAuto => {
                cmd.arg("--yolo");
            }
        }
        if let Some(model) = &ctx.model {
            cmd.args(["-m", model]);
        }
        cmd
    }
}

// ─── Registry ────────────────────────────────────────────────────────────────

/// Every shipped adapter, in display order.
pub fn all_adapters() -> Vec<Box<dyn AgentAdapter>> {
    vec![
        Box::new(ClaudeCode),
        Box::new(Codex),
        Box::new(OpenCode),
        Box::new(Gemini),
    ]
}

/// Resolve an adapter by its stable id. Derived from `all_adapters` so the registry
/// has a single source of truth.
pub fn adapter_for(id: &str) -> Option<Box<dyn AgentAdapter>> {
    all_adapters().into_iter().find(|a| a.id() == id)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::path::PathBuf;

    fn ctx() -> RunContext {
        RunContext {
            scratch_dir: PathBuf::from("/tmp/run_x"),
            preamble_file: PathBuf::from("/tmp/run_x/task.md"),
            task: "extract the invoice".to_string(),
            full_prompt: "PREAMBLE\n\n--- TASK ---\nextract the invoice".to_string(),
            model: None,
        }
    }

    fn argv(cmd: &Command) -> Vec<String> {
        cmd.get_args()
            .map(|a| a.to_string_lossy().to_string())
            .collect()
    }

    fn program(cmd: &Command) -> String {
        cmd.get_program().to_string_lossy().to_string()
    }

    fn contains_seq(args: &[String], seq: &[&str]) -> bool {
        args.windows(seq.len()).any(|w| w == seq)
    }

    #[test]
    fn claude_full_auto_is_noninteractive_and_skips_permissions() {
        let cmd = ClaudeCode.build_command(&ctx(), PermissionMode::FullAuto);
        let args = argv(&cmd);
        assert_eq!(program(&cmd), "claude");
        assert!(args.contains(&"-p".to_string()), "must be print/headless");
        assert!(contains_seq(&args, &["--output-format", "json"]));
        assert!(args.contains(&"--dangerously-skip-permissions".to_string()));
        assert!(!args.contains(&"--permission-mode".to_string()));
        // task is the final positional, guarded by `--`
        assert_eq!(args.last().unwrap(), "extract the invoice");
        assert!(cmd.get_current_dir().unwrap().ends_with("run_x"));
    }

    #[test]
    fn claude_allowlist_uses_dontask_not_bypass() {
        let cmd = ClaudeCode.build_command(&ctx(), PermissionMode::Allowlist);
        let args = argv(&cmd);
        assert!(contains_seq(&args, &["--permission-mode", "dontAsk"]));
        assert!(args.iter().any(|a| a == "--allowedTools"));
        assert!(!args.contains(&"--dangerously-skip-permissions".to_string()));
    }

    #[test]
    fn codex_requires_git_skip_and_cd() {
        let c = ctx();
        let cmd = Codex.build_command(&c, PermissionMode::FullAuto);
        let args = argv(&cmd);
        assert_eq!(program(&cmd), "codex");
        assert_eq!(args.first().unwrap(), "exec");
        assert!(args.contains(&"--json".to_string()));
        assert!(args.contains(&"--skip-git-repo-check".to_string()));
        assert!(contains_seq(
            &args,
            &["--cd", &c.scratch_dir.to_string_lossy()]
        ));
        assert!(args.contains(&"--dangerously-bypass-approvals-and-sandbox".to_string()));
    }

    #[test]
    fn codex_allowlist_sandboxes_workspace() {
        let cmd = Codex.build_command(&ctx(), PermissionMode::Allowlist);
        let args = argv(&cmd);
        assert!(contains_seq(&args, &["--sandbox", "workspace-write"]));
        assert!(contains_seq(&args, &["--ask-for-approval", "never"]));
        assert!(!args.contains(&"--dangerously-bypass-approvals-and-sandbox".to_string()));
    }

    #[test]
    fn opencode_full_auto_skips_permissions_allowlist_does_not() {
        let full = OpenCode.build_command(&ctx(), PermissionMode::FullAuto);
        let allow = OpenCode.build_command(&ctx(), PermissionMode::Allowlist);
        assert_eq!(program(&full), "opencode");
        assert_eq!(argv(&full).first().unwrap(), "run");
        assert!(argv(&full).contains(&"--dangerously-skip-permissions".to_string()));
        assert!(!argv(&allow).contains(&"--dangerously-skip-permissions".to_string()));
        assert!(!OpenCode.supports_allowlist());
    }

    #[test]
    fn gemini_yolo_for_full_auto_autoedit_for_allowlist() {
        let full = Gemini.build_command(&ctx(), PermissionMode::FullAuto);
        let allow = Gemini.build_command(&ctx(), PermissionMode::Allowlist);
        assert_eq!(program(&full), "gemini");
        assert!(argv(&full).contains(&"-p".to_string()));
        assert!(contains_seq(&argv(&full), &["--output-format", "json"]));
        assert!(argv(&full).contains(&"--yolo".to_string()));
        assert!(contains_seq(&argv(&allow), &["--approval-mode", "auto_edit"]));
    }

    #[test]
    fn approval_first_uses_full_access_flags() {
        // approval_first runs with the same flags as full_auto; the gate is in the runner.
        for ad in all_adapters() {
            let full = argv(&ad.build_command(&ctx(), PermissionMode::FullAuto));
            let appr = argv(&ad.build_command(&ctx(), PermissionMode::ApprovalFirst));
            assert_eq!(full, appr, "{} approval_first should match full_auto argv", ad.id());
        }
    }

    #[test]
    fn registry_resolves_all_and_rejects_unknown() {
        for ad in all_adapters() {
            assert!(adapter_for(ad.id()).is_some(), "{} not resolvable", ad.id());
        }
        assert!(adapter_for("nope").is_none());
    }

    #[test]
    fn model_override_threads_through() {
        let mut c = ctx();
        c.model = Some("opus".to_string());
        let cmd = ClaudeCode.build_command(&c, PermissionMode::FullAuto);
        assert!(contains_seq(&argv(&cmd), &["--model", "opus"]));
    }
}
