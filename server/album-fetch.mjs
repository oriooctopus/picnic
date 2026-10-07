#!/usr/bin/env node
/**
 * Album triage fetcher.
 *   node album-fetch.mjs thumbs <albumId>    fetch <thumbUrl>=w512-h512 for each item
 *   node album-fetch.mjs videos <albumId>    fetch a playable mp4 (=m37, else =m18) for each kind=video item
 *   node album-fetch.mjs kinds <albumId> <kinds.json>  merge {mediaKey: Photo|Video|Animation} into items.json
 *   node album-fetch.mjs download <albumId>  fetch <thumbUrl>=d for each KEPT item
 * Paced at 1 request / 300ms; idempotent (files already on disk are skipped).
 */
import { AlbumStore, defaultAlbumsDir } from './lib/album.mjs';

const PACE_MS = 300;
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

const EXT_BY_TYPE = {
  'image/jpeg': 'jpg', 'image/png': 'png', 'image/webp': 'webp', 'image/heic': 'heic', 'image/heif': 'heif',
  'image/gif': 'gif', 'video/mp4': 'mp4', 'video/quicktime': 'mov',
};

/** Google serves `=d` as the original; the extension comes from the response Content-Type. */
function extFor(res) {
  const type = (res.headers.get('content-type') || '').split(';')[0].trim().toLowerCase();
  const ext = EXT_BY_TYPE[type];
  if (!ext) throw new Error(`unexpected content-type ${JSON.stringify(type)}`);
  return ext;
}

const PLACEHOLDER_MAX_BYTES = 2000;

/**
 * Pure: why a response must NOT be written to disk, or null if it is usable.
 * Without the signed-in session cookies Google answers 403 with a ~1KB
 * image/png placeholder (observed live: 1035 bytes), which looks like an image
 * and would otherwise be saved as a "thumb". So an image content-type alone
 * is not proof: the status must be 200 too, and a small non-200 body is
 * called out as the placeholder.
 */
export function classifyResponse({ status, contentType, bytes }) {
  const type = (contentType || '').split(';')[0].trim().toLowerCase();
  if (status !== 200) {
    const hint = bytes < PLACEHOLDER_MAX_BYTES ? ' (small body: likely the signed-out placeholder, session cookies missing?)' : '';
    return `HTTP ${status}, ${type || 'no content-type'}, ${bytes} bytes${hint}`;
  }
  if (!type.startsWith('image/') && !type.startsWith('video/')) {
    return `HTTP 200 but content-type ${JSON.stringify(type)} is not image/* or video/* (${bytes} bytes)`;
  }
  return null;
}

/**
 * Pure adapter: a Playwright APIRequestContext (shares the signed-in Chrome
 * cookies) -> a fetch-like fn returning the minimal Response shape the
 * fetchers consume (ok, status, headers.get, arrayBuffer). failOnStatusCode
 * stays false so a 403 reaches classifyResponse instead of throwing.
 */
export function requestContextFetch(requestContext) {
  return async (url) => {
    // Long videos are transcoded on request (=m37/=m18) and routinely exceed
    // Playwright's 30s default (8 of 109 Oliver-album videos did, both renditions).
    const r = await requestContext.get(url, { failOnStatusCode: false, timeout: 300_000 });
    const headers = r.headers();
    return {
      ok: r.status() >= 200 && r.status() < 300,
      status: r.status(),
      headers: { get: (name) => headers[name.toLowerCase()] ?? null },
      arrayBuffer: async () => {
        const b = await r.body();
        return b.buffer.slice(b.byteOffset, b.byteOffset + b.byteLength);
      },
    };
  };
}

async function fetchBytes(fetchFn, url) {
  const res = await fetchFn(url);
  const buf = Buffer.from(await res.arrayBuffer());
  const reason = classifyResponse({ status: res.status, contentType: res.headers.get('content-type'), bytes: buf.length });
  if (reason) throw new Error(reason);
  return { res, buf };
}

/**
 * Connects to the signed-in Chrome over CDP and returns {fetchFn, close}.
 * close() calls browser.close(), which for a connectOverCDP browser only
 * closes Playwright's websocket (verified in playwright-core 1.62.1: the
 * browserProcess.close for CDP is transport.closeAndWait(); the
 * Browser.close CDP command is only sent for browsers Playwright launched).
 */
async function connectCdpFetch() {
  const { chromium } = await import('playwright-core');
  const { getGatewayIp } = await import('./lib/gateway.mjs');
  const browser = await chromium.connectOverCDP(`http://${getGatewayIp()}:9251`);
  const context = browser.contexts()[0];
  if (!context) throw new Error('CDP browser has no context to take cookies from');
  return { fetchFn: requestContextFetch(context.request), close: () => browser.close() };
}

export async function fetchThumbs(store, { fetchFn = fetch, paceMs = PACE_MS, log = console.log } = {}) {
  let ok = 0, skipped = 0, failed = 0, requests = 0;
  for (const item of store.loadItems()) {
    if (store.hasThumb(item.mediaKey)) { skipped += 1; continue; }
    if (requests++ > 0) await sleep(paceMs);
    try {
      const { buf } = await fetchBytes(fetchFn, `${item.thumbUrl}=w512-h512`);
      store.writeThumb(item.mediaKey, buf);
      ok += 1;
      log(`thumb ok ${item.mediaKey}`);
    } catch (e) {
      failed += 1;
      log(`thumb FAILED ${item.mediaKey}: ${e.message}`);
    }
  }
  log(`thumbs: ok ${ok}, skipped ${skipped}, failed ${failed}`);
  return { ok, skipped, failed };
}

/**
 * Playable video rendition per kind=video item: `=m37` (1080p) first, `=m18`
 * (360p) when m37 is not a usable 200. Stored at video/<mediaKey>.mp4.
 */
export async function fetchVideos(store, { fetchFn = fetch, paceMs = PACE_MS, log = console.log } = {}) {
  let downloaded = 0, cached = 0, failed = 0, requests = 0;
  for (const item of store.loadItems().filter((i) => i.kind === 'video')) {
    if (store.hasVideo(item.mediaKey)) { cached += 1; continue; }
    let done = false;
    const errors = [];
    for (const fmt of ['m37', 'm18']) {
      if (requests++ > 0) await sleep(paceMs);
      try {
        const { res, buf } = await fetchBytes(fetchFn, `${item.thumbUrl}=${fmt}`);
        const type = (res.headers.get('content-type') || '').split(';')[0].trim().toLowerCase();
        if (!type.startsWith('video/')) throw new Error(`content-type ${JSON.stringify(type)} is not video/*`);
        if (buf.length <= PLACEHOLDER_MAX_BYTES) throw new Error(`only ${buf.length} bytes`);
        store.writeVideo(item.mediaKey, buf);
        log(`video ok ${item.mediaKey} via ${fmt} (${buf.length} bytes)`);
        downloaded += 1;
        done = true;
        break;
      } catch (e) {
        errors.push(`${fmt}: ${e.message}`);
      }
    }
    if (!done) {
      failed += 1;
      log(`video FAILED ${item.mediaKey}: ${errors.join('; ')}`);
    }
  }
  log(`videos: ${downloaded} downloaded, ${cached} cached, ${failed} failed`);
  return { downloaded, cached, failed };
}

export async function downloadKept(store, { fetchFn = fetch, paceMs = PACE_MS, log = console.log } = {}) {
  const decisions = store.loadDecisions();
  const kept = store.loadItems().filter((i) => decisions[i.mediaKey] === 'keep');
  let ok = 0, skipped = 0, failed = 0, requests = 0;
  for (const item of kept) {
    if (store.fullPath(item.mediaKey)) { skipped += 1; continue; }
    if (requests++ > 0) await sleep(paceMs);
    try {
      const { res, buf } = await fetchBytes(fetchFn, `${item.thumbUrl}=d`);
      store.writeFull(item.mediaKey, extFor(res), buf);
      ok += 1;
      log(`full ok ${item.mediaKey}`);
    } catch (e) {
      failed += 1;
      log(`full FAILED ${item.mediaKey}: ${e.message}`);
    }
  }
  const downloaded = ok + skipped;
  log(`downloaded ${downloaded} of ${kept.length} kept, failed ${failed}`);
  return { downloaded, kept: kept.length, failed, ok, skipped };
}

/** Google's kind names -> stored kinds (Animation is a photo). */
const GOOGLE_KINDS = { Photo: 'photo', Animation: 'photo', Video: 'video' };

export function mergeKindsFile(store, raw) {
  const kinds = {};
  for (const [key, k] of Object.entries(raw)) {
    const kind = GOOGLE_KINDS[k];
    if (!kind) throw new Error(`unknown kind for ${key}: ${JSON.stringify(k)}`);
    kinds[key] = kind;
  }
  return store.mergeKinds(kinds);
}

if (import.meta.url === `file://${process.argv[1]}`) {
  const args = process.argv.slice(2);
  const useCdp = args.includes('--cdp');
  const [cmd, albumId, extra] = args.filter((a) => a !== '--cdp');
  if (!['thumbs', 'download', 'videos', 'kinds'].includes(cmd) || !albumId || (cmd === 'kinds') !== (extra !== undefined)) {
    console.error('usage: node album-fetch.mjs thumbs|download|videos <albumId> [--cdp]\n       node album-fetch.mjs kinds <albumId> <kinds.json>');
    process.exit(2);
  }
  const store = new AlbumStore(defaultAlbumsDir(), albumId);
  if (cmd === 'kinds') {
    const { readFileSync } = await import('node:fs');
    console.log(JSON.stringify(mergeKindsFile(store, JSON.parse(readFileSync(extra, 'utf8')))));
    process.exit(0);
  }
  const cdp = useCdp ? await connectCdpFetch() : null;
  let r;
  try {
    const opts = cdp ? { fetchFn: cdp.fetchFn } : {};
    r = cmd === 'thumbs' ? await fetchThumbs(store, opts) : cmd === 'videos' ? await fetchVideos(store, opts) : await downloadKept(store, opts);
  } finally {
    await cdp?.close();
  }
  process.exit(r.failed > 0 ? 1 : 0);
}
