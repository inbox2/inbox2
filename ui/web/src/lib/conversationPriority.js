import api from './localFirstApi'; // the same client SpaceDashboard used
import log from './log';
import { isTauri } from './tauri';
import { isRealOrgId } from './org';
import { QUADRANTS, PRIORITY_URGENT, PRIORITY_IMPORTANT, PRIORITY_LATER } from './priority';

/**
 * Put one conversation in an Eisenhower quadrant (`key`) or take it out (null),
 * outside a list that owns it (Spaces strip, Lore peek). Local threads
 * (`accountKey`) go through provider priority; MX threads store priority as
 * tags — the current tags are read first so the replace-all PUT keeps the rest.
 */
export async function setConversationPriority({ id, accountKey, orgId }, key) {
  try {
    if (accountKey) {
      if (!isTauri()) return;
      const providers = await import('./providers/index.js');
      if (!key) await providers.clearPriority(accountKey, [id]);
      else await providers.setPriority(accountKey, [id], QUADRANTS[key].urgent, QUADRANTS[key].important);
    } else if (isRealOrgId(orgId)) {
      const [tagsData, detail] = await Promise.all([api.getTags(orgId), api.getConversation(orgId, id)]);
      const allTags = tagsData.tags || [];
      const tag = (name) => allTags.find((t) => t.name === name);
      const drop = new Set([tag(PRIORITY_URGENT)?.key, tag(PRIORITY_IMPORTANT)?.key, tag(PRIORITY_LATER)?.key]);
      const keep = (detail.conversation?.tags || []).map((t) => t.key || t.id).filter((k) => k && !drop.has(k));
      const q = key ? QUADRANTS[key] : null;
      if (q?.urgent && tag(PRIORITY_URGENT)) keep.push(tag(PRIORITY_URGENT).key);
      if (q?.important && tag(PRIORITY_IMPORTANT)) keep.push(tag(PRIORITY_IMPORTANT).key);
      if (q && !q.urgent && !q.important && tag(PRIORITY_LATER)) keep.push(tag(PRIORITY_LATER).key);
      await api.put(`/orgs/${orgId}/conversations/${id}/tags`, { tag_ids: keep });
    }
  } catch (e) { log.warn('Priority', `triage failed for ${id}: ${e?.message || e}`); }
}
