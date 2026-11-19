// The desktop app opens two extra webviews on bare routes of this same bundle:
// the new-mail popup (/notification) and the menu bar popover (/tray). Both are
// hidden most of the time — WebKit suspends a hidden webview, so sockets stall —
// and neither wants the main window's global chrome (palette, notifiers, floats).
export const TRAY_PATH = '/tray';
const AUX_PATHS = ['/notification', TRAY_PATH];

export const isAuxWindowPath = (pathname) => AUX_PATHS.includes(pathname);
