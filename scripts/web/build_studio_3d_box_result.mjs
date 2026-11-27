import { mkdir, writeFile } from 'node:fs/promises';
import { join } from 'node:path';
import { runStudio3dBoxJob } from './run_studio_3d_box_job.mjs';

const [output, ...values] = process.argv.slice(2);
if (!output || values.length !== 5) {
  throw new Error('Usage: build_studio_3d_box_result.mjs OUTPUT WIDTH DEPTH HEIGHT WALL FLOOR');
}
const [width, depth, height, wall, floor] = values.map(Number);
const { manifest, scad, stl } = await runStudio3dBoxJob({ width, depth, height, wall, floor });

await mkdir(output);
await Promise.all([
  writeFile(join(output, 'box.scad'), scad, { flag: 'wx' }),
  writeFile(join(output, 'box.stl'), stl, { flag: 'wx' }),
  writeFile(join(output, 'result.json'), JSON.stringify(manifest, null, 2) + '\n', { flag: 'wx' }),
]);
