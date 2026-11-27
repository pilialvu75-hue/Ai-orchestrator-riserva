import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { join } from 'node:path';
import { readStudioStl } from '../../web/studio_3d_preview.mjs';
import { DatabaseSync } from 'node:sqlite';
import { test } from 'node:test';
import { listWebCadRevisions, readWebCadRevision, saveWebCadRevision, selectWebCadRevision } from '../../scripts/web/d1_web_cad_revisions.mjs';
import { applyOpenBoxInstruction, parseOpenBoxDescription } from '../../scripts/web/studio_3d_box_parameters.mjs';
import { collectWebCadJob, findActiveWebCadJob, startWebCadJob } from '../../scripts/web/d1_web_cad_jobs.mjs';
import { decodeWebAppJob, encodeRunnerBase64, encodeWebAppResult, importWebAppAuthorizationKey, runnerPayloadSha256 } from '../../scripts/web/web_application_runner_packet.mjs';

const sqliteValue = value => value instanceof ArrayBuffer ? new Uint8Array(value) : value;

test('stores immutable CAD artifacts, rejects altered bytes and isolates owners', async () => {
  const sqlite = new DatabaseSync(':memory:');
  sqlite.exec(readFileSync(new URL('../../scripts/web/sql/013_web_cad_revisions.sql', import.meta.url), 'utf8'));
  const db = { prepare: query => ({
    bind: (...params) => ({ first: async () => sqlite.prepare(query).get(...params.map(sqliteValue)), all: async () => ({ results: sqlite.prepare(query).all(...params.map(sqliteValue)) }) }),
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
  assert.deepEqual(await selectWebCadRevision(root), { ok: true, activeRevisionId: root.revisionId });
  assert.equal((await listWebCadRevisions(root)).find(entry => entry.selected).revisionId, root.revisionId);
  assert.equal((await selectWebCadRevision({ ...root, ownerSubject: 'stranger' })).reason, 'cad_revision_conflict');
  assert.deepEqual(await listWebCadRevisions({ ...root, ownerSubject: 'stranger' }), []);
  sqlite.close();
});

const artifactBase = process.env.AIVEXUS_CAD_TEST_ARTIFACTS;
test('stores both real OpenSCAD results and recovers either revision by ID',
  { skip: !artifactBase }, async () => {
    const sqlite = new DatabaseSync(':memory:');
    sqlite.exec(readFileSync(new URL('../../scripts/web/sql/013_web_cad_revisions.sql', import.meta.url), 'utf8'));
    const db = { prepare: query => ({
      bind: (...params) => ({ first: async () => sqlite.prepare(query).get(...params.map(sqliteValue)) }),
    }) };
    try {
      const project = { db, ownerSubject: 'private-test-owner', projectId: 'web-project:1795000000000000' };
      const revisionIds = [];
      for (const width of [80, 90]) {
        const path = join(artifactBase, 'box-' + width + 'mm');
        const scad = readFileSync(join(path, 'box.scad'));
        const stl = readFileSync(join(path, 'box.stl'));
        const manifest = JSON.parse(readFileSync(join(path, 'result.json'), 'utf8'));
        const revisionId = crypto.randomUUID();
        const baseRevisionId = revisionIds.at(-1) ?? null;
        const stored = await saveWebCadRevision({ ...project, revisionId, baseRevisionId, manifest, scad, stl });
        assert.deepEqual(stored, { ok: true, revisionNumber: revisionIds.length + 1 });
        revisionIds.push(revisionId);
      }
      for (const [index, revisionId] of revisionIds.entries()) {
        const revision = await readWebCadRevision({ ...project, revisionId });
        assert.equal(revision.ok, true);
        const width = index === 0 ? 80 : 90;
        const { bounds } = readStudioStl(new TextDecoder().decode(revision.stl));
        assert.deepEqual(bounds, [[0, width], [0, 60], [0, 30]]);
        assert.match(new TextDecoder().decode(revision.scad), new RegExp('width = ' + width + ';'));
      }
    } finally {
      sqlite.close();
    }
  });

test('reserves one CAD dispatch and imports its ticket-bound result into private history', async () => {
  const sqlite = new DatabaseSync(':memory:');
  try {
    for (const migration of ['013_web_cad_revisions.sql', '014_web_cad_jobs.sql']) {
      sqlite.exec(readFileSync(new URL('../../scripts/web/sql/' + migration, import.meta.url), 'utf8'));
    }
    const db = { prepare: query => ({ bind: (...args) => ({
      first: async () => sqlite.prepare(query).get(...args.map(sqliteValue)),
      run: async () => sqlite.prepare(query).run(...args.map(sqliteValue)),
    }) }) };
    const makeKey = () => crypto.subtle.generateKey({
      name: 'RSA-OAEP', modulusLength: 2048, hash: 'SHA-256',
      publicExponent: Uint8Array.of(1, 0, 1),
    }, true, ['encrypt', 'decrypt']);
    const [sender, receiver] = await Promise.all([makeKey(), makeKey()]);
    const exportKey = async (format, key) => encodeRunnerBase64(new Uint8Array(
      await crypto.subtle.exportKey(format, key)));
    const runner = {
      token: 'test', headSha: 'a'.repeat(40),
      jobPublicKey: await exportKey('spki', sender.publicKey),
      resultPublicKey: await exportKey('spki', receiver.publicKey),
      resultPrivateKey: await exportKey('pkcs8', receiver.privateKey),
      authorizationKey: encodeRunnerBase64(crypto.getRandomValues(new Uint8Array(32))),
    };
    const authorizationKey = await importWebAppAuthorizationKey(runner.authorizationKey);
    const parameters = { width: 80, depth: 60, height: 30, wall: 2, floor: 3 };
    const request = { projectId: 'web-project:1795000000000000', revisionId: crypto.randomUUID(), parameters, photoEstimates: ['width'] };
    const scad = Uint8Array.of(1, 2, 3);
    const stl = Uint8Array.of(4, 5, 6);
    const manifest = { version: 1, kind: 'cad', shape: 'open_box', unit: 'mm', parameters, files: [
      { name: 'box.scad', mediaType: 'text/plain', bytes: 3, sha256: await runnerPayloadSha256(scad) },
      { name: 'box.stl', mediaType: 'model/stl', bytes: 3, sha256: await runnerPayloadSha256(stl) },
    ] };
    let packet;
    let dispatches = 0;
    const githubClient = () => ({
      async dispatch({ ticket, input }) {
        dispatches++;
        const job = await decodeWebAppJob({ privateKey: sender.privateKey, authorizationKey, ticket, input });
        const expected = dispatches === 1 ? parameters : { ...parameters, width: 90 };
        assert.deepEqual(job.source, { kind: 'cad_open_box', parameters: expected });
        packet = await encodeWebAppResult({
          publicKey: job.resultPublicKey, authorizationKey, ticket, jobSha256: job.jobSha256,
          result: { manifest: { ...manifest, parameters: expected }, scad: encodeRunnerBase64(scad), stl: encodeRunnerBase64(stl) },
        });
        return 123;
      },
      async readResult(runId) { assert.equal(runId, 123); return { status: 'ready' }; },
      async downloadArchive() { return packet; },
    });
    const options = { db, ownerSubject: 'owner', runner, githubClient };
    const start = () => startWebCadJob({ ...options, request });
    assert.equal((await start()).status, 'submitted');
    assert.equal((await start()).status, 'submitted');
    assert.equal(dispatches, 1);
    const { projectId, revisionId } = request;
    const recover = (ownerSubject, id = projectId) => findActiveWebCadJob({
      ...options, ownerSubject, request: { projectId: id },
    });
    assert.deepEqual((await recover('owner')).activeJob, { revisionId, status: 'submitted' });
    assert.equal((await recover('stranger')).activeJob, null);
    assert.equal((await recover('owner', 'web-project:1')).activeJob, null);
    const collect = ownerSubject => collectWebCadJob({
      ...options, ownerSubject, request: { projectId, revisionId },
    });
    assert.equal((await collect('stranger')).reason, 'cad_job_not_found');
    assert.equal((await collect('owner')).status, 'verified');
    assert.equal((await recover('owner')).activeJob, null);
    assert.equal((await collect('owner')).status, 'verified');
    const saved = await readWebCadRevision({ db, ownerSubject: 'owner', projectId, revisionId });
    assert.deepEqual(saved.stl, stl);
    assert.deepEqual(saved.manifest, { ...manifest, photoEstimates: ['width'] });
    const edit = { projectId, revisionId: crypto.randomUUID(), baseRevisionId: revisionId,
      instruction: 'Allarga la scatola di 10 mm.' };
    assert.equal((await startWebCadJob({ ...options, request: { ...edit, instruction: 'Aggiungi fori' } })).reason,
      'unsupported_cad_instruction');
    assert.equal((await startWebCadJob({ ...options, request: edit })).status, 'submitted');
    assert.equal(dispatches, 2);
    assert.equal((await collectWebCadJob({ ...options,
      request: { projectId, revisionId: edit.revisionId } })).status, 'verified');
    const updated = await readWebCadRevision({ ...options, projectId, revisionId: edit.revisionId });
    assert.equal(updated.revisionNumber, 2);
    assert.equal(updated.manifest.parameters.width, 90);
    assert.deepEqual(updated.manifest.photoEstimates, ['width']);
    assert.equal((await readWebCadRevision({ ...options, projectId, revisionId })).manifest.parameters.width, 80);

    assert.equal(applyOpenBoxInstruction(parameters, 'Porta il fondo a 3,5 mm').floor, 3.5);
    assert.throws(() => applyOpenBoxInstruction(parameters, 'Restringi la scatola di 79 mm'));
  } finally { sqlite.close(); }
});

test('reads both supported descriptions and rejects missing dimensions', () => {
  const expected = { width: 80, depth: 60, height: 30, wall: 2, floor: 3 };
  assert.deepEqual(parseOpenBoxDescription('Voglio una scatola portaoggetti larga 80 mm, profonda 60 mm e alta 30 mm, con pareti spesse 2 mm e fondo spesso 3 mm.'), expected);
  assert.deepEqual(parseOpenBoxDescription('Scatola aperta 80×60×30 mm, pareti 2 mm, fondo 3 mm'), expected);
  assert.throws(() => parseOpenBoxDescription('Scatola aperta 80×60×30 mm'));
});
