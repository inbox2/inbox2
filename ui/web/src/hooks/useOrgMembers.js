import { useState, useEffect } from 'react';
import api from '../lib/api';
import { isRealOrgId } from '../lib/org';
import log from '../lib/log';

/* The org's members (memberships), for the Spaces dashboard team card and
 * anywhere a real headcount is needed. Returns [] until loaded / when there's no
 * real org (the unguarded /spaces design preview). Mirrors how /admin counts
 * users — every membership, not just those staffed on a space. */
export default function useOrgMembers(orgId) {
  const [members, setMembers] = useState([]);

  useEffect(() => {
    if (!isRealOrgId(orgId)) return undefined;
    let cancelled = false;
    api.getMembers(orgId)
      .then((d) => { if (!cancelled) setMembers(d.members || []); })
      .catch((e) => { log.warn('useOrgMembers', `failed: ${e?.message || e}`); });
    return () => { cancelled = true; };
  }, [orgId]);

  return members;
}
