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
const OPEN_INFO_SELECTOR = 'button[aria-label="Open info"]';
const INFO_PANEL_SELECTOR = '[aria-label="Info"], [role="complementary"]';
const NEXT_PHOTO_SELECTOR = 'button[aria-label="View next photo" i]';
const TRASH_SELECTOR = 'button[aria-label="Move to trash" i]';
// Randomized 4-9s between jobs (was a fixed 4000ms) — a constant interval is
// itself a bot signature per rules/social-media-browsing.md; jitter it.
const PACE_MS_MIN = 4000;
const PACE_MS_MAX = 9000;
// Bound the walk through a single day's search results so a huge day can't
// loop forever. Unmatched jobs for that date attempt just fall through to
// the next date attempt (or needs_review) once the cap is hit.
export const MAX_STEPS_PER_DATE = 80;

function parseArgs(argv) {
  const args = { cap: DEFAULT_CAP, dryRun: false };
  for (let i = 0; i < argv.length; i++) {
    if (argv[i] === '--cap') args.cap = Number(argv[++i]);
    if (argv[i] === '--dry-run') args.dryRun = true;
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
 * Search Google Photos by calendar date ("<Month> <D>, <YYYY>") using the
 * app's own search box (never goto()'ing a /search/<query> URL directly —
 * see module header). Types character-by-character with human-scale delay
 * rather than page.fill(), which pastes the whole string in one DOM
 * mutation and is a well-known automation tell.
 */
async function searchByDate(page, dateStr) {
  const query = formatSearchDate(dateStr);
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
    withLabels.push({ locator: link, ariaLabel });
  }
  return dedupeTilesByAriaLabel(withLabels.filter((t) => isRealPhotoTile(t.ariaLabel)));
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

/** Open the info panel once (button, falling back to the "i" shortcut). */
async function openInfoPanelOnce(page) {
  const infoButton = page.locator(OPEN_INFO_SELECTOR).first();
  if (await infoButton.count()) {
    await randomDelay(500, 2000);
    await infoButton.click();
  } else {
    await page.keyboard.press('i');
  }
  const panel = page.locator(INFO_PANEL_SELECTOR).first();
  await panel.waitFor({ state: 'visible', timeout: 10000 });
  await randomDelay(1000, 3000); // dwell reading the panel before extracting text
}

async function readPanelText(page) {
  return (await page.locator(INFO_PANEL_SELECTOR).first().textContent().catch(() => '')) ?? '';
}

/** Step to the next photo in the day, keeping the info panel open. Returns false when there's no next photo. */
async function viewNextPhoto(page) {
  const nextButton = page.locator(NEXT_PHOTO_SELECTOR).first();
  if (!(await nextButton.count())) return false;
  await randomDelay(1000, 3000);
  await nextButton.click();
  await assertNoFriction(page);
  await randomDelay(1000, 3000); // dwell for the panel to update before reading it
  return true;
}

/** Move the currently-open photo to trash via the UI. NEVER permanent-delete. */
async function moveToTrash(page) {
  const trashButton = page.locator(TRASH_SELECTOR).first();
  await randomDelay(500, 2000);
  await trashButton.click();
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
    const job = findMatchingJob(remaining, parsed);
    if (job) {
      if (dryRun) {
        console.log(`[dry-run WOULD TRASH] ${job.filename} (search ${query})`);
      } else {
        await moveToTrash(page);
        queue.update(job.id, {
          status: 'trashed',
          comparison: { searchDate: query, matchedFilename: parsed.filename, pixelWidth: parsed.pixelWidth, pixelHeight: parsed.pixelHeight },
          attempts: job.attempts + 1,
        });
        console.log(`[trashed] ${job.filename} (search ${query})`);
      }
      remaining = remaining.filter((j) => j !== job);
    }
    steps += 1;
    if (remaining.length === 0) break;
    hasMore = await viewNextPhoto(page);
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
