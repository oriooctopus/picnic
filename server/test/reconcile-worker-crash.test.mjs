import { test } from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { spawn } from 'node:child_process';
import { ReconcileStore } from '../lib/reconcile.mjs';

// Exercises attachReconcileExitHandler directly against small fake child
// processes (`node -e ...`) instead of a real worker.mjs/CDP/browser crash --
// see its doc comment in queue-server.mjs for why it's split out testably.
const dir = mkdtempSync(join(tmpdir(), 'picnic-reconcile-crash-test-'));
const tokenPath = join(dir, 'token');
const reconcileDir = join(dir, 'reconcile');
writeFileSync(tokenPath, 'x');

process.env.PICNIC_TOKEN_PATH = tokenPath;
process.env.PICNIC_QUEUE_PATH = join(dir, 'queue.jsonl');
process.env.PICNIC_THUMBS_DIR = join(dir, 'thumbs');
process.env.PICNIC_RECONCILE_DIR = reconcileDir;

const { attachReconcileExitHandler } = await import('../queue-server.mjs');
const store = new ReconcileStore(reconcileDir);

test.after(() => rmSync(dir, { recursive: true, force: true }));

function waitExit(child) {
  return new Promise((resolve) => child.on('exit', resolve));
}

test('attachReconcileExitHandler marks the month failed with an error when the worker exits non-zero', async () => {
  const month = '2026-08';
  store.saveStatus(month, 'scanning');
  const child = spawn(process.execPath, ['-e', 'process.exit(7)']);
  attachReconcileExitHandler(child, 'scan', month, '/tmp/fake-reconcile-log.log');
  await waitExit(child);
  // Our handler is registered before waitExit's listener, so 'exit'
  // listeners already ran synchronously in order by the time the await
  // above resolves -- no extra tick needed, but assert on the persisted
  // files (not an in-memory flag) since that's what GET /reconcile/:month
  // actually reads.
  assert.equal(store.loadStatus(month), 'failed');
  assert.match(store.loadError(month), /reconcile scan worker exited with code 7/);
  assert.match(store.loadError(month), /fake-reconcile-log\.log/);
});

test('attachReconcileExitHandler leaves status untouched on a clean exit (code 0)', async () => {
  const month = '2026-07';
  store.saveStatus(month, 'scanning');
  const child = spawn(process.execPath, ['-e', 'process.exit(0)']);
  attachReconcileExitHandler(child, 'scan', month, '/tmp/fake-reconcile-log.log');
  await waitExit(child);
  assert.equal(store.loadStatus(month), 'scanning');
  assert.equal(store.loadError(month), null);
});

test('attachReconcileExitHandler records a signal kill distinctly from a plain exit code', async () => {
  const month = '2026-06';
  store.saveStatus(month, 'scanning');
  const child = spawn(process.execPath, ['-e', 'setInterval(() => {}, 1000)']);
  attachReconcileExitHandler(child, 'trash', month, '/tmp/fake-reconcile-log.log');
  child.kill('SIGKILL');
  await waitExit(child);
  assert.equal(store.loadStatus(month), 'failed');
  assert.match(store.loadError(month), /killed by signal SIGKILL/);
});
