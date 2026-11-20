-- Customer invites are separate from the existing owner's Access identity.
-- The Cloudflare Access policy itself MUST independently allow the recipient
-- before the recipient can exercise this invitation. No anonymous entrypoint.
CREATE TABLE IF NOT EXISTS web_client_invitations (
  invitation_id TEXT PRIMARY KEY CHECK(length(invitation_id) = 36),
  owner_subject TEXT NOT NULL,
  recipient_email TEXT NOT NULL CHECK(length(recipient_email) BETWEEN 5 AND 254),
  customer_subject TEXT,
  status TEXT NOT NULL CHECK(status IN ('pending', 'accepted', 'revoked')),
  created_at INTEGER NOT NULL DEFAULT (unixepoch()),
  expires_at INTEGER NOT NULL,
  accepted_at INTEGER,
  CHECK(expires_at > created_at),
  CHECK(
    (status = 'accepted' AND customer_subject IS NOT NULL AND accepted_at IS NOT NULL) OR
    (status = 'pending' AND customer_subject IS NULL AND accepted_at IS NULL) OR
    (status = 'revoked')
  )
);
CREATE INDEX IF NOT EXISTS web_client_invitations_owner
 ON web_client_invitations(owner_subject, created_at DESC);
CREATE INDEX IF NOT EXISTS web_client_invitations_active
 ON web_client_invitations(customer_subject, recipient_email, status, expires_at);
CREATE INDEX IF NOT EXISTS web_client_invitations_claim
 ON web_client_invitations(invitation_id, recipient_email, status, expires_at);
