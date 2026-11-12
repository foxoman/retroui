#!/usr/bin/env python3
"""Draws Retro Navigator's app icon: a modern rounded tile holding 1994 pixel
art -- a planet with a ring in the night, a comet going round it, stars --
the logo the browser draws at the right of its tool bar. Writes
examples/assets/navigator-icon.png (192 x 192, the launcher's and the
window's) and navigator-icon-512.png (for stores, docs, desktops).

    python3 tools/gennavigatoricon.py

Developed by Sultan Al Isaiee @foxoman -- www.foxoman.net -- sultan@foxoman.net
"""

import math
import os
from PIL import Image, ImageDraw, ImageFilter

HERE = os.path.dirname(os.path.abspath(__file__))
ASSETS = os.path.join(HERE, '..', 'examples', 'assets')

NIGHT, PLANET, LIGHT, RING = (0, 0, 48), (0, 128, 192), (127, 212, 255), (255, 208, 64)
STAR, COMET = (200, 210, 255), (255, 236, 140)


def pixel_art():
    """The logo, 32 x 32 pixels (drawn 1:1, scaled up whole)."""
    n = 32
    im = Image.new('RGBA', (n, n), NIGHT + (255,))
    d = ImageDraw.Draw(im)
    for (x, y) in [(4, 5), (26, 4), (9, 27), (28, 23), (18, 3), (3, 19), (22, 28), (13, 9)]:
        d.point((x, y), STAR + (255,))
    d.ellipse((9, 9, 23, 23), PLANET + (255,))
    d.ellipse((12, 11, 17, 16), LIGHT + (255,))
    d.line((4, 21, 28, 12), RING + (255,), 1)
    d.line((4, 22, 28, 13), RING + (255,), 1)
    # the comet at the top right, its tail behind it
    a = -math.pi / 4
    for k, fade in [(3, 90), (2, 145), (1, 200)]:
        b = a - 0.22 * k
        d.point((16 + round(math.cos(b) * 12), 16 + round(math.sin(b) * 11.5)), (fade, fade, 160, 255))
    cx, cy = 16 + round(math.cos(a) * 12), 16 + round(math.sin(a) * 11.5)
    d.rectangle((cx - 1, cy - 1, cx + 1, cy + 1), COMET + (255,))
    return im


def tile(size):
    """The rounded tile with the art in it, `size` pixels square."""
    out = Image.new('RGBA', (size, size), (0, 0, 0, 0))
    pad = size // 16
    r = size // 5
    shadow = Image.new('RGBA', (size, size), (0, 0, 0, 0))
    ImageDraw.Draw(shadow).rounded_rectangle((pad, pad + size // 40, size - pad, size - pad + size // 40),
                                             r, (0, 0, 0, 110))
    out = Image.alpha_composite(out, shadow.filter(ImageFilter.GaussianBlur(size / 60)))
    face = Image.new('RGBA', (size, size), (0, 0, 0, 0))
    ImageDraw.Draw(face).rounded_rectangle((pad, pad, size - pad, size - pad), r, (232, 232, 236, 255))
    out = Image.alpha_composite(out, face)
    art = pixel_art()
    inner = size - 2 * pad - size // 8
    scale = inner // art.width
    big = art.resize((art.width * scale, art.height * scale), Image.NEAREST)
    frame = Image.new('RGBA', (big.width + 2 * max(1, scale // 2), big.height + 2 * max(1, scale // 2)),
                      (0, 0, 0, 255))
    frame.paste(big, (max(1, scale // 2), max(1, scale // 2)))
    out.alpha_composite(frame, ((size - frame.width) // 2, (size - frame.height) // 2))
    return out


if __name__ == '__main__':
    tile(192).save(os.path.join(ASSETS, 'navigator-icon.png'))
    tile(512).save(os.path.join(ASSETS, 'navigator-icon-512.png'))
    print('examples/assets/navigator-icon.png, navigator-icon-512.png')
