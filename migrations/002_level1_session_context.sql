-- context-harness:v1
-- 002 Level 1 - deterministic message ordering + integrity. ADDITIVE ONLY.
--   * messages.seq        : monotonically increasing ordering key (tie-breaker for created_at)
--   * unique (session_id, seq) : serves "newest N for a session" via a backward index scan
--   * role CHECK / FK     : added NOT VALID so legacy rows can never make the migration fail;
--                           they are enforced for every NEW row.
-- The whole file runs in one transaction (see src/migrate.js).

-- block writers while we backfill so no NULL seq can appear (brief; table is small)
LOCK TABLE messages IN SHARE ROW EXCLUSIVE MODE;

-- json -> jsonb where an older deployment used plain json (lossless)
DO $$
BEGIN
  IF (SELECT data_type FROM information_schema.columns
        WHERE table_schema = current_schema() AND table_name = 'messages' AND column_name = 'metadata') = 'json' THEN
    ALTER TABLE messages ALTER COLUMN metadata TYPE jsonb USING metadata::jsonb;
  END IF;
  IF (SELECT data_type FROM information_schema.columns
        WHERE table_schema = current_schema() AND table_name = 'sessions' AND column_name = 'metadata') = 'json' THEN
    ALTER TABLE sessions ALTER COLUMN metadata TYPE jsonb USING metadata::jsonb;
  END IF;
END $$;

CREATE SEQUENCE IF NOT EXISTS messages_seq_seq;
ALTER TABLE messages ADD COLUMN IF NOT EXISTS seq bigint;

-- backfill existing rows in their historical order (created_at, then id as a stable tie-break)
UPDATE messages m
   SET seq = r.rn + b.base
  FROM (SELECT id, row_number() OVER (ORDER BY created_at, id::text) AS rn
          FROM messages WHERE seq IS NULL) r,
       (SELECT COALESCE(MAX(seq), 0) AS base FROM messages) b
 WHERE m.id = r.id;

SELECT setval('messages_seq_seq',
              GREATEST((SELECT COALESCE(MAX(seq), 0) FROM messages), 1),
              (SELECT COALESCE(MAX(seq), 0) FROM messages) > 0);

ALTER TABLE messages ALTER COLUMN seq SET DEFAULT nextval('messages_seq_seq');
ALTER TABLE messages ALTER COLUMN seq SET NOT NULL;
ALTER SEQUENCE messages_seq_seq OWNED BY messages.seq;

CREATE UNIQUE INDEX IF NOT EXISTS messages_session_seq_uidx ON messages (session_id, seq);

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint
                  WHERE conname = 'messages_role_check' AND conrelid = 'messages'::regclass) THEN
    ALTER TABLE messages
      ADD CONSTRAINT messages_role_check
      CHECK (role IN ('system', 'user', 'assistant', 'tool')) NOT VALID;
  END IF;

  -- FK only when column types are compatible and sessions.id is unique (never fail the migration)
  IF NOT EXISTS (SELECT 1 FROM pg_constraint
                  WHERE contype = 'f' AND conrelid = 'messages'::regclass AND confrelid = 'sessions'::regclass)
     AND (SELECT format_type(atttypid, atttypmod) FROM pg_attribute
           WHERE attrelid = 'messages'::regclass AND attname = 'session_id')
       = (SELECT format_type(atttypid, atttypmod) FROM pg_attribute
           WHERE attrelid = 'sessions'::regclass AND attname = 'id')
     AND EXISTS (SELECT 1 FROM pg_index i
                  WHERE i.indrelid = 'sessions'::regclass AND i.indisunique AND i.indnatts = 1
                    AND i.indkey[0] = (SELECT attnum FROM pg_attribute
                                        WHERE attrelid = 'sessions'::regclass AND attname = 'id')) THEN
    ALTER TABLE messages
      ADD CONSTRAINT messages_session_fk
      FOREIGN KEY (session_id) REFERENCES sessions(id) ON DELETE CASCADE NOT VALID;
  END IF;
END $$;
