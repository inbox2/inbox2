#!/usr/bin/env node
// Local app installer (macOS).
//
// Builds the Tauri desktop app for THIS machine, Developer-ID-signs it, and
// installs the .app into /Applications so you can run it like any other app.
// Two identities that live side by side (separate Dock icons, separate data
// dirs, separate Keychain credential keys — can run at the same time):
//
//   yarn install:app        Inbox2      (com.inbox2.desktop,     real mail)
//   yarn install:app:dev    Inbox2 Dev  (com.inbox2.desktop.dev, golden badge,
//                                         the fake/demo database)
//
// The dev identity is the SAME one `yarn dev` uses, so the bundled "Inbox2 Dev"
// app and the `yarn dev` loop share one data dir + Keychain key.
//
// Signing: picks the best identity in the keychain (Developer ID, else Apple
// Development) and fails fast if there is none. Override or disable:
//   APPLE_SIGNING_IDENTITY="Developer ID Application: …"   exact string
//   APPLE_SIGNING_IDENTITY="-"                             ad-hoc / unsigned
// Notarization is intentionally skipped — a locally-built, locally-signed app
// launches without it (no quarantine attribute). The Keychain ACL is stable
// because the Developer ID signature is stable across rebuilds, so stored
// mailbox credentials aren't re-prompted.
//
// The Inbox2 (prod) build carries the real updater config and a real version,
// so a local install stays in the update stream — the next `bin/release-desktop`
// reaches it like any other machine. See docs/Desktop-Release.md.

import { execFileSync } from 'node:child_process';
import { readdirSync, readFileSync, rmSync, cpSync, existsSync, statSync } from 'node:fs';
import { dirname, resolve, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { platform } from 'node:os';

const __dirname = dirname(fileURLToPath(import.meta.url));
const DESKTOP_DIR = resolve(__dirname, '..');
const ROOT = resolve(DESKTOP_DIR, '../..');
const BUNDLE_MACOS = resolve(DESKTOP_DIR, 'target/release/bundle/macos');
const APPLICATIONS = '/Applications';

// Signing identities we'll pick from, best first.
//
// What actually matters here is that the signature is STABLE, not that it's
// distributable: macOS pins a Keychain "Always Allow" grant to the binary's code
// identity, and the app reads the credential master key from the Keychain on every
// launch. A stable cert means one prompt ever. Ad-hoc ("-") changes the cdhash on
// every rebuild, so the grant is void and macOS asks for the login password each
// time you launch — see the same trap in core/src/sync/crypto.rs for debug builds.
//
// Developer ID is the right identity for something you hand to other people (and
// what `bin/release-desktop` needs). An Apple Development cert is enough for an app
// installed on this Mac and is what a dev machine usually has. Override with
// APPLE_SIGNING_IDENTITY (exact string, or "-" for ad-hoc).
const IDENTITY_PREFERENCE = [/^Developer ID Application:/, /^Apple Development:/];

// Signing identities present in the keychain, in `security` order.
function availableIdentities() {
  try {
    const out = execFileSync('security', ['find-identity', '-v', '-p', 'codesigning'], {
      encoding: 'utf8',
    });
    return [...out.matchAll(/^\s*\d+\)\s+\S+\s+"([^"]+)"/gm)].map((m) => m[1]);
  } catch {
    return [];
  }
}

// Resolve before building — a missing cert otherwise surfaces as an opaque
// "failed to bundle project: failed codesign application" after a full Rust
// compile, which is a long way to travel for a one-line problem.
function resolveSigningIdentity() {
  const available = availableIdentities();
  const requested = process.env.APPLE_SIGNING_IDENTITY;

  if (requested === '-') return '-';
  if (requested) {
    if (!available.includes(requested)) {
      console.error(
        `error: APPLE_SIGNING_IDENTITY is set to "${requested}", which isn't in the keychain.\n` +
        `  Available: ${available.length ? available.map((i) => `\n    ${i}`).join('') : '(none)'}\n` +
        '  Use APPLE_SIGNING_IDENTITY="-" to sign ad-hoc instead.'
      );
      process.exit(1);
    }
    return requested;
  }

  for (const pattern of IDENTITY_PREFERENCE) {
    const found = available.find((i) => pattern.test(i));
    if (found) return found;
  }

  console.error(
    'error: no usable code-signing identity found in the keychain.\n' +
    `  Looked for: ${IDENTITY_PREFERENCE.map((p) => String(p).replace(/[/^]/g, '')).join(', ')}\n` +
    `  Available:  ${available.length ? available.map((i) => `\n    ${i}`).join('') : '(none)'}\n` +
    '  Create one in Xcode → Settings → Accounts → Manage Certificates,\n' +
    '  or set APPLE_SIGNING_IDENTITY="-" to sign ad-hoc (expect a Keychain\n' +
    '  password prompt on every launch after a rebuild).'
  );
  process.exit(1);
}

const isDev = process.argv.includes('--dev');

if (platform() !== 'darwin') {
  console.error('install-local.mjs currently supports macOS only.');
  process.exit(1);
}

// The updater block (endpoint + pubkey) lives in tauri.release.conf.json and
// nowhere else; lib.rs only starts the updater plugin when the built config
// carries `plugins.updater`. Read it rather than restating it, so a locally
// installed app sees the same releases every other machine does.
const updaterPlugin = JSON.parse(
  readFileSync(resolve(DESKTOP_DIR, 'src-tauri/tauri.release.conf.json'), 'utf8')
).plugins.updater;

// The same version a release would carry (MAJOR.MINOR + commit count), because
// the updater compares versions: left at tauri.conf.json's 0.1.0 this build
// would read every published release as newer and replace itself on launch.
const appVersion = execFileSync(join(ROOT, 'bin/version'), { encoding: 'utf8' }).trim();

// Identity-specific build inputs.
const plan = isDev
  ? {
      appName: 'Inbox2 Dev.app',
      identifier: 'com.inbox2.desktop.dev',
      // The dev overlay sets productName/identifier/icons + disables updater
      // artifacts; the env var sets the compile-time BUNDLE_ID (data dir +
      // Keychain service) to match.
      configArg: 'src-tauri/tauri.dev.conf.json',
      env: { INBOX2_BUNDLE_ID: 'com.inbox2.desktop.dev' },
    }
  : {
      appName: 'Inbox2.app',
      identifier: 'com.inbox2.desktop',
      // Prod uses the base config (so its beforeBuildCommand still rebuilds the
      // web client) plus the real updater config and version. Updater
      // ARTIFACTS stay off — those exist for other machines to download, and
      // making them would need the updater signing key.
      configArg: JSON.stringify({
        version: appVersion,
        plugins: { updater: updaterPlugin },
        bundle: { createUpdaterArtifacts: false },
      }),
      env: {},
    };

const signingIdentity = resolveSigningIdentity();

function log(m) { console.log(`\x1b[36m•\x1b[0m ${m}`); }

// Refuse to clobber a running copy — macOS keeps the binary mapped and the
// replaced app would be in a half-broken state.
function assertNotRunning() {
  try {
    // Anchored at the start of the command line: the app's own process, not any
    // shell or script that merely mentions the path (a "wait for Inbox2" loop).
    const out = execFileSync('pgrep', ['-f', `^/Applications/${plan.appName}/Contents/MacOS/`], {
      encoding: 'utf8',
    });
    if (out.trim()) {
      console.error(
        `error: ${plan.appName} is running (pid ${out.trim().split('\n').join(', ')}).\n` +
        '  Quit it first, then re-run.'
      );
      process.exit(1);
    }
  } catch {
    /* pgrep exits 1 when nothing matches — that's the good case. */
  }
}

assertNotRunning();

// ── build ─────────────────────────────────────────────────────────────────────
log(`building ${plan.appName} ${isDev ? '' : `${appVersion} `}(${plan.identifier})${signingIdentity === '-' ? ' [ad-hoc]' : ` signed: ${signingIdentity}`}`);
const buildEnv = {
  ...process.env,
  ...plan.env,
  APPLE_SIGNING_IDENTITY: signingIdentity,
};
// Disk in Finder (docs/Disk-Sync.md): the File Provider extension, built and
// signed for this app's id first. Tauri copies it into Contents/PlugIns and
// does not sign nested extensions, so build.sh signs it with its own entitlements.
log('building the Disk in Finder extension');
execFileSync(join(DESKTOP_DIR, 'fileprovider/build.sh'), [], {
  stdio: 'inherit',
  env: { ...buildEnv, INBOX2_APP_ID: plan.identifier },
});
const pluginArg = JSON.stringify({ bundle: { macOS: { files: { 'PlugIns/Inbox2Disk.appex': '../fileprovider/build/Inbox2Disk.appex' } } } });
execFileSync('yarn', ['tauri', 'build', '--bundles', 'app', '-c', plan.configArg, '-c', pluginArg], {
  stdio: 'inherit',
  cwd: DESKTOP_DIR,
  env: buildEnv,
});

// ── locate the freshest matching .app ─────────────────────────────────────────
if (!existsSync(BUNDLE_MACOS)) {
  console.error(`error: bundle dir not found: ${BUNDLE_MACOS}`);
  process.exit(1);
}
const built = join(BUNDLE_MACOS, plan.appName);
if (!existsSync(built)) {
  const found = readdirSync(BUNDLE_MACOS).filter((n) => n.endsWith('.app'));
  console.error(
    `error: expected ${plan.appName} under ${BUNDLE_MACOS}, found: ${found.join(', ') || '(none)'}`
  );
  process.exit(1);
}

// ── install into /Applications ────────────────────────────────────────────────
const dest = join(APPLICATIONS, plan.appName);
if (existsSync(dest)) {
  log(`removing existing ${dest}`);
  rmSync(dest, { recursive: true, force: true });
}
log(`installing → ${dest}`);
cpSync(built, dest, { recursive: true });

// Drop the build-tree bundle once it's installed. It carries the SAME bundle
// identifier as the copy in /Applications, so LaunchServices indexes both and
// Spotlight/Launchpad offer two identical-looking "Inbox2 Dev" entries — while the
// build-tree one goes stale on the next build. Launching that by mistake runs an
// old binary against the live data dir, with nothing on screen to tell you.
// It's a build artifact; `tauri build` regenerates it every time.
rmSync(built, { recursive: true, force: true });

// Strip the quarantine bit just in case (locally built apps usually lack it).
try {
  execFileSync('xattr', ['-dr', 'com.apple.quarantine', dest], { stdio: 'ignore' });
} catch { /* not present — fine */ }

const sizeMB = (() => {
  try {
    return Math.round(
      execFileSync('du', ['-sm', dest], { encoding: 'utf8' }).split('\t')[0]
    );
  } catch { return '?'; }
})();

console.log(`\n\x1b[1mInstalled.\x1b[0m  ${plan.appName}  (${sizeMB} MB)`);
console.log(`  open with:  open -a "${plan.appName.replace(/\.app$/, '')}"`);
if (!isDev) {
  console.log('  data dir:   ~/Library/Application Support/com.inbox2.desktop  (real mail)');
  console.log(`  updates:    ${appVersion} → ${updaterPlugin.endpoints[0]}`);
} else {
  console.log('  data dir:   ~/Library/Application Support/com.inbox2.desktop.dev  (demo data)');
}
