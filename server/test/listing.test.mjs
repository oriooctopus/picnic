import { test } from 'node:test';
import assert from 'node:assert/strict';
import { parseListingBody, filterItemsToMonth, mergeItems, localMonthOf } from '../lib/listing.mjs';
import { diffListingVsManifest, dimensionsAgree } from '../lib/reconcile.mjs';
import { item, body, listingBody } from './helpers/listingFixture.mjs';

const T = (iso) => Date.parse(iso);
const asset = (iso, w = 3024, h = 4032) => ({ filename: 'IMG_X.HEIC', creationDate: iso, pixelWidth: w, pixelHeight: h });

test('parseListingBody: extracts items from an EzkLib body, skipping preamble, length prefixes and noise lines', () => {
  const items = parseListingBody(listingBody([item('AF1QipA', 1774879351051, { w: 3024, h: 4032, tz: -14400000 }), item('AF1QipB', 1774879352000)]));
  assert.equal(items.length, 2);
  assert.deepEqual(items[0], {
    mediaKey: 'AF1QipA',
    thumbUrl: 'https://lh3.googleusercontent.com/synthetic/AF1QipA',
    height: 4032,
    width: 3024,
    captureMs: 1774879351051,
    tzOffsetMs: -14400000,
    uploadMs: 1777517769332,
  });
});

test('parseListingBody: several wrb.fr lines in one body, across rpcs, are all read', () => {
  const b = body([
    { rpc: 'EzkLib', payload: [[item('AF1QipA', 1000000000000)]] },
    { rpc: 'ZSBAec', payload: [[[item('AF1QipB', 1000000001000)]]] },
    { rpc: 'frGlJf', payload: [item('AF1QipC', 1000000002000)] },
  ]);
  assert.deepEqual(parseListingBody(b).map((i) => i.mediaKey), ['AF1QipA', 'AF1QipB', 'AF1QipC']);
});

test('parseListingBody: non-listing rpcs, album/ref arrays and look-alikes yield nothing', () => {
  const lookalikes = [
    ['AF1QipNoThumb', 'notalist', 1000000000000, 'd', 0, 1], // o[1] not a list
    ['AF1QipNoUrl', ['not-a-url', 1, 2], 1000000000000, 'd', 0, 1],
    ['AF1QipNoTime', ['http://x', 1, 2], 'str', 'd', 0, 1],
    ['NotAKey', ['http://x', 1, 2], 1000000000000, 'd', 0, 1],
    ['AF1QipShort', ['http://x', 1, 2], 1000000000000],
  ];
  const b = body([
    { rpc: 'KI4Ef', payload: [[null, null, 2]] },
    { rpc: 'rJ0tlb', payload: [56534, [[1674584748000, 1675718167999, 73, 1]]] },
    { rpc: 'ZSBAec', payload: [lookalikes, ['AF1QipAlbumOnly']] },
  ]);
  assert.deepEqual(parseListingBody(b), []);
  assert.deepEqual(parseListingBody(''), []);
  assert.deepEqual(parseListingBody(")]}'\n\n"), []);
});

test('parseListingBody: a wrb.fr line whose payload is not valid JSON is a loud format-change error', () => {
  const bad = `)]}'\n\n10\n[["wrb.fr","EzkLib","{not json"]]\n`;
  assert.throws(() => parseListingBody(bad), SyntaxError);
});

test('filterItemsToMonth: local month = capture + tz offset, at both month edges', () => {
  const lateMarch = item('AF1QipA', T('2026-04-01T02:00:00Z'), { tz: -14400000 }); // local Mar 31 22:00 -> March
  const earlyMarch = item('AF1QipB', T('2026-03-01T02:00:00Z'), { tz: -18000000 }); // local Feb 28 21:00 -> Feb
  const utcMarchLocalApril = item('AF1QipC', T('2026-03-31T22:00:00Z'), { tz: 7200000 }); // local Apr 1 00:00 -> April
  const out = filterItemsToMonth(parseListingBody(listingBody([lateMarch, earlyMarch, utcMarchLocalApril])), '2026-03');
  assert.deepEqual(out.map((i) => i.mediaKey), ['AF1QipA']);
  assert.equal(localMonthOf({ captureMs: T('2026-03-31T22:00:00Z'), tzOffsetMs: 7200000 }), '2026-04');
});

test('mergeItems: a media key seen in several responses is kept once (first wins)', () => {
  const byKey = new Map();
  const a = parseListingBody(listingBody([item('AF1QipA', 1), item('AF1QipB', 2)]));
  const b = parseListingBody(listingBody([item('AF1QipB', 999), item('AF1QipC', 3)]));
  assert.equal(mergeItems(byKey, a), 2);
  assert.equal(mergeItems(byKey, b), 1);
  assert.equal(byKey.get('AF1QipB').captureMs, 2);
  assert.equal(byKey.size, 3);
});

const items = (...xs) => parseListingBody(listingBody(xs));

test('diffListingVsManifest: exact match is on the phone, an unmatched item is a filename-less candidate', () => {
  const manifest = [asset('2026-03-13T20:00:00.000Z')];
  const out = diffListingVsManifest(manifest, items(item('AF1QipA', T('2026-03-13T20:00:00Z')), item('AF1QipB', T('2026-03-13T21:00:00Z'))));
  assert.deepEqual(out.map((c) => c.photoId), ['AF1QipB']);
  assert.equal(out[0].filename, null);
  assert.equal(out[0].cameraModel, null);
  assert.equal(out[0].captureDateMs, T('2026-03-13T21:00:00Z'));
});

test('diffListingVsManifest: 1-2s jitter still matches, 3s does not', () => {
  const manifest = [asset('2026-03-13T20:00:00.000Z')];
  const at = (ms) => diffListingVsManifest(manifest, items(item('AF1QipA', T('2026-03-13T20:00:00Z') + ms))).length;
  assert.equal(at(1500), 0);
  assert.equal(at(-2000), 0);
  assert.equal(at(3000), 1);
  assert.equal(at(-3000), 1);
});

test('diffListingVsManifest: same time but different dimensions is a candidate; swapped w/h is the same photo', () => {
  const manifest = [asset('2026-03-13T20:00:00.000Z', 3024, 4032)];
  assert.equal(diffListingVsManifest(manifest, items(item('AF1QipA', T('2026-03-13T20:00:00Z'), { w: 1920, h: 1080 }))).length, 1);
  assert.equal(diffListingVsManifest(manifest, items(item('AF1QipB', T('2026-03-13T20:00:00Z'), { w: 4032, h: 3024 }))).length, 0);
  assert.equal(dimensionsAgree(null, 1, 1, 1), false);
});

test('diffListingVsManifest: a media key duplicated across responses yields one candidate', () => {
  const dup = item('AF1QipA', T('2026-03-13T21:00:00Z'));
  assert.equal(diffListingVsManifest([], [...items(dup), ...items(dup)]).length, 1);
});
