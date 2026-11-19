import { useState, useEffect, useMemo, useCallback } from 'react';
import { isTauri } from '../lib/tauri';
import { PROVIDER } from '../lib/providerTypes';
import { initialsDataUri } from '../lib/initialsIcon';
import useAccountOrder, { setAccountOrder } from '../lib/accountOrderPref';
import { scrubIfDemo } from '../lib/demoData';
import log from '../lib/log';
import useAccountStore from '../stores/accountStore';

/**
 * Shared account management hook.
 * Builds the unified account list (Rails orgs + external accounts),
 * and provides helpers for adding/reordering accounts.
 *
 * @param {Array} organizations — Rails orgs from useAuth()
 * @param {Object} [opts]
 * @param {Array}  [opts.externalAccounts] — pre-loaded external accounts
 *   (e.g. from useExternalAccountSync). If omitted, loads from Tauri automatically.
 * @param {Function} [opts.setExternalAccounts] — setter for externally-managed accounts
 *   (required when opts.externalAccounts is provided and reorderAccounts is used).
 */
export default function useAccounts(organizations, opts = {}) {
  const managed = opts.externalAccounts === undefined;
  // Start from the shared store (the screen before this one filled it): an empty
  // first render drops the channel tabs from the chrome until the load below
  // lands, so moving between screens made the tab strip shrink and grow back.
  const [ownAccounts, setOwnAccounts] = useState(() => useAccountStore.getState().externalAccounts);

  // Load external accounts only when not externally managed
  useEffect(() => {
    if (!managed || !isTauri()) return;
    let cancelled = false;
    (async () => {
      try {
        const { invoke } = await import('@tauri-apps/api/core');
        const accounts = scrubIfDemo(await invoke('list_external_accounts'));
        if (cancelled) return;
        setOwnAccounts(accounts);
        // Compose's From picker (useFromIdentities) reads the shared store, which
        // only InboxPage/CalendarPage fill — seed it so views without them (the
        // Unified inbox) can still reply from a Gmail/Microsoft address.
        useAccountStore.getState().setExternalAccounts(accounts);
      } catch (e) {
        log.warn('useAccounts', `Failed to list external accounts: ${e?.message || e}`);
      }
    })();
    return () => { cancelled = true; };
  }, [managed]);

  const externalAccounts = managed ? ownAccounts : opts.externalAccounts;

  // Unified list: one MX tab per DOMAIN (an org owns many equal domains), plus
  // external sync accounts. A domain tab is the org's MX inbox narrowed to that
  // domain (?domain=dom_…) — keyed by the Domain's public id. Orgs with no
  // domains array (legacy/single-domain) fall back to one tab keyed by slug.
  // Saved drag & drop order (full key list, MX + external interleaved). Applied
  // over the composed list so MX domain tabs aren't pinned before externals.
  const savedOrder = useAccountOrder();

  const allAccounts = useMemo(() => {
    const base = [
    ...(organizations || []).flatMap(org => {
      const slug = org.slug || org.id;
      const domains = (org.domains && org.domains.length)
        ? org.domains
        : [{ id: slug, name: org.domain || slug }];
      return domains.map(dom => {
        // Icon per tab: the domain's own uploaded icon wins; else the org's
        // custom icon on its primary domain; else a deterministic name-initials
        // icon so the tabs stay distinguishable.
        const isPrimary = dom.name && dom.name === org.domain;
        const iconUrl = dom.icon_url
          || (isPrimary && org.icon_url ? org.icon_url : initialsDataUri(dom.name || org.name || slug));
        return {
          key: dom.id,
          domainKey: dom.id,
          // Path slug for this domain tab (/:domainSlug/mail/inbox). Real domains
          // carry their own slug from the API; the single-domain/legacy fallback
          // has none (→ ChromeBar routes it to the org's unified inbox instead).
          domainSlug: dom.slug || null,
          orgSlug: slug,
          display_name: dom.name || org.name || slug,
          email_address: dom.name || org.domain || slug,
          provider_type: PROVIDER.INBOX2,
          icon_url: iconUrl,
          status: 'connected',
        };
      });
    }),
    ...externalAccounts,
    ];
    // No demo-mode branch here on purpose: both halves arrive already scrubbed
    // (orgs come from the API, external accounts from the load above), and
    // scrubbing twice would just pick a second stand-in for the same account.
    // The initials icon below is computed from whatever name survived, so a demo
    // tab draws its glyph from the fake one.
    const list = base;
    if (!savedOrder.length) return list;
    const idx = new Map(savedOrder.map((k, i) => [k, i]));
    // Stable sort: unsaved (new) keys keep their composition order at the end.
    return list.sort((a, b) => (idx.get(a.key) ?? Infinity) - (idx.get(b.key) ?? Infinity));
  }, [organizations, externalAccounts, savedOrder]);

  const addAccount = useCallback((account) => {
    setOwnAccounts(prev => [...prev, account]);
    useAccountStore.getState().setExternalAccounts(prev =>
      prev.some(a => a.key === account.key) ? prev : [...prev, account]);
  }, []);

  const setter = managed ? setOwnAccounts : opts.setExternalAccounts;

  const reorderAccounts = useCallback(async (orderedKeys) => {
    // The full interleaved order (MX + external) persists locally and drives
    // allAccounts; the engine additionally keeps the external subset's order.
    setAccountOrder(orderedKeys);
    const orgKeys = new Set((organizations || []).flatMap(o => {
      const slug = o.slug || o.id;
      return (o.domains && o.domains.length) ? o.domains.map(d => d.id) : [slug];
    }));
    const externalKeys = orderedKeys.filter(k => !orgKeys.has(k));

    setter?.(prev => {
      const byKey = new Map(prev.map(a => [a.key, a]));
      return externalKeys.map(k => byKey.get(k)).filter(Boolean);
    });

    if (isTauri()) {
      try {
        const { invoke } = await import('@tauri-apps/api/core');
        await invoke('reorder_external_accounts', { accountKeys: externalKeys });
      } catch (e) {
        log.warn('useAccounts', `Failed to persist reorder: ${e?.message || e}`);
      }
    }
  }, [organizations, setter]);

  return {
    externalAccounts,
    setExternalAccounts: setOwnAccounts,
    allAccounts,
    addAccount,
    reorderAccounts,
  };
}
