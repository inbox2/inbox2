import { useState } from 'react';
import { ADDRESS_TREE_COLLAPSED } from '../../lib/storageKeys';
import Icon from '../Icon';
import ContextMenu from '../DropdownMenu/ContextMenu';
import { FOLDER_KIND, folderLabel, folderView } from '../../lib/addressFolders';
import styles from './AddressFolderTree.module.css';

// In the tree the address is implied: "info", a tag as "+receipts" under its owner.
function treeLabel(f) {
  if (f.kind === FOLDER_KIND.TAG && f.parent) return f.key.slice(f.parent.length);
  if (f.kind === FOLDER_KIND.OWN || f.kind === FOLDER_KIND.SHARED) return f.key;
  return folderLabel(f);
}

// Menu rows: a check when on, an empty slot when off (keeps labels aligned).
const check = (on) => (on ? 'checkmark' : <span />);

/** "Show in Inbox" (shared and tag folders) and "Notify me" for one folder. */
function folderMenuItems(f, onSetPref) {
  const items = [];
  if (f.kind === FOLDER_KIND.SHARED || f.kind === FOLDER_KIND.TAG) {
    items.push({ label: 'Show in Inbox', icon: check(f.in_inbox), onSelect: () => onSetPref(f, { inbox: !f.in_inbox }) });
  }
  items.push({ label: 'Notify me', icon: check(f.notify), onSelect: () => onSetPref(f, { notify: !f.notify }) });
  return items;
}

function FolderRow({ folder, label, icon, active, indent, onSelect, onSetPref, expanded, onToggle }) {
  const [menuAt, setMenuAt] = useState(null);
  const isInbox = folder.kind === FOLDER_KIND.INBOX;
  const readOnly = (folder.kind === FOLDER_KIND.OWN || folder.kind === FOLDER_KIND.SHARED) && !folder.can_reply;
  // Other has no address to keep a pref under: no bell, no menu.
  const hasPrefs = folder.kind !== FOLDER_KIND.OTHER;
  const openMenuFrom = (el) => {
    const r = el.getBoundingClientRect();
    setMenuAt({ x: r.left, y: r.bottom + 2 });
  };
  return (
    <div
      className={`${styles.row} ${active ? styles.rowActive : ''} ${indent ? styles.indent : ''}`}
      role="presentation"
      onContextMenu={(e) => { e.preventDefault(); if (hasPrefs) setMenuAt({ x: e.clientX, y: e.clientY }); }}
    >
      {onToggle && <Chevron expanded={expanded} label={label} onToggle={onToggle} />}
      <button
        type="button"
        className={styles.main}
        aria-current={active ? 'true' : undefined}
        onClick={onSelect}
        onKeyDown={(e) => {
          // The keyboard's context-menu key / Shift+F10 open the row menu.
          if (hasPrefs && (e.key === 'ContextMenu' || (e.shiftKey && e.key === 'F10'))) { e.preventDefault(); openMenuFrom(e.currentTarget); }
        }}
      >
        <Icon name={icon} size={15} className={styles.icon} />
        <span className={styles.label}>{label}</span>
        {/* Plain words like iOS and Android; the pen and eye icons read as noise (2026-11-23). */}
        {readOnly && <span className={styles.readOnly}>Read only</span>}
      </button>
      {hasPrefs && <button
        type="button"
        className={`${styles.ctl} ${styles.ctlShown} ${folder.notify ? styles.ctlOn : ''}`}
        aria-label={folder.notify ? 'Notifications on' : 'Notifications off'}
        aria-pressed={!!folder.notify}
        title={folder.notify ? 'Notifications on' : 'Notifications off'}
        onClick={() => onSetPref(folder, { notify: !folder.notify })}
      >
        <Icon name={folder.notify ? 'bell' : 'bell.slash'} size={11} />
      </button>}
      {!isInbox && hasPrefs && (
        <button
          type="button"
          className={`${styles.ctl} ${styles.more}`}
          aria-label={`${label} options`}
          aria-haspopup="menu"
          onClick={(e) => openMenuFrom(e.currentTarget)}
        >
          <Icon name="ellipsis" size={11} />
        </button>
      )}
      {folder.unread > 0 && <span className={styles.badge}>{folder.unread}</span>}
      <ContextMenu
        open={!!menuAt}
        position={menuAt}
        items={folderMenuItems(folder, onSetPref)}
        onClose={() => setMenuAt(null)}
      />
    </div>
  );
}

/** Expand/collapse toggle in front of a row or group heading. */
function Chevron({ expanded, label, onToggle }) {
  return (
    <button type="button" className={styles.chevron} aria-expanded={expanded}
      aria-label={`${expanded ? 'Collapse' : 'Expand'} ${label}`} onClick={onToggle}>
      <Icon name={expanded ? 'chevron.down' : 'chevron.right'} size={10} />
    </button>
  );
}

// Which parts of the tree are collapsed, kept across reloads. Default: Inbox
// open, Yours and Shared closed, so Sent and Drafts sit close under Inbox.
const DEFAULT_COLLAPSED = { inbox: false, yours: true, shared: true };
function readCollapsed() {
  try { return { ...DEFAULT_COLLAPSED, ...JSON.parse(localStorage.getItem(ADDRESS_TREE_COLLAPSED) || '{}') }; } catch { return DEFAULT_COLLAPSED; }
}

const sumUnread = (list) => list.reduce((n, f) => n + (f.unread || 0), 0);

/**
 * The MX domain's Inbox with its address folders under it. Inbox expands into
 * two groups, Yours and Shared, each collapsible and showing its total unread,
 * then Other. Each row selects its folder as the list's view; the
 * bell and the row menu (… button, right-click, Shift+F10) set the member's prefs.
 */
export default function AddressFolderTree({ folders, domainKey, inboxView, activeView, onSwitchView, onSetPref }) {
  const [collapsed, setCollapsed] = useState(readCollapsed);
  const toggle = (part) => setCollapsed((c) => {
    const next = { ...c, [part]: !c[part] };
    try { localStorage.setItem(ADDRESS_TREE_COLLAPSED, JSON.stringify(next)); } catch { /* private mode */ }
    return next;
  });

  const inbox = folders.find((f) => f.kind === FOLDER_KIND.INBOX);
  const own = folders.filter((f) => f.kind === FOLDER_KIND.OWN);
  const tagsOf = (o) => folders.filter((f) => f.kind === FOLDER_KIND.TAG && f.parent === o.key);
  const yours = own.flatMap((o) => [o, ...tagsOf(o)]);
  const shared = folders.filter((f) => f.kind === FOLDER_KIND.SHARED);
  const other = folders.find((f) => f.kind === FOLDER_KIND.OTHER);
  const activeId = activeView?.id;

  const row = (f, indent = false) => {
    const view = folderView(f, domainKey);
    return (
      <FolderRow key={f.key} folder={f} label={treeLabel(f)} icon={view.icon} indent={indent}
        active={activeId === view.id} onSelect={() => onSwitchView(view)} onSetPref={onSetPref} />
    );
  };

  // A collapsed group still shows the open folder, so the selection never hides.
  const group = (part, title, list, render) => {
    if (list.length === 0) return null;
    const open = !collapsed[part];
    const unread = sumUnread(list);
    const shown = open ? list : list.filter((f) => folderView(f, domainKey).id === activeId);
    return (
      <div className={styles.group}>
        <div className={styles.groupHead}>
          <Chevron expanded={open} label={title} onToggle={() => toggle(part)} />
          <button type="button" className={styles.groupTitle} aria-expanded={open} onClick={() => toggle(part)}>
            {title}
          </button>
          {unread > 0 && <span className={styles.groupBadge}>{unread}</span>}
        </div>
        {shown.map(render)}
      </div>
    );
  };

  const inboxOpen = !collapsed.inbox;
  return (
    <div className={styles.tree}>
      {inbox && (
        <FolderRow folder={inbox} label="Inbox" icon={inboxView?.icon || 'tray'}
          active={!!inboxView && activeId === inboxView.id}
          onSelect={() => inboxView && onSwitchView(inboxView)} onSetPref={onSetPref}
          expanded={inboxOpen} onToggle={() => toggle('inbox')} />
      )}
      {inboxOpen ? (
        <div className={styles.children}>
          {group('yours', 'Yours', yours, (f) => row(f, f.kind === FOLDER_KIND.TAG))}
          {group('shared', 'Shared', shared, (f) => row(f))}
          {other && row(other)}
        </div>
      ) : (
        // Inbox closed: keep the open folder visible under it.
        [...yours, ...shared, ...(other ? [other] : [])]
          .filter((f) => folderView(f, domainKey).id === activeId)
          .map((f) => <div key={f.key} className={styles.children}>{row(f)}</div>)
      )}
    </div>
  );
}
