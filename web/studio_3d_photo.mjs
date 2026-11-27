export function detectPhotoSilhouette({ data, width, height }) {
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
    } else {
      runnerUp = Math.max(runnerUp, size);
    }
  }
  if (!largest || largest.size < count * 0.02 || runnerUp > largest.size / 4 ||
      !largest.left || !largest.top || largest.right === width - 1 ||
      largest.bottom === height - 1) return null;
  return largest;
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

export function mountStudioPhotoMeasurement(panel, onApply, signal, onPhotoLoaded) {
  const input = panel.querySelector('[data-photo-file]');
  const canvas = panel.querySelector('canvas');
  const status = panel.querySelector('output');
  const reference = panel.querySelector('[data-photo-reference]');
  const axis = panel.querySelector('[data-photo-axis]');
  const apply = panel.querySelector('[data-photo-apply]');
  const reset = panel.querySelector('[data-photo-reset]');
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
    if (imageView !== view.value) {
      apply.disabled = true;
      canvas.hidden = true;
      status.textContent = 'Carica una foto per la nuova angolazione selezionata.';
      return;
    }
    canvas.hidden = false;
    context.drawImage(image, 0, 0, canvas.width, canvas.height);
    for (const [index, point] of points.entries()) {
      context.beginPath();
      context.arc(point.x, point.y, 5, 0, Math.PI * 2);
      context.fillStyle = index < 2 ? '#ffcd52' : '#54e7ff';
      context.fill();
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
      onPhotoLoaded?.();
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
    if (!image || imageView !== view.value || points.length === 4) return;
    const bounds = canvas.getBoundingClientRect();
    points.push({
      x: (event.clientX - bounds.left) * canvas.width / bounds.width,
      y: (event.clientY - bounds.top) * canvas.height / bounds.height,
    });
    redraw();
  }, { signal });
  reset.addEventListener('click', () => { points = []; redraw(); }, { signal });
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
