import { useCallback, useEffect, useState } from 'react';
import { getDb } from '../lib/db';
import log from '../lib/log';
import { getLocalWhatsAppEnabled } from '../lib/localWhatsApp';
import { isDemoMode } from '../lib/demoData';
import { isTauri } from '../lib/tauri';
import syncManager from '../lib/sync-manager';

/**
 * The WhatsApp groups Lore tracks (`wa_groups.business`, whatsapp_groups.rs),
 * whether or not anything is open in them, plus the ones the person switched
 * off or ignored (so their page, and its switch, stay reachable) — the Lore sidebar lists
 * these. Reloads when the worker reports a change (`triage-updated`).
 *   → { groups: [{ chatId, name, tracked, ignored }], reload }
 */
export default function useWaTrackedGroups() {
  const [groups, setGroups] = useState([]);
  const reload = useCallback(async () => {
    if (!getLocalWhatsAppEnabled() || isDemoMode()) { setGroups([]); return; }
    try {
      const db = await getDb();
      const rows = db ? await db.select("SELECT chat_id, chat_name, business, ignored FROM wa_groups WHERE business = 1 OR source = 'user' OR ignored = 1 ORDER BY ignored, business DESC, chat_name") : [];
      setGroups(rows.map((r) => ({ chatId: r.chat_id, name: r.chat_name, tracked: !!r.business && !r.ignored, ignored: !!r.ignored })));
    } catch (e) {
      // A store from before the table: no tracked groups yet.
      if (!/no such table/i.test(String(e?.message || e))) log.warn('useWaTrackedGroups', e?.message || e);
      setGroups([]);
    }
  }, []);
  useEffect(() => {
    // eslint-disable-next-line react-hooks/set-state-in-effect -- loads from SQLite on mount
    reload();
    // The worker judges new groups as they change: list them as they land.
    const off = isTauri() ? syncManager.on('triage-updated', reload) : null;
    return () => off?.();
  }, [reload]);
  return { groups, reload };
}
