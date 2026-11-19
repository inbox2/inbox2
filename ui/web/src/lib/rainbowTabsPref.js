// "Rainbow tabs" preference — when on, each chrome workspace tab is tinted with
// a colour from the Catppuccin accent palette by position (the Obsidian
// "rainbow folders" look). A small external store (like cloudPushPref) so
// ChromeBar reads it reactively via useRainbowTabs() while the Settings toggle
// stays in sync. Off by default. The palette lives in layout.module.css
// (.rb0….rb8); RAINBOW_TAB_COUNT must match the number of palette classes.
import { createBoolPref } from './prefStore';
import { RAINBOW_TABS_ENABLED } from './storageKeys';

export const RAINBOW_TAB_COUNT = 9;

const store = createBoolPref(RAINBOW_TABS_ENABLED, { defaultValue: false });

export const getRainbowTabsPref = store.getPref;
export const setRainbowTabsEnabled = store.setEnabled;

export default store.usePref;
