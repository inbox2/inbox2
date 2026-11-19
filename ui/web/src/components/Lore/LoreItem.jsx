import { openLink } from '../../lib/openLink';
import { memo } from 'react';
import Checkbox from '../Checkbox/Checkbox';
import Icon from '../Icon';
import { Mention } from './EntityIcon';
import { BUCKET_TAG, LORE_BUCKET, WA_SOURCE, ageLabel, ageStep, dueLabel, dueSoon, isMemberDone } from '../../lib/lore';
import { providerIcon } from '../../lib/providerTypes';
import { priorityChip } from '../../lib/triage';
import styles from './Lore.module.css';

/**
 * One Lore to-do: a real checkbox (ticking it archives the thread), the
 * subject, who it's from and the one-line summary. `compact` is the side-panel
 * row; `showBucket` adds the bucket tag (mixed lists: search, an org's page).
 *   onToggle(item)  tick off      onOpen(item)  open the email
 *   onEntity({ kind, domain, address, name })  open an org / person page
 *   group — a groupItems() group of 2+ threads: the row stands for all of them
 *           (ticking archives every one), with a count that unfolds the list.
 *   tone  — the section's colour: a bar in the left gutter, fading as the mail ages.
 */
function LoreItem({ item, group = null, expanded = false, onExpand, compact = false, tone = null, showBucket = false, inGroup = false, onToggle, onOpen, onEntity, onSendTo }) {
  const many = group && group.items.length > 1;
  const amount = many ? (group.total || item.amount) : item.amount;
  const dueAt = many ? group.dueAt : item.dueAt;
  const urgent = priorityChip(item.priority < 0 ? null : item.priority);
  const who = item.domain
    ? { kind: 'org', domain: item.domain, name: item.from }
    : { kind: 'person', address: item.address, name: item.from };
  const waiting = item.bucket === LORE_BUCKET.WAITING;
  // A WhatsApp ask: badged with the app, and its sender has no person page (no address).
  const whatsApp = item.source === WA_SOURCE;
  const noun = whatsApp ? 'chats' : 'emails';
  return (
    <div
      className={`${styles.item} ${compact ? styles.itemCompact : ''} ${tone ? `${styles.toned} ${styles[`bar_${tone}`]}` : ''}`}
      data-age={tone ? ageStep(item.at) : undefined}
    >
      <Checkbox
        className={styles.check}
        checked={false}
        onChange={() => onToggle?.(many ? group.items : item)}
        aria-label={whatsApp || isMemberDone(item)
          ? (many ? `Done — mark all ${group.items.length} ${noun} about "${item.title}" done` : `Done — mark "${item.title}" done`)
          : (many ? `Done — archive all ${group.items.length} emails about "${item.title}"` : `Done — archive "${item.title}"`)}
      />
      <div className={styles.itemBody}>
        <div className={styles.itemLine}>
          <button type="button" className={styles.itemTitle} onClick={() => onOpen?.(item)} title={whatsApp ? `Open the chat — ${item.subject}` : `Open the email — ${item.subject}`}>
            {item.title}
          </button>
          {many && (
            <button type="button" className={styles.mergedCount} onClick={onExpand} aria-expanded={expanded} title={expanded ? `Hide the ${noun}` : `Show the ${noun}`}>
              <Icon name="chevron.right" size={8} className={`${styles.chevron} ${expanded ? styles.chevronOpen : ''}`} />
              {group.items.length} {noun}
            </button>
          )}
          {!many && item.reminder && <span className={styles.tag}>Reminder</span>}
          {showBucket && <span className={`${styles.tag} ${styles[`tag_${item.bucket}`]}`}>{item.labelName || BUCKET_TAG[item.bucket]}</span>}
          {!showBucket && item.labelName && <span className={`${styles.tag} ${styles.tag_work}`}>{item.labelName}</span>}
          {urgent && <span className={`${styles.tag} ${styles.tag_urgent}`}>{urgent.badge}</span>}
          {amount && <span className={styles.amount}>{amount}</span>}
          {dueAt && (
            <span className={`${styles.tag} ${dueSoon(dueAt) ? styles.tag_urgent : ''}`} title="Due date found in the email">
              Due {dueLabel(dueAt)}
            </span>
          )}
        </div>
        {/* A WhatsApp ask keeps its preview in the compact panel too: its title is
            often just the ask's opening ("@You"), which says nothing on its own. */}
        {/* Opens like the title; the title is the keyboard's way in, so this skips the Tab order. */}
        {(!compact || whatsApp) && item.detail && (
          <button type="button" tabIndex={-1} className={styles.itemDetail} onClick={() => onOpen?.(item)}>{item.detail}</button>
        )}
        <div className={styles.itemMeta}>
          {whatsApp && <img className={styles.sourceIcon} src={providerIcon(item.provider)} alt="WhatsApp" title="From WhatsApp on this Mac" />}
          <Mention {...who} onClick={whatsApp ? () => onOpen?.(item) : onEntity && (() => onEntity(who))} />
          {/* A tracked group's to-do names its group, which is a Lore page (not on that page itself). */}
          {item.group && !inGroup && (
            <Mention kind="org" name={item.group.name} onClick={onEntity && (() => onEntity({ kind: 'group', chatId: item.group.chatId }))} />
          )}
          {item.unread && <span className={styles.unreadDot} aria-label="Unread" />}
          {item.sent && (
            <button type="button" className={styles.sentChip} disabled={!item.sent.url} title={`Sent to ${item.sent.connection_name}`}
              onClick={() => openLink(item.sent.url)}>
              <Icon name="paperplane" size={10} />
              {item.sent.reference || `Sent to ${item.sent.connection_name}`}
            </button>
          )}
          <span className={styles.age}>{waiting ? `waiting ${ageLabel(item.at)}` : ageLabel(item.at)}</span>
          {onSendTo && (
            <button type="button" className={`${styles.iconButton} ${styles.rowAction}`} onClick={() => onSendTo(item)} aria-label={`Send "${item.subject}" to another app`} title="Send to… (Linear, Jira, HubSpot…)">
              <Icon name="paperplane" size={12} />
            </button>
          )}
        </div>
      </div>
    </div>
  );
}

export default memo(LoreItem);
