#!/usr/bin/env python3
"""Draws 7GUIs' app icon: a modern rounded tile (soft light, a shadow)
holding 1994 pixel art -- a 3.1 window with a big 7 on its white field, a
circle (the circle drawer) and a slider under them (the timer). Writes
examples/assets/sevenguis-icon.png (192 x 192, the launcher's) and
sevenguis-icon-512.png (for stores, docs, desktops).

    python3 tools/gensevenguisicon.py
"""

import os
from PIL import Image, ImageDraw, ImageFilter

HERE = os.path.dirname(os.path.abspath(__file__))
ASSETS = os.path.join(HERE, '..', 'examples', 'assets')

BLACK, SILVER, GRAY, WHITE, NAVY = (0, 0, 0), (192, 192, 192), (128, 128, 128), (255, 255, 255), (0, 0, 128)
RED, TEAL = (200, 0, 0), (0, 128, 128)


def pixel_art():
    """The window, its 7, the circle and the slider, 40 x 34 pixels (drawn
    1:1, scaled up whole)."""
    W, H = 40, 34
    im = Image.new('RGBA', (W, H), (0, 0, 0, 0))
    px = im.load()

    def put(x, y, c):
        if 0 <= x < W and 0 <= y < H:
            px[x, y] = c + (255,)

    def rect(x0, y0, x1, y1, c):
        for y in range(y0, y1 + 1):
            for x in range(x0, x1 + 1):
                put(x, y, c)

    # the window: a black line round it, the silver frame, the blue title bar
    rect(0, 0, W - 1, H - 1, BLACK)
    rect(1, 1, W - 2, H - 2, SILVER)
    for x in range(1, W - 1):
        put(x, 1, WHITE)
        put(x, H - 2, GRAY)
    for y in range(1, H - 1):
        put(1, y, WHITE)
        put(W - 2, y, GRAY)
    rect(3, 3, W - 4, 7, NAVY)
    for x in (5, 6, 7, 9, 10, 11, 12, 14, 15):
        put(x, 5, (170, 190, 255))
    rect(W - 11, 3, W - 8, 7, SILVER)
    put(W - 10, 5, BLACK); put(W - 9, 5, BLACK)
    rect(W - 7, 3, W - 4, 7, SILVER)
    put(W - 6, 4, BLACK); put(W - 5, 4, BLACK)
    put(W - 6, 6, BLACK); put(W - 5, 6, BLACK)
    # the field: white, sunken
    x0, y0, x1, y1 = 3, 10, W - 4, H - 9
    rect(x0 - 1, y0 - 1, x1 + 1, y1 + 1, GRAY)
    rect(x0, y0, x1, y1, WHITE)
    # the 7: a bar and a stroke going down to the left, navy
    rect(6, 12, 17, 13, NAVY)
    for i in range(10):
        rect(16 - i // 2 * 1 - (i // 3), 14 + i, 17 - i // 2 * 1 - (i // 3), 14 + i, NAVY)
    # the circle (the circle drawer), red
    cx, cy, r = 27, 18, 5
    for y in range(cy - r, cy + r + 1):
        for x in range(cx - r, cx + r + 1):
            d = ((x - cx) ** 2 + (y - cy) ** 2) ** 0.5
            if r - 1.1 <= d <= r + 0.3:
                put(x, y, RED)
    # the slider under the field: its groove and its thumb
    rect(4, H - 6, W - 5, H - 6, GRAY)
    rect(4, H - 5, W - 5, H - 5, WHITE)
    rect(14, H - 8, 17, H - 4, SILVER)
    rect(14, H - 8, 17, H - 8, WHITE)
    rect(14, H - 8, 14, H - 4, WHITE)
    rect(17, H - 8, 17, H - 4, BLACK)
    rect(14, H - 4, 17, H - 4, BLACK)
    rect(4, H - 7, 13, H - 7, TEAL)
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
    # the tile: an orange into a plum, light from the top
    grad = Image.new('RGBA', (big, big))
    gp = grad.load()
    top, mid, bot = (250, 160, 60), (200, 70, 90), (70, 30, 110)
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
    icon(192).save(os.path.join(ASSETS, 'sevenguis-icon.png'))
    icon(512).save(os.path.join(ASSETS, 'sevenguis-icon-512.png'))
    print('sevenguis-icon.png, sevenguis-icon-512.png')
