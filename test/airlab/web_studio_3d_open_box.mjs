import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { createChromiumWebVerifier } from '../../scripts/web/chromium_web_verifier.mjs';
import { test } from 'node:test';
import { createOpenBoxCad, renderOpenBox } from '../../scripts/web/studio_3d_open_box.mjs';

import { mountStudioStlPreview } from '../../web/studio_3d_preview.mjs';

import { runEncryptedStudioCadJob } from '../../scripts/web/run_encrypted_studio_cad_job.mjs';
import { decodeRunnerBase64, decodeWebAppResult, encodeRunnerBase64, encodeWebAppJob,
  importWebAppAuthorizationKey, runnerPayloadSha256 } from '../../scripts/web/web_application_runner_packet.mjs';

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

test('renders the real STL and redraws the mesh after keyboard rotation and zoom', async () => {
  const { stl } = await renderOpenBox(box);
  const frames = [];
  const canvas = new EventTarget();
  const context = {
    fillRect: () => frames.push([]),
    moveTo: (x, y) => frames.at(-1).push([x, y]),
    beginPath() {}, lineTo() {}, closePath() {}, stroke() {}, fill() {}, fillText() {},
  };
  Object.assign(canvas, { width: 640, height: 480, getContext: () => context });
  const label = {};
  const dispose = mountStudioStlPreview(canvas, stl.toString('ascii'), label);
  assert.equal(label.textContent, '80 × 60 × 30 mm');
  for (const key of ['ArrowLeft', '+']) {
    const event = Object.assign(new Event('keydown', { cancelable: true }), { key });
    canvas.dispatchEvent(event);
    assert.ok(event.defaultPrevented);
  }
  assert.equal(frames.length, 3);
  assert.notDeepEqual(frames[0], frames[1]);
  assert.notDeepEqual(frames[1], frames[2]);
  dispose();
  canvas.dispatchEvent(Object.assign(new Event('keydown'), { key: 'ArrowLeft' }));
  assert.equal(frames.length, 3);
});

const chromium = process.env.AIVEXUS_WEB_CHROMIUM;
test('Chromium draws the OpenSCAD STL and changes canvas pixels after rotation and zoom',
  { skip: !chromium, timeout: 45000 }, async () => {
    const { stl } = await renderOpenBox(box);
    const viewer = await readFile(new URL('../../web/studio_3d_preview.mjs', import.meta.url), 'utf8');
    const verify = createChromiumWebVerifier({ executable: chromium });
    const result = await verify({
      assets: new Map([
        ['index.html', '<!doctype html><canvas width="640" height="480" tabindex="0"></canvas><output id="dimensions"></output><output id="pixels"></output><button id="rotate">Rotate</button><button id="zoom">Zoom</button><script type="module" src="fixture.mjs"></script>'],
        ['viewer.mjs', viewer],
        ['fixture.mjs', `
          import { mountStudioStlPreview } from './viewer.mjs';
          const canvas = document.querySelector('canvas');
          mountStudioStlPreview(canvas, ${JSON.stringify(stl.toString('ascii'))},
            document.querySelector('#dimensions'));
          const pixels = document.querySelector('#pixels');
          const context = canvas.getContext('2d');
          const data = context.getImageData(0, 0, canvas.width, canvas.height).data;
          pixels.textContent = data.some((value, index) => index % 4 === 0 && value > 45)
            ? 'mesh drawn' : 'blank';
          for (const [id, key] of [['rotate', 'ArrowLeft'], ['zoom', '+']]) {
            document.getElementById(id).onclick = () => {
              const before = canvas.toDataURL();
              canvas.dispatchEvent(new KeyboardEvent('keydown', { key, cancelable: true }));
              pixels.textContent = canvas.toDataURL() === before ? 'unchanged' : id;
            };
          }
        `],
      ]),
      checks: [
        { action: 'text', selector: '#dimensions', value: '80 × 60 × 30 mm' },
        { action: 'text', selector: '#pixels', value: 'mesh drawn' },
        { action: 'click', selector: '#rotate' },
        { action: 'text', selector: '#pixels', value: 'rotate' },
        { action: 'click', selector: '#zoom' },
        { action: 'text', selector: '#pixels', value: 'zoom' },
      ],
    });
    assert.equal(result.status, 'passed', JSON.stringify(result));
  });

test('Chromium imports the actual STL through the preview element file input',
  { skip: !chromium, timeout: 45000 }, async () => {
    const { stl } = await renderOpenBox({ ...box, width: 90 });
    const elementFiles = ['studio_3d_preview.mjs', 'studio_3d_preview_element.mjs'];
    const assets = new Map(await Promise.all(elementFiles.map(async name =>
      [name, await readFile(new URL(`../../web/${name}`, import.meta.url), 'utf8')])));
    assets.set('index.html', '<!doctype html><aivexus-stl-preview></aivexus-stl-preview><output id="result"></output><script type="module" src="fixture.mjs"></script>');
    assets.set('fixture.mjs', `
      import './studio_3d_preview_element.mjs';
      const root = document.querySelector('aivexus-stl-preview').shadowRoot;
      const input = root.querySelector('input[type=file]');
      const canvas = root.querySelector('canvas');
      const status = root.querySelector('output:not([data-job])');
      new MutationObserver(() => {
        document.querySelector('#result').textContent =
          canvas.hidden ? status.textContent : status.textContent + ' rendered';
      }).observe(status, { childList: true });
      const selection = new DataTransfer();
      selection.items.add(new File([${JSON.stringify(stl.toString('ascii'))}], 'box.stl'));
      input.files = selection.files;
      input.dispatchEvent(new Event('change'));
    `);
    const result = await createChromiumWebVerifier({ executable: chromium })({
      assets,
      checks: [
        { action: 'text', selector: '#result', value: '90 × 60 × 30 mm rendered' },
      ],
    });
    assert.equal(result.status, 'passed', JSON.stringify(result));
  });

test('encrypts the real CAD job and verifies its encrypted result and ticket',
  { skip: !chromium }, async () => {
    const makeKey = () => crypto.subtle.generateKey({
      name: 'RSA-OAEP', modulusLength: 2048, hash: 'SHA-256',
      publicExponent: Uint8Array.of(1, 0, 1),
    }, true, ['encrypt', 'decrypt']);
    const [runner, pages] = await Promise.all([makeKey(), makeKey()]);
    const authorizationKey = await importWebAppAuthorizationKey(
      encodeRunnerBase64(crypto.getRandomValues(new Uint8Array(32))));
    const ticket = crypto.randomUUID();
    const resultPublicKeySpki = encodeRunnerBase64(new Uint8Array(
      await crypto.subtle.exportKey('spki', pages.publicKey)));
    const { input, jobSha256 } = await encodeWebAppJob({
      publicKey: runner.publicKey, authorizationKey, ticket, resultPublicKeySpki,
      source: { kind: 'cad_open_box', parameters: box }, checks: [],
    });
    const runnerRequest = { input, ticket, privateKey: runner.privateKey, authorizationKey };
    await assert.rejects(runEncryptedStudioCadJob({ ...runnerRequest, ticket: crypto.randomUUID() }));
    const packet = await runEncryptedStudioCadJob(runnerRequest);
    const { manifest, stl } = await decodeWebAppResult({
      privateKey: pages.privateKey, authorizationKey, ticket, packet, jobSha256,
    });
    assert.deepEqual(manifest.parameters, box);
    assert.equal(await runnerPayloadSha256(decodeRunnerBase64(stl, 90000)),
      manifest.files.find(file => file.name === 'box.stl').sha256);
  });

test('Chromium submits dimensions and opens the verified CAD revision after refresh',
  { skip: !chromium, timeout: 45000 }, async () => {
    const { stl } = await renderOpenBox({ ...box, width: 90 });
    const names = ['studio_3d_preview.mjs', 'studio_3d_preview_element.mjs'];
    const assets = new Map(await Promise.all(names.map(async name =>
      [name, await readFile(new URL(`../../web/${name}`, import.meta.url), 'utf8')])));
    assets.set('index.html', '<!doctype html><button id="start">Start</button><button id="refresh">Refresh</button><output id="state"></output><script type="module" src="fixture.mjs"></script>');
    assets.set('fixture.mjs', `
      let revisionId;
      let saved = false;
      const projectId = 'web-project:1795000000000000';
      globalThis.fetch = async (path, options) => {
        const url = new URL(path, location.origin);
        if (url.pathname.endsWith('/job')) {
          const request = JSON.parse(options.body);
          if (request.projectId !== projectId) throw new Error('Bad project');
          if (request.action === 'start') {
            if (request.parameters.width !== 90 || request.parameters.wall !== 2 ||
                request.baseRevisionId !== null || revisionId) throw new Error('Bad job');
            revisionId = request.revisionId;
            return Response.json({ status: 'submitted' });
          }
          if (request.action !== 'collect' || request.revisionId !== revisionId) throw new Error('Bad ticket');
          saved = true;
          return Response.json({ status: 'verified' });
        }
        if (url.searchParams.get('file') === 'history') {
          return Response.json({ revisions: saved ? [{ revisionId, revisionNumber: 1 }] : [] });
        }
        if (saved && url.searchParams.get('file') === 'stl' &&
            url.searchParams.get('revisionId') === revisionId) {
          return new Response(${JSON.stringify(stl.toString('ascii'))});
        }
        throw new Error('Unexpected request');
      };
      import './studio_3d_preview_element.mjs';
      const viewer = document.createElement('aivexus-stl-preview');
      viewer.setAttribute('project-id', projectId);
      document.body.append(viewer);
      const root = viewer.shadowRoot;
      const state = document.querySelector('#state');
      const status = root.querySelectorAll('output');
      new MutationObserver(() => {
        state.textContent = status[1].textContent.includes('90 × 60 × 30 mm')
          ? 'revision rendered' : status[0].textContent;
      }).observe(root, { childList: true, subtree: true });
      document.querySelector('#start').onclick = () => {
        root.querySelector('[name=width]').value = 90;
        root.querySelector('form').requestSubmit();
      };
      document.querySelector('#refresh').onclick = () => root.querySelector('[data-refresh]').click();
    `);
    const result = await createChromiumWebVerifier({ executable: chromium })({
      assets,
      checks: [
        { action: 'click', selector: '#start' },
        { action: 'text', selector: '#state', value: 'Generazione CAD in corso. Usa Aggiorna generazione per verificarne l’esito.' },
        { action: 'click', selector: '#refresh' },
        { action: 'text', selector: '#state', value: 'revision rendered' },
      ],
    });
    assert.equal(result.status, 'passed', JSON.stringify(result));
  });
