import { Node } from '@tiptap/core'
import { cleanSignatureHtml, signatureText } from '../../lib/signatures'

// The signature in a message body: one block, edited in Settings › Signatures,
// not in the message. Serializes as <div data-signature="sig_…">…</div>, so the
// composer can find it and swap it when the From address changes.
function signatureDom(node) {
  const dom = document.createElement('div')
  dom.setAttribute('data-signature', node.attrs.id || '')
  dom.innerHTML = cleanSignatureHtml(node.attrs.html)
  return dom
}

const SignatureNode = Node.create({
  name: 'signature',
  group: 'block',
  atom: true,
  selectable: true,
  draggable: false,

  addAttributes() {
    return {
      id: { default: null, parseHTML: (el) => el.getAttribute('data-signature'), renderHTML: () => ({}) },
      html: { default: '', parseHTML: (el) => el.innerHTML, renderHTML: () => ({}) },
    }
  },

  parseHTML() {
    return [{ tag: 'div[data-signature]' }]
  },

  renderHTML({ node }) {
    return { dom: signatureDom(node) }
  },

  renderText({ node }) {
    return `\n${signatureText(node.attrs.html)}`
  },

  addNodeView() {
    return ({ node }) => {
      const dom = signatureDom(node)
      dom.classList.add('inbox2-signature')
      dom.contentEditable = 'false'
      return { dom }
    }
  },
})

export default SignatureNode
