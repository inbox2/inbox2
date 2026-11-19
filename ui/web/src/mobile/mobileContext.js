import { createContext, useContext, useMemo } from 'react';
import { useParams } from 'react-router';
import useAuth from '../hooks/useAuth';
import { resolveWorkspace } from '../lib/workspace';

// Shared by the phone screens (src/mobile/): which tab is current, which org a
// screen belongs to, and the shell's notification-panel opener.

export const MOBILE_TAB = { INBOX: 'inbox', SEARCH: 'search', CALENDAR: 'calendar', MORE: 'more' };

// The org a phone screen belongs to: the URL's workspace slug (a domain or org
// slug), else the signed-in user's current org.
export function useMobileOrg() {
  const { orgSlug } = useParams();
  const { organizations, currentOrgSlug } = useAuth();
  return useMemo(() => {
    const fromUrl = resolveWorkspace(organizations, orgSlug);
    const org = fromUrl.org
      || organizations?.find((o) => o.slug === currentOrgSlug)
      || organizations?.[0]
      || null;
    return { org, domain: fromUrl.domain, orgSlug: org?.slug || orgSlug || null };
  }, [organizations, orgSlug, currentOrgSlug]);
}

// Screens open the notification panel from their own top bar.
export const MobileNotifContext = createContext(() => {});
export const useOpenNotifications = () => useContext(MobileNotifContext);
