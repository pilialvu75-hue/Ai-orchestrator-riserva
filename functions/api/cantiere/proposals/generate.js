import { studioAccessOptions } from '../studio-access.js';
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
    ...studioAccessOptions(env),
    infer: request.method === 'POST' ? createWebBuilderInference(env) : null,
  })(request);
}
