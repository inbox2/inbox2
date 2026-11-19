#!/usr/bin/env node
// Packs the Disk exact-view engine (LibreOffice WASM, @matbee/libreoffice-converter)
// for hosting apart from the app (spec F5b; disk-build.md section 3).
//
//   node scripts/disk-engine-pack.mjs <out-dir>
//
// Writes <out-dir>/manifest.json and <out-dir>/<version>/<file>.gz.NNN parts:
// each file gzip-compressed and cut into 8 MiB parts. The version is a hash of
// the files, so a new converter release gets a new folder and old ones can stay
// until no browser asks for them.
//
// Hosting (VITE_DISK_ENGINE_URL points at the folder holding manifest.json;
// default /disk-engine on the app's own origin):
//   - Cloudflare Pages caps each file at 25 MiB; soffice.wasm is 141 MiB raw and
//     47 MiB gzipped, so the parts are what make same-origin Pages hosting possible
//     at all. Preferred: an R2 bucket (or any CDN) on its own host, so app deploys
//     do not carry ~77 MB of engine.
//   - Serve parts as application/octet-stream with NO Content-Encoding (the browser
//     gunzips them itself after checking each part's sha256), Cache-Control
//     public, max-age=31536000, immutable. manifest.json: Cache-Control no-cache.
//   - From another host: Access-Control-Allow-Origin: <the web app's origin> and
//     Cross-Origin-Resource-Policy: cross-origin on every file (Disk pages are
//     cross-origin isolated).
import { createHash } from 'node:crypto'
import { gzipSync } from 'node:zlib'
import fs from 'node:fs'
import path from 'node:path'
import { createRequire } from 'node:module'

const PART = 8 * 1024 * 1024
const out = process.argv[2]
if (!out) { console.error('usage: disk-engine-pack.mjs <out-dir>'); process.exit(1) }

const pkg = path.dirname(createRequire(import.meta.url).resolve('@matbee/libreoffice-converter/package.json'))
const FILES = {
  'soffice.js': 'wasm/soffice.js',
  'soffice.wasm': 'wasm/soffice.wasm',
  'soffice.data': 'wasm/soffice.data',
  'soffice.worker.js': 'wasm/soffice.worker.js',
  'browser.worker.global.js': 'dist/browser.worker.global.js',
}
const sha = (buf) => createHash('sha256').update(buf).digest('hex')

const files = Object.entries(FILES).map(([name, rel]) => {
  const raw = fs.readFileSync(path.join(pkg, rel))
  console.log(`${name}: ${raw.length} bytes, compressing`)
  return { name, raw, gz: gzipSync(raw, { level: 9 }) }
})
const version = sha(files.map((f) => sha(f.raw)).join('')).slice(0, 16)
const dir = path.join(out, version)
fs.mkdirSync(dir, { recursive: true })

const manifest = {
  version,
  converter: JSON.parse(fs.readFileSync(path.join(pkg, 'package.json'), 'utf8')).version,
  files: files.map(({ name, raw, gz }) => {
    const parts = []
    for (let i = 0, n = 0; i < gz.length; i += PART, n++) {
      const chunk = gz.subarray(i, i + PART)
      const partPath = `${name}.gz.${String(n).padStart(3, '0')}`
      fs.writeFileSync(path.join(dir, partPath), chunk)
      parts.push({ path: partPath, bytes: chunk.length, sha256: sha(chunk) })
    }
    return { name, bytes: raw.length, sha256: sha(raw), parts }
  }),
}
fs.writeFileSync(path.join(out, 'manifest.json'), `${JSON.stringify(manifest, null, 2)}\n`)
const total = manifest.files.reduce((s, f) => s + f.parts.reduce((t, p) => t + p.bytes, 0), 0)
console.log(`engine ${version}: ${manifest.files.length} files, ${total} bytes to download, in ${out}`)
