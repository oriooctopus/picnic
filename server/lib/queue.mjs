import { createHash } from 'node:crypto';
import { readFileSync, appendFileSync, existsSync, mkdirSync, writeFileSync } from 'node:fs';
import { dirname } from 'node:path';

// not_in_google: a human verified the photo is absent from the Google Photos
// library (already in Trash, or deleted on the phone before it ever uploaded),
// so there is nothing left to mirror. Set only via POST /close/:id.
export const STATUSES = ['queued', 'trashed', 'needs_review', 'error', 'not_in_google'];

/**
 * Deterministic job id from the idempotency key (filename + creationDate).
 * Same (filename, creationDate) pair always yields the same id, which is
 * what makes POST /queue idempotent.
 */
export function jobKey(filename, creationDate) {
  return createHash('sha256').update(`${filename}|${creationDate}`).digest('hex').slice(0, 24);
}

/** Deterministic job id for a replace job, from the app-side job's UUID. */
export function replaceJobId(clientId) {
  return createHash('sha256').update(`replace|${clientId}`).digest('hex').slice(0, 24);
}

export const isReplaceJob = (job) => job.kind === 'replace';

/**
 * Append-only JSONL job store. Each line is a full job snapshot; the latest
 * line for a given id is that job's current state. Nothing is ever mutated
 * in place — updates are appended as new lines with the same id.
 */
export class JobQueue {
  constructor(filePath) {
    this.filePath = filePath;
    const dir = dirname(filePath);
    if (!existsSync(dir)) mkdirSync(dir, { recursive: true });
    if (!existsSync(filePath)) writeFileSync(filePath, '');
  }

  /** Load all jobs, folded down to latest-state-per-id, in first-seen order. */
  loadAll() {
    const raw = readFileSync(this.filePath, 'utf8');
    const order = [];
    const byId = new Map();
    for (const line of raw.split('\n')) {
      const trimmed = line.trim();
      if (!trimmed) continue;
      const job = JSON.parse(trimmed);
      if (!byId.has(job.id)) order.push(job.id);
      byId.set(job.id, job);
    }
    return order.map((id) => byId.get(id));
  }

  getById(id) {
    return this.loadAll().find((j) => j.id === id) ?? null;
  }

  /** Append a job snapshot (create or update) as a new line. */
  append(job) {
    appendFileSync(this.filePath, JSON.stringify(job) + '\n');
    return job;
  }

  /**
   * Idempotent enqueue: if a job with this filename+creationDate key already
   * exists, return it unchanged (no duplicate). Otherwise append a new
   * queued job.
   */
  enqueue({ filename, creationDate, pixelWidth, pixelHeight, mediaType, isLivePhoto }) {
    const id = jobKey(filename, creationDate);
    const existing = this.getById(id);
    if (existing) return { job: existing, created: false };
    const now = new Date().toISOString();
    const job = {
      id,
      filename,
      creationDate,
      pixelWidth,
      pixelHeight,
      mediaType: mediaType ?? null,
      isLivePhoto: !!isLivePhoto,
      status: 'queued',
      attempts: 0,
      comparison: null,
      error: null,
      createdAt: now,
      updatedAt: now,
    };
    this.append(job);
    return { job, created: true };
  }

  /**
   * Idempotent enqueue of a trim-replace job (kind 'replace'): the app trimmed
   * a video and uploaded the trimmed file, which the worker must put into
   * Google Photos before trashing the stale full-length original. `id` is
   * replaceJobId(clientId), so a re-sent upload of the same app-side job
   * returns the existing job. The file itself lives on disk (replace.file),
   * never inline in queue.jsonl.
   */
  enqueueReplace({ clientId, filename, creationDate, pixelWidth, pixelHeight, file, bytes, durationSec }) {
    const id = replaceJobId(clientId);
    const existing = this.getById(id);
    if (existing) return { job: existing, created: false };
    const now = new Date().toISOString();
    const job = {
      id,
      kind: 'replace',
      filename,
      creationDate,
      pixelWidth,
      pixelHeight,
      mediaType: 'video',
      isLivePhoto: false,
      status: 'queued',
      attempts: 0,
      comparison: null,
      error: null,
      replace: { file, bytes, durationSec, phase: 'received', uploadName: null, newItem: null },
      createdAt: now,
      updatedAt: now,
    };
    this.append(job);
    return { job, created: true };
  }

  /** Append an updated snapshot of an existing job (status transition etc). */
  update(id, patch) {
    const existing = this.getById(id);
    if (!existing) throw new Error(`no job with id ${id}`);
    const next = { ...existing, ...patch, id, updatedAt: new Date().toISOString() };
    this.append(next);
    return next;
  }

  /** Per-status counts; `kind` ('replace' | 'delete') restricts to that job kind (missing kind = delete). */
  counts(kind) {
    const jobs = this.loadAll().filter((j) => !kind || (j.kind === 'replace' ? 'replace' : 'delete') === kind);
    const counts = Object.fromEntries(STATUSES.map((s) => [s, 0]));
    for (const j of jobs) counts[j.status] = (counts[j.status] ?? 0) + 1;
    return counts;
  }
}
