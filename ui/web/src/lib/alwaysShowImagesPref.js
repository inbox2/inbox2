// Global "always show images" preference — when on, remote images load directly
// for every message without the "Show images" prompt. Set from the banner's
// "Always show images" action. Read synchronously by the render path.
import { ALWAYS_SHOW_IMAGES } from './storageKeys';

export function getAlwaysShowImages() {
  return localStorage.getItem(ALWAYS_SHOW_IMAGES) === 'true';
}

export function setAlwaysShowImages(value) {
  localStorage.setItem(ALWAYS_SHOW_IMAGES, String(!!value));
}
