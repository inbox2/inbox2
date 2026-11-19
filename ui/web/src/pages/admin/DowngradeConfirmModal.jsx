import { useState } from 'react';
import Icon from '../../components/Icon';
import { MgmtModal, MgmtButton, MgmtCheckbox } from '../../components/management';
import styles from './adminShared.module.css';

/* Gated downgrade confirm. When the target plan is cheaper than the current one
 * and the org is over the new limits, the API replies 422 with an `impact`
 * payload ({ domains_over, collaborators_over }). This modal spells out what gets
 * locked and forces an explicit acknowledgement checkbox before the downgrade is
 * re-submitted with `{ acknowledge: true }`. */
export default function DowngradeConfirmModal({ plan, impact, busy, onCancel, onConfirm }) {
  const [ack, setAck] = useState(false);
  const domainsOver = impact?.domains_over || 0;
  const collaboratorsOver = impact?.collaborators_over || 0;

  return (
    <MgmtModal open onClose={busy ? undefined : onCancel} width={520}>
      <h2 className={styles.modalTitle}>Downgrade to {plan?.name}?</h2>
      <p className={styles.modalSub}>
        You keep your data. Anything over the new limit is <strong>locked</strong> until
        you upgrade again.
      </p>

      <ul className={styles.downgradeImpact}>
        {domainsOver > 0 && (
          <li>
            <Icon name="lock.fill" size={14} className={styles.downgradeLockIcon} />
            <span>
              <strong>{domainsOver}</strong> domain{domainsOver === 1 ? '' : 's'} will stop
              receiving mail until you upgrade.
            </span>
          </li>
        )}
        {collaboratorsOver > 0 && (
          <li>
            <Icon name="lock.fill" size={14} className={styles.downgradeLockIcon} />
            <span>
              <strong>{collaboratorsOver}</strong> collaborator{collaboratorsOver === 1 ? '' : 's'} will
              be signed out until you move to a higher plan.
            </span>
          </li>
        )}
      </ul>

      <label className={styles.downgradeAck}>
        <MgmtCheckbox  checked={ack} onChange={(e) => setAck(e.target.checked)} />
        <span>I understand these stay locked until I upgrade.</span>
      </label>

      <div className={styles.modalActions}>
        <MgmtButton variant="glass" className={styles.modalCancel} onClick={onCancel} disabled={busy}>Cancel</MgmtButton>
        <MgmtButton variant="danger" onClick={onConfirm} disabled={busy || !ack}>
          {busy ? 'Downgrading…' : `Downgrade to ${plan?.name}`}
        </MgmtButton>
      </div>
    </MgmtModal>
  );
}
