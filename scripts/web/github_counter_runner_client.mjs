import { readCounterRunnerArchive, readRunnerArchiveEntry } from './counter_runner_archive.mjs';
import { webZipSha256 } from './web_execution_artifact_download.mjs';
import { MAX_WEB_APP_JOB_INPUT_CHARS, MAX_WEB_APP_RESULT_PACKET_BYTES } from './web_application_runner_packet.mjs';

const API = 'https://api.github.com/repos/pilialvu75-hue/Ai-orchestrator-riserva';
const REPOSITORY_ID = 1235011890;
const SHA = /^[0-9a-f]{40}$/;
const DIGEST = /^sha256:[0-9a-f]{64}$/;
const TICKET = /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/;

function validId(id) {
  return Number.isSafeInteger(id) && id > 0;
}

function storageRedirect(location) {
  if (!location) throw new Error('Runner archive redirect is invalid');
  const url = new URL(location);
  if (url.protocol !== 'https:' || url.port || url.username || url.password ||
      (url.hostname !== 'results-receiver.actions.githubusercontent.com' &&
       !url.hostname.endsWith('.blob.core.windows.net'))) {
    throw new Error('Runner archive redirect is invalid');
  }
  return url;
}

async function readArchive(response, size) {
  const length = response.headers.get('content-length');
  if (response.status !== 200 || !response.body || (length !== null && Number(length) !== size)) {
    throw new Error('Runner archive download failed');
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
        throw new Error('Runner archive length mismatch');
      }
      bytes.set(value, offset);
      offset += value.length;
    }
  } finally {
    reader.releaseLock();
  }
  if (offset !== size) throw new Error('Runner archive length mismatch');
  return bytes;
}

function createGitHubRunnerClient({ token, expectedHeadSha, fetchImpl = fetch }, {
  workflow, artifactName, maxArchiveBytes, openArchive,
}) {
  if (typeof token !== 'string' || !token.trim() || typeof expectedHeadSha !== 'string' ||
      !SHA.test(expectedHeadSha)) {
    throw new TypeError('Runner GitHub configuration is invalid');
  }

  function apiRequest(path, { body } = {}) {
    return fetchImpl(API + path, {
      method: body ? 'POST' : 'GET',
      headers: {
        Accept: 'application/vnd.github+json',
        Authorization: 'Bearer ' + token,
        'X-GitHub-Api-Version': '2026-03-10',
        'User-Agent': 'Aivexus-Web',
        ...(body ? { 'Content-Type': 'application/json' } : {}),
      },
      ...(body ? { body: JSON.stringify(body) } : {}),
      redirect: 'manual',
      signal: AbortSignal.timeout(5000),
    });
  }

  async function request(path, body) {
    const response = await apiRequest(path, { body });
    if (response.status !== 200) throw new Error('Runner GitHub request failed');
    return await response.json();
  }

  return {
    async dispatch(inputs) {
      // A caller must persist the dispatch attempt before calling this method.
      // A timeout is ambiguous. Never retry this POST without reconciliation.
      const result = await request('/actions/workflows/' + workflow + '/dispatches', {
        ref: 'main', inputs,
      });
      if (!validId(result?.workflow_run_id)) throw new Error('Runner dispatch not confirmed');
      return result.workflow_run_id;
    },

    async readResult(runId) {
      if (!validId(runId)) throw new TypeError('Runner run ID is invalid');
      const runPath = '/actions/runs/' + runId;
      const run = await request(runPath);
      if (run?.id !== runId || run.event !== 'workflow_dispatch' || run.run_attempt !== 1 ||
          run.head_branch !== 'main' || run.head_sha !== expectedHeadSha ||
          run.path !== '.github/workflows/' + workflow ||
          run.repository?.id !== REPOSITORY_ID || run.head_repository?.id !== REPOSITORY_ID) {
        throw new Error('Runner provenance verification failed');
      }
      if (run.status !== 'completed') return { status: 'pending' };
      if (run.conclusion !== 'success') return { status: 'failed' };

      const list = await request(runPath + '/artifacts?per_page=2');
      const [artifact] = Array.isArray(list?.artifacts) ? list.artifacts : [];
      const source = artifact?.workflow_run;
      if (list?.total_count !== 1 || list.artifacts?.length !== 1 ||
          !validId(artifact?.id) || artifact.name !== artifactName || artifact.expired !== false ||
          !Number.isSafeInteger(artifact.size_in_bytes) || artifact.size_in_bytes < 1 ||
          artifact.size_in_bytes > maxArchiveBytes ||
          typeof artifact.digest !== 'string' || !DIGEST.test(artifact.digest) ||
          source?.id !== runId || source.repository_id !== run.repository.id ||
          source.head_repository_id !== run.repository.id || source.head_branch !== 'main' ||
          source.head_sha !== expectedHeadSha) {
        throw new Error('Runner artifact provenance verification failed');
      }
      return {
        status: 'ready', artifactId: artifact.id,
        sha256: artifact.digest.slice('sha256:'.length), size: artifact.size_in_bytes,
      };
    },

    async downloadArchive(result) {
      const { artifactId, sha256, size } = result ?? {};
      if (result?.status !== 'ready' || !validId(artifactId) ||
          !Number.isSafeInteger(size) || size < 1 || size > maxArchiveBytes ||
          typeof sha256 !== 'string' || !DIGEST.test('sha256:' + sha256)) {
        throw new TypeError('Runner archive metadata is invalid');
      }
      const response = await apiRequest('/actions/artifacts/' + artifactId + '/zip');
      if (response.status !== 302) throw new Error('Runner archive redirect failed');
      const target = storageRedirect(response.headers.get('location'));
      const archived = await fetchImpl(target.href, {
        method: 'GET', redirect: 'manual', credentials: 'omit', signal: AbortSignal.timeout(10000),
      });
      const bytes = await readArchive(archived, size);
      if (await webZipSha256(bytes) !== sha256) throw new Error('Runner archive digest mismatch');
      return openArchive(bytes);
    },
  };
}

export function createGitHubCounterRunnerClient(options) {
  const client = createGitHubRunnerClient(options, {
    workflow: 'web-counter-runner.yml', artifactName: 'aivexus-counter-envelope',
    maxArchiveBytes: 128 * 1024, openArchive: readCounterRunnerArchive,
  });
  return {
    ...client,
    async dispatch({ ticket, publicKeySpki }) {
      if (typeof ticket !== 'string' || !TICKET.test(ticket) ||
          typeof publicKeySpki !== 'string' || publicKeySpki.length > 416 ||
          !/^[A-Za-z0-9+/]+={0,2}$/.test(publicKeySpki)) {
        throw new TypeError('Counter runner inputs are invalid');
      }
      return client.dispatch({ ticket, public_key: publicKeySpki });
    },
  };
}

export function createGitHubWebApplicationRunnerClient(options) {
  const maxArchiveBytes = 224 * 1024;
  const client = createGitHubRunnerClient(options, {
    workflow: 'web-application-runner.yml', artifactName: 'aivexus-application-envelope',
    maxArchiveBytes,
    openArchive: bytes => readRunnerArchiveEntry(bytes, 'application.aivexus', MAX_WEB_APP_RESULT_PACKET_BYTES, maxArchiveBytes),
  });
  return {
    ...client,
    async dispatch({ ticket, input }) {
      if (typeof ticket !== 'string' || !TICKET.test(ticket) || typeof input !== 'string' ||
          input.length < 1 || input.length > MAX_WEB_APP_JOB_INPUT_CHARS ||
          input.length % 4 || !/^[A-Za-z0-9+/]+={0,2}$/.test(input)) {
        throw new TypeError('Application runner inputs are invalid');
      }
      return client.dispatch({ ticket, job: input });
    },
  };
}
