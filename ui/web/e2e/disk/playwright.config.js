import { defineConfig, devices } from '@playwright/test'
import fs from 'node:fs'
import path from 'node:path'
import { API, BASE, ENGINE_PORT, FAKE, FAKE_PORT, HERE, RAILS, RAILS_PORT, SAMPLES, STATE, WEB, WEB_PORT, railsEnv } from './env.js'

/* The Disk end-to-end suite (docs/plans/disk-spec.md is the test plan; one spec
 * file per spec section). `yarn e2e:disk` runs prepare.mjs first (fresh e2e
 * database, seed, samples), then this config, which starts its own Rails, Vite
 * engine host and fake providers on 4620-4623 and talks to nothing else. See README.md. */
const engineDir = path.join(STATE, 'engine')
const hasEngine = fs.existsSync(path.join(engineDir, 'manifest.json'))

export default defineConfig({
  testDir: HERE,
  outputDir: path.join(STATE, 'results'),
  timeout: 60_000,
  expect: { timeout: 15_000 },
  globalSetup: path.join(HERE, 'global-setup.js'),
  // One seeded world: specs run in order, one at a time, and make their own
  // uniquely named folders for anything they change.
  fullyParallel: false,
  workers: 1,
  retries: process.env.CI ? 1 : 0,
  reporter: [['list'], ['json', { outputFile: path.join(STATE, 'results.json') }]],
  use: {
    baseURL: BASE,
    actionTimeout: 15_000,
    navigationTimeout: 30_000,
    trace: 'retain-on-failure',
    screenshot: 'only-on-failure',
    viewport: { width: 1440, height: 900 },
  },
  projects: [
    { name: 'chromium', use: { ...devices['Desktop Chrome'], viewport: { width: 1440, height: 900 } }, testIgnore: /screens\.spec/ },
    // The smoke subset in the other engines: browse, upload, a PDF preview, a public link.
    { name: 'firefox', use: { ...devices['Desktop Firefox'], viewport: { width: 1440, height: 900 } }, grep: /@smoke/, testIgnore: /screens\.spec/ },
    { name: 'webkit', use: { ...devices['Desktop Safari'], viewport: { width: 1440, height: 900 } }, grep: /@smoke/, testIgnore: /screens\.spec/ },
    // The screenshot set for review (yarn e2e:disk:screens); not part of the release run.
    { name: 'screens', use: { ...devices['Desktop Chrome'] }, testMatch: /screens\.spec/ },
  ],
  webServer: [
    {
      command: `bin/rails server -p ${RAILS_PORT} -P tmp/pids/e2e-disk.pid`,
      cwd: API,
      env: railsEnv(),
      url: `${RAILS}/up`,
      reuseExistingServer: !!process.env.E2E_DISK_REUSE, // debugging: start the servers yourself (README)
      timeout: 120_000,
      stdout: 'ignore',
      stderr: 'pipe',
    },
    {
      command: `yarn dev --port ${WEB_PORT} --strictPort`,
      cwd: WEB,
      env: {
        INBOX2_API_ORIGIN: RAILS,
        ...(hasEngine ? { VITE_DISK_ENGINE_URL: `http://localhost:${ENGINE_PORT}` } : {}),
      },
      url: BASE,
      stdout: 'ignore',
      stderr: 'ignore', // Vite forwards every browser console line; failures keep their own traces
      reuseExistingServer: !!process.env.E2E_DISK_REUSE, // debugging: start the servers yourself (README)
      timeout: 120_000,
    },
    {
      // Google Drive, Microsoft 365 and Dropbox as far as the importers see them (F10).
      command: `node ${path.join(HERE, 'fake-providers.mjs')} ${FAKE_PORT} ${SAMPLES}`,
      url: `${FAKE}/_health`,
      reuseExistingServer: !!process.env.E2E_DISK_REUSE, // debugging: start the servers yourself (README)
      timeout: 30_000,
    },
    ...(hasEngine ? [{
      command: `node ${path.join(HERE, 'engine-server.mjs')} ${engineDir} ${ENGINE_PORT} ${BASE}`,
      url: `http://localhost:${ENGINE_PORT}/manifest.json`,
      reuseExistingServer: !!process.env.E2E_DISK_REUSE, // debugging: start the servers yourself (README)
      timeout: 30_000,
    }] : []),
  ],
})
