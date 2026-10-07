/**
 * Remote album triage storage: one directory per Google Photos shared album,
 *   <root>/<albumId>/items.json      [{mediaKey, thumbUrl, width, height, captureMs}]
 *   <root>/<albumId>/decisions.json  {mediaKey: 'keep'|'skip'}
 *   <root>/<albumId>/thumbs/<mediaKey>.jpg
 *   <root>/<albumId>/full/<mediaKey>.<ext>
 *   <root>/<albumId>/video/<mediaKey>.mp4   (playable rendition of kind=video items)
 *   <root>/<albumId>/trims.json      {mediaKey: {startSec, endSec}}  (kept-video cut range, applied at download)
 * albumId and mediaKey are untrusted URL/body text; both are validated against
 * ID_RE before they ever reach a path join.
 */
import { mkdirSync, readFileSync, writeFileSync, existsSync, readdirSync } from 'node:fs';
import { homedir } from 'node:os';
import { join } from 'node:path';
import { mergeItems } from './listing.mjs';

export const ID_RE = /^[A-Za-z0-9_-]+$/;
export const KINDS = new Set(['photo', 'video']);
export const DECISIONS = new Set(['keep', 'skip']);
/** Shortest kept clip. Matches the app's VideoTrimBar minimum length (0.5s) loosely; this is only a sanity floor. */
export const MIN_TRIM_SEC = 0.1;
/** Slack past the probed duration: the app reads duration from AVPlayer, ffprobe from the container; they differ by a frame or two. */
export const TRIM_DURATION_SLACK_SEC = 0.5;
export const defaultAlbumsDir = () =>
  process.env.PICNIC_ALBUMS_DIR || join(homedir(), '.local', 'share', 'picnic', 'albums');

export function assertId(kind, value) {
  if (typeof value !== 'string' || !ID_RE.test(value)) throw new Error(`invalid ${kind}: ${JSON.stringify(value)}`);
  return value;
}

/** Listing item array [mediaKey,[thumbUrl,w,h],captureMs,...] (or an already-shaped object) -> stored item. */
export function normalizeItem(raw) {
  let item;
  if (Array.isArray(raw)) {
    item = { mediaKey: raw[0], thumbUrl: raw[1]?.[0], width: raw[1]?.[1], height: raw[1]?.[2], captureMs: raw[2] };
  } else if (raw && typeof raw === 'object') {
    item = { mediaKey: raw.mediaKey, thumbUrl: raw.thumbUrl, width: raw.width, height: raw.height, captureMs: raw.captureMs };
  } else {
    throw new Error('item must be an array or object');
  }
  assertId('mediaKey', item.mediaKey);
  if (typeof item.thumbUrl !== 'string' || !item.thumbUrl.startsWith('http')) {
    throw new Error(`item ${item.mediaKey}: thumbUrl must be an http URL`);
  }
  return item;
}

export class AlbumStore {
  constructor(root, albumId) {
    this.albumId = assertId('albumId', albumId);
    this.dir = join(root, albumId);
    mkdirSync(join(this.dir, 'thumbs'), { recursive: true });
    mkdirSync(join(this.dir, 'full'), { recursive: true });
    mkdirSync(join(this.dir, 'video'), { recursive: true });
  }

  #read(name, fallback) {
    const p = join(this.dir, name);
    return existsSync(p) ? JSON.parse(readFileSync(p, 'utf8')) : fallback;
  }

  loadItems() {
    return this.#read('items.json', []);
  }

  loadDecisions() {
    return this.#read('decisions.json', {});
  }

  /** Idempotent merge by mediaKey (first sighting wins). Returns {added, total}. */
  ingestItems(rawItems) {
    const items = rawItems.map(normalizeItem);
    const byKey = new Map(this.loadItems().map((i) => [i.mediaKey, i]));
    const added = mergeItems(byKey, items);
    writeFileSync(join(this.dir, 'items.json'), JSON.stringify([...byKey.values()]));
    return { added, total: byKey.size };
  }

  /**
   * Merge {mediaKey: kind} into items.json. Kinds must be photo|video and every
   * key must already be in the album; anything else throws and writes nothing.
   */
  mergeKinds(kinds) {
    const items = this.loadItems();
    const known = new Set(items.map((i) => i.mediaKey));
    for (const [key, kind] of Object.entries(kinds)) {
      if (!KINDS.has(kind)) throw new Error(`invalid kind for ${key}: ${JSON.stringify(kind)}`);
      if (!known.has(key)) throw new Error(`unknown mediaKey: ${key}`);
    }
    for (const i of items) if (i.mediaKey in kinds) i.kind = kinds[i.mediaKey];
    writeFileSync(join(this.dir, 'items.json'), JSON.stringify(items));
    return { merged: Object.keys(kinds).length, videos: items.filter((i) => i.kind === 'video').length };
  }

  videoPath(mediaKey) {
    return join(this.dir, 'video', `${assertId('mediaKey', mediaKey)}.mp4`);
  }

  hasVideo(mediaKey) {
    return existsSync(this.videoPath(mediaKey));
  }

  writeVideo(mediaKey, buf) {
    writeFileSync(this.videoPath(mediaKey), buf);
  }

  loadTrims() {
    return this.#read('trims.json', {});
  }

  /**
   * Stores the kept range of a video. Throws (route -> 400) unless mediaKey is a
   * known kind=video item and 0 <= startSec, startSec + MIN_TRIM_SEC <= endSec,
   * both finite numbers. When `durationSec` is given (route passes the ffprobe
   * duration of the cached mp4) endSec may not exceed it by more than the slack.
   * Last write wins; the range is applied only at download time.
   */
  setTrim(mediaKey, startSec, endSec, durationSec) {
    assertId('mediaKey', mediaKey);
    const item = this.loadItems().find((i) => i.mediaKey === mediaKey);
    if (!item) throw new Error(`unknown mediaKey: ${mediaKey}`);
    if (item.kind !== 'video') throw new Error(`not a video: ${mediaKey}`);
    for (const [name, v] of [['startSec', startSec], ['endSec', endSec]]) {
      if (typeof v !== 'number' || !Number.isFinite(v)) throw new Error(`${name} must be a finite number`);
    }
    if (startSec < 0) throw new Error('startSec must be >= 0');
    if (endSec - startSec < MIN_TRIM_SEC) throw new Error(`trim must be at least ${MIN_TRIM_SEC}s long`);
    if (durationSec !== undefined && endSec > durationSec + TRIM_DURATION_SLACK_SEC) {
      throw new Error(`endSec ${endSec} is past the video duration ${durationSec}`);
    }
    const trims = this.loadTrims();
    trims[mediaKey] = { startSec, endSec };
    writeFileSync(join(this.dir, 'trims.json'), JSON.stringify(trims));
    return trims[mediaKey];
  }

  setDecision(mediaKey, decision) {
    assertId('mediaKey', mediaKey);
    if (!DECISIONS.has(decision)) throw new Error(`invalid decision: ${JSON.stringify(decision)}`);
    if (!this.loadItems().some((i) => i.mediaKey === mediaKey)) throw new Error(`unknown mediaKey: ${mediaKey}`);
    const decisions = this.loadDecisions();
    decisions[mediaKey] = decision;
    writeFileSync(join(this.dir, 'decisions.json'), JSON.stringify(decisions));
  }

  thumbPath(mediaKey) {
    return join(this.dir, 'thumbs', `${assertId('mediaKey', mediaKey)}.jpg`);
  }

  hasThumb(mediaKey) {
    return existsSync(this.thumbPath(mediaKey));
  }

  writeThumb(mediaKey, buf) {
    writeFileSync(this.thumbPath(mediaKey), buf);
  }

  /** Path of the downloaded full-res file for mediaKey, or null. */
  fullPath(mediaKey) {
    assertId('mediaKey', mediaKey);
    const prefix = `${mediaKey}.`;
    const name = readdirSync(join(this.dir, 'full')).find((n) => n.startsWith(prefix));
    return name ? join(this.dir, 'full', name) : null;
  }

  writeFull(mediaKey, ext, buf) {
    assertId('mediaKey', mediaKey);
    assertId('ext', ext);
    writeFileSync(join(this.dir, 'full', `${mediaKey}.${ext}`), buf);
  }

  listItems() {
    const decisions = this.loadDecisions();
    const trims = this.loadTrims();
    return this.loadItems().map((i) => ({
      ...i,
      kind: i.kind ?? 'photo',
      trim: trims[i.mediaKey] ?? null,
      hasVideo: i.kind === 'video' && this.hasVideo(i.mediaKey),
      decision: decisions[i.mediaKey] ?? null,
      hasThumb: this.hasThumb(i.mediaKey),
      downloaded: this.fullPath(i.mediaKey) !== null,
    }));
  }

  counts() {
    const items = this.listItems();
    const keep = items.filter((i) => i.decision === 'keep').length;
    const skip = items.filter((i) => i.decision === 'skip').length;
    return {
      total: items.length,
      keep,
      skip,
      undecided: items.length - keep - skip,
      downloaded: items.filter((i) => i.downloaded).length,
    };
  }
}
