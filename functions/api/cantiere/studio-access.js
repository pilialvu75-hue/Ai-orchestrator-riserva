export function studioBetaEnabled(env) {
  return env.AIVEXUS_WEB_STUDIO_BETA_ENABLED === 'true' &&
    env.AIVEXUS_WEB_CLIENT_ACCESS_ENABLED === 'true';
}

export function studioAccessOptions(env, allowsAppMembers = false) {
  const beta = studioBetaEnabled(env);
  const memberAccess = allowsAppMembers && env.AIVEXUS_WEB_APP_MEMBERS_ENABLED === 'true';
  return {
    adminSubject: env.AIVEXUS_WEB_ADMIN_ACCESS_SUBJECT,
    ownerEmail: env.AIVEXUS_WEB_OWNER_EMAIL,
    ownerOnly: !beta && !memberAccess,
    clientAccessEnabled: beta,
  };
}
