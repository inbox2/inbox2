// Image-proxy preference — whether remote email images load privately through
// the Rails image proxy (so the sender never sees the reader's IP/UA). Piggybacks
// on the API token the cloud-push work introduced: when a token is present the
// proxy is used; otherwise images stay blocked behind the "Show images" banner.
//
// A small external store (like cloudPushPref/notificationPref) so the render path
// can read the value synchronously via getImageProxyPref(), while settings stay
// reactive through useImageProxyPref(). Defaults ON.
import { createBoolPref } from './prefStore';
import { IMAGE_PROXY_ENABLED } from './storageKeys';

const store = createBoolPref(IMAGE_PROXY_ENABLED, { defaultValue: true });

export const getImageProxyPref = store.getPref;
export const setImageProxyEnabled = store.setEnabled;

export default store.usePref;
