// @vitest-environment jsdom
import { describe, it, expect } from 'vitest'
import { Editor } from '@tiptap/core'
import StarterKit from '@tiptap/starter-kit'
import SignatureNode from '../../components/RichEditor/SignatureNode'
import { signatureFor, signatureBlock, signatureText, applySignature, bodyTextWithoutSignature } from '../signatures'

const data = { applied: { 'wesley@lalaaji.com': { id: 'sig_a', html: '<p>Wesley<br>Lalaaji</p>' } } }

describe('signatures', () => {
  it('looks the From address up without case', () => {
    expect(signatureFor(data, 'Wesley@Lalaaji.com').id).toBe('sig_a')
    expect(signatureFor(data, 'x@y.com')).toBeNull()
    expect(signatureFor(undefined, 'x@y.com')).toBeNull()
  })

  it('strips scripts from the block and writes plain text after "-- "', () => {
    expect(signatureBlock({ id: 'sig_b', html: '<p>Hi<script>x()</script></p>' })).toBe('<div data-signature="sig_b"><p>Hi</p></div>')
    expect(signatureText('<p>Wesley<br>Lalaaji</p>')).toBe('-- \nWesley\nLalaaji')
  })

  it('treats a body with only the signature as empty', () => {
    expect(bodyTextWithoutSignature('<p></p><p></p><div data-signature="sig_a"><p>Wesley</p></div><p></p>')).toBe('')
    expect(bodyTextWithoutSignature('<p>Hi</p><div data-signature="sig_a"><p>Wesley</p></div>')).toBe('Hi')
  })

  it('adds, swaps and removes the signature in the editor', () => {
    const editor = new Editor({ extensions: [StarterKit, SignatureNode], content: '' })
    applySignature(editor, data.applied['wesley@lalaaji.com'], true)
    // (StarterKit keeps an empty paragraph after a block, for the caret.)
    expect(editor.getHTML()).toMatch(/^<p><\/p><p><\/p><div data-signature="sig_a"><p>Wesley<br>Lalaaji<\/p><\/div>/)
    applySignature(editor, { id: 'sig_c', html: '<p>Bram</p>' }, false)
    expect(editor.getHTML()).toContain('<div data-signature="sig_c"><p>Bram</p></div>')
    expect(editor.getHTML()).not.toContain('Wesley')
    applySignature(editor, null, true)
    expect(editor.getHTML()).not.toContain('data-signature')
    // A body that is not new gets none added.
    applySignature(editor, data.applied['wesley@lalaaji.com'], false)
    expect(editor.getHTML()).not.toContain('data-signature')
    // A saved body parses its signature back into the block.
    const saved = new Editor({ extensions: [StarterKit, SignatureNode], content: '<p>Hi</p><div data-signature="sig_a"><p>Wesley</p></div>' })
    expect(saved.getHTML()).toMatch(/^<p>Hi<\/p><div data-signature="sig_a"><p>Wesley<\/p><\/div>/)
    expect(saved.getText()).toContain('-- \nWesley')
  })
})
