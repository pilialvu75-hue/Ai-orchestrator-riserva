import { createAuthenticatedWebProjectOperation } from
  '../../../../scripts/web/authenticated_web_project_operation.mjs';

export function onRequest({ request, env }) {
  return createAuthenticatedWebProjectOperation({
    operation: request.method === 'GET' ? 'verification_status' : 'verify_app',
    expectedOrigin: env.AIVEXUS_WEB_ORIGIN,
    accessIssuer: env.AIVEXUS_WEB_ACCESS_ISSUER,
    accessAudience: env.AIVEXUS_WEB_ACCESS_AUDIENCE,
    db: env.AIVEXUS_WEB_D1,
    // Deliberately pause all customer access; this cannot be reenabled by
    // changing a Pages flag without a reviewed code change.
    adminSubject: env.AIVEXUS_WEB_ADMIN_ACCESS_SUBJECT,
    ownerEmail: env.AIVEXUS_WEB_OWNER_EMAIL,
    ownerOnly: true,
    clientAccessEnabled: false,
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
