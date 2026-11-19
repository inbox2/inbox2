import { useState, useEffect, useCallback, useMemo } from 'react';
import { useNavigate } from 'react-router';
import Icon from '../../components/Icon';
import Avatar from '../../components/Avatar';
import Spinner from '../../components/Spinner';
import IconButton from '../../components/IconButton';
import DropdownMenu from '../../components/DropdownMenu/DropdownMenu';
import { MgmtModal, MgmtConfirm, MgmtButton, MgmtSelect } from '../../components/management';
import InviteMxModal from './InviteMxModal';
import useAuth from '../../hooks/useAuth';
import { ORG_ROLES, grantableRoles, canManageMember } from '../../lib/orgRoles';
import { ROLE_LABEL, STATUS_LABEL, who } from './memberDisplay';
import api from '../../lib/api';
import log from '../../lib/log';
import styles from './adminShared.module.css';
import { consolePath } from '../../lib/consoleHost';

/* Team management for ONE organization. The org owns many first-class domains
 * sharing a single pool; each member (one org membership) is granted per-domain
 * access — owners/admins always see every domain, a regular member sees only the
 * domains they're granted (optionally extended by grant_access visibility rules
 * or narrowed by the personal-mailbox exclusion). This table is the overview:
 * the access cell is a read-only summary, and clicking a person opens their
 * dedicated access page (/console/team/:orgId/:memberId) where everything is
 * managed. `scopeDomain` is the DomainSettingsPage object whose `.key` is the
 * ORG key (all of an org's domains route to the same settings/Team tab). */

export default function AdminPeople({ scopeDomain, title = 'Team' }) {
  const orgKey = scopeDomain?.key;
  const navigate = useNavigate();
  const { user, organizations } = useAuth();
  const [members, setMembers] = useState([]);
  const [rules, setRules] = useState([]); // org routing rules, for the access summary
  const [loading, setLoading] = useState(true);
  const [busyKey, setBusyKey] = useState(null); // membership key currently mutating
  const [error, setError] = useState(null); // { key, msg } from a failed change
  const [deleteMember, setDeleteMember] = useState(null);
  const [inviteOpen, setInviteOpen] = useState(false);

  const load = useCallback(() => Promise.all([
    api.getMembers(orgKey),
    api.get(`/orgs/${orgKey}/rules`).catch(() => ({ rules: [] })),
  ]), [orgKey]);

  const reload = useCallback(async () => {
    if (!orgKey) return;
    try {
      const [m, r] = await load();
      setMembers(m.members || []);
      setRules(r.rules || []);
    } catch (e) {
      log.warn('AdminPeople', `load failed: ${e?.message || e}`);
    } finally {
      setLoading(false);
    }
  }, [orgKey, load]);

  // Initial load — inline (setState lands in the promise callback, not in the
  // effect body) with a cancelled guard.
  useEffect(() => {
    if (!orgKey) return undefined;
    let cancelled = false;
    load()
      .then(([m, r]) => { if (!cancelled) { setMembers(m.members || []); setRules(r.rules || []); } })
      .catch((e) => log.warn('AdminPeople', `load failed: ${e?.message || e}`))
      .finally(() => { if (!cancelled) setLoading(false); });
    return () => { cancelled = true; };
  }, [orgKey, load]);

  // Role/status changes are one PATCH /members/:id; access editing lives on the
  // member's dedicated page.
  const patchMember = async (member, body) => {
    setBusyKey(member.id);
    setError(null);
    try {
      await api.updateMember(orgKey, member.id, body);
      await reload();
    } catch (e) {
      setError({ key: member.id, msg: `${who(member)}: ${e?.message || "couldn't update."}` });
    } finally {
      setBusyKey(null);
    }
  };

  const toggleStatus = (member) =>
    patchMember(member, { status: member.status === 'active' ? 'disabled' : 'active' });

  // How many rules extend this member's access (grant_access rules targeting them).
  const ruleCount = (member) =>
    rules.filter((r) => (r.actions || []).some((a) => a.type === 'grant_access' && a.value === member.id)).length;

  // The viewer's own role in this org (matched by username, the field both the
  // members list and the auth account carry) — gates who may change whose role.
  const myRole = useMemo(
    () => members.find((m) => m.user?.username && m.user.username === user?.username)?.role,
    [members, user],
  );

  const changeRole = (member, role) => {
    if (role === member.role) return;
    const body = { role };
    // Downgrading owner/admin → member: send their (all-domains) access explicitly
    // so a membership whose all_domains column was left false while they were an
    // admin doesn't silently land as Limited. The owner can then scope them on
    // their access page.
    if (role === 'member' && member.all_domains) body.all_domains = true;
    patchMember(member, body);
  };

  const openMember = (m) => navigate(consolePath(`team/${orgKey}/${m.id}`));

  const resendInvite = async (member) => {
    setBusyKey(member.id);
    setError(null);
    try {
      await api.resendInvite(orgKey, member.id);
    } catch (e) {
      setError({ key: member.id, msg: `${who(member)}: ${e?.message || "couldn't resend the invite."}` });
    } finally {
      setBusyKey(null);
    }
  };

  // The invite endpoint takes DOMAIN keys (the address lands on that exact
  // domain); `scopeDomain.key` is the ORG key, so build the picker's list from
  // the org's own domains.
  const inviteDomains = useMemo(() => {
    const org = (organizations || []).find((o) => o.id === orgKey);
    return (org?.domains || []).map((d) => ({
      key: d.id, name: d.name, domain: d.name, displayName: d.name, logoUrl: d.icon_url || org.icon_url || null,
    }));
  }, [organizations, orgKey]);

  if (loading) {
    return (
      <div className={styles.peopleLoading}>
        <Spinner size={20} color="var(--violet)" />
        <p className={styles.domainsEmptySub}>Loading team…</p>
      </div>
    );
  }

  return (
    <section className={[styles.section, styles.embedded].join(' ')} id="people">
      <div className={styles.sectionHead}>
        <h2 className={styles.sectionTitle}>{title}</h2>
        <span className={styles.peopleCount}>{members.length} {members.length === 1 ? 'person' : 'people'}</span>
        <MgmtButton variant="glass" size="sm" onClick={() => setInviteOpen(true)}>
          <Icon name="person.badge.plus" size={14} /> Invite
        </MgmtButton>
      </div>

      {error && (
        <div className={styles.peopleBanner} role="alert">
          <Icon name="exclamationmark.triangle.fill" size={14} />
          <span>{error.msg}</span>
          <IconButton className={styles.peopleBannerClose} icon="xmark" iconSize={12} onClick={() => setError(null)} aria-label="Dismiss" />
        </div>
      )}

      {members.length === 0 ? (
        <div className={styles.domainsEmpty}>
          <Icon name="person.2" size={26} />
          <p className={styles.domainsEmptyTitle}>No team members yet</p>
          <p className={styles.domainsEmptySub}>Invite teammates, then grant each the domains they should see.</p>
        </div>
      ) : (
        <div className={styles.peopleTable} role="table">
          <div className={[styles.peopleRow, styles.peopleHeadRow].join(' ')} role="row">
            <span role="columnheader">Person</span>
            <span role="columnheader">Access</span>
            <span role="columnheader">Status</span>
            <span role="columnheader" className={styles.peopleActionsCol}>Actions</span>
          </div>
          {members.map((m) => {
            const busy = busyKey === m.id;
            const isSelf = m.user?.username && m.user.username === user?.username;
            // Roles the viewer may switch this member to. Owners are protected here
            // (like deactivate/remove) and you can't change your own role.
            const roleTargets = (m.role !== 'owner' && !isSelf && canManageMember(myRole, m.role))
              ? grantableRoles(myRole).filter((r) => r !== m.role)
              : [];
            return (
              <div key={m.id} className={styles.peopleRow} role="row">
                <span className={styles.personCell} role="cell">
                  <button type="button" className={styles.personBtn} onClick={() => openMember(m)}
                    title={`Manage ${who(m)}'s access`}>
                    <Avatar name={who(m)} email={m.user?.billing_email} size={32} />
                    <span className={styles.personText}>
                      <span className={styles.personName}>{who(m)} <span className={styles.personRole}>· {ROLE_LABEL[m.role] || m.role}</span></span>
                      <span className={styles.personEmail}>{m.user?.billing_email || m.email_addresses?.[0] || m.user?.username}</span>
                    </span>
                  </button>
                </span>

                <span className={styles.domainChips} role="cell">
                  <AccessSummary member={m} ruleCount={ruleCount(m)} onOpen={() => openMember(m)} />
                </span>

                <span role="cell"><StatusBadge status={m.status} busy={busy} /></span>

                <span className={styles.peopleActions} role="cell">
                  <RowActionsMenu
                    busy={busy}
                    isOwner={m.role === 'owner'}
                    invited={m.status === 'invited'}
                    active={m.status === 'active'}
                    currentRole={m.role}
                    roleTargets={roleTargets}
                    onManage={() => openMember(m)}
                    onChangeRole={(r) => changeRole(m, r)}
                    onToggle={() => toggleStatus(m)}
                    onResend={() => resendInvite(m)}
                    onDelete={() => setDeleteMember(m)}
                  />
                </span>
              </div>
            );
          })}
        </div>
      )}

      {deleteMember && (
        <OffboardModal
          member={deleteMember}
          members={members}
          orgKey={orgKey}
          onClose={() => setDeleteMember(null)}
          onDone={async () => { setDeleteMember(null); await reload(); }}
        />
      )}

      {inviteOpen && (
        <InviteMxModal
          domains={inviteDomains}
          lockedDomain={inviteDomains.length === 1}
          onInvited={reload}
          onClose={() => setInviteOpen(false)}
        />
      )}
    </section>
  );
}

/* Read-only access summary: "All domains" / the granted domain names / Limited,
 * plus how many rules extend it. Clicking it (like clicking the person) opens
 * the member's access page — all editing happens there. */
function AccessSummary({ member, ruleCount, onOpen }) {
  return (
    <button type="button" className={styles.accessSummary} onClick={onOpen} title="Manage access">
      {member.all_domains ? (
        <span className={styles.accessAllBadge}>All domains</span>
      ) : (
        <>
          {member.domains.length === 0 && ruleCount === 0 && (
            <span className={styles.limitedBadge}>Limited</span>
          )}
          {member.domains.map((d) => (
            <span key={d.id} className={styles.domainChip}>
              <span className={styles.domainChipName}>{d.name}</span>
            </span>
          ))}
          {ruleCount > 0 && (
            <span className={[styles.domainChip, styles.ruleChip].join(' ')}>
              <span className={styles.domainChipName}>+{ruleCount} rule{ruleCount === 1 ? '' : 's'}</span>
            </span>
          )}
        </>
      )}
    </button>
  );
}

export function StatusBadge({ status, busy = false }) {
  const cls = {
    active: styles.statusActive,
    invited: styles.statusInvited,
    disabled: styles.statusDisabled,
  }[status] || styles.statusDisabled;
  return (
    <span className={[styles.statusBadge, cls].join(' ')}>
      {busy ? <Spinner size={11} color="currentColor" /> : <span className={styles.statusDot} />}
      {busy ? 'Updating…' : (STATUS_LABEL[status] || status)}
    </span>
  );
}

function RowActionsMenu({ busy, isOwner, invited, active, currentRole, roleTargets = [], onManage, onChangeRole, onToggle, onResend, onDelete }) {
  // "Change role" → a submenu of the roles the viewer may grant (current marked
  // with a check; picking it is a no-op). Empty when the viewer can't manage this
  // member's role (owners protected, self, or insufficient rank).
  const roleItem = roleTargets.length > 0 ? {
    label: 'Change role', icon: 'person',
    submenu: ORG_ROLES
      .filter((r) => r === currentRole || roleTargets.includes(r))
      .map((r) => ({
        label: ROLE_LABEL[r],
        icon: r === currentRole ? 'checkmark' : undefined,
        onSelect: () => onChangeRole(r),
      })),
  } : null;

  // The owner can't be deactivated or removed here. A pending invite gets
  // "Resend invite" instead of a status toggle.
  const statusItems = isOwner ? [] : [
    invited
      ? { label: 'Resend invite', icon: 'paperplane', onSelect: onResend }
      : { label: active ? 'Deactivate' : 'Reactivate', icon: active ? 'pause.circle' : 'play.circle', onSelect: onToggle },
    { separator: true },
    { label: 'Remove', icon: 'trash', onSelect: onDelete },
  ];
  const manageItem = { label: 'Manage access', icon: 'eye', onSelect: onManage };
  const items = [
    manageItem,
    ...(roleItem ? [roleItem] : []),
    ...(statusItems.length ? [{ separator: true }, ...statusItems] : []),
  ];
  return (
    <DropdownMenu
      variant="light"
      align="right"
      trigger={<IconButton className={styles.personAction} icon="ellipsis" iconSize={16} size={32} disabled={busy} aria-haspopup="menu" title="Actions" />}
      items={items}
    />
  );
}

/* Offboarding: remove a member from the org, choosing what happens to their
 * mailbox mail (archive/wipe) and old address (bounce/reroute to a member). Uses
 * the offboarder endpoint (keyed by the user), scoped to this org. */
function OffboardModal({ member, members, orgKey, onClose, onDone }) {
  const [dataHandling, setDataHandling] = useState('archive');
  const [aliasHandling, setAliasHandling] = useState('bounce');
  const [rerouteTarget, setRerouteTarget] = useState('');
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState(null);
  const [confirm, setConfirm] = useState(false);

  // Reroute targets: other active members of this org (value = their membership key).
  const targetOptions = useMemo(() => members
    .filter((m) => m.id !== member.id && m.status === 'active')
    .map((m) => ({ value: m.id, label: `${who(m)} · ${m.email_addresses?.[0] || m.user?.username}` })), [members, member.id]);

  const effectiveTarget = targetOptions.find((o) => o.value === rerouteTarget) ? rerouteTarget : (targetOptions[0]?.value || '');
  const rerouteAllowed = targetOptions.length > 0;
  const effectiveAlias = (aliasHandling === 'reroute' && !rerouteAllowed) ? 'bounce' : aliasHandling;

  const submit = async () => {
    setBusy(true); setError(null);
    try {
      await api.deleteUser(member.user.id, {
        scope: 'domain',
        org_id: orgKey,
        data_handling: dataHandling,
        alias_handling: effectiveAlias,
        reroute_target_id: effectiveAlias === 'reroute' ? effectiveTarget : undefined,
      });
      await onDone();
    } catch (e) {
      setError(e?.message || "Couldn't remove this member.");
      setBusy(false);
      setConfirm(false);
    }
  };

  return (
    <>
      <MgmtModal open onClose={busy ? undefined : onClose} onSubmit={busy ? undefined : () => setConfirm(true)} width={520}>
        <h2 className={styles.modalTitle}>Remove {who(member)}</h2>
        <p className={styles.modalSub}>Choose what happens to their access, mail, and address.</p>

        <div className={styles.modalField}>
          <span className={styles.modalLabel}>Their mailbox mail</span>
          <div className={styles.offboardChoices}>
            <Choice checked={dataHandling === 'archive'} onChange={() => setDataHandling('archive')} title="Archive" desc="Keep it. You can still see it as an admin." />
            <Choice checked={dataHandling === 'wipe'} onChange={() => setDataHandling('wipe')} title="Wipe" desc="Delete mail to/from their address." />
          </div>
        </div>

        <div className={styles.modalField}>
          <span className={styles.modalLabel}>Their old address</span>
          <div className={styles.offboardChoices}>
            <Choice checked={effectiveAlias === 'bounce'} onChange={() => setAliasHandling('bounce')} title="Bounce" desc="Reject future mail to their address." />
            <Choice checked={effectiveAlias === 'reroute'} onChange={() => rerouteAllowed && setAliasHandling('reroute')} title="Reroute" disabled={!rerouteAllowed} desc={rerouteAllowed ? 'Give a member their mailbox.' : 'No other active member can take it.'} />
          </div>
          {effectiveAlias === 'reroute' && rerouteAllowed && (
            <MgmtSelect bare value={effectiveTarget} onChange={(e) => setRerouteTarget(e.target.value)} options={targetOptions} aria-label="Reroute to" />
          )}
        </div>

        {error && <p className={styles.settingsError} role="alert"><Icon name="exclamationmark.triangle.fill" size={13} /> {error}</p>}

        <div className={styles.modalActions}>
          <MgmtButton variant="glass" className={styles.modalCancel} onClick={onClose} disabled={busy}>Cancel</MgmtButton>
          <MgmtButton variant="danger" onClick={() => setConfirm(true)} disabled={busy}>
            {busy ? 'Removing…' : 'Remove member'}
          </MgmtButton>
        </div>
      </MgmtModal>

      {confirm && (
        <MgmtConfirm
          open
          title="Remove this member?"
          message={`${who(member)} loses access right away${dataHandling === 'wipe' ? ' and their mailbox mail is deleted for good' : ''}.`}
          confirmLabel="Remove member"
          danger
          busy={busy}
          onConfirm={submit}
          onClose={() => setConfirm(false)}
        />
      )}
    </>
  );
}

export function Choice({ checked, onChange, title, desc, disabled = false, img }) {
  return (
    <button type="button" className={[styles.choice, img ? styles.choiceStacked : '', checked ? styles.choiceOn : '', disabled ? styles.choiceDisabled : ''].join(' ')} onClick={onChange} disabled={disabled} aria-pressed={checked}>
      <span className={styles.choiceRadio}>{checked && <span className={styles.choiceDot} />}</span>
      {img && <img className={styles.choiceImg} src={img} alt="" />}
      <span className={styles.choiceText}>
        <span className={styles.choiceTitle}>{title}</span>
        <span className={styles.choiceDesc}>{desc}</span>
      </span>
    </button>
  );
}
