import { useState } from 'react';
import useAuth from '../../hooks/useAuth';
import { isTauri } from '../../lib/tauri';
import Button from '../../components/Button/Button';
import Icon from '../../components/Icon';
import log from '../../lib/log';
import styles from './settings.module.css';

/* A person's own C:\\ is in no admin's export (Disk spec F11), so they take it out
 * here. Web only: the desktop app opens Disk in the browser. */
export default function ExportMyDisk({ disabled = false }) {
  const { currentOrg } = useAuth();
  const [status, setStatus] = useState('');
  const [busy, setBusy] = useState(false);
  if (isTauri() || !currentOrg?.plan?.disk) return null;

  const run = async () => {
    setBusy(true);
    setStatus('Preparing the zip...');
    try {
      const [{ default: diskApi }, { downloadZip, zipReport }] = await Promise.all([
        import('../../lib/disk/api'), import('../../lib/disk/download'),
      ]);
      const { c_drive: drive } = await diskApi.drives(currentOrg.id);
      const result = await downloadZip(currentOrg.id, [{ ...drive, name: 'My disk' }], 'My disk.zip',
        ({ done, total }) => setStatus(`Zipping ${done} of ${total} files...`));
      setStatus(zipReport(result));
    } catch (e) {
      if (e.name === 'AbortError') setStatus('');
      else { log.warn('Disk', `export failed: ${e?.message || e}`); setStatus("The export didn't finish. Try again."); }
    } finally {
      setBusy(false);
    }
  };

  return (
    <div className={styles.exportRow}>
      <div>
        <span className={styles.tablePrimary}>Export my disk</span>
        <span className={styles.tableSecondary} role="status">{status || 'Download your files and pages on C:\\ as a zip. Sealed items stay out.'}</span>
      </div>
      <Button variant="secondary" className={styles.exportBtn} onClick={run} disabled={busy || disabled}
        title={disabled ? 'Wait for the mail import to finish.' : undefined}>
        <Icon name="arrow.down.circle" size={14} /> Export
      </Button>
    </div>
  );
}
