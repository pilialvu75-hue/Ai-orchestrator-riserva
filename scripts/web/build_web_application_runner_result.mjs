import { readFile, stat, writeFile } from 'node:fs/promises';
import { runEncryptedWebApplicationJob } from './run_encrypted_web_application_job.mjs';
import { importWebAppAuthorizationKey, importWebAppPrivateKey } from './web_application_runner_packet.mjs';

const [eventFile, output] = process.argv.slice(2);

try {
  if (!output || !eventFile || (await stat(eventFile)).size > 180000) throw new Error('Invalid runner event');
  const { inputs } = JSON.parse(await readFile(eventFile, 'utf8'));
  if (!inputs || Object.keys(inputs).length !== 2) throw new Error('Invalid runner inputs');
  const [privateKey, authorizationKey] = await Promise.all([
    importWebAppPrivateKey(process.env.AIVEXUS_WEB_BUILDER_JOB_PRIVATE_KEY),
    importWebAppAuthorizationKey(process.env.AIVEXUS_WEB_BUILDER_JOB_AUTH_KEY),
  ]);
  const encrypted = await runEncryptedWebApplicationJob({
    input: inputs.job, ticket: inputs.ticket, privateKey, authorizationKey,
    executable: process.env.AIVEXUS_WEB_CHROMIUM || 'google-chrome', env: process.env,
  });
  await writeFile(output, encrypted, { flag: 'wx', mode: 0o600 });
} catch (_) {
  process.stderr.write('Web runner rejected the encrypted job or could not save the result.\n');
  process.exitCode = 1;
}
