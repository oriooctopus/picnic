/**
 * Pure decision logic for the date-search matching strategy.
 *
 * Google Photos web search does not match filenames (verified live,
 * 2026-09-01: searching "IMG_1418.HEIC" returned semantically "relevant"
 * photos spanning Nov 2023 -> Aug 2026). Date search DOES work, so the
 * worker searches by calendar date instead and confirms every candidate it
 * opens by exact filename + pixel dimensions.
 *
 * The job's `creationDate` is UTC (MirrorQueueStore's ISO8601DateFormatter
 * has no explicit timeZone). Google Photos displays local capture time, and
 * the capture offset isn't known ahead of time (his photos are not all one
 * timezone) -- so the UTC calendar date is only a CANDIDATE local date. The
 * worker tries it first, then +/-1 day, confirming every hit by filename so
 * a wrong-day guess only costs a wasted search, never a wrong match.
 */

const EXTENSIONS = 'HEIC|JPG|JPEG|PNG|MOV|MP4';

// Specific, unambiguous filename shapes only -- NOT a generic
// [A-Za-z0-9._-]+ character-class match. The observed live panel text runs
// fields together with no delimiter (".../2.71mmISO40IMG_1433.HEIC7.2MP...")
// so a generic class match starting from the nearest \b boundary would
// greedily swallow "ISO40" (and everything back to the previous "/") as
// part of the filename. Literal-anchored patterns ("IMG_" as literal text,
// the rigid 8-4-4-4-12 hex-and-dash UUID shape) don't have that failure
// mode: the engine only matches starting at the literal substring, so a
// digit run glued on the front is never absorbed.
const FILENAME_PATTERNS = [
  new RegExp(`[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\\.(?:${EXTENSIONS})`, 'gi'),
  new RegExp(`IMG_\\d+\\.(?:${EXTENSIONS})`, 'gi'),
];

const DIMS_PATTERN = /(\d{3,5})\s*[×x]\s*(\d{3,5})/g;

/**
 * Parse a Google Photos info-panel's raw (run-together, no-separator)
 * textContent into the fields we need to confirm a match.
 *
 * The panel can accumulate more than one photo's block when "View next
 * photo" is used without the panel being torn down first (observed live:
 * IMG_1433's block followed directly by IMG_1441's). The CURRENT photo is
 * always the one whose block appears LAST in the text -- each "next" click
 * appends the new photo's fields after whatever was already there, it
 * never prepends. So: take the last filename match in document order, and
 * the dimensions match nearest after it (dimensions always follow the
 * filename in the observed field order: ...ISO, filename, megapixels,
 * W x H, "Uploaded from...").
 */
export function parsePanelText(rawText) {
  const text = rawText ?? '';
  const filenameMatches = [];
  for (const pattern of FILENAME_PATTERNS) {
    pattern.lastIndex = 0;
    let m;
    while ((m = pattern.exec(text))) {
      filenameMatches.push({ text: m[0], index: m.index, end: m.index + m[0].length });
    }
  }
  if (filenameMatches.length === 0) {
    return { filename: null, pixelWidth: null, pixelHeight: null };
  }
  filenameMatches.sort((a, b) => a.index - b.index);
  const current = filenameMatches[filenameMatches.length - 1];

  const dimsMatches = [];
  DIMS_PATTERN.lastIndex = 0;
  let dm;
  while ((dm = DIMS_PATTERN.exec(text))) {
    dimsMatches.push({ pixelWidth: Number(dm[1]), pixelHeight: Number(dm[2]), index: dm.index });
  }
  const after = dimsMatches.filter((d) => d.index >= current.end);
  const dims = after.length
    ? after.reduce((closest, d) => (d.index - current.end < closest.index - current.end ? d : closest))
    : null;

  return {
    filename: current.text,
    pixelWidth: dims ? dims.pixelWidth : null,
    pixelHeight: dims ? dims.pixelHeight : null,
  };
}

export function filenamesAgree(a, b) {
  return typeof a === 'string' && typeof b === 'string' && a.toLowerCase() === b.toLowerCase();
}

/**
 * Dimensions agree either as-reported or transposed -- Google Photos can
 * report W x H the other way round relative to the job's pixelWidth/
 * pixelHeight (e.g. portrait vs. landscape reporting convention), and the
 * spec treats that as the same photo, not a mismatch.
 */
export function dimensionsAgree(job, parsed) {
  if (parsed.pixelWidth == null || parsed.pixelHeight == null) return false;
  const straight = job.pixelWidth === parsed.pixelWidth && job.pixelHeight === parsed.pixelHeight;
  const transposed = job.pixelWidth === parsed.pixelHeight && job.pixelHeight === parsed.pixelWidth;
  return straight || transposed;
}

/**
 * Find the single unmatched job that this parsed photo confirms (exact
 * filename AND dimensions-agree-in-either-orientation). Zero or more than
 * one candidate job agreeing => null, never guess.
 */
export function findMatchingJob(jobs, parsed) {
  if (!parsed || !parsed.filename) return null;
  const matches = jobs.filter((job) => filenamesAgree(job.filename, parsed.filename) && dimensionsAgree(job, parsed));
  return matches.length === 1 ? matches[0] : null;
}

/** UTC calendar date ('YYYY-MM-DD') of an ISO timestamp. */
export function utcDateOf(isoString) {
  return new Date(isoString).toISOString().slice(0, 10);
}

/** Shift a 'YYYY-MM-DD' date string by `delta` days (can be negative). */
export function shiftDateDays(dateStr, delta) {
  const [y, m, d] = dateStr.split('-').map(Number);
  const dt = new Date(Date.UTC(y, m - 1, d));
  dt.setUTCDate(dt.getUTCDate() + delta);
  return dt.toISOString().slice(0, 10);
}

const MONTH_NAMES = [
  'January', 'February', 'March', 'April', 'May', 'June',
  'July', 'August', 'September', 'October', 'November', 'December',
];

/** 'YYYY-MM-DD' -> the "Month D, YYYY" string typed into Google Photos search. */
export function formatSearchDate(dateStr) {
  const [y, m, d] = dateStr.split('-').map(Number);
  return `${MONTH_NAMES[m - 1]} ${d}, ${y}`;
}

/**
 * Group jobs by the UTC calendar date of their creationDate, in first-seen
 * date order, jobs within a date in their original order. One search per
 * date group instead of one per job -- 221 jobs span ~30 distinct days.
 */
export function groupJobsByDate(jobs) {
  const map = new Map();
  for (const job of jobs) {
    const date = utcDateOf(job.creationDate);
    if (!map.has(date)) map.set(date, []);
    map.get(date).push(job);
  }
  return map;
}

/**
 * Google Photos search-result tiles share `a[href^="./search/"]` with
 * non-photo chips (e.g. "Favorites"); real tiles are distinguished by their
 * aria-label starting "Photo - ..." or "Video - ...".
 */
export function isRealPhotoTile(ariaLabel) {
  return typeof ariaLabel === 'string' && /^(Photo|Video)\s*-\s*/i.test(ariaLabel);
}

/**
 * The grid renders the same photo at multiple sizes, so the same tile
 * (identical aria-label, which carries capture time to the second) can
 * appear more than once. Dedupe before opening any of them.
 */
export function dedupeTilesByAriaLabel(tiles) {
  const seen = new Set();
  const out = [];
  for (const tile of tiles) {
    if (seen.has(tile.ariaLabel)) continue;
    seen.add(tile.ariaLabel);
    out.push(tile);
  }
  return out;
}
