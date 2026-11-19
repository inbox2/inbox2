// Resolves which rule backend the create-rule wizard talks to:
//   - MX context (an inbox2-hosted org/domain conversation) → the Rails API
//     (server-side Rule/RuleExecutor). See lib/mxRules.js.
//   - otherwise → local external-channel rules over Tauri. See lib/localAgents.js.
//
// Both expose the same method surface so RuleManager is backend-agnostic. The MX
// backend is create-only (list/edit live in Settings → Rules), so its list/remove
// are inert.
import {
  detectLocalAgents,
  listLocalRules,
  upsertLocalRule,
  deleteLocalRule,
  previewRuleMatches,
  applyRuleToExisting,
  runRuleOnce,
} from './localAgents';
import { previewMxRule, upsertMxRule, applyMxRuleToExisting } from './mxRules';

// mx: { orgId } when launched from MX-hosted mail, else null/undefined.
export function getRuleBackend(mx) {
  if (mx?.orgId) {
    const { orgId } = mx;
    return {
      mode: 'mx',
      detectAgents: async () => [],
      list: async () => [],
      preview: (payload) => previewMxRule(orgId, payload),
      upsert: (payload) => upsertMxRule(orgId, payload),
      applyToExisting: (key) => applyMxRuleToExisting(orgId, key),
      // MX has no ephemeral "run once without saving" — the wizard always persists.
      runOnce: async () => { throw new Error('run-once is not supported for MX rules'); },
      remove: async () => {},
    };
  }
  return {
    mode: 'local',
    detectAgents: detectLocalAgents,
    list: listLocalRules,
    preview: previewRuleMatches,
    upsert: upsertLocalRule,
    applyToExisting: applyRuleToExisting,
    runOnce: runRuleOnce,
    remove: deleteLocalRule,
  };
}
