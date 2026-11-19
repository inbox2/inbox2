import { chromium, request } from '@playwright/test';
import fs from 'node:fs';
import path from 'node:path';

/* Pre-authenticate each actor by minting a session token straight from the API
 * and writing it as a Playwright storageState (the dev web app hydrates its
 * bearer from localStorage). This skips the flaky UI-login step + boot-signout
 * race, then warms the cold Vite dev server so the first real spec isn't slow. */

const AUTH_DIR = path.join(process.cwd(), 'e2e', '.auth');
const USERS = ['demo', 'sarah'];

function statePath(user) {
  return path.join(AUTH_DIR, `${user}.json`);
}

function tokenOf(state) {
  return state?.origins?.[0]?.localStorage?.find((e) => e.name === 'inbox2_cloud_auth_token')?.value;
}

async function tokenValid(apiOrigin, token) {
  const ctx = await request.newContext({ extraHTTPHeaders: { Authorization: `Bearer ${token}` } });
  const ok = (await ctx.get(`${apiOrigin}/api/v1/account`)).ok();
  await ctx.dispose();
  return ok;
}

async function mintState(apiOrigin, webBase, username) {
  const ctx = await request.newContext();
  const res = await ctx.post(`${apiOrigin}/api/v1/auth/login`, { data: { username, password: 'password123' } });
  if (!res.ok()) {
    throw new Error(`e2e login for ${username} failed: HTTP ${res.status()}` +
      (res.status() === 429 ? ' (login rate-limited — wait ~1 min, or reuse the cached e2e/.auth state)' : ''));
  }
  const { token } = await res.json();
  await ctx.dispose();
  return {
    cookies: [],
    origins: [{ origin: webBase, localStorage: [{ name: 'inbox2_cloud_auth_token', value: token }] }],
  };
}

// Reuse a cached auth state when its token still authenticates (avoids hammering
// the login rate-limiter on every run); mint fresh only when missing/stale.
async function ensureState(apiOrigin, webBase, username) {
  const file = statePath(username);
  if (fs.existsSync(file)) {
    try {
      const token = tokenOf(JSON.parse(fs.readFileSync(file, 'utf8')));
      if (token && await tokenValid(apiOrigin, token)) return;
    } catch { /* fall through to re-mint */ }
  }
  fs.writeFileSync(file, JSON.stringify(await mintState(apiOrigin, webBase, username)));
}

export default async function globalSetup(config) {
  const { baseURL } = config.projects[0].use;
  const apiOrigin = process.env.INBOX2_API_ORIGIN || 'http://localhost:4000';
  fs.mkdirSync(AUTH_DIR, { recursive: true });

  for (const u of USERS) {
    await ensureState(apiOrigin, baseURL, u);
  }

  // Warm the routes the specs hit so no spec pays the cold-compile cost inside
  // its own timeout. Authed routes with the owner session; /signup signed-out.
  const browser = await chromium.launch();
  try {
    const owner = await browser.newPage({ storageState: statePath('demo') });
    await owner.goto(`${baseURL}/console`, { waitUntil: 'domcontentloaded', timeout: 120_000 });
    await owner.getByText('acme.com').first().waitFor({ state: 'visible', timeout: 120_000 });
    for (const route of ['/acme-corp/mail/inbox', '/onboarding', '/console/domains/acme-corp?tab=team', '/console/api-keys']) {
      await owner.goto(`${baseURL}${route}`, { waitUntil: 'domcontentloaded', timeout: 120_000 });
    }

    const guest = await browser.newPage(); // no auth → GuestRoute renders /signup
    await guest.goto(`${baseURL}/signup`, { waitUntil: 'domcontentloaded', timeout: 120_000 });
    await guest.getByText('Create your account').waitFor({ state: 'visible', timeout: 120_000 });
  } finally {
    await browser.close();
  }
}
