#!/usr/bin/env node
// Step one of `yarn e2e:disk`: a clean world before Playwright starts the servers.
//   1. the ports are free and local Garage answers on :4900
//   2. sample files exist (made once with ffmpeg and zip, then cached)
//   3. the e2e database is dropped, recreated from schema.rb and seeded
//      (api/lib/tasks/e2e_disk.rake), which also empties the e2e bucket
// Nothing here touches api_development, api_test or the dev bucket.
import { execFileSync } from 'node:child_process'
import fs from 'node:fs'
import net from 'node:net'
import path from 'node:path'
import { API, BUCKET, DB, ENGINE_PORT, FAKE_PORT, GARAGE_PORT, RAILS_PORT, SAMPLES, SEED, STATE, WEB_PORT, railsEnv } from './env.js'

const SPIKE = path.resolve(API, '../docs/plans/disk-design/engine-spike/samples')

const portOpen = (port) => new Promise((resolve) => {
  const s = net.connect(port, '127.0.0.1')
  s.once('connect', () => { s.destroy(); resolve(true) })
  s.once('error', () => resolve(false))
})

function run(cmd, args, opts = {}) {
  execFileSync(cmd, args, { stdio: 'inherit', ...opts })
}

/** A small text PDF with `pages` pages; page 3 says "zebra" for the search test. */
function pdf(pages) {
  const objs = []
  const add = (s) => { objs.push(s); return objs.length }
  const font = add('<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>')
  const kids = []
  const pagesId = objs.length + 1 + pages * 2 // reserved after the page objects
  for (let i = 1; i <= pages; i++) {
    const text = `BT /F1 28 Tf 72 700 Td (E2E handbook page ${i} of ${pages}) Tj 0 -40 Td (${i === 3 ? 'The zebra is on page three.' : 'Nothing special here.'}) Tj ET`
    const content = add(`<< /Length ${text.length} >>\nstream\n${text}\nendstream`)
    kids.push(add(`<< /Type /Page /Parent ${pagesId} 0 R /MediaBox [0 0 612 792] /Resources << /Font << /F1 ${font} 0 R >> >> /Contents ${content} 0 R >>`))
  }
  add(`<< /Type /Pages /Kids [${kids.map((k) => `${k} 0 R`).join(' ')}] /Count ${pages} >>`)
  const catalog = add(`<< /Type /Catalog /Pages ${pagesId} 0 R >>`)
  let body = '%PDF-1.4\n'
  const offsets = objs.map((o, i) => { const at = body.length; body += `${i + 1} 0 obj\n${o}\nendobj\n`; return at })
  const xref = body.length
  body += `xref\n0 ${objs.length + 1}\n0000000000 65535 f \n${offsets.map((o) => `${String(o).padStart(10, '0')} 00000 n \n`).join('')}`
  body += `trailer\n<< /Size ${objs.length + 1} /Root ${catalog} 0 R >>\nstartxref\n${xref}\n%%EOF\n`
  return body
}

function samples() {
  if (fs.existsSync(path.join(SAMPLES, '.done'))) return
  fs.mkdirSync(SAMPLES, { recursive: true })
  const at = (n) => path.join(SAMPLES, n)
  const ff = (...args) => run('ffmpeg', ['-loglevel', 'error', '-y', ...args])
  ff('-f', 'lavfi', '-i', 'testsrc=size=640x360:rate=1', '-frames:v', '1', at('hero-banner.png'))
  ff('-f', 'lavfi', '-i', 'smptebars=size=800x600:rate=1', '-frames:v', '1', at('photo.jpg'))
  ff('-f', 'lavfi', '-i', 'testsrc=size=320x240:rate=25', '-f', 'lavfi', '-i', 'sine=frequency=440', '-t', '4',
    '-c:v', 'libx264', '-pix_fmt', 'yuv420p', '-c:a', 'aac', '-shortest', '-movflags', '+faststart', at('clip.mp4'))
  ff('-f', 'lavfi', '-i', 'sine=frequency=330', '-t', '4', '-c:a', 'aac', at('voice.m4a'))
  fs.writeFileSync(at('report.pdf'), pdf(5))
  fs.copyFileSync(path.join(SPIKE, 'broken.pdf'), at('broken.pdf'))
  for (const f of ['plan.docx', 'budget.xlsx', 'deck.pptx']) fs.copyFileSync(path.join(SPIKE, f), at(f))
  fs.writeFileSync(at('diagram.svg'), '<svg xmlns="http://www.w3.org/2000/svg" width="200" height="120"><script>window.parent.__svgRan = true</script><rect width="200" height="120" fill="#2f7ad6"/><text x="20" y="70" fill="#fff" font-size="24">diagram</text></svg>\n')
  fs.writeFileSync(at('notes.md'), '# Release notes\n\n## What changed\n\n- Faster uploads\n- [ ] Write docs\n\n```js\nconsole.log("hi")\n```\n')
  fs.writeFileSync(at('brief.md'), '# Launch brief\n\nThe hero banner lives in Assets.\n')
  fs.writeFileSync(at('app.js'), 'export function greet(name) {\n  return `Hello, ${name}`\n}\n\nconsole.log(greet("e2e"))\n')
  fs.writeFileSync(at('page.html'), '<!doctype html><html><body><h1>Uploaded HTML</h1><script>window.parent.__htmlRan = true</script></body></html>\n')
  fs.writeFileSync(at('data.csv'), 'quarter,revenue,costs\nQ1,100,80\nQ2,120,90\nQ3,140,95\n')
  fs.writeFileSync(at('design.fig'), Buffer.from('fig-kiwi-e2e-not-a-real-figma-file'))
  fs.writeFileSync(at('server.log'), Array.from({ length: 400 }, (_, i) => `2026-10-03T12:00:${String(i % 60).padStart(2, '0')}Z INFO line ${i + 1}`).join('\n') + '\n')
  // A zip of two entries, made from the files above.
  run('zip', ['-q', '-j', at('bundle.zip'), at('notes.md'), at('data.csv')])
  fs.writeFileSync(path.join(SAMPLES, '.done'), new Date().toISOString())
}

async function main() {
  const t0 = Date.now()
  fs.mkdirSync(STATE, { recursive: true })
  for (const port of [RAILS_PORT, WEB_PORT, ENGINE_PORT, FAKE_PORT]) {
    if (await portOpen(port)) throw new Error(`port ${port} is in use; the Disk e2e harness starts its own servers there. Stop whatever holds it (lsof -nP -iTCP:${port}).`)
  }
  if (!await portOpen(GARAGE_PORT)) {
    throw new Error(`local Garage is not answering on :${GARAGE_PORT}. Start it: docker compose -f docker/docker-compose.yml --profile storage up -d && bin/garage-init`)
  }
  samples()
  // A 200-page PDF (F5: open at page 1, jump to page 150).
  if (!fs.existsSync(path.join(SAMPLES, 'pages200.pdf'))) fs.writeFileSync(path.join(SAMPLES, 'pages200.pdf'), pdf(200))
  // E2E_DISK_LARGE=1: the sizes the spec names (a 1 GB upload and zip, a 500 MB sealed video), made once.
  if (process.env.E2E_DISK_LARGE) {
    const gb = path.join(SAMPLES, 'one-gb.bin')
    if (!fs.existsSync(gb)) run('dd', ['if=/dev/urandom', `of=${gb}`, 'bs=1048576', 'count=1024', 'status=none'])
    const zip = path.join(SAMPLES, 'one-gb.zip')
    if (!fs.existsSync(zip)) run('zip', ['-q', '-0', '-j', zip, gb, path.join(SAMPLES, 'notes.md')])
    const mp4 = path.join(SAMPLES, 'big500.mp4')
    if (!fs.existsSync(mp4)) {
      run('ffmpeg', ['-loglevel', 'error', '-y', '-f', 'lavfi', '-i', 'testsrc2=size=1920x1080:rate=30', '-f', 'lavfi', '-i', 'sine=frequency=440',
        '-t', '80', '-c:v', 'libx264', '-preset', 'ultrafast', '-b:v', '52M', '-minrate', '52M', '-maxrate', '52M', '-bufsize', '26M', '-x264-params', 'nal-hrd=cbr', '-pix_fmt', 'yuv420p', '-c:a', 'aac', '-shortest', '-movflags', '+faststart', mp4])
    }
  }
  // A larger video for sealed seeking (F7): about 40 MB, made once.
  const bigVideo = path.join(SAMPLES, 'long.mp4')
  if (!fs.existsSync(bigVideo)) {
    run('ffmpeg', ['-loglevel', 'error', '-y', '-f', 'lavfi', '-i', 'testsrc2=size=1280x720:rate=30', '-f', 'lavfi', '-i', 'sine=frequency=500',
      '-t', '60', '-c:v', 'libx264', '-b:v', '5M', '-pix_fmt', 'yuv420p', '-c:a', 'aac', '-shortest', '-movflags', '+faststart', bigVideo])
  }
  // The exact-view engine, packed once (about 75 MB) and served by engine-server.mjs.
  if (!fs.existsSync(path.join(STATE, 'engine', 'manifest.json'))) run('node', [path.resolve(API, '../ui/web/scripts/disk-engine-pack.mjs'), path.join(STATE, 'engine')])

  // The e2e bucket, made the way bin/garage-init makes the dev ones (the app key may not create buckets).
  const garage = (...args) => execFileSync('docker', ['compose', '-f', path.resolve(API, '../docker/docker-compose.yml'), 'exec', '-T', 'garage', '/garage', ...args], { stdio: 'pipe' })
  try { garage('bucket', 'info', BUCKET) } catch { garage('bucket', 'create', BUCKET) }
  garage('bucket', 'allow', '--read', '--write', '--owner', BUCKET, '--key', process.env.S3_ACCESS_KEY || 'GK1b0a5c9d3e7f2a8b4c6d0e12')

  const env = railsEnv()
  run('dropdb', ['--if-exists', '--force', DB])
  run('createdb', [DB])
  run('bin/rails', ['db:schema:load'], { cwd: API, env })
  // Migrations newer than schema.rb (someone mid-change in api/). SCHEMA points the
  // development env's after-migrate dump into .state, so api/db/schema.rb is never written.
  run('bin/rails', ['db:migrate'], { cwd: API, env: { ...env, SCHEMA: path.join(STATE, 'schema-after-migrate.rb') } })
  fs.rmSync(SEED, { force: true })
  run('bin/rails', ['e2e:disk:seed'], { cwd: API, env: { ...env, E2E_DISK_SAMPLES: SAMPLES, E2E_DISK_SEED_OUT: SEED } })
  console.log(`e2e:disk prepared in ${((Date.now() - t0) / 1000).toFixed(1)}s`)
}

main().catch((e) => { console.error(e.message); process.exit(1) })
