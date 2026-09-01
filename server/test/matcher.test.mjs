import { test } from 'node:test';
import assert from 'node:assert/strict';
import {
  parsePanelText,
  filenamesAgree,
  dimensionsAgree,
  findMatchingJob,
  utcDateOf,
  shiftDateDays,
  formatSearchDate,
  groupJobsByDate,
  isRealPhotoTile,
  dedupeTilesByAriaLabel,
} from '../lib/matcher.mjs';

// Verbatim panel text observed live, 2026-09-01 (see task brief).
const IMG_1433_BLOCK =
  "InfoAdd a descriptionPeopleDetailsAug 5Wed, 6:54 PMGMT-06:00Apple iPhone 13 Pro" +
  "ƒ/2.21/632.71mmISO40IMG_1433.HEIC7.2MP2316 × 3088Uploaded from iOS deviceBacked up (6 MB)Original quality. Learn moreWestminster, CO";

const IMG_1441_BLOCK =
  "InfoAdd a descriptionPeopleDetailsAug 5Wed, 7:31 PMGMT-06:00Apple iPhone 13 Pro" +
  "ƒ/1.61/1201.55mmISO64IMG_1441.HEIC5.1MP3024 × 4032Uploaded from iOS deviceBacked up (5 MB)Original quality. Learn moreWestminster, CO";

const UUID_BLOCK =
  "InfoAdd a descriptionPeopleDetailsAug 7Fri, 5:28 AMGMT-06:00" +
  "ISO64a3c16ffc-7158-40d9-86d6-efa6f6910600.jpg1.2MP1010 × 571Uploaded from iOS deviceBacked up (1 MB)Original quality. Learn moreWestminster, CO";

test('parsePanelText: extracts filename and dimensions from run-together text', () => {
  const parsed = parsePanelText(IMG_1433_BLOCK);
  assert.equal(parsed.filename, 'IMG_1433.HEIC');
  assert.equal(parsed.pixelWidth, 2316);
  assert.equal(parsed.pixelHeight, 3088);
});

test('parsePanelText: the digit run glued to the filename (ISO value) is never absorbed into it', () => {
  const parsed = parsePanelText(IMG_1433_BLOCK);
  assert.equal(parsed.filename, 'IMG_1433.HEIC', 'must not be "ISO40IMG_1433.HEIC" or similar');
});

test('parsePanelText: UUID-style filenames parse correctly', () => {
  const parsed = parsePanelText(UUID_BLOCK);
  assert.equal(parsed.filename, 'a3c16ffc-7158-40d9-86d6-efa6f6910600.jpg');
  assert.equal(parsed.pixelWidth, 1010);
  assert.equal(parsed.pixelHeight, 571);
});

test('parsePanelText: when two photos\' blocks are concatenated, picks the CURRENT (last) one', () => {
  const concatenated = IMG_1433_BLOCK + IMG_1441_BLOCK;
  const parsed = parsePanelText(concatenated);
  assert.equal(parsed.filename, 'IMG_1441.HEIC');
  assert.equal(parsed.pixelWidth, 3024);
  assert.equal(parsed.pixelHeight, 4032);
});

test('parsePanelText: three concatenated blocks still picks the last', () => {
  const concatenated = IMG_1433_BLOCK + IMG_1441_BLOCK + UUID_BLOCK;
  const parsed = parsePanelText(concatenated);
  assert.equal(parsed.filename, 'a3c16ffc-7158-40d9-86d6-efa6f6910600.jpg');
  assert.equal(parsed.pixelWidth, 1010);
  assert.equal(parsed.pixelHeight, 571);
});

test('parsePanelText: no filename in the text -> null fields, not a throw', () => {
  const parsed = parsePanelText('Info Add a description People Details Aug 5');
  assert.equal(parsed.filename, null);
  assert.equal(parsed.pixelWidth, null);
  assert.equal(parsed.pixelHeight, null);
});

test('parsePanelText: empty/undefined text -> null fields', () => {
  assert.deepEqual(parsePanelText(''), { filename: null, pixelWidth: null, pixelHeight: null });
  assert.deepEqual(parsePanelText(undefined), { filename: null, pixelWidth: null, pixelHeight: null });
});

test('filenamesAgree: case-insensitive', () => {
  assert.equal(filenamesAgree('IMG_1433.HEIC', 'img_1433.heic'), true);
  assert.equal(filenamesAgree('IMG_1433.HEIC', 'IMG_1434.HEIC'), false);
});

test('dimensionsAgree: matches straight', () => {
  const job = { pixelWidth: 3024, pixelHeight: 4032 };
  assert.equal(dimensionsAgree(job, { pixelWidth: 3024, pixelHeight: 4032 }), true);
});

test('dimensionsAgree: matches transposed (Google may report W x H swapped)', () => {
  const job = { pixelWidth: 3024, pixelHeight: 4032 };
  assert.equal(dimensionsAgree(job, { pixelWidth: 4032, pixelHeight: 3024 }), true);
});

test('dimensionsAgree: genuine mismatch fails both orientations', () => {
  const job = { pixelWidth: 3024, pixelHeight: 4032 };
  assert.equal(dimensionsAgree(job, { pixelWidth: 1170, pixelHeight: 2532 }), false);
});

test('dimensionsAgree: missing parsed dims fails', () => {
  const job = { pixelWidth: 3024, pixelHeight: 4032 };
  assert.equal(dimensionsAgree(job, { pixelWidth: null, pixelHeight: null }), false);
});

test('findMatchingJob: filename mismatch never matches, regardless of dimensions', () => {
  const jobs = [{ id: 'a', filename: 'IMG_1433.HEIC', pixelWidth: 2316, pixelHeight: 3088 }];
  const parsed = { filename: 'IMG_9999.HEIC', pixelWidth: 2316, pixelHeight: 3088 };
  assert.equal(findMatchingJob(jobs, parsed), null);
});

test('findMatchingJob: filename matches but dimensions disagree -> no match', () => {
  const jobs = [{ id: 'a', filename: 'IMG_1433.HEIC', pixelWidth: 2316, pixelHeight: 3088 }];
  const parsed = { filename: 'IMG_1433.HEIC', pixelWidth: 100, pixelHeight: 100 };
  assert.equal(findMatchingJob(jobs, parsed), null);
});

test('findMatchingJob: unique filename+dimensions agreement returns that job', () => {
  const jobs = [
    { id: 'a', filename: 'IMG_1433.HEIC', pixelWidth: 2316, pixelHeight: 3088 },
    { id: 'b', filename: 'IMG_1441.HEIC', pixelWidth: 3024, pixelHeight: 4032 },
  ];
  const parsed = { filename: 'IMG_1441.HEIC', pixelWidth: 3024, pixelHeight: 4032 };
  const job = findMatchingJob(jobs, parsed);
  assert.equal(job.id, 'b');
});

test('findMatchingJob: transposed dimensions still resolve to the job', () => {
  const jobs = [{ id: 'a', filename: 'IMG_1433.HEIC', pixelWidth: 3088, pixelHeight: 2316 }];
  const parsed = { filename: 'IMG_1433.HEIC', pixelWidth: 2316, pixelHeight: 3088 };
  assert.equal(findMatchingJob(jobs, parsed).id, 'a');
});

test('utcDateOf: extracts the UTC calendar date', () => {
  assert.equal(utcDateOf('2026-08-05T03:08:21Z'), '2026-08-05');
  assert.equal(utcDateOf('2026-08-05T23:59:59Z'), '2026-08-05');
});

test('shiftDateDays: +/-1 day, including month/year rollover', () => {
  assert.equal(shiftDateDays('2026-08-05', -1), '2026-08-04');
  assert.equal(shiftDateDays('2026-08-05', 1), '2026-08-06');
  assert.equal(shiftDateDays('2026-09-01', -1), '2026-08-31');
  assert.equal(shiftDateDays('2026-12-31', 1), '2027-01-01');
});

test('formatSearchDate: "Month D, YYYY" as typed into the search box', () => {
  assert.equal(formatSearchDate('2026-08-05'), 'August 5, 2026');
  assert.equal(formatSearchDate('2026-01-01'), 'January 1, 2026');
});

test('groupJobsByDate: groups by UTC calendar date, preserves order', () => {
  const jobs = [
    { filename: 'a', creationDate: '2026-08-05T03:08:21Z' },
    { filename: 'b', creationDate: '2026-08-06T17:32:31Z' },
    { filename: 'c', creationDate: '2026-08-05T23:00:00Z' },
  ];
  const groups = groupJobsByDate(jobs);
  assert.deepEqual([...groups.keys()], ['2026-08-05', '2026-08-06']);
  assert.equal(groups.get('2026-08-05').length, 2);
  assert.deepEqual(groups.get('2026-08-05').map((j) => j.filename), ['a', 'c']);
  assert.equal(groups.get('2026-08-06').length, 1);
});

test('isRealPhotoTile: matches Photo/Video tiles, rejects decoy chips', () => {
  assert.equal(isRealPhotoTile('Photo - Portrait - Aug 5, 2026, 6:54:07 PM'), true);
  assert.equal(isRealPhotoTile('Video - Portrait - Aug 5, 2026, 7:31:07 PM'), true);
  assert.equal(isRealPhotoTile('Favorites'), false);
  assert.equal(isRealPhotoTile(null), false);
  assert.equal(isRealPhotoTile(undefined), false);
});

test('dedupeTilesByAriaLabel: drops repeats of the same photo rendered at another size', () => {
  const tiles = [
    { ariaLabel: 'Photo - Portrait - Aug 5, 2026, 6:54:07 PM' },
    { ariaLabel: 'Favorites' },
    { ariaLabel: 'Photo - Portrait - Aug 5, 2026, 6:54:07 PM' },
    { ariaLabel: 'Photo - Landscape - Aug 5, 2026, 7:31:07 PM' },
  ];
  const deduped = dedupeTilesByAriaLabel(tiles);
  assert.equal(deduped.length, 3);
});
