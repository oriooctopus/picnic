# Picnic — iOS app

SwiftUI, iOS 17+, PhotoKit. See `SPEC.md` for the full contract; this covers
build/install/what-talks-to-what for the `app/` half specifically. The
`server/` half (mirror queue + Google Photos worker) is owned by a separate
agent/README.

## Project structure

```
app/
  project.yml              XcodeGen spec — the source of truth for the Xcode project
  Picnic/
    App/                   entry point, AppState, Config, MirrorToken (CI-baked)
    Models/                MonthBucket, CompareGroup, SwiftData @Model types
    Services/               PhotoLibraryService, SortStore, GroupingService,
                            MirrorClient/MirrorQueueStore, ThumbnailLoader
    Views/
      MyLife/               month grid, year sections, streak, long-press sort
      Deck/                 swipe-sort card stack, filmstrip, hide-sorted filter
      Compare/               time-proximity group resolution
      Utilities/             smart collections
      Profile/               placeholder
    Resources/              Assets.xcassets (Info.plist is generated, not committed)
  PicnicUITests/            launch + tab-navigation smoke test
  fastlane/                 Appfile, Fastfile (adhoc lane)
  scripts/mock_mirror_server.py   throwaway local stand-in for server/ during dev
.github/workflows/
  ota.yml                   ad-hoc build → ota-ipa artifact
  sim-test.yml               simulator build + UI smoke test
```

No CocoaPods — everything used (PhotoKit, PhotosUI, SwiftData) is a system
framework, so there's no `.xcworkspace`, just the XcodeGen-generated
`.xcodeproj`.

## Why XcodeGen instead of a hand-written `.pbxproj`

Overland-iOS hand-maintains its `.pbxproj` (with a `gen-project.yml` helper
that runs Ruby `xcodeproj` mutator scripts on a macOS runner, since the dev
box here has no Xcode). That works because Overland's project structure is
stable and rarely changes shape. Picnic's view/service tree is much larger
and still moving, and hand-editing a `.pbxproj`'s UUID graph with no Xcode or
compiler to validate it is exactly the kind of thing that silently corrupts.
`project.yml` regenerates a correct `.xcodeproj` deterministically from the
folder structure on every CI run (`xcodegen generate`, installed via `brew`),
so the project file is never something committed or hand-edited — Xcode/CI
only ever sees a fresh, structurally-valid one.

## Build & install

CI does this automatically on every push to `main` (`ota.yml`):
`xcodegen generate` → import the dist cert → bake `PICNIC_MIRROR_TOKEN` into
`MirrorToken.swift` → `fastlane adhoc` → upload the ipa as the `ota-ipa`
artifact.

**Local build** (needs a Mac with Xcode + `brew install xcodegen`):
```
cd app
xcodegen generate
open Picnic.xcodeproj   # or: xcodebuild -project Picnic.xcodeproj -scheme Picnic build
```

**Install on device**: same ad-hoc-over-the-air pattern as Overland-iOS —
the `ota-ipa` artifact needs a poller (like
`~/.local/share/ota-install/bin/ota.py`) to publish it to an install page.
**That poller is currently hardcoded to one app (Assistant Location)** — see
"Open risks" below. Once a Picnic-specific poller instance exists, the
1-line install link goes here.

## What talks to what

- **PhotoKit** (`PhotoLibraryService`) reads the camera roll, buckets by
  month, and is the only place that calls `PHAssetChangeRequest.deleteAssets`
  — always from an explicit user commit (deck X, or a confirmed Compare
  group resolution), and always shows iOS's own system confirm dialog.
- **SwiftData** (`PersistenceController`, `SortStore`, `MirrorQueueStore`)
  persists per-asset sort state, the manual per-month "mark sorted" override,
  the streak counter, resolved Compare groups, and the mirror job queue —
  all in the app's own container, on-device only.
- **Mirror queue** (`MirrorClient`): after a successful delete, each deleted
  asset's identity (`filename`, `creationDate`, `pixelWidth`, `pixelHeight`,
  `mediaType`, `isLivePhoto`) is POSTed to
  `http://MIRROR_HOST:8307/queue` with a bearer token. A
  failed POST stays "pending" in SwiftData (never dropped) and retries on the
  next launch or foreground — see `MirrorSyncBanner` for the in-app "N not
  yet mirrored" indicator. The mirror server itself (`server/`) moves matched
  photos to Google Photos trash, never permanent delete.

## Deviations from SPEC.md

- **Mirror port is 8307, not 8306.** SPEC.md says 8306; the actual
  `picnic-mirror` service ended up on 8307 because 8306 was already taken on
  the host. `Config.swift` and this README use 8307.
- **Deck/Compare/smart-collections are not tabs.** SPEC.md's own bullet list
  says "bottom tab bar: months grid / utilities / profile" — Deck (from a
  month card) and Compare (from a Compare pill) are pushed full-screen, not
  additional tabs.
- **Swipe-right semantics.** SPEC.md's interaction semantics #1 only
  describes swipe-as-delete-cue; it doesn't specify what a swipe in the other
  direction does. Implemented as "keep" (marks `.kept`, no PhotoKit call,
  advances the deck) — the standard convention for this app genre and the
  only way the reference screenshots' deck flow makes sense as a two-way
  swipe. Flagging this as an assumption, not a literal spec requirement.
- **Utilities smart collections are read-only paged browsers** (heart to
  favorite), not sortable decks — SPEC.md describes them as "smart
  collections with counts," and DeckViewModel's month/commit semantics don't
  map cleanly onto a collection that isn't a calendar month.
- **BEST heuristic (largest file size)** is computed via
  `PHImageManager.requestImageDataAndOrientation`, a public API, rather than
  the private `PHAssetResource.fileSize` KVC trick some apps use. Slightly
  more code, no private-API risk. It fetches full image data for photos only
  in the 2-6 assets of an open Compare group — never the whole library — so
  the cost is bounded.
- **Streak increments on any addressed photo** (kept, marked-for-delete, or a
  compare resolution), once per calendar day. SPEC.md doesn't define the
  streak's trigger condition precisely; this is the most natural reading of
  "keep sorting daily."

## Open risks

- **OTA poller is single-app.** `~/.local/share/ota-install/bin/ota.py` on
  the dev machine hardcodes `REPO = "oriooctopus/assistant-location"` and a
  single `.ipa`/`manifest.plist` pair for Assistant Location. Picnic's
  `ota.yml` produces a correctly-shaped `ota-ipa` artifact, but nothing
  currently polls *this* repo's `ota.yml` runs — either that script needs a
  multi-app mode, or a second poller service/systemd unit needs to be stood
  up pointing at this repo. That's infra outside this repo (and outside
  `app/`), so it's called out here rather than done silently.
- **First-run bundle id self-provisioning is untested against the real
  Developer Portal.** `ensure_bundle_id` in `fastlane/Fastfile` mirrors the
  pattern Overland-iOS uses for its share-extension bundle id
  (`Spaceship::ConnectAPI::BundleId.create`), which is proven to work for a
  *secondary* id there. This is the first time it's asked to register a
  *primary* app id from scratch — if App Store Connect's API key permissions
  or the BundleId creation payload need anything extra for a primary app
  (vs. an extension), the very first `ota.yml` run is where that would
  surface. Watch the first CI run closely.
- **No CocoaPods, but also no dependency isolation testing.** Since the app
  only uses system frameworks, there's nothing to validate here beyond what
  `sim-test.yml` already covers — noting it because Overland's CI pattern
  assumes Pods exist and Picnic's doesn't, so anyone diffing the two
  workflows should expect that step to simply be absent, not missing.
- **Compare group "total resolution" deletes outside the deck's X commit.**
  This is intentional (SPEC.md interaction semantics #2), gated on an
  explicit checkmark confirm, and still shows PhotoKit's own system dialog —
  but it means there are two independent user-facing delete-confirm flows in
  the app (deck commit, and compare resolve) rather than one. Worth Oliver's
  attention on first real-device test to make sure both feel deliberate and
  neither feels like an accidental delete.
- **Sim-test doesn't exercise PhotoKit delete or the mirror POST.** Per
  SPEC.md's own verification section, that's scoped to Oliver's manual
  real-device OTA test, not CI — flagging so it's not mistaken for gap in
  the CI coverage that should have been closed.
