// Discovery between Disk tabs and the engine window, over BroadcastChannel
// CHANNEL (same origin only). No file data goes on it: conversions travel
// through the Disk service worker (engine/client.js convertInEngine).
//
//   Disk → engine   { type: 'ping' }
//   engine → Disk   { type: 'pong', busy } | { type: 'closing' }
export const CHANNEL = 'inbox2-disk-engine'
export const ENGINE_PAGE = '/disk-engine.html'
