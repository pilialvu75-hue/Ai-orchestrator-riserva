CREATE TABLE IF NOT EXISTS web_counter_dispatch (
  execution_id TEXT PRIMARY KEY NOT NULL
    REFERENCES web_execution_reservations(execution_id),
  ticket TEXT NOT NULL UNIQUE,
  head_sha TEXT NOT NULL CHECK(length(head_sha) = 40 AND head_sha NOT GLOB '*[^0-9a-f]*'),
  state TEXT NOT NULL CHECK(state IN ('dispatching', 'submitted', 'review_required')),
  github_run_id INTEGER UNIQUE,
  CHECK (
    (state = 'submitted' AND github_run_id IS NOT NULL AND github_run_id > 0) OR
    (state IN ('dispatching', 'review_required') AND github_run_id IS NULL)
  )
);
