'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const { createRateLimiter } = require('../src/request-rate-limiter');

function run(middleware, request = { ip: '127.0.0.1', method: 'GET' }) {
  const headers = {};
  const response = {
    statusCode: 200,
    body: null,
    set(name, value) {
      headers[name] = value;
      return this;
    },
    status(statusCode) {
      this.statusCode = statusCode;
      return this;
    },
    json(body) {
      this.body = body;
      return this;
    },
  };
  let continued = false;
  middleware(request, response, () => { continued = true; });
  return { continued, response, headers };
}

test('allows requests up to the configured limit and exposes policy headers', () => {
  const limiter = createRateLimiter({
    windowMs: 60_000,
    maxRequests: 2,
    exposePolicyHeaders: true,
    now: () => 1_000,
  });

  assert.equal(run(limiter).continued, true);
  const second = run(limiter);
  const blocked = run(limiter);

  assert.equal(second.headers['RateLimit-Remaining'], '0');
  assert.equal(blocked.response.statusCode, 429);
  assert.equal(blocked.headers['Retry-After'], '60');
});

test('starts a fresh window after the previous one expires', () => {
  let timestamp = 1_000;
  const limiter = createRateLimiter({
    windowMs: 1_000,
    maxRequests: 1,
    now: () => timestamp,
  });

  assert.equal(run(limiter).continued, true);
  assert.equal(run(limiter).response.statusCode, 429);
  timestamp = 2_000;
  assert.equal(run(limiter).continued, true);
});

test('skips requests outside the configured method scope', () => {
  const limiter = createRateLimiter({
    windowMs: 1_000,
    maxRequests: 1,
    appliesTo: (request) => request.method === 'POST',
  });

  assert.equal(run(limiter, { ip: '127.0.0.1', method: 'GET' }).continued, true);
  assert.equal(run(limiter, { ip: '127.0.0.1', method: 'GET' }).continued, true);
});
