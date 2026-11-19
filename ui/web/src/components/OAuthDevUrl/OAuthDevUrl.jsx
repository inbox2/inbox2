import useCopyToClipboard from '../../hooks/useCopyToClipboard'
import styles from './OAuthDevUrl.module.css'

/**
 * Dev-mode override panel for OAuth setup screens.
 *
 * Surfaced when the user toggles dev mode with the backtick (`) key. Shows the
 * authorization URL in a read-only field so it can be copied into a different
 * browser instead of the OS default. The loopback callback
 * (http://localhost:{port}/oauth-callback) still hooks back into the app
 * regardless of which browser completes the flow.
 *
 * Props:
 *   url     — the OAuth authorization URL
 *   onOpen  — optional callback to open the URL in the default browser
 */
export default function OAuthDevUrl({ url, onOpen }) {
  const [copied, copy] = useCopyToClipboard(1500)
  if (!url) return null

  const handleCopy = () => { copy(url) }

  return (
    <div className={styles.panel}>
      <div className={styles.header}>
        <span className={styles.badge}>dev</span>
        <span className={styles.note}>Paste into any browser. It brings you back here.</span>
      </div>
      <div className={styles.row}>
        <input
          className={styles.url}
          value={url}
          readOnly
          spellCheck={false}
          onFocus={(e) => e.target.select()}
        />
        <button type="button" className={styles.btn} onClick={handleCopy}>
          {copied ? 'Copied' : 'Copy'}
        </button>
        {onOpen && (
          <button type="button" className={styles.btn} onClick={onOpen}>
            Open
          </button>
        )}
      </div>
    </div>
  )
}
