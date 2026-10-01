/**
 * Synthetic Google Photos batchexecute listing bodies, in the real wire
 * format (`)]}'`, length-prefixed lines, [["wrb.fr", rpc, "<JSON string>"]]).
 * No real ids/URLs: everything here is made up.
 */

export function item(mediaKey, captureMs, { w = 3024, h = 4032, tz = -21600000, upload = 1777517769332 } = {}) {
  return [
    mediaKey,
    [`https://lh3.googleusercontent.com/synthetic/${mediaKey}`, w, h, null, null, null, null, null, [null, null, 14], [1]],
    captureMs,
    'dedupe-' + mediaKey,
    tz,
    upload,
    [`AF1QipAlbum${mediaKey}`],
    [[1], [2]],
  ];
}

function line(rpc, payload) {
  const json = JSON.stringify([['wrb.fr', rpc, JSON.stringify(payload), null, null, null, 'generic']]);
  return `${json.length}\n${json}\n`;
}

/** One response body with several wrb.fr lines: `lines` = [{rpc, payload}]. */
export function body(lines, { noise = true } = {}) {
  const out = [")]}'\n\n"];
  for (const { rpc, payload } of lines) out.push(line(rpc, payload));
  if (noise) out.push('58\n[["di",823],["af.httprm",823,"-1","x"]]\n27\n[["e",5,null,null,71284]]\n');
  return out.join('');
}

/** Convenience: a single EzkLib listing body holding `items` nested the way Google nests them. */
export function listingBody(items, rpc = 'EzkLib') {
  return body([{ rpc, payload: [[items], null, [[1, 2, 3]]] }]);
}
