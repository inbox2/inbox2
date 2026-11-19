// Domain migration tab (docs/plans/mail-import.md): an owner or admin imports
// every mailbox on this domain from Google Workspace or Microsoft 365. Each
// person's history lands private to them. The source is connected once for the
// whole organization on Disk's import screen (the same connection imports their
// drives); asking again after the MX switch brings only what arrived since.
import { useCallback, useEffect, useState } from 'react';
import Spinner from '../../components/Spinner';
import { MgmtButton } from '../../components/management';
import api from '../../lib/api';
import diskApi from '../../lib/disk/api';
import log from '../../lib/log';
import admin from './adminShared.module.css';
import styles from './DomainSettingsPage.module.css';
import consoleCss from './console.module.css';
import css from './MailImportPanel.module.css';

const LABEL = { google: 'Google Workspace', microsoft: 'Microsoft 365' };
const IN_FLIGHT = ['queued', 'running'];
const POLL_MS = 5000;
const PILL = {
  queued: [consoleCss.pillPlain, 'Waiting'],
  running: [consoleCss.pillPlain, 'Importing'],
  paused: [consoleCss.pillBad, 'Paused'],
  done: [consoleCss.pillOk, 'Done'],
  cancelled: [consoleCss.pillPlain, 'Cancelled'],
};

const n = (v) => (v || 0).toLocaleString();

function countsLine(c = {}) {
  const parts = [`${n(c.imported)} imported`];
  if (c.duplicate) parts.push(`${n(c.duplicate)} already here`);
  if (c.skipped) parts.push(`${n(c.skipped)} skipped`);
  if (c.failed) parts.push(`${n(c.failed)} failed`);
  return parts.join(' · ');
}

export default function MailImportPanel({ domain }) {
  const orgKey = domain.key;
  const [data, setData] = useState(null); // { imports, sources }
  const [unmatched, setUnmatched] = useState(null);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState(null);

  const load = useCallback(() => api.listMailImports(orgKey)
    .then(setData)
    .catch((e) => { log.warn('MailImport', e?.message || e); setError(e?.status === 403 ? 'Only owners and admins can migrate mail.' : "Couldn't load the migration."); }),
  [orgKey]);

  useEffect(() => {
    let cancelled = false;
    Promise.resolve().then(() => { if (!cancelled) load(); });
    return () => { cancelled = true; };
  }, [load]);

  const imports = (data?.imports || []).filter((i) => i.domain === domain.domain);
  const working = imports.some((i) => IN_FLIGHT.includes(i.state));
  useEffect(() => {
    if (!working) return undefined;
    const t = setInterval(load, POLL_MS);
    return () => clearInterval(t);
  }, [working, load]);

  const run = async (fn) => {
    setBusy(true); setError(null);
    try { await fn(); await load(); } catch (e) {
      log.warn('MailImport', e?.message || e);
      setError(e?.message || 'Something went wrong.');
    } finally { setBusy(false); }
  };

  const connect = (provider) => run(async () => {
    const { authorize_url: url } = await diskApi.importConnect(orgKey, provider, 'org');
    window.location.assign(url);
  });
  const start = (provider) => run(async () => {
    const res = await api.startMailImport(orgKey, provider, domain.domainKey);
    setUnmatched(res.unmatched || []);
  });

  if (!data && !error) return <div className={styles.loading}><Spinner size={22} color="var(--violet)" /></div>;

  const sources = (data?.sources || []).filter((s) => s.offered);

  return (
    <div className={styles.section}>
      <h2 className={styles.sectionTitle}>Move mail to inbox2</h2>
      <p className={admin.settingsHint}>
        Imports every mailbox on {domain.domain} from Google Workspace or Microsoft 365: inbox, sent and archived mail
        with attachments, but not Spam, Trash or drafts. Each person&apos;s history is private to them. Nobody else on the
        team sees it, admins included. New mail after the switch goes to the domain&apos;s inbox as usual.
      </p>
      <p className={admin.settingsHint}>
        Run it while MX still points at the old provider, switch MX, then run it again to bring in what arrived during
        the switch. Each person needs a mailbox here first.
      </p>

      {sources.length === 0 && data && (
        <p className={admin.settingsHint}>No source is set up for this organization yet (see the migration guide).</p>
      )}
      {sources.map((s) => {
        const started = imports.some((i) => i.provider === s.provider);
        return (
          <div key={s.provider} className={css.source}>
            <span className={css.sourceName}>{LABEL[s.provider] || s.provider}</span>
            {s.connected ? (
              <MgmtButton onClick={() => start(s.provider)} disabled={busy || working}>
                {started ? 'Run again' : 'Import mailboxes'}
              </MgmtButton>
            ) : (
              <MgmtButton variant="glass" onClick={() => connect(s.provider)} disabled={busy}>
                Connect for the organization
              </MgmtButton>
            )}
          </div>
        );
      })}

      {unmatched?.length > 0 && (
        <p className={admin.settingsError}>
          No mailbox here for {unmatched.join(', ')}. Add one for each person, then run it again.
        </p>
      )}
      {error && <p className={admin.settingsError}>{error}</p>}

      {imports.length > 0 && (
        <ul className={css.list}>
          {imports.map((i) => {
            const [pillClass, pillLabel] = PILL[i.state] || [];
            return (
              <li key={i.id} className={css.row}>
                <div className={css.who}>
                  <span className={css.email}>{i.source_email}</span>
                  <span className={css.counts}>{countsLine(i.counts)}</span>
                  {i.error && <span className={css.error}>{i.error}</span>}
                  {i.failed?.length > 0 && (
                    <details className={css.failed}>
                      <summary>Why {i.failed.length} failed</summary>
                      <ul>{i.failed.map((f) => <li key={f.id}>{f.reason}</li>)}</ul>
                    </details>
                  )}
                </div>
                <span className={`${consoleCss.pill} ${pillClass}`}>{pillLabel}</span>
                <div className={css.actions}>
                  {['paused', 'cancelled'].includes(i.state) && (
                    <MgmtButton variant="glass" onClick={() => run(() => api.resumeMailImport(orgKey, i.id))} disabled={busy}>Resume</MgmtButton>
                  )}
                  {IN_FLIGHT.includes(i.state) && (
                    <MgmtButton variant="glass" onClick={() => run(() => api.cancelMailImport(orgKey, i.id))} disabled={busy}>Cancel</MgmtButton>
                  )}
                </div>
              </li>
            );
          })}
        </ul>
      )}
    </div>
  );
}
