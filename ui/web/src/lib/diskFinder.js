// Disk in Finder (docs/Disk-Sync.md): the desktop app's commands and the
// words for its state, shared by Settings › Disk and the menu bar popover.
import { isTauri } from './tauri'
import { apiBaseUrl } from './apiOrigin'
import api from './api'
import { identityKeys } from './e2eeStore'

const WEB_ORIGIN = import.meta.env.VITE_WEB_ORIGIN || 'https://mail.inbox2.com'

async function call(cmd, args) {
  const { invoke } = await import('@tauri-apps/api/core')
  return invoke(cmd, args)
}

const b64 = (bytes) => btoa(String.fromCharCode(...bytes))

/** The identity key pair, base64, when it is open in this window. The app
 *  writes it for the Finder extension only while FileVault is on. */
function identity() {
  const keys = identityKeys()
  return keys ? { identitySecret: b64(keys.privateKey), identityPublic: b64(keys.publicKey) } : {}
}

export const diskFinder = {
  available: () => isTauri() && navigator.userAgent.includes('Mac'),
  status: () => call('disk_finder_status'),
  enable: async (org, user) => call('disk_finder_enable', {
    args: {
      org: org.id,
      orgName: org.name,
      memberId: String(user?.id || ''),
      apiBase: apiBaseUrl(),
      webBase: WEB_ORIGIN,
      token: (await api.getToken()) || '',
      memberName: user?.first_name || user?.name?.split(' ')[0] || '',
      ...identity(),
    },
  }),
  update: (args) => call('disk_finder_update', { args }),
  /** Keeps the extension's token and sealed key current; call after sign-in and unlock. */
  refresh: async () => call('disk_finder_update', { args: { token: (await api.getToken()) || '', ...identity() } }),
  /** Sign-out removes Disk from Finder: the token, the sealed key and every
   *  downloaded copy leave this Mac (edits that didn't upload are kept). */
  signOut: () => call('disk_finder_disable'),
  disable: () => call('disk_finder_disable'),
  pause: (paused) => call('disk_finder_pause', { paused, reason: 'You paused Disk in inbox2.' }),
  open: () => call('disk_finder_open'),
  openSystemSettings: () => call('disk_finder_open_system_settings'),
}

/**
 * One line for the state: { tone, text } where tone is ok | busy | warn | error.
 * `last_error` carries the engine's error text; the known ones get a next step.
 */
export function statusLine(s) {
  if (!s?.enabled) return { tone: 'idle', text: 'Off' }
  if (!s.approved) return { tone: 'warn', text: 'Allow inbox2 in System Settings' }
  if (s.paused) return { tone: 'warn', text: 'Paused' }
  const err = s.last_error || ''
  if (err.startsWith('signed out')) return { tone: 'error', text: 'Sign in again to keep your files up to date.' }
  if (err.startsWith('storage full')) return { tone: 'error', text: 'Disk storage is full. Free space or ask your admin.' }
  if (err.startsWith('offline')) {
    return { tone: 'warn', text: s.uploading ? `No connection. ${count(s.uploading, 'change')} upload when you're back online.` : "No connection. Finder shows what's on this Mac." }
  }
  if (err) return { tone: 'error', text: 'The last check failed. Next try in 30 seconds.' }
  if (s.uploading) return { tone: 'busy', text: `Uploading ${count(s.uploading, 'file')}` }
  return { tone: 'ok', text: 'Up to date' }
}

export const count = (n, word) => `${n} ${word}${n === 1 ? '' : 's'}`

/** Speed limits in KiB/s; 0 is no limit. */
export const SPEEDS = [
  { value: 0, label: 'No limit' },
  { value: 1024, label: '1 MB/s' },
  { value: 5120, label: '5 MB/s' },
]
