#!/usr/bin/env python3
"""Draws Retro Atelier's app icon: a modern rounded tile (soft light, a
shadow) holding 1994 pixel art -- a 3.1 window with a dithered sunset in
it, the selection's marching ants and a brush. Writes
examples/assets/photo-icon.png (192 x 192, the launcher's) and
photo-icon-512.png (for stores, docs, desktops).

    python3 tools/genphotoicon.py
"""

import os
from PIL import Image, ImageDraw, ImageFilter

HERE = os.path.dirname(os.path.abspath(__file__))
ASSETS = os.path.join(HERE, '..', 'examples', 'assets')

# the 16 VGA colors, and a few in-between ones a 256-color screen had
VGA = {
    'k': (0, 0, 0), 'n': (0, 0, 128), 'G': (0, 128, 0), 't': (0, 128, 128), 'm': (128, 0, 0),
    'P': (128, 0, 128), 'o': (128, 128, 0), 's': (192, 192, 192), 'g': (128, 128, 128),
    'b': (0, 0, 255), 'l': (0, 255, 0), 'c': (0, 255, 255), 'r': (255, 0, 0), 'p': (255, 0, 255),
    'y': (255, 255, 0), 'w': (255, 255, 255),
}


def pixel_art():
    """The window and its picture, 40 x 34 pixels (drawn 1:1, scaled up whole)."""
    W, H = 40, 34
    im = Image.new('RGBA', (W, H), (0, 0, 0, 0))
    px = im.load()

    def put(x, y, c):
        if 0 <= x < W and 0 <= y < H:
            px[x, y] = c + (255,) if len(c) == 3 else c

    def rect(x0, y0, x1, y1, c):
        for y in range(y0, y1 + 1):
            for x in range(x0, x1 + 1):
                put(x, y, c)

    # the window: a black line round it, silver frame, the blue title bar
    rect(0, 0, W - 1, H - 1, VGA['k'])
    rect(1, 1, W - 2, H - 2, VGA['s'])
    for x in range(1, W - 1):
        put(x, 1, VGA['w'])
    for y in range(1, H - 1):
        put(1, y, VGA['w'])
    for x in range(1, W - 1):
        put(x, H - 2, VGA['g'])
    for y in range(1, H - 1):
        put(W - 2, y, VGA['g'])
    rect(3, 3, W - 4, 7, VGA['n'])
    # (the title: a few light dashes, and the boxes at the right)
    for x in (5, 6, 7, 9, 10, 12, 13, 14):
        put(x, 5, (170, 190, 255))
    rect(W - 11, 3, W - 8, 7, VGA['s'])
    put(W - 10, 5, VGA['k']); put(W - 9, 5, VGA['k'])
    rect(W - 7, 3, W - 4, 7, VGA['s'])
    put(W - 6, 4, VGA['k']); put(W - 5, 4, VGA['k'])
    put(W - 6, 6, VGA['k']); put(W - 5, 6, VGA['k'])
    # the picture: a sunset over the hills and the water, in bands dithered into each other
    x0, y0, x1, y1 = 3, 9, W - 4, H - 4
    rect(x0 - 1, y0 - 1, x1 + 1, y1 + 1, VGA['g'])
    sky = [(28, 12, 64), (58, 18, 96), (104, 26, 112), (164, 40, 104), (214, 72, 72), (246, 128, 56),
           (252, 184, 72)]
    horizon = y0 + 13
    for y in range(y0, horizon + 1):
        t = (y - y0) / (horizon - y0) * (len(sky) - 1)
        i = int(t)
        f = t - i
        for x in range(x0, x1 + 1):
            # (a 2 x 2 ordered dither between neighboring bands)
            th = [[0.2, 0.7], [0.95, 0.45]][y % 2][x % 2]
            put(x, y, sky[min(i + (1 if f > th else 0), len(sky) - 1)])
    # the sun, its glow
    cx, cy, r = x0 + 21, horizon - 3, 5.2
    for y in range(y0, horizon + 1):
        for x in range(x0, x1 + 1):
            d = ((x - cx) ** 2 + (y - cy) ** 2) ** 0.5
            if d <= r - 1:
                put(x, y, (255, 246, 196))
            elif d <= r:
                put(x, y, (255, 214, 120))
            elif d <= r + 2 and (x + y) % 2 == 0:
                put(x, y, (252, 200, 96))
    # the hills: far ones (lighter), near ones (dark), a valley where the sun goes down
    import math
    for x in range(x0, x1 + 1):
        u = (x - x0) / (x1 - x0)
        far = horizon - int(2 + 3 * (0.5 + 0.5 * math.cos(u * 9.0)) * (abs(u - 0.6) * 2.2))
        near = horizon - int(1 + 4.5 * max(0.0, abs(u - 0.6) * 2 - 0.25) + (1 if (x % 5) == 0 else 0))
        for y in range(far, horizon + 1):
            put(x, y, (120, 44, 96))
        for y in range(near, horizon + 1):
            put(x, y, (52, 18, 60) if y > near else (84, 30, 84))
    # the water: the sky again, darker, in lines; the sun's path on it, shorter as it nears
    for y in range(horizon + 1, y1 + 1):
        k = y - horizon
        for x in range(x0, x1 + 1):
            base = sky[max(0, len(sky) - 2 - k // 2)]
            c = tuple(int(v * (0.5 if k % 2 else 0.62)) for v in base)
            put(x, y, c)
        if k % 2 == 1:
            half = max(1, 5 - k // 2)
            for x in range(int(cx) - half, int(cx) + half + 1):
                put(x, y, (255, 222, 130) if k < 4 else (238, 156, 84))
    return im


def brush_art():
    """A brush lying across the corner, 30 x 30 pixels."""
    N = 30
    im = Image.new('RGBA', (N, N), (0, 0, 0, 0))
    px = im.load()

    def put(x, y, c):
        if 0 <= x < N and 0 <= y < N:
            px[x, y] = c + (255,)

    # the handle (red, a light edge), the ferrule (silver), the hairs (dark, then the paint)
    for i in range(N):
        x, y = N - 1 - i, i
        for w in range(-2, 3):
            xx, yy = x + w // 2 + (w % 2), y + w // 2
            if i < 15:
                c = (214, 36, 36) if w < 1 else (150, 16, 16)
                if w == -2:
                    c = (255, 120, 110)
            elif i < 19:
                c = (236, 236, 236) if w < 0 else (150, 150, 150)
            elif i < 26:
                c = (40, 40, 48)
            else:
                c = (252, 200, 72) if w <= 0 else (246, 128, 56)
            if i >= 26 and abs(w) > 1:
                continue
            put(xx, yy, c)
    # (a black line round it)
    out = im.copy()
    op = out.load()
    for y in range(N):
        for x in range(N):
            if px[x, y][3] == 0:
                for dx, dy in ((1, 0), (-1, 0), (0, 1), (0, -1)):
                    xx, yy = x + dx, y + dy
                    if 0 <= xx < N and 0 <= yy < N and px[xx, yy][3] > 0:
                        op[x, y] = (0, 0, 0, 255)
                        break
    return out


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
    # the tile: the 3.1 desktop's teal into a night blue, light from the top
    grad = Image.new('RGBA', (big, big))
    gp = grad.load()
    top, mid, bot = (38, 150, 160), (16, 92, 128), (12, 30, 78)
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
    # (a faint pixel grid over it: the screen it came from)
    grid = Image.new('RGBA', (big, big), (0, 0, 0, 0))
    gd = ImageDraw.Draw(grid)
    step = big // 24
    for k in range(0, big, step):
        gd.line((k, 0, k, big), fill=(255, 255, 255, 12), width=max(1, S))
        gd.line((0, k, big, k), fill=(255, 255, 255, 12), width=max(1, S))
    gm = Image.new('L', (big, big), 0)
    gm.paste(mask, (0, 0))
    tile.alpha_composite(Image.composite(grid, Image.new('RGBA', (big, big), (0, 0, 0, 0)), gm))
    # (the light on its top edge)
    hl = Image.new('RGBA', (big, big), (0, 0, 0, 0))
    ImageDraw.Draw(hl).rounded_rectangle((box[0] + S * 2, box[1] + S * 2, box[2] - S * 2, box[3]), rad - S * 2,
                                         outline=(255, 255, 255, 70), width=S * 2)
    cut = Image.new('L', (big, big), 0)
    ImageDraw.Draw(cut).rectangle((0, 0, big, box[1] + rad), fill=255)
    tile.alpha_composite(Image.composite(hl, Image.new('RGBA', (big, big), (0, 0, 0, 0)), cut))
    canvas.alpha_composite(tile)
    out = canvas.resize((size, size), Image.LANCZOS)
    # the pixel art, whole pixels scaled up (sharp)
    art = pixel_art()
    k = max(1, int(size * 0.72) // art.width)
    a2 = art.resize((art.width * k, art.height * k), Image.NEAREST)
    ax = (size - a2.width) // 2 - k
    ay = (size - a2.height) // 2 - k
    # (its own soft shadow)
    shadow = Image.new('RGBA', (size, size), (0, 0, 0, 0))
    am = a2.split()[3].point(lambda v: 110 if v else 0)
    shadow.paste(Image.new('RGBA', a2.size, (0, 0, 20, 255)), (ax + k, ay + 2 * k), am)
    shadow = shadow.filter(ImageFilter.GaussianBlur(size / 90))
    out.alpha_composite(shadow)
    out.alpha_composite(a2, (ax, ay))
    # the marching ants round the sun
    d = ImageDraw.Draw(out)
    sx0, sy0 = ax + 16 * k, ay + 12 * k
    sx1, sy1 = ax + 31 * k, ay + 23 * k
    dash = k
    for x in range(sx0, sx1, dash):
        c = (0, 0, 0, 255) if ((x - sx0) // dash) % 2 == 0 else (255, 255, 255, 255)
        d.rectangle((x, sy0, min(sx1, x + dash - 1), sy0 + max(1, k // 3)), fill=c)
        d.rectangle((x, sy1, min(sx1, x + dash - 1), sy1 + max(1, k // 3)), fill=c)
    for y in range(sy0, sy1 + 1, dash):
        c = (0, 0, 0, 255) if ((y - sy0) // dash) % 2 == 0 else (255, 255, 255, 255)
        d.rectangle((sx0, y, sx0 + max(1, k // 3), min(sy1, y + dash - 1)), fill=c)
        d.rectangle((sx1, y, sx1 + max(1, k // 3), min(sy1, y + dash - 1)), fill=c)
    # the brush, over the corner
    br = brush_art()
    kb = max(1, int(size * 0.42) // br.width)
    b2 = br.resize((br.width * kb, br.height * kb), Image.NEAREST)
    bx = ax + a2.width - b2.width + 6 * kb
    by = ay + a2.height - b2.height + 6 * kb
    bsh = Image.new('RGBA', (size, size), (0, 0, 0, 0))
    bm = b2.split()[3].point(lambda v: 120 if v else 0)
    bsh.paste(Image.new('RGBA', b2.size, (0, 0, 20, 255)), (bx + kb, by + 2 * kb), bm)
    bsh = bsh.filter(ImageFilter.GaussianBlur(size / 100))
    out.alpha_composite(bsh)
    out.alpha_composite(b2, (bx, by))
    return out


if __name__ == '__main__':
    icon(192).save(os.path.join(ASSETS, 'photo-icon.png'))
    icon(512).save(os.path.join(ASSETS, 'photo-icon-512.png'))
    print('photo-icon.png, photo-icon-512.png')
