export const REFERENCE_FDM_PROFILE = Object.freeze({
  bedMm: Object.freeze([220, 220, 250]), nozzleMm: 0.4, layerMm: 0.2, material: 'PLA',
});

export function checkOpenBoxFdm({ width, depth, height, wall, floor }, profile = REFERENCE_FDM_PROFILE) {
  const fitsVolume = [width, depth, height].every((value, axis) => value <= profile.bedMm[axis]);
  const wallMeetsMinimum = wall >= 2 * profile.nozzleMm;
  const floorMeetsMinimum = floor >= 3 * profile.layerMm - 1e-9;
  return { profile, fitsVolume, wallMeetsMinimum, floorMeetsMinimum };
}
