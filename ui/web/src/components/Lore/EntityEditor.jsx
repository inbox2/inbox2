import { useEffect, useState } from 'react';
import Modal from '../Modal/Modal';
import Button from '../Button/Button';
import ConfirmDialog from '../ConfirmDialog/ConfirmDialog';
import FormField, { ErrorMessage } from '../FormField/FormField';
import Icon from '../Icon';
import Tooltip from '../Tooltip';
import { loreEdits } from '../../hooks/useLoreFacts';
import { LORE_KIND_LABEL } from '../../lib/lore';
import styles from './Lore.module.css';

const errText = (e) => e?.message || String(e || 'That did not work. Try again.');

// One dialog at a time per row: 'rename' | 'kind' | 'merge' | 'remove' | null.
function useDialog() {
  const [open, setOpen] = useState(null);
  return { open, show: setOpen, close: () => setOpen(null) };
}

function Actions({ onClose, onSave, saving, label = 'Save', disabled = false }) {
  return (
    <div className={styles.editActions}>
      <Button variant="ghost" onClick={onClose}>Cancel</Button>
      <Button onClick={onSave} disabled={saving || disabled}>{label}</Button>
    </div>
  );
}

function NameField({ name, onClose, onSave }) {
  const [value, setValue] = useState(name);
  const [state, setState] = useState({ saving: false, error: null });
  const save = async () => {
    setState({ saving: true, error: null });
    try { await onSave(value); onClose(); } catch (e) { setState({ saving: false, error: errText(e) }); }
  };
  return (
    <Modal open onClose={onClose} className={styles.editDialog} titleId="lore-rename">
      <h2 id="lore-rename" className={styles.editTitle}>Rename {name}</h2>
      <FormField label="Name" value={value} onChange={(e) => setValue(e.target.value)} />
      <ErrorMessage>{state.error}</ErrorMessage>
      <Actions onClose={onClose} onSave={save} saving={state.saving} disabled={!value.trim() || value.trim() === name} />
    </Modal>
  );
}

function KindDialog({ entity, onClose, onSave }) {
  const [error, setError] = useState(null);
  const pick = async (kind) => {
    if (kind === entity.kind) return onClose();
    setError(null);
    try { await onSave(kind); onClose(); } catch (e) { setError(errText(e)); }
    return undefined;
  };
  return (
    <Modal open onClose={onClose} className={styles.editDialog} titleId="lore-kind">
      <h2 id="lore-kind" className={styles.editTitle}>Change the type of {entity.name}</h2>
      {Object.entries(LORE_KIND_LABEL).map(([kind, label]) => (
        <button key={kind} type="button" className={styles.kindOption} aria-pressed={kind === entity.kind} onClick={() => pick(kind)}>
          {label}
        </button>
      ))}
      <ErrorMessage>{error}</ErrorMessage>
    </Modal>
  );
}

function MergeDialog({ entity, edits, onClose, onMerged }) {
  const [q, setQ] = useState('');
  const [hits, setHits] = useState([]);
  const [error, setError] = useState(null);
  useEffect(() => {
    let live = true;
    const t = setTimeout(() => {
      edits.search(q).then((rows) => { if (live) setHits(rows.filter((r) => r.id !== entity.id)); }).catch((e) => { if (live) setError(errText(e)); });
    }, 150);
    return () => { live = false; clearTimeout(t); };
  }, [q, edits, entity.id]);
  const pick = async (target) => {
    setError(null);
    try { await edits.merge(entity.id, target.id); onMerged(target); } catch (e) { setError(errText(e)); }
  };
  return (
    <Modal open onClose={onClose} className={styles.editDialog} titleId="lore-merge">
      <h2 id="lore-merge" className={styles.editTitle}>Merge {entity.name} into another</h2>
      <p className={styles.muted}>Facts and threads move to the one you pick. New mail about {entity.name} goes there too.</p>
      <FormField label="Search" placeholder="Name or address" value={q} onChange={(e) => setQ(e.target.value)} autoFocus />
      <div className={styles.mergeList}>
        {hits.map((h) => (
          <button key={h.id} type="button" className={styles.mergeHit} onClick={() => pick(h)}>
            {h.name}
            <span className={styles.mergeMeta}>{LORE_KIND_LABEL[h.kind]}{h.address ? ` · ${h.address}` : h.email_domain ? ` · ${h.email_domain}` : ''}</span>
          </button>
        ))}
        {!hits.length && <p className={styles.muted}>Nothing found.</p>}
      </div>
      <ErrorMessage>{error}</ErrorMessage>
    </Modal>
  );
}

/** Rename, change type, merge and remove for one entity in one store (docs/Ontology.md "Editing"). */
export function EntityActions({ hit, showStore, onChanged, onGone }) {
  const { open, show, close } = useDialog();
  const [error, setError] = useState(null);
  const { entity, store } = hit;
  const edits = loreEdits(store);
  const tool = (key, icon, label) => (
    <Tooltip content={label}>
      <button type="button" className={styles.iconButton} onClick={() => show(key)} aria-label={label}>
        <Icon name={icon} size={13} />
      </button>
    </Tooltip>
  );
  const run = async (fn, after) => {
    setError(null);
    try { await fn(); after(); } catch (e) { setError(errText(e)); }
  };
  return (
    <div className={styles.entityTools}>
      {showStore && <span className={styles.entityToolsStore}>{store.device ? 'On this device' : 'Team knowledge'}</span>}
      {tool('rename', 'pencil', 'Rename')}
      {tool('kind', 'tag', 'Change type')}
      {tool('merge', 'arrow.triangle.branch', 'Merge into another')}
      {tool('remove', 'trash', 'Remove')}
      <ErrorMessage>{error}</ErrorMessage>
      {open === 'rename' && <NameField name={entity.name} onClose={close} onSave={(n) => edits.rename(entity.id, n).then(onChanged)} />}
      {open === 'kind' && <KindDialog entity={entity} onClose={close} onSave={(k) => edits.setKind(entity.id, k).then(onChanged)} />}
      {open === 'merge' && <MergeDialog entity={entity} edits={edits} onClose={close} onMerged={(target) => { close(); onGone(pageFor(target)); }} />}
      <ConfirmDialog
        open={open === 'remove'}
        title={`Remove ${entity.name}?`}
        message="Lore hides it and stops learning about it. Your mail stays as it is."
        confirmLabel="Remove"
        onCancel={close}
        onConfirm={() => run(() => edits.remove(entity.id), () => { close(); onGone(null); })}
      />
    </div>
  );
}

// Where a merge target's page is: only people and organizations have one.
function pageFor(e) {
  if (e.kind === 'person' && e.address) return { kind: 'person', address: e.address, name: e.name };
  if (e.kind === 'organization' && e.email_domain) return { kind: 'org', domain: e.email_domain, name: e.name };
  return null;
}

/** Edit or remove one fact. Both stay after the next mined mail. */
export function FactActions({ hit, fact, onChanged }) {
  const { open, show, close } = useDialog();
  const [error, setError] = useState(null);
  const edits = loreEdits(hit.store);
  const related = !!fact.related;
  const [name, setName] = useState(fact.name.replace(/_/g, ' '));
  const [value, setValue] = useState(fact.value || '');
  const save = async () => {
    setError(null);
    try {
      await edits.editFact(hit.entity.id, fact.id, related ? { name: name.trim() } : { name: name.trim(), value: value.trim() });
      close();
      onChanged();
    } catch (e) { setError(errText(e)); }
  };
  const remove = async () => {
    setError(null);
    try { await edits.removeFact(hit.entity.id, fact.id); close(); onChanged(); } catch (e) { setError(errText(e)); }
  };
  return (
    <span className={styles.factTools}>
      <button type="button" className={styles.iconButton} onClick={() => show('edit')} aria-label={`Edit ${fact.name.replace(/_/g, ' ')}`}>
        <Icon name="pencil" size={12} />
      </button>
      <button type="button" className={styles.iconButton} onClick={() => show('remove')} aria-label={`Remove ${fact.name.replace(/_/g, ' ')}`}>
        <Icon name="xmark" size={12} />
      </button>
      {open === 'edit' && (
        <Modal open onClose={close} className={styles.editDialog} titleId="lore-fact">
          <h2 id="lore-fact" className={styles.editTitle}>Edit this fact</h2>
          <FormField label="Name" value={name} onChange={(e) => setName(e.target.value)} />
          {!related && <FormField label="Value" value={value} onChange={(e) => setValue(e.target.value)} />}
          <ErrorMessage>{error}</ErrorMessage>
          <Actions onClose={close} onSave={save} disabled={!name.trim() || (!related && !value.trim())} />
        </Modal>
      )}
      <ConfirmDialog
        open={open === 'remove'}
        title="Remove this fact?"
        message="Lore hides it and does not learn it again from later mail."
        confirmLabel="Remove"
        onCancel={close}
        onConfirm={remove}
      />
    </span>
  );
}
