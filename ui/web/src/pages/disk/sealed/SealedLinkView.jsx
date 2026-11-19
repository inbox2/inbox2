import { useCallback, useEffect, useState } from 'react'
import FileTypeIcon, { ActionIcon } from '../../../components/FileTypeIcon'
import Skeleton from '../../../components/Skeleton'
import { MgmtButton, MgmtField } from '../../../components/management'
import { linkDownload, openLink, unlockSealedLink } from '../../../lib/disk/publicLink'
import { saveUrl } from '../../../lib/disk/download'
import { registerDiskWorker } from '../../../lib/disk/swRegister'
import formatBytes from '../../../lib/formatBytes'
import PreviewPane from '../preview/PreviewPane'
import styles from '../PublicLinkPage.module.css'

/**
 * A public link to one sealed file (6.9). The key is the URL fragment, read
 * once by PublicLinkPage and dropped from the address bar and history. With a
 * password, the verifier derived here unlocks the ciphertext; the password
 * also goes into the key, so it stays in memory for the open.
 */
export default function SealedLinkView({ token, link, secret }) {
  const [unlock, setUnlock] = useState(null)
  const [password, setPassword] = useState('')
  const [pwError, setPwError] = useState(null)
  const [busy, setBusy] = useState(false)
  const [opened, setOpened] = useState(null) // { Kv, name, mime, manifest, versionId }
  const [error, setError] = useState(null)
  const [shown, setShown] = useState(link)
  const needsPassword = link.password_required && !unlock

  // Unlocked (or no password): the payload and the manifest arrive; open them with the fragment's key.
  useEffect(() => {
    if (!secret || needsPassword) return undefined
    let live = true
    ;(async () => {
      const data = unlock ? (await openLink(token, { unlock })).link : link
      const lib = await import('../../../lib/disk/sealed')
      const o = await lib.openSealedLink({ secretB64url: secret, password: link.password_required ? password : null, link: data })
      if (live) { setShown(data); setOpened(o) }
    })().catch((e) => { if (live) setError(e) })
    return () => { live = false }
    // password is read once the unlock token exists; it does not re-run on typing
  }, [token, link, secret, unlock, needsPassword]) // eslint-disable-line react-hooks/exhaustive-deps

  const submit = async (e) => {
    e.preventDefault()
    setBusy(true)
    try {
      const { linkVerifier } = await import('../../../lib/disk/sealed')
      const { unlock: u } = await unlockSealedLink(token, await linkVerifier(secret, link.kdf_salt, password))
      setPwError(null)
      setUnlock(u.token)
    } catch (err) {
      setPwError(err.status === 429 ? `Too many tries. Wait ${err.retryAfter || 60} seconds.` : err.status === 403 ? "That password isn't right." : err.message)
    } finally {
      setBusy(false)
    }
  }

  // The ciphertext's address, and the worker for media (its origin is the one the API handed out).
  const source = useCallback(async () => {
    const { download } = await linkDownload(token, { unlock })
    const lib = await import('../../../lib/disk/sealed')
    if (/^(video|audio)\//.test(opened.mime || '')) {
      await registerDiskWorker([new URL(download.preview_url).origin])
    }
    return (await lib.sealedLinkSource({ opened, previewUrl: download.preview_url })).url
  }, [token, unlock, opened])
  const download = async () => {
    const { download: d } = await linkDownload(token, { unlock })
    if (!d.url) return
    const lib = await import('../../../lib/disk/sealed')
    const { url } = await lib.sealedLinkSource({ opened, previewUrl: d.url })
    saveUrl(url, opened.name)
  }

  if (!secret) {
    return <div className={styles.card} role="alert"><h1 className={styles.title}>This link isn&apos;t complete</h1><p>The key is missing. Ask the sender for the whole link.</p></div>
  }
  if (needsPassword) {
    return (
      <form className={styles.card} onSubmit={submit}>
        <h1 className={styles.title}>This link has a password</h1>
        <MgmtField label="Password" type="password" value={password} onChange={(e) => setPassword(e.target.value)} autoFocus autoComplete="off" />
        {pwError && <p className={styles.error} role="alert">{pwError}</p>}
        <MgmtButton type="submit" variant="primary" disabled={!password || busy}>{busy ? 'Checking...' : 'Open'}</MgmtButton>
      </form>
    )
  }
  if (error) return <div className={styles.card} role="alert"><h1 className={styles.title}>This file didn&apos;t open</h1><p>The link may be incomplete or changed. {error.message}</p></div>
  if (!opened) return <div className={styles.card}><Skeleton variant="text" count={4} /></div>
  const node = { id: shown.node?.id, kind: 'file', name: opened.name, mime: opened.mime, size_bytes: opened.manifest.size, has_thumbnail: false }
  return (
    <div className={styles.card}>
      <h1 className={styles.title}><FileTypeIcon name={node.name} mime={node.mime} size={28} />{node.name}</h1>
      <p className={styles.muted}>This browser decrypted the file with the key in the link.</p>
      <PreviewPane node={node} loadUrl={source} onDownload={shown.download_allowed ? download : null} />
      {shown.download_allowed && <MgmtButton variant="primary" size="sm" onClick={download}><ActionIcon name="download" />Download, {formatBytes(node.size_bytes)}</MgmtButton>}
    </div>
  )
}
