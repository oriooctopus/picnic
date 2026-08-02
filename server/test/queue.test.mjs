import { test } from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { JobQueue, jobKey } from '../lib/queue.mjs';

function withTempQueue(fn) {
  const dir = mkdtempSync(join(tmpdir(), 'picnic-queue-test-'));
  const queue = new JobQueue(join(dir, 'queue.jsonl'));
  try {
    return fn(queue);
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
}

test('enqueue creates a queued job', () => {
  withTempQueue((queue) => {
    const { job, created } = queue.enqueue({
      filename: 'IMG_0001.HEIC',
      creationDate: '2026-06-15T14:30:00.000Z',
      pixelWidth: 100,
      pixelHeight: 200,
    });
    assert.equal(created, true);
    assert.equal(job.status, 'queued');
    assert.equal(job.attempts, 0);
  });
});

test('enqueue is idempotent on filename+creationDate', () => {
  withTempQueue((queue) => {
    const first = queue.enqueue({
      filename: 'IMG_0001.HEIC',
      creationDate: '2026-06-15T14:30:00.000Z',
      pixelWidth: 100,
      pixelHeight: 200,
    });
    const second = queue.enqueue({
      filename: 'IMG_0001.HEIC',
      creationDate: '2026-06-15T14:30:00.000Z',
      pixelWidth: 100,
      pixelHeight: 200,
    });
    assert.equal(first.job.id, second.job.id);
    assert.equal(second.created, false);
    assert.equal(queue.loadAll().length, 1);
  });
});

test('different filename or creationDate produces a different job', () => {
  withTempQueue((queue) => {
    queue.enqueue({ filename: 'A.HEIC', creationDate: '2026-06-15T14:30:00.000Z', pixelWidth: 1, pixelHeight: 1 });
    queue.enqueue({ filename: 'B.HEIC', creationDate: '2026-06-15T14:30:00.000Z', pixelWidth: 1, pixelHeight: 1 });
    queue.enqueue({ filename: 'A.HEIC', creationDate: '2026-06-16T14:30:00.000Z', pixelWidth: 1, pixelHeight: 1 });
    assert.equal(queue.loadAll().length, 3);
  });
});

test('jobKey is deterministic', () => {
  const a = jobKey('IMG_0001.HEIC', '2026-06-15T14:30:00.000Z');
  const b = jobKey('IMG_0001.HEIC', '2026-06-15T14:30:00.000Z');
  const c = jobKey('IMG_0002.HEIC', '2026-06-15T14:30:00.000Z');
  assert.equal(a, b);
  assert.notEqual(a, c);
});

test('update appends a new snapshot, loadAll returns latest state', () => {
  withTempQueue((queue) => {
    const { job } = queue.enqueue({
      filename: 'IMG_0001.HEIC',
      creationDate: '2026-06-15T14:30:00.000Z',
      pixelWidth: 100,
      pixelHeight: 200,
    });
    queue.update(job.id, { status: 'trashed' });
    const all = queue.loadAll();
    assert.equal(all.length, 1);
    assert.equal(all[0].status, 'trashed');
  });
});

test('status transitions: queued -> needs_review -> queued (retry) -> trashed', () => {
  withTempQueue((queue) => {
    const { job } = queue.enqueue({
      filename: 'IMG_0001.HEIC',
      creationDate: '2026-06-15T14:30:00.000Z',
      pixelWidth: 100,
      pixelHeight: 200,
    });
    queue.update(job.id, { status: 'needs_review', comparison: { decision: 'ambiguous' } });
    assert.equal(queue.getById(job.id).status, 'needs_review');

    queue.update(job.id, { status: 'queued', error: null });
    assert.equal(queue.getById(job.id).status, 'queued');

    queue.update(job.id, { status: 'trashed' });
    assert.equal(queue.getById(job.id).status, 'trashed');
  });
});

test('counts tallies by status', () => {
  withTempQueue((queue) => {
    const j1 = queue.enqueue({ filename: 'A', creationDate: '2026-01-01T00:00:00Z', pixelWidth: 1, pixelHeight: 1 }).job;
    const j2 = queue.enqueue({ filename: 'B', creationDate: '2026-01-01T00:00:00Z', pixelWidth: 1, pixelHeight: 1 }).job;
    queue.enqueue({ filename: 'C', creationDate: '2026-01-01T00:00:00Z', pixelWidth: 1, pixelHeight: 1 });
    queue.update(j1.id, { status: 'trashed' });
    queue.update(j2.id, { status: 'error', error: 'boom' });
    const counts = queue.counts();
    assert.equal(counts.trashed, 1);
    assert.equal(counts.error, 1);
    assert.equal(counts.queued, 1);
  });
});

test('update throws for unknown job id', () => {
  withTempQueue((queue) => {
    assert.throws(() => queue.update('nonexistent', { status: 'trashed' }));
  });
});
