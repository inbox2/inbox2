import { useState, useEffect, useCallback } from 'react';
import api from '../../../lib/api';
import log from '../../../lib/log';
import Icon from '../../../components/Icon';
import Modal from '../../../components/Modal/Modal';
import Button from '../../../components/Button/Button';
import { MgmtSelect, MgmtCheckbox } from '../../../components/management';
import { spaceColor } from '../../../lib/spaceColors';
import styles from '../settings.module.css';
import local from './SpacesSettings.module.css';

const OPENNESS = [
  { value: 'assigned', label: 'Assigned members only' },
  { value: 'org', label: 'Whole domain' },
];

// Color swatch — gradient set via ref (inline styles are banned project-wide).
function Swatch({ slug }) {
  const color = spaceColor(slug);
  return <span className={local.swatch} ref={(el) => { if (el) el.style.background = color.gradient; }} />;
}

export default function SpacesSettings({ orgId }) {
  const [spaces, setSpaces] = useState([]);
  const [members, setMembers] = useState([]);
  const [draftName, setDraftName] = useState('');
  const [draftAlias, setDraftAlias] = useState('');
  const [draftOpenness, setDraftOpenness] = useState('assigned');
  const [editingKey, setEditingKey] = useState(null);
  const [edit, setEdit] = useState(null);
  const [showCreate, setShowCreate] = useState(false);

  const reload = useCallback(async () => {
    const data = await api.getSpaces(orgId);
    setSpaces(data.spaces || []);
  }, [orgId]);

  useEffect(() => {
    if (!orgId) return;
    api.getSpaces(orgId).then((d) => setSpaces(d.spaces || []))
      .catch((e) => log.warn('Spaces', `Failed to load spaces: ${e?.message || e}`));
    api.getMembers(orgId).then((d) => setMembers(d.members || []))
      .catch((e) => log.warn('Spaces', `Failed to load members: ${e?.message || e}`));
  }, [orgId]);

  const handleCreate = async () => {
    if (!draftName.trim()) return;
    try {
      await api.createSpace(orgId, {
        name: draftName.trim(),
        alias_local: draftAlias.trim() || undefined,
        openness: draftOpenness,
      });
      setDraftName(''); setDraftAlias(''); setDraftOpenness('assigned');
      setShowCreate(false);
      await reload();
    } catch (e) { log.warn('Spaces', `Create failed: ${e?.message || e}`); }
  };

  const startEdit = (space) => {
    setEditingKey(space.id === editingKey ? null : space.id);
    setEdit({
      name: space.name,
      description: space.description || '',
      not_for: space.not_for || '',
      openness: space.openness,
      classify: space.classify,
      memberKeys: new Set((space.members || []).map((m) => m.key).filter(Boolean)),
    });
  };

  const toggleMember = (key) => {
    setEdit((prev) => {
      const next = new Set(prev.memberKeys);
      if (next.has(key)) next.delete(key); else next.add(key);
      return { ...prev, memberKeys: next };
    });
  };

  const handleSave = async (space) => {
    try {
      await api.updateSpace(orgId, space.id, {
        name: edit.name.trim(),
        description: edit.description.trim(),
        not_for: edit.not_for.trim(),
        openness: edit.openness,
        classify: edit.classify,
        members: [...edit.memberKeys],
      });
      setEditingKey(null); setEdit(null);
      await reload();
    } catch (e) { log.warn('Spaces', `Save failed: ${e?.message || e}`); }
  };

  const handleDelete = async (space) => {
    try {
      await api.deleteSpace(orgId, space.id);
      setEditingKey(null);
      setSpaces((prev) => prev.filter((s) => s.id !== space.id));
    } catch (e) { log.warn('Spaces', `Delete failed: ${e?.message || e}`); }
  };

  return (
    <>
      <div className={styles.settingsTitleRow}>
        <h1 className={styles.settingsTitle}>Spaces</h1>
        <button className={styles.addAccountCta} onClick={() => setShowCreate(true)}>New space</button>
      </div>
      <p className={styles.sectionDesc}>
        Jev sorts the domain&rsquo;s inbox into these Spaces. Anything unclear lands in Triage.
        Describe what belongs, and what doesn&rsquo;t, to help it sort.
      </p>

      <Modal open={showCreate} onClose={() => setShowCreate(false)} className={styles.settingsModal}>
        <div className={styles.settingsModalTitle}>New space</div>
        <div className={styles.settingsField}>
          <label htmlFor="space-name">Name</label>
          <input
            id="space-name"
            value={draftName}
            onChange={(e) => setDraftName(e.target.value)}
            placeholder="e.g. Partnerships"
            onKeyDown={(e) => e.key === 'Enter' && handleCreate()}
          />
        </div>
        <div className={styles.settingsField}>
          <label htmlFor="space-alias">Alias address (optional)</label>
          <input
            id="space-alias"
            value={draftAlias}
            onChange={(e) => setDraftAlias(e.target.value)}
            placeholder="partnerships"
          />
        </div>
        <div className={styles.settingsField}>
          <label htmlFor="space-openness">Visibility</label>
          <MgmtSelect bare compact id="space-openness" value={draftOpenness} onChange={(e) => setDraftOpenness(e.target.value)} options={OPENNESS} />
        </div>
        <div className={styles.settingsModalActions}>
          <button className={styles.addAccountBtn} onClick={() => setShowCreate(false)}>Cancel</button>
          <Button className={styles.settingsButton} onClick={handleCreate}>Create space</Button>
        </div>
      </Modal>

      <div className={styles.settingsSection}>
        <div className={styles.settingsSectionTitle}>Spaces ({spaces.length})</div>
        {spaces.length === 0 ? (
          <p className={styles.tableEmpty}>No spaces yet.</p>
        ) : (
          <table className={styles.settingsTable}>
            <thead>
              <tr>
                <th>Name</th>
                <th>Visibility</th>
                <th>Routing</th>
                <th>Members</th>
                <th>Open</th>
                <th></th>
              </tr>
            </thead>
            <tbody>
              {spaces.map((s) => (
                <tr key={s.id}>
                  <td>
                    <span className={local.nameCell}>
                      <Swatch slug={s.slug || s.id} />
                      <span className={styles.tablePrimary}>{s.name}</span>
                    </span>
                  </td>
                  <td><span className={styles.tableBadge} data-status={s.openness === 'org' ? 'active' : 'disabled'}>{s.openness === 'org' ? 'domain' : 'assigned'}</span></td>
                  <td><span className={styles.tableBadge} data-status={s.classify ? 'active' : 'disabled'}>{s.classify ? 'auto' : 'manual'}</span></td>
                  <td>{(s.members || []).length}</td>
                  <td>{s.open ?? 0}</td>
                  <td className={styles.tableActions}>
                    <button className={styles.tableAction} onClick={() => startEdit(s)} title="Edit space">
                      <Icon name="pencil" size={14} />
                    </button>
                    <button className={styles.tableAction} onClick={() => handleDelete(s)} title="Delete space">
                      <Icon name="trash" size={14} />
                    </button>
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
        )}

        {editingKey && edit && (() => {
          const space = spaces.find((s) => s.id === editingKey);
          if (!space) return null;
          return (
            <div className={local.editor}>
              <div className={local.editorHead}>
                <Swatch slug={space.slug || space.id} />
                <span className={styles.tablePrimary}>Editing “{space.name}”</span>
              </div>
              <div className={styles.settingsField}>
                <label htmlFor="edit-name">Name</label>
                <input id="edit-name" value={edit.name} onChange={(e) => setEdit({ ...edit, name: e.target.value })} />
              </div>
              <div className={styles.settingsField}>
                <label htmlFor="edit-desc">Description (helps Jev sort)</label>
                <input
                  id="edit-desc"
                  value={edit.description}
                  onChange={(e) => setEdit({ ...edit, description: e.target.value })}
                  placeholder="invoices, payments, billing disputes…"
                />
              </div>
              <div className={styles.settingsField}>
                <label htmlFor="edit-not-for">Not for (optional)</label>
                <input
                  id="edit-not-for"
                  value={edit.not_for}
                  onChange={(e) => setEdit({ ...edit, not_for: e.target.value })}
                  placeholder="sales quotes, marketing newsletters…"
                />
              </div>
              <div className={styles.settingsField}>
                <label htmlFor="edit-openness">Visibility</label>
                <MgmtSelect bare compact id="edit-openness" value={edit.openness} onChange={(e) => setEdit({ ...edit, openness: e.target.value })} options={OPENNESS} />
              </div>
              <label className={local.classifyRow}>
                <MgmtCheckbox  checked={edit.classify} onChange={(e) => setEdit({ ...edit, classify: e.target.checked })} />
                Auto-route mail into this space
              </label>
              <div className={styles.settingsField}>
                <label>Staffed members</label>
                <div className={local.memberPick}>
                  {members.length === 0 && <span className={styles.tableSecondary}>No members yet.</span>}
                  {members.map((m) => {
                    const checked = edit.memberKeys.has(m.id);
                    return (
                      <button
                        type="button"
                        key={m.id}
                        className={`${local.memberChip} ${checked ? local.memberChipOn : ''}`}
                        onClick={() => toggleMember(m.id)}
                        aria-pressed={checked}
                      >
                        {checked && <Icon name="checkmark" size={11} />}
                        {m.user.display_name || m.user.username}
                      </button>
                    );
                  })}
                </div>
              </div>
              <div className={local.editorActions}>
                <Button className={styles.settingsButton} onClick={() => handleSave(space)}>Save</Button>
                <button className={styles.tableAction} onClick={() => { setEditingKey(null); setEdit(null); }}>Cancel</button>
              </div>
            </div>
          );
        })()}
      </div>
    </>
  );
}
