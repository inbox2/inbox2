// The preview registry (spec F5, disk.md "Preview engine"): which renderer
// shows a file, and how big a file each will take. Every renderer is its own
// module behind a dynamic import, so browsing Disk downloads none of them.
// Anything without a renderer, too large, or that fails falls back to the type
// icon, the size and Download.
import { extensionOf, fileType } from '../fileTypes'
import { RAW_EXTENSIONS } from '../raw'

const MB = 1024 ** 2

// id -> { load, maxBytes }. maxBytes: the renderer reads the whole file into
// memory; media and zip read ranges, so they have no ceiling.
export const RENDERERS = {
  pdf: { load: () => import('../../../pages/disk/preview/PdfPreview'), maxBytes: 200 * MB },
  image: { load: () => import('../../../pages/disk/preview/ImagePreview'), maxBytes: 60 * MB },
  psd: { load: () => import('../../../pages/disk/preview/PsdPreview'), maxBytes: 150 * MB },
  raw: { load: () => import('../../../pages/disk/preview/RawPreview'), maxBytes: 200 * MB },
  video: { load: () => import('../../../pages/disk/preview/MediaPreview'), maxBytes: Infinity },
  audio: { load: () => import('../../../pages/disk/preview/MediaPreview'), maxBytes: Infinity },
  markdown: { load: () => import('../../../pages/disk/preview/MarkdownPreview'), maxBytes: 5 * MB },
  code: { load: () => import('../../../pages/disk/preview/CodePreview'), maxBytes: 20 * MB },
  csv: { load: () => import('../../../pages/disk/preview/CsvPreview'), maxBytes: 20 * MB },
  docx: { load: () => import('../../../pages/disk/preview/DocxPreview'), maxBytes: 50 * MB },
  sheet: { load: () => import('../../../pages/disk/preview/SheetPreview'), maxBytes: 50 * MB },
  pptx: { load: () => import('../../../pages/disk/preview/PptxPreview'), maxBytes: 100 * MB },
  zip: { load: () => import('../../../pages/disk/preview/ZipPreview'), maxBytes: Infinity },
}

// Formats the browser draws natively only in some engines.
const SAFARI_ONLY = new Set(['heic', 'heif', 'tif', 'tiff'])
// Recognised image families with no renderer yet.
const NO_RENDERER = new Set(['eps', 'ai'])

/**
 * The renderer id for a file, or null. `env.safari` says whether the browser
 * decodes HEIC and TIFF itself.
 */
export function rendererFor(node, env = {}) {
  if (!node || node.kind !== 'file' || node.sealed) return null
  const ext = extensionOf(node.name)
  const { preview } = fileType(node)
  if (NO_RENDERER.has(ext)) return null
  switch (preview) {
    case 'pdf': return 'pdf'
    case 'image':
      if (ext === 'psd' || ext === 'psb') return 'psd'
      if (RAW_EXTENSIONS.includes(ext)) return 'raw'
      if (SAFARI_ONLY.has(ext)) return env.safari ? 'image' : null
      return 'image'
    case 'video': return 'video'
    case 'audio': return 'audio'
    case 'markdown': return 'markdown'
    case 'text': return 'code'
    case 'sheet': return ext === 'csv' || ext === 'tsv' ? 'csv' : ['xlsx', 'xls', 'ods', 'numbers'].includes(ext) ? 'sheet' : null
    case 'document': return ext === 'docx' ? 'docx' : null // doc, odt, rtf and Pages wait for the office engine (package 8)
    case 'slides': return ext === 'pptx' ? 'pptx' : null
    case 'archive': return ext === 'zip' ? 'zip' : null
    default: return null
  }
}

/**
 * What the slide-over should show: { renderer } when a renderer takes it,
 * else { reason } for the fallback ('sealed' | 'empty' | 'none' | 'too-large').
 * 'empty' is a file whose upload has not finished: there are no bytes yet.
 */
export function previewPlan(node, env = {}) {
  if (node?.sealed) return { reason: 'sealed' }
  if (node?.kind === 'file' && node.current_version_id === null) return { reason: 'empty' } // undefined: a public link, which never says
  const id = rendererFor(node, env)
  if (!id) return { reason: 'none' }
  if ((node.size_bytes || 0) > RENDERERS[id].maxBytes) return { reason: 'too-large', limit: RENDERERS[id].maxBytes }
  return { renderer: id }
}

export const isSafari = () =>
  typeof navigator !== 'undefined' && /^((?!chrome|android|crios|fxios).)*safari/i.test(navigator.userAgent)
