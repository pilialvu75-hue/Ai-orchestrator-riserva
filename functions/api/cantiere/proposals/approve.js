import { createAuthenticatedWebProjectOperation } from
  '../../../../scripts/web/authenticated_web_project_operation.mjs';

export function onRequest({ request, env }) {
  return createAuthenticatedWebProjectOperation({
    operation: 'approve',
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
  })(request);
}
