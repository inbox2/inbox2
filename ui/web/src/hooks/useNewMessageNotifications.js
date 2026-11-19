import { useEffect, useRef } from 'react';
import { useNavigate } from 'react-router';
import syncManager from '../lib/sync-manager';
import useNotificationStore from '../stores/notificationStore';
import useNavigationStore from '../stores/navigationStore';
import useAccountStore from '../stores/accountStore';
import { playPing } from '../lib/notificationSound';
import { getNotificationPref, NOTIFICATION_MODES } from '../lib/notificationPref';
import { showSystemNotification } from '../lib/systemNotification';
import { inviteForAlert } from '../lib/invites';
import { siteIconUrl, fetchSiteIcon } from '../lib/otp';
import { avatarDataUrl } from '../lib/avatar';
import { parseAddress } from '../lib/emailAddress';
import { alertMailTarget } from '../lib/notificationActions';
import log from '../lib/log';
import { isTauri, popupWindowsSupported } from '../lib/tauri';
import { isDemoMode } from '../lib/demoData';
import useCalendarStore, { CALENDAR_VIEW } from '../stores/calendarStore';

/**
 * useNewMessageNotifications — global hook that subscribes to SyncManager's
 * 'new-message' event and:
 *   1. Shows a notification (external Tauri window, or in-app popup for browser)
 *   2. Fires a system notification (Notification API — browser fallback)
 *   3. Plays the notification sound
 *
 * The sync engine only emits 'new-message' for genuinely-new inbound mail, so
 * this is the single source of truth for new-message alerts (and the only place
 * the ping is played).
 *
 * Mount once at the app root level.
 */
export default function useNewMessageNotifications() {
  const show = useNotificationStore(s => s.show);
  const record = useNotificationStore(s => s.record);
  const navigateTo = useNavigationStore(s => s.navigateTo);
  const navigate = useNavigate();
  const permissionAsked = useRef(false);

  // Listen for navigation requests from the external notification window
  useEffect(() => {
    if (!isTauri()) return;
    let unlisten;
    (async () => {
      const { listen } = await import('@tauri-apps/api/event');
      unlisten = await listen('notification-navigate', async (event) => {
        const { accountKey, conversationId, page, date, eventId, providerType, orgSlug: alertSlug } = event.payload;
        // The menu bar popover opens the calendar on the day that was clicked, in
        // day view — a click on the 24th means "show me the 24th", not its week.
        if (page === 'calendar' && date) {
          const cal = useCalendarStore.getState();
          cal.setCurrentDate(new Date(date));
          cal.setView(CALENDAR_VIEW.DAY);
        }
        // A notification can fire from any page (Explorer, calendar), so the card
        // names the page it wants rather than inheriting wherever we happen to be.
        // A specific meeting: the calendar's :eventId deep link opens its detail
        // popup once the day's events load (same route the invite banner uses).
        const orgSlug = useNavigationStore.getState().orgSlug;
        if (page === 'calendar' && eventId && orgSlug) {
          navigate(`/${orgSlug}/calendar/${encodeURIComponent(eventId)}`);
        } else {
          navigateTo(page === 'calendar'
            ? { page: 'calendar' }
            : alertMailTarget({ key: conversationId, accountKey, providerType, orgSlug: alertSlug }));
        }
        // Raise the main window. setFocus() alone won't bring a backgrounded or
        // minimized window forward (on macOS or Windows), so unminimize + show
        // first. All three are cross-platform Tauri window APIs.
        try {
          const { getCurrentWindow } = await import('@tauri-apps/api/window');
          const win = getCurrentWindow();
          if (await win.isMinimized()) await win.unminimize();
          await win.show();
          await win.setFocus();
        } catch (e) {
          log.warn('Notification', `Focus main window failed: ${e?.message || e}`);
        }
      });
    })();
    return () => { if (unlisten) unlisten(); };
  }, [navigateTo, navigate]);

  // Main event listener
  useEffect(() => {
    // Request browser notification permission (fallback for non-Tauri)
    if (!isTauri() && !permissionAsked.current && 'Notification' in window && Notification.permission === 'default') {
      permissionAsked.current = true;
      Notification.requestPermission();
    }

    const unsub = syncManager.on('new-message', async (rawMessage) => {
      // Tag the alert with the channel it arrived on so the popup can show the
      // provider icon (Gmail/Outlook/IMAP/…). The notification window is a
      // separate webview without the account store, so we resolve it here (where
      // the store is populated) and pass it along in the payload.
      const acct = useAccountStore.getState().externalAccounts.find(a => a.key === rawMessage.accountKey);
      const message = {
        ...rawMessage,
        providerType: rawMessage.providerType || acct?.provider_type,
        channelIconUrl: rawMessage.channelIconUrl || acct?.icon_url,
        // Demo mode lives in this window's sessionStorage; the Tauri notification
        // window can't see it, so the card carries it (runNotificationAction).
        demo: isDemoMode(),
      };
      // Honor the user's notification preferences (Settings → Preferences →
      // Notifications). Sound is gated independently of the alert mode; the
      // in-app activity feed (record) is always kept regardless of mode.
      const { mode } = getNotificationPref();
      // Trace every delivered alert + the mode that routed it, so misfires (e.g.
      // sent items raising alerts) can be reconstructed from desktop logs. The
      // engine logs the cause (folder role / from_is_self); this logs delivery.
      log.info(
        'Notification',
        `new-message: mode=${mode} from=${message?.from_address || '?'} subject=${JSON.stringify(message?.subject)} key=${message?.key} account=${message?.email || message?.accountKey}`,
      );
      // Sound choice + master enable live in Settings → Sounds; playPing self-gates.
      playPing();

      // A meeting invitation gets answered from the card itself, so it has to be
      // recognised before the card is built. Costs two provider calls, gated on
      // the engine's hasAttachment flag and time-boxed (lib/invites.js), so
      // ordinary mail is unaffected and a slow probe just loses the buttons.
      const invite = await inviteForAlert(message);
      // Always overwrite: an MX alert arrives with its raw invite, and a PUBLISH
      // (booking confirmation) must not keep Accept/Decline on the card.
      message.invite = invite;
      if (invite) {
        message.eventLabel = 'Meeting invitation';
        // Amber rail + the longer dwell of a meeting alert: an invite you can
        // answer is worth more than the 8 seconds ordinary mail gets.
        message.eventColor = 'meeting';
        message.priority = 'high';
      } else if (message.otp) {
        message.eventLabel = message.otp.code ? 'Sign-in code' : 'Sign-in link';
        // A code takes a moment to type into the other app; give it the longer dwell.
        message.priority = 'high';
      }
      // Shown large on the card: the sender's face (Meta DMs), a sign-in link's
      // site, else the sender's picture (Gravatar or their domain's icon,
      // lib/avatar.js). The card window can't use the API, so it rides along as
      // a data URL. ponytail: awaited (bounded 1.5s each, cached) — the Tauri
      // card gets its payload once, so a late icon would need a second event.
      message.siteIcon = await fetchSiteIcon(message.from_avatar || siteIconUrl(message.otp))
        || await Promise.race([
          avatarDataUrl(parseAddress(message.from_address).email),
          new Promise((resolve) => setTimeout(() => resolve(null), 1500)),
        ]);

      record(message);

      if (mode === NOTIFICATION_MODES.NONE) return;

      if (mode === NOTIFICATION_MODES.SYSTEM) {
        // Native OS notification (macOS Notification Center / Windows).
        showSystemNotification(message);
      } else if (isTauri()) {
        // Custom mode, desktop: the external glass card window.
        showTauriNotification(message);
      } else {
        // Custom mode, browser: in-app popup.
        show(message);
      }
    });

    return unsub;
  }, [show, record]);
}

// ── Tauri notification window ───────────────────────

let tauriModules = null;
async function getTauriModules() {
  if (!tauriModules) {
    const [wv, ev, win, dpi] = await Promise.all([
      import('@tauri-apps/api/webviewWindow'),
      import('@tauri-apps/api/event'),
      import('@tauri-apps/api/window'),
      import('@tauri-apps/api/dpi'),
    ]);
    tauriModules = {
      WebviewWindow: wv.WebviewWindow,
      emitTo: ev.emitTo,
      getCurrentWindow: win.getCurrentWindow,
      monitorFromPoint: win.monitorFromPoint,
      currentMonitor: win.currentMonitor,
      PhysicalPosition: dpi.PhysicalPosition,
    };
  }
  return tauriModules;
}

// Serialize notification handling. The getByLabel() check below followed by an
// async window create is not atomic: two messages arriving back-to-back would
// each see "no window yet" and both create one, leaving an orphan window that
// survived dismissing the visible alert. Chaining forces the second message to
// wait until the first window is fully created, so it takes the reuse path.
let notifyChain = Promise.resolve();

export function showTauriNotification(message) {
  notifyChain = notifyChain
    .catch(() => {})
    .then(() => doShowTauriNotification(message));
  return notifyChain;
}

async function doShowTauriNotification(message) {
  try {
    // Wayland lets no client position a window or keep it on top, so the card
    // would land anywhere, possibly behind the app. The OS notification instead.
    if (!(await popupWindowsSupported())) {
      showSystemNotification(message);
      return;
    }
    const { WebviewWindow, emitTo, getCurrentWindow, monitorFromPoint, currentMonitor, PhysicalPosition } =
      await getTauriModules();

    // Resolve the monitor the MAIN window actually sits on. The free
    // currentMonitor() is unreliable on multi-monitor setups — it can resolve
    // to a different display than the one the window is on — so we locate the
    // monitor from the window's own center point instead.
    const main = getCurrentWindow();
    let monitor = null;
    try {
      const [pos, size] = await Promise.all([main.outerPosition(), main.outerSize()]);
      monitor = await monitorFromPoint(pos.x + size.width / 2, pos.y + size.height / 2);
    } catch { /* fall back below */ }
    if (!monitor) monitor = await currentMonitor();

    // winW must match WINDOW_W in NotificationPage.jsx (the page positions
    // nothing, but reuse/reposition here assumes this width). winH is only the
    // initial size — the page auto-resizes the window to fit its card stack.
    const winW = 436;
    const winH = 200;
    const padding = 16;

    // Compute the target position in PHYSICAL pixels. Logical window
    // coordinates live in one global space whose scale mapping is ambiguous
    // across monitors, which is what kept landing the popup on the wrong
    // display. Physical pixels are unambiguous global coordinates, so we
    // position the window explicitly via PhysicalPosition after creation.
    // monitor.workArea excludes the menu bar/dock; fall back to full size.
    const scale = monitor?.scaleFactor || 1;
    const area = monitor?.workArea || { position: monitor?.position, size: monitor?.size };
    const areaX = area?.position?.x || 0;
    const areaY = area?.position?.y || 0;
    const areaW = area?.size?.width || 1920 * scale;
    const xPhys = Math.round(areaX + areaW - (winW + padding) * scale);
    const yPhys = Math.round(areaY + padding * scale);

    // Check if window already exists — reuse it (and reposition, since the
    // main window may have moved to a different monitor since last time).
    const existing = await WebviewWindow.getByLabel('notification');
    if (existing) {
      try { await existing.setPosition(new PhysicalPosition(xPhys, yPhys)); } catch { /* best effort */ }
      await emitTo('notification', 'notification-show', message);
      // The popup is persistent (we hide it on dismiss rather than destroy it,
      // so the non-activating NSPanel survives), so re-show it for this alert.
      try { await existing.show(); } catch { /* best effort */ }
      return;
    }

    // First alert of the session: create the popup window. It is created once
    // and then kept alive (hidden between alerts), because converting it to a
    // non-activating NSPanel below can only happen once per window instance.
    //
    // Create a new frameless, transparent, always-on-top window — hidden, so
    // we can place it on the correct monitor before it's shown (avoids a flash
    // on the wrong display). Notification data rides in the URL hash so
    // NotificationPage can read it on mount — avoids a race where emitTo fires
    // before the React listener is registered in the new webview.
    const encodedData = encodeURIComponent(JSON.stringify(message));
    const notifWin = new WebviewWindow('notification', {
      url: `/notification#data=${encodedData}`,
      title: '',
      width: winW,
      height: winH,
      visible: false,
      decorations: false,
      transparent: true,
      alwaysOnTop: true,
      focus: false,
      skipTaskbar: true,
      resizable: false,
      shadow: false,
    });

    // Await creation so a follow-up message reuses this window (via the
    // getByLabel path above) instead of racing a second create.
    await new Promise((resolve) => {
      notifWin.once('tauri://created', async () => {
        try {
          await notifWin.setPosition(new PhysicalPosition(xPhys, yPhys));
          await notifWin.show();
          // macOS: turn this window into a non-activating NSPanel so its action
          // buttons don't activate the app / steal focus. On Windows/Linux this
          // command is a graceful no-op — the window's focus:false + skipTaskbar
          // + alwaysOnTop flags (above) give equivalent non-activating behaviour.
          // Idempotent + once-per-window (the window is now persistent), so it's
          // safe to call here on creation.
          try {
            const { invoke } = await import('@tauri-apps/api/core');
            await invoke('convert_notification_to_panel');
          } catch (e) {
            log.warn('Notification', `Panel conversion failed: ${e?.message || e}`);
          }
        } catch (e) {
          log.warn('Notification', `Window positioning failed: ${e?.message || e}`);
        }
        resolve();
      });
      notifWin.once('tauri://error', (e) => {
        log.warn('Notification', `Window creation failed: ${e}`);
        resolve();
      });
    });
  } catch (e) {
    log.warn('Notification', `Tauri notification failed: ${e?.message || e}`);
  }
}
