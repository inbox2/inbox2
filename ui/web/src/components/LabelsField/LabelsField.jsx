import { useContext, useEffect, useState } from 'react';
import { AuthContext } from '../../hooks/AuthProvider';
import { isAdminRole } from '../../lib/orgRoles';
import Popover from '../Popover';
import Tag from '../Tag';
import Icon from '../Icon';
import api from '../../lib/api';
import log from '../../lib/log';
import styles from './LabelsField.module.css';
import { MgmtCheckbox } from '../management';

const PRIORITY = new Set(['urgent', 'important', 'later']);
// Tells the sidebar's label list (useViewsAndTags) that a label was made here.
export const TAGS_CHANGED = 'inbox2:tags-changed';

/**
 * The labels on an MX conversation, editable: the team's tags and the viewer's
 * own private labels (a lock marks those; only the viewer sees them). The
 * picker toggles labels and makes a new private one from the search box.
 * Priority tags (Urgent/Important/Later) belong to the triage control above.
 *
 * Props: conversation (with tags), orgId, onTagsChange(tags) after a change.
 */
export default function LabelsField({ conversation, orgId, onTagsChange }) {
  const [anchorRect, setAnchorRect] = useState(null); // set while the picker is open
  const open = !!anchorRect;
  const [all, setAll] = useState([]);
  const [query, setQuery] = useState('');
  const [error, setError] = useState(null);
  // A private label's own controls: { id, name } while its row is open for editing.
  const [editing, setEditing] = useState(null);
  const auth = useContext(AuthContext); // context, not useAuth: mail renders outside the provider in stories
  const canShare = isAdminRole(auth?.organizations?.find((o) => o.id === orgId)?.role);
  const current = (conversation.tags || []).filter((t) => typeof t === 'object' && !PRIORITY.has((t.name || '').toLowerCase()));
  const on = new Set(current.map((t) => t.id));

  useEffect(() => {
    if (!open) return undefined;
    let cancelled = false;
    api.getTags(orgId)
      .then((d) => { if (!cancelled) setAll((d.tags || []).filter((t) => !PRIORITY.has(t.name.toLowerCase()))); })
      .catch((e) => log.warn('Labels', e?.message || e));
    return () => { cancelled = true; };
  }, [open, orgId]);

  const apply = async (body) => {
    setError(null);
    try {
      const res = await api.updateConversationTags(orgId, conversation.id, body);
      onTagsChange?.(res.conversation?.tags || []);
    } catch (e) {
      setError(e?.message || 'Could not change the labels.');
    }
  };
  const toggle = (tag) => apply(on.has(tag.id) ? { remove_tag_ids: [tag.id] } : { add_tag_ids: [tag.id] });

  const create = async () => {
    const name = query.trim();
    if (!name) return;
    setError(null);
    try {
      const { tag } = await api.createTag(orgId, { name, private: true });
      setAll((prev) => [...prev, tag]);
      document.dispatchEvent(new CustomEvent(TAGS_CHANGED));
      setQuery('');
      await apply({ add_tag_ids: [tag.id] });
    } catch (e) {
      setError(e?.message || 'Could not make the label.');
    }
  };

  // Rename, delete or share one private label, then tell this thread and the sidebar.
  const manage = async (work, change) => {
    setError(null);
    try {
      await work();
      setAll(change);
      onTagsChange?.(change(current));
      document.dispatchEvent(new CustomEvent(TAGS_CHANGED));
      setEditing(null);
    } catch (e) {
      setError(e?.data?.errors?.[0]?.message || e?.message || 'Could not change the label.');
    }
  };
  const rename = (t) => {
    const name = editing.name.trim();
    if (!name || name === t.name) { setEditing(null); return undefined; }
    return manage(() => api.updateTag(orgId, t.id, { name }), (l) => l.map((x) => (x.id === t.id ? { ...x, name } : x)));
  };
  const remove = (t) => manage(() => api.deleteTag(orgId, t.id), (l) => l.filter((x) => x.id !== t.id));
  const share = (t) => manage(() => api.shareTag(orgId, t.id), (l) => l.map((x) => (x.id === t.id ? { ...x, private: false } : x)));

  const q = query.trim().toLowerCase();
  const shown = all.filter((t) => !q || t.name.toLowerCase().includes(q));
  const exact = all.some((t) => t.private && t.name.toLowerCase() === q);

  return (
    <div className={styles.field}>
      {current.map((t) => (
        <Tag key={t.id} bg={t.color || 'var(--accent-primary)'} fg="var(--text-inverse)" variant="square">
          <span className={styles.chip}>
            {t.private && <Icon name="lock.fill" size={9} />}
            {t.name}
          </span>
        </Tag>
      ))}
      <button type="button" className={styles.add}
        onClick={(e) => setAnchorRect(open ? null : e.currentTarget.getBoundingClientRect())}
        aria-haspopup="dialog" aria-expanded={open}>
        <Icon name="tag.fill" size={11} />
        {current.length ? 'Edit' : 'Add label…'}
      </button>
      <Popover open={open} anchorRect={anchorRect} onClose={() => setAnchorRect(null)}
        className={styles.popover}>
        <input
          className={styles.search}
          placeholder="Find or make a label"
          value={query}
          autoFocus
          onChange={(e) => setQuery(e.target.value)}
          onKeyDown={(e) => { if (e.key === 'Enter' && !exact && q) create(); }}
          aria-label="Find or make a label"
        />
        <ul className={styles.list}>
          {shown.map((t) => (
            <li key={t.id}>
              <div className={styles.rowWrap}>
                <label className={styles.row}>
                  <MgmtCheckbox  checked={on.has(t.id)} onChange={() => toggle(t)} />
                  <span className={styles.name}>{t.name}</span>
                  {t.private && <Icon name="lock.fill" size={10} className={styles.lock} />}
                </label>
                {t.private && (
                  <button type="button" className={styles.more} aria-label={`Change ${t.name}`} aria-expanded={editing?.id === t.id}
                    onClick={() => setEditing(editing?.id === t.id ? null : { id: t.id, name: t.name })}>
                    <Icon name="ellipsis" size={11} />
                  </button>
                )}
              </div>
              {editing?.id === t.id && (
                <div className={styles.edit}>
                  <input className={styles.search} value={editing.name} aria-label="Label name" autoFocus
                    onChange={(e) => setEditing({ ...editing, name: e.target.value })}
                    onKeyDown={(e) => { if (e.key === 'Enter') rename(t); if (e.key === 'Escape') { e.stopPropagation(); setEditing(null); } }} />
                  <div className={styles.editActions}>
                    <button type="button" className={styles.create} onClick={() => rename(t)}>Rename</button>
                    {canShare && <button type="button" className={styles.create} onClick={() => share(t)}>Share with the team</button>}
                    <button type="button" className={styles.create} onClick={() => remove(t)}>Delete</button>
                  </div>
                </div>
              )}
            </li>
          ))}
        </ul>
        {q && !exact && (
          <button type="button" className={styles.create} onClick={create}>
            <Icon name="plus" size={10} /> Make “{query.trim()}”, just for you
          </button>
        )}
        {error && <p className={styles.error}>{error}</p>}
      </Popover>
    </div>
  );
}
