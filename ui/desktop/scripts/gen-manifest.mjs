#!/usr/bin/env node
// Generate the Tauri updater manifest (latest.json) from a directory of built
// bundles + their `.sig` files (collected from the three OS build jobs).
//
// Emits <outDir>/latest.json, whose `platforms` map holds BOTH the canonical
// `{target}-{arch}` keys (Tauri's primary lookup) AND the multi-installer
// `{target}-{arch}-{installer}` keys (deb/rpm/appimage/nsis/app). That way a
// single-file endpoint and a templated per-target endpoint both resolve.
//
// The `signature` field is the *content* of each `.sig` file (not a path/URL).
//
// Usage:
//   node gen-manifest.mjs --artifacts <dir> --out <dir> \
//        --version 1.2.3 --base-url https://host/path [--notes "..."] [--date ISO]
//   (or via env: ARTIFACTS_DIR, OUT_DIR, RELEASE_VERSION, MANIFEST_BASE_URL,
//    RELEASE_NOTES, PUB_DATE)

import { readdirSync, readFileSync, mkdirSync, writeFileSync } from 'node:fs';
import { join, basename } from 'node:path';

function arg(name, envName, fallback) {
  const i = process.argv.indexOf(`--${name}`);
  if (i !== -1 && process.argv[i + 1]) return process.argv[i + 1];
  if (envName && process.env[envName]) return process.env[envName];
  return fallback;
}

const ARTIFACTS = arg('artifacts', 'ARTIFACTS_DIR');
const OUT = arg('out', 'OUT_DIR', 'dist-manifest');
const VERSION = arg('version', 'RELEASE_VERSION');
const BASE_URL = arg('base-url', 'MANIFEST_BASE_URL');
const NOTES = arg('notes', 'RELEASE_NOTES', '');
const PUB_DATE = arg('date', 'PUB_DATE', new Date().toISOString());
// Which arch the macOS .app.tar.gz targets (its filename carries no arch):
// 'universal' → both, 'aarch64'/'x86_64' → that one only.
const MAC_ARCH = arg('mac-arch', 'MAC_ARCH', 'universal');

if (!ARTIFACTS || !VERSION || !BASE_URL) {
  console.error('error: --artifacts, --version and --base-url are required');
  process.exit(1);
}

// Map a bundle filename to { installer, arches, target }. Returns null for files
// we don't recognise as an updatable bundle.
function classify(file) {
  const f = file.toLowerCase();
  // Explicit arch token in the filename, or null when none is present.
  const explicitArch = (() => {
    if (/universal/.test(f)) return ['x86_64', 'aarch64']; // mac universal serves both
    if (/aarch64|arm64/.test(f)) return ['aarch64'];
    if (/x86_64|amd64|x64/.test(f)) return ['x86_64'];
    return null;
  })();

  // macOS updater artifact (`Inbox2.app.tar.gz`) carries NO arch in its name, so
  // fall back to the build-declared --mac-arch ('universal' → both) rather than
  // guessing — otherwise an arm64-only build would be offered to Intel Macs.
  if (f.endsWith('.app.tar.gz')) {
    const macArches = explicitArch
      || (MAC_ARCH === 'universal' ? ['x86_64', 'aarch64'] : [MAC_ARCH]);
    return { installer: 'app', target: 'darwin', arches: macArches };
  }
  const arches = explicitArch || ['x86_64'];
  if (f.endsWith('.appimage')) return { installer: 'appimage', target: 'linux', arches };
  if (f.endsWith('.deb')) return { installer: 'deb', target: 'linux', arches };
  if (f.endsWith('.rpm')) return { installer: 'rpm', target: 'linux', arches };
  if (f.endsWith('.exe')) return { installer: 'nsis', target: 'windows', arches };
  return null;
}

// The installer Tauri picks for the bare `{target}-{arch}` key (the running app
// updates in place with its own installer kind; this is the default when the
// build type can't be determined).
const PRIMARY = { darwin: 'app', windows: 'nsis', linux: 'appimage' };

// Walk the artifacts dir (one level + nested per-job subdirs) for `.sig` files —
// a `.sig` means "this bundle is an updater artifact".
function findSigs(dir) {
  const out = [];
  for (const entry of readdirSync(dir, { withFileTypes: true })) {
    const p = join(dir, entry.name);
    if (entry.isDirectory()) out.push(...findSigs(p));
    else if (entry.name.endsWith('.sig')) out.push(p);
  }
  return out;
}

const platforms = {};
let count = 0;

for (const sigPath of findSigs(ARTIFACTS)) {
  const bundle = basename(sigPath).replace(/\.sig$/, '');
  const cls = classify(bundle);
  if (!cls) {
    console.warn(`skip (unrecognised): ${bundle}`);
    continue;
  }
  const signature = readFileSync(sigPath, 'utf8').trim();
  const url = `${BASE_URL.replace(/\/$/, '')}/${bundle}`;
  const entry = { signature, url };

  for (const arch of cls.arches) {
    // Multi-installer key (always set).
    platforms[`${cls.target}-${arch}-${cls.installer}`] = entry;
    // Canonical key — only the primary installer claims it.
    if (cls.installer === PRIMARY[cls.target]) {
      platforms[`${cls.target}-${arch}`] = entry;
    }
  }
  count++;
}

// A platform whose primary installer is absent (the deb-only Linux release
// bin/release-desktop produces) still gets its bare key, from whatever
// installer it does have — otherwise a client that can't tell its bundle type
// would see no Linux entry at all.
for (const key of Object.keys(platforms)) {
  const bare = key.replace(/-(app|nsis|appimage|deb|rpm)$/, '');
  if (bare !== key && !platforms[bare]) platforms[bare] = platforms[key];
}

if (count === 0) {
  console.error(`error: no updater bundles (.sig files) found under ${ARTIFACTS}`);
  process.exit(1);
}

const manifest = {
  version: VERSION.replace(/^v/, ''),
  notes: NOTES,
  pub_date: PUB_DATE,
  platforms,
};

// Write the combined manifest.
mkdirSync(OUT, { recursive: true });
const json = JSON.stringify(manifest, null, 2);
writeFileSync(join(OUT, 'latest.json'), json);

console.log(`manifest: ${count} bundle(s), ${Object.keys(platforms).length} platform keys`);
console.log(`  version ${manifest.version}  date ${manifest.pub_date}`);
console.log(`  → ${join(OUT, 'latest.json')}`);
console.log(json);
