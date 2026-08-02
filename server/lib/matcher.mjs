/**
 * Pure decision logic for matching a queued deletion job (from the phone,
 * PhotoKit metadata) against candidate photos found by searching Google
 * Photos web by filename.
 *
 * SPEC requirement: filename AND capture timestamp AND pixel dimensions must
 * ALL agree for exactly one candidate before we act. Zero matches or more
 * than one match => ambiguous, never guess.
 *
 * Timestamp comparison must tolerate timezone skew between the phone's local
 * time and whatever Google Photos displays. We treat two timestamps as
 * agreeing if, after removing any whole-hour offset (DST / timezone), the
 * remainder is within toleranceMinutes. This matches "same wall-clock
 * moment, different UTC offset" without requiring us to know the offset.
 */

const DEFAULT_TOLERANCE_MINUTES = 5;

/** Minutes-of-remainder after folding out whole-hour offsets. */
function minutesDiffModHour(diffMinutes) {
  const mod = ((diffMinutes % 60) + 60) % 60;
  return Math.min(mod, 60 - mod);
}

export function timestampsAgree(isoA, isoB, toleranceMinutes = DEFAULT_TOLERANCE_MINUTES) {
  const a = new Date(isoA).getTime();
  const b = new Date(isoB).getTime();
  if (Number.isNaN(a) || Number.isNaN(b)) return { agree: false, diffMinutes: null };
  const diffMinutes = Math.abs(a - b) / 60000;
  const remainder = minutesDiffModHour(diffMinutes);
  return { agree: remainder <= toleranceMinutes, diffMinutes };
}

function filenamesAgree(a, b) {
  return typeof a === 'string' && typeof b === 'string' && a.toLowerCase() === b.toLowerCase();
}

function dimensionsAgree(job, candidate) {
  return job.pixelWidth === candidate.pixelWidth && job.pixelHeight === candidate.pixelHeight;
}

/**
 * @param job {{filename, creationDate, pixelWidth, pixelHeight}}
 * @param candidates {Array<{filename, captureDateTime, pixelWidth, pixelHeight}>}
 * @param opts {{toleranceMinutes?: number}}
 * @returns {{decision: 'match'|'ambiguous', matchedCandidate: object|null, comparisons: Array}}
 */
export function decideMatch(job, candidates, opts = {}) {
  const toleranceMinutes = opts.toleranceMinutes ?? DEFAULT_TOLERANCE_MINUTES;

  const comparisons = candidates.map((candidate) => {
    const filenameMatch = filenamesAgree(job.filename, candidate.filename);
    const { agree: timestampMatch, diffMinutes } = timestampsAgree(
      job.creationDate,
      candidate.captureDateTime,
      toleranceMinutes
    );
    const dimensionsMatch = dimensionsAgree(job, candidate);
    return {
      candidate,
      filenameMatch,
      timestampMatch,
      timestampDiffMinutes: diffMinutes,
      dimensionsMatch,
      agreeAll: filenameMatch && timestampMatch && dimensionsMatch,
    };
  });

  const agreeing = comparisons.filter((c) => c.agreeAll);

  if (agreeing.length === 1) {
    return { decision: 'match', matchedCandidate: agreeing[0].candidate, comparisons, toleranceMinutes };
  }
  return { decision: 'ambiguous', matchedCandidate: null, comparisons, toleranceMinutes };
}
