import ConfirmDialog from '../ConfirmDialog/ConfirmDialog'
import useReauthAlert from '../../hooks/useReauthAlert'

const PROVIDER_LABELS = { gmail: 'Gmail', microsoft: 'Office 365', imap: 'IMAP' }

/**
 * Global one-time alert when a connected account's sign-in expires
 * (`needs_reauth`): offers to jump to Settings → Connected accounts with the
 * reconnect flow pre-armed. Mounted once at the route root (desktop only —
 * the hook no-ops outside Tauri).
 */
export default function ReauthPrompt() {
  const { prompt, dismiss, reconnect } = useReauthAlert()

  return (
    <ConfirmDialog
      open={!!prompt}
      title="Sign-in expired"
      message={`${PROVIDER_LABELS[prompt?.provider] || 'This account'} (${prompt?.email || ''}) can’t get new mail until you reconnect.`}
      confirmLabel="Reconnect…"
      cancelLabel="Later"
      variant="warning"
      onConfirm={reconnect}
      onCancel={dismiss}
    />
  )
}
