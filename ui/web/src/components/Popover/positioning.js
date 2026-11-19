// Shared anchored-positioning math for portal popovers.
//
// Extracted from the near-identical clamp/flip effects that EmailPreviewPopup
// and EventDetailPopup each hand-rolled. Given the floating element's measured
// size and either an anchor rect (placement-relative) or an explicit point,
// returns viewport-clamped { top, left } in fixed-position coordinates.

const VIEWPORT_MARGIN = 10;

/**
 * Compute clamped coordinates for a popover anchored to a rect.
 *
 * @param {DOMRect|{top,left,bottom,right,width,height}} anchorRect
 * @param {{width:number,height:number}} size — measured popover size
 * @param {object} opts
 * @param {'bottom'|'top'|'right'|'left'} opts.placement — preferred side (default 'bottom')
 * @param {number} opts.offset — gap between anchor and popover (default 6)
 * @param {number} opts.margin — min distance from viewport edge (default 10)
 * @returns {{top:number, left:number}}
 */
export function positionFromAnchor(anchorRect, size, opts = {}) {
  const { placement = 'bottom', offset = 6, margin = VIEWPORT_MARGIN } = opts;
  const vw = window.innerWidth;
  const vh = window.innerHeight;
  const { width: pw, height: ph } = size;

  let top;
  let left;

  if (placement === 'top' || placement === 'bottom') {
    // Horizontally centered on the anchor.
    left = anchorRect.left + anchorRect.width / 2 - pw / 2;
    if (placement === 'top') {
      top = anchorRect.top - ph - offset;
      // Flip down if it would overflow the top edge.
      if (top < margin) top = anchorRect.bottom + offset;
    } else {
      top = anchorRect.bottom + offset;
      // Flip up if it would overflow the bottom edge.
      if (top + ph > vh - margin) top = anchorRect.top - ph - offset;
    }
  } else {
    // Vertically aligned to the anchor top.
    top = anchorRect.top;
    if (placement === 'left') {
      left = anchorRect.left - pw - offset;
      if (left < margin) left = anchorRect.right + offset;
    } else {
      left = anchorRect.right + offset;
      if (left + pw > vw - margin) left = anchorRect.left - pw - offset;
    }
  }

  return clampToViewport({ top, left }, size, margin);
}

/**
 * Clamp an explicit { top, left } point so the popover stays on-screen.
 *
 * @param {{top:number,left:number}} point
 * @param {{width:number,height:number}} size
 * @param {number} margin
 * @returns {{top:number, left:number}}
 */
export function clampToViewport(point, size, margin = VIEWPORT_MARGIN) {
  const vw = window.innerWidth;
  const vh = window.innerHeight;
  const { width: pw, height: ph } = size;

  let { top, left } = point;

  if (left < margin) left = margin;
  if (left + pw > vw - margin) left = vw - pw - margin;
  if (top < margin) top = margin;
  if (top + ph > vh - margin) top = vh - ph - margin;

  return { top, left };
}
