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
  // If the owner configured an email identity, it is authoritative:
  // an obsolete legacy subject must not grant a *second* owner account.
  const allowedEmail = canonicalEmail(configuredEmail);
  if (allowedEmail) {
    return canonicalEmail(principal.email) === allowedEmail
      ? principal.subject : null;
  }
  // Backward-compatible existing Access subject when the email binding is
  // absent. No new admin account, customer role or guest entitlement.
  if (typeof configuredSubject === 'string' && configuredSubject &&
      configuredSubject.length <= 256 &&
      principal.subject === configuredSubject) return principal.subject;
  return null;
}
