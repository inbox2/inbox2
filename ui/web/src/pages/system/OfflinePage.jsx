import StatusPage from '../../components/StatusPage/StatusPage';
import { isTauri } from '../../lib/tauri';

/**
 * Shown instead of the login screen when session restore fails for a reason
 * that isn't an auth rejection (network down, API 5xx/502). The session is
 * still valid and still stored — the server just can't be reached — so bouncing
 * to /login would be a lie, and the login form couldn't reach the API either.
 * AuthProvider keeps retrying with backoff behind this screen.
 */
export default function OfflinePage({ onRetry }) {
  return (
    <StatusPage
      code="⚠"
      title="Can't reach inbox2"
      message={`You're still signed in. We'll keep trying to load your domain mail.${
        isTauri() ? ' Your Gmail, Outlook and IMAP accounts keep working.' : ''
      }`}
      actionLabel="Retry now"
      onAction={onRetry}
    />
  );
}
