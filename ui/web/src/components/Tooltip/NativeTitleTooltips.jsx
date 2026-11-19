import { useEffect, useRef, useState } from 'react'
import { createPortal } from 'react-dom'
import styles from './Tooltip.module.css'

// Elements where `title` is an accessibility label, not a hover hint — leave
// those alone (an <iframe> without a title fails a11y checks).
const SEMANTIC = new Set(['IFRAME', 'BASE', 'SVG', 'TITLE'])

/**
 * Mounted once at the app root: every element carrying a native `title` gets our
 * own tooltip instead of the OS one. Hovering strips the attribute (that's the
 * only way to suppress the system bubble) and restores it on the way out, so
 * call sites keep the plain `title="…"` prop and nothing has to be wrapped in
 * <Tooltip> by hand.
 *
 * ponytail: one delegated listener beats wrapping ~60 call sites, and it also
 * covers any `title` added later.
 */
export default function NativeTitleTooltips() {
  const [tip, setTip] = useState(null); // { text, rect }
  const elRef = useRef(null);
  const tipRef = useRef(null);

  useEffect(() => {
    // Put the title back the moment the pointer leaves (or anything moves), so
    // the DOM is never left permanently stripped.
    const restore = () => {
      const el = elRef.current;
      if (el) {
        if (el.dataset.nativeTitle != null) {
          el.setAttribute('title', el.dataset.nativeTitle);
          delete el.dataset.nativeTitle;
        }
        elRef.current = null;
      }
      setTip(null);
    };

    const onOver = (e) => {
      const el = e.target.closest?.('[title]');
      if (el === elRef.current) return;
      restore();
      if (!el || SEMANTIC.has(el.tagName)) return;
      const text = el.getAttribute('title');
      if (!text) return;
      el.dataset.nativeTitle = text;
      el.removeAttribute('title');
      elRef.current = el;
      setTip({ text, rect: el.getBoundingClientRect() });
    };

    document.addEventListener('mouseover', onOver, true);
    document.addEventListener('mouseleave', restore, true);
    window.addEventListener('scroll', restore, true);
    window.addEventListener('blur', restore);
    document.addEventListener('mousedown', restore, true);
    return () => {
      document.removeEventListener('mouseover', onOver, true);
      document.removeEventListener('mouseleave', restore, true);
      window.removeEventListener('scroll', restore, true);
      window.removeEventListener('blur', restore);
      document.removeEventListener('mousedown', restore, true);
      restore();
    };
  }, []);

  // Same measure-then-place pass as <Tooltip>: clamp inside the viewport and
  // flip below the trigger when there's no room above.
  useEffect(() => {
    if (!tip) return;
    const id = requestAnimationFrame(() => {
      const el = tipRef.current;
      if (!el) return;
      const { rect } = tip;
      let left = rect.left + rect.width / 2 - el.offsetWidth / 2;
      if (left < 4) left = 4;
      if (left + el.offsetWidth > window.innerWidth - 4) left = window.innerWidth - el.offsetWidth - 4;
      el.style.setProperty('--tip-x', `${left}px`);
      if (rect.top - 6 - el.offsetHeight < 4) {
        el.style.setProperty('--tip-y', `${rect.bottom + 6}px`);
        el.dataset.placement = 'below';
      } else {
        el.style.setProperty('--tip-y', `${rect.top - 6}px`);
        el.dataset.placement = 'above';
      }
    });
    return () => cancelAnimationFrame(id);
  }, [tip]);

  if (!tip) return null;
  return createPortal(
    <div ref={tipRef} className={styles.tooltip}>{tip.text}</div>,
    document.body
  );
}
