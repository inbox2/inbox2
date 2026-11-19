import { useEffect, useRef } from 'react'
import { fetchText } from './fetchBytes'
import styles from './Preview.module.css'

/* Code and plain text in a read-only CodeMirror: line numbers, highlighting by
   file name, and a virtual viewport, so a 5 MB log scrolls without freezing. */
export default function CodePreview({ node, url, onReady, onError }) {
  const host = useRef(null)
  useEffect(() => {
    const ctl = new AbortController()
    let view
    ;(async () => {
      const [{ EditorView, lineNumbers }, { EditorState }, lang, { languages }, text] = await Promise.all([
        import('@codemirror/view'), import('@codemirror/state'), import('@codemirror/language'),
        import('@codemirror/language-data'), fetchText(url, ctl.signal),
      ])
      const desc = lang.LanguageDescription.matchFilename(languages, node.name)
      const support = desc ? await desc.load().catch(() => null) : null
      if (ctl.signal.aborted || !host.current) return
      view = new EditorView({
        parent: host.current,
        state: EditorState.create({
          doc: text,
          extensions: [
            lineNumbers(), EditorState.readOnly.of(true), EditorView.editable.of(false), EditorView.lineWrapping,
            lang.syntaxHighlighting(lang.defaultHighlightStyle), ...(support ? [support] : []),
          ],
        }),
      })
      onReady()
    })().catch((e) => { if (!ctl.signal.aborted) onError(e) })
    return () => { ctl.abort(); view?.destroy() }
  }, [url, node.name, onReady, onError])
  return <div ref={host} className={styles.code} />
}
