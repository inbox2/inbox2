import { shotSrc, useShotTheme } from "../../lib/shotTheme.jsx";
import { useReveal } from "../../lib/reveal.js";
import styles from "./WindowFrame.module.css";

/**
 * Desktop window / browser frame around an app screenshot.
 * `reflect` adds the flipped, fading mirror underneath.
 * `bare` drops the drawn title bar — the screenshots taken by
 * website/scripts/shots.py capture the app's own chrome, and two title bars
 * stacked on top of each other reads as a mistake.
 */
export default function WindowFrame({ src, alt, title = "inbox2", web = false, bare = false, reflect = false, className = "" }) {
  const { theme } = useShotTheme();
  const reveal = useReveal();
  const themed = shotSrc(src, theme);
  const frame = (
    <div className={styles.frame}>
      {!bare && (
        <div className={styles.bar}>
          <i /><i /><i />
          {web ? (
            <div className={styles.url}><b>mail.inbox2.com</b>/inbox</div>
          ) : (
            <span className={styles.title}>{title}</span>
          )}
        </div>
      )}
      <img src={themed} alt={alt} loading="lazy" />
    </div>
  );
  if (!reflect) return <div ref={reveal} className={`reveal ${className}`}>{frame}</div>;
  return (
    <div ref={reveal} className={`reveal ${styles.reflectWrap} ${className}`}>
      {frame}
      <div className={styles.reflection} aria-hidden="true">
        <div className={styles.flip}>{frame}</div>
      </div>
    </div>
  );
}
