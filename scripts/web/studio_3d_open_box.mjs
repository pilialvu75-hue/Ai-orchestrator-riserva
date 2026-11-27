import { execFile } from 'node:child_process';
import { mkdtemp, readFile, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { promisify } from 'node:util';

const run = promisify(execFile);
const dimensions = ['width', 'depth', 'height', 'wall', 'floor'];

export function createOpenBoxCad(parameters) {
  if (!parameters || Object.keys(parameters).length !== dimensions.length ||
      dimensions.some(name => !Object.hasOwn(parameters, name) ||
        !Number.isFinite(parameters[name]) ||
        parameters[name] < 0.1 || parameters[name] > 500)) {
    throw new RangeError('Expected five dimensions in millimetres, between 0.1 and 500');
  }
  const { width, depth, height, wall, floor } = parameters;
  if (2 * wall >= Math.min(width, depth) || floor >= height) {
    throw new RangeError('The dimensions must leave room for an open cavity');
  }

  return `// Dimensions in millimetres
width = ${width};
depth = ${depth};
height = ${height};
wall = ${wall};
floor = ${floor};

difference() {
    cube([width, depth, height]);
    translate([wall, wall, floor])
        cube([width - 2 * wall, depth - 2 * wall, height - floor + 1]);
}
`;
}

// Runs a fixed template with numeric inputs. The caller never supplies executable CAD.
export async function renderOpenBox(parameters, { executable = 'openscad' } = {}) {
  const source = createOpenBoxCad(parameters);
  const directory = await mkdtemp(join(tmpdir(), 'aivexus-open-box-'));
  try {
    await writeFile(join(directory, 'box.scad'), source);
    await run(executable, ['-o', 'box.stl', 'box.scad'], {
      cwd: directory,
      timeout: 30_000,
      maxBuffer: 128 * 1024,
    });
    const stl = await readFile(join(directory, 'box.stl'));
    if (stl.length === 0) throw new Error('OpenSCAD returned an empty STL');
    return { source, stl };
  } finally {
    await rm(directory, { recursive: true, force: true });
  }
}
