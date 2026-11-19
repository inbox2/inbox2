// Cloud-push preference — whether to use the Rails backend for realtime push on
// local channels (Gmail/Office365), vs. falling back to 60s polling. A small
// external store (like notificationPref/markReadPref) so plain handlers can read
// the value synchronously via getCloudPushPref(), while settings stay reactive
// through useCloudPushPref(). Defaults ON. See docs/Cloud-Push.md.
import { createBoolPref } from './prefStore';
import { CLOUD_PUSH_ENABLED } from './storageKeys';

const store = createBoolPref(CLOUD_PUSH_ENABLED, { defaultValue: true });

export const getCloudPushPref = store.getPref;
export const setCloudPushEnabled = store.setEnabled;

export default store.usePref;
