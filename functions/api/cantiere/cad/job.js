import { createAuthenticatedWebProjectOperation } from '../../../../scripts/web/authenticated_web_project_operation.mjs';

export function onRequest({ request, env }) {
  return createAuthenticatedWebProjectOperation({
    operation: 'cad_job',
    expectedOrigin: env.AIVEXUS_WEB_ORIGIN,
    accessIssuer: env.AIVEXUS_WEB_ACCESS_ISSUER,
    accessAudience: env.AIVEXUS_WEB_ACCESS_AUDIENCE,
    db: env.AIVEXUS_WEB_D1,
    ownerOnly: true,
    adminSubject: env.AIVEXUS_WEB_ADMIN_ACCESS_SUBJECT,
    ownerEmail: env.AIVEXUS_WEB_OWNER_EMAIL,
    runner: env.AIVEXUS_WEB_CAD_RUNNER_ENABLED === 'true' ? {
      token: env.AIVEXUS_WEB_BUILDER_GITHUB_TOKEN || env.AIVEXUS_COUNTER_GITHUB_TOKEN,
      headSha: env.AIVEXUS_WEB_BUILDER_GITHUB_HEAD_SHA,
      authorizationKey: env.AIVEXUS_WEB_BUILDER_JOB_AUTH_KEY,
      jobPublicKey: env.AIVEXUS_WEB_BUILDER_JOB_PUBLIC_KEY,
      resultPublicKey: env.AIVEXUS_WEB_BUILDER_RESULT_PUBLIC_KEY,
      resultPrivateKey: env.AIVEXUS_WEB_BUILDER_RESULT_PRIVATE_KEY,
    } : null,
  })(request);
}
