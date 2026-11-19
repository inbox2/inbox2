// IPC wrappers for agentic filters (local CLI agents). Desktop-only — every call
// returns an inert value in the browser. See docs/Agentic-Filters.md §5.3.
import { isTauri } from './tauri';

async function call(cmd, args) {
  const { invoke } = await import('@tauri-apps/api/core');
  return invoke(cmd, args);
}

// The per-rule permission posture (docs §3.4). Kept here as the single source so
// the create-rule popup and any other caller stay in sync.
export const PERMISSION_MODES = [
  {
    value: 'allowlist',
    label: 'Allowlist (sandboxed)',
    desc: "Limited tools. It's the safest, but the agent can't reach outside services.",
  },
  {
    value: 'approval_first',
    label: 'Approve first run',
    desc: 'Full access. You approve the first run, then it runs on its own.',
  },
  {
    value: 'full_auto',
    label: 'Full auto',
    desc: 'Full access with no approval. A crafted email could steer the agent.',
  },
];

// A rule's action is either invoking a CLI agent, or one of the built-in
// "perform action" outcomes. Kept here as the single source so the editor and the
// Rust `RuleAction` (local_agents/store.rs) stay in sync.
export const ACTION_KINDS = {
  AGENT: 'run_agent',
  PERFORM: 'perform_action',
};

// Adapter ids that have a real brand mark (AgentLogo) — callers gate on this so
// built-in action "runs" (archive/delete/…) don't get an agent glyph.
export const AGENT_IDS = ['claude-code', 'codex', 'opencode', 'gemini'];

export const BUILTIN_ACTIONS = [
  { value: 'archive', label: 'Archive', icon: 'archivebox.fill', desc: 'Move it out of the inbox.' },
  { value: 'delete', label: 'Delete', icon: 'trash.fill', desc: 'Move it to trash.' },
  { value: 'mark_read', label: 'Mark as read', icon: 'envelope.open', desc: 'Clear the unread badge.' },
  { value: 'auto_triage', label: 'Triage', icon: 'arrow.triangle.branch', desc: 'Set a priority.' },
  { value: 'auto_label', label: 'Auto-label', icon: 'tag.fill', desc: 'Let on-device AI apply a label.' },
  { value: 'auto_reply', label: 'Reply', icon: 'arrowshape.turn.up.left.fill', desc: 'Send a canned reply.' },
];

// Priority targets for the `auto_triage` action's follow-up choice. 'auto' lets the
// on-device AI pick; the rest map to a fixed Eisenhower quadrant (mirrors the Rust
// quadrant_to_priority in local_agents/actions.rs).
export const TRIAGE_OPTIONS = [
  { value: 'auto', label: 'Auto: on-device AI decides' },
  { value: 'DO_FIRST', label: 'Do first: urgent and important' },
  { value: 'SCHEDULE', label: 'Schedule: important' },
  { value: 'DELEGATE', label: 'Delegate: urgent' },
  { value: 'LATER', label: 'Later: neither' },
];

export async function detectLocalAgents() {
  if (!isTauri()) return [];
  return call('detect_local_agents');
}

export async function setLocalAgentEnabled(adapterId, enabled) {
  if (!isTauri()) return;
  return call('set_local_agent_enabled', { adapterId, enabled });
}

export async function listLocalRules() {
  if (!isTauri()) return [];
  return call('list_local_rules');
}

export async function upsertLocalRule(rule) {
  if (!isTauri()) return null;
  return call('upsert_local_rule', { rule });
}

export async function deleteLocalRule(key) {
  if (!isTauri()) return;
  return call('delete_local_rule', { key });
}

/// Preview which existing emails a (possibly unsaved) rule would affect — read-only,
/// Tier-0 conditions over current local-channel mail. Returns
/// { samples: [{ message_key, from, subject, date, ... }], total, scanned_capped }.
export async function previewRuleMatches(rule) {
  if (!isTauri()) return { samples: [], total: 0, scanned_capped: false };
  return call('preview_rule_matches', { rule });
}

/// Run a saved rule's action against existing matching mail (the wizard's "apply
/// to existing emails" option on a persisted rule). Returns the number acted on.
export async function applyRuleToExisting(ruleKey) {
  if (!isTauri()) return 0;
  return call('apply_rule_to_existing', { ruleKey });
}

/// Run an unsaved rule's action against existing mail once, without persisting the
/// rule (the wizard's "run once"). Returns the number of messages acted on.
export async function runRuleOnce(rule) {
  if (!isTauri()) return 0;
  return call('run_rule_once', { rule });
}

/// Run a saved rule against a single conversation now (the routing panel's manual
/// "Run"). Returns the number of messages acted on.
export async function runRuleOnConversation(ruleKey, conversationKey) {
  if (!isTauri()) return 0;
  return call('run_rule_on_conversation', { ruleKey, conversationKey });
}

export async function testRunAgent({ adapterId, messageKey, accountKey, task, permissionMode }) {
  if (!isTauri()) return null;
  return call('test_run_agent', { adapterId, messageKey, accountKey, task, permissionMode });
}

export async function listAgentRuns({ conversationKey, messageKey, limit } = {}) {
  if (!isTauri()) return [];
  return call('list_agent_runs', {
    conversationKey: conversationKey ?? null,
    messageKey: messageKey ?? null,
    limit: limit ?? null,
  });
}

export async function retryAgentRun(runKey) {
  if (!isTauri()) return;
  return call('retry_agent_run', { runKey });
}

export async function listAgentApprovals() {
  if (!isTauri()) return [];
  return call('list_agent_approvals');
}

export async function listFailedAgentRuns(limit) {
  if (!isTauri()) return [];
  return call('list_failed_agent_runs', { limit: limit ?? null });
}

export async function resolveAgentApproval(approvalKey, approved) {
  if (!isTauri()) return;
  return call('resolve_agent_approval', { approvalKey, approved });
}

/// Tier-0 static matching, ported from the Rust `conditions_match`
/// (ui/desktop/src-tauri/src/local_agents/rules.rs) so the sidebar can show which
/// rules a conversation matches without a round-trip. Keep the two in sync.
/// `fields` is { from, to, subject, body, has_attachment }. An empty condition set
/// never matches (a rule with no conditions would fire on everything).
export function conditionsMatch(conditions, fields) {
  if (!conditions || conditions.length === 0) return false;
  return conditions.every((c) => conditionMatch(c, fields));
}

function conditionMatch(c, m) {
  if (c.field === 'has_attachment') {
    switch (c.op) {
      case 'is_true':
        return !!m.has_attachment;
      case 'is_false':
        return !m.has_attachment;
      case 'equals':
        return (c.value === 'true') === !!m.has_attachment;
      default:
        return false;
    }
  }

  if (!['from', 'to', 'subject', 'body'].includes(c.field)) return false;
  const haystack = String(m[c.field] || '').toLowerCase();
  const needle = String(c.value || '').toLowerCase();
  switch (c.op) {
    case 'equals':
      return haystack === needle;
    case 'contains':
      return haystack.includes(needle);
    case 'starts_with':
      return haystack.startsWith(needle);
    case 'ends_with':
      return haystack.endsWith(needle);
    default:
      return false;
  }
}

/// Build the snake_case rule payload the Rust `LocalRule`/`RuleAction` serde
/// structs expect. Tauri converts top-level arg keys, but nested struct fields are
/// deserialized verbatim — hence the snake_case here.
export function buildRulePayload({
  key,
  name,
  accountKey,
  conditions,
  enabled = true,
  action, // pre-built action object (preferred)
  // Legacy run_agent shorthand — used when `action` is omitted.
  adapterId,
  task,
  permissionMode,
  timeoutS,
}) {
  const act = action || {
    type: ACTION_KINDS.AGENT,
    adapter_id: adapterId,
    task,
    permission_mode: permissionMode,
    timeout_s: timeoutS || 120,
  };
  return {
    key: key || '',
    name,
    account_key: accountKey || null,
    conditions,
    ai_gate: null,
    action: act,
    enabled,
  };
}

/// Action object for invoking a CLI agent.
export function agentAction({ adapterId, task, permissionMode, timeoutS }) {
  return {
    type: ACTION_KINDS.AGENT,
    adapter_id: adapterId,
    task,
    permission_mode: permissionMode,
    timeout_s: timeoutS || 120,
  };
}

/// Action object for a built-in "perform action" outcome (see BUILTIN_ACTIONS).
/// `extra` carries per-action config: { quadrant } for auto_triage, { reply } for
/// auto_reply.
export function performAction(builtin, extra = {}) {
  return { type: ACTION_KINDS.PERFORM, builtin, ...extra };
}
