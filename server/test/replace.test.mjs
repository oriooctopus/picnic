import { test } from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, rmSync, writeFileSync, readFileSync, existsSync, readdirSync } from 'node:fs';
import { execFileSync } from 'node:child_process';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { JobQueue } from '../lib/queue.mjs';
import { processReplaceJob, replaceUploadName, buildStageArgs, offsetFits, parseClock, durationMatches } from '../lib/replace.mjs';

const dir = mkdtempSync(join(tmpdir(), 'picnic-replace-test-'));
const tokenPath = join(dir, 'token');
const queuePath = join(dir, 'queue.jsonl');
const replaceDir = join(dir, 'replace');
const TOKEN = 'replace-test-token';
writeFileSync(tokenPath, TOKEN);
process.env.PICNIC_TOKEN_PATH = tokenPath;
process.env.PICNIC_QUEUE_PATH = queuePath;
process.env.PICNIC_THUMBS_DIR = join(dir, 'thumbs');
process.env.PICNIC_REPLACE_DIR = replaceDir;

const { createApp } = await import('../queue-server.mjs');
const drainCalls = [];
const server = createApp({ autoDrain: { notifyEnqueued: () => drainCalls.push(1), isRunning: () => false, getStatus: () => ({ enabled: true }) } });
await new Promise((r) => server.listen(0, '127.0.0.1', r));
const base = `http://127.0.0.1:${server.address().port}`;
test.after(() => { server.close(); rmSync(dir, { recursive: true, force: true }); });

// A real 2s video (the route probes the upload with ffprobe, so a fake blob would 400).
const clip = join(dir, 'clip.mov');
execFileSync('ffmpeg', ['-y', '-loglevel', 'error', '-f', 'lavfi', '-i', 'testsrc=size=64x64:rate=10', '-t', '2', '-pix_fmt', 'yuv420p', '-c:v', 'libx264', clip]);
const clipBytes = readFileSync(clip);

const goodHeaders = (id = 'abcdef12-0001') => ({
  Authorization: `Bearer ${TOKEN}`,
  'Content-Type': 'application/octet-stream',
  'X-Replace-Id': id,
  'X-Filename': encodeURIComponent('IMG 0001.MOV'),
  'X-Creation-Date': '2026-10-13T17:41:00Z',
  'X-Pixel-Width': '1920',
  'X-Pixel-Height': '1080',
});
const put = (headers, body = clipBytes) => fetch(`${base}/replace`, { method: 'POST', headers, body });

test('POST /replace without a token is 401 and stores nothing', async () => {
  const { Authorization, ...noAuth } = goodHeaders('abcdef12-noauth');
  assert.equal((await put(noAuth)).status, 401);
  assert.equal(existsSync(replaceDir), false);
});

test('POST /replace rejects missing metadata headers with 400', async () => {
  const h = goodHeaders('abcdef12-nometa');
  delete h['X-Creation-Date'];
  assert.equal((await put(h)).status, 400);
});

test('POST /replace rejects a body that is not a video, deleting the part file', async () => {
  const res = await put(goodHeaders('abcdef12-notvid'), Buffer.from('this is not a video'));
  assert.equal(res.status, 400);
  assert.match((await res.json()).error, /not a readable video/);
  assert.deepEqual(readdirSync(replaceDir).filter((f) => f.includes('.part') || f.endsWith('.mov')), []);
});

test('POST /replace stores the file on disk, queues a replace job (not inline), and is idempotent', async () => {
  const res = await put(goodHeaders());
  assert.equal(res.status, 201);
  const { job, created } = await res.json();
  assert.equal(created, true);
  assert.equal(job.kind, 'replace');
  assert.equal(job.status, 'queued');
  assert.equal(job.filename, 'IMG 0001.MOV');
  assert.equal(job.replace.bytes, clipBytes.length);
  assert.ok(Math.abs(job.replace.durationSec - 2) < 0.3, `duration ${job.replace.durationSec}`);
  assert.deepEqual(readFileSync(job.replace.file), clipBytes);
  assert.equal(drainCalls.length, 1, 'autodrain was poked once');
  // the queue file holds the path, never the bytes
  assert.ok(readFileSync(queuePath).length < 5000);

  const again = await put(goodHeaders());
  assert.equal(again.status, 200);
  assert.equal((await again.json()).created, false);
  assert.equal(drainCalls.length, 1, 'a duplicate does not re-arm autodrain');
});

test('replace jobs appear in GET /queue replaceCounts and the /issues page once they need review', async () => {
  const q = await (await fetch(`${base}/queue`, { headers: { Authorization: `Bearer ${TOKEN}` } })).json();
  assert.equal(q.replaceCounts.queued, 1);
  assert.equal(q.counts.queued, 1, 'the overall counts include replace jobs too');
  const queue = new JobQueue(queuePath);
  const job = queue.loadAll().find((j) => j.kind === 'replace');
  queue.update(job.id, { status: 'needs_review', error: 'trimmed upload not confirmed' });
  const html = await (await fetch(`${base}/issues`, { headers: { Authorization: `Bearer ${TOKEN}` } })).text();
  assert.match(html, /trim replace/);
  assert.match(html, /trimmed upload not confirmed/);
});

// ---- processReplaceJob state machine (fake Google ops, real JobQueue) ----

function setup() {
  const q = new JobQueue(join(mkdtempSync(join(dir, 'sm-')), 'q.jsonl'));
  const { job } = q.enqueueReplace({ clientId: 'sm-' + Math.random().toString(36).slice(2), filename: 'IMG_1.MOV', creationDate: '2026-10-13T17:41:00Z', pixelWidth: 1, pixelHeight: 1, file: '/x.mov', bytes: 1, durationSec: 41 });
  const calls = [];
  const ops = {
    stage: async () => { calls.push('stage'); return { path: '/s.mov', uploadName: 'IMG_1-trim.MOV' }; },
    findNew: async () => { calls.push('findNew'); return null; },
    upload: async () => { calls.push('upload'); },
    trashOriginal: async () => { calls.push('trashOriginal'); return { outcome: 'trashed', originalUrl: 'u' }; },
    cleanup: async () => { calls.push('cleanup'); },
  };
  return { q, job, ops, calls, run: (o = {}) => processReplaceJob(job, q, { ...ops, ...o }, { log: () => {} }) };
}

test('upload never confirmed -> needs_review and the original is NEVER trashed', async () => {
  const { q, job, calls, run } = setup();
  const out = await run();
  assert.equal(out.status, 'needs_review');
  assert.match(out.error, /original left untouched/);
  assert.equal(calls.includes('trashOriginal'), false);
  assert.equal(calls.filter((c) => c === 'upload').length, 3, 'retried every attempt');
  assert.equal(q.getById(job.id).status, 'needs_review');
});

test('confirmed upload then verified trash -> trashed, phase done, local copy cleaned up', async () => {
  const { q, job, calls, run } = setup();
  let uploaded = false;
  const out = await run({ upload: async () => { uploaded = true; }, findNew: async () => (uploaded ? { url: 'new' } : null) });
  assert.equal(out.status, 'trashed');
  assert.equal(out.replace.phase, 'done');
  assert.ok(calls.indexOf('trashOriginal') > -1 && calls.at(-1) === 'cleanup');
  assert.equal(q.getById(job.id).comparison.replacedBy, 'new');
});

test('trash step runs only AFTER the upload is confirmed (ordering)', async () => {
  const { calls, run } = setup();
  let uploaded = false;
  await run({ upload: async () => { calls.push('upload'); uploaded = true; }, findNew: async () => (uploaded ? { url: 'n' } : null) });
  assert.ok(calls.indexOf('upload') < calls.indexOf('trashOriginal'));
});

test('unverified trash -> needs_review with the trimmed copy recorded, never trashed', async () => {
  const { run } = setup();
  const out = await run({ findNew: async () => ({ url: 'n' }), trashOriginal: async () => ({ outcome: 'unverified', detail: 'no banner' }) });
  assert.equal(out.status, 'needs_review');
  assert.match(out.error, /in Google Photos, but the original was not trashed: unverified/);
  assert.equal(out.replace.phase, 'uploaded');
});

test('a retry after a confirmed upload skips the upload entirely', async () => {
  const { q, job, calls, ops } = setup();
  q.update(job.id, { replace: { ...job.replace, phase: 'uploaded', newItem: { url: 'n' } } });
  const out = await processReplaceJob(q.getById(job.id), q, ops, { log: () => {} });
  assert.equal(out.status, 'trashed');
  assert.equal(calls.includes('upload'), false);
  assert.equal(calls.includes('stage'), false);
});

test('an upload attempt first checks whether a prior attempt already uploaded (no double upload)', async () => {
  const { calls, run } = setup();
  const out = await run({ findNew: async () => ({ url: 'already-there' }) });
  assert.equal(out.status, 'trashed');
  assert.equal(calls.includes('upload'), false);
});

test('a fatal error (tab closed) leaves the job queued, not failed', async () => {
  const { q, job, run } = setup();
  const boom = new Error('Target page closed');
  await assert.rejects(processReplaceJob(job, q, { stage: async () => ({ path: 'p', uploadName: 'n' }), findNew: async () => { throw boom; } }, { log: () => {}, isFatal: (e) => e === boom }), boom);
  assert.equal(q.getById(job.id).status, 'queued');
});

// ---- pure helpers ----

test('replaceUploadName differs from the original but keeps the extension', () => {
  assert.equal(replaceUploadName('IMG_0001.MOV'), 'IMG_0001-trim.MOV');
  assert.equal(replaceUploadName('noext'), 'noext-trim.mov');
});

test('buildStageArgs stream-copies and stamps the ORIGINAL capture date', () => {
  const a = buildStageArgs({ input: 'i', output: 'o', creationDate: '2026-10-13T17:41:00.000Z' });
  assert.ok(a.includes('copy'));
  assert.ok(a.includes('creation_time=2026-10-13T17:41:00Z'));
  assert.ok(a.includes('com.apple.quicktime.creationdate=2026-10-13T17:41:00.000Z'));
});

test('offsetFits accepts any 15-minute-multiple timezone offset and rejects others', () => {
  const t = Date.parse('2026-10-13T17:41:00Z');
  assert.equal(offsetFits(t - 5 * 3600e3, '2026-10-13T17:41:00Z'), true);
  assert.equal(offsetFits(t + 5.5 * 3600e3, '2026-10-13T17:41:00Z'), true);
  assert.equal(offsetFits(t - 5 * 3600e3 + 60e3, '2026-10-13T17:41:00Z'), false);
  assert.equal(offsetFits(t + 20 * 3600e3, '2026-10-13T17:41:00Z'), false);
});

test('parseClock and durationMatches', () => {
  assert.equal(parseClock('0:41'), 41);
  assert.equal(parseClock('1:02:03'), 3723);
  assert.equal(parseClock('x'), null);
  assert.equal(durationMatches(60, 41), false);
  assert.equal(durationMatches(40, 41.4), true);
  assert.equal(durationMatches(null, 41), false);
});
