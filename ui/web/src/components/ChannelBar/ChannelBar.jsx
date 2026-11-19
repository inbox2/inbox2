import { useRef, useEffect } from 'react';
import AccountSwitcher, { ProviderIcon } from '../AccountSwitcher/AccountSwitcher';
import Icon from '../Icon';
import Tooltip from '../Tooltip';
import { useAvatarUrl } from '../../lib/avatar';
import useAccountStatusStore, { needsReconnect } from '../../stores/accountStatusStore';
import useRainbowTabs from '../../lib/rainbowTabsPref';
import { withShortcut } from '../../lib/shortcuts';
import styles from './ChannelBar.module.css';

function ChannelItem({ account, enabled, muteCheck, onToggle, onNavigate }) {
  // Prefer the provider photo, then a Gravatar for the address; ProviderIcon
  // falls back to the provider/default icon if neither resolves.
  const picture = useAvatarUrl(account.email_address);
  // Live connection status (falls back to the loaded status) → a dead sign-in
  // gets a red ring + dot so it reads as "needs reconnection" at a glance.
  const status = useAccountStatusStore(s => s.byKey[account.key]) ?? account.status;
  const reconnect = needsReconnect(status);
  return (
    <button
      className={`${styles.channel} ${enabled ? styles.channelActive : styles.channelDisabled}${reconnect ? ` ${styles.channelReauth}` : ''}`}
      onClick={() => onNavigate(account.key)}
      aria-label={reconnect ? `${account.display_name}: sign-in expired, reconnect` : `Open ${account.display_name}`}
    >
      <span
        className={`${styles.channelCheck} ${enabled ? styles.channelCheckOn : ''}${enabled && muteCheck ? ` ${styles.channelCheckMuted}` : ''}`}
        role="checkbox"
        aria-checked={enabled}
        aria-label={`Include ${account.email_address || account.display_name} in unified view`}
        onClick={(e) => { e.stopPropagation(); onToggle(); }}
        onKeyDown={(e) => { if (e.key === ' ' || e.key === 'Enter') { e.stopPropagation(); e.preventDefault(); onToggle(); } }}
        tabIndex={0}
      >
        {enabled && <Icon name="checkmark" size={9} />}
      </span>
      <span className={styles.channelAvatar}>
        <ProviderIcon type={account.provider_type} iconUrl={account.icon_url} avatarUrl={account.avatar_url || picture} name={account.display_name || account.email_address} size={26} />
        {reconnect && <span className={styles.channelReauthDot} aria-hidden="true" />}
      </span>
      <span className={styles.channelLabel}>
        {account.email_address || account.display_name}
      </span>
    </button>
  );
}

export default function ChannelBar({ channelStates, onToggle, unreadOnly, onToggleUnread, accounts, onSwitchAccount, onAddAccount, onReorder, viewMode, onViewModeChange }) {
  const barRef = useRef(null);
  // Keyboard navigation
  useEffect(() => {
    const bar = barRef.current;
    if (!bar) return;

    const handler = (e) => {
      const buttons = bar.querySelectorAll('button');
      const focused = document.activeElement;
      const idx = Array.from(buttons).indexOf(focused);
      if (idx === -1) return;

      if (e.key === 'ArrowRight' && idx < buttons.length - 1) {
        e.preventDefault();
        buttons[idx + 1].focus();
      } else if (e.key === 'ArrowLeft' && idx > 0) {
        e.preventDefault();
        buttons[idx - 1].focus();
      }
    };

    bar.addEventListener('keydown', handler);
    return () => bar.removeEventListener('keydown', handler);
  }, []);

  // With rainbow tabs on, the chrome is already saturated — so the "included"
  // check reads as a neutral dark-gray control instead of the accent colour.
  const { enabled: rainbowTabs } = useRainbowTabs();

  const channels = Object.entries(channelStates);
  if (channels.length === 0) return null;

  return (
    <div className={styles.bar} ref={barRef} role="toolbar" aria-label="Channel filters">
      {accounts && (
        <div className={styles.accountSwitcher}>
          <AccountSwitcher
            accounts={accounts}
            activeKey={null}
            onSwitch={onSwitchAccount}
            onAddAccount={onAddAccount}
            onUnified={() => {}}
            onReorder={onReorder}
            isUnified
          />
        </div>
      )}
      <div className={styles.channelDivider} />
      {channels.map(([key, state]) => (
        <ChannelItem
          key={key}
          account={state.account}
          enabled={state.enabled}
          muteCheck={rainbowTabs}
          onToggle={() => onToggle(key)}
          onNavigate={onSwitchAccount}
        />
      ))}
      <div className={styles.barSpacer} />
      {onViewModeChange && (
        <div className={styles.viewModeGroup}>
          <Tooltip content={withShortcut('Grid view', 'view_toggle')}>
            <button
              className={`${styles.viewModeBtn}${viewMode === 'grid' ? ` ${styles.viewModeBtnActive}` : ''}`}
              onClick={() => onViewModeChange('grid')}
              aria-pressed={viewMode === 'grid'}
              aria-label="Grid view"
            >
              <Icon name="square.grid.2x2" size={12} />
            </button>
          </Tooltip>
          <Tooltip content={withShortcut('List view', 'view_toggle')}>
            <button
              className={`${styles.viewModeBtn}${viewMode === 'list' ? ` ${styles.viewModeBtnActive}` : ''}`}
              onClick={() => onViewModeChange('list')}
              aria-pressed={viewMode === 'list'}
              aria-label="List view"
            >
              <Icon name="list.bullet" size={12} />
            </button>
          </Tooltip>
        </div>
      )}
      <Tooltip content={withShortcut('Show only unread items', 'unread_toggle')}>
        <button
          className={`${styles.unreadToggle} ${unreadOnly ? styles.unreadToggleActive : ''}`}
          onClick={onToggleUnread}
          aria-pressed={unreadOnly}
          aria-label="Show only unread items"
        >
          <span className={styles.toggleTrack}>
            <span className={styles.toggleThumb} />
          </span>
          <span className={styles.unreadToggleLabel}>Unread</span>
        </button>
      </Tooltip>
    </div>
  );
}
