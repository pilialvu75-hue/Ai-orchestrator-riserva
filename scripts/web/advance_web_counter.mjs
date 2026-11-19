import { openCounterRunnerZip } from './counter_runner_envelope.mjs';
import { dispatchReservedWebCounter, readWebCounterDispatch } from './d1_web_counter_dispatch.mjs';
import { createWebD1ExecutionJournal } from './d1_execution_journal_store.mjs';
import { createGitHubCounterRunnerClient } from './github_counter_runner_client.mjs';
import { runWebCounterAttempt } from './run_web_counter_attempt.mjs';

const EXECUTION = /^web-exec-[0-9a-f]{32}$/;

async function readState(db, executionId, ownerSubject) {
  return await db.prepare(`
    SELECT status FROM web_execution_reservations
    WHERE execution_id = ?1 AND owner_subject = ?2 AND product = 'aivexus-web'
  `).bind(executionId, ownerSubject).first('status');
}

export async function advanceWebCounter({
  db, bucket, executionId, ownerSubject, github, expectedHeadSha, publicKeySpki, privateKey,
}) {
  const status = await readState(db, executionId, ownerSubject);
  if (!status) return { ok: false, reason: 'execution_not_found' };
  if (status !== 'reserved') return { ok: true, executionId, status };

  const reference = { db, ownerSubject, executionId };
  const dispatch = await readWebCounterDispatch(reference);
  if (!dispatch) {
    const { state } = await dispatchReservedWebCounter({
      ...reference, github, expectedHeadSha, publicKeySpki,
    });
    return state === 'not_found' ? { ok: false, reason: 'execution_not_found' } :
      { ok: true, executionId, status: state };
  }
  if (dispatch.state !== 'submitted') {
    return { ok: true, executionId, status: dispatch.state };
  }
  if (dispatch.headSha !== expectedHeadSha) {
    return { ok: true, executionId, status: 'review_required' };
  }

  const result = await github.readResult(dispatch.runId);
  if (result.status === 'pending') return { ok: true, executionId, status: 'submitted' };
  const attempt = { key: dispatch.executionKey, attemptId: dispatch.attemptId };
  if (result.status === 'failed') {
    await createWebD1ExecutionJournal(db).failPreflight(attempt);
  } else {
    // Reading and decrypting is safe to repeat after a transient download
    // error. The journal claim still gates all artifact writes.
    const envelope = await github.downloadArchive(result);
    const bytes = await openCounterRunnerZip({ privateKey, ticket: dispatch.ticket, envelope });
    await runWebCounterAttempt({
      db, bucket, ...attempt,
      buildAndTestCounter: async () => bytes,
    });
  }
  const updated = await readState(db, executionId, ownerSubject);
  return { ok: true, executionId, status: updated === 'reserved' ? 'review_required' : updated };
}

export async function handleWebCounterAdvance({ request, principal, db, bucket, runner }) {
  if (Object.keys(request).length !== 1 || typeof request.executionId !== 'string' ||
      !EXECUTION.test(request.executionId)) {
    return { ok: false, reason: 'invalid_request' };
  }
  const { token, expectedHeadSha, publicKeySpki, privateKeyPkcs8 } = runner ?? {};
  if (typeof privateKeyPkcs8 !== 'string' || privateKeyPkcs8.length > 2048 ||
      typeof publicKeySpki !== 'string' || publicKeySpki.length > 416) {
    return { ok: false, reason: 'runner_unavailable' };
  }
  const privateKey = await crypto.subtle.importKey(
    'pkcs8', Uint8Array.from(atob(privateKeyPkcs8), value => value.charCodeAt(0)),
    { name: 'RSA-OAEP', hash: 'SHA-256' }, false, ['decrypt'],
  );
  const publicKey = await crypto.subtle.importKey(
    'spki', Uint8Array.from(atob(publicKeySpki), value => value.charCodeAt(0)),
    { name: 'RSA-OAEP', hash: 'SHA-256' }, false, ['encrypt'],
  );
  if (privateKey.algorithm.modulusLength !== 2048 || publicKey.algorithm.modulusLength !== 2048) {
    return { ok: false, reason: 'runner_unavailable' };
  }
  const github = createGitHubCounterRunnerClient({ token, expectedHeadSha });
  return await advanceWebCounter({
    db, bucket, executionId: request.executionId, ownerSubject: principal.subject,
    github, expectedHeadSha, publicKeySpki, privateKey,
  });
}
