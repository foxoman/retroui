#!/usr/bin/env python3
"""Draws Retro Podcast's app icon: a modern rounded tile (soft light, a
shadow) holding 1994 pixel art -- a studio microphone on its stand, the
sound going out on both sides. Writes examples/assets/podcast-icon.png
(192 x 192, the launcher's) and podcast-icon-512.png (for stores, docs,
desktops).

    python3 tools/genpodcasticon.py
"""

import os
from PIL import Image, ImageDraw, ImageFilter

HERE = os.path.dirname(os.path.abspath(__file__))
ASSETS = os.path.join(HERE, '..', 'examples', 'assets')

BLACK, SILVER, GRAY, WHITE, NAVY = (0, 0, 0), (192, 192, 192), (128, 128, 128), (255, 255, 255), (0, 0, 128)
DARK, YELLOW, RED = (64, 64, 64), (255, 220, 60), (210, 30, 30)


def pixel_art():
    """The microphone, its holder, stand and the waves, 40 x 34 pixels
    (drawn 1:1, scaled up whole)."""
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

    # the capsule: a rounded silver body, a black line round it, a grille
    x0, y0, x1, y1 = 14, 1, 25, 19
    rect(x0 + 1, y0, x1 - 1, y1, BLACK)
    rect(x0, y0 + 1, x1, y1 - 1, BLACK)
    rect(x0 + 1, y0 + 1, x1 - 1, y1 - 1, SILVER)
    for y in range(y0 + 2, y1 - 1):
        put(x0 + 1, y, WHITE)
        put(x1 - 1, y, GRAY)
    for y in range(y0 + 3, y1 - 2, 2):
        for x in range(x0 + 3, x1 - 2, 2):
            put(x, y, DARK)
    # the band round its middle, and the red light: on the air
    rect(x0, 11, x1, 12, NAVY)
    put(x0 + 2, 11, RED)
    # the holder: a U round the capsule's lower half
    for y in range(9, 22):
        put(11, y, BLACK); put(12, y, NAVY)
        put(27, y, NAVY); put(28, y, BLACK)
    rect(12, 21, 27, 22, NAVY)
    rect(11, 23, 28, 23, BLACK)
    # the stand and its foot
    rect(19, 24, 20, 29, DARK)
    put(19, 24, GRAY)
    rect(12, 30, 27, 31, DARK)
    rect(11, 32, 28, 32, BLACK)
    rect(12, 30, 27, 30, GRAY)
    # the sound: two arcs on each side
    for (r, c) in ((4, YELLOW), (7, WHITE)):
        for y in range(10 - r, 11 + r):
            dy = y - 10
            dx = int(round((r * r - dy * dy) ** 0.5)) if r * r >= dy * dy else 0
            if abs(dy) < r - 0:
                put(10 - dx - 1, y, c)
                put(29 + dx + 1, y, c)
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
    top, mid, bot = (170, 90, 230), (90, 60, 170), (10, 90, 110)
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
    icon(192).save(os.path.join(ASSETS, 'podcast-icon.png'))
    icon(512).save(os.path.join(ASSETS, 'podcast-icon-512.png'))
    print('podcast-icon.png, podcast-icon-512.png')
