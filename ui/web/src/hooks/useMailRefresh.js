import { useEffect, useRef } from 'react';
import orgLiveMail from '../lib/orgLiveMail';

/**
 * Realtime new-mail refresh: fires `onRefresh` (throttled by orgLiveMail) whenever
 * new MX mail lands in any of the user's orgs, delivered over ActionCable. This is
 * the instant path — it works even while the tab is focused, unlike the polling
 * failsafe. Pair it with useRefetchOnFocus for the socket-dropped fallback.
 *
 * The callback is held in a ref so the subscription stays mounted for the
 * component's lifetime (no re-bind churn when the callback identity changes).
 *
 * @param {() => void} onRefresh
 */
export default function useMailRefresh(onRefresh) {
  const ref = useRef(onRefresh);
  useEffect(() => { ref.current = onRefresh; }, [onRefresh]);
  useEffect(() => orgLiveMail.onNewMail(() => ref.current?.()), []);
}
