CREATE TABLE web_app_records (
  owner_subject TEXT NOT NULL,
  project_id TEXT NOT NULL,
  collection_name TEXT NOT NULL,
  record_id TEXT NOT NULL,
  record_version INTEGER NOT NULL CHECK(record_version > 0),
  data_json TEXT NOT NULL CHECK(length(data_json) <= 16384),
  updated_at INTEGER NOT NULL DEFAULT (unixepoch()),
  PRIMARY KEY (owner_subject, project_id, collection_name, record_id),
  FOREIGN KEY (owner_subject, project_id) REFERENCES web_app_generations(owner_subject, generation_id)
);
