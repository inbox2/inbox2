import styles from "./Proof.module.css";

// Pilot placeholders — swap for real quotes before launch.
const BIG = ["We deleted eleven forwarding rules on day one and nobody noticed anything missing.", "Ops lead, 40-person SaaS, Utrecht (pilot)"];
const SMALL = [
  ["Support finally sees invoices without finance seeing support.", "Founder, agency, Berlin (pilot)"],
  ["The DPO signed off in one meeting because 'where is the data' had a one-word answer.", "IT manager, municipality (pilot)"],
];

export default function Proof() {
  return (
    <section className={styles.section}>
      <div className={`wrap ${styles.grid}`}>
        <div className={styles.lead}>
          <h2 className={styles.h2}>After 1 month:</h2>
          <div className={styles.art}><img src="/assets/3d/quote.webp" alt="Three speech bubbles" loading="lazy" /></div>
        </div>
        <div className={styles.right}>
          <blockquote className={styles.big}>
            <p>"{BIG[0]}"</p>
            <cite>{BIG[1]}</cite>
          </blockquote>
          <div className={styles.smalls}>
            {SMALL.map(([q, who]) => (
              <blockquote key={who} className={styles.small}>
                <p>"{q}"</p>
                <cite>{who}</cite>
              </blockquote>
            ))}
          </div>
        </div>
      </div>
    </section>
  );
}
