import assert from 'node:assert/strict';
import test from 'node:test';

import {
  openCounterRunnerZip, sealCounterRunnerZip,
} from '../../scripts/web/counter_runner_envelope.mjs';
import { MAX_COUNTER_D1_ZIP_BYTES } from '../../scripts/web/d1_web_counter_artifact_store.mjs';

test('counter envelope is randomized, ticket-bound and rejects tampering', async () => {
  const { publicKey, privateKey } = await crypto.subtle.generateKey({
    name: 'RSA-OAEP', modulusLength: 2048, hash: 'SHA-256',
    publicExponent: new Uint8Array([1, 0, 1]),
  }, false, ['encrypt', 'decrypt']);
  const ticket = crypto.randomUUID();
  const zip = Uint8Array.from(Buffer.from('504b0506000000000000000000000000000000000000', 'hex'));
  const envelope = await sealCounterRunnerZip({ publicKey, ticket, zip });
  assert.notDeepEqual(envelope, await sealCounterRunnerZip({ publicKey, ticket, zip }));
  assert.deepEqual(await openCounterRunnerZip({ privateKey, ticket, envelope }), zip);
  await assert.rejects(openCounterRunnerZip({ privateKey, ticket: crypto.randomUUID(), envelope }));
  envelope[envelope.length - 1] ^= 1;
  await assert.rejects(openCounterRunnerZip({ privateKey, ticket, envelope }));
  await assert.rejects(openCounterRunnerZip({ privateKey, ticket, envelope: envelope.subarray(0, 30) }),
    RangeError);
  await assert.rejects(sealCounterRunnerZip({
    publicKey, ticket, zip: new Uint8Array(MAX_COUNTER_D1_ZIP_BYTES + 1),
  }), RangeError);
});
