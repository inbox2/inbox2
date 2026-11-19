import { useEffect, useRef, useState } from 'react';
import useAuth from '../../hooks/useAuth';
import api from '../../lib/api';
import { isTauri } from '../../lib/tauri';
import useUploadStore, { UPLOAD_STATE as U } from '../../stores/uploadStore';
import Button from '../../components/Button/Button';
import Icon from '../../components/Icon';
import FileTypeIcon from '../../components/FileTypeIcon';
import log from '../../lib/log';
import styles from './settings.module.css';

const ACTIVE = ['queued', 'running'];
const POLL_MS = 5000;

/* Bring old mail in: an .mbox file (Google Takeout writes one) goes up through the
 * Disk uploader to C:\ (resumable, straight to storage), then the server imports
 * it into one of your mailboxes, private to you (docs/plans/mail-import.md).
 * Web only, like the export beside it. */
export default function ImportMail({ onBusyChange }) {
  const { currentOrg } = useAuth();
  const orgId = currentOrg?.id;
  // The list and the org it belongs to: another org's answer shows nothing until this org's arrives.
  const [list, setList] = useState({ org: null, mailboxes: [], imports: [] });
  const mailboxes = list.org === orgId ? list.mailboxes : [];
  const imports = list.org === orgId ? list.imports : [];
  const [mailboxId, setMailboxId] = useState('');
  const [error, setError] = useState('');
  const fileRef = useRef(null);
  // The .mbox upload whose import has not started yet. Tagged with its mailbox in
  // the upload store, so leaving Settings mid-upload and coming back still starts it.
  // Only this org's: one left pending in another org starts when the person is back there.
  const upload = useUploadStore((s) => s.items.find((it) => it.orgId === orgId && it.mailboxId && !it.importStarted));
  const enabled = orgId && !isTauri() && currentOrg?.plan?.disk;

  // A response for an org the person has since switched away from is dropped.
  const orgRef = useRef(orgId);
  useEffect(() => { orgRef.current = orgId; }, [orgId]);
  const load = (org = orgId) => api.listMyMailImports(org).then((data) => {
    if (orgRef.current !== org) return;
    const boxes = data.mailboxes || [];
    setList({ org, mailboxes: boxes, imports: data.imports || [] });
    setMailboxId((id) => (boxes.some((m) => m.id === id) ? id : boxes[0]?.id || ''));
  });

  const [loadFailed, setLoadFailed] = useState(false);
  const reload = () => load().then(() => setLoadFailed(false)).catch((e) => {
    log.warn('MailImport', `list failed: ${e?.message || e}`);
    if (orgRef.current === orgId) setLoadFailed(true);
  });
  useEffect(() => {
    if (enabled) reload();
  }, [enabled, orgId]); // eslint-disable-line react-hooks/exhaustive-deps

  // Follow the server while an import runs.
  const running = imports.some((i) => ACTIVE.includes(i.state));
  useEffect(() => {
    if (!running) return undefined;
    const t = setInterval(() => load(orgId).catch(() => {}), POLL_MS);
    return () => clearInterval(t);
  }, [running, orgId]); // eslint-disable-line react-hooks/exhaustive-deps

  // One file at a time: no new file (and no export beside it) while one uploads or an import runs.
  const uploading = !!upload && upload.state !== U.DONE && upload.state !== U.ERROR && upload.state !== U.CANCELLED;
  const busy = uploading || running;
  useEffect(() => { onBusyChange?.(busy); }, [busy, onBusyChange]);

  // Hand the uploaded file to the server. The upload stays pending until the
  // server accepts it, so a failed start can be tried again from the same file.
  const [startFailed, setStartFailed] = useState(false);
  const start = (it) => api.startMyMailImport(it.orgId, it.mailboxId, it.nodeId)
    .then(() => { useUploadStore.getState().patch(it.id, { importStarted: true }); reload(); },
      (e) => { setError(e?.message || "The import didn't start."); setStartFailed(true); });
  const retry = () => { setError(''); setStartFailed(false); start(upload); };

  // The upload finished: start the import from the file now on C:\.
  useEffect(() => {
    if (!upload) return;
    // A failed upload stays pending (the Disk panel's Retry can still finish it); a cancelled one is let go.
    if (upload.state === U.CANCELLED) useUploadStore.getState().patch(upload.id, { importStarted: true });
    else if (upload.state === U.DONE && upload.nodeId) start(upload);
  }, [upload?.id, upload?.state]); // eslint-disable-line react-hooks/exhaustive-deps

  if (!enabled) return null;
  if (loadFailed && !mailboxes.length) {
    return (
      <div className={styles.importMail}>
        <div className={styles.exportRow}>
          <div>
            <span className={styles.tablePrimary}>Import mail</span>
            <span className={styles.settingsError}>Your mailboxes didn't load.</span>
          </div>
          <Button variant="secondary" className={styles.exportBtn} onClick={reload}>Try again</Button>
        </div>
      </div>
    );
  }
  if (!mailboxes.length) return null;

  const pick = async (e) => {
    const file = e.target.files?.[0];
    if (fileRef.current) fileRef.current.value = '';
    if (!file) return;
    setError('');
    setStartFailed(false);
    // One import upload at a time: a new file replaces one whose import never started.
    if (upload) useUploadStore.getState().patch(upload.id, { importStarted: true });
    try {
      const [{ default: diskApi, KEEP_BOTH }, { enqueue }] = await Promise.all([
        import('../../lib/disk/api'), import('../../lib/disk/upload'),
      ]);
      const { c_drive: drive } = await diskApi.drives(orgId);
      const [id] = await enqueue(orgId, drive.id, [{ file, relativePath: file.name }], { onConflict: KEEP_BOTH });
      useUploadStore.getState().patch(id, { mailboxId });
    } catch (err) {
      setError(err?.message || "The upload didn't start. Try again.");
    }
  };

  const act = (fn) => fn().then(() => reload(), (e) => setError(e?.message || "That didn't work. Try again."));
  const pct = upload?.size ? Math.floor((100 * upload.loaded) / upload.size) : 0;

  return (
    <div className={styles.importMail}>
      <div className={styles.exportRow}>
        <div className={styles.importMailHead}>
          <span className={styles.importMailIcons} aria-hidden="true">
            <img src="/channels/gmail.svg" alt="" width={22} height={22} />
            <FileTypeIcon name="mail.mbox" size={28} />
          </span>
          <div>
            <span className={styles.tablePrimary}>Import mail</span>
            <span className={styles.tableSecondary}>
              Add old mail from a Google Takeout or .mbox file. We skip spam, trash and drafts.
            </span>
          </div>
        </div>
        {mailboxes.length > 1 && (
          <select className={styles.tableSelect} value={mailboxId} onChange={(e) => setMailboxId(e.target.value)}
            aria-label="Mailbox to import into" disabled={busy}>
            {mailboxes.map((m) => <option key={m.id} value={m.id}>{m.email_address}</option>)}
          </select>
        )}
        <Button variant="secondary" className={styles.exportBtn} onClick={() => fileRef.current?.click()} disabled={busy}
          title={running ? 'Wait for the import to finish, or stop it.' : undefined}>
          <Icon name="arrow.up.circle.fill" size={14} /> Choose file
        </Button>
        <input ref={fileRef} type="file" accept=".mbox,application/mbox" onChange={pick} hidden />
      </div>
      {uploading && (
        <ImportProgress title={upload.name} detail={'Uploading to C:\\. Keep this page open.'} value={pct / 100} active />
      )}
      {error && <div className={styles.settingsError}>{error}</div>}
      {loadFailed && (
        <div className={styles.importMailRow}>
          <span className={styles.settingsError}>Your imports didn't load.</span>
          <Button variant="secondary" className={styles.exportBtn} onClick={reload}>Try again</Button>
        </div>
      )}
      {startFailed && upload?.state === U.DONE && (
        <Button variant="secondary" className={styles.exportBtn} onClick={retry}>Try again</Button>
      )}
      {imports.map((i) => (
        <div key={i.id} className={styles.importMailRow}>
          <ImportProgress title={i.source_email} detail={describe(i)} value={i.progress}
            active={ACTIVE.includes(i.state)} state={i.state} />
          {ACTIVE.includes(i.state) && (
            <Button variant="secondary" className={styles.exportBtn} onClick={() => act(() => api.cancelMyMailImport(orgId, i.id))}>Stop</Button>
          )}
          {i.state === 'paused' && i.resumable && (
            <Button variant="secondary" className={styles.exportBtn} onClick={() => act(() => api.resumeMyMailImport(orgId, i.id))}>Resume</Button>
          )}
        </div>
      ))}
    </div>
  );
}

/* A labelled bar: title and percentage over a thick fill. value is 0..1, or
 * null when the server can't tell (an import without a Disk file). */
function ImportProgress({ title, detail, value, active, state }) {
  const fillRef = useRef(null);
  const known = typeof value === 'number';
  const pct = known ? Math.round(value * 100) : null;
  useEffect(() => { fillRef.current?.style.setProperty('--import-pct', `${pct ?? 0}%`); }, [pct]);
  return (
    <div className={styles.importProgress} data-state={state}>
      <div className={styles.importProgressHead}>
        <span className={styles.tablePrimary}>{title}</span>
        {known && <span className={styles.importProgressPct}>{pct}%</span>}
      </div>
      {known && (
        <div className={styles.importProgressTrack} role="progressbar" aria-label={title}
          aria-valuenow={pct} aria-valuemin={0} aria-valuemax={100}>
          <div ref={fillRef} className={styles.importProgressFill} data-active={active || undefined} />
        </div>
      )}
      <span className={styles.tableSecondary} role="status">{detail}</span>
    </div>
  );
}

function describe(i) {
  const c = i.counts || {};
  const n = (k) => Number(c[k] || 0);
  const tally = `${n('imported')} imported, ${n('duplicate')} already here, ${n('skipped')} skipped${n('failed') ? `, ${n('failed')} failed` : ''}`;
  switch (i.state) {
    case 'queued': return 'Waiting to start.';
    case 'running': return `Importing. ${n('seen')} read: ${tally}.`;
    case 'done': return `Done. ${tally}. You can delete the .mbox from C:\\ now.`;
    case 'cancelled': return `Stopped. ${tally}.`;
    default: return `Paused. ${i.error || ''} ${tally}.`.replace(/\s+/g, ' ');
  }
}
