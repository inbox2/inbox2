import { useMemo, useRef, useState, useCallback, useEffect } from 'react'
import { openLink } from '../../lib/openLink'
import { isTauri } from '../../lib/tauri'
import useRemoteImages from '../../hooks/useRemoteImages'
import RemoteContentBanner from '../RemoteContentBanner/RemoteContentBanner'
import ProxyFailedBanner from '../RemoteContentBanner/ProxyFailedBanner'
import log from '../../lib/log'
import { buildSrcDoc, isNearWhite } from './buildSrcDoc'
import styles from './EmailFrame.module.css'

// HTML emails render inside a sandboxed iframe so the email's own <style>/layout
// renders faithfully (Gmail-like) while being fully isolated from the app. The
// iframe is same-origin (so we can proxy images + intercept links from the
// parent) but cannot run scripts. The srcdoc itself is built (and unit-tested) in
// buildSrcDoc.js. See docs / project_email_iframe_render.

export default function EmailFrame({ html, sender, messageKey, blockLinks = false }) {
  const iframeRef = useRef(null)
  const cleanupRef = useRef(null)
  const [docBody, setDocBody] = useState(null)
  // handleLoad is deliberately dep-free; read the live value through a ref.
  const blockLinksRef = useRef(blockLinks)
  useEffect(() => { blockLinksRef.current = blockLinks }, [blockLinks])

  const {
    showBanner, blockedCount, onShowOnce, onAlwaysSender, onAlwaysAll,
    showFailedBanner, failedCount, direct, onLoadDirect,
  } = useRemoteImages(docBody, html, sender, messageKey)

  // Strict CSP (no remote loads) except the consented direct render: flipping
  // `direct` rebuilds the document with https images admitted, the hook re-proxies,
  // and only the proxy-refused images fall back to their original URLs.
  const srcDoc = useMemo(() => buildSrcDoc(html, direct, isTauri()), [html, direct])

  // Wire the iframe document each time it (re)loads.
  const handleLoad = useCallback(() => {
    cleanupRef.current?.()
    const iframe = iframeRef.current
    const cdoc = iframe?.contentDocument
    if (!cdoc) return

    setDocBody(cdoc.body)

    // Intercept link clicks → openLink. Use the CAPTURE phase: in WKWebView a
    // bubble-phase listener on a sandboxed iframe doc doesn't fire before the
    // frame navigates itself, so the click was lost. Capture runs first.
    const onClick = (e) => {
      const a = e.target?.closest?.('a[href]')
      if (!a) return
      const raw = a.getAttribute('href')
      if (!raw || raw.startsWith('#')) return
      e.preventDefault()
      e.stopPropagation()
      // Spam: swallow the click — links in junk mail must not open (phishing).
      if (blockLinksRef.current) return
      // Pass the resolved absolute URL (a.href), not the raw attribute, so it
      // matches the URL the native email-link-router emits — otherwise the
      // cross-handler dedupe in openLink can't tell they're the same click.
      openLink(a.href, { forceExternal: e.metaKey || e.ctrlKey })
    }
    cdoc.addEventListener('click', onClick, true)

    // Size the iframe to its content (no inner scrollbars); track reflow as
    // images load and the layout settles. Measure the BODY, not documentElement:
    // once we set the iframe tall, <html> fills that viewport, so its scrollHeight
    // stays inflated and never shrinks back — body height tracks real content.
    //
    // Anti-flap: on width-sensitive emails (long wrapping text + max-width
    // images) the measured height can oscillate A↔B forever — sub-pixel
    // rounding, or the outer scrollbar toggling the available width — which
    // renders as the body visibly "bouncing". Tolerate ±1px jitter, and when a
    // measurement bounces straight back to the previous value, pin the larger
    // height at the current width until the frame's width really changes (or
    // the content genuinely grows, e.g. expanding a quoted-text block).
    let applied = 0
    let previous = 0
    let pinnedAtWidth = null
    const resize = () => {
      const el = iframeRef.current
      if (!el || !cdoc.body) return
      const w = el.clientWidth
      const h = cdoc.body.scrollHeight
      if (pinnedAtWidth !== null) {
        if (w === pinnedAtWidth && h <= applied + 1) return
        pinnedAtWidth = null // real reflow (width change / content growth)
      }
      if (Math.abs(h - applied) <= 1) return
      if (h === previous) {
        // A→B→A cycle — settle on the taller of the two and stop chasing it.
        const target = Math.max(h, applied)
        previous = applied
        applied = target
        el.style.height = `${target}px`
        pinnedAtWidth = w
        return
      }
      previous = applied
      applied = h
      el.style.height = `${h}px`
    }
    resize()
    const ro = new ResizeObserver(resize)
    ro.observe(cdoc.body)

    // Drop the white page when the email paints its own background, so the app's
    // dark surface shows through the margins instead of white strips. Kept white
    // otherwise — many emails are dark text on no background and need it to read.
    const applyBackground = () => {
      const win = cdoc.defaultView
      if (!win || !cdoc.body) return
      const w = cdoc.documentElement.clientWidth
      const hViewport = cdoc.documentElement.clientHeight
      const sample = (x, y) => {
        let el = cdoc.elementFromPoint(Math.round(x), Math.round(Math.min(y, hViewport - 1)))
        while (el && el !== cdoc.body && el !== cdoc.documentElement) {
          const cs = win.getComputedStyle(el)
          // A near-white background is indistinguishable from the white reading page,
          // so it does NOT make the email "self-backgrounded" — otherwise prose that
          // sets `background:white` on its blocks loses its padding and runs flush to
          // the card edges. Only colored / image backgrounds count as full-bleed.
          const opaque = cs.backgroundColor
            && !/^(transparent|rgba\(0,\s*0,\s*0,\s*0\))$/.test(cs.backgroundColor)
            && !isNearWhite(cs.backgroundColor)
          if (opaque || cs.backgroundImage !== 'none') return true
          el = el.parentElement
        }
        return false
      }
      const pts = [[w * 0.5, 24], [w * 0.25, hViewport * 0.5], [w * 0.75, hViewport * 0.5]]
      const painted = pts.filter(([x, y]) => sample(x, y)).length
      // All three, not a majority: an unpainted strip (a forwarded header or a
      // typed reply above a painted newsletter) is dark text that needs the page.
      const transparent = painted === pts.length
      const bg = transparent ? 'transparent' : ''
      cdoc.documentElement.style.background = bg
      cdoc.body.style.background = bg
      if (iframeRef.current) iframeRef.current.style.background = bg
      // Self-backgrounded emails control their own spacing → flush (0). White-page
      // emails (dark text) get padding so the text isn't cramped against the edge.
      cdoc.body.style.padding = transparent ? '0px' : '16px'
    }
    requestAnimationFrame(applyBackground)
    // Re-check once images/backgrounds have settled.
    const bgTimer = setTimeout(applyBackground, 600)

    cleanupRef.current = () => {
      ro.disconnect()
      clearTimeout(bgTimer)
      cdoc.removeEventListener('click', onClick, true)
    }
  }, []) // handleLoad re-fires on each iframe (re)load; reads only live refs

  useEffect(() => () => cleanupRef.current?.(), [])

  return (
    <div className={styles.wrap}>
      {showBanner && (
        <RemoteContentBanner
          count={blockedCount}
          onShowOnce={onShowOnce}
          onAlwaysSender={onAlwaysSender}
          onAlwaysAll={onAlwaysAll}
        />
      )}
      {showFailedBanner && (
        <ProxyFailedBanner count={failedCount} onLoadDirect={onLoadDirect} />
      )}
      <iframe
        ref={iframeRef}
        className={styles.frame}
        srcDoc={srcDoc}
        // allow-same-origin is required for the whole pipeline (contentDocument
        // access: link interception, image proxy, sizing, background).
        // Web also needs allow-popups so the <base target="_blank"> in buildSrcDoc
        // can open a real tab — WebKit never fires our JS click handler for a
        // sandboxed iframe, so the native _blank is the only thing that opens the
        // link there, and without allow-popups WebKit silently blocks it.
        // Desktop OMITS allow-popups (and gets no base target): its click is an
        // in-frame nav routed to the OS browser by the Rust email-link-router.
        // NEVER add allow-popups-to-escape-sandbox: WebKit revokes the same-origin
        // grant when an escaping flag is present → opaque origin → blank reading
        // pane on Safari.
        sandbox={isTauri() ? 'allow-same-origin' : 'allow-same-origin allow-popups'}
        onLoad={handleLoad}
        onError={() => log.warn('EmailFrame', 'iframe load error')}
        title="Email message"
      />
    </div>
  )
}
