# Picnic — swipe-sort photo cleanup app + Google Photos deletion mirror

Purpose: let Oliver keep Google Photos as his library while killing the
delete-twice problem. A personal clone of the "Picnic" iOS app: swipe-sort the
camera roll month by month; committed deletions remove photos locally via
PhotoKit AND are mirrored to Google Photos **trash** (never permanent delete —
permanent deletion stays a manual step Oliver does himself in Google Photos).

Team/signing: reuse the Overland-iOS pipeline (repo
`~/coding/assistant/Overland-iOS`) — GitHub Actions macOS runner, dist cert
`BUILD_CERT_P12` + `P12_PASSWORD` secrets, App Store Connect API key via
fastlane (`asc_api_key` lane), ad-hoc profile auto-downloaded, ipa served over
the ota-install server (`~/.local/share/ota-install`, tailnet
https://MIRROR_HOST:10000/). Team `J66WVM2DTX`, apple id
oliverullman@gmail.com. New bundle id: `com.oliverullman.picnic`.

## Reference screenshots (real Picnic app, read these before building UI)

All in `/home/esme/inbox/`, files `2026-08-02-1453*-IMG_138[2-9].png` and
`...-IMG_1390.png`:

- IMG_1382, IMG_1388, IMG_1389 — "My life" home: year sections (2025, 2026),
  month cards in a 4-col grid, each with cover thumbnail and either a photo
  count (unsorted remaining) or green "Sorted". Top bar: filter button, streak
  flame with count, gift icon. Long-press a month card → context menu "Mark as
  sorted / Mark as unsorted" (IMG_1388/1389). Floating ↑ scroll-to-top; bottom
  tab bar: months grid / utilities / profile (red-dot badge).
- IMG_1383, IMG_1386 — deck view for a month: full-bleed card stack, header
  "October 2025" + exact "OCT 4, 2025 · 3:25 AM", shuffle top-left, X top-right
  (with red count badge once swipes are pending — IMG_1386). Live Photo
  indicator top-left of the photo. "Compare N >" pill at photo bottom when the
  photo belongs to a similar-shot group. Bottom row: heart (favorite),
  add-to-album, share. Thumbnail filmstrip + "2 OF 56" position, undo
  bottom-left, filter bottom-right. Note IMG_1386: count went 56→55 after one
  sort and the X badge shows 1.
- IMG_1384, IMG_1385 — Compare flow (tap the pill): horizontally paged
  full-size cards of the group, one marked "★ BEST · date · time · size"
  (others show date · time · size only), per-photo buttons trash | thumbs-up |
  heart, thumbnail row of the group (green dot = kept), X bottom-left,
  check bottom-right. Check/X only become enabled once at least one photo in
  the group has been sorted.
- IMG_1387 — deck view "Hide:" popover: "✓ Sorted pics" toggle + "More
  settings".
- IMG_1390 — Utilities tab: Recents (Today 14 / Yesterday 24 / Last 7 days
  38), then Shuffle 1,123 / Favorites 28 / Screenshots 19 / Videos 140 /
  Photos 964 / Live photos 489 — smart collections with counts.

## Interaction semantics (Oliver's explicit requirements — do not deviate)

1. **Swipe is only a cue.** Swiping a card marks it for deletion (X badge
   count increments); nothing is deleted yet. The **top-right X commits**: one
   PhotoKit batch delete of everything marked (iOS shows its single system
   confirm; photos go to iOS Recently Deleted), and each committed asset is
   queued for the Google Photos mirror.
2. **Compare-group resolution is total.** In a compare group, the moment at
   least one photo is sorted the bottom controls become enabled, and
   confirming resolves the WHOLE group: accepting (thumbs-up) one photo
   deletes all the others in the group; deleting one photo deletes them all.
   Unaddressed group members are never left dangling.
3. **Long-press a photo plays its Live Photo.**
4. **Google side goes to TRASH only.** The mirror worker moves matched photos
   to Google Photos trash; it must never touch "Delete permanently". Restoring
   or purging trash is Oliver's call, in Google's own UI.

## Architecture

### iOS app (`app/`) — SwiftUI, iOS 17+, PhotoKit
- Read library with `PHPhotoLibrary`/`PHAsset`, month buckets by creationDate.
- Sorted/unsorted state per asset + per month, streak count, favorites →
  local persistence (SwiftData or JSON in app container). "Sorted" month =
  every asset addressed or manually marked sorted.
- Similar-group detection for Compare: cluster by capture time proximity
  (≤10 s gap, same day) as v1; BEST = largest file size in group as the
  default heuristic (matches the ★ BEST size display).
- Commit X → `PHAssetChangeRequest.deleteAssets` batch; on success POST each
  deleted asset's identity to the mirror queue over Tailscale:
  `{filename (originalFilename), creationDate ISO8601 with tz, pixelWidth,
  pixelHeight, mediaType, isLivePhoto}` with a bearer token. Queue POSTs are
  fire-and-retry (background URLSession, survives offline: persist unsent).
- Favorite (heart) → `PHAssetChangeRequest.isFavorite`. v1 favorites are
  local/Apple-only; do not mirror favorites to Google.
- Utilities tab: smart collections via `PHAssetCollection` smart albums +
  mediaSubtypes (screenshots, live, videos).
- Undo: unswipe last action while uncommitted.
- Hide-sorted toggle in deck filter.

### Mirror server (`server/`) — Node, port 8307, systemd user unit `picnic-mirror`
(8306 in an earlier draft, but that port was already taken by podctl — 8307 is
the registered port.)
- Binds 0.0.0.0 (phone reaches it over Tailscale). Bearer token in
  `~/.config/picnic/token` (generate, chmod 600, also append to
  `~/.claude/tokens.env` as PICNIC_MIRROR_TOKEN).
- `POST /queue` — append deletion jobs (JSONL on disk, idempotent by
  filename+timestamp key). `GET /queue` — status. `POST /retry/<id>`.
- Worker drains the queue against Google Photos web in the CDP Chrome on
  port 9251 (Windows relay; `connectOverCDP("http://$GW:9251")`, GW = default
  route gateway; profile signed into oliverullman@gmail.com). Per job:
  search by filename in photos.google.com, open candidates, verify match on
  **filename + capture timestamp + dimensions (all three must agree** — the
  info panel shows all); matched → move to trash via the UI; ambiguous or
  no-match → mark `needs_review` in the queue, never guess. Pace: one job
  every few seconds, batch cap per run.
- Playwright rules apply (~/.claude/rules/playwright.md): any breakage
  surfaced loudly, never silently skip.

### CI (`.github/workflows/`) — copy Overland-iOS `ota.yml` pattern
- macOS runner, same cert secrets, fastlane ad-hoc lane for
  `com.oliverullman.picnic` (fastlane `produce`/App Store Connect API creates
  the new app id + ad-hoc profile using the existing `asc_api_key` lane
  pattern), ipa + manifest.plist published to the ota-install server's
  `public/` (same publish step ota.yml uses — read it).
- No TestFlight needed for v1; ad-hoc OTA only.

## v1 scope cuts
- No gamification beyond the streak counter display; no gift/referral UI.
- No albums/add-to-album action (button can be present but disabled).
- No share-sheet niceties beyond the system share sheet.
- Profile tab = placeholder.
- Similarity clustering = time-proximity only (no ML embeddings yet).

## Verification (before calling anything done)
- iOS: sim-test workflow pattern from Overland-iOS (build + UI smoke test on
  simulator in CI). PhotoKit deletion flows need the real device — Oliver
  installs OTA and tests; provide him a 1-line install link.
- Server: unit tests for queue + matcher decision logic; live worker test
  against a THROWAWAY photo Oliver uploads (or an existing junk screenshot),
  confirming it lands in Google Photos trash and nothing else was touched.
