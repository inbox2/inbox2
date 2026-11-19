import { useCallback, useEffect, useState } from 'react'
import { useParams } from 'react-router'
import FileTypeIcon, { ActionIcon } from '../../components/FileTypeIcon'
import SlideOver from '../../components/SlideOver'
import Skeleton from '../../components/Skeleton'
import { MgmtButton, MgmtField } from '../../components/management'
import { openLink, unlockLink, linkDownload } from '../../lib/disk/publicLink'
import { saveUrl } from '../../lib/disk/download'
import { tokenFromLinkPath } from '../../lib/disk/model'
import formatBytes from '../../lib/formatBytes'
import PreviewPane from './preview/PreviewPane'
import SealedLinkView from './sealed/SealedLinkView'
import '../../styles/management.css'
import styles from './PublicLinkPage.module.css'

// No referrer leaves this page: the link token is in its URL.
function useNoReferrer() {
  useEffect(() => {
    const meta = document.createElement('meta')
    meta.name = 'referrer'
    meta.content = 'no-referrer'
    document.head.append(meta)
    return () => meta.remove()
  }, [])
}

/* /l/:token: a public link, for anyone, no inbox2 account (spec F4). A file
   previews with Download unless the link hides it; a folder link browses its
   own subtree. Unknown, revoked and expired links all get the same screen. */
// A sealed link's key is the fragment (6.9): read it once, then take it out of the
// address bar and history. Kept here, not in the component, because React may run
// the state initializer twice (StrictMode) and the second run would find no hash.
let taken = { path: null, secret: null } // for this link's path only
function takeSecret() {
  const h = window.location.hash.slice(1)
  if (h) {
    taken = { path: window.location.pathname, secret: h }
    window.history.replaceState(window.history.state, '', window.location.pathname + window.location.search)
  }
  return taken.path === window.location.pathname ? taken.secret : null
}

export default function PublicLinkPage() {
  useNoReferrer()
  const { a, b } = useParams()
  const token = tokenFromLinkPath(a, b) // /share/<name>/<token> or /share/<token>
  const [unlock, setUnlock] = useState(null)
  const [folderId, setFolderId] = useState(null)
  const [data, setData] = useState(null)
  const [error, setError] = useState(null)
  const [open, setOpen] = useState(null)
  const [password, setPassword] = useState('')
  const [pwError, setPwError] = useState(null)
  const [secret] = useState(takeSecret)

  useEffect(() => {
    let live = true
    openLink(token, { nodeId: folderId, unlock }).then((d) => { if (live) { setData(d); setError(null) } }).catch((e) => { if (live) setError(e) })
    return () => { live = false }
  }, [token, folderId, unlock])

  // The server lists a folder 100 at a time; the next page appends.
  const more = () => openLink(token, { nodeId: folderId, cursor: data.next_cursor, unlock })
    .then((d) => setData((cur) => ({ ...cur, nodes: [...cur.nodes, ...d.nodes], next_cursor: d.next_cursor })))
    .catch(setError)

  const submit = async (e) => {
    e.preventDefault()
    try {
      const { unlock: u } = await unlockLink(token, password)
      setPwError(null)
      setUnlock(u.token)
    } catch (err) {
      setPwError(err.status === 429 ? `Too many tries. Wait ${err.retryAfter || 60} seconds and try again.` : err.status === 403 ? "That password isn't right." : err.message)
    }
  }
  const download = async (node) => {
    const { download: d } = await linkDownload(token, { nodeId: node.id, unlock })
    if (d.url) saveUrl(d.url, node.name)
  }
  const linkedId = data?.link?.node?.id
  const fileUrl = useCallback(async () => (await linkDownload(token, { nodeId: linkedId, unlock })).download.preview_url, [token, linkedId, unlock])
  const previewUrl = useCallback(async () => (await linkDownload(token, { nodeId: open?.id, unlock })).download.preview_url, [token, open, unlock])

  let body
  if (error?.status === 429) {
    body = <State icon={<ActionIcon name="clock" size={40} />} title="Too many tries" text={`Wait ${error.retryAfter || 60} seconds, then reload this page.`} />
  } else if (error) {
    body = <State icon={<FileTypeIcon kind="file" size={64} />} title="This link doesn't work" text="It may have expired or been turned off, or the address isn't complete. Ask whoever sent it for a new one." />
  } else if (!data) {
    body = <div className={styles.card}><Skeleton variant="text" count={4} /></div>
  } else if (data.link.sealed) {
    body = <SealedLinkView token={token} link={data.link} secret={secret} />
  } else if (data.link.password_required && !data.link.unlocked) {
    body = (
      <form className={styles.card} onSubmit={submit}>
        <h1 className={styles.title}>This link has a password</h1>
        <MgmtField label="Password" type="password" value={password} onChange={(e) => setPassword(e.target.value)} autoFocus autoComplete="off" />
        {pwError && <p className={styles.error} role="alert">{pwError}</p>}
        <MgmtButton type="submit" variant="primary" disabled={!password}>Open</MgmtButton>
      </form>
    )
  } else if (data.link.node.kind === 'folder') {
    const path = data.path || []
    body = (
      <div className={styles.card}>
        <nav className={styles.crumbs} aria-label="Folder">
          {path.map((p, i) => (
            <span key={p.id}>{i > 0 && '\\'}<button type="button" onClick={() => setFolderId(p.id)} aria-current={i === path.length - 1 ? 'location' : undefined}>{p.name}</button></span>
          ))}
        </nav>
        <ul className={styles.list}>
          {data.nodes.map((n) => (
            <li key={n.id}>
              <button type="button" className={styles.row} onClick={() => (n.kind === 'folder' ? setFolderId(n.id) : setOpen(n))}>
                {n.kind === 'folder' ? <FileTypeIcon kind="folder" size={26} /> : <FileTypeIcon name={n.name} mime={n.mime} size={28} />}
                <span className={styles.name}>{n.name}</span>
                <span className={styles.size}>{n.kind === 'file' ? formatBytes(n.size_bytes) : ''}</span>
              </button>
            </li>
          ))}
          {!data.nodes.length && <li className={styles.muted}>This folder is empty.</li>}
        </ul>
        {data.next_cursor && <MgmtButton variant="glass" onClick={more}>Show more</MgmtButton>}
      </div>
    )
  } else {
    const node = data.link.node
    body = (
      <div className={styles.card}>
        <h1 className={styles.title}><FileTypeIcon name={node.name} mime={node.mime} size={28} />{node.name}</h1>
        <PreviewPane
          node={node}
          loadUrl={fileUrl}
          onDownload={data.link.download_allowed ? () => download(node) : null}
        />
        {data.link.download_allowed && <MgmtButton variant="primary" size="sm" onClick={() => download(node)}><ActionIcon name="download" />Download, {formatBytes(node.size_bytes)}</MgmtButton>}
      </div>
    )
  }

  return (
    <div className={`management ${styles.page}`}>
      <header className={styles.brand}><b>inbox2</b><i>Disk</i></header>
      <main className={styles.main}>{body}</main>
      <footer className={styles.foot}>
        Shared through inbox2 Disk. {data?.link?.abuse_email && <>Report abuse to <a href={`mailto:${data.link.abuse_email}`}>{data.link.abuse_email}</a>.</>}
      </footer>
      {open && (
        <SlideOver
          open
          onClose={() => setOpen(null)}
          title={open.name}
          icon={<FileTypeIcon name={open.name} mime={open.mime} />}
          actions={data?.link.download_allowed && <MgmtButton variant="primary" size="sm" onClick={() => download(open)}><ActionIcon name="download" />Download</MgmtButton>}
        >
          <PreviewPane key={open.id} node={open} loadUrl={previewUrl} onDownload={data?.link.download_allowed ? () => download(open) : null} />
        </SlideOver>
      )}
    </div>
  )
}

function State({ icon, title, text }) {
  return (
    <div className={`${styles.card} ${styles.state}`} role="alert">
      {icon}
      <h1 className={styles.title}>{title}</h1>
      <p>{text}</p>
    </div>
  )
}
