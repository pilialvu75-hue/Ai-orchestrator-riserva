const dimensions = ['width', 'depth', 'height', 'wall', 'floor'];

export function validateOpenBoxParameters(parameters) {
  if (!parameters || Object.keys(parameters).length !== dimensions.length ||
      dimensions.some(name => !Object.hasOwn(parameters, name) ||
        !Number.isFinite(parameters[name]) ||
        parameters[name] < 0.1 || parameters[name] > 500)) {
    throw new RangeError('Expected five dimensions in millimetres, between 0.1 and 500');
  }
  const { width, depth, height, wall, floor } = parameters;
  if (2 * wall >= Math.min(width, depth) || floor >= height) {
    throw new RangeError('The dimensions must leave room for an open cavity');
  }

  return { width, depth, height, wall, floor };
}

const axis = { larghezza: 'width', profondità: 'depth', altezza: 'height', parete: 'wall', fondo: 'floor' };

export function applyOpenBoxInstruction(parameters, instruction) {
  if (typeof instruction !== 'string' || instruction.length > 160) {
    throw new RangeError('Invalid CAD instruction');
  }
  const baseline = validateOpenBoxParameters(parameters);
  const text = instruction.trim().toLowerCase().replace(/\s+/g, ' ');
  const absolute = /^(?:porta|imposta|modifica) (?:la |il )?(larghezza|profondità|altezza|parete|fondo) (?:a|al) (\d+(?:[.,]\d+)?)\s*mm[.!]?$/.exec(text);
  if (absolute) {
    return validateOpenBoxParameters({
      ...baseline, [axis[absolute[1]]]: Number(absolute[2].replace(',', '.')),
    });
  }
  const incremental = /^(allarga|restringi|alza|abbassa|approfondisci) (?:la scatola )?di (\d+(?:[.,]\d+)?)\s*mm[.!]?$/.exec(text);
  if (!incremental) throw new RangeError('Unsupported CAD instruction');
  const [field, direction] = {
    allarga: ['width', 1], restringi: ['width', -1],
    alza: ['height', 1], abbassa: ['height', -1], approfondisci: ['depth', 1],
  }[incremental[1]];
  return validateOpenBoxParameters({
    ...baseline, [field]: Number((baseline[field] + direction * Number(incremental[2].replace(',', '.'))).toFixed(6)),
  });
}

export function parseOpenBoxDescription(description) {
  if (typeof description !== 'string' || description.length > 300) {
    throw new RangeError('Invalid CAD description');
  }
  const text = description.trim().toLowerCase().replace(/\s+/g, ' ');
  const tuple = /^(?:voglio |crea )?(?:una )?scatola(?: portaoggetti)?(?: aperta)? (\d+(?:[.,]\d+)?)\s*[x×]\s*(\d+(?:[.,]\d+)?)\s*[x×]\s*(\d+(?:[.,]\d+)?)\s*mm,? (?:con )?pareti (?:spesse )?(\d+(?:[.,]\d+)?)\s*mm(?:,| e)? fondo (?:spesso )?(\d+(?:[.,]\d+)?)\s*mm[.!]?$/;
  const prose = /^(?:voglio |crea )?(?:una )?scatola(?: portaoggetti)?(?: aperta)? larga (\d+(?:[.,]\d+)?)\s*mm,? profonda (\d+(?:[.,]\d+)?)\s*mm,?(?: e)? alta (\d+(?:[.,]\d+)?)\s*mm,? (?:con )?pareti (?:spesse )?(\d+(?:[.,]\d+)?)\s*mm(?:,| e)? fondo (?:spesso )?(\d+(?:[.,]\d+)?)\s*mm[.!]?$/;
  const match = tuple.exec(text) ?? prose.exec(text);
  if (!match) throw new RangeError('Specify width, depth, height, wall and floor in millimetres');
  const [width, depth, height, wall, floor] = match.slice(1).map(value => Number(value.replace(',', '.')));
  return validateOpenBoxParameters({ width, depth, height, wall, floor });
}

export function validateStudioCadParameters(parameters) {
  if (!parameters || !Object.hasOwn(parameters, 'baseWidth')) return validateOpenBoxParameters(parameters);
  const { baseWidth, baseDepth, cornerRadius, ...box } = parameters;
  const normalized = validateOpenBoxParameters(box);
  if (![baseWidth, baseDepth, cornerRadius].every(Number.isFinite) ||
      baseWidth > normalized.width || baseDepth > normalized.depth ||
      cornerRadius <= normalized.wall || 2 * cornerRadius >= Math.min(baseWidth, baseDepth)) {
    throw new RangeError('Invalid tapered box dimensions');
  }
  return { ...normalized, baseWidth, baseDepth, cornerRadius };
}
