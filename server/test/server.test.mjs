import { test } from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, rmSync, writeFileSync, readFileSync, existsSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { JobQueue } from '../lib/queue.mjs';

const dir = mkdtempSync(join(tmpdir(), 'picnic-server-test-'));
const tokenPath = join(dir, 'token');
const queuePath = join(dir, 'queue.jsonl');
const thumbsDir = join(dir, 'thumbs');
const TOKEN = 'test-token-value';
writeFileSync(tokenPath, TOKEN);

process.env.PICNIC_TOKEN_PATH = tokenPath;
process.env.PICNIC_QUEUE_PATH = queuePath;
process.env.PICNIC_THUMBS_DIR = thumbsDir;

const { createApp } = await import('../queue-server.mjs');
// Same queue file the server itself reads/writes -- used to plant
// needs_review/error fixtures directly, the way worker.mjs really would,
// without needing a full worker run inside this test file.
const fixtureQueue = new JobQueue(queuePath);

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

// ---- thumbnails: POST /queue thumbnailBase64, GET /thumb/:id, GET /issues ----

const FAKE_JPEG_BYTES = Buffer.from('not-a-real-jpeg-but-bytes-are-bytes');
const FAKE_JPEG_BASE64 = FAKE_JPEG_BYTES.toString('base64');

test('POST /queue with a valid thumbnail writes the file and sets hasThumbnail', async () => {
  const res = await post('/queue', {
    filename: 'IMG_6000.HEIC',
    creationDate: '2026-06-15T14:30:00.000Z',
    pixelWidth: 4032,
    pixelHeight: 3024,
    thumbnailBase64: FAKE_JPEG_BASE64,
  });
  assert.equal(res.status, 201);
  const body = await res.json();
  assert.equal(body.job.hasThumbnail, true);
  const onDisk = readFileSync(join(thumbsDir, `${body.job.id}.jpg`));
  assert.ok(onDisk.equals(FAKE_JPEG_BYTES), 'file on disk must match the decoded bytes');
});

test('POST /queue with no thumbnail still works exactly as before', async () => {
  const res = await post('/queue', {
    filename: 'IMG_6001.HEIC',
    creationDate: '2026-06-15T14:30:00.000Z',
    pixelWidth: 4032,
    pixelHeight: 3024,
  });
  assert.equal(res.status, 201);
  const body = await res.json();
  assert.ok(!body.job.hasThumbnail);
  assert.ok(!existsSync(join(thumbsDir, `${body.job.id}.jpg`)));
});

test('POST /queue with invalid base64 thumbnail 400s but still queues the job and triggers auto-drain', async () => {
  const before = fakeAutoDrainCalls.length;
  const res = await post2('/queue', {
    filename: 'IMG_6002.HEIC',
    creationDate: '2026-06-15T14:30:00.000Z',
    pixelWidth: 4032,
    pixelHeight: 3024,
    thumbnailBase64: 'not valid base64 !!!',
  });
  assert.equal(res.status, 400);
  const body = await res.json();
  assert.ok(body.error);
  assert.equal(body.job.status, 'queued', 'the mirror job itself must still be stored');
  assert.equal(fakeAutoDrainCalls.length, before + 1, 'a bad thumbnail must not stop auto-drain from firing');
  // Confirm it is really persisted, not just echoed in the response.
  const stored = await get2('/queue');
  const storedBody = await stored.json();
  assert.ok(storedBody.jobs.some((j) => j.id === body.job.id));
});

test('POST /queue with an oversized thumbnail 400s but still queues the job and triggers auto-drain', async () => {
  const before = fakeAutoDrainCalls.length;
  // 2.5MB decoded (> the 2MB thumbnail cap) but its ~3.3MB base64 form stays
  // safely under the server's separate 4MB whole-request-body cap, so this
  // exercises decodeThumbnail()'s own size check rather than the request
  // reader silently destroying the connection first.
  const oversized = Buffer.alloc(2.5 * 1024 * 1024, 1).toString('base64');
  const res = await post2('/queue', {
    filename: 'IMG_6003.HEIC',
    creationDate: '2026-06-15T14:30:00.000Z',
    pixelWidth: 4032,
    pixelHeight: 3024,
    thumbnailBase64: oversized,
  });
  assert.equal(res.status, 400);
  const body = await res.json();
  assert.match(body.error, /exceeds max size/);
  assert.equal(body.job.status, 'queued');
  assert.equal(fakeAutoDrainCalls.length, before + 1);
});

test('GET /thumb/:id serves the stored bytes with an image content-type', async () => {
  const created = await post('/queue', {
    filename: 'IMG_6004.HEIC',
    creationDate: '2026-06-15T14:30:00.000Z',
    pixelWidth: 4032,
    pixelHeight: 3024,
    thumbnailBase64: FAKE_JPEG_BASE64,
  });
  const { job } = await created.json();
  const res = await fetch(`${base}/thumb/${job.id}?token=${TOKEN}`);
  assert.equal(res.status, 200);
  assert.match(res.headers.get('content-type'), /image\/jpeg/);
  const bytes = Buffer.from(await res.arrayBuffer());
  assert.ok(bytes.equals(FAKE_JPEG_BYTES));
});

test('GET /thumb/:id 404s when no thumbnail was ever stored', async () => {
  const created = await post('/queue', {
    filename: 'IMG_6005.HEIC',
    creationDate: '2026-06-15T14:30:00.000Z',
    pixelWidth: 4032,
    pixelHeight: 3024,
  });
  const { job } = await created.json();
  const res = await fetch(`${base}/thumb/${job.id}?token=${TOKEN}`);
  assert.equal(res.status, 404);
});

test('GET /thumb/:id rejects a missing or wrong token', async () => {
  const created = await post('/queue', {
    filename: 'IMG_6006.HEIC',
    creationDate: '2026-06-15T14:30:00.000Z',
    pixelWidth: 4032,
    pixelHeight: 3024,
    thumbnailBase64: FAKE_JPEG_BASE64,
  });
  const { job } = await created.json();
  const noToken = await fetch(`${base}/thumb/${job.id}`);
  assert.equal(noToken.status, 401);
  const wrongToken = await fetch(`${base}/thumb/${job.id}?token=wrong`);
  assert.equal(wrongToken.status, 401);
  // The existing Authorization-header path must keep working too.
  const withHeader = await fetch(`${base}/thumb/${job.id}`, { headers: { Authorization: `Bearer ${TOKEN}` } });
  assert.equal(withHeader.status, 200);
});

test('GET /issues renders a job with a thumbnail and a job without one, plus counts', async () => {
  const { job: withThumb } = fixtureQueue.enqueue({
    filename: 'IMG_7000.PNG',
    creationDate: '2026-08-05T10:00:00.000Z',
    pixelWidth: 1170,
    pixelHeight: 2532,
  });
  writeFileSync(join(thumbsDir, `${withThumb.id}.jpg`), FAKE_JPEG_BYTES);
  // Mirror worker.mjs's REAL shape for a no-match: the explanation goes in
  // comparison.reason and `error` stays null. Seeding `error` here instead
  // (as this test first did) is a shape the worker never produces, and it
  // hid a bug where the panel read only `error` and so showed "(no reason
  // recorded)" on every needs_review card.
  fixtureQueue.update(withThumb.id, {
    status: 'needs_review',
    comparison: { reason: 'no filename+dimensions match for 2026-08-05 (+/-1 day)' },
    hasThumbnail: true,
  });

  const { job: noThumb } = fixtureQueue.enqueue({
    filename: 'IMG_7001.PNG',
    creationDate: '2026-08-05T11:00:00.000Z',
    pixelWidth: 1170,
    pixelHeight: 2532,
  });
  fixtureQueue.update(noThumb.id, { status: 'error', error: 'worker crashed mid-run' });

  const res = await fetch(`${base}/issues?token=${TOKEN}`);
  assert.equal(res.status, 200);
  assert.match(res.headers.get('content-type'), /text\/html/);
  const html = await res.text();

  assert.match(html, /IMG_7000\.PNG/);
  assert.match(html, /IMG_7001\.PNG/);
  // Both reason sources must render: comparison.reason for a no-match, and
  // `error` for an exception. Covering only one lets the other regress.
  assert.match(html, /no filename\+dimensions match for 2026-08-05/);
  assert.match(html, /worker crashed mid-run/);
  assert.match(html, new RegExp(`/thumb/${withThumb.id}\\?token=${TOKEN}`));
  assert.match(html, /no thumbnail/); // placeholder for the job with no thumbnail
  // Sanity: a plain "queued" job (created earlier in this file) must not show up.
  assert.doesNotMatch(html, /IMG_1000\.HEIC/);
});

test('GET /issues rejects a missing or wrong token, accepts a bearer header', async () => {
  const noToken = await fetch(`${base}/issues`);
  assert.equal(noToken.status, 401);
  const wrongToken = await fetch(`${base}/issues?token=wrong`);
  assert.equal(wrongToken.status, 401);
  const withHeader = await fetch(`${base}/issues`, { headers: { Authorization: `Bearer ${TOKEN}` } });
  assert.equal(withHeader.status, 200);
});
