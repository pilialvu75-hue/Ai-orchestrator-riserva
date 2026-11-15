-- Aivexus Web-owned execution journal + immutable artifact receipts.
-- SOURCE-ONLY migration 003. Apply after 001 and 002; no live D1 changes.
-- Keep authorization, build, blob storage and artifact read-back verification in
-- trusted Web-owned workers. Never execute jobs from browser-supplied claims.
-- No automatic retry of a running or interrupted execution is permitted.

ALTER TABLE web_execution_reservations
  ADD COLUMN journal_version INTEGER NOT NULL DEFAULT 0
  CHECK (journal_version >= 0);
ALTER TABLE web_execution_reservations
  ADD COLUMN worker_token TEXT
  CHECK (worker_token IS NULL OR (
    length(worker_token) BETWEEN 16 AND 128 AND
    worker_token NOT GLOB '*[^a-zA-Z0-9_-]*'
  ));
ALTER TABLE web_execution_reservations
  ADD COLUMN transition_at TEXT;
ALTER TABLE web_execution_reservations
  ADD COLUMN artifact_storage_key TEXT;
ALTER TABLE web_execution_reservations
  ADD COLUMN artifact_size_bytes INTEGER
  CHECK (artifact_size_bytes IS NULL OR artifact_size_bytes > 0);
ALTER TABLE web_execution_reservations
  ADD COLUMN failure_kind TEXT
  CHECK (failure_kind IS NULL OR
    failure_kind IN ('preflight','build','test','storage','interrupted','reconciliation'));

CREATE TABLE IF NOT EXISTS web_execution_journal_events (
  event_id INTEGER PRIMARY KEY AUTOINCREMENT,
  idempotency_key TEXT NOT NULL,
  execution_id TEXT NOT NULL,
  attempt_id TEXT NOT NULL,
  journal_version INTEGER NOT NULL,
  from_status TEXT,
  to_status TEXT NOT NULL,
  event_at TEXT NOT NULL,
  failure_kind TEXT,
  artifact_sha256 TEXT,
  UNIQUE(idempotency_key, journal_version),
  FOREIGN KEY (idempotency_key)
    REFERENCES web_execution_reservations(idempotency_key)
);
CREATE INDEX IF NOT EXISTS web_execution_journal_by_attempt
  ON web_execution_journal_events(attempt_id, event_id);

CREATE TABLE IF NOT EXISTS web_execution_artifact_receipts (
  idempotency_key TEXT PRIMARY KEY,
  execution_id TEXT NOT NULL UNIQUE,
  attempt_id TEXT NOT NULL UNIQUE,
  approved_spec_sha256 TEXT NOT NULL,
  artifact_sha256 TEXT NOT NULL
    CHECK (length(artifact_sha256) = 64 AND
      artifact_sha256 NOT GLOB '*[^0-9a-f]*'),
  artifact_storage_key TEXT NOT NULL UNIQUE,
  artifact_size_bytes INTEGER NOT NULL CHECK (artifact_size_bytes > 0),
  recorded_at TEXT NOT NULL,
  FOREIGN KEY (idempotency_key)
    REFERENCES web_execution_reservations(idempotency_key)
);

CREATE TRIGGER IF NOT EXISTS web_execution_insert_guard
BEFORE INSERT ON web_execution_reservations
WHEN NEW.status IS NOT 'reserved' OR NEW.journal_version IS NOT 0
  OR NEW.worker_token IS NOT NULL OR NEW.artifact_sha256 IS NOT NULL
  OR NEW.artifact_storage_key IS NOT NULL OR NEW.artifact_size_bytes IS NOT NULL
  OR NEW.transition_at IS NOT NULL OR NEW.failure_kind IS NOT NULL
BEGIN
  SELECT RAISE(ABORT, 'invalid_web_execution_reservation');
END;

-- A status change is an exact, single-statement CAS. Stable identity is never
-- rewritten. A run is claimed once; interrupted runs cannot be resumed blindly.
-- sqlite IS / IS NOT provide NULL-safe equality, unlike = / !=.
CREATE TRIGGER IF NOT EXISTS web_execution_transition_guard
BEFORE UPDATE ON web_execution_reservations
WHEN NOT (
  NEW.idempotency_key IS OLD.idempotency_key AND
  NEW.product IS OLD.product AND
  NEW.owner_subject IS OLD.owner_subject AND
  NEW.project_id IS OLD.project_id AND
  NEW.revision IS OLD.revision AND
  NEW.approval_id IS OLD.approval_id AND
  NEW.approved_spec_sha256 IS OLD.approved_spec_sha256 AND
  NEW.execution_id IS OLD.execution_id AND
  NEW.attempt_id IS OLD.attempt_id AND
  NEW.created_at IS OLD.created_at AND
  NEW.journal_version = OLD.journal_version + 1 AND
  NEW.transition_at IS NOT NULL AND
  (
    (OLD.status = 'reserved' AND NEW.status = 'running' AND
      OLD.worker_token IS NULL AND NEW.worker_token IS NOT NULL AND
      NEW.failure_kind IS NULL) OR
    (OLD.status = 'reserved' AND NEW.status = 'failed' AND
      NEW.worker_token IS NULL AND NEW.failure_kind = 'preflight') OR
    (OLD.status = 'running' AND NEW.status = 'review_required' AND
      NEW.worker_token IS OLD.worker_token AND
      NEW.failure_kind = 'interrupted') OR
    (OLD.status = 'running' AND NEW.status = 'failed' AND
      NEW.worker_token IS OLD.worker_token AND
      NEW.failure_kind IN ('build','test','storage')) OR
    (OLD.status = 'review_required' AND NEW.status = 'failed' AND
      NEW.worker_token IS OLD.worker_token AND
      NEW.failure_kind = 'reconciliation') OR
    (OLD.status = 'running' AND NEW.status = 'completed' AND
      NEW.worker_token IS OLD.worker_token AND
      NEW.failure_kind IS NULL AND
      NEW.artifact_sha256 IS NOT NULL AND
      length(NEW.artifact_sha256) = 64 AND
      NEW.artifact_sha256 NOT GLOB '*[^0-9a-f]*' AND
      NEW.artifact_size_bytes > 0 AND
      NEW.artifact_storage_key =
        'web-artifacts/' || NEW.execution_id || '/' ||
        NEW.artifact_sha256 || '.zip')
  ) AND
  (
    NEW.status = 'completed' OR
    (NEW.artifact_sha256 IS NULL AND
     NEW.artifact_storage_key IS NULL AND NEW.artifact_size_bytes IS NULL)
  )
)
BEGIN
  SELECT RAISE(ABORT, 'invalid_web_execution_transition');
END;

CREATE TRIGGER IF NOT EXISTS web_execution_initial_event
AFTER INSERT ON web_execution_reservations
BEGIN
  INSERT INTO web_execution_journal_events (
    idempotency_key, execution_id, attempt_id, journal_version,
    from_status, to_status, event_at, failure_kind, artifact_sha256
  ) VALUES (
    NEW.idempotency_key, NEW.execution_id, NEW.attempt_id, 0,
    NULL, 'reserved', NEW.created_at, NULL, NULL
  );
END;

CREATE TRIGGER IF NOT EXISTS web_execution_transition_event
AFTER UPDATE ON web_execution_reservations
BEGIN
  INSERT INTO web_execution_journal_events (
    idempotency_key, execution_id, attempt_id, journal_version,
    from_status, to_status, event_at, failure_kind, artifact_sha256
  ) VALUES (
    NEW.idempotency_key, NEW.execution_id, NEW.attempt_id,
    NEW.journal_version, OLD.status, NEW.status, NEW.transition_at,
    NEW.failure_kind, NEW.artifact_sha256
  );
END;

-- The artifact receipt is written by SQLite atomically with completion;
-- a failed INSERT prevents status='completed'. The trusted worker MUST
-- verify the stored ZIP bytes, SHA-256 and tests before calling completion.
CREATE TRIGGER IF NOT EXISTS web_execution_complete_receipt
AFTER UPDATE ON web_execution_reservations
WHEN NEW.status = 'completed' AND OLD.status IS NOT 'completed'
BEGIN
  INSERT INTO web_execution_artifact_receipts (
    idempotency_key, execution_id, attempt_id, approved_spec_sha256,
    artifact_sha256, artifact_storage_key, artifact_size_bytes, recorded_at
  ) VALUES (
    NEW.idempotency_key, NEW.execution_id, NEW.attempt_id,
    NEW.approved_spec_sha256, NEW.artifact_sha256,
    NEW.artifact_storage_key, NEW.artifact_size_bytes, NEW.transition_at
  );
END;

CREATE TRIGGER IF NOT EXISTS web_execution_no_delete
BEFORE DELETE ON web_execution_reservations
BEGIN SELECT RAISE(ABORT, 'immutable_web_execution_history'); END;
CREATE TRIGGER IF NOT EXISTS web_execution_events_no_update
BEFORE UPDATE ON web_execution_journal_events
BEGIN SELECT RAISE(ABORT, 'immutable_web_execution_history'); END;
CREATE TRIGGER IF NOT EXISTS web_execution_events_no_delete
BEFORE DELETE ON web_execution_journal_events
BEGIN SELECT RAISE(ABORT, 'immutable_web_execution_history'); END;
CREATE TRIGGER IF NOT EXISTS web_execution_receipts_no_update
BEFORE UPDATE ON web_execution_artifact_receipts
BEGIN SELECT RAISE(ABORT, 'immutable_web_execution_receipt'); END;
CREATE TRIGGER IF NOT EXISTS web_execution_receipts_no_delete
BEFORE DELETE ON web_execution_artifact_receipts
BEGIN SELECT RAISE(ABORT, 'immutable_web_execution_receipt'); END;
