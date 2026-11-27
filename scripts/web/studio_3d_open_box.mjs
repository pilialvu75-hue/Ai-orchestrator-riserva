import { execFile } from 'node:child_process';
import { mkdtemp, readFile, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { promisify } from 'node:util';
import { validateOpenBoxParameters } from './studio_3d_box_parameters.mjs';

const run = promisify(execFile);

export function createOpenBoxCad(parameters) {
  const { width, depth, height, wall, floor } = validateOpenBoxParameters(parameters);
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

function verifyBoxMesh(stl, { width, depth, height, wall, floor }) {
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

  // A valid outer envelope can still hide a missing or mis-sized cavity.
  const toleranceMm = 0.001;
  for (const x of [wall, width - wall]) {
    for (const y of [wall, depth - wall]) {
      for (const z of [floor, height]) {
        if (!vertices.some(vertex => vertex.every((value, axis) =>
          Math.abs(value - [x, y, z][axis]) <= toleranceMm))) {
          throw new Error('STL cavity dimensions differ from the CAD parameters');
        }
      }
    }
  }

  const edges = new Map();
  for (let index = 0; index < vertices.length; index += 3) {
    const [a, b, c] = vertices.slice(index, index + 3);
    const u = b.map((value, axis) => value - a[axis]);
    const v = c.map((value, axis) => value - a[axis]);
    const cross = [u[1] * v[2] - u[2] * v[1], u[2] * v[0] - u[0] * v[2], u[0] * v[1] - u[1] * v[0]];
    if (Math.hypot(...cross) < 1e-10) throw new Error('STL has a zero-area triangle');
    const triangle = [a, b, c].map(vertex => vertex.join(','));

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
  return { dimensionsMm: { width, depth, height }, cavityMm: { wall, floor }, triangles: vertices.length / 3 };
}

// Runs a fixed template with numeric inputs. The caller never supplies executable CAD.
export async function renderOpenBox(parameters, { executable = 'openscad' } = {}) {
  const source = createOpenBoxCad(parameters);
  const directory = await mkdtemp(join(tmpdir(), 'aivexus-open-box-'));
  try {
    await writeFile(join(directory, 'box.scad'), source);
    await run(executable, ['-o', 'box.stl', 'box.scad'], {
      cwd: directory,
      env: {
        PATH: process.env.PATH,
        SystemRoot: process.env.SystemRoot,
        HOME: directory,
        TMPDIR: directory,
        TEMP: directory,
        TMP: directory,
      },
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
