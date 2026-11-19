import { useEffect, useRef } from 'react';
import styles from './MgmtMeter.module.css';

// Thin progress meter whose fill reflects a real 0–1 ratio. Width is driven by a
// CSS custom property (inline styles are banned by F1/ESLint). A parent can set
// --meter-color to tell one meter from another (the Disk upload panel's total).
export default function MgmtMeter({ value }) {
  const ref = useRef(null);
  const pct = Math.max(0, Math.min(1, value || 0)) * 100;
  useEffect(() => {
    ref.current?.style.setProperty('--meter-fill', `${pct}%`);
  }, [pct]);
  return <div className={styles.meter}><span ref={ref} className={styles.meterFill} /></div>;
}
