import { test } from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { JobQueue } from '../lib/queue.mjs';
import { createFakePage } from './helpers/fakePage.mjs';

// Must be set BEFORE worker.mjs is evaluated (it reads the env var once, at
// module load, into a top-level FAST_DELAYS const) — dynamic import lets us
// set it first instead of racing a static import's hoisting. This collapses
// worker.mjs's real 1-9s human-scale jitter down to ~0ms so the suite runs
// in milliseconds instead of minutes, without changing that pacing for a
// real run (see the FAST_DELAYS comment in worker.mjs).
process.env.PICNIC_WORKER_FAST_DELAYS = '1';
const { processJob, assertNoFriction, MAX_CANDIDATES_PER_JOB } = await import('../worker.mjs');

// NOTE: unlike queue.test.mjs's sync version of this helper, worker tests
// pass an ASYNC fn — a bare try/finally would run rmSync() the instant
// fn(queue) returns its (still-pending) promise, deleting the queue file
// out from under processJob mid-flight. Must await fn before cleaning up.
async function withTempQueue(fn) {
  const dir = mkdtempSync(join(tmpdir(), 'picnic-worker-test-'));
  const queue = new JobQueue(join(dir, 'queue.jsonl'));
  try {
    return await fn(queue);
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
}

// A job + a single candidate that agrees with it on filename, timestamp,
// and dimensions — decideMatch (lib/matcher.mjs) resolves this to 'match'.
const MATCHING_JOB = {
  filename: 'IMG_0001.HEIC',
  creationDate: '2026-06-15T14:30:00.000Z',
  pixelWidth: 100,
  pixelHeight: 200,
};
const MATCHING_CANDIDATE = {
  filenameText: 'IMG_0001.HEIC',
  dateText: '2026-06-15T14:30:00.000Z',
  dimsText: '100x200',
};

test('assertNoFriction passes on an ordinary Google Photos page', async () => {
  const page = createFakePage({ bodyText: 'Your photos, organized. Search your library.' });
  await assert.doesNotReject(() => assertNoFriction(page));
});

test('assertNoFriction throws on a captcha/rate-limit interstitial', async () => {
  const cases = [
    'We have detected unusual activity from your computer network.',
    'Please verify it\'s you before continuing.',
    'Too many requests — try again later.',
  ];
  for (const bodyText of cases) {
    const page = createFakePage({ bodyText });
    await assert.rejects(() => assertNoFriction(page), /FRICTION DETECTED/);
  }
});

test('processJob throws (does not proceed to decide/trash) when friction is detected on the results page', async () => {
  await withTempQueue(async (queue) => {
    const { job } = queue.enqueue(MATCHING_JOB);
    const page = createFakePage({
      bodyText: 'Our systems have detected unusual traffic from your computer network.',
      tiles: 1,
      candidates: [MATCHING_CANDIDATE],
    });
    await assert.rejects(() => processJob(page, job, queue, { dryRun: false }), /FRICTION DETECTED/);
    // The run must abort before ever deciding or trashing — no trash
    // click, and the job's status must still be 'queued' (unchanged).
    assert.ok(!page.log.some((l) => l.startsWith('click:button[aria-label="Delete"')));
    assert.equal(queue.getById(job.id).status, 'queued');
  });
});

test('--dry-run: on a match, logs the verdict but never calls the trash path and never mutates the queue', async () => {
  await withTempQueue(async (queue) => {
    const { job } = queue.enqueue(MATCHING_JOB);
    const page = createFakePage({ tiles: 1, candidates: [MATCHING_CANDIDATE] });

    await processJob(page, job, queue, { dryRun: true });

    // No click on the trash button (aria-label="Delete"/"Move to trash") or
    // its confirm button anywhere in the interaction log.
    assert.ok(!page.log.some((l) => l.startsWith('click:button[aria-label="Delete"')));
    assert.ok(!page.log.some((l) => l.includes('Move to trash')));
    // Queue untouched: still exactly the original 'queued' snapshot, one line.
    assert.equal(queue.getById(job.id).status, 'queued');
    assert.equal(queue.loadAll().length, 1);
  });
});

test('live run (not dry-run): on a match, clicks the trash path and marks the job trashed', async () => {
  await withTempQueue(async (queue) => {
    const { job } = queue.enqueue(MATCHING_JOB);
    const page = createFakePage({ tiles: 1, candidates: [MATCHING_CANDIDATE] });

    await processJob(page, job, queue, { dryRun: false });

    assert.ok(page.log.some((l) => l.startsWith('click:button[aria-label="Delete"')), 'expected the trash button to be clicked');
    assert.ok(page.log.some((l) => l.includes('Move to trash')), 'expected the confirm-trash button to be clicked');
    assert.equal(queue.getById(job.id).status, 'trashed');
  });
});

test('candidate scan is capped at MAX_CANDIDATES_PER_JOB even with far more search results', async () => {
  await withTempQueue(async (queue) => {
    assert.equal(MAX_CANDIDATES_PER_JOB, 3, 'sanity: brief specifies a cap of at most 3');
    const { job } = queue.enqueue({ ...MATCHING_JOB, filename: 'NoMatch.HEIC' });
    // 10 search-result tiles, none of which match the job (ambiguous
    // filenames) — this only tells us how many tiles got OPENED, not
    // whether any matched.
    const nonMatchingCandidates = Array.from({ length: 10 }, (_, i) => ({
      filenameText: `Other${i}.HEIC`,
      dateText: '2020-01-01T00:00:00.000Z',
      dimsText: '1x1',
    }));
    const page = createFakePage({ tiles: 10, candidates: nonMatchingCandidates });

    await processJob(page, job, queue, { dryRun: true });

    const tileClicks = page.log.filter((l) => l.startsWith('tile-click:'));
    assert.equal(tileClicks.length, MAX_CANDIDATES_PER_JOB, `expected exactly ${MAX_CANDIDATES_PER_JOB} tiles opened, got ${tileClicks.length}`);
    assert.deepEqual(tileClicks, ['tile-click:0', 'tile-click:1', 'tile-click:2']);
  });
});
