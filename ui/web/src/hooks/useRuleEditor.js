import { useState, useCallback, useMemo } from 'react';
import {
  buildRulePayload,
  agentAction,
  performAction,
  ACTION_KINDS,
  BUILTIN_ACTIONS,
  TRIAGE_OPTIONS,
} from '../lib/localAgents';
import { MX_ACTION_TYPES } from '../lib/mxRules';

const isBoolField = (f) => f === 'has_attachment';
const blankCondition = () => ({ field: 'from', op: 'contains', value: '' });

// The full editor draft. Every field startNew/startEdit used to set by hand now
// lives here; `setField` replaces the ~15 individual setters.
const DRAFT_INIT = {
  editingKey: null,        // null = creating
  editingEnabled: true,
  // The rule's channel scope. New rules are null (cross-channel-capable): they're
  // instead contained by a default `to` condition, which the user can remove to
  // go cross-channel. Preserved verbatim when editing a rule that carries one.
  ruleAccountKey: null,
  step: 1,
  name: '',
  conditions: [blankCondition()],
  actionKind: ACTION_KINDS.AGENT,
  builtin: BUILTIN_ACTIONS[0].value,
  triageQuadrant: TRIAGE_OPTIONS[0].value,
  replyBody: '',
  adapterId: '',
  task: '',
  permissionMode: 'approval_first',
  timeoutS: 120,
  // MX (server-side) rule action model — used only when mode === 'mx'. The action
  // set differs from local (webhook / built-ins vs agent / perform), so it carries
  // its own fields.
  mxActionType: MX_ACTION_TYPES.WEBHOOK,
  webhookUrl: '',
  webhookSecret: '',
  tagName: '',
  statusValue: 'open',
  memberKey: '',
  saving: false,
  error: '',
  // Step 3 (Review) — existing-mail preview + the apply-to-existing choice.
  applyExisting: false,
  preview: null,           // { samples, total, scanned_capped }
  previewLoading: false,
  previewError: '',
};

/**
 * Rule-editor draft state machine. Collapses the 26 useState setters that
 * RuleManager carried by hand into one `draft` object + `setField`, and folds the
 * duplicated startNew/startEdit init (each ~15 fields) into `loadRule`/`reset`.
 *
 * Behaviorally identical to the inline state: same defaults, same init order,
 * same validation gates and payload shape.
 *
 * Options:
 *   prefill — { from, to, hasAttachment } seeds for a new rule
 *   agents  — usable local agents (for the default adapter id + agent validation)
 *
 * Returns:
 *   draft       — the editor state object
 *   setField    — (name, value|updater) => void; updater receives the prev value
 *   loadRule    — (rule) => void; load the editor from an existing rule
 *   reset       — () => void; fresh "new rule" (prefilled from a message)
 *   buildPayload— (action) => payload for the current draft
 *   validateStep— (n) => bool; gate step n (sets draft.error on failure)
 *   buildConditions / buildAction — exposed so the view + save reuse one object
 *   effectiveMode / allowlistDisabled / selectedAgent — derived agent helpers
 */
export default function useRuleEditor({ mode = 'local', prefill = {}, agents = [] } = {}) {
  const [draft, setDraft] = useState(DRAFT_INIT);

  const setField = useCallback((name, value) => {
    setDraft((d) => ({
      ...d,
      [name]: typeof value === 'function' ? value(d[name]) : value,
    }));
  }, []);

  // Reset the editor to a fresh "new rule" (prefilled from a message when present).
  const reset = useCallback(() => {
    const fromEmail = prefill.from || '';
    const toEmail = prefill.to || '';
    const initial = [];
    // Default the channel address as the first, removable condition: keep it to
    // contain the rule to this channel; remove it to make the rule cross-channel.
    if (toEmail) initial.push({ field: 'to', op: 'contains', value: toEmail });
    if (fromEmail) initial.push({ field: 'from', op: 'contains', value: fromEmail });
    if (prefill.hasAttachment) initial.push({ field: 'has_attachment', op: 'is_true', value: '' });
    const defaultName = mode === 'mx'
      ? (fromEmail ? `Rule for ${fromEmail}` : 'New rule')
      : (fromEmail ? `Agent for ${fromEmail}` : 'New agent rule');
    setDraft((d) => ({
      ...DRAFT_INIT,
      // Contain new rules via a removable `to` condition, not a hidden scope.
      name: defaultName,
      conditions: initial.length ? initial : [blankCondition()],
      adapterId: d.adapterId || '',
    }));
  }, [mode, prefill.from, prefill.to, prefill.hasAttachment]);

  // Load the editor from an existing rule.
  const loadRule = useCallback((rule) => {
    const conds = (rule.conditions || []).map((c) => ({
      field: c.field,
      op: c.op,
      value: c.value || '',
    }));
    const perform = rule.action?.type === ACTION_KINDS.PERFORM;
    setDraft((d) => ({
      ...DRAFT_INIT,
      editingKey: rule.key,
      editingEnabled: rule.enabled !== false,
      ruleAccountKey: rule.account_key || null,
      name: rule.name || '',
      conditions: conds.length ? conds : [blankCondition()],
      actionKind: perform ? ACTION_KINDS.PERFORM : ACTION_KINDS.AGENT,
      builtin: perform ? rule.action.builtin || BUILTIN_ACTIONS[0].value : BUILTIN_ACTIONS[0].value,
      triageQuadrant: rule.action?.quadrant || TRIAGE_OPTIONS[0].value,
      replyBody: rule.action?.reply || '',
      adapterId: rule.action?.adapter_id || agents[0]?.adapter_id || d.adapterId || '',
      task: rule.action?.task || '',
      permissionMode: rule.action?.permission_mode || 'approval_first',
      timeoutS: rule.action?.timeout_s || 120,
    }));
  }, [agents]);

  const selectedAgent = useMemo(
    () => agents.find((a) => a.adapter_id === draft.adapterId),
    [agents, draft.adapterId],
  );
  const allowlistDisabled = selectedAgent ? !selectedAgent.supports_allowlist : false;
  // Derive (don't store) the effective mode so an agent that can't do allowlist
  // never runs with it selected — no corrective effect needed.
  const effectiveMode =
    allowlistDisabled && draft.permissionMode === 'allowlist' ? 'approval_first' : draft.permissionMode;

  // Normalize the editor rows into stored conditions, dropping text rows with no
  // value. Boolean (attachment) rows need no value.
  const buildConditions = useCallback(() =>
    draft.conditions
      .map((c) =>
        isBoolField(c.field)
          ? { field: c.field, op: c.op || 'is_true', value: '' }
          : { field: c.field, op: c.op || 'contains', value: (c.value || '').trim() },
      )
      .filter((c) => isBoolField(c.field) || c.value),
  [draft.conditions]);

  // Step 1 gate — returns false (and sets an error) when conditions are incomplete.
  const validateConditions = useCallback(() => {
    if (!draft.name.trim()) {
      setField('error', 'Give the rule a name.');
      return false;
    }
    if (buildConditions().length === 0) {
      setField('error', 'Add at least one condition.');
      return false;
    }
    return true;
  }, [draft.name, buildConditions, setField]);

  // Build the validated action object from the step-2 editor, or null (setting an
  // error) when incomplete. Shared by the review step and the final save.
  const buildAction = useCallback(() => {
    // MX rules have their own action set (webhook + built-in server actions).
    if (mode === 'mx') {
      const t = draft.mxActionType;
      if (t === MX_ACTION_TYPES.WEBHOOK) {
        const url = (draft.webhookUrl || '').trim();
        if (!/^https?:\/\/.+/i.test(url)) {
          setField('error', 'Enter a web address that starts with http.');
          return null;
        }
        return { type: t, url, secret: (draft.webhookSecret || '').trim() };
      }
      if (t === MX_ACTION_TYPES.ADD_TAG) {
        if (!draft.tagName) { setField('error', 'Choose a tag to add.'); return null; }
        return { type: t, value: draft.tagName };
      }
      if (t === MX_ACTION_TYPES.SET_STATUS) {
        return { type: t, value: draft.statusValue || 'open' };
      }
      if (t === MX_ACTION_TYPES.ASSIGN || t === MX_ACTION_TYPES.GRANT_ACCESS) {
        if (!draft.memberKey) { setField('error', 'Choose a member.'); return null; }
        return { type: t, value: draft.memberKey };
      }
      return null;
    }
    if (draft.actionKind === ACTION_KINDS.AGENT) {
      if (!draft.adapterId) {
        setField('error', 'Choose an agent to run.');
        return null;
      }
      if (!draft.task.trim()) {
        setField('error', 'Describe the task for the agent.');
        return null;
      }
      return agentAction({
        adapterId: draft.adapterId,
        task: draft.task.trim(),
        permissionMode: effectiveMode,
        timeoutS: Number(draft.timeoutS) || 120,
      });
    }
    if (draft.builtin === 'auto_triage') return performAction(draft.builtin, { quadrant: draft.triageQuadrant });
    if (draft.builtin === 'auto_reply') {
      if (!draft.replyBody.trim()) {
        setField('error', 'Write the reply to send.');
        return null;
      }
      return performAction(draft.builtin, { reply: draft.replyBody.trim() });
    }
    return performAction(draft.builtin);
  }, [mode, draft.mxActionType, draft.webhookUrl, draft.webhookSecret, draft.tagName, draft.statusValue, draft.memberKey,
      draft.actionKind, draft.adapterId, draft.task, draft.builtin, draft.triageQuadrant, draft.replyBody, draft.timeoutS, effectiveMode, setField]);

  // validateStep(n) — gate step n. Step 1 checks conditions; step 2 checks the
  // action object can be built.
  const validateStep = useCallback((n) => {
    if (n === 1) return validateConditions();
    if (n === 2) return buildAction() != null;
    return true;
  }, [validateConditions, buildAction]);

  // Assemble the full rule payload for the current draft. `action` is passed in so
  // callers reuse a single validated action object.
  const buildPayload = useCallback((action) => {
    // MX rules are mapped to the API shape by lib/mxRules — hand it the raw draft
    // (no account scoping; the local Rust payload builder doesn't apply).
    if (mode === 'mx') {
      return {
        key: draft.editingKey || undefined,
        name: draft.name.trim(),
        conditions: buildConditions(),
        action,
        enabled: draft.editingEnabled,
      };
    }
    return buildRulePayload({
      key: draft.editingKey || undefined,
      name: draft.name.trim(),
      accountKey: draft.ruleAccountKey,
      conditions: buildConditions(),
      action,
      enabled: draft.editingEnabled,
    });
  },
  [mode, draft.editingKey, draft.name, draft.ruleAccountKey, draft.editingEnabled, buildConditions]);

  return {
    draft,
    setField,
    loadRule,
    reset,
    buildPayload,
    validateStep,
    buildConditions,
    buildAction,
    validateConditions,
    selectedAgent,
    allowlistDisabled,
    effectiveMode,
  };
}
