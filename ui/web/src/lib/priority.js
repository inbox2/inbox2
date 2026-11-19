// Priority constants for Eisenhower matrix triage.
// Two independent boolean dimensions (urgent, important) compose into four quadrants.

export const PRIORITY_URGENT = 'Urgent';
export const PRIORITY_IMPORTANT = 'Important';
// Marker for the "Later" quadrant (urgent=false, important=false), which would
// otherwise be indistinguishable from an untriaged conversation. Org accounts
// persist it as this tag; external (SQLite) accounts as the priority_triaged
// column.
export const PRIORITY_LATER = 'Later';

// `label` is the quadrant's name (used in the Eisenhower matrix, context panel,
// etc.). `statusLabel` is the past-tense form used where the quadrant reads as a
// status applied to a conversation (e.g. the conversation-list triage chip).
export const QUADRANTS = {
  DO_FIRST: {
    key: 'DO_FIRST',
    urgent: true,
    important: true,
    label: 'Priority',
    statusLabel: 'Prioritized',
    icon: 'flame.fill',
    color: '#e06060',
  },
  SCHEDULE: {
    key: 'SCHEDULE',
    urgent: false,
    important: true,
    label: 'Schedule',
    statusLabel: 'Scheduled',
    icon: 'calendar.badge.clock',
    color: '#6ea8d9',
  },
  DELEGATE: {
    key: 'DELEGATE',
    urgent: true,
    important: false,
    label: 'Delegate',
    statusLabel: 'Delegated',
    icon: 'person.badge.plus',
    color: '#d4a843',
  },
  LATER: {
    key: 'LATER',
    urgent: false,
    important: false,
    label: 'Later',
    statusLabel: 'Snoozed',
    icon: 'clock',
    color: '#6b7280',
  },
};

/** Look up which quadrant a conversation belongs to based on its priority flags. */
export function getQuadrant(urgent, important) {
  if (urgent && important) return QUADRANTS.DO_FIRST;
  if (!urgent && important) return QUADRANTS.SCHEDULE;
  if (urgent && !important) return QUADRANTS.DELEGATE;
  return QUADRANTS.LATER;
}

/** Derive the quadrant for a conversation from its priority fields (columns or tags). */
export function getConvQuadrant(conv) {
  const urgent = conv.priority_urgent || conv.urgent ||
    conv.tags?.some(t => t.name === PRIORITY_URGENT);
  const important = conv.priority_important || conv.important ||
    conv.tags?.some(t => t.name === PRIORITY_IMPORTANT);
  if (urgent || important) return getQuadrant(!!urgent, !!important);
  // Later: no priority flags, but explicitly triaged into the backlog.
  const later = conv.triaged || conv.priority_triaged ||
    conv.tags?.some(t => t.name === PRIORITY_LATER);
  if (later) return QUADRANTS.LATER;
  return null;
}

/** All quadrant keys in display order (top-left, top-right, bottom-left, bottom-right). */
export const QUADRANT_ORDER = ['DO_FIRST', 'DELEGATE', 'SCHEDULE', 'LATER'];
