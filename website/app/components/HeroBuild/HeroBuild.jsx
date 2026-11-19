import { useEffect, useRef } from "react";
import { shotSrc, useShotTheme } from "../../lib/shotTheme.jsx";
import styles from "./HeroBuild.module.css";

/** The hero opener. One pinned scene, driven by scroll from the top of the page:
 *
 *   1. blueprint  — the app as a glowing wireframe, tilted back in 3D, each pane
 *                   a layer floating at its own depth above the window frame
 *   2. assemble   — the tilt flattens and the layers drop onto the frame
 *   3. come alive — each wireframe pane cross-fades into the real app (the
 *                   panes are cut from one capture by website/scripts/hero-parts.py)
 *   4. showcase   — the finished window grows to fill the screen
 *   5. tour       — still zoomed, the window flips through `slides` (other
 *                   desktop screens) while each slide's caption floats up
 *   6. settle     — it shrinks back to its resting size
 *
 *  Stage values are written as CSS variables (--tilt, --real, --zoom) so the
 *  stylesheet does all the drawing. Reduced motion or no JS: the variables keep
 *  their CSS defaults, which are the finished, resting window. */
const PARTS = ["channels", "sidebar", "list", "reading", "composer", "strip"];

/** The share of the scroll the slide tour gets, while the window is zoomed. */
const TOUR = [0.34, 0.9];

const clamp01 = (x) => Math.min(1, Math.max(0, x));
/** 0 → 1 across [a, b], eased in and out. */
const ramp = (p, a, b) => {
  const t = clamp01((p - a) / (b - a));
  return t * t * (3 - 2 * t);
};

function useScene() {
  const ref = useRef(null);
  useEffect(() => {
    const el = ref.current;
    if (!el || window.matchMedia("(prefers-reduced-motion: reduce)").matches) return undefined;
    el.dataset.stage = "on";
    let frame = 0;
    const paint = () => {
      frame = 0;
      const r = el.getBoundingClientRect();
      const top = r.top + window.scrollY;
      // 0 at the top of the page, 1 when the pin releases (the track's end
      // reaches the pin's bottom edge).
      const pinH = el.firstElementChild?.offsetHeight || window.innerHeight;
      const p = clamp01(window.scrollY / Math.max(1, top + r.height - pinH));
      el.style.setProperty("--tilt", (1 - ramp(p, 0.03, 0.18)).toFixed(4));
      el.style.setProperty("--real", ramp(p, 0.15, 0.25).toFixed(4));
      el.style.setProperty("--zoom", (ramp(p, 0.26, 0.34) - ramp(p, 0.9, 0.98)).toFixed(4));
      // The tour: slide i owns [a, b) of TOUR; it fades in over its first
      // stretch and out over the next slide's. Slide 0 is the assembled app.
      const n = el.dataset.slides | 0;
      const span = (TOUR[1] - TOUR[0]) / Math.max(1, n);
      for (let i = 0; i < n; i++) {
        const a = TOUR[0] + i * span;
        // Each slide slides up from below and lands on top of the one before;
        // nothing is removed, so the stack builds up.
        const land = i === 0 ? 1 : ramp(p, a - 0.05, a);
        el.style.setProperty(`--v${i}`, land.toFixed(4));
        // Its caption is shown from its landing until the next slide lands.
        const next = i < n - 1 ? ramp(p, a + span - 0.05, a + span - 0.02) : 0;
        const c = Math.min(land - next, ramp(p, 0.3, 0.34), 1 - ramp(p, 0.88, 0.92));
        el.style.setProperty(`--c${i}`, c.toFixed(4));
      }
    };
    const onScroll = () => { frame ||= requestAnimationFrame(paint); };
    paint();
    window.addEventListener("scroll", onScroll, { passive: true });
    window.addEventListener("resize", onScroll);
    return () => {
      cancelAnimationFrame(frame);
      window.removeEventListener("scroll", onScroll);
      window.removeEventListener("resize", onScroll);
    };
  }, []);
  return ref;
}

/** `slides`: [{ shot, alt, kicker?, title?, caption }] — slide 0 is the
 *  assembled app itself (its `shot` is ignored); the rest are full-window
 *  screenshots swapped in during the tour. */
export default function HeroBuild({ alt, slides = [], className = "" }) {
  const { theme } = useShotTheme();
  const src = (name) => shotSrc(`/assets/shots/hero/${name}.webp`, theme);
  const scene = useScene();
  return (
    <div ref={scene} id="hero-tour" className={`${styles.track} ${className}`} data-slides={slides.length}>
      <div className={styles.pin}>
        <div className={styles.captions}>
          {slides.map((s, i) => (
            <div key={i} className={`${styles.caption} ${styles[`c${i}`] || ""}`}>
              {s.kicker && <span className={styles.capKicker}>{s.kicker}</span>}
              {s.title && <h2 className={styles.capTitle}>{s.title}</h2>}
              <p className={styles.capText}>{s.caption}</p>
            </div>
          ))}
        </div>
        <div className={styles.camera}>
          <div className={styles.window} role="img" aria-label={alt}>
            <div className={styles.frame}>
              <div className={styles.wire} aria-hidden="true">
                <span className={styles.dots}><i /><i /><i /></span>
              </div>
              <img className={styles.real} src={src("chrome")} alt="" draggable="false" />
            </div>
            {PARTS.map((id) => (
              <div key={id} className={`${styles.part} ${styles[id]}`}>
                <div className={styles.wire} aria-hidden="true" />
                <img className={styles.real} src={src(id)} alt="" draggable="false" />
              </div>
            ))}
            <div className={styles.slides}>
              {slides.slice(1).map((s, i) => (
                <img
                  key={s.shot}
                  className={`${styles.slide} ${styles[`v${i + 1}`] || ""}`}
                  src={shotSrc(`/assets/shots/${s.shot}.webp`, theme)}
                  alt={s.alt}
                  loading="lazy"
                  draggable="false"
                />
              ))}
            </div>
          </div>
        </div>
      </div>
    </div>
  );
}
