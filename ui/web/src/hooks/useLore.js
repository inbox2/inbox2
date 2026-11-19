import { useCallback, useEffect, useMemo, useRef, useState } from 'react';
import api from '../lib/api';
import log from '../lib/log';
import { isRealOrgId } from '../lib/org';
import { isTauri } from '../lib/tauri';
import { LORE_SENT_CHANGED } from '../lib/mcpClient';
import { getDb } from '../lib/db';
import syncManager from '../lib/sync-manager';
import { CONV_STATUS } from '../lib/conversationStatus';
import { BOARD_METRIC, localWhere } from '../lib/spaceBoard';
import {
  CONV_ACTION, REVERSE_VERB, REMOVAL_ACTIONS, REMOVAL_PAST_TENSE, ACTION_ICON, commitAction, unreadDelta,
} from '../lib/conversationActions';
import { LORE_LABELS, toItem, waItem, waTodoItem, WA_SOURCE, WA_DONE_TRACKED, buildToday, entitiesFrom, isMemberDone } from '../lib/lore';
import { getLocalWhatsAppEnabled, waLoreSetDone, waGroupTodoSetDone } from '../lib/localWhatsApp';
import useUndoStore from '../stores/undoStore';
import useUnreadStore from '../stores/unreadStore';
import { loadTriageLabels, LOCAL_TRIAGE_LABELS } from './useTriageLabels';
import useAuth from './useAuth';
import { isDemoMode } from '../lib/demoData';

/*
 * Lore's data (lib/lore.js has the rules): every thread with a Lore label, from
 * every MX org the person belongs to (API) and every local channel (SQLite,
 * desktop). A Lore item IS a thread, so ticking it off archives the email — except
 * a personal bucket on a shared domain, which is hidden for this member only.
 *
 *   useLore({ scope, dispatch })
 *     scope    LORE_SCOPE.OPEN — what is still on your plate (default)
 *              LORE_SCOPE.DONE — recently archived Lore threads (History)
 *     dispatch optional (item, action) → null | Promise<bool>: a host that owns
 *              the same thread (the unified inbox) acts on it itself, with its
 *              own undo, and resolves whether it landed; null lets Lore do it.
 *   → { items, today, entities, loading, error, complete, completeMany, restore, refresh }
 *     error — the last reload's failure, if any source failed (it then shows its last good data)
 *
 * Reloads every minute while visible, on focus, on the engine's triage/sync
 * events, and shortly after any undoable action anywhere in the app (archiving
 * from the inbox must take the item off Lore too).
 */
export const LORE_SCOPE = { OPEN: 'open', DONE: 'done' };

const MX_PAGE = 100;
// Open work is paged until exhausted; this is only a runaway guard (5,000 threads per org).
const MX_MAX_PAGES = 50;
const DONE_LIMIT = 100;
const REFRESH_MS = 60 * 1000;
const SETTLE_MS = 1500;
const LOCAL_EVENTS = ['triage-updated', 'sync'];
// Read state has an undo too, like every other conversation action.
const OPPOSITE_MARK = { [CONV_ACTION.MARK_READ]: CONV_ACTION.MARK_UNREAD, [CONV_ACTION.MARK_UNREAD]: CONV_ACTION.MARK_READ };
const MARK_PAST_TENSE = { [CONV_ACTION.MARK_READ]: 'Marked as read', [CONV_ACTION.MARK_UNREAD]: 'Marked as unread' };

const LOCAL_COLUMNS = `c.key, c.subject, c.from_address, c.snippet, c.ai_summary_short, c.read,
  c.updated_at, c.status, c.triage_label, c.triage_priority, c.organization_id AS account_key,
  (SELECT ea.provider_type FROM external_accounts ea WHERE ea.key = c.organization_id) AS provider_type`;
// Added with the next-action extractor; a store opened by an older engine lacks them.
const NEXT_ACTION_COLUMNS = ', c.next_action_due_on, c.next_action_amount_cents, c.next_action_currency';
// The AI-written to-do title (summary pass).
const TITLE_COLUMN = ', c.next_action_title';
// An optimistic removal the reloads still disagree with after this long was refused: show it again.
const HIDE_MAX_MS = 20 * 1000;

async function fetchMx(org, scope) {
  const custom = (await loadTriageLabels(org.id)).filter((l) => !l.builtin);
  const params = {
    status: scope === LORE_SCOPE.DONE ? CONV_STATUS.ARCHIVED : CONV_STATUS.OPEN,
    triage_label: [...LORE_LABELS, ...custom.map((l) => l.slug)],
    per_page: scope === LORE_SCOPE.DONE ? DONE_LIMIT : MX_PAGE,
  };
  // Today leaves out what this member ticked off; History adds it back in.
  if (scope === LORE_SCOPE.OPEN) params.lore_done = false;
  const rows = [];
  for (let page = 1; page <= (scope === LORE_SCOPE.DONE ? 1 : MX_MAX_PAGES); page += 1) {
    const data = await api.getConversations(org.id, { ...params, page });
    const list = data.conversations || [];
    rows.push(...list);
    if (list.length < params.per_page) break;
  }
  if (scope === LORE_SCOPE.DONE) {
    const data = await api.getConversations(org.id, { per_page: DONE_LIMIT, lore_done: true });
    const have = new Set(rows.map((r) => r.id));
    rows.push(...(data.conversations || []).filter((r) => !have.has(r.id)));
  }
  return rows.map((r) => toItem(r, { source: 'mx', orgId: org.id, labels: custom })).filter(Boolean);
}

async function fetchLocal(scope) {
  const db = await getDb();
  if (!db) return [];
  const where = scope === LORE_SCOPE.DONE
    ? `c.status = '${CONV_STATUS.ARCHIVED}'`
    : localWhere(BOARD_METRIC.OPEN);
  const query = (cols) => db.select(
    `SELECT ${cols} FROM conversations c
     WHERE c.triage_label IS NOT NULL AND ${where}
     ORDER BY c.updated_at DESC${scope === LORE_SCOPE.DONE ? ` LIMIT ${DONE_LIMIT}` : ''}`,
  );
  // Newest columns first; a store from an older engine falls back a tier at a time.
  const tiers = [LOCAL_COLUMNS + NEXT_ACTION_COLUMNS + TITLE_COLUMN, LOCAL_COLUMNS + NEXT_ACTION_COLUMNS, LOCAL_COLUMNS];
  let rows;
  for (const [n, cols] of tiers.entries()) {
    try {
      rows = await query(cols);
      break;
    } catch (e) {
      if (n === tiers.length - 1 || !/no such column/i.test(String(e?.message || e))) throw e;
    }
  }
  const labels = await loadTriageLabels(LOCAL_TRIAGE_LABELS);
  return rows.map((r) => toItem(r, { source: 'local', labels })).filter(Boolean);
}

// Local WhatsApp asks (wa_lore, written by the desktop's WhatsApp Lore worker).
// Off → none, even if rows remain from when it was on.
async function fetchWhatsApp(scope) {
  if (!getLocalWhatsAppEnabled()) return [];
  // Demo mode: the fictional chats' asks (the real wa_lore rows hold real chat text).
  if (isDemoMode()) {
    const { demoWaLoreRows } = await import('../lib/demoWhatsApp');
    return demoWaLoreRows(scope === LORE_SCOPE.DONE ? 'done' : 'open').map((r) => waItem(r)).filter(Boolean);
  }
  const db = await getDb();
  if (!db) return [];
  let rows;
  try {
    rows = await db.select(
      // An ask a tracked group's list took over isn't work you did: kept out of History.
      // An ignored group (wa_groups.ignored) is kept out of Lore entirely.
      `SELECT * FROM wa_lore WHERE status = ?1 AND coalesce(done_reason, '') <> ?2
        AND chat_id NOT IN (SELECT chat_id FROM wa_groups WHERE ignored = 1)
        ORDER BY ask_at DESC${scope === LORE_SCOPE.DONE ? ` LIMIT ${DONE_LIMIT}` : ''}`,
      [scope === LORE_SCOPE.DONE ? 'done' : 'open', WA_DONE_TRACKED],
    );
  } catch (e) {
    // A store from before the table existed: nothing to show yet.
    if (/no such table/i.test(String(e?.message || e))) return [];
    throw e;
  }
  // Tracked groups' to-dos (everyone's); a group switched off keeps its rows but
  // shows none. A store from before the tables: none.
  let todos = [];
  try {
    todos = await db.select(
      `SELECT t.*, g.chat_name, g.avatar FROM wa_group_todos t JOIN wa_groups g ON g.chat_id = t.chat_id
        WHERE t.status = ?1 AND g.business = 1 AND g.ignored = 0 ORDER BY ${scope === LORE_SCOPE.DONE ? 'coalesce(t.done_at, t.at)' : 't.at'} DESC${scope === LORE_SCOPE.DONE ? ` LIMIT ${DONE_LIMIT}` : ''}`,
      [scope === LORE_SCOPE.DONE ? 'done' : 'open'],
    );
  } catch (e) {
    if (!/no such table/i.test(String(e?.message || e))) throw e;
  }
  const labels = await loadTriageLabels(LOCAL_TRIAGE_LABELS);
  return [...rows.map((r) => waItem(r, { labels })), ...todos.map(waTodoItem)].filter(Boolean);
}

// The provider half of an action on one item. Restores reach MX as 'open'.
// Demo mode (product videos): nothing leaves the machine — every action
// "lands" on screen only, and the optimistic state is kept for the session.
async function run(item, action) {
  if (isDemoMode()) return true;
  // WhatsApp's database is read-only: ticking marks the item done here, a
  // restore reopens it, read state has nothing to change.
  if (item.source === WA_SOURCE) {
    if (action === CONV_ACTION.MARK_READ || action === CONV_ACTION.MARK_UNREAD) return true;
    try {
      const done = !Object.values(REVERSE_VERB).includes(action);
      await (item.todoId ? waGroupTodoSetDone(item.todoId, done) : waLoreSetDone(item.chatId, done));
      return true;
    } catch (e) {
      log.warn('Lore', `WhatsApp ${action} failed for ${item.id}: ${e?.message || e}`);
      return false;
    }
  }
  if (item.source === 'local') {
    if (!isTauri()) return false;
    try {
      const { performAction } = await import('../lib/providers/index.js');
      await performAction(item.accountKey, [item.id], action);
      return true;
    } catch (e) {
      log.warn('Lore', `${action} failed for ${item.id}: ${e?.message || e}`);
      return false;
    }
  }
  const verb = action !== CONV_ACTION.LORE_UNDONE && Object.values(REVERSE_VERB).includes(action) ? CONV_STATUS.OPEN : action;
  return commitAction(verb, () => api.bulkConversations(item.orgId, [item.id], verb));
}

export default function useLore({ scope = LORE_SCOPE.OPEN, dispatch } = {}) {
  const { organizations } = useAuth();
  const [loaded, setLoaded] = useState({ items: [], loading: true, error: null });
  // Last good result per source (org id / 'local'), so one failing source keeps
  // showing what it had; and a counter so a slower, older reload can't land last.
  const lastGood = useRef(new Map());
  const seq = useRef(0);
  // Optimistically removed (ticked off / restored): uid → when, until a reload agrees.
  const [hidden, setHidden] = useState(() => new Map());
  // Read state changed here since the last reload: uid → unread (the row's dot follows at once).
  const [readNow, setReadNow] = useState(() => new Map());
  const orgSig = (organizations || []).map((o) => o.id).filter(isRealOrgId).join(',');
  // MX tab badges are keyed by domain id; an MX item knows its mail domain's name.
  const domainKeys = useRef(new Map());
  useEffect(() => {
    domainKeys.current = new Map((organizations || []).flatMap((o) => (o.domains || []).map((d) => [d.name, d.id])));
  }, [organizations]);
  const dispatchRef = useRef(dispatch);
  useEffect(() => { dispatchRef.current = dispatch; }, [dispatch]);

  const load = useCallback(async () => {
    const mine = ++seq.current;
    const orgs = orgSig ? orgSig.split(',').map((id) => ({ id })) : [];
    const sources = [
      ...orgs.map((o) => [o.id, () => fetchMx(o, scope)]),
      ...(isTauri() ? [['local', () => fetchLocal(scope)], [WA_SOURCE, () => fetchWhatsApp(scope)]] : []),
    ];
    let error = null;
    const fresh = new Map();
    const parts = await Promise.all(sources.map(async ([key, fetch]) => {
      try {
        const got = await fetch();
        fresh.set(key, got);
        return got;
      } catch (e) {
        log.warn('Lore', `${key}: ${e?.message || e}`);
        error = e;
        return lastGood.current.get(key) || [];
      }
    }));
    if (mine !== seq.current) return; // a newer reload started meanwhile: drop this one whole
    for (const [key, got] of fresh) lastGood.current.set(key, got);
    const items = parts.flat();
    setLoaded({ items, loading: false, error });
    if (!isDemoMode()) setReadNow((m) => (m.size ? new Map() : m)); // the reload carries the truth (demo: nothing was written)
    // A reload without the item settles its removal; one that still has it long
    // after the action means the action failed (inbox dispatcher included) — unhide.
    const present = new Set(items.map((i) => i.uid));
    const now = Date.now();
    setHidden((h) => (h.size
      ? new Map([...h].filter(([uid, at]) => present.has(uid) && (isDemoMode() || now - at < HIDE_MAX_MS)))
      : h));
  }, [orgSig, scope]);

  // A different org list or scope is a different question: forget the old answers.
  useEffect(() => { lastGood.current = new Map(); }, [orgSig, scope]);

  useEffect(() => { load(); }, [load]);

  useEffect(() => {
    let timer = null;
    const soon = () => {
      if (timer) return; // throttle, don't reset: a backfill emits an event per thread
      timer = setTimeout(() => { timer = null; load(); }, SETTLE_MS);
    };
    const tick = setInterval(() => { if (document.visibilityState === 'visible') load(); }, REFRESH_MS);
    window.addEventListener('focus', soon);
    const offs = isTauri() ? LOCAL_EVENTS.map((ev) => syncManager.on(ev, soon)) : [];
    // Any undoable action anywhere (inbox archive, undo itself) may move a Lore thread.
    const unsub = useUndoStore.subscribe((s, prev) => {
      if (s.undoStack !== prev.undoStack || s.redoStack !== prev.redoStack) soon();
      // An undo (the inbox's included) puts a thread back: drop its optimistic hide
      // now rather than at the stale timeout. A batch undo names no single key.
      const undone = s.redoStack.length > prev.redoStack.length ? s.redoStack[s.redoStack.length - 1] : null;
      if (undone) {
        setHidden((h) => (undone.batch
          ? new Map()
          : new Map([...h].filter(([uid]) => !uid.endsWith(`:${undone.key}`)))));
      }
    });
    return () => {
      clearTimeout(timer);
      clearInterval(tick);
      window.removeEventListener('focus', soon);
      offs.forEach((off) => off());
      unsub();
    };
  }, [load]);

  const hide = useCallback((uid, on) => setHidden((h) => {
    const next = new Map(h);
    if (on) next.set(uid, Date.now()); else next.delete(uid);
    return next;
  }), []);

  // Act on one item: optimistic hide, the provider call, an undo entry. A host
  // that holds the thread (the unified inbox) runs it with its own undo instead.
  const act = useCallback(async (item, requested, { batch = null, reverse: reversed = null } = {}) => {
    // A personal bucket on a shared domain: a tick is this member's, whatever the verb was.
    const action = isMemberDone(item) && REMOVAL_ACTIONS.includes(requested) ? CONV_ACTION.LORE_DONE : requested;
    const reverse = reversed || REVERSE_VERB[action] || OPPOSITE_MARK[action];
    const memberDone = action === CONV_ACTION.LORE_DONE || action === CONV_ACTION.LORE_UNDONE;
    // Whether a verb takes the item off THIS view: a removal leaves Today, a
    // restore leaves History; mark read/unread leaves it where it is.
    const restores = (verb) => Object.values(REVERSE_VERB).includes(verb);
    const leaves = (verb) => (scope === LORE_SCOPE.DONE
      ? restores(verb)
      : REMOVAL_ACTIONS.includes(verb) || verb === CONV_ACTION.LORE_DONE);
    if (leaves(action)) hide(item.uid, true);
    // The inbox keeps showing a member-done thread, so it has nothing to do here.
    const hosted = memberDone ? null : dispatchRef.current?.(item, action, { batch });
    if (hosted) {
      const ok = await hosted;
      if (!ok) hide(item.uid, false);
      return !!ok;
    }
    // Where the thread is right now, for the badge: an archived (History) one
    // isn't in the inbox the badge counts. Each step moves it in or out.
    let inInbox = item.status !== CONV_STATUS.ARCHIVED;
    let unreadNow = item.unread; // read state as the steps change it, for the badge
    // One step (forward, undo or redo) with its badge move; refused → nothing moves.
    const step = async (verb) => {
      if (!await run(item, verb)) return false;
      const delta = unreadDelta(verb, unreadNow, inInbox);
      if (verb === CONV_ACTION.MARK_READ) unreadNow = false;
      else if (verb === CONV_ACTION.MARK_UNREAD) unreadNow = true;
      if (restores(verb)) inInbox = true;
      else if (REMOVAL_ACTIONS.includes(verb)) inInbox = false;
      const badge = item.accountKey || domainKeys.current.get(item.mailDomain);
      if (delta && badge) useUnreadStore.getState().adjust(badge, delta);
      if (leaves(verb)) hide(item.uid, true);
      else if (leaves(action) || leaves(reverse)) hide(item.uid, false);
      if (verb === CONV_ACTION.MARK_READ || verb === CONV_ACTION.MARK_UNREAD) {
        setReadNow((m) => new Map(m).set(item.uid, verb === CONV_ACTION.MARK_UNREAD));
      }
      return true;
    };
    if (!await step(action)) {
      hide(item.uid, false);
      return false;
    }
    if (!reverse) return true;
    const past = REMOVAL_PAST_TENSE[action] || MARK_PAST_TENSE[action] || 'Moved back';
    useUndoStore.getState().record({
      batch,
      description: `${past} "${item.subject}"`,
      batchDescription: (n) => `${past} ${n} conversations`,
      variant: action === CONV_ACTION.TRASH ? 'danger' : 'triage',
      icon: ACTION_ICON[action] || 'tray.and.arrow.down',
      key: item.id,
      undo: () => step(reverse),
      redo: () => step(action),
    });
    return true;
  }, [hide, scope]);

  /** Tick an item off: archive (or `action`) the thread behind it. Resolves whether it landed. */
  const complete = useCallback((item, action = CONV_ACTION.ARCHIVE) => act(item, action), [act]);

  /** One action over several items — one undo toast for the lot. */
  const completeMany = useCallback((items, action = CONV_ACTION.ARCHIVE) => {
    const batch = Symbol('lore');
    items.forEach((i) => act(i, action, { batch }));
  }, [act]);

  /** History: put an archived thread back in the inbox (and on the Lore list). */
  const restore = useCallback((item) => (item.loreDone
    ? act(item, CONV_ACTION.LORE_UNDONE, { reverse: CONV_ACTION.LORE_DONE })
    : act(item, CONV_ACTION.UNARCHIVE, { reverse: CONV_ACTION.ARCHIVE })), [act]);

  // What "Send to…" made for each item, newest first: the chip on its row. Desktop only.
  const [sent, setSent] = useState(() => new Map());
  useEffect(() => {
    if (!isTauri()) return undefined;
    const read = () => import('../lib/mcpClient').then((m) => m.listLoreSent())
      .then((rows) => setSent(new Map([...rows].reverse().map((r) => [r.item_key, r]))))
      .catch((e) => log.warn('Lore', `sent references: ${e?.message || e}`));
    read();
    document.addEventListener(LORE_SENT_CHANGED, read);
    return () => document.removeEventListener(LORE_SENT_CHANGED, read);
  }, []);

  const items = useMemo(() => {
    const shown = hidden.size ? loaded.items.filter((i) => !hidden.has(i.uid)) : loaded.items;
    const withRead = readNow.size ? shown.map((i) => (readNow.has(i.uid) ? { ...i, unread: readNow.get(i.uid) } : i)) : shown;
    return sent.size ? withRead.map((i) => (sent.has(i.uid) ? { ...i, sent: sent.get(i.uid) } : i)) : withRead;
  }, [loaded.items, hidden, readNow, sent]);
  const today = useMemo(() => buildToday(items), [items]);
  const entities = useMemo(() => entitiesFrom(items), [items]);

  return { items, today, entities, loading: loaded.loading, error: loaded.error, complete, completeMany, restore, refresh: load };
}
