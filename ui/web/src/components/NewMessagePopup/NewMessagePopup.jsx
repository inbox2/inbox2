import { useState, useEffect, useCallback, useRef } from 'react';
import { createPortal } from 'react-dom';
import Icon from '../Icon';
import useDismiss from '../../hooks/useDismiss';
import { parseAddress } from '../../lib/emailAddress';
import { QUADRANTS, QUADRANT_ORDER } from '../../lib/priority';
import useNotificationStore, { DISMISS_BY_PRIORITY, expiresAt, isMeetingAlert, isZoneAlert, isCalendarAlert } from '../../stores/notificationStore';
import NotificationCard, { CardHead, CardContext, CardDetail, CardActions, ActionButton } from '../NotificationCard/NotificationCard';
import cardStyles from '../NotificationCard/NotificationCard.module.css';
import useNavigationStore from '../../stores/navigationStore';
import useUndoStore from '../../stores/undoStore';
import useUnreadStore from '../../stores/unreadStore';
import { isTauri } from '../../lib/tauri';
import { stripHtml } from '../../lib/messageText';
import { runNotificationAction, alertMailTarget, isMxAlert } from '../../lib/notificationActions';
import { CONV_ACTION } from '../../lib/conversationActions';
import relativeTime from '../../lib/relativeTime';
import { MeetingGlyph, MeetingLabel, MeetingDetail, MeetingActions, InviteActions, ZoneGlyph, ZoneDetail, ZoneActions } from '../MeetingAlert/MeetingAlert';
import { respondToAlertInvite } from '../../lib/invites';
import log from '../../lib/log';
import { ignoreMeeting, snoozeMeeting } from '../../lib/meetingAlerts';
import styles from './NewMessagePopup.module.css';

export default function NewMessagePopup() {
  const notifications = useNotificationStore(s => s.notifications);
  const dismiss = useNotificationStore(s => s.dismiss);
  const navigateTo = useNavigationStore(s => s.navigateTo);

  const openNotif = useCallback((notif) => {
    const target = notif._isMerged ? notif.items[0] : notif;
    // A notification can fire from any page (Explorer, calendar) — force the page
    // the alert is actually about.
    navigateTo(isCalendarAlert(target)
      ? { page: 'calendar' }
      : alertMailTarget(target));
    // A zone card stays until Done/✕/Escape — opening the calendar isn't an answer.
    if (!isZoneAlert(notif)) dismiss(notif._alertId);
    if (isTauri()) {
      import('@tauri-apps/api/window').then(({ getCurrentWindow }) => getCurrentWindow().setFocus());
    }
  }, [navigateTo, dismiss]);

  const handleAction = useCallback((notif, action, quadrantKey) => {
    runNotificationAction(notif, action, quadrantKey, {
      record: (entry) => useUndoStore.getState().record(entry),
      // In-app popup: same window as the badge, so write the store directly.
      onUnread: (delta) => useUnreadStore.getState().adjust(notif.accountKey, delta),
    });
    dismiss(notif._alertId);
  }, [dismiss]);

  // Global keyboard shortcuts when notifications are visible
  useEffect(() => {
    if (notifications.length === 0) return;
    const top = notifications[0];
    const handler = (e) => {
      if (e.target.tagName === 'INPUT' || e.target.tagName === 'TEXTAREA' || e.target.isContentEditable) return;
      if (isCalendarAlert(top)) {
        if (e.key === 'Escape') { e.preventDefault(); dismiss(top._alertId); }
        return;
      }
      switch (e.key) {
        case 'Escape': e.preventDefault(); dismiss(top._alertId); break;
        case 'e': case 'E': e.preventDefault(); handleAction(top, CONV_ACTION.ARCHIVE); break;
        case 'r': case 'R': e.preventDefault(); openNotif(top); break;
      }
    };
    window.addEventListener('keydown', handler);
    return () => window.removeEventListener('keydown', handler);
  }, [notifications, dismiss, handleAction, openNotif]);

  if (notifications.length === 0) return null;

  return createPortal(
    <div className={styles.container}>
      {/* Newest at the bottom, fully expanded; older cards collapse above it.
          notifications[0] is the newest, so render reversed. */}
      {notifications.slice().reverse().map((notif) => (
        notif._isMerged
          ? <MergedCard
              key={notif._alertId}
              notif={notif}
              collapsed={notif._alertId !== notifications[0]._alertId}
              onDismiss={() => dismiss(notif._alertId)}
              onOpen={() => openNotif(notif)}
            />
          : <EventCard
              key={notif._alertId}
              notif={notif}
              collapsed={notif._alertId !== notifications[0]._alertId}
              onDismiss={() => dismiss(notif._alertId)}
              onOpen={() => openNotif(notif)}
              onAction={(action, qk) => handleAction(notif, action, qk)}
            />
      ))}
    </div>,
    document.body
  );
}

/** Triage dropdown — opens above the button, card stays open. */
function TriageDropdown({ onSelect, onClose }) {
  const ref = useRef(null);
  useDismiss(ref, onClose);

  return (
    <div ref={ref} className={styles.triageDropdown}>
      {QUADRANT_ORDER.map(key => {
        const q = QUADRANTS[key];
        return (
          <button
            key={key}
            className={styles.triageItem}
            onClick={() => onSelect(key)}
          >
            <Icon name={q.icon} size={11} />
            {q.label}
          </button>
        );
      })}
      <div className={styles.triageSep} />
      <button className={styles.triageItem} onClick={() => onSelect(null)}>
        <Icon name="tag.slash" size={11} />
        Untag
      </button>
    </div>
  );
}

/** Single workflow event card. */
function EventCard({ notif, collapsed, onDismiss, onOpen, onAction }) {
  const [triageOpen, setTriageOpen] = useState(false);
  const isMeeting = isMeetingAlert(notif);
  const isZone = isZoneAlert(notif);
  // Identify by the SENDER (name • their email), not the account we received on
  // — mirrors the desktop NotificationPage card. Leading with `notif.email` (the
  // channel/mailbox) read as the alert being "from" the channel.
  const { name: sender, email: senderEmail } = parseAddress(notif.from_address);
  const context = notif.subject || '(no subject)';
  const meta = [sender, senderEmail].filter(Boolean).join(' • ');
  // Snippets arrive as raw HTML; decode to plain text and collapse whitespace.
  const snippet = stripHtml(notif.snippet || '').replace(/\s+/g, ' ').trim();
  // The rail spans the card's real lifetime: a meeting card's runs out 5 minutes
  // into the meeting, a zone card's never does (0 = static bar).
  const dismissAt = expiresAt(notif, notif.arrivedAt);
  const dismissMs = dismissAt ? Math.max(0, dismissAt - notif.arrivedAt) : 0;

  return (
    <NotificationCard
      eventColor={notif.eventColor}
      dismissMs={dismissMs}
      collapsed={collapsed}
      zone={isZone}
      onClick={(e) => { if (!e.target.closest('button') && !e.target.closest(`.${styles.triageDropdown}`)) onOpen(); }}
      role="button"
      tabIndex={0}
      onKeyDown={(e) => { if (e.key === 'Enter') onOpen(); }}
    >
      <CardHead
        glyph={isZone ? <ZoneGlyph size={14} /> : isMeeting ? <MeetingGlyph meeting={notif.meeting} size={14} /> : <span className={styles.eventDot} />}
        label={isMeeting ? <MeetingLabel notif={notif} /> : notif.eventLabel}
        time={relativeTime(notif.arrivedAt)}
        onDismiss={onDismiss}
      />

      <CardContext>{context}</CardContext>

      {isZone ? (
        <ZoneDetail notif={notif} styles={cardStyles} />
      ) : isMeeting ? (
        <MeetingDetail notif={notif} styles={cardStyles} />
      ) : (
        <CardDetail siteIcon={notif.siteIcon} meta={meta}>
          {snippet && <div className={cardStyles.snippet}>{snippet}</div>}
        </CardDetail>
      )}

      {isZone ? (
        <ZoneActions onDone={onDismiss} onOpen={onOpen} />
      ) : isMeeting ? (
        <MeetingActions
          notif={notif}
          styles={cardStyles}
          onSnooze={() => { snoozeMeeting(notif.eventId); onDismiss(); }}
          onIgnore={() => { ignoreMeeting(notif.eventId, Date.parse(notif.startAt)); onDismiss(); }}
        />
      ) : (
      <>
      {notif.invite && (
        <InviteActions
          notif={notif}
          styles={cardStyles}
          onRespond={(resp) => {
            onDismiss();
            respondToAlertInvite(notif, resp).catch((e) => log.warn('Notification', `RSVP failed: ${e?.message || e}`));
          }}
        />
      )}
      <CardActions>
        <ActionButton icon="envelope.open" onClick={() => onAction(CONV_ACTION.MARK_READ)}>Read</ActionButton>
        <ActionButton icon="archivebox" onClick={() => onAction(CONV_ACTION.ARCHIVE)}>Archive</ActionButton>
        <ActionButton icon="trash" onClick={() => onAction(CONV_ACTION.TRASH)}>Delete</ActionButton>
        {!isMxAlert(notif) && (
          <div className={styles.triageWrap}>
            <ActionButton icon="tag.fill" onClick={() => setTriageOpen(v => !v)}>Triage</ActionButton>
            {triageOpen && (
              <TriageDropdown
                onSelect={(qk) => {
                  if (qk === null) onAction('untriage');
                  else onAction('triage', qk);
                  setTriageOpen(false);
                }}
                onClose={() => setTriageOpen(false)}
              />
            )}
          </div>
        )}
      </CardActions>
      </>
      )}
    </NotificationCard>
  );
}

/** Merged same-thread card. */
function MergedCard({ notif, collapsed, onDismiss, onOpen }) {
  const dismissMs = DISMISS_BY_PRIORITY[notif.priority] || DISMISS_BY_PRIORITY.normal;

  return (
    <NotificationCard
      eventColor={notif.eventColor}
      dismissMs={dismissMs}
      collapsed={collapsed}
      className={styles.merged}
      onClick={(e) => { if (!e.target.closest('button')) onOpen(); }}
      role="button"
      tabIndex={0}
      onKeyDown={(e) => { if (e.key === 'Enter') onOpen(); }}
    >
      <CardHead
        glyph={<span className={styles.eventDot} />}
        label={`${notif.count} new replies`}
        onDismiss={(e) => { e.stopPropagation(); onDismiss(); }}
      />

      <div className={cardStyles.detail}>
        <ul className={styles.stackList}>
          {notif.items.slice(0, 4).map((item, i) => (
            <li key={item._alertId || i} className={styles.stackItem}>
              {item.subject || '(no subject)'}
            </li>
          ))}
          {notif.count > 4 && (
            <li className={styles.stackMore}>+{notif.count - 4} more</li>
          )}
        </ul>
      </div>

      <div className={styles.stackAction}>
        <span>Open thread</span>
        <Icon name="chevron.right" size={10} />
      </div>
    </NotificationCard>
  );
}
