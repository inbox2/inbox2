// Demo notifications — fire a new-message alert, a burst of them, a sign-in
// code, a sign-in link, a WhatsApp message, a meeting reminder or a meeting
// invite on demand.
//
// Used two ways: the command palette's "Demo:" entries (any build — this is how
// a notification gets into a demo or a screen recording on cue), and the
// dev-only boot harness below, which fires a stacked burst at launch so the
// desktop popup window's sizing and stacking can be eyeballed. Everything goes
// through the real syncManager 'new-message' path, so it exercises the full
// pipeline (sound + Tauri window + activity feed), identical to genuine mail.
//
// The boot burst is off by default (the palette replaced it) and is guarded by
// import.meta.env.DEV besides; flip ENABLED to re-arm it.

import syncManager from './sync-manager';
import { buildAlert, deliverMeetingAlert } from '../hooks/useMeetingReminders';
import { detectMeeting } from '../components/MeetingProviderIcon/meetingProvider';
import { rsvpSummary } from './meetingAlerts';
import log from './log';

const ENABLED = false;

// Fictional samples only — no real personal mail (bookings, addresses, etc.).
const SAMPLES = [
  {
    baseKey: 'harness-wifi',
    from_address: 'CustomerCare <care@skyway-air.example>',
    subject: 'Inflight Wi-Fi Purchase Confirmation',
    snippet: 'Thank you for flying with us. Wi-Fi purchase reference #WIFI-5L31BH — plan: Surf & Stream. Connect any time during your flight.',
    email: 'you@acme.com',
    accountKey: 'demo',
    providerType: 'gmail',
  },
  {
    baseKey: 'harness-pipeline',
    from_address: 'Sarah Chen <sarah.chen@example.com>',
    subject: 'Q3 Pipeline Review — action needed',
    snippet: 'Hey team, can you review slides 4–8 before standup tomorrow? Want to lock the forecast numbers before the board call.',
    email: 'you@acme.com',
    accountKey: 'demo',
    providerType: 'microsoft',
  },
  {
    baseKey: 'harness-invoice',
    from_address: 'Billing <billing@acme.io>',
    subject: 'Invoice #4821 is ready',
    snippet: 'Your monthly invoice is available. Total due €1,240.00 by 15 Jun 2026. View and pay online at any time.',
    email: 'you@acme.com',
    accountKey: 'demo',
    providerType: 'imap',
  },
];

// A meeting eight minutes out with a real-shaped Meet link, so the Join button
// and the amber rail can be checked alongside the blue mail cards.
const SAMPLE_MEETING = {
  id: 'harness-meeting',
  title: 'Q3 Roadmap Review',
  location: 'https://meet.google.com/wqf-rhzt-yjk',
  organizerName: 'Marieke de Groot',
  // camelCase, the shape the offline calendar sync stores (the API's snake_case
  // is normalised to the same thing by rsvpSummary).
  attendees: [
    { name: 'Marieke de Groot', email: 'marieke@example.com', responseStatus: 'accepted' },
    { name: 'Sanne Peters', email: 'sanne@example.com', responseStatus: 'accepted' },
    { name: 'Tomas Kok', email: 'tomas@example.com', responseStatus: 'tentative' },
    { name: 'Jasper Vos', email: 'jasper@example.com', responseStatus: 'declined' },
  ],
  leads: [10, 0],
};

// A mail card carrying an answerable invite — the Accept/Decline strip above the
// usual action row. The `invite` rides on the payload as if the probe in
// lib/invites.js had resolved it (it can't here: there is no real ICS to fetch).
const SAMPLE_INVITE = {
  baseKey: 'harness-invite',
  from_address: 'Marieke de Groot <marieke@example.com>',
  subject: 'Invitation: Q3 Roadmap Review',
  snippet: 'Marieke de Groot has invited you to Q3 Roadmap Review.',
  email: 'you@acme.com',
  accountKey: 'demo',
  providerType: 'gmail',
  eventLabel: 'Meeting invitation',
  eventColor: 'meeting',
  priority: 'high',
  invite: {
    method: 'REQUEST',
    uid: 'harness-invite@example.com',
    summary: 'Q3 Roadmap Review',
    location: 'https://meet.google.com/wqf-rhzt-yjk',
    organizer_email: 'marieke@example.com',
    attachment_id: 'harness-ics',
  },
};

// A sign-in code and a sign-in link: the engine detects these on real mail and
// sends them as `otp` on the payload (Copy code / Open link on the card).
const SAMPLE_OTP_CODE = {
  baseKey: 'harness-otp-code',
  from_address: 'Orbit Labs <security@orbitlabs.io>',
  subject: 'Your Orbit Labs sign-in code',
  snippet: 'Your sign-in code is 482 913. It expires in 10 minutes. If you did not try to sign in, you can ignore this email.',
  email: 'you@acme.com',
  accountKey: 'demo',
  providerType: 'gmail',
  otp: { code: '482 913' },
};
const SAMPLE_OTP_LINK = {
  baseKey: 'harness-otp-link',
  from_address: 'Brightfold <login@brightfold.co>',
  subject: 'Sign in to Brightfold',
  snippet: 'Click the link to sign in to your Brightfold workspace. The link works once and expires in 15 minutes.',
  email: 'you@acme.com',
  accountKey: 'demo',
  providerType: 'microsoft',
  otp: { link: 'https://app.brightfold.co/auth/magic?token=demo', host: 'app.brightfold.co' },
};
// A WhatsApp message (the social card: the sender's face, the WhatsApp badge).
const SAMPLE_SOCIAL = {
  baseKey: 'harness-whatsapp',
  from_address: 'Sarah Chen',
  subject: '',
  snippet: 'Can you send me the signed contract before 3pm today? Legal needs it for the filing 🙏',
  email: 'WhatsApp',
  accountKey: 'demo',
  providerType: 'whatsapp',
  channel: 'whatsapp',
  from_avatar: '/images/a2.jpg',
};

let fired = false;

function emit(sample) {
  syncManager.emit('new-message', {
    ...sample,
    key: `${sample.baseKey}-${Date.now()}`,
    from_address: sample.from_address,
    subject: sample.subject,
    snippet: sample.snippet,
    email: sample.email,
    accountKey: sample.accountKey,
    providerType: sample.providerType,
    updated_at: new Date().toISOString(),
  });
}

function emitMeeting() {
  const now = Date.now();
  const start = new Date(now + 8 * 60000);
  deliverMeetingAlert(buildAlert(
    {
      ...SAMPLE_MEETING,
      startAt: start,
      endAt: new Date(start.getTime() + 60 * 60000),
      meeting: detectMeeting(SAMPLE_MEETING),
      attendeeSummary: rsvpSummary(SAMPLE_MEETING.attendees),
    },
    now,
  ));
}

/** One demo email — a different sample each time, so a burst looks like mail. */
let nextSample = 0;
export function emitDemoMail() {
  emit(SAMPLES[nextSample++ % SAMPLES.length]);
}

/** A meeting reminder for a meeting eight minutes out (Join button + amber rail). */
export function emitDemoMeeting() {
  emitMeeting();
}

/** Several emails in quick succession, so the cards stack the way a busy inbox does. */
export function emitDemoMailBurst(count = 3) {
  for (let i = 0; i < count; i += 1) setTimeout(emitDemoMail, i * 700);
}

/** A sign-in code (big code + Copy on the card). */
export function emitDemoOtpCode() {
  emit(SAMPLE_OTP_CODE);
}

/** A sign-in link (Open link on the card). */
export function emitDemoSignInLink() {
  emit(SAMPLE_OTP_LINK);
}

/** A new WhatsApp message. */
export function emitDemoSocial() {
  emit(SAMPLE_SOCIAL);
}

/** A mail alert carrying an answerable invite (the Accept/Decline strip). */
export function emitDemoInvite() {
  emit(SAMPLE_INVITE);
}

/** Arm the boot harness once per app session (no-op unless ENABLED, dev only). */
export function runNotificationTestHarness() {
  if (!import.meta.env.DEV || !ENABLED || fired) return;
  fired = true;
  log.info('NotifTest', 'harness armed — 1 alert in 1.5s, 2 more 3s after (stacking test), meeting at 7s, invite at 9.5s');
  setTimeout(() => emit(SAMPLES[0]), 1500);
  setTimeout(() => { emit(SAMPLES[1]); emit(SAMPLES[2]); }, 4500);
  setTimeout(emitMeeting, 7000);
  setTimeout(() => emit(SAMPLE_INVITE), 9500);
}
