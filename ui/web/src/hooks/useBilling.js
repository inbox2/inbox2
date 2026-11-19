import { useState, useEffect, useCallback } from 'react';
import api from '../lib/api';
import log from '../lib/log';

/* Org-scoped billing + plan state for the MX console.
 *
 * Mirrors the useAdminData pattern: owns the async fetch, exposes the raw state
 * plus a couple of derived labels, and returns imperative actions. Pulled out of
 * AdminSyncs verbatim — behavior is unchanged.
 *
 * Args:
 *   orgId     — the org whose subscription drives the console (primary org).
 *   domainsCount — fallback count for `domainsUsed` until billing loads.
 *   onChanged — optional callback fired after a successful subscribe (so the
 *               caller can re-fetch domains → locked badges refresh).
 *
 * Returns billing/plans/planBusy/downgrade state, refreshBilling + subscribe +
 * setDowngrade actions, and the derived plan/quota fields the console renders. */
export default function useBilling(orgId, domainsCount = 0, onChanged) {
  const [billing, setBilling] = useState(null);
  const [plans, setPlans] = useState([]);
  const [planBusy, setPlanBusy] = useState(null); // plan id being changed
  // Pending downgrade awaiting acknowledgement: { plan, impact } (set when the API
  // replies 422 with the lock impact). null when no confirm is open.
  const [downgrade, setDowngrade] = useState(null);

  const refreshBilling = useCallback(() => {
    if (!orgId) return Promise.resolve();
    return api.getBilling(orgId).then(setBilling).catch(() => { /* offline / not signed in */ });
  }, [orgId]);

  useEffect(() => { refreshBilling(); }, [refreshBilling]);

  useEffect(() => {
    api.getPlans().then((d) => setPlans(d.plans || [])).catch(() => { /* offline */ });
  }, []);

  // Apply a plan change. Without `acknowledge`, a downgrade that exceeds the new
  // limits returns 422 + impact → open the gated confirm modal. With `acknowledge`
  // the (mocked) Stripe checkout runs and the plan flips + over-limit resources lock.
  const subscribe = useCallback(async (plan, { acknowledge } = {}) => {
    if (!orgId) return;
    setPlanBusy(plan.id);
    try {
      await api.subscribe(orgId, plan.id, { acknowledge });
      setDowngrade(null);
      await refreshBilling();
      await onChanged?.(); // refresh domains so locked badges appear
    } catch (e) {
      if (e?.status === 422 && e?.data?.code === 'downgrade_requires_acknowledgement') {
        setDowngrade({ plan, impact: e.data.impact });
      } else {
        log.warn('Admin', `Subscribe failed: ${e?.message || e}`);
      }
    } finally { setPlanBusy(null); }
  }, [orgId, refreshBilling, onChanged]);

  // ── Derived plan / quota fields ─────────────────────────────────────────────
  const domainLimit = billing?.plan?.max_domains ?? null;
  const unlimitedDomains = billing?.plan?.unlimited_domains ?? false;
  const domainsUsed = billing?.domains_used ?? domainsCount;
  const atDomainLimit = billing?.domain_limit_reached ?? false;

  // Effective current plan for the billing cards. With no org yet (signed up but
  // no domain added → no subscription), default to Free so it shows as selected
  // instead of every card reading "Downgrade".
  const currentPlan = billing?.plan || plans.find((p) => p.price_cents === 0) || null;

  // Usage caption beside the "Your domains" title: "2 / 3 used" on a capped plan,
  // "2 used" when unlimited.
  const domainUsageText = domainLimit == null
    ? null
    : unlimitedDomains
      ? `${domainsUsed} used`
      : `${domainsUsed} / ${domainLimit} used`;

  // "available" for the Add-domain card: a number on a capped plan, "unlimited"
  // when the plan is uncapped, or null until billing loads.
  const domainsAvailable = unlimitedDomains
    ? 'unlimited'
    : (domainLimit != null ? Math.max(0, domainLimit - domainsUsed) : null);

  return {
    billing,
    plans,
    planBusy,
    downgrade,
    setDowngrade,
    refreshBilling,
    subscribe,
    // derived
    domainLimit,
    unlimitedDomains,
    domainsUsed,
    atDomainLimit,
    currentPlan,
    domainUsageText,
    domainsAvailable,
  };
}
