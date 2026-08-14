#!/usr/bin/env python3
"""Pixel-level check that the filmstrip's rendered content actually changes
after swiping under hideSorted at scale.

test31FilmstripDropsCountUnderHideSortedAtScale already proves the VIEW
MODEL's total (the "N OF M" position label, driven straight off
DeckViewModel.visibleAssets.count) drops by exactly one on every swipe. That
was never really in doubt — it's plain array math. What it CANNOT prove is
whether the FILMSTRIP VIEW itself repaints to match: an XCUITest
accessibility-tree assertion can't tell a freshly-rendered cell from a stale
one still showing pre-swipe pixels (same blind spot as D1's blank-thumbnail
regression — see check_filmstrip_content.py, whose band-finding logic this
reuses). "The count is right but the strip looks unchanged" is exactly the
owner's real-device report, so this is the check that actually targets it:
it diffs the real pixels of the filmstrip band between a screenshot taken
before any swipe ("30-filmstrip-before-scale-swipes") and one taken after
five alternating swipes ("31-filmstrip-after-scale-swipes"), and fails if the
band looks the same.

Screenshots are 1170x2532 (iPhone 14 class @3x). pt = px/3.

Usage: check_filmstrip_visually_updated.py <before.png> <after.png>
Exit 0 on PASS, 1 on FAIL (including "filmstrip not found").
"""
import sys
from collections import Counter

from PIL import Image

# Fraction of sampled band pixels that must differ by more than PIXEL_THRESH
# for the strip to count as "visually updated". Five swipes each remove a
# 24x36pt cell and shift/replace neighbours, so a real update changes a large
# swath of the band — this is deliberately loose (real photos also
# anti-alias/dither slightly frame to frame even when unchanged) so it only
# fires on a strip that is genuinely still showing the pre-swipe content.
MIN_CHANGED_FRACTION = 0.05
PIXEL_THRESH = 24


def load(path):
    im = Image.open(path).convert("RGB")
    return im, im.load(), im.size


def dist(c1, c2):
    return sum(abs(a - b) for a, b in zip(c1, c2))


def bg_color(px, w, h):
    corners = [px[2, 2], px[w - 3, 2], px[2, h - 3], px[w - 3, h - 3]]
    return Counter(corners).most_common(1)[0][0]


def col_is_fg(px, y_center, x, bg, thresh, halfwin=15, step=3, frac=0.5):
    ys = range(max(0, y_center - halfwin), y_center + halfwin + 1, step)
    n = 0
    fg = 0
    for y in ys:
        n += 1
        if dist(px[x, y], bg) > thresh:
            fg += 1
    return n > 0 and (fg / n) >= frac


def find_horizontal_run_containing(px, w, h, y, bg, thresh=30):
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
    return runs


def find_filmstrip(px, w, h, bg, below_y, thresh=30):
    """Same band-scan as check_filmstrip_overlap.py's find_filmstrip — see
    that file for why segment-count/uniformity isn't enforced at this
    stage."""
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
        segs = find_horizontal_run_containing(px, w, h, mid, bg, thresh=thresh)
        widths = [s[1] - s[0] for s in segs]
        if 20 <= band_h <= 200 and widths and max(widths) > 20:
            return band_top, band_bottom
        y = band_bottom + 1
    return None


def main():
    if len(sys.argv) != 3:
        print(f"Usage: {sys.argv[0]} <before.png> <after.png>")
        return 2
    before_path, after_path = sys.argv[1], sys.argv[2]

    before_im, before_px, (bw, bh) = load(before_path)
    after_im, after_px, (aw, ah) = load(after_path)

    if (bw, bh) != (aw, ah):
        print(f"FAIL: before/after screenshots differ in size ({bw}x{bh} vs {aw}x{ah}) — can't diff pixel-for-pixel")
        return 1

    before_bg = bg_color(before_px, bw, bh)
    before_band = find_filmstrip(before_px, bw, bh, before_bg, below_y=int(bh * 0.4))
    if before_band is None:
        print(f"FAIL: could not find the filmstrip row in {before_path} (image {bw}x{bh}, bg={before_bg})")
        return 1

    after_bg = bg_color(after_px, aw, ah)
    after_band = find_filmstrip(after_px, aw, ah, after_bg, below_y=int(ah * 0.4))
    if after_band is None:
        print(f"FAIL: could not find the filmstrip row in {after_path} (image {aw}x{ah}, bg={after_bg})")
        return 1

    # Use the union of both bands' y-range: a genuinely broken strip (frozen
    # in place) would report the identical band in both shots anyway, and
    # unioning avoids missing real changed pixels near either edge if the
    # band height itself shifted by a pixel or two between captures.
    top = min(before_band[0], after_band[0])
    bottom = max(before_band[1], after_band[1])
    print(f"Filmstrip band: before={before_band} after={after_band} (comparing y=[{top},{bottom}])")

    changed = 0
    total = 0
    for x in range(0, bw, 2):
        for y in range(top, bottom + 1, 2):
            total += 1
            if dist(before_px[x, y], after_px[x, y]) > PIXEL_THRESH:
                changed += 1

    frac = changed / total if total else 0.0
    print(f"Changed pixels: {changed}/{total} ({frac:.1%})")

    if frac < MIN_CHANGED_FRACTION:
        print(f"FAIL: filmstrip band looks essentially unchanged after 5 swipes "
              f"({frac:.1%} of sampled pixels differ, need >= {MIN_CHANGED_FRACTION:.0%}) — "
              f"the strip is not visually updating, matching the owner's real-device report")
        return 1

    print(f"PASS: filmstrip band visibly changed after swiping ({frac:.1%} of sampled pixels differ)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
