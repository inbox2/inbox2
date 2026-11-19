// .docx to page markdown (spec F6: import a .docx as a page). Reads
// word/document.xml with zip.js (already a dependency) and walks the
// WordprocessingML: headings, paragraphs, bullet and numbered lists, tables,
// bold, italic, strikethrough and links. Images are left out and counted, so
// the caller can say so. The result goes through markdownToHtml like any
// imported markdown. Browser only (DOMParser).
import { escapeText } from './pages'

const W = 'http://schemas.openxmlformats.org/wordprocessingml/2006/main'
const R = 'http://schemas.openxmlformats.org/officeDocument/2006/relationships'

const kids = (el, name) => [...(el?.childNodes || [])].filter((n) => n.nodeType === 1 && (!name || n.localName === name))
const kid = (el, name) => kids(el, name)[0] || null
const attr = (el, name) => el?.getAttributeNS(W, name) ?? el?.getAttribute(`w:${name}`) ?? null
// <w:b/>, <w:b w:val="1"/> are on; w:val "0", "false" or "none" turn it off.
const on = (el) => !!el && !['0', 'false', 'none'].includes(attr(el, 'val'))
const SAFE_HREF = /^(https?:|mailto:)/i

/** Markdown and what was left out ({ images }) for a .docx Blob. */
export async function docxToMarkdown(blob) {
  const { ZipReader, BlobReader, TextWriter, configure } = await import('@zip.js/zip.js')
  configure({ useWebWorkers: false })
  const zip = new ZipReader(new BlobReader(blob))
  try {
    const entries = await zip.getEntries()
    const read = (name) => entries.find((e) => e.filename === name)?.getData(new TextWriter()) ?? Promise.resolve(null)
    const [doc, rels, numbering, styles] = await Promise.all(['word/document.xml', 'word/_rels/document.xml.rels', 'word/numbering.xml', 'word/styles.xml'].map(read))
    if (!doc) throw new Error("This file isn't a Word document")
    return convertDocx({ doc, rels, numbering, styles })
  } finally {
    await zip.close().catch(() => {})
  }
}

/** The pure part, over the four XML parts as strings (rels, numbering and styles may be null). */
export function convertDocx({ doc, rels, numbering, styles }) {
  const parse = (s) => (s ? new DOMParser().parseFromString(s, 'application/xml') : null)
  const relDoc = parse(rels)
  const links = new Map([...(relDoc?.getElementsByTagName('Relationship') || [])].map((r) => [r.getAttribute('Id'), r.getAttribute('Target')]))
  const styleDoc = parse(styles)
  const styleNames = new Map([...(styleDoc?.getElementsByTagNameNS(W, 'style') || [])].map((s) => [attr(s, 'styleId'), (attr(kid(s, 'name'), 'val') || '').toLowerCase()]))
  const numDoc = parse(numbering)
  const abstractOf = new Map([...(numDoc?.getElementsByTagNameNS(W, 'num') || [])].map((n) => [attr(n, 'numId'), attr(kid(n, 'abstractNumId'), 'val')]))
  const formats = new Map([...(numDoc?.getElementsByTagNameNS(W, 'abstractNum') || [])].map((a) => [
    attr(a, 'abstractNumId'),
    new Map(kids(a, 'lvl').map((l) => [attr(l, 'ilvl'), attr(kid(l, 'numFmt'), 'val')])),
  ]))
  const dropped = { images: 0 }

  const headingLevel = (styleId) => {
    if (!styleId) return 0
    const name = styleNames.get(styleId) || styleId.toLowerCase()
    if (name === 'title') return 1
    if (name === 'subtitle') return 2
    const m = /^heading\s*([1-6])$/.exec(name)
    return m ? Number(m[1]) : 0
  }

  // Runs to segments { text, b, i, s, href }, then merged so **bold** spans whole phrases.
  function segments(el, href = null, out = []) {
    for (const n of kids(el)) {
      if (n.localName === 'r') {
        const pr = kid(n, 'rPr')
        const fmt = { b: on(kid(pr, 'b')), i: on(kid(pr, 'i')), s: on(kid(pr, 'strike')) || on(kid(pr, 'dstrike')), href }
        for (const c of kids(n)) {
          if (c.localName === 't') out.push({ ...fmt, text: c.textContent })
          else if (c.localName === 'tab') out.push({ ...fmt, text: ' ' })
          else if (c.localName === 'br' || c.localName === 'cr') out.push({ ...fmt, text: '\n' })
          else if (c.localName === 'drawing' || c.localName === 'pict' || c.localName === 'object') dropped.images++
        }
      } else if (n.localName === 'hyperlink') {
        const target = links.get(n.getAttributeNS(R, 'id') || n.getAttribute('r:id'))
        segments(n, target && SAFE_HREF.test(target) ? target : null, out)
      } else if (!['pPr', 'del', 'moveFrom', 'rPr'].includes(n.localName)) {
        segments(n, href, out) // ins, smartTag, fldSimple, sdt and sdtContent hold runs too
      }
    }
    return out
  }

  function inline(el) {
    const merged = []
    for (const seg of segments(el)) {
      const last = merged.at(-1)
      if (last && last.b === seg.b && last.i === seg.i && last.s === seg.s && last.href === seg.href) last.text += seg.text
      else merged.push({ ...seg })
    }
    return merged.map((m) => m.text.split('\n').map((part) => {
      // Markers hug the words: "** a **" is not bold in markdown.
      const [, lead, core, trail] = /^(\s*)(.*?)(\s*)$/s.exec(part)
      if (!core) return part
      let t = escapeText(core)
      if (m.s) t = `~~${t}~~`
      if (m.i) t = `*${t}*`
      if (m.b) t = `**${t}**`
      if (m.href) t = `[${t}](${m.href.replace(/[()\s]/g, encodeURIComponent)})`
      return lead + t + trail
    }).join('  \n')).join('')
  }

  const table = (tbl) => {
    const rows = kids(tbl, 'tr').map((tr) => kids(tr, 'tc').map((tc) => kids(tc, 'p').map(inline).join(' ').replace(/\s*\n\s*/g, ' ').trim()))
    if (!rows.length) return ''
    const width = Math.max(...rows.map((r) => r.length))
    const pad = (r) => [...r, ...Array(width - r.length).fill('')]
    const [head, ...body] = rows.map(pad)
    return [`| ${head.join(' | ')} |`, `| ${head.map(() => '---').join(' | ')} |`, ...body.map((r) => `| ${r.join(' | ')} |`)].join('\n')
  }

  const out = []
  let list = null // the previous block's list (numId): items of one list join with single newlines
  const walk = (body) => {
    for (const n of kids(body)) {
      if (n.localName === 'sdt') { walk(kid(n, 'sdtContent')); continue }
      if (n.localName === 'tbl') { out.push({ text: table(n) }); list = null; continue }
      if (n.localName !== 'p') continue
      const pr = kid(n, 'pPr')
      const numPr = kid(pr, 'numPr')
      const numId = attr(kid(numPr, 'numId'), 'val')
      const text = inline(n).trim()
      if (numPr && numId && numId !== '0') {
        const level = Number(attr(kid(numPr, 'ilvl'), 'val') || 0)
        const fmt = formats.get(abstractOf.get(numId))?.get(String(level))
        const marker = fmt && fmt !== 'bullet' && fmt !== 'none' ? '1.' : '-'
        out.push({ text: `${'   '.repeat(level)}${marker} ${text}`, item: list === numId })
        list = numId
        continue
      }
      list = null
      if (!text) continue
      const level = headingLevel(attr(kid(pr, 'pStyle'), 'val'))
      out.push({ text: level ? `${'#'.repeat(level)} ${text}` : text })
    }
  }
  walk(kid(parse(doc)?.documentElement, 'body'))
  const markdown = out.reduce((s, b) => (s ? s + (b.item ? '\n' : '\n\n') : '') + b.text, '')
  return { markdown: `${markdown.trim()}\n`, dropped }
}
