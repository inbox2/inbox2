import { useEffect, useMemo, useRef } from 'react';
import { displayName as senderName, emailOnly as senderEmail } from '../../lib/emailAddress';
import { stripSubjectPrefixes } from '../../lib/subjectNormalizer';
import { linkifyText } from '../../lib/linkifyText';
import useDraftActions from '../../hooks/useDraftActions';
import useManualTriage, { manualTriageTarget } from '../../hooks/useManualTriage';
import MessageCard from '../MessageCard';
import E2eeUnlock from '../E2eeUnlock/E2eeUnlock';
import useSealedMessages from '../../hooks/useSealedMessages';
import NoteCard from '../NoteCard';
import ChatThread from '../ChatThread/ChatThread';
import CommentCard from '../CommentCard/CommentCard';
import SmartReplyBar from '../SmartReplyBar';
import Composer from '../Composer';
import ToolbarGroup, { ToolbarButton, ToolbarDivider } from '../ToolbarGroup';
import DropdownMenu from '../DropdownMenu/DropdownMenu';
import { triageSubmenu } from '../../lib/conversationActions';
import { isSocial, META_KIND } from '../../lib/providerTypes';
import { mapMxAttachments } from '../../lib/mxAttachments';
import styles from '../../styles/layout.module.css';
import detailStyles from './ConversationDetail.module.css';

export default function ConversationDetail({ conversation: rawConversation, defaultFrom, orgId, onArchive, onTrash, onConversationAction, executePriority, wasUnread, focusedMsgIndex, onFocusMessage, enrichingKeys, disableArchive = false, disableTrash = false, folderRole, headerExtra, bare = false }) {
  // Sealed (E2EE) conversations decrypt client-side; plaintext ones pass
  // through untouched (docs/E2EE.md Phase F).
  const { conversation, hasSealed, sealedLocked, identityStatus } = useSealedMessages(rawConversation, orgId);
  const { reply, replyAll, forward } = useDraftActions({ conversation, defaultFrom });
  const messagesRef = useRef(null);
  // One manual-triage source for the toolbar's Triage menu and every card's menu.
  const manualTriage = useManualTriage(manualTriageTarget(rawConversation, orgId));

  // Social channels render as a chat thread (DMs) or a comment card
  // (comments/mentions) instead of the email message list. Email/MX is unchanged.
  const social = isSocial(conversation.providerType);
  const isCommentSurface = social
    && (conversation.kind === META_KIND.COMMENT || conversation.kind === META_KIND.MENTION);

  // Linkifying runs regexes over entire plain-text bodies; keep it out of the
  // per-render path so unrelated state changes don't re-process every message.
  const messageBodies = useMemo(
    () => (conversation.messages ?? []).map(msg => msg.body_html || linkifyText(msg.body_plain) || ''),
    [conversation.messages]
  );
  // MX attachments arrive in the API's shape (filename/size_bytes/download_url);
  // local-channel ones are already mapped to the UI shape by the provider fetch.
  // mapMxAttachments passes the latter through, so this one call covers both.
  const messageAttachments = useMemo(
    () => (conversation.messages ?? []).map(msg => mapMxAttachments(msg.attachments)),
    [conversation.messages]
  );
  const noteTimes = useMemo(
    () => (conversation.notes ?? []).map(note => new Date(note.created_at).toLocaleString()),
    [conversation.notes]
  );

  useEffect(() => {
    if (!messagesRef.current) return;
    const container = messagesRef.current;

    // Open on the newest message, its top at the top of the pane. A short one
    // can't scroll that far, so the thread just sits scrolled to the bottom.
    // (Read threads used to open at the top of the thread, the newest message
    // below the fold under a stack of collapsed ones.)
    const cards = container.querySelectorAll('[data-message-card]');
    const last = cards[cards.length - 1];
    if (last) last.scrollIntoView({ block: 'start', behavior: 'instant' });
    else container.scrollTop = 0;
  }, [conversation?.id]);

  // Jump to (and expand) a specific message when an activity entry is clicked
  // in the context panel. Mirrors the keyboard-nav approach of locating cards
  // by their DOM marker and toggling collapse via the header click handler.
  useEffect(() => {
    const handler = (e) => {
      const index = e.detail?.index;
      const container = messagesRef.current;
      if (index == null || !container) return;
      const card = container.querySelectorAll('[data-message-card]')[index];
      if (!card) return;
      if (card.className.includes('collapsed')) {
        // Expanding scrolls the card to the top of the viewport itself.
        card.querySelector('[class*="header"]')?.click();
      } else {
        card.scrollIntoView({ block: 'start', behavior: 'smooth' });
      }
    };
    document.addEventListener('jump-to-message', handler);
    return () => document.removeEventListener('jump-to-message', handler);
  }, []);

  const handleMessageAction = (actionId, msg) => {
    switch (actionId) {
      case 'reply': reply(msg); break;
      case 'reply-all': replyAll(msg); break;
      case 'forward': forward(msg); break;
    }
  };

  // `bare`: the phone thread screen (src/mobile/) brings its own top bar and
  // action bar, so it takes only the messages — no toolbar, no inline composer.
  return (
    <>
      {!bare && (
      <div className={social ? `${styles.detailHeader} ${detailStyles.socialChrome}` : styles.detailHeader}>
        <h1 className={styles.detailSubject} dir="auto">{stripSubjectPrefixes(conversation.subject) || '(no subject)'}</h1>
        <ToolbarGroup>
          <ToolbarButton icon="arrowshape.turn.up.left" color="blue" onClick={() => reply()}>Reply</ToolbarButton>
          {/* Reply-all / Forward are email concepts — hide them on social channels. */}
          {!social && <ToolbarButton icon="arrowshape.turn.up.left.2" color="indigo" onClick={() => replyAll()}>All</ToolbarButton>}
          {!social && <ToolbarButton icon="arrowshape.turn.up.right" color="teal" onClick={() => forward()}>Fwd</ToolbarButton>}
          <ToolbarButton icon="archivebox.fill" color="rose" onClick={onArchive} disabled={disableArchive}
            title={disableArchive ? 'Not available in this folder' : undefined}>Archive</ToolbarButton>
          <ToolbarButton icon="trash.fill" color="red" onClick={onTrash} disabled={disableTrash}
            title={disableTrash ? 'Already in Trash' : undefined}>Delete</ToolbarButton>
          <DropdownMenu
            align="left"
            trigger={<ToolbarButton icon="tag.fill" color="amber">Triage</ToolbarButton>}
            items={triageSubmenu([conversation.id], executePriority, { manual: manualTriage }).submenu}
          />
          {/* Host-supplied trailing control (the reading pane's mode picker) —
              set off from the message actions, which it has nothing to do with. */}
          {headerExtra && <ToolbarDivider />}
          {headerExtra}
        </ToolbarGroup>
      </div>
      )}

      {isCommentSurface ? (
        <CommentCard conversation={conversation} />
      ) : social ? (
        <ChatThread conversation={conversation} enrichingKeys={enrichingKeys} focusedMsgIndex={focusedMsgIndex} />
      ) : (
      <div ref={messagesRef} className={styles.detailMessages}>
        {hasSealed && sealedLocked && <E2eeUnlock identityStatus={identityStatus} />}
        {conversation.messages?.map((msg, i) => {
          const msgs = conversation.messages;
          const lastIndex = msgs.length - 1;
          const shouldCollapse = msgs.length > 1 && i !== lastIndex;
          return (
            <MessageCard
              key={msg.id}
              sender={senderName(msg.from_address)}
              email={senderEmail(msg.from_address)}
              time={msg.created_at}
              body={messageBodies[i]}
              isHtml={!!msg.body_html}
              attachments={messageAttachments[i]}
              message={msg}
              orgId={orgId}
              conversationId={conversation.id}
              conversation={conversation}
              defaultFrom={defaultFrom}
              onAction={(actionId) => handleMessageAction(actionId, msg)}
              onConversationAction={onConversationAction}
              folderRole={folderRole}
              executePriority={executePriority}
              manualTriage={manualTriage}
              unread={wasUnread && i === lastIndex}
              showTriage={i === lastIndex}
              defaultCollapsed={shouldCollapse}
              focused={focusedMsgIndex === i}
              onFocusCard={() => onFocusMessage?.(i)}
              enriching={enrichingKeys.has(msg.key || msg.id)}
            />
          );
        })}
        {conversation.notes?.map((note, i) => (
          <NoteCard
            key={note.id}
            author={note.author?.username || 'Unknown'}
            time={noteTimes[i]}
          >
            <p>{note.body}</p>
          </NoteCard>
        ))}
      </div>
      )}

      {!bare && conversation.messages?.length > 0 && (
        <SmartReplyBar
          emailText={conversation.messages[conversation.messages.length - 1]?.body_plain || ''}
          senderName={senderName(conversation.messages[conversation.messages.length - 1]?.from_address)}
          onSelectReply={(reply) => {
            document.dispatchEvent(new CustomEvent('smart-reply-selected', { detail: reply }));
          }}
        />
      )}

      {!bare && (
      <Composer
        conversationId={conversation.id}
        replyTo={conversation.from_address}
        replySubject={conversation.subject}
        defaultFrom={defaultFrom}
        messages={conversation.messages}
        orgId={orgId}
        executePriority={executePriority}
        placeholder={conversation.from_address ? `Reply to ${senderName(conversation.from_address)}…  (/ for commands)` : undefined}
      />
      )}
    </>
  );
}
