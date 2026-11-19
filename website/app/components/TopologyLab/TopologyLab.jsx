import { useEffect, useRef, useState } from "react";
import { TOPOLOGIES, KIND_STYLE, NODE_DESC } from "./topologies.js";
import styles from "./TopologyLab.module.css";

/**
 * TopologyLab — the deployment-mode switcher + the isometric board it drives.
 * The board is the zero-dependency 2D canvas scene (canvas-iso.client.js),
 * loaded lazily client-side so nothing renders during prerender. Hovering a
 * block raises a colour-matched explainer popup.
 */
const DEFAULT_ID = "cloud-mx";

export default function TopologyLab() {
  const canvasRef = useRef(null);
  const sceneRef = useRef(null);
  const popupRef = useRef(null);
  const [mounted, setMounted] = useState(false);
  const [activeId, setActiveId] = useState(DEFAULT_ID);
  const [popup, setPopup] = useState(null);

  const active = TOPOLOGIES.find((t) => t.id === activeId) || TOPOLOGIES[0];

  // eslint-disable-next-line react-hooks/set-state-in-effect -- the canvas scene is client-only; this gate is what keeps it out of the prerender.
  useEffect(() => setMounted(true), []);

  useEffect(() => {
    if (!mounted) return;
    let scene;
    let cancelled = false;
    import("./canvas-iso.client.js").then((m) => {
      if (cancelled || !canvasRef.current) return;
      scene = m.createIsoScene(canvasRef.current, { onHover: setPopup });
      sceneRef.current = scene;
      scene.setTopology(TOPOLOGIES.find((t) => t.id === activeId) || TOPOLOGIES[0]);
    });
    return () => {
      cancelled = true;
      scene?.destroy();
      sceneRef.current = null;
    };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [mounted]);

  useEffect(() => {
    // eslint-disable-next-line react-hooks/set-state-in-effect -- clears the hover popup left over from the previous topology.
    setPopup(null);
    sceneRef.current?.setTopology(active);
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [activeId]);

  useEffect(() => {
    const el = popupRef.current;
    if (!el || !popup) return;
    const style = KIND_STYLE[popup.kind];
    el.style.setProperty("--x", `${popup.x}px`);
    el.style.setProperty("--y", `${popup.y}px`);
    el.style.setProperty("--accent", style.hex);
    el.style.setProperty("--glow", style.glow);
  }, [popup]);

  const usedKinds = [...new Set(active.nodes.map((node) => node.kind))];

  return (
    <div className={styles.lab}>
      <div className={styles.tabs} role="tablist">
        {TOPOLOGIES.map((t) => (
          <button
            key={t.id}
            type="button"
            role="tab"
            aria-selected={t.id === activeId}
            className={`${styles.tab} ${t.id === activeId ? styles.active : ""}`}
            onClick={() => setActiveId(t.id)}
          >
            <span className={styles.tier}>{t.tier}</span>
            <span className={styles.label}>{t.label}</span>
            <span className={styles.sub}>{t.sub}</span>
          </button>
        ))}
      </div>

      <div className={styles.stage}>
        {!mounted && <div className={styles.loading}>Loading scene…</div>}
        {mounted && <canvas ref={canvasRef} className={styles.canvas} />}
        <div className={styles.stageMeta}>{active.label} · hover a block to see what it does</div>
        {mounted && popup && (
          <div ref={popupRef} className={styles.popup} role="tooltip">
            <span className={styles.popupTitle}>{popup.label}</span>
            <span className={styles.popupKind}>{KIND_STYLE[popup.kind].label}</span>
            <p className={styles.popupDesc}>{NODE_DESC[popup.id] || ""}</p>
          </div>
        )}
      </div>

      <div className={styles.footer}>
        <p className={styles.blurb}>{active.blurb}</p>
        <ul className={styles.legend}>
          {usedKinds.map((k) => (
            <li key={k} className={styles.legendItem}>
              <span className={styles.swatch} ref={(el) => el && el.style.setProperty("--c", KIND_STYLE[k].hex)} />
              {KIND_STYLE[k].label}
            </li>
          ))}
        </ul>
      </div>
    </div>
  );
}
