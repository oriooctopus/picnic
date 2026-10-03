#!/usr/bin/env python3
"""Pixel check for test52DeckLogOutfitFillsButtonAndPersists.

Counts lilac (#c9a2ff, the outfit accent) pixels in two bands of the 3 screenshots:
  - action row band (hanger button): 0 before the tap, filled after the tap, and
    still filled after relaunch.
  - top band (toast): lilac "Review now" text + border present right after the
    tap, absent before the tap and after relaunch.
Seed photos are flat systemColors, none within tolerance of lilac.

Usage: check_outfit_button.py <before.png> <after.png> <relaunch.png>
Exit 0 PASS, 1 FAIL.
"""
import sys

from PIL import Image

LILAC = (201, 162, 255)
TOL = 40
ROW_BAND = (0.15, 0.85, 0.66, 0.90)   # x0, x1, y0, y1 fractions: action row + filmstrip margin
TOAST_BAND = (0.05, 0.95, 0.05, 0.25)
MIN_ROW_PIXELS = 300
MIN_TOAST_PIXELS = 150


def count(path, band):
    im = Image.open(path).convert("RGB")
    w, h = im.size
    x0, x1, y0, y1 = band
    px = im.load()
    n = 0
    for y in range(int(h * y0), int(h * y1)):
        for x in range(int(w * x0), int(w * x1)):
            if sum(abs(a - b) for a, b in zip(px[x, y], LILAC)) < TOL:
                n += 1
    return n


def main():
    before, after, relaunch = sys.argv[1:4]
    r = [count(p, ROW_BAND) for p in (before, after, relaunch)]
    t = [count(p, TOAST_BAND) for p in (before, after, relaunch)]
    print(f"lilac px in action-row band  before/after/relaunch: {r}")
    print(f"lilac px in toast band       before/after/relaunch: {t}")
    ok = True
    if r[0] >= MIN_ROW_PIXELS:
        print("FAIL: button already lilac before tap"); ok = False
    if r[1] < MIN_ROW_PIXELS:
        print("FAIL: button not lilac after tap"); ok = False
    if r[2] < MIN_ROW_PIXELS:
        print("FAIL: button not lilac after relaunch (persistence)"); ok = False
    if t[0] >= MIN_TOAST_PIXELS:
        print("FAIL: toast present before tap"); ok = False
    if t[1] < MIN_TOAST_PIXELS:
        print("FAIL: toast missing after tap"); ok = False
    if t[2] >= MIN_TOAST_PIXELS:
        print("FAIL: toast present after relaunch"); ok = False
    print("PASS" if ok else "FAIL")
    return 0 if ok else 1


sys.exit(main())
