const express = require('express');
const { Pool } = require('pg');
const { createClient } = require('redis');
const client = require('prom-client');
const crypto = require('crypto');

const PORT = process.env.PORT || 8080;
const HOST = process.env.HOST || '0.0.0.0';
const DATABASE_URL = process.env.DATABASE_URL;
const REDIS_URL = process.env.REDIS_URL;
const STACK3_URL = process.env.STACK3_URL || 'http://192.168.0.140:4405';
const REQUEST_TIMEOUT_MS = parseInt(process.env.REQUEST_TIMEOUT_MS || '15000', 10);
const DEP_TIMEOUT_MS = parseInt(process.env.DEP_TIMEOUT_MS || '2000', 10);
const CONTEXT_MAX_MESSAGES = parseInt(process.env.CONTEXT_MAX_MESSAGES || '20', 10);
const SERVICE_NAME = 'ai-gateway-4-of-10-context-session';

const app = express();
app.use(express.json({ limit: '2mb' }));

const pool = new Pool({ connectionString: DATABASE_URL, max: 10 });
const redisClient = createClient({ url: REDIS_URL });
redisClient.on('error', () => {});
let redisReady = false;
(async () => {
  try {
    await redisClient.connect();
    redisReady = true;
  } catch (e) {
    redisReady = false;
  }
})();

const register = new client.Registry();
client.collectDefaultMetrics({ register });

function counter(name, help) {
  const c = new client.Counter({ name, help });
  register.registerMetric(c);
  return c;
}
function histogram(name, help, buckets) {
  const h = new client.Histogram({ name, help, buckets });
  register.registerMetric(h);
  return h;
}

const contextRequestsTotal = counter('context_requests_total', 'Total number of /v1/context requests received');
const contextRequestsSuccessTotal = counter('context_requests_success_total', 'Total number of successful /v1/context requests');
const contextRequestsFailedTotal = counter('context_requests_failed_total', 'Total number of failed /v1/context requests');

const sessionRequestsTotal = counter('session_requests_total', 'Total number of session requests received');
const sessionRequestsSuccessTotal = counter('session_requests_success_total', 'Total number of successful session requests');
const sessionRequestsFailedTotal = counter('session_requests_failed_total', 'Total number of failed session requests');

const messageRequestsTotal = counter('message_requests_total', 'Total number of message requests received');
const messageRequestsSuccessTotal = counter('message_requests_success_total', 'Total number of successful message requests');
const messageRequestsFailedTotal = counter('message_requests_failed_total', 'Total number of failed message requests');

const chatRequestsTotal = counter('chat_requests_total', 'Total number of /v1/chat requests received');
const chatRequestsSuccessTotal = counter('chat_requests_success_total', 'Total number of successful /v1/chat requests');
const chatRequestsFailedTotal = counter('chat_requests_failed_total', 'Total number of failed /v1/chat requests');

const contextBuildDuration = histogram('context_build_duration_seconds', 'Duration of context construction in seconds', [0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1, 2]);
const chatContextDuration = histogram('chat_context_duration_seconds', 'Duration of full chat and context pipeline in seconds', [0.1, 0.3, 0.5, 1, 2, 5, 10, 20]);

function withTimeout(promise, ms, label) {
  let timer;
  const timeout = new Promise((_, reject) => {
    timer = setTimeout(() => reject(new Error((label || 'operation') + ' timed out after ' + ms + 'ms')), ms);
  });
  return Promise.race([promise, timeout]).finally(() => clearTimeout(timer));
}

function log(obj) {
  try {
    console.log(JSON.stringify(Object.assign({ ts: new Date().toISOString(), service: SERVICE_NAME }, obj)));
  } catch (e) {}
}

function genId() {
  return crypto.randomUUID();
}

app.get('/health', (req, res) => {
  res.json({ status: 'ok', service: SERVICE_NAME, timestamp: new Date().toISOString() });
});

app.get('/ready', async (req, res) => {
  const result = { postgres: false, redis: false };
  try {
    await withTimeout(pool.query('SELECT 1'), DEP_TIMEOUT_MS, 'postgres');
    result.postgres = true;
  } catch (e) {}
  try {
    if (redisReady) {
      await withTimeout(redisClient.ping(), DEP_TIMEOUT_MS, 'redis');
      result.redis = true;
    }
  } catch (e) {}
  const ready = result.postgres && result.redis;
  res.status(ready ? 200 : 503).json({ success: ready, ready, dependencies: result });
});

app.get('/dependencies', async (req, res) => {
  const deps = {
    postgres: { reachable: false },
    redis: { reachable: false },
    stack3: { reachable: false, url: STACK3_URL }
  };
  try {
    await withTimeout(pool.query('SELECT 1'), DEP_TIMEOUT_MS, 'postgres');
    deps.postgres.reachable = true;
  } catch (e) {
    deps.postgres.error = 'unreachable';
  }
  try {
    if (redisReady) {
      await withTimeout(redisClient.ping(), DEP_TIMEOUT_MS, 'redis');
      deps.redis.reachable = true;
    } else {
      deps.redis.error = 'not connected';
    }
  } catch (e) {
    deps.redis.error = 'unreachable';
  }
  try {
    const ctrl = new AbortController();
    const t = setTimeout(() => ctrl.abort(), DEP_TIMEOUT_MS);
    const r = await fetch(STACK3_URL + '/health', { signal: ctrl.signal });
    clearTimeout(t);
    deps.stack3.reachable = r.ok;
  } catch (e) {
    deps.stack3.error = 'unreachable';
  }
  res.json({ success: true, dependencies: deps });
});

app.get('/help', (req, res) => {
  res.json({
    service: SERVICE_NAME,
    version: '0.1.0',
    description: 'AI Gateway - Stack 4 of 10 - Context, Session and Conversation Intelligence',
    endpoints: [
      { method: 'GET', path: '/health', description: 'Process liveness, no external dependencies' },
      { method: 'GET', path: '/ready', description: 'Readiness including Postgres and Redis' },
      { method: 'GET', path: '/dependencies', description: 'Dependency connectivity diagnostics with bounded timeouts' },
      { method: 'GET', path: '/help', description: 'Machine readable API discovery document' },
      { method: 'GET', path: '/metrics', description: 'Prometheus metrics' },
      { method: 'POST', path: '/v1/session', description: 'Create a session' },
      { method: 'GET', path: '/v1/session/:session_id', description: 'Fetch a session' },
      { method: 'POST', path: '/v1/session/:session_id/messages', description: 'Persist a message' },
      { method: 'GET', path: '/v1/session/:session_id/messages', description: 'List messages chronologically' },
      { method: 'POST', path: '/v1/context', description: 'Construct a normalized context object' },
      { method: 'POST', path: '/v1/chat', description: 'Context aware chat forwarded to Stack 3 provider routing' }
    ],
    notes: 'Day 4 of 10. Conversation history and context construction only. No vector memory, no tool execution, no provider failover.'
  });
});

app.get('/metrics', async (req, res) => {
  res.set('Content-Type', register.contentType);
  res.end(await register.metrics());
});

async function ensureSession(sessionId) {
  const r = await pool.query('SELECT * FROM sessions WHERE id = $1', [sessionId]);
  return r.rows[0] || null;
}

app.post('/v1/session', async (req, res) => {
  sessionRequestsTotal.inc();
  try {
    const body = req.body || {};
    const userId = body.user_id;
    if (!userId) {
      sessionRequestsFailedTotal.inc();
      return res.status(400).json({ success: false, error: 'user_id is required' });
    }
    const id = genId();
    const agentName = body.agent_name || 'general-assistant';
    const meta = body.metadata || {};
    await withTimeout(
      pool.query(
        'INSERT INTO sessions (id, user_id, agent_name, metadata, status) VALUES ($1,$2,$3,$4,$5)',
        [id, userId, agentName, JSON.stringify(meta), 'active']
      ),
      REQUEST_TIMEOUT_MS,
      'insert session'
    );
    sessionRequestsSuccessTotal.inc();
    res.status(201).json({ success: true, session_id: id, user_id: userId, agent_name: agentName });
  } catch (e) {
    sessionRequestsFailedTotal.inc();
    log({ level: 'error', msg: 'session create failed', error: e.message });
    res.status(500).json({ success: false, error: 'internal error' });
  }
});

app.get('/v1/session/:session_id', async (req, res) => {
  sessionRequestsTotal.inc();
  try {
    const s = await withTimeout(ensureSession(req.params.session_id), REQUEST_TIMEOUT_MS, 'get session');
    if (!s) {
      sessionRequestsFailedTotal.inc();
      return res.status(404).json({ success: false, error: 'session not found' });
    }
    sessionRequestsSuccessTotal.inc();
    res.json({
      success: true,
      session: {
        session_id: s.id,
        user_id: s.user_id,
        agent_name: s.agent_name,
        metadata: s.metadata,
        status: s.status,
        created_at: s.created_at,
        updated_at: s.updated_at
      }
    });
  } catch (e) {
    sessionRequestsFailedTotal.inc();
    res.status(500).json({ success: false, error: 'internal error' });
  }
});

async function insertMessage(sessionId, role, content, metadata) {
  const id = genId();
  await pool.query(
    'INSERT INTO messages (id, session_id, role, content, metadata) VALUES ($1,$2,$3,$4,$5)',
    [id, sessionId, role, content, JSON.stringify(metadata || {})]
  );
  await pool.query('UPDATE sessions SET updated_at = now() WHERE id = $1', [sessionId]);
  return id;
}

app.post('/v1/session/:session_id/messages', async (req, res) => {
  messageRequestsTotal.inc();
  try {
    const sessionId = req.params.session_id;
    const s = await ensureSession(sessionId);
    if (!s) {
      messageRequestsFailedTotal.inc();
      return res.status(404).json({ success: false, error: 'session not found' });
    }
    const body = req.body || {};
    const role = body.role;
    const content = body.content;
    if (!role || ['system', 'user', 'assistant', 'tool'].indexOf(role) === -1) {
      messageRequestsFailedTotal.inc();
      return res.status(400).json({ success: false, error: 'role must be one of system,user,assistant,tool' });
    }
    if (!content || typeof content !== 'string') {
      messageRequestsFailedTotal.inc();
      return res.status(400).json({ success: false, error: 'content is required' });
    }
    const messageId = await withTimeout(insertMessage(sessionId, role, content, body.metadata), REQUEST_TIMEOUT_MS, 'insert message');
    messageRequestsSuccessTotal.inc();
    res.status(201).json({ success: true, message_id: messageId, session_id: sessionId, role, content });
  } catch (e) {
    messageRequestsFailedTotal.inc();
    log({ level: 'error', msg: 'message insert failed', error: e.message });
    res.status(500).json({ success: false, error: 'internal error' });
  }
});

async function getMessages(sessionId, limit) {
  const r = await pool.query(
    'SELECT id, role, content, metadata, created_at FROM messages WHERE session_id = $1 ORDER BY created_at ASC LIMIT $2',
    [sessionId, limit]
  );
  return r.rows;
}

app.get('/v1/session/:session_id/messages', async (req, res) => {
  messageRequestsTotal.inc();
  try {
    const sessionId = req.params.session_id;
    const s = await ensureSession(sessionId);
    if (!s) {
      messageRequestsFailedTotal.inc();
      return res.status(404).json({ success: false, error: 'session not found' });
    }
    const limit = Math.min(parseInt(req.query.limit || String(CONTEXT_MAX_MESSAGES), 10) || CONTEXT_MAX_MESSAGES, 500);
    const rows = await withTimeout(getMessages(sessionId, limit), REQUEST_TIMEOUT_MS, 'get messages');
    messageRequestsSuccessTotal.inc();
    res.json({
      success: true,
      session_id: sessionId,
      messages: rows.map((r) => ({ message_id: r.id, role: r.role, content: r.content, metadata: r.metadata, created_at: r.created_at }))
    });
  } catch (e) {
    messageRequestsFailedTotal.inc();
    res.status(500).json({ success: false, error: 'internal error' });
  }
});

async function buildContext(sessionId, currentMessage, systemInstruction, maxMessages) {
  const end = contextBuildDuration.startTimer();
  try {
    const rows = await getMessages(sessionId, maxMessages);
    const messages = rows.map((r) => ({ role: r.role, content: r.content }));
    return { system: systemInstruction || '', messages, current_message: currentMessage };
  } finally {
    end();
  }
}

app.post('/v1/context', async (req, res) => {
  contextRequestsTotal.inc();
  try {
    const body = req.body || {};
    const sessionId = body.session_id;
    const message = body.message;
    if (!sessionId) {
      contextRequestsFailedTotal.inc();
      return res.status(400).json({ success: false, error: 'session_id is required' });
    }
    if (!message) {
      contextRequestsFailedTotal.inc();
      return res.status(400).json({ success: false, error: 'message is required' });
    }
    const s = await ensureSession(sessionId);
    if (!s) {
      contextRequestsFailedTotal.inc();
      return res.status(404).json({ success: false, error: 'session not found' });
    }
    const limit = Math.min(body.max_messages || CONTEXT_MAX_MESSAGES, 500);
    const context = await withTimeout(buildContext(sessionId, message, body.system_instruction, limit), REQUEST_TIMEOUT_MS, 'build context');
    contextRequestsSuccessTotal.inc();
    res.json({ success: true, session_id: sessionId, context });
  } catch (e) {
    contextRequestsFailedTotal.inc();
    log({ level: 'error', msg: 'context build failed', error: e.message });
    res.status(500).json({ success: false, error: 'internal error' });
  }
});

app.post('/v1/chat', async (req, res) => {
  chatRequestsTotal.inc();
  const endChatTimer = chatContextDuration.startTimer();
  const body = req.body || {};
  const requestId = (body.metadata && body.metadata.request_id) || req.headers['x-request-id'] || genId();
  try {
    const message = body.message;
    if (!message || typeof message !== 'string') {
      chatRequestsFailedTotal.inc();
      endChatTimer();
      return res.status(400).json({ success: false, error: 'message is required', request_id: requestId });
    }
    let sessionId = body.session_id;
    const agentName = body.agent_name || 'general-assistant';
    const instruction = body.instruction || 'You are a helpful assistant.';
    const provider = body.provider || 'auto';
    const model = body.model || '';
    const temperature = typeof body.temperature === 'number' ? body.temperature : 0.3;
    const metadata = body.metadata || {};

    let session = sessionId ? await ensureSession(sessionId) : null;
    if (!session) {
      sessionId = sessionId || genId();
      await pool.query(
        'INSERT INTO sessions (id, user_id, agent_name, metadata, status) VALUES ($1,$2,$3,$4,$5) ON CONFLICT (id) DO NOTHING',
        [sessionId, metadata.user_id || 'anonymous', agentName, JSON.stringify(metadata), 'active']
      );
      session = await ensureSession(sessionId);
    }

    const context = await withTimeout(buildContext(sessionId, message, instruction, CONTEXT_MAX_MESSAGES), REQUEST_TIMEOUT_MS, 'build context');

    await withTimeout(
      insertMessage(sessionId, 'user', message, { source: metadata.source, request_id: requestId }),
      REQUEST_TIMEOUT_MS,
      'persist user message'
    );

    const historyText = context.messages.map((m) => m.role + ': ' + m.content).join('\n');
    const combinedInstruction = historyText ? instruction + '\n\nConversation history so far:\n' + historyText : instruction;

    const stack3Payload = {
      agent_name: agentName,
      instruction: combinedInstruction,
      message,
      provider,
      model,
      temperature,
      metadata: Object.assign({}, metadata, { request_id: requestId, session_id: sessionId })
    };

    log({
      level: 'info',
      msg: 'forwarding to stack3',
      request_id: requestId,
      session_id: sessionId,
      workflow_id: metadata.workflow_id,
      execution_id: metadata.execution_id
    });

    const ctrl = new AbortController();
    const timer = setTimeout(() => ctrl.abort(), REQUEST_TIMEOUT_MS);
    let stack3Response;
    try {
      const r = await fetch(STACK3_URL + '/v1/chat', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json', 'X-Request-ID': requestId },
        body: JSON.stringify(stack3Payload),
        signal: ctrl.signal
      });
      stack3Response = await r.json();
      if (!r.ok || !stack3Response.success) {
        throw new Error(stack3Response.error || 'stack3 returned HTTP ' + r.status);
      }
    } finally {
      clearTimeout(timer);
    }

    const assistantText = stack3Response.response || '';
    await withTimeout(
      insertMessage(sessionId, 'assistant', assistantText, { provider: stack3Response.provider, model: stack3Response.model, request_id: requestId }),
      REQUEST_TIMEOUT_MS,
      'persist assistant message'
    );

    chatRequestsSuccessTotal.inc();
    endChatTimer();
    res.json({
      success: true,
      session_id: sessionId,
      provider: stack3Response.provider,
      model: stack3Response.model,
      message,
      response: assistantText,
      request_id: requestId
    });
  } catch (e) {
    chatRequestsFailedTotal.inc();
    endChatTimer();
    log({ level: 'error', msg: 'chat failed', error: e.message, request_id: requestId });
    res.status(502).json({ success: false, error: e.message || 'chat pipeline failed', request_id: requestId });
  }
});

app.use((req, res) => res.status(404).json({ success: false, error: 'not found' }));

app.listen(PORT, HOST, () => {
  log({ level: 'info', msg: 'listening', port: PORT, host: HOST });
});

process.on('SIGTERM', () => process.exit(0));
process.on('SIGINT', () => process.exit(0));
