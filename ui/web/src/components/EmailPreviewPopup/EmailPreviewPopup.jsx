import Avatar from '../Avatar';
import Icon from '../Icon';
import IconButton from '../IconButton';
import Tooltip from '../Tooltip';
import Popover from '../Popover/Popover';
import ChannelAvatar from '../ChannelAvatar/ChannelAvatar';
import { displayName as senderName, emailOnly } from '../../lib/emailAddress';
import { getConvQuadrant } from '../../lib/priority';
import { isSocial, brandFor, brandVars, META_KIND } from '../../lib/providerTypes';
import styles from './EmailPreviewPopup.module.css';

function formatFullTime(dateStr) {
  if (!dateStr) return '';
  const d = new Date(dateStr);
  return d.toLocaleDateString([], { month: 'short', day: 'numeric', year: 'numeric' })
    + ' ' + d.toLocaleTimeString([], { hour: 'numeric', minute: '2-digit' });
}

function truncateBody(text, maxLen) {
  if (!text) return '';
  const clean = text.replace(/\r\n/g, '\n').replace(/\n{3,}/g, '\n\n').trim();
  if (clean.length <= maxLen) return clean;
  return clean.slice(0, maxLen) + '…';
}

// Strip the "<surface>:" prefix Meta identifiers carry ("whatsapp:1555…",
// "messenger:123") and prefix bare handles with "@" so DMs read like a chat
// (mirrors socialRowProps / the chat header).
function socialHandle(addr) {
  if (!addr) return '';
  const stripped = addr.replace(/^(whatsapp|messenger|instagram|facebook|threads):/i, '').trim();
  if (!stripped) return '';
  // Phone-style ids (WhatsApp) and already-@'d handles pass through unchanged.
  return /^[+\d]/.test(stripped) || stripped.startsWith('@') ? stripped : `@${stripped}`;
}

// Per-kind badge for comments/mentions (public post replies, not DMs) — mirrors
// the SocialListRow / Comments folder glyphs.
const KIND_BADGE = {
  [META_KIND.COMMENT]: { icon: 'bubble.left.fill', label: 'Comment' },
  [META_KIND.MENTION]: { icon: 'at', label: 'Mention' },
};

export default function EmailPreviewPopup({
  conversation,
  anchorRect,
  onClose,
  onView,
  onArchive,
  onTrash,
  onMarkRead,
  onUrgent,
  onImportant,
  onPopupMouseEnter,
  onPopupMouseLeave,
}) {
  if (!conversation || !anchorRect) return null;

  // Meta/social channels (Instagram, Messenger, WhatsApp) render chat-style:
  // a channel-badged avatar, @handle + "TO @recipient", and no email subject/Cc.
  const social = isSocial(conversation.providerType);
  const brand = social ? brandFor(conversation) : null;
  const kindBadge = social ? KIND_BADGE[conversation.kind] : null;

  const name = social
    ? (senderName(socialHandle(conversation.from_address)) || socialHandle(conversation.from_address))
    : senderName(conversation.from_address);
  const email = social ? socialHandle(conversation.from_address) : emailOnly(conversation.from_address);
  let rawBody = conversation.snippet || conversation.body_plain || '';
  // Comment/mention snippets may carry a "Comment: '…'" wrapper (demo seed);
  // the kind badge already labels them, so unwrap to the bare text.
  if (kindBadge) rawBody = rawBody.replace(/^Comment:\s*'(.*)'\s*$/, '$1');
  const bodyPreview = truncateBody(rawBody, 500);
  const toAddr = social ? socialHandle(conversation.to_address) : conversation.to_address;
  const ccAddr = social ? null : conversation.cc_address;
  const attachments = conversation.attachments || [];

  const quadrant = getConvQuadrant(conversation);

  return (
    <Popover
      open
      anchorRect={anchorRect}
      placement="bottom"
      onClose={onClose}
      className={social ? `${styles.popup} ${styles.social}` : styles.popup}
      styleVars={social ? brandVars(brand) : undefined}
      onMouseEnter={onPopupMouseEnter}
      onMouseLeave={onPopupMouseLeave}
    >
        {/* Triage toolbar */}
        <div className={styles.toolbar}>
          <span className={styles.toolbarLabel}>Triage</span>
          <div className={styles.toolbarSpacer} />
          <Tooltip content={conversation.read ? 'Mark unread' : 'Mark read'}>
            <IconButton
              icon={conversation.read ? 'envelope.badge' : 'envelope.open'}
              iconSize={13}
              onClick={onMarkRead}
              aria-label={conversation.read ? 'Mark unread' : 'Mark read'}
            />
          </Tooltip>
          <Tooltip content={conversation.urgent ? 'Remove urgent' : 'Mark urgent'}>
            <IconButton
              icon="flame.fill"
              iconSize={13}
              onClick={onUrgent}
              aria-label={conversation.urgent ? 'Remove urgent' : 'Mark urgent'}
            />
          </Tooltip>
          <Tooltip content={conversation.important ? 'Remove important' : 'Mark important'}>
            <IconButton
              icon="star.fill"
              iconSize={13}
              onClick={onImportant}
              aria-label={conversation.important ? 'Remove important' : 'Mark important'}
            />
          </Tooltip>
          <Tooltip content="Archive">
            <IconButton icon="archivebox" iconSize={13} onClick={onArchive} aria-label="Archive" />
          </Tooltip>
          <Tooltip content="Delete">
            <IconButton icon="trash" iconSize={13} variant="danger" onClick={onTrash} aria-label="Delete" />
          </Tooltip>
        </div>

        {/* Header */}
        <div className={styles.header}>
          {social ? (
            <ChannelAvatar name={name} src={conversation.from_avatar} brand={brand} size={32} badgeSize={18} />
          ) : (
            <Avatar name={name} email={email} size={32} />
          )}
          <div className={styles.headerInfo}>
            <div className={styles.headerFrom}>{name}</div>
            <div className={styles.headerEmail}>{email}</div>
          </div>
          <span className={styles.headerTime}>{formatFullTime(conversation.updated_at)}</span>
        </div>

        {/* Addressing */}
        {(toAddr || ccAddr) && (
          <div className={styles.addressing}>
            {toAddr && (
              <div className={styles.addressLine}>
                <span className={styles.addressLabel}>To</span>
                <span className={styles.addressValue}>{toAddr}</span>
              </div>
            )}
            {ccAddr && (
              <div className={styles.addressLine}>
                <span className={styles.addressLabel}>Cc</span>
                <span className={styles.addressValue}>{ccAddr}</span>
              </div>
            )}
          </div>
        )}

        {/* Subject — email only; social channels have no subject line */}
        {!social && (
          <div className={styles.subject} dir="auto">{conversation.subject || '(no subject)'}</div>
        )}

        {/* Applied labels + kind badge + attachments strip */}
        {(quadrant || kindBadge || conversation.has_attachment || attachments.length > 0) && (
          <div className={styles.meta}>
            {kindBadge && (
              <span
                className={styles.kindBadge}
                ref={(el) => { if (el && brand) el.style.setProperty('--brand-accent', brand.accent); }}
              >
                <Icon name={kindBadge.icon} size={10} />
                {kindBadge.label}
              </span>
            )}
            {quadrant && (
              <span
                className={styles.label}
                ref={(el) => { if (el) el.style.setProperty('--triage-color', quadrant.color); }}
              >
                <Icon name={quadrant.icon} size={10} />
                {quadrant.label}
              </span>
            )}
            {attachments.length > 0 ? (
              attachments.map((att, i) => (
                <span key={i} className={styles.attachmentChip}>
                  <Icon name="paperclip" size={8} className={styles.attachmentChipIcon} />
                  {att.filename || att.name || 'attachment'}
                </span>
              ))
            ) : conversation.has_attachment ? (
              <span className={styles.attachmentChip}>
                <Icon name="paperclip" size={8} className={styles.attachmentChipIcon} />
                Attachments
              </span>
            ) : null}
          </div>
        )}

        {/* Body preview */}
        <div className={styles.body}>
          {bodyPreview ? (
            <div className={styles.bodyText}>{bodyPreview}</div>
          ) : (
            <div className={styles.bodyEmpty}>No preview available</div>
          )}
        </div>

        {/* Footer */}
        <div className={styles.footer}>
          <button className={styles.viewBtn} onClick={onView}>
            <Icon name="envelope.open" size={11} />
            View message
          </button>
        </div>
    </Popover>
  );
}
