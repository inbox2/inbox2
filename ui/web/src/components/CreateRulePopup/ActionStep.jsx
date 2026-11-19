import Icon from '../Icon';
import {
  ACTION_KINDS,
  BUILTIN_ACTIONS,
  TRIAGE_OPTIONS,
  PERMISSION_MODES,
} from '../../lib/localAgents';
import { MX_ACTION_TYPES, MX_STATUS_OPTIONS } from '../../lib/mxRules';
import { MgmtSelect } from '../management';
import styles from './CreateRulePopup.module.css';

const memberLabel = (m) =>
  m.user?.display_name || m.user?.username || (m.email_addresses && m.email_addresses[0]) || m.id;

/**
 * Step 2 — choose the action. Two action models:
 *   - MX rules (mode === 'mx'): server-side actions — HTTP POST webhook, or a
 *     built-in (add tag / set status / assign / grant access).
 *   - local rules: a built-in "perform" action or a local CLI agent invocation.
 * Pure presentation; mutations flow through the callbacks (editor setField).
 */
export default function ActionStep({
  mode = 'local',
  actionKind, builtin, triageQuadrant, replyBody,
  agents, adapterId, task, effectiveMode, allowlistDisabled, timeoutS,
  onActionKind, onBuiltin, onTriageQuadrant, onReplyBody,
  onAdapterId, onTask, onPermissionMode, onTimeoutS,
  // MX action model
  mxActionType, webhookUrl, webhookSecret, tagName, statusValue, memberKey,
  tags = [], members = [],
  onMxActionType, onWebhookUrl, onWebhookSecret, onTagName, onStatusValue, onMemberKey,
}) {
  if (mode === 'mx') {
    const isMember = mxActionType === MX_ACTION_TYPES.ASSIGN || mxActionType === MX_ACTION_TYPES.GRANT_ACCESS;
    return (
      <>
        <p className={styles.intro}>When the conditions match, then:</p>

        <label className={styles.field}>
          <span className={styles.label}>Action</span>
          <MgmtSelect bare compact value={mxActionType} onChange={(e) => onMxActionType(e.target.value)}>
            <option value={MX_ACTION_TYPES.WEBHOOK}>HTTP POST to endpoint</option>
            <option value={MX_ACTION_TYPES.ADD_TAG}>Add tag</option>
            <option value={MX_ACTION_TYPES.SET_STATUS}>Set status</option>
            <option value={MX_ACTION_TYPES.ASSIGN}>Assign to member</option>
            <option value={MX_ACTION_TYPES.GRANT_ACCESS}>Grant access to member</option>
          </MgmtSelect>
        </label>

        {mxActionType === MX_ACTION_TYPES.WEBHOOK && (
          <>
            <label className={styles.field}>
              <span className={styles.label}>Endpoint URL</span>
              <input
                className={styles.input}
                type="url"
                value={webhookUrl}
                onChange={(e) => onWebhookUrl(e.target.value)}
                placeholder="https://example.com/hooks/inbox2"
              />
            </label>
            <label className={styles.field}>
              <span className={styles.label}>Signing secret (optional)</span>
              <input
                className={styles.input}
                type="text"
                value={webhookSecret}
                onChange={(e) => onWebhookSecret(e.target.value)}
                placeholder="Signs the X-Inbox2-Signature header"
              />
            </label>
            <p className={styles.modeDesc}>
              We POST a JSON <code>rule.matched</code> event to this URL. Sealed domains
              send only metadata, so content conditions won&apos;t match there.
            </p>
          </>
        )}

        {mxActionType === MX_ACTION_TYPES.ADD_TAG && (
          <label className={styles.field}>
            <span className={styles.label}>Tag</span>
            <MgmtSelect bare compact value={tagName} onChange={(e) => onTagName(e.target.value)}>
              <option value="">Choose a tag…</option>
              {tags.map((t) => (
                <option key={t.id || t.name} value={t.name}>{t.name}</option>
              ))}
            </MgmtSelect>
          </label>
        )}

        {mxActionType === MX_ACTION_TYPES.SET_STATUS && (
          <label className={styles.field}>
            <span className={styles.label}>Status</span>
            <MgmtSelect bare compact value={statusValue} onChange={(e) => onStatusValue(e.target.value)} options={MX_STATUS_OPTIONS} />
          </label>
        )}

        {isMember && (
          <label className={styles.field}>
            <span className={styles.label}>Member</span>
            <MgmtSelect bare compact value={memberKey} onChange={(e) => onMemberKey(e.target.value)}>
              <option value="">Choose a member…</option>
              {members.map((m) => (
                <option key={m.id} value={m.id}>{memberLabel(m)}</option>
              ))}
            </MgmtSelect>
          </label>
        )}
      </>
    );
  }

  return (
    <>
      <p className={styles.intro}>When the conditions match, then:</p>

      <div className={styles.modeCards}>
        <button
          type="button"
          className={`${styles.modeCard} ${actionKind === ACTION_KINDS.PERFORM ? styles.modeCardActive : ''}`}
          onClick={() => onActionKind(ACTION_KINDS.PERFORM)}
        >
          <span className={styles.modeCardTitle}>
            <Icon name="bolt.fill" size={13} /> Perform action
          </span>
          <span className={styles.modeCardDesc}>Run a built-in action.</span>
        </button>
        <button
          type="button"
          className={`${styles.modeCard} ${actionKind === ACTION_KINDS.AGENT ? styles.modeCardActive : ''}`}
          onClick={() => onActionKind(ACTION_KINDS.AGENT)}
        >
          <span className={styles.modeCardTitle}>
            <Icon name="wand.and.stars" size={13} /> Invoke agent
          </span>
          <span className={styles.modeCardDesc}>Run a local CLI agent on the email.</span>
        </button>
      </div>

      {actionKind === ACTION_KINDS.PERFORM ? (
        <>
          <div className={styles.actionGrid}>
            {BUILTIN_ACTIONS.map((a) => (
              <button
                key={a.value}
                type="button"
                className={`${styles.actionCard} ${builtin === a.value ? styles.actionCardActive : ''}`}
                onClick={() => onBuiltin(a.value)}
                title={a.desc}
              >
                <Icon name={a.icon} size={15} className={styles.actionIcon} />
                <span className={styles.actionLabel}>{a.label}</span>
              </button>
            ))}
          </div>

          {builtin === 'auto_triage' && (
            <label className={styles.field}>
              <span className={styles.label}>Set priority to</span>
              <MgmtSelect
                bare
                compact
                value={triageQuadrant}
                onChange={(e) => onTriageQuadrant(e.target.value)}
                options={TRIAGE_OPTIONS}
              />
            </label>
          )}

          {builtin === 'auto_reply' && (
            <label className={styles.field}>
              <span className={styles.label}>Reply with</span>
              <textarea
                className={styles.textarea}
                value={replyBody}
                onChange={(e) => onReplyBody(e.target.value)}
                rows={3}
                placeholder="Thanks, we got your message and will reply soon."
              />
            </label>
          )}
        </>
      ) : agents.length === 0 ? (
        <p className={styles.empty}>
          No agents turned on. Turn one on in Settings → On-device AI → Local agents.
        </p>
      ) : (
        <>
          <label className={styles.field}>
            <span className={styles.label}>Agent</span>
            <MgmtSelect
              bare
              compact
              value={adapterId}
              onChange={(e) => onAdapterId(e.target.value)}
            >
              {agents.map((a) => (
                <option key={a.adapter_id} value={a.adapter_id}>
                  {a.display_name}
                </option>
              ))}
            </MgmtSelect>
          </label>

          <label className={styles.field}>
            <span className={styles.label}>Task</span>
            <textarea
              className={styles.textarea}
              value={task}
              onChange={(e) => onTask(e.target.value)}
              rows={3}
              placeholder="Extract the invoice PDF, total, and due date, then POST them to my automation."
            />
          </label>

          <hr className={styles.divider} />

          <p className={styles.warn}>
            <Icon name="exclamationmark.triangle" size={13} /> The agent reads email you
            didn&apos;t write. Pick the least powerful mode that works.
          </p>

          <label className={styles.field}>
            <span className={styles.label}>Permission</span>
            <MgmtSelect
              bare
              compact
              value={effectiveMode}
              onChange={(e) => onPermissionMode(e.target.value)}
            >
              {PERMISSION_MODES.map((m) => (
                <option key={m.value} value={m.value} disabled={m.value === 'allowlist' && allowlistDisabled}>
                  {m.label}
                  {m.value === 'allowlist' && allowlistDisabled ? ' (this agent can’t)' : ''}
                </option>
              ))}
            </MgmtSelect>
          </label>
          <p className={styles.modeDesc}>
            {PERMISSION_MODES.find((m) => m.value === effectiveMode)?.desc}
          </p>

          <label className={styles.field}>
            <span className={styles.label}>Timeout (seconds)</span>
            <input
              className={styles.inputSmall}
              type="number"
              min={10}
              max={1800}
              value={timeoutS}
              onChange={(e) => onTimeoutS(e.target.value)}
            />
          </label>
        </>
      )}
    </>
  );
}
