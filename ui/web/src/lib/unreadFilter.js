// One rule for what the unread view shows, shared by the columns, the channel
// checkboxes and the post-action cursor move — they drifted apart when each
// spelled it out for itself.
//
// Unread rows, plus the pinned one: the row you opened stays in its lane while
// it's selected, so the reading pane marking it read doesn't yank it out from
// under you. It leaves once you move off it. The caller only pins a row that
// was unread when opened — a read one restored via ?c= must not resurrect.
export const filterUnread = (convs, unreadOnly, pinnedId = null) =>
  (unreadOnly ? convs.filter(c => !c.read || c.id === pinnedId) : convs);
