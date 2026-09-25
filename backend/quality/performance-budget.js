const assert = require('node:assert/strict');
const test = require('node:test');
const { performance } = require('node:perf_hooks');
const { createApp } = require('../src/app');

function percentile(values, fraction) {
  const sorted = values.slice().sort((left, right) => left - right);
  return sorted[Math.max(0, Math.ceil(sorted.length * fraction) - 1)];
}

async function timed(request) {
  const startedAt = performance.now();
  const response = await request();
  await response.arrayBuffer();
  return { status: response.status, durationMs: performance.now() - startedAt };
}

test('representative reads and writes stay within the CI performance budget', async () => {
  const app = createApp();
  const server = await new Promise((resolve) => {
    const instance = app.listen(0, '127.0.0.1', () => resolve(instance));
  });
  const baseUrl = `http://127.0.0.1:${server.address().port}`;
  try {
    const login = await fetch(`${baseUrl}/api/auth/login`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({
        email: 'admin@materialkompass.org',
        password: 'MaterialKompass2026!',
      }),
    });
    const token = (await login.json()).token;
    const headers = { Authorization: `Bearer ${token}` };

    await fetch(`${baseUrl}/api/material?limit=1000`, { headers });
    const reads = await Promise.all(Array.from({ length: 50 }, () => timed(() =>
      fetch(`${baseUrl}/api/material?limit=1000`, { headers }))));
    assert.ok(reads.every((entry) => entry.status === 200));
    assert.ok(
      percentile(reads.map((entry) => entry.durationMs), 0.95) <= 500,
      `p95 der Lesezugriffe überschreitet 500 ms`,
    );

    const writes = [];
    for (let index = 0; index < 20; index += 1) {
      writes.push(await timed(() => fetch(`${baseUrl}/api/material`, {
        method: 'POST',
        headers: { ...headers, 'Content-Type': 'application/json' },
        body: JSON.stringify({
          name: `Lasttest ${index}`,
          categoryCode: '02',
          subcategoryCode: '02-02',
          locationId: 'loc-1',
          status: 'Lagernd',
          itemType: 'individual',
        }),
      })));
    }
    assert.ok(writes.every((entry) => entry.status === 201));
    assert.ok(
      percentile(writes.map((entry) => entry.durationMs), 0.95) <= 1000,
      `p95 der Schreibzugriffe überschreitet 1.000 ms`,
    );
  } finally {
    server.closeAllConnections?.();
    await new Promise((resolve) => server.close(resolve));
  }
});
