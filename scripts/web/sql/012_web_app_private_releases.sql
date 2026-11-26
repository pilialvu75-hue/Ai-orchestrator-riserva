CREATE TABLE web_app_release_events (
  release_id TEXT NOT NULL,
  revision INTEGER NOT NULL CHECK(revision > 0),
  project_owner TEXT NOT NULL,
  project_id TEXT NOT NULL,
  generation_id TEXT NOT NULL,
  action TEXT NOT NULL CHECK(action IN ('publish', 'rollback')),
  created_at INTEGER NOT NULL DEFAULT (unixepoch()),
  PRIMARY KEY (release_id, revision),
  UNIQUE (project_owner, project_id, revision),
  FOREIGN KEY (project_owner, project_id) REFERENCES web_app_generations(owner_subject, generation_id),
  FOREIGN KEY (project_owner, generation_id) REFERENCES web_app_generations(owner_subject, generation_id)
);
