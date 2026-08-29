#!/usr/bin/env python3
"""Pixel-level check for the bug this session fixes: tapping the Compare
pill on the deck opened Compare on the group's FIRST photo, even when the
deck card under the pill was the second (or later) member. The fix
(DeckPresentation.compare now carries the tapped card's asset id;
CompareView.init(startAssetID:) seeds pageIndex from it, see
app/Picnic/Views/Deck/DeckView.swift and
app/Picnic/Views/Compare/CompareView.swift) is proven here.

November's seeded burst cluster C (SeedLibrary.swift) is three flat, DISTINCT
numbered colours (systemBrown, systemRed, systemOrange for seed idx
19/20/21) with Deck opening on member 0 (brown) — see
test39CompareOpensOnTappedPhoto's doc comment for why this cluster survives
to that point in a full-suite run. The test swipes right twice (keep) to
advance the deck to member 2 (orange) — the group stays unresolved, so the
Compare pill still points at it — then opens Compare from there.

Three screenshots, same technique as this repo's other start/identity
checks:
  43-deck-first-member  — deck card showing member 0 (brown), before the
                           swipe. Sampled the same way as
                           check_deck_card_not_frozen.py: most-common colour
                           in the card's central inset box.
  44-deck-tapped-member — deck card showing member 2 (orange), after two keep-swipes.
                           Same box.
  45-compare-opened-on-tapped-member — Compare, opened from member 2's card.
                           Sampled the same way as check_compare_letterbox.py:
                           most-common SATURATED colour in the photo band.

Three assertions:
  (a) dom(43) != dom(44) — the swipe actually advanced the deck. Without
      this, a swipe that silently failed to register would make the test
      vacuous: 45 would trivially equal 43 no matter what CompareView does,
      since the deck never moved off member 0 in the first place.
  (b) dom(45) == dom(44) — Compare opened on the SAME photo the deck was
      showing when the pill was tapped (member 2, orange — neither the group's first nor its BEST). This is the actual
      fix.
  (c) dom(45) != dom(43) — Compare did NOT fall back to the group's first
      photo (member 0, brown). Belt-and-suspenders with (b): a bug that
      opened Compare on some OTHER wrong index (not 0, not the tapped one)
      would fail (b) but could accidentally still pass a bare
      "not member 0" check on its own — checking both makes the assertion
      about the ONE right answer, not merely about avoiding the one known
      wrong answer.

With the bug reinstated (CompareView seeding pageIndex 0 unconditionally),
Compare opens on member 0 regardless of which card the pill was tapped from,
so dom(45) == dom(43) and dom(45) != dom(44) — this script fails on (b)
and (c) while (a) still passes (the deck itself still advances correctly;
only Compare's start index is wrong).

Screenshots are 1170x2532 (iPhone 14 class @3x). pt = px/3.

Usage: check_compare_start_index.py <43-deck-first-member.png>
                                     <44-deck-tapped-member.png>
                                     <45-compare-opened-on-tapped-member.png>
Exit 0 on PASS, 1 on FAIL.
"""
import sys
from collections import Counter

from PIL import Image

# Deck-card sample box: same as check_deck_card_not_frozen.py — the card
# sits roughly in the middle third of the screen, well clear of the top bar
# and bottom rows (actions/filmstrip/controls).
DECK_BOX_X_FRAC = (0.30, 0.70)
DECK_BOX_Y_FRAC = (0.30, 0.55)

# Compare-card sample band: same as check_compare_letterbox.py — below the
# "Compare" title row, above the caption/button/thumbnail-strip chrome, full
# width.
COMPARE_SCAN_Y_FRAC = (0.05, 0.72)

# A seeded palette colour (systemBrown/systemRed/systemOrange here) is far
# more saturated than anything else on the Compare screen (dark box fill,
# black background, white/grey text/icons) — this threshold separates "a
# real photo pixel" from everything else in frame. Same value as
# check_compare_letterbox.py.
SATURATION_THRESH = 40

# Sum of absolute per-channel RGB difference. Distinct systemColor swatches
# differ by well over 100 on this scale; anti-aliasing noise on a flat fill
# does not. Same threshold as check_deck_card_not_frozen.py.
DOMINANT_COLOR_DIST_THRESH = 60


def dist(c1, c2):
    return sum(abs(a - b) for a, b in zip(c1, c2))


def deck_card_dominant_color(im_path):
    """Most-common colour in the deck card's central inset box."""
    im = Image.open(im_path).convert("RGB")
    w, h = im.size
    px = im.load()
    x0, x1 = int(w * DECK_BOX_X_FRAC[0]), int(w * DECK_BOX_X_FRAC[1])
    y0, y1 = int(h * DECK_BOX_Y_FRAC[0]), int(h * DECK_BOX_Y_FRAC[1])
    samples = Counter()
    for x in range(x0, x1, 3):
        for y in range(y0, y1, 3):
            samples[px[x, y]] += 1
    return samples.most_common(1)[0][0]


def compare_dominant_photo_color(im_path):
    """Most-common SATURATED colour in Compare's photo band."""
    im = Image.open(im_path).convert("RGB")
    w, h = im.size
    px = im.load()
    y0, y1 = int(h * COMPARE_SCAN_Y_FRAC[0]), int(h * COMPARE_SCAN_Y_FRAC[1])
    samples = Counter()
    for y in range(y0, y1, 3):
        for x in range(0, w, 3):
            r, g, b = px[x, y]
            if max(r, g, b) - min(r, g, b) > SATURATION_THRESH:
                samples[(r, g, b)] += 1
    if not samples:
        return None
    return samples.most_common(1)[0][0]


def main():
    if len(sys.argv) != 4:
        print(f"Usage: {sys.argv[0]} <43-deck-first-member.png> "
              f"<44-deck-tapped-member.png> <45-compare-opened-on-tapped-member.png>")
        return 2
    first_path, second_path, compare_path = sys.argv[1], sys.argv[2], sys.argv[3]

    first_color = deck_card_dominant_color(first_path)
    second_color = deck_card_dominant_color(second_path)
    compare_color = compare_dominant_photo_color(compare_path)

    print(f"Deck card, member 0 (before swipe, expect brown):  {first_color}")
    print(f"Deck card, member 1 (after swipe, expect red):     {second_color}")
    if compare_color is None:
        print("FAIL: no saturated (photo-like) colour found in the Compare card region — "
              "the card may not have loaded an image at all")
        return 1
    print(f"Compare card, opened from member 1's pill:         {compare_color}")

    swipe_advanced_dist = dist(first_color, second_color)
    compare_vs_second_dist = dist(compare_color, second_color)
    compare_vs_first_dist = dist(compare_color, first_color)
    print(f"Distance member0 vs member1 (swipe advanced?):     {swipe_advanced_dist}")
    print(f"Distance compare vs member1 (opened on tapped?):   {compare_vs_second_dist}")
    print(f"Distance compare vs member0 (avoided group-first?): {compare_vs_first_dist}")

    swipe_advanced = swipe_advanced_dist >= DOMINANT_COLOR_DIST_THRESH
    opened_on_tapped = compare_vs_second_dist < DOMINANT_COLOR_DIST_THRESH
    avoided_group_first = compare_vs_first_dist >= DOMINANT_COLOR_DIST_THRESH

    if not swipe_advanced:
        print(f"FAIL: the deck card's dominant colour barely changed after the swipe "
              f"({swipe_advanced_dist} < {DOMINANT_COLOR_DIST_THRESH}) — the swipe never advanced "
              f"the deck from member 0 to member 1, so this test proves nothing about Compare's "
              f"start index")
    if not opened_on_tapped:
        print(f"FAIL: Compare's dominant photo colour does not match the deck card it was opened "
              f"from (member 1, distance {compare_vs_second_dist} >= {DOMINANT_COLOR_DIST_THRESH}) "
              f"— Compare did not open on the tapped photo")
    if not avoided_group_first:
        print(f"FAIL: Compare's dominant photo colour matches the group's FIRST member (member 0, "
              f"distance {compare_vs_first_dist} < {DOMINANT_COLOR_DIST_THRESH}) instead of the "
              f"tapped one — this is exactly the bug this session fixes: Compare opened on the "
              f"group's first photo regardless of which card the pill was tapped from")

    if not (swipe_advanced and opened_on_tapped and avoided_group_first):
        return 1

    print("PASS: Compare opened on the photo it was tapped from, not the group's first")
    return 0


if __name__ == "__main__":
    sys.exit(main())
