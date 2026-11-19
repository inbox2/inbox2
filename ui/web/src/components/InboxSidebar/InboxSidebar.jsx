import NavGroup, { NavItem } from '../NavGroup';
import SyncStatusBar from '../SyncStatusBar/SyncStatusBar';
import NextMeeting from '../Calendar/NextMeeting';
import { isTauri } from '../../lib/tauri';
import { QUADRANTS, PRIORITY_URGENT, PRIORITY_IMPORTANT } from '../../lib/priority';
import { CONV_STATUS } from '../../lib/conversationStatus';
import { PROVIDER, META_PROVIDERS, META_CHANNEL, META_KIND, channelLabel } from '../../lib/providerTypes';
import styles from '../../styles/layout.module.css';

// Channel-appropriate sub-views for Meta accounts: split by surface/kind rather
// than the mail Spam/Trash folders (which have no provider-side equivalent). The
// query layer (useInboxConversations) narrows by the `channel` / `kind` filters.
const META_SUBVIEWS = {
  [PROVIDER.WHATSAPP]: [],
  [PROVIDER.MESSENGER]: [
    { name: 'Messages', icon: 'paperplane', filters: [{ field: 'channel', value: META_CHANNEL.MESSENGER }] },
    { name: 'Comments', icon: 'bubble.left.fill', filters: [{ field: 'channel', value: META_CHANNEL.FACEBOOK }] },
  ],
  [PROVIDER.INSTAGRAM]: [
    { name: 'DMs', icon: 'paperplane', filters: [{ field: 'kind', value: META_KIND.DM }] },
    { name: 'Comments', icon: 'bubble.left.fill', filters: [{ field: 'kind', value: META_KIND.COMMENT }] },
    { name: 'Mentions', icon: 'at', filters: [{ field: 'kind', value: META_KIND.MENTION }] },
  ],
};

const TRIAGE_LABEL_MAP = Object.fromEntries(
  Object.values(QUADRANTS).map(q => [`inbox2/${q.label}`, q])
);
const HIDDEN_LABELS = new Set([
  `inbox2/${PRIORITY_URGENT}`, `inbox2/${PRIORITY_IMPORTANT}`,
  'CATEGORY_PERSONAL', 'CATEGORY_SOCIAL', 'CATEGORY_PROMOTIONS',
  'CATEGORY_UPDATES', 'CATEGORY_FORUMS',
]);

export default function InboxSidebar({
  folderViews, systemViews, personalViews, activeView, onSwitchView,
  activeAccountKey, tags, syncFolders,
  onNavigateSettings,
  syncStatus, activeAccount, onOpenConsole,
  onRefresh, isSyncing,
  activeLabelKeys, onToggleLabel,
  selectedTags, onToggleTag, onClearTags,
  onFocusZone,
  allAccounts = [], activeUnifiedKey,
}) {
  const metaProvider = META_PROVIDERS.includes(activeAccount?.provider_type) ? activeAccount.provider_type : null;
  const inboxView = folderViews[0];
  // Title = the account/domain behind the current view. MX domains have
  // activeAccountKey=null and are keyed by activeUnifiedKey in allAccounts, so
  // resolve there (not activeAccount) to name domain tabs too.
  const titleAccount = allAccounts.find(a => a.key === activeUnifiedKey) || activeAccount;

  return (
    <aside className={styles.sidebar} onMouseDownCapture={onFocusZone}>
      <div className={styles.sidebarBody}>
        <NavGroup icon="tray.fill" title={channelLabel(titleAccount) || 'Folders'}>
          {metaProvider ? (
            <>
              {/* The synthetic inbox; "All" once a channel has sub-surfaces, else "Messages". */}
              {inboxView && (
                <NavItem
                  icon={inboxView.icon || 'tray'}
                  label={META_SUBVIEWS[metaProvider]?.length ? 'All' : 'Messages'}
                  active={activeView?.id === inboxView.id}
                  onClick={() => onSwitchView(inboxView)}
                />
              )}
              {(META_SUBVIEWS[metaProvider] || []).map(sv => (
                <NavItem key={sv.name} icon={sv.icon} label={sv.name}
                  active={activeView?.name === sv.name}
                  onClick={() => onSwitchView({ name: sv.name, filters: sv.filters })} />
              ))}
              {/* Archived applies everywhere; no Spam/Trash — no provider-side equivalent. */}
              <NavItem icon="archivebox" label="Archived"
                active={activeView?.name === 'Archived'}
                onClick={() => onSwitchView({ name: 'Archived', filters: [{ field: 'status', value: CONV_STATUS.ARCHIVED }] })} />
            </>
          ) : (
            <>
              {folderViews.map(v => (
                <NavItem
                  key={v.id}
                  icon={v.icon || 'tray'}
                  label={v.name}
                  active={activeView?.id === v.id}
                  onClick={() => onSwitchView(v)}
                />
              ))}
              <NavItem icon="archivebox" label="Archived"
                active={activeView?.name === 'Archived'}
                onClick={() => onSwitchView({ name: 'Archived', filters: [{ field: 'status', value: CONV_STATUS.ARCHIVED }] })} />
              <NavItem icon="nosign" label="Spam"
                active={activeView?.name === 'Spam'}
                onClick={() => onSwitchView({ name: 'Spam', filters: [{ field: 'status', value: CONV_STATUS.SPAM }] })} />
              <NavItem icon="trash" label="Trash"
                active={activeView?.name === 'Trash'}
                onClick={() => onSwitchView({ name: 'Trash', filters: [{ field: 'status', value: CONV_STATUS.TRASH }] })} />
            </>
          )}
        </NavGroup>
        {(systemViews.length > 0 || personalViews.length > 0) && (
          <NavGroup icon="line.3.horizontal.decrease" title="Views">
            {systemViews.map(v => (
              <NavItem key={v.id} icon={v.icon || 'tray'} label={v.name} active={activeView?.id === v.id} onClick={() => onSwitchView(v)} />
            ))}
            {personalViews.map(v => (
              <NavItem key={v.id} icon={v.icon || 'line.3.horizontal.decrease'} label={v.name} active={activeView?.id === v.id} onClick={() => onSwitchView(v)} />
            ))}
          </NavGroup>
        )}
        {(() => {
          if (!activeAccountKey) {
            if (tags.length === 0) return null;
            return (
              <NavGroup icon="tag.fill" title="Labels"
                action={selectedTags?.size > 0 ? (
                  <button type="button" className={styles.listTitleClear} onClick={onClearTags}>Clear</button>
                ) : null}>
                {tags.map(t => (
                  <NavItem key={t.id} color={t.color} icon={t.private ? 'lock.fill' : undefined} label={t.name}
                    active={selectedTags?.has(t.name)}
                    onClick={() => onToggleTag?.(t.name)} />
                ))}
              </NavGroup>
            );
          }
          const allLabels = syncFolders.filter(f => !f.well_known_role && !HIDDEN_LABELS.has(f.provider_name));
          const triageLabels = allLabels.filter(f => TRIAGE_LABEL_MAP[f.provider_name]);
          const otherLabels = allLabels.filter(f => !TRIAGE_LABEL_MAP[f.provider_name]);
          if (triageLabels.length === 0 && otherLabels.length === 0) return null;
          return (
            <NavGroup icon="tag.fill" title="Labels">
              {triageLabels.map(f => {
                const triage = TRIAGE_LABEL_MAP[f.provider_name];
                return (
                  <NavItem key={f.key} color={triage.color} label={triage.label} active={activeLabelKeys?.has(f.key)}
                    onClick={() => onToggleLabel?.({ key: f.key, quadrantKey: triage.key })} />
                );
              })}
              {otherLabels.map(f => {
                // flags stores the provider label ID as JSON array, e.g. ["Label_123"] or ["INBOX"]
                const labelId = (() => { try { const ids = JSON.parse(f.flags || '[]'); return ids[0] || f.key; } catch { return f.key; } })();
                return (
                  <NavItem key={f.key} color="var(--text-muted)" label={f.provider_name} active={activeView?.name === `label:${f.provider_name}`}
                    onClick={() => onSwitchView({ name: `label:${f.provider_name}`, filters: [{ field: 'gmail_label', value: labelId, folderKey: f.key }] })} />
                );
              })}
            </NavGroup>
          );
        })()}
        {!isTauri() && (
          <NavGroup icon="list.bullet.rectangle" title="Workflow">
            <NavItem icon="arrow.triangle.branch" label="Rules" onClick={onNavigateSettings} />
            <NavItem icon="tag" label="Tags" onClick={onNavigateSettings} />
            <NavItem icon="person.2" label="Team" onClick={onNavigateSettings} />
          </NavGroup>
        )}
      </div>
      {isTauri() && (
        <div className={styles.sidebarFooter}>
          <NextMeeting />
          <SyncStatusBar
            status={syncStatus}
            lastSyncAt={activeAccount?.last_connected_at}
            onOpenConsole={onOpenConsole}
            onRefresh={onRefresh}
            isSyncing={isSyncing}
          />
        </div>
      )}
    </aside>
  );
}
