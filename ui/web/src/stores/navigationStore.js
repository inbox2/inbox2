import { create } from 'zustand';
import { ACTIVE_ACCOUNT_KEY, ACTIVE_CONVERSATION_KEY } from '../lib/storageKeys';
import { isRealOrgId } from '../lib/org';

// The live router URL (path + query), used to skip driving navigate() when the
// target already matches what's in the address bar.
const locationUrl = () => window.location.pathname + window.location.search;

// Mirror the open conversation to storage so a desktop refresh (reloads to '/',
// rebuilds the route from storage) can reopen it — see routes.jsx RootRedirect.
const persistConversation = (id) => {
  if (id) localStorage.setItem(ACTIVE_CONVERSATION_KEY, id);
  else localStorage.removeItem(ACTIVE_CONVERSATION_KEY);
};

/**
 * NavigationManager — singleton store that owns all app navigation state.
 * Components subscribe via Zustand selectors; changing state drives URL routing.
 *
 * State: accountKey, viewName, conversationId, orgSlug
 * History: stack of entries for browser-style back/forward
 * Router bridge: stores navigate() ref, builds URLs, calls navigate() itself
 */
const useNavigationStore = create((set, get) => ({
  // ── Current view state ──
  orgSlug: null,
  accountKey: null,
  viewName: null,
  conversationId: null,
  // Which top-level page we're on: 'mail' | 'explorer' | 'calendar' | 'settings'.
  // The store used to model only mail, so the Explorer (and calendar/settings)
  // were invisible to the back/forward stack — pressing Back from a drill-down
  // skipped Explorer entirely and buildUrl could only ever produce /mail URLs.
  // Tracking the page makes every top-level view a first-class history entry.
  page: 'mail',
  // True on the cross-channel unified inbox (/:orgSlug/mail). False on the org's
  // single-channel view (/:orgSlug/mail/inbox) — both have accountKey=null, so this
  // is what keeps them as distinct history entries.
  unified: false,
  // The active ?from=/?to= mail filter (Explorer drill-down, "view sender", etc.).
  // Stored per history entry so back/forward restore the filtered view instead of
  // reading whatever happens to be in the live URL at navigation time.
  filterFrom: null,
  filterTo: null,
  space: null,

  // ── History ──
  stack: [],
  index: -1,

  // ── Internal ──
  _navigate: null,
  _skipSyncCount: 0,
  _isRestoring: false,

  /** Bind react-router navigate — called once by NavigationSync. */
  bindNavigate(fn) { set({ _navigate: fn }); },

  /**
   * Build a URL from state (with optional overrides).
   * Replaces InboxPage.buildInboxUrl — centralizes route pattern knowledge.
   */
  buildUrl(overrides = {}) {
    const s = get();
    const page = overrides.page !== undefined ? overrides.page : s.page;
    const orgSlug = overrides.orgSlug !== undefined ? overrides.orgSlug : s.orgSlug;
    const accountKey = overrides.accountKey !== undefined ? overrides.accountKey : s.accountKey;
    const unified = overrides.unified !== undefined ? overrides.unified : s.unified;

    // Non-mail pages have their own URL shapes and carry no mail filters.
    if (page === 'explorer') return orgSlug ? `/${orgSlug}` : '/explorer';
    if (page === 'calendar') return orgSlug ? `/${orgSlug}/calendar` : '/calendar';
    if (page === 'settings') return orgSlug ? `/${orgSlug}/settings` : '/settings';

    // Filters come from the entry/state (not the live URL), so back/forward
    // reconstruct the exact filtered view they were captured on.
    const filterFrom = overrides._clearFilters ? null
      : (overrides.filterFrom !== undefined ? overrides.filterFrom : s.filterFrom);
    const filterTo = overrides._clearFilters ? null
      : (overrides.filterTo !== undefined ? overrides.filterTo : s.filterTo);
    // Space filter (MX org single-channel inbox only) — a spc_ key. Like the
    // from/to filters it rides the entry/state, not the live URL.
    const space = overrides._clearFilters ? null
      : (overrides.space !== undefined ? overrides.space : s.space);
    // The open conversation rides the URL (all mail views) so a refresh reopens it.
    const conversationId = overrides.conversationId !== undefined ? overrides.conversationId : s.conversationId;
    const params = new URLSearchParams();
    if (filterTo) params.set('to', filterTo);
    if (filterFrom) params.set('from', filterFrom);
    // Only the org inbox (no account, real org, not unified) carries a space.
    if (space && !accountKey && isRealOrgId(orgSlug) && !unified) params.set('space', space);
    if (conversationId) params.set('c', conversationId);

    // A non-real org slug ("null"/"undefined" from a null param) must not leak into
    // the path — it builds `/null/mail/...` routes that then drive `/orgs/null/...`
    // API 404s across the app. Treat it as org-less (local channels).
    const realOrg = isRealOrgId(orgSlug);
    let base;
    if (accountKey) {
      const prefix = realOrg ? `/${orgSlug}` : '';
      base = `${prefix}/mail/account/${accountKey}`;
    } else if (realOrg) {
      // unified → cross-channel inbox; otherwise the org's single-channel view
      base = unified ? `/${orgSlug}/mail` : `/${orgSlug}/mail/inbox`;
    } else {
      base = '/mail';
    }
    const qs = params.toString();
    return qs ? `${base}?${qs}` : base;
  },

  /**
   * Central navigation method — updates state, pushes history, drives URL.
   * All navigation in the app should go through this instead of calling navigate() directly.
   */
  navigateTo(next, { replace = false, replaceStack = false, clearFilters = false, skipUrl = false } = {}) {
    const current = get();
    const accountChanged = next.accountKey !== undefined && next.accountKey !== current.accountKey;

    // When switching accounts: clear conversationId, viewName, and filters unless
    // explicitly provided. Switching to a specific account is always a channel
    // view (unified = false). `clearFilters` drops the active ?from=/?to= filter.
    const entry = {
      page: next.page !== undefined ? next.page : current.page,
      accountKey: next.accountKey !== undefined ? next.accountKey : current.accountKey,
      viewName: next.viewName !== undefined ? next.viewName : (accountChanged ? null : current.viewName),
      conversationId: next.conversationId !== undefined ? next.conversationId : (accountChanged ? null : current.conversationId),
      unified: next.unified !== undefined ? next.unified : (accountChanged ? false : current.unified),
      filterFrom: clearFilters ? null : (next.filterFrom !== undefined ? next.filterFrom : (accountChanged ? null : current.filterFrom)),
      filterTo: clearFilters ? null : (next.filterTo !== undefined ? next.filterTo : (accountChanged ? null : current.filterTo)),
      space: clearFilters ? null : (next.space !== undefined ? next.space : (accountChanged ? null : current.space)),
    };

    // Skip if nothing changed
    if (entry.page === current.page &&
        entry.accountKey === current.accountKey &&
        entry.viewName === current.viewName &&
        entry.conversationId === current.conversationId &&
        entry.unified === current.unified &&
        entry.filterFrom === current.filterFrom &&
        entry.filterTo === current.filterTo &&
        entry.space === current.space) {
      return;
    }

    // Persist active account to localStorage
    if (entry.accountKey !== current.accountKey) {
      if (entry.accountKey) localStorage.setItem(ACTIVE_ACCOUNT_KEY, entry.accountKey);
      else localStorage.removeItem(ACTIVE_ACCOUNT_KEY);
    }
    if (entry.conversationId !== current.conversationId) persistConversation(entry.conversationId);

    // Update orgSlug if provided
    const orgSlug = next.orgSlug !== undefined ? next.orgSlug : current.orgSlug;

    // Update history — replaceStack overwrites current entry, otherwise push new
    const { stack, index, _navigate } = current;
    let newStack, newIndex;
    if (replaceStack && index >= 0) {
      newStack = [...stack];
      newStack[index] = entry;
      newIndex = index;
    } else {
      newStack = [...stack.slice(0, index + 1), entry];
      newIndex = newStack.length - 1;
    }

    set({
      ...entry,
      orgSlug,
      stack: newStack,
      index: newIndex,
      _isRestoring: false,
    });

    // Only drive the router if the URL actually changes (conversationId is
    // in-memory only, so most navigateTo calls won't change the URL)
    if (!skipUrl && _navigate) {
      const newUrl = get().buildUrl({ ...entry, orgSlug, _clearFilters: clearFilters });
      if (newUrl !== locationUrl()) {
        set({ _skipSyncCount: get()._skipSyncCount + 1 });
        _navigate(newUrl, { replace });
      }
    }
  },

  /**
   * Apply the history entry at `i` to live state — the shared core of
   * goBack/goForward. Drives the router to the entry's URL. Does not push/pop —
   * the caller has already positioned the stack.
   */
  _applyEntryAt(i) {
    const { stack } = get();
    if (i < 0 || i >= stack.length) return;
    const entry = stack[i];

    if (entry.accountKey) localStorage.setItem(ACTIVE_ACCOUNT_KEY, entry.accountKey);
    else localStorage.removeItem(ACTIVE_ACCOUNT_KEY);
    persistConversation(entry.conversationId);

    const { _navigate } = get();
    // Entries captured from the URL remember it verbatim — buildUrl only knows the
    // mail/explorer/calendar/settings shapes, so restoring a search (or spaces)
    // entry through it would silently land on /mail and drop the ?q=.
    const url = entry.url || get().buildUrl(entry);
    const drivesUrl = !!_navigate && url !== locationUrl();
    set({
      ...entry,
      index: i,
      _isRestoring: drivesUrl,
      _skipSyncCount: get()._skipSyncCount + (drivesUrl ? 1 : 0),
    });
    if (drivesUrl) _navigate(url);
  },

  /** Navigate back in history. */
  goBack() {
    const { index } = get();
    if (index <= 0) return;
    get()._applyEntryAt(index - 1);
  },

  /** Navigate forward in history. */
  goForward() {
    const { index, stack } = get();
    if (index >= stack.length - 1) return;
    get()._applyEntryAt(index + 1);
  },

  /** Update viewName and annotate current history entry. */
  setViewName(viewName) {
    const { stack, index } = get();
    if (viewName === get().viewName) return;
    const newStack = [...stack];
    if (index >= 0) newStack[index] = { ...newStack[index], viewName };
    set({ viewName, stack: newStack });
  },

  /**
   * Sync state from URL — called by NavigationSync when URL changes externally
   * (initial load, direct URL entry, browser back). Skips when we caused the change.
   */
  syncFromUrl({ page, orgSlug, accountKey, unified, filterFrom, filterTo, space, conversationId }) {
    if (get()._skipSyncCount > 0) {
      set({ _skipSyncCount: get()._skipSyncCount - 1 });
      return;
    }

    // Any URL change reaching here is a genuine forward navigation, not a history
    // restore (goBack/goForward consume their own _skipSyncCount above). A restore
    // flag still set means a goBack landed on a page that never consumed it (e.g.
    // Explorer, which has no folder-restore logic) — it's stale now, so drop it
    // before it corrupts the next mail page's folder restore.
    if (get()._isRestoring) set({ _isRestoring: false });

    const current = get();
    const newPage = page !== undefined ? page : current.page;
    const newAccountKey = accountKey !== undefined ? accountKey : current.accountKey;
    const newOrgSlug = orgSlug !== undefined ? orgSlug : current.orgSlug;
    const newUnified = unified !== undefined ? unified : current.unified;
    // Filters only exist on mail pages — drop them when the URL is elsewhere.
    const newFilterFrom = newPage === 'mail' ? (filterFrom ?? null) : null;
    const newFilterTo = newPage === 'mail' ? (filterTo ?? null) : null;
    const newSpace = newPage === 'mail' ? (space ?? null) : null;
    // The open conversation only lives on mail pages; a URL that reaches here
    // (initial load, direct entry, back/forward) is authoritative for it.
    const newConversationId = newPage === 'mail' ? (conversationId ?? null) : null;

    // Persist account
    if (newAccountKey !== current.accountKey) {
      if (newAccountKey) localStorage.setItem(ACTIVE_ACCOUNT_KEY, newAccountKey);
      else localStorage.removeItem(ACTIVE_ACCOUNT_KEY);
    }
    if (newConversationId !== current.conversationId) persistConversation(newConversationId);

    const entry = {
      page: newPage,
      accountKey: newAccountKey,
      viewName: current.viewName,
      conversationId: newConversationId,
      unified: newUnified,
      filterFrom: newFilterFrom,
      filterTo: newFilterTo,
      space: newSpace,
      url: locationUrl(),
    };

    const { stack, index } = current;
    const same = (e) => !!e && e.page === entry.page && e.accountKey === entry.accountKey
      && e.conversationId === entry.conversationId && e.unified === entry.unified
      && e.filterFrom === entry.filterFrom && e.filterTo === entry.filterTo
      && e.space === entry.space
      // Each Disk folder (and each Lore page) is its own entry, so the chrome's Back steps through them.
      && ((entry.page !== 'disk' && entry.page !== 'lore') || e.url === entry.url);

    // Don't push if same as current top of stack
    if (same(index >= 0 ? stack[index] : null)) {
      // Same entry — refresh its URL (a second search reuses this entry) and
      // reconcile orgSlug if it changed.
      const newStack = [...stack];
      newStack[index] = { ...newStack[index], url: entry.url };
      set({ stack: newStack, ...(newOrgSlug !== current.orgSlug ? { orgSlug: newOrgSlug } : {}) });
      return;
    }

    // A URL change that lands on the neighbouring entry is someone else's back /
    // forward (the browser button, SettingsPage's navigate(-1)) — walk the stack
    // instead of pushing a duplicate. Pushing one made Back re-enter the page you
    // just left: search → settings → close → clearing the search "went back" to
    // settings again, with no way out of the pair.
    const step = same(stack[index - 1]) ? index - 1 : same(stack[index + 1]) ? index + 1 : null;
    if (step !== null) {
      const newStack = [...stack];
      newStack[step] = { ...newStack[step], url: entry.url };
      set({ ...newStack[step], orgSlug: newOrgSlug, stack: newStack, index: step });
      return;
    }

    const newStack = [...stack.slice(0, index + 1), entry];
    set({
      ...entry,
      orgSlug: newOrgSlug,
      stack: newStack,
      index: newStack.length - 1,
    });
  },

  /** Returns true if the current state came from back/forward, then clears the flag. */
  consumeIsRestoring() {
    const v = get()._isRestoring;
    if (v) set({ _isRestoring: false });
    return v;
  },

  canGoBack() { return get().index > 0; },
  canGoForward() { const { stack, index } = get(); return index < stack.length - 1; },
}));

export default useNavigationStore;
