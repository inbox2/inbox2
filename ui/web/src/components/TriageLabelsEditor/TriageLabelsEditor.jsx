import { useState } from 'react';
import Icon from '../Icon';
import Button from '../Button/Button';
import IconButton from '../IconButton/IconButton';
import Switch from '../Switch/Switch';
import FormField, { ErrorMessage } from '../FormField/FormField';
import ConfirmDialog from '../ConfirmDialog/ConfirmDialog';
import { FALLBACK_TRIAGE_LABEL } from '../../lib/triage';
import { PALETTE_KEYS, paletteSolid } from '../../lib/spaceColors';
import styles from './TriageLabelsEditor.module.css';

const NEW = Symbol('new');

// Palette colors are data — set through a custom property (no inline styles).
const paint = (key) => (el) => { if (el) el.style.setProperty('--label-color', paletteSolid(key) || 'transparent'); };

/**
 * Editor for Jev's triage labels (docs/Triage.md), shared by the local-channel
 * list (Settings › Triage & sync) and the MX org list (Settings › Triage labels).
 * Built-ins come first: they can be switched off (except `fyi`, the fallback)
 * and their description / "not for" edited, never renamed or deleted. Custom
 * labels get the full add / edit / delete.
 *
 * The data source is the caller's: `onCreate(draft)`, `onUpdate(label, patch)`
 * and `onRemove(label)` return promises and throw a displayable Error.
 * `readOnly` shows the list without controls (non-admin org members).
 */
export default function TriageLabelsEditor({ labels, readOnly = false, onCreate, onUpdate, onRemove }) {
  const [editing, setEditing] = useState(null); // label slug | NEW | null
  const [draft, setDraft] = useState(null);
  const [error, setError] = useState('');
  const [busy, setBusy] = useState(false);
  const [confirmDelete, setConfirmDelete] = useState(null);

  if (!labels) return <p className={styles.note}>Loading labels…</p>;

  const ordered = [...labels.filter((l) => l.builtin), ...labels.filter((l) => !l.builtin)];

  const run = async (fn) => {
    setBusy(true);
    setError('');
    try {
      await fn();
      return true;
    } catch (e) {
      setError(e.message);
      return false;
    } finally {
      setBusy(false);
    }
  };

  const open = (label) => {
    setError('');
    setEditing(label ? label.slug : NEW);
    setDraft({
      name: label?.name || '',
      description: label?.description || '',
      not_for: label?.not_for || '',
      color: label?.color || null,
    });
  };
  const close = () => { setEditing(null); setDraft(null); };

  const save = async (label) => {
    const fields = {
      description: draft.description.trim(),
      not_for: draft.not_for.trim(),
    };
    if (!label?.builtin) Object.assign(fields, { name: draft.name.trim(), color: draft.color });
    const ok = await run(() => (label ? onUpdate(label, fields) : onCreate(fields)));
    if (ok) close();
  };

  const form = (label) => {
    const builtin = !!label?.builtin;
    const canSave = draft.description.trim() && (builtin || draft.name.trim());
    return (
      <div className={styles.form}>
        {!builtin && (
          <FormField
            label="Name"
            aria-label="Label name"
            value={draft.name}
            onChange={(e) => setDraft({ ...draft, name: e.target.value })}
            placeholder="e.g. Legal review"
            autoFocus
          />
        )}
        <FormField label="What it's for" hint="Jev reads this to decide when the label fits.">
          <textarea
            className={styles.textarea}
            aria-label="What the label is for"
            value={draft.description}
            onChange={(e) => setDraft({ ...draft, description: e.target.value })}
            placeholder="A contract, NDA or terms change that needs legal to look at it"
            rows={2}
            autoFocus={builtin}
          />
        </FormField>
        <FormField label="Not for (optional)" hint="What looks similar but doesn't belong here.">
          <textarea
            className={styles.textarea}
            aria-label="What the label is not for"
            value={draft.not_for}
            onChange={(e) => setDraft({ ...draft, not_for: e.target.value })}
            placeholder="Marketing mail that mentions terms and conditions"
            rows={2}
          />
        </FormField>
        {!builtin && (
          <div className={styles.colors} role="radiogroup" aria-label="Label color">
            {[null, ...PALETTE_KEYS].map((key) => (
              <button
                key={key || 'none'}
                type="button"
                role="radio"
                aria-checked={draft.color === key}
                aria-label={key || 'No color'}
                className={`${styles.swatch} ${key ? '' : styles.swatchNone} ${draft.color === key ? styles.swatchOn : ''}`}
                ref={paint(key)}
                onClick={() => setDraft({ ...draft, color: key })}
              />
            ))}
          </div>
        )}
        <div className={styles.formActions}>
          <Button onClick={() => save(label)} disabled={busy || !canSave}>
            {label ? 'Save' : 'Add label'}
          </Button>
          <Button variant="link" onClick={close}>Cancel</Button>
        </div>
      </div>
    );
  };

  return (
    <div className={styles.editor}>
      <ErrorMessage>{error}</ErrorMessage>
      <ul className={styles.list}>
        {ordered.map((l) => (
          <li key={l.slug} className={styles.row}>
            <div className={styles.rowMain}>
              <span className={`${styles.dot} ${l.color ? '' : styles.dotNone}`} ref={paint(l.color)} aria-hidden="true" />
              <div className={styles.rowText}>
                <span className={styles.name}>
                  {l.name}
                  {l.builtin && <span className={styles.builtinTag}>Built-in</span>}
                </span>
                <span className={styles.desc}>{l.description}</span>
                {l.not_for && <span className={styles.notFor}>Not for: {l.not_for}</span>}
              </div>
              {!readOnly && (
                <div className={styles.rowActions}>
                  <IconButton icon="pencil" size="sm" aria-label={`Edit ${l.name}`} onClick={() => open(l)} disabled={busy} />
                  {!l.builtin && (
                    <IconButton icon="trash" size="sm" variant="danger" aria-label={`Delete ${l.name}`} onClick={() => setConfirmDelete(l)} disabled={busy} />
                  )}
                </div>
              )}
              <Switch
                id={`triage-label-${l.slug}`}
                ariaLabel={l.slug === FALLBACK_TRIAGE_LABEL ? `${l.name} is always on` : `Use ${l.name}`}
                checked={l.enabled !== false}
                disabled={readOnly || busy || l.slug === FALLBACK_TRIAGE_LABEL}
                onChange={(on) => run(() => onUpdate(l, { enabled: on }))}
              />
            </div>
            {editing === l.slug && draft && form(l)}
          </li>
        ))}
      </ul>

      {!readOnly && (editing === NEW && draft
        ? <div className={styles.newWrap}>{form(null)}</div>
        : (
          <Button variant="secondary" className={styles.addBtn} onClick={() => open(null)} disabled={busy}>
            <Icon name="plus" size={12} /> New label
          </Button>
        ))}

      <ConfirmDialog
        open={!!confirmDelete}
        title="Delete this label?"
        message={confirmDelete ? `Threads already labelled “${confirmDelete.name}” keep it until they're triaged again.` : ''}
        confirmLabel="Delete label"
        onConfirm={async () => {
          const l = confirmDelete;
          setConfirmDelete(null);
          if (editing === l.slug) close();
          await run(() => onRemove(l));
        }}
        onCancel={() => setConfirmDelete(null)}
      />
    </div>
  );
}
