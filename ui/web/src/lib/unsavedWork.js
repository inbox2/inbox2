// Open editors whose text may not have reached the server, for the signed-out
// screen: it says so and offers each one's text to copy, because the tab keeps
// its pages mounted (and their contents in memory) behind the screen.
const entries = new Map()
const listeners = new Set()

/**
 * Register an open editor. label: what to call it ("Page: Launch plan");
 * text: () => its current plain text. Returns an unregister function.
 */
export function registerUnsaved(label, text) {
  const id = Symbol(label)
  entries.set(id, { label, text })
  listeners.forEach((fn) => fn())
  return () => { entries.delete(id); listeners.forEach((fn) => fn()) }
}

/** The open editors with any text: [{ label, text: string }]. */
export function unsavedWork() {
  return [...entries.values()]
    .map((e) => { try { return { label: e.label, text: String(e.text() || '') } } catch { return { label: e.label, text: '' } } })
    .filter((e) => e.text.trim())
}

/** Subscribe to registrations coming and going. Returns an unsubscribe. */
export function onUnsavedChange(fn) {
  listeners.add(fn)
  return () => listeners.delete(fn)
}
