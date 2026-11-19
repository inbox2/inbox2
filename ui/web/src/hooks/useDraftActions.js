import { useCallback } from 'react';
import useDrafts from './useDrafts';
import { buildQuotedHtml, buildForwardHtml, buildForwardChainHtml } from '../lib/draftBuilders';
import { forwardAttachmentPlaceholders } from '../lib/draftAttachments';
import { replyAllRecipients, replyFromAddress, emailOnly } from '../lib/emailAddress';
import useFromIdentities from './useFromIdentities';

/**
 * Reply / Reply All / Forward actions for a conversation.
 *
 * Shared by ConversationDetail's toolbar buttons and the keyboard shortcuts
 * (useMessageActionShortcuts), so both paths behave identically:
 *   - reply    → focuses the inline composer at the bottom of the detail pane
 *                (popup composer when the reading pane isn't showing one).
 *   - replyAll → opens the global composer popup prefilled with the original
 *                To/Cc structure (sender + To on To, Cc stays Cc, self dropped).
 *   - forward  → opens the global composer popup prefilled with the forward chain.
 *
 * replyAll/forward accept an optional `msg` to target a specific message; when
 * omitted they target the last message / the whole thread.
 */
export default function useDraftActions({ conversation, defaultFrom }) {
  const { createDraft } = useDrafts();
  const identities = useFromIdentities();
  const lastMsg = conversation?.messages?.[conversation.messages.length - 1];

  // Reply uses the inline composer (already wired to the conversation's sender
  // + subject). Notify it to scroll into view, focus, and flash for visibility.
  // No inline composer mounted (reading pane hidden/closed) → nobody cancels the
  // event, so open the popup composer instead.
  const reply = useCallback((msg) => {
    if (!document.dispatchEvent(new CustomEvent('inline-compose-reply', { cancelable: true }))) return;
    const target = msg || lastMsg;
    if (!target?.from_address || !conversation) return; // sealed + locked: no sender yet
    const from = replyFromAddress(target, identities, defaultFrom);
    const fromSelf = emailOnly(target.from_address || '').toLowerCase() === emailOnly(from || '').toLowerCase();
    createDraft({
      conversationId: conversation.id,
      fromAddress: from,
      toAddress: fromSelf ? target.to_address : target.from_address,
      subject: conversation.subject?.startsWith('Re: ') ? conversation.subject : `Re: ${conversation.subject || ''}`,
      quotedHtml: buildQuotedHtml(target),
      replyToMessageKey: target.key,
      focus: 'body',
    });
  }, [conversation, defaultFrom, lastMsg, createDraft, identities]);

  const replyAll = useCallback((msg) => {
    const target = msg || lastMsg;
    if (!target || !conversation) return;
    const from = replyFromAddress(target, identities, defaultFrom);
    const { to, cc } = replyAllRecipients(target, from);
    createDraft({
      conversationId: conversation.id,
      fromAddress: from,
      toAddress: to,
      ccAddress: cc,
      subject: conversation.subject?.startsWith('Re: ') ? conversation.subject : `Re: ${conversation.subject || ''}`,
      quotedHtml: buildQuotedHtml(target),
      // Thread the reply under the targeted message (engine hydrates the RFC
      // headers + provider thread id from this key at send time).
      replyToMessageKey: target.key,
      focus: 'body',
    });
  }, [conversation, defaultFrom, lastMsg, createDraft, identities]);

  // Forward opens the global composer popup. With a specific message, forward
  // just that message; otherwise forward the whole conversation chain. The
  // forwarded message's attachments are carried onto the draft (standard mail
  // behavior — a quoted forward alone drops them).
  const forward = useCallback(async (msg) => {
    if (!conversation) return;
    const target = msg || lastMsg;
    // Seed the original attachments as pending placeholders so the composer opens
    // instantly; ComposePopup downloads the bytes (cached) and unblocks Send.
    // A whole-thread forward quotes every message, so it carries every message's
    // files — the one on the first message used to drop once anyone replied.
    const sources = msg ? [msg] : (conversation.messages?.length ? conversation.messages : [target]);
    const seen = new Set();
    const attachments = (await Promise.all(sources.map(forwardAttachmentPlaceholders)))
      .flat()
      .filter(a => {
        // The placeholder key names the source attachment, so only the same
        // file seen twice drops — never two different files that share a name.
        return !seen.has(a.key) && seen.add(a.key);
      });
    createDraft({
      conversationId: conversation.id,
      fromAddress: replyFromAddress(target, identities, defaultFrom),
      subject: conversation.subject?.startsWith('Fwd: ') ? conversation.subject : `Fwd: ${conversation.subject || ''}`,
      quotedHtml: msg ? buildForwardHtml(msg) : buildForwardChainHtml(conversation),
      attachments,
    });
  }, [conversation, defaultFrom, lastMsg, createDraft, identities]);

  return { reply, replyAll, forward };
}
