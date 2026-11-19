import Icon from '../Icon';
import Button from '../Button/Button';
import ConfirmDialog from '../ConfirmDialog/ConfirmDialog';
import { ACTION_KINDS, BUILTIN_ACTIONS } from '../../lib/localAgents';
import styles from './CreateRulePopup.module.css';

// One-line summary of a rule's action for the list view.
function summarizeAction(action) {
  if (action?.type === ACTION_KINDS.PERFORM) {
    return BUILTIN_ACTIONS.find((a) => a.value === action.builtin)?.label || action.builtin || 'action';
  }
  return action?.adapter_id || 'agent';
}

// One-line summary of a rule's Tier-0 conditions for the list view.
const FIELD_LABEL = { from: 'From', to: 'To', subject: 'Subject', body: 'Body' };
const OP_LABEL = { contains: 'contains', equals: 'is', starts_with: 'starts with', ends_with: 'ends with' };
function summarizeConditions(conditions) {
  const parts = (conditions || []).map((c) => {
    if (c.field === 'has_attachment') return c.op === 'is_false' ? 'No attachment' : 'Has attachment';
    return `${FIELD_LABEL[c.field] || c.field} ${OP_LABEL[c.op] || c.op} ${c.value}`.trim();
  });
  return parts.length ? parts.join(' · ') : 'No conditions';
}

/**
 * The current-rules list (Settings → Auto rules surface). Lifted verbatim from
 * RuleManager's renderList; the toggle / info / edit / delete row controls stay
 * bespoke (list-row styling), the "Add rule" CTA is the catalog Button.
 */
export default function RulesList({
  rules, busyKey, error, confirmDelete,
  onToggle, onEdit, onConfirmDelete, onDelete, onCancelDelete, onAddRule,
}) {
  return (
    <>
      {rules.length === 0 ? (
        <p className={styles.empty}>
          No rules yet. Add one to act on new mail that matches.
        </p>
      ) : (
        <div className={styles.list}>
          {rules.map((rule) => {
            const enabled = rule.enabled !== false;
            const busy = busyKey === rule.key;
            return (
              <div key={rule.key} className={styles.ruleRow}>
                <button
                  type="button"
                  className={`${styles.toggle} ${enabled ? styles.toggleOn : styles.toggleOff}`}
                  onClick={() => onToggle(rule)}
                  disabled={busy}
                  aria-label={enabled ? 'Disable rule' : 'Enable rule'}
                  title={enabled ? 'On. Click to turn off.' : 'Off. Click to turn on.'}
                >
                  <Icon name={enabled ? 'checkmark.circle' : 'minus.circle'} size={15} />
                </button>
                <button type="button" className={styles.ruleInfo} onClick={() => onEdit(rule)}>
                  <span className={styles.ruleName}>{rule.name}</span>
                  <span className={styles.ruleSummary}>
                    {summarizeConditions(rule.conditions)}
                    {` → ${summarizeAction(rule.action)}`}
                  </span>
                </button>
                <button
                  type="button"
                  className={styles.iconBtn}
                  onClick={() => onEdit(rule)}
                  aria-label="Edit rule"
                >
                  <Icon name="square.and.pencil" size={14} />
                </button>
                <button
                  type="button"
                  className={`${styles.iconBtn} ${styles.iconBtnDanger}`}
                  onClick={() => onConfirmDelete(rule)}
                  disabled={busy}
                  aria-label="Delete rule"
                >
                  <Icon name="trash" size={14} />
                </button>
              </div>
            );
          })}
        </div>
      )}

      {error && <p className={styles.error}>{error}</p>}

      <div className={styles.actions}>
        <Button onClick={onAddRule}>
          <Icon name="plus" size={12} /> Add rule
        </Button>
      </div>

      <ConfirmDialog
        open={!!confirmDelete}
        title="Delete rule?"
        message={
          confirmDelete
            ? `You’ll lose “${confirmDelete.name}” for good.`
            : ''
        }
        confirmLabel="Delete rule"
        onConfirm={() => onDelete(confirmDelete)}
        onCancel={onCancelDelete}
      />
    </>
  );
}
