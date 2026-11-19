import { MgmtButton, MgmtMeter } from '../../../components/management'
import formatBytes from '../../../lib/formatBytes'
import { EXACT } from '../../../lib/disk/engine/logic'
import styles from './Preview.module.css'


/**
 * The exact-view line above a quick view (spec F5b; disk.md "First use"):
 * the one-time offer with its size, progress and Cancel, Preparing, and the
 * question whether to always use exact view on this device. Presentational:
 * PreviewPane owns the state.
 *
 *   state   one of EXACT;  quick  whether a quick view shows underneath
 *   downloadSize, installSize, loaded, total, error
 *   onGet, onConfirm, onCancel, onConvert, onRetry, onAlways(yes)
 */
export default function ExactViewBar({ state, quick = true, downloadSize, installSize, loaded = 0, total = 0, error, onGet, onConfirm, onCancel, onConvert, onRetry, onAlways }) {
  const size = downloadSize ? formatBytes(downloadSize) : 'large'
  let body
  switch (state) {
    case EXACT.OFFER:
      body = <>
        <span className={styles.exactText}>{quick ? 'This is a quick view.' : 'There is no quick view for this type.'} Exact view needs a one-time {size} download.</span>
        <MgmtButton size="sm" variant="primary" onClick={onGet}>Get exact view</MgmtButton>
      </>
      break
    case EXACT.CONFIRM:
      body = <>
        <span className={styles.exactText}>This device is low on space. Exact view takes {installSize ? formatBytes(installSize) : 'a lot of space'}.</span>
        <MgmtButton size="sm" variant="primary" onClick={onConfirm}>Download anyway</MgmtButton>
        <MgmtButton size="sm" variant="ghost" onClick={onCancel}>Not now</MgmtButton>
      </>
      break
    case EXACT.DOWNLOADING:
      body = <>
        <span className={styles.exactText}>Downloading exact view: {formatBytes(loaded)} of {formatBytes(total)}. It keeps going if you close this.</span>
        <MgmtButton size="sm" variant="ghost" onClick={onCancel}>Cancel</MgmtButton>
        <div className={styles.exactMeter}><MgmtMeter value={total ? loaded / total : 0} /></div>
      </>
      break
    case EXACT.VERIFYING:
      body = <span className={styles.exactText}>Preparing exact view...</span>
      break
    case EXACT.READY:
      body = <>
        <span className={styles.exactText}>{quick ? 'This is a quick view.' : 'This type opens in exact view.'}</span>
        <MgmtButton size="sm" variant="primary" onClick={onConvert}>Show exact view</MgmtButton>
      </>
      break
    case EXACT.CONVERTING:
      body = <>
        <span className={styles.exactText}>Making the exact view on this device...</span>
        <MgmtButton size="sm" variant="ghost" onClick={onCancel}>Cancel</MgmtButton>
      </>
      break
    case EXACT.FAILED:
      body = <>
        <span className={styles.exactText} role="alert">{error || "Exact view didn't work."} {quick ? 'Quick view still works.' : 'Download the file to open it.'}</span>
        {onRetry && <MgmtButton size="sm" variant="ghost" onClick={onRetry}>Try again</MgmtButton>}
      </>
      break
    case EXACT.ASK_ALWAYS:
      body = <>
        <span className={styles.exactText}>Always open Office files in exact view on this device?</span>
        <MgmtButton size="sm" variant="primary" onClick={() => onAlways(true)}>Yes</MgmtButton>
        <MgmtButton size="sm" variant="ghost" onClick={() => onAlways(false)}>No</MgmtButton>
      </>
      break
    default:
      return null
  }
  return <div className={styles.exactBar} role="status">{body}</div>
}
