import { useState, useRef, useCallback, useMemo } from 'react';
import { useParams, useNavigate, useSearchParams } from 'react-router';
import Icon from '../../components/Icon';
import Spinner from '../../components/Spinner';
import DnsVerify from '../../components/DnsRecordsTable/DnsVerify';
import { MgmtConfirm, MgmtButton } from '../../components/management';
import DeliverabilityPanel from './DeliverabilityPanel';
import TrackingPanel from './TrackingPanel';
import E2eePanel from './E2eePanel';
import MailImportPanel from './MailImportPanel';
import SharedAddressesPanel from './SharedAddressesPanel';
import useAuth from '../../hooks/useAuth';
import { resolveWorkspace, defaultDomainOf } from '../../lib/workspace';
import { initialsDataUri } from '../../lib/initialsIcon';
import api from '../../lib/api';
import log from '../../lib/log';
import admin from './adminShared.module.css';
import styles from './DomainSettingsPage.module.css';
import { consolePath } from '../../lib/consoleHost';

/* Per-domain settings page reached from a domain card's gear. The URL slug is the
 * DOMAIN's own slug (/console/domains/:slug); we resolve it to (org, domain) from
 * the authenticated org list and operate on THAT domain — per-domain icon, DNS,
 * deliverability, encryption, and removal all target the specific domain. The
 * org-level brand (organization name + company logo) is editable only on the
 * default domain, which represents the org. A left side menu switches tabs. */

// receiving_mail | verified → active; anything else → pending (mirrors useAdminData).
function normStatus(s) {
  return s === 'receiving_mail' || s === 'verified' ? 'active' : 'pending';
}

// Build the settings model for one (org, domain). `key`/`orgKey` = the ORG id
// (org-scoped API base + org-level brand ops the panels call); `domainKey` = the
// specific domain for the per-domain endpoints. Domains have no display-name /
// logo column — those are org-level brand. Returns null when unresolved.
function toDomainModel(org, dom) {
  if (!org || !dom) return null;
  const isDefault = dom.name === org.domain;
  return {
    key: org.id,          // org id — panels read `.key` as the org key
    orgKey: org.id,
    domainKey: dom.id,    // the specific domain (per-domain endpoints)
    slug: dom.slug,
    name: dom.name,
    domain: dom.name,     // E2eePanel matches its record on this
    displayName: dom.name,
    isDefault,
    orgName: org.name,
    // Per-domain icon; the default domain falls back to the org icon (its tab does).
    iconUrl: dom.icon_url || (isDefault ? org.icon_url : null) || null,
    hasOwnIcon: !!dom.icon_url,
    logoUrl: org.logo_url || null,
    status: normStatus(dom.status),
    rawStatus: dom.status,
    dnsChecks: dom.dns_checks || null,
    locked: dom.locked || false,
    // Org-level: track member activity (powers the team-activity feed).
    activityTracking: org.activity_tracking_enabled !== false,
  };
}

const TABS = [
  { key: 'settings', label: 'Settings', icon: 'gear' },
  { key: 'addresses', label: 'Shared addresses', icon: 'at' },
  { key: 'dns', label: 'DNS', icon: 'globe' },
  { key: 'deliverability', label: 'Deliverability', icon: 'paperplane.fill' },
  { key: 'tracking', label: 'Open tracking', icon: 'eye' },
  { key: 'encryption', label: 'Encryption', icon: 'lock.fill' },
  { key: 'migration', label: 'Migration', icon: 'tray.and.arrow.down' },
  { key: 'advanced', label: 'Advanced', icon: 'wrench.fill' },
];
const TAB_KEYS = TABS.map((t) => t.key);

export default function DomainSettingsPage() {
  const { slug } = useParams();
  const navigate = useNavigate();
  const { organizations, loading: authLoading, refreshAccount } = useAuth();
  // Tab lives in the URL (?tab=dns) so every panel is deep-linkable — the MX
  // inbox banner links straight to .../settings?tab=dns, and back/forward work.
  const [searchParams, setSearchParams] = useSearchParams();
  const tabParam = searchParams.get('tab');
  const tab = TAB_KEYS.includes(tabParam) ? tabParam : 'settings';
  const setTab = useCallback((key) => {
    setSearchParams((prev) => { const p = new URLSearchParams(prev); p.set('tab', key); return p; });
  }, [setSearchParams]);

  // Resolve the domain slug → (org, domain) from the session org list. A domain
  // slug resolves to that domain; a bare org slug is org-level (domain=null), so
  // fall back to the org's default domain for display. No fetch needed — the org
  // list already carries every domain (icon/status/dns/e2ee) via DomainSerializer.
  const resolved = useMemo(() => {
    const { org, domain } = resolveWorkspace(organizations, slug);
    return toDomainModel(org, domain || defaultDomainOf(org));
  }, [organizations, slug]);
  // Local copy so panels can patch optimistically; re-seed (React's render-time
  // reset pattern) whenever the resolved domain changes — i.e. when the org list
  // refreshes after a name/icon change or a removal — so it can't go stale.
  const [domain, setDomain] = useState(resolved);
  const [seededFrom, setSeededFrom] = useState(resolved);
  if (resolved !== seededFrom) {
    setSeededFrom(resolved);
    setDomain(resolved);
  }
  const loading = authLoading && !domain;

  const patchDomain = useCallback((patch) => setDomain((d) => (d ? { ...d, ...patch } : d)), []);

  if (loading) {
    return (
      <div className={`${styles.page} management`}>
        <div className={styles.loading}><Spinner size={22} color="var(--violet)" /></div>
      </div>
    );
  }

  if (!domain) {
    return (
      <div className={`${styles.page} management`}>
        <div className={styles.loading}>
          <p>Domain not found.</p>
          <MgmtButton variant="primary" onClick={() => navigate(consolePath('domains'))}>Back to console</MgmtButton>
        </div>
      </div>
    );
  }

  return (
    <div className={`${styles.page} management`}>
      <header className={styles.head}>
        <button type="button" className={styles.back} onClick={() => navigate(consolePath('domains'))}>
          <Icon name="chevron.left" size={15} /> Console
        </button>
        <span className={styles.headIcon}>
          <img src={domain.iconUrl || initialsDataUri(domain.displayName || domain.domain)} alt="" />
        </span>
        <div className={styles.headText}>
          <h1 className={styles.headTitle}>{domain.name}</h1>
          <span className={styles.headDomain}>{domain.isDefault ? 'Default domain' : 'Domain'}</span>
        </div>
      </header>

      <div className={styles.body}>
        <div className={styles.sidebar}>
          <nav className={styles.menu} aria-label="Domain settings">
            {TABS.map((t) => (
              <button
                key={t.key}
                type="button"
                className={[styles.menuItem, tab === t.key ? styles.menuItemOn : ''].join(' ')}
                onClick={() => setTab(t.key)}
                aria-current={tab === t.key ? 'page' : undefined}
              >
                <Icon name={t.icon} size={15} /> {t.label}
              </button>
            ))}
          </nav>
        </div>

        <div className={styles.panel}>
          {tab === 'settings' && (
            <SettingsPanel domain={domain} onPatch={patchDomain} refreshAccount={refreshAccount} />
          )}
          {tab === 'dns' && <DnsPanel domain={domain} onPatch={patchDomain} refreshAccount={refreshAccount} />}
          {tab === 'addresses' && <SharedAddressesPanel key={domain.domainKey} domain={domain} />}
          {tab === 'deliverability' && <DeliverabilityPanel domain={domain} />}
          {tab === 'tracking' && <TrackingPanel domain={domain} />}
          {tab === 'encryption' && <E2eePanel domain={domain} />}
          {tab === 'migration' && <MailImportPanel domain={domain} />}
          {tab === 'advanced' && (
            <AdvancedPanel
              domain={domain}
              onRemoved={async () => {
                // Pull the now-deleted org out of the auth org list so /console's
                // useAdminData re-renders without it instead of showing a ghost card.
                await refreshAccount?.();
                navigate(consolePath('domains'));
              }}
            />
          )}
        </div>
      </div>
    </div>
  );
}

/* Per-domain square icon (all domains) + organization name & company logo (the
 * default domain only — these are org-wide brand). */
function SettingsPanel({ domain, onPatch, refreshAccount }) {
  const [name, setName] = useState(domain.orgName || '');
  const [tracking, setTracking] = useState(domain.activityTracking);
  const [busy, setBusy] = useState(null); // 'name' | 'icon' | 'logo' | 'tracking' | null
  const [error, setError] = useState(null);
  const iconRef = useRef(null);
  const logoRef = useRef(null);

  const anyBusy = busy !== null;
  const nameDirty = name.trim() && name.trim() !== (domain.orgName || '');
  const messageOf = (e, fallback) => e?.message || fallback;

  const saveName = async () => {
    if (!nameDirty) return;
    setBusy('name'); setError(null);
    try {
      const res = await api.updateOrg(domain.orgKey, { name: name.trim() });
      onPatch({ orgName: res.organization?.name || name.trim() });
      await refreshAccount?.();
    } catch (e) {
      log.warn('DomainSettings', `Name update failed: ${e?.message || e}`);
      setError(messageOf(e, 'Couldn’t save the name.'));
    } finally { setBusy(null); }
  };

  // Per-domain icon — every domain has its own (uploadDomainIcon → domains.icon_url).
  const uploadIcon = async (e) => {
    const file = e.target.files?.[0];
    if (!file) return;
    setBusy('icon'); setError(null);
    try {
      const res = await api.uploadDomainIcon(domain.orgKey, domain.domainKey, file);
      onPatch({ iconUrl: res.domain?.icon_url || null, hasOwnIcon: true });
      await refreshAccount?.(); // refresh the workspace tab icon
    } catch (err) {
      log.warn('DomainSettings', `Icon upload failed: ${err?.message || err}`);
      setError(messageOf(err, 'Icon upload failed.'));
    } finally { setBusy(null); }
  };

  const uploadLogo = async (e) => {
    const file = e.target.files?.[0];
    if (!file) return;
    setBusy('logo'); setError(null);
    try {
      const res = await api.uploadOrgLogo(domain.orgKey, file);
      onPatch({ logoUrl: res.organization?.logo_url || null });
    } catch (err) {
      log.warn('DomainSettings', `Logo upload failed: ${err?.message || err}`);
      setError(messageOf(err, 'Logo upload failed.'));
    } finally { setBusy(null); }
  };

  // Org-level activity tracking — optimistic flip, reverted on failure.
  const toggleTracking = async () => {
    const next = !tracking;
    setTracking(next);
    setBusy('tracking'); setError(null);
    try {
      await api.patch(`/orgs/${domain.orgKey}`, { activity_tracking_enabled: next });
      onPatch({ activityTracking: next });
      await refreshAccount?.();
    } catch (err) {
      setTracking(!next);
      log.warn('DomainSettings', `Activity-tracking update failed: ${err?.message || err}`);
      setError(messageOf(err, 'Couldn’t change activity tracking.'));
    } finally { setBusy(null); }
  };

  return (
    <div className={styles.section}>
      <h2 className={styles.sectionTitle}>Settings</h2>

      <div className={admin.modalField}>
        <span className={admin.modalLabel}>Square icon</span>
        <div className={admin.settingsAssetRow}>
          <span className={admin.settingsIconPreview}>
            <img src={domain.iconUrl || initialsDataUri(domain.name)} alt="" />
          </span>
          <div className={admin.settingsAssetActions}>
            <MgmtButton variant="ghost" size="sm" onClick={() => iconRef.current?.click()} disabled={anyBusy}>
              {busy === 'icon' ? 'Working…' : 'Upload'}
            </MgmtButton>
          </div>
        </div>
        <span className={admin.settingsHint}>
          {domain.hasOwnIcon
            ? 'This domain’s icon, shown on its workspace tab.'
            : domain.isDefault
              ? 'Uses the organization icon. Upload one to give this domain its own.'
              : 'Shows the domain’s initials. Upload an icon for its workspace tab.'}
        </span>
        <input ref={iconRef} type="file" accept="image/*" hidden onChange={uploadIcon} />
      </div>

      {/* Organization name + company logo are org-wide brand — editable only on the
          default domain, which stands in for the org. */}
      {domain.isDefault && (
        <>
          <label className={admin.modalField}>
            <span className={admin.modalLabel}>Organization name</span>
            <div className={admin.settingsNameRow}>
              <input
                className={admin.modalInput}
                value={name}
                onChange={(e) => setName(e.target.value)}
                placeholder={domain.name}
                onKeyDown={(e) => { if (e.key === 'Enter') saveName(); }}
              />
              <MgmtButton variant="primary" onClick={saveName} disabled={!nameDirty || anyBusy}>
                {busy === 'name' ? 'Saving…' : 'Save'}
              </MgmtButton>
            </div>
            <span className={admin.settingsHint}>Shown across the whole organization.</span>
          </label>

          <div className={admin.modalField}>
            <span className={admin.modalLabel}>Company logo</span>
            <div className={admin.settingsAssetRow}>
              {domain.logoUrl && (
                <span className={admin.settingsLogoPreview}>
                  <img src={domain.logoUrl} alt="" />
                </span>
              )}
              <div className={admin.settingsAssetActions}>
                <MgmtButton variant="ghost" size="sm" onClick={() => logoRef.current?.click()} disabled={anyBusy}>
                  {busy === 'logo' ? 'Working…' : 'Upload'}
                </MgmtButton>
              </div>
            </div>
            <span className={admin.settingsHint}>
              {domain.logoUrl
                ? 'The full brand logo, shown on your admin console and sign-in.'
                : 'No logo yet, so we show your name. Upload your logo for the admin console and sign-in.'}
            </span>
            <input ref={logoRef} type="file" accept="image/*" hidden onChange={uploadLogo} />
          </div>

          <div className={admin.modalField}>
            <span className={admin.modalLabel}>Activity tracking</span>
            <div className={admin.settingsAssetRow}>
              <button
                type="button"
                className={[styles.trackToggle, tracking ? '' : styles.trackToggleOff].join(' ')}
                onClick={toggleTracking}
                disabled={anyBusy}
                role="switch"
                aria-checked={tracking}
                aria-label="Activity tracking"
              />
              <span className={admin.settingsHint}>
                {tracking
                  ? 'On. Teammates’ recent activity shows in the team feed.'
                  : 'Off. We don’t record or show member activity.'}
              </span>
            </div>
          </div>

        </>
      )}

      {error && (
        <p className={admin.settingsError} role="alert">
          <Icon name="exclamationmark.triangle.fill" size={13} /> {error}
        </p>
      )}
    </div>
  );
}

/* DNS tab — the records to add at the registrar + a live "Verify now" (the shared
 * DnsVerify body, same as the console Verify modal and the onboarding wizard).
 * Deep-linked from the MX inbox banner (…/settings?tab=dns). The endpoint is
 * admin/owner-only server-side, mirroring the banner's client-side gate. */
function DnsPanel({ domain, onPatch, refreshAccount }) {
  // toDomainModel normalizes status to 'active'/'pending' and keeps the raw value
  // (verified/receiving_mail/pending_dns) on rawStatus — track the raw one here.
  const [rawStatus, setRawStatus] = useState(domain.rawStatus || domain.status);
  const ready = rawStatus === 'verified' || rawStatus === 'receiving_mail';

  const onResult = async (res) => {
    setRawStatus(res.status);
    const normalized = ['verified', 'receiving_mail'].includes(res.status) ? 'active' : 'pending';
    onPatch({ status: normalized, rawStatus: res.status, dnsChecks: res.checks || {} });
    await refreshAccount?.(); // clears the inbox MX-pending banner once verified
  };

  return (
    <div className={styles.section}>
      <div className={styles.dnsHead}>
        <h2 className={styles.sectionTitle}>DNS records</h2>
        <span className={[styles.dnsState, ready ? styles.dnsStateOk : styles.dnsStatePending].join(' ')}>
          <Icon name={ready ? 'checkmark.circle.fill' : 'clock.fill'} size={13} />
          {ready ? 'Verified' : 'Pending'}
        </span>
      </div>
      <p className={styles.dnsHint}>
        Add these records at your DNS provider for <strong>{domain.domain}</strong>, then verify.
        Propagation can take a few minutes.
      </p>

      <DnsVerify
        orgKey={domain.orgKey}
        domainKey={domain.domainKey}
        initialChecks={domain.dnsChecks || {}}
        onResult={onResult}
        renderActions={({ verify, verifying }) => (
          // Wrapper keeps the button its natural width — it's a direct child of
          // the flex-column .section, which would otherwise stretch it full-width.
          <div>
            <MgmtButton variant="primary" onClick={verify} disabled={verifying}>
              <Icon name={verifying ? 'arrow.triangle.2.circlepath' : 'checkmark.shield'} size={14} />
              {verifying ? 'Checking…' : 'Verify now'}
            </MgmtButton>
          </div>
        )}
      />
    </div>
  );
}

/* Danger zone — remove the domain (with a typed confirm for verified domains). */
function AdvancedPanel({ domain, onRemoved }) {
  const [confirm, setConfirm] = useState(false);
  const [busy, setBusy] = useState(false);
  const pending = domain.status === 'pending';

  const remove = async () => {
    setBusy(true);
    try {
      // Remove THIS domain only (not the org) — the org's default re-derives to
      // the next-oldest server-side. This is the whole reason the page is per-domain.
      await api.removeDomain(domain.orgKey, domain.domainKey);
      onRemoved();
    } catch (e) {
      log.warn('DomainSettings', `Remove domain failed: ${e?.message || e}`);
      setBusy(false);
      setConfirm(false);
    }
  };

  return (
    <div className={styles.section}>
      <h2 className={styles.sectionTitle}>Advanced</h2>
      <div className={styles.danger}>
        <div className={styles.dangerText}>
          <span className={styles.dangerTitle}>Remove this domain</span>
          <span className={styles.dangerDesc}>
            {pending
              ? 'It isn’t verified yet, so you lose nothing. You can reconnect anytime.'
              : 'Deletes the domain and all its mail, spaces and members for good.'}
          </span>
        </div>
        <MgmtButton variant="danger" onClick={() => setConfirm(true)}>
          <Icon name="trash" size={14} /> Remove domain
        </MgmtButton>
      </div>

      {confirm && (
        <MgmtConfirm
          open
          title="Remove domain?"
          message={pending
            ? `It isn’t verified yet, so you lose nothing.`
            : `${domain.displayName} and all its mail, spaces and members are deleted for good.`}
          confirmLabel="Remove domain"
          danger
          confirmText={pending ? undefined : domain.displayName}
          busy={busy}
          onConfirm={remove}
          onClose={() => setConfirm(false)}
        />
      )}
    </div>
  );
}
