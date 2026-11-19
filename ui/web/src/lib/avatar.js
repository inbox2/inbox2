import { useEffect, useState } from 'react';

// A sender's picture from GET /api/v1/avatars (Gravatar, else their domain's
// icon — resolved and proxied server-side, so the reader never contacts either).
// Resolves to an object URL, or null when there is none and initials show.
// ponytail: per-session cache keyed on the address; a confirmed miss (404) is
// cached, a network/auth failure is dropped so the next render retries. Object
// URLs live for the session (a few KB each).
const cache = new Map();

export function avatarUrl(email) {
  const clean = (email || '').trim().toLowerCase();
  if (!clean.includes('@')) return Promise.resolve(null);
  if (!cache.has(clean)) {
    cache.set(clean, import('./api.js')
      .then(({ default: api }) => api.fetchAvatar(clean))
      .then(blob => (blob ? URL.createObjectURL(blob) : null))
      .catch(() => { cache.delete(clean); return null; }));
  }
  return cache.get(clean);
}

/** The picture as a data: URL — for the notification card, which can't share object URLs. */
export async function avatarDataUrl(email) {
  const url = await avatarUrl(email);
  if (!url) return null;
  const blob = await fetch(url).then(r => r.blob());
  return new Promise(resolve => {
    const r = new FileReader();
    r.onload = () => resolve(r.result);
    r.onerror = () => resolve(null);
    r.readAsDataURL(blob);
  });
}

export function useAvatarUrl(email) {
  const [state, setState] = useState({ email: null, url: null });
  useEffect(() => {
    let active = true;
    avatarUrl(email).then(url => { if (active) setState({ email, url }); });
    return () => { active = false; };
  }, [email]);
  // A stale picture never shows for a new address.
  return state.email === email ? state.url : null;
}
