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
const {
  processDateGroup,
  runDateGroups,
  assertNoFriction,
  isPageClosedError,
  MAX_STEPS_PER_DATE,
  MAX_TILE_OPEN_RETRIES,
  parseArgs,
  stealthDelayRange,
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

test('every visible tile is walked: a job whose photo is at the LAST tile is still matched', async () => {
  await withTempQueue(async (queue) => {
    // The regression this guards against: the old walk opened only tiles[0]
    // and relied on an accelerator that didn't reliably reach the rest of
    // the day. 6 tiles here; only the 6th (last) one matches.
    const { job } = queue.enqueue(IMG_1433_JOB);
    const labels = Array.from({ length: 6 }, (_, i) => `Photo - Portrait - Aug 5, 2026, ${i}:00:00 AM`);
    const panelTextByLabel = { 'August 5, 2026': {} };
    for (let i = 0; i < 5; i++) {
      panelTextByLabel['August 5, 2026'][labels[i]] = panelBlock(`IMG_900${i}.HEIC`, 1000, 1000);
    }
    panelTextByLabel['August 5, 2026'][labels[5]] = IMG_1433_BLOCK; // the match, last tile

    const page = createFakePage({
      searchResults: { 'August 5, 2026': labels.map((ariaLabel) => ({ ariaLabel })) },
      panelTextByLabel,
    });

    const { stillUnmatched } = await processDateGroup(page, '2026-08-05', [job], queue, { dryRun: false });

    assert.equal(stillUnmatched.length, 0, 'job at the last tile must still be matched');
    assert.equal(queue.getById(job.id).status, 'trashed');
    for (const label of labels) {
      assert.ok(page.log.includes(`tile-click:${label}`), `expected tile "${label}" to have been opened`);
    }
  });
});

test('the walk stops as soon as every job is matched, without opening remaining tiles', async () => {
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
    assert.ok(page.log.includes(`tile-click:${labels[0]}`));
    assert.ok(page.log.includes(`tile-click:${labels[1]}`));
    assert.ok(!page.log.includes(`tile-click:${labels[2]}`), 'must stop once the job is matched');
    assert.ok(!page.log.includes(`tile-click:${labels[3]}`), 'must stop once the job is matched');
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

test('scrolling reveals more tiles, and the newly-revealed tiles are visited', async () => {
  await withTempQueue(async (queue) => {
    const { job } = queue.enqueue(IMG_1433_JOB);
    const page = createFakePage({
      searchResults: {
        'August 5, 2026': [{ ariaLabel: 'Photo - Portrait - tile-1' }, { ariaLabel: 'Photo - Portrait - tile-2' }],
      },
      scrollReveals: {
        'August 5, 2026': [[{ ariaLabel: 'Photo - Portrait - tile-3 (match, revealed by scroll)' }]],
      },
      panelTextByLabel: {
        'August 5, 2026': {
          'Photo - Portrait - tile-1': panelBlock('IMG_0001.HEIC', 1000, 1000),
          'Photo - Portrait - tile-2': panelBlock('IMG_0002.HEIC', 1000, 1000),
          'Photo - Portrait - tile-3 (match, revealed by scroll)': IMG_1433_BLOCK,
        },
      },
    });

    const { stillUnmatched } = await processDateGroup(page, '2026-08-05', [job], queue, { dryRun: false });

    assert.equal(stillUnmatched.length, 0, 'the scroll-revealed tile must be visited and matched');
    assert.equal(queue.getById(job.id).status, 'trashed');
    assert.ok(page.log.includes('wheel'), 'must have scrolled to look for more tiles');
    assert.ok(page.log.includes('tile-click:Photo - Portrait - tile-3 (match, revealed by scroll)'));
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

    assert.deepEqual(page.searchLog, ['August 5, 2026', 'August 4, 2026', 'August 6, 2026']);
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

test('hitting MAX_STEPS_PER_DATE is logged as ABANDONED, distinct from a genuinely EXHAUSTED date', async () => {
  await withTempQueue(async (queue) => {
    // Case 1: a huge day (more tiles than the cap), nothing ever matches ->
    // the walk must stop at the cap and say so distinctly.
    const { job: bigJob } = queue.enqueue({ ...IMG_1433_JOB, filename: 'IMG_NOMATCH.HEIC' });
    const bigLabels = Array.from({ length: MAX_STEPS_PER_DATE + 10 }, (_, i) => `Photo - Portrait - tile-${i}`);
    const bigPanels = {};
    for (const label of bigLabels) bigPanels[label] = panelBlock(`${label}.HEIC`, 1000, 1000);
    const bigPage = createFakePage({
      searchResults: { 'August 5, 2026': bigLabels.map((ariaLabel) => ({ ariaLabel })) },
      panelTextByLabel: { 'August 5, 2026': bigPanels },
    });

    const boundLogs = await captureLogs(() => processDateGroup(bigPage, '2026-08-05', [bigJob], queue, { dryRun: true }));
    const boundClicks = bigPage.log.filter((l) => l.startsWith('tile-click:'));
    assert.equal(boundClicks.length, MAX_STEPS_PER_DATE, `expected exactly ${MAX_STEPS_PER_DATE} tiles opened before the bound stopped the walk`);
    assert.ok(
      boundLogs.some((l) => l.includes('ABANDONED') && l.includes('MAX_STEPS_PER_DATE')),
      `expected an ABANDONED/MAX_STEPS_PER_DATE log line, got: ${JSON.stringify(boundLogs)}`
    );

    // Case 2: a small day (fewer tiles than the cap), nothing matches -> the
    // walk exhausts every tile and must say EXHAUSTED, never ABANDONED.
    const { job: smallJob } = queue.enqueue({ ...IMG_1433_JOB, filename: 'IMG_ALSO_NOMATCH.HEIC' });
    const smallLabels = ['Photo - Portrait - tile-a', 'Photo - Portrait - tile-b', 'Photo - Portrait - tile-c'];
    const smallPanels = {};
    for (const label of smallLabels) smallPanels[label] = panelBlock(`${label}.HEIC`, 1000, 1000);
    const smallPage = createFakePage({
      searchResults: { 'August 6, 2026': smallLabels.map((ariaLabel) => ({ ariaLabel })) },
      panelTextByLabel: { 'August 6, 2026': smallPanels },
    });

    const exhaustedLogs = await captureLogs(() =>
      processDateGroup(smallPage, '2026-08-06', [smallJob], queue, { dryRun: true })
    );
    const exhaustedClicks = smallPage.log.filter((l) => l.startsWith('tile-click:'));
    assert.equal(exhaustedClicks.length, smallLabels.length, 'every tile on the small day must have been opened');
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

test('aria fast path: two tiles sharing the same predicted second fall back to the exhaustive walk, never a guess', async () => {
  await withTempQueue(async (queue) => {
    const { job: job1 } = queue.enqueue(IMG_1433_JOB); // Aug 5, 12:54:07Z -> local 6:54:07 PM at +6h
    const { job: job2 } = queue.enqueue(IMG_1441_JOB); // Aug 5, 13:31:07Z -> local 7:31:07 PM at +6h
    const label1 = 'Photo - Portrait - Aug 5, 2026, 6:54:07 PM';
    const label2 = 'Photo - Portrait - Aug 5, 2026, 7:31:07 PM';
    // A second tile at job2's exact predicted second+mediaType -- a genuine
    // burst-shot collision. planAriaMatches must refuse the WHOLE date
    // rather than guess between label2 and this one. Placed BEFORE label2
    // in tile order so the exhaustive walk's in-order scan necessarily opens
    // it before reaching job2's real match -- if the code had instead
    // trusted a 2-tile aria plan (label1, label2), this tile would never be
    // opened at all, so its presence in the open log is the fallback's
    // fingerprint.
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
    // The fallback signature: the walk opened the COLLIDING tile too (it sits
    // between label1 and label2 in the grid), proving it walked every tile in
    // order rather than trusting a 2-tile aria plan that would have skipped it.
    const tileClicks = page.log.filter((l) => l.startsWith('tile-click:'));
    for (const label of labels) {
      assert.ok(tileClicks.includes(`tile-click:${label}`), `expected exhaustive walk to open "${label}"`);
    }
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
      /info panel never produced dimensions text/,
      'must throw rather than hang when the panel genuinely never opens'
    );
  });
});

test('--slow: parseArgs recognizes the flag, and stealthDelayRange restores the long delays only when slow=true', () => {
  assert.equal(parseArgs([]).slow, false, 'off by default');
  assert.equal(parseArgs(['--dry-run', '--slow', '--cap', '10']).slow, true);

  assert.deepEqual(stealthDelayRange(500, 2000, false), [0, 0], 'default (fast): no jitter');
  assert.deepEqual(stealthDelayRange(500, 2000, true), [500, 2000], '--slow: original human-scale range restored');
});


// REGRESSION (live, 2026-09-01): the aria fast path's "scroll the date to
// completion first" phase and the exhaustive walk shared one scrollAttempts
// budget. The pre-scroll spent all MAX_SCROLL_ATTEMPTS_PER_DATE attempts, so
// the walk's first "no unvisited tile rendered" check broke out immediately
// and the date was reported EXHAUSTED with 25 of 27 tiles never opened --
// photos silently left undeleted. The two phases need independent budgets.
test('the exhaustive walk can still scroll after the aria pre-scroll spent its own budget', async () => {
  await withTempQueue(async (queue) => {
    const { job } = queue.enqueue(IMG_1433_JOB);

    // Enough batches that the pre-scroll consumes its whole budget, with the
    // matching tile only reachable by a FURTHER scroll during the walk.
    const batches = [];
    const panelText = { 'Photo - Portrait - base': panelBlock('IMG_0000.HEIC', 1000, 1000) };
    for (let i = 1; i <= 6; i++) {
      const label = `Photo - Portrait - batch-${i}`;
      batches.push([{ ariaLabel: label }]);
      panelText[label] = panelBlock(`IMG_000${i}.HEIC`, 1000, 1000);
    }
    const matchLabel = 'Photo - Portrait - batch-7 (match, past the pre-scroll budget)';
    batches.push([{ ariaLabel: matchLabel }]);
    panelText[matchLabel] = IMG_1433_BLOCK;

    const page = createFakePage({
      searchResults: { 'August 5, 2026': [{ ariaLabel: 'Photo - Portrait - base' }] },
      scrollReveals: { 'August 5, 2026': batches },
      panelTextByLabel: { 'August 5, 2026': panelText },
    });

    const { stillUnmatched } = await processDateGroup(page, '2026-08-05', [job], queue, { dryRun: false });

    assert.equal(
      stillUnmatched.length,
      0,
      'the walk must keep scrolling past the pre-scroll budget and reach the matching tile'
    );
    assert.equal(queue.getById(job.id).status, 'trashed');
    assert.ok(page.log.includes(`tile-click:${matchLabel}`), 'the late-revealed matching tile must actually be opened');
  });
});

// REGRESSION (diagnosed 2026-09-01, from live evidence): the exhaustive walk
// judged "did this scroll find anything new?" by comparing on-screen tile
// COUNTS before/after. That's wrong for a VIRTUALIZED grid -- Google's result
// grid only ever renders the tiles currently in the viewport, so scrolling
// mounts new tiles AND unmounts old ones, and the on-screen count can stay
// flat (or even shrink) while the actual content moved on entirely. A live
// run walked only 3 of 27 tiles before wrongly reporting EXHAUSTED.
//
// `windowSize` (see fakePage.mjs's windowedTiles()) models exactly that: only
// the most-recently-revealed N tiles are ever "mounted" at once, unlike the
// existing (additive-only) scrollReveals fixtures every other test above
// uses, which can't express this bug at all -- their tile count only ever
// grows.
test('virtualized grid: the visible window moves as you scroll (tiles leave as others enter) -- a job in a late window must still be matched', async () => {
  await withTempQueue(async (queue) => {
    const { job } = queue.enqueue(IMG_1433_JOB);
    // 8 tiles, revealed one scroll at a time, with only 3 ever mounted at
    // once -- the on-screen tile count never exceeds 3 no matter how deep
    // the walk goes, exactly the shape that broke the old count comparison.
    const laterLabels = Array.from({ length: 8 }, (_, i) => `Photo - Portrait - window-${i + 1}`);
    const panelText = {};
    for (let i = 0; i < laterLabels.length - 1; i++) {
      panelText[laterLabels[i]] = panelBlock(`IMG_920${i}.HEIC`, 1000, 1000);
    }
    const matchLabel = laterLabels[laterLabels.length - 1]; // deep: only mounted after 7 scrolls
    panelText[matchLabel] = IMG_1433_BLOCK;

    const page = createFakePage({
      searchResults: { 'August 5, 2026': [{ ariaLabel: 'Photo - Portrait - window-base' }] },
      scrollReveals: { 'August 5, 2026': laterLabels.map((ariaLabel) => [{ ariaLabel }]) },
      panelTextByLabel: { 'August 5, 2026': panelText },
      windowSize: 3,
    });

    const { stillUnmatched } = await processDateGroup(page, '2026-08-05', [job], queue, { dryRun: false });

    assert.equal(stillUnmatched.length, 0, 'the deep, late-window match must still be found');
    assert.equal(queue.getById(job.id).status, 'trashed');
    for (const label of laterLabels) {
      assert.ok(page.log.includes(`tile-click:${label}`), `expected tile "${label}" to have been opened despite the moving window`);
    }
  });
});

// Minimal, sharpest form of the same bug: with only ONE tile ever mounted,
// the on-screen tile COUNT is 1 before AND after every scroll for the whole
// walk -- so a comparison of counts can never see progress, even though the
// tile actually mounted is a completely different one each time. Only a
// comparison of the underlying LABEL SET (this fix's `seen`/mergeSeen) can
// tell "swapped for something new" apart from "genuinely found nothing".
test('a scroll that swaps the one visible tile for a different one (same on-screen count) must not be treated as "nothing new"', async () => {
  await withTempQueue(async (queue) => {
    const { job } = queue.enqueue(IMG_1433_JOB);
    // 3 scroll-revealed batches, not 1: the aria fast path's own pre-scroll
    // loop (unchanged, out of scope for this fix) always spends its first
    // scroll before the exhaustive walk below even starts -- with only ONE
    // reveal batch, that pre-scroll alone would already land on the match
    // and the exhaustive walk would never need to scroll at all, proving
    // nothing about ITS count-vs-label-set logic. Three batches guarantees
    // the walk still has real scrolling of its own left to do afterward.
    const page = createFakePage({
      searchResults: { 'August 5, 2026': [{ ariaLabel: 'Photo - Portrait - swap-a' }] },
      scrollReveals: {
        'August 5, 2026': [
          [{ ariaLabel: 'Photo - Portrait - swap-b' }],
          [{ ariaLabel: 'Photo - Portrait - swap-c' }],
          [{ ariaLabel: 'Photo - Portrait - swap-d (match)' }],
        ],
      },
      panelTextByLabel: {
        'August 5, 2026': {
          'Photo - Portrait - swap-a': panelBlock('IMG_9500.HEIC', 1000, 1000),
          'Photo - Portrait - swap-b': panelBlock('IMG_9501.HEIC', 1000, 1000),
          'Photo - Portrait - swap-c': panelBlock('IMG_9502.HEIC', 1000, 1000),
          'Photo - Portrait - swap-d (match)': IMG_1433_BLOCK,
        },
      },
      windowSize: 1, // exactly one tile mounted, ever -- the on-screen count is 1 before, during, and after every scroll
    });

    const { stillUnmatched } = await processDateGroup(page, '2026-08-05', [job], queue, { dryRun: false });

    assert.equal(
      stillUnmatched.length,
      0,
      'the swapped-in tile several scrolls deep must be visited even though the on-screen tile count never changed'
    );
    assert.equal(queue.getById(job.id).status, 'trashed');
    assert.ok(page.log.includes('tile-click:Photo - Portrait - swap-d (match)'));
  });
});

// A tile the walk KNOWS about (collectResultTiles() saw it on-screen) but
// which the grid genuinely never lets open -- distinct from one merely
// scrolled out of the window (that case is the two tests above). The old
// code marked a tile "visited" the instant it was CHOSEN to be opened, before
// the open even attempted, so a tile that failed to open was silently
// counted as walked and never retried. This must retry a bounded number of
// times, then give up on that ONE tile (logged distinctly as UNREACHABLE)
// without derailing the rest of the date, and without letting the date's
// final summary claim the unreachable tile was "walked".
test('unreachable tile: known but never openable is retried a bounded number of times, then recorded unreachable -- never silently counted as walked', async () => {
  await withTempQueue(async (queue) => {
    const { job } = queue.enqueue(IMG_1433_JOB); // nothing on this date will actually confirm it
    const ghostLabel = 'Photo - Portrait - ghost (never mounts)';
    const openLabel = 'Photo - Portrait - openable (no match)';
    const page = createFakePage({
      searchResults: {
        'August 5, 2026': [{ ariaLabel: ghostLabel }, { ariaLabel: openLabel }],
      },
      panelTextByLabel: {
        'August 5, 2026': { [openLabel]: panelBlock('IMG_0001.HEIC', 1000, 1000) },
      },
      unopenableLabels: [ghostLabel],
    });

    let result;
    const logs = await captureLogs(async () => {
      result = await processDateGroup(page, '2026-08-05', [job], queue, { dryRun: false });
    });

    assert.equal(result.stillUnmatched.length, 1, 'no tile on this date confirms the job -- it must remain unmatched');
    assert.ok(
      page.log.includes(`tile-click:${openLabel}`),
      'the walk must still reach and open the OTHER tile, not get stuck retrying the ghost forever'
    );
    assert.ok(
      !page.log.includes(`tile-click:${ghostLabel}`),
      'the ghost tile must never actually be recorded as opened -- it never became actionable'
    );
    assert.ok(
      logs.some((l) => l.includes('UNREACHABLE') && l.includes(ghostLabel) && l.includes(`after ${MAX_TILE_OPEN_RETRIES} attempt`)),
      `expected a distinct UNREACHABLE log line bounded at ${MAX_TILE_OPEN_RETRIES} attempts, got: ${JSON.stringify(logs)}`
    );
    // The date-level summary must not claim the ghost was "walked" -- it was
    // explicitly given up on, and EXHAUSTED must say so rather than imply
    // every seen tile was successfully opened.
    assert.ok(
      logs.some((l) => l.includes('EXHAUSTED') && l.includes('unreachable') && !l.includes(`2 tile(s) opened`)),
      `expected EXHAUSTED to distinguish opened-vs-unreachable rather than reporting a clean sweep, got: ${JSON.stringify(logs)}`
    );
  });
});

// -- CHANGE 2 (2026-09-01): aria pre-scroll cumulative-set fix, upward
// recovery, and the ambiguity-safety risk that motivated both -----------
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

// REGRESSION (2026-09-01): reachable ONLY via upward recovery -- the tile
// that resolves the job is revealed FIRST, then scrolled out of the mounted
// window by later filler before the exhaustive walk ever starts (the aria
// fast path never fires here: none of these labels are date-format, so
// planAriaMatches bails out immediately and the whole date runs through the
// walk). Down-only scrolling can never bring it back -- there's nothing
// further to reveal once all 4 filler batches are loaded -- so this is
// exactly the scenario that made the "virtualized grid" test above fail
// under my first (recovery-less) attempt at the pre-scroll fix.
test('upward recovery: a tile scrolled out of the window by the pre-scroll is still reached and matched', async () => {
  await withTempQueue(async (queue) => {
    const { job } = queue.enqueue(IMG_1433_JOB);
    const matchLabel = 'Photo - Portrait - recovery-match (revealed first, buried by later filler)';
    const padLabels = ['Photo - Portrait - recovery-pad-a', 'Photo - Portrait - recovery-pad-b', 'Photo - Portrait - recovery-pad-c', 'Photo - Portrait - recovery-pad-d'];
    const panelText = { [matchLabel]: IMG_1433_BLOCK };
    for (const [i, label] of padLabels.entries()) panelText[label] = panelBlock(`IMG_930${i}.HEIC`, 1000, 1000);

    const page = createFakePage({
      searchResults: { 'August 5, 2026': [{ ariaLabel: matchLabel }] }, // on-screen before any scroll
      scrollReveals: { 'August 5, 2026': padLabels.map((ariaLabel) => [{ ariaLabel }]) }, // 4 batches of filler, pushing matchLabel out
      panelTextByLabel: { 'August 5, 2026': panelText },
      windowSize: 3, // matchLabel falls out of the window after the 3rd filler batch loads, well before the pre-scroll (budget 6) stops
    });

    const { stillUnmatched } = await processDateGroup(page, '2026-08-05', [job], queue, { dryRun: false });

    assert.equal(stillUnmatched.length, 0, 'the buried tile must still be reached and matched');
    assert.equal(queue.getById(job.id).status, 'trashed');
    assert.ok(page.log.includes(`tile-click:${matchLabel}`), 'the buried tile must actually have been opened');
    // The mechanism, not just the outcome: an upward ('wheel:up') scroll must
    // have happened -- down-only scrolling cannot express this recovery at
    // all (there's nothing further to reveal once all 4 filler batches have
    // loaded), so without it the walk would exhaust its scroll budget and
    // report the date ABANDONED with the job still unmatched.
    assert.ok(page.log.includes('wheel:up'), 'expected an upward recovery scroll, got: ' + JSON.stringify(page.log.filter((l) => l.startsWith('wheel'))));
  });
});

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
    // The fallback's fingerprint: decoyA (which no aria plan would ever open
    // -- it doesn't match either job's predicted second) gets opened, proving
    // the WHOLE date fell through to the exhaustive walk rather than the
    // fast path trusting a falsely-unique match for job1. With the count-
    // based pre-scroll bug, dupLabel is invisible to planAriaMatches, job1's
    // slot looks uniquely resolved, and the fast path opens ONLY label1 and
    // label2 -- decoyA (and dupLabel) never opened at all.
    const tileClicks = page.log.filter((l) => l.startsWith('tile-click:'));
    assert.ok(
      tileClicks.includes(`tile-click:${decoyA}`),
      `expected the exhaustive walk to fire (proving the fast path declined the ambiguous match), got: ${JSON.stringify(tileClicks)}`
    );
    assert.ok(tileClicks.includes(`tile-click:${label1}`));
    assert.ok(tileClicks.includes(`tile-click:${label2}`));
  });
});
