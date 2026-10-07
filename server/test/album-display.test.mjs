import { test } from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, rmSync, writeFileSync, readFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { AlbumStore } from '../lib/album.mjs';
import { fetchDisplays, DISPLAY_BOX } from '../album-fetch.mjs';

const dir = mkdtempSync(join(tmpdir(), 'picnic-album-display-test-'));
const tokenPath = join(dir, 'token');
const TOKEN = 'display-test-token';
writeFileSync(tokenPath, TOKEN);
process.env.PICNIC_TOKEN_PATH = tokenPath;
process.env.PICNIC_QUEUE_PATH = join(dir, 'queue.jsonl');
process.env.PICNIC_THUMBS_DIR = join(dir, 'thumbs');
process.env.PICNIC_RECONCILE_DIR = join(dir, 'reconcile');
process.env.PICNIC_ALBUMS_DIR = join(dir, 'albums');

const { createApp } = await import('../queue-server.mjs');
const server = createApp();
await new Promise((r) => server.listen(0, '127.0.0.1', r));
const base = `http://127.0.0.1:${server.address().port}`;
test.after(() => {
  server.close();
  rmSync(dir, { recursive: true, force: true });
});

const A = (key) => [key, [`https://lh3.example/${key}`, 100, 50], 1700000000000, 'dedupe', 0, 1];
const auth = { Authorization: `Bearer ${TOKEN}` };
const resp = (body, type = 'image/jpeg', status = 200) => new Response(body, { status, headers: { 'content-type': type } });
const quiet = { paceMs: 0, log: () => {} };

test('display route: 404 until cached, auth by header or ?token=, items carry hasDisplay, thumb unaffected', async () => {
  const store = new AlbumStore(process.env.PICNIC_ALBUMS_DIR, 'd1');
  store.ingestItems([A('k1'), A('k2')]);
  const listed = async () => (await (await fetch(`${base}/album/d1`, { headers: auth })).json()).items;

  assert.deepEqual((await listed()).map((i) => i.hasDisplay), [false, false]);
  assert.equal((await fetch(`${base}/album/d1/display/k1?token=${TOKEN}`)).status, 404, 'not cached yet is a plain 404');

  store.writeDisplay('k1', Buffer.from('BIGJPEG'));
  assert.deepEqual((await listed()).map((i) => i.hasDisplay), [true, false], 'only the cached item reports hasDisplay');
  assert.equal((await fetch(`${base}/album/d1/display/k1`)).status, 401);
  const viaQuery = await fetch(`${base}/album/d1/display/k1?token=${TOKEN}`);
  assert.equal(viaQuery.status, 200);
  assert.equal(viaQuery.headers.get('content-type'), 'image/jpeg');
  assert.equal(await viaQuery.text(), 'BIGJPEG');
  assert.equal((await fetch(`${base}/album/d1/display/k1`, { headers: auth })).status, 200);
  assert.equal((await fetch(`${base}/album/d1/thumb/k1?token=${TOKEN}`)).status, 404, 'display must not satisfy the thumb route');
});

test('display route rejects traversal in mediaKey and albumId', async () => {
  writeFileSync(join(dir, 'albums', 'secret.jpg'), 'SECRET');
  assert.equal((await fetch(`${base}/album/d1/display/..%2F..%2Fsecret?token=${TOKEN}`)).status, 404);
  assert.equal((await fetch(`${base}/album/..%2Fx/display/k1?token=${TOKEN}`)).status, 404);
});

test('fetchDisplays: =w2048-h2048 for photos AND videos, idempotent, bad responses never stored', async () => {
  const store = new AlbumStore(process.env.PICNIC_ALBUMS_DIR, 'd2');
  store.ingestItems([A('p1'), A('v1'), A('bad403'), A('png')]);
  store.mergeKinds({ p1: 'photo', v1: 'video', bad403: 'photo', png: 'photo' });
  const urls = [];
  const fetchFn = async (u) => {
    urls.push(u);
    if (u.includes('bad403')) return resp('x'.repeat(100), 'image/png', 403); // signed-out placeholder
    if (u.includes('/png=')) return resp('PNGDATA', 'image/png');
    return resp(`jpeg-of-${u.split('/').pop()}`);
  };
  assert.equal(DISPLAY_BOX, 2048);
  assert.deepEqual(await fetchDisplays(store, { fetchFn, ...quiet }), { ok: 2, skipped: 0, failed: 2 });
  assert.deepEqual(urls, ['p1', 'v1', 'bad403', 'png'].map((k) => `https://lh3.example/${k}=w2048-h2048`));
  assert.equal(readFileSync(store.displayPath('p1'), 'utf8'), 'jpeg-of-p1=w2048-h2048');
  assert.equal(store.hasDisplay('v1'), true, 'a video poster gets a display image too');
  assert.equal(store.hasDisplay('bad403'), false, 'a 403 placeholder must not be saved as a display image');
  assert.equal(store.hasDisplay('png'), false, 'a non-JPEG body must not be saved under .jpg');

  urls.length = 0;
  assert.deepEqual(await fetchDisplays(store, { fetchFn, ...quiet }), { ok: 0, skipped: 2, failed: 2 });
  assert.deepEqual(urls, ['bad403', 'png'].map((k) => `https://lh3.example/${k}=w2048-h2048`), 'cached items are not re-fetched');
});
