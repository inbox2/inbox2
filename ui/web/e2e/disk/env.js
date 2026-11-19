// The Disk e2e harness's fixed settings, shared by prepare.mjs, the Playwright
// config and the specs. Ports sit away from the owner's own dev servers (Rails
// 4000, Vite 4173, the older e2e Vite 4199) so both can run at once.
import crypto from 'node:crypto'
import path from 'node:path'
import { fileURLToPath } from 'node:url'

export const HERE = path.dirname(fileURLToPath(import.meta.url))
export const WEB = path.resolve(HERE, '../..')
export const API = path.resolve(WEB, '../../api')
export const STATE = path.join(HERE, '.state') // gitignored: seed.json, auth states, samples, engine
export const SEED = path.join(STATE, 'seed.json')
export const SAMPLES = path.join(STATE, 'samples')

export const RAILS_PORT = 4620
export const WEB_PORT = 4621
export const ENGINE_PORT = 4622 // static host for the packed exact-view engine
export const FAKE_PORT = 4623 // fake-providers.mjs: Google, Microsoft and Dropbox for F10
export const GARAGE_PORT = 4900
export const RAILS = `http://localhost:${RAILS_PORT}`
export const BASE = `http://localhost:${WEB_PORT}`
export const FAKE = `http://127.0.0.1:${FAKE_PORT}`
export const DB = 'api_e2e_disk'
export const BUCKET = 'inbox2-e2e-disk'

// Credentials and external services the e2e Rails must never use: a real
// MESSY_API_KEY in the owner's shell would send real mail to the seeded people.
const SCRUB = /(_API_KEY|_SECRET|_TOKEN|PASSWORD|_KEY_ID|^APNS_|^FCM_|^GOOGLE_|^MICROSOFT_|^DROPBOX_|^OPENAI|^TYPESAFE|^MESSY|^SENTRY|^S3_|^DISK_|^DATABASE_URL$)/

/** The environment the e2e Rails (server, seed, schema load) runs with. */
export function railsEnv() {
  const env = Object.fromEntries(Object.entries(process.env).filter(([k]) => !SCRUB.test(k)))
  return {
    ...env,
    RAILS_ENV: 'development',
    DATABASE_URL: `postgres:///${DB}`,
    SKIP_TEST_DATABASE: '1', // db tasks in development otherwise also touch api_test
    DISK_S3_BUCKET: BUCKET,
    S3_BUCKET: BUCKET, // the seeded mail attachment too, never the dev attachments bucket
    DISK_CORS_ORIGINS: BASE,
    FRONTEND_URL: BASE,
    WEB_APP_URL: BASE,
    MESSY_API_URL: 'http://127.0.0.1:9', // discard port: notification mail goes nowhere
    MESSY_API_KEY: 'e2e-disabled',
    RAILS_MAX_THREADS: '8', // two collaborating browsers plus the cable
    // Importer apps (fake credentials), every provider endpoint pointed at the
    // local fake (fake-providers.mjs; Disk::ImportSource.url, refused in production).
    // No real provider is ever reached.
    ...Object.fromEntries(['GOOGLE', 'MICROSOFT', 'DROPBOX'].flatMap((p) => [
      [`DISK_IMPORT_${p}_CLIENT_ID`, `e2e-${p.toLowerCase()}-client`],
      [`DISK_IMPORT_${p}_CLIENT_SECRET`, 'e2e-not-a-secret'],
      [`DISK_IMPORT_${p}_APPROVED`, 'true'],
      [`DISK_IMPORT_${p}_AUTHORIZE_URL`, `${FAKE}/${p.toLowerCase()}/authorize`],
      [`DISK_IMPORT_${p}_TOKEN_URL`, `${FAKE}/${p.toLowerCase()}/token`],
    ])),
    DISK_IMPORT_GOOGLE_API_URL: `${FAKE}/google/drive/v3`,
    DISK_IMPORT_GOOGLE_DIRECTORY_URL: `${FAKE}/google/directory`,
    DISK_IMPORT_GOOGLE_USERINFO_URL: `${FAKE}/google/userinfo`,
    DISK_IMPORT_GOOGLE_SERVICE_ACCOUNT: SERVICE_ACCOUNT, // members' My Drives through delegation
    DISK_IMPORT_MICROSOFT_GRAPH_URL: `${FAKE}/microsoft/graph`,
    DISK_IMPORT_MICROSOFT_LOGIN_URL: `${FAKE}/microsoft/login`,
    DISK_IMPORT_DROPBOX_API_URL: `${FAKE}/dropbox/api/2`,
    DISK_IMPORT_DROPBOX_CONTENT_URL: `${FAKE}/dropbox/content/2`,
  }
}

// A throwaway service account for Google's domain-wide delegation: the API signs
// its JWT grant with this key; the fake reads the subject and does not verify.
const SERVICE_ACCOUNT = JSON.stringify({
  client_email: 'importer@e2e.iam.gserviceaccount.com',
  private_key: crypto.generateKeyPairSync('rsa', { modulusLength: 2048 }).privateKey.export({ type: 'pkcs8', format: 'pem' }),
})
