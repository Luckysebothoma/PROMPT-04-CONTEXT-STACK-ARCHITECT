'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');

test('context history selects the newest bounded window in chronological order', () => {
  const source = fs.readFileSync(require.resolve('../src/app.js'), 'utf8');

  assert.match(source, /ORDER BY seq DESC LIMIT \$2/);
  assert.match(source, /r\.rows\.slice\(0, limit\)\.reverse\(\)/);
});
