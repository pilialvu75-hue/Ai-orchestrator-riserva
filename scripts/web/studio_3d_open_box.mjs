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

function verifyBoxMesh(stl, { width, depth, height }) {
  const vertices = [...stl.toString('ascii').matchAll(/\bvertex\s+(\S+)\s+(\S+)\s+(\S+)/g)]
    .map(match => match.slice(1).map(Number));
  if (vertices.length < 12 || vertices.length % 3 ||
      !vertices.every(vertex => vertex.every(Number.isFinite))) {
    throw new Error('OpenSCAD returned invalid ASCII STL vertices');
  }

  const extent = [width, depth, height];
  for (let axis = 0; axis < extent.length; axis++) {
    const coordinates = vertices.map(vertex => vertex[axis]);
    if (Math.abs(Math.min(...coordinates)) > 0.001 ||
        Math.abs(Math.max(...coordinates) - extent[axis]) > 0.001) {
      throw new Error('STL dimensions differ from the CAD parameters');
    }
  }

  const edges = new Map();
  for (let index = 0; index < vertices.length; index += 3) {
    const triangle = vertices.slice(index, index + 3).map(vertex => vertex.join(','));
    if (new Set(triangle).size !== 3) throw new Error('STL has a collapsed triangle');
    for (let side = 0; side < 3; side++) {
      const start = triangle[side];
      const end = triangle[(side + 1) % 3];
      const key = [start, end].sort().join('|');
      const edge = edges.get(key) ?? { faces: 0, orientation: 0 };
      edge.faces++;
      edge.orientation += start < end ? 1 : -1;
      edges.set(key, edge);
    }
  }
  for (const edge of edges.values()) {
    if (edge.faces !== 2 || edge.orientation !== 0) {
      throw new Error('STL has an open or inconsistently oriented edge');
    }
  }
  return { dimensionsMm: { width, depth, height }, triangles: vertices.length / 3 };
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
    const verification = verifyBoxMesh(stl, parameters);
    return { source, stl, verification };
  } finally {
    await rm(directory, { recursive: true, force: true });
  }
}
