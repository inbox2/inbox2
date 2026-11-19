import { useRef, useEffect } from 'react'
import styles from './SyncProgressBar.module.css'

/**
 * Sync progress bar shown at the top of the conversation list while a sync is
 * in flight.
 *
 * Pass a `progress` object to render a *deterministic* bar (a real percentage)
 * for the active account's current folder:
 *   { folderName, folderIndex, totalFolders, synced, folderTotal }
 * — `folderTotal` is the provider's folder size (exact for IMAP, an estimate
 * for Gmail). When it's missing (Microsoft delta gives no total) the bar falls
 * back to the indeterminate animated sliver.
 *
 * Overall fraction = (completed folders + current-folder fraction) / total
 * folders, so it advances within a folder and reaches 100% at the end.
 */
export default function SyncProgressBar({ progress, label: idleLabel = 'Syncing mailbox' }) {
  const fillRef = useRef(null)

  const folderTotal = progress?.folderTotal
  const synced = progress?.synced ?? 0
  const totalFolders = progress?.totalFolders || 1
  const folderIndex = progress?.folderIndex || 1

  // Deterministic only when we have a *trustworthy* denominator for the current
  // folder. Gmail's `resultSizeEstimate` is a rough first-page guess that can be
  // wildly low (e.g. ~201 for an 11k-message All Mail); once we've synced past
  // it the estimate is disproven, so fall back to the indeterminate bar rather
  // than peg the fill at 100% and show a contradictory "11,002 / ~201" label.
  const determinate =
    progress != null && folderTotal != null && folderTotal > 0 && synced <= folderTotal
  const folderFraction = determinate ? Math.min(synced / folderTotal, 1) : 0
  const overall = determinate
    ? Math.min(((folderIndex - 1) + folderFraction) / totalFolders, 1)
    : 0

  // No inline styles (ESLint): drive the width via a CSS custom property.
  useEffect(() => {
    if (fillRef.current) {
      fillRef.current.style.setProperty('--sync-pct', `${Math.round(overall * 100)}%`)
    }
  }, [overall])

  if (!determinate) {
    return (
      <div className={styles.track} role="progressbar" aria-label={idleLabel}>
        <div className={styles.indicator} />
      </div>
    )
  }

  const pct = Math.round(overall * 100)
  const label = progress.folderName
    ? `Syncing ${progress.folderName}: ${synced.toLocaleString()} / ~${folderTotal.toLocaleString()} (folder ${folderIndex} of ${totalFolders})`
    : 'Syncing mailbox'

  return (
    <div
      className={styles.track}
      role="progressbar"
      aria-label={label}
      aria-valuenow={pct}
      aria-valuemin={0}
      aria-valuemax={100}
    >
      <div ref={fillRef} className={styles.fill} />
      {/* Faint sheen sweeping the track — signals "still working" while the
          fill shows real progress. */}
      <div className={styles.shimmer} aria-hidden="true" />
    </div>
  )
}
