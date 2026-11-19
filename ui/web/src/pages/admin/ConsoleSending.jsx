import { useState, useEffect, useCallback } from 'react';
import { Link } from 'react-router';
import Skeleton from '../../components/Skeleton';
import DnsRecordsTable from '../../components/DnsRecordsTable/DnsRecordsTable';
import { MgmtButton, MgmtField, MgmtConfirm, MgmtMeter } from '../../components/management';
import useAuth from '../../hooks/useAuth';
import api from '../../lib/api';
import log from '../../lib/log';
import { consolePath } from '../../lib/consoleHost';
import { isAdminRole } from '../../lib/orgRoles';
import TokenList from './TokenList';
import styles from './console.module.css';
import keys from './ApiKeysPage.module.css';
import own from './TokenList.module.css';

/* /console/sending — the sending API (docs/ESP.md): this month's use, sending
 * keys, send-only domains and the send log. Owners and admins only; the API
 * refuses everyone else. */

const KEY_COPY = {
  placeholder: 'e.g. Order confirmations',
  create: 'Create key',
  created: (name) => `Key “${name}” created. Copy it now, you won’t see it again.`,
  empty: 'Create a key for your application.',
  remove: 'Revoke',
  removeTitle: 'Revoke this key?',
  removeBody: (name) => `“${name}” stops working right away.`,
};

// Esp::Delivery statuses → pill. Anything not listed is still on its way.
const STATUS_PILL = { delivered: 'pillOk', bounced: 'pillBad', failed: 'pillBad', complained: 'pillBad', deferred: 'pillWarn' };

function fmtWhen(iso) {
  return new Date(iso).toLocaleString(undefined, { month: 'short', day: 'numeric', hour: '2-digit', minute: '2-digit' });
}

// Keyed by organization: a switch starts the page empty, and answers for the last one are dropped.
export default function ConsoleSending() {
  const { currentOrg } = useAuth();
  return <Page key={currentOrg?.id} currentOrg={currentOrg} />;
}

function Page({ currentOrg }) {
  const isAdmin = isAdminRole(currentOrg?.role);
  const orgId = isAdmin ? currentOrg?.id : null; // members load nothing: the API refuses them
  const [error, setError] = useState('');
  const [usage, setUsage] = useState(null);
  const [sendKeys, setSendKeys] = useState(null);
  const [domains, setDomains] = useState(null);
  const [emails, setEmails] = useState(null);
  const [total, setTotal] = useState(0);
  const [page, setPage] = useState(1);
  const [domainName, setDomainName] = useState('');
  const [busy, setBusy] = useState(false);
  const [removing, setRemoving] = useState(null);

  const fail = useCallback((e) => {
    log.warn('Sending', e?.message || e);
    setError(e?.data?.errors?.[0]?.message || e?.message || 'That did not work. Try again.');
  }, []);

  useEffect(() => {
    if (!orgId) return;
    api.espUsage(orgId).then((r) => setUsage(r.usage)).catch(fail);
    api.listEspKeys(orgId).then((r) => setSendKeys(r.keys)).catch(fail);
    api.listEspDomains(orgId).then((r) => setDomains(r.domains)).catch(fail);
    api.listEspEmails(orgId).then((r) => { setEmails(r.emails); setTotal(r.meta.total); }).catch(fail);
  }, [orgId, fail]);

  const createKey = useCallback(async (name) => {
    const r = await api.createEspKey(orgId, name);
    setSendKeys((prev) => [...(prev || []), r.key]);
    return r.token;
  }, [orgId]);
  const revokeKey = useCallback(async (k) => {
    await api.revokeEspKey(orgId, k.id);
    setSendKeys((prev) => prev.filter((x) => x.id !== k.id));
  }, [orgId]);

  const replaceDomain = (d) => setDomains((prev) => prev.map((x) => (x.id === d.id ? d : x)));
  const run = async (fn) => {
    setBusy(true);
    setError('');
    try { await fn(); } catch (e) { fail(e); } finally { setBusy(false); }
  };
  const addDomain = () => run(async () => {
    const r = await api.createEspDomain(orgId, domainName.trim());
    setDomains((prev) => [...(prev || []), r.domain]);
    setDomainName('');
  });
  const checkDomain = (d) => run(async () => replaceDomain((await api.verifyEspDomain(orgId, d.id)).domain));
  const removeDomain = () => run(async () => {
    await api.deleteEspDomain(orgId, removing.id);
    setDomains((prev) => prev.filter((x) => x.id !== removing.id));
    setRemoving(null);
  });
  const loadMore = () => run(async () => {
    const r = await api.listEspEmails(orgId, page + 1);
    setEmails((prev) => [...prev, ...r.emails]);
    setPage(page + 1);
  });

  const onPlan = usage ? usage.allowance > 0 : true;

  if (currentOrg && !isAdmin) {
    return (
      <>
        <div className={styles.pageHead}><h1 className={styles.pageTitle}>Sending API</h1></div>
        <div className={styles.card}><div className={own.body}><p className={own.note}>Only owners and admins manage the sending API.</p></div></div>
      </>
    );
  }

  return (
    <>
      <div className={styles.pageHead}>
        <div>
          <div className={styles.pageEyebrow}>Developers</div>
          <h1 className={styles.pageTitle}>Sending API</h1>
          <p className={styles.pageSub}>Send mail from your own application.</p>
        </div>
      </div>
      {error && <p className={own.error} role="alert">{error}</p>}

      <div className={styles.card}>
        <div className={styles.cardHead}><h2 className={styles.cardTitle}>This month</h2></div>
        <div className={own.body}>
          {!usage ? <Skeleton variant="text" count={2} /> : onPlan ? (
            <>
              <p className={own.big}>{usage.used.toLocaleString()} of {usage.allowance.toLocaleString()} recipients mailed</p>
              <MgmtMeter value={usage.used / usage.allowance} />
            </>
          ) : (
            <p className={own.note}>
              The sending API is on paid plans. <Link className={own.link} to={consolePath('billing')}>See plans</Link>
            </p>
          )}
        </div>
      </div>

      <div className={`${styles.card} ${styles.mt}`}>
        <div className={styles.cardHead}><h2 className={styles.cardTitle}>Sending keys</h2></div>
        <TokenList items={sendKeys} onCreate={createKey} onRemove={revokeKey} copy={KEY_COPY} />
      </div>

      <div className={`${styles.card} ${styles.mt}`}>
        <div className={styles.cardHead}><h2 className={styles.cardTitle}>Send-only domains</h2></div>
        <div className={own.body}>
          <p className={own.note}>For a domain that keeps its mailboxes elsewhere.</p>
          <div className={keys.createRow}>
            <MgmtField
              className={keys.nameField}
              label="Domain"
              value={domainName}
              onChange={(e) => setDomainName(e.target.value)}
              placeholder="news.example.com"
              autoComplete="off"
              onKeyDown={(e) => { if (e.key === 'Enter' && domainName.trim()) addDomain(); }}
            />
            <MgmtButton variant="primary" onClick={addDomain} disabled={!domainName.trim() || busy}>Add domain</MgmtButton>
          </div>
          {domains === null ? <Skeleton variant="text" count={2} /> : domains.map((d) => (
            <div key={d.id} className={own.domain}>
              <div className={own.domainHead}>
                <span className={own.domainName}>{d.name}</span>
                <span className={`${styles.pill} ${d.status === 'verified' ? styles.pillOk : styles.pillWarn}`}>
                  {d.status === 'verified' ? 'Verified' : 'Waiting for DNS'}
                </span>
                <MgmtButton variant="ghost" onClick={() => checkDomain(d)} disabled={busy}>Check DNS</MgmtButton>
                <MgmtButton variant="ghost" onClick={() => setRemoving(d)}>Remove</MgmtButton>
              </div>
              <DnsRecordsTable
                records={d.records}
                apex={d.name}
                verified={(r) => (d.dns_checked_at ? !!d.dns_checks?.[r.type === 'CNAME' ? 'dkim' : 'dmarc'] : null)}
              />
            </div>
          ))}
        </div>
      </div>

      <div className={`${styles.card} ${styles.mt}`}>
        <div className={styles.cardHead}><h2 className={styles.cardTitle}>Sent mail</h2></div>
        {emails === null ? <div className={own.body}><Skeleton variant="text" count={3} /></div> : emails.length === 0 ? (
          <div className={own.body}><p className={own.note}>Nothing sent yet.</p></div>
        ) : (
          <>
            <table className={styles.tbl}>
              <thead><tr><th>To</th><th>Subject</th><th>Status</th><th className={styles.right}>Sent</th></tr></thead>
              <tbody>
                {emails.flatMap((m) => m.deliveries.map((d) => (
                  <tr key={`${m.id}-${d.recipient}`}>
                    <td className={own.mono}>{d.recipient}</td>
                    <td>{m.subject}</td>
                    <td><span className={`${styles.pill} ${styles[STATUS_PILL[d.status] || 'pillPlain']}`} title={d.response || undefined}>{d.status}</span></td>
                    <td className={`${styles.right} ${styles.num}`}>{fmtWhen(m.created_at)}</td>
                  </tr>
                )))}
              </tbody>
            </table>
            {emails.length < total && (
              <div className={own.more}><MgmtButton variant="ghost" onClick={loadMore} disabled={busy}>Show more</MgmtButton></div>
            )}
          </>
        )}
      </div>

      <MgmtConfirm
        open={!!removing}
        title="Remove this domain?"
        message={removing ? `Your application can no longer send from ${removing.name}.` : ''}
        confirmLabel="Remove"
        danger
        busy={busy}
        onConfirm={removeDomain}
        onClose={() => setRemoving(null)}
      />
    </>
  );
}
