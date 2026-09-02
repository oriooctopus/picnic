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

/**
 * -- CHANGE 1: aria-label fast-path matching -------------------------------
 *
 * A result-grid tile's aria-label carries capture time to the SECOND, in the
 * viewer's local time zone, e.g. "Photo - Portrait - Aug 5, 2026, 6:54:07 PM"
 * / "Video - Portrait - Aug 5, 2026, 7:31:07 PM". That's more precise than
 * the info panel (minutes only), so if we can work out the local UTC offset
 * for a date group we can predict exactly which tile matches each queued
 * job WITHOUT opening every tile -- see planAriaMatches() below.
 *
 * The job's creationDate is UTC and the offset varies by trip, so it's
 * self-calibrated per date group from the data itself (never configured):
 * for every (job, tile) pair, treat the tile's local wall-clock reading as
 * if it were a UTC instant (parseTileAriaLabel's wallClockAsUtcMs -- pure
 * bookkeeping, not a real UTC time) and subtract the job's real UTC instant.
 * For a TRUE pair (the tile really is that job's photo) this difference is
 * exactly the zone's UTC offset, every time, because both timestamps carry
 * second precision. For an unrelated pair it's whatever the two random
 * timestamps happen to differ by. So: keep only diffs landing exactly on a
 * real UTC-offset boundary (calibrateOffsetSeconds' VALID_OFFSET_SECONDS,
 * 15-minute granularity, +/-14h), and trust the value multiple independent
 * pairs agree on -- a lone coincidental hit must never set the offset.
 *
 * This is a pre-filter only. planAriaMatches() names which tile to open for
 * each job, but opening it and confirming the FILENAME from the info panel
 * (worker.mjs's confirmAndTrash, unchanged from before this change) is still
 * the only thing that ever authorises a trash.
 */

/** Abbreviated ("Aug") and full ("August") month names, case-insensitive -> index. Tile aria-labels use the abbreviated form; matched defensively against both. */
const MONTH_INDEX = new Map();
MONTH_NAMES.forEach((name, i) => {
  MONTH_INDEX.set(name.toLowerCase(), i);
  MONTH_INDEX.set(name.slice(0, 3).toLowerCase(), i);
});

const TILE_LABEL_PATTERN =
  /^(Photo|Video)\s*-\s*[A-Za-z]+\s*-\s*([A-Za-z]+)\s+(\d{1,2}),\s*(\d{4}),\s*(\d{1,2}):(\d{2}):(\d{2})\s*(AM|PM)/i;

/**
 * Parse a result-grid tile's aria-label into {mediaType, wallClockAsUtcMs}.
 * Returns null for anything that doesn't match the expected shape (decoy
 * chips already filtered by isRealPhotoTile, but also protects against any
 * future aria-label format Google ships) -- callers must treat null as "no
 * signal", never coerce it into a match.
 */
export function parseTileAriaLabel(ariaLabel) {
  const m = TILE_LABEL_PATTERN.exec(ariaLabel || '');
  if (!m) return null;
  const [, kind, monthName, day, year, hourStr, minute, second, ampm] = m;
  const monthIdx = MONTH_INDEX.get(monthName.toLowerCase());
  if (monthIdx == null) return null;
  let hour = Number(hourStr) % 12;
  if (/PM/i.test(ampm)) hour += 12;
  return {
    mediaType: kind.toLowerCase(), // 'photo' | 'video'
    // The tile's LOCAL wall-clock reading, reinterpreted as if it were a UTC
    // instant -- see the module comment above. Never compare this to a real
    // UTC timestamp directly; it only makes sense as a diff against another
    // value produced the same way (or against a job's UTC ms, which is
    // exactly what calibrateOffsetSeconds does).
    wallClockAsUtcMs: Date.UTC(Number(year), monthIdx, Number(day), hour, Number(minute), Number(second)),
  };
}

/**
 * Does a queued job's declared media type allow it to match a tile of
 * `tileMediaType` ('photo' | 'video')? MirrorQueueStore.swift emits
 * mediaType as 'video' | 'image' (never null) for real queue entries, but
 * older queued jobs predate the field and carry null -- for those, don't
 * gate on a signal we don't have and let filename+dimensions decide, same
 * as before this change existed.
 */
export function jobMediaTypeMatchesTile(job, tileMediaType) {
  if (job.mediaType == null) return true;
  const jobKind = job.mediaType === 'video' ? 'video' : 'photo';
  return jobKind === tileMediaType;
}

// Every real-world UTC offset, 15-minute granularity (covers the standard
// hour/half-hour zones and the handful of :45 outliers like Nepal/Chatham
// Islands), +/-14h. A spurious (job,tile) diff landing exactly on one of
// these AND recurring across independent pairs is not plausible by chance.
const VALID_OFFSET_SECONDS = new Set();
for (let m = -14 * 60; m <= 14 * 60; m += 15) VALID_OFFSET_SECONDS.add(m * 60);

// "A single coincidental pair must not set the offset" (task brief) -- two
// independent (job,tile) pairs agreeing on the same boundary is the floor.
const MIN_AGREEING_PAIRS = 2;

/**
 * Self-calibrate a date group's local-time UTC offset (in seconds) from its
 * own (job, tile) data -- see the module comment above. `parsedTiles` is
 * `[{tile, parsed}, ...]` (parsed = parseTileAriaLabel output, already
 * filtered non-null by the caller). Returns null when no offset reaches
 * MIN_AGREEING_PAIRS -- refuse rather than trust a weak signal.
 */
export function calibrateOffsetSeconds(jobs, parsedTiles) {
  const counts = new Map();
  for (const job of jobs) {
    const jobMs = new Date(job.creationDate).getTime();
    for (const { parsed } of parsedTiles) {
      if (!jobMediaTypeMatchesTile(job, parsed.mediaType)) continue;
      const diffSeconds = Math.round((parsed.wallClockAsUtcMs - jobMs) / 1000);
      if (!VALID_OFFSET_SECONDS.has(diffSeconds)) continue;
      counts.set(diffSeconds, (counts.get(diffSeconds) ?? 0) + 1);
    }
  }
  let best = null;
  for (const [offset, count] of counts) {
    if (!best || count > best.count) best = { offset, count };
  }
  if (!best || best.count < MIN_AGREEING_PAIRS) return null;
  return best.offset;
}

/**
 * Decide which tiles are worth opening for a date group, from the grid's
 * own aria-labels alone. Returns a Map<job, tile> naming exactly the ONE
 * tile predicted to confirm each job, or null when the date isn't safe to
 * fast-path: the offset didn't calibrate, or ANY job's predicted slot has 0
 * or more than 1 candidate tile (burst shots; a Live Photo can surface as a
 * paired image+video tile at the same second, but jobMediaTypeMatchesTile
 * already disambiguates that case when the job's mediaType is known).
 *
 * null means "fall back to the exhaustive walk for the WHOLE date" -- never
 * open some jobs' tiles via a plan we don't fully trust. This function only
 * decides what's worth OPENING; the caller (worker.mjs) still requires the
 * info panel's filename to agree before ever trashing anything.
 */
export function planAriaMatches(jobs, tiles) {
  const parsedTiles = tiles
    .map((tile) => ({ tile, parsed: parseTileAriaLabel(tile.ariaLabel) }))
    .filter((t) => t.parsed);
  if (parsedTiles.length === 0) return null;

  const offsetSeconds = calibrateOffsetSeconds(jobs, parsedTiles);
  if (offsetSeconds == null) return null;

  // Ambiguity is decided PER JOB, not per date. This used to `return null` for
  // the whole date the moment any single job had 0 or >1 candidates -- and on
  // a date with twenty-odd deletions there is nearly always one such job (its
  // tile not loaded yet, or already trashed by an earlier pass). The effect
  // was that the fast path engaged on only 6 of ~30 dates in a full run, and
  // everything else fell through to the far less reliable walk, even though
  // most jobs on those dates had a perfectly unique match waiting.
  //
  // Safety is unchanged: a job is only planned when EXACTLY ONE tile matches
  // its predicted capture second and media type, and the filename read from
  // the info panel still has to confirm before anything is trashed. Jobs left
  // unplanned here simply fall through to the exhaustive walk.
  const matches = new Map();
  for (const job of jobs) {
    const jobMs = new Date(job.creationDate).getTime();
    const predictedMs = jobMs + offsetSeconds * 1000;
    const candidates = parsedTiles.filter(
      (t) => t.parsed.wallClockAsUtcMs === predictedMs && jobMediaTypeMatchesTile(job, t.parsed.mediaType)
    );
    if (candidates.length !== 1) continue; // ambiguous (0 or >1) -- leave to the walk
    matches.set(job, candidates[0].tile);
  }
  if (matches.size === 0) return null;
  return matches;
}
