import { createAuthenticatedWebProjectOperation } from
  '../../../../scripts/web/authenticated_web_project_operation.mjs';
import { createD1WebCounterArtifactStore } from
  '../../../../scripts/web/d1_web_counter_artifact_store.mjs';

export function onRequest({ request, env }) {
  return createAuthenticatedWebProjectOperation({
    operation: 'download',
    expectedOrigin: env.AIVEXUS_WEB_ORIGIN,
    accessIssuer: env.AIVEXUS_WEB_ACCESS_ISSUER,
    accessAudience: env.AIVEXUS_WEB_ACCESS_AUDIENCE,
    db: env.AIVEXUS_WEB_D1,
    bucket: env.AIVEXUS_WEB_ARTIFACTS ?? createD1WebCounterArtifactStore(env.AIVEXUS_WEB_D1),
  })(request);
}
