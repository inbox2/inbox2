// DropBlock preference — whether the playable DropBlock game appears in the
// reading-pane empty state. A small external store (like cloudPushPref) so the
// inbox views can read it reactively via useDropBlockPref(), defaulting ON.
import { createBoolPref } from './prefStore';
import { DROPBLOCK_ENABLED } from './storageKeys';

const store = createBoolPref(DROPBLOCK_ENABLED, { defaultValue: true });

export const getDropBlockPref = store.getPref;
export const setDropBlockEnabled = store.setEnabled;

export default store.usePref;
