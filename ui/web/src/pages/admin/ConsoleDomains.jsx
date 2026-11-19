import { useState } from 'react';
import { useNavigate, Link } from 'react-router';
import Icon from '../../components/Icon';
import Spinner from '../../components/Spinner';
import useAuth from '../../hooks/useAuth';
import useAdminData from '../../hooks/useAdminData';
import useBilling from '../../hooks/useBilling';
import DnsVerify from '../../components/DnsRecordsTable/DnsVerify';
import { MgmtModal, MgmtButton } from '../../components/management';
import { fmt } from '../../lib/format';
import { initialsDataUri } from '../../lib/initialsIcon';
import api from '../../lib/api';
import log from '../../lib/log';
import styles from './console.module.css';
import admin from './adminShared.module.css';
import { consolePath } from '../../lib/consoleHost';

/* Domains view — one row per connected domain: status, DNS record marks, its
 * slice of the pool (users/emails/unread), Manage (per-domain settings) and
 * Verify/Remove. Healthy records are quiet checks; only failures take color. */

const DNS_RECORDS = [
  { label: 'MX', key: 'mx' },
  { label: 'SPF', key: 'spf' },
  { label: 'DKIM', key: 'dkim' },
  { label: 'DMARC', key: 'dmarc' },
];

export default function ConsoleDomains() {
  const navigate = useNavigate();
  const { organizations, currentOrg, refreshAccount } = useAuth();
  const { domains, loading, refresh, markActive } = useAdminData(organizations);

  const billingOrgId = currentOrg?.id || organizations?.[0]?.id;
  const { atDomainLimit, domainUsageText } = useBilling(billingOrgId, domains.length, refresh);

  // { orgKey, domainKey, name } — DNS verification popup / removal confirm.
  const [verifyTarget, setVerifyTarget] = useState(null);
  const [removeTarget, setRemoveTarget] = useState(null);
  const [removeBusy, setRemoveBusy] = useState(false);

  const confirmRemove = async () => {
    if (!removeTarget) return;
    setRemoveBusy(true);
    try {
      await api.removeDomain(removeTarget.orgKey, removeTarget.domainKey);
      await refreshAccount?.();
      setRemoveTarget(null);
    } catch (e) {
      log.warn('Console', `Remove domain failed: ${e?.message || e}`);
    } finally {
      setRemoveBusy(false);
    }
  };

  const openSettings = (d) => navigate(consolePath(`domains/${d.domainSlug || d.slug}`));

  return (
    <>
      <div className={styles.pageHead}>
        <div>
          <div className={styles.pageEyebrow}>{domainUsageText || 'Domains'}</div>
          <h1 className={styles.pageTitle}>Domains</h1>
          <p className={styles.pageSub}>
            Each domain gets one inbox for the whole team.
          </p>
        </div>
        <div className={styles.pageActions}>
          <MgmtButton
            variant="primary"
            onClick={() => (atDomainLimit ? navigate(consolePath('billing')) : navigate('/onboarding'))}
          >
            <Icon name={atDomainLimit ? 'sparkles' : 'plus'} size={14} />
            {atDomainLimit ? 'Upgrade to add domains' : 'Add domain'}
          </MgmtButton>
        </div>
      </div>

      <div className={styles.card}>
        {loading && domains.length === 0 ? (
          <div className={styles.cardLoading}><Spinner size={18} color="#2f7ad6" /></div>
        ) : domains.length === 0 ? (
          <div className={admin.domainsEmpty}>
            <Icon name="globe" size={26} />
            <p className={admin.domainsEmptyTitle}>No domains connected yet</p>
            <p className={admin.domainsEmptySub}>Connect your domain to get all its mail in one team inbox.</p>
            <MgmtButton variant="glass" className={admin.domainsEmptyBtn} onClick={() => navigate('/onboarding')}>
              <Icon name="plus" size={14} /> Connect a domain
            </MgmtButton>
          </div>
        ) : (
          <table className={styles.tbl}>
            <thead>
              <tr>
                <th>Domain</th>
                <th>Status</th>
                <th>DNS</th>
                <th className={styles.right}>Users</th>
                <th className={styles.right}>Emails</th>
                <th className={styles.right}>Unread</th>
                <th></th>
              </tr>
            </thead>
            <tbody>
              {[...domains].sort((a, b) => a.name.localeCompare(b.name)).map((d) => {
                const pending = d.status === 'pending';
                return (
                  <tr key={d.key} className={styles.rowLink} onClick={() => openSettings(d)}>
                    <td>
                      <span className={styles.domainCell}>
                        <img className={styles.favicon} src={d.iconUrl || initialsDataUri(d.name)} alt="" />
                        {d.name}
                        {d.isDefault && <span className={`${styles.pill} ${styles.pillPlain}`}>Default</span>}
                      </span>
                    </td>
                    <td>
                      <span className={[
                        styles.pill,
                        pending ? styles.pillWarn : d.locked ? styles.pillBad : styles.pillOk,
                      ].join(' ')}>
                        {pending ? 'Pending DNS' : d.locked ? 'Locked' : 'Active'}
                      </span>
                    </td>
                    <td>
                      <span className={styles.dnsMarks}>
                        {DNS_RECORDS.map(({ label, key }) => {
                          const state = d.dnsChecks?.[key];
                          const cls = state === true ? styles.dnsMarkOk : state === false ? styles.dnsMarkBad : styles.dnsMarkNa;
                          const status = state === true ? 'live' : state === false ? 'missing' : 'not checked';
                          return <span key={label} className={`${styles.dnsMark} ${cls}`} title={`${label}: ${status}`}>{label}</span>;
                        })}
                      </span>
                    </td>
                    <td className={`${styles.right} ${styles.num}`}>{fmt(d.users)}</td>
                    <td className={`${styles.right} ${styles.num}`}>{pending ? '—' : fmt(d.emails)}</td>
                    <td className={`${styles.right} ${styles.num}`}>{pending ? '—' : fmt(d.unread)}</td>
                    <td className={styles.right} onClick={(e) => e.stopPropagation()}>
                      <span className={styles.ruleActions}>
                        {pending ? (
                          <MgmtButton
                            variant="primary"
                            size="sm"
                            onClick={() => setVerifyTarget({ orgKey: d.orgKey, domainKey: d.domainKey, name: d.name })}
                          >
                            Verify DNS
                          </MgmtButton>
                        ) : (
                          <MgmtButton as={Link} to={`/${d.domainSlug || d.slug}/mail/inbox`} variant="glass" size="sm">
                            Open
                          </MgmtButton>
                        )}
                        <MgmtButton variant="glass" size="sm" onClick={() => openSettings(d)}>
                          <Icon name="gear" size={12} /> Manage
                        </MgmtButton>
                        <button
                          type="button"
                          className={styles.rowRemove}
                          onClick={() => setRemoveTarget({ orgKey: d.orgKey, domainKey: d.domainKey, name: d.name })}
                          title={`Remove ${d.name}`}
                          aria-label={`Remove ${d.name}`}
                        >
                          <Icon name="trash" size={13} />
                        </button>
                      </span>
                    </td>
                  </tr>
                );
              })}
            </tbody>
          </table>
        )}
      </div>

      {verifyTarget && (
        <MgmtModal open onClose={() => setVerifyTarget(null)} width={780}>
          <h2 className={admin.modalTitle}>Verify {verifyTarget.name}</h2>
          <p className={admin.modalSub}>
            Add these records at your DNS provider, then verify. We keep checking on our own too.
          </p>
          <DnsVerify
            orgKey={verifyTarget.orgKey}
            domainKey={verifyTarget.domainKey || null}
            onVerified={() => {
              if (verifyTarget.domainKey) refreshAccount?.(); else markActive(verifyTarget.orgKey);
              setVerifyTarget(null);
            }}
            renderActions={({ verify, verifying }) => (
              <div className={admin.modalActions}>
                <MgmtButton variant="glass" className={admin.modalCancel} onClick={() => setVerifyTarget(null)}>Close</MgmtButton>
                <MgmtButton variant="primary" onClick={verify} disabled={verifying}>
                  {verifying ? 'Checking…' : 'Verify now'}
                </MgmtButton>
              </div>
            )}
          />
        </MgmtModal>
      )}

      {removeTarget && (
        <MgmtModal open onClose={() => (removeBusy ? null : setRemoveTarget(null))} width={520}>
          <h2 className={admin.modalTitle}>Remove {removeTarget.name}?</h2>
          <p className={admin.modalSub}>
            Mail for <strong>{removeTarget.name}</strong> stops arriving in the domain&apos;s inbox.
            You can add it back later.
          </p>
          <div className={admin.modalActions}>
            <MgmtButton variant="glass" className={admin.modalCancel} onClick={() => setRemoveTarget(null)} disabled={removeBusy}>
              Cancel
            </MgmtButton>
            <MgmtButton variant="danger" onClick={confirmRemove} disabled={removeBusy}>
              {removeBusy ? 'Removing…' : 'Remove domain'}
            </MgmtButton>
          </div>
        </MgmtModal>
      )}
    </>
  );
}
