#!/usr/bin/env python3
"""Pixel-level check for the Compare-view crop bug this session fixes:
ComparePhotoCardView drew its photo with `.aspectRatio(contentMode: .fill)`,
which scales a source photo up to cover the whole card box and crops
whatever doesn't fit — so a photo whose aspect ratio didn't match the
(roughly portrait) Compare box came out visibly zoomed in and cut off, even
though the SAME photo shows uncropped in Deck (PicnicSwipeCard's imageView
is `.scaleAspectFit`, see PicnicSwipeCard.swift:156). The fix
(ComparePhotoCardView.swift's `.aspectRatio(contentMode: .fit)`) shrinks the
photo to fit entirely inside the box instead, leaving dark letterbox bars
above/below a landscape source rather than cropping it.

XCUITest accessibility-tree element frames don't track this repo's real
rendered geometry (established precedent — see check_filmstrip_overlap.py's
doc comment), so this is a pixel question, not an element-frame one.

November's seeded burst cluster C (SeedLibrary.swift) is 3 flat, numbered,
800x600 LANDSCAPE photos, dated earliest in the month so Deck opens on the
cluster (not November's other, later-dated photos) — its first member is the
card test38CompareLandscapePhotoIsNotCropped lands on when it opens Compare,
with nothing yet accepted/rejected (so the accept/reject overlay stroke,
which would otherwise reuse green/red, stays clear). Each seeded item's flat
fill is one of SeedLibrary's palette UIColors (systemRed, systemBrown,
etc — whichever this particular item's index lands on); this script doesn't
care which one, it just finds whatever saturated colour dominates the card
and checks its rendered shape two independent ways:

  1. Aspect ratio: an 800x600 source under `.fit` in a taller-than-wide box
     is width-limited, so the visible band's height/width ratio should be
     ~0.75 (600/800). Under the old `.fill`, the band instead takes on the
     BOX's own (much taller) aspect ratio, well above 1.0.
  2. Letterbox bars: `.fit` leaves the box's own dark fill
     (Color(white: 0.08) ~= RGB(20,20,20)) visible in a band directly above
     AND below the photo. `.fill` covers the box edge-to-edge, so no such
     dark band exists on either side.

Either signal alone catches the regression; both are checked so a fix that
happens to pass one accidentally (e.g. a source/box combination that still
produces a plausible-looking ratio) doesn't slip through.

Screenshots are 1170x2532 (iPhone 14 class @3x). pt = px/3.

Usage: check_compare_letterbox.py <screenshot.png>
Exit 0 on PASS, 1 on FAIL.
"""
import sys
from collections import Counter

from PIL import Image

# Broad net for locating the photo's flat colour: below the "Compare" title/
# icon row, above the caption/button/thumbnail-strip chrome, full width. Wide
# enough to contain the rendered band under EITHER content mode (`.fit`'s
# band sits somewhere inside this range; `.fill`'s band, covering the whole
# box, necessarily does too) without reaching into unrelated UI.
SCAN_Y_FRAC = (0.05, 0.72)

# A seeded palette colour (e.g. systemRed ~ (255,59,48)) is far more
# saturated than anything else on this screen: the box's own fill is flat
# grey (Color(white: 0.08)), the page background is black, and all text/
# icons are white/grey. This threshold separates "a real photo pixel" from
# every other thing in frame.
SATURATION_THRESH = 40

# Sum of absolute per-channel RGB difference for "this pixel is (close
# enough to) the dominant photo colour" / "this pixel is (close enough to)
# the box's dark fill". Generous enough to absorb JPEG blockiness and
# anti-aliased edges without merging genuinely distinct colours.
COLOR_MATCH_THRESH = 45

BOX_FILL_COLOR = (20, 20, 20)

# A row/column counts as "part of the band" once at least this fraction of
# its (sampled) pixels match the dominant colour — low enough that the
# seeded number glyph punching a hole through the middle of a row/column
# doesn't drop it below threshold, high enough that stray matches elsewhere
# in frame can't fake a band on their own.
ROW_COL_MATCH_FRAC = 0.25

# Expected height/width for an 800x600 source under `.fit` in a
# taller-than-wide box is 600/800 = 0.75 exactly; this window absorbs
# rounding from corner clipping and sampling step.
RATIO_MIN, RATIO_MAX = 0.70, 0.80

# How far above/below the measured band to look for the box's dark fill,
# and how much of that probe row may deviate before it counts as "not dark
# enough" — small on purpose: it only needs to land inside the box's own
# gap above/below a `.fit` band, not survive a box-height estimate that
# could be wrong. See module docstring point 2.
DARK_BAR_PROBE_OFFSET_PX = 15
DARK_BAR_MATCH_FRAC = 0.6


def dist(c1, c2):
    return sum(abs(a - b) for a, b in zip(c1, c2))


def find_dominant_photo_color(im, w, h):
    px = im.load()
    y0, y1 = int(h * SCAN_Y_FRAC[0]), int(h * SCAN_Y_FRAC[1])
    samples = Counter()
    for y in range(y0, y1, 3):
        for x in range(0, w, 3):
            r, g, b = px[x, y]
            if max(r, g, b) - min(r, g, b) > SATURATION_THRESH:
                samples[(r, g, b)] += 1
    if not samples:
        return None
    return samples.most_common(1)[0][0]


def matching_row_col_extents(im, w, h, color):
    px = im.load()

    def row_match_frac(y):
        hits = sum(1 for x in range(0, w, 2) if dist(px[x, y], color) < COLOR_MATCH_THRESH)
        return hits / (w / 2)

    def col_match_frac(x, y0, y1):
        total = max(1, (y1 - y0) // 2)
        hits = sum(1 for y in range(y0, y1, 2) if dist(px[x, y], color) < COLOR_MATCH_THRESH)
        return hits / total

    band_rows = [y for y in range(0, h) if row_match_frac(y) >= ROW_COL_MATCH_FRAC]
    if not band_rows:
        return None
    top, bottom = min(band_rows), max(band_rows)

    band_cols = [x for x in range(0, w) if col_match_frac(x, top, bottom) >= ROW_COL_MATCH_FRAC]
    if not band_cols:
        return None
    left, right = min(band_cols), max(band_cols)

    return top, bottom, left, right


def probe_dark_bar(im, w, top, bottom, left, right, offset):
    """Fraction of a horizontal probe row (inset from the band's left/right
    by 10% each side, to stay clear of the box's rounded corners) matching
    the box's dark fill colour."""
    px = im.load()
    y = top - offset if top - offset >= 0 else None
    above = None
    if y is not None:
        x0, x1 = left + int((right - left) * 0.1), right - int((right - left) * 0.1)
        hits = sum(1 for x in range(x0, x1, 2) if dist(px[x, y], BOX_FILL_COLOR) < COLOR_MATCH_THRESH)
        above = hits / max(1, (x1 - x0) // 2)

    y = bottom + offset
    below = None
    if y < im.size[1]:
        x0, x1 = left + int((right - left) * 0.1), right - int((right - left) * 0.1)
        hits = sum(1 for x in range(x0, x1, 2) if dist(px[x, y], BOX_FILL_COLOR) < COLOR_MATCH_THRESH)
        below = hits / max(1, (x1 - x0) // 2)

    return above, below


def main():
    if len(sys.argv) != 2:
        print(f"Usage: {sys.argv[0]} <screenshot.png>")
        return 2

    im = Image.open(sys.argv[1]).convert("RGB")
    w, h = im.size
    print(f"Image size: {w}x{h}")

    color = find_dominant_photo_color(im, w, h)
    if color is None:
        print("FAIL: no saturated (photo-like) colour found in the Compare card region — "
              "the card may not have loaded an image at all")
        return 1
    print(f"Dominant photo colour: {color}")

    extents = matching_row_col_extents(im, w, h, color)
    if extents is None:
        print("FAIL: couldn't establish the rendered photo band's extents from the dominant colour")
        return 1
    top, bottom, left, right = extents
    band_h, band_w = bottom - top, right - left
    ratio = band_h / band_w if band_w else float("inf")
    print(f"Band bounds (px): top={top} bottom={bottom} left={left} right={right}")
    print(f"Band size (px): width={band_w} height={band_h}")
    print(f"Height/width ratio: {ratio:.3f} (expect {RATIO_MIN}-{RATIO_MAX} for an 800x600 source under .fit)")

    above_frac, below_frac = probe_dark_bar(im, w, top, bottom, left, right, DARK_BAR_PROBE_OFFSET_PX)
    print(f"Dark-fill match fraction directly above band: {above_frac}")
    print(f"Dark-fill match fraction directly below band: {below_frac}")

    ratio_ok = RATIO_MIN <= ratio <= RATIO_MAX
    bars_ok = (
        above_frac is not None and above_frac >= DARK_BAR_MATCH_FRAC
        and below_frac is not None and below_frac >= DARK_BAR_MATCH_FRAC
    )

    if not ratio_ok:
        print(f"FAIL: band height/width ratio {ratio:.3f} is outside [{RATIO_MIN}, {RATIO_MAX}] — "
              f"the photo does not look aspect-fit; a .fill crop stretches the band toward the box's "
              f"own (much taller) aspect ratio instead")
    if not bars_ok:
        print("FAIL: no dark letterbox bar found directly above and below the photo band — "
              "with .fit, the box's own dark fill (~RGB(20,20,20)) should show there; its absence "
              "means the photo is covering the box edge-to-edge, i.e. cropped (.fill)")

    if not (ratio_ok and bars_ok):
        return 1

    print(f"PASS: band is aspect-fit (ratio {ratio:.3f}) with letterbox bars above and below")
    return 0


if __name__ == "__main__":
    sys.exit(main())
