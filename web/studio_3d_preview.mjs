export function readStudioStl(source) {
  if (typeof source !== 'string' || source.length > 131072) {
    throw new Error('Invalid STL size');
  }
  const vertices = [...source.matchAll(/\bvertex\s+(\S+)\s+(\S+)\s+(\S+)/g)]
    .map(match => match.slice(1).map(Number));
  if (vertices.length < 12 || vertices.length % 3 ||
      vertices.some(vertex => vertex.some(value => !Number.isFinite(value)))) {
    throw new Error('Invalid ASCII STL vertices');
  }
  const bounds = [0, 1, 2].map(axis => {
    const coordinates = vertices.map(vertex => vertex[axis]);
    return [Math.min(...coordinates), Math.max(...coordinates)];
  });
  const faces = [];
  for (let index = 0; index < vertices.length; index += 3) {
    faces.push(vertices.slice(index, index + 3));
  }
  return { faces, bounds };
}

export function mountStudioStlPreview(canvas, source, dimensionsLabel) {
  const { faces, bounds } = readStudioStl(source);
  const context = canvas.getContext('2d');
  if (!context) throw new Error('Canvas 2D is unavailable');
  const dimensions = bounds.map(([low, high]) => high - low);
  dimensionsLabel.textContent = dimensions.map(value => Number(value.toFixed(3))).join(' × ') + ' mm';
  const center = bounds.map(([low, high]) => (low + high) / 2);
  const radius = Math.max(...dimensions);
  if (radius <= 0) throw new Error('Empty STL bounds');

  let yaw = -0.55;
  let pitch = 0.8;
  let zoom = 1;
  let panX = 0;
  let panY = 0;
  let drag = null;

  function draw() {
    const { width, height } = canvas;
    const scale = Math.min(width, height) * 0.48 * zoom / radius;
    const cosYaw = Math.cos(yaw);
    const sinYaw = Math.sin(yaw);
    const cosPitch = Math.cos(pitch);
    const sinPitch = Math.sin(pitch);
    function project(vertex) {
      const [x, y, z] = vertex.map((value, axis) => value - center[axis]);
      const rotatedY = x * sinYaw + y * cosYaw;
      return [
        width / 2 + panX + scale * (x * cosYaw - y * sinYaw),
        height / 2 + panY + scale * (rotatedY * cosPitch - z * sinPitch),
        rotatedY * sinPitch + z * cosPitch,
      ];
    }
    function path(points) {
      context.beginPath();
      context.moveTo(points[0][0], points[0][1]);
      for (const [x, y] of points.slice(1)) context.lineTo(x, y);
    }

    context.fillStyle = '#111822';
    context.fillRect(0, 0, width, height);
    const [left, front, bottom] = bounds.map(([low]) => low);
    const [right, back, top] = bounds.map(([, high]) => high);
    context.strokeStyle = '#334457';
    for (let index = 0; index <= 10; index++) {
      const x = left + dimensions[0] * index / 10;
      const y = front + dimensions[1] * index / 10;
      path([[x, front, bottom], [x, back, bottom]].map(project));
      context.stroke();
      path([[left, y, bottom], [right, y, bottom]].map(project));
      context.stroke();
    }

    const projectedFaces = faces.map(face => {
      const points = face.map(project);
      return { points, depth: points.reduce((sum, point) => sum + point[2], 0) };
    });
    projectedFaces.sort((first, second) => first.depth - second.depth);
    context.strokeStyle = '#4e718a';
    for (const { points, depth } of projectedFaces) {
      path(points);
      context.closePath();
      const light = Math.round(56 + 40 * (0.5 + depth / (6 * radius)));
      context.fillStyle = `rgb(${light}, ${light + 51}, ${light + 76})`;
      context.fill();
      context.stroke();
    }

    const axes = [
      ['X', '#ff8a82', [right + radius * 0.18, front, bottom]],
      ['Y', '#8be2ae', [left, back + radius * 0.18, bottom]],
      ['Z', '#8bbcff', [left, front, top + radius * 0.18]],
    ];
    for (const [label, color, end] of axes) {
      const endpoint = project(end);
      path([project([left, front, bottom]), endpoint]);
      context.strokeStyle = color;
      context.stroke();
      context.fillStyle = color;
      context.fillText(label, endpoint[0] + 3, endpoint[1] - 3);
    }
  }

  const events = new AbortController();
  const options = { signal: events.signal };
  canvas.addEventListener('pointerdown', event => {
    if (drag || event.button !== 0) return;
    drag = { id: event.pointerId, x: event.clientX, y: event.clientY, pan: event.shiftKey };
    canvas.setPointerCapture(event.pointerId);
  }, options);
  canvas.addEventListener('pointermove', event => {
    if (drag?.id !== event.pointerId) return;
    const dx = event.clientX - drag.x;
    const dy = event.clientY - drag.y;
    if (drag.pan) {
      panX += dx * canvas.width / canvas.clientWidth;
      panY += dy * canvas.height / canvas.clientHeight;
    } else {
      yaw += dx * 0.012;
      pitch += dy * 0.012;
    }
    drag.x = event.clientX;
    drag.y = event.clientY;
    draw();
  }, options);
  canvas.addEventListener('lostpointercapture', event => {
    if (drag?.id === event.pointerId) drag = null;
  }, options);
  function adjustZoom(factor) {
    zoom = Math.min(6, Math.max(0.25, zoom * factor));
  }
  canvas.addEventListener('wheel', event => {
    event.preventDefault();
    adjustZoom(Math.exp(-event.deltaY * 0.001));
    draw();
  }, { ...options, passive: false });
  canvas.addEventListener('keydown', event => {
    const commands = {
      ArrowLeft: () => event.shiftKey ? panX -= 12 : yaw -= 0.15,
      ArrowRight: () => event.shiftKey ? panX += 12 : yaw += 0.15,
      ArrowUp: () => event.shiftKey ? panY -= 12 : pitch -= 0.15,
      ArrowDown: () => event.shiftKey ? panY += 12 : pitch += 0.15,
      '+': () => adjustZoom(1.15),
      '-': () => adjustZoom(1 / 1.15),
    };
    if (!Object.hasOwn(commands, event.key)) return;
    event.preventDefault();
    commands[event.key]();
    draw();
  }, options);
  draw();
  return () => events.abort();
}
