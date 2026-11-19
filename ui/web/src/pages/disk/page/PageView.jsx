import { useCallback, useEffect, useMemo, useRef, useState } from 'react'
import { useNavigate } from 'react-router'
import * as Y from 'yjs'
import RichEditor from '../../../components/RichEditor'
import Breadcrumbs from '../../../components/Breadcrumbs'
import Avatar from '../../../components/Avatar'
import Skeleton from '../../../components/Skeleton'
import FileTypeIcon, { ActionIcon } from '../../../components/FileTypeIcon'
import { MgmtButton, MgmtConfirm } from '../../../components/management'
import YjsActionCableProvider from '../../../lib/YjsActionCableProvider'
import diskApi from '../../../lib/disk/api'
import { pathSegments } from '../../../lib/disk/paths'
import { PAGE_REPLACED, SEED_CLIENT_ID, base64ToBytes, bytesToBase64, isReplacement, markdownToHtml, toMarkdown } from '../../../lib/disk/pages'
import { crumbUrl, drivePath, pathUrl, previewUrl, ROLE, roleAtLeast, shortId } from '../../../lib/disk/model'
import { saveUrl } from '../../../lib/disk/download'
import useDiskStore from '../../../stores/diskStore'
import useAuth from '../../../hooks/useAuth'
import { registerUnsaved } from '../../../lib/unsavedWork'
import { pageExtensions } from './extensions'
import SlashMenu from './SlashMenu'
import PageTree from './PageTree'
import PageHistory from './PageHistory'
import { MoveDialog, PeopleDialog } from '../DiskDialogs'
import useSealed from '../sealed/useSealed'
import { SealedBanner } from '../sealed/SealedUI'
import useSealedStore from '../../../stores/sealedStore'
import styles from './Page.module.css'

const SAVE_DEBOUNCE_MS = 2000

/**
 * A Disk page, full screen (spec F6; mockup: the wiki view). The shared
 * RichEditor over a Y.Doc, live over DiskPageChannel, saved as a snapshot
 * (ydoc + markdown) a couple of seconds after each change.
 *
 *   ctx   the Disk outlet context; node  the page (GET /nodes/:id)
 */
export default function PageView({ ctx, node }) {
  const { orgId, slug, drives, people } = ctx
  const { user } = useAuth()
  const navigate = useNavigate()
  const [loaded, setLoaded] = useState(null) // { doc, provider }
  const [role, setRole] = useState(null)
  const [error, setError] = useState(null)
  const [status, setStatus] = useState('Saved')
  const [revoked, setRevoked] = useState(false)
  const [present, setPresent] = useState([])
  const [dialog, setDialog] = useState(null)
  const [slash, setSlash] = useState(null) // { from, rect }
  const editorRef = useRef(null)
  const [editor, setEditor] = useState(null) // the same instance, as state, for what renders from it
  // Channel events beyond the Yjs relay. A ref, so the provider made at load time always calls the latest.
  const onChannel = useRef(() => {})
  const revision = useRef(0)
  const restoredFrom = useRef(null)
  const dirty = useRef(false)
  const timer = useRef(null)
  const saving = useRef(null)
  const saveRef = useRef(null) // the latest save, for the re-save a landed save schedules
  const importInput = useRef(null)
  // A markdown-only replacement (an agent over MCP) drops the Yjs state: the page is reloaded as a new document.
  const [generation, setGeneration] = useState(0)
  // Typed and not yet stored (or still on its way): offered to copy if the session ends (SignedOutScreen).
  useEffect(() => (editor ? registerUnsaved(`Page: ${node.name || 'Untitled page'}`, () => (dirty.current || saving.current ? editor.getText() : '')) : undefined), [editor, node.name])
  const [replaced, setReplaced] = useState(null) // { by, local } for the notice; local = unsaved edits as markdown
  const editable = roleAtLeast(role, ROLE.EDIT) && !revoked
  // Sealed (6.10): opened here with the scope key; updates are sealed and stored in order, snapshots now and then.
  const sealedState = useSealed(orgId, node)
  const scope = node.sealed ? sealedState.scope : null
  const shown = scope && sealedState.lib ? sealedState.lib.openNames(scope, [node])[0] : node

  // Load the snapshot, then go live.
  useEffect(() => {
    if (!node.sealed) return undefined
    if (!scope) return undefined
    let live = true
    const doc = new Y.Doc()
    let provider
    Promise.all([diskApi.page(orgId, node.id), import('../../../lib/disk/sealed'), import('../../../lib/disk/sealedPage')])
      .then(async ([{ page, role: r }, lib, { default: SealedPageProvider }]) => {
        const { state, seq } = await lib.openSealedPage(scope, node.id, page)
        if (!live) return
        Y.applyUpdate(doc, state, 'server')
        setRole(r)
        provider = new SealedPageProvider(doc, node.id, { user, orgId, scope, seq, onMessage: (m) => onChannel.current(m) })
        provider.awareness.on('change', () => queueMicrotask(() => {
          const states = [...provider.awareness.getStates().entries()].filter(([id]) => id !== doc.clientID)
          setPresent(states.map(([id, st]) => ({ id, name: st.user?.name || 'Someone' })))
        }))
        setLoaded({ doc, provider, markdown: null, sealed: true })
      })
      .catch((e) => { if (live) setError(e) })
    return () => {
      live = false
      provider?.destroy()
      doc.destroy()
    }
  }, [orgId, node.id, node.sealed, scope, user, generation])

  useEffect(() => {
    if (node.sealed) return undefined
    let live = true
    const doc = new Y.Doc()
    let provider
    diskApi.page(orgId, node.id).then(({ page, role: r }) => {
      if (!live) return
      if (page.ydoc) Y.applyUpdate(doc, base64ToBytes(page.ydoc), 'server')
      revision.current = page.revision || 0
      setRole(r)
      provider = new YjsActionCableProvider(doc, node.id, {
        user,
        channel: 'DiskPageChannel',
        params: { org_id: orgId, node_id: node.id },
        ignoreOwn: false, // the server never echoes; two tabs of one person must still sync
        syncOnJoin: true,
        onMessage: (m) => onChannel.current(m),
      })
      // Awareness changes fire while the editor's caret extension is being built (inside a render): defer.
      provider.awareness.on('change', () => queueMicrotask(() => {
        const states = [...provider.awareness.getStates().entries()].filter(([id]) => id !== doc.clientID)
        setPresent(states.map(([id, st]) => ({ id, name: st.user?.name || 'Someone' })))
      }))
      setLoaded({ doc, provider, markdown: isReplacement(page) ? page.markdown : null })
    }).catch((e) => { if (live) setError(e) })
    return () => {
      live = false
      provider?.destroy()
      doc.destroy()
    }
  }, [orgId, node.id, node.sealed, user, generation])

  // The page was replaced on the server (no ydoc). Keep what was typed here and
  // not saved, so the person can copy or re-apply it; never save it over the new version.
  const rebuild = useCallback((by, unsaved) => {
    const ed = editorRef.current
    const local = unsaved && ed ? toMarkdown(ed.getJSON()) : null
    dirty.current = false
    clearTimeout(timer.current)
    setReplaced({ by, local })
    editorRef.current = null
    setEditor(null)
    setLoaded(null)
    setGeneration((g) => g + 1)
  }, [])

  const save = useCallback(async () => {
    const editor = editorRef.current
    if (!loaded || !editor || !dirty.current) return
    if (saving.current) return saving.current
    dirty.current = false
    setStatus('Saving...')
    // A save landed. Edits made while it was in flight were not in it (their
    // debounced save found this one running and joined it), so save again.
    const settled = () => {
      if (!dirty.current) { setStatus('Saved'); return }
      setStatus('Editing')
      clearTimeout(timer.current)
      timer.current = setTimeout(() => saveRef.current?.(), SAVE_DEBOUNCE_MS)
    }
    if (loaded.sealed) {
      // Each edit is already stored as a sealed update; this compacts them into a snapshot (6.10).
      saving.current = (async () => {
        try {
          const { sealedEndpoints } = await import('../../../lib/disk/sealed')
          for (let tries = 0; ; tries++) {
            try {
              await loaded.provider.queue
              await sealedEndpoints.pageSnapshot(orgId, node.id, loaded.provider.snapshotBody())
              settled()
              return
            } catch (e) {
              if (e.status !== 409 || tries > 2) throw e
              if (e.data?.current_epoch && e.data.current_epoch !== loaded.provider.scope.epoch) {
                await useSealedStore.getState().reopen(orgId, loaded.provider.scope.id)
                throw new Error('Someone renewed the key. Reopening the page.', { cause: e })
              }
              await loaded.provider.catchUp()
            }
          }
        } catch (e) {
          dirty.current = true
          setStatus(`Not saved: ${e.message}`)
        } finally {
          saving.current = null
        }
      })()
      return saving.current
    }
    const body = () => ({
      ydoc: bytesToBase64(Y.encodeStateAsUpdate(loaded.doc)),
      markdown: toMarkdown(editor.getJSON()),
      base_revision: revision.current,
      ...(restoredFrom.current ? { restored_from: restoredFrom.current } : {}),
    })
    saving.current = (async () => {
      try {
        for (let tries = 0; ; tries++) {
          try {
            const { page } = await diskApi.savePage(orgId, node.id, body())
            revision.current = page.revision
            restoredFrom.current = null
            settled()
            return
          } catch (e) {
            if (e.status !== 409 || tries > 2) throw e
            const { page } = await diskApi.page(orgId, node.id)
            // Replaced from markdown: load it first; what we were saving goes back to the person.
            if (isReplacement(page)) { rebuild('someone', true); return }
            // Someone saved since our base: fold their snapshot in (a CRDT merge) and save on top.
            Y.applyUpdate(loaded.doc, base64ToBytes(page.ydoc), 'server')
            revision.current = page.revision
          }
        }
      } catch (e) {
        dirty.current = true
        setStatus(`Not saved: ${e.message}`)
      } finally {
        saving.current = null
      }
    })()
    return saving.current
  }, [loaded, orgId, node.id, rebuild])
  useEffect(() => { saveRef.current = save }, [save])

  // Every local change schedules a save; remote changes are saved by whoever made them.
  useEffect(() => {
    if (!loaded) return undefined
    const onUpdate = (_u, origin) => {
      if (origin === loaded.provider || origin === 'server' || !editable) return
      dirty.current = true
      setStatus('Editing')
      clearTimeout(timer.current)
      timer.current = setTimeout(save, SAVE_DEBOUNCE_MS)
    }
    loaded.doc.on('update', onUpdate)
    const beforeUnload = (e) => { if (dirty.current) { save(); e.preventDefault() } }
    window.addEventListener('beforeunload', beforeUnload)
    return () => {
      loaded.doc.off('update', onUpdate)
      window.removeEventListener('beforeunload', beforeUnload)
      clearTimeout(timer.current)
      save()
    }
  }, [loaded, editable, save])

  useEffect(() => {
    onChannel.current = (m) => {
      if (m.type === 'page_saved') revision.current = Math.max(revision.current, m.revision)
      else if (m.type === 'epoch_changed') useSealedStore.getState().reopen(orgId, sealedState.scopeId).then(() => setGeneration((g) => g + 1))
      else if (m.type === 'sealed_error') setStatus(`Not saved: ${m.message}`)
      else if (m.type === 'role_changed') setRole(m.role)
      else if (m.type === 'access_revoked' || m.type === 'rejected') setRevoked(true)
      // An agent (or anyone over MCP) wrote markdown: drop the Yjs state and rebuild from it.
      else if (m.type === PAGE_REPLACED) rebuild(m.agent ? `${m.name || 'An agent'} (agent)` : (m.name || 'Someone'), dirty.current)
    }
  }, [rebuild, orgId, sealedState.scopeId])

  const onEditor = useCallback((ed) => {
    editorRef.current = ed
    setEditor(ed)
    // A page with markdown and no ydoc (made outside the editor, or replaced by an agent).
    // Every editor seeds it under the same fixed Yjs client id, so the identical seeds
    // from several people merge into one copy instead of repeating the text.
    if (loaded?.markdown && ed.isEmpty) {
      markdownToHtml(loaded.markdown).then((html) => {
        const own = loaded.doc.clientID
        loaded.doc.clientID = SEED_CLIENT_ID
        try { ed.commands.setContent(html) } finally { loaded.doc.clientID = own }
      })
    }
  }, [loaded])

  const openFile = useCallback((file) => {
    const parentPath = file.path?.length > 1 ? file.path.slice(0, -1) : [{ short_id: shortId(file.parent_id), name: 'folder', kind: 'folder' }]
    navigate(previewUrl(pathUrl(parentPath), file))
  }, [navigate])
  const extensions = useMemo(() => pageExtensions({ orgId, onOpenFile: openFile }), [orgId, openFile])

  // Slash menu: "/" in an empty block opens the block list at the caret.
  const onKeyDown = useCallback((view, event) => {
    if (event.key !== '/' || !editable) return false
    const { $from, empty } = view.state.selection
    if (!empty || $from.parent.textContent.length) return false
    const at = $from.pos
    requestAnimationFrame(() => {
      const c = view.coordsAtPos(at)
      setSlash({ from: at, rect: { top: c.top, bottom: c.bottom, left: c.left, right: c.right, width: 0, height: c.bottom - c.top } })
    })
    return false
  }, [editable])

  const done = async () => {
    await save()
    const parent = (node.path || []).at(-2)
    navigate(parent ? pathUrl(node.path.slice(0, -1)) : drivePath(node.drive))
  }
  const exportMd = () => {
    const md = toMarkdown(editorRef.current?.getJSON())
    saveUrl(URL.createObjectURL(new Blob([md], { type: 'text/markdown' })), `${node.name || 'page'}.md`)
  }
  // Import .md, or a .docx converted in this browser (images are left out and the status says so).
  const importMd = async (file) => {
    let md = null
    let left = 0
    if (/\.docx$/i.test(file.name)) {
      const { docxToMarkdown } = await import('../../../lib/disk/docx')
      const { markdown, dropped } = await docxToMarkdown(file).catch((e) => { setStatus(`Not imported: ${e.message}`); return {} })
      if (markdown == null) return
      md = markdown
      left = dropped.images
    }
    const html = await markdownToHtml(md ?? await file.text())
    editorRef.current?.commands.setContent(html)
    if (left) setStatus(`Imported without ${left === 1 ? 'one image' : `${left} images`}`)
  }
  const newSubPage = async () => {
    let child
    try {
      // A sealed page's children are sealed too: the server refuses a plain one there.
      ;({ node: child } = loaded?.sealed
        ? await (await import('../../../lib/disk/sealed')).createSealedChild({ orgId, scope: loaded.provider.scope, parentId: node.id, name: 'Untitled', kind: 'page' })
        : await diskApi.createPage(orgId, node.id, 'Untitled'))
    } catch (e) {
      setStatus(`Not created: ${e.message}`)
      return
    }
    const name = child.name || 'Untitled'
    editorRef.current?.chain().focus().insertContent({ type: 'paragraph', content: [{ type: 'text', text: name, marks: [{ type: 'link', attrs: { href: pathUrl([...(node.path || []), { ...child, name }]) } }] }] }).run()
    useDiskStore.getState().invalidate(orgId)
  }
  const restore = async (revisionNo) => {
    const { version } = await diskApi.pageVersion(orgId, node.id, revisionNo)
    editorRef.current?.commands.setContent(await markdownToHtml(version.markdown || ''))
    restoredFrom.current = revisionNo
    dirty.current = true
    await save()
    setDialog(null)
  }

  // Ctrl/Cmd+S saves now.
  useEffect(() => {
    const onKey = (e) => { if ((e.metaKey || e.ctrlKey) && e.key === 's') { e.preventDefault(); save() } }
    window.addEventListener('keydown', onKey)
    return () => window.removeEventListener('keydown', onKey)
  }, [save])

  const pageShare = node.share_id ? drives?.shares.find((x) => x.id === node.share_id) : null
  const segments = pathSegments(node.drive, node.path || [], { ...(pageShare?.sealed ? { [pageShare.root_node_id]: pageShare.name } : {}), ...sealedState.names, ...(shown.opened ? { [node.id]: shown.name } : {}) })
  const onCrumb = (seg) => {
    navigate(crumbUrl(node.drive, node.path || [], segments.indexOf(seg)))
  }
  const share = node.share_id ? drives?.shares.find((s) => s.id === node.share_id) : null

  if (node.sealed && !scope) {
    return (
      <div className={`management ${styles.shell} ${styles.center}`}>
        <FileTypeIcon kind="page" size={72} />
        <SealedBanner entry={sealedState.entry || { status: 'loading' }} />
        {(!sealedState.entry || sealedState.entry.status === 'loading') && <p>Opening the sealed page...</p>}
        <MgmtButton variant="glass" size="sm" onClick={done}>Back</MgmtButton>
      </div>
    )
  }

  return (
    <div className={`management ${styles.shell}`}>
      <PageTree orgId={orgId} slug={slug} page={node} nameOf={(p) => (p.sealed && scope && sealedState.lib ? sealedState.lib.openNames(scope, [p])[0].name : null)} />
      <main className={styles.main}>
        <div className={styles.bar}>
          <div className={styles.crumbs}><Breadcrumbs segments={segments} onNavigate={onCrumb} /></div>
          <span className={styles.present} aria-label={`${present.length} other ${present.length === 1 ? 'person' : 'people'} here`}>
            {present.slice(0, 5).map((p) => <Avatar key={p.id} name={p.name} size={24} />)}
          </span>
          <span className={styles.status} role="status">{revoked ? 'Your access to this page ended' : !editable && role ? 'View only' : status}</span>
          {/* A sealed page is shared with its scope, and keeps history only as snapshots. */}
          {!node.sealed && <MgmtButton size="sm" variant="glass" onClick={() => setDialog('share')}><ActionIcon name="share" />Share</MgmtButton>}
          {!node.sealed && <MgmtButton size="sm" variant="glass" onClick={() => setDialog('history')}><ActionIcon name="clock" />History</MgmtButton>}
          <MgmtButton size="sm" variant="glass" onClick={exportMd}><ActionIcon name="download" />Export .md</MgmtButton>
          {editable && <MgmtButton size="sm" variant="glass" onClick={() => importInput.current?.click()}><ActionIcon name="upload" />Import .md or .docx</MgmtButton>}
          <MgmtButton size="sm" variant="primary" onClick={done}>Done</MgmtButton>
          <input ref={importInput} type="file" accept=".md,.markdown,text/markdown,.docx" hidden onChange={(e) => {
            const f = e.target.files?.[0]
            e.target.value = ''
            if (f) setDialog({ type: 'import', file: f })
          }} />
        </div>
        <article className={styles.doc}>
          <h1 className={styles.title}>{shown.name}</h1>
          <p className={styles.by}>{node.modified_by ? `Edited by ${node.modified_by.name}` : ''}{present.length ? `, ${present.length + 1} people here` : ''}</p>
          {replaced && (
            <div className={styles.notice} role="status">
              <span>{replaced.by} replaced this page.{replaced.local ? ' You still have your unsaved edits.' : ''}</span>
              {replaced.local && <>
                <MgmtButton size="sm" variant="glass" onClick={() => navigator.clipboard?.writeText(replaced.local)}>Copy my edits as markdown</MgmtButton>
                {editable && <MgmtButton size="sm" variant="primary" onClick={async () => {
                  const ed = editorRef.current
                  if (ed) ed.commands.setContent(await markdownToHtml(replaced.local))
                  setReplaced(null)
                }}>Put my edits back</MgmtButton>}
              </>}
              <MgmtButton size="sm" variant="ghost" onClick={() => setReplaced(null)}>Dismiss</MgmtButton>
            </div>
          )}
          {error && <p className={styles.error} role="alert">{error.message}</p>}
          {!loaded && !error && <Skeleton variant="text" count={8} />}
          {loaded && (
            <RichEditor
              yjsDoc={loaded.doc}
              provider={loaded.provider}
              editable={editable}
              toolbar={false}
              autofocus={false}
              placeholder={editable ? 'Type / to add a block' : ''}
              extraExtensions={extensions}
              onKeyDown={onKeyDown}
              onEditor={onEditor}
              className={styles.editor}
            />
          )}
        </article>
      </main>

      {slash && editor && (
        <SlashMenu
          editor={editor}
          from={slash.from}
          anchorRect={slash.rect}
          onClose={() => setSlash(null)}
          onPickFile={() => setDialog('file')}
          onSubPage={() => newSubPage().catch((e) => setStatus(e.message))}
        />
      )}
      {dialog === 'history' && <PageHistory orgId={orgId} node={node} canRestore={editable} onRestore={restore} onClose={() => setDialog(null)} />}
      {dialog === 'share' && <PeopleDialog orgId={orgId} node={node} share={share} people={people} onClose={() => setDialog(null)} />}
      {dialog === 'file' && drives && (
        <MoveDialog
          orgId={orgId}
          drives={drives}
          movingIds={[]}
          verb="Embed"
          pickFiles
          onClose={() => setDialog(null)}
          onPick={(_target, file) => {
            setDialog(null)
            if (file) editorRef.current?.chain().focus().insertContent({ type: 'diskFile', attrs: { nodeId: file.id, name: file.name } }).run()
          }}
        />
      )}
      <MgmtConfirm
        open={dialog?.type === 'import'}
        title="Replace this page?"
        message={`${dialog?.file?.name || 'The file'} replaces the page's text. History keeps the current version.`}
        confirmLabel="Replace"
        onConfirm={() => { const f = dialog.file; setDialog(null); importMd(f) }}
        onClose={() => setDialog(null)}
      />
    </div>
  )
}

