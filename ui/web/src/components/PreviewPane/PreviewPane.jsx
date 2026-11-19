import { sanitizePreviewHtml } from '../../lib/previewSanitizer'
import styles from './PreviewPane.module.css'

export default function PreviewPane({ html = '', quotedHtml = '' }) {
  const cleanBody = sanitizePreviewHtml(html)
  const cleanQuoted = sanitizePreviewHtml(quotedHtml)

  return (
    <div className={styles.preview}>
      <div className={styles.label}>Preview</div>
      <div className={styles.stripe} />
      <div className={styles.envelope}>
        <div
          className={styles.body}
          dangerouslySetInnerHTML={{ __html: cleanBody }}
        />
        {cleanQuoted && (
          <div className={styles.quoted}>
            <hr className={styles.quotedRule} />
            <div dangerouslySetInnerHTML={{ __html: cleanQuoted }} />
          </div>
        )}
      </div>
    </div>
  )
}
