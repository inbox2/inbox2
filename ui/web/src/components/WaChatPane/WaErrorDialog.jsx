import ConfirmDialog from '../ConfirmDialog'
import { isNoAccess, isNoAx, waErrorText, waOpenAccessibilitySettings, waOpenPrivacySettings } from '../../lib/localWhatsApp'

/**
 * A local-WhatsApp action that failed (send, Open in WhatsApp), as
 * the app's own alert: what went wrong in plain words, and the one button that
 * fixes it when there is one (the macOS privacy pane Inbox2 needs).
 * `error` null = closed.
 */
export default function WaErrorDialog({ error, title, onClose }) {
  const fix = isNoAx(error)
    ? { title: 'Allow Inbox2 to type into WhatsApp', label: 'Open Accessibility', run: waOpenAccessibilitySettings }
    : isNoAccess(error)
      ? { title: "Inbox2 can't read WhatsApp", label: 'Open Full Disk Access', run: waOpenPrivacySettings }
      : null
  return (
    <ConfirmDialog
      open={!!error}
      title={fix?.title || title}
      message={waErrorText(error)}
      variant="warning"
      confirmLabel={fix ? fix.label : 'OK'}
      cancelLabel={fix ? 'Close' : null}
      onConfirm={() => { fix?.run().catch(() => {}); onClose() }}
      onCancel={onClose}
    />
  )
}
