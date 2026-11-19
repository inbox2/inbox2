/**
 * Centralized logger for production observability.
 *
 * In Tauri: routes to invoke('js_log') → Rust log crate → tauri_plugin_log (disk).
 * In browser: falls back to console.*.
 *
 * Maintains an in-memory ring buffer (last 500 entries) accessible via log.entries
 * for the settings log viewer. Notifies subscribers on each new entry.
 *
 * Usage:
 *   import log from '../lib/log'
 *   log.info('Auth', 'Login succeeded user=demo')
 *   log.error('API', `Network error: GET ${path}`)
 */
import { isTauri } from './tauri.js'

let _invoke = null

function getInvoke() {
  if (_invoke !== null) return _invoke
  if (!isTauri()) { _invoke = false; return false }
  _invoke = import('@tauri-apps/api/core').then(m => m.invoke)
  return _invoke
}

// ── In-memory ring buffer for log viewer ──
const MAX_ENTRIES = 500
const entries = []
const listeners = new Set()

function formatTime() {
  const d = new Date()
  return d.toLocaleTimeString('en-US', { hour12: false, hour: '2-digit', minute: '2-digit', second: '2-digit' })
}

function emit(level, tag, msg) {
  const formatted = `[${tag}] ${msg}`

  // Append to ring buffer
  const entry = { time: formatTime(), level: level.toUpperCase(), tag, message: msg }
  entries.push(entry)
  if (entries.length > MAX_ENTRIES) entries.shift()
  for (const fn of listeners) fn(entry)

  // Route to Tauri or console
  const inv = getInvoke()
  if (inv) {
    Promise.resolve(inv).then(fn => fn('js_log', { level, message: formatted })).catch(() => {})
  } else {
    const m = level === 'error' ? 'error' : level === 'warn' ? 'warn' : 'log'
    console[m](formatted)
  }
}

const log = {
  error: (tag, msg) => emit('error', tag, msg),
  warn:  (tag, msg) => emit('warn', tag, msg),
  info:  (tag, msg) => emit('info', tag, msg),
  debug: (tag, msg) => emit('debug', tag, msg),

  /** Read-only snapshot of the ring buffer. */
  get entries() { return entries },

  /** Subscribe to new log entries. Returns unsubscribe function. */
  subscribe(fn) {
    listeners.add(fn)
    return () => listeners.delete(fn)
  },
}

export default log
