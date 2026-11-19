import { writeFile } from 'node:fs/promises';
import { buildAndTestCounter } from './build_verified_counter_zip.mjs';
import { sealCounterRunnerZip } from './counter_runner_envelope.mjs';

const [output] = process.argv.slice(2);
const ticket = process.env.AIVEXUS_COUNTER_TICKET;
const publicKeySpki = process.env.AIVEXUS_COUNTER_PUBLIC_KEY;

try {
  if (!output || !ticket || ticket.length !== 36 ||
      !publicKeySpki || publicKeySpki.length > 416 ||
      !/^[A-Za-z0-9+/]+={0,2}$/.test(publicKeySpki)) {
    throw new TypeError('Counter runner configuration is invalid');
  }
  const publicKey = await crypto.subtle.importKey(
    'spki', Buffer.from(publicKeySpki, 'base64'),
    { name: 'RSA-OAEP', hash: 'SHA-256' }, false, ['encrypt'],
  );
  const zip = await buildAndTestCounter();
  const encrypted = await sealCounterRunnerZip({ publicKey, ticket, zip });
  await writeFile(output, encrypted, { flag: 'wx' });
} catch (_) {
  process.stderr.write('Counter build or encrypted handoff failed.\n');
  process.exitCode = 1;
}
