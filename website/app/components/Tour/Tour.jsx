import { useCallback, useEffect, useRef, useState } from "react";
import { shotSrc, useShotTheme } from "../../lib/shotTheme.jsx";
import styles from "./Tour.module.css";

/** The recorded product tour — one unbroken take through the app, on a loop.
 *  Muted and autoplaying, which is the only way a browser will start it.
 *
 *  The captions and the zooms are not burnt into the video: the recorder writes
 *  a cue file next to it (`tour.json`, `[{t, text, zoom:[scale,x,y]}]`) and this
 *  plays it back over the frame. Rewording a caption or nudging a zoom is a text
 *  edit — no re-recording, no re-encoding. Re-taking the tour does rewrite the
 *  file, so edit the text there and it survives until the next take. */
export default function Tour() {
  const { theme } = useShotTheme();
  const [cues, setCues] = useState([]);
  const [cue, setCue] = useState(null);
  const videoRef = useRef(null);

  useEffect(() => {
    let live = true;
    fetch(shotSrc("/assets/video/tour.json", theme))
      .then((r) => (r.ok ? r.json() : []))
      // No reset first: the previous theme's cue lingers for the length of the
      // fetch, which is a frame or two of the wrong caption at most.
      .then((list) => { if (live) setCues(Array.isArray(list) ? list : []); })
      .catch(() => { /* no cue file — the video still plays, just bare */ });
    return () => { live = false; };
  }, [theme]);

  // timeupdate fires ~4x a second, which is finer than the cues and far cheaper
  // than a rAF loop. The cue objects are stable, so the compare stops the
  // re-render on every tick between beats.
  const onTime = useCallback((e) => {
    const t = e.currentTarget.currentTime;
    let at = null;
    for (const c of cues) {
      if (c.t > t) break;
      at = c;
    }
    setCue((prev) => (prev === at ? prev : at));
  }, [cues]);

  useEffect(() => {
    const el = videoRef.current;
    if (!el) return;
    const [z, x, y] = cue?.zoom || [1, 0.5, 0.5];
    el.style.setProperty("--z", z);
    el.style.setProperty("--zx", `${x * 100}%`);
    el.style.setProperty("--zy", `${y * 100}%`);
  }, [cue, cues]);

  return (
    <section className={styles.section}>
      <div className={`wrap ${styles.head}`}>
        <span className="kicker">The tour</span>
        <h2 className={styles.h2}>See the app in two minutes</h2>
      </div>
      <div className={`wrap ${styles.stage}`}>
        <div className={styles.frame}>
          {/* Keyed on the theme: swapping a <source> mid-playback does nothing,
              the element has to be remounted to pick up the other recording. */}
          <video
            key={theme}
            ref={videoRef}
            className={styles.video}
            src={shotSrc("/assets/video/tour.mp4", theme)}
            poster={shotSrc("/assets/shots/accounts.webp", theme)}
            onTimeUpdate={onTime}
            autoPlay
            loop
            muted
            playsInline
            preload="none"
          />
          {cue?.text ? <p className={styles.cc}>{cue.text}</p> : null}
        </div>
      </div>
    </section>
  );
}
