import { Link } from "react-router";
import styles from "./Legal.module.css";

/**
 * Shared chrome for /privacy and /terms: dark title band, a contents rail and a
 * measured prose column. `sections` drives both the rail and the anchor ids, so
 * a new <h2> is added by adding an entry here and using the same id.
 */
export default function Legal({ title, lede, updated, sections, children }) {
  return (
    <>
      <header className={`${styles.band} on-dark`}>
        <div className={`wrap ${styles.bandInner}`}>
          <span className="kicker kicker--accent">Legal</span>
          <h1 className={styles.h1}>{title}</h1>
          <p className={`lede ${styles.lede}`}>{lede}</p>
          <p className={styles.updated}>Last updated {updated}</p>
        </div>
      </header>

      <div className={`wrap ${styles.body}`}>
        <nav className={styles.rail} aria-label="On this page">
          <span className={styles.railLabel}>On this page</span>
          {sections.map((s) => (
            <a key={s.id} href={`#${s.id}`}>{s.label}</a>
          ))}
          <span className={styles.railLabel}>The other one</span>
          <Link to={title === "Privacy policy" ? "/terms" : "/privacy"}>
            {title === "Privacy policy" ? "Terms of service" : "Privacy policy"}
          </Link>
        </nav>
        <article className={styles.prose}>{children}</article>
      </div>
    </>
  );
}

/** A fact counsel still has to supply. Loud on purpose so it cannot ship quietly. */
export function Fill({ children }) {
  return <mark className={styles.fill}>[to confirm: {children}]</mark>;
}
