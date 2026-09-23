import { test } from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import { spawn } from 'node:child_process';
import { JobQueue } from '../lib/queue.mjs';
import { groupJobsByDate } from '../lib/matcher.mjs';
import { createFakePage } from './helpers/fakePage.mjs';

const WORKER_MJS_PATH = join(dirname(fileURLToPath(import.meta.url)), '..', 'worker.mjs');

// Must be set BEFORE worker.mjs is evaluated (it reads the env var once, at
// module load, into a top-level FAST_DELAYS const) — dynamic import lets us
// set it first instead of racing a static import's hoisting. This collapses
// worker.mjs's real 1-9s human-scale jitter down to ~0ms so the suite runs
// in milliseconds instead of minutes, without changing that pacing for a
// real run (see the FAST_DELAYS comment in worker.mjs).
process.env.PICNIC_WORKER_FAST_DELAYS = '1';
const {
  processDateGroup,
  runDateGroups,
  assertNoFriction,
  isPageClosedError,
  MAX_STEPS_PER_DATE,
  MAX_TILE_OPEN_RETRIES,
  EMPTY_SEARCH_RETRIES,
  parseArgs,
  stealthDelayRange,
  exitAfterSettled,
  isTrashConfirmed,
  moveToTrash,
  walkTimeline,
  runTimelineWalk,
  timelineTileWorthOpening,
  TIMELINE_TIME_TOLERANCE_SECONDS,
  MAX_TIMELINE_FRUITLESS_SCROLLS,
} = await import('../worker.mjs');

async function withTempQueue(fn) {
  const dir = mkdtempSync(join(tmpdir(), 'picnic-worker-test-'));
  const queue = new JobQueue(join(dir, 'queue.jsonl'));
  try {
    return await fn(queue);
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
}

/** Raw (run-together, no-separator) Google Photos info-panel text for one photo. */
function panelBlock(filename, w, h, timeLabel = 'Aug 5Wed, 6:54 PMGMT-06:00') {
  return (
    `InfoAdd a descriptionPeopleDetails${timeLabel}Apple iPhone 13 Pro` +
    `ƒ/2.21/632.71mmISO40${filename}7.2MP${w} × ${h}Uploaded from iOS deviceBacked up (6 MB)Original quality. Learn moreWestminster, CO`
  );
}

/** Capture console.log lines during `fn`, restoring the real console.log after. */
async function captureLogs(fn) {
  const lines = [];
  const original = console.log;
  console.log = (...args) => lines.push(args.join(' '));
  try {
    await fn();
  } finally {
    console.log = original;
  }
  return lines;
}

const IMG_1433_BLOCK = panelBlock('IMG_1433.HEIC', 2316, 3088);
const IMG_1441_BLOCK = panelBlock('IMG_1441.HEIC', 3024, 4032, 'Aug 5Wed, 7:31 PMGMT-06:00');

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
    const label1 = 'Photo - Portrait - Aug 5, 2026, 6:54:07 PM';
    const label2 = 'Photo - Portrait - Aug 5, 2026, 7:31:07 PM';
    const page = createFakePage({
      searchResults: {
        'August 5, 2026': [{ ariaLabel: label1 }, { ariaLabel: 'Favorites' }, { ariaLabel: label2 }],
      },
      panelTextByLabel: {
        'August 5, 2026': { [label1]: IMG_1433_BLOCK, [label2]: IMG_1441_BLOCK },
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

// REWRITTEN 2026-09-01 for the in-photo-view traversal (see worker.mjs's
// module header + walkPhotoView): the exhaustive fallback no longer returns
// to the grid between photos, so it never issues a distinct 'tile-click' per
// photo the way the old grid-return walk did -- only the FIRST photo of a
// date is ever grid-clicked; every photo after that is reached by pressing
// ArrowRight while staying inside the photo view. This test's fingerprint
// updates to match: exactly ONE tile-click, and the rest walked by
// ArrowRight. It still fails exactly the way the brief requires against a
// tiles[0]-only implementation -- one that opens the first tile and never
// arrows would read tile 0's (non-matching) panel forever and leave the job
// unmatched -- proven by mutation, see report.
test('every visible tile is walked: a job whose photo is at the LAST tile is still matched', async () => {
  await withTempQueue(async (queue) => {
    // Deliberately more tiles than any single "window" a virtualized grid
    // might mount -- there is no grid-mounting concern left for this walk at
    // all (see module header), but a generous count still proves the walk
    // reaches deep into the day rather than stopping early for any reason.
    const TILE_COUNT = 20;
    const { job } = queue.enqueue(IMG_1433_JOB);
    const labels = Array.from({ length: TILE_COUNT }, (_, i) => `Photo - Portrait - tile-${i}`);
    const panelTextByLabel = { 'August 5, 2026': {} };
    for (let i = 0; i < TILE_COUNT - 1; i++) {
      panelTextByLabel['August 5, 2026'][labels[i]] = panelBlock(`IMG_900${i}.HEIC`, 1000, 1000);
    }
    panelTextByLabel['August 5, 2026'][labels[TILE_COUNT - 1]] = IMG_1433_BLOCK; // the match, LAST tile

    const page = createFakePage({
      searchResults: { 'August 5, 2026': labels.map((ariaLabel) => ({ ariaLabel })) },
      panelTextByLabel,
    });

    const { stillUnmatched } = await processDateGroup(page, '2026-08-05', [job], queue, { dryRun: false });

    assert.equal(stillUnmatched.length, 0, 'job at the last tile must still be matched');
    assert.equal(queue.getById(job.id).status, 'trashed');
    const tileClicks = page.log.filter((l) => l.startsWith('tile-click:'));
    assert.equal(tileClicks.length, 1, `expected exactly ONE grid tile-click (the first tile), got: ${JSON.stringify(tileClicks)}`);
    assert.equal(tileClicks[0], `tile-click:${labels[0]}`, 'the ONE grid click must be the date\'s first tile');
    // TILE_COUNT - 1 presses to walk from tile 0 to the last (matching) tile,
    // PLUS one more (2026-09-12 duplicate-detection change): the walk no
    // longer stops the instant every job is matched -- a second copy of a job
    // (Oliver's real duplicate library items) could be anywhere else in the
    // day, so it keeps trying to advance until it hits the genuine end of the
    // day. That one extra attempt past the last tile finds no next photo and
    // stops -- see the next test for the "several untouched tiles after the
    // match" shape of the same behavior.
    const arrowPresses = page.log.filter((l) => l === 'key:ArrowRight').length;
    assert.equal(arrowPresses, TILE_COUNT, `expected ${TILE_COUNT - 1} presses to reach the last tile plus 1 to confirm no further tile follows it, got ${arrowPresses}`);
  });
});

// REWRITTEN 2026-09-12 (duplicate-detection change, see module header's
// matchedJobs comments): once ANY job is matched, the walk no longer stops
// early -- it keeps stepping through the rest of the day looking for a
// further copy of that same job (Oliver's real duplicate library items),
// stopping only at the genuine end of the day or MAX_STEPS_PER_DATE. This
// test now proves the opposite of its original name: the walk does NOT stop
// once the only job is matched, it walks every remaining tile.
test('once matched, the walk keeps going to the end of the day looking for duplicate copies, rather than stopping early', async () => {
  await withTempQueue(async (queue) => {
    const { job } = queue.enqueue(IMG_1433_JOB);
    const labels = [
      'Photo - Portrait - tile-A',
      'Photo - Portrait - tile-B (match)',
      'Photo - Portrait - tile-C (untouched)',
      'Photo - Portrait - tile-D (untouched)',
    ];
    const page = createFakePage({
      searchResults: { 'August 5, 2026': labels.map((ariaLabel) => ({ ariaLabel })) },
      panelTextByLabel: {
        'August 5, 2026': {
          [labels[0]]: panelBlock('IMG_0001.HEIC', 1000, 1000),
          [labels[1]]: IMG_1433_BLOCK,
          [labels[2]]: panelBlock('IMG_0002.HEIC', 1000, 1000),
          [labels[3]]: panelBlock('IMG_0003.HEIC', 1000, 1000),
        },
      },
    });

    const { stillUnmatched } = await processDateGroup(page, '2026-08-05', [job], queue, { dryRun: false });

    assert.equal(stillUnmatched.length, 0);
    const tileClicks = page.log.filter((l) => l.startsWith('tile-click:'));
    assert.deepEqual(tileClicks, [`tile-click:${labels[0]}`], 'only the first tile is ever grid-clicked');
    // A->B costs one ArrowRight (the match). Trashing B then auto-advances
    // the view straight onto C at ZERO cost (the fakePage's performTrash
    // models the same live auto-advance walkPhotoView's advancedByDelete
    // handles -- see that test below). From C: one more ArrowRight reaches D,
    // and a final attempt past D finds nothing and ends the walk. Total: 3 --
    // C and D are visited (and checked for a duplicate copy of the matched
    // job) even though the only job was already matched at B.
    const arrowPresses = page.log.filter((l) => l === 'key:ArrowRight').length;
    assert.equal(arrowPresses, 3, 'must walk on through C and D looking for a duplicate copy, then confirm there is no further tile after D');
  });
});

// --- Duplicate-copy detection (2026-09-12) --------------------------------
// Oliver has real duplicate library items: a photo downloaded to his phone
// and separately re-uploaded by a backup tool gives Google Photos TWO
// distinct items with the same filename+dims on the same search date. The
// worker must trash every copy it finds on that date's search, not just the
// first one the walk happens to reach -- while never guessing (a same-name,
// DIFFERENT-dims photo on the same date must never be swept up as if it were
// a copy).

test('two copies of the same job on one date (identical filename+dims, different tiles): both get trashed and the job is done', async () => {
  await withTempQueue(async (queue) => {
    const { job } = queue.enqueue(IMG_1433_JOB);
    const labels = [
      'Photo - Portrait - tile-A (first copy)',
      'Photo - Portrait - tile-B (unrelated)',
      'Photo - Portrait - tile-C (second copy, re-uploaded duplicate)',
    ];
    const page = createFakePage({
      searchResults: { 'August 5, 2026': labels.map((ariaLabel) => ({ ariaLabel })) },
      panelTextByLabel: {
        'August 5, 2026': {
          // Both A and C are IMG_1433.HEIC at the same dimensions -- two
          // distinct Google Photos items behind two distinct tiles (this is
          // exactly what dedupeTilesByAriaLabel would NOT collapse, since
          // the aria-labels here are deliberately distinct -- see the report
          // for the narrower case where they'd be identical too).
          [labels[0]]: IMG_1433_BLOCK,
          [labels[1]]: panelBlock('IMG_0002.HEIC', 1000, 1000),
          [labels[2]]: IMG_1433_BLOCK,
        },
      },
    });

    const { stillUnmatched } = await processDateGroup(page, '2026-08-05', [job], queue, { dryRun: false });

    assert.equal(stillUnmatched.length, 0, 'the job is done once every copy on the date is accounted for');
    const record = queue.getById(job.id);
    assert.equal(record.status, 'trashed');
    assert.equal(record.copiesTrashed, 2, 'the job record must reflect BOTH copies trashed, not just the first');
    // Two real '#' deletions -- the unrelated B tile must never be touched.
    const deletions = page.log.filter((l) => l === 'key:#').length;
    assert.equal(deletions, 2, 'both the first and second copy must actually be trashed');
  });
});

// REPLACED 2026-09-22: matching dropped the dimensions gate entirely (see
// matcher.mjs's findMatchingJob header) -- a "same filename, different
// dimensions" tile is no longer distinguishable from a genuine duplicate
// copy (the same case an edited photo's differing size produces, which is
// exactly the false-miss this change fixes). The brief accepts that
// filenames are unique within the +/-1-day search window in practice, so
// this scenario is no longer a case the worker tries to disambiguate --
// both tiles now confirm the same job and both get trashed, same as any
// other real duplicate copy (see the 'real duplicate library items' tests
// above this one).
test('same filename, different dimensions on the same date: now trashed as a duplicate copy (dimensions no longer gate identity)', async () => {
  await withTempQueue(async (queue) => {
    const { job } = queue.enqueue(IMG_1433_JOB); // 2316x3088
    const labels = ['Photo - Portrait - tile-A', 'Photo - Portrait - tile-B (same filename, different dims)'];
    const page = createFakePage({
      searchResults: { 'August 5, 2026': labels.map((ariaLabel) => ({ ariaLabel })) },
      panelTextByLabel: {
        'August 5, 2026': {
          [labels[0]]: IMG_1433_BLOCK, // 2316x3088
          [labels[1]]: panelBlock('IMG_1433.HEIC', 1200, 1600), // same filename, disagreeing dims
        },
      },
    });

    const { stillUnmatched } = await processDateGroup(page, '2026-08-05', [job], queue, { dryRun: false });

    assert.equal(stillUnmatched.length, 0);
    const record = queue.getById(job.id);
    assert.equal(record.status, 'trashed');
    assert.equal(record.copiesTrashed, 2, 'both filename-matching tiles are trashed as copies of the same job');
    const deletions = page.log.filter((l) => l === 'key:#').length;
    assert.equal(deletions, 2, 'both tiles get a trash attempt');
  });
});

// The aria fast path's own ambiguity check (planAriaMatches: exactly one
// candidate tile at the predicted second, or defer) is what a TRUE duplicate
// hits first live -- a re-uploaded copy shares its original's EXIF capture
// time down to the second, so it predicts to the SAME slot as the original
// and makes that job's slot ambiguous (candidates.length > 1), deferring the
// WHOLE job to the exhaustive walk rather than ever risking the aria path
// picking one of the two arbitrarily. This proves the walk it falls through
// to then finds and trashes BOTH.
test('duplicate via the aria pre-match path: an identical-second collision defers to the walk, which trashes both copies', async () => {
  await withTempQueue(async (queue) => {
    const { job } = queue.enqueue(IMG_1433_JOB); // predicts to Aug 5, 6:54:07 PM local at +6h offset
    const { job: calibrationJob } = queue.enqueue(IMG_1441_JOB); // unambiguous second pair, needed so calibrateOffsetSeconds has 2 agreeing pairs
    const dupLabelA = 'Photo - Portrait - Aug 5, 2026, 6:54:07 PM';
    const dupLabelB = 'Photo - Landscape - Aug 5, 2026, 6:54:07 PM'; // distinct aria-label, SAME predicted second -- the collision
    const calibrationLabel = 'Photo - Portrait - Aug 5, 2026, 7:31:07 PM';
    const page = createFakePage({
      searchResults: {
        'August 5, 2026': [{ ariaLabel: dupLabelA }, { ariaLabel: dupLabelB }, { ariaLabel: calibrationLabel }],
      },
      panelTextByLabel: {
        'August 5, 2026': {
          [dupLabelA]: IMG_1433_BLOCK,
          [dupLabelB]: IMG_1433_BLOCK, // the duplicate copy: identical filename+dims
          [calibrationLabel]: IMG_1441_BLOCK,
        },
      },
    });

    const { stillUnmatched } = await processDateGroup(page, '2026-08-05', [job, calibrationJob], queue, { dryRun: false });

    assert.equal(stillUnmatched.length, 0);
    assert.equal(queue.getById(calibrationJob.id).status, 'trashed', 'the unambiguous calibration job resolves via the aria fast path');
    const record = queue.getById(job.id);
    assert.equal(record.status, 'trashed');
    assert.equal(record.copiesTrashed, 2, 'both same-second copies must be trashed once the collision defers to the walk');
    const deletions = page.log.filter((l) => l === 'key:#').length;
    assert.equal(deletions, 3, 'the calibration job (1) plus both duplicate copies (2) — total 3 deletions');
  });
});

// 2026-09-12 FOLLOW-UP: this is Oliver's ACTUAL common case, not the test
// above's manufactured collision. A photo downloaded to his phone and
// separately re-uploaded by a backup tool carries the SAME EXIF capture
// second, so Google Photos renders the SAME aria-label text for both grid
// tiles ("Photo - Portrait - Aug 5, 2026, 6:54:07 PM") -- and it's usually
// the ONLY job on that date (one deletion, one date search), so there's no
// second job around to force the exhaustive walk if the aria path resolves
// this one. Before dedupeTilesByIdentity (matcher.mjs), collectResultTiles
// deduped by aria-label ALONE, silently collapsing the two distinct DOM
// tiles (different hrefs) into ONE entry before planAriaMatches ever saw
// them -- so the aria path found exactly 1 candidate, "resolved" the job,
// and the second copy was NEVER independently discovered by any path. Now
// dedupeTilesByIdentity keeps both (distinct hrefs -> distinct identity), so
// planAriaMatches sees 2 candidates at the same predicted second, defers to
// the walk, and the walk (tileLocatorFor addressing by href+aria-label, and
// fakePage's identity-based fullOrderedTiles/performTrash) can open and
// trash each one independently.
test('duplicate via the aria pre-match path: two tiles with an IDENTICAL aria-label but DISTINCT hrefs are two real items, both trashed', async () => {
  await withTempQueue(async (queue) => {
    // Deliberately ONE job on this date -- the realistic shape: without a
    // second job to leave `remaining` non-empty, the OLD aria-label-only
    // dedup would let the aria path "fully resolve" the date after trashing
    // just one of the two duplicates, never running the walk at all.
    const { job } = queue.enqueue(IMG_1433_JOB);
    const { job: calibrationJob } = queue.enqueue(IMG_1441_JOB); // needed only so calibrateOffsetSeconds has 2 agreeing (job, tile) pairs -- see planAriaMatches
    const dupLabel = 'Photo - Portrait - Aug 5, 2026, 6:54:07 PM';
    const calibrationLabel = 'Photo - Portrait - Aug 5, 2026, 7:31:07 PM';
    const page = createFakePage({
      searchResults: {
        'August 5, 2026': [
          { ariaLabel: dupLabel, href: './search/photo/AAA' },
          { ariaLabel: dupLabel, href: './search/photo/BBB' }, // IDENTICAL aria-label, DIFFERENT href -- two real Google Photos items
          { ariaLabel: calibrationLabel, href: './search/photo/CAL' },
        ],
      },
      panelTextByLabel: {
        'August 5, 2026': {
          [dupLabel]: IMG_1433_BLOCK, // both AAA and BBB render this SAME panel text -- that's what "duplicate" means
          [calibrationLabel]: IMG_1441_BLOCK,
        },
      },
    });

    const { stillUnmatched } = await processDateGroup(page, '2026-08-05', [job, calibrationJob], queue, { dryRun: false });

    assert.equal(stillUnmatched.length, 0);
    assert.equal(queue.getById(calibrationJob.id).status, 'trashed', 'the unambiguous calibration job still resolves via the aria fast path');
    const record = queue.getById(job.id);
    assert.equal(record.status, 'trashed');
    assert.equal(
      record.copiesTrashed,
      2,
      'AAA and BBB are two distinct Google Photos items (different hrefs) despite sharing an aria-label -- both must be trashed, not collapsed into one'
    );
    const deletions = page.log.filter((l) => l === 'key:#').length;
    assert.equal(deletions, 3, 'calibration (1) plus both duplicate copies (2) — total 3 deletions');
  });
});

test('tiles are not re-visited when the grid re-renders and returns them in a different order', async () => {
  await withTempQueue(async (queue) => {
    const { job: job1 } = queue.enqueue(IMG_1433_JOB);
    const { job: job2 } = queue.enqueue(IMG_1441_JOB);
    const labels = { none: 'Photo - Portrait - tile-none', j1: 'Photo - Portrait - tile-1433', j2: 'Photo - Portrait - tile-1441' };
    const page = createFakePage({
      searchResults: {
        'August 5, 2026': [{ ariaLabel: labels.none }, { ariaLabel: labels.j1 }, { ariaLabel: labels.j2 }],
      },
      panelTextByLabel: {
        'August 5, 2026': {
          [labels.none]: panelBlock('IMG_0009.HEIC', 1000, 1000),
          [labels.j1]: IMG_1433_BLOCK,
          [labels.j2]: IMG_1441_BLOCK,
        },
      },
      // Every OTHER re-collection returns the tiles reversed, simulating the
      // real grid re-rendering between visits.
      reorderOnRecollect: { 'August 5, 2026': true },
    });

    const { stillUnmatched } = await processDateGroup(page, '2026-08-05', [job1, job2], queue, { dryRun: false });

    assert.equal(stillUnmatched.length, 0, 'both jobs matched despite the grid reordering between visits');
    assert.equal(queue.getById(job1.id).status, 'trashed');
    assert.equal(queue.getById(job2.id).status, 'trashed');
    assert.deepEqual(page.searchLog, ['August 5, 2026'], 'still exactly one search');
    const noneClicks = page.log.filter((l) => l === `tile-click:${labels.none}`);
    assert.equal(noneClicks.length, 1, 'the no-match tile must be opened exactly once, never re-opened after reordering');
  });
});

test('runDateGroups: the +/-1 day fallback does NOT fire when the first date matches everything', async () => {
  await withTempQueue(async (queue) => {
    const { job } = queue.enqueue(IMG_1433_JOB);
    const groups = groupJobsByDate([job]);
    const label = 'Photo - Portrait - Aug 5, 2026, 6:54:07 PM';
    const page = createFakePage({
      searchResults: { 'August 5, 2026': [{ ariaLabel: label }] },
      panelTextByLabel: { 'August 5, 2026': { [label]: IMG_1433_BLOCK } },
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
    const wrongLabel = 'Photo - Portrait - Aug 5, 2026, 1:00:00 AM';
    const rightLabel = 'Photo - Portrait - Aug 4, 2026, 6:54:07 PM';
    const page = createFakePage({
      searchResults: {
        'August 5, 2026': [{ ariaLabel: wrongLabel }],
        'August 4, 2026': [{ ariaLabel: rightLabel }],
      },
      panelTextByLabel: {
        // A different photo on Aug 5 that must NOT be accepted as a match
        // just because the date search hit something — filename disagrees.
        'August 5, 2026': { [wrongLabel]: panelBlock('IMG_9999.HEIC', 2316, 3088, 'Aug 5Wed, 1:00 AMGMT-06:00') },
        'August 4, 2026': { [rightLabel]: IMG_1433_BLOCK },
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

    // Each empty date is re-searched before being believed (a live run got 0
    // tiles for a date a probe had just returned 5 for), so every attempted
    // date appears EMPTY_SEARCH_RETRIES + 1 times. What matters is that all
    // three dates were attempted, in order, and none was skipped.
    const distinctInOrder = page.searchLog.filter((q, i) => q !== page.searchLog[i - 1]);
    assert.deepEqual(distinctInOrder, ['August 5, 2026', 'August 4, 2026', 'August 6, 2026']);
    for (const date of distinctInOrder) {
      assert.equal(
        page.searchLog.filter((q) => q === date).length,
        EMPTY_SEARCH_RETRIES + 1,
        `an empty date must be retried before being written off: ${date}`
      );
    }
    assert.equal(queue.getById(job.id).status, 'needs_review');
    assert.ok(!page.log.some((l) => l.includes('Move to trash')));
  });
});

test('filename mismatch never reaches the trash path, even with matching dimensions', async () => {
  await withTempQueue(async (queue) => {
    const { job } = queue.enqueue(IMG_1433_JOB); // expects IMG_1433.HEIC
    const label = 'Photo - Portrait - Aug 5, 2026, 6:54:07 PM';
    const page = createFakePage({
      searchResults: { 'August 5, 2026': [{ ariaLabel: label }] },
      panelTextByLabel: {
        // Same dimensions as the job, but a different filename.
        'August 5, 2026': { [label]: panelBlock('IMG_0001.HEIC', 2316, 3088) },
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
    const label = 'Photo - Portrait - Aug 5, 2026, 6:54:07 PM';
    const page = createFakePage({
      searchResults: { 'August 5, 2026': [{ ariaLabel: label }] },
      panelTextByLabel: { 'August 5, 2026': { [label]: IMG_1433_BLOCK } },
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

test('a trash action that does not take is recorded as needs_review, never trashed', async () => {
  await withTempQueue(async (queue) => {
    const { job } = queue.enqueue(IMG_1433_JOB);
    const label = 'Photo - Portrait - Aug 5, 2026, 6:54:07 PM';
    const page = createFakePage({
      searchResults: { 'August 5, 2026': [{ ariaLabel: label }] },
      panelTextByLabel: { 'August 5, 2026': { [label]: IMG_1433_BLOCK } },
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

// --- isTrashConfirmed: pure decision, and the exact false positive it fixes ---
//
// Confirmed live 2026-09-22: job B4D8DDA7-880E-4641-BF36-69727D7F98AE_Original.JPG
// was recorded 'trashed' (3 copies) but was STILL PRESENT in Google Photos.
// moveToTrash's old settled() counted a mere panel-text change/empty as proof
// of a trash, with no requirement that the "Move to trash" confirm dialog was
// ever actually shown and clicked. isTrashConfirmed is the fix: dialogConfirmed
// is now a hard requirement, not just one of several optional signals.

test('isTrashConfirmed: no confirm dialog shown, panel text merely changed -> NOT confirmed (the exact B4D8DDA7... false positive)', () => {
  assert.equal(isTrashConfirmed({ dialogConfirmed: false, toastShown: false, panelChanged: true }), false);
});

test('isTrashConfirmed: no confirm dialog shown, even with a "moved to trash" toast somehow visible -> NOT confirmed', () => {
  // Belt-and-suspenders: the dialog requirement is unconditional, not just
  // the common case. A toast with no dialog is exactly as untrustworthy as a
  // panel change with no dialog -- see this function's header.
  assert.equal(isTrashConfirmed({ dialogConfirmed: false, toastShown: true, panelChanged: false }), false);
});

test('isTrashConfirmed: dialog shown and clicked, followed by the "moved to trash" toast -> confirmed', () => {
  assert.equal(isTrashConfirmed({ dialogConfirmed: true, toastShown: true, panelChanged: false }), true);
});

test('isTrashConfirmed: dialog shown and clicked, followed by the panel moving off this photo -> confirmed', () => {
  assert.equal(isTrashConfirmed({ dialogConfirmed: true, toastShown: false, panelChanged: true }), true);
});

test('isTrashConfirmed: dialog shown and clicked, but NEITHER a toast nor a panel change followed -> NOT confirmed (dialog click alone is not proof either)', () => {
  assert.equal(isTrashConfirmed({ dialogConfirmed: true, toastShown: false, panelChanged: false }), false);
});

// Direct unit tests against the real moveToTrash(), at the seam it actually
// makes its decision -- a minimal hand-built page mock rather than the full
// createFakePage() harness, so the confirm-dialog's visibility is the ONE
// thing under the test's control (createFakePage's higher-level fixtures
// above prove the same fix through the full processDateGroup path, but
// can't isolate "the dialog is never visible, no matter what the panel text
// does" as directly as this).

test('moveToTrash: confirm dialog NEVER becomes visible (neither the \'#\' shortcut nor the toolbar fallback show one) -> not confirmed, regardless of what the panel text does', async () => {
  // The panel text changing here (even wildly, on every poll) must not
  // matter -- this IS the B4D8DDA7... shape: a view that moves on for
  // reasons that have nothing to do with a dialog ever having been shown.
  let evaluateCalls = 0;
  const page = {
    keyboard: { press: async () => {} },
    locator: () => ({
      first: () => ({ isVisible: async () => false, click: async () => {} }),
      all: async () => [], // no visible toolbar trash control either
    }),
    evaluate: async () => {
      evaluateCalls += 1;
      return `panel text that changes every read #${evaluateCalls}`;
    },
  };

  const confirmed = await moveToTrash(page, 'ORIGINAL PANEL TEXT');

  assert.equal(confirmed, false, 'a confirm dialog that never appears must never read as a confirmed trash');
});

test('moveToTrash: confirm dialog shown and clicked, followed by the "moved to trash" toast -> confirmed', async () => {
  let dialogVisible = false;
  let toastVisible = false;
  const page = {
    keyboard: {
      press: async (key) => {
        if (key === '#') dialogVisible = true; // '#' opens the confirm dialog
      },
    },
    locator: (selector) => ({
      first: () => ({
        isVisible: async () => {
          if (/has-text\("Move to trash"\)|has-text\("Delete"\)/i.test(selector)) return dialogVisible;
          if (/moved to \(trash\|bin\)/i.test(selector)) return toastVisible;
          return false;
        },
        click: async () => {
          // Clicking the dialog's own confirm button is what actually
          // performs the trash and surfaces the toast -- mirrors the real
          // two-step flow (dialog appears -> click -> Google shows a toast).
          if (/has-text\("Move to trash"\)|has-text\("Delete"\)/i.test(selector)) {
            dialogVisible = false;
            toastVisible = true;
          }
        },
      }),
      all: async () => [],
    }),
    evaluate: async () => '', // panel text never changes -- the toast alone must be sufficient
  };

  const confirmed = await moveToTrash(page, 'ORIGINAL PANEL TEXT');

  assert.equal(confirmed, true, 'a genuinely shown-and-clicked dialog followed by the toast must confirm');
});

// REWRITTEN 2026-09-01 for the in-photo-view traversal: "how many tiles were
// opened" is no longer the right fingerprint (only the first tile is ever
// grid-clicked -- see the two tests above), so this now checks how many
// photos the ArrowRight loop actually stepped through instead.
test('hitting MAX_STEPS_PER_DATE is logged as ABANDONED, distinct from a genuinely EXHAUSTED date', async () => {
  await withTempQueue(async (queue) => {
    // Case 1: a huge day (more photos than the cap), nothing ever matches ->
    // the walk must stop at the cap and say so distinctly, never reaching
    // the (nonexistent) end of the day's results.
    const { job: bigJob } = queue.enqueue({ ...IMG_1433_JOB, filename: 'IMG_NOMATCH.HEIC' });
    const bigLabels = Array.from({ length: MAX_STEPS_PER_DATE + 10 }, (_, i) => `Photo - Portrait - tile-${i}`);
    const bigPanels = {};
    // Real (parseable) IMG_#### filenames, not the raw tile label -- openInfoPanelOnce's
    // readiness now polls for a FILENAME (parsePanelText's FILENAME_PATTERNS, "IMG_\d+" or
    // a UUID -- see its 2026-09-22 header), which the label text itself never matches, so a
    // panel whose only "filename" is the label text would (correctly, but not what this test
    // is exercising) time out before ever reaching the MAX_STEPS_PER_DATE bound.
    for (const [i, label] of bigLabels.entries()) bigPanels[label] = panelBlock(`IMG_9${String(i).padStart(4, '0')}.HEIC`, 1000, 1000);
    const bigPage = createFakePage({
      searchResults: { 'August 5, 2026': bigLabels.map((ariaLabel) => ({ ariaLabel })) },
      panelTextByLabel: { 'August 5, 2026': bigPanels },
    });

    const boundLogs = await captureLogs(() => processDateGroup(bigPage, '2026-08-05', [bigJob], queue, { dryRun: true }));
    const boundClicks = bigPage.log.filter((l) => l.startsWith('tile-click:'));
    assert.equal(boundClicks.length, 1, 'only the first tile is ever grid-clicked, even on a huge day');
    const arrowPresses = bigPage.log.filter((l) => l === 'key:ArrowRight').length;
    // Each of the MAX_STEPS_PER_DATE panel-reads that fit under the bound is
    // followed by one ArrowRight press (to reach the NEXT one) before the
    // bound check on the following iteration stops the walk -- so the count
    // is exactly the bound itself, not one less.
    assert.equal(arrowPresses, MAX_STEPS_PER_DATE, `expected exactly ${MAX_STEPS_PER_DATE} ArrowRight presses before the bound stopped the walk, got ${arrowPresses}`);
    assert.ok(
      boundLogs.some((l) => l.includes('ABANDONED') && l.includes('MAX_STEPS_PER_DATE')),
      `expected an ABANDONED/MAX_STEPS_PER_DATE log line, got: ${JSON.stringify(boundLogs)}`
    );

    // Case 2: a small day (fewer photos than the cap), nothing matches -> the
    // walk reaches the genuine end of the day (panel stops changing) and
    // must say EXHAUSTED, never ABANDONED.
    const { job: smallJob } = queue.enqueue({ ...IMG_1433_JOB, filename: 'IMG_ALSO_NOMATCH.HEIC' });
    const smallLabels = ['Photo - Portrait - tile-a', 'Photo - Portrait - tile-b', 'Photo - Portrait - tile-c'];
    const smallPanels = {};
    const smallFilenames = ['IMG_8001.HEIC', 'IMG_8002.HEIC', 'IMG_8003.HEIC']; // see the big-day case's comment above
    smallLabels.forEach((label, i) => (smallPanels[label] = panelBlock(smallFilenames[i], 1000, 1000)));
    const smallPage = createFakePage({
      searchResults: { 'August 6, 2026': smallLabels.map((ariaLabel) => ({ ariaLabel })) },
      panelTextByLabel: { 'August 6, 2026': smallPanels },
    });

    const exhaustedLogs = await captureLogs(() =>
      processDateGroup(smallPage, '2026-08-06', [smallJob], queue, { dryRun: true })
    );
    const exhaustedClicks = smallPage.log.filter((l) => l.startsWith('tile-click:'));
    assert.equal(exhaustedClicks.length, 1, 'only the first tile is ever grid-clicked');
    const smallArrowPresses = smallPage.log.filter((l) => l === 'key:ArrowRight').length;
    assert.equal(smallArrowPresses, smallLabels.length, `expected ${smallLabels.length} ArrowRight presses (the last one finding no next photo), got ${smallArrowPresses}`);
    assert.ok(
      exhaustedLogs.some((l) => l.includes('EXHAUSTED') && !l.includes('ABANDONED')),
      `expected an EXHAUSTED log line, got: ${JSON.stringify(exhaustedLogs)}`
    );
  });
});

test('a page that reports closed mid-walk ends the run cleanly and leaves untouched jobs queued', async () => {
  await withTempQueue(async (queue) => {
    const { job: job1 } = queue.enqueue(IMG_1433_JOB); // Aug 5
    const { job: job2 } = queue.enqueue({
      filename: 'IMG_2000.HEIC',
      creationDate: '2026-08-10T12:00:00.000Z', // a different date -> its own date group
      pixelWidth: 1000,
      pixelHeight: 1000,
    });
    const groups = groupJobsByDate([job1, job2]);

    const label1 = 'Photo - Portrait - Aug 5, 2026, 6:54:07 PM';
    const label2 = 'Photo - Portrait - Aug 10, 2026, 12:00:00 PM';
    const page = createFakePage({
      searchResults: {
        'August 5, 2026': [{ ariaLabel: label1 }],
        'August 9, 2026': [], // day-1 fallback if job1 somehow didn't match on the 5th (it will)
        'August 10, 2026': [{ ariaLabel: label2 }],
      },
      panelTextByLabel: {
        'August 5, 2026': { [label1]: IMG_1433_BLOCK },
        'August 10, 2026': { [label2]: panelBlock('IMG_2000.HEIC', 1000, 1000) },
      },
      // The tab "closes" right after the 2nd tile is opened across the whole
      // run -- i.e. mid-way through job2's date, after job1 is already done.
      closeAfterTiles: 2,
    });

    const logs = await captureLogs(() => runDateGroups(page, groups, queue, { dryRun: false }));

    assert.equal(queue.getById(job1.id).status, 'trashed', 'job1 was fully processed before the tab closed');
    assert.equal(queue.getById(job2.id).status, 'queued', 'job2 must be left untouched, not error/needs_review');
    assert.ok(
      logs.some((l) => /tab went away/i.test(l) && /1 job\(s\) processed/.test(l) && /1 left queued/.test(l)),
      `expected a clean "tab went away" summary line, got: ${JSON.stringify(logs)}`
    );
  });
});

test('runDateGroups: a real (non-page-closed) throw mid-date must not overwrite a job the run ALREADY trashed', async () => {
  await withTempQueue(async (queue) => {
    // Two jobs in ONE date group. job1's tile opens and matches cleanly and
    // gets trashed; job2's tile has no panelTextByLabel entry at all, so
    // openInfoPanelOnce (called per-tile under walk='grid') spins past its
    // deadline and throws "info panel never produced filename text" --
    // a real mid-group failure, not the page-closed path exercised above.
    const { job: job1 } = queue.enqueue(IMG_1433_JOB);
    const { job: job2 } = queue.enqueue(IMG_1441_JOB);
    const groups = groupJobsByDate([job1, job2]);

    const label1 = 'Photo - Portrait - Aug 5, 2026, 6:54:07 PM';
    const label2 = 'Photo - Portrait - Aug 5, 2026, 7:31:07 PM';
    const page = createFakePage({
      searchResults: {
        'August 5, 2026': [{ ariaLabel: label1 }, { ariaLabel: label2 }],
      },
      panelTextByLabel: {
        'August 5, 2026': { [label1]: IMG_1433_BLOCK }, // label2 deliberately has no entry
      },
    });

    await assert.rejects(
      () => runDateGroups(page, groups, queue, { dryRun: false, walk: 'grid' }),
      /info panel never produced filename text/
    );

    // The bug: runDateGroups' catch block used to mark every job in the
    // in-memory `unmatched` array as 'error', including job1 -- which
    // processDateGroup had ALREADY resolved to 'trashed' before the throw.
    // That silently rewrote a genuine deletion record into a false failure.
    // The fix reads each job's CURRENT persisted status back from the queue
    // and only marks it 'error' if it is still 'queued'.
    assert.equal(queue.getById(job1.id).status, 'trashed', 'a job already trashed this run must keep that status, never be overwritten to error');
    assert.equal(queue.getById(job2.id).status, 'error', 'the job that was genuinely never resolved must still be marked error');
  });
});

test('isPageClosedError recognizes both page.isClosed() and the Playwright closed-target error text', () => {
  const closedPage = createFakePage();
  closedPage._closed = true;
  assert.equal(isPageClosedError(closedPage, new Error('some other error')), true);

  const openPage = createFakePage();
  assert.equal(isPageClosedError(openPage, new Error('Target page, context or browser has been closed')), true);
  assert.equal(isPageClosedError(openPage, new Error('totally unrelated failure')), false);
});

// -- CHANGE 1: aria fast-path integration tests -----------------------------
//
// These use real tile aria-label timestamps (not the placeholder
// "tile-A"-style labels the tests above use), computed at a genuine +6h
// offset from each job's UTC creationDate -- same shape as the live tiles
// described in the task brief ("Photo - Portrait - Aug 5, 2026, 6:54:07 PM").

test('aria fast path: with many tiles on the date but few jobs, only the matched tiles get opened', async () => {
  await withTempQueue(async (queue) => {
    const { job: jobPhoto } = queue.enqueue({
      filename: 'IMG_3001.HEIC',
      creationDate: '2026-08-05T10:00:00.000Z',
      pixelWidth: 1000,
      pixelHeight: 1000,
      mediaType: 'image',
    });
    const { job: jobVideo } = queue.enqueue({
      filename: 'IMG_3002.MOV',
      creationDate: '2026-08-05T11:15:00.000Z',
      pixelWidth: 1920,
      pixelHeight: 1080,
      mediaType: 'video',
    });
    // True tiles (+6h local offset, matching the two jobs above) plus a
    // decoy Photo tile sharing jobVideo's exact predicted second (proves
    // mediaType gating, not just timestamp, decides the match) plus 5
    // unrelated decoy tiles elsewhere on the date.
    const tPhoto = 'Photo - Portrait - Aug 5, 2026, 4:00:00 PM';
    const tVideoTrue = 'Video - Landscape - Aug 5, 2026, 5:15:00 PM';
    const tVideoDecoyPhoto = 'Photo - Landscape - Aug 5, 2026, 5:15:00 PM'; // same second as tVideoTrue, wrong kind
    const decoys = [
      'Photo - Portrait - Aug 5, 2026, 1:00:00 AM',
      'Photo - Portrait - Aug 5, 2026, 2:11:17 AM',
      'Photo - Portrait - Aug 5, 2026, 3:22:34 AM',
      'Photo - Portrait - Aug 5, 2026, 4:33:51 AM',
      'Photo - Portrait - Aug 5, 2026, 5:44:08 AM',
    ];
    // The true tiles go LAST: if the aria fast path didn't actually fire and
    // the code fell back to opening tiles in grid order instead, it would
    // have to open every decoy before ever reaching a real match, which
    // would blow well past the "exactly 2" assertion below and expose the
    // regression. (Putting them first would let a broken always-exhaustive
    // fallback coincidentally match this assertion too, since the walk stops
    // as soon as every job is matched -- verified by mutation, see report.)
    const allLabels = [...decoys, tVideoDecoyPhoto, tPhoto, tVideoTrue];

    const page = createFakePage({
      searchResults: { 'August 5, 2026': allLabels.map((ariaLabel) => ({ ariaLabel })) },
      panelTextByLabel: {
        // Only the two TRUE tiles get panel text -- if the aria fast path
        // regressed and opened a decoy instead, its panel would come back
        // empty and the job would wrongly go unmatched, failing this test.
        'August 5, 2026': {
          [tPhoto]: panelBlock('IMG_3001.HEIC', 1000, 1000),
          [tVideoTrue]: panelBlock('IMG_3002.MOV', 1920, 1080),
        },
      },
    });

    const { stillUnmatched } = await processDateGroup(page, '2026-08-05', [jobPhoto, jobVideo], queue, { dryRun: false });

    assert.equal(stillUnmatched.length, 0);
    assert.equal(queue.getById(jobPhoto.id).status, 'trashed');
    assert.equal(queue.getById(jobVideo.id).status, 'trashed');

    const tileClicks = page.log.filter((l) => l.startsWith('tile-click:'));
    assert.equal(tileClicks.length, 2, `expected exactly 2 tiles opened (of ${allLabels.length} on the date), got: ${JSON.stringify(tileClicks)}`);
    assert.ok(tileClicks.includes(`tile-click:${tPhoto}`));
    assert.ok(tileClicks.includes(`tile-click:${tVideoTrue}`));
    assert.ok(!tileClicks.includes(`tile-click:${tVideoDecoyPhoto}`), 'video job must match the Video tile, never the same-second Photo decoy');
    for (const decoy of decoys) {
      assert.ok(!tileClicks.includes(`tile-click:${decoy}`), `unrelated decoy tile "${decoy}" must never be opened`);
    }
  });
});

// REWRITTEN 2026-09-01: the exhaustive fallback no longer opens tiles
// individually from the grid (see module header / walkPhotoView) -- it
// grid-clicks only the date's first tile, then reaches everything else with
// ArrowRight, so "opened the colliding tile" is no longer a 'tile-click' log
// entry. The safety property under test (never guess between two tiles at
// the same predicted second) is unchanged; only the fingerprint that proves
// the fallback engaged is updated: exactly ONE grid click, everything else
// via traversal.
test('aria fast path: two tiles sharing the same predicted second fall back to the exhaustive walk, never a guess', async () => {
  await withTempQueue(async (queue) => {
    const { job: job1 } = queue.enqueue(IMG_1433_JOB); // Aug 5, 12:54:07Z -> local 6:54:07 PM at +6h
    const { job: job2 } = queue.enqueue(IMG_1441_JOB); // Aug 5, 13:31:07Z -> local 7:31:07 PM at +6h
    const label1 = 'Photo - Portrait - Aug 5, 2026, 6:54:07 PM';
    const label2 = 'Photo - Portrait - Aug 5, 2026, 7:31:07 PM';
    // A second tile at job2's exact predicted second+mediaType -- a genuine
    // burst-shot collision. planAriaMatches must refuse the WHOLE date
    // rather than guess between label2 and this one.
    const collidingLabel = 'Photo - Landscape - Aug 5, 2026, 7:31:07 PM';
    const labels = [label1, collidingLabel, label2];
    const page = createFakePage({
      searchResults: { 'August 5, 2026': labels.map((ariaLabel) => ({ ariaLabel })) },
      panelTextByLabel: {
        'August 5, 2026': {
          [label1]: IMG_1433_BLOCK,
          [label2]: IMG_1441_BLOCK,
          [collidingLabel]: panelBlock('IMG_9999.HEIC', 1000, 1000), // matches neither job -- just noise the walk must step past
        },
      },
    });

    const { stillUnmatched } = await processDateGroup(page, '2026-08-05', [job1, job2], queue, { dryRun: false });

    assert.equal(stillUnmatched.length, 0, 'the exhaustive walk must still resolve both jobs by filename');
    assert.equal(queue.getById(job1.id).status, 'trashed');
    assert.equal(queue.getById(job2.id).status, 'trashed');
    // Ambiguity is now per job: job1 is unambiguous and may be planned by the
    // aria path, while job2's burst-shot collision leaves IT to the walk. The
    // property that matters is not which mechanism resolved each job, but that
    // the collision was never guessed: exactly two deletions happened, both
    // filename-confirmed, and the colliding photo (IMG_9999.HEIC, which
    // matches neither job) was not one of them.
    const deletions = page.log.filter((l) => l === 'key:#').length;
    assert.equal(deletions, 2, 'exactly two photos deleted -- the collision must never be guessed into a third');
    assert.ok(
      !page.log.some((l) => l.includes('IMG_9999')),
      'the colliding photo must never be acted on'
    );
  });
});

test('aria fast path: a predicted tile that does not confirm by filename is never trashed (falls through to the exhaustive walk)', async () => {
  await withTempQueue(async (queue) => {
    const { job: job1 } = queue.enqueue(IMG_1433_JOB);
    const { job: job2 } = queue.enqueue(IMG_1441_JOB);
    const label1 = 'Photo - Portrait - Aug 5, 2026, 6:54:07 PM';
    const label2 = 'Photo - Portrait - Aug 5, 2026, 7:31:07 PM';
    const page = createFakePage({
      searchResults: { 'August 5, 2026': [{ ariaLabel: label1 }, { ariaLabel: label2 }] },
      panelTextByLabel: {
        'August 5, 2026': {
          [label1]: IMG_1433_BLOCK, // job1's aria-predicted tile confirms normally
          // job2's aria-predicted tile (label2) opens to a DIFFERENT photo's
          // panel -- simulates the aria prediction landing on the wrong
          // tile. Must never be trashed off the aria match alone.
          [label2]: panelBlock('IMG_9999.HEIC', 3024, 4032, 'Aug 5Wed, 7:31 PMGMT-06:00'),
        },
      },
    });

    const { stillUnmatched } = await processDateGroup(page, '2026-08-05', [job1, job2], queue, { dryRun: false });

    assert.equal(queue.getById(job1.id).status, 'trashed', 'job1 confirmed normally via the aria match');
    assert.equal(stillUnmatched.length, 1, 'job2 must remain unresolved, not silently dropped or trashed');
    assert.equal(stillUnmatched[0].id, job2.id);
    assert.equal(queue.getById(job2.id).status, 'queued', 'processDateGroup itself must not mark it -- unchanged from the pre-existing filename-mismatch contract');
    // '#' (the trash shortcut) must be pressed exactly once -- job1's
    // legitimate trash. If job2's mismatched aria-predicted tile had been
    // trashed anyway, this would be 2.
    const trashPresses = page.log.filter((l) => l === 'key:#');
    assert.equal(trashPresses.length, 1, 'the mismatched tile must never reach the trash keyboard shortcut');
  });
});

// -- Regression tests for the two live failures fixed 2026-09-01 -----------
//
// Both bugs were diagnosed from real runs (see worker.mjs's module header
// and openTile/openInfoPanelOnce comments), not reproduced here against
// live Google Photos -- these fixtures model the specific failure shape.

test('positional-drift regression: a tile addressed by grid position can land on "Back to search" instead of the intended photo; identity addressing must not', async () => {
  await withTempQueue(async (queue) => {
    const { job } = queue.enqueue(IMG_1433_JOB);
    const label = 'Photo - Portrait - Aug 5, 2026, 6:54:07 PM';
    const page = createFakePage({
      // "Back to search" carries the same `./search/` href prefix as a real
      // tile (RESULT_LINK_SELECTOR matches it) -- exactly the live collision:
      // a click aimed at nth(48) in the real grid hit that link instead of a
      // photo. isRealPhotoTile filters it out of the walkable tile queue
      // (its aria-label doesn't start with "Photo -"/"Video -"), same as
      // live, so with the fix it is never even a candidate to open.
      searchResults: {
        'August 5, 2026': [{ ariaLabel: 'Back to search' }, { ariaLabel: label }],
      },
      panelTextByLabel: {
        'August 5, 2026': { [label]: IMG_1433_BLOCK },
      },
      // Models the grid re-rendering between "we decided to open this tile"
      // and "we actually clicked it": a POSITIONAL locator (the pre-fix
      // tile.locator.click()) held for `label` would silently resolve to
      // "Back to search" by click time. The identity-scoped locator
      // worker.mjs's openTile uses now (tileLocatorFor) looks the tile up by
      // aria-label fresh on every call and cannot be fooled by this -- see
      // FakeTileLink.click() / FakeLocator.click() in fakePage.mjs.
      staleTileClickTargets: { [label]: 'Back to search' },
    });

    const { stillUnmatched } = await processDateGroup(page, '2026-08-05', [job], queue, { dryRun: false });

    assert.equal(stillUnmatched.length, 0, 'the intended tile must still be opened and matched despite the positional-drift fixture');
    assert.equal(queue.getById(job.id).status, 'trashed');
    assert.ok(page.log.includes(`tile-click:${label}`), 'must open the intended tile by identity');
    assert.ok(!page.log.includes('tile-click:Back to search'), 'must NEVER open the "Back to search" link');
  });
});

test('lost-keystroke regression: the info panel opens even when the first "i" press is lost, and openInfoPanelOnce still throws (never hangs) if the panel truly never opens', async () => {
  await withTempQueue(async (queue) => {
    // Case 1: the panel eventually opens, but only after openInfoPanelOnce
    // re-presses "i" (its first press is dropped, modeling the keystroke
    // landing mid-transition before the photo view existed -- see
    // openInfoPanelOnce's comment on the re-press-every-8th-poll behaviour).
    const { job } = queue.enqueue(IMG_1433_JOB);
    const label = 'Photo - Portrait - Aug 5, 2026, 6:54:07 PM';
    const page = createFakePage({
      searchResults: { 'August 5, 2026': [{ ariaLabel: label }] },
      panelTextByLabel: { 'August 5, 2026': { [label]: IMG_1433_BLOCK } },
      swallowInfoPressesCount: 1,
    });

    const { stillUnmatched } = await processDateGroup(page, '2026-08-05', [job], queue, { dryRun: false });

    assert.equal(stillUnmatched.length, 0, 'must still match once the re-press opens the panel');
    assert.equal(queue.getById(job.id).status, 'trashed');
    const iPresses = page.log.filter((l) => l === 'key:i').length;
    assert.ok(iPresses >= 2, `expected the first "i" press to be lost and a later re-press to succeed, got ${iPresses} press(es)`);

    // Case 2: a photo view whose panel NEVER yields dimensions text (no
    // panelTextByLabel entry at all) must still throw once the deadline
    // elapses, rather than the re-press loop hanging forever.
    const { job: neverJob } = queue.enqueue({ ...IMG_1441_JOB, filename: 'IMG_NEVER.HEIC' });
    const neverLabel = 'Photo - Portrait - Aug 5, 2026, 8:00:00 PM';
    const neverPage = createFakePage({
      searchResults: { 'August 5, 2026': [{ ariaLabel: neverLabel }] },
      panelTextByLabel: { 'August 5, 2026': {} }, // no entry for neverLabel -- panel content never arrives
    });

    await assert.rejects(
      () => processDateGroup(neverPage, '2026-08-05', [neverJob], queue, { dryRun: false }),
      /info panel never produced filename text/,
      'must throw rather than hang when the panel genuinely never opens'
    );
  });
});

// DELETED 2026-09-01 (was: 'closeAnyOpenPhoto regression: the search box
// staying visible while a photo is open must not be mistaken for "back at
// the grid"...'). It exercised the OLD exhaustive walk's specific
// tile-1-opened/closed-via-closeAnyOpenPhoto/tile-2-opened cycle, which no
// longer exists: the new in-photo-view traversal never calls
// closeAnyOpenPhoto mid-date at all (only between DATES, in searchByDate).
// closeAnyOpenPhoto's own Escape-detection logic (the live bug it fixes)
// remains covered end-to-end by 'aria fast path: with many tiles on the
// date but few jobs...' above, which opens two DISTINCT tiles via the aria
// loop and must closeAnyOpenPhoto genuinely between them.

test('--slow: parseArgs recognizes the flag, and stealthDelayRange restores the long delays only when slow=true', () => {
  assert.equal(parseArgs([]).slow, false, 'off by default');
  assert.equal(parseArgs(['--dry-run', '--slow', '--cap', '10']).slow, true);

  assert.deepEqual(stealthDelayRange(500, 2000, false), [0, 0], 'default (fast): no jitter');
  assert.deepEqual(stealthDelayRange(500, 2000, true), [500, 2000], '--slow: original human-scale range restored');
});


// -- CHANGE 2 (2026-09-01): aria pre-scroll cumulative-set fix, and the
// ambiguity-safety risk that motivated it --------------------------------
//
// The aria fast path's OWN pre-scroll loop had the exact count-based bug
// already fixed in the exhaustive walk above: it judged "did that scroll
// load anything new" by comparing on-screen tile COUNTS, which a virtualized
// window swap can hold flat while the labels underneath move on entirely.
// planAriaMatches() got handed whatever tiles happened to be on-screen when
// the (buggy) loop broke -- never the FULL set the date ever showed -- which
// is a correctness risk, not just a coverage one: planAriaMatches uses the
// full set to decide whether a predicted match is AMBIGUOUS (see the
// ambiguity-safety test below).

test('pre-scroll accumulates across windows, so planAriaMatches sees the full cumulative tile set (not just the last on-screen snapshot)', async () => {
  await withTempQueue(async (queue) => {
    const { job: job1 } = queue.enqueue(IMG_1433_JOB); // Aug 5, 12:54:07Z -> local 6:54:07 PM at +6h
    const { job: job2 } = queue.enqueue(IMG_1441_JOB); // Aug 5, 13:31:07Z -> local 7:31:07 PM at +6h
    const label1 = 'Photo - Portrait - Aug 5, 2026, 6:54:07 PM'; // job1's real match
    const label2 = 'Photo - Portrait - Aug 5, 2026, 7:31:07 PM'; // job2's real match
    // Non-colliding filler, interleaved so label1 (revealed early) has fallen
    // OUT of the mounted window (windowSize: 2) by the time the pre-scroll
    // loop stops -- decoyC and label2 are the only ones still on-screen.
    const decoyA = 'Photo - Portrait - filler-a';
    const decoyB = 'Photo - Portrait - filler-b';
    const decoyC = 'Photo - Portrait - filler-c';

    const page = createFakePage({
      searchResults: { 'August 5, 2026': [{ ariaLabel: decoyA }] },
      scrollReveals: {
        'August 5, 2026': [[{ ariaLabel: decoyB }], [{ ariaLabel: label1 }], [{ ariaLabel: decoyC }], [{ ariaLabel: label2 }]],
      },
      panelTextByLabel: {
        'August 5, 2026': {
          [decoyA]: panelBlock('IMG_9990.HEIC', 1000, 1000),
          [decoyB]: panelBlock('IMG_9991.HEIC', 1000, 1000),
          [decoyC]: panelBlock('IMG_9992.HEIC', 1000, 1000),
          [label1]: IMG_1433_BLOCK,
          [label2]: IMG_1441_BLOCK,
        },
      },
      windowSize: 2, // by the time all 4 reveals have loaded, only the last 2 (decoyC, label2) are mounted -- label1 fell out 2 scrolls ago
    });

    const { stillUnmatched } = await processDateGroup(page, '2026-08-05', [job1, job2], queue, { dryRun: false });

    assert.equal(stillUnmatched.length, 0, 'both jobs must still resolve');
    assert.equal(queue.getById(job1.id).status, 'trashed');
    assert.equal(queue.getById(job2.id).status, 'trashed');
    // The fast-path fingerprint: if planAriaMatches saw the CUMULATIVE set
    // (including label1, dropped from the window it merely happens to be
    // ambiguity-free), it predicts both tiles uniquely and opens EXACTLY
    // those 2 -- never touching a decoy. With the count-based bug, label1 is
    // missing from what planAriaMatches sees, job1 can never be uniquely
    // predicted, the WHOLE date falls back to the exhaustive walk, and every
    // decoy gets opened too (proven by mutation -- see report).
    const tileClicks = page.log.filter((l) => l.startsWith('tile-click:'));
    assert.equal(
      tileClicks.length,
      2,
      `expected the aria fast path to fire (exactly 2 tiles opened), got: ${JSON.stringify(tileClicks)}`
    );
    assert.ok(tileClicks.includes(`tile-click:${label1}`));
    assert.ok(tileClicks.includes(`tile-click:${label2}`));
  });
});

// DELETED 2026-09-01 (was: 'upward recovery: a tile scrolled out of the
// window by the pre-scroll is still reached and matched'). It proved the
// OLD exhaustive walk's own up/down scroll-recovery mechanism, which no
// longer exists: the new walk never scrolls or re-collects the grid at all
// -- it captures the date's first tile BEFORE the aria pre-scroll runs
// (processDateGroup's `dateFirstTile`) and then reaches everything else
// with ArrowRight, which pages through the app's own full result order
// regardless of what the grid has mounted (see the module header's "27
// photos in one run" note, and fakePage.mjs's fullOrderedTiles). There is
// no virtualization concern left for this walk to recover from.

// AMBIGUITY SAFETY (2026-09-01): the specific correctness risk problem A
// describes -- a burst-shot duplicate (same predicted second, different
// orientation, so a DIFFERENT aria-label -- see the "two tiles sharing the
// same predicted second" test above for why orientation is what makes this a
// distinct tile rather than a re-render of the same one) that's visible ONLY
// in an early window must still make the aria match AMBIGUOUS, even though
// it has long since scrolled out of view by the time the pre-scroll loop
// stops. If the pre-scroll only ever saw the last on-screen snapshot, the
// duplicate would be invisible to planAriaMatches and job1's real match
// (label1) would look falsely unique -- a WRONG-BUT-LUCKY trash, not a
// caught ambiguity. The exhaustive walk must run instead.
test('ambiguity safety: a duplicate tile visible only in an early window still makes the aria match ambiguous, deferring to the exhaustive walk', async () => {
  await withTempQueue(async (queue) => {
    const { job: job1 } = queue.enqueue(IMG_1433_JOB); // Aug 5, 12:54:07Z -> local 6:54:07 PM at +6h
    const { job: job2 } = queue.enqueue(IMG_1441_JOB); // Aug 5, 13:31:07Z -> local 7:31:07 PM at +6h
    const label1 = 'Photo - Portrait - Aug 5, 2026, 6:54:07 PM'; // job1's real match
    const label2 = 'Photo - Portrait - Aug 5, 2026, 7:31:07 PM'; // job2's real match
    // Same predicted second as label1, different orientation -- a genuine
    // burst-shot collision, revealed FIRST (in searchResults) and long
    // scrolled out of the window by the time the pre-scroll loop stops.
    const dupLabel = 'Photo - Landscape - Aug 5, 2026, 6:54:07 PM';
    const decoyA = 'Photo - Portrait - Aug 5, 2026, 1:00:00 AM'; // non-colliding filler

    const page = createFakePage({
      searchResults: { 'August 5, 2026': [{ ariaLabel: dupLabel }] },
      scrollReveals: { 'August 5, 2026': [[{ ariaLabel: decoyA }], [{ ariaLabel: label1 }], [{ ariaLabel: label2 }]] },
      panelTextByLabel: {
        'August 5, 2026': {
          [dupLabel]: panelBlock('IMG_9998.HEIC', 1000, 1000), // matches neither job -- just noise the walk must step past
          [decoyA]: panelBlock('IMG_9997.HEIC', 1000, 1000),
          [label1]: IMG_1433_BLOCK,
          [label2]: IMG_1441_BLOCK,
        },
      },
      windowSize: 3, // dupLabel has fallen out of the mounted window by the time all 3 reveals have loaded
    });

    const { stillUnmatched } = await processDateGroup(page, '2026-08-05', [job1, job2], queue, { dryRun: false });

    assert.equal(stillUnmatched.length, 0, 'the exhaustive walk must still resolve both jobs by filename');
    assert.equal(queue.getById(job1.id).status, 'trashed');
    assert.equal(queue.getById(job2.id).status, 'trashed');
    // Under the per-job ambiguity contract the unambiguous job may legitimately
    // be planned by the aria path while the ambiguous one falls to the walk, so
    // counting grid clicks no longer identifies which mechanism ran. What must
    // hold regardless -- and what the count-based pre-scroll bug would have
    // broken -- is that the DUPLICATE tile is never acted on and no third
    // deletion occurs. planAriaMatches' per-job refusal itself is covered
    // directly in matcher.test.mjs.
    // The walk legitimately OPENS the duplicate -- that is how it reads its
    // filename and rules it out. What must never happen is deleting it, so the
    // invariant is the deletion count, not whether the tile was visited.
    const deletions = page.log.filter((l) => l === 'key:#').length;
    assert.equal(deletions, 2, 'exactly the two real jobs are deleted, never the duplicate');
  });
});

// -- In-photo-view traversal (2026-09-01 rewrite): auto-advance-after-trash
// and the "info panel opened once, not per photo" invariant -----------------

// REGRESSION-SHAPED (2026-09-01): a trashed photo disappears from the day's
// results, and fakePage's performTrash (matching the live behaviour the
// module header describes) auto-advances the view straight onto the NEXT
// photo by itself. walkPhotoView must detect that (by the panel content
// having already moved on) and NOT blindly press ArrowRight afterward -- a
// blind press here would skip the very photo the auto-advance just landed
// on. Two adjacent jobs (B's tile immediately follows A's) makes this
// concrete: if the code ever presses ArrowRight unconditionally after every
// trash, it walks A -> (auto-advance) -> B -> (blind ArrowRight) -> C,
// reading C instead of B and leaving job B permanently unmatched.
test('after a successful trash, traversal does not skip the following photo (the auto-advance case)', async () => {
  await withTempQueue(async (queue) => {
    const { job: jobA } = queue.enqueue(IMG_1433_JOB);
    const { job: jobB } = queue.enqueue(IMG_1441_JOB);
    const labels = [
      'Photo - Portrait - tile-A (match A)',
      'Photo - Portrait - tile-B (match B, right after A)',
      'Photo - Portrait - tile-C (no match)',
    ];
    const page = createFakePage({
      searchResults: { 'August 5, 2026': labels.map((ariaLabel) => ({ ariaLabel })) },
      panelTextByLabel: {
        'August 5, 2026': {
          [labels[0]]: IMG_1433_BLOCK,
          [labels[1]]: IMG_1441_BLOCK,
          [labels[2]]: panelBlock('IMG_9999.HEIC', 1000, 1000),
        },
      },
    });

    const { stillUnmatched } = await processDateGroup(page, '2026-08-05', [jobA, jobB], queue, { dryRun: false });

    assert.equal(stillUnmatched.length, 0, 'job B must not be skipped by a blind ArrowRight after job A auto-advances onto it');
    assert.equal(queue.getById(jobA.id).status, 'trashed');
    assert.equal(queue.getById(jobB.id).status, 'trashed');
    // The fingerprint: trashing A auto-advances the view straight onto B, and
    // trashing B auto-advances onto C -- reaching and confirming BOTH matches
    // costs ZERO ArrowRight presses. C is a non-match, and (2026-09-12
    // duplicate-detection change) the walk keeps going past it looking for a
    // further copy of A or B rather than stopping the instant both are
    // matched -- that costs exactly ONE press (the failed attempt to advance
    // past C, the actual last tile).
    const arrowPresses = page.log.filter((l) => l === 'key:ArrowRight').length;
    assert.equal(arrowPresses, 1, 'job A auto-advances directly onto job B, and job B onto C; the only ArrowRight is the failed attempt past C');
  });
});

// The info panel is STICKY (opened once, stays open across photos -- see
// openInfoPanelOnce's header) and pressing "i" while it's already open
// CLOSES it. walkPhotoView must therefore call openInfoPanelOnce exactly
// ONCE for the whole date, before the ArrowRight loop starts, never again
// per photo.
test('the info panel is opened ONCE per date, not once per photo', async () => {
  await withTempQueue(async (queue) => {
    const PHOTO_COUNT = 6;
    const { job } = queue.enqueue(IMG_1433_JOB);
    const labels = Array.from({ length: PHOTO_COUNT }, (_, i) => `Photo - Portrait - tile-${i}`);
    const panelTextByLabel = { 'August 5, 2026': {} };
    for (let i = 0; i < PHOTO_COUNT - 1; i++) {
      panelTextByLabel['August 5, 2026'][labels[i]] = panelBlock(`IMG_90${i}.HEIC`, 1000, 1000);
    }
    panelTextByLabel['August 5, 2026'][labels[PHOTO_COUNT - 1]] = IMG_1433_BLOCK; // match, last photo

    const page = createFakePage({
      searchResults: { 'August 5, 2026': labels.map((ariaLabel) => ({ ariaLabel })) },
      panelTextByLabel,
    });

    const { stillUnmatched } = await processDateGroup(page, '2026-08-05', [job], queue, { dryRun: false });

    assert.equal(stillUnmatched.length, 0);
    const iPresses = page.log.filter((l) => l === 'key:i').length;
    assert.equal(iPresses, 1, `expected exactly one "i" press across all ${PHOTO_COUNT} photos walked, got ${iPresses}`);
  });
});

// -- --walk=<photo|grid> A/B (2026-09-01) ------------------------------------
//
// Both the in-photo-view walk (walkPhotoView, default) and the recovered
// grid-return walk (walkGrid, RECOVERED FROM HISTORY -- see worker.mjs's
// walkGrid header for why it's a recovery, not a rewrite, and what root
// cause its old failure actually traced to) share the exact same
// matching/deletion path (confirmAndTrash) and only differ in HOW a tile
// gets opened and read. These tests prove that sameness holds, and that the
// `walk` option genuinely selects between the two rather than being ignored.

test('both --walk strategies reach a job whose photo is LAST on the date; the default (no walk option) behaves as --walk=photo', async () => {
  const TILE_COUNT = 12;
  const buildFixture = () => {
    const labels = Array.from({ length: TILE_COUNT }, (_, i) => `Photo - Portrait - tile-${i}`);
    const panelTextByLabel = { 'August 5, 2026': {} };
    for (let i = 0; i < TILE_COUNT - 1; i++) {
      panelTextByLabel['August 5, 2026'][labels[i]] = panelBlock(`IMG_920${i}.HEIC`, 1000, 1000);
    }
    panelTextByLabel['August 5, 2026'][labels[TILE_COUNT - 1]] = IMG_1433_BLOCK; // the match, LAST tile
    return { labels, panelTextByLabel };
  };

  // --walk=photo: exactly one grid tile-click (tile 0), the rest via ArrowRight.
  await withTempQueue(async (queue) => {
    const { job } = queue.enqueue(IMG_1433_JOB);
    const { labels, panelTextByLabel } = buildFixture();
    const page = createFakePage({ searchResults: { 'August 5, 2026': labels.map((ariaLabel) => ({ ariaLabel })) }, panelTextByLabel });

    const { stillUnmatched } = await processDateGroup(page, '2026-08-05', [job], queue, { dryRun: false, walk: 'photo' });

    assert.equal(stillUnmatched.length, 0, '--walk=photo must still reach the last tile');
    assert.equal(queue.getById(job.id).status, 'trashed');
    assert.equal(page.log.filter((l) => l.startsWith('tile-click:')).length, 1, '--walk=photo grid-clicks only the first tile');
  });

  // --walk=grid: every tile gets its own grid tile-click, zero ArrowRight presses.
  await withTempQueue(async (queue) => {
    const { job } = queue.enqueue(IMG_1433_JOB);
    const { labels, panelTextByLabel } = buildFixture();
    const page = createFakePage({ searchResults: { 'August 5, 2026': labels.map((ariaLabel) => ({ ariaLabel })) }, panelTextByLabel });

    const { stillUnmatched } = await processDateGroup(page, '2026-08-05', [job], queue, { dryRun: false, walk: 'grid' });

    assert.equal(stillUnmatched.length, 0, '--walk=grid must still reach the last tile');
    assert.equal(queue.getById(job.id).status, 'trashed');
    assert.equal(page.log.filter((l) => l.startsWith('tile-click:')).length, TILE_COUNT, '--walk=grid opens each tile individually from the grid');
    assert.equal(page.log.filter((l) => l === 'key:ArrowRight').length, 0, '--walk=grid never presses ArrowRight');
  });

  // No `walk` option at all: must behave exactly like --walk=photo (the
  // documented default), never like --walk=grid.
  await withTempQueue(async (queue) => {
    const { job } = queue.enqueue(IMG_1433_JOB);
    const { labels, panelTextByLabel } = buildFixture();
    const page = createFakePage({ searchResults: { 'August 5, 2026': labels.map((ariaLabel) => ({ ariaLabel })) }, panelTextByLabel });

    const { stillUnmatched } = await processDateGroup(page, '2026-08-05', [job], queue, { dryRun: false });

    assert.equal(stillUnmatched.length, 0, 'default (no walk option) must still reach the last tile');
    assert.equal(queue.getById(job.id).status, 'trashed');
    assert.equal(page.log.filter((l) => l.startsWith('tile-click:')).length, 1, 'default must grid-click only the first tile, i.e. behave as --walk=photo');
  });

  // parseArgs itself: no --walk flag defaults to 'photo'.
  assert.equal(parseArgs([]).walk, 'photo', 'parseArgs must default walk to "photo" when --walk is omitted');
  assert.equal(parseArgs(['--walk=grid']).walk, 'grid');
  assert.equal(parseArgs(['--walk=photo']).walk, 'photo');
});

// REGRESSION TEST for the exact bug walkGrid's cumulative `seen` set exists
// to prevent: a VIRTUALIZED grid (config.windowSize) only ever mounts a
// WINDOW of tiles, so the on-screen tile COUNT can stay perfectly flat across
// a scroll even though the window has moved on to an entirely different set
// of labels underneath. Judging "did that scroll find anything new" by
// comparing on-screen COUNTS (rather than the label SET, as `seen`/mergeSeen
// do) is blind to this and made a real 27-tile date report EXHAUSTED after
// visiting only 2-3 tiles live. Proven by mutation in the report: replacing
// walkGrid's label-set `mergeSeen`/`recoveredKnown` progress check with a
// tile-count comparison reproduces exactly that -- the walk's "no on-screen
// candidate" branch reads a flat count as "no progress" and gives up
// scrolling long before every tile is reached.
//
// No job matches ANY tile on this date -- deliberately, so the walk cannot
// stop early once it happens to find a match (as in the "reach the last
// tile" tests above) and is forced to genuinely exhaust every tile the date
// has, which is the only way to prove ALL of them were walked rather than
// just enough to satisfy the jobs. WINDOW_SIZE=4 against 7 total tiles is
// chosen so a SINGLE up-scroll from the tail window (started at index 3)
// reaches all the way back to index 0 -- proving the recovery path (not just
// the initial downward pre-scroll) also participates in exhausting the date.
test('the grid strategy walks EVERY tile on a virtualized date: the on-screen window moves but the count stays flat', async () => {
  await withTempQueue(async (queue) => {
    const { job } = queue.enqueue({ ...IMG_1433_JOB, filename: 'IMG_NOMATCH.HEIC' });
    const WINDOW_SIZE = 4;
    const REVEAL_BATCHES = 6; // 1 initial (searchResults) + 6 reveals = 7 total tiles
    const labels = Array.from({ length: REVEAL_BATCHES + 1 }, (_, i) => `Photo - Portrait - tile-${i}`);
    const panelTextByLabel = { 'August 5, 2026': {} };
    // Real (parseable) IMG_#### filenames, not the raw tile label -- see the
    // MAX_STEPS_PER_DATE test's identical comment above for why.
    labels.forEach((label, i) => {
      panelTextByLabel['August 5, 2026'][label] = panelBlock(`IMG_7${String(i).padStart(4, '0')}.HEIC`, 1000, 1000); // never matches IMG_NOMATCH.HEIC
    });

    const page = createFakePage({
      searchResults: { 'August 5, 2026': [{ ariaLabel: labels[0] }] },
      scrollReveals: { 'August 5, 2026': labels.slice(1).map((l) => [{ ariaLabel: l }]) },
      panelTextByLabel,
      windowSize: WINDOW_SIZE, // on-screen count is ALWAYS exactly 4, however far the window has moved
    });

    const logs = await captureLogs(() => processDateGroup(page, '2026-08-05', [job], queue, { dryRun: true, walk: 'grid' }));

    // Every genuinely distinct tile the date ever had must be opened exactly
    // once -- the strongest statement of "walked every tile", not just
    // "found the one that mattered" (there is nothing to find here).
    const uniqueTileClicks = new Set(page.log.filter((l) => l.startsWith('tile-click:')).map((l) => l.slice('tile-click:'.length)));
    assert.equal(
      uniqueTileClicks.size,
      labels.length,
      `expected all ${labels.length} distinct tiles opened, got ${uniqueTileClicks.size}: ${JSON.stringify([...uniqueTileClicks])}`
    );
    // EXHAUSTED, not ABANDONED: every seen tile really was reached, so the
    // walk must say so plainly rather than reporting a bound cutting it off.
    assert.ok(
      logs.some((l) => l.includes('EXHAUSTED') && !l.includes('ABANDONED') && !l.includes('never reached')),
      `expected a clean EXHAUSTED (no ABANDONED / never-reached tiles) log line, got: ${JSON.stringify(logs)}`
    );
  });
});

// REGRESSION TEST: closeAnyOpenPhoto is documented (worker.mjs, and the
// measured live sequence in the task brief) to need EXACTLY one Escape per
// tile-to-tile transition -- a second Escape leaves the search results
// entirely rather than returning to the grid. walkGrid calls it once between
// every pair of consecutive (non-final) tiles it opens; this asserts the
// actual count of Escape presses, not just that the walk eventually succeeds
// (a walk that pressed Escape twice per transition could still "work" against
// this fake, since fakePage's atGrid signal is idempotent under repeats).
test('the grid strategy presses Escape exactly once per tile-to-tile transition', async () => {
  await withTempQueue(async (queue) => {
    const { job } = queue.enqueue(IMG_1433_JOB);
    const TILE_COUNT = 5;
    const labels = Array.from({ length: TILE_COUNT }, (_, i) => `Photo - Portrait - tile-${i}`);
    const panelTextByLabel = { 'August 5, 2026': {} };
    for (let i = 0; i < TILE_COUNT - 1; i++) {
      panelTextByLabel['August 5, 2026'][labels[i]] = panelBlock(`IMG_940${i}.HEIC`, 1000, 1000);
    }
    panelTextByLabel['August 5, 2026'][labels[TILE_COUNT - 1]] = IMG_1433_BLOCK; // match, last tile

    const page = createFakePage({ searchResults: { 'August 5, 2026': labels.map((ariaLabel) => ({ ariaLabel })) }, panelTextByLabel });

    const { stillUnmatched } = await processDateGroup(page, '2026-08-05', [job], queue, { dryRun: false, walk: 'grid' });

    assert.equal(stillUnmatched.length, 0);
    // TILE_COUNT tiles walked in order = TILE_COUNT - 1 transitions between
    // them (the last, matching tile is trashed and the walk stops -- it never
    // closes back to the grid afterward, so it does NOT close-and-reopen).
    const escapePresses = page.log.filter((l) => l === 'key:Escape').length;
    assert.equal(escapePresses, TILE_COUNT - 1, `expected exactly ${TILE_COUNT - 1} Escape presses (one per transition), got ${escapePresses}`);
    assert.equal(page.escapePresses, TILE_COUNT - 1, 'fakePage\'s own Escape counter must agree');
  });
});

// Unconfirmed trash -> needs_review, and filename mismatch -> never trashed,
// must hold identically under BOTH strategies -- they share confirmAndTrash
// (the only place that ever calls moveToTrash / authorises a trash), so
// safety cannot depend on which strategy opened the tile.
for (const walk of ['photo', 'grid']) {
  test(`[--walk=${walk}] a trash action that does not take is recorded as needs_review, never trashed`, async () => {
    await withTempQueue(async (queue) => {
      const { job } = queue.enqueue(IMG_1433_JOB);
      const label = 'Photo - Portrait - Aug 5, 2026, 6:54:07 PM';
      const page = createFakePage({
        searchResults: { 'August 5, 2026': [{ ariaLabel: label }] },
        panelTextByLabel: { 'August 5, 2026': { [label]: IMG_1433_BLOCK } },
        infoButtonFound: true,
        trashButtonVisible: false,
        swallowTrashShortcut: true,
      });

      await processDateGroup(page, '2026-08-05', [queue.getById(job.id)], queue, { dryRun: false, walk });

      const after = queue.getById(job.id);
      assert.equal(after.status, 'needs_review', `[--walk=${walk}] unconfirmed trash must not be recorded as trashed`);
      assert.match(after.error ?? '', /not confirmed/i);
    });
  });

  test(`[--walk=${walk}] filename mismatch never reaches the trash path, even with matching dimensions`, async () => {
    await withTempQueue(async (queue) => {
      const { job } = queue.enqueue(IMG_1433_JOB); // expects IMG_1433.HEIC
      const label = 'Photo - Portrait - Aug 5, 2026, 6:54:07 PM';
      const page = createFakePage({
        searchResults: { 'August 5, 2026': [{ ariaLabel: label }] },
        panelTextByLabel: {
          // Same dimensions as the job, but a different filename.
          'August 5, 2026': { [label]: panelBlock('IMG_0001.HEIC', 2316, 3088) },
        },
      });

      const { stillUnmatched } = await processDateGroup(page, '2026-08-05', [job], queue, { dryRun: false, walk });

      assert.equal(stillUnmatched.length, 1, `[--walk=${walk}] filename mismatch must never match`);
      assert.ok(!page.log.some((l) => l.includes('Move to trash')));
      assert.equal(queue.getById(job.id).status, 'queued', `[--walk=${walk}] job untouched by processDateGroup itself`);
    });
  });
}

// --- exitAfterSettled: the worker-never-terminates regression ------------
//
// Confirmed live (2026-09-22, worker-runs/2026-09-22T13-20-18.443Z.log and
// .../13-51-24.122Z.log): runWorker's own try/catch swallows errors (sets
// process.exitCode = 1, then returns normally instead of re-throwing), so
// the top-level `runWorker(args).catch(...)` never fired, and the still-open
// CDP WebSocket (chromium.connectOverCDP — deliberately never closed, since
// browser.close() would kill Oliver's real Chrome) kept the event loop alive
// forever. The child process sat idle for 30+ minutes until manually killed.
//
// exitAfterSettled fixes this by always calling process.exit() once work()
// settles, on every path (resolve, resolve-with-exitCode-already-set, or
// reject) — see the comment above its definition in worker.mjs.

function spawnNode(scriptPath) {
  return spawn(process.execPath, [scriptPath], { stdio: 'ignore' });
}

/** Resolves true if the child is STILL alive `ms` after spawning (i.e. hung), then kills it. */
function stillRunningAfter(scriptPath, ms) {
  return new Promise((resolve) => {
    const child = spawnNode(scriptPath);
    let exited = false;
    child.on('exit', () => {
      exited = true;
    });
    setTimeout(() => {
      resolve(!exited);
      // Clean up regardless of outcome -- this is the process we expect
      // (and want) to still be hanging on its open handle.
      child.kill('SIGKILL');
    }, ms);
  });
}

/** Resolves once the child exits on its own, or times out (and is force-killed) after `timeoutMs`. */
function waitForExit(scriptPath, timeoutMs) {
  return new Promise((resolve) => {
    const child = spawnNode(scriptPath);
    let settled = false;
    const timer = setTimeout(() => {
      if (settled) return;
      settled = true;
      child.kill('SIGKILL');
      resolve({ timedOut: true, code: null });
    }, timeoutMs);
    child.on('exit', (code) => {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      resolve({ timedOut: false, code });
    });
  });
}

test('exitAfterSettled: process.exit(0) on a clean success', async () => {
  const originalExit = process.exit;
  const originalExitCode = process.exitCode;
  process.exitCode = undefined;
  const exitCalls = [];
  process.exit = (code) => exitCalls.push(code);
  try {
    await exitAfterSettled(async () => 'ok');
    assert.deepEqual(exitCalls, [0]);
  } finally {
    process.exit = originalExit;
    process.exitCode = originalExitCode;
  }
});

test('exitAfterSettled: work() that sets process.exitCode=1 and RETURNS NORMALLY (runWorker\'s own internal catch shape — openInfoPanelOnce timeout, etc.) still forces exit(1)', async () => {
  const originalExit = process.exit;
  const originalExitCode = process.exitCode;
  process.exitCode = undefined;
  const exitCalls = [];
  process.exit = (code) => exitCalls.push(code);
  try {
    await exitAfterSettled(async () => {
      // Mirrors runWorker's `catch (err) { loud(...); process.exitCode = 1; }`
      // — the error is swallowed, not re-thrown, which is exactly what made
      // the old `.catch()`-only wrapper never fire.
      process.exitCode = 1;
    });
    assert.deepEqual(exitCalls, [1]);
  } finally {
    process.exit = originalExit;
    process.exitCode = originalExitCode;
  }
});

test('exitAfterSettled: a work() that THROWS is caught and forces exit(1)', async () => {
  const originalExit = process.exit;
  const originalExitCode = process.exitCode;
  process.exitCode = undefined;
  const exitCalls = [];
  process.exit = (code) => exitCalls.push(code);
  try {
    await exitAfterSettled(async () => {
      throw new Error('boom');
    });
    assert.deepEqual(exitCalls, [1]);
  } finally {
    process.exit = originalExit;
    process.exitCode = originalExitCode;
  }
});

test('regression: an open handle (standing in for the never-closed CDP socket) hangs the process forever WITHOUT a forced exit, but exitAfterSettled exits promptly despite it', async () => {
  const dir = mkdtempSync(join(tmpdir(), 'picnic-worker-exit-test-'));
  try {
    // OLD shape (what worker.mjs used to do at its bottom): `work().catch(...)`
    // with nothing forcing a real exit. A live handle -- here a plain
    // setInterval, standing in for the CDP WebSocket connectOverCDP leaves
    // open -- keeps Node's event loop non-empty, so the process never exits
    // on its own. This is the counterfactual proof: without the fix, this
    // exact shape hangs.
    const oldPath = join(dir, 'old-shape.mjs');
    writeFileSync(
      oldPath,
      `
      const work = async () => {
        setInterval(() => {}, 1000000);
      };
      work().catch(() => {
        process.exitCode = 1;
      });
      `
    );

    // NEW shape: the real exitAfterSettled from worker.mjs, same open handle.
    const newPath = join(dir, 'new-shape.mjs');
    writeFileSync(
      newPath,
      `
      import { exitAfterSettled } from ${JSON.stringify(WORKER_MJS_PATH)};
      exitAfterSettled(async () => {
        setInterval(() => {}, 1000000);
      });
      `
    );

    const oldStillHanging = await stillRunningAfter(oldPath, 1500);
    assert.equal(oldStillHanging, true, 'old shape (no forced exit) must still be hanging on the open handle after 1.5s');

    const newResult = await waitForExit(newPath, 5000);
    assert.equal(newResult.timedOut, false, 'new shape (exitAfterSettled) must exit on its own despite the open handle');
    assert.equal(newResult.code, 0);
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});

// ============================================================================
// --walk=timeline (2026-09-22): walkTimeline / runTimelineWalk / timelineTileWorthOpening
//
// Date search (processDateGroup/runDateGroups above) was measured live to be
// badly incomplete -- see worker.mjs's walkTimeline header for the concrete
// numbers ("March 19, 2026" returning 1 tile vs. several real photos, "March
// 17, 2026" returning zero). These tests exercise the replacement: scrolling
// the main library timeline directly and matching candidates by a calibrated
// UTC offset + filename, rather than trusting search.
// ============================================================================

/** A timeline tile's aria-label in the shape parseTileAriaLabel expects (matcher.mjs). */
function timelineTileLabel(monthAbbrev, day, year, hour12, minute, second, ampm, kind = 'Photo') {
  return `${kind} - Portrait - ${monthAbbrev} ${day}, ${year}, ${hour12}:${String(minute).padStart(2, '0')}:${String(second).padStart(2, '0')} ${ampm}`;
}

test('timelineTileWorthOpening: pure boundary + gating behaviour', () => {
  const job = { filename: 'IMG_1.HEIC', creationDate: '2026-08-05T12:00:00.000Z', mediaType: null };
  const offsetSeconds = -21600; // -6h
  const predictedMs = new Date(job.creationDate).getTime() + offsetSeconds * 1000;

  // No calibration yet -> never worth opening, regardless of how close a tile reads.
  assert.equal(
    timelineTileWorthOpening([job], { wallClockAsUtcMs: predictedMs, mediaType: 'photo' }, null),
    false,
    'an uncalibrated offset must never authorise opening a tile'
  );

  // Exactly at TIMELINE_TIME_TOLERANCE_SECONDS -- inclusive boundary.
  assert.equal(
    timelineTileWorthOpening(
      [job],
      { wallClockAsUtcMs: predictedMs + TIMELINE_TIME_TOLERANCE_SECONDS * 1000, mediaType: 'photo' },
      offsetSeconds
    ),
    true,
    'exactly at the tolerance boundary must still be worth opening'
  );

  // One second past the boundary -- not worth opening.
  assert.equal(
    timelineTileWorthOpening(
      [job],
      { wallClockAsUtcMs: predictedMs + (TIMELINE_TIME_TOLERANCE_SECONDS + 1) * 1000, mediaType: 'photo' },
      offsetSeconds
    ),
    false,
    'one second past the tolerance boundary must not be worth opening'
  );

  // Media-type gating: a video job's predicted time must not flag a photo tile.
  const videoJob = { ...job, mediaType: 'video' };
  assert.equal(
    timelineTileWorthOpening([videoJob], { wallClockAsUtcMs: predictedMs, mediaType: 'photo' }, offsetSeconds),
    false,
    'a video job must not be worth opening for a Photo tile at the same predicted time'
  );
});

test('walkTimeline: finds a photo, calibrates a -6h offset from 2 clean pairs, and tolerates a 6-second-off reading (the exact live-measured discrepancy)', async () => {
  await withTempQueue(async (queue) => {
    const OFFSET_H = -6;
    const cal1 = queue.enqueue({ filename: 'IMG_9001.HEIC', creationDate: '2026-08-05T12:00:00.000Z', pixelWidth: 100, pixelHeight: 100 }).job;
    const cal2 = queue.enqueue({ filename: 'IMG_9002.HEIC', creationDate: '2026-08-05T15:00:00.000Z', pixelWidth: 100, pixelHeight: 100 }).job;
    const target = queue.enqueue({ filename: 'IMG_9003.HEIC', creationDate: '2026-08-05T18:00:00.000Z', pixelWidth: 100, pixelHeight: 100 }).job;
    // Predicted local time is 1:59:54 PM (14:00:00 - 6s) -- the same 6-second
    // discrepancy the brief measured live (aria-label reading vs. creationDate
    // after applying the calibrated offset), well inside TIMELINE_TIME_TOLERANCE_SECONDS.
    const tolerant = queue.enqueue({ filename: 'IMG_9004.HEIC', creationDate: '2026-08-05T20:00:00.000Z', pixelWidth: 100, pixelHeight: 100 }).job;

    const cal1Label = timelineTileLabel('Aug', 5, 2026, 6, 0, 0, 'AM'); // 12:00 UTC -6h = 06:00 local, exact
    const cal2Label = timelineTileLabel('Aug', 5, 2026, 9, 0, 0, 'AM'); // 15:00 UTC -6h = 09:00 local, exact
    const targetLabel = timelineTileLabel('Aug', 5, 2026, 12, 0, 0, 'PM'); // 18:00 UTC -6h = 12:00 local, exact
    const tolerantLabel = timelineTileLabel('Aug', 5, 2026, 1, 59, 54, 'PM'); // 20:00 UTC -6h = 14:00:00 local, tile reads 6s early

    const page = createFakePage({
      timelineTiles: [
        { ariaLabel: cal1Label },
        { ariaLabel: cal2Label },
        { ariaLabel: targetLabel },
        { ariaLabel: tolerantLabel },
      ],
      timelinePanelTextByLabel: {
        [cal1Label]: panelBlock('IMG_9001.HEIC', 100, 100),
        [cal2Label]: panelBlock('IMG_9002.HEIC', 100, 100),
        [targetLabel]: panelBlock('IMG_9003.HEIC', 100, 100),
        [tolerantLabel]: panelBlock('IMG_9004.HEIC', 100, 100),
      },
    });

    const { stillUnmatched } = await walkTimeline(page, [cal1, cal2, target, tolerant], queue, { dryRun: false });

    assert.equal(stillUnmatched.length, 0, `all 4 jobs should have matched, offset=${OFFSET_H}h`);
    for (const job of [cal1, cal2, target, tolerant]) {
      assert.equal(queue.getById(job.id).status, 'trashed', `${job.filename} should be trashed`);
    }
  });
});

test('walkTimeline: a candidate tile within the time tolerance but with a DIFFERENT filename is opened but never trashed', async () => {
  await withTempQueue(async (queue) => {
    // Two clean calibration pairs (required for the offset to calibrate at all).
    const cal1 = queue.enqueue({ filename: 'IMG_9001.HEIC', creationDate: '2026-08-05T12:00:00.000Z', pixelWidth: 100, pixelHeight: 100 }).job;
    const cal2 = queue.enqueue({ filename: 'IMG_9002.HEIC', creationDate: '2026-08-05T15:00:00.000Z', pixelWidth: 100, pixelHeight: 100 }).job;
    // decoyTarget's own real photo is nowhere in this fixture -- only a
    // DIFFERENT photo (decoyTile) happens to sit at its predicted time.
    const decoyTarget = queue.enqueue({ filename: 'IMG_9006.HEIC', creationDate: '2026-08-06T00:00:00.000Z', pixelWidth: 100, pixelHeight: 100 }).job;

    const cal1Label = timelineTileLabel('Aug', 5, 2026, 6, 0, 0, 'AM');
    const cal2Label = timelineTileLabel('Aug', 5, 2026, 9, 0, 0, 'AM');
    // 2026-08-06T00:00:00Z - 6h = Aug 5, 6:00 PM local -- decoyTarget's predicted slot.
    const decoyLabel = timelineTileLabel('Aug', 5, 2026, 6, 0, 0, 'PM');

    const page = createFakePage({
      timelineTiles: [{ ariaLabel: cal1Label }, { ariaLabel: cal2Label }, { ariaLabel: decoyLabel }],
      timelinePanelTextByLabel: {
        [cal1Label]: panelBlock('IMG_9001.HEIC', 100, 100),
        [cal2Label]: panelBlock('IMG_9002.HEIC', 100, 100),
        // Different filename entirely -- a real distinct photo that merely
        // happens to have been taken near decoyTarget's predicted time.
        [decoyLabel]: panelBlock('IMG_0000.HEIC', 100, 100),
      },
    });

    let stillUnmatched;
    const logs = await captureLogs(async () => {
      ({ stillUnmatched } = await walkTimeline(page, [cal1, cal2, decoyTarget], queue, { dryRun: false }));
    });

    assert.equal(stillUnmatched.length, 1, 'decoyTarget must remain unmatched');
    assert.equal(stillUnmatched[0].id, decoyTarget.id);
    assert.equal(queue.getById(decoyTarget.id).status, 'queued', 'never trashed, never rewritten by a coincidental time-neighbour');
    assert.ok(
      page.log.includes(`tile-click:${decoyLabel}`),
      'the decoy tile IS opened (it was worth a look, time-wise) -- proves this is a real non-match, not a candidate that was never tried'
    );
    // cal1/cal2 DO have real matches in this fixture (needed so the offset
    // can calibrate at all) and legitimately reach the trash keystroke --
    // the assertion that matters is that neither the decoy's real filename
    // nor decoyTarget's own (never-found) filename was ever reported trashed.
    assert.ok(!logs.some((l) => l.includes('[trashed] IMG_0000.HEIC')));
    assert.ok(!logs.some((l) => l.includes('[trashed] IMG_9006.HEIC')));
  });
});

test('walkTimeline: duplicate copies of the same job are both trashed', async () => {
  await withTempQueue(async (queue) => {
    const cal1 = queue.enqueue({ filename: 'IMG_9001.HEIC', creationDate: '2026-08-05T12:00:00.000Z', pixelWidth: 100, pixelHeight: 100 }).job;
    const cal2 = queue.enqueue({ filename: 'IMG_9002.HEIC', creationDate: '2026-08-05T15:00:00.000Z', pixelWidth: 100, pixelHeight: 100 }).job;
    const dup = queue.enqueue({ filename: 'IMG_9005.HEIC', creationDate: '2026-08-05T22:00:00.000Z', pixelWidth: 100, pixelHeight: 100 }).job;

    const cal1Label = timelineTileLabel('Aug', 5, 2026, 6, 0, 0, 'AM');
    const cal2Label = timelineTileLabel('Aug', 5, 2026, 9, 0, 0, 'AM');
    const dupLabelA = timelineTileLabel('Aug', 5, 2026, 4, 0, 0, 'PM'); // 22:00 UTC -6h = 16:00 local, exact
    const dupLabelB = dupLabelA; // same wall-clock reading -- a real re-upload duplicate; distinguished by href only

    const page = createFakePage({
      timelineTiles: [
        { ariaLabel: cal1Label },
        { ariaLabel: cal2Label },
        { ariaLabel: dupLabelA, href: './photo/copyA' },
        { ariaLabel: dupLabelB, href: './photo/copyB' },
      ],
      timelinePanelTextByLabel: {
        [cal1Label]: panelBlock('IMG_9001.HEIC', 100, 100),
        [cal2Label]: panelBlock('IMG_9002.HEIC', 100, 100),
        [dupLabelA]: panelBlock('IMG_9005.HEIC', 100, 100),
      },
    });

    const { stillUnmatched } = await walkTimeline(page, [cal1, cal2, dup], queue, { dryRun: false });

    assert.equal(stillUnmatched.length, 0);
    const record = queue.getById(dup.id);
    assert.equal(record.status, 'trashed');
    assert.equal(record.copiesTrashed, 2, 'both copies of the duplicate must be trashed');
  });
});

test('walkTimeline: stops scrolling once the visible timeline is more than 1 day older than the oldest pending job', async () => {
  await withTempQueue(async (queue) => {
    const job = queue.enqueue({ filename: 'IMG_NEVER_FOUND.HEIC', creationDate: '2026-08-05T12:00:00.000Z', pixelWidth: 100, pixelHeight: 100 }).job;

    // 40 batches, one NEW tile each, dated one calendar day further back per
    // batch (Aug 5, Aug 4, Aug 3, ... back to ~June 27) -- deliberately never
    // matches `job`'s filename, and no calibration pair exists at all (offset
    // stays null throughout), so this test isolates the STOP condition alone:
    // nothing is ever opened (timelineTileWorthOpening always refuses a null
    // offset -- see the pure-function test above), the only way the walk can
    // end is either exhausting MAX_TIMELINE_FRUITLESS_SCROLLS (40 distinct
    // batches means it never goes fruitless) or the 1-day stop check.
    const reveals = Array.from({ length: 40 }, (_, i) => {
      const day = 5 - i; // day 0 or negative is fine -- Date.UTC normalises month/day rollover
      const label = timelineTileLabel('Aug', day, 2026, 12, 0, 0, 'PM');
      return [{ ariaLabel: label, href: `./photo/day${i}` }];
    });

    const page = createFakePage({ timelineTiles: [], timelineReveals: reveals });

    const { stillUnmatched } = await walkTimeline(page, [job], queue, { dryRun: false });

    assert.equal(stillUnmatched.length, 1, 'job never matches anything in this fixture');
    assert.ok(
      page.timelineRevealedCount < reveals.length,
      `expected the walk to stop before revealing all ${reveals.length} batches, revealed ${page.timelineRevealedCount}`
    );
    // Precise: the stop condition fires once the oldest MOUNTED tile is
    // strictly older than (oldestPendingMs - 1 day) = Aug 4, 2026 12:00 UTC.
    // Batch 2 (Aug 3) is the first to cross that, so exactly 3 batches
    // (Aug 5, Aug 4, Aug 3) should have been revealed -- see this test's
    // sibling assertion below for the exact-count mutation-proof version.
    assert.equal(page.timelineRevealedCount, 3, 'exactly 3 batches (through the first one that crosses the 1-day cutoff) should be revealed');
  });
});

test('runTimelineWalk: a job never matched by the timeline walk becomes needs_review with the TIMELINE-specific reason', async () => {
  await withTempQueue(async (queue) => {
    const { job } = queue.enqueue({ filename: 'IMG_LOST.HEIC', creationDate: '2026-08-05T12:00:00.000Z', pixelWidth: 100, pixelHeight: 100 });
    // No tiles anywhere -- MAX_TIMELINE_FRUITLESS_SCROLLS consecutive
    // no-new-tile scrolls end the walk quickly.
    const page = createFakePage({ timelineTiles: [] });

    await runTimelineWalk(page, [queue.getById(job.id)], queue, { dryRun: false });

    const after = queue.getById(job.id);
    assert.equal(after.status, 'needs_review');
    assert.equal(
      after.comparison?.reason,
      "timeline walked past this job's capture time with no filename match",
      'the reason must be distinct from date search\'s own "no filename match for <date> (+/-1 day)"'
    );
    const wheelCount = page.log.filter((l) => l === 'wheel:down').length;
    assert.ok(wheelCount <= MAX_TIMELINE_FRUITLESS_SCROLLS + 1, `must not scroll forever against an empty timeline, got ${wheelCount} scrolls`);
  });
});

test('walkTimeline: calibrates a DIFFERENT offset (-4h) correctly -- not hardcoded to -6h', async () => {
  await withTempQueue(async (queue) => {
    const cal1 = queue.enqueue({ filename: 'IMG_8001.HEIC', creationDate: '2026-03-18T04:59:00.000Z', pixelWidth: 100, pixelHeight: 100 }).job;
    const cal2 = queue.enqueue({ filename: 'IMG_8002.HEIC', creationDate: '2026-03-18T08:00:00.000Z', pixelWidth: 100, pixelHeight: 100 }).job;
    const target = queue.enqueue({ filename: 'IMG_8003.HEIC', creationDate: '2026-03-18T10:00:00.000Z', pixelWidth: 100, pixelHeight: 100 }).job;

    // -4h: 04:59 UTC -> 12:59 AM local; 08:00 UTC -> 4:00 AM local; 10:00 UTC -> 6:00 AM local.
    const cal1Label = timelineTileLabel('Mar', 18, 2026, 12, 59, 0, 'AM');
    const cal2Label = timelineTileLabel('Mar', 18, 2026, 4, 0, 0, 'AM');
    const targetLabel = timelineTileLabel('Mar', 18, 2026, 6, 0, 0, 'AM');

    const page = createFakePage({
      timelineTiles: [{ ariaLabel: cal1Label }, { ariaLabel: cal2Label }, { ariaLabel: targetLabel }],
      timelinePanelTextByLabel: {
        [cal1Label]: panelBlock('IMG_8001.HEIC', 100, 100),
        [cal2Label]: panelBlock('IMG_8002.HEIC', 100, 100),
        [targetLabel]: panelBlock('IMG_8003.HEIC', 100, 100),
      },
    });

    const { stillUnmatched } = await walkTimeline(page, [cal1, cal2, target], queue, { dryRun: false });

    assert.equal(stillUnmatched.length, 0);
    assert.equal(queue.getById(target.id).status, 'trashed');
  });
});
