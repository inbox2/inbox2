/**
 * NotificationPage — standalone page for the Tauri external notification window.
 *
 * Holds a *stack* of notifications (newest on top, max MAX_VISIBLE). Each
 * `notification-show` event pushes a new card; cards auto-dismiss per priority
 * and on manual action. The OS window auto-resizes to fit the stack and hides
 * itself when the stack empties — the window itself is a persistent
 * non-activating NSPanel (created once, hidden between alerts), so removing a
 * card never tears down the webview. That's what lets button actions run
 * fire-and-forget: the card disappears instantly while the provider IPC settles
 * in the still-alive webview.
 *
 * Light frosted-glass styling, fixed regardless of the app theme.
 */
import { ALERT_REMOVE_EVENT, alertMatches } from '../../lib/alertDismiss';
import { useState, useEffect, useCallback, useRef } from 'react';
import { parseAddress } from '../../lib/emailAddress';
import { stripHtml } from '../../lib/messageText';
import { getEventMeta, expiresAt, isMeetingAlert, isZoneAlert, isCalendarAlert, keepVisible } from '../../stores/notificationStore';
import NotificationCard, { CardHead, CardContext, CardDetail, CardActions, ActionButton } from '../../components/NotificationCard/NotificationCard';
import cardStyles from '../../components/NotificationCard/NotificationCard.module.css';
import { runNotificationAction } from '../../lib/notificationActions';
import { openLink } from '../../lib/openLink';
import { CONV_ACTION } from '../../lib/conversationActions';
import relativeTime from '../../lib/relativeTime';
import { MeetingGlyph, MeetingLabel, MeetingDetail, MeetingActions, InviteActions, ZoneGlyph, ZoneDetail, ZoneActions } from '../../components/MeetingAlert/MeetingAlert';
import { respondToAlertInvite } from '../../lib/invites';
import { copyText, codeForClipboard } from '../../lib/otp';
import { PROVIDER, providerIcon } from '../../lib/providerTypes';
import log from '../../lib/log';
import styles from './NotificationPage.module.css';
import mtg from '../../components/MeetingAlert/MeetingAlert.module.css';

// Stack depth + window geometry. WINDOW_W / WINDOW_PAD must agree with the
// creator in useNewMessageNotifications.js (it positions the window top-right
// using the same width). Card width = WINDOW_W - 2 * WINDOW_PAD.
const MAX_VISIBLE = 4;
const WINDOW_W = 436;
const WINDOW_PAD = 16;

let idSeq = 0;

// This panel is its own Tauri window with its own module instances, so neither
// the unread badge nor the reminder tick lives here. Both are handed to the main
// window over the same emitTo channel handleView already uses to navigate.
const snoozeFromPanel = (eventId) => {
  import('@tauri-apps/api/event')
    .then(({ emitTo }) => emitTo('main', 'meeting-snooze', { eventId }))
    .catch(() => { /* not in Tauri */ });
};

const ignoreFromPanel = (eventId, startMs) => {
  import('@tauri-apps/api/event')
    .then(({ emitTo }) => emitTo('main', 'meeting-ignore', { eventId, startMs }))
    .catch(() => { /* not in Tauri */ });
};

// A zone card clicked away: the main window owns the "dismissed" record (this
// webview has its own module instances), so hand it back like snooze/ignore.
const zoneDismissFromPanel = (notif) => {
  import('@tauri-apps/api/event')
    .then(({ emitTo }) => emitTo('main', 'zone-dismiss', { zoneId: notif.zoneId, endAt: notif.endAt }))
    .catch(() => { /* not in Tauri */ });
};

const notifyUnread = (notif) => (delta) => {
  import('@tauri-apps/api/event')
    .then(({ emitTo }) => emitTo('main', 'unread-adjust', { key: notif.accountKey, delta }))
    .catch(() => { /* not in Tauri */ });
};

function deriveEventType(n) {
  return n.eventType || 'new_message';
}

function makeEntry(message) {
  return { ...message, _id: ++idSeq, shownAt: Date.now() };
}

// Seed the stack from the URL. Tauri passes one card this way when it creates
// the window; an array is accepted too so the stacked state can be opened
// directly in a browser (website/scripts/uishots.mjs shoots the marketing
// screenshots of these cards that way).
function readHashData() {
  const hash = window.location.hash;
  if (hash.startsWith('#data=')) {
    try {
      const parsed = JSON.parse(decodeURIComponent(hash.slice(6)));
      return (Array.isArray(parsed) ? parsed : [parsed]).map(makeEntry);
    } catch { /* malformed */ }
  }
  return [];
}

// Lazily-loaded Tauri window/dpi modules, memoized for the lifetime of the page.
let winMods = null;
async function getWinMods() {
  if (!winMods) {
    const [win, dpi] = await Promise.all([
      import('@tauri-apps/api/window'),
      import('@tauri-apps/api/dpi'),
    ]);
    winMods = { getCurrentWindow: win.getCurrentWindow, LogicalSize: dpi.LogicalSize };
  }
  return winMods;
}

// Where a sign-in link goes, without the scheme, query or fragment (the token's usual home).
function linkShown(otp) {
  try {
    const u = new URL(otp.link);
    return `${u.host}${u.pathname === '/' ? '' : u.pathname}`;
  } catch {
    return otp.host || '';
  }
}

export default function NotificationPage() {
  const [notifications, setNotifications] = useState(readHashData);
  const [flushing, setFlushing] = useState(false);
  const stackRef = useRef(null);

  const removeCard = useCallback((id) => {
    setNotifications((list) => list.filter((n) => n._id !== id));
  }, []);

  const addCard = useCallback((message) => {
    setNotifications((list) => {
      // Dedup by conversation key so a re-emit doesn't double-stack.
      if (message.key && list.some((n) => n.key === message.key)) return list;
      return keepVisible([makeEntry(message), ...list], MAX_VISIBLE);
    });
  }, []);

  const handleView = useCallback(async (notif) => {
    try {
      const { emitTo } = await import('@tauri-apps/api/event');
      await emitTo('main', 'notification-navigate', {
        page: isCalendarAlert(notif) ? 'calendar' : 'mail',
        accountKey: notif.accountKey,
        conversationId: notif.key,
        providerType: notif.providerType,
        orgSlug: notif.orgSlug,
      });
    } catch { /* not in Tauri */ }
    // Opening a card flings the stack out to the right, then clears it (and
    // hides the window if nothing is left). Zone cards stay: only Done, ✕,
    // Escape or a swipe takes one down.
    setFlushing(true);
    setTimeout(() => { setNotifications((list) => list.filter(isZoneAlert)); setFlushing(false); }, FLING_MS);
  }, []);

  // New alerts pushed into this persistent window.
  useEffect(() => {
    let unlisten;
    (async () => {
      const { listen } = await import('@tauri-apps/api/event');
      unlisten = await listen('notification-show', (event) => addCard(event.payload));
    })();
    return () => { if (unlisten) unlisten(); };
  }, [addCard]);

  // Its thread was deleted/archived elsewhere (lib/alertDismiss.js): the card
  // would offer actions on mail that's already gone, so it closes at once.
  useEffect(() => {
    let unlisten;
    let disposed = false;
    (async () => {
      const { listen } = await import('@tauri-apps/api/event');
      const fn = await listen(ALERT_REMOVE_EVENT, (event) => {
        const keys = new Set(event.payload?.keys || []);
        setNotifications((list) => list.filter((n) => !alertMatches(n, keys)));
      });
      if (disposed) fn(); else unlisten = fn;
    })();
    return () => { disposed = true; if (unlisten) unlisten(); };
  }, []);

  // A zone card clicked away on another device (docs/Calendar.md "Zones"):
  // drop it quietly — no zone-dismiss back, the main window already knows.
  useEffect(() => {
    let unlisten;
    let disposed = false;
    (async () => {
      const { listen } = await import('@tauri-apps/api/event');
      const fn = await listen('zone-card-remove', (event) => {
        const zoneId = event.payload?.zoneId;
        setNotifications((list) => list.filter((n) => !(isZoneAlert(n) && n.zoneId === zoneId)));
      });
      if (disposed) fn(); else unlisten = fn;
    })();
    return () => { disposed = true; if (unlisten) unlisten(); };
  }, []);

  useEffect(() => {
    document.documentElement.style.setProperty('background', 'transparent');
    document.body.style.setProperty('background', 'transparent');
  }, []);

  // Auto-resize the OS window to fit the stack. A single long-lived
  // ResizeObserver re-measures on *any* content change — cards added/removed,
  // snippets wrapping, late font layout — so the window always grows to show
  // the whole stack (no clipped bottom, no cards hidden below the edge).
  // offsetHeight is the unscaled layout height (ignores the entry transform).
  useEffect(() => {
    const el = stackRef.current;
    if (!el) return undefined;
    let disposed = false;
    let ro;
    (async () => {
      const { getCurrentWindow, LogicalSize } = await getWinMods();
      if (disposed) return;
      const win = getCurrentWindow();
      const apply = () => {
        const h = el.offsetHeight;
        if (h <= 0) return; // empty — the hide effect takes over
        win.setSize(new LogicalSize(WINDOW_W, h + WINDOW_PAD * 2)).catch(() => {});
      };
      apply();
      ro = new ResizeObserver(apply);
      ro.observe(el);
    })();
    return () => { disposed = true; if (ro) ro.disconnect(); };
  }, []);

  // Hide the window when the stack empties (the persistent NSPanel is reused).
  // Also tell the main window the panel is gone, so it can restore anything it
  // stepped aside (the in-app browser webview, which would composite over us).
  useEffect(() => {
    if (notifications.length > 0) return;
    (async () => {
      try {
        const { emitTo } = await import('@tauri-apps/api/event');
        await emitTo('main', 'notification-hidden', {});
      } catch { /* best effort */ }
      try {
        const { getCurrentWindow } = await getWinMods();
        await getCurrentWindow().hide();
      } catch (e) {
        log.warn('Notification', `Hide window failed: ${e?.message || e}`);
      }
    })();
  }, [notifications.length]);

  // Keyboard shortcuts act on the top (newest) card.
  useEffect(() => {
    const handler = (e) => {
      const top = notifications[0];
      if (!top) return;
      if (e.key === 'Escape') {
        if (isZoneAlert(top)) zoneDismissFromPanel(top);
        removeCard(top._id);
      }
      else if (isZoneAlert(top)) { /* Done / Escape only */ }
      else if (isMeetingAlert(top)) {
        // Archive/delete are meaningless here; r = the one thing you want.
        if ((e.key === 'r' || e.key === 'R') && top.meeting?.url) openLink(top.meeting.url);
      }
      else if (e.key === 'e' || e.key === 'E') {
        removeCard(top._id);
        runNotificationAction(top, CONV_ACTION.ARCHIVE, null, { onUnread: notifyUnread(top) });
      }
      else if (e.key === 'r' || e.key === 'R') handleView(top);
    };
    window.addEventListener('keydown', handler);
    return () => window.removeEventListener('keydown', handler);
  }, [notifications, removeCard, handleView]);

  return (
    <div className={styles.root}>
      <div className={styles.stack} ref={stackRef}>
        {/* Newest at the bottom, fully expanded; older cards collapse above it
            to just their title + action buttons. notifications[0] is the newest
            (addCard prepends), so render reversed. */}
        {notifications.slice().reverse().map((notif) => (
          <NotifCard
            key={notif._id}
            notif={notif}
            collapsed={notif._id !== notifications[0]._id}
            flushing={flushing && !isZoneAlert(notif)}
            onRemove={removeCard}
            onView={handleView}
          />
        ))}
      </div>
    </div>
  );
}

// Horizontal drag past this many px (rightward) flings the card away; anything
// less snaps back. Movement under TAP_SLOP is treated as a tap (open message),
// not a drag, so the whole text area stays clickable.
const SWIPE_THRESHOLD = 96;
const TAP_SLOP = 5;
const FLING_MS = 180;

function NotifCard({ notif, collapsed, flushing, onRemove, onView }) {
  const eventType = deriveEventType(notif);
  const meta = getEventMeta(eventType);
  const isMeeting = isMeetingAlert(notif);
  const isZone = isZoneAlert(notif);
  // A zone card is only ever clicked away by hand — every way off the screen
  // records that, so it doesn't come back on the next tick.
  const remove = useCallback(() => {
    if (isZone) zoneDismissFromPanel(notif);
    onRemove(notif._id);
  }, [isZone, notif, onRemove]);
  // A meeting card stays up counting down, so its label ("Meeting in 9 minutes"
  // → "Starting now") is kept live rather than frozen at the moment it fired.
  const label = isMeeting ? <MeetingLabel notif={notif} /> : (notif.eventLabel || meta.label);
  const priority = notif.priority || meta.priority;
  const { name: sender, email: senderEmail } = parseAddress(notif.from_address);
  const context = notif.subject || '(no subject)';
  // Show the *sender's* address (name • their email), not the account we
  // received on.
  const metaLine = [sender, senderEmail].filter(Boolean).join(' • ');
  const channelIcon = notif.channelIconUrl || providerIcon(notif.providerType);
  // The generic IMAP glyph is white (for the app's dark surfaces); invert it to
  // dark so it stays legible on the light frosted-glass notification card. It's
  // also the fallback for an unknown provider type.
  const channelIconDark = channelIcon === providerIcon(PROVIDER.IMAP);
  // Snippets arrive as raw HTML; decode to plain text and collapse whitespace
  // so the two-line clamp reads cleanly.
  const snippet = stripHtml(notif.snippet || '').replace(/\s+/g, ' ').trim();
  // When this card goes away on its own (null = stays until touched). A meeting
  // card stays until touched or 5 minutes past the start, so one that fired while
  // the lid was shut isn't still shouting "Starting now" hours later.
  const dismissAt = expiresAt({ ...notif, priority }, notif.shownAt);
  const dismissMs = dismissAt ? Math.max(0, dismissAt - notif.shownAt) : 0;

  const cardRef = useRef(null);
  const textRef = useRef(null);
  const actionsRef = useRef(null);
  const dragRef = useRef({ active: false, startX: 0, dx: 0, moved: false, target: null });

  // Per-card auto-dismiss. Ticks against the wall clock instead of sleeping on
  // one long delay — JS timers stall while the machine is asleep, so an expiry
  // that passed with the lid shut is only caught by re-comparing clocks on wake.
  useEffect(() => {
    if (!dismissAt) return undefined;
    const t = setInterval(() => { if (Date.now() >= dismissAt) onRemove(notif._id); }, 1000);
    return () => clearInterval(t);
  }, [dismissAt, notif._id, onRemove]);

  // Optimistic: drop the card immediately, then fire the action. The webview
  // persists (only hidden when the stack empties), so the async IPC isn't
  // aborted — no more second-long wait before the card disappears.
  const act = useCallback((action, quadrantKey) => {
    onRemove(notif._id);
    runNotificationAction(notif, action, quadrantKey, { onUnread: notifyUnread(notif) });
  }, [notif, onRemove]);

  // ── Swipe-right-to-dismiss (macOS-style) + tap-anywhere-to-open ──
  // A single pointer gesture drives both: small movement = tap (open the
  // message if it started in the text area); a rightward drag past the
  // threshold flings the card off-screen and removes it.
  const onPointerDown = useCallback((e) => {
    if (e.button !== 0 || e.target.closest('button')) return; // let buttons act
    const d = dragRef.current;
    d.active = true;
    d.startX = e.clientX;
    d.dx = 0;
    d.moved = false;
    d.target = e.target;
    const el = cardRef.current;
    if (el) {
      el.style.transition = 'none';
      el.setPointerCapture?.(e.pointerId);
    }
  }, []);

  const onPointerMove = useCallback((e) => {
    const d = dragRef.current;
    if (!d.active) return;
    d.dx = e.clientX - d.startX;
    if (Math.abs(d.dx) > TAP_SLOP) d.moved = true;
    const el = cardRef.current;
    if (!el) return;
    // Rightward only; a little rubber-band resistance the other way.
    const x = d.dx >= 0 ? d.dx : d.dx * 0.25;
    el.style.transform = `translateX(${x}px)`;
    el.style.opacity = String(Math.max(0, 1 - Math.max(0, x) / (SWIPE_THRESHOLD * 2.2)));
  }, []);

  const settle = useCallback((e) => {
    const d = dragRef.current;
    if (!d.active) return;
    d.active = false;
    const el = cardRef.current;
    if (el) el.releasePointerCapture?.(e.pointerId);
    if (!el) return;

    if (d.dx > SWIPE_THRESHOLD) {
      // Fling off to the right, then remove once the slide completes.
      el.style.transition = `transform ${FLING_MS}ms var(--ease-in, ease-in), opacity ${FLING_MS}ms linear`;
      el.style.transform = `translateX(${el.offsetWidth + 48}px)`;
      el.style.opacity = '0';
      setTimeout(remove, FLING_MS - 10);
      return;
    }

    // Not a dismiss. Either a tap (open) or a short drag (snap back). The whole
    // card opens the message — header, subject, sender, snippet, and the padding
    // and gaps around them — so there are no dead zones between the text and the
    // card edge. Only the action-button row is excluded (its buttons run their
    // own onClick, and a tap on the row's gaps/padding must not open the thread).
    if (!d.moved && !actionsRef.current?.contains(d.target)) {
      el.style.transition = '';
      el.style.transform = '';
      el.style.opacity = '';
      onView(notif);
      return;
    }
    // Snap back into place.
    el.style.transition = 'transform 0.2s var(--ease-out, ease-out), opacity 0.2s linear';
    el.style.transform = '';
    el.style.opacity = '';
  }, [notif, remove, onView]);

  // The meeting/zone helpers render the shared action row; the page's own
  // "not an open target" cursor rides along.
  const actionStyles = { ...cardStyles, actions: `${cardStyles.actions} ${styles.actionsRow}` };

  return (
    <NotificationCard
      eventColor={notif.eventColor || meta.color}
      dismissMs={dismissMs}
      collapsed={collapsed}
      zone={isZone}
      className={`${styles.swipe} ${flushing ? styles.flung : ''}`}
      cardRef={cardRef}
      onPointerDown={onPointerDown}
      onPointerMove={onPointerMove}
      onPointerUp={settle}
      onPointerCancel={settle}
    >
      {/* Whole text region is one click target — tap anywhere here (header,
          subject, sender, snippet) to open the message. The dismiss button
          sits inside but stops propagation via the button guard above. */}
      <div
        className={styles.clickable}
        ref={textRef}
        role="button"
        tabIndex={0}
        onKeyDown={(e) => { if (e.key === 'Enter') onView(notif); }}
      >
        <CardHead
          glyph={isZone ? (
            <ZoneGlyph />
          ) : isMeeting ? (
            <MeetingGlyph meeting={notif.meeting} />
          ) : (
            <img
              className={`${styles.channelIcon} ${channelIconDark ? styles.channelIconDark : ''}`}
              src={channelIcon}
              alt=""
              width={16}
              height={16}
            />
          )}
          label={label}
          time={relativeTime(notif.updated_at)}
          onDismiss={remove}
        />

        <CardContext>{context}</CardContext>

        {isZone ? (
          <ZoneDetail notif={notif} styles={cardStyles} />
        ) : isMeeting ? (
          <MeetingDetail notif={notif} styles={cardStyles} />
        ) : (
          <CardDetail siteIcon={notif.siteIcon} meta={metaLine} className={styles.detailShort}>
            {notif.otp ? (
              <div className={styles.otpRow}>
                {notif.otp.code
                  ? <span className={styles.otpCode}>{notif.otp.code}</span>
                  : (
                    <span className={styles.otpHost}>
                      Opens
                      {/* Host and path only: a sign-in link's one-time token lives in the query
                          (or fragment), so neither is shown. CSS cuts a long one with an ellipsis. */}
                      <code className={styles.otpUrl} title={linkShown(notif.otp)}>{linkShown(notif.otp)}</code>
                    </span>
                  )}
              </div>
            ) : snippet && <div className={cardStyles.snippet}>{snippet}</div>}
          </CardDetail>
        )}
      </div>

      {isZone ? (
        <div ref={actionsRef}>
          <ZoneActions onDone={remove} onOpen={() => onView(notif)} />
        </div>
      ) : isMeeting ? (
        <div ref={actionsRef}>
          <MeetingActions
            notif={notif}
            styles={actionStyles}
            onSnooze={() => { onRemove(notif._id); snoozeFromPanel(notif.eventId); }}
            onIgnore={() => { onRemove(notif._id); ignoreFromPanel(notif.eventId, Date.parse(notif.startAt)); }}
          />
        </div>
      ) : (
      <div ref={actionsRef}>
      {notif.invite && (
        <InviteActions
          notif={notif}
          styles={actionStyles}
          onRespond={(resp) => {
            // Same optimistic shape as `act`: drop the card now, let the RSVP
            // settle in the (still-alive) webview.
            onRemove(notif._id);
            respondToAlertInvite(notif, resp).catch((e) => log.warn('Notification', `RSVP failed: ${e?.message || e}`));
          }}
        />
      )}
      {notif.otp ? (
      <CardActions className={styles.actionsRow}>
        {notif.otp.code ? (
          <ActionButton
            icon="doc.on.doc"
            className={mtg.join}
            onClick={() => {
              // Copied, so the mail has done its job: it goes to the trash.
              copyText(codeForClipboard(notif.otp.code))
                .then(() => act(CONV_ACTION.TRASH))
                .catch((e) => log.warn('Notification', `copy failed: ${e?.message || e}`));
            }}
          >
            Copy &amp; delete
          </ActionButton>
        ) : (
          <ActionButton
            icon="arrow.up.right"
            className={mtg.join}
            onClick={() => {
              // Trash only once the browser has it; a failed open keeps the mail.
              openLink(notif.otp.link).then((ok) => { if (ok) act(CONV_ACTION.TRASH); });
            }}
          >
            Open &amp; delete
          </ActionButton>
        )}
        <ActionButton icon="archivebox" onClick={() => act(CONV_ACTION.ARCHIVE)}>Archive</ActionButton>
        <ActionButton icon="trash" onClick={() => act(CONV_ACTION.TRASH)}>Delete</ActionButton>
      </CardActions>
      ) : (
      <CardActions className={styles.actionsRow}>
        <ActionButton icon="envelope.open" onClick={() => act(CONV_ACTION.MARK_READ)}>Read</ActionButton>
        <ActionButton icon="archivebox" onClick={() => act(CONV_ACTION.ARCHIVE)}>Archive</ActionButton>
        <ActionButton icon="trash" onClick={() => act(CONV_ACTION.TRASH)}>Delete</ActionButton>
        <ActionButton icon="arrowshape.turn.up.left" onClick={() => onView(notif)}>Reply</ActionButton>
      </CardActions>
      )}
      </div>
      )}
    </NotificationCard>
  );
}
