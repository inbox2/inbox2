import { createConsumer } from '@rails/actioncable'
import api from './api'
import log from './log'
import { cableOrigin } from './apiOrigin'

let consumer = null

export function getConsumer() {
  if (!consumer) {
    // Cross-origin API (Cloudflare Pages) → use the API host; otherwise the
    // current origin (Vite proxy in dev, same ingress in-cluster).
    const origin = cableOrigin()
    const protocol = origin ? origin.protocol : (window.location.protocol === 'https:' ? 'wss:' : 'ws:')
    const host = origin ? origin.host : window.location.host
    log.info('Cable', `Creating WebSocket consumer ${protocol}//${host}/cable`)
    // Desktop/CLI authenticate the socket with the stored bearer in the URL.
    // The web build has no JS-readable token — the HttpOnly session cookie is
    // sent on the same-site WS handshake, so we DON'T put a token in the URL
    // (avoids leaking it via proxy/access logs).
    //
    // Pass a URL *function*, not a string: ActionCable re-evaluates it on every
    // (re)connect (consumer.js `get url()` → createWebSocketURL). On desktop the
    // bearer hydrates asynchronously from the encrypted store, but the channel is
    // opened the instant the user is authenticated (AuthProvider.ensureSessionListener) —
    // a string URL would freeze a tokenless socket that Rails rejects forever (it
    // can't read a query token and there's no cookie). The lazy function lets the
    // next reconnect pick up the token once it's hydrated, so the socket authenticates.
    const url = () => {
      const token = api.token || ''
      return token
        ? `${protocol}//${host}/cable?token=${encodeURIComponent(token)}`
        : `${protocol}//${host}/cable`
    }
    consumer = createConsumer(url)
  }
  return consumer
}

/** Stops the socket while this tab is signed out (no reconnect attempts); resumeCable reopens it. */
export function pauseCable() {
  consumer?.disconnect()
}

export function resumeCable() {
  consumer?.connect()
}
