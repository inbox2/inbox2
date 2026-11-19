// Builds public/assets/3d/sovereign.glb from primitives: the matte black server
// tower with pink slats, a lime padlock and status light, and the envelope stack.
// Metres, Y-up, front face towards +Z. Run: node scripts/build-sovereign-glb.mjs
import * as THREE from "three";
import { RoundedBoxGeometry } from "three/examples/jsm/geometries/RoundedBoxGeometry.js";
import { Document, NodeIO } from "@gltf-transform/core";

const OUT = process.argv[2] || "public/assets/3d/sovereign.glb";

const doc = new Document();
const buffer = doc.createBuffer();
const scene = doc.createScene("sovereign");

const lin = (hex) => {
  const c = new THREE.Color(hex); // three converts sRGB hex to linear
  return [c.r, c.g, c.b, 1];
};
const material = (name, hex, roughness = 0.9, emissive = null) => {
  const m = doc.createMaterial(name).setBaseColorFactor(lin(hex)).setRoughnessFactor(roughness).setMetallicFactor(0);
  if (emissive) m.setEmissiveFactor(lin(emissive).slice(0, 3));
  return m;
};
const M = {
  black: material("ServerBlack", "#141414", 0.92),
  groove: material("GrooveBlack", "#050505", 0.95),
  pink: material("EnvelopePink", "#E53F89", 0.85),
  white: material("EnvelopeOffWhite", "#F2EFE8", 0.85),
  lime: material("Lime", "#B7E64A", 0.8),
  led: material("StatusLight", "#B7E64A", 0.5, "#B7E64A"),
};

function add(name, geometry, mat, { pos = [0, 0, 0], rot = [0, 0, 0] } = {}) {
  const g = geometry.clone();
  g.rotateX(rot[0]); g.rotateY(rot[1]); g.rotateZ(rot[2]);
  g.translate(...pos);
  g.computeVertexNormals();
  const pos3 = g.getAttribute("position").array;
  const nor = g.getAttribute("normal").array;
  const idx = g.index ? g.index.array : Uint32Array.from({ length: pos3.length / 3 }, (_, i) => i);
  const prim = doc
    .createPrimitive()
    .setAttribute("POSITION", doc.createAccessor().setType("VEC3").setArray(new Float32Array(pos3)).setBuffer(buffer))
    .setAttribute("NORMAL", doc.createAccessor().setType("VEC3").setArray(new Float32Array(nor)).setBuffer(buffer))
    .setIndices(doc.createAccessor().setType("SCALAR").setArray(new Uint32Array(idx)).setBuffer(buffer))
    .setMaterial(mat);
  const node = doc.createNode(name).setMesh(doc.createMesh(name).addPrimitive(prim));
  scene.addChild(node);
  return node;
}

// ---- tower ----
const TW = 1.1, TH = 1.8, TD = 0.8, FRONT = TD / 2;
add("ServerTower", new RoundedBoxGeometry(TW, TH, TD, 8, 0.1), M.black, { pos: [0, TH / 2, 0] });

// ---- five grooves with pink slats on the front face ----
[0.36, 0.62, 0.88, 1.14, 1.4].forEach((y, i) => {
  add(`Groove_${i + 1}`, new RoundedBoxGeometry(0.74, 0.13, 0.05, 4, 0.02), M.groove, { pos: [0, y, FRONT + 0.005] });
  add(`Slat_${i + 1}`, new RoundedBoxGeometry(0.62, 0.055, 0.05, 4, 0.02), M.pink, { pos: [0, y, FRONT + 0.02] });
});

// ---- status light ----
add("StatusLight", new THREE.CylinderGeometry(0.045, 0.045, 0.03, 48), M.led, { pos: [0, 1.6, FRONT + 0.012], rot: [Math.PI / 2, 0, 0] });

// ---- padlock on top ----
add("PadlockBody", new RoundedBoxGeometry(0.34, 0.28, 0.16, 6, 0.05), M.lime, { pos: [0, TH + 0.14, 0] });
add("PadlockShackle", new THREE.TorusGeometry(0.11, 0.036, 24, 64), M.lime, { pos: [0, TH + 0.32, 0] });
add("Keyhole", new THREE.CylinderGeometry(0.025, 0.025, 0.02, 32), M.groove, { pos: [0, TH + 0.15, 0.085], rot: [Math.PI / 2, 0, 0] });

// ---- envelope stack beside the base ----
const EX = 1.0, EZ = -0.05, EW = 0.64, ED = 0.44, EH = 0.1;
[M.pink, M.white, M.pink].forEach((m, i) => {
  add(`Envelope_${i + 1}`, new RoundedBoxGeometry(EW, EH, ED, 5, 0.03), m, { pos: [EX, EH / 2 + i * (EH + 0.012), EZ] });
});
// flap on the top envelope: a thin triangle, base along the back edge, apex towards the front
const ztop = 3 * EH + 2 * 0.012;
const shape = new THREE.Shape([
  new THREE.Vector2(EX - EW / 2 + 0.03, EZ - ED / 2 + 0.02),
  new THREE.Vector2(EX + EW / 2 - 0.03, EZ - ED / 2 + 0.02),
  new THREE.Vector2(EX, EZ + 0.1),
]);
const flap = new THREE.ExtrudeGeometry(shape, { depth: 0.014, bevelEnabled: false });
add("EnvelopeFlap", flap, M.white, { pos: [0, ztop, 0], rot: [Math.PI / 2, 0, 0] });

// flip the flap so its extrusion points up (rotateX(+90°) sends +z to -y)
// (handled by translating: rotateX maps depth along +z to -y, so lift by depth)
scene.listChildren().find((n) => n.getName() === "EnvelopeFlap").setTranslation([0, 0.014, 0]);

const io = new NodeIO();
await io.write(OUT, doc);
console.log("wrote", OUT);
