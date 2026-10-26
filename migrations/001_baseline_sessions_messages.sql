-- context-harness:v1
-- 001 baseline: makes a FRESH database work. On an existing Day 4 database every
-- statement is a no-op (CREATE TABLE IF NOT EXISTS) - no data is touched.
CREATE TABLE IF NOT EXISTS sessions (
  id          uuid PRIMARY KEY,
  user_id     text        NOT NULL DEFAULT 'anonymous',
  agent_name  text        NOT NULL DEFAULT 'general-assistant',
  metadata    jsonb       NOT NULL DEFAULT '{}'::jsonb,
  status      text        NOT NULL DEFAULT 'active',
  created_at  timestamptz NOT NULL DEFAULT now(),
  updated_at  timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS messages (
  id          uuid PRIMARY KEY,
  session_id  uuid        NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
  role        text        NOT NULL,
  content     text        NOT NULL,
  metadata    jsonb       NOT NULL DEFAULT '{}'::jsonb,
  created_at  timestamptz NOT NULL DEFAULT now()
);
