// The visitor side of a public link (spec F4): no account, no org, no cookies.
// Called with plain fetch, not the app's ApiClient: no session rides along,
// no referrer is sent, and the unlock proof goes in X-Disk-Link-Unlock.
import { API_ORIGIN } from '../apiOrigin'

const base = (token) => `${API_ORIGIN}/api/v1/disk/links/${encodeURIComponent(token)}`
export const UNLOCK_HEADER = 'X-Disk-Link-Unlock'

async function call(path, { method = 'GET', body, unlock } = {}) {
  const headers = { Accept: 'application/json' }
  if (body) headers['Content-Type'] = 'application/json'
  if (unlock) headers[UNLOCK_HEADER] = unlock
  const res = await fetch(path, {
    method, headers, body: body && JSON.stringify(body), credentials: 'omit', referrerPolicy: 'no-referrer', cache: 'no-store',
  })
  const data = res.status === 204 ? null : await res.json().catch(() => null)
  if (!res.ok) {
    const e = new Error(data?.errors?.[0]?.message || `Request failed (${res.status})`)
    e.status = res.status
    e.retryAfter = Number(res.headers.get('Retry-After')) || null
    throw e
  }
  return data
}

const qs = (o) => {
  const sp = new URLSearchParams(Object.entries(o).filter(([, v]) => v))
  return sp.toString() ? `?${sp}` : ''
}

/** { link: { password_required, unlocked, download_allowed, abuse_email, node }, folder, path, nodes, next_cursor } */
export const openLink = (token, { nodeId, cursor, unlock } = {}) => call(`${base(token)}${qs({ node_id: nodeId, cursor })}`, { unlock })
/** { unlock: { token, expires_at } }; 403 on a wrong password, 429 when throttled. */
export const unlockLink = (token, password) => call(`${base(token)}/unlock`, { method: 'POST', body: { password } })
/** { download: { url (null when downloads are hidden), preview_url, node } } */
export const linkDownload = (token, { nodeId, unlock } = {}) => call(`${base(token)}/download${qs({ node_id: nodeId })}`, { unlock })
/** A sealed link's unlock: the verifier derived in this browser (6.9), base64. Same answers as unlockLink. */
export const unlockSealedLink = (token, verifier) => call(`${base(token)}/unlock`, { method: 'POST', body: { verifier } })
