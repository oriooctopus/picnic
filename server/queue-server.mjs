import { createServer } from 'node:http';
import { homedir } from 'node:os';
import { join } from 'node:path';
import { JobQueue, STATUSES } from './lib/queue.mjs';
import { loadToken, checkBearerAuth } from './lib/auth.mjs';

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

export function createApp() {
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
        return send(res, 200, { counts, total: jobs.length, jobs: recent });
      }

      const retryMatch = /^\/retry\/([^/]+)$/.exec(url.pathname);
      if (req.method === 'POST' && retryMatch) {
        if (!requireAuth(req, res)) return;
        const id = retryMatch[1];
        const existing = queue.getById(id);
        if (!existing) return send(res, 404, { error: 'no such job' });
        const job = queue.update(id, { status: 'queued', error: null });
        return send(res, 200, { job });
      }

      send(res, 404, { error: 'not found' });
    } catch (err) {
      send(res, 500, { error: String(err && err.message ? err.message : err) });
    }
  });
}

if (import.meta.url === `file://${process.argv[1]}`) {
  const server = createApp();
  server.listen(PORT, HOST, () => {
    console.log(`picnic-mirror queue server listening on ${HOST}:${PORT}`);
  });
}
