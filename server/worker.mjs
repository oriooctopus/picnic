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
 *   4. Open the first tile, open the info panel once, then step through
 *      the day with "View next photo", reading + parsing the panel per
 *      photo (lib/matcher.mjs's parsePanelText).
 *   5. A photo confirms a job when filename matches exactly AND dimensions
 *      agree (either orientation) — lib/matcher.mjs's findMatchingJob.
 *   6. Because the job's creationDate is UTC and Google Photos displays
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
 * Connects to the persistent Windows Chrome (profile signed into
 * oliverullman@gmail.com) via the CDP relay on the WSL2 default-route
 * gateway, port 9251. Per ~/.claude/rules/playwright.md: any CDP/selector
 * failure is surfaced loudly and the run stops (no silent retry loops).
 *
 * Run: node worker.mjs --dry-run [--cap 50]   (safe: never trashes anything)
 *      node worker.mjs --cap 50               (live: trashes matched photos)
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
const NEXT_PHOTO_SELECTOR = '[aria-label="View next photo" i]';
// NOT scoped to <button>: these toolbar controls are not necessarily real
// button elements, and a 'button[...]' selector silently matched nothing —
// which sent moveToTrash down its keyboard fallback and deleted nothing at
// all, twice. Match on the aria-label alone. Verified live 2026-09-01.
const TRASH_SELECTOR = '[aria-label="Move to trash" i]';
// Randomized 4-9s between jobs (was a fixed 4000ms) — a constant interval is
// itself a bot signature per rules/social-media-browsing.md; jitter it.
const PACE_MS_MIN = 4000;
const PACE_MS_MAX = 9000;
// Bound the walk through a single day's search results so a huge day can't
// loop forever. Unmatched jobs for that date attempt just fall through to
// the next date attempt (or needs_review) once the cap is hit.
let VERBOSE = false;
export const MAX_STEPS_PER_DATE = 80;

function parseArgs(argv) {
  const args = { cap: DEFAULT_CAP, dryRun: false };
  for (let i = 0; i < argv.length; i++) {
    if (argv[i] === '--cap') args.cap = Number(argv[++i]);
    if (argv[i] === '--dry-run') args.dryRun = true;
    if (argv[i] === '--verbose') VERBOSE = true;
    if (argv[i] === '--help' || argv[i] === '-h') {
      console.log(
        'Usage: node worker.mjs [--dry-run] [--cap N]\n' +
          '  --dry-run  Search + read candidate info + decide, but never trash. Safe default for a first run.\n' +
          '  --cap N    Max queued jobs to process this run (default 50).'
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

// Test-only escape hatch: the real pacing (1-9s per action) makes the unit
// suite take minutes for no benefit, since node:test never touches a real
// browser or a real rate limiter. Gated by an explicit opt-in env var (never
// a silent/default change) so production runs always get real human-scale
// jitter; only worker.test.mjs sets this, before importing the module.
const FAST_DELAYS = process.env.PICNIC_WORKER_FAST_DELAYS === '1';

/**
 * Random delay in [min, max] ms. Used everywhere instead of a fixed sleep()
 * so the whole run's timing pattern doesn't look scripted — a fixed
 * interval between actions is itself a bot signature (rules/
 * social-media-browsing.md).
 */
function randomDelay(min, max) {
  if (FAST_DELAYS) return sleep(0);
  const ms = min + Math.random() * (max - min);
  return sleep(ms);
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
  await randomDelay(1000, 3000); // dwell on the loaded page like a person
}

/**
 * Leave the photo detail view, if one is open, so the search box is reachable
 * again. Verified live 2026-09-01: after walking a date's photos the detail
 * view still covers the app, and the search input resolves but is NOT visible,
 * so the next date's search dies with a click timeout. Escape is the app's own
 * dismiss affordance (no goto/reload, per rules/playwright.md).
 */
async function closeAnyOpenPhoto(page) {
  const searchBox = page.locator(SEARCH_BOX_SELECTOR).first();
  for (let attempt = 0; attempt < 4; attempt++) {
    if (await searchBox.isVisible().catch(() => false)) return;
    await page.keyboard.press('Escape');
    await randomDelay(900, 1800);
  }
  if (!(await searchBox.isVisible().catch(() => false))) {
    throw new Error('search box still not reachable after 4 Escape presses — UI drift, stopping rather than forcing navigation');
  }
}

/**
 * Search Google Photos by calendar date ("<Month> <D>, <YYYY>") using the
 * app's own search box (never goto()'ing a /search/<query> URL directly —
 * see module header). Types character-by-character with human-scale delay
 * rather than page.fill(), which pastes the whole string in one DOM
 * mutation and is a well-known automation tell.
 */
async function searchByDate(page, dateStr) {
  const query = formatSearchDate(dateStr);
  await closeAnyOpenPhoto(page);
  const searchBox = page.locator(SEARCH_BOX_SELECTOR).first();
  await searchBox.click();
  await randomDelay(1000, 4000);
  // Clear any prior query with the keyboard rather than fill().
  await page.keyboard.press('Control+A');
  await page.keyboard.press('Delete');
  await page.keyboard.type(query, { delay: 80 + Math.random() * 70 }); // 80-150ms/char
  await randomDelay(2000, 6000); // dwell before submitting, like a person re-reading the query
  await page.keyboard.press('Enter');
  await page.locator(RESULT_LINK_SELECTOR).first().waitFor({ state: 'visible', timeout: 20000 }).catch(() => {});
  await assertNoFriction(page);
  await randomDelay(1500, 3500); // dwell on the results before acting on them
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

/** Open a tile. Requires bringToFront() first — see module header note. */
async function openTile(page, tile) {
  await page.bringToFront();
  await tile.locator.scrollIntoViewIfNeeded();
  await randomDelay(500, 2000);
  await tile.locator.click();
  await assertNoFriction(page);
  await randomDelay(1000, 3000);
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
  await randomDelay(500, 1500);
  // The panel is sticky: once opened it stays open as you move between photos
  // and across searches. Pressing "i" when it is ALREADY open closes it, which
  // is what broke the second date of the first successful walk. Only toggle it
  // when it is genuinely shut. Verified live 2026-09-01.
  const already = await readPanelText(page);
  if (/\d{3,5}\s*[\u00d7x]\s*\d{3,5}/.test(already)) {
    await randomDelay(400, 1200);
    return;
  }
  await page.keyboard.press('i');

  const deadline = Date.now() + (FAST_DELAYS ? 50 : 15000);
  while (Date.now() < deadline) {
    await randomDelay(700, 1400);
    const text = await readPanelText(page);
    if (/\d{3,5}\s*[\u00d7x]\s*\d{3,5}/.test(text)) {
      await randomDelay(800, 2000); // dwell reading the panel
      return;
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

/** Step to the next photo in the day, keeping the info panel open. Returns false when there's no next photo. */
async function viewNextPhoto(page, previousText) {
  // The "View next photo" BUTTON is present but not reliably clickable in the
  // search-context photo view (same hidden-duplicate problem as "Open info"),
  // so the walk never advanced past the first photo. ArrowRight is Google
  // Photos' own next-photo shortcut and works there. Verified live 2026-09-01.
  await randomDelay(900, 2200);
  const button = page.locator(NEXT_PHOTO_SELECTOR).first();
  if (await button.isVisible().catch(() => false)) {
    await button.click().catch(() => {});
  } else {
    await page.keyboard.press('ArrowRight');
  }
  await assertNoFriction(page);

  // Advancement is confirmed by the panel CONTENT changing, not by a click
  // resolving: unchanged text after the dwell means we're at the last photo.
  const deadline = Date.now() + (FAST_DELAYS ? 50 : 8000);
  while (Date.now() < deadline) {
    await randomDelay(700, 1400);
    const text = await readPanelText(page);
    if (text && text !== previousText) return true;
  }
  return false;
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
  await randomDelay(500, 2000);
  const trashButton = page.locator(TRASH_SELECTOR).first();
  const trashVisible = await trashButton.isVisible().catch(() => false);
  if (VERBOSE) console.log(`    trash control: count=${await page.locator(TRASH_SELECTOR).count()} visible=${trashVisible}`);
  if (trashVisible) {
    // NOT .catch(() => {}): swallowing the click error is what made the first
    // real run indistinguishable from "clicked but Google ignored it". Let it
    // throw so the caller records a real reason.
    await trashButton.click();
  } else {
    // Keyboard fallback only. Note focus often sits on "Back to search" in
    // this view, so the shortcut may go nowhere — hence the confirmation below.
    await page.keyboard.press('#');
  }

  // A confirmation dialog may appear; take it only if it is actually there.
  const confirm = page.locator('button:has-text("Move to trash"), button:has-text("Delete")').first();
  if (await confirm.isVisible().catch(() => false)) {
    await randomDelay(600, 1600);
    await confirm.click();
  }

  // Confirmation, in priority order:
  //  1. Google's own "Moved to trash" toast — unambiguous.
  //  2. The panel moving to a DIFFERENT photo.
  //  3. The photo view closing entirely (panel text empties) — trashing the
  //     last item returns to the grid, which the first version wrongly read as
  //     "no change" because an empty string is falsy.
  const deadline = Date.now() + (FAST_DELAYS ? 50 : 12000);
  while (Date.now() < deadline) {
    await randomDelay(700, 1500);
    const toast = await page
      .locator('text=/moved to trash/i')
      .first()
      .isVisible()
      .catch(() => false);
    if (toast) return true;
    const now = await readPanelText(page);
    if (now && now !== panelTextBefore) return true;
    if (!now && panelTextBefore) return true;
  }
  return false;
}

/**
 * Search one calendar date and walk its results, confirming and (live
 * only) trashing every still-unmatched job it can. Returns the jobs from
 * `unmatchedJobs` that remain unconfirmed after this date's walk.
 */
export async function processDateGroup(page, dateStr, unmatchedJobs, queue, { dryRun }) {
  let remaining = [...unmatchedJobs];
  if (remaining.length === 0) return { stillUnmatched: remaining };

  const query = await searchByDate(page, dateStr);
  const tiles = await collectResultTiles(page);
  if (VERBOSE) console.log(`[search ${query}] ${tiles.length} visible photo tile(s)`);
  if (tiles.length === 0) {
    console.log(`[search ${query}] no results`);
    return { stillUnmatched: remaining };
  }

  await openTile(page, tiles[0]);
  await openInfoPanelOnce(page);

  let steps = 0;
  let hasMore = true;
  while (hasMore && remaining.length > 0 && steps < MAX_STEPS_PER_DATE) {
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
      if (dryRun) {
        console.log(`[dry-run WOULD TRASH] ${job.filename} (search ${query})`);
      } else {
        const confirmed = await moveToTrash(page, text);
        const comparison = { searchDate: query, matchedFilename: parsed.filename, pixelWidth: parsed.pixelWidth, pixelHeight: parsed.pixelHeight };
        if (confirmed) {
          queue.update(job.id, { status: 'trashed', comparison, attempts: job.attempts + 1 });
          console.log(`[trashed] ${job.filename} (search ${query})`);
        } else {
          // Matched the right photo but could not prove the trash took. Leave
          // it for a human rather than recording a deletion that may not have
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
      remaining = remaining.filter((j) => j !== job);
    }
    steps += 1;
    if (remaining.length === 0) break;
    hasMore = await viewNextPhoto(page, text);
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
        if (unmatched.length > 0) await randomDelay(PACE_MS_MIN, PACE_MS_MAX);
      }
    } catch (err) {
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
    await randomDelay(PACE_MS_MIN, PACE_MS_MAX); // pace between date groups
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
  runWorker(args).catch((err) => {
    loud(`BLOCKER: unhandled worker failure: ${err.stack || err}`);
    process.exit(1);
  });
}
