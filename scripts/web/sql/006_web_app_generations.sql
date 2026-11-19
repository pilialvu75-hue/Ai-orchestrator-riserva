CREATE TABLE IF NOT EXISTS web_app_generations (
  owner_subject TEXT NOT NULL,
  generation_id TEXT NOT NULL,
  prompt_sha256 TEXT NOT NULL CHECK(length(prompt_sha256) = 64),
  created_at INTEGER NOT NULL DEFAULT (unixepoch()),
  status TEXT NOT NULL CHECK(status IN ('generating', 'generated', 'failed')),
  result_json TEXT,
  PRIMARY KEY (owner_subject, generation_id),
  CHECK (
    (status = 'generated' AND result_json IS NOT NULL AND length(result_json) <= 65536) OR
    (status IN ('generating', 'failed') AND result_json IS NULL)
  )
);

CREATE INDEX IF NOT EXISTS web_app_generations_owner_recent ON web_app_generations (owner_subject, created_at);
CREATE INDEX IF NOT EXISTS web_app_generations_recent ON web_app_generations (created_at);
