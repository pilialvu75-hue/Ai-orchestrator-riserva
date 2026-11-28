import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { createChromiumWebVerifier } from '../../scripts/web/chromium_web_verifier.mjs';
import { test } from 'node:test';
import { createOpenBoxCad, renderOpenBox } from '../../scripts/web/studio_3d_open_box.mjs';

import { createStudioRoundStl, mountStudioStlPreview, readStudioStl } from '../../web/studio_3d_preview.mjs';

import { runEncryptedStudioCadJob } from '../../scripts/web/run_encrypted_studio_cad_job.mjs';
import { decodeRunnerBase64, decodeWebAppResult, encodeRunnerBase64, encodeWebAppJob,
  importWebAppAuthorizationKey, runnerPayloadSha256 } from '../../scripts/web/web_application_runner_packet.mjs';

import { detectPhotoCavity, detectPhotoSilhouette, estimatePhotoDimension, extrudePhotoProfile, isRectangularPhotoSilhouette, nextPhotoView, reconstructPhotoVolume, tracePhotoProfile } from '../../web/studio_3d_photo.mjs';
import { checkOpenBoxFdm } from '../../web/studio_3d_fdm.mjs';

const box = { width: 80, depth: 60, height: 30, wall: 2, floor: 3 };

test('generates closed binary STL for a sphere and an open tapered cup', () => {
  const sphere = readStudioStl(createStudioRoundStl({ shape: 'sphere', diameter: 80 }));
  const parameters = { shape: 'cup', diameter: 80, baseDiameter: 60, height: 90, wall: 3, floor: 4 };
  const cup = readStudioStl(createStudioRoundStl(parameters));
  assert.deepEqual(sphere.bounds, [[-40, 40], [-40, 40], [0, 80]]);
  assert.deepEqual(cup.bounds, [[-40, 40], [-40, 40], [0, 90]]);
  assert.ok(cup.faces.flat().some(([x, y, z]) => x === 0 && y === 0 && z === 4));
  assert.ok(cup.faces.flat().filter(vertex => vertex[2] === 90)
    .every(([x, y]) => Math.hypot(x, y) > 36.9));
  assert.throws(() => createStudioRoundStl({ ...parameters, wall: 30 }), RangeError);
  for (const { faces } of [sphere, cup]) {
    const edges = new Map();
    for (const face of faces) {
      for (let i = 0; i < face.length; i++) {
        const start = face[i].join(',');
        const end = face[(i + 1) % face.length].join(',');
        const key = [start, end].sort().join('|');
        const edge = edges.get(key) ?? [];
        edge.push(start < end);
        edges.set(key, edge);
      }
    }
    assert.ok([...edges.values()].every(edge => edge.length === 2 && edge[0] !== edge[1]));
  }
});

test('intersects three measured silhouettes into a closed non-extruded volume', () => {
  const outline = coordinates => coordinates.map(([x, y]) => ({ x, y }));
  const square = outline([[0, 0], [8, 0], [8, 8], [0, 8]]);
  const step = outline([[0, 0], [4, 0], [4, 4], [8, 4], [8, 8], [0, 8]]);
  const { faces, bounds } = readStudioStl(reconstructPhotoVolume(
    { front: step, side: step, top: square }, [80, 64, 48]));
  assert.deepEqual(bounds, [[0, 80], [0, 64], [0, 48]]);
  assert.equal(Math.max(...faces.flat().filter(vertex => vertex[2] === 48).map(vertex => vertex[0])), 40);
  assert.equal(Math.max(...faces.flat().filter(vertex => vertex[2] === 48).map(vertex => vertex[1])), 32);
  assert.throws(() => reconstructPhotoVolume({ front: step, side: step }, [80, 64, 48]), /tre le viste/);
});

test('traces a non-rectangular silhouette while rejecting a profile with a hole', () => {
  const width = 32, height = 32;
  const data = new Uint8ClampedArray(width * height * 4).fill(255);
  for (let y = 6; y < 26; y++) {
    for (let x = 6; x < (y < 13 ? 26 : 13); x++) {
      data.fill(0, (y * width + x) * 4, (y * width + x) * 4 + 3);
    }
  }
  const image = { width, height, data };
  const contour = tracePhotoProfile(image);
  assert.equal(contour.length, 6);
  assert.deepEqual(readStudioStl(extrudePhotoProfile(contour, 40, 5)).bounds,
    [[0, 40], [0, 40], [0, 5]]);
  data.fill(255, (9 * width + 9) * 4, (9 * width + 9) * 4 + 4);
  assert.equal(tracePhotoProfile(image), null);
});

test('extrudes a concave outline to scale with closed, oriented edges', () => {
  const profile = [[0, 0], [40, 0], [40, 10], [10, 10], [10, 30], [0, 30]]
    .map(([x, y]) => ({ x, y }));
  for (const points of [profile, [...profile].reverse()]) {
    const { bounds, faces } = readStudioStl(extrudePhotoProfile(points, 80, 5));
    assert.deepEqual(bounds, [[0, 80], [0, 60], [0, 5]]);
    assert.equal(faces.length, 20);
    const edgeCounts = new Map();
    const edgeDirections = new Map();
    for (const face of faces) {
      for (let i = 0; i < 3; i++) {
        const start = face[i].join(',');
        const end = face[(i + 1) % 3].join(',');
        const key = [start, end].sort().join('|');
        edgeCounts.set(key, (edgeCounts.get(key) ?? 0) + 1);
        edgeDirections.set(key, (edgeDirections.get(key) ?? 0) + (start < end ? 1 : -1));
      }
    }
    assert.ok([...edgeCounts.values()].every(count => count === 2));
    assert.ok([...edgeDirections.values()].every(direction => direction === 0));
  }
  const crossing = [[0, 0], [20, 20], [20, 0], [0, 20]].map(([x, y]) => ({ x, y }));
  assert.throws(() => extrudePhotoProfile(crossing, 80, 5), /si incrocia/);
  assert.throws(() => extrudePhotoProfile(profile, 80, 0), RangeError);
});

test('accepts numeric dimensions and rejects invalid cavities and source injection', () => {
  assert.match(createOpenBoxCad(box), /width = 80;/);
  const sample = checkOpenBoxFdm(box);
  assert.ok(sample.fitsVolume && sample.wallMeetsMinimum && sample.floorMeetsMinimum);
  const oversize = checkOpenBoxFdm({ ...box, width: 221, wall: 0.4, floor: 0.5 });
  assert.equal(oversize.fitsVolume, false);
  assert.equal(oversize.wallMeetsMinimum, false);
  assert.equal(oversize.floorMeetsMinimum, false);
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
    assert.deepEqual(verification.cavityMm, { wall: 2, floor: 3 });
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

test('Chromium turns a photo into a downloadable STL preview',
  { skip: !chromium, timeout: 45000 }, async () => {
    const names = ['studio_3d_preview.mjs', 'studio_3d_preview_element.mjs',
      'studio_3d_fdm.mjs', 'studio_3d_photo.mjs'];
    const assets = new Map(await Promise.all(names.map(async name =>
      [name, await readFile(new URL(`../../web/${name}`, import.meta.url), 'utf8')])));
    assets.set('index.html', '<!doctype html><button id="start">Load photo</button><button id="volume">Generate volume</button><button id="round">Generate sphere</button><output id="result"></output><script type="module" src="fixture.mjs"></script>');
    assets.set('fixture.mjs', `
      import './studio_3d_preview_element.mjs';
      globalThis.fetch = async () => ({ ok: true, json: async () => ({ revisions: [], activeJob: null }) });
      const viewer = document.createElement('aivexus-stl-preview');
      viewer.setAttribute('project-id', 'web-project:1795000000000000');
      document.body.append(viewer);
      const root = viewer.shadowRoot;
      const panel = root.querySelector('[data-photo]');
      panel.open = true;
      document.querySelector('#round').onclick = () => {
        const form = root.querySelector('[data-round] form');
        const shape = form.elements.namedItem('shape');
        shape.value = 'sphere';
        shape.dispatchEvent(new Event('change'));
        form.dispatchEvent(new SubmitEvent('submit', { cancelable: true }));
        const link = root.querySelector('[data-profile-download]');
        if (!link.hidden && link.download === 'sfera.stl' && form.querySelector('fieldset').disabled) {
          document.querySelector('#result').textContent = root.querySelector('output:not([data-job])').textContent;
        }
      };
      document.querySelector('#volume').onclick = () => {
        const volume = panel.querySelector('[data-photo-volume]');
        volume.open = true;
        volume.querySelector('[data-volume-generate]').click();
        if (!volume.querySelector('output').textContent.includes('tre le viste')) return;
        const select = volume.querySelector('select');
        for (const view of ['front', 'side', 'top']) {
          select.value = view;
          volume.querySelector('[data-volume-save]').click();
        }
        for (const [i, field] of [...volume.querySelectorAll('input')].entries()) {
          field.value = [80, 60, 50][i];
        }
        volume.querySelector('[data-volume-generate]').click();
        const link = root.querySelector('[data-profile-download]');
        if (!link.hidden && link.download === 'volume-da-foto.stl' && link.href.startsWith('blob:')) {
          document.querySelector('#result').textContent = 'Volume STL pronto';
        }
      };
      document.querySelector('#start').onclick = () => {
        panel.querySelector('[data-photo-profile-mode]').click();
        panel.querySelector('[data-profile-width]').value = 80;
        panel.querySelector('[data-profile-thickness]').value = 5;
        const image = document.createElement('canvas');
        image.width = image.height = 120;
        const ink = image.getContext('2d');
        ink.fillStyle = '#fff';
        ink.fillRect(0, 0, 120, 120);
        ink.fillStyle = '#111';
        ink.fillRect(20, 20, 80, 20);
        ink.fillRect(20, 40, 20, 40);
        const bytes = Uint8Array.from(atob(image.toDataURL().split(',')[1]), ch => ch.charCodeAt(0));
        const file = panel.querySelector('[data-photo-file]');
        const observer = new MutationObserver(() => {
          if (panel.querySelector('canvas').hidden) return;
          observer.disconnect();
          panel.querySelector('[data-profile-detect]').click();
          panel.querySelector('[data-profile-generate]').click();
          const link = root.querySelector('[data-profile-download]');
          const preview = root.querySelector('canvas');
          if (!preview.hidden && !link.hidden && link.download === 'sagoma.stl' &&
              link.href.startsWith('blob:')) {
            document.querySelector('#result').textContent =
              root.querySelector('output:not([data-job])').textContent;
          }
        });
        observer.observe(panel.querySelector('[data-photo-status]'), { childList: true });
        const selection = new DataTransfer();
        selection.items.add(new File([bytes], 'profile.png', { type: 'image/png' }));
        file.files = selection.files;
        file.dispatchEvent(new Event('change'));
      };
    `);
    const result = await createChromiumWebVerifier({ executable: chromium })({
      assets,
      checks: [
        { action: 'click', selector: '#start' },
        { action: 'text', selector: '#result', value: '80 × 60 × 5 mm' },
        { action: 'click', selector: '#volume' },
        { action: 'text', selector: '#result', value: 'Volume STL pronto' },
        { action: 'click', selector: '#round' },
        { action: 'text', selector: '#result', value: '80 × 80 × 80 mm' },
      ],
    });
    assert.equal(result.status, 'passed', JSON.stringify(result));
  });
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
    const elementFiles = ['studio_3d_preview.mjs', 'studio_3d_preview_element.mjs', 'studio_3d_fdm.mjs', 'studio_3d_photo.mjs'];
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
    const names = ['studio_3d_preview.mjs', 'studio_3d_preview_element.mjs', 'studio_3d_fdm.mjs', 'studio_3d_photo.mjs'];
    const assets = new Map(await Promise.all(names.map(async name =>
      [name, await readFile(new URL(`../../web/${name}`, import.meta.url), 'utf8')])));
    assets.set('index.html', '<!doctype html><button id="photo">Load synthetic photo</button><button id="side">Load side photo</button><button id="start">Start</button><button id="confirm">Confirm dimensions</button><button id="refresh">Refresh</button><button id="bed">Smaller bed</button><output id="state"></output><script type="module" src="fixture.mjs"></script>');
    assets.set('fixture.mjs', `
      // Chromium's intercepted test origin is HTTP, so supply a deterministic UUID.
      Object.defineProperty(crypto, 'randomUUID', { value: () => 'a1000000-0000-4000-8000-000000000001' });
      const json = data => ({ ok: true, json: async () => data });
      let revisionId;
      let saved = false;
      const projectId = 'web-project:1795000000000000';
      globalThis.fetch = async (path, options) => {
        const url = new URL(path, location.origin);
        if (url.pathname.endsWith('/job')) {
          const request = JSON.parse(options.body);
          if (request.projectId !== projectId) throw new Error('Bad project');
          if (request.action === 'resume') return json({ activeJob: null });
          if (request.action === 'start') {
            if (request.parameters.width !== 90 || request.parameters.wall !== 2 ||
                request.parameters.depth !== 60 || request.photoEstimates?.join() !== 'width,depth' || request.baseRevisionId !== null || revisionId) throw new Error('Bad job');
            revisionId = request.revisionId;
            return json({ status: 'submitted' });
          }
          if (request.action === 'select') return json({ activeRevisionId: revisionId });
          if (request.action !== 'collect' || request.revisionId !== revisionId) throw new Error('Bad ticket');
          saved = true;
          return json({ status: 'verified' });
        }
        if (url.searchParams.get('file') === 'history') {
          return json({ revisions: saved ? [{ revisionId, revisionNumber: 1, selected: true, parameters: { ...${JSON.stringify(box)}, width: 90 } }] : [] });
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
      const status = root.querySelectorAll('output:not([data-photo-status])');
      const observer = new MutationObserver(() => {
        state.textContent = status[1].textContent.includes('90 × 60 × 30 mm')
          ? 'revision rendered' : status[0].textContent;
      });
      for (const output of status) observer.observe(output, { childList: true });
      const loadPhoto = (objectWidth, view) => {
        const panel = root.querySelector('[data-photo]');
        panel.open = true;
        const source = document.createElement('canvas');
        source.width = 220;
        source.height = 80;
        const ink = source.getContext('2d');
        ink.fillStyle = '#ddd';
        ink.fillRect(0, 0, 220, 80);
        ink.fillStyle = '#222';
        ink.fillRect(10, 10, 100, 5);
        ink.fillRect(10, 40, objectWidth, 20);
        const bytes = Uint8Array.from(atob(source.toDataURL('image/png').split(',')[1]), char => char.charCodeAt(0));
        const photo = panel.querySelector('[data-photo-file]');
        const marker = panel.querySelector('[data-photo-status]');
        const ready = new MutationObserver(() => {
          const image = panel.querySelector('canvas');
          if (image.hidden) return;
          ready.disconnect();
          const measure = panel.querySelector('[data-photo-reference]');
          measure.value = 50;
          measure.dispatchEvent(new Event('input'));
          image.style.width = '220px';
          const rect = image.getBoundingClientRect();
          for (const [x, y] of [[10, 12], [110, 12]]) {
            image.dispatchEvent(new MouseEvent('click', {
              clientX: rect.left + rect.width * x / image.width,
              clientY: rect.top + rect.height * y / image.height,
            }));
          }
          panel.querySelector('[data-photo-detect]').click();
          panel.querySelector('[data-photo-apply]').click();
          if (view === 'front') {
            const angle = panel.querySelector('[data-photo-view]');
            angle.value = 'side';
            angle.dispatchEvent(new Event('change'));
            if (!image.hidden || !panel.querySelector('[data-photo-apply]').disabled) {
              throw new Error('A front photo cannot supply a side measurement');
            }
          }
          state.textContent = root.querySelector('[data-estimate-note]').textContent;
        });
        ready.observe(marker, { childList: true });
        const selection = new DataTransfer();
        selection.items.add(new File([bytes], 'synthetic-' + view + '.png', { type: 'image/png' }));
        photo.files = selection.files;
        photo.dispatchEvent(new Event('change'));
      };
      document.querySelector('#photo').onclick = () => loadPhoto(180, 'front');
      document.querySelector('#side').onclick = () => loadPhoto(120, 'side');
      document.querySelector('#start').onclick = () => {
        const form = root.querySelector('form');
        if (!form.checkValidity()) throw new Error('Invalid CAD form fixture');
        // The verifier's CSP sandbox blocks native form submission. Exercise
        // the same event handler without permitting navigation or form posts.
        form.dispatchEvent(new SubmitEvent('submit', { cancelable: true }));
      };
      document.querySelector('#confirm').onclick = () => {
        for (const [axis, value] of Object.entries({ height: 30, wall: 2, floor: 3 })) {
          const field = root.querySelector('[name=' + axis + ']');
          field.value = value;
          field.dispatchEvent(new Event('input', { bubbles: true }));
        }
        const checkbox = root.querySelector('[data-photo-confirm]');
        if (checkbox.disabled) throw new Error('Cannot confirm complete photo dimensions');
        checkbox.checked = true;
      };
      document.querySelector('#refresh').onclick = () => root.querySelector('[data-refresh]').click();
      document.querySelector('#bed').onclick = () => {
        const panel = root.querySelector('[data-fdm]');
        if (panel.hidden) throw new Error('Missing printer checks');
        const width = panel.querySelector('[data-bed]');
        width.value = 60;
        width.dispatchEvent(new Event('input', { bubbles: true }));
        document.querySelector('#state').textContent = panel.querySelector('li').textContent;
      };
    `);
    const result = await createChromiumWebVerifier({ executable: chromium })({
      assets,
      checks: [
        { action: 'click', selector: '#photo' },
        { action: 'text', selector: '#state', value: 'larghezza: 90 mm (stima da foto)' },
        { action: 'click', selector: '#side' },
        { action: 'text', selector: '#state', value: 'larghezza: 90 mm (stima da foto) · profondità: 60 mm (stima da foto)' },
        { action: 'click', selector: '#start' },
        { action: 'text', selector: '#state', value: 'Completa e conferma le quote della fotografia.' },
        { action: 'click', selector: '#confirm' },
        { action: 'click', selector: '#start' },
        { action: 'text', selector: '#state', value: 'Generazione CAD in corso. Usa Aggiorna generazione per verificarne l’esito.' },
        { action: 'click', selector: '#refresh' },
        { action: 'text', selector: '#state', value: 'revision rendered' },
        { action: 'click', selector: '#bed' },
        { action: 'text', selector: '#state', value: 'La scatola supera il volume scelto.' },
      ],
    });
    assert.equal(result.status, 'passed', JSON.stringify(result));
  });

test('estimates only a calibrated visible segment from a synthetic photo fixture', () => {
  const points = [{ x: 10, y: 12 }, { x: 110, y: 12 }, { x: 20, y: 40 }, { x: 180, y: 40 }];
  assert.equal(estimatePhotoDimension(points, 50), 80);
  assert.equal(estimatePhotoDimension(points.slice(0, 3), 50), null);
  assert.equal(estimatePhotoDimension([points[0], points[0], ...points.slice(2)], 50), null);
  assert.equal(estimatePhotoDimension(points, 0), null);
});

test('finds the main image silhouette and requests the missing viewing angle', () => {
  const width = 30, height = 20;
  const data = new Uint8ClampedArray(width * height * 4).fill(255);
  for (let y = 6; y <= 15; y++) {
    for (let x = 4; x <= 24; x++) data.fill(20, (y * width + x) * 4, (y * width + x) * 4 + 3);
  }
  assert.deepEqual(detectPhotoSilhouette({ data, width, height }),
    { left: 4, top: 6, right: 24, bottom: 15, size: 210 });
  assert.equal(isRectangularPhotoSilhouette(detectPhotoSilhouette({ data, width, height })), true);
  assert.equal(isRectangularPhotoSilhouette({ left: 92, top: 61, right: 921, bottom: 801, size: 360645 }), false);
  data[0] = 0;
  assert.equal(detectPhotoSilhouette({ data, width, height }), null);
  assert.match(nextPhotoView(new Set(['width', 'height'])), /foto laterale/);
  assert.match(nextPhotoView(new Set(['width', 'height', 'depth'])), /foto superiore/);
});

test('estimates uniform walls only when a rectangular cavity is visible from above', () => {
  const width = 30, height = 30;
  const data = new Uint8ClampedArray(width * height * 4).fill(255);
  const draw = (start, end, color) => {
    for (let y = start; y < end; y++) {
      for (let x = start; x < end; x++) data.fill(color, (y * width + x) * 4, (y * width + x) * 4 + 3);
    }
  };
  draw(5, 25, 30);
  const image = { data, width, height };
  assert.equal(detectPhotoCavity(image, detectPhotoSilhouette(image)), null);
  draw(8, 22, 140);
  assert.deepEqual(detectPhotoCavity(image, detectPhotoSilhouette(image)), { wallPixels: 3 });
});
