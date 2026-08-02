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
 *
 * Run: node worker.mjs [--cap 50]
 */
import { execSync } from 'node:child_process';
import { homedir } from 'node:os';
import { join } from 'node:path';
import { JobQueue } from './lib/queue.mjs';
import { decideMatch } from './lib/matcher.mjs';

const QUEUE_PATH = process.env.PICNIC_QUEUE_PATH || join(homedir(), '.local/share/picnic/queue.jsonl');
const DEFAULT_CAP = 50;
const PACE_MS = 4000; // a few seconds between jobs, per SPEC

function parseArgs(argv) {
  const args = { cap: DEFAULT_CAP };
  for (let i = 0; i < argv.length; i++) {
    if (argv[i] === '--cap') args.cap = Number(argv[++i]);
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

function loud(msg) {
  console.error(`\n=== PICNIC WORKER BLOCKER ===\n${msg}\n=============================\n`);
}

/** Search Google Photos by filename and return raw candidate elements. */
async function searchCandidates(page, filename) {
  const searchUrl = `https://photos.google.com/search/${encodeURIComponent(filename)}`;
  await page.goto(searchUrl, { waitUntil: 'networkidle' });
  // Photo tiles in Google Photos search results.
  const tiles = await page.locator('[data-latest-bg], a[href^="./photo/"]').all();
  return tiles;
}

/**
 * Open a candidate's info panel (the "i" details view) and read back
 * filename, capture timestamp, and pixel dimensions as displayed by Google
 * Photos.
 */
async function readCandidateInfo(page, tileLocator) {
  await tileLocator.click();
  await page.waitForLoadState('networkidle');
  // Open info panel (keyboard shortcut "i", matches Google Photos UI).
  await page.keyboard.press('i');
  const infoPanel = page.locator('[aria-label="Info"], [role="complementary"]').first();
  await infoPanel.waitFor({ state: 'visible', timeout: 10000 });

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

/** Move the currently-open photo to trash via the UI. NEVER permanent-delete. */
async function moveToTrash(page) {
  // "Move to trash" — Shift+Delete is Google Photos' trash shortcut (NOT
  // permanent delete, which requires a separate action inside Trash itself).
  await page.keyboard.press('Delete');
  const confirmButton = page.locator('button:has-text("Move to trash")');
  await confirmButton.waitFor({ state: 'visible', timeout: 5000 });
  await confirmButton.click();
}

async function processJob(page, job, queue) {
  const tiles = await searchCandidates(page, job.filename);
  if (tiles.length === 0) {
    const decision = decideMatch(job, []);
    queue.update(job.id, { status: 'needs_review', comparison: decision, attempts: job.attempts + 1 });
    console.log(`[needs_review] ${job.filename}: no search results`);
    return;
  }

  const candidates = [];
  for (const tile of tiles.slice(0, 10)) {
    const info = await readCandidateInfo(page, tile);
    candidates.push(info);
    await page.goBack({ waitUntil: 'networkidle' }).catch(() => {});
  }

  const decision = decideMatch(job, candidates);

  if (decision.decision === 'match') {
    const matchedTileIndex = candidates.indexOf(decision.matchedCandidate);
    await readCandidateInfo(page, tiles[matchedTileIndex]); // reopen the matched photo
    await moveToTrash(page);
    queue.update(job.id, { status: 'trashed', comparison: decision, attempts: job.attempts + 1 });
    console.log(`[trashed] ${job.filename}`);
  } else {
    queue.update(job.id, { status: 'needs_review', comparison: decision, attempts: job.attempts + 1 });
    console.log(`[needs_review] ${job.filename}: ${candidates.length} candidate(s), none conclusively agreed`);
  }
}

export async function runWorker({ cap = DEFAULT_CAP } = {}) {
  const queue = new JobQueue(QUEUE_PATH);
  const jobs = queue.loadAll().filter((j) => j.status === 'queued').slice(0, cap);

  if (jobs.length === 0) {
    console.log('no queued jobs');
    return;
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

  try {
    const context = browser.contexts()[0] ?? (await browser.newContext());
    const page = await context.newPage();

    for (const job of jobs) {
      try {
        await processJob(page, job, queue);
      } catch (err) {
        queue.update(job.id, { status: 'error', error: String(err.message || err), attempts: job.attempts + 1 });
        loud(`BLOCKER: worker error on job ${job.id} (${job.filename}): ${err.stack || err}`);
        process.exitCode = 1;
        return; // stop the run, no silent retry loop
      }
      await sleep(PACE_MS);
    }
  } finally {
    await browser.close().catch(() => {});
  }
}

if (import.meta.url === `file://${process.argv[1]}`) {
  const args = parseArgs(process.argv.slice(2));
  runWorker(args).catch((err) => {
    loud(`BLOCKER: unhandled worker failure: ${err.stack || err}`);
    process.exit(1);
  });
}
