import { useState } from 'react';
import Icon from '../Icon';
import useCopyToClipboard from '../../hooks/useCopyToClipboard';
import styles from './SecretValue.module.css';

/* A long machine value in a compact chip: masked by default, with reveal and
 * copy. Copy always takes the real value, so the common case (paste it into a
 * config file) never needs the reveal at all.
 *
 * Used for identifiers and credentials that are too long to sit inline — an
 * application ID, a token, a webhook secret. Not every value here is a true
 * secret; masking is as much about density as it is about shoulder-surfing. */
export default function SecretValue({ value, label = 'value', className = '' }) {
  const [shown, setShown] = useState(false);
  const [copied, copy] = useCopyToClipboard();

  if (!value) return null;

  // Keep the type prefix (oap_, ink_, …) legible while masking the rest — it's
  // what tells you *which* kind of value this is. Fixed-width mask so the dots
  // don't leak the length.
  const split = value.indexOf('_') + 1;
  const masked = `${split > 0 ? value.slice(0, split) : ''}${'•'.repeat(16)}`;

  return (
    <span className={`${styles.wrap} ${className}`}>
      <code className={styles.value}>{shown ? value : masked}</code>
      <button
        type="button"
        className={styles.action}
        onClick={() => setShown((v) => !v)}
        title={shown ? `Hide ${label}` : `Show ${label}`}
        aria-label={shown ? `Hide ${label}` : `Show ${label}`}
        aria-pressed={shown}
      >
        <Icon name={shown ? 'eye.slash' : 'eye'} size={13} />
      </button>
      <button
        type="button"
        className={styles.action}
        onClick={() => copy(value)}
        title={`Copy ${label}`}
        aria-label={`Copy ${label}`}
      >
        <Icon name={copied ? 'checkmark' : 'doc.on.doc'} size={13} />
      </button>
    </span>
  );
}
