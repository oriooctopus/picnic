#!/usr/bin/env python3
"""Pixel-level check for the owner's real-device report (A1 in this session's
whole-app review): with "Hide Sorted Pics" ON, swiping a photo left the big
deck card showing the SWIPED photo even though the "N OF M" counter had
already moved on. The root cause (see DeckView.loadCurrentImage's doc
comment) is a real network round trip on a phone with Optimize Storage on —
a gap a simulator's local PhotoKit library can never reproduce, which is
exactly why `--slow-image-loads` (DEBUG-only, see ThumbnailLoader.swift)
exists to stand in for it in CI.

Seeded photos are flat, numbered colour cards (see SeedLibrary.swift) — May's
burst cluster uses a distinct systemColor per asset — so "is the big card
still showing the swiped-away photo" reduces to "does the card's dominant
colour still match what it was BEFORE the swipe." XCUITest accessibility
frames don't carry colour information at all (and this repo's own precedent,
check_filmstrip_overlap.py, is that its reported frames don't even track
real rendered geometry), so this is a real pixel measurement of the
"40-deck-card-before-swipe" and "41-deck-card-immediately-after-swipe"
screenshots, not an element read.

Screenshots are 1170x2532 (iPhone 14 class @3x). pt = px/3.

Usage: check_deck_card_not_frozen.py <before.png> <after_immediate.png>
Exit 0 on PASS, 1 on FAIL.
"""
import sys
from collections import Counter

from PIL import Image

# The card sits roughly in the middle third of the screen, well clear of the
# top bar (title/buttons) and the bottom rows (actions/filmstrip/controls) —
# see DeckView.body's layout. Sampling this generously-inset box means every
# sampled pixel is either the seeded card's flat fill colour or, post-fix,
# whatever legitimately replaced it (a different flat colour, or the card's
# own black background while a fresh fetch is still in flight) — never the
# surrounding chrome.
BOX_X_FRAC = (0.30, 0.70)
BOX_Y_FRAC = (0.30, 0.55)

# Sum of absolute per-channel RGB difference. Distinct systemColor swatches
# (e.g. systemPurple vs systemPink, the two cluster-A members this test
# swipes between) differ by well over 100 on this scale; anti-aliasing noise
# on a flat fill does not.
DOMINANT_COLOR_DIST_THRESH = 60


def dist(c1, c2):
    return sum(abs(a - b) for a, b in zip(c1, c2))


def dominant_color(im_path):
    im = Image.open(im_path).convert("RGB")
    w, h = im.size
    px = im.load()
    x0, x1 = int(w * BOX_X_FRAC[0]), int(w * BOX_X_FRAC[1])
    y0, y1 = int(h * BOX_Y_FRAC[0]), int(h * BOX_Y_FRAC[1])
    # Most-common-color-in-the-box (not mean): the seeded card's number glyph
    # and any anti-aliased edges inside the sample box would otherwise pull a
    # simple average off the true flat fill colour.
    samples = Counter()
    for x in range(x0, x1, 3):
        for y in range(y0, y1, 3):
            samples[px[x, y]] += 1
    return samples.most_common(1)[0][0], (x0, x1, y0, y1)


def main():
    if len(sys.argv) != 3:
        print(f"Usage: {sys.argv[0]} <before.png> <after_immediate.png>")
        return 2
    before_path, after_path = sys.argv[1], sys.argv[2]

    before_color, box = dominant_color(before_path)
    after_color, _ = dominant_color(after_path)

    d = dist(before_color, after_color)
    print(f"Sample box (px): x=[{box[0]},{box[1]}] y=[{box[2]},{box[3]}]")
    print(f"Dominant colour before swipe:          {before_color}")
    print(f"Dominant colour immediately after swipe: {after_color}")
    print(f"Colour distance: {d}")

    if d < DOMINANT_COLOR_DIST_THRESH:
        print(f"FAIL: the big card's dominant colour barely changed ({d} < {DOMINANT_COLOR_DIST_THRESH}) "
              f"immediately after the swipe — the card is still showing the swiped-away photo, "
              f"matching the owner's real-device report")
        return 1

    print(f"PASS: the big card's dominant colour changed immediately after the swipe (distance {d})")
    return 0


if __name__ == "__main__":
    sys.exit(main())
