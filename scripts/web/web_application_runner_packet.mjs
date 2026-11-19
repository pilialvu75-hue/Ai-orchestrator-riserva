import {
  openWebRunnerEnvelope, sealWebRunnerEnvelope, WEB_RUNNER_OVERHEAD_BYTES, WEB_RUNNER_TICKET,
} from './web_runner_envelope.mjs';

const JOB_PURPOSE = 'aivexus-web-application-job:v1';
const RESULT_PURPOSE = 'aivexus-web-application-result:v1';
const TAG_BYTES = 32;
const JOB_MAX_COMPRESSED_BYTES = 44 * 1024;
const JOB_MAX_BYTES = 76 * 1024;
const RESULT_MAX_BYTES = 192 * 1024;
const JOB_TTL_SECONDS = 900;
export const MAX_WEB_APP_JOB_INPUT_CHARS = 61000;
export const MAX_WEB_APP_RESULT_PACKET_BYTES = RESULT_MAX_BYTES + WEB_RUNNER_OVERHEAD_BYTES + TAG_BYTES;
const encoder = new TextEncoder();
const decoder = new TextDecoder('utf-8', { fatal: true });
const SHA256 = /^[0-9a-f]{64}$/;

export function encodeRunnerBase64(bytes) {
  let encoded = '';
  for (let start = 0; start < bytes.length; start += 0x8000) {
    encoded += String.fromCharCode(...bytes.subarray(start, start + 0x8000));
  }
  return btoa(encoded);
}

export function decodeRunnerBase64(encoded, maxChars) {
  if (typeof encoded !== 'string' || !encoded || encoded.length > maxChars ||
      encoded.length % 4 || !/^[a-z0-9+/]+={0,2}$/i.test(encoded)) {
    throw new TypeError('Invalid runner encoding');
  }
  const decoded = Uint8Array.from(atob(encoded), character => character.charCodeAt(0));
  if (encodeRunnerBase64(decoded) !== encoded) throw new TypeError('Noncanonical runner encoding');
  return decoded;
}

export function importWebAppAuthorizationKey(encoded) {
  const bytes = decodeRunnerBase64(encoded, 44);
  if (bytes.length !== 32) throw new TypeError('Invalid runner authorization key');
  return crypto.subtle.importKey('raw', bytes, { name: 'HMAC', hash: 'SHA-256' }, false, ['sign', 'verify']);
}

export function importWebAppPublicKey(encoded) {
  return crypto.subtle.importKey('spki', decodeRunnerBase64(encoded, 416),
    { name: 'RSA-OAEP', hash: 'SHA-256' }, false, ['encrypt']);
}

export function importWebAppPrivateKey(encoded) {
  return crypto.subtle.importKey('pkcs8', decodeRunnerBase64(encoded, 2000),
    { name: 'RSA-OAEP', hash: 'SHA-256' }, false, ['decrypt']);
}

export async function runnerPayloadSha256(bytes) {
  const digest = new Uint8Array(await crypto.subtle.digest('SHA-256', bytes));
  return Array.from(digest, byte => byte.toString(16).padStart(2, '0')).join('');
}

function join(first, second) {
  const result = new Uint8Array(first.length + second.length);
  result.set(first);
  result.set(second, first.length);
  return result;
}

function authorizationInput(purpose, ticket, envelope) {
  if (typeof ticket !== 'string' || !WEB_RUNNER_TICKET.test(ticket)) throw new TypeError('Invalid runner ticket');
  return join(encoder.encode(purpose + ':' + ticket + ':'), envelope);
}

async function seal({ publicKey, authorizationKey, purpose, ticket, payload, maxBytes }) {
  const envelope = await sealWebRunnerEnvelope({ publicKey, purpose, ticket, payload, maxBytes });
  const tag = await crypto.subtle.sign('HMAC', authorizationKey, authorizationInput(purpose, ticket, envelope));
  return join(new Uint8Array(tag), envelope);
}

async function open({ privateKey, authorizationKey, purpose, ticket, packet, maxBytes }) {
  const overhead = WEB_RUNNER_OVERHEAD_BYTES + TAG_BYTES;
  if (!(packet instanceof Uint8Array) || packet.length <= overhead || packet.length > maxBytes + overhead) {
    throw new RangeError('Invalid runner packet size');
  }
  const envelope = packet.subarray(TAG_BYTES);
  if (!await crypto.subtle.verify('HMAC', authorizationKey, packet.subarray(0, TAG_BYTES),
    authorizationInput(purpose, ticket, envelope))) throw new Error('Runner packet authorization failed');
  return openWebRunnerEnvelope({ privateKey, purpose, ticket, envelope, maxBytes });
}

async function transform(input, codec, maxBytes) {
  const reader = new Blob([input]).stream().pipeThrough(codec).getReader();
  const chunks = [];
  let size = 0;
  try {
    while (true) {
      const { value, done } = await reader.read();
      if (done) break;
      size += value.byteLength;
      if (size > maxBytes) {
        await reader.cancel().catch(() => {});
        throw new RangeError('Runner job exceeds transport limits');
      }
      chunks.push(value);
    }
  } finally { reader.releaseLock(); }
  const result = new Uint8Array(size);
  let offset = 0;
  for (const chunk of chunks) {
    result.set(chunk, offset);
    offset += chunk.byteLength;
  }
  return result;
}

export async function encodeWebAppJob({ publicKey, authorizationKey, ticket, source, checks,
  resultPublicKeySpki, now = Math.floor(Date.now() / 1000) }) {
  if (!Number.isSafeInteger(now) || now <= 0) throw new TypeError('Invalid runner job clock');
  const resultKey = await importWebAppPublicKey(resultPublicKeySpki);
  if (resultKey.algorithm.modulusLength !== 2048) throw new TypeError('Invalid result wrapping key');
  const job = encoder.encode(JSON.stringify({ version: 1, source, checks, resultPublicKeySpki, issuedAt: now }));
  if (job.length > JOB_MAX_BYTES) throw new RangeError('Runner job exceeds payload limits');
  const compressed = await transform(job, new CompressionStream('gzip'), JOB_MAX_COMPRESSED_BYTES);
  const packet = await seal({ publicKey, authorizationKey, purpose: JOB_PURPOSE, ticket,
    payload: compressed, maxBytes: JOB_MAX_COMPRESSED_BYTES });
  const input = encodeRunnerBase64(packet);
  if (input.length > MAX_WEB_APP_JOB_INPUT_CHARS) throw new RangeError('Runner job exceeds dispatch limits');
  return { input, jobSha256: await runnerPayloadSha256(job) };
}

export async function decodeWebAppJob({ privateKey, authorizationKey, ticket, input,
  now = Math.floor(Date.now() / 1000) }) {
  const compressed = await open({ privateKey, authorizationKey, purpose: JOB_PURPOSE, ticket,
    packet: decodeRunnerBase64(input, MAX_WEB_APP_JOB_INPUT_CHARS), maxBytes: JOB_MAX_COMPRESSED_BYTES });
  const bytes = await transform(compressed, new DecompressionStream('gzip'), JOB_MAX_BYTES);
  const job = JSON.parse(decoder.decode(bytes));
  if (job?.version !== 1 || !Number.isSafeInteger(job.issuedAt) || !Number.isSafeInteger(now) ||
      job.issuedAt > now + 30 || now - job.issuedAt > JOB_TTL_SECONDS) throw new Error('Runner job expired or invalid');
  return { source: job.source, checks: job.checks, jobSha256: await runnerPayloadSha256(bytes),
    resultPublicKey: await importWebAppPublicKey(job.resultPublicKeySpki) };
}

export async function encodeWebAppResult({ publicKey, authorizationKey, ticket, jobSha256, result }) {
  if (typeof jobSha256 !== 'string' || !SHA256.test(jobSha256)) throw new TypeError('Invalid runner job digest');
  const payload = encoder.encode(JSON.stringify({ version: 1, jobSha256, result }));
  return seal({ publicKey, authorizationKey, purpose: RESULT_PURPOSE, ticket, payload, maxBytes: RESULT_MAX_BYTES });
}

export async function decodeWebAppResult({ privateKey, authorizationKey, ticket, packet, jobSha256 }) {
  if (typeof jobSha256 !== 'string' || !SHA256.test(jobSha256)) throw new TypeError('Invalid runner job digest');
  const payload = await open({ privateKey, authorizationKey, purpose: RESULT_PURPOSE, ticket, packet, maxBytes: RESULT_MAX_BYTES });
  const decoded = JSON.parse(decoder.decode(payload));
  if (decoded?.version !== 1 || decoded.jobSha256 !== jobSha256) throw new Error('Runner job digest mismatch');
  return decoded.result;
}
