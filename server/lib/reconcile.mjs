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
}
