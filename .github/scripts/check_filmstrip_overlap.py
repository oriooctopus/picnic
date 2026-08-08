#!/usr/bin/env python3
"""Pixel-level check for the deck filmstrip's mixed-aspect-ratio regression.

XCUITest's accessibility-tree `frame.width` for the filmstrip thumbnails
stopped tracking real rendered geometry (confirmed by byte-identical widths
reported across three commits that each changed the rendering — see
test17DeckFilmstripMixedAspectRatios's doc comment in WalkthroughUITests.swift).
This script replaces that dead assertion with a real measurement of the
rendered pixels in the "24-deck-filmstrip-mixed-aspect" screenshot: it finds
the filmstrip row below the front card, segments it into individual
thumbnails by contrast against the near-black background, and asserts the
thumbnails are uniform width and have visible, non-overlapping gaps between
them.

Screenshots are 1170x2532 (iPhone 14 class @3x). pt = px/3.

Usage: check_filmstrip_overlap.py <screenshot.png>
Exit 0 on PASS, 1 on FAIL (including "filmstrip not found").
"""
import sys
from collections import Counter

from PIL import Image

# Minimum visible gap between adjacent thumbnails, in px, at 3x. Anything at
# or below this is indistinguishable from touching/overlapping cells.
MIN_GAP_PX = 3
# Uniformity tolerance: widest thumb must be within this fraction of the
# narrowest, otherwise something is overflowing its 24pt cell.
WIDTH_TOLERANCE_FRAC = 0.3


def dist(c1, c2):
    return sum(abs(a - b) for a, b in zip(c1, c2))


def load(path):
    im = Image.open(path).convert("RGB")
    return im, im.load(), im.size


def bg_color(px, w, h):
    corners = [px[2, 2], px[w - 3, 2], px[2, h - 3], px[w - 3, h - 3]]
    return Counter(corners).most_common(1)[0][0]


def row_is_fg(px, x_center, y, bg, thresh, halfwin=15, step=3, frac=0.5):
    xs = range(max(0, x_center - halfwin), x_center + halfwin + 1, step)
    n = 0
    fg = 0
    for x in xs:
        n += 1
        if dist(px[x, y], bg) > thresh:
            fg += 1
    return n > 0 and (fg / n) >= frac


def col_is_fg(px, y_center, x, bg, thresh, halfwin=15, step=3, frac=0.5):
    ys = range(max(0, y_center - halfwin), y_center + halfwin + 1, step)
    n = 0
    fg = 0
    for y in ys:
        n += 1
        if dist(px[x, y], bg) > thresh:
            fg += 1
    return n > 0 and (fg / n) >= frac


def find_horizontal_run_containing(px, w, h, y, bg, x_hint=None, thresh=30):
    runs = []
    start = None
    for x in range(w):
        isfg = col_is_fg(px, y, x, bg, thresh)
        if isfg and start is None:
            start = x
        elif not isfg and start is not None:
            runs.append((start, x - 1))
            start = None
    if start is not None:
        runs.append((start, w - 1))
    if not runs:
        return None, runs
    if x_hint is not None:
        for r in runs:
            if r[0] <= x_hint <= r[1]:
                return r, runs
    return max(runs, key=lambda r: r[1] - r[0]), runs


def find_filmstrip(px, w, h, bg, below_y, thresh=30):
    """Scan downward for the first horizontal contrast band below `below_y`
    that's a plausible thumbnail-row shape (roughly 20-200px tall, i.e.
    ~7-67pt, with at least one segment wider than 20px).

    Deliberately does NOT require segments to be uniform width or to number
    >=3 here — an overlap bug can MERGE what should be 3 separate thumbnails
    into fewer, wider contiguous runs, and that merge is itself the failure
    this check needs to catch. Filtering it out at detection time would just
    make the check report "filmstrip not found" instead of "overlap
    detected", which is a worse failure message for the same underlying
    problem. Segment-count/uniformity assertions happen in main() instead.
    """
    y = below_y
    while y < h - 2:
        row_has_fg = any(dist(px[x, y], bg) > thresh for x in range(0, w, 4))
        if not row_has_fg:
            y += 1
            continue
        band_top = y
        yy = y
        while yy < h and any(dist(px[x, yy], bg) > thresh for x in range(0, w, 4)):
            yy += 1
        band_bottom = yy - 1
        band_h = band_bottom - band_top + 1
        mid = (band_top + band_bottom) // 2
        _, segs = find_horizontal_run_containing(px, w, h, mid, bg, thresh=thresh)
        widths = [s[1] - s[0] for s in segs]
        if 20 <= band_h <= 200 and widths and max(widths) > 20:
            return band_top, band_bottom, segs
        y = band_bottom + 1
    return None


def main():
    if len(sys.argv) != 2:
        print(f"Usage: {sys.argv[0]} <screenshot.png>")
        return 2
    path = sys.argv[1]

    im, px, (w, h) = load(path)
    bg = bg_color(px, w, h)

    # Filmstrip sits below the front card. We don't need the card's exact
    # bbox here — scanning from a generous fixed offset finds the same band
    # find_filmstrip's contiguous-contrast-band logic would from below the
    # card, since nothing else on this screen produces a >=3-segment
    # uniform-width run above the filmstrip.
    fs = find_filmstrip(px, w, h, bg, below_y=int(h * 0.4))
    if fs is None:
        print(f"FAIL: could not find the filmstrip row in {path} (image {w}x{h}, bg={bg})")
        return 1

    fb_top, fb_bottom, segs = fs
    widths_px = [s[1] - s[0] + 1 for s in segs]
    gaps_px = [segs[i + 1][0] - segs[i][1] - 1 for i in range(len(segs) - 1)]
    widths_pt = [round(wpx / 3, 2) for wpx in widths_px]
    gaps_pt = [round(g / 3, 2) for g in gaps_px]

    print(f"Filmstrip row: y=[{fb_top},{fb_bottom}] ({len(segs)} thumbnails found)")
    print(f"  widths_px={widths_px}  widths_pt={widths_pt}")
    print(f"  gaps_px={gaps_px}  gaps_pt={gaps_pt}")

    failures = []

    if len(segs) < 3:
        failures.append(
            f"only {len(segs)} contiguous thumbnail run(s) found (expected 3) — "
            f"adjacent thumbnails have likely merged into one run because one "
            f"overflowed its 24pt cell and bled into its neighbor, eliminating the gap"
        )

    overlaps = [g for g in gaps_px if g <= 0]
    if overlaps:
        failures.append(f"overlap detected: {len(overlaps)} gap(s) <= 0px (thumbnails touching/overlapping)")

    thin_gaps = [g for g in gaps_px if 0 < g <= MIN_GAP_PX]
    if thin_gaps:
        failures.append(f"gap(s) too small to be a visible separation: {thin_gaps}px (min required > {MIN_GAP_PX}px)")

    max_w, min_w = max(widths_px), min(widths_px)
    if (max_w - min_w) > WIDTH_TOLERANCE_FRAC * max_w:
        failures.append(
            f"non-uniform thumbnail widths: max={max_w}px min={min_w}px "
            f"(spread {max_w - min_w}px exceeds {WIDTH_TOLERANCE_FRAC:.0%} of max — "
            f"a wider cell means its aspect-fill source overflowed its 24pt frame)"
        )

    if failures:
        print("FAIL:")
        for f in failures:
            print(f"  - {f}")
        return 1

    print("PASS: filmstrip thumbnails are uniform width with visible non-overlapping gaps")
    return 0


if __name__ == "__main__":
    sys.exit(main())
