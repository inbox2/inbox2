import styles from "./StatChips.module.css";

const STATS = [
  ["One inbox", "per domain, and every mailbox is a view over it"],
  ["Zero DNS", "runs over Gmail, Microsoft 365 or IMAP"],
  ["One price", "per organisation, mailboxes are free"],
];

/** Hero → page transition: the black curves down into the off-white, and the
 *  three stats float on the seam as gradient-outlined chips. */
export default function StatChips() {
  return (
    <section className={styles.seam}>
      <div className={styles.glow} aria-hidden="true" />
      <svg className={styles.curve} viewBox="0 0 1440 160" preserveAspectRatio="none" aria-hidden="true">
        <path d="M0 0 H1440 V36 C1120 172 320 172 0 36 Z" fill="var(--ink)" />
      </svg>
      <div className={styles.chips}>
        {STATS.map(([num, sub]) => (
          <div key={num} className={styles.chip}>
            <div>
              <span className={styles.num}>{num}</span>
              <span className={styles.sub}>{sub}</span>
            </div>
          </div>
        ))}
      </div>
    </section>
  );
}
