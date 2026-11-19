// Disk file types: one table from extension and MIME to the icon drawn by
// FileTypeIcon, a human label, the filter family FilterBar offers (spec F2)
// and the preview family the renderer registry keys on (spec F5).
//
// family:  documents | sheets | slides | images | media | other
//          (folders and pages are node kinds, see listing.js)
// preview: pdf | image | video | audio | markdown | text | document | sheet
//          | slides | archive | null (no renderer: icon plus Download)

import { RAW_EXTENSIONS } from './raw'

// [icon, label, family, preview, extensions, MIME types]
const TYPES = [
  ['link', 'Link', 'other', null, ['url', 'webloc', 'lnk'], ['application/internet-shortcut']],
  ['pdf', 'PDF', 'documents', 'pdf', ['pdf'], ['application/pdf']],
  ['word', 'Word document', 'documents', 'document', ['doc', 'docx', 'odt', 'rtf', 'pages'], [
    'application/msword',
    'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
    'application/vnd.oasis.opendocument.text',
    'application/rtf', 'text/rtf',
  ]],
  ['text', 'Text', 'documents', 'text', ['txt', 'log'], ['text/plain']],
  ['markdown', 'Markdown', 'documents', 'markdown', ['md', 'mdx'], ['text/markdown']],
  ['ebook', 'E-book', 'documents', null, ['epub', 'mobi'], ['application/epub+zip', 'application/x-mobipocket-ebook']],
  ['sheet', 'Spreadsheet', 'sheets', 'sheet', ['xls', 'xlsx', 'ods', 'numbers'], [
    'application/vnd.ms-excel',
    'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
    'application/vnd.oasis.opendocument.spreadsheet',
  ]],
  ['csv', 'CSV', 'sheets', 'sheet', ['csv', 'tsv'], ['text/csv', 'text/tab-separated-values']],
  ['slides', 'Presentation', 'slides', 'slides', ['ppt', 'pptx', 'odp', 'key'], [
    'application/vnd.ms-powerpoint',
    'application/vnd.openxmlformats-officedocument.presentationml.presentation',
    'application/vnd.oasis.opendocument.presentation',
  ]],
  ['database', 'Database', 'other', null, ['sqlite', 'db', 'sql'], ['application/vnd.sqlite3', 'application/sql']],
  ['structured', 'Data', 'other', 'text', ['json', 'yaml', 'yml', 'toml', 'xml'], [
    'application/json', 'application/yaml', 'application/toml', 'application/xml', 'text/xml',
  ]],
  ['image', 'Image', 'images', 'image', ['jpg', 'jpeg', 'png', 'gif', 'webp', 'avif', 'heic', 'heif', 'bmp', 'tif', 'tiff'], []],
  ['raw', 'Camera RAW', 'images', 'image', RAW_EXTENSIONS, ['image/x-canon-cr2', 'image/x-canon-cr3', 'image/x-nikon-nef', 'image/x-sony-arw', 'image/x-adobe-dng', 'image/x-fuji-raf', 'image/x-olympus-orf', 'image/x-panasonic-rw2']],
  ['vector', 'Vector', 'images', 'image', ['svg', 'eps', 'ai'], ['image/svg+xml', 'application/postscript', 'application/illustrator']],
  ['photoshop', 'Photoshop', 'images', 'image', ['psd', 'psb'], ['image/vnd.adobe.photoshop']],
  ['design', 'Design file', 'images', null, ['fig', 'sketch', 'xd', 'indd'], []],
  ['video', 'Video', 'media', 'video', ['mp4', 'm4v', 'mov', 'mkv', 'webm', 'avi'], []],
  ['audio', 'Audio', 'media', 'audio', ['mp3', 'm4a', 'flac', 'wav', 'ogg', 'opus'], []],
  ['subtitle', 'Subtitles', 'media', 'text', ['srt', 'vtt'], ['text/vtt', 'application/x-subrip']],
  ['model', '3D model', 'other', null, ['glb', 'gltf', 'obj', 'stl'], ['model/gltf-binary', 'model/gltf+json', 'model/obj', 'model/stl']],
  ['cad', 'CAD drawing', 'other', null, ['dwg', 'dxf', 'step', 'stp'], ['image/vnd.dwg', 'image/vnd.dxf']],
  ['font', 'Font', 'other', null, ['ttf', 'otf', 'woff', 'woff2'], []],
  ['code', 'Code', 'other', 'text', ['js', 'jsx', 'mjs', 'ts', 'tsx', 'py', 'rb', 'go', 'rs', 'java', 'c', 'h', 'cpp', 'swift', 'kt'], [
    'text/javascript', 'application/javascript', 'text/x-python', 'text/x-ruby',
  ]],
  ['web', 'Web page', 'other', 'text', ['html', 'htm', 'css'], ['text/html', 'text/css']],
  ['shell', 'Script', 'other', 'text', ['sh', 'bash', 'zsh', 'bat', 'cmd', 'ps1'], ['application/x-sh', 'text/x-shellscript']],
  ['notebook', 'Notebook', 'other', 'text', ['ipynb'], ['application/x-ipynb+json']],
  ['config', 'Config', 'other', 'text', ['env', 'ini', 'conf', 'cfg'], []],
  ['archive', 'Archive', 'other', 'archive', ['zip', 'rar', '7z', 'tar', 'gz', 'tgz'], [
    'application/zip', 'application/x-zip-compressed', 'application/vnd.rar', 'application/x-7z-compressed',
    'application/x-tar', 'application/gzip',
  ]],
  ['diskimage', 'Disk image', 'other', null, ['iso', 'dmg'], ['application/x-iso9660-image', 'application/x-apple-diskimage']],
  ['installer', 'Installer', 'other', null, ['exe', 'msi', 'apk', 'pkg', 'deb'], [
    'application/vnd.microsoft.portable-executable', 'application/x-msdownload', 'application/x-msi',
    'application/vnd.android.package-archive', 'application/vnd.debian.binary-package',
  ]],
  ['email', 'Email', 'other', null, ['eml', 'msg', 'mbox'], ['message/rfc822', 'application/vnd.ms-outlook', 'application/mbox']],
  ['calendar', 'Calendar', 'other', 'text', ['ics'], ['text/calendar']],
  ['contact', 'Contact', 'other', 'text', ['vcf'], ['text/vcard', 'text/x-vcard']],
  ['key', 'Key or certificate', 'other', null, ['pem', 'crt', 'cer', 'p12', 'pfx', 'gpg', 'asc'], [
    'application/x-pem-file', 'application/x-x509-ca-cert', 'application/x-pkcs12', 'application/pgp-encrypted',
  ]],
]

// Per-extension exceptions to their icon's preview family: formats that only
// the office engine (or nothing) can show. The registry decides quick vs exact.
const PREVIEW_OVERRIDES = { pages: null, numbers: 'sheet', key: null, eps: null, ai: null, sqlite: null, db: null, sql: 'text', p12: null, pfx: null, gpg: null }

export const GENERIC = { icon: 'file', label: 'File', family: 'other', preview: null }

const BY_EXT = new Map()
const BY_MIME = new Map()
for (const [icon, label, family, preview, exts, mimes] of TYPES) {
  for (const ext of exts) {
    BY_EXT.set(ext, { icon, label, family, preview: ext in PREVIEW_OVERRIDES ? PREVIEW_OVERRIDES[ext] : preview })
  }
  for (const mime of mimes) BY_MIME.set(mime, { icon, label, family, preview })
}

// Families of whole MIME top-level types, for files with no known extension.
const BY_MIME_PREFIX = { image: 'image', video: 'video', audio: 'audio', text: 'text', font: 'font' }
const ICONS = new Map(TYPES.map(([icon, label, family, preview]) => [icon, { icon, label, family, preview }]))

/** Lower-case extension of a file name, or '' (".env" counts as "env"). */
export function extensionOf(name) {
  const i = (name || '').lastIndexOf('.')
  return i < 0 ? '' : name.slice(i + 1).toLowerCase()
}

/** { icon, label, family, preview } for a file, by extension first, then MIME. */
export function fileType({ name, mime } = {}) {
  const byExt = BY_EXT.get(extensionOf(name))
  if (byExt) return byExt
  const m = (mime || '').toLowerCase().split(';')[0].trim()
  if (BY_MIME.has(m)) return BY_MIME.get(m)
  const prefixIcon = BY_MIME_PREFIX[m.split('/')[0]]
  return (prefixIcon && ICONS.get(prefixIcon)) || GENERIC
}

/** The entry for an icon key, e.g. typeForIcon('link'). */
export function typeForIcon(icon) {
  return ICONS.get(icon) || GENERIC
}

/** Every file icon key, for the Storybook gallery and tests. */
export const FILE_ICONS = [...ICONS.keys(), 'file']
