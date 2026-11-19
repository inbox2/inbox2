// Post-process: make every material matte clay (no metal, high roughness), like the render.
import { NodeIO } from '@gltf-transform/core';
import { ALL_EXTENSIONS } from '@gltf-transform/extensions';
import draco3d from 'draco3dgltf';
const [,, inFile, outFile] = process.argv;
const io = new NodeIO().registerExtensions(ALL_EXTENSIONS).registerDependencies({
  'draco3d.decoder': await draco3d.createDecoderModule(),
  'draco3d.encoder': await draco3d.createEncoderModule(),
});
const doc = await io.read(inFile);
for (const m of doc.getRoot().listMaterials()) {
  m.setMetallicFactor(0).setRoughnessFactor(0.92);
  const mr = m.getMetallicRoughnessTexture(); if (mr) m.setMetallicRoughnessTexture(null);
}
await io.write(outFile, doc);
console.log('matte ok');
