// Closes the Chrome tab the worker opened when the process is killed by a
// signal. `finally` blocks don't run on SIGTERM/SIGINT/SIGHUP (e.g.
// `timeout 115 node worker.mjs`, `pkill -f worker.mjs`), so without this every
// killed run leaks a ~1 GB Google Photos tab in Oliver's persistent Chrome.
// Closes only the page, never the browser (see the note in worker.mjs).
import { constants } from 'node:os';

const SIGNALS = ['SIGTERM', 'SIGINT', 'SIGHUP'];
export const PAGE_CLOSE_TIMEOUT_MS = 3000;

// Returns an unregister function; call it from the normal `finally` path.
export function closePageOnSignal(page, { timeoutMs = PAGE_CLOSE_TIMEOUT_MS } = {}) {
  const handlers = SIGNALS.map((sig) => {
    const handler = async () => {
      // bounded so a hung CDP connection can't block the exit
      await Promise.race([
        page.close().catch(() => {}),
        new Promise((resolve) => setTimeout(resolve, timeoutMs)),
      ]);
      process.exit(128 + constants.signals[sig]);
    };
    process.once(sig, handler);
    return [sig, handler];
  });
  return () => handlers.forEach(([sig, handler]) => process.off(sig, handler));
}
