import { test } from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, rmSync, existsSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { createFakePage } from './helpers/fakePage.mjs';
import { ReconcileStore, sectionForCameraModel } from '../lib/reconcile.mjs';

// Must be set BEFORE worker.mjs is evaluated (it reads the env var once, at
// module load, into a top-level FAST_DELAYS const) — same reason
// worker.test.mjs dynamic-imports it. Collapses the real 1-9s pacing to ~0ms
// so the suite runs in milliseconds; a real run is unchanged.
process.env.PICNIC_WORKER_FAST_DELAYS = '1';
const { runReconcileScan, runReconcileTrash } = await import('../worker.mjs');

async function withTempStore(fn) {
  const dir = mkdtempSync(join(tmpdir(), 'picnic-reconcile-worker-test-'));
  const store = new ReconcileStore(dir);
  try {
    // MUST await: a plain `return fn(store)` makes the finally (rmSync) run
    // synchronously the instant fn's async body first suspends, deleting the
    // dir out from under the still-running test — a mid-run store re-read then
    // finds nothing. Awaiting keeps the dir alive until the body settles.
    await fn(store);
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
}

/** Raw (run-together, no-separator) Google Photos info-panel text for one photo. */
function panelBlock(filename, cameraModel = 'Apple iPhone 13 Pro') {
  return (
    `InfoAdd a descriptionPeopleDetailsAug 5Wed, 6:54 PMGMT-06:00${cameraModel}` +
    `ƒ/2.21/632.71mmISO40${filename}7.2MP2316 × 3088Uploaded from iOS deviceBacked up (6 MB)Original quality. Learn moreWestminster, CO`
  );
}

function manifestAsset(filename, creationDate) {
  return { filename, creationDate, pixelWidth: 2316, pixelHeight: 3088 };
}

test('runReconcileScan: timestamp fast-path and filename match are skipped; only the off-phone iPhone photo becomes a candidate with a thumbnail', async () => {
  await withTempStore(async (store) => {
    const month = '2026-08';
    // Three manifest entries: two map to tiles A1/A2 by capture time (so the
    // self-calibrating fast path plans those tiles and they are never opened),
    // the third matches tile B by filename alone (opened, decided on-phone).
    store.saveManifest(month, [
      manifestAsset('IMG_1433.HEIC', '2026-08-05T12:54:07.000Z'), // -> A1 at 6:54:07 PM (-6h)
      manifestAsset('IMG_1441.HEIC', '2026-08-05T13:31:07.000Z'), // -> A2 at 7:31:07 PM (-6h)
      manifestAsset('IMG_3333.HEIC', '2026-08-05T14:00:00.000Z'), // -> tile B, filename only
    ]);

    const labelA1 = 'Photo - Portrait - Aug 5, 2026, 6:54:07 PM';
    const labelA2 = 'Photo - Portrait - Aug 5, 2026, 7:31:07 PM';
    const labelB = 'Photo - Portrait - Aug 5, 2026, 3:00:00 PM';
    const labelC = 'Photo - Portrait - Aug 5, 2026, 4:00:00 PM';

    const page = createFakePage({
      searchResults: { 'August 5, 2026': [labelA1, labelA2, labelB, labelC] },
      panelTextByLabel: {
        'August 5, 2026': {
          [labelB]: panelBlock('IMG_3333.HEIC', null),
          [labelC]: panelBlock('IMG_7777.HEIC'),
        },
      },
      photoIdByLabel: { [labelB]: 'photoB', [labelC]: 'photoC' },
    });

    await runReconcileScan(page, month, store);

    const candidates = store.listCandidates(month);
    assert.equal(candidates.length, 1, 'exactly the off-phone photo is a candidate');
    const c = candidates[0];
    assert.equal(c.photoId, 'photoC');
    assert.equal(c.filename, 'IMG_7777.HEIC');
    assert.equal(c.cameraModel, 'Apple iPhone 13 Pro');
    assert.equal(sectionForCameraModel(c.cameraModel), 'iphone');
    assert.equal(c.status, 'candidate');

    // A thumbnail was actually written to disk for the candidate.
    const thumb = store.thumbPath(month, 'photoC');
    assert.ok(existsSync(thumb), 'candidate thumbnail exists on disk');

    // The fast path opened exactly the two non-planned tiles (B and C), never
    // the two timestamp-matched ones (A1/A2).
    assert.equal(page.log.filter((l) => l.startsWith('tile-click:')).length, 2, 'only B and C were opened');

    // A screenshot (thumbnail) was taken exactly once — for the one candidate.
    assert.equal(page.log.filter((l) => l === 'screenshot').length, 1);

    assert.equal(store.loadStatus(month), 'ready');
  });
});

test('runReconcileScan: one unreadable tile is skipped; scan completes and still saves the other readable candidates', async () => {
  await withTempStore(async (store) => {
    const month = '2026-08';
    store.saveManifest(month, [manifestAsset('IMG_3333.HEIC', '2026-08-05T14:00:00.000Z')]);

    const labelDead = 'Photo - Portrait - Aug 5, 2026, 1:00:00 PM'; // no panel text -> openInfoPanelOnce throws
    const labelOk = 'Photo - Portrait - Aug 5, 2026, 4:00:00 PM';
    const page = createFakePage({
      // Dead tile FIRST: proves the tile AFTER it is still reached, i.e. the
      // skip closed the open viewer instead of leaving it blocking the grid.
      searchResults: { 'August 5, 2026': [labelDead, labelOk] },
      panelTextByLabel: { 'August 5, 2026': { [labelOk]: panelBlock('IMG_7777.HEIC') } },
      photoIdByLabel: { [labelDead]: 'photoDead', [labelOk]: 'photoOk' },
    });

    await runReconcileScan(page, month, store); // must not throw

    const list = store.listCandidates(month);
    assert.deepEqual(list.map((c) => c.photoId), ['photoOk']);
    assert.ok(existsSync(store.thumbPath(month, 'photoOk')));
    assert.ok(!existsSync(store.thumbPath(month, 'photoDead')), 'no thumbnail for the unreadable tile');
    assert.equal(store.loadStatus(month), 'ready');
  });
});

test('runReconcileScan: no manifest -> logs and writes no status', async () => {
  await withTempStore(async (store) => {
    const page = createFakePage({});
    await runReconcileScan(page, '2026-08', store);
    assert.equal(store.loadStatus('2026-08'), null);
    assert.deepEqual(store.listCandidates('2026-08'), []);
  });
});

test('runReconcileScan: two tiles resolving to the same photoId produce ONE candidate', async () => {
  await withTempStore(async (store) => {
    const month = '2026-08';
    // Timestamp far from either tile's capture time so the fast path never
    // plans them away -- both must actually be opened for this test to mean
    // anything.
    store.saveManifest(month, [manifestAsset('IMG_9999.HEIC', '2026-08-05T20:00:00.000Z')]);

    const label1 = 'Photo - Portrait - Aug 5, 2026, 3:00:00 PM';
    const label2 = 'Photo - Portrait - Aug 5, 2026, 3:00:01 PM';
    const page = createFakePage({
      searchResults: { 'August 5, 2026': [label1, label2] },
      // Both tiles have REAL, DIFFERENT panel text on purpose: if the
      // seenPhotoIds dedupe were missing, label2 would still be fully read
      // (not merely rejected as "unreadable"), and the store's fold-latest-
      // record-per-id behaviour would let its filename silently overwrite
      // label1's -- a same-count-but-wrong-content bug a same-photoId-with-
      // no-second-panel-text fixture couldn't distinguish from the fix.
      panelTextByLabel: {
        'August 5, 2026': {
          [label1]: panelBlock('IMG_7777.HEIC'),
          [label2]: panelBlock('IMG_6666.HEIC'),
        },
      },
      // Google's two grid sizes render the SAME underlying photo under two
      // different tile labels/hrefs -- pinning both to one photoId is exactly
      // the live bug (every candidate recorded twice) this test proves fixed.
      photoIdByLabel: { [label1]: 'dupPhoto', [label2]: 'dupPhoto' },
    });

    await runReconcileScan(page, month, store);

    const candidates = store.listCandidates(month);
    assert.deepEqual(candidates.map((c) => c.photoId), ['dupPhoto'], 'the second tile (same photoId) produced no extra candidate');
    assert.equal(candidates[0].filename, 'IMG_7777.HEIC', 'label2 (same photoId, seen second) was never opened/read at all -- its filename never overwrote label1\'s');
    assert.equal(page.log.filter((l) => l === 'screenshot').length, 1, 'only ONE screenshot was taken -- label2 never reached the thumbnail step');
    assert.equal(
      page.log.filter((l) => l.startsWith('tile-click:')).length,
      2,
      'both tiles were still opened -- dedupe happens after open, on photoId, not before'
    );
  });
});

test("runReconcileScan: a tile whose viewer opens late is still read, not skipped, and the next day's search still runs", async () => {
  await withTempStore(async (store) => {
    const month = '2026-08';
    store.saveManifest(month, [manifestAsset('IMG_9999.HEIC', '2026-08-05T20:00:00.000Z')]);

    const lateLabel = 'Photo - Portrait - Aug 5, 2026, 3:00:00 PM';
    const nextDayLabel = 'Photo - Portrait - Aug 6, 2026, 3:00:00 PM';
    const page = createFakePage({
      searchResults: {
        'August 5, 2026': [lateLabel],
        'August 6, 2026': [nextDayLabel],
      },
      panelTextByLabel: {
        'August 5, 2026': { [lateLabel]: panelBlock('IMG_7777.HEIC') },
        'August 6, 2026': { [nextDayLabel]: panelBlock('IMG_8888.HEIC') },
      },
      photoIdByLabel: { [lateLabel]: 'latePhoto', [nextDayLabel]: 'nextDayPhoto' },
      // Models Google opening the viewer a beat after the click: page.url()
      // keeps reporting the pre-click (grid) URL until runReconcileScan's own
      // page.waitForURL() call resolves it (see fakePage.mjs openTileInFake's
      // lateOpeningLabels comment for the live bug this reproduces -- without
      // the waitForURL fix, photoIdFromUrl(page.url()) reads null here and the
      // tile is silently skipped).
      lateOpeningLabels: new Set([lateLabel]),
    });

    await runReconcileScan(page, month, store);

    const candidates = store.listCandidates(month);
    assert.deepEqual(
      candidates.map((c) => c.photoId).sort(),
      ['latePhoto', 'nextDayPhoto'],
      'the late-opening tile was not skipped, and the following day was still scanned'
    );
  });
});

/** Three-photo-agnostic helper: queued candidate row. */
function cand(photoId, filename, status) {
  return { photoId, filename, cameraModel: 'Apple iPhone 13 Pro', captureDateMs: 1, pixelWidth: 2316, pixelHeight: 3088, status };
}

/** Spy standing in for moveToTrash: records calls, returns the scripted result. */
function spyTrash(result = { confirmed: true }) {
  const calls = [];
  const fn = async (_page, panelText, opts) => {
    calls.push({ panelText, opts });
    return result;
  };
  fn.calls = calls;
  return fn;
}

function trashPage(tiles, texts) {
  return createFakePage({ timelineTiles: tiles, timelinePanelTextByLabel: texts });
}

test('runReconcileTrash: filename mismatch -> moveToTrash NEVER called (this gate, not the inner guard), needs_review', async () => {
  await withTempStore(async (store) => {
    const month = '2026-09';
    store.appendCandidate(month, cand('cand2', 'IMG_1002.HEIC', 'queued'));
    const page = trashPage([{ ariaLabel: 'candB', href: 'cand2' }], { candB: panelBlock('IMG_9999.HEIC') });
    const trash = spyTrash();
    await runReconcileTrash(page, month, store, { moveToTrash: trash });
    assert.equal(trash.calls.length, 0);
    assert.equal(store.listCandidates(month)[0].status, 'needs_review');
    assert.equal(store.loadStatus(month), 'done');
  });
});

test('runReconcileTrash: openInfoPanelOnce resolves but the re-read filename is null -> moveToTrash never called, needs_review', async () => {
  await withTempStore(async (store) => {
    const month = '2026-09';
    store.appendCandidate(month, cand('cand1', 'IMG_1001.HEIC', 'queued'));
    const page = trashPage([{ ariaLabel: 'candA', href: 'cand1' }], { candA: panelBlock('IMG_1001.HEIC') });
    // Panel reads fine until openInfoPanelOnce has seen its filename, then goes
    // blank (photo vanished between the open and the gate's re-read): the very
    // next evaluate() after the first filename-bearing one returns nothing.
    const realEvaluate = page.evaluate.bind(page);
    let sawFilename = false;
    page.evaluate = async (...args) => {
      if (sawFilename) return { detailsAndFile: [], dimsAndFile: [], fileOnly: [], detailsHeadingOnly: [] };
      const r = await realEvaluate(...args);
      if (r && (r.detailsAndFile?.length || r.dimsAndFile?.length || r.fileOnly?.length)) sawFilename = true;
      return r;
    };
    const trash = spyTrash();
    await runReconcileTrash(page, month, store, { moveToTrash: trash });
    assert.ok(sawFilename, 'fixture really did let openInfoPanelOnce resolve first');
    assert.equal(trash.calls.length, 0);
    assert.equal(store.listCandidates(month)[0].status, 'needs_review');
  });
});

test('runReconcileTrash: unreadable photo (openInfoPanelOnce throws) -> needs_review, never trashed, later candidates still processed', async () => {
  await withTempStore(async (store) => {
    const month = '2026-09';
    store.appendCandidate(month, cand('cand1', 'IMG_1001.HEIC', 'queued'));
    store.appendCandidate(month, cand('cand2', 'IMG_1002.HEIC', 'queued'));
    const page = trashPage(
      [{ ariaLabel: 'candA', href: 'cand1' }, { ariaLabel: 'candB', href: 'cand2' }],
      { candB: panelBlock('IMG_1002.HEIC') } // candA has no panel text at all
    );
    const trash = spyTrash();
    await runReconcileTrash(page, month, store, { moveToTrash: trash });
    const byId = Object.fromEntries(store.listCandidates(month).map((c) => [c.photoId, c.status]));
    assert.deepEqual(byId, { cand1: 'needs_review', cand2: 'trashed' });
    assert.equal(trash.calls.length, 1);
    assert.equal(store.loadStatus(month), 'done');
  });
});

test('runReconcileTrash: only status "queued" rows are trashed; an unconfirmed candidate row is left untouched', async () => {
  await withTempStore(async (store) => {
    const month = '2026-09';
    store.appendCandidate(month, cand('cand1', 'IMG_1001.HEIC', 'queued'));
    // Panel would match perfectly, so ONLY the status filter can stop it.
    store.appendCandidate(month, cand('cand2', 'IMG_1002.HEIC', 'candidate'));
    const page = trashPage(
      [{ ariaLabel: 'candA', href: 'cand1' }, { ariaLabel: 'candB', href: 'cand2' }],
      { candA: panelBlock('IMG_1001.HEIC'), candB: panelBlock('IMG_1002.HEIC') }
    );
    const trash = spyTrash();
    await runReconcileTrash(page, month, store, { moveToTrash: trash });
    assert.equal(trash.calls.length, 1);
    assert.equal(trash.calls[0].opts.expectedFilename, 'IMG_1001.HEIC');
    const byId = Object.fromEntries(store.listCandidates(month).map((c) => [c.photoId, c.status]));
    assert.deepEqual(byId, { cand1: 'trashed', cand2: 'candidate' });
  });
});

test('runReconcileTrash: moveToTrash result decides status (confirmed false -> needs_review) and is called with URL verification bound to the exact photo', async () => {
  await withTempStore(async (store) => {
    const month = '2026-09';
    store.appendCandidate(month, cand('cand1', 'IMG_1001.HEIC', 'queued'));
    const page = trashPage([{ ariaLabel: 'candA', href: 'cand1' }], { candA: panelBlock('IMG_1001.HEIC') });
    const trash = spyTrash({ confirmed: false, guardFailed: false, verifiedByUrl: false });
    await runReconcileTrash(page, month, store, { moveToTrash: trash });
    assert.equal(store.listCandidates(month)[0].status, 'needs_review');
    const { opts, panelText } = trash.calls[0];
    assert.equal(opts.verifyByUrl, true, 'must confirm the trash by re-visiting the URL');
    assert.equal(opts.matchedUrl, 'https://photos.google.com/photo/cand1');
    assert.equal(opts.expectedFilename, 'IMG_1001.HEIC');
    assert.match(panelText, /IMG_1001\.HEIC/);
  });
});

test('runReconcileTrash: real moveToTrash on a matching photo -> trashed, mismatched one is never actually trashed on the page', async () => {
  await withTempStore(async (store) => {
    const month = '2026-09';
    store.appendCandidate(month, cand('cand1', 'IMG_1001.HEIC', 'queued'));
    store.appendCandidate(month, cand('cand2', 'IMG_1002.HEIC', 'queued'));
    const page = trashPage(
      [{ ariaLabel: 'candA', href: 'cand1' }, { ariaLabel: 'candB', href: 'cand2' }],
      { candA: panelBlock('IMG_1001.HEIC'), candB: panelBlock('IMG_9999.HEIC') }
    );
    await runReconcileTrash(page, month, store);
    const byId = Object.fromEntries(store.listCandidates(month).map((c) => [c.photoId, c.status]));
    assert.deepEqual(byId, { cand1: 'trashed', cand2: 'needs_review' });
    assert.ok(page.trashedIdentities.has('cand1'));
    assert.ok(!page.trashedIdentities.has('cand2'));
    assert.equal(page.log.filter((l) => l === 'key:#').length, 1);
  });
});
