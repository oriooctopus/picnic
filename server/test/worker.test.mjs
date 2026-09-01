import { test } from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { JobQueue } from '../lib/queue.mjs';
import { groupJobsByDate } from '../lib/matcher.mjs';
import { createFakePage } from './helpers/fakePage.mjs';

// Must be set BEFORE worker.mjs is evaluated (it reads the env var once, at
// module load, into a top-level FAST_DELAYS const) — dynamic import lets us
// set it first instead of racing a static import's hoisting. This collapses
// worker.mjs's real 1-9s human-scale jitter down to ~0ms so the suite runs
// in milliseconds instead of minutes, without changing that pacing for a
// real run (see the FAST_DELAYS comment in worker.mjs).
process.env.PICNIC_WORKER_FAST_DELAYS = '1';
const { processDateGroup, runDateGroups, assertNoFriction, MAX_STEPS_PER_DATE } = await import('../worker.mjs');

async function withTempQueue(fn) {
  const dir = mkdtempSync(join(tmpdir(), 'picnic-worker-test-'));
  const queue = new JobQueue(join(dir, 'queue.jsonl'));
  try {
    return await fn(queue);
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
}

const IMG_1433_BLOCK =
  "InfoAdd a descriptionPeopleDetailsAug 5Wed, 6:54 PMGMT-06:00Apple iPhone 13 Pro" +
  "ƒ/2.21/632.71mmISO40IMG_1433.HEIC7.2MP2316 × 3088Uploaded from iOS deviceBacked up (6 MB)Original quality. Learn moreWestminster, CO";

const IMG_1441_BLOCK =
  "InfoAdd a descriptionPeopleDetailsAug 5Wed, 7:31 PMGMT-06:00Apple iPhone 13 Pro" +
  "ƒ/1.61/1201.55mmISO64IMG_1441.HEIC5.1MP3024 × 4032Uploaded from iOS deviceBacked up (5 MB)Original quality. Learn moreWestminster, CO";

const IMG_1433_JOB = {
  filename: 'IMG_1433.HEIC',
  creationDate: '2026-08-05T12:54:07.000Z',
  pixelWidth: 2316,
  pixelHeight: 3088,
};
const IMG_1441_JOB = {
  filename: 'IMG_1441.HEIC',
  creationDate: '2026-08-05T13:31:07.000Z',
  pixelWidth: 3024,
  pixelHeight: 4032,
};

test('assertNoFriction passes on an ordinary Google Photos page', async () => {
  const page = createFakePage({ bodyText: 'Your photos, organized. Search your library.' });
  await assert.doesNotReject(() => assertNoFriction(page));
});

test('assertNoFriction throws on a captcha/rate-limit interstitial', async () => {
  const cases = [
    'We have detected unusual activity from your computer network.',
    "Please verify it's you before continuing.",
    'Too many requests — try again later.',
  ];
  for (const bodyText of cases) {
    const page = createFakePage({ bodyText });
    await assert.rejects(() => assertNoFriction(page), /FRICTION DETECTED/);
  }
});

test('N jobs on the same date produce exactly ONE search, not N', async () => {
  await withTempQueue(async (queue) => {
    const { job: job1 } = queue.enqueue(IMG_1433_JOB);
    const { job: job2 } = queue.enqueue(IMG_1441_JOB);
    const page = createFakePage({
      searchResults: {
        'August 5, 2026': [
          { ariaLabel: 'Photo - Portrait - Aug 5, 2026, 6:54:07 PM' },
          { ariaLabel: 'Favorites' }, // decoy chip, must be filtered
          { ariaLabel: 'Photo - Portrait - Aug 5, 2026, 7:31:07 PM' },
        ],
      },
      photoSequence: {
        'August 5, 2026': [IMG_1433_BLOCK, IMG_1441_BLOCK],
      },
    });

    const { stillUnmatched } = await processDateGroup(page, '2026-08-05', [job1, job2], queue, { dryRun: false });

    assert.equal(stillUnmatched.length, 0, 'both jobs should be matched');
    assert.equal(page.searchLog.length, 1, 'exactly one search must be submitted for N jobs on one date');
    assert.deepEqual(page.searchLog, ['August 5, 2026']);
    assert.equal(queue.getById(job1.id).status, 'trashed');
    assert.equal(queue.getById(job2.id).status, 'trashed');
  });
});

test('runDateGroups: the +/-1 day fallback does NOT fire when the first date matches everything', async () => {
  await withTempQueue(async (queue) => {
    const { job } = queue.enqueue(IMG_1433_JOB);
    const groups = groupJobsByDate([job]);
    const page = createFakePage({
      searchResults: {
        'August 5, 2026': [{ ariaLabel: 'Photo - Portrait - Aug 5, 2026, 6:54:07 PM' }],
      },
      photoSequence: {
        'August 5, 2026': [IMG_1433_BLOCK],
      },
    });

    await runDateGroups(page, groups, queue, { dryRun: false });

    assert.deepEqual(page.searchLog, ['August 5, 2026'], 'must not search Aug 4 or Aug 6 once Aug 5 resolved everything');
    assert.equal(queue.getById(job.id).status, 'trashed');
  });
});

test('runDateGroups: the +/-1 day fallback fires only for jobs still unmatched, and still confirms by filename', async () => {
  await withTempQueue(async (queue) => {
    // Job's UTC date is Aug 5, but its real local capture day (per the
    // panel) is Aug 4 (the timezone trap from the brief) — Aug 5 search
    // finds nothing for it, day-1 (Aug 4) finds and confirms it.
    const { job } = queue.enqueue({
      filename: 'IMG_1433.HEIC',
      creationDate: '2026-08-05T03:08:21.000Z', // UTC date Aug 5
      pixelWidth: 2316,
      pixelHeight: 3088,
    });
    const groups = groupJobsByDate([job]);
    const page = createFakePage({
      searchResults: {
        'August 5, 2026': [{ ariaLabel: 'Photo - Portrait - Aug 5, 2026, 1:00:00 AM' }],
        'August 4, 2026': [{ ariaLabel: 'Photo - Portrait - Aug 4, 2026, 6:54:07 PM' }],
      },
      photoSequence: {
        // A different photo on Aug 5 that must NOT be accepted as a match
        // just because the date search hit something — filename disagrees.
        'August 5, 2026': [
          "InfoAdd a descriptionPeopleDetailsAug 5Wed, 1:00 AMGMT-06:00Apple iPhone 13 Pro" +
            "ƒ/2.21/632.71mmISO40IMG_9999.HEIC7.2MP2316 × 3088Uploaded from iOS deviceBacked up (6 MB)Original quality. Learn moreWestminster, CO",
        ],
        'August 4, 2026': [IMG_1433_BLOCK],
      },
    });

    await runDateGroups(page, groups, queue, { dryRun: false });

    assert.deepEqual(page.searchLog, ['August 5, 2026', 'August 4, 2026']);
    assert.equal(queue.getById(job.id).status, 'trashed');
    assert.equal(queue.getById(job.id).comparison.searchDate, 'August 4, 2026');
  });
});

test('runDateGroups: unmatched after all three date attempts -> needs_review, never trash', async () => {
  await withTempQueue(async (queue) => {
    const { job } = queue.enqueue(IMG_1433_JOB);
    const groups = groupJobsByDate([job]);
    const page = createFakePage({
      searchResults: {
        'August 5, 2026': [],
        'August 4, 2026': [],
        'August 6, 2026': [],
      },
    });

    await runDateGroups(page, groups, queue, { dryRun: false });

    assert.deepEqual(page.searchLog, ['August 5, 2026', 'August 4, 2026', 'August 6, 2026']);
    assert.equal(queue.getById(job.id).status, 'needs_review');
    assert.ok(!page.log.some((l) => l.includes('Move to trash')));
  });
});

test('filename mismatch never reaches the trash path, even with matching dimensions', async () => {
  await withTempQueue(async (queue) => {
    const { job } = queue.enqueue(IMG_1433_JOB); // expects IMG_1433.HEIC
    const page = createFakePage({
      searchResults: {
        'August 5, 2026': [{ ariaLabel: 'Photo - Portrait - Aug 5, 2026, 6:54:07 PM' }],
      },
      photoSequence: {
        'August 5, 2026': [
          // Same dimensions as the job, but a different filename.
          "InfoAdd a descriptionPeopleDetailsAug 5Wed, 6:54 PMGMT-06:00Apple iPhone 13 Pro" +
            "ƒ/2.21/632.71mmISO40IMG_0001.HEIC7.2MP2316 × 3088Uploaded from iOS deviceBacked up (6 MB)Original quality. Learn moreWestminster, CO",
        ],
      },
    });

    const { stillUnmatched } = await processDateGroup(page, '2026-08-05', [job], queue, { dryRun: false });

    assert.equal(stillUnmatched.length, 1, 'filename mismatch must never match');
    assert.ok(!page.log.some((l) => l.includes('Move to trash')));
    assert.equal(queue.getById(job.id).status, 'queued', 'job untouched by processDateGroup itself (needs_review applied by runDateGroups)');
  });
});

test('--dry-run: on a match, logs the verdict but never trashes and never mutates the queue', async () => {
  await withTempQueue(async (queue) => {
    const { job } = queue.enqueue(IMG_1433_JOB);
    const page = createFakePage({
      searchResults: {
        'August 5, 2026': [{ ariaLabel: 'Photo - Portrait - Aug 5, 2026, 6:54:07 PM' }],
      },
      photoSequence: {
        'August 5, 2026': [IMG_1433_BLOCK],
      },
    });

    const { stillUnmatched } = await processDateGroup(page, '2026-08-05', [job], queue, { dryRun: true });

    assert.equal(stillUnmatched.length, 0, 'dry-run still determines a match');
    assert.ok(!page.log.some((l) => l.includes('Move to trash')), 'dry-run must never click trash');
    assert.equal(queue.getById(job.id).status, 'queued', 'dry-run must never mutate the queue');
    assert.equal(queue.loadAll().length, 1);
  });
});

test('--dry-run through runDateGroups: needs_review path also never mutates the queue', async () => {
  await withTempQueue(async (queue) => {
    const { job } = queue.enqueue(IMG_1433_JOB);
    const groups = groupJobsByDate([job]);
    const page = createFakePage({ searchResults: { 'August 5, 2026': [], 'August 4, 2026': [], 'August 6, 2026': [] } });

    await runDateGroups(page, groups, queue, { dryRun: true });

    assert.equal(queue.getById(job.id).status, 'queued');
    assert.equal(queue.loadAll().length, 1);
  });
});

test('walk through a date is bounded by MAX_STEPS_PER_DATE', async () => {
  await withTempQueue(async (queue) => {
    assert.equal(MAX_STEPS_PER_DATE, 80, 'sanity: brief specifies a cap of 80 steps/day');
    const { job } = queue.enqueue({ ...IMG_1433_JOB, filename: 'IMG_NOMATCH.HEIC' });
    const hugeSequence = Array.from({ length: 90 }, (_, i) => (
      "InfoAdd a descriptionPeopleDetailsAug 5Wed, 6:54 PMGMT-06:00Apple iPhone 13 Pro" +
      `ƒ/2.21/632.71mmISO40Other${i}.HEIC7.2MP2316 × 3088Uploaded from iOS deviceBacked up (6 MB)Original quality. Learn moreWestminster, CO`
    ));
    const page = createFakePage({
      searchResults: { 'August 5, 2026': [{ ariaLabel: 'Photo - Portrait - Aug 5, 2026, 6:54:07 PM' }] },
      photoSequence: { 'August 5, 2026': hugeSequence },
    });

    await processDateGroup(page, '2026-08-05', [job], queue, { dryRun: true });

    const nextClicks = page.log.filter((l) => l === 'click:button[aria-label="View next photo" i]');
    assert.ok(nextClicks.length <= MAX_STEPS_PER_DATE, `expected at most ${MAX_STEPS_PER_DATE} "next" clicks, got ${nextClicks.length}`);
  });
});


// A trash click that resolves is NOT proof the photo was trashed: "Open info"
// and "View next photo" both turned out to have hidden duplicates whose clicks
// silently time out. A job wrongly recorded as "trashed" would never be
// revisited, so an unconfirmed delete must fall back to needs_review.
test('a trash action that does not take is recorded as needs_review, never trashed', async () => {
  await withTempQueue(async (queue) => {
    const { job } = queue.enqueue(IMG_1433_JOB);
    const page = createFakePage({
      searchResults: { 'August 5, 2026': ['Photo - Portrait - Aug 5, 2026, 6:54:07 PM'] },
      photoSequence: { 'August 5, 2026': [IMG_1433_BLOCK] },
      infoButtonFound: true,
      trashButtonVisible: false,
      swallowTrashShortcut: true,
    });

    await processDateGroup(page, '2026-08-05', [queue.getById(job.id)], queue, { dryRun: false });

    const after = queue.getById(job.id);
    assert.equal(after.status, 'needs_review', 'unconfirmed trash must not be recorded as trashed');
    assert.match(after.error ?? '', /not confirmed/i);
  });
});
