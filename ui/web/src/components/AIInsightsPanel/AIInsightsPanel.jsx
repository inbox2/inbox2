import { isInferenceReady } from '../../lib/ai';
import { useAIClassification } from '../../lib/ai/useAIClassification';
import { SENTIMENT_CONFIG, INTENT_CONFIG } from '../AIBadge';
import AIBadge from '../AIBadge';
import Spinner from '../Spinner';
import styles from './AIInsightsPanel.module.css';

/**
 * A single signal row: spinner while inference is in flight, the classified
 * badge once a result lands, or an em-dash when there's nothing to show.
 */
function SignalRow({ label, loading, type, result, config }) {
  const conf = result?.label ? config[result.label] : null;
  return (
    <div className={styles.row}>
      <span className={styles.label}>{label}</span>
      {loading ? (
        <span className={styles.loading}><Spinner size={8} /> Analyzing</span>
      ) : conf ? (
        <span className={styles.value}>
          <AIBadge type={type} label={result.label} score={result.score} />
          {conf.label} ({Math.round(result.score * 100)}%)
        </span>
      ) : (
        <span className={styles.value}>{'—'}</span>
      )}
    </div>
  );
}

/**
 * Signals section for the context sidebar.
 * Shows Tier A classification results (sentiment + intent) for a conversation.
 * Returns null when AI is not available — parent should not render a header.
 *
 * @param {Object} props
 * @param {string} props.messageId - ID of the latest message for classification
 * @param {string} props.plainText - Plain text of the latest message
 * @param {Object} [props.message] - Latest message object (for cache seeding from persisted columns)
 */
export default function AIInsightsPanel({ messageId, plainText, message }) {
  const { sentiment, intent, loading } = useAIClassification(messageId, plainText, message);

  // AI not available — hide entirely
  if (!isInferenceReady()) {
    return null;
  }

  return (
    <div className={styles.container}>
      <SignalRow label="Sentiment" loading={loading} type="sentiment" result={sentiment} config={SENTIMENT_CONFIG} />
      <SignalRow label="Intent" loading={loading} type="intent" result={intent} config={INTENT_CONFIG} />
    </div>
  );
}
