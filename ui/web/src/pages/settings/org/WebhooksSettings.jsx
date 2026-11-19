import { useState, useEffect } from 'react';
import api from '../../../lib/api';
import log from '../../../lib/log';
import useUndoStore from '../../../stores/undoStore';
import Modal from '../../../components/Modal/Modal';
import Button from '../../../components/Button/Button';
import styles from '../settings.module.css';

export default function WebhooksSettings({ orgId }) {
  const [webhooks, setWebhooks] = useState([]);
  const [newUrl, setNewUrl] = useState('');
  const [showAdd, setShowAdd] = useState(false);

  useEffect(() => {
    if (!orgId) return;
    api.get(`/orgs/${orgId}/webhooks`).then(data => setWebhooks(data.webhooks)).catch(() => { /* load error */ });
  }, [orgId]);

  const handleCreate = async () => {
    if (!newUrl.trim()) return;
    try {
      await api.post(`/orgs/${orgId}/webhooks`, { url: newUrl });
      setNewUrl('');
      setShowAdd(false);
      const data = await api.get(`/orgs/${orgId}/webhooks`);
      setWebhooks(data.webhooks);
    } catch (e) {
      // The form stays open with the URL still in it; without this the failure
      // was indistinguishable from nothing having happened.
      log.error('Webhooks', `Create failed: ${e?.message || e}`);
      useUndoStore.getState().notify({
        description: `Couldn't add that webhook. ${e?.message || 'Try again.'}`,
        variant: 'danger',
        icon: 'exclamationmark.triangle',
      });
    }
  };

  return (
    <>
      <div className={styles.settingsTitleRow}>
        <h1 className={styles.settingsTitle}>Webhooks</h1>
        <button className={styles.addAccountCta} onClick={() => setShowAdd(true)}>Add webhook</button>
      </div>

      <div className={styles.settingsSection}>
        <div className={styles.settingsSectionTitle}>Endpoints ({webhooks.length})</div>
        {webhooks.map(wh => (
          <div key={wh.id} className={styles.settingsField}>
            <label>{wh.url}</label>
            <input value={wh.enabled ? 'Active' : 'Disabled'} disabled />
          </div>
        ))}
      </div>

      <Modal open={showAdd} onClose={() => setShowAdd(false)} className={styles.settingsModal}>
        <div className={styles.settingsModalTitle}>Add webhook</div>
        <div className={styles.settingsField}>
          <label htmlFor="webhook-url">Endpoint URL</label>
          <input
            id="webhook-url"
            value={newUrl}
            onChange={e => setNewUrl(e.target.value)}
            placeholder="https://example.com/webhook"
            onKeyDown={e => e.key === 'Enter' && handleCreate()}
          />
        </div>
        <div className={styles.settingsModalActions}>
          <button className={styles.addAccountBtn} onClick={() => setShowAdd(false)}>Cancel</button>
          <Button className={styles.settingsButton} onClick={handleCreate}>Add webhook</Button>
        </div>
      </Modal>
    </>
  );
}
