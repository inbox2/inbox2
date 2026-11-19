import api from './api';
import { isTauri } from './tauri';

/* Passkey (WebAuthn) ceremonies against the API (A1.9). The browser's own JSON
 * helpers do the base64url <-> ArrayBuffer work, so there is no library here.
 * ponytail: needs Chrome 129 / Safari 18 / Firefox 119; older browsers just
 * don't get the passkey UI. Add @simplewebauthn/browser if that ever matters.
 * Web only: the desktop webview's origin (tauri://localhost) isn't a valid RP. */

export const passkeysSupported = () =>
  !isTauri()
  && typeof PublicKeyCredential !== 'undefined'
  && typeof PublicKeyCredential.parseCreationOptionsFromJSON === 'function';

// The user dismissed the browser sheet (or it timed out) — not an error to show.
export const isPasskeyCancel = (err) => err?.name === 'NotAllowedError' || err?.name === 'AbortError';

// Rejects with status 401 when the server wants the password first (any session
// that didn't just sign in) — pass it on the retry.
export async function createPasskey(nickname, password) {
  const options = await api.passkeyRegistrationOptions(password);
  const credential = await navigator.credentials.create({
    publicKey: PublicKeyCredential.parseCreationOptionsFromJSON(options),
  });
  return api.registerPasskey(credential.toJSON(), nickname);
}

// Resolves to the login response ({ token, user }) — same shape as api.login.
export async function signInWithPasskey() {
  const options = await api.passkeyLoginOptions();
  const credential = await navigator.credentials.get({
    publicKey: PublicKeyCredential.parseRequestOptionsFromJSON(options),
  });
  return api.passkeyLogin(credential.toJSON());
}
