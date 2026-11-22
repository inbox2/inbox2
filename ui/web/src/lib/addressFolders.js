import { CONV_STATUS } from './conversationStatus.js';

// Address folders (API: AddressFolders + FoldersController). An MX domain's
// mail split by the address it came in to: Inbox (mail for you), your own
// address and its +tags, shared addresses (info@, support@) and the rest.
export const FOLDER_KIND = {
  INBOX: 'inbox',
  OWN: 'own',
  TAG: 'tag',
  SHARED: 'shared',
  OTHER: 'other',
};
export const INBOX_FOLDER = 'inbox';
export const VIEW_KIND_FOLDER = 'folder';

/** Sidebar/header name of a folder: "info@", "waseem+receipts@", "Other". */
export function folderLabel(f) {
  if (f.kind === FOLDER_KIND.INBOX) return 'Inbox';
  if (f.kind === FOLDER_KIND.OTHER) return 'Other';
  return `${f.key}@`;
}

/**
 * An address folder as an inbox view (the activeView shape the list, header
 * and back/forward restore already understand). `name` is unique per domain
 * because it holds the "@", so restore-by-name can't hit a system view.
 */
export function folderView(f, domainKey) {
  return {
    id: `folder:${domainKey}:${f.key}`,
    name: folderLabel(f),
    icon: f.kind === FOLDER_KIND.OTHER ? 'tray.2.fill' : 'at',
    kind: VIEW_KIND_FOLDER,
    folder: f.key,
    address: f.address,
    canReply: !!f.can_reply,
    folderKind: f.kind,
    filters: [],
  };
}

/** The pref key the API takes for a folder: its full address, or "inbox". */
export function folderPrefKey(f) {
  return f.kind === FOLDER_KIND.INBOX ? INBOX_FOLDER : f.address;
}

/**
 * The MX conversation-list query for a view. Inbox and address folders send
 * `folder` (the API splits by address); every other view (Sent, Drafts, All
 * Mail, Archived…) is the whole-pool listing and must NOT send it.
 */
export function orgListParams({ activeView, mailboxFilter, senderFilter, selectedTags, spaceFilter, domainFilter, perPage }) {
  const params = { per_page: perPage };
  if (mailboxFilter) params.to = mailboxFilter;
  if (senderFilter) params.from = senderFilter;
  // Translate the active view's filters into API query params. Each system
  // view carries its own distinguishing filter (Sent=direction:outbound,
  // Drafts=is_draft:true, Unassigned=assignee:is_empty, Mentioned=mentioned:is_me);
  // without this every view collapsed to status=open and Inbox/Sent/Drafts all
  // showed the same list.
  //
  // The Inbox forces status=open regardless of the filter it ships with: some
  // backends still serve the legacy Inbox definition (assignee:is_me), and
  // honoring that would empty the inbox whenever nothing is assigned to you.
  // It also sends folder=inbox (mail for you, not every address on the domain)
  // — except on a Space drill-down, which is an org-wide pool by design.
  const isInbox = activeView?.kind === 'system' && activeView?.name === 'Inbox';
  if (activeView?.kind === VIEW_KIND_FOLDER) {
    params.folder = activeView.folder;
    params.status = CONV_STATUS.OPEN;
  } else if (isInbox) {
    params.status = CONV_STATUS.OPEN;
    if (!spaceFilter) params.folder = INBOX_FOLDER;
  } else {
    for (const f of (activeView?.filters || [])) {
      switch (f.field) {
        case 'status': params.status = f.value; break;
        case 'direction': params.direction = f.value; break;
        case 'is_draft': params.is_draft = f.value; break;
        case 'assignee':
          params.assignee = f.operator === 'is_me' ? 'me' : f.operator === 'is_empty' ? 'none' : f.value;
          break;
        case 'mentioned':
          if (f.operator === 'is_me') params.mentioned = 'me';
          break;
        default: break;
      }
    }
    // Default to the open pool when no folder-defining filter is set (e.g. a
    // not-yet-resolved view). "All Mail" intentionally has no filters, so it
    // must NOT be forced to open — it spans every status.
    const hasScopingFilter = params.status || params.direction || params.is_draft || params.assignee || params.mentioned;
    if (!hasScopingFilter && activeView?.name !== 'All Mail') params.status = CONV_STATUS.OPEN;
    if (activeView?.name === 'All Mail') params.include_sent = 'true';
  }
  // Sidebar LABELS overlay: AND the folder above with the selected tags
  // (OR among themselves). Sent as tags[] so the API filters server-side
  // (the list is paginated, so client-side narrowing would be wrong).
  const tagNames = selectedTags ? Array.from(selectedTags) : [];
  if (tagNames.length) params.tags = tagNames;
  // Space drill-down (treemap → inbox): narrow to one MX classification bucket.
  if (spaceFilter) params.space = spaceFilter;
  // Per-domain workspace tab: narrow the org's MX pool to one domain.
  if (domainFilter) params.domain = domainFilter;
  return params;
}

/** A folder's header name from its key alone (the unified columns store keys). */
export function folderKeyLabel(key) {
  if (!key || key === INBOX_FOLDER) return 'Inbox';
  if (key === FOLDER_KIND.OTHER) return 'Other';
  return `${key}@`;
}

/** Key of an extra folder column: the domain column's key + the folder. */
export const extraColumnKey = (domainKey, folder) => `${domainKey}~${folder}`;

/**
 * The unified inbox's columns. Every MX domain column lists a folder: the one
 * picked in its header in list mode, else Inbox. In list mode an extra column
 * opened from a picker follows its domain's column. Other channels pass through.
 * `layout` = { folders: { [domainKey]: folderKey }, extras: [{ domainKey, folder }] }.
 */
export function unifiedColumnAccounts(accounts, layout, listMode) {
  const out = [];
  for (const a of accounts) {
    if (a.provider_type !== 'inbox2') { out.push(a); continue; }
    const picked = listMode ? layout?.folders?.[a.key] : null;
    out.push({ ...a, folder: picked || INBOX_FOLDER });
    if (!listMode) continue;
    for (const x of layout?.extras || []) {
      if (x.domainKey !== a.key) continue;
      out.push({
        ...a,
        key: extraColumnKey(a.key, x.folder),
        folder: x.folder,
        folderColumnOf: a.key,
        email_address: x.folder === FOLDER_KIND.OTHER ? `Other · ${a.email_address}` : `${x.folder}@${a.email_address}`,
      });
    }
  }
  return out;
}
