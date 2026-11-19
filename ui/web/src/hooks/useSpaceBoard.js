import { useState, useEffect, useMemo } from 'react';
import api from '../lib/api';
import { isRealOrgId } from '../lib/org';
import { isTauri } from '../lib/tauri';
import { getDb } from '../lib/db';
import syncManager from '../lib/sync-manager';
import log from '../lib/log';
import useTriageLabels, { LOCAL_TRIAGE_LABELS } from './useTriageLabels';
import { BOARD_VIEW, ROW_CAP, mxQuery, localWhere, personalCells, buildBoard } from '../lib/spaceBoard';

/* The Spaces board's data (lib/spaceBoard.js has the view/merge rules).
 *
 *   useSpaceBoard({ orgId, spaces, view, metric, enabled })
 *     → { cells, rowsBySlug, hasLocal }
 *
 * MX: every Space's threads for the metric, paged up to ROW_CAP (Mine adds
 * assignee=me). Local (desktop, Mine only): one SQLite pass over the viewer's
 * connected-account threads with a space_slug, reloaded on the engine's
 * space-updated / triage-updated events, throttled to one reload per second (a
 * backfill emits one event per thread; a trailing debounce would never fire
 * while it runs). Personal Spaces come from the core's get_personal_spaces. */

const PER_PAGE = 100; // the conversations index's max_per_page
const REFRESH_THROTTLE_MS = 1000;
const LOCAL_EVENTS = ['space-updated', 'triage-updated'];

async function fetchMxSpace(orgId, key, params) {
  const rows = [];
  let total = 0;
  for (let page = 1; rows.length < ROW_CAP; page += 1) {
    const data = await api.getConversations(orgId, { ...params, space: key, per_page: PER_PAGE, page });
    const list = data.conversations || [];
    rows.push(...list);
    total = data.meta?.total ?? rows.length;
    if (list.length < PER_PAGE || rows.length >= total) break;
  }
  return { total, rows: rows.slice(0, ROW_CAP) };
}

export default function useSpaceBoard({ orgId, spaces, view, metric, enabled }) {
  const mine = view === BOARD_VIEW.MINE;
  const desktopMine = enabled && mine && isTauri();
  // Results are stamped with the query they answer, so a view/metric switch
  // never shows the previous query's rows while the new one loads.
  const [mx, setMx] = useState({ q: null, data: {} });
  const [local, setLocal] = useState({ q: null, data: {} });
  const [personal, setPersonal] = useState([]);

  // Stable dependency: the set of real Space keys, not the array identity.
  const sig = (spaces || []).filter((s) => s.key).map((s) => `${s.id}:${s.key}`).join(',');
  const mxQ = `${orgId}|${sig}|${view}|${metric}`;
  const localQ = metric;

  useEffect(() => {
    if (!enabled || !isRealOrgId(orgId) || !sig) return undefined;
    let cancelled = false;
    const params = { ...mxQuery(metric), ...(mine ? { assignee: 'me' } : {}) };
    Promise.all(sig.split(',').map(async (pair) => {
      const [id, key] = pair.split(':');
      try {
        return [id, await fetchMxSpace(orgId, key, params)];
      } catch (e) {
        log.warn('useSpaceBoard', `space ${key}: ${e?.message || e}`);
        return [id, { total: 0, rows: [] }];
      }
    })).then((entries) => { if (!cancelled) setMx({ q: mxQ, data: Object.fromEntries(entries) }); });
    return () => { cancelled = true; };
  }, [enabled, orgId, sig, mine, metric, mxQ]);

  useEffect(() => {
    if (!desktopMine) return undefined;
    let cancelled = false;
    let timer = null;
    const load = async () => {
      const db = await getDb();
      if (!db || cancelled) return;
      try {
        const rows = await db.select(
          `SELECT * FROM (
             SELECT c.space_slug AS slug, c.key, c.subject, c.from_address, c.snippet, c.ai_summary_short,
                    c.read, c.updated_at, c.triage_label, c.triage_priority,
                    c.organization_id AS account_key, ea.provider_type,
                    ROW_NUMBER() OVER (PARTITION BY c.space_slug
                      ORDER BY COALESCE(c.triage_priority, -1) DESC, c.updated_at DESC) AS rn,
                    COUNT(*) OVER (PARTITION BY c.space_slug) AS total
             FROM conversations c
             LEFT JOIN external_accounts ea ON ea.key = c.organization_id
             WHERE c.space_slug IS NOT NULL AND c.space_slug != 'spam'
               AND ${localWhere(metric)}
           ) WHERE rn <= ${ROW_CAP}`,
        );
        const map = {};
        for (const r of rows) {
          (map[r.slug] ||= { total: r.total || 0, rows: [] }).rows.push(r);
        }
        if (!cancelled) setLocal({ q: localQ, data: map });
      } catch (e) {
        log.warn('useSpaceBoard', `local query failed: ${e?.message || e}`);
      }
    };
    load();
    const reload = () => {
      if (timer) return; // a reload is already scheduled — throttle, don't reset
      timer = setTimeout(() => { timer = null; load(); }, REFRESH_THROTTLE_MS);
    };
    const offs = LOCAL_EVENTS.map((ev) => syncManager.on(ev, reload));
    return () => { cancelled = true; clearTimeout(timer); offs.forEach((off) => off()); };
  }, [desktopMine, metric, localQ]);

  useEffect(() => {
    if (!desktopMine) return undefined;
    let cancelled = false;
    import('@tauri-apps/api/core')
      .then(({ invoke }) => invoke('get_personal_spaces'))
      .then((list) => { if (!cancelled) setPersonal(Array.isArray(list) ? list : []); })
      .catch((e) => {
        // Older core without personal Spaces: the board just has none.
        log.warn('useSpaceBoard', `get_personal_spaces failed: ${e?.message || e}`);
        if (!cancelled) setPersonal([]);
      });
    return () => { cancelled = true; };
  }, [desktopMine]);

  // Custom label names: the engine's list for local rows, the org's for MX rows.
  const { labels: localLabels } = useTriageLabels(desktopMine ? LOCAL_TRIAGE_LABELS : null);
  const { labels: orgLabels } = useTriageLabels(enabled && isRealOrgId(orgId) ? orgId : null);

  const mxData = enabled && mx.q === mxQ ? mx.data : null;
  const localData = desktopMine && local.q === localQ ? local.data : null;

  return useMemo(() => {
    const orgSpaces = spaces || [];
    const board = buildBoard({
      view,
      metric,
      spaces: orgSpaces,
      personal: desktopMine ? personalCells(personal, orgSpaces) : [],
      mx: mxData || {},
      local: localData || {},
      labels: { local: localLabels, org: orgLabels },
    });
    return { ...board, hasLocal: !!localData && Object.keys(localData).length > 0 };
  }, [spaces, view, metric, desktopMine, personal, mxData, localData, localLabels, orgLabels]);
}
