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

export function mountStudioPhotoMeasurement(panel, onApply, signal) {
  const input = panel.querySelector('[data-photo-file]');
  const canvas = panel.querySelector('canvas');
  const status = panel.querySelector('output');
  const reference = panel.querySelector('[data-photo-reference]');
  const axis = panel.querySelector('select');
  const apply = panel.querySelector('[data-photo-apply]');
  const reset = panel.querySelector('[data-photo-reset]');
  const context = canvas.getContext('2d');
  if (!context) return;

  let image;
  let points = [];
  let estimate;
  let imageVersion = 0;

  function redraw() {
    if (!image) return;
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
      bitmap = undefined;
      const scale = Math.min(1, 1000 / Math.max(image.width, image.height));
      canvas.width = Math.max(2, Math.round(image.width * scale));
      canvas.height = Math.max(2, Math.round(image.height * scale));
      canvas.hidden = false;
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
    if (!image || points.length === 4) return;
    const bounds = canvas.getBoundingClientRect();
    points.push({
      x: (event.clientX - bounds.left) * canvas.width / bounds.width,
      y: (event.clientY - bounds.top) * canvas.height / bounds.height,
    });
    redraw();
  }, { signal });
  reset.addEventListener('click', () => { points = []; redraw(); }, { signal });
  reference.addEventListener('input', redraw, { signal });
  apply.addEventListener('click', () => {
    if (estimate !== null) onApply(axis.value, estimate);
  }, { signal });
  signal.addEventListener('abort', () => image?.close(), { once: true });
}
