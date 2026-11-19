export const MAX_COUNTER_D1_ZIP_BYTES = 64 * 1024;

// Uses the same create-only/read-back interface as the private object binding.
export function createD1WebCounterArtifactStore(db) {
  return {
    async put(storageKey, bytes) {
      if (!(bytes instanceof Uint8Array) || bytes.byteLength < 1 ||
          bytes.byteLength > MAX_COUNTER_D1_ZIP_BYTES) {
        throw new RangeError('Counter ZIP exceeds the D1 artifact limit');
      }
      const result = await db.prepare(
        'INSERT INTO web_counter_artifacts (storage_key, zip_bytes) VALUES (?1, ?2) ' +
        'ON CONFLICT(storage_key) DO NOTHING',
      ).bind(storageKey, Uint8Array.from(bytes).buffer).run();
      if (!result?.success || ![0, 1].includes(result.meta?.changes)) {
        throw new Error('Counter artifact write unavailable');
      }
      return result.meta.changes === 1 ? { size: bytes.byteLength } : null;
    },
    async get(storageKey) {
      const value = await db.prepare(
        'SELECT zip_bytes FROM web_counter_artifacts WHERE storage_key = ?1',
      ).bind(storageKey).first('zip_bytes');
      if (!Array.isArray(value) && !(value instanceof Uint8Array)) return null;
      if (value.length < 1 || value.length > MAX_COUNTER_D1_ZIP_BYTES) return null;
      const bytes = Uint8Array.from(value);
      return { size: bytes.length, arrayBuffer: async () => bytes.buffer };
    },
  };
}
