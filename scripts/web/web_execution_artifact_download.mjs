const EXECUTION_ID = /^web-exec-[0-9a-f]{32}$/;
const SHA256 = /^[0-9a-f]{64}$/;
export const MAX_ARTIFACT_BYTES = 16 * 1024 * 1024;

const READ_OWNED_RECEIPT = `
SELECT receipt.artifact_sha256 AS sha256,
       receipt.artifact_storage_key AS storageKey,
       receipt.artifact_size_bytes AS size
FROM web_execution_reservations AS execution
JOIN web_execution_artifact_receipts AS receipt
  ON receipt.idempotency_key = execution.idempotency_key
  AND receipt.execution_id = execution.execution_id
  AND receipt.attempt_id = execution.attempt_id
WHERE execution.owner_subject = ?1 AND execution.execution_id = ?2
  AND execution.product = 'aivexus-web' AND execution.status = 'completed'
LIMIT 1
`;

export async function webZipSha256(bytes) {
  const digest = await crypto.subtle.digest('SHA-256', bytes);
  return Array.from(new Uint8Array(digest), byte =>
    byte.toString(16).padStart(2, '0')).join('');
}

export async function readVerifiedWebZip({ bucket, storageKey, size, sha256 }) {
  const object = await bucket.get(storageKey);
  if (!object || object.size !== size) return null;
  const bytes = await object.arrayBuffer();
  if (bytes.byteLength !== size || await webZipSha256(bytes) !== sha256) return null;
  return bytes;
}

export async function readWebExecutionZip({ db, bucket, ownerSubject, executionId }) {
  if (!EXECUTION_ID.test(executionId ?? '')) return { error: 'invalid_request' };
  const receipt = await db.prepare(READ_OWNED_RECEIPT)
    .bind(ownerSubject, executionId).first();
  if (!receipt) return { error: 'execution_not_found' };

  const { sha256, storageKey, size } = receipt;
  if (typeof sha256 !== 'string' || !SHA256.test(sha256) ||
      storageKey !== `web-artifacts/${executionId}/${sha256}.zip` ||
      !Number.isSafeInteger(size) || size <= 0 || size > MAX_ARTIFACT_BYTES) {
    return { error: 'artifact_unavailable' };
  }
  const bytes = await readVerifiedWebZip({ bucket, storageKey, size, sha256 });
  return bytes ? { bytes } : { error: 'artifact_unavailable' };
}
