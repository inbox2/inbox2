// Standalone embed of the DropBlock game for the native iOS WebView overlay.
// Bundled (esbuild) into a single self-contained HTML at
// ui/ios/Resources/dropblock-game.html by scripts/build-dropblock-embed.mjs.
//
// It reuses the exact React component the web app ships (touch controls included)
// and talks to the native host over the `dropblock` message handler:
//   page → host : { type: 'state', state }  (debounced snapshot for resume)
//                 { type: 'quit' }           (player left the game)
//   host → page : window.__dropblockHydrate(json)  (restore a saved snapshot)
import { createRoot } from 'react-dom/client';
import './styles/reset.css';
import './styles/tokens.css';
import DropBlock from './components/DropBlock/DropBlock';
import useDropBlockStore, { STATUS, serializeGame, hydrateGame } from './stores/dropBlockStore';

const native = window.webkit?.messageHandlers?.dropblock;
const post = (msg) => { try { native?.postMessage(msg); } catch { /* not in a native shell */ } };

// Host → page: restore a saved snapshot (called after the WebView finishes load).
window.__dropblockHydrate = (data) => {
  try { hydrateGame(typeof data === 'string' ? JSON.parse(data) : data); } catch { /* ignore bad payload */ }
};

createRoot(document.getElementById('root')).render(<DropBlock />);

// Begin a fresh game immediately; if the host has a saved snapshot it calls
// __dropblockHydrate right after load, which replaces this with the resumed game.
useDropBlockStore.getState().start();

// Persist on every change (debounced) so the host can resume later; quit the
// overlay when the player exits to idle.
let saveTimer = 0;
useDropBlockStore.subscribe((s) => {
  if (s.status === STATUS.IDLE) { clearTimeout(saveTimer); post({ type: 'quit' }); return; }
  clearTimeout(saveTimer);
  saveTimer = setTimeout(() => post({ type: 'state', state: serializeGame() }), 250);
});

// Flush a final snapshot when the overlay is dismissed / app backgrounded.
const flush = () => post({ type: 'state', state: serializeGame() });
window.addEventListener('pagehide', flush);
document.addEventListener('visibilitychange', () => { if (document.hidden) flush(); });
