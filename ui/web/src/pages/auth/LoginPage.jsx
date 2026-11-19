import { useState } from 'react';
import { Link, useNavigate, useLocation } from 'react-router';
import useAuth from '../../hooks/useAuth';
import { ManagementLayout, MgmtAuthCard, MgmtField, MgmtButton } from '../../components/management';
import Icon from '../../components/Icon';
import { isTauri } from '../../lib/tauri';
import { clearSetupMode } from '../../lib/setupMode';
import { startDesktopDeviceLink } from '../../lib/deviceLink';
import { safeNextPath } from '../../lib/safeNext';
import { mobileLayoutNow } from '../../hooks/useIsPhone';
import { passkeysSupported, signInWithPasskey, isPasskeyCancel } from '../../lib/passkeys';
import api from '../../lib/api';
import log from '../../lib/log';
import styles from './authManagement.module.css';
import Button from '../../components/Button/Button';
import StepTrail from '../setup/steps/StepTrail';
import setup from '../setup/setup.module.css';
import { consolePath } from '../../lib/consoleHost';

// Where a sign-in lands: the console on desktop browsers, the inbox on phones
// and tablets.
const HOME = () => (mobileLayoutNow() ? '/' : consolePath());

export default function LoginPage() {
  const [username, setUsername] = useState('');
  const [password, setPassword] = useState('');
  const [error, setError] = useState('');
  const [loading, setLoading] = useState(false);
  const [linking, setLinking] = useState(false);
  const { login, refreshAccount } = useAuth();
  const navigate = useNavigate();
  const location = useLocation();
  const showBack = isTauri();

  // A local-only ?next= return path (e.g. the /link approval page bounces signed-
  // out users here).
  const next = safeNextPath(location.search);

  const handleSubmit = async (e) => {
    e.preventDefault();
    setError('');
    setLoading(true);
    try {
      await login(username, password);
      // Management console is the post-login home (login → admin → enter domain),
      // unless a ?next return path was supplied (device-link approval). Phones go
      // to their mail, like the apps.
      navigate(next || HOME());
    } catch (err) {
      // Dismissing the passkey sheet on an account that requires one.
      setError(isPasskeyCancel(err)
        ? 'This account needs its passkey to sign in. Try again and choose it.'
        : (err.message || 'Invalid username or password'));
    } finally {
      setLoading(false);
    }
  };

  // Passkey sign-in: the browser offers the passkeys it holds for this site, so
  // there is no username to type. The API sets the same session cookie as a
  // password login; adopt the token and load the account.
  const handlePasskey = async () => {
    setError('');
    setLoading(true);
    try {
      const data = await signInWithPasskey();
      api.setToken(data.token);
      await refreshAccount();
      navigate(next || HOME());
    } catch (err) {
      if (!isPasskeyCancel(err)) {
        log.warn('Auth', `passkey sign-in failed: ${err?.message || err}`);
        setError("That passkey didn't work. Try again or use your password.");
      }
    } finally {
      setLoading(false);
    }
  };

  const handleBack = () => {
    clearSetupMode();
    navigate('/setup');
  };

  const [ssoOpen, setSsoOpen] = useState(false);
  const [ssoOrg, setSsoOrg] = useState('');
  const [ssoLoading, setSsoLoading] = useState(false);
  const handleSso = async () => {
    setError('');
    setSsoLoading(true);
    try {
      const { redirect_url: url } = await api.samlInitiate(ssoOrg.trim().toLowerCase());
      window.location.assign(url);
    } catch (err) {
      setError(err?.status === 404 ? 'No single sign-on is set up for that organization.' : (err?.message || "Couldn't start single sign-on"));
      setSsoLoading(false);
    }
  };

  // Desktop: link this client to an inbox2 account via the browser (loopback +
  // PKCE) instead of typing credentials here. Rust runs the loopback exchange and
  // persists the minted ink_ key; we adopt it as the bearer and continue.
  const handleLink = async () => {
    setError('');
    setLinking(true);
    try {
      const result = await startDesktopDeviceLink({});
      if (result?.token) {
        api.setToken(result.token);
        await refreshAccount();
        navigate(next || consolePath());
      }
    } catch (err) {
      log.warn('DeviceLink', `desktop link failed: ${err?.message || err}`);
      setError(err?.message || "Linking didn't finish. Try again.");
    } finally {
      setLinking(false);
    }
  };

  // Desktop: sign-in is the last step of setup, so it wears the wizard's look —
  // browser sign-in first (no password typed here), the rest underneath.
  if (isTauri()) {
    return (
      <div className={setup.page}>
        <div className={setup.card}>
          <StepTrail step="signin" mode="mx" />
          <div className={setup.signinHead}>
            <img src="/logo-cube.png" alt="" width="44" height="45" />
            <h1 className={setup.title}>Sign in to inbox2</h1>
          </div>
          <p className={setup.subtitle}>Your browser opens inbox2. Sign in there and approve this Mac; you come straight back here.</p>
          <Button className={setup.signinPrimary} onClick={handleLink} disabled={linking}>
            {linking ? 'Waiting for your browser…' : 'Continue in browser'}
          </Button>
          <div className={setup.signinDivider}>or with your password</div>
          <form className={setup.signinForm} onSubmit={handleSubmit}>
            <label className={setup.signinLabel}>Username
              <input className={setup.aiKeyInput} type="text" value={username} onChange={(e) => setUsername(e.target.value)}
                placeholder="yourname" autoComplete="username" required />
            </label>
            <label className={setup.signinLabel}>Password
              <input className={setup.aiKeyInput} type="password" value={password} onChange={(e) => setPassword(e.target.value)}
                placeholder="Your password" autoComplete="current-password" required />
            </label>
            {error && <p className={setup.signinError} role="alert">{error}</p>}
            <div className={setup.signinRow}>
              <Button type="submit" variant="secondary" disabled={loading}>{loading ? 'Signing in…' : 'Sign in'}</Button>
              {passkeysSupported() && (
                <Button type="button" variant="ghost" disabled={loading} onClick={handlePasskey}>
                  <Icon name="key" size={14} /> Passkey
                </Button>
              )}
              {ssoOpen ? (
                <>
                  <input className={setup.aiKeyInput} type="text" value={ssoOrg} onChange={(e) => setSsoOrg(e.target.value)}
                    placeholder="your-company" aria-label="Organization" autoFocus />
                  <Button type="button" variant="ghost" disabled={ssoLoading || !ssoOrg.trim()} onClick={handleSso}>
                    {ssoLoading ? 'Redirecting…' : 'Continue'}
                  </Button>
                </>
              ) : (
                <Button type="button" variant="ghost" onClick={() => setSsoOpen(true)}>
                  <Icon name="lock" size={14} /> SSO
                </Button>
              )}
            </div>
          </form>
          <div className={setup.signinFooter}>
            <button type="button" className={setup.signinLink} onClick={handleBack}>Back to setup</button>
            <Link className={setup.signinLink} to="/forgot-password">Forgot password?</Link>
            <Link className={setup.signinLink} to="/signup">No account? Sign up</Link>
          </div>
        </div>
      </div>
    );
  }

  return (
    <ManagementLayout centered brand={false}>
      <MgmtAuthCard
        title="Welcome back"
        subtitle="Log in to your inbox2 console."
        error={error || null}
        footer={(
          <>
            <Link className={styles.link} to="/forgot-password">Forgot password?</Link>
            <span className={styles.muted}>Don&apos;t have an account? <Link className={styles.link} to="/signup">Sign up</Link></span>
            {showBack && <button type="button" className={styles.textBtn} onClick={handleBack}>Back to setup</button>}
          </>
        )}
      >
        <form className={styles.form} onSubmit={handleSubmit}>
          <MgmtField
            label="Username"
            type="text"
            value={username}
            onChange={(e) => setUsername(e.target.value)}
            placeholder="yourname"
            autoComplete="username"
            autoFocus
            required
          />
          <MgmtField
            label="Password"
            type="password"
            value={password}
            onChange={(e) => setPassword(e.target.value)}
            placeholder="Your password"
            autoComplete="current-password"
            required
          />
          <MgmtButton type="submit" variant="primary" block disabled={loading}>
            {loading ? 'Logging in…' : (<>Log in <Icon name="arrow.right" size={14} /></>)}
          </MgmtButton>
          {passkeysSupported() && (
            <MgmtButton type="button" variant="glass" block disabled={loading} onClick={handlePasskey}>
              <Icon name="key" size={14} /> Sign in with a passkey
            </MgmtButton>
          )}
          {/* SAML SSO: the org's slug (the first segment of its inbox2 URLs) names
              whose IdP to go to; the API answers with the IdP's URL. */}
          {ssoOpen ? (
            <>
              <MgmtField
                label="Organization"
                type="text"
                value={ssoOrg}
                onChange={(e) => setSsoOrg(e.target.value)}
                placeholder="your-company"
                autoFocus
              />
              <MgmtButton type="button" variant="glass" block disabled={ssoLoading || !ssoOrg.trim()} onClick={handleSso}>
                {ssoLoading ? 'Redirecting…' : (<><Icon name="lock" size={14} /> Continue with SSO</>)}
              </MgmtButton>
            </>
          ) : (
            <MgmtButton type="button" variant="glass" block disabled={loading} onClick={() => setSsoOpen(true)}>
              <Icon name="lock" size={14} /> Sign in with SSO
            </MgmtButton>
          )}
          {isTauri() && (
            <>
              <span className={styles.divider} />
              <MgmtButton type="button" variant="dark" block disabled={linking} onClick={handleLink}>
                {linking ? 'Waiting for browser…' : (<><Icon name="link" size={14} /> Link to inbox2 account</>)}
              </MgmtButton>
            </>
          )}
        </form>
      </MgmtAuthCard>
    </ManagementLayout>
  );
}
