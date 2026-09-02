import { createServer } from 'node:http';
import { homedir } from 'node:os';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { JobQueue, STATUSES } from './lib/queue.mjs';
import { loadToken, checkBearerAuth } from './lib/auth.mjs';
import { createAutoDrain, createCdpProbe, createWorkerSpawn, isAutoDrainEnabled } from './lib/autodrain.mjs';

// NOTE: SPEC.md / task instructions said 8306, but ~/.claude/rules/ports.md
// already has 8306 assigned to another local service (verified live and
// running on this machine) — using it would collide. Using 8307 instead,
// registered in ports.md. The iOS app's mirror-queue base URL must match.
const PORT = 8307;
const HOST = '0.0.0.0';
const TOKEN_PATH = process.env.PICNIC_TOKEN_PATH || join(homedir(), '.config/picnic/token');
const QUEUE_PATH = process.env.PICNIC_QUEUE_PATH || join(homedir(), '.local/share/picnic/queue.jsonl');

const queue = new JobQueue(QUEUE_PATH);

function readJsonBody(req) {
  return new Promise((resolve, reject) => {
    let data = '';
    req.on('data', (chunk) => {
      data += chunk;
      if (data.length > 1e6) req.destroy();
    });
    req.on('end', () => {
      if (!data) return resolve({});
      try {
        resolve(JSON.parse(data));
      } catch (e) {
        reject(e);
      }
    });
    req.on('error', reject);
  });
}

function send(res, status, body) {
  const payload = JSON.stringify(body);
  res.writeHead(status, { 'Content-Type': 'application/json' });
  res.end(payload);
}

function requireAuth(req, res) {
  const token = loadToken(TOKEN_PATH);
  if (!checkBearerAuth(req, token)) {
    send(res, 401, { error: 'unauthorized' });
    return false;
  }
  return true;
}

// A no-op stand-in used whenever createApp() is called without a real
// autoDrain (every test file, since server.test.mjs imports createApp()
// directly with no args) -- this is what keeps `node --test` from ever
// starting a real 90s/10min timer or touching the network: only the
// `if (import.meta.url === ...)` block at the bottom of this file, which
// only runs when queue-server.mjs is executed as the actual server process,
// constructs the real one via createCdpProbe()/createWorkerSpawn().
const NOOP_AUTO_DRAIN = {
  notifyEnqueued() {},
  isRunning: () => false,
  getStatus: () => ({ enabled: false, running: false, lastRun: null }),
};

export function createApp({ autoDrain = NOOP_AUTO_DRAIN } = {}) {
  return createServer(async (req, res) => {
    try {
      const url = new URL(req.url, `http://${req.headers.host}`);

      if (req.method === 'GET' && url.pathname === '/health') {
        return send(res, 200, { ok: true });
      }

      if (req.method === 'POST' && url.pathname === '/queue') {
        if (!requireAuth(req, res)) return;
        const body = await readJsonBody(req);
        const { filename, creationDate, pixelWidth, pixelHeight, mediaType, isLivePhoto } = body;
        if (!filename || !creationDate || !pixelWidth || !pixelHeight) {
          return send(res, 400, { error: 'filename, creationDate, pixelWidth, pixelHeight are required' });
        }
        const { job, created } = queue.enqueue({
          filename,
          creationDate,
          pixelWidth,
          pixelHeight,
          mediaType,
          isLivePhoto,
        });
        // Fire-and-forget: notifyEnqueued() only (re)schedules a debounced
        // timer, it never awaits a worker run, so this never delays the
        // HTTP response. Only on a successful enqueue -- the 400 branch
        // above for missing fields returns before this line, so a failed
        // POST never arms a run for a job that was never stored.
        autoDrain.notifyEnqueued();
        return send(res, created ? 201 : 200, { job, created });
      }

      if (req.method === 'GET' && url.pathname === '/queue') {
        if (!requireAuth(req, res)) return;
        const statusFilter = url.searchParams.get('status');
        const limit = Number(url.searchParams.get('limit') || 50);
        let jobs = queue.loadAll();
        if (statusFilter) {
          if (!STATUSES.includes(statusFilter)) {
            return send(res, 400, { error: `invalid status, must be one of ${STATUSES.join(', ')}` });
          }
          jobs = jobs.filter((j) => j.status === statusFilter);
        }
        const counts = queue.counts();
        const recent = jobs.slice(-limit).reverse();
        // Pull-based health surface (auto-drain never notifies anyone by
        // design -- see lib/autodrain.mjs -- so a stuck pipeline has to be
        // something a human can go LOOK at here instead). oldestQueuedWaitMs
        // is computed straight from the jobs already loaded above, not from
        // autoDrain, since it's a fact about the queue, not the scheduler.
        const allQueued = jobs.filter((j) => j.status === 'queued');
        const oldestQueued = allQueued.reduce(
          (oldest, j) => (oldest === null || j.createdAt < oldest ? j.createdAt : oldest),
          null
        );
        const autoDrainStatus = {
          ...autoDrain.getStatus(),
          oldestQueuedWaitMs: oldestQueued === null ? null : Date.now() - Date.parse(oldestQueued),
        };
        return send(res, 200, { counts, total: jobs.length, jobs: recent, autoDrain: autoDrainStatus });
      }

      const retryMatch = /^\/retry\/([^/]+)$/.exec(url.pathname);
      if (req.method === 'POST' && retryMatch) {
        if (!requireAuth(req, res)) return;
        const id = retryMatch[1];
        const existing = queue.getById(id);
        if (!existing) return send(res, 404, { error: 'no such job' });
        // A human-initiated retry always gets the full two-strategy
        // treatment again -- clear the auto-drain retry marker (see
        // lib/autodrain.mjs's module header, item 5b) along with the usual
        // status reset, or a job that already burned its one automatic
        // retry would never be eligible for another even after this.
        const job = queue.update(id, { status: 'queued', error: null, autoDrainRetried: false });
        autoDrain.notifyEnqueued();
        return send(res, 200, { job });
      }

      send(res, 404, { error: 'not found' });
    } catch (err) {
      send(res, 500, { error: String(err && err.message ? err.message : err) });
    }
  });
}

if (import.meta.url === `file://${process.argv[1]}`) {
  // The real, side-effecting wiring -- only ever constructed here, when
  // this file is run as the actual server process. createApp() itself
  // defaults to a no-op autoDrain (see NOOP_AUTO_DRAIN above) so importing
  // createApp() for tests never starts a real timer or touches the network.
  const autoDrain = createAutoDrain({
    queue,
    spawnWorker: createWorkerSpawn({ cwd: dirname(fileURLToPath(import.meta.url)) }),
    probeCdp: createCdpProbe(),
    enabled: isAutoDrainEnabled(),
  });
  const server = createApp({ autoDrain });
  server.listen(PORT, HOST, () => {
    console.log(`picnic-mirror queue server listening on ${HOST}:${PORT}`);
  });
}
