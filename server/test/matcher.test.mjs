import { test } from 'node:test';
import assert from 'node:assert/strict';
import { decideMatch, timestampsAgree } from '../lib/matcher.mjs';

const baseJob = {
  filename: 'IMG_1234.HEIC',
  creationDate: '2026-06-15T14:30:00.000Z',
  pixelWidth: 4032,
  pixelHeight: 3024,
};

test('matches when filename, timestamp, and dimensions all agree exactly', () => {
  const candidates = [
    { filename: 'IMG_1234.HEIC', captureDateTime: '2026-06-15T14:30:00.000Z', pixelWidth: 4032, pixelHeight: 3024 },
  ];
  const result = decideMatch(baseJob, candidates);
  assert.equal(result.decision, 'match');
  assert.equal(result.matchedCandidate, candidates[0]);
});

test('matches despite whole-hour timezone skew within tolerance', () => {
  // Candidate displayed 1 hour later (e.g. phone local vs Google display tz).
  const candidates = [
    { filename: 'IMG_1234.HEIC', captureDateTime: '2026-06-15T15:30:00.000Z', pixelWidth: 4032, pixelHeight: 3024 },
  ];
  const result = decideMatch(baseJob, candidates);
  assert.equal(result.decision, 'match');
});

test('matches despite multi-hour timezone skew (e.g. 9 hour offset)', () => {
  const candidates = [
    { filename: 'IMG_1234.HEIC', captureDateTime: '2026-06-15T23:30:00.000Z', pixelWidth: 4032, pixelHeight: 3024 },
  ];
  const result = decideMatch(baseJob, candidates);
  assert.equal(result.decision, 'match');
});

test('ambiguous when timestamp is off by a non-hour amount beyond tolerance', () => {
  const candidates = [
    { filename: 'IMG_1234.HEIC', captureDateTime: '2026-06-15T14:47:00.000Z', pixelWidth: 4032, pixelHeight: 3024 },
  ];
  const result = decideMatch(baseJob, candidates);
  assert.equal(result.decision, 'ambiguous');
});

test('ambiguous when filename disagrees', () => {
  const candidates = [
    { filename: 'IMG_9999.HEIC', captureDateTime: '2026-06-15T14:30:00.000Z', pixelWidth: 4032, pixelHeight: 3024 },
  ];
  const result = decideMatch(baseJob, candidates);
  assert.equal(result.decision, 'ambiguous');
});

test('ambiguous when dimensions disagree', () => {
  const candidates = [
    { filename: 'IMG_1234.HEIC', captureDateTime: '2026-06-15T14:30:00.000Z', pixelWidth: 1024, pixelHeight: 768 },
  ];
  const result = decideMatch(baseJob, candidates);
  assert.equal(result.decision, 'ambiguous');
});

test('ambiguous with zero candidates', () => {
  const result = decideMatch(baseJob, []);
  assert.equal(result.decision, 'ambiguous');
  assert.equal(result.matchedCandidate, null);
});

test('ambiguous when more than one candidate agrees on all fields', () => {
  const candidates = [
    { filename: 'IMG_1234.HEIC', captureDateTime: '2026-06-15T14:30:00.000Z', pixelWidth: 4032, pixelHeight: 3024 },
    { filename: 'IMG_1234.HEIC', captureDateTime: '2026-06-15T14:31:00.000Z', pixelWidth: 4032, pixelHeight: 3024 },
  ];
  const result = decideMatch(baseJob, candidates);
  assert.equal(result.decision, 'ambiguous');
});

test('filename comparison is case-insensitive', () => {
  const candidates = [
    { filename: 'img_1234.heic', captureDateTime: '2026-06-15T14:30:00.000Z', pixelWidth: 4032, pixelHeight: 3024 },
  ];
  const result = decideMatch(baseJob, candidates);
  assert.equal(result.decision, 'match');
});

test('comparisons array records what was compared, for auditability', () => {
  const candidates = [
    { filename: 'IMG_1234.HEIC', captureDateTime: '2026-06-15T14:47:00.000Z', pixelWidth: 4032, pixelHeight: 3024 },
  ];
  const result = decideMatch(baseJob, candidates);
  assert.equal(result.comparisons.length, 1);
  assert.equal(result.comparisons[0].filenameMatch, true);
  assert.equal(result.comparisons[0].timestampMatch, false);
  assert.ok(typeof result.comparisons[0].timestampDiffMinutes === 'number');
});

test('timestampsAgree: within tolerance directly', () => {
  const { agree } = timestampsAgree('2026-06-15T14:30:00.000Z', '2026-06-15T14:33:00.000Z', 5);
  assert.equal(agree, true);
});

test('timestampsAgree: outside tolerance and not an hour-multiple', () => {
  const { agree } = timestampsAgree('2026-06-15T14:30:00.000Z', '2026-06-15T14:50:00.000Z', 5);
  assert.equal(agree, false);
});
