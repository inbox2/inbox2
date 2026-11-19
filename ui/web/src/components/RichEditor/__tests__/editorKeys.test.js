import { describe, it, expect, vi, afterEach } from 'vitest'
import { handleEditorKeyDown, isFunctionKeyText } from '../editorKeys'

const key = (over = {}) => ({ key: 'End', metaKey: false, ctrlKey: false, altKey: false, shiftKey: false, ...over })

const withSelection = (modify) => {
  globalThis.window = { getSelection: () => ({ modify }) }
}

afterEach(() => { delete globalThis.window })

describe('handleEditorKeyDown', () => {
  it('moves to the line boundary and swallows End', () => {
    const modify = vi.fn()
    withSelection(modify)
    expect(handleEditorKeyDown(null, key())).toBe(true)
    expect(modify).toHaveBeenCalledWith('move', 'forward', 'lineboundary')
  })

  it('extends the selection for shift+Home', () => {
    const modify = vi.fn()
    withSelection(modify)
    expect(handleEditorKeyDown(null, key({ key: 'Home', shiftKey: true }))).toBe(true)
    expect(modify).toHaveBeenCalledWith('extend', 'backward', 'lineboundary')
  })

  it('leaves other keys and modified Home/End alone', () => {
    withSelection(vi.fn())
    expect(handleEditorKeyDown(null, key({ key: 'a' }))).toBe(false)
    expect(handleEditorKeyDown(null, key({ metaKey: true }))).toBe(false)
  })
})

describe('isFunctionKeyText', () => {
  it('drops AppKit function-key characters, keeps real text', () => {
    expect(isFunctionKeyText('')).toBe(true)   // NSEndFunctionKey
    expect(isFunctionKeyText('contact')).toBe(false)
    expect(isFunctionKeyText('')).toBe(false)  // Apple logo
  })
})
