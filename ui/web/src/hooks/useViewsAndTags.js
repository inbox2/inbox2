import { useState, useEffect } from 'react';
import api from '../lib/localFirstApi';
import remoteApi from '../lib/api';
import { TAGS_CHANGED } from '../components/LabelsField/LabelsField';
import { isRealOrgId } from '../lib/org';
import useNavigationStore from '../stores/navigationStore';
import log from '../lib/log';

const FIRST_VIEWS_RETRY_MS = 2000;
const MAX_VIEWS_RETRY_MS = 30000;

// Load the org's saved views + tags (re-runs when the org changes), and default
// the active view to the system "Inbox" whenever the org/unified inbox has no
// valid selection. Selection state is owned by the caller (shared with folder
// nav), so activeView/setActiveView are passed in.
export default function useViewsAndTags(orgId, { activeView, setActiveView }) {
  const [views, setViews] = useState([]);
  const [tags, setTags] = useState([]);
  // Same source useExternalAccountSync reads — null on the org/unified inbox,
  // set on a channel tab. Used to scope default-selection to the org tab only.
  const activeAccountKey = useNavigationStore((s) => s.accountKey);

  useEffect(() => {
    // Saved views + tags are an MX/domain (org) feature. Local channels (Gmail/
    // Office365/IMAP) are fully offline and have no org, so the route resolves to
    // `/orgs/null/...` → 404s on every inbox load. Skip when there's no real org.
    if (!isRealOrgId(orgId)) return undefined;
    // Views are the sidebar's Inbox/Sent/Drafts and only the API has them, so one
    // failed request must not leave the folders missing until the next org switch.
    let cancelled = false;
    let timer;
    const loadViews = (delay) => api.getViews(orgId)
      .then((data) => { if (!cancelled) setViews(data.views); })
      .catch((e) => {
        log.warn('Inbox', `Failed to load views: ${e?.message || e}`);
        if (!cancelled) timer = setTimeout(() => loadViews(Math.min(delay * 2, MAX_VIEWS_RETRY_MS)), delay);
      });
    loadViews(FIRST_VIEWS_RETRY_MS);
    api.getTags(orgId).then((data) => setTags(data.tags || []))
      .catch((e) => log.warn('Inbox', `Failed to load tags: ${e?.message || e}`));
    return () => { cancelled = true; clearTimeout(timer); };
  }, [orgId]);

  // A label made in the reader (LabelsField): re-list from the server, since the
  // local mirror's tag directory only catches up on its next sync.
  useEffect(() => {
    if (!isRealOrgId(orgId)) return undefined;
    const reload = () => remoteApi.getTags(orgId).then((data) => setTags(data.tags || []))
      .catch((e) => log.warn('Inbox', `Failed to reload tags: ${e?.message || e}`));
    document.addEventListener(TAGS_CHANGED, reload);
    return () => document.removeEventListener(TAGS_CHANGED, reload);
  }, [orgId]);

  // Default the active view to the system "Inbox" for the org/unified inbox.
  // Must run independently of the data load above: switching tabs via the chrome
  // bar navigates without resetting the shared activeView (both routes render the
  // same InboxPage, so its state persists), so a [orgId]-only effect would leave
  // the folders sidebar with no valid selection. The channel path is owned by
  // useFolderViews — skip when a channel is active.
  useEffect(() => {
    if (activeAccountKey || !isRealOrgId(orgId) || views.length === 0) return;
    // Switching tabs via the chrome bar navigates without resetting the shared
    // activeView (both routes render the same InboxPage, so its state persists).
    // The carried-over selection is only valid here if it belongs to THIS org's
    // views — otherwise it's stale: a channel view (`ext_…` id) or another org's
    // view from a different inbox2 tab, neither of which matches a sidebar item.
    // The hardcoded Archived/Spam/Trash folders aren't in `views`, so allow them
    // by name. Anything else (incl. null) falls back to the system Inbox.
    const HARDCODED_FOLDERS = ['Archived', 'Spam', 'Trash'];
    const valid = !!activeView
      && (views.some((v) => v.id === activeView.id) || HARDCODED_FOLDERS.includes(activeView.name));
    if (valid) return;
    const inbox = views.find((v) => v.name === 'Inbox' && v.kind === 'system');
    if (inbox) setActiveView(inbox);
  }, [views, activeView, orgId, activeAccountKey, setActiveView]);

  return { views, tags };
}
