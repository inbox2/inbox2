import { useState, useEffect } from 'react';
import Icon from '../../components/Icon';
import { MgmtButton, MgmtSelect } from '../../components/management';
import api from '../../lib/api';
import log from '../../lib/log';
import useAuth from '../../hooks/useAuth';
import styles from './mailboxStep.module.css';

// Turn a name/email into a valid local-part (Membership::LOCAL_PART_FORMAT):
// lowercase, drop any @domain, keep [a-z0-9._-], trim stray separators.
function toLocalPart(raw) {
  return String(raw || '')
    .toLowerCase()
    .split('@')[0]
    .replace(/[^a-z0-9._-]+/g, '')
    .replace(/^[._-]+|[._-]+$/g, '');
}

// Post-domain-setup step: create the mailboxes for this domain. The owner's own
// address is pre-filled (the whole reason we're here — a new domain should give
// you an address). Also assign existing teammates and invite new ones, each
// landing on THIS domain. Reuses POST /mailboxes for members and inviteMx for
// new invites.
//
// orgKey / domainKey (dom_ key) / domainName: the just-set-up domain.
// onDone(): advance the wizard.
export default function MailboxStep({ orgKey, domainKey, domainName, onDone }) {
  const { user } = useAuth();
  const [members, setMembers] = useState([]);
  const [created, setCreated] = useState([]); // [{ email, kind }]
  const [error, setError] = useState('');
  const [busy, setBusy] = useState(false);

  // My own mailbox (pre-filled from my name), an existing-member assignment, and
  // an invite — three independent little forms.
  const [mineLocal, setMineLocal] = useState('');
  const [mineMembership, setMineMembership] = useState(null); // resolved after load
  const [pick, setPick] = useState(''); // selected member key
  const [pickLocal, setPickLocal] = useState('');
  const [inviteEmail, setInviteEmail] = useState('');
  const [inviteLocal, setInviteLocal] = useState('');

  useEffect(() => {
    if (!orgKey) return;
    api.getMembers(orgKey)
      .then((d) => {
        const list = d.members || [];
        setMembers(list);
        // Find my membership (one per user) to own the pre-filled mailbox.
        const mine = list.find((m) => m.user?.username === user?.username);
        setMineMembership(mine?.id || null);
        setMineLocal(toLocalPart(user?.display_name || user?.username));
      })
      .catch((e) => log.warn('MailboxStep', `members load: ${e?.message || e}`));
  }, [orgKey, user]);

  // Members who don't already have a mailbox on THIS domain (candidates to assign).
  const assignable = members.filter(
    (m) => m.user?.username !== user?.username
      && !m.mailboxes?.some((mb) => mb.domain === domainName),
  );

  const record = (email, kind) => setCreated((c) => [...c, { email, kind }]);

  const addMailbox = async (membershipId, localPart, kind) => {
    const lp = toLocalPart(localPart);
    if (!membershipId || !lp) { setError('Enter a mailbox name.'); return false; }
    setBusy(true); setError('');
    try {
      const { mailbox } = await api.createMailbox(orgKey, { membershipId, domainId: domainKey, localPart: lp });
      record(mailbox.email_address, kind);
      return true;
    } catch (e) {
      setError(e?.message || "Couldn't create that mailbox.");
      return false;
    } finally { setBusy(false); }
  };

  const addMine = async () => { if (await addMailbox(mineMembership, mineLocal, 'me')) setMineLocal(''); };

  const addExisting = async () => {
    if (!pick) { setError('Pick a teammate.'); return; }
    const lp = pickLocal || toLocalPart(members.find((m) => m.id === pick)?.user?.display_name || members.find((m) => m.id === pick)?.user?.username);
    if (await addMailbox(pick, lp, 'existing')) { setPick(''); setPickLocal(''); }
  };

  const invite = async () => {
    const email = inviteEmail.trim();
    const lp = toLocalPart(inviteLocal || email);
    if (!email || !lp) { setError('Enter an email and mailbox name.'); return; }
    setBusy(true); setError('');
    try {
      await api.inviteMx({ email, local_part: lp, role: 'member', domain_ids: [domainKey] });
      record(`${lp}@${domainName}`, 'invite');
      setInviteEmail(''); setInviteLocal('');
    } catch (e) {
      setError(e?.message || "Couldn't send the invite.");
    } finally { setBusy(false); }
  };

  const atSuffix = <span className={styles.at}>@ {domainName}</span>;

  return (
    <>
      <h1 className={styles.title}>Set up mailboxes</h1>
      <p className={styles.sub}>Give people an address on <strong>{domainName}</strong>. Their mail still lands in the domain’s inbox for the whole team.</p>

      {created.length > 0 && (
        <ul className={styles.created}>
          {created.map((c) => (
            <li key={c.email} className={styles.createdRow}>
              <Icon name="checkmark.circle.fill" size={15} className={styles.createdOk} />
              <span className={styles.createdAddr}>{c.email}</span>
              <span className={styles.createdKind}>{c.kind === 'invite' ? 'invited' : c.kind === 'me' ? 'you' : 'assigned'}</span>
            </li>
          ))}
        </ul>
      )}

      {error && <div className={styles.error} role="alert">{error}</div>}

      {/* Your own mailbox — pre-filled from your name. */}
      {mineMembership && !created.some((c) => c.kind === 'me') && (
        <div className={styles.block}>
          <span className={styles.blockLabel}>Your mailbox</span>
          <div className={styles.row}>
            <div className={styles.localWrap}>
              <input className={styles.input} value={mineLocal} onChange={(e) => setMineLocal(e.target.value)} placeholder="you" aria-label="Your mailbox name" />
              {atSuffix}
            </div>
            <MgmtButton variant="primary" onClick={addMine} disabled={busy || !mineLocal.trim()}>Add</MgmtButton>
          </div>
        </div>
      )}

      {/* Assign an existing teammate. */}
      {assignable.length > 0 && (
        <div className={styles.block}>
          <span className={styles.blockLabel}>Add existing user</span>
          <div className={styles.row}>
            <MgmtSelect bare compact value={pick} onChange={(e) => setPick(e.target.value)} placeholder="Select a teammate"
              options={assignable.map((m) => ({ value: m.id, label: m.user?.display_name || m.user?.username || m.email_addresses?.[0] || '—' }))}
            />
            <div className={styles.localWrap}>
              <input className={styles.input} value={pickLocal} onChange={(e) => setPickLocal(e.target.value)} placeholder="name" aria-label="Mailbox name" />
              {atSuffix}
            </div>
            <MgmtButton variant="glass" onClick={addExisting} disabled={busy || !pick}>Add</MgmtButton>
          </div>
        </div>
      )}

      {/* Invite someone new. */}
      <div className={styles.block}>
        <span className={styles.blockLabel}>Invite new user</span>
        <div className={styles.row}>
          <input className={styles.input} type="email" value={inviteEmail} onChange={(e) => setInviteEmail(e.target.value)} placeholder="teammate@external.com" aria-label="Invite email" />
          <div className={styles.localWrap}>
            <input className={styles.input} value={inviteLocal} onChange={(e) => setInviteLocal(e.target.value)} placeholder="name" aria-label="Mailbox name" />
            {atSuffix}
          </div>
          <MgmtButton variant="glass" onClick={invite} disabled={busy || !inviteEmail.trim()}>Invite</MgmtButton>
        </div>
      </div>

      <MgmtButton variant="primary" block onClick={onDone} className={styles.done}>
        {created.length ? 'Continue' : 'Skip for now'}
      </MgmtButton>
    </>
  );
}
