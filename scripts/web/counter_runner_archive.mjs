import { MAX_COUNTER_ENVELOPE_BYTES } from './counter_runner_envelope.mjs';

// upload-artifact is configured with compression level zero. Read the one
// expected stored entry in memory, with no paths written to a filesystem.
export function readRunnerArchiveEntry(bytes, entryName, maxEnvelopeBytes, maxArchiveBytes) {
  const name = new TextEncoder().encode(entryName);
  function validName(offset, length) {
    return length === name.length && name.every((value, index) => bytes[offset + index] === value);
  }
  const invalid = () => new Error('Unexpected runner archive format');
  if (!(bytes instanceof Uint8Array) || bytes.length < 98 || bytes.length > maxArchiveBytes) {
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
  if (central < 30 + name.length || central + centralSize !== end ||
      centralSize < 46 + name.length || integer(central) !== 0x02014b50) {
    throw invalid();
  }
  const flags = word(central + 8);
  const size = integer(central + 20);
  const nameLength = word(central + 28);
  if (flags & ~(0x0008 | 0x0800) || word(central + 10) !== 0 ||
      size < 1 || size > maxEnvelopeBytes || size !== integer(central + 24) ||
      word(central + 34) || integer(central + 42) !== 0 ||
      46 + nameLength + word(central + 30) + word(central + 32) !== centralSize ||
      !validName(central + 46, nameLength)) {
    throw invalid();
  }
  const localNameLength = word(26);
  const start = 30 + localNameLength + word(28);
  if (integer(0) !== 0x04034b50 || word(6) !== flags || word(8) !== 0 ||
      !validName(30, localNameLength) || start + size > central ||
      (!(flags & 0x0008) && (integer(18) !== size || integer(22) !== size ||
        start + size !== central))) {
    throw invalid();
  }
  return bytes.slice(start, start + size);
}

export function readCounterRunnerArchive(bytes) {
  return readRunnerArchiveEntry(bytes, 'counter.aivexus', MAX_COUNTER_ENVELOPE_BYTES, 128 * 1024);
}
