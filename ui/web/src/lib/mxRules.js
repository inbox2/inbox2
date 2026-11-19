// MX (server-side) routing-rule backend for the create-rule wizard — the API
// counterpart to lib/localAgents.js (which drives local external-channel rules over
// Tauri). MX-hosted domain mail lives in the Rails API, so these rules are stored
// and evaluated server-side by RuleExecutor (docs/Routing.md, docs/Agentic-Filters.md).
//
// Scope: create-from-message (the message-launched modal). Listing/editing MX rules
// lives in Settings → Rules; this module only needs preview + create + backfill.
//
// Shape mapping: the wizard uses conditions `{ field, op, value }` and an action
// descriptor; the API wants `{ field, operator, value }` and `[{ type, value }]`.
import api from './api';

// Statuses a set_status action may target (mirrors Conversation::STATUSES on the
// API; static UI config, not live data).
export const MX_STATUS_OPTIONS = [
  { value: 'open', label: 'Open' },
  { value: 'pending', label: 'Pending' },
  { value: 'archived', label: 'Archived' },
  { value: 'spam', label: 'Spam' },
  { value: 'trash', label: 'Trash' },
];

// The action types an MX rule supports (matches Rule::ACTION_TYPES server-side).
export const MX_ACTION_TYPES = {
  WEBHOOK: 'webhook',
  ADD_TAG: 'add_tag',
  SET_STATUS: 'set_status',
  ASSIGN: 'assign',
  GRANT_ACCESS: 'grant_access',
};

function mapConditions(conditions) {
  return (conditions || []).map((c) => ({
    field: c.field,
    operator: c.op,
    value: c.value || '',
  }));
}

// Preview matches for an unsaved rule (review step). Returns { samples, total,
// scanned_capped } — same shape the local backend returns, so ReviewStep is shared.
export function previewMxRule(orgId, payload) {
  return api.post(`/orgs/${orgId}/rules/preview`, { conditions: mapConditions(payload.conditions) });
}

// Turn the wizard's action descriptor into the API's actions array. A webhook
// action first registers (or updates) the endpoint as a Webhook record, then
// references it by key — that's what RuleExecutor delivers to.
async function buildActions(orgId, action) {
  switch (action.type) {
    case MX_ACTION_TYPES.WEBHOOK: {
      const { webhook } = await api.post(`/orgs/${orgId}/webhooks`, {
        url: action.url,
        secret: action.secret || undefined,
        events: ['rule.matched'],
        enabled: true,
      });
      return [{ type: MX_ACTION_TYPES.WEBHOOK, value: webhook.id }];
    }
    case MX_ACTION_TYPES.ADD_TAG:
    case MX_ACTION_TYPES.SET_STATUS:
    case MX_ACTION_TYPES.ASSIGN:
    case MX_ACTION_TYPES.GRANT_ACCESS:
      return [{ type: action.type, value: action.value }];
    default:
      throw new Error(`Unsupported MX action: ${action.type}`);
  }
}

// Create (or update) the MX rule. Returns the rule key.
export async function upsertMxRule(orgId, payload) {
  const body = {
    name: payload.name,
    conditions: mapConditions(payload.conditions),
    actions: await buildActions(orgId, payload.action),
    enabled: payload.enabled !== false,
  };
  const res = payload.key
    ? await api.patch(`/orgs/${orgId}/rules/${payload.key}`, body)
    : await api.post(`/orgs/${orgId}/rules`, body);
  return res.rule.id;
}

// "Apply to existing emails" — enqueue the saved rule over already-received mail.
export function applyMxRuleToExisting(orgId, ruleKey) {
  return api.post(`/orgs/${orgId}/rules/${ruleKey}/apply-existing`, {});
}
