import { MAX_COUNTER_D1_ZIP_BYTES } from './d1_web_counter_artifact_store.mjs';

const VERSION = 1;
const WRAPPED_BYTES = 256;
const NONCE_BYTES = 12;
const TAG_BYTES = 16;
const HEADER_BYTES = 1 + WRAPPED_BYTES + NONCE_BYTES;
export const MAX_COUNTER_ENVELOPE_BYTES =
  HEADER_BYTES + TAG_BYTES + MAX_COUNTER_D1_ZIP_BYTES;
const TICKET = /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/;

function associatedData(ticket) {
  if (typeof ticket !== 'string' || !TICKET.test(ticket)) {
    throw new TypeError('Invalid counter dispatch ticket');
  }
  return new TextEncoder().encode('aivexus-counter-zip:v1:' + ticket);
}

function verifyWrappingKey(key, type) {
  if (key?.type !== type || key.algorithm?.name !== 'RSA-OAEP' ||
      key.algorithm.modulusLength !== 2048 || key.algorithm.hash?.name !== 'SHA-256') {
    throw new TypeError('Invalid counter envelope key');
  }
}

// The runner receives only the public key. The private key remains in Pages.
// This protects confidentiality and binds the archive to an opaque ticket.
// Caller must also verify the exact authorized GitHub run before decryption.
export async function sealCounterRunnerZip({ publicKey, ticket, zip }) {
  verifyWrappingKey(publicKey, 'public');
  const additionalData = associatedData(ticket);
  if (!(zip instanceof Uint8Array) || zip.length < 1 || zip.length > MAX_COUNTER_D1_ZIP_BYTES) {
    throw new RangeError('Invalid counter ZIP length');
  }
  const nonce = crypto.getRandomValues(new Uint8Array(NONCE_BYTES));
  const key = await crypto.subtle.generateKey({ name: 'AES-GCM', length: 256 }, true, ['encrypt']);
  const wrapped = await crypto.subtle.encrypt('RSA-OAEP', publicKey, await crypto.subtle.exportKey('raw', key));
  const cipher = await crypto.subtle.encrypt({ name: 'AES-GCM', iv: nonce, additionalData }, key, zip);
  const envelope = new Uint8Array(HEADER_BYTES + cipher.byteLength);
  envelope[0] = VERSION;
  envelope.set(new Uint8Array(wrapped), 1);
  envelope.set(nonce, 1 + WRAPPED_BYTES);
  envelope.set(new Uint8Array(cipher), HEADER_BYTES);
  return envelope;
}

export async function openCounterRunnerZip({ privateKey, ticket, envelope }) {
  verifyWrappingKey(privateKey, 'private');
  const additionalData = associatedData(ticket);
  if (!(envelope instanceof Uint8Array) || envelope[0] !== VERSION ||
      envelope.length <= HEADER_BYTES + TAG_BYTES ||
      envelope.length > MAX_COUNTER_ENVELOPE_BYTES) {
    throw new RangeError('Invalid counter envelope');
  }
  const wrapped = envelope.subarray(1, 1 + WRAPPED_BYTES);
  const iv = envelope.subarray(1 + WRAPPED_BYTES, HEADER_BYTES);
  const raw = await crypto.subtle.decrypt('RSA-OAEP', privateKey, wrapped);
  if (raw.byteLength !== 32) throw new Error('Invalid wrapped counter key');
  const key = await crypto.subtle.importKey('raw', raw, 'AES-GCM', false, ['decrypt']);
  return new Uint8Array(await crypto.subtle.decrypt(
    { name: 'AES-GCM', iv, additionalData }, key, envelope.subarray(HEADER_BYTES),
  ));
}
