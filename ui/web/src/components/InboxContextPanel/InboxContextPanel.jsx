import { displayName as senderName, emailOnly as senderEmail, parseAddress, parseAddressList } from '../../lib/emailAddress';
import AddressContextMenu from '../DropdownMenu/AddressContextMenu';
import Avatar from '../Avatar';
import Tag from '../Tag';
import { TAG_PRESETS } from '../Tag/presets';
import Icon from '../Icon';
import { ContextGroup, ContextField, ContextRow } from '../ContextPanel';
import StreamItem from '../StreamItem';
import DropdownMenu from '../DropdownMenu/DropdownMenu';
import { AISummaryGroup } from '../ComposeWidgets/ComposeWidgets';
import RoutingPanel from '../RoutingPanel';
import ApolloContact from './ApolloContact';
import LabelsField from '../LabelsField/LabelsField';
import { getConvQuadrant } from '../../lib/priority';
import { triageSubmenu } from '../../lib/conversationActions';
import { formatClock as shortTime } from '../../lib/relativeTime';
import styles from '../../styles/layout.module.css';

// Ask the conversation view (sibling pane) to scroll to and expand a message.
const jumpToMessage = (index) =>
  document.dispatchEvent(new CustomEvent('jump-to-message', { detail: { index } }));

export default function InboxContextPanel({ conversation, executePriority, labelsOrgId, onTagsChange }) {
  if (!conversation) return null;

  const quadrant = getConvQuadrant(conversation);
  const triageItems = executePriority
    ? triageSubmenu([conversation.id], executePriority).submenu
    : [];
  const messages = conversation.messages || [];

  return (
    <>
      <ContextGroup icon="person.fill" title="Contact">
        <ApolloContact conversation={conversation} />
      </ContextGroup>

      <AISummaryGroup conversation={conversation} />

      <ContextGroup icon="doc.text.fill" title="Details">
        <ContextField label="Label">
          <DropdownMenu
            align="left"
            value={quadrant ? `triage_${quadrant.key}` : undefined}
            items={triageItems}
            trigger={quadrant ? (
              <button type="button" className={styles.contextLabelButton}>
                <Tag bg={quadrant.color} fg="var(--text-inverse)" variant="square">
                  <span className={styles.contextLabelInner}>
                    <Icon name={quadrant.icon} size={11} />
                    {quadrant.label}
                    <Icon name="chevron.down" size={8} className={styles.contextLabelChevron} />
                  </span>
                </Tag>
              </button>
            ) : (
              <button type="button" className={styles.contextLabelEmpty}>
                <Icon name="tag.fill" size={11} />
                Set label…
                <Icon name="chevron.down" size={8} className={styles.contextLabelChevron} />
              </button>
            )}
          />
        </ContextField>
        {conversation.assignees?.length > 0 && (
          <ContextField label="Assignee">
            <ContextRow>
              <Avatar name={conversation.assignees[0].username} size={16} />
              <span>{conversation.assignees[0].username}</span>
            </ContextRow>
          </ContextField>
        )}
        <ContextField label="To" mono>
          {parseAddressList(conversation.to_address).map((r, i) => (
            <span key={r.email + i}>
              {i > 0 && ', '}
              <AddressContextMenu focusable email={r.email} name={r.explicit ? r.name : ''}>{r.email}</AddressContextMenu>
            </span>
          ))}
        </ContextField>
        <ContextField label="From" mono>
          <AddressContextMenu focusable email={senderEmail(conversation.from_address)} name={parseAddress(conversation.from_address).explicit ? senderName(conversation.from_address) : ''}>{senderEmail(conversation.from_address)}</AddressContextMenu>
        </ContextField>
        {labelsOrgId && (
          <ContextField label="Labels">
            <LabelsField conversation={conversation} orgId={labelsOrgId} onTagsChange={onTagsChange} />
          </ContextField>
        )}
        {!labelsOrgId && conversation.tags?.length > 0 && (
          <ContextField label="Tags">
            <ContextRow>
              {conversation.tags.map((t, i) => {
                // Tags may be plain strings (simplified callers) or objects.
                const label = typeof t === 'string' ? t : t.name;
                const preset = TAG_PRESETS[(label || '').toLowerCase()] || {};
                return (
                  <Tag
                    key={t.id || label || i}
                    bg={t.bg || preset.bg || t.color || 'var(--accent-primary)'}
                    fg="var(--text-inverse)"
                    variant="square"
                  >{label}</Tag>
                );
              })}
            </ContextRow>
          </ContextField>
        )}
      </ContextGroup>

      <RoutingPanel conversation={conversation} />

      {messages.length > 1 && (
        <ContextGroup icon="list.bullet.rectangle" title="Activity">
          {messages.map((_, i) => messages.length - 1 - i).map((i) => {
            const m = messages[i];
            return (
              <StreamItem
                key={m.id || i}
                name={senderName(m.from_address)}
                text={i === 0 ? 'sent' : 'replied'}
                time={shortTime(m.created_at)}
                onClick={() => jumpToMessage(i)}
              />
            );
          })}
        </ContextGroup>
      )}
    </>
  );
}
