import { useCallback, useEffect, useState } from 'react';
import Button from '../../components/Button/Button';
import FormField, { ErrorMessage } from '../../components/FormField/FormField';
import ConfirmDialog from '../../components/ConfirmDialog/ConfirmDialog';
import Icon from '../../components/Icon';
import Skeleton from '../../components/Skeleton';
import useCopyToClipboard from '../../hooks/useCopyToClipboard';
import api from '../../lib/api';
import styles from './settings.module.css';
import own from './MailClientsSettings.module.css';

/* Settings › Mail clients (docs/Mail-Clients.md): a member connects Outlook,
 * Apple Mail or Thunderbird to their inbox2 mail. Pick the client, follow its
 * steps, create an app password. Listed only while the org has mail clients on. */

// Steps per client. `address` is the member's own; the servers are in the table under the steps.
const CLIENTS = [
  {
    key: 'outlook', name: 'Outlook', logo: '/mail-clients/outlook.svg',
    steps: (address) => [
      'Create an app password below and copy it.',
      'In Outlook, open File and choose Add Account.',
      `Enter ${address}, open Advanced options and tick “Let me set up my account manually”.`,
      'Choose IMAP and enter the two servers below.',
      'Paste the app password and choose Connect.',
    ],
  },
  {
    key: 'apple-mail', name: 'Apple Mail', logo: '/mail-clients/apple-mail.svg',
    steps: (address) => [
      'Create an app password below and copy it.',
      'In Mail, open Settings, choose Accounts and click +.',
      'Choose Other Mail Account.',
      `Enter ${address} and paste the app password.`,
      'Enter the two servers below when Mail asks for them.',
    ],
  },
  {
    key: 'thunderbird', name: 'Thunderbird', logo: '/mail-clients/thunderbird.svg',
    steps: (address) => [
      'Create an app password below and copy it.',
      'In Thunderbird, open Account Settings, then Account Actions, and choose Add Mail Account.',
      `Enter ${address} and paste the app password.`,
      'Choose Configure manually and enter the two servers below.',
      'Choose Done.',
    ],
  },
  {
    key: 'other', name: 'Another client', icon: 'envelope.open',
    steps: (address) => [
      'Create an app password below and copy it.',
      'Add an IMAP account in your mail client.',
      `Enter ${address} as the username and paste the app password.`,
      'Enter the two servers below.',
    ],
  },
];

const fmtDate = (iso) => (iso ? new Date(iso).toLocaleDateString(undefined, { year: 'numeric', month: 'short', day: 'numeric' }) : null);
const errText = (e) => e?.data?.errors?.[0]?.message || e?.message || 'That did not work. Try again.';

export default function MailClientsSettings({ orgId }) {
  const [settings, setSettings] = useState(null);
  const [passwords, setPasswords] = useState([]);
  const [client, setClient] = useState(CLIENTS[0]);
  const [name, setName] = useState('');
  const [revealed, setRevealed] = useState(null); // { name, token }
  const [removing, setRemoving] = useState(null);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState('');
  const [listError, setListError] = useState('');
  const [copied, copy] = useCopyToClipboard();

  const loadPasswords = useCallback(() => {
    api.listMailClientPasswords(orgId)
      .then((r) => { setPasswords(r.passwords); setListError(''); })
      .catch((e) => setListError(errText(e)));
  }, [orgId]);

  useEffect(() => {
    api.mailClientSettings(orgId).then((r) => setSettings(r.mail_client)).catch((e) => setError(errText(e)));
    loadPasswords();
  }, [orgId, loadPasswords]);

  const create = useCallback(async () => {
    const label = name.trim() || client.name;
    setBusy(true);
    setError('');
    try {
      const r = await api.createMailClientPassword(orgId, label);
      setPasswords((prev) => [...prev, r.password]);
      setRevealed({ name: label, token: r.token });
      setName('');
    } catch (e) { setError(errText(e)); } finally { setBusy(false); }
  }, [orgId, name, client]);

  const remove = useCallback(async () => {
    const p = removing;
    setRemoving(null);
    try {
      await api.deleteMailClientPassword(orgId, p.id);
      setPasswords((prev) => prev.filter((x) => x.id !== p.id));
    } catch (e) { setError(errText(e)); }
  }, [orgId, removing]);

  // Radio group keys: one tab stop, arrows move the selection and the focus.
  const pickByArrow = (e) => {
    const step = { ArrowRight: 1, ArrowDown: 1, ArrowLeft: -1, ArrowUp: -1 }[e.key];
    if (!step) return;
    e.preventDefault();
    const i = (CLIENTS.findIndex((c) => c.key === client.key) + step + CLIENTS.length) % CLIENTS.length;
    setClient(CLIENTS[i]);
    e.currentTarget.parentElement.children[i].focus();
  };

  if (!settings) {
    return (
      <>
        <h1 className={styles.settingsTitle}>Mail clients</h1>
        {error ? <ErrorMessage>{error}</ErrorMessage> : <div aria-busy="true"><Skeleton variant="text" count={4} /></div>}
      </>
    );
  }
  if (!settings.enabled) {
    return (
      <>
        <h1 className={styles.settingsTitle}>Mail clients</h1>
        <p className={styles.tableEmpty}>Ask an admin to switch on mail clients for your organization.</p>
      </>
    );
  }

  // A mail client signs in with a mailbox address; without one there is nothing to connect.
  if (settings.addresses.length === 0) {
    return (
      <>
        <h1 className={styles.settingsTitle}>Mail clients</h1>
        <p className={styles.tableEmpty}>You have no mailbox in this organization. Ask an admin to give you one, then connect your mail client here.</p>
      </>
    );
  }

  const address = settings.addresses[0];

  return (
    <>
      <h1 className={styles.settingsTitle}>Mail clients</h1>

      <div className={styles.settingsSection}>
        <div className={styles.settingsSectionTitle}>Choose your mail client</div>
        <div className={own.clients} role="radiogroup" aria-label="Mail client">
          {CLIENTS.map((c) => (
            <button
              key={c.key}
              type="button"
              role="radio"
              aria-checked={client.key === c.key}
              tabIndex={client.key === c.key ? 0 : -1}
              onKeyDown={pickByArrow}
              className={`${own.client} ${client.key === c.key ? own.clientOn : ''}`}
              onClick={() => setClient(c)}
            >
              {c.logo ? <img src={c.logo} alt="" className={own.logo} /> : <span className={own.logo}><Icon name={c.icon} size={26} /></span>}
              <span>{c.name}</span>
            </button>
          ))}
        </div>

        <ol className={own.steps}>
          {client.steps(address).map((step) => <li key={step}>{step}</li>)}
        </ol>

        <div className={own.scroll}>
        <table className={own.servers}>
          <thead><tr><th /><th>Server</th><th>Port</th><th>Security</th></tr></thead>
          <tbody>
            <tr><td>Incoming mail (IMAP)</td><td className={own.mono}>{settings.imap.host}</td><td>{settings.imap.port}</td><td>{settings.imap.security}</td></tr>
            <tr><td>Outgoing mail (SMTP)</td><td className={own.mono}>{settings.smtp.host}</td><td>{settings.smtp.port}</td><td>{settings.smtp.security}</td></tr>
            <tr><td>Username</td><td className={own.mono} colSpan={3}>{settings.addresses.join(', ')}</td></tr>
          </tbody>
        </table>
        </div>
      </div>

      <div className={styles.settingsSection}>
        <div className={styles.settingsSectionTitle}>App passwords</div>
        {revealed && (
          <div className={own.reveal} role="status">
            <span>Copy the password for “{revealed.name}” now. You won’t see it again.</span>
            <div className={own.revealRow}>
              <code className={own.token}>{revealed.token}</code>
              <Button variant="secondary" onClick={() => copy(revealed.token)}>{copied ? 'Copied' : 'Copy'}</Button>
              <Button variant="link" onClick={() => setRevealed(null)}>Done</Button>
            </div>
          </div>
        )}
        <div className={own.createRow}>
          <FormField label="Name" value={name} onChange={(e) => setName(e.target.value)} placeholder={`e.g. ${client.name} on my laptop`} />
          <Button onClick={create} disabled={busy || !!revealed}>Create password</Button>
        </div>
        <ErrorMessage>{error}</ErrorMessage>
        {listError && (
          <div className={own.password}>
            <ErrorMessage>Your passwords did not load.</ErrorMessage>
            <Button variant="link" onClick={loadPasswords}>Try again</Button>
          </div>
        )}
        {passwords.map((p) => (
          <div key={p.id} className={own.password}>
            <div>
              <div className={styles.providerName}>{p.name}</div>
              <div className={styles.providerDesc}>
                {p.last_used_at ? `Last used ${fmtDate(p.last_used_at)}` : 'Never used'} · Created {fmtDate(p.created_at)}
              </div>
            </div>
            <Button variant="danger-link" onClick={() => setRemoving(p)}>Delete</Button>
          </div>
        ))}
      </div>

      <ConfirmDialog
        open={!!removing}
        title="Delete this password?"
        message={`“${removing?.name}” stops syncing right away.`}
        confirmLabel="Delete"
        onConfirm={remove}
        onCancel={() => setRemoving(null)}
      />
    </>
  );
}
