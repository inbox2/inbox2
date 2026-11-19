import { useState, useEffect, useCallback } from 'react';
import Spinner from '../../components/Spinner';
import { MgmtButton } from '../../components/management';
import api from '../../lib/api';
import { apiBaseUrl } from '../../lib/apiOrigin';
import formatBytes from '../../lib/formatBytes';
import styles from './console.module.css';
import own from './DataExportCard.module.css';

const IN_FLIGHT = ['queued', 'running'];
const POLL_MS = 5000;
const PILL = {
  queued: [styles.pillPlain, 'Starting'],
  running: [styles.pillPlain, 'In progress'],
  ready: [styles.pillOk, 'Ready'],
  failed: [styles.pillBad, 'Failed'],
  expired: [styles.pillPlain, 'Expired'],
};

const day = (iso) => new Date(iso).toLocaleDateString(undefined, { day: 'numeric', month: 'short' });

/* "Export your data": the org's mail (mbox per domain) and calendars (.ics) as
 * one zip, built in the background. Shows the latest export and polls while it
 * builds. Admin-only: a 403 hides the card. */
export default function DataExportCard({ orgId }) {
  const [latest, setLatest] = useState(undefined); // undefined = loading, null = none
  const [hidden, setHidden] = useState(false);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState(null);

  const load = useCallback(() => {
    if (!orgId) return;
    api.listDataExports(orgId)
      .then((d) => setLatest(d.data_exports?.[0] || null))
      .catch((e) => { if (e.status === 403) setHidden(true); else setError(e.message); });
  }, [orgId]);

  useEffect(() => { load(); }, [load]);

  const building = IN_FLIGHT.includes(latest?.status);
  useEffect(() => {
    if (!building) return undefined;
    const t = setInterval(load, POLL_MS);
    return () => clearInterval(t);
  }, [building, load]);

  const start = async () => {
    setBusy(true);
    setError(null);
    try {
      const d = await api.startDataExport(orgId);
      setLatest(d.data_export);
    } catch (e) {
      setError(e.message);
    } finally {
      setBusy(false);
    }
  };

  if (hidden) return null;

  const [pillClass, pillLabel] = PILL[latest?.status] || [];
  // ponytail: a plain link, so the browser streams the zip to disk. It rides the
  // session cookie, which covers the web console (desktop opens the console in
  // the browser). A bearer-only dev session can't use it.
  const downloadUrl = latest && `${apiBaseUrl()}/orgs/${orgId}/exports/${latest.id}/download`;

  return (
    <section className={`${styles.card} ${own.card}`}>
      <div className={styles.cardHead}>
        <h2 className={styles.cardTitle}>Export your data</h2>
        {pillLabel && <span className={`${styles.pill} ${pillClass}`}>{pillLabel}</span>}
      </div>
      <div className={own.body}>
        <p className={own.text}>All your mail and calendars in one zip file.</p>

        {latest === undefined && !error && <Spinner size={16} color="#2f7ad6" />}
        {building && <p className={own.text}>Big inboxes take a while. You can leave this page.</p>}
        {latest?.status === 'ready' && (
          <p className={own.text}>{formatBytes(latest.byte_size)}. Download it before {day(latest.expires_at)}.</p>
        )}
        {latest?.status === 'failed' && <p className={own.error}>{latest.error || 'The export failed.'}</p>}
        {latest?.status === 'expired' && <p className={own.text}>The download expired. Start a new one.</p>}
        {error && <p className={own.error}>{error}</p>}

        <div className={own.actions}>
          {latest?.status === 'ready' && (
            <MgmtButton as="a" href={downloadUrl} download>Download</MgmtButton>
          )}
          {latest !== undefined && !building && (
            <MgmtButton variant={latest?.status === 'ready' ? 'glass' : 'primary'} onClick={start} disabled={busy}>
              {busy ? 'Starting…' : latest?.status === 'failed' ? 'Try again' : latest ? 'New export' : 'Start export'}
            </MgmtButton>
          )}
        </div>
      </div>
    </section>
  );
}
