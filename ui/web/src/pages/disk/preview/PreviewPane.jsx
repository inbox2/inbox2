import { useCallback, useContext, useEffect, useMemo, useRef, useState } from 'react'
import FileTypeIcon, { ActionIcon } from '../../../components/FileTypeIcon'
import { MgmtButton } from '../../../components/management'
import Skeleton from '../../../components/Skeleton'
import diskApi from '../../../lib/disk/api'
import { previewPlan, RENDERERS, isSafari } from '../../../lib/disk/preview/registry'
import formatBytes from '../../../lib/formatBytes'
import log from '../../../lib/log'
import { AuthContext } from '../../../hooks/AuthProvider'
import useEngineStore, { ENGINE } from '../../../stores/engineStore'
import { isEngineFormat } from '../../../lib/disk/engine/rendition'
import { currentSupport, exactAlways, setEngineDeclined, setExactAlways } from '../../../lib/disk/engine/env'
import { convertInEngine, engineWindowOpen, openEngineWindow } from '../../../lib/disk/engine/client'
import { EXACT, needsStorageWarning } from '../../../lib/disk/engine/logic'
import ExactViewBar from './ExactViewBar'
import styles from './Preview.module.css'

const REASONS = {
  sealed: 'Sealed files have no preview here.',
  none: 'There is no preview for this type of file yet.',
  'too-large': 'This file is too large to preview here.',
  empty: "This file's upload hasn't finished.",
}

/**
 * The preview slot of the slide-over (spec F5). Picks the renderer from the
 * registry, loads it on first use, shows the blurred thumbnail (when the
 * version has one) until the renderer is ready, and falls back to the type
 * icon, size and Download for anything it cannot show. Mount it with a key per
 * node and version.
 */
// sealedExact (a sealed file, opened here): { rendition: () => Promise<blob URL | null> } for its sealed
// stored rendition. Exact view of a sealed file is converted on this device and kept in memory only.
export default function PreviewPane({ orgId, node, version, startFull = false, onDownload, loadUrl, sealedExact }) {
  // loadUrl: where the bytes come from; a public link passes its preview_url. Default: GET /nodes/:id/download.
  const fetchUrl = useCallback(async () => (loadUrl ? loadUrl() : (await diskApi.download(orgId, node.id)).download.url), [loadUrl, orgId, node.id])
  const plan = useMemo(() => previewPlan(node, { safari: isSafari() }), [node])
  const [Renderer, setRenderer] = useState(null)
  const [url, setUrl] = useState(null)
  const [thumb, setThumb] = useState(null)
  const [ready, setReady] = useState(false)
  const [error, setError] = useState(null)
  const [full, setFull] = useState(startFull)

  // ── exact view (spec F5b): a stored rendition, this device's own conversion, or the engine ──
  const account = useContext(AuthContext)?.user?.id
  const versionId = version?.id || node.current_version_id
  const exactable = (!loadUrl || !!sealedExact) && !node.sealed && isEngineFormat(node.name)
  const support = useMemo(() => currentSupport(), [])
  const engine = useEngineStore()
  const [exact, setExact] = useState(null) // { url, source: 'rendition' | 'device' }
  const [exactState, setExactState] = useState(null) // CONFIRM | CONVERTING | FAILED | ASK_ALWAYS, else derived
  const [exactError, setExactError] = useState(null)
  const job = useRef(null)

  // fromClick: open the engine window now (window.open must run inside the click);
  // otherwise use one that is already open.
  const convert = useCallback(async (fromClick = false) => {
    const windowReady = fromClick ? openEngineWindow() : engineWindowOpen().then((ok) => { if (!ok) throw Object.assign(new Error('no window'), { aborted: true }) })
    setExactState(EXACT.CONVERTING)
    setExactError(null)
    try {
      await windowReady
      const { putConversion } = await import('../../../lib/disk/engine/conversions')
      const bytes = new Uint8Array(await (await fetch(await fetchUrl())).arrayBuffer())
      job.current = convertInEngine(bytes, node.name)
      const pdf = await job.current.promise
      // Nothing is uploaded at view time; a sealed file's conversion is never written to the device cache either.
      if (!sealedExact) putConversion(account, versionId, pdf).catch(() => {})
      setExact({ url: URL.createObjectURL(new Blob([pdf], { type: 'application/pdf' })), source: 'device' })
      setExactState(exactAlways() ? null : EXACT.ASK_ALWAYS)
    } catch (e) {
      if (e.aborted) return setExactState(null)
      log.warn('DiskPreview', `exact view failed for a ${node.mime || 'file'}: ${e.message}`)
      setExactError(/pop-up|window/.test(e.message) ? e.message : "Exact view didn't work for this file.")
      setExactState(EXACT.FAILED)
    } finally {
      job.current = null
    }
  }, [fetchUrl, node.name, node.mime, account, versionId, sealedExact])

  useEffect(() => {
    if (!exactable) return undefined
    let live = true
    // No stored rendition and no conversion on this device: use the engine if it is here,
    // else start its download (the first Office file is what fetches it, spec F5b).
    const wantEngine = () => {
      if (!support.ok) return
      if (useEngineStore.getState().status === ENGINE.READY) { if (exactAlways() === 'yes') convert() }
      else import('../../../lib/disk/engine/install').then((m) => m.ensureEngine()).catch(() => {})
    }
    ;(async () => {
      if (sealedExact) {
        const u = version?.has_rendition ? await sealedExact.rendition() : null
        if (u) { if (live) setExact({ url: u, source: 'device' }); return }
        if (live) wantEngine()
        return
      }
      if (version?.has_rendition) {
        const { download } = await diskApi.versionDownload(orgId, version.id, 'rendition')
        if (live) setExact({ url: download.url, source: 'rendition' })
        return
      }
      const { getConversion } = await import('../../../lib/disk/engine/conversions')
      const cached = await getConversion(account, versionId)
      if (cached) { if (live) setExact({ url: URL.createObjectURL(cached), source: 'device' }); return }
      if (live) wantEngine()
    })().catch(() => {})
    return () => { live = false; job.current?.cancel() }
  }, [exactable, version, orgId, account, versionId, support.ok, convert, sealedExact])
  useEffect(() => () => { if (exact?.source === 'device') URL.revokeObjectURL(exact.url) }, [exact])

  const getEngine = async (confirmed = false) => {
    // ponytail: the storage check awaits before window.open, so after "Download anyway" the
    // engine window may be blocked; the bar then offers "Show exact view", whose click opens it.
    if (!confirmed && needsStorageWarning(await navigator.storage?.estimate?.().catch(() => null), engine.size || engine.downloadSize * 3)) {
      return setExactState(EXACT.CONFIRM)
    }
    setExactState(null)
    setExactError(null)
    setEngineDeclined(false)
    const windowReady = openEngineWindow().catch(() => null) // inside the click, so the browser allows it
    const { installEngine } = await import('../../../lib/disk/engine/install')
    installEngine().then(() => windowReady).then(() => convert(false)).catch((e) => {
      if (e.aborted) return
      setExactError(e.message)
      setExactState(EXACT.FAILED)
    })
  }
  const cancelExact = async () => {
    if (exactState === EXACT.CONVERTING) return job.current?.cancel()
    if (exactState === EXACT.CONFIRM) return setExactState(null)
    // Cancelled on purpose: the next Office file offers the download and does not start it.
    setEngineDeclined(true)
    ;(await import('../../../lib/disk/engine/install')).cancelInstall()
  }
  // "Try again": a download that failed starts over (cached parts are kept); a conversion runs again.
  const retryExact = () => (engine.status === ENGINE.READY ? convert(true) : getEngine(false))
  const barState = exact ? (exactState === EXACT.ASK_ALWAYS ? EXACT.ASK_ALWAYS : null)
    : exactState || ({ [ENGINE.DOWNLOADING]: EXACT.DOWNLOADING, [ENGINE.VERIFYING]: EXACT.VERIFYING, [ENGINE.READY]: EXACT.READY, [ENGINE.ERROR]: EXACT.FAILED }[engine.status] || EXACT.OFFER)
  const bar = exactable && (support.ok || exact) && barState && (
    <ExactViewBar
      state={barState}
      quick={!!plan.renderer}
      downloadSize={engine.downloadSize}
      installSize={engine.size}
      loaded={engine.loaded}
      total={engine.total}
      error={exactError || engine.error}
      onGet={() => getEngine(false)}
      onConfirm={() => getEngine(true)}
      onCancel={cancelExact}
      onConvert={() => convert(true)}
      onRetry={retryExact}
      onAlways={(yes) => { setExactAlways(yes ? 'yes' : 'no'); setExactState(null) }}
    />
  )
  const rendererId = exact ? 'pdf' : plan.renderer

  useEffect(() => {
    if (!rendererId) return undefined
    let live = true
    Promise.all([RENDERERS[rendererId].load(), exact ? exact.url : fetchUrl()])
      .then(([mod, u]) => { if (live) { setRenderer(() => mod.default); setUrl(u); setReady(false); setError(null) } })
      .catch((e) => { if (live) setError(e) })
    return () => { live = false }
  }, [fetchUrl, rendererId, exact])

  useEffect(() => {
    if (!version?.has_thumbnail) return undefined
    let live = true
    diskApi.versionDownload(orgId, version.id, 'thumbnail')
      .then(({ download }) => { if (live) setThumb(download.url) })
      .catch(() => {})
    return () => { live = false }
  }, [orgId, version])

  const onReady = useCallback(() => setReady(true), [])
  const onError = useCallback((e) => {
    log.warn('DiskPreview', `${rendererId} failed for a ${node.mime || 'file'}: ${e?.message}`)
    // Counted by the API (spec F5); public links have no member to count it for.
    if (!loadUrl && orgId) diskApi.previewFailure(orgId, node.id, rendererId, 'render_failed').catch(() => {})
    setError(e)
  }, [rendererId, node.mime, node.id, loadUrl, orgId])
  const refreshUrl = fetchUrl

  if (!rendererId || error) {
    return (
      <div className={styles.fallback}>
        {bar}
        <FileTypeIcon name={node.name} mime={node.mime} type={node.sealed ? 'key' : undefined} size={96} />
        <p>
          <b>{error ? "This preview didn't work." : REASONS[plan.reason]}</b>
          <br />{formatBytes(node.size_bytes)}{plan.limit ? `, previews go up to ${formatBytes(plan.limit)}` : ''}
        </p>
        {!node.sealed && onDownload && (node.current_version_id || loadUrl) && <MgmtButton size="sm" variant="primary" onClick={onDownload}><ActionIcon name="download" />Download</MgmtButton>}
      </div>
    )
  }

  return (
    <div className={[styles.pane, full ? styles.paneFull : ''].join(' ')}>
      <button
        type="button"
        className={styles.full}
        aria-pressed={full}
        aria-label={full ? 'Exit full screen' : 'Full screen'}
        title={full ? 'Exit full screen' : 'Full screen'}
        onClick={() => setFull(!full)}
      >
        <ActionIcon name={full ? 'x' : 'expand'} />
      </button>
      {bar}
      {exact && <p className={styles.exactLabel}>Exact view{exact.source === 'rendition' ? '' : ', made on this device'}</p>}
      {!ready && (
        <div className={styles.loading} aria-hidden="true">
          {thumb ? <img className={styles.thumb} src={thumb} alt="" /> : <Skeleton variant="text" count={6} />}
        </div>
      )}
      <div className={ready ? styles.shown : styles.hidden}>
        {Renderer && url && <Renderer key={rendererId} node={node} url={url} refreshUrl={refreshUrl} onReady={onReady} onError={onError} />}
      </div>
    </div>
  )
}
