ALTER TABLE web_app_generations ADD COLUMN project_id TEXT;
ALTER TABLE web_app_generations ADD COLUMN base_generation_id TEXT;
ALTER TABLE web_app_generations ADD COLUMN revision_instruction TEXT;
ALTER TABLE web_app_generations ADD COLUMN revision_number INTEGER NOT NULL DEFAULT 1 CHECK(revision_number > 0);

CREATE INDEX web_app_generations_project_order ON web_app_generations
  (owner_subject, project_id, created_at DESC, generation_id DESC);

CREATE TABLE web_app_project_selection (
  owner_subject TEXT NOT NULL,
  project_id TEXT NOT NULL,
  generation_id TEXT NOT NULL,
  PRIMARY KEY (owner_subject, project_id),
  FOREIGN KEY (owner_subject, project_id) REFERENCES web_app_generations(owner_subject, generation_id),
  FOREIGN KEY (owner_subject, generation_id) REFERENCES web_app_generations(owner_subject, generation_id)
);
