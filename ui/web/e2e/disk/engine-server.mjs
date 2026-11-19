#!/usr/bin/env node
// Serves the packed exact-view engine (scripts/disk-engine-pack.mjs output) the
// way disk-engine-pack.mjs says a host must: parts as octet-stream with no
// Content-Encoding, CORS for the app's origin, and Cross-Origin-Resource-Policy
// so the isolated engine page may load them.
//   node engine-server.mjs <dir> <port> <app-origin>
import http from 'node:http'
import fs from 'node:fs'
import path from 'node:path'

const [dir, port, origin] = process.argv.slice(2)
http.createServer((req, res) => {
  const file = path.join(dir, path.normalize(decodeURIComponent(new URL(req.url, 'http://x').pathname)).replace(/^(\.\.[/\\])+/, ''))
  const headers = {
    'Access-Control-Allow-Origin': origin,
    'Cross-Origin-Resource-Policy': 'cross-origin',
    'Cache-Control': file.endsWith('manifest.json') ? 'no-cache' : 'public, max-age=31536000, immutable',
  }
  if (req.method === 'OPTIONS') { res.writeHead(204, { ...headers, 'Access-Control-Allow-Headers': '*' }); return res.end() }
  fs.stat(file, (err, st) => {
    if (err || !st.isFile()) { res.writeHead(404, headers); return res.end() }
    res.writeHead(200, { ...headers, 'Content-Type': file.endsWith('.json') ? 'application/json' : 'application/octet-stream', 'Content-Length': st.size })
    fs.createReadStream(file).pipe(res)
  })
}).listen(Number(port))
