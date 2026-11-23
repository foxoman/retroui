#!/usr/bin/env python3
"""Draws Retro Nim UI's pixel icons and writes src/retroui/pixelicons.nim.

Every icon has a 16 x 16 and a 32 x 32 drawing in the 16 VGA colors. The
32 x 32 art is used for big icons and, on screens of 2x and more, for icons
in ordinary text, so it is drawn with the same idea as the small one and
more detail -- not just made bigger.

The designs are our own, in the manner of the early-1990s desktops: a black
outline, light from the top left (white on the upper and left edges, a darker
shade on the lower and right ones), flat fronts, no drop shadows (they look
wrong on a selected, navy row), the 16 VGA colors only.

  python3 tools/genicons.py                  # writes the Nim module
  python3 tools/genicons.py sheet.png        # and a contact sheet
  python3 tools/genicons.py --appicons       # and the example apps' launcher icons
"""
import sys, os, math, re

PAL = {'k': (0, 0, 0), 'w': (255, 255, 255), 's': (192, 192, 192), 'g': (128, 128, 128),
       'r': (255, 0, 0), 'm': (128, 0, 0), 'y': (255, 255, 0), 'o': (128, 128, 0),
       'l': (0, 255, 0), 'G': (0, 128, 0), 'c': (0, 255, 255), 't': (0, 128, 128),
       'b': (0, 0, 255), 'n': (0, 0, 128), 'p': (255, 0, 255), 'P': (128, 0, 128)}


class C:
    """A square of pixels in the palette's letters ('.' is transparent)."""

    def __init__(self, n):
        self.n = n
        self.big = n >= 32
        self.g = [['.'] * n for _ in range(n)]

    def px(self, x, y, c):
        if 0 <= x < self.n and 0 <= y < self.n and c not in (' ', None):
            self.g[y][x] = c

    def get(self, x, y):
        return self.g[y][x] if 0 <= x < self.n and 0 <= y < self.n else '.'

    def rect(self, x0, y0, x1, y1, c):
        for y in range(min(y0, y1), max(y0, y1) + 1):
            for x in range(min(x0, x1), max(x0, x1) + 1):
                self.px(x, y, c)

    def hline(self, x0, x1, y, c):
        for x in range(min(x0, x1), max(x0, x1) + 1):
            self.px(x, y, c)

    def vline(self, x, y0, y1, c):
        for y in range(min(y0, y1), max(y0, y1) + 1):
            self.px(x, y, c)

    def frame(self, x0, y0, x1, y1, c):
        self.hline(x0, x1, y0, c); self.hline(x0, x1, y1, c)
        self.vline(x0, y0, y1, c); self.vline(x1, y0, y1, c)

    def line(self, x0, y0, x1, y1, c):
        x0, y0, x1, y1 = (int(round(v)) for v in (x0, y0, x1, y1))
        dx, dy = abs(x1 - x0), -abs(y1 - y0)
        sx, sy = (1 if x0 < x1 else -1), (1 if y0 < y1 else -1)
        err = dx + dy
        while True:
            self.px(x0, y0, c)
            if x0 == x1 and y0 == y1:
                break
            e2 = 2 * err
            if e2 >= dy:
                err += dy; x0 += sx
            if e2 <= dx:
                err += dx; y0 += sy

    def poly(self, pts, c):
        """A filled polygon (pixel centers inside it)."""
        n = len(pts)
        for y in range(self.n):
            yc = y + 0.5
            xs = []
            for i in range(n):
                (x0, y0), (x1, y1) = pts[i], pts[(i + 1) % n]
                y0 += 0.5; y1 += 0.5; x0 += 0.5; x1 += 0.5
                if (y0 <= yc < y1) or (y1 <= yc < y0):
                    xs.append(x0 + (yc - y0) * (x1 - x0) / (y1 - y0))
            xs.sort()
            for i in range(0, len(xs) - 1, 2):
                for x in range(self.n):
                    if xs[i] - 0.01 <= x + 0.5 <= xs[i + 1] + 0.01:
                        self.px(x, y, c)

    def outline(self, pts, c):
        for i in range(len(pts)):
            (x0, y0), (x1, y1) = pts[i], pts[(i + 1) % len(pts)]
            self.line(x0, y0, x1, y1, c)

    def shape(self, pts, fill, out='k'):
        self.poly(pts, fill)
        self.outline(pts, out)

    def ellipse(self, cx, cy, rx, ry, c):
        """A filled ellipse around (cx, cy) (half-pixel centers allowed)."""
        for y in range(self.n):
            for x in range(self.n):
                if ((x + 0.5 - cx) / rx) ** 2 + ((y + 0.5 - cy) / ry) ** 2 <= 1.0:
                    self.px(x, y, c)

    def disc(self, cx, cy, r, fill, out='k'):
        """A disc with a one-pixel outline: (cx, cy) is its center in
        pixel-edge coordinates (16 for the middle of a 32 x 32 icon)."""
        if out:
            self.ellipse(cx, cy, r, r, out)
            self.ellipse(cx, cy, r - 1, r - 1, fill)
        else:
            self.ellipse(cx, cy, r, r, fill)

    def dither(self, x0, y0, x1, y1, a, b):
        for y in range(y0, y1 + 1):
            for x in range(x0, x1 + 1):
                self.px(x, y, a if (x + y) % 2 == 0 else b)

    def paste(self, rows, x, y):
        if isinstance(rows, str):
            rows = sprite(rows)
        for j, row in enumerate(rows):
            for i, ch in enumerate(row):
                if ch not in '. ':
                    self.px(x + i, y + j, ch)

    def recolor(self, a, b, box=None):
        x0, y0, x1, y1 = box or (0, 0, self.n - 1, self.n - 1)
        for y in range(y0, y1 + 1):
            for x in range(x0, x1 + 1):
                if self.get(x, y) == a:
                    self.g[y][x] = b

    def bevel(self, x0, y0, x1, y1, face='s', hl='w', sh='g', out='k'):
        """A raised box: an outline, its face, light top/left, dark bottom/right."""
        self.rect(x0, y0, x1, y1, face)
        if out:
            self.frame(x0, y0, x1, y1, out)
            x0 += 1; y0 += 1; x1 -= 1; y1 -= 1
        if hl:
            self.hline(x0, x1, y0, hl); self.vline(x0, y0, y1, hl)
        if sh:
            self.hline(x0, x1, y1, sh); self.vline(x1, y0, y1, sh)

    def sunken(self, x0, y0, x1, y1, face='w'):
        """A hollow: dark top/left, light bottom/right, and its face."""
        self.rect(x0, y0, x1, y1, face)
        self.hline(x0, x1, y0, 'g'); self.vline(x0, y0, y1, 'g')
        self.hline(x0, x1, y1, 'w'); self.vline(x1, y0, y1, 'w')

    def rows(self):
        return [''.join(r) for r in self.g]

    # -- drawing by distance: thick strokes and arcs, for round things --

    def stroke(self, x0, y0, x1, y1, w, c):
        """A line `w` pixels thick from (x0, y0) to (x1, y1) (pixel-edge
        coordinates: 16 is the middle of a 32 x 32 icon)."""
        dx, dy = x1 - x0, y1 - y0
        ll = dx * dx + dy * dy or 1e-9
        for y in range(self.n):
            for x in range(self.n):
                px, py = x + 0.5, y + 0.5
                t = max(0.0, min(1.0, ((px - x0) * dx + (py - y0) * dy) / ll))
                if math.hypot(px - (x0 + t * dx), py - (y0 + t * dy)) <= w / 2:
                    self.px(x, y, c)

    def arc(self, cx, cy, r, w, a0, a1, c):
        """A ring `w` thick around (cx, cy) from angle `a0` to `a1` (degrees,
        0 at the right, 90 down)."""
        for y in range(self.n):
            for x in range(self.n):
                dx, dy = x + 0.5 - cx, y + 0.5 - cy
                d = math.hypot(dx, dy)
                if abs(d - r) > w / 2:
                    continue
                a = math.degrees(math.atan2(dy, dx))
                for k in (-360, 0, 360):
                    if a0 <= a + k <= a1:
                        self.px(x, y, c)
                        break

    def ring(self, cx, cy, r0, r1, c):
        for y in range(self.n):
            for x in range(self.n):
                if r0 <= math.hypot(x + 0.5 - cx, y + 0.5 - cy) <= r1:
                    self.px(x, y, c)

    def outlined(self, out='k'):
        """Puts an outline around everything drawn (on the transparent pixels
        next to it, sideways and up and down)."""
        snap = [row[:] for row in self.g]
        for y in range(self.n):
            for x in range(self.n):
                if snap[y][x] != '.':
                    continue
                for dx, dy in ((1, 0), (-1, 0), (0, 1), (0, -1)):
                    xx, yy = x + dx, y + dy
                    if 0 <= xx < self.n and 0 <= yy < self.n and snap[yy][xx] not in ('.', out):
                        self.g[y][x] = out
                        break
        return self

    def lit(self, face, light, dark):
        """Light from the top left: the `face` pixels touching the outline
        above or at the left turn `light`, those below or at the right `dark`."""
        snap = [row[:] for row in self.g]
        for y in range(self.n):
            for x in range(self.n):
                if snap[y][x] != face:
                    continue
                def at(xx, yy):
                    return snap[yy][xx] if 0 <= xx < self.n and 0 <= yy < self.n else '.'
                if light and (at(x - 1, y) in 'k.' or at(x, y - 1) in 'k.'):
                    self.g[y][x] = light
                elif dark and (at(x + 1, y) in 'k.' or at(x, y + 1) in 'k.'):
                    self.g[y][x] = dark
        return self

    def over(self, other):
        """Draws `other` (a layer of the same size) over this one."""
        for y in range(self.n):
            for x in range(self.n):
                if other.g[y][x] != '.':
                    self.g[y][x] = other.g[y][x]
        return self

    def layer(self):
        return C(self.n)


def sprite(text):
    lines = text.strip('\n').split('\n')
    w = max(len(l) for l in lines)
    return [l.ljust(w, '.') for l in lines]


# ---- the shapes many icons share -------------------------------------------------------------------

def page(c, fill='w', narrow=False):
    """A sheet of paper with its top right corner folded over. Returns the
    room inside it (x0, y0, x1, y1) for an emblem."""
    if c.big:
        x0, y0, x1, y1, e = (7, 1, 24, 30, 6) if narrow else (5, 1, 26, 30, 7)
    else:
        x0, y0, x1, y1, e = 3, 0, 12, 15, 4
    for y in range(y0, y1 + 1):
        for x in range(x0, x1 + 1):
            if y - y0 < e and x > x1 - e + (y - y0):
                continue
            c.px(x, y, fill)
    c.vline(x0, y0, y1, 'k'); c.hline(x0, x1, y1, 'k')
    c.vline(x1, y0 + e, y1, 'k'); c.hline(x0, x1 - e, y0, 'k')
    c.line(x1 - e, y0, x1, y0 + e, 'k')
    # the folded corner, lit from the top left
    for y in range(y0 + 1, y0 + e):
        for x in range(x1 - e + 1, x1 - e + (y - y0)):
            c.px(x, y, 's')
    c.vline(x1 - e, y0, y0 + e, 'k'); c.hline(x1 - e, x1, y0 + e, 'k')
    if c.big:
        c.vline(x1 - 1, y0 + e + 1, y1 - 1, 's'); c.hline(x0 + 1, x1 - 1, y1 - 1, 's')
        return (x0 + 3, y0 + e + 2, x1 - 3, y1 - 3)
    return (x0 + 2, y0 + e + 1, x1 - 2, y1 - 2)


def lines_in(c, box, color='g', gaps=2, ragged=(1.0, 0.75, 1.0, 0.9, 0.6, 1.0, 0.85, 0.7)):
    x0, y0, x1, y1 = box
    y, i = y0, 0
    while y <= y1:
        f = ragged[i % len(ragged)]
        c.hline(x0, x0 + max(0, int(round((x1 - x0) * f))), y, color)
        y += gaps; i += 1


def folder(c, face='y', lit='w', shade='o', inside=None):
    """A closed folder seen from the front, its tab at the top left. Returns
    the room on its front (x0, y0, x1, y1) for an emblem."""
    k = 'k'
    if c.big:
        # the back: its tab, then its top edge behind the front
        c.hline(2, 10, 5, k); c.px(1, 6, k); c.px(11, 6, k); c.px(12, 7, k)
        c.hline(13, 29, 8, k); c.vline(1, 6, 28, k); c.vline(30, 9, 28, k)
        c.rect(2, 6, 10, 10, face); c.rect(11, 7, 11, 10, face); c.rect(12, 8, 12, 10, face)
        c.rect(13, 9, 29, 10, inside or face)
        c.hline(2, 10, 6, lit); c.vline(2, 7, 10, lit); c.hline(13, 29, 9, lit if not inside else shade)
        c.px(11, 7, lit); c.px(12, 8, lit)
        # the front
        c.hline(1, 30, 11, k); c.hline(1, 30, 28, k)
        c.rect(2, 12, 29, 27, face)
        c.hline(2, 29, 12, lit); c.vline(2, 12, 27, lit)
        c.hline(3, 29, 27, shade); c.vline(29, 13, 27, shade)
        return (4, 14, 27, 25)
    c.hline(1, 5, 1, k); c.px(0, 2, k); c.px(6, 2, k)
    c.hline(7, 14, 3, k); c.vline(0, 2, 14, k); c.vline(15, 4, 14, k)
    c.rect(1, 2, 5, 4, face); c.rect(6, 3, 6, 4, face); c.rect(7, 4, 14, 4, inside or face)
    c.hline(1, 5, 2, lit); c.px(6, 3, lit)
    c.hline(0, 15, 5, k); c.hline(0, 15, 14, k)
    c.rect(1, 6, 14, 13, face)
    c.hline(1, 14, 6, lit); c.vline(1, 6, 13, lit)
    c.hline(2, 14, 13, shade); c.vline(14, 7, 13, shade)
    return (2, 7, 13, 12)


def folder_open(c, paper=True):
    """An open folder, its front flap tipped towards us."""
    k = 'k'
    if c.big:
        # the back, its inside dark
        c.hline(2, 10, 5, k); c.px(1, 6, k); c.px(11, 6, k); c.px(12, 7, k)
        c.hline(13, 26, 8, k); c.vline(1, 6, 28, k); c.vline(27, 9, 14, k)
        c.rect(2, 6, 10, 14, 'y'); c.rect(11, 7, 12, 14, 'y'); c.rect(13, 9, 26, 14, 'y')
        c.rect(4, 9, 26, 27, 'o')
        c.hline(2, 10, 6, 'w'); c.vline(2, 7, 27, 'w'); c.vline(3, 8, 27, 'y')
        if paper:
            c.rect(7, 3, 23, 16, 'w'); c.frame(7, 3, 23, 17, k)
            c.vline(22, 4, 16, 's')
            for y, w in ((6, 12), (8, 10), (10, 12), (12, 9), (14, 11)):
                c.hline(9, 9 + w, y, 'g')
        # the front flap, tipped towards us
        c.shape([(6, 14), (31, 14), (27, 28), (1, 28)], 'y')
        c.line(7, 15, 29, 15, 'w')
        c.line(2, 27, 26, 27, 'o'); c.line(30, 15, 27, 26, 'o')
        return (6, 18, 24, 25)
    c.hline(1, 5, 1, k); c.px(0, 2, k); c.px(6, 2, k)
    c.hline(7, 12, 3, k); c.vline(0, 2, 14, k); c.vline(13, 4, 7, k)
    c.rect(1, 2, 5, 7, 'y'); c.rect(6, 3, 6, 7, 'y'); c.rect(7, 4, 12, 7, 'y')
    c.rect(2, 4, 12, 13, 'o')
    c.hline(1, 5, 2, 'w'); c.vline(1, 3, 13, 'w')
    if paper:
        c.rect(4, 1, 10, 7, 'w'); c.frame(4, 1, 10, 8, k)
        c.hline(5, 8, 3, 'g'); c.hline(5, 7, 5, 'g')
    c.shape([(3, 7), (15, 7), (13, 14), (0, 14)], 'y')
    c.line(4, 8, 14, 8, 'w')
    c.hline(1, 12, 13, 'o')
    return (3, 9, 11, 12)


def monitor(c, screen='n', stand=True):
    """A display: a beige case around a dark screen. Returns the screen."""
    if c.big:
        c.bevel(2, 2, 29, 22, 's')
        c.rect(5, 5, 26, 19, 'k')
        c.rect(6, 6, 25, 18, screen)
        c.hline(4, 27, 20, 's')
        c.px(26, 21, 'l')
        if stand:
            c.bevel(11, 23, 20, 25, 's', sh='g')
            c.bevel(6, 25, 25, 29, 's')
        return (6, 6, 25, 18)
    c.bevel(1, 1, 14, 11, 's')
    c.rect(3, 3, 12, 9, 'k')
    c.rect(4, 4, 11, 8, screen)
    if stand:
        c.rect(5, 12, 10, 12, 'g'); c.vline(5, 12, 12, 'k'); c.vline(10, 12, 12, 'k')
        c.bevel(2, 13, 13, 15, 's', hl='w', sh='g')
    return (4, 4, 11, 8)


def arrow(c, direction, x, y, size, fill='G', out='k'):
    """A fat arrow pointing `direction` ('l', 'r', 'u', 'd') with its tip at
    (x, y); `size` is its length."""
    h = max(2, size // 2)                     # half height of the head
    shaft = max(1, size // 4)                 # half height of the shaft
    head = max(2, size // 2)                  # length of the head
    if direction == 'r':
        pts = [(x, y), (x - head, y - h), (x - head, y - shaft), (x - size + 1, y - shaft),
               (x - size + 1, y + shaft), (x - head, y + shaft), (x - head, y + h)]
    elif direction == 'l':
        pts = [(x, y), (x + head, y - h), (x + head, y - shaft), (x + size - 1, y - shaft),
               (x + size - 1, y + shaft), (x + head, y + shaft), (x + head, y + h)]
    elif direction == 'u':
        pts = [(x, y), (x + h, y + head), (x + shaft, y + head), (x + shaft, y + size - 1),
               (x - shaft, y + size - 1), (x - shaft, y + head), (x - h, y + head)]
    else:
        pts = [(x, y), (x + h, y - head), (x + shaft, y - head), (x + shaft, y - size + 1),
               (x - shaft, y - size + 1), (x - shaft, y - head), (x - h, y - head)]
    c.shape(pts, fill, out)


# ---- emblems: small pictures on pages and folders (big, small) ------------------------------------

EMB = {
    'page': ('''
kkkkkkkk..
kwwwwwwkk.
kwggggwkwk
kwwwwwwkkk
kwgggggwwk
kwwwwwwwwk
kwggggggwk
kwwwwwwwwk
kwgggggwwk
kwwwwwwwwk
kkkkkkkkkk''', '''
kkkk.
kwwkk
kgwwk
kwwwk
kggwk
kkkkk'''),
    'down': ('''
...kkkkk...
...klllk...
...kllGk...
...kllGk...
kkkkllGkkkk
.kllllllGk.
..kllllGk..
...kllGk...
....klk....
.....k.....''', '''
.kkk.
.klk.
kkGkk
.kGk.
..k..'''),
    'up': ('''
.....k.....
....klk....
...kllGk...
..kllllGk..
.kllllllGk.
kkkkllGkkkk
...kllGk...
...kllGk...
...kllGk...
...kkkkk...''', '''
..k..
.kGk.
kkGkk
.klk.
.kkk.'''),
    'picture': ('''
kkkkkkkkkkkkkkk
kcccccccccccyck
kccccccccccyyyk
kcccccccccccyck
kccccccGcccccck
kcccccGGGccccGk
kccccGGGGGccGGk
kcccGGGGGGGGGGk
kccGGGGGGGGGGGk
kGGGGGGGGGGGGGk
kkkkkkkkkkkkkkk''', '''
kkkkkkk
kcccyck
kccGcck
kcGGGGk
kGGGGGk
kkkkkkk'''),
    'note': ('''
.....kkkkkkk
.....kbbbbbk
.....kkkkkkk
.....k.....k
.....k.....k
.....k.....k
..kkkk..kkkk
.kbbbk.kbbbk
kbbbbkkbbbbk
kbbbbkkbbbbk
.kkkk..kkkk.''', '''
..kkkk
..kkkk
..k..k
kkk.kk
kkkkkk
.k..k.'''),
    'film': ('''
kkkkkkkkkkkkkkk
kwkwkwkwkwkwkwk
kkkkkkkkkkkkkkk
knnnnnnnnnnnnnk
knnnnnwnnnnnnnk
knnnnnwwnnnnnnk
knnnnnwwwnnnnnk
knnnnnwwnnnnnnk
knnnnnwnnnnnnnk
kkkkkkkkkkkkkkk
kwkwkwkwkwkwkwk
kkkkkkkkkkkkkkk''', '''
kkkkkkk
kwkwkwk
knnwnnk
knnwwnk
knnwnnk
kwkwkwk
kkkkkkk'''),
    'star': ('''
......k......
.....krk.....
.....krk.....
....krrrk....
kkkkkrrrkkkkk
krrrrrrrrrrmk
.krrrrrrrrmk.
..krrrrrrmk..
..krrrmrrmk..
.krrmk.krrmk.
.kmmk...kmmk.
.kkk.....kkk.''', '''
...r...
..rrr..
rrrrrrr
.rrrrr.
.rr.rr.
.r...r.'''),
    'plus': ('''
...kkkk...
...klGk...
...klGk...
kkkklGkkkk
kllllllGGk
kGGGGlGGGk
kkkklGkkkk
...klGk...
...kGGk...
...kkkk...''', '''
..GG..
..GG..
GGGGGG
GGGGGG
..GG..
..GG..'''),
}


def emblem(c, key, box, dx=0, dy=0):
    """Put emblem `key` in the middle of `box`."""
    art = sprite(EMB[key][0 if c.big else 1])
    w, h = len(art[0]), len(art)
    x0, y0, x1, y1 = box
    c.paste(art, x0 + (x1 - x0 + 1 - w) // 2 + dx, y0 + (y1 - y0 + 1 - h) // 2 + dy)


# ---- the icons --------------------------------------------------------------------------------------

ICONS = []   # (name, doc, rows16, rows32)


def icon(name, doc):
    """Decorator: draws an icon at 16 and 32 with the same function."""
    def deco(f):
        s = C(16); f(s)
        b = C(32); f(b)
        ICONS.append((name, doc, s.rows(), b.rows()))
        return f
    return deco


def pair(name, doc, small, big):
    """An icon from two sprites (16 and 32 rows)."""
    s = sprite(small); b = sprite(big)
    ICONS.append((name, doc, s, b))


# -- folders and places --

@icon('Folder', 'A closed folder.')
def _(c):
    folder(c)


@icon('FolderOpen', 'An open folder.')
def _(c):
    folder_open(c)


def folder_with(key, dx=0, dy=0):
    def f(c):
        box = folder(c)
        emblem(c, key, box, dx, dy)
    return f


icon('Documents', 'The documents folder.')(folder_with('page'))
icon('Downloads', 'The downloads folder.')(folder_with('down'))
icon('Pictures', 'The pictures folder.')(folder_with('picture'))
icon('Music', 'The music folder.')(folder_with('note'))
icon('Videos', 'The videos folder.')(folder_with('film'))
icon('FolderStar', 'A favorite folder.')(folder_with('star'))
icon('FolderPlus', 'A new folder.')(folder_with('plus'))
icon('FolderUp', 'Up one folder.')(folder_with('up'))


@icon('Home', 'Home.')
def _(c):
    if c.big:
        c.bevel(5, 15, 26, 29, 'w', hl=None, sh='s')
        c.shape([(15, 2), (16, 2), (31, 16), (0, 16)], 'm')
        c.line(15, 4, 3, 15, 'r'); c.line(16, 4, 28, 15, 'm')
        c.rect(22, 4, 25, 9, 'm'); c.frame(22, 3, 25, 9, 'k'); c.hline(22, 25, 3, 'k')
        c.hline(0, 31, 16, 'k')
        c.rect(9, 20, 14, 29, 'n'); c.frame(9, 20, 14, 29, 'k'); c.px(13, 25, 'y')
        c.rect(18, 20, 23, 25, 'c'); c.frame(18, 20, 23, 25, 'k')
        c.hline(18, 23, 22, 'k'); c.vline(20, 20, 25, 'k'); c.px(19, 21, 'w')
        c.hline(5, 26, 29, 'k')
    else:
        c.rect(3, 8, 12, 14, 'w'); c.frame(3, 8, 12, 14, 'k')
        c.shape([(7, 1), (8, 1), (15, 8), (0, 8)], 'm')
        c.line(7, 2, 2, 7, 'r')
        c.rect(11, 2, 12, 5, 'm'); c.frame(11, 2, 12, 5, 'k')
        c.hline(0, 15, 8, 'k')
        c.rect(5, 10, 7, 14, 'n'); c.frame(5, 10, 7, 14, 'k')
        c.rect(9, 10, 10, 11, 'c'); c.frame(9, 10, 11, 12, 'k')


@icon('Desktop', 'The desktop.')
def _(c):
    x0, y0, x1, y1 = monitor(c, 't')
    if c.big:
        for (ix, iy, col) in [(8, 8, 'y'), (8, 13, 'w'), (14, 8, 'w')]:
            c.rect(ix, iy, ix + 3, iy + 2, col); c.frame(ix, iy, ix + 3, iy + 2, 'k')
        c.rect(6, 17, 25, 18, 's'); c.hline(6, 25, 17, 'w'); c.rect(7, 18, 9, 18, 'G')
        c.bevel(16, 10, 23, 15, 's'); c.rect(17, 11, 22, 11, 'n')
    else:
        c.px(5, 5, 'y'); c.px(5, 7, 'w'); c.px(7, 5, 'w')
        c.hline(4, 11, 8, 's')
        c.rect(9, 5, 11, 7, 's'); c.hline(9, 11, 5, 'n')


@icon('Computer', 'This computer.')
def _(c):
    if c.big:
        c.bevel(4, 1, 27, 17, 's')
        c.rect(7, 4, 24, 14, 'k'); c.rect(8, 5, 23, 13, 'n')
        c.hline(9, 15, 6, 'c'); c.hline(9, 13, 8, 'c'); c.hline(9, 11, 10, 'c')
        c.px(25, 16, 'l')
        c.bevel(12, 18, 19, 19, 's', hl=None)
        c.bevel(1, 20, 30, 29, 's')
        c.rect(19, 23, 27, 24, 'k'); c.hline(20, 26, 24, 'g')
        c.rect(4, 23, 5, 24, 'l'); c.px(4, 26, 'G'); c.px(5, 26, 'G')
        c.hline(3, 28, 27, 's')
    else:
        c.bevel(2, 0, 13, 9, 's')
        c.rect(4, 2, 11, 7, 'n'); c.hline(5, 8, 3, 'c'); c.hline(5, 7, 5, 'c')
        c.rect(6, 10, 9, 10, 'g')
        c.bevel(0, 11, 15, 15, 's')
        c.hline(9, 13, 13, 'k'); c.px(2, 13, 'l')


@icon('Drive', 'A disk.')
def _(c):
    if c.big:
        c.bevel(1, 9, 30, 23, 's')
        c.hline(2, 29, 12, 'g'); c.hline(2, 29, 13, 'w')
        c.rect(5, 16, 18, 17, 'k'); c.hline(6, 17, 17, 'g')
        c.frame(22, 16, 26, 19, 'k'); c.rect(23, 17, 25, 18, 'l')
        c.dither(5, 20, 18, 21, 'g', 's')
    else:
        c.bevel(0, 4, 15, 12, 's')
        c.hline(1, 14, 6, 'g')
        c.hline(2, 8, 9, 'k')
        c.rect(11, 8, 12, 9, 'l'); c.frame(10, 8, 13, 10, 'k')


@icon('SdCard', 'A memory card.')
def _(c):
    if c.big:
        pts = [(7, 1), (21, 1), (26, 6), (26, 30), (7, 30)]
        c.shape(pts, 'n')
        c.vline(8, 2, 29, 'b'); c.line(8, 2, 20, 2, 'b')
        for x in range(10, 23, 3):
            c.rect(x, 3, x + 1, 8, 'y'); c.hline(x, x + 1, 8, 'o')
        c.bevel(10, 13, 23, 26, 'w', hl=None, sh='s')
        c.hline(12, 21, 16, 'n'); c.hline(12, 19, 19, 'g'); c.hline(12, 21, 22, 'g')
    else:
        pts = [(3, 0), (10, 0), (12, 2), (12, 15), (3, 15)]
        c.shape(pts, 'n')
        for x in (5, 7, 9):
            c.vline(x, 1, 3, 'y')
        c.rect(5, 7, 10, 12, 'w'); c.frame(5, 7, 10, 12, 'k'); c.hline(6, 9, 9, 'n')


@icon('Phone', 'A phone.')
def _(c):
    if c.big:
        c.rect(8, 0, 23, 31, 'k')
        c.rect(9, 1, 22, 30, 'g'); c.vline(9, 1, 30, 's'); c.hline(9, 22, 1, 's')
        c.rect(10, 4, 21, 25, 'k')
        c.rect(11, 5, 20, 24, 't'); c.hline(11, 20, 5, 'n')
        for (x, y, col) in [(12, 7, 'y'), (16, 7, 'w'), (12, 12, 'w'), (16, 12, 'l')]:
            c.rect(x, y, x + 2, y + 2, col); c.frame(x, y, x + 2, y + 2, 'k')
        c.rect(14, 27, 17, 28, 's'); c.frame(14, 27, 17, 28, 'k')
        c.hline(14, 17, 2, 'k')
    else:
        c.rect(4, 0, 11, 15, 'k')
        c.rect(5, 1, 10, 14, 'g')
        c.rect(5, 2, 10, 11, 't')
        c.px(6, 3, 'y'); c.px(8, 3, 'w'); c.px(6, 5, 'w'); c.px(8, 5, 'l')
        c.hline(7, 8, 13, 's')


def wastebasket(c, full):
    if c.big:
        pts = [(5, 9), (26, 9), (24, 30), (7, 30)]
        c.shape(pts, 's')
        for i, x in enumerate((9, 13, 17, 21)):
            lean = (i - 1.5) * 0.6
            c.line(x, 11, int(round(x + lean)), 28, 'g')
            c.line(x + 1, 11, int(round(x + 1 + lean)), 28, 'w')
        c.bevel(3, 6, 28, 9, 's')
        c.bevel(12, 3, 19, 6, 's', sh=None); c.rect(14, 5, 17, 6, 'k')
        if full:
            pts = [(6, 6), (8, 1), (12, 3), (15, 0), (20, 2), (24, 0), (27, 5)]
            c.shape(pts + [(26, 6)], 'w')
            c.line(10, 3, 12, 5, 'g'); c.line(19, 2, 21, 4, 'g')
            c.rect(8, 3, 10, 5, 'y'); c.frame(7, 2, 10, 5, 'k')
            c.bevel(3, 6, 28, 9, 's')
    else:
        pts = [(3, 5), (12, 5), (11, 15), (4, 15)]
        c.shape(pts, 's')
        for x in (5, 7, 9):
            c.vline(x, 6, 14, 'g')
        c.bevel(1, 3, 14, 5, 's', sh=None)
        c.hline(6, 9, 2, 'k')
        if full:
            c.shape([(2, 3), (4, 0), (7, 1), (10, 0), (13, 3)], 'w')
            c.px(5, 1, 'y'); c.bevel(1, 3, 14, 5, 's', sh=None)


@icon('Trash', 'The trash, empty.')
def _(c):
    wastebasket(c, False)


@icon('TrashFull', 'The trash, with something in it.')
def _(c):
    wastebasket(c, True)


# -- files --

@icon('File', 'A file.')
def _(c):
    page(c)


@icon('Text', 'A text file.')
def _(c):
    box = page(c)
    lines_in(c, box, 'g', 2 if c.big else 2)


@icon('Markdown', 'A Markdown document.')
def _(c):
    page(c)
    if c.big:
        c.paste('''
kkkkkkkkkkkkkk
kwwwwwwwwwwwwk
kwnwwwnwwwnwwk
kwnnwnnwwwnwwk
kwnwnwnwwwnwwk
kwnwwwnwnnnnnk
kwnwwwnwwnnnwk
kwnwwwnwwwnwwk
kwwwwwwwwwwwwk
kkkkkkkkkkkkkk''', 9, 11)
        lines_in(c, (9, 23, 21, 27), 'g')
    else:
        c.paste('''
n...n...
nn.nn...
n.n.n.n.
n...n.n.
n...nnnn
.....nn.''', 4, 6)


@icon('Code', 'Source code.')
def _(c):
    page(c)
    if c.big:
        c.paste('''
...b.....r.....b...
..bb....rr.....bb..
.bb.....r.......bb.
bb.....rr........bb
.bb....r........bb.
..bb..rr.......bb..
...b..r........b...''', 7, 12)
        lines_in(c, (9, 22, 21, 27), 'g')
    else:
        c.paste('''
.b..r.b.
b..r...b
.b.r..b.''', 4, 8)


def globe(c, cx, cy, r):
    """The earth: blue sea, green land, a shine at the top left."""
    c.disc(cx, cy, r, 'b')
    k = r / 14.5
    land = c.layer()
    for (ex, ey, rx, ry) in ((-6, -4, 3.2, 4.2), (-4.5, 4, 2.6, 4.6), (4, -6, 5.5, 2.6),
                             (2.5, 2, 3, 4.6), (8, -1, 2.4, 2.2)):
        land.ellipse(cx + ex * k, cy + ey * k, max(0.9, rx * k), max(0.9, ry * k), 'G')
    for y in range(c.n):
        for x in range(c.n):
            if land.g[y][x] == 'G' and c.g[y][x] == 'b':
                c.g[y][x] = 'G'
    if r > 8:
        c.arc(cx, cy, r - 3, 1.2, -165, -115, 'c')


@icon('Web', 'A web page.')
def _(c):
    page(c)
    if c.big:
        globe(c, 15.5, 19, 8)
    else:
        globe(c, 7.5, 10.5, 3.6)


@icon('Data', 'Data (JSON, XML, YAML...).')
def _(c):
    page(c)
    if c.big:
        c.paste('''
..ttt..........ttt..
.tt..............tt.
.t................t.
.t...nn....nnnn...t.
.t................t.
tt...nnnn..nn.....tt
.t................t.
.t...nnn...nnnnn..t.
.t................t.
.tt..............tt.
..ttt..........ttt..''', 6, 12)
    else:
        c.paste('''
.tt..tt.
t......t
.t.nn.t.
t......t
.tt..tt.''', 4, 7)


@icon('Sheet', 'A spreadsheet or table.')
def _(c):
    page(c)
    if c.big:
        c.rect(8, 10, 23, 26, 'w'); c.rect(8, 10, 23, 12, 'G')
        for y in (10, 13, 16, 19, 22, 26):
            c.hline(8, 23, y, 'k')
        for x in (8, 12, 23):
            c.vline(x, 10, 26, 'k')
        c.vline(17, 13, 26, 'g')
        c.rect(13, 20, 16, 21, 'y')
    else:
        c.rect(4, 6, 11, 13, 'w'); c.rect(4, 6, 11, 7, 'G')
        for y in (9, 11):
            c.hline(4, 11, y, 'g')
        c.vline(6, 8, 13, 'g')
        c.frame(4, 6, 11, 13, 'k')


@icon('Document', 'A formatted document.')
def _(c):
    page(c)
    if c.big:
        c.rect(8, 9, 18, 11, 'n')
        lines_in(c, (8, 14, 23, 16), 'g')
        c.rect(16, 18, 23, 24, 'c'); c.frame(16, 18, 23, 24, 'n'); c.rect(17, 22, 22, 23, 'G')
        c.hline(8, 14, 18, 'g'); c.hline(8, 13, 20, 'g'); c.hline(8, 14, 22, 'g'); c.hline(8, 12, 24, 'g')
        c.hline(8, 22, 27, 'g')
    else:
        c.hline(5, 9, 6, 'n'); c.hline(5, 9, 7, 'n')
        c.hline(5, 10, 9, 'g'); c.rect(8, 11, 10, 13, 'c'); c.hline(5, 6, 11, 'g'); c.hline(5, 6, 13, 'g')


@icon('Slides', 'A presentation.')
def _(c):
    page(c)
    if c.big:
        c.bevel(7, 11, 24, 23, 'w', hl=None, sh='s')
        c.rect(8, 12, 23, 13, 'm')
        c.disc(12.5, 18.5, 3.5, 'r')
        c.rect(17, 18, 18, 21, 'G'); c.rect(20, 16, 21, 21, 'b')
        c.vline(15, 24, 26, 'k'); c.hline(12, 19, 27, 'k')
    else:
        c.rect(4, 6, 11, 11, 'w'); c.frame(4, 6, 11, 11, 'k'); c.hline(5, 10, 7, 'm')
        c.px(6, 9, 'r'); c.px(6, 10, 'r'); c.px(5, 9, 'r')
        c.vline(9, 9, 10, 'b'); c.vline(8, 10, 10, 'G')
        c.vline(7, 12, 13, 'k')


@icon('Pdf', 'A PDF document.')
def _(c):
    page(c)
    if c.big:
        lines_in(c, (8, 10, 22, 16), 'g')
        c.rect(3, 19, 23, 27, 'm'); c.frame(3, 19, 23, 27, 'k')
        c.paste('''
www..ww...www
w.w.w.w..w...
www.w..w.ww..
w...w.w..w...
w...ww...w...''', 7, 21)
    else:
        c.hline(5, 9, 6, 'g'); c.hline(5, 8, 8, 'g')
        c.rect(1, 10, 11, 14, 'm'); c.frame(1, 10, 11, 14, 'k')
        c.hline(3, 9, 12, 'w')


@icon('Image', 'A picture.')
def _(c):
    page(c)
    if c.big:
        c.paste(EMB['picture'][0], 9, 13)
    else:
        c.paste(EMB['picture'][1], 4, 7)


@icon('Audio', 'Sound or music.')
def _(c):
    page(c)
    if c.big:
        c.paste(EMB['note'][0], 9, 13)
    else:
        c.paste(EMB['note'][1], 5, 7)


@icon('Video', 'A video.')
def _(c):
    page(c)
    if c.big:
        c.paste(EMB['film'][0], 8, 12)
    else:
        c.paste(EMB['film'][1], 4, 7)


@icon('Archive', 'A zip (or other) archive.')
def _(c):
    page(c)
    if c.big:
        for y in range(3, 20, 2):
            c.hline(14, 15, y, 'k'); c.hline(16, 17, y + 1, 'k')
        c.rect(12, 20, 19, 27, 'y'); c.frame(12, 20, 19, 27, 'k')
        c.hline(13, 18, 21, 'w'); c.vline(13, 21, 26, 'w'); c.rect(14, 23, 17, 24, 'k')
    else:
        for y in range(1, 9, 2):
            c.px(7, y, 'k'); c.px(8, y + 1, 'k')
        c.rect(6, 10, 9, 13, 'y'); c.frame(6, 10, 9, 13, 'k')


@icon('App', 'A program (exe, apk...).')
def _(c):
    if c.big:
        c.bevel(2, 4, 29, 27, 's')
        c.rect(3, 5, 28, 9, 'n'); c.hline(3, 28, 10, 'k')
        c.bevel(4, 6, 7, 8, 's', sh=None)
        c.bevel(24, 6, 27, 8, 's', sh=None)
        c.rect(3, 11, 28, 26, 'w')
        c.rect(5, 13, 9, 17, 'r'); c.frame(5, 13, 9, 17, 'k')
        c.rect(5, 20, 9, 24, 'G'); c.frame(5, 20, 9, 24, 'k')
        c.hline(12, 25, 14, 'b'); c.hline(12, 22, 16, 'g')
        c.hline(12, 25, 21, 'b'); c.hline(12, 20, 23, 'g')
    else:
        c.bevel(0, 2, 15, 14, 's')
        c.rect(1, 3, 14, 5, 'n'); c.hline(1, 14, 6, 'k')
        c.px(2, 4, 's'); c.px(13, 4, 's')
        c.rect(1, 7, 14, 13, 'w')
        c.rect(3, 8, 4, 9, 'r'); c.rect(3, 11, 4, 12, 'G')
        c.hline(6, 12, 8, 'b'); c.hline(6, 11, 11, 'b')


@icon('Script', 'A shell script.')
def _(c):
    page(c)
    if c.big:
        c.rect(7, 11, 24, 25, 'k')
        c.paste('''
l.....
ll....
.ll...
ll....
l..lll''', 9, 14)
        c.hline(9, 20, 22, 'G')
    else:
        c.rect(4, 6, 11, 12, 'k')
        c.paste('''
l...
.l..
l.ll''', 5, 7)


@icon('Font', 'A font.')
def _(c):
    page(c)
    if c.big:
        c.paste('''
.....nn.....
.....nn.....
....nnnn....
....n.nn....
...nn..nn...
...nn..nn...
..nnnnnnnn..
..nn....nn..
.nn......nn.
nnnn....nnnn''', 10, 13)
    else:
        c.paste('''
..n..
.n.n.
.nnn.
n...n
n...n''', 5, 7)


# -- message box signs --

def sign(c, col, big_rows, small_rows):
    if c.big:
        c.disc(16, 16, 14, col)
        art = sprite(big_rows)
        c.paste(art, 16 - len(art[0]) // 2, 16 - len(art) // 2)
    else:
        c.disc(8, 8, 7.5, col)
        art = sprite(small_rows)
        c.paste(art, 8 - (len(art[0]) + 1) // 2, 8 - (len(art) + 1) // 2)


@icon('Info', 'Information.')
def _(c):
    sign(c, 'b', '''
..ww.
..ww.
.....
wwww.
..ww.
..ww.
..ww.
..ww.
..ww.
.wwww''', '''
.w.
...
ww.
.w.
.w.
www''')


@icon('Question', 'A question.')
def _(c):
    sign(c, 'b', '''
.wwwww.
ww...ww
.....ww
....ww.
...ww..
...ww..
.......
...ww..
...ww..''', '''
.ww.
w..w
..w.
.w..
....
.w..''')


@icon('Error', 'An error, a stop.')
def _(c):
    sign(c, 'r', '''
ww.....ww
www...www
.www.www.
..wwwww..
...www...
..wwwww..
.www.www.
www...www
ww.....ww''', '''
w...w
.w.w.
..w..
.w.w.
w...w''')


@icon('Warning', 'A warning.')
def _(c):
    if c.big:
        c.shape([(15, 1), (16, 1), (31, 29), (0, 29)], 'y')
        c.rect(14, 10, 17, 20, 'k'); c.rect(15, 21, 16, 21, 'k')
        c.rect(14, 23, 17, 26, 'k')
    else:
        c.shape([(7, 0), (8, 0), (15, 14), (0, 14)], 'y')
        c.vline(7, 4, 9, 'k'); c.vline(8, 4, 9, 'k'); c.rect(7, 11, 8, 12, 'k')


# -- actions --

@icon('New', 'New.')
def _(c):
    box = page(c)
    if c.big:
        c.paste('''
.....k.....
....kyk....
..k.kyk.k..
...kyyyk...
.kkyywyykk.
kyyywwwyyyk
.kkyywyykk.
...kyyyk...
..k.kyk.k..
....kyk....
.....k.....''', 20, 0)
    else:
        c.paste('''
..k..
.kyk.
kyyyk
.kyk.
..k..''', 10, 0)


@icon('Open', 'Open.')
def _(c):
    folder_open(c, paper=False)
    a = c.layer()
    if c.big:
        a.arc(23, 13, 7, 3, -180, -40, 'l')
        a.shape([(26, 3), (31, 10), (24, 12)], 'l', 'l')
    else:
        a.arc(12, 6.5, 3.5, 1.6, -180, -40, 'l')
        a.shape([(13, 0), (15, 4), (11, 5)], 'l', 'l')
    a.outlined()
    c.over(a)


@icon('Save', 'Save.')
def _(c):
    if c.big:
        c.shape([(2, 2), (27, 2), (30, 5), (30, 29), (2, 29)], 'n')
        c.vline(3, 3, 28, 'b'); c.hline(3, 26, 3, 'b')
        c.bevel(7, 3, 24, 14, 'w', hl=None, sh='s')
        c.hline(9, 22, 6, 'g'); c.hline(9, 22, 8, 'g'); c.hline(9, 18, 10, 'g')
        c.bevel(8, 18, 24, 28, 's')
        c.rect(19, 20, 22, 26, 'n'); c.frame(19, 20, 22, 26, 'k')
    else:
        c.shape([(1, 1), (13, 1), (14, 2), (14, 14), (1, 14)], 'n')
        c.rect(4, 2, 11, 6, 'w'); c.frame(4, 1, 11, 6, 'k'); c.hline(5, 10, 3, 'g')
        c.rect(4, 9, 11, 14, 's'); c.frame(4, 9, 11, 14, 'k'); c.rect(9, 10, 10, 13, 'n')


@icon('Cut', 'Cut.')
def _(c):
    blades = c.layer()
    if c.big:
        blades.stroke(20.5, 1, 11, 21, 3, 's')
        blades.stroke(11.5, 1, 21, 21, 3, 'w')
        blades.outlined()
        blades.px(16, 11, 'k')
        rings = c.layer()
        rings.ring(9.5, 24.5, 3, 5.5, 'r')
        rings.ring(22.5, 24.5, 3, 5.5, 'r')
        rings.outlined()
        rings.lit('r', None, 'm')
    else:
        blades.stroke(10.5, 0, 6, 10, 1.4, 's')
        blades.stroke(5.5, 0, 10, 10, 1.4, 'w')
        blades.outlined()
        rings = c.layer()
        rings.ring(4.5, 12.5, 1.2, 2.8, 'r')
        rings.ring(11.5, 12.5, 1.2, 2.8, 'r')
        rings.outlined()
    c.over(blades).over(rings)


def mini_page(c, x0, y0, x1, y1, ear, lines=True):
    """A small sheet of paper with a folded corner (for Copy, Paste...)."""
    for y in range(y0, y1 + 1):
        for x in range(x0, x1 + 1):
            if y - y0 < ear and x > x1 - ear + (y - y0):
                continue
            c.px(x, y, 'w')
    c.vline(x0, y0, y1, 'k'); c.hline(x0, x1, y1, 'k')
    c.vline(x1, y0 + ear, y1, 'k'); c.hline(x0, x1 - ear, y0, 'k')
    c.line(x1 - ear, y0, x1, y0 + ear, 'k')
    for y in range(y0 + 1, y0 + ear):
        for x in range(x1 - ear + 1, x1 - ear + (y - y0)):
            c.px(x, y, 's')
    c.vline(x1 - ear, y0, y0 + ear, 'k'); c.hline(x1 - ear, x1, y0 + ear, 'k')
    if lines:
        step = 3 if c.big else 2
        for i, y in enumerate(range(y0 + ear + (2 if c.big else 1), y1 - 1, step)):
            c.hline(x0 + 2, x1 - 2 - (i % 3) * (2 if c.big else 1), y, 'g')


@icon('Copy', 'Copy.')
def _(c):
    if c.big:
        mini_page(c, 2, 1, 18, 22, 5)
        mini_page(c, 12, 9, 29, 30, 5)
    else:
        mini_page(c, 1, 0, 9, 10, 3)
        mini_page(c, 6, 5, 14, 15, 3)


@icon('Paste', 'Paste.')
def _(c):
    if c.big:
        c.bevel(2, 4, 21, 30, 'o', hl='y', sh='m')
        c.bevel(7, 1, 16, 6, 's')
        c.rect(9, 2, 14, 3, 'k')
        c.rect(12, 11, 29, 30, 'w'); c.frame(12, 11, 29, 30, 'k')
        for y in range(15, 28, 3):
            c.hline(15, 26 - (y % 2) * 3, y, 'g')
    else:
        c.bevel(1, 2, 10, 15, 'o', hl='y', sh=None)
        c.rect(4, 1, 7, 3, 's'); c.frame(4, 1, 7, 3, 'k')
        c.rect(6, 6, 14, 15, 'w'); c.frame(6, 6, 14, 15, 'k')
        c.hline(8, 12, 9, 'g'); c.hline(8, 11, 11, 'g'); c.hline(8, 12, 13, 'g')


@icon('Print', 'Print.')
def _(c):
    if c.big:
        c.rect(8, 2, 23, 12, 'w'); c.frame(8, 2, 23, 12, 'k')
        c.hline(10, 21, 5, 'g'); c.hline(10, 18, 7, 'g'); c.hline(10, 20, 9, 'g')
        c.bevel(2, 11, 29, 23, 's')
        c.rect(6, 15, 25, 16, 'k')
        c.rect(23, 19, 26, 20, 'l'); c.frame(22, 18, 27, 21, 'k')
        c.bevel(5, 23, 26, 28, 'w', sh='s')
        c.hline(7, 22, 25, 'g')
    else:
        c.rect(4, 0, 11, 5, 'w'); c.frame(4, 0, 11, 5, 'k'); c.hline(5, 9, 2, 'g')
        c.bevel(0, 5, 15, 11, 's')
        c.hline(3, 12, 7, 'k'); c.px(12, 9, 'l')
        c.rect(3, 11, 12, 14, 'w'); c.frame(3, 11, 12, 14, 'k'); c.hline(5, 10, 12, 'g')


@icon('Help', 'Help.')
def _(c):
    if c.big:
        c.shape([(2, 3), (29, 3), (29, 22), (13, 22), (6, 29), (8, 22), (2, 22)], 'w')
        c.paste('''
..kkkkk..
.kbbbbbk.
kbbk.kbbk
.kk..kbbk
....kbbk.
...kbbk..
...kbbk..
....kk...
...kbbk..
...kbbk..
....kk...''', 11, 7)
        c.recolor('k', 'n', (11, 7, 19, 17))
    else:
        c.shape([(0, 1), (15, 1), (15, 11), (7, 11), (3, 15), (4, 11), (0, 11)], 'w')
        c.paste('''
.bbb.
b...b
...b.
..b..
.....
..b..''', 5, 3)


def _shade_arrow(c):
    """Light lime arrows get a green lower half for some depth."""
    mid = c.n // 2
    for y in range(mid + 1, c.n):
        for x in range(c.n):
            if c.get(x, y) == 'l' and c.get(x, y + 1) in ('k', '.'):
                c.px(x, y, 'G')
    for y in range(c.n):
        for x in range(c.n):
            if c.get(x, y) == 'l' and c.get(x + 1, y) in ('k',) and y > mid - 3:
                c.px(x, y, 'G')


@icon('Back', 'Back.')
def _(c):
    if c.big:
        arrow(c, 'l', 2, 16, 27, 'l')
    else:
        arrow(c, 'l', 1, 8, 14, 'l')
    _shade_arrow(c)


@icon('Forward', 'Forward.')
def _(c):
    if c.big:
        arrow(c, 'r', 29, 16, 27, 'l')
    else:
        arrow(c, 'r', 14, 8, 14, 'l')
    _shade_arrow(c)


@icon('Up', 'Up.')
def _(c):
    if c.big:
        arrow(c, 'u', 16, 2, 28, 'l')
    else:
        arrow(c, 'u', 8, 1, 14, 'l')
    _shade_arrow(c)


@icon('Refresh', 'Refresh.')
def _(c):
    a = c.layer()
    if c.big:
        a.arc(16, 16, 10, 4.4, -165, -25, 'l')
        a.shape([(22, 11), (31, 11), (26, 18)], 'l', 'l')
        a.arc(16, 16, 10, 4.4, 15, 155, 'G')
        a.shape([(1, 21), (10, 21), (5, 14)], 'G', 'G')
    else:
        a.arc(8, 8, 5, 2.2, -165, -25, 'l')
        a.shape([(11, 6), (15, 6), (13, 9)], 'l', 'l')
        a.arc(8, 8, 5, 2.2, 15, 155, 'G')
        a.shape([(0, 9), (4, 9), (2, 6)], 'G', 'G')
    a.outlined()
    c.over(a)


def curved(c, right):
    """Undo / redo: an arrow bending back over the top."""
    a = c.layer()
    if c.big:
        a.arc(17, 18, 9, 5, -180, 0, 'l')
        a.rect(0, 18, 31, 31, '.')
        a.shape([(1, 17), (15, 17), (8, 26)], 'l', 'l')
        a.stroke(24, 18, 24, 22, 5, 'l')
    else:
        a.arc(9, 9, 4.5, 2.6, -180, 0, 'l')
        a.rect(0, 9, 15, 15, '.')
        a.shape([(1, 8), (8, 8), (4.5, 12.5)], 'l', 'l')
        a.stroke(13.5, 9, 13.5, 11, 2.6, 'l')
    a.outlined()
    a.lit('l', None, 'G')
    if right:
        for row in a.g:
            row.reverse()
    c.over(a)


@icon('Delete', 'Delete.')
def _(c):
    x = c.layer()
    if c.big:
        x.stroke(5, 5, 27, 27, 5.2, 'r')
        x.stroke(27, 5, 5, 27, 5.2, 'r')
    else:
        x.stroke(3, 3, 13, 13, 2.6, 'r')
        x.stroke(13, 3, 3, 13, 2.6, 'r')
    x.outlined()
    x.lit('r', None, 'm')
    c.over(x)


@icon('Rename', 'Rename.')
def _(c):
    if c.big:
        c.rect(1, 9, 30, 22, 'k'); c.rect(2, 10, 29, 21, 'w')
        c.hline(2, 29, 10, 'g'); c.vline(2, 10, 21, 'g')
        c.rect(4, 12, 19, 19, 'n')
        c.paste('''
.ww...w....
...w..w....
.www..www..
w..w..w..w.
.www..www..''', 6, 13)
        c.vline(23, 6, 25, 'k'); c.hline(21, 25, 6, 'k'); c.hline(21, 25, 25, 'k')
    else:
        c.rect(0, 4, 15, 11, 'k'); c.rect(1, 5, 14, 10, 'w')
        c.rect(2, 6, 9, 9, 'n'); c.hline(3, 8, 7, 'w')
        c.vline(12, 2, 13, 'k'); c.hline(11, 13, 2, 'k'); c.hline(11, 13, 13, 'k')


@icon('Properties', 'Properties.')
def _(c):
    if c.big:
        c.bevel(3, 2, 26, 29, 'w', hl=None, sh='s')
        c.rect(4, 3, 25, 6, 'n')
        for i, y in enumerate((10, 15, 20, 25)):
            c.frame(6, y - 1, 9, y + 2, 'k')
            if i != 2:
                c.paste('''
....G
...G.
G.G..
.G...''', 6, y - 2)
            c.hline(12, 23 - i % 2 * 4, y, 'g')
    else:
        c.bevel(2, 1, 13, 14, 'w', hl=None, sh=None)
        c.hline(3, 12, 2, 'n')
        for y in (5, 8, 11):
            c.rect(4, y, 5, y + 1, 'G' if y != 8 else 'w'); c.frame(4, y, 5, y + 1, 'k')
            c.hline(7, 11, y + 1, 'g')


@icon('Search', 'Search.')
def _(c):
    if c.big:
        c.shape([(18, 20), (21, 17), (30, 26), (27, 29)], 'm')
        c.line(21, 19, 28, 26, 'r')
        c.disc(12.5, 12.5, 10.5, 's')
        c.disc(12.5, 12.5, 8, 'c')
        c.ellipse(9.5, 9.5, 2.5, 1.8, 'w')
    else:
        c.shape([(9, 11), (11, 9), (15, 13), (13, 15)], 'm')
        c.disc(6.5, 6.5, 5.5, 's')
        c.disc(6.5, 6.5, 4, 'c')
        c.px(4, 4, 'w'); c.px(5, 4, 'w'); c.px(4, 5, 'w')


@icon('Details', 'A details (list) view.')
def _(c):
    if c.big:
        for i, y in enumerate((3, 10, 17, 24)):
            c.rect(2, y, 6, y + 4, 'y'); c.frame(2, y, 6, y + 4, 'k'); c.hline(3, 5, y + 1, 'w')
            c.hline(9, 29 - (i % 2) * 6, y + 2, 'n'); c.hline(9, 23 - (i % 3) * 3, y + 3, 'g')
    else:
        for i, y in enumerate((1, 6, 11)):
            c.rect(0, y, 2, y + 2, 'y'); c.frame(0, y, 2, y + 2, 'k')
            c.hline(4, 15 - (i % 2) * 3, y + 1, 'n')


@icon('Icons', 'An icons view.')
def _(c):
    if c.big:
        for (x, y) in ((3, 2), (18, 2), (3, 17), (18, 17)):
            c.bevel(x + 2, y, x + 9, y + 7, 'y', sh='o')
            c.hline(x, x + 11, y + 10, 'n'); c.hline(x + 2, x + 9, y + 12, 'g')
    else:
        for (x, y) in ((1, 1), (9, 1), (1, 9), (9, 9)):
            c.rect(x, y, x + 5, y + 3, 'y'); c.frame(x, y, x + 5, y + 3, 'k')
            c.hline(x, x + 5, y + 5, 'n')


@icon('Star', 'A star, a favorite.')
def _(c):
    if c.big:
        pts = []
        for i in range(10):
            a = -math.pi / 2 + i * math.pi / 5
            r = 15 if i % 2 == 0 else 6.5
            pts.append((15.5 + r * math.cos(a), 16.5 + r * math.sin(a)))
        c.poly([(round(x), round(y)) for x, y in pts], 'y')
        c.outline([(round(x), round(y)) for x, y in pts], 'k')
        for y in range(17, 32):
            for x in range(16, 32):
                if c.get(x, y) == 'y' and c.get(x + 1, y) == 'k':
                    c.px(x, y, 'o')
    else:
        c.paste('''
.......k.......
......kyk......
......kyk......
.....kyyyk.....
kkkkkkyyykkkkkk
kyyyyyyyyyyyyok
.kyyyyyyyyyyok.
..kyyyyyyyyok..
...kyyyyyyok...
...kyyyoyyok...
..kyyok.kyyok..
..kyok...kyok..
.kook.....kook.
.kk.........kk.''', 0, 1)


@icon('Share', 'Share.')
def _(c):
    if c.big:
        c.shape([(2, 14), (8, 14), (8, 25), (23, 25), (23, 20), (29, 20), (29, 30), (2, 30)], 's')
        c.hline(3, 7, 15, 'w'); c.vline(3, 15, 29, 'w')
        c.shape([(10, 22), (10, 14), (14, 9), (20, 9), (20, 4), (29, 11), (20, 18), (20, 13),
                 (15, 13), (13, 16), (13, 22)], 'l')
        _shade_arrow(c)
    else:
        c.shape([(0, 7), (3, 7), (3, 12), (11, 12), (11, 10), (14, 10), (14, 15), (0, 15)], 's')
        c.shape([(5, 11), (5, 7), (8, 4), (10, 4), (10, 1), (15, 5), (10, 9), (10, 6), (8, 6),
                 (7, 8), (7, 11)], 'l')


@icon('Select', 'Select.')
def _(c):
    if c.big:
        for i in range(2, 30):
            if i % 3 != 2:
                c.px(i, 2, 'k'); c.px(i, 29, 'k'); c.px(2, i, 'k'); c.px(29, i, 'k')
        c.paste('''
k.........
kk........
kwk.......
kwwk......
kwwwk.....
kwwwwk....
kwwwwwk...
kwwwwwwk..
kwwwwwwwk.
kwwwwkkkkk
kwwkwwk...
kwk.kwwk..
kk..kwwk..
k....kwwk.
.....kwwk.
......kk..''', 12, 10)
    else:
        for i in range(0, 15):
            if i % 2 == 0:
                c.px(i, 0, 'k'); c.px(i, 14, 'k'); c.px(0, i, 'k'); c.px(14, i, 'k')
        c.paste('''
k.....
kk....
kwk...
kwwk..
kwwwk.
kwkkkk
kk.kwk
k...kk''', 6, 5)


@icon('Undo', 'Undo.')
def _(c):
    curved(c, False)


@icon('Redo', 'Redo.')
def _(c):
    curved(c, True)


@icon('Settings', 'Settings.')
def _(c):
    g = c.layer()
    n = c.n
    cx = cy = n / 2
    body, tip, half, hole = (10.2, 14.6, 2.3, 4.2) if c.big else (4.9, 7.9, 1.05, 1.6)
    teeth = 8
    for y in range(n):
        for x in range(n):
            dx, dy = x + 0.5 - cx, y + 0.5 - cy
            d = math.hypot(dx, dy)
            on = d <= body
            for k in range(teeth):
                a = k * 2 * math.pi / teeth
                along = dx * math.cos(a) + dy * math.sin(a)
                across = -dx * math.sin(a) + dy * math.cos(a)
                if 0 < along <= tip and abs(across) <= half:
                    on = True
            if on and d > hole:
                g.px(x, y, 's')
    if not c.big:
        # at 16 x 16 the teeth are drawn as blocks, two pixels wide
        g = c.layer()
        g.ellipse(8, 8, 4.7, 4.7, 's')
        g.rect(6, 1, 9, 14, 's'); g.rect(1, 6, 14, 9, 's')
        for (x, y) in ((2, 2), (12, 2), (2, 12), (12, 12)):
            g.rect(x, y, x + 1, y + 1, 's')
        g.px(4, 4, 's'); g.px(11, 4, 's'); g.px(4, 11, 's'); g.px(11, 11, 's')
        g.rect(7, 7, 8, 8, '.')
    g.outlined()
    g.lit('s', 'w', 'g')
    c.over(g)
    if c.big:
        c.ring(cx, cy, hole, hole + 1, 'k')


@icon('Tiles', 'A tiles view.')
def _(c):
    if c.big:
        for y in (2, 12, 22):
            c.bevel(2, y, 9, y + 7, 'y', sh='o')
            c.hline(12, 28, y + 2, 'n'); c.hline(12, 24, y + 4, 'g'); c.hline(12, 20, y + 6, 'g')
    else:
        for y in (1, 6, 11):
            c.rect(0, y, 3, y + 3, 'y'); c.frame(0, y, 3, y + 3, 'k')
            c.hline(5, 14, y + 1, 'n'); c.hline(5, 11, y + 3, 'g')


@icon('Tree', 'A folder tree.')
def _(c):
    def mini(x, y):
        if c.big:
            c.rect(x + 1, y, x + 3, y, 'k'); c.px(x, y + 1, 'k'); c.px(x + 4, y + 1, 'k')
            c.hline(x + 5, x + 7, y + 1, 'k')
            c.rect(x, y + 2, x + 8, y + 6, 'y'); c.frame(x, y + 2, x + 8, y + 6, 'k')
            c.rect(x + 1, y + 1, x + 3, y + 1, 'y')
            c.hline(x + 1, x + 7, y + 3, 'w')
        else:
            c.rect(x, y, x + 4, y + 3, 'y'); c.frame(x, y, x + 4, y + 3, 'k'); c.px(x + 1, y + 1, 'w')
    if c.big:
        mini(1, 1)
        for y in range(9, 27, 2):
            c.px(5, y, 'g')
        for y in (9, 18, 25):
            for xx in range(6, 11, 2):
                c.px(xx, y + 4, 'g')
            mini(11, y)
    else:
        mini(0, 0)
        for y in range(4, 13, 2):
            c.px(2, y, 'g')
        for y in (5, 11):
            c.px(4, y + 2, 'g')
            mini(6, y)


@icon('Preview', 'The preview pane.')
def _(c):
    if c.big:
        c.bevel(1, 3, 30, 28, 's')
        c.rect(2, 4, 29, 7, 'n'); c.hline(2, 29, 8, 'k')
        c.rect(2, 9, 29, 27, 'w')
        c.vline(15, 9, 27, 'k'); c.vline(16, 9, 27, 's')
        for y in (11, 14, 17, 20, 23):
            c.rect(4, y, 5, y + 1, 'y'); c.hline(7, 13, y + 1, 'g')
        c.rect(18, 11, 28, 19, 'c'); c.frame(18, 11, 28, 19, 'k')
        c.shape([(19, 18), (22, 14), (25, 18)], 'G', 'G'); c.rect(25, 12, 26, 13, 'y')
        c.hline(18, 27, 22, 'g'); c.hline(18, 25, 24, 'g')
    else:
        c.rect(0, 1, 15, 14, 'w'); c.frame(0, 1, 15, 14, 'k')
        c.rect(1, 2, 14, 3, 'n'); c.hline(1, 14, 4, 'k')
        c.vline(7, 4, 14, 'k')
        for y in (6, 9, 12):
            c.hline(2, 5, y, 'g')
        c.rect(9, 6, 13, 9, 'c'); c.frame(9, 6, 13, 9, 'k'); c.hline(9, 13, 11, 'g')


@icon('Columns', 'A column view: each folder of the way a column.')
def _(c):
    if c.big:
        c.bevel(1, 3, 30, 28, 's')
        c.rect(2, 4, 29, 27, 'w')
        for x in (11, 20):
            c.vline(x, 4, 27, 'g')
        for x0 in (3, 12):
            for i, y in enumerate((6, 10, 14, 18, 22)):
                sel = (x0 == 3 and i == 1) or (x0 == 12 and i == 2)
                if sel:
                    c.rect(x0, y - 1, x0 + 7, y + 2, 'n')
                c.rect(x0 + 1, y, x0 + 2, y + 1, 'y')
                c.hline(x0 + 4, x0 + 6, y + 1, 'w' if sel else 'g')
        # the third column: a picture of the file picked
        c.rect(22, 7, 28, 15, 'c'); c.frame(22, 7, 28, 15, 'k'); c.rect(23, 12, 27, 14, 'G')
        c.hline(22, 28, 18, 'g'); c.hline(22, 26, 20, 'g')
    else:
        c.rect(0, 1, 15, 14, 'w'); c.frame(0, 1, 15, 14, 'k')
        c.vline(5, 2, 13, 'g'); c.vline(10, 2, 13, 'g')
        for y in (3, 6, 9, 12):
            c.hline(1, 4, y, 'n' if y == 6 else 'g')
            c.hline(6, 9, y, 'n' if y == 9 else 'g')
        c.rect(11, 3, 14, 6, 'c'); c.hline(11, 14, 9, 'g')


@icon('TwoPanes', 'Two panes side by side.')
def _(c):
    if c.big:
        c.bevel(1, 3, 30, 28, 's')
        c.rect(2, 4, 29, 7, 'n'); c.hline(2, 29, 8, 'k')
        c.rect(2, 9, 29, 27, 'w')
        c.vline(15, 9, 27, 'k'); c.vline(16, 9, 27, 'k')
        for x0 in (4, 18):
            for y in (11, 15, 19, 23):
                c.rect(x0, y, x0 + 1, y + 1, 'y'); c.hline(x0 + 3, x0 + 9, y + 1, 'g')
    else:
        c.rect(0, 1, 15, 14, 'w'); c.frame(0, 1, 15, 14, 'k')
        c.rect(1, 2, 14, 3, 'n'); c.hline(1, 14, 4, 'k')
        c.vline(7, 4, 14, 'k'); c.vline(8, 4, 14, 'k')
        for y in (6, 9, 12):
            c.hline(2, 5, y, 'g'); c.hline(10, 13, y, 'g')


@icon('Eye', 'View.')
def _(c):
    if c.big:
        c.ellipse(16, 16, 15, 8.5, 'k'); c.ellipse(16, 16, 13.5, 7.2, 'w')
        c.disc(16, 16, 6.5, 'b'); c.ellipse(16, 16, 2.6, 2.6, 'k'); c.rect(13, 13, 14, 13, 'w')
    else:
        c.ellipse(8, 8, 7.5, 4.5, 'k'); c.ellipse(8, 8, 6.5, 3.5, 'w')
        c.ellipse(8, 8, 2.6, 2.6, 'b'); c.rect(7, 7, 8, 8, 'k'); c.px(7, 6, 'w')


@icon('OpenWith', 'Open with another program.')
def _(c):
    if c.big:
        page(c, narrow=True)
        c.recolor('s', 'w', (8, 8, 22, 29))
        lines_in(c, (10, 9, 20, 17), 'g')
        c.bevel(13, 17, 30, 30, 's')
        c.rect(14, 18, 29, 20, 'n'); c.hline(14, 29, 21, 'k')
        c.rect(14, 22, 29, 29, 'w')
        c.rect(16, 24, 17, 25, 'r'); c.hline(20, 27, 24, 'b'); c.hline(20, 25, 27, 'g')
    else:
        c.rect(1, 0, 9, 11, 'w'); c.frame(1, 0, 9, 11, 'k')
        c.hline(3, 7, 2, 'g'); c.hline(3, 6, 4, 'g')
        c.bevel(6, 7, 15, 15, 's', hl=None, sh=None)
        c.hline(7, 14, 8, 'n'); c.rect(7, 9, 14, 14, 'w'); c.hline(9, 13, 11, 'b')


@icon('Bell', 'A notification.')
def _(c):
    if c.big:
        pts = [(16, 2), (20, 4), (22, 8), (23, 20), (28, 25), (28, 26), (3, 26), (3, 25), (9, 20),
               (9, 8), (11, 4), (15, 2)]
        c.shape(pts, 'y')
        c.vline(12, 7, 20, 'w'); c.vline(13, 5, 9, 'w')
        c.vline(21, 9, 21, 'o'); c.hline(5, 27, 25, 'o')
        c.disc(16, 28.5, 3, 'o')
        c.rect(14, 0, 17, 2, 'k')
    else:
        pts = [(7, 1), (10, 3), (11, 9), (14, 12), (14, 13), (1, 13), (1, 12), (4, 9), (5, 3)]
        c.shape(pts, 'y')
        c.vline(6, 4, 9, 'w')
        c.rect(7, 14, 8, 15, 'k'); c.px(7, 0, 'k'); c.px(8, 0, 'k')


@icon('Check', 'Done, OK.')
def _(c):
    if c.big:
        pts = [(2, 16), (6, 12), (12, 18), (26, 3), (30, 7), (12, 27)]
        c.shape(pts, 'l')
        c.line(12, 26, 29, 8, 'G'); c.line(12, 25, 28, 8, 'G')
    else:
        c.shape([(0, 8), (3, 5), (6, 8), (12, 1), (15, 4), (6, 14)], 'l')
        c.line(6, 13, 14, 4, 'G')


@icon('Lock', 'Locked, read-only.')
def _(c):
    if c.big:
        c.disc(16, 12, 9, 's')
        c.ellipse(16, 12, 5, 5, '.')
        for y in range(32):
            for x in range(32):
                d = math.hypot(x + 0.5 - 16, y + 0.5 - 12)
                if 4 <= d <= 5:
                    c.px(x, y, 'k')
        c.rect(4, 13, 27, 31, '.')
        c.bevel(4, 13, 27, 30, 'y', sh='o')
        c.rect(14, 18, 17, 22, 'k'); c.rect(15, 22, 16, 26, 'k')
        for x in (7, 8):
            c.vline(x, 9, 12, 'k' if x == 7 else 's')
        for x in (23, 24):
            c.vline(x, 9, 12, 's' if x == 23 else 'k')
        c.vline(7, 11, 12, 'k'); c.vline(24, 11, 12, 'k')
        c.vline(8, 10, 12, 's'); c.vline(23, 10, 12, 'g')
        c.vline(10, 10, 12, 'k'); c.vline(21, 10, 12, 'k')
        c.rect(11, 10, 20, 12, '.')
    else:
        c.rect(4, 1, 11, 7, 'k'); c.rect(5, 2, 10, 7, 's'); c.rect(6, 3, 9, 7, '.')
        c.vline(6, 3, 7, 'k'); c.vline(9, 3, 7, 'k')
        c.bevel(2, 7, 13, 15, 'y', sh='o')
        c.rect(7, 10, 8, 12, 'k')


@icon('Play', 'Play.')
def _(c):
    if c.big:
        c.shape([(7, 2), (29, 16), (7, 30)], 'l')
        c.line(8, 29, 27, 17, 'G'); c.line(8, 28, 26, 17, 'G')
    else:
        c.shape([(3, 1), (14, 8), (3, 15)], 'l')
        c.line(4, 14, 12, 9, 'G')


@icon('User', 'A person.')
def _(c):
    if c.big:
        c.shape([(3, 31), (3, 25), (7, 20), (25, 20), (29, 25), (29, 31)], 'b')
        c.line(4, 25, 8, 21, 'c'); c.hline(8, 14, 21, 'c')
        c.shape([(13, 20), (19, 20), (16, 26)], 'w')
        c.disc(16, 11, 8, 'y')
        c.rect(12, 9, 13, 10, 'k'); c.rect(19, 9, 20, 10, 'k')
        c.hline(13, 19, 14, 'm'); c.px(12, 13, 'm'); c.px(20, 13, 'm')
        c.ellipse(16, 5, 7, 3, 'o')
    else:
        c.shape([(1, 15), (1, 12), (4, 10), (11, 10), (14, 12), (14, 15)], 'b')
        c.disc(7.5, 5.5, 4.5, 'y')
        c.px(6, 5, 'k'); c.px(9, 5, 'k'); c.hline(6, 9, 7, 'm')


@icon('Inbox', 'An inbox, a tray.')
def _(c):
    if c.big:
        c.rect(7, 3, 24, 16, 'w'); c.frame(7, 3, 24, 16, 'k')
        c.hline(9, 20, 6, 'g'); c.hline(9, 18, 8, 'g'); c.hline(9, 21, 10, 'g')
        c.shape([(5, 13), (26, 13), (30, 21), (30, 29), (1, 29), (1, 21)], 's')
        c.shape([(1, 21), (10, 21), (12, 24), (19, 24), (21, 21), (30, 21), (30, 29), (1, 29)], 's')
        c.hline(2, 9, 22, 'w'); c.hline(13, 18, 25, 'w'); c.hline(22, 29, 22, 'w')
        c.hline(2, 29, 28, 'g'); c.vline(29, 22, 28, 'g')
    else:
        c.rect(4, 1, 11, 8, 'w'); c.frame(4, 1, 11, 8, 'k'); c.hline(5, 9, 3, 'g')
        c.shape([(0, 10), (4, 10), (5, 12), (10, 12), (11, 10), (15, 10), (15, 15), (0, 15)], 's')
        c.hline(1, 14, 14, 'g')


@icon('Fit', 'Fit to the window.')
def _(c):
    if c.big:
        c.bevel(8, 8, 23, 23, 'w', hl=None, sh='s')
        for (x, y, d) in ((1, 1, 1), (30, 1, 2), (1, 30, 3), (30, 30, 4)):
            sx = 1 if x < 16 else -1
            sy = 1 if y < 16 else -1
            c.shape([(x, y), (x + 6 * sx, y), (x + 4 * sx, y + 2 * sy), (x + 8 * sx, y + 6 * sy),
                     (x + 6 * sx, y + 8 * sy), (x + 2 * sx, y + 4 * sy), (x, y + 6 * sy)], 'l')
    else:
        c.frame(5, 5, 10, 10, 'k')
        for (x, y) in ((0, 0), (15, 0), (0, 15), (15, 15)):
            sx = 1 if x < 8 else -1
            sy = 1 if y < 8 else -1
            c.shape([(x, y), (x + 3 * sx, y), (x, y + 3 * sy)], 'G', 'G')
            c.line(x, y, x + 3 * sx, y + 3 * sy, 'G')


def hourglass(c, top_full):
    n = c.n
    if c.big:
        l, r, t, b = 6, 25, 1, 30
        c.bevel(l - 2, t, r + 2, t + 2, 'o', hl='y', sh='m')
        c.bevel(l - 2, b - 2, r + 2, b, 'o', hl='y', sh='m')
        g0, g1 = t + 3, b - 3
    else:
        l, r, t, b = 3, 12, 0, 15
        c.rect(l - 1, t, r + 1, t + 1, 'o'); c.frame(l - 1, t, r + 1, t + 1, 'k')
        c.rect(l - 1, b - 1, r + 1, b, 'o'); c.frame(l - 1, b - 1, r + 1, b, 'k')
        g0, g1 = t + 2, b - 2
    mid = (g0 + g1) / 2
    cx = (l + r) / 2
    for y in range(g0, g1 + 1):
        t_ = abs(y + 0.5 - mid - 0.5) / ((g1 - g0) / 2)
        half = 1 + t_ * ((r - l) / 2 - 1)
        x0, x1 = int(round(cx - half + 0.5)), int(round(cx + half - 0.5))
        c.hline(x0, x1, y, 'w')
        c.px(x0 - 1, y, 'k'); c.px(x1 + 1, y, 'k')
        upper = y < mid
        sand = False
        if top_full:
            sand = (upper and y > g0 + (g1 - g0) * 0.18) or (not upper and y > g1 - (g1 - g0) * 0.12)
        else:
            sand = (not upper and y > mid + (g1 - g0) * 0.08)
        if sand:
            c.hline(x0 + (1 if half > 1.5 else 0), x1 - (1 if half > 1.5 else 0), y, 'y')
    if top_full:
        c.vline(int(cx), int(mid), g1 - 1, 'o')


# -- more of them --

@icon('Hourglass', 'Busy (sand running).')
def _(c):
    hourglass(c, True)


@icon('Hourglass2', 'Busy (the sand run through).')
def _(c):
    hourglass(c, False)



@icon('Chart', 'A bar chart.')
def _(c):
    b = c.layer()
    if c.big:
        for (x0, x1, top, col) in ((6, 10, 15, 'r'), (13, 17, 6, 'b'), (20, 24, 11, 'G'), (27, 30, 19, 'y')):
            b.rect(x0, top, x1, 27, col)
        b.outlined()
        b.lit('r', None, 'm'); b.lit('b', None, 'n'); b.lit('G', None, 'G'); b.lit('y', None, 'o')
        c.vline(2, 2, 28, 'k'); c.hline(2, 31, 28, 'k')
        for y in (8, 14, 20):
            c.px(1, y, 'k')
    else:
        for (x0, x1, top, col) in ((3, 4, 8, 'r'), (7, 8, 3, 'b'), (11, 12, 6, 'G')):
            b.rect(x0, top, x1, 13, col)
        b.outlined()
        c.vline(1, 1, 14, 'k'); c.hline(1, 15, 14, 'k')
    c.over(b)



@icon('PieChart', 'A pie chart.')
def _(c):
    n = c.n
    cx = cy = n / 2
    r = 14.5 if c.big else 7.4
    p = c.layer()
    for y in range(n):
        for x in range(n):
            dx, dy = x + 0.5 - cx, y + 0.5 - cy
            if math.hypot(dx, dy) > r - 1:
                continue
            a = math.degrees(math.atan2(dy, dx)) % 360
            col = 'b' if a < 150 else ('r' if a < 250 else ('y' if a < 310 else 'G'))
            p.px(x, y, col)
    p.outlined()
    if c.big:
        p.lit('b', None, 'n'); p.lit('r', 'r', 'm'); p.lit('y', 'w', 'o'); p.lit('G', None, 'G')
    c.over(p)



@icon('Report', 'A report (a document with a chart).')
def _(c):
    page(c)
    if c.big:
        c.rect(8, 9, 17, 10, 'n')
        lines_in(c, (8, 13, 22, 15), 'g')
        c.vline(8, 17, 26, 'k'); c.hline(8, 22, 26, 'k')
        for (x0, top, col) in ((10, 22, 'r'), (13, 18, 'b'), (16, 20, 'G'), (19, 19, 'y')):
            c.rect(x0, top, x0 + 1, 25, col)
    else:
        c.hline(5, 9, 6, 'n')
        c.vline(5, 8, 13, 'k'); c.hline(5, 10, 13, 'k')
        c.vline(7, 10, 12, 'r'); c.vline(9, 9, 12, 'b')



@icon('Map', 'A map.')
def _(c):
    m = c.layer()
    if c.big:
        pts = [(1, 6), (10, 2), (21, 6), (30, 2), (30, 26), (21, 30), (10, 26), (1, 30)]
        m.poly(pts, 'c')
        m.poly([(10, 2), (21, 6), (21, 30), (10, 26)], 'w')
        m.outline(pts, 'k')
        m.line(10, 2, 10, 26, 'k'); m.line(21, 6, 21, 30, 'k')
        m.paste('''
..GG......
.GGGG.....
GGGGG..GG.
.GGG..GGGG
..G....GG.''', 3, 10)
        m.paste('''
...GG...
..GGGG..
.GGGGGG.
..GGGG..''', 20, 15)
        for (x, y) in ((13, 9), (14, 11), (15, 13), (16, 15), (17, 17)):
            m.px(x, y, 'r')
        m.disc(18.5, 19.5, 2.6, 'r')
    else:
        pts = [(0, 3), (5, 1), (10, 3), (15, 1), (15, 13), (10, 15), (5, 13), (0, 15)]
        m.poly(pts, 'c')
        m.poly([(5, 1), (10, 3), (10, 15), (5, 13)], 'w')
        m.outline(pts, 'k')
        m.line(5, 1, 5, 13, 'k'); m.line(10, 3, 10, 15, 'k')
        m.rect(1, 6, 3, 8, 'G'); m.rect(12, 7, 13, 10, 'G')
        m.rect(7, 7, 8, 8, 'r')
    c.over(m)



@icon('Cube', 'A 3D shape.')
def _(c):
    if c.big:
        top = [(16, 2), (29, 8), (16, 14), (3, 8)]
        left = [(3, 8), (16, 14), (16, 30), (3, 23)]
        right = [(16, 14), (29, 8), (29, 23), (16, 30)]
        c.poly(top, 'c'); c.poly(left, 'b'); c.poly(right, 'n')
        c.outline(top, 'k'); c.outline(left, 'k'); c.outline(right, 'k')
        c.line(5, 8, 16, 3, 'w')
    else:
        top = [(8, 1), (14, 4), (8, 7), (1, 4)]
        left = [(1, 4), (8, 7), (8, 15), (1, 11)]
        right = [(8, 7), (14, 4), (14, 11), (8, 15)]
        c.poly(top, 'c'); c.poly(left, 'b'); c.poly(right, 'n')
        c.outline(top, 'k'); c.outline(left, 'k'); c.outline(right, 'k')



@icon('Paint', 'Painting, a canvas.')
def _(c):
    p = c.layer()
    if c.big:
        p.ellipse(14, 17, 13, 10.5, 'y')
        p.ellipse(17, 23, 3, 2.4, '.')
        p.outlined()
        p.lit('y', 'w', 'o')
        for (x, y, col) in ((7, 13, 'r'), (12, 10, 'b'), (18, 10, 'G'), (8, 19, 'P')):
            p.disc(x + 0.5, y + 0.5, 2.4, col)
        b = c.layer()
        b.stroke(30, 1, 20, 17, 2.4, 'm')
        b.stroke(21, 15, 18, 20, 2.6, 's')
        b.outlined()
        b.px(17, 20, 'k'); b.px(18, 21, 'b'); b.px(17, 21, 'b')
        p.over(b)
    else:
        p.ellipse(7, 9, 6.6, 5.6, 'y')
        p.ellipse(8.5, 12, 1.5, 1.2, '.')
        p.outlined()
        p.px(4, 7, 'r'); p.px(7, 5, 'b'); p.px(10, 6, 'G'); p.px(4, 10, 'P')
        b = c.layer()
        b.stroke(15, 0, 9.5, 8.5, 1.4, 'm')
        b.outlined()
        p.over(b)
    c.over(p)



@icon('Speaker', 'Sound.')
def _(c):
    if c.big:
        c.shape([(3, 11), (9, 11), (17, 4), (17, 28), (9, 21), (3, 21)], 's')
        c.vline(4, 12, 20, 'w'); c.line(10, 12, 16, 6, 'w')
        c.vline(9, 11, 21, 'k')
        for r in (5, 9, 13):
            c.arc(16, 16, r, 1.4, -45, 45, 'k')
    else:
        c.shape([(1, 5), (4, 5), (8, 2), (8, 13), (4, 10), (1, 10)], 's')
        c.vline(4, 5, 10, 'k')
        for r in (3, 6):
            c.arc(8, 8, r, 1.1, -45, 45, 'k')



@icon('Camera', 'A camera, a photo.')
def _(c):
    if c.big:
        c.bevel(9, 5, 17, 9, 's', sh=None)
        c.bevel(1, 8, 30, 27, 's')
        c.rect(23, 10, 27, 12, 'w'); c.frame(23, 10, 27, 12, 'k')
        c.disc(15.5, 17.5, 8.5, 'g')
        c.disc(15.5, 17.5, 6, 'n')
        c.ellipse(13.5, 15.5, 2, 1.6, 'c')
        c.rect(4, 10, 6, 11, 'r')
    else:
        c.rect(5, 2, 9, 3, 's'); c.frame(5, 2, 9, 4, 'k')
        c.bevel(0, 4, 15, 14, 's', sh=None)
        c.disc(8, 9, 4, 'n'); c.px(7, 8, 'c')
        c.px(13, 6, 'w')



@icon('Calendar', 'A calendar, a date.')
def _(c):
    if c.big:
        c.bevel(2, 4, 29, 30, 'w', hl=None, sh='s')
        c.rect(3, 5, 28, 10, 'r'); c.hline(3, 28, 5, 'r'); c.hline(2, 29, 11, 'k')
        for x in (8, 23):
            c.rect(x, 1, x + 1, 7, 's'); c.frame(x, 1, x + 1, 7, 'k')
        for i in range(5):
            for j in range(3):
                x = 5 + i * 5; y = 14 + j * 5
                c.rect(x, y, x + 2, y + 2, 'g' if (i, j) != (3, 1) else 'r')
    else:
        c.bevel(0, 2, 15, 15, 'w', hl=None, sh=None)
        c.rect(1, 3, 14, 5, 'r'); c.hline(0, 15, 6, 'k')
        c.vline(4, 0, 3, 'k'); c.vline(11, 0, 3, 'k')
        for i in range(4):
            for j in range(3):
                c.px(2 + i * 3, 8 + j * 2, 'g' if (i, j) != (2, 1) else 'r')
                c.px(3 + i * 3, 8 + j * 2, 'g' if (i, j) != (2, 1) else 'r')



@icon('Clock', 'A clock, the time.')
def _(c):
    n = c.n
    if c.big:
        c.disc(16, 16, 15, 's')
        c.disc(16, 16, 12.5, 'w')
        c.ring(16, 16, 11.5, 12.5, 'k')
        for k in range(12):
            a = k * math.pi / 6
            x, y = 16 + 10 * math.cos(a), 16 + 10 * math.sin(a)
            c.px(int(x), int(y), 'n' if k % 3 else 'k')
        c.stroke(16, 16, 16, 7, 1.6, 'k')
        c.stroke(16, 16, 22, 19, 1.6, 'k')
        c.px(15, 15, 'r')
        c.arc(16, 16, 13.8, 1, -170, -100, 'w')
    else:
        c.disc(8, 8, 7.5, 'w')
        c.px(7, 1, 'k'); c.px(8, 1, 'k')
        c.vline(7, 3, 8, 'k'); c.hline(7, 11, 8, 'k')
        c.px(13, 7, 'g'); c.px(2, 8, 'g'); c.px(8, 13, 'g')



@icon('Kanban', 'A board of cards (kanban).')
def _(c):
    if c.big:
        c.bevel(1, 2, 30, 29, 's')
        for x in (11, 20):
            c.vline(x, 3, 28, 'g')
        cards = [(3, 5, 'y'), (3, 12, 'y'), (3, 19, 'w'), (13, 5, 'c'), (13, 12, 'w'), (22, 5, 'l')]
        for (x, y, col) in cards:
            c.rect(x, y, x + 6, y + 5, col); c.frame(x, y, x + 6, y + 5, 'k')
            c.hline(x + 1, x + 4, y + 2, 'g')
    else:
        c.bevel(0, 1, 15, 14, 's', sh=None)
        c.vline(5, 2, 13, 'g'); c.vline(10, 2, 13, 'g')
        for (x, y, col) in ((1, 3, 'y'), (1, 7, 'y'), (6, 3, 'c'), (11, 3, 'l')):
            c.rect(x, y, x + 3, y + 2, col); c.frame(x, y, x + 3, y + 2, 'k')



@icon('Gantt', 'A plan on a time line (Gantt).')
def _(c):
    if c.big:
        c.rect(1, 3, 30, 28, 'w'); c.frame(1, 3, 30, 28, 'k')
        c.rect(2, 4, 29, 7, 's'); c.hline(2, 29, 8, 'k')
        for x in range(5, 30, 6):
            c.vline(x, 9, 27, 's')
        for (x0, x1, y, col) in ((3, 12, 11, 'b'), (9, 20, 16, 'G'), (17, 27, 21, 'r')):
            c.rect(x0, y, x1, y + 2, col); c.frame(x0, y, x1, y + 2, 'k')
        c.line(12, 13, 12, 15, 'k'); c.line(20, 18, 20, 20, 'k')
    else:
        c.rect(0, 1, 15, 14, 'w'); c.frame(0, 1, 15, 14, 'k')
        c.hline(1, 14, 3, 's')
        c.hline(2, 7, 5, 'b'); c.hline(2, 7, 6, 'b')
        c.hline(5, 11, 8, 'G'); c.hline(5, 11, 9, 'G')
        c.hline(9, 13, 11, 'r'); c.hline(9, 13, 12, 'r')



@icon('OrgChart', 'Who reports to whom (an org chart).')
def _(c):
    if c.big:
        c.bevel(10, 2, 21, 9, 'n', hl='b', sh=None)
        c.vline(15, 10, 14, 'k'); c.vline(16, 10, 14, 'k')
        c.hline(5, 26, 14, 'k')
        c.vline(5, 14, 19, 'k'); c.vline(26, 14, 19, 'k'); c.vline(15, 14, 19, 'k')
        for x in (1, 11, 22):
            c.bevel(x, 19, x + 8, 26, 'c', sh='t')
    else:
        c.rect(5, 0, 10, 3, 'n'); c.frame(5, 0, 10, 3, 'k')
        c.vline(7, 4, 6, 'k'); c.hline(2, 13, 6, 'k')
        c.vline(2, 6, 9, 'k'); c.vline(13, 6, 9, 'k'); c.vline(7, 6, 9, 'k')
        for x in (0, 5, 11):
            c.rect(x, 9, x + 4, 12, 'c'); c.frame(x, 9, x + 4, 12, 'k')



@icon('Calculator', 'A calculator.')
def _(c):
    if c.big:
        c.bevel(5, 1, 26, 30, 's')
        c.rect(8, 4, 23, 10, 'G'); c.frame(8, 4, 23, 10, 'k')
        c.paste('''
lll.lll.l.l
..l...l.l.l
lll.lll.lll
l.....l...l
lll.lll...l''', 11, 5)
        for j in range(4):
            for i in range(4):
                x = 8 + i * 4; y = 13 + j * 4
                col = 'r' if (i, j) == (3, 3) else ('w' if i < 3 else 's')
                c.bevel(x, y, x + 3, y + 3, col, sh='g' if col != 'r' else 'm')
    else:
        c.bevel(2, 0, 13, 15, 's', sh=None)
        c.rect(4, 2, 11, 4, 'G'); c.frame(4, 2, 11, 4, 'k'); c.hline(6, 10, 3, 'l')
        for j in range(4):
            for i in range(3):
                c.rect(4 + i * 3, 6 + j * 2, 5 + i * 3, 6 + j * 2, 'k' if (i, j) != (2, 3) else 'r')



@icon('Mail', 'Mail, a message.')
def _(c):
    if c.big:
        c.rect(1, 7, 30, 25, 'w'); c.frame(1, 7, 30, 25, 'k')
        c.line(1, 7, 15, 18, 'k'); c.line(30, 7, 16, 18, 'k')
        c.line(1, 25, 12, 16, 'g'); c.line(30, 25, 19, 16, 'g')
        c.hline(2, 29, 24, 's')
        c.rect(23, 9, 27, 13, 'r')
    else:
        c.rect(0, 3, 15, 12, 'w'); c.frame(0, 3, 15, 12, 'k')
        c.line(0, 3, 7, 8, 'k'); c.line(15, 3, 8, 8, 'k')



@icon('Database', 'A database.')
def _(c):
    if c.big:
        c.rect(5, 6, 26, 26, 's')
        c.ellipse(16, 26, 11, 4, 's')
        c.ellipse(16, 6, 11, 4, 'w')
        c.ellipse(16, 6, 9, 2.6, 'c')
        # the outline
        snap = c.layer()
        for y in range(32):
            for x in range(32):
                snap.g[y][x] = c.g[y][x]
        c.g = [row[:] for row in snap.outlined().g]
        for y0 in (13, 20):
            for x in range(6, 26):
                y = y0 + int(round(3.5 * math.sqrt(max(0, 1 - ((x + 0.5 - 16) / 10.5) ** 2))))
                c.px(x, y, 'g')
        c.vline(6, 7, 26, 'w')
        c.vline(25, 7, 26, 'g')
    else:
        c.rect(2, 3, 13, 13, 's')
        c.ellipse(8, 13, 6, 2, 's')
        c.ellipse(8, 3, 6, 2.2, 'c')
        snap = c.layer()
        for y in range(16):
            for x in range(16):
                snap.g[y][x] = c.g[y][x]
        c.g = [row[:] for row in snap.outlined().g]
        c.hline(3, 12, 7, 'g'); c.hline(3, 12, 10, 'g')



@icon('Globe', 'The internet, the world.')
def _(c):
    if c.big:
        globe(c, 16, 16, 14.5)
    else:
        globe(c, 8, 8, 7.5)


@icon('Window', 'A window.')
def _(c):
    if c.big:
        c.bevel(1, 3, 30, 28, 's')
        c.rect(2, 4, 29, 8, 'n'); c.hline(2, 29, 9, 'k')
        c.bevel(3, 5, 6, 7, 's', sh=None)
        c.bevel(21, 5, 24, 7, 's'); c.bevel(25, 5, 28, 7, 's')
        c.hline(10, 18, 6, 'w')
        c.rect(2, 10, 29, 27, 'w')
    else:
        c.bevel(0, 1, 15, 14, 's', sh=None)
        c.rect(1, 2, 14, 4, 'n'); c.hline(1, 14, 5, 'k')
        c.px(2, 3, 's'); c.px(13, 3, 's')
        c.rect(1, 6, 14, 13, 'w')



@icon('Terminal', 'A terminal, a command line.')
def _(c):
    x0, y0, x1, y1 = monitor(c, 'k')
    if c.big:
        c.paste('''
l.......
ll......
.ll.....
ll......
l..lllll''', 8, 8)
    else:
        c.paste('''
l...
.l..
l.ll''', 5, 5)



@icon('Gauge', 'A gauge, a dial.')
def _(c):
    if c.big:
        c.arc(16, 22, 13, 5, -180, -120, 'r')
        c.arc(16, 22, 13, 5, -120, -60, 'y')
        c.arc(16, 22, 13, 5, -60, 0, 'l')
        g = c.layer()
        g.over(c)
        g.outlined()
        c.over(g)
        c.stroke(16, 22, 24, 12, 2, 'k')
        c.disc(16, 22, 3, 'k')
    else:
        c.arc(8, 11, 6.5, 2.6, -180, -120, 'r')
        c.arc(8, 11, 6.5, 2.6, -120, -60, 'y')
        c.arc(8, 11, 6.5, 2.6, -60, 0, 'l')
        g = c.layer(); g.over(c); g.outlined(); c.over(g)
        c.line(8, 11, 12, 6, 'k'); c.rect(7, 10, 8, 11, 'k')



@icon('Key', 'A key, a password.')
def _(c):
    k = c.layer()
    if c.big:
        k.disc(9, 11, 7.5, 'y'); k.ellipse(7.5, 9.5, 2.2, 2.2, '.')
        k.rect(14, 10, 29, 13, 'y')
        k.rect(23, 14, 25, 18, 'y'); k.rect(27, 14, 29, 16, 'y')
        k.outlined()
        k.lit('y', 'w', 'o')
    else:
        k.disc(4.5, 6, 4, 'y'); k.rect(3, 5, 4, 6, '.')
        k.rect(8, 5, 14, 6, 'y'); k.rect(11, 7, 12, 8, 'y'); k.rect(14, 7, 14, 8, 'y')
        k.outlined()
    c.over(k)



@icon('Add', 'Add.')
def _(c):
    a = c.layer()
    if c.big:
        a.rect(12, 3, 19, 28, 'l'); a.rect(3, 12, 28, 19, 'l')
    else:
        a.rect(6, 1, 9, 14, 'l'); a.rect(1, 6, 14, 9, 'l')
    a.outlined(); a.lit('l', None, 'G')
    c.over(a)



@icon('Remove', 'Remove.')
def _(c):
    a = c.layer()
    if c.big:
        a.rect(3, 12, 28, 19, 'r')
    else:
        a.rect(1, 6, 14, 9, 'r')
    a.outlined(); a.lit('r', None, 'm')
    c.over(a)



@icon('Filter', 'Filter.')
def _(c):
    f = c.layer()
    if c.big:
        f.poly([(2, 3), (29, 3), (18, 16), (18, 27), (13, 30), (13, 16)], 's')
        f.outlined(); f.lit('s', 'w', 'g')
    else:
        f.poly([(1, 1), (14, 1), (9, 7), (9, 13), (6, 15), (6, 7)], 's')
        f.outlined()
    c.over(f)



@icon('Sort', 'Sort.')
def _(c):
    if c.big:
        c.paste('''
...nn....
..nnnn...
.nn..nn..
.nn..nn..
.nnnnnn..
.nn..nn..
.nn..nn..''', 1, 2)
        c.paste('''
nnnnnnn.
.....nn.
....nn..
...nn...
..nn....
.nn.....
nnnnnnn.''', 2, 20)
        arrow(c, 'd', 22, 28, 22, 'l')
        _shade_arrow(c)
    else:
        c.paste('''
.n.
n.n
nnn
n.n''', 1, 1)
        c.paste('''
nnn
..n
.n.
nnn''', 1, 10)
        c.vline(11, 1, 13, 'k'); c.hline(9, 13, 12, 'k'); c.hline(10, 12, 13, 'k'); c.px(11, 14, 'k')



@icon('Pin', 'A place on a map.')
def _(c):
    p = c.layer()
    if c.big:
        p.disc(16, 11, 9.5, 'r')
        p.poly([(9, 16), (23, 16), (16, 30)], 'r')
        p.outlined(); p.lit('r', None, 'm')
        p.disc(16, 11, 3.6, 'w')
        p.px(12, 6, 'w'); p.px(11, 7, 'w')
    else:
        p.disc(8, 6, 5, 'r')
        p.poly([(4, 8), (11, 8), (7.5, 15)], 'r')
        p.outlined()
        p.rect(7, 5, 8, 6, 'w')
    c.over(p)


def magnifier_with(c, sign):
    if c.big:
        c.shape([(18, 20), (21, 17), (30, 26), (27, 29)], 'm')
        c.line(21, 19, 28, 26, 'r')
        c.disc(12.5, 12.5, 10.5, 's')
        c.disc(12.5, 12.5, 8, 'c')
        c.rect(8, 11, 17, 13, 'n')
        if sign == '+':
            c.rect(11, 8, 13, 16, 'n')
    else:
        c.shape([(9, 11), (11, 9), (15, 13), (13, 15)], 'm')
        c.disc(6.5, 6.5, 5.5, 's')
        c.disc(6.5, 6.5, 4, 'c')
        c.hline(4, 8, 6, 'n')
        if sign == '+':
            c.vline(6, 4, 8, 'n')



@icon('ZoomIn', 'Zoom in.')
def _(c):
    magnifier_with(c, '+')



@icon('ZoomOut', 'Zoom out.')
def _(c):
    magnifier_with(c, '-')



@icon('Pause', 'Pause.')
def _(c):
    a = c.layer()
    if c.big:
        a.rect(7, 4, 12, 27, 'b'); a.rect(19, 4, 24, 27, 'b')
    else:
        a.rect(3, 2, 5, 13, 'b'); a.rect(10, 2, 12, 13, 'b')
    a.outlined(); a.lit('b', 'c', 'n')
    c.over(a)



@icon('Stop', 'Stop.')
def _(c):
    a = c.layer()
    if c.big:
        a.rect(6, 6, 25, 25, 'r')
    else:
        a.rect(3, 3, 12, 12, 'r')
    a.outlined(); a.lit('r', None, 'm')
    c.over(a)



@icon('Record', 'Record.')
def _(c):
    if c.big:
        c.disc(16, 16, 12, 'r')
        c.ellipse(12.5, 12.5, 3, 2.2, 'w')
    else:
        c.disc(8, 8, 6, 'r')
        c.px(6, 5, 'w'); c.px(5, 6, 'w')



# -- painting tools (for image editors) --

def _dash_path(c, pts, on, off, col='k', alt='w'):
    """Pixels along a closed path of points, in dashes: `on` pixels of
    `col`, `off` of `alt` (None: left as is)."""
    k = 0
    for (x, y) in pts:
        c.px(x, y, col if k % (on + off) < on else alt)
        k += 1


def _rect_path(x0, y0, x1, y1):
    pts = [(x, y0) for x in range(x0, x1 + 1)] + [(x1, y) for y in range(y0 + 1, y1 + 1)]
    pts += [(x, y1) for x in range(x1 - 1, x0 - 1, -1)] + [(x0, y) for y in range(y1 - 1, y0, -1)]
    return pts


def _ellipse_path(cx, cy, rx, ry, n):
    pts = []
    seen = set()
    steps = int(2 * math.pi * max(rx, ry) * 3)
    for i in range(steps):
        a = 2 * math.pi * i / steps
        p = (int(round(cx + rx * math.cos(a) - 0.5)), int(round(cy + ry * math.sin(a) - 0.5)))
        if p not in seen:
            seen.add(p)
            pts.append(p)
    return pts


@icon('MarqueeRect', 'The rectangular marquee: select a rectangle.')
def _(c):
    if c.big:
        _dash_path(c, _rect_path(3, 6, 28, 25), 3, 2)
        _dash_path(c, _rect_path(4, 7, 27, 24), 3, 2, 'k', None)
    else:
        _dash_path(c, _rect_path(1, 3, 14, 12), 2, 1)


@icon('MarqueeEllipse', 'The elliptical marquee: select an ellipse.')
def _(c):
    if c.big:
        _dash_path(c, _ellipse_path(16, 16, 13, 10, 0), 3, 2)
        _dash_path(c, _ellipse_path(16, 16, 12, 9, 0), 3, 2, 'k', None)
    else:
        _dash_path(c, _ellipse_path(8, 8, 7, 5.5, 0), 2, 1)


@icon('Lasso', 'The lasso: select a shape drawn freehand.')
def _(c):
    a = c.layer()
    if c.big:
        a.ellipse(17, 11, 13, 8, 'o')
        a.ellipse(17, 11, 10, 5, '.')
        a.stroke(9, 17, 7, 25, 2.6, 'o')
        a.stroke(7, 25, 11, 30, 2.4, 'o')
        a.outlined()
        a.disc(9.5, 17.5, 2.4, 'y')
    else:
        a.ellipse(8.5, 5.5, 7, 4.5, 'o')
        a.ellipse(8.5, 5.5, 5, 2.5, '.')
        a.stroke(4.5, 9, 3.5, 14, 1.3, 'o')
        a.outlined()
    c.over(a)


@icon('MoveTool', 'The move tool: move the selection or the layer.')
def _(c):
    a = c.layer()
    if c.big:
        a.shape([(4, 2), (4, 24), (9, 19), (13, 28), (16, 27), (12, 18), (19, 18)], 'w')
        b = c.layer()
        for (x0, y0, x1, y1) in ((24, 14, 24, 30), (16, 22, 31, 22)):
            b.stroke(x0, y0 + 0.5, x1 + 0.5, y1 + 0.5, 2, 'k')
        b.shape([(24, 12), (27, 16), (21, 16)], 'k')
        b.shape([(24, 31), (27, 27), (21, 27)], 'k')
        b.shape([(15, 22), (19, 19), (19, 25)], 'k')
        b.shape([(31, 22), (28, 19), (28, 25)], 'k')
        a.over(b)
    else:
        a.shape([(2, 1), (2, 12), (5, 9), (7, 14), (8, 13), (6, 8), (9, 8)], 'w')
        a.vline(12, 8, 15, 'k'); a.hline(9, 15, 12, 'k')
        a.px(11, 9, 'k'); a.px(13, 9, 'k'); a.px(11, 15, 'k'); a.px(13, 15, 'k')
        a.px(10, 11, 'k'); a.px(10, 13, 'k'); a.px(14, 11, 'k'); a.px(14, 13, 'k')
    c.over(a)


@icon('MagicWand', 'The magic wand: select similar colors.')
def _(c):
    a = c.layer()
    if c.big:
        a.stroke(4, 29, 19, 14, 3.4, 'k')
        a.stroke(16, 17, 19, 14, 3.4, 'w')
        a.outlined()
        b = c.layer()
        for (x0, y0, x1, y1) in ((24, 2, 24, 13), (18.5, 7.5, 29.5, 7.5), (20, 3, 28, 12), (28, 3, 20, 12)):
            b.stroke(x0, y0, x1, y1, 1.5 if x0 != x1 and y0 != y1 else 2, 'y')
        b.outlined('k')
        b.disc(24, 7.5, 1.8, 'w', None)
        a.over(b)
    else:
        a.line(1, 14, 9, 6, 'k'); a.line(2, 14, 10, 6, 'k')
        a.px(9, 7, 'w'); a.px(8, 7, 'w')
        for (x, y) in ((12, 1), (12, 2), (12, 4), (12, 5), (10, 3), (11, 3), (13, 3), (14, 3)):
            a.px(x, y, 'k')
        a.px(12, 3, 'y')
        a.px(10, 1, 'y'); a.px(14, 1, 'y'); a.px(10, 5, 'y'); a.px(14, 5, 'y')
    c.over(a)


@icon('HandTool', 'The hand: scroll the image.')
def _(c):
    a = c.layer()
    if c.big:
        for x, top in ((9, 6), (13.5, 3), (18, 4), (22.5, 7)):
            a.stroke(x, top + 1.5, x, 18, 3.6, 'w')
        a.stroke(6, 16, 10, 22, 3.6, 'w')
        a.ellipse(16, 21, 8.5, 8, 'w')
        a.rect(10, 15, 24, 22, 'w')
        a.outlined()
        for x in (11, 15, 20):
            a.vline(x, 12, 17, 'k')
    else:
        for x, top in ((4, 4), (7, 2), (10, 2), (13, 4)):
            a.vline(x, top, 9, 'w')
            a.vline(x + 1, top, 9, 'w') if x + 1 < 14 else None
        a.rect(4, 8, 13, 12, 'w')
        a.rect(5, 12, 12, 14, 'w')
        a.px(2, 8, 'w'); a.px(3, 9, 'w'); a.px(3, 10, 'w')
        a.outlined()
        a.vline(6, 4, 8, 'k'); a.vline(9, 3, 8, 'k'); a.vline(12, 4, 8, 'k')
    c.over(a)


@icon('ZoomTool', 'The zoom tool: look closer (or further).')
def _(c):
    if c.big:
        c.shape([(18, 20), (21, 17), (30, 26), (27, 29)], 'm')
        c.line(21, 19, 28, 26, 'r')
        c.disc(12.5, 12.5, 10.5, 's')
        c.disc(12.5, 12.5, 8, 'w')
        c.px(8, 9, 'c'); c.px(9, 8, 'c'); c.px(8, 10, 'c'); c.px(10, 8, 'c')
    else:
        c.shape([(9, 11), (11, 9), (15, 13), (13, 15)], 'm')
        c.disc(6.5, 6.5, 5.5, 's')
        c.disc(6.5, 6.5, 4, 'w')
        c.px(4, 5, 'c'); c.px(5, 4, 'c')


@icon('Crop', 'The crop tool: cut the image down.')
def _(c):
    if c.big:
        c.rect(7, 2, 9, 24, 'k'); c.rect(7, 22, 30, 24, 'k')
        c.rect(2, 7, 24, 9, 'k'); c.rect(22, 7, 24, 29, 'k')
    else:
        c.vline(4, 1, 11, 'k'); c.hline(4, 15, 11, 'k')
        c.hline(1, 11, 4, 'k'); c.vline(11, 4, 14, 'k')


@icon('Eraser', 'The eraser: rub out to the background or transparent.')
def _(c):
    a = c.layer()
    if c.big:
        a.shape([(11, 6), (29, 6), (21, 26), (3, 26)], 'w')
        a.shape([(3, 26), (21, 26), (21, 30), (3, 30)], 's')
        a.shape([(21, 26), (29, 6), (29, 10), (21, 30)], 'g')
        a.line(9, 16, 25, 16, 'r')
    else:
        a.shape([(5, 3), (14, 3), (10, 12), (1, 12)], 'w')
        a.rect(1, 12, 10, 14, 's'); a.frame(1, 12, 10, 14, 'k')
        a.line(10, 12, 14, 3, 'k'); a.line(10, 14, 14, 5, 'k'); a.vline(14, 3, 5, 'k')
        a.px(11, 11, 'g'); a.px(12, 9, 'g'); a.px(13, 7, 'g'); a.px(11, 12, 'g'); a.px(12, 10, 'g')
    c.over(a)


@icon('Pencil', 'The pencil: hard-edged freehand lines.')
def _(c):
    a = c.layer()
    if c.big:
        a.stroke(26, 5, 10, 21, 6.5, 'y')
        a.stroke(28.5, 2.5, 25, 6, 6.5, 'p')
        a.outlined()
        a.shape([(6, 21), (11, 26), (3, 29)], 's')
        a.shape([(4, 26), (6, 28), (3, 29)], 'k')
        a.line(24, 8, 9, 23, 'o')
    else:
        a.stroke(13.5, 2.5, 5, 11, 3.2, 'y')
        a.stroke(14.5, 1.5, 13, 3, 3.2, 'p')
        a.outlined()
        a.px(2, 13, 's'); a.px(3, 13, 's'); a.px(2, 12, 's'); a.px(3, 12, 'k')
        a.px(1, 14, 'k'); a.px(2, 14, 'k'); a.px(1, 13, 'k')
    c.over(a)


@icon('LineTool', 'The line tool: straight lines, with arrowheads.')
def _(c):
    if c.big:
        c.stroke(4, 28, 28, 4, 2.8, 'k')
        c.rect(2, 26, 5, 29, 'w'); c.frame(2, 26, 5, 29, 'k')
        c.rect(26, 2, 29, 5, 'w'); c.frame(26, 2, 29, 5, 'k')
    else:
        c.line(2, 13, 13, 2, 'k'); c.line(3, 13, 13, 3, 'k')


@icon('Airbrush', 'The airbrush: soft paint that builds up.')
def _(c):
    a = c.layer()
    if c.big:
        a.stroke(13, 13, 27, 27, 5, 's')
        a.stroke(20, 19, 15, 29, 3.2, 'g')
        a.stroke(9, 9, 13, 13, 2.6, 'g')
        a.outlined()
        a.rect(22, 9, 25, 14, 's'); a.frame(22, 8, 26, 14, 'k')
        for (x, y) in ((2, 3), (5, 2), (4, 6), (7, 5), (2, 8), (6, 9), (9, 3), (3, 11)):
            a.px(x, y, 'k')
    else:
        a.stroke(6.5, 6.5, 14, 14, 2.6, 's')
        a.stroke(10, 10, 8, 15, 1.4, 'g')
        a.outlined()
        for (x, y) in ((1, 1), (3, 1), (2, 3), (4, 3), (1, 5), (5, 2)):
            a.px(x, y, 'k')
    c.over(a)


@icon('Brush', 'The paintbrush: soft-edged painting.')
def _(c):
    a = c.layer()
    if c.big:
        a.stroke(30, 2, 15, 17, 3.4, 'o')
        a.stroke(16, 16, 12, 20, 4.5, 's')
        a.outlined()
        b = c.layer()
        b.shape([(10, 18), (14, 22), (9, 28), (2, 30), (4, 24)], 'k')
        b.px(7, 24, 'g')
        a.over(b)
    else:
        a.stroke(15, 1, 8, 8, 1.6, 'o')
        a.stroke(8.5, 7.5, 6.5, 9.5, 2.4, 's')
        a.outlined()
        a.shape([(5, 9), (7, 11), (4, 14), (1, 14), (2, 12)], 'k')
    c.over(a)


@icon('Stamp', 'The rubber stamp: paint with a copy of another place.')
def _(c):
    a = c.layer()
    if c.big:
        a.disc(16, 7, 5, 'm', None)
        a.rect(13, 11, 19, 19, 'm')
        a.rect(5, 19, 27, 25, 's')
        a.outlined()
        a.lit('m', 'r', None)
        a.rect(6, 26, 26, 28, 'k')
        a.hline(6, 26, 20, 'w')
    else:
        a.disc(8, 3.5, 2.6, 'm', None)
        a.rect(7, 5, 9, 9, 'm')
        a.rect(2, 10, 14, 12, 's')
        a.outlined()
        a.hline(3, 13, 13, 'k')
    c.over(a)


@icon('Smudge', 'The smudge tool: drag paint as a finger does.')
def _(c):
    a = c.layer()
    if c.big:
        # a hand pointing down and to the left with one finger
        a.stroke(5, 27, 15, 15, 5.5, 'w')
        a.ellipse(21, 13, 8.5, 7.5, 'w')
        a.stroke(17, 5, 27, 7, 4.5, 'w')
        a.outlined()
        a.line(15, 9, 23, 11, 'k')
        a.line(15, 15, 22, 17, 'k')
        a.shape([(4, 25), (7, 28), (4, 29), (3, 27)], 's')
    else:
        a.stroke(2.5, 13.5, 7.5, 7.5, 2.8, 'w')
        a.ellipse(10.5, 6.5, 4.5, 4, 'w')
        a.outlined()
        a.line(8, 5, 12, 6, 'k')
        a.px(2, 13, 's'); a.px(3, 14, 's')
    c.over(a)


@icon('Blur', 'The blur tool: soften what it goes over.')
def _(c):
    a = c.layer()
    if c.big:
        a.shape([(16, 2), (24, 15), (25, 20), (22, 27), (16, 30), (10, 27), (7, 20), (8, 15)], 'b')
        a.ellipse(16, 21, 9, 9, 'b')
        a.outlined()
        a.lit('b', 'c', 'n')
        a.rect(11, 18, 12, 22, 'w'); a.px(12, 16, 'w')
    else:
        a.shape([(8, 1), (12, 8), (12, 11), (10, 14), (6, 14), (4, 11), (4, 8)], 'b')
        a.outlined()
        a.lit('b', 'c', 'n')
        a.px(6, 9, 'w'); a.px(6, 10, 'w')
    c.over(a)


@icon('Sharpen', 'The sharpen tool: harden what it goes over.')
def _(c):
    a = c.layer()
    if c.big:
        a.shape([(5, 5), (27, 5), (16, 29)], 's')
        a.outlined()
        a.lit('s', 'w', 'g')
    else:
        a.shape([(2, 3), (13, 3), (8, 14), (7, 14)], 's')
        a.outlined()
        a.lit('s', 'w', 'g')
    c.over(a)


@icon('Dodge', 'The dodge tool: lighten what it goes over.')
def _(c):
    a = c.layer()
    if c.big:
        a.stroke(17, 15, 29, 30, 2.4, 'g')
        a.disc(12, 10, 8.5, 'k', None)
        a.outlined('k')
        a.disc(12, 10, 6.5, 'k', None)
        a.px(9, 7, 'g'); a.px(10, 6, 'g')
    else:
        a.line(9, 8, 14, 14, 'g'); a.line(10, 8, 15, 14, 'k')
        a.disc(6, 5.5, 4.5, 'k', None)
        a.px(4, 4, 'g')
    c.over(a)


@icon('Burn', 'The burn tool: darken what it goes over.')
def _(c):
    a = c.layer()
    if c.big:
        a.ellipse(14, 20, 11, 9, 'w')
        a.stroke(7, 10, 11, 18, 4, 'w')
        a.outlined()
        a.ring(16, 19, 3, 4.5, 'k')
    else:
        a.ellipse(7, 10, 5.5, 4.5, 'w')
        a.stroke(3.5, 4.5, 5.5, 8, 2, 'w')
        a.outlined()
        a.px(8, 9, 'k'); a.px(9, 9, 'k'); a.px(8, 10, 'k'); a.px(9, 10, 'k')
    c.over(a)


@icon('Sponge', 'The sponge: saturate or desaturate.')
def _(c):
    a = c.layer()
    if c.big:
        a.shape([(4, 10), (24, 6), (29, 20), (8, 26)], 'y')
        a.outlined()
        a.lit('y', 'w', 'o')
        for (x, y) in ((10, 13), (16, 11), (21, 12), (13, 19), (20, 18), (24, 16)):
            a.disc(x + 0.5, y + 0.5, 1.6, 'o', None)
    else:
        a.shape([(1, 5), (12, 3), (14, 10), (3, 13)], 'y')
        a.outlined()
        for (x, y) in ((5, 6), (9, 5), (6, 9), (10, 9)):
            a.px(x, y, 'o')
    c.over(a)


@icon('Pen', 'The pen: draw paths of curves.')
def _(c):
    a = c.layer()
    if c.big:
        a.shape([(3, 29), (8, 16), (16, 12), (20, 16), (16, 24)], 'k')
        a.stroke(17, 15, 28, 4, 5, 'k')
        b = c.layer()
        b.line(4, 28, 12, 20, 'w')
        b.disc(13, 19, 1.8, 'w', None)
        a.over(b)
    else:
        a.shape([(1, 14), (4, 8), (8, 6), (10, 8), (8, 12)], 'k')
        a.line(9, 7, 14, 2, 'k'); a.line(10, 7, 14, 3, 'k'); a.line(9, 6, 13, 2, 'k')
        a.line(2, 13, 5, 10, 'w')
        a.px(6, 9, 'w')
    c.over(a)


def _pen(c, a):
    if c.big:
        a.shape([(3, 29), (8, 16), (16, 12), (20, 16), (16, 24)], 'k')
        a.stroke(17, 15, 28, 4, 5, 'k')
        b = c.layer()
        b.line(4, 28, 12, 20, 'w')
        b.disc(13, 19, 1.8, 'w', None)
        a.over(b)
    else:
        a.shape([(1, 14), (4, 8), (8, 6), (10, 8), (8, 12)], 'k')
        a.line(9, 7, 14, 2, 'k'); a.line(10, 7, 14, 3, 'k'); a.line(9, 6, 13, 2, 'k')
        a.line(2, 13, 5, 10, 'w')
        a.px(6, 9, 'w')


@icon('PathArrow', 'The arrow of the Paths palette: move the points of a path and their handles.')
def _(c):
    if c.big:
        c.shape([(8, 2), (8, 26), (13, 21), (17, 30), (20, 29), (16, 20), (23, 20)], 'w')
    else:
        c.shape([(4, 1), (4, 13), (7, 10), (9, 15), (11, 14), (9, 9), (13, 9)], 'w')


@icon('PenAdd', 'The pen that adds a point to a path.')
def _(c):
    a = c.layer()
    _pen(c, a)
    if c.big:
        a.rect(18, 24, 30, 25, 'k'); a.rect(23, 19, 24, 30, 'k')
    else:
        a.hline(10, 14, 12, 'k'); a.vline(12, 10, 14, 'k')
    c.over(a)


@icon('PenRemove', 'The pen that takes a point out of a path.')
def _(c):
    a = c.layer()
    _pen(c, a)
    if c.big:
        a.rect(18, 24, 30, 25, 'k')
    else:
        a.hline(10, 14, 12, 'k')
    c.over(a)


@icon('ConvertPoint', 'Turns a corner of a path into a curve and back.')
def _(c):
    if c.big:
        c.stroke(4, 28, 15, 6, 2, 'k'); c.stroke(15, 6, 26, 28, 2, 'k')
        c.stroke(6, 6, 24, 6, 1, 'k')
        c.rect(4, 5, 6, 7, 'k'); c.rect(24, 5, 26, 7, 'k')
    else:
        c.line(2, 14, 7, 3, 'k'); c.line(7, 3, 12, 14, 'k')
        c.hline(3, 11, 3, 'k')
        c.px(2, 3, 'k'); c.px(12, 3, 'k'); c.px(2, 2, 'k'); c.px(12, 2, 'k')


@icon('TypeTool', 'The type tool: put text in the image.')
def _(c):
    if c.big:
        c.rect(5, 4, 26, 8, 'k'); c.rect(14, 4, 18, 27, 'k')
        c.rect(10, 26, 22, 28, 'k')
        c.rect(5, 9, 6, 11, 'k'); c.rect(25, 9, 26, 11, 'k')
    else:
        c.hline(2, 13, 2, 'k'); c.hline(2, 13, 3, 'k')
        c.vline(2, 2, 5, 'k'); c.vline(13, 2, 5, 'k')
        c.rect(7, 2, 8, 13, 'k'); c.hline(5, 10, 13, 'k')


@icon('Gradient', 'The gradient tool: a blend from one color to another.')
def _(c):
    shades = 'kkgggsssswwww'
    if c.big:
        for x in range(3, 29):
            col = 'kgsw'[min(3, (x - 3) * 4 // 26)]
            nxt = 'kgsw'[min(3, (x - 3) * 4 // 26 + 1)]
            for y in range(5, 27):
                c.px(x, y, nxt if ((x * 4) % 26 > 18 and (x + y) % 2 == 0) else col)
        c.frame(2, 4, 29, 27, 'k')
    else:
        for x in range(2, 14):
            col = 'kgsw'[min(3, (x - 2) // 3)]
            for y in range(3, 13):
                c.px(x, y, col)
        c.frame(1, 2, 14, 13, 'k')


@icon('Bucket', 'The paint bucket: fill an area of one color.')
def _(c):
    a = c.layer()
    if c.big:
        a.shape([(7, 12), (25, 12), (22, 29), (10, 29)], 's')
        a.outlined()
        a.lit('s', 'w', 'g')
        a.ellipse(16, 12, 9, 3, 'g')
        a.arc(16, 12, 10, 1.6, 180, 360, 'k')
        b = c.layer()
        b.stroke(7, 12, 4, 20, 3, 'b')
        b.disc(4, 23, 2.5, 'b', None)
        b.outlined()
        a.over(b)
    else:
        a.shape([(3, 6), (13, 6), (11, 14), (5, 14)], 's')
        a.outlined()
        a.lit('s', 'w', 'g')
        a.hline(4, 12, 7, 'g')
        a.arc(8, 6, 5, 1.0, 180, 360, 'k')
        a.vline(2, 6, 10, 'b'); a.px(1, 11, 'b'); a.px(2, 11, 'b')
    c.over(a)


@icon('Eyedropper', 'The eyedropper: take a color from the image.')
def _(c):
    a = c.layer()
    if c.big:
        a.stroke(9, 23, 21, 11, 3.6, 'w')
        a.stroke(4, 28, 9, 23, 1.6, 'w')
        a.stroke(22, 10, 27, 5, 6, 'k')
        a.outlined()
        a.stroke(19, 9, 23, 13, 2.2, 'k')
        a.line(8, 23, 13, 18, 'b')
    else:
        a.line(3, 12, 10, 5, 's'); a.line(4, 12, 10, 6, 'w')
        a.outlined()
        a.disc(12.5, 3.5, 2.5, 'k', None)
        a.line(9, 4, 12, 7, 'k')
        a.px(1, 14, 'k'); a.px(2, 13, 'k')
    c.over(a)


@icon('StandardMode', 'Edit in the standard mode (the selection as marching ants).')
def _(c):
    if c.big:
        c.rect(3, 3, 28, 28, 'w'); c.frame(3, 3, 28, 28, 'k')
        _dash_path(c, _ellipse_path(16, 16, 8, 8, 0), 2, 2, 'k', None)
    else:
        c.rect(1, 1, 14, 14, 'w'); c.frame(1, 1, 14, 14, 'k')
        _dash_path(c, _ellipse_path(8, 8, 4, 4, 0), 1, 1, 'k', None)


@icon('QuickMask', 'Edit in Quick Mask mode (the selection as a red mask to paint).')
def _(c):
    if c.big:
        c.rect(3, 3, 28, 28, 'm'); c.frame(3, 3, 28, 28, 'k')
        c.disc(16, 16, 8, 'w', 'k')
    else:
        c.rect(1, 1, 14, 14, 'm'); c.frame(1, 1, 14, 14, 'k')
        c.disc(8, 8, 4.2, 'w', None)


@icon('ScreenWindow', 'Show the image in its window.')
def _(c):
    if c.big:
        c.rect(2, 4, 29, 27, 's'); c.frame(2, 4, 29, 27, 'k')
        c.rect(5, 9, 26, 24, 'w'); c.frame(5, 9, 26, 24, 'k')
        c.rect(5, 9, 26, 11, 'n')
    else:
        c.rect(1, 2, 14, 13, 's'); c.frame(1, 2, 14, 13, 'k')
        c.rect(3, 5, 12, 11, 'w'); c.frame(3, 5, 12, 11, 'k'); c.hline(3, 12, 5, 'n')


@icon('ScreenFullMenu', 'Show the image on the whole screen, with the menu bar.')
def _(c):
    if c.big:
        c.rect(2, 4, 29, 27, 's'); c.frame(2, 4, 29, 27, 'k')
        c.rect(3, 5, 28, 7, 'w'); c.hline(3, 28, 8, 'k')
        c.rect(8, 12, 23, 23, 'w'); c.frame(8, 12, 23, 23, 'k')
    else:
        c.rect(1, 2, 14, 13, 's'); c.frame(1, 2, 14, 13, 'k')
        c.hline(2, 13, 3, 'w'); c.hline(2, 13, 4, 'k')
        c.rect(5, 7, 10, 11, 'w'); c.frame(5, 7, 10, 11, 'k')


@icon('ScreenFull', 'Show the image on the whole screen, on black.')
def _(c):
    if c.big:
        c.rect(2, 4, 29, 27, 'k')
        c.rect(8, 10, 23, 21, 'w'); c.frame(8, 10, 23, 21, 'g')
    else:
        c.rect(1, 2, 14, 13, 'k')
        c.rect(5, 6, 10, 10, 'w')


@icon('SpotHeal', 'The spot healing brush: paint over a spot to make it like what is around it.')
def _(c):
    a = c.layer()
    if c.big:
        a.stroke(9, 27, 27, 9, 9, 'y')
        a.outlined()
        a.stroke(15, 21, 21, 15, 6, 'w')
        for x, y in ((16, 18), (18, 16), (18, 20), (20, 18)):
            a.px(x, y, 's')
        a.arc(8, 8, 6, 1.6, 0, 360, 'k')
        for k in range(0, 360, 45):
            a.px(int(8 + 6 * math.cos(math.radians(k))), int(8 + 6 * math.sin(math.radians(k))), '.')
    else:
        a.stroke(5, 14, 14, 5, 4.5, 'y')
        a.outlined()
        a.stroke(8, 11, 11, 8, 2.5, 'w')
        a.px(9, 9, 's')
        for x, y in ((3, 0), (5, 1), (6, 3), (5, 5), (3, 6), (1, 5), (0, 3), (1, 1)):
            a.px(x, y, 'k')
    c.over(a)


@icon('Heal', 'The healing brush: a copy of another place that takes on the light and color of where it goes.')
def _(c):
    a = c.layer()
    if c.big:
        a.stroke(6, 26, 26, 6, 10, 'y')
        a.outlined()
        a.stroke(12, 20, 20, 12, 7, 'w')
        for x, y in ((14, 16), (16, 14), (16, 18), (18, 16)):
            a.px(x, y, 's')
    else:
        a.stroke(3, 13, 13, 3, 5, 'y')
        a.outlined()
        a.stroke(6, 10, 10, 6, 3, 'w')
        a.px(7, 8, 's')
        a.px(8, 7, 's')
    c.over(a)


@icon('Patch', 'The patch: drag a selection to the place whose texture it takes.')
def _(c):
    a = c.layer()
    if c.big:
        a.rect(5, 7, 26, 24, 'o')
        a.outlined()
        for x in range(7, 25, 3):
            a.hline(x, x + 1, 9, 'y')
            a.hline(x, x + 1, 22, 'y')
        for y in range(9, 23, 3):
            a.vline(7, y, y + 1, 'y')
            a.vline(24, y, y + 1, 'y')
        a.stroke(20, 4, 29, 13, 1.6, 's')
    else:
        a.rect(2, 4, 13, 12, 'o')
        a.outlined()
        for x in range(3, 13, 2):
            a.px(x, 5, 'y')
            a.px(x, 11, 'y')
        for y in range(6, 11, 2):
            a.px(3, y, 'y')
            a.px(12, y, 'y')
    c.over(a)


@icon('RedEye', 'The red eye tool: click a red pupil to make it dark.')
def _(c):
    a = c.layer()
    if c.big:
        a.ellipse(16, 16, 14, 8, 'k')
        a.ellipse(16, 16, 13, 7, 'w')
        a.disc(16, 16, 6.5, 'r')
        a.ellipse(16, 16, 2.5, 2.5, 'm')
        a.px(14, 13, 'w')
        a.px(13, 14, 'w')
    else:
        a.ellipse(8, 8, 7.5, 4.5, 'k')
        a.ellipse(8, 8, 6.5, 3.5, 'w')
        a.disc(8, 8, 3.5, 'r')
        a.px(8, 8, 'm')
        a.px(7, 7, 'w')
    c.over(a)


@icon('AdjustLayer', 'An adjustment layer: it changes the layers under it.')
def _(c):
    a = c.layer()
    if c.big:
        a.disc(16, 16, 12, 'w')
        for y in range(32):
            for x in range(16, 32):
                if a.get(x, y) == 'w':
                    a.px(x, y, 'k')
    else:
        a.disc(8, 8, 6.5, 'w')
        for y in range(16):
            for x in range(8, 16):
                if a.get(x, y) == 'w':
                    a.px(x, y, 'k')
    c.over(a)


@icon('LayerMask', 'A layer mask: add one (white shows the layer, black hides it).')
def _(c):
    a = c.layer()
    if c.big:
        a.rect(3, 6, 28, 25, 'g')
        a.outlined()
        a.disc(15.5, 15.5, 7, 'w', None)
    else:
        a.rect(1, 3, 14, 12, 'g')
        a.outlined()
        a.disc(8, 8, 3.6, 'w', None)
    c.over(a)



# -- type: alignment, character styles, warps, layer styles --

def text_lines(c, lens, align, last=None):
    """Lines of text (a paragraph) of relative lengths `lens`, aligned."""
    n = c.n
    k = 2 if c.big else 1
    x0, x1 = 2 * k, n - 2 * k - 1
    full = x1 - x0 + 1
    ys = [3 * k + i * (4 * k if c.big else 3) for i in range(len(lens))] if not c.big else [5, 11, 17, 23]
    if not c.big:
        ys = [3, 6, 9, 12]
    for i, (y, f) in enumerate(zip(ys, lens)):
        a = align if (last is None or i < len(lens) - 1) else last
        w = max(2, int(round(full * f)))
        if a == 'l':
            xa = x0
        elif a == 'r':
            xa = x1 - w + 1
        else:
            xa = x0 + (full - w) // 2
        for t in range(k):
            c.hline(xa, xa + w - 1, y + t, 'k')


@icon('AlignLeft', 'Align text left.')
def _(c):
    text_lines(c, [1.0, 0.6, 0.9, 0.45], 'l')


@icon('AlignCenter', 'Center text.')
def _(c):
    text_lines(c, [1.0, 0.6, 0.9, 0.45], 'c')


@icon('AlignRight', 'Align text right.')
def _(c):
    text_lines(c, [1.0, 0.6, 0.9, 0.45], 'r')


@icon('JustifyLeft', 'Justify the lines, the last one aligned left.')
def _(c):
    text_lines(c, [1.0, 1.0, 1.0, 0.5], 'l', 'l')


@icon('JustifyCenter', 'Justify the lines, the last one centered.')
def _(c):
    text_lines(c, [1.0, 1.0, 1.0, 0.5], 'l', 'c')


@icon('JustifyRight', 'Justify the lines, the last one aligned right.')
def _(c):
    text_lines(c, [1.0, 1.0, 1.0, 0.5], 'l', 'r')


@icon('JustifyAll', 'Justify all the lines, the last one too.')
def _(c):
    text_lines(c, [1.0, 1.0, 1.0, 1.0], 'l')


def letter_t(c, x, y, w, h, thick, slant=0.0, col='k'):
    """A capital T in the box (x, y, w, h) (pixel-edge coordinates)."""
    c.stroke(x + slant * h, y + thick / 2, x + w + slant * h, y + thick / 2, thick, col)
    mx = x + w / 2
    c.stroke(mx + slant * h, y, mx, y + h, thick, col)


@icon('FauxBold', 'Faux Bold: letters made thicker.')
def _(c):
    if c.big:
        letter_t(c, 6, 5, 20, 22, 6)
    else:
        letter_t(c, 3, 2, 10, 12, 3)


@icon('FauxItalic', 'Faux Italic: letters slanted.')
def _(c):
    if c.big:
        letter_t(c, 6, 5, 18, 22, 3, 0.3)
    else:
        letter_t(c, 3, 2, 9, 12, 2, 0.3)


@icon('AllCaps', 'All Caps: capital letters.')
def _(c):
    if c.big:
        letter_t(c, 2, 7, 13, 19, 3)
        letter_t(c, 17, 7, 13, 19, 3)
    else:
        letter_t(c, 0, 3, 7, 10, 2)
        letter_t(c, 8, 3, 7, 10, 2)


@icon('SmallCaps', 'Small Caps: small letters as small capitals.')
def _(c):
    if c.big:
        letter_t(c, 2, 7, 14, 19, 3)
        letter_t(c, 19, 14, 10, 12, 3)
    else:
        letter_t(c, 0, 3, 8, 10, 2)
        letter_t(c, 9, 7, 6, 6, 2)


@icon('Superscript', 'Superscript: smaller, raised letters.')
def _(c):
    if c.big:
        letter_t(c, 2, 9, 16, 19, 3)
        letter_t(c, 20, 3, 9, 10, 2)
    else:
        letter_t(c, 0, 4, 9, 10, 2)
        letter_t(c, 10, 1, 5, 5, 1)


@icon('Subscript', 'Subscript: smaller, lowered letters.')
def _(c):
    if c.big:
        letter_t(c, 2, 4, 16, 19, 3)
        letter_t(c, 20, 19, 9, 10, 2)
    else:
        letter_t(c, 0, 2, 9, 10, 2)
        letter_t(c, 10, 10, 5, 5, 1)


@icon('Underline', 'Underline.')
def _(c):
    if c.big:
        letter_t(c, 7, 3, 18, 19, 3)
        c.rect(5, 26, 26, 27, 'k')
    else:
        letter_t(c, 3, 1, 10, 10, 2)
        c.hline(2, 13, 13, 'k')


@icon('Strikethrough', 'Strikethrough: a line through the letters.')
def _(c):
    if c.big:
        letter_t(c, 7, 5, 18, 22, 3)
        c.rect(4, 17, 27, 18, 'r')
    else:
        letter_t(c, 3, 2, 10, 12, 2)
        c.hline(1, 14, 9, 'r')


@icon('WarpText', 'Warp Text: bend the text (an arc, a flag, a wave...).')
def _(c):
    a = c.layer()
    if c.big:
        a.arc(16, 34, 24, 2, 205, 335, 'b')
        letter_t(a, 4, 12, 8, 10, 2.5, -0.25)
        letter_t(a, 12, 7, 8, 10, 2.5)
        letter_t(a, 20, 12, 8, 10, 2.5, 0.25)
    else:
        a.arc(8, 17, 12, 1.2, 205, 335, 'b')
        letter_t(a, 1, 6, 5, 5, 1.5, -0.25)
        letter_t(a, 5.5, 3, 5, 5, 1.5)
        letter_t(a, 10, 6, 5, 5, 1.5, 0.25)
    c.over(a)


@icon('TypePath', 'Type on a path: text that follows a line.')
def _(c):
    a = c.layer()
    if c.big:
        a.arc(30, 32, 26, 1.6, 180, 270, 'b')
        for (x, y) in ((4, 31), (30, 6)):
            a.rect(x - 2, y - 2, x + 1, y + 1, 'w')
            a.frame(x - 2, y - 2, x + 1, y + 1, 'k')
        letter_t(a, 9, 9, 12, 14, 3, 0.2)
    else:
        a.arc(15, 16, 13, 1.0, 180, 270, 'b')
        a.rect(1, 13, 3, 15, 'k')
        a.rect(13, 1, 15, 3, 'k')
        letter_t(a, 4, 4, 7, 7, 2, 0.2)
    c.over(a)


@icon('LayerStyle', 'A layer style: effects (shadows, glows, bevels, strokes) on a layer.')
def _(c):
    a = c.layer()
    if c.big:
        # an f and an x, slanted
        a.stroke(12, 6, 9, 27, 3, 'k')
        a.arc(15, 8, 4, 2.5, 180, 300, 'k')
        a.stroke(5, 14, 15, 14, 2.5, 'k')
        a.stroke(15, 14, 26, 27, 3, 'k')
        a.stroke(26, 14, 15, 27, 3, 'k')
    else:
        a.stroke(6, 3, 4.5, 14, 1.6, 'k')
        a.hline(6, 8, 2, 'k')
        a.hline(2, 7, 7, 'k')
        a.stroke(8, 7, 14, 14, 1.6, 'k')
        a.stroke(14, 7, 8, 14, 1.6, 'k')
    c.over(a)


@icon('Character', 'The Character palette: font, size, spacing of letters.')
def _(c):
    a = c.layer()
    if c.big:
        a.shape([(3, 27), (11, 4), (15, 4), (23, 27), (18, 27), (16, 21), (10, 21), (8, 27)], 'n')
        a.poly([(11, 17), (13, 10), (15, 17)], '.')
        a.outline([(11, 17), (13, 10), (15, 17)], 'k')
        a.ellipse(25.5, 22.5, 4, 4.5, 'k')
        a.ellipse(25.5, 22.5, 2, 2.5, '.')
        a.rect(28, 18, 29, 27, 'k')
    else:
        a.shape([(1, 14), (5, 2), (7, 2), (11, 14), (9, 14), (8, 11), (4, 11), (3, 14)], 'n')
        a.px(6, 6, '.')
        a.ellipse(13, 12, 2.2, 2.5, 'k')
        a.px(12, 12, '.')
        a.vline(14, 9, 14, 'k')
    c.over(a)


@icon('Paragraph', 'The Paragraph palette: alignment, indents, spacing.')
def _(c):
    a = c.layer()
    if c.big:
        a.ellipse(13, 11, 7, 7, 'k')
        a.rect(13, 4, 22, 5, 'k')
        a.rect(17, 4, 18, 28, 'k')
        a.rect(21, 4, 22, 28, 'k')
    else:
        a.ellipse(6.5, 5.5, 3.5, 3.5, 'k')
        a.hline(6, 11, 2, 'k')
        a.vline(8, 2, 14, 'k')
        a.vline(11, 2, 14, 'k')
    c.over(a)


@icon('RectShape', 'The rectangle tool: draw a rectangle as a shape.')
def _(c):
    if c.big:
        c.rect(4, 8, 27, 24, 'n')
        c.frame(4, 8, 27, 24, 'k')
        c.hline(5, 26, 9, 'b'); c.vline(5, 9, 23, 'b')
    else:
        c.rect(1, 4, 14, 12, 'n')
        c.frame(1, 4, 14, 12, 'k')
        c.hline(2, 13, 5, 'b')


@icon('RoundRectShape', 'The rounded rectangle tool: a rectangle with round corners.')
def _(c):
    a = c.layer()
    if c.big:
        a.rect(9, 7, 22, 25, 'n'); a.rect(4, 12, 27, 20, 'n')
        for (x, y) in ((9, 12), (22, 12), (9, 20), (22, 20)):
            a.ellipse(x + 0.5, y + 0.5, 5.5, 5.5, 'n')
        a.outlined('k')
    else:
        a.rect(4, 4, 11, 12, 'n'); a.rect(2, 6, 13, 10, 'n')
        a.px(3, 5, 'n'); a.px(12, 5, 'n'); a.px(3, 11, 'n'); a.px(12, 11, 'n')
        a.outlined('k')
    c.over(a)


@icon('EllipseShape', 'The ellipse tool: draw an ellipse as a shape.')
def _(c):
    if c.big:
        c.ellipse(16, 16, 13, 10, 'k')
        c.ellipse(16, 16, 12, 9, 'n')
        c.arc(16, 16, 10, 1.2, 190, 260, 'b')
    else:
        c.ellipse(8, 8, 7, 5.5, 'k')
        c.ellipse(8, 8, 6, 4.5, 'n')


@icon('PolygonShape', 'The polygon tool: draw a polygon or a star as a shape.')
def _(c):
    import math as m
    pts = []
    n = 32 if c.big else 16
    cx, cy, r = n / 2, n / 2 + (0.5 if c.big else 0.3), n / 2 - (2 if c.big else 1)
    for i in range(6):
        a = m.radians(-90 + i * 60)
        pts.append((cx + m.cos(a) * r, cy + m.sin(a) * r * 0.95))
    c.shape(pts, 'n')


@icon('CustomShape', 'The custom shape tool: draw one of the ready-made shapes (a heart, an arrow...).')
def _(c):
    a = c.layer()
    if c.big:
        a.ellipse(10.5, 11, 7, 7, 'r'); a.ellipse(21.5, 11, 7, 7, 'r')
        a.poly([(3.6, 13), (28.4, 13), (16, 28)], 'r')
        a.outlined('k')
        a.ellipse(9, 9, 2, 2, 'w')
    else:
        a.ellipse(5.5, 6, 3.5, 3.5, 'r'); a.ellipse(10.5, 6, 3.5, 3.5, 'r')
        a.poly([(2, 7), (14, 7), (8, 14)], 'r')
        a.outlined('k')
    c.over(a)


@icon('ShapeLayer', 'A shape layer: a shape kept as its outline (sharp at any size).')
def _(c):
    if c.big:
        c.rect(3, 3, 28, 28, 'w')
        c.frame(3, 3, 28, 28, 'k')
        c.ellipse(16, 17, 9, 8, 'n')
        for (x, y) in ((7, 17), (25, 17), (16, 9), (16, 25)):
            c.rect(x - 1, y - 1, x + 1, y + 1, 'w')
            c.frame(x - 1, y - 1, x + 1, y + 1, 'k')
    else:
        c.rect(1, 1, 14, 14, 'w')
        c.frame(1, 1, 14, 14, 'k')
        c.ellipse(8, 8, 4.5, 4, 'n')
        for (x, y) in ((3, 8), (12, 8)):
            c.px(x, y, 'k')


@icon('ClipLayer', 'A clipping mask: the layer shows only where the layer under it does.')
def _(c):
    if c.big:
        c.rect(7, 4, 9, 20, 'k')
        c.rect(7, 19, 22, 21, 'k')
        c.poly([(20, 14), (28, 20), (20, 26)], 'k')
    else:
        c.vline(4, 2, 10, 'k'); c.vline(5, 2, 10, 'k')
        c.hline(4, 11, 10, 'k'); c.hline(4, 11, 11, 'k')
        c.poly([(10, 7), (14, 10.5), (10, 14)], 'k')


@icon('Plugin', 'A plug-in filter: one made with Filter Factory, or added to the Plug-ins folder.')
def _(c):
    a = c.layer()
    if c.big:
        a.rect(4, 10, 24, 28, 'G')
        a.ellipse(14, 8, 4.5, 4.5, 'G')
        a.ellipse(26, 19, 4.5, 4.5, 'G')
        a.outlined('k')
        a.lit('G', 'l', None)
    else:
        a.rect(2, 5, 11, 14, 'G')
        a.ellipse(6.5, 4, 2.5, 2.5, 'G')
        a.ellipse(13, 9.5, 2.5, 2.5, 'G')
        a.outlined('k')
    c.over(a)


@icon('Symmetry', 'Symmetry: what is painted on one side is painted mirrored on the other.')
def _(c):
    if c.big:
        c.shape([(15, 6), (4, 10), (6, 22), (15, 26)], 'P')
        c.shape([(17, 6), (28, 10), (26, 22), (17, 26)], 'p')
        for y in range(2, 31, 3):
            c.vline(16, y, y + 1, 'k')
    else:
        c.shape([(7, 3), (1, 5), (2, 11), (7, 13)], 'P')
        c.shape([(9, 3), (15, 5), (14, 11), (9, 13)], 'p')
        for y in range(0, 16, 2):
            c.px(8, y, 'k')


@icon('ProofColors', 'Proof Colors: see on the screen how the image will print in ink (CMYK).')
def _(c):
    a = c.layer()
    if c.big:
        a.ellipse(12, 12, 8, 8, 'c'); a.ellipse(20, 12, 8, 8, 'p'); a.ellipse(16, 19, 8, 8, 'y')
        a.ellipse(16, 15, 2.6, 2.6, 'k')
    else:
        a.ellipse(6, 6, 4.2, 4.2, 'c'); a.ellipse(10, 6, 4.2, 4.2, 'p'); a.ellipse(8, 10, 4.2, 4.2, 'y')
        a.px(8, 8, 'k')
    a.outlined('k')
    c.over(a)


@icon('SmartObject', 'A Smart Object: a picture kept as it was placed (scaled and turned again without loss).')
def _(c):
    if c.big:
        c.shape([(5, 3), (21, 3), (27, 9), (27, 29), (5, 29)], 'w')
        c.shape([(21, 3), (21, 9), (27, 9)], 's')
        c.rect(17, 18, 29, 30, 'w'); c.frame(17, 18, 29, 30, 'k')
        c.rect(19, 20, 23, 24, 'n'); c.rect(23, 24, 27, 28, 'n')
    else:
        c.shape([(2, 1), (10, 1), (13, 4), (13, 14), (2, 14)], 'w')
        c.shape([(10, 1), (10, 4), (13, 4)], 's')
        c.rect(8, 9, 15, 15, 'w'); c.frame(8, 9, 15, 15, 'k')
        c.rect(10, 11, 11, 12, 'n'); c.rect(12, 12, 13, 13, 'n')


@icon('QuickSelect', 'The quick selection tool: paint over what to select; it finds the edges.')
def _(c):
    a = c.layer()
    if c.big:
        for t in range(0, 360, 30):
            x = 12 + 9 * math.cos(math.radians(t)); y = 12 + 9 * math.sin(math.radians(t))
            a.rect(int(x) - 1, int(y) - 1, int(x), int(y), 'k')
        a.stroke(30, 30, 18, 18, 3.4, 'o')
        a.stroke(19, 19, 15, 15, 4.5, 's')
        a.outlined()
    else:
        for t in range(0, 360, 45):
            x = 6 + 4.5 * math.cos(math.radians(t)); y = 6 + 4.5 * math.sin(math.radians(t))
            a.px(int(round(x)), int(round(y)), 'k')
        a.stroke(15, 15, 9, 9, 1.6, 'o')
        a.stroke(9.5, 9.5, 7.5, 7.5, 2.4, 's')
        a.outlined()
    c.over(a)


@icon('ObjectSelect', 'The object selection tool: draw a box round a thing; it selects the thing.')
def _(c):
    if c.big:
        for x in range(3, 27, 4):
            c.hline(x, x + 1, 3, 'k'); c.hline(x, x + 1, 22, 'k')
        for y in range(3, 23, 4):
            c.vline(3, y, y + 1, 'k'); c.vline(26, y, y + 1, 'k')
        c.ellipse(15, 13, 6, 6, 'r')
        c.shape([(18, 16), (18, 30), (21, 27), (24, 31), (26, 30), (23, 26), (27, 26)], 'w')
    else:
        for x in range(1, 13, 2):
            c.px(x, 1, 'k'); c.px(x, 11, 'k')
        for y in range(1, 12, 2):
            c.px(1, y, 'k'); c.px(13, y, 'k')
        c.ellipse(7, 6, 3, 3, 'r')
        c.shape([(9, 8), (9, 15), (11, 13), (12, 15), (13, 15), (12, 12), (14, 12)], 'w')


@icon('PathSelect', 'The path selection tool: pick and move whole paths and shapes.')
def _(c):
    if c.big:
        c.shape([(8, 2), (8, 26), (13, 21), (17, 30), (20, 29), (16, 20), (23, 20)], 'k')
    else:
        c.shape([(4, 1), (4, 13), (7, 10), (9, 15), (11, 14), (9, 9), (13, 9)], 'k')


@icon('HistoryBrush', 'The history brush: paint back what the image was (a snapshot of it).')
def _(c):
    a = c.layer()
    if c.big:
        a.stroke(30, 2, 15, 17, 3.4, 'o')
        a.stroke(16, 16, 12, 20, 4.5, 's')
        a.outlined()
        b = c.layer()
        b.shape([(10, 18), (14, 22), (9, 28), (2, 30), (4, 24)], 'k')
        a.over(b)
        for t in range(200, 350, 12):
            x = 9 + 7 * math.cos(math.radians(t)); y = 10 + 7 * math.sin(math.radians(t))
            a.rect(int(x), int(y), int(x) + 1, int(y) + 1, 'b')
        a.shape([(1, 9), (5, 9), (3, 13)], 'b')
    else:
        a.stroke(15, 1, 8, 8, 1.6, 'o')
        a.stroke(8.5, 7.5, 6.5, 9.5, 2.4, 's')
        a.outlined()
        a.shape([(5, 9), (7, 11), (4, 14), (1, 14), (2, 12)], 'k')
        for (x, y) in ((1, 4), (2, 2), (4, 1), (6, 1)):
            a.px(x, y, 'b')
        a.px(0, 5, 'b'); a.px(2, 5, 'b'); a.px(1, 6, 'b')
    c.over(a)


@icon('MixerBrush', 'The mixer brush: paint that mixes with the wet paint already on the canvas.')
def _(c):
    a = c.layer()
    if c.big:
        a.stroke(30, 2, 15, 17, 3.4, 'o')
        a.stroke(16, 16, 12, 20, 4.5, 's')
        a.outlined()
        b = c.layer()
        b.shape([(10, 18), (14, 22), (9, 28), (2, 30), (4, 24)], 'r')
        b.outlined()
        a.over(b)
        a.disc(25, 25, 4, 'b')
    else:
        a.stroke(15, 1, 8, 8, 1.6, 'o')
        a.stroke(8.5, 7.5, 6.5, 9.5, 2.4, 's')
        a.outlined()
        a.shape([(5, 9), (7, 11), (4, 14), (1, 14), (2, 12)], 'r')
        a.disc(12.5, 12.5, 2, 'b')
    c.over(a)


@icon('RemoveTool', 'The remove tool: paint over something to take it away; what was behind it is made up.')
def _(c):
    a = c.layer()
    if c.big:
        a.stroke(6, 26, 22, 10, 9, 'y')
        a.outlined()
        a.stroke(11, 21, 17, 15, 6, 'w')
        b = c.layer()
        for (x0, y0, x1, y1) in ((26, 1, 26, 11), (21, 6, 31, 6)):
            b.stroke(x0, y0, x1 + 0.01, y1 + 0.01, 2, 'b')
        a.over(b)
    else:
        a.stroke(3, 13, 11, 5, 4.5, 'y')
        a.outlined()
        a.stroke(6, 10, 8, 8, 2.5, 'w')
        a.vline(13, 0, 4, 'b'); a.hline(11, 15, 2, 'b')
    c.over(a)


@icon('ContentMove', 'Content-Aware Move: move a selection; where it was is filled in from round it.')
def _(c):
    if c.big:
        for x in range(2, 20, 4):
            c.hline(x, x + 1, 2, 'k'); c.hline(x, x + 1, 17, 'k')
        for y in range(2, 18, 4):
            c.vline(2, y, y + 1, 'k'); c.vline(19, y, y + 1, 'k')
        c.rect(12, 12, 29, 29, 'c'); c.frame(12, 12, 29, 29, 'k')
        c.stroke(15, 26, 26, 15, 2, 'k')
        c.shape([(27, 14), (27, 20), (21, 14)], 'k')
    else:
        for x in range(1, 10, 2):
            c.px(x, 1, 'k'); c.px(x, 9, 'k')
        for y in range(1, 10, 2):
            c.px(1, y, 'k'); c.px(9, y, 'k')
        c.rect(6, 6, 14, 14, 'c'); c.frame(6, 6, 14, 14, 'k')
        c.line(8, 12, 12, 8, 'k')
        c.px(11, 8, 'k'); c.px(12, 9, 'k')


@icon('Navigator', 'The Navigator: the whole image small, with the part shown framed in red.')
def _(c):
    if c.big:
        c.rect(2, 5, 29, 26, 'G'); c.frame(2, 5, 29, 26, 'k')
        c.shape([(3, 25), (12, 13), (19, 21), (23, 16), (28, 25)], 'o')
        c.ellipse(23, 10, 2.5, 2.5, 'y')
        c.frame(9, 9, 20, 19, 'r'); c.frame(10, 10, 19, 18, 'r')
    else:
        c.rect(1, 3, 14, 13, 'G'); c.frame(1, 3, 14, 13, 'k')
        c.shape([(2, 12), (6, 7), (9, 10), (11, 8), (13, 12)], 'o')
        c.frame(5, 5, 10, 10, 'r')


@icon('History', 'The History palette: the steps done, to go back to any of them.')
def _(c):
    if c.big:
        c.rect(3, 3, 28, 28, 'w'); c.frame(3, 3, 28, 28, 'k')
        for i, y in enumerate((7, 13, 19, 25)):
            c.rect(6, y - 1, 9, y + 1, 'n' if i < 3 else 'g')
            c.rect(12, y, 25, y, 'k' if i < 3 else 'g')
        c.shape([(6, 18), (9, 18), (9, 20), (6, 20)], 'r')
    else:
        c.rect(1, 1, 14, 14, 'w'); c.frame(1, 1, 14, 14, 'k')
        for i, y in enumerate((4, 7, 10)):
            c.rect(3, y, 4, y, 'n' if i < 2 else 'g')
            c.hline(6, 12, y, 'k' if i < 2 else 'g')


@icon('Snapshot', 'A snapshot: the image as it is now, kept to go back to or paint from.')
def _(c):
    if c.big:
        c.rect(2, 9, 29, 27, 's'); c.frame(2, 9, 29, 27, 'k')
        c.rect(10, 5, 19, 9, 's'); c.frame(10, 5, 19, 9, 'k')
        c.disc(16, 18, 6, 'k', None)
        c.disc(16, 18, 4, 'n', None)
        c.rect(14, 16, 15, 17, 'w')
        c.rect(23, 12, 26, 13, 'r')
    else:
        c.rect(1, 4, 14, 13, 's'); c.frame(1, 4, 14, 13, 'k')
        c.rect(5, 2, 9, 4, 's'); c.frame(5, 2, 9, 4, 'k')
        c.disc(8, 8.5, 3, 'k', None)
        c.disc(8, 8.5, 2, 'n', None)
        c.px(7, 8, 'w')


@icon('Actions', 'The Actions palette: steps recorded, to be played again on other images.')
def _(c):
    if c.big:
        c.rect(3, 3, 28, 28, 'w'); c.frame(3, 3, 28, 28, 'k')
        c.shape([(9, 8), (9, 24), (23, 16)], 'G')
        c.outline([(9, 8), (9, 24), (23, 16)], 'k')
    else:
        c.rect(1, 1, 14, 14, 'w'); c.frame(1, 1, 14, 14, 'k')
        c.shape([(4, 4), (4, 11), (11, 7.5)], 'G')


@icon('Guides', 'Guides: lines over the image (not printed) that things snap to.')
def _(c):
    if c.big:
        c.rect(2, 2, 29, 29, 'w'); c.frame(2, 2, 29, 29, 'k')
        c.rect(3, 11, 28, 11, 'c'); c.rect(3, 21, 28, 21, 'c')
        c.rect(11, 3, 11, 28, 'c'); c.rect(21, 3, 21, 28, 'c')
    else:
        c.rect(1, 1, 14, 14, 'w'); c.frame(1, 1, 14, 14, 'k')
        c.hline(2, 13, 5, 'c'); c.hline(2, 13, 10, 'c')
        c.vline(5, 2, 13, 'c'); c.vline(10, 2, 13, 'c')


@icon('Grid', 'The grid: lines across the image at even steps.')
def _(c):
    if c.big:
        c.rect(2, 2, 29, 29, 'w')
        for v in range(2, 30, 6):
            c.rect(v, 2, v, 29, 'g'); c.rect(2, v, 29, v, 'g')
        c.frame(2, 2, 29, 29, 'k')
    else:
        c.rect(1, 1, 14, 14, 'w')
        for v in (1, 5, 9, 13):
            c.vline(v, 1, 14, 'g'); c.hline(1, 14, v, 'g')
        c.frame(1, 1, 14, 14, 'k')


def align_icon(c, edge):
    n = 32 if c.big else 16
    k = 2 if c.big else 1
    if edge in 'lhr':
        line = {'l': 2 * k, 'h': n // 2 - 1, 'r': n - 3 * k}[edge]
        bars = ((5 * k, 12 * k), (10 * k, 7 * k))
        for (y, w) in bars:
            x0 = {'l': line + k, 'h': n // 2 - w // 2 - 1, 'r': line - w}[edge]
            c.rect(x0, y, x0 + w, y + 3 * k, 'w'); c.frame(x0, y, x0 + w, y + 3 * k, 'k')
        c.rect(line, k, line + (k - 1), n - 2 * k, 'r')
    else:
        line = {'t': 2 * k, 'v': n // 2 - 1, 'b': n - 3 * k}[edge]
        bars = ((5 * k, 12 * k), (10 * k, 7 * k))
        for (x, h) in bars:
            y0 = {'t': line + k, 'v': n // 2 - h // 2 - 1, 'b': line - h}[edge]
            c.rect(x, y0, x + 3 * k, y0 + h, 'w'); c.frame(x, y0, x + 3 * k, y0 + h, 'k')
        c.rect(k, line, n - 2 * k, line + (k - 1), 'r')


@icon('AlignEdgeLeft', 'Align the left edges.')
def _(c): align_icon(c, 'l')


@icon('AlignEdgeHCenter', 'Align the horizontal centers.')
def _(c): align_icon(c, 'h')


@icon('AlignEdgeRight', 'Align the right edges.')
def _(c): align_icon(c, 'r')


@icon('AlignEdgeTop', 'Align the top edges.')
def _(c): align_icon(c, 't')


@icon('AlignEdgeVCenter', 'Align the vertical centers.')
def _(c): align_icon(c, 'v')


@icon('AlignEdgeBottom', 'Align the bottom edges.')
def _(c): align_icon(c, 'b')


@icon('Warp', 'Warp: bend a layer by the points of a mesh over it.')
def _(c):
    if c.big:
        c.rect(3, 3, 28, 28, 'w')
        for i in range(4):
            t = 3 + i * 25 / 3
            pts = [(3 + j * 25 / 8, t + 3 * math.sin(j * math.pi / 8) * (1 if 0 < i < 3 else 0.5)) for j in range(9)]
            for (a, b) in zip(pts, pts[1:]): c.line(int(a[0]), int(a[1]), int(b[0]), int(b[1]), 'n')
            pts = [(t + 3 * math.sin(j * math.pi / 8) * (1 if 0 < i < 3 else 0.5), 3 + j * 25 / 8) for j in range(9)]
            for (a, b) in zip(pts, pts[1:]): c.line(int(a[0]), int(a[1]), int(b[0]), int(b[1]), 'n')
        for (x, y) in ((3, 3), (28, 3), (3, 28), (28, 28)):
            c.rect(x - 1, y - 1, x + 1, y + 1, 'k')
    else:
        c.rect(1, 1, 14, 14, 'w')
        for t in (1, 7, 14):
            c.line(1, t, 7, t + 1 if 0 < t < 14 else t, 'n'); c.line(7, t + 1 if 0 < t < 14 else t, 14, t, 'n')
            c.line(t, 1, t + 1 if 0 < t < 14 else t, 7, 'n'); c.line(t + 1 if 0 < t < 14 else t, 7, t, 14, 'n')
        for (x, y) in ((1, 1), (14, 1), (1, 14), (14, 14)):
            c.px(x, y, 'k')


@icon('PuppetWarp', 'Puppet Warp: pins on a layer; dragging one bends it round the others.')
def _(c):
    if c.big:
        c.shape([(6, 26), (10, 10), (16, 6), (22, 10), (26, 26), (20, 20), (12, 20)], 's')
        c.outline([(6, 26), (10, 10), (16, 6), (22, 10), (26, 26), (20, 20), (12, 20)], 'k')
        for (x, y) in ((10, 12), (22, 12), (16, 8)):
            c.disc(x, y, 2.5, 'y')
    else:
        c.shape([(2, 13), (5, 5), (8, 3), (11, 5), (14, 13), (10, 10), (6, 10)], 's')
        for (x, y) in ((5, 6), (11, 6), (8, 4)):
            c.px(x, y, 'y')


@icon('Sky', 'Sky Replacement: a new sky in place of the one in the picture.')
def _(c):
    a = c.layer()
    if c.big:
        a.rect(1, 1, 30, 22, 'c')
        a.rect(1, 23, 30, 30, 'G')
        a.disc(10, 12, 5, 'w', None); a.disc(16, 9, 6, 'w', None); a.disc(22, 12, 5, 'w', None)
        a.rect(10, 12, 22, 16, 'w')
        a.frame(1, 1, 30, 30, 'k')
    else:
        a.rect(0, 0, 15, 10, 'c')
        a.rect(0, 11, 15, 15, 'G')
        a.disc(5, 6, 2.5, 'w', None); a.disc(8, 4.5, 3, 'w', None); a.disc(11, 6, 2.5, 'w', None)
        a.rect(5, 6, 11, 8, 'w')
        a.frame(0, 0, 15, 15, 'k')
    c.over(a)


@icon('FillLayer', 'A fill layer: a solid color, a gradient or a pattern filling the layer.')
def _(c):
    if c.big:
        c.rect(3, 3, 28, 28, 'w')
        c.shape([(3, 28), (28, 3), (28, 28)], 'b')
        c.frame(3, 3, 28, 28, 'k')
    else:
        c.rect(1, 1, 14, 14, 'w')
        c.shape([(1, 14), (14, 1), (14, 14)], 'b')
        c.frame(1, 1, 14, 14, 'k')


def sel_squares(c, mode):
    """Two squares, the second over the first: how a new selection meets
    the one there is (new, add, subtract, intersect)."""
    k = 2 if c.big else 1
    a = (1 * k, 1 * k, 9 * k + (k - 1), 9 * k + (k - 1))
    b = (6 * k, 6 * k, 14 * k + (k - 1), 14 * k + (k - 1))
    def inner(r):
        return (r[0] + 1, r[1] + 1, r[2] - 1, r[3] - 1)
    if mode == 'new':
        r = (3 * k, 3 * k, 12 * k + (k - 1), 12 * k + (k - 1))
        c.rect(*r, 'w'); c.frame(*r, 'k')
    elif mode == 'add':
        c.frame(*a, 'k'); c.frame(*b, 'k')
        c.rect(*inner(a), 'w'); c.rect(*inner(b), 'w')
    elif mode == 'subtract':
        c.rect(*a, 'w'); c.frame(*a, 'k')
        c.rect(*inner(b), '.'); c.frame(*b, 'k')
    else:
        c.frame(*a, 'k'); c.frame(*b, 'k')
        c.rect(b[0] + 1, b[1] + 1, a[2] - 1, a[3] - 1, 'w')


icon('SelNew', 'A new selection.')(lambda c: sel_squares(c, 'new'))
icon('SelAdd', 'Add to the selection.')(lambda c: sel_squares(c, 'add'))
icon('SelSubtract', 'Subtract from the selection.')(lambda c: sel_squares(c, 'subtract'))
icon('SelIntersect', 'Intersect with the selection.')(lambda c: sel_squares(c, 'intersect'))


def grad_square(c, fn):
    """A framed square shaded black to white by `fn(u, v)` (u, v in -1..1),
    in bands of the four grays."""
    import math
    n = c.n
    m = 1 if not c.big else 2
    for y in range(m, n - m):
        for x in range(m, n - m):
            u = (x + 0.5 - n / 2) / (n / 2 - m)
            v = (y + 0.5 - n / 2) / (n / 2 - m)
            t = max(0.0, min(1.0, fn(u, v, math)))
            c.px(x, y, 'kgsw'[max(0, min(3, int(t * 4)))])
    c.frame(m - 1, m - 1, n - m, n - m, 'k')


icon('GradLinear', 'A linear gradient.')(lambda c: grad_square(c, lambda u, v, M: (u + 1) / 2))
icon('GradRadial', 'A radial gradient.')(
    lambda c: grad_square(c, lambda u, v, M: 1 - M.hypot(u, v) / 1.2))
icon('GradAngle', 'An angle gradient.')(
    lambda c: grad_square(c, lambda u, v, M: ((M.atan2(v, u) + M.pi) / M.pi) % 1.0))
icon('GradReflected', 'A reflected gradient.')(lambda c: grad_square(c, lambda u, v, M: 1 - abs(u)))
icon('GradDiamond', 'A diamond gradient.')(
    lambda c: grad_square(c, lambda u, v, M: 1 - (abs(u) + abs(v)) / 1.6))



def dashed_poly(c, pts, col, on=2, off=2, closed=True):
    """A polygon's sides drawn dashed (a marquee's marching ants, still)."""
    n = len(pts)
    k = 0
    for i in range(n if closed else n - 1):
        x0, y0 = pts[i]
        x1, y1 = pts[(i + 1) % n]
        steps = max(abs(x1 - x0), abs(y1 - y0), 1)
        for t in range(steps):
            x = int(round(x0 + (x1 - x0) * t / steps))
            y = int(round(y0 + (y1 - y0) * t / steps))
            if k % (on + off) < on:
                c.px(x, y, col)
            k += 1


@icon('MarqueeRow', 'The single row marquee: select one row of pixels.')
def _(c):
    if c.big:
        for x in range(1, 31, 4):
            c.hline(x, x + 1, 15, 'k'); c.hline(x, x + 1, 16, 'k')
        c.vline(2, 10, 21, 'g'); c.vline(29, 10, 21, 'g')
    else:
        for x in range(0, 16, 3):
            c.hline(x, x + 1, 7, 'k')
        c.vline(0, 4, 10, 'g'); c.vline(15, 4, 10, 'g')


@icon('MarqueeColumn', 'The single column marquee: select one column of pixels.')
def _(c):
    if c.big:
        for y in range(1, 31, 4):
            c.vline(15, y, y + 1, 'k'); c.vline(16, y, y + 1, 'k')
        c.hline(10, 21, 2, 'g'); c.hline(10, 21, 29, 'g')
    else:
        for y in range(0, 16, 3):
            c.vline(7, y, y + 1, 'k')
        c.hline(4, 10, 0, 'g'); c.hline(4, 10, 15, 'g')


@icon('PolyLasso', 'The polygonal lasso: click the corners of a selection with straight sides.')
def _(c):
    if c.big:
        pts = [(3, 12), (13, 3), (28, 8), (23, 25), (7, 21)]
        dashed_poly(c, pts, 'k', 3, 2)
        for (x, y) in pts:
            c.rect(x - 1, y - 1, x + 1, y + 1, 'n')
    else:
        pts = [(1, 6), (7, 1), (14, 4), (11, 13), (3, 11)]
        dashed_poly(c, pts, 'k', 2, 1)
        for (x, y) in pts:
            c.px(x, y, 'n')


def t_shape(big):
    if big:
        return [(x, y) for y in range(4, 10) for x in range(4, 28)] + \
               [(x, y) for y in range(10, 29) for x in range(13, 19)]
    return [(x, y) for y in range(1, 5) for x in range(1, 15)] + \
           [(x, y) for y in range(5, 15) for x in range(6, 10)]


@icon('TypeMask', 'The type mask tool: what is typed becomes a selection.')
def _(c):
    cells = set(t_shape(c.big))
    for (x, y) in cells:
        edge = any((x + dx, y + dy) not in cells for dx, dy in ((1, 0), (-1, 0), (0, 1), (0, -1)))
        if edge and (x + y) % 2 == 0:
            c.px(x, y, 'k')


@icon('PatternStamp', 'The pattern stamp: paint with a pattern.')
def _(c):
    if c.big:
        c.ellipse(16, 7, 5, 4.5, 'm')
        c.rect(13, 10, 18, 18, 's'); c.frame(13, 10, 18, 18, 'k')
        c.rect(4, 18, 27, 23, 'o'); c.frame(4, 18, 27, 23, 'k')
        for y in range(25, 31, 2):
            for x in range(4, 28, 2):
                c.rect(x, y, x, y, 'r' if ((x + y) // 2) % 2 == 0 else 'b')
    else:
        c.ellipse(7.5, 3, 2.6, 2.4, 'm')
        c.rect(6, 4, 9, 8, 's'); c.frame(6, 4, 9, 8, 'k')
        c.rect(2, 9, 13, 11, 'o'); c.frame(2, 9, 13, 11, 'k')
        for x in range(2, 14):
            c.px(x, 13, 'r' if x % 2 == 0 else 'b')
            c.px(x, 14, 'b' if x % 2 == 0 else 'r')


@icon('MoreTools', 'More tools, and the toolbar edited (Edit Toolbar).')
def _(c):
    if c.big:
        for x in (5, 14, 23):
            c.rect(x, 14, x + 3, 17, 'k')
    else:
        for x in (2, 7, 12):
            c.rect(x, 7, x + 1, 8, 'k')



@icon('PerspCrop', 'The perspective crop tool: four corners made a rectangle again.')
def _(c):
    if c.big:
        c.rect(7, 2, 9, 24, 'k'); c.rect(7, 22, 30, 24, 'k')
        c.rect(2, 7, 24, 9, 'k'); c.rect(22, 7, 24, 29, 'k')
        for (x0, x1) in ((11, 13), (15, 15), (20, 18)):
            c.line(x0, 20, x1, 11, 'b')
        c.line(12, 16, 19, 16, 'b')
    else:
        c.vline(4, 1, 11, 'k'); c.hline(4, 15, 11, 'k')
        c.hline(1, 11, 4, 'k'); c.vline(11, 4, 14, 'k')
        c.line(6, 10, 7, 6, 'b'); c.line(9, 10, 8, 6, 'b')


@icon('BgEraser', 'The background eraser: rubs out the color sampled under its middle, keeps the edges.')
def _(c):
    a = c.layer()
    if c.big:
        a.rect(1, 19, 12, 30, 'w')
        for y in range(19, 31, 3):
            for x in range(1, 13, 3):
                if ((x - 1) // 3 + (y - 19) // 3) % 2 == 0:
                    a.rect(x, y, x + 2, y + 2, 'g')
        a.shape([(14, 4), (29, 4), (23, 19), (8, 19)], 'w')
        a.shape([(8, 19), (23, 19), (23, 23), (8, 23)], 's')
        a.shape([(23, 19), (29, 4), (29, 8), (23, 23)], 'g')
        a.ring(16, 26, 3, 4, 'k'); a.px(16, 26, 'k')
    else:
        a.rect(0, 10, 5, 15, 'w')
        for y in range(10, 16, 2):
            for x in range(0, 6, 2):
                if (x // 2 + (y - 10) // 2) % 2 == 0:
                    a.rect(x, y, x + 1, y + 1, 'g')
        a.shape([(7, 2), (14, 2), (11, 9), (4, 9)], 'w')
        a.rect(4, 9, 11, 10, 's'); a.frame(4, 9, 11, 10, 'k')
        a.line(11, 9, 14, 2, 'k')
        a.frame(7, 12, 9, 14, 'k')
    c.over(a)


@icon('FreeformPen', 'The freeform pen: a path drawn as the hand goes.')
def _(c):
    a = c.layer()
    _pen(c, a)
    if c.big:
        pts = [(18, 27), (20, 23), (23, 22), (24, 26), (27, 28), (30, 23)]
        for i in range(len(pts) - 1):
            a.line(pts[i][0], pts[i][1], pts[i + 1][0], pts[i + 1][1], 'k')
            a.line(pts[i][0], pts[i][1] + 1, pts[i + 1][0], pts[i + 1][1] + 1, 'k')
    else:
        for (x0, y0, x1, y1) in ((9, 14, 10, 12), (10, 12, 12, 13), (12, 13, 13, 15), (13, 15, 15, 12)):
            a.line(x0, y0, x1, y1, 'k')
    c.over(a)


@icon('CurvaturePen', 'The curvature pen: click points, the curve goes smoothly through them.')
def _(c):
    a = c.layer()
    _pen(c, a)
    if c.big:
        a.arc(24, 31, 7, 1.6, 200, 340, 'k')
        for (x, y) in ((17, 28), (24, 24), (31, 28)):
            a.rect(x - 1, y - 1, x + 1, y + 1, 'w'); a.frame(x - 1, y - 1, x + 1, y + 1, 'k')
    else:
        a.arc(12.5, 16, 3.5, 1.1, 200, 340, 'k')
        a.px(9, 14, 'k'); a.px(12, 12, 'k'); a.px(15, 14, 'k')
    c.over(a)


@icon('StarShape', 'The star tool: a star of so many points.')
def _(c):
    import math as _m
    n = c.n
    cx, cy = n / 2, n / 2 + (1 if c.big else 0.5)
    ro = n * 0.46
    ri = ro * 0.45
    pts = []
    for i in range(10):
        a = -_m.pi / 2 + i * _m.pi / 5
        r = ro if i % 2 == 0 else ri
        pts.append((cx + _m.cos(a) * r, cy + _m.sin(a) * r))
    c.shape([(round(x), round(y)) for (x, y) in pts], 'y')


@icon('Spiral', 'The spiral tool: an open spiral.')
def _(c):
    import math as _m
    n = c.n
    cx = cy = n / 2
    w = 2.2 if c.big else 1.2
    prev = None
    for i in range(0, 3 * 48 + 1):
        t = i / 48
        r = (n * 0.45) * (0.72 ** (t * 1.6))
        a = -_m.pi / 2 + t * 2 * _m.pi
        p = (cx + _m.cos(a) * r, cy + _m.sin(a) * r)
        if prev is not None:
            c.stroke(prev[0], prev[1], p[0], p[1], w, 'k')
        prev = p


@icon('ColorReplace', 'The color replacement tool: paint a new color over one color, keeping its light.')
def _(c):
    a = c.layer()
    if c.big:
        a.stroke(26, 5, 10, 21, 6.5, 'r')
        a.stroke(28.5, 2.5, 25, 6, 6.5, 's')
        a.outlined()
        b = c.layer()
        b.rect(2, 22, 13, 30, 'b'); b.frame(2, 22, 13, 30, 'k')
        b.rect(8, 24, 18, 31, 'y'); b.frame(8, 24, 18, 31, 'k')
        a.over(b)
    else:
        a.line(14, 1, 6, 9, 'k'); a.line(13, 1, 5, 9, 'r'); a.line(14, 2, 6, 10, 'r')
        a.rect(1, 10, 6, 14, 'b'); a.frame(1, 10, 6, 14, 'k')
        a.rect(5, 11, 9, 15, 'y'); a.frame(5, 11, 9, 15, 'k')
    c.over(a)



@icon('Slice', 'The slice tool: cut the image into parts for the web.')
def _(c):
    a = c.layer()
    if c.big:
        # a knife: a gray blade, a black handle, over a dashed cut
        a.shape([(4, 26), (22, 8), (26, 12), (9, 28)], 's')
        a.line(6, 25, 22, 9, 'w')
        a.stroke(23, 8, 28, 3, 5, 'k')
        for k in range(0, 28, 4):
            a.hline(2 + k, min(29, 3 + k), 30, 'b')
    else:
        a.shape([(2, 13), (11, 4), (13, 6), (5, 14)], 's')
        a.line(3, 12, 11, 4, 'w')
        a.line(12, 4, 14, 2, 'k'); a.line(12, 3, 14, 1, 'k'); a.line(13, 4, 15, 2, 'k')
        for k in range(0, 14, 3):
            a.px(1 + k, 15, 'b')
    c.over(a)


@icon('Note', 'The note tool: a note pinned on the image.')
def _(c):
    if c.big:
        c.rect(4, 4, 27, 27, 'y'); c.frame(4, 4, 27, 27, 'k')
        c.shape([(21, 27), (27, 21), (27, 27)], 'o')
        for y in (10, 15, 20):
            c.hline(8, 22 if y < 20 else 17, y, 'g')
    else:
        c.rect(2, 2, 13, 13, 'y'); c.frame(2, 2, 13, 13, 'k')
        c.px(12, 12, 'o'); c.px(11, 12, 'o'); c.px(12, 11, 'o')
        for y in (5, 8):
            c.hline(4, 10, y, 'g')


@icon('Count', 'The count tool: numbers put on things to count them.')
def _(c):
    if c.big:
        c.line(9, 9, 22, 12, 'k'); c.line(22, 12, 13, 23, 'k')
        for (x, y) in ((8, 8), (23, 12), (13, 24)):
            c.disc(x, y, 5, 'c')
    else:
        c.line(4, 4, 11, 6, 'k'); c.line(11, 6, 6, 12, 'k')
        for (x, y) in ((4, 4), (11, 6), (6, 12)):
            c.disc(x, y, 2.6, 'c')


@icon('RotateView', 'The rotate view tool: the canvas turned on the screen.')
def _(c):
    a = c.layer()
    if c.big:
        # a tilted page, a curved arrow round it
        a.shape([(9, 6), (25, 10), (21, 26), (5, 22)], 'w')
        a.line(11, 11, 21, 13, 'g'); a.line(10, 15, 20, 17, 'g'); a.line(9, 19, 17, 21, 'g')
        a.arc(16, 16, 13, 2.2, 200, 330, 'b')
        a.shape([(25, 4), (31, 8), (24, 11)], 'b', 'b')
    else:
        a.shape([(4, 3), (12, 5), (10, 13), (2, 11)], 'w')
        a.line(5, 6, 10, 7, 'g'); a.line(4, 9, 9, 10, 'g')
        a.arc(8, 8, 7, 1.3, 200, 330, 'b')
        a.px(13, 2, 'b'); a.px(14, 3, 'b'); a.px(12, 4, 'b'); a.px(13, 3, 'b'); a.px(14, 4, 'b')
    c.over(a)


@icon('ArtHistory', 'The art history brush: strokes in the style of a snapshot.')
def _(c):
    a = c.layer()
    if c.big:
        a.stroke(20, 4, 9, 19, 4, 'm')
        a.shape([(6, 18), (11, 21), (8, 27), (3, 26)], 'y')
        a.arc(21, 22, 6, 2, 180, 470, 'p')
        a.arc(21, 22, 2.5, 1.5, 0, 360, 'p')
    else:
        a.line(10, 2, 5, 9, 'm'); a.line(11, 2, 6, 9, 'm')
        a.shape([(3, 9), (6, 10), (4, 14), (1, 13)], 'y')
        a.arc(11, 11, 3.5, 1.2, 180, 470, 'p')
    c.over(a)


@icon('Timeline', 'The timeline: the frames of an animation.')
def _(c):
    if c.big:
        c.rect(1, 8, 30, 23, 'k')
        for x in range(3, 30, 4):
            c.rect(x, 9, x + 1, 10, 'w'); c.rect(x, 21, x + 1, 22, 'w')
        for k, col in enumerate(('c', 'y', 'p')):
            c.rect(3 + 9 * k, 12, 9 + 9 * k, 19, col)
    else:
        c.rect(0, 4, 15, 11, 'k')
        for x in range(1, 15, 2):
            c.px(x, 4, 'w'); c.px(x, 11, 'w')
        for k, col in enumerate(('c', 'y', 'p')):
            c.rect(1 + 5 * k, 6, 4 + 5 * k, 9, col)


@icon('ParaStyle', 'Paragraph styles: the look of a paragraph kept by name.')
def _(c):
    if c.big:
        c.rect(12, 4, 15, 28, 'k'); c.rect(19, 4, 22, 28, 'k')
        c.disc(11, 11, 7, 'k', 'k')
        c.rect(12, 4, 26, 6, 'k')
    else:
        c.rect(7, 2, 8, 14, 'k'); c.rect(10, 2, 11, 14, 'k')
        c.disc(6, 5, 3.6, 'k', 'k')
        c.rect(7, 2, 13, 2, 'k')


@icon('CharStyle', 'Character styles: the look of letters kept by name.')
def _(c):
    if c.big:
        c.shape([(4, 28), (13, 4), (19, 4), (28, 28), (22, 28), (20, 22), (12, 22), (10, 28)], 'b')
        c.shape([(13, 17), (16, 9), (19, 17)], 'w')
    else:
        c.shape([(1, 14), (6, 2), (9, 2), (14, 14), (11, 14), (10, 11), (5, 11), (4, 14)], 'b')
        c.px(7, 6, 'w'); c.px(7, 7, 'w'); c.px(6, 8, 'w'); c.px(8, 8, 'w')


@icon('OpenType', 'OpenType features: ligatures, alternates, stylistic sets.')
def _(c):
    if c.big:
        c.ring(12, 16, 6, 10, 'k')
        c.rect(19, 6, 31, 9, 'k'); c.rect(24, 6, 27, 27, 'k')
    else:
        c.ring(6, 8, 3, 5.5, 'k')
        c.rect(9, 3, 15, 4, 'k'); c.rect(11, 3, 12, 14, 'k')


@icon('ScriptEdit', 'A script: lines of code that run.')
def _(c):
    if c.big:
        c.rect(3, 4, 28, 27, 'w'); c.frame(3, 4, 28, 27, 'k'); c.rect(4, 5, 27, 8, 'n')
        c.line(7, 13, 11, 16, 'b'); c.line(11, 16, 7, 19, 'b')
        c.hline(13, 22, 19, 'k'); c.hline(7, 25, 23, 'g')
    else:
        c.rect(1, 2, 14, 13, 'w'); c.frame(1, 2, 14, 13, 'k'); c.hline(2, 13, 3, 'n')
        c.line(3, 6, 5, 8, 'b'); c.line(5, 8, 3, 10, 'b'); c.hline(7, 11, 10, 'k')


@icon('Language', 'The language of the menus and dialogs.')
def _(c):
    if c.big:
        c.disc(16, 16, 13, 'c')
        c.ellipse(16, 16, 5, 13, 'k')
        c.hline(4, 28, 16, 'k'); c.hline(6, 26, 10, 'k'); c.hline(6, 26, 22, 'k')
        c.vline(16, 3, 29, 'k')
    else:
        c.disc(8, 8, 6.6, 'c')
        c.ellipse(8, 8, 2, 6, 'k')
        c.hline(2, 14, 8, 'k'); c.vline(8, 2, 14, 'k')



@icon('Layers', 'The Layers panel: sheets stacked, the image made of them.')
def _(c):
    if c.big:
        for k, col in enumerate(('c', 'y', 'w')):
            y = 18 - 6 * k
            c.shape([(2 + 2 * k, y + 5), (14 + 2 * k, y), (29 - 2 * k, y + 5), (17 - 2 * k, y + 10)], col)
    else:
        for k, col in enumerate(('c', 'y', 'w')):
            y = 9 - 3 * k
            c.shape([(1 + k, y + 3), (7 + k, y), (14 - k, y + 3), (8 - k, y + 6)], col)


@icon('Channels', 'The Channels panel: the red, green and blue of the image.')
def _(c):
    if c.big:
        for (x, y, col) in ((11, 11, 'r'), (21, 11, 'l'), (16, 20, 'b')):
            c.disc(x, y, 8, col, None)
        for (x, y) in ((11, 11), (21, 11), (16, 20)):
            c.ring(x, y, 7.2, 8.2, 'k')
    else:
        for (x, y, col) in ((5, 5.5, 'r'), (10.5, 5.5, 'l'), (7.8, 10.2, 'b')):
            c.disc(x, y, 4.4, col, None)
        for (x, y) in ((5, 5.5), (10.5, 5.5), (7.8, 10.2)):
            c.ring(x, y, 3.7, 4.6, 'k')


@icon('Swatches', 'The Swatches panel: colors kept to paint with.')
def _(c):
    cols = ('r', 'y', 'l', 'c', 'b', 'p', 'k', 'g', 'w')
    if c.big:
        for k, col in enumerate(cols):
            x = 2 + (k % 3) * 10
            y = 2 + (k // 3) * 10
            c.rect(x, y, x + 8, y + 8, col); c.frame(x, y, x + 8, y + 8, 'k')
    else:
        for k, col in enumerate(cols):
            x = 1 + (k % 3) * 5
            y = 1 + (k // 3) * 5
            c.rect(x, y, x + 3, y + 3, col); c.frame(x, y, x + 3, y + 3, 'k')


@icon('ColorPanel', 'The Color panel: the foreground and background colors, mixed by sliders.')
def _(c):
    if c.big:
        c.rect(12, 12, 28, 28, 'w'); c.frame(12, 12, 28, 28, 'k')
        c.rect(3, 3, 19, 19, 'r'); c.frame(3, 3, 19, 19, 'k')
        c.hline(4, 18, 4, 'w'); c.vline(4, 4, 18, 'w'); c.hline(4, 18, 18, 'm'); c.vline(18, 4, 18, 'm')
    else:
        c.rect(6, 6, 14, 14, 'w'); c.frame(6, 6, 14, 14, 'k')
        c.rect(1, 1, 9, 9, 'r'); c.frame(1, 1, 9, 9, 'k')


@icon('Histogram', 'The Histogram panel: how many pixels there are at each lightness.')
def _(c):
    if c.big:
        c.rect(2, 4, 29, 27, 'w'); c.frame(2, 4, 29, 27, 'k')
        hs = [2, 3, 5, 8, 12, 15, 17, 16, 13, 10, 9, 11, 14, 18, 20, 17, 12, 8, 6, 5, 4, 6, 9, 7, 4, 2]
        for i, v in enumerate(hs):
            c.vline(3 + i, 26 - v, 26, 'k')
    else:
        c.rect(0, 2, 15, 14, 'w'); c.frame(0, 2, 15, 14, 'k')
        hs = [1, 3, 6, 8, 7, 5, 6, 9, 10, 7, 4, 3, 5, 2]
        for i, v in enumerate(hs):
            c.vline(1 + i, 13 - v, 13, 'k')


@icon('Glyphs', 'The Glyphs panel: every character of a font, to put in.')
def _(c):
    if c.big:
        c.rect(2, 2, 29, 29, 'w'); c.frame(2, 2, 29, 29, 'k')
        c.vline(11, 3, 28, 'g'); c.vline(20, 3, 28, 'g'); c.hline(3, 28, 11, 'g'); c.hline(3, 28, 20, 'g')
        c.rect(12, 12, 19, 19, 'n')
        c.shape([(13, 18), (15.5, 13), (18, 18)], 'w', 'w')
        for (x, y) in ((6, 6), (15, 6), (24, 6), (6, 15), (24, 15), (6, 24), (15, 24), (24, 24)):
            c.rect(x - 1, y - 1, x + 1, y + 1, 'k')
    else:
        c.rect(0, 0, 15, 15, 'w'); c.frame(0, 0, 15, 15, 'k')
        c.vline(5, 1, 14, 'g'); c.vline(10, 1, 14, 'g'); c.hline(1, 14, 5, 'g'); c.hline(1, 14, 10, 'g')
        c.rect(6, 6, 9, 9, 'n')
        for (x, y) in ((2, 2), (7, 2), (12, 2), (2, 7), (12, 7), (2, 12), (7, 12), (12, 12)):
            c.px(x, y, 'k'); c.px(x + 1, y + 1, 'k')


@icon('Commands', 'The Commands panel: a button for each command.')
def _(c):
    if c.big:
        for k, y in enumerate((3, 12, 21)):
            c.bevel(3, y, 28, y + 7)
            c.hline(7, 20 - 3 * k, y + 4, 'k')
    else:
        for k, y in enumerate((1, 6, 11)):
            c.bevel(1, y, 14, y + 3)
            c.hline(4, 10 - k, y + 2, 'k')


@icon('ToolPresets', 'Tool presets: a tool with its settings, kept by name.')
def _(c):
    if c.big:
        c.shape([(3, 12), (12, 3), (28, 3), (28, 19), (19, 28), (3, 28)], 'y')
        c.disc(22, 9, 2.5, 'w')
        c.hline(7, 18, 16, 'k'); c.hline(7, 15, 21, 'k')
    else:
        c.shape([(1, 6), (6, 1), (14, 1), (14, 9), (9, 14), (1, 14)], 'y')
        c.px(11, 4, 'k')
        c.hline(4, 9, 8, 'k'); c.hline(4, 7, 11, 'k')


@icon('LayerComps', 'Layer comps: how the layers are set, kept by name.')
def _(c):
    if c.big:
        c.rect(9, 3, 29, 21, 'c'); c.frame(9, 3, 29, 21, 'k')
        c.rect(3, 10, 23, 28, 'w'); c.frame(3, 10, 23, 28, 'k')
        c.line(7, 19, 11, 23, 'G'); c.line(11, 23, 19, 14, 'G')
        c.line(7, 20, 11, 24, 'G'); c.line(11, 24, 19, 15, 'G')
    else:
        c.rect(5, 1, 14, 10, 'c'); c.frame(5, 1, 14, 10, 'k')
        c.rect(1, 5, 10, 14, 'w'); c.frame(1, 5, 10, 14, 'k')
        c.line(3, 9, 5, 11, 'G'); c.line(5, 11, 8, 7, 'G')


@icon('Libraries', 'Libraries: colors, styles and pictures kept to use again.')
def _(c):
    if c.big:
        for (x0, x1, col, top) in ((3, 8, 'r', 5), (9, 14, 'b', 3), (15, 19, 'G', 7)):
            c.rect(x0, top, x1, 27, col); c.frame(x0, top, x1, 27, 'k')
            c.hline(x0 + 1, x1 - 1, top + 3, 'y')
        c.shape([(20, 9), (24, 8), (29, 26), (25, 27)], 'P')
        c.hline(1, 30, 28, 'k'); c.hline(1, 30, 29, 'o')
    else:
        for (x0, x1, col, top) in ((1, 3, 'r', 3), (4, 6, 'b', 1), (7, 9, 'G', 4)):
            c.rect(x0, top, x1, 13, col); c.frame(x0, top, x1, 13, 'k')
        c.shape([(10, 5), (12, 4), (15, 12), (13, 13)], 'P')
        c.hline(0, 15, 14, 'k')


@icon('Scratch', 'The Scratch panel: paper to try colors and brushes on.')
def _(c):
    if c.big:
        c.rect(3, 3, 28, 28, 'w'); c.frame(3, 3, 28, 28, 'k')
        c.stroke(6, 22, 12, 9, 2, 'r'); c.stroke(12, 9, 17, 21, 2, 'b'); c.stroke(17, 21, 25, 7, 2, 'G')
    else:
        c.rect(1, 1, 14, 14, 'w'); c.frame(1, 1, 14, 14, 'k')
        c.line(3, 11, 6, 4, 'r'); c.line(6, 4, 9, 11, 'b'); c.line(9, 11, 12, 3, 'G')


@icon('ColorThemes', 'Color themes: five colors that go together.')
def _(c):
    cols = ('n', 'b', 'c', 'y', 'r')
    if c.big:
        for k, col in enumerate(cols):
            c.rect(2 + 6 * k, 6, 7 + 6 * k, 25, col)
        c.frame(2, 6, 31, 25, 'k')
        for k in range(1, 5): c.vline(2 + 6 * k, 6, 25, 'k')
    else:
        for k, col in enumerate(cols):
            c.rect(1 + 3 * k, 3, 3 + 3 * k, 12, col)
        c.frame(0, 2, 15, 13, 'k')


@icon('Patterns', 'The Patterns panel: tiles that repeat.')
def _(c):
    if c.big:
        c.rect(2, 2, 29, 29, 'y'); c.frame(2, 2, 29, 29, 'k')
        for y in range(3, 29, 7):
            for x in range(3, 29, 7):
                c.disc(x + 3, y + 3, 2, 'r', 'm')
    else:
        c.rect(0, 0, 15, 15, 'y'); c.frame(0, 0, 15, 15, 'k')
        for y in (3, 8, 12):
            for x in (3, 8, 12):
                c.px(x, y, 'r'); c.px(x + 1, y, 'r'); c.px(x, y + 1, 'm'); c.px(x + 1, y + 1, 'm')


@icon('BrushSettings', 'Brush settings: the shape of the tip and how it changes as it paints.')
def _(c):
    if c.big:
        c.disc(10, 10, 7, 'k', 'k')
        for k, (y, v) in enumerate(((20, 18), (24, 9), (28, 23))):
            c.hline(3, 28, y, 'g')
            c.rect(v - 1, y - 2, v + 1, y + 2, 's'); c.frame(v - 1, y - 2, v + 1, y + 2, 'k')
        c.stroke(30, 2, 20, 12, 2, 'm')
    else:
        c.disc(5, 5, 3.6, 'k', 'k')
        for (y, v) in ((10, 9), (13, 4)):
            c.hline(1, 14, y, 'g')
            c.rect(v, y - 1, v + 1, y + 1, 'k')
        c.line(14, 1, 10, 5, 'm')


@icon('QuickActions', 'Quick actions: an edit in one click.')
def _(c):
    if c.big:
        c.shape([(19, 1), (6, 18), (15, 18), (11, 31), (26, 12), (17, 12), (22, 1)], 'y')
        c.px(4, 6, 'c'); c.px(3, 6, 'c'); c.px(5, 6, 'c'); c.px(4, 5, 'c'); c.px(4, 7, 'c')
        c.px(27, 24, 'c'); c.px(26, 24, 'c'); c.px(28, 24, 'c'); c.px(27, 23, 'c'); c.px(27, 25, 'c')
    else:
        c.shape([(9, 0), (3, 9), (7, 9), (5, 15), (13, 6), (9, 6), (11, 0)], 'y')
        c.px(1, 3, 'c'); c.px(14, 12, 'c')

@icon('SelectionBrush', 'The selection brush: paint what to select (Alt: take it away).')
def _(c):
    a = c.layer()
    if c.big:
        # (the selection: marching ants round a square)
        for x in range(2, 22, 4):
            a.hline(x, x + 1, 2, 'k'); a.hline(x, x + 1, 19, 'k')
        for y in range(2, 20, 4):
            a.vline(2, y, y + 1, 'k'); a.vline(21, y, y + 1, 'k')
        a.stroke(30, 30, 17, 17, 3.4, 'o')
        a.stroke(17, 17, 9, 9, 5.2, 'r')
        a.outlined()
    else:
        for x in range(0, 11, 2):
            a.px(x, 0, 'k'); a.px(x, 10, 'k')
        for y in range(0, 11, 2):
            a.px(0, y, 'k'); a.px(10, y, 'k')
        a.stroke(15, 15, 9, 9, 1.6, 'o')
        a.stroke(9, 9, 4.5, 4.5, 2.8, 'r')
        a.outlined()
    c.over(a)


@icon('AdjustBrush', 'The adjustment brush: paint an adjustment (lighter, more colorful...) where it is wanted.')
def _(c):
    a = c.layer()
    if c.big:
        a.disc(11, 11, 9, 'w')
        for y in range(32):
            for x in range(11, 32):
                if a.get(x, y) == 'w':
                    a.px(x, y, 'k')
        a.stroke(30, 30, 19, 19, 3.4, 'o')
        a.stroke(19, 19, 13, 13, 4.5, 's')
        a.outlined()
    else:
        a.disc(5.5, 5.5, 4.6, 'w')
        for y in range(16):
            for x in range(6, 16):
                if a.get(x, y) == 'w':
                    a.px(x, y, 'k')
        a.stroke(15, 15, 10, 10, 1.6, 'o')
        a.stroke(10, 10, 7.5, 7.5, 2.4, 's')
        a.outlined()
    c.over(a)


@icon('ContentTrace', 'The content-aware tracing tool: point at an edge of the picture, click: a path along it.')
def _(c):
    a = c.layer()
    _pen(c, a)
    if c.big:
        # (an edge of the picture, lit up where it is traced)
        pts = [(15, 31), (17, 26), (21, 24), (25, 25), (28, 22), (31, 21)]
        for i in range(len(pts) - 1):
            a.line(pts[i][0], pts[i][1], pts[i + 1][0], pts[i + 1][1], 'b')
            a.line(pts[i][0], pts[i][1] + 1, pts[i + 1][0], pts[i + 1][1] + 1, 'b')
        for (x, y) in ((17, 26), (25, 25), (31, 21)):
            a.rect(x - 1, y - 1, x + 1, y + 1, 'w'); a.frame(x - 1, y - 1, x + 1, y + 1, 'k')
    else:
        for (x0, y0, x1, y1) in ((8, 15, 10, 12), (10, 12, 13, 13), (13, 13, 15, 11)):
            a.line(x0, y0, x1, y1, 'b')
        a.px(10, 12, 'k'); a.px(15, 11, 'k')
    c.over(a)



# ---- every tool an icon of its own (0.72): the drawing program's, the layout program's and the
# photo editor's tools that had another's -------------------------------------------------------

def _art(name, big):
    for n, d, s, b in ICONS:
        if n == name:
            return b if big else s
    raise KeyError(name)


def _base(c, name, box=None):
    """Another icon's art, all of it (or the part outside `box`, which is left clear)."""
    art = _art(name, c.big)
    for y, row in enumerate(art):
        for x, ch in enumerate(row):
            if ch != '.' and not (box and box[0] <= x <= box[2] and box[1] <= y <= box[3]):
                c.px(x, y, ch)


def _corner(c):
    """(the bottom right quarter, where a variant's mark goes: cleared a pixel round it)"""
    return (8, 8, 15, 15) if not c.big else (17, 17, 31, 31)


def _poly_path(pts):
    out = []
    for i in range(len(pts)):
        (x0, y0), (x1, y1) = pts[i], pts[(i + 1) % len(pts)]
        n = int(max(abs(x1 - x0), abs(y1 - y0))) or 1
        for k in range(n):
            out.append((x0 + (x1 - x0) * k / n, y0 + (y1 - y0) * k / n))
    return out


def _u(c):
    return 2 if c.big else 1


def _mark(c, kind):
    """A small mark in the bottom right corner telling a variant from its tool."""
    x0, y0, x1, y1 = _corner(c)
    a = c.layer()
    u = _u(c)
    if kind == 'node':          # an anchor point and its handle: a vector tool
        if c.big:
            a.line(19, 29, 30, 18, 'k')
            a.rect(18, 25, 23, 30, 'w'); a.frame(18, 25, 23, 30, 'k')
            a.disc(29, 19, 2.5, 'b')
        else:
            a.line(10, 14, 15, 9, 'k')
            a.rect(9, 12, 11, 14, 'w'); a.frame(9, 12, 11, 14, 'k')
            a.px(14, 10, 'b'); a.px(15, 9, 'b')
    elif kind == 'magic':       # a sparkle
        cx, cy = (24.5, 24.5) if c.big else (12, 12)
        r = 7 if c.big else 3.5
        a.shape([(cx, cy - r), (cx + r / 3.5, cy - r / 3.5), (cx + r, cy), (cx + r / 3.5, cy + r / 3.5),
                 (cx, cy + r), (cx - r / 3.5, cy + r / 3.5), (cx - r, cy), (cx - r / 3.5, cy - r / 3.5)], 'y')
    elif kind == 'arrow':       # the pointer: picks
        pts = [(0, 0), (0, 10), (3, 7), (5, 11), (7, 10), (5, 6), (9, 6)] if c.big else \
              [(0, 0), (0, 6), (2, 4), (3, 6), (4, 5), (3, 3), (5, 3)]
        ox, oy = (19, 19) if c.big else (9, 9)
        a.shape([(ox + x, oy + y) for (x, y) in pts], 'w')
    elif kind == 'plus':
        if c.big:
            a.rect(23, 18, 26, 31, 'G'); a.rect(18, 23, 31, 26, 'G'); a.outlined()
        else:
            a.rect(11, 9, 12, 15, 'G'); a.rect(9, 11, 14, 13, 'G'); a.outlined()
    elif kind == 'magnet':      # a horseshoe magnet
        if c.big:
            a.arc(24.5, 24, 5.5, 4, 0, 180, 'r')
            a.rect(17, 17, 20, 23, 'r'); a.rect(29, 17, 32, 23, 'r')
            a.rect(17, 17, 20, 18, 's'); a.rect(29, 17, 32, 18, 's')
            a.outlined()
        else:
            a.arc(12, 12, 2.7, 2, 0, 180, 'r')
            a.vline(9, 9, 12, 'r'); a.vline(10, 9, 12, 'r'); a.vline(14, 9, 12, 'r'); a.vline(15, 9, 12, 'r')
            a.px(9, 9, 's'); a.px(10, 9, 's'); a.px(14, 9, 's'); a.px(15, 9, 's')
    elif kind == 'symbol':      # a symbol: a little clover of the drawing program's symbols
        cx, cy = (24.5, 24.5) if c.big else (12, 12)
        r = 3.2 if c.big else 1.7
        for (dx, dy) in ((0, -1), (-1, 0.6), (1, 0.6)):
            a.disc(cx + dx * r * 1.1, cy + dy * r * 1.1, r, 'G', None)
        a.stroke(cx, cy, cx, cy + r * 2.6, 1.6 * u, 'G')
        a.outlined()
    elif kind == 'drop':        # a drop of paint
        cx, cy = (24.5, 26) if c.big else (12, 12.5)
        r = 4.5 if c.big else 2.4
        a.disc(cx, cy, r, 'b', None)
        a.shape([(cx - r * 0.8, cy - r * 0.5), (cx, cy - r * 2.2), (cx + r * 0.8, cy - r * 0.5)], 'b', 'b')
        a.outlined()
        a.px(int(cx - r / 2), int(cy - r / 3), 'w')
    elif kind == 'shape':       # a triangle and a disc: shapes, not pixels
        if c.big:
            a.shape([(18, 31), (24, 19), (30, 31)], 'c')
            a.disc(28, 21, 3.5, 'r')
        else:
            a.shape([(9, 15), (12, 9), (15, 15)], 'c')
            a.px(14, 9, 'r'); a.px(15, 10, 'r')
    elif kind == 'rotate':      # an arrow round
        cx, cy = (24.5, 24.5) if c.big else (12, 12)
        r = 5.5 if c.big else 2.6
        a.arc(cx, cy, r, 2 * u, -60, 220, 'b')
        a.shape([(cx + r + u * 1.5, cy - u * 2), (cx + r - u * 2, cy - u * 2), (cx + r, cy + u)], 'b', 'b')
        a.outlined()
    elif kind == 'size':        # arrows out to two corners
        if c.big:
            a.stroke(19, 30, 30, 19, 2, 'b')
            a.shape([(30, 18), (30, 24), (24, 18)], 'b')
            a.shape([(18, 30), (18, 24), (24, 30)], 'b')
        else:
            a.line(9, 15, 15, 9, 'b')
            a.hline(13, 15, 9, 'b'); a.vline(15, 9, 11, 'b')
            a.hline(9, 11, 15, 'b'); a.vline(9, 13, 15, 'b')
    elif kind == 'in':          # two arrowheads, pointing in to the middle
        if c.big:
            a.shape([(17, 19.5), (23, 24.5), (17, 29.5)], 'b', 'b')
            a.shape([(31.5, 19.5), (25.5, 24.5), (31.5, 29.5)], 'b', 'b')
            a.outlined()
        else:
            a.vline(9, 10, 14, 'b'); a.vline(10, 11, 13, 'b'); a.px(11, 12, 'b')
            a.vline(15, 10, 14, 'b'); a.vline(14, 11, 13, 'b'); a.px(13, 12, 'b')
    elif kind == 'path':        # a dashed path
        if c.big:
            for k in range(0, 14, 4):
                a.stroke(18 + k, 30 - k * 0.6, 20 + k, 28.8 - k * 0.6, 2, 'b')
        else:
            for k in (9, 12, 15):
                a.px(k, 15 - (k - 9) // 2, 'b')
    elif kind == 'grid':        # faces of a Live Paint group
        if c.big:
            a.rect(18, 18, 31, 31, 'w')
            a.rect(18, 18, 24, 24, 'r'); a.rect(25, 25, 31, 31, 'b')
            a.frame(18, 18, 31, 31, 'k'); a.hline(18, 31, 24, 'k'); a.vline(24, 18, 31, 'k')
        else:
            a.rect(9, 9, 15, 15, 'w'); a.rect(9, 9, 11, 11, 'r'); a.rect(13, 13, 15, 15, 'b')
            a.frame(9, 9, 15, 15, 'k'); a.hline(9, 15, 12, 'k'); a.vline(12, 9, 15, 'k')
    elif kind == 'eye':
        if c.big:
            a.ellipse(24.5, 24.5, 7, 4.5, 'w'); a.disc(24.5, 24.5, 3, 'n')
            a.outlined()
        else:
            a.hline(10, 14, 11, 'k'); a.hline(10, 14, 13, 'k'); a.px(9, 12, 'k'); a.px(15, 12, 'k')
            a.hline(10, 14, 12, 'w'); a.px(12, 12, 'n')
    elif kind == 'down':        # an arrow down: running down
        if c.big:
            arrow(a, 'd', 25, 31, 13, 'b')
        else:
            a.vline(12, 9, 13, 'b'); a.hline(10, 14, 13, 'b'); a.hline(11, 13, 14, 'b'); a.px(12, 15, 'b')
            a.outlined()
    elif kind == 'tone':        # half light, half dark: lighter or darker
        cx, cy = (24.5, 24.5) if c.big else (12, 12)
        r = 6.5 if c.big else 3.2
        a.disc(cx, cy, r, 'w')
        for y in range(c.n):
            for x in range(c.n):
                if a.get(x, y) == 'w' and x + 0.5 > cx:
                    a.px(x, y, 'k')
    # (the tool's drawing cleared a pixel round the mark: the mark stands apart)
    for y in range(c.n):
        for x in range(c.n):
            if a.get(x, y) != '.':
                continue
            if any(a.get(x + dx, y + dy) != '.' for dx in (-1, 0, 1) for dy in (-1, 0, 1)):
                c.g[y][x] = '.'
    c.over(a)


def _variant(name, doc, base, mark):
    """An icon: `base`'s art with `mark` in its bottom right corner."""
    def f(c):
        _base(c, base)
        _mark(c, mark)
    icon(name, doc)(f)


# the variants: a tool's own art and what makes it this one
for (name, doc, base, mark) in [
        ('MagicEraser', 'The magic eraser: rub out the pixels of a color at a click.', 'Eraser', 'magic'),
        ('MagicWandShapes', 'The magic wand on shapes: pick the shapes of a color or a stroke.', 'MagicWand', 'shape'),
        ('MagneticLasso', 'The magnetic lasso: an outline that clings to the edges.', 'Lasso', 'magnet'),
        ('LassoPoints', 'The lasso on points: select a path\'s anchor points by drawing round them.', 'PolyLasso', 'node'),
        ('VectorCrop', 'The vector crop: a layer shown in a box, its pixels kept.', 'Crop', 'node'),
        ('SliceSelect', 'The slice select tool: pick a slice to change it.', 'Slice', 'arrow'),
        ('BrushVector', 'The drawing program\'s paintbrush: strokes that stay paths.', 'Brush', 'node'),
        ('PathEraser', 'The path eraser: rub out part of a path.', 'Eraser', 'path'),
        ('EraserShapes', 'The eraser on shapes: rub out part of the shapes it goes over.', 'BgEraser', 'shape'),
        ('SymbolStainer', 'The symbol stainer: tint the symbols under it.', 'ColorReplace', 'symbol'),
        ('SymbolSprayer', 'The symbol sprayer: spray symbols as paint.', 'Airbrush', 'symbol'),
        ('SymbolShifter', 'The symbol shifter: push the symbols under it.', 'MoveTool', 'symbol'),
        ('SymbolSizer', 'The symbol sizer: make the symbols under it bigger (Alt: smaller).', 'ZoomIn', 'symbol'),
        ('SymbolScruncher', 'The symbol scruncher: draw the symbols together (Alt: apart).', 'PuppetWarp', 'in'),
        ('SymbolSpinner', 'The symbol spinner: turn the symbols under it.', 'Refresh', 'symbol'),
        ('ToneBrush', 'The tone brush: lighten or darken on a layer of its own.', 'Brush', 'tone'),
        ('LivePaintBucket', 'The Live Paint bucket: fill a face of a Live Paint group.', 'Bucket', 'grid'),
        ('LivePaintSelect', 'The Live Paint selection tool: pick faces and edges of a Live Paint group.', 'PathSelect', 'grid'),
        ('GroupSelect', 'The group selection tool: a click on a shape picks it, again its group.', 'PathSelect', 'plus'),
        ('ShapeBuilder', 'The shape builder: drag across shapes to join them (Alt: take away).', 'Bucket', 'plus'),
        ('ColorSamplerTool', 'The color sampler: points whose colors the Info panel keeps showing.', 'Eyedropper', 'plus'),
        ('PerspSelect', 'The perspective selection tool: move and size shapes on the perspective grid.', 'PerspCrop', 'arrow'),
        ('TypeMaskVertical', 'The vertical type mask: letters running down that become a selection.', 'TypeMask', 'down'),
        ('TypePathVertical', 'Vertical type on a path: letters standing along a path.', 'TypePath', 'down'),
        ('Join', 'The join tool: drag over two ends of paths to join them.', 'ConvertPoint', 'in'),
        ('Smooth', 'The smooth tool: drag along a path to smooth it.', 'CurvaturePen', 'path'),
        ('Reshape', 'The reshape tool: drag a point of a path and its neighbors follow.', 'CurvaturePen', 'arrow'),
        ('MedianBrush', 'The median brush: paint away speckles, keeping the edges.', 'Blur', 'grid'),
        ('PageTool', 'The page tool: a page\'s size and its place on the pasteboard.', 'New', 'size'),
        ]:
    _variant(name, doc, base, mark)


def _icon2(name, doc):
    """(an icon drawn anew, at both sizes)"""
    return icon(name, doc)


# graphs: each kind its own chart
def _axes(c):
    if c.big:
        c.vline(2, 2, 28, 'k'); c.hline(2, 31, 28, 'k')
    else:
        c.vline(1, 1, 14, 'k'); c.hline(1, 15, 14, 'k')


@_icon2('ChartStacked', 'The stacked column graph tool: columns of parts.')
def _(c):
    b = c.layer()
    cols = ((6, 11, (20, 13)), (14, 19, (14, 6)), (22, 27, (18, 10))) if c.big else \
           ((3, 5, (10, 6)), (7, 9, (7, 3)), (11, 13, (9, 5)))
    for (x0, x1, (mid, top)) in cols:
        b.rect(x0, mid, x1, 27 if c.big else 13, 'b')
        b.rect(x0, top, x1, mid - 1, 'y')
    b.outlined()
    _axes(c)
    c.over(b)


@_icon2('ChartBar', 'The bar graph tool: bars across.')
def _(c):
    b = c.layer()
    bars = ((6, 10, 24, 'r'), (13, 17, 14, 'b'), (20, 24, 28, 'G')) if c.big else \
           ((3, 4, 11, 'r'), (7, 8, 7, 'b'), (11, 12, 14, 'G'))
    for (y0, y1, x1, col) in bars:
        b.rect(3 if c.big else 2, y0, x1, y1, col)
    b.outlined()
    if c.big:
        c.vline(2, 2, 29, 'k'); c.hline(2, 30, 29, 'k')
    else:
        c.vline(1, 1, 14, 'k'); c.hline(1, 15, 14, 'k')
    c.over(b)


@_icon2('ChartBarStacked', 'The stacked bar graph tool: bars of parts across.')
def _(c):
    b = c.layer()
    bars = ((6, 11, 14, 24), (15, 20, 10, 20), (24, 27, 16, 28)) if c.big else \
           ((3, 5, 7, 12), (7, 9, 5, 10), (11, 13, 8, 14))
    for (y0, y1, mid, x1) in bars:
        b.rect(3 if c.big else 2, y0, mid, y1, 'b')
        b.rect(mid + 1, y0, x1, y1, 'y')
    b.outlined()
    if c.big:
        c.vline(2, 2, 29, 'k'); c.hline(2, 30, 29, 'k')
    else:
        c.vline(1, 1, 14, 'k'); c.hline(1, 15, 14, 'k')
    c.over(b)


@_icon2('ChartLine', 'The line graph tool: points joined by a line.')
def _(c):
    _axes(c)
    pts = [(5, 22), (11, 14), (17, 18), (23, 8), (29, 11)] if c.big else [(3, 11), (6, 7), (9, 9), (12, 4), (15, 6)]
    for i in range(len(pts) - 1):
        if c.big:
            c.stroke(pts[i][0], pts[i][1], pts[i + 1][0], pts[i + 1][1], 2.2, 'r')
        else:
            c.line(pts[i][0], pts[i][1], pts[i + 1][0], pts[i + 1][1], 'r')
    for (x, y) in pts:
        if c.big:
            c.rect(x - 1, y - 1, x + 1, y + 1, 'k')
        else:
            c.px(x, y, 'k')


@_icon2('ChartArea', 'The area graph tool: the room under a line filled.')
def _(c):
    b = c.layer()
    if c.big:
        b.shape([(3, 27), (3, 18), (10, 11), (17, 16), (24, 6), (30, 10), (30, 27)], 'G')
        b.shape([(3, 27), (3, 23), (10, 19), (17, 22), (24, 15), (30, 19), (30, 27)], 'l')
    else:
        b.shape([(2, 13), (2, 9), (5, 5), (8, 8), (12, 3), (15, 5), (15, 13)], 'G')
        b.shape([(2, 13), (2, 11), (5, 9), (8, 11), (12, 7), (15, 9), (15, 13)], 'l')
    c.over(b)
    _axes(c)


@_icon2('ChartScatter', 'The scatter graph tool: points by two numbers.')
def _(c):
    _axes(c)
    pts = [(7, 22, 'r'), (11, 15, 'b'), (16, 19, 'r'), (19, 10, 'b'), (24, 14, 'r'), (27, 6, 'b'), (13, 24, 'b')] \
        if c.big else [(4, 11, 'r'), (6, 7, 'b'), (9, 9, 'r'), (10, 4, 'b'), (13, 6, 'r'), (14, 2, 'b')]
    for (x, y, col) in pts:
        if c.big:
            c.disc(x, y, 2.6, col)
        else:
            c.px(x, y, col); c.px(x + 1, y, col); c.px(x, y + 1, col); c.px(x + 1, y + 1, col)


@_icon2('ChartRadar', 'The radar graph tool: numbers on spokes, joined.')
def _(c):
    cx = cy = c.n / 2
    r = 14 if c.big else 7
    ang = [math.radians(-90 + 72 * k) for k in range(5)]
    outer = [(cx + r * math.cos(a), cy + r * math.sin(a)) for a in ang]
    for (x, y) in outer:
        c.line(cx, cy, x, y, 'g')
    c.outline(outer, 'k')
    inner = [(cx + r * f * math.cos(a), cy + r * f * math.sin(a)) for a, f in zip(ang, (0.9, 0.5, 0.75, 0.45, 0.7))]
    b = c.layer()
    b.shape(inner, 'c', 'b')
    c.over(b)


# type: the ways of setting it
def _bigT(c, x, y, s, col='k'):
    """A T: its top bar at (x, y), `s` its size (16 for the type tool's)."""
    k = s / 16.0
    c.rect(x, y, int(x + 10 * k), int(y + 1.6 * k), col)
    c.rect(int(x + 4 * k), y, int(x + 6 * k), int(y + 11 * k), col)


@_icon2('TypeVertical', 'The vertical type tool: letters running down.')
def _(c):
    if c.big:
        _bigT(c, 3, 3, 26)
        arrow(c, 'd', 25, 30, 14, 'b')
    else:
        _bigT(c, 1, 1, 13)
        c.vline(13, 6, 14, 'b'); c.hline(11, 15, 12, 'b'); c.hline(12, 14, 13, 'b')


@_icon2('TypeArea', 'The area type tool: text that fills a shape.')
def _(c):
    if c.big:
        _dash_path(c, _rect_path(2, 2, 29, 29), 3, 2, 'k', None)
        _bigT(c, 8, 8, 18)
        for y in (24, 27):
            c.hline(6, 25, y, 'g')
    else:
        _dash_path(c, _rect_path(0, 0, 15, 15), 2, 1, 'k', None)
        _bigT(c, 4, 3, 10)


@_icon2('TypeAreaVertical', 'The vertical area type tool: letters running down, filling a shape.')
def _(c):
    if c.big:
        _dash_path(c, _rect_path(2, 2, 29, 29), 3, 2, 'k', None)
        _bigT(c, 6, 6, 16)
        arrow(c, 'd', 23, 27, 12, 'b')
    else:
        _dash_path(c, _rect_path(0, 0, 15, 15), 2, 1, 'k', None)
        _bigT(c, 2, 2, 9)
        c.vline(12, 5, 12, 'b'); c.hline(10, 14, 11, 'b'); c.px(12, 13, 'b')


@_icon2('TouchType', 'The touch type tool: each letter moved, sized and turned by itself.')
def _(c):
    if c.big:
        _bigT(c, 2, 4, 18)
        a = c.layer()
        # (a letter of its own, turned, in its box)
        pts = [(17, 12), (29, 17), (24, 29), (12, 24)]
        _dash_path(a, [(int(x), int(y)) for (x, y) in _poly_path(pts)], 2, 2, 'b', None)
        a.stroke(17, 24, 24, 15, 2.6, 'k'); a.stroke(19, 26.5, 26, 17.5, 2.6, 'k')
        c.over(a)
    else:
        _bigT(c, 1, 1, 10)
        c.line(8, 13, 13, 8, 'k'); c.line(9, 14, 14, 9, 'k')
        c.px(15, 10, 'b'); c.px(7, 12, 'b'); c.px(11, 15, 'b'); c.px(12, 6, 'b')


# shapes and frames
@_icon2('TriangleShape', 'The triangle tool: a triangle.')
def _(c):
    b = c.layer()
    if c.big:
        b.shape([(16, 3), (29, 27), (3, 27)], 'c')
        b.lit('c', 'w', 't')
    else:
        b.shape([(8, 1), (15, 14), (1, 14)], 'c')
    c.over(b)


@_icon2('FrameRect', 'The rectangle frame tool: a frame for a picture (a cross in it till it has one).')
def _(c):
    if c.big:
        c.rect(3, 5, 28, 26, 'w'); c.frame(3, 5, 28, 26, 'k')
        c.line(4, 6, 27, 25, 'b'); c.line(27, 6, 4, 25, 'b')
    else:
        c.rect(1, 2, 14, 13, 'w'); c.frame(1, 2, 14, 13, 'k')
        c.line(2, 3, 13, 12, 'b'); c.line(13, 3, 2, 12, 'b')


@_icon2('FrameEllipse', 'The ellipse frame tool: a round frame for a picture.')
def _(c):
    if c.big:
        c.disc(16, 16, 13, 'w')
        c.line(8, 8, 24, 24, 'b'); c.line(24, 8, 8, 24, 'b')
    else:
        c.disc(8, 8, 7, 'w')
        c.line(4, 4, 11, 11, 'b'); c.line(11, 4, 4, 11, 'b')


@_icon2('FramePolygon', 'The polygon frame tool: a frame of many sides for a picture.')
def _(c):
    cx = cy = c.n / 2
    r = 14 if c.big else 7
    pts = [(cx + r * math.cos(math.radians(-90 + 60 * k)), cy + r * math.sin(math.radians(-90 + 60 * k)))
           for k in range(6)]
    b = c.layer()
    b.shape(pts, 'w')
    c.over(b)
    if c.big:
        c.line(9, 9, 23, 23, 'b'); c.line(23, 9, 9, 23, 'b')
    else:
        c.line(4, 4, 11, 11, 'b'); c.line(11, 4, 4, 11, 'b')


@_icon2('Contour', 'The contour tool: outlines inside and outside a shape, as a map\'s heights.')
def _(c):
    cx = cy = c.n / 2
    for (r, col) in ((14, 'b'), (10, 'c'), (6, 'G')) if c.big else ((7, 'b'), (5, 'c'), (3, 'G')):
        c.ring(cx, cy - (1 if c.big else 0.5), r - (2 if c.big else 1), r, col)


@_icon2('PolarGrid', 'The polar grid tool: rings and spokes.')
def _(c):
    cx = cy = c.n / 2
    r = 14 if c.big else 7
    c.disc(cx, cy, r, 'w')
    c.ring(cx, cy, r * 0.55 - 0.5, r * 0.55 + 0.5, 'g')
    for k in range(6):
        a = math.radians(30 * k)
        c.line(cx - r * math.cos(a), cy - r * math.sin(a), cx + r * math.cos(a), cy + r * math.sin(a), 'k')
    c.ring(cx, cy, r - 1, r, 'k')


@_icon2('ArcShape', 'The arc tool: a part of a circle.')
def _(c):
    if c.big:
        c.arc(4, 28, 23, 3, -90, 0, 'k')
        c.rect(2, 3, 5, 6, 'w'); c.frame(2, 3, 5, 6, 'k'); c.rect(25, 26, 28, 29, 'w'); c.frame(25, 26, 28, 29, 'k')
    else:
        c.arc(2, 14, 11.5, 1.6, -90, 0, 'k')
        c.px(2, 2, 'b'); c.px(13, 13, 'b')


@_icon2('CornerTool', 'The corner tool: round a corner by dragging its widget.')
def _(c):
    if c.big:
        c.stroke(5, 28, 5, 14, 3, 'k'); c.stroke(14, 5, 28, 5, 3, 'k')
        c.arc(14, 14, 9, 3, 180, 270, 'k')
        c.disc(12, 12, 3, 'w', 'b')
    else:
        c.vline(2, 7, 14, 'k'); c.hline(7, 14, 2, 'k')
        c.arc(7, 7, 5, 1.4, 180, 270, 'k')
        c.px(6, 6, 'b'); c.px(5, 6, 'b'); c.px(6, 5, 'b')


@_icon2('Scallop', 'The scallop tool: curves into the outline, as a shell\'s.')
def _(c):
    cx = cy = c.n / 2
    r = 13 if c.big else 6.5
    b = c.layer()
    b.disc(cx, cy, r, 'y', None)
    for k in range(8):
        a = math.radians(45 * k)
        b.disc(cx + r * math.cos(a), cy + r * math.sin(a), r * 0.32, '.', None)
    b.outlined()
    c.over(b)


@_icon2('Crystallize', 'The crystallize tool: spikes out of the outline.')
def _(c):
    cx = cy = c.n / 2
    r0, r1 = (6, 15) if c.big else (3, 7.5)
    pts = []
    for k in range(18):
        a = math.radians(20 * k)
        r = r1 if k % 2 == 0 else r0
        r = r * (0.75 if k % 4 == 2 else 1)
        pts.append((cx + r * math.cos(a), cy + r * math.sin(a)))
    b = c.layer()
    b.shape(pts, 'c', 'b')
    c.over(b)


@_icon2('Twirl', 'The twirl tool: turn the outline round itself.')
def _(c):
    cx = cy = c.n / 2
    for k in range(240 if c.big else 120):
        t = k / (240 if c.big else 120)
        a = t * 4 * math.pi
        r = 1 + t * (13 if c.big else 6.5)
        x, y = cx + r * math.cos(a), cy + r * math.sin(a)
        if c.big:
            c.stroke(x, y, x, y, 2.2, 'P')
        else:
            c.px(int(x), int(y), 'P')


@_icon2('Bloat', 'The bloat tool: push the outline out.')
def _(c):
    cx = cy = c.n / 2
    b = c.layer()
    r = 13 if c.big else 6.5
    pts = [(cx + r * (1 + 0.15 * math.cos(4 * a)) * math.cos(a), cy + r * (1 + 0.15 * math.cos(4 * a)) * math.sin(a))
           for a in [math.radians(k * 5) for k in range(72)]]
    b.shape(pts, 'p')
    c.over(b)
    if c.big:
        for (dx, dy) in ((1, 0), (-1, 0), (0, 1), (0, -1)):
            arrow(c, {(1, 0): 'r', (-1, 0): 'l', (0, 1): 'd', (0, -1): 'u'}[(dx, dy)], int(cx + dx * 9), int(cy + dy * 9), 7, 'w')
    else:
        c.px(int(cx), int(cy), 'w')


@_icon2('Wrinkle', 'The wrinkle tool: waves along the outline.')
def _(c):
    for (k, col) in enumerate(('b', 'n', 'b')):
        y0 = (9 + 7 * k) if c.big else (4 + 4 * k)
        prev = None
        for x in range(2, c.n - 2):
            y = y0 + (2.5 if c.big else 1.2) * math.sin(x * (0.9 if c.big else 1.6) + k)
            if c.big:
                c.stroke(x, y, x, y, 2, col)
            else:
                c.px(x, int(round(y)), col)


@_icon2('Deform', 'The deform tool: bones in a shape, the shape bent as they turn.')
def _(c):
    b = c.layer()
    if c.big:
        b.shape([(5, 26), (8, 10), (15, 4), (24, 9), (27, 26), (21, 19), (11, 19)], 's')
        c.over(b)
        c.stroke(9, 22, 15, 10, 2, 'b'); c.stroke(15, 10, 23, 22, 2, 'b')
        for (x, y) in ((9, 22), (15, 10), (23, 22)):
            c.disc(x, y, 2.8, 'y')
    else:
        b.shape([(2, 13), (4, 5), (8, 2), (12, 5), (14, 13), (10, 10), (6, 10)], 's')
        c.over(b)
        c.line(4, 11, 8, 4, 'b'); c.line(8, 4, 12, 11, 'b')
        c.px(4, 11, 'y'); c.px(8, 4, 'y'); c.px(12, 11, 'y')


@_icon2('MeshTool', 'The mesh tool: a gradient mesh, its points each a color.')
def _(c):
    n = c.n
    c.rect(1, 1, n - 2, n - 2, 'c')
    c.dither(1, 1, n // 2, n // 2, 'b', 'c')
    for k in range(1, 4):
        t = k / 4.0
        prevx = prevy = None
        for s in range(0, 101, 4):
            u = s / 100.0
            x = 1 + u * (n - 3)
            y = 1 + t * (n - 3) + (2 if c.big else 1) * math.sin(u * math.pi)
            c.px(int(x), int(y), 'k')
            x2 = 1 + t * (n - 3) + (2 if c.big else 1) * math.sin(u * math.pi)
            y2 = 1 + u * (n - 3)
            c.px(int(x2), int(y2), 'k')
    c.frame(0, 0, n - 1, n - 1, 'k')
    m = n // 2
    c.rect(m - 1, m - 1, m + 1, m + 1, 'w') if c.big else c.px(m, m, 'w')


@_icon2('MeshWarp', 'The mesh warp tool: a grid over a shape, its points pulled.')
def _(c):
    n = c.n
    steps = 5 if c.big else 4
    for i in range(steps + 1):
        t = i / steps
        for s in range(0, 101, 2):
            u = s / 100.0
            bend = (3 if c.big else 1.5) * math.sin(u * math.pi) * math.sin(t * math.pi)
            x = 1 + u * (n - 3) + bend * 0.6
            y = 1 + t * (n - 3) + bend
            c.px(int(x), int(y), 'b')
            x2 = 1 + t * (n - 3) + bend
            y2 = 1 + u * (n - 3) + bend * 0.6
            c.px(int(x2), int(y2), 'b')


@_icon2('WidthTool', 'The width tool: a stroke made wider or thinner at a point.')
def _(c):
    if c.big:
        b = c.layer()
        pts = [(3, 16)]
        top = [(3 + k, 16 - (2 + 6 * math.sin(k / 26 * math.pi))) for k in range(0, 27)]
        bot = [(3 + k, 16 + (2 + 6 * math.sin(k / 26 * math.pi))) for k in range(26, -1, -1)]
        b.shape(top + bot, 'n')
        c.over(b)
        c.vline(16, 6, 26, 'w'); c.rect(15, 5, 17, 7, 'y'); c.rect(15, 25, 17, 27, 'y')
        c.frame(15, 5, 17, 7, 'k'); c.frame(15, 25, 17, 27, 'k')
    else:
        for x in range(1, 15):
            h = 1 + int(3 * math.sin((x - 1) / 13 * math.pi))
            c.vline(x, 8 - h, 8 + h, 'n')
        c.px(8, 3, 'y'); c.px(8, 13, 'y')


@_icon2('RotateTool', 'The rotate tool: turn a shape round a point.')
def _(c):
    if c.big:
        b = c.layer()
        b.shape([(9, 11), (21, 7), (25, 19), (13, 23)], 'c')
        c.over(b)
        c.disc(16, 16, 2.5, 'r')
        c.arc(16, 16, 13, 2.2, 200, 330, 'k')
        c.shape([(27, 6), (28, 13), (22, 10)], 'k')
    else:
        c.shape([(4, 6), (10, 4), (12, 10), (6, 12)], 'c')
        c.px(8, 8, 'r')
        c.arc(8, 8, 7, 1.2, 200, 330, 'k')
        c.px(14, 4, 'k'); c.px(13, 4, 'k'); c.px(14, 5, 'k')


@_icon2('ShearTool', 'The shear tool: slant a shape.')
def _(c):
    if c.big:
        c.frame(4, 8, 18, 26, 'g')
        b = c.layer()
        b.shape([(12, 8), (28, 8), (20, 26), (4, 26)], 'c')
        c.over(b)
        arrow(c, 'r', 30, 4, 12, 'b')
    else:
        c.frame(2, 4, 9, 13, 'g')
        c.shape([(6, 4), (14, 4), (10, 13), (2, 13)], 'c')
        c.hline(9, 14, 1, 'b'); c.px(13, 0, 'b'); c.px(13, 2, 'b')


@_icon2('ScaleTool', 'The scale tool: a shape made bigger or smaller round a point.')
def _(c):
    if c.big:
        c.frame(3, 13, 16, 28, 'g')
        c.rect(9, 3, 28, 22, 'c'); c.frame(9, 3, 28, 22, 'k')
        c.stroke(5, 27, 15, 17, 2, 'b')
        c.shape([(16, 15), (16, 21), (10, 15)], 'b')
    else:
        c.frame(1, 7, 8, 14, 'g')
        c.rect(5, 1, 14, 10, 'c'); c.frame(5, 1, 14, 10, 'k')
        c.line(2, 13, 7, 8, 'b')


@_icon2('FreeTransform', 'The free transform tool: move, size, turn and slant with the mouse.')
def _(c):
    if c.big:
        c.frame(5, 5, 26, 26, 'k')
        for (x, y) in ((5, 5), (15, 5), (26, 5), (5, 15), (26, 15), (5, 26), (15, 26), (26, 26)):
            c.rect(x - 2, y - 2, x + 2, y + 2, 'w'); c.frame(x - 2, y - 2, x + 2, y + 2, 'k')
        c.arc(16, 16, 6, 2, -150, 120, 'b')
    else:
        c.frame(2, 2, 13, 13, 'k')
        for (x, y) in ((2, 2), (13, 2), (2, 13), (13, 13), (7, 2), (7, 13), (2, 7), (13, 7)):
            c.px(x, y, 'w'); c.px(x, y, 'w')
        for (x, y) in ((2, 2), (13, 2), (2, 13), (13, 13)):
            c.rect(x - 1, y - 1, x + 1, y + 1, 'w'); c.frame(x - 1, y - 1, x + 1, y + 1, 'k')
        c.arc(8, 8, 3, 1.2, -150, 120, 'b')


@_icon2('PointTransform', 'The point transform tool: points of a path moved and turned as one.')
def _(c):
    if c.big:
        pts = [(5, 25), (11, 8), (21, 6), (27, 22)]
        for i in range(3):
            c.line(pts[i][0], pts[i][1], pts[i + 1][0], pts[i + 1][1], 'k')
        for (x, y) in pts:
            c.rect(x - 2, y - 2, x + 2, y + 2, 'b'); c.frame(x - 2, y - 2, x + 2, y + 2, 'k')
        c.frame(8, 4, 24, 12, 'g')
    else:
        pts = [(2, 13), (5, 4), (11, 3), (14, 11)]
        for i in range(3):
            c.line(pts[i][0], pts[i][1], pts[i + 1][0], pts[i + 1][1], 'k')
        for (x, y) in pts:
            c.px(x, y, 'b')
        c.frame(4, 2, 12, 6, 'g')


@_icon2('AreaTool', 'The area tool: the area and the outline\'s length of a shape.')
def _(c):
    if c.big:
        c.rect(5, 5, 26, 26, 'y'); c.frame(5, 5, 26, 26, 'k')
        c.dither(6, 6, 25, 25, 'y', 'o')
        c.rect(11, 12, 20, 20, 'w'); c.frame(11, 12, 20, 20, 'k')
        c.rect(13, 14, 14, 18, 'k'); c.rect(17, 14, 18, 18, 'k'); c.hline(13, 18, 14, 'k'); c.hline(13, 18, 16, 'k')
    else:
        c.rect(2, 2, 13, 13, 'y'); c.frame(2, 2, 13, 13, 'k')
        c.dither(3, 3, 12, 12, 'y', 'o')
        c.vline(5, 5, 10, 'k'); c.vline(10, 5, 10, 'k'); c.hline(5, 10, 5, 'k'); c.hline(5, 10, 7, 'k')


@_icon2('DimensionTool', 'The dimension tool: a measure drawn on the page, its number on it.')
def _(c):
    if c.big:
        c.vline(3, 8, 26, 'k'); c.vline(28, 8, 26, 'k')
        c.hline(4, 27, 17, 'b')
        c.shape([(4, 17), (9, 13), (9, 21)], 'b'); c.shape([(27, 17), (22, 13), (22, 21)], 'b')
        c.rect(11, 6, 20, 12, 'w'); c.frame(11, 6, 20, 12, 'k')
        c.hline(13, 18, 9, 'g')
    else:
        c.vline(1, 4, 13, 'k'); c.vline(14, 4, 13, 'k')
        c.hline(2, 13, 9, 'b'); c.px(3, 8, 'b'); c.px(3, 10, 'b'); c.px(12, 8, 'b'); c.px(12, 10, 'b')
        c.hline(5, 10, 5, 'k')


@_icon2('Shaper', 'The shaper tool: a rough drawing made a clean shape.')
def _(c):
    _base(c, 'Pencil')
    a = c.layer()
    if c.big:
        a.shape([(17, 31), (24, 18), (31, 31)], 'w')
        a.disc(27, 20, 4, 'w')
    else:
        a.shape([(9, 15), (12, 9), (15, 15)], 'w')
    c.over(a)


@_icon2('GradientFeather', 'The gradient feather tool: a shape fading out to see-through.')
def _(c):
    # a solid middle, its rim dithered thinner and thinner (an ordered dither: no noise)
    bayer = ((0, 8, 2, 10), (12, 4, 14, 6), (3, 11, 1, 9), (15, 7, 13, 5))
    cx, cy, r0, r1 = (15.5, 15.5, 6.0, 14.0) if c.big else (7.5, 7.5, 2.5, 7.0)
    for y in range(c.n):
        for x in range(c.n):
            d = ((x + 0.5 - cx - 0.5) ** 2 + (y + 0.5 - cy - 0.5) ** 2) ** 0.5
            if d <= r0:
                c.px(x, y, 'b')
            elif d < r1 and (bayer[y % 4][x % 4] + 0.5) / 16 > (d - r0) / (r1 - r0):
                c.px(x, y, 'b')


@_icon2('BlendTool', 'The blend tool: shapes and the steps between them.')
def _(c):
    if c.big:
        cols = 'rmPnb'
        for k in range(5):
            r = 4.5 - k * 0.3
            c.disc(6 + k * 5, 24 - k * 4, r, cols[k])
    else:
        cols = 'rPb'
        for k in range(3):
            c.disc(3.5 + k * 4.5, 12 - k * 3.5, 2.5, cols[k], None)


@_icon2('ArtboardTool', 'The artboard tool: a page of its own on the canvas, its size and place.')
def _(c):
    if c.big:
        c.rect(5, 9, 28, 28, 'w'); c.frame(5, 9, 28, 28, 'k')
        c.rect(5, 3, 18, 7, 'n'); c.hline(6, 15, 5, 'w')
        c.rect(27, 27, 30, 30, 'b')
    else:
        c.rect(2, 5, 14, 14, 'w'); c.frame(2, 5, 14, 14, 'k')
        c.hline(2, 9, 2, 'n'); c.hline(2, 9, 3, 'n')
        c.px(14, 14, 'b'); c.px(15, 15, 'b')


@_icon2('KnifeTool', 'The knife: cut shapes along a line drawn freehand.')
def _(c):
    a = c.layer()
    if c.big:
        for k in range(0, 28, 3):
            y = 26 - 6 * math.sin(k / 27 * math.pi)
            a.rect(2 + k, int(y), 3 + k, int(y) + 1, 'r')
        a.shape([(6, 18), (22, 3), (25, 6), (10, 21)], 's')
        a.line(8, 18, 22, 4, 'w')
        a.stroke(24, 5, 29, 1, 4, 'k')
    else:
        for k in range(0, 14, 2):
            a.px(1 + k, int(13 - 3 * math.sin(k / 13 * math.pi)), 'r')
        a.shape([(3, 9), (11, 1), (12, 3), (5, 10)], 's')
        a.line(12, 2, 14, 0, 'k'); a.line(13, 2, 15, 0, 'k')
    c.over(a)


def build():
    # the icons above, in the order of their characters (keep it: the
    # characters are part of the API); new ones go after the old ones
    for n, d, s, b in ICONS:
        assert len(s) == 16 and all(len(r) == 16 for r in s), n
        assert len(b) == 32 and all(len(r) == 32 for r in b), n
        for r in s + b:
            for ch in r:
                assert ch == '.' or ch in PAL, (n, ch)


ORDER = ["Folder", "FolderOpen", "Documents", "Downloads", "Pictures", "Music", "Videos",
         "FolderStar", "FolderPlus", "FolderUp", "Home", "Desktop", "Computer", "Drive", "SdCard",
         "Phone", "Trash", "TrashFull", "File", "Text", "Markdown", "Code", "Web", "Data", "Sheet",
         "Document", "Slides", "Pdf", "Image", "Audio", "Video", "Archive", "App", "Script", "Font",
         "Info", "Question", "Error", "Warning", "New", "Open", "Save", "Cut", "Copy", "Paste",
         "Print", "Help", "Back", "Forward", "Up", "Refresh", "Delete", "Rename", "Properties",
         "Search", "Details", "Icons", "Star", "Share", "Select", "Undo", "Redo", "Settings",
         "Tiles", "Tree", "Preview", "TwoPanes", "Columns", "Eye", "OpenWith", "Bell", "Check", "Lock",
         "Play", "User", "Inbox", "Fit", "Hourglass", "Hourglass2"]


def ordered():
    by = {n: (n, d, s, b) for n, d, s, b in ICONS}
    out = [by[n] for n in ORDER]
    out += [i for i in ICONS if i[0] not in ORDER]
    return out


def write_nim(path):
    """The icons' constants, their count and their names in pixelicons.nim (the rest of
    it is kept as it is), and their art in pixelart.z beside it."""
    icons = ordered()
    nim = open(path).read()
    consts = ''.join('  px%s* = "\\u{%X}"  ## %s\n' % (n, 0x10F000 + i, d)
                     for i, (n, d, s, b) in enumerate(icons))
    nim = re.sub(r'(?ms)^const\n(  px\w+\* = .*?\n)+', lambda m: 'const\n' + consts, nim, count=1)
    nim = re.sub(r'const pixelIconCount = \d+\n  ## \(.*?\)',
                 lambda m: 'const pixelIconCount = %d\n  ## (how many icons there are: U+10F000 .. U+%X)'
                 % (len(icons), 0x10F000 + len(icons) - 1), nim, count=1)
    nim = re.sub(r'const pixelIconNames\* = \[.*?\]',
                 lambda m: 'const pixelIconNames* = [' + ', '.join('"%s"' % n for n, *_ in icons) + ']',
                 nim, count=1)
    open(path, 'w').write(nim)
    # the art, one byte a pixel (the palette letters of `icon`), zlib-packed
    # in pixelart.z: a few dozen KB instead of half a megabyte of pixels
    import zlib
    blob = bytearray()
    for (n, d, s, b) in icons:
        for art in (s, b):
            blob += bytes([len(art[0]) if art else 0, len(art)])
            for row in art:
                blob += row.encode('ascii')
    open(os.path.join(os.path.dirname(path), 'pixelart.z'), 'wb').write(zlib.compress(bytes(blob), 9))


def sheet(path, scales=(1, 2, 3)):
    """A contact sheet: every icon at 16 and 32, at each scale, on white,
    the 3.1 face gray and the navy selection."""
    from PIL import Image, ImageDraw
    icons = ordered()
    bgs = [(255, 255, 255), (192, 192, 192), (0, 0, 128)]
    cols = 8
    rows = (len(icons) + cols - 1) // cols
    cellw = sum((16 + 32) * s + 12 for s in scales) + 8
    cellh = max(32 * max(scales), 16) + 22
    img = Image.new('RGB', (cols * cellw, rows * cellh * len(bgs)), (192, 192, 192))
    d = ImageDraw.Draw(img)
    for bi, bg in enumerate(bgs):
        for k, (name, _, s, b) in enumerate(icons):
            ox = (k % cols) * cellw
            oy = (bi * rows + k // cols) * cellh
            d.rectangle([ox, oy, ox + cellw - 2, oy + cellh - 2], fill=bg)
            d.text((ox + 3, oy + cellh - 13), name, fill=(0, 0, 0) if bi < 2 else (255, 255, 255))
            x = ox + 4
            for sc in scales:
                for art in (s, b):
                    for yy, row in enumerate(art):
                        for xx, ch in enumerate(row):
                            if ch in PAL:
                                d.rectangle([x + xx * sc, oy + 3 + yy * sc,
                                             x + xx * sc + sc - 1, oy + 3 + yy * sc + sc - 1],
                                            fill=PAL[ch])
                    x += len(art[0]) * sc + 6
    img.save(path)


# ---- the example apps' launcher icons and the default app icon ------------------------------------

def app_window(c, title='n'):
    """A program's window, the frame of every launcher icon."""
    c.bevel(1, 1, 30, 30, 's')
    c.rect(2, 2, 29, 6, title)
    c.hline(2, 29, 7, 'k')
    c.bevel(3, 3, 6, 5, 's', sh=None)
    c.rect(2, 8, 29, 29, 'w')


def files_icon():
    c = C(32)
    app_window(c)
    # the folder tree at the left, an open folder at the right
    for y in (10, 15, 20, 25):
        x = 3 if y == 10 else 6
        c.rect(x, y, x + 4, y + 2, 'y'); c.frame(x, y, x + 4, y + 2, 'k')
    for y in range(13, 27, 2):
        c.px(4, y, 'g')
    for y in (16, 21, 26):
        c.px(5, y, 'g')
    c.vline(12, 8, 29, 's')
    s = C(16); folder_open(s)
    c.paste(s.rows(), 14, 11)
    return c


def gallery_icon():
    c = C(32)
    app_window(c)
    # the controls: a check box, a radio button, a slider and a button
    c.rect(4, 10, 9, 15, 'w'); c.frame(4, 10, 9, 15, 'k')
    c.line(5, 11, 8, 14, 'k'); c.line(8, 11, 5, 14, 'k')
    c.hline(11, 17, 12, 'n'); c.hline(11, 15, 14, 'g')
    c.ring(23, 13, 2.2, 3.4, 'k'); c.rect(22, 12, 23, 13, 'k')
    c.hline(4, 27, 19, 'g'); c.hline(4, 27, 20, 'w')
    c.bevel(14, 17, 17, 22, 's')
    c.bevel(5, 24, 26, 28, 's')
    c.hline(11, 20, 26, 'k')
    return c


def default_icon48():
    """The icon of an app that brings none: a 3.1 window on the desktop
    teal, at 48 x 48."""
    c = C(48)
    c.rect(1, 1, 46, 46, 't')
    c.bevel(5, 6, 42, 41, 's')
    c.rect(6, 7, 41, 12, 'n')
    c.bevel(7, 8, 11, 11, 's', sh=None)
    c.rect(30, 7, 35, 12, 's'); c.vline(29, 7, 12, 'k'); c.hline(32, 34, 9, 'k'); c.px(33, 10, 'k')
    c.rect(36, 7, 41, 12, 's'); c.vline(35, 7, 12, 'k'); c.px(38, 9, 'k'); c.hline(37, 39, 10, 'k')
    c.hline(16, 27, 9, 'w'); c.hline(16, 27, 10, 'w')
    c.hline(6, 41, 13, 'k')
    c.rect(6, 14, 41, 17, 'w'); c.hline(8, 11, 15, 'k'); c.hline(14, 18, 15, 'k'); c.hline(21, 24, 15, 'k')
    c.hline(6, 41, 18, 'k')
    c.rect(6, 19, 41, 40, 'w')
    c.rect(9, 23, 19, 33, 'w'); c.frame(9, 23, 19, 33, 'k')
    c.line(11, 25, 17, 31, 'k'); c.line(17, 25, 11, 31, 'k')
    c.bevel(23, 30, 38, 36, 's'); c.hline(27, 34, 33, 'k')
    c.hline(23, 38, 24, 'n'); c.hline(23, 33, 26, 'g')
    return c


def to_png(c, path, scale):
    from PIL import Image
    img = Image.new('RGBA', (c.n * scale, c.n * scale), (0, 0, 0, 0))
    for y, row in enumerate(c.rows()):
        for x, ch in enumerate(row):
            if ch in PAL:
                for yy in range(scale):
                    for xx in range(scale):
                        img.putpixel((x * scale + xx, y * scale + yy), PAL[ch] + (255,))
    img.save(path)


def write_appicon(path):
    """Writes the default app icon's pixels into src/retroui/appicon.nim."""
    src = open(path).read()
    start = src.index('proc iconPixels*()')
    end = src.index('proc iconPng*')
    art = default_icon48().rows()
    body = ['proc iconPixels*(): array[48 * 48, uint32] =',
            '  ## The icon at its own size, 48 x 48: a 3.1 window on the desktop teal.',
            '  ## (Drawn by tools/genicons.py.)',
            '  const art = [']
    body += ['    "%s",' % r for r in art]
    body += ['  ]',
             '  for y in 0 ..< 48:',
             '    for x in 0 ..< 48:',
             '      result[y * 48 + x] = case art[y][x]',
             '        of \'k\': 0xFF000000\'u32',
             '        of \'w\': 0xFFFFFFFF\'u32',
             '        of \'s\': 0xFFC0C0C0\'u32',
             '        of \'g\': 0xFF808080\'u32',
             '        of \'n\': 0xFF000080\'u32',
             '        of \'t\': 0xFF008080\'u32',
             '        of \'y\': 0xFFFFFF00\'u32',
             '        of \'r\': 0xFFFF0000\'u32',
             '        of \'G\': 0xFF008000\'u32',
             '        of \'l\': 0xFF00FF00\'u32',
             '        of \'b\': 0xFF0000FF\'u32',
             '        of \'c\': 0xFF00FFFF\'u32',
             '        of \'m\': 0xFF800000\'u32',
             '        of \'o\': 0xFF808000\'u32',
             '        of \'p\': 0xFFFF00FF\'u32',
             '        of \'P\': 0xFF800080\'u32',
             '        else: 0\'u32',
             '', '']
    for r in art:
        for ch in r:
            assert ch == '.' or ch in PAL
    open(path, 'w').write(src[:start] + '\n'.join(body) + src[end:])


if __name__ == '__main__':
    build()
    here = os.path.dirname(os.path.abspath(__file__))
    write_nim(os.path.join(here, '..', 'src', 'retroui', 'pixelicons.nim'))
    args = sys.argv[1:]
    if '--appicons' in args:
        assets = os.path.join(here, '..', 'examples', 'assets')
        to_png(files_icon(), os.path.join(assets, 'filemanager-icon.png'), 6)
        to_png(gallery_icon(), os.path.join(assets, 'gallery-icon.png'), 6)
        write_appicon(os.path.join(here, '..', 'src', 'retroui', 'appicon.nim'))
        args.remove('--appicons')
    if args:
        sheet(args[0])
    print(len(ICONS), 'icons')
