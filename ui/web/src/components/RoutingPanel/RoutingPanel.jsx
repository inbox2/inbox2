import { useState, useEffect, useCallback } from 'react';
import { ContextGroup, ContextField } from '../ContextPanel';
import Icon from '../Icon';
import CreateRulePopup from '../CreateRulePopup';
import RunDetailModal from '../RunDetailModal/RunDetailModal';
import AgentLogo from '../AgentLogo/AgentLogo';
import { isTauri } from '../../lib/tauri';
import { emailOnly } from '../../lib/emailAddress';
import {
  listLocalRules,
  listAgentRuns,
  listAgentApprovals,
  resolveAgentApproval,
  retryAgentRun,
  runRuleOnConversation,
  conditionsMatch,
  ACTION_KINDS,
  BUILTIN_ACTIONS,
  AGENT_IDS,
} from '../../lib/localAgents';
import { formatClock as shortTime } from '../../lib/relativeTime';
import layout from '../../styles/layout.module.css';
import styles from './RoutingPanel.module.css';

// Run-status → chip presentation. Mirrors AgentRunsPanel's STATUS so a rule's
// latest run reads the same in both places.
const STATUS = {
  pending: { label: 'Waiting', cls: 'pending', icon: 'clock' },
  awaiting_approval: { label: 'Needs approval', cls: 'awaiting', icon: 'hand.raised.fill' },
  running: { label: 'Running', cls: 'running', icon: 'gear' },
  succeeded: { label: 'Done', cls: 'ok', icon: 'checkmark.circle.fill' },
  failed: { label: 'Failed', cls: 'fail', icon: 'xmark.circle.fill' },
  timeout: { label: 'Timed out', cls: 'fail', icon: 'timer' },
};
// A matched rule that hasn't produced a run for this conversation.
const MATCHED = { label: 'Matched', cls: 'matched', icon: 'checkmark.circle' };
const DISABLED = { label: 'Disabled', cls: 'disabled', icon: 'minus.circle' };

// What a rule does, for the secondary line: the built-in action's label, or the
// agent's adapter id.
function actionLabel(action) {
  if (action?.type === ACTION_KINDS.PERFORM) {
    return BUILTIN_ACTIONS.find((a) => a.value === action.builtin)?.label || action.builtin || 'Action';
  }
  return action?.adapter_id || 'Agent';
}

/**
 * Routing group for the open conversation: which local rules match it, each with
 * its latest run status, plus a "Create rule…" affordance prefilled from the
 * conversation. Rules + runs are desktop-only (local SQLite via Tauri); in the
 * browser the list is empty and only the create button shows.
 * See docs/Agentic-Filters.md §5.2.
 */
export default function RoutingPanel({ conversation }) {
  const [rules, setRules] = useState([]);
  const [runs, setRuns] = useState([]);
  const [approvals, setApprovals] = useState({}); // run_key → approval_key
  const [busyKey, setBusyKey] = useState(''); // rule key mid manual run
  const [detail, setDetail] = useState(null); // run shown in the detail modal
  const [createOpen, setCreateOpen] = useState(false);
  const conversationKey = conversation?.key || conversation?.id;

  const refresh = useCallback(async () => {
    if (!isTauri() || !conversationKey) return;
    const [ruleList, runList, pending] = await Promise.all([
      listLocalRules(),
      listAgentRuns({ conversationKey }),
      listAgentApprovals(),
    ]);
    setRules(ruleList || []);
    setRuns(runList || []);
    const map = {};
    for (const a of pending || []) if (a.run_key) map[a.run_key] = a.approval_key;
    setApprovals(map);
  }, [conversationKey]);

  const handleRun = async (rule) => {
    setBusyKey(rule.key);
    try {
      await runRuleOnConversation(rule.key, conversationKey);
      await refresh();
    } finally {
      setBusyKey('');
    }
  };

  const handleApproval = async (approvalKey, approved) => {
    await resolveAgentApproval(approvalKey, approved);
    await refresh();
  };

  const handleRetry = async (runKey) => {
    await retryAgentRun(runKey);
    await refresh();
  };

  // Open the detail modal — an existing run, or, for a matched rule that hasn't run
  // yet, a preview of the prompt/action it would run (synthesized from the rule).
  const openRule = (rule, run) => {
    if (run) return setDetail(run);
    const agent = rule.action?.type === ACTION_KINDS.AGENT;
    setDetail({
      adapter_id: agent ? rule.action.adapter_id : rule.action?.builtin || 'action',
      status: 'matched',
      task: agent ? rule.action.task : `Built-in action: ${actionLabel(rule.action)}`,
      result_json: null,
    });
  };

  /* eslint-disable react-hooks/set-state-in-effect -- intentional: fetch rules + runs */
  useEffect(() => {
    if (!isTauri() || !conversationKey) return;
    refresh();
  }, [refresh, conversationKey]);
  /* eslint-enable react-hooks/set-state-in-effect */

  // Poll only while a run tied to this conversation is in flight.
  const hasLive = runs.some((r) => ['pending', 'running', 'awaiting_approval'].includes(r.status));
  useEffect(() => {
    if (!isTauri() || !conversationKey || !hasLive) return;
    const t = setInterval(refresh, 5000);
    return () => clearInterval(t);
  }, [refresh, conversationKey, hasLive]);

  if (!conversation) return null;

  const fields = {
    from: conversation.from_address || '',
    to: conversation.to_address || '',
    subject: conversation.subject || '',
    body: conversation.snippet || '',
    has_attachment: !!conversation.has_attachment,
  };
  const matched = rules.filter((r) => conditionsMatch(r.conditions, fields));

  // Latest run per rule, keyed by rule_key (ISO timestamps compare lexically).
  const latestByRule = {};
  for (const r of runs) {
    if (!r.rule_key) continue;
    const prev = latestByRule[r.rule_key];
    if (!prev || (r.updated_at || '') > (prev.updated_at || '')) latestByRule[r.rule_key] = r;
  }

  return (
    <>
      <ContextGroup icon="arrow.triangle.branch" title="Routing" badge={matched.length || undefined}>
        <ContextField label="Rules">
          <button
            type="button"
            className={layout.contextLabelEmpty}
            onClick={() => setCreateOpen(true)}
          >
            <Icon name="plus" size={11} />
            Create rule…
          </button>
        </ContextField>
        {matched.length === 0 ? (
          <p className={styles.empty}>No rules match this conversation.</p>
        ) : (
          matched.map((rule) => {
            const run = latestByRule[rule.key];
            const enabled = rule.enabled !== false;
            const s = run
              ? STATUS[run.status] || STATUS.pending
              : enabled
                ? MATCHED
                : DISABLED;
            const approvalKey = run?.status === 'awaiting_approval' ? approvals[run.key] : null;
            const retriable = run?.status === 'failed' || run?.status === 'timeout';
            // Offer a manual run when the rule matches, is enabled, and hasn't run
            // on this conversation yet.
            const canRun = enabled && !run;
            return (
              <div key={rule.key} className={styles.rule}>
                <span className={`${styles.chip} ${styles[s.cls]}`}>
                  <Icon name={s.icon} size={10} />
                  {s.label}
                </span>
                <button
                  type="button"
                  className={styles.body}
                  onClick={() => openRule(rule, run)}
                  title={run ? 'View run log' : 'View prompt'}
                >
                  <span className={styles.name}>{rule.name}</span>
                  <span className={styles.action}>
                    {rule.action?.type === ACTION_KINDS.AGENT &&
                      AGENT_IDS.includes(rule.action.adapter_id) && (
                        <AgentLogo adapterId={rule.action.adapter_id} size={12} className={styles.actionLogo} />
                      )}
                    {actionLabel(rule.action)}
                  </span>
                </button>
                {run && <span className={styles.time}>{shortTime(run.updated_at)}</span>}
                {approvalKey ? (
                  <span className={styles.approveRow}>
                    <button
                      type="button"
                      className={styles.approve}
                      onClick={() => handleApproval(approvalKey, true)}
                      aria-label="Approve first run"
                      title="Approve first run"
                    >
                      <Icon name="checkmark" size={11} />
                    </button>
                    <button
                      type="button"
                      className={styles.reject}
                      onClick={() => handleApproval(approvalKey, false)}
                      aria-label="Reject"
                      title="Reject"
                    >
                      <Icon name="xmark" size={11} />
                    </button>
                  </span>
                ) : retriable ? (
                  <button
                    type="button"
                    className={styles.runBtn}
                    onClick={() => handleRetry(run.key)}
                    aria-label="Retry"
                    title="Retry"
                  >
                    <Icon name="arrow.clockwise" size={12} />
                  </button>
                ) : canRun ? (
                  <button
                    type="button"
                    className={styles.runBtn}
                    onClick={() => handleRun(rule)}
                    disabled={busyKey === rule.key}
                    aria-label="Run on this conversation"
                    title="Run on this conversation"
                  >
                    <Icon name="play.fill" size={12} />
                  </button>
                ) : null}
              </div>
            );
          })
        )}
      </ContextGroup>

      <CreateRulePopup
        open={createOpen}
        onClose={() => setCreateOpen(false)}
        prefill={{
          from: emailOnly(conversation.from_address),
          to: emailOnly(conversation.to_address),
          subject: conversation.subject,
          hasAttachment: !!conversation.has_attachment,
        }}
        onSaved={refresh}
      />

      <RunDetailModal
        run={detail}
        onClose={() => setDetail(null)}
        onRerun={(runKey) => {
          setDetail(null);
          handleRetry(runKey);
        }}
      />
    </>
  );
}
