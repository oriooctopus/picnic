/**
 * ffmpeg/ffprobe helpers for cutting a remote-album video to the range the
 * user trimmed in the app (stored in AlbumStore trims.json). Kept apart from
 * album.mjs so the store stays pure file IO and these can be unit-tested with
 * an injected runner or against real ffmpeg.
 */
import { execFile } from 'node:child_process';
import { promisify } from 'node:util';

const execFileAsync = promisify(execFile);

/**
 * Pure: ffmpeg argv that cuts input to [startSec, endSec] into output.
 * Re-encodes (libx264/aac) on purpose: `-c copy` can only cut on keyframes,
 * and a phone clip often has one every few seconds, so a copy-cut would start
 * up to seconds before the point the user chose. `-ss` BEFORE `-i` plus a
 * re-encode is frame-accurate and fast (it seeks, then decodes only the range).
 * `-t` (a length) rather than `-to`, because with input-side `-ss` the output
 * timeline restarts at 0 and `-to` would then be read against the wrong clock.
 */
export function buildTrimArgs({ input, output, startSec, endSec }) {
  if (!(Number.isFinite(startSec) && Number.isFinite(endSec) && startSec >= 0 && endSec > startSec)) {
    throw new Error(`invalid trim range: ${startSec}..${endSec}`);
  }
  return [
    '-y', '-hide_banner', '-loglevel', 'error',
    '-ss', String(startSec), '-i', input,
    '-t', String(endSec - startSec),
    '-c:v', 'libx264', '-preset', 'veryfast', '-crf', '18', '-pix_fmt', 'yuv420p',
    '-c:a', 'aac',
    '-movflags', '+faststart',
    output,
  ];
}

/** Runs ffmpeg; rejects (with stderr in the message) on a non-zero exit. */
export async function trimVideoFile(opts, { ffmpeg = 'ffmpeg', run = execFileAsync } = {}) {
  await run(ffmpeg, buildTrimArgs(opts));
}

/** Container duration in seconds via ffprobe. Throws if it cannot be read. */
export async function probeDurationSec(path, { ffprobe = 'ffprobe', run = execFileAsync } = {}) {
  const { stdout } = await run(ffprobe, [
    '-v', 'error', '-show_entries', 'format=duration', '-of', 'default=nw=1:nk=1', path,
  ]);
  const sec = Number.parseFloat(String(stdout).trim());
  if (!Number.isFinite(sec)) throw new Error(`ffprobe gave no duration for ${path}: ${JSON.stringify(String(stdout))}`);
  return sec;
}
