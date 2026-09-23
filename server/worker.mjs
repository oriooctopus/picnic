#!/usr/bin/env node
/**
 * Drains queued Picnic mirror jobs against Google Photos web.
 *
 * STRATEGY (rewritten 2026-09-01 — see git history for the prior filename-
 * search design, which was disproven live: Google Photos search does not
 * match filenames, it returns semantically "relevant" photos spanning
 * years). Date search DOES work, so:
 *
 *   1. Group queued jobs by the UTC calendar date of their creationDate.
 *      One search per date group, not per job (221 jobs -> ~30 searches).
 *   2. Search "<Month> <D>, <YYYY>" via the in-app search box.
 *   3. Collect real photo/video tiles (filter Google's own decoy chips by
 *      aria-label), dedupe (the grid renders one photo at multiple sizes).
 *   4. CHANGE 1 (2026-09-01): before opening anything, try to predict
 *      exactly which tile matches each queued job from the tiles' own
 *      aria-labels, which carry capture time to the SECOND (more precise
 *      than the info panel's minutes-only reading) — see lib/matcher.mjs's
 *      planAriaMatches() for the self-calibration + collision-safety logic.
 *      When it returns a plan, ONLY those tiles get opened (~221 opens
 *      instead of ~700 across ~30 dates). When it returns null (offset
 *      didn't calibrate, or any job's predicted tile is ambiguous), fall
 *      straight through to step 5 unchanged — the exhaustive walk.
 *   5. Exhaustive fallback (REWRITTEN 2026-09-01 -- see processDateGroup /
 *      walkPhotoView): the original design opened a tile, read the panel,
 *      returned to the results GRID, then found the next tile there -- that
 *      grid-return step failed live for five distinct reasons across many
 *      rounds (stale positional locators, a dead 0x0 duplicate grid, a
 *      shared scroll budget, virtualized re-collection, an Escape loop that
 *      navigated out of the results entirely), topping out at 2 of 27 tiles
 *      on the last measured run. It never returns to the grid mid-date now:
 *      open the date's FIRST tile once, open the info panel once, then step
 *      through the day entirely INSIDE the photo view with ArrowRight
 *      ("View next photo"'s keyboard equivalent), reading + parsing the
 *      panel at each stop. An early version of this worker did exactly this
 *      and walked 27 photos on one date in a single live run.
 *   6. A photo confirms a job when its filename matches exactly (2026-09-22:
 *      no longer gated on dimensions agreeing too — an edited photo reports
 *      a different size on the phone than Google holds, and the info panel
 *      sometimes never renders dimensions at all; date-window + filename is
 *      unique enough on its own, see lib/matcher.mjs's findMatchingJob for
 *      the full history) — lib/matcher.mjs's findMatchingJob. This is the
 *      ONLY thing that ever authorises a trash — the aria pre-filter in step
 *      4 only decides what's worth opening, never confirms a match by
 *      itself.
 *   7. Because the job's creationDate is UTC and Google Photos displays
 *      local capture time, and the offset isn't known ahead of time, a
 *      date group's still-unmatched jobs get a second search on day-1 and
 *      a third on day+1 before falling back to needs_review. A wrong-day
 *      guess only costs a wasted search — every hit is still confirmed by
 *      exact filename, never assumed from the date match alone.
 *
 * On a match: click "Move to trash" (never permanent-delete) and mark the
 * job 'trashed'. Ambiguous (0 or >1 agreeing) after all date attempts ->
 * needs_review, never guess.
 *
 * CHANGE 2 (2026-09-01): Oliver has explicitly decided this worker does not
 * need bot-detection avoidance (he already bulk-deletes via a scripted
 * browser extension), so the human-mimicry pacing that used to run by
 * default (inter-click jitter, pre-submit dwell, per-character typing,
 * randomized inter-job pacing) is now OFF by default — see stealthDelay()
 * below. Pass --slow to restore it. The STOP-on-friction behaviour
 * (assertNoFriction, FRICTION_PATTERNS) is UNCHANGED either way — dropping
 * pacing is not the same as ignoring a captcha/rate-limit if one shows up.
 *
 * Connects to the persistent Windows Chrome (profile signed into
 * oliverullman@gmail.com) via the CDP relay on the WSL2 default-route
 * gateway, port 9251. Per ~/.claude/rules/playwright.md: any CDP/selector
 * failure is surfaced loudly and the run stops (no silent retry loops).
 *
 * Run: node worker.mjs --dry-run [--cap 50]         (safe: never trashes anything)
 *      node worker.mjs --cap 50                     (live: trashes matched photos)
 *      node worker.mjs --cap 50 --slow              (live, with human-scale pacing restored)
 *      node worker.mjs --cap 50 --walk=grid         (live, exhaustive fallback via the grid walk instead of in-photo)
 *
 * --walk (2026-09-01): the exhaustive fallback (step 5 above) has TWO
 * selectable traversal strategies, kept side by side so they can be A/B'd
 * live rather than assumed -- see walkPhotoView's and walkGrid's own headers
 * for the full history of why neither has been trusted alone. `photo`
 * (default) steps through the open photo view with ArrowRight; `grid` opens
 * each tile directly from the results grid and returns to it between tiles.
 * Both share the exact same matching/deletion path (confirmAndTrash) and
 * only ever differ in HOW a tile gets opened and read.
 */
import { execSync } from 'node:child_process';
import { homedir } from 'node:os';
import { join } from 'node:path';
import { JobQueue } from './lib/queue.mjs';
import {
  parsePanelText,
  findMatchingJob,
  utcDateOf,
  shiftDateDays,
  formatSearchDate,
  groupJobsByDate,
  isRealPhotoTile,
  dedupeTilesByIdentity,
  tileIdentity,
  planAriaMatches,
} from './lib/matcher.mjs';

const QUEUE_PATH = process.env.PICNIC_QUEUE_PATH || join(homedir(), '.local/share/picnic/queue.jsonl');
const DEFAULT_CAP = 50;
const SEARCH_BOX_SELECTOR = 'input[aria-label*="Search" i], input[placeholder*="Search" i]';
// Search-result tiles share this href prefix with non-photo chips (e.g.
// "Favorites") — filtered down to real tiles via isRealPhotoTile().
const RESULT_LINK_SELECTOR = 'a[href^="./search/"]';
// UNVERIFIED LIVE (2026-09-22): the main timeline's own tiles were only ever
// probed for their aria-labels and scroll behaviour, never for their actual
// href shape -- Google Photos' per-item permalink is widely documented as
// "./photo/<id>" (distinct from a search result's "./search/..."), and this
// is the best guess absent a live check. If a real timeline run finds zero
// tiles despite the page clearly showing photos, THIS is the first thing to
// re-probe (aria-label filtering via isRealPhotoTile() is reused unchanged
// and is known-good from the search-results path).
const TIMELINE_TILE_SELECTOR = 'a[href^="./photo/"]';
// Exact aria-label, not a substring match: `[aria-label*="Info"]` also
// hits "Close info" and others (4 elements observed live) and .first()
// on that times out. "Open info" is exact.
const OPEN_INFO_SELECTOR = '[aria-label="Open info" i]';
// The open panel has no stable container selector of its own — verified live
// on 2026-09-01: '[aria-label="Info"]' / '[role="complementary"]' never match.
// The reliable signal that the panel is open is the toolbar button flipping
// from "Open info" to "Close info". Panel TEXT is read by locating the
// container that holds the dimensions string (see readPanelText).
const INFO_PANEL_OPEN_SELECTOR = 'button[aria-label="Close info"]';
// NOT scoped to <button>: these toolbar controls are not necessarily real
// button elements, and a 'button[...]' selector silently matched nothing —
// which sent moveToTrash down its keyboard fallback and deleted nothing at
// all, twice. Match on the aria-label alone. Verified live 2026-09-01.
// Presence of this control is the authoritative "there is another photo in
// this date" signal. A panel-change timeout is NOT: ArrowRight intermittently
// fails to register, and treating that as end-of-day silently abandoned most
// of a date's photos.
const NEXT_PHOTO_SELECTOR = '[aria-label="View next photo" i]';
const TRASH_SELECTOR = '[aria-label="Move to trash" i]';
// Only meaningful under --slow (see stealthDelay below) -- the pacing
// between date-group attempts and between jobs, restored for anyone who
// wants the old bot-avoidance behaviour back.
const PACE_MS_MIN = 4000;
const PACE_MS_MAX = 9000;
// Bound the walk through a single day's search results so a huge day can't
// loop forever. Unmatched jobs for that date attempt just fall through to
// the next date attempt (or needs_review) once the cap is hit.
let VERBOSE = false;
const ARROW_RETRIES = 3;
export const EMPTY_SEARCH_RETRIES = 2;
export const MAX_STEPS_PER_DATE = 80;
// Bound the "scroll for more tiles" loop separately from the tile-open bound
// above -- a date with a huge grid must not scroll forever trying to find
// tiles that were never going to load.
export const MAX_SCROLL_ATTEMPTS_PER_DATE = 6;
// Bound how many times openFirstTile() re-collects and retries opening the
// EXHAUSTIVE fallback's starting tile after a StaleTileError (the held
// reference -- captured before the aria pre-scroll even runs, see
// processDateGroup's `dateFirstTile` -- turned out to already be gone, e.g.
// trashed by the aria phase, or the grid re-rendered under us). Distinct
// from MAX_STEPS_PER_DATE, which bounds the whole date's traversal once
// we're actually in the photo view. Small on purpose: a starting tile that
// still won't open after a few re-collect+retry rounds is not going to
// succeed on one more -- better to report the date EXHAUSTED with nothing
// walked than loop forever on a broken reference.
export const MAX_TILE_OPEN_RETRIES = 3;

// --- --walk=timeline constants (2026-09-22, REWRITTEN) ---------------------
//
// Date search was measured live to be badly incomplete: "March 19, 2026"
// returned 1 tile when the timeline has several that day; "March 17, 2026"
// returned NO results for a day that demonstrably has photos. The main
// timeline (no search) DOES show them.
//
// REWRITE HISTORY: the first version of this walk scrolled the main
// timeline's GRID (like a big date-search result) and opened individual
// candidate tiles by predicted capture time. Live dry-run against 106
// pending jobs (2026-09-22) disproved that design outright: opening a tile
// then returning to the grid (closeAnyOpenPhoto's single Escape) RESET the
// timeline's scroll position to the top every single time -- the grid-return
// mechanism date search relies on does not survive the real site when
// reached from the main library instead of a search results page. 0 matches
// across the whole run. This version instead walks the PHOTO VIEWER itself
// (ArrowRight to the next photo, sticky info panel) exactly like
// walkPhotoView already does after a date search -- see walkTimeline's own
// header below for the full design, and advancePhotoView (shared with
// walkPhotoView) for the hard-won advance-retry logic neither walk
// reimplements independently.
//
// No time/offset calibration is needed at all: every photo's filename is
// checked via findMatchingJob (the only thing that ever authorises a
// trash), so the old candidate-offset machinery (BROAD_CANDIDATE_OFFSETS_SECONDS,
// timelineTileWorthOpening, calibrateOffsetSeconds/parseTileAriaLabel/
// jobMediaTypeMatchesTile imports) is dead code now and has been removed --
// see git history for the removed version if it's ever needed again.
//
// Safety cap on how many photos this walk will ever step through, regardless
// of the date-based stop condition below -- the live library has ~1500
// photos between Sep 2026 and Mar 2026 (Oliver, 2026-09-22), so this is
// >3x that with room for the library to grow before the cap would ever
// realistically bind. Hitting it logs LOUDLY (loud()) since it means either
// the date-based stop condition never fired (a parsing/format problem worth
// knowing about) or the library is far bigger than expected.
export const MAX_TIMELINE_PHOTOS = 5000;
// How many days older than the OLDEST PENDING job's own creationDate the
// panel's parsed capture date has to read before the walk gives up looking
// for anything further back. 2 days (not 1, unlike date search's +/-1-day
// window) -- this walk has no per-job date attempts to retry, so the buffer
// has to absorb a plausible DOM-shape/parsing error in the panel's
// capture-date parse (see matcher.mjs's parsePanelText CAPTURE_DATE_PATTERN,
// still UNVERIFIED LIVE for the older-year "Mon D, YYYY" form specifically)
// -- captureDateMs is now a REAL, offset-corrected UTC instant (2026-09-24
// fix: the GMT offset used to be matched but silently discarded), so this
// buffer no longer needs to absorb timezone error on top of that, just
// genuine parse misses. Kept at 2 days as headroom regardless -- this only
// ever decides when to stop LOOKING, never whether a photo matches
// (findMatchingJob's filename check is unaffected either way), so a wider
// buffer than strictly necessary costs nothing but a little extra walking.
export const TIMELINE_STOP_BUFFER_DAYS = 2;
const TIMELINE_STOP_BUFFER_MS = TIMELINE_STOP_BUFFER_DAYS * 24 * 60 * 60 * 1000;

// CHANGE 2 (2026-09-01): Oliver has decided this worker does not need
// bot-detection avoidance (he already bulk-deletes via a scripted browser
// extension elsewhere), so human-mimicry pacing is OFF by default now.
// --slow restores it for anyone who wants it back. Set by parseArgs' return
// value at the top-level entry point below -- NOT mutated by parseArgs
// itself (unlike VERBOSE), so stealthDelayRange() below stays a pure,
// directly-testable function of an explicit boolean.
let SLOW = false;

// The exhaustive fallback's traversal strategy, once (2026-09-01) rewritten
// unconditionally to walk INSIDE the photo view via ArrowRight (see module
// header) -- disproven live on the same day: 64 "advance did not register"
// events and dates with many photos left mostly unwalked (EXHAUSTED with a
// handful of tiles visited out of dozens). The ORIGINAL grid-return walk
// (open a tile, read the panel, back to the grid via closeAnyOpenPhoto, open
// the next tile) was abandoned earlier for the same reason -- but its actual
// root cause (closeAnyOpenPhoto pressing Escape twice, leaving the search
// results) was found and fixed AFTER the grid walk was already deleted, so
// the fix was never tested against it. Rather than assume either strategy
// is now reliable, both are kept selectable so they can be A/B'd live --
// `photo` (walkPhotoView) stays the default so nothing changes unless asked.
export function parseArgs(argv) {
  const args = { cap: DEFAULT_CAP, dryRun: false, slow: false, walk: 'photo' };
  for (let i = 0; i < argv.length; i++) {
    if (argv[i] === '--cap') args.cap = Number(argv[++i]);
    if (argv[i] === '--dry-run') args.dryRun = true;
    if (argv[i] === '--verbose') VERBOSE = true;
    if (argv[i] === '--slow') args.slow = true;
    if (argv[i].startsWith('--walk=')) {
      const value = argv[i].slice('--walk='.length);
      if (value !== 'photo' && value !== 'grid' && value !== 'timeline') {
        throw new Error(`--walk must be "photo", "grid", or "timeline", got "${value}"`);
      }
      args.walk = value;
    }
    if (argv[i] === '--help' || argv[i] === '-h') {
      console.log(
        'Usage: node worker.mjs [--dry-run] [--cap N] [--slow] [--walk=photo|grid|timeline]\n' +
          '  --dry-run    Search + read candidate info + decide, but never trash. Safe default for a first run.\n' +
          '  --cap N      Max queued jobs to process this run (default 50).\n' +
          '  --slow       Restore human-scale pacing (inter-click jitter, dwell, per-character typing). Off by default.\n' +
          '  --walk=MODE  "photo" (default, date-search + ArrowRight through the photo view), "grid" (date-search,\n' +
          '               opens each tile from the results grid directly), or "timeline" (no search at all -- date\n' +
          '               search was measured badly incomplete live -- opens the main library\'s newest photo and\n' +
          '               walks the photo viewer with ArrowRight, checking every photo\'s filename; see walkTimeline).'
      );
      process.exit(0);
    }
  }
  return args;
}

function getGatewayIp() {
  const route = execSync("ip route show default | awk '{print $3}'").toString().trim();
  if (!route) throw new Error('could not determine WSL2 default-route gateway IP');
  return route;
}

function sleep(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

// Test-only escape hatch: even the fast pacing below still has a real (if
// short) poll interval for correctness waits, which would make the unit
// suite take whole seconds for no benefit, since node:test never touches a
// real browser. Gated by an explicit opt-in env var (never a silent/default
// change); only worker.test.mjs sets this, before importing the module. This
// ALWAYS collapses delays to 0 regardless of --slow -- proving --slow
// actually restores the long delays is done by testing stealthDelayRange()
// directly (a pure function of its `slow` argument), not by timing a real
// sleep.
const FAST_DELAYS = process.env.PICNIC_WORKER_FAST_DELAYS === '1';

/**
 * Pure: what [min, max] ms range a stealth delay would sleep for, given
 * whether --slow is set. Exported so --slow's effect is unit-testable
 * without the suite waiting real seconds (see FAST_DELAYS above).
 */
export function stealthDelayRange(min, max, slow) {
  return slow ? [min, max] : [0, 0];
}

/**
 * Delay that exists ONLY for human-mimicry (inter-click jitter, pre-submit
 * dwell, "dwell reading the panel", inter-job pacing) -- i.e. the pacing
 * Oliver said this worker doesn't need. Off by default (sleeps 0); --slow
 * restores the original random [min, max] jitter. Never used for a wait
 * that real Google Photos UI needs to settle -- see pollDelay() for that.
 */
function stealthDelay(min, max) {
  if (FAST_DELAYS) return sleep(0);
  const [lo, hi] = stealthDelayRange(min, max, SLOW);
  if (lo === hi) return sleep(lo);
  return sleep(lo + Math.random() * (hi - lo));
}

// Fixed short pause between polls of a real async UI condition (info panel
// content, trash confirmation dialog, search-box reachability after
// Escape). NOT a stealth signal -- repeatedly checking local DOM state isn't
// something Google's server can see the cadence of -- so this stays fast
// regardless of --slow; it exists only to avoid busy-looping the CPU while
// genuinely waiting on the page.
function pollDelay() {
  return sleep(FAST_DELAYS ? 0 : 150);
}

function loud(msg) {
  console.error(`\n=== PICNIC WORKER BLOCKER ===\n${msg}\n=============================\n`);
}

/**
 * Friction phrases Google shows for captchas / rate-limits / "confirm it's
 * you" interstitials. Checked against page.textContent('body') before
 * acting on any search or click result. Per rules/social-media-browsing.md
 * this must STOP the whole run, never retry — a retry against a live
 * challenge is exactly what escalates a rate-limit into an account lock.
 */
const FRICTION_PATTERNS = [
  /unusual activity/i,
  /unusual traffic/i,
  /confirm it'?s you/i,
  /verify it'?s you/i,
  /captcha/i,
  /are you a robot/i,
  /too many requests/i,
  /rate limit/i,
  /try again later/i,
  /suspicious activity/i,
];

/**
 * Throws if the current page looks like a captcha/rate-limit/"confirm it's
 * you" interstitial rather than the expected Google Photos UI. Callers
 * catch this the same way as any other job error, which routes through the
 * existing loud() BLOCKER path in runWorker and stops the whole run.
 */
export async function assertNoFriction(page) {
  const bodyText = await page.locator('body').textContent().catch(() => '');
  for (const pattern of FRICTION_PATTERNS) {
    if (pattern.test(bodyText)) {
      throw new Error(`FRICTION DETECTED (matched ${pattern}) — stopping run, not retrying. Page: ${page.url()}`);
    }
  }
}

/**
 * One-time top-level entry to Google Photos for the whole run. Deep
 * per-search page.goto() is a rules violation (navigation in an
 * authenticated app must be through the app's own UI); this is the single
 * allowed top-level navigation.
 */
async function openPhotosHome(page) {
  // NOT 'networkidle': Google Photos holds long-lived connections open, so
  // the network never goes idle. Wait for a real piece of the UI instead.
  await page.goto('https://photos.google.com', { waitUntil: 'domcontentloaded' });
  await assertNoFriction(page);
  await page.locator(SEARCH_BOX_SELECTOR).first().waitFor({ state: 'visible', timeout: 30000 });
  await stealthDelay(1000, 3000); // dwell on the loaded page like a person — pure mimicry, off unless --slow
}

/**
 * Leave the photo detail view, if one is open, so the search box is reachable
 * again. Verified live 2026-09-01: after walking a date's photos the detail
 * view still covers the app, and the search input resolves but is NOT visible,
 * so the next date's search dies with a click timeout. Escape is the app's own
 * dismiss affordance (no goto/reload, per rules/playwright.md).
 *
 * The retry loop itself is a correctness wait (Google's dismiss animation
 * needs a moment), so it's kept regardless of --slow -- but it now POLLS for
 * the search box becoming visible after each Escape (up to 2s) instead of
 * committing to a single fixed dwell, which is both faster when the UI
 * settles quickly and no less safe when it doesn't.
 */
async function closeAnyOpenPhoto(page) {
  // Measured live 2026-09-01, pressing Escape from an open photo in a date's
  // search results:
  //
  //   after search     search=true  trash=false  photoTiles=34
  //   photo open       search=false trash=true   photoTiles=0
  //   after Escape #1  search=true  trash=false  photoTiles=34  <- at the grid
  //   after Escape #2  search=true  trash=false  photoTiles=0   <- LEFT the
  //                                                                results for
  //                                                                the library
  //
  // Two lessons, both learned the hard way:
  //  1. ONE Escape is correct and a SECOND navigates out of the search results
  //     entirely. Looping "press Escape until <condition>" destroyed the grid,
  //     which is why tiles then read as "gone from the grid" and the next
  //     date's search found no search box.
  //  2. Neither signal identifies the grid alone. The search box is hidden
  //     while a photo is open (so it cannot be the only check), and the trash
  //     control is absent both at the grid AND after we have navigated away
  //     (so it cannot be either). "At the grid" is search box visible AND
  //     trash control not visible -- which is also true, correctly, for a
  //     zero-result date where no photo was ever opened, so this returns
  //     immediately there without pressing anything.
  const atGrid = async () => {
    const searchVisible = await page.locator(SEARCH_BOX_SELECTOR).first().isVisible().catch(() => false);
    if (!searchVisible) return false;
    return !(await page.locator(TRASH_SELECTOR).first().isVisible().catch(() => false));
  };

  // Deliberately few attempts: an extra Escape is not harmless here.
  for (let attempt = 0; attempt < 2; attempt++) {
    if (await atGrid()) return;
    await page.keyboard.press('Escape');
    const deadline = Date.now() + (FAST_DELAYS ? 20 : 3000);
    while (Date.now() < deadline) {
      if (await atGrid()) return;
      await pollDelay();
    }
  }
  throw new Error('could not get back to the results grid after 2 Escape presses — UI drift, stopping rather than pressing Escape again (a third would leave the search results)');
}



/**
 * Search Google Photos by calendar date ("<Month> <D>, <YYYY>") using the
 * app's own search box (never goto()'ing a /search/<query> URL directly —
 * see module header). Under --slow, types character-by-character with
 * human-scale delay rather than page.fill()/a plain type(), which pastes the
 * whole string in one DOM mutation and is a well-known automation tell; by
 * default (no bot-avoidance needed) a plain fast type is fine.
 */
async function searchByDate(page, dateStr) {
  const query = formatSearchDate(dateStr);
  await closeAnyOpenPhoto(page);
  const searchBox = page.locator(SEARCH_BOX_SELECTOR).first();
  await searchBox.click();
  await stealthDelay(1000, 4000); // pure mimicry, off unless --slow
  // Clear any prior query with the keyboard rather than fill().
  await page.keyboard.press('Control+A');
  await page.keyboard.press('Delete');
  const typeOptions = !FAST_DELAYS && SLOW ? { delay: 80 + Math.random() * 70 } : undefined; // 80-150ms/char only under --slow
  await page.keyboard.type(query, typeOptions);
  await stealthDelay(2000, 6000); // pre-submit dwell — pure mimicry, off unless --slow
  await page.keyboard.press('Enter');
  await page.locator(RESULT_LINK_SELECTOR).first().waitFor({ state: 'visible', timeout: 20000 }).catch(() => {});
  await assertNoFriction(page);
  await stealthDelay(1500, 3500); // dwell on the results before acting on them — pure mimicry, off unless --slow
  return query;
}

/**
 * Collect this date's real photo/video tiles (filtering Google's own decoy
 * chips, deduping the same photo rendered at multiple grid sizes).
 *
 * Dedupes by IDENTITY (href, falling back to aria-label when href is
 * unreadable -- see matcher.mjs's tileIdentity/dedupeTilesByIdentity), NOT by
 * aria-label alone. 2026-09-12 FINDING: two of Oliver's real duplicate
 * library items (same photo downloaded then separately re-uploaded by a
 * backup tool) share an EXIF capture second and so render a BYTE-IDENTICAL
 * aria-label -- deduping by aria-label alone silently dropped one of them
 * before planAriaMatches ever got a chance to see two candidates and defer
 * the ambiguous job to the exhaustive walk. href is the one attribute that
 * actually tells apart "the same item rendered at another grid size" (same
 * href) from "two distinct items that happen to collide on aria-label text"
 * (different hrefs) -- see dedupeTilesByIdentity's header for the full case.
 */
/**
 * Shared by collectResultTiles (date-search results) and collectTimelineTiles
 * (the main library timeline, 2026-09-22) -- the only difference between the
 * two views is which selector addresses a "tile" at all; filtering (real
 * photo/video tiles only, visible only) and dedup are identical.
 */
async function collectTilesBySelector(page, selector) {
  const links = await page.locator(selector).all();
  const withLabels = [];
  for (const link of links) {
    const ariaLabel = await link.getAttribute('aria-label').catch(() => null);
    if (!isRealPhotoTile(ariaLabel)) continue;
    // VERIFIED LIVE 2026-09-01 (date search): a previous search's result grid
    // stays in the DOM after the next search, collapsed to a 0x0 box. Its
    // tiles still match the selector and still carry aria-labels, so without
    // a visibility filter the walk picks a stale hidden tile and openTile()
    // dies in scrollIntoViewIfNeeded with "element is not visible". Kept for
    // the timeline too even though it's unverified there -- a virtualized
    // list unmounting old tiles rather than hiding them would make this a
    // no-op, never a correctness problem.
    if (!(await link.isVisible().catch(() => false))) continue;
    const href = await link.getAttribute('href').catch(() => null);
    withLabels.push({ locator: link, ariaLabel, href });
  }
  return dedupeTilesByIdentity(withLabels);
}

async function collectResultTiles(page) {
  return collectTilesBySelector(page, RESULT_LINK_SELECTOR);
}

/**
 * Collect the main timeline's currently-mounted tiles (2026-09-22, the
 * `--walk=timeline` strategy -- see walkTimeline's header for why this view
 * exists at all: date search was measured live to be badly incomplete,
 * while the timeline shows everything).
 */
async function collectTimelineTiles(page) {
  return collectTilesBySelector(page, TIMELINE_TILE_SELECTOR);
}

/** Thrown when a held tile locator no longer points at the tile we collected. */
export class StaleTileError extends Error {}

/**
 * Open a tile. Requires bringToFront() first — see module header note.
 *
 * `resultSelector` defaults to RESULT_LINK_SELECTOR (date-search results);
 * the timeline walk (2026-09-22) passes TIMELINE_TILE_SELECTOR instead --
 * everything else about opening a tile (identity-scoped addressing,
 * scroll-then-visibility, StaleTileError) is identical between the two views.
 *
 * Locators from .all() resolve positionally (nth(i)), so any scroll or
 * re-render shifts what they point at. A held locator was observed resolving
 * to an "unlabeled person" chip at nth(52) and hanging the run for 30s.
 * Re-check identity immediately before clicking and bail out to a re-collect
 * instead of clicking whatever now occupies that index.
 */
async function openTile(page, tile, resultSelector = RESULT_LINK_SELECTOR) {
  await page.bringToFront();
  // Address the tile by its aria-label, NOT by grid position. Playwright
  // re-resolves a locator on EVERY call, so a positional locator from .all()
  // is re-evaluated between the identity check and the click -- which is how a
  // click meant for a photo landed on the "Back to search" link at nth(48)
  // (it carries a ./search/ href too), and earlier on an "unlabeled person"
  // chip at nth(52). An identity-scoped locator cannot drift this way.
  //
  // tileLocatorFor also pins :visible, because a previous search's grid stays
  // in the DOM collapsed to 0x0 and carries the SAME aria-labels -- .first()
  // kept resolving to that dead copy, which can never become visible however
  // much we scroll, so dates reported "EXHAUSTED" after a handful of tiles and
  // silently left photos undeleted. :visible excludes a 0x0 element while
  // still matching a real tile that is merely below the fold.
  const locator = tileLocatorFor(page, tile, resultSelector);
  if ((await locator.count()) === 0) {
    throw new StaleTileError(`tile gone from the grid: "${tileIdentity(tile)}"`);
  }
  // Scroll BEFORE the final visibility assertion: the live grid is virtualized,
  // so a genuine tile below the fold is not actionable until scrolled to.
  await locator.first().scrollIntoViewIfNeeded().catch(() => {});
  if (!(await locator.first().isVisible().catch(() => false))) {
    throw new StaleTileError(`tile not actionable after scrolling: "${tileIdentity(tile)}"`);
  }
  await stealthDelay(500, 2000); // pre-click jitter -- pure mimicry, off unless --slow
  await locator.first().click();
  await assertNoFriction(page);
  await stealthDelay(1000, 3000); // post-click settle jitter -- pure mimicry, off unless --slow
}


/**
 * A locator that finds a result tile by its IDENTITY (href when known, plus
 * aria-label) rather than its grid index. aria-labels here look like
 * `Photo - Portrait - Aug 5, 2026, 6:54:07 PM`; they contain commas and
 * spaces but no double quotes, so they drop into an attribute selector as-is
 * (hrefs are ordinary relative paths, same assumption).
 *
 * 2026-09-12: `[aria-label="..."]` ALONE is ambiguous for Oliver's real
 * duplicate library items -- two distinct Google Photos items that share an
 * EXIF capture second render the identical aria-label text, so an
 * aria-label-only selector can match TWO real elements and `.first()` always
 * resolves to the same one, making the second copy permanently unreachable
 * by identity. Pinning href too (when collectResultTiles read one) picks out
 * the SPECIFIC element the caller actually means. Falls back to aria-label
 * alone when href is unavailable (older callers/fixtures), matching the
 * pre-2026-09-12 behaviour exactly.
 */
function tileLocatorFor(page, tile, resultSelector = RESULT_LINK_SELECTOR) {
  const escapedLabel = tile.ariaLabel.replace(/["\\]/g, '\\$&');
  if (tile.href) {
    const escapedHref = tile.href.replace(/["\\]/g, '\\$&');
    return page.locator(`${resultSelector}[href="${escapedHref}"][aria-label="${escapedLabel}"]:visible`);
  }
  return page.locator(`${resultSelector}[aria-label="${escapedLabel}"]:visible`);
}


/**
 * Open the info panel once. Verified live 2026-09-01: the "Open info" BUTTON
 * click is unreliable in the search-context photo view (the toolbar carries
 * hidden duplicates, so a click on .first() times out), while the "i"
 * keyboard shortcut works. And "Close info" is present-but-hidden even when
 * the panel is shut, so its mere existence proves nothing.
 *
 * Readiness is therefore judged on CONTENT — poll until the panel actually
 * yields a FILENAME (2026-09-22: was a dimensions string, which produced a
 * false hang -- job IMG_6636 failed live with "info panel never produced
 * dimensions text after 15s" because the panel rendered a filename fine but
 * never rendered dimensions at all. Matching is filename-only now
 * (lib/matcher.mjs's findMatchingJob), so readiness must be judged on the
 * same signal that actually authorises a match, not a stricter one that can
 * block a photo the matcher no longer needs dimensions from) — rather than
 * on any selector being visible.
 */
async function openInfoPanelOnce(page) {
  await stealthDelay(500, 1500); // pure mimicry, off unless --slow
  // The panel is sticky: once opened it stays open as you move between photos
  // and across searches. Pressing "i" when it is ALREADY open closes it, which
  // is what broke the second date of the first successful walk. Only toggle it
  // when it is genuinely shut. Verified live 2026-09-01.
  const already = await readPanelText(page);
  if (parsePanelText(already).filename) {
    await stealthDelay(400, 1200); // pure mimicry, off unless --slow
    return;
  }
  // Wait for the photo view to actually exist before pressing anything. With
  // the mimicry delays removed, 'i' was being pressed while the view was still
  // opening, so the keystroke went nowhere and the poll below then waited the
  // full 15s for a panel nobody had opened. This was the fast-mode failure:
  // the same run passed with --slow purely because the jitter happened to
  // cover the transition.
  await page
    .locator(TRASH_SELECTOR)
    .first()
    .waitFor({ state: 'attached', timeout: FAST_DELAYS ? 100 : 15000 })
    .catch(() => {});
  await page.keyboard.press('i');

  // Real correctness wait: poll until the panel actually yields a FILENAME
  // (2026-09-22: was a dimensions string -- see this function's header for
  // why that produced a false 15s timeout on a photo whose panel never
  // rendered dimensions but did render its filename). The poll interval
  // (pollDelay) stays fast regardless of --slow -- it's a local content
  // check, not a network action Google could see the cadence of.
  const deadline = Date.now() + (FAST_DELAYS ? 50 : 15000);
  let attempts = 0;
  while (Date.now() < deadline) {
    await pollDelay();
    const text = await readPanelText(page);
    if (parsePanelText(text).filename) {
      await stealthDelay(800, 2000); // "dwell reading the panel" — pure mimicry, off unless --slow
      return;
    }
    // Re-press rather than trusting the single keystroke above: if it landed
    // mid-transition it was simply lost, and polling forever for a panel that
    // was never opened is the failure this replaces. Re-press on a slower
    // cadence than the poll so we never toggle it shut again immediately.
    attempts += 1;
    if (attempts % 8 === 0) {
      await page.keyboard.press('i');
    }
    // Second chance: a VISIBLE "Open info" button, if one is actually there.
    const button = page.locator(OPEN_INFO_SELECTOR).first();
    if (await button.isVisible().catch(() => false)) {
      await button.click().catch(() => {});
    }
  }
  throw new Error('info panel never produced filename text after 15s — selector/UI drift, stopping rather than guessing');
}

/**
 * Pure decision logic for readPanelText below, extracted so it is directly
 * unit-testable: page.evaluate(callback) serializes `callback` and runs it
 * inside an isolated BROWSER realm with no access to anything else in this
 * file, so a selection algorithm that lived entirely inside that callback
 * could never be exercised by a Node-side test -- only whatever canned
 * string a test fixture stood in for its final output, never the tiering
 * logic itself. This is why the 2026-09-23 DOM-shape bug (see below)
 * shipped untested at the level that actually mattered.
 *
 * `candidateSets` is `{ detailsAndFile, dimsAndFile, fileOnly }`, each an
 * array of raw innerText strings -- readPanelText's evaluate() callback does
 * the (cheap, DOM-side) FILTERING into these three tiers, and this function
 * does the (Node-side, testable) "which tier, and which smallest element
 * within it" DECISION. Tier priority, smallest-first within each:
 *
 *   1. detailsAndFile -- an element containing BOTH the panel's own
 *      "Details" heading AND the filename. VERIFIED LIVE 2026-09-23
 *      (Oliver's own probe): the capture-date lines ("Sep 22" /
 *      "Yesterday, 6:25 PM" / "GMT-04:00") sit ABOVE the filename in the
 *      DOM, inside the SAME "Details" container but OUTSIDE the smaller
 *      dimensions+filename element the old (DIMS+FILE-only) selector
 *      picked -- which is why captureDateMs (matcher.mjs) came back null
 *      on every single photo of a live 449-photo run: the text it was
 *      ever given structurally could not contain the date lines.
 *      Preferring this tier first fixes that without touching
 *      filename/dimensions parsing at all (parsePanelText still finds
 *      them fine in the larger text).
 *   2. dimsAndFile -- the OLD (2026-09-01) selector's behaviour, kept as a
 *      fallback for whatever DOM shape doesn't carry a "Details" heading
 *      at all (still fine for filename+dims parsing, just never yields a
 *      capture date).
 *   3. fileOnly -- dimensions can legitimately never render (2026-09-22:
 *      job IMG_6636 failed live with "info panel never produced dimensions
 *      text after 15s" even though its filename was on screen the whole
 *      time) -- matching is filename-only (matcher.mjs's findMatchingJob),
 *      so this must never block a photo from being read at all.
 */
export function selectPanelText({ detailsAndFile = [], dimsAndFile = [], fileOnly = [] } = {}) {
  const bySize = (a, b) => a.length - b.length;
  if (detailsAndFile.length) return [...detailsAndFile].sort(bySize)[0];
  if (dimsAndFile.length) return [...dimsAndFile].sort(bySize)[0];
  if (fileOnly.length) return [...fileOnly].sort(bySize)[0];
  return '';
}

async function readPanelText(page) {
  // Verified live: the details block is an unlabelled div, found by content
  // rather than a selector, which Google does not give us a stable one for.
  // The FILTERING happens here, DOM-side inside evaluate() (cheap: a real
  // Google Photos page carries hundreds of div/c-wiz/aside elements, and
  // only the handful that actually match ever cross back over the bridge)
  // -- the actual TIERED DECISION is selectPanelText() above, kept OUTSIDE
  // evaluate() specifically so it's unit-testable.
  //
  // VISIBLE-ONLY (2026-09-23 live finding): a 449-photo run showed the
  // SAME stale filename ("IMG_2201.PNG") read back on ~10 different
  // photos scattered across that run -- some element holding an EARLIER
  // photo's text was still present in the DOM (a prior viewer instance,
  // or a panel Google keeps around hidden) and occasionally won the
  // smallest-element tiebreak over the CURRENT, genuinely visible panel.
  // offsetWidth/offsetHeight > 0 excludes a hidden/collapsed element the
  // same way jQuery's :visible does, without needing a stable selector for
  // "the current viewer" that Google doesn't expose. This can't fully
  // replace the filename-must-change poll (waitForTimelineAdvanceConfirmed)
  // -- a stale-but-currently-visible element is still possible -- so both
  // defenses stay in place together.
  const candidateSets = await page
    .evaluate(() => {
      const DIMS = /\d{3,5}\s*[\u00d7x]\s*\d{3,5}/;
      const FILE = /[A-Za-z0-9._-]+\.(HEIC|JPG|JPEG|PNG|MOV|MP4)\b/i;
      const DETAILS = /Details/;
      const isVisible = (el) => el.offsetWidth > 0 && el.offsetHeight > 0;
      const all = Array.from(document.querySelectorAll('div,c-wiz,aside'))
        .filter(isVisible)
        .map((el) => el.innerText || '');
      return {
        detailsAndFile: all.filter((t) => DETAILS.test(t) && FILE.test(t)),
        dimsAndFile: all.filter((t) => DIMS.test(t) && FILE.test(t)),
        fileOnly: all.filter((t) => FILE.test(t)),
      };
    })
    .catch(() => ({ detailsAndFile: [], dimsAndFile: [], fileOnly: [] }));
  return selectPanelText(candidateSets);
}

/**
 * A wheel event scrolls whatever sits under the pointer. Playwright's pointer
 * starts at (0,0), over Google Photos' header, so without this the main
 * timeline never scrolled at all (2026-09-22: every timeline run stopped after
 * "10 consecutive scroll(s) with no new tile"). Search walks only worked by
 * accident, because an earlier tile click had left the pointer over the grid.
 */
export async function pointAtGrid(page) {
  const { width, height } = page.viewportSize() ?? { width: 1280, height: 800 };
  await page.mouse.move(width / 2, height / 2);
}

/**
 * Click the centre of the photo viewer to re-establish KEYBOARD focus on
 * it. Live finding 2026-09-23 (a 449-photo timeline run): after moveToTrash
 * fell back to clicking the toolbar trash control (its '#' shortcut path
 * having failed to even show the confirm dialog), keyboard focus ended up
 * on BODY in a way that did NOT relay ArrowRight to Google's own handler --
 * three straight ArrowRight attempts, then the "View next photo" click
 * fallback, ALL failed to advance, and the walk wrongly concluded
 * end-of-library with 103 jobs still pending (real photos going back to
 * March). releaseFocus()'s plain blur-to-document is not the same as this:
 * blurring only removes focus from whatever CONTROL last had it (a button),
 * it does not re-establish focus ON THE VIEWER when the viewer itself has
 * lost it entirely -- only a genuine click inside the viewer area does
 * that. Used both before pressing '#' (moveToTrash -- the suspected cause
 * of its own "confirmation dialog not shown" failures) and before/between
 * ArrowRight retries in advanceTimelinePhotoView.
 */
export async function focusViewerCenter(page) {
  const { width, height } = page.viewportSize() ?? { width: 1280, height: 800 };
  await page.mouse.click(width / 2, height / 2).catch(() => {});
}

/**
 * Scroll the results grid to load more of the day's tiles. `collectResultTiles`
 * only sees what is currently rendered -- a big day's grid is virtualized, so
 * concluding a date is exhausted just because no unvisited tile is on-screen
 * would silently leave photos unwalked. The post-scroll wait here is a real
 * correctness wait (the grid needs a moment to fetch/render newly-scrolled-
 * into-view tiles before the caller re-collects), not human mimicry, so it
 * stays short and fixed regardless of --slow.
 */
async function scrollResults(page) {
  await pointAtGrid(page);
  await page.mouse.wheel(0, 600 + Math.random() * 400);
  await sleep(FAST_DELAYS ? 0 : 500);
}

/**
 * Scroll the results grid back UP -- toward tiles the `grid` walk strategy
 * already knows about (tracked in its `seen` map) but that scrolled out of
 * the mounted window as later content loaded. RECOVERED FROM HISTORY
 * 2026-09-01 (see walkGrid's header) -- only walkGrid uses this; walkPhotoView
 * never scrolls the grid at all.
 *
 * A virtualized grid only ever mounts a WINDOW of tiles. walkGrid's own
 * pre-scroll (shared with the aria fast path's pre-scroll, see
 * processDateGroup) can run that window well past an early tile before the
 * walk even gets to it -- scrolling DOWN can never recover such a tile
 * (there's nothing further to reveal, and the window only follows the tail
 * forward as new content loads), so this is the only path back to a tile
 * that fell behind. A negative wheel delta is Google Photos' own "scroll up"
 * gesture. Same real-correctness settle wait as scrollResults -- not human
 * mimicry -- so it stays short and fixed regardless of --slow.
 */
async function scrollResultsUp(page) {
  await pointAtGrid(page);
  await page.mouse.wheel(0, -(600 + Math.random() * 400));
  await sleep(FAST_DELAYS ? 0 : 500);
}

/**
 * True when `err` (or the page itself) indicates the tab/browser this worker
 * was driving has gone away -- Oliver's real Chrome, which can close a tab
 * out from under this run at any time (he uses the browser, or Chrome closes
 * it). This is not a bug to retry past; it just means nothing further can be
 * learned this run.
 */
export function isPageClosedError(page, err) {
  if (page?.isClosed?.()) return true;
  return /Target page, context or browser has been closed/i.test(String(err?.message || err || ''));
}

/**
 * Pure decision: was a trash actually CONFIRMED? Exported for tests (the
 * live moveToTrash below is the only caller, gathering these three booleans
 * from the real page).
 *
 * 2026-09-22 FIX: `dialogConfirmed` is now REQUIRED, not just a hint --
 * `toastShown`/`panelChanged` alone are not proof. Job
 * B4D8DDA7-880E-4641-BF36-69727D7F98AE_Original.JPG was recorded 'trashed'
 * (3 copies) but was still live in Google Photos: the old settled() returned
 * true purely because the info panel's text changed/emptied, even though the
 * "Move to trash" confirm dialog never actually appeared (and so nothing was
 * ever really deleted). A toast or panel change can happen for reasons that
 * have nothing to do with a trash succeeding (view navigating on its own,
 * panel re-rendering) -- the CONFIRM DIALOG being shown and clicked is the
 * one signal that ties directly to the destructive action itself.
 */
export function isTrashConfirmed({ dialogConfirmed, toastShown, panelChanged }) {
  return Boolean(dialogConfirmed) && (Boolean(toastShown) || Boolean(panelChanged));
}

/**
 * Move the currently-open photo to trash via the UI. NEVER permanent-delete.
 *
 * Returns true only if the deletion was CONFIRMED -- see isTrashConfirmed's
 * header for the 2026-09-22 fix and the false "trashed" it corrects. "Open
 * info" and "View next photo" both turned out to have hidden duplicates that
 * make a .first() click silently time out, so a click that merely resolves
 * is not evidence the photo was trashed — and a job wrongly marked "trashed"
 * is one we would never revisit.
 */
export async function moveToTrash(page, panelTextBefore) {
  // Ordering matters, and this got it wrong twice:
  //  - '#' is Google Photos' own move-to-trash shortcut and is the ONLY path
  //    ever observed to actually delete (the verified IMG_1418.HEIC deletion
  //    went through it).
  //  - '#' opens a CONFIRMATION DIALOG, which lays a scrim over the page
  //    (<div class="LB4Y1">, data-back-to-cancel="true"), so clicking the
  //    toolbar control while it is up dies with "subtree intercepts pointer
  //    events" — exactly how the previous version failed on IMG_1447.PNG.
  // So: press, accept the dialog, check; only then consider a click fallback.
  // Real correctness wait: the confirmation dialog takes a moment to render
  // after '#' or a toolbar click. Poll for it rather than committing to a
  // fixed dwell first -- a fast-rendering dialog doesn't cost the full wait,
  // and a slow one still gets caught.
  const waitForConfirmButton = async () => {
    const confirm = page
      .locator('button:has-text("Move to trash"), button:has-text("Delete"), button:has-text("Move to bin")')
      .first();
    const deadline = Date.now() + (FAST_DELAYS ? 20 : 3000);
    while (Date.now() < deadline) {
      if (await confirm.isVisible().catch(() => false)) return confirm;
      await pollDelay();
    }
    return null;
  };

  const confirmDialog = async () => {
    const confirm = await waitForConfirmButton();
    if (!confirm) return false;
    await stealthDelay(600, 1500); // pure mimicry, off unless --slow
    await confirm.click();
    return true;
  };

  // Polls for the two POST-dialog signals (never authoritative on their own
  // -- see isTrashConfirmed) and reports which one (if either) fired, so the
  // caller can feed both into the actual confirmation decision.
  const settled = async () => {
    const deadline = Date.now() + (FAST_DELAYS ? 50 : 12000);
    while (Date.now() < deadline) {
      await pollDelay();
      const toastShown = await page.locator('text=/moved to (trash|bin)/i').first().isVisible().catch(() => false);
      if (toastShown) return { toastShown: true, panelChanged: false };
      const now = await readPanelText(page);
      const panelChanged = (Boolean(now) && now !== panelTextBefore) || (!now && Boolean(panelTextBefore));
      if (panelChanged) return { toastShown: false, panelChanged: true };
    }
    return { toastShown: false, panelChanged: false };
  };

  await stealthDelay(500, 2000); // pure mimicry, off unless --slow
  // Live finding 2026-09-23: a run's '#' presses sometimes never showed the
  // confirm dialog at all ("confirmation dialog: not shown"), immediately
  // preceding the SAME run's viewer losing keyboard focus entirely
  // (ArrowRight producing no advance, activeElement=BODY) -- both point at
  // the SAME root cause, focus having drifted off the viewer by the time
  // this runs. See focusViewerCenter's own header for the full story.
  await focusViewerCenter(page);
  if (VERBOSE) console.log("    trash: pressing '#'");
  await page.keyboard.press('#');
  // Sticky across both attempts below: once EITHER path (the '#' shortcut or
  // the toolbar-click fallback) actually shows and clicks the confirm
  // dialog, that fact must not be lost even if the OTHER path's dialog
  // attempt later comes back empty (e.g. the fallback fires after the photo
  // is already gone, so its own confirmDialog() naturally finds nothing).
  let dialogConfirmed = await confirmDialog();
  if (VERBOSE) console.log(`    trash: confirmation dialog ${dialogConfirmed ? 'accepted' : 'not shown'}`);
  if (dialogConfirmed) {
    const outcome = await settled();
    if (isTrashConfirmed({ dialogConfirmed, ...outcome })) return true;
  }

  // Fallback: only now, with no dialog scrim in the way, try the control.
  // Same rule applies here -- clicking the control is not itself a trash,
  // only its own confirm dialog appearing and being clicked counts.
  const candidates = await page.locator(TRASH_SELECTOR).all();
  for (const candidate of candidates) {
    if (await candidate.isVisible().catch(() => false)) {
      if (VERBOSE) console.log('    trash: falling back to clicking the visible control');
      await candidate.click();
      if (await confirmDialog()) dialogConfirmed = true;
      break;
    }
  }
  // No confirm dialog on EITHER path -- refuse regardless of any panel/toast
  // signal. This is exactly the B4D8DDA7... false positive: a panel text
  // change with no dialog ever shown must never read as confirmed.
  if (!dialogConfirmed) return false;
  const outcome = await settled();
  return isTrashConfirmed({ dialogConfirmed, ...outcome });
}


/**
 * Shared by the aria fast path and the exhaustive walk below: the currently
 * open photo's panel has just been read and parsed, and (by exact filename --
 * lib/matcher.mjs's findMatchingJob, already checked by the caller) confirmed
 * to be `job`'s photo. Live only, trashes it and records
 * the outcome on the queue; dry-run only logs. This is the ONLY place that
 * ever calls moveToTrash -- whether the tile got opened via the aria
 * pre-filter or the exhaustive walk makes no difference to how a match gets
 * confirmed or trashed.
 */
/**
 * `isDuplicateCopy` (added for Oliver's real duplicate library items -- a
 * photo downloaded to his phone and then separately re-uploaded by a backup
 * tool gives Google Photos two distinct items with the same filename+dims,
 * same search date): true when `job` was ALREADY confirmed+trashed once
 * earlier in this same date's walk (tracked by the caller's `matchedJobs`
 * set) and this is a further copy of it, found at a DIFFERENT tile. The
 * "never guess" rule is unchanged either way -- the caller only reaches here
 * after findMatchingJob already confirmed this exact job's filename against
 * the parsed panel, whether that job came from `remaining` (first copy) or
 * `matchedJobs` (a further one).
 *
 * A duplicate trash must NOT overwrite the first copy's `comparison`/
 * `attempts` bookkeeping (that recorded the confirmation that made the job
 * 'trashed' in the first place) -- it only advances `copiesTrashed`, which
 * schema-old jobs implicitly read as 1 (see queue.mjs; the field is purely
 * additive, so the iOS app and queue-server.mjs's JSON responses are
 * unaffected by its absence on older records).
 *
 * Returns whether the trash was CONFIRMED (false for dry-run, which never
 * attempts one) -- callers use this, not a panel-text diff, to know whether
 * the view has moved on. A confirmed trash always removes the current photo
 * from the results, so the view HAS moved on (to whatever's next, or closed
 * if it was the day's last) even when the new panel's text happens to be
 * byte-identical to what was just trashed -- exactly the duplicate-copy case
 * this exists for (two items with the same filename/dims/camera info render
 * the same panel text). A text diff genuinely cannot tell that apart from
 * "never moved"; the confirmation itself is the only reliable signal.
 */
async function confirmAndTrash(page, job, parsed, text, query, queue, dryRun, isDuplicateCopy = false) {
  if (dryRun) {
    console.log(`[dry-run WOULD TRASH${isDuplicateCopy ? ' duplicate copy of' : ''}] ${job.filename} (search ${query})`);
    return false;
  }
  const confirmed = await moveToTrash(page, text);
  if (isDuplicateCopy) {
    if (confirmed) {
      // Read the job's CURRENT persisted state (not the possibly-stale `job`
      // reference the caller is holding) so a second or third copy in the
      // same walk still increments from the real count, not from 1 every
      // time.
      const current = queue.getById(job.id);
      const copiesTrashed = (current.copiesTrashed ?? 1) + 1;
      queue.update(job.id, { copiesTrashed });
      console.log(`[trashed] ${job.filename}: duplicate copy #${copiesTrashed} (search ${query})`);
    } else {
      // Do NOT downgrade status: the job is genuinely 'trashed' already from
      // its first copy. Surface the unconfirmed duplicate via `error` alone
      // so a human can check Google Photos for a stray copy, without
      // rewriting a real deletion back to needs_review.
      queue.update(job.id, { error: `a duplicate copy matched but its trash action was not confirmed (search ${query})` });
      console.log(`[needs_review] ${job.filename}: duplicate matched but trash not confirmed (search ${query})`);
    }
    return confirmed;
  }
  const comparison = { searchDate: query, matchedFilename: parsed.filename, pixelWidth: parsed.pixelWidth, pixelHeight: parsed.pixelHeight };
  if (confirmed) {
    queue.update(job.id, { status: 'trashed', comparison, copiesTrashed: 1, attempts: job.attempts + 1 });
    console.log(`[trashed] ${job.filename} (search ${query})`);
  } else {
    // Matched the right photo but could not prove the trash took. Leave it
    // for a human rather than recording a deletion that may not have
    // happened.
    queue.update(job.id, {
      status: 'needs_review',
      comparison,
      error: 'matched but trash action not confirmed',
      attempts: job.attempts + 1,
    });
    console.log(`[needs_review] ${job.filename}: matched but trash not confirmed (search ${query})`);
  }
  return confirmed;
}

/**
 * Bounded attempt to get INTO the photo view, starting from `candidateTile`
 * (the first tile a caller already collected -- for walkPhotoView, the
 * date's first tile captured by processDateGroup BEFORE the aria phase's
 * own pre-scroll runs; for walkTimeline (2026-09-22), the timeline's
 * newest tile). `collectFn`/`resultSelector` let each walk supply its own
 * "collect visible tiles" function and selector (collectResultTiles/
 * RESULT_LINK_SELECTOR by default for date search; collectTimelineTiles/
 * TIMELINE_TILE_SELECTOR for the timeline) while sharing everything else.
 * A held tile reference can go stale the same way any tile locator can (the
 * aria phase trashed it, or the grid re-rendered under us) -- openTile()
 * throws StaleTileError exactly as it does everywhere else it's called.
 * Re-collect fresh and retry rather than giving up over one stale
 * reference; MAX_TILE_OPEN_RETRIES bounds it so a genuinely broken run
 * can't loop forever. Returns the tile actually opened, or null if nothing
 * could be opened at all.
 */
async function openFirstTile(page, candidateTile, { collectFn = collectResultTiles, resultSelector = RESULT_LINK_SELECTOR } = {}) {
  let tile = candidateTile;
  for (let attempt = 0; attempt < MAX_TILE_OPEN_RETRIES; attempt++) {
    if (!tile) {
      const fresh = await collectFn(page);
      tile = fresh[0] ?? null;
    }
    if (!tile) return null; // nothing left to open at all
    try {
      await openTile(page, tile, resultSelector);
      return tile;
    } catch (err) {
      if (!(err instanceof StaleTileError)) throw err;
      tile = null; // force a fresh re-collect on the next attempt
    }
  }
  return null;
}

/**
 * Poll readPanelText() until it differs from `previousText`, or give up
 * after a real (if short) timeout. This is the ONLY way the traversal below
 * can tell "moved to the next photo" from "there is no next photo" --
 * ArrowRight is a keypress with no return value, and per the module header,
 * advancement must be confirmed by PANEL CONTENT changing, never by the
 * keypress merely resolving. An unchanged panel after the deadline means the
 * end of the day's results -- a normal, expected outcome -- so this returns
 * null rather than throwing (contrast openInfoPanelOnce, whose timeout IS a
 * genuine UI-drift error: the panel not opening AT ALL is never expected).
 */
/**
 * Drop focus before sending a photo-view shortcut.
 *
 * Measured live 2026-09-01: after opening a photo and its info panel, focus
 * sits on whichever control was last interacted with -- observed as
 * BUTTON[Open info] and A[Back to search]. Those swallow ArrowRight, so the
 * traversal advanced zero photos and every date reported EXHAUSTED after one.
 * Blurring lets the key reach the document, where Google's own handler picks
 * it up.
 */
async function releaseFocus(page) {
  await page
    .evaluate(() => {
      const el = document.activeElement;
      if (el && typeof el.blur === 'function' && el !== document.body) el.blur();
    })
    .catch(() => {});
}

async function waitForPanelChange(page, previousText) {
  const deadline = Date.now() + (FAST_DELAYS ? 30 : 8000);
  while (Date.now() < deadline) {
    await pollDelay();
    const text = await readPanelText(page);
    if (text && text !== previousText) return text;
  }
  return null;
}

/**
 * Advance the open photo view to the NEXT photo in whatever sequence is
 * currently open (a date's search results for walkPhotoView, or the main
 * library for walkTimeline, 2026-09-22) and return its panel text -- or
 * null if genuinely at the end of the sequence, or if advancing failed
 * outright (those two cases are indistinguishable from here; see below).
 *
 * EXTRACTED 2026-09-22 from walkPhotoView (previously the only caller) so
 * walkTimeline could reuse it rather than reimplement it -- this is the
 * single most hard-won piece of either walk (see the module header's "5
 * distinct reasons" the old grid-return design died, and the "64 advance
 * did not register" events from a live run): ArrowRight does not always
 * register, even with focus correctly released and the next-photo control
 * present -- the SAME date walked 7 photos on one run and 1 on the next
 * with identical code. A timeout therefore cannot be read as "end of the
 * sequence" (that inference is what silently abandoned most of a date
 * before this fix) -- retry the press, and treat the ABSENCE of the
 * next-photo control as the authoritative end-of-sequence signal instead
 * of a timeout. Prefer CLICKING the next-photo control (picking the
 * genuinely visible match out of its several same-labelled elements -- the
 * same hidden-duplicate trap that made the trash button silently do
 * nothing) over the key, which is kept only as a fallback when no visible
 * control is found.
 *
 * `logPrefix` is purely cosmetic (VERBOSE logging), letting each caller
 * label its own step count ("[photo N]" / "[timeline photo N]").
 */
async function advancePhotoView(page, currentText, logPrefix = '') {
  let next = null;
  for (let attempt = 0; attempt < ARROW_RETRIES && next == null; attempt++) {
    const candidates = await page.locator(NEXT_PHOTO_SELECTOR).all();
    let clicked = false;
    for (const candidate of candidates) {
      if (await candidate.isVisible().catch(() => false)) {
        await candidate.click().catch(() => {});
        clicked = true;
        break;
      }
    }
    if (!clicked) {
      await releaseFocus(page);
      await page.keyboard.press('ArrowRight');
    }
    next = await waitForPanelChange(page, currentText);
    if (next != null) break;
    if (candidates.length === 0) break; // genuinely the last photo of the sequence
    if (VERBOSE) {
      console.log(`  ${logPrefix} advance did not register via ${clicked ? 'click' : 'ArrowRight'}, retrying (${attempt + 1}/${ARROW_RETRIES})`);
    }
  }
  if (next == null && VERBOSE) {
    // Either genuinely the last photo of the sequence, or ArrowRight did not
    // take (e.g. focus sitting somewhere that swallows it). Those look
    // identical from here, so say so rather than silently calling it done.
    const focus = await page
      .evaluate(() => {
        const a = document.activeElement;
        return a ? `${a.tagName}[${(a.getAttribute('aria-label') || a.className || '').toString().slice(0, 40)}]` : 'none';
      })
      .catch(() => 'unknown');
    console.log(`  ${logPrefix} ArrowRight produced no panel change (end of sequence, or the key was swallowed). activeElement=${focus}`);
  }
  return next;
}

/**
 * The exhaustive fallback (REWRITTEN 2026-09-01, see module header for the
 * five live failures that killed the old grid-return design). Opens the
 * date's first tile ONCE, opens the info panel ONCE, then steps forward with
 * ArrowRight -- never returning to the results grid mid-date -- reading and
 * confirming the panel at each stop until every job is matched, the panel
 * stops changing (genuinely reached the end of the day), or
 * MAX_STEPS_PER_DATE is hit.
 *
 * `dateFirstTile` is the tile processDateGroup captured from the very FIRST
 * collectResultTiles() call, before the aria phase's own pre-scroll could
 * run the mounted window past it -- so this never depends on where the grid
 * happens to be scrolled to when the aria phase hands off.
 *
 * `matchedJobs` (added for Oliver's real duplicate library items -- see
 * confirmAndTrash's header): jobs already confirmed+trashed once earlier in
 * THIS date's search (by the aria phase, or by an earlier photo in this same
 * walk), shared by reference with the caller so it also picks up whatever
 * this walk itself matches. A duplicate copy of one of these can appear
 * ANYWHERE in the rest of the day's order -- there is no way to know it
 * won't -- so once anything has matched, the walk no longer stops the moment
 * `remaining` empties; it keeps stepping to the genuine end of the day (the
 * "no next photo" signal) or MAX_STEPS_PER_DATE, checking every subsequent
 * photo against matchedJobs too. Only when NEITHER remaining nor matchedJobs
 * has anything left to check is there truly nothing this walk can still find.
 */
async function walkPhotoView(page, dateFirstTile, unmatchedJobs, query, queue, dryRun, matchedJobs = new Set()) {
  let remaining = unmatchedJobs;
  if (remaining.length === 0 && matchedJobs.size === 0) return { stillUnmatched: remaining };

  const tile = await openFirstTile(page, dateFirstTile);
  if (!tile) {
    // Nothing openable at all -- e.g. the aria phase's own trashes consumed
    // every tile this date ever had. Not a bug, just nothing left to walk.
    console.log(`[date ${query}] EXHAUSTED: 0 photo(s) visited (nothing left to open), ${remaining.length} job(s) still unmatched`);
    return { stillUnmatched: remaining };
  }

  // Opened ONCE for the whole date -- the panel is sticky and stays open as
  // ArrowRight steps through the rest of the day (see openInfoPanelOnce's
  // header and the module header). Never called again per-photo below:
  // pressing "i" while it's already open CLOSES it.
  await openInfoPanelOnce(page);

  let steps = 0;
  let boundHit = false;
  let text = await readPanelText(page);

  // See matchedJobs' header above: once anything has matched, a duplicate of
  // it could be anywhere later in the day, so the loop no longer stops just
  // because `remaining` emptied -- only when there's truly nothing left
  // either unmatched or worth re-checking for a further copy.
  while (remaining.length > 0 || matchedJobs.size > 0) {
    if (steps >= MAX_STEPS_PER_DATE) {
      boundHit = true;
      break;
    }
    steps += 1;

    const parsed = parsePanelText(text);
    if (VERBOSE) {
      console.log(
        `  [photo ${steps}] filename=${parsed.filename ?? '(none)'} ` +
          `dims=${parsed.pixelWidth ?? '?'}x${parsed.pixelHeight ?? '?'}` +
          (parsed.filename ? '' : ` rawLen=${(text || '').length} raw="${(text || '').slice(0, 100)}"`)
      );
    }
    // Check this photo against unmatched jobs AND jobs already matched
    // earlier this date -- a hit against the latter is a further copy of a
    // job we've already confirmed once (findMatchingJob still requires the
    // filename to agree exactly; "already matched" only widens WHICH jobs we
    // compare against, never how a match is confirmed).
    const candidateJobs = matchedJobs.size > 0 ? [...remaining, ...matchedJobs] : remaining;
    const job = findMatchingJob(candidateJobs, parsed);
    let advancedByDelete = false;

    if (job) {
      const isDuplicateCopy = matchedJobs.has(job);
      const confirmed = await confirmAndTrash(page, job, parsed, text, query, queue, dryRun, isDuplicateCopy);
      if (!isDuplicateCopy) {
        remaining = remaining.filter((j) => j !== job);
        matchedJobs.add(job);
      }
      if (!dryRun) {
        const afterTrash = await readPanelText(page);
        if (confirmed) {
          // A CONFIRMED trash always removes the current photo from the
          // results -- the view HAS moved on (to whatever's next, or closed
          // if this was the day's last photo), which is settled fact once
          // confirmAndTrash reports it, not something to re-derive from a
          // text diff. Diffing would fail exactly for a duplicate copy
          // (2026-09-12 finding): two items with the same filename/dims/
          // camera info render BYTE-IDENTICAL panel text, so
          // `afterTrash !== text` reads false even though the view is now
          // showing a genuinely different (duplicate) photo -- which used to
          // make the walk try to ArrowRight past it instead of examining it,
          // silently skipping the very duplicate this feature exists to
          // catch. Always take the fresh read, whether or not it looks
          // different from `text`.
          text = afterTrash;
          advancedByDelete = true;
        } else if (afterTrash && afterTrash !== text) {
          // Trash was not confirmed (rare), but the panel moved anyway --
          // same handling this branch always had.
          text = afterTrash;
          advancedByDelete = true;
        }
      }
    }

    if (!advancedByDelete) {
      const next = await advancePhotoView(page, text, `[photo ${steps}]`);
      if (next == null) break; // genuinely the last photo of the day, or ArrowRight did not take
      text = next;
    }
  }

  if (remaining.length > 0) {
    if (boundHit) {
      console.log(`[date ${query}] ABANDONED: MAX_STEPS_PER_DATE (${MAX_STEPS_PER_DATE}) reached, ${remaining.length} job(s) still unmatched`);
    } else {
      console.log(`[date ${query}] EXHAUSTED: ${steps} photo(s) visited, ${remaining.length} job(s) still unmatched`);
    }
  }

  return { stillUnmatched: remaining };
}

/**
 * GRID-BASED exhaustive walk -- the `--walk=grid` strategy, RECOVERED FROM
 * HISTORY 2026-09-01 (commit "Replace the grid-return exhaustive walk with
 * in-photo-view traversal") rather than rewritten, because it carried
 * several hard-won fixes worth keeping intact: a cumulative `seen` set
 * judged on new LABELS (never tile counts, since the grid is virtualized and
 * a windowed swap can hold the on-screen count flat while the tiles
 * underneath move on entirely), a scroll budget separate from the aria fast
 * path's own pre-scroll budget, `visited.add` only after a tile genuinely
 * opens, and bounded per-tile retries ending in an explicit `unreachable`
 * record so EXHAUSTED can mean "every seen label was visited or explicitly
 * given up on" and nothing was silently skipped.
 *
 * It was retired in favour of walkPhotoView after topping out at 2/27 tiles
 * live -- but its actual root cause (closeAnyOpenPhoto pressing Escape
 * TWICE, which the second time leaves the search results entirely rather
 * than returning to the grid) was found and fixed in a LATER commit, after
 * this walk was already deleted, so the fix was never tested against it (see
 * the module header). closeAnyOpenPhoto below is that already-corrected,
 * shared function -- not recovered from history -- so this run is the first
 * time the grid walk has ever run with it.
 *
 * Opens each tile directly from the results grid via its identity-scoped
 * locator (openTile/tileLocatorFor), reads + parses the panel
 * (openInfoPanelOnce/readPanelText/parsePanelText), confirms + trashes a
 * match through the same confirmAndTrash all strategies share, then returns
 * to the grid (closeAnyOpenPhoto) before opening the next tile. Never steps
 * through the photo view with ArrowRight.
 *
 * `seen` is the SAME map processDateGroup's aria-phase pre-scroll already
 * populated -- both need one memory of "every tile this date has ever shown
 * us" because the grid is virtualized (collectResultTiles only ever returns
 * what's currently mounted). `tiles` is the latest on-screen snapshot to
 * resume scanning from.
 *
 * `matchedJobs`: same duplicate-hunting contract as walkPhotoView's (see its
 * header) -- jobs already confirmed+trashed once this date, shared by
 * reference so a further copy found at another tile still gets trashed
 * rather than silently skipped once its job is no longer "unmatched".
 */
async function walkGrid(page, seen, tiles, unmatchedJobs, query, queue, dryRun, matchedJobs = new Set()) {
  let remaining = unmatchedJobs;
  if (remaining.length === 0 && matchedJobs.size === 0) return { stillUnmatched: remaining };

  // Keyed by IDENTITY (tileIdentity: href, falling back to aria-label), NOT
  // aria-label alone -- 2026-09-12: two of Oliver's real duplicate library
  // items share an aria-label (same EXIF capture second), and this map/the
  // visited/unreachable/openAttempts bookkeeping below all need to treat
  // them as the two SEPARATE tiles they are, or the grid walk would mark
  // opening one as covering both and silently never visit the second. See
  // dedupeTilesByIdentity's header in matcher.mjs for the full case.
  const mergeSeen = (freshTiles) => {
    let addedNew = false;
    for (const t of freshTiles) {
      const key = tileIdentity(t);
      if (!seen.has(key)) {
        seen.set(key, t);
        addedNew = true;
      }
    }
    return addedNew;
  };

  const visited = new Set();
  // Tiles `seen` at some point but which never became actionable after
  // MAX_TILE_OPEN_RETRIES scroll+retry attempts. Tracked separately from
  // `visited` (opened and its panel read) so EXHAUSTED can mean what it says
  // -- every seen label accounted for -- rather than silently dropping a
  // tile the grid just wouldn't mount.
  const unreachable = new Set();
  const openAttempts = new Map(); // ariaLabel -> retry count so far
  let steps = 0;
  let boundHit = false;
  // SEPARATE budget from the aria phase's own pre-scroll loop (processDateGroup)
  // -- sharing one budget meant the pre-scroll could spend the whole thing
  // just loading the day, leaving this walk's very first "nothing on-screen"
  // check to break immediately with most of the date never reached.
  let walkScrollAttempts = 0;
  // Which direction the "no on-screen candidate" branch last made real
  // progress in -- alternated each time rather than always preferring the
  // same one, so a direction that just paid off doesn't keep re-covering the
  // same ground forever (a direction that always scrolls up first can walk
  // all the way back to the very first tile ever seen without ever giving a
  // down-scroll the chance to reveal the tile that would end the walk).
  let lastRecoveryDirection = null;

  // See matchedJobs' header above: keep scanning tiles for a duplicate copy
  // of an already-matched job even once `remaining` empties.
  while (remaining.length > 0 || matchedJobs.size > 0) {
    let tile = tiles.find((t) => !visited.has(tileIdentity(t)) && !unreachable.has(tileIdentity(t)));

    if (!tile) {
      // Nothing on-screen is both unvisited and not given up on. Before
      // concluding the date is exhausted, scroll (both directions -- see
      // scrollResultsUp's header for why down-only can't recover a tile the
      // window already moved past) and re-collect.
      if (walkScrollAttempts >= MAX_SCROLL_ATTEMPTS_PER_DATE) break;

      const tryDirection = async (direction) => {
        if (direction === 'down') await scrollResults(page);
        else await scrollResultsUp(page);
        const fresh = await collectResultTiles(page);
        // "Progress" covers BOTH senses scrolling can help: a genuinely NEW
        // label (down's case) OR an already-known label that's simply back
        // on-screen and still actionable (up's recovery case -- mergeSeen
        // alone would say "nothing new" for a tile already in `seen`).
        const newlySeen = mergeSeen(fresh);
        const recoveredKnown = fresh.some((t) => !visited.has(tileIdentity(t)) && !unreachable.has(tileIdentity(t)));
        return { fresh, progressed: newlySeen || recoveredKnown };
      };

      const preferred = lastRecoveryDirection === 'up' ? 'down' : 'up';
      let outcome = await tryDirection(preferred);
      let directionUsed = preferred;
      if (!outcome.progressed) {
        directionUsed = preferred === 'up' ? 'down' : 'up';
        outcome = await tryDirection(directionUsed);
      }

      tiles = outcome.fresh;
      if (outcome.progressed) {
        walkScrollAttempts = 0; // genuine progress -- keep scrolling as long as it keeps paying off
        lastRecoveryDirection = directionUsed;
      } else {
        walkScrollAttempts += 1;
      }
      continue; // re-check the freshly-collected/merged set for a candidate
    }

    if (steps >= MAX_STEPS_PER_DATE) {
      boundHit = true;
      break;
    }
    steps += 1;

    try {
      await openTile(page, tile);
    } catch (err) {
      if (err instanceof StaleTileError) {
        // A tile we KNOW exists (on-screen a moment ago) failed to open --
        // e.g. the grid re-virtualized it out between collecting and
        // clicking. Retry a bounded number of times, scrolling in between,
        // before giving up on THIS tile specifically. Deliberately does NOT
        // add the tile to `visited` on failure -- only a genuine open earns
        // that (see the comment above `visited.add` below).
        const attempts = (openAttempts.get(tileIdentity(tile)) ?? 0) + 1;
        openAttempts.set(tileIdentity(tile), attempts);
        if (attempts >= MAX_TILE_OPEN_RETRIES) {
          unreachable.add(tileIdentity(tile));
          console.log(
            `[date ${query}] UNREACHABLE: "${tile.ariaLabel}" never became actionable after ${attempts} attempt(s) — ` +
              'giving up on this tile, NOT counting it as walked'
          );
        } else {
          if (VERBOSE) console.log(`  [grid step ${steps}] ${err.message} — retry ${attempts}/${MAX_TILE_OPEN_RETRIES} after scrolling`);
          await scrollResults(page);
        }
        tiles = await collectResultTiles(page);
        mergeSeen(tiles);
        continue;
      }
      throw err;
    }

    // Only reaching here means the tile genuinely opened -- only NOW is it
    // safe to count it visited. Marking it visited any earlier (e.g. before
    // the openTile attempt) is the exact bug that let a date report
    // EXHAUSTED while most of it was never actually opened.
    visited.add(tileIdentity(tile));
    openAttempts.delete(tileIdentity(tile));
    walkScrollAttempts = 0; // opening a tile is progress too

    await openInfoPanelOnce(page);
    const text = await readPanelText(page);
    const parsed = parsePanelText(text);
    if (VERBOSE) {
      console.log(
        `  [grid step ${steps}] filename=${parsed.filename ?? '(none)'} ` +
          `dims=${parsed.pixelWidth ?? '?'}x${parsed.pixelHeight ?? '?'}` +
          (parsed.filename ? '' : ` rawLen=${(text || '').length} raw="${(text || '').slice(0, 120)}"`)
      );
    }
    // See walkPhotoView's identical candidateJobs comment -- widen the
    // candidate set to already-matched jobs too, so a duplicate copy at a
    // DIFFERENT tile still gets trashed instead of silently opened and
    // ignored once its job is no longer "unmatched".
    const candidateJobs = matchedJobs.size > 0 ? [...remaining, ...matchedJobs] : remaining;
    const job = findMatchingJob(candidateJobs, parsed);
    if (job) {
      const isDuplicateCopy = matchedJobs.has(job);
      await confirmAndTrash(page, job, parsed, text, query, queue, dryRun, isDuplicateCopy);
      if (!isDuplicateCopy) {
        remaining = remaining.filter((j) => j !== job);
        matchedJobs.add(job);
      }
    }

    // Back to the grid -- the LIVE-CORRECTED closeAnyOpenPhoto (search box
    // visible AND trash control not visible, at most 2 Escape attempts). See
    // this function's header for why this is the first time the grid walk
    // has ever run against the fixed version.
    await closeAnyOpenPhoto(page);
    tiles = await collectResultTiles(page); // DOM re-renders on return to the grid
    mergeSeen(tiles);
  }

  if (remaining.length > 0) {
    // EXHAUSTED means every tile this walk ever saw (`seen`) has either been
    // opened (`visited`) or explicitly given up on (`unreachable`) -- never
    // silently skipped. `unwalked > 0` is the one case that would actually
    // contradict that invariant, reserved for MAX_STEPS_PER_DATE cutting the
    // walk off mid-day.
    const unwalked = seen.size - visited.size - unreachable.size;
    if (boundHit || unwalked > 0) {
      const why = boundHit
        ? `MAX_STEPS_PER_DATE (${MAX_STEPS_PER_DATE}) reached`
        : `${MAX_SCROLL_ATTEMPTS_PER_DATE} consecutive fruitless scroll(s)`;
      console.log(
        `[date ${query}] ABANDONED: ${why}, ${remaining.length} job(s) still unmatched` +
          (unwalked > 0 ? `, ${unwalked} seen tile(s) never reached` : '')
      );
    } else {
      const unreachableNote = unreachable.size > 0 ? `, ${unreachable.size} unreachable (see UNREACHABLE above)` : '';
      console.log(
        `[date ${query}] EXHAUSTED: ${visited.size} tile(s) opened${unreachableNote} of ${seen.size} seen, ${remaining.length} job(s) still unmatched`
      );
    }
  }

  return { stillUnmatched: remaining };
}


export async function processDateGroup(page, dateStr, unmatchedJobs, queue, { dryRun, walk = 'photo' }) {
  let remaining = [...unmatchedJobs];
  if (remaining.length === 0) return { stillUnmatched: remaining };

  // An empty result set is NOT reliable evidence that the date has no photos:
  // "August 3, 2026" returned 0 tiles during a full run, while a probe of the
  // exact same query minutes earlier returned 5. Treating that as "no results"
  // wrote three jobs off to needs_review for a date that demonstrably has
  // photos. Re-issue the search before believing an empty day.
  let query = await searchByDate(page, dateStr);
  let tiles = await collectResultTiles(page);
  for (let attempt = 1; attempt <= EMPTY_SEARCH_RETRIES && tiles.length === 0; attempt++) {
    if (VERBOSE) console.log(`[search ${query}] 0 tiles — re-issuing the search (${attempt}/${EMPTY_SEARCH_RETRIES})`);
    query = await searchByDate(page, dateStr);
    tiles = await collectResultTiles(page);
  }
  if (VERBOSE) console.log(`[search ${query}] ${tiles.length} visible photo tile(s), exhaustive-fallback strategy: ${walk}`);
  if (tiles.length === 0) {
    console.log(`[search ${query}] no results after ${EMPTY_SEARCH_RETRIES + 1} attempt(s)`);
    return { stillUnmatched: remaining };
  }

  // Captured BEFORE the aria pre-scroll below runs, so the exhaustive
  // fallback always has a genuine "date's first tile" to start from even if
  // that pre-scroll later moves the mounted window well past it -- see
  // walkPhotoView's header. A plain reference, not re-derived from `seen`,
  // so its identity survives however `seen`/`tiles` get mutated below.
  const dateFirstTile = tiles[0];

  // `seen` is the aria fast path's OWN memory of "every tile this date has
  // ever shown us" (see mergeSeen below), needed because Google's result
  // grid is VIRTUALIZED -- collectResultTiles() only ever returns what's
  // currently mounted/on-screen. planAriaMatches() needs the FULL set to
  // judge ambiguity safely (a duplicate that hasn't loaded yet could be the
  // thing that makes a seemingly-unique match actually ambiguous), so the
  // pre-scroll below accumulates by LABEL SET, not by comparing on-screen
  // tile COUNTS -- a windowed swap can hold the count flat while the labels
  // underneath move on entirely, which is a correctness risk here (a missed
  // duplicate turns a genuinely ambiguous match into a FALSELY CONFIDENT
  // one), not just a coverage one. The exhaustive fallback below (walkPhoto-
  // View) needs none of this: it never re-collects or scrolls the grid at
  // all, see its header for why.
  const seen = new Map(); // identity (href, or aria-label as fallback) -> tile, first-seen copy
  // Jobs already confirmed+trashed once THIS date search -- shared across the
  // aria phase below and whichever exhaustive walk follows, so a duplicate
  // copy found later still gets trashed. See confirmAndTrash's/walkPhotoView's
  // matchedJobs comments for the full rationale.
  const matchedJobs = new Set();
  let scrollAttempts = 0;

  // Keyed by IDENTITY, not aria-label alone -- see collectResultTiles' and
  // dedupeTilesByIdentity's headers. planAriaMatches reads `[...seen.values()]`
  // below to decide ambiguity; if two of Oliver's real duplicate library
  // items (identical aria-label, distinct href) collapsed to one entry here,
  // planAriaMatches would see only 1 candidate and never notice the
  // collision -- which is exactly the 2026-09-12 gap this keys around.
  const mergeSeen = (freshTiles) => {
    let addedNew = false;
    for (const t of freshTiles) {
      const key = tileIdentity(t);
      if (!seen.has(key)) {
        seen.set(key, t);
        addedNew = true;
      }
    }
    return addedNew;
  };

  // --- CHANGE 1: aria fast path (unchanged -- verified live, matched 3/3
  // and 2/2 on real dates, filename-confirmed) -----------------------------
  // Predict which tiles are worth opening from the grid's own aria-labels
  // (capture time to the SECOND) before falling back to the exhaustive walk.
  mergeSeen(tiles); // seed `seen` with whatever was on-screen before any pre-scroll happened
  while (scrollAttempts < MAX_SCROLL_ATTEMPTS_PER_DATE) {
    await scrollResults(page);
    scrollAttempts += 1;
    tiles = await collectResultTiles(page);
    if (!mergeSeen(tiles)) break; // scroll revealed no label we hadn't already seen -- fully loaded
  }

  const ariaPlan = planAriaMatches(remaining, [...seen.values()]);
  if (ariaPlan) {
    if (VERBOSE) {
      console.log(`[search ${query}] aria fast path: ${ariaPlan.size}/${remaining.length} job(s) matched to a tile, opening only those`);
    }
    for (const [job, tile] of ariaPlan) {
      // Keep `seen` in sync for aria-considered tiles too -- it's a real,
      // known tile regardless of whether opening it below succeeds.
      mergeSeen([tile]);
      try {
        await openTile(page, tile);
      } catch (err) {
        if (err instanceof StaleTileError) {
          // Grid shifted under us since planAriaMatches ran. Don't guess --
          // leave this job for the exhaustive walk below, which starts fresh
          // from the date's first tile and will still reach it if it's there.
          if (VERBOSE) console.log(`  [aria] ${err.message} — leaving for the exhaustive walk`);
          continue;
        }
        throw err;
      }
      await openInfoPanelOnce(page);
      const text = await readPanelText(page);
      const parsed = parsePanelText(text);
      // The aria match only decided this tile was worth OPENING -- it never
      // authorises a trash by itself. If the panel's filename doesn't
      // confirm `job` (a coincidental offset hit, or the grid reordering
      // under us), leave the job in `remaining` for the exhaustive walk
      // rather than giving up on it.
      if (findMatchingJob(remaining, parsed) === job) {
        await confirmAndTrash(page, job, parsed, text, query, queue, dryRun);
        remaining = remaining.filter((j) => j !== job);
        // Remembered so that if the exhaustive walk below still has to run
        // (because some OTHER job on this date is unmatched), it keeps
        // checking every photo it visits against this job too -- a duplicate
        // copy of it can be sitting anywhere else in the day's results. See
        // confirmAndTrash's / walkPhotoView's matchedJobs comments. A date
        // fully resolved by the aria plan (remaining empties right below)
        // never reaches the walk at all, so a duplicate that shares this
        // job's exact predicted second (the identical-timestamp case
        // planAriaMatches' own ambiguity check is designed to catch) is the
        // one shape this still can't find -- see report.
        matchedJobs.add(job);
      } else if (VERBOSE) {
        console.log(
          `  [aria] predicted tile for ${job.filename} did not confirm by filename ` +
            `(got ${parsed.filename ?? '(none)'}) — leaving for the exhaustive walk`
        );
      }
      if (remaining.length === 0) break;
      await closeAnyOpenPhoto(page);
    }
    if (remaining.length === 0) return { stillUnmatched: remaining };
    // Only the grid walk needs a fresh on-screen snapshot to resume scanning
    // from (the DOM re-renders after trashing/closing) -- walkPhotoView below
    // never uses `tiles` at all, it starts from `dateFirstTile` instead.
    if (walk === 'grid') tiles = await collectResultTiles(page);
  }

  if (walk === 'grid') {
    // seed with everything already known from the aria phase above -- see
    // walkGrid's header for why it shares this map rather than starting over.
    mergeSeen(tiles);
    return await walkGrid(page, seen, tiles, remaining, query, queue, dryRun, matchedJobs);
  }

  // --- Exhaustive fallback: in-photo-view traversal (see walkPhotoView) --
  return await walkPhotoView(page, dateFirstTile, remaining, query, queue, dryRun, matchedJobs);
}

/**
 * Process every date group: UTC-derived date first, then day-1 and day+1
 * only for jobs still unmatched after the prior attempt. Anything left
 * unmatched after all three attempts becomes needs_review.
 */
export async function runDateGroups(page, groupedJobs, queue, { dryRun, walk = 'photo' }) {
  for (const [dateStr, jobs] of groupedJobs) {
    let unmatched = [...jobs];
    const attemptDates = [dateStr, shiftDateDays(dateStr, -1), shiftDateDays(dateStr, 1)];

    try {
      for (const attemptDate of attemptDates) {
        if (unmatched.length === 0) break;
        const { stillUnmatched } = await processDateGroup(page, attemptDate, unmatched, queue, { dryRun, walk });
        unmatched = stillUnmatched;
        if (unmatched.length > 0) await stealthDelay(PACE_MS_MIN, PACE_MS_MAX); // pure mimicry, off unless --slow
      }
    } catch (err) {
      if (isPageClosedError(page, err)) {
        // The tab this worker was driving is gone -- nothing was learned
        // about any in-flight job, so nothing gets marked failed/needs_review;
        // every job that never resolved to trashed/needs_review/error this
        // run simply stays 'queued' for the next run.
        const allIds = [...groupedJobs.values()].flat().map((j) => j.id);
        const processed = allIds.filter((id) => queue.getById(id)?.status !== 'queued').length;
        console.log(
          `[worker] browser tab went away mid-run — ${processed} job(s) processed before that, ` +
            `${allIds.length - processed} left queued for the next run.`
        );
        return; // end cleanly, no rethrow
      }
      if (!dryRun) {
        // `unmatched` is a snapshot from the LAST attemptDate iteration that
        // returned normally -- processDateGroup only reassigns it on a clean
        // return (see the loop above). When it throws partway through a date
        // group, `unmatched` still lists jobs the group had already resolved
        // to trashed/needs_review before the throw (processDateGroup updates
        // the queue as it goes, job by job). Blindly marking everything in
        // `unmatched` as 'error' here rewrote genuine 'trashed' records back
        // to 'error' -- confirmed live 2026-09-02 (worker-runs log for that
        // date: two photos logged [trashed] ended the run recorded as
        // error). Read each job's CURRENT persisted status back from the
        // queue instead and only touch it if it is still 'queued' -- exactly
        // what the isPageClosedError branch above already does, for the same
        // reason.
        for (const job of unmatched) {
          if (queue.getById(job.id)?.status !== 'queued') continue;
          queue.update(job.id, { status: 'error', error: String(err.message || err), attempts: job.attempts + 1 });
        }
      }
      throw err; // stop the whole run, no silent retry loop
    }

    for (const job of unmatched) {
      if (dryRun) {
        console.log(`[dry-run needs_review] ${job.filename}: no filename match for ${dateStr} (+/-1 day)`);
      } else {
        queue.update(job.id, {
          status: 'needs_review',
          comparison: { reason: `no filename match for ${dateStr} (+/-1 day)` },
          attempts: job.attempts + 1,
        });
        console.log(`[needs_review] ${job.filename}: no filename match for ${dateStr} (+/-1 day)`);
      }
    }
    await stealthDelay(PACE_MS_MIN, PACE_MS_MAX); // pace between date groups — pure mimicry, off unless --slow
  }
}

// Bounded panel-recovery loop (2026-09-24, round 4 live finding) --
// waitForTimelineAdvanceConfirmed's own header explains why this exists.
// ~1.5s between rounds is a real-correctness wait (the panel needs actual
// render time), not a tight poll -- 6 rounds is roughly the brief's
// "~12s total" once the per-round read+click overhead is added on top of
// the 6*1.5s=9s of waiting.
const MAX_PANEL_RECOVERY_ROUNDS = 6;
const PANEL_RECOVERY_ROUND_WAIT_MS = 1500;

/**
 * Confirm a TIMELINE advance actually happened, returning `{ text, url,
 * unreadable }` or null -- 2026-09-23, replacing bare panel text as the
 * timeline walk's advance signal after a real run (commit 7565a5d) proved
 * it unsound: photo 1 and photo 2 of that run both read back
 * "IMG_2932.JPG", because the panel's content lags the actual navigation by
 * a poll or two and a bare "text !== previousText" check accepted a
 * transient, still-stale read as proof of having moved on. Live evidence
 * (Oliver's own probe, same day) showed page.url() -- a distinct
 * "/photo/<id>" per photo -- changes RELIABLY on every ArrowRight (6/6), so
 * URL is now the PRIMARY signal; panel text is only trusted once the URL
 * has already changed, and even then gets a confirmation pass against
 * staleness:
 *
 *   1. Poll page.url() until it differs from `beforeUrl` (real-correctness
 *      wait, bounded) -- no URL change at all means the advance genuinely
 *      did not register; returns null, the ONLY case that means that now
 *      (see point 4).
 *   2. Once the URL has moved, read the panel. If it already has a
 *      filename, skip straight to step 3's staleness check.
 *   3. Otherwise -- PANEL-RECOVERY LOOP (2026-09-24, round 4): a live run
 *      showed the panel can stay genuinely unreadable across MULTIPLE
 *      recovery attempts, and the single keyboard-only reopen an earlier
 *      version of this function tried can itself fail outright (a real
 *      run's activeElement ended up BUTTON[Open info] afterward -- the
 *      click path got as far as landing focus on the button but the panel
 *      still hadn't rendered, or 'i' toggled an already-open panel shut
 *      mid-render). For up to MAX_PANEL_RECOVERY_ROUNDS rounds: PREFER
 *      clicking a VISIBLE "Open info" control over pressing 'i' -- 'i' on
 *      an ALREADY-OPEN panel CLOSES it (openInfoPanelOnce's own
 *      sticky-toggle behaviour), so blindly keying risks flipping a panel
 *      that's merely slow to render shut mid-open; 'i' is only used when
 *      no visible button exists to click. Waits a real
 *      PANEL_RECOVERY_ROUND_WAIT_MS between rounds, then re-reads.
 *   4. If the panel is STILL unreadable after every round, this is no
 *      longer treated as "not yet confirmed" the way it used to be --
 *      the URL DID change, we genuinely are on a different, real photo,
 *      we simply cannot read what it is. Returns
 *      `{ text: '', url, unreadable: true }` so the caller (walkTimeline)
 *      can count it and move on WITHOUT ending the walk. null is now
 *      reserved exclusively for "the URL never changed at all".
 *   5. Once a filename IS available (immediately, or after recovery), the
 *      SAME same-filename staleness confirmation as before applies: if it
 *      equals the PREVIOUS photo's filename, take one more read and only
 *      trust the match as a genuine duplicate if that second read agrees
 *      too (never guess between a real duplicate and a read that just
 *      hadn't caught up).
 *
 * findMatchingJob's own "never guess" rule is unaffected by any of this --
 * this function only ever decides what text (if any) to hand it, never
 * whether a job matches.
 */
export async function waitForTimelineAdvanceConfirmed(page, beforeUrl, previousText) {
  const urlDeadline = Date.now() + (FAST_DELAYS ? 20 : 5000);
  let url = page.url();
  while (url === beforeUrl && Date.now() < urlDeadline) {
    await pollDelay();
    url = page.url();
  }
  if (url === beforeUrl) return null; // advance never took at all -- the ONLY case this function still returns null for

  const previousFilename = parsePanelText(previousText).filename;

  // PHASE A -- fast poll (2026-09-23, round 3 fix, unchanged): handles the
  // ORDINARY lag case where the panel is rendering (or already rendered)
  // but the filename specifically hasn't caught up to a DIFFERENT photo
  // yet (surrounding fields like the map/"Backed up" size can re-render on
  // their own schedule ahead of it). Cheap, tight polling -- no active DOM
  // actions -- since simply waiting resolves this most of the time.
  const filenameDeadline = Date.now() + (FAST_DELAYS ? 30 : 8000);
  let text = await readPanelText(page);
  let filename = parsePanelText(text).filename;
  while ((!filename || (previousFilename && filename === previousFilename)) && Date.now() < filenameDeadline) {
    await pollDelay();
    text = await readPanelText(page);
    filename = parsePanelText(text).filename;
  }

  // PHASE B -- bounded active-recovery loop (2026-09-24, round 4 fix):
  // engages ONLY when Phase A's whole window elapsed with the panel still
  // genuinely EMPTY (not merely stale-but-present, which Phase A already
  // handles) -- a different problem needing real DOM actions, not more
  // passive waiting.
  for (let round = 0; round < MAX_PANEL_RECOVERY_ROUNDS && !filename; round++) {
    if (VERBOSE) {
      console.log(`    [timeline] panel unreadable after URL change, recovery round ${round + 1}/${MAX_PANEL_RECOVERY_ROUNDS}`);
    }
    const openInfoButton = page.locator(OPEN_INFO_SELECTOR).first();
    if (await openInfoButton.isVisible().catch(() => false)) {
      await openInfoButton.click().catch(() => {});
    } else {
      // Only fall back to the keyboard when there's genuinely no visible
      // button to click -- see this function's header, step 3.
      await page.keyboard.press('i');
    }
    await sleep(FAST_DELAYS ? 0 : PANEL_RECOVERY_ROUND_WAIT_MS);
    text = await readPanelText(page);
    filename = parsePanelText(text).filename;
  }

  if (!filename) {
    // Unreadable even after the full recovery window -- see this
    // function's header, step 4. The caller must NOT treat this as
    // end-of-library.
    return { text: '', url, unreadable: true };
  }

  if (previousFilename && filename === previousFilename) {
    // Ambiguous same-filename result -- see this function's header, step 5.
    await pollDelay();
    const secondText = await readPanelText(page);
    const secondFilename = parsePanelText(secondText).filename;
    if (secondFilename && secondFilename !== filename) {
      text = secondText; // disagreed -- the first read was stale, trust the later one
    }
    // else: both reads agree (or the second also came back empty) -- trust
    // the original read as a genuine duplicate rather than looping forever.
  }

  return { text, url, unreadable: false };
}

/**
 * TIMELINE-ONLY advance (2026-09-23) -- pairs with
 * waitForTimelineAdvanceConfirmed above. Tries ArrowRight FIRST across all
 * its retries (swapped from advancePhotoView's click-first order): the
 * live run that exposed the stale-read bug also logged "advance did not
 * register via click" as its only failed advance, while Oliver's separate
 * direct probe (ArrowRight x6, no click involved at all) succeeded every
 * time. Clicking "View next photo" is kept only as a LAST-RESORT fallback
 * if every ArrowRight attempt fails to move the URL at all.
 *
 * SIMPLIFIED 2026-09-24 (round 4): waitForTimelineAdvanceConfirmed now
 * returns null EXCLUSIVELY when the URL never moved at all (an unreadable-
 * but-moved photo returns a real `{ ..., unreadable: true }` object
 * instead of null -- see its own header). That means every `result` this
 * function gets back, truthy or not, already tells the whole story: truthy
 * = we moved (confirmed or unreadable, walkTimeline decides what to do
 * with that), falsy = we are still on `beforeUrl` and can safely try
 * again. The `page.url() === beforeUrl` guards before every keypress/click
 * below are accordingly simpler than an earlier version needed (no longer
 * have to separately special-case "moved but not yet confirmed") but are
 * kept anyway as defence-in-depth against the URL changing between this
 * function's own checks (e.g. a slow-to-register press that only completes
 * after waitForTimelineAdvanceConfirmed's internal deadline already gave
 * up) -- never press/click again once truly moved.
 */
export async function advanceTimelinePhotoView(page, currentText, logPrefix = '') {
  const beforeUrl = page.url();
  for (let attempt = 0; attempt < ARROW_RETRIES; attempt++) {
    if (page.url() === beforeUrl) {
      await releaseFocus(page);
      await page.keyboard.press('ArrowRight');
    }
    const result = await waitForTimelineAdvanceConfirmed(page, beforeUrl, currentText);
    if (result) return result; // moved -- confirmed OR unreadable, both are a real outcome now; bubble straight up, never retry a keypress
    // Still on beforeUrl -- the press genuinely did not register. No
    // next-photo control at all is the authoritative end-of-library
    // signal (same convention as advancePhotoView) -- no point burning the
    // rest of the retries or falling through to the recovery pass below.
    const candidates = await page.locator(NEXT_PHOTO_SELECTOR).all();
    if (candidates.length === 0) return null;
    if (VERBOSE) {
      console.log(`  ${logPrefix} advance did not register via ArrowRight, retrying (${attempt + 1}/${ARROW_RETRIES})`);
    }
  }
  // RECOVERY PASS (2026-09-23 live finding): a still-on-`beforeUrl` retry
  // loop can fail for a reason none of its own attempts can fix -- keyboard
  // focus drifting off the viewer entirely (activeElement=BODY on a real
  // run, immediately after moveToTrash's own fallback-click path). Before
  // ever concluding "end of library", explicitly re-focus the viewer
  // (focusViewerCenter) and give BOTH the key and the click control one
  // more real try -- a live run wrongly declared EXHAUSTED after 449 of
  // what should have been ~1500+ photos, with 103 jobs still pending
  // (their real photos going back to March), precisely because this
  // recovery did not exist yet.
  await focusViewerCenter(page);
  await releaseFocus(page);
  await page.keyboard.press('ArrowRight');
  const recovered = await waitForTimelineAdvanceConfirmed(page, beforeUrl, currentText);
  if (recovered) return recovered;

  // Last-resort click fallback -- see this function's header for why it's
  // no longer tried first. Refocuses again immediately before clicking:
  // the SAME lost-focus state that defeats ArrowRight can make a stale
  // click land on nothing too.
  await focusViewerCenter(page);
  const candidates = await page.locator(NEXT_PHOTO_SELECTOR).all();
  for (const candidate of candidates) {
    if (await candidate.isVisible().catch(() => false)) {
      await candidate.click().catch(() => {});
      break;
    }
  }
  const result = await waitForTimelineAdvanceConfirmed(page, beforeUrl, currentText);
  if (result) return result;
  // Only NOW -- ArrowRight + refocus + the click fallback ALL failed to
  // move the URL at all -- is this treated as genuinely the end of the
  // library (or an advance that was truly swallowed, indistinguishable
  // from here).
  if (VERBOSE) {
    const focus = await page
      .evaluate(() => {
        const a = document.activeElement;
        return a ? `${a.tagName}[${(a.getAttribute('aria-label') || a.className || '').toString().slice(0, 40)}]` : 'none';
      })
      .catch(() => 'unknown');
    console.log(`  ${logPrefix} advance produced no confirmed change (end of library, or advancing was swallowed). activeElement=${focus}`);
  }
  return null;
}

/**
 * Walk the main Google Photos LIBRARY TIMELINE (no search at all) by
 * stepping through its PHOTO VIEWER, exactly like walkPhotoView already
 * does for a date's search results -- the `--walk=timeline` strategy,
 * REWRITTEN 2026-09-22 (see the "--walk=timeline constants" module comment
 * above for the full rewrite history: the original grid-scrolling design
 * was disproven by a live dry-run where returning to the grid after each
 * candidate tile reset the scroll position to the top every time).
 *
 * WHY THIS EXISTS AT ALL: date search (processDateGroup/runDateGroups) was
 * measured live to be badly incomplete -- "March 19, 2026" returned 1 tile
 * from a day the timeline shows several for, "March 17, 2026" returned ZERO
 * results for a day that demonstrably has photos. The main timeline DOES
 * show everything.
 *
 * STRATEGY:
 *   1. Open the timeline's FIRST (newest) tile via openFirstTile, passed
 *      collectTimelineTiles/TIMELINE_TILE_SELECTOR so it addresses the
 *      timeline instead of a date's search results -- everything else about
 *      "get into the photo view" (identity-scoped addressing, StaleTileError
 *      retry) is shared, unchanged code.
 *   2. Open the info panel ONCE (openInfoPanelOnce, sticky -- unchanged).
 *   3. Loop: read + parse the panel (readPanelText/parsePanelText,
 *      unchanged). findMatchingJob decides -- filename ONLY, checked on
 *      EVERY photo, no time/offset calibration of any kind. A match runs
 *      through confirmAndTrash (requires the real confirm dialog, per the
 *      earlier commit) exactly like walkPhotoView; the SAME `matchedJobs`
 *      convention handles duplicate copies (a job stays in the candidate
 *      pool after its first trash, so a further copy later in the library
 *      still gets found). A non-match, or a match not confirmed as trashed,
 *      falls through to the SAME advance-to-next-photo step either way.
 *   4. Advancing (both after a confirmed trash, which moves the view on by
 *      itself, and after a non-match) reuses advancePhotoView -- the exact
 *      same hard-won retry-click-then-key logic walkPhotoView depends on,
 *      not reimplemented here.
 *   5. Stops when: every job has matched (remaining empties AND there are
 *      no matchedJobs left to keep hunting duplicates for -- same rule as
 *      walkPhotoView); the panel's parsed captureDateMs (matcher.mjs,
 *      UNVERIFIED LIVE -- see its own header) reads more than
 *      TIMELINE_STOP_BUFFER_DAYS before the OLDEST pending job's own
 *      creationDate (a photo with no parseable captureDateMs never trips
 *      this check -- see below for why that's safe); advancing genuinely
 *      fails (end of the library, or ArrowRight/click stopped registering
 *      three times running -- advancePhotoView returns null either way);
 *      or MAX_TIMELINE_PHOTOS is hit (a safety valve, logged loudly since
 *      it should never bind in normal operation against a ~1500-photo
 *      library).
 *   6. Progress is logged every 100 photos (count + the current photo's
 *      parsed capture date, when one parsed) so a live run can be watched.
 *   7. A photo whose panel never becomes readable (waitForTimelineAdvance-
 *      Confirmed's bounded recovery loop exhausts) does NOT stop the walk --
 *      it's logged loudly, counted, and skipped; a live run wrongly declared
 *      EXHAUSTED with 103 real jobs still pending over exactly this before
 *      the fix (2026-09-24). A one-line summary (photos visited, matched,
 *      unreadable) prints once the loop ends either way.
 */
export async function walkTimeline(page, pendingJobs, queue, { dryRun }) {
  let remaining = [...pendingJobs];
  if (remaining.length === 0) return { stillUnmatched: remaining };

  const matchedJobs = new Set();
  const oldestPendingMs = Math.min(...remaining.map((j) => new Date(j.creationDate).getTime()));
  const stopBeforeMs = oldestPendingMs - TIMELINE_STOP_BUFFER_MS;

  const firstTiles = await collectTimelineTiles(page);
  const tile = await openFirstTile(page, firstTiles[0] ?? null, {
    collectFn: collectTimelineTiles,
    resultSelector: TIMELINE_TILE_SELECTOR,
  });
  if (!tile) {
    // Nothing on the timeline at all to open -- not a bug, just nothing to walk.
    console.log(`[timeline] EXHAUSTED: 0 photo(s) visited (nothing on the timeline to open), ${remaining.length} job(s) still unmatched`);
    return { stillUnmatched: remaining };
  }

  // Opened ONCE for the whole walk -- the panel is sticky and stays open as
  // ArrowRight steps through the rest of the library (see
  // openInfoPanelOnce's header). Never called again per-photo below.
  await openInfoPanelOnce(page);

  let steps = 0;
  let boundHit = false;
  let stoppedPastOldest = false;
  let matchedCount = 0;
  let unreadableCount = 0;
  let text = await readPanelText(page);
  // Live finding, 2026-09-22: a panel read can land EMPTY or STALE
  // immediately after opening/advancing, before Google has actually
  // rendered the new photo's content -- openInfoPanelOnce's own poll
  // already guarantees SOME filename by the time it returns, but per the
  // same "never trust an immediate read" rule this whole advance rewrite
  // is built on (see waitForTimelineAdvanceConfirmed), give the FIRST photo
  // one more short settle-and-reread pass too, rather than assuming its
  // very first successful read is necessarily the final one.
  await pollDelay();
  const settledFirstRead = await readPanelText(page);
  if (settledFirstRead) text = settledFirstRead;

  // See matchedJobs' header (walkPhotoView) -- once anything has matched, a
  // duplicate copy could be anywhere else in the library, so the loop keeps
  // going until neither remaining nor matchedJobs has anything left to check.
  while (remaining.length > 0 || matchedJobs.size > 0) {
    if (steps >= MAX_TIMELINE_PHOTOS) {
      boundHit = true;
      loud(
        `BLOCKER: timeline walk hit MAX_TIMELINE_PHOTOS (${MAX_TIMELINE_PHOTOS}) without finishing -- stopping, ` +
          `${remaining.length} job(s) still unmatched. Either the library is far bigger than the ~1500 photos measured ` +
          `live 2026-09-22, or the date-based stop condition never fired (check parsePanelText's captureDateMs parsing).`
      );
      break;
    }
    steps += 1;

    const parsed = parsePanelText(text);
    if (steps % 100 === 0 || VERBOSE) {
      const dateLabel = parsed.captureDateMs != null ? new Date(parsed.captureDateMs).toISOString() : '(unparsed)';
      console.log(`[timeline] photo ${steps}: filename=${parsed.filename ?? '(none)'} captureDate=${dateLabel}`);
    }

    // Stop condition: a photo with no parseable captureDateMs NEVER trips
    // this (never guesses a date) -- it just means the check is skipped for
    // THIS photo, relying on MAX_TIMELINE_PHOTOS as the ultimate backstop.
    // See matcher.mjs's parseCaptureDateMs header for why this field can be
    // absent/wrong and why that's an accepted, bounded risk here.
    if (parsed.captureDateMs != null && parsed.captureDateMs < stopBeforeMs) {
      stoppedPastOldest = true;
      break;
    }

    const candidateJobs = matchedJobs.size > 0 ? [...remaining, ...matchedJobs] : remaining;
    const job = findMatchingJob(candidateJobs, parsed);
    let advancedByDelete = false;

    if (job) {
      matchedCount += 1;
      const isDuplicateCopy = matchedJobs.has(job);
      const beforeTrashUrl = page.url(); // captured BEFORE confirmAndTrash -- see the advanced-read comment below
      const confirmed = await confirmAndTrash(page, job, parsed, text, 'timeline', queue, dryRun, isDuplicateCopy);
      if (!isDuplicateCopy) {
        remaining = remaining.filter((j) => j !== job);
        matchedJobs.add(job);
      }
      if (!dryRun) {
        // Same reasoning as walkPhotoView's identical branch: a CONFIRMED
        // trash always removes the current photo from the results -- the
        // view HAS moved on, settled fact once confirmAndTrash reports it,
        // not something to re-derive from a text diff (which fails exactly
        // for a duplicate copy with byte-identical panel text). BUT a
        // trash-driven auto-advance is still an ADVANCE, subject to the
        // exact same panel-lag risk ArrowRight/click advances are (see
        // waitForTimelineAdvanceConfirmed's header) -- so this goes through
        // the SAME URL-plus-staleness-confirmed read, using the URL from
        // BEFORE the trash (not the current one, which may already reflect
        // wherever the auto-advance already landed) as the baseline for
        // detecting the move.
        const advanced = await waitForTimelineAdvanceConfirmed(page, beforeTrashUrl, text);
        // A trash-driven "unreadable" needs one more check that the
        // ArrowRight branch below doesn't: trashing the library's LAST photo
        // makes performTrash's own auto-advance land on NO photo at all (the
        // view closes, URL reverts to the bare library root), and that reads
        // as "URL changed, no filename ever appeared" -- identical to a
        // genuinely-there-but-unreadable photo from waitForTimelineAdvance-
        // Confirmed's perspective, since it has no way to tell "closed" from
        // "open but broken". TRASH_SELECTOR visibility is the disambiguator:
        // it's only present while an actual photo viewer is open, so its
        // absence here means we've simply reached the end of the library via
        // this trash's own auto-advance, not a real unreadable photo to
        // retry later. Caught by a test with a 3rd, trailing readable tile
        // being wrongly counted as unreadable after the LAST job's trash.
        const viewerStillOpen = advanced && advanced.unreadable
          ? await page.locator(TRASH_SELECTOR).first().isVisible().catch(() => false)
          : false;
        if (advanced && advanced.unreadable && viewerStillOpen) {
          // See the ArrowRight-advance branch's identical handling below
          // for the full "must not end the walk" rationale -- same rule
          // applies to a trash-driven auto-advance landing on an
          // unreadable photo.
          unreadableCount += 1;
          loud(`[timeline] UNREADABLE photo ${steps + 1} (url ${advanced.url}) — skipped, a later pass will retry`);
          text = '';
          advancedByDelete = true;
        } else if (confirmed) {
          // A confirmed trash ALWAYS counts as having advanced, whether or
          // not waitForTimelineAdvanceConfirmed managed to confirm a full
          // (URL + fresh text) transition -- e.g. trashing the library's
          // LAST photo closes the view entirely rather than landing on
          // another one, which reads as "no confirmed advance" from that
          // helper's perspective even though it's a perfectly normal
          // outcome. The critical bit is `text` must NEVER be left
          // pointing at the just-trashed photo's stale content in that
          // case (an infinite re-trash loop caught by running the
          // "duplicate copies" test, not by inspection: `advanced` came
          // back null, `text` was left unchanged, and the SAME already-
          // trashed photo matched and re-trashed itself forever) -- fall
          // back to a raw read, which correctly comes back empty once the
          // view has genuinely closed, so the next loop iteration finds no
          // filename and moves on to actually advancing instead.
          text = advanced ? advanced.text : await readPanelText(page);
          advancedByDelete = true;
        } else if (advanced) {
          text = advanced.text;
          advancedByDelete = true;
        }
      }
    }

    if (!advancedByDelete) {
      const next = await advanceTimelinePhotoView(page, text, `[timeline photo ${steps}]`);
      if (next == null) break; // genuinely end of the library (or an advance ArrowRight+refocus+click all truly swallowed) -- see advanceTimelinePhotoView's header
      if (next.unreadable) {
        // LIVE FINDING 2026-09-24 (round 4): a photo whose panel never
        // becomes readable, even after the full bounded recovery window
        // (waitForTimelineAdvanceConfirmed's own header), must NEVER end
        // the walk -- the URL DID change, this is a real, different photo,
        // we simply couldn't read it this pass. A live run wrongly
        // declared EXHAUSTED with 103 jobs still pending (real photos
        // going back to March) over exactly this. Count it loudly and
        // keep walking from here -- `text=''` means the next loop
        // iteration finds no filename (never guesses a match) and moves
        // straight on to advancing again.
        unreadableCount += 1;
        loud(`[timeline] UNREADABLE photo ${steps + 1} (url ${next.url}) — skipped, a later pass will retry`);
        text = '';
      } else {
        text = next.text;
      }
    }
  }

  console.log(`[timeline] summary: ${steps} photo(s) visited, ${matchedCount} matched, ${unreadableCount} unreadable`);

  if (remaining.length > 0) {
    if (boundHit) {
      console.log(`[timeline] ABANDONED: MAX_TIMELINE_PHOTOS (${MAX_TIMELINE_PHOTOS}) reached, ${remaining.length} job(s) still unmatched`);
    } else if (stoppedPastOldest) {
      console.log(
        `[timeline] reached more than ${TIMELINE_STOP_BUFFER_DAYS} day(s) past the oldest pending job's date — stopping, ` +
          `${remaining.length} job(s) still unmatched`
      );
    } else {
      console.log(`[timeline] EXHAUSTED: ${steps} photo(s) visited (end of library), ${remaining.length} job(s) still unmatched`);
    }
  }

  return { stillUnmatched: remaining };
}

/**
 * Top-level driver for `--walk=timeline` -- runs walkTimeline ONCE across
 * every pending job (no per-date grouping/looping needed: the photo-viewer
 * walk covers the whole library in one continuous pass, oldest to newest),
 * then marks anything still unmatched as needs_review with a reason
 * distinct from date search's own ("no filename match for <date> (+/-1
 * day)") -- so a human triaging needs_review can tell "search never found
 * this photo at all" (the old reason, still produced by --walk=photo/grid)
 * apart from "the photo viewer walked all the way past this job's date and
 * never confirmed a filename match" (this one), which point at different
 * follow-ups (search's date math vs. a genuinely missing/miscategorized
 * photo).
 *
 * Error handling mirrors runDateGroups' own two branches (isPageClosedError
 * vs. any other throw) for the same reasons given there -- see its comments.
 */
export async function runTimelineWalk(page, jobs, queue, { dryRun }) {
  let unmatched = [...jobs];
  try {
    const { stillUnmatched } = await walkTimeline(page, unmatched, queue, { dryRun });
    unmatched = stillUnmatched;
  } catch (err) {
    if (isPageClosedError(page, err)) {
      // Nothing was learned about any in-flight job -- everything not
      // already resolved to trashed/needs_review by walkTimeline's own
      // queue.update() calls simply stays 'queued' for the next run.
      const processed = jobs.filter((j) => queue.getById(j.id)?.status !== 'queued').length;
      console.log(
        `[timeline] browser tab went away mid-run — ${processed} job(s) processed before that, ` +
          `${jobs.length - processed} left queued for the next run.`
      );
      return;
    }
    if (!dryRun) {
      // Same "only touch what's still genuinely queued" rule as
      // runDateGroups -- walkTimeline updates the queue job-by-job as it
      // goes, so `unmatched` can still list jobs already resolved to
      // trashed/needs_review before the throw; blindly marking all of
      // `unmatched` as 'error' would rewrite a real trash back to error.
      for (const job of unmatched) {
        if (queue.getById(job.id)?.status !== 'queued') continue;
        queue.update(job.id, { status: 'error', error: String(err.message || err), attempts: job.attempts + 1 });
      }
    }
    throw err; // stop the whole run, no silent retry loop
  }

  for (const job of unmatched) {
    if (dryRun) {
      console.log(`[dry-run needs_review] ${job.filename}: walked the photo viewer past this job's date with no filename match`);
    } else {
      queue.update(job.id, {
        status: 'needs_review',
        comparison: { reason: "walked the photo viewer past this job's date with no filename match" },
        attempts: job.attempts + 1,
      });
      console.log(`[needs_review] ${job.filename}: walked the photo viewer past this job's date with no filename match`);
    }
  }
}

export async function runWorker({ cap = DEFAULT_CAP, dryRun = false, walk = 'photo' } = {}) {
  const queue = new JobQueue(QUEUE_PATH);
  const jobs = queue.loadAll().filter((j) => j.status === 'queued').slice(0, cap);

  if (jobs.length === 0) {
    console.log('no queued jobs');
    return;
  }

  // Date grouping is only meaningful for the search-based walks -- the
  // timeline walk takes the flat job list directly (see runTimelineWalk's
  // header for why it needs no per-date loop).
  const groups = walk === 'timeline' ? null : groupJobsByDate(jobs);

  if (dryRun) {
    console.log(
      walk === 'timeline'
        ? `--dry-run: will scroll the timeline + decide for ${jobs.length} job(s) but never trash or mutate the queue.`
        : `--dry-run: will search + decide for ${jobs.length} job(s) across ${groups.size} date(s) but never trash or mutate the queue.`
    );
  }

  let gw;
  try {
    gw = getGatewayIp();
  } catch (err) {
    loud(`Could not determine WSL2 gateway IP: ${err.message}`);
    process.exitCode = 1;
    return;
  }

  const cdpUrl = `http://${gw}:9251`;

  // playwright-core is a peer dependency; imported lazily so unit tests
  // (which never touch the browser) don't require it to be installed.
  const { chromium } = await import('playwright-core');

  let browser;
  try {
    browser = await chromium.connectOverCDP(cdpUrl);
  } catch (err) {
    loud(`BLOCKER: could not connect to CDP Chrome at ${cdpUrl} — ${err.message}`);
    process.exitCode = 1;
    return;
  }

  // Opened by this worker; closed in the finally block below. Deliberately
  // NOT browser itself — see the comment on browser.close() there.
  let page;
  try {
    const context = browser.contexts()[0] ?? (await browser.newContext());
    page = await context.newPage();
    await openPhotosHome(page); // lands on the main timeline either way -- no search is ever performed for --walk=timeline
    if (walk === 'timeline') {
      await runTimelineWalk(page, jobs, queue, { dryRun });
    } else {
      await runDateGroups(page, groups, queue, { dryRun, walk });
    }
  } catch (err) {
    loud(`BLOCKER: worker error: ${err.stack || err}`);
    process.exitCode = 1;
  } finally {
    // IMPORTANT: only close the page/tab this worker opened, never the
    // browser. `browser` here came from chromium.connectOverCDP() against
    // Oliver's persistent, already-signed-in Windows Chrome — calling
    // browser.close() on a CDP connection sends Browser.close and kills
    // that real Chrome process outright (not just this tab), same as
    // "never kill a Chrome to free a port" in CLAUDE.md.
    await page?.close().catch(() => {});
  }
}

// Runs `work()` and forces the process to exit once it settles, success or
// failure, instead of relying on Node's event loop to empty naturally. The
// worker's CDP connection (chromium.connectOverCDP, deliberately never
// closed — see the comment on browser.close() above) keeps an open WebSocket
// handle alive for the whole run, so on any error path where runWorker()
// catches internally and returns instead of throwing (e.g. the
// openInfoPanelOnce timeout), the old code — `runWorker(args).catch(...)`
// with no forced exit — would just sit there forever with near-zero CPU,
// never re-triggering autodrain's reschedule. Exported for testing.
export async function exitAfterSettled(work) {
  try {
    await work();
  } catch (err) {
    loud(`BLOCKER: unhandled worker failure: ${err.stack || err}`);
    process.exitCode = 1;
  } finally {
    process.exit(process.exitCode ?? 0);
  }
}

if (import.meta.url === `file://${process.argv[1]}`) {
  const args = parseArgs(process.argv.slice(2));
  if (args.slow) SLOW = true;
  exitAfterSettled(() => runWorker(args));
}
