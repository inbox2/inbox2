import useNavigationStore from '../../stores/navigationStore';
import { WA_SOURCE } from '../../lib/lore';
import { waChatPath } from '../../lib/localWhatsApp';

/** Open the email behind a Lore item in its own inbox view (MX org inbox or the local channel). */
export function openLoreItem(item, organizations) {
  // A WhatsApp ask opens the WhatsApp tab at the chat, on the ask's first message.
  if (item.source === WA_SOURCE) {
    useNavigationStore.getState()._navigate?.(waChatPath(item.chatId, item.askId));
    return;
  }
  if (item.source === 'local') {
    useNavigationStore.getState().navigateTo({ page: 'mail', accountKey: item.accountKey, conversationId: item.id });
    return;
  }
  const org = (organizations || []).find((o) => o.id === item.orgId);
  useNavigationStore.getState().navigateTo({
    page: 'mail',
    orgSlug: org?.slug || item.orgId, accountKey: null, conversationId: item.id, unified: false,
  });
}

/** The full-window Lore app's paths (routes.jsx mounts /lore/*). */
export const LORE_PATH = {
  TODAY: '/lore',
  WAITING: '/lore/waiting',
  HANDLED: '/lore/handled',
  HISTORY: '/lore/history',
  ORG: (domain) => `/lore/org/${encodeURIComponent(domain)}`,
  PERSON: (address) => `/lore/person/${encodeURIComponent(address)}`,
  PAGE: (id) => `/lore/page/${encodeURIComponent(id)}`,
  GROUP: (chatId) => `/lore/group/${encodeURIComponent(chatId)}`,
  SEARCH: (q) => `/lore/search?q=${encodeURIComponent(q)}`,
};

/** An entity mention → its Lore page path. */
export const entityPath = (e) => {
  if (e.kind === 'group') return LORE_PATH.GROUP(e.chatId);
  return e.kind === 'org' ? LORE_PATH.ORG(e.domain) : LORE_PATH.PERSON(e.address);
};

/** The Lore page area's id: focus lands here when what had it went away (a peeked row archived). */
export const LORE_MAIN_ID = 'lore-main';
