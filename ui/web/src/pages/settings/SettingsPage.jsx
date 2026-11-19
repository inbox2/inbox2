import { useState, useEffect, useMemo } from 'react';
import { useParams, useNavigate, useSearchParams } from 'react-router';
import syncManager from '../../lib/sync-manager';
import useAuth from '../../hooks/useAuth';
import AccountSettings from './AccountSettings';
import ThemeSettings from './ThemeSettings';
import PreferencesSettings from './PreferencesSettings';
import RulesSettings from './org/RulesSettings';
import SpacesSettings from './org/SpacesSettings';
import TriageLabelsSettings from './org/TriageLabelsSettings';
import WebhooksSettings from './org/WebhooksSettings';
import SsoSettings from './org/SsoSettings';
import SpamSettings from './org/SpamSettings';
import LogViewerSettings from './org/LogViewerSettings';
import AIFeaturesSettings from './AIFeaturesSettings';
import TriageSyncSettings from './TriageSyncSettings';
import LocalRulesSettings from './LocalRulesSettings';
import McpConnectionsSettings from './McpConnectionsSettings';
import IntegrationsSettings from './IntegrationsSettings';
import SchedulingSettings from './SchedulingSettings';
import MailClientsSettings from './MailClientsSettings';
import PrivacySettings from './PrivacySettings';
import AboutSettings from './AboutSettings';
import AddAccountModal from '../../components/AddAccountModal/AddAccountModal';
import AccountTracking from '../../components/AccountTracking/AccountTracking';
import ConfirmDialog from '../../components/ConfirmDialog/ConfirmDialog';
import Icon from '../../components/Icon';
import Button from '../../components/Button/Button';
import DotMatrix from '../../components/DotMatrix';
import useDevMode from '../../hooks/useDevMode';
import DevModeIndicator from '../../components/DevModeIndicator/DevModeIndicator';
import log from '../../lib/log';
import { isTauri } from '../../lib/tauri';
import { providerIcon } from '../../lib/providerTypes';
import useAccountStatusStore from '../../stores/accountStatusStore';
import styles from './settings.module.css';
import { ALL_SECTIONS } from './settingsSections';
import { isAdminRole } from '../../lib/orgRoles';


// Tabs that render their own panel(s) internally (multi-section stacks), are
// full-bleed (logs), or need the full content width (theme grid) — everything
// else gets wrapped in a single panel centrally.
const SELF_PANELED = new Set(['preferences', 'accounts', 'theme', 'logs', 'ai-features', 'spam', 'triage', 'scheduling']);
// Sections that lay their panels out in a multi-column grid need the wider column.
const WIDE_SECTIONS = new Set(['preferences', 'accounts', 'ai-features', 'theme', 'spam', 'triage', 'scheduling']);

// Human label for the raw engine status where the raw value reads poorly.
const STATUS_LABELS = { needs_reauth: 'needs sign-in' };

function ConnectedAccountsSection({ devMode }) {
  const navigate = useNavigate();
  const [searchParams, setSearchParams] = useSearchParams();
  const [modalOpen, setModalOpen] = useState(false);
  // The account being reconnected ({ provider, email }) — scopes the modal to
  // that provider and surfaces/login-hints the mailbox so the right one is
  // re-authenticated.
  const [reconnectTarget, setReconnectTarget] = useState(null);
  const [accounts, setAccounts] = useState([]);
  const [resyncing, setResyncing] = useState({});
  // Account pending removal — gates the destructive delete behind a confirm.
  const [confirmRemove, setConfirmRemove] = useState(null);

  useEffect(() => {
    if (!isTauri()) return;
    (async () => {
      try {
        const { invoke } = await import('@tauri-apps/api/core');
        const list = await invoke('list_external_accounts');
        setAccounts(list);
      } catch { /* not in tauri */ }
    })();
  }, [modalOpen]);

  // Live status: the engine pushes per-account status transitions, so a sync
  // failure flips the row to needs_reauth/error (and recovery clears it)
  // without a reload.
  useEffect(() => {
    if (!isTauri()) return undefined;
    return syncManager.on('account-status', (p) => {
      if (!p?.accountKey) return;
      setAccounts(prev => prev.map(a =>
        a.key === p.accountKey ? { ...a, status: p.status, error_message: p.error ?? null } : a
      ));
    });
  }, []);

  // Shared tail for every connect/reconnect path: the account row now exists with
  // fresh credentials, but its stored status still reads `disconnected`/`needs_reauth`
  // until a sync round-trips and emits a status event. Kick off that sync (which
  // connects the engine adapter and emits `connected` on success — without it the
  // background poller skips the still-`Disconnected` account, so nothing ever clears
  // the red state until a restart) and optimistically flip the row + sidebar dot to
  // connected so every reconnect indicator clears right away.
  const markConnectedAndSync = async (result) => {
    const { invoke } = await import('@tauri-apps/api/core');
    // Flip the indicators BEFORE kicking off the sync: `start_sync` resolves only
    // when the initial sync finishes (folder-by-folder — tens of seconds on a big
    // mailbox), so awaiting it first meant the row and the channel tile kept their
    // red "reconnect" state long after the account was re-credentialed. A failure
    // still corrects them — the engine emits needs_reauth/error on the live channel.
    const connected = { ...result, status: 'connected', error_message: null };
    setAccounts(prev => [...prev.filter(a => a.key !== connected.key), connected]);
    useAccountStatusStore.getState().setStatus(connected.key, 'connected');
    setReconnectTarget(null);
    await invoke('start_sync', { accountKey: result.key });
  };

  const handleSubmit = async (params) => {
    if (!isTauri()) throw new Error('Connect this account from the desktop app');
    const { invoke } = await import('@tauri-apps/api/core');
    const result = await invoke('add_external_account', { request: params });
    await markConnectedAndSync(result);
  };

  // OAuth (Gmail/Microsoft) success. useOAuthFlow has already called
  // add_external_account, so the account exists — run the same connect tail the
  // IMAP form does. Without this the OAuth reconnect never triggered a sync, so
  // the engine stayed `Disconnected` and the row/dot stayed red until restart.
  const handleOAuthConnected = (result) => {
    if (!isTauri() || !result?.key) return undefined;
    return markConnectedAndSync(result);
  };

  const handleRemove = async (key) => {
    if (!isTauri()) return;
    const { invoke } = await import('@tauri-apps/api/core');
    await invoke('remove_external_account', { accountKey: key });
    setAccounts(prev => prev.filter(a => a.key !== key));
    window.dispatchEvent(new CustomEvent('external-account-removed', { detail: { key } }));
    setConfirmRemove(null);
  };

  const handleReconnect = (acct) => {
    // The account stays in place: completing the flow upserts by email+provider
    // (same key), replaces the stored credentials, and re-registers the live
    // adapter — history, folders, and settings survive the reconnect.
    setReconnectTarget({ provider: acct.provider_type, email: acct.email_address });
    setModalOpen(true);
  };

  // Deep link from the global re-auth alert: ?reconnect=<accountKey> arms the
  // reconnect flow for that account as soon as the list is loaded. Deferred a
  // tick so the URL cleanup + modal open don't set state inside the effect body.
  useEffect(() => {
    const key = searchParams.get('reconnect');
    if (!key || accounts.length === 0) return undefined;
    const acct = accounts.find(a => a.key === key);
    const timer = setTimeout(() => {
      setSearchParams(prev => {
        const next = new URLSearchParams(prev);
        next.delete('reconnect');
        return next;
      }, { replace: true });
      if (acct) handleReconnect(acct);
    }, 0);
    return () => clearTimeout(timer);
  // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [accounts, searchParams]);

  // Dev-mode: clear the account's sync cursors and re-fetch everything. Backfills
  // fields added after the first sync (e.g. has_attachment). Dedupes by Message-ID.
  const handleResync = async (key) => {
    if (!isTauri()) return;
    setResyncing(prev => ({ ...prev, [key]: true }));
    try {
      const { invoke } = await import('@tauri-apps/api/core');
      await invoke('resync_account', { accountKey: key });
    } catch (err) {
      log.error('settings', 'resync failed', err);
    } finally {
      setResyncing(prev => ({ ...prev, [key]: false }));
    }
  };

  // Logging into an MX domain is the API-backed inbox2 flow, distinct from
  // offline external channels. The modal handles the sign-in inline (reusing the
  // onboarding auth UX) and invokes this once authenticated, so we just land the
  // user in their workspace.
  const handleConnectMx = () => {
    navigate('/');
  };

  return (
    <>
      <div className={styles.prefGrid}>
      <section className={styles.settingsPanel}>
      <h2 className={styles.sectionTitle}>Connected accounts</h2>
      <p className={styles.sectionDesc}>
        Sign in to your inbox2 domain or connect other mailboxes. Each one shows in the sidebar.
      </p>
      {devMode && (
        <div className={styles.devBanner}>
          <Icon name="terminal" size={12} />
          Developer mode. Reconnect accounts to update OAuth scopes.
        </div>
      )}
      {accounts.length > 0 && (
        <div className={styles.accountList}>
          {accounts.map(acct => {
            const needsReauth = acct.status === 'needs_reauth';
            // ponytail: no reauth banner — the row's status badge + Reconnect button already say it
            const failing = acct.status === 'error';
            return (
              <div key={acct.key} className={styles.accountItem}>
                <div className={styles.accountRow}>
                  <img
                    src={providerIcon(acct.provider_type)}
                    alt="" width="24" height="24"
                  />
                  <div className={styles.accountRowInfo}>
                    <span className={styles.accountRowName}>{acct.display_name}</span>
                    <span className={styles.accountRowEmail}>{acct.email_address}</span>
                  </div>
                  <span className={styles.accountRowStatus} data-status={acct.status}>{STATUS_LABELS[acct.status] || acct.status}</span>
                  {(needsReauth || devMode) && (
                    <button className={styles.accountRowReconnect} onClick={() => handleReconnect(acct)}>
                      Reconnect
                    </button>
                  )}
                  {devMode && (
                    <button
                      className={styles.accountRowResync}
                      onClick={() => handleResync(acct.key)}
                      disabled={resyncing[acct.key]}
                    >
                      {resyncing[acct.key] ? 'Resyncing…' : 'Resync'}
                    </button>
                  )}
                  <Button variant="danger" onClick={() => setConfirmRemove(acct)}>Remove</Button>
                </div>
                <AccountTracking account={acct} />
                {failing && (
                  <div className={styles.accountBanner} data-kind="error">
                    <Icon name="exclamationmark.triangle" size={12} />
                    <span className={styles.accountBannerText}>
                      {acct.error_message || "Couldn't get new mail. We'll try again."}
                    </span>
                  </div>
                )}
              </div>
            );
          })}
        </div>
      )}
      <div className={styles.panelFooter}>
        <Button onClick={() => setModalOpen(true)}>Add account</Button>
      </div>
      <AddAccountModal
        open={modalOpen}
        onClose={() => { setModalOpen(false); setReconnectTarget(null); }}
        onSubmit={handleSubmit}
        onGmailConnected={handleOAuthConnected}
        onMicrosoftConnected={handleOAuthConnected}
        onConnectMx={handleConnectMx}
        initialProvider={reconnectTarget?.provider}
        reconnectEmail={reconnectTarget?.email}
      />
      </section>
      <section className={styles.settingsPanel}>
        <PrivacySettings />
      </section>
      </div>
      <ConfirmDialog
        open={!!confirmRemove}
        title="Remove this account?"
        message={
          confirmRemove
            ? `${confirmRemove.email_address || confirmRemove.display_name} leaves this device with its mail, calendar and attachments. The mailbox itself keeps everything.`
            : ''
        }
        confirmLabel="Remove account"
        onConfirm={() => handleRemove(confirmRemove.key)}
        onCancel={() => setConfirmRemove(null)}
      />
    </>
  );
}

export default function SettingsPage() {
  const { orgSlug: rawOrgSlug } = useParams();
  const { currentOrgSlug, organizations, logout } = useAuth();
  const navigate = useNavigate();

  const handleLogout = async () => {
    await logout();
    navigate('/login');
  };
  // ?section=<key> deep-links a tab (e.g. the re-auth alert jumps straight to
  // Connected accounts).
  const [searchParams] = useSearchParams();
  const [active, setActive] = useState(() => searchParams.get('section') || 'preferences');
  const isDesktop = isTauri();
  const devMode = useDevMode();

  // Resolve a real org id. The URL can be /null/settings in local standalone mode
  // (ChromeBar builds `/${orgSlug}/settings` with a null slug → the string "null"),
  // which is truthy and would fetch /orgs/null/* → 401. Fall back to the authed
  // org slug, else null so org panels are hidden and their loaders skip.
  const orgId = (rawOrgSlug && rawOrgSlug !== 'null' && rawOrgSlug !== 'undefined')
    ? rawOrgSlug
    : (currentOrgSlug || null);

  // Role in the org these settings are for (not just the app's current org).
  const settingsOrg = (organizations || []).find(o => o.slug === orgId || o.id === orgId);
  const orgIsAdmin = isAdminRole(settingsOrg?.role);
  const mailClientsOn = !!settingsOrg?.mail_clients_enabled;
  const sections = useMemo(() =>
    ALL_SECTIONS.filter(s => (!s.desktop || isDesktop) && (!s.hideDesktop || !isDesktop) && (!s.inConsole || !isDesktop)
      && (!s.org || !!orgId) && (!s.admin || orgIsAdmin) && (!s.mailClients || mailClientsOn)),
    [isDesktop, orgId, orgIsAdmin, mailClientsOn]
  );

  // Effective section: if the selected one is hidden (e.g. an org tab with no
  // org), fall back to a safe default so we never render a panel that 401s.
  const activeKey = sections.some(s => s.key === active) ? active : 'preferences';

  const groups = useMemo(() =>
    [...new Set(sections.map(s => s.group))],
    [sections]
  );

  const renderContent = () => {
    switch (activeKey) {
      // Personal
      case 'preferences': return <PreferencesSettings />;
      case 'account': return <AccountSettings />;
      case 'theme': return <ThemeSettings />;
      // Workspace
      case 'spaces': return <SpacesSettings orgId={orgId} />;
      case 'triage-labels': return <TriageLabelsSettings orgId={orgId} />;
      case 'rules': return <RulesSettings orgId={orgId} />;
      case 'scheduling': return <SchedulingSettings orgId={orgId} />;
      case 'mail-clients': return <MailClientsSettings key={orgId} orgId={orgId} />;
      // Channels
      case 'accounts': return <ConnectedAccountsSection devMode={devMode} />;
      case 'webhooks': return <WebhooksSettings orgId={orgId} />;
      case 'sso': return <SsoSettings orgId={orgId} />;
      // Intelligence
      case 'enrichment': return <IntegrationsSettings />;
      case 'ai-features': return <AIFeaturesSettings />;
      case 'triage': return <TriageSyncSettings />;
      case 'local-rules': return <LocalRulesSettings />;
      case 'mcp-apps': return <McpConnectionsSettings />;
      // Security & Compliance
      case 'spam': return <SpamSettings orgId={orgId} />;
      case 'logs': return <LogViewerSettings />;
      case 'about': return <AboutSettings />;
      default: return <AccountSettings />;
    }
  };

  return (
    <div className={styles.settingsPage}>
      <DotMatrix pixelGrid />
      <div className={styles.settingsSidebar}>
        <button className={styles.settingsBack} onClick={() => window.history.length > 1 ? navigate(-1) : navigate(orgId ? `/${orgId}/mail` : '/')}>
          &larr; Back
        </button>
        {groups.map(group => (
          <div key={group}>
            <div className={styles.settingsNavGroupLabel}>{group}</div>
            {sections.filter(s => s.group === group).map(section => (
              <button
                key={section.key}
                className={`${styles.settingsNavItem} ${activeKey === section.key ? styles.settingsNavItemActive : ''}`}
                onClick={() => setActive(section.key)}
              >
                <Icon name={section.icon} size={14} className={styles.settingsNavIcon} />
                {section.label}
              </button>
            ))}
          </div>
        ))}
        {devMode && <DevModeIndicator className={styles.devIndicator} />}
        <div className={styles.settingsSidebarSpacer} />
        {/* Web only: desktop manages its session via the native shell. */}
        {!isDesktop && (
          <button type="button" className={styles.settingsLogout} onClick={handleLogout}>
            <Icon name="rectangle.portrait.and.arrow.right" size={14} className={styles.settingsNavIcon} />
            Log out
          </button>
        )}
      </div>
      <div className={`${styles.settingsContent} ${activeKey === 'logs' ? styles.settingsContentFull : ''}`}>
        <div className={`${styles.settingsContentInner} ${WIDE_SECTIONS.has(activeKey) ? styles.settingsContentWide : ''}`}>
          {SELF_PANELED.has(activeKey)
            ? renderContent()
            : <section className={styles.settingsPanel}>{renderContent()}</section>}
        </div>
      </div>
    </div>
  );
}
