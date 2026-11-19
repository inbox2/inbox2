// AgentAdapter — the per-CLI invocation contract.
//
// Every locally-installed agent (Claude Code, Codex, OpenCode, Gemini) differs in
// its non-interactive subcommand, the flag that suppresses permission prompts, how
// it takes a prompt, and how it reports output. Each is wrapped in one impl of this
// trait so adding an agent later is a single new struct + a registry entry.
//
// See docs/Agentic-Filters.md §2.

use std::path::PathBuf;
use std::process::Command;

/// How much the agent is trusted to do unattended, chosen per-rule by the user.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum PermissionMode {
    /// Restricted tools / sandboxed. Safest; may be too limited for some tasks.
    Allowlist,
    /// Full access, but the first firing of a rule needs one human approval.
    ApprovalFirst,
    /// Full access, no gate. Max power, max prompt-injection exposure.
    FullAuto,
}

impl Default for PermissionMode {
    /// The conservative default when a mode is missing or unparseable.
    fn default() -> Self {
        PermissionMode::ApprovalFirst
    }
}

impl PermissionMode {
    pub fn as_str(self) -> &'static str {
        match self {
            PermissionMode::Allowlist => "allowlist",
            PermissionMode::ApprovalFirst => "approval_first",
            PermissionMode::FullAuto => "full_auto",
        }
    }

    pub fn parse(s: &str) -> Option<Self> {
        match s {
            "allowlist" => Some(PermissionMode::Allowlist),
            "approval_first" => Some(PermissionMode::ApprovalFirst),
            "full_auto" => Some(PermissionMode::FullAuto),
            _ => None,
        }
    }

    /// Approval-gated and ungated full runs both use the agent's full-access flags;
    /// the approval gate is enforced by the runner, not by the command shape.
    pub fn is_full_access(self) -> bool {
        matches!(self, PermissionMode::ApprovalFirst | PermissionMode::FullAuto)
    }
}

/// What a matched rule does: invoke a CLI agent, or apply a built-in outcome.
/// Single source for the persisted `action_type` strings (CLAUDE.md: no
/// duplicated enums) — the same literals were repeated across the rule
/// deserializer default and the runner's dispatch match.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum AgentActionType {
    /// Invoke a locally-installed CLI agent in the harness.
    RunAgent,
    /// Apply a built-in mailbox action (mark read, archive, …) inline.
    PerformAction,
}

impl AgentActionType {
    pub fn as_str(self) -> &'static str {
        match self {
            AgentActionType::RunAgent => "run_agent",
            AgentActionType::PerformAction => "perform_action",
        }
    }

    pub fn parse(s: &str) -> Option<Self> {
        match s {
            "run_agent" => Some(AgentActionType::RunAgent),
            "perform_action" => Some(AgentActionType::PerformAction),
            _ => None,
        }
    }
}

/// Everything an adapter needs to construct one invocation. The email itself never
/// goes on the command line — it lives on disk in `scratch_dir` (see harness).
pub struct RunContext {
    /// The agent's cwd. Contains email.eml, body.txt, attachments/, context.json, task.md.
    pub scratch_dir: PathBuf,
    /// Path to task.md (the preamble + task); used by agents with a system-prompt-file flag.
    pub preamble_file: PathBuf,
    /// The user's task string only.
    pub task: String,
    /// Preamble + task combined, for agents that take a single prompt argument.
    pub full_prompt: String,
    /// Optional model override.
    pub model: Option<String>,
}

pub trait AgentAdapter: Send + Sync {
    /// Stable id, e.g. "claude-code". Maps to `local_agents.adapter_id`.
    fn id(&self) -> &'static str;
    fn display_name(&self) -> &'static str;
    /// The executable name searched for on PATH.
    fn binary(&self) -> &'static str;
    fn install_url(&self) -> &'static str;
    /// Args that print the version (and confirm the binary runs).
    fn version_args(&self) -> &'static [&'static str] {
        &["--version"]
    }
    /// Whether this agent can honor `Allowlist` without stalling. OpenCode cannot
    /// (a permission prompt aborts the run); Gemini's is best-effort.
    fn supports_allowlist(&self) -> bool;
    /// Build the fully-configured, non-interactive command for one run.
    fn build_command(&self, ctx: &RunContext, mode: PermissionMode) -> Command;
}

/// Result of probing PATH for an agent. Serialized to the frontend.
#[derive(Debug, Clone, serde::Serialize)]
pub struct DetectedAgent {
    pub adapter_id: String,
    pub display_name: String,
    pub binary: String,
    pub install_url: String,
    pub installed: bool,
    pub binary_path: Option<String>,
    pub version: Option<String>,
    pub supports_allowlist: bool,
}
