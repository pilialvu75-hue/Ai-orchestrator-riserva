CREATE TABLE IF NOT EXISTS web_counter_artifacts (
  storage_key TEXT PRIMARY KEY NOT NULL,
  zip_bytes BLOB NOT NULL
    CHECK (typeof(zip_bytes) = 'blob' AND length(zip_bytes) BETWEEN 1 AND 65536)
);
