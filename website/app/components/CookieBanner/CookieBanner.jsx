import { useEffect, useState } from "react";
import { Link } from "react-router";
import {
  ANALYTICS_CONFIGURED,
  CONSENT,
  applyConsent,
  readConsent,
  startAnalytics,
} from "../../lib/consent.js";
import styles from "./CookieBanner.module.css";

/** Footer's "Cookie settings" button fires this to reopen the choice. */
export const REOPEN_EVENT = "inbox2:cookie-settings";

export default function CookieBanner() {
  const [open, setOpen] = useState(false);

  useEffect(() => {
    if (readConsent() === CONSENT.ACCEPTED) startAnalytics();
    // eslint-disable-next-line react-hooks/set-state-in-effect -- the stored consent is only readable in the browser.
    else if (ANALYTICS_CONFIGURED && readConsent() === null) setOpen(true);

    const reopen = () => setOpen(true);
    window.addEventListener(REOPEN_EVENT, reopen);
    return () => window.removeEventListener(REOPEN_EVENT, reopen);
  }, []);

  // The banner owns the bottom of the screen while it is up. On a phone it is
  // full width, so the theme switch has to step out of its way.
  useEffect(() => {
    const root = document.documentElement;
    if (open) root.dataset.cookieBanner = "1";
    else delete root.dataset.cookieBanner;
    return () => { delete root.dataset.cookieBanner; };
  }, [open]);

  if (!open) return null;

  const choose = (value) => {
    applyConsent(value, { reloadOnWithdraw: true });
    setOpen(false);
  };

  return (
    <div className={styles.banner} role="dialog" aria-labelledby="cookie-title">
      <div className={styles.text}>
        <h2 id="cookie-title" className={styles.title}>Analytics cookies</h2>
        <p className={styles.body}>
          Google Analytics and PostHog show us which pages people read. Nothing loads
          until you accept, and you can change your choice in the footer.{" "}
          <Link to="/privacy#cookies" className={styles.more}>What we collect</Link>
        </p>
      </div>
      <div className={styles.actions}>
        <button type="button" className={styles.decline} onClick={() => choose(CONSENT.DECLINED)}>
          Decline
        </button>
        <button type="button" className={styles.accept} onClick={() => choose(CONSENT.ACCEPTED)}>
          Accept
        </button>
      </div>
    </div>
  );
}
