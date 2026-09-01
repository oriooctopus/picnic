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
 *   5. Exhaustive fallback: open the first unvisited tile, open the info
 *      panel once, then step through the day's tiles, reading + parsing
 *      the panel per photo (lib/matcher.mjs's parsePanelText).
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
export const MAX_STEPS_PER_DATE = 80;
// Bound the "scroll for more tiles" loop separately from the tile-open bound
// above -- a date with a huge grid must not scroll forever trying to find
// tiles that were never going to load.
export const MAX_SCROLL_ATTEMPTS_PER_DATE = 6;
// Bound how many times the exhaustive walk retries a SINGLE known tile that
// keeps throwing StaleTileError before giving up on it specifically (see the
// "UNREACHABLE" branch in processDateGroup below) -- distinct from
// MAX_STEPS_PER_DATE (bounds the whole date's total attempts) and
// MAX_SCROLL_ATTEMPTS_PER_DATE (bounds consecutive scrolls that find nothing
// AT ALL on-screen). Small on purpose: a tile that still won't open after a
// few scroll+retry rounds is not going to succeed on one more -- better to
// record it and move on than burn the date's shared step budget hammering a
// single broken tile forever.
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
  const searchBox = page.locator(SEARCH_BOX_SELECTOR).first();
  for (let attempt = 0; attempt < 4; attempt++) {
    if (await searchBox.isVisible().catch(() => false)) return;
    await page.keyboard.press('Escape');
    const deadline = Date.now() + (FAST_DELAYS ? 20 : 2000);
    while (Date.now() < deadline) {
      if (await searchBox.isVisible().catch(() => false)) return;
      await pollDelay();
    }
  }
  if (!(await searchBox.isVisible().catch(() => false))) {
    throw new Error('search box still not reachable after 4 Escape presses — UI drift, stopping rather than forcing navigation');
  }
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
 * Search one calendar date and walk its results EXHAUSTIVELY -- every visible
 * tile, not just those an accelerator like "next photo" happens to reach --
 * confirming and (live only) trashing every still-unmatched job it can.
 * Returns the jobs from `unmatchedJobs` that remain unconfirmed after this
 * date's walk.
 *
 * Tiles are tracked as visited by `aria-label` (carries media type,
 * orientation and capture time to the second -- see isRealPhotoTile /
 * dedupeTilesByAriaLabel in lib/matcher.mjs), never by array index: the grid
 * re-renders between tiles and indices shift.
 */

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

  const visited = new Set();
  // BUG FIX (2026-09-01, live): union of every real tile aria-label ever
  // observed on this date, across every re-collection and scroll. Needed
  // because Google's result grid is VIRTUALIZED -- collectResultTiles() only
  // ever returns what's currently mounted/on-screen, never the whole date.
  // The old exhaustive walk judged "did this scroll find anything new?" by
  // comparing `tiles.length` before/after -- which is wrong for a
  // virtualized grid: scrolling swaps the mounted WINDOW (old tiles unmount
  // as new ones mount), so the on-screen COUNT can stay flat or even shrink
  // while the CONTENT is entirely different. That false "nothing new" read
  // is exactly what made a 27-tile day report EXHAUSTED after 3 tiles live.
  // `seen` is the walk's memory of "what actually exists on this date",
  // independent of what happens to be on-screen at any one instant --
  // mergeSeen() below is the corrected comparison, done on the LABEL SET
  // rather than a count.
  const seen = new Map(); // ariaLabel -> tile, first-seen copy
  // Tiles `seen` at some point but which never became actionable after
  // MAX_TILE_OPEN_RETRIES scroll+retry attempts (see the StaleTileError
  // branch below). Tracked separately from `visited` (which means "actually
  // opened and its panel read") so a genuine EXHAUSTED report can mean what
  // it says -- every seen label accounted for -- rather than silently
  // dropping a tile the grid just wouldn't mount.
  const unreachable = new Set();
  const openAttempts = new Map(); // ariaLabel -> retry count so far, for the StaleTileError branch
  let steps = 0;
  let scrollAttempts = 0;
  // Consecutive top-of-loop scroll rounds (see the "no candidate on-screen"
  // branch below) that revealed no previously-unseen label. Reset by ANY
  // progress -- a newly-seen label, or a tile actually opened -- so the walk
  // only gives up after a genuine run of fruitless scrolling. This is a
  // SEPARATE budget from the aria fast path's own pre-scroll loop above
  // (see that loop's `scrollAttempts`) -- sharing one budget between the two
  // phases meant the pre-scroll could spend the whole thing just loading the
  // day, leaving the walk's very first "nothing on-screen" check to break
  // immediately and report a date EXHAUSTED with 25 of 27 tiles never
  // visited. Regression test 85 in worker.test.mjs proves this by mutation.
  let walkScrollAttempts = 0;
  let boundHit = false;

  /**
   * Merge freshly-collected tiles into `seen`. Returns true iff at least one
   * label was genuinely NEW. This is the corrected "did scrolling reveal
   * anything" signal -- see the comment on `seen` above for why comparing
   * label sets (not tile counts) is what actually detects progress on a
   * virtualized grid.
   */
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

  // --- CHANGE 1: aria fast path -------------------------------------------
  // Predict which tiles are worth opening from the grid's own aria-labels
  // (capture time to the SECOND) before falling back to opening every tile.
  // planAriaMatches() needs the date's FULL tile set to judge safety -- a
  // tile that hasn't loaded yet could be the duplicate that makes a
  // seemingly-unique match actually ambiguous -- so scroll to completion
  // first. This costs at most one wasted scroll+recollect when there was
  // nothing more to load (cheap; VERIFIED via the fake-page unit suite,
  // never against live Google Photos -- see the module header).
  while (scrollAttempts < MAX_SCROLL_ATTEMPTS_PER_DATE) {
    const beforeCount = tiles.length;
    await scrollResults(page);
    scrollAttempts += 1;
    tiles = await collectResultTiles(page);
    if (tiles.length <= beforeCount) break; // scroll revealed nothing new -- fully loaded
  }

  const ariaPlan = planAriaMatches(remaining, tiles);
  if (ariaPlan) {
    if (VERBOSE) {
      console.log(`[search ${query}] aria fast path: ${ariaPlan.size}/${remaining.length} job(s) matched to a tile, opening only those`);
    }
    for (const [job, tile] of ariaPlan) {
      visited.add(tile.ariaLabel);
      // Keep `seen` in sync with `visited` for aria-opened tiles too --
      // otherwise a tile opened here (and, say, later trashed and dropped
      // from the grid) never enters `seen` at all, and the exhaustive
      // walk's end-of-date summary below can end up reporting more tiles
      // "opened" than it ever "saw" (visited.size > seen.size), which is a
      // nonsensical thing to print even though it doesn't affect
      // correctness (visited/unreachable membership, not seen membership,
      // drives candidate selection).
      mergeSeen([tile]);
      steps += 1;
      try {
        await openTile(page, tile);
      } catch (err) {
        if (err instanceof StaleTileError) {
          // Grid shifted under us since planAriaMatches ran. Don't guess --
          // leave this job for the exhaustive walk below, which re-collects
          // tiles fresh and will still reach it if it's there.
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
    tiles = await collectResultTiles(page); // grid re-renders after trashing/closing
  }

  mergeSeen(tiles); // seed `seen` with everything already known from the aria phase above

  // --- Exhaustive fallback ------------------------------------------------
  // Walks every tile this date has ever revealed (tracked in `seen`, not
  // just what's on-screen right now) until every remaining job is matched,
  // every seen tile is accounted for, or a bound is hit. See the comments on
  // `seen`/`unreachable`/`mergeSeen` above for why this is no longer a
  // straight "walk what's currently rendered" loop.
  while (remaining.length > 0) {
    // Prefer a tile that's on-screen RIGHT NOW (in this round's `tiles`
    // snapshot) and neither already visited nor already given up on.
    // openTile needs a real, actionable element -- a label merely present in
    // `seen` but currently scrolled out of the mounted window isn't
    // actionable until a scroll brings it back on-screen.
    let tile = tiles.find((t) => !visited.has(t.ariaLabel) && !unreachable.has(t.ariaLabel));

    if (!tile) {
      // Nothing on-screen is both unvisited and not given up on. Before
      // concluding the date is exhausted, scroll the grid and re-collect --
      // it's virtualized, so unwalked tiles can exist off-screen even when
      // the on-screen tile COUNT didn't grow (see mergeSeen's comment: a
      // scroll that swaps the mounted window for an equally-sized one still
      // reveals genuinely new content).
      if (walkScrollAttempts >= MAX_SCROLL_ATTEMPTS_PER_DATE) break; // give up scrolling -- see EXHAUSTED-vs-ABANDONED reporting below
      await scrollResults(page);
      const fresh = await collectResultTiles(page);
      tiles = fresh;
      if (mergeSeen(fresh)) {
        walkScrollAttempts = 0; // genuine progress -- keep scrolling as long as it keeps paying off
      } else {
        // A scroll that revealed nothing UNSEEN. Deliberately NOT the old
        // `tiles.length <= beforeCount` check: that compares on-screen
        // COUNTS, which stay flat across a virtualized window swap even
        // though the labels underneath moved on entirely -- exactly the bug
        // that made a 27-tile day report EXHAUSTED after 3 tiles live.
        // Comparing against `seen`'s label set is what actually detects
        // "this scroll genuinely found nothing new".
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
        // A tile we KNOW exists (it was on-screen a moment ago) failed to
        // open -- e.g. the grid re-virtualized it out between collecting and
        // clicking. Retry a bounded number of times, scrolling in between in
        // case that's what brings it back, before giving up on THIS tile
        // specifically.
        //
        // Crucially this does NOT add the tile to `visited` on failure. The
        // OLD code marked a tile visited BEFORE attempting to open it, so a
        // tile that merely failed to open was silently counted as "walked"
        // and never retried -- precisely how a date could report EXHAUSTED
        // while most of it was never actually opened.
        const attempts = (openAttempts.get(tile.ariaLabel) ?? 0) + 1;
        openAttempts.set(tile.ariaLabel, attempts);
        if (attempts >= MAX_TILE_OPEN_RETRIES) {
          unreachable.add(tile.ariaLabel);
          console.log(
            `[date ${query}] UNREACHABLE: "${tile.ariaLabel}" never became actionable after ${attempts} attempt(s) — ` +
              'giving up on this tile, NOT counting it as walked'
          );
        } else {
          if (VERBOSE) console.log(`  [step ${steps}] ${err.message} — retry ${attempts}/${MAX_TILE_OPEN_RETRIES} after scrolling`);
          await scrollResults(page);
        }
        tiles = await collectResultTiles(page);
        mergeSeen(tiles);
        continue;
      }
      throw err;
    }

    // Only reaching here means the tile genuinely opened -- only NOW is it
    // safe to count it as visited (see the StaleTileError comment above).
    visited.add(tile.ariaLabel);
    openAttempts.delete(tile.ariaLabel);
    walkScrollAttempts = 0; // opening a tile is progress too

    await openInfoPanelOnce(page);
    const text = await readPanelText(page);
    const parsed = parsePanelText(text);
    if (VERBOSE) {
      console.log(
        `  [step ${steps}] panel: filename=${parsed.filename ?? '(none)'} ` +
          `dims=${parsed.pixelWidth ?? '?'}x${parsed.pixelHeight ?? '?'}` +
          (parsed.filename ? '' : ` rawLen=${(text || '').length} raw="${(text || '').slice(0, 120)}"`)
      );
    }
    const job = findMatchingJob(remaining, parsed);
    if (job) {
      await confirmAndTrash(page, job, parsed, text, query, queue, dryRun);
      remaining = remaining.filter((j) => j !== job);
    }

    if (remaining.length === 0) break;

    await closeAnyOpenPhoto(page);
    tiles = await collectResultTiles(page); // DOM re-renders on return to the grid
    mergeSeen(tiles);
  }

  if (remaining.length > 0) {
    // EXHAUSTED means exactly what the brief requires it to mean: every
    // tile this walk ever saw (`seen`) has either been opened (`visited`) or
    // explicitly given up on after retries (`unreachable`) -- nothing was
    // silently skipped. Classify on THAT invariant, not on which bound
    // happened to fire the `break`: hitting the scroll-fruitless bound
    // (walkScrollAttempts) only means the date is done in THIS walk's
    // provable case, where the "no on-screen candidate" branch already
    // established seen == visited ∪ unreachable before scrolling even
    // started, so consecutive fruitless scrolls after that can never leave
    // anything genuinely unwalked. `unwalked > 0` is the one case that would
    // actually contradict that -- reserved for MAX_STEPS_PER_DATE cutting
    // the walk off mid-day, or a future change that breaks the invariant.
    const unwalked = seen.size - visited.size - unreachable.size;
    if (boundHit || unwalked > 0) {
      const why = boundHit ? `MAX_STEPS_PER_DATE (${MAX_STEPS_PER_DATE}) reached` : `${MAX_SCROLL_ATTEMPTS_PER_DATE} consecutive fruitless scroll(s)`;
      console.log(
        `[date ${query}] ABANDONED: ${why}, ${remaining.length} job(s) still unmatched` +
          (unwalked > 0 ? `, ${unwalked} seen tile(s) never reached` : '')
      );
    } else {
      // Don't say "walked" for a tile that only ever got recorded
      // unreachable -- it was explicitly given up on after retries, never
      // actually opened, and EXHAUSTED must not imply otherwise (the
      // per-tile UNREACHABLE line above already named it distinctly).
      const unreachableNote = unreachable.size > 0 ? `, ${unreachable.size} unreachable (see UNREACHABLE above)` : '';
      console.log(
        `[date ${query}] EXHAUSTED: ${visited.size} tile(s) opened${unreachableNote} of ${seen.size} seen, ${remaining.length} job(s) still unmatched`
      );
    }
  }

  return { stillUnmatched: remaining };
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
