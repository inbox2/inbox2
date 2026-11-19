import { Link } from "react-router";
import styles from "./Mark.module.css";

/** The classic inbox2 box: a still of assets/3d/logo-cube.glb. */
export function Mark({ size = 30 }) {
  return (
    <img
      className={styles.mark}
      src="/assets/3d/logo-cube.webp"
      width={size}
      height={size}
      alt=""
      aria-hidden="true"
    />
  );
}

/** Mark + wordmark lockup, links home. `big` is the footer's size. */
export default function Lockup({ big = false }) {
  return (
    <Link to="/" className={`${styles.lockup} ${big ? styles.big : ""}`} aria-label="inbox2 home">
      <Mark size={big ? 34 : 30} />
      <span>inbox2</span>
    </Link>
  );
}
