import styles from "./Starfield.module.css";

const TWINKLES = 10; // positions live in Starfield.module.css, one nth-child each

/** Decorative night sky for the dark heroes. Render it first inside a positioned section. */
export default function Starfield() {
  return (
    <div className={styles.sky} aria-hidden="true">
      <div className={styles.stars} />
      <div className={styles.twinkles}>
        {Array.from({ length: TWINKLES }, (_, i) => <i key={i} />)}
      </div>
    </div>
  );
}
