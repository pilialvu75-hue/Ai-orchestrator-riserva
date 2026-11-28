import { studioBetaEnabled } from '../studio-access.js';
import { createWebCustomerAccessHandler } from
  '../../../../scripts/web/web_client_invitations.mjs';

// Account roles are resolved only from a cryptographically verified Access
// assertion. Never trust a request-provided owner id, email or role.
export function onRequest({ request, env }) {
  return createWebCustomerAccessHandler({
    operation: 'revoke',
    expectedOrigin: env.AIVEXUS_WEB_ORIGIN,
    accessIssuer: env.AIVEXUS_WEB_ACCESS_ISSUER,
    accessAudience: env.AIVEXUS_WEB_ACCESS_AUDIENCE,
    configuredOwnerSubject: env.AIVEXUS_WEB_ADMIN_ACCESS_SUBJECT,
    configuredOwnerEmail: env.AIVEXUS_WEB_OWNER_EMAIL,
    clientAccessEnabled: studioBetaEnabled(env),
    enrollmentPaused: !studioBetaEnabled(env),
    db: env.AIVEXUS_WEB_D1,
  })(request);
}
