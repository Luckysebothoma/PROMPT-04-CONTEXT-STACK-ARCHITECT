#!/usr/bin/env bash
# =============================================================================
# patch-context-harness.sh
# Day 4 (context / session)  ->  CONTEXT HARNESS  (Level 1 full, Level 2/3 foundation)
#
# Safe by default: never commits, never pushes, never deploys, never touches .env.
# Idempotent: re-running detects already-applied content and reports "unchanged".
# Every file that is replaced is backed up first; every write is atomic (temp + mv).
#
# Usage:  ./patch-context-harness.sh [options]      (see --help)
# =============================================================================
set -Eeuo pipefail

SCRIPT_VERSION="1.0.0"
MARKER="context-harness:v1"
EXPECTED_PKG_NAME="ai-gateway-4-of-10-context-session"
DEFAULT_REPO="/ai-gatway/ai-gateway-10d-prompt/ai-gateway-4-of-10-context-session"
NODE_IMAGE="node:20-alpine"

REPO=""
DRY_RUN=0
DO_TEST=0
TEST_ONLY=0
DO_VERIFY=1
DO_BACKUP=1
DO_MIGRATE=0
MIGRATE_STATUS=0
DO_DOCKER_BUILD=0
SHOW_DIFF=0
FORCE=0
TEST_MODE="auto"          # auto | host | docker
NODE_MODE=""              # host | docker (resolved later)
CHANGED=()
UNCHANGED=()
SKIPPED=()
BACKUP_DIR=""

if [[ -t 1 ]]; then C_G=$'\033[32m'; C_Y=$'\033[33m'; C_R=$'\033[31m'; C_B=$'\033[1m'; C_0=$'\033[0m'
else C_G=""; C_Y=""; C_R=""; C_B=""; C_0=""; fi
log()  { printf '%s\n' "$*"; }
ok()   { printf '%s[ok]%s   %s\n' "$C_G" "$C_0" "$*"; }
warn() { printf '%s[warn]%s %s\n' "$C_Y" "$C_0" "$*" >&2; }
die()  { printf '%s[fail]%s %s\n' "$C_R" "$C_0" "$*" >&2; exit 1; }
step() { printf '\n%s== %s ==%s\n' "$C_B" "$*" "$C_0"; }
trap 'printf "%s[fail]%s line %s: %s\n" "$C_R" "$C_0" "$LINENO" "$BASH_COMMAND" >&2' ERR

usage() {
cat <<'__CH_EOF__'
patch-context-harness.sh - upgrade Day 4 into the Context Harness (Level 1 implemented)

Usage: patch-context-harness.sh [options]

Repo selection:
  --repo DIR          Day 4 repo directory. Default: $PWD if it is the Day 4 repo,
                      else /ai-gatway/ai-gateway-10d-prompt/ai-gateway-4-of-10-context-session

Actions (default = patch + verify; nothing else touches the database or Docker):
  --dry-run           Show what would change; write nothing, touch no DB.
  --test              After patching, run the test suite (real PostgreSQL, isolated
                      throw-away schema; production tables are never touched).
  --test-only         Skip patching, only run the test suite.
  --verify            Syntax/JSON/compose verification (default ON after patching).
  --no-verify         Skip verification.
  --migrate           Apply pending DB migrations now using DATABASE_URL from .env
                      (additive, transactional, advisory-locked). The service also runs
                      them on boot unless MIGRATE_ON_BOOT=false.
  --migrate-status    List applied / pending migrations (read-only).
  --docker-build      Validate the image builds (docker build, no push, no run).
  --test-mode MODE    auto (default) | host | docker. 'auto' uses the host if the DB from
                      .env is reachable from it, otherwise runs inside a throw-away
                      node container attached to ai-gateway-net / databases.
  --backup            Create backups of replaced files (default ON).
  --no-backup         Do not create backups (not recommended).
  --diff              Print the full 'git diff' at the end (default: git status + --stat).
  --force             Continue even if the repo is not recognised / not a git repo.
  --help              This help.

Never done automatically: git commit, git push, docker compose up, editing .env.
Backups: <repo>/.context-harness-backup/<timestamp>/  (excluded from git via .git/info/exclude)
__CH_EOF__
}

# ------------------------------------------------------------------ arguments
while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo)            [[ $# -ge 2 ]] || die "--repo needs a value"; REPO="$2"; shift 2;;
    --dry-run)         DRY_RUN=1; shift;;
    --test)            DO_TEST=1; shift;;
    --test-only)       TEST_ONLY=1; DO_TEST=1; shift;;
    --verify)          DO_VERIFY=1; shift;;
    --no-verify)       DO_VERIFY=0; shift;;
    --migrate)         DO_MIGRATE=1; shift;;
    --migrate-status)  MIGRATE_STATUS=1; shift;;
    --docker-build)    DO_DOCKER_BUILD=1; shift;;
    --test-mode)       [[ $# -ge 2 ]] || die "--test-mode needs a value"; TEST_MODE="$2"; shift 2;;
    --backup)          DO_BACKUP=1; shift;;
    --no-backup)       DO_BACKUP=0; shift;;
    --diff)            SHOW_DIFF=1; shift;;
    --force)           FORCE=1; shift;;
    -h|--help)         usage; exit 0;;
    *) usage >&2; die "unknown option: $1";;
  esac
done
case "$TEST_MODE" in auto|host|docker) ;; *) die "--test-mode must be auto|host|docker";; esac

# ------------------------------------------------------------------ repo detection
detect_repo() {
  if [[ -z "$REPO" ]]; then
    if [[ -f package.json ]] && grep -q "\"$EXPECTED_PKG_NAME\"" package.json; then REPO="$PWD"
    elif [[ -d "$DEFAULT_REPO" ]]; then REPO="$DEFAULT_REPO"
    else die "cannot locate the Day 4 repo. Use --repo DIR (looked in \$PWD and $DEFAULT_REPO)"; fi
  fi
  [[ -d "$REPO" ]] || die "repo directory not found: $REPO"
  REPO="$(cd "$REPO" && pwd)"
}

preflight() {
  step "Preflight (read-only)"
  log "repo: $REPO"
  [[ -f "$REPO/package.json" ]]  || die "package.json missing"
  [[ -f "$REPO/src/index.js" ]]  || die "src/index.js missing"
  [[ -f "$REPO/Dockerfile" ]]    || die "Dockerfile missing"
  if ! grep -q "\"$EXPECTED_PKG_NAME\"" "$REPO/package.json"; then
    [[ $FORCE -eq 1 ]] && warn "package name is not $EXPECTED_PKG_NAME (continuing: --force)" \
      || die "package.json name is not $EXPECTED_PKG_NAME - is this the Day 4 repo? (--force to override)"
  fi
  if ! grep -q "$MARKER" "$REPO/src/index.js" && ! grep -q "$EXPECTED_PKG_NAME" "$REPO/src/index.js"; then
    [[ $FORCE -eq 1 ]] && warn "src/index.js not recognised (continuing: --force)" \
      || die "src/index.js is neither the original Day 4 file nor an already-patched one (--force to override)"
  fi
  if git -C "$REPO" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    local br dirty
    br="$(git -C "$REPO" branch --show-current 2>/dev/null || true)"
    dirty="$(git -C "$REPO" status --porcelain | wc -l | tr -d ' ')"
    ok "git repository, branch: ${br:-detached}, uncommitted paths: $dirty"
    [[ "$dirty" != "0" ]] && warn "working tree is not clean - backups will be taken; nothing is committed"
    git -C "$REPO" remote -v 2>/dev/null | sed 's/^/       /' || true
  else
    [[ $FORCE -eq 1 ]] && warn "not a git repository (continuing: --force)" || die "not a git repository (--force to override)"
  fi
  [[ -f "$REPO/.env" ]] && ok ".env present (never modified by this script)" || warn ".env not found - DB-backed steps (--test/--migrate) need DATABASE_URL"
  [[ -f "$REPO/docker-compose.yml" ]] && ok "docker-compose.yml present (not modified)"
}

# ------------------------------------------------------------------ node helpers
node_ok_on_host() {
  command -v node >/dev/null 2>&1 && command -v npm >/dev/null 2>&1 || return 1
  local major; major="$(node -p 'process.versions.node.split(".")[0]' 2>/dev/null || echo 0)"
  [[ "$major" -ge 18 ]]
}
resolve_node_mode() {
  [[ -n "$NODE_MODE" ]] && return 0
  if node_ok_on_host; then NODE_MODE="host"
  elif command -v docker >/dev/null 2>&1; then NODE_MODE="docker"; warn "node >= 18 not found on host; using $NODE_IMAGE via docker for node tasks"
  else die "need node >= 18 (with npm) or docker"; fi
}
# run_node <args...>   - runs `node <args>` with cwd = repo (stdin passes through)
run_node() {
  resolve_node_mode
  if [[ "$NODE_MODE" == "host" ]]; then ( cd "$REPO" && node "$@" )
  else docker run --rm -i -v "$REPO":/app -w /app "$NODE_IMAGE" node "$@"; fi
}

# ------------------------------------------------------------------ atomic file writer
init_backup() {
  [[ $DRY_RUN -eq 1 || $DO_BACKUP -eq 0 ]] && return 0
  BACKUP_DIR="$REPO/.context-harness-backup/$(date +%Y%m%d-%H%M%S)"
  if [[ -d "$REPO/.git" ]] && ! grep -qs '^\.context-harness-backup/' "$REPO/.git/info/exclude" 2>/dev/null; then
    mkdir -p "$REPO/.git/info"; printf '.context-harness-backup/\n' >> "$REPO/.git/info/exclude"
  fi
}
backup_file() {
  local rel="$1"
  [[ $DO_BACKUP -eq 1 && -f "$REPO/$rel" ]] || return 0
  mkdir -p "$BACKUP_DIR/$(dirname "$rel")"
  cp -p "$REPO/$rel" "$BACKUP_DIR/$rel"
}

# write_file <relpath> [replace|managed]   (new content on stdin)
#   replace : overwrite (after backup) - used for files this patch owns/replaces
#   managed : only overwrite if it already carries our marker or is a stub (<=5 lines);
#             never clobbers user-owned content
write_file() {
  local rel="$1" mode="${2:-replace}" target="$REPO/$1" tmp stage action
  tmp="$(mktemp "${TMPDIR:-/tmp}/ch.XXXXXX")"
  cat >"$tmp"
  if [[ -f "$target" ]]; then
    if cmp -s "$tmp" "$target"; then UNCHANGED+=("$rel"); log "  unchanged  $rel"; rm -f "$tmp"; return 0; fi
    if [[ "$mode" == "managed" ]] && ! grep -q "$MARKER" "$target" && [[ "$(wc -l <"$target")" -gt 5 ]]; then
      SKIPPED+=("$rel"); warn "skip (user-owned, not overwritten): $rel"; rm -f "$tmp"; return 0
    fi
    action="update"
  else action="create"; fi
  if [[ $DRY_RUN -eq 1 ]]; then log "  would $action $rel"; CHANGED+=("$rel"); rm -f "$tmp"; return 0; fi
  backup_file "$rel"
  mkdir -p "$(dirname "$target")"
  stage="${target}.ch-new.$$"
  cp "$tmp" "$stage"; chmod 0644 "$stage"
  mv -f "$stage" "$target"             # atomic on the same filesystem
  rm -f "$tmp"
  CHANGED+=("$rel"); log "  ${action}d    $rel"
}

# =============================================================================
# PATCH CONTENT
# =============================================================================
patch_all() {
  step "Patching Day 4 -> Context Harness (Level 1)"
  init_backup

  # ---------------------------------------------------------------- migrations
  write_file migrations/001_baseline_sessions_messages.sql <<'__CH_EOF__'
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
__CH_EOF__

  write_file migrations/002_level1_session_context.sql <<'__CH_EOF__'
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
__CH_EOF__

  write_file migrations/003_level2_level3_foundations.sql <<'__CH_EOF__'
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
__CH_EOF__

  # ---------------------------------------------------------------- source
  write_file src/config.js <<'__CH_EOF__'
// context-harness:v1 (generated by patch-context-harness.sh)
'use strict';

const SERVICE_NAME = 'ai-gateway-4-of-10-context-session';
const SERVICE_VERSION = '0.2.0';
const CONTEXT_VERSION = 1; // v1 = session messages. v2 = +summary, v3 = +project, v4 = +memory (future)
const ROLES = Object.freeze(['system', 'user', 'assistant', 'tool']);

// Empty string counts as "unset": docker-compose passes ${VAR} through as '' when .env lacks it.
function isUnset(v) {
  return v === undefined || v === null || String(v).trim() === '';
}

function intVar(env, name, def, min, max) {
  const raw = env[name];
  if (isUnset(raw)) return def;
  const s = String(raw).trim();
  if (!/^-?\d+$/.test(s)) throw new Error(name + ' must be an integer (got "' + raw + '")');
  const n = parseInt(s, 10);
  if (n < min || n > max) throw new Error(name + ' must be between ' + min + ' and ' + max + ' (got ' + n + ')');
  return n;
}

function boolVar(env, name, def) {
  const raw = env[name];
  if (isUnset(raw)) return def;
  const s = String(raw).trim().toLowerCase();
  if (['1', 'true', 'yes', 'on'].includes(s)) return true;
  if (['0', 'false', 'no', 'off'].includes(s)) return false;
  throw new Error(name + ' must be a boolean (got "' + raw + '")');
}

function loadConfig(env) {
  env = env || process.env;
  const contextHardMax = intVar(env, 'CONTEXT_MAX_MESSAGES_HARD', 500, 1, 5000);
  const cfg = {
    port: intVar(env, 'PORT', 8080, 1, 65535),
    host: isUnset(env.HOST) ? '0.0.0.0' : env.HOST,
    databaseUrl: env.DATABASE_URL,
    redisUrl: isUnset(env.REDIS_URL) ? undefined : env.REDIS_URL,
    stack3Url: isUnset(env.STACK3_URL) ? 'http://192.168.0.140:4405' : env.STACK3_URL,
    requestTimeoutMs: intVar(env, 'REQUEST_TIMEOUT_MS', 15000, 100, 300000),
    depTimeoutMs: intVar(env, 'DEP_TIMEOUT_MS', 2000, 100, 60000),
    contextMaxMessages: intVar(env, 'CONTEXT_MAX_MESSAGES', 20, 1, 5000),
    contextHardMax,
    messageMaxChars: intVar(env, 'MESSAGE_MAX_CHARS', 100000, 1, 5000000),
    dbPoolMax: intVar(env, 'DB_POOL_MAX', 10, 1, 200),
    migrateOnBoot: boolVar(env, 'MIGRATE_ON_BOOT', true),
    redisRequired: boolVar(env, 'REDIS_REQUIRED', false),
    chatLegacyEnabled: boolVar(env, 'CHAT_LEGACY_ENABLED', true),
    searchPath: undefined // tests only: isolate into a throw-away schema
  };
  if (cfg.contextMaxMessages > cfg.contextHardMax) {
    throw new Error('CONTEXT_MAX_MESSAGES (' + cfg.contextMaxMessages + ') exceeds CONTEXT_MAX_MESSAGES_HARD (' + cfg.contextHardMax + ')');
  }
  return cfg;
}

module.exports = { loadConfig, ROLES, CONTEXT_VERSION, SERVICE_NAME, SERVICE_VERSION };
__CH_EOF__

  write_file src/load-env.js <<'__CH_EOF__'
// context-harness:v1 (generated by patch-context-harness.sh)
// Tiny .env reader for host-side tooling (migrate CLI, tests). The service itself gets its
// environment from docker-compose. Never overrides variables that are already set.
'use strict';
const fs = require('fs');
const path = require('path');

function parseEnv(text) {
  const out = {};
  for (let line of String(text).split(/\r?\n/)) {
    line = line.trim();
    if (!line || line.startsWith('#')) continue;
    if (line.startsWith('export ')) line = line.slice(7);
    const i = line.indexOf('=');
    if (i < 1) continue;
    const key = line.slice(0, i).trim();
    let val = line.slice(i + 1).trim();
    if ((val.startsWith('"') && val.endsWith('"')) || (val.startsWith("'") && val.endsWith("'"))) {
      val = val.slice(1, -1);
    } else {
      const h = val.search(/\s#/);
      if (h >= 0) val = val.slice(0, h).trim();
    }
    out[key] = val;
  }
  // compose-style ${VAR} / ${VAR:-default} interpolation (single pass)
  for (const k of Object.keys(out)) {
    out[k] = out[k].replace(/\$\{([A-Za-z_][A-Za-z0-9_]*)(?::-([^}]*))?\}/g, (_, name, def) => {
      const v = out[name] !== undefined ? out[name] : process.env[name];
      return v !== undefined && v !== '' ? v : (def || '');
    });
  }
  return out;
}

function loadDotEnv(file) {
  file = file || path.join(__dirname, '..', '.env');
  let text;
  try { text = fs.readFileSync(file, 'utf8'); } catch (e) { return {}; }
  const parsed = parseEnv(text);
  for (const k of Object.keys(parsed)) {
    if (process.env[k] === undefined) process.env[k] = parsed[k];
  }
  return parsed;
}

module.exports = { loadDotEnv, parseEnv };
__CH_EOF__

  write_file src/db.js <<'__CH_EOF__'
// context-harness:v1 (generated by patch-context-harness.sh)
'use strict';
const { Pool } = require('pg');

function createPool(cfg) {
  const pool = new Pool({
    connectionString: cfg.databaseUrl,
    max: cfg.dbPoolMax,
    connectionTimeoutMillis: Math.min(cfg.requestTimeoutMs, 5000),
    // native, server-side protection: no query can hang the pool forever
    statement_timeout: cfg.requestTimeoutMs,
    query_timeout: cfg.requestTimeoutMs + 1000,
    idle_in_transaction_session_timeout: cfg.requestTimeoutMs * 2
  });
  pool.on('error', () => { /* idle client errors must not crash the process */ });
  if (cfg.searchPath) {
    // tests: queue SET before any user query on each new connection
    pool.on('connect', (c) => { c.query('SET search_path TO ' + cfg.searchPath).catch(() => {}); });
  }
  return pool;
}

// One real transaction: COMMIT if fn resolves, ROLLBACK if it throws.
async function withTx(pool, fn) {
  const c = await pool.connect();
  let broken = false;
  try {
    await c.query('BEGIN');
    const out = await fn(c);
    await c.query('COMMIT');
    return out;
  } catch (e) {
    try { await c.query('ROLLBACK'); } catch (rb) { broken = true; }
    throw e;
  } finally {
    c.release(broken);
  }
}

function withTimeout(promise, ms, label) {
  let timer;
  const timeout = new Promise((_, reject) => {
    timer = setTimeout(() => {
      const err = new Error((label || 'operation') + ' timed out after ' + ms + 'ms');
      err.code = 'APP_TIMEOUT';
      reject(err);
    }, ms);
  });
  return Promise.race([promise, timeout]).finally(() => clearTimeout(timer));
}

module.exports = { createPool, withTx, withTimeout };
__CH_EOF__

  write_file src/migrate.js <<'__CH_EOF__'
// context-harness:v1 (generated by patch-context-harness.sh)
// Forward-only, additive SQL migrations. Applied files are recorded (with checksum) in
// context_harness_migrations and NEVER re-applied or rewritten. Serialised by an advisory
// lock so parallel container starts are safe.
'use strict';
const fs = require('fs');
const path = require('path');
const crypto = require('crypto');

const LOCK_KEY = 44060001;
const TABLE = 'context_harness_migrations';
const DEFAULT_DIR = path.join(__dirname, '..', 'migrations');

function listMigrations(dir) {
  return fs.readdirSync(dir).filter((f) => /^\d+_.+\.sql$/.test(f)).sort();
}

async function runMigrations(pool, opts) {
  opts = opts || {};
  const dir = opts.dir || DEFAULT_DIR;
  const log = opts.log || (() => {});
  const c = await pool.connect();
  const applied = [];
  const skipped = [];
  try {
    await c.query('SET statement_timeout = 0'); // backfills may exceed the request timeout
    await c.query('SELECT pg_advisory_lock($1)', [LOCK_KEY]);
    await c.query('CREATE TABLE IF NOT EXISTS ' + TABLE +
      ' (filename text PRIMARY KEY, checksum text NOT NULL, applied_at timestamptz NOT NULL DEFAULT now())');
    const done = new Map((await c.query('SELECT filename, checksum FROM ' + TABLE)).rows.map((r) => [r.filename, r.checksum]));
    for (const file of listMigrations(dir)) {
      const sql = fs.readFileSync(path.join(dir, file), 'utf8');
      const sum = crypto.createHash('sha256').update(sql).digest('hex');
      if (done.has(file)) {
        if (done.get(file) !== sum) log({ level: 'warn', msg: 'migration file changed after being applied (ignored)', file });
        skipped.push(file);
        continue;
      }
      try {
        await c.query('BEGIN');
        await c.query(sql);
        await c.query('INSERT INTO ' + TABLE + ' (filename, checksum) VALUES ($1, $2)', [file, sum]);
        await c.query('COMMIT');
      } catch (e) {
        try { await c.query('ROLLBACK'); } catch (rb) { /* ignore */ }
        e.message = 'migration ' + file + ' failed: ' + e.message;
        throw e;
      }
      applied.push(file);
      log({ level: 'info', msg: 'migration applied', file });
    }
    return { applied, skipped };
  } finally {
    try { await c.query('SELECT pg_advisory_unlock($1)', [LOCK_KEY]); } catch (e) { /* ignore */ }
    try { await c.query('RESET statement_timeout'); } catch (e) { /* ignore */ }
    c.release();
  }
}

async function migrationStatus(pool, dir) {
  dir = dir || DEFAULT_DIR;
  const exists = (await pool.query('SELECT to_regclass($1) AS t', [TABLE])).rows[0].t;
  const done = new Set();
  if (exists) (await pool.query('SELECT filename FROM ' + TABLE)).rows.forEach((r) => done.add(r.filename));
  return listMigrations(dir).map((f) => ({ file: f, applied: done.has(f) }));
}

module.exports = { runMigrations, migrationStatus, listMigrations };

if (require.main === module) {
  require('./load-env').loadDotEnv();
  const { loadConfig } = require('./config');
  const { createPool } = require('./db');
  (async () => {
    const cfg = loadConfig();
    if (!cfg.databaseUrl) throw new Error('DATABASE_URL is not set');
    const pool = createPool(cfg);
    try {
      if (process.argv.includes('--status')) {
        (await migrationStatus(pool)).forEach((m) => console.log((m.applied ? 'applied  ' : 'PENDING  ') + m.file));
      } else {
        const r = await runMigrations(pool, { log: (o) => console.log(JSON.stringify(o)) });
        console.log('applied: ' + (r.applied.join(', ') || '(none - already up to date)'));
      }
    } finally {
      await pool.end();
    }
  })().catch((e) => { console.error('migrate failed: ' + e.message); process.exit(1); });
}
__CH_EOF__

  write_file src/app.js <<'__CH_EOF__'
// context-harness:v1 (generated by patch-context-harness.sh)
// Day 4 - CONTEXT HARNESS. Level 1 (session context) implemented; Levels 2/3 are schema-only.
// Day 4 owns session + conversation history + context assembly. It does NOT pick models
// (Day 3) and does NOT orchestrate (Day 5).
'use strict';
const express = require('express');
const crypto = require('crypto');
const client = require('prom-client');
const { ROLES, CONTEXT_VERSION, SERVICE_NAME, SERVICE_VERSION } = require('./config');
const { withTx, withTimeout } = require('./db');

const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const MAX_METADATA_BYTES = 64 * 1024;

class HttpError extends Error {
  constructor(status, code, message) { super(message); this.status = status; this.code = code; }
}
const bad = (m) => new HttpError(400, 'INVALID_REQUEST', m);

function defaultLog(obj) {
  try { console.log(JSON.stringify(Object.assign({ ts: new Date().toISOString(), service: SERVICE_NAME }, obj))); } catch (e) { /* ignore */ }
}
const genId = () => crypto.randomUUID();

// ---------------------------------------------------------------- validation
function parseSessionId(v) {
  if (typeof v !== 'string' || !UUID_RE.test(v)) throw bad('session id must be a valid UUID');
  return v.toLowerCase();
}

// Day 5 historically sends "meta", Day 4 "metadata". Both are accepted and normalised into
// ONE internal object (metadata wins on key conflicts). No duplicated storage.
function normalizeMetadata(body) {
  const parts = [];
  for (const key of ['meta', 'metadata']) {
    const v = body[key];
    if (v === undefined || v === null) continue;
    if (typeof v !== 'object' || Array.isArray(v)) throw bad(key + ' must be a JSON object');
    parts.push(v);
  }
  const merged = Object.assign({}, ...parts);
  if (Buffer.byteLength(JSON.stringify(merged)) > MAX_METADATA_BYTES) throw bad('metadata is too large (max 64KB)');
  return merged;
}

function optionalString(v, name, def) {
  if (v === undefined || v === null || v === '') return def;
  if (typeof v !== 'string' || v.length > 255) throw bad(name + ' must be a string of at most 255 characters');
  return v;
}

function parseLimit(raw, config, name) {
  if (raw === undefined || raw === null || raw === '') return config.contextMaxMessages;
  const s = String(raw).trim();
  if (!/^\d+$/.test(s)) throw bad(name + ' must be a positive integer');
  const n = parseInt(s, 10);
  if (n < 1 || n > config.contextHardMax) throw bad(name + ' must be between 1 and ' + config.contextHardMax);
  return n;
}

function parseMeta(m) {
  if (typeof m === 'string') { try { return JSON.parse(m); } catch (e) { return {}; } }
  return m || {};
}

function serializeMessage(r) {
  return {
    message_id: r.id,
    role: r.role,
    content: r.content,
    metadata: parseMeta(r.metadata),
    created_at: r.created_at,
    sequence: Number(r.seq)
  };
}

// ---------------------------------------------------------------- error classification
const CONN_CODES = ['ECONNREFUSED', 'ECONNRESET', 'ETIMEDOUT', 'ENOTFOUND', 'EHOSTUNREACH', 'EAI_AGAIN'];
function isDbUnavailable(e) {
  if (!e) return false;
  if (CONN_CODES.includes(e.code)) return true;
  if (typeof e.code === 'string' && /^(08|53|57P)/.test(e.code)) return true;
  return /Connection terminated|timeout exceeded when trying to connect|connection error|Client has encountered/i.test(e.message || '');
}
function isTimeout(e) {
  return !!e && (e.code === 'APP_TIMEOUT' || e.code === '57014' || e.name === 'AbortError' || /Query read timeout/i.test(e.message || ''));
}

// ---------------------------------------------------------------- metrics
function buildMetrics(register) {
  const c = (name, help, extra) => new client.Counter(Object.assign({ name, help, registers: [register] }, extra || {}));
  const h = (name, help, buckets) => new client.Histogram({ name, help, buckets, registers: [register] });
  const trio = (base, label) => ({
    total: c(base + '_requests_total', 'Total number of ' + label + ' requests received'),
    success: c(base + '_requests_success_total', 'Total number of successful ' + label + ' requests'),
    failed: c(base + '_requests_failed_total', 'Total number of failed ' + label + ' requests')
  });
  return {
    context: trio('context', 'context'),
    session: trio('session', 'session'),
    message: trio('message', 'message'),
    chat: trio('chat', '/v1/chat (deprecated)'),
    sessionsCreated: c('sessions_created_total', 'Sessions created'),
    messagesPersisted: c('messages_persisted_total', 'Messages persisted', { labelNames: ['role'] }),
    dbFailures: c('db_failures_total', 'Database failures (connection loss, timeouts, unexpected SQL errors)'),
    deprecated: c('deprecated_requests_total', 'Requests to deprecated routes', { labelNames: ['route'] }),
    contextTruncated: c('context_truncated_total', 'Context builds where older messages were left out'),
    contextBuildDuration: h('context_build_duration_seconds', 'Duration of context construction in seconds', [0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1, 2]),
    contextSize: h('context_size_messages', 'Messages returned per context build', [0, 1, 5, 10, 20, 50, 100, 250, 500]),
    chatContextDuration: h('chat_context_duration_seconds', 'Duration of deprecated /v1/chat pipeline in seconds', [0.1, 0.3, 0.5, 1, 2, 5, 10, 20])
  };
}

// ---------------------------------------------------------------- app factory
function createApp(deps) {
  const config = deps.config;
  const pool = deps.pool;
  const redis = deps.redis || null;          // { ping(): Promise } or null
  const log = deps.log || defaultLog;
  const doFetch = deps.fetch || fetch;

  const register = new client.Registry();
  client.collectDefaultMetrics({ register });
  const metrics = buildMetrics(register);

  const app = express();
  app.disable('x-powered-by');
  app.use(express.json({ limit: '2mb' }));

  const q = (text, params) => withTimeout(pool.query(text, params), config.requestTimeoutMs, 'database query');

  function toHttpError(e) {
    if (e instanceof HttpError) return e;
    if (isTimeout(e)) { metrics.dbFailures.inc(); return new HttpError(504, 'TIMEOUT', 'request timed out'); }
    if (isDbUnavailable(e)) { metrics.dbFailures.inc(); return new HttpError(503, 'DB_UNAVAILABLE', 'database unavailable'); }
    if (e && e.severity) metrics.dbFailures.inc();
    return new HttpError(500, 'INTERNAL', 'internal error');
  }
  function sendError(res, e, req) {
    const he = toHttpError(e);
    if (he.status >= 500) log({ level: 'error', msg: 'request failed', code: he.code, error: e && e.message, method: req.method, path: req.path });
    const payload = { success: false, error: he.message, code: he.code };
    if (res.locals.requestId) payload.request_id = res.locals.requestId;
    res.status(he.status).json(payload);
  }
  function route(kind, fn) {
    const m = metrics[kind];
    return async (req, res) => {
      m.total.inc();
      try { await fn(req, res); m.success.inc(); } catch (e) { m.failed.inc(); sendError(res, e, req); }
    };
  }
  const deprecate = (routeName) => (req, res, next) => {
    res.set('Deprecation', 'true');
    res.set('Link', '</v1/sessions>; rel="successor-version"');
    metrics.deprecated.inc({ route: routeName });
    next();
  };

  // ---------------------------------------------------------------- data access
  async function getSession(id) {
    const r = await q('SELECT * FROM sessions WHERE id = $1', [id]);
    return r.rows[0] || null;
  }
  async function requireSession(id) {
    const s = await getSession(id);
    if (!s) throw new HttpError(404, 'SESSION_NOT_FOUND', 'session not found');
    return s;
  }
  async function createSession(userId, agentName, metadata) {
    const id = genId();
    const r = await q(
      'INSERT INTO sessions (id, user_id, agent_name, metadata, status) VALUES ($1,$2,$3,$4,$5) RETURNING created_at',
      [id, userId, agentName, JSON.stringify(metadata), 'active']
    );
    metrics.sessionsCreated.inc();
    return { id, created_at: r.rows[0].created_at };
  }

  // Level 1 core: the NEWEST `limit` messages, returned oldest -> newest.
  // Fetch limit+1 (newest first, by the deterministic seq key) to learn if we truncated.
  async function fetchRecentMessages(sessionId, limit) {
    const r = await q(
      'SELECT id, role, content, metadata, created_at, seq FROM messages WHERE session_id = $1 ORDER BY seq DESC LIMIT $2',
      [sessionId, limit + 1]
    );
    const truncated = r.rows.length > limit;
    return { rows: r.rows.slice(0, limit).reverse(), truncated };
  }

  // Transactional: lock the session row, insert the message, touch updated_at, COMMIT.
  // Any failure -> ROLLBACK, so "message saved without timestamp" (or the inverse) is impossible.
  // The row lock also serialises writers per session, so seq order == commit order.
  function insertMessage(sessionId, role, content, metadata) {
    return withTimeout(withTx(pool, async (c) => {
      const lock = await c.query('SELECT id FROM sessions WHERE id = $1 FOR UPDATE', [sessionId]);
      if (lock.rowCount === 0) throw new HttpError(404, 'SESSION_NOT_FOUND', 'session not found');
      const id = genId();
      const ins = await c.query(
        'INSERT INTO messages (id, session_id, role, content, metadata) VALUES ($1,$2,$3,$4,$5) RETURNING seq, created_at',
        [id, sessionId, role, content, JSON.stringify(metadata || {})]
      );
      await c.query('UPDATE sessions SET updated_at = now() WHERE id = $1', [sessionId]);
      metrics.messagesPersisted.inc({ role });
      return { id, seq: Number(ins.rows[0].seq), created_at: ins.rows[0].created_at };
    }), config.requestTimeoutMs, 'persist message');
  }

  async function buildSessionContext(sessionId, limit) {
    const end = metrics.contextBuildDuration.startTimer();
    try {
      const { rows, truncated } = await withTimeout(fetchRecentMessages(sessionId, limit), config.requestTimeoutMs, 'build context');
      metrics.contextSize.observe(rows.length);
      if (truncated) metrics.contextTruncated.inc();
      return { messages: rows.map(serializeMessage), truncated };
    } finally { end(); }
  }

  // ---------------------------------------------------------------- infra endpoints
  async function checkPostgres() {
    try { await withTimeout(pool.query('SELECT 1'), config.depTimeoutMs, 'postgres'); return true; } catch (e) { return false; }
  }
  async function checkRedis() {
    if (!redis) return null;
    try { await withTimeout(redis.ping(), config.depTimeoutMs, 'redis'); return true; } catch (e) { return false; }
  }

  // liveness: process is up. Deliberately touches NO dependency.
  app.get('/health', (req, res) => {
    res.json({ status: 'ok', service: SERVICE_NAME, version: SERVICE_VERSION, context_version: CONTEXT_VERSION, timestamp: new Date().toISOString() });
  });

  // readiness: PostgreSQL is REQUIRED (source of truth). Redis only counts if REDIS_REQUIRED=true
  // (it is infrastructure-only today; Level 1 does not read or write it).
  app.get('/ready', async (req, res) => {
    const pg = await checkPostgres();
    const rd = await checkRedis();
    const ready = pg && (!config.redisRequired || rd === true);
    res.status(ready ? 200 : 503).json({
      success: ready,
      ready,
      dependencies: { postgres: pg, redis: rd === true },
      details: {
        postgres: { ready: pg, required: true },
        redis: { state: rd === null ? 'disabled' : (rd ? 'ok' : 'down'), required: config.redisRequired }
      }
    });
  });

  app.get('/dependencies', async (req, res) => {
    const deps2 = { postgres: { reachable: false }, redis: { reachable: false }, stack3: { reachable: false, url: config.stack3Url, used_by: 'deprecated /v1/chat' } };
    deps2.postgres.reachable = await checkPostgres();
    if (!deps2.postgres.reachable) deps2.postgres.error = 'unreachable';
    const rd = await checkRedis();
    deps2.redis.reachable = rd === true;
    if (rd !== true) deps2.redis.error = rd === null ? 'not configured' : 'unreachable';
    if (!config.chatLegacyEnabled) {
      deps2.stack3.skipped = true;
    } else {
      const ctrl = new AbortController();
      const t = setTimeout(() => ctrl.abort(), config.depTimeoutMs);
      try {
        const r = await doFetch(config.stack3Url + '/health', { signal: ctrl.signal });
        deps2.stack3.reachable = r.ok;
      } catch (e) { deps2.stack3.error = 'unreachable'; } finally { clearTimeout(t); }
    }
    res.json({ success: true, dependencies: deps2 });
  });

  app.get('/metrics', async (req, res) => {
    res.set('Content-Type', register.contentType);
    res.end(await register.metrics());
  });

  app.get('/help', (req, res) => {
    res.json({
      service: SERVICE_NAME,
      version: SERVICE_VERSION,
      description: 'AI Gateway - Stack 4 of 10 - Context Harness (Level 1 session context implemented; Level 2/3 foundation only)',
      context_version: CONTEXT_VERSION,
      levels: { level1_session_context: 'implemented', level2_project_context: 'foundation (schema only)', level3_long_term_memory: 'foundation (schema only)' },
      endpoints: [
        { method: 'GET', path: '/health', description: 'Liveness, no dependencies' },
        { method: 'GET', path: '/ready', description: 'Readiness: PostgreSQL required; Redis only if REDIS_REQUIRED=true' },
        { method: 'GET', path: '/dependencies', description: 'Dependency diagnostics with bounded timeouts' },
        { method: 'GET', path: '/metrics', description: 'Prometheus metrics' },
        { method: 'POST', path: '/v1/sessions', description: 'Create a session (user_id optional)' },
        { method: 'GET', path: '/v1/sessions/:id', description: 'Fetch a session' },
        { method: 'POST', path: '/v1/sessions/:id/messages', description: 'Persist a message (role, content, metadata|meta)' },
        { method: 'GET', path: '/v1/sessions/:id/messages?limit=N', description: 'Newest N messages, chronological' },
        { method: 'GET', path: '/v1/sessions/:id/context?max_messages=N', description: 'Versioned session context package' },
        { method: 'DEPRECATED', path: '/v1/session[/:id[/messages]]', description: 'Aliases of the plural routes' },
        { method: 'DEPRECATED', path: 'POST /v1/context', description: 'Legacy context builder; use GET /v1/sessions/:id/context' },
        { method: 'DEPRECATED', path: 'POST /v1/chat', description: 'Orchestration belongs to Day 5; kept for compatibility (CHAT_LEGACY_ENABLED)' }
      ],
      notes: 'Day 4 owns session, history and context assembly. Day 3 owns inference. Day 5 owns orchestration.'
    });
  });

  // ---------------------------------------------------------------- deprecation headers
  app.use('/v1/session', deprecate('/v1/session'));
  app.use('/v1/context', deprecate('/v1/context'));
  app.use('/v1/chat', deprecate('/v1/chat'));

  // ---------------------------------------------------------------- sessions
  app.post(['/v1/sessions', '/v1/session'], route('session', async (req, res) => {
    const body = req.body || {};
    // user_id is optional: Day 5 may send null. Default keeps the NOT NULL column satisfied.
    const userId = optionalString(body.user_id, 'user_id', 'anonymous');
    const agentName = optionalString(body.agent_name, 'agent_name', 'general-assistant');
    const metadata = normalizeMetadata(body);
    const s = await createSession(userId, agentName, metadata);
    res.status(201).json({ success: true, session_id: s.id, user_id: userId, agent_name: agentName, status: 'active', created_at: s.created_at });
  }));

  app.get(['/v1/sessions/:id', '/v1/session/:id'], route('session', async (req, res) => {
    const s = await requireSession(parseSessionId(req.params.id));
    res.json({
      success: true,
      session: {
        session_id: s.id, user_id: s.user_id, agent_name: s.agent_name, metadata: parseMeta(s.metadata),
        status: s.status, created_at: s.created_at, updated_at: s.updated_at
      }
    });
  }));

  // ---------------------------------------------------------------- messages
  app.post(['/v1/sessions/:id/messages', '/v1/session/:id/messages'], route('message', async (req, res) => {
    const sessionId = parseSessionId(req.params.id);
    const body = req.body || {};
    if (typeof body.role !== 'string' || !ROLES.includes(body.role)) throw bad('role must be one of ' + ROLES.join(','));
    if (typeof body.content !== 'string' || body.content.trim() === '') throw bad('content must be a non-empty string');
    if (body.content.length > config.messageMaxChars) throw bad('content exceeds ' + config.messageMaxChars + ' characters');
    const metadata = normalizeMetadata(body);
    await requireSession(sessionId);
    const m = await insertMessage(sessionId, body.role, body.content, metadata);
    res.status(201).json({
      success: true, message_id: m.id, session_id: sessionId, role: body.role, content: body.content,
      metadata, sequence: m.seq, created_at: m.created_at
    });
  }));

  app.get(['/v1/sessions/:id/messages', '/v1/session/:id/messages'], route('message', async (req, res) => {
    const sessionId = parseSessionId(req.params.id);
    const limit = parseLimit(req.query.limit, config, 'limit');
    await requireSession(sessionId);
    const { rows, truncated } = await withTimeout(fetchRecentMessages(sessionId, limit), config.requestTimeoutMs, 'get messages');
    res.json({ success: true, session_id: sessionId, messages: rows.map(serializeMessage), message_count: rows.length, limit, truncated });
  }));

  // ---------------------------------------------------------------- context (canonical)
  app.get('/v1/sessions/:id/context', route('context', async (req, res) => {
    const sessionId = parseSessionId(req.params.id);
    const limit = parseLimit(req.query.max_messages !== undefined ? req.query.max_messages : req.query.limit, config, 'max_messages');
    await requireSession(sessionId);
    const ctx = await buildSessionContext(sessionId, limit);
    res.json({
      success: true,
      session_id: sessionId,
      context_type: 'session',
      context_version: CONTEXT_VERSION,
      messages: ctx.messages,
      message_count: ctx.messages.length,
      max_messages: limit,
      truncated: ctx.truncated,
      layers: { session: 'included', project: 'not_implemented', memory: 'not_implemented' },
      generated_at: new Date().toISOString()
    });
  }));

  // legacy: POST /v1/context (kept, deprecated). Same data, old response shape.
  app.post('/v1/context', route('context', async (req, res) => {
    const body = req.body || {};
    const sessionId = parseSessionId(body.session_id);
    if (typeof body.message !== 'string' || body.message === '') throw bad('message is required');
    const limit = parseLimit(body.max_messages, config, 'max_messages');
    await requireSession(sessionId);
    const ctx = await buildSessionContext(sessionId, limit);
    res.json({
      success: true,
      session_id: sessionId,
      context: {
        system: typeof body.system_instruction === 'string' ? body.system_instruction : '',
        messages: ctx.messages.map((m) => ({ role: m.role, content: m.content })),
        current_message: body.message,
        context_version: CONTEXT_VERSION,
        truncated: ctx.truncated
      }
    });
  }));

  // ---------------------------------------------------------------- DEPRECATED /v1/chat
  // Kept because other consumers (n8n flows, scripts) may still call it and cannot be verified
  // from this repo. Day 5 owns orchestration. Disable with CHAT_LEGACY_ENABLED=false.
  app.post('/v1/chat', route('chat', async (req, res) => {
    const endTimer = metrics.chatContextDuration.startTimer();
    try {
      if (!config.chatLegacyEnabled) throw new HttpError(410, 'GONE', '/v1/chat is disabled on Day 4 (CHAT_LEGACY_ENABLED=false); call Day 5 /v1/chat');
      const body = req.body || {};
      const metadata = normalizeMetadata(body);
      const requestId = String((metadata && metadata.request_id) || req.headers['x-request-id'] || genId());
      res.locals.requestId = requestId;
      if (typeof body.message !== 'string' || body.message === '') throw bad('message is required');

      let sessionId;
      if (body.session_id) {
        sessionId = parseSessionId(body.session_id);
        await requireSession(sessionId);
      } else {
        sessionId = (await createSession(optionalString(metadata.user_id, 'user_id', 'anonymous'), optionalString(body.agent_name, 'agent_name', 'general-assistant'), metadata)).id;
      }
      const agentName = body.agent_name || 'general-assistant';
      const instruction = body.instruction || 'You are a helpful assistant.';

      const ctx = await buildSessionContext(sessionId, config.contextMaxMessages);
      await insertMessage(sessionId, 'user', body.message, { source: metadata.source, request_id: requestId });

      const historyText = ctx.messages.map((m) => m.role + ': ' + m.content).join('\n');
      const combined = historyText ? instruction + '\n\nConversation history so far:\n' + historyText : instruction;
      const payload = {
        agent_name: agentName,
        instruction: combined,
        message: body.message,
        provider: body.provider || 'auto',
        model: body.model || '',
        temperature: typeof body.temperature === 'number' ? body.temperature : 0.3,
        metadata: Object.assign({}, metadata, { request_id: requestId, session_id: sessionId })
      };
      log({ level: 'info', msg: 'forwarding to stack3 (deprecated route)', request_id: requestId, session_id: sessionId });

      const ctrl = new AbortController();
      const timer = setTimeout(() => ctrl.abort(), config.requestTimeoutMs);
      let out;
      try {
        let r;
        try {
          r = await doFetch(config.stack3Url + '/v1/chat', {
            method: 'POST',
            headers: { 'Content-Type': 'application/json', 'X-Request-ID': requestId },
            body: JSON.stringify(payload),
            signal: ctrl.signal
          });
        } catch (e) {
          const t = e && e.name === 'AbortError';
          throw new HttpError(t ? 504 : 502, t ? 'UPSTREAM_TIMEOUT' : 'UPSTREAM_UNREACHABLE', t ? 'stack3 timed out' : 'stack3 unreachable');
        }
        let data;
        try { data = await r.json(); } catch (e) { throw new HttpError(502, 'UPSTREAM_ERROR', 'stack3 returned a non-JSON response'); }
        if (!r.ok || !data || !data.success) {
          const er = data && data.error;
          throw new HttpError(502, 'UPSTREAM_ERROR', (typeof er === 'string' ? er : er && er.message) || 'stack3 returned HTTP ' + r.status);
        }
        out = data;
      } finally { clearTimeout(timer); }

      const assistantText = out.response || '';
      await insertMessage(sessionId, 'assistant', assistantText, { provider: out.provider, model: out.model, request_id: requestId });
      res.json({ success: true, session_id: sessionId, provider: out.provider, model: out.model, message: body.message, response: assistantText, request_id: requestId });
    } finally { endTimer(); }
  }));

  // ---------------------------------------------------------------- fallbacks
  app.use((req, res) => res.status(404).json({ success: false, error: 'not found', code: 'NOT_FOUND' }));
  // eslint-disable-next-line no-unused-vars
  app.use((err, req, res, next) => {
    if (err && err.type === 'entity.parse.failed') return res.status(400).json({ success: false, error: 'malformed JSON body', code: 'INVALID_REQUEST' });
    if (err && err.type === 'entity.too.large') return res.status(413).json({ success: false, error: 'request body too large', code: 'PAYLOAD_TOO_LARGE' });
    log({ level: 'error', msg: 'unhandled error', error: err && err.message });
    res.status(500).json({ success: false, error: 'internal error', code: 'INTERNAL' });
  });

  return app;
}

module.exports = { createApp, HttpError, parseLimit, normalizeMetadata };
__CH_EOF__

  write_file src/index.js <<'__CH_EOF__'
// context-harness:v1 (generated by patch-context-harness.sh)
'use strict';
const { loadConfig, SERVICE_NAME, SERVICE_VERSION, CONTEXT_VERSION } = require('./config');
const { createPool } = require('./db');
const { runMigrations } = require('./migrate');
const { createApp } = require('./app');

function log(obj) {
  try { console.log(JSON.stringify(Object.assign({ ts: new Date().toISOString(), service: SERVICE_NAME }, obj))); } catch (e) { /* ignore */ }
}
function fatal(msg) { log({ level: 'fatal', msg }); process.exit(1); }

let config;
try { config = loadConfig(process.env); } catch (e) { fatal('invalid configuration: ' + e.message); }
if (!config.databaseUrl) fatal('DATABASE_URL is required');

const pool = createPool(config);

// Redis is infrastructure-only for now: readiness signal, NOT a context cache.
// PostgreSQL is the single source of truth for session history.
let redisClient = null;
let redis = null;
if (config.redisUrl) {
  const { createClient } = require('redis');
  redisClient = createClient({ url: config.redisUrl });
  redisClient.on('error', () => {});
  redisClient.connect().catch(() => {});
  redis = { ping: async () => { if (!redisClient.isReady) throw new Error('redis not connected'); return redisClient.ping(); } };
}

let server;
(async () => {
  if (config.migrateOnBoot) {
    try {
      const r = await runMigrations(pool, { log });
      log({ level: 'info', msg: 'migrations up to date', applied: r.applied, already_applied: r.skipped.length });
    } catch (e) {
      // exit non-zero: docker "restart: always" retries once the database is back
      return fatal('migration failed: ' + e.message);
    }
  }
  const app = createApp({ config, pool, redis, log });
  server = app.listen(config.port, config.host, () => {
    log({ level: 'info', msg: 'listening', port: config.port, host: config.host, version: SERVICE_VERSION, context_version: CONTEXT_VERSION, chat_legacy_enabled: config.chatLegacyEnabled });
  });
})();

async function shutdown() {
  const kill = setTimeout(() => process.exit(0), 5000);
  kill.unref();
  try { if (server) await new Promise((r) => server.close(r)); } catch (e) { /* ignore */ }
  try { await pool.end(); } catch (e) { /* ignore */ }
  try { if (redisClient && redisClient.isOpen) await redisClient.quit(); } catch (e) { /* ignore */ }
  process.exit(0);
}
process.on('SIGTERM', shutdown);
process.on('SIGINT', shutdown);
__CH_EOF__

  # ---------------------------------------------------------------- tests
  write_file test/context-harness.test.js <<'__CH_EOF__'
// context-harness:v1 (generated by patch-context-harness.sh)
// Integration tests against REAL PostgreSQL. Everything runs inside a throw-away schema
// (t4_<random>) that is dropped afterwards - production tables are never touched.
'use strict';
const { describe, it, before, after } = require('node:test');
const assert = require('node:assert/strict');
const http = require('node:http');
const crypto = require('node:crypto');
const { Pool } = require('pg');
const { loadDotEnv } = require('../src/load-env');
loadDotEnv();
const { loadConfig, CONTEXT_VERSION } = require('../src/config');
const { createPool } = require('../src/db');
const { runMigrations } = require('../src/migrate');
const { createApp } = require('../src/app');

const DB_URL = process.env.TEST_DATABASE_URL || process.env.DATABASE_URL;
const silent = () => {};
const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;

function testConfig(over) {
  return Object.assign(
    loadConfig({ DATABASE_URL: DB_URL, CONTEXT_MAX_MESSAGES: '10', REQUEST_TIMEOUT_MS: '10000', DEP_TIMEOUT_MS: '2000' }),
    over || {}
  );
}
function startServer(app) {
  return new Promise((resolve) => {
    const server = app.listen(0, '127.0.0.1', () => resolve({ server, base: 'http://127.0.0.1:' + server.address().port }));
  });
}
function stopServer(s) {
  if (!s) return;
  if (s.closeAllConnections) s.closeAllConnections();
  s.close();
}
function api(base) {
  return async (method, path, body) => {
    const r = await fetch(base + path, {
      method,
      headers: { 'content-type': 'application/json' },
      body: body === undefined ? undefined : (typeof body === 'string' ? body : JSON.stringify(body))
    });
    const text = await r.text();
    let json = null;
    try { json = JSON.parse(text); } catch (e) { /* not json */ }
    return { status: r.status, json, headers: r.headers };
  };
}

// ---------------------------------------------------------------------------------------
describe('config validation', () => {
  it('uses safe defaults and treats empty strings as unset (docker-compose passthrough)', () => {
    assert.equal(loadConfig({ DATABASE_URL: 'x' }).contextMaxMessages, 20);
    assert.equal(loadConfig({ DATABASE_URL: 'x', CONTEXT_MAX_MESSAGES: '' }).contextMaxMessages, 20);
    assert.equal(loadConfig({ DATABASE_URL: 'x', CONTEXT_MAX_MESSAGES: '35' }).contextMaxMessages, 35);
  });
  it('rejects invalid CONTEXT_MAX_MESSAGES values', () => {
    for (const bad of ['abc', '0', '-5', '1.5', '99999']) {
      assert.throws(() => loadConfig({ DATABASE_URL: 'x', CONTEXT_MAX_MESSAGES: bad }), /CONTEXT_MAX_MESSAGES/, bad);
    }
  });
  it('rejects a default limit above the hard maximum', () => {
    assert.throws(() => loadConfig({ DATABASE_URL: 'x', CONTEXT_MAX_MESSAGES: '600', CONTEXT_MAX_MESSAGES_HARD: '500' }), /exceeds/);
  });
  it('rejects invalid booleans', () => {
    assert.throws(() => loadConfig({ DATABASE_URL: 'x', REDIS_REQUIRED: 'maybe' }), /REDIS_REQUIRED/);
  });
});

// ---------------------------------------------------------------------------------------
describe('Level 1 session context (PostgreSQL)', () => {
  let schema, admin, pool, config, server, base, call;

  before(async () => {
    assert.ok(DB_URL, 'DATABASE_URL (or TEST_DATABASE_URL) must be set');
    schema = 't4_' + crypto.randomBytes(6).toString('hex');
    admin = new Pool({ connectionString: DB_URL, max: 1 });
    await admin.query('CREATE SCHEMA ' + schema);
    config = testConfig({ searchPath: schema });
    pool = createPool(config);
    await runMigrations(pool, { log: silent });
    ({ server, base } = await startServer(createApp({ config, pool, redis: null, log: silent })));
    call = api(base);
  });
  after(async () => {
    stopServer(server);
    if (pool) await pool.end();
    if (admin) { await admin.query('DROP SCHEMA IF EXISTS ' + schema + ' CASCADE'); await admin.end(); }
  });

  const newSession = async (extra) => {
    const r = await call('POST', '/v1/sessions', Object.assign({ user_id: 'tester' }, extra || {}));
    assert.equal(r.status, 201);
    return r.json.session_id;
  };
  const post = (sid, role, content, extra) => call('POST', '/v1/sessions/' + sid + '/messages', Object.assign({ role, content }, extra || {}));

  describe('sessions', () => {
    it('creates a session', async () => {
      const r = await call('POST', '/v1/sessions', { user_id: 'u1', agent_name: 'coder', metadata: { x: 1 } });
      assert.equal(r.status, 201);
      assert.equal(r.json.success, true);
      assert.match(r.json.session_id, UUID_RE);
      assert.equal(r.json.agent_name, 'coder');
    });
    it('accepts a null user_id (Day 5 behaviour)', async () => {
      const r = await call('POST', '/v1/sessions', { user_id: null });
      assert.equal(r.status, 201);
      assert.equal(r.json.user_id, 'anonymous');
    });
    it('gets a session', async () => {
      const sid = await newSession({ metadata: { project: 'p' } });
      const r = await call('GET', '/v1/sessions/' + sid);
      assert.equal(r.status, 200);
      assert.equal(r.json.session.session_id, sid);
      assert.equal(r.json.session.status, 'active');
      assert.deepEqual(r.json.session.metadata, { project: 'p' });
    });
    it('404 for an unknown session', async () => {
      const r = await call('GET', '/v1/sessions/' + crypto.randomUUID());
      assert.equal(r.status, 404);
      assert.equal(r.json.success, false);
    });
    it('400 for a malformed session id', async () => {
      assert.equal((await call('GET', '/v1/sessions/not-a-uuid')).status, 400);
    });
    it('rejects non-object metadata and malformed JSON', async () => {
      assert.equal((await call('POST', '/v1/sessions', { metadata: [] })).status, 400);
      assert.equal((await call('POST', '/v1/sessions', '{bad json')).status, 400);
    });
    it('legacy singular route still works and is marked deprecated', async () => {
      const r = await call('POST', '/v1/session', { user_id: 'legacy' });
      assert.equal(r.status, 201);
      assert.equal(r.headers.get('deprecation'), 'true');
      const g = await call('GET', '/v1/session/' + r.json.session_id);
      assert.equal(g.status, 200);
    });
  });

  describe('messages', () => {
    it('persists user and assistant messages with metadata', async () => {
      const sid = await newSession();
      const u = await post(sid, 'user', 'hello', { metadata: { source: 'n8n' } });
      assert.equal(u.status, 201);
      assert.deepEqual(u.json.metadata, { source: 'n8n' });
      const a = await post(sid, 'assistant', 'hi there');
      assert.equal(a.status, 201);
      assert.ok(a.json.sequence > u.json.sequence);
      const list = await call('GET', '/v1/sessions/' + sid + '/messages');
      assert.deepEqual(list.json.messages.map((m) => m.role + ':' + m.content), ['user:hello', 'assistant:hi there']);
    });
    it('accepts Day 5 "meta" and normalises it into metadata', async () => {
      const sid = await newSession();
      const r = await post(sid, 'user', 'x', { meta: { request_id: 'r1' } });
      assert.equal(r.status, 201);
      const list = await call('GET', '/v1/sessions/' + sid + '/messages');
      assert.equal(list.json.messages[0].metadata.request_id, 'r1');
    });
    it('merges meta + metadata (metadata wins conflicts)', async () => {
      const sid = await newSession();
      const r = await post(sid, 'user', 'x', { meta: { a: 1, k: 'meta' }, metadata: { b: 2, k: 'metadata' } });
      assert.deepEqual(r.json.metadata, { a: 1, b: 2, k: 'metadata' });
    });
    it('rejects an invalid role', async () => {
      const sid = await newSession();
      assert.equal((await post(sid, 'god', 'x')).status, 400);
      assert.equal((await post(sid, undefined, 'x')).status, 400);
    });
    it('rejects invalid content', async () => {
      const sid = await newSession();
      assert.equal((await post(sid, 'user', '')).status, 400);
      assert.equal((await post(sid, 'user', '   ')).status, 400);
      assert.equal((await post(sid, 'user', 123)).status, 400);
      assert.equal((await post(sid, 'user', 'x'.repeat(config.messageMaxChars + 1))).status, 400);
    });
    it('rejects invalid metadata', async () => {
      const sid = await newSession();
      assert.equal((await post(sid, 'user', 'x', { metadata: 'str' })).status, 400);
      assert.equal((await post(sid, 'user', 'x', { meta: [1] })).status, 400);
    });
    it('404 for an unknown session, 400 for a malformed one', async () => {
      assert.equal((await post(crypto.randomUUID(), 'user', 'x')).status, 404);
      assert.equal((await post('nope', 'user', 'x')).status, 400);
    });
    it('legacy singular messages route works', async () => {
      const sid = (await call('POST', '/v1/session', { user_id: 'l' })).json.session_id;
      const r = await call('POST', '/v1/session/' + sid + '/messages', { role: 'user', content: 'legacy' });
      assert.equal(r.status, 201);
      assert.equal(r.headers.get('deprecation'), 'true');
    });
  });

  describe('ordering (newest N, chronological)', () => {
    it('30 messages with limit 10 -> 21..30 in order (NOT 1..10)', async () => {
      const sid = await newSession();
      for (let i = 1; i <= 30; i++) assert.equal((await post(sid, i % 2 ? 'user' : 'assistant', 'msg ' + i)).status, 201);
      const r = await call('GET', '/v1/sessions/' + sid + '/context?max_messages=10');
      assert.equal(r.status, 200);
      assert.deepEqual(r.json.messages.map((m) => m.content), Array.from({ length: 10 }, (_, k) => 'msg ' + (21 + k)));
      assert.equal(r.json.truncated, true);
      assert.equal(r.json.message_count, 10);
      const seqs = r.json.messages.map((m) => m.sequence);
      assert.deepEqual(seqs, [...seqs].sort((a, b) => a - b));
    });
    it('uses the configured default (10 in tests) when max_messages is absent', async () => {
      const sid = await newSession();
      for (let i = 1; i <= 12; i++) await post(sid, 'user', 'm' + i);
      const r = await call('GET', '/v1/sessions/' + sid + '/context');
      assert.equal(r.json.max_messages, 10);
      assert.equal(r.json.messages[0].content, 'm3');
      assert.equal(r.json.truncated, true);
    });
    it('exactly-at-limit is NOT truncated', async () => {
      const sid = await newSession();
      for (let i = 1; i <= 5; i++) await post(sid, 'user', 'm' + i);
      const r = await call('GET', '/v1/sessions/' + sid + '/context?max_messages=5');
      assert.equal(r.json.truncated, false);
      assert.equal(r.json.messages.length, 5);
    });
    it('the messages listing also returns the newest N chronologically', async () => {
      const sid = await newSession();
      for (let i = 1; i <= 6; i++) await post(sid, 'user', 'm' + i);
      const r = await call('GET', '/v1/sessions/' + sid + '/messages?limit=3');
      assert.deepEqual(r.json.messages.map((m) => m.content), ['m4', 'm5', 'm6']);
      assert.equal(r.json.truncated, true);
    });
    it('concurrent writers get unique, strictly ordered sequence numbers', async () => {
      const sid = await newSession();
      const rs = await Promise.all(Array.from({ length: 20 }, (_, i) => post(sid, 'user', 'c' + i)));
      assert.ok(rs.every((r) => r.status === 201));
      const c = await call('GET', '/v1/sessions/' + sid + '/context?max_messages=50');
      const seqs = c.json.messages.map((m) => m.sequence);
      assert.equal(new Set(seqs).size, 20);
      assert.deepEqual(seqs, [...seqs].sort((a, b) => a - b));
    });
  });

  describe('context package', () => {
    it('empty session', async () => {
      const sid = await newSession();
      const r = await call('GET', '/v1/sessions/' + sid + '/context');
      assert.equal(r.status, 200);
      assert.equal(r.json.session_id, sid);
      assert.equal(r.json.context_type, 'session');
      assert.equal(r.json.context_version, CONTEXT_VERSION);
      assert.deepEqual(r.json.messages, []);
      assert.equal(r.json.message_count, 0);
      assert.equal(r.json.truncated, false);
      assert.equal(r.json.layers.project, 'not_implemented');
      assert.equal(r.json.layers.memory, 'not_implemented');
    });
    it('normal session', async () => {
      const sid = await newSession();
      await post(sid, 'user', 'a');
      await post(sid, 'assistant', 'b');
      const r = await call('GET', '/v1/sessions/' + sid + '/context');
      assert.equal(r.json.message_count, 2);
      assert.deepEqual(r.json.messages.map((m) => m.role), ['user', 'assistant']);
      assert.equal(r.json.context_version, 1);
    });
    it('rejects invalid max_messages', async () => {
      const sid = await newSession();
      for (const bad of ['0', '-1', 'abc', '1.5', '501', '1e2', '5,6']) {
        assert.equal((await call('GET', '/v1/sessions/' + sid + '/context?max_messages=' + encodeURIComponent(bad))).status, 400, bad);
      }
    });
    it('404 for unknown session', async () => {
      assert.equal((await call('GET', '/v1/sessions/' + crypto.randomUUID() + '/context')).status, 404);
    });
    it('legacy POST /v1/context keeps its old shape and is deprecated', async () => {
      const sid = await newSession();
      await post(sid, 'user', 'a');
      const r = await call('POST', '/v1/context', { session_id: sid, message: 'now', system_instruction: 'sys' });
      assert.equal(r.status, 200);
      assert.equal(r.headers.get('deprecation'), 'true');
      assert.equal(r.json.context.system, 'sys');
      assert.equal(r.json.context.current_message, 'now');
      assert.deepEqual(r.json.context.messages, [{ role: 'user', content: 'a' }]);
      assert.equal((await call('POST', '/v1/context', { session_id: sid })).status, 400);
    });
  });

  describe('transactions', () => {
    it('rolls back the INSERT when the session-touch UPDATE fails, then recovers', async () => {
      const sid = await newSession();
      await pool.query("CREATE FUNCTION ch_fail_touch() RETURNS trigger AS $$ BEGIN RAISE EXCEPTION 'simulated failure'; END $$ LANGUAGE plpgsql");
      await pool.query('CREATE TRIGGER ch_fail_touch_trg BEFORE UPDATE ON sessions FOR EACH ROW EXECUTE PROCEDURE ch_fail_touch()');
      try {
        const r = await post(sid, 'user', 'must not persist');
        assert.equal(r.status, 500);
        const n = await pool.query('SELECT count(*)::int AS n FROM messages WHERE session_id = $1', [sid]);
        assert.equal(n.rows[0].n, 0, 'message row must have been rolled back');
      } finally {
        await pool.query('DROP TRIGGER ch_fail_touch_trg ON sessions');
        await pool.query('DROP FUNCTION ch_fail_touch()');
      }
      assert.equal((await post(sid, 'user', 'now it works')).status, 201);
    });
    it('updates sessions.updated_at together with the message', async () => {
      const sid = await newSession();
      const before = (await call('GET', '/v1/sessions/' + sid)).json.session.updated_at;
      await new Promise((r) => setTimeout(r, 15));
      await post(sid, 'user', 'x');
      const after = (await call('GET', '/v1/sessions/' + sid)).json.session.updated_at;
      assert.ok(new Date(after) > new Date(before));
    });
  });

  describe('Day 5 -> Day 4 contract (mirrors Day 5 src/day4Client.js exactly)', () => {
    it('ensureSession / persistTurn / getContext', async () => {
      // ensureSession: POST /v1/sessions { user_id: null } -> res.data.session_id
      let r = await call('POST', '/v1/sessions', { user_id: null });
      assert.equal(r.status, 201);
      const sid = r.json.session_id || r.json.id;
      assert.match(sid, UUID_RE);
      // persistTurn: POST /v1/sessions/:id/messages { role, content, meta }
      r = await call('POST', '/v1/sessions/' + sid + '/messages', { role: 'user', content: 'Hello, my name is Mimo', meta: { agent_name: 'a', request_id: 'req-1', trace_id: 't-1' } });
      assert.equal(r.status, 201);
      r = await call('POST', '/v1/sessions/' + sid + '/messages', { role: 'assistant', content: 'Hi Mimo', meta: { worker: 'chat-worker', provider: 'groq', model: 'm' } });
      assert.equal(r.status, 201);
      // getContext: GET /v1/sessions/:id/context -> res.data.messages || res.data.context
      r = await call('GET', '/v1/sessions/' + sid + '/context');
      const msgs = r.json.messages || r.json.context;
      assert.deepEqual(msgs.map((m) => ({ role: m.role, content: m.content })), [
        { role: 'user', content: 'Hello, my name is Mimo' },
        { role: 'assistant', content: 'Hi Mimo' }
      ]);
      // Day 5 passes history straight into chat: role/content must be present on every item
      assert.ok(msgs.every((m) => typeof m.role === 'string' && typeof m.content === 'string'));
      // isAvailable: GET /health
      assert.equal((await call('GET', '/health')).status, 200);
    });
  });

  describe('health / readiness / failure handling', () => {
    it('/health is liveness only; /ready reports postgres', async () => {
      assert.equal((await call('GET', '/health')).status, 200);
      const r = await call('GET', '/ready');
      assert.equal(r.status, 200);
      assert.equal(r.json.dependencies.postgres, true);
      assert.equal(r.json.details.redis.state, 'disabled');
    });
    it('redis down does not fail readiness unless REDIS_REQUIRED=true', async () => {
      const redis = { ping: async () => { throw new Error('down'); } };
      for (const [required, status] of [[false, 200], [true, 503]]) {
        const s = await startServer(createApp({ config: Object.assign({}, config, { redisRequired: required }), pool, redis, log: silent }));
        try {
          const r = await api(s.base)('GET', '/ready');
          assert.equal(r.status, status);
          assert.equal(r.json.dependencies.redis, false);
        } finally { stopServer(s.server); }
      }
    });
    it('database unavailable -> /health 200, /ready 503, API 503 DB_UNAVAILABLE', async () => {
      const badCfg = testConfig({ databaseUrl: 'postgres://nobody:nopass@127.0.0.1:1/none' });
      const badPool = createPool(badCfg);
      const s = await startServer(createApp({ config: badCfg, pool: badPool, redis: null, log: silent }));
      try {
        const c = api(s.base);
        assert.equal((await c('GET', '/health')).status, 200);
        const ready = await c('GET', '/ready');
        assert.equal(ready.status, 503);
        assert.equal(ready.json.dependencies.postgres, false);
        const r = await c('POST', '/v1/sessions', { user_id: 'x' });
        assert.equal(r.status, 503);
        assert.equal(r.json.code, 'DB_UNAVAILABLE');
      } finally { stopServer(s.server); await badPool.end().catch(() => {}); }
    });
    it('exposes prometheus metrics for sessions, messages, context, size and failures', async () => {
      const txt = await (await fetch(base + '/metrics')).text();
      for (const name of ['session_requests_total', 'message_requests_total', 'context_requests_total', 'context_build_duration_seconds',
        'context_size_messages', 'context_truncated_total', 'db_failures_total', 'sessions_created_total', 'messages_persisted_total']) {
        assert.ok(txt.includes(name), 'missing metric ' + name);
      }
    });
    it('404 for unknown routes', async () => {
      assert.equal((await call('GET', '/nope')).status, 404);
    });
  });

  describe('deprecated POST /v1/chat (kept for compatibility)', () => {
    let stack3, captured, stack3Url;
    before(async () => {
      captured = [];
      stack3 = http.createServer((req, res) => {
        let b = '';
        req.on('data', (d) => { b += d; });
        req.on('end', () => {
          captured.push(JSON.parse(b));
          res.setHeader('content-type', 'application/json');
          res.end(JSON.stringify({ success: true, response: 'pong', provider: 'mock', model: 'm1' }));
        });
      });
      await new Promise((r) => stack3.listen(0, '127.0.0.1', r));
      stack3Url = 'http://127.0.0.1:' + stack3.address().port;
    });
    after(() => { if (stack3.closeAllConnections) stack3.closeAllConnections(); stack3.close(); });

    it('creates a session when none is given, persists both turns, sends history on the next call', async () => {
      const s = await startServer(createApp({ config: Object.assign({}, config, { stack3Url }), pool, redis: null, log: silent }));
      try {
        const c = api(s.base);
        let r = await c('POST', '/v1/chat', { message: 'hello' });
        assert.equal(r.status, 200);
        assert.equal(r.headers.get('deprecation'), 'true');
        assert.equal(r.json.response, 'pong');
        const sid = r.json.session_id;
        assert.match(sid, UUID_RE);
        r = await c('POST', '/v1/chat', { message: 'again', session_id: sid });
        assert.equal(r.status, 200);
        assert.ok(captured[1].instruction.includes('user: hello'));
        assert.ok(captured[1].instruction.includes('assistant: pong'));
        const list = await c('GET', '/v1/sessions/' + sid + '/messages');
        assert.deepEqual(list.json.messages.map((m) => m.role), ['user', 'assistant', 'user', 'assistant']);
        assert.equal((await c('POST', '/v1/chat', { message: 'x', session_id: crypto.randomUUID() })).status, 404);
      } finally { stopServer(s.server); }
    });
    it('can be switched off with CHAT_LEGACY_ENABLED=false (410)', async () => {
      const s = await startServer(createApp({ config: Object.assign({}, config, { chatLegacyEnabled: false }), pool, redis: null, log: silent }));
      try { assert.equal((await api(s.base)('POST', '/v1/chat', { message: 'x' })).status, 410); } finally { stopServer(s.server); }
    });
  });
});

// ---------------------------------------------------------------------------------------
describe('migration from a LEGACY Day 4 schema (no data loss, no failure)', () => {
  let schema, admin, pool, config;
  before(async () => {
    assert.ok(DB_URL, 'DATABASE_URL (or TEST_DATABASE_URL) must be set');
    schema = 't4_up_' + crypto.randomBytes(6).toString('hex');
    admin = new Pool({ connectionString: DB_URL, max: 1 });
    await admin.query('CREATE SCHEMA ' + schema);
    config = testConfig({ searchPath: schema });
    pool = createPool(config);
  });
  after(async () => {
    if (pool) await pool.end();
    if (admin) { await admin.query('DROP SCHEMA IF EXISTS ' + schema + ' CASCADE'); await admin.end(); }
  });

  it('backfills seq deterministically, keeps legacy rows, adds foundations, is re-runnable', async () => {
    // the ORIGINAL Day 4 shape: no seq, no FK, no CHECK
    await pool.query("CREATE TABLE sessions (id uuid PRIMARY KEY, user_id text NOT NULL, agent_name text, metadata jsonb, status text, created_at timestamptz DEFAULT now(), updated_at timestamptz DEFAULT now())");
    await pool.query("CREATE TABLE messages (id uuid PRIMARY KEY, session_id uuid NOT NULL, role text NOT NULL, content text NOT NULL, metadata jsonb, created_at timestamptz DEFAULT now())");
    const sid = crypto.randomUUID();
    await pool.query("INSERT INTO sessions (id, user_id, agent_name, metadata, status) VALUES ($1,'u','a','{}','active')", [sid]);
    const tie = '2024-01-01T00:00:00Z';
    // five rows with IDENTICAL created_at (the collision case) + one older row inserted last
    for (let i = 1; i <= 5; i++) {
      await pool.query('INSERT INTO messages (id, session_id, role, content, metadata, created_at) VALUES ($1,$2,$3,$4,$5,$6)',
        ['00000000-0000-0000-0000-00000000000' + i, sid, 'user', 'tie-' + i, '{}', tie]);
    }
    await pool.query('INSERT INTO messages (id, session_id, role, content, metadata, created_at) VALUES ($1,$2,$3,$4,$5,$6)',
      ['00000000-0000-0000-0000-0000000000ff', sid, 'assistant', 'oldest', '{}', '2023-01-01T00:00:00Z']);
    // legacy dirt that must NOT break the migration: orphan row + non-standard role
    await pool.query("INSERT INTO messages (id, session_id, role, content, metadata) VALUES ($1,$2,'weird','dirty','{}')", [crypto.randomUUID(), crypto.randomUUID()]);

    const first = await runMigrations(pool, { log: silent });
    assert.ok(first.applied.length >= 3, 'expected the three migrations to apply');

    const ordered = await pool.query('SELECT content FROM messages WHERE session_id = $1 ORDER BY seq', [sid]);
    assert.deepEqual(ordered.rows.map((r) => r.content), ['oldest', 'tie-1', 'tie-2', 'tie-3', 'tie-4', 'tie-5']);
    const total = await pool.query('SELECT count(*)::int AS n, count(DISTINCT seq)::int AS d FROM messages');
    assert.equal(total.rows[0].n, 7, 'no rows lost');
    assert.equal(total.rows[0].d, 7, 'seq is unique');
    const nn = await pool.query("SELECT is_nullable FROM information_schema.columns WHERE table_schema = current_schema() AND table_name = 'messages' AND column_name = 'seq'");
    assert.equal(nn.rows[0].is_nullable, 'NO');

    // new rows continue the sequence and are now validated
    const ins = await pool.query("INSERT INTO messages (id, session_id, role, content) VALUES ($1,$2,'user','new') RETURNING seq", [crypto.randomUUID(), sid]);
    assert.ok(Number(ins.rows[0].seq) > 7);
    await assert.rejects(pool.query("INSERT INTO messages (id, session_id, role, content) VALUES ($1,$2,'god','x')", [crypto.randomUUID(), sid]), /messages_role_check/);
    await assert.rejects(pool.query("INSERT INTO messages (id, session_id, role, content) VALUES ($1,$2,'user','x')", [crypto.randomUUID(), crypto.randomUUID()]), /messages_session_fk/);

    // Level 2 / Level 3 foundations exist
    for (const t of ['projects', 'project_context', 'memories']) {
      const r = await pool.query('SELECT to_regclass($1) AS t', [t]);
      assert.ok(r.rows[0].t, t + ' table missing');
    }
    // re-running is a no-op
    const second = await runMigrations(pool, { log: silent });
    assert.deepEqual(second.applied, []);
  });
});
__CH_EOF__

  # ---------------------------------------------------------------- package.json (JSON-safe merge, not sed)
  step "package.json (structured merge)"
  local pkg_json
  pkg_json="$(run_node -e '
    const fs = require("fs");
    const pkg = JSON.parse(fs.readFileSync("package.json", "utf8"));
    pkg.version = "0.2.0";
    pkg.description = pkg.description || "AI Gateway Day 4 - Context Harness (Level 1 session context)";
    pkg.scripts = Object.assign({}, pkg.scripts, {
      start: "node src/index.js",
      migrate: "node src/migrate.js",
      "migrate:status": "node src/migrate.js --status",
      check: "node --check src/index.js && node --check src/app.js && node --check src/config.js && node --check src/db.js && node --check src/migrate.js && node --check src/load-env.js",
      lint: "npm run check",
      test: "node --test test/context-harness.test.js"
    });
    pkg.engines = Object.assign({}, pkg.engines, { node: ">=18" });
    process.stdout.write(JSON.stringify(pkg, null, 2) + "\n");
  ')"
  [[ -n "$pkg_json" ]] || die "could not compute package.json"
  printf '%s\n' "$pkg_json" | write_file package.json replace

  # ---------------------------------------------------------------- Dockerfile
  write_file Dockerfile replace <<'__CH_EOF__'
# context-harness:v1
FROM node:20-alpine
WORKDIR /app
ENV NODE_ENV=production
COPY package.json ./
RUN npm install --omit=dev
COPY src ./src
COPY migrations ./migrations
EXPOSE 8080
CMD ["node", "src/index.js"]
__CH_EOF__

  # ---------------------------------------------------------------- .env.example / .gitignore (create-only)
  write_file .env.example managed <<'__CH_EOF__'
# context-harness:v1 - documentation of Day 4 variables. Copy to .env and edit; never commit secrets.
PORT=8080
HOST=0.0.0.0
API_PORT_HOST=4406
LOG_LEVEL=info

# --- required
DATABASE_URL=postgres://USER:PASSWORD@HOST:5432/DBNAME
# --- optional infrastructure (Redis is readiness-only today; NOT a context cache)
REDIS_URL=redis://redis:6379
REDIS_REQUIRED=false

# --- Level 1 session context
CONTEXT_MAX_MESSAGES=20          # default messages per context (1..CONTEXT_MAX_MESSAGES_HARD)
CONTEXT_MAX_MESSAGES_HARD=500    # absolute cap; requests above it get HTTP 400
MESSAGE_MAX_CHARS=100000

# --- timeouts / pool
REQUEST_TIMEOUT_MS=15000
DEP_TIMEOUT_MS=2000
DB_POOL_MAX=10

# --- migrations
MIGRATE_ON_BOOT=true             # apply pending SQL migrations on start (advisory-locked, additive)

# --- deprecated /v1/chat (orchestration belongs to Day 5)
CHAT_LEGACY_ENABLED=true
STACK3_URL=http://192.168.0.140:4405
__CH_EOF__

  if [[ ! -f "$REPO/.gitignore" ]]; then
    write_file .gitignore managed <<'__CH_EOF__'
# context-harness:v1
node_modules/
.env
.context-harness-backup/
__CH_EOF__
  fi

  # ---------------------------------------------------------------- README
  write_file README.md managed <<'__CH_EOF__'
<!-- context-harness:v1 -->
# Day 4 - Context Harness (Stack 4 of 10)

Day 4 owns **session, conversation history and context assembly**.
Day 3 owns inference. Day 5 owns orchestration. Day 4 never chooses a model.

| Level | Question | Status |
|---|---|---|
| 1 - Session context | "What have we talked about in THIS chat?" | **Implemented** |
| 2 - Project context | "What are we currently building?" | Foundation only (tables `projects`, `project_context`, nullable `sessions.project_id`) |
| 3 - Long-term memory | "What should persist across chats?" | Foundation only (table `memories`) |

```
 n8n / API -> DAY 5 (orchestration) -> DAY 4 CONTEXT HARNESS -> PostgreSQL
                                        L1 session (live) | L2 project | L3 memory
                                                   (L2/L3: schema only)
```

## Canonical API (plural)

| Method | Path | Notes |
|---|---|---|
| POST | `/v1/sessions` | body: `user_id?` (null ok -> `anonymous`), `agent_name?`, `metadata?` -> `201 {session_id}` |
| GET | `/v1/sessions/:id` | 404 unknown, 400 malformed UUID |
| POST | `/v1/sessions/:id/messages` | `role` (system\|user\|assistant\|tool), `content` (non-empty string), `metadata` or `meta` |
| GET | `/v1/sessions/:id/messages?limit=N` | newest N, oldest -> newest |
| GET | `/v1/sessions/:id/context?max_messages=N` | versioned context package (below) |

Context package (`context_version` 1 = session messages; 2 = +summary, 3 = +project, 4 = +memory are reserved):

```json
{ "success": true, "session_id": "...", "context_type": "session", "context_version": 1,
  "messages": [{"message_id":"...","role":"user","content":"...","metadata":{},"created_at":"...","sequence":41}],
  "message_count": 20, "max_messages": 20, "truncated": true,
  "layers": {"session":"included","project":"not_implemented","memory":"not_implemented"},
  "generated_at": "..." }
```

Errors are always `{ "success": false, "error": "...", "code": "INVALID_REQUEST|SESSION_NOT_FOUND|DB_UNAVAILABLE|TIMEOUT|..." }`
with 400 / 404 / 503 / 504 / 500.

### Deprecated but still working (no consumer is broken)
`/v1/session`, `/v1/session/:id`, `/v1/session/:id/messages` (aliases), `POST /v1/context`, `POST /v1/chat`.
They return `Deprecation: true`. `POST /v1/chat` (Stack 3 forwarding) stays until Day 5 fully owns orchestration;
switch it off with `CHAT_LEGACY_ENABLED=false` (returns 410). `meta` (Day 5) and `metadata` are merged into one stored `metadata` object.

## Message ordering
Every message gets `seq` from a database sequence. Context = the **newest** N messages (`ORDER BY seq DESC LIMIT N+1`),
then reversed to chronological order; the extra row tells us whether we truncated. `created_at` is never used alone
(timestamps collide). Inserting a message locks the session row, inserts, touches `sessions.updated_at` and commits in **one transaction**
(rollback on any failure), which also makes `seq` order equal commit order per session.

## Environment variables
See `.env.example`. Invalid values (non-integer, out of range) stop the service at boot; empty values fall back to defaults.
`CONTEXT_MAX_MESSAGES` (20), `CONTEXT_MAX_MESSAGES_HARD` (500), `MESSAGE_MAX_CHARS`, `REQUEST_TIMEOUT_MS` (also enforced by PostgreSQL `statement_timeout`),
`DEP_TIMEOUT_MS`, `DB_POOL_MAX`, `MIGRATE_ON_BOOT`, `REDIS_REQUIRED`, `CHAT_LEGACY_ENABLED`, `STACK3_URL`, `DATABASE_URL`, `REDIS_URL`.

## Health
`/health` = process alive (no dependencies). `/ready` = PostgreSQL required (503 without it); Redis counts only if `REDIS_REQUIRED=true`.
Redis is infrastructure-only: it is **not** used for context storage; PostgreSQL is the source of truth.

## Migrations
`migrations/*.sql`, forward-only and additive, applied in order inside transactions, tracked in `context_harness_migrations`
(with checksum), serialised by an advisory lock. Applied on boot (`MIGRATE_ON_BOOT`) or `npm run migrate` / `npm run migrate:status`.
`001` baseline (no-op on existing DBs), `002` Level 1 (seq, unique `(session_id, seq)`, role CHECK and FK added `NOT VALID` so legacy rows never block), `003` Level 2/3 foundations.

## Metrics (Prometheus, `/metrics`)
`session_requests_*`, `message_requests_*`, `context_requests_*`, `sessions_created_total`, `messages_persisted_total{role}`,
`context_build_duration_seconds`, `context_size_messages`, `context_truncated_total`, `db_failures_total`, `deprecated_requests_total{route}`, plus deprecated `chat_*`.

## Tests
`npm test` (needs `DATABASE_URL` or `TEST_DATABASE_URL`). Runs in an isolated throw-away schema and drops it afterwards.
Covers sessions, messages, `meta` compatibility, ordering (30 messages / limit 10 -> 21..30), transaction rollback, context limits,
Day 5 contract, DB-down behaviour, legacy-schema upgrade.

## Deliberately deferred
Level 2: project APIs, project state/artifact/decision handling. Level 3: retrieval, ranking, embeddings, autonomous memory.
Token-based context budgeting and summarisation (context_version 2). Memory `confidence` must come from evidence
(source, confirmation, repetition, contradiction, verification) - **never from model temperature**.
__CH_EOF__
}

# =============================================================================
# VERIFY / MIGRATE / TEST / DOCKER
# =============================================================================
verify_all() {
  step "Verification"
  local f
  for f in src/index.js src/app.js src/config.js src/db.js src/migrate.js src/load-env.js test/context-harness.test.js; do
    if [[ -f "$REPO/$f" ]]; then run_node --check "$f" && ok "node --check $f"; else warn "missing $f"; fi
  done
  run_node -e 'JSON.parse(require("fs").readFileSync("package.json","utf8"))' && ok "package.json is valid JSON"
  local n; n="$(ls "$REPO"/migrations/*.sql 2>/dev/null | wc -l | tr -d ' ')"
  [[ "$n" -ge 3 ]] && ok "$n migration files present" || die "migrations missing"
  grep -q 'COPY migrations' "$REPO/Dockerfile" && ok "Dockerfile copies migrations/" || die "Dockerfile does not copy migrations/"
  if [[ -f "$REPO/docker-compose.yml" ]] && command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
    if [[ -f "$REPO/.env" ]]; then
      ( cd "$REPO" && docker compose -f docker-compose.yml config -q ) && ok "docker compose config valid" || warn "docker compose config reported problems"
    else warn "skipping compose validation (.env missing)"; fi
  fi
  log "compose/ports/networks/healthcheck are unchanged: /health still answers 200 without dependencies."
}

# runs a shell command (cwd = repo) where DATABASE_URL from .env is reachable
run_with_db_env() {
  local cmd="$1" mode="$TEST_MODE"
  [[ -f "$REPO/.env" || -n "${TEST_DATABASE_URL:-}${DATABASE_URL:-}" ]] || die "no .env and no DATABASE_URL/TEST_DATABASE_URL in the environment"
  if [[ "$mode" != "docker" ]] && node_ok_on_host; then
    ( cd "$REPO" && npm install --no-audit --no-fund --no-package-lock --silent >/dev/null 2>&1 ) || die "npm install failed"
    if ( cd "$REPO" && node -e '
        require("./src/load-env").loadDotEnv();
        const { Client } = require("pg");
        const url = process.env.TEST_DATABASE_URL || process.env.DATABASE_URL;
        if (!url) { console.error("DATABASE_URL not set"); process.exit(2); }
        const c = new Client({ connectionString: url, connectionTimeoutMillis: 4000 });
        c.connect().then(() => c.query("select 1")).then(() => process.exit(0)).catch((e) => { console.error(e.message); process.exit(1); });
      ' ); then
      ok "database reachable from the host"
      ( cd "$REPO" && bash -c "$cmd" )
      return $?
    fi
    [[ "$mode" == "host" ]] && die "database not reachable from the host (use --test-mode docker or set TEST_DATABASE_URL)"
    warn "database not reachable from the host - retrying inside a docker network"
  fi
  command -v docker >/dev/null 2>&1 || die "database unreachable from host and docker is not available"
  local nets=() n cid rc=0 env_args=()
  for n in ai-gateway-net databases obs-network; do docker network inspect "$n" >/dev/null 2>&1 && nets+=("$n"); done
  [[ ${#nets[@]} -eq 0 ]] && warn "none of ai-gateway-net/databases/obs-network exist; using the default bridge"
  [[ -n "${TEST_DATABASE_URL:-}" ]] && env_args+=(-e "TEST_DATABASE_URL=$TEST_DATABASE_URL")
  cid="$(docker create ${nets[0]:+--network "${nets[0]}"} ${env_args[@]+"${env_args[@]}"} \
        -v "$REPO":/app -v /app/node_modules -w /app "$NODE_IMAGE" \
        sh -c "npm install --no-audit --no-fund --no-package-lock --silent && $cmd")"
  for n in "${nets[@]:1}"; do docker network connect "$n" "$cid" >/dev/null 2>&1 || true; done
  log "running inside a throw-away $NODE_IMAGE container on: ${nets[*]:-bridge}"
  docker start -a "$cid" || rc=$?
  docker rm -fv "$cid" >/dev/null 2>&1 || true
  return $rc
}

do_migrate() {
  step "Database migrations (additive, transactional, advisory-locked)"
  if [[ $MIGRATE_STATUS -eq 1 && $DO_MIGRATE -eq 0 ]]; then run_with_db_env "node src/migrate.js --status"
  else run_with_db_env "node src/migrate.js"; fi
}

do_tests() {
  step "Test suite (real PostgreSQL, isolated throw-away schema)"
  run_with_db_env "node --test test/context-harness.test.js" && ok "all tests passed" || die "tests failed"
}

do_docker_build() {
  step "Docker image build (validation only - nothing is run or pushed)"
  command -v docker >/dev/null 2>&1 || die "docker not found"
  ( cd "$REPO" && docker build -t ai-gateway-4-context-harness:patch-check . ) && ok "image builds"
}

summary() {
  step "Summary"
  log "changed   (${#CHANGED[@]}): ${CHANGED[*]:-none}"
  log "unchanged (${#UNCHANGED[@]}): ${UNCHANGED[*]:-none}"
  [[ ${#SKIPPED[@]} -gt 0 ]] && log "skipped   (${#SKIPPED[@]}): ${SKIPPED[*]}"
  [[ -n "$BACKUP_DIR" && -d "$BACKUP_DIR" ]] && log "backups   : $BACKUP_DIR"
  log "NOT changed by design: .env, docker-compose.yml, prometheus/, grafana/, other repos (Day 3 / Day 5)"
  if [[ $DRY_RUN -eq 0 ]] && git -C "$REPO" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    step "git status / diff --stat (nothing is committed)"
    git -C "$REPO" status --short
    git -C "$REPO" diff --stat
    [[ $SHOW_DIFF -eq 1 ]] && git -C "$REPO" diff
  fi
  if [[ $DRY_RUN -eq 1 ]]; then
    log ""; log "DRY RUN: nothing was written."
  else
    log ""
    log "Next (manual, not automatic):"
    log "  1. review:  git -C \"$REPO\" diff"
    log "  2. deploy:  cd \"$REPO\" && docker compose up -d --build   (migrations run on boot)"
    log "  3. smoke:   curl -s localhost:\${API_PORT_HOST:-4406}/ready ; curl -s -XPOST localhost:\${API_PORT_HOST:-4406}/v1/sessions -H 'content-type: application/json' -d '{\"user_id\":null}'"
    log "  4. commit yourself when satisfied (this script never commits or pushes)."
  fi
}

# =============================================================================
# MAIN
# =============================================================================
detect_repo
preflight
if [[ $TEST_ONLY -eq 1 ]]; then
  do_tests
  exit 0
fi
if [[ $MIGRATE_STATUS -eq 1 && $DO_MIGRATE -eq 0 && $DO_TEST -eq 0 && $DRY_RUN -eq 0 ]]; then
  do_migrate; exit 0
fi

patch_all
if [[ $DRY_RUN -eq 1 ]]; then
  summary
  exit 0
fi
[[ $DO_VERIFY -eq 1 ]] && verify_all
[[ $DO_MIGRATE -eq 1 || $MIGRATE_STATUS -eq 1 ]] && do_migrate
[[ $DO_TEST -eq 1 ]] && do_tests
[[ $DO_DOCKER_BUILD -eq 1 ]] && do_docker_build
summary
ok "done (script v$SCRIPT_VERSION)"
