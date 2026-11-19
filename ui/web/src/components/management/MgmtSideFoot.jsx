import { useCallback, useRef, useState } from 'react';
import { createPortal } from 'react-dom';
import Icon from '../Icon';
import Avatar from '../Avatar';
import useAuth from '../../hooks/useAuth';
import useDismiss from '../../hooks/useDismiss';
import ChangePasswordModal from '../../pages/admin/ChangePasswordModal';
import ContactEmailModal from '../../pages/admin/ContactEmailModal';
import PasskeysModal from '../../pages/admin/PasskeysModal';
import styles from './MgmtSideFoot.module.css';

/**
 * The foot of a management sidebar (the console, Disk): the signed-in person with a menu for
 * password, passkeys and logging out. The other apps are in the AppSwitcher, top right.
 *
 * Props:
 *   sub       — the line under the name (the org's domain, else the email)
 *   onAction  — called on any choice, so a phone drawer can close
 */
export default function MgmtSideFoot({ sub, onAction }) {
  const { user, logout } = useAuth();
  const [menuOpen, setMenuOpen] = useState(false);
  const [modal, setModal] = useState(null); // 'password' | 'passkeys' | 'contact'
  const menuRef = useRef(null);
  useDismiss(menuRef, useCallback(() => setMenuOpen(false), []), menuOpen);
  const pick = (fn) => () => { setMenuOpen(false); onAction?.(); fn(); };

  return (
    <div className={styles.foot}>
      <div className={styles.userWrap} ref={menuRef}>
        {menuOpen && (
          <div className={styles.userMenu} role="menu">
            <button type="button" className={styles.userMenuItem} role="menuitem" onClick={pick(() => setModal('password'))}>
              <Icon name="lock" size={15} /> Change password
            </button>
            <button type="button" className={styles.userMenuItem} role="menuitem" onClick={pick(() => setModal('passkeys'))}>
              <Icon name="key" size={15} /> Passkeys
            </button>
            <button type="button" className={styles.userMenuItem} role="menuitem" onClick={pick(() => setModal('contact'))}>
              <Icon name="envelope.fill" size={15} /> Contact email
            </button>
            <div className={styles.userMenuDivider} />
            <button type="button" className={styles.userMenuItem} role="menuitem" onClick={pick(logout)}>
              <Icon name="rectangle.portrait.and.arrow.right" size={15} /> Log out
            </button>
          </div>
        )}
        <button type="button" className={styles.userChip} onClick={() => setMenuOpen((v) => !v)} aria-haspopup="menu" aria-expanded={menuOpen}>
          <Avatar name={user?.display_name || user?.username} email={user?.email} size={30} />
          <span className={styles.userWho}>
            <span className={styles.userName}>{user?.display_name || user?.username}</span>
            <span className={styles.userSub}>{sub || user?.email}</span>
          </span>
          <Icon name="chevron.up.chevron.down" size={12} />
        </button>
      </div>
      {/* Portalled: on a phone the sidebar is a drawer that closes (offscreen, inert) as the menu is used. */}
      {modal === 'password' && createPortal(<ChangePasswordModal onClose={() => setModal(null)} />, document.body)}
      {modal === 'contact' && createPortal(<ContactEmailModal onClose={() => setModal(null)} />, document.body)}
      {modal === 'passkeys' && createPortal(<PasskeysModal onClose={() => setModal(null)} />, document.body)}
    </div>
  );
}
