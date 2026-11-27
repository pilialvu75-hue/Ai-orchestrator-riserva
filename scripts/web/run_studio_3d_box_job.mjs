import { checkOpenBoxFdm } from './studio_3d_box_parameters.mjs';
import { renderOpenBox } from './studio_3d_open_box.mjs';
import { runnerPayloadSha256 } from './web_application_runner_packet.mjs';

export async function runStudio3dBoxJob(parameters) {
  const { source, stl, verification } = await renderOpenBox(parameters);
  const scad = new TextEncoder().encode(source);
  const files = await Promise.all([
    ['box.scad', 'text/plain', scad],
    ['box.stl', 'model/stl', stl],
  ].map(async ([name, mediaType, content]) => ({
    name, mediaType, bytes: content.length, sha256: await runnerPayloadSha256(content),
  })));
  const manifest = { version: 1, kind: 'cad', shape: 'open_box', unit: 'mm',
    parameters, verification, fdm: checkOpenBoxFdm(parameters), files };
  return { manifest, scad, stl };
}
