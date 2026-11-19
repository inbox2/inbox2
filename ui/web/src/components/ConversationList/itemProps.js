import { displayName as senderName, recipientName } from '../../lib/emailAddress';
import { stripSubjectPrefixes } from '../../lib/subjectNormalizer';
import { getConvQuadrant } from '../../lib/priority';
import { conversationPreview } from '../../lib/conversationPreview';
import { priorityChip } from '../../lib/triage';

// Map an API/SQLite conversation record to the presentational props a
// ConversationItem row expects. Pure (no JSX/CSS imports) so it can be unit
// tested in the node test env; ConversationList spreads the result.
//
// `isSent` flips the row to name the recipient instead of the (self) sender —
// the Sent folder is the one view where the from-address is always the user, so
// "who I sent it to" is the useful identity. See viewFolderRole(FOLDER_ROLE.SENT).
export function conversationItemProps(conv, { isSent = false } = {}) {
  // In Sent, show when the mail was actually sent (the latest outbound message's
  // date) rather than the thread's updated_at, which a later inbound reply — or a
  // re-dated message with an unparseable Date header — can bump to a wrong/recent
  // value. Falls back to updated_at when no outbound date is available.
  const rowDate = isSent ? (conv.sent_at || conv.updated_at) : conv.updated_at;
  return {
    sender: isSent ? recipientName(conv.to_address) : senderName(conv.from_address),
    subject: stripSubjectPrefixes(conv.subject) || '(no subject)',
    snippet: conversationPreview(conv),
    time: new Date(rowDate).toLocaleDateString(),
    unread: !conv.read,
    tags: conv.tags?.map((t) => ({ name: t.name, bg: t.color })),
    assignee: conv.assignees?.[0]?.username,
    count: conv.message_count || 1,
    hasAttachment: conv.has_attachment,
    quadrant: getConvQuadrant(conv),
    // Jev's urgency (both sync modes): an Urgent/High chip, nothing below.
    priority: priorityChip(conv.triage_priority),
    // Set on cross-folder search hits that live outside the inbox (Archive/Spam/
    // Trash); ConversationItem renders it as a small folder badge.
    folder: conv.searchFolder || null,
  };
}
