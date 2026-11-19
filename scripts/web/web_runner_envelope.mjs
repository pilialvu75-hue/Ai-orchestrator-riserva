const encoder = new TextEncoder();
const VERSION = 1;
const WRAPPED_BYTES = 256;
const NONCE_BYTES = 12;
const TAG_BYTES = 16;
const HEADER_BYTES = 1 + WRAPPED_BYTES + NONCE_BYTES;
export const WEB_RUNNER_OVERHEAD_BYTES = HEADER_BYTES + TAG_BYTES;
export const WEB_RUNNER_TICKET = /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/;

function associatedData(purpose, ticket) {
  if (typeof ticket !== 'string' || !WEB_RUNNER_TICKET.test(ticket)) {
    throw new TypeError('Invalid runner dispatch ticket');
  }
  return encoder.encode(purpose + ':' + ticket);
}

function verifyWrappingKey(key, type) {
  if (key?.type !== type || key.algorithm?.name !== 'RSA-OAEP' ||
      key.algorithm.modulusLength !== 2048 || key.algorithm.hash?.name !== 'SHA-256') {
    throw new TypeError('Invalid runner envelope key');
  }
}

export async function sealWebRunnerEnvelope({ publicKey, purpose, ticket, payload, maxBytes }) {
  verifyWrappingKey(publicKey, 'public');
  const additionalData = associatedData(purpose, ticket);
  if (!(payload instanceof Uint8Array) || payload.length < 1 || payload.length > maxBytes) {
    throw new RangeError('Invalid runner payload length');
  }
  const nonce = crypto.getRandomValues(new Uint8Array(NONCE_BYTES));
  const key = await crypto.subtle.generateKey({ name: 'AES-GCM', length: 256 }, true, ['encrypt']);
  const wrapped = await crypto.subtle.encrypt('RSA-OAEP', publicKey, await crypto.subtle.exportKey('raw', key));
  const cipher = await crypto.subtle.encrypt({ name: 'AES-GCM', iv: nonce, additionalData }, key, payload);
  const envelope = new Uint8Array(HEADER_BYTES + cipher.byteLength);
  envelope[0] = VERSION;
  envelope.set(new Uint8Array(wrapped), 1);
  envelope.set(nonce, 1 + WRAPPED_BYTES);
  envelope.set(new Uint8Array(cipher), HEADER_BYTES);
  return envelope;
}

export async function openWebRunnerEnvelope({ privateKey, purpose, ticket, envelope, maxBytes }) {
  verifyWrappingKey(privateKey, 'private');
  const additionalData = associatedData(purpose, ticket);
  if (!(envelope instanceof Uint8Array) || envelope[0] !== VERSION ||
      envelope.length <= WEB_RUNNER_OVERHEAD_BYTES || envelope.length > WEB_RUNNER_OVERHEAD_BYTES + maxBytes) {
    throw new RangeError('Invalid runner envelope');
  }
  const wrapped = envelope.subarray(1, 1 + WRAPPED_BYTES);
  const iv = envelope.subarray(1 + WRAPPED_BYTES, HEADER_BYTES);
  const raw = await crypto.subtle.decrypt('RSA-OAEP', privateKey, wrapped);
  if (raw.byteLength !== 32) throw new Error('Invalid wrapped runner key');
  const key = await crypto.subtle.importKey('raw', raw, 'AES-GCM', false, ['decrypt']);
  return new Uint8Array(await crypto.subtle.decrypt(
    { name: 'AES-GCM', iv, additionalData }, key, envelope.subarray(HEADER_BYTES),
  ));
}
