import { useEffect, useRef, useState } from "react";
import styles from "./Model3D.module.css";

/**
 * A real 3D object on the page: loads the <model-viewer> web component on the
 * client and spins the GLB on its own vertical axis. Shows a spinner until the
 * model has loaded; nothing renders during prerender except the empty stage.
 */
export default function Model3D({ src, alt, speed = "18deg", className = "" }) {
  const [ready, setReady] = useState(false);
  const [loaded, setLoaded] = useState(false);
  const ref = useRef(null);

  useEffect(() => {
    let cancelled = false;
    import("@google/model-viewer").then(() => {
      if (!cancelled) setReady(true);
    });
    return () => {
      cancelled = true;
    };
  }, []);

  useEffect(() => {
    const el = ref.current;
    if (!el) return;
    const done = () => setLoaded(true);
    el.addEventListener("load", done);
    if (el.loaded) done();
    return () => el.removeEventListener("load", done);
  }, [ready]);

  return (
    <div className={`${styles.stage} ${className}`}>
      {ready && (
        <model-viewer
          ref={ref}
          class={styles.viewer}
          src={src}
          alt={alt}
          auto-rotate
          rotation-per-second={speed}
          interaction-prompt="none"
          disable-zoom
          disable-pan
          disable-tap
          shadow-intensity="0.45"
          shadow-softness="1"
          exposure="1.3"
          tone-mapping="neutral"
          environment-image="neutral"
          camera-orbit="100deg 76deg 108%"
          field-of-view="28deg"
        />
      )}
      {!loaded && <span className={styles.spinner} aria-label="Loading 3D model" role="status" />}
    </div>
  );
}
