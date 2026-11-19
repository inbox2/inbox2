// Disk's own flat icon set, ported from docs/plans/disk-design/disk-mockup.html.
// File glyphs sit in a 14x14 box on white paper; share emblems in a 12x12 box
// on the folder. Shapes are filled in the colour unless they set S (stroked).

const S = { fill: 'none', strokeLinecap: 'round', strokeLinejoin: 'round' }

// icon key -> [colour, glyph]
export const FILE_GLYPHS = {
  file: ['#8d92a5', <><circle cx="2" cy="7" r="1.6" /><circle cx="7" cy="7" r="1.6" /><circle cx="12" cy="7" r="1.6" /></>],
  link: ['#17509f', <path d="M5.5 8.5a2.6 2.6 0 0 0 3.7 0l2.5-2.5a2.6 2.6 0 0 0-3.7-3.7l-.7.7M8.5 5.5a2.6 2.6 0 0 0-3.7 0L2.3 8a2.6 2.6 0 0 0 3.7 3.7l.7-.7" {...S} strokeWidth="1.6" />],
  pdf: ['#d6453d', <><rect width="14" height="5" rx="1.2" /><path d="M1 8.8h12M1 12.3h8" {...S} strokeWidth="1.5" strokeOpacity=".45" /></>],
  word: ['#2f7ad6', <path d="M1 1h12M1 5h12M1 9h12M1 13h7" {...S} strokeWidth="1.6" />],
  text: ['#6f7f99', <path d="M1 2h12M1 6h12M1 10h12M1 13.5h6" {...S} strokeWidth="1.1" />],
  markdown: ['#182242', <text x="7" y="12" textAnchor="middle" fontFamily="JetBrains Mono" fontWeight="700" fontSize="14">#</text>],
  page: ['#17509f', <text x="7" y="11.5" textAnchor="middle" fontFamily="Fraunces" fontWeight="600" fontSize="12.5">Aa</text>],
  ebook: ['#b0603a', <path d="M7 3C5 1.5 2.5 1.2.7 1.5v10c1.8-.3 4.3 0 6.3 1.5 2-1.5 4.5-1.8 6.3-1.5v-10C11.5 1.2 9 1.5 7 3zM7 3v10.5" {...S} strokeWidth="1.3" />],
  sheet: ['#2e8f5b', <><rect x=".7" y=".7" width="12.6" height="12.6" rx="1.5" {...S} strokeWidth="1.4" /><path d="M.7 5h12.6M.7 9.2h12.6M5.2.7v12.6" {...S} strokeWidth="1.2" /></>],
  csv: ['#2e8f5b', <path d="M1 2h3M6 2h3M11 2h2M1 7h3M6 7h3M11 7h2M1 12h3M6 12h3M11 12h2" {...S} strokeWidth="1.7" />],
  slides: ['#e07a2f', <><path d="M6.5 1.5a6 6 0 1 0 6 6h-6z" /><path d="M8.5 0a5.5 5.5 0 0 1 5.5 5.5H8.5z" fillOpacity=".5" /></>],
  database: ['#4a55c9', <><ellipse cx="7" cy="2.6" rx="6" ry="2.1" {...S} strokeWidth="1.3" /><path d="M1 2.6v8.6c0 1.2 2.7 2.1 6 2.1s6-.9 6-2.1V2.6M1 6.9c0 1.2 2.7 2.1 6 2.1s6-.9 6-2.1" {...S} strokeWidth="1.3" /></>],
  structured: ['#c98a1b', <path d="M4.5 1C3 1 2.8 2 2.8 3.2v2C2.8 6.4 2 7 1 7c1 0 1.8.6 1.8 1.8v2c0 1.2.2 2.2 1.7 2.2M9.5 1c1.5 0 1.7 1 1.7 2.2v2c0 1.2.8 1.8 1.8 1.8-1 0-1.8.6-1.8 1.8v2c0 1.2-.2 2.2-1.7 2.2" {...S} strokeWidth="1.5" />],
  image: ['#8a5bd6', <><circle cx="10.5" cy="3" r="2" /><path d="M0 13.5l4.5-7.5 3.5 4.5 2-2.5 4 5.5z" /></>],
  raw: ['#6a4bb0', <><path d="M2 3h2.3l1.2-2h3l1.2 2H12a2 2 0 0 1 2 2v7a2 2 0 0 1-2 2H2a2 2 0 0 1-2-2V5a2 2 0 0 1 2-2z" /><circle cx="7" cy="8.3" r="2.6" fill="#fff" /></>],
  vector: ['#e06a3d', <><path d="M1.5 12C3.5 4 10.5 10 12.5 2" {...S} strokeWidth="1.4" /><rect y="10.5" width="3" height="3" rx=".5" /><rect x="11" y=".5" width="3" height="3" rx=".5" /></>],
  photoshop: ['#2a8fd6', <><path d="M7 1l6 3-6 3-6-3z" /><path d="M1 7.2l6 3 6-3M1 10.2l6 3 6-3" {...S} strokeWidth="1.4" /></>],
  design: ['#c2408f', <><path d="M7 .8l5 5.6-5 7.2-5-7.2z" {...S} strokeWidth="1.4" /><circle cx="7" cy="7" r="1.3" /></>],
  video: ['#c2408f', <><rect y="1" width="14" height="12" rx="2.5" /><path d="M5.5 4.2v5.6L10 7z" fill="#fff" stroke="none" /></>],
  audio: ['#d69a2f', <path d="M1 5v4M4 2v10M7 4v6M10 .5v13M13 5v4" {...S} strokeWidth="1.7" />],
  subtitle: ['#9b3d75', <><rect x=".7" y="1.5" width="12.6" height="11" rx="2" {...S} strokeWidth="1.4" /><path d="M3.2 7.8h4M9 7.8h1.8M3.2 10h7.6" {...S} strokeWidth="1.4" /></>],
  model: ['#1f9aa5', <path d="M7 .8l5.6 3v6.4L7 13.2l-5.6-3V3.8zM1.4 3.8L7 6.8l5.6-3M7 6.8v6.4" {...S} strokeWidth="1.3" />],
  cad: ['#3d6f8f', <><path d="M1 13V1l12 12z" {...S} strokeWidth="1.4" /><path d="M3.8 10.2V7l3.2 3.2z" {...S} strokeWidth="1.2" /></>],
  font: ['#182242', <text x="7" y="11.5" textAnchor="middle" fontFamily="Fraunces" fontWeight="600" fontSize="12.5">Ag</text>],
  code: ['#5b6178', <path d="M4.5 2L0 7l4.5 5M9.5 2L14 7l-4.5 5" {...S} strokeWidth="1.7" />],
  web: ['#2f7ad6', <><circle cx="7" cy="7" r="6" {...S} strokeWidth="1.3" /><ellipse cx="7" cy="7" rx="2.6" ry="6" {...S} strokeWidth="1.2" /><path d="M1 7h12" {...S} strokeWidth="1.2" /></>],
  shell: ['#182242', <path d="M1 2.5L5.5 7 1 11.5M7 12h6" {...S} strokeWidth="1.7" />],
  notebook: ['#e07a2f', <><rect x="3" y=".7" width="10.3" height="12.6" rx="1.5" {...S} strokeWidth="1.4" /><path d="M1 3.5h3.5M1 7h3.5M1 10.5h3.5M6.5 4.5h4" {...S} strokeWidth="1.4" /></>],
  config: ['#5b6178', <><path d="M1 3h12M1 7h12M1 11h12" {...S} strokeWidth="1.1" /><circle cx="4" cy="3" r="1.7" /><circle cx="10" cy="7" r="1.7" /><circle cx="6" cy="11" r="1.7" /></>],
  archive: ['#8d6b3f', <><path d="M5 0h2v2H5zM7 2h2v2H7zM5 4h2v2H5zM7 6h2v2H7z" /><rect x="4.5" y="9" width="5" height="5" rx="1" /></>],
  diskimage: ['#5b6178', <><circle cx="7" cy="7" r="6.2" {...S} strokeWidth="1.4" /><circle cx="7" cy="7" r="1.8" /></>],
  installer: ['#2e8f5b', <path d="M7 1v7.5M4 5.5l3 3 3-3M1 9.5v3.3h12V9.5" {...S} strokeWidth="1.6" />],
  email: ['#2f7ad6', <><rect x=".7" y="2" width="12.6" height="10" rx="1.5" {...S} strokeWidth="1.4" /><path d="M1.2 3l5.8 4.8L12.8 3" {...S} strokeWidth="1.4" /></>],
  calendar: ['#d6453d', <><rect x=".7" y="2" width="12.6" height="11.3" rx="1.5" {...S} strokeWidth="1.4" /><path d="M.7 3.5A1.5 1.5 0 0 1 2.2 2h9.6a1.5 1.5 0 0 1 1.5 1.5v2.2H.7z" /><path d="M4 .5v3M10 .5v3" {...S} strokeWidth="1.4" /></>],
  contact: ['#8a5bd6', <><circle cx="7" cy="4.3" r="2.8" /><path d="M1.6 13.3a5.4 5.4 0 0 1 10.8 0z" /></>],
  key: ['#c98a1b', <><circle cx="4" cy="7" r="3" {...S} strokeWidth="1.5" /><path d="M7 7h6.3M10.8 7v2.6M13 7v2" {...S} strokeWidth="1.5" /></>],
}

// Share colour keys. A share stores an emblem and a colour key; the emblem's
// own colour is the default.
export const SHARE_COLORS = {
  orange: '#e06a3d', green: '#2e8f5b', amber: '#c98a1b', violet: '#8a5bd6',
  blue: '#2f7ad6', pink: '#c2408f', teal: '#1f9aa5', indigo: '#4a55c9',
  brown: '#8d6b3f', slate: '#3d5a80', red: '#9b3d3d', navy: '#3b4a6b',
}
export const FOLDER_COLOR = '#4a8fdd'

// emblem key -> [default colour key, glyph]
export const EMBLEMS = {
  marketing: ['orange', <><path d="M1 4.5v3h2.5L8 10.5v-9L3.5 4.5z" /><path d="M9.6 3.8a3 3 0 0 1 0 4.4" {...S} strokeWidth="1.2" /></>],
  sales: ['green', <><path d="M1 10l3.5-4 2.5 2L11 2.5" {...S} strokeWidth="1.6" /><path d="M7.5 1.5h4v4z" /></>],
  finance: ['amber', <><circle cx="6" cy="6" r="5" {...S} strokeWidth="1.4" /><text x="6" y="8.7" textAnchor="middle" fontSize="7.5" fontWeight="700" fontFamily="Inter">€</text></>],
  hr: ['violet', <><circle cx="6" cy="3.6" r="2.4" /><path d="M1.5 11.5a4.5 4.5 0 0 1 9 0z" /></>],
  product: ['blue', <path d="M6 .8l4.8 2.6v5.2L6 11.2 1.2 8.6V3.4zM1.2 3.4L6 6l4.8-2.6M6 6v5.2" {...S} strokeWidth="1.3" />],
  design: ['pink', <><circle cx="4.5" cy="4.5" r="3.6" {...S} strokeWidth="1.3" /><rect x="5" y="5" width="6" height="6" rx="1" /></>],
  support: ['teal', <><circle cx="6" cy="6" r="5" {...S} strokeWidth="1.4" /><circle cx="6" cy="6" r="2" {...S} strokeWidth="1.4" /></>],
  business: ['slate', <><rect x=".8" y="3.5" width="10.4" height="7.5" rx="1.2" /><path d="M4 3.5V2a1 1 0 0 1 1-1h2a1 1 0 0 1 1 1v1.5" {...S} strokeWidth="1.3" /></>],
  analytics: ['indigo', <><rect x="1" y="6.5" width="2.6" height="5" rx=".6" /><rect x="4.7" y="3.5" width="2.6" height="8" rx=".6" /><rect x="8.4" y=".8" width="2.6" height="10.7" rx=".6" /></>],
  procurement: ['brown', <><path d="M.8 1.5h2l1.6 6h5.4l1.2-4.2H4" {...S} strokeWidth="1.3" /><circle cx="5" cy="10" r="1.1" /><circle cx="9" cy="10" r="1.1" /></>],
  legal: ['red', <><path d="M6 1v10M3 11h6M1.5 3h9M1.5 3L.3 6.5M1.5 3l1.2 3.5M10.5 3L9.3 6.5M10.5 3l1.2 3.5" {...S} strokeWidth="1.1" /><path d="M0 6.5a1.5 1.5 0 0 0 3 0zM9 6.5a1.5 1.5 0 0 0 3 0z" /></>],
  engineering: ['navy', <path d="M4 2.5L.8 6 4 9.5M8 2.5L11.2 6 8 9.5" {...S} strokeWidth="1.5" />],
  // Emblems for plain folders: shared with people, sealed.
  shared: [null, <><circle cx="4.5" cy="3.6" r="2.1" /><path d="M.6 10.8a3.9 3.9 0 0 1 7.8 0z" /><circle cx="9.2" cy="4.2" r="1.6" /><path d="M8.6 7.3a3 3 0 0 1 3 3.5H9.6" /></>],
  sealed: ['green', <><rect x="2" y="5.3" width="8" height="6.2" rx="1.2" /><path d="M4 5.3V3.9a2 2 0 0 1 4 0v1.4" {...S} strokeWidth="1.4" /></>],
}

// 16px line action glyphs (the mockup's `ic` set), drawn by ActionIcon.
export const ACTION_PATHS = {
  download: 'M8 2v8M4.5 7L8 10.5 11.5 7M3 13.5h10',
  upload: 'M8 11V3M4.5 6L8 2.5 11.5 6M3 13.5h10',
  expand: 'M9.5 2.5h4v4M13.5 2.5L9 7M6.5 13.5h-4v-4M2.5 13.5L7 9',
  share: 'M8.5 5a2.5 2.5 0 1 1-5 0 2.5 2.5 0 0 1 5 0zM1.5 13.5a4.5 4.5 0 0 1 9 0M12.5 5v4M10.5 7h4',
  folder: 'M2 4.5A1.5 1.5 0 0 1 3.5 3h3L8 4.5h4.5A1.5 1.5 0 0 1 14 6v6a1.5 1.5 0 0 1-1.5 1.5h-9A1.5 1.5 0 0 1 2 12zM8 7.5V11M6.25 9.25h3.5',
  page: 'M4 2h5l3 3v9H4zM9 2v3h3M8 8v3.5M6.25 9.75h3.5',
  more: 'M3.5 8h.01M8 8h.01M12.5 8h.01',
  search: 'M7 12A5 5 0 1 0 7 2a5 5 0 0 0 0 10zM11 11l3 3',
  list: 'M3 4h10M3 8h10M3 12h10',
  grid: 'M3 3h4v4H3zM9 3h4v4H9zM3 9h4v4H3zM9 9h4v4H9z',
  trash: 'M3 4.5h10M6.5 4.5V3h3v1.5M4.5 4.5l.5 9h6l.5-9',
  move: 'M2 8h9M8 5l3 3-3 3M14 3v10',
  x: 'M4 4l8 8M12 4l-8 8',
  eye: 'M1.5 8s2.5-4.5 6.5-4.5S14.5 8 14.5 8 12 12.5 8 12.5 1.5 8 1.5 8zM8 9.8a1.8 1.8 0 1 0 0-3.6 1.8 1.8 0 0 0 0 3.6z',
  link: 'M6.5 9.5a3 3 0 0 0 4.2 0l2-2a3 3 0 0 0-4.2-4.2l-.8.8M9.5 6.5a3 3 0 0 0-4.2 0l-2 2a3 3 0 0 0 4.2 4.2l.8-.8',
  pencil: 'M2.5 13.5l.7-3L10.8 3a1.4 1.4 0 0 1 2 2l-7.5 7.6zM9.8 4l2.2 2.2',
  copy: 'M5.5 5.5h7v8h-7zM3.5 10.5v-8h7',
  star: 'M8 2l1.8 3.8 4.2.5-3.1 2.9.8 4.1L8 11.3l-3.7 2 .8-4.1L2 6.3l4.2-.5z',
  clock: 'M8 14A6 6 0 1 0 8 2a6 6 0 0 0 0 12zM8 4.5V8l2.5 1.5',
  lock: 'M4 7.5h8v6H4zM5.5 7.5V5.5a2.5 2.5 0 0 1 5 0v2',
  people: 'M6 7a2.3 2.3 0 1 0 0-4.6A2.3 2.3 0 0 0 6 7zM1.8 13a4.2 4.2 0 0 1 8.4 0M11 7.2a2 2 0 1 0-.6-3.9M11.6 9.3a3.6 3.6 0 0 1 2.8 3.7',
  check: 'M3 8.5l3.2 3L13 4.5',
  chevronLeft: 'M10 3L5 8l5 5',
  chevronDown: 'M3 6l5 5 5-5',
  chevronRight: 'M6 3l5 5-5 5',
  arrowUp: 'M8 13V3M4 7l4-4 4 4',
  arrowDown: 'M8 3v10M4 9l4 4 4-4',
}
