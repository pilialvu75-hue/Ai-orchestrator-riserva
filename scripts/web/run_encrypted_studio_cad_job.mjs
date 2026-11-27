import { runStudio3dBoxJob } from './run_studio_3d_box_job.mjs';
import { decodeWebAppJob, encodeRunnerBase64, encodeWebAppResult } from './web_application_runner_packet.mjs';

export async function runEncryptedStudioCadJob({ input, ticket, privateKey, authorizationKey }) {
  const job = await decodeWebAppJob({ privateKey, authorizationKey, ticket, input });
  const { source, checks } = job;
  if (!['cad_open_box', 'cad_tapered_box'].includes(source?.kind) || Object.keys(source).length !== 2 ||
      !Array.isArray(checks) || checks.length !== 0) {
    throw new Error('Invalid CAD runner job');
  }
  if ((source.kind === 'cad_tapered_box') !== Object.hasOwn(source.parameters, 'baseWidth')) {
    throw new Error('CAD job shape mismatch');
  }
  const { manifest, scad, stl } = await runStudio3dBoxJob(source.parameters);
  return encodeWebAppResult({
    publicKey: job.resultPublicKey, authorizationKey, ticket, jobSha256: job.jobSha256,
    result: { manifest, scad: encodeRunnerBase64(scad), stl: encodeRunnerBase64(stl) },
  });
}
