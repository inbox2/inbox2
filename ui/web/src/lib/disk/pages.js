// Disk pages (spec F6) as markdown: the editor's document (ProseMirror JSON)
// to markdown for saving, search and Export .md; and markdown back to HTML the
// editor parses, for Import .md, "Edit as page" and restoring a version.
// Export is always made here in the browser from the open editor (spec F6).

// DiskPageChannel's message when a page is saved with no ydoc (an agent writing
// markdown over MCP): editors drop their Yjs state and rebuild from the markdown.
export const PAGE_REPLACED = 'page_replaced'

/** A server page with markdown and no Yjs state was replaced (or never edited here): load it before saving anything. */
export const isReplacement = (page) => !page?.ydoc

// The Yjs client id every editor uses to seed a page from markdown, so identical
// seeds made by several people at once merge into one copy.
export const SEED_CLIENT_ID = 1

// A Disk file card in markdown: [File: name](disk://dnd_x). Import turns it back into a card.
export const DISK_LINK = 'disk://'

export const escapeText = (t) => t.replace(/([\\`*_[\]#|<>])/g, '\\$1')

function marks(text, list = []) {
  let out = list.some((m) => m.type === 'code') ? `\`${text}\`` : escapeText(text)
  for (const m of list) {
    if (m.type === 'bold') out = `**${out}**`
    else if (m.type === 'italic') out = `*${out}*`
    else if (m.type === 'strike') out = `~~${out}~~`
    else if (m.type === 'link') out = `[${out}](${m.attrs?.href || ''})`
  }
  return out
}

function inline(nodes = []) {
  return nodes.map((n) => {
    if (n.type === 'text') return marks(n.text, n.marks)
    if (n.type === 'hardBreak') return '  \n'
    if (n.type === 'image') return `![${n.attrs?.alt || ''}](${n.attrs?.src || ''})`
    return inline(n.content)
  }).join('')
}

const indent = (text, pad) => text.split('\n').map((l, i) => (i && l ? pad + l : l)).join('\n')

function cellText(cell) {
  return (cell.content || []).map((p) => inline(p.content)).join(' ').replace(/\n/g, ' ') // inline() already escapes |
}

function block(n, ctx = {}) {
  switch (n.type) {
    case 'paragraph': return inline(n.content)
    case 'heading': return `${'#'.repeat(n.attrs?.level || 1)} ${inline(n.content)}`
    case 'blockquote': return blocks(n.content).split('\n').map((l) => `> ${l}`.trimEnd()).join('\n')
    case 'callout': return `> [!NOTE]\n${blocks(n.content).split('\n').map((l) => `> ${l}`.trimEnd()).join('\n')}`
    case 'codeBlock': return `\`\`\`${n.attrs?.language || ''}\n${(n.content || []).map((t) => t.text).join('')}\n\`\`\``
    case 'horizontalRule': return '---'
    case 'bulletList': return (n.content || []).map((li) => `- ${indent(blocks(li.content, ctx), '  ')}`).join('\n')
    case 'orderedList': {
      const start = n.attrs?.start || 1
      return (n.content || []).map((li, i) => `${start + i}. ${indent(blocks(li.content, ctx), '   ')}`).join('\n')
    }
    case 'taskList':
      return (n.content || []).map((li) => `- [${li.attrs?.checked ? 'x' : ' '}] ${indent(blocks(li.content, ctx), '  ')}`).join('\n')
    case 'table': {
      const rows = (n.content || []).map((r) => (r.content || []).map(cellText))
      if (!rows.length) return ''
      const width = Math.max(...rows.map((r) => r.length))
      const pad = (r) => [...r, ...Array(width - r.length).fill('')]
      const [head, ...body] = rows.map(pad)
      return [`| ${head.join(' | ')} |`, `| ${head.map(() => '---').join(' | ')} |`, ...body.map((r) => `| ${r.join(' | ')} |`)].join('\n')
    }
    case 'diskFile': return `[File: ${escapeText(n.attrs?.name || 'file')}](${DISK_LINK}${n.attrs?.nodeId})`
    case 'image': return `![${n.attrs?.alt || ''}](${n.attrs?.src || ''})`
    default: return n.content ? blocks(n.content, ctx) : ''
  }
}

function blocks(list = [], ctx = {}) {
  return list.map((n) => block(n, ctx)).join('\n\n')
}

/** Markdown for an editor document (editor.getJSON()). */
export function toMarkdown(doc) {
  return `${blocks(doc?.content || []).replace(/\n{3,}/g, '\n\n').trim()}\n`
}

/** The page's first heading or line, for a title or a file name. */
export function pageTitle(markdown, fallback = 'Untitled') {
  const line = (markdown || '').split('\n').find((l) => l.trim())
  return line ? line.replace(/^#+\s*/, '').trim().slice(0, 120) || fallback : fallback
}

/**
 * Markdown to HTML the editor's schema reads: GitHub task lists become Tiptap
 * task items, "> [!NOTE]" blocks become callouts, disk:// links become file
 * cards. Sanitised; remote images are dropped (pages never load remote content).
 * Browser only (DOMParser).
 */
export async function markdownToHtml(markdown) {
  const [{ marked }, { default: DOMPurify }] = await Promise.all([import('marked'), import('dompurify')])
  // disk:// (file cards) joins the protocols DOMPurify keeps; everything else is its default list.
  const html = DOMPurify.sanitize(marked.parse(markdown || '', { async: false, gfm: true }), {
    ALLOWED_URI_REGEXP: /^(?:(?:https?|mailto|tel|disk):|[^a-z]|[a-z+.-]+(?:[^a-z+.\-:]|$))/i,
  })
  const doc = new DOMParser().parseFromString(`<body>${html}</body>`, 'text/html')
  // To-do items become a task list. CommonMark makes "- a" then a blank line then
  // "- [ ] b" ONE list, so a mixed list is split into runs of plain and to-do items.
  const isTask = (li) => !!li.querySelector(':scope > input[type="checkbox"], :scope > p > input[type="checkbox"]')
  doc.querySelectorAll('ul').forEach((ul) => {
    const items = [...ul.children]
    if (!items.some(isTask)) return
    const runs = []
    for (const li of items) {
      const task = isTask(li)
      if (!runs.length || runs.at(-1).task !== task) runs.push({ task, items: [] })
      runs.at(-1).items.push(li)
    }
    ul.replaceWith(...runs.map((run) => {
      const list = doc.createElement('ul')
      run.items.forEach((li) => list.append(li))
      if (!run.task) return list
      list.setAttribute('data-type', 'taskList')
      run.items.forEach((li) => {
        const box = li.querySelector('input[type="checkbox"]')
        li.setAttribute('data-type', 'taskItem')
        li.setAttribute('data-checked', box.checked ? 'true' : 'false')
        box.remove()
      })
      return list
    }))
  })
  doc.querySelectorAll('blockquote').forEach((q) => {
    const first = q.firstElementChild
    if (!first || !/^\s*\[!NOTE\]/.test(first.textContent)) return
    first.innerHTML = first.innerHTML.replace(/^\s*\[!NOTE\]\s*(<br>)?/, '')
    if (!first.textContent.trim()) first.remove()
    const div = doc.createElement('div')
    div.setAttribute('data-callout', '')
    div.append(...q.childNodes)
    q.replaceWith(div)
  })
  doc.querySelectorAll(`a[href^="${DISK_LINK}"]`).forEach((a) => {
    const card = doc.createElement('div')
    card.setAttribute('data-disk-file', a.getAttribute('href').slice(DISK_LINK.length))
    card.setAttribute('data-name', a.textContent.replace(/^File:\s*/, ''))
    const host = a.parentElement?.tagName === 'P' && a.parentElement.childNodes.length === 1 ? a.parentElement : a
    host.replaceWith(card)
  })
  doc.querySelectorAll('img').forEach((img) => { if (!/^(data|blob):/.test(img.getAttribute('src') || '')) img.remove() })
  return doc.body.innerHTML
}

/** Uint8Array <-> base64 for ydoc snapshots. */
export function bytesToBase64(bytes) {
  let s = ''
  for (let i = 0; i < bytes.length; i += 0x8000) s += String.fromCharCode(...bytes.subarray(i, i + 0x8000))
  return btoa(s)
}
export function base64ToBytes(b64) {
  const bin = atob(b64)
  const out = new Uint8Array(bin.length)
  for (let i = 0; i < bin.length; i++) out[i] = bin.charCodeAt(i)
  return out
}

/** Markdown from a Yjs state (a sealed page opened in this browser, 6.10): the editor's "default" fragment. */
export async function stateToMarkdown(state) {
  const [Y, { yDocToProsemirrorJSON }] = await Promise.all([import('yjs'), import('@tiptap/y-tiptap')])
  const doc = new Y.Doc()
  Y.applyUpdate(doc, state)
  try { return toMarkdown(yDocToProsemirrorJSON(doc, 'default')) } finally { doc.destroy() }
}
