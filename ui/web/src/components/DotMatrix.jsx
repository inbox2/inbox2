import { useRef, useEffect, useSyncExternalStore } from 'react'
import styles from './DotMatrix.module.css'
import useTheme from '../hooks/useTheme'
import { THEME_MODE } from '../lib/themes'
import { buildBonsai, drawBonsai } from '../lib/bonsai'
import { buildGroovebox, drawGroovebox } from '../lib/groovebox'
import { useAmbientActive, useSoftwareRendering } from '../lib/ambientMotion'

// Canvas backdrops by `theme.procedural` key: build once per size, draw with
// progress p in [0, 1] over `ms`, then hold the still frame.
const PROCEDURAL = {
  bonsai: { build: buildBonsai, draw: drawBonsai, ms: 2400 },
  groovebox: { build: buildGroovebox, draw: drawGroovebox, ms: 1600 },
}

// Reactive `prefers-reduced-motion` — falls back to the still image when set.
const _rmQuery =
  typeof window !== 'undefined' && window.matchMedia
    ? window.matchMedia('(prefers-reduced-motion: reduce)')
    : null
function usePrefersReducedMotion() {
  return useSyncExternalStore(
    (cb) => {
      _rmQuery?.addEventListener?.('change', cb)
      return () => _rmQuery?.removeEventListener?.('change', cb)
    },
    () => !!_rmQuery?.matches,
    () => false,
  )
}

/**
 * DotMatrix — cinematic AI console background.
 *
 * Renders the active theme's background: for image-backed variants, a looping
 * ambient video (slow drifting clouds / faint haze) when the theme defines one,
 * otherwise the static image; or the percolating dot-grid loop when a dark theme
 * has no shipped backdrop (NONE mode or a dark theme). The Light theme keeps the
 * theme-aware animated canvas grid (dark dots on light). Respects
 * `prefers-reduced-motion` by holding the still image.
 *
 * Pass `pixelGrid` to always render the original animated canvas grid regardless
 * of theme — used by the settings and auth/setup surfaces, which keep a
 * consistent backdrop.
 */
export default function DotMatrix({ className, pixelGrid = false }) {
  const { theme } = useTheme()
  // Without a GPU every frame is drawn by the CPU: hold the still backdrop, as for reduced motion.
  const software = useSoftwareRendering()
  const reducedMotion = usePrefersReducedMotion() || software
  const active = useAmbientActive() && !reducedMotion
  const themeVideoRef = useRef(null)
  const cls = `${styles.fill} ${styles.bgImg} ${className || ''}`.trim()

  // Ambient theme video: only decode while the window is visible and focused.
  useEffect(() => {
    const v = themeVideoRef.current
    if (!v) return
    if (active) v.play().catch(() => {})
    else v.pause()
  }, [active, theme.video])

  if (!pixelGrid && PROCEDURAL[theme.procedural]) {
    return <ProceduralCanvas key={theme.procedural} renderer={PROCEDURAL[theme.procedural]} reducedMotion={reducedMotion} className={`${styles.fill} ${styles.bgImg} ${className || ''}`.trim()} />
  }

  if (!pixelGrid && theme.background) {
    if (theme.video && !reducedMotion) {
      return (
        <video
          key={theme.video}
          ref={themeVideoRef}
          className={cls}
          poster={theme.background}
          autoPlay
          loop
          muted
          playsInline
          disablePictureInPicture
          preload="auto"
          aria-hidden="true"
          tabIndex={-1}
        >
          <source src={theme.video} type="video/mp4" />
        </video>
      )
    }

    return (
      <img
        src={theme.background}
        alt=""
        aria-hidden="true"
        className={cls}
      />
    )
  }

  // The pixelGrid surfaces (settings, auth/setup) always get the original
  // theme-aware animated canvas grid.
  if (pixelGrid) {
    return <DotMatrixCanvas active={active} className={`${styles.fill} ${className || ''}`.trim()} />
  }

  // No shipped backdrop. Dark contexts (NONE mode or a dark theme) get the
  // percolating LED dot-grid loop; the Light theme keeps the theme-aware canvas
  // grid, whose dots adapt to the light surface. The backdrop is dimmed to ~0.2
  // so it stays a faint ambient texture behind the UI.
  if (theme.mode === THEME_MODE.DARK) {
    if (reducedMotion) {
      return (
        <img src="/bg-dotgrid.jpg" alt="" aria-hidden="true" className={`${cls} ${styles.dim}`} />
      )
    }
    return <PixelGridLoop active={active} className={`${styles.fill} ${styles.dim} ${className || ''}`.trim()} />
  }

  return <DotMatrixCanvas active={active} className={`${styles.fill} ${className || ''}`.trim()} />
}

/**
 * ProceduralCanvas — a canvas-drawn theme backdrop (Atelier's bonsai, the
 * Groovebox grid). Plays its draw-in once on mount, then holds a still frame:
 * no rAF loop at rest, a redraw only on resize.
 */
function ProceduralCanvas({ className, reducedMotion, renderer }) {
  const canvasRef = useRef(null)

  useEffect(() => {
    const canvas = canvasRef.current
    if (!canvas) return
    const ctx = canvas.getContext('2d')
    const { build, draw, ms } = renderer
    const start = performance.now()
    let scene
    let raf

    const paint = () => {
      const p = reducedMotion ? 1 : Math.min(1, (performance.now() - start) / ms)
      const dpr = window.devicePixelRatio || 1
      ctx.setTransform(dpr, 0, 0, dpr, 0, 0)
      draw(ctx, scene, p)
      if (p < 1) raf = requestAnimationFrame(paint)
    }

    const resize = () => {
      const { width, height } = canvas.parentElement.getBoundingClientRect()
      const dpr = window.devicePixelRatio || 1
      canvas.width = Math.floor(width * dpr)
      canvas.height = Math.floor(height * dpr)
      scene = build(width, height)
      cancelAnimationFrame(raf)
      paint()
    }

    const ro = new ResizeObserver(resize)
    ro.observe(canvas.parentElement)
    resize()
    return () => {
      cancelAnimationFrame(raf)
      ro.disconnect()
    }
  }, [reducedMotion, renderer])

  return <canvas ref={canvasRef} className={className} aria-hidden="true" />
}

/**
 * PixelGridLoop — seamless loop of the percolating dot-grid clip.
 *
 * The source clip isn't authored to loop, so a native `loop` shows a visible
 * cut at the boundary. Because the grid is static and only dot brightness
 * animates, we hide the seam by crossfading the clip with a second copy of
 * itself offset by half its duration: each copy fades to 0 at its own loop
 * boundary while the other plays through the middle, so the boundary is never
 * on screen. Per-frame opacity is driven through a CSS custom property
 * (`--o`) — inline styles are banned, and the values are dynamic.
 */
function PixelGridLoop({ className, active = true }) {
  const aRef = useRef(null)
  const bRef = useRef(null)

  useEffect(() => {
    const a = aRef.current
    const b = bRef.current
    if (!a || !b) return
    if (!active) {
      // Window hidden/blurred: stop video decode and the crossfade rAF loop.
      a.pause()
      b.pause()
      return
    }
    const FADE = 0.7 // seconds of crossfade at each loop boundary
    let raf

    // Opacity ramp: fade in over the first FADE, fade out over the last FADE.
    const opacityAt = (t, dur) => {
      if (t < FADE) return t / FADE
      if (t > dur - FADE) return Math.max(0, (dur - t) / FADE)
      return 1
    }

    // Both clips autoplay (muted) on their own, so the grid animates even if the
    // crossfade setup below never runs — it only drives the boundary opacity.
    const start = () => {
      const dur = a.duration
      if (!dur || Number.isNaN(dur)) return
      // Offset the second copy by half the clip so the two boundaries never
      // coincide — one always covers the other's fade. Kick both off explicitly
      // in case the autoplay attribute was deferred.
      if (Math.abs(b.currentTime - dur / 2) > 0.05) b.currentTime = dur / 2
      a.play().catch(() => {})
      b.play().catch(() => {})
      const tick = () => {
        a.style.setProperty('--o', opacityAt(a.currentTime, dur).toFixed(3))
        b.style.setProperty('--o', opacityAt(b.currentTime, dur).toFixed(3))
        raf = requestAnimationFrame(tick)
      }
      tick()
    }

    if (a.readyState >= 1 && a.duration) start()
    a.addEventListener('loadedmetadata', start)

    return () => {
      cancelAnimationFrame(raf)
      a.removeEventListener('loadedmetadata', start)
    }
  }, [active])

  const videoProps = {
    className: styles.loopVideo,
    autoPlay: true,
    loop: true,
    muted: true,
    playsInline: true,
    disablePictureInPicture: true,
    preload: 'auto',
    'aria-hidden': 'true',
    tabIndex: -1,
  }

  return (
    <div className={className} aria-hidden="true">
      <video ref={aRef} poster="/bg-dotgrid.jpg" {...videoProps}>
        <source src="/bg-dotgrid.mp4" type="video/mp4" />
      </video>
      <video ref={bRef} {...videoProps}>
        <source src="/bg-dotgrid.mp4" type="video/mp4" />
      </video>
    </div>
  )
}

function DotMatrixCanvas({ className, active = true }) {
  const canvasRef = useRef(null)
  const activeRef = useRef(active)
  useEffect(() => { activeRef.current = active }, [active])

  useEffect(() => {
    const canvas = canvasRef.current
    if (!canvas) return

    const ctx = canvas.getContext('2d')
    let animId
    let cw = 0
    let ch = 0
    let imageData
    let data

    const GAP = 14

    // Per-dot persistent state (flat arrays for perf)
    let dotCount = 0
    let baseAlpha
    let phase
    let speed
    let hueR, hueG, hueB
    let flare, flareDecay
    let tintR = 255, tintG = 255, tintB = 255
    let flareBudget = 0

    const isLightMode = () => {
      const themed = canvas.closest('[data-theme]')
      return themed?.getAttribute('data-theme') === THEME_MODE.LIGHT
    }

    const resize = () => {
      const rect = canvas.parentElement.getBoundingClientRect()
      const w = rect.width
      const h = rect.height
      cw = Math.floor(w)
      ch = Math.floor(h)
      canvas.width = cw
      canvas.height = ch
      imageData = ctx.createImageData(cw, ch)
      data = imageData.data
      buildDots(w, h)
    }

    const buildDots = (w, h) => {
      const cols = Math.floor(w / GAP) + 1
      const rows = Math.floor(h / GAP) + 1
      dotCount = cols * rows
      const light = isLightMode()

      baseAlpha = new Float32Array(dotCount)
      phase = new Float32Array(dotCount)
      speed = new Float32Array(dotCount)
      hueR = new Uint8Array(dotCount)
      hueG = new Uint8Array(dotCount)
      hueB = new Uint8Array(dotCount)
      flare = new Float32Array(dotCount)
      flareDecay = new Float32Array(dotCount)

      // Twinkles tint toward hot white-blue on dark surfaces, deep ink on light.
      if (light) { tintR = 24; tintG = 44; tintB = 86 }
      else { tintR = 214; tintG = 232; tintB = 255 }

      for (let i = 0; i < dotCount; i++) {
        const fg = Math.random() < 0.3
        baseAlpha[i] = fg
          ? 0.11 + Math.random() * 0.11
          : 0.035 + Math.random() * 0.055
        phase[i] = Math.random() * Math.PI * 2
        speed[i] = 0.3 + Math.random() * 0.8
        flareDecay[i] = 0.90 + Math.random() * 0.06

        if (light) {
          // Dark steel-blue dots for light mode
          const h = 210 + Math.random() * 30
          const s = 0.15 + Math.random() * 0.15
          const l = 0.30 + Math.random() * 0.12
          const c = (1 - Math.abs(2 * l - 1)) * s
          const x = c * (1 - Math.abs(((h / 60) % 2) - 1))
          const m = l - c / 2
          let r1, g1, b1
          if (h < 240) { r1 = 0; g1 = x; b1 = c; }
          else { r1 = x; g1 = 0; b1 = c; }
          hueR[i] = Math.round((r1 + m) * 255)
          hueG[i] = Math.round((g1 + m) * 255)
          hueB[i] = Math.round((b1 + m) * 255)
        } else {
          // Light blue-gray dots for dark mode
          const h = 210 + Math.random() * 25
          const s = 0.05 + Math.random() * 0.08
          const l = 0.78 + Math.random() * 0.12
          const c = (1 - Math.abs(2 * l - 1)) * s
          const x = c * (1 - Math.abs(((h / 60) % 2) - 1))
          const m = l - c / 2
          let r1, g1, b1
          if (h < 240) { r1 = 0; g1 = x; b1 = c; }
          else { r1 = x; g1 = 0; b1 = c; }
          hueR[i] = Math.round((r1 + m) * 255)
          hueG[i] = Math.round((g1 + m) * 255)
          hueB[i] = Math.round((b1 + m) * 255)
        }
      }
    }

    let t = 0
    const startTime = Date.now()
    const breathPhaseX = Math.random() * Math.PI * 2
    const breathPhaseY = Math.random() * Math.PI * 2
    let skip = true
    let drawn = false
    const draw = () => {
      animId = requestAnimationFrame(draw)
      // Idle gate: skip entirely while the window is hidden/blurred, and render
      // at 30fps when it isn't — the full-frame software render + putImageData
      // at 60fps was the top idle-CPU/energy cost on desktop.
      // The first frame always draws, so a still backdrop is never blank.
      if (!activeRef.current && drawn) return
      drawn = true
      skip = !skip
      if (skip) return
      // Clear to transparent
      data.fill(0)

      const w = cw
      const h = ch

      const waveCx = w * 0.5 + Math.sin(t * 0.25) * w * 0.35
      const waveCy = h * 0.5 + Math.cos(t * 0.18) * h * 0.35

      // Breathing pulse — starts soft, builds over ~60s
      const sec = (Date.now() - startTime) / 1000
      const warmup = Math.min(1, sec / 10)
      const breathCx = w * (0.5 + Math.sin(sec * 0.15 + breathPhaseX) * 0.3)
      const breathCy = h * (0.5 + Math.cos(sec * 0.11 + breathPhaseY) * 0.3)
      const breathRadius = Math.min(w, h) * 0.15
      const breathCycle = Math.sin(sec * 0.4) * 0.5 + 0.5

      const cols = Math.floor(w / GAP) + 1

      // Ignite a few random twinkles per frame (rate scaled to grid size).
      flareBudget += dotCount * 0.0004
      while (flareBudget >= 1) {
        flareBudget -= 1
        const j = (Math.random() * dotCount) | 0
        if (flare[j] < 0.3) flare[j] = 0.7 + Math.random() * 0.3
      }

      for (let i = 0; i < dotCount; i++) {
        const c = i % cols
        const r = (i / cols) | 0
        const x = c * GAP
        const y = r * GAP

        // Wave
        const dx = x - waveCx
        const dy = y - waveCy
        const dist = Math.sqrt(dx * dx + dy * dy)
        const wave = Math.sin(dist * 0.012 - t * 1.5) * 0.5 + 0.5

        // Shimmer — cubed so dots idle dim and pop into short bright blinks
        // instead of washing sinusoidally.
        const s = Math.sin(t * speed[i] + phase[i]) * 0.5 + 0.5
        const shimmer = s * s * s

        // Twinkle — sharp attack, exponential decay; as a blink fades it can
        // ignite a neighbour, so flashes percolate in little chains.
        const f = flare[i]
        if (f > 0.012) {
          const nf = f * flareDecay[i]
          flare[i] = nf
          if (f >= 0.5 && nf < 0.5 && Math.random() < 0.4) {
            const step = Math.random() < 0.5 ? 1 : cols
            const n = i + (Math.random() < 0.5 ? step : -step)
            if (n >= 0 && n < dotCount) flare[n] = Math.max(flare[n], 0.5 + Math.random() * 0.25)
          }
        } else if (f > 0) {
          flare[i] = 0
        }

        // Breathing proximity
        const bdx = x - breathCx
        const bdy = y - breathCy
        const breathDist = Math.sqrt(bdx * bdx + bdy * bdy)
        const breathProx = Math.max(0, 1 - breathDist / breathRadius)
        const breath = breathProx * breathCycle * warmup * 2.5

        // Alpha
        const alpha =
          baseAlpha[i] * (0.25 + shimmer * 0.85 + wave * 0.3) + breath * 0.25 + f * 0.5

        // Soft vignette
        const ex = x / w - 0.5
        const ey = y / h - 0.5
        const vignette = 1 - (ex * ex + ey * ey) * 0.5
        const finalAlpha = alpha * Math.max(0.08, vignette)

        if (finalAlpha < 0.005) continue

        const a = Math.round(Math.min(1, finalAlpha) * 255)
        const px = Math.round(x)
        const py = Math.round(y)
        let rr = hueR[i], gg = hueG[i], bb = hueB[i]
        if (f > 0.05) {
          rr += (tintR - rr) * f
          gg += (tintG - gg) * f
          bb += (tintB - bb) * f
        }

        // Draw 2x2 pixel block
        for (let dy = 0; dy < 2; dy++) {
          for (let dx = 0; dx < 2; dx++) {
            const sx = px + dx
            const sy = py + dy
            if (sx >= 0 && sx < cw && sy >= 0 && sy < ch) {
              const idx = (sy * cw + sx) * 4
              data[idx] = rr
              data[idx + 1] = gg
              data[idx + 2] = bb
              data[idx + 3] = a
            }
          }
        }

        // Bright blinks get a faint 1px halo ring around the 2x2 block.
        if (f > 0.45) {
          const ga = Math.round(Math.min(1, finalAlpha) * f * 90)
          for (let gy = -1; gy < 3; gy++) {
            for (let gx = -1; gx < 3; gx++) {
              if (gx >= 0 && gx < 2 && gy >= 0 && gy < 2) continue
              const sx = px + gx
              const sy = py + gy
              if (sx >= 0 && sx < cw && sy >= 0 && sy < ch) {
                const idx = (sy * cw + sx) * 4
                if (data[idx + 3] < ga) {
                  data[idx] = rr
                  data[idx + 1] = gg
                  data[idx + 2] = bb
                  data[idx + 3] = ga
                }
              }
            }
          }
        }
      }

      ctx.putImageData(imageData, 0, 0)

      // ── CRT scanline (drawn after putImageData) ──
      const scanY = ((t * 10) % (ch + 80)) - 40
      ctx.globalAlpha = 0.018
      ctx.fillStyle = 'rgba(140, 180, 255, 1)'
      ctx.fillRect(0, scanY, cw, 1)
      ctx.globalAlpha = 1

      t += 0.02 // double step: drawing every other frame, same visual speed
    }

    resize()
    draw()

    // Rebuild dots when theme changes
    const observer = new MutationObserver(() => {
      const rect = canvas.parentElement.getBoundingClientRect()
      buildDots(rect.width, rect.height)
    })
    const themed = canvas.closest('[data-theme]')
    if (themed) {
      observer.observe(themed, { attributes: true, attributeFilter: ['data-theme'] })
    }

    const ro = new ResizeObserver(resize)
    ro.observe(canvas.parentElement)

    return () => {
      cancelAnimationFrame(animId)
      ro.disconnect()
      observer.disconnect()
    }
  }, [])

  return (
    <canvas
      ref={canvasRef}
      className={className}
    />
  )
}
