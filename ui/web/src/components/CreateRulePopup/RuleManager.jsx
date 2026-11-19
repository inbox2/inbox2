import { useState, useEffect, useCallback, useMemo } from 'react';
import Icon from '../Icon';
import Button from '../Button/Button';
import { ACTION_KINDS } from '../../lib/localAgents';
import { getRuleBackend } from '../../lib/ruleBackend';
import api from '../../lib/api';
import useRuleEditor from '../../hooks/useRuleEditor';
import RulesList from './RulesList';
import ConditionsStep from './ConditionsStep';
import ActionStep from './ActionStep';
import ReviewStep from './ReviewStep';
import styles from './CreateRulePopup.module.css';

const STEPS = ['Conditions', 'Action', 'Review'];

const isBoolField = (f) => f === 'has_attachment';
const blankCondition = () => ({ field: 'from', op: 'contains', value: '' });

/**
 * Rule manager — the 3-step editor (conditions → action → review), usable inline
 * (Settings) or inside CreateRulePopup's Modal (launched from a message).
 *
 * Two backends, resolved from `mx` (see lib/ruleBackend.js):
 *   - MX context (`mx = { orgId }`, an inbox2-hosted conversation): server-side
 *     Rule/RuleExecutor over the Rails API. Create-only from a message; the rules
 *     list lives in Settings → Rules. Actions: webhook / tag / status / assign /
 *     grant.
 *   - local (default): external-channel rules over Tauri; agent / built-in actions.
 *
 * Props:
 *   embedded — render inline (Settings): land on the rules list, Cancel → list.
 *   onClose  — dismiss (modal only)
 *   prefill  — { from, to, subject, hasAttachment } seeds for a new rule
 *   onSaved  — called with the rule key after each successful save
 *   mx       — { orgId } to target MX server-side rules; omit for local rules
 */
export default function RuleManager({ embedded = false, onClose, prefill = {}, onSaved, mx }) {
  const orgId = mx?.orgId || null;
  const backend = useMemo(() => getRuleBackend(orgId ? { orgId } : null), [orgId]);
  const mxMode = backend.mode === 'mx';

  const [view, setView] = useState(embedded ? 'list' : 'form'); // 'list' | 'form'
  const [rules, setRules] = useState([]);
  const [agents, setAgents] = useState([]);
  const [tags, setTags] = useState([]);       // MX: org tags for the add_tag action
  const [members, setMembers] = useState([]); // MX: org members for assign/grant
  const [busyKey, setBusyKey] = useState(''); // rule key mid toggle/delete
  const [confirmDelete, setConfirmDelete] = useState(null); // rule pending deletion

  // Editor state — the 26 hand-rolled useState/init collapsed into one hook.
  const {
    draft, setField, loadRule, reset, buildPayload, validateStep,
    buildAction, validateConditions,
    allowlistDisabled, effectiveMode,
  } = useRuleEditor({ mode: backend.mode, prefill, agents });

  const {
    editingKey, editingEnabled, step, name, conditions,
    actionKind, builtin, triageQuadrant, replyBody,
    adapterId, task, timeoutS, saving, error,
    mxActionType, webhookUrl, webhookSecret, tagName, statusValue, memberKey,
    applyExisting, preview, previewLoading, previewError,
  } = draft;

  const loadRules = useCallback(async () => {
    const list = await backend.list();
    setRules(list || []);
  }, [backend]);

  // Reset the editor to a fresh "new rule" and land on the form.
  const startNew = useCallback(() => {
    reset();
    setView('form');
  }, [reset]);

  // Load the editor from an existing rule and land on the form.
  const startEdit = (rule) => {
    loadRule(rule);
    setView('form');
  };

  // Initialize once on mount. The modal remounts on each open (Modal unmounts its
  // children when closed), so this also resets it per open.
  /* eslint-disable react-hooks/set-state-in-effect, react-hooks/exhaustive-deps -- intentional one-time init */
  useEffect(() => {
    setField('error', '');
    loadRules();
    backend.detectAgents().then((list) => {
      const usable = (list || []).filter((a) => a.installed && a.enabled);
      setAgents(usable);
      setField('adapterId', (a) => a || usable[0]?.adapter_id || '');
    });
    if (embedded) setView('list');
    else startNew();
  }, []);
  /* eslint-enable react-hooks/set-state-in-effect, react-hooks/exhaustive-deps */

  // MX action pickers need the org's tags + members (add_tag / assign / grant).
  useEffect(() => {
    if (!mxMode || !orgId) return undefined;
    let cancelled = false;
    Promise.all([
      api.getTags(orgId).catch(() => ({ tags: [] })),
      api.getMembers(orgId).catch(() => ({ members: [] })),
    ]).then(([t, m]) => {
      if (cancelled) return;
      setTags(t.tags || []);
      setMembers(m.members || []);
    });
    return () => { cancelled = true; };
  }, [mxMode, orgId]);

  const backToList = () => {
    setField('error', '');
    loadRules();
    setView('list');
  };

  // Leave the editor: embedded returns to the rules list; the modal dismisses
  // (its list lives only in Settings).
  const exitForm = () => {
    if (embedded) backToList();
    else onClose?.();
  };

  // Top-left chevron: step back one level (later steps keep the draft; step 1 → out
  // of the editor).
  const handleTitleBack = () => {
    if (step > 1) {
      setField('error', '');
      setField('step', step - 1);
    } else {
      exitForm();
    }
  };

  // Condition-row mutators — operate on draft.conditions via setField.
  const updateCondition = (i, patch) =>
    setField('conditions', (cs) => cs.map((c, idx) => (idx === i ? { ...c, ...patch } : c)));
  const changeField = (i, field) =>
    updateCondition(i, { field, op: isBoolField(field) ? 'is_true' : 'contains', value: '' });
  const addCondition = () => setField('conditions', (cs) => [...cs, blankCondition()]);
  const removeCondition = (i) => setField('conditions', (cs) => cs.filter((_, idx) => idx !== i));

  const handleNext = () => {
    if (!validateStep(1)) return;
    setField('error', '');
    setField('step', 2);
  };

  // Fetch the existing-mail preview for the review step. Conditions drive the
  // match, but we send the real (built) rule so the backend scope matches the save.
  const loadPreview = async (action) => {
    setField('previewLoading', true);
    setField('preview', null);
    setField('previewError', '');
    try {
      setField('preview', await backend.preview(buildPayload(action)));
    } catch (e) {
      setField('previewError', String(e));
    } finally {
      setField('previewLoading', false);
    }
  };

  // Step 2 → 3: validate conditions + action, then advance and load the preview.
  const handleActionNext = () => {
    if (!validateConditions()) return setField('step', 1);
    const action = buildAction();
    if (!action) return;
    setField('error', '');
    setField('step', 3);
    loadPreview(action);
  };

  // MX rules always persist (no ephemeral run-once). For local rules, editing
  // always persists; a *new* rule persists only when "Apply to new emails" is on —
  // otherwise it's a one-time "run once" over existing mail.
  const willPersist = mxMode || !!editingKey || editingEnabled;
  const hasBackfill = applyExisting && preview?.total > 0;

  const handleSave = async () => {
    if (!validateConditions()) return setField('step', 1);
    const action = buildAction();
    if (!action) return setField('step', 2);
    if (!willPersist && !applyExisting) {
      return setField(
        'error',
        'Turn on “Apply to new emails” to save the rule, or “Apply to existing emails” to run it once.',
      );
    }

    setField('saving', true);
    setField('error', '');
    try {
      if (willPersist) {
        const key = await backend.upsert(buildPayload(action));
        // Backfill: run the saved rule over matching existing mail.
        if (hasBackfill) await backend.applyToExisting(key);
        onSaved?.(key);
      } else {
        // One-time run: apply to existing mail without saving the rule (local only).
        if (hasBackfill) await backend.runOnce(buildPayload(action));
        onSaved?.();
      }
      exitForm();
    } catch (e) {
      setField('error', String(e));
    } finally {
      setField('saving', false);
    }
  };

  // Enter in the form advances the current step (Next / Next / Create), mirroring
  // the primary button. The primary button is type="submit" and carries the same
  // disabled rules, so implicit submission is blocked exactly when the button is.
  const handlePrimary = () => {
    if (saving) return;
    if (step === 1) handleNext();
    else if (step === 2) handleActionNext();
    else handleSave();
  };

  const handleToggle = async (rule) => {
    setBusyKey(rule.key);
    try {
      await backend.upsert({ ...rule, enabled: rule.enabled === false });
      await loadRules();
      onSaved?.(rule.key);
    } catch (e) {
      setField('error', String(e));
    } finally {
      setBusyKey('');
    }
  };

  const handleDelete = async (rule) => {
    setBusyKey(rule.key);
    try {
      await backend.remove(rule.key);
      await loadRules();
      onSaved?.(rule.key);
    } catch (e) {
      setField('error', String(e));
    } finally {
      setBusyKey('');
      setConfirmDelete(null);
    }
  };

  if (view === 'list') {
    return (
      <RulesList
        rules={rules}
        busyKey={busyKey}
        error={error}
        confirmDelete={confirmDelete}
        onToggle={handleToggle}
        onEdit={startEdit}
        onConfirmDelete={setConfirmDelete}
        onDelete={handleDelete}
        onCancelDelete={() => setConfirmDelete(null)}
        onAddRule={startNew}
      />
    );
  }

  return (
    <form
      onSubmit={(e) => {
        e.preventDefault();
        handlePrimary();
      }}
    >
      <div className={styles.title}>
        <button type="button" className={styles.backBtn} onClick={handleTitleBack} aria-label="Back">
          <Icon name="chevron.left" size={15} />
        </button>
        {editingKey ? 'Edit rule' : 'New rule'}
      </div>

      <div className={styles.stepper}>
        {STEPS.map((label, i) => {
          const n = i + 1;
          const state = n === step ? styles.stepActive : n < step ? styles.stepDone : '';
          return (
            <div key={label} className={`${styles.step} ${state}`}>
              <span className={styles.stepNum}>
                {n < step ? <Icon name="checkmark" size={10} /> : n}
              </span>
              <span className={styles.stepText}>{label}</span>
            </div>
          );
        })}
      </div>

      {step === 1 ? (
        <ConditionsStep
          name={name}
          conditions={conditions}
          onName={(v) => setField('name', v)}
          onChangeField={changeField}
          onUpdateCondition={updateCondition}
          onAddCondition={addCondition}
          onRemoveCondition={removeCondition}
        />
      ) : step === 2 ? (
        <ActionStep
          mode={backend.mode}
          actionKind={actionKind}
          builtin={builtin}
          triageQuadrant={triageQuadrant}
          replyBody={replyBody}
          agents={agents}
          adapterId={adapterId}
          task={task}
          effectiveMode={effectiveMode}
          allowlistDisabled={allowlistDisabled}
          timeoutS={timeoutS}
          onActionKind={(v) => setField('actionKind', v)}
          onBuiltin={(v) => setField('builtin', v)}
          onTriageQuadrant={(v) => setField('triageQuadrant', v)}
          onReplyBody={(v) => setField('replyBody', v)}
          onAdapterId={(v) => setField('adapterId', v)}
          onTask={(v) => setField('task', v)}
          onPermissionMode={(v) => setField('permissionMode', v)}
          onTimeoutS={(v) => setField('timeoutS', v)}
          mxActionType={mxActionType}
          webhookUrl={webhookUrl}
          webhookSecret={webhookSecret}
          tagName={tagName}
          statusValue={statusValue}
          memberKey={memberKey}
          tags={tags}
          members={members}
          onMxActionType={(v) => setField('mxActionType', v)}
          onWebhookUrl={(v) => setField('webhookUrl', v)}
          onWebhookSecret={(v) => setField('webhookSecret', v)}
          onTagName={(v) => setField('tagName', v)}
          onStatusValue={(v) => setField('statusValue', v)}
          onMemberKey={(v) => setField('memberKey', v)}
        />
      ) : (
        <ReviewStep
          previewLoading={previewLoading}
          previewError={previewError}
          preview={preview}
          editingEnabled={editingEnabled}
          applyExisting={applyExisting}
          onEditingEnabled={(v) => setField('editingEnabled', v)}
          onApplyExisting={(v) => setField('applyExisting', v)}
        />
      )}

      {error && <p className={styles.error}>{error}</p>}

      <div className={styles.actions}>
        {step === 1 ? (
          <>
            <Button type="button" variant="secondary" onClick={exitForm} disabled={saving}>
              Cancel
            </Button>
            <Button type="submit">Next</Button>
          </>
        ) : step === 2 ? (
          <>
            <Button type="button" variant="secondary" onClick={() => setField('step', 1)} disabled={saving}>
              Back
            </Button>
            <Button type="submit" disabled={!mxMode && actionKind === ACTION_KINDS.AGENT && agents.length === 0}>
              Next
            </Button>
          </>
        ) : (
          <>
            <Button type="button" variant="secondary" onClick={() => setField('step', 2)} disabled={saving}>
              Back
            </Button>
            <Button type="submit" disabled={saving || (!willPersist && !applyExisting)}>
              {saving
                ? !willPersist
                  ? 'Running…'
                  : hasBackfill
                    ? 'Applying…'
                    : 'Saving…'
                : !willPersist
                  ? 'Run once'
                  : editingKey
                    ? 'Save rule'
                    : 'Create rule'}
            </Button>
          </>
        )}
      </div>
    </form>
  );
}
