import { MAX_COUNTER_ENVELOPE_BYTES } from './counter_runner_envelope.mjs';

const NAME = new TextEncoder().encode('counter.aivexus');

function validName(bytes, offset, length) {
  return length === NAME.length &&
    NAME.every((value, index) => bytes[offset + index] === value);
}

// upload-artifact is configured with compression level zero. Read the one
// expected stored entry in memory, with no paths written to a filesystem.
export function readCounterRunnerArchive(bytes) {
  const invalid = () => new Error('Unexpected counter runner archive format');
  if (!(bytes instanceof Uint8Array) || bytes.length < 98 || bytes.length > 128 * 1024) {
    throw invalid();
  }
  const view = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
  const word = offset => view.getUint16(offset, true);
  const integer = offset => view.getUint32(offset, true);
  const end = bytes.length - 22;
  if (integer(end) !== 0x06054b50 || word(end + 4) || word(end + 6) ||
      word(end + 8) !== 1 || word(end + 10) !== 1 || word(end + 20)) {
    throw invalid();
  }
  const central = integer(end + 16);
  const centralSize = integer(end + 12);
  if (central < 30 + NAME.length || central + centralSize !== end ||
      centralSize < 46 + NAME.length || integer(central) !== 0x02014b50) {
    throw invalid();
  }
  const flags = word(central + 8);
  const size = integer(central + 20);
  const nameLength = word(central + 28);
  if (flags & ~(0x0008 | 0x0800) || word(central + 10) !== 0 ||
      size < 1 || size > MAX_COUNTER_ENVELOPE_BYTES || size !== integer(central + 24) ||
      word(central + 34) || integer(central + 42) !== 0 ||
      46 + nameLength + word(central + 30) + word(central + 32) !== centralSize ||
      !validName(bytes, central + 46, nameLength)) {
    throw invalid();
  }
  const localNameLength = word(26);
  const start = 30 + localNameLength + word(28);
  if (integer(0) !== 0x04034b50 || word(6) !== flags || word(8) !== 0 ||
      !validName(bytes, 30, localNameLength) || start + size > central ||
      (!(flags & 0x0008) && (integer(18) !== size || integer(22) !== size ||
        start + size !== central))) {
    throw invalid();
  }
  return bytes.slice(start, start + size);
}
