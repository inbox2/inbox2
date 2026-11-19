import { useEffect, useMemo, useRef, useState } from 'react';
import { useOutletContext } from 'react-router';
import ConversationDetail from '../../components/ConversationDetail/ConversationDetail';
import Icon from '../../components/Icon';
import useSelectedConversationDetail from '../../hooks/useSelectedConversationDetail';
import useAuth from '../../hooks/useAuth';
import { CONV_ACTION } from '../../lib/conversationActions';
import { setConversationPriority } from '../../lib/conversationPriority';
import { LORE_MAIN_ID } from '../../components/Lore/openItem';
import WaChatPane from '../../components/WaChatPane/WaChatPane';
import { WA_SOURCE } from '../../lib/lore';
import styles from '../../components/Lore/Lore.module.css';

const LOAD_TIMEOUT_MS = 15 * 1000;
const READ_ACTIONS = [CONV_ACTION.MARK_READ, CONV_ACTION.MARK_UNREAD];
const FILING_ACTIONS = [CONV_ACTION.ARCHIVE, CONV_ACTION.TRASH, CONV_ACTION.SPAM];

/**
 * The email behind a Lore item, opened beside the page (Notion's side peek) so
 * reading it never leaves Lore. Same reading pane as the inbox — reply, forward,
 * archive and the rest — over the same detail loader. Archiving here ticks the
 * item off. `onClose` closes the peek; `onOpenInInbox` goes to the mail view.
 */
export default function LorePeek({ item, lore, onClose, onOpenInInbox }) {
  // Each attempt remounts the body, so "Try again" re-runs the detail loader.
  const [attempt, setAttempt] = useState(0);
  // Focus moves into the peek when it opens and back to the row when it closes.
  const ref = useRef(null);
  useEffect(() => {
    const back = document.activeElement;
    ref.current?.focus();
    // The row is gone after Archive/Delete: fall back to the Lore page itself.
    return () => (back?.isConnected ? back.focus() : document.getElementById(LORE_MAIN_ID)?.focus());
  }, []);

  return (
    <aside ref={ref} tabIndex={-1} className={styles.peek} aria-label="Email">
      <div className={styles.peekBar}>
        <button type="button" className={styles.iconButton} onClick={onClose} aria-label="Close" title="Close (Esc)">
          <Icon name="xmark" size={12} />
        </button>
        <span className={styles.crumb}>{item.subject}</span>
        <span className={styles.topbarRight}>
          <button type="button" className={`${styles.button} ${styles.ghost}`} onClick={onOpenInInbox}>
            <Icon name="arrow.up.right" size={11} /> {item.source === WA_SOURCE ? 'Open in WhatsApp tab' : 'Open in inbox'}
          </button>
        </span>
      </div>
      <div className={styles.peekBody}>
        {item.source === WA_SOURCE ? (
          <WaChatPane chat={{ id: item.chatId, name: item.subject, avatar: item.avatar, is_group: item.isGroup }} anchorId={item.askId} />
        ) : <PeekDetail
          key={attempt}
          item={item}
          lore={lore}
          onClose={onClose}
          onOpenInInbox={onOpenInInbox}
          onRetry={() => setAttempt((a) => a + 1)}
        />}
      </div>
    </aside>
  );
}

function PeekDetail({ item, lore, onClose, onOpenInInbox, onRetry }) {
  const { allAccounts = [] } = useOutletContext() || {};
  const { user } = useAuth();
  const [conversation, setConversation] = useState(null);
  const [enrichingKeys, setEnrichingKeys] = useState(new Set());
  // The thread's read state as it changes here, so badge moves use the current one.
  const [unread, setUnread] = useState(item.unread);

  // The one-row "list" the detail loader resolves provider + account from.
  const rows = useMemo(() => [{
    id: item.id,
    accountKey: item.accountKey || item.orgId,
    orgKey: item.orgId,
    providerType: item.source === 'local' ? (item.provider || 'imap') : 'inbox2',
  }], [item]);
  useSelectedConversationDetail({ selectedId: item.id, conversations: rows, setSelectedConv: setConversation, setEnrichingKeys, logTag: 'LorePeek' });

  // The shared loader swallows errors, so a load that hasn't landed after a while
  // shows as failed, with a retry. ponytail: a timeout, not the real error —
  // thread one through useSelectedConversationDetail if the copy matters.
  const [stalled, setStalled] = useState(false);
  useEffect(() => {
    if (conversation) return undefined;
    const t = setTimeout(() => setStalled(true), LOAD_TIMEOUT_MS);
    return () => clearTimeout(t);
  }, [conversation]);

  // Reply from the address the mail came to: the channel's own address, or on MX
  // the person's mailbox on the domain it arrived at.
  const defaultFrom = item.source === 'local'
    ? allAccounts.find((a) => a.key === item.accountKey)?.email_address || ''
    : (item.mailDomain && user?.username ? `${user.username}@${item.mailDomain}` : '');
  const current = { ...item, unread };

  const onAction = async (action) => {
    if (FILING_ACTIONS.includes(action)) {
      lore.complete(current, action);
      onClose();
    } else if (action === CONV_ACTION.MOVE_TO_INBOX) {
      // A UI verb; restoring resolves it per sync mode (useLore.restore).
      lore.restore(current);
      onClose();
    } else if (await lore.complete(current, action) && READ_ACTIONS.includes(action)) {
      // Only once it landed: the pane's menu reads this state.
      setUnread(action === CONV_ACTION.MARK_UNREAD);
      setConversation((c) => (c ? { ...c, read: action === CONV_ACTION.MARK_READ } : c));
    }
  };

  if (conversation) {
    return (
      <ConversationDetail
        conversation={conversation}
        defaultFrom={defaultFrom}
        orgId={item.orgId}
        onArchive={() => onAction(CONV_ACTION.ARCHIVE)}
        onTrash={() => onAction(CONV_ACTION.TRASH)}
        onConversationAction={onAction}
        executePriority={(_ids, key) => setConversationPriority({ id: item.id, accountKey: item.accountKey, orgId: item.orgId }, key)}
        wasUnread={item.unread}
        focusedMsgIndex={-1}
        enrichingKeys={enrichingKeys}
      />
    );
  }
  if (stalled) {
    return (
      <div className={styles.empty} role="alert">
        Couldn't load this email.
        <span>
          <button type="button" className={styles.button} onClick={onRetry}>Try again</button>
          {' '}
          <button type="button" className={`${styles.button} ${styles.ghost}`} onClick={onOpenInInbox}>Open in inbox</button>
        </span>
      </div>
    );
  }
  return <p className={styles.muted}>Loading the email…</p>;
}
