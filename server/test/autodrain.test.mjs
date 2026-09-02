import { test } from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { JobQueue } from '../lib/queue.mjs';
import { createAutoDrain, isAutoDrainEnabled, DEBOUNCE_MS, MAX_DELAY_MS, CDP_BACKOFF_MS } from '../lib/autodrain.mjs';
import { createFakeClock } from './helpers/fakeClock.mjs';

/**
 * All the promise chains inside autodrain (notifyEnqueued -> timer fires ->
 * attemptRun -> startRun -> await probeCdp -> await spawnWorker -> ...) run
 * as microtasks/macrotasks AFTER clock.advance() returns synchronously (the
 * fake clock only fires the timer CALLBACK synchronously; anything that
 * callback awaits still needs the real event loop to actually settle). This
 * drains that queue without waiting on any real timer/delay -- it's letting
 * already-resolved promises settle, not simulating elapsed time.
 */
async function tick(n = 20) {
  for (let i = 0; i < n; i++) await new Promise((resolve) => setImmediate(resolve));
}

async function withTempQueue(fn) {
  const dir = mkdtempSync(join(tmpdir(), 'picnic-autodrain-test-'));
  const queue = new JobQueue(join(dir, 'queue.jsonl'));
  try {
    return await fn(queue, dir);
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
}

function addQueuedJob(queue, filename, creationDate = '2026-06-15T14:30:00.000Z') {
  return queue.enqueue({ filename, creationDate, pixelWidth: 100, pixelHeight: 100 }).job;
}

/** A spawnWorker fake that just records calls and resolves cleanly -- for tests that don't care about the queue mutation a real worker run would do. */
function makeSpawnRecorder() {
  const calls = [];
  const spawnWorker = async ({ walk, logPath }) => {
    calls.push({ walk, logPath });
    return { code: 0 };
  };
  return { spawnWorker, calls };
}

/** A spawnWorker fake whose promise the test resolves manually, for single-flight/liveness tests that need to hold a run "in progress". */
function makeDeferredSpawn() {
  const calls = [];
  const resolvers = [];
  const spawnWorker = ({ walk, logPath }) => {
    calls.push({ walk, logPath });
    return new Promise((resolve) => resolvers.push(resolve));
  };
  return {
    spawnWorker,
    calls,
    resolveNext(result = { code: 0 }) {
      const resolve = resolvers.shift();
      if (!resolve) throw new Error('no pending spawnWorker call to resolve');
      resolve(result);
    },
  };
}

function baseDeps(queue, clock, overrides = {}) {
  return {
    queue,
    probeCdp: async () => true,
    now: clock.now,
    setTimer: clock.setTimer,
    clearTimer: clock.clearTimer,
    log: () => {},
    ...overrides,
  };
}

test('createAutoDrain requires queue, spawnWorker, and probeCdp when enabled', () => {
  assert.throws(() => createAutoDrain({ spawnWorker: async () => {}, probeCdp: async () => true }));
  assert.throws(() => createAutoDrain({ queue: { loadAll: () => [], update: () => {} }, probeCdp: async () => true }));
  assert.throws(() => createAutoDrain({ queue: { loadAll: () => [], update: () => {} }, spawnWorker: async () => {} }));
});

test('isAutoDrainEnabled parses the PICNIC_AUTO_DRAIN kill switch (only "0" disables)', () => {
  assert.equal(isAutoDrainEnabled({}), true);
  assert.equal(isAutoDrainEnabled({ PICNIC_AUTO_DRAIN: '0' }), false);
  assert.equal(isAutoDrainEnabled({ PICNIC_AUTO_DRAIN: '1' }), true);
  assert.equal(isAutoDrainEnabled({ PICNIC_AUTO_DRAIN: 'false' }), true);
});

test('debounce coalesces a burst of enqueues into exactly one run', async () => {
  await withTempQueue(async (queue) => {
    const clock = createFakeClock();
    const { spawnWorker, calls } = makeSpawnRecorder();
    const drain = createAutoDrain(baseDeps(queue, clock, { spawnWorker }));

    addQueuedJob(queue, 'A.HEIC');
    drain.notifyEnqueued();
    clock.advance(30_000);
    addQueuedJob(queue, 'B.HEIC');
    drain.notifyEnqueued(); // resets the 90s window
    clock.advance(30_000);
    addQueuedJob(queue, 'C.HEIC');
    drain.notifyEnqueued(); // resets it again
    clock.advance(30_000); // only 30s since the LAST notify -- still pending
    await tick();
    assert.equal(calls.length, 0, 'debounce should not have fired yet');

    clock.advance(90_000);
    await tick();
    assert.equal(calls.length, 1, 'the whole burst collapses into one run');
    assert.equal(calls[0].walk, 'photo');
  });
});

test('a steady drip of enqueues (one every 60s) still fires within the max-delay ceiling, not silence', async () => {
  await withTempQueue(async (queue) => {
    const clock = createFakeClock();
    const { spawnWorker, calls } = makeSpawnRecorder();
    const drain = createAutoDrain(baseDeps(queue, clock, { spawnWorker }));

    addQueuedJob(queue, 'A.HEIC');
    drain.notifyEnqueued();
    // Each 60s notify resets the 90s debounce before it can ever fire, so
    // only the 10-minute (MAX_DELAY_MS) ceiling armed by the FIRST notify
    // can rescue this run from being pushed forward forever.
    for (let i = 0; i < 9; i++) {
      clock.advance(60_000);
      drain.notifyEnqueued();
    }
    await tick();
    assert.equal(calls.length, 0, 'under 10 minutes since the first notify -- no run yet');

    clock.advance(60_000); // crosses the 10-minute mark
    await tick();
    assert.equal(calls.length, 1, 'the ceiling must force a run despite the continuous drip');
  });
});

test('single-flight: a timer firing mid-run does not spawn a second worker; a follow-up runs after', async () => {
  await withTempQueue(async (queue) => {
    const clock = createFakeClock();
    const deferred = makeDeferredSpawn();
    const drain = createAutoDrain(baseDeps(queue, clock, { spawnWorker: deferred.spawnWorker }));

    addQueuedJob(queue, 'A.HEIC');
    drain.notifyEnqueued();
    clock.advance(DEBOUNCE_MS);
    await tick();
    assert.equal(deferred.calls.length, 1, 'first run started');
    assert.equal(drain.isRunning(), true);

    // a swipe arrives while the run is in flight, and its debounce fires
    // BEFORE the in-flight run finishes
    addQueuedJob(queue, 'B.HEIC');
    drain.notifyEnqueued();
    clock.advance(DEBOUNCE_MS);
    await tick();
    assert.equal(deferred.calls.length, 1, 'must not spawn a second worker while one is running');

    deferred.resolveNext({ code: 0 }); // job A never transitions in this fake -> no strategy retry
    await tick();
    assert.equal(drain.isRunning(), false);

    clock.advance(DEBOUNCE_MS - 1);
    await tick();
    assert.equal(deferred.calls.length, 1, 'follow-up is debounced too, not immediate');
    clock.advance(1);
    await tick();
    assert.equal(deferred.calls.length, 2, 'follow-up run happened after the first one finished');
  });
});

test('a failed run (spawn reject) still re-arms scheduling for a job that arrived mid-run', async () => {
  await withTempQueue(async (queue) => {
    addQueuedJob(queue, 'A.HEIC');
    const clock = createFakeClock();
    const calls = [];
    // Rejects on demand (via the returned reject()) rather than immediately,
    // so the test controls exactly when the in-flight run fails -- this
    // mirrors createWorkerSpawn rejecting with ENOENT on a bad node binary
    // or missing worker script (Finding 1's first confirmed trigger).
    const rejecters = [];
    const spawnWorker = ({ walk }) => {
      calls.push(walk);
      return new Promise((_resolve, reject) => rejecters.push(reject));
    };
    const drain = createAutoDrain(baseDeps(queue, clock, { spawnWorker }));

    drain.notifyEnqueued();
    clock.advance(DEBOUNCE_MS);
    await tick();
    assert.equal(calls.length, 1, 'first run started');
    assert.equal(drain.isRunning(), true);

    // job B arrives mid-run and its own debounce timer fires WHILE the first
    // run is still in flight -- attemptRun() sees running===true and sets
    // pendingFollowUp instead of spawning a second worker.
    addQueuedJob(queue, 'B.HEIC', '2026-06-16T14:30:00.000Z');
    drain.notifyEnqueued();
    clock.advance(DEBOUNCE_MS);
    await tick();
    assert.equal(calls.length, 1, 'must not spawn a second worker while one is running');

    // the in-flight run now fails outright
    rejecters.shift()(new Error('spawn ENOENT'));
    await tick();
    assert.equal(drain.isRunning(), false);
    assert.ok(clock.pendingCount() > 0, 'a failed run with pendingFollowUp set must re-arm a timer, not leave zero pending');

    // no further notifyEnqueued() call -- only the pendingFollowUp flag set
    // before the failure should drive this follow-up run
    clock.advance(DEBOUNCE_MS - 1);
    await tick();
    assert.equal(calls.length, 1, 'the re-armed follow-up is debounced too, not immediate');
    clock.advance(1);
    await tick();
    assert.equal(calls.length, 2, 'a failed run must still re-arm scheduling for work that arrived mid-run');
  });
});

test('a debounce timer still pending when the ceiling fires does not survive to spawn a second run later', async () => {
  await withTempQueue(async (queue) => {
    const clock = createFakeClock();
    const { spawnWorker, calls } = makeSpawnRecorder();
    const drain = createAutoDrain(baseDeps(queue, clock, { spawnWorker }));

    addQueuedJob(queue, 'A.HEIC');
    drain.notifyEnqueued();
    // Same steady-drip shape as the ceiling test above: each notify resets
    // the 90s debounce before it can fire, so only the 10-minute deadline
    // (armed once, by the FIRST notify) ends up firing. Critically, the
    // debounce timer armed by the LAST notify is still pending (not yet due)
    // at the moment the deadline fires.
    for (let i = 0; i < 9; i++) {
      clock.advance(60_000);
      drain.notifyEnqueued();
    }
    clock.advance(60_000); // crosses the 10-minute mark -- ceiling fires
    await tick();
    assert.equal(calls.length, 1, 'the ceiling fired the run');

    // Advance well past where the stale (last-notify) debounce timer would
    // fire on its own, with NO new enqueue. If clearScheduling() failed to
    // clear the debounce timer when the deadline fired, it survives and
    // fires a spurious second run here.
    clock.advance(DEBOUNCE_MS);
    await tick();
    assert.equal(calls.length, 1, 'no second run without a new enqueue');
  });
});

test('DEBOUNCE_MS stays close to the documented ~90s value', () => {
  // Pins the exported constant against a fixed, hard-coded window -- every
  // other test advances the fake clock BY the imported DEBOUNCE_MS, so those
  // tests pass no matter what value the constant holds. Nothing else in this
  // suite would catch DEBOUNCE_MS being changed to, say, 61s or 120s.
  assert.ok(DEBOUNCE_MS >= 85_000 && DEBOUNCE_MS <= 95_000, `DEBOUNCE_MS should be ~90s, got ${DEBOUNCE_MS}ms`);
});

test('CDP unreachable: does not spawn, backs off, and re-probes after the backoff window', async () => {
  await withTempQueue(async (queue) => {
    const clock = createFakeClock();
    const { spawnWorker, calls } = makeSpawnRecorder();
    let reachable = false;
    let probeCount = 0;
    const probeCdp = async () => {
      probeCount++;
      return reachable;
    };
    const drain = createAutoDrain(baseDeps(queue, clock, { spawnWorker, probeCdp }));

    addQueuedJob(queue, 'A.HEIC');
    drain.notifyEnqueued();
    clock.advance(DEBOUNCE_MS);
    await tick();
    assert.equal(calls.length, 0, 'must not spawn when CDP is unreachable');
    assert.equal(probeCount, 1);
    assert.equal(drain.getStatus().lastRun.outcome, 'cdp_unreachable');

    clock.advance(CDP_BACKOFF_MS - 1);
    await tick();
    assert.equal(probeCount, 1, 'backoff not due yet');

    reachable = true; // CDP comes back before the backoff timer fires
    clock.advance(1);
    await tick();
    assert.equal(probeCount, 2, 'backoff re-checked CDP');
    assert.equal(calls.length, 1, 'now that CDP is reachable, the run spawns');
  });
});

test('strategy retry: needs_review jobs from the photo run get exactly one grid retry', async () => {
  await withTempQueue(async (queue) => {
    const a = addQueuedJob(queue, 'A.HEIC');
    const b = addQueuedJob(queue, 'B.HEIC', '2026-06-16T14:30:00.000Z');
    const clock = createFakeClock();
    const calls = [];
    const spawnWorker = async ({ walk }) => {
      calls.push(walk);
      if (walk === 'photo') {
        queue.update(a.id, { status: 'needs_review', comparison: { reason: 'no match' } });
        queue.update(b.id, { status: 'trashed' });
      } else if (walk === 'grid') {
        queue.update(a.id, { status: 'trashed' });
      }
      // distinct exit codes per walk so a getStatus() assertion below can
      // prove gridExitCode is genuinely read from the grid run, not just a
      // copy of photoExitCode
      return { code: walk === 'grid' ? 3 : 0 };
    };
    const drain = createAutoDrain(baseDeps(queue, clock, { spawnWorker }));

    drain.notifyEnqueued();
    clock.advance(DEBOUNCE_MS);
    await tick();
    assert.deepEqual(calls, ['photo', 'grid']);
    assert.equal(queue.getById(a.id).status, 'trashed');
    assert.equal(queue.getById(a.id).autoDrainRetried, true);

    const status = drain.getStatus();
    assert.equal(status.lastRun.photoExitCode, 0);
    assert.equal(status.lastRun.gridExitCode, 3, 'gridExitCode must reflect the grid run, not the photo run');
    assert.equal(status.lastRun.retried, true);

    // no THIRD run just because a retried job exists on the queue
    clock.advance(MAX_DELAY_MS);
    await tick();
    assert.deepEqual(calls, ['photo', 'grid'], 'no further automatic run without a new enqueue');
  });
});

test('a job re-queued while already carrying the retry marker is not retried a second time (marker filter, not status filter)', async () => {
  await withTempQueue(async (queue) => {
    // This must be genuinely distinguishing: a job that is simply not
    // 'queued' at run start is ALREADY excluded by the `status === 'queued'`
    // filter regardless of the marker, so a job stuck at needs_review from a
    // prior run doesn't exercise the `!j.autoDrainRetried` filter at all. To
    // actually test the marker, the job must be 'queued' AND already carry
    // autoDrainRetried:true -- e.g. re-enqueued through some other path
    // without the marker being cleared (only a human POST /retry clears it).
    const a = addQueuedJob(queue, 'A.HEIC');
    queue.update(a.id, { autoDrainRetried: true });
    const clock = createFakeClock();
    const calls = [];
    const spawnWorker = async ({ walk }) => {
      calls.push(walk);
      queue.update(a.id, { status: 'needs_review' });
      return { code: 0 };
    };
    const drain = createAutoDrain(baseDeps(queue, clock, { spawnWorker }));

    drain.notifyEnqueued();
    clock.advance(DEBOUNCE_MS);
    await tick();
    assert.deepEqual(calls, ['photo'], 'already-retried job must not get a second grid retry even though it was queued at run start');
  });
});

test('a job that is still needs_review after its one retry is never auto-retried again by a later run', async () => {
  await withTempQueue(async (queue) => {
    const a = addQueuedJob(queue, 'A.HEIC');
    const clock = createFakeClock();
    const calls = [];
    const spawnWorker = async ({ walk }) => {
      calls.push(walk);
      // neither strategy finds a match -- both leave it needs_review
      queue.update(a.id, { status: 'needs_review' });
      return { code: 0 };
    };
    const drain = createAutoDrain(baseDeps(queue, clock, { spawnWorker }));

    drain.notifyEnqueued();
    clock.advance(DEBOUNCE_MS);
    await tick();
    assert.deepEqual(calls, ['photo', 'grid']);
    assert.equal(queue.getById(a.id).autoDrainRetried, true);

    // a later run (new enqueue) must not retry it a second time
    addQueuedJob(queue, 'B.HEIC', '2026-06-17T00:00:00.000Z');
    drain.notifyEnqueued();
    clock.advance(DEBOUNCE_MS);
    await tick();
    assert.deepEqual(calls, ['photo', 'grid', 'photo'], 'job A must not trigger a second grid retry');
  });
});

test('a pre-existing unmarked needs_review job is left untouched by a normal cycle (status filter, not just the marker)', async () => {
  await withTempQueue(async (queue) => {
    // Mirrors the live queue's 14 pre-existing needs_review jobs left by
    // earlier manual runs, none carrying autoDrainRetried. Without the
    // `status === 'queued'` filter on queuedAtStart, the first automatic run
    // would treat this job as retry-eligible (it has no marker), re-queue,
    // mark, and grid-retry it -- a burst of unrequested browser work against
    // jobs nobody asked this run to touch.
    const stale = addQueuedJob(queue, 'STALE.HEIC', '2026-05-01T00:00:00.000Z');
    queue.update(stale.id, { status: 'needs_review' });
    const a = addQueuedJob(queue, 'A.HEIC');
    const clock = createFakeClock();
    const calls = [];
    const spawnWorker = async ({ walk }) => {
      calls.push(walk);
      if (walk === 'photo') queue.update(a.id, { status: 'trashed' });
      return { code: 0 };
    };
    const drain = createAutoDrain(baseDeps(queue, clock, { spawnWorker }));

    drain.notifyEnqueued();
    clock.advance(DEBOUNCE_MS);
    await tick();

    assert.deepEqual(calls, ['photo'], 'no grid retry -- the pre-existing needs_review job was never queued at this run\'s start');
    const staleAfter = queue.getById(stale.id);
    assert.equal(staleAfter.status, 'needs_review', 'pre-existing needs_review job must be left untouched');
    assert.notEqual(staleAfter.autoDrainRetried, true, 'must not gain the retry marker');
  });
});

test('the retry marker survives a restart between the photo run and the grid retry finishing', async () => {
  await withTempQueue(async (queue) => {
    const a = addQueuedJob(queue, 'A.HEIC');
    const clock1 = createFakeClock();
    let crashed = false;
    // Simulates the process dying right after job A is re-queued with the
    // retry marker (already durably written via queue.update) but before
    // the grid spawnWorker call itself resolves.
    const spawnWorker1 = async ({ walk }) => {
      if (walk === 'photo') {
        queue.update(a.id, { status: 'needs_review' });
        return { code: 0 };
      }
      crashed = true;
      throw new Error('simulated crash mid grid-retry');
    };
    const drain1 = createAutoDrain(baseDeps(queue, clock1, { spawnWorker: spawnWorker1 }));
    drain1.notifyEnqueued();
    clock1.advance(DEBOUNCE_MS);
    await tick();
    assert.equal(crashed, true, 'sanity check: the simulated crash path actually ran');
    assert.equal(queue.getById(a.id).status, 'queued', 're-queued for the grid retry before the crash');
    assert.equal(queue.getById(a.id).autoDrainRetried, true, 'marker persisted to disk before the crash');

    // "restart": a fresh autodrain instance (fresh in-memory state) against
    // the SAME on-disk queue file.
    const queue2 = new JobQueue(queue.filePath);
    const clock2 = createFakeClock();
    const calls2 = [];
    const spawnWorker2 = async ({ walk }) => {
      calls2.push(walk);
      queue2.update(a.id, { status: 'needs_review' });
      return { code: 0 };
    };
    createAutoDrain(baseDeps(queue2, clock2, { spawnWorker: spawnWorker2 }));
    // No notifyEnqueued() call at all -- startup recovery must arm it.
    clock2.advance(DEBOUNCE_MS);
    await tick();
    assert.deepEqual(calls2, ['photo'], 'must NOT retry with grid again -- the marker survived the crash/restart');
  });
});

test('a human retry (marker cleared) gets the full two-strategy treatment again', async () => {
  await withTempQueue(async (queue) => {
    const a = addQueuedJob(queue, 'A.HEIC');
    const clock = createFakeClock();
    const calls = [];
    const spawnWorker = async ({ walk }) => {
      calls.push(walk);
      queue.update(a.id, { status: 'needs_review' });
      return { code: 0 };
    };
    const drain = createAutoDrain(baseDeps(queue, clock, { spawnWorker }));
    drain.notifyEnqueued();
    clock.advance(DEBOUNCE_MS);
    await tick();
    assert.deepEqual(calls, ['photo', 'grid']);

    // mirrors what queue-server.mjs's POST /retry/:id does: reset status AND clear the marker
    queue.update(a.id, { status: 'queued', error: null, autoDrainRetried: false });
    drain.notifyEnqueued();
    clock.advance(DEBOUNCE_MS);
    await tick();
    assert.deepEqual(calls, ['photo', 'grid', 'photo', 'grid'], 'a cleared marker means a fresh retry allowance');
  });
});

test('startup recovery arms a run for a job left queued with no live timer, with no notifyEnqueued call', async () => {
  await withTempQueue(async (queue) => {
    addQueuedJob(queue, 'A.HEIC');
    const clock = createFakeClock();
    const { spawnWorker, calls } = makeSpawnRecorder();
    createAutoDrain(baseDeps(queue, clock, { spawnWorker }));
    // never call notifyEnqueued()
    clock.advance(DEBOUNCE_MS);
    await tick();
    assert.equal(calls.length, 1, 'startup recovery must arm a run for the already-queued job');
  });
});

test('startup recovery does nothing when there are no queued jobs', async () => {
  await withTempQueue(async (queue) => {
    const clock = createFakeClock();
    const { spawnWorker, calls } = makeSpawnRecorder();
    createAutoDrain(baseDeps(queue, clock, { spawnWorker }));
    clock.advance(MAX_DELAY_MS * 2);
    await tick();
    assert.equal(calls.length, 0);
  });
});

test('kill switch: enabled:false makes notifyEnqueued a no-op and skips startup recovery entirely', async () => {
  await withTempQueue(async (queue) => {
    addQueuedJob(queue, 'A.HEIC');
    const clock = createFakeClock();
    const { spawnWorker, calls } = makeSpawnRecorder();
    const drain = createAutoDrain(baseDeps(queue, clock, { spawnWorker, enabled: false }));
    drain.notifyEnqueued();
    clock.advance(MAX_DELAY_MS * 2);
    await tick();
    assert.equal(calls.length, 0);
    assert.deepEqual(drain.getStatus(), { enabled: false, running: false, lastRun: null });
  });
});

test('a killed worker child (SIGKILL) still resolves and releases the single-flight lock for the next enqueue', async () => {
  await withTempQueue(async (queue) => {
    addQueuedJob(queue, 'A.HEIC');
    const clock = createFakeClock();
    const deferred = makeDeferredSpawn();
    const drain = createAutoDrain(baseDeps(queue, clock, { spawnWorker: deferred.spawnWorker }));
    drain.notifyEnqueued();
    clock.advance(DEBOUNCE_MS);
    await tick();
    assert.equal(drain.isRunning(), true);

    // Node's child_process 'exit' event fires even for a SIGKILLed process
    // (code=null, signal='SIGKILL') -- createWorkerSpawn's real implementation
    // resolves { code: null } on that event, so simulate it the same way.
    deferred.resolveNext({ code: null });
    await tick();
    assert.equal(drain.isRunning(), false, 'the lock must not survive a killed child process');

    addQueuedJob(queue, 'B.HEIC');
    drain.notifyEnqueued();
    clock.advance(DEBOUNCE_MS);
    await tick();
    assert.equal(deferred.calls.length, 2, 'a subsequent enqueue must still trigger a new run');
  });
});

test('getStatus reports the outcome of the last run', async () => {
  await withTempQueue(async (queue) => {
    addQueuedJob(queue, 'A.HEIC');
    const clock = createFakeClock();
    const { spawnWorker } = makeSpawnRecorder();
    const drain = createAutoDrain(baseDeps(queue, clock, { spawnWorker }));

    assert.equal(drain.getStatus().lastRun, null);
    drain.notifyEnqueued();
    clock.advance(DEBOUNCE_MS);
    await tick();
    const status = drain.getStatus();
    assert.equal(status.enabled, true);
    assert.equal(status.running, false);
    assert.equal(status.lastRun.outcome, 'completed');
    assert.equal(status.lastRun.photoExitCode, 0);
    assert.equal(status.lastRun.gridExitCode, null, 'no needs_review jobs -- no grid run happened');
    assert.equal(status.lastRun.retried, false);
  });
});
