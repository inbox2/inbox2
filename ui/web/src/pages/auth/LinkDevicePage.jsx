import { useState, useMemo } from 'react';
import { useLocation, useNavigate } from 'react-router';
import useAuth from '../../hooks/useAuth';
import { ManagementLayout, MgmtAuthCard, MgmtButton } from '../../components/management';
import Icon from '../../components/Icon';
import api from '../../lib/api';
import log from '../../lib/log';
import { parseLinkParams, linkParamsValid, buildRedirect, platformLabel } from '../../lib/deviceLink';
import authStyles from './authManagement.module.css';
import styles from './LinkDevicePage.module.css';
import { consolePath } from '../../lib/consoleHost';

/* /link — the browser approval surface of the device-link (loopback + PKCE) flow.
 * A desktop/mobile client opens this URL in the system browser; the logged-in
 * user approves, and we mint a one-time code and 302 back to the client's
 * 127.0.0.1 listener, which exchanges it for a device-scoped ink_ key. See
 * docs/Device-Link.md. */
export default function LinkDevicePage() {
  const { user, loading } = useAuth();
  const location = useLocation();
  const navigate = useNavigate();

  const params = useMemo(() => parseLinkParams(location.search), [location.search]);
  const valid = useMemo(() => linkParamsValid(params), [params]);

  const [busy, setBusy] = useState(false);
  const [done, setDone] = useState(false);
  const [error, setError] = useState('');

  const here = location.pathname + location.search;

  const approve = async () => {
    setBusy(true);
    setError('');
    try {
      const { code, redirect_uri } = await api.authorizeDeviceLink({
        code_challenge: params.codeChallenge,
        code_challenge_method: params.codeChallengeMethod,
        redirect_uri: params.redirectUri,
        device_name: params.deviceName || platformLabel(params.platform),
        platform: params.platform,
      });
      setDone(true);
      // Hand the browser back to the client's loopback listener with the one-time
      // code (+ state for CSRF). The native side redeems it for the ink_ key.
      window.location.href = buildRedirect(redirect_uri || params.redirectUri, code, params.state);
    } catch (e) {
      log.warn('DeviceLink', `approve failed: ${e?.message || e}`);
      setError(e?.data?.errors?.[0]?.message || e?.message || "Couldn't link this device. Try again from the app.");
      setBusy(false);
    }
  };

  if (loading) return null;

  // Invalid / stale link request — nothing safe to approve.
  if (!valid) {
    return (
      <ManagementLayout centered brand={false}>
        <MgmtAuthCard
          title="This link doesn’t work"
          subtitle="It’s incomplete or it expired. Start again from the app."
        />
      </ManagementLayout>
    );
  }

  // Not signed in → send through the normal login (it returns here via ?next).
  if (!user) {
    return (
      <ManagementLayout centered brand={false}>
        <MgmtAuthCard
          title="Link your device"
          subtitle={`Log in to link your ${platformLabel(params.platform).toLowerCase()} to your inbox2 account.`}
          footer={(
            <span className={authStyles.muted}>
              New to inbox2?{' '}
              <button type="button" className={authStyles.textBtn} onClick={() => navigate(`/signup?next=${encodeURIComponent(here)}`)}>Create an account</button>
            </span>
          )}
        >
          <MgmtButton variant="primary" block onClick={() => navigate(`/login?next=${encodeURIComponent(here)}`)}>
            Log in to continue <Icon name="arrow.right" size={14} />
          </MgmtButton>
        </MgmtAuthCard>
      </ManagementLayout>
    );
  }

  return (
    <ManagementLayout centered brand={false}>
      <MgmtAuthCard
        title="Link this device?"
        subtitle="This device gets your mail and alerts from your inbox2 account."
        error={error || null}
        success={done ? 'Device linked. Taking you back to the app…' : null}
      >
        <div className={styles.device}>
          <span className={styles.deviceIcon}><Icon name="laptopcomputer" size={20} /></span>
          <span className={styles.deviceText}>
            <span className={styles.deviceName}>{params.deviceName || platformLabel(params.platform)}</span>
            <span className={styles.devicePlatform}>{platformLabel(params.platform)}</span>
          </span>
        </div>

        <p className={styles.account}>
          Signing in as <strong>{user.username || user.display_name}</strong>
        </p>

        <div className={styles.actions}>
          <MgmtButton variant="primary" block disabled={busy || done} onClick={approve}>
            {busy ? 'Linking…' : (<>Approve &amp; link <Icon name="checkmark" size={14} /></>)}
          </MgmtButton>
          <MgmtButton variant="ghost" block disabled={busy || done} onClick={() => navigate(consolePath())}>
            Cancel
          </MgmtButton>
        </div>
      </MgmtAuthCard>
    </ManagementLayout>
  );
}
