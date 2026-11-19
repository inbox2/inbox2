import { useEffect, useRef } from "react";

/** Scroll reveal that never depends on JS to *show* anything: the element
 *  renders visible, and only once hydration runs is an off-screen element
 *  marked `out` (hidden), to be released as it scrolls in. If JS never runs
 *  (a content blocker eating a chunk, say) the page reads exactly as before. */
export function useReveal() {
  const ref = useRef(null);
  useEffect(() => {
    const el = ref.current;
    if (!el) return undefined;
    if (window.matchMedia("(prefers-reduced-motion: reduce)").matches || !("IntersectionObserver" in window)) return undefined;
    const r = el.getBoundingClientRect();
    if (r.bottom > 0 && r.top < window.innerHeight) return undefined;
    el.classList.add("out");
    const show = () => el.classList.remove("out");
    const io = new IntersectionObserver((entries) => {
      if (!entries.some((e) => e.isIntersecting)) return;
      show();
      io.disconnect();
    }, { rootMargin: "0px 0px -10% 0px" });
    io.observe(el);
    return () => io.disconnect();
  }, []);
  return ref;
}
