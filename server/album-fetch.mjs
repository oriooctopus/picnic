#!/usr/bin/env node
/**
 * Album triage fetcher.
 *   node album-fetch.mjs thumbs <albumId>    fetch <thumbUrl>=w512-h512 for each item
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

async function fetchBytes(fetchFn, url) {
  const res = await fetchFn(url);
  if (!res.ok) throw new Error(`HTTP ${res.status}`);
  return { res, buf: Buffer.from(await res.arrayBuffer()) };
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

if (import.meta.url === `file://${process.argv[1]}`) {
  const [cmd, albumId] = process.argv.slice(2);
  if (!['thumbs', 'download'].includes(cmd) || !albumId) {
    console.error('usage: node album-fetch.mjs thumbs|download <albumId>');
    process.exit(2);
  }
  const store = new AlbumStore(defaultAlbumsDir(), albumId);
  const r = cmd === 'thumbs' ? await fetchThumbs(store) : await downloadKept(store);
  process.exit(r.failed > 0 ? 1 : 0);
}
