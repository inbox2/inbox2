import { useState, useCallback } from 'react';
import Icon from '../../components/Icon';
import Skeleton from '../../components/Skeleton';
import { MgmtButton, MgmtField, MgmtConfirm } from '../../components/management';
import useCopyToClipboard from '../../hooks/useCopyToClipboard';
import keys from './ApiKeysPage.module.css';
import own from './TokenList.module.css';

function fmtDate(iso) {
  return iso ? new Date(iso).toLocaleDateString(undefined, { year: 'numeric', month: 'short', day: 'numeric' }) : null;
}

/* A named secret that is shown once: create it, copy it, see the list, remove
 * one. Sending keys (ConsoleSending) and app passwords (ConsoleMailClients).
 *
 * items: null while loading, else [{ id, name, prefix?, last_used_at, created_at }]
 * onCreate(name) resolves to the raw token; onRemove(item) removes it.
 * copy: { placeholder, create, created, empty, remove, removeTitle, removeBody } */
export default function TokenList({ items, onCreate, onRemove, copy }) {
  const [name, setName] = useState('');
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState('');
  const [revealed, setRevealed] = useState(null); // { name, token }
  const [removing, setRemoving] = useState(null);
  const [copied, copyText] = useCopyToClipboard();

  const create = useCallback(async () => {
    const trimmed = name.trim();
    if (!trimmed || busy) return;
    setBusy(true);
    setError('');
    try {
      setRevealed({ name: trimmed, token: await onCreate(trimmed) });
      setName('');
    } catch (e) {
      setError(e?.data?.errors?.[0]?.message || e?.message || 'That did not work. Try again.');
    } finally {
      setBusy(false);
    }
  }, [name, busy, onCreate]);

  const confirmRemove = useCallback(async () => {
    setBusy(true);
    try {
      await onRemove(removing);
      setRemoving(null);
    } catch (e) {
      setError(e?.message || 'That did not work. Try again.');
    } finally {
      setBusy(false);
    }
  }, [removing, onRemove]);

  return (
    <div className={own.body}>
      {revealed && (
        <div className={keys.reveal} role="status">
          <div className={keys.revealHead}>
            <Icon name="checkmark.circle.fill" size={16} />
            <span>{copy.created(revealed.name)}</span>
          </div>
          <div className={keys.revealRow}>
            <code className={keys.revealToken}>{revealed.token}</code>
            <MgmtButton variant="dark" onClick={() => copyText(revealed.token)}>
              <Icon name={copied ? 'checkmark' : 'doc.on.doc'} size={13} /> {copied ? 'Copied' : 'Copy'}
            </MgmtButton>
          </div>
          <button type="button" className={keys.revealDismiss} onClick={() => setRevealed(null)}>Done</button>
        </div>
      )}

      <div className={keys.createRow}>
        <MgmtField
          className={keys.nameField}
          label="Name"
          value={name}
          onChange={(e) => setName(e.target.value)}
          placeholder={copy.placeholder}
          autoComplete="off"
          onKeyDown={(e) => { if (e.key === 'Enter') create(); }}
        />
        <MgmtButton variant="primary" onClick={create} disabled={!name.trim() || busy}>{copy.create}</MgmtButton>
      </div>
      {error && <p className={keys.error} role="alert">{error}</p>}

      {items === null ? <Skeleton variant="text" count={2} /> : items.length === 0 ? (
        <p className={keys.empty}>{copy.empty}</p>
      ) : (
        <ul className={keys.list}>
          {items.map((k) => {
            const last = fmtDate(k.last_used_at);
            const created = fmtDate(k.created_at);
            return (
              <li key={k.id} className={keys.row}>
                <div className={keys.rowMain}>
                  <span className={keys.keyName}>{k.name}</span>
                  {k.prefix && <code className={keys.keyPrefix}>{k.prefix}…</code>}
                </div>
                <div className={keys.rowMeta}>
                  <span>{last ? `Last used ${last}` : 'Never used'}</span>
                  {created && <span>· Created {created}</span>}
                </div>
                <MgmtButton variant="ghost" className={keys.revokeBtn} onClick={() => setRemoving(k)}>{copy.remove}</MgmtButton>
              </li>
            );
          })}
        </ul>
      )}

      <MgmtConfirm
        open={!!removing}
        title={copy.removeTitle}
        message={removing ? copy.removeBody(removing.name) : ''}
        confirmLabel={copy.remove}
        danger
        busy={busy}
        onConfirm={confirmRemove}
        onClose={() => setRemoving(null)}
      />
    </div>
  );
}
