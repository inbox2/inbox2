import { useEffect, useRef } from 'react'
import Popover from '../../../components/Popover'
import styles from './Page.module.css'

// The block types "/" offers (spec F6). Each runs on a chain after the "/" is removed.
const BLOCKS = [
  { label: 'Text', run: (c) => c.setParagraph() },
  { label: 'Heading 1', hint: '#', run: (c) => c.setHeading({ level: 1 }) },
  { label: 'Heading 2', hint: '##', run: (c) => c.setHeading({ level: 2 }) },
  { label: 'Heading 3', hint: '###', run: (c) => c.setHeading({ level: 3 }) },
  { label: 'Bulleted list', hint: '-', run: (c) => c.toggleBulletList() },
  { label: 'Numbered list', hint: '1.', run: (c) => c.toggleOrderedList() },
  { label: 'To-do list', hint: '[ ]', run: (c) => c.toggleTaskList() },
  { label: 'Table', run: (c) => c.insertTable({ rows: 3, cols: 3, withHeaderRow: true }) },
  { label: 'Code block', hint: '```', run: (c) => c.toggleCodeBlock() },
  { label: 'Quote', hint: '>', run: (c) => c.toggleBlockquote() },
  { label: 'Callout', run: (c) => c.setCallout() },
  { label: 'Divider', hint: '---', run: (c) => c.setHorizontalRule() },
  { label: 'File from Disk', action: 'file' },
  { label: 'Sub-page', action: 'subpage' },
]

/** The "/" block menu at the caret. Arrows move, Enter picks, Escape closes. */
/** `menuClassName` / `itemClassName` re-skin it for another host (Lore's dark page); Disk's management skin otherwise. */
export default function SlashMenu({ editor, from, anchorRect, onClose, onPickFile, onSubPage, menuClassName, itemClassName }) {
  const ref = useRef(null)
  useEffect(() => { ref.current?.querySelector('button')?.focus() }, [])

  const pick = (b) => {
    const chain = editor.chain().focus().deleteRange({ from, to: from + 1 })
    if (b.run) b.run(chain).run()
    else chain.run()
    onClose()
    if (b.action === 'file') onPickFile()
    if (b.action === 'subpage') onSubPage()
  }
  const onKeyDown = (e) => {
    const items = [...ref.current.querySelectorAll('button')]
    const i = items.indexOf(document.activeElement)
    const to = { ArrowDown: items[(i + 1) % items.length], ArrowUp: items[(i - 1 + items.length) % items.length] }[e.key]
    if (to) { e.preventDefault(); to.focus() }
    if (e.key === 'Escape') { e.preventDefault(); onClose(); editor.commands.focus() }
  }
  return (
    <Popover open anchorRect={anchorRect} onClose={onClose} className={menuClassName || `management ${styles.slash}`}>
      <div ref={ref} role="menu" tabIndex={-1} aria-label="Insert a block" onKeyDown={onKeyDown}>
        {BLOCKS.filter((b) => (b.action === 'file' ? !!onPickFile : b.action === 'subpage' ? !!onSubPage : true)).map((b) => (
          <button key={b.label} type="button" role="menuitem" className={itemClassName || styles.slashItem} onClick={() => pick(b)}>
            {b.label}{b.hint && <kbd>{b.hint}</kbd>}
          </button>
        ))}
      </div>
    </Popover>
  )
}
