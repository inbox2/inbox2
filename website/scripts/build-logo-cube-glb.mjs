// Builds public/assets/3d/logo-cube.glb — the classic inbox2 box: an OPEN glossy
// black box (four walls + a floor, no lid) with the chrome "2" embossed on the
// front wall. Sharp edges, plain dark interior, no tint inside.
// Run: node scripts/build-logo-cube-glb.mjs [out.glb]
import * as THREE from "three";
import { Document, NodeIO } from "@gltf-transform/core";

const OUT = process.argv[2] || "public/assets/3d/logo-cube.glb";

// "2" from Helvetica Neue Light (upem 1000, Y already up), which is the weight
// the original mark uses — the bold numeral in brand/inbox2-mark.svg is a
// different glyph. Absolute M/H/V/Q/Z.
const TWO =
  "M497 0V58H108Q114 93 138.0 122.5Q162 152 193.5 177.0Q225 202 259.0 222.5Q293 243 318 260Q353 282 384.5 307.5Q416 333 440.5 363.0Q465 393 479.5 429.0Q494 465 494 509Q494 558 477.5 595.0Q461 632 431.5 656.5Q402 681 362.5 693.5Q323 706 277 706Q220 706 177.5 687.5Q135 669 107.0 636.0Q79 603 65.5 557.5Q52 512 53 458H116Q115 497 123.5 532.0Q132 567 151.0 594.0Q170 621 200.5 637.0Q231 653 274 653Q306 653 334.5 643.5Q363 634 384.5 615.5Q406 597 418.5 570.5Q431 544 431 510Q431 468 416.5 437.5Q402 407 373.0 378.0Q344 349 307.5 323.5Q271 298 234.0 273.5Q197 249 162.0 222.5Q127 196 99.0 164.0Q71 132 54.0 92.0Q37 52 36 0Z";

/** Minimal absolute-only SVG path → THREE.Shape (M L H V C Q Z). */
function pathToShape(d) {
  const shape = new THREE.Shape();
  const tokens = d.match(/[MLHVCQZ]|-?\d*\.?\d+/gi);
  let x = 0;
  let y = 0;
  let cmd = "";
  const n = (t) => parseFloat(t);
  for (let i = 0; i < tokens.length; ) {
    if (/[MLHVCQZ]/i.test(tokens[i])) cmd = tokens[i++].toUpperCase();
    switch (cmd) {
      case "M":
        x = n(tokens[i++]); y = n(tokens[i++]); shape.moveTo(x, y); cmd = "L"; break;
      case "L":
        x = n(tokens[i++]); y = n(tokens[i++]); shape.lineTo(x, y); break;
      case "H":
        x = n(tokens[i++]); shape.lineTo(x, y); break;
      case "V":
        y = n(tokens[i++]); shape.lineTo(x, y); break;
      case "Q": {
        const cx = n(tokens[i++]), cy = n(tokens[i++]);
        x = n(tokens[i++]); y = n(tokens[i++]);
        shape.quadraticCurveTo(cx, cy, x, y);
        break;
      }
      case "C": {
        const x1 = n(tokens[i++]), y1 = n(tokens[i++]);
        const x2 = n(tokens[i++]), y2 = n(tokens[i++]);
        x = n(tokens[i++]); y = n(tokens[i++]);
        shape.bezierCurveTo(x1, y1, x2, y2, x, y);
        break;
      }
      case "Z":
        shape.closePath(); break;
      default:
        throw new Error(`unsupported path command: ${cmd}`);
    }
  }
  return shape;
}

const doc = new Document();
const buffer = doc.createBuffer();
const scene = doc.createScene("logo-cube");

const lin = (hex) => {
  const c = new THREE.Color(hex);
  return [c.r, c.g, c.b, 1];
};
const material = (name, hex, roughness, metallic) =>
  doc.createMaterial(name).setBaseColorFactor(lin(hex)).setRoughnessFactor(roughness).setMetallicFactor(metallic);

const M = {
  // Glossy black lacquer. The interior takes the same material, so the box reads
  // as one moulded piece and nothing tints the inside.
  shell: material("BoxBlack", "#0a0a0a", 0.11, 0.35),
  chrome: material("Chrome2", "#e8e8e8", 0.17, 1),
};

function add(name, geometry, mat, { flat = false } = {}) {
  const g = flat ? geometry.toNonIndexed() : geometry;
  g.computeVertexNormals();
  const pos = g.getAttribute("position").array;
  const nor = g.getAttribute("normal").array;
  const idx = g.index ? g.index.array : Uint32Array.from({ length: pos.length / 3 }, (_, i) => i);
  const prim = doc
    .createPrimitive()
    .setAttribute("POSITION", doc.createAccessor().setType("VEC3").setArray(new Float32Array(pos)).setBuffer(buffer))
    .setAttribute("NORMAL", doc.createAccessor().setType("VEC3").setArray(new Float32Array(nor)).setBuffer(buffer))
    .setIndices(doc.createAccessor().setType("SCALAR").setArray(new Uint32Array(idx)).setBuffer(buffer))
    .setMaterial(mat);
  scene.addChild(doc.createNode(name).setMesh(doc.createMesh(name).addPrimitive(prim)));
}

// ---- the open box: four walls standing on a floor, centred on the origin ----
const S = 1.6; // outer width and depth
const H = 1.34; // wall height
const T = 0.075; // wall thickness
const box = (w, h, d, x, y, z) => {
  const g = new THREE.BoxGeometry(w, h, d);
  g.translate(x, y, z);
  return g;
};
const y0 = -H / 2;
add("Floor", box(S, T, S, 0, y0 + T / 2, 0), M.shell);
add("WallFront", box(S, H, T, 0, y0 + H / 2, (S - T) / 2), M.shell);
add("WallBack", box(S, H, T, 0, y0 + H / 2, -(S - T) / 2), M.shell);
add("WallLeft", box(T, H, S - 2 * T, -(S - T) / 2, y0 + H / 2, 0), M.shell);
add("WallRight", box(T, H, S - 2 * T, (S - T) / 2, y0 + H / 2, 0), M.shell);

// ---- the chrome "2", embossed on the front wall ----
const two = new THREE.ExtrudeGeometry(pathToShape(TWO), {
  depth: 34,
  bevelEnabled: true,
  bevelThickness: 7,
  bevelSize: 7,
  bevelSegments: 4,
  curveSegments: 10,
});
two.computeBoundingBox();
const bb = two.boundingBox;
const scale = (H * 0.62) / (bb.max.y - bb.min.y);
two.translate(-(bb.min.x + bb.max.x) / 2, -(bb.min.y + bb.max.y) / 2, 0);
two.scale(scale, scale, scale);
// sink the glyph's back into the wall so only the raised face stands proud
two.translate(0, y0 + H / 2, S / 2 - 22 * scale);
add("Two", two, M.chrome, { flat: true });

const io = new NodeIO();
await io.write(OUT, doc);
console.log("wrote", OUT);
