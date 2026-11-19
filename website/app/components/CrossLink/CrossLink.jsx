import Button from "../Button/Button.jsx";
import styles from "./CrossLink.module.css";

/** The band that hands the reader over to the site's other half:
 *  the apps page points at MX, the MX page points back at the apps. */
export default function CrossLink({ kicker, title, body, cta, to, img, alt, children }) {
  return (
    <section className={styles.section}>
      <div className="wrap">
        <div className={styles.card}>
          <div className={`${styles.inner} on-dark`}>
            <div className={styles.text}>
              <span className="kicker kicker--accent">{kicker}</span>
              <h2 className={styles.h2}>{title}</h2>
              <p className={styles.body}>{body}</p>
              <Button variant="accent" to={to}>{cta}</Button>
            </div>
            {img ? <img className={styles.art} src={img} alt={alt} loading="lazy" /> : <div className={styles.art}>{children}</div>}
          </div>
        </div>
      </div>
    </section>
  );
}
