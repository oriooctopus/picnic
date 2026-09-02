/**
 * Auto-drain: triggers a worker run automatically once jobs land on the
 * queue, instead of requiring a human to run `node worker.mjs` by hand.
 *
 * `createAutoDrain()` is the pure, fully-injectable state machine (no real
 * timers, no real child processes, no real network) — see
 * server/test/autodrain.test.mjs. `createCdpProbe()` and `createWorkerSpawn()`
 * below are the real-world implementations of the two side-effecting
 * dependencies it needs (network probe + child process), used only by the
 * production wiring in queue-server.mjs's `if (import.meta.url === ...)`
 * block — never imported by anything that also imports createApp() for
 * testing, so `node --test` never starts a real timer or touches the
 * network.
 *
 * State machine, in order of the requirements it implements (original brief
 * 1-7, then a round of amendments from a QA pass that found real holes —
 * marked [amend] below; see git history / conversation for the full text):
 *
 *   1. Debounce: notifyEnqueued() (re)schedules a run `debounceMs` after the
 *      MOST RECENT call, coalescing a burst of swipes into one run.
 *   [amend] 1b. Debounce has a hard ceiling: the FIRST notifyEnqueued() of
 *      an idle period also arms a `maxDelayMs` deadline that is NEVER reset.
 *      The run fires at whichever of (debounce, deadline) comes first, so a
 *      steady drip of enqueues (a swipe every 60s while watching TV) can't
 *      push the debounce forward forever and starve the run entirely.
 *   2. Single-flight: a debounce/deadline/backoff firing while a run is
 *      already in progress does not spawn a second one — it just flags
 *      pendingFollowUp. This is liveness-safe against a killed CHILD worker
 *      process for free: Node's child_process 'exit' event fires even for
 *      SIGKILL, which resolves spawnWorker()'s promise and clears `running`
 *      in startRun's finally block. Note what is and isn't tested here:
 *      autodrain.test.mjs SIMULATES that exit ({ code: null }) against the
 *      fake spawn, which proves the state machine's handling but says
 *      nothing about Node itself. The real createWorkerSpawn was checked
 *      separately by SIGKILLing an actual spawned child — it resolved with
 *      { code: null } after ~1.5s, so the lock does release. If you change
 *      createWorkerSpawn's 'exit'/'error' handling, that guarantee is on
 *      you: no test in this suite covers it. There is no separate persisted lock to go stale — the
 *      lock is just an in-memory flag scoped to one live process, and if
 *      THAT process dies, [amend] 2b below re-arms on its next start.
 *   3. Follow-up: if pendingFollowUp was set when a run finishes, a fresh
 *      debounced+deadlined run is scheduled (not spawned immediately).
 *   [amend] 2b. Startup recovery: createAutoDrain() itself checks for any
 *      already-`queued` job at construction time and arms scheduling if it
 *      finds one — otherwise a server restart mid-debounce silently strands
 *      queued jobs with no timer left to drain them (indistinguishable from
 *      working correctly, since nothing ever surfaces it).
 *   4. CDP precondition: before spawning, probeCdp() must resolve true. If
 *      not, no spawn happens; a backoff timer re-attempts in `backoffMs`.
 *      Queued jobs are untouched — they get picked up whenever a run
 *      actually happens.
 *   5. Strategy retry: after the photo-walk run, any job that was `queued`
 *      at the run's start (and hasn't already used its retry — see [amend]
 *      5b) and is now `needs_review` gets re-queued and the worker runs
 *      exactly once more with `--walk=grid`, covering every such job in
 *      ONE follow-up spawn, not one per job. One retry only.
 *   [amend] 5b. The retry marker (`autoDrainRetried: true`) is written onto
 *      the JOB RECORD itself via queue.update(), not held in memory, so it
 *      survives a crash/restart between the photo run and the grid retry —
 *      without it, a restart at exactly that point would re-arm the job as
 *      plain 'queued' with no memory of having already spent its retry, and
 *      it could cycle through the retry logic again next run. A human
 *      POST /retry/:id clears the marker (queue-server.mjs), so a manual
 *      retry always gets the full two-strategy treatment again.
 *   [amend] 5c. Infra failures (CDP drop, a wedged tab) never masquerade as
 *      a genuine "no match" — verified against worker.mjs's actual status
 *      transitions (runDateGroups, worker.mjs ~L1296-1315): a job only ever
 *      becomes 'needs_review' with an explicit "no filename+dimensions
 *      match" reason. A page-closed/tab-gone failure leaves affected jobs
 *      'queued' (worker.mjs's own comment: "nothing gets marked failed/
 *      needs_review"); any other exception marks them 'error', not
 *      needs_review. So the queued-at-start-now-needs_review filter below
 *      can never accidentally include an infra casualty — no extra exit-code
 *      gating needed here, since worker.mjs itself never conflates the two.
 *   6. Kill switch: `enabled: false` makes notifyEnqueued() (and startup
 *      recovery) a no-op — see queue-server.mjs, which resolves this from
 *      PICNIC_AUTO_DRAIN via isAutoDrainEnabled().
 *   7. Logging: each spawnWorker() call is handed a logPath under
 *      ~/.local/share/picnic/worker-runs/ (see createWorkerSpawn) named by
 *      an ISO timestamp with colons swapped for '-' (filename-safe).
 *   [amend] 8. getStatus() exposes the scheduler's own state (enabled,
 *      running, lastRun outcome) so queue-server.mjs can fold it into
 *      GET /queue as a pull-based health surface — since this module is
 *      forbidden from ever paging anyone, a stuck pipeline has to be
 *      something a human can go LOOK at instead.
 *
 * [amend] on a monotonic clock (item 9 in the QA pass): not needed. Nothing
 * here computes a wall-clock time DIFFERENCE to decide when to fire — every
 * schedule call is a fixed-relative setTimer(fn, ms), and Node's own timers
 * already run off libuv's monotonic clock, so an NTP step can't move them.
 * `now()` is only ever used for the log filename and to detect "is this the
 * first enqueue of a new idle burst" (a null-check, not a duration).
 *
 * [amend] on resetting stranded non-terminal jobs on startup (item 3 in the
 * QA pass): checked against lib/queue.mjs's actual STATUSES — ['queued',
 * 'trashed', 'needs_review', 'error']. There is no in-progress/processing
 * status; worker.mjs never writes one (grepped every `status:` assignment).
 * The scenario described doesn't exist in this schema, so there's nothing
 * to reset — inventing a new status here would be exactly the kind of
 * unrequested defensive layer CLAUDE.md says not to add.
 */
import { execSync, spawn as nodeSpawn } from 'node:child_process';
import { createWriteStream, existsSync, mkdirSync } from 'node:fs';
import { homedir } from 'node:os';
import { dirname, join } from 'node:path';

export const DEBOUNCE_MS = 90_000;
// [amend] hard ceiling on the debounce — see module header item 1b. 10 min
// per the QA pass's own number; the user is triaging photos live, not
// waiting on a background batch job, so 10 minutes of silence is already a
// long time to sit undrained.
export const MAX_DELAY_MS = 10 * 60 * 1000;
export const CDP_BACKOFF_MS = 10 * 60 * 1000;
export const CDP_PORT = 9251;
export const DEFAULT_LOG_DIR = join(homedir(), '.local/share/picnic/worker-runs');

/** Parses the PICNIC_AUTO_DRAIN kill switch. Only '0' disables; unset/anything else leaves it on. */
export function isAutoDrainEnabled(env = process.env) {
  return env.PICNIC_AUTO_DRAIN !== '0';
}

function isoTimestampForFilename(date) {
  return date.toISOString().replace(/:/g, '-');
}

/**
 * The pure auto-drain state machine. All side effects — reading/writing the
 * queue, running the worker, probing CDP, scheduling timers, logging — are
 * injected, so this is testable with a fake clock and fake spawn/probe.
 */
export function createAutoDrain({
  queue,
  spawnWorker,
  probeCdp,
  now = Date.now,
  setTimer = setTimeout,
  clearTimer = clearTimeout,
  log = console.log,
  enabled = true,
  debounceMs = DEBOUNCE_MS,
  maxDelayMs = MAX_DELAY_MS,
  backoffMs = CDP_BACKOFF_MS,
  logDir = DEFAULT_LOG_DIR,
} = {}) {
  if (!enabled) {
    return {
      notifyEnqueued() {},
      isRunning: () => false,
      getStatus: () => ({ enabled: false, running: false, lastRun: null }),
    };
  }

  if (typeof queue?.loadAll !== 'function' || typeof queue?.update !== 'function') {
    throw new Error('createAutoDrain requires a queue with loadAll()/update()');
  }
  if (typeof spawnWorker !== 'function') throw new Error('createAutoDrain requires spawnWorker()');
  if (typeof probeCdp !== 'function') throw new Error('createAutoDrain requires probeCdp()');

  // debounceTimer resets on every notifyEnqueued(); deadlineTimer is armed
  // once per idle burst (firstEnqueueAt !== null) and never reset — whichever
  // fires first wins. Both are cleared together in attemptRun() once either
  // one fires, so the sibling never fires again for a burst already handled.
  let debounceTimer = null;
  let deadlineTimer = null;
  let firstEnqueueAt = null;
  let backoffTimer = null;
  let running = false;
  let pendingFollowUp = false;
  let lastRun = null;

  /** Starts (or extends) a scheduling burst: called by notifyEnqueued() and, on run finish, for a flagged follow-up. */
  function armScheduling() {
    if (firstEnqueueAt === null) {
      firstEnqueueAt = now();
      deadlineTimer = setTimer(onDeadlineFire, maxDelayMs);
    }
    if (debounceTimer !== null) clearTimer(debounceTimer);
    debounceTimer = setTimer(onDebounceFire, debounceMs);
  }

  /** Cancels any pending debounce/deadline timers and resets burst tracking — called once either one fires. */
  function clearScheduling() {
    if (debounceTimer !== null) clearTimer(debounceTimer);
    if (deadlineTimer !== null) clearTimer(deadlineTimer);
    debounceTimer = null;
    deadlineTimer = null;
    firstEnqueueAt = null;
  }

  function onDebounceFire() {
    attemptRun();
  }

  function onDeadlineFire() {
    attemptRun();
  }

  function scheduleBackoff() {
    if (backoffTimer !== null) clearTimer(backoffTimer);
    backoffTimer = setTimer(onBackoffFire, backoffMs);
  }

  function onBackoffFire() {
    backoffTimer = null;
    attemptRun();
  }

  function attemptRun() {
    clearScheduling();
    if (running) {
      pendingFollowUp = true;
      return;
    }
    startRun().catch((err) => {
      log(`[autodrain] run failed: ${err && err.stack ? err.stack : err}`);
    });
  }

  async function runOnce(walk) {
    const logPath = join(logDir, `${isoTimestampForFilename(new Date(now()))}.log`);
    log(`[autodrain] starting worker run (--walk=${walk}) -> ${logPath}`);
    const result = await spawnWorker({ walk, logPath });
    log(`[autodrain] worker run (--walk=${walk}) finished, exit ${result && result.code}`);
    return result;
  }

  async function startRun() {
    running = true;
    pendingFollowUp = false;
    const startedAt = now();
    try {
      const reachable = await probeCdp();
      if (!reachable) {
        log('[autodrain] CDP endpoint unreachable, backing off');
        scheduleBackoff();
        lastRun = { startedAt, finishedAt: now(), outcome: 'cdp_unreachable' };
        return;
      }

      // Only jobs 'queued' at the moment this run starts, and that haven't
      // already burned their one strategy retry (see module header 5b), are
      // eligible for the grid re-run below. A job that ends up needs_review
      // from a PRIOR run (not touched this run) or that already carries
      // autoDrainRetried:true is left alone — retrying it again would be
      // the infinite-loop / silent-burn-of-browser-time shape the QA pass
      // flagged.
      const queuedAtStart = queue.loadAll().filter((j) => j.status === 'queued');
      const retryEligible = new Set(queuedAtStart.filter((j) => !j.autoDrainRetried).map((j) => j.id));

      const photoResult = await runOnce('photo');
      let gridResult = null;
      let retried = false;

      if (retryEligible.size > 0) {
        const after = queue.loadAll();
        const needsReview = after.filter((j) => retryEligible.has(j.id) && j.status === 'needs_review');
        if (needsReview.length > 0) {
          for (const job of needsReview) {
            // autoDrainRetried:true is the durable marker — persisted on the
            // job record itself, so it survives a crash between here and
            // the grid run finishing (module header 5b).
            queue.update(job.id, { status: 'queued', error: null, autoDrainRetried: true });
          }
          gridResult = await runOnce('grid');
          retried = true;
        }
      }

      lastRun = {
        startedAt,
        finishedAt: now(),
        outcome: 'completed',
        photoExitCode: photoResult && photoResult.code,
        gridExitCode: gridResult && gridResult.code,
        retried,
      };
    } finally {
      running = false;
    }

    if (pendingFollowUp) {
      pendingFollowUp = false;
      armScheduling();
    }
  }

  // [amend] startup recovery (module header 2b): if the process restarted
  // while jobs were sitting 'queued' with no live timer (or was never told
  // about them because the enqueue that would have called notifyEnqueued()
  // happened in a previous process lifetime), arm scheduling now instead of
  // leaving them stranded until the next unrelated enqueue.
  if (queue.loadAll().some((j) => j.status === 'queued')) {
    armScheduling();
  }

  return {
    notifyEnqueued() {
      armScheduling();
    },
    isRunning: () => running,
    getStatus: () => ({ enabled: true, running, lastRun }),
  };
}

function defaultGetGateway() {
  return execSync("ip route show default | awk '{print $3}'").toString().trim();
}

/**
 * Real CDP-reachability probe: GET http://<gateway>:<port>/json/version.
 * Gateway resolution and the HTTP client are both injectable so this can be
 * pointed at a fake in tests without ever hitting the network — but this
 * factory itself is only ever called from queue-server.mjs's production
 * wiring, never from autodrain.test.mjs.
 */
export function createCdpProbe({ getGateway = defaultGetGateway, port = CDP_PORT, fetchImpl = fetch, timeoutMs = 3000 } = {}) {
  return async function probeCdp() {
    let gateway;
    try {
      gateway = getGateway();
    } catch {
      return false;
    }
    if (!gateway) return false;

    const controller = new AbortController();
    const timer = setTimeout(() => controller.abort(), timeoutMs);
    try {
      const res = await fetchImpl(`http://${gateway}:${port}/json/version`, { signal: controller.signal });
      return res.ok;
    } catch {
      return false;
    } finally {
      clearTimeout(timer);
    }
  };
}

/**
 * Real worker spawn: `node worker.mjs --walk=<walk>`, stdout+stderr piped to
 * logPath. Resolves { code } on exit; rejects only if the process itself
 * could not be spawned. Production-only, same reasoning as createCdpProbe.
 *
 * Deliberately relies on child_process's 'exit' event alone (not 'close',
 * not a manual kill-detection timer): 'exit' fires whenever the child
 * actually terminates, INCLUDING via an external `kill -9` (code=null,
 * signal='SIGKILL') — so a killed worker still resolves this promise and
 * flips autodrain's `running` flag back to false via startRun's finally.
 * No separate liveness check is needed on top of that (verified in
 * autodrain.test.mjs's kill -9 test).
 */
export function createWorkerSpawn({ cwd, nodeBin = process.execPath, workerScript = 'worker.mjs', cap } = {}) {
  return function spawnWorker({ walk, logPath }) {
    return new Promise((resolve, reject) => {
      const dir = dirname(logPath);
      if (!existsSync(dir)) mkdirSync(dir, { recursive: true });
      const logStream = createWriteStream(logPath);

      const args = [workerScript, `--walk=${walk}`];
      if (cap != null) args.push('--cap', String(cap));

      const child = nodeSpawn(nodeBin, args, { cwd });
      child.stdout.pipe(logStream);
      child.stderr.pipe(logStream);
      child.on('error', (err) => {
        logStream.end();
        reject(err);
      });
      child.on('exit', (code) => {
        logStream.end();
        resolve({ code });
      });
    });
  };
}
