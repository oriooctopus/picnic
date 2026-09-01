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
const { processDateGroup, runDateGroups, assertNoFriction, isPageClosedError, MAX_STEPS_PER_DATE } = await import(
  '../worker.mjs'
);

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
