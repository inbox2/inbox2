import Chip from '../Chip/Chip';
import Icon from '../Icon';
import { chips as toChips, without, EMPTY_QUERY } from '../../lib/searchQuery';
import styles from './SearchFilters.module.css';

/**
 * The active search filters, one removable pill each. Reads straight off the
 * parsed query object, so it can't disagree with the box or the results.
 */
export default function SearchFilterChips({ filter, onChange }) {
  const items = toChips(filter);
  if (items.length === 0) return null;

  return (
    <div className={styles.chipBar}>
      {items.map(chip => (
        <Chip
          key={chip.key}
          className={styles.chip}
          maxWidth={220}
          onClick={() => onChange(without(filter, chip))}
          title={`Remove ${chip.label}`}
          aria-label={`Remove filter ${chip.label}`}
        >
          {chip.label}
          <Icon name="xmark" size={7} className={styles.chipRemove} />
        </Chip>
      ))}
      {items.length > 1 && (
        <button type="button" className={styles.clearAll} onClick={() => onChange({ ...EMPTY_QUERY, text: filter.text })}>
          Clear filters
        </button>
      )}
    </div>
  );
}
