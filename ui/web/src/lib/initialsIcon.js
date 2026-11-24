// Deterministic "initials avatar" rendered as an SVG data-URI, so it can be
// dropped anywhere an image URL is expected (e.g. the workspace-tab <img>).
// Used as the default square icon for an MX domain that hasn't set a custom one
// — replacing the generic inbox2 cube with the domain's own monogram.
//
// Palette mirrors the Avatar component so a domain reads consistently across the
// app (tab, account switcher, admin).

const COLORS = [
  { bg: '#5E4AE3', fg: '#E8E0FF' },
  { bg: '#E0544E', fg: '#FFE0DE' },
  { bg: '#2D9CDB', fg: '#D6EFFF' },
  { bg: '#27AE60', fg: '#D4F5E2' },
  { bg: '#E67E22', fg: '#FDE8D0' },
  { bg: '#E84393', fg: '#FDDDEF' },
  { bg: '#00B894', fg: '#CCF5EA' },
  { bg: '#6C5CE7', fg: '#E4E0FA' },
];

function hashCode(str) {
  let hash = 0;
  for (let i = 0; i < str.length; i++) {
    hash = str.charCodeAt(i) + ((hash << 5) - hash);
  }
  return Math.abs(hash);
}

// A trailing label short enough to be a TLD ("com", "co", "uk", "email").
const TLD = /^[a-z]{2,6}$/i;

/**
 * Monogram for a domain, address or display name.
 *
 * Domains take the registrable label and ignore the TLD: "brightfold.com" → "BR".
 * Taking the first letter of each of the first two tokens (the old behaviour)
 * read the TLD as a word, giving "BC" — and every domain on the same TLD then
 * shared its second letter. It went unnoticed because "acme.com" → "AC" happens
 * to look correct: the C comes from "com".
 *
 *   brightfold.com        → BR      sam@brightfold.com → BR
 *   acme.com              → AC      widgets.co         → WI
 *   mail.brightfold.co.uk → BR      Acme Corp          → AC
 *   new-business          → NB      support            → SU
 */
export function monogram(name) {
  const raw = String(name || '').trim();
  if (!raw) return '?';

  // Not a hostname — a person/org name or a bare mailbox. Two-token initials.
  if (/\s/.test(raw) || !/[.@]/.test(raw)) {
    const parts = raw.split(/[\s._-]+/).filter(Boolean);
    if (parts.length >= 2) return (parts[0][0] + parts[1][0]).toUpperCase();
    return (parts[0] || raw).slice(0, 2).toUpperCase();
  }

  // Hostname (or address): drop the local part, then peel TLD-ish labels off the
  // end — never the last one, or "acme.com" would be left with nothing.
  const host = raw.includes('@') ? raw.slice(raw.lastIndexOf('@') + 1) : raw;
  const labels = host.split('.').filter(Boolean);
  while (labels.length > 1 && TLD.test(labels[labels.length - 1])) labels.pop();
  return (labels[labels.length - 1] || host).slice(0, 2).toUpperCase();
}

export function initialsColor(name) {
  return COLORS[hashCode(String(name || '')) % COLORS.length];
}

/**
 * A rounded-square initials tile as an SVG data-URI.
 * @param {string} name — domain or display name (drives the monogram + color).
 * @param {object} [opts]
 * @param {number} [opts.radius=7] — corner radius on the 32×32 viewbox.
 */
export function initialsDataUri(name, { radius = 7, ring = true } = {}) {
  const { bg, fg } = initialsColor(name);
  const text = monogram(name);
  // The gradient ring is the brand's own device (it's what makes the app icon
  // recognisable), so an MX domain reads as inbox2-hosted at a glance while the
  // monogram + hashed colour still tell one domain from another. Without it a
  // domain tab is just a coloured square — indistinguishable from a contact
  // avatar or a local channel that happens to have a custom icon.
  //
  // The gradient id is scoped per-document: each data-URI is its own SVG
  // document inside an <img>, so repeating "r" across tabs can't collide.
  const ringDefs = ring
    ? `<defs><linearGradient id="r" x1="0" y1="0" x2="1" y2="1">` +
      `<stop offset="0" stop-color="#8B7BF0"/>` +
      `<stop offset=".35" stop-color="#E84393"/>` +
      `<stop offset=".7" stop-color="#F5A623"/>` +
      `<stop offset="1" stop-color="#5E4AE3"/>` +
      `</linearGradient></defs>` +
      `<rect x="1" y="1" width="30" height="30" rx="${radius + 1}" fill="none" ` +
      `stroke="url(#r)" stroke-width="2"/>`
    : '';
  // Inset the tile inside the ring so the stroke reads as a border, not a halo.
  const i = ring ? 3.2 : 0;
  const size = 32 - i * 2;
  const svg =
    `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 32 32">` +
    ringDefs +
    `<rect x="${i}" y="${i}" width="${size}" height="${size}" rx="${radius}" fill="${bg}"/>` +
    `<text x="16" y="16" dy="0.35em" text-anchor="middle" ` +
    `font-family="-apple-system,BlinkMacSystemFont,'Segoe UI',Roboto,sans-serif" ` +
    `font-size="${ring ? 12 : 14}" font-weight="700" fill="${fg}">${text}</text>` +
    `</svg>`;
  return `data:image/svg+xml,${encodeURIComponent(svg)}`;
}

/** A domain's icon: its own, else the org's for the org's main domain, else initials. */
export function domainIconUrl(dom, org, fallbackName) {
  const isPrimary = dom?.name && dom.name === org?.domain;
  return dom?.icon_url
    || (isPrimary && org.icon_url ? org.icon_url : initialsDataUri(dom?.name || org?.name || fallbackName || ''));
}
