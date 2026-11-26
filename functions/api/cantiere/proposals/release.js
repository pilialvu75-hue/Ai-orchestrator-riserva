import { createAuthenticatedWebProjectOperation } from
  '../../../../scripts/web/authenticated_web_project_operation.mjs';

export function onRequest({ request, env }) {
  return createAuthenticatedWebProjectOperation({
    operation: request.method === 'GET' ? 'app_release_history' : 'app_release_change',
    expectedOrigin: env.AIVEXUS_WEB_ORIGIN, accessIssuer: env.AIVEXUS_WEB_ACCESS_ISSUER,
    accessAudience: env.AIVEXUS_WEB_ACCESS_AUDIENCE, db: env.AIVEXUS_WEB_D1,
    releasesEnabled: env.AIVEXUS_WEB_PRIVATE_RELEASES_ENABLED === 'true',
    ownerOnly: true,
    adminSubject: env.AIVEXUS_WEB_ADMIN_ACCESS_SUBJECT,
    ownerEmail: env.AIVEXUS_WEB_OWNER_EMAIL,
  })(request);
}
