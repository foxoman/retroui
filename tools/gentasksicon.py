#!/usr/bin/env python3
"""Draws Retro Tasks' app icon: a rounded tile of glass, sky blue to deep blue, a white sheet of
lined paper on it with three round checks -- two ticked -- and a soft shadow. Writes
examples/assets/tasks-icon.png (192 x 192, the launcher's) and tasks-icon-512.png (for stores,
docs, desktops).

    python3 tools/gentasksicon.py
"""

import os
from PIL import Image, ImageDraw, ImageFilter

HERE = os.path.dirname(os.path.abspath(__file__))
ASSETS = os.path.join(HERE, '..', 'examples', 'assets')


def tile(size):
    k = size / 512
    o = lambda v: int(v * k)
    img = Image.new('RGBA', (size, size), (0, 0, 0, 0))
    grad = Image.new('RGBA', (size, size))
    px = grad.load()
    for y in range(size):
        for x in range(size):
            t = (x + y) / (2 * size)
            px[x, y] = (int(80 - 60 * t), int(170 - 90 * t), int(250 - 60 * t), 255)
    mask = Image.new('L', (size, size), 0)
    ImageDraw.Draw(mask).rounded_rectangle([o(24), o(24), size - o(24), size - o(24)], radius=o(110), fill=255)
    img.paste(grad, (0, 0), mask)
    sheen = Image.new('RGBA', (size, size), (0, 0, 0, 0))
    ImageDraw.Draw(sheen).ellipse([o(-60), o(-260), size + o(60), o(250)], fill=(255, 255, 255, 46))
    img = Image.alpha_composite(img, Image.composite(sheen, Image.new('RGBA', (size, size)), mask))
    # the sheet: its shadow, then white with blue lines and a red margin
    sh = Image.new('RGBA', (size, size), (0, 0, 0, 0))
    ImageDraw.Draw(sh).rounded_rectangle([o(122), o(112), o(402), o(422)], radius=o(22), fill=(0, 20, 60, 120))
    sh = sh.filter(ImageFilter.GaussianBlur(o(12) or 1))
    img = Image.alpha_composite(img, sh)
    d = ImageDraw.Draw(img)
    d.rounded_rectangle([o(112), o(98), o(392), o(408)], radius=o(22), fill=(255, 255, 250, 255))
    for i in range(3):
        y = 160 + i * 90
        d.line([(o(200), o(y + 22)), (o(360), o(y + 22))], fill=(150, 185, 230, 255), width=max(1, o(6)))
        cx, cy, r = 160, y + 10, 24
        if i < 2:
            d.ellipse([o(cx - r), o(cy - r), o(cx + r), o(cy + r)], fill=(36, 112, 216, 255))
            d.line([(o(cx - 11), o(cy + 1)), (o(cx - 3), o(cy + 10)), (o(cx + 13), o(cy - 10))],
                   fill=(255, 255, 255, 255), width=max(1, o(7)), joint='curve')
        else:
            d.ellipse([o(cx - r), o(cy - r), o(cx + r), o(cy + r)], outline=(160, 160, 170, 255), width=max(1, o(5)))
    return img


big = tile(512)
big.save(os.path.join(ASSETS, 'tasks-icon-512.png'))
big.resize((192, 192), Image.LANCZOS).save(os.path.join(ASSETS, 'tasks-icon.png'))
print('tasks-icon.png, tasks-icon-512.png')
