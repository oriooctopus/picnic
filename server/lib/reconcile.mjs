/**
 * "Clean up Google" reconcile logic: decide which Google Photos library items
 * are NOT already on the phone (candidates to review for trash), and store
 * per-month reconcile state on disk.
 *
 * The phone POSTs a manifest of every PHAsset it has for one month. A worker
 * (later brief) scans that month in Google Photos read-only and produces a
 * list of googlePhotos. The pure diff here compares the two and returns the
 * photos that exist ONLY in Google. Only user-confirmed candidates ever get
 * moved to Google trash -- this module never trashes anything itself.
 */

import {
  appendFileSync,
  mkdirSync,
  writeFileSync,
  readFileSync,
  existsSync,
  rmSync,
} from 'node:fs';
import { homedir } from 'node:os';
import { join } from 'node:path';
import { filenamesAgree } from './matcher.mjs';

// Local reimplementations of matcher.mjs's module-private helpers
// (stripOriginalSuffix / baseNameNoExtension / extensionOf). Kept local rather
// than exporting the originals to avoid churn in that file -- they're 3 lines
// each and only this file's diff needs them.

/** Strip exactly the known "_Original" re-import suffix (see matcher.mjs's stripOriginalSuffix for the live evidence). */
function stripOriginalSuffix(name) {
  return name.replace(/_original(?=\.[^.]+$)/i, '');
}

/** `stripOriginalSuffix` plus the extension itself, lowercased. */
function baseNameNoExtension(name) {
  return stripOriginalSuffix(name).replace(/\.[^.]+$/, '').toLowerCase();
}

/** The bare extension (no leading dot), lowercased; '' if there isn't one. */
function extensionOf(name) {
  const m = /\.([^.]+)$/.exec(name);
  return m ? m[1].toLowerCase() : '';
}

/** Video extensions that can surface as a Live Photo's video half on Google. */
const VIDEO_EXTENSIONS = new Set(['mov', 'mp4', 'm4v']);

/**
 * Route a camera model to a reconcile section. Only a non-null model whose
 * text STARTS with "Apple iPhone" counts as an iPhone photo; everything else
 * -- a missing model (no EXIF camera field at all), WhatsApp saves, shared
 * items, other cameras, iPads -- is "other".
 */
export function sectionForCameraModel(cameraModel) {
  return cameraModel != null && /^Apple\s+iPhone\b/i.test(cameraModel) ? 'iphone' : 'other';
}

/**
 * Is this google photo already on the phone (per the manifest)? Identity is
 * decided by FILENAME ONLY, never by date -- the capture date is a
 * ±1-day-search concern handled upstream in the scan, not by this diff, so a
 * date-shifted copy of the same filename is still the same photo. Two
 * agreement paths:
 *
 *   1. filenamesAgree() -- exact name match, stripping the "_Original"
 *      re-import suffix and lowercasing (see matcher.mjs's filenamesAgree).
 *   2. Live Photo video half -- a google photo whose filename is a VIDEO
 *      (.mov/.mp4/.m4v) and whose base name (extension-stripped,
 *      _Original-stripped, lowercased) matches a manifest entry that is
 *      NON-video. WHY: a Live Photo is ONE PHAsset on the phone (its image
 *      filename is what lands in the manifest), but Google Photos can surface
 *      the video half as a separate tile; that video half is content already
 *      on the phone, so it must not become a false "only in Google" candidate.
 *      This is narrow on purpose -- video google + non-video manifest basename
 *      match ONLY, no other fuzzy matching.
 */
function isOnPhone(google, manifestAssets) {
  for (const manifest of manifestAssets) {
    if (filenamesAgree(google.filename, manifest.filename)) return true;
    if (
      VIDEO_EXTENSIONS.has(extensionOf(google.filename)) &&
      !VIDEO_EXTENSIONS.has(extensionOf(manifest.filename)) &&
      baseNameNoExtension(google.filename) === baseNameNoExtension(manifest.filename)
    ) {
      return true;
    }
  }
  return false;
}

/**
 * Pure diff: split googlePhotos into the photos NOT on the phone (candidates)
 * and partition those candidates by camera-model section.
 *
 * manifestAssets: [{ filename, creationDate, pixelWidth, pixelHeight }] from
 *   the phone.
 * googlePhotos: [{ photoId, filename, cameraModel, captureDateMs, pixelWidth,
 *   pixelHeight }] from the Google scan; cameraModel comes from
 *   matcher.mjs's parseCameraModel and may be null.
 *
 * Returns { candidates, bySection: { iphone: [], other: [] } } -- `candidates`
 * is the full list in input order, and `bySection.iphone` / `bySection.other`
 * are the same objects partitioned by section (references, not copies).
 */
export function diffGoogleVsManifest(manifestAssets, googlePhotos) {
  const candidates = [];
  const bySection = { iphone: [], other: [] };
  for (const google of googlePhotos) {
    if (isOnPhone(google, manifestAssets)) continue;
    candidates.push(google);
    bySection[sectionForCameraModel(google.cameraModel)].push(google);
  }
  return { candidates, bySection };
}

/** Two capture times agree when within this many ms (manifest dates are whole seconds; Google's are ms). */
export const CAPTURE_TOLERANCE_MS = 2000;

/** Do two width/height pairs describe the same picture (either orientation)? Nulls never agree. */
export function dimensionsAgree(aW, aH, bW, bH) {
  if ([aW, aH, bW, bH].some((v) => typeof v !== 'number')) return false;
  return (aW === bW && aH === bH) || (aW === bH && aH === bW);
}

/**
 * Pure diff for the passive-listing scan: items from Google's listing
 * responses ({mediaKey, thumbUrl, height, width, captureMs, ...}) that have NO
 * manifest entry with the same capture time (within CAPTURE_TOLERANCE_MS) and
 * the same dimensions (either order). Duplicate mediaKeys are reported once.
 * Returns candidate records in the store's shape, filename/cameraModel null
 * (the listing does not carry them).
 */
export function diffListingVsManifest(manifestAssets, items, toleranceMs = CAPTURE_TOLERANCE_MS) {
  const manifest = manifestAssets.map((a) => ({
    ms: Date.parse(a.creationDate),
    w: a.pixelWidth,
    h: a.pixelHeight,
  }));
  const seen = new Set();
  const candidates = [];
  for (const item of items) {
    if (seen.has(item.mediaKey)) continue;
    seen.add(item.mediaKey);
    const onPhone = manifest.some(
      (m) => Math.abs(m.ms - item.captureMs) <= toleranceMs && dimensionsAgree(m.w, m.h, item.width, item.height)
    );
    if (onPhone) continue;
    candidates.push({
      photoId: item.mediaKey,
      filename: null,
      cameraModel: null,
      captureDateMs: item.captureMs,
      pixelWidth: item.width,
      pixelHeight: item.height,
      thumbUrl: item.thumbUrl,
    });
  }
  return candidates;
}

const DEFAULT_BASE_DIR = join(homedir(), '.local', 'share', 'picnic', 'reconcile');

/**
 * Append-only per-month reconcile store, mirroring lib/queue.mjs's JobQueue
 * idiom: every mutation is a full snapshot appended as a new JSONL line, and
 * reads fold down to the LATEST line per key (here, the Google photoId).
 * Nothing is ever rewritten in place.
 *
 * On disk: <baseDir>/<month>/manifest.json, <baseDir>/<month>/candidates.jsonl,
 * <baseDir>/<month>/thumbs/<photoId>.jpg. `month` is the "YYYY-MM" string.
 */
// Bump when the scan method changes so stale "ready" results are rescanned.
export const SCAN_VERSION = 2;

export class ReconcileStore {
  constructor(baseDir = DEFAULT_BASE_DIR) {
    this.baseDir = baseDir;
    mkdirSync(baseDir, { recursive: true });
  }

  monthDir(month) {
    return join(this.baseDir, month);
  }

  manifestPath(month) {
    return join(this.monthDir(month), 'manifest.json');
  }

  statusPath(month) {
    return join(this.monthDir(month), 'status.json');
  }

  /** Where a failed scan/trash run's error message is stored (see saveError). */
  errorPath(month) {
    return join(this.monthDir(month), 'error.json');
  }

  candidatesPath(month) {
    return join(this.monthDir(month), 'candidates.jsonl');
  }

  thumbsDir(month) {
    return join(this.monthDir(month), 'thumbs');
  }

  /** Path where a candidate's thumbnail lives (does NOT create it). */
  thumbPath(month, photoId) {
    return join(this.thumbsDir(month), `${photoId}.jpg`);
  }

  saveManifest(month, assets) {
    mkdirSync(this.monthDir(month), { recursive: true });
    writeFileSync(this.manifestPath(month), JSON.stringify(assets));
  }

  /** null when no manifest has been saved for this month yet. */
  loadManifest(month) {
    const p = this.manifestPath(month);
    if (!existsSync(p)) return null;
    return JSON.parse(readFileSync(p, 'utf8'));
  }

  /**
   * Persist the month's reconcile phase. Statuses are the finite lifecycle
   * 'scanning' | 'ready' | 'confirming' | 'done'; the worker writes 'ready'
   * after its read-only scan finishes and 'done' after its trash pass, the
   * server writes 'scanning' on manifest receipt and 'confirming' on user
   * confirmation. Plain overwrite (not the candidates.jsonl append idiom) --
   * a month's phase is a single latest value, never a folded history.
   */
  saveStatus(month, status) {
    mkdirSync(this.monthDir(month), { recursive: true });
    writeFileSync(this.statusPath(month), JSON.stringify(status));
  }

  /**
   * Stamp a finished scan with SCAN_VERSION. A "ready" result from an older scan
   * method (per-photo filename reads) must not be reused for an unchanged
   * manifest, so the server only reuses results carrying the current stamp.
   */
  saveScanVersion(month) {
    mkdirSync(this.monthDir(month), { recursive: true });
    writeFileSync(join(this.monthDir(month), 'scan-version'), String(SCAN_VERSION));
  }

  hasCurrentScan(month) {
    const p = join(this.monthDir(month), 'scan-version');
    return existsSync(p) && readFileSync(p, 'utf8') === String(SCAN_VERSION);
  }

  /** null when no status has been written for this month yet. */
  loadStatus(month) {
    const p = this.statusPath(month);
    if (!existsSync(p)) return null;
    return JSON.parse(readFileSync(p, 'utf8'));
  }

  /**
   * Append a candidate snapshot. Idempotent by photoId in the READ: re-appending
   * the same photoId appends a new line, but listCandidates folds to the latest
   * line per photoId, so the visible list never holds duplicates (same contract
   * as JobQueue's append + loadAll).
   */
  appendCandidate(month, candidate) {
    mkdirSync(this.monthDir(month), { recursive: true });
    appendFileSync(this.candidatesPath(month), JSON.stringify(candidate) + '\n');
    return candidate;
  }

  /** Fold the JSONL down to latest-record-per-photoId, in first-seen order. */
  listCandidates(month) {
    const p = this.candidatesPath(month);
    if (!existsSync(p)) return [];
    const raw = readFileSync(p, 'utf8');
    const order = [];
    const byId = new Map();
    for (const line of raw.split('\n')) {
      const trimmed = line.trim();
      if (!trimmed) continue;
      const candidate = JSON.parse(trimmed);
      if (!byId.has(candidate.photoId)) order.push(candidate.photoId);
      byId.set(candidate.photoId, candidate);
    }
    return order.map((id) => byId.get(id));
  }

  /** Append an updated snapshot of an existing candidate (status transition). */
  updateCandidateStatus(month, photoId, status) {
    const existing = this.listCandidates(month).find((c) => c.photoId === photoId);
    if (!existing) throw new Error(`no candidate with photoId ${photoId}`);
    const next = { ...existing, status };
    appendFileSync(this.candidatesPath(month), JSON.stringify(next) + '\n');
    return next;
  }

  /** Mark the given photoIds as queued for Google trash. */
  confirm(month, ids) {
    for (const photoId of ids) this.updateCandidateStatus(month, photoId, 'queued');
    return this.listCandidates(month);
  }

  /** Write a candidate thumbnail and return its path. */
  saveThumb(month, photoId, buffer) {
    mkdirSync(this.thumbsDir(month), { recursive: true });
    writeFileSync(this.thumbPath(month, photoId), buffer);
    return this.thumbPath(month, photoId);
  }

  /**
   * Record a scan/trash run's failure so GET /reconcile/:month can surface
   * WHY the month is stuck, instead of the phone silently polling a status
   * that never leaves "scanning" (the March 2026 bug report: a worker crash
   * with stdio:'ignore' vanished without a trace). Plain overwrite, like
   * saveStatus -- only the latest run's error matters.
   */
  saveError(month, message) {
    mkdirSync(this.monthDir(month), { recursive: true });
    writeFileSync(this.errorPath(month), JSON.stringify({ message }));
  }

  /** null when the month has no recorded error (never failed, or was reset by a rescan). */
  loadError(month) {
    const p = this.errorPath(month);
    if (!existsSync(p)) return null;
    return JSON.parse(readFileSync(p, 'utf8')).message;
  }

  /**
   * Clear a month's candidates/thumbs/error before a rescan. Without this, a
   * re-POSTed manifest (user retries after a failure, or just re-runs the
   * month) would append its new candidates on top of the OLD candidates.jsonl
   * -- listCandidates folds by photoId, but a Google photo the new scan no
   * longer sees (deleted, or the old diff was simply wrong) would never be
   * pruned, so stale "only in Google" rows accumulate forever. Does NOT touch
   * status.json/manifest.json -- the caller overwrites those right after.
   */
  resetForRescan(month) {
    rmSync(this.candidatesPath(month), { force: true });
    rmSync(this.thumbsDir(month), { recursive: true, force: true });
    rmSync(this.errorPath(month), { force: true });
  }
}
