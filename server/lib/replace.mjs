/**
 * Trim-replace job state machine (job.kind === 'replace').
 *
 * The app trimmed a video and uploaded the trimmed file; Google Photos never
 * re-uploads edits to already-backed-up items, so the worker must put the
 * trimmed file into Google Photos and then trash the stale full-length
 * original. The ORDER is the safety property:
 *
 *   received -> (upload + confirm new item exists) -> uploaded
 *            -> (find original, move to Trash, verify)  -> done / status 'trashed'
 *
 * The original is NEVER touched unless the new item was confirmed in Google
 * first, and `trashed` is only written after the trash was verified. Any
 * unconfirmed step becomes `needs_review` with a reason (visible in /issues).
 * The persisted `replace.phase` makes a re-run idempotent: a job that already
 * confirmed its upload skips straight to the trash step, and an upload attempt
 * always first asks Google whether the new item is already there, so a retry
 * never uploads twice.
 *
 * Browser work is injected as `ops` so this logic is testable without Chrome:
 *   stage(job)                      -> { path, uploadName }   file to upload (capture date fixed up)
 *   findNew(job, staged)            -> { url, ... } | null    confirmed new item in Google, or null
 *   upload(job, staged)             -> void                   push the file through Google's UI
 *   trashOriginal(job, newItem)     -> { outcome: 'trashed' | 'original_not_found' | 'unverified', detail? }
 *   cleanup(job)                    -> void                   drop the server-side copy once done
 * An op that throws (tab closed, CDP gone) aborts the run and leaves the job
 * as it was, so the next run resumes -- nothing is marked failed on a crash.
 */
export const REPLACE_ATTEMPTS = 3;

export async function processReplaceJob(job, queue, ops, { attempts = REPLACE_ATTEMPTS, log = console.log, isFatal = () => false } = {}) {
  let current = queue.getById(job.id);
  // A single failed Google UI interaction is flakiness, not a conclusion: it
  // counts as one failed attempt (its message is kept for the needs_review
  // reason) and the loop tries again. Only `isFatal` errors (the tab/browser
  // is gone) escape, leaving the job exactly as it was for the next run.
  let lastError = null;
  const tryOp = async (fn, fallback) => {
    try {
      return await fn();
    } catch (err) {
      if (isFatal(err)) throw err;
      lastError = err.message;
      log(`[replace] ${job.filename}: UI step failed: ${err.message}`);
      return fallback;
    }
  };
  if (current.status !== 'queued') return current;
  const needsReview = (error, replacePatch = {}) => {
    log(`[needs_review] ${current.filename} (trim replace): ${error}`);
    current = queue.update(current.id, {
      status: 'needs_review',
      error,
      attempts: current.attempts + 1,
      replace: { ...current.replace, ...replacePatch },
    });
    return current;
  };

  // Phase 1: the trimmed video must exist in Google Photos before anything else.
  if (current.replace.phase === 'received') {
    const staged = await ops.stage(current);
    let newItem = null;
    for (let i = 1; i <= attempts && !newItem; i++) {
      newItem = await tryOp(() => ops.findNew(current, staged), null); // a prior attempt may already have uploaded it
      if (newItem) break;
      log(`[replace] ${current.filename}: uploading trimmed video (attempt ${i}/${attempts})`);
      await tryOp(() => ops.upload(current, staged));
      newItem = await tryOp(() => ops.findNew(current, staged), null);
    }
    if (!newItem) return needsReview(`trimmed upload not confirmed in Google Photos after ${attempts} attempt(s)${lastError ? ` (last error: ${lastError})` : ''}; original left untouched`, { uploadName: staged.uploadName });
    current = queue.update(current.id, { replace: { ...current.replace, phase: 'uploaded', uploadName: staged.uploadName, newItem } });
    log(`[replace] ${current.filename}: trimmed upload confirmed at ${newItem.url}`);
  }

  // Phase 2: only now may the original go to Trash.
  let result = null;
  for (let i = 1; i <= attempts; i++) {
    result = await tryOp(() => ops.trashOriginal(current, current.replace.newItem), { outcome: 'unverified', detail: lastError });
    if (result.outcome === 'trashed') break;
    log(`[replace] ${current.filename}: original not trashed (${result.outcome}${result.detail ? `: ${result.detail}` : ''}), attempt ${i}/${attempts}`);
  }
  if (result.outcome !== 'trashed') {
    return needsReview(`trimmed version is in Google Photos, but the original was not trashed: ${result.outcome}${result.detail ? ` (${result.detail})` : ''}`);
  }
  current = queue.update(current.id, {
    status: 'trashed',
    error: null,
    attempts: current.attempts + 1,
    comparison: { replacedBy: current.replace.newItem.url, originalUrl: result.originalUrl ?? null },
    replace: { ...current.replace, phase: 'done' },
  });
  await ops.cleanup(current);
  log(`[trashed] ${current.filename} (trim replace, original trashed after trimmed upload confirmed)`);
  return current;
}

// ---------------------------------------------------------------------------
// Pure helpers used by worker.mjs's browser ops (kept here so tests can reach
// them without importing the 3800-line worker).
// ---------------------------------------------------------------------------

/**
 * Filename the trimmed copy is uploaded under: `<stem>-trim<ext>`. It must
 * differ from the original's name because that is how the worker tells the two
 * Google items apart afterwards (same capture second, same date search) -- the
 * info panel shows the uploaded file's name. Extension is kept (Google keys
 * media type off it), defaulting to .mov.
 */
export function replaceUploadName(originalFilename) {
  const m = /^(.*?)(\.[A-Za-z0-9]{2,5})?$/.exec(originalFilename);
  return `${m[1]}-trim${m[2] ?? '.mov'}`;
}

/**
 * ffmpeg argv that stream-copies the app's trimmed file (no re-encode) while
 * stamping the ORIGINAL's capture time on it. The app's passthrough export is
 * not guaranteed to carry creation metadata, and Google places an upload on
 * its timeline from it; without this the trimmed copy lands at upload time
 * instead of next to the original. Writes both the mvhd creation_time (UTC) and
 * the Apple `com.apple.quicktime.creationdate` tag (with the original's local
 * offset), the two fields Google/iOS read.
 */
export function buildStageArgs({ input, output, creationDate }) {
  const utc = new Date(creationDate).toISOString().replace(/\.\d{3}Z$/, 'Z');
  return [
    '-y', '-hide_banner', '-loglevel', 'error',
    '-i', input,
    '-map', '0', '-c', 'copy',
    '-movflags', '+faststart+use_metadata_tags',
    '-metadata', `creation_time=${utc}`,
    '-metadata', `com.apple.quicktime.creationdate=${creationDate}`,
    output,
  ];
}

/**
 * Does a tile's wall-clock reading (parseTileAriaLabel's wallClockAsUtcMs,
 * i.e. the local time as if UTC) correspond to the job's capture instant under
 * SOME real timezone offset? True when the difference is a 15-minute multiple
 * within +/-14h, give or take a second (Google and PhotoKit may round the
 * sub-second part differently). The browser's timezone is not known to the
 * worker, so this deliberately accepts any real offset; the filename in the
 * info panel is what actually identifies a candidate.
 */
export function offsetFits(wallClockAsUtcMs, creationDate) {
  const diffSec = (wallClockAsUtcMs - new Date(creationDate).getTime()) / 1000;
  if (Math.abs(diffSec) > 14 * 3600 + 1) return false;
  const rem = ((diffSec % 900) + 900) % 900;
  return rem <= 1 || rem >= 899;
}

/** "m:ss" / "h:mm:ss" -> seconds, or null when it is not a clock string. */
export function parseClock(text) {
  const m = /^(?:(\d+):)?(\d{1,2}):(\d{2})$/.exec(String(text).trim());
  if (!m) return null;
  return Number(m[1] ?? 0) * 3600 + Number(m[2]) * 60 + Number(m[3]);
}

/** Google shows whole seconds (rounded or floored); accept 2s either way. */
export function durationMatches(shownSec, expectedSec, toleranceSec = 2) {
  return shownSec != null && Math.abs(shownSec - expectedSec) <= toleranceSec;
}

/**
 * What a same-capture-second video in Google Photos is, for a trim-replace job.
 * Names alone cannot say: the Google Photos iOS app can itself back up the
 * edited video as a NEW item under the ORIGINAL filename (live 2026-10-16:
 * IMG_3699.MOV 0:59/67MB and a second IMG_3699.MOV 0:42/47MB, both "Uploaded
 * from iOS device"), so the worker trashed the trimmed one. Duration decides:
 *   'trimmed'  -- name is the original's or our upload name AND duration ~ the trimmed length
 *   'original' -- name is the original's AND duration is known and clearly LONGER than the trim
 *   'unknown'  -- anything else (other name, unreadable duration): never trashed, never confirmed
 */
export function classifyReplaceCandidate({ filename, durationSec }, job, uploadName) {
  if (!filename || durationSec == null) return 'unknown';
  const lower = filename.toLowerCase();
  const isOriginalName = lower === job.filename.toLowerCase();
  if (!isOriginalName && lower !== uploadName.toLowerCase()) return 'unknown';
  if (durationMatches(durationSec, job.replace.durationSec)) return 'trimmed';
  if (isOriginalName && durationSec > job.replace.durationSec + 2) return 'original';
  return 'unknown';
}
