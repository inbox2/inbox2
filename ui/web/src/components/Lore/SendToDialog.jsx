import { useEffect, useState } from 'react';
import Modal from '../Modal/Modal';
import Button from '../Button/Button';
import FormField, { ErrorMessage } from '../FormField/FormField';
import Spinner from '../Spinner';
import Icon from '../Icon';
import Checkbox from '../Checkbox/Checkbox';
import SendToLogo from './SendToLogo';
import {
  mcpAvailable, listMcpConnections, listMcpTools, callMcpTool, reauthMcpConnection,
  rankTools, buildDefaults, buildArguments, missingRequired, schemaFields, firstText,
  NEEDS_AUTH, MCP_STATUS,
} from '../../lib/mcpClient';
import styles from './SendTo.module.css';

const errText = (e) => String(e?.message || e || 'Something went wrong');

/**
 * Send a Lore item to a connected app (Linear, GitHub, Jira, …) through its
 * MCP server. Draft-only: the arguments are prefilled and editable, and nothing
 * is sent until the person presses Create. docs/MCP-Client.md.
 *
 * Props:
 *   item    — { subject, detail, from, address, domain, source, id }
 *   onClose — close the dialog
 *   onSent  — ({ connection, tool, summary }) after a successful Create;
 *             summary is the result's first text block (e.g. the issue URL)
 */
export default function SendToDialog({ item, onClose, onSent }) {
  const desktop = mcpAvailable();
  const [connections, setConnections] = useState(null);
  const [conn, setConn] = useState(null);
  const [tools, setTools] = useState(null);
  const [tool, setTool] = useState(null);
  const [values, setValues] = useState({});
  const [error, setError] = useState('');
  const [busy, setBusy] = useState(false);
  const [summary, setSummary] = useState(null);

  const chooseTool = (c, t) => {
    setTool(t);
    setValues(t ? buildDefaults(c.url, t, item) : {});
    setError('');
  };

  const pick = async (c) => {
    setConn(c);
    setTools(null);
    chooseTool(c, null);
    try {
      const ranked = rankTools(c.url, await listMcpTools(c.id));
      setTools(ranked);
      chooseTool(c, ranked[0] || null);
    } catch (e) {
      setTools([]);
      setError(errText(e));
    }
  };

  useEffect(() => {
    if (!desktop) return undefined;
    let live = true;
    listMcpConnections()
      .then((cs) => {
        if (!live) return;
        setConnections(cs);
        const first = cs.find((c) => c.status === MCP_STATUS.CONNECTED) || cs[0];
        if (first) pick(first);
      })
      .catch((e) => { if (live) { setConnections([]); setError(errText(e)); } });
    return () => { live = false; };
    // Load once per open; `pick` is stable enough for that.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [desktop]);

  const reauth = async () => {
    setBusy(true);
    try {
      const fresh = await reauthMcpConnection(conn.id);
      setConnections((cs) => cs.map((c) => (c.id === fresh.id ? fresh : c)));
      await pick(fresh);
    } catch (e) {
      setError(errText(e));
    } finally {
      setBusy(false);
    }
  };

  const create = async () => {
    let args;
    try { args = buildArguments(tool, values); } catch (e) { setError(errText(e)); return; }
    setBusy(true);
    setError('');
    try {
      const res = await callMcpTool(conn.id, tool.name, args);
      const text = firstText(res.content);
      if (res.is_error) { setError(text || `${tool.name} reported an error`); return; }
      setSummary(text || 'Created.');
      onSent?.({ item, connection: conn, tool: tool.name, summary: text });
    } catch (e) {
      setError(errText(e));
    } finally {
      setBusy(false);
    }
  };

  const set = (key, v) => setValues((s) => ({ ...s, [key]: v }));
  const missing = tool ? missingRequired(tool, values) : [];
  const needsAuth = error === NEEDS_AUTH;

  return (
    <Modal open onClose={onClose} className={styles.dialog} titleId="sendto-title">
      <div>
        <h2 id="sendto-title" className={styles.title}>Send to…</h2>
        <p className={styles.subtitle}>{item.subject}</p>
      </div>

      {!desktop && <p className={styles.note}>Available in the desktop app.</p>}

      {desktop && connections === null && (
        <div className={styles.loading}><Spinner size="md" /> Loading connected apps…</div>
      )}

      {desktop && connections?.length === 0 && (
        <p className={styles.note}>No apps connected yet. Add one in Settings › Connected apps (MCP).</p>
      )}

      {desktop && connections?.length > 0 && (
        <div className={styles.destinations} role="group" aria-label="Destination">
          {connections.map((c) => (
            <button
              key={c.id}
              type="button"
              className={styles.destination}
              aria-pressed={conn?.id === c.id}
              data-status={c.status}
              onClick={() => pick(c)}
              disabled={busy}
            >
              <SendToLogo url={c.url} />
              {c.name}
            </button>
          ))}
        </div>
      )}

      {conn && tools === null && !error && (
        <div className={styles.loading}><Spinner size="md" /> Loading {conn.name} tools…</div>
      )}

      {conn && tools?.length > 0 && !summary && (
        <div className={styles.fields}>
          <FormField label="Action">
            <select
              className={styles.select}
              value={tool?.name || ''}
              onChange={(e) => chooseTool(conn, tools.find((t) => t.name === e.target.value))}
            >
              {tools.map((t) => <option key={t.name} value={t.name}>{t.name}</option>)}
            </select>
          </FormField>
          {tool?.description && <p className={styles.toolHint}>{tool.description.slice(0, 300)}</p>}
          {tool && schemaFields(tool.input_schema).map((f) => (
            <ToolField key={`${tool.name}:${f.key}`} field={f} value={values[f.key]} onChange={(v) => set(f.key, v)} />
          ))}
        </div>
      )}

      {conn && tools?.length === 0 && !error && <p className={styles.note}>{conn.name} offers no tools.</p>}

      {summary && (
        <div className={styles.result}><Icon name="checkmark.circle.fill" size={14} /> {summary}</div>
      )}

      <ErrorMessage>{needsAuth ? `${conn?.name || 'This app'} needs you to sign in again.` : error}</ErrorMessage>

      <div className={styles.actions}>
        {summary ? (
          <Button onClick={onClose}>Done</Button>
        ) : (
          <>
            <Button variant="secondary" onClick={onClose}>Cancel</Button>
            {needsAuth ? (
              <Button onClick={reauth} disabled={busy}>{busy ? 'Waiting for the browser…' : 'Sign in again'}</Button>
            ) : (
              <Button onClick={create} disabled={!tool || busy || missing.length > 0}>
                {busy ? 'Creating…' : 'Create'}
              </Button>
            )}
          </>
        )}
      </div>
    </Modal>
  );
}

function ToolField({ field, value, onChange }) {
  const label = `${field.label}${field.required ? ' *' : ''}`;
  const hint = field.description.length > 160 ? `${field.description.slice(0, 160)}…` : field.description;
  if (field.type === 'boolean') {
    return (
      <Checkbox checked={!!value} onChange={(e) => onChange(e.target.checked)}>
        {label}
      </Checkbox>
    );
  }
  if (field.type === 'enum') {
    return (
      <FormField label={label} hint={hint}>
        <select className={styles.select} value={value ?? ''} onChange={(e) => onChange(e.target.value)}>
          <option value="">—</option>
          {field.options.map((o) => <option key={String(o)} value={o}>{String(o)}</option>)}
        </select>
      </FormField>
    );
  }
  if (field.type === 'json' || (field.type === 'string' && /description|body|content|text|note|message|detail/i.test(field.key))) {
    return (
      <FormField label={field.type === 'json' ? `${label} (JSON)` : label} hint={hint}>
        <textarea
          className={`${styles.textarea} ${field.type === 'json' ? styles.mono : ''}`}
          value={value ?? ''}
          onChange={(e) => onChange(e.target.value)}
        />
      </FormField>
    );
  }
  return (
    <FormField
      label={label}
      hint={hint}
      type={field.type === 'string' ? 'text' : 'number'}
      value={value ?? ''}
      onChange={(e) => onChange(e.target.value)}
    />
  );
}
