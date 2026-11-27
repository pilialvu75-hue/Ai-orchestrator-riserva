import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { DatabaseSync } from 'node:sqlite';
import { test } from 'node:test';
import { listWebCadRevisions, readWebCadRevision, saveWebCadRevision } from '../../scripts/web/d1_web_cad_revisions.mjs';
import { runnerPayloadSha256 } from '../../scripts/web/web_application_runner_packet.mjs';

test('stores immutable CAD artifacts, rejects altered bytes and isolates owners', async () => {
  const sqlite = new DatabaseSync(':memory:');
  sqlite.exec(readFileSync(new URL('../../scripts/web/sql/013_web_cad_revisions.sql', import.meta.url), 'utf8'));
  const db = { prepare: query => ({
    bind: (...params) => ({ first: async () => sqlite.prepare(query).get(...params), all: async () => ({ results: sqlite.prepare(query).all(...params) }) }),
  }) };
  const scad = Uint8Array.of(1, 2, 3);
  const stl = Uint8Array.of(4, 5, 6);
  const manifest = { version: 1, kind: 'cad', shape: 'open_box', unit: 'mm', files: [
    { name: 'box.scad', mediaType: 'text/plain', bytes: scad.length, sha256: await runnerPayloadSha256(scad) },
    { name: 'box.stl', mediaType: 'model/stl', bytes: stl.length, sha256: await runnerPayloadSha256(stl) },
  ] };
  const root = { db, ownerSubject: 'owner', projectId: 'web-project:1795000000000000',
    revisionId: crypto.randomUUID(), manifest, scad, stl };
  assert.equal((await saveWebCadRevision({ ...root, stl: Uint8Array.of(6, 5, 4) })).reason, 'invalid_cad_result');
  assert.deepEqual(await saveWebCadRevision(root), { ok: true, revisionNumber: 1 });
  assert.equal((await saveWebCadRevision(root)).reason, 'cad_revision_conflict');
  const next = { ...root, baseRevisionId: root.revisionId, revisionId: crypto.randomUUID() };
  for (const scope of [{ ownerSubject: 'stranger' }, { projectId: crypto.randomUUID() }]) {
    assert.equal((await readWebCadRevision({ ...root, ...scope })).ok, false);
    assert.equal((await saveWebCadRevision({ ...next, ...scope })).reason, 'cad_revision_conflict');
  }
  assert.deepEqual(await saveWebCadRevision(next), { ok: true, revisionNumber: 2 });
  const current = await readWebCadRevision(next);
  assert.deepEqual(current.manifest, manifest);
  assert.deepEqual(current.scad, scad);
  assert.deepEqual(current.stl, stl);
  assert.equal(current.baseRevisionId, root.revisionId);
  assert.equal((await readWebCadRevision(root)).revisionNumber, 1);
  const afterRollback = { ...next, revisionId: crypto.randomUUID() };
  assert.deepEqual(await saveWebCadRevision(afterRollback), { ok: true, revisionNumber: 3 });
  assert.deepEqual((await listWebCadRevisions(root)).map(item => item.revisionNumber), [3, 2, 1]);
  assert.deepEqual(await listWebCadRevisions({ ...root, ownerSubject: 'stranger' }), []);
  sqlite.close();
});
