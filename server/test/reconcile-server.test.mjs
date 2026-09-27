import { test } from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { connect } from 'node:net';
import { ReconcileStore } from '../lib/reconcile.mjs';
import { createFakePage } from './helpers/fakePage.mjs';

// Everything under one temp dir, and every env var set BEFORE importing
// queue-server.mjs — the module reads them once at load time (into the
// top-level queue/reconcile consts), so a later assignment would be ignored.
const dir = mkdtempSync(join(tmpdir(), 'picnic-reconcile-server-test-'));
const tokenPath = join(dir, 'token');
const queuePath = join(dir, 'queue.jsonl');
const thumbsDir = join(dir, 'thumbs');
const reconcileDir = join(dir, 'reconcile');
const TOKEN = 'reconcile-test-token';
writeFileSync(tokenPath, TOKEN);

process.env.PICNIC_TOKEN_PATH = tokenPath;
process.env.PICNIC_QUEUE_PATH = queuePath;
process.env.PICNIC_THUMBS_DIR = thumbsDir;
process.env.PICNIC_RECONCILE_DIR = reconcileDir;
// Collapses worker pacing for the end-to-end test that runs the real trash pass; set before worker.mjs loads.
process.env.PICNIC_WORKER_FAST_DELAYS = '1';

const { createApp } = await import('../queue-server.mjs');
const { runReconcileTrash } = await import('../worker.mjs');
// Same dir the server's module-level `reconcile` store points at, so planting
// candidates here is visible to the routes (and vice versa) — no mock seams.
const store = new ReconcileStore(reconcileDir);

const spawnCalls = [];
const server = createApp({
  spawnReconcile: (mode, month) => {
    spawnCalls.push({ mode, month });
  },
});
await new Promise((resolve) => server.listen(0, '127.0.0.1', resolve));
const { port } = server.address();
const base = `http://127.0.0.1:${port}`;

test.after(() => {
  server.close();
  rmSync(dir, { recursive: true, force: true });
});

async function req(method, path, body) {
  const res = await fetch(`${base}${path}`, {
    method,
    headers: { Authorization: `Bearer ${TOKEN}`, 'Content-Type': 'application/json' },
    body: body === undefined ? undefined : JSON.stringify(body),
  });
  return res;
}

const get = (path) => req('GET', path);
const post = (path, body) => req('POST', path, body);

function manifestAsset(filename, overrides = {}) {
  return {
    filename,
    creationDate: '2026-09-01T12:00:00.000Z',
    pixelWidth: 2316,
    pixelHeight: 3088,
    ...overrides,
  };
}

function candidate(photoId, filename, cameraModel, overrides = {}) {
  return {
    photoId,
    filename,
    cameraModel,
    captureDateMs: 1,
    pixelWidth: 2316,
    pixelHeight: 3088,
    status: 'candidate',
    ...overrides,
  };
}

test('POST /reconcile saves the manifest, sets scanning, spawns the scan worker', async () => {
  const assets = [manifestAsset('IMG_0001.HEIC')];
  const res = await post('/reconcile', { month: '2026-09', assets });
  assert.equal(res.status, 200);
  const body = await res.json();
  assert.equal(body.month, '2026-09');
  assert.equal(body.status, 'scanning');
  assert.equal(body.assetCount, 1);
  assert.deepEqual(store.loadManifest('2026-09'), assets);
  assert.equal(store.loadStatus('2026-09'), 'scanning');
  assert.deepEqual(spawnCalls, [{ mode: 'scan', month: '2026-09' }]);
});

test('POST /reconcile rejects a malformed month and non-array assets, without spawning', async () => {
  const before = spawnCalls.length;
  assert.equal((await post('/reconcile', { month: 'not-a-month', assets: [] })).status, 400);
  assert.equal((await post('/reconcile', { month: '2026-09', assets: 'nope' })).status, 400);
  assert.equal(spawnCalls.length, before); // no worker spawned on a rejected POST
});

test('GET /reconcile/:month partitions candidates into iphone/other with thumb urls', async () => {
  store.appendCandidate('2026-09', candidate('id_iphone', 'IMG_A.HEIC', 'Apple iPhone 13 Pro'));
  store.appendCandidate('2026-09', candidate('id-other', 'IMG_B.HEIC', null));

  const res = await get('/reconcile/2026-09');
  assert.equal(res.status, 200);
  const body = await res.json();
  assert.equal(body.totalCandidates, 2);
  assert.equal(body.status, 'scanning'); // status file still says scanning from the POST above
  assert.equal(body.sections.iphone.count, 1);
  assert.equal(body.sections.iphone.candidates[0].id, 'id_iphone');
  assert.equal(body.sections.iphone.candidates[0].thumbUrl, '/reconcile/thumb/2026-09/id_iphone');
  assert.equal(body.sections.other.count, 1);
  assert.equal(body.sections.other.candidates[0].id, 'id-other');
});

test('POST /reconcile/:month/confirm marks ids queued, sets confirming, spawns trash worker', async () => {
  const res = await post('/reconcile/2026-09/confirm', { ids: ['id_iphone'] });
  assert.equal(res.status, 200);
  const body = await res.json();
  assert.equal(body.queued, 1);
  const list = store.listCandidates('2026-09');
  assert.equal(list.find((c) => c.photoId === 'id_iphone').status, 'queued');
  assert.equal(list.find((c) => c.photoId === 'id-other').status, 'candidate'); // untouched
  assert.equal(store.loadStatus('2026-09'), 'confirming');
  assert.deepEqual(spawnCalls.at(-1), { mode: 'trash', month: '2026-09' });
});

test('POST /reconcile/:month/confirm rejects unknown ids (404) and empty ids (400)', async () => {
  assert.equal((await post('/reconcile/2026-09/confirm', { ids: ['does-not-exist'] })).status, 404);
  assert.equal((await post('/reconcile/2026-09/confirm', { ids: [] })).status, 400);
  assert.equal((await post('/reconcile/2026-09/confirm', { ids: 'nope' })).status, 400);
});

test('GET /reconcile/:month/results reflects per-photo statuses and done only when status is done', async () => {
  // Not done yet (status is 'confirming' from the confirm test).
  const pending = await (await get('/reconcile/2026-09/results')).json();
  assert.equal(pending.done, false);
  assert.deepEqual(pending.results, [
    { id: 'id_iphone', status: 'queued' },
    { id: 'id-other', status: 'candidate' },
  ]);

  // The trash worker marks the queued one 'trashed' then the month 'done'.
  store.updateCandidateStatus('2026-09', 'id_iphone', 'trashed');
  store.saveStatus('2026-09', 'done');
  const done = await (await get('/reconcile/2026-09/results')).json();
  assert.equal(done.done, true);
  assert.deepEqual(done.results, [
    { id: 'id_iphone', status: 'trashed' },
    { id: 'id-other', status: 'candidate' },
  ]);
});

test('GET /reconcile/thumb/:month/:id serves a JPEG and rejects traversal/unknown ids', async () => {
  store.saveThumb('2026-09', 'id_iphone', Buffer.from('jpeg-bytes-here'));
  const res = await get('/reconcile/thumb/2026-09/id_iphone');
  assert.equal(res.status, 200);
  assert.equal(res.headers.get('content-type'), 'image/jpeg');
  assert.equal(Buffer.from(await res.arrayBuffer()).toString(), 'jpeg-bytes-here');

  // Unknown id -> 404.
  assert.equal((await get('/reconcile/thumb/2026-09/never_saved')).status, 404);
  // Path-traversal ids are rejected before any filesystem access.
  assert.equal((await get('/reconcile/thumb/2026-09/..%2F..%2Ftoken')).status, 404);
  assert.equal((await get('/reconcile/thumb/not-a-month/id_iphone')).status, 404);
});

test('reconcile routes require auth', async () => {
  const unauth = await fetch(`${base}/reconcile/2026-09`);
  assert.equal(unauth.status, 401);
  const unauthThumb = await fetch(`${base}/reconcile/thumb/2026-09/id_iphone`);
  assert.equal(unauthThumb.status, 401);
});

// fetch() normalizes '..' out of URLs before sending, so a traversal test through
// it never reaches the server as a literal '..'. A raw socket sends the bytes as-is.
function rawGet(path) {
  return new Promise((resolve, reject) => {
    const sock = connect(port, '127.0.0.1', () => {
      sock.write(`GET ${path} HTTP/1.1\r\nHost: x\r\nAuthorization: Bearer ${TOKEN}\r\nConnection: close\r\n\r\n`);
    });
    let data = '';
    sock.on('data', (d) => (data += d));
    sock.on('end', () => resolve({ status: Number(/^HTTP\/1\.1 (\d+)/.exec(data)[1]), raw: data }));
    sock.on('error', reject);
  });
}

test('thumb route: literal ".." and dotted ids are refused (raw socket, no client-side normalization)', async () => {
  store.saveThumb('2026-09', 'id_iphone', Buffer.from('jpeg-bytes-here'));
  // Plant thumbs whose on-disk names WOULD resolve for a dotted id, so only the
  // id regex (not a coincidental missing file) can produce the 404.
  store.saveThumb('2026-09', 'id.dotted', Buffer.from('dotted-bytes'));
  store.saveThumb('2026-09', '..', Buffer.from('dotdot-bytes'));
  for (const path of [
    '/reconcile/thumb/2026-09/id.dotted',
    '/reconcile/thumb/2026-09/..',
    '/reconcile/thumb/2026-09/../id_iphone',
    '/reconcile/thumb/../2026-09/id_iphone',
    '/reconcile/thumb/2026-09/id.iphone',
    '/reconcile/thumb/2026-09/id_iphone.jpg',
    '/reconcile/thumb/2026-09/.hidden',
  ]) {
    const r = await rawGet(path);
    assert.ok(r.status === 400 || r.status === 404, `${path} -> ${r.status}`);
    assert.ok(!/jpeg-bytes-here|dotted-bytes|dotdot-bytes/.test(r.raw), `${path} leaked thumb bytes`);
  }
});

test('POST /reconcile, POST confirm and GET results all require auth (401)', async () => {
  const noAuth = (method, path, body) =>
    fetch(`${base}${path}`, { method, headers: { 'Content-Type': 'application/json' }, body: body && JSON.stringify(body) });
  const before = spyLen();
  assert.equal((await noAuth('POST', '/reconcile', { month: '2026-09', assets: [] })).status, 401);
  assert.equal((await noAuth('POST', '/reconcile/2026-09/confirm', { ids: ['id_iphone'] })).status, 401);
  assert.equal((await noAuth('GET', '/reconcile/2026-09/results')).status, 401);
  assert.equal(spyLen(), before, 'an unauthenticated request must not spawn a worker');
});
function spyLen() {
  return spawnCalls.length;
}

test('month must match YYYY-MM on confirm (400) and on GET month / results (400)', async () => {
  assert.equal((await post('/reconcile/2026-9/confirm', { ids: ['x'] })).status, 400);
  assert.equal((await post('/reconcile/abcd/confirm', { ids: ['x'] })).status, 400);
  assert.equal((await get('/reconcile/2026-9')).status, 400);
  assert.equal((await get('/reconcile/latest')).status, 400);
  assert.equal((await get('/reconcile/20260-09/results')).status, 400);
});

test('GET /reconcile/:month with no status file yet reports "scanning" and zero candidates', async () => {
  const body = await (await get('/reconcile/2031-01')).json();
  assert.equal(body.status, 'scanning');
  assert.equal(body.totalCandidates, 0);
});

test('end to end on ONE store: POST confirm -> queued -> real trash pass -> trashed, unconfirmed untouched', async () => {
  const month = '2026-10';
  const panel = (f) =>
    `InfoAdd a descriptionPeopleDetailsAug 5Wed, 6:54 PMGMT-06:00Apple iPhone 13 Pro` +
    `ƒ/2.21/632.71mmISO40${f}7.2MP2316 × 3088Uploaded from iOS deviceBacked up (6 MB)Original quality. Learn moreWestminster, CO`;
  store.appendCandidate(month, candidate('e2eA', 'IMG_2001.HEIC', 'Apple iPhone 13 Pro'));
  store.appendCandidate(month, candidate('e2eB', 'IMG_2002.HEIC', 'Apple iPhone 13 Pro'));

  const res = await post(`/reconcile/${month}/confirm`, { ids: ['e2eA'] });
  assert.equal((await res.json()).queued, 1);
  const mid = await (await get(`/reconcile/${month}/results`)).json();
  assert.deepEqual(mid, { month, done: false, results: [{ id: 'e2eA', status: 'queued' }, { id: 'e2eB', status: 'candidate' }] });
  assert.deepEqual(spawnCalls.at(-1), { mode: 'trash', month });

  // What the spawned worker does, run in-process against a fake Photos page.
  const page = createFakePage({
    timelineTiles: [{ ariaLabel: 'A', href: 'e2eA' }, { ariaLabel: 'B', href: 'e2eB' }],
    timelinePanelTextByLabel: { A: panel('IMG_2001.HEIC'), B: panel('IMG_2002.HEIC') },
  });
  await runReconcileTrash(page, month, store);

  const end = await (await get(`/reconcile/${month}/results`)).json();
  assert.equal(end.done, true);
  assert.deepEqual(end.results, [{ id: 'e2eA', status: 'trashed' }, { id: 'e2eB', status: 'candidate' }]);
  assert.ok(page.trashedIdentities.has('e2eA'));
  assert.ok(!page.trashedIdentities.has('e2eB'));
});
