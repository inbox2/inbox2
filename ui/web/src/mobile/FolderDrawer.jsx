import { useCallback, useEffect, useRef } from 'react';
import { useNavigate } from 'react-router';
import Icon from '../components/Icon';
import useDismiss from '../hooks/useDismiss';
import { CONV_STATUS } from '../lib/conversationStatus';
import styles from './FolderDrawer.module.css';
import { consolePath } from '../lib/consoleHost';

// The status folders every MX inbox has, after the server's Inbox/Sent/Drafts.
const STATUS_FOLDERS = [
  { name: 'Archived', icon: 'archivebox', status: CONV_STATUS.ARCHIVED },
  { name: 'Spam', icon: 'nosign', status: CONV_STATUS.SPAM },
  { name: 'Trash', icon: 'trash', status: CONV_STATUS.TRASH },
];

/* The apps' FolderDrawer: slides in from the left over the inbox. Mailboxes,
 * views, labels — the same lists the desktop sidebar shows — and, at the foot,
 * Settings and (for admins) the admin console. Inert while closed; Escape or a
 * tap outside closes it and focus returns to whatever opened it. */
export default function FolderDrawer({
  // pinned: a permanent column (landscape iPad) — no scrim, no close, no trap.
  pinned = false,
  open, onClose, title, header, folderViews, systemViews, personalViews, activeView, onSwitchView,
  tags, selectedTags, onToggleTag, orgSlug, isAdmin,
}) {
  const navigate = useNavigate();
  const panelRef = useRef(null);
  const openerRef = useRef(null);
  useDismiss(panelRef, onClose, open && !pinned);

  // Focus in on open, back to the opener on close.
  useEffect(() => {
    if (pinned) return;
    if (open) {
      openerRef.current = document.activeElement;
      panelRef.current?.querySelector('button')?.focus();
    } else if (openerRef.current) {
      openerRef.current.focus?.();
      openerRef.current = null;
    }
  }, [open, pinned]);

  // Keep Tab inside the open drawer — the inbox behind the scrim isn't reachable.
  const trapTab = (e) => {
    if (e.key !== 'Tab') return;
    const focusables = panelRef.current?.querySelectorAll('button:not([disabled])');
    if (!focusables?.length) return;
    const first = focusables[0];
    const last = focusables[focusables.length - 1];
    if (e.shiftKey && document.activeElement === first) { e.preventDefault(); last.focus(); }
    else if (!e.shiftKey && document.activeElement === last) { e.preventDefault(); first.focus(); }
  };

  const go = useCallback((to) => { if (!pinned) onClose(); navigate(to); }, [onClose, navigate, pinned]);
  const base = orgSlug ? `/${orgSlug}` : '';

  const item = (key, icon, label, active, onClick, color) => (
    <button key={key} type="button" className={[styles.item, active ? styles.itemOn : ''].join(' ')}
      onClick={onClick} aria-current={active ? 'true' : undefined}>
      {color
        ? <span className={styles.swatch} ref={(el) => el?.style.setProperty('--swatch', color)} />
        : <Icon name={icon} size={16} />}
      <span className={styles.itemLabel}>{label}</span>
    </button>
  );

  return (
    <>
      {open && !pinned && <div className={styles.scrim} aria-hidden="true" />}
      <aside
        ref={panelRef}
        className={pinned ? styles.pinned : [styles.drawer, open ? styles.open : ''].join(' ')}
        inert={!open}
        role={pinned ? undefined : 'dialog'}
        aria-modal={pinned ? undefined : 'true'}
        aria-label="Folders"
        onKeyDown={pinned ? undefined : trapTab}
      >
        <div className={styles.head}>
          {header || <span className={styles.title}>{title}</span>}
          {!pinned && (
            <button type="button" className={styles.close} onClick={onClose} aria-label="Close folders">
              <Icon name="xmark" size={14} />
            </button>
          )}
        </div>

        <div className={styles.body}>
          <div className={styles.group}>Mailboxes</div>
          {folderViews.map((v) => item(v.id, v.icon || 'tray', v.name, activeView?.id === v.id, () => onSwitchView(v)))}
          {STATUS_FOLDERS.map((f) => item(f.name, f.icon, f.name, activeView?.name === f.name,
            () => onSwitchView({ name: f.name, filters: [{ field: 'status', value: f.status }] })))}

          {(systemViews.length > 0 || personalViews.length > 0) && <div className={styles.group}>Views</div>}
          {systemViews.map((v) => item(v.id, v.icon || 'tray', v.name, activeView?.id === v.id, () => onSwitchView(v)))}
          {personalViews.map((v) => item(v.id, v.icon || 'line.3.horizontal.decrease', v.name, activeView?.id === v.id, () => onSwitchView(v)))}

          {tags.length > 0 && <div className={styles.group}>Labels</div>}
          {tags.map((t) => item(t.id, null, t.name, selectedTags.has(t.name), () => onToggleTag(t.name), t.color || 'var(--text-muted)'))}
        </div>

        <div className={styles.foot}>
          {item('settings', 'gear', 'Settings', false, () => go(`${base}/settings`))}
          {isAdmin && item('admin', 'checkmark.shield.fill', 'Admin console', false, () => go(consolePath()))}
        </div>
      </aside>
    </>
  );
}
