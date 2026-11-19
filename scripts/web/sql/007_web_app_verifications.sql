CREATE TABLE IF NOT EXISTS web_app_verifications (
  owner_subject TEXT NOT NULL,
  generation_id TEXT NOT NULL,
  ticket TEXT NOT NULL UNIQUE,
  head_sha TEXT NOT NULL CHECK(length(head_sha) = 40),
  job_sha256 TEXT NOT NULL CHECK(length(job_sha256) = 64),
  source_sha256 TEXT NOT NULL CHECK(length(source_sha256) = 64),
  status TEXT NOT NULL CHECK(status IN ('dispatching', 'submitted', 'importing', 'review_required', 'verified', 'failed', 'unavailable')),
  updated_at INTEGER NOT NULL DEFAULT (unixepoch()),
  run_id INTEGER UNIQUE CHECK(run_id > 0),
  import_id TEXT,
  receipt_json TEXT,
  source_json TEXT,
  zip_sha256 TEXT CHECK(length(zip_sha256) = 64),
  zip_bytes BLOB CHECK(length(zip_bytes) <= 73728),
  PRIMARY KEY (owner_subject, generation_id),
  FOREIGN KEY (owner_subject, generation_id) REFERENCES web_app_generations(owner_subject, generation_id),
  CHECK (status NOT IN ('submitted', 'importing', 'verified', 'failed', 'unavailable') OR run_id IS NOT NULL),
  CHECK (status != 'importing' OR import_id IS NOT NULL),
  CHECK (status != 'verified' OR (receipt_json IS NOT NULL AND source_json IS NOT NULL
    AND zip_sha256 IS NOT NULL AND zip_bytes IS NOT NULL))
);
