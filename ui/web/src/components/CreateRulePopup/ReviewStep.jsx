import Icon from '../Icon';
import Switch from '../Switch/Switch';
import styles from './CreateRulePopup.module.css';

/**
 * Step 3 — the review/preview: what the rule would do to mail already in the
 * inbox, plus the "apply to new / existing" toggles. Pure presentation.
 */
export default function ReviewStep({
  previewLoading, previewError, preview,
  editingEnabled, applyExisting, onEditingEnabled, onApplyExisting,
}) {
  return (
    <>
      <p className={styles.intro}>
        Here&apos;s what this rule would do to mail you already have.
      </p>

      {previewLoading ? (
        <p className={styles.previewStatus}>
          <Icon name="hourglass" size={13} /> Checking existing mail…
        </p>
      ) : previewError ? (
        <p className={styles.error}>{previewError}</p>
      ) : preview ? (
        <>
          <p className={styles.previewCount}>
            {preview.total === 0 ? (
              'No existing emails match these conditions.'
            ) : (
              <>
                <strong>
                  {preview.total}
                  {preview.scanned_capped ? '+' : ''}
                </strong>{' '}
                existing email{preview.total === 1 ? '' : 's'} match
                {preview.total === 1 ? 'es' : ''} these conditions.
              </>
            )}
          </p>

          {preview.samples.length > 0 && (
            <div className={styles.previewList}>
              {preview.samples.map((s) => (
                <div key={s.message_key} className={styles.previewRow}>
                  <span className={styles.previewFrom}>{s.from || '(unknown sender)'}</span>
                  <span className={styles.previewSubject}>{s.subject || '(no subject)'}</span>
                </div>
              ))}
              {preview.total > preview.samples.length && (
                <p className={styles.previewMore}>
                  +{preview.total - preview.samples.length}
                  {preview.scanned_capped ? '+' : ''} more
                </p>
              )}
            </div>
          )}

          <div className={styles.applyChoices}>
            <div className={styles.applyChoice}>
              <Switch
                id="apply-new"
                checked={editingEnabled}
                onChange={onEditingEnabled}
                label="Apply to new emails"
                description="Runs the action on matching mail as it arrives."
              />
            </div>
            <div className={styles.applyChoice}>
              <Switch
                id="apply-existing"
                checked={applyExisting}
                disabled={preview.total === 0}
                onChange={onApplyExisting}
                label="Apply to existing emails"
                description={
                  preview.total === 0
                    ? 'No existing emails match.'
                    : `Run the action now on the ${preview.total}${
                        preview.scanned_capped ? '+' : ''
                      } matching message${preview.total === 1 ? '' : 's'} already in your inbox.`
                }
              />
            </div>
          </div>
        </>
      ) : null}
    </>
  );
}
