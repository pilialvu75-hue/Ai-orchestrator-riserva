import { createAuthenticatedWebProjectOperation } from
  '../../../../scripts/web/authenticated_web_project_operation.mjs';

export function onRequest({ request, env }) {
  return createAuthenticatedWebProjectOperation({
    operation: 'advance',
    expectedOrigin: env.AIVEXUS_WEB_ORIGIN,
    accessIssuer: env.AIVEXUS_WEB_ACCESS_ISSUER,
    accessAudience: env.AIVEXUS_WEB_ACCESS_AUDIENCE,
    db: env.AIVEXUS_WEB_D1,
    clientAccessEnabled: env.AIVEXUS_WEB_CLIENT_ACCESS_ENABLED === 'true',
    bucket: env.AIVEXUS_WEB_ARTIFACTS,
    runner: {
      token: env.AIVEXUS_COUNTER_GITHUB_TOKEN,
      expectedHeadSha: env.AIVEXUS_COUNTER_GITHUB_HEAD_SHA,
      publicKeySpki: env.AIVEXUS_COUNTER_PUBLIC_KEY,
      privateKeyPkcs8: env.AIVEXUS_COUNTER_PRIVATE_KEY,
    },
  })(request);
}
