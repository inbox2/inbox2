# Disk end-to-end suite

The release check for Disk. `docs/plans/disk-spec.md` is the test plan: one spec
file per spec section, each test named after the box it proves.

```sh
cd ui/web
yarn e2e:disk                 # everything, from a clean world, exits non-zero on failure
yarn e2e:disk f6-pages        # one spec file (any Playwright filter after the script)
yarn e2e:disk -g "F2.5"       # one test by name
yarn e2e:disk:screens         # the screenshot set for review (not part of the release run)
E2E_DISK_LARGE=1 yarn e2e:disk -g E2E_DISK_LARGE   # the spec's sizes: 1 GB resumed upload, 1 GB zip, 500 MB sealed video
```

About 8 minutes on an M-series Mac from a clean database: 10 s to prepare (plus about a
minute the first time, to make samples and pack the engine), then Chromium, then the Firefox
and WebKit smoke subset. The screenshot set takes about 5 minutes. `E2E_DISK_LARGE=1` adds
about 3 GB of samples (made once) and under a minute of tests.

## Prerequisites

- Postgres running locally (the suite makes and drops its own database, `api_e2e_disk`), with `pg_dump` on the PATH (the sealed dump check).
- Local Garage on :4900: `docker compose -f docker/docker-compose.yml --profile storage up -d && bin/garage-init`.
- `bundle install` in `api/`, `yarn install --ignore-scripts` in `ui/web`.
- `ffmpeg` and `zip` on the PATH (the sample image, video and audio are made once).
- Playwright's Chromium, Firefox and WebKit: `npx playwright install chromium firefox webkit`.
- Ports 4620 to 4623 free. Your own Rails (4000) and Vite (4173) can keep running.

## What it does

1. `prepare.mjs` checks the ports and Garage, makes the samples (cached in `.state/samples`),
   packs the exact-view engine once (`scripts/disk-engine-pack.mjs`, about 75 MB, cached in
   `.state/engine`), makes the `inbox2-e2e-disk` bucket, drops and recreates `api_e2e_disk`
   from `schema.rb` plus any newer migrations (the dump after migrating goes to `.state`,
   never to `api/db/schema.rb`), and runs `bin/rails e2e:disk:seed`
   (`api/lib/tasks/e2e_disk.rake`), which empties the bucket and writes `.state/seed.json`.
2. Playwright starts its own servers and stops them at the end:
   - Rails on **4620** against `api_e2e_disk`, development environment, `DISK_S3_BUCKET=inbox2-e2e-disk`,
     with every credential-like variable stripped from the environment and Messy pointed at a
     dead port, so no mail leaves the machine;
   - Vite on **4621** with `INBOX2_API_ORIGIN=http://localhost:4620` (never production);
   - a static host for the packed engine on **4622** (`engine-server.mjs`);
   - fake Google Drive, Microsoft 365 and Dropbox on **4623** (`fake-providers.mjs`).
3. `global-setup.js` writes a signed-in browser state per seeded person and warms Vite.

Sealing (F7, F7b) runs in org `e2e-seal`. Its people get identity keys from the real client
(`lib/e2eeStore.js setupIdentity`) in a real browser during global setup, and every sealed item
is made by the real browser crypto against the real API and Garage: nothing is faked. The
sealed dump check greps a `pg_dump` of `api_e2e_disk` and the whole e2e bucket
(`bin/rails e2e:disk:bucket_scan`).

Importers (F10) run end to end against `fake-providers.mjs`: one small server that grants
consent straight back to the API's callback, exchanges tokens (including Google's
service-account grant and Microsoft's tenant admin consent) and answers the Drive, Graph and
Dropbox calls the adapters make, over one fixed tree (nested folders, a Doc, a Sheet, Slides,
a file whose hash never matches, a no-content item, a shared space, two people). The e2e Rails
points every importer endpoint there through `DISK_IMPORT_<P>_<NAME>_URL` (`env.js`), which the
API refuses in production. Specs flip the fake's state through `POST /_ctl/<provider>`: a second
pass (a change, a rename, a deletion), a 429 with Retry-After, Microsoft's 410 on the delta
link, a revoked grant, Dropbox's transfer cap, a Google Doc over the 5 MB page limit, and holding downloads to watch progress or
cancel. Import jobs run in the Rails process (Active Job's async adapter, the development
default). Nothing reaches a real provider. Org `e2e-imp`: Ivy imports; Cal is matched by the
email he signs in with. The seeded import rows in `e2e-disk` remain for the screenshots.

Signing out across tabs (`signout.spec.js`) signs in afresh through `POST /auth/login`
(`support.js freshSession`), so its sign-outs end those sessions only, never the seeded ones.

The seed (all passwords `e2e-pass-123`): org `e2e-disk` on max with an owner, an admin, Ana and
Ben (members), Vic (a viewer of Marketing), Nina (empty C:\) and Leo (a leaver); shares
Marketing (assigned), Finance (admin only) and Handbook (open to everyone); a file of every
preview type in `D:\Marketing\Samples`; a deep `C:\Clients\Acme\2026\Q1\Invoices`; a file with
three versions; pages; public links (open, password `open-sesame`, hidden download, expired,
revoked, folder); an agent with an `agt_` key; one MX mail with an attachment. Other orgs:
`e2e-other` (isolation), `e2e-nodisk` (paywall), `e2e-readonly` (downgraded), `e2e-full` and
`e2e-warn` (quota states).

Tests never depend on each other's leftovers: anything a test changes lives in a folder it
makes with a unique name. Every run starts from a fresh seed, so it is safe to repeat and to
run in CI.

## Browsers

Chromium runs everything. Firefox and WebKit run the `@smoke` subset: browse, upload, a PDF
preview, a public link, phone width.

## Screenshots

`yarn e2e:disk:screens` writes `screens/desktop/*.png` (1440x900) and `screens/phone/*.png`
(390x844). The folder is gitignored. Rerun the command to update them.

## Debugging

Keep the servers up between runs: `node e2e/disk/prepare.mjs`, start Rails, Vite, the fake providers and the
engine host the way `playwright.config.js` does, then
`E2E_DISK_REUSE=1 npx playwright test -c e2e/disk/playwright.config.js --project=chromium <file>`.
Failures leave a trace and a screenshot in `.state/results/`
(`npx playwright show-trace <trace.zip>`).

## Known limits

- The zip and org-export tests remove `showSaveFilePicker` first (a headless browser cannot
  answer the save dialog), so they drive the Blob path Safari and Firefox take.
- `@axe-core/playwright` is not installed, so the accessibility test is skipped.
- Sealed tests reach into the app's own modules (`sealedSupport.js appImport`) for set-up
  steps such as unlocking and capturing a holder's key; the UI paths are tested separately.
- The seed and the mail tests (F9) write a few small objects to the development attachments bucket (`inbox2-attachments`); there is no environment switch for that bucket outside production.
- The Rails server runs in the development environment, so it appends to `api/log/development.log`.
- Run it when no one is mid-change in `api/` or `src/`: Rails and Vite reload code under the suite, and a half-saved file fails the tests that touch it.
- The importers run against fakes written from the providers' documentation, not recorded
  traffic: a real account can still answer in ways the fake does not (paging edge cases,
  Paper and Google-in-Dropbox exports, Microsoft's resync semantics, real rate limits).
