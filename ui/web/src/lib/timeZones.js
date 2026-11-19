// Timezone naming + wall-clock helpers shared by the calendar's zone picker and
// the timezone planner. All data comes from Intl — no bundled zone table.

export const LOCAL_TZ = Intl.DateTimeFormat().resolvedOptions().timeZone;

export const ZONES = typeof Intl.supportedValuesOf === 'function'
  ? Intl.supportedValuesOf('timeZone')
  : [LOCAL_TZ];

const zoneName = (tz, style, date, locale = 'en-US') =>
  new Intl.DateTimeFormat(locale, { timeZone: tz, timeZoneName: style })
    .formatToParts(date || new Date())
    .find((p) => p.type === 'timeZoneName')?.value || '';

// "GMT+2" — the current offset.
export const shortOffset = (tz, date) => zoneName(tz, 'shortOffset', date) || tz;

// CLDR only ships real abbreviations for a handful of zones, and never for all
// of them in one locale ("CET" needs en-GB, "EST" needs en-US, "PKT" exists
// nowhere). So: ask both locales, and where neither has one, take the long
// name's initials — "Pakistan Standard Time" → PST — listing the few whose
// real-world abbreviation isn't its initials.
const ABBR = {
  'Pakistan Standard Time': 'PKT',
  'Moscow Standard Time': 'MSK',
  'Singapore Standard Time': 'SGT',
  'Hong Kong Standard Time': 'HKT',
  'Indochina Time': 'ICT',
  'Western Indonesia Time': 'WIB',
  'Central Indonesia Time': 'WITA',
  'Eastern Indonesia Time': 'WIT',
  'Brasilia Standard Time': 'BRT',
  'Argentina Standard Time': 'ART',
  'Amazon Standard Time': 'AMT',
  'Nepal Time': 'NPT',
  'Afghanistan Time': 'AFT',
  'Turkmenistan Standard Time': 'TMT',
  'Kazakhstan Time': 'ALMT',
};

const isOffset = (s) => !s || /^(GMT|UTC)/.test(s);

// "CEST", "PKT", "EDT" — falls back to the offset for zones with no name of
// their own ("GMT+05:45").
export function abbrOf(tz, date) {
  for (const locale of ['en-GB', 'en-US']) {
    const short = zoneName(tz, 'short', date, locale);
    if (!isOffset(short)) return short;
  }
  const long = zoneName(tz, 'long', date);
  if (isOffset(long)) return shortOffset(tz, date);
  return ABBR[long] || long.split(/\s+/).map((w) => w[0]).join('').toUpperCase();
}

// "Europe/Amsterdam" → "Amsterdam" / "Europe"
export const cityOf = (tz) => tz.split('/').pop().replace(/_/g, ' ');
export const regionOf = (tz) => tz.split('/').slice(0, -1).join(' / ').replace(/_/g, ' ');

// Zone id + city + both seasons' abbreviations + offset, so "EST" finds New
// York in July and "new york" finds it despite the underscore in the id. ~90ms
// for the whole tz database, built once on the first search.
let INDEX = null;
const searchIndex = () => (INDEX ||= ZONES.map((tz) => {
  const winter = abbrOf(tz, new Date(Date.UTC(new Date().getUTCFullYear(), 0, 15))).toLowerCase();
  const summer = abbrOf(tz, new Date(Date.UTC(new Date().getUTCFullYear(), 6, 1))).toLowerCase();
  return {
    tz,
    abbrs: [winter, summer],
    hay: `${tz} ${cityOf(tz)} ${winter} ${summer} ${shortOffset(tz)}`.toLowerCase(),
  };
}));

// ponytail: cap the rendered list; refine by typing.
export function searchZones(query, limit = 60) {
  const q = query.trim().toLowerCase();
  if (!q) return ZONES.slice(0, limit);
  // An abbreviation typed in full wins over a substring hit elsewhere
  // ("EST" → New York before Budapest, which merely contains "est").
  const hits = searchIndex().filter((e) => e.hay.includes(q));
  hits.sort((a, b) => (b.abbrs.includes(q) ? 1 : 0) - (a.abbrs.includes(q) ? 1 : 0));
  return hits.slice(0, limit).map((e) => e.tz);
}

// Wall clock in `tz` at an instant, as numbers.
export function wallParts(tz, date) {
  const p = new Intl.DateTimeFormat('en-US', {
    timeZone: tz, hourCycle: 'h23',
    year: 'numeric', month: '2-digit', day: '2-digit', hour: '2-digit', minute: '2-digit',
  }).formatToParts(date);
  const g = (t) => +p.find((x) => x.type === t).value;
  return { year: g('year'), month: g('month'), day: g('day'), hour: g('hour') % 24, minute: g('minute') };
}

// Minutes east of UTC for `tz` at `date`.
export function offsetMinutes(tz, date) {
  const w = wallParts(tz, date);
  const asUtc = Date.UTC(w.year, w.month - 1, w.day, w.hour, w.minute);
  return Math.round((asUtc - Math.floor(date.getTime() / 60000) * 60000) / 60000);
}

// The instant at which `tz`'s wall clock reads y-m-d h:00. Two passes so a day
// that starts on the far side of a DST change still lands on the right hour.
export function wallToInstant(tz, y, m, d, h) {
  const guess = Date.UTC(y, m - 1, d, h);
  let ts = guess - offsetMinutes(tz, new Date(guess)) * 60000;
  ts = guess - offsetMinutes(tz, new Date(ts)) * 60000;
  return new Date(ts);
}
