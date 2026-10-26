-- context-harness:v1
-- 003 Level 2 (project context) + Level 3 (long-term memory): FOUNDATION ONLY.
-- Minimal tables so IDs, relationships, versioning and migration strategy exist.
-- NO API, NO retrieval, NO ranking, NO embeddings are built on top of them yet.

DO $$
BEGIN
  -- gen_random_uuid() is built in from PostgreSQL 13; older servers need pgcrypto
  IF current_setting('server_version_num')::int < 130000 THEN
    BEGIN
      CREATE EXTENSION IF NOT EXISTS pgcrypto;
    EXCEPTION WHEN OTHERS THEN
      RAISE NOTICE 'pgcrypto unavailable (%): new tables need explicit ids', SQLERRM;
    END;
  END IF;
END $$;

-- ---- LEVEL 2: "What are we currently building?" ---------------------------------------
CREATE TABLE IF NOT EXISTS projects (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  name        text        NOT NULL,
  description text,
  status      text        NOT NULL DEFAULT 'active',
  owner_id    text,
  metadata    jsonb       NOT NULL DEFAULT '{}'::jsonb,
  created_at  timestamptz NOT NULL DEFAULT now(),
  updated_at  timestamptz NOT NULL DEFAULT now()
);

-- Versioned, typed project context. Future context_type values (not enforced yet):
--   state | artifact | decision | summary
-- (project_state / project_artifact / project_decision become rows here, not new tables,
--  until a real access pattern justifies splitting them.)
CREATE TABLE IF NOT EXISTS project_context (
  id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  project_id   uuid        NOT NULL REFERENCES projects(id) ON DELETE CASCADE,
  context_type text        NOT NULL,
  version      integer     NOT NULL DEFAULT 1 CHECK (version >= 1),
  content      jsonb       NOT NULL DEFAULT '{}'::jsonb,
  metadata     jsonb       NOT NULL DEFAULT '{}'::jsonb,
  created_at   timestamptz NOT NULL DEFAULT now(),
  UNIQUE (project_id, context_type, version)
);

-- a chat may (later) belong to a project; nullable => zero impact on Level 1
ALTER TABLE sessions ADD COLUMN IF NOT EXISTS project_id uuid REFERENCES projects(id) ON DELETE SET NULL;
CREATE INDEX IF NOT EXISTS sessions_project_idx ON sessions (project_id) WHERE project_id IS NOT NULL;

-- ---- LEVEL 3: "What should persist across chats?" -------------------------------------
CREATE TABLE IF NOT EXISTS memories (
  id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  memory_type       text        NOT NULL CHECK (memory_type IN
                      ('preference','fact','constraint','decision','project_context',
                       'technical_environment','workflow','instruction','summary')),
  content           text        NOT NULL,
  source            text        NOT NULL DEFAULT 'unknown',
  confidence        numeric(4,3) CHECK (confidence IS NULL OR (confidence >= 0 AND confidence <= 1)),
  importance        numeric(4,3) CHECK (importance IS NULL OR (importance >= 0 AND importance <= 1)),
  owner_id          text,
  project_id        uuid REFERENCES projects(id) ON DELETE SET NULL,
  metadata          jsonb       NOT NULL DEFAULT '{}'::jsonb,
  created_at        timestamptz NOT NULL DEFAULT now(),
  updated_at        timestamptz NOT NULL DEFAULT now(),
  last_confirmed_at timestamptz
);
CREATE INDEX IF NOT EXISTS memories_owner_type_idx ON memories (owner_id, memory_type);

COMMENT ON COLUMN memories.confidence IS
  'NULL = not evaluated. Must be derived from EVIDENCE (source, confirmation, repeated observation, contradiction, verification). NEVER from model temperature - temperature is a generation parameter, not a truth signal.';
COMMENT ON TABLE memories IS 'Level 3 foundation only. Not read or written by any Day 4 endpoint yet.';
COMMENT ON TABLE project_context IS 'Level 2 foundation only. Not read or written by any Day 4 endpoint yet.';
