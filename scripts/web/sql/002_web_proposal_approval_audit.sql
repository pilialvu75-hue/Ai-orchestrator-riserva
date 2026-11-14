-- AIVEXUS Web-only migration; apply AFTER 001_web_approval_reservation.sql.
-- SOURCE-ONLY: no D1 resource is created or migrated by this commit.
-- proposal_spec_sha256 must be written by a future authenticated, Web-owned
-- proposal-persistence path. The browser never chooses this stored value.
ALTER TABLE web_project_approvals
  ADD COLUMN proposal_spec_sha256 TEXT
  CHECK (
    proposal_spec_sha256 IS NULL OR (
      length(proposal_spec_sha256) = 64 AND
      proposal_spec_sha256 NOT GLOB '*[^0-9a-f]*'
    )
  );

CREATE TABLE IF NOT EXISTS web_approval_audit (
  event_id INTEGER PRIMARY KEY AUTOINCREMENT,
  owner_subject TEXT NOT NULL,
  project_id TEXT NOT NULL,
  revision INTEGER NOT NULL,
  event_type TEXT NOT NULL CHECK(event_type IN ('approved', 'revoked')),
  proposal_spec_sha256 TEXT NOT NULL,
  approval_id TEXT NOT NULL,
  event_at TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS web_approval_audit_by_project
  ON web_approval_audit(owner_subject, project_id, event_id);

-- Guard against any future writer approving a hash different from the
-- persisted proposal, or approving a revision with no trusted proposal.
CREATE TRIGGER IF NOT EXISTS web_approval_guard_update
BEFORE UPDATE ON web_project_approvals
WHEN NEW.status = 'approved' AND (
  NEW.proposal_spec_sha256 IS NULL OR
  NEW.approved_spec_sha256 IS NOT NEW.proposal_spec_sha256 OR
  NEW.approved_revision IS NOT NEW.current_revision
)
BEGIN
  SELECT RAISE(ABORT, 'untrusted_web_approval');
END;

CREATE TRIGGER IF NOT EXISTS web_approval_guard_insert
BEFORE INSERT ON web_project_approvals
WHEN NEW.status = 'approved' AND (
  NEW.proposal_spec_sha256 IS NULL OR
  NEW.approved_spec_sha256 IS NOT NEW.proposal_spec_sha256 OR
  NEW.approved_revision IS NOT NEW.current_revision
)
BEGIN
  SELECT RAISE(ABORT, 'untrusted_web_approval');
END;

-- The audit row is created by SQLite in the same statement/transaction as
-- the successful approval or revocation, never by a separate best-effort call.
CREATE TRIGGER IF NOT EXISTS web_approval_audit_transition
AFTER UPDATE OF status, approval_id ON web_project_approvals
WHEN NEW.status IN ('approved','revoked') AND (
  NEW.status IS NOT OLD.status OR NEW.approval_id IS NOT OLD.approval_id
)
BEGIN
  INSERT INTO web_approval_audit
    (owner_subject, project_id, revision, event_type,
     proposal_spec_sha256, approval_id, event_at)
  VALUES
    (NEW.owner_subject, NEW.project_id, NEW.current_revision, NEW.status,
     NEW.proposal_spec_sha256,
     CASE WHEN NEW.status = 'revoked' THEN OLD.approval_id
          ELSE NEW.approval_id END,
     NEW.updated_at);
END;


-- Once a revision is approved its digest and approval identity cannot be
-- edited in-place to silently repurpose an earlier approval. Revoke first,
-- then persist a *new* proposal/revision through the trusted writer.
CREATE TRIGGER IF NOT EXISTS web_approved_identity_immutable
BEFORE UPDATE ON web_project_approvals
WHEN OLD.status = 'approved' AND (
  NEW.status NOT IN ('approved', 'revoked') OR
  (NEW.status = 'approved' AND (
    NEW.current_revision IS NOT OLD.current_revision OR
    NEW.approved_revision IS NOT OLD.approved_revision OR
    NEW.approved_spec_sha256 IS NOT OLD.approved_spec_sha256 OR
    NEW.proposal_spec_sha256 IS NOT OLD.proposal_spec_sha256 OR
    NEW.approval_id IS NOT OLD.approval_id
  )) OR
  (NEW.status = 'revoked' AND (
    NEW.current_revision IS NOT OLD.current_revision OR
    NEW.proposal_spec_sha256 IS NOT OLD.proposal_spec_sha256 OR
    NEW.approved_revision IS NOT NULL OR
    NEW.approved_spec_sha256 IS NOT NULL OR
    NEW.approval_id IS NOT NULL
  ))
)
BEGIN
  SELECT RAISE(ABORT, 'immutable_web_approved_revision');
END;

-- Audit history is append-only. Retention/deletion policy requires a separate
-- explicitly reviewed data-governance migration, not an application endpoint.
CREATE TRIGGER IF NOT EXISTS web_approval_audit_no_update
BEFORE UPDATE ON web_approval_audit
BEGIN
  SELECT RAISE(ABORT, 'immutable_web_approval_audit');
END;
CREATE TRIGGER IF NOT EXISTS web_approval_audit_no_delete
BEFORE DELETE ON web_approval_audit
BEGIN
  SELECT RAISE(ABORT, 'immutable_web_approval_audit');
END;
