import { MAX_COUNTER_D1_ZIP_BYTES } from './d1_web_counter_artifact_store.mjs';
import {
  openWebRunnerEnvelope, sealWebRunnerEnvelope, WEB_RUNNER_OVERHEAD_BYTES,
} from './web_runner_envelope.mjs';

const purpose = 'aivexus-counter-zip:v1';
const maxBytes = MAX_COUNTER_D1_ZIP_BYTES;
export const MAX_COUNTER_ENVELOPE_BYTES = WEB_RUNNER_OVERHEAD_BYTES + maxBytes;

// Keep the counter's existing binary wire format and ticket binding.
export function sealCounterRunnerZip({ publicKey, ticket, zip }) {
  return sealWebRunnerEnvelope({ publicKey, ticket, payload: zip, purpose, maxBytes });
}

export function openCounterRunnerZip({ privateKey, ticket, envelope }) {
  return openWebRunnerEnvelope({ privateKey, ticket, envelope, purpose, maxBytes });
}
