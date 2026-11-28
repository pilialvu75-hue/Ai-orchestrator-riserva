export function readStudioStl(source) {
  const size = typeof source === 'string' ? source.length : source?.byteLength;
  if (!size || size > 131072) {
    throw new Error('Invalid STL size');
  }
  let vertices;
  if (source instanceof ArrayBuffer && size >= 84) {
    const data = new DataView(source);
    const triangles = data.getUint32(80, true);
    if (84 + triangles * 50 === size) {
      vertices = Array.from({ length: triangles * 3 }, (_, index) => {
        const offset = 96 + Math.floor(index / 3) * 50 + index % 3 * 12;
        return [0, 4, 8].map(axis => data.getFloat32(offset + axis, true));
      });
    }
  }
  if (!vertices) {
    const text = typeof source === 'string' ? source : new TextDecoder().decode(source);
    vertices = [...text.matchAll(/\bvertex\s+(\S+)\s+(\S+)\s+(\S+)/g)]
      .map(match => match.slice(1).map(Number));
  }
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

export function createStudioRoundStl({ shape, diameter, baseDiameter, height, wall, floor }) {
  const dimension = value => Number.isFinite(value) && value >= 0.5 && value <= 500;
  if (!dimension(diameter)) throw new RangeError('Inserisci un diametro tra 0,5 e 500 mm.');
  const radius = diameter / 2;
  let profile;
  if (shape === 'sphere') {
    profile = [[0, 0]];
    for (let i = 1; i < 24; i++) {
      const angle = Math.PI * i / 24;
      profile.push([radius * Math.sin(angle), radius * (1 - Math.cos(angle))]);
    }
    profile.push([0, diameter]);
  } else if (shape === 'cup') {
    if (![baseDiameter, height, wall, floor].every(dimension) ||
        2 * wall >= Math.min(diameter, baseDiameter) || floor >= height) {
      throw new RangeError('Verifica le quote. Pareti e fondo devono lasciare spazio alla cavità.');
    }
    const base = baseDiameter / 2;
    const innerFloor = base + (radius - base) * floor / height - wall;
    profile = [[0, 0], [base, 0], [radius, height], [radius - wall, height], [innerFloor, floor], [0, floor]];
  } else {
    throw new RangeError('Seleziona una sfera o un bicchiere.');
  }
  const segments = 48;
  const rings = profile.map(([r, z]) => Array.from({ length: segments }, (_, i) => {
    const angle = 2 * Math.PI * i / segments;
    return [Math.fround(r * Math.cos(angle)) || 0, Math.fround(r * Math.sin(angle)) || 0, Math.fround(z)];
  }));
  const count = (profile.length - 2) * segments * 2;
  const bytes = new ArrayBuffer(84 + count * 50);
  const data = new DataView(bytes);
  data.setUint32(80, count, true);
  let offset = 84;
  function write(a, b, c) {
    const u = b.map((value, axis) => value - a[axis]);
    const v = c.map((value, axis) => value - a[axis]);
    const normal = [u[1] * v[2] - u[2] * v[1], u[2] * v[0] - u[0] * v[2], u[0] * v[1] - u[1] * v[0]];
    const length = Math.hypot(...normal);
    for (const [index, value] of [...normal.map(n => n / length), ...a, ...b, ...c].entries()) {
      data.setFloat32(offset + index * 4, value, true);
    }
    offset += 50;
  }
  for (let ring = 0; ring < rings.length - 1; ring++) {
    for (let i = 0; i < segments; i++) {
      const next = (i + 1) % segments;
      const [a, b] = [rings[ring][i], rings[ring][next]];
      const [c, d] = [rings[ring + 1][i], rings[ring + 1][next]];
      if (ring > 0) write(a, b, d);
      if (ring < rings.length - 2) write(a, d, c);
    }
  }
  return bytes;
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
