import assert from 'node:assert/strict';
import { test } from 'node:test';
import { createOpenBoxCad, renderOpenBox } from '../../scripts/web/studio_3d_open_box.mjs';

const box = { width: 80, depth: 60, height: 30, wall: 2, floor: 3 };

test('accepts numeric dimensions and rejects invalid cavities and source injection', () => {
  assert.match(createOpenBoxCad(box), /width = 80;/);
  assert.throws(() => createOpenBoxCad({ ...box, wall: 30 }), RangeError);
  assert.throws(() => createOpenBoxCad({ ...box, floor: 30 }), RangeError);
  assert.throws(() => createOpenBoxCad({ ...box, width: '80; import("file")' }), RangeError);
});

test('OpenSCAD exports the original and the resized box with an open cavity', async () => {
  for (const width of [80, 90]) {
    const { stl, verification } = await renderOpenBox({ ...box, width });
    assert.deepEqual(verification.dimensionsMm, { width, depth: 60, height: 30 });
    const vertices = [...stl.toString('ascii').matchAll(/\bvertex\s+(\S+)\s+(\S+)\s+(\S+)/g)]
      .map(match => match.slice(1).map(Number));
    assert.equal(verification.triangles, vertices.length / 3);
    assert.ok(vertices.flat().every(Number.isFinite));
    assert.deepEqual([0, 1, 2].map(axis => {
      const coordinates = vertices.map(vertex => vertex[axis]);
      return [Math.min(...coordinates), Math.max(...coordinates)];
    }), [[0, width], [0, 60], [0, 30]]);
    for (const z of [3, 30]) {
      for (const x of [2, width - 2]) {
        for (const y of [2, 58]) {
          assert.ok(vertices.some(vertex => vertex.join() === [x, y, z].join()));
        }
      }
    }
  }
});
