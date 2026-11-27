CREATE TABLE web_cad_jobs (
  owner_subject TEXT NOT NULL,
  project_id TEXT NOT NULL,
  revision_id TEXT NOT NULL,
  base_revision_id TEXT,
  head_sha TEXT NOT NULL,
  job_sha256 TEXT NOT NULL,
  parameters_json TEXT NOT NULL,
  photo_estimates_json TEXT NOT NULL DEFAULT '[]',
  status TEXT NOT NULL CHECK(status IN ('dispatching','submitted','review_required','failed','verified')),
  run_id INTEGER,
  created_at INTEGER NOT NULL DEFAULT (unixepoch()),
  PRIMARY KEY (owner_subject, project_id, revision_id)
);
CREATE UNIQUE INDEX web_cad_active_job ON web_cad_jobs(owner_subject)
  WHERE status IN ('dispatching','submitted');
