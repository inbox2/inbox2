// The meeting half of a notification card. The mail card and the meeting card
// share one surface — the frosted-glass window on desktop, the in-app popup in
// the browser — so these pieces take that surface's CSS module and slot into it,
// rather than growing a third card component that would drift from both.
import { useEffect, useState } from 'react';
import Icon from '../Icon';
import MeetingProviderIcon from '../MeetingProviderIcon/MeetingProviderIcon';
import { detectMeetingProvider } from '../MeetingProviderIcon/meetingProvider';
import { openLink } from '../../lib/openLink';
import { formatWhen } from '../../lib/invites';
import { progress, remaining } from '../../lib/zones';
import { minutesLabel } from '../../lib/meetingAlerts';
import mtg from './MeetingAlert.module.css';

/** The wall clock, re-read every second — drives the cards' live countdowns. */
function useNow() {
  const [now, setNow] = useState(() => Date.now());
  useEffect(() => {
    const t = setInterval(() => setNow(Date.now()), 1000);
    return () => clearInterval(t);
  }, []);
  return now;
}

/**
 * The card head's "Meeting in 9 minutes" → "Starting now", kept current: the
 * card stays up until clicked away, so the label it fired with goes stale.
 */
export function MeetingLabel({ notif }) {
  return minutesLabel(new Date(notif.startAt), useNow());
}

/** Brand mark for the call, or a plain calendar glyph when there's no link. */
export function MeetingGlyph({ meeting, size = 16 }) {
  if (meeting?.provider) return <MeetingProviderIcon provider={meeting.provider} size={size} />;
  return <Icon name="calendar" size={size - 2} />;
}

/** Countdown to the start + where, in place of the mail card's sender + snippet. */
export function MeetingDetail({ notif, styles }) {
  const now = useNow();
  const started = now >= Date.parse(notif.startAt);
  // A conference URL as the "location" is noise — the time line already names
  // the provider and the button already opens it.
  const place = notif.meeting && notif.location === notif.meeting.url ? null : notif.location;
  const line = [place, notif.organizerName, notif.attendeeSummary].filter(Boolean).join(' · ');
  return (
    <div className={styles.detail}>
      <div className={`${mtg.zoneClock} ${mtg.meetClock}`}>
        <span className={mtg.zoneRemaining}>{started ? 'Started' : remaining({ end_at: notif.startAt }, now, { withSeconds: true })}</span>
        <span className={mtg.zoneUntil}>{started ? notif.timeLine : `to start · ${notif.timeLine}`}</span>
      </div>
      {line && <div className={styles.snippet}>{line}</div>}
    </div>
  );
}

/**
 * THE Join button: the blue primary with the provider's own mark. One component
 * so the alert cards and the menu bar popover can't drift into two looks.
 * `className` is the host surface's button class (size, radius); `onJoined`
 * runs after the link opens (the popover closes itself).
 *
 * `tone`: the alert cards are a fixed light-glass surface, so their Join is a
 * fixed blue ('alert'). A surface that follows the app theme passes 'theme' and
 * gets the theme's primary button — the same fill as the calendar's event popup
 * (violet on Warm, bronze on Dark, …), so the two Joins on screen match.
 */
export function JoinButton({ meeting, title, className = '', tone = 'alert', onJoined }) {
  return (
    <button
      type="button"
      className={`${className} ${tone === 'theme' ? mtg.joinThemed : mtg.join}`}
      aria-label={title ? `Join ${meeting.label}: ${title}` : undefined}
      onClick={() => { openLink(meeting.url); onJoined?.(); }}
    >
      <MeetingGlyph meeting={meeting} size={13} />
      Join
    </button>
  );
}

/**
 * Join / Snooze. Join is the whole point of the alert, so it leads and carries
 * the provider's own mark; an event with no link (a room booking, lunch) simply
 * doesn't get the button rather than getting a dead one. No Open button —
 * clicking the card itself already opens the event.
 */
export function MeetingActions({ notif, styles, onSnooze, onIgnore }) {
  const url = notif.meeting?.url;
  return (
    <div className={styles.actions}>
      {url && <JoinButton meeting={notif.meeting} className={styles.actionBtn} />}
      <button className={styles.actionBtn} onClick={onSnooze}>
        <Icon name="clock.arrow.circlepath" size={12} />
        Snooze 5m
      </button>
      <button className={styles.actionBtn} onClick={onIgnore}>
        <Icon name="nosign" size={12} />
        Ignore
      </button>
    </div>
  );
}

/**
 * The invite half of a *mail* card: a meeting invitation just landed, so the
 * card carries the answer above its ordinary Read/Archive row. Borrows the
 * meeting reminder's look (brand mark, time line, primary button) so an invite
 * reads as calendar, not mail, at a glance. Tentative is deliberately left to
 * the reader's banner — a card that auto-dismisses gets the two answers people
 * actually give from a notification.
 */
export function InviteActions({ notif, styles, onRespond }) {
  const invite = notif.invite;
  const provider = detectMeetingProvider(invite.location, invite.description, invite.summary);
  const when = formatWhen(invite);
  return (
    <div className={mtg.invite}>
      <div className={mtg.inviteWhen}>
        {provider ? <MeetingProviderIcon provider={provider} size={14} /> : <Icon name="calendar" size={13} />}
        <span>{when || invite.summary || 'Meeting invitation'}</span>
      </div>
      <div className={styles.actions}>
        <button className={`${styles.actionBtn} ${mtg.join}`} onClick={() => onRespond('accepted')}>
          <Icon name="checkmark" size={12} />
          Accept
        </button>
        <button className={styles.actionBtn} onClick={() => onRespond('declined')}>
          <Icon name="xmark" size={12} />
          Decline
        </button>
      </div>
    </div>
  );
}

// ── Calendar zones (docs/Calendar.md "Zones") ───────
// The zone-start card rides the same two surfaces as a meeting reminder; these
// are its pieces. It never auto-dismisses — the card is the reminder.

/** The zone mark, tinted with the zone's category colour (the card's rail). */
export function ZoneGlyph({ size = 16 }) {
  return <span className={mtg.zoneGlyph}><Icon name="scope" size={size - 2} /></span>;
}

/** Note + a live countdown and progress bar for the time left in the zone. */
export function ZoneDetail({ notif, styles }) {
  const now = useNow();
  const zone = { start_at: notif.startAt, end_at: notif.endAt };
  const over = now >= Date.parse(notif.endAt);
  return (
    <div className={`${styles.detail} ${mtg.zoneDetail}`}>
      <img className={mtg.zoneArt} src="/images/zone-focus.png" alt="" width={52} height={52} draggable={false} />
      <div className={mtg.zoneMain}>
      {notif.note && <div className={mtg.zoneNote}>{notif.note}</div>}
      <div className={mtg.zoneClock}>
        <span className={mtg.zoneRemaining}>{over ? 'Zone ended' : remaining(zone, now, { withSeconds: true })}</span>
        <span className={mtg.zoneUntil}>{over ? notif.timeLine : `left · ${notif.timeLine}`}</span>
      </div>
      <div className={mtg.zoneTrack}>
        <div className={mtg.zoneFill} ref={(el) => el?.style.setProperty('--zone-progress', `${Math.round(progress(zone, now) * 100)}%`)} />
      </div>
      </div>
    </div>
  );
}

/**
 * Done (clicks the card away for good) / Open calendar — quiet text links, not
 * buttons: the card is there to keep you in the zone, not to be clicked off.
 */
export function ZoneActions({ onDone, onOpen }) {
  return (
    <div className={mtg.zoneLinks}>
      <button type="button" className={mtg.zoneLink} onClick={onDone}>
        <Icon name="checkmark" size={11} />Done
      </button>
      <button type="button" className={mtg.zoneLink} onClick={onOpen}>
        <Icon name="calendar" size={11} />Open calendar
      </button>
    </div>
  );
}
