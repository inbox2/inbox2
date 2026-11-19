// The metric set the Team activity board tallies — same keys the API returns
// under `totals` (ActivityEvent::METRIC_ACTIONS). Order = display order.
export const ACTIVITY_METRICS = [
  { key: 'replied', label: 'Replied', icon: 'arrowshape.turn.up.left' },
  { key: 'read', label: 'Read', icon: 'envelope.open' },
  { key: 'archived', label: 'Archived', icon: 'archivebox' },
  { key: 'deleted', label: 'Deleted', icon: 'trash' },
  { key: 'snoozed', label: 'Snoozed', icon: 'clock' },
  { key: 'assigned', label: 'Assigned', icon: 'person.badge.plus' },
];
