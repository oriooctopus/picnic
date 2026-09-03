import { createServer } from 'node:http';
import { homedir } from 'node:os';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { existsSync, mkdirSync, readFileSync, writeFileSync } from 'node:fs';
import { JobQueue, STATUSES } from './lib/queue.mjs';
import { loadToken, checkBearerAuth, tokensMatch } from './lib/auth.mjs';
import { createAutoDrain, createCdpProbe, createWorkerSpawn, isAutoDrainEnabled } from './lib/autodrain.mjs';

// NOTE: SPEC.md / task instructions said 8306, but ~/.claude/rules/ports.md
// already has 8306 assigned to another local service (verified live and
// running on this machine) — using it would collide. Using 8307 instead,
// registered in ports.md. The iOS app's mirror-queue base URL must match.
const PORT = 8307;
const HOST = '0.0.0.0';
const TOKEN_PATH = process.env.PICNIC_TOKEN_PATH || join(homedir(), '.config/picnic/token');
const QUEUE_PATH = process.env.PICNIC_QUEUE_PATH || join(homedir(), '.local/share/picnic/queue.jsonl');
// Overridable the same way as QUEUE_PATH so tests never touch the real
// thumbs directory. This is a directory (not a single file) because each
// job gets its own <id>.jpg -- see decodeThumbnail()/POST /queue below.
const THUMBS_DIR = process.env.PICNIC_THUMBS_DIR || join(homedir(), '.local/share/picnic/thumbs');
// Cap chosen generously above the ~5-20KB the iOS app is expected to send
// (per the brief) -- this exists only to stop a malformed/huge body from
// writing an unbounded file to disk, not to police normal thumbnail sizes.
const MAX_THUMBNAIL_BYTES = 2 * 1024 * 1024;

const queue = new JobQueue(QUEUE_PATH);
// Created eagerly (mirrors JobQueue's own directory bootstrap) so the first
// POST /queue with a thumbnail never races a lazy mkdir.
if (!existsSync(THUMBS_DIR)) mkdirSync(THUMBS_DIR, { recursive: true });

function thumbPath(id) {
  return join(THUMBS_DIR, `${id}.jpg`);
}

/**
 * Decode+validate an inbound base64 JPEG. Thrown messages are surfaced
 * verbatim in the 400 response, so keep them specific enough for the app
 * dev to act on. Validation lives here (not in lib/queue.mjs) because this
 * is the actual system boundary -- untrusted bytes arriving over HTTP.
 */
function decodeThumbnail(base64) {
  if (typeof base64 !== 'string' || base64.length === 0) {
    throw new Error('thumbnailBase64 must be a non-empty base64 string');
  }
  // Buffer.from(str, 'base64') silently ignores invalid characters instead
  // of throwing, so a malformed string would otherwise decode "successfully"
  // into garbage bytes. Reject anything that isn't well-formed base64 first.
  if (!/^[A-Za-z0-9+/]+={0,2}$/.test(base64) || base64.length % 4 !== 0) {
    throw new Error('thumbnailBase64 is not valid base64');
  }
  const buffer = Buffer.from(base64, 'base64');
  if (buffer.length > MAX_THUMBNAIL_BYTES) {
    throw new Error(`thumbnail exceeds max size of ${MAX_THUMBNAIL_BYTES} bytes (got ${buffer.length})`);
  }
  return buffer;
}

// Pre-thumbnails this was 1e6 (1MB), plenty for the plain job-metadata body.
// A base64-encoded 2MB thumbnail (MAX_THUMBNAIL_BYTES below) needs ~2.7MB of
// JSON body on its own (base64's ~4/3 blowup), so the old cap would silently
// req.destroy() the connection -- no response, not even a 400 -- for any
// thumbnail near the size decodeThumbnail() is supposed to accept and reject
// cleanly. Sized with headroom above the worst case so the 2MB decode cap
// is the thing that actually rejects oversized thumbnails, not this one.
const MAX_REQUEST_BODY_BYTES = 4 * 1024 * 1024;

function readJsonBody(req) {
  return new Promise((resolve, reject) => {
    let data = '';
    req.on('data', (chunk) => {
      data += chunk;
      if (data.length > MAX_REQUEST_BODY_BYTES) req.destroy();
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

/**
 * Same bearer-header check as requireAuth(), plus a `?token=` fallback --
 * ONLY for the two browser-facing GET routes (/issues, /thumb/:id). Oliver
 * opens these from a browser tab, which cannot attach an Authorization
 * header, so the query param is the only way in. Every other route keeps
 * bearer-only auth via requireAuth() above; do not reuse this for POSTs.
 */
function requireAuthQueryOrHeader(req, res, url) {
  const token = loadToken(TOKEN_PATH);
  if (checkBearerAuth(req, token)) return true;
  const queryToken = url.searchParams.get('token');
  if (queryToken && tokensMatch(queryToken, token)) return true;
  send(res, 401, { error: 'unauthorized' });
  return false;
}

function escapeHtml(str) {
  return String(str).replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
}

/**
 * Renders the stalled-job review panel: every needs_review/error job with
 * whatever thumbnail we captured, so Oliver can tell what a photo WAS
 * without pulling up a browser to go find it. `jobs` is expected pre-sorted
 * (newest first) and pre-filtered by the caller. `token` is appended to
 * every /thumb/:id src -- see the GET /issues route for why.
 */
function renderIssuesPage(jobs, token) {
  const needsReviewCount = jobs.filter((j) => j.status === 'needs_review').length;
  const errorCount = jobs.filter((j) => j.status === 'error').length;
  const tokenQs = `?token=${encodeURIComponent(token)}`;

  const cards = jobs
    .map((job) => {
      const thumb = job.hasThumbnail
        ? `<img class="thumb" src="/thumb/${encodeURIComponent(job.id)}${tokenQs}" alt="${escapeHtml(job.filename)}" loading="lazy">`
        : `<div class="thumb placeholder">no thumbnail</div>`;
      // worker.mjs writes a genuine no-match (the common case -- almost
      // every needs_review job) into comparison.reason and leaves `error`
      // null; `error` itself is only set on an exception path (a crash,
      // an unconfirmed trash). Reading `error` alone showed "(no reason
      // recorded)" on nearly the whole panel against the real 17 stalled
      // jobs -- comparison.reason must be checked first.
      const rawReason = job.comparison?.reason || job.error;
      const reason = rawReason ? escapeHtml(rawReason) : '(no reason recorded)';
      return `
        <div class="card">
          ${thumb}
          <div class="meta">
            <div class="filename">${escapeHtml(job.filename)}</div>
            <div class="row"><span class="label">captured</span> ${escapeHtml(job.creationDate)}</div>
            <div class="row"><span class="label">size</span> ${escapeHtml(job.pixelWidth)}&times;${escapeHtml(job.pixelHeight)}</div>
            <div class="row"><span class="status ${escapeHtml(job.status)}">${escapeHtml(job.status)}</span></div>
            <div class="reason">${reason}</div>
          </div>
        </div>`;
    })
    .join('\n');

  return `<!doctype html>
<html>
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Picnic — stalled jobs</title>
<style>
  :root { color-scheme: dark; }
  * { box-sizing: border-box; }
  body {
    margin: 0;
    padding: 16px;
    background: #14151a;
    color: #e8e8ec;
    font: 14px/1.4 -apple-system, system-ui, sans-serif;
  }
  h1 { font-size: 18px; margin: 0 0 4px; }
  .counts { color: #9a9aa5; margin-bottom: 16px; }
  .grid {
    display: grid;
    grid-template-columns: repeat(auto-fill, minmax(160px, 1fr));
    gap: 12px;
  }
  .card {
    background: #1e1f26;
    border: 1px solid #2c2d36;
    border-radius: 10px;
    overflow: hidden;
    display: flex;
    flex-direction: column;
  }
  .thumb {
    width: 100%;
    aspect-ratio: 1 / 1;
    object-fit: cover;
    display: block;
    background: #0e0f13;
  }
  .thumb.placeholder {
    display: flex;
    align-items: center;
    justify-content: center;
    color: #55565f;
    font-size: 12px;
    text-align: center;
    padding: 8px;
  }
  .meta { padding: 8px 10px 10px; min-width: 0; }
  .filename {
    font-weight: 600;
    font-size: 12.5px;
    overflow-wrap: break-word;
    margin-bottom: 4px;
  }
  .row { color: #b6b6c0; font-size: 12px; margin-bottom: 2px; }
  .label { color: #77787f; }
  .status {
    display: inline-block;
    border-radius: 4px;
    padding: 1px 6px;
    font-size: 11px;
    text-transform: uppercase;
    letter-spacing: 0.03em;
  }
  .status.needs_review { background: #3a2f0f; color: #f0c14b; }
  .status.error { background: #3a1414; color: #f07070; }
  .reason {
    margin-top: 6px;
    color: #d0d0d8;
    font-size: 12px;
    overflow-wrap: break-word;
  }
  .empty { color: #9a9aa5; }
</style>
</head>
<body>
  <h1>Stalled jobs</h1>
  <div class="counts">${needsReviewCount} needs_review, ${errorCount} error (${jobs.length} total)</div>
  ${jobs.length ? `<div class="grid">${cards}</div>` : '<p class="empty">Nothing stalled.</p>'}
</body>
</html>`;
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
        const { filename, creationDate, pixelWidth, pixelHeight, mediaType, isLivePhoto, thumbnailBase64 } = body;
        if (!filename || !creationDate || !pixelWidth || !pixelHeight) {
          return send(res, 400, { error: 'filename, creationDate, pixelWidth, pixelHeight are required' });
        }
        let { job, created } = queue.enqueue({
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

        // The thumbnail is a nice-to-have for the /issues panel, not the
        // job itself -- a bad/oversized thumbnail must not stop the mirror
        // job from being queued (that already happened above) or from
        // triggering auto-drain (that already fired above too). We only
        // report the problem via a 400, with the job included so the caller
        // can see it went through anyway.
        let thumbnailError = null;
        if (thumbnailBase64 !== undefined) {
          try {
            const buffer = decodeThumbnail(thumbnailBase64);
            // Stored on disk, never inlined into the job record: queue.jsonl
            // is append-only and rewrites the full record on every status
            // change, so an inline blob would be duplicated on every future
            // update. The record only carries the boolean flag.
            writeFileSync(thumbPath(job.id), buffer);
            job = queue.update(job.id, { hasThumbnail: true });
          } catch (err) {
            thumbnailError = err.message;
          }
        }

        if (thumbnailError) {
          return send(res, 400, { error: thumbnailError, job, created });
        }
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

      const thumbMatch = /^\/thumb\/([^/]+)$/.exec(url.pathname);
      if (req.method === 'GET' && thumbMatch) {
        if (!requireAuthQueryOrHeader(req, res, url)) return;
        const id = thumbMatch[1];
        // job ids are lowercase-hex (see jobKey() in lib/queue.mjs) -- reject
        // anything else before it ever reaches a filesystem path, rather
        // than trusting an arbitrary URL segment as a filename.
        if (!/^[0-9a-f]+$/.test(id) || !existsSync(thumbPath(id))) {
          return send(res, 404, { error: 'no thumbnail for that id' });
        }
        res.writeHead(200, { 'Content-Type': 'image/jpeg' });
        return res.end(readFileSync(thumbPath(id)));
      }

      if (req.method === 'GET' && url.pathname === '/issues') {
        if (!requireAuthQueryOrHeader(req, res, url)) return;
        // Every thumbnail <img> on the page must carry ?token= too (a
        // browser <img> can't send an Authorization header), so we reuse
        // whatever token got this request past auth. This page is expected
        // to always be opened via ?token=, not a bearer header, so this is
        // never empty in the real (browser) path.
        const token = url.searchParams.get('token') || '';
        const jobs = queue
          .loadAll()
          .filter((j) => j.status === 'needs_review' || j.status === 'error')
          .sort((a, b) => (a.updatedAt < b.updatedAt ? 1 : -1));
        res.writeHead(200, { 'Content-Type': 'text/html; charset=utf-8' });
        return res.end(renderIssuesPage(jobs, token));
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
