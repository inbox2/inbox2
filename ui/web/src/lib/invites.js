// Emailed meeting invites (docs/Meeting-Invites.md) — the bits more than one
// surface needs: which ICS is answerable, how to say when it is, and how to
// resolve/answer one from a notification alert.

import log from './log';
import { isTauri } from './tauri';
import { PROVIDER } from './providerTypes';

// An invitation you can actually answer, vs an event you just file. A stated
// METHOD other than REQUEST (PUBLISH confirmations, bookings, tickets) is never
// answerable. Past that, an MX invite is a REQUEST by construction, while a
// local-channel one also has to name an organizer — an RSVP with nobody to send
// it to isn't worth offering. Kept in step with iOS `ClientInvite.isRequest`
// and Android's.
export function isRequest(invite) {
  if (invite.method && invite.method !== 'REQUEST') return false;
  if (!invite.attachment_id) return true;   // MX
  return !!invite.organizer_email;
}

export function attachmentIsCalendar(a) {
  const name = (a.name || a.filename || '').toLowerCase();
  return a.mimeType === 'text/calendar' || name.endsWith('.ics');
}

// ms `tz` is ahead of UTC at `date`.
function tzOffset(date, tz) {
  const p = {};
  const dtf = new Intl.DateTimeFormat('en-US', {
    timeZone: tz, hourCycle: 'h23', year: 'numeric', month: 'numeric', day: 'numeric',
    hour: 'numeric', minute: 'numeric', second: 'numeric',
  });
  for (const { type, value } of dtf.formatToParts(date)) p[type] = +value;
  return Date.UTC(p.year, p.month - 1, p.day, p.hour, p.minute, p.second) - date.getTime();
}

/**
 * An invite time as an instant. A local-channel invite keeps the sender's
 * TZID: `start`/`end` are a bare wall clock read in `invite.timezone`
 * (core ics.rs), so `new Date()` alone would show the sender's hour as ours.
 * MX invites arrive with an offset already.
 */
export function inviteInstant(ts, tz) {
  // All-day "2024-01-15": your midnight, not UTC's (a day early west of UTC).
  const day = /^(\d{4})-(\d\d)-(\d\d)$/.exec(ts);
  if (day) return new Date(+day[1], day[2] - 1, +day[3]);
  if (!tz || /(Z|[+-]\d\d:?\d\d)$/i.test(ts)) return new Date(ts);
  try {
    const wall = Date.parse(`${ts}Z`);
    // Two passes so a DST boundary between guess and answer still resolves.
    let t = wall - tzOffset(new Date(wall), tz);
    t = wall - tzOffset(new Date(t), tz);
    return new Date(t);
  } catch {
    return new Date(ts);   // unknown zone: the old wall-clock reading
  }
}

/** "Tue, Sep 9 · 2:00 PM – 2:30 PM" — the one line an invite is judged on. */
export function formatWhen(invite) {
  if (!invite.start) return null;
  try {
    const start = invite.all_day ? inviteInstant(invite.start.slice(0, 10)) : inviteInstant(invite.start, invite.timezone);
    if (invite.all_day) {
      return start.toLocaleDateString(undefined, { weekday: 'short', month: 'short', day: 'numeric' }) + ' · All day';
    }
    const date = start.toLocaleDateString(undefined, { weekday: 'short', month: 'short', day: 'numeric' });
    const t = (d) => d.toLocaleTimeString(undefined, { hour: 'numeric', minute: '2-digit' });
    const end = invite.end ? inviteInstant(invite.end, invite.timezone) : null;
    return end ? `${date} · ${t(start)} – ${t(end)}` : `${date} · ${t(start)}`;
  } catch {
    return null;
  }
}

// A live provider fetch (message detail, then the ICS bytes) sits behind this,
// so the alert can't wait on it forever — past this we show the plain mail card.
const PROBE_TIMEOUT_MS = 2500;

/**
 * Resolve a just-arrived message to an answerable invite, or null.
 *
 * MX alerts arrive with the invite already parsed by Rails. Local channels are
 * probed: the engine's payload carries `hasAttachment`, and that gate is what
 * keeps the two provider round-trips off ordinary mail.
 */
export async function inviteForAlert(notif) {
  // MX: Rails already parsed it and sent it with the alert (lib/pushSync.js).
  if (notif?.providerType === PROVIDER.INBOX2) return notif.invite && isRequest(notif.invite) ? notif.invite : null;
  if (!isTauri() || !notif?.hasAttachment || !notif.messageKey || !notif.accountKey) return null;
  try {
    return await Promise.race([
      probe(notif),
      new Promise((resolve) => setTimeout(() => resolve(null), PROBE_TIMEOUT_MS)),
    ]);
  } catch (e) {
    log.warn('Notification', `invite probe failed: ${e?.message || e}`);
    return null;
  }
}

async function probe(notif) {
  const { fetchMessage, inviteForAttachment } = await import('./providers/index.js');
  const { attachments } = await fetchMessage(notif.accountKey, notif.messageKey);
  const att = (attachments || []).find(attachmentIsCalendar);
  if (!att) return null;
  const invite = await inviteForAttachment(notif.accountKey, notif.messageKey, att.attachmentId);
  // Only an answerable REQUEST earns Accept/Decline on a card that auto-dismisses;
  // "Add to calendar" stays a decision you make in the reader.
  return invite && isRequest(invite) ? invite : null;
}

/** Answer the invite an alert card is showing. `response` is accepted|declined|tentative. */
export async function respondToAlertInvite(notif, response) {
  // Same guard as runNotificationAction: the card carries demo mode for the window.
  if (notif.demo) throw new Error('Demo data is on, so nothing is saved.');
  if (notif.providerType === PROVIDER.INBOX2) {
    // Same endpoint the reader's banner answers an MX invite with.
    const { default: api } = await import('./api.js');
    return api.post(`/orgs/${notif.orgId}/messages/${notif.messageKey}/rsvp`, { status: response });
  }
  const { respondToInvite } = await import('./providers/index.js');
  return respondToInvite(notif.accountKey, notif.messageKey, notif.invite.attachment_id, response);
}
