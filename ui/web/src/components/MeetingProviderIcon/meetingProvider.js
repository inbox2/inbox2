// Real-brand meeting-provider detection + logo markup. `detectMeetingProvider`
// scans the free-text fields an invite/event carries (location/description/
// summary/url) for a known conferencing host — the URL almost always lands in
// one of them. Glyphs are the actual official brand logos (multicolour SVG),
// stored as markup strings so the exact same source renders in React
// (MeetingProviderIcon) AND in FullCalendar's plain-DOM eventDidMount hook.

// host substring → provider key. First match wins.
const HOSTS = [
  ['zoom.us', 'zoom'],
  ['zoom.com', 'zoom'],
  ['teams.microsoft.com', 'teams'],
  ['teams.live.com', 'teams'],
  ['meet.google.com', 'meet'],
  ['webex.com', 'webex'],
]

// key → { label, w, h (native aspect), viewBox, svg (inner markup) }.
// Official brand logos — do not redraw as generic glyphs.
const GLYPHS = {
  // Zoom — blue app tile + white camera (the real brand mark).
  zoom: {
    label: 'Zoom',
    w: 24, h: 24, viewBox: '0 0 24 24',
    svg: '<rect width="24" height="24" rx="5.4" fill="#2D8CFF"/><path fill="#fff" d="M5.5 9.6c0-.83.67-1.5 1.5-1.5h5.3c.83 0 1.5.67 1.5 1.5v4.8c0 .83-.67 1.5-1.5 1.5H7c-.83 0-1.5-.67-1.5-1.5V9.6zm9.4 1.05 2.85-2.08c.33-.24.75-.01.75.36v6.14c0 .37-.42.6-.75.36l-2.85-2.08z"/>',
  },
  // Google Meet — the official multicolour camera.
  meet: {
    label: 'Google Meet',
    w: 87.5, h: 72, viewBox: '0 0 87.5 72',
    svg: '<path fill="#00832d" d="M49.5 36l8.53 9.75 11.47 7.33 2-17.02-2-16.64-11.69 6.44z"/><path fill="#0066da" d="M0 51.5V66c0 3.315 2.685 6 6 6h14.5l3-10.96-3-9.54-9.95-3z"/><path fill="#e94235" d="M20.5 0L0 20.5l10.55 3 9.95-3 2.95-9.41z"/><path fill="#2684fc" d="M20.5 20.5H0v31h20.5z"/><path fill="#00ac47" d="M82.6 8.68L69.5 19.42v33.66l13.16 10.79c1.97 1.54 4.85.135 4.85-2.37V11.01c0-2.535-2.945-3.925-4.91-2.33z"/><path fill="#00ac47" d="M49.5 36v15.5h-29V72h43c3.315 0 6-2.685 6-6V53.08z"/><path fill="#ffba00" d="M63.5 0h-43v20.5h29V36l20-16.57V6c0-3.315-2.685-6-6-6z"/>',
  },
  // Microsoft Teams — two purple figures + the purple "T" tile.
  teams: {
    label: 'Microsoft Teams',
    w: 24, h: 24, viewBox: '0 0 24 24',
    svg: '<path fill="#5059c9" d="M14.5 9.5h7.2c.44 0 .8.36.8.8v6.06a3.6 3.6 0 1 1-7.2 0V9.5z"/><circle fill="#5059c9" cx="18.6" cy="5.6" r="2.3"/><circle fill="#7b83eb" cx="11.2" cy="4.8" r="3.1"/><path fill="#7b83eb" d="M14.9 9.5H7.5a1 1 0 0 0-1 1v6.2a4.35 4.35 0 0 0 4.35 4.35h.7a4.35 4.35 0 0 0 4.35-4.35V10.5a1 1 0 0 0-1-1z"/><rect x="1" y="6" width="11.4" height="11.4" rx="1.4" fill="#4b53bc"/><path fill="#fff" d="M9.4 8.6H4v1.55h1.95v5.2h1.5v-5.2H9.4z"/>',
  },
  // Cisco Webex — the ribbon "W". The official mark is ~50 gradient-masked
  // rects, so it ships as a raster cropped from the brand SVG (same PNG the
  // iOS/Android join buttons use).
  webex: {
    label: 'Webex',
    w: 24, h: 24, viewBox: '0 0 24 24',
    svg: '<image width="24" height="24" href="data:image/png;base64,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"/>',
  },
}

export function detectMeetingProvider(...fields) {
  const hay = fields.filter(Boolean).join(' ').toLowerCase()
  if (!hay) return null
  for (const [host, key] of HOSTS) {
    if (hay.includes(host)) return key
  }
  return null
}

/** Brand name for a provider key — 'Google Meet', 'Zoom', … */
export function providerLabel(provider) {
  return GLYPHS[provider]?.label || null
}

// Any http(s) URL. Stops at whitespace and the characters that end a link in
// prose or in an HTML attribute, so `href="…/j/1"` and `(see …/j/1).` both
// yield the bare URL.
const URL_RE = /https?:\/\/[^\s<>"'`\\]+/gi

/**
 * The first URL in these fields that points at a known conferencing host.
 * Descriptions arrive as HTML, so entity-decode the ampersand — a Zoom link
 * loses its `?pwd=` half otherwise.
 */
export function findMeetingUrl(...fields) {
  const hay = fields.filter(Boolean).join(' ').replace(/&amp;/gi, '&')
  if (!hay) return null
  for (const raw of hay.match(URL_RE) || []) {
    // Sentence punctuation isn't part of the URL; a closing bracket only is if
    // the URL opened one (Teams links carry %7b…%7d, never a literal paren).
    const url = raw.replace(/[.,;:!?)\]}>]+$/, '')
    if (detectMeetingProvider(url)) return url
  }
  return null
}

/**
 * The one call every Join button makes: given an event (either shape — the API's
 * or the local SQLite row's), where do I click to get into this meeting?
 *
 * A structured link from the provider wins: Google's `conferenceData` and
 * Microsoft's `onlineMeeting` are recorded by the calendar itself, so they
 * survive a body that a forwarding mail client has mangled. Everything else —
 * an emailed ICS, an MX event, a Zoom link someone pasted into the description —
 * falls back to scanning the free text, which is where those always put it.
 *
 * Returns null when the event has no way in (a lunch, a room booking).
 */
export function detectMeeting(event) {
  if (!event) return null
  const conf = event.conference || event.metadata?.conference
  const url = conf?.url || findMeetingUrl(event.location, event.description, event.title || event.summary, event.url)
  if (!url) return null
  const provider = detectMeetingProvider(url)
  return {
    url,
    provider,
    // The provider's own name for it beats ours — a Zoom add-on inside Google
    // Calendar says "Zoom Meeting", and an unknown host has no glyph at all.
    label: providerLabel(provider) || conf?.label || 'meeting',
    code: conf?.code || null,
  }
}

// Full <svg> markup string — used directly by FullCalendar's DOM eventDidMount.
// `size` is the target height; width follows the logo's native aspect ratio.
export function meetingProviderSvg(provider, size = 22) {
  const g = GLYPHS[provider]
  if (!g) return ''
  const w = Math.round(size * (g.w / g.h))
  return `<svg width="${w}" height="${size}" viewBox="${g.viewBox}" role="img" aria-label="${g.label}">${g.svg}</svg>`
}
