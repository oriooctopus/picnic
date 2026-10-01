import { test } from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, rmSync, existsSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { createFakePage } from './helpers/fakePage.mjs';
import { item, body, listingBody } from './helpers/listingFixture.mjs';
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


test('runReconcileScan: no manifest -> logs and writes no status', async () => {
  await withTempStore(async (store) => {
    const page = createFakePage({});
    await runReconcileScan(page, '2026-08', store);
    assert.equal(store.loadStatus('2026-08'), null);
    assert.deepEqual(store.listCandidates('2026-08'), []);
  });
});


test('runReconcileScan: tiles are collected in one evaluate round trip, never per-link getAttribute/isVisible', async () => {
  await withTempStore(async (store) => {
    const month = '2026-08';
    store.saveManifest(month, [manifestAsset('IMG_9999.HEIC', '2026-08-05T20:00:00.000Z')]);
    const label1 = 'Photo - Portrait - Aug 5, 2026, 3:00:00 PM';
    const page = createFakePage({
      searchResults: { 'August 5, 2026': [label1] },
      panelTextByLabel: { 'August 5, 2026': { [label1]: panelBlock('IMG_7777.HEIC') } },
      photoIdByLabel: { [label1]: 'onePhoto' },
    });
    await runReconcileScan(page, month, store);
    assert.ok(page.collectEvaluates > 0, 'collection went through page.evaluate');
    assert.equal(page.perLinkReads ?? 0, 0, 'no per-link getAttribute/isVisible round trips');
  });
});



const T = (iso) => Date.parse(iso);
const OK_FETCH = (urls) => async (url) => {
  urls.push(url);
  return { ok: true, status: 200, arrayBuffer: async () => new TextEncoder().encode('thumb-bytes').buffer };
};

test('runReconcileScan: one month-wide search; only items with no manifest timestamp+dimension match become candidates; nothing is ever opened', async () => {
  await withTempStore(async (store) => {
    const month = '2026-08';
    store.saveManifest(month, [
      { filename: 'IMG_1.HEIC', creationDate: '2026-08-05T12:54:07.000Z', pixelWidth: 3024, pixelHeight: 4032 },
      { filename: 'IMG_2.HEIC', creationDate: '2026-08-05T13:31:07.000Z', pixelWidth: 4032, pixelHeight: 3024 },
    ]);
    const label = 'Photo - Portrait - Aug 5, 2026, 6:54:07 PM';
    const page = createFakePage({
      searchResults: { 'August 2026': [label] },
      listingResponses: {
        'August 2026': {
          onSearch: [
            listingBody([
              item('AF1QipAAA', T('2026-08-05T12:54:07.000Z')), // exact match -> on phone
              item('AF1QipBBB', T('2026-08-05T13:31:08.500Z')), // 1.5s jitter, rotated dims -> on phone
              item('AF1QipCCC', T('2026-08-05T15:00:00.000Z')), // no manifest entry -> candidate
              item('AF1QipDDD', T('2026-08-05T12:54:07.000Z'), { w: 1000, h: 1000 }), // time matches, dims do not -> candidate
              item('AF1QipFFF', T('2026-09-01T02:00:00.000Z')), // local Aug 31 20:00 -> IN month
              item('AF1QipGGG', T('2026-08-01T03:00:00.000Z')), // local Jul 31 21:00 -> out of month
            ]),
            // non-listing rpc and a non-batchexecute URL: ignored
            body([{ rpc: 'KI4Ef', payload: [[null, null, 2]] }]),
            { url: 'https://photos.google.com/manifest.json', body: '{"name":"x"}' },
          ],
          onScroll: [
            [listingBody([item('AF1QipEEE', T('2026-08-05T16:00:00.000Z')), item('AF1QipCCC', T('2026-08-05T15:00:00.000Z'))], 'frGlJf')], // new + duplicate key
          ],
        },
      },
    });
    const urls = [];
    await runReconcileScan(page, month, store, { fetchImpl: OK_FETCH(urls) });

    const list = store.listCandidates(month);
    assert.deepEqual(list.map((c) => c.photoId).sort(), ['AF1QipCCC', 'AF1QipDDD', 'AF1QipEEE', 'AF1QipFFF']);
    const c = list.find((x) => x.photoId === 'AF1QipCCC');
    assert.deepEqual(
      { ...c },
      { photoId: 'AF1QipCCC', filename: null, cameraModel: null, captureDateMs: T('2026-08-05T15:00:00.000Z'), pixelWidth: 3024, pixelHeight: 4032, status: 'candidate' }
    );
    assert.equal(sectionForCameraModel(c.cameraModel), 'other');
    assert.ok(urls.every((u) => u.endsWith('=w400')) && urls.length === 6, 'thumbnails (4 candidates + 2 matched) fetched from thumbUrl + =w400');
    assert.ok(existsSync(store.thumbPath(month, 'AF1QipCCC')));
    assert.deepEqual(page.log.filter((l) => l.startsWith('type:')), ['type:August 2026'], 'exactly one search, for the month');
    assert.equal(page.log.filter((l) => l.startsWith('tile-click:')).length, 0, 'no photo was ever opened');
    assert.equal(page.log.filter((l) => l === 'screenshot').length, 0);
    assert.equal(page.log.filter((l) => l.startsWith('goto:')).length, 0);
    assert.equal(store.loadStatus(month), 'ready');
    assert.equal(page._responseHandlers.length, 0, 'response listener detached');
  });
});

test('runReconcileScan: default thumbnail fetch goes through the browser request context with a short timeout, in parallel', async () => {
  await withTempStore(async (store) => {
    const month = '2026-08';
    store.saveManifest(month, [{ filename: 'IMG_1.HEIC', creationDate: '2026-08-05T12:00:00.000Z', pixelWidth: 1, pixelHeight: 1 }]);
    const many = Array.from({ length: 12 }, (_, n) => item(`AF1QipT${n}`, T(`2026-08-05T${String(13 + (n % 9)).padStart(2, '0')}:${String(n).padStart(2, '0')}:00.000Z`)));
    const page = createFakePage({
      searchResults: { 'August 2026': ['Photo - Portrait - Aug 5, 2026, 6:54:07 PM'] },
      listingResponses: { 'August 2026': { onSearch: [listingBody(many)] } },
    });
    let inFlight = 0;
    let maxInFlight = 0;
    const calls = [];
    page.request = {
      get: async (url, opts) => {
        calls.push({ url, opts });
        inFlight += 1;
        maxInFlight = Math.max(maxInFlight, inFlight);
        await new Promise((r) => setTimeout(r, 10));
        inFlight -= 1;
        if (url.includes('AF1QipT3') || calls.length === 4) return { ok: () => false, status: () => 500, body: async () => Buffer.alloc(0) };
        return { ok: () => true, status: () => 200, body: async () => Buffer.from('bytes') };
      },
    };
    const start = Date.now();
    await runReconcileScan(page, month, store);
    assert.equal(store.listCandidates(month).length, 12, 'every candidate recorded');
    assert.equal(calls.length, 12);
    assert.ok(calls.every((c) => c.opts.timeout > 0 && c.opts.timeout <= 10000), 'short per-thumb timeout');
    assert.ok(maxInFlight > 1, 'thumbs fetched concurrently');
    assert.ok(Date.now() - start < 5000);
    const have = store.listCandidates(month).filter((c) => existsSync(store.thumbPath(month, c.photoId))).length;
    assert.equal(have, 11, 'the one failed thumb is skipped, the rest saved');
  });
});

test('runReconcileScan: a failed thumbnail fetch is loud but the candidate is still recorded', async () => {
  await withTempStore(async (store) => {
    const month = '2026-08';
    store.saveManifest(month, [{ filename: 'IMG_1.HEIC', creationDate: '2026-08-05T12:00:00.000Z', pixelWidth: 1, pixelHeight: 1 }]);
    const page = createFakePage({
      searchResults: { 'August 2026': ['Photo - Portrait - Aug 5, 2026, 6:54:07 PM'] },
      listingResponses: { 'August 2026': { onSearch: [listingBody([item('AF1QipXXX', T('2026-08-05T15:00:00.000Z'))])] } },
    });
    await runReconcileScan(page, month, store, { fetchImpl: async () => ({ ok: false, status: 403 }) });
    assert.deepEqual(store.listCandidates(month).map((c) => c.photoId), ['AF1QipXXX']);
    assert.ok(!existsSync(store.thumbPath(month, 'AF1QipXXX')));
    assert.equal(store.loadStatus(month), 'ready');
  });
});

test('runReconcileScan: keeps scrolling while new listing responses arrive, so items loaded by later scrolls are found', async () => {
  await withTempStore(async (store) => {
    const month = '2026-08';
    store.saveManifest(month, [{ filename: 'IMG_1.HEIC', creationDate: '2026-08-05T12:00:00.000Z', pixelWidth: 1, pixelHeight: 1 }]);
    const batches = [1, 2, 3, 4].map((n) => [listingBody([item(`AF1QipS${n}`, T(`2026-08-05T1${n}:00:00.000Z`))])]);
    const page = createFakePage({
      searchResults: { 'August 2026': ['Photo - Portrait - Aug 5, 2026, 6:54:07 PM'] },
      listingResponses: { 'August 2026': { onScroll: batches } },
    });
    await runReconcileScan(page, month, store, { fetchImpl: OK_FETCH([]) });
    assert.deepEqual(store.listCandidates(month).map((c) => c.photoId), ['AF1QipS1', 'AF1QipS2', 'AF1QipS3', 'AF1QipS4']);
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

/** Filename-less (listing-scan) candidate: captureDateMs/dims line up with panelBlock() (Aug 5 6:54 PM GMT-06:00, 2316 x 3088). */
const PANEL_CAPTURE_MS = Date.parse('2026-08-06T00:54:00.000Z');
function listingCand(photoId, over = {}) {
  return { photoId, filename: null, cameraModel: null, captureDateMs: PANEL_CAPTURE_MS + 7000, pixelWidth: 2316, pixelHeight: 3088, status: 'queued', ...over };
}
function listingTrashSetup(store, candOver, manifest, panel = panelBlock('IMG_7777.HEIC').replace('Aug 5Wed', 'Aug 5\nWed')) {
  const month = '2026-08';
  if (manifest !== null) store.saveManifest(month, manifest);
  store.appendCandidate(month, listingCand('cand1', candOver));
  return { month, page: trashPage([{ ariaLabel: 'candA', href: 'cand1' }], { candA: panel }), trash: spyTrash() };
}
const OTHER_MANIFEST = [manifestAsset('IMG_0001.HEIC', '2026-08-05T10:00:00.000Z')];

test('runReconcileTrash: filename-null candidate whose re-read filename is off the manifest and whose time+dims agree IS trashed, bound to the re-read filename', async () => {
  await withTempStore(async (store) => {
    const { month, page, trash } = listingTrashSetup(store, {}, OTHER_MANIFEST);
    await runReconcileTrash(page, month, store, { moveToTrash: trash });
    assert.equal(trash.calls.length, 1);
    assert.equal(trash.calls[0].opts.expectedFilename, 'IMG_7777.HEIC');
    assert.equal(store.listCandidates(month)[0].status, 'trashed');
  });
});

test('runReconcileTrash: filename-null candidate whose re-read filename IS on the phone (manifest) -> needs_review, never trashed', async () => {
  await withTempStore(async (store) => {
    const { month, page, trash } = listingTrashSetup(store, {}, [...OTHER_MANIFEST, manifestAsset('IMG_7777.HEIC', '2026-08-05T12:54:00.000Z')]);
    await runReconcileTrash(page, month, store, { moveToTrash: trash });
    assert.equal(trash.calls.length, 0);
    assert.equal(store.listCandidates(month)[0].status, 'needs_review');
  });
});

test('runReconcileTrash: filename-null candidate whose capture time disagrees with the photo now at that URL -> needs_review', async () => {
  await withTempStore(async (store) => {
    const { month, page, trash } = listingTrashSetup(store, { captureDateMs: PANEL_CAPTURE_MS + 3600000 }, OTHER_MANIFEST);
    await runReconcileTrash(page, month, store, { moveToTrash: trash });
    assert.equal(trash.calls.length, 0);
    assert.equal(store.listCandidates(month)[0].status, 'needs_review');
  });
});

test('runReconcileTrash: filename-null candidate whose dimensions disagree -> needs_review', async () => {
  await withTempStore(async (store) => {
    const { month, page, trash } = listingTrashSetup(store, { pixelWidth: 1000, pixelHeight: 1000 }, OTHER_MANIFEST);
    await runReconcileTrash(page, month, store, { moveToTrash: trash });
    assert.equal(trash.calls.length, 0);
    assert.equal(store.listCandidates(month)[0].status, 'needs_review');
  });
});

test('runReconcileTrash: filename-null candidate with no manifest to re-check against -> needs_review', async () => {
  await withTempStore(async (store) => {
    const { month, page, trash } = listingTrashSetup(store, {}, null);
    await runReconcileTrash(page, month, store, { moveToTrash: trash });
    assert.equal(trash.calls.length, 0);
    assert.equal(store.listCandidates(month)[0].status, 'needs_review');
  });
});
