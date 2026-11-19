import { readCounterRunnerArchive } from './counter_runner_archive.mjs';
import { webZipSha256 } from './web_execution_artifact_download.mjs';

const API = 'https://api.github.com/repos/pilialvu75-hue/Ai-orchestrator-riserva';
const REPOSITORY_ID = 1235011890;
const WORKFLOW = 'web-counter-runner.yml';
const ARTIFACT = 'aivexus-counter-envelope';
const MAX_ARCHIVE_BYTES = 128 * 1024;
const SHA = /^[0-9a-f]{40}$/;
const DIGEST = /^sha256:[0-9a-f]{64}$/;
const TICKET = /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/;

function validId(id) {
  return Number.isSafeInteger(id) && id > 0;
}

function storageRedirect(location) {
  if (!location) throw new Error('Counter runner archive redirect is invalid');
  const url = new URL(location);
  if (url.protocol !== 'https:' || url.port || url.username || url.password ||
      (url.hostname !== 'results-receiver.actions.githubusercontent.com' &&
       !url.hostname.endsWith('.blob.core.windows.net'))) {
    throw new Error('Counter runner archive redirect is invalid');
  }
  return url;
}

async function readArchive(response, size) {
  const length = response.headers.get('content-length');
  if (response.status !== 200 || !response.body || (length !== null && Number(length) !== size)) {
    throw new Error('Counter runner archive download failed');
  }
  const reader = response.body.getReader();
  const bytes = new Uint8Array(size);
  let offset = 0;
  try {
    for (;;) {
      const { value, done } = await reader.read();
      if (done) break;
      if (offset + value.length > size) {
        await reader.cancel().catch(() => {});
        throw new Error('Counter runner archive length mismatch');
      }
      bytes.set(value, offset);
      offset += value.length;
    }
  } finally {
    reader.releaseLock();
  }
  if (offset !== size) throw new Error('Counter runner archive length mismatch');
  return bytes;
}

export function createGitHubCounterRunnerClient({ token, expectedHeadSha, fetchImpl = fetch }) {
  if (typeof token !== 'string' || !token.trim() || typeof expectedHeadSha !== 'string' ||
      !SHA.test(expectedHeadSha)) {
    throw new TypeError('Counter runner GitHub configuration is invalid');
  }

  function apiRequest(path, { body } = {}) {
    return fetchImpl(API + path, {
      method: body ? 'POST' : 'GET',
      headers: {
        Accept: 'application/vnd.github+json',
        Authorization: 'Bearer ' + token,
        'X-GitHub-Api-Version': '2026-03-10',
        'User-Agent': 'Aivexus-Web-Counter',
        ...(body ? { 'Content-Type': 'application/json' } : {}),
      },
      ...(body ? { body: JSON.stringify(body) } : {}),
      redirect: 'manual',
      signal: AbortSignal.timeout(5000),
    });
  }

  async function request(path, body) {
    const response = await apiRequest(path, { body });
    if (response.status !== 200) throw new Error('Counter runner GitHub request failed');
    return await response.json();
  }

  return {
    async dispatch({ ticket, publicKeySpki }) {
      if (typeof ticket !== 'string' || !TICKET.test(ticket) ||
          typeof publicKeySpki !== 'string' || publicKeySpki.length > 416 ||
          !/^[A-Za-z0-9+/]+={0,2}$/.test(publicKeySpki)) {
        throw new TypeError('Counter runner inputs are invalid');
      }
      // A caller must persist the dispatch attempt before calling this method.
      // A timeout is ambiguous. Never retry this POST without reconciliation.
      const result = await request('/actions/workflows/' + WORKFLOW + '/dispatches', {
        ref: 'main', inputs: { ticket, public_key: publicKeySpki },
      });
      if (!validId(result?.workflow_run_id)) throw new Error('Counter runner dispatch not confirmed');
      return result.workflow_run_id;
    },

    async readResult(runId) {
      if (!validId(runId)) throw new TypeError('Counter runner run ID is invalid');
      const runPath = '/actions/runs/' + runId;
      const run = await request(runPath);
      if (run?.id !== runId || run.event !== 'workflow_dispatch' || run.run_attempt !== 1 ||
          run.head_branch !== 'main' || run.head_sha !== expectedHeadSha ||
          run.path !== '.github/workflows/' + WORKFLOW ||
          run.repository?.id !== REPOSITORY_ID || run.head_repository?.id !== REPOSITORY_ID) {
        throw new Error('Counter runner provenance verification failed');
      }
      if (run.status !== 'completed') return { status: 'pending' };
      if (run.conclusion !== 'success') return { status: 'failed' };

      const list = await request(runPath + '/artifacts?per_page=2');
      const [artifact] = Array.isArray(list?.artifacts) ? list.artifacts : [];
      const source = artifact?.workflow_run;
      if (list?.total_count !== 1 || list.artifacts?.length !== 1 ||
          !validId(artifact?.id) || artifact.name !== ARTIFACT || artifact.expired !== false ||
          !Number.isSafeInteger(artifact.size_in_bytes) || artifact.size_in_bytes < 1 ||
          artifact.size_in_bytes > MAX_ARCHIVE_BYTES ||
          typeof artifact.digest !== 'string' || !DIGEST.test(artifact.digest) ||
          source?.id !== runId || source.repository_id !== run.repository.id ||
          source.head_repository_id !== run.repository.id || source.head_branch !== 'main' ||
          source.head_sha !== expectedHeadSha) {
        throw new Error('Counter runner artifact provenance verification failed');
      }
      return {
        status: 'ready', artifactId: artifact.id,
        sha256: artifact.digest.slice('sha256:'.length), size: artifact.size_in_bytes,
      };
    },

    async downloadArchive(result) {
      const { artifactId, sha256, size } = result ?? {};
      if (result?.status !== 'ready' || !validId(artifactId) ||
          !Number.isSafeInteger(size) || size < 1 || size > MAX_ARCHIVE_BYTES ||
          typeof sha256 !== 'string' || !DIGEST.test('sha256:' + sha256)) {
        throw new TypeError('Counter runner archive metadata is invalid');
      }
      const response = await apiRequest('/actions/artifacts/' + artifactId + '/zip');
      if (response.status !== 302) throw new Error('Counter runner archive redirect failed');
      const target = storageRedirect(response.headers.get('location'));
      const archived = await fetchImpl(target.href, {
        method: 'GET', redirect: 'manual', credentials: 'omit', signal: AbortSignal.timeout(10000),
      });
      const bytes = await readArchive(archived, size);
      if (await webZipSha256(bytes) !== sha256) throw new Error('Counter runner archive digest mismatch');
      return readCounterRunnerArchive(bytes);
    },
  };
}
