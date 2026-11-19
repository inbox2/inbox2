import { useState, useEffect } from 'react';
import useImageProxyPref from '../../lib/imageProxyPref';
import Switch from '../../components/Switch/Switch';
import FormField, { ErrorMessage } from '../../components/FormField/FormField';
import Button from '../../components/Button/Button';
import { isStandaloneDesktop } from '../../lib/setupMode';
import { isTauri } from '../../lib/tauri';
import { saveApiKey, clearApiKey, currentToken, API_KEY_PREFIX } from '../../lib/inbox2ApiKey';
import Modal from '../../components/Modal/Modal';
import MxLoginForm from '../../components/AddAccountModal/MxLoginForm';
import useAuth from '../../hooks/useAuth';
import styles from './settings.module.css';

/**
 * Privacy controls for how email content is loaded. Remote images are always
 * blocked until requested; the toggle decides whether requested images load
 * privately through the Rails proxy (hiding your IP/address from the sender).
 *
 * The proxy authenticates with a bearer token. MX/web users have one from their
 * web session; standalone desktop users have none, so they paste a personal API
 * key (ink_…) here — stored as the bearer that the proxy (and push) use.
 */
export default function PrivacySettings() {
  const { enabled, setEnabled } = useImageProxyPref();
  const [keyInput, setKeyInput] = useState('');
  const [savedKey, setSavedKey] = useState('');
  const [error, setError] = useState('');
  const [confirmingClear, setConfirmingClear] = useState(false);
  const { login } = useAuth();
  const [showLogin, setShowLogin] = useState(false);
  const [submitting, setSubmitting] = useState(false);
  const [loginError, setLoginError] = useState(null);

  // Token lives in the secret store (async) — hydrate the "connected" display.
  useEffect(() => { let alive = true; currentToken().then((t) => { if (alive) setSavedKey(t || ''); }); return () => { alive = false; }; }, []);

  // Show the key entry for standalone desktop, or for any client that has no
  // token yet (so a client that needs a key can never have the field hidden).
  // MX/web users with a live session token keep it hidden to avoid clobbering it.
  const showKeyEntry = isStandaloneDesktop() || !savedKey;

  const handleSave = () => {
    if (!saveApiKey(keyInput)) {
      setError(`API keys start with “${API_KEY_PREFIX}”.`);
      return;
    }
    setSavedKey(keyInput.trim());
    setKeyInput('');
    setError('');
  };

  const handleClear = () => {
    clearApiKey();
    setSavedKey('');
    setConfirmingClear(false);
  };

  // Sign in in-app rather than handing off to the browser. The old device-link
  // flow opened the hosted web app to mint an ink_ key, which meant this screen
  // and the setup wizard authenticated in different ways against different
  // origins — and against a local MX it just fails, because the browser lands on
  // whatever origin the web build points at. Reuses the same MxLoginForm the
  // add-account modal uses, so there is one MX sign-in surface.
  const handleMxLogin = async (username, password) => {
    setLoginError(null);
    setSubmitting(true);
    try {
      await login(username, password);
      // The session token is now the cloud bearer (api.setToken inside login),
      // so the pasted-key path has nothing left to do.
      setShowLogin(false);
      setKeyInput('');
      setSavedKey(await currentToken() || '');
    } catch (err) {
      setLoginError(err.message || 'Invalid username or password');
    } finally {
      setSubmitting(false);
    }
  };

  return (
    <>
      <h2 className={styles.sectionTitle}>Private images</h2>
      <p className={styles.sectionDesc}>
        Loading an image in an email tells the sender you opened it and roughly where you are.
      </p>

      <Switch
        id="image-proxy-enabled"
        label="Load remote images privately"
        description="Inbox2 loads images for you, so senders never see your IP. When off, images wait until you choose “Show images”."
        checked={enabled}
        onChange={setEnabled}
      />

      {showKeyEntry && <hr className={styles.settingsGroupDivider} />}
      {showKeyEntry && (savedKey ? (
        <FormField label="Inbox2 API key">
          <span className={styles.keyConnected}>
            <code className={styles.keyPreview}>{savedKey.slice(0, 8)}…</code>
          </span>
          {confirmingClear ? (
            <div className={styles.dangerLinkRow}>
              <span className={styles.providerHint}>Clear this key?</span>
              <Button type="button" variant="danger-link" onClick={handleClear}>
                Clear key
              </Button>
              <Button type="button" variant="link" onClick={() => setConfirmingClear(false)}>
                Cancel
              </Button>
            </div>
          ) : (
            <div className={styles.dangerLinkRow}>
              <Button type="button" variant="danger-link" onClick={() => setConfirmingClear(true)}>
                Clear key
              </Button>
            </div>
          )}
        </FormField>
      ) : (
        <>
          {isTauri() && (
            <div className={styles.linkTop}>
              <button type="button" className={styles.linkAction} onClick={() => { setLoginError(null); setShowLogin(true); }}>
                Sign in to your inbox2 account
              </button>
              <p className={styles.linkHint}>
                Recommended. Sign in and skip the key.
              </p>
              <hr className={styles.settingsGroupDivider} />
              <span className={styles.linkOr}>or</span>
            </div>
          )}
          <FormField
            label="Inbox2 API key"
            type="password"
            value={keyInput}
            onChange={(e) => setKeyInput(e.target.value)}
            placeholder={`${API_KEY_PREFIX}…`}
            autoComplete="off"
            hint={<>Paste a personal key for private images and push alerts. Create one in the Inbox2 web app under Console &rsaquo; API keys.</>}
          />
          <ErrorMessage>{error}</ErrorMessage>
          <Button type="button" variant="secondary" className={styles.saveKeyBtn} onClick={handleSave}>
            Save key
          </Button>
        </>
      ))}

      {/* In-app MX sign-in. Same component the add-account modal uses, so the
          form, validation and error copy stay identical wherever you sign in. */}
      <Modal open={showLogin} onClose={() => setShowLogin(false)}>
        <MxLoginForm
          onBack={() => setShowLogin(false)}
          onSubmit={handleMxLogin}
          submitting={submitting}
          error={loginError}
        />
      </Modal>
    </>
  );
}
