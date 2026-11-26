import { readMemberWebApplicationSource } from './d1_web_application_members.mjs';

const REPOSITORY = /^[A-Za-z0-9][A-Za-z0-9-]{0,38}\/[A-Za-z0-9][A-Za-z0-9_.-]{0,99}$/;
const fail = reason => ({ ok: false, reason });

export async function readWebApplicationIntegration({ db, ownerSubject, request, integrationConfig }) {
  const { generationId, integration } = request;
  if (Object.keys(request).length !== 2 || integration !== 'github_repository') return fail('invalid_request');
  const verified = await readMemberWebApplicationSource({ db, ownerSubject, generationId });
  if (!verified.ok) return verified;
  if (!verified.source.runtime?.integrations?.includes(integration)) return fail('integration_not_found');
  const { repository, token } = integrationConfig ?? {};
  if (typeof repository !== 'string' || !REPOSITORY.test(repository)) return fail('integration_unavailable');
  try {
    const path = repository.split('/').map(encodeURIComponent).join('/');
    const response = await fetch('https://api.github.com/repos/' + path, {
      method: 'GET', redirect: 'manual', signal: AbortSignal.timeout(6000),
      headers: {
        Accept: 'application/vnd.github+json', 'X-GitHub-Api-Version': '2026-03-10',
        'User-Agent': 'Aivexus-Web-Integration', ...(token ? { Authorization: 'Bearer ' + token } : {}),
      },
    });
    if (!response.ok || Number(response.headers.get('Content-Length')) > 65536) return fail('integration_unavailable');
    const body = await response.text();
    if (body.length > 65536) return fail('integration_unavailable');
    const data = JSON.parse(body);
    if (data.private !== false || typeof data.full_name !== 'string' || data.full_name.toLowerCase() !== repository.toLowerCase() ||
        !Number.isSafeInteger(data.stargazers_count) || data.stargazers_count < 0) return fail('integration_unavailable');
    return { ok: true, repository: { fullName: data.full_name, stars: data.stargazers_count } };
  } catch (_) {
    return fail('integration_unavailable');
  }
}
