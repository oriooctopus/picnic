#!/usr/bin/env python3
"""Pixel-level check for the owner's real-device report: "when I unhide
sorted pics it currently has the bar at the beginning, but it should
actually keep the bar where it was."

Root cause (see FilmstripView's `scrollAnchor` / `.onChange(of:
scrollAnchor)` doc comments): toggling hideSorted OFF deliberately keeps the
deck on the SAME photo (DeckViewModel.reanchorCurrentIndex), so the OLD
onChange — keyed on the current asset's IDENTITY alone — never fired even
though every previously-hidden sorted photo was re-inserted around the
current one, most of them BEFORE it. The stale scroll offset survived that
re-composition, so the strip visibly snapped toward its leading edge instead
of staying centered on the current photo.

Same "assert on real pixels, not the accessibility tree" rule as every other
filmstrip check here (see check_filmstrip_overlap.py's doc comment for why):
this locates the CURRENT cell by its white `strokeBorder`
(FilmstripThumbnail's `.overlay`, ~2pt/~6px @3x) and measures its rendered
x-position against the filmstrip viewport's horizontal center — the image
center, since FilmstripView's ScrollView spans the full screen width (no
extra outer padding at the DeckView call site; the 12pt inset baked into the
content is what centers a short strip's cell in the narrow-content case, and
matters at the ScrollView's un-narrow edges when the current cell's own
positioning is what's being measured here).

White-border detection was validated against real screenshots pulled from
CI run 31822841184 (visual-walk, build branch, 2026-08-14) before this
script was written: across six real screenshots (21/29/30/40/41/99-final),
every one showed exactly one segment with >=80% near-white pixels at BOTH
its left and right edge columns (the current cell), while every OTHER
segment read exactly 0.00 at both edges despite some of those segments'
INTERIOR columns reading up to 0.25 (the seeded photos draw bold white index
numbers — SeedLibrary.makeImage/makeNoisyImage — which land in the middle of
a cell, never at its edges). That's why this only samples each segment's own
edge columns, never its interior, and requires BOTH edges to clear the
threshold rather than either alone.

WHY ONLY THE "AFTER" SHOT IS ASSERTED CENTERED, NOT BOTH: hideSorted is
turned on BEFORE swiping (matching the owner's actual workflow — turn it on,
then keep sorting), so under hideSorted every predecessor of the current
photo in the FILTERED list is, by construction, exactly what was just
swiped away (advance() never fires while hideSorted is on — see
DeckViewModel.markKept/markForDelete's own comments — so the current photo
is always whatever slides into the filtered list's leading slot). That makes
the "before" shot's current cell sit at the filtered strip's leading edge
NO MATTER HOW THE SCROLL-FOLLOW CODE IS WRITTEN — confirmed empirically
against a real "before"-shaped screenshot (30-filmstrip-before-scale-swipes,
also from run 31822841184: 5 sequential hideSorted-on swipes from a fresh
month put the current cell at the very first segment, x=[36,107] of a
1170px-wide image). Asserting "centered" there would fail even on
genuinely-fixed code, which is exactly the kind of broken criterion this
repo's own precedent (see check_filmstrip_visually_updated.py's
CENTER_MIN_CHANGED_FRACTION doc comment) argues against shipping. The real
regression — and the only place "did the strip actually re-center" is a
meaningful question — is the "after" shot: once hideSorted is off, both the
swiped-away predecessors AND the never-touched successors are back in the
strip, giving the current photo real room on both sides.

The "before" shot's current cell is still located and measured (logged, not
asserted on beyond "found exactly one") — useful context for reading a
failure, and it re-uses the same "found exactly one" loud-failure path so a
detector regression there is caught too.

Screenshots are 1170x2532 (iPhone 14 class @3x). pt = px/3.

Usage: check_filmstrip_current_cell_recentered.py <before.png> <after.png>
Exit 0 on PASS, 1 on FAIL (including "filmstrip not found" and "could not
find exactly one current cell").
"""
import sys
from collections import Counter

from PIL import Image

# How much of the after-shot's current cell can sit off the viewport's
# horizontal center and still count as "recentered", as a fraction of the
# image width. A genuinely re-centered cell (proxy.scrollTo(id, anchor:
# .center), unclamped — this test seeds 12 predecessor cells and ~276
# successor cells specifically so nothing clamps it) should land close to
# dead center; the bug this chases instead leaves the pre-unhide scroll
# offset in place, which check_filmstrip_visually_updated.py's real "before"
# baseline (run 31822841184) shows pins the cell at the image's leading
# edge — a difference of roughly half the image width, not a few percent.
MAX_CENTER_OFFSET_FRAC = 0.15

WHITE = (255, 255, 255)
# Sum-of-abs-diff across R,G,B. The strokeBorder is drawn at full white;
# validated against real screenshots (see module doc comment): at this
# threshold every non-current segment's edge columns read a white fraction
# of 0.00 (dist(bg or cell color, white) is always >> 60 for this app's
# palette — see SeedLibrary's systemRed/orange/yellow/green/teal/blue/
# indigo/purple/pink/brown, none of which are pale enough to false-positive
# here), while the real border read comfortably under 60 across its whole
# ~6px width. Raising this past ~70 starts letting systemYellow-toned cell
# fill through as a false "white edge" — confirmed by re-running this
# script's own detector at threshold 80 against real screenshots and seeing
# extra segments falsely match; keep this at the validated value, don't
# raise it without re-validating against real screenshots.
WHITE_DIST_THRESH = 60
# Fraction of a segment's edge column (sampled top-to-bottom, inset by
# `margin` to skip the rounded-corner softening) that must read near-white
# for that edge to count as bordered. Real current cells measured 0.81-0.83;
# real non-current cells measured 0.00-0.15 (the 0.15 case was a photo's
# white index-number digit bleeding into a segment's outer few px, still far
# below this). 0.5 sits with wide margin on both sides.
MIN_EDGE_WHITE_FRAC = 0.5


def dist(c1, c2):
    return sum(abs(a - b) for a, b in zip(c1, c2))


def load(path):
    im = Image.open(path).convert("RGB")
    return im, im.load(), im.size


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


def col_white_frac(px, x, y0, y1, margin=6):
    """Fraction of near-white pixels in column `x`, sampled between y0+margin
    and y1-margin — inset to skip the rounded-corner softening at the very
    top/bottom of the band, same rationale as check_filmstrip_content.py's
    `cell_stddev` margin."""
    n = 0
    white = 0
    for y in range(y0 + margin, y1 - margin + 1):
        n += 1
        if dist(px[x, y], WHITE) < WHITE_DIST_THRESH:
            white += 1
    return white / n if n else 0.0


def find_current_cell(px, top, bottom, segs, label):
    """Returns (index, x0, x1) of the segment whose left AND right edge
    columns both read as the white strokeBorder, or None with a printed
    diagnostic if that isn't exactly one segment."""
    matches = []
    for i, (x0, x1) in enumerate(segs):
        left = col_white_frac(px, x0 + 2, top, bottom)
        right = col_white_frac(px, x1 - 2, top, bottom)
        print(f"  [{label}] seg[{i}] x=[{x0},{x1}] left_white={left:.2f} right_white={right:.2f}")
        if left >= MIN_EDGE_WHITE_FRAC and right >= MIN_EDGE_WHITE_FRAC:
            matches.append(i)
    if len(matches) != 1:
        print(f"FAIL: expected exactly one current (white-bordered) cell in {label}, found {len(matches)} {matches}")
        return None
    i = matches[0]
    x0, x1 = segs[i]
    return i, x0, x1


def measure(path, label):
    im, px, (w, h) = load(path)
    bg = bg_color(px, w, h)
    fs = find_filmstrip(px, w, h, bg, below_y=int(h * 0.4))
    if fs is None:
        print(f"FAIL: could not find the filmstrip row in {path} (image {w}x{h}, bg={bg})")
        return None
    top, bottom, segs = fs
    print(f"[{label}] filmstrip band y=[{top},{bottom}] ({len(segs)} thumbnails found), image width={w}")
    current = find_current_cell(px, top, bottom, segs, label)
    if current is None:
        return None
    idx, x0, x1 = current
    center = (x0 + x1) / 2
    viewport_center = w / 2
    diff = abs(center - viewport_center)
    diff_frac = diff / w
    print(f"[{label}] current cell = seg[{idx}] x=[{x0},{x1}] center={center:.1f}, "
          f"viewport center={viewport_center:.1f}, offset={diff:.1f}px ({diff_frac:.1%} of width)")
    return diff_frac


def main():
    if len(sys.argv) != 3:
        print(f"Usage: {sys.argv[0]} <before.png> <after.png>")
        return 2
    before_path, after_path = sys.argv[1], sys.argv[2]

    before_diff_frac = measure(before_path, "before-unhide")
    if before_diff_frac is None:
        return 1

    after_diff_frac = measure(after_path, "after-unhide")
    if after_diff_frac is None:
        return 1

    # See the module doc comment: only the after-unhide shot is asserted on.
    # The before shot's current cell is legitimately pinned at the filtered
    # strip's leading edge by construction (nothing precedes it there once
    # hideSorted has filtered out everything already swiped) — that's not
    # the bug, so it's measured above for context but not gated here.
    if after_diff_frac > MAX_CENTER_OFFSET_FRAC:
        print(f"FAIL: after unhiding, the current photo's cell sits {after_diff_frac:.1%} of the image width "
              f"off the viewport center (max allowed {MAX_CENTER_OFFSET_FRAC:.0%}) — matching the owner's "
              f"real-device report that the bar snaps toward the beginning instead of staying on the current photo")
        return 1

    print(f"PASS: current photo's cell re-centered after unhide "
          f"(before={before_diff_frac:.1%}, after={after_diff_frac:.1%} of image width off-center)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
