// Named-timezone support for FullCalendar via the browser's Intl, so we can
// display the grid in any IANA zone (e.g. Europe/Amsterdam while sitting in
// Dubai). The official plugins bundle moment-timezone's ~1MB offset table;
// Intl already carries that data, so this is the whole thing in ~30 lines.
import { createPlugin } from '@fullcalendar/core';
import { NamedTimeZoneImpl } from '@fullcalendar/core/internal';

// UTC ms -> [year, month(0-11), day, hour, minute, second, ms] as wall time in `tz`.
function timestampToArray(ms, tz) {
  const p = new Intl.DateTimeFormat('en-US', {
    timeZone: tz, hourCycle: 'h23',
    year: 'numeric', month: '2-digit', day: '2-digit',
    hour: '2-digit', minute: '2-digit', second: '2-digit',
  }).formatToParts(new Date(ms));
  const g = (t) => +p.find((x) => x.type === t).value;
  return [g('year'), g('month') - 1, g('day'), g('hour') % 24, g('minute'), g('second'), 0];
}

class IntlNamedTimeZone extends NamedTimeZoneImpl {
  timestampToArray(ms) {
    return timestampToArray(ms, this.timeZoneName);
  }
  // Wall-time array in this zone -> offset (minutes east of UTC).
  offsetForArray(a) {
    const asUtc = Date.UTC(a[0], a[1], a[2], a[3], a[4], a[5]);
    const back = timestampToArray(asUtc, this.timeZoneName);
    // ponytail: "pretend array is UTC" trick; off by an offset-step only in the
    // ~1h DST fold, which FullCalendar never queries for a whole-grid render.
    return (Date.UTC(back[0], back[1], back[2], back[3], back[4], back[5]) - asUtc) / 60000;
  }
}

export { IntlNamedTimeZone };

export default createPlugin({
  name: 'intl-named-timezone',
  namedTimeZonedImpl: IntlNamedTimeZone, // note: core's option key really is spelled with the extra "d"
});
