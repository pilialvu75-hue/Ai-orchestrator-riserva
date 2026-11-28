export function detectPhotoSilhouette({ data, width, height }, withPixels = false) {
  if (width < 8 || height < 8 || width * height > 1_000_000) return null;
  const count = width * height;
  const contrast = id => {
    const offset = id * 4;
    return Math.max(Math.abs(data[offset] - data[0]), Math.abs(data[offset + 1] - data[1]),
      Math.abs(data[offset + 2] - data[2]));
  };
  if ([width - 1, count - width, count - 1].some(id => contrast(id) > 24)) return null;
  const mask = new Uint8Array(count);
  for (let id = 0; id < count; id++) mask[id] = +(data[id * 4 + 3] >= 200 && contrast(id) > 48);
  const queue = new Int32Array(count);
  let largest;
  let runnerUp = 0;
  for (let id = 0; id < count; id++) {
    if (!mask[id]) continue;
    let left = width, top = height, right = 0, bottom = 0, size = 1;
    queue[0] = id;
    mask[id] = 0;
    const visit = neighbor => {
      if (!mask[neighbor]) return;
      mask[neighbor] = 0;
      queue[size++] = neighbor;
    };
    for (let slot = 0; slot < size; slot++) {
      const index = queue[slot];
      const x = index % width;
      const y = Math.floor(index / width);
      left = Math.min(left, x);
      right = Math.max(right, x);
      top = Math.min(top, y);
      bottom = Math.max(bottom, y);
      if (x > 0) visit(index - 1);
      if (x + 1 < width) visit(index + 1);
      if (y > 0) visit(index - width);
      if (y + 1 < height) visit(index + width);
    }
    if (!largest || size > largest.size) {
      runnerUp = largest?.size ?? 0;
      largest = { left, top, right, bottom, size };
      if (withPixels) largest.pixels = queue.slice(0, size);
    } else {
      runnerUp = Math.max(runnerUp, size);
    }
  }
  if (!largest || largest.size < count * 0.02 || runnerUp > largest.size / 4 ||
      !largest.left || !largest.top || largest.right === width - 1 ||
      largest.bottom === height - 1) return null;
  return largest;
}

export function tracePhotoProfile(image) {
  const silhouette = detectPhotoSilhouette(image, true);
  if (!silhouette) return null;
  const { width } = image;
  const stride = width + 1;
  const pixels = new Set(silhouette.pixels);
  const boundary = new Map();
  function edge(start, end) {
    if (boundary.has(start)) return false;
    boundary.set(start, end);
    return true;
  }
  for (const pixel of pixels) {
    const x = pixel % width, y = Math.floor(pixel / width);
    const corner = y * stride + x;
    if ((!pixels.has(pixel - width) && !edge(corner, corner + 1)) ||
        (!pixels.has(pixel + 1) && !edge(corner + 1, corner + stride + 1)) ||
        (!pixels.has(pixel + width) && !edge(corner + stride + 1, corner + stride)) ||
        (!pixels.has(pixel - 1) && !edge(corner + stride, corner))) return null;
  }
  const start = boundary.keys().next().value;
  let vertex = start;
  const contour = [];
  do {
    contour.push({ x: vertex % stride, y: Math.floor(vertex / stride) });
    const next = boundary.get(vertex);
    boundary.delete(vertex);
    if (next === undefined) return null;
    vertex = next;
  } while (vertex !== start);
  if (boundary.size) return null;
  const corners = contour.filter((p, i) => turn(contour.at(i - 1), p, contour[(i + 1) % contour.length]) !== 0);
  return corners.length >= 3 && corners.length <= 64 ? corners : null;
}

export function isRectangularPhotoSilhouette(outline) {
  if (!outline) return false;
  const width = outline.right - outline.left + 1;
  const height = outline.bottom - outline.top + 1;
  // A loose bounding box around flaps, an oblique view or an articulated
  // object should not supply a rectangular model's dimensions.
  return width >= 8 && height >= 8 && outline.size >= width * height * 0.85;
}

export function detectPhotoCavity(imageData, bounds) {
  const { data, width: imageWidth } = imageData;
  const { left, top, right, bottom } = bounds;
  const width = right - left + 1;
  const height = bottom - top + 1;
  const crop = new Uint8ClampedArray(width * height * 4);
  for (let y = 0; y < height; y++) {
    const start = ((top + y) * imageWidth + left) * 4;
    crop.set(data.subarray(start, start + width * 4), y * width * 4);
  }
  const cavity = detectPhotoSilhouette({ data: crop, width, height });
  if (!cavity) return null;
  const area = (cavity.right - cavity.left + 1) * (cavity.bottom - cavity.top + 1);
  const margins = [cavity.left, width - cavity.right - 1, cavity.top, height - cavity.bottom - 1];
  const wallPixels = margins.reduce((sum, value) => sum + value, 0) / margins.length;
  if (cavity.size < area * 0.9 || wallPixels < 2 ||
      margins.some(value => Math.abs(value - wallPixels) > Math.max(2, wallPixels * 0.25))) return null;
  return { wallPixels };
}

export function nextPhotoView(axes) {
  if (!axes.has('width') || !axes.has('height')) return 'Usa una foto frontale per larghezza e altezza.';
  if (!axes.has('depth')) return 'Aggiungi una foto laterale per stimare la profondità.';
  if (!axes.has('wall')) return 'Aggiungi una foto superiore per stimare le pareti.';
  return 'Controlla le stime e inserisci lo spessore del fondo misurato.';
}
export function estimatePhotoDimension(points, referenceMm) {
  if (points.length !== 4 || !Number.isFinite(referenceMm) || referenceMm <= 0 ||
      points.some(point => !Number.isFinite(point.x) || !Number.isFinite(point.y))) return null;
  const distance = (a, b) => Math.hypot(b.x - a.x, b.y - a.y);
  const reference = distance(points[0], points[1]);
  const target = distance(points[2], points[3]);
  if (reference < 1 || target < 1) return null;
  const estimate = target * referenceMm / reference;
  return estimate >= 0.1 && estimate <= 500 ? Number(estimate.toFixed(1)) : null;
}

const turn = (a, b, c) => (b.x - a.x) * (c.y - a.y) - (b.y - a.y) * (c.x - a.x);

export function extrudePhotoProfile(points, widthMm, thicknessMm) {
  if (points.length < 3 || points.length > 64 || points.some(p =>
    !Number.isFinite(p.x) || !Number.isFinite(p.y)) ||
    ![widthMm, thicknessMm].every(value => value >= 0.1 && value <= 500)) {
    throw new RangeError('Servono da 3 a 64 punti, larghezza e spessore da 0,1 a 500 mm.');
  }
  const minX = Math.min(...points.map(p => p.x));
  const maxY = Math.max(...points.map(p => p.y));
  const span = Math.max(...points.map(p => p.x)) - minX;
  const scale = widthMm / span;
  const ring = points.map(p => ({ x: (p.x - minX) * scale, y: (maxY - p.y) * scale }));
  const height = Math.max(...ring.map(p => p.y));
  if (!Number.isFinite(scale) || height < 0.1 || height > 500) {
    throw new RangeError('La sagoma deve avere dimensioni comprese tra 0,1 e 500 mm.');
  }
  const next = i => (i + 1) % ring.length;
  const epsilon = 1e-8;
  function onSegment(a, b, p) {
    return Math.abs(turn(a, b, p)) <= epsilon &&
      p.x >= Math.min(a.x, b.x) && p.x <= Math.max(a.x, b.x) &&
      p.y >= Math.min(a.y, b.y) && p.y <= Math.max(a.y, b.y);
  }
  for (const [i, a] of ring.entries()) {
    const b = ring[next(i)];
    if (Math.abs(turn(a, b, ring[next(next(i))])) <= epsilon) {
      throw new RangeError('Rimuovi i punti duplicati o allineati sullo stesso lato.');
    }
    for (let j = i + 2; j < ring.length; j++) {
      if (next(j) === i) continue;
      const c = ring[j], d = ring[next(j)];
      if ((turn(a, b, c) * turn(a, b, d) < 0 && turn(c, d, a) * turn(c, d, b) < 0) ||
          onSegment(a, b, c) || onSegment(a, b, d) || onSegment(c, d, a) || onSegment(c, d, b)) {
        throw new RangeError('Il contorno si incrocia. Segna i punti seguendo il bordo in ordine.');
      }
    }
  }
  const area = ring.reduce((sum, p, i) => sum + p.x * ring[next(i)].y - p.y * ring[next(i)].x, 0);
  if (area < 0) ring.reverse();
  const remaining = [...ring];
  const faces = [];
  const vertex = (p, z) => [p.x, p.y, z];
  function triangle(u, v, w) {
    const d = v.map((value, axis) => value - u[axis]);
    const e = w.map((value, axis) => value - u[axis]);
    const normal = [d[1] * e[2] - d[2] * e[1], d[2] * e[0] - d[0] * e[2], d[0] * e[1] - d[1] * e[0]];
    const magnitude = Math.hypot(...normal);
    const vertices = [u, v, w].map(point => `  vertex ${point.join(' ')}`).join('\n');
    faces.push(`facet normal ${normal.map(value => value / magnitude).join(' ')}\n outer loop\n${vertices}\n endloop\nendfacet`);
  }
  while (remaining.length >= 3) {
    const ear = remaining.findIndex((b, i) => {
      const a = remaining.at(i - 1), c = remaining[(i + 1) % remaining.length];
      return turn(a, b, c) > epsilon && !remaining.some(p => p !== a && p !== b && p !== c &&
        turn(a, b, p) >= -epsilon && turn(b, c, p) >= -epsilon && turn(c, a, p) >= -epsilon);
    });
    if (ear < 0) throw new RangeError('Impossibile chiudere la sagoma. Controlla i punti.');
    const a = remaining.at(ear - 1), b = remaining[ear], c = remaining[(ear + 1) % remaining.length];
    triangle(vertex(a, thicknessMm), vertex(b, thicknessMm), vertex(c, thicknessMm));
    triangle(vertex(c, 0), vertex(b, 0), vertex(a, 0));
    remaining.splice(ear, 1);
  }
  for (const [i, a] of ring.entries()) {
    const b = ring[next(i)];
    triangle(vertex(a, 0), vertex(b, 0), vertex(b, thicknessMm));
    triangle(vertex(a, 0), vertex(b, thicknessMm), vertex(a, thicknessMm));
  }
  return `solid sagoma\n${faces.join('\n')}\nendsolid sagoma\n`;
}

export function mountStudioPhotoMeasurement(panel, onApply, signal, onPhotoLoaded, onProfile) {
  const input = panel.querySelector('[data-photo-file]');
  const canvas = panel.querySelector('canvas');
  const status = panel.querySelector('output');
  const reference = panel.querySelector('[data-photo-reference]');
  const axis = panel.querySelector('[data-photo-axis]');
  const apply = panel.querySelector('[data-photo-apply]');
  const reset = panel.querySelector('[data-photo-reset]');
  const profileMode = panel.querySelector('[data-photo-profile-mode]');
  const profile = panel.querySelector('[data-photo-profile]');
  const context = canvas.getContext('2d');
  if (!context) return;

  const view = panel.querySelector('[data-photo-view]');
  const guide = panel.querySelector('[data-photo-guide]');
  const measured = new Set();
  guide.textContent = nextPhotoView(measured);
  let image;
  let imageView;
  let points = [];
  let estimate;
  let imageVersion = 0;

  function redraw() {
    if (!image) return;
    if (!profileMode.checked && imageView !== view.value) {
      apply.disabled = true;
      canvas.hidden = true;
      status.textContent = 'Carica una foto per la nuova angolazione selezionata.';
      return;
    }
    canvas.hidden = false;
    context.drawImage(image, 0, 0, canvas.width, canvas.height);
    if (profileMode.checked && points.length > 1) {
      context.beginPath();
      context.moveTo(points[0].x, points[0].y);
      for (const point of points.slice(1)) context.lineTo(point.x, point.y);
      if (points.length > 2) context.closePath();
      context.strokeStyle = '#54e7ff';
      context.lineWidth = 2;
      context.stroke();
    }
    for (const [index, point] of points.entries()) {
      context.beginPath();
      context.arc(point.x, point.y, 5, 0, Math.PI * 2);
      context.fillStyle = index < 2 ? '#ffcd52' : '#54e7ff';
      context.fill();
    }
    if (profileMode.checked) {
      status.textContent = `${points.length} punti. Segna il contorno esterno in ordine.`;
      return;
    }
    const prompts = [
      'Segna il primo estremo del riferimento.',
      'Segna il secondo estremo del riferimento.',
      'Segna il primo estremo dell’oggetto.',
      'Segna il secondo estremo dell’oggetto.',
    ];
    estimate = estimatePhotoDimension(points, reference.valueAsNumber);
    apply.disabled = estimate === null;
    status.textContent = estimate === null
      ? prompts[points.length] ?? 'Controlla i due segmenti e la misura di riferimento.'
      : `Stima sul piano della foto: ${estimate} mm. Verifica prima di usare la misura.`;
  }

  input.addEventListener('change', async () => {
    const version = ++imageVersion;
    const uploadedView = view.value;
    image?.close();
    image = undefined;
    points = [];
    apply.disabled = true;
    canvas.hidden = true;
    status.textContent = '';
    const file = input.files[0];
    if (!file) return;
    let bitmap;
    try {
      if (!['image/jpeg', 'image/png', 'image/webp'].includes(file.type) || file.size > 8 * 1024 * 1024) {
        throw new Error('Invalid photo');
      }
      bitmap = await createImageBitmap(file);
      if (signal.aborted || version !== imageVersion) return;
      if (bitmap.width < 2 || bitmap.height < 2 || bitmap.width * bitmap.height > 24_000_000) {
        throw new Error('Invalid photo dimensions');
      }
      image = bitmap;
      imageView = uploadedView;
      bitmap = undefined;
      const scale = Math.min(1, 1000 / Math.max(image.width, image.height));
      canvas.width = Math.max(2, Math.round(image.width * scale));
      canvas.height = Math.max(2, Math.round(image.height * scale));
      canvas.hidden = false;
      if (!profileMode.checked) onPhotoLoaded?.();
      redraw();
    } catch {
      if (!signal.aborted && version === imageVersion) {
        status.textContent = 'Apri una foto JPG, PNG o WebP fino a 8 MB e 24 megapixel.';
      }
    } finally {
      bitmap?.close();
    }
  }, { signal });

  canvas.addEventListener('click', event => {
    if (!image || (!profileMode.checked && imageView !== view.value) ||
        points.length >= (profileMode.checked ? 64 : 4)) return;
    const bounds = canvas.getBoundingClientRect();
    points.push({
      x: (event.clientX - bounds.left) * canvas.width / bounds.width,
      y: (event.clientY - bounds.top) * canvas.height / bounds.height,
    });
    redraw();
  }, { signal });
  reset.addEventListener('click', () => { points = []; redraw(); }, { signal });
  profileMode.addEventListener('change', () => {
    points = [];
    profile.hidden = !profileMode.checked;
    for (const field of panel.querySelectorAll('[data-photo-measure]')) field.hidden = profileMode.checked;
    if (!profileMode.checked && image) onPhotoLoaded?.();
    redraw();
  }, { signal });
  profile.querySelector('[data-profile-detect]').addEventListener('click', () => {
    if (!image) {
      status.textContent = 'Carica una foto prima di rilevare la sagoma.';
      return;
    }
    context.drawImage(image, 0, 0, canvas.width, canvas.height);
    const detected = tracePhotoProfile(context.getImageData(0, 0, canvas.width, canvas.height));
    if (!detected) {
      redraw();
      status.textContent = 'Contorno incerto o complesso. Usa uno sfondo uniforme oppure traccia il bordo a mano.';
      return;
    }
    points = detected;
    redraw();
    status.textContent = 'Sagoma rilevata. Controlla il bordo e inserisci le misure.';
  }, { signal });
  profile.querySelector('[data-profile-generate]').addEventListener('click', () => {
    try {
      if (!image) throw new RangeError('Carica una foto prima di tracciare la sagoma.');
      const width = profile.querySelector('[data-profile-width]').valueAsNumber;
      const thickness = profile.querySelector('[data-profile-thickness]').valueAsNumber;
      onProfile(extrudePhotoProfile(points, width, thickness));
      status.textContent = 'Sagoma estrusa. Controlla il modello nell’anteprima 3D.';
    } catch (error) {
      status.textContent = error instanceof RangeError ? error.message : 'Impossibile generare la sagoma.';
    }
  }, { signal });
  reference.addEventListener('input', redraw, { signal });
  view.addEventListener('change', () => {
    const allowed = { front: ['width', 'height'], side: ['depth', 'height'], top: ['width', 'depth', 'wall'] }[view.value];
    for (const option of axis.options) option.disabled = !allowed.includes(option.value);
    if (!allowed.includes(axis.value)) axis.value = allowed[0];
    points = [];
    redraw();
  }, { signal });
  axis.addEventListener('change', () => {
    points = points.slice(0, 2);
    redraw();
  }, { signal });
  panel.querySelector('[data-photo-detect]').addEventListener('click', () => {
    if (!image || imageView !== view.value || points.length < 2) {
      status.textContent = 'Segna prima i due estremi del riferimento.';
      return;
    }
    context.drawImage(image, 0, 0, canvas.width, canvas.height);
    const pixels = context.getImageData(0, 0, canvas.width, canvas.height);
    const bounds = detectPhotoSilhouette(pixels);
    if (!bounds) {
      redraw();
      status.textContent = 'Contorno incerto. Usa uno sfondo uniforme o segna gli estremi a mano.';
      return;
    }
    if (!isRectangularPhotoSilhouette(bounds)) {
      points = points.slice(0, 2);
      redraw();
      status.textContent = 'La sagoma non è abbastanza rettangolare. Riprova con una foto perpendicolare all’oggetto.';
      return;
    }
    const { left, top, right, bottom } = bounds;
    const x = (left + right) / 2;
    const y = (top + bottom) / 2;
    if (axis.value === 'wall') {
      const cavity = detectPhotoCavity(pixels, bounds);
      if (!cavity) {
        redraw();
        status.textContent = 'Cavità non distinguibile. Prova una vista superiore con bordi ben visibili.';
        return;
      }
      points = [...points.slice(0, 2), { x: left, y }, { x: left + cavity.wallPixels, y }];
      redraw();
      return;
    }
    const vertical = axis.value === 'height' || (axis.value === 'depth' && view.value === 'top');
    const extremes = vertical
      ? [{ x, y: top - 0.5 }, { x, y: bottom + 0.5 }]
      : [{ x: left - 0.5, y }, { x: right + 0.5, y }];
    points = [...points.slice(0, 2), ...extremes];
    redraw();
  }, { signal });
  apply.addEventListener('click', () => {
    if (imageView !== view.value || estimate === null || axis.selectedOptions[0]?.disabled) return;
    if (onApply(axis.value, estimate) === false) return;
    measured.add(axis.value);
    guide.textContent = nextPhotoView(measured);
  }, { signal });
  signal.addEventListener('abort', () => image?.close(), { once: true });
}
