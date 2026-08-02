import { readFileSync } from 'node:fs';
import { timingSafeEqual } from 'node:crypto';

export function loadToken(tokenPath) {
  return readFileSync(tokenPath, 'utf8').trim();
}

/** Constant-time token compare (avoids leaking match length via timing). */
export function tokensMatch(a, b) {
  const bufA = Buffer.from(String(a ?? ''));
  const bufB = Buffer.from(String(b ?? ''));
  if (bufA.length !== bufB.length) {
    // Still run a comparison of equal-length buffers to avoid a fast bail-out
    // that leaks length via timing.
    timingSafeEqual(bufA, bufA);
    return false;
  }
  return timingSafeEqual(bufA, bufB);
}

export function checkBearerAuth(req, expectedToken) {
  const header = req.headers['authorization'] || '';
  const match = /^Bearer (.+)$/.exec(header);
  if (!match) return false;
  return tokensMatch(match[1], expectedToken);
}
