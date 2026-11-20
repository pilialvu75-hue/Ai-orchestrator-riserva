// AIVEXUS Web owner is the *existing* Cloudflare Access identity, never a
// separately created administrator account. Input principal is produced only
// after Access issuer/audience/JWKS/signature/expiry verification.
//
// Allowlist settings are private Pages Production configuration, NEVER supplied
// by the browser. A customer allowed by Access stays a customer by default.
function canonicalEmail(value) {
  if (typeof value !== 'string' || value.length > 254) return null;
  const email = value.trim().toLowerCase();
  if (!/^[^\s@<>]{1,64}@[a-z0-9.-]+\.[a-z]{2,}$/.test(email) ||
      email.includes('..')) return null;
  return email;
}

export function existingWebOwnerSubject({
  principal, configuredSubject, configuredEmail,
} = {}) {
  if (principal?.verifiedBy !== 'cloudflare-access-jwt' ||
      typeof principal.subject !== 'string' ||
      !principal.subject || principal.subject.length > 256) return null;
  // Preserve the old stable Cloudflare Access subject configuration.
  if (typeof configuredSubject === 'string' && configuredSubject &&
      configuredSubject.length <= 256 &&
      principal.subject === configuredSubject) return principal.subject;
  // Additional owner identity route: a *signed* Access email from the
  // IdP, matched against a private server setting. No unverified header,
  // raw request JSON, browser input, or self-registration can grant this role.
  const allowedEmail = canonicalEmail(configuredEmail);
  if (allowedEmail && canonicalEmail(principal.email) === allowedEmail) {
    return principal.subject;
  }
  return null;
}
