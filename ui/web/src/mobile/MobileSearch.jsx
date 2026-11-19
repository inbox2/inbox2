import { useCallback, useEffect, useMemo, useRef, useState } from 'react';
import { createPortal } from 'react-dom';
import { useMobileLayout, MOBILE_LAYOUT } from '../hooks/useIsPhone';
import { useNavigate, useSearchParams } from 'react-router';
import useAuth from '../hooks/useAuth';
import useDebounce from '../hooks/useDebounce';
import useSelectedConversationDetail from '../hooks/useSelectedConversationDetail';
import useConversationActions from '../hooks/useConversationActions';
import useMarkRead from '../hooks/useMarkRead';
import api from '../lib/localFirstApi';
import log from '../lib/log';
import { parse, isBare, toApiParams } from '../lib/searchQuery';
import { normalize } from '../hooks/useUnifiedInbox';
import { CONV_ACTION } from '../lib/conversationActions';
import Icon from '../components/Icon';
import Spinner from '../components/Spinner';
import MobileShell from './MobileShell';
import { MOBILE_TAB, useMobileOrg } from './mobileContext';
import MobileRow from './MobileRow';
import MobileThread from './MobileThread';
import styles from './MobileSearch.module.css';

/* Phone search: one field, results as inbox rows across every org the user
 * belongs to (the same api.search the desktop results view runs, operators and
 * all — from:, has:attachment, in:anywhere…). The query rides ?q= and the open
 * result ?c=, so back closes the thread and then clears nothing it shouldn't. */
const NO_ROWS = [];

export default function MobileSearch() {
  const { organizations, user } = useAuth();
  const { org } = useMobileOrg();
  const navigate = useNavigate();
  const [searchParams, setSearchParams] = useSearchParams();
  const q = searchParams.get('q') || '';
  const selectedId = searchParams.get('c');
  const [draft, setDraft] = useState(q);
  const query = useDebounce(draft, 300);
  // A ?q= change from outside (Back, a deep link) resets the field to it.
  const [seenQ, setSeenQ] = useState(q);
  if (q !== seenQ) { setSeenQ(q); setDraft(q); }
  // Hits are stored with the query that produced them, so a new query never
  // shows the previous one's rows while it loads.
  const [hits, setHits] = useState({ q: null, rows: [], failed: false });
  const [retryNonce, setRetryNonce] = useState(0);
  const results = hits.q === q ? hits.rows : NO_ROWS;
  const loading = !!q && hits.q !== q;
  const setResults = useCallback((update) => setHits((h) => ({ ...h, rows: typeof update === 'function' ? update(h.rows) : update })), []);
  const [selectedConv, setSelectedConv] = useState(null);
  const [enrichingKeys, setEnrichingKeys] = useState(() => new Set());
  const inputRef = useRef(null);
  const seq = useRef(0);

  // Typing replaces ?q= (one history entry per search, not per keystroke).
  useEffect(() => {
    // Only once typing has settled on what's in the field — not the lagging
    // debounce of a value the URL has since replaced.
    if (query === q || query !== draft) return;
    const next = new URLSearchParams(searchParams);
    if (query) next.set('q', query); else next.delete('q');
    next.delete('c');
    setSearchParams(next, { replace: true });
  }, [query, draft]); // eslint-disable-line react-hooks/exhaustive-deps -- only the settled text drives the URL

  useEffect(() => {
    const filter = parse(q);
    const text = filter.text.trim();
    const run = ++seq.current;
    // Cleared: forget the last hits, so typing the same query again searches anew.
    if (!text && isBare(filter)) { setHits({ q: null, rows: [] }); return; } // eslint-disable-line react-hooks/set-state-in-effect -- reset on an external (URL) change
    Promise.all((organizations || []).map((o) => api.search(o.id || o.slug, text, toApiParams(filter))
      .then((data) => (data.conversations || []).map((c) => normalize(c, o.slug || o.id, 'inbox2', o.slug || o.id)))
      .catch((e) => { log.warn('Search', `search failed for ${o.slug}: ${e?.message || e}`); return null; })))
      .then((lists) => {
        if (run !== seq.current) return;
        // Every org failed = the search failed, not "nothing found".
        const failed = lists.length > 0 && lists.every((l) => l === null);
        const rows = lists.filter(Boolean).flat().sort((a, b) => (b.updated_at || '').localeCompare(a.updated_at || ''));
        setHits({ q, rows, failed });
      });
  }, [q, organizations, retryNonce]);

  useSelectedConversationDetail({ selectedId, conversations: results, setSelectedConv, setEnrichingKeys, logTag: 'MobileSearch' });

  // Results grouped by the org they came from: each group runs its own action
  // hook, so an archive goes to that org's API (a user can be in several).
  const groups = useMemo(() => {
    const byOrg = new Map();
    for (const c of results) {
      const key = c.orgKey || c.accountKey;
      if (!byOrg.has(key)) byOrg.set(key, []);
      byOrg.get(key).push(c);
    }
    return [...byOrg.entries()];
  }, [results]);

  // As in the inbox: back pops the entry opening pushed; a deep-linked ?c= is
  // just dropped.
  // Tablet: results | conversation side by side, so opening swaps in place.
  const tablet = useMobileLayout() === MOBILE_LAYOUT.TABLET;
  const [detailEl, setDetailEl] = useState(null);
  const pushedThread = useRef(false);
  const open = useCallback((conv) => {
    const next = new URLSearchParams(searchParams);
    next.set('c', conv.id);
    if (tablet) { setSearchParams(next, { replace: true }); return; }
    pushedThread.current = true;
    setSearchParams(next);
  }, [searchParams, setSearchParams, tablet]);
  useEffect(() => { if (!selectedId) pushedThread.current = false; }, [selectedId]);
  // A ?c= that isn't among this query's hits (stale or hand-made link) has no
  // row to load from — drop it rather than spin on the loading screen.
  const hitsReady = !q || (!loading && hits.q === q);
  useEffect(() => {
    if (!selectedId || !hitsReady || results.some((c) => c.id === selectedId)) return;
    const next = new URLSearchParams(searchParams);
    next.delete('c');
    setSearchParams(next, { replace: true });
  }, [selectedId, hitsReady, results, searchParams, setSearchParams]);
  const close = useCallback(() => {
    if (pushedThread.current) { pushedThread.current = false; navigate(-1); return; }
    const next = new URLSearchParams(searchParams);
    next.delete('c');
    setSearchParams(next, { replace: true });
  }, [navigate, searchParams, setSearchParams]);

  const defaultFrom = user?.email || `${user?.username || 'me'}@${org?.domain || 'example.com'}`;

  return (
    <MobileShell tab={MOBILE_TAB.SEARCH} hideNav={!!selectedId} composeFrom={defaultFrom}>
      <div className={styles.columns}>
      <div className={styles.listCol}>
      <form className={styles.bar} role="search" onSubmit={(e) => { e.preventDefault(); inputRef.current?.blur(); }}>
        <span className={styles.field}>
          <Icon name="magnifyingglass" size={15} />
          <input
            ref={inputRef}
            className={styles.input}
            type="search"
            enterKeyHint="search"
            value={draft}
            onChange={(e) => setDraft(e.target.value)}
            placeholder="Search mail"
            aria-label="Search mail"
            autoFocus={!q}
          />
          {draft && (
            <button type="button" className={styles.clear} onClick={() => { setDraft(''); inputRef.current?.focus(); }} aria-label="Clear search">
              <Icon name="xmark" size={10} />
            </button>
          )}
        </span>
      </form>

      <div className={styles.list}>
        {!q ? (
          <div className={styles.state}>
            <p className={styles.hint}>Search every domain you&apos;re in.</p>
            <p className={styles.hintSub}>Try <code>from:anna</code>, <code>has:attachment</code> or <code>in:anywhere</code>.</p>
          </div>
        ) : loading && results.length === 0 ? (
          <div className={styles.state}><Spinner size={18} /></div>
        ) : hits.q === q && hits.failed ? (
          <div className={styles.state}>
            <p className={styles.hint}>Couldn&apos;t search right now.</p>
            <button type="button" className={styles.retry} onClick={() => { setHits((h) => ({ ...h, q: null })); setRetryNonce((n) => n + 1); }}>Try again</button>
          </div>
        ) : results.length === 0 ? (
          <div className={styles.state}><p className={styles.hint}>No results for “{q}”</p></div>
        ) : (
          groups.map(([orgKey, rows]) => (
            <OrgResults
              key={orgKey}
              orgKey={orgKey}
              rows={rows}
              setResults={setResults}
              selectedId={selectedId}
              selectedConv={selectedConv}
              setSelectedConv={setSelectedConv}
              enrichingKeys={enrichingKeys}
              // Replies go out from this result's own org, not the current one.
              defaultFrom={user?.email || `${user?.username || 'me'}@${(organizations || []).find((o) => (o.slug || o.id) === orgKey)?.domain || org?.domain || 'example.com'}`}
              onOpen={open}
              onClose={close}
              detailEl={tablet ? detailEl : null}
            />
          ))
        )}
      </div>
      </div>
      {/* Tablet: the open result renders here (portaled from its org section). */}
      {tablet && (
        <div className={styles.detailCol} ref={setDetailEl}>
          {!(selectedId && selectedConv?.id === selectedId) && (
            <div className={styles.detailState}>
              {selectedId ? <Spinner size={18} /> : <p className={styles.hint}>Pick a result to read it.</p>}
            </div>
          )}
        </div>
      )}
      </div>

      {!tablet && selectedId && selectedConv?.id !== selectedId && (
        <div className={styles.threadLoading}><Spinner size={18} /></div>
      )}
    </MobileShell>
  );
}

// The open thread goes into the tablet's detail column when there is one.
const wrapDetail = (el, node) => (el ? createPortal(node, el) : node);

// One org's hits, plus the open thread when it is one of them.
function OrgResults({ orgKey, rows, setResults, selectedId, selectedConv, setSelectedConv, enrichingKeys, defaultFrom, onOpen, onClose, detailEl }) {
  const { executeAction, executePriority } = useConversationActions({
    activeAccountKey: null, orgId: orgKey, conversations: rows, displayedConversations: rows,
    selectedId, setConversations: setResults, setSelectedConv,
    badgeKey: orgKey, inInboxView: false, followSelection: false,
  });
  const threadHere = selectedConv && selectedConv.id === selectedId && rows.some((c) => c.id === selectedId);
  // Opening a hit reads it per the user's mark-as-read setting, as in the inbox.
  const markRead = useCallback((id) => executeAction([id], CONV_ACTION.MARK_READ, { record: false }), [executeAction]);
  useMarkRead({ conv: threadHere ? { id: selectedConv.id, read: selectedConv.read } : null, markRead });

  return (
    <>
      {rows.map((conv) => (
        <MobileRow
          key={conv.id}
          conv={conv}
          onOpen={onOpen}
          onToggleRead={() => executeAction([conv.id], conv.read ? CONV_ACTION.MARK_UNREAD : CONV_ACTION.MARK_READ)}
          onArchive={() => executeAction([conv.id], CONV_ACTION.ARCHIVE)}
          onTrash={() => executeAction([conv.id], CONV_ACTION.TRASH)}
        />
      ))}
      {threadHere && wrapDetail(detailEl,
        <MobileThread
          embedded={!!detailEl}
          conversation={selectedConv}
          orgId={orgKey}
          defaultFrom={defaultFrom}
          enrichingKeys={enrichingKeys}
          onBack={onClose}
          onAction={(action) => {
            executeAction([selectedConv.id], action);
            if (action !== CONV_ACTION.MARK_READ && action !== CONV_ACTION.MARK_UNREAD) onClose();
          }}
          executePriority={executePriority}
        />,
      )}
    </>
  );
}
