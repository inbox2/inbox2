import { useCallback, useEffect, useRef, useState } from 'react';
import { useSearchParams, useNavigate } from 'react-router';
import api from '../../lib/api';
import AuthLayout from '../../components/AuthLayout/AuthLayout';
import Button from '../../components/Button/Button';
import styles from './auth.module.css';
import { consolePath } from '../../lib/consoleHost';

/* Invite-onboarding landing (linked from the invite email). A fresh invitee
 * picks a username + password; someone with an existing session skips the form
 * entirely (the server ignores credentials for claimed accounts and just
 * activates their pending invites). Managers land on /console, members on the
 * inbox. */
export default function AcceptInvitePage() {
  const [searchParams] = useSearchParams();
  const inviteId = searchParams.get('invite') || '';
  const [username, setUsername] = useState('');
  const [password, setPassword] = useState('');
  const [error, setError] = useState('');
  const [loading, setLoading] = useState(false);
  // null until the stored-token check resolves; then true → auto-accept, false → form.
  const [signedIn, setSignedIn] = useState(null);
  const navigate = useNavigate();

  const accept = useCallback(async (credentials) => {
    setError('');
    setLoading(true);
    try {
      const data = await api.acceptInvite({ invite_id: inviteId, ...credentials });
      // The already-signed-in path (existing account accepting extra invites)
      // returns no token — the current session stays.
      if (data.token) api.setToken(data.token);
      // Managers land on the console; members go straight to their inbox.
      navigate(data.admin ? consolePath() : '/');
    } catch (err) {
      // The invitee already has a claimed account — bounce through login and
      // return here so the pending invites still get activated.
      if (err.status === 401) {
        navigate(`/login?next=${encodeURIComponent(`/accept-invite?invite=${inviteId}`)}`);
        return;
      }
      setError(err.message || "Couldn't accept invite");
      setSignedIn(false);
    } finally {
      setLoading(false);
    }
  }, [inviteId, navigate]);

  // With a live session (e.g. back from the login bounce) there's nothing to
  // fill in — accept straight away rather than showing credential fields the
  // server would ignore for a claimed account.
  const autoRan = useRef(false);
  useEffect(() => {
    let cancelled = false;
    api.getToken().then((token) => {
      if (cancelled) return;
      setSignedIn(!!token);
      if (token && !autoRan.current) { autoRan.current = true; accept({}); }
    });
    return () => { cancelled = true; };
  }, [accept]);

  if (signedIn !== false) {
    return (
      <AuthLayout title="Join Inbox2">
        <p className={styles.authSubtitle}>{error || 'Adding you to the team…'}</p>
      </AuthLayout>
    );
  }

  return (
    <AuthLayout title="Join Inbox2">
      <form className={styles.authForm} onSubmit={(e) => { e.preventDefault(); accept({ username, password }); }}>
        {error && <div className={styles.authError}>{error}</div>}
        <div className={styles.fieldGroup}>
          <label htmlFor="username">Choose a username</label>
          <input
            id="username"
            type="text"
            value={username}
            onChange={(e) => setUsername(e.target.value)}
            autoFocus
            required
            minLength={3}
          />
        </div>
        <div className={styles.fieldGroup}>
          <label htmlFor="password">Set your password</label>
          <input
            id="password"
            type="password"
            value={password}
            onChange={(e) => setPassword(e.target.value)}
            autoComplete="new-password"
            required
          />
        </div>
        <Button type="submit" className={styles.submitButton} disabled={loading}>
          {loading ? 'Joining...' : 'Join team'}
        </Button>
      </form>
    </AuthLayout>
  );
}
