// The global search lives in the ChromeBar (rendered on every primary screen) and
// is tagged with `data-global-search`. ⌘K and the command palette focus it through
// this helper rather than threading a ref across the page tree.
export function focusGlobalSearch() {
  const el = document.querySelector('[data-global-search]');
  if (el) {
    el.focus();
    el.select?.();
    return true;
  }
  return false;
}
