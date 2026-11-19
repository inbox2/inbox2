import { Link } from "react-router";
import Lockup from "../Mark/Mark.jsx";
import { OsIcon, PLATFORMS } from "../OsIcons/OsIcons.jsx";
import { FOOTER_COLUMNS, FOOTER_LEGAL, CLI_RELEASE_PAGE } from "../../lib/nav.js";
import { REOPEN_EVENT } from "../CookieBanner/CookieBanner.jsx";
import styles from "./Footer.module.css";

export default function Footer() {
  return (
    <footer className={styles.footer}>
      <div className={styles.inner}>
        <div className={styles.top}>
          <div className={styles.brand}>
            <Lockup big />
            <p className={styles.blurb}>inbox2 gives each domain one shared inbox, each person a view over it, and rules for the rest.</p>
            <span className={styles.label}>Free native apps</span>
            <div className={styles.badges}>
              {[...PLATFORMS.map((p) => ({ ...p, href: "/download" })), { id: "cli", name: "CLI", href: CLI_RELEASE_PAGE }].map((p) => (
                <a key={p.id} href={p.href} className={styles.badge} {...(p.id === "cli" ? { target: "_blank", rel: "noopener" } : {})}>
                  <OsIcon id={p.id} size={14} />
                  {p.name}
                </a>
              ))}
            </div>
          </div>
          {FOOTER_COLUMNS.map((col) => (
            <div key={col.title} className={styles.col}>
              <span className={styles.label}>{col.title}</span>
              {col.items.map((it) =>
                it.to ? (
                  <Link key={it.label} to={it.to}>{it.label}</Link>
                ) : (
                  <a key={it.label} href={it.href} target="_blank" rel="noopener">{it.label}</a>
                ),
              )}
            </div>
          ))}
        </div>
        <div className={styles.jumbo} aria-hidden="true">inbox2</div>
        <div className={styles.legal}>
          <span>© {new Date().getFullYear()} Sadiq Beheer B.V., trading as inbox2. Made in the Netherlands, hosted wherever you choose.</span>
          <div className={styles.social}>
            {FOOTER_LEGAL.map((it) =>
              it.to ? (
                <Link key={it.label} to={it.to}>{it.label}</Link>
              ) : it.action ? (
                <button
                  key={it.label}
                  type="button"
                  className={styles.linkButton}
                  onClick={() => window.dispatchEvent(new Event(REOPEN_EVENT))}
                >
                  {it.label}
                </button>
              ) : (
                <a key={it.label} href={it.href} target="_blank" rel="noopener">{it.label}</a>
              ),
            )}
          </div>
        </div>
      </div>
    </footer>
  );
}
