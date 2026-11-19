import { useEffect } from 'react';
import useUnreadStore from '../stores/unreadStore';
import { isTauri, getOS } from '../lib/tauri';
import log from '../lib/log';

// Windows has no numeric badge API; the taskbar shows a 16x16 overlay icon
// instead. Draw the count on a canvas and hand the RGBA pixels to Tauri.
async function overlayImage(total) {
  const { Image } = await import('@tauri-apps/api/image');
  const size = 32;
  const canvas = document.createElement('canvas');
  canvas.width = size;
  canvas.height = size;
  const ctx = canvas.getContext('2d');
  ctx.fillStyle = '#d13438';
  ctx.beginPath();
  ctx.arc(size / 2, size / 2, size / 2, 0, Math.PI * 2);
  ctx.fill();
  ctx.fillStyle = '#ffffff';
  const text = total > 99 ? '99+' : String(total);
  ctx.font = `bold ${text.length > 2 ? 13 : 18}px system-ui, sans-serif`;
  ctx.textAlign = 'center';
  ctx.textBaseline = 'middle';
  ctx.fillText(text, size / 2, size / 2 + 1);
  const { data } = ctx.getImageData(0, 0, size, size);
  return Image.new(new Uint8Array(data.buffer), size, size);
}

/**
 * Mirrors the total unread count (summed across every channel) onto the macOS
 * dock / Windows taskbar badge, keeping it in sync as counts change.
 * Mount once in the main window.
 */
export default function useDockBadge() {
  const total = useUnreadStore(s => s.total);

  // The standalone notification panel is a separate Tauri window with its own
  // store, so acting on a card there can't touch this window's count directly.
  // It emits instead, and we apply it here — without this the badge sat stale
  // until the provider write landed and something refetched (~2s).
  useEffect(() => {
    if (!isTauri()) return;
    let unlisten;
    import('@tauri-apps/api/event').then(({ listen }) =>
      listen('unread-adjust', (e) => {
        useUnreadStore.getState().adjust(e.payload?.key, e.payload?.delta);
      }).then(fn => { unlisten = fn; })
    ).catch(e => log.warn('DockBadge', `unread-adjust listen failed: ${e?.message || e}`));
    return () => { if (unlisten) unlisten(); };
  }, []);

  useEffect(() => {
    if (!isTauri()) return;
    let cancelled = false;
    (async () => {
      try {
        const { getCurrentWindow } = await import('@tauri-apps/api/window');
        if (cancelled) return;
        const win = getCurrentWindow();
        if (getOS() === 'windows') {
          // setBadgeCount is a no-op on Windows; the overlay icon is the badge.
          const img = total > 0 ? await overlayImage(total) : undefined;
          try {
            // A newer count may have started while the image was drawn.
            if (!cancelled) await win.setOverlayIcon(img);
          } finally {
            // The pixels are copied into the HICON; free the Tauri resource.
            await img?.close?.();
          }
          return;
        }
        // undefined clears the badge; a positive count shows it.
        await win.setBadgeCount(total > 0 ? total : undefined);
      } catch (e) {
        log.warn('DockBadge', `badge update failed: ${e?.message || e}`);
      }
    })();
    return () => { cancelled = true; };
  }, [total]);
}
