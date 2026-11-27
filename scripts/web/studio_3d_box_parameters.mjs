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
