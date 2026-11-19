import { startDrag } from '../../lib/tauri';
import WindowControls from '../Chrome/WindowControls';
import styles from './ManagementLayout.module.css';

/* Shell for every MANAGEMENT-layer screen (auth, onboarding, admin console).
 * Provides the lavender page background, the inbox2 brand mark, and an optional
 * vertically-centred content column (auth / wizard cards). The dark Aero app
 * client uses its own shell (layout.module.css) — this is deliberately separate.
 *
 *   centered    — vertically centre the children (auth / onboarding cards)
 *   brand       — show the top-left inbox2 brand bar (off when the card carries
 *                 its own logo, e.g. the auth screens)
 *   coBrandLogo — a connected domain's company logo; when set the brand bar
 *                 leads with it and trails a subtle "via inbox2" (white-label)
 *   topRight    — optional node pinned top-right (e.g. a step indicator)
 */
export default function ManagementLayout({ centered = false, brand = true, coBrandLogo = null, topRight, children }) {
  return (
    <div className={`${styles.root} management`}>
      <div className={styles.dragRegion} role="presentation" onMouseDown={startDrag}><WindowControls /></div>
      {(brand || topRight) && (
        <header className={styles.brandBar}>
          {brand ? (
            coBrandLogo ? (
              <span className={styles.brand}>
                <img src={coBrandLogo} alt="" className={styles.coBrandMark} />
                <span className={styles.coBrandVia}>
                  via <img src="/logo-mark.png" alt="" className={styles.coBrandViaMark} /> inbox2
                </span>
              </span>
            ) : (
              <span className={styles.brand}>
                <img src="/logo-mark.png" alt="" className={styles.brandMark} />
                inbox2
              </span>
            )
          ) : <span />}
          {topRight}
        </header>
      )}
      <main className={centered ? styles.centered : styles.flow}>
        {children}
      </main>
    </div>
  );
}
