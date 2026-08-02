# Visual parity rubric — judge every walkthrough capture against this

Derived from the 9 reference screenshots of the real Picnic app
(/home/esme/inbox/2026-08-02-1453*-IMG_138[2-9].png, *-IMG_1390.png).
"Parity" = same elements, same placement, same visual weight; content
(actual photos, counts) obviously differs.

## Global chrome
- Pure black background everywhere (#000 or near), white text.
- Bottom tab bar: floating dark pill (not an edge-to-edge system tab bar),
  3 icons: grid, cards/shuffle glyph, person. Active tab brighter. Red dot
  badge on person icon.
- Top-right cluster on browse screens: streak pill (flame emoji-style icon +
  count, dark circle), gift icon in green circle.

## 1. My Life grid (ref IMG_1382, 1388, 1389)
- Large bold white "My life" top-left.
- Filter (hamburger-ish) circle button left of streak.
- Year section headers ("2025", "2026") large, bold, white.
- 4-column grid of rounded-corner month cards (portrait ~2:3), cover photo
  fills card, bottom-left overlay: month name bold white + below it either
  photo count (grey/white) or "Sorted" in GREEN.
- Long-press month → context menu with exactly "Mark as sorted" (thumbs-up
  icon) / "Mark as unsorted" (circle icon); rest of screen dims/blurs.
- Floating white circular ↑ button bottom-center above tab bar.

## 2. Deck view (ref IMG_1383, 1386)
- Header center: "October 2025" bold + underneath exact "OCT 4, 2025 · 3:25 AM"
  in grey caps.
- Top-left: shuffle circle button. Top-right: X circle button; once ≥1 swipe
  pending, small RED badge with count sits on the X (IMG_1386).
- Card: large rounded-corner photo nearly full-width, stack of next cards
  peeking behind/above it.
- Live Photo indicator: small concentric-circles glyph top-left ON the photo.
- "Compare N >" pill: dark translucent capsule bottom-center ON the photo,
  only when the card belongs to a similar group.
- Under the card: three icon buttons in a row — heart, add-to-stack(+), share
  (paper plane).
- Bottom: undo circle button left, filmstrip of upcoming thumbnails center
  (current highlighted), filter circle button right, "2 OF 56" caps grey
  under the filmstrip.
- Filter popover (IMG_1387): dark rounded sheet anchored bottom-right with
  "Hide:" label, "✓ Sorted pics" row, divider, gear "More settings" row.
- Sorting decrements the position count (56 → 55 after one sort).

## 3. Compare view (ref IMG_1384, 1385)
- Header: "Compare" center bold, layout-toggle icon top-right.
- Full-size rounded photo card, horizontally paged; adjacent cards peek at
  the edges.
- Metadata line under card: BEST photo gets "★ BEST · OCT 4, 2025 ·
  3:25:02 AM · 7.1 MB" with purple/violet star+BEST; others show plain grey
  "OCT 4, 2025 · 3:25:05 AM · 6 MB".
- Below: trash | (divider) | thumbs-up | heart icon row.
- Bottom: X circle bottom-left, thumbnail row of the group center (kept photo
  gets a small GREEN dot under it, IMG_1385), big white check circle
  bottom-right.
- X/check disabled (dim) until ≥1 photo in the group is sorted; enabled
  after (IMG_1385 check is bright white).

## 4. Utilities (ref IMG_1390)
- Large bold "Utilities" top-left; streak + gift top-right.
- "Recents" implied section first: Today / Yesterday / Last 7 days cards with
  counts, each a rounded photo card like month cards.
- "Utilities" section header, then 2-column-ish large cards: Shuffle
  (pixelated cover + dice glyph), Favorites (heart glyph), Screenshots
  (frame glyph), Videos (camera glyph), Photos (photo glyph), Live photos
  (live glyph) — each glyph top-left white on the card, title + count
  bottom-left (count grey, thousands separator "1,123").

## 5. States that must be demonstrated in captures
- X badge appearing after a swipe; gone after undo.
- Compare controls disabled → enabled transition.
- Green dot on kept thumbnail in compare.
- Month card switching count → green "Sorted".
- System delete confirmation dialog on commit (Apple's own sheet).

## Known acceptable deviations (v1 scope, agreed)
- Gift button present but inert; profile tab placeholder; add-to-album
  disabled; no gamification beyond streak count display.
- Fonts: SF system font is fine; Picnic appears to use SF-ish weights anyway.
- Exact glyph art may differ slightly if SF Symbols equivalent used; shape
  and placement must match.
