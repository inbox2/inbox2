/** Drop leading Re:/Fwd:/Fw: prefixes (possibly repeated) so we show the
 *  underlying conversation subject. Falls back to the original if stripping
 *  would leave it empty. */
export function cleanSubject(s) {
  if (!s) return s;
  return s.replace(/^((re|fwd?|fw)\s*:\s*)+/i, '').trim() || s;
}
