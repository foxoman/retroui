#!/usr/bin/env python3
"""Draws BMI Studio's app icon: a rounded tile in the banner's pale blue, a
red heart with its heartbeat line across it. Writes
examples/assets/bmi-icon.png (192 x 192, the launcher's) and
bmi-icon-512.png (for stores, docs, desktops).

    python3 tools/genbmiicon.py
"""

import os
from PIL import Image, ImageDraw, ImageFilter

HERE = os.path.dirname(os.path.abspath(__file__))
ASSETS = os.path.join(HERE, '..', 'examples', 'assets')
S = 4                      # drawn four times as big, then made smaller: soft edges


def icon(n):
    w = n * S
    im = Image.new('RGBA', (w, w), (0, 0, 0, 0))
    d = ImageDraw.Draw(im)
    r = w * 0.2
    # the tile: its shadow, its face lighter at the top
    sh = Image.new('RGBA', (w, w), (0, 0, 0, 0))
    ImageDraw.Draw(sh).rounded_rectangle((w * 0.06, w * 0.09, w * 0.94, w * 0.97), r, fill=(10, 30, 80, 110))
    im.alpha_composite(sh.filter(ImageFilter.GaussianBlur(w * 0.02)))
    d.rounded_rectangle((w * 0.05, w * 0.05, w * 0.95, w * 0.95), r, fill=(88, 128, 196))
    d.rounded_rectangle((w * 0.07, w * 0.07, w * 0.93, w * 0.93), r * 0.9, fill=(184, 211, 240))
    top = Image.new('RGBA', (w, w), (0, 0, 0, 0))
    ImageDraw.Draw(top).rounded_rectangle((w * 0.07, w * 0.07, w * 0.93, w * 0.42), r * 0.9, fill=(222, 236, 252, 170))
    im.alpha_composite(top)
    d = ImageDraw.Draw(im)
    # the heart: two discs and a triangle, an edge round it
    cx, cy, s = w * 0.5, w * 0.5, w * 0.62
    for k, c in ((1.0, (150, 24, 44)), (0.9, (232, 62, 82))):
        rr = s * 0.27 * k
        for sx in (-1, 1):
            d.ellipse((cx + sx * s * 0.22 - rr, cy - s * 0.12 - rr, cx + sx * s * 0.22 + rr, cy - s * 0.12 + rr), fill=c)
        d.polygon([(cx - s * 0.48 * k, cy - s * 0.04), (cx + s * 0.48 * k, cy - s * 0.04), (cx, cy + s * 0.46 * k)], fill=c)
    # the heartbeat
    pts = [(-0.40, 0.02), (-0.16, 0.02), (-0.08, -0.16), (0.02, 0.22), (0.12, -0.06), (0.18, 0.02), (0.40, 0.02)]
    d.line([(cx + x * s, cy - s * 0.05 + y * s) for x, y in pts], fill=(255, 255, 255), width=int(s * 0.055), joint='curve')
    return im.resize((n, n), Image.LANCZOS)


if __name__ == '__main__':
    icon(192).save(os.path.join(ASSETS, 'bmi-icon.png'), optimize=True)
    icon(512).save(os.path.join(ASSETS, 'bmi-icon-512.png'), optimize=True)
    print('wrote examples/assets/bmi-icon.png and bmi-icon-512.png')
