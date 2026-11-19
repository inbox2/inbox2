import ConversationDetail from '../components/ConversationDetail/ConversationDetail';
import DropdownMenu from '../components/DropdownMenu/DropdownMenu';
import Icon from '../components/Icon';
import useDraftActions from '../hooks/useDraftActions';
import useManualTriage, { manualTriageTarget } from '../hooks/useManualTriage';
import { conversationContextMenuItems, CONV_ACTION } from '../lib/conversationActions';
import { stripSubjectPrefixes } from '../lib/subjectNormalizer';
import { MobileTopBar, MobileIconButton } from './MobileShell';
import styles from './MobileThread.module.css';

/* A conversation, full screen: back · subject · ⋯ on top, the message cards,
 * and a thumb-reach action bar (Reply · Reply all · Forward · Archive · Trash).
 * Reply opens the full-screen composer. The ⋯ menu carries the rest — read
 * state, spam, triage, move to inbox — from the same builder as the desktop
 * context menu, so both offer the same actions per folder. */
export default function MobileThread({
  conversation, orgId, defaultFrom, folderRole, wasUnread = false, enrichingKeys,
  disableArchive = false, disableTrash = false, onBack, onAction, executePriority,
  // Tablet split view: sits in the detail column instead of covering the screen.
  embedded = false,
}) {
  const { reply, replyAll, forward } = useDraftActions({ conversation, defaultFrom });
  const manualTriage = useManualTriage(manualTriageTarget(conversation, orgId));
  const act = (action) => onAction(action);

  const menuItems = conversationContextMenuItems(conversation, {
    onReply: () => reply(),
    onReplyAll: () => replyAll(),
    onForward: () => forward(),
    onMarkReadUnread: () => act(conversation.read ? CONV_ACTION.MARK_UNREAD : CONV_ACTION.MARK_READ),
    onArchive: disableArchive ? undefined : () => act(CONV_ACTION.ARCHIVE),
    onSpam: () => act(CONV_ACTION.SPAM),
    onTrash: disableTrash ? undefined : () => act(CONV_ACTION.TRASH),
    onMoveToInbox: () => act(CONV_ACTION.MOVE_TO_INBOX),
    executePriority,
    manualTriage,
    folderRole,
  });

  return (
    <div className={embedded ? styles.embedded : styles.screen}>
      <MobileTopBar
        leading={embedded
          ? <MobileIconButton icon="xmark" label="Close" onClick={onBack} />
          : <MobileIconButton icon="chevron.left" label="Back" onClick={onBack} />}
        title={stripSubjectPrefixes(conversation.subject) || '(no subject)'}
        subtitle={conversation.message_count > 1 ? `${conversation.message_count} messages` : undefined}
      >
        <DropdownMenu
          align="right"
          trigger={<MobileIconButton icon="ellipsis" label="More actions" />}
          items={menuItems}
        />
      </MobileTopBar>

      <div className={styles.body}>
        <ConversationDetail
          bare
          conversation={conversation}
          defaultFrom={defaultFrom}
          orgId={orgId}
          onConversationAction={act}
          executePriority={executePriority}
          wasUnread={wasUnread}
          focusedMsgIndex={-1}
          enrichingKeys={enrichingKeys || EMPTY}
          disableArchive={disableArchive}
          disableTrash={disableTrash}
          folderRole={folderRole}
        />
      </div>

      <nav className={styles.actions} aria-label="Conversation actions">
        <ActionButton icon="arrowshape.turn.up.left" label="Reply" onClick={() => reply()} />
        <ActionButton icon="arrowshape.turn.up.left.2" label="Reply all" onClick={() => replyAll()} />
        <ActionButton icon="arrowshape.turn.up.right" label="Forward" onClick={() => forward()} />
        <ActionButton icon="archivebox" label="Archive" onClick={() => act(CONV_ACTION.ARCHIVE)} disabled={disableArchive} />
        <ActionButton icon="trash" label="Trash" onClick={() => act(CONV_ACTION.TRASH)} disabled={disableTrash} danger />
      </nav>
    </div>
  );
}

const EMPTY = new Set();

function ActionButton({ icon, label, onClick, disabled, danger }) {
  return (
    <button type="button" className={[styles.action, danger ? styles.danger : ''].join(' ')}
      onClick={onClick} disabled={disabled} aria-label={label}>
      <Icon name={icon} size={19} />
      <span className={styles.actionLabel}>{label}</span>
    </button>
  );
}
