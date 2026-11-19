import { useState } from 'react';
import { format, isValid } from 'date-fns';
import { ToolbarButton } from '../ToolbarGroup';
import Icon from '../Icon';
import IconButton from '../IconButton';
import Linkify from '../Linkify';
import Popover from '../Popover/Popover';
import MeetingProviderIcon from '../MeetingProviderIcon/MeetingProviderIcon';
import { detectMeeting } from '../MeetingProviderIcon/meetingProvider';
import { openLink } from '../../lib/openLink';
import { PREP_LEADS } from '../../lib/zones';
import styles from './EventDetailPopup.module.css';

// Attendee RSVP status arrives in two shapes: the Rails API serializes
// snake_case (`response_status`, e.g. "needs_action"); the offline calendar
// sync stores the provider's camelCase (`responseStatus`, e.g. "needsAction").
// Normalize to a snake_case key so the badge class + label work for both — and
// tolerate it being absent (older synced events) instead of crashing on
// `.replace` of undefined, which took down the whole detail view.
function rsvpKey(att) {
  const raw = att.response_status || att.responseStatus || '';
  return raw.replace(/([a-z])([A-Z])/g, '$1_$2').toLowerCase();
}

// A glance at an event. Everything you can do with it — Edit, Delete — lives in
// the full view that View opens (the same one a double-click opens).
export default function EventDetailPopup({ event, position, anchorRect, placement, onClose, onView, onRespondProposal, onPrepZone, canEdit = true }) {
  const start = event.start_at ? new Date(event.start_at) : null;
  const end = event.end_at ? new Date(event.end_at) : null;
  const timeStr = event.all_day
    ? 'All day'
    : isValid(start) && isValid(end)
      ? `${format(start, 'EEE, MMM d')} \u00b7 ${format(start, 'h:mm a')} \u2013 ${format(end, 'h:mm a')}`
      : '';

  // The provider's own conference link when the channel synced one, else the one
  // written into the location/description. Null for anything with no way in.
  const meeting = detectMeeting(event);

  // Counter-proposals (docs/Calendar.md): an attendee suggesting a different
  // time. Only the organizer can act on one, so the row is action-less for
  // everyone else rather than hidden — knowing a time was proposed is useful.
  const proposals = (event.attendees || []).filter(a => a.proposed_start);

  // A prep zone (docs/Calendar.md "Zones") only makes sense before a timed
  // meeting that hasn't started yet.
  const [openedAt] = useState(() => Date.now());
  const canPrep = onPrepZone && !event.all_day && isValid(start) && start.getTime() > openedAt;

  return (
    <Popover open position={position} anchorRect={anchorRect} placement={placement} onClose={onClose} className={styles.popup}>
      <div className={styles.header}>
        <h3 className={styles.title}>
          {meeting?.provider && <MeetingProviderIcon provider={meeting.provider} size={18} />}
          {event.title}
        </h3>
        <IconButton icon="xmark" onClick={onClose} aria-label="Close" />
      </div>

      {meeting && (
        <button className={styles.join} onClick={() => openLink(meeting.url)}>
          {meeting.provider
            ? <MeetingProviderIcon provider={meeting.provider} size={16} />
            : <Icon name="link" size={14} />}
          Join {meeting.label}
        </button>
      )}

      <div className={styles.time}>
        <Icon name="clock" size={14} />
        <span>{timeStr}</span>
      </div>

      {event.location && (
        <div className={styles.detail}>
          <Icon name="mappin.and.ellipse" size={14} />
          <span><Linkify text={event.location} className={styles.link} /></span>
        </div>
      )}

      {event.organizer_name && (
        <div className={styles.detail}>
          <Icon name="person" size={14} />
          <span>{event.organizer_name} ({event.organizer_email})</span>
        </div>
      )}

      {event.attendees && event.attendees.length > 0 && (
        <div className={styles.attendees}>
          <div className={styles.attendeesLabel}>
            <Icon name="person.2" size={14} />
            <span>{event.attendees.length} attendee{event.attendees.length !== 1 ? 's' : ''}</span>
          </div>
          <div className={styles.attendeeList}>
            {event.attendees.slice(0, 5).map((att, i) => {
              const status = rsvpKey(att);
              return (
                <div key={att.id || att.email || i} className={styles.attendeeRow}>
                  <span className={styles.attendeeName}>{att.name || att.email}</span>
                  {status && (
                    <span className={`${styles.rsvpBadge} ${styles[`rsvp_${status}`] || ''}`}>
                      {status.replace(/_/g, ' ')}
                    </span>
                  )}
                </div>
              );
            })}
            {event.attendees.length > 5 && (
              <div className={styles.attendeeMore}>+{event.attendees.length - 5} more</div>
            )}
          </div>
        </div>
      )}

      {proposals.length > 0 && (
        <div className={styles.proposals}>
          {proposals.map((att, i) => {
            const from = new Date(att.proposed_start);
            const to = att.proposed_end ? new Date(att.proposed_end) : null;
            const when = isValid(from)
              ? `${format(from, 'EEE, MMM d')} \u00b7 ${format(from, 'h:mm a')}${to && isValid(to) ? ` \u2013 ${format(to, 'h:mm a')}` : ''}`
              : '';
            return (
              <div key={att.id || att.email || i} className={styles.proposalRow}>
                <div className={styles.proposalText}>
                  <Icon name="arrow.triangle.2.circlepath" size={13} />
                  <span>
                    <strong>{att.name || att.email}</strong> proposed {when}
                  </span>
                </div>
                {att.comment && <div className={styles.proposalComment}>{att.comment}</div>}
                {canEdit && onRespondProposal && (
                  <div className={styles.proposalActions}>
                    <ToolbarButton icon="checkmark" onClick={() => onRespondProposal(event, att, 'accept')}>
                      Move to this time
                    </ToolbarButton>
                    <ToolbarButton icon="xmark" onClick={() => onRespondProposal(event, att, 'decline')}>
                      Keep current
                    </ToolbarButton>
                  </div>
                )}
              </div>
            );
          })}
        </div>
      )}

      {event.description && (
        <div className={styles.description}>
          <Linkify text={event.description} className={styles.link} />
        </div>
      )}

      {canPrep && (
        <div className={styles.prep}>
          <div className={styles.prepLabel}>
            <Icon name="scope" size={14} />
            <span>Prep zone before this</span>
          </div>
          <div className={styles.prepChoices}>
            {PREP_LEADS.map(m => (
              <ToolbarButton key={m} icon="timer" className={styles.prepChoice} iconClassName={styles.prepIcon} onClick={() => onPrepZone(event, m)}>
                {m < 60 ? `${m} min` : `${m / 60} h`}
              </ToolbarButton>
            ))}
          </div>
        </div>
      )}

      {/* No onView = a glance-only surface (the inbox calendar rail): no actions row. */}
      {onView && (
        <div className={styles.actions}>
          <ToolbarButton icon="eye" onClick={() => onView(event)}>View</ToolbarButton>
        </div>
      )}
    </Popover>
  );
}
