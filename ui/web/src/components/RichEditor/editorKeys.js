// macOS hands a function key WebKit has no binding for straight to the editor as
// text: End arrives as U+F72B and lands in the draft as a tofu box. Move the
// caret ourselves (Home/End) and drop the private-use characters (PageUp/Down,
// F-keys) that would otherwise be typed into the message.
export function handleEditorKeyDown(_view, event) {
  if (event.key !== 'Home' && event.key !== 'End') return false
  if (event.metaKey || event.ctrlKey || event.altKey) return false
  const sel = window.getSelection?.()
  if (!sel?.modify) return false
  sel.modify(event.shiftKey ? 'extend' : 'move', event.key === 'End' ? 'forward' : 'backward', 'lineboundary')
  return true
}

// U+F700-F7FF is AppKit's function-key block; the rest of the private-use area
// (the Apple logo at U+F8FF, icon fonts) stays typeable.
export const isFunctionKeyText = (text) => /[\uF700-\uF7FF]/.test(text)
