import { useState, useEffect, useCallback } from 'react';
import { Link } from 'react-router';
import Skeleton from '../../components/Skeleton';
import Switch from '../../components/Switch/Switch';
import useAuth from '../../hooks/useAuth';
import api from '../../lib/api';
import log from '../../lib/log';
import { consolePath } from '../../lib/consoleHost';
import { isAdminRole } from '../../lib/orgRoles';
import styles from './console.module.css';
import own from './TokenList.module.css';

/* /console/mail-clients (docs/Mail-Clients.md): the org switch, for owners and
 * admins on a paid plan. Each member connects their own mail client from the
 * app's Settings › Mail clients (pages/settings/MailClientsSettings.jsx). */

// The same product icons as Settings › Mail clients (public/mail-clients).
const LOGOS = [['outlook', 'Outlook'], ['apple-mail', 'Apple Mail'], ['thunderbird', 'Thunderbird']];

// Keyed by organization: a switch starts the page empty, and answers for the last one are dropped.
export default function ConsoleMailClients() {
  const { currentOrg, refreshAccount } = useAuth();
  // The API lets only owners and admins change the switch; a member connects from Settings.
  if (currentOrg && !isAdminRole(currentOrg.role)) {
    return (
      <>
        <div className={styles.pageHead}><h1 className={styles.pageTitle}>Mail clients</h1></div>
        <div className={styles.card}><div className={own.body}><p className={own.note}>Connect your mail client from Settings, under Mail clients.</p></div></div>
      </>
    );
  }
  return <Page key={currentOrg?.id} orgId={currentOrg?.id} refreshAccount={refreshAccount} />;
}

function Page({ orgId, refreshAccount }) {
  const [settings, setSettings] = useState(null);
  const [error, setError] = useState('');

  const fail = useCallback((e) => {
    log.warn('MailClients', e?.message || e);
    setError(e?.data?.errors?.[0]?.message || e?.message || 'That did not work. Try again.');
  }, []);

  useEffect(() => {
    if (orgId) api.mailClientSettings(orgId).then((r) => setSettings(r.mail_client)).catch(fail);
  }, [orgId, fail]);

  const toggle = useCallback(async (on) => {
    setError('');
    try {
      await api.updateOrg(orgId, { mail_clients_enabled: on });
      setSettings((await api.mailClientSettings(orgId)).mail_client);
      refreshAccount?.(); // Settings lists "Mail clients" from the org's flag
    } catch (e) { fail(e); }
  }, [orgId, fail, refreshAccount]);

  return (
    <>
      <div className={styles.pageHead}>
        <div>
          <div className={styles.pageEyebrow}>Mail</div>
          <h1 className={styles.pageTitle}>Mail clients</h1>
          <p className={styles.pageSub}>Let members use Outlook, Apple Mail or Thunderbird with their inbox2 mail.</p>
        </div>
      </div>
      {error && <p className={own.error} role="alert">{error}</p>}

      <div className={styles.card}>
        <div className={styles.cardHead}>
          <h2 className={styles.cardTitle}>Access</h2>
          {settings?.included_in_plan && (
            <Switch id="mail-clients" label="Allow mail clients" checked={settings.enabled} onChange={toggle} ariaLabel="Allow mail clients" />
          )}
        </div>
        <div className={own.body}>
          <div className={own.logos}>
            {LOGOS.map(([file, name]) => <img key={file} src={`/mail-clients/${file}.svg`} alt={name} title={name} className={own.logo} />)}
          </div>
          {!settings ? <Skeleton variant="text" count={1} /> : !settings.included_in_plan ? (
            <p className={own.note}>
              Mail clients are on paid plans. <Link className={own.link} to={consolePath('billing')}>See plans</Link>
            </p>
          ) : settings.enabled ? (
            <p className={own.note}>Each member connects from Settings, under Mail clients, with their own app password. A mail client gets that member’s own mail only.</p>
          ) : (
            <p className={own.note}>Switch this on to let members connect a mail client.</p>
          )}
        </div>
      </div>
    </>
  );
}
