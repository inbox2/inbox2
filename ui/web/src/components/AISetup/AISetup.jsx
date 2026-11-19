import { useState, useEffect } from 'react';
import Button from '../Button/Button';
import { ErrorMessage } from '../FormField/FormField';
import Icon from '../Icon';
import {
  detectCapabilities,
  matchBackends,
  getTierADownloadSizeMB,
  downloadAllModels,
  setAIConsent,
  allModelsReady,
  initializeInference,
  isInferenceReady,
  isGenerativeReady,
} from '../../lib/ai';
import styles from './AISetup.module.css';

/**
 * AI Features setup/consent flow.
 * Can be embedded in onboarding or launched from settings.
 *
 * Consent-only: opting in NEVER blocks on a download. The (small)
 * classification models fetch in the background, and generation engines
 * (Apple Intelligence / local model / OpenAI) are chosen — and downloaded —
 * in Settings → On-device AI.
 *
 * @param {Object} props
 * @param {() => void} props.onComplete - Called when setup finishes (opt-in or skip)
 * @param {boolean} [props.compact] - Whether to render in compact settings mode
 */
export default function AISetup({ onComplete, compact = false }) {
  const [phase, setPhase] = useState('detecting'); // detecting | consent | done | unsupported | skipped
  const [decision, setDecision] = useState(null);
  const [error, setError] = useState(null);
  const [tierStatus, setTierStatus] = useState({ a: false, b: false, bReason: '' });

  useEffect(() => {
    let cancelled = false;
    detectCapabilities().then(caps => {
      if (cancelled) return;
      const d = matchBackends(caps);
      setDecision(d);

      if (!caps.canRunClassification) {
        setPhase('unsupported');
      } else if (allModelsReady() && isInferenceReady()) {
        setTierStatus({ a: true, b: isGenerativeReady(), bReason: '' });
        setPhase('done');
      } else if (allModelsReady()) {
        setPhase('consent');
      } else {
        setPhase('consent');
      }
    });
    return () => { cancelled = true; };
  }, []);

  const handleOptIn = () => {
    setError(null);
    setAIConsent(true);

    // Classification models fetch in the BACKGROUND — onboarding completes
    // immediately. Failures are non-fatal: Settings → On-device AI re-offers
    // the download.
    downloadAllModels()
      .then(async (result) => {
        if (result?.success) await initializeInference();
      })
      .catch(() => {});

    setTierStatus({
      a: allModelsReady() && isInferenceReady(),
      b: isGenerativeReady(),
      bReason: '',
    });
    setPhase('done');
  };

  const handleSkip = () => {
    setPhase('skipped');
    onComplete?.();
  };

  const handleDone = () => {
    onComplete?.();
  };

  const downloadSize = getTierADownloadSizeMB();
  const containerClass = compact ? styles.setupCompact : styles.setup;

  if (phase === 'detecting') {
    return (
      <div className={containerClass}>
        <div className={styles.detecting}>
          <Icon name="gear" size={24} />
          <p className={styles.detectingText}>Checking this device…</p>
        </div>
      </div>
    );
  }

  if (phase === 'unsupported') {
    return (
      <div className={containerClass}>
        <div className={styles.header}>
          <Icon name="bolt.fill" size={20} className={styles.headerIcon} />
          <h3 className={styles.title}>On-device AI</h3>
        </div>
        <p className={styles.description}>
          This device can&apos;t run on-device AI.
          Everything else works as normal.
        </p>
        <Button variant="ghost" onClick={handleDone}>
          Continue
        </Button>
      </div>
    );
  }

  if (phase === 'consent') {
    return (
      <div className={containerClass}>
        <div className={styles.header}>
          <Icon name="bolt.fill" size={20} className={styles.headerIcon} />
          <h3 className={styles.title}>On-device AI</h3>
        </div>
        <p className={styles.description}>
          Sort your email by tone and intent with private AI on this device.
          Your mail never leaves it.
        </p>

        <div className={styles.features}>
          <div className={styles.feature}>
            <Icon name="checkmark.circle" size={16} />
            <span>Tone (positive or negative)</span>
          </div>
          <div className={styles.feature}>
            <Icon name="checkmark.circle" size={16} />
            <span>Intent (question, request, scheduling…)</span>
          </div>
          <div className={styles.feature}>
            <Icon name="checkmark.circle" size={16} />
            <span>Thread summaries and smart replies</span>
          </div>
        </div>

        {decision && (
          <div className={styles.techNote}>
            <span className={styles.techLabel}>Runtime:</span>
            <span>{decision.classificationReason}</span>
          </div>
        )}

        <div className={styles.sizeNote}>
          ~{downloadSize} MB downloads in the background. You can keep working.
        </div>

        <ErrorMessage>{error}</ErrorMessage>

        <div className={styles.actions}>
          <Button onClick={handleOptIn}>
            Turn on AI
          </Button>
          <Button variant="ghost" onClick={handleSkip}>
            Skip
          </Button>
        </div>
      </div>
    );
  }

  if (phase === 'done') {
    return (
      <div className={containerClass}>
        <div className={styles.header}>
          <Icon name="checkmark.circle.fill" size={20} className={styles.headerIcon} />
          <h3 className={styles.title}>AI is on</h3>
        </div>

        <div className={styles.features}>
          <div className={styles.feature}>
            <Icon name={tierStatus.a ? 'checkmark.circle.fill' : 'arrow.down.circle'} size={16} />
            <span>Sorting and insights: {tierStatus.a ? 'on' : 'downloading'}</span>
          </div>
          <div className={styles.feature}>
            <Icon name={tierStatus.b ? 'checkmark.circle.fill' : 'gearshape'} size={16} />
            <span>
              Writing help: {tierStatus.b ? 'on' : 'pick one in Settings → On-device AI'}
            </span>
          </div>
        </div>

        <Button onClick={handleDone}>
          Continue
        </Button>
      </div>
    );
  }

  return null;
}
