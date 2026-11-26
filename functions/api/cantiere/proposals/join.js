import { createAuthenticatedWebProjectOperation } from
  '../../../../scripts/web/authenticated_web_project_operation.mjs';

export function onRequest({ request, env }) {
  return createAuthenticatedWebProjectOperation({
    operation: 'app_join', expectedOrigin: env.AIVEXUS_WEB_ORIGIN,
    accessIssuer: env.AIVEXUS_WEB_ACCESS_ISSUER, accessAudience: env.AIVEXUS_WEB_ACCESS_AUDIENCE,
    db: env.AIVEXUS_WEB_D1,
    appMemberInvitesEnabled: env.AIVEXUS_WEB_APP_MEMBERS_ENABLED === 'true',
    ownerOnly: false,
    adminSubject: env.AIVEXUS_WEB_ADMIN_ACCESS_SUBJECT,
    ownerEmail: env.AIVEXUS_WEB_OWNER_EMAIL,
  })(request);
}
