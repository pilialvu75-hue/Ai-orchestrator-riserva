import { validateOpenBoxParameters } from './studio_3d_box_parameters.mjs';

export function createTaperedBoxCad(parameters) {
  const { width, depth, height, wall, floor } = validateOpenBoxParameters({
    width: parameters.width, depth: parameters.depth, height: parameters.height,
    wall: parameters.wall, floor: parameters.floor,
  });
  const { baseWidth, baseDepth, cornerRadius } = parameters;
  if (![baseWidth, baseDepth, cornerRadius].every(Number.isFinite) ||
      baseWidth > width || baseDepth > depth || cornerRadius <= wall ||
      2 * cornerRadius >= Math.min(baseWidth, baseDepth)) {
    throw new RangeError('Invalid tapered box dimensions');
  }
  return `// Millimetres. Wall is the horizontal inset.
top = [${width}, ${depth}];
base = [${baseWidth}, ${baseDepth}];
height = ${height};
wall = ${wall};
floor = ${floor};
corner = ${cornerRadius};
eps = 0.01;
$fn = 16;
module section(size, radius, z) {
    translate([0, 0, z])
        linear_extrude(height = eps)
            offset(r = radius)
                square(size - [2 * radius, 2 * radius], center = true);
}
difference() {
    hull() {
        section(base, corner, 0);
        section(top, corner, height - eps);
    }
    hull() {
        section(base + (top - base) * (floor / height) - [2 * wall, 2 * wall], corner - wall, floor);
        section(top - [2 * wall, 2 * wall], corner - wall, height + eps);
    }
}
`;
}
