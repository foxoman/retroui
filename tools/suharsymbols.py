#!/usr/bin/env python3
"""The symbols the kit writes or names that Suhar App has not drawn, drawn
into a face of it (tools/gensuharfont.py calls `add_symbols` for each of the
eight): each in the face's own weight -- its stems measured from its "l" and
its "minus" -- and slant (its italic angle), from its own letters where a
symbol is one of them turned or moved:

  ∀ its A turned round      ∃ its E mirrored      ∆ its Δ      ∇ its Δ upside down
  ∏ its Π      ∅ its Ø      ⌀ its ø      ∗ its * on the axis of + and −
  ∂ its 6 mirrored          ∈ its є on the axis   ∋ its є mirrored
  ∉ its є on the axis with a stroke through it

and drawn in its strokes where none of its letters is the symbol:

  ∝ proportional to         ⟨ ⟩ angle brackets      ⁁ caret insertion point
  ▁ lower one eighth block  ☎ telephone             ♀ ♂ female, male
  ♭ ♮ ♯ flat, natural, sharp

Glyphs Suhar draws itself are never replaced. Needs fontTools.

    python3 tools/suharsymbols.py FONT.ttf OUT.ttf      (one face, to look at)
"""
import math, sys
from fontTools.ttLib import TTFont
from fontTools.pens.ttGlyphPen import TTGlyphPen
from fontTools.pens.recordingPen import DecomposingRecordingPen


# ---- outlines: a source glyph's, its points mapped ---------------------------------------------

def record(gs, name):
    """The glyph's outline as moves, lines and quadratic curves, every contour with a start point
    (a contour of off-curve points only -- an O's -- given one: the middle of its last two)."""
    p = DecomposingRecordingPen(gs)
    gs[name].draw(p)
    out = []
    for op, args in p.value:
        if op == 'qCurveTo' and args[-1] is None:
            offs = list(args[:-1])
            a, b = offs[-1], offs[0]
            start = ((a[0] + b[0]) / 2, (a[1] + b[1]) / 2)
            out.append(('moveTo', (start,)))
            out.append(('qCurveTo', tuple(offs) + (start,)))
        else:
            out.append((op, args))
    return out


def replay(ops, pen, fn):
    """The recorded outline `ops` drawn into `pen`, each point through `fn`; a map that mirrors
    reverses each contour, so its outer contours stay clockwise."""
    for op, args in ops:
        pts = [fn(x, y) for x, y in args]
        getattr(pen, op)(*pts)


def mirrored(ops):
    """`ops` with each contour drawn the other way round (for a mirroring map)."""
    out = []
    contour = []
    def flush():
        if not contour:
            return
        start = contour[0][1][0]
        segs = contour[1:]
        # (points of the contour in order, each segment's points ending on its on-curve point)
        pts = [start]
        kinds = []
        for op, args in segs:
            if op in ('lineTo', 'qCurveTo', 'curveTo'):
                kinds.append((op, len(args)))
                pts.extend(args)
        # reversed: walk the points back
        rev = list(reversed(pts))
        out.append(('moveTo', (rev[0],)))
        i = 1
        for op, n in reversed(kinds):
            out.append((op, tuple(rev[i:i + n])))
            i += n
        out.append(('closePath', ()))
    for op, args in ops:
        if op == 'moveTo':
            flush()
            contour[:] = [(op, args)]
        elif op in ('closePath', 'endPath'):
            flush()
            contour[:] = []
        else:
            contour.append((op, args))
    flush()
    return out


def flatten(ops, steps=8):
    """`ops` as polygons (lists of points), curves cut in `steps` straight pieces."""
    polys = []
    cur = []
    last = None
    for op, args in ops:
        if op == 'moveTo':
            if cur:
                polys.append(cur)
            cur = [args[0]]
            last = args[0]
        elif op == 'lineTo':
            cur.append(args[0])
            last = args[0]
        elif op == 'qCurveTo':
            offs = list(args[:-1])
            on = args[-1]
            # implied on-curve points between off-curve ones
            p0 = last
            for k, c in enumerate(offs):
                p2 = on if k == len(offs) - 1 else ((c[0] + offs[k + 1][0]) / 2, (c[1] + offs[k + 1][1]) / 2)
                for s in range(1, steps + 1):
                    t = s / steps
                    x = (1 - t) ** 2 * p0[0] + 2 * (1 - t) * t * c[0] + t * t * p2[0]
                    y = (1 - t) ** 2 * p0[1] + 2 * (1 - t) * t * c[1] + t * t * p2[1]
                    cur.append((x, y))
                p0 = p2
            last = on
        elif op == 'curveTo':
            c1, c2, p3 = args
            p0 = last
            for s in range(1, steps + 1):
                t = s / steps
                x = (1 - t) ** 3 * p0[0] + 3 * (1 - t) ** 2 * t * c1[0] + 3 * (1 - t) * t * t * c2[0] + t ** 3 * p3[0]
                y = (1 - t) ** 3 * p0[1] + 3 * (1 - t) ** 2 * t * c1[1] + 3 * (1 - t) * t * t * c2[1] + t ** 3 * p3[1]
                cur.append((x, y))
            last = p3
        elif op in ('closePath', 'endPath'):
            if cur:
                polys.append(cur)
            cur = []
    if cur:
        polys.append(cur)
    return polys


def bounds(ops):
    pts = [p for poly in flatten(ops) for p in poly]
    xs = [p[0] for p in pts]
    ys = [p[1] for p in pts]
    return min(xs), min(ys), max(xs), max(ys)


def crossings(ops, y):
    """Where the outline crosses the line at height `y`: its x's, left to right."""
    xs = []
    for poly in flatten(ops, 16):
        for i in range(len(poly)):
            (x0, y0), (x1, y1) = poly[i], poly[(i + 1) % len(poly)]
            if (y0 <= y < y1) or (y1 <= y < y0):
                xs.append(x0 + (y - y0) * (x1 - x0) / (y1 - y0))
    return sorted(xs)


# ---- shapes drawn: polygons, rings, strokes ---------------------------------------------------------

def area(poly):
    return sum(poly[i][0] * poly[(i + 1) % len(poly)][1] - poly[(i + 1) % len(poly)][0] * poly[i][1]
               for i in range(len(poly))) / 2


def oriented(poly, outer=True):
    """`poly` clockwise (y up) for an outer contour, counter-clockwise for a hole."""
    a = area(poly)
    if (a > 0) == outer:
        return list(reversed(poly))
    return poly


def stroke(points, w, miter=2.5):
    """The outline of a line through `points`, `w` thick, its ends cut square, its corners mitred."""
    n = len(points)
    left, right = [], []
    for i in range(n):
        p = points[i]
        if i == 0:
            dx, dy = points[1][0] - p[0], points[1][1] - p[1]
            d = math.hypot(dx, dy)
            nx, ny = -dy / d, dx / d
            k = 1.0
        elif i == n - 1:
            dx, dy = p[0] - points[i - 1][0], p[1] - points[i - 1][1]
            d = math.hypot(dx, dy)
            nx, ny = -dy / d, dx / d
            k = 1.0
        else:
            ax, ay = p[0] - points[i - 1][0], p[1] - points[i - 1][1]
            bx, by = points[i + 1][0] - p[0], points[i + 1][1] - p[1]
            da, db = math.hypot(ax, ay), math.hypot(bx, by)
            n1 = (-ay / da, ax / da)
            n2 = (-by / db, bx / db)
            mx, my = n1[0] + n2[0], n1[1] + n2[1]
            dm = math.hypot(mx, my) or 1.0
            nx, ny = mx / dm, my / dm
            cos = nx * n1[0] + ny * n1[1]
            k = min(miter, 1.0 / max(cos, 1e-3))
        left.append((p[0] + nx * w / 2 * k, p[1] + ny * w / 2 * k))
        right.append((p[0] - nx * w / 2 * k, p[1] - ny * w / 2 * k))
    return left + list(reversed(right))


def hermite(pts, tangents, steps=14):
    """A smooth line through `pts`, leaving each in the direction of its tangent (cubic Hermite)."""
    out = [pts[0]]
    for i in range(len(pts) - 1):
        p0, p1 = pts[i], pts[i + 1]
        d = math.hypot(p1[0] - p0[0], p1[1] - p0[1])
        m0 = (tangents[i][0] * d, tangents[i][1] * d)
        m1 = (tangents[i + 1][0] * d, tangents[i + 1][1] * d)
        for s in range(1, steps + 1):
            t = s / steps
            h00 = 2 * t ** 3 - 3 * t * t + 1
            h10 = t ** 3 - 2 * t * t + t
            h01 = -2 * t ** 3 + 3 * t * t
            h11 = t ** 3 - t * t
            out.append((h00 * p0[0] + h10 * m0[0] + h01 * p1[0] + h11 * m1[0],
                        h00 * p0[1] + h10 * m0[1] + h01 * p1[1] + h11 * m1[1]))
    return out


def unit(dx, dy):
    d = math.hypot(dx, dy)
    return (dx / d, dy / d)


def ellipse(cx, cy, rx, ry, n=48):
    return [(cx + rx * math.cos(2 * math.pi * k / n), cy + ry * math.sin(2 * math.pi * k / n)) for k in range(n)]


def rect(x0, y0, x1, y1):
    return [(x0, y0), (x0, y1), (x1, y1), (x1, y0)]


# ---- a face's measures ------------------------------------------------------------------------------

class Face:
    def __init__(self, f):
        self.f = f
        self.gs = f.getGlyphSet()
        self.cm = f.getBestCmap()
        self.slant = math.tan(math.radians(-f['post'].italicAngle))
        os2 = f['OS/2']
        self.capH = os2.sCapHeight or 700
        self.xH = os2.sxHeight or 500
        self.asc = f['hhea'].ascent
        self.desc = f['hhea'].descent
        # (a stem: "l" across, half way up the x-height -- upright)
        l = self.upright(record(self.gs, self.cm[ord('l')]))
        xs = crossings(l, self.xH / 2)
        self.stem = (xs[1] - xs[0]) if len(xs) >= 2 else 80
        # (a bar: the minus's height; the axis: its middle)
        mb = bounds(record(self.gs, self.cm[0x2212]))
        self.bar = mb[3] - mb[1]
        self.axis = (mb[1] + mb[3]) / 2
        pb = bounds(record(self.gs, self.cm[ord('(')]))
        self.parenLo, self.parenHi = pb[1], pb[3]
        self.digitW = f['hmtx'][self.cm[ord('0')]][0]

    def upright(self, ops):
        s = self.slant
        return [(op, tuple((x - s * y, y) for x, y in args)) for op, args in ops]

    def adv(self, ch):
        return self.f['hmtx'][self.cm[ord(ch)]][0]

    def src(self, ch):
        """(the upright outline of the face's own `ch`, its advance)"""
        return self.upright(record(self.gs, self.cm[ord(ch)])), self.adv(ch)


def build(face, ops):
    """A glyph from upright outline `ops`, slanted as the face is."""
    s = face.slant
    pen = TTGlyphPen(None)
    replay(ops, pen, lambda x, y: (round(x + s * y), round(y)))
    return pen.glyph()


def polys_ops(polys_outer, polys_holes=()):
    ops = []
    for p in polys_outer:
        p = oriented(p, True)
        ops.append(('moveTo', (p[0],)))
        for q in p[1:]:
            ops.append(('lineTo', (q,)))
        ops.append(('closePath', ()))
    for p in polys_holes:
        p = oriented(p, False)
        ops.append(('moveTo', (p[0],)))
        for q in p[1:]:
            ops.append(('lineTo', (q,)))
        ops.append(('closePath', ()))
    return ops


def mapped(ops, fn, mirror):
    out = [(op, tuple(fn(x, y) for x, y in args)) for op, args in ops]
    return mirrored(out) if mirror else out


# ---- the symbols --------------------------------------------------------------------------------------

def derived(face):
    """(code point: (upright outline, advance)) of the symbols made from the face's own letters"""
    out = {}
    A, aw = face.src('A')
    ax0, ay0, ax1, ay1 = bounds(A)
    out[0x2200] = (mapped(A, lambda x, y: (aw - x, ay0 + ay1 - y), False), aw)          # ∀
    E, ew = face.src('E')
    out[0x2203] = (mapped(E, lambda x, y: (ew - x, y), True), ew)                      # ∃
    D, dw = face.src('Δ')
    dy0, dy1 = bounds(D)[1], bounds(D)[3]
    out[0x2206] = (D, dw)                                                              # ∆
    out[0x2207] = (mapped(D, lambda x, y: (x, dy0 + dy1 - y), True), dw)               # ∇
    out[0x220F] = face.src('Π')                                                        # ∏
    out[0x2205] = face.src('Ø')                                                        # ∅
    out[0x2300] = face.src('ø')                                                        # ⌀
    st, sw = face.src('*')
    sy0, sy1 = bounds(st)[1], bounds(st)[3]
    dy = face.axis - (sy0 + sy1) / 2
    out[0x2217] = (mapped(st, lambda x, y: (x, y + dy), False), sw)                    # ∗
    six, w6 = face.src('6')
    out[0x2202] = (mapped(six, lambda x, y: (w6 - x, y), True), w6)                    # ∂
    ie, iw = face.src('є')
    iy0, iy1 = bounds(ie)[1], bounds(ie)[3]
    ey = face.axis - (iy0 + iy1) / 2
    el = mapped(ie, lambda x, y: (x, y + ey), False)
    out[0x2208] = (el, iw)                                                             # ∈
    out[0x220B] = (mapped(ie, lambda x, y: (iw - x, y + ey), True), iw)                # ∋
    ix0, _, ix1, _ = bounds(el)
    h = (iy1 - iy0) * 0.62
    cx = (ix0 + ix1) / 2
    slash = stroke([(cx - (ix1 - ix0) * 0.36, face.axis - h), (cx + (ix1 - ix0) * 0.36, face.axis + h)],
                   face.bar * 1.05)
    out[0x2209] = (el + polys_ops([slash]), iw)                                        # ∉
    return out


def drawn(face):
    """(code point: (upright outline, advance)) of the symbols drawn in the face's strokes"""
    out = {}
    t = face.stem * 0.86          # (a symbol's stroke: a little lighter than a letter's stem)
    b = face.bar
    ax = face.axis
    # ∝ proportional to: a loop at the left, its two ends open to the right
    W = 620
    h = face.xH * 0.56
    xc = 0.56 * W
    pts = [(W - 50, ax + h / 2), (xc, ax), (0.30 * W, ax - h / 2), (60, ax), (0.30 * W, ax + h / 2),
           (xc, ax), (W - 50, ax - h / 2)]
    tans = [(-1, 0), unit(-1, -1.15), (-1, 0), (0, 1), (1, 0), unit(1, -1.15), (1, 0)]
    out[0x221D] = (polys_ops([stroke(hermite(pts, tans), b * 1.15)]), W)
    # ⟨ ⟩ angle brackets: as tall as the parentheses, thin
    lo, hi = face.parenLo, face.parenHi
    cw = (hi - lo) * 0.27
    tb = t * 0.78
    L = stroke([(70 + cw, hi - tb / 2), (70, (lo + hi) / 2), (70 + cw, lo + tb / 2)], tb)
    R = stroke([(70, hi - tb / 2), (70 + cw, (lo + hi) / 2), (70, lo + tb / 2)], tb)
    out[0x27E8] = (polys_ops([L]), int(cw + 140))
    out[0x27E9] = (polys_ops([R]), int(cw + 140))
    # ⁁ caret insertion point: a long stroke up from under the baseline, a short leg off it
    d = face.desc * 0.55
    top = face.xH * 0.53
    p0, p1 = (45, d), (290, top)
    mid = (p0[0] + (p1[0] - p0[0]) * 0.44, p0[1] + (p1[1] - p0[1]) * 0.44)
    out[0x2041] = (polys_ops([stroke([p0, p1], t), stroke([mid, (390, d)], t)]), 440)
    # ▁ lower one eighth block: the line's foot, an eighth of it
    out[0x2581] = (polys_ops([rect(0, face.desc, face.digitW, face.desc + (face.asc - face.desc) / 8)]),
                   face.digitW)
    # ☎ telephone: its body with the dial, its handset over it
    body = [(70, 0), (180, 300), (620, 300), (730, 0)]
    body = [(90, 0), (70, 30), (175, 290), (205, 310), (595, 310), (625, 290), (730, 30), (710, 0)]
    dial_out = ellipse(400, 150, 100, 100)
    dial_in = ellipse(400, 150, 42, 42)
    arch = hermite([(110, 400), (400, 600), (690, 400)], [unit(0.35, 1), (1, 0), unit(0.35, -1)])
    ear_l = ellipse(125, 395, 95, 52)
    ear_r = ellipse(675, 395, 95, 52)
    out[0x260E] = (polys_ops([body, dial_in, stroke(arch, t * 1.25), ear_l, ear_r], [dial_out]), 800)
    # ♀ ♂ female, male: a ring and a cross under it, a ring and an arrow off it
    R = 190
    cx, cy = 270, 430
    ring_o = ellipse(cx, cy, R + t / 2, R + t / 2, 64)
    ring_i = ellipse(cx, cy, R - t / 2, R - t / 2, 64)
    cross_v = rect(cx - t / 2, -200, cx + t / 2, cy - R)
    cross_h = rect(cx - 140, -55 - t / 2, cx + 140, -55 + t / 2)
    out[0x2640] = (polys_ops([ring_o, cross_v, cross_h], [ring_i]), 540)
    cx, cy = 280, 260
    ring_o = ellipse(cx, cy, R + t / 2, R + t / 2, 64)
    ring_i = ellipse(cx, cy, R - t / 2, R - t / 2, 64)
    k = math.cos(math.radians(45))
    tip = (650, 630)
    shaft = stroke([(cx + R * k, cy + R * k), (tip[0] - t * 0.35, tip[1] - t * 0.35)], t)
    head = stroke([(tip[0] - 210, tip[1] - t / 2), (tip[0] - t / 2, tip[1] - t / 2),
                   (tip[0] - t / 2, tip[1] - 210)], t)
    out[0x2642] = (polys_ops([ring_o, shaft, head], [ring_i]), 720)
    # ♭ flat: a stem and its bowl
    sx = 90
    sr = sx + t * 0.5                 # (the bowl's edge: inside the stem, so they are one)
    stemr = rect(sx, -20, sx + t, 760)
    # (its bowl: thick at the right, coming to a point at the stem's foot; its counter in it)
    outer = hermite([(sr, 300), (235, 352), (350, 255), (300, 95), (sr, -20)],
                    [unit(1, 0.5), (1, 0), unit(0.1, -1), unit(-0.8, -0.7), unit(-1, -0.6)])
    inner = hermite([(sr + t * 0.5, 228), (215, 272), (262, 222), (sr + t * 0.5, 48)],
                    [unit(1, 0.6), (1, -0.1), unit(-0.2, -1), unit(-1, -0.9)])
    out[0x266D] = (polys_ops([stemr, outer], [inner]), 430)
    # ♮ natural: two stems and two bars rising to the right
    hb = t * 1.35
    lx, rx = 80, 300
    rise = 55
    lstem = rect(lx, 120, lx + t, 760)
    rstem = rect(rx, -230, rx + t, 400 + rise + hb)
    bar1 = [(lx, 400), (lx, 400 + hb), (rx + t, 400 + rise + hb), (rx + t, 400 + rise)]
    bar2 = [(lx, 120), (lx, 120 + hb), (rx + t, 120 + rise + hb), (rx + t, 120 + rise)]
    out[0x266E] = (polys_ops([lstem, rstem, bar1, bar2]), rx + t + 80)
    # ♯ sharp: two stems, two bars across rising to the right
    x1, x2 = 150, 300
    s1 = rect(x1, -210, x1 + t, 700)
    s2 = rect(x2, -170, x2 + t, 740)
    bars = []
    for y in (150, 420):
        bars.append([(50, y), (50, y + hb), (400 + t, y + hb + 70), (400 + t, y + 70)])
    out[0x266F] = (polys_ops([s1, s2] + bars), 400 + t + 70)
    return out


def add_symbols(f):
    """The symbols Suhar has not drawn, drawn into TTFont `f` (one face of Suhar App)."""
    face = Face(f)
    cm = face.cm
    made = {}
    made.update(derived(face))
    made.update(drawn(face))
    order = list(f.getGlyphOrder())
    glyf = f['glyf']
    hmtx = f['hmtx']
    added = []
    for cp, (ops, adv) in sorted(made.items()):
        if cp in cm:
            continue                   # (Suhar's own: kept)
        name = 'uni%04X' % cp
        g = build(face, ops)
        order.append(name)
        f.setGlyphOrder(order)
        glyf.glyphOrder = order
        glyf[name] = g
        g.recalcBounds(glyf)
        hmtx.metrics[name] = (int(adv), getattr(g, 'xMin', 0))
        for t in f['cmap'].tables:
            if t.isUnicode() and (t.format == 12 or (t.format == 4 and cp <= 0xFFFF)):
                t.cmap[cp] = name
        added.append(cp)
    return added


if __name__ == '__main__':
    if len(sys.argv) != 3:
        print(__doc__)
        sys.exit(2)
    font = TTFont(sys.argv[1])
    got = add_symbols(font)
    font.save(sys.argv[2])
    print(sys.argv[2], len(got), 'symbols:', ''.join(chr(c) for c in got))
