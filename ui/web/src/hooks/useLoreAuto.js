import { useCallback, useEffect, useState } from 'react';
import api from '../lib/api';
import log from '../lib/log';
import { isTauri } from '../lib/tauri';
import useAuth from './useAuth';

/*
 * "Handled for you" auto mode (docs/Triage.md "Auto mode"): per Handled group,
 * whether Lore files new mail away by itself instead of suggesting it. Off by
 * default (decided 2026-10-20). One setting, stored twice because the two sync
 * modes act separately: the engine for local channels (desktop), the account for
 * MX — which only ever auto-acts in a domain with a single member.
 *
 *   useLoreAuto() → { auto: { fyi, receipt, notification }, setAuto(label, on), saving }
 */
const OFF = { fyi: false, receipt: false, notification: false };

export default function useLoreAuto() {
  const { user } = useAuth();
  const [auto, setState] = useState(OFF);
  const [saving, setSaving] = useState(false);

  useEffect(() => {
    let live = true;
    (async () => {
      try {
        const remote = user ? (await api.get('/account/lore-auto')).lore_auto : null;
        const local = isTauri() ? await (await import('@tauri-apps/api/core')).invoke('get_lore_auto') : null;
        // Either store saying "on" means the person turned it on (they're written together).
        const merged = Object.fromEntries(Object.keys(OFF).map((k) => [k, !!(remote?.[k] || local?.[k])]));
        if (live) setState(merged);
      } catch (e) {
        log.warn('LoreAuto', `load failed: ${e?.message || e}`);
      }
    })();
    return () => { live = false; };
  }, [user]);

  const setAuto = useCallback(async (label, on) => {
    const next = { ...auto, [label]: on };
    setState(next);
    setSaving(true);
    try {
      await Promise.all([
        user ? api.put('/account/lore-auto', { lore_auto: next }) : null,
        isTauri() ? import('@tauri-apps/api/core').then(({ invoke }) => invoke('set_lore_auto', { settings: next })) : null,
      ]);
    } catch (e) {
      log.warn('LoreAuto', `save failed: ${e?.message || e}`);
      setState(auto);
    } finally {
      setSaving(false);
    }
  }, [auto, user]);

  return { auto, setAuto, saving };
}
