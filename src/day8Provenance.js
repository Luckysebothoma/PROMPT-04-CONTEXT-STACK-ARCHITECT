'use strict';
// DAY8_PROVENANCE - records which messages Day 4 actually delivered in a context response.
// It is an Express middleware that observes the response AFTER it has been sent ('finish'),
// so it adds no latency and cannot change or fail the request. Own tiny pg pool (max 2, 2s timeouts),
// errors swallowed, pauses itself for 60s after 5 consecutive failures. PROVENANCE_ENABLED=false switches it off.
// Routes observed (override with PROVENANCE_ROUTE_REGEX): GET /v1/sessions/:id/context and POST /v1/context.
const crypto = require('crypto');
let Pool = null;
try { ({ Pool } = require('pg')); } catch (_) { /* pg missing -> disabled */ }
let prom = null;
try { prom = require('prom-client'); } catch (_) { /* metrics optional */ }

const ENABLED = process.env.PROVENANCE_ENABLED !== 'false' && !!process.env.DATABASE_URL && !!Pool;
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
let ROUTE_RE;
try { ROUTE_RE = new RegExp(process.env.PROVENANCE_ROUTE_REGEX || '^/v1/(sessions?/[^/]+/context|context)/?$'); }
catch (_) { ROUTE_RE = /^\/v1\/(sessions?\/[^/]+\/context|context)\/?$/; }

const pool = ENABLED
  ? new Pool({ connectionString: process.env.DATABASE_URL, max: 2, connectionTimeoutMillis: 2000, statement_timeout: 2000, query_timeout: 2500 })
  : null;
if (pool) pool.on('error', () => {});

let recorded = null;
let failed = null;
function attach(registry) {
  if (!prom || recorded) return;
  try {
    const registers = [registry || prom.register];
    recorded = new prom.Counter({ name: 'context_provenance_recorded_total', help: 'Context deliveries recorded (Day 8)', registers });
    failed = new prom.Counter({ name: 'context_provenance_failed_total', help: 'Context delivery records that failed (Day 8, fail-open)', registers });
  } catch (_) { /* already registered elsewhere */ }
}
const inc = (c) => { try { if (c) c.inc(); } catch (_) {} };

let failStreak = 0;
let pausedUntil = 0;

function findMessages(o, depth) {
  if (depth > 6 || !o || typeof o !== 'object') return null;
  if (Array.isArray(o)) {
    if (o.length && o.every((x) => x && typeof x === 'object' && 'role' in x && ('content' in x || 'text' in x))) return o;
    for (const x of o) { const r = findMessages(x, depth + 1); if (r) return r; }
    return null;
  }
  for (const k of Object.keys(o)) { const r = findMessages(o[k], depth + 1); if (r) return r; }
  return null;
}

function record(req, res, captured) {
  if (!pool || Date.now() < pausedUntil) return;
  if (res.statusCode >= 400 || captured == null) return;
  const path = String(req.originalUrl || req.url || '').split('?')[0];
  const body = (req.body && typeof req.body === 'object') ? req.body : {};
  const meta = (body.metadata && typeof body.metadata === 'object') ? body.metadata : {};
  const h = req.headers || {};
  const q = req.query || {};
  let sessionId = null;
  const sm = path.match(/\/sessions?\/([0-9a-f-]{36})\//i);
  if (sm) sessionId = sm[1]; else if (typeof body.session_id === 'string') sessionId = body.session_id;
  if (!sessionId || !UUID.test(sessionId)) return;
  let payload = null;
  try {
    const text = Buffer.isBuffer(captured) ? captured.toString('utf8') : String(captured);
    if (text.length > 5 * 1024 * 1024) return;
    payload = JSON.parse(text);
  } catch (_) { return; }
  const msgs = findMessages(payload, 0) || [];
  const ids = msgs.map((m) => m.id || m.message_id).filter((x) => typeof x === 'string' && UUID.test(x));
  const chars = msgs.reduce((n, m) => n + (typeof m.content === 'string' ? m.content.length : (typeof m.text === 'string' ? m.text.length : 0)), 0);
  const rid = String(h['x-request-id'] || body.request_id || meta.request_id || q.request_id || crypto.randomUUID());
  const trace = body.trace_id || meta.trace_id || h['x-trace-id'] || q.trace_id || null;
  const route = (req.method || 'GET') + ' ' + path.replace(/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/gi, ':id');
  if (!recorded) attach();
  pool.query(
    'INSERT INTO context_deliveries (request_id, trace_id, session_id, caller, route, message_ids, message_count, context_chars) ' +
    "VALUES ($1,$2,$3,'context',$4,$5::uuid[],$6,$7) ON CONFLICT (request_id, caller) DO NOTHING",
    [rid, trace ? String(trace) : null, sessionId, route, ids, msgs.length, chars]
  ).then(() => { failStreak = 0; inc(recorded); }).catch((e) => {
    inc(failed);
    failStreak++;
    if (failStreak >= 5) {
      failStreak = 0;
      pausedUntil = Date.now() + 60000;
      console.log(JSON.stringify({ ts: new Date().toISOString(), level: 'warn', msg: 'day8 provenance recording paused 60s after repeated failures', error: e && e.message }));
    }
  });
}

function middleware(req, res, next) {
  try {
    if (ENABLED) {
      const path = String(req.originalUrl || req.url || '').split('?')[0];
      if (ROUTE_RE.test(path)) {
        let captured = null;
        const origSend = res.send;
        res.send = function (b) { try { captured = b; } catch (_) {} return origSend.apply(this, arguments); };
        res.on('finish', () => { try { record(req, res, captured); } catch (_) { inc(failed); } });
      }
    }
  } catch (_) { /* never affect the request */ }
  next();
}

module.exports = { attach, middleware, enabled: ENABLED };
