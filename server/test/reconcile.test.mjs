import { test } from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, rmSync, existsSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { parseCameraModel } from '../lib/matcher.mjs';
import { diffGoogleVsManifest, sectionForCameraModel, ReconcileStore } from '../lib/reconcile.mjs';

// A manifest entry is what the phone sends per PHAsset; a google photo is what
// the worker produces from the read-only scan. Helper builders keep the six
// diff cases terse without losing the fields each one actually exercises.
function manifestAsset(filename, overrides = {}) {
  return {
    filename,
    creationDate: '2026-09-22T18:25:00.000Z',
    pixelWidth: 2316,
    pixelHeight: 3088,
    ...overrides,
  };
}

function googlePhoto(photoId, filename, cameraModel = 'Apple iPhone 13 Pro', overrides = {}) {
  return {
    photoId,
    filename,
    cameraModel,
    captureDateMs: Date.parse('2026-09-22T18:25:00.000Z'),
    pixelWidth: 2316,
    pixelHeight: 3088,
    ...overrides,
  };
}

test('diff: exact filename match is not a candidate', () => {
  const manifest = [manifestAsset('IMG_1433.HEIC')];
  const google = [googlePhoto('g1', 'IMG_1433.HEIC')];
  const { candidates, bySection } = diffGoogleVsManifest(manifest, google);
  assert.deepEqual(candidates, []);
  assert.deepEqual(bySection.iphone, []);
  assert.deepEqual(bySection.other, []);
});

test('diff: timezone ±1 day date shift does not change identity (filename only)', () => {
  const manifest = [manifestAsset('IMG_1433.HEIC', { creationDate: '2026-09-22T18:25:00.000Z' })];
  // Same filename, capture 24h later: the date shift is the scan's ±1-day
  // search concern, not the diff's -- filename presence decides identity.
  const google = [
    googlePhoto('g1', 'IMG_1433.HEIC', 'Apple iPhone 13 Pro', {
      captureDateMs: Date.parse('2026-09-22T18:25:00.000Z') + 24 * 60 * 60 * 1000,
    }),
  ];
  const { candidates } = diffGoogleVsManifest(manifest, google);
  assert.deepEqual(candidates, []);
});

test('diff: _Original suffix variant agrees both directions', () => {
  // manifest has the _Original re-import name, google has the bare name...
  const manifest = [manifestAsset('IMG_6716_Original.HEIC')];
  const google = [googlePhoto('g1', 'IMG_6716.HEIC')];
  assert.deepEqual(diffGoogleVsManifest(manifest, google).candidates, []);

  // ...and the reverse (google carries _Original, manifest is bare).
  const manifest2 = [manifestAsset('IMG_6716.HEIC')];
  const google2 = [googlePhoto('g1', 'IMG_6716_Original.HEIC')];
  assert.deepEqual(diffGoogleVsManifest(manifest2, google2).candidates, []);
});

test('diff: Live Photo video half is not a candidate; unmatched video is', () => {
  const manifest = [manifestAsset('IMG_1433.HEIC')];
  const google = [
    // Same base name as the manifest image -> the video half of that Live
    // Photo, already on the phone -> NOT a candidate.
    googlePhoto('g1', 'IMG_1433.mov'),
    // No manifest entry shares this base name -> genuinely only-in-Google.
    googlePhoto('g2', 'IMG_9999.mov'),
  ];
  const { candidates } = diffGoogleVsManifest(manifest, google);
  assert.deepEqual(candidates.map((c) => c.photoId), ['g2']);
});

test('diff: Live-Photo negatives -- manifest video does not excuse a google video; ext mismatch on a non-video is still a candidate', () => {
  // The video-half exemption only applies when the MANIFEST side is a still.
  // Manifest is itself a video with a different name -> google video stays a candidate.
  const m1 = [manifestAsset('IMG_1433.MOV')];
  assert.deepEqual(diffGoogleVsManifest(m1, [googlePhoto('g1', 'IMG_1433.mp4')]).candidates.map((c) => c.photoId), ['g1']);
  // google .jpg vs manifest .heic: same base but google is NOT a video -> no exemption, candidate.
  const m2 = [manifestAsset('IMG_1433.HEIC')];
  assert.deepEqual(diffGoogleVsManifest(m2, [googlePhoto('g2', 'IMG_1433.jpg')]).candidates.map((c) => c.photoId), ['g2']);
});

test('diff: _Original.MOV google video agrees with the bare manifest video name', () => {
  const manifest = [manifestAsset('IMG_6716.MOV')];
  const google = [googlePhoto('g1', 'IMG_6716_Original.MOV')];
  assert.deepEqual(diffGoogleVsManifest(manifest, google).candidates, []);
});

test('diff: duplicate filenames -- both copies kept or both dropped, per agreement', () => {
  const manifest = [manifestAsset('IMG_1433.HEIC')];
  const google = [
    // Two distinct google items (different photoIds) both named IMG_1433.HEIC
    // -> both agree with the manifest, neither is a candidate.
    googlePhoto('g1', 'IMG_1433.HEIC'),
    googlePhoto('g2', 'IMG_1433.HEIC'),
    // A filename absent from the manifest, appearing twice -> BOTH are
    // candidates, distinct photoIds preserved.
    googlePhoto('g3', 'IMG_5555.HEIC'),
    googlePhoto('g4', 'IMG_5555.HEIC'),
  ];
  const { candidates } = diffGoogleVsManifest(manifest, google);
  assert.deepEqual(candidates.map((c) => c.photoId), ['g3', 'g4']);
});

test('diff: missing camera model -> candidate in "other"; iPhone model -> "iphone"', () => {
  const manifest = [];
  const google = [
    googlePhoto('g1', 'IMG_0001.HEIC', null),
    googlePhoto('g2', 'IMG_0002.HEIC', 'Apple iPhone 13 Pro'),
  ];
  const { candidates, bySection } = diffGoogleVsManifest(manifest, google);
  assert.equal(candidates.length, 2);
  assert.deepEqual(bySection.other.map((c) => c.photoId), ['g1']);
  assert.deepEqual(bySection.iphone.map((c) => c.photoId), ['g2']);
});

test('sectionForCameraModel: a look-alike "Not Apple iPhone" is other', () => {
  assert.equal(sectionForCameraModel('Not Apple iPhone'), 'other');
});

test('sectionForCameraModel: only a non-null "Apple iPhone..." model is iphone', () => {
  assert.equal(sectionForCameraModel('Apple iPhone 13 Pro'), 'iphone');
  assert.equal(sectionForCameraModel('Apple iPhone 14 Pro Max'), 'iphone');
  assert.equal(sectionForCameraModel(null), 'other');
  assert.equal(sectionForCameraModel('WhatsApp Image 2026-09-22'), 'other');
  assert.equal(sectionForCameraModel('Canon EOS R5'), 'other');
  assert.equal(sectionForCameraModel('Apple iPad Pro (11-inch)'), 'other');
});

test('parseCameraModel: extracts the device string from both live panel shapes', () => {
  // Model PRESENT -- the panel runs the lens/EXIF block on directly after the
  // model ("Apple iPhone 13 Proƒ/2.2..."), so parsing must stop at the aperture.
  const withModel =
    'Details\nSep 22\nYesterday, 6:25 PM\nGMT-04:00\nApple iPhone 13 Proƒ/2.21/632.71mmISO40IMG_2928.HEIC7.2MP2316 × 3088';
  assert.equal(parseCameraModel(withModel), 'Apple iPhone 13 Pro');

  // Model ABSENT -- goes straight from the GMT offset to the filename.
  const withoutModel = 'Details\nSep 22\nYesterday, 2:34 PM\nGMT-04:00\nIMG_2929.JPG';
  assert.equal(parseCameraModel(withoutModel), null);
});

test('ReconcileStore: manifest, candidate fold, confirm/status, and thumb round-trip', () => {
  const dir = mkdtempSync(join(tmpdir(), 'picnic-reconcile-test-'));
  try {
    const store = new ReconcileStore(dir);
    const month = '2026-09';

    // manifest round-trip
    const assets = [manifestAsset('IMG_1433.HEIC')];
    store.saveManifest(month, assets);
    assert.deepEqual(store.loadManifest(month), assets);
    assert.equal(store.loadManifest('2026-08'), null); // unsaved month -> null

    // appendCandidate is idempotent per photoId on read: latest line wins.
    store.appendCandidate(month, googlePhoto('p1', 'IMG_0001.HEIC', 'Apple iPhone 13 Pro'));
    store.appendCandidate(month, googlePhoto('p1', 'IMG_0001.HEIC', 'Apple iPhone 14 Pro'));
    store.appendCandidate(month, googlePhoto('p2', 'IMG_0002.HEIC', null));
    let list = store.listCandidates(month);
    assert.equal(list.length, 2); // p1 folded to one, p2 distinct
    const p1 = list.find((c) => c.photoId === 'p1');
    assert.equal(p1.cameraModel, 'Apple iPhone 14 Pro'); // latest wins

    // confirm marks queued; updateCandidateStatus flips it; all three statuses work.
    store.confirm(month, ['p1', 'p2']);
    list = store.listCandidates(month);
    assert.equal(list.find((c) => c.photoId === 'p1').status, 'queued');
    assert.equal(list.find((c) => c.photoId === 'p2').status, 'queued');
    store.updateCandidateStatus(month, 'p1', 'trashed');
    store.updateCandidateStatus(month, 'p2', 'needs_review');
    list = store.listCandidates(month);
    assert.equal(list.find((c) => c.photoId === 'p1').status, 'trashed');
    assert.equal(list.find((c) => c.photoId === 'p2').status, 'needs_review');

    // updateCandidateStatus on an unknown photoId fails loudly, not silently.
    assert.throws(() => store.updateCandidateStatus(month, 'nope', 'queued'), /no candidate with photoId nope/);

    // thumbnail writes where thumbPath says it should be.
    const thumbPath = store.thumbPath(month, 'p1');
    assert.ok(!existsSync(thumbPath));
    assert.equal(store.saveThumb(month, 'p1', Buffer.from('fake-jpeg-bytes')), thumbPath);
    assert.ok(existsSync(thumbPath));
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});
