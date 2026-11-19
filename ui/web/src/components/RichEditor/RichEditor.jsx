import { useEffect, useMemo } from 'react'
import { useEditor, EditorContent } from '@tiptap/react'
import StarterKit from '@tiptap/starter-kit'
import Image from '@tiptap/extension-image'
import Placeholder from '@tiptap/extension-placeholder'
import Collaboration from '@tiptap/extension-collaboration'
import CollaborationCaret from '@tiptap/extension-collaboration-caret'
import EditorToolbar from './EditorToolbar'
import { handleEditorKeyDown, isFunctionKeyText } from './editorKeys'
import styles from './RichEditor.module.css'

// Steady per-person caret colours, readable on the light and dark editors.
const CARET_COLORS = ['#2f7ad6', '#2e8f5b', '#c2408f', '#c98a1b', '#8a5bd6', '#1f9aa5', '#e06a3d']
function caretUser(user) {
  const name = user?.display_name || user?.username || 'Someone'
  const key = String(user?.id || name)
  let h = 0
  for (let i = 0; i < key.length; i++) h = (h * 31 + key.charCodeAt(i)) >>> 0
  return { name, color: CARET_COLORS[h % CARET_COLORS.length] }
}

export default function RichEditor({
  content = '',
  placeholder = 'Write your message...',
  onUpdate,
  yjsDoc,
  provider,
  editable = true,
  autofocus = 'end',
  // For richer hosts (Disk pages): more blocks, no toolbar, a key hook, the editor instance.
  extraExtensions = [],
  toolbar = true,
  onKeyDown,
  onEditor,
  className,
}) {
  const extensions = useMemo(() => {
    const exts = [
      StarterKit.configure({
        link: { openOnClick: false },
        // Yjs brings its own undo stack; StarterKit's must be off or the two
        // fight. (The option is `undoRedo` since tiptap 3 — the old `history`
        // key was silently ignored, leaving both enabled.)
        undoRedo: yjsDoc ? false : undefined,
      }),
      Image,
      Placeholder.configure({ placeholder }),
      ...extraExtensions,
    ]

    if (yjsDoc) {
      exts.push(
        Collaboration.configure({
          document: yjsDoc,
        })
      )

      if (provider?.awareness) {
        exts.push(
          CollaborationCaret.configure({
            provider,
            // Without a user the carets read "User: <client id>" and presence lists no names.
            user: caretUser(provider.user),
          })
        )
      }
    }

    return exts
  }, [yjsDoc, provider, placeholder, extraExtensions])

  const editor = useEditor({
    extensions,
    content: yjsDoc ? undefined : content,
    editable,
    autofocus,
    // dir="auto" on the contenteditable: the paragraph direction follows the
    // first strong character the user types, so an RTL draft composes RTL.
    editorProps: {
      attributes: { dir: 'auto' },
      handleKeyDown: (view, event) => onKeyDown?.(view, event) || handleEditorKeyDown(view, event),
      handleTextInput: (_v, _from, _to, text) => isFunctionKeyText(text),
    },
    onUpdate: ({ editor: ed }) => {
      onUpdate?.({
        html: ed.getHTML(),
        text: ed.getText(),
        json: ed.getJSON(),
      })
    },
  })

  useEffect(() => { if (editor) onEditor?.(editor) }, [editor, onEditor])
  useEffect(() => { editor?.setEditable(editable) }, [editor, editable])

  return (
    <div className={[styles.editor, className].filter(Boolean).join(' ')}>
      {toolbar && <EditorToolbar editor={editor} />}
      <div className={styles.content}>
        <EditorContent editor={editor} />
      </div>
    </div>
  )
}
