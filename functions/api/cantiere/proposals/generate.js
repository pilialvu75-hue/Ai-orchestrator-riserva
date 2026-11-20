import { createAuthenticatedWebProjectOperation } from
  '../../../../scripts/web/authenticated_web_project_operation.mjs';
import { createWebBuilderInference } from '../inference.js';

export function onRequest({ request, env }) {
  return createAuthenticatedWebProjectOperation({
    operation: request.method === 'GET' ? 'generation_status' : 'generate_app',
    expectedOrigin: env.AIVEXUS_WEB_ORIGIN,
    accessIssuer: env.AIVEXUS_WEB_ACCESS_ISSUER,
    accessAudience: env.AIVEXUS_WEB_ACCESS_AUDIENCE,
    db: env.AIVEXUS_WEB_D1,
    // Deliberately pause all customer access; this cannot be reenabled by
    // changing a Pages flag without a reviewed code change.
    ownerOnly: true,
    clientAccessEnabled: false,
    adminSubject: env.AIVEXUS_WEB_ADMIN_ACCESS_SUBJECT,
    ownerEmail: env.AIVEXUS_WEB_OWNER_EMAIL,
    infer: request.method === 'POST' ? createWebBuilderInference(env) : null,
  })(request);
}
