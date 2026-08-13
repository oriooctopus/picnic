#!/usr/bin/env python3
"""Pixel-level check for D1 (the filmstrip blank-thumbnail regression).

FilmstripView keyed each cell's view *identity* on asset localIdentifier via
ForEach, but then applied `.id(index)` on top of it, which silently
overrides that identity back to raw array position. Removing any item (e.g.
a hideSorted swipe) shifted every later cell's index, so SwiftUI tore down
and rebuilt those views from scratch — resetting each cell's `@State private
var image` to nil — and they rendered as empty gray rounded rects until each
cell's `.task` re-fetched. See test30FilmstripThumbnailsRetainImageAfterSwipeUnderHideSorted's
doc comment in WalkthroughUITests.swift: a blanked cell still EXISTS in the
accessibility tree (it's a real view, just rendering nothing), so
element-existence assertions can't catch this — only a real pixel
measurement can, same rationale as check_filmstrip_overlap.py.

This measures the "29-filmstrip-thumbs-after-hidesorted-swipe" screenshot:
finds the filmstrip row (reusing check_filmstrip_overlap.py's band/segment
detection), then asserts each thumbnail's interior pixels vary enough to be
real photo content rather than a flat placeholder-gray fill.

Screenshots are 1170x2532 (iPhone 14 class @3x). pt = px/3.

Usage: check_filmstrip_content.py <screenshot.png>
Exit 0 on PASS, 1 on FAIL (including "filmstrip not found").
"""
import sys
from collections import Counter

from PIL import Image

# A cell filled only with FilmstripThumbnail's placeholder
# (RoundedRectangle.fill(Color(white: 0.15))) has essentially zero pixel
# variance — every interior pixel is the same near-black gray. Real photo
# content, even a dim or low-contrast source, varies well above this.
# Measured against the placeholder's exact RGB (38, 38, 38 @ 8-bit): stddev
# of a solid fill is 0 up to sampling/compression noise, so this threshold
# has wide margin without risking false positives on a genuinely low-
# contrast photo.
MIN_STDDEV = 4.0


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
            return band_top, band_bottom, segs
        y = band_bottom + 1
    return None


def stddev(values):
    n = len(values)
    if n == 0:
        return 0.0
    mean = sum(values) / n
    return (sum((v - mean) ** 2 for v in values) / n) ** 0.5


def cell_stddev(px, x0, x1, y0, y1, margin=3):
    """Grayscale stddev over a cell's interior, inset from its edges to
    avoid the white current-photo stroke and the rounded-corner border
    pixels (both of which vary regardless of what's inside)."""
    samples = []
    for x in range(x0 + margin, x1 - margin, 2):
        for y in range(y0 + margin, y1 - margin, 2):
            r, g, b = px[x, y]
            samples.append((r + g + b) / 3)
    return stddev(samples)


def main():
    if len(sys.argv) != 2:
        print(f"Usage: {sys.argv[0]} <screenshot.png>")
        return 2
    path = sys.argv[1]

    im, px, (w, h) = load(path)
    bg = bg_color(px, w, h)

    fs = find_filmstrip(px, w, h, bg, below_y=int(h * 0.4))
    if fs is None:
        print(f"FAIL: could not find the filmstrip row in {path} (image {w}x{h}, bg={bg})")
        return 1

    fb_top, fb_bottom, segs = fs
    print(f"Filmstrip row: y=[{fb_top},{fb_bottom}] ({len(segs)} thumbnails found)")

    blanks = []
    for i, (x0, x1) in enumerate(segs):
        sd = cell_stddev(px, x0, x1, fb_top, fb_bottom)
        print(f"  thumb[{i}] x=[{x0},{x1}] stddev={sd:.2f}")
        if sd < MIN_STDDEV:
            blanks.append(i)

    if blanks:
        print(f"FAIL: thumbnail(s) {blanks} look flat/blank (stddev < {MIN_STDDEV}) — "
              f"likely the .id(index) identity bug resetting @State image to nil")
        return 1

    print("PASS: all filmstrip thumbnails contain varied (non-blank) pixel content")
    return 0


if __name__ == "__main__":
    sys.exit(main())
