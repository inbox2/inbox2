import { useState, useEffect, useMemo, useRef, useCallback } from 'react';
import Icon from '../../components/Icon';
import Avatar from '../../components/Avatar';
import Spinner from '../../components/Spinner';
import useAuth from '../../hooks/useAuth';
import useDismiss from '../../hooks/useDismiss';
import { MgmtModal, MgmtButton, MgmtSelect } from '../../components/management';
import { MX_STATUS_OPTIONS } from '../../lib/mxRules';
import api from '../../lib/api';
import styles from './console.module.css';
import admin from './adminShared.module.css';

/* Routing-rules view — first-class list of the org's server-side MX rules
 * (Rule/RuleExecutor): when incoming mail matches, assign it, grant access,
 * tag it, set a status, or hand off to a webhook. One section per org. */

const FIELDS = [
  { value: 'to', label: 'To' },
  { value: 'from', label: 'From' },
  { value: 'subject', label: 'Subject' },
  { value: 'body', label: 'Body' },
];
const OPERATORS = [
  { value: 'equals', label: 'is' },
  { value: 'contains', label: 'contains' },
  { value: 'starts_with', label: 'starts with' },
  { value: 'ends_with', label: 'ends with' },
];
const ACTIONS = [
  { value: 'assign', label: 'Assign to a person', hint: 'Matches get assigned to them.' },
  { value: 'grant_access', label: 'Grant access to', hint: 'They see matches on top of their domain access.' },
  { value: 'add_tag', label: 'Add a tag', hint: 'Every match gets this tag.' },
  { value: 'set_status', label: 'Set status', hint: 'Every match moves to this status.' },
  { value: 'webhook', label: 'Call a webhook', hint: 'We POST every match to your endpoint.' },
];

const label = (list, v) => list.find((x) => x.value === v)?.label || v;

function memberName(members, id) {
  const m = members.find((x) => x.id === id);
  return m ? (m.user?.display_name || m.user?.username || m.email_addresses?.[0] || 'someone') : 'someone';
}

// Rule summaries read as prose with the user's own values set in mono, so the
// literal a rule matches on stands apart from the fixed vocabulary around it.
const Val = ({ children }) => <code className={styles.ruleVal}>{children}</code>;

function RuleConditions({ rule }) {
  return (rule.conditions || []).map((c, i) => (
    <span key={i}>
      {i > 0 && ' AND '}
      {label(FIELDS, c.field)} {label(OPERATORS, c.operator)} <Val>{c.value}</Val>
    </span>
  ));
}

function actionParts(a, members) {
  switch (a.type) {
    case 'assign': return <>Assign to <Val>{memberName(members, a.value)}</Val></>;
    case 'grant_access': return <>Grant access to <Val>{memberName(members, a.value)}</Val></>;
    case 'add_tag': return <>Tag <Val>{a.value}</Val></>;
    case 'set_status': return <>Set status <Val>{label(MX_STATUS_OPTIONS, a.value)}</Val></>;
    case 'webhook': return 'Call webhook';
    default: return a.type;
  }
}

function RuleActions({ rule, members }) {
  return (rule.actions || []).map((a, i) => (
    <span key={i}>{i > 0 && ' · '}{actionParts(a, members)}</span>
  ));
}

export default function ConsoleRules() {
  const { organizations } = useAuth();
  return (
    <>
      <div className={styles.pageHead}>
        <div>
          <div className={styles.pageEyebrow}>Routing</div>
          <h1 className={styles.pageTitle}>Routing rules</h1>
          <p className={styles.pageSub}>
            Send matching mail to people, tags, statuses or webhooks.
          </p>
        </div>
      </div>
      {(organizations || []).map((org) => (
        <OrgRules key={org.id} org={org} showTitle={organizations.length > 1} />
      ))}
    </>
  );
}

function OrgRules({ org, showTitle }) {
  const [rules, setRules] = useState([]);
  const [members, setMembers] = useState([]);
  const [mailboxes, setMailboxes] = useState([]);
  const [loading, setLoading] = useState(true);
  const [modalOpen, setModalOpen] = useState(false);
  const [error, setError] = useState(null);

  useEffect(() => {
    let cancelled = false;
    Promise.all([
      api.get(`/orgs/${org.id}/rules`).catch(() => ({ rules: [] })),
      api.getMembers(org.id).catch(() => ({ members: [] })),
      api.get(`/orgs/${org.id}/mailboxes`).catch(() => ({ mailboxes: [] })),
    ]).then(([r, m, mb]) => {
      if (cancelled) return;
      setRules(r.rules || []);
      setMembers(m.members || []);
      setMailboxes(mb.mailboxes || []);
      setLoading(false);
    });
    return () => { cancelled = true; };
  }, [org.id]);

  const toggle = async (rule) => {
    try {
      const { rule: updated } = await api.patch(`/orgs/${org.id}/rules/${rule.id}/toggle`);
      setRules((rs) => rs.map((r) => (r.id === rule.id ? updated : r)));
    } catch (e) {
      setError(e?.message || "Couldn't toggle the rule.");
    }
  };

  const remove = async (rule) => {
    try {
      await api.delete(`/orgs/${org.id}/rules/${rule.id}`);
      setRules((rs) => rs.filter((r) => r.id !== rule.id));
    } catch (e) {
      setError(e?.message || "Couldn't delete the rule.");
    }
  };

  // Pool addresses for the condition-value quick-find (native datalist).
  const addresses = useMemo(
    () => [...new Set(mailboxes.flatMap((m) => m.email_addresses || (m.address ? [m.address] : [])))],
    [mailboxes],
  );

  return (
    <div className={`${styles.card} ${styles.mt}`}>
      <div className={styles.cardHead}>
        <h2 className={styles.cardTitle}>{showTitle ? `Rules · ${org.domain || org.name}` : 'Rules'}</h2>
        <MgmtButton variant="glass" size="sm" onClick={() => setModalOpen(true)}>
          <Icon name="plus" size={13} /> New rule
        </MgmtButton>
      </div>
      {error && <p className={admin.settingsError} role="alert"><Icon name="exclamationmark.triangle" size={14} /> {error}</p>}
      {loading ? (
        <div className={styles.cardLoading}><Spinner size={16} color="#2f7ad6" /></div>
      ) : rules.length === 0 ? (
        <div className={styles.attnEmpty}>
          No routing rules yet. Create one to route matching mail.
        </div>
      ) : (
        rules.map((rule) => (
          <div key={rule.id} className={styles.ruleRow}>
            <div className={styles.ruleCond}>
              <span className={styles.ruleName}>{rule.name}</span>
              <span className={styles.ruleExpr}><RuleConditions rule={rule} /></span>
            </div>
            <span className={styles.ruleArrow}>→</span>
            <div className={styles.ruleThen}><RuleActions rule={rule} members={members} /></div>
            <div className={styles.ruleActions}>
              <button
                type="button"
                className={[styles.toggle, rule.enabled ? '' : styles.toggleOff].join(' ')}
                onClick={() => toggle(rule)}
                aria-label={rule.enabled ? `Disable ${rule.name}` : `Enable ${rule.name}`}
                aria-pressed={rule.enabled}
              />
              <button
                type="button"
                className={styles.rowRemove}
                onClick={() => remove(rule)}
                title={`Delete ${rule.name}`}
                aria-label={`Delete ${rule.name}`}
              >
                <Icon name="trash" size={13} />
              </button>
            </div>
          </div>
        ))
      )}

      {modalOpen && (
        <RuleModal
          org={org}
          members={members}
          addresses={addresses}
          onClose={() => setModalOpen(false)}
          onCreated={(rule) => { setRules((rs) => [...rs, rule]); setModalOpen(false); }}
        />
      )}
    </div>
  );
}

/* Create-rule modal — name, condition rows (field / operator / value with a
 * pool-address quick-find), then an action whose target control follows the
 * chosen type: person picker (searchable, with avatars) for assign/grant,
 * status select, tag/webhook inputs. */
function RuleModal({ org, members, addresses, onClose, onCreated }) {
  const [name, setName] = useState('');
  const [conditions, setConditions] = useState([{ field: 'to', operator: 'equals', value: '' }]);
  const [actionType, setActionType] = useState('assign');
  const [target, setTarget] = useState(null); // member id | status | tag | url
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState(null);

  const action = ACTIONS.find((a) => a.value === actionType);
  const needsMember = actionType === 'assign' || actionType === 'grant_access';

  const setCond = (i, patch) =>
    setConditions((cs) => cs.map((c, j) => (j === i ? { ...c, ...patch } : c)));

  const valid = name.trim()
    && conditions.every((c) => c.value.trim())
    && (needsMember ? !!target : String(target || '').trim());

  const create = async () => {
    if (!valid || busy) return;
    setBusy(true);
    setError(null);
    try {
      const { rule } = await api.post(`/orgs/${org.id}/rules`, {
        name: name.trim(),
        conditions: conditions.map((c) => ({ field: c.field, operator: c.operator, value: c.value.trim() })),
        actions: [{ type: actionType, value: String(target).trim() }],
        enabled: true,
      });
      onCreated(rule);
    } catch (e) {
      setError(e?.message || "Couldn't create the rule.");
      setBusy(false);
    }
  };

  const listId = `rule-values-${org.id}`;

  return (
    <MgmtModal open onClose={onClose} width={640}>
      <h2 className={admin.modalTitle}>New routing rule</h2>
      <p className={admin.modalSub}>Pick what happens to mail that matches.</p>

      <div className={admin.modalField}>
        <span className={admin.modalLabel}>Name</span>
        <input
          className={admin.modalInput}
          value={name}
          onChange={(e) => setName(e.target.value)}
          placeholder="e.g. Support requests"
        />
      </div>

      <div className={admin.modalField}>
        <span className={admin.modalLabel}>When</span>
        {conditions.map((c, i) => (
          <div key={i} className={styles.ruleCondGrid}>
            <MgmtSelect
              bare
              compact
              value={c.field}
              onChange={(e) => setCond(i, { field: e.target.value })}
              options={FIELDS}
            />
            <MgmtSelect
              bare
              compact
              value={c.operator}
              onChange={(e) => setCond(i, { operator: e.target.value })}
              options={OPERATORS}
            />
            <input
              className={admin.modalInput}
              value={c.value}
              onChange={(e) => setCond(i, { value: e.target.value })}
              placeholder={c.field === 'subject' || c.field === 'body' ? 'invoice' : 'support@yourdomain.com'}
              list={c.field === 'to' || c.field === 'from' ? listId : undefined}
              autoComplete="off"
            />
            {conditions.length > 1 && (
              <button
                type="button"
                className={styles.rowRemove}
                onClick={() => setConditions((cs) => cs.filter((_, j) => j !== i))}
                aria-label="Remove condition"
              >
                <Icon name="xmark" size={12} />
              </button>
            )}
          </div>
        ))}
        <button
          type="button"
          className={admin.accessAdd}
          onClick={() => setConditions((cs) => [...cs, { field: 'subject', operator: 'contains', value: '' }])}
        >
          <Icon name="plus" size={11} /> And also matches…
        </button>
        <datalist id={listId}>
          {addresses.map((a) => <option key={a} value={a} />)}
        </datalist>
      </div>

      <div className={admin.modalField}>
        <span className={admin.modalLabel}>Then</span>
        <div className={styles.ruleCondGrid}>
          <MgmtSelect
            bare
            compact
            value={actionType}
            onChange={(e) => { setActionType(e.target.value); setTarget(null); }}
            options={ACTIONS}
          />
          {needsMember && (
            <MemberPicker members={members} value={target} onChange={setTarget} />
          )}
          {actionType === 'set_status' && (
            <MgmtSelect
              bare
              compact
              value={target || ''}
              onChange={(e) => setTarget(e.target.value)}
              options={MX_STATUS_OPTIONS}
              placeholder="Pick a status…"
            />
          )}
          {actionType === 'add_tag' && (
            <input
              className={admin.modalInput}
              value={target || ''}
              onChange={(e) => setTarget(e.target.value)}
              placeholder="finance"
            />
          )}
          {actionType === 'webhook' && (
            <input
              className={admin.modalInput}
              value={target || ''}
              onChange={(e) => setTarget(e.target.value)}
              placeholder="https://example.com/hooks/mail"
            />
          )}
        </div>
        <p className={styles.ruleHint}>{action?.hint}</p>
      </div>

      {error && <p className={admin.modalError} role="alert">{error}</p>}

      <div className={admin.modalActions}>
        <MgmtButton variant="glass" className={admin.modalCancel} onClick={onClose} disabled={busy}>Cancel</MgmtButton>
        <MgmtButton variant="primary" onClick={create} disabled={!valid || busy}>
          {busy ? 'Creating…' : 'Create rule'}
        </MgmtButton>
      </div>
    </MgmtModal>
  );
}

/* Searchable person picker (MxSelect pattern): avatar + name + role per row,
 * with a type-to-search field focused on open. */
function MemberPicker({ members, value, onChange }) {
  const [open, setOpen] = useState(false);
  const [query, setQuery] = useState('');
  const ref = useRef(null);
  useDismiss(ref, useCallback(() => setOpen(false), []), open);

  const toggleOpen = () => {
    if (!open) setQuery('');
    setOpen((o) => !o);
  };

  const display = (m) => m.user?.display_name || m.user?.username || m.email_addresses?.[0] || '?';
  const sub = (m) => [m.role, m.all_domains ? 'all domains' : (m.domains || []).map((d) => d.name).join(', ')]
    .filter(Boolean).join(' · ');
  const selected = members.find((m) => m.id === value) || null;
  const q = query.trim().toLowerCase();
  const hits = members.filter((m) => !q || `${display(m)} ${sub(m)}`.toLowerCase().includes(q));

  const row = (m) => (
    <span className={admin.mxOption}>
      <Avatar name={display(m)} email={m.user?.billing_email || m.email_addresses?.[0]} size={26} />
      <span className={admin.mxOptionText}>
        <span className={admin.mxOptionName}>{display(m)}</span>
        <span className={admin.mxOptionDns}>{sub(m)}</span>
      </span>
    </span>
  );

  return (
    <div className={admin.mxSelect} ref={ref}>
      <button
        type="button"
        className={admin.mxSelectTrigger}
        onClick={toggleOpen}
        aria-haspopup="listbox"
        aria-expanded={open}
      >
        {selected ? row(selected) : <span className={admin.mxSelectPlaceholder}>Pick a person</span>}
        <Icon name="chevron.down" size={12} className={admin.mxSelectChevron} />
      </button>
      {open && (
        <ul className={admin.mxSelectList} role="listbox">
          <li className={styles.pickSearch}>
            <input
              className={admin.modalInput}
              /* mounts on open — autoFocus lands the caret in the search */
              autoFocus
              value={query}
              onChange={(e) => setQuery(e.target.value)}
              onKeyDown={(e) => {
                if (e.key === 'Enter' && hits[0]) { onChange(hits[0].id); setOpen(false); }
              }}
              placeholder="Type to search…"
              autoComplete="off"
            />
          </li>
          {hits.map((m) => (
            <li key={m.id}>
              <button
                type="button"
                role="option"
                aria-selected={m.id === value}
                className={`${admin.mxSelectItem} ${m.id === value ? admin.mxSelectItemOn : ''}`}
                onClick={() => { onChange(m.id); setOpen(false); }}
              >
                {row(m)}
                {m.id === value && <Icon name="checkmark" size={13} className={admin.mxSelectCheck} />}
              </button>
            </li>
          ))}
          {hits.length === 0 && (
            <li><span className={`${admin.mxSelectItem}`} aria-disabled="true">No one matches “{query}”</span></li>
          )}
        </ul>
      )}
    </div>
  );
}
