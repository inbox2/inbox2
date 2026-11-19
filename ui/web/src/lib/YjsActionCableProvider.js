import * as Y from 'yjs'
import {
  Awareness,
  encodeAwarenessUpdate,
  applyAwarenessUpdate,
} from 'y-protocols/awareness'
import { getConsumer } from './cable'
import log from './log'

/**
 * Custom Yjs sync provider over Rails Action Cable.
 *
 * Subscribes to DraftChannel and relays Yjs binary updates
 * as base64-encoded strings. The server is a pure relay —
 * it doesn't store Yjs state.
 *
 * Usage:
 *   const doc = new Y.Doc()
 *   const provider = new YjsActionCableProvider(doc, draftId, { user })
 *   // ... use doc with Tiptap Collaboration extension ...
 *   provider.destroy()
 *
 * Other channels with the same relay contract (Disk pages) pass:
 *   channel, params   the subscription, e.g. 'DiskPageChannel', { org_id, node_id }
 *   ignoreOwn         false when the server never echoes to the sender, so two
 *                     tabs of one person still sync (default true: DraftChannel)
 *   syncOnJoin        send the full state when another editor joins
 *   onMessage         every other message (page_saved, role_changed, ...)
 */
export default class YjsActionCableProvider {
  constructor(doc, draftId, { user, channel = 'DraftChannel', params, ignoreOwn = true, syncOnJoin = false, sendStateOnConnect = true, onMessage } = {}) {
    this.doc = doc
    this.draftId = draftId
    this.user = user
    this.channel = channel
    this.params = params || { draft_id: draftId }
    this.ignoreOwn = ignoreOwn
    this.syncOnJoin = syncOnJoin
    this.sendStateOnConnect = sendStateOnConnect // false: a sealed page sends only real edits
    this.onMessage = onMessage
    this.awareness = new Awareness(doc)
    this.subscription = null
    this.connected = false
    this.destroyed = false

    // Set local awareness state
    if (user) {
      this.awareness.setLocalStateField('user', {
        name: user.username || user.display_name || 'Anonymous',
        color: this._userColor(user.id || user.username),
      })
    }

    // Listen for local Yjs doc updates
    this._onUpdate = (update, origin) => {
      if (origin === this) return // Skip updates applied from remote
      this._sendUpdate(update)
    }
    this.doc.on('update', this._onUpdate)

    // Listen for awareness changes
    this._onAwarenessUpdate = ({ added, updated, removed }) => {
      const changedClients = added.concat(updated).concat(removed)
      const encodedUpdate = encodeAwarenessUpdate(this.awareness, changedClients)
      this._sendAwareness(encodedUpdate)
    }
    this.awareness.on('update', this._onAwarenessUpdate)

    // Connect
    this._connect()
  }

  _connect() {
    log.info('Yjs', `Subscribing to ${this.channel} ${this.draftId}`)
    const consumer = getConsumer()
    this.subscription = consumer.subscriptions.create(
      { channel: this.channel, ...this.params },
      {
        connected: () => {
          this.connected = true
          log.info('Yjs', `Connected to ${this.channel} ${this.draftId}`)
          // Send initial state to sync with any existing editors
          const state = Y.encodeStateAsUpdate(this.doc)
          if (this.sendStateOnConnect && state.length > 2) { // Non-empty state
            this._sendUpdate(state)
          }
          // Our presence was set before the socket was up, so that update went nowhere:
          // announce it now, or a member who never moves the caret (a viewer) stays invisible.
          if (this.awareness.getLocalState()) this._sendAwareness(encodeAwarenessUpdate(this.awareness, [this.doc.clientID]))
        },
        disconnected: () => {
          this.connected = false
          log.warn('Yjs', `Disconnected from ${this.channel} ${this.draftId}`)
        },
        received: (data) => {
          this._handleMessage(data)
        },
        rejected: () => {
          log.warn('Yjs', `${this.channel} refused ${this.draftId}`)
          this.onMessage?.({ type: 'rejected' })
        },
      }
    )
  }

  _handleMessage(data) {
    // Skip our own messages (channels that echo to the sender)
    if (this.ignoreOwn && data.user_id === this.user?.id) return

    switch (data.type) {
      case 'yjs_update': {
        const update = this._base64ToUint8Array(data.update)
        Y.applyUpdate(this.doc, update, this) // origin = this to prevent echo
        break
      }
      case 'yjs_awareness': {
        const update = this._base64ToUint8Array(data.update)
        applyAwarenessUpdate(this.awareness, update, this)
        break
      }
      case 'editor_joined':
        // A newcomer starts from the last saved snapshot: hand it everything we have, and our cursor.
        if (this.syncOnJoin) {
          this._sendUpdate(Y.encodeStateAsUpdate(this.doc))
          this._sendAwareness(encodeAwarenessUpdate(this.awareness, [this.doc.clientID]))
        }
        this.onMessage?.(data)
        break
      default:
        this.onMessage?.(data)
        break
    }
  }

  _sendUpdate(update) {
    if (!this.connected || !this.subscription) return
    const encoded = this._uint8ArrayToBase64(update instanceof Uint8Array ? update : new Uint8Array(update))
    this.subscription.perform('sync_update', { update: encoded })
  }

  _sendAwareness(update) {
    if (!this.connected || !this.subscription) return
    const encoded = this._uint8ArrayToBase64(update instanceof Uint8Array ? update : new Uint8Array(update))
    this.subscription.perform('sync_awareness', { update: encoded })
  }

  // Public for callers that save snapshots: the same base64 the channel uses.
  static toBase64(bytes) { return YjsActionCableProvider.prototype._uint8ArrayToBase64(bytes) }
  static fromBase64(b64) { return YjsActionCableProvider.prototype._base64ToUint8Array(b64) }

  _uint8ArrayToBase64(bytes) {
    let binary = ''
    for (let i = 0; i < bytes.length; i++) {
      binary += String.fromCharCode(bytes[i])
    }
    return btoa(binary)
  }

  _base64ToUint8Array(base64) {
    const binary = atob(base64)
    const bytes = new Uint8Array(binary.length)
    for (let i = 0; i < binary.length; i++) {
      bytes[i] = binary.charCodeAt(i)
    }
    return bytes
  }

  _userColor(id) {
    const colors = [
      '#e06060', '#d4a843', '#7aaa8c', '#7a9aaa',
      '#a080c0', '#c07070', '#60a0d0', '#b0a060',
    ]
    const hash = String(id).split('').reduce((a, c) => a + c.charCodeAt(0), 0)
    return colors[hash % colors.length]
  }

  destroy() {
    if (this.destroyed) return
    this.destroyed = true
    log.info('Yjs', `Destroyed provider ${this.channel} ${this.draftId}`)

    this.doc.off('update', this._onUpdate)
    this.awareness.off('update', this._onAwarenessUpdate)
    this.awareness.destroy()

    if (this.subscription) {
      this.subscription.unsubscribe()
      this.subscription = null
    }

    this.connected = false
  }
}
