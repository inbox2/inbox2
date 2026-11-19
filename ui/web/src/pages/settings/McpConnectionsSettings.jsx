import { useCallback, useEffect, useState } from 'react';
import Button from '../../components/Button/Button';
import FormField, { ErrorMessage } from '../../components/FormField/FormField';
import ConfirmDialog from '../../components/ConfirmDialog/ConfirmDialog';
import SendToLogo from '../../components/Lore/SendToLogo';
import {
  mcpAvailable, listMcpPresets, listMcpConnections, addMcpConnection, reauthMcpConnection,
  removeMcpConnection, MCP_STATUS, MCP_AUTH, NEEDS_AUTH,
} from '../../lib/mcpClient';
import styles from './settings.module.css';

const STATUS_LABEL = { [MCP_STATUS.CONNECTED]: 'Connected', [MCP_STATUS.NEEDS_AUTH]: 'Sign in again', [MCP_STATUS.ERROR]: 'Error' };
const AUTH_LABEL = { [MCP_AUTH.OAUTH]: 'Signed in', [MCP_AUTH.TOKEN]: 'Access token', [MCP_AUTH.NONE]: 'No sign-in' };
const EMPTY_FORM = { name: '', url: '', token: '', clientId: '', clientSecret: '' };
const errText = (e) => {
  const s = String(e?.message || e || 'Something went wrong');
  return s === NEEDS_AUTH ? 'The app needs you to sign in again.' : s;
};

/**
 * Settings › Connected apps (MCP): remote MCP servers Lore items can be sent
 * to (Linear, GitHub, Jira, …). Desktop-only — the client lives in the Rust
 * core. docs/MCP-Client.md.
 */
export default function McpConnectionsSettings() {
  const desktop = mcpAvailable();
  const [presets, setPresets] = useState([]);
  const [connections, setConnections] = useState([]);
  const [form, setForm] = useState(EMPTY_FORM);
  const [note, setNote] = useState('');
  const [busy, setBusy] = useState(null); // 'add' | connection id
  const [error, setError] = useState('');
  const [removing, setRemoving] = useState(null);

  const load = useCallback(async () => {
    try {
      const [p, c] = await Promise.all([listMcpPresets(), listMcpConnections()]);
      setPresets(p);
      setConnections(c);
    } catch (e) {
      setError(errText(e));
    }
  }, []);

  /* eslint-disable react-hooks/set-state-in-effect -- intentional: load on mount */
  useEffect(() => { if (desktop) load(); }, [desktop, load]);
  /* eslint-enable react-hooks/set-state-in-effect */

  const add = async (input) => {
    setBusy('add');
    setError('');
    try {
      await addMcpConnection(input);
      setForm(EMPTY_FORM);
      setNote('');
      await load();
    } catch (e) {
      setError(errText(e));
    } finally {
      setBusy(null);
    }
  };

  const applyPreset = (p) => {
    if (p.auth === MCP_AUTH.OAUTH) { add({ name: p.name, url: p.url }); return; }
    // No self-registration: the person supplies a token or their own OAuth app.
    setForm({ ...EMPTY_FORM, name: p.name, url: p.url });
    setNote(p.note);
  };

  const reauth = async (c) => {
    setBusy(c.id);
    setError('');
    try { await reauthMcpConnection(c.id); } catch (e) { setError(errText(e)); }
    await load();
    setBusy(null);
  };

  const remove = async () => {
    const c = removing;
    setRemoving(null);
    try { await removeMcpConnection(c.id); } catch (e) { setError(errText(e)); }
    await load();
  };

  const set = (k) => (e) => setForm((f) => ({ ...f, [k]: e.target.value }));
  const connectedUrls = new Set(connections.map((c) => c.url));

  return (
    <>
      <h1 className={styles.settingsTitle}>Connected apps (MCP)</h1>
      <p className={styles.sectionDesc}>
        Send Lore items to Linear, GitHub, Jira and other apps through their MCP servers.
        You check every draft and press Create. Nothing is sent on its own.
      </p>

      {!desktop && <p className={styles.tableEmpty}>Available in the desktop app.</p>}

      {desktop && (
        <>
          {connections.map((c) => (
            <div key={c.id} className={styles.providerCard}>
              <div className={styles.providerHeader}>
                <SendToLogo url={c.url} />
                <div>
                  <h3 className={styles.providerName}>{c.name}</h3>
                  <p className={styles.providerDesc}>{c.url} · {AUTH_LABEL[c.auth]}</p>
                </div>
                <span
                  className={styles.providerStatus}
                  data-status={c.status === MCP_STATUS.CONNECTED ? 'connected' : 'error'}
                  title={c.error || undefined}
                >
                  {STATUS_LABEL[c.status]}
                </span>
              </div>
              <div className={styles.dangerLinkRow}>
                {c.auth !== MCP_AUTH.TOKEN && (
                  <Button variant="link" onClick={() => reauth(c)} disabled={busy === c.id}>
                    {busy === c.id ? 'Waiting for the browser…' : c.auth === MCP_AUTH.OAUTH ? 'Sign in again' : 'Check again'}
                  </Button>
                )}
                <Button variant="danger-link" onClick={() => setRemoving(c)}>Remove</Button>
              </div>
            </div>
          ))}

          {presets.length > 0 && (
            <div className={styles.providerCard}>
              <h3 className={styles.providerName}>Add an app</h3>
              <div className={`${styles.providerActions} ${styles.dangerLinkRow}`}>
                {presets.filter((p) => !connectedUrls.has(p.url)).map((p) => (
                  <Button
                    key={p.url}
                    variant="secondary"
                    onClick={() => applyPreset(p)}
                    disabled={busy === 'add'}
                    title={p.verified ? p.note || undefined : `Unverified address. ${p.note}`}
                  >
                    {p.name}
                  </Button>
                ))}
              </div>
            </div>
          )}

          <div className={styles.providerCard}>
            <h3 className={styles.providerName}>Any MCP server</h3>
            {note && <p className={styles.providerHint}>{note}</p>}
            <div className={styles.settingsField}>
              <FormField label="Name" value={form.name} onChange={set('name')} placeholder="Linear" />
            </div>
            <div className={styles.settingsField}>
              <FormField label="Server URL" value={form.url} onChange={set('url')} placeholder="https://mcp.example.com/mcp" />
            </div>
            <div className={styles.settingsField}>
              <FormField
                label="Access token (optional)"
                type="password"
                autoComplete="off"
                value={form.token}
                onChange={set('token')}
                hint="Leave empty to sign in in the browser."
              />
            </div>
            <div className={styles.settingsField}>
              <FormField
                label="OAuth client ID (optional)"
                value={form.clientId}
                onChange={set('clientId')}
                hint="Only for servers that don't let apps register themselves (HubSpot, Asana, Salesforce)."
              />
            </div>
            {form.clientId && (
              <div className={styles.settingsField}>
                <FormField label="OAuth client secret (optional)" type="password" autoComplete="off" value={form.clientSecret} onChange={set('clientSecret')} />
              </div>
            )}
            <div className={styles.providerActions}>
              <Button className={styles.settingsButton} onClick={() => add(form)} disabled={!form.url.trim() || busy === 'add'}>
                {busy === 'add' ? 'Connecting…' : 'Connect'}
              </Button>
              {busy === 'add' && <span className={styles.providerHint}>Finish signing in in your browser.</span>}
            </div>
          </div>

          <ErrorMessage>{error}</ErrorMessage>
        </>
      )}

      <ConfirmDialog
        open={!!removing}
        title={`Remove ${removing?.name || 'this app'}?`}
        message="inbox2 forgets the connection and its sign-in on this device."
        confirmLabel="Remove"
        onConfirm={remove}
        onCancel={() => setRemoving(null)}
      />
    </>
  );
}
