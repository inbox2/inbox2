import { shotSrc, useShotTheme } from "../../lib/shotTheme.jsx";
import { useReveal } from "../../lib/reveal.js";
import styles from "./PhoneFrame.module.css";

/**
 * Phone bezel around an app screenshot — the PhoneFrame to WindowFrame's desktop.
 * The stills come out of the simulator at the full screen (website/scripts/
 * mobile-shots.sh), status bar and Dynamic Island included, so the frame only
 * has to add the rim and round the corners off.
 *
 * Pass `children` instead of `src` to put something drawn (the lock screen) in
 * the same bezel.
 */
export default function PhoneFrame({ src, alt = "", className = "", children }) {
  const { theme } = useShotTheme();
  const reveal = useReveal();
  return (
    <div ref={reveal} className={`reveal ${styles.phone} ${className}`}>
      <div className={styles.screen}>
        {src ? <img src={shotSrc(src, theme)} alt={alt} loading="lazy" /> : children}
      </div>
    </div>
  );
}
