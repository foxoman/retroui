## Shape layers: rectangles, rounded rectangles, ellipses, polygons and
## stars, lines with arrowheads and custom shapes, kept as outlines (paths)
## and drawn -- filled with a color or a gradient, stroked inside, on or
## outside their edge, solid or dashed -- sharp at any size. Importing it
## sets `photo.shapeRender`.
##
## ```nim
## let L = d.addShapeLayer(ShapeData(path: rectPath(10, 10, 200, 120, 12),
##                                   fill: solidPaint(0xFFCC3333'u32)))
## ```

import std/[math, strutils, hashes, locks, algorithm]
import gfx, photo, raster, parallel, textengine, photostyles

type Pt* = (float, float)
  ## A point: x, y (image pixels).

const Kappa = 0.5522847498        ## (a quarter of a circle as one cubic curve)

proc corner(p: Pt): PathPoint = PathPoint(p: p, inH: p, outH: p)

proc solidPaint*(c: uint32): ShapePaint =
  ## A fill or stroke of one color.
  ShapePaint(kind: spColor, color: c, color2: c, angle: 90, opacity: 100)

proc gradientPaint*(c0, c1: uint32; angle = 90; style = 0): ShapePaint =
  ## A fill or stroke of a gradient from `c0` to `c1` (`angle` in degrees;
  ## `style` 0 linear, 1 radial, 2 angle, 3 reflected, 4 diamond).
  ShapePaint(kind: spGradient, color: c0, color2: c1, angle: angle, style: style, opacity: 100)

# ---- outlines --------------------------------------------------------------------------------------------

proc ordered(x0, y0, x1, y1: float): (float, float, float, float) =
  (min(x0, x1), min(y0, y1), max(x0, x1), max(y0, y1))

proc rectPath*(x0, y0, x1, y1: float; radius = 0.0): Path =
  ## A rectangle (its corners rounded by `radius`), clockwise.
  let (a, b, c, d) = ordered(x0, y0, x1, y1)
  let r = clamp(radius, 0.0, min(c - a, d - b) / 2)
  var sp = SubPath(closed: true)
  if r <= 0.01:
    for p in [(a, b), (c, b), (c, d), (a, d)]: sp.pts.add corner(p)
  else:
    let k = r * (1 - Kappa)
    sp.pts.add PathPoint(p: (a + r, b), inH: (a + k, b), outH: (a + r, b))
    sp.pts.add PathPoint(p: (c - r, b), inH: (c - r, b), outH: (c - k, b))
    sp.pts.add PathPoint(p: (c, b + r), inH: (c, b + k), outH: (c, b + r))
    sp.pts.add PathPoint(p: (c, d - r), inH: (c, d - r), outH: (c, d - k))
    sp.pts.add PathPoint(p: (c - r, d), inH: (c - k, d), outH: (c - r, d))
    sp.pts.add PathPoint(p: (a + r, d), inH: (a + r, d), outH: (a + k, d))
    sp.pts.add PathPoint(p: (a, d - r), inH: (a, d - k), outH: (a, d - r))
    sp.pts.add PathPoint(p: (a, b + r), inH: (a, b + r), outH: (a, b + k))
  result.subs.add sp

proc ellipsePath*(x0, y0, x1, y1: float): Path =
  ## The ellipse in the box, clockwise.
  let (a, b, c, d) = ordered(x0, y0, x1, y1)
  let cx = (a + c) / 2
  let cy = (b + d) / 2
  let kx = (c - a) / 2 * Kappa
  let ky = (d - b) / 2 * Kappa
  var sp = SubPath(closed: true)
  sp.pts.add PathPoint(p: (cx, b), inH: (cx - kx, b), outH: (cx + kx, b))
  sp.pts.add PathPoint(p: (c, cy), inH: (c, cy - ky), outH: (c, cy + ky))
  sp.pts.add PathPoint(p: (cx, d), inH: (cx + kx, d), outH: (cx - kx, d))
  sp.pts.add PathPoint(p: (a, cy), inH: (a, cy + ky), outH: (a, cy - ky))
  result.subs.add sp

proc polygonPath*(x0, y0, x1, y1: float; sides: int; star = false; indent = 50; smooth = false): Path =
  ## A polygon of `sides` sides (a star of as many points: its inner corners
  ## `indent` % of the way in) in the box, a corner on top; `smooth`
  ## rounds its corners.
  let (a, b, c, d) = ordered(x0, y0, x1, y1)
  let n = clamp(sides, 3, 100)
  let cx = (a + c) / 2
  let cy = (b + d) / 2
  let rx = (c - a) / 2
  let ry = (d - b) / 2
  var pts: seq[Pt]
  let m = if star: 2 * n else: n
  for i in 0 ..< m:
    let ang = -PI / 2 + i.float * 2 * PI / m.float
    let k = if star and i mod 2 == 1: 1 - clamp(indent, 1, 99) / 100 else: 1.0
    pts.add (cx + cos(ang) * rx * k, cy + sin(ang) * ry * k)
  var sp = SubPath(closed: true)
  for i, p in pts:
    if smooth:
      let pv = pts[(i + m - 1) mod m]
      let nx = pts[(i + 1) mod m]
      let tx = (nx[0] - pv[0]) * 0.18
      let ty = (nx[1] - pv[1]) * 0.18
      sp.pts.add PathPoint(p: p, inH: (p[0] - tx, p[1] - ty), outH: (p[0] + tx, p[1] + ty))
    else: sp.pts.add corner(p)
  result.subs.add sp

proc linePath*(x0, y0, x1, y1, weight: float; arrowStart = false; arrowEnd = false; arrowW = 500;
               arrowL = 1000; concavity = 0): Path =
  ## A line `weight` wide as an outline, with arrowheads `arrowW` % of the
  ## weight wide and `arrowL` % long, their backs hollowed `concavity` %
  ## (-50..50).
  let dx = x1 - x0
  let dy = y1 - y0
  let len = sqrt(dx * dx + dy * dy)
  if len < 1e-6: return
  let u = (dx / len, dy / len)
  let n = (-u[1], u[0])
  let hw = max(0.25, weight / 2)
  let aw = max(hw, weight * arrowW.float / 200)
  var al = weight * arrowL.float / 100
  let both = arrowStart and arrowEnd
  if (if both: 2 * al else: al) > len: al = (if both: len / 2 else: len)
  let cc = clamp(concavity, -50, 50).float / 100
  proc at(base: Pt; along, across: float): Pt =
    (base[0] + u[0] * along + n[0] * across, base[1] + u[1] * along + n[1] * across)
  var pts: seq[Pt]
  let a = (x0, y0)
  let b = (x1, y1)
  # (+n side from the start to the end, then back along the -n side)
  if arrowStart:
    pts.add at(a, al, aw)
    pts.add at(a, al + al * cc * (1 - hw / aw) - al * cc, hw)
  else: pts.add at(a, 0, hw)
  if arrowEnd:
    pts.add at(b, -al - al * cc * (1 - hw / aw) + al * cc, hw)
    pts.add at(b, -al, aw)
    pts.add b
    pts.add at(b, -al, -aw)
    pts.add at(b, -al - al * cc * (1 - hw / aw) + al * cc, -hw)
  else:
    pts.add at(b, 0, hw)
    pts.add at(b, 0, -hw)
  if arrowStart:
    pts.add at(a, al + al * cc * (1 - hw / aw) - al * cc, -hw)
    pts.add at(a, al, -aw)
    pts.add a
  else: pts.add at(a, 0, -hw)
  var sp = SubPath(closed: true)
  for p in pts: sp.pts.add corner(p)
  result.subs.add sp

proc svgPath*(data: string; x0, y0, x1, y1: float; op = poAdd): Path =
  ## An outline written as SVG path data (M L H V C S Q T Z, upper or
  ## lower case) over a 100 x 100 square, stretched into the box; its
  ## subpaths go with `op` (the first: added).
  let sx = (x1 - x0) / 100
  let sy = (y1 - y0) / 100
  proc tr(p: Pt): Pt = (x0 + p[0] * sx, y0 + p[1] * sy)
  var toks: seq[string]
  var cur = ""
  for ch in data:
    if ch in {'0' .. '9', '.'} or (ch in {'-', '+'} and (cur.len == 0 or cur[^1] in {'e', 'E'})):
      if ch in {'-', '+'} and cur.len > 0 and cur[^1] notin {'e', 'E'}:
        toks.add cur
        cur = ""
      if ch == '.' and '.' in cur:
        toks.add cur
        cur = ""
      cur.add ch
    elif ch == '-':
      toks.add cur
      cur = "-"
    else:
      if cur.len > 0:
        toks.add cur
        cur = ""
      if ch.isAlphaAscii: toks.add $ch
  if cur.len > 0: toks.add cur
  var i = 0
  var cmd = 'M'
  var pen: Pt = (0.0, 0.0)
  var start: Pt = (0.0, 0.0)
  var lastCtl: Pt = (0.0, 0.0)
  var lastWasCurve = false
  var sp = SubPath()
  var raw: seq[(Pt, Pt, Pt)]       # (in, point, out) in the square
  template flushSub() =
    if raw.len > 0:
      var s = SubPath(closed: sp.closed, op: (if result.subs.len == 0: poAdd else: op))
      for (ih, p, oh) in raw: s.pts.add PathPoint(p: tr(p), inH: tr(ih), outH: tr(oh))
      result.subs.add s
    raw.setLen(0)
    sp = SubPath()
  proc num(): float =
    if i >= toks.len: return 0
    result = try: parseFloat(toks[i]) except ValueError: 0.0
    inc i
  while i < toks.len:
    if toks[i].len == 1 and toks[i][0].isAlphaAscii:
      cmd = toks[i][0]
      inc i
    let rel = cmd.isLowerAscii
    let base = if rel: pen else: (0.0, 0.0)
    case cmd.toUpperAscii
    of 'M':
      flushSub()
      let p = (base[0] + num(), base[1] + num())
      raw.add (p, p, p)
      pen = p
      start = p
      cmd = if rel: 'l' else: 'L'
      lastWasCurve = false
    of 'L', 'H', 'V':
      var p = pen
      case cmd.toUpperAscii
      of 'L': p = (base[0] + num(), base[1] + num())
      of 'H': p = ((if rel: pen[0] else: 0.0) + num(), pen[1])
      else: p = (pen[0], (if rel: pen[1] else: 0.0) + num())
      raw.add (p, p, p)
      pen = p
      lastWasCurve = false
    of 'C', 'S':
      var c1: Pt
      if cmd.toUpperAscii == 'C': c1 = (base[0] + num(), base[1] + num())
      else: c1 = if lastWasCurve: (2 * pen[0] - lastCtl[0], 2 * pen[1] - lastCtl[1]) else: pen
      let c2 = (base[0] + num(), base[1] + num())
      let p = (base[0] + num(), base[1] + num())
      if raw.len == 0: raw.add (pen, pen, pen)
      raw[^1][2] = c1
      raw.add (c2, p, p)
      pen = p
      lastCtl = c2
      lastWasCurve = true
    of 'Q', 'T':
      var q: Pt
      if cmd.toUpperAscii == 'Q': q = (base[0] + num(), base[1] + num())
      else: q = if lastWasCurve: (2 * pen[0] - lastCtl[0], 2 * pen[1] - lastCtl[1]) else: pen
      let p = (base[0] + num(), base[1] + num())
      let c1 = (pen[0] + (q[0] - pen[0]) * 2 / 3, pen[1] + (q[1] - pen[1]) * 2 / 3)
      let c2 = (p[0] + (q[0] - p[0]) * 2 / 3, p[1] + (q[1] - p[1]) * 2 / 3)
      if raw.len == 0: raw.add (pen, pen, pen)
      raw[^1][2] = c1
      raw.add (c2, p, p)
      pen = p
      lastCtl = q
      lastWasCurve = true
    of 'Z':
      if raw.len > 1 and abs(raw[^1][1][0] - start[0]) < 1e-9 and abs(raw[^1][1][1] - start[1]) < 1e-9:
        # (the last point is the first: its curve comes into the first)
        raw[0][0] = raw[^1][0]
        raw.setLen(raw.len - 1)
      sp.closed = true
      pen = start
      flushSub()
      lastWasCurve = false
      cmd = 'M'
      if i < toks.len and not (toks[i].len == 1 and toks[i][0].isAlphaAscii):
        inc i                            # (a stray number)
    else:
      inc i
  flushSub()

proc combine*(a: var Path; b: Path; op: PathOp) =
  ## `b`'s subpaths added to `a`'s, going with them by `op`.
  for k, s in b.subs:
    var t = s
    if k == 0 or not s.joined: t.op = (if a.subs.len == 0 and k == 0: poAdd else: op)
    a.subs.add t

type CustomShape* = object
  ## A shape of the Shapes panel (the Custom Shape tool).
  name*: string                   ## shown in the panel
  parts*: seq[(PathOp, string)]   ## SVG path data over 100 x 100 (`svgPath`)
  category*: string               ## its set in the Shapes panel ("Arrows", "Nature"...)

const ShapeCategories* = ["Shapes", "Arrows", "Banners & Awards", "Frames", "Nature", "Animals", "Objects",
                          "Symbols", "Talk Bubbles", "Music", "Ornaments", "Web"]
  ## The sets of the Custom Shape tool's shapes.

# (the shapes made from numbers: polygons, stars, circles, bands -- as
# SVG path data over 100 x 100)

proc f1(v: float): string = $(round(v * 10) / 10)

proc polyD(pts: openArray[(float, float)]): string =
  result = "M" & f1(pts[0][0]) & " " & f1(pts[0][1])
  for k in 1 ..< pts.len: result.add " L" & f1(pts[k][0]) & " " & f1(pts[k][1])
  result.add " Z"

proc regularPts(n: int; r: float; cx = 50.0; cy = 50.0; rot = -90.0): seq[(float, float)] =
  for k in 0 ..< n:
    let a = degToRad(rot + k.float * 360 / n.float)
    result.add (cx + cos(a) * r, cy + sin(a) * r)

proc starPts(n: int; ro, ri: float; cx = 50.0; cy = 50.0; rot = -90.0): seq[(float, float)] =
  for k in 0 ..< 2 * n:
    let a = degToRad(rot + k.float * 180 / n.float)
    let r = if k mod 2 == 0: ro else: ri
    result.add (cx + cos(a) * r, cy + sin(a) * r)

proc circleD(cx, cy, r: float): string =
  let k = r * 0.5523
  "M" & f1(cx) & " " & f1(cy - r) &
    " C" & f1(cx + k) & " " & f1(cy - r) & " " & f1(cx + r) & " " & f1(cy - k) & " " & f1(cx + r) & " " & f1(cy) &
    " C" & f1(cx + r) & " " & f1(cy + k) & " " & f1(cx + k) & " " & f1(cy + r) & " " & f1(cx) & " " & f1(cy + r) &
    " C" & f1(cx - k) & " " & f1(cy + r) & " " & f1(cx - r) & " " & f1(cy + k) & " " & f1(cx - r) & " " & f1(cy) &
    " C" & f1(cx - r) & " " & f1(cy - k) & " " & f1(cx - k) & " " & f1(cy - r) & " " & f1(cx) & " " & f1(cy - r) & " Z"

proc rectD(x0, y0, x1, y1: float): string = polyD([(x0, y0), (x1, y0), (x1, y1), (x0, y1)])

proc roundRectD(x0, y0, x1, y1, r: float): string =
  let k = r * 0.5523
  "M" & f1(x0 + r) & " " & f1(y0) & " L" & f1(x1 - r) & " " & f1(y0) &
    " C" & f1(x1 - r + k) & " " & f1(y0) & " " & f1(x1) & " " & f1(y0 + r - k) & " " & f1(x1) & " " & f1(y0 + r) &
    " L" & f1(x1) & " " & f1(y1 - r) &
    " C" & f1(x1) & " " & f1(y1 - r + k) & " " & f1(x1 - r + k) & " " & f1(y1) & " " & f1(x1 - r) & " " & f1(y1) &
    " L" & f1(x0 + r) & " " & f1(y1) &
    " C" & f1(x0 + r - k) & " " & f1(y1) & " " & f1(x0) & " " & f1(y1 - r + k) & " " & f1(x0) & " " & f1(y1 - r) &
    " L" & f1(x0) & " " & f1(y0 + r) &
    " C" & f1(x0) & " " & f1(y0 + r - k) & " " & f1(x0 + r - k) & " " & f1(y0) & " " & f1(x0 + r) & " " & f1(y0) & " Z"

proc barD(cx, cy, length, thick, angle: float): string =
  ## (a bar `length` long, `thick` wide, through `cx`, `cy` at `angle` degrees)
  let a = degToRad(angle)
  let (ux, uy) = (cos(a) * length / 2, sin(a) * length / 2)
  let (vx, vy) = (-sin(a) * thick / 2, cos(a) * thick / 2)
  polyD([(cx - ux - vx, cy - uy - vy), (cx + ux - vx, cy + uy - vy), (cx + ux + vx, cy + uy + vy),
         (cx - ux + vx, cy - uy + vy)])

proc arcBandD(cx, cy, r0, r1, a0, a1: float; steps = 28): string =
  ## (a band between radii `r0` and `r1` from `a0` to `a1` degrees)
  var pts: seq[(float, float)]
  for k in 0 .. steps:
    let a = degToRad(a0 + (a1 - a0) * k.float / steps.float)
    pts.add (cx + cos(a) * r1, cy + sin(a) * r1)
  for k in countdown(steps, 0):
    let a = degToRad(a0 + (a1 - a0) * k.float / steps.float)
    pts.add (cx + cos(a) * r0, cy + sin(a) * r0)
  polyD(pts)

proc sh(name, category: string; parts: varargs[(PathOp, string)]): CustomShape =
  CustomShape(name: name, category: category, parts: @parts)

proc ad(d: string): (PathOp, string) = (poAdd, d)
proc sb(d: string): (PathOp, string) = (poSubtract, d)

proc buildShapes(): seq[CustomShape] =
  let old = @[
  CustomShape(name: "Heart", parts: @[(poAdd, "M50 92 C22 72 0 54 0 30 C0 12 14 0 29 0 C39 0 46 6 50 14 " &
                                              "C54 6 61 0 71 0 C86 0 100 12 100 30 C100 54 78 72 50 92 Z")]),
  CustomShape(name: "Star", parts: @[(poAdd, "M50 0 L61.8 35.4 L99 35.4 L68.9 57.3 L80.4 92.7 L50 70.8 " &
                                             "L19.6 92.7 L31.1 57.3 L1 35.4 L38.2 35.4 Z")]),
  CustomShape(name: "Arrow", parts: @[(poAdd, "M0 35 L58 35 L58 8 L100 50 L58 92 L58 65 L0 65 Z")]),
  CustomShape(name: "Check Mark", parts: @[(poAdd, "M0 55 L15 40 L38 63 L85 10 L100 25 L38 92 Z")]),
  CustomShape(name: "Lightning", parts: @[(poAdd, "M58 0 L14 56 L44 56 L32 100 L86 38 L55 38 L72 0 Z")]),
  CustomShape(name: "Talk Bubble", parts: @[(poAdd, "M12 0 L88 0 C95 0 100 5 100 12 L100 58 C100 65 95 70 " &
                                                    "88 70 L42 70 L18 96 L24 70 L12 70 C5 70 0 65 0 58 " &
                                                    "L0 12 C0 5 5 0 12 0 Z")]),
  CustomShape(name: "Cross", parts: @[(poAdd, "M35 0 L65 0 L65 35 L100 35 L100 65 L65 65 L65 100 L35 100 " &
                                              "L35 65 L0 65 L0 35 L35 35 Z")]),
  CustomShape(name: "Drop", parts: @[(poAdd, "M50 0 C50 0 88 42 88 64 C88 86 71 100 50 100 C29 100 12 86 " &
                                             "12 64 C12 42 50 0 50 0 Z")]),
  CustomShape(name: "Leaf", parts: @[(poAdd, "M0 100 C0 40 40 0 100 0 C100 60 60 100 0 100 Z")]),
  CustomShape(name: "Ring", parts: @[(poAdd, "M50 0 C77.6 0 100 22.4 100 50 C100 77.6 77.6 100 50 100 " &
                                             "C22.4 100 0 77.6 0 50 C0 22.4 22.4 0 50 0 Z"),
                                     (poSubtract, "M50 25 C63.8 25 75 36.2 75 50 C75 63.8 63.8 75 50 75 " &
                                                  "C36.2 75 25 63.8 25 50 C25 36.2 36.2 25 50 25 Z")]),
  CustomShape(name: "Moon", parts: @[(poAdd, "M50 0 C22.4 0 0 22.4 0 50 C0 77.6 22.4 100 50 100 " &
                                             "C68 100 84 90 92 76 C66 80 40 62 40 36 C40 20 48 7 60 1 " &
                                             "C57 0.4 53 0 50 0 Z")]),
  CustomShape(name: "House", parts: @[(poAdd, "M50 0 L100 45 L86 45 L86 100 L60 100 L60 68 L40 68 L40 100 " &
                                              "L14 100 L14 45 L0 45 Z")]),
  CustomShape(name: "Banner", parts: @[(poAdd, "M0 20 L100 20 L86 50 L100 80 L0 80 L14 50 Z")]),
  CustomShape(name: "Diamond", parts: @[(poAdd, "M50 0 L100 50 L50 100 L0 50 Z")]),
  CustomShape(name: "Cloud", parts: @[(poAdd, "M25 85 C11 85 0 75 0 62 C0 50 9 41 21 40 C22 26 33 15 47 15 " &
                                              "C58 15 67 21 72 30 C75 29 78 28 81 28 C92 28 100 37 100 48 " &
                                              "C100 50 100 51 100 52 C100 70 90 85 75 85 Z")]),
  CustomShape(name: "Puzzle", parts: @[(poAdd, "M0 20 L32 20 C30 14 30 10 33 6 C37 0 47 0 50 6 C53 10 53 14 " &
                                               "51 20 L80 20 L80 48 C86 46 90 46 94 49 C100 53 100 63 94 67 " &
                                               "C90 70 86 70 80 68 L80 100 L0 100 Z")]),
  CustomShape(name: "Gear", parts: @[(poAdd, "M43 0 L57 0 L59 13 C63 14 67 16 70 18 L81 10 L90 19 L82 30 " &
                                             "C84 33 86 37 87 41 L100 43 L100 57 L87 59 C86 63 84 67 82 70 " &
                                             "L90 81 L81 90 L70 82 C67 84 63 86 59 87 L57 100 L43 100 L41 87 " &
                                             "C37 86 33 84 30 82 L19 90 L10 81 L18 70 C16 67 14 63 13 59 " &
                                             "L0 57 L0 43 L13 41 C14 37 16 33 18 30 L10 19 L19 10 L30 18 " &
                                             "C33 16 37 14 41 13 Z"),
                                     (poSubtract, "M50 34 C58.8 34 66 41.2 66 50 C66 58.8 58.8 66 50 66 " &
                                                  "C41.2 66 34 58.8 34 50 C34 41.2 41.2 34 50 34 Z")]),
  CustomShape(name: "Music Note", parts: @[(poAdd, "M40 0 L48 0 C52 10 62 16 74 20 C84 23 90 30 88 42 " &
                                                   "C84 32 70 28 48 26 L48 78 C48 92 36 100 22 100 " &
                                                   "C10 100 2 94 2 85 C2 74 14 66 26 66 C32 66 36 67 40 70 Z")]),
  CustomShape(name: "Paw", parts: @[(poAdd, "M50 48 C66 48 82 64 82 80 C82 92 72 98 62 96 C56 95 54 92 50 92 " &
                                            "C46 92 44 95 38 96 C28 98 18 92 18 80 C18 64 34 48 50 48 Z"),
                                    (poAdd, "M30 4 C38 4 43 14 43 24 C43 34 38 40 32 40 C24 40 19 30 19 20 " &
                                            "C19 10 24 4 30 4 Z"),
                                    (poAdd, "M70 4 C76 4 81 10 81 20 C81 30 76 40 68 40 C62 40 57 34 57 24 " &
                                            "C57 14 62 4 70 4 Z"),
                                    (poAdd, "M8 30 C14 30 20 38 20 46 C20 54 16 58 11 58 C5 58 0 50 0 42 " &
                                            "C0 35 3 30 8 30 Z"),
                                    (poAdd, "M92 30 C97 30 100 35 100 42 C100 50 95 58 89 58 C84 58 80 54 80 46 " &
                                            "C80 38 86 30 92 30 Z")])]
  let cats = {"Heart": "Shapes", "Star": "Shapes", "Arrow": "Arrows", "Check Mark": "Symbols",
              "Lightning": "Nature", "Talk Bubble": "Talk Bubbles", "Cross": "Symbols", "Drop": "Nature",
              "Leaf": "Nature", "Ring": "Frames", "Moon": "Nature", "House": "Objects",
              "Banner": "Banners & Awards", "Diamond": "Shapes", "Cloud": "Nature", "Puzzle": "Objects",
              "Gear": "Objects", "Music Note": "Music", "Paw": "Animals"}
  for o in old:
    var c = o
    for (n, k) in cats:
      if n == o.name: c.category = k
    result.add c
  # ---- shapes
  result.add sh("Triangle", "Shapes", ad(polyD([(50.0, 3.0), (100.0, 95.0), (0.0, 95.0)])))
  result.add sh("Pentagon", "Shapes", ad(polyD(regularPts(5, 50, 50, 54))))
  result.add sh("Hexagon", "Shapes", ad(polyD(regularPts(6, 50, rot = 0))))
  result.add sh("Octagon", "Shapes", ad(polyD(regularPts(8, 52, rot = 22.5))))
  result.add sh("Parallelogram", "Shapes", ad("M22 15 L100 15 L78 85 L0 85 Z"))
  result.add sh("Trapezoid", "Shapes", ad("M22 20 L78 20 L100 80 L0 80 Z"))
  result.add sh("Semicircle", "Shapes", ad("M0 75 C0 47 22 25 50 25 C78 25 100 47 100 75 Z"))
  result.add sh("Quarter Circle", "Shapes", ad("M0 100 L0 0 C55 0 100 45 100 100 Z"))
  result.add sh("Rounded Square", "Shapes", ad(roundRectD(0, 0, 100, 100, 22)))
  result.add sh("Six-Pointed Star", "Shapes", ad(polyD(starPts(6, 50, 29))))
  result.add sh("Eight-Pointed Star", "Shapes", ad(polyD(starPts(8, 50, 26, rot = -90))))
  result.add sh("Burst", "Shapes", ad(polyD(starPts(16, 50, 38))))
  result.add sh("Heart Outline", "Shapes",
                ad("M50 92 C22 72 0 54 0 30 C0 12 14 0 29 0 C39 0 46 6 50 14 C54 6 61 0 71 0 C86 0 100 12 " &
                   "100 30 C100 54 78 72 50 92 Z"),
                sb("M50 78 C30 62 12 48 12 31 C12 19 20 12 29 12 C37 12 44 18 50 28 C56 18 63 12 71 12 C80 12 " &
                   "88 19 88 31 C88 48 70 62 50 78 Z"))
  # ---- arrows
  result.add sh("Double Arrow", "Arrows", ad("M0 50 L25 20 L25 38 L75 38 L75 20 L100 50 L75 80 L75 62 L25 62 L25 80 Z"))
  result.add sh("Chevron", "Arrows", ad("M0 10 L45 10 L85 50 L45 90 L0 90 L40 50 Z"))
  result.add sh("Arrow Up", "Arrows", ad("M50 0 L95 45 L68 45 L68 100 L32 100 L32 45 L5 45 Z"))
  result.add sh("Notched Arrow", "Arrows", ad("M0 30 L60 30 L60 8 L100 50 L60 92 L60 70 L0 70 L16 50 Z"))
  result.add sh("Curved Arrow", "Arrows",
                ad("M8 95 C8 45 38 22 68 22 L68 0 L100 34 L68 68 L68 46 C48 46 32 62 32 95 Z"))
  result.add sh("Circle Arrow", "Arrows",
                ad("M50 8 C73 8 92 27 92 50 C92 73 73 92 50 92 C27 92 8 73 8 50 L0 50 L20 26 L40 50 L28 50 " &
                   "C28 62 38 72 50 72 C62 72 72 62 72 50 C72 38 62 28 50 28 Z"))
  result.add sh("Arrows Out", "Arrows",
                ad("M50 0 L66 18 L56 18 L56 44 L82 44 L82 34 L100 50 L82 66 L82 56 L56 56 L56 82 L66 82 L50 100 " &
                   "L34 82 L44 82 L44 56 L18 56 L18 66 L0 50 L18 34 L18 44 L44 44 L44 18 L34 18 Z"))
  result.add sh("Pointer", "Arrows", ad("M15 0 L15 80 L34 62 L48 95 L61 89 L47 57 L72 57 Z"))
  # ---- banners and awards
  result.add sh("Ribbon Banner", "Banners & Awards",
                ad("M0 42 L24 42 L24 82 L0 82 L9 62 Z"), ad("M100 42 L76 42 L76 82 L100 82 L91 62 Z"),
                ad(rectD(14, 28, 86, 68)))
  result.add sh("Seal", "Banners & Awards", ad(polyD(starPts(24, 50, 44))))
  result.add sh("Medal", "Banners & Awards",
                ad("M28 0 L46 0 L58 40 L42 44 Z"), ad("M72 0 L54 0 L42 40 L58 44 Z"), ad(circleD(50, 68, 30)),
                sb(circleD(50, 68, 21)), ad(polyD(starPts(5, 16, 7, 50, 69))))
  result.add sh("Shield", "Banners & Awards", ad("M50 0 L95 14 C95 60 78 86 50 100 C22 86 5 60 5 14 Z"))
  result.add sh("Trophy", "Banners & Awards",
                ad("M20 4 L80 4 L80 30 C80 50 66 62 56 64 L56 78 L72 78 L72 94 L28 94 L28 78 L44 78 L44 64 " &
                   "C34 62 20 50 20 30 Z"),
                ad("M20 10 L8 10 C2 10 0 18 3 28 C7 39 15 44 22 44 L22 37 C16 36 12 32 10 26 C8 20 10 17 14 17 " &
                   "L20 17 Z"),
                ad("M80 10 L92 10 C98 10 100 18 97 28 C93 39 85 44 78 44 L78 37 C84 36 88 32 90 26 C92 20 90 17 " &
                   "86 17 L80 17 Z"))
  result.add sh("Crown", "Banners & Awards", ad("M6 88 L0 22 L28 48 L50 8 L72 48 L100 22 L94 88 Z"),
                sb(rectD(12, 72, 88, 78)))
  result.add sh("Rosette", "Banners & Awards", ad("M30 55 L18 100 L34 90 L44 100 L48 62 Z"),
                ad("M70 55 L82 100 L66 90 L56 100 L52 62 Z"), ad(polyD(starPts(14, 38, 31, 50, 40))))
  # ---- frames
  result.add sh("Square Frame", "Frames", ad(rectD(0, 0, 100, 100)), sb(rectD(12, 12, 88, 88)))
  result.add sh("Rounded Frame", "Frames", ad(roundRectD(0, 0, 100, 100, 20)), sb(roundRectD(11, 11, 89, 89, 12)))
  result.add sh("Octagon Frame", "Frames", ad(polyD(regularPts(8, 52, rot = 22.5))),
                sb(polyD(regularPts(8, 41, rot = 22.5))))
  result.add sh("Scalloped Frame", "Frames", ad(polyD(starPts(20, 50, 46))), sb(circleD(50, 50, 37)))
  result.add sh("Double Frame", "Frames", ad(rectD(0, 0, 100, 100)), sb(rectD(6, 6, 94, 94)),
                ad(rectD(11, 11, 89, 89)), sb(rectD(16, 16, 84, 84)))
  # ---- nature
  var sun = @[ad(circleD(50, 50, 22))]
  for k in 0 ..< 12:
    let a = degToRad(k.float * 30)
    let (tx, ty) = (50 + cos(a) * 50, 50 + sin(a) * 50)
    let (lx, ly) = (50 + cos(a + 0.16) * 29, 50 + sin(a + 0.16) * 29)
    let (rx, ry) = (50 + cos(a - 0.16) * 29, 50 + sin(a - 0.16) * 29)
    sun.add ad(polyD([(tx, ty), (lx, ly), (rx, ry)]))
  result.add sh("Sun", "Nature", sun)
  var flower: seq[(PathOp, string)]
  for k in 0 ..< 6:
    let a = degToRad(k.float * 60 - 90)
    flower.add ad(circleD(50 + cos(a) * 28, 50 + sin(a) * 28, 20))
  flower.add sb(circleD(50, 50, 13))
  flower.add ad(circleD(50, 50, 9))
  result.add sh("Flower", "Nature", flower)
  result.add sh("Tree", "Nature", ad("M50 0 L80 38 L66 38 L92 70 L58 70 L58 100 L42 100 L42 70 L8 70 L34 38 L20 38 Z"))
  result.add sh("Mountains", "Nature", ad("M0 90 L32 28 L46 52 L66 16 L100 90 Z"))
  var flake: seq[(PathOp, string)]
  for k in 0 ..< 3: flake.add ad(barD(50, 50, 100, 9, k.float * 60 + 90))
  for k in 0 ..< 6:
    let a = degToRad(k.float * 60 - 90)
    let (cx, cy) = (50 + cos(a) * 32, 50 + sin(a) * 32)
    flake.add ad(barD(cx + cos(a + 0.9) * 7, cy + sin(a + 0.9) * 7, 20, 6, radToDeg(a + 0.9)))
    flake.add ad(barD(cx + cos(a - 0.9) * 7, cy + sin(a - 0.9) * 7, 20, 6, radToDeg(a - 0.9)))
  result.add sh("Snowflake", "Nature", flake)
  result.add sh("Flame", "Nature",
                ad("M50 0 C62 25 86 40 86 66 C86 87 70 100 50 100 C30 100 14 87 14 66 C14 50 24 40 32 30 C34 42 " &
                   "40 49 46 51 C42 31 44 15 50 0 Z"))
  result.add sh("Wave", "Nature", ad("M0 55 C15 35 35 35 50 55 C65 75 85 75 100 55 L100 100 L0 100 Z"))
  result.add sh("Clover", "Nature", ad(circleD(50, 26, 22)), ad(circleD(26, 50, 22)), ad(circleD(74, 50, 22)),
                ad(circleD(50, 72, 20)), ad("M47 70 L53 70 L60 100 L52 100 Z"))
  # ---- animals
  result.add sh("Fish", "Animals", ad("M0 50 C20 20 60 15 80 40 L100 20 L100 80 L80 60 C60 85 20 80 0 50 Z"),
                sb(circleD(24, 45, 5)))
  result.add sh("Bird", "Animals",
                ad("M0 38 C20 28 40 34 50 50 C60 34 80 28 100 38 C80 40 62 54 50 72 C38 54 20 40 0 38 Z"))
  result.add sh("Cat", "Animals",
                ad("M14 30 L18 0 L40 20 C46 18 54 18 60 20 L82 0 L86 30 C96 46 92 70 80 84 C70 96 30 96 20 84 " &
                   "C8 70 4 46 14 30 Z"),
                sb(polyD([(30.0, 48.0), (42.0, 48.0), (36.0, 58.0)])), sb(polyD([(58.0, 48.0), (70.0, 48.0), (64.0, 58.0)])))
  result.add sh("Butterfly", "Animals",
                ad("M50 30 C40 0 0 0 4 30 C7 48 30 50 46 48 C30 55 10 70 20 90 C30 100 46 80 50 60 C54 80 70 100 " &
                   "80 90 C90 70 70 55 54 48 C70 50 93 48 96 30 C100 0 60 0 50 30 Z"))
  result.add sh("Rabbit", "Animals", ad(circleD(50, 70, 28)), ad("M34 48 C26 20 28 0 38 0 C48 0 46 28 44 46 Z"),
                ad("M66 48 C74 20 72 0 62 0 C52 0 54 28 56 46 Z"))
  # ---- objects
  result.add sh("Light Bulb", "Objects",
                ad("M50 0 C74 0 90 16 90 38 C90 54 80 62 70 72 L70 80 L30 80 L30 72 C20 62 10 54 10 38 C10 16 26 0 " &
                   "50 0 Z"), ad("M32 84 L68 84 L68 90 L62 98 L38 98 L32 90 Z"))
  result.add sh("Key", "Objects", ad(circleD(24, 50, 24)),
                ad("M44 44 L100 44 L100 56 L92 56 L92 70 L82 70 L82 56 L74 56 L74 66 L64 66 L64 56 L44 56 Z"),
                sb(circleD(22, 50, 9)))
  result.add sh("Lock", "Objects", ad(rectD(12, 44, 88, 100)),
                ad("M26 44 L26 30 C26 10 38 0 50 0 C62 0 74 10 74 30 L74 44 L63 44 L63 30 C63 18 57 11 50 11 " &
                   "C43 11 37 18 37 30 L37 44 Z"),
                sb(circleD(50, 66, 7)), sb("M47 68 L53 68 L55 86 L45 86 Z"))
  result.add sh("Bell", "Objects",
                ad("M50 0 C56 0 60 4 60 9 C76 14 84 28 84 46 L84 66 L96 82 L4 82 L16 66 L16 46 C16 28 24 14 40 9 " &
                   "C40 4 44 0 50 0 Z"), ad(circleD(50, 90, 9)))
  result.add sh("Envelope", "Objects", ad(rectD(0, 18, 100, 82)), sb("M5 22 L50 56 L95 22 L95 29 L50 63 L5 29 Z"))
  result.add sh("Camera", "Objects", ad("M0 28 L25 28 L33 12 L67 12 L75 28 L100 28 L100 90 L0 90 Z"),
                sb(circleD(50, 58, 23)), ad(circleD(50, 58, 15)))
  result.add sh("Cup", "Objects", ad("M8 18 L74 18 L74 70 C74 86 62 96 47 96 L35 96 C20 96 8 86 8 70 Z"),
                ad("M74 28 L84 28 C96 28 100 38 100 47 C100 58 92 66 80 66 L74 66 L74 56 L80 56 C86 56 90 52 90 47 " &
                   "C90 42 86 38 82 38 L74 38 Z"))
  result.add sh("Umbrella", "Objects",
                ad("M0 50 C0 22 22 0 50 0 C78 0 100 22 100 50 C92 44 84 44 76 50 C68 44 58 44 50 50 C42 44 32 44 " &
                   "24 50 C16 44 8 44 0 50 Z"), ad("M47 48 L53 48 L53 86 C53 96 39 99 35 88 L41 86 C43 90 47 90 47 86 Z"))
  result.add sh("Pencil", "Objects", ad("M4 96 L13 66 L72 7 L93 28 L34 87 Z"), sb("M60 19 L81 40 L77 44 L56 23 Z"))
  result.add sh("Clock", "Objects", ad(circleD(50, 50, 50)), sb(circleD(50, 50, 42)), ad(rectD(46, 16, 54, 52)),
                ad(barD(60, 58, 30, 8, 35)))
  result.add sh("Tag", "Objects", ad("M0 50 L45 5 L95 5 L95 55 L50 100 Z"), sb(circleD(77, 23, 8)))
  result.add sh("Flag", "Objects", ad(rectD(8, 0, 16, 100)),
                ad("M16 6 C38 -4 60 20 92 8 L92 52 C60 64 38 40 16 50 Z"))
  result.add sh("Book", "Objects",
                ad("M50 16 C35 6 15 6 0 10 L0 90 C15 86 35 86 50 96 C65 86 85 86 100 90 L100 10 C85 6 65 6 50 16 Z"),
                sb("M48 22 L52 22 L52 88 L48 88 Z"))
  result.add sh("Gift", "Objects", ad(rectD(10, 46, 90, 100)), ad(rectD(4, 30, 96, 46)),
                ad("M50 30 C40 8 18 8 22 21 C25 29 40 30 50 30 Z"), ad("M50 30 C60 8 82 8 78 21 C75 29 60 30 50 30 Z"),
                sb(rectD(45, 30, 55, 100)))
  result.add sh("Phone", "Objects",
                ad("M20 0 L38 0 L44 25 L32 34 C38 50 50 62 66 68 L75 56 L100 62 L100 80 C100 92 92 100 80 100 " &
                   "C36 100 0 64 0 20 C0 8 8 0 20 0 Z"))
  # ---- symbols
  result.add sh("Minus", "Symbols", ad(rectD(0, 38, 100, 62)))
  result.add sh("Multiply", "Symbols", ad(barD(50, 50, 120, 24, 45)), ad(barD(50, 50, 120, 24, -45)))
  result.add sh("Equals", "Symbols", ad(rectD(0, 22, 100, 42)), ad(rectD(0, 58, 100, 78)))
  result.add sh("Percent", "Symbols", ad(circleD(22, 22, 20)), sb(circleD(22, 22, 10)), ad(circleD(78, 78, 20)),
                sb(circleD(78, 78, 10)), ad(barD(50, 50, 118, 12, -50)))
  result.add sh("Infinity", "Symbols", ad(circleD(28, 50, 27)), sb(circleD(28, 50, 14)), ad(circleD(72, 50, 27)),
                sb(circleD(72, 50, 14)))
  result.add sh("Spade", "Symbols",
                ad("M50 0 C70 25 100 40 100 62 C100 78 88 88 74 88 C64 88 56 84 54 78 C56 90 62 96 70 100 L30 100 " &
                   "C38 96 44 90 46 78 C44 84 36 88 26 88 C12 88 0 78 0 62 C0 40 30 25 50 0 Z"))
  result.add sh("Club", "Symbols", ad(circleD(50, 24, 23)), ad(circleD(24, 58, 23)), ad(circleD(76, 58, 23)),
                ad("M45 50 L55 50 C56 76 62 92 72 100 L28 100 C38 92 44 76 45 50 Z"))
  result.add sh("Location Pin", "Symbols",
                ad("M50 0 C72 0 90 18 90 40 C90 65 50 100 50 100 C50 100 10 65 10 40 C10 18 28 0 50 0 Z"),
                sb(circleD(50, 40, 15)))
  result.add sh("Power", "Symbols", ad(arcBandD(50, 54, 34, 46, -50, 230)), ad(rectD(44, 0, 56, 50)))
  result.add sh("Asterisk", "Symbols", ad(barD(50, 50, 100, 16, 90)), ad(barD(50, 50, 100, 16, 30)),
                ad(barD(50, 50, 100, 16, -30)))
  # ---- talk bubbles
  result.add sh("Round Bubble", "Talk Bubbles",
                ad("M50 0 C78 0 100 18 100 40 C100 62 78 80 50 80 C44 80 38 79 33 78 L12 98 L18 72 C6 64 0 52 0 40 " &
                   "C0 18 22 0 50 0 Z"))
  result.add sh("Thought Bubble", "Talk Bubbles", ad(circleD(30, 32, 24)), ad(circleD(55, 26, 26)),
                ad(circleD(76, 38, 22)), ad(circleD(50, 48, 26)), ad(circleD(20, 80, 8)), ad(circleD(8, 95, 5)))
  result.add sh("Shout", "Talk Bubbles", ad(polyD(starPts(12, 50, 34, rot = -75))))
  result.add sh("Square Bubble", "Talk Bubbles", ad("M0 0 L100 0 L100 70 L45 70 L22 98 L26 70 L0 70 Z"))
  # ---- music
  result.add sh("Two Notes", "Music",
                ad("M30 20 L90 5 L90 70 C90 80 82 86 72 86 C62 86 56 80 56 74 C56 66 64 60 72 60 C76 60 79 61 82 63 " &
                   "L82 26 L38 37 L38 82 C38 92 30 98 20 98 C10 98 4 92 4 86 C4 78 12 72 20 72 C24 72 27 73 30 75 Z"))
  result.add sh("Speaker", "Music", ad("M0 34 L22 34 L50 8 L50 92 L22 66 L0 66 Z"),
                ad(arcBandD(50, 50, 22, 30, -45, 45)), ad(arcBandD(50, 50, 38, 46, -45, 45)))
  # ---- ornaments
  result.add sh("Sparkle", "Ornaments",
                ad("M50 0 C54 34 66 46 100 50 C66 54 54 66 50 100 C46 66 34 54 0 50 C34 46 46 34 50 0 Z"))
  result.add sh("Twinkles", "Ornaments",
                ad("M36 10 C39 34 46 41 70 44 C46 47 39 54 36 78 C33 54 26 47 2 44 C26 41 33 34 36 10 Z"),
                ad("M80 56 C82 70 86 74 100 76 C86 78 82 82 80 96 C78 82 74 78 60 76 C74 74 78 70 80 56 Z"))
  result.add sh("Fleur", "Ornaments",
                ad("M50 0 C62 14 64 30 54 46 L54 60 L46 60 L46 46 C36 30 38 14 50 0 Z"),
                ad("M44 58 C30 36 6 38 4 54 C2 66 16 72 24 62 C18 62 14 58 16 54 C20 46 34 50 44 66 Z"),
                ad("M56 58 C70 36 94 38 96 54 C98 66 84 72 76 62 C82 62 86 58 84 54 C80 46 66 50 56 66 Z"),
                ad(rectD(30, 64, 70, 72)), ad("M44 72 L56 72 L54 100 L46 100 Z"))
  result.add sh("Diamond Tile", "Ornaments", ad("M50 0 L100 50 L50 100 L0 50 Z"), sb("M50 18 L82 50 L50 82 L18 50 Z"),
                ad("M50 34 L66 50 L50 66 L34 50 Z"))
  # ---- web
  result.add sh("Download", "Web", ad("M38 0 L62 0 L62 40 L80 40 L50 72 L20 40 L38 40 Z"),
                ad("M0 70 L10 70 L10 88 L90 88 L90 70 L100 70 L100 100 L0 100 Z"))
  result.add sh("Upload", "Web", ad("M50 0 L80 32 L62 32 L62 72 L38 72 L38 32 L20 32 Z"),
                ad("M0 70 L10 70 L10 88 L90 88 L90 70 L100 70 L100 100 L0 100 Z"))
  result.add sh("Magnifier", "Web", ad(circleD(40, 40, 38)), sb(circleD(40, 40, 27)), ad(barD(78, 78, 42, 15, 45)))
  result.add sh("User", "Web", ad(circleD(50, 28, 24)), ad("M8 100 C8 72 26 56 50 56 C74 56 92 72 92 100 Z"))
  result.add sh("Wi-Fi", "Web", ad(circleD(50, 86, 9)), ad(arcBandD(50, 86, 24, 34, -135, -45)),
                ad(arcBandD(50, 86, 44, 54, -135, -45)), ad(arcBandD(50, 86, 64, 74, -135, -45)))
  result.add sh("Battery", "Web", ad(roundRectD(0, 22, 90, 78, 8)), sb(roundRectD(7, 29, 83, 71, 4)),
                ad(rectD(90, 38, 100, 62)), ad(rectD(12, 34, 58, 66)))
  result.add sh("Signal", "Web", ad(rectD(0, 72, 18, 100)), ad(rectD(27, 52, 45, 100)), ad(rectD(54, 30, 72, 100)),
                ad(rectD(81, 6, 99, 100)))
  result.add sh("Play", "Web", ad("M15 0 L95 50 L15 100 Z"))
  result.add sh("Pause", "Web", ad(rectD(12, 0, 40, 100)), ad(rectD(60, 0, 88, 100)))

var CustomShapes* = buildShapes()
  ## The shapes of the Custom Shape tool (`category` its set in the Shapes
  ## panel): 19 of the first ones, and Photoshop's kinds of sets since.

proc customPath*(i: int; x0, y0, x1, y1: float): Path =
  ## Custom shape `i` stretched into the box.
  let (a, b, c, d) = ordered(x0, y0, x1, y1)
  let cs = CustomShapes[clamp(i, 0, CustomShapes.high)]
  for (op, data) in cs.parts:
    result.combine(svgPath(data, a, b, c, d), (if result.subs.len == 0: poAdd else: op))

proc pathBounds*(p: Path): (float, float, float, float) =
  ## The box around a path's points and handles.
  result = (1e18, 1e18, -1e18, -1e18)
  for s in p.subs:
    for q in s.pts:
      for v in [q.p, q.inH, q.outH]:
        result[0] = min(result[0], v[0]); result[1] = min(result[1], v[1])
        result[2] = max(result[2], v[0]); result[3] = max(result[3], v[1])

# ---- flattening ------------------------------------------------------------------------------------------

proc flat(s: SubPath; tol = 0.15): seq[Pt] =
  ## A subpath as a polygon (its curves in pieces no more than `tol` off).
  let n = s.pts.len
  if n == 0: return
  result.add s.pts[0].p
  let segs = if s.closed: n else: n - 1
  for k in 0 ..< segs:
    let a = s.pts[k]
    let b = s.pts[(k + 1) mod n]
    if a.outH == a.p and b.inH == b.p:
      if b.p != result[^1]: result.add b.p
      continue
    # pieces by how far the handles bend the curve
    let ddx = max(abs(a.p[0] - 2 * a.outH[0] + b.inH[0]), abs(a.outH[0] - 2 * b.inH[0] + b.p[0]))
    let ddy = max(abs(a.p[1] - 2 * a.outH[1] + b.inH[1]), abs(a.outH[1] - 2 * b.inH[1] + b.p[1]))
    let dd = sqrt(ddx * ddx + ddy * ddy)
    let steps = clamp(int(ceil(sqrt(0.75 * dd / tol))), 1, 1000)
    for t in 1 .. steps:
      let u = t / steps
      let mu = 1 - u
      let p = (mu * mu * mu * a.p[0] + 3 * mu * mu * u * a.outH[0] + 3 * mu * u * u * b.inH[0] + u * u * u * b.p[0],
               mu * mu * mu * a.p[1] + 3 * mu * mu * u * a.outH[1] + 3 * mu * u * u * b.inH[1] + u * u * u * b.p[1])
      if p != result[^1]: result.add p
  if s.closed and result.len > 1 and result[^1] == result[0]: result.setLen(result.len - 1)

type
  Edge = array[4, float32]           # x0, y0, x1, y1

  Component = object
    op: PathOp
    edges: seq[Edge]

proc addPoly(edges: var seq[Edge]; pts: openArray[Pt]) =
  if pts.len < 3: return
  for i in 0 ..< pts.len:
    let a = pts[i]
    let b = pts[(i + 1) mod pts.len]
    if a[1] != b[1]: edges.add [a[0].float32, a[1].float32, b[0].float32, b[1].float32]

proc components(p: Path): seq[Component] =
  ## The subpaths as the parts that are combined (a part: a subpath and
  ## those joined to it).
  for s in p.subs:
    let poly = flat(s)
    if result.len == 0 or not s.joined:
      result.add Component(op: (if result.len == 0 and s.op == poIntersect: poAdd else: s.op))
    result[^1].edges.addPoly(poly)

# ---- strokes --------------------------------------------------------------------------------------------

proc area(pts: openArray[Pt]): float =
  for i in 0 ..< pts.len:
    let a = pts[i]
    let b = pts[(i + 1) mod pts.len]
    result += a[0] * b[1] - b[0] * a[1]

proc addConvex(edges: var seq[Edge]; pts: seq[Pt]) =
  ## A convex polygon, turned the one way (so that overlaps make a union).
  if pts.len < 3: return
  if area(pts) < 0:
    var r = pts
    for i in 0 ..< pts.len: r[i] = pts[pts.high - i]
    edges.addPoly(r)
  else: edges.addPoly(pts)

proc circle(c: Pt; r: float): seq[Pt] =
  let n = clamp(int(ceil(r * 1.2)) + 8, 8, 256)
  for i in 0 ..< n:
    let a = i.float * 2 * PI / n.float
    result.add (c[0] + cos(a) * r, c[1] + sin(a) * r)

proc strokeEdges(poly: seq[Pt]; closed: bool; r: float; cap: LineCap; join: LineJoin;
                 edges: var seq[Edge]) =
  ## The outline of a line `r` from each side of `poly`.
  let n = poly.len
  if n == 0: return
  if n == 1:
    if cap == lcRound: edges.addConvex(circle(poly[0], r))
    elif cap == lcSquare:
      let p = poly[0]
      edges.addConvex(@[(p[0] - r, p[1] - r), (p[0] + r, p[1] - r), (p[0] + r, p[1] + r), (p[0] - r, p[1] + r)])
    return
  let segs = if closed: n else: n - 1
  proc dirOf(k: int): Pt =
    let a = poly[k]
    let b = poly[(k + 1) mod n]
    let dx = b[0] - a[0]
    let dy = b[1] - a[1]
    let l = max(1e-12, sqrt(dx * dx + dy * dy))
    (dx / l, dy / l)
  for k in 0 ..< segs:
    let a = poly[k]
    let b = poly[(k + 1) mod n]
    let u = dirOf(k)
    let nn = (-u[1] * r, u[0] * r)
    var a0 = a
    var b0 = b
    if not closed and cap == lcSquare:
      if k == 0: a0 = (a[0] - u[0] * r, a[1] - u[1] * r)
      if k == segs - 1: b0 = (b[0] + u[0] * r, b[1] + u[1] * r)
    edges.addConvex(@[(a0[0] + nn[0], a0[1] + nn[1]), (b0[0] + nn[0], b0[1] + nn[1]),
                      (b0[0] - nn[0], b0[1] - nn[1]), (a0[0] - nn[0], a0[1] - nn[1])])
  # the joins
  let first = if closed: 0 else: 1
  let last = if closed: n - 1 else: n - 2
  for k in first .. last:
    let p = poly[k]
    let d1 = dirOf((k - 1 + n) mod n)
    let d2 = dirOf(k)
    let cr = d1[0] * d2[1] - d1[1] * d2[0]
    let dt = d1[0] * d2[0] + d1[1] * d2[1]
    if abs(cr) < 1e-9 and dt > 0: continue              # (straight on)
    case join
    of ljRound: edges.addConvex(circle(p, r))
    of ljBevel, ljMiter:
      let s = if cr > 0: -1.0 else: 1.0                 # the outer side
      let n1 = (-d1[1] * r * s, d1[0] * r * s)
      let n2 = (-d2[1] * r * s, d2[0] * r * s)
      let e1 = (p[0] + n1[0], p[1] + n1[1])
      let e2 = (p[0] + n2[0], p[1] + n2[1])
      # (the miter: where the two outer edges meet, unless it reaches too far)
      let half = sqrt(max(0.0, (1 + dt) / 2))           # cos of half the turn between the normals
      if join == ljMiter and half > 0.25:
        let mx = (n1[0] + n2[0]) / 2
        let my = (n1[1] + n2[1]) / 2
        let ml = sqrt(mx * mx + my * my)
        if ml > 1e-9:
          let k2 = r / half / ml
          edges.addConvex(@[p, e1, (p[0] + mx * k2, p[1] + my * k2), e2])
          continue
      edges.addConvex(@[p, e1, e2])
  if not closed and cap == lcRound:
    edges.addConvex(circle(poly[0], r))
    edges.addConvex(circle(poly[^1], r))

proc varStrokePolys(poly: seq[Pt]; closed: bool; radii: seq[float]; cap: LineCap): seq[seq[Pt]] =
  ## The outline of a line whose half width at each point of `poly` is
  ## `radii`'s, as convex pieces that make it together: a trapezoid a
  ## piece of the line, round where it turns (a variable width, a
  ## calligraphic nib).
  let n = poly.len
  if n == 0 or radii.len != n: return
  if n == 1:
    result.add circle(poly[0], radii[0])
    return
  let segs = if closed: n else: n - 1
  var dirs = newSeq[Pt](segs)
  for k in 0 ..< segs:
    let a = poly[k]
    let b = poly[(k + 1) mod n]
    let dx = b[0] - a[0]
    let dy = b[1] - a[1]
    let l = max(1e-12, sqrt(dx * dx + dy * dy))
    dirs[k] = (dx / l, dy / l)
  for k in 0 ..< segs:
    let a = poly[k]
    let b = poly[(k + 1) mod n]
    let ra = radii[k]
    let rb = radii[(k + 1) mod n]
    let u = dirs[k]
    var a0 = a
    var b0 = b
    if not closed and cap == lcSquare:
      if k == 0: a0 = (a[0] - u[0] * ra, a[1] - u[1] * ra)
      if k == segs - 1: b0 = (b[0] + u[0] * rb, b[1] + u[1] * rb)
    result.add @[(a0[0] - u[1] * ra, a0[1] + u[0] * ra), (b0[0] - u[1] * rb, b0[1] + u[0] * rb),
                 (b0[0] + u[1] * rb, b0[1] - u[0] * rb), (a0[0] + u[1] * ra, a0[1] - u[0] * ra)]
  # (where it turns, a round join -- a straight run needs none)
  let first = if closed: 0 else: 1
  let last = if closed: n - 1 else: n - 2
  for k in first .. last:
    let d1 = dirs[(k - 1 + segs) mod segs]
    let d2 = dirs[k mod segs]
    if d1[0] * d2[0] + d1[1] * d2[1] < 0.9995 and radii[k] > 0.05: result.add circle(poly[k], radii[k])
  if not closed and cap == lcRound:
    if radii[0] > 0.05: result.add circle(poly[0], radii[0])
    if radii[^1] > 0.05: result.add circle(poly[^1], radii[^1])

proc strokeEdgesVar(poly: seq[Pt]; closed: bool; radii: seq[float]; cap: LineCap; edges: var seq[Edge]) =
  for q in varStrokePolys(poly, closed, radii, cap): edges.addConvex(q)

proc widthAt*(ws: seq[WidthPoint]; t: float): float =
  ## A width profile's width (times the stroke's) at `t` (0..1 along the
  ## subpath): between its points, in between; past its ends, as they are.
  if ws.len == 0: return 1
  var a = ws[0]
  if t <= a.t: return a.w
  for k in 1 .. ws.high:
    let b = ws[k]
    if t <= b.t:
      return if b.t - a.t <= 1e-9: b.w else: a.w + (b.w - a.w) * (t - a.t) / (b.t - a.t)
    a = b
  ws[^1].w

proc nibRadius*(b: StrokeBrush; r: float; dirX, dirY: float): float =
  ## A calligraphic nib's half width (`r`: half its size) across a line
  ## going (`dirX`, `dirY`): wide across its angle, thin along it.
  let al = degToRad(b.angle)
  let ro = clamp(b.roundness, 1.0, 100.0) / 100
  # (the ellipse's reach along the line's normal)
  let nx = -dirY
  let ny = dirX
  let u = nx * cos(al) + ny * sin(al)
  let v = -nx * sin(al) + ny * cos(al)
  r * sqrt(u * u + ro * ro * v * v)

proc strokeRadii(poly: seq[Pt]; closed: bool; r: float; s: ShapeData): seq[float] =
  ## (each point's half width: the width profile times the nib's)
  let n = poly.len
  result = newSeq[float](n)
  var lens = newSeq[float](n)
  for k in 1 ..< n:
    lens[k] = lens[k - 1] + hypot(poly[k][0] - poly[k - 1][0], poly[k][1] - poly[k - 1][1])
  let total = max(1e-9, lens[^1] + (if closed and n > 1: hypot(poly[0][0] - poly[^1][0], poly[0][1] - poly[^1][1]) else: 0.0))
  for k in 0 ..< n:
    var rr = r * (if s.widths.len > 0: widthAt(s.widths, lens[k] / total) else: 1.0)
    if s.brush.kind == sbCalligraphic and n > 1:
      # (the nib across the line here: the mean of the pieces either side)
      var dx, dy = 0.0
      for j in [k - 1, k]:
        let i0 = if closed: (j + n) mod n else: clamp(j, 0, n - 2)
        let i1 = if closed: (i0 + 1) mod n else: i0 + 1
        dx += poly[i1][0] - poly[i0][0]
        dy += poly[i1][1] - poly[i0][1]
      let l = max(1e-12, hypot(dx, dy))
      rr = nibRadius(s.brush, rr, dx / l, dy / l)
    result[k] = max(0.0, rr)

proc varStrokeOutline*(s: ShapeData): Path =
  ## A stroke of varying width (a width profile, a calligraphic nib) as an
  ## outline to fill: pieces turned the one way, so that filled with the
  ## non-zero rule they make it together (SVG, PDF).
  let r = s.strokeWidth / 2
  for sp in s.path.subs:
    let poly = flat(sp)
    if poly.len == 0: continue
    let closed = sp.closed and poly.len > 2
    for q in varStrokePolys(poly, closed, strokeRadii(poly, closed, r, s), s.cap):
      if q.len < 3: continue
      var pts = q
      if area(pts) < 0: pts.reverse()
      var o = SubPath(closed: true)
      for v in pts: o.pts.add PathPoint(p: v, inH: v, outH: v)
      result.subs.add o

proc dashed(poly: seq[Pt]; closed: bool; pattern: seq[float]): seq[seq[Pt]] =
  ## The pieces of `poly` that the dashes draw (`pattern`: dash, gap...).
  var total = 0.0
  for v in pattern: total += v
  if pattern.len == 0 or total <= 1e-6: return @[poly]
  var pts = poly
  if closed and pts.len > 0: pts.add pts[0]
  var idx = 0
  var left = max(1e-6, pattern[0])
  var on = true
  var cur: seq[Pt]
  if pts.len > 0: cur.add pts[0]
  var guard = 0
  for k in 0 ..< pts.len - 1:
    var a = pts[k]
    let b = pts[k + 1]
    var segLen = sqrt((b[0] - a[0]) ^ 2 + (b[1] - a[1]) ^ 2)
    while segLen > 1e-9:
      inc guard
      if guard > 200_000: return
      if left >= segLen:
        left -= segLen
        if on: cur.add b
        segLen = 0
      else:
        let t = left / segLen
        let m = (a[0] + (b[0] - a[0]) * t, a[1] + (b[1] - a[1]) * t)
        if on:
          cur.add m
          result.add cur
        cur = @[m]
        a = m
        segLen -= left
        on = not on
        idx = (idx + 1) mod pattern.len
        left = max(1e-6, pattern[idx])
  if on and cur.len > 1: result.add cur

# ---- drawing ----------------------------------------------------------------------------------------------

proc bandCoverage(r: var Raster; edges: openArray[Edge]; bx, by: float32) =
  r.clear()
  let y1 = by + r.h.float32
  for e in edges:
    if max(e[1], e[3]) <= by or min(e[1], e[3]) >= y1: continue
    r.edge(e[0] - bx, e[1] - by, e[2] - bx, e[3] - by)
  r.accumulate()

proc gradientT*(style: int; angle, scale: float; x, y: float; box: (float, float, float, float)): float =
  ## Where (`x`, `y`) is along a gradient laid across `box` (x0, y0, x1,
  ## y1): 0..1 (as Photoshop lays them: 0 Linear, 1 Radial, 2 Angle,
  ## 3 Reflected, 4 Diamond; `scale` 1 for 100 %).
  let bw = max(1.0, box[2] - box[0])
  let bh = max(1.0, box[3] - box[1])
  let ratio = floorMod(angle, 90.0)
  let sc = max(1e-6, scale * ((90 - ratio) / 90 * bw + ratio / 90 * bh))
  # (pixel by pixel from -1 to 1 across the box, the first and last on its
  # sides)
  let stepX = if bw > 1: 2 * bw / (bw - 1) else: 0.0
  let stepY = if bh > 1: 2 * bh / (bh - 1) else: 0.0
  let X = (-bw + (x - box[0]) * stepX) / sc
  let Y = (-bh + (y - box[1]) * stepY) / sc
  let th = degToRad(floorMod(angle, 360.0))
  let z = case style
          of 1: sqrt(X * X + Y * Y)
          of 2: floorMod(radToDeg(arctan2(Y, X)) + angle, 360.0) / 360
          of 3: abs(cos(th) * X - sin(th) * Y)
          of 4: abs(cos(th) * X - sin(th) * Y) + abs(sin(th) * X + cos(th) * Y)
          else: 0.5 * (cos(th) * X - sin(th) * Y + 1)
  clamp(z, 0.0, 1.0)

proc freeformAt*(points: openArray[tuple[x, y: float; color: uint32]]; u, v: float): uint32 =
  ## A freeform gradient's color at (`u`, `v`) of its box (0..1): its
  ## points' colors, each weighed by how near it is (the square of the
  ## distance, inverted): smooth between them, each point's own at it.
  if points.len == 0: return 0
  if points.len == 1: return points[0].color
  var a, r, g, b, wsum = 0.0
  for p in points:
    let d2 = (u - p.x) * (u - p.x) + (v - p.y) * (v - p.y)
    if d2 < 1e-10: return p.color
    let w = 1 / (d2 * d2)
    wsum += w
    a += w * float((p.color shr 24) and 255)
    r += w * float((p.color shr 16) and 255)
    g += w * float((p.color shr 8) and 255)
    b += w * float(p.color and 255)
  (uint32(a / wsum + 0.5) shl 24) or (uint32(r / wsum + 0.5) shl 16) or (uint32(g / wsum + 0.5) shl 8) or
    uint32(b / wsum + 0.5)

proc freeformPaint*(points: openArray[tuple[x, y: float; color: uint32]]): ShapePaint =
  ## A freeform gradient (Gradient Mesh's look): colors at points of the
  ## shape's box, blended smoothly.
  ShapePaint(kind: spGradient, style: 5, color: (if points.len > 0: points[0].color else: 0'u32),
             color2: (if points.len > 1: points[^1].color else: 0'u32), points: @points, opacity: 100)

const MeshRes = 256      # (a mesh's colors made once, on a grid this fine, then read between)

const MeshKeep = 16      # (the meshes' colors kept, the last made)

var
  meshSlots: array[MeshKeep, tuple[key: Hash; px: ptr UncheckedArray[uint32]]]
    ## (in a ring -- an array, not a seq: nothing frees it as the program ends, so
    ## what it points at is still held then, not lost)
  meshNext: int
  meshLock: Lock
initLock(meshLock)

proc meshRaster(pts: openArray[tuple[x, y: float; color: uint32]]; cols: int): seq[uint32] =
  ## (a gradient mesh's colors over its box, `MeshRes` square: each cell of points cut in small
  ## pieces, each piece's corners where the cell bends them, colored between its corners)
  let points = @pts
  let rows = points.len div max(1, cols)
  result = newSeq[uint32](MeshRes * MeshRes)
  if cols < 2 or rows < 2: return
  const sub = 10
  proc lerpC(a, b: uint32; t: float): array[4, float] =
    for k in 0 .. 3:
      let sh = 24 - 8 * k
      result[k] = float((a shr sh) and 255) * (1 - t) + float((b shr sh) and 255) * t
  proc node(r, c: int): tuple[x, y: float; col: array[4, float]] =
    let p = points[r * cols + c]
    (p.x, p.y, lerpC(p.color, p.color, 0))
  # (a point of a cell, s and t across it: where it is, its color)
  proc at(r, c: int; s, t: float): tuple[x, y: float; col: array[4, float]] =
    let a = node(r, c)
    let b = node(r, c + 1)
    let cc = node(r + 1, c)
    let d = node(r + 1, c + 1)
    result.x = (a.x * (1 - s) + b.x * s) * (1 - t) + (cc.x * (1 - s) + d.x * s) * t
    result.y = (a.y * (1 - s) + b.y * s) * (1 - t) + (cc.y * (1 - s) + d.y * s) * t
    for k in 0 .. 3:
      result.col[k] = (a.col[k] * (1 - s) + b.col[k] * s) * (1 - t) + (cc.col[k] * (1 - s) + d.col[k] * s) * t
  proc tri(buf: var seq[uint32]; p0, p1, p2: tuple[x, y: float; col: array[4, float]]) =
    let s = float(MeshRes - 1)
    let (x0, y0, x1, y1, x2, y2) = (p0.x * s, p0.y * s, p1.x * s, p1.y * s, p2.x * s, p2.y * s)
    let area = (x1 - x0) * (y2 - y0) - (x2 - x0) * (y1 - y0)
    if abs(area) < 1e-9: return
    let minX = max(0, int(floor(min(x0, min(x1, x2)))))
    let maxX = min(MeshRes - 1, int(ceil(max(x0, max(x1, x2)))))
    let minY = max(0, int(floor(min(y0, min(y1, y2)))))
    let maxY = min(MeshRes - 1, int(ceil(max(y0, max(y1, y2)))))
    for py in minY .. maxY:
      for qx in minX .. maxX:
        let (fx, fy) = (qx.float, py.float)
        let w0 = ((x1 - fx) * (y2 - fy) - (x2 - fx) * (y1 - fy)) / area
        let w1 = ((x2 - fx) * (y0 - fy) - (x0 - fx) * (y2 - fy)) / area
        let w2 = 1 - w0 - w1
        if w0 < -0.02 or w1 < -0.02 or w2 < -0.02: continue
        var c = 0'u32
        for k in 0 .. 3:
          let v = clamp(p0.col[k] * w0 + p1.col[k] * w1 + p2.col[k] * w2, 0.0, 255.0)
          c = c or (uint32(v + 0.5) shl (24 - 8 * k))
        buf[py * MeshRes + qx] = c
  for r in 0 ..< rows - 1:
    for c in 0 ..< cols - 1:
      for i in 0 ..< sub:
        for j in 0 ..< sub:
          let s0 = i / sub
          let s1 = (i + 1) / sub
          let t0 = j / sub
          let t1 = (j + 1) / sub
          let a = at(r, c, s0, t0)
          let b = at(r, c, s1, t0)
          let cc = at(r, c, s0, t1)
          let d = at(r, c, s1, t1)
          tri(result, a, b, d)
          tri(result, a, d, cc)

proc meshKey(points: openArray[tuple[x, y: float; color: uint32]]; cols: int): Hash =
  result = hash(cols)
  for p in points: result = result !& hash(p.x) !& hash(p.y) !& hash(p.color)
  result = !$result

proc meshRasterOf(points: openArray[tuple[x, y: float; color: uint32]]; cols: int): ptr UncheckedArray[uint32] =
  ## (the mesh's colors, made once and kept -- the last `MeshKeep` -- for every pixel to read; a
  ## shape drawn on another thread at the same time waits its turn here)
  let h = meshKey(points, cols)
  {.cast(gcsafe).}:
    acquire(meshLock)
    try:
      for e in meshSlots:
        if e.px != nil and e.key == h: result = e.px
      if result == nil:
        result = cast[ptr UncheckedArray[uint32]](allocShared(MeshRes * MeshRes * 4))
        let r = meshRaster(points, cols)
        copyMem(result, unsafeAddr r[0], MeshRes * MeshRes * 4)
        # (the oldest let go: no shape of it is being drawn by now -- 16 made since)
        if meshSlots[meshNext].px != nil: deallocShared(meshSlots[meshNext].px)
        meshSlots[meshNext] = (h, result)
        meshNext = (meshNext + 1) mod MeshKeep
    finally: release(meshLock)

proc diffusionRaster(pts: openArray[tuple[x, y: float; color: uint32]]): seq[uint32] =
  ## (a freeform gradient's colors spread as heat does, `MeshRes` square: each point a small round
  ## spot held at its color, the rest the mean of its neighbours -- Laplace's equation -- worked out
  ## on a coarse grid first, then on each finer one from it)
  {.push checks: off.}
  result = newSeq[uint32](MeshRes * MeshRes)
  if pts.len == 0: return
  var n = 8
  # (the four channels side by side, a cell's four together)
  var g = newSeq[float32](n * n * 4)
  var mean: array[4, float32]
  for p in pts:
    for c in 0 .. 3: mean[c] += float32((p.color shr (24 - 8 * c)) and 255) / float32(pts.len)
  for i in 0 ..< n * n:
    for c in 0 .. 3: g[i * 4 + c] = mean[c]
  while true:
    # (the points held: a spot round each, at this grid's size)
    var held = newSeq[int16](n * n)
    for v in held.mitems: v = -1
    let rr = max(1.0, 3.0 * float(n) / float(MeshRes))
    for k, p in pts:
      let (px, py) = (p.x * float(n - 1), p.y * float(n - 1))
      for y in max(0, int(py - rr)) .. min(n - 1, int(py + rr) + 1):
        for x in max(0, int(px - rr)) .. min(n - 1, int(px + rr) + 1):
          if (x.float - px) ^ 2 + (y.float - py) ^ 2 <= rr * rr or (x == int(px + 0.5) and y == int(py + 0.5)):
            held[y * n + x] = int16(k)
    for i in 0 ..< n * n:
      if held[i] >= 0:
        for c in 0 .. 3: g[i * 4 + c] = float32((pts[held[i]].color shr (24 - 8 * c)) and 255)
    # (red-black Gauss-Seidel, over-relaxed; an edge takes its inside neighbour for the one past it)
    let gp = cast[ptr UncheckedArray[float32]](addr g[0])
    let hp = cast[ptr UncheckedArray[int16]](addr held[0])
    let iters = if n <= 16: 100 elif n <= 64: 40 elif n <= 128: 16 else: 8
    for it in 0 ..< iters:
      for parity in 0 .. 1:
        for y in 0 ..< n:
          let up = if y > 0: -n else: n
          let dn = if y < n - 1: n else: -n
          var x = (y + parity) and 1
          while x < n:
            let i = y * n + x
            if hp[i] < 0:
              let lf = if x > 0: -1 else: 1
              let rt = if x < n - 1: 1 else: -1
              let (a, b, u, d) = ((i + lf) * 4, (i + rt) * 4, (i + up) * 4, (i + dn) * 4)
              let o = i * 4
              for c in 0 .. 3:
                let avg = (gp[a + c] + gp[b + c] + gp[u + c] + gp[d + c]) * 0.25'f32
                gp[o + c] = gp[o + c] + 1.85'f32 * (avg - gp[o + c])
            x += 2
    if n >= MeshRes: break
    # (to the next grid, twice as fine: the values read between)
    let m = min(MeshRes, n * 2)
    var f = newSeq[float32](m * m * 4)
    for y in 0 ..< m:
      let sy = y.float * float(n - 1) / float(m - 1)
      let y0 = min(int(sy), n - 2)
      let ty = float32(sy - y0.float)
      for x in 0 ..< m:
        let sx = x.float * float(n - 1) / float(m - 1)
        let x0 = min(int(sx), n - 2)
        let tx = float32(sx - x0.float)
        let (i00, i01) = ((y0 * n + x0) * 4, (y0 * n + x0 + 1) * 4)
        let (i10, i11) = (((y0 + 1) * n + x0) * 4, ((y0 + 1) * n + x0 + 1) * 4)
        for c in 0 .. 3:
          let a = g[i00 + c] + (g[i01 + c] - g[i00 + c]) * tx
          let b = g[i10 + c] + (g[i11 + c] - g[i10 + c]) * tx
          f[(y * m + x) * 4 + c] = a + (b - a) * ty
    g = move f
    n = m
  for i in 0 ..< MeshRes * MeshRes:
    var v: uint32
    for c in 0 .. 3: v = v or (uint32(clamp(g[i * 4 + c], 0'f32, 255'f32) + 0.5) shl (24 - 8 * c))
    result[i] = v
  {.pop.}

proc diffusionRasterOf(points: openArray[tuple[x, y: float; color: uint32]]): ptr UncheckedArray[uint32] =
  ## (as `meshRasterOf`, for a freeform gradient spread by diffusion)
  let h = !$(meshKey(points, -1) !& 7919)
  {.cast(gcsafe).}:
    acquire(meshLock)
    try:
      for e in meshSlots:
        if e.px != nil and e.key == h: result = e.px
      if result == nil:
        result = cast[ptr UncheckedArray[uint32]](allocShared(MeshRes * MeshRes * 4))
        let r = diffusionRaster(points)
        copyMem(result, unsafeAddr r[0], MeshRes * MeshRes * 4)
        if meshSlots[meshNext].px != nil: deallocShared(meshSlots[meshNext].px)
        meshSlots[meshNext] = (h, result)
        meshNext = (meshNext + 1) mod MeshKeep
    finally: release(meshLock)

proc gridAt(px: ptr UncheckedArray[uint32]; u, v: float): uint32 =
  ## (a `MeshRes` grid's color at (u, v), read between its cells)
  let fx = clamp(u, 0.0, 1.0) * float(MeshRes - 1)
  let fy = clamp(v, 0.0, 1.0) * float(MeshRes - 1)
  let x0 = min(int(fx), MeshRes - 2)
  let y0 = min(int(fy), MeshRes - 2)
  let tx = fx - x0.float
  let ty = fy - y0.float
  for c in 0 .. 3:
    let sh = 24 - 8 * c
    proc ch(x, y: int): float = float((px[y * MeshRes + x] shr sh) and 255)
    let a = ch(x0, y0) + (ch(x0 + 1, y0) - ch(x0, y0)) * tx
    let b = ch(x0, y0 + 1) + (ch(x0 + 1, y0 + 1) - ch(x0, y0 + 1)) * tx
    result = result or (uint32(a + (b - a) * ty + 0.5) shl sh)

proc freeformDiffusedAt*(points: openArray[tuple[x, y: float; color: uint32]]; u, v: float): uint32 =
  ## A freeform gradient's color at (`u`, `v`) of its box (0..1), its points' colors spread from
  ## them as heat does (Diffusion: smooth all over) -- `freeformAt`'s other way.
  if points.len == 0: return 0
  if points.len == 1: return points[0].color
  gridAt(diffusionRasterOf(points), u, v)

proc freeformColor*(p: ShapePaint; u, v: float): uint32 =
  ## A freeform gradient's color at (`u`, `v`) of its box (0..1), by the way it spreads (`diffuse`).
  if p.diffuse: freeformDiffusedAt(p.points, u, v) else: freeformAt(p.points, u, v)

proc meshAt*(points: openArray[tuple[x, y: float; color: uint32]]; cols: int; u, v: float): uint32 =
  ## A gradient mesh's color at (`u`, `v`) of its box (0..1): its grid of points, `cols` a row,
  ## each with its color, the colors between them bent where the points were moved.
  let px = meshRasterOf(points, cols)
  let x = clamp(int(u * float(MeshRes - 1) + 0.5), 0, MeshRes - 1)
  let y = clamp(int(v * float(MeshRes - 1) + 0.5), 0, MeshRes - 1)
  px[y * MeshRes + x]

proc meshPaint*(cols, rows: int; colors: openArray[uint32] = []): ShapePaint =
  ## A gradient mesh of `cols` x `rows` cells, its points even over the box (to be moved), each
  ## a color of `colors` in turn (none: white, the corners of a light blue).
  let nc = clamp(cols, 1, 15) + 1
  let nr = clamp(rows, 1, 15) + 1
  result = ShapePaint(kind: spGradient, style: 6, meshCols: nc, opacity: 100)
  for r in 0 ..< nr:
    for c in 0 ..< nc:
      let k = r * nc + c
      let col = if colors.len > 0: colors[k mod colors.len]
                elif (r == 0 or r == nr - 1) and (c == 0 or c == nc - 1): 0xFF8EC5FF'u32
                else: 0xFFFFFFFF'u32
      result.points.add (c / (nc - 1), r / (nr - 1), col)
  result.color = result.points[0].color
  result.color2 = result.points[^1].color

proc stopsColor*(stops: openArray[GradientStop]; t: float): uint32 =
  ## The color at `t` of a gradient through `stops` (in order).
  gradientColor(stops, t)

proc gradientAtT(p: ShapePaint; t0, x, y: float): uint32

proc paintAt(p: ShapePaint; x, y: float; box: (float, float, float, float);
             mesh: ptr UncheckedArray[uint32] = nil): uint32 {.inline.} =
  case p.kind
  of spPattern:
    if p.pw <= 0 or p.ph <= 0 or p.pattern.len != p.pw * p.ph: return 0
    let sc = (if p.scale <= 0: 100 else: p.scale).float / 100
    let tx = floorMod(int(floor(x / sc)), p.pw)
    let ty = floorMod(int(floor(y / sc)), p.ph)
    p.pattern[ty * p.pw + tx]
  of spGradient:
    if p.style == 5 and p.points.len > 0:
      let (u, v) = ((x - box[0]) / max(1.0, box[2] - box[0]), (y - box[1]) / max(1.0, box[3] - box[1]))
      if p.diffuse and p.points.len > 1:
        return gridAt(if mesh != nil: mesh else: diffusionRasterOf(p.points), u, v)
      return freeformAt(p.points, u, v)
    if p.style == 6 and p.meshCols >= 2 and p.points.len >= 4:
      let u = (x - box[0]) / max(1.0, box[2] - box[0])
      let v = (y - box[1]) / max(1.0, box[3] - box[1])
      if mesh == nil: return meshAt(p.points, p.meshCols, u, v)
      let mx = clamp(int(u * float(MeshRes - 1) + 0.5), 0, MeshRes - 1)
      let my = clamp(int(v * float(MeshRes - 1) + 0.5), 0, MeshRes - 1)
      return mesh[my * MeshRes + mx]
    let t = gradientT(p.style, p.angle.float, (if p.scale <= 0: 1.0 else: p.scale / 100), x, y, box)
    gradientAtT(p, t, x, y)
  else: p.color

proc gradientAtT(p: ShapePaint; t0, x, y: float): uint32 =
  ## (a gradient's color `t0` of the way along it, dithered at pixel `x, y`)
  block:
    var t = t0
    if p.reverse: t = 1 - t
    # (dithered: the color worked out between levels, then rounded up or down by a pattern that
    # stays put -- a smooth gradient, no bands)
    let f = if p.stops.len > 0: gradientColorF(p.stops, t)
            else:
              block:
                let c0 = p.color
                let c1 = p.color2
                template ch(c: uint32; sh: int): float32 = float32((c shr sh) and 255) / 255
                let u = float32(t)
                [ch(c0, 16) + (ch(c1, 16) - ch(c0, 16)) * u, ch(c0, 8) + (ch(c1, 8) - ch(c0, 8)) * u,
                 ch(c0, 0) + (ch(c1, 0) - ch(c0, 0)) * u, ch(c0, 24) + (ch(c1, 24) - ch(c0, 24)) * u]
    let ix = int(floor(x)) and 3
    let iy = int(floor(y)) and 3
    const bayer = [0'f32, 8, 2, 10, 12, 4, 14, 6, 3, 11, 1, 9, 15, 7, 13, 5]
    let dth = (bayer[iy * 4 + ix] + 0.5'f32) / 16 - 0.5'f32
    template q(v: float32): uint32 = uint32(clamp(int(floor(v * 255 + 0.5'f32 + dth)), 0, 255))
    (q(f[3]) shl 24) or (q(f[0]) shl 16) or (q(f[1]) shl 8) or q(f[2])

type StrokeParams = object
  ## (a stroke's paths flattened, for a gradient along or across it: each piece, how far along
  ## its path it begins, how long that path is; a grid of the pieces near each cell)
  segs: seq[tuple[ax, ay, bx, by, s0, len: float32]]
  cell: float32
  gx, gy, gw, gh: int
  grid: seq[seq[int32]]

proc strokeParams(polys: seq[tuple[pts: seq[(float, float)]; closed: bool]]; reach: float): StrokeParams =
  var x0, y0 = 1e18
  var x1, y1 = -1e18
  for (pts, closed) in polys:
    var total = 0.0
    let n = pts.len
    let m = if closed: n else: n - 1
    for i in 0 ..< m:
      let a = pts[i]
      let b = pts[(i + 1) mod n]
      total += hypot(b[0] - a[0], b[1] - a[1])
    var at = 0.0
    for i in 0 ..< m:
      let a = pts[i]
      let b = pts[(i + 1) mod n]
      let l = hypot(b[0] - a[0], b[1] - a[1])
      result.segs.add (a[0].float32, a[1].float32, b[0].float32, b[1].float32, at.float32, max(1e-6, total).float32)
      at += l
      x0 = min(x0, min(a[0], b[0])); y0 = min(y0, min(a[1], b[1]))
      x1 = max(x1, max(a[0], b[0])); y1 = max(y1, max(a[1], b[1]))
  if result.segs.len == 0: return
  result.cell = float32(max(8.0, reach))
  result.gx = int(floor((x0 - reach) / result.cell.float))
  result.gy = int(floor((y0 - reach) / result.cell.float))
  result.gw = min(4096, int(floor((x1 + reach) / result.cell.float)) - result.gx + 1)
  result.gh = min(4096, int(floor((y1 + reach) / result.cell.float)) - result.gy + 1)
  result.grid = newSeq[seq[int32]](result.gw * result.gh)
  for k, sg in result.segs:
    let cx0 = clamp(int(floor((min(sg.ax, sg.bx) - reach) / result.cell)) - result.gx, 0, result.gw - 1)
    let cx1 = clamp(int(floor((max(sg.ax, sg.bx) + reach) / result.cell)) - result.gx, 0, result.gw - 1)
    let cy0 = clamp(int(floor((min(sg.ay, sg.by) - reach) / result.cell)) - result.gy, 0, result.gh - 1)
    let cy1 = clamp(int(floor((max(sg.ay, sg.by) + reach) / result.cell)) - result.gy, 0, result.gh - 1)
    for cy in cy0 .. cy1:
      for cx in cx0 .. cx1: result.grid[cy * result.gw + cx].add int32(k)

proc strokeAt(sp: ptr StrokeParams; x, y: float32): tuple[along, side: float32] =
  ## (where pixel `x, y` is on the stroke: how far along its path, 0..1, and how far to the right
  ## of it -- negative: the left --, pixels)
  if sp.segs.len == 0: return
  let cx = int(floor(x / sp.cell)) - sp.gx
  let cy = int(floor(y / sp.cell)) - sp.gy
  if cx < 0 or cy < 0 or cx >= sp.gw or cy >= sp.gh: return
  var best = 1e30'f32
  for k in sp.grid[cy * sp.gw + cx]:
    let sg = sp.segs[k]
    let dx = sg.bx - sg.ax
    let dy = sg.by - sg.ay
    let l2 = dx * dx + dy * dy
    var t = if l2 > 0: ((x - sg.ax) * dx + (y - sg.ay) * dy) / l2 else: 0'f32
    t = clamp(t, 0'f32, 1'f32)
    let px = sg.ax + dx * t
    let py = sg.ay + dy * t
    let d2 = (x - px) * (x - px) + (y - py) * (y - py)
    if d2 < best:
      best = d2
      let l = sqrt(l2)
      result.along = (sg.s0 + t * l) / sg.len
      # (to the right of the way it goes: y is down)
      let cr = dx * (y - sg.ay) - dy * (x - sg.ax)
      result.side = (if cr >= 0: 1'f32 else: -1'f32) * sqrt(d2)

proc hasEnds*(s: ShapeData): bool = s.startEnd != leNone or s.endEnd != leNone
  ## The shape's open lines have arrowheads (or other ends).

proc endSize(s: ShapeData): (float, float) =
  ## (an end's width and length, in pixels)
  let w = max(0.5, s.strokeWidth)
  (max(10.0, (if s.endW > 0: s.endW else: 4.0) * w), max(10.0, (if s.endL > 0: s.endL else: 4.0) * w))

proc lineEnds*(poly: seq[Pt]; s: ShapeData): tuple[line: seq[Pt]; polys: seq[seq[Pt]]] =
  ## An open line (`poly`) with the shape's ends: the line cut back where an
  ## arrowhead covers it, and the ends as convex polygons (counterclockwise).
  result.line = poly
  if poly.len < 2 or not s.hasEnds: return
  var total = 0.0
  for i in 1 ..< poly.len: total += hypot(poly[i][0] - poly[i - 1][0], poly[i][1] - poly[i - 1][1])
  if total < 1e-6: return
  let (ew, el) = endSize(s)
  let hw = max(0.25, s.strokeWidth / 2)
  proc ccw(q: seq[Pt]): seq[Pt] =
    var a = 0.0
    for i in 0 ..< q.len:
      let p0 = q[i]
      let p1 = q[(i + 1) mod q.len]
      a += p0[0] * p1[1] - p1[0] * p0[1]
    if a < 0:
      for i in countdown(q.high, 0): result.add q[i]
    else: result = q
  proc pointBack(pts: seq[Pt]; dist: float): Pt =
    ## (the point `dist` along the line from its first point)
    var left = dist
    for i in 1 ..< pts.len:
      let a = pts[i - 1]
      let b = pts[i]
      let l = hypot(b[0] - a[0], b[1] - a[1])
      if l >= left and l > 0: return (a[0] + (b[0] - a[0]) * left / l, a[1] + (b[1] - a[1]) * left / l)
      left -= l
    pts[^1]
  proc cut(pts: seq[Pt]; dist: float): seq[Pt] =
    ## (the line without its first `dist`)
    if dist <= 0: return pts
    var left = dist
    for i in 1 ..< pts.len:
      let a = pts[i - 1]
      let b = pts[i]
      let l = hypot(b[0] - a[0], b[1] - a[1])
      if l > left:
        result.add (a[0] + (b[0] - a[0]) * left / l, a[1] + (b[1] - a[1]) * left / l)
        for j in i ..< pts.len: result.add pts[j]
        return
      left -= l
    @[pts[^1]]
  var line = poly
  for atEnd in [false, true]:
    let e = if atEnd: s.endEnd else: s.startEnd
    if e == leNone: continue
    var pts = line
    if atEnd:
      pts.setLen(0)
      for i in countdown(line.high, 0): pts.add line[i]
    # (its direction: from a little way along -- a curve's arrow follows it)
    let p = pts[0]
    let q = pointBack(pts, min(el, total / 2))
    var ux = p[0] - q[0]
    var uy = p[1] - q[1]
    let ul = hypot(ux, uy)
    if ul < 1e-9: continue
    ux /= ul
    uy /= ul
    let nx = -uy
    let ny = ux
    proc at(along, across: float): Pt = (p[0] + ux * along + nx * across, p[1] + uy * along + ny * across)
    var trim = 0.0
    case e
    of leArrow:
      result.polys.add ccw(@[p, at(-el, ew / 2), at(-el, -ew / 2)])
      trim = el / 2
    of leStealth:
      let notch = at(-el * 0.6, 0)
      result.polys.add ccw(@[p, at(-el, ew / 2), notch])
      result.polys.add ccw(@[p, notch, at(-el, -ew / 2)])
      trim = el * 0.4
    of leOpenArrow:
      for side in [1.0, -1.0]:
        let a = at(-el, side * ew / 2)
        var dx = p[0] - a[0]
        var dy = p[1] - a[1]
        let dl = max(1e-9, hypot(dx, dy))
        dx /= dl
        dy /= dl
        # (its outer side: away from the line)
        var ox = -dy
        var oy = dx
        if ox * nx + oy * ny < 0 == (side > 0):
          ox = -ox
          oy = -oy
        result.polys.add ccw(@[(a[0] + ox * hw, a[1] + oy * hw), (p[0] + ox * hw, p[1] + oy * hw),
                               (p[0] - ox * hw, p[1] - oy * hw), (a[0] - ox * hw, a[1] - oy * hw)])
      # (the point: mitred -- the arms' outer sides meet on the line, as far
      # as four times the half width)
      let hh = max(1e-9, hypot(el, ew / 2))
      let m = min(hw * hh / max(ew / 2, 1e-6), 4 * hw)
      result.polys.add ccw(@[at(hw * (ew / 2) / hh, -hw * el / hh), p,
                             at(hw * (ew / 2) / hh, hw * el / hh), at(m, 0)])
      trim = hw
    of leCircle:
      let r = ew / 2
      let n = clamp(int(ceil(r * 1.2)) + 8, 8, 256)
      var c: seq[Pt]
      for i in 0 ..< n:
        let a = i.float * 2 * PI / n.float
        c.add (p[0] + cos(a) * r, p[1] + sin(a) * r)
      result.polys.add ccw(c)
    of leSquare:
      result.polys.add ccw(@[at(ew / 2, ew / 2), at(-ew / 2, ew / 2), at(-ew / 2, -ew / 2), at(ew / 2, -ew / 2)])
    of leDiamond:
      result.polys.add ccw(@[at(ew / 2, 0), at(0, ew / 2), at(-ew / 2, 0), at(0, -ew / 2)])
    of leBar:
      result.polys.add ccw(@[at(hw, ew / 2), at(-hw, ew / 2), at(-hw, -ew / 2), at(hw, -ew / 2)])
    of leNone: discard
    # (the line stops inside its arrowhead: no butt end past the point)
    trim = min(trim, total * (if s.startEnd != leNone and s.endEnd != leNone: 0.45 else: 0.9))
    var cutPts = cut(pts, trim)
    if atEnd:
      line.setLen(0)
      for i in countdown(cutPts.high, 0): line.add cutPts[i]
    else: line = cutPts
  result.line = line

proc endsPath*(s: ShapeData): Path =
  ## The ends of the shape's open lines (arrowheads...) as an outline to fill
  ## in the stroke's color -- for files that keep outlines (SVG, EPS).
  if not s.hasEnds: return
  for sp in s.path.subs:
    if sp.closed: continue
    for q in lineEnds(flat(sp), s).polys:
      var o = SubPath(closed: true)
      for p in q: o.pts.add corner(p)
      result.subs.add o

proc trimmedPath*(s: ShapeData): Path =
  ## The shape's path with its open lines cut back where their arrowheads
  ## cover them (as `renderShape` strokes them).
  if not s.hasEnds: return s.path
  result.name = s.path.name
  for sp in s.path.subs:
    if sp.closed:
      result.subs.add sp
      continue
    var o = SubPath(op: sp.op, joined: sp.joined)
    for p in lineEnds(flat(sp), s).line: o.pts.add corner(p)
    result.subs.add o

proc reachOf(s: ShapeData): float =
  if s.stroke.kind == spNone or s.strokeWidth <= 0: return 0
  var w = s.strokeWidth
  for wp in s.widths: w = max(w, s.strokeWidth * wp.w)
  let mult = if s.join == ljMiter: 4.0 else: 1.0
  result = (if s.align == saCenter: w / 2 elif s.align == saOutside: w else: 0.0) * mult + w * 0.5
  if s.hasEnds:
    let (ew, el) = endSize(s)
    result = max(result, max(ew, el) + w)

proc shapeReach*(s: ShapeData): float = reachOf(s)
  ## How far past its path's points a shape draws (its stroke, a line's ends).

var
  liveEffectsHook*: proc (p: Path; es: seq[LiveEffect]): Path {.nimcall.}
    ## Does a shape's live effects to its path (set by `retroui/liveeffects`).
  brushOutlineHook*: proc (p: Path; b: StrokeBrush; width: float): Path {.nimcall.}
    ## The outline an Art, Pattern or Scatter brush draws along a path (set
    ## by `retroui/pathbrush`).
  threeDHook*: proc (s: ShapeData): seq[ShapeData] {.nimcall.}
    ## A shape's 3D as faces, back to front (set by `retroui/threed`).

proc translated*(p: Path; dx, dy: float): Path =
  ## The path moved by (`dx`, `dy`).
  result = p
  for sp in result.subs.mitems:
    for q in sp.pts.mitems:
      q.p = (q.p[0] + dx, q.p[1] + dy)
      q.inH = (q.inH[0] + dx, q.inH[1] + dy)
      q.outH = (q.outH[0] + dx, q.outH[1] + dy)

proc withEffects*(p: Path; es: seq[LiveEffect]): Path =
  ## The path as its live effects make it (as it is without any, or
  ## without `retroui/liveeffects`).
  var on = false
  for e in es:
    if not e.off: on = true
  if not on or liveEffectsHook == nil: p else: liveEffectsHook(p, es)

proc isStacked(s: ShapeData): bool =
  ## (drawn in parts: effects, an artwork brush, more fills and strokes, 3D)
  if s.appearance.len > 0 or s.brush.kind in {sbArt, sbPattern, sbScatter}: return true
  if s.threeD.kind != tdNone and threeDHook != nil: return true
  for e in s.effects:
    if not e.off: return true

proc expanded*(s: ShapeData): seq[tuple[shape: ShapeData; opacity: int; mode: BlendMode]] =
  ## What a shape draws, bottom first, each a plain shape (no effects, no
  ## artwork brush, no more fills or strokes): the Appearance panel's
  ## items under it, its own fill and stroke, the items over it. (Exports
  ## draw these; `renderShape` draws them.)
  var base = s
  base.appearance = @[]
  base.effects = @[]
  base.path = withEffects(s.path, s.effects)
  proc item(a: Appearance): ShapeData =
    result = ShapeData(path: withEffects(base.path, a.effects), cap: s.cap, join: s.join)
    if a.kind == apFill:
      result.fill = a.paint
      result.stroke = ShapePaint(kind: spNone)
    else:
      result.fill = ShapePaint(kind: spNone)
      result.stroke = a.paint
      result.strokeWidth = a.width
      result.align = a.align
  for a in s.appearance:
    if a.below and not a.off: result.add (item(a), clamp(a.opacity, 0, 100), a.mode)
  if base.threeD.kind != tdNone and threeDHook != nil:
    # (3D: its faces in place of its fill and stroke)
    for f in threeDHook(base): result.add (f, 100, bmNormal)
  elif base.brush.kind in {sbArt, sbPattern, sbScatter} and base.stroke.kind != spNone and base.strokeWidth > 0:
    # (an artwork brush: its outline filled with the stroke's paint, over the fill)
    var fillOnly = base
    fillOnly.stroke = ShapePaint(kind: spNone)
    fillOnly.brush = StrokeBrush()
    result.add (fillOnly, 100, bmNormal)
    if brushOutlineHook != nil:
      let o = brushOutlineHook(base.path, base.brush, base.strokeWidth)
      result.add (ShapeData(path: o, fill: base.stroke, stroke: ShapePaint(kind: spNone)), 100, bmNormal)
  else:
    result.add (base, 100, bmNormal)
  for a in s.appearance:
    if not a.below and not a.off: result.add (item(a), clamp(a.opacity, 0, 100), a.mode)

proc exportParts*(s: ShapeData): seq[tuple[shape: ShapeData; opacity: int; mode: BlendMode]] =
  ## What a shape draws, for a file that holds plain paths (SVG, PDF): its
  ## `expanded` parts, a stroke of varying width (a width profile, a
  ## calligraphic nib) made an outline filled with the stroke's paint.
  for (part, op, mode) in expanded(s):
    if part.stroke.kind != spNone and part.strokeWidth > 0 and (part.widths.len > 0 or part.brush.kind == sbCalligraphic):
      var fillOnly = part
      fillOnly.stroke = ShapePaint(kind: spNone)
      fillOnly.widths = @[]
      fillOnly.brush = StrokeBrush()
      if fillOnly.fill.kind != spNone: result.add (fillOnly, op, mode)
      result.add (ShapeData(path: varStrokeOutline(part), fill: part.stroke, stroke: ShapePaint(kind: spNone)), op, mode)
    else: result.add (part, op, mode)

proc isPlain*(s: ShapeData): bool =
  ## Nothing more than a fill and a stroke of one width (no effects, brush,
  ## width profile or more fills and strokes): a file's path holds it as it is.
  not s.isStacked and s.widths.len == 0 and s.brush.kind == sbNone

proc renderPlain(s: ShapeData; px: var seq[uint32]; w, h: int; clearFirst = Rect(); fillAll = false): DrawnBox

proc renderShape*(s: ShapeData; px: var seq[uint32]; w, h: int; clearFirst = Rect(); fillAll = false): DrawnBox =
  ## Draws the shape into `px` (`w` x `h`), over what is cleared there
  ## first (`clearFirst`), saying where it drew: its live effects, its
  ## brush and the Appearance panel's fills and strokes too.
  if not s.isStacked: return renderPlain(s, px, w, h, clearFirst, fillAll)
  if px.len != w * h: return
  let cl = intersect(clearFirst, rect(0, 0, w, h))
  if cl.w > 0 and cl.h > 0:
    let pp = cast[ptr UncheckedArray[uint32]](addr px[0])
    parallelRows(cl.h, yy):
      zeroMem(addr pp[(cl.y + yy) * w + cl.x], cl.w * 4)
  let parts = expanded(s)
  # (each part drawn into a picture of its own box, then laid over what is there)
  var all = (int.high, int.high, int.low, int.low)
  for (part, op, mode) in parts:
    let b0 = pathBounds(part.path)
    let reach = min(reachOf(part) + 2, 1e6)
    if b0[0] > b0[2] or b0[0] != b0[0]: continue
    let box = intersect(rect(int(floor(b0[0] - reach)), int(floor(b0[1] - reach)),
                             int(ceil(b0[2] + reach)) - int(floor(b0[0] - reach)),
                             int(ceil(b0[3] + reach)) - int(floor(b0[1] - reach))), rect(0, 0, w, h))
    if box.w <= 0 or box.h <= 0: continue
    var tmp = newSeq[uint32](box.w * box.h)
    var moved = part
    moved.path = translated(part.path, -box.x.float, -box.y.float)
    let drawn = renderPlain(moved, tmp, box.w, box.h, Rect(), fillAll)
    if drawn[2] <= drawn[0]: continue
    let a = op * 255 div 100
    let m = mode
    let tp = cast[ptr UncheckedArray[uint32]](addr tmp[0])
    let pp = cast[ptr UncheckedArray[uint32]](addr px[0])
    parallelRows(box.h, yy):
      let row = (box.y + yy) * w + box.x
      for xx in 0 ..< box.w:
        let c = tp[yy * box.w + xx]
        if c shr 24 == 0: continue
        pp[row + xx] = blendPx(pp[row + xx], c, a, m, box.x + xx, box.y + yy)
    all = (min(all[0], box.x + drawn[0]), min(all[1], box.y + drawn[1]), max(all[2], box.x + drawn[2]),
           max(all[3], box.y + drawn[3]))
  if all[0] > all[2]: return (0, 0, 0, 0)
  all

proc renderPlain(s: ShapeData; px: var seq[uint32]; w, h: int; clearFirst = Rect(); fillAll = false): DrawnBox =
  ## (one fill and one stroke: the shape as it was always drawn)
  if px.len != w * h: return
  let comps = components(s.path)
  proc tame(v: float): float = (if v != v: 0.0 else: clamp(v, -1e7, 1e7))  # (wild coordinates: kept to what an int holds)
  let b0 = pathBounds(s.path)
  let bb = (tame(b0[0]), tame(b0[1]), tame(b0[2]), tame(b0[3]))
  let reach = min(reachOf(s) + 2, 1e6)
  var box = rect(int(floor(bb[0] - reach)), int(floor(bb[1] - reach)), 0, 0)
  box.w = int(ceil(bb[2] + reach)) - box.x
  box.h = int(ceil(bb[3] + reach)) - box.y
  let wholeCanvas = fillAll or (comps.len > 0 and comps[0].op == poSubtract)
  if wholeCanvas: box = rect(0, 0, w, h)
  box = intersect(box, rect(0, 0, w, h))
  let cl = intersect(clearFirst, rect(0, 0, w, h))
  let pp = cast[ptr UncheckedArray[uint32]](addr px[0])
  if cl.w > 0 and cl.h > 0:
    parallelRows(cl.h, yy):
      zeroMem(addr pp[(cl.y + yy) * w + cl.x], cl.w * 4)
  if box.w <= 0 or box.h <= 0 or comps.len == 0: return (0, 0, 0, 0)
  # (a gradient mesh's colors made once, here: every pixel reads them)
  proc gridOf(p: ShapePaint): ptr UncheckedArray[uint32] =
    if p.kind != spGradient: nil
    elif p.style == 6 and p.meshCols >= 2 and p.points.len >= 4: meshRasterOf(p.points, p.meshCols)
    elif p.style == 5 and p.diffuse and p.points.len > 1: diffusionRasterOf(p.points)
    else: nil
  let fillMesh = gridOf(s.fill)
  let strokeMesh = gridOf(s.stroke)
  # the stroke's outline
  var strokeE: seq[Edge]
  let stroking = s.stroke.kind != spNone and s.strokeWidth > 0
  let closedOnly = block:
    var c = true
    for sp in s.path.subs:
      if not sp.closed: c = false
    c
  let align = if closedOnly: s.align else: saCenter
  if stroking:
    let r = if align == saCenter: s.strokeWidth / 2 else: s.strokeWidth
    for sp in s.path.subs:
      var poly = flat(sp)
      if poly.len == 0: continue
      let closed = sp.closed and poly.len > 2
      if not closed and s.hasEnds:
        # (a line's arrowheads, or other ends: in the stroke's color)
        let e = lineEnds(poly, s)
        poly = e.line
        for q in e.polys: strokeE.addConvex(q)
      if s.widths.len > 0 or s.brush.kind == sbCalligraphic:
        strokeEdgesVar(poly, closed, strokeRadii(poly, closed, r, s), s.cap, strokeE)
      elif s.dashes.len > 0:
        var pat: seq[float]
        for v in s.dashes: pat.add max(0.0, v) * s.strokeWidth
        for piece in dashed(poly, closed, pat): strokeEdges(piece, false, r, s.cap, s.join, strokeE)
      else: strokeEdges(poly, closed, r, s.cap, s.join, strokeE)
  # (a gradient along the stroke or across it: where each pixel is on it)
  let strokeGrad = stroking and s.stroke.kind == spGradient and s.stroke.onStroke in 1 .. 2 and
                   s.stroke.style notin 5 .. 6
  var sparams: StrokeParams
  if strokeGrad:
    var polys: seq[tuple[pts: seq[(float, float)]; closed: bool]]
    for sp in s.path.subs:
      let poly = flat(sp)
      if poly.len >= 2: polys.add (poly, sp.closed and poly.len > 2)
    sparams = strokeParams(polys, s.strokeWidth + 2)
  let spp = unsafeAddr sparams
  let across = s.stroke.onStroke == 2
  let sw0 = max(0.01, s.strokeWidth).float32
  let fillOp = (if s.fill.opacity <= 0: 100 else: s.fill.opacity).float / 100
  let strokeOp = (if s.stroke.opacity <= 0: 100 else: s.stroke.opacity).float / 100
  let filling = s.fill.kind != spNone
  # (a shape of several parts is stroked along the edge of what they make
  # together, measured from it; one part along its outline)
  let alongEdge = stroking and closedOnly and comps.len > 1
  let needFill = filling or (stroking and align != saCenter) or alongEdge
  const band = 32
  let nb = (box.h + band - 1) div band
  let compsP = unsafeAddr comps
  let strokeP = unsafeAddr strokeE
  let sP = unsafeAddr s
  template combineBand(rc: var Raster; acc: ptr UncheckedArray[float32]; count: int) =
    for ci, c in compsP[]:
      bandCoverage(rc, c.edges, box.x.float32, by.float32)
      for i in 0 ..< count:
        let p = rc[i]
        let m = acc[i]
        acc[i] = if ci == 0:
                   (if c.op == poSubtract: max(0'f32, 1 - p) else: p)
                 else:
                   case c.op
                   of poAdd: m + p - m * p
                   of poSubtract: max(0'f32, m - p)
                   of poIntersect: m * p
                   of poExclude: m + p - 2 * m * p
  template put(x, y: int; fcov, scov: float32) =
    let fa = if filling: fcov * fillOp else: 0.0
    let sa = scov * strokeOp
    if fa > 0.001 or sa > 0.001:
      let fc = if filling: paintAt(sP[].fill, x.float, y.float, bb, fillMesh) else: 0'u32
      if sa <= 0.001 and fa >= 0.999 and aOf(fc) == 255:
        pp[y * w + x] = fc
      else:
        var sc = 0'u32
        if stroking:
          if strokeGrad:
            let at = strokeAt(spp, x.float32 + 0.5, y.float32 + 0.5)
            let t = if not across: at.along
                    elif align == saCenter: clamp(0.5'f32 + at.side / sw0, 0'f32, 1'f32)
                    else: clamp(abs(at.side) / sw0, 0'f32, 1'f32)
            sc = gradientAtT(sP[].stroke, t.float, x.float, y.float)
          else: sc = paintAt(sP[].stroke, x.float, y.float, bb, strokeMesh)
        let fa2 = fa * aOf(fc).float / 255
        let sa2 = sa * aOf(sc).float / 255
        let oa = sa2 + fa2 * (1 - sa2)
        if oa > 0.001:
          let wf = fa2 * (1 - sa2) / oa
          let ws = sa2 / oa
          pp[y * w + x] = argb(clamp(int(round(oa * 255)), 0, 255),
                               clamp(int(round(rOf(fc).float * wf + rOf(sc).float * ws)), 0, 255),
                               clamp(int(round(gOf(fc).float * wf + gOf(sc).float * ws)), 0, 255),
                               clamp(int(round(bOf(fc).float * wf + bOf(sc).float * ws)), 0, 255))
  if alongEdge:
    var cov = newSeq[float32](box.w * box.h)
    let cp = cast[ptr UncheckedArray[float32]](addr cov[0])
    parallelChunks(nb, lo, hi):
      var rc = newRaster(box.w, band)
      for bi in lo ..< hi:
        let by = box.y + bi * band
        let bh = min(band, box.y + box.h - by)
        combineBand(rc, cast[ptr UncheckedArray[float32]](addr cp[bi * band * box.w]), box.w * bh)
    let sd = signedDistances(cov, box.w, box.h)
    let sdp = cast[ptr UncheckedArray[float32]](unsafeAddr sd[0])
    let sw = s.strokeWidth.float32
    let (lo, hi) = case align
                   of saInside: (-sw, 0'f32)
                   of saOutside: (0'f32, sw)
                   of saCenter: (-sw / 2, sw / 2)
    parallelRows(box.h, yy):
      let y = box.y + yy
      for xx in 0 ..< box.w:
        let i = yy * box.w + xx
        let d = sdp[i]
        let scov = clamp(min(d + 0.5'f32, hi) - max(d - 0.5'f32, lo), 0'f32, 1'f32)
        put(box.x + xx, y, cp[i], scov)
  else:
    parallelChunks(nb, lo, hi):
      var rc = newRaster(box.w, band)
      var acc = newSeq[float32](box.w * band)
      let ap = cast[ptr UncheckedArray[float32]](addr acc[0])
      var rs = newRaster(box.w, band)
      for bi in lo ..< hi:
        let by = box.y + bi * band
        let bh = min(band, box.y + box.h - by)
        if needFill: combineBand(rc, ap, box.w * bh)
        if stroking: bandCoverage(rs, strokeP[], box.x.float32, by.float32)
        for yy in 0 ..< bh:
          let y = by + yy
          for xx in 0 ..< box.w:
            let i = yy * box.w + xx
            let fcov = if needFill: ap[i] else: 0'f32
            var scov = if stroking: rs[i] else: 0'f32
            case align
            of saInside: scov = scov * fcov
            of saOutside: scov = scov * (1 - fcov)
            of saCenter: discard
            put(box.x + xx, y, fcov, scov)
  (box.x, box.y, box.x + box.w, box.y + box.h)

proc shapeMask*(p: Path; w, h: int; fillAll = false): seq[uint8] =
  ## How much of each pixel the path's shape covers (a vector mask),
  ## 0..255; `fillAll`: everything when the path is empty.
  result = newSeq[uint8](w * h)
  if p.subs.len == 0:
    if fillAll:
      for v in result.mitems: v = 255
    return
  var px = newSeq[uint32](w * h)
  discard renderShape(ShapeData(path: p, fill: solidPaint(0xFFFFFFFF'u32)), px, w, h)
  let rp = cast[ptr UncheckedArray[uint8]](addr result[0])
  let sp = cast[ptr UncheckedArray[uint32]](addr px[0])
  parallelFor(w * h, proc (lo, hi: int) =
    for i in lo ..< hi: rp[i] = uint8(sp[i] shr 24), grain = 65536)

proc drawShapeLayer(w, h: int; L: Layer): DrawnBox =
  let old = L.shapeArea
  if old.w > 0: return renderShape(L.shape, L.px, w, h, old)
  # (not drawn yet: cleared only where something is -- a new layer's memory, never written,
  # stays not taken; a layer just made is all zeros already)
  if not L.freshPixels: clearSet(L.px)
  renderShape(L.shape, L.px, w, h)

shapeRender = drawShapeLayer

proc addShapeLayer*(d: Doc; s: ShapeData; name = ""; above = -1): Layer =
  ## A new shape layer drawing `s` (named after what it is), the current
  ## one. (Undoable in a step: `touchLayers` first.)
  var n = 1
  for L in d.layers:
    if L.name.startsWith("Shape "):
      try: n = max(n, parseInt(L.name[6 .. ^1]) + 1)
      except ValueError: discard
  result = d.addLayer(if name.len > 0: name else: "Shape " & $n, above, fresh = true)
  result.shape = s
  if d.pixelAlign: alignToPixels(result.shape)
  d.drawShape(result)
  if above < 0: d.drawModePlace(result)

proc addFillLayer*(d: Doc; paint: ShapePaint; name = ""): Layer =
  ## Layer > New Fill Layer: a layer filled with a color, a gradient or a
  ## pattern (made again when it changes), its mask from the selection --
  ## above the current one. (Undoable in a step: `touchLayers` first.)
  let base = case paint.kind
             of spGradient: "Gradient Fill"
             of spPattern: "Pattern Fill"
             else: "Color Fill"
  var n = 1
  for L in d.layers:
    if L.name.startsWith(base & " "):
      try: n = max(n, parseInt(L.name[base.len + 1 .. ^1]) + 1)
      except ValueError: discard
  let hadSel = d.hasSelection
  result = d.addLayer(if name.len > 0: name else: base & " " & $n)
  result.shape = ShapeData(path: canvasPath(d.w, d.h), fill: paint, kind: "Fill")
  d.drawShape(result)
  if hadSel:
    d.addLayerMask(mfRevealSelection)

proc setFillPaint*(d: Doc; L: Layer; paint: ShapePaint) =
  ## A fill layer's color, gradient or pattern changed (undoable in a step:
  ## `touchLayers` first).
  if not L.isFill: return
  var s = L.shape
  s.fill = paint
  d.setShape(L, s)

proc strokeOutline*(s: ShapeData): Path =
  ## The outline of a shape's path as a path made of straight pieces
  ## (for selections: Make Selection).
  for sp in s.path.subs:
    let poly = flat(sp)
    var o = SubPath(closed: true, op: sp.op, joined: sp.joined)
    for p in poly: o.pts.add corner(p)
    if o.pts.len > 2: result.subs.add o
