import { lazy, Suspense, useCallback, useEffect, useMemo, useRef, useState } from 'react';
import Button from '../../components/Button/Button';
import FormField, { ErrorMessage } from '../../components/FormField/FormField';
import ConfirmDialog from '../../components/ConfirmDialog/ConfirmDialog';
import Modal from '../../components/Modal/Modal';
import SearchSelect from '../../components/SearchSelect/SearchSelect';
import Skeleton from '../../components/Skeleton';
import useAuth from '../../hooks/useAuth';
import { isAdminRole } from '../../lib/orgRoles';
import { cleanSignatureHtml, imageToDataUrl, loadSignatures, reloadSignatures } from '../../lib/signatures';
import api from '../../lib/api';
import styles from './settings.module.css';
import own from './SignaturesSettings.module.css';

// TipTap is heavy: only load it when the editor opens.
const RichEditor = lazy(() => import('../../components/RichEditor'));

/* Settings › Signatures (spec 8.1.7). A person's own signatures, for one address
 * or all of them, and the domain signatures an admin sets for everyone on a
 * domain. The API says which one goes under mail from each address. */

const errText = (e) => e?.data?.errors?.[0]?.message || e?.message || 'That did not work. Try again.';

function Preview({ html }) {
  // Sanitized: a domain signature is written by an admin and shown to everyone.
  return <div className={own.preview} dangerouslySetInnerHTML={{ __html: cleanSignatureHtml(html) }} />;
}

export default function SignaturesSettings({ orgId }) {
  const { organizations, user } = useAuth();
  const org = organizations?.find((o) => o.id === orgId || o.slug === orgId);
  const isAdmin = isAdminRole(org?.role);
  const [data, setData] = useState(null);
  const [loadError, setLoadError] = useState('');
  const [editing, setEditing] = useState(null); // { sig?, shared }
  const [removing, setRemoving] = useState(null);
  const [error, setError] = useState('');

  const load = useCallback((fresh) => {
    (fresh ? reloadSignatures(orgId, user?.id) : loadSignatures(orgId, user?.id))
      .then((d) => { setLoadError(''); setData(d); }, (e) => setLoadError(errText(e)));
  }, [orgId, user?.id]);
  useEffect(() => { load(false); }, [load]);

  const byId = useMemo(() => Object.fromEntries((data?.signatures || []).map((s) => [s.id, s])), [data]);
  const mine = (data?.signatures || []).filter((s) => s.scope === 'personal');
  const shared = (data?.signatures || []).filter((s) => s.scope !== 'personal');
  const addresses = org?.from_addresses || [];

  const remove = async () => {
    const s = removing;
    setRemoving(null);
    try { await api.deleteSignature(orgId, s.id); load(true); } catch (e) { setError(errText(e)); }
  };

  if (!data) {
    return (
      <>
        <h1 className={styles.settingsTitle}>Signatures</h1>
        {loadError
          ? <div className={own.row}><ErrorMessage>{loadError}</ErrorMessage><Button variant="link" onClick={() => load(true)}>Try again</Button></div>
          : <div aria-busy="true"><Skeleton variant="text" count={4} /></div>}
      </>
    );
  }

  const card = (s) => (
    <div key={s.id} className={own.card}>
      <div className={own.cardHead}>
        <div>
          <div className={styles.providerName}>{s.name}</div>
          <div className={styles.providerDesc}>
            {s.scope === 'personal' ? (s.from_address || 'All your addresses') : (s.domain_name || 'Every domain')}
          </div>
        </div>
        {s.editable && (
          <div className={own.actions}>
            <Button variant="secondary" onClick={() => setEditing({ sig: s, shared: s.scope !== 'personal' })}>Edit</Button>
            <Button variant="danger-link" onClick={() => setRemoving(s)}>Delete</Button>
          </div>
        )}
      </div>
      <Preview html={s.body_html} />
    </div>
  );

  return (
    <>
      <h1 className={styles.settingsTitle}>Signatures</h1>
      <ErrorMessage>{error}</ErrorMessage>

      <div className={styles.settingsSection}>
        <div className={styles.settingsSectionTitle}>Your addresses</div>
        <table className={styles.settingsTable}>
          <thead><tr><th>Address</th><th>Signature</th></tr></thead>
          <tbody>
            {addresses.map((a) => {
              const applied = data.applied?.[a.toLowerCase()];
              return (
                <tr key={a}>
                  <td className={styles.tablePrimary}>{a}</td>
                  <td className={applied ? undefined : styles.tableSecondary}>{applied ? byId[applied.id]?.name : 'No signature'}</td>
                </tr>
              );
            })}
          </tbody>
        </table>
        <p className={`${styles.settingsHint} ${own.hint}`}>Your signature for an address comes first. Then the domain’s, then your default.</p>
      </div>

      <div className={styles.settingsSection}>
        <div className={own.sectionHead}>
          <div className={styles.settingsSectionTitle}>Your signatures</div>
          <Button variant="secondary" onClick={() => setEditing({ shared: false })}>New signature</Button>
        </div>
        {mine.length ? mine.map(card) : <p className={styles.tableEmpty}>Add a signature for your mail.</p>}
      </div>

      <div className={styles.settingsSection}>
        <div className={own.sectionHead}>
          <div className={styles.settingsSectionTitle}>Domain signatures</div>
          {isAdmin && <Button variant="secondary" onClick={() => setEditing({ shared: true })}>New domain signature</Button>}
        </div>
        {shared.length
          ? shared.map(card)
          : <p className={styles.tableEmpty}>{isAdmin ? 'Set one signature for everyone on a domain.' : 'Your admin hasn’t set one.'}</p>}
      </div>

      {editing && (
        <SignatureEditor
          orgId={orgId}
          editing={editing}
          addresses={addresses}
          domains={org?.domains || []}
          onClose={() => setEditing(null)}
          onSaved={() => { setEditing(null); load(true); }}
        />
      )}

      <ConfirmDialog
        open={!!removing}
        title="Delete this signature?"
        message="Mail you already sent keeps it."
        confirmLabel="Delete"
        onConfirm={remove}
        onCancel={() => setRemoving(null)}
      />
    </>
  );
}

function SignatureEditor({ orgId, editing, addresses, domains, onClose, onSaved }) {
  const { sig, shared } = editing;
  const [name, setName] = useState(sig?.name || '');
  const [target, setTarget] = useState(shared ? (sig?.domain_id || domains[0]?.id || '') : (sig?.from_address || ''));
  const [html, setHtml] = useState(sig?.body_html || '');
  const [editor, setEditor] = useState(null);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState('');
  const fileRef = useRef(null);

  const options = shared
    ? [...domains.map((d) => ({ value: d.id, label: d.name })), { value: '', label: 'Every domain' }]
    : [{ value: '', label: 'All your addresses' }, ...addresses.map((a) => ({ value: a, label: a }))];

  const addImage = async (e) => {
    const file = e.target.files?.[0];
    e.target.value = '';
    if (!file || !editor) return;
    try {
      const { src, width } = await imageToDataUrl(file);
      editor.chain().focus().setImage({ src, width }).run();
    } catch { setError('That image could not be read. Try a PNG or JPEG.'); }
  };

  const save = async () => {
    setBusy(true);
    setError('');
    const body = shared
      ? { name: name.trim(), body_html: html, domain_id: target, shared: true }
      : { name: name.trim(), body_html: html, from_address: target, is_default: !target };
    try {
      if (sig) await api.updateSignature(orgId, sig.id, body);
      else await api.createSignature(orgId, body);
      onSaved();
    } catch (err) { setError(errText(err)); setBusy(false); }
  };

  return (
    <Modal open onClose={onClose} className={own.modal} titleId="signature-editor-title">
      <h2 id="signature-editor-title" className={styles.settingsModalTitle}>
        {sig ? 'Edit signature' : shared ? 'New domain signature' : 'New signature'}
      </h2>
      <div className={own.fields}>
        <FormField label="Name" value={name} onChange={(e) => setName(e.target.value)} placeholder={shared ? 'e.g. Lalaaji' : 'e.g. Work'} />
        <FormField label="Use for">
          <SearchSelect id="signature-target" label="Use for" value={target} onChange={setTarget} options={options} />
        </FormField>
      </div>
      <div className={own.editorHead}>
        <span className={own.editorLabel}>Signature</span>
        <Button variant="secondary" onClick={() => fileRef.current?.click()} disabled={!editor}>Add image</Button>
        <input ref={fileRef} type="file" accept="image/png,image/jpeg,image/gif,image/webp" className={own.hiddenInput} onChange={addImage} />
      </div>
      <div className={own.editor}>
        <Suspense fallback={<Skeleton variant="text" count={3} />}>
          <RichEditor
            content={html}
            placeholder="Your name, role and phone"
            autofocus={false}
            onUpdate={({ html: h }) => setHtml(h)}
            onEditor={setEditor}
          />
        </Suspense>
      </div>
      {shared && <p className={styles.settingsHint}>Use {'{{name}}'} and {'{{email}}'} for each sender’s name and address.</p>}
      <ErrorMessage>{error}</ErrorMessage>
      <div className={styles.settingsModalActions}>
        <Button variant="secondary" onClick={onClose}>Cancel</Button>
        <Button onClick={save} disabled={busy || !name.trim()}>{busy ? 'Saving…' : 'Save'}</Button>
      </div>
    </Modal>
  );
}
