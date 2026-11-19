// Live editing of a sealed page (6.10). The relay is the same DiskPageChannel,
// but nothing plain crosses it: each local Yjs update is sealed under P[e] and
// written with POST /pages/:id/updates at exactly update_seq + 1; the channel
// then broadcasts it as sealed_update. A 409 means someone wrote first: fetch
// what was missed, apply it, and send ours at the next seq. Awareness is sealed
// with the epoch and relayed, never stored.
import * as Y from 'yjs'
import YjsActionCableProvider from '../YjsActionCableProvider'
import * as X from './crypto'
import diskApi from './api'
import { sealedEndpoints } from './sealed'

export default class SealedPageProvider extends YjsActionCableProvider {
  /** opts: everything YjsActionCableProvider takes, plus orgId, scope, seq (the last seq applied). */
  constructor(doc, nodeId, { orgId, scope, seq, ...opts }) {
    super(doc, nodeId, { ...opts, channel: 'DiskPageChannel', params: { org_id: orgId, node_id: nodeId }, ignoreOwn: false, syncOnJoin: false, sendStateOnConnect: false })
    this.orgId = orgId
    this.scope = scope
    this.seq = seq
    this.queue = Promise.resolve()
    this.pending = [] // local updates not yet stored
  }

  // A connect would send the whole state as an update: on a sealed page only real edits go out.
  _sendUpdate(update) {
    if (!this.scope) return
    this.pending.push(update instanceof Uint8Array ? update : new Uint8Array(update))
    this.queue = this.queue.then(() => this._flush()).catch((e) => this.onMessage?.({ type: 'sealed_error', message: e.message }))
  }

  async _flush() {
    while (this.pending.length && !this.destroyed) {
      // Only what is sent now leaves the queue: keys typed while the request is out stay pending.
      const sent = this.pending.length
      const update = Y.mergeUpdates(this.pending.slice(0, sent))
      const { scope } = this
      try {
        const next = this.seq + 1
        await sealedEndpoints.pageUpdate(this.orgId, this.draftId, {
          update: X.b64(X.sealPageUpdate(scope.key, this.draftId, scope.epoch, next, update)), epoch: scope.epoch, seq: next,
        })
        this.seq = next
        this.pending.splice(0, sent)
      } catch (e) {
        if (e.status !== 409) throw e
        if (e.data?.current_epoch && e.data.current_epoch !== scope.epoch) {
          this.onMessage?.({ type: 'epoch_changed', epoch: e.data.current_epoch }) // the page reopens the scope
          throw e
        }
        await this.catchUp() // rebase: what we missed, then ours at the next seq
      }
    }
  }

  /** Applies stored updates above this.seq (after a 409 or a gap in the broadcasts). */
  async catchUp() {
    const { page } = await diskApi.page(this.orgId, this.draftId)
    for (const u of page.updates || []) {
      if (u.seq <= this.seq) continue
      Y.applyUpdate(this.doc, X.openPageUpdate(this.scope.keyFor(u.epoch), this.draftId, u.epoch, u.seq, X.unb64(u.ciphertext)), this)
      this.seq = u.seq
    }
    this.seq = Math.max(this.seq, page.update_seq || 0)
  }

  _sendAwareness(update) {
    if (!this.connected || !this.subscription || !this.scope) return
    const { scope } = this
    this.subscription.perform('sync_awareness', { update: X.b64(X.sealAwareness(scope.key, this.draftId, scope.epoch, update)), epoch: scope.epoch })
  }

  _handleMessage(data) {
    if (data.type === 'sealed_update') {
      if (data.seq <= this.seq) return
      if (data.seq !== this.seq + 1) { this.queue = this.queue.then(() => this.catchUp()); return }
      try {
        Y.applyUpdate(this.doc, X.openPageUpdate(this.scope.keyFor(data.epoch), this.draftId, data.epoch, data.seq, X.unb64(data.update)), this)
        this.seq = data.seq
      } catch (e) {
        this.onMessage?.({ type: 'sealed_error', message: e.message })
      }
      return
    }
    if (data.type === 'yjs_awareness') {
      if (data.epoch == null) return // plain awareness never applies to a sealed page
      try {
        return super._handleMessage({ ...data, update: X.b64(X.openAwareness(this.scope.keyFor(data.epoch), this.draftId, data.epoch, X.unb64(data.update))) })
      } catch { return undefined }
    }
    if (data.type === 'yjs_update') return // ignored on a sealed page
    return super._handleMessage(data)
  }

  /** The snapshot body for PUT /pages/:id: the whole state, covering this.seq. */
  snapshotBody() {
    const { scope } = this
    const state = Y.encodeStateAsUpdate(this.doc)
    return { sealed_snapshot: X.b64(X.sealPageSnapshot(scope.key, this.draftId, scope.epoch, this.seq, state)), epoch: scope.epoch, seq: this.seq }
  }
}
