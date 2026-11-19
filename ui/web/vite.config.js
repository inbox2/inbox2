/// <reference types="vitest/config" />
import { defineConfig, createLogger } from 'vite';
import react from '@vitejs/plugin-react';

import path from 'node:path';
import { readFileSync } from 'node:fs';
import http from 'node:http';
import https from 'node:https';
import { fileURLToPath } from 'node:url';
import { storybookTest } from '@storybook/addon-vitest/vitest-plugin';
import { playwright } from '@vitest/browser-playwright';
const dirname = typeof __dirname !== 'undefined' ? __dirname : path.dirname(fileURLToPath(import.meta.url));

// Where /api and /cable proxy to. Default is the hosted prod deployment (so the
// desktop app gets working cloud push without a Tailscale Funnel); export
// INBOX2_API_ORIGIN=http://localhost:4000 to develop against a local Rails.
const apiOrigin = process.env.INBOX2_API_ORIGIN || 'https://api.inbox2.com';

// api.inbox2.com is dual-stack (Cloudflare publishes AAAA). On a network with
// broken IPv6 — hotel/airport wifi, most VPNs — Node tries the AAAA addresses,
// times out after ~510ms and the proxy answers 502 with an empty body, while
// curl and the browser fall back to IPv4 and work fine. That looked exactly
// like "prod is down": 5,706 failed /api calls over five days in Aug 2026, the
// desktop app stuck on a login screen, with a perfectly healthy API. Pin the
// upstream to IPv4 — Cloudflare always answers there.
// ponytail: no fallback logic; if IPv6-only networks ever matter, make it an env flag.
const proxyAgent = apiOrigin.startsWith('https:')
  ? new https.Agent({ family: 4, keepAlive: true })
  : new http.Agent({ family: 4, keepAlive: true });

// Tauri/HMR restarts tear down in-flight proxied WebSocket + API connections,
// which Vite surfaces as `(ws|http) proxy (socket )?error` with a full stack
// trace. These are benign client-disconnect races (EPIPE/ECONNRESET), so
// downgrade them to a single-line warning instead of a multi-line stack dump.
const logger = createLogger();
const baseError = logger.error.bind(logger);
logger.error = (msg, opts) => {
  const code = opts?.error?.code;
  const isProxyDisconnect =
    /proxy (socket )?error/.test(msg) &&
    (code === 'EPIPE' || code === 'ECONNRESET' || code === 'ECANCELED');
  if (isProxyDisconnect) {
    const kind = /ws proxy/.test(msg) ? 'ws' : 'http';
    logger.warn(`[vite] ${kind} proxy disconnected (${code}) — likely a client/HMR restart`);
    return;
  }
  baseError(msg, opts);
};

// Only the Disk exact-view engine page is cross-origin isolated (public/_headers
// does the same on Cloudflare Pages; src/lib/disk/engine/client.js explains why).
const ENGINE_PAGE = /^\/disk-engine(\.html)?$/;
function isolateEnginePage(req, res, next) {
  if (ENGINE_PAGE.test((req.url || '').split('?')[0])) {
    res.setHeader('Cross-Origin-Opener-Policy', 'same-origin');
    res.setHeader('Cross-Origin-Embedder-Policy', 'require-corp');
  }
  next();
}
const diskEngineIsolation = {
  name: 'disk-engine-isolation',
  configureServer: (server) => { server.middlewares.use(isolateEnginePage); },
  configurePreviewServer: (server) => { server.middlewares.use(isolateEnginePage); },
};

// The Disk service worker (src/lib/disk/sw.js) is a classic script: browsers
// give service workers no dynamic import, and importScripts only works in a
// classic worker. It is served as one file, libsodium first, at /disk-sw.js.
function diskWorkerSource() {
  const read = (p) => readFileSync(p, 'utf8');
  return [
    read(path.resolve(dirname, 'node_modules/libsodium-sumo/dist/modules-sumo/libsodium-sumo.js')),
    read(path.resolve(dirname, 'node_modules/libsodium-wrappers-sumo/dist/modules-sumo/libsodium-wrappers.js')),
    read(path.resolve(dirname, 'src/lib/disk/sw.js')),
  ].join(';\n');
}
const DISK_SW = '/disk-sw.js';
const diskServiceWorker = {
  name: 'disk-service-worker',
  configureServer(server) {
    server.middlewares.use((req, res, next) => {
      if ((req.url || '').split('?')[0] !== DISK_SW) return next();
      res.setHeader('Content-Type', 'text/javascript');
      res.setHeader('Cache-Control', 'no-cache');
      res.end(diskWorkerSource());
    });
  },
  generateBundle() {
    this.emitFile({ type: 'asset', fileName: DISK_SW.slice(1), source: diskWorkerSource() });
  },
};

export default defineConfig({
  customLogger: logger,
  plugins: [react(), diskEngineIsolation, diskServiceWorker],
  resolve: {
    alias: {
      // The framework-free email-body package (quote/signature collapsing +
      // remote-image privacy), shared with the native mobile WebViews. Kept a
      // separate package; resolved by source here so dev edits are live.
      '@inbox2/email-body': path.resolve(dirname, '../../packages/email-body/src/index.js'),
    },
  },
  server: {
    port: 4173,
    // Allow serving the sibling @inbox2/email-body package (outside this app's
    // root) so its source + tests resolve in dev and under vitest.
    fs: {
      allow: [path.resolve(dirname, '..', '..')],
    },
    proxy: {
      '/api': {
        target: apiOrigin,
        changeOrigin: true,
        agent: proxyAgent, // IPv4-only — see proxyAgent above
        // The API session is an HttpOnly cookie. When proxying to a remote origin
        // (prod default) the Set-Cookie carries Domain=api.inbox2.com, which the
        // browser rejects on localhost — so the session is lost on every reload
        // and /console bounces to /login. Strip the Domain so the cookie binds to
        // localhost, and drop Secure so it survives http://localhost in all browsers.
        cookieDomainRewrite: '',
        configure: (proxy) => {
          proxy.on('proxyRes', (proxyRes) => {
            const sc = proxyRes.headers['set-cookie'];
            if (sc) {
              proxyRes.headers['set-cookie'] = sc.map((c) =>
                c.replace(/;\s*Secure/gi, '').replace(/;\s*SameSite=None/gi, '; SameSite=Lax'),
              );
            }
          });
        },
      },
      '/cable': {
        target: apiOrigin.replace(/^http/, 'ws'),
        ws: true,
        changeOrigin: true,
        agent: proxyAgent,
      },
    },
  },
  build: {
    // Two pages: the app, and the isolated Disk exact-view engine host.
    rolldownOptions: {
      input: {
        main: path.resolve(dirname, 'index.html'),
        diskEngine: path.resolve(dirname, 'disk-engine.html'),
      },
    },
  },
  test: {
    projects: [
      {
        extends: true,
        test: {
          name: 'unit',
          include: [
            'src/**/__tests__/**/*.test.{js,jsx}',
            '../../packages/email-body/__tests__/**/*.test.js',
          ],
          environment: 'node',
        }
      },
      {
        extends: true,
        plugins: [
          storybookTest({
            configDir: path.join(dirname, '.storybook')
          })
        ],
        test: {
          name: 'storybook',
          browser: {
            enabled: true,
            headless: true,
            provider: playwright({}),
            instances: [{ browser: 'chromium' }]
          }
        }
      }
    ]
  }
});
