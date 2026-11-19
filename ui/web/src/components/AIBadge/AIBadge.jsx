import Icon from '../Icon';
import Tooltip from '../Tooltip';
import styles from './AIBadge.module.css';

const SENTIMENT_CONFIG = {
  POSITIVE: { icon: 'checkmark.circle', label: 'Positive' },
  NEGATIVE: { icon: 'minus.circle', label: 'Negative' },
};

const INTENT_CONFIG = {
  question: { icon: 'magnifyingglass', label: 'Question' },
  request: { icon: 'bolt.fill', label: 'Action requested' },
  complaint: { icon: 'exclamationmark.triangle', label: 'Complaint' },
  FYI: { icon: 'eye', label: 'Informational' },
  scheduling: { icon: 'calendar', label: 'Scheduling' },
  other: { icon: 'ellipsis', label: 'General' },
};

/**
 * Displays a classification result as a subtle icon with tooltip.
 *
 * @param {Object} props
 * @param {'sentiment' | 'intent'} props.type - Badge type
 * @param {string} props.label - Classification label (e.g. 'POSITIVE', 'question')
 * @param {number} props.score - Confidence score 0-1
 * @param {number} [props.threshold=0.6] - Minimum confidence to show badge
 */
export default function AIBadge({ type, label, score, threshold = 0.6 }) {
  const config = type === 'sentiment' ? SENTIMENT_CONFIG[label] : INTENT_CONFIG[label];

  if (!label || score < threshold || !config) return null;

  const tooltipText = `${config.label} (${Math.round(score * 100)}%)`;

  return (
    <Tooltip content={tooltipText}>
      <span className={styles.badge}>
        <Icon name={config.icon} size={13} />
      </span>
    </Tooltip>
  );
}

export { SENTIMENT_CONFIG, INTENT_CONFIG };
