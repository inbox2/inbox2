import { useState, useEffect } from 'react';
import { getSecret, setSecret, clearSecret } from '../../lib/secretStore';
import useTransientFlag from '../../hooks/useTransientFlag';
import Button from '../../components/Button/Button';
import ApolloLogo from '../../components/ApolloLogo';
import styles from './settings.module.css';

const SECRET_NAME = 'apollo_api_key';

export default function IntegrationsSettings() {
  const [apiKey, setApiKey] = useState('');
  const [connected, setConnected] = useState(false);
  const [saved, flashSaved] = useTransientFlag();
  const [confirmingClear, setConfirmingClear] = useState(false);

  // Load from the encrypted store (desktop) / localStorage (web) on mount.
  useEffect(() => {
    let active = true;
    getSecret(SECRET_NAME).then((v) => {
      if (!active) return;
      setApiKey(v || '');
      setConnected(!!v);
    });
    return () => { active = false; };
  }, []);

  const handleSave = async () => {
    if (apiKey.trim()) {
      await setSecret(SECRET_NAME, apiKey.trim());
      setConnected(true);
    } else {
      await clearSecret(SECRET_NAME);
      setConnected(false);
    }
    flashSaved();
  };

  const handleDisconnect = async () => {
    await clearSecret(SECRET_NAME);
    setApiKey('');
    setConnected(false);
    setConfirmingClear(false);
  };

  return (
    <>
      <h1 className={styles.settingsTitle}>Enrichment</h1>
      <p className={styles.sectionDesc}>
        Connect services that add details to your contacts.
      </p>

      <div className={styles.providerCard}>
        <div className={styles.providerHeader}>
          <ApolloLogo size={28} />
          <div>
            <h3 className={styles.providerName}>Apollo.io</h3>
            <p className={styles.providerDesc}>Adds LinkedIn, job titles and company info</p>
          </div>
          {connected && <span className={styles.providerStatus} data-status="connected">Connected</span>}
        </div>
        {connected ? (
          <>
            <div className={styles.settingsField}>
              <label>API key</label>
              <span className={styles.keyConnected}>
                <code className={styles.keyPreview}>{apiKey.slice(0, 8)}…</code>
              </span>
            </div>
            {confirmingClear ? (
              <div className={styles.dangerLinkRow}>
                <span className={styles.providerHint}>Disconnect Apollo?</span>
                <Button variant="danger-link" onClick={handleDisconnect}>
                  Disconnect
                </Button>
                <Button variant="link" onClick={() => setConfirmingClear(false)}>
                  Cancel
                </Button>
              </div>
            ) : (
              <div className={styles.dangerLinkRow}>
                <Button variant="danger-link" onClick={() => setConfirmingClear(true)}>
                  Disconnect
                </Button>
              </div>
            )}
          </>
        ) : (
          <>
            <div className={styles.settingsField}>
              <label htmlFor="apollo-key">API key</label>
              <input
                id="apollo-key"
                type="password"
                value={apiKey}
                onChange={e => setApiKey(e.target.value)}
                placeholder="Paste your Apollo API key"
                autoComplete="off"
              />
            </div>
            <div className={styles.providerActions}>
              <Button className={styles.settingsButton} onClick={handleSave}>
                {saved ? 'Saved' : 'Save'}
              </Button>
              <span className={styles.providerHint}>
                Find your key at Apollo &rarr; Settings &rarr; Integrations &rarr; API Keys
              </span>
            </div>
          </>
        )}
      </div>
    </>
  );
}
