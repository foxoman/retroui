#!/usr/bin/env python3
"""Draws Retro Music's app icon: a rounded tile of glass, coral to violet, a white eighth-note
pair on it with a soft shadow. Writes examples/assets/music-icon.png (192 x 192, the
launcher's) and music-icon-512.png (for stores, docs, desktops).

    python3 tools/genmusicicon.py
"""

import os
from PIL import Image, ImageDraw, ImageFilter

HERE = os.path.dirname(os.path.abspath(__file__))
ASSETS = os.path.join(HERE, '..', 'examples', 'assets')


def tile(size):
    k = size / 512
    img = Image.new('RGBA', (size, size), (0, 0, 0, 0))
    # the tile: a gradient from coral (top left) to violet (bottom right), rounded
    grad = Image.new('RGBA', (size, size))
    px = grad.load()
    for y in range(size):
        for x in range(size):
            t = (x + y) / (2 * size)
            px[x, y] = (int(255 - 120 * t), int(94 - 40 * t), int(110 + 120 * t), 255)
    mask = Image.new('L', (size, size), 0)
    ImageDraw.Draw(mask).rounded_rectangle([int(24 * k), int(24 * k), size - int(24 * k), size - int(24 * k)],
                                           radius=int(110 * k), fill=255)
    img.paste(grad, (0, 0), mask)
    # its light: a glassy sheen on the upper half
    sheen = Image.new('RGBA', (size, size), (0, 0, 0, 0))
    ImageDraw.Draw(sheen).ellipse([int(-60 * k), int(-260 * k), size + int(60 * k), int(250 * k)],
                                  fill=(255, 255, 255, 46))
    img = Image.alpha_composite(img, Image.composite(sheen, Image.new('RGBA', (size, size)), mask))
    # the notes: two heads, two stems, a beam -- a shadow under them, then white
    def notes(d, c, dx=0, dy=0):
        o = lambda v: int(v * k)
        d.ellipse([o(130 + dx), o(330 + dy), o(230 + dx), o(410 + dy)], fill=c)
        d.ellipse([o(290 + dx), o(300 + dy), o(390 + dx), o(380 + dy)], fill=c)
        d.rectangle([o(204 + dx), o(130 + dy), o(230 + dx), o(372 + dy)], fill=c)
        d.rectangle([o(364 + dx), o(100 + dy), o(390 + dx), o(342 + dy)], fill=c)
        d.polygon([(o(204 + dx), o(130 + dy)), (o(390 + dx), o(100 + dy)), (o(390 + dx), o(160 + dy)),
                   (o(204 + dx), o(190 + dy))], fill=c)
    sh = Image.new('RGBA', (size, size), (0, 0, 0, 0))
    notes(ImageDraw.Draw(sh), (40, 0, 60, 110), 6, 10)
    sh = sh.filter(ImageFilter.GaussianBlur(int(10 * k) or 1))
    img = Image.alpha_composite(img, sh)
    fg = Image.new('RGBA', (size, size), (0, 0, 0, 0))
    notes(ImageDraw.Draw(fg), (255, 255, 255, 255))
    return Image.alpha_composite(img, fg)


big = tile(512)
big.save(os.path.join(ASSETS, 'music-icon-512.png'))
big.resize((192, 192), Image.LANCZOS).save(os.path.join(ASSETS, 'music-icon.png'))
print('music-icon.png, music-icon-512.png')
