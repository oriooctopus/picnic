#!/usr/bin/env python3
"""Turn xcresulttool's exported attachments into the flat, named PNG set
visual-walk.yml uploads as the `visual-walk` artifact.

`xcrun xcresulttool get test-results attachments --path <xcresult>
--output-path <dir>` exports every XCTAttachment plus a manifest.json
mapping each exported file back to the XCTAttachment.name WalkthroughUITests
set (e.g. "01-mylife"). This parses that manifest and falls back to
substring-matching raw filenames if a given Xcode version doesn't preserve
names in the manifest the same way.

Usage: extract_walkthrough_screenshots.py <extracted_dir> <screenshots_dir>
Exits non-zero (after copying whatever was found) if any expected shot is missing.
"""
import glob
import json
import os
import shutil
import sys

EXPECTED = [
    "00-launch",
    "01-mylife", "02-longpress-context-menu", "03-deck-first-card",
    "04-deck-swiped-x1", "05-deck-undo", "06-deck-filter-popover",
    "07-compare-initial", "08-compare-thumbsup", "09-compare-confirm-dialog",
    "10-utilities", "11-smart-shuffle", "12-smart-favorites",
    "13-smart-screenshots", "14-smart-videos", "15-smart-photos",
    "16-smart-livephotos", "17-profile",
]


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

    print(f"Found {len(EXPECTED) - len(missing)}/{len(EXPECTED)} screenshots")
    if missing:
        print("MISSING:", missing)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
