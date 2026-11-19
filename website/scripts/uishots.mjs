/**
 * Notification-card screenshots for the website.
 *
 * The cards live in the standalone /notification page (the one Tauri opens in
 * its frameless panel). That page seeds its stack from the URL hash, so every
 * variant below is just a payload — no mail, no sync, no app state. Shot in
 * headless Chromium against the running web dev server.
 *
 *     cd ui/web && node ../../website/scripts/uishots.mjs
 *     WEB_ORIGIN=http://localhost:4173 node ../../website/scripts/uishots.mjs
 *
 * Cards are captured on transparent so the site can float them over any section.
 */
import { execFileSync } from 'node:child_process';
import { createRequire } from 'node:module';
import { mkdirSync, rmSync } from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

// playwright lives in ui/web, not here — resolve it from there rather than
// duplicating the dependency for one script.
const require = createRequire(new URL('../../ui/web/package.json', import.meta.url));
const { chromium } = require('playwright');

const ORIGIN = process.env.WEB_ORIGIN || 'http://localhost:4173';
const OUT = path.resolve(fileURLToPath(new URL('../public/assets/shots', import.meta.url)));

const mail = (o) => ({
  key: `k${Math.random()}`,
  email: 'sam@brightfold.co',
  accountKey: 'gmail:hello@brightfold.co',
  updated_at: new Date().toISOString(),
  ...o,
});

const inTwelve = new Date(Date.now() + 12 * 60000);

const MEETING = {
  eventType: 'meeting_reminder',
  eventLabel: 'In 12 minutes',
  eventColor: 'meeting',
  priority: 'high',
  key: 'mtg:demo',
  eventId: 'demo',
  subject: 'Aurora — guidelines working session',
  title: 'Aurora — guidelines working session',
  timeLine: '1:30 PM – 2:30 PM · Google Meet',
  startAt: inTwelve.toISOString(),
  endAt: new Date(inTwelve.getTime() + 3600000).toISOString(),
  location: 'https://meet.google.com/xgb-rkzt-qva',
  organizerName: 'Priya Raman',
  attendeeSummary: '3 accepted · 1 tentative',
  meeting: { provider: 'google', label: 'Google Meet', url: 'https://meet.google.com/xgb-rkzt-qva' },
  updated_at: inTwelve.toISOString(),
};

const SHOTS = {
  'notif-mail': [mail({
    from_address: 'Priya Raman <priya@aurorahealth.com>',
    subject: 'Re: Aurora rebrand — final logo lockups',
    snippet: 'These look incredible. The board signed off this morning — unanimously, which almost never happens here — so we can lock the primary mark.',
    providerType: 'gmail',
  })],

  'notif-stack': [
    mail({
      from_address: 'Priya Raman <priya@aurorahealth.com>',
      subject: 'Re: Aurora rebrand — final logo lockups',
      snippet: 'These look incredible. The board signed off this morning — unanimously, which almost never happens here.',
      providerType: 'gmail',
    }),
    mail({
      from_address: 'North Point Print <billing@northpoint-print.com>',
      subject: 'Invoice INV-2048 is overdue (net-15)',
      snippet: 'A friendly reminder that invoice INV-2048 for $3,420.00 is now six days past due.',
      providerType: 'microsoft',
      priority: 'urgent',
    }),
    mail({
      from_address: 'Jordan Mills',
      subject: 'WhatsApp · Jordan Mills',
      snippet: 'Perfect, see you then! 🙌',
      providerType: 'whatsapp',
    }),
    mail({
      from_address: 'Marcus Webb <marcus@finchley.io>',
      subject: 'Q3 retainer — second motion designer?',
      snippet: 'Can we add a second motion designer before the quarter starts?',
      providerType: 'imap',
    }),
  ],

  'notif-invite': [mail({
    from_address: 'Priya Raman <priya@aurorahealth.com>',
    subject: 'Invitation: Aurora — guidelines working session',
    snippet: 'Priya Raman has invited you to Aurora — guidelines working session.',
    providerType: 'gmail',
    eventLabel: 'Meeting invitation',
    eventColor: 'meeting',
    priority: 'high',
    invite: {
      method: 'REQUEST',
      uid: 'demo-invite@brightfold.co',
      summary: 'Aurora — guidelines working session',
      location: 'https://meet.google.com/xgb-rkzt-qva',
      organizer_email: 'priya@aurorahealth.com',
      starts_at: inTwelve.toISOString(),
      ends_at: new Date(inTwelve.getTime() + 3600000).toISOString(),
      attachment_id: 'demo-ics',
    },
  })],

  'notif-meeting': [MEETING],

  'notif-starting': [{
    ...MEETING,
    eventLabel: 'Starting now',
    eventColor: 'urgent',
    priority: 'urgent',
    startAt: new Date().toISOString(),
  }],
};

const browser = await chromium.launch();
const page = await browser.newPage({
  viewport: { width: 480, height: 900 },
  deviceScaleFactor: 3,
});
mkdirSync(OUT, { recursive: true });

for (const [name, payload] of Object.entries(SHOTS)) {
  // The query param is a cache-buster: changing only the hash is a same-document
  // navigation, so React keeps the previous stack and the shot is a repeat.
  const url = `${ORIGIN}/notification?shot=${name}#data=${encodeURIComponent(JSON.stringify(payload))}`;
  await page.goto(url, { waitUntil: 'domcontentloaded' });
  // Frosted glass over nothing reads as grey mush; the site floats these on a
  // dark section, so composite them on the same ink while shooting.
  await page.addStyleTag({ content: 'html,body{background:#111 !important}' });
  const stack = page.locator('[class*="stack"]').first();
  await stack.waitFor({ state: 'visible', timeout: 10000 });
  await page.waitForTimeout(1200);     // entry animation + the stack settling
  const box = await stack.boundingBox();
  const png = path.join(OUT, `_${name}.png`);
  // Clip off the page rather than element.screenshot(): the cards animate in
  // with a transform, and an element shot clips to the pre-animation box.
  const m = 14;                        // keep the card shadows
  await page.screenshot({
    path: png,
    clip: { x: box.x - m, y: box.y - m, width: box.width + m * 2, height: box.height + m * 2 },
  });
  execFileSync('cwebp', ['-quiet', '-q', '88', png, '-o', path.join(OUT, `${name}.webp`)]);
  rmSync(png);
  console.log(`  → assets/shots/${name}.webp`);
}

await browser.close();
