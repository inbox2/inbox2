import { useContext, useEffect, useState } from 'react'
import DOMPurify from 'dompurify'
import api from './api'
import { AuthContext } from '../hooks/AuthProvider'

// Mail signatures (spec 8.1.7, docs/Signatures in api/app/models/signature.rb).
// The API answers which signature goes under each From address (`applied`), so
// the clients never choose one themselves.

// Keyed by member and org: the answer holds the member's own signatures, so a
// different person signing in on this browser never gets the last one's.
const cache = new Map() // "userId:orgId" → { at, promise: Promise<{ signatures, applied }> }
const listeners = new Set()
// A change made on another device shows up in the next composer after this long.
const MAX_AGE_MS = 5 * 60 * 1000

// No org (a Gmail or Outlook From): nothing applies.
const NONE = Object.freeze({ signatures: [], applied: {} })

export function loadSignatures(orgId, userId, { fresh = false } = {}) {
  if (!orgId) return Promise.resolve(NONE)
  const key = `${userId}:${orgId}`
  const hit = cache.get(key)
  if (fresh || !hit || Date.now() - hit.at > MAX_AGE_MS) {
    const promise = api.listSignatures(orgId).catch((e) => { cache.delete(key); throw e })
    cache.set(key, { at: Date.now(), promise })
  }
  return cache.get(key).promise
}

// After a change in Settings: refetch and tell every open composer.
export function reloadSignatures(orgId, userId) {
  const p = loadSignatures(orgId, userId, { fresh: true })
  p.then(() => listeners.forEach((fn) => fn(orgId))).catch(() => {})
  return p
}

// undefined while loading, null when the fetch failed (keep what the draft has).
export function useSignatures(orgId) {
  const userId = useContext(AuthContext)?.user?.id
  const key = `${userId}:${orgId}`
  // Keyed to what it was loaded for: while another org or member loads, this is
  // undefined, so a composer never applies one answer to another From address.
  const [state, setState] = useState({ key: undefined, data: undefined })
  useEffect(() => {
    let live = true
    let latest = 0 // only the newest request may set the state (a reload can finish first)
    const load = () => {
      const n = ++latest
      const settle = (data) => { if (live && n === latest) setState({ key, data }) }
      loadSignatures(orgId, userId).then(settle, () => settle(null))
    }
    load()
    const onChange = (id) => { if (id === orgId) load() }
    listeners.add(onChange)
    return () => { live = false; listeners.delete(onChange) }
  }, [orgId, userId, key])
  // No org (a Gmail or Outlook From) needs no fetch: nothing applies, at once.
  if (!orgId) return NONE
  return state.key === key ? state.data : undefined
}

// A body's text with the signature block left out (is this draft empty?).
export function bodyTextWithoutSignature(html) {
  const doc = new DOMParser().parseFromString(html || '', 'text/html')
  doc.querySelectorAll('[data-signature]').forEach((el) => el.remove())
  return (doc.body.textContent || '').replace(/\u00a0/g, ' ').trim()
}

// { id, html } for mail from `address`, or null.
export function signatureFor(data, address) {
  return data?.applied?.[String(address || '').toLowerCase()] || null
}

export const cleanSignatureHtml = (html) => DOMPurify.sanitize(html || '')

// The block a signature takes in a message body; the editor's signature node
// parses it back (components/RichEditor/SignatureNode.js).
export function signatureBlock(sig) {
  return sig ? `<div data-signature="${sig.id}">${cleanSignatureHtml(sig.html)}</div>` : ''
}

// Plain-text form for body_plain: "-- " then the text, as mail clients expect.
export function signatureText(html) {
  const doc = new DOMParser().parseFromString(cleanSignatureHtml(html).replace(/<br\s*\/?>/gi, '\n').replace(/<\/(p|div|tr|li|h\d)>/gi, '$&\n'), 'text/html')
  const text = (doc.body.textContent || '').replace(/\n{3,}/g, '\n\n').trim()
  return text ? `-- \n${text}` : ''
}

// Puts `sig` ({ id, html } or null) in the editor's body: replaces or removes
// the signature that is there, or, when `insert`, adds it under a blank line.
// Kept out of undo history: it is not the user's edit.
// (Here, not in SignatureNode.js, so the composer can call it without loading TipTap.)
export function applySignature(editor, sig, insert) {
  const { state } = editor
  let found = null
  state.doc.descendants((n, pos) => {
    if (found) return false
    if (n.type.name === 'signature') { found = { node: n, pos }; return false }
    return true
  })
  const type = state.schema.nodes.signature
  let tr = state.tr
  if (found) {
    if (!sig) tr = tr.delete(found.pos, found.pos + found.node.nodeSize)
    else if (found.node.attrs.id === sig.id && found.node.attrs.html === sig.html) return
    else tr = tr.replaceWith(found.pos, found.pos + found.node.nodeSize, type.create({ id: sig.id, html: sig.html }))
  } else if (sig && insert) {
    tr = tr.insert(state.doc.content.size, [state.schema.nodes.paragraph.create(), type.create({ id: sig.id, html: sig.html })])
  } else {
    return
  }
  editor.view.dispatch(tr.setMeta('addToHistory', false))
}

const MAX_IMAGE_WIDTH = 600

// A picked image file → a data: URL, scaled down to 600 px wide. PNG stays PNG
// (logos keep their transparency), everything else becomes JPEG.
export async function imageToDataUrl(file) {
  const bitmap = await createImageBitmap(file)
  const scale = Math.min(1, MAX_IMAGE_WIDTH / bitmap.width)
  const canvas = document.createElement('canvas')
  canvas.width = Math.round(bitmap.width * scale)
  canvas.height = Math.round(bitmap.height * scale)
  canvas.getContext('2d').drawImage(bitmap, 0, 0, canvas.width, canvas.height)
  bitmap.close?.()
  const png = file.type === 'image/png' || file.type === 'image/gif'
  // Shown at most 300 px wide, so a 600 px file stays sharp on a retina screen.
  return { src: canvas.toDataURL(png ? 'image/png' : 'image/jpeg', 0.88), width: Math.min(canvas.width, 300) }
}
