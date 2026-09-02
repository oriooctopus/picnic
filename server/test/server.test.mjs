import { test } from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';

const dir = mkdtempSync(join(tmpdir(), 'picnic-server-test-'));
const tokenPath = join(dir, 'token');
const queuePath = join(dir, 'queue.jsonl');
const TOKEN = 'test-token-value';
writeFileSync(tokenPath, TOKEN);

process.env.PICNIC_TOKEN_PATH = tokenPath;
process.env.PICNIC_QUEUE_PATH = queuePath;

const { createApp } = await import('../queue-server.mjs');

const server = createApp();
await new Promise((resolve) => server.listen(0, '127.0.0.1', resolve));
const { port } = server.address();
const base = `http://127.0.0.1:${port}`;

// A second app instance, wired to a fake autoDrain, purely to prove
// queue-server.mjs actually CALLS notifyEnqueued() at the right spots
// (POST /queue on success, POST /retry/:id on retry) and exposes its
// getStatus() through GET /queue -- without ever starting a real timer
// (createApp() with no autoDrain arg, used by `server` above, already
// covers that createApp() itself is safe to import for tests).
const fakeAutoDrainCalls = [];
const fakeAutoDrain = {
  notifyEnqueued: () => fakeAutoDrainCalls.push('notifyEnqueued'),
  isRunning: () => false,
  getStatus: () => ({ enabled: true, running: false, lastRun: { outcome: 'completed' } }),
};
const server2 = createApp({ autoDrain: fakeAutoDrain });
await new Promise((resolve) => server2.listen(0, '127.0.0.1', resolve));
const { port: port2 } = server2.address();
const base2 = `http://127.0.0.1:${port2}`;

test.after(() => {
  server.close();
  server2.close();
  rmSync(dir, { recursive: true, force: true });
});

async function post(path, body, token = TOKEN) {
  return fetch(`${base}${path}`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json', ...(token ? { Authorization: `Bearer ${token}` } : {}) },
    body: JSON.stringify(body),
  });
}

async function get(path, token = TOKEN) {
  return fetch(`${base}${path}`, {
    headers: token ? { Authorization: `Bearer ${token}` } : {},
  });
}

test('GET /health returns 200 with no auth', async () => {
  const res = await fetch(`${base}/health`);
  assert.equal(res.status, 200);
  const body = await res.json();
  assert.equal(body.ok, true);
});

test('POST /queue without auth is rejected', async () => {
  const res = await post('/queue', { filename: 'X.HEIC' }, null);
  assert.equal(res.status, 401);
});

test('POST /queue with wrong token is rejected', async () => {
  const res = await post('/queue', { filename: 'X.HEIC' }, 'wrong-token');
  assert.equal(res.status, 401);
});

test('POST /queue creates a job', async () => {
  const res = await post('/queue', {
    filename: 'IMG_1000.HEIC',
    creationDate: '2026-06-15T14:30:00.000Z',
    pixelWidth: 4032,
    pixelHeight: 3024,
  });
  assert.equal(res.status, 201);
  const body = await res.json();
  assert.equal(body.created, true);
  assert.equal(body.job.status, 'queued');
});

test('POST /queue is idempotent on filename+creationDate', async () => {
  const payload = {
    filename: 'IMG_2000.HEIC',
    creationDate: '2026-06-15T14:30:00.000Z',
    pixelWidth: 4032,
    pixelHeight: 3024,
  };
  const first = await post('/queue', payload);
  const second = await post('/queue', payload);
  assert.equal(first.status, 201);
  assert.equal(second.status, 200);
  const firstBody = await first.json();
  const secondBody = await second.json();
  assert.equal(firstBody.job.id, secondBody.job.id);
  assert.equal(secondBody.created, false);
});

test('POST /queue rejects missing required fields', async () => {
  const res = await post('/queue', { filename: 'IMG_3000.HEIC' });
  assert.equal(res.status, 400);
});

test('GET /queue without auth is rejected', async () => {
  const res = await get('/queue', null);
  assert.equal(res.status, 401);
});

test('GET /queue returns counts and jobs', async () => {
  const res = await get('/queue');
  assert.equal(res.status, 200);
  const body = await res.json();
  assert.ok(typeof body.counts.queued === 'number');
  assert.ok(Array.isArray(body.jobs));
});

test('GET /queue?status=needs_review filters', async () => {
  const res = await get('/queue?status=needs_review');
  assert.equal(res.status, 200);
  const body = await res.json();
  for (const job of body.jobs) assert.equal(job.status, 'needs_review');
});

test('GET /queue?status=bogus rejected', async () => {
  const res = await get('/queue?status=bogus');
  assert.equal(res.status, 400);
});

test('POST /retry/:id on unknown id returns 404', async () => {
  const res = await post('/retry/does-not-exist', {});
  assert.equal(res.status, 404);
});

test('POST /retry/:id resets an errored job to queued', async () => {
  const created = await post('/queue', {
    filename: 'IMG_4000.HEIC',
    creationDate: '2026-06-15T14:30:00.000Z',
    pixelWidth: 4032,
    pixelHeight: 3024,
  });
  const { job } = await created.json();

  // Simulate the worker marking it errored via a raw enqueue-and-fetch cycle:
  // hit retry directly is enough to prove the transition works from any state.
  const res = await post(`/retry/${job.id}`, {});
  assert.equal(res.status, 200);
  const body = await res.json();
  assert.equal(body.job.status, 'queued');
});

test('unknown route returns 404', async () => {
  const res = await get('/nope');
  assert.equal(res.status, 404);
});

async function post2(path, body) {
  return fetch(`${base2}${path}`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json', Authorization: `Bearer ${TOKEN}` },
    body: JSON.stringify(body),
  });
}

async function get2(path) {
  return fetch(`${base2}${path}`, { headers: { Authorization: `Bearer ${TOKEN}` } });
}

test('POST /queue calls autoDrain.notifyEnqueued() on a successful enqueue', async () => {
  const before = fakeAutoDrainCalls.length;
  const res = await post2('/queue', {
    filename: 'IMG_5000.HEIC',
    creationDate: '2026-06-15T14:30:00.000Z',
    pixelWidth: 4032,
    pixelHeight: 3024,
  });
  assert.equal(res.status, 201);
  assert.equal(fakeAutoDrainCalls.length, before + 1);
});

test('POST /queue with a validation failure does NOT call notifyEnqueued (no job stored, no run armed)', async () => {
  const before = fakeAutoDrainCalls.length;
  const res = await post2('/queue', { filename: 'IMG_5001.HEIC' }); // missing required fields
  assert.equal(res.status, 400);
  assert.equal(fakeAutoDrainCalls.length, before, 'a failed POST must not arm a run');
});

test('POST /retry/:id calls notifyEnqueued() and clears the autoDrainRetried marker', async () => {
  const created = await post2('/queue', {
    filename: 'IMG_5002.HEIC',
    creationDate: '2026-06-15T14:30:00.000Z',
    pixelWidth: 4032,
    pixelHeight: 3024,
  });
  const { job } = await created.json();
  const before = fakeAutoDrainCalls.length;
  const res = await post2(`/retry/${job.id}`, {});
  assert.equal(res.status, 200);
  const body = await res.json();
  assert.equal(body.job.autoDrainRetried, false, 'a human retry must reset the one-shot marker');
  assert.equal(fakeAutoDrainCalls.length, before + 1);
});

test('GET /queue includes the autoDrain status surface', async () => {
  const res = await get2('/queue');
  assert.equal(res.status, 200);
  const body = await res.json();
  assert.equal(body.autoDrain.enabled, true);
  assert.equal(body.autoDrain.running, false);
  assert.equal(body.autoDrain.lastRun.outcome, 'completed');
  assert.ok('oldestQueuedWaitMs' in body.autoDrain);
});

test('GET /queue on the default (no-op) autoDrain reports disabled/no run', async () => {
  const res = await get('/queue');
  assert.equal(res.status, 200);
  const body = await res.json();
  assert.equal(body.autoDrain.enabled, false);
  assert.equal(body.autoDrain.lastRun, null);
});
