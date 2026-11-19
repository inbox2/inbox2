import { useEffect, useState } from "react";
import styles from "./TypeCycle.module.css";

/**
 * Typewriter that cycles a list of words. The first word renders in full, so
 * the prerendered HTML (and anyone on reduced motion) reads as a finished
 * sentence; the animation starts by deleting it. `once` stops after that first
 * pass has retyped the last word, caret still blinking.
 */
export default function TypeCycle({ words, className = "", once = false }) {
  const [i, setI] = useState(0);
  const [len, setLen] = useState(words[0].length);
  const [erasing, setErasing] = useState(false);
  const [retyped, setRetyped] = useState(false);

  useEffect(() => {
    if (window.matchMedia("(prefers-reduced-motion: reduce)").matches) return undefined;
    const word = words[i];
    const done = !erasing && len === word.length;
    if (done && once && retyped && i === words.length - 1) return undefined;
    const empty = erasing && len === 0;
    const delay = done ? 1900 : empty ? 240 : erasing ? 34 : 62;
    const t = setTimeout(() => {
      if (done) setErasing(true);
      else if (empty) {
        setErasing(false);
        setRetyped(true);
        setI((n) => (n + 1) % words.length);
      } else setLen((n) => n + (erasing ? -1 : 1));
    }, delay);
    return () => clearTimeout(t);
  }, [words, i, len, erasing, retyped, once]);

  return (
    <span className={`${styles.type} ${className}`}>
      {words[i].slice(0, len)}
      <span className={styles.caret} />
    </span>
  );
}
