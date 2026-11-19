import { useCallback, useContext, useMemo } from 'react';
import { AuthContext } from './AuthProvider';
import useAccountStore from '../stores/accountStore';
import { getLastFrom } from '../lib/lastUsedPref';

/**
 * The set of addresses the user can send "From": their address at each Rails
 * org domain, plus every connected external account (Gmail/Microsoft/IMAP).
 * Each identity carries enough to render an icon + email in the compose header.
 *
 * Reads AuthContext directly (rather than useAuth) so it stays safe when used
 * outside an AuthProvider — e.g. isolated Storybook stories — returning [].
 *
 * @returns {Array<{key: string, email: string, label: string,
 *   providerType: string, iconUrl: ?string, avatarUrl: ?string}>}
 */
export default function useFromIdentities() {
  const auth = useContext(AuthContext);
  const externalAccounts = useAccountStore((s) => s.externalAccounts);

  const user = auth?.user;
  const organizations = auth?.organizations;

  return useMemo(() => {
    // One address per org domain (an org owns many equal domains; legacy
    // payloads carry only `domain`).
    const orgIdentities = (organizations || [])
      .filter(() => user?.username)
      .flatMap((o) => {
        // The server's list of what you may send as here (username@ each pool
        // domain, your mailboxes, admin-granted info@/sales@); older payloads
        // lack it → username@ each domain.
        const names = o.domains?.length ? o.domains.map((d) => d.name) : [o.domain];
        const emails = o.from_addresses || names.filter(Boolean).map((name) => `${user.username}@${name}`);
        return emails.map((email) => {
          const name = email.split('@')[1];
          return {
            key: `org:${o.slug || o.id}:${email}`,
            email,
            label: o.domains?.length > 1 ? name : (o.name || name),
            providerType: 'inbox2',
            orgId: o.id,
            iconUrl: o.icon_url || null,
            avatarUrl: null,
          };
        });
      });

    const extIdentities = (externalAccounts || [])
      .filter((a) => a.email_address)
      .map((a) => ({
        key: `ext:${a.key}`,
        email: a.email_address,
        label: a.display_name || a.email_address,
        providerType: a.provider_type,
        iconUrl: a.icon_url || null,
        avatarUrl: a.avatar_url || null,
      }));

    // De-dupe by email (an org address could also be a connected account).
    const seen = new Set();
    return [...orgIdentities, ...extIdentities].filter((i) => {
      const e = i.email.toLowerCase();
      if (seen.has(e)) return false;
      seen.add(e);
      return true;
    });
  }, [user, organizations, externalAccounts]);
}

/**
 * From for a fresh compose (not a reply/forward). With `rememberLast` (the
 * unified inbox only — a specific inbox composes from its own account): the
 * address last sent from when it's still an available identity, else
 * `fallback`. Read at call time so a send this session counts.
 */
export function useNewComposeFrom(fallback, rememberLast) {
  const identities = useFromIdentities();
  return useCallback(() => {
    if (!rememberLast) return fallback;
    const last = (getLastFrom() || '').toLowerCase();
    return identities.find((i) => i.email.toLowerCase() === last)?.email || fallback;
  }, [identities, fallback, rememberLast]);
}
