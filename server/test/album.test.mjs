import { test } from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, rmSync, writeFileSync, existsSync, readFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { AlbumStore } from '../lib/album.mjs';
import { fetchThumbs, downloadKept, classifyResponse, requestContextFetch } from '../album-fetch.mjs';

const dir = mkdtempSync(join(tmpdir(), 'picnic-album-test-'));
const tokenPath = join(dir, 'token');
const TOKEN = 'album-test-token';
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

const A = (key, w = 100) => [key, [`https://lh3.example/${key}`, w, 50], 1700000000000, 'dedupe', 0, 1];
const auth = { Authorization: `Bearer ${TOKEN}` };
const post = (path, body, headers = auth) =>
  fetch(`${base}${path}`, { method: 'POST', headers: { 'Content-Type': 'application/json', ...headers }, body: JSON.stringify(body) });

function freshStore(name = 'alb') {
  return new AlbumStore(mkdtempSync(join(dir, 'store-')), name);
}

test('ingestItems maps listing arrays and is idempotent (first sighting wins)', () => {
  const s = freshStore();
  assert.deepEqual(s.ingestItems([A('k1'), A('k2')]), { added: 2, total: 2 });
  assert.deepEqual(s.ingestItems([A('k1', 999), A('k3')]), { added: 1, total: 3 });
  const items = s.loadItems();
  assert.equal(items.length, 3);
  assert.deepEqual(items[0], { mediaKey: 'k1', thumbUrl: 'https://lh3.example/k1', width: 100, height: 50, captureMs: 1700000000000 });
});

test('mediaKey and albumId are validated before touching paths', () => {
  const s = freshStore();
  for (const bad of ['../x', 'a/b', '', 'a.b', '..']) {
    assert.throws(() => s.ingestItems([A(bad)]), /invalid mediaKey/);
    assert.throws(() => s.thumbPath(bad), /invalid mediaKey/);
    assert.throws(() => s.setDecision(bad, 'keep'), /invalid mediaKey/);
    assert.throws(() => s.fullPath(bad), /invalid mediaKey/);
  }
  assert.throws(() => new AlbumStore(dir, '../evil'), /invalid albumId/);
  assert.equal(existsSync(join(dir, '..', 'evil')), false);
});

test('decisions, listItems flags and counts', () => {
  const s = freshStore();
  s.ingestItems([A('k1'), A('k2'), A('k3')]);
  s.setDecision('k1', 'keep');
  s.setDecision('k2', 'skip');
  assert.throws(() => s.setDecision('k1', 'maybe'), /invalid decision/);
  assert.throws(() => s.setDecision('nope', 'keep'), /unknown mediaKey/);
  s.writeThumb('k1', Buffer.from('jpg'));
  s.writeFull('k1', 'jpg', Buffer.from('full'));
  const list = s.listItems();
  assert.deepEqual(list.map((i) => [i.decision, i.hasThumb, i.downloaded]), [
    ['keep', true, true],
    ['skip', false, false],
    [null, false, false],
  ]);
  assert.deepEqual(s.counts(), { total: 3, keep: 1, skip: 1, undecided: 1, downloaded: 1 });
});

test('album routes: auth, ingest, list, decision, thumb, download-status', async () => {
  assert.equal((await post('/album/a1/items', { items: [A('k1')] }, {})).status, 401);
  assert.equal((await fetch(`${base}/album/a1`)).status, 401);
  assert.equal((await post('/album/a1/items', { items: 'x' })).status, 400);
  assert.equal((await post('/album/a1/items', { items: [A('../x')] })).status, 400);

  const r = await post('/album/a1/items', { items: [A('k1'), A('k2')] });
  assert.deepEqual(await r.json(), { added: 2, total: 2 });

  assert.equal((await post('/album/a1/decision', { mediaKey: 'k1', decision: 'keep' })).status, 200);
  assert.equal((await post('/album/a1/decision', { mediaKey: 'k1', decision: 'bad' })).status, 400);
  assert.equal((await post('/album/a1/decision', { mediaKey: '../k1', decision: 'keep' })).status, 400);
  assert.equal((await post('/album/a1/decision', { mediaKey: 'zzz', decision: 'keep' })).status, 400);

  const body = await (await fetch(`${base}/album/a1`, { headers: auth })).json();
  assert.deepEqual(body.counts, { total: 2, keep: 1, skip: 0, undecided: 1, downloaded: 0 });
  assert.equal(body.items[0].decision, 'keep');

  const st = await (await fetch(`${base}/album/a1/download-status`, { headers: auth })).json();
  assert.deepEqual([st.kept, st.downloaded, st.pending], [1, 0, 1]);

  // thumb: 404 until present, then served with header or ?token=
  assert.equal((await fetch(`${base}/album/a1/thumb/k1`, { headers: auth })).status, 404);
  new AlbumStore(process.env.PICNIC_ALBUMS_DIR, 'a1').writeThumb('k1', Buffer.from('JPEGDATA'));
  assert.equal((await fetch(`${base}/album/a1/thumb/k1`)).status, 401);
  const viaQuery = await fetch(`${base}/album/a1/thumb/k1?token=${TOKEN}`);
  assert.equal(viaQuery.status, 200);
  assert.equal(viaQuery.headers.get('content-type'), 'image/jpeg');
  assert.equal(await viaQuery.text(), 'JPEGDATA');
  assert.equal((await fetch(`${base}/album/a1/thumb/k1`, { headers: auth })).status, 200);
});

test('album routes reject traversal in albumId and mediaKey', async () => {
  // A decoy file outside the album dir that a traversal would reach.
  writeFileSync(join(dir, 'albums', 'secret.jpg'), 'SECRET');
  const r1 = await fetch(`${base}/album/a1/thumb/..%2F..%2Fsecret?token=${TOKEN}`);
  assert.equal(r1.status, 404);
  const r2 = await fetch(`${base}/album/..%2Fx/thumb/k1?token=${TOKEN}`);
  assert.equal(r2.status, 404);
  const r3 = await fetch(`${base}/album/..%2Fevil`, { headers: auth });
  assert.equal(r3.status, 404);
  assert.equal(existsSync(join(dir, 'evil')), false);
});

const fakeResponse = (body, type = 'image/jpeg', status = 200) =>
  new Response(body, { status, headers: { 'content-type': type } });

test('fetchThumbs: appends size suffix, idempotent, counts failures, no network', async () => {
  const s = freshStore();
  s.ingestItems([A('k1'), A('k2')]);
  const urls = [];
  const fetchFn = async (u) => {
    urls.push(u);
    return u.includes('k2') ? fakeResponse('x', 'text/plain', 500) : fakeResponse('thumbbytes');
  };
  const logs = [];
  const opts = { fetchFn, paceMs: 0, log: (m) => logs.push(m) };
  assert.deepEqual(await fetchThumbs(s, opts), { ok: 1, skipped: 0, failed: 1 });
  assert.deepEqual(urls, ['https://lh3.example/k1=w512-h512', 'https://lh3.example/k2=w512-h512']);
  assert.equal(readFileSync(s.thumbPath('k1'), 'utf8'), 'thumbbytes');
  assert.equal(logs.at(-1), 'thumbs: ok 1, skipped 0, failed 1');
  urls.length = 0;
  assert.deepEqual(await fetchThumbs(s, opts), { ok: 0, skipped: 1, failed: 1 });
  assert.deepEqual(urls, ['https://lh3.example/k2=w512-h512']);
});

// Fake Playwright APIResponse / APIRequestContext (lowercased header keys, like the real one).
const fakeApiResponse = (status, contentType, body) => ({
  status: () => status,
  headers: () => ({ 'content-type': contentType }),
  body: async () => Buffer.from(body),
});

test('requestContextFetch adapts an APIRequestContext to the fetch shape', async () => {
  const seen = [];
  const ctx = { get: async (url, opts) => (seen.push([url, opts]), fakeApiResponse(200, 'image/jpeg', 'abc')) };
  const res = await requestContextFetch(ctx)('https://x/y=d');
  assert.equal(res.ok, true);
  assert.equal(res.status, 200);
  assert.equal(res.headers.get('Content-Type'), 'image/jpeg');
  assert.equal(Buffer.from(await res.arrayBuffer()).toString(), 'abc');
  assert.deepEqual(seen, [['https://x/y=d', { failOnStatusCode: false, timeout: 300_000 }]]);
  const bad = await requestContextFetch({ get: async () => fakeApiResponse(403, 'image/png', 'p') })('u');
  assert.equal(bad.ok, false);
  assert.equal(bad.status, 403);
});

test('classifyResponse flags placeholder 403, html 200, accepts image/video 200', () => {
  assert.match(classifyResponse({ status: 403, contentType: 'image/png', bytes: 1035 }), /HTTP 403.*1035 bytes.*placeholder/);
  assert.match(classifyResponse({ status: 200, contentType: 'text/html; charset=utf-8', bytes: 50000 }), /not image\/\* or video\/\*/);
  assert.match(classifyResponse({ status: 403, contentType: 'text/html', bytes: 90000 }), /HTTP 403/);
  assert.equal(classifyResponse({ status: 200, contentType: 'image/jpeg', bytes: 500 }), null);
  assert.equal(classifyResponse({ status: 200, contentType: 'video/mp4', bytes: 9e6 }), null);
});

test('fetchThumbs via adapter never writes placeholder or html bodies', async () => {
  const s = freshStore();
  s.ingestItems([A('k1'), A('k2'), A('k3')]);
  const resp = {
    k1: fakeApiResponse(403, 'image/png', 'x'.repeat(1035)),
    k2: fakeApiResponse(200, 'text/html', '<html>'),
    k3: fakeApiResponse(200, 'image/jpeg', 'good'),
  };
  const ctx = { get: async (u) => resp[u.split('/').pop().split('=')[0]] };
  const logs = [];
  const r = await fetchThumbs(s, { fetchFn: requestContextFetch(ctx), paceMs: 0, log: (m) => logs.push(m) });
  assert.deepEqual(r, { ok: 1, skipped: 0, failed: 2 });
  assert.equal(s.hasThumb('k1'), false);
  assert.equal(s.hasThumb('k2'), false);
  assert.equal(s.hasThumb('k3'), true);
  assert.ok(logs.some((l) => /thumb FAILED k1: HTTP 403.*placeholder/.test(l)));
});

test('fetchThumbs paces requests', async () => {
  const s = freshStore();
  s.ingestItems([A('k1'), A('k2'), A('k3')]);
  const t0 = Date.now();
  await fetchThumbs(s, { fetchFn: async () => fakeResponse('x'), paceMs: 60, log: () => {} });
  assert.ok(Date.now() - t0 >= 110, 'two gaps of 60ms between three requests');
});

test('downloadKept: only kept items, =d url, ext from content-type, idempotent, summary line', async () => {
  const s = freshStore();
  s.ingestItems([A('k1'), A('k2'), A('k3'), A('k4')]);
  s.setDecision('k1', 'keep');
  s.setDecision('k2', 'keep');
  s.setDecision('k3', 'skip');
  s.setDecision('k4', 'keep');
  const urls = [];
  const fetchFn = async (u) => {
    urls.push(u);
    if (u.includes('k2')) return fakeResponse('x', 'text/plain', 403);
    return fakeResponse('orig', u.includes('k4') ? 'image/heic' : 'image/jpeg');
  };
  const logs = [];
  const opts = { fetchFn, paceMs: 0, log: (m) => logs.push(m) };
  const r = await downloadKept(s, opts);
  assert.deepEqual([r.downloaded, r.kept, r.failed], [2, 3, 1]);
  assert.equal(logs.at(-1), 'downloaded 2 of 3 kept, failed 1');
  assert.deepEqual(urls, ['https://lh3.example/k1=d', 'https://lh3.example/k2=d', 'https://lh3.example/k4=d']);
  assert.ok(s.fullPath('k1').endsWith('k1.jpg'));
  assert.ok(s.fullPath('k4').endsWith('k4.heic'));
  assert.equal(s.fullPath('k3'), null);
  urls.length = 0;
  const r2 = await downloadKept(s, opts);
  assert.deepEqual(urls, ['https://lh3.example/k2=d']);
  assert.deepEqual([r2.downloaded, r2.failed], [2, 1]);
});

// ----- kinds + videos + Range -------------------------------------------
import { mergeKindsFile, fetchVideos } from '../album-fetch.mjs';

test('mergeKindsFile: maps Google kinds, Animation is a photo, listItems exposes kind/hasVideo', () => {
  const s = freshStore();
  s.ingestItems([A('k1'), A('k2'), A('k3')]);
  assert.deepEqual(mergeKindsFile(s, { k1: 'Photo', k2: 'Video', k3: 'Animation' }), { merged: 3, videos: 1 });
  const items = s.listItems();
  assert.deepEqual(items.map((i) => [i.kind, i.hasVideo]), [['photo', false], ['video', false], ['photo', false]]);
  s.writeVideo('k2', Buffer.from('v'));
  assert.equal(s.listItems()[1].hasVideo, true);
});

test('mergeKindsFile: unknown kind or missing key throws and writes nothing', () => {
  const s = freshStore();
  s.ingestItems([A('k1')]);
  assert.throws(() => mergeKindsFile(s, { k1: 'Video', k2: 'Photo' }), /unknown mediaKey: k2/);
  assert.throws(() => mergeKindsFile(s, { k1: 'Hologram' }), /unknown kind for k1/);
  assert.equal(s.loadItems()[0].kind, undefined);
});

test('fetchVideos: m37 first, m18 fallback, failures write nothing, cached skipped', async () => {
  const s = freshStore();
  s.ingestItems([A('v1'), A('v2'), A('v3'), A('v4'), A('p1')]);
  mergeKindsFile(s, { v1: 'Video', v2: 'Video', v3: 'Video', v4: 'Video', p1: 'Photo' });
  const big = 'x'.repeat(3000);
  const urls = [];
  const fetchFn = async (u) => {
    urls.push(u);
    if (u === 'https://lh3.example/v1=m37') return fakeResponse(big, 'video/mp4');
    if (u === 'https://lh3.example/v2=m37') return fakeResponse('redirect', 'text/html', 302);
    if (u === 'https://lh3.example/v2=m18') return fakeResponse(big + 'low', 'video/mp4');
    if (u.startsWith('https://lh3.example/v3=')) return fakeResponse('tiny', 'video/mp4');
    return fakeResponse(big, 'image/jpeg');
  };
  const logs = [];
  const opts = { fetchFn, paceMs: 0, log: (m) => logs.push(m) };
  assert.deepEqual(await fetchVideos(s, opts), { downloaded: 2, cached: 0, failed: 2 });
  assert.deepEqual(urls, [
    'https://lh3.example/v1=m37', 'https://lh3.example/v2=m37', 'https://lh3.example/v2=m18',
    'https://lh3.example/v3=m37', 'https://lh3.example/v3=m18', 'https://lh3.example/v4=m37', 'https://lh3.example/v4=m18',
  ]);
  assert.ok(logs.includes('video ok v1 via m37 (3000 bytes)'));
  assert.ok(logs.includes('video ok v2 via m18 (3003 bytes)'));
  assert.ok(logs.some((l) => /video FAILED v3: m37: only 4 bytes; m18: only 4 bytes/.test(l)));
  assert.ok(logs.some((l) => /video FAILED v4: .*not image\/\* or video\/\*|video FAILED v4: .*not video\/\*/.test(l)));
  assert.equal(logs.at(-1), 'videos: 2 downloaded, 0 cached, 2 failed');
  assert.equal(s.hasVideo('v3'), false);
  assert.equal(s.hasVideo('v4'), false);
  assert.equal(s.hasVideo('p1'), false);
  urls.length = 0;
  await fetchVideos(s, opts);
  assert.deepEqual(urls.filter((u) => u.includes('v1') || u.includes('v2')), []);
  assert.equal(logs.at(-1), 'videos: 0 downloaded, 2 cached, 2 failed');
});

test('GET /album/:id/video/:key serves Range (200, 206, open-ended, suffix, 416) and 404/401', async () => {
  await post('/album/vr/items', { items: [A('v1'), A('v2')] });
  const s = new AlbumStore(process.env.PICNIC_ALBUMS_DIR, 'vr');
  s.writeVideo('v1', Buffer.from('0123456789'));
  const get = (key, range) =>
    fetch(`${base}/album/vr/video/${key}?token=${TOKEN}`, { headers: range ? { Range: range } : {} });
  assert.equal((await fetch(`${base}/album/vr/video/v1`)).status, 401);
  assert.equal((await get('v2')).status, 404);

  const full = await get('v1');
  assert.equal(full.status, 200);
  assert.equal(full.headers.get('accept-ranges'), 'bytes');
  assert.equal(full.headers.get('content-type'), 'video/mp4');
  assert.equal(await full.text(), '0123456789');

  const part = await get('v1', 'bytes=0-1');
  assert.equal(part.status, 206);
  assert.equal(part.headers.get('content-range'), 'bytes 0-1/10');
  assert.equal(await part.text(), '01');

  const open = await get('v1', 'bytes=4-');
  assert.equal(open.status, 206);
  assert.equal(open.headers.get('content-range'), 'bytes 4-9/10');
  assert.equal(await open.text(), '456789');

  const suffix = await get('v1', 'bytes=-3');
  assert.equal(suffix.status, 206);
  assert.equal(await suffix.text(), '789');

  const clamped = await get('v1', 'bytes=8-99');
  assert.equal(clamped.headers.get('content-range'), 'bytes 8-9/10');
  await clamped.arrayBuffer();

  const bad = await get('v1', 'bytes=10-20');
  assert.equal(bad.status, 416);
  assert.equal(bad.headers.get('content-range'), 'bytes */10');

  const list = await (await fetch(`${base}/album/vr`, { headers: auth })).json();
  assert.deepEqual(list.items.map((i) => [i.kind, i.hasVideo]), [['photo', false], ['photo', false]]);
});
