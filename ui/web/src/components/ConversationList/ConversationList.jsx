import { memo } from 'react';
import { AnimatePresence } from 'motion/react';
import ConversationItem from '../ConversationItem';
import SocialListRow from '../SocialListRow/SocialListRow';
import { CONV_ACTION } from '../../lib/conversationActions';
import { isSocial } from '../../lib/providerTypes';
import { conversationItemProps } from './itemProps';
import { socialRowProps } from './socialRowProps';

// One memoized row. The parent's callbacks are useCallback-stable, and `conv`
// records keep their identity across unrelated state changes, so a row only
// re-renders when its own conversation, selection state, or position changes.
// That also keeps conversationItemProps (date formatting, quadrant lookup) off
// the re-render path for the rest of the list.
const Row = memo(function Row({ conv, index, active, selected, isSent, disableArchive, disableTrash, onConversationClick, onConversationContextMenu, onAction, onForward }) {
  // Shared callback surface for both row types.
  const handlers = {
    active,
    selected,
    onClick: (e) => onConversationClick(conv, index, e),
    onContextMenu: (e) => onConversationContextMenu(conv, e),
    onForward: onForward ? () => onForward(conv) : undefined,
    onMarkRead: () => onAction([conv.id], conv.read ? CONV_ACTION.MARK_UNREAD : CONV_ACTION.MARK_READ),
    // Hide the removal action only where it's redundant for the FOLDER in view
    // (no Archive in Archived/Sent/Trash, no Trash in Trash) — same signal the
    // toolbar uses. Keyed on the folder, not per-row status: a Gmail thread can
    // sit in the inbox while its conversation status is 'archived' (mixed
    // inbox/archived messages), and those rows must still be archivable.
    onArchive: disableArchive ? undefined : () => onAction([conv.id], CONV_ACTION.ARCHIVE),
    onTrash: disableTrash ? undefined : () => onAction([conv.id], CONV_ACTION.TRASH),
  };

  // Social channels (Instagram/Messenger/WhatsApp) get a platform-style chat row;
  // email/MX keep the classic ConversationItem unchanged.
  if (isSocial(conv.providerType)) {
    return <SocialListRow {...socialRowProps(conv)} {...handlers} />;
  }
  return <ConversationItem {...conversationItemProps(conv, { isSent })} {...handlers} />;
});

// Renders the inbox row list: one ConversationItem per conversation, with
// selection state and per-row quick actions wired to onAction. Presentational —
// the caller owns the conversations, selection, and action handling. (The
// unified card view and search column view use different item components by
// design, so this is intentionally not shared with them.)
export default function ConversationList({
  conversations,
  selectedId,
  selectedIds,
  isSent = false,
  disableArchive = false,
  disableTrash = false,
  onConversationClick,
  onConversationContextMenu,
  onAction,
  onForward,
}) {
  // AnimatePresence keeps a removed row mounted long enough to play its exit
  // (fade + height collapse) before it leaves the DOM. initial={false} so the
  // list doesn't animate on first paint or when switching views/accounts —
  // only genuine removals animate. It renders a Fragment (no wrapper element),
  // so the rows stay direct siblings and the .item zebra striping is unaffected.
  return (
    <AnimatePresence initial={false}>
      {conversations.map((conv, i) => (
        <Row
          key={conv.id}
          conv={conv}
          index={i}
          active={selectedId === conv.id}
          selected={selectedIds.has(conv.id)}
          isSent={isSent}
          disableArchive={disableArchive}
          disableTrash={disableTrash}
          onConversationClick={onConversationClick}
          onConversationContextMenu={onConversationContextMenu}
          onAction={onAction}
          onForward={onForward}
        />
      ))}
    </AnimatePresence>
  );
}
