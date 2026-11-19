// Keyboard focus plumbing shared by the dialog shells (Modal, SlideOver).

export const FOCUSABLE = 'a[href], button:not(:disabled), input:not(:disabled), select:not(:disabled), textarea:not(:disabled), [tabindex]:not([tabindex="-1"])';

export function focusables(container) {
  return [...container.querySelectorAll(FOCUSABLE)].filter((el) => el.offsetParent !== null);
}

// Wrap Tab / Shift+Tab inside `container`. Call from a keydown handler; a no-op
// for every other key.
export function trapTab(e, container) {
  if (e.key !== 'Tab' || !container) return;
  const items = focusables(container);
  if (items.length === 0) { e.preventDefault(); return; }
  const i = items.indexOf(document.activeElement);
  if (e.shiftKey ? i <= 0 : i === items.length - 1) {
    e.preventDefault();
    items[e.shiftKey ? items.length - 1 : 0].focus();
  }
}
