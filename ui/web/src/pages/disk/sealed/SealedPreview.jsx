import { useCallback, useEffect, useMemo, useState } from 'react'
import Skeleton from '../../../components/Skeleton'
import PreviewPane from '../preview/PreviewPane'
import { MgmtButton } from '../../../components/management'
import { ACCOUNT_WEB_URL } from '../../../lib/webOrigin'
import { openLink } from '../../../lib/openLink'
import formatBytes from '../../../lib/formatBytes'
import styles from './Sealed.module.css'

/**
 * A sealed file through the ordinary preview pane (spec F7: every F5 type):
 * small files are opened here into a blob: URL, media and large files stream
 * through the Disk service worker. The pane sees the opened node (name, type,
 * plaintext size) and never the sealed thumbnail. Exact view: the sealed
 * rendition, or a conversion here that is never cached on the device.
 */
export default function SealedPreview({ orgId, scope, node, version, startFull, onDownload }) {
  const [state, setState] = useState(null) // { node, url } | { error }
  const loadUrl = useCallback(async () => state?.url, [state]) // stable: PreviewPane's engine effect depends on it, and every render re-fetched the manifest
  // Exact view (spec F5b): the sealed stored rendition opened here, or a conversion on this device kept in memory.
  const sealedExact = useMemo(() => ({
    rendition: () => import('../../../lib/disk/sealed')
      .then((lib) => lib.derivedBlob({ orgId, scope, nodeId: node.id, version, variant: 'rendition', mime: 'application/pdf' }))
      .then((b) => URL.createObjectURL(b)).catch(() => null),
  }), [orgId, scope?.id, scope?.epoch, node.id, version?.id]) // eslint-disable-line react-hooks/exhaustive-deps -- by id: the parent passes fresh objects every render
  useEffect(() => {
    let live = true
    let revoke = () => {}
    const ctl = new AbortController()
    import('../../../lib/disk/sealed')
      .then((lib) => lib.sealedPreview({ orgId, scope, node, version, signal: ctl.signal }))
      .then((p) => { revoke = p.revoke; if (live) setState({ node: { ...p.node, has_thumbnail: false }, url: p.url, plan: p.plan }) })
      .catch((e) => { if (live && e.name !== 'AbortError') setState({ error: e }) })
    return () => { live = false; ctl.abort(); revoke() }
  }, [orgId, scope?.id, scope?.epoch, node.id, version?.id]) // eslint-disable-line react-hooks/exhaustive-deps -- by id, or a re-render reopens the file and revokes the blob the preview is reading
  if (!state) return <div className={styles.progress}><Skeleton variant="text" count={4} /></div>
  if (state.error) return <p className={styles.error} role="alert">This sealed file didn&apos;t open: {state.error.message}</p>
  // No service worker here (the desktop app's webview) and too large to open in memory.
  if (state.plan?.reason === 'browser') {
    return (
      <div className={styles.banner} role="status">
        This sealed file is {formatBytes(state.node.size_bytes)}. The limit here is {formatBytes(state.plan.limit)}.
        <MgmtButton size="sm" variant="primary" onClick={() => openLink(`${ACCOUNT_WEB_URL}${window.location.pathname}${window.location.search}`)}>Open in the browser</MgmtButton>
      </div>
    )
  }
  return <PreviewPane orgId={orgId} node={state.node} version={version} startFull={startFull} onDownload={onDownload} loadUrl={loadUrl} sealedExact={sealedExact} />
}
