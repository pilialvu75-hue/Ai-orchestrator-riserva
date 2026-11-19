import { execFile } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { promisify } from 'node:util';

import { MAX_ARTIFACT_BYTES } from './web_execution_artifact_download.mjs';

const run = promisify(execFile);
const builder = fileURLToPath(new URL('./build_verified_counter_zip.py', import.meta.url));

// Only for the trusted Node/Python runner. The browser never supplies a command,
// path, or input to the fixed counter build.
export async function buildAndTestCounter() {
  const python = process.env.AIVEXUS_COUNTER_PYTHON || 'python3';
  const env = { AIVEXUS_COUNTER_PYTHON: python };
  for (const name of ['PATH', 'SystemRoot', 'TEMP', 'TMP', 'TMPDIR']) {
    if (process.env[name]) env[name] = process.env[name];
  }
  const { stdout } = await run(python, [builder], {
    cwd: fileURLToPath(new URL('../../', import.meta.url)),
    env,
    encoding: 'buffer',
    maxBuffer: MAX_ARTIFACT_BYTES,
    timeout: 120_000,
  });
  return stdout;
}
