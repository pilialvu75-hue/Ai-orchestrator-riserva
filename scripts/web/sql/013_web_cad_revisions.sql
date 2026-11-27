CREATE TABLE web_cad_revisions (
  owner_subject TEXT NOT NULL,
  project_id TEXT NOT NULL,
  revision_id TEXT NOT NULL,
  base_revision_id TEXT,
  revision_number INTEGER NOT NULL CHECK(revision_number >= 1),
  manifest_json TEXT NOT NULL CHECK(length(manifest_json) BETWEEN 2 AND 4096),
  scad_bytes BLOB NOT NULL CHECK(typeof(scad_bytes) = 'blob' AND length(scad_bytes) BETWEEN 1 AND 65536),
  stl_bytes BLOB NOT NULL CHECK(typeof(stl_bytes) = 'blob' AND length(stl_bytes) BETWEEN 1 AND 65536),
  PRIMARY KEY (owner_subject, project_id, revision_id),
  UNIQUE (owner_subject, project_id, revision_number),
  FOREIGN KEY (owner_subject, project_id, base_revision_id)
    REFERENCES web_cad_revisions(owner_subject, project_id, revision_id),
  CHECK ((revision_number = 1 AND base_revision_id IS NULL) OR
         (revision_number > 1 AND base_revision_id IS NOT NULL))
);

CREATE TABLE web_cad_project_selection (
  owner_subject TEXT NOT NULL,
  project_id TEXT NOT NULL,
  revision_id TEXT NOT NULL,
  PRIMARY KEY (owner_subject, project_id),
  FOREIGN KEY (owner_subject, project_id, revision_id)
    REFERENCES web_cad_revisions(owner_subject, project_id, revision_id)
);
