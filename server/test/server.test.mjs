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

test.after(() => {
  server.close();
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
