import { useState, useEffect, useMemo, useCallback } from 'react';
import api from '../lib/api';
import { isRealOrgId } from '../lib/org';
import log from '../lib/log';

/**
 * Colleague availability for the scheduling assistant (docs/Calendar.md).
 *
 * One request returns everything the grid needs — each attendee's identity,
 * timezone, working day and busy blocks, plus ranked slots that suit everyone.
 * Drawing one grid should not cost five round trips.
 *
 * MX-only: availability comes from the Rails API. Offline channels
 * (Gmail/Office365/IMAP) have no colleague directory to ask.
 */
export default function useAvailability(orgSlug, { emails, day, durationMinutes, enabled = true }) {
  // The window is the whole local day the grid shows, so a block starting
  // before midnight still lands in it.
  const { startIso, endIso } = useMemo(() => {
    if (!day) return { startIso: null, endIso: null };
    const from = new Date(day);
    from.setHours(0, 0, 0, 0);
    const to = new Date(from.getTime() + 24 * 60 * 60 * 1000);
    return { startIso: from.toISOString(), endIso: to.toISOString() };
  }, [day]);

  // Stable primitive so a fresh array identity doesn't refetch.
  const emailKey = useMemo(
    () => (emails || []).filter(Boolean).map(e => e.toLowerCase()).sort().join(','),
    [emails],
  );

  const requestKey = `${orgSlug}|${emailKey}|${startIso}|${endIso}|${durationMinutes || ''}`;
  const active = enabled && !!startIso && !!endIso && isRealOrgId(orgSlug);

  // Result carries the key it was loaded for, so "loading" is derived rather
  // than toggled from inside the effect — no synchronous setState, and the flag
  // is true exactly while the shown data doesn't match the asked-for params.
  const [result, setResult] = useState({ key: null, attendees: [], suggestions: [], error: null });
  const loading = active && result.key !== requestKey;

  const buildUrl = useCallback(() => {
    const params = new URLSearchParams();
    emailKey.split(',').filter(Boolean).forEach(e => params.append('emails[]', e));
    params.set('start', startIso);
    params.set('end', endIso);
    if (durationMinutes) params.set('duration_minutes', String(durationMinutes));
    return `/orgs/${orgSlug}/events/availability?${params.toString()}`;
  }, [orgSlug, emailKey, startIso, endIso, durationMinutes]);

  useEffect(() => {
    if (!active) return undefined;

    let cancelled = false;
    (async () => {
      try {
        const data = await api.get(buildUrl());
        // A slower earlier request must not overwrite a newer answer.
        if (cancelled) return;
        setResult({
          key: requestKey,
          attendees: data?.attendees || [],
          suggestions: data?.suggestions || [],
          error: null,
        });
      } catch (e) {
        if (cancelled) return;
        log.debug('Availability', `Lookup failed: ${e?.message}`);
        setResult({ key: requestKey, attendees: [], suggestions: [], error: e });
      }
    })();

    return () => { cancelled = true; };
  }, [active, buildUrl, requestKey]);

  return {
    attendees: result.attendees,
    suggestions: result.suggestions,
    error: result.error,
    loading,
  };
}
