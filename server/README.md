# Picnic mirror server

Queue + worker that mirror committed PhotoKit deletions on the iPhone into
Google Photos **trash** (never permanent delete). See `../SPEC.md` for the
full contract — "Interaction semantics" and "Mirror server" sections.

## Port

**8307**, not 8306. SPEC.md said 8306, but `~/.claude/rules/ports.md` already
had that assigned to another local service, confirmed live on this
machine. Used 8307 instead and registered it in the ports file. If the iOS
app hardcodes 8306 anywhere, it needs to point at 8307.

## Auth

Bearer token in `~/.config/picnic/token` (chmod 600, generated with
`openssl rand -hex 32`), also mirrored to `~/.claude/tokens.env` as
`PICNIC_MIRROR_TOKEN`. Compared with `crypto.timingSafeEqual` (constant
time). Every endpoint except `GET /health` requires
`Authorization: Bearer <token>`.

## Storage

Append-only JSONL at `~/.local/share/picnic/queue.jsonl`. Each line is a full
job snapshot; the latest line for a given job `id` is its current state —
updates append a new line rather than mutating in place, so the file is a
complete audit log. Job `id` is `sha256(filename|creationDate)` truncated to
24 hex chars, which is what makes `POST /queue` idempotent: re-posting the
same filename+creationDate returns the existing job (`created: false`)
instead of creating a duplicate.

Job statuses: `queued` -> `trashed` | `needs_review` | `error`.
`POST /retry/:id` resets any job back to `queued`.

## Endpoints

- `GET /health` — `{ ok: true }`, no auth.
- `POST /queue` — body `{ filename, creationDate, pixelWidth, pixelHeight, mediaType?, isLivePhoto? }`.
  Returns `201` + `{ job, created: true }` on first insert, `200` +
  `{ job, created: false }` if that filename+creationDate was already queued.
- `GET /queue?status=<status>&limit=<n>` — `{ counts, total, jobs }`. `status`
  filter is optional (one of `queued|trashed|needs_review|error`); `jobs` is
  the most recent `limit` (default 50) jobs, newest first.
- `POST /retry/:id` — resets job `id` to `queued`, clears `error`. `404` if
  unknown.

## Running

Server (always-on, systemd user unit):

```
systemctl --user status picnic-mirror
```

Worker (NOT a daemon in v1 — run on demand):

```
cd server && node worker.mjs --cap 50
```

`--cap` limits how many queued jobs a single run drains (default 50). The
worker connects to the persistent Windows Chrome via the CDP relay
(`http://$GW:9251`, `GW` = WSL2 default-route gateway, profile signed into
oliverullman@gmail.com), searches Google Photos by filename per job, and
requires filename + capture timestamp + pixel dimensions to ALL agree (see
`lib/matcher.mjs`) before moving a photo to trash. Any CDP-connect or
selector failure stops the run immediately with a loud `BLOCKER:` message and
a nonzero exit — no silent retries. `picnic-worker.service` (`systemd/`) is a
oneshot wrapper around the same command for convenience; it is not enabled
and must be run manually (`systemctl --user start picnic-worker`).

**The worker has not been run against real Google Photos yet.** Its DOM
selectors (`worker.mjs`: `searchCandidates`, `readCandidateInfo`,
`moveToTrash`) are best-effort against the current Google Photos web UI and
must be verified against the live site on the first real run, per the task's
explicit instruction not to run it against real photos yet.

## Timestamp matching / timezone skew

The phone's local capture time and whatever Google Photos displays can be off
by a timezone/DST offset. `lib/matcher.mjs` treats two timestamps as
agreeing if, after folding out any whole-hour offset, the remainder is within
5 minutes — so e.g. a candidate 9 hours off (multiple of an hour) still
matches, but one that's 17 minutes off does not. Every comparison — per
candidate, per field (filename/timestamp/dimensions), including the raw
`timestampDiffMinutes` — is stored in the job's `comparison` field for
auditability.

## `needs_review`

A job lands in `needs_review` whenever the worker found zero candidates, more
than one candidate where all three fields agreed, or no candidate where they
all agreed. The worker never guesses in this case. Oliver reviews with:

```
curl -s http://<host>:8307/queue?status=needs_review \
  -H "Authorization: Bearer $(cat ~/.config/picnic/token)" | jq
```

Each job's `comparison` field shows exactly what was compared against each
candidate, so the reason it was ambiguous is visible without re-running
anything. Resolve manually in Google Photos, then either leave the job as
`needs_review` (it's excluded from future worker runs, which only drain
`queued`) or `POST /retry/:id` to have the worker try again.

## Tests

```
node --test test/
```

40/40 passing as of this writeup — queue idempotency/status-transition
tests, bearer-auth tests, matcher decision-function tests (including
timezone-skew and ambiguity cases), and HTTP endpoint tests.
