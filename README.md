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
