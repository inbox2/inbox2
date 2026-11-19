import { create } from 'zustand'
import { identityKeys, isUnlocked } from '../lib/e2eeStore'

// Sealed scopes on this page (spec F7): scopeKey `${orgId}/${scopeId}` ->
// { status, scope, error }. status: loading | open | locked (identity key
// locked) | noidentity | nokey (a role without a key: an admin who is not a
// member) | error. Keys stay in lib/disk/sealed.js memory; this is what renders.
const key = (orgId, id) => `${orgId}/${id}`

const useSealedStore = create((set, get) => ({
  scopes: {},
  version: 0, // bumps on every change, for effects that re-derive names

  async open(orgId, scopeId, { refresh = false } = {}) {
    const k = key(orgId, scopeId)
    const cur = get().scopes[k]
    if (!refresh && cur && (cur.status === 'open' || cur.status === 'loading' || cur.status === 'nokey')) return cur.scope
    const ids = identityKeys()
    if (!ids) {
      put(set, k, { status: isUnlocked() ? 'error' : 'locked' })
      return null
    }
    put(set, k, { status: 'loading', scope: cur?.scope })
    try {
      const { openScope, NoKey } = await import('../lib/disk/sealed')
      try {
        const scope = await openScope(orgId, scopeId, ids, { refresh })
        put(set, k, { status: 'open', scope })
        return scope
      } catch (e) {
        put(set, k, e instanceof NoKey ? { status: 'nokey' } : { status: 'error', error: e })
        return null
      }
    } catch (e) {
      put(set, k, { status: 'error', error: e })
      return null
    }
  },

  /** After epoch_changed, rotation or a holder change: fetch the grant again. */
  async reopen(orgId, scopeId) {
    const { forgetScope } = await import('../lib/disk/sealed')
    forgetScope(orgId, scopeId)
    return get().open(orgId, scopeId, { refresh: true })
  },

  entry: (orgId, scopeId) => get().scopes[key(orgId, scopeId)] || null,

  /** Lock, sign-out: forget every key here and in the service worker. */
  async clear() {
    set({ scopes: {}, version: get().version + 1 })
    const { clearSealed } = await import('../lib/disk/sealed')
    clearSealed()
  },
}))

function put(set, k, entry) {
  set((s) => ({ scopes: { ...s.scopes, [k]: entry }, version: s.version + 1 }))
}

export default useSealedStore
