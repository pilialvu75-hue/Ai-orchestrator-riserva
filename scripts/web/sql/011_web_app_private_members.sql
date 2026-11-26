CREATE TABLE web_app_invites (
  token_sha256 TEXT PRIMARY KEY NOT NULL CHECK(length(token_sha256) = 64),
  project_owner TEXT NOT NULL,
  project_id TEXT NOT NULL,
  generation_id TEXT NOT NULL,
  expires_at INTEGER NOT NULL,
  member_subject TEXT,
  FOREIGN KEY (project_owner, project_id) REFERENCES web_app_generations(owner_subject, generation_id),
  FOREIGN KEY (project_owner, generation_id) REFERENCES web_app_generations(owner_subject, generation_id)
);

CREATE INDEX web_app_membership_scope ON web_app_invites (member_subject, project_owner, project_id);
CREATE INDEX web_app_generations_member_lookup ON web_app_generations (generation_id, owner_subject, project_id);

CREATE TABLE web_app_scoped_records (
  project_owner TEXT NOT NULL,
  project_id TEXT NOT NULL,
  user_subject TEXT NOT NULL,
  collection_name TEXT NOT NULL,
  record_id TEXT NOT NULL,
  record_version INTEGER NOT NULL CHECK(record_version > 0),
  data_json TEXT NOT NULL CHECK(length(data_json) <= 16384),
  updated_at INTEGER NOT NULL DEFAULT (unixepoch()),
  PRIMARY KEY (project_owner, project_id, user_subject, collection_name, record_id),
  FOREIGN KEY (project_owner, project_id) REFERENCES web_app_generations(owner_subject, generation_id)
);

INSERT INTO web_app_scoped_records (project_owner, project_id, user_subject, collection_name, record_id, record_version, data_json, updated_at)
SELECT owner_subject, project_id, owner_subject, collection_name, record_id, record_version, data_json, updated_at
FROM web_app_records;

DROP TABLE web_app_records;
ALTER TABLE web_app_scoped_records RENAME TO web_app_records;
