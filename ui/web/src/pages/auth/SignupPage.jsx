import { useState, useEffect } from 'react';
import { Link, useNavigate, useLocation } from 'react-router';
import useAuth from '../../hooks/useAuth';
import api from '../../lib/api';
import { ManagementLayout, MgmtAuthCard, MgmtField, MgmtButton } from '../../components/management';
import Icon from '../../components/Icon';
import { safeNextPath } from '../../lib/safeNext';
import styles from './authManagement.module.css';
import { consolePath } from '../../lib/consoleHost';

export default function SignupPage() {
  const [username, setUsername] = useState('');
  const [password, setPassword] = useState('');
  const [passwordConfirmation, setPasswordConfirmation] = useState('');
  const [billingEmail, setBillingEmail] = useState('');
  const [error, setError] = useState('');
  const [loading, setLoading] = useState(false);
  const { signup } = useAuth();
  const navigate = useNavigate();
  const location = useLocation();

  // Local-only ?next= return path (device-link approval).
  const next = safeNextPath(location.search);
  // Invite token from the emailed account-creation link (?invite=…).
  const inviteToken = new URLSearchParams(location.search).get('invite') || '';

  // Gate state: are direct signups invite-only, and is this invite valid?
  // null = still resolving (avoid a flash of the wrong screen).
  const [inviteEnabled, setInviteEnabled] = useState(null);
  const [inviteValid, setInviteValid] = useState(false);

  useEffect(() => {
    let active = true;
    api.waitlistConfig()
      .then(async (cfg) => {
        if (!active) return;
        const enabled = !!cfg?.invite_enabled;
        setInviteEnabled(enabled);
        if (enabled && inviteToken) {
          try {
            const { email } = await api.waitlistInviteLookup(inviteToken);
            if (!active) return;
            setBillingEmail(email || '');
            setInviteValid(true);
          } catch {
            if (active) setInviteValid(false);
          }
        }
      })
      .catch(() => { if (active) setInviteEnabled(false); });
    return () => { active = false; };
  }, [inviteToken]);

  const handleSubmit = async (e) => {
    e.preventDefault();
    setError('');

    if (password !== passwordConfirmation) {
      setError("Passwords don't match");
      return;
    }

    setLoading(true);
    try {
      await signup({
        username,
        password,
        password_confirmation: passwordConfirmation,
        billing_email: billingEmail,
        ...(inviteToken ? { invite_token: inviteToken } : {}),
      });
      // New accounts land in the console to connect their first domain, unless a
      // ?next return path was supplied (device-link approval).
      navigate(next || consolePath());
    } catch (err) {
      setError(err.message || 'Signup failed');
    } finally {
      setLoading(false);
    }
  };

  // Still resolving the gate — render nothing to avoid a flash.
  if (inviteEnabled === null) {
    return <ManagementLayout centered brand={false}><span /></ManagementLayout>;
  }

  // Invite-only and no valid invite → funnel to the waitlist.
  if (inviteEnabled && !inviteValid) {
    return (
      <ManagementLayout centered brand={false}>
        <MgmtAuthCard
          title="inbox2 is invite-only"
          subtitle={inviteToken
            ? "This invite link doesn’t work anymore. Request a new one below."
            : "We're letting people in bit by bit. Request access and we'll email your invite."}
          footer={<span className={styles.muted}>Already have an account? <Link className={styles.link} to="/login">Log in</Link></span>}
        >
          <Link to="/waitlist">
            <MgmtButton variant="primary" block>Request early access <Icon name="arrow.right" size={14} /></MgmtButton>
          </Link>
        </MgmtAuthCard>
      </ManagementLayout>
    );
  }

  const invited = inviteEnabled && inviteValid;

  return (
    <ManagementLayout centered brand={false}>
      <MgmtAuthCard
        title="Create your account"
        subtitle={invited
          ? "Welcome to inbox2. Pick a username and password to finish."
          : "Set up inbox2 for your team, then connect your domain."}
        error={error || null}
        footer={<span className={styles.muted}>Already have an account? <Link className={styles.link} to={next ? `/login?next=${encodeURIComponent(next)}` : '/login'}>Log in</Link></span>}
      >
        <form className={styles.form} onSubmit={handleSubmit}>
          <MgmtField
            label="Username"
            type="text"
            value={username}
            onChange={(e) => setUsername(e.target.value)}
            placeholder="yourname"
            autoFocus
            required
            minLength={3}
          />
          <MgmtField
            label="Billing email"
            type="email"
            value={billingEmail}
            onChange={(e) => setBillingEmail(e.target.value)}
            placeholder="you@external-email.com"
            required
            readOnly={invited}
            hint={invited ? 'From your invite' : undefined}
          />
          <span className={styles.divider} />
          <MgmtField
            label="Password"
            type="password"
            value={password}
            onChange={(e) => setPassword(e.target.value)}
            placeholder="Create a password"
            autoComplete="new-password"
            required
          />
          {password && (
            <MgmtField
              label="Confirm password"
              type="password"
              value={passwordConfirmation}
              onChange={(e) => setPasswordConfirmation(e.target.value)}
              placeholder="Re-enter your password"
              autoComplete="new-password"
              required
            />
          )}
          <MgmtButton type="submit" variant="primary" block disabled={loading}>
            {loading ? 'Creating account…' : (<>Create account <Icon name="arrow.right" size={14} /></>)}
          </MgmtButton>
        </form>
      </MgmtAuthCard>
    </ManagementLayout>
  );
}
