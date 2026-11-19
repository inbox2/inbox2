import Icon from '../Icon';
import { MgmtSelect } from '../management';
import styles from './CreateRulePopup.module.css';

// Condition-builder options. Fields/ops mirror the Rust Tier-0 matcher
// (local_agents/rules.rs); keep them in sync.
const COND_FIELDS = [
  { value: 'from', label: 'From' },
  { value: 'to', label: 'To' },
  { value: 'subject', label: 'Subject' },
  { value: 'body', label: 'Body' },
  { value: 'has_attachment', label: 'Attachment' },
];
const TEXT_OPS = [
  { value: 'contains', label: 'contains' },
  { value: 'equals', label: 'is' },
  { value: 'starts_with', label: 'starts with' },
  { value: 'ends_with', label: 'ends with' },
];
const BOOL_OPS = [
  { value: 'is_true', label: 'present' },
  { value: 'is_false', label: 'absent' },
];
const isBoolField = (f) => f === 'has_attachment';

/**
 * Step 1 — rule name + the Tier-0 condition rows. Pure presentation; all state
 * mutation goes through the callbacks (which wrap the editor's setField).
 */
export default function ConditionsStep({
  name, conditions, onName, onChangeField, onUpdateCondition, onAddCondition, onRemoveCondition,
}) {
  return (
    <>
      <label className={styles.field}>
        <span className={styles.label}>Rule name</span>
        <input className={styles.input} value={name} onChange={(e) => onName(e.target.value)} />
      </label>

      <p className={styles.intro}>Run the agent when a message matches all of these:</p>

      <div className={styles.conds}>
        {conditions.map((c, i) => {
          const bool = isBoolField(c.field);
          const ops = bool ? BOOL_OPS : TEXT_OPS;
          return (
            <div key={i} className={styles.condRow}>
              <MgmtSelect
                bare
                compact
                className={styles.condField}
                value={c.field}
                onChange={(e) => onChangeField(i, e.target.value)}
                options={COND_FIELDS}
                aria-label="Field"
              />
              <MgmtSelect
                bare
                compact
                className={styles.condOp}
                value={c.op}
                onChange={(e) => onUpdateCondition(i, { op: e.target.value })}
                options={ops}
                aria-label="Operator"
              />
              {!bool && (
                <input
                  className={`${styles.input} ${styles.condValue}`}
                  value={c.value}
                  onChange={(e) => onUpdateCondition(i, { value: e.target.value })}
                  placeholder={c.field === 'from' ? 'billing@acme.com' : 'text…'}
                />
              )}
              <button
                type="button"
                className={styles.condRemove}
                onClick={() => onRemoveCondition(i)}
                disabled={conditions.length === 1}
                aria-label="Remove condition"
              >
                <Icon name="xmark" size={12} />
              </button>
            </div>
          );
        })}
      </div>

      <button type="button" className={styles.addCond} onClick={onAddCondition}>
        <Icon name="plus" size={12} /> Add condition
      </button>
    </>
  );
}
