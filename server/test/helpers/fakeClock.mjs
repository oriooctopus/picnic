/**
 * A virtual clock for testing autodrain's scheduling logic without ever
 * waiting on a real timer. `setTimer`/`clearTimer`/`now` are drop-in
 * replacements for the real ones; `advance(ms)` moves virtual time forward
 * and fires every timer that becomes due along the way, IN DUE-TIME ORDER,
 * including timers newly scheduled by a callback that itself fires within
 * the same advance window (e.g. autodrain rescheduling its own debounce
 * timer from inside a fired callback) — this mirrors how a real event loop
 * would interleave them, which matters for the debounce-vs-deadline race
 * this module relies on.
 */
export function createFakeClock(start = 0) {
  let virtualNow = start;
  let nextId = 1;
  const timers = new Map(); // id -> { fireAt, fn }

  function setTimer(fn, ms) {
    const id = nextId++;
    timers.set(id, { fireAt: virtualNow + ms, fn });
    return id;
  }

  function clearTimer(id) {
    timers.delete(id);
  }

  function now() {
    return virtualNow;
  }

  function advance(ms) {
    const target = virtualNow + ms;
    for (;;) {
      let due = null;
      for (const [id, t] of timers) {
        if (t.fireAt <= target && (due === null || t.fireAt < due.fireAt)) due = { id, ...t };
      }
      if (!due) break;
      timers.delete(due.id);
      virtualNow = due.fireAt;
      due.fn();
    }
    virtualNow = target;
  }

  return { setTimer, clearTimer, now, advance, pendingCount: () => timers.size };
}
