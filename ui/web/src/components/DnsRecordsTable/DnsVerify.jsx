import { useState, useEffect, useCallback } from 'react';
import Icon from '../Icon';
import Spinner from '../Spinner';
import { MgmtButton } from '../management';
import DnsRecordsTable from './DnsRecordsTable';
import api from '../../lib/api';
import log from '../../lib/log';
import styles from './DnsVerify.module.css';

// Maps a required record to the dns_checks key that verifies it, so each row can
// show its own ✓/pending independent of the others. Type/host based so it doesn't
// depend on the serializer's record ordering.
function recordCheckKey(rec) {
  if (rec.type === 'MX') return 'mx';
  if (rec.type === 'CNAME') return 'dkim';
  if (rec.type === 'TXT') return rec.host?.startsWith('_dmarc') ? 'dmarc' : 'spf';
  return null;
}

const POLL_MS = 10_000; // auto re-check cadence while DNS propagates
const MAX_POLLS = 60;   // give up after ~10 min on a single view (resumes on return)

// Shared "add these records → Verify now" body used by every surface that asks a
// customer to set up DNS: the console Verify modal, the onboarding wizard, and the
// domain settings DNS tab. Owns the load + verify + live per-row check logic so the
// three never drift. Surrounding chrome (modal / wizard card / tab) stays with each
// caller; only the records table, propagation notice and verify action live here.
//
// orgKey: the org's public id/key (used for both the load and verify calls).
// domainKey: when set, load/verify target this specific (non-primary) domain via
//   the per-domain endpoints. Omit to act on the org's primary domain.
// records: pass them in if the caller already loaded them (onboarding); otherwise
//   they're fetched on mount.
// initialChecks: a dns_checks map to seed per-row status (settings, for an already
//   verified domain).
// onVerified(status): called once verification passes.
// onResult(res): called after every verify with the raw { verified, checks, status }.
// renderActions({ verify, verifying }): custom action area; defaults to a primary
//   block "Verify now" button.
export default function DnsVerify({
  orgKey,
  domainKey = null,
  records: initialRecords,
  initialChecks = null,
  onVerified,
  onResult,
  renderActions,
}) {
  // When the caller already has the records (onboarding) we use them directly;
  // otherwise they're fetched on mount into `fetched`. Either way we still fetch
  // the DNS payload once to learn the `provider` (one-click path) and the domain
  // status (to resume the waiting state).
  const [fetched, setFetched] = useState(null);
  const [provider, setProvider] = useState(null);
  const records = initialRecords || fetched || [];
  const loading = !initialRecords && fetched === null;
  const [checks, setChecks] = useState(initialChecks);
  const [verifying, setVerifying] = useState(false);
  // `waiting` = auto re-checking every 10s while DNS propagates; `exhausted` = we
  // gave up after the cap (show a manual re-check). Persisted per-domain so
  // closing + reopening the page resumes the wait.
  const [waiting, setWaiting] = useState(false);
  const [exhausted, setExhausted] = useState(false);
  const [ready, setReady] = useState(false); // domain already verified/receiving mail
  const [, setAttempts] = useState(0); // poll counter (state, not a ref — read via the updater)
  const waitKey = `inbox2:dnsWait:${domainKey || orgKey || ''}`;

  const runCheck = useCallback(async () => {
    try {
      return domainKey ? await api.verifyDomainDns(orgKey, domainKey) : await api.verifyOrgDns(orgKey);
    } catch (e) {
      log.warn('DnsVerify', `Verify failed: ${e?.message || e}`);
      return null;
    }
  }, [orgKey, domainKey]);

  const clearWait = useCallback(() => { try { localStorage.removeItem(waitKey); } catch { /* ignore */ } }, [waitKey]);

  const beginWaiting = useCallback(() => {
    setExhausted(false);
    setAttempts(0);
    try { localStorage.setItem(waitKey, '1'); } catch { /* ignore */ }
    setWaiting(true);
  }, [waitKey]);

  // Apply a check/apply result: update rows, finish on green, else start waiting.
  const applyResult = useCallback((res) => {
    if (!res) return;
    setChecks(res.checks || null);
    onResult?.(res);
    if (res.verified) {
      setWaiting(false); setExhausted(false); setReady(true); clearWait();
      onVerified?.(res.status);
    } else {
      beginWaiting();
    }
  }, [onResult, onVerified, beginWaiting, clearWait]);

  // Load records + provider + status; resume the wait if we left mid-propagation.
  useEffect(() => {
    if (!orgKey) return undefined;
    let cancelled = false;
    const load = domainKey ? api.getDomainDns(orgKey, domainKey) : api.getOrgDns(orgKey);
    load
      .then((d) => {
        if (cancelled) return;
        setFetched(d.records || []);
        setProvider(d.provider || null);
        const isReady = ['verified', 'receiving_mail'].includes(d.status);
        setReady(isReady);
        let stored = false;
        try { stored = !!localStorage.getItem(waitKey); } catch { /* ignore */ }
        if (isReady) clearWait();
        else if (stored) { setAttempts(0); setWaiting(true); }
      })
      .catch((e) => log.warn('DnsVerify', `DNS load failed: ${e?.message || e}`));
    return () => { cancelled = true; };
  }, [orgKey, domainKey, waitKey, clearWait]);

  // Auto re-check every 10s while `waiting`; stop on green or after the cap.
  useEffect(() => {
    if (!waiting) return undefined;
    const id = setInterval(async () => {
      const res = await runCheck();
      if (res) { setChecks(res.checks || null); onResult?.(res); }
      if (res?.verified) { setWaiting(false); clearWait(); onVerified?.(res.status); return; }
      setAttempts((n) => {
        const next = n + 1;
        if (next >= MAX_POLLS) { setWaiting(false); setExhausted(true); clearWait(); }
        return next;
      });
    }, POLL_MS);
    return () => clearInterval(id);
  }, [waiting, runCheck, onResult, onVerified, clearWait]);

  const verify = useCallback(async () => {
    setVerifying(true);
    setExhausted(false);
    const res = await runCheck();
    setVerifying(false);
    applyResult(res);
  }, [runCheck, applyResult]);

  // true → live, false → checked-and-missing, null → not yet checked.
  const rowStatus = (rec) => {
    if (!checks) return null;
    const k = recordCheckKey(rec);
    if (!k || !(k in checks)) return null;
    return checks[k] === true;
  };

  const domainName = records.find((r) => r.type === 'MX')?.host || records[0]?.host || '';
  const busy = verifying || waiting;
  // Already verified? Don't offer to auto-configure — the records are live.
  const verified = ready || (checks && ['mx', 'spf', 'dmarc', 'dkim'].every((k) => checks[k] === true));

  return (
    <>
      {provider === 'cloudflare' && domainKey && !verified && (
        <CloudflareAutoConfig
          orgKey={orgKey}
          domainKey={domainKey}
          domainName={domainName}
          onApplied={applyResult}
        />
      )}
      {waiting ? (
        <div className={styles.waiting} role="status">
          <Spinner size={14} color="var(--m-violet, var(--accent-bento-violet))" />
          <span>Waiting for DNS. We check again every 10 seconds…</span>
        </div>
      ) : exhausted ? (
        <div className={styles.notice} role="alert">
          <Icon name="exclamationmark.triangle.fill" size={15} />
          <span>Some records aren’t live yet. Check them above, then verify again in a few minutes.</span>
        </div>
      ) : null}
      <div className={styles.table}>
        {loading ? (
          <div className={styles.loading}><Spinner size={20} color="var(--m-violet, var(--accent-bento-violet))" /></div>
        ) : (
          <DnsRecordsTable records={records} verified={(r) => rowStatus(r)} />
        )}
      </div>
      {renderActions
        ? renderActions({ verify, verifying: busy })
        : (
          <MgmtButton variant="primary" block onClick={verify} disabled={busy || loading}>
            {busy ? 'Checking…' : 'Verify now'}
          </MgmtButton>
        )}
    </>
  );
}

// This domain is on Cloudflare → offer to write all four records automatically
// with a scoped API token. The token is sent once, used server-side, and never
// stored. On success the parent's rows update + verify.
//
// Deep-link to Cloudflare's "create token" form PRE-FILLED with the permissions
// we need — DNS · Edit (write the records) + Zone · Read (find the zone by name).
// (Cloudflare user-token template URL format, see their API docs.) The user just
// reviews → Create Token → copies it.
const CF_TOKEN_PERMISSIONS = encodeURIComponent(JSON.stringify([
  { key: 'dns', type: 'edit' },
  { key: 'zone', type: 'read' },
]));
const CF_TOKEN_URL = `https://dash.cloudflare.com/profile/api-tokens?permissionGroupKeys=${CF_TOKEN_PERMISSIONS}&accountId=*&zoneId=all&name=${encodeURIComponent('inbox2 mail DNS')}`;

function CloudflareAutoConfig({ orgKey, domainKey, domainName, onApplied }) {
  const [open, setOpen] = useState(false);
  const [token, setToken] = useState('');
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState(null);
  const [done, setDone] = useState(false);

  const apply = async () => {
    const t = token.trim();
    if (!t) return;
    setBusy(true); setError(null);
    try {
      const res = await api.configureCloudflareDns(orgKey, domainKey, t);
      setToken('');
      setDone(true);
      onApplied(res); // updates the per-row ✓/✗ + kicks off auto re-checking
    } catch (e) {
      setError(e?.message || 'Couldn’t set up Cloudflare. Check the token and try again.');
    } finally {
      setBusy(false);
    }
  };

  return (
    <div className={styles.cf}>
      <div className={styles.cfHead}>
        <span className={styles.cfBadge}><Icon name="bolt.fill" size={13} /> Cloudflare</span>
        <span className={styles.cfTitle}>This domain is on Cloudflare. Set it up in one click.</span>
        {!open && !done && (
          <MgmtButton variant="primary" size="sm" onClick={() => setOpen(true)}>Auto-configure</MgmtButton>
        )}
      </div>

      {done ? (
        <p className={styles.cfDone}>
          <Icon name="checkmark.circle.fill" size={14} /> We added the records to Cloudflare. We’ll check them again as they go live.
        </p>
      ) : open && (
        <div className={styles.cfBody}>
          <ol className={styles.cfSteps}>
            <li>
              <a href={CF_TOKEN_URL} target="_blank" rel="noreferrer" className={styles.cfLink}>
                Create an API token <Icon name="arrow.up.right" size={11} />
              </a>.{' '}
              The form opens <strong>pre-filled</strong> with DNS edit access. Click <strong>Create Token</strong> and copy it.
            </li>
            <li>Paste it below. We write the MX, SPF, DMARC and DKIM records for <code>{domainName}</code> (DKIM stays DNS-only), then verify.</li>
          </ol>
          <div className={styles.cfRow}>
            <input
              type="password"
              className={styles.cfInput}
              placeholder="Cloudflare API token"
              value={token}
              onChange={(e) => setToken(e.target.value)}
              onKeyDown={(e) => { if (e.key === 'Enter') apply(); }}
              autoComplete="off"
              spellCheck={false}
            />
            <MgmtButton variant="primary" onClick={apply} disabled={busy || !token.trim()}>
              {busy ? 'Applying…' : 'Apply & verify'}
            </MgmtButton>
          </div>
          {error && (
            <p className={styles.cfError} role="alert">
              <Icon name="exclamationmark.triangle.fill" size={13} /> {error}
            </p>
          )}
          <p className={styles.cfNote}>We use your token once to add the records. We don’t store it.</p>
        </div>
      )}
    </div>
  );
}
