/* ⚠️ VISUAL-PROTOTYPE ONLY — demo avatar photos for the bento mockups.
 * Deterministic name → local image mapping (faces under public/images/). */
export const FACES = ['/images/a1.jpg', '/images/a2.jpg', '/images/a3.jpg', '/images/a4.jpg', '/images/a5.jpg', '/images/a6.jpg'];

export function faceFor(name) {
  let h = 0;
  for (let i = 0; i < name.length; i += 1) h = (h * 31 + name.charCodeAt(i)) >>> 0;
  return FACES[h % FACES.length];
}
