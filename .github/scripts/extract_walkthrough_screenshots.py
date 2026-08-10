#!/usr/bin/env python3
"""Turn xcresulttool's exported attachments into the flat, named PNG set
visual-walk.yml uploads as the `visual-walk` artifact.

`xcrun xcresulttool get test-results attachments --path <xcresult>
--output-path <dir>` exports every XCTAttachment plus a manifest.json
mapping each exported file back to the XCTAttachment.name WalkthroughUITests
set (e.g. "01-mylife"). This parses that manifest and falls back to
substring-matching raw filenames if a given Xcode version doesn't preserve
names in the manifest the same way.

Usage: extract_walkthrough_screenshots.py <extracted_dir> <screenshots_dir> [export_log]

WalkthroughUITests is split into independent test0N... methods (one per
screen/state) so a single failing assertion can't take out the whole
walkthrough. Each method's tearDown captures its own "99-final-<method>"
shot, so those 10 are optional/best-effort — a method that never got that
far (e.g. it failed early) simply won't have one, and that's not itself a
reason to fail the extraction step. Every other capture is still expected
from whichever test method produces it; only the XCTest pass/fail counts,
not this script, mark the CI run failed.

Exits non-zero only if NOTHING was extracted (a real pipeline problem, e.g.
the xcresult never got produced) — a partial set is copied and reported so
the workflow can still surface it as an artifact instead of throwing it away.
"""
import glob
import json
import os
import shutil
import sys

REQUIRED = [
    "00-launch",
    "01-mylife", "02-longpress-context-menu", "03-deck-first-card",
    "04-deck-swiped-x1", "05-deck-undo", "06-deck-filter-popover",
    "07-compare-initial", "08-compare-thumbsup", "09-compare-confirm-dialog",
    "10-utilities", "11-smart-shuffle", "12-smart-favorites",
    "13-smart-screenshots", "14-smart-videos", "15-smart-photos",
    "16-smart-livephotos", "17-profile",
    "18-deck-large-month", "19-deck-exit-nothing-pending",
    "20-compare-swipe-down-exit", "21-hide-sorted-on",
    "22-deck-drag-framerate", "23-deck-drag-framerate-large",
    "24-deck-filmstrip-mixed-aspect",
    "25-deck-pending-before-relaunch", "26-deck-pending-after-relaunch",
    "27-deck-swipe-down-from-top-exit", "28-compare-mismatched-aspect",
]

# Best-effort: one per test method, captured in tearDown. See module
# docstring — a missing one just means that method failed before tearDown
# ran, which the XCTest result already reports.
OPTIONAL = [
    "99-final-test01MyLifeGrid",
    "99-final-test02DeckFirstCard",
    "99-final-test03DeckSwipeAndUndo",
    "99-final-test04DeckFilterPopover",
    "99-final-test05CompareInitialAndThumbsUp",
    "99-final-test06CompareConfirmDialog",
    "99-final-test07Utilities",
    "99-final-test08SmartCollections",
    "99-final-test09Profile",
    "99-final-test10LongPressContextMenu",
    "99-final-test11DeckLargeMonthStaysResponsive",
    "99-final-test12DeckExitWithNothingPending",
    "99-final-test13CompareSwipeDownToExit",
    "99-final-test14HideSortedActuallyFilters",
    "99-final-test15DeckDragFrameRate",
    "99-final-test18DeckPendingDeletePersistsAcrossRelaunch",
    "99-final-test19DeckSwipeDownFromTopExits",
    "99-final-test20CompareButtonsReachableWithMismatchedAspect",
]

EXPECTED = REQUIRED + OPTIONAL


def main() -> int:
    extracted_dir, screenshots_dir = sys.argv[1], sys.argv[2]
    export_log = sys.argv[3] if len(sys.argv) > 3 else None
    found = {}

    # Primary source on current Xcode: `export attachments` prints the mapping
    # to stdout as lines like
    #   File: 864F26C2-....png, suggested name: "01-mylife_0_DF83....png"
    # while the on-disk files are bare UUIDs. Parse the captured stdout.
    if export_log and os.path.exists(export_log):
        import re
        pat = re.compile(r'File: (\S+?),\s+suggested name: "?([^"\n]+)"?')
        for line in open(export_log):
            m = pat.search(line)
            if not m:
                continue
            exported, suggested = m.group(1), m.group(2)
            for exp_name in EXPECTED:
                if suggested.startswith(exp_name) and exp_name not in found:
                    matches = glob.glob(os.path.join(extracted_dir, "**", exported), recursive=True)
                    if matches:
                        found[exp_name] = matches[0]

    for manifest_path in glob.glob(os.path.join(extracted_dir, "**", "manifest.json"), recursive=True):
        with open(manifest_path) as f:
            manifest = json.load(f)
        attachments = manifest.get("attachments", manifest) if isinstance(manifest, dict) else manifest
        manifest_dir = os.path.dirname(manifest_path)
        for entry in attachments:
            name = entry.get("name") or entry.get("suggestedHumanReadableName") or ""
            exported = entry.get("exportedFileName") or entry.get("filename")
            if not exported:
                continue
            for exp_name in EXPECTED:
                if exp_name in name and exp_name not in found:
                    candidate = os.path.join(manifest_dir, exported)
                    if not os.path.exists(candidate):
                        matches = glob.glob(os.path.join(extracted_dir, "**", exported), recursive=True)
                        candidate = matches[0] if matches else candidate
                    if os.path.exists(candidate):
                        found[exp_name] = candidate

    if len(found) < len(EXPECTED):
        all_files = glob.glob(os.path.join(extracted_dir, "**", "*"), recursive=True)
        for exp_name in EXPECTED:
            if exp_name in found:
                continue
            for f in all_files:
                if exp_name in os.path.basename(f):
                    found[exp_name] = f
                    break

    os.makedirs(screenshots_dir, exist_ok=True)
    missing = []
    for exp_name in EXPECTED:
        if exp_name in found:
            shutil.copy(found[exp_name], os.path.join(screenshots_dir, exp_name + ".png"))
        else:
            missing.append(exp_name)

    missing_required = [m for m in missing if m in REQUIRED]
    missing_optional = [m for m in missing if m in OPTIONAL]

    print(f"Found {len(EXPECTED) - len(missing)}/{len(EXPECTED)} screenshots")
    if missing_required:
        print("MISSING (required):", missing_required)
    if missing_optional:
        print("MISSING (optional 99-final-* — the owning test likely failed before tearDown):", missing_optional)

    if not found:
        print("Nothing was extracted at all — treating as a pipeline failure.")
        return 1

    # A partial set is still useful signal — surface it as an artifact
    # rather than throwing it away. The XCTest pass/fail counts are what
    # mark the CI run failed, not this script.
    return 0


if __name__ == "__main__":
    sys.exit(main())
