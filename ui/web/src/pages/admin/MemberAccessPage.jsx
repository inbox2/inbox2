import { useState, useEffect, useCallback, useMemo } from 'react';
import { useParams, useNavigate } from 'react-router';
import Icon from '../../components/Icon';
import Avatar from '../../components/Avatar';
import Spinner from '../../components/Spinner';
import IconButton from '../../components/IconButton';
import { MgmtModal, MgmtButton, MgmtSelect, MgmtCheckbox } from '../../components/management';
import { StatusBadge, Choice } from './AdminPeople';
import { ROLE_LABEL, who } from './memberDisplay';
import useAuth from '../../hooks/useAuth';
import { ORG_ROLES, grantableRoles, canManageMember } from '../../lib/orgRoles';
import api from '../../lib/api';
import log from '../../lib/log';
import admin from './adminShared.module.css';
import styles from './MemberAccessPage.module.css';
import everythingIcon from '../../assets/access-everything.png';
import specificIcon from '../../assets/access-specific.png';
import { consolePath } from '../../lib/consoleHost';

/* Dedicated per-member access page (/console/team/:orgId/:memberId), reached by
 * clicking a person on the console Team table. One clear flow:
 *   1. Radio cards — everything vs. specific domains.
 *   2. Specific → pick the domains, plus "hide teammates' personal mailboxes"
 *      (whole-domain access minus waseem@-style personal threads).
 *   3. Below, separately: rules that EXTEND access (grant_access routing rules)
 *      — "also show them anything to info@ / from x / subject y".
 *   4. Send as: extra From addresses (info@, sales@) granted to this person.
 * Every change applies immediately (one PATCH per change, same endpoints as the
 * Team table). */

export default function MemberAccessPage() {
  const { orgId, memberId } = useParams();
  const navigate = useNavigate();
  const { user } = useAuth();

  const [members, setMembers] = useState(null); // null = loading
  const [domains, setDomains] = useState([]);
  const [rules, setRules] = useState([]);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState(null);
  const [ruleModal, setRuleModal] = useState(false);
  const [sendLocal, setSendLocal] = useState('');
  const [sendDomain, setSendDomain] = useState('');

  const load = useCallback(() => Promise.all([
    api.getMembers(orgId),
    api.listDomains(orgId).catch(() => ({ domains: [] })),
    api.get(`/orgs/${orgId}/rules`).catch(() => ({ rules: [] })),
  ]), [orgId]);

  const reload = useCallback(async () => {
    try {
      const [m, d, r] = await load();
      setMembers(m.members || []);
      setDomains(d.domains || []);
      setRules(r.rules || []);
    } catch (e) {
      log.warn('MemberAccess', `load failed: ${e?.message || e}`);
      setMembers([]);
    }
  }, [load]);

  useEffect(() => {
    let cancelled = false;
    load()
      .then(([m, d, r]) => { if (!cancelled) { setMembers(m.members || []); setDomains(d.domains || []); setRules(r.rules || []); } })
      .catch((e) => { log.warn('MemberAccess', `load failed: ${e?.message || e}`); if (!cancelled) setMembers([]); });
    return () => { cancelled = true; };
  }, [load]);

  const member = useMemo(() => (members || []).find((m) => m.id === memberId), [members, memberId]);
  const myRole = useMemo(
    () => (members || []).find((m) => m.user?.username && m.user.username === user?.username)?.role,
    [members, user],
  );
  const memberRules = useMemo(
    () => rules.filter((r) => (r.actions || []).some((a) => a.type === 'grant_access' && a.value === memberId)),
    [rules, memberId],
  );

  const patch = async (body) => {
    setBusy(true);
    setError(null);
    try {
      await api.updateMember(orgId, memberId, body);
      await reload();
    } catch (e) {
      setError(e?.message || "Couldn't update.");
    } finally {
      setBusy(false);
    }
  };

  const toggleDomain = (domainKey) => {
    const ids = member.domains.map((d) => d.id);
    const next = ids.includes(domainKey) ? ids.filter((k) => k !== domainKey) : [...ids, domainKey];
    patch({ all_domains: false, domain_ids: next });
  };

  // Revoke an extending rule: delete the rule when this grant is its only
  // action, else strip just this member's grant from the action list.
  const revokeRule = async (rule) => {
    setBusy(true);
    setError(null);
    try {
      const remaining = (rule.actions || []).filter((a) => !(a.type === 'grant_access' && a.value === memberId));
      if (remaining.length === 0 && !(rule.branches?.length) && !(rule.else_actions?.length)) {
        await api.delete(`/orgs/${orgId}/rules/${rule.id}`);
      } else {
        await api.patch(`/orgs/${orgId}/rules/${rule.id}`, { actions: remaining });
      }
      await reload();
    } catch (e) {
      setError(e?.message || "Couldn't remove the rule.");
    } finally {
      setBusy(false);
    }
  };

  const setSendAs = (list) => patch({ send_as_addresses: list });
  const addSendAs = async () => {
    const local = sendLocal.trim().toLowerCase();
    const domain = sendDomain || domains[0]?.name;
    if (!local || !domain) return;
    await setSendAs([...(member.send_as_addresses || []), `${local}@${domain}`]);
    setSendLocal('');
  };

  const back = () => navigate(consolePath('people'));

  if (members === null) {
    return (
      <div className={`${styles.page} management`}>
        <div className={styles.loading}><Spinner size={22} color="var(--m-accent)" /></div>
      </div>
    );
  }

  if (!member) {
    return (
      <div className={`${styles.page} management`}>
        <div className={styles.loading}>
          <p>Member not found.</p>
          <MgmtButton variant="primary" onClick={back}>Back to console</MgmtButton>
        </div>
      </div>
    );
  }

  const isAdmin = member.role === 'owner' || member.role === 'admin';
  const isSelf = member.user?.username && member.user.username === user?.username;
  const roleTargets = (member.role !== 'owner' && !isSelf && canManageMember(myRole, member.role))
    ? grantableRoles(myRole)
    : [];
  const grantedIds = new Set(member.domains.map((d) => d.id));
  const scoped = !member.all_domains;

  return (
    <div className={`${styles.page} management`}>
      <div>
        <header className={styles.head}>
          <button type="button" className={styles.back} onClick={back}>
            <Icon name="chevron.left" size={13} /> Console
          </button>
          <Avatar name={who(member)} email={member.user?.billing_email} size={44} />
          <div className={styles.headText}>
            <h1 className={styles.headTitle}>{who(member)}</h1>
            <span className={styles.headSub}>
              {member.user?.billing_email || member.email_addresses?.[0] || member.user?.username}
            </span>
          </div>
          <div className={styles.headMeta}>
            {roleTargets.length > 0 ? (
              <MgmtSelect bare value={member.role} disabled={busy} aria-label="Role"
                onChange={(e) => patch({ role: e.target.value, ...(e.target.value === 'member' && member.all_domains ? { all_domains: true } : {}) })}
                options={ORG_ROLES.filter((r) => r === member.role || roleTargets.includes(r))
                  .map((r) => ({ value: r, label: ROLE_LABEL[r] }))} />
            ) : (
              <span className={styles.roleTag}>{ROLE_LABEL[member.role] || member.role}{isSelf ? ' · you' : ''}</span>
            )}
            <StatusBadge status={member.status} busy={busy} />
          </div>
        </header>

        {error && (
          <p className={admin.settingsError} role="alert">
            <Icon name="exclamationmark.triangle.fill" size={13} /> {error}
          </p>
        )}

        {/* ── What can they see? ── */}
        <section className={styles.card}>
          <div className={styles.cardHead}>
            <span className={styles.cardLabel}>/ access</span>
            <h2 className={styles.cardTitle}>What can {who(member)} see?</h2>
          </div>
          <div className={styles.cardBody}>
            {isAdmin ? (
              <p className={styles.note}>
                <Icon name="globe" size={13} /> {ROLE_LABEL[member.role]}s see every domain in this workspace.
                Make them a Member to limit what they see.
              </p>
            ) : (
              <>
                <div className={admin.offboardChoices}>
                  <Choice
                    checked={!scoped}
                    onChange={() => !busy && patch({ all_domains: true })}
                    title="Everything"
                    desc="Every domain's inbox in this workspace, including domains added later."
                    img={everythingIcon}
                  />
                  <Choice
                    checked={scoped}
                    onChange={() => !busy && scoped === false && patch({ all_domains: false, domain_ids: member.domains.map((d) => d.id) })}
                    title="Specific domains"
                    desc="Only the domains you pick below, plus any rules you add."
                    img={specificIcon}
                  />
                </div>

                {scoped && (
                  <>
                    <div className={styles.domainList}>
                      {domains.map((d) => (
                        <label key={d.id} className={styles.domainRow}>
                          <MgmtCheckbox
                            
                            checked={grantedIds.has(d.id)}
                            disabled={busy}
                            onChange={() => toggleDomain(d.id)}
                          />
                          <Icon name="globe" size={13} />
                          <span className={styles.domainName}>{d.name}</span>
                        </label>
                      ))}
                    </div>
                    {grantedIds.size === 0 && (
                      <p className={styles.note}>
                        <Icon name="eye" size={13} /> No domains picked. {who(member)} only sees mail your rules match
                        or that someone shares.
                      </p>
                    )}
                  </>
                )}
              </>
            )}
          </div>
        </section>

        {/* ── Rules that extend access ── */}
        {!isAdmin && scoped && (
          <section className={styles.card}>
            <div className={styles.cardHead}>
              <span className={styles.cardLabel}>/ extend with rules</span>
              <h2 className={styles.cardTitle}>Also show conversations that match</h2>
              <MgmtButton variant="glass" size="sm" onClick={() => setRuleModal(true)} disabled={busy}>
                <Icon name="plus" size={13} /> Add rule
              </MgmtButton>
            </div>
            <div className={styles.cardBody}>
              {memberRules.length === 0 ? (
                <p className={styles.note}>
                  No rules yet. A rule shows {who(member)} matching mail, like everything to info@
                  or mail from one customer.
                </p>
              ) : (
                <div className={styles.ruleList}>
                  {memberRules.map((r) => (
                    <div key={r.id} className={styles.ruleRow}>
                      <Icon name="eye" size={13} />
                      <span className={styles.ruleText}>{ruleSummary(r)}</span>
                      <IconButton className={admin.personAction} icon="xmark" iconSize={11} disabled={busy} onClick={() => revokeRule(r)}
                        title={`Remove rule ${r.name}`} aria-label={`Remove rule ${r.name}`} />
                    </div>
                  ))}
                </div>
              )}
            </div>
          </section>
        )}

        {/* ── Send as ── */}
        {!isAdmin && (
          <section className={styles.card}>
            <div className={styles.cardHead}>
              <span className={styles.cardLabel}>/ send as</span>
              <h2 className={styles.cardTitle}>Addresses {who(member)} can send from</h2>
            </div>
            <div className={styles.cardBody}>
              <p className={styles.note}>
                Besides their own mailboxes. Add a shared address like info@ so their replies go out from it.
              </p>
              {(member.send_as_addresses || []).length > 0 && (
                <div className={styles.ruleList}>
                  {member.send_as_addresses.map((a) => (
                    <div key={a} className={styles.ruleRow}>
                      <Icon name="paperplane" size={13} />
                      <span className={styles.ruleText}>{a}</span>
                      <IconButton className={admin.personAction} icon="xmark" iconSize={11} disabled={busy}
                        onClick={() => setSendAs(member.send_as_addresses.filter((x) => x !== a))}
                        title={`Stop sending as ${a}`} aria-label={`Stop sending as ${a}`} />
                    </div>
                  ))}
                </div>
              )}
              <div className={admin.condRow}>
                <input className={[admin.modalInput, admin.condValue].join(' ')} value={sendLocal}
                  placeholder="info" aria-label="Address name" disabled={busy}
                  onChange={(e) => setSendLocal(e.target.value)}
                  onKeyDown={(e) => { if (e.key === 'Enter') addSendAs(); }} />
                <MgmtSelect bare value={sendDomain || domains[0]?.name || ''} aria-label="Domain" disabled={busy}
                  onChange={(e) => setSendDomain(e.target.value)}
                  options={domains.map((d) => ({ value: d.name, label: `@${d.name}` }))} />
                <MgmtButton variant="glass" size="sm" onClick={addSendAs} disabled={busy || !sendLocal.trim()}>
                  <Icon name="plus" size={13} /> Add
                </MgmtButton>
              </div>
            </div>
          </section>
        )}

        {/* ── Their addresses ── */}
        {(member.mailboxes?.length || 0) > 0 && (
          <section className={styles.card}>
            <div className={styles.cardHead}>
              <span className={styles.cardLabel}>/ addresses</span>
              <h2 className={styles.cardTitle}>Their mailboxes</h2>
            </div>
            <div className={styles.cardBody}>
              <div className={admin.dns}>
                {member.mailboxes.map((mb) => (
                  <div key={mb.id} className={admin.dnsRow}>
                    <span className={admin.dnsStatusDot}><Icon name="envelope.fill" size={13} className={admin.dnsOk} /></span>
                    <span className={admin.dnsType}>MAILBOX</span>
                    <span className={admin.dnsMono}>{mb.email_address}</span>
                  </div>
                ))}
              </div>
            </div>
          </section>
        )}
      </div>

      {ruleModal && (
        <VisibilityRuleModal
          member={member}
          orgKey={orgId}
          onClose={() => setRuleModal(false)}
          onDone={async () => { setRuleModal(false); await reload(); }}
        />
      )}
    </div>
  );
}

// Compact human summary of a visibility rule's conditions ("to contains info@").
const OP_LABEL = { equals: 'is', contains: 'contains', starts_with: 'starts with', ends_with: 'ends with' };
function ruleSummary(rule) {
  const parts = (rule.conditions || []).map((c) => `${c.field} ${OP_LABEL[c.operator] || c.operator} ${c.value}`);
  return parts.join(' & ') || rule.name;
}

// Condition vocabulary (mirrors Rule::FIELDS/OPERATORS server-side; static UI
// config, not data). has_attachment is omitted — it makes no sense as an access
// pattern on its own.
const RULE_FIELDS = [
  { value: 'to', label: 'To address' },
  { value: 'from', label: 'From address' },
  { value: 'subject', label: 'Subject' },
  { value: 'body', label: 'Body' },
];
const RULE_OPERATORS = [
  { value: 'contains', label: 'contains' },
  { value: 'equals', label: 'is exactly' },
  { value: 'starts_with', label: 'starts with' },
  { value: 'ends_with', label: 'ends with' },
];

/* Create a visibility rule for one member: conditions matched against inbound
 * mail (AND-ed) whose only action grants this member access to the matched
 * conversation. Saves the rule, then backfills it over existing mail so "they
 * can see info@" holds retroactively, not just for new messages. */
function VisibilityRuleModal({ member, orgKey, onClose, onDone }) {
  const [conditions, setConditions] = useState([{ field: 'to', operator: 'contains', value: '' }]);
  const [preview, setPreview] = useState(null); // { total, scanned_capped }
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState(null);

  const complete = conditions.filter((c) => c.value.trim() !== '');
  const canSave = complete.length === conditions.length && conditions.length > 0;

  // Debounced live preview of how many existing conversations would match.
  useEffect(() => {
    let cancelled = false;
    const t = setTimeout(() => {
      if (complete.length === 0) { setPreview(null); return; }
      api.post(`/orgs/${orgKey}/rules/preview`, {
        conditions: complete.map((c) => ({ field: c.field, operator: c.operator, value: c.value.trim() })),
      })
        .then((r) => { if (!cancelled) setPreview(r); })
        .catch(() => { if (!cancelled) setPreview(null); });
    }, 400);
    return () => { cancelled = true; clearTimeout(t); };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [orgKey, JSON.stringify(complete)]);

  const setCond = (i, patch) =>
    setConditions((cs) => cs.map((c, j) => (j === i ? { ...c, ...patch } : c)));
  const addCond = () => setConditions((cs) => [...cs, { field: 'subject', operator: 'contains', value: '' }]);
  const removeCond = (i) => setConditions((cs) => cs.filter((_, j) => j !== i));

  const save = async () => {
    setBusy(true);
    setError(null);
    try {
      const payload = {
        name: `Visibility · ${who(member)} · ${ruleSummary({ conditions: complete })}`.slice(0, 120),
        conditions: complete.map((c) => ({ field: c.field, operator: c.operator, value: c.value.trim() })),
        actions: [{ type: 'grant_access', value: member.id }],
        enabled: true,
      };
      const { rule } = await api.post(`/orgs/${orgKey}/rules`, payload);
      // Backfill over already-received mail so matching threads are visible now.
      await api.post(`/orgs/${orgKey}/rules/${rule.id}/apply-existing`, {});
      await onDone();
    } catch (e) {
      setError(e?.message || "Couldn't create the rule.");
      setBusy(false);
    }
  };

  return (
    <MgmtModal open onClose={busy ? undefined : onClose} onSubmit={busy || !canSave ? undefined : save} width={560}>
      <h2 className={admin.modalTitle}>Visibility rule for {who(member)}</h2>
      <p className={admin.modalSub}>
        {who(member)} also sees mail that matches all of these.
      </p>

      <div className={admin.modalField}>
        <span className={admin.modalLabel}>When a conversation matches</span>
        {conditions.map((c, i) => (
          <div key={i} className={admin.condRow}>
            <MgmtSelect bare value={c.field} aria-label="Field"
              onChange={(e) => setCond(i, { field: e.target.value })} options={RULE_FIELDS} />
            <MgmtSelect bare value={c.operator} aria-label="Operator"
              onChange={(e) => setCond(i, { operator: e.target.value })} options={RULE_OPERATORS} />
            <input className={[admin.modalInput, admin.condValue].join(' ')} value={c.value}
              placeholder={c.field === 'to' ? 'info@yourdomain.com' : 'value…'} aria-label="Value"
              onChange={(e) => setCond(i, { value: e.target.value })} />
            {conditions.length > 1 && (
              <IconButton className={admin.personAction} icon="xmark" iconSize={11} onClick={() => removeCond(i)} title="Remove condition" aria-label="Remove condition" />
            )}
          </div>
        ))}
        <button type="button" className={admin.accessAdd} onClick={addCond}>
          <Icon name="plus" size={11} /> Condition
        </button>
      </div>

      {preview && (
        <p className={admin.rulePreview}>
          <Icon name="eye" size={12} /> {preview.total}{preview.scanned_capped ? '+' : ''} existing conversation{preview.total === 1 ? '' : 's'} match. They'll show up too.
        </p>
      )}

      {error && <p className={admin.settingsError} role="alert"><Icon name="exclamationmark.triangle.fill" size={13} /> {error}</p>}

      <div className={admin.modalActions}>
        <MgmtButton variant="glass" className={admin.modalCancel} onClick={onClose} disabled={busy}>Cancel</MgmtButton>
        <MgmtButton onClick={save} disabled={busy || !canSave}>
          {busy ? 'Creating…' : 'Create rule'}
        </MgmtButton>
      </div>
    </MgmtModal>
  );
}
