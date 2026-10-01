import { test } from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { ReconcileStore } from '../lib/reconcile.mjs';

// Same isolated-temp-dir setup as reconcile-server.test.mjs, in its own file
// because this suite needs a mutable `isReconcileScanRunning` stub the other
// file's fixed one doesn't have.
const dir = mkdtempSync(join(tmpdir(), 'picnic-reconcile-rescan-test-'));
const tokenPath = join(dir, 'token');
const reconcileDir = join(dir, 'reconcile');
const TOKEN = 'rescan-test-token';
writeFileSync(tokenPath, TOKEN);

process.env.PICNIC_TOKEN_PATH = tokenPath;
process.env.PICNIC_QUEUE_PATH = join(dir, 'queue.jsonl');
process.env.PICNIC_THUMBS_DIR = join(dir, 'thumbs');
process.env.PICNIC_RECONCILE_DIR = reconcileDir;

const { createApp } = await import('../queue-server.mjs');
const store = new ReconcileStore(reconcileDir);

const spawnCalls = [];
// Flipped per-test; defaults to "nothing running" like the real
// isReconcileScanRunningDefault would report for a month with no live child.
let scanRunning = false;
const server = createApp({
  spawnReconcile: (mode, month) => spawnCalls.push({ mode, month }),
  isReconcileScanRunning: () => scanRunning,
});
await new Promise((resolve) => server.listen(0, '127.0.0.1', resolve));
const { port } = server.address();
const base = `http://127.0.0.1:${port}`;

test.after(() => {
  server.close();
  rmSync(dir, { recursive: true, force: true });
});

function post(path, body) {
  return fetch(`${base}${path}`, {
    method: 'POST',
    headers: { Authorization: `Bearer ${TOKEN}`, 'Content-Type': 'application/json' },
    body: JSON.stringify(body),
  });
}
function get(path) {
  return fetch(`${base}${path}`, { headers: { Authorization: `Bearer ${TOKEN}` } });
}

test('re-POST /reconcile for a month resets stale candidates/thumbs instead of appending duplicates', async () => {
  const month = '2026-11';
  store.appendCandidate(month, {
    photoId: 'stale1',
    filename: 'OLD.HEIC',
    cameraModel: null,
    captureDateMs: 1,
    pixelWidth: 1,
    pixelHeight: 1,
    status: 'candidate',
  });
  store.saveThumb(month, 'stale1', Buffer.from('old-thumb'));
  store.saveError(month, 'a previous run failed');
  assert.equal(store.listCandidates(month).length, 1);

  const res = await post('/reconcile', {
    month,
    assets: [{ filename: 'NEW.HEIC', creationDate: '2026-11-01T00:00:00Z', pixelWidth: 1, pixelHeight: 1 }],
  });
  assert.equal(res.status, 200);
  assert.equal(store.listCandidates(month).length, 0, 'reset must clear stale candidates before the new scan starts');
  assert.deepEqual(store.loadManifest(month).map((a) => a.filename), ['NEW.HEIC']);
  assert.equal(store.loadError(month), null, 'a rescan clears a previous run\'s recorded error');

  const body = await (await get(`/reconcile/${month}`)).json();
  assert.equal(body.totalCandidates, 0);
  assert.equal(body.error, null);
});

test('POST /reconcile refuses a second scan while one is already running for that month (409)', async () => {
  const month = '2026-12';
  const before = spawnCalls.length;
  scanRunning = true;
  try {
    const res = await post('/reconcile', { month, assets: [] });
    assert.equal(res.status, 409);
    assert.equal(spawnCalls.length, before, 'must not spawn a second scan while one is running');
  } finally {
    scanRunning = false;
  }
});

const ASSET_A = { filename: 'A.HEIC', creationDate: '2026-10-01T00:00:00Z', pixelWidth: 1, pixelHeight: 1 };
const ASSET_B = { filename: 'B.HEIC', creationDate: '2026-10-02T00:00:00Z', pixelWidth: 1, pixelHeight: 1 };

test('re-POST with an unchanged manifest reuses a ready result instead of rescanning', async () => {
  const month = '2026-10';
  store.saveManifest(month, [ASSET_A, ASSET_B]);
  store.saveStatus(month, 'ready');
  store.saveScanVersion(month);
  store.appendCandidate(month, { photoId: 'keep1', filename: 'G.HEIC', cameraModel: null, captureDateMs: 1, pixelWidth: 1, pixelHeight: 1, status: 'candidate' });
  const before = spawnCalls.length;

  const res = await post('/reconcile', { month, assets: [ASSET_B, ASSET_A] }); // same set, different order
  assert.equal(res.status, 200);
  assert.equal((await res.json()).status, 'ready');
  assert.equal(spawnCalls.length, before, 'must not spawn a rescan for an unchanged manifest');
  assert.equal(store.listCandidates(month).length, 1, 'the finished result must survive');

  const changed = await post('/reconcile', { month, assets: [ASSET_A] });
  assert.equal(changed.status, 200);
  assert.equal(spawnCalls.length, before + 1, 'a changed manifest rescans');
  assert.equal(store.listCandidates(month).length, 0);
});

test('a ready result from an older scan method (no version stamp) is rescanned even with the same manifest', async () => {
  const month = '2026-09';
  store.saveManifest(month, [ASSET_A, ASSET_B]);
  store.saveStatus(month, 'ready');
  store.appendCandidate(month, { photoId: 'stale1', filename: 'G.HEIC', cameraModel: null, captureDateMs: 1, pixelWidth: 1, pixelHeight: 1, status: 'candidate' });
  const before = spawnCalls.length;

  const res = await post('/reconcile', { month, assets: [ASSET_A, ASSET_B] });
  assert.equal(res.status, 200);
  assert.equal((await res.json()).status, 'scanning');
  assert.equal(spawnCalls.length, before + 1, 'unstamped ready result must be rescanned');
  assert.equal(store.listCandidates(month).length, 0, 'stale candidates must be cleared');
});

test('re-POST with the same manifest while its scan is running joins it (200), not 409', async () => {
  const month = '2027-01';
  store.saveManifest(month, [ASSET_A]);
  store.saveStatus(month, 'scanning');
  const before = spawnCalls.length;
  scanRunning = true;
  try {
    const res = await post('/reconcile', { month, assets: [ASSET_A] });
    assert.equal(res.status, 200);
    assert.equal((await res.json()).status, 'scanning');
    assert.equal(spawnCalls.length, before);
  } finally {
    scanRunning = false;
  }
});

test('a month whose trash pass finished (done) rescans even with the same manifest', async () => {
  const month = '2027-02';
  store.saveManifest(month, [ASSET_A]);
  store.saveStatus(month, 'done');
  const before = spawnCalls.length;
  const res = await post('/reconcile', { month, assets: [ASSET_A] });
  assert.equal(res.status, 200);
  assert.equal(spawnCalls.length, before + 1);
});
