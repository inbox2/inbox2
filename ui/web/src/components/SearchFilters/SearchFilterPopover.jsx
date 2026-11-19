import { useState, useEffect, useRef } from 'react';
import Modal from '../Modal/Modal';
import Button from '../Button/Button';
import FormField from '../FormField/FormField';
import FileIcon from '../FileIcon/FileIcon';
import Switch from '../Switch/Switch';
import { TAG_PRESETS } from '../Tag/presets';
import Icon from '../Icon';
import { format, parseSize, formatSize, EMPTY_QUERY, IN_SCOPES } from '../../lib/searchQuery';
import { PRIORITY_URGENT, PRIORITY_IMPORTANT } from '../../lib/priority';
import styles from './SearchFilters.module.css';

// People fields are plain text — comma-separate for several ("ana, bob").
const PEOPLE = [
  { field: 'from', label: 'From' },
  { field: 'to', label: 'To' },
  { field: 'cc', label: 'Cc' },
];

// Read state reads as a plain toggle…
const READ_FLAGS = [
  { flag: 'unread', label: 'Unread', icon: 'envelope.badge' },
  { flag: 'read', label: 'Read', icon: 'envelope.open' },
];
// …priority is a LABEL, so it's drawn as one (same <Tag> + presets as the list rows).
const LABEL_FLAGS = [
  { flag: 'urgent', name: PRIORITY_URGENT },
  { flag: 'important', name: PRIORITY_IMPORTANT },
];

// Mutually exclusive pairs — "read AND unread" matches nothing, so picking one
// drops the other rather than quietly returning an empty result set.
const EXCLUSIVE = [['read', 'unread']];

// The extensions people actually hunt for; anything else is typed into the field.
const QUICK_TYPES = ['pdf', 'docx', 'xlsx', 'pptx', 'zip', 'png', 'jpg'];

const SCOPE = {
  inbox: { label: 'Inbox', icon: 'tray' },
  archive: { label: 'Archive', icon: 'archivebox.fill' },
  trash: { label: 'Trash', icon: 'trash' },
  spam: { label: 'Spam', icon: 'nosign' },
  anywhere: { label: 'Everywhere', icon: 'globe' },
};

const TABS = [
  { value: 'people', label: 'People' },
  { value: 'attachments', label: 'Attachments' },
];

// Relative date shortcuts — the common case is "recently", not a calendar date.
const SINCE = [
  { label: 'Last 7 days', days: 7 },
  { label: 'Last 30 days', days: 30 },
  { label: 'Last year', days: 365 },
];

const ISO_DATE = /^\d{4}-\d{2}-\d{2}$/;
const daysAgo = (days) => new Date(Date.now() - days * 864e5).toISOString().slice(0, 10);

const joined = (values) => (values || []).join(', ');
const split = (raw) => raw.split(',').map(v => v.trim()).filter(Boolean);
const countOf = (...lists) => lists.reduce((n, l) => n + (l?.length || 0), 0) || undefined;

/**
 * Search filters dialog — the same Modal shell as the rule editor
 * (CreateRulePopup), not a floating popover: this is a form, and a form that
 * overlaps the mail behind it is unreadable.
 *
 * Edits a working copy and applies on submit, so a half-typed filter never
 * re-runs the search. `Apply` hands back the query object the search box, the
 * chips and ?q= all read.
 */
export default function SearchFilterPopover({ open, filter, onChange, onClose }) {
  const [draft, setDraft] = useState(filter);
  const [tab, setTab] = useState('people');

  // Re-seed each time it opens — Modal keeps children mounted between opens.
  /* eslint-disable react-hooks/set-state-in-effect -- intentional: reset the working copy on open */
  useEffect(() => { if (open) setDraft(filter); }, [open, filter]);
  /* eslint-enable react-hooks/set-state-in-effect */

  if (!open) return null;

  const set = (patch) => setDraft(d => ({ ...d, ...patch }));

  const toggleFlag = (flag) => {
    const has = draft.is?.includes(flag);
    let next = (draft.is || []).filter(f => f !== flag);
    if (!has) {
      for (const pair of EXCLUSIVE) {
        if (pair.includes(flag)) next = next.filter(f => !pair.includes(f));
      }
      next = [...next, flag];
    }
    set({ is: next });
  };

  const toggleType = (ext) => set({
    type: draft.type?.includes(ext)
      ? draft.type.filter(t => t !== ext)
      : [...(draft.type || []), ext],
  });

  // Sizes are free-typed ("5mb"); anything unparseable clears rather than
  // silently searching for something else.
  const setSize = (key, raw) => set({ [key]: raw.trim() ? parseSize(raw) : null });
  // Dates commit only once whole, so a half-typed year isn't a filter. Empty is
  // the default and stays empty — no "today" seeded into an untouched field.
  const setDate = (key, raw) => set({ [key]: ISO_DATE.test(raw.trim()) ? raw.trim() : null });

  const apply = (e) => {
    e.preventDefault();
    onChange(draft);
    onClose();
  };

  // Every one of these only matches mail that carries a file, so "has an
  // attachment" is already true — the backends filter on an attachment row /
  // filename either way.
  const impliesAttachment = !!(draft.filename?.length || draft.type?.length
    || draft.larger != null || draft.smaller != null);

  const tabs = [
    { ...TABS[0], count: countOf(draft.from, draft.to, draft.cc, draft.subject) },
    {
      ...TABS[1],
      count: countOf(draft.filename, draft.type)
        || ((draft.larger != null || draft.smaller != null || draft.is?.includes('attachment')) ? 1 : undefined),
    },
  ];

  return (
    <Modal open={open} onClose={onClose} className={styles.panel}>
      <form onSubmit={apply}>
        <div className={styles.title}>
          <Icon name="line.3.horizontal.decrease" size={16} />
          Search filters
        </div>

        <div className={styles.tabBar} role="tablist" aria-label="Filter group">
          {tabs.map(({ value, label, count }) => (
            <button
              key={value}
              type="button"
              role="tab"
              aria-selected={tab === value}
              className={`${styles.tab} ${tab === value ? styles.tabActive : ''}`}
              onClick={() => setTab(value)}
            >
              {label}
              {count != null && <span className={styles.tabCount}>{count}</span>}
            </button>
          ))}
        </div>

        <div className={styles.tabPanel}>
          {tab === 'people' ? (
            <>
              <div className={styles.fieldPair}>
                {PEOPLE.slice(0, 2).map(({ field, label }) => (
                  <FormField
                    key={field}
                    label={label}
                    type="text"
                    placeholder="name or address"
                    value={joined(draft[field])}
                    onChange={(e) => set({ [field]: split(e.target.value) })}
                  />
                ))}
              </div>
              <div className={styles.fieldPair}>
                <FormField
                  label="Cc"
                  type="text"
                  placeholder="name or address"
                  value={joined(draft.cc)}
                  onChange={(e) => set({ cc: split(e.target.value) })}
                />
                <FormField
                  label="Subject"
                  type="text"
                  placeholder="words in the subject"
                  value={joined(draft.subject)}
                  onChange={(e) => set({ subject: split(e.target.value) })}
                />
              </div>
            </>
          ) : (
            <>
              <FormField label="File type">
                <div className={styles.chipRow}>
                  {QUICK_TYPES.map(ext => (
                    <button
                      key={ext}
                      type="button"
                      className={`${styles.toggle} ${draft.type?.includes(ext) ? styles.toggleOn : ''}`}
                      onClick={() => toggleType(ext)}
                    >
                      {/* Native OS file-type icon, same as the attachment chips
                          in the reading pane / composer. Renders nothing off
                          desktop, where the extension alone carries the pill. */}
                      <FileIcon filename={`file.${ext}`} size={14} />
                      {ext}
                    </button>
                  ))}
                </div>
              </FormField>
              <FormField
                label="Filename"
                type="text"
                placeholder="contract.pdf"
                value={joined(draft.filename)}
                onChange={(e) => set({ filename: split(e.target.value) })}
              />
              <div className={styles.fieldPair}>
                <FormField
                  label="Larger than"
                  type="text"
                  placeholder="5mb"
                  defaultValue={draft.larger != null ? formatSize(draft.larger) : ''}
                  onChange={(e) => setSize('larger', e.target.value)}
                />
                <FormField
                  label="Smaller than"
                  type="text"
                  placeholder="1mb"
                  defaultValue={draft.smaller != null ? formatSize(draft.smaller) : ''}
                  onChange={(e) => setSize('smaller', e.target.value)}
                />
              </div>
              {/* On/off, not one of a set — so it's the Switch from Settings,
                  not a pill pretending to be one. Any type/name/size filter
                  already means "has an attachment", so it reads as on and locks
                  rather than sitting there off next to a contradiction. */}
              <Switch
                id="filter-has-attachment"
                label="Has an attachment"
                description={impliesAttachment
                  ? 'The filters above already need one.'
                  : 'Any file, whatever its name, type or size.'}
                checked={impliesAttachment || !!draft.is?.includes('attachment')}
                disabled={impliesAttachment}
                onChange={() => toggleFlag('attachment')}
              />
            </>
          )}
        </div>

        <div className={styles.grid}>
          <section className={styles.group}>
            <span className={styles.groupTitle}>State</span>
            <div className={styles.chipRow}>
              {READ_FLAGS.map(({ flag, label, icon }) => (
                <button
                  key={flag}
                  type="button"
                  className={`${styles.toggle} ${draft.is?.includes(flag) ? styles.toggleOn : ''}`}
                  onClick={() => toggleFlag(flag)}
                >
                  <Icon name={icon} size={11} />
                  {label}
                </button>
              ))}
              {/* Priority is a label everywhere else in the app, so it looks
                  like one here — the same <Tag> and preset colours as a row's
                  labels, dimmed until picked. */}
              {LABEL_FLAGS.map(({ flag, name }) => (
                <LabelToggle
                  key={flag}
                  name={name}
                  color={TAG_PRESETS[name.toLowerCase()].bg}
                  on={!!draft.is?.includes(flag)}
                  onClick={() => toggleFlag(flag)}
                />
              ))}
            </div>
          </section>

          <section className={styles.group}>
            <span className={styles.groupTitle}>Where</span>
            <div className={styles.chipRow}>
              {IN_SCOPES.map(scope => (
                <button
                  key={scope}
                  type="button"
                  className={`${styles.toggle} ${draft.in === scope ? styles.toggleOn : ''}`}
                  onClick={() => set({ in: draft.in === scope ? null : scope })}
                >
                  <Icon name={SCOPE[scope].icon} size={11} />
                  {SCOPE[scope].label}
                </button>
              ))}
            </div>
            <span className={styles.hint}>
              {draft.in ? `Only ${SCOPE[draft.in].label}.` : 'Everywhere except Trash & Spam.'}
            </span>
          </section>

          <section className={`${styles.group} ${styles.groupWide}`}>
            <span className={styles.groupTitle}>When</span>
            <div className={styles.chipRow}>
              {SINCE.map(({ label, days }) => {
                const value = daysAgo(days);
                return (
                  <button
                    key={days}
                    type="button"
                    className={`${styles.toggle} ${draft.after === value ? styles.toggleOn : ''}`}
                    onClick={() => set({ after: draft.after === value ? null : value, before: null })}
                  >
                    <Icon name="clock.arrow.circlepath" size={11} />
                    {label}
                  </button>
                );
              })}
            </div>
            <div className={styles.fieldPair}>
              <FormField
                label="After"
                type="text"
                placeholder="yyyy-mm-dd"
                // Uncontrolled + re-keyed: partial typing survives, and a preset
                // above still writes through to the box.
                key={`after:${draft.after || ''}`}
                defaultValue={draft.after || ''}
                onChange={(e) => setDate('after', e.target.value)}
              />
              <FormField
                label="Before"
                type="text"
                placeholder="yyyy-mm-dd"
                key={`before:${draft.before || ''}`}
                defaultValue={draft.before || ''}
                onChange={(e) => setDate('before', e.target.value)}
              />
            </div>
          </section>
        </div>

        {/* What the search box would read — the dialog teaches the operator
            syntax by showing what it just wrote. */}
        <div className={styles.syntax}>
          <code className={styles.syntaxCode}>{format(draft) || 'no filters'}</code>
        </div>

        <div className={styles.actions}>
          {/* Clear commits the cleared query and closes — "clear" that only
              emptied the form left you to press Apply to mean it. */}
          <Button
            type="button"
            variant="ghost"
            onClick={() => { onChange({ ...EMPTY_QUERY, text: draft.text }); onClose(); }}
          >
            Clear
          </Button>
          <Button type="button" variant="secondary" onClick={onClose}>Cancel</Button>
          <Button type="submit">Apply</Button>
        </div>
      </form>
    </Modal>
  );
}

/**
 * A priority label as a filter pill: the same shape as its neighbours, wearing
 * the label's own colour as a dot (and as a tint once picked). Embedding the
 * real <Tag> here made a square block in a row of pills.
 */
function LabelToggle({ name, color, on, onClick }) {
  const ref = useRef(null);

  useEffect(() => {
    ref.current?.style.setProperty('--label-color', color);
  }, [color]);

  return (
    <button
      ref={ref}
      type="button"
      aria-pressed={on}
      className={`${styles.toggle} ${styles.labelToggle} ${on ? styles.labelToggleOn : ''}`}
      onClick={onClick}
    >
      <span className={styles.labelDot} />
      {name}
    </button>
  );
}
