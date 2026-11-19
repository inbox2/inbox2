// SF Symbols icon component — spec F3.1–F3.3
// Semi-filled duotone rendering: bold strokes + atmospheric fill
// Designed for premium operational desktop presence
//
// Parent <svg> sets default stroke attributes — children inherit.
// Add fill="currentColor" fillOpacity={n} for duotone fill layers.
// Add stroke="none" for pure-fill elements (dots, solid shapes).

import styles from './Icon.module.css'

const ICONS = {
  // ── Navigation / Containers ─────────────────────────────

  // Pinned chat (WhatsApp's chat list pin).
  'pin.fill': (
    <>
      <path d="M9 10.76a2 2 0 0 1-1.11 1.79l-1.78.9A2 2 0 0 0 5 15.24V16a1 1 0 0 0 1 1h12a1 1 0 0 0 1-1v-.76a2 2 0 0 0-1.11-1.79l-1.78-.9A2 2 0 0 1 15 10.76V7a1 1 0 0 1 1-1 2 2 0 0 0 0-4H8a2 2 0 0 0 0 4 1 1 0 0 1 1 1z" fill="currentColor" fillOpacity="0.3" />
      <path d="M12 17v5" />
    </>
  ),

  'tray.fill': (
    <path d="M2 13h4.764a2 2 0 0 1 1.789 1.106l.447.894A2 2 0 0 0 10.789 16h2.422a2 2 0 0 0 1.789-1.106l.447-.894A2 2 0 0 1 17.236 13H22v4a2 2 0 0 1-2 2H4a2 2 0 0 1-2-2v-4zM2 13V6a2 2 0 0 1 2-2h16a2 2 0 0 1 2 2v7" fill="currentColor" fillOpacity="0.2" />
  ),

  'tray': (
    <path d="M2 13h4.764a2 2 0 0 1 1.789 1.106l.447.894A2 2 0 0 0 10.789 16h2.422a2 2 0 0 0 1.789-1.106l.447-.894A2 2 0 0 1 17.236 13H22v4a2 2 0 0 1-2 2H4a2 2 0 0 1-2-2v-4zM2 13V6a2 2 0 0 1 2-2h16a2 2 0 0 1 2 2v7" fill="currentColor" fillOpacity="0.08" />
  ),

  'tray.full': (
    <>
      <path d="M2 13h4.764a2 2 0 0 1 1.789 1.106l.447.894A2 2 0 0 0 10.789 16h2.422a2 2 0 0 0 1.789-1.106l.447-.894A2 2 0 0 1 17.236 13H22v4a2 2 0 0 1-2 2H4a2 2 0 0 1-2-2v-4zM2 13V6a2 2 0 0 1 2-2h16a2 2 0 0 1 2 2v7" fill="currentColor" fillOpacity="0.12" />
      <path d="M8 8h8M8 11h5" />
    </>
  ),

  'tray.and.arrow.down': (
    <>
      <path d="M3 14h4.5a2 2 0 0 1 1.8 1.1l.4.9a2 2 0 0 0 1.8 1h1a2 2 0 0 0 1.8-1l.4-.9a2 2 0 0 1 1.8-1.1H21v3a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2v-3z" fill="currentColor" fillOpacity="0.12" />
      <path d="M12 3v7m0 0l-2.5-2.5M12 10l2.5-2.5" />
    </>
  ),

  'tray.2.fill': (
    <>
      <rect x="3" y="4" width="18" height="7" rx="1.5" fill="currentColor" fillOpacity="0.2" />
      <rect x="3" y="13" width="18" height="7" rx="1.5" fill="currentColor" fillOpacity="0.2" />
    </>
  ),

  'externaldrive': (
    <>
      <path d="M5.5 5h13l3 8.5V17a2 2 0 0 1-2 2h-15a2 2 0 0 1-2-2v-3.500z" fill="currentColor" fillOpacity="0.12" />
      <path d="M2.5 13.500h19M17.500 16.250h.01" />
    </>
  ),

  'folder': (
    <path d="M22 19a2 2 0 0 1-2 2H4a2 2 0 0 1-2-2V5a2 2 0 0 1 2-2h5l2 3h9a2 2 0 0 1 2 2z" fill="currentColor" fillOpacity="0.12" />
  ),

  'archivebox.fill': (
    <>
      <rect x="3" y="3" width="18" height="4" rx="1" fill="currentColor" fillOpacity="0.25" />
      <path d="M4 7v11a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2V7" fill="currentColor" fillOpacity="0.15" />
      <path d="M10 12h4" />
    </>
  ),

  'archivebox': (
    <>
      <rect x="3" y="3" width="18" height="4" rx="1" fill="currentColor" fillOpacity="0.12" />
      <path d="M4 7v11a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2V7" fill="currentColor" fillOpacity="0.06" />
      <path d="M10 12h4" />
    </>
  ),

  // ── People ──────────────────────────────────────────────

  'person.fill': (
    <>
      <circle cx="12" cy="8" r="4" fill="currentColor" fillOpacity="0.25" />
      <path d="M5 20c0-3.314 3.134-6 7-6s7 2.686 7 6" fill="currentColor" fillOpacity="0.15" />
    </>
  ),

  'person': (
    <>
      <circle cx="12" cy="8" r="4" fill="currentColor" fillOpacity="0.08" />
      <path d="M5 20c0-3.314 3.134-6 7-6s7 2.686 7 6" />
    </>
  ),

  'person.2': (
    <>
      <circle cx="9" cy="7" r="3.5" fill="currentColor" fillOpacity="0.15" />
      <path d="M2 20c0-3 2.5-5.5 7-5.5s7 2.5 7 5.5" fill="currentColor" fillOpacity="0.1" />
      <circle cx="17" cy="8" r="2.5" fill="currentColor" fillOpacity="0.1" />
      <path d="M19 14.5c2.5.5 4 2 4 4" />
    </>
  ),

  'person.badge.plus': (
    <>
      <circle cx="9" cy="7" r="4" fill="currentColor" fillOpacity="0.2" />
      <path d="M2 21v-2a4 4 0 0 1 4-4h6a4 4 0 0 1 4 4v2" fill="currentColor" fillOpacity="0.12" />
      <path d="M19 8v6M22 11h-6" />
    </>
  ),

  'person.slash': (
    <>
      <circle cx="12" cy="8" r="4" fill="currentColor" fillOpacity="0.12" />
      <path d="M5 20c0-3.314 3.134-6 7-6s7 2.686 7 6" fill="currentColor" fillOpacity="0.08" />
      <path d="M4 4l16 16" />
    </>
  ),

  // ── Communication ───────────────────────────────────────

  'bubble.left.fill': (
    <path d="M21 12a9 9 0 1 1-3.14-6.84L21 3v9z" fill="currentColor" fillOpacity="0.2" />
  ),

  'paperplane.fill': (
    <path d="M3 3l18 9-18 9V14l12-2-12-2V3z" fill="currentColor" fillOpacity="0.15" />
  ),

  'paperplane': (
    <path d="M3 3l18 9-18 9V14l12-2-12-2V3z" fill="currentColor" fillOpacity="0.06" />
  ),

  'bell': (
    <path d="M18 8A6 6 0 0 0 6 8c0 7-3 9-3 9h18s-3-2-3-9zM13.73 21a2 2 0 0 1-3.46 0" fill="currentColor" fillOpacity="0.12" />
  ),

  // ── Documents ───────────────────────────────────────────

  'doc.text.fill': (
    <>
      <path d="M14 2H6a2 2 0 0 0-2 2v16a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2V8l-6-6z" fill="currentColor" fillOpacity="0.2" />
      <path d="M14 2v6h6M8 13h8M8 17h5" />
    </>
  ),

  'doc': (
    <>
      <path d="M14 2H6a2 2 0 0 0-2 2v16a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2V8l-6-6z" fill="currentColor" fillOpacity="0.08" />
      <path d="M14 2v6h6" />
    </>
  ),

  'note.text': (
    <>
      <path d="M16 2H4a2 2 0 0 0-2 2v16l4-4h10a2 2 0 0 0 2-2V4a2 2 0 0 0-2-2z" fill="currentColor" fillOpacity="0.12" />
      <path d="M6 8h8M6 12h5" />
    </>
  ),

  // ── Circles / Status ────────────────────────────────────

  'plus': (
    <path d="M12 5v14M5 12h14" />
  ),

  'plus.circle': (
    <>
      <circle cx="12" cy="12" r="9" fill="currentColor" fillOpacity="0.12" />
      <path d="M12 8v8M8 12h8" />
    </>
  ),

  'at.badge.plus': (
    <>
      <circle cx="12" cy="12" r="9" fill="currentColor" fillOpacity="0.12" />
      <path d="M12 8v8M8 12h8" />
    </>
  ),

  'nosign': (
    <>
      <circle cx="12" cy="12" r="9" fill="currentColor" fillOpacity="0.1" />
      <path d="M5.7 5.7l12.6 12.6" />
    </>
  ),

  'dollarsign.circle.fill': (
    <>
      <circle cx="12" cy="12" r="9" fill="currentColor" fillOpacity="0.2" />
      <path d="M12 6v12M9 9.5a2.5 2 0 0 1 2.5-2h1a2.5 2 0 0 1 0 4h-1a2.5 2 0 0 0 0 4h1a2.5 2 0 0 0 2.5-2" />
    </>
  ),

  'arrow.up.circle.fill': (
    <>
      <circle cx="12" cy="12" r="9" fill="currentColor" fillOpacity="0.2" />
      <path d="M12 16V8M8 12l4-4 4 4" />
    </>
  ),

  'magnifyingglass': (
    <>
      <circle cx="11" cy="11" r="7" fill="currentColor" fillOpacity="0.06" />
      <path d="M21 21l-4.35-4.35" />
    </>
  ),

  // ── Actions / Compose ───────────────────────────────────

  'square.and.pencil': (
    <>
      <path d="M12 20h9" />
      <path d="M16.5 3.5a2.121 2.121 0 0 1 3 3L7 19l-4 1 1-4L16.5 3.5z" fill="currentColor" fillOpacity="0.08" />
    </>
  ),

  'pencil': (
    <path d="M16.5 3.5a2.121 2.121 0 0 1 3 3L7 19l-4 1 1-4L16.5 3.5z" fill="currentColor" fillOpacity="0.08" />
  ),

  'compose': (
    <>
      <path d="M12 20h9" />
      <path d="M16.5 3.5a2.121 2.121 0 0 1 3 3L7 19l-4 1 1-4L16.5 3.5z" fill="currentColor" fillOpacity="0.08" />
    </>
  ),

  // ── Reply / Forward ─────────────────────────────────────

  'arrowshape.turn.up.left': (
    <path d="M10 9V5l-7 7 7 7v-4.1c5 0 8.5 1.6 11 5.1-1-5-4-10-11-11z" fill="currentColor" fillOpacity="0.08" />
  ),

  'arrowshape.turn.up.left.fill': (
    <path d="M10 9V5l-7 7 7 7v-4.1c5 0 8.5 1.6 11 5.1-1-5-4-10-11-11z" fill="currentColor" fillOpacity="0.2" />
  ),

  'arrowshape.turn.up.left.2': (
    <>
      <path d="M10 9V5l-7 7 7 7v-4.1c5 0 8.5 1.6 11 5.1-1-5-4-10-11-11z" fill="currentColor" fillOpacity="0.08" />
      <path d="M14 9V5" opacity="0.5" />
    </>
  ),

  'arrowshape.turn.up.right': (
    <path d="M14 9V5l7 7-7 7v-4.1c-5 0-8.5 1.6-11 5.1 1-5 4-10 11-11z" fill="currentColor" fillOpacity="0.08" />
  ),

  // ── Labels / Tags ───────────────────────────────────────

  'tag.fill': (
    <>
      <path d="M20.59 13.41l-7.17 7.17a2 2 0 0 1-2.83 0L2 12V2h10l8.59 8.59a2 2 0 0 1 0 2.82z" fill="currentColor" fillOpacity="0.2" />
      <circle cx="7" cy="7" r="1.5" fill="currentColor" stroke="none" />
    </>
  ),

  'tag': (
    <>
      <path d="M20.59 13.41l-7.17 7.17a2 2 0 0 1-2.83 0L2 12V2h10l8.59 8.59a2 2 0 0 1 0 2.82z" fill="currentColor" fillOpacity="0.08" />
      <circle cx="7" cy="7" r="1.5" fill="currentColor" stroke="none" />
    </>
  ),

  'tag.slash': (
    <>
      <path d="M20.59 13.41l-7.17 7.17a2 2 0 0 1-2.83 0L2 12V2h10l8.59 8.59a2 2 0 0 1 0 2.82z" fill="currentColor" fillOpacity="0.08" />
      <circle cx="7" cy="7" r="1.5" fill="currentColor" stroke="none" />
      <line x1="3" y1="21" x2="21" y2="3" strokeWidth="2" strokeLinecap="round" />
    </>
  ),

  // ── Trash / Delete ──────────────────────────────────────

  'trash': (
    <>
      <path d="M5 6v14a2 2 0 0 0 2 2h10a2 2 0 0 0 2-2V6" fill="currentColor" fillOpacity="0.1" />
      <path d="M3 6h18M8 6V4a1 1 0 0 1 1-1h6a1 1 0 0 1 1 1v2" />
      <path d="M10 11v6M14 11v6" />
    </>
  ),

  'trash.fill': (
    <>
      <path d="M5 6v14a2 2 0 0 0 2 2h10a2 2 0 0 0 2-2V6" fill="currentColor" fillOpacity="0.25" />
      <path d="M3 6h18M8 6V4a1 1 0 0 1 1-1h6a1 1 0 0 1 1 1v2" />
      <path d="M10 11v6M14 11v6" />
    </>
  ),

  'xmark.bin.fill': (
    <>
      <path d="M5 6v14a2 2 0 0 0 2 2h10a2 2 0 0 0 2-2V6" fill="currentColor" fillOpacity="0.2" />
      <path d="M3 6h18M8 6V4a1 1 0 0 1 1-1h6a1 1 0 0 1 1 1v2" />
    </>
  ),

  // ── Utilities ───────────────────────────────────────────

  'paperclip': (
    <path d="M21.44 11.05l-9.19 9.19a6 6 0 0 1-8.49-8.49l9.19-9.19a4 4 0 0 1 5.66 5.66l-9.2 9.19a2 2 0 0 1-2.83-2.83l8.49-8.48" />
  ),

  'wrench.fill': (
    <path d="M14.7 6.3a1 1 0 0 0 0 1.4l1.6 1.6a1 1 0 0 0 1.4 0l3.77-3.77a6 6 0 0 1-7.94 7.94l-6.91 6.91a2.12 2.12 0 0 1-3-3l6.91-6.91a6 6 0 0 1 7.94-7.94l-3.76 3.76z" fill="currentColor" fillOpacity="0.15" />
  ),

  'handshake.fill': (
    <>
      <path d="M7 11l-4-4 4-4" />
      <path d="M17 11l4-4-4-4" />
      <path d="M3 7h8l2 7M21 7h-8l-2 7" />
    </>
  ),

  'gear': (
    <path d="M12 15a3 3 0 1 0 0-6 3 3 0 0 0 0 6zM19.4 15a1.65 1.65 0 0 0 .33 1.82l.06.06a2 2 0 1 1-2.83 2.83l-.06-.06a1.65 1.65 0 0 0-1.82-.33 1.65 1.65 0 0 0-1 1.51V21a2 2 0 0 1-4 0v-.09A1.65 1.65 0 0 0 9 19.4a1.65 1.65 0 0 0-1.82.33l-.06.06a2 2 0 1 1-2.83-2.83l.06-.06A1.65 1.65 0 0 0 4.68 15a1.65 1.65 0 0 0-1.51-1H3a2 2 0 0 1 0-4h.09A1.65 1.65 0 0 0 4.6 9a1.65 1.65 0 0 0-.33-1.82l-.06-.06a2 2 0 1 1 2.83-2.83l.06.06A1.65 1.65 0 0 0 9 4.68a1.65 1.65 0 0 0 1-1.51V3a2 2 0 0 1 4 0v.09a1.65 1.65 0 0 0 1 1.51 1.65 1.65 0 0 0 1.82-.33l.06-.06a2 2 0 1 1 2.83 2.83l-.06.06A1.65 1.65 0 0 0 19.4 9a1.65 1.65 0 0 0 1.51 1H21a2 2 0 0 1 0 4h-.09a1.65 1.65 0 0 0-1.51 1z" fill="currentColor" fillOpacity="0.1" />
  ),

  // ── Calendar ────────────────────────────────────────────

  'calendar': (
    <>
      <rect x="3" y="4" width="18" height="18" rx="2" fill="currentColor" fillOpacity="0.1" />
      <path d="M16 2v4M8 2v4M3 10h18" />
    </>
  ),

  // ── Chrome tab glyphs (house set — unique per surface, same duotone
  //    stroke language as the SF-style icons above) ─────────────────

  // Triage / Spaces: the treemap board — one dominant cell + two nested cells.
  'square.treemap': (
    <>
      <rect x="3" y="3" width="10" height="18" rx="2" fill="currentColor" fillOpacity="0.18" />
      <rect x="16" y="3" width="5" height="9" rx="1.5" fill="currentColor" fillOpacity="0.1" />
      <rect x="16" y="15" width="5" height="6" rx="1.5" fill="currentColor" fillOpacity="0.28" />
    </>
  ),

  // Calendar tab: month sheet with binder pins, agenda lines and a "today" dot.
  'calendar.today': (
    <>
      <rect x="3" y="4" width="18" height="17" rx="2" fill="currentColor" fillOpacity="0.08" />
      <path d="M16 2v4M8 2v4M3 9.5h18" />
      <circle cx="15.5" cy="15.5" r="2.4" fill="currentColor" stroke="none" />
      <path d="M7 14.5h3.5M7 18.5h5" strokeWidth="1.5" strokeOpacity="0.5" />
    </>
  ),

  // Explorer: the force-graph — a hub node with four satellites.
  'point.connected': (
    <>
      <path d="M9.8 9.9L6.6 6.3M14.3 10.4L17.4 8.1M13.7 14.5L16.1 17.6M9.5 13.9L6.4 16.3" strokeWidth="1.5" strokeOpacity="0.55" />
      <circle cx="12" cy="12" r="3" fill="currentColor" fillOpacity="0.25" />
      <circle cx="5.2" cy="4.8" r="2.2" fill="currentColor" fillOpacity="0.12" />
      <circle cx="19.2" cy="6.8" r="2.4" fill="currentColor" fillOpacity="0.12" />
      <circle cx="17.6" cy="19.2" r="2.2" fill="currentColor" fillOpacity="0.12" />
      <circle cx="4.6" cy="17.8" r="2.4" fill="currentColor" fillOpacity="0.12" />
    </>
  ),

  // ── Theme ───────────────────────────────────────────────

  'sun.max.fill': (
    <>
      <circle cx="12" cy="12" r="4" fill="currentColor" fillOpacity="0.25" />
      <path d="M12 2v2M12 20v2M4.93 4.93l1.41 1.41M17.66 17.66l1.41 1.41M2 12h2M20 12h2M4.93 19.07l1.41-1.41M17.66 6.34l1.41-1.41" />
    </>
  ),

  'sun': (
    <>
      <circle cx="12" cy="12" r="4" fill="currentColor" fillOpacity="0.1" />
      <path d="M12 2v2M12 20v2M4.93 4.93l1.41 1.41M17.66 17.66l1.41 1.41M2 12h2M20 12h2M4.93 19.07l1.41-1.41M17.66 6.34l1.41-1.41" />
    </>
  ),

  'moon.fill': (
    <path d="M21 12.79A9 9 0 1 1 11.21 3 7 7 0 0 0 21 12.79z" fill="currentColor" fillOpacity="0.2" />
  ),

  // ── Weather (Touch Strip) ─────────────────────────────

  'cloud': (
    <path d="M7 18h10a4 4 0 0 0 .6-7.96A5.5 5.5 0 0 0 7 11a3.5 3.5 0 0 0 0 7z" fill="currentColor" fillOpacity="0.1" />
  ),

  'cloud.sun': (
    <>
      <path d="M8 3v1.5M3.2 5.2l1 1M2 10h1.5M12.8 5.2l-1 1" />
      <path d="M5.3 11.2A3.5 3.5 0 0 1 11.3 7.6" />
      <path d="M9 20h8a3.5 3.5 0 0 0 .5-6.96A5 5 0 0 0 8.6 13.5 3.25 3.25 0 0 0 9 20z" fill="currentColor" fillOpacity="0.12" />
    </>
  ),

  'cloud.rain': (
    <>
      <path d="M7 15h10a3.5 3.5 0 0 0 .5-6.96A5 5 0 0 0 7.6 8.5 3.25 3.25 0 0 0 7 15z" fill="currentColor" fillOpacity="0.12" />
      <path d="M8 18l-1 3M12 18l-1 3M16 18l-1 3" />
    </>
  ),

  'cloud.snow': (
    <>
      <path d="M7 15h10a3.5 3.5 0 0 0 .5-6.96A5 5 0 0 0 7.6 8.5 3.25 3.25 0 0 0 7 15z" fill="currentColor" fillOpacity="0.12" />
      <path d="M8 19h.01M12 19h.01M16 19h.01M10 22h.01M14 22h.01" strokeWidth="2.5" />
    </>
  ),

  'cloud.bolt': (
    <>
      <path d="M7 15h10a3.5 3.5 0 0 0 .5-6.96A5 5 0 0 0 7.6 8.5 3.25 3.25 0 0 0 7 15z" fill="currentColor" fillOpacity="0.12" />
      <path d="M12.5 16l-2 3.5h3l-2 3.5" />
    </>
  ),

  'cloud.fog': (
    <>
      <path d="M7 15h10a3.5 3.5 0 0 0 .5-6.96A5 5 0 0 0 7.6 8.5 3.25 3.25 0 0 0 7 15z" fill="currentColor" fillOpacity="0.12" />
      <path d="M5 18.5h14M7 21.5h10" />
    </>
  ),

  'slider.horizontal.3': (
    <>
      <path d="M3 6h10M17 6h4M3 12h4M11 12h10M3 18h12M19 18h2" />
      <circle cx="15" cy="6" r="2" fill="currentColor" fillOpacity="0.2" />
      <circle cx="9" cy="12" r="2" fill="currentColor" fillOpacity="0.2" />
      <circle cx="17" cy="18" r="2" fill="currentColor" fillOpacity="0.2" />
    </>
  ),

  'location': (
    <path d="M3 11l18-8-8 18-2-8z" fill="currentColor" fillOpacity="0.12" />
  ),

  'newspaper': (
    <>
      <path d="M4 5h13v13a2 2 0 0 0 2 2H6a2 2 0 0 1-2-2z" fill="currentColor" fillOpacity="0.1" />
      <path d="M17 9h3v9a2 2 0 0 1-4 0M7.5 9h6M7.5 13h6M7.5 16h4" />
    </>
  ),

  'moon': (
    <path d="M21 12.79A9 9 0 1 1 11.21 3 7 7 0 0 0 21 12.79z" fill="currentColor" fillOpacity="0.08" />
  ),

  // ── Lists / Filters ─────────────────────────────────────

  'list.bullet.rectangle': (
    <>
      <rect x="3" y="4" width="18" height="16" rx="2" fill="currentColor" fillOpacity="0.1" />
      <path d="M8 9h8M8 13h6M8 17h4" />
      <circle cx="5.5" cy="9" r="1" fill="currentColor" stroke="none" />
      <circle cx="5.5" cy="13" r="1" fill="currentColor" stroke="none" />
      <circle cx="5.5" cy="17" r="1" fill="currentColor" stroke="none" />
    </>
  ),

  'line.3.horizontal': (
    <path d="M4 6h16M4 12h16M4 18h16" />
  ),

  'line.3.horizontal.decrease': (
    <path d="M4 6h16M6 12h12M8 18h8" />
  ),

  // ── Eyes / Visibility ───────────────────────────────────

  'eye': (
    <>
      <path d="M1 12s4-8 11-8 11 8 11 8-4 8-11 8-11-8-11-8z" fill="currentColor" fillOpacity="0.08" />
      <circle cx="12" cy="12" r="3" fill="currentColor" fillOpacity="0.15" />
    </>
  ),

  'eye.slash': (
    <>
      <path d="M1 12s4-8 11-8 11 8 11 8-4 8-11 8-11-8-11-8z" fill="currentColor" fillOpacity="0.08" />
      <circle cx="12" cy="12" r="3" fill="currentColor" fillOpacity="0.15" />
      <line x1="3" y1="21" x2="21" y2="3" />
    </>
  ),

  // ── Branching / Workflow ────────────────────────────────

  'arrow.triangle.branch': (
    <>
      <circle cx="18" cy="6" r="3" fill="currentColor" fillOpacity="0.12" />
      <circle cx="6" cy="18" r="3" fill="currentColor" fillOpacity="0.12" />
      <path d="M6 3v12M18 9c0 4-2 7-6 8-2 .5-4 1-6 1" />
    </>
  ),

  // ── Time / Alerts ───────────────────────────────────────

  'clock': (
    <>
      <circle cx="12" cy="12" r="9" fill="currentColor" fillOpacity="0.1" />
      <path d="M12 6v6l4 2" />
    </>
  ),

  'clock.arrow.circlepath': (
    <>
      <circle cx="12" cy="13" r="8" fill="currentColor" fillOpacity="0.1" />
      <path d="M12 9v4l2.5 1.5" />
      <path d="M21 5v4h-4" />
      <path d="M21 9a9 9 0 1 0-2 6" />
    </>
  ),

  // Calendar zones — a dashed soft block around a focus point.
  'scope': (
    <>
      <rect x="3" y="3" width="18" height="18" rx="5" strokeDasharray="4 3" fill="currentColor" fillOpacity="0.1" />
      <circle cx="12" cy="12" r="3" fill="currentColor" fillOpacity="0.3" />
    </>
  ),

  'timer': (
    <>
      <circle cx="12" cy="13" r="8" fill="currentColor" fillOpacity="0.12" />
      <path d="M12 9v4M10 2h4" />
      <path d="M17.5 6.5l1-1" />
    </>
  ),

  'exclamationmark.triangle': (
    <>
      <path d="M10.29 3.86L1.82 18a2 2 0 0 0 1.71 3h16.94a2 2 0 0 0 1.71-3L13.71 3.86a2 2 0 0 0-3.42 0z" fill="currentColor" fillOpacity="0.15" />
      <path d="M12 9v4" />
      <circle cx="12" cy="17" r="0.5" fill="currentColor" stroke="none" />
    </>
  ),

  'bolt.fill': (
    <path d="M13 2L3 14h9l-1 8 10-12h-9l1-8z" fill="currentColor" fillOpacity="0.2" />
  ),

  'play.fill': (
    <path d="M8 5.5v13l11-6.5z" fill="currentColor" fillOpacity="0.2" />
  ),

  'star.fill': (
    <path d="M12 2l2.4 7.4H22l-6.2 4.5 2.4 7.4L12 16.8 5.8 21.3l2.4-7.4L2 9.4h7.6z" fill="currentColor" fillOpacity="0.2" />
  ),

  'flame.fill': (
    <path d="M12 22c-4.42 0-7-2.69-7-6.76 0-3.01 1.87-5.28 3.38-7.08C9.83 6.48 12 4.13 12 2c0 0 1.23 2.08 1.23 4.2 0 1.64-.93 2.95-1.56 3.62.93-.35 2.33-1.47 2.75-2.82.6 1.56 2.58 4 2.58 6.24C17 19.31 16.42 22 12 22z" fill="currentColor" fillOpacity="0.2" />
  ),

  'calendar.badge.clock': (
    <>
      <rect x="3" y="4" width="18" height="18" rx="2" fill="currentColor" fillOpacity="0.08" />
      <path d="M3 10h18M8 2v4M16 2v4" />
      <circle cx="16" cy="17" r="4" fill="currentColor" fillOpacity="0.15" />
      <path d="M16 15v2l1.5 1" strokeWidth="1.5" />
    </>
  ),

  // ── Editor / Formatting ──────────────────────────────────

  'bold': (
    <path d="M6 4h8a4 4 0 0 1 0 8H6zM6 12h9a4 4 0 0 1 0 8H6z" fill="currentColor" fillOpacity="0.12" />
  ),

  'italic': (
    <path d="M10 4h8M6 20h8M14 4l-4 16" />
  ),

  'underline': (
    <>
      <path d="M6 4v8a6 6 0 0 0 12 0V4" />
      <path d="M4 21h16" />
    </>
  ),

  'strikethrough': (
    <>
      <path d="M16 4c-.5-1.5-2.5-3-5-3-3 0-5 2-5 4 0 1.5.5 2.5 2 3.5" />
      <path d="M4 12h16" />
      <path d="M8 20c.5 1 2.5 2 5 2 3 0 5-1.5 5-3.5 0-1.5-.5-2.5-2-3.5" />
    </>
  ),

  'list.number': (
    <>
      <path d="M10 6h11M10 12h11M10 18h11" />
      <path d="M4 6h1v4M4 10h2M6 18H4c0-1 2-2 2-3s-1-1.5-2-1" />
    </>
  ),

  'list.bullet': (
    <>
      <path d="M10 6h11M10 12h11M10 18h11" />
      <circle cx="4" cy="6" r="1.5" fill="currentColor" stroke="none" />
      <circle cx="4" cy="12" r="1.5" fill="currentColor" stroke="none" />
      <circle cx="4" cy="18" r="1.5" fill="currentColor" stroke="none" />
    </>
  ),

  'link': (
    <>
      <path d="M10 13a5 5 0 0 0 7.54.54l3-3a5 5 0 0 0-7.07-7.07l-1.72 1.71" />
      <path d="M14 11a5 5 0 0 0-7.54-.54l-3 3a5 5 0 0 0 7.07 7.07l1.71-1.71" />
    </>
  ),

  'video': (
    <>
      <rect x="2" y="6" width="13" height="12" rx="2" fill="currentColor" fillOpacity="0.15" />
      <path d="M15 10.5L21 7v10l-6-3.5v-3z" fill="currentColor" fillOpacity="0.2" />
    </>
  ),

  'macwindow': (
    <>
      <rect x="3" y="5" width="18" height="14" rx="2" fill="currentColor" fillOpacity="0.12" />
      <path d="M3 9h18" />
    </>
  ),

  'photo': (
    <>
      <rect x="3" y="3" width="18" height="18" rx="2" fill="currentColor" fillOpacity="0.1" />
      <circle cx="8.5" cy="8.5" r="1.5" fill="currentColor" fillOpacity="0.25" stroke="none" />
      <path d="M21 15l-5-5L5 21" />
    </>
  ),

  'textformat.size': (
    <path d="M4 7V4h16v3M9 20h6M12 4v16" />
  ),

  'minus.circle': (
    <>
      <circle cx="12" cy="12" r="9" fill="currentColor" fillOpacity="0.1" />
      <path d="M8 12h8" />
    </>
  ),

  // ── Window Controls ─────────────────────────────────────

  'xmark': (
    <path d="M18 6L6 18M6 6l12 12" />
  ),

  'minus': (
    <path d="M5 12h14" />
  ),

  // A window with a panel floating over it: the "floating pane" mode. Duotone like
  // its siblings — the stroke-only expand arrows it replaced drew blank in the
  // reading pane's frosted toolbar (macOS webview, 2026-10-20).
  'macwindow.floating': (
    <>
      <rect x="3" y="5" width="18" height="14" rx="2" fill="currentColor" fillOpacity="0.08" />
      <rect x="11" y="10" width="7" height="6" rx="1" fill="currentColor" fillOpacity="0.35" />
    </>
  ),

  'arrow.up.left.and.arrow.down.right': (
    <>
      <path d="M4 14v6h6" />
      <path d="M20 10V4h-6" />
      <path d="M14 10l6-6M10 14l-6 6" />
    </>
  ),

  'checkmark.circle': (
    <>
      <circle cx="12" cy="12" r="9" fill="currentColor" fillOpacity="0.12" />
      <path d="M9 12l2 2 4-4" />
    </>
  ),

  'checkmark.circle.fill': (
    <>
      <circle cx="12" cy="12" r="9" fill="currentColor" fillOpacity="0.25" />
      <path d="M9 12l2 2 4-4" />
    </>
  ),

  'arrow.clockwise': (
    <>
      <path d="M21 4v6h-6" />
      <path d="M3 12a9 9 0 0 1 15-6.7L21 8" />
      <path d="M3 12a9 9 0 0 0 9 9 9 9 0 0 0 9-9" />
    </>
  ),

  'arrow.uturn.backward': (
    <>
      <path d="M9 14l-5-5 5-5" />
      <path d="M4 9h11a5 5 0 0 1 0 10h-3" />
    </>
  ),

  'arrow.triangle.2.circlepath': (
    <>
      <path d="M18.5 7.5A7.5 7.5 0 0 0 5.1 8.5" />
      <polyline points="3 6 5.1 8.5 7.5 6.5" />
      <path d="M5.5 16.5A7.5 7.5 0 0 0 18.9 15.5" />
      <polyline points="21 18 18.9 15.5 16.5 17.5" />
    </>
  ),

  'globe': (
    <>
      <circle cx="12" cy="12" r="9" fill="currentColor" fillOpacity="0.1" />
      <path d="M2 12h20M12 3a15.3 15.3 0 0 1 4 9 15.3 15.3 0 0 1-4 9 15.3 15.3 0 0 1-4-9 15.3 15.3 0 0 1 4-9z" />
    </>
  ),

  // ── Misc ────────────────────────────────────────────────

  'at': (
    <path d="M12 16a4 4 0 1 0 0-8 4 4 0 0 0 0 8zm0 0v1.5a2.5 2.5 0 0 0 5 0V12a9 9 0 1 0-4.29 7.68" />
  ),

  'heart': (
    <path d="M12 21.35l-1.45-1.32C5.4 15.36 2 12.28 2 8.5 2 5.42 4.42 3 7.5 3c1.74 0 3.41.81 4.5 2.09C13.09 3.81 14.76 3 16.5 3 19.58 3 22 5.42 22 8.5c0 3.78-3.4 6.86-8.55 11.54L12 21.35z" />
  ),

  'square.grid.2x2': (
    <>
      <rect x="3" y="3" width="8" height="8" rx="1.5" fill="currentColor" fillOpacity="0.15" />
      <rect x="13" y="3" width="8" height="8" rx="1.5" fill="currentColor" fillOpacity="0.15" />
      <rect x="3" y="13" width="8" height="8" rx="1.5" fill="currentColor" fillOpacity="0.15" />
      <rect x="13" y="13" width="8" height="8" rx="1.5" fill="currentColor" fillOpacity="0.15" />
    </>
  ),

  'creditcard': (
    <>
      <rect x="2.5" y="5" width="19" height="14" rx="2.5" fill="currentColor" fillOpacity="0.1" />
      <path d="M2.5 9.5h19" />
      <path d="M6 15.5h4" />
    </>
  ),

  'circle.grid.cross': (
    <>
      {/* Compass / radar — exploration icon */}
      <circle cx="12" cy="12" r="9" fill="currentColor" fillOpacity="0.08" />
      <circle cx="12" cy="12" r="5" fill="currentColor" fillOpacity="0.06" />
      <circle cx="12" cy="12" r="1.5" fill="currentColor" fillOpacity="0.35" stroke="none" />
      <path d="M12 3v3M12 18v3M3 12h3M18 12h3" strokeOpacity="0.3" strokeWidth="1.5" />
      <path d="M12 8l2 4-2 4-2-4z" fill="currentColor" fillOpacity="0.2" stroke="none" />
    </>
  ),

  'ellipsis': (
    <>
      <circle cx="5" cy="12" r="1.5" fill="currentColor" stroke="none" />
      <circle cx="12" cy="12" r="1.5" fill="currentColor" stroke="none" />
      <circle cx="19" cy="12" r="1.5" fill="currentColor" stroke="none" />
    </>
  ),
  'terminal': (
    <>
      <rect x="3" y="4" width="18" height="16" rx="2" />
      <polyline points="7,9 10,12 7,15" />
      <line x1="13" y1="15" x2="17" y2="15" />
    </>
  ),
  'info.circle': (
    <>
      <circle cx="12" cy="12" r="9" fill="currentColor" fillOpacity="0.12" />
      <line x1="12" y1="11" x2="12" y2="16.5" />
      <circle cx="12" cy="7.75" r="1.05" fill="currentColor" stroke="none" />
    </>
  ),
  'chevron.up.chevron.down': (
    <>
      <polyline points="8,9 12,5 16,9" />
      <polyline points="8,15 12,19 16,15" />
    </>
  ),

  // ── Text / Alignment ────────────────────────────────────

  'text.alignleft': (
    <>
      <path d="M3 6h18M3 10h14M3 14h18M3 18h10" />
    </>
  ),

  // ── AI / Brain ──────────────────────────────────────────

  'brain': (
    <>
      <path d="M12 4.5C10 2.5 7 2.5 5.5 4.5S4 9 5.5 11c1 1.3 1.5 3 1.5 5v1h2v-1c0-2.5-.5-4-2-5.5C6 9 6 7 7 5.5S10 4 12 5.5" fill="currentColor" fillOpacity="0.12" />
      <path d="M12 4.5c2-2 5-2 6.5 0S20 9 18.5 11c-1 1.3-1.5 3-1.5 5v1h-2v-1c0-2.5.5-4 2-5.5C18 9 18 7 17 5.5S14 4 12 5.5" fill="currentColor" fillOpacity="0.12" />
      <path d="M12 5.5v16M9 16h6" />
      <circle cx="12" cy="9" r="2" fill="currentColor" fillOpacity="0.2" stroke="none" />
    </>
  ),

  'cpu': (
    <>
      <rect x="5" y="5" width="14" height="14" rx="2" fill="currentColor" fillOpacity="0.12" />
      <rect x="9" y="9" width="6" height="6" rx="1" fill="currentColor" fillOpacity="0.2" />
      <path d="M9 2v3M15 2v3M9 19v3M15 19v3M2 9h3M2 15h3M19 9h3M19 15h3" />
    </>
  ),

  // ── Chevrons ───────────────────────────────────────────

  'chevron.left': (
    <polyline points="15,6 9,12 15,18" />
  ),

  'chevron.right': (
    <polyline points="9,6 15,12 9,18" />
  ),

  'chevron.down': (
    <polyline points="6,9 12,15 18,9" />
  ),

  'chevron.up': (
    <polyline points="6,15 12,9 18,15" />
  ),

  // ── Arrows ─────────────────────────────────────────────

  'arrow.up': (
    <path d="M12 19V5M5 12l7-7 7 7" />
  ),

  'arrow.up.right': (
    <>
      <path d="M7 17 17 7" />
      <path d="M8 7h9v9" />
    </>
  ),

  'arrow.down': (
    <path d="M12 5v14M19 12l-7 7-7-7" />
  ),

  'arrow.down.circle': (
    <>
      <circle cx="12" cy="12" r="10" />
      <path d="M12 8v8m-3.5-3.5L12 16l3.5-3.5" />
    </>
  ),

  // ── Mail ───────────────────────────────────────────────

  'envelope.open': (
    <>
      <path d="M3 9l9-5 9 5" />
      <path d="M21 9v10a2 2 0 01-2 2H5a2 2 0 01-2-2V9" />
      <path d="M3 9l9 6 9-6" />
    </>
  ),

  'envelope.badge': (
    <>
      <rect x="3" y="6" width="18" height="14" rx="2" fill="currentColor" fillOpacity="0.12" />
      <path d="M3 8l9 6 9-6" />
      <circle cx="18" cy="6" r="3" fill="currentColor" stroke="none" />
    </>
  ),

  // ── Checks ─────────────────────────────────────────────

  'checkmark': (
    <path d="M5 12l5 5L20 7" />
  ),

  'circle.fill': (
    <circle cx="12" cy="12" r="6" fill="currentColor" fillOpacity="0.4" stroke="none" />
  ),

  'rectangle.portrait.and.arrow.right': (
    <>
      <rect x="4" y="3" width="12" height="18" rx="2" fill="currentColor" fillOpacity="0.1" />
      <path d="M15 12h6M18 9l3 3-3 3" />
    </>
  ),

  // ── Agents / Automation ─────────────────────────────────

  'wand.and.stars': (
    <>
      <path d="M5 20L15 10" />
      <path d="M14 8l2-2" />
      <path d="M18 3l.9 2.1L21 6l-2.1.9L18 9l-.9-2.1L15 6l2.1-.9z" fill="currentColor" fillOpacity="0.25" stroke="none" />
      <path d="M6 4l.6 1.4L8 6l-1.4.6L6 8l-.6-1.4L4 6l1.4-.6z" fill="currentColor" fillOpacity="0.2" stroke="none" />
    </>
  ),

  'sparkles': (
    <>
      <path d="M11 5l1.5 5.5L18 12l-5.5 1.5L11 19l-1.5-5.5L4 12l5.5-1.5z" fill="currentColor" fillOpacity="0.2" />
      <path d="M18 3l.6 1.4L20 5l-1.4.6L18 7l-.6-1.4L16 5l1.4-.6z" fill="currentColor" fillOpacity="0.25" stroke="none" />
      <path d="M19 14l.6 1.4L21 16l-1.4.6L19 18l-.6-1.4L17 16l1.4-.6z" fill="currentColor" fillOpacity="0.2" stroke="none" />
    </>
  ),

  'hand.raised.fill': (
    <path d="M8 12V5.5a1.5 1.5 0 0 1 3 0V10m0-.5V4.5a1.5 1.5 0 0 1 3 0V10m0-.5a1.5 1.5 0 0 1 3 0V13a6 6 0 0 1-6 6h-.5a6 6 0 0 1-5.2-3l-1.6-2.8a1.5 1.5 0 0 1 2.6-1.5L8 13.5z" fill="currentColor" fillOpacity="0.2" />
  ),

  'xmark.circle.fill': (
    <>
      <circle cx="12" cy="12" r="9" fill="currentColor" fillOpacity="0.25" />
      <path d="M15 9l-6 6M9 9l6 6" />
    </>
  ),

  'checkmark.shield.fill': (
    <>
      <path d="M12 3l7 2.5V11c0 4.5-3 7.8-7 9-4-1.2-7-4.5-7-9V5.5z" fill="currentColor" fillOpacity="0.22" />
      <path d="M9 12l2 2 4-4" />
    </>
  ),

  'checkmark.shield': (
    <>
      <path d="M12 3l7 2.5V11c0 4.5-3 7.8-7 9-4-1.2-7-4.5-7-9V5.5z" fill="currentColor" fillOpacity="0.1" />
      <path d="M9 12l2 2 4-4" />
    </>
  ),

  'pause.circle': (
    <>
      <circle cx="12" cy="12" r="9" fill="currentColor" fillOpacity="0.12" />
      <path d="M10 9v6M14 9v6" />
    </>
  ),

  'play.circle': (
    <>
      <circle cx="12" cy="12" r="9" fill="currentColor" fillOpacity="0.12" />
      <path d="M10 8.5l6 3.5-6 3.5z" fill="currentColor" />
    </>
  ),

  'key': (
    <>
      <circle cx="8.5" cy="8.5" r="3.5" fill="currentColor" fillOpacity="0.12" />
      <path d="M11 11l7.5 7.5M16 16l2-2M14 14l1.5 1.5" />
    </>
  ),

  'lock': (
    <>
      <rect x="5" y="11" width="14" height="9" rx="2" fill="currentColor" fillOpacity="0.12" />
      <path d="M8 11V8a4 4 0 0 1 8 0v3" />
      <path d="M12 15v2" stroke="currentColor" />
    </>
  ),

  'lock.fill': (
    <>
      <rect x="5" y="11" width="14" height="9" rx="2" fill="currentColor" fillOpacity="0.18" />
      <path d="M8 11V8a4 4 0 0 1 8 0v3" />
      <path d="M12 15v2" stroke="currentColor" />
    </>
  ),

  'doc.on.doc': (
    <>
      <rect x="9" y="9" width="11" height="11" rx="2" fill="currentColor" fillOpacity="0.12" />
      <path d="M5 15H5a1 1 0 0 1-1-1V5a1 1 0 0 1 1-1h9a1 1 0 0 1 1 1v0" />
    </>
  ),
}

export default function Icon({ name, size = 18, className }) {
  return (
    <svg
      width={size}
      height={size}
      viewBox="0 0 24 24"
      fill="none"
      stroke="currentColor"
      strokeWidth="2"
      strokeLinecap="round"
      strokeLinejoin="round"
      className={className ? `${styles.icon} ${className}` : styles.icon}
      aria-hidden="true"
    >
      {ICONS[name] || null}
    </svg>
  )
}

export { ICONS }
