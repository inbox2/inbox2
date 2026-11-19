import Icon from '../Icon';
import styles from './MgmtDelta.module.css';

// Day-over-day delta pill; hidden when there's no prior day to compare against.
export default function MgmtDelta({ value }) {
  if (value == null) return null;
  const up = value >= 0;
  return (
    <span className={up ? styles.deltaUp : styles.deltaDown}>
      <Icon name={up ? 'arrow.up.right' : 'arrow.down.right'} size={10} /> {Math.abs(value)}%
    </span>
  );
}
