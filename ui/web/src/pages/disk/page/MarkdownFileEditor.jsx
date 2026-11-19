import { useCallback, useEffect, useMemo, useRef, useState } from 'react'
import { useNavigate } from 'react-router'
import RichEditor from '../../../components/RichEditor'
import Breadcrumbs from '../../../components/Breadcrumbs'
import Skeleton from '../../../components/Skeleton'
import { ActionIcon } from '../../../components/FileTypeIcon'
import { MgmtButton } from '../../../components/management'
import diskApi from '../../../lib/disk/api'
import { pathSegments } from '../../../lib/disk/paths'
import { markdownToHtml, toMarkdown } from '../../../lib/disk/pages'
import { crumbUrl, drivePath, pathUrl, previewUrl, ROLE, roleAtLeast } from '../../../lib/disk/model'
import useUploadStore, { UPLOAD_STATE as S } from '../../../stores/uploadStore'
import { pageExtensions } from './extensions'
import styles from './Page.module.css'

/**
 * "Edit as page" on a .md file (spec F6): the page editor over the file's
 * markdown. Saving writes the markdown back as a new version of the same file
 * through the upload queue (POST /uploads with node_id), so history and the
 * upload panel work as for any upload. One person at a time: there is no live
 * collaboration on a file, unlike a page.
 *
 *   ctx   the Disk outlet context; node  the file (GET /nodes/:id)
 */
export default function MarkdownFileEditor({ ctx, node }) {
  const { orgId } = ctx
  const navigate = useNavigate()
  const [html, setHtml] = useState(null)
  const [error, setError] = useState(null)
  const [status, setStatus] = useState('')
  const editorRef = useRef(null)
  const dirty = useRef(false)
  const editable = roleAtLeast(node.access?.role, ROLE.EDIT) && ctx.writable !== false

  useEffect(() => {
    let live = true
    diskApi.download(orgId, node.id)
      .then(({ download }) => fetch(download.url))
      .then((res) => { if (!res.ok) throw new Error(`The file didn't load (${res.status})`); return res.text() })
      .then(markdownToHtml)
      .then((h) => { if (live) setHtml(h) })
      .catch((e) => { if (live) setError(e) })
    return () => { live = false }
  }, [orgId, node.id])

  const save = useCallback(async () => {
    const ed = editorRef.current
    if (!ed || !dirty.current) return
    dirty.current = false
    setStatus('Saving...')
    const file = new File([toMarkdown(ed.getJSON())], node.name, { type: 'text/markdown' })
    const { enqueueVersion } = await import('../../../lib/disk/upload')
    const id = enqueueVersion(orgId, node, file)
    try {
      await new Promise((resolve, reject) => {
        const check = (st) => {
          const it = st.items.find((x) => x.id === id)
          if (it?.state === S.DONE) { unsub(); resolve() }
          if (it && [S.ERROR, S.CANCELLED].includes(it.state)) { unsub(); reject(new Error(it.error || 'The upload stopped')) }
        }
        const unsub = useUploadStore.subscribe(check)
        check(useUploadStore.getState())
      })
      setStatus('Saved as a new version')
    } catch (e) {
      dirty.current = true
      setStatus(`Not saved: ${e.message}`)
    }
  }, [orgId, node])

  // Ctrl/Cmd+S saves now.
  useEffect(() => {
    const onKey = (e) => { if ((e.metaKey || e.ctrlKey) && e.key === 's') { e.preventDefault(); save() } }
    window.addEventListener('keydown', onKey)
    return () => window.removeEventListener('keydown', onKey)
  }, [save])
  useEffect(() => {
    const beforeUnload = (e) => { if (dirty.current) e.preventDefault() }
    window.addEventListener('beforeunload', beforeUnload)
    return () => window.removeEventListener('beforeunload', beforeUnload)
  }, [])

  const extensions = useMemo(() => pageExtensions({ orgId, onOpenFile: () => {} }), [orgId])
  const segments = pathSegments(node.drive, node.path || [])
  const folderPath = (node.path || []).slice(0, -1)
  const done = async () => {
    await save()
    if (dirty.current) return // the save failed: stay, with the reason in the bar, so the edits aren't lost
    navigate(previewUrl(folderPath.length ? pathUrl(folderPath) : drivePath(node.drive), node))
  }

  return (
    <div className={`management ${styles.shell} ${styles.single}`}>
      <main className={styles.main}>
        <div className={styles.bar}>
          <div className={styles.crumbs}><Breadcrumbs segments={segments} onNavigate={(seg) => navigate(crumbUrl(node.drive, node.path || [], segments.indexOf(seg)))} /></div>
          <span className={styles.status} role="status">{!editable ? 'View only' : status || 'Each save adds a new version'}</span>
          {editable && <MgmtButton size="sm" variant="glass" onClick={save}><ActionIcon name="upload" />Save</MgmtButton>}
          <MgmtButton size="sm" variant="primary" onClick={done}>Done</MgmtButton>
        </div>
        <article className={styles.doc}>
          <h1 className={styles.title}>{node.name}</h1>
          <p className={styles.by}>A markdown file, edited as a page.</p>
          {error && <p className={styles.error} role="alert">{error.message}</p>}
          {html === null && !error && <Skeleton variant="text" count={8} />}
          {html !== null && (
            <RichEditor
              content={html}
              editable={editable}
              toolbar={false}
              autofocus={false}
              placeholder=""
              extraExtensions={extensions}
              onUpdate={() => { dirty.current = true; setStatus('Not saved yet') }}
              onEditor={(ed) => { editorRef.current = ed }}
              className={styles.editor}
            />
          )}
        </article>
      </main>
    </div>
  )
}
