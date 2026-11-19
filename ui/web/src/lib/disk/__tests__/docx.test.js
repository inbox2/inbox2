// @vitest-environment jsdom
import { describe, it, expect } from 'vitest'
import { convertDocx } from '../docx'

const NS = 'xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"'
const run = (t, pr = '') => `<w:r>${pr ? `<w:rPr>${pr}</w:rPr>` : ''}<w:t xml:space="preserve">${t}</w:t></w:r>`
const p = (body, ppr = '') => `<w:p>${ppr ? `<w:pPr>${ppr}</w:pPr>` : ''}${body}</w:p>`
const item = (t, numId, lvl = 0) => p(run(t), `<w:numPr><w:ilvl w:val="${lvl}"/><w:numId w:val="${numId}"/></w:numPr>`)
const doc = (body) => `<w:document ${NS}><w:body>${body}</w:body></w:document>`

const styles = `<w:styles ${NS}><w:style w:styleId="Kop1"><w:name w:val="heading 1"/></w:style><w:style w:styleId="Title"><w:name w:val="Title"/></w:style></w:styles>`
const numbering = `<w:numbering ${NS}>
  <w:abstractNum w:abstractNumId="0"><w:lvl w:ilvl="0"><w:numFmt w:val="bullet"/></w:lvl><w:lvl w:ilvl="1"><w:numFmt w:val="bullet"/></w:lvl></w:abstractNum>
  <w:abstractNum w:abstractNumId="1"><w:lvl w:ilvl="0"><w:numFmt w:val="decimal"/></w:lvl></w:abstractNum>
  <w:num w:numId="1"><w:abstractNumId w:val="0"/></w:num><w:num w:numId="2"><w:abstractNumId w:val="1"/></w:num>
</w:numbering>`
const rels = `<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId9" Target="https://example.com/a b" TargetMode="External"/><Relationship Id="rId10" Target="javascript:alert(1)" TargetMode="External"/></Relationships>`

describe('convertDocx', () => {
  it('turns headings, formatting, links, lists and tables into markdown, and counts images it leaves out', () => {
    const body = [
      p(run('Plan'), '<w:pStyle w:val="Title"/>'),
      p(run('Scope'), '<w:pStyle w:val="Kop1"/>'),
      p(run('We ') + run('ship ', '<w:b/>') + run('soon', '<w:b/><w:i/>') + run(' and ') + run('not this', '<w:b w:val="0"/><w:strike/>')),
      p(`<w:hyperlink r:id="rId9">${run('site')}</w:hyperlink>${run(' ')}<w:hyperlink r:id="rId10">${run('bad')}</w:hyperlink>`),
      item('one', 1), item('nested', 1, 1), item('two', 1),
      item('first', 2), item('second', 2),
      `<w:tbl><w:tr><w:tc>${p(run('Name'))}</w:tc><w:tc>${p(run('Qty'))}</w:tc></w:tr><w:tr><w:tc>${p(run('a|b'))}</w:tc><w:tc>${p(run('2'))}</w:tc></w:tr></w:tbl>`,
      p('<w:r><w:drawing/></w:r>'),
      `<w:sdt><w:sdtContent>${p(run('In a control'))}</w:sdtContent></w:sdt>`,
    ].join('')
    const { markdown, dropped } = convertDocx({ doc: doc(body), rels, numbering, styles })
    expect(markdown).toBe([
      '# Plan',
      '# Scope',
      'We **ship** ***soon*** and ~~not this~~',
      '[site](https://example.com/a%20b) bad',
      '- one\n   - nested\n- two',
      '1. first\n1. second',
      '| Name | Qty |\n| --- | --- |\n| a\\|b | 2 |',
      'In a control',
    ].join('\n\n') + '\n')
    expect(dropped.images).toBe(1)
  })

  it('handles a document with no numbering, styles or relationships', () => {
    expect(convertDocx({ doc: doc(p(run('Just text'))), rels: null, numbering: null, styles: null }).markdown).toBe('Just text\n')
  })
})
