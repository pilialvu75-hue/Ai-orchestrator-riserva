import { studioAccessOptions } from '../studio-access.js';
import { createAuthenticatedWebProjectOperation } from
  '../../../../scripts/web/authenticated_web_project_operation.mjs';

export function onRequest({ request, env }) {
  return createAuthenticatedWebProjectOperation({
    operation: request.method === 'GET' ? 'verification_status' : 'verify_app',
    expectedOrigin: env.AIVEXUS_WEB_ORIGIN,
    accessIssuer: env.AIVEXUS_WEB_ACCESS_ISSUER,
    accessAudience: env.AIVEXUS_WEB_ACCESS_AUDIENCE,
    db: env.AIVEXUS_WEB_D1,
    ...studioAccessOptions(env),
    appMemberInvitesEnabled: env.AIVEXUS_WEB_APP_MEMBERS_ENABLED === 'true',
    runner: {
      token: env.AIVEXUS_WEB_BUILDER_GITHUB_TOKEN || env.AIVEXUS_COUNTER_GITHUB_TOKEN,
      expectedHeadSha: env.AIVEXUS_WEB_BUILDER_GITHUB_HEAD_SHA,
      authorizationKey: env.AIVEXUS_WEB_BUILDER_JOB_AUTH_KEY,
      jobPublicKey: env.AIVEXUS_WEB_BUILDER_JOB_PUBLIC_KEY,
      resultPublicKey: env.AIVEXUS_WEB_BUILDER_RESULT_PUBLIC_KEY,
      resultPrivateKey: env.AIVEXUS_WEB_BUILDER_RESULT_PRIVATE_KEY,
    },
  })(request);
}
