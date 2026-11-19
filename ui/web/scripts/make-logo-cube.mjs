#!/usr/bin/env node
// Author the inbox2 logo cube as a real GLB: 24 verts, 12 tris, one embedded
// face-atlas texture built from the brand mark's own "2" path (brand/inbox2-mark.svg).
//
// Why authored rather than generated: image-to-3D reconstruction (Higgsfield
// image_to_3d, tried 2026-08-24) returns a ~29k-tri photogrammetry blob with a
// lumpy silhouette and hallucinated detail on the unseen sides — fine for props,
// useless for a hard-surface logo. A cube is eight corners; the exact one is
// smaller, sharper at every angle, and stays on-brand.
//
// Usage: node scripts/make-logo-cube.mjs [out.glb]
import { readFileSync, writeFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';
import { chromium } from 'playwright';

const here = dirname(fileURLToPath(import.meta.url));
const repo = join(here, '..', '..', '..');
const outPath = process.argv[2] || join(here, '..', 'public', 'logo-cube.glb');

// ── 1. Face atlas: [ "2" tile | plain tile ], 2048×1024 ───────────────────────
// The glyph path is lifted verbatim from the brand mark so the cube carries the
// real numeral, not a font's approximation of it.
const markSvg = readFileSync(join(repo, 'brand', 'inbox2-mark.svg'), 'utf8');
const glyphPath = markSvg.match(/<path d="(M56\.9688[^"]+)"/)?.[1];
if (!glyphPath) throw new Error('could not find the "2" path in brand/inbox2-mark.svg');

const TILE = 1024;
const atlasHtml = `<!doctype html><meta charset="utf-8">
<style>html,body{margin:0;background:transparent}</style>
<svg id="a" width="${TILE * 2}" height="${TILE}" viewBox="0 0 2 1" xmlns="http://www.w3.org/2000/svg">
  <defs>
    <!-- Glossy black face: lit from the top edge, falling to near-black at the base. -->
    <linearGradient id="face" x1="0" y1="0" x2="0" y2="1">
      <stop offset="0" stop-color="#31343E"/>
      <stop offset="0.45" stop-color="#181B22"/>
      <stop offset="1" stop-color="#0A0C11"/>
    </linearGradient>
    <!-- Chrome numeral: bright top, steel waist, bright base — the logo's look. -->
    <linearGradient id="chrome" x1="0" y1="0" x2="0" y2="1">
      <stop offset="0" stop-color="#FFFFFF"/>
      <stop offset="0.42" stop-color="#E6E8EE"/>
      <stop offset="0.62" stop-color="#9AA0AC"/>
      <stop offset="1" stop-color="#F2F4F8"/>
    </linearGradient>
  </defs>
  <rect x="0" y="0" width="1" height="1" fill="url(#face)"/>
  <rect x="1" y="0" width="1" height="1" fill="url(#face)"/>
  <g id="glyph" fill="url(#chrome)"><path d="${glyphPath}"/></g>
</svg>
<script>
  // Centre the glyph in the left tile at 58% of its width — measured, not guessed,
  // so a future tweak to the mark can't drift the cube face off-centre.
  const g = document.getElementById('glyph');
  const b = g.getBBox();
  const s = 0.58 / Math.max(b.width, b.height);
  g.setAttribute('transform',
    \`translate(\${0.5 - (b.x + b.width / 2) * s} \${0.5 - (b.y + b.height / 2) * s}) scale(\${s})\`);
  window.__laidOut = true;
</script>`;

const browser = await chromium.launch();
const page = await browser.newPage({ viewport: { width: TILE * 2, height: TILE } });
await page.setContent(atlasHtml);
await page.waitForFunction('window.__laidOut');
const texture = await page.locator('#a').screenshot({ omitBackground: true });
await browser.close();

// ── 2. Cube geometry ─────────────────────────────────────────────────────────
// Unit cube centred on the origin. Opposite faces carry the "2" (left atlas
// tile), the other four are plain — so the turntable shows one mark at a time,
// like the original logo art. Putting a "2" on all four sides reads as "22"
// whenever two faces are visible at once.
const H = 0.5;
const GLYPH = [0, 0.5];   // u range of the "2" tile
const PLAIN = [0.5, 1];   // u range of the blank tile
// [normal, four corners CCW from bottom-left, u range]
const FACES = [
  [[0, 0, 1], [[-H, -H, H], [H, -H, H], [H, H, H], [-H, H, H]], GLYPH],   // front
  [[0, 0, -1], [[H, -H, -H], [-H, -H, -H], [-H, H, -H], [H, H, -H]], GLYPH], // back
  [[1, 0, 0], [[H, -H, H], [H, -H, -H], [H, H, -H], [H, H, H]], PLAIN],   // right
  [[-1, 0, 0], [[-H, -H, -H], [-H, -H, H], [-H, H, H], [-H, H, -H]], PLAIN], // left
  [[0, 1, 0], [[-H, H, H], [H, H, H], [H, H, -H], [-H, H, -H]], PLAIN],   // top
  [[0, -1, 0], [[-H, -H, -H], [H, -H, -H], [H, -H, H], [-H, -H, H]], PLAIN], // bottom
];

const positions = [], normals = [], uvs = [], indices = [];
FACES.forEach(([n, corners, [u0, u1]], f) => {
  // v runs bottom→top of the tile; glTF UV origin is top-left, so flip it.
  const uv = [[u0, 1], [u1, 1], [u1, 0], [u0, 0]];
  corners.forEach((p, i) => { positions.push(...p); normals.push(...n); uvs.push(...uv[i]); });
  const b = f * 4;
  indices.push(b, b + 1, b + 2, b, b + 2, b + 3);
});

// ── 3. Pack the GLB ──────────────────────────────────────────────────────────
const pad4 = (b) => (b.length % 4 ? Buffer.concat([b, Buffer.alloc(4 - (b.length % 4))]) : b);
const f32 = (a) => Buffer.from(new Float32Array(a).buffer);
const u16 = (a) => pad4(Buffer.from(new Uint16Array(a).buffer));

const parts = [f32(positions), f32(normals), f32(uvs), u16(indices), pad4(texture)];
const offsets = [];
let off = 0;
for (const p of parts) { offsets.push(off); off += p.length; }
const bin = Buffer.concat(parts);

const json = {
  asset: { version: '2.0', generator: 'inbox2 make-logo-cube.mjs' },
  scene: 0,
  scenes: [{ nodes: [0] }],
  nodes: [{ mesh: 0, name: 'logo-cube' }],
  meshes: [{
    name: 'logo-cube',
    primitives: [{ attributes: { POSITION: 0, NORMAL: 1, TEXCOORD_0: 2 }, indices: 3, material: 0 }],
  }],
  materials: [{
    name: 'glossy-black',
    pbrMetallicRoughness: {
      baseColorTexture: { index: 0 },
      // Piano-black lacquer. Deliberately low metallic: a metal with no
      // environment map to reflect renders as a black hole in both three.js and
      // SceneKit — the sheen has to come from the lights hitting a dielectric.
      metallicFactor: 0.15,
      roughnessFactor: 0.32,
    },
  }],
  textures: [{ source: 0, sampler: 0 }],
  samplers: [{ magFilter: 9729, minFilter: 9987, wrapS: 33071, wrapT: 33071 }],
  images: [{ mimeType: 'image/png', bufferView: 4 }],
  accessors: [
    { bufferView: 0, componentType: 5126, count: positions.length / 3, type: 'VEC3', min: [-H, -H, -H], max: [H, H, H] },
    { bufferView: 1, componentType: 5126, count: normals.length / 3, type: 'VEC3' },
    { bufferView: 2, componentType: 5126, count: uvs.length / 2, type: 'VEC2' },
    { bufferView: 3, componentType: 5123, count: indices.length, type: 'SCALAR' },
  ],
  bufferViews: [
    { buffer: 0, byteOffset: offsets[0], byteLength: positions.length * 4, target: 34962 },
    { buffer: 0, byteOffset: offsets[1], byteLength: normals.length * 4, target: 34962 },
    { buffer: 0, byteOffset: offsets[2], byteLength: uvs.length * 4, target: 34962 },
    { buffer: 0, byteOffset: offsets[3], byteLength: indices.length * 2, target: 34963 },
    { buffer: 0, byteOffset: offsets[4], byteLength: texture.length },
  ],
  buffers: [{ byteLength: bin.length }],
};

// The JSON chunk pads with spaces (0x20) — zero bytes there are a parse error.
const jsonBytes = Buffer.from(JSON.stringify(json), 'utf8');
const jsonPad = (4 - (jsonBytes.length % 4)) % 4;
const jsonChunk = Buffer.concat([jsonBytes, Buffer.alloc(jsonPad, 0x20)]);
const header = Buffer.alloc(12);
header.writeUInt32LE(0x46546c67, 0);                     // "glTF"
header.writeUInt32LE(2, 4);
header.writeUInt32LE(12 + 8 + jsonChunk.length + 8 + bin.length, 8);
const chunkHeader = (len, type) => {
  const b = Buffer.alloc(8);
  b.writeUInt32LE(len, 0); b.writeUInt32LE(type, 4);
  return b;
};
writeFileSync(outPath, Buffer.concat([
  header,
  chunkHeader(jsonChunk.length, 0x4e4f534a), jsonChunk,   // JSON
  chunkHeader(bin.length, 0x004e4942), bin,               // BIN
]));

console.log(`glb → ${outPath} (${(bin.length / 1024).toFixed(0)}KB, 12 tris, ${TILE * 2}×${TILE} atlas)`);
