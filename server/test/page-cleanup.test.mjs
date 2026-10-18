import { test } from 'node:test';
import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';
import { fileURLToPath } from 'node:url';

const helper = fileURLToPath(new URL('../lib/page-cleanup.mjs', import.meta.url));

// Child registers the handler with a fake page whose close() prints a marker,
// then idles like a worker mid-run until we signal it.
function runChild(signal, { unregister = false } = {}) {
  const src = `
    import { closePageOnSignal } from ${JSON.stringify(helper)};
    const off = closePageOnSignal({ close: async () => { console.log('PAGE_CLOSED'); } });
    ${unregister ? 'off();' : ''}
    console.log('READY');
    setInterval(() => {}, 1000);
  `;
  return new Promise((resolve) => {
    const child = spawn(process.execPath, ['--input-type=module', '-e', src]);
    let out = '';
    child.stdout.on('data', (d) => {
      out += d;
      if (out.includes('READY') && !child.killed) child.kill(signal);
    });
    child.on('close', (code, sig) => resolve({ out, code, sig }));
  });
}

test('closePageOnSignal: SIGTERM closes the page and exits 143', async () => {
  const { out, code } = await runChild('SIGTERM');
  assert.match(out, /PAGE_CLOSED/);
  assert.equal(code, 143);
});

test('closePageOnSignal: SIGINT exits 130, SIGHUP exits 129', async () => {
  assert.equal((await runChild('SIGINT')).code, 130);
  assert.equal((await runChild('SIGHUP')).code, 129);
});

test('closePageOnSignal: unregistered handler leaves the page alone', async () => {
  const { out, sig } = await runChild('SIGTERM', { unregister: true });
  assert.doesNotMatch(out, /PAGE_CLOSED/);
  assert.equal(sig, 'SIGTERM');
});

test('closePageOnSignal: hung page.close() cannot block exit past the timeout', async () => {
  const src = `
    import { closePageOnSignal } from ${JSON.stringify(helper)};
    closePageOnSignal({ close: () => new Promise(() => {}) }, { timeoutMs: 200 });
    console.log('READY');
    setInterval(() => {}, 1000);
  `;
  const code = await new Promise((resolve) => {
    const child = spawn(process.execPath, ['--input-type=module', '-e', src]);
    child.stdout.once('data', () => child.kill('SIGTERM'));
    child.on('close', resolve);
  });
  assert.equal(code, 143);
});
