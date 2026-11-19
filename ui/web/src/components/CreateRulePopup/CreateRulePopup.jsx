import Modal from '../Modal/Modal';
import RuleManager from './RuleManager';
import styles from './CreateRulePopup.module.css';

/**
 * Message-launched rule editor — a Modal wrapper around RuleManager. Opens straight
 * on a new rule prefilled from the conversation (the current-rules list lives only
 * in Settings → Auto rules). Modal unmounts its children when closed, so
 * RuleManager re-initializes on each open. See docs/Agentic-Filters.md §5.2.
 *
 * Props:
 *   open    — visibility
 *   onClose — dismiss
 *   prefill — { from, to, subject, hasAttachment } (see RuleManager)
 *   onSaved — called with the rule key after a successful save
 *   mx      — { orgId } when launched from MX-hosted mail (server-side rules);
 *             omit for local external-channel rules
 */
export default function CreateRulePopup({ open, onClose, prefill = {}, onSaved, mx }) {
  return (
    <Modal open={open} onClose={onClose} className={styles.panel}>
      <RuleManager prefill={prefill} onClose={onClose} onSaved={onSaved} mx={mx} />
    </Modal>
  );
}
