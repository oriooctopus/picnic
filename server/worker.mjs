#!/usr/bin/env node
/**
 * Drains queued Picnic mirror jobs against Google Photos web.
 *
 * Per job: search photos.google.com by filename, open each candidate's info
 * panel, and require filename + capture timestamp + pixel dimensions to ALL
 * agree (see lib/matcher.mjs) before moving the photo to Google Photos
 * TRASH. Never permanent-delete. Ambiguous (0 or >1 agreeing candidates) ->
 * needs_review, never guess.
 *
 * Connects to the persistent Windows Chrome (profile signed into
 * oliverullman@gmail.com) via the CDP relay on the WSL2 default-route
 * gateway, port 9251. Per ~/.claude/rules/playwright.md: any CDP/selector
 * failure is surfaced loudly and the run stops (no silent retry loops).
 *
 * NOTE: this file has intentionally NOT been run against real Google Photos
 * (per task instructions — the live test happens later with Oliver). The
 * DOM selectors in searchCandidates/openInfoPanel/moveToTrash are
 * best-effort against Google Photos' current web UI and MUST be verified
 * against the live site on the first real run before trusting its output.
 * DEFAULT to --dry-run for that first live run: it exercises search, info
 * reads, and decideMatch without ever calling moveToTrash.
 *
 * Run: node worker.mjs --dry-run [--cap 50]   (safe: never trashes anything)
 *      node worker.mjs --cap 50               (live: trashes matched photos)
 */
import { execSync } from 'node:child_process';
import { homedir } from 'node:os';
import { join } from 'node:path';
import { JobQueue } from './lib/queue.mjs';
import { decideMatch } from './lib/matcher.mjs';

const QUEUE_PATH = process.env.PICNIC_QUEUE_PATH || join(homedir(), '.local/share/picnic/queue.jsonl');
const DEFAULT_CAP = 50;
const SEARCH_BOX_SELECTOR = 'input[aria-label*="Search" i], input[placeholder*="Search" i]';
const TILE_SELECTOR = '[data-latest-bg], a[href^="./photo/"]';
// Randomized 4-9s between jobs (was a fixed 4000ms) — a constant interval is
// itself a bot signature per rules/social-media-browsing.md; jitter it.
const PACE_MS_MIN = 4000;
const PACE_MS_MAX = 9000;
// At most 3 candidates opened per job (was 10) — opening every search hit
// back-to-back is "rapid-fire enumeration", the strongest scraper signature
// per rules/social-media-browsing.md. 3 is enough for decideMatch's
// all-fields-agree check to find (or rule out) the real match in practice.
export const MAX_CANDIDATES_PER_JOB = 3;

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
  // the network never goes idle and the wait dies with "Target page,
  // context or browser has been closed" instead of ever resolving (observed
  // on the first live run, 2026-09-01). Wait for a real piece of the UI
  // instead — that is what "loaded" actually means here.
  await page.goto('https://photos.google.com', { waitUntil: 'domcontentloaded' });
  await assertNoFriction(page);
  await page.locator(SEARCH_BOX_SELECTOR).first().waitFor({ state: 'visible', timeout: 30000 });
  await randomDelay(1000, 3000); // dwell on the loaded page like a person
}

/**
 * Search Google Photos by filename using the app's own search box (never
 * goto()'ing a /search/<query> URL directly — see module header). Types
 * the filename character-by-character with human-scale delay rather than
 * page.fill(), which pastes the whole string in one DOM mutation and is a
 * well-known automation tell.
 */
async function searchCandidates(page, filename) {
  const searchBox = page.locator(SEARCH_BOX_SELECTOR).first();
  await searchBox.click();
  await randomDelay(1000, 4000);
  // Clear any prior query with the keyboard rather than fill(): fill() pastes
  // in a single DOM mutation, which rules/social-media-browsing.md calls out.
  await page.keyboard.press('Control+A');
  await page.keyboard.press('Delete');
  await page.keyboard.type(filename, { delay: 80 + Math.random() * 70 }); // 80-150ms/char
  await randomDelay(2000, 6000); // dwell before submitting, like a person re-reading the query
  await page.keyboard.press('Enter');
  // See openPhotosHome: networkidle never settles on this site. Wait for the
  // results themselves, and treat "no tiles" as a real empty result rather
  // than hanging.
  await page.locator(TILE_SELECTOR).first().waitFor({ state: 'visible', timeout: 20000 }).catch(() => {});
  await assertNoFriction(page);
  await randomDelay(1500, 3500); // dwell on the results before acting on them

  // Photo tiles in Google Photos search results.
  const tiles = await page.locator(TILE_SELECTOR).all();
  return tiles;
}

/**
 * Open a candidate's info panel (the "i" details view) and read back
 * filename, capture timestamp, and pixel dimensions as displayed by Google
 * Photos.
 */
async function readCandidateInfo(page, tileLocator) {
  await tileLocator.click();
  await assertNoFriction(page);
  await randomDelay(1000, 4000);
  // Open info panel (keyboard shortcut "i", matches Google Photos UI).
  await page.keyboard.press('i');
  const infoPanel = page.locator('[aria-label="Info"], [role="complementary"]').first();
  await infoPanel.waitFor({ state: 'visible', timeout: 10000 });
  await randomDelay(1000, 3000); // dwell reading the panel before extracting text

  const filename = (await infoPanel.locator('text=/\\.[A-Za-z0-9]{2,4}$/').first().textContent().catch(() => null))?.trim();
  const dateText = (await infoPanel.locator('[aria-label*="date" i], [aria-label*="Date" i]').first().textContent().catch(() => null))?.trim();
  const dimsText = (await infoPanel.locator('text=/\\d+\\s*[×x]\\s*\\d+/').first().textContent().catch(() => null))?.trim();

  let pixelWidth = null;
  let pixelHeight = null;
  const dimsMatch = dimsText && /(\d+)\s*[×x]\s*(\d+)/.exec(dimsText);
  if (dimsMatch) {
    pixelWidth = Number(dimsMatch[1]);
    pixelHeight = Number(dimsMatch[2]);
  }

  const captureDateTime = dateText ? new Date(dateText).toISOString() : null;

  return {
    filename,
    captureDateTime,
    pixelWidth,
    pixelHeight,
    url: page.url(),
  };
}

/**
 * Return from an open photo to the search results. Google Photos' own UI
 * has a close ("X" / back arrow) control in the photo viewer toolbar —
 * prefer clicking that over page.goBack(), which is a full history
 * navigation rather than an in-app action and is what rules/playwright.md
 * forbids for authenticated apps. Falls back to goBack() only if that
 * control genuinely isn't found (unverified selector — flagged for the
 * first live run), with an explicit comment so it's never silently assumed
 * to be the primary path.
 */
async function returnToResults(page) {
  const closeButton = page.locator('button[aria-label="Back" i], button[aria-label="Close" i]').first();
  if (await closeButton.count()) {
    await randomDelay(500, 2000);
    await closeButton.click();
    await page.locator(TILE_SELECTOR).first().waitFor({ state: 'visible', timeout: 15000 }).catch(() => {});
    await assertNoFriction(page);
    return;
  }
  // KNOWN DEVIATION: no in-app close/back control matched. Falling back to
  // browser history nav rather than getting the whole job stuck — this is
  // exactly the goBack() the rules discourage, kept only as a last resort
  // until the real selector is confirmed against the live site.
  await page.goBack({ waitUntil: 'domcontentloaded' }).catch(() => {});
  await assertNoFriction(page);
}

/** Move the currently-open photo to trash via the UI. NEVER permanent-delete. */
async function moveToTrash(page) {
  // The actual mechanism is the confirm button below, not a keyboard
  // shortcut: Google Photos' web UI does not bind a bare Delete/Shift+Delete
  // key to trash reliably across all view types (album vs. search-result
  // viewer), so we click the toolbar/menu trash action and then confirm.
  // (An earlier version of this comment claimed Shift+Delete was the
  // shortcut; that was never verified against the live UI and did not match
  // the code below, which pressed plain Delete. Selector below is
  // unverified — see module header — confirm on first live run.)
  const trashButton = page.locator('button[aria-label="Delete" i], button[aria-label="Move to trash" i]').first();
  await randomDelay(500, 2000);
  await trashButton.click();
  const confirmButton = page.locator('button:has-text("Move to trash")');
  await confirmButton.waitFor({ state: 'visible', timeout: 5000 });
  await randomDelay(500, 1500);
  await confirmButton.click();
}

export async function processJob(page, job, queue, { dryRun }) {
  const tiles = await searchCandidates(page, job.filename);
  if (tiles.length === 0) {
    const decision = decideMatch(job, []);
    if (dryRun) {
      console.log(`[dry-run needs_review] ${job.filename}: no search results`);
    } else {
      queue.update(job.id, { status: 'needs_review', comparison: decision, attempts: job.attempts + 1 });
      console.log(`[needs_review] ${job.filename}: no search results`);
    }
    return;
  }

  const candidates = [];
  for (const tile of tiles.slice(0, MAX_CANDIDATES_PER_JOB)) {
    const info = await readCandidateInfo(page, tile);
    candidates.push(info);
    await returnToResults(page);
    await randomDelay(1000, 4000); // between-candidate pacing, not just between-job
  }

  const decision = decideMatch(job, candidates);

  if (decision.decision === 'match') {
    if (dryRun) {
      // Dry-run must never call moveToTrash and must never mutate the
      // queue — it exists precisely so the first live exercise of these
      // unverified selectors can be observed without any side effect.
      console.log(`[dry-run WOULD TRASH] ${job.filename} -> ${decision.matchedCandidate.url}`);
      return;
    }
    const matchedTileIndex = candidates.indexOf(decision.matchedCandidate);
    await readCandidateInfo(page, tiles[matchedTileIndex]); // reopen the matched photo
    await moveToTrash(page);
    queue.update(job.id, { status: 'trashed', comparison: decision, attempts: job.attempts + 1 });
    console.log(`[trashed] ${job.filename}`);
  } else {
    if (dryRun) {
      console.log(`[dry-run needs_review] ${job.filename}: ${candidates.length} candidate(s), none conclusively agreed`);
      return;
    }
    queue.update(job.id, { status: 'needs_review', comparison: decision, attempts: job.attempts + 1 });
    console.log(`[needs_review] ${job.filename}: ${candidates.length} candidate(s), none conclusively agreed`);
  }
}

export async function runWorker({ cap = DEFAULT_CAP, dryRun = false } = {}) {
  const queue = new JobQueue(QUEUE_PATH);
  const jobs = queue.loadAll().filter((j) => j.status === 'queued').slice(0, cap);

  if (jobs.length === 0) {
    console.log('no queued jobs');
    return;
  }

  if (dryRun) {
    console.log(`--dry-run: will search + decide for ${jobs.length} job(s) but never trash or mutate the queue.`);
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

    for (const job of jobs) {
      try {
        await processJob(page, job, queue, { dryRun });
      } catch (err) {
        if (!dryRun) {
          queue.update(job.id, { status: 'error', error: String(err.message || err), attempts: job.attempts + 1 });
        }
        loud(`BLOCKER: worker error on job ${job.id} (${job.filename}): ${err.stack || err}`);
        process.exitCode = 1;
        return; // stop the run, no silent retry loop
      }
      await randomDelay(PACE_MS_MIN, PACE_MS_MAX);
    }
  } finally {
    // IMPORTANT: only close the page/tab this worker opened, never the
    // browser. `browser` here came from chromium.connectOverCDP() against
    // Oliver's persistent, already-signed-in Windows Chrome — calling
    // browser.close() on a CDP connection sends Browser.close and kills
    // that real Chrome process outright (not just this tab), same as
    // "never kill a Chrome to free a port" in CLAUDE.md. A previous version
    // of this file did call browser.close() here; that was never exercised
    // against the live browser and would have taken down Oliver's session.
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
