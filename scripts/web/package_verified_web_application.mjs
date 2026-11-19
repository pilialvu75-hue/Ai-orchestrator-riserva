import { spawn } from 'node:child_process';
import { createHash } from 'node:crypto';
import { fileURLToPath } from 'node:url';

const packager = fileURLToPath(new URL('./package_verified_web_application.py', import.meta.url));
const MAX_ZIP_BYTES = 72 * 1024;

export async function packageVerifiedWebApplication(verification) {
  const { status, source, attempts } = verification;
  if (status !== 'verified' || attempts?.at(-1)?.status !== 'passed') {
    throw new Error('Application must pass verification before packaging');
  }
  const serialized = JSON.stringify(source);
  const sourceSha256 = createHash('sha256').update(serialized).digest('hex');
  if (sourceSha256 !== attempts.at(-1).sourceSha256 || Buffer.byteLength(serialized) > 65536) {
    throw new Error('Verified application source has changed');
  }
  const python = process.env.AIVEXUS_COUNTER_PYTHON || 'python3';
  const env = {};
  for (const key of ['PATH', 'SystemRoot', 'TEMP', 'TMP', 'TMPDIR']) {
    if (process.env[key]) env[key] = process.env[key];
  }
  const child = spawn(python, ['-I', packager], {
    stdio: ['pipe', 'pipe', 'ignore'], env, windowsHide: true, signal: AbortSignal.timeout(6000),
  });
  let size = 0;
  const chunks = [];
  const zip = await new Promise((resolve, reject) => {
    child.once('error', reject);
    child.stdin.once('error', reject);
    child.stdout.on('data', chunk => {
      size += chunk.length;
      if (size > MAX_ZIP_BYTES) {
        child.kill();
        reject(new Error('ZIP exceeds the runner limit'));
        return;
      }
      chunks.push(chunk);
    });
    child.once('close', (code) => {
      if (code === 0 && size > 0) resolve(Buffer.concat(chunks));
      else reject(new Error('ZIP packaging failed'));
    });
    child.stdin.end(serialized);
  });
  return { zip, sha256: createHash('sha256').update(zip).digest('hex'), sourceSha256 };
}
