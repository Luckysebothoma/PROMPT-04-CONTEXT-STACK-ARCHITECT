'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');

test('context history query selects newest bounded window and returns chronological order', () => {
  const source = fs.readFileSync(require.resolve('../src/index.js'), 'utf8');
  assert.match(source, /SELECT id, role, content, metadata, created_at\s+FROM \(/);
  assert.match(source, /ORDER BY created_at DESC, id DESC\s+LIMIT \$2/);
  assert.match(source, /ORDER BY created_at ASC, id ASC/);
  assert.match(source, /Math\.min\(limit, 500\)/);
});
