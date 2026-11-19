import { useCallback, useEffect, useRef } from 'react';
import useNavigationStore from '../stores/navigationStore';
import { CONV_STATUS } from '../lib/conversationStatus';
import { FOLDER_ROLE } from '../lib/folderRoles';

// Well-known folders and the mapping from a provider's folder role → display.
const FOLDER_NAMES = new Set(['Inbox', 'Sent', 'Drafts']);
const ROLE_TO_FOLDER = { [FOLDER_ROLE.INBOX]: 'Inbox', [FOLDER_ROLE.SENT]: 'Sent', [FOLDER_ROLE.DRAFTS]: 'Drafts' };
const ROLE_ICONS = { [FOLDER_ROLE.INBOX]: 'tray', [FOLDER_ROLE.SENT]: 'paperplane', [FOLDER_ROLE.DRAFTS]: 'doc' };
const ROLE_ORDER = { [FOLDER_ROLE.INBOX]: 0, [FOLDER_ROLE.SENT]: 1, [FOLDER_ROLE.DRAFTS]: 2 };

// Meta channels have no provider folders — their conversations are split by
// surface (`channel`) and event kind (`kind`) instead. These sub-views let a
// member scope to e.g. WhatsApp messages vs Facebook Page comments vs Instagram
// mentions. Keyed by the account's provider_type (see docs/Cloud-Push.md Meta).
const META_VIEWS = {
  whatsapp: [
    { name: 'Messages', icon: 'paperplane', filters: [] },
  ],
  messenger: [
    { name: 'All', icon: 'tray', filters: [] },
    { name: 'Messages', icon: 'paperplane', filters: [{ field: 'channel', value: 'messenger' }] },
    { name: 'Comments', icon: 'bubble.left.fill', filters: [{ field: 'channel', value: 'facebook' }] },
  ],
  instagram: [
    { name: 'All', icon: 'tray', filters: [] },
    { name: 'DMs', icon: 'paperplane', filters: [{ field: 'kind', value: 'dm' }] },
    { name: 'Comments', icon: 'bubble.left.fill', filters: [{ field: 'kind', value: 'comment' }] },
    { name: 'Mentions', icon: 'at', filters: [{ field: 'kind', value: 'mention' }] },
  ],
};

/**
 * Derives the sidebar folder/view lists for the active channel and owns folder
 * navigation: switching views (with per-folder selection memory + on-demand
 * sync), auto-selecting Inbox once an external account's folders load, and
 * restoring the folder on browser back/forward.
 *
 * External accounts derive folders from synced provider folders; org/unified
 * accounts use the server-defined views. Returns the view lists plus switchView.
 */
export default function useFolderViews({
  activeAccountKey, activeAccountProvider, syncFolders, views, activeView, setActiveView,
  setLabelFilters, setSelectedTags, setSelectedConv, mailboxFilter, senderFilter,
  navIsRestoring, syncMgr, selectedId,
}) {
  const folderSelectionRef = useRef({}); // viewName → selectedId

  // `restore: false` opens the folder on its list instead of reopening the
  // thread last selected there (the phone layout, which has no reading pane).
  const switchView = useCallback((v, { restore = true } = {}) => {
    // Save current selection for this folder
    if (activeView?.name && selectedId) {
      folderSelectionRef.current[activeView.name] = selectedId;
    }
    setActiveView(v);
    setLabelFilters(new Map());
    setSelectedTags?.(new Set()); // labels are folder-scoped; switching folder clears them
    // Restore previous selection for target folder
    const restored = restore ? folderSelectionRef.current[v?.name] : null;
    setSelectedConv(null);
    // Clicking a folder/label is a fresh scope — drop any active ?from=/?to=
    // person drill-down (from Explorer / "view sender"). Otherwise it lingers as
    // an invisible intersection (e.g. "Archived ∩ from:lajos") that reads as an
    // empty folder. clearFilters also resets the seeded Filter field via the URL.
    useNavigationStore.getState().navigateTo(
      { conversationId: restored || null, viewName: v?.name },
      { replace: true, clearFilters: true },
    );

    // Trigger on-demand sync when user navigates to a non-eager folder
    if (activeAccountKey) {
      const channel = syncMgr.get(activeAccountKey);
      if (channel) {
        const filter = v?.filters?.[0];
        if (filter?.field === 'status') {
          channel.syncFolderByRole(filter.value).catch(() => {});
        } else if (filter?.field === 'gmail_label') {
          channel.syncFolderByProviderId(filter.value).catch(() => {});
        }
      }
    }
  // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [activeView, selectedId, activeAccountKey]);

  // Meta channels (Instagram/Messenger/WhatsApp) have no provider folders —
  // their sidebar entries are channel/kind sub-views instead of mail folders.
  const metaViews = META_VIEWS[activeAccountProvider];

  // For external accounts, derive folder views from synced Gmail folders (or, for
  // Meta accounts, from the channel/kind sub-view map).
  const folderViews = activeAccountKey
    ? (metaViews
        ? metaViews.map((v, i) => ({ id: `ext_meta_${activeAccountKey}_${i}`, kind: 'system', _order: i, ...v }))
        : syncFolders
            .filter(f => f.well_known_role && ROLE_TO_FOLDER[f.well_known_role])
            .map(f => ({
              id: `ext_${f.key}`,
              name: ROLE_TO_FOLDER[f.well_known_role],
              icon: ROLE_ICONS[f.well_known_role] || 'tray',
              kind: 'system',
              filters: [{ field: 'gmail_label', value: f.provider_label_id || f.key, folderKey: f.key, wellKnownRole: f.well_known_role }],
              _order: ROLE_ORDER[f.well_known_role] ?? 99,
            }))
            .sort((a, b) => a._order - b._order))
    : views.filter(v => v.kind === 'system' && FOLDER_NAMES.has(v.name));

  const systemViews = activeAccountKey
    ? []
    : views.filter(v => v.kind === 'system' && !FOLDER_NAMES.has(v.name));
  const personalViews = activeAccountKey
    ? []
    : views.filter(v => v.kind === 'personal');

  // Auto-select Inbox for external accounts once folders have loaded
  // If a sender/mailbox filter is active, use All Mail so the filter can work across folders
  const folderViewIds = folderViews.map(v => v.id).join(',');
  /* eslint-disable react-hooks/exhaustive-deps -- intentional: syncs activeView with account/folder changes via folderViewIds */
  useEffect(() => {
    if (!activeAccountKey || folderViews.length === 0) return;
    const viewStale = activeView && !folderViews.some(v => v.id === activeView.id)
      && activeView.id !== 'ext_all' && activeView.kind === 'system';
    if (activeView && !viewStale) return;
    if (mailboxFilter || senderFilter) {
      setActiveView({ id: 'ext_all', name: 'All Mail', icon: 'tray.full', kind: 'system', filters: [] });
    } else {
      // Mail accounts default to Inbox; Meta accounts (no Inbox) to their first
      // sub-view (Messages / All).
      const inbox = folderViews.find(v => v.name === 'Inbox') || folderViews[0];
      if (inbox) setActiveView(inbox);
    }
  }, [activeAccountKey, folderViewIds]);
  /* eslint-enable react-hooks/exhaustive-deps */

  // ── Notify NavigationManager when folder changes ──
  useEffect(() => {
    if (activeView?.name) useNavigationStore.getState().setViewName(activeView.name);
  }, [activeView?.name]);

  // ── Restore folder on back/forward navigation ──
  useEffect(() => {
    if (!navIsRestoring) return;
    const targetName = useNavigationStore.getState().viewName;
    if (!targetName) { useNavigationStore.getState().consumeIsRestoring(); return; }
    const allViews = [
      ...folderViews,
      ...views.filter(v => v.kind === 'system' && !FOLDER_NAMES.has(v.name)),
      ...views.filter(v => v.kind === 'personal'),
      { name: 'Archived', kind: 'system', filters: [{ field: 'status', value: CONV_STATUS.ARCHIVED }] },
      { name: 'Spam', kind: 'system', filters: [{ field: 'status', value: CONV_STATUS.SPAM }] },
      { name: 'Trash', kind: 'system', filters: [{ field: 'status', value: CONV_STATUS.TRASH }] },
      { id: 'ext_all', name: 'All Mail', icon: 'tray.full', kind: 'system', filters: [] },
    ];
    const target = allViews.find(v => v.name === targetName);
    if (target) {
      setActiveView(target);
      useNavigationStore.getState().consumeIsRestoring();
    }
    // If not found, views may still be loading — effect re-runs when they arrive
  }, [navIsRestoring, folderViews, views, setActiveView]);

  return { folderViews, systemViews, personalViews, switchView };
}
