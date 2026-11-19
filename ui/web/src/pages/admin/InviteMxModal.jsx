import { useState, useRef } from 'react';
import Icon from '../../components/Icon';
import { MgmtModal, MgmtButton, MgmtSelect } from '../../components/management';
import useDismiss from '../../hooks/useDismiss';
import api from '../../lib/api';
import log from '../../lib/log';
import styles from './adminShared.module.css';

/* Invite one person to a private mailbox on a single MX domain. Shared by the
 * admin console header and the per-domain Team tab (which fixes the domain). */

// One row of the MX dropdown: the domain's logo (or a fallback glyph), its
// display name, and its DNS name.
function MxOption({ domain }) {
  return (
    <span className={styles.mxOption}>
      <span className={styles.mxOptionIcon}>
        {domain.logoUrl ? <img src={domain.logoUrl} alt="" /> : <Icon name="globe" size={16} />}
      </span>
      <span className={styles.mxOptionText}>
        <span className={styles.mxOptionName}>{domain.displayName || domain.name}</span>
        <span className={styles.mxOptionDns}>{domain.domain}</span>
      </span>
    </span>
  );
}

// Single-select MX picker (icon + name + DNS name). Expands inline so the modal
// card's overflow never clips it.
function MxSelect({ domains, value, onChange }) {
  const [open, setOpen] = useState(false);
  const ref = useRef(null);
  const selected = domains.find((d) => d.key === value) || null;

  useDismiss(ref, () => setOpen(false), open);

  return (
    <div className={styles.mxSelect} ref={ref}>
      <button
        type="button"
        className={styles.mxSelectTrigger}
        onClick={() => setOpen((o) => !o)}
        aria-haspopup="listbox"
        aria-expanded={open}
      >
        {selected ? <MxOption domain={selected} /> : <span className={styles.mxSelectPlaceholder}>Select a domain</span>}
        <Icon name="chevron.down" size={12} className={styles.mxSelectChevron} />
      </button>
      {open && (
        <ul className={styles.mxSelectList} role="listbox">
          {domains.map((d) => (
            <li key={d.key}>
              <button
                type="button"
                role="option"
                aria-selected={d.key === value}
                className={`${styles.mxSelectItem} ${d.key === value ? styles.mxSelectItemOn : ''}`}
                onClick={() => { onChange(d.key); setOpen(false); }}
              >
                <MxOption domain={d} />
                {d.key === value && <Icon name="checkmark" size={13} className={styles.mxSelectCheck} />}
              </button>
            </li>
          ))}
        </ul>
      )}
    </div>
  );
}

// `lockedDomain` hides the picker when the caller already fixes the domain
// (a single-domain org's Team tab). `onClose` is called on dismiss and after a
// successful invite; `onInvited` (if given) fires first so callers can refresh
// their list — the pending row there is the confirmation.
export default function InviteMxModal({ domains, onClose, onInvited, lockedDomain = false }) {
  const [email, setEmail] = useState('');
  const [localPart, setLocalPart] = useState('');
  const [role, setRole] = useState('member');
  const [domainKey, setDomainKey] = useState(() => domains[0]?.key || '');
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState(null);

  const selectedDomain = domains.find((d) => d.key === domainKey) || null;

  const submit = async () => {
    if (!email.trim() || !domainKey) return;
    setBusy(true);
    setError(null);
    try {
      await api.inviteMx({
        email: email.trim(),
        local_part: localPart.trim() || undefined,
        role,
        domain_ids: [domainKey],
      });
      onInvited?.();
      onClose();
    } catch (e) {
      log.warn('Admin', `Invite failed: ${e?.message || e}`);
      setError(e?.message || "Couldn't send the invite.");
      setBusy(false);
    }
  };

  return (
    <MgmtModal open onClose={busy ? undefined : onClose} onSubmit={busy ? undefined : submit} width={520}>
      <h2 className={styles.modalTitle}>Invite a teammate</h2>
      <p className={styles.modalSub}>
        {lockedDomain && selectedDomain
          ? `They’ll get a private mailbox on ${selectedDomain.domain}.`
          : 'They’ll get a private mailbox on the domain you select.'}
      </p>
      <label className={styles.modalField}>
        <span className={styles.modalLabel}>Email</span>
        <input className={styles.modalInput} type="email" value={email} onChange={(e) => setEmail(e.target.value)} placeholder="teammate@external.com" />
      </label>
      {!lockedDomain && (
        <div className={styles.modalField}>
          <span className={styles.modalLabel}>Domain</span>
          <MxSelect domains={domains} value={domainKey} onChange={setDomainKey} />
        </div>
      )}
      <label className={styles.modalField}>
        <span className={styles.modalLabel}>Mailbox name</span>
        <div className={styles.inviteLocal}>
          <input className={styles.modalInput} value={localPart} onChange={(e) => setLocalPart(e.target.value)} placeholder="mailbox" />
          <span className={styles.inviteAt}>@ {selectedDomain?.domain || 'domain'}</span>
        </div>
      </label>
      <label className={styles.modalField}>
        <span className={styles.modalLabel}>Role</span>
        <MgmtSelect bare value={role} onChange={(e) => setRole(e.target.value)}>
          <option value="member">Member</option>
          <option value="admin">Admin</option>
        </MgmtSelect>
      </label>
      {error && <p className={styles.settingsError} role="alert"><Icon name="exclamationmark.triangle.fill" size={13} /> {error}</p>}
      <div className={styles.modalActions}>
        <MgmtButton variant="glass" className={styles.modalCancel} onClick={onClose}>Cancel</MgmtButton>
        <MgmtButton variant="primary" onClick={submit} disabled={busy || !email.trim() || !domainKey}>
          {busy ? 'Inviting…' : 'Send invite'}
        </MgmtButton>
      </div>
    </MgmtModal>
  );
}
