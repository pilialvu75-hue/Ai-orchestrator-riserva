-- Aivexus Web-owned durable approval + execution reservation schema.
-- Source-only: no Cloudflare D1 database or binding is created by this file.
-- All writes to web_project_approvals must be made by a separately reviewed,
-- authenticated Web approval endpoint, NEVER copied directly from browser JSON.

CREATE TABLE IF NOT EXISTS web_project_approvals (
  owner_subject TEXT NOT NULL,
  project_id TEXT NOT NULL,
  product TEXT NOT NULL CHECK(product = 'aivexus-web'),
  status TEXT NOT NULL CHECK(status IN ('draft','proposal_ready','approved','revoked')),
  current_revision INTEGER NOT NULL CHECK(current_revision >= 1),
  approved_revision INTEGER,
  approved_spec_sha256 TEXT,
  approval_id TEXT,
  updated_at TEXT NOT NULL,
  PRIMARY KEY (owner_subject, project_id),
  CHECK (status != 'approved' OR
         (approved_revision = current_revision AND
          length(approved_spec_sha256) = 64 AND
          approval_id IS NOT NULL))
);

CREATE TABLE IF NOT EXISTS web_execution_reservations (
  idempotency_key TEXT PRIMARY KEY NOT NULL,
  product TEXT NOT NULL CHECK(product = 'aivexus-web'),
  owner_subject TEXT NOT NULL,
  project_id TEXT NOT NULL,
  revision INTEGER NOT NULL CHECK(revision >= 1),
  approval_id TEXT NOT NULL,
  approved_spec_sha256 TEXT NOT NULL,
  execution_id TEXT NOT NULL UNIQUE,
  attempt_id TEXT NOT NULL UNIQUE,
  status TEXT NOT NULL DEFAULT 'reserved'
    CHECK(status IN ('reserved','running','review_required','failed','completed')),
  artifact_sha256 TEXT,
  created_at TEXT NOT NULL,
  FOREIGN KEY (owner_subject, project_id)
    REFERENCES web_project_approvals(owner_subject, project_id)
);

CREATE INDEX IF NOT EXISTS web_execution_by_project
  ON web_execution_reservations(owner_subject, project_id, revision);
