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

// REGRESSION TEST for the exact bug the seenPhotoIds.add() reordering fixes
// (live 2026-09-29): a photo's FIRST tile fails to read a filename (here,
// openInfoPanelOnce throws outright -- the brief's "or" alternative to a
// successful-open-but-null-filename race, which is simpler to model here and
// exercises the same seenPhotoIds ordering). If seenPhotoIds.add(photoId) ran
// right after the dup check (the OLD position, before the panel read), the
// photoId would already be marked "seen" by the time label1's failure
// unwinds -- so label2, the SAME photo's other grid-size tile, would be
// skipped as a duplicate and the photo would never be recorded at all. Only
// adding it AFTER parsePanelText yields a real filename keeps the id
// retryable until a read actually succeeds.
test('runReconcileScan: a photo whose first tile fails to read a filename is still recorded when a later tile of the same photo succeeds', async () => {
  await withTempStore(async (store) => {
    const month = '2026-08';
    // Timestamp far from either tile's capture time -- the fast path must
    // never plan this photo away, or the seenPhotoIds ordering this test
    // targets would never be exercised.
    store.saveManifest(month, [manifestAsset('IMG_9999.HEIC', '2026-08-05T20:00:00.000Z')]);

    const label1 = 'Photo - Portrait - Aug 5, 2026, 3:00:00 PM'; // first tile of the photo -- no panel text configured, so openInfoPanelOnce throws
    const label2 = 'Photo - Portrait - Aug 5, 2026, 3:00:01 PM'; // second tile, same underlying photo -- panel reads fine
    const page = createFakePage({
      searchResults: { 'August 5, 2026': [label1, label2] },
      panelTextByLabel: {
        'August 5, 2026': { [label2]: panelBlock('IMG_7777.HEIC') }, // label1 deliberately has NO entry
      },
      // Google's two grid sizes render the SAME underlying photo under two
      // different tile labels/hrefs -- pinning both to one photoId is what
      // makes this the exact live scenario (a second, later-loaded tile of a
      // photo whose first read failed).
      photoIdByLabel: { [label1]: 'samePhoto', [label2]: 'samePhoto' },
    });

    await runReconcileScan(page, month, store); // must not throw

    const candidates = store.listCandidates(month);
    assert.deepEqual(
      candidates.map((c) => c.photoId),
      ['samePhoto'],
      "the photo must still be recorded via label2 even though label1 (same photoId) failed to read a filename first"
    );
    assert.equal(candidates[0].filename, 'IMG_7777.HEIC');
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

test("runReconcileScan: closeAnyOpenPhoto presses Escape and reaches the grid even when the viewer draws late, so the next day's search still finds its tile", async () => {
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
      // Models the OTHER live gap (distinct from lateOpeningLabels, which
      // delays the URL itself): here page.url() is /photo/<id> the instant
      // the tile is clicked, exactly like Google, but the trash control
      // (closeAnyOpenPhoto's "is a photo really showing" signal) stays
      // hidden until closeAnyOpenPhoto's own TRASH_SELECTOR.waitFor()
      // resolves it -- see fakePage.mjs's viewerRendersLateLabels comment.
      viewerRendersLateLabels: new Set([lateLabel]),
    });

    await runReconcileScan(page, month, store);

    // Without the fix, atGrid() (URL-blind) sees "search box visible, trash
    // not yet visible" during the render gap and wrongly calls that "at the
    // grid" -- so closeAnyOpenPhoto returns WITHOUT pressing Escape, and
    // openedAriaLabel/openedIdentity are never cleared. The next tile's
    // identity-scoped locator then counts 0 (fakePage's countFor treats "a
    // photo is open" as "grid unreachable", exactly like the live viewer
    // covering the grid) and openTile() throws StaleTileError, silently
    // dropping the next day's candidate -- this is the "next searchByDate
    // still works" half of the bug, reproduced without needing to model the
    // real search-box-hidden-behind-the-viewer visual overlap.
    const candidates = store.listCandidates(month);
    assert.deepEqual(
      candidates.map((c) => c.photoId).sort(),
      ['latePhoto', 'nextDayPhoto'],
      'the late-rendering tile was closed properly, so the next day\'s tile was still reachable and became a candidate'
    );
    // One Escape per tile closed (late-rendering AND the normal next-day
    // tile) -- proves closeAnyOpenPhoto actually pressed Escape for the
    // late-rendering tile rather than short-circuiting on a falsely-"at the
    // grid" read (which would leave this at 1, only the next-day tile's).
    assert.equal(page.escapePresses, 2, 'closeAnyOpenPhoto must press Escape for both tiles, including the late-rendering one');
  });
});

test("runReconcileScan: searchByDate waits for the new day's tiles to actually render instead of trusting the old grid still being on screen", async () => {
  await withTempStore(async (store) => {
    const month = '2026-08';
    store.saveManifest(month, [manifestAsset('IMG_9999.HEIC', '2026-08-06T20:00:00.000Z')]);

    const dayOneLabel = 'Photo - Portrait - Aug 5, 2026, 3:00:00 PM';
    const dayTwoLabel = 'Photo - Portrait - Aug 6, 2026, 3:00:00 PM';
    const page = createFakePage({
      searchResults: {
        'August 5, 2026': [dayOneLabel],
        'August 6, 2026': [dayTwoLabel],
      },
      panelTextByLabel: {
        'August 5, 2026': { [dayOneLabel]: panelBlock('IMG_7777.HEIC') },
        'August 6, 2026': { [dayTwoLabel]: panelBlock('IMG_8888.HEIC') },
      },
      photoIdByLabel: { [dayOneLabel]: 'dayOnePhoto', [dayTwoLabel]: 'dayTwoPhoto' },
      // 2026-09-29 live evidence (see searchByDate's own header comment): the
      // grid still shows the PREVIOUS day's tiles for a beat after Enter.
      // Two reads' worth of delay here -- with the old
      // `waitFor({state:'visible'}).catch()` code, that single immediate read
      // sees day one's still-mounted tile, opens IT again instead of day
      // two's, and dayTwoPhoto never becomes a candidate.
      searchRevealDelay: { 'August 6, 2026': 2 },
    });

    await runReconcileScan(page, month, store);

    const candidates = store.listCandidates(month);
    assert.deepEqual(
      candidates.map((c) => c.photoId).sort(),
      ['dayOnePhoto', 'dayTwoPhoto'],
      "searchByDate must poll until August 6's own tile actually renders, not settle for August 5's stale grid"
    );
  });
});

// REGRESSION TEST for the exact bug runReconcileScan's own header comment
// documents (2026-09-29 live evidence): the pre-scroll that builds `tiles`
// for planAriaMatches walks a VIRTUALIZED grid all the way to the bottom,
// which unmounts the early tiles it passed over on the way down. The OLD
// code then opened `tiles` in that same top-to-bottom order and hit
// StaleTileError on every early one -- gone forever, never revisited.
//
// windowSize: 2 against 5 total tiles means the pre-scroll (which snaps the
// window to the tail on every downward scroll, per fakePage's
// windowedTiles()) ends with only the LAST 2 tiles mounted -- the first 3
// are exactly the tiles the old code would silently drop. No manifest entry
// matches any tile's capture time, so every tile is unplanned and must be
// opened for this test to mean anything.
test('runReconcileScan: every tile on a big, virtualized day is recovered, not just the ones still mounted after the pre-scroll', async () => {
  await withTempStore(async (store) => {
    const month = '2026-08';
    // Timestamp far from any tile below -- the fast path must never plan
    // any of them away, or this test would not prove the walk recovers them.
    store.saveManifest(month, [manifestAsset('IMG_9999.HEIC', '2026-08-05T02:00:00.000Z')]);

    const TILE_COUNT = 5;
    const labels = Array.from({ length: TILE_COUNT }, (_, i) => `Photo - Portrait - Aug 5, 2026, ${i + 3}:00:00 PM`);
    const panelTextByLabel = { 'August 5, 2026': {} };
    const photoIdByLabel = {};
    labels.forEach((label, i) => {
      panelTextByLabel['August 5, 2026'][label] = panelBlock(`IMG_7${String(i).padStart(3, '0')}.HEIC`);
      photoIdByLabel[label] = `photo${i}`;
    });

    const page = createFakePage({
      searchResults: { 'August 5, 2026': [labels[0]] },
      scrollReveals: { 'August 5, 2026': labels.slice(1).map((l) => [{ ariaLabel: l }]) },
      panelTextByLabel,
      photoIdByLabel,
      windowSize: 2, // only the last 2 of 5 tiles are mounted once the pre-scroll reaches the bottom
    });

    await runReconcileScan(page, month, store);

    const candidates = store.listCandidates(month);
    assert.deepEqual(
      candidates.map((c) => c.photoId).sort(),
      labels.map((_, i) => `photo${i}`).sort(),
      `every one of the ${TILE_COUNT} tiles must become a candidate, including the ones unmounted by the pre-scroll`
    );
  });
});

test('runReconcileScan: a single-tile photo whose panel blanks right after it validated is still recorded (no second read)', async () => {
  await withTempStore(async (store) => {
    const month = '2026-08';
    store.saveManifest(month, [manifestAsset('IMG_9999.HEIC', '2026-08-05T02:00:00.000Z')]);
    const label = 'Photo - Portrait - Aug 5, 2026, 3:00:00 PM';
    const page = createFakePage({
      searchResults: { 'August 5, 2026': [label] },
      panelTextByLabel: { 'August 5, 2026': { [label]: panelBlock('IMG_8888.HEIC') } },
      photoIdByLabel: { [label]: 'photoX' },
    });
    // Live 2026-09-29: the panel validated a filename, then the very next panel
    // read came back blank. Blank exactly ONE panel read after the first
    // filename-bearing one; every other evaluate() passes through untouched.
    const realEvaluate = page.evaluate.bind(page);
    let sawFilename = false;
    let blanked = false;
    page.evaluate = async (...args) => {
      const r = await realEvaluate(...args);
      const isPanelRead = r && typeof r === 'object' && 'detailsAndFile' in r;
      if (!isPanelRead) return r;
      if (sawFilename && !blanked) {
        blanked = true;
        return { detailsAndFile: [], dimsAndFile: [], fileOnly: [], detailsHeadingOnly: [] };
      }
      if (r.detailsAndFile?.length || r.dimsAndFile?.length || r.fileOnly?.length) sawFilename = true;
      return r;
    };

    await runReconcileScan(page, month, store);

    assert.ok(sawFilename, 'fixture really did let the panel validate a filename first');
    assert.deepEqual(store.listCandidates(month).map((c) => c.photoId), ['photoX']);
  });
});

test('runReconcileScan: closing a photo never waits on the hidden duplicate trash button (was 5s per photo)', async () => {
  await withTempStore(async (store) => {
    const month = '2026-08';
    store.saveManifest(month, [manifestAsset('IMG_9999.HEIC', '2026-08-05T02:00:00.000Z')]);
    const labels = ['Photo - Portrait - Aug 5, 2026, 3:00:00 PM', 'Photo - Portrait - Aug 5, 2026, 4:00:00 PM'];
    const page = createFakePage({
      searchResults: { 'August 5, 2026': labels },
      panelTextByLabel: { 'August 5, 2026': { [labels[0]]: panelBlock('IMG_8001.HEIC'), [labels[1]]: panelBlock('IMG_8002.HEIC') } },
      photoIdByLabel: { [labels[0]]: 'p1', [labels[1]]: 'p2' },
      trashFirstIsHiddenDuplicate: true,
    });

    await runReconcileScan(page, month, store);

    assert.equal(store.listCandidates(month).length, 2, 'both photos were opened and recorded');
    assert.equal(page.hiddenTrashWaits ?? 0, 0, 'no visible-wait on the bare trash selector');
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
