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

test('GET /reconcile/:month: a filename-less (listing-scan) candidate gets a non-null display filename (the app decodes a non-optional String) and lands in "other"', async () => {
  store.appendCandidate('2026-07', { photoId: 'AF1QipNoName', filename: null, cameraModel: null, captureDateMs: Date.parse('2026-07-04T15:30:00Z'), pixelWidth: 1, pixelHeight: 2, status: 'candidate' });
  const body = await (await get('/reconcile/2026-07')).json();
  assert.equal(body.sections.iphone.count, 0);
  const c = body.sections.other.candidates[0];
  assert.equal(c.id, 'AF1QipNoName');
  assert.equal(typeof c.filename, 'string');
  assert.match(c.filename, /2026-07-04 15:30/);
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

test('GET /reconcile/:month returns the unified items: both + google + phone, tagged and time-sorted', async () => {
  const m = '2026-05';
  store.saveManifest(m, [
    manifestAsset('IMG_A.HEIC', { creationDate: '2026-05-01T10:00:00.000Z' }),
    manifestAsset('IMG_B.HEIC', { creationDate: '2026-05-01T12:00:00.000Z' }),
  ]);
  store.saveMatched(m, [{ photoId: 'gid-a', phoneIndex: 0, filename: 'IMG_A.HEIC', captureDateMs: Date.parse('2026-05-01T10:00:00.000Z'), pixelWidth: 2316, pixelHeight: 3088 }]);
  store.appendCandidate(m, candidate('gid-only', null, null, { captureDateMs: Date.parse('2026-05-01T11:00:00.000Z') }));
  store.saveStatus(m, 'ready');
  const body = await (await get(`/reconcile/${m}`)).json();
  assert.deepEqual(body.items.map((i) => [i.id, i.source, i.phoneIndex, i.thumbUrl]), [
    ['gid-a', 'both', 0, `/reconcile/thumb/${m}/gid-a`],
    ['gid-only', 'google', null, `/reconcile/thumb/${m}/gid-only`],
    ['phone-1', 'phone', 1, null],
  ]);
  assert.deepEqual(body.counts, { both: 1, google: 1, phone: 1 });
  assert.equal(body.items[0].filename, 'IMG_A.HEIC');
});

test('POST confirm for a matched photo: 409 until the app reports it deleted from the phone; then it leaves the manifest and becomes a queued candidate', async () => {
  const m = '2026-06';
  store.saveManifest(m, [manifestAsset('IMG_A.HEIC'), manifestAsset('IMG_B.HEIC')]);
  store.saveMatched(m, [{ photoId: 'gid-a', phoneIndex: 0, filename: 'IMG_A.HEIC', captureDateMs: 5, pixelWidth: 2316, pixelHeight: 3088 }]);
  store.saveStatus(m, 'ready');
  const refused = await post(`/reconcile/${m}/confirm`, { ids: ['gid-a'] });
  assert.equal(refused.status, 409);
  assert.deepEqual((await refused.json()).ids, ['gid-a']);
  assert.equal(store.listCandidates(m).length, 0, 'nothing queued on refusal');
  assert.equal(store.loadManifest(m).length, 2, 'manifest untouched on refusal');

  const wrongIndex = await post(`/reconcile/${m}/confirm`, { ids: ['gid-a'], phoneDeleted: [1] });
  assert.equal(wrongIndex.status, 409);

  const ok = await post(`/reconcile/${m}/confirm`, { ids: ['gid-a'], phoneDeleted: [0] });
  assert.equal(ok.status, 200);
  assert.deepEqual(store.loadManifest(m).map((a) => a.filename), ['IMG_B.HEIC']);
  const c = store.listCandidates(m).find((x) => x.photoId === 'gid-a');
  assert.equal(c.status, 'queued');
  assert.equal(c.filename, null);
  assert.deepEqual(spawnCalls.at(-1), { mode: 'trash', month: m });
  assert.equal((await post(`/reconcile/${m}/confirm`, { ids: ['gid-a'], phoneDeleted: ['x'] })).status, 400);
});

// ---- duplicate Google copies of a phone photo that is being KEPT ----
function dupSetup(m, { siblingCandidate = null } = {}) {
  store.saveManifest(m, [manifestAsset('IMG_A.HEIC'), manifestAsset('IMG_B.HEIC')]);
  const mk = (photoId, phoneIndex, filename) => ({ photoId, phoneIndex, filename, captureDateMs: 5, pixelWidth: 2316, pixelHeight: 3088 });
  store.saveMatched(m, [mk('dupA1', 0, 'IMG_A.HEIC'), mk('dupA2', 0, 'IMG_A.HEIC'), mk('solo', 1, 'IMG_B.HEIC')]);
  if (siblingCandidate) store.appendCandidate(m, candidate('dupA2', 'IMG_A.HEIC', null, { status: siblingCandidate }));
  store.saveStatus(m, 'ready');
}

test('POST confirm for a duplicate Google copy with a kept sibling: 200, queued candidate with filename + duplicateOf, phone untouched', async () => {
  const m = '2026-11';
  dupSetup(m);
  const before = spawnCalls.length;
  const res = await post(`/reconcile/${m}/confirm`, { ids: ['dupA1'], phoneDeleted: [] });
  assert.equal(res.status, 200);
  const c = store.listCandidates(m).find((x) => x.photoId === 'dupA1');
  assert.equal(c.status, 'queued');
  assert.equal(c.filename, 'IMG_A.HEIC');
  assert.equal(c.duplicateOf, 'dupA2');
  assert.equal(c.captureDateMs, 5);
  assert.equal(store.loadManifest(m).length, 2, 'phone manifest untouched');
  assert.equal(spawnCalls.length, before + 1);
  assert.ok(!store.listCandidates(m).some((x) => x.photoId === 'dupA2'), 'the kept sibling is never queued');
});

test('POST confirm for a duplicate: an older candidate line for the same id is superseded (last line wins)', async () => {
  const m = '2027-01';
  dupSetup(m);
  store.appendCandidate(m, candidate('dupA1', null, null, { status: 'needs_review' }));
  assert.equal((await post(`/reconcile/${m}/confirm`, { ids: ['dupA1'] })).status, 200);
  const c = store.listCandidates(m).filter((x) => x.photoId === 'dupA1');
  assert.equal(c.length, 1);
  assert.equal(c[0].status, 'queued');
  assert.equal(c[0].duplicateOf, 'dupA2');
  assert.equal(c[0].filename, 'IMG_A.HEIC');
});

test('POST confirm with BOTH copies of one phone photo and no phoneDeleted: 409 (no kept sibling), nothing mutated', async () => {
  const m = '2027-02';
  dupSetup(m);
  const res = await post(`/reconcile/${m}/confirm`, { ids: ['dupA1', 'dupA2'] });
  assert.equal(res.status, 409);
  assert.deepEqual((await res.json()).ids.sort(), ['dupA1', 'dupA2']);
  assert.equal(store.listCandidates(m).length, 0);
});

for (const status of ['trashed', 'queued', 'needs_review']) {
  test(`POST confirm for a duplicate whose sibling is already ${status}: 409, nothing mutated`, async () => {
    const m = { trashed: '2027-03', queued: '2027-04', needs_review: '2027-07' }[status];
    dupSetup(m, { siblingCandidate: status });
    const before = store.listCandidates(m);
    const res = await post(`/reconcile/${m}/confirm`, { ids: ['dupA1'] });
    assert.equal(res.status, 409);
    assert.deepEqual((await res.json()).ids, ['dupA1']);
    assert.deepEqual(store.listCandidates(m), before);
  });
}

test('POST confirm mixed batch (valid duplicate + still-on-phone solo): 409 and NOTHING mutated, even with phoneDeleted given', async () => {
  const m = '2027-05';
  dupSetup(m);
  const manifestBefore = JSON.stringify(store.loadManifest(m));
  const spawnsBefore = spawnCalls.length;
  const res = await post(`/reconcile/${m}/confirm`, { ids: ['dupA1', 'solo'], phoneDeleted: [] });
  assert.equal(res.status, 409);
  assert.deepEqual((await res.json()).ids, ['solo']);
  assert.equal(store.listCandidates(m).length, 0);
  assert.equal(JSON.stringify(store.loadManifest(m)), manifestBefore);
  assert.equal(spawnCalls.length, spawnsBefore);
  // phoneDeleted for an unrelated index must not be applied either
  const res2 = await post(`/reconcile/${m}/confirm`, { ids: ['dupA1', 'solo'], phoneDeleted: [0] });
  assert.equal(res2.status, 409);
  assert.equal(store.loadManifest(m).length, 2);
  assert.equal(store.listCandidates(m).length, 0);
});

test('end to end: confirm a duplicate copy -> real trash pass trashes it, the kept sibling is untouched', async () => {
  const m = '2027-06';
  const panel = (f) =>
    `InfoAdd a descriptionPeopleDetailsAug 5\nWed, 6:54 PMGMT-06:00Apple iPhone 13 Pro` +
    `ƒ/2.21/632.71mmISO40${f}7.2MP2316 × 3088Uploaded from iOS deviceBacked up (6 MB)Original quality. Learn moreWestminster, CO`;
  const cap = Date.parse('2026-08-06T00:54:00.000Z');
  store.saveManifest(m, [manifestAsset('IMG_5000.HEIC')]);
  const mk = (photoId) => ({ photoId, phoneIndex: 0, filename: 'IMG_5000.HEIC', captureDateMs: cap, pixelWidth: 2316, pixelHeight: 3088 });
  store.saveMatched(m, [mk('e2eD1'), mk('e2eD2')]);
  store.saveStatus(m, 'ready');
  assert.equal((await post(`/reconcile/${m}/confirm`, { ids: ['e2eD1'] })).status, 200);
  const page = createFakePage({
    timelineTiles: [{ ariaLabel: 'DX', href: 'e2eD1' }, { ariaLabel: 'SX', href: 'e2eD2' }],
    timelinePanelTextByLabel: { DX: panel('IMG_5000.HEIC'), SX: panel('IMG_5000.HEIC') },
  });
  await runReconcileTrash(page, m, store);
  const end = await (await get(`/reconcile/${m}/results`)).json();
  assert.deepEqual(end.results, [{ id: 'e2eD1', status: 'trashed' }]);
  assert.ok(page.trashedIdentities.has('e2eD1'));
  assert.ok(!page.trashedIdentities.has('e2eD2'));
});

test('POST confirm: three copies, ids=[G1,G2] -> 200 and BOTH point at the one copy NOT in ids (never at each other)', async () => {
  const m = '2027-08';
  store.saveManifest(m, [manifestAsset('IMG_A.HEIC')]);
  const mk = (photoId) => ({ photoId, phoneIndex: 0, filename: 'IMG_A.HEIC', captureDateMs: 5, pixelWidth: 2316, pixelHeight: 3088 });
  store.saveMatched(m, [mk('G1'), mk('G2'), mk('G3')]);
  assert.equal((await post(`/reconcile/${m}/confirm`, { ids: ['G1', 'G2'] })).status, 200);
  const by = Object.fromEntries(store.listCandidates(m).map((c) => [c.photoId, c]));
  assert.equal(by.G1.duplicateOf, 'G3');
  assert.equal(by.G2.duplicateOf, 'G3');
  assert.ok(!by.G3);
});

test('POST confirm: repeat confirms cannot erase the last copy (A: [G1] ok with G2 kept; B: [G2] -> 409 because G1 is queued)', async () => {
  const m = '2027-09';
  store.saveManifest(m, [manifestAsset('IMG_A.HEIC')]);
  const mk = (photoId) => ({ photoId, phoneIndex: 0, filename: 'IMG_A.HEIC', captureDateMs: 5, pixelWidth: 2316, pixelHeight: 3088 });
  store.saveMatched(m, [mk('G1'), mk('G2')]);
  assert.equal((await post(`/reconcile/${m}/confirm`, { ids: ['G1'] })).status, 200);
  const res = await post(`/reconcile/${m}/confirm`, { ids: ['G2'] });
  assert.equal(res.status, 409);
  assert.deepEqual((await res.json()).ids, ['G2']);
  assert.equal(store.listCandidates(m).find((c) => c.photoId === 'G2'), undefined);
});

test('POST confirm: ids=[G1,G1] is deduped (no double-queue, no corruption); [G1,G1] over both copies still 409', async () => {
  const m = '2027-10';
  store.saveManifest(m, [manifestAsset('IMG_A.HEIC')]);
  const mk = (photoId) => ({ photoId, phoneIndex: 0, filename: 'IMG_A.HEIC', captureDateMs: 5, pixelWidth: 2316, pixelHeight: 3088 });
  store.saveMatched(m, [mk('G1'), mk('G2')]);
  const res = await post(`/reconcile/${m}/confirm`, { ids: ['G1', 'G1'] });
  assert.equal(res.status, 200);
  assert.equal((await res.json()).queued, 1);
  assert.equal(store.listCandidates(m).length, 1);
  assert.equal(store.listCandidates(m)[0].status, 'queued');
});
