// Build the DropBlock game into one self-contained HTML for the native iOS
// WebView overlay (ui/ios/Resources/dropblock-game.html).
//
// It bundles the real React component (esbuild) and inlines the sprite PNGs as
// data URIs on window.__DROPBLOCK_ASSETS, so the WebView can load it with
// loadHTMLString — no HTTP origin and no separate asset files needed.
//
//   node scripts/build-dropblock-embed.mjs      (run from ui/web)
import { build } from 'esbuild';
import { readFile, writeFile, mkdir, readdir } from 'node:fs/promises';
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const here = dirname(fileURLToPath(import.meta.url));
const webRoot = resolve(here, '..');                              // ui/web
const outFile = resolve(webRoot, '../ios/Resources/dropblock-game.html');

// 1. Bundle JS + CSS (React + the component + CSS modules) to memory.
const result = await build({
  entryPoints: [resolve(webRoot, 'src/dropblock-embed.jsx')],
  bundle: true,
  format: 'iife',
  jsx: 'automatic',
  minify: true,
  define: { 'process.env.NODE_ENV': '"production"' },
  loader: { '.png': 'dataurl', '.woff': 'dataurl', '.woff2': 'dataurl', '.ttf': 'dataurl' },
  write: false,
  outdir: 'dropblock-embed-out',
});
let js = '';
let css = '';
for (const f of result.outputFiles) {
  if (f.path.endsWith('.css')) css = f.text;
  else if (f.path.endsWith('.js')) js = f.text;
}

// 2. Inline the sprites + logo as data URIs, keyed by their public path.
// Sprite list is derived from public/dropblock/ so new sprites are picked up
// automatically and can't silently fall out of sync with a hardcoded list.
const pub = resolve(webRoot, 'public');
const sprites = (await readdir(resolve(pub, 'dropblock')))
  .filter((f) => f.endsWith('.png'))
  .sort()
  .map((f) => `/dropblock/${f}`);
const assetPaths = [...sprites, '/logo-mark.png'];
const assets = {};
for (const p of assetPaths) {
  try {
    const buf = await readFile(resolve(pub, '.' + p));
    assets[p] = `data:image/png;base64,${buf.toString('base64')}`;
  } catch {
    console.warn('⚠ missing asset (skipped):', p);
  }
}

// 3. Assemble the self-contained HTML.
const html = `<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1, maximum-scale=1, user-scalable=no, viewport-fit=cover">
<title>DropBlock</title>
<style>
html,body{margin:0;height:100%;background:#0a0e16;overflow:hidden;}
body{-webkit-user-select:none;user-select:none;-webkit-touch-callout:none;-webkit-tap-highlight-color:transparent;}
#root{position:relative;width:100vw;height:100dvh;}
${css}
</style>
</head>
<body data-theme="dark">
<div id="root"></div>
<script>window.__DROPBLOCK_ASSETS=${JSON.stringify(assets)};window.__INBOX_NATIVE=true;</script>
<script>${js}</script>
</body>
</html>
`;

await mkdir(dirname(outFile), { recursive: true });
await writeFile(outFile, html, 'utf8');
console.log(`✓ wrote ${outFile} (${Math.round(html.length / 1024)} KB)`);
