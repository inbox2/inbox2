import { useState, useEffect } from 'react';
import { useSearchParams } from 'react-router';
import Icon from '../../components/Icon';
import Spinner from '../../components/Spinner';
import { MgmtButton } from '../../components/management';
import { API_ORIGIN } from '../../lib/apiOrigin';
import { initialsDataUri } from '../../lib/initialsIcon';
import api from '../../lib/api';
import log from '../../lib/log';
import styles from './AppOauthConsentPage.module.css';

/* Consent screen for a registered application's brokered OAuth flow
 * (docs/App-OAuth.md). Reached in a plain browser with no inbox2 session — the
 * person connecting their mailbox need not have an inbox2 account. All it does
 * is name who is asking, which provider they're about to sign in to, and hand
 * off to (or refuse) the provider.
 *
 * Continue/Not now are server-side redirects: the next hop is the provider's own
 * domain, so the API builds it (it holds the client id + scopes). */

const PROVIDER_LOGO = { google: '/channels/gmail.svg', microsoft: '/channels/office365.svg' };

export default function AppOauthConsentPage() {
  const [params] = useSearchParams();
  const flow = params.get('flow') || '';

  const [info, setInfo] = useState(null);
  const [error, setError] = useState(
    flow ? '' : 'This link is missing its authorization reference. Start again from the app.'
  );
  const [leaving, setLeaving] = useState(false);

  useEffect(() => {
    if (!flow) return;
    api.getAppOauthConsent(flow)
      .then(setInfo)
      .catch((e) => {
        log.warn('AppOauth', `consent load failed: ${e?.message || e}`);
        setError(e?.data?.errors?.[0]?.message || 'This link has expired. Start again from the app.');
      });
  }, [flow]);

  const go = (action) => {
    setLeaving(true);
    window.location.href = `${API_ORIGIN}/api/v1/auth/app-oauth/${action}?flow=${encodeURIComponent(flow)}`;
  };

  return (
    <div className={`${styles.page} management`}>
      <div className={styles.card}>
        {error ? (
          <div className={styles.state} role="alert">
            <Icon name="exclamationmark.triangle" size={26} />
            <p className={styles.stateTitle}>Can&apos;t continue</p>
            <p className={styles.stateSub}>{error}</p>
          </div>
        ) : !info ? (
          <div className={styles.state}><Spinner size={22} color="var(--m-violet)" /></div>
        ) : (
          <>
            <div className={styles.marks}>
              <img className={styles.appIcon} src={info.app.icon_url || initialsDataUri(info.app.name)} alt="" />
              <span className={styles.marksLink} aria-hidden="true">
                <Icon name="arrow.up.right" size={14} />
              </span>
              <span className={styles.providerIcon}>
                {PROVIDER_LOGO[info.provider]
                  ? <img className={styles.providerLogo} src={PROVIDER_LOGO[info.provider]} alt="" />
                  : <Icon name="globe" size={22} />}
              </span>
            </div>

            <h1 className={styles.title}>
              {info.app.name} wants to connect your {info.provider_label} account
            </h1>
            <p className={styles.sub}>
              You&apos;ll sign in to {info.provider_label} next and choose what to allow.
              Then <strong>{info.app.name}</strong> can read and send mail and manage the
              calendar for that account.
            </p>

            <div className={styles.actions}>
              <MgmtButton variant="primary" onClick={() => go('start')} disabled={leaving}>
                {leaving ? 'One moment…' : `Continue to ${info.provider_label}`}
              </MgmtButton>
              <MgmtButton variant="glass" onClick={() => go('cancel')} disabled={leaving}>
                Not now
              </MgmtButton>
            </div>

            <p className={styles.note}>
              inbox2 passes the connection straight to {info.app.name} and keeps no copy of your mail.
            </p>
          </>
        )}

        <div className={styles.poweredBy}>
          <img className={styles.brandMark} src="/logo-mark.png" alt="" />
          Powered by <strong>inbox2</strong>
        </div>
      </div>
    </div>
  );
}
