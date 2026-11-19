import DotMatrix from '../DotMatrix';
import useTheme from '../../hooks/useTheme';
import { startDrag } from '../../lib/tauri';
import WindowControls from '../Chrome/WindowControls';
import styles from '../../pages/auth/auth.module.css';

export default function AuthLayout({ title, children, topLeft }) {
  // The login / onboarding screens render outside the app shell, so nothing else
  // pulls in the theme — without this they'd miss the active theme's variant
  // overrides (e.g. the Warm theme's violet button) and fall back to the base
  // brown button. Subscribing applies the theme (data-theme + overrides).
  useTheme();
  return (
    <div className={styles.authPage}>
      <div className={styles.dragRegion} role="presentation" onMouseDown={startDrag}><WindowControls /></div>
      <DotMatrix pixelGrid />
      {topLeft}
      <div className={styles.authCard}>
        <div className={styles.authLogo}>
          <img src="/logo-mark.png" alt="inbox2" />
          <span>inbox2</span>
        </div>
        <h1 className={styles.authTitle}>{title}</h1>
        {children}
      </div>
    </div>
  );
}
