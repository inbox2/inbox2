import { useEffect, useRef, useState } from 'react';
import { useNavigate, useSearchParams } from 'react-router';
import api from '../../lib/api';
import useAuth from '../../hooks/useAuth';
import { ManagementLayout, MgmtAuthCard, MgmtButton } from '../../components/management';
import { consolePath } from '../../lib/consoleHost';
import { mobileLayoutNow } from '../../hooks/useIsPhone';

/* Landing for SAML SSO (spec 2.1.7). The IdP posts the assertion to the API,
 * which bounces the browser here with a two-minute, single-use ticket; trading
 * it for a session is the only thing this page does. A linking round-trip
 * (Settings › Single sign-on › Link) ends here too — same ticket, same session. */
export default function SamlCallbackPage() {
  const [searchParams] = useSearchParams();
  const ticket = searchParams.get('ticket') || '';
  const [error, setError] = useState(ticket ? null : 'This sign-in link is incomplete.');
  const navigate = useNavigate();
  const { setToken, refreshAccount } = useAuth();
  const ran = useRef(false);

  useEffect(() => {
    if (!ticket || ran.current) return;
    ran.current = true;
    api.samlExchange(ticket)
      .then(async (data) => {
        // Same landing as a password login (LoginPage's HOME).
        setToken(data.token);
        if (refreshAccount) await refreshAccount();
        navigate(mobileLayoutNow() ? '/' : consolePath());
      })
      .catch((err) => setError(err?.status === 401 ? 'This sign-in link has expired. Start again from the login page.' : (err?.message || "Couldn't finish single sign-on.")));
  }, [ticket, navigate, setToken, refreshAccount]);

  return (
    <ManagementLayout centered brand={false}>
      <MgmtAuthCard
        title={error ? 'Sign-in failed' : 'Signing you in…'}
        subtitle={error ? undefined : 'Finishing single sign-on'}
        error={error}
        footer={error ? (
          <MgmtButton type="button" variant="primary" block onClick={() => navigate('/login')}>Back to log in</MgmtButton>
        ) : undefined}
      />
    </ManagementLayout>
  );
}
