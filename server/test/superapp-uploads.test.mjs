import { test } from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, rmSync, writeFileSync, readFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';

const dir = mkdtempSync(join(tmpdir(), 'picnic-superapp-test-'));
const uploadsPath = join(dir, 'uploads.jsonl');
const resolutionsPath = join(dir, 'data', 'resolutions.jsonl');
const TOKEN = 'superapp-test-token';
writeFileSync(join(dir, 'token'), TOKEN);
process.env.PICNIC_TOKEN_PATH = join(dir, 'token');
process.env.PICNIC_QUEUE_PATH = join(dir, 'queue.jsonl');
process.env.PICNIC_THUMBS_DIR = join(dir, 'thumbs');
process.env.PICNIC_SUPERAPP_UPLOADS_PATH = uploadsPath;
process.env.PICNIC_SUPERAPP_RESOLUTIONS_PATH = resolutionsPath;

const rec = (id, receivedAt) => ({ id, receivedAt, filename: `${id}.HEIC`, savedAs: `/x/${id}.HEIC`, contentType: 'image/heic', bytes: 1, captureDate: null, captureDateHasOffset: false, pixelWidth: null, pixelHeight: null });
writeFileSync(uploadsPath, [rec('a', '2026-11-01T00:00:00.000Z'), rec('c', '2026-11-03T00:00:00.000Z'), rec('b', '2026-11-02T00:00:00.000Z')].map((r) => JSON.stringify(r)).join('\n') + '\n');

const { createApp } = await import('../queue-server.mjs');
const server = createApp();
await new Promise((r) => server.listen(0, '127.0.0.1', r));
const base = `http://127.0.0.1:${server.address().port}`;
test.after(() => { server.close(); rmSync(dir, { recursive: true, force: true }); });

const auth = { Authorization: `Bearer ${TOKEN}` };
const list = async () => (await (await fetch(`${base}/superapp-uploads`, { headers: auth })).json()).uploads.map((u) => u.id);
const resolve = (body) => fetch(`${base}/superapp-uploads/resolve`, { method: 'POST', headers: { ...auth, 'Content-Type': 'application/json' }, body: JSON.stringify(body) });

test('requires the bearer token', async () => {
  assert.equal((await fetch(`${base}/superapp-uploads`)).status, 401);
  assert.equal((await fetch(`${base}/superapp-uploads/resolve`, { method: 'POST', body: '{}' })).status, 401);
});

test('GET lists records newest first', async () => {
  assert.deepEqual(await list(), ['c', 'b', 'a']);
});

test('resolve rejects a bad action or ids and changes nothing', async () => {
  assert.equal((await resolve({ ids: ['a'], action: 'nuked' })).status, 400);
  assert.equal((await resolve({ ids: 'a', action: 'kept' })).status, 400);
  assert.deepEqual(await list(), ['c', 'b', 'a']);
});

test('resolve removes ids from GET, counts only new ones, persists to the resolutions file', async () => {
  const r = await resolve({ ids: ['b', 'zzz'], action: 'deleted' });
  assert.equal(r.status, 200);
  assert.deepEqual(await r.json(), { resolved: 2 });
  assert.deepEqual(await list(), ['c', 'a']);
  assert.deepEqual(await (await resolve({ ids: ['b'], action: 'kept' })).json(), { resolved: 0 });
  assert.deepEqual(await (await resolve({ ids: ['a'], action: 'kept' })).json(), { resolved: 1 });
  assert.deepEqual(await list(), ['c']);
  const lines = readFileSync(resolutionsPath, 'utf8').trim().split('\n').map(JSON.parse);
  assert.deepEqual(lines.map((l) => [l.id, l.action]), [['b', 'deleted'], ['zzz', 'deleted'], ['a', 'kept']]);
});

test('missing uploads file means an empty list', async () => {
  rmSync(uploadsPath);
  assert.deepEqual(await list(), []);
});
