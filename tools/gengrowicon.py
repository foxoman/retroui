#!/usr/bin/env python3
"""Draws Grow's app icon: a modern rounded tile (soft light, a shadow)
holding 1994 pixel art -- three bars rising, the last one green (the goal
reached), and a gold coin over it. Writes examples/assets/grow-icon.png
(192 x 192, the launcher's) and grow-icon-512.png (for stores, docs,
desktops).

    python3 tools/gengrowicon.py
"""

import os
from PIL import Image, ImageDraw, ImageFilter

HERE = os.path.dirname(os.path.abspath(__file__))
ASSETS = os.path.join(HERE, '..', 'examples', 'assets')

BLACK, SILVER, GRAY, WHITE = (0, 0, 0), (192, 192, 192), (128, 128, 128), (255, 255, 255)
BLUE, LBLUE, DBLUE = (66, 120, 235), (140, 180, 255), (30, 60, 150)
GREEN, LGREEN, DGREEN = (32, 190, 120), (120, 235, 170), (10, 110, 70)
GOLD, LGOLD, DGOLD = (255, 196, 60), (255, 236, 150), (190, 120, 10)


def pixel_art():
    """The bars on their floor and the coin, 40 x 36 pixels (drawn 1:1,
    scaled up whole)."""
    W, H = 40, 36
    im = Image.new('RGBA', (W, H), (0, 0, 0, 0))
    px = im.load()

    def put(x, y, c):
        if 0 <= x < W and 0 <= y < H:
            px[x, y] = c + (255,)

    def rect(x0, y0, x1, y1, c):
        for y in range(y0, y1 + 1):
            for x in range(x0, x1 + 1):
                put(x, y, c)

    def bar(x0, top, face, light, dark):
        # a bar with a black line round it, lit on its left, shaded on its right
        x1, bottom = x0 + 8, 31
        rect(x0, top, x1, bottom, BLACK)
        rect(x0 + 1, top + 1, x1 - 1, bottom - 1, face)
        rect(x0 + 1, top + 1, x0 + 1, bottom - 1, light)
        rect(x0 + 1, top + 1, x1 - 1, top + 1, light)
        rect(x1 - 2, top + 2, x1 - 1, bottom - 1, dark)

    bar(4, 22, BLUE, LBLUE, DBLUE)
    bar(15, 16, BLUE, LBLUE, DBLUE)
    bar(26, 13, GREEN, LGREEN, DGREEN)
    # the floor
    rect(1, 32, 38, 33, BLACK)
    rect(2, 32, 37, 32, GRAY)
    # the coin over the green bar: a gold disc, black round it, light on
    # its upper left, its rim darker on the lower right
    cx, cy, r = 30, 6, 4
    for y in range(cy - r - 1, cy + r + 2):
        for x in range(cx - r - 1, cx + r + 2):
            d = (x - cx) ** 2 + (y - cy) ** 2
            if d <= r * r:
                put(x, y, DGOLD if (x - cx) + (y - cy) >= 4 else GOLD)
            elif d <= (r + 1) * (r + 1):
                put(x, y, BLACK)
    for (x, y) in ((cx - 2, cy - 2), (cx - 1, cy - 3), (cx - 3, cy - 1)):
        put(x, y, LGOLD)
    rect(cx, cy - 2, cx, cy + 2, DGOLD)
    # an arrow going up, at the left: growing
    for i in range(6):
        put(6 + i, 14 - i, WHITE)
        put(6 + i, 15 - i, WHITE)
    rect(9, 8, 12, 8, WHITE)
    rect(12, 8, 12, 11, WHITE)
    return im


def icon(size):
    S = 4                       # (the smooth parts drawn bigger, then made smaller: soft edges)
    big = size * S
    canvas = Image.new('RGBA', (big, big), (0, 0, 0, 0))
    inset = int(big * 0.045)
    rad = int(big * 0.22)
    box = (inset, inset, big - inset, big - inset)
    # the shadow
    sh = Image.new('RGBA', (big, big), (0, 0, 0, 0))
    ImageDraw.Draw(sh).rounded_rectangle((box[0], box[1] + big // 40, box[2], box[3] + big // 40), rad,
                                         fill=(0, 10, 30, 120))
    sh = sh.filter(ImageFilter.GaussianBlur(big / 70))
    canvas.alpha_composite(sh)
    # the tile: a violet into a deep teal, light from the top
    grad = Image.new('RGBA', (big, big))
    gp = grad.load()
    top, mid, bot = (40, 70, 160), (20, 40, 110), (10, 120, 90)
    for y in range(big):
        t = y / (big - 1)
        if t < 0.5:
            u = t / 0.5
            c = tuple(int(top[i] + (mid[i] - top[i]) * u) for i in range(3))
        else:
            u = (t - 0.5) / 0.5
            c = tuple(int(mid[i] + (bot[i] - mid[i]) * u) for i in range(3))
        for x in range(big):
            gp[x, y] = c + (255,)
    mask = Image.new('L', (big, big), 0)
    ImageDraw.Draw(mask).rounded_rectangle(box, rad, fill=255)
    tile = Image.new('RGBA', (big, big), (0, 0, 0, 0))
    tile.paste(grad, (0, 0), mask)
    # (the light on its top edge)
    hl = Image.new('RGBA', (big, big), (0, 0, 0, 0))
    ImageDraw.Draw(hl).rounded_rectangle((box[0] + S * 2, box[1] + S * 2, box[2] - S * 2, box[3]), rad - S * 2,
                                         outline=(255, 255, 255, 70), width=S * 2)
    cut = Image.new('L', (big, big), 0)
    ImageDraw.Draw(cut).rectangle((0, 0, big, box[1] + rad), fill=255)
    tile.alpha_composite(Image.composite(hl, Image.new('RGBA', (big, big), (0, 0, 0, 0)), cut))
    canvas.alpha_composite(tile)
    out = canvas.resize((size, size), Image.LANCZOS)
    # the pixel art, whole pixels scaled up (sharp), with its own soft shadow
    art = pixel_art()
    k = max(1, int(size * 0.74) // art.width)
    a2 = art.resize((art.width * k, art.height * k), Image.NEAREST)
    ax = (size - a2.width) // 2
    ay = (size - a2.height) // 2
    shadow = Image.new('RGBA', (size, size), (0, 0, 0, 0))
    am = a2.split()[3].point(lambda v: 110 if v else 0)
    shadow.paste(Image.new('RGBA', a2.size, (0, 0, 20, 255)), (ax + k, ay + 2 * k), am)
    shadow = shadow.filter(ImageFilter.GaussianBlur(size / 90))
    out.alpha_composite(shadow)
    out.alpha_composite(a2, (ax, ay))
    return out


if __name__ == '__main__':
    icon(192).save(os.path.join(ASSETS, 'grow-icon.png'))
    icon(512).save(os.path.join(ASSETS, 'grow-icon-512.png'))
    print('grow-icon.png, grow-icon-512.png')
