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
  // Any other name, anchored to a WHOLE LINE. The live panel's innerText puts
  // each field on its own line, so a line that is nothing but a name ending
  // in a media extension is unambiguous. 2026-09-23: without this, names
  // like IMG_6732_Original.HEIC, lp_image_Original.HEIC and
  // RecordIt-1785788960.mp4 parsed as "no filename", and 186 photos per walk
  // were logged UNREADABLE -- including every job the walk never matched.
  new RegExp(`^[^\\n/\\\\]{1,200}\\.(?:${EXTENSIONS})$`, 'gim'),
];

const DIMS_PATTERN = /(\d{3,5})\s*[×x]\s*(\d{3,5})/g;

// VERIFIED LIVE 2026-09-22 (Oliver's own probe of the real info panel's
// innerText): the date/time block is THREE SEPARATE LINES, not the
// run-together shape an earlier version of this pattern assumed --
//
//   Sep 22                  <- "<Month> <Day>" alone -- NO YEAR for the
//                               current calendar year (confirmed live: both
//                               real samples below omit it)
//   Yesterday, 6:25 PM      <- a free-text label ("Yesterday", "Today", or
//                               presumably a weekday name -- never itself
//                               constrained) + ", " + "H:MM AM/PM"
//   GMT-04:00               <- Google's UTC-offset suffix, own line
//
// real samples (Oliver, 2026-09-22):
//   "Details\nSep 22\nYesterday, 6:25 PM\nGMT-04:00\nApple iPhone 13 Pro..."
//   "Details\nSep 22\nYesterday, 2:34 PM\nGMT-04:00\nIMG_2929.JPG..."
//
// The "Mon D, YYYY" (older-year) shape and its accompanying label line are
// UNVERIFIED LIVE -- no real past-year photo was in the live probe's first
// few results -- this is a best-effort guess at the same three-line
// structure with a year appended to the first line, per Google's common
// "show the year only when it's not the current one" convention. If a live
// run's stop condition misbehaves specifically on OLDER photos, this is the
// first thing to re-probe.
//
// \s+ between fields matches real newlines fine (JS \s includes \n), so
// this pattern works whether the true separator is a literal newline or
// run together with no separator at all -- \s* also matches zero
// characters. The label is a generic [A-Za-z]+ here (unlike a plain
// [A-Za-z]{3,9} class, see the month-name story below) because a real
// newline or space always separates it from the day-of-month before it, so
// it cannot swallow a preceding merged word.
//
// EXPLICIT month-name alternation for the month itself, NOT a generic
// [A-Za-z]{3,9} class -- bitten by exactly the same failure this file's
// FILENAME_PATTERNS header documents for filenames: an EARLIER (now
// corrected) version of this pattern assumed the month ran together with
// whatever preceded it ("...PeopleDetailsAug 5Wed...") and a generic
// letter-class quantifier greedily absorbed "etailsAug" as the "month name"
// instead of just "Aug" -- caught by testing against a fixture, not by
// inspection; kept as a defensive habit even now that the real text is
// known to have a preceding newline. Built lazily (captureDatePattern())
// because it needs MONTH_NAMES, which this file defines further down;
// referencing it inside a function body is safe (called only after the
// whole module has finished loading), referencing it in this top-level
// const's initializer would not be (temporal-dead-zone ReferenceError).
let capturedDatePatternCache = null;
function captureDatePattern() {
  if (!capturedDatePatternCache) {
    const monthAlternation = MONTH_NAMES.map((n) => `${n}|${n.slice(0, 3)}`).join('|');
    // GMT offset is now CAPTURED (sign + HH:MM), not just matched as a bare
    // literal -- see parseCaptureDateMs' 2026-09-24 header for the bug this
    // fixes (the offset was being read past but silently discarded, so
    // "6:27 PM GMT-04:00" -- 10:27 PM UTC -- parsed as 6:27 PM UTC, 4 hours
    // off).
    capturedDatePatternCache = new RegExp(
      `(${monthAlternation})\\s+(\\d{1,2})(?:,\\s*(\\d{4}))?\\s+[A-Za-z]+,\\s*(\\d{1,2}):(\\d{2})\\s*(AM|PM)\\s*GMT([+-])(\\d{2}):(\\d{2})`,
      'i'
    );
  }
  return capturedDatePatternCache;
}

/**
 * Parse a REAL UTC capture instant out of the panel's raw text -- added
 * 2026-09-22 for the TIMELINE walk's stop condition ONLY (worker.mjs's
 * walkTimeline: "have we scrolled past the oldest pending job's date yet?").
 * NEVER used for matching, which stays filename-only (findMatchingJob) --
 * this field only decides when to stop LOOKING, so a wrong estimate costs
 * walking too long or stopping a little early, never a wrong trash.
 *
 * See captureDatePattern's own header for the exact shape this expects and
 * what's still UNVERIFIED LIVE about it (the older-year "Mon D, YYYY" form).
 *
 * TIMEZONE FIX (2026-09-24, live finding): an earlier version of this
 * function matched the trailing "GMT[+-]HH:MM" as a bare literal and threw
 * the offset away entirely, treating the parsed LOCAL wall-clock reading as
 * if it were already UTC -- "6:27 PM GMT-04:00" (a real capture, 22:27
 * UTC) parsed as 18:27 UTC, 4 hours off. The offset is now captured and
 * applied properly: local wall-clock time is UTC PLUS the offset (so a
 * negative offset like -04:00 means UTC is LATER than the local reading --
 * UTC = local - offset), which is what standard date-header notation
 * always means and matches the corrected example above (18:27 - (-4h) =
 * 22:27).
 *
 * `nowMs` (real epoch ms, defaulting to Date.now() at the parsePanelText
 * call site) is needed because the panel OMITS the year for the current
 * calendar year (verified live) -- when no year is present in the text,
 * this assumes the current calendar year first, and if that lands in the
 * FUTURE relative to `nowMs` (e.g. today is Sep 23 and the photo reads
 * "Dec 25" with no year -- Google would never show a genuinely future
 * capture date with the year omitted), falls back to the PREVIOUS year
 * instead. The year-guess itself is evaluated in UTC terms (before the
 * offset shift) since `nowMs` is a real instant either way -- a capture
 * within a few hours of a year boundary could theoretically land on the
 * "wrong" side of this heuristic, but that only ever costs the stop
 * condition a slightly early/late decision, never a wrong trash. A year
 * embedded in the text is always trusted as-is, offset applied the same way.
 *
 * Returns null (never throws, never guesses) when the pattern doesn't match
 * at all, or when the matched "month" text isn't a real month name --
 * refusing is always safe here since the caller just skips the stop-check
 * for that one photo.
 */
function parseCaptureDateMs(text, nowMs) {
  const m = captureDatePattern().exec(text);
  if (!m) return null;
  const [, monthName, day, year, hourStr, minute, ampm, offsetSign, offsetHours, offsetMinutes] = m;
  const monthIdx = MONTH_INDEX.get(monthName.toLowerCase());
  if (monthIdx == null) return null; // not a real month name -- a coincidental match, refuse rather than guess
  let hour = Number(hourStr) % 12;
  if (/PM/i.test(ampm)) hour += 12;
  const offsetMs = (offsetSign === '-' ? -1 : 1) * (Number(offsetHours) * 60 + Number(offsetMinutes)) * 60 * 1000;
  const localToUtcMs = (y) => Date.UTC(y, monthIdx, Number(day), hour, Number(minute)) - offsetMs;
  if (year != null) {
    return localToUtcMs(Number(year));
  }
  const currentYear = new Date(nowMs).getUTCFullYear();
  const candidateMs = localToUtcMs(currentYear);
  return candidateMs > nowMs ? localToUtcMs(currentYear - 1) : candidateMs;
}

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
 *
 * `nowMs` feeds parseCaptureDateMs' current-vs-future-year decision when the
 * panel text omits a year -- defaults to the real Date.now() so ordinary
 * callers (worker.mjs) get sensible behaviour with no extra argument, but
 * stays overridable so tests can be deterministic without mocking the
 * system clock. NOTE: this makes parsePanelText's return depend on
 * wall-clock time ONLY for a text sample with no year in it and no explicit
 * override -- filename/pixelWidth/pixelHeight (and captureDateMs when a
 * year IS present) are unaffected either way.
 */
export function parsePanelText(rawText, nowMs = Date.now()) {
  const text = rawText ?? '';
  const captureDateMs = parseCaptureDateMs(text, nowMs);
  const filenameMatches = [];
  for (const pattern of FILENAME_PATTERNS) {
    pattern.lastIndex = 0;
    let m;
    while ((m = pattern.exec(text))) {
      filenameMatches.push({ text: m[0], index: m.index, end: m.index + m[0].length });
    }
  }
  if (filenameMatches.length === 0) {
    return { filename: null, pixelWidth: null, pixelHeight: null, captureDateMs };
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
    captureDateMs,
  };
}

/**
 * A bulk re-import into the local photo library can append "_Original"
 * immediately before the extension (e.g. IMG_6716_Original.HEIC), while
 * Google Photos keeps the bare original name for the same photo
 * (IMG_6716.HEIC) -- confirmed live 2026-09-22 against 110 jobs stuck in
 * needs_review from a March 2026 re-import (see PhotoLibraryService.swift /
 * worker.mjs git history for the re-import itself; no need to touch the
 * Swift side). Strip exactly that known suffix before comparing. This is
 * narrow on purpose, not a fuzzy matcher: any other divergence (a real
 * filename mismatch) still fails, preserving findMatchingJob's exact-match
 * philosophy.
 */
function stripOriginalSuffix(name) {
  return name.replace(/_original(?=\.[^.]+$)/i, '');
}

export function filenamesAgree(a, b) {
  if (typeof a !== 'string' || typeof b !== 'string') return false;
  return stripOriginalSuffix(a).toLowerCase() === stripOriginalSuffix(b).toLowerCase();
}

/** `stripOriginalSuffix` plus the extension itself, lowercased -- shared by basenameAgreesWithinCaptureWindow's two comparisons below. */
function baseNameNoExtension(name) {
  return stripOriginalSuffix(name).replace(/\.[^.]+$/, '').toLowerCase();
}

/** The bare extension (no leading dot), lowercased; '' if there isn't one. */
function extensionOf(name) {
  const m = /\.([^.]+)$/.exec(name);
  return m ? m[1].toLowerCase() : '';
}

// Panel captures only MINUTE precision (matcher.mjs's captureDatePattern --
// no seconds field at all), so a genuine same-photo pair can legitimately
// read 1 minute apart depending on which side of a minute boundary each
// timestamp source rounds to. 3 minutes covers that with margin while still
// rejecting the real 2026-09-25 live evidence this exists for: two DISTINCT
// copies of "IMG_6562" sat a full 2 HOURS apart (T21:15 vs T19:16) -- only
// the one within minutes of the job's own creationDate may ever match.
const EXTENSION_TOLERANT_WINDOW_MS = 3 * 60 * 1000;

/**
 * A job also matches a panel read when the BASE name agrees (after
 * stripping _Original and the extension) but the EXTENSION itself differs --
 * live finding 2026-09-25: 4 jobs from a phone re-import are EDITED exports
 * (job filenames end "..._Original.JPG"), while Google Photos still holds
 * the ORIGINAL, unedited file under its own extension (the panel reads
 * "IMG_6636.PNG" while the job says "IMG_6636_Original.JPG"). This is not a
 * typo or drift -- it's a permanent, structural difference this specific
 * re-import always produces, so the exact-match filenamesAgree() above
 * correctly refuses these forever; they were stuck in needs_review with no
 * other path to ever confirm them.
 *
 * Extension tolerance ALONE would be too loose -- many unrelated photos can
 * share a base name across different exports/extensions -- so this also
 * requires the panel's captureDateMs to land within
 * EXTENSION_TOLERANT_WINDOW_MS of the job's own creationDate (see that
 * constant's header for the exact live evidence this window size is tuned
 * against). A read with no captureDateMs at all (matcher.mjs's
 * parseCaptureDateMs can legitimately return null -- see its own header)
 * has no time evidence to gate on and NEVER matches via this path --
 * exact-filename matching, unaffected by any of this, remains the only way
 * such a read can ever match.
 */
export function basenameAgreesWithinCaptureWindow(job, parsed) {
  if (parsed.captureDateMs == null) return false;
  if (typeof job?.filename !== 'string' || typeof parsed.filename !== 'string') return false;
  if (extensionOf(job.filename) === extensionOf(parsed.filename)) return false; // same extension -> filenamesAgree()'s job, not this one's
  if (baseNameNoExtension(job.filename) !== baseNameNoExtension(parsed.filename)) return false;
  const jobMs = new Date(job.creationDate).getTime();
  if (!Number.isFinite(jobMs)) return false;
  return Math.abs(parsed.captureDateMs - jobMs) <= EXTENSION_TOLERANT_WINDOW_MS;
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
 * Find the single unmatched job that this parsed photo confirms.
 *
 * FILENAME ONLY as of 2026-09-22 -- dimensions used to gate this too, but
 * that produced false misses two ways, confirmed live:
 *   1. An EDITED photo (e.g. cropped) reports its NEW pixel size on the
 *      phone side (job IMG_6636_Original.JPG: 1170x1111), while Google
 *      Photos still holds whatever size it has for the same photo -- the
 *      edit is real, the photo is still the same file, dimensions just
 *      disagree for a reason that has nothing to do with identity.
 *   2. openInfoPanelOnce polls up to 15s for the panel to render a
 *      dimensions string before giving up entirely (job IMG_6636 failed
 *      live with "info panel never produced dimensions text after 15s" --
 *      see worker.mjs) -- sometimes it just never renders, taking a
 *      genuinely matchable photo down with it.
 * Search is already restricted to the job's date +/-1 day (runDateGroups),
 * and within that window IMG_#### / UUID filenames are unique, so filename
 * alone is sufficient identity. dimensionsAgree() is kept (still used to
 * annotate `comparison` when dimensions happen to be available -- see
 * confirmAndTrash) but no longer gates a match.
 *
 * The "never guess" rule is unchanged: zero or more than one candidate job
 * agreeing on filename => null.
 *
 * 2026-09-25: a candidate job can ALSO agree via basenameAgreesWithinCapture-
 * Window (same base name, different extension, captureDateMs within its own
 * tight window -- see that function's own header for the live re-import
 * case this exists for). Both kinds of agreement feed the SAME pool before
 * the ambiguity check runs, so a job that would exact-match AND a different
 * job that would only base-name-match against the same read still correctly
 * refuse as ambiguous (0 or >1 => null), exactly like two exact-filename
 * matches always have.
 */
export function findMatchingJob(jobs, parsed) {
  if (!parsed || !parsed.filename) return null;
  const matches = jobs.filter(
    (job) => filenamesAgree(job.filename, parsed.filename) || basenameAgreesWithinCaptureWindow(job, parsed)
  );
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
 * A tile's REAL identity: its href when known, falling back to its
 * aria-label for anything that doesn't carry one (older callers/tests that
 * never read href -- see dedupeTilesByIdentity). Google Photos assigns each
 * library item a stable per-item href regardless of which grid size it's
 * currently rendered at, so href is the one thing that tells apart "the same
 * item rendered twice" from "two distinct items that happen to render the
 * same aria-label text" (see dedupeTilesByIdentity's header for why that
 * distinction matters).
 */
export function tileIdentity(tile) {
  return tile.href ?? tile.ariaLabel;
}

/**
 * Dedupe by the tile's REAL identity (href) rather than its aria-label alone
 * (dedupeTilesByAriaLabel above, kept for its own tests/history and for any
 * caller that only ever had aria-label to go on).
 *
 * 2026-09-12 FINDING: Oliver's real duplicate library items (a photo
 * downloaded to his phone and separately re-uploaded by a backup tool) carry
 * the SAME EXIF capture time down to the second, so their grid tiles render a
 * BYTE-IDENTICAL aria-label ("Photo - Portrait - Aug 5, 2026, 6:54:07 PM")
 * despite being two distinct Google Photos items with distinct hrefs.
 * dedupeTilesByAriaLabel was built only to collapse the SAME photo rendered
 * at multiple grid sizes (which shares BOTH aria-label and href) -- it can't
 * tell that case apart from two genuinely different items that happen to
 * collide on aria-label text, and silently drops one of the real items
 * before planAriaMatches ever sees it. That is the actual reason a date
 * fully resolved by the aria fast path (the common case: one queued job,
 * whose duplicate is otherwise invisible to it) never got a chance to notice
 * the collision and defer to the exhaustive walk. Deduping by href instead
 * keeps both real items as separate candidates: planAriaMatches then
 * correctly sees 2 candidates for that job's predicted second and defers it
 * to the walk, which finds and trashes both (see confirmAndTrash's /
 * walkPhotoView's matchedJobs).
 */
export function dedupeTilesByIdentity(tiles) {
  const seen = new Set();
  const out = [];
  for (const tile of tiles) {
    const key = tileIdentity(tile);
    if (seen.has(key)) continue;
    seen.add(key);
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
