import Button from "../Button/Button.jsx";
import { SIGNUP_URL } from "../../lib/nav.js";
import styles from "./Closing.module.css";

// Six leaves: [left %, size px, delay s, duration s, green?]
const LEAVES = [
  [8, 200, 0, 27, false],
  [22, 140, -9, 31, true],
  [40, 120, -17, 25, false],
  [62, 160, -5, 29, true],
  [78, 210, -21, 33, false],
  [90, 130, -13, 28, true],
];

/** Full-bleed closing block: gradient headline, envelopes falling into the tray forever. */
export default function Closing() {
  return (
    <section className={`${styles.closing} on-dark`}>
      <div className={styles.glowA} aria-hidden="true" />
      <div className={styles.glowB} aria-hidden="true" />
      <div className={styles.rain} aria-hidden="true">
        {LEAVES.map(([left, size, delay, dur, green], i) => (
          /* Per-leaf position and animation timing — no CSS way to say
             "the nth one, offset by n". */
          /* eslint-disable react/forbid-dom-props */
          <img
            key={i}
            src={green ? "/assets/3d/env-green.webp" : "/assets/3d/env-pink.webp"}
            alt=""
            className={styles.leaf}
            style={{ left: `${left}%`, width: size, animationDelay: `${delay}s`, animationDuration: `${dur}s` }}
          />
          /* eslint-enable react/forbid-dom-props */
        ))}
      </div>
      <div className={`wrap ${styles.inner}`}>
        <h2 className={styles.h2}>Replace your forwarding rules with one inbox</h2>
        <p className={styles.p}>Connect a domain in ten minutes, or try it on your own Gmail first. You need no card and we never count seats.</p>
        <div className={styles.ctas}>
          <Button size="lg" href={SIGNUP_URL}>Start free</Button>
          <Button size="lg" variant="glass" href="mailto:hello@inbox2.com">Talk to us</Button>
        </div>
        <img className={styles.pool} src="/assets/3d/pool.webp" alt="Envelopes settled in the domain's inbox" loading="lazy" />
      </div>
    </section>
  );
}
