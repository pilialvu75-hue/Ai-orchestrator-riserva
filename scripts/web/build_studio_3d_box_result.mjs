import { createHash } from 'node:crypto';
import { mkdir, writeFile } from 'node:fs/promises';
import { join } from 'node:path';
import { renderOpenBox } from './studio_3d_open_box.mjs';

const [output, ...values] = process.argv.slice(2);
if (!output || values.length !== 5) {
  throw new Error('Usage: build_studio_3d_box_result.mjs OUTPUT WIDTH DEPTH HEIGHT WALL FLOOR');
}
const [width, depth, height, wall, floor] = values.map(Number);
const parameters = { width, depth, height, wall, floor };
const { source, stl, verification } = await renderOpenBox(parameters);
const files = [
  { name: 'box.scad', mediaType: 'text/plain', content: Buffer.from(source) },
  { name: 'box.stl', mediaType: 'model/stl', content: stl },
];
const result = {
  version: 1,
  kind: 'cad',
  shape: 'open_box',
  unit: 'mm',
  parameters,
  verification,
  files: files.map(({ name, mediaType, content }) => ({
    name, mediaType, bytes: content.length,
    sha256: createHash('sha256').update(content).digest('hex'),
  })),
};

await mkdir(output);
for (const { name, content } of files) {
  await writeFile(join(output, name), content, { flag: 'wx' });
}
await writeFile(join(output, 'result.json'), JSON.stringify(result, null, 2) + '\n', {
  flag: 'wx',
});
