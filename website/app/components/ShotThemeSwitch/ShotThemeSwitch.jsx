import { useShotTheme } from "../../lib/shotTheme.jsx";
import styles from "./ShotThemeSwitch.module.css";

const OPTIONS = [
  ["dark", "Dark", "M17.5 14.5A7 7 0 0 1 9.5 6.5a7 7 0 1 0 8 8Z"],
  ["light", "Light", "M12 5.5v-2M12 20.5v-2M5.5 12h-2M20.5 12h-2M7.4 7.4 6 6M18 18l-1.4-1.4M7.4 16.6 6 18M18 6l-1.4 1.4M12 8a4 4 0 1 1 0 8 4 4 0 0 1 0-8Z"],
];

/** Fixed to the viewport so the app screenshots can be flipped between the
 *  dark and light themes at any point on the page, not just at the top. */
export default function ShotThemeSwitch() {
  const { theme, choose } = useShotTheme();
  return (
    <div className={styles.dock} data-theme={theme}>
      <span className={styles.label}>Theme</span>
      <div className={styles.pill} role="radiogroup" aria-label="App theme shown in the screenshots">
        <span className={styles.thumb} aria-hidden="true" />
        {OPTIONS.map(([id, text, path]) => (
          <button
            key={id}
            type="button"
            role="radio"
            aria-checked={theme === id}
            className={`${styles.option} ${theme === id ? styles.on : ""}`}
            onClick={() => choose(id)}
          >
            <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.7" strokeLinecap="round" strokeLinejoin="round" aria-hidden="true">
              <path d={path} />
            </svg>
            {text}
          </button>
        ))}
      </div>
    </div>
  );
}
