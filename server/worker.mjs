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
 *   6. A photo confirms a job when filename matches exactly AND dimensions
 *      agree (either orientation) — lib/matcher.mjs's findMatchingJob. This
 *      is the ONLY thing that ever authorises a trash — the aria pre-filter
 *      in step 4 only decides what's worth opening, never confirms a match
 *      by itself.
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
 * Run: node worker.mjs --dry-run [--cap 50]   (safe: never trashes anything)
 *      node worker.mjs --cap 50               (live: trashes matched photos)
 *      node worker.mjs --cap 50 --slow        (live, with human-scale pacing restored)
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
  dedupeTilesByAriaLabel,
  planAriaMatches,
} from './lib/matcher.mjs';

const QUEUE_PATH = process.env.PICNIC_QUEUE_PATH || join(homedir(), '.local/share/picnic/queue.jsonl');
const DEFAULT_CAP = 50;
const SEARCH_BOX_SELECTOR = 'input[aria-label*="Search" i], input[placeholder*="Search" i]';
// Search-result tiles share this href prefix with non-photo chips (e.g.
// "Favorites") — filtered down to real tiles via isRealPhotoTile().
const RESULT_LINK_SELECTOR = 'a[href^="./search/"]';
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

// CHANGE 2 (2026-09-01): Oliver has decided this worker does not need
// bot-detection avoidance (he already bulk-deletes via a scripted browser
// extension elsewhere), so human-mimicry pacing is OFF by default now.
// --slow restores it for anyone who wants it back. Set by parseArgs' return
// value at the top-level entry point below -- NOT mutated by parseArgs
// itself (unlike VERBOSE), so stealthDelayRange() below stays a pure,
// directly-testable function of an explicit boolean.
let SLOW = false;

export function parseArgs(argv) {
  const args = { cap: DEFAULT_CAP, dryRun: false, slow: false };
  for (let i = 0; i < argv.length; i++) {
    if (argv[i] === '--cap') args.cap = Number(argv[++i]);
    if (argv[i] === '--dry-run') args.dryRun = true;
    if (argv[i] === '--verbose') VERBOSE = true;
    if (argv[i] === '--slow') args.slow = true;
    if (argv[i] === '--help' || argv[i] === '-h') {
      console.log(
        'Usage: node worker.mjs [--dry-run] [--cap N] [--slow]\n' +
          '  --dry-run  Search + read candidate info + decide, but never trash. Safe default for a first run.\n' +
          '  --cap N    Max queued jobs to process this run (default 50).\n' +
          '  --slow     Restore human-scale pacing (inter-click jitter, dwell, per-character typing). Off by default.'
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
 */
async function collectResultTiles(page) {
  const links = await page.locator(RESULT_LINK_SELECTOR).all();
  const withLabels = [];
  for (const link of links) {
    const ariaLabel = await link.getAttribute('aria-label').catch(() => null);
    if (!isRealPhotoTile(ariaLabel)) continue;
    // VERIFIED LIVE 2026-09-01: a previous search's result grid stays in the
    // DOM after the next search, collapsed to a 0x0 box. Its tiles still match
    // the selector and still carry aria-labels, so without a visibility filter
    // the walk picks a stale hidden tile and openTile() dies in
    // scrollIntoViewIfNeeded with "element is not visible".
    if (!(await link.isVisible().catch(() => false))) continue;
    withLabels.push({ locator: link, ariaLabel });
  }
  return dedupeTilesByAriaLabel(withLabels);
}

/** Thrown when a held tile locator no longer points at the tile we collected. */
export class StaleTileError extends Error {}

/**
 * Open a tile. Requires bringToFront() first — see module header note.
 *
 * Locators from .all() resolve positionally (nth(i)), so any scroll or
 * re-render shifts what they point at. A held locator was observed resolving
 * to an "unlabeled person" chip at nth(52) and hanging the run for 30s.
 * Re-check identity immediately before clicking and bail out to a re-collect
 * instead of clicking whatever now occupies that index.
 */
async function openTile(page, tile) {
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
  const locator = tileLocatorFor(page, tile.ariaLabel);
  if ((await locator.count()) === 0) {
    throw new StaleTileError(`tile gone from the grid: "${tile.ariaLabel}"`);
  }
  // Scroll BEFORE the final visibility assertion: the live grid is virtualized,
  // so a genuine tile below the fold is not actionable until scrolled to.
  await locator.first().scrollIntoViewIfNeeded().catch(() => {});
  if (!(await locator.first().isVisible().catch(() => false))) {
    throw new StaleTileError(`tile not actionable after scrolling: "${tile.ariaLabel}"`);
  }
  await stealthDelay(500, 2000); // pre-click jitter -- pure mimicry, off unless --slow
  await locator.first().click();
  await assertNoFriction(page);
  await stealthDelay(1000, 3000); // post-click settle jitter -- pure mimicry, off unless --slow
}


/**
 * A locator that finds a result tile by its aria-label rather than its index.
 * aria-labels here look like `Photo - Portrait - Aug 5, 2026, 6:54:07 PM`;
 * they contain commas and spaces but no double quotes, so they drop into an
 * attribute selector as-is.
 */
function tileLocatorFor(page, ariaLabel) {
  const escaped = ariaLabel.replace(/["\\]/g, '\\$&');
  return page.locator(`${RESULT_LINK_SELECTOR}[aria-label="${escaped}"]:visible`);
}


/**
 * Open the info panel once. Verified live 2026-09-01: the "Open info" BUTTON
 * click is unreliable in the search-context photo view (the toolbar carries
 * hidden duplicates, so a click on .first() times out), while the "i"
 * keyboard shortcut works. And "Close info" is present-but-hidden even when
 * the panel is shut, so its mere existence proves nothing.
 *
 * Readiness is therefore judged on CONTENT — poll until the panel actually
 * yields a dimensions string — rather than on any selector being visible.
 */
async function openInfoPanelOnce(page) {
  await stealthDelay(500, 1500); // pure mimicry, off unless --slow
  // The panel is sticky: once opened it stays open as you move between photos
  // and across searches. Pressing "i" when it is ALREADY open closes it, which
  // is what broke the second date of the first successful walk. Only toggle it
  // when it is genuinely shut. Verified live 2026-09-01.
  const already = await readPanelText(page);
  if (/\d{3,5}\s*[\u00d7x]\s*\d{3,5}/.test(already)) {
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

  // Real correctness wait: poll until the panel actually yields dimensions
  // text. The poll interval (pollDelay) stays fast regardless of --slow --
  // it's a local content check, not a network action Google could see the
  // cadence of.
  const deadline = Date.now() + (FAST_DELAYS ? 50 : 15000);
  let attempts = 0;
  while (Date.now() < deadline) {
    await pollDelay();
    const text = await readPanelText(page);
    if (/\d{3,5}\s*[\u00d7x]\s*\d{3,5}/.test(text)) {
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
  throw new Error('info panel never produced dimensions text after 15s — selector/UI drift, stopping rather than guessing');
}

async function readPanelText(page) {
  // Verified live: the details block is an unlabelled div. Find it by content
  // (it is the smallest element containing a "W x H" dimensions string) rather
  // than by a selector, which Google does not give us a stable one for.
  return await page.evaluate(() => {
    const DIMS = /\d{3,5}\s*[\u00d7x]\s*\d{3,5}/;
    const FILE = /[A-Za-z0-9._-]+\.(HEIC|JPG|JPEG|PNG|MOV|MP4)\b/i;
    // Smallest element containing BOTH dimensions AND a filename. Taking the
    // smallest element with dimensions alone (the earlier version) returned
    // just "7.2MP2316 x 3088" — no filename — so every photo parsed as a
    // non-match. Verified live 2026-09-01.
    const hits = Array.from(document.querySelectorAll('div,c-wiz,aside'))
      .filter((el) => {
        const t = el.innerText || '';
        return DIMS.test(t) && FILE.test(t);
      })
      .sort((a, b) => (a.innerText || '').length - (b.innerText || '').length);
    return hits.length ? hits[0].innerText : '';
  }).catch(() => '');
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
  await page.mouse.wheel(0, 600 + Math.random() * 400);
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
 * Move the currently-open photo to trash via the UI. NEVER permanent-delete.
 *
 * Returns true only if the deletion was CONFIRMED. "Open info" and "View next
 * photo" both turned out to have hidden duplicates that make a .first() click
 * silently time out, so a click that merely resolves is not evidence the photo
 * was trashed — and a job wrongly marked "trashed" is one we would never
 * revisit. Confirm by the panel moving off this photo.
 */
async function moveToTrash(page, panelTextBefore) {
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

  const settled = async () => {
    const deadline = Date.now() + (FAST_DELAYS ? 50 : 12000);
    while (Date.now() < deadline) {
      await pollDelay();
      const toast = await page.locator('text=/moved to (trash|bin)/i').first().isVisible().catch(() => false);
      if (toast) return true;
      const now = await readPanelText(page);
      if (now && now !== panelTextBefore) return true;
      if (!now && panelTextBefore) return true;
    }
    return false;
  };

  await stealthDelay(500, 2000); // pure mimicry, off unless --slow
  if (VERBOSE) console.log("    trash: pressing '#'");
  await page.keyboard.press('#');
  const tookDialog = await confirmDialog();
  if (VERBOSE) console.log(`    trash: confirmation dialog ${tookDialog ? 'accepted' : 'not shown'}`);
  if (await settled()) return true;

  // Fallback: only now, with no dialog scrim in the way, try the control.
  const candidates = await page.locator(TRASH_SELECTOR).all();
  for (const candidate of candidates) {
    if (await candidate.isVisible().catch(() => false)) {
      if (VERBOSE) console.log('    trash: falling back to clicking the visible control');
      await candidate.click();
      await confirmDialog();
      break;
    }
  }
  return await settled();
}


/**
 * Shared by the aria fast path and the exhaustive walk below: the currently
 * open photo's panel has just been read and parsed, and (by exact filename +
 * dimensions -- lib/matcher.mjs's findMatchingJob, already checked by the
 * caller) confirmed to be `job`'s photo. Live only, trashes it and records
 * the outcome on the queue; dry-run only logs. This is the ONLY place that
 * ever calls moveToTrash -- whether the tile got opened via the aria
 * pre-filter or the exhaustive walk makes no difference to how a match gets
 * confirmed or trashed.
 */
async function confirmAndTrash(page, job, parsed, text, query, queue, dryRun) {
  if (dryRun) {
    console.log(`[dry-run WOULD TRASH] ${job.filename} (search ${query})`);
    return;
  }
  const confirmed = await moveToTrash(page, text);
  const comparison = { searchDate: query, matchedFilename: parsed.filename, pixelWidth: parsed.pixelWidth, pixelHeight: parsed.pixelHeight };
  if (confirmed) {
    queue.update(job.id, { status: 'trashed', comparison, attempts: job.attempts + 1 });
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
}

/**
 * Bounded attempt to get INTO the photo view for a date, starting from
 * `candidateTile` (the date's first tile, captured by processDateGroup
 * BEFORE the aria phase's own pre-scroll runs -- see `dateFirstTile` there).
 * A held tile reference can go stale the same way any tile locator can (the
 * aria phase trashed it, or the grid re-rendered under us) -- openTile()
 * throws StaleTileError exactly as it does everywhere else it's called.
 * Re-collect fresh and retry rather than giving up on the whole date over
 * one stale reference; MAX_TILE_OPEN_RETRIES bounds it so a genuinely broken
 * date can't loop forever. Returns the tile actually opened, or null if
 * nothing on this date could be opened at all (e.g. the aria phase's own
 * trashes consumed every tile it had).
 */
async function openFirstTile(page, candidateTile) {
  let tile = candidateTile;
  for (let attempt = 0; attempt < MAX_TILE_OPEN_RETRIES; attempt++) {
    if (!tile) {
      const fresh = await collectResultTiles(page);
      tile = fresh[0] ?? null;
    }
    if (!tile) return null; // nothing left to open on this date at all
    try {
      await openTile(page, tile);
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
 */
async function walkPhotoView(page, dateFirstTile, unmatchedJobs, query, queue, dryRun) {
  let remaining = unmatchedJobs;
  if (remaining.length === 0) return { stillUnmatched: remaining };

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

  while (remaining.length > 0) {
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
    const job = findMatchingJob(remaining, parsed);
    let advancedByDelete = false;

    if (job) {
      await confirmAndTrash(page, job, parsed, text, query, queue, dryRun);
      remaining = remaining.filter((j) => j !== job);
      if (!dryRun) {
        // A trashed photo disappears from the results, and the view can
        // auto-advance to the next one BY ITSELF -- the same thing
        // moveToTrash's own settled() check already has to detect (a panel
        // that moved on from `panelTextBefore` counts as settled). Check for
        // it here too: if the panel already moved on, do NOT blindly
        // ArrowRight below, or we'd skip the very photo the auto-advance
        // just landed on.
        const afterTrash = await readPanelText(page);
        if (afterTrash && afterTrash !== text) {
          text = afterTrash;
          advancedByDelete = true;
        }
      }
    }

    if (remaining.length === 0) break;

    if (!advancedByDelete) {
      // ArrowRight does not always register: with identical code this date
      // walked 7 photos on one run and 1 on the next. A timeout therefore
      // cannot be read as "end of the day" -- that inference is what silently
      // abandoned most of a date. Retry the press, and treat the absence of
      // the next-photo control as the AUTHORITATIVE end-of-day signal instead
      // of a timeout.
      // Advancing by KEY is unreliable: ArrowRight is intermittently swallowed
      // even with focus on BODY and the next-photo control present, and some
      // photos never advanced across three retries. Prefer CLICKING the
      // next-photo control, picking the genuinely visible match out of its
      // several same-labelled elements (the same hidden-duplicate trap that
      // made the trash button silently do nothing). Keep the key as fallback.
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
        next = await waitForPanelChange(page, text);
        if (next != null) break;
        if (candidates.length === 0) break; // genuinely the last photo of the day
        if (VERBOSE) {
          console.log(
            `  [photo ${steps}] advance did not register via ${clicked ? 'click' : 'ArrowRight'}, retrying (${attempt + 1}/${ARROW_RETRIES})`
          );
        }
      }
      if (next == null) {
        // Either genuinely the last photo of the day, or ArrowRight did not
        // take (e.g. focus sitting somewhere that swallows it). Those look
        // identical from here, so say so rather than silently calling the
        // date done.
        if (VERBOSE) {
          const focus = await page
            .evaluate(() => {
              const a = document.activeElement;
              return a ? `${a.tagName}[${(a.getAttribute('aria-label') || a.className || '').toString().slice(0, 40)}]` : 'none';
            })
            .catch(() => 'unknown');
          console.log(`  [photo ${steps}] ArrowRight produced no panel change (end of day, or the key was swallowed). activeElement=${focus}`);
        }
        break;
      }
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

export async function processDateGroup(page, dateStr, unmatchedJobs, queue, { dryRun }) {
  let remaining = [...unmatchedJobs];
  if (remaining.length === 0) return { stillUnmatched: remaining };

  const query = await searchByDate(page, dateStr);
  let tiles = await collectResultTiles(page);
  if (VERBOSE) console.log(`[search ${query}] ${tiles.length} visible photo tile(s)`);
  if (tiles.length === 0) {
    console.log(`[search ${query}] no results`);
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
  const seen = new Map(); // ariaLabel -> tile, first-seen copy
  let scrollAttempts = 0;

  const mergeSeen = (freshTiles) => {
    let addedNew = false;
    for (const t of freshTiles) {
      if (!seen.has(t.ariaLabel)) {
        seen.set(t.ariaLabel, t);
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
  }

  // --- Exhaustive fallback: in-photo-view traversal (see walkPhotoView) --
  return await walkPhotoView(page, dateFirstTile, remaining, query, queue, dryRun);
}

/**
 * Process every date group: UTC-derived date first, then day-1 and day+1
 * only for jobs still unmatched after the prior attempt. Anything left
 * unmatched after all three attempts becomes needs_review.
 */
export async function runDateGroups(page, groupedJobs, queue, { dryRun }) {
  for (const [dateStr, jobs] of groupedJobs) {
    let unmatched = [...jobs];
    const attemptDates = [dateStr, shiftDateDays(dateStr, -1), shiftDateDays(dateStr, 1)];

    try {
      for (const attemptDate of attemptDates) {
        if (unmatched.length === 0) break;
        const { stillUnmatched } = await processDateGroup(page, attemptDate, unmatched, queue, { dryRun });
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
        for (const job of unmatched) {
          queue.update(job.id, { status: 'error', error: String(err.message || err), attempts: job.attempts + 1 });
        }
      }
      throw err; // stop the whole run, no silent retry loop
    }

    for (const job of unmatched) {
      if (dryRun) {
        console.log(`[dry-run needs_review] ${job.filename}: no filename+dimensions match for ${dateStr} (+/-1 day)`);
      } else {
        queue.update(job.id, {
          status: 'needs_review',
          comparison: { reason: `no filename+dimensions match for ${dateStr} (+/-1 day)` },
          attempts: job.attempts + 1,
        });
        console.log(`[needs_review] ${job.filename}: no filename+dimensions match for ${dateStr} (+/-1 day)`);
      }
    }
    await stealthDelay(PACE_MS_MIN, PACE_MS_MAX); // pace between date groups — pure mimicry, off unless --slow
  }
}

export async function runWorker({ cap = DEFAULT_CAP, dryRun = false } = {}) {
  const queue = new JobQueue(QUEUE_PATH);
  const jobs = queue.loadAll().filter((j) => j.status === 'queued').slice(0, cap);

  if (jobs.length === 0) {
    console.log('no queued jobs');
    return;
  }

  const groups = groupJobsByDate(jobs);

  if (dryRun) {
    console.log(`--dry-run: will search + decide for ${jobs.length} job(s) across ${groups.size} date(s) but never trash or mutate the queue.`);
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
    await openPhotosHome(page);
    await runDateGroups(page, groups, queue, { dryRun });
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

if (import.meta.url === `file://${process.argv[1]}`) {
  const args = parseArgs(process.argv.slice(2));
  if (args.slow) SLOW = true;
  runWorker(args).catch((err) => {
    loud(`BLOCKER: unhandled worker failure: ${err.stack || err}`);
    process.exit(1);
  });
}
