// Grouping helpers for Meta BYOK credential reuse. Several channels (WhatsApp /
// Messenger / Instagram) can share one Meta app's app secret + System User
// token; when adding another channel the operator can reuse an existing app's
// credentials instead of re-entering them. The Rust core surfaces a non-secret
// `meta_app_id` per Meta account (the secret + token stay encrypted on-device)
// so we can group channels by app here. See docs/Cloud-Push.md (Meta).

import { META_PROVIDERS, PROVIDER } from './providerTypes'

const PROVIDER_LABEL = {
  [PROVIDER.WHATSAPP]: 'WhatsApp',
  [PROVIDER.MESSENGER]: 'Messenger',
  [PROVIDER.INSTAGRAM]: 'Instagram',
}

/**
 * Group connected Meta accounts by their Meta app so each underlying app is
 * offered once for credential reuse. Accounts without a known app id (created
 * before the app id was captured) each form their own group.
 *
 * @param {Array} accounts — `list_external_accounts` rows
 * @returns {Array<{ key, appId, repKey, channels }>} one entry per Meta app.
 *   `repKey` is the account key whose encrypted credentials get reused.
 */
export function groupMetaApps(accounts = []) {
  const groups = new Map()
  for (const a of accounts) {
    if (!META_PROVIDERS.includes(a.provider_type)) continue
    const appId = a.meta_app_id || ''
    const key = appId ? `app:${appId}` : `acct:${a.key}`
    if (!groups.has(key)) {
      groups.set(key, { key, appId, repKey: a.key, channels: [] })
    }
    groups.get(key).channels.push(a)
  }
  return [...groups.values()]
}

/** Human label for an app group: app id (or its first channel's name) + the
 *  channels that already use it, e.g. "App 123456 · WhatsApp, Messenger". */
export function metaAppLabel(group) {
  if (!group) return ''
  const chans = group.channels
    .map((c) => PROVIDER_LABEL[c.provider_type] || c.provider_type)
    .join(', ')
  const base = group.appId
    ? `App ${group.appId}`
    : group.channels[0]?.display_name || 'Existing Meta app'
  return chans ? `${base} · ${chans}` : base
}
