import { existsSync, readFileSync, appendFileSync, mkdirSync } from 'node:fs';
import { dirname } from 'node:path';

export const RESOLVE_ACTIONS = ['deleted', 'kept'];

function readJsonl(path) {
  if (!existsSync(path)) return [];
  return readFileSync(path, 'utf8').split('\n').filter(Boolean).map((l) => JSON.parse(l));
}

/**
 * Read side of the location server's superapp-uploads.jsonl (one record per iPhone Superapp
 * upload) plus Picnic's own resolutions.jsonl ({id, action, resolvedAt} lines).
 */
export class SuperappUploads {
  constructor(uploadsPath, resolutionsPath) {
    this.uploadsPath = uploadsPath;
    this.resolutionsPath = resolutionsPath;
  }

  /** Unresolved records, newest first. */
  listPending() {
    const resolved = new Set(readJsonl(this.resolutionsPath).map((r) => r.id));
    return readJsonl(this.uploadsPath)
      .filter((u) => !resolved.has(u.id))
      .sort((a, b) => b.receivedAt.localeCompare(a.receivedAt));
  }

  /** Returns the number of ids newly resolved (already-resolved ids are not appended again). */
  resolve(ids, action) {
    const done = new Set(readJsonl(this.resolutionsPath).map((r) => r.id));
    const fresh = [...new Set(ids)].filter((id) => !done.has(id));
    if (fresh.length) {
      mkdirSync(dirname(this.resolutionsPath), { recursive: true });
      const at = new Date().toISOString();
      appendFileSync(this.resolutionsPath, fresh.map((id) => JSON.stringify({ id, action, resolvedAt: at })).join('\n') + '\n');
    }
    return fresh.length;
  }
}
