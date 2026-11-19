// Native OS notification for the "system" notification mode.
//
// Tauri (desktop): routes through tauri-plugin-notification, which posts to the
//   macOS Notification Center (and the equivalent on Windows/Linux), giving the
//   OS-native card with its own snooze/dismiss affordances.
// Browser: uses the Web Notification API.
//
// Permission is requested lazily on first use. Failures degrade quietly — a
// missing permission just means no banner; the message is still in the feed.

import { isTauri } from './tauri';
import { getAppIcon, previewSrc } from './appIcon';
import { displayName as senderName } from './emailAddress';
import { stripHtml } from './messageText';
import log from './log';
import { isMeetingAlert, isZoneAlert } from '../stores/notificationStore';

function buildTitle(message) {
  // A meeting reminder names the moment ("Meeting in 10 minutes"); mail names
  // the sender.
  if (isZoneAlert(message)) return `You're in the zone: ${message.title}`;
  if (isMeetingAlert(message)) return message.eventLabel || 'Upcoming meeting';
  return senderName(message.from_address) || 'New message';
}

function buildBody(message) {
  if (isZoneAlert(message)) return [message.timeLine, message.note].filter(Boolean).join('\n');
  if (isMeetingAlert(message)) {
    return [message.title, message.timeLine].filter(Boolean).join('\n');
  }
  const subject = message.subject || '(no subject)';
  const snippet = stripHtml(message.snippet || '').replace(/\s+/g, ' ').trim();
  return snippet ? `${subject}\n${snippet}` : subject;
}

async function showTauriSystemNotification(message) {
  try {
    const notif = await import('@tauri-apps/plugin-notification');
    let granted = await notif.isPermissionGranted();
    if (!granted) granted = (await notif.requestPermission()) === 'granted';
    if (!granted) {
      log.info('Notification', 'system notification permission denied');
      return;
    }
    notif.sendNotification({
      title: buildTitle(message),
      body: buildBody(message),
    });
  } catch (e) {
    log.warn('Notification', `system notification failed: ${e?.message || e}`);
  }
}

function showBrowserSystemNotification(message) {
  if (!('Notification' in window)) return;
  if (Notification.permission !== 'granted') {
    if (Notification.permission === 'default') Notification.requestPermission();
    return;
  }
  try {
    const n = new Notification(buildTitle(message), {
      body: buildBody(message),
      icon: message.siteIcon || previewSrc(getAppIcon()), // else browsers fall back to the favicon
      tag: `inbox2-${message.key}`,
      silent: true, // sound handled by playPing()
    });
    setTimeout(() => n.close(), 6000);
  } catch (e) {
    log.warn('Notification', `browser notification failed: ${e?.message || e}`);
  }
}

/** Post a native OS notification for a new message or a meeting reminder. */
export function showSystemNotification(message) {
  if (isTauri()) showTauriSystemNotification(message);
  else showBrowserSystemNotification(message);
}
