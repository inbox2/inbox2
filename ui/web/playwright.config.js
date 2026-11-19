import { defineConfig, devices } from '@playwright/test';

/* Browser e2e for the web console/inbox, driven against a LOCAL Rails API (dev
 * DB, seeded with the multi-domain demo via `bin/rails db:seed`). Runs a
 * dedicated Vite dev server on :4199 pointed at http://localhost:4000 so it never
 * collides with a normal `yarn dev` on :4173 (which proxies to prod). Both
 * servers are reused if already running (e.g. under `bin/dev`).
 *
 *   yarn e2e              # headless
 *   yarn e2e --headed     # watch it drive
 */
const WEB_PORT = 4199;
const API_ORIGIN = process.env.INBOX2_API_ORIGIN || 'http://localhost:4000';

export default defineConfig({
  testDir: './e2e',
  // The Disk suite has its own harness and database: yarn e2e:disk (e2e/disk/README.md).
  testIgnore: ['disk/**'],
  // Generous: the dev API is a single Puma worker with code-reload, and cold Vite
  // compiles the SPA on first load — both slow relative to a built app.
  timeout: 90_000,
  expect: { timeout: 20_000 },
  globalSetup: './e2e/global-setup.js', // warm the dev server so the first spec isn't cold
  // Shared seeded DB → run serially so specs don't race on mutations.
  fullyParallel: false,
  workers: 1,
  retries: 1,
  reporter: [['list']],
  use: {
    baseURL: `http://localhost:${WEB_PORT}`,
    actionTimeout: 20_000,
    navigationTimeout: 45_000,
    trace: 'retain-on-failure',
    screenshot: 'only-on-failure',
  },
  projects: [{ name: 'chromium', use: { ...devices['Desktop Chrome'] } }],
  webServer: [
    {
      // Local Rails API against the seeded dev DB. Reused if bin/dev is running.
      command: 'bin/rails server -p 4000',
      cwd: '../../api',
      url: 'http://localhost:4000/up',
      reuseExistingServer: true,
      timeout: 120_000,
    },
    {
      // Vite dev server pointed at the LOCAL API (not prod), on a dedicated port.
      command: `yarn dev --port ${WEB_PORT} --strictPort`,
      url: `http://localhost:${WEB_PORT}`,
      reuseExistingServer: true,
      timeout: 120_000,
      env: { INBOX2_API_ORIGIN: API_ORIGIN },
    },
  ],
});
