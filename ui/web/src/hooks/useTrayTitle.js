import { useEffect, useState } from 'react';
import useUnreadStore from '../stores/unreadStore';
import { fetchNextMeeting } from '../lib/localCalendar';
import { trayTitle } from '../lib/trayTitle';
import { isTauri } from '../lib/tauri';
import log from '../lib/log';
import useZoneStore from '../stores/zoneStore';
import { isActive } from '../lib/zones';

const TICK_MS = 30 * 1000;

/**
 * Keeps the menu bar item's text current. Lives in the MAIN window because the
 * popover's own webview is hidden (and so suspended) almost all the time.
 * Mount once, next to useDockBadge.
 */
export default function useTrayTitle() {
  const total = useUnreadStore(s => s.total);
  const [next, setNext] = useState(null);
  const [now, setNow] = useState(() => Date.now());

  useEffect(() => {
    if (!isTauri()) return undefined;
    let alive = true;
    // ponytail: local-channel calendars only, like the calendar rail — MX
    // calendars aren't in SQLite. Merge mxUpcoming (useMeetingReminders) in if
    // an MX-only user misses their meetings up here.
    const tick = async () => {
      const meeting = await fetchNextMeeting();
      if (alive) { setNext(meeting); setNow(Date.now()); }
    };
    tick();
    const timer = setInterval(tick, TICK_MS);
    return () => { alive = false; clearInterval(timer); };
  }, []);

  // The zone running now, if any (useZoneAlerts keeps the store fed). The 30s
  // tick is plenty — the title shows minutes, not seconds.
  const zones = useZoneStore(s => s.zones);
  const zone = zones.find(z => isActive(z, now)) || null;
  const title = trayTitle(total, next, now, zone);
  useEffect(() => {
    if (!isTauri()) return;
    import('@tauri-apps/api/core')
      .then(({ invoke }) => invoke('tray_set_title', { title }))
      .catch(e => log.warn('Tray', `set title failed: ${e?.message || e}`));
  }, [title]);
}
