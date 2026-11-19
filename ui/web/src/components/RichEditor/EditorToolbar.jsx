import { useState, useRef, useEffect } from 'react'
import ToolbarGroup, { ToolbarButton } from '../ToolbarGroup'
import Modal from '../Modal/Modal'
import Button from '../Button/Button'
import styles from './EditorToolbar.module.css'

export default function EditorToolbar({ editor }) {
  // `prompt` is null when closed, otherwise { kind: 'link' | 'image', title }.
  const [prompt, setPrompt] = useState(null)
  const [value, setValue] = useState('')
  const inputRef = useRef(null)

  useEffect(() => {
    if (prompt) {
      const t = setTimeout(() => inputRef.current?.focus(), 50)
      return () => clearTimeout(t)
    }
    return undefined
  }, [prompt])

  const openPrompt = (next) => { setValue(''); setPrompt(next) }

  if (!editor) return null

  const btn = (icon, label, action, isActive) => (
    <ToolbarButton
      icon={icon}
      onClick={action}
      variant={isActive?.() ? 'active' : undefined}
    >
      {label}
    </ToolbarButton>
  )

  const closePrompt = () => setPrompt(null)

  const submitPrompt = () => {
    const url = value.trim()
    if (url) {
      if (prompt?.kind === 'link') {
        editor.chain().focus().setLink({ href: url }).run()
      } else if (prompt?.kind === 'image') {
        editor.chain().focus().setImage({ src: url }).run()
      }
    }
    closePrompt()
  }

  return (
    <div className={styles.toolbar}>
      <ToolbarGroup>
        {btn('bold', null, () => editor.chain().focus().toggleBold().run(),
          () => editor.isActive('bold'))}
        {btn('italic', null, () => editor.chain().focus().toggleItalic().run(),
          () => editor.isActive('italic'))}
        {btn('strikethrough', null, () => editor.chain().focus().toggleStrike().run(),
          () => editor.isActive('strike'))}
      </ToolbarGroup>

      <ToolbarGroup>
        {btn('textformat.size', null, () => editor.chain().focus().toggleHeading({ level: 2 }).run(),
          () => editor.isActive('heading', { level: 2 }))}
      </ToolbarGroup>

      <ToolbarGroup>
        {btn('list.bullet', null, () => editor.chain().focus().toggleBulletList().run(),
          () => editor.isActive('bulletList'))}
        {btn('list.number', null, () => editor.chain().focus().toggleOrderedList().run(),
          () => editor.isActive('orderedList'))}
      </ToolbarGroup>

      <ToolbarGroup>
        {btn('link', null, () => {
          if (editor.isActive('link')) {
            editor.chain().focus().unsetLink().run()
          } else {
            openPrompt({ kind: 'link', title: 'Add link', label: 'URL', placeholder: 'https://example.com' })
          }
        }, () => editor.isActive('link'))}
        {btn('photo', null, () => {
          openPrompt({ kind: 'image', title: 'Add image', label: 'Image URL', placeholder: 'https://example.com/image.png' })
        })}
      </ToolbarGroup>

      <Modal open={!!prompt} onClose={closePrompt} showClose={false} className={styles.promptModal}>
        <h3 className={styles.promptTitle}>{prompt?.title}</h3>
        <input
          ref={inputRef}
          type="url"
          className={styles.promptInput}
          value={value}
          placeholder={prompt?.placeholder}
          aria-label={prompt?.label}
          onChange={(e) => setValue(e.target.value)}
          onKeyDown={(e) => {
            if (e.key === 'Enter') { e.preventDefault(); submitPrompt() }
          }}
        />
        <div className={styles.promptActions}>
          <Button variant="secondary" onClick={closePrompt}>Cancel</Button>
          <Button onClick={submitPrompt}>Insert</Button>
        </div>
      </Modal>
    </div>
  )
}
