import { runWebApplicationVerification } from './run_web_application_verification.mjs';
import {
  decodeWebAppJob, encodeRunnerBase64, encodeWebAppResult,
} from './web_application_runner_packet.mjs';

export async function runEncryptedWebApplicationJob({ input, ticket, privateKey, authorizationKey, executable, env }) {
  const job = await decodeWebAppJob({ privateKey, authorizationKey, ticket, input });
  const verification = await runWebApplicationVerification({
    source: job.source, checks: job.checks, executable, env,
  });
  const { status, diagnosis, attempts, source, artifact } = verification;
  const result = { status, diagnosis, attempts };
  if (status === 'verified') {
    result.source = source;
    result.artifact = {
      sourceSha256: artifact.sourceSha256, sha256: artifact.sha256, zip: encodeRunnerBase64(artifact.zip),
    };
  }
  return encodeWebAppResult({
    publicKey: job.resultPublicKey, authorizationKey, ticket, jobSha256: job.jobSha256, result,
  });
}
