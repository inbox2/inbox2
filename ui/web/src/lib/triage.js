// Triage label presentation — mirrors the core `TriageLabel` taxonomy and the
// iOS `rowBadge`. Low-signal categories (fyi / resolved / receipt / notification) return null so the list
// stays clean. `tone` maps to a CSS class for the chip color. Labels are Jev's
// (docs/Triage.md): these thirteen built-ins plus any custom label the org (MX) or
// the user (local channels) added.
const TRIAGE = {
  needs_answer: { badge: 'Reply', tone: 'urgent' },
  needs_answer_other: { badge: 'Others', tone: 'open' },
  waiting_reply: { badge: 'Waiting', tone: 'open' },
  needs_approval: { badge: 'Approve', tone: 'pending' },
  scheduling: { badge: 'Schedule', tone: 'open' },
  action_required: { badge: 'Action', tone: 'urgent' },
  fyi: null,
  resolved: null,
  payment_due: { badge: 'Pay', tone: 'urgent' },
  to_review: { badge: 'Review', tone: 'open' },
  read_later: { badge: 'Read', tone: 'open' },
  receipt: null,
  notification: null,
};

/** The fallback label: always on, can't be disabled (docs/Triage.md). */
export const FALLBACK_TRIAGE_LABEL = 'fyi';

export function isBuiltinTriageLabel(slug) {
  return Object.hasOwn(TRIAGE, slug);
}

/** `needs_legal_review` → `Needs legal review` (a custom slug before its list loads). */
export function titleCaseSlug(slug) {
  const s = String(slug || '').replace(/_+/g, ' ').trim();
  return s ? s[0].toUpperCase() + s.slice(1) : '';
}

/** Name → custom slug, `[a-z0-9_]{1,40}` (the same rule the API and core enforce). */
export function slugifyTriageLabel(name) {
  return String(name || '').normalize('NFD').replace(/[\u0300-\u036f]/g, '').toLowerCase().replace(/[^a-z0-9]+/g, '_').replace(/^_+|_+$/g, '').slice(0, 40);
}

/**
 * Returns `{ badge, tone, color? }` for a triage label, or null to render no
 * chip. A built-in keeps its fixed badge; any other slug is a custom label and
 * renders as a neutral chip named from `labels` (the loaded label list), else
 * the title-cased slug.
 */
export function triageBadge(label, labels) {
  if (!label) return null;
  if (isBuiltinTriageLabel(label)) return TRIAGE[label];
  const def = labels?.find((l) => l.slug === label);
  return { badge: def?.name || titleCaseSlug(label), tone: 'custom', color: def?.color || null };
}

// Shared constants so memoized rows keep a stable prop.
const URGENT = Object.freeze({ badge: 'Urgent', tone: 'urgent' });
const HIGH = Object.freeze({ badge: 'High', tone: 'pending' });

/** Jev's 0–4 priority score → `{ badge, tone }` chip, or null below High. */
export function priorityChip(score) {
  if (score == null || score === '') return null;
  const n = Number(score);
  if (n >= 3.5) return URGENT;
  if (n >= 2.5) return HIGH;
  return null;
}

/** DOM event `{ detail: { id, patch } }`: manual triage changed an MX row
 * (useManualTriage); lists and the open detail patch it in place. */
export const CONVERSATION_PATCHED = 'conversation-patched';

/** The holding pen's slug (both sync modes): mail Jev couldn't place. */
export const HOLDING_PEN_SPACE = 'triage';

/**
 * "Re-run Jev" for one local-channel conversation (Tauri only): the rules run
 * fresh, Jev decides label + priority + Space, and a manual label or Space is
 * cleared (the user asked Jev again). The engine writes the result and fires
 * `triage-updated` / `space-updated`. Resolves to the provenance tag recorded
 * (e.g. `rule:scheduling+jev:jev-1.13.0`).
 */
export async function retriageConversation(conversationKey) {
  const { invoke } = await import('@tauri-apps/api/core');
  return invoke('retriage_conversation', { conversationKey });
}

/** Manually file a local-channel thread into a Space; Jev never moves it again. */
export async function setConversationSpace(conversationKey, slug) {
  const { invoke } = await import('@tauri-apps/api/core');
  return invoke('set_conversation_space', { conversationKey, slug });
}

/** Manually label a local-channel thread; sticks until a new message arrives. */
export async function setConversationLabel(conversationKey, label) {
  const { invoke } = await import('@tauri-apps/api/core');
  return invoke('set_conversation_label', { conversationKey, label });
}
