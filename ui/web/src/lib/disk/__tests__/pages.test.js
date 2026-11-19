import { describe, it, expect } from 'vitest'
import { toMarkdown, pageTitle, bytesToBase64, base64ToBytes } from '../pages'

const t = (text, marks) => ({ type: 'text', text, ...(marks ? { marks } : {}) })
const p = (...content) => ({ type: 'paragraph', content })

describe('page markdown', () => {
  it('writes headings, marks, lists, to-dos, code, quotes, callouts, tables and file cards', () => {
    const doc = {
      type: 'doc',
      content: [
        { type: 'heading', attrs: { level: 2 }, content: [t('Plan')] },
        p(t('A '), t('bold', [{ type: 'bold' }]), t(' and '), t('x', [{ type: 'code' }]), t(' and a '), t('link', [{ type: 'link', attrs: { href: 'https://x.test' } }])),
        { type: 'bulletList', content: [{ type: 'listItem', content: [p(t('one'))] }, { type: 'listItem', content: [p(t('two'))] }] },
        { type: 'orderedList', attrs: { start: 3 }, content: [{ type: 'listItem', content: [p(t('three'))] }] },
        { type: 'taskList', content: [{ type: 'taskItem', attrs: { checked: true }, content: [p(t('done'))] }, { type: 'taskItem', attrs: { checked: false }, content: [p(t('todo'))] }] },
        { type: 'codeBlock', attrs: { language: 'rb' }, content: [t('puts 1')] },
        { type: 'blockquote', content: [p(t('said'))] },
        { type: 'callout', content: [p(t('note'))] },
        { type: 'table', content: [
          { type: 'tableRow', content: [{ type: 'tableHeader', content: [p(t('A'))] }, { type: 'tableHeader', content: [p(t('B|C'))] }] },
          { type: 'tableRow', content: [{ type: 'tableCell', content: [p(t('1'))] }, { type: 'tableCell', content: [p(t('2'))] }] },
        ] },
        { type: 'diskFile', attrs: { nodeId: 'dnd_1', name: 'a.pdf' } },
        { type: 'horizontalRule' },
      ],
    }
    expect(toMarkdown(doc)).toBe([
      '## Plan',
      'A **bold** and `x` and a [link](https://x.test)',
      '- one\n- two',
      '3. three',
      '- [x] done\n- [ ] todo',
      '```rb\nputs 1\n```',
      '> said',
      '> [!NOTE]\n> note',
      '| A | B\\|C |\n| --- | --- |\n| 1 | 2 |',
      '[File: a.pdf](disk://dnd_1)',
      '---',
    ].join('\n\n') + '\n')
  })

  it('escapes markdown in text and handles an empty page', () => {
    expect(toMarkdown({ type: 'doc', content: [p(t('*not* # bold'))] })).toBe('\\*not\\* \\# bold\n')
    expect(toMarkdown({ type: 'doc', content: [] })).toBe('\n')
  })

  it('takes a title from the first line', () => {
    expect(pageTitle('\n\n## Launch plan\nbody')).toBe('Launch plan')
    expect(pageTitle('')).toBe('Untitled')
  })

  it('round-trips ydoc bytes through base64, including large ones', () => {
    const bytes = new Uint8Array(100_000).map((_, i) => i % 256)
    expect(base64ToBytes(bytesToBase64(bytes))).toEqual(bytes)
  })
})

describe('replaced pages', async () => {
  const { isReplacement, PAGE_REPLACED } = await import('../pages')
  it('treats a page with no Yjs state as replaced, to load before saving', () => {
    expect(PAGE_REPLACED).toBe('page_replaced')
    expect(isReplacement({ ydoc: null, markdown: '# agent wrote this' })).toBe(true)
    expect(isReplacement({ ydoc: 'AQID', markdown: '' })).toBe(false)
  })
})
