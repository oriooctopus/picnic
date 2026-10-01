/**
 * Passive parsing of Google Photos' own listing responses (the reconcile scan
 * never opens a photo). Google's web app POSTs `.../_/PhotosUi/data/batchexecute`
 * (rpcids EzkLib, ZSBAec, frGlJf ...) and each response body is `)]}'` followed
 * by length-prefixed lines; every JSON line looks like
 *   [["wrb.fr","<rpcid>","<JSON string>", ...], ["di",..], ...]
 * and the inner JSON string, parsed, contains item arrays shaped
 *   [mediaKey, [thumbUrl, width, height, ...], captureMs, dedupeStr, tzOffsetMs, uploadMs, ...]
 * Verified live 2026-09-30 by a read-only probe. Filename and camera model are
 * NOT in these items.
 */

/** Is `o` an item array? (len > 5, o[0] an AF1Qip media key, o[1][0] an http URL, o[2] an integer) */
function isListingItem(o) {
  return (
    Array.isArray(o) &&
    o.length > 5 &&
    typeof o[0] === 'string' &&
    o[0].startsWith('AF1Qip') &&
    Array.isArray(o[1]) &&
    typeof o[1][0] === 'string' &&
    o[1][0].startsWith('http') &&
    Number.isInteger(o[2])
  );
}

function walk(node, out) {
  if (!Array.isArray(node)) return;
  if (isListingItem(node)) {
    out.push({
      mediaKey: node[0],
      thumbUrl: node[1][0],
      width: node[1][1],
      height: node[1][2],
      captureMs: node[2],
      tzOffsetMs: Number.isInteger(node[4]) ? node[4] : 0,
      uploadMs: Number.isInteger(node[5]) ? node[5] : null,
    });
    return;
  }
  for (const child of node) walk(child, out);
}

/**
 * Pure: a batchexecute response body -> [{mediaKey, thumbUrl, width, height,
 * captureMs, tzOffsetMs, uploadMs}]. Lines that are not JSON (the `)]}'`
 * preamble, the length prefixes, blanks) are skipped -- they are the wire
 * format, not an error. A line that IS a JSON array but whose wrb.fr payload
 * fails to parse is a real format change and throws.
 */
export function parseListingBody(body) {
  const items = [];
  for (const line of String(body).split('\n')) {
    const trimmed = line.trim();
    if (!trimmed.startsWith('[')) continue;
    const envelope = JSON.parse(trimmed);
    for (const entry of envelope) {
      if (Array.isArray(entry) && entry[0] === 'wrb.fr' && typeof entry[2] === 'string') {
        walk(JSON.parse(entry[2]), items);
      }
    }
  }
  return items;
}

/** Local capture "YYYY-MM" of an item: capture time shifted by the item's own tz offset. */
export function localMonthOf(item) {
  return new Date(item.captureMs + item.tzOffsetMs).toISOString().slice(0, 7);
}

/**
 * Pure: keep items whose LOCAL capture month (captureMs + tzOffsetMs) is
 * `month` ("YYYY-MM"). The phone buckets its manifest by local month, so an
 * item outside the month can never be in the manifest and must not become a
 * false "only in Google" candidate.
 */
export function filterItemsToMonth(items, month) {
  return items.filter((item) => localMonthOf(item) === month);
}

/** Pure: merge items into `byKey` (first sighting of a mediaKey wins); returns how many were new. */
export function mergeItems(byKey, items) {
  let added = 0;
  for (const item of items) {
    if (!byKey.has(item.mediaKey)) {
      byKey.set(item.mediaKey, item);
      added += 1;
    }
  }
  return added;
}
