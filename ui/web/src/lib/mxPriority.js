// MX (org) priority write-back. Org mail stores the Eisenhower flags as tags
// (Urgent / Important / Later); every caller used to re-implement this diff.
// Local channels are NOT handled here: their `setPriority`/`clearPriority` live
// in the code-split `lib/providers/index.js` on purpose.
import api from './localFirstApi';
import { PRIORITY_URGENT, PRIORITY_IMPORTANT, PRIORITY_LATER } from './priority';

async function priorityTags(orgId) {
  const all = (await api.getTags(orgId)).tags || [];
  const byName = (name) => all.find((t) => t.name === name) || null;
  return { urgent: byName(PRIORITY_URGENT), important: byName(PRIORITY_IMPORTANT), later: byName(PRIORITY_LATER) };
}

function keep(conv, tags) {
  const drop = new Set([tags.urgent?.key, tags.important?.key, tags.later?.key].filter(Boolean));
  return (conv?.tags || []).map((t) => t.key || t.id).filter((k) => k && !drop.has(k));
}

function put(orgId, convId, tagIds) {
  return api.put(`/orgs/${orgId}/conversations/${convId}/tags`, { tag_ids: tagIds });
}

/** Set a conversation's quadrant: Urgent/Important flags, or the Later marker when neither. */
export async function setMxPriorityTags(orgId, conv, { urgent, important }) {
  const tags = await priorityTags(orgId);
  const ids = keep(conv, tags);
  if (urgent && tags.urgent) ids.push(tags.urgent.key);
  if (important && tags.important) ids.push(tags.important.key);
  // Later quadrant: no flags, so persist the marker tag.
  if (!urgent && !important && tags.later) ids.push(tags.later.key);
  return put(orgId, conv.id, ids);
}

/** Back to untriaged: strip all three priority tags. */
export async function clearMxPriorityTags(orgId, conv) {
  const tags = await priorityTags(orgId);
  return put(orgId, conv.id, keep(conv, tags));
}
