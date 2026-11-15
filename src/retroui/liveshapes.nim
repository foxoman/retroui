## Shapes that keep their settings: arrows, chevrons, speech and thought
## bubbles, badges, ribbons, hearts, gears, polygons and stars, rectangles
## with each corner its own, crosses, rings, triangles, parallelograms,
## trapezoids, tags, pies -- each drawn in a box from a few numbers
## (`ShapeParams`) that can be changed again later, the shape drawn anew
## (a shape layer's path: `liveShapePath`). `paramsOf` says what each
## number is.
##
## ```nim
## var p = defaultParams(lsStar)       # 5 points, inner radius 50 %
## p.v[0] = 8                          # 8 points
## L.shape.path = liveShapePath(p, 100, 100, 300, 300)
## ```

import std/[math, json]
import photo

type
  LiveShape* = enum
    lsArrow = "Arrow", lsDoubleArrow = "Double Arrow", lsChevron = "Chevron", lsBubble = "Speech Bubble",
    lsCloud = "Thought Bubble", lsBadge = "Badge", lsRibbon = "Ribbon", lsHeart = "Heart", lsGear = "Gear",
    lsPolygon = "Polygon", lsStar = "Star", lsRoundRect = "Rectangle, Corners Apart", lsCross = "Cross",
    lsRing = "Ring", lsTriangle = "Triangle", lsParallelogram = "Parallelogram", lsTrapezoid = "Trapezoid",
    lsTag = "Tag", lsPie = "Pie", lsBlob = "Blob"
  ShapeParams* = object
    ## A live shape: its kind and its numbers (`paramsOf` names them).
    kind*: LiveShape
    v*: array[4, float]

proc paramsOf*(k: LiveShape): seq[tuple[name: string; lo, hi, default: float]] =
  ## What a kind's numbers are, their range and where they start.
  case k
  of lsArrow, lsDoubleArrow: @[("Shaft width %", 5.0, 100.0, 40.0), ("Head length %", 5.0, 95.0, 35.0)]
  of lsChevron: @[("Depth %", 0.0, 95.0, 35.0)]
  of lsBubble: @[("Corners %", 0.0, 50.0, 18.0), ("Tail at %", 0.0, 100.0, 25.0),
                 ("Tail width %", 2.0, 60.0, 14.0), ("Tail length %", 5.0, 60.0, 22.0)]
  of lsCloud: @[("Bumps", 5.0, 24.0, 10.0), ("Bumps' depth %", 2.0, 40.0, 14.0)]
  of lsBadge: @[("Points", 6.0, 80.0, 24.0), ("Depth %", 1.0, 40.0, 10.0)]
  of lsRibbon: @[("Fold width %", 5.0, 40.0, 16.0), ("Notch %", 0.0, 100.0, 50.0), ("Fold drop %", 0.0, 50.0, 18.0)]
  of lsHeart: @[("Point %", 50.0, 100.0, 100.0)]
  of lsGear: @[("Teeth", 4.0, 60.0, 12.0), ("Tooth depth %", 3.0, 40.0, 16.0), ("Hole %", 0.0, 80.0, 30.0)]
  of lsPolygon: @[("Sides", 3.0, 24.0, 6.0), ("Roundness %", 0.0, 50.0, 0.0)]
  of lsStar: @[("Points", 3.0, 60.0, 5.0), ("Inner radius %", 5.0, 95.0, 45.0), ("Roundness %", 0.0, 50.0, 0.0)]
  of lsRoundRect: @[("Top left %", 0.0, 100.0, 30.0), ("Top right %", 0.0, 100.0, 0.0),
                    ("Bottom right %", 0.0, 100.0, 30.0), ("Bottom left %", 0.0, 100.0, 0.0)]
  of lsCross: @[("Arm thickness %", 5.0, 95.0, 34.0), ("Roundness %", 0.0, 50.0, 0.0)]
  of lsRing: @[("Thickness %", 2.0, 95.0, 30.0)]
  of lsTriangle: @[("Apex at %", 0.0, 100.0, 50.0), ("Roundness %", 0.0, 50.0, 0.0)]
  of lsParallelogram: @[("Slant %", -90.0, 90.0, 25.0), ("Roundness %", 0.0, 50.0, 0.0)]
  of lsTrapezoid: @[("Top width %", 0.0, 100.0, 60.0), ("Roundness %", 0.0, 50.0, 0.0)]
  of lsTag: @[("Point length %", 5.0, 60.0, 22.0), ("Hole %", 0.0, 30.0, 8.0), ("Corners %", 0.0, 40.0, 10.0)]
  of lsPie: @[("Start angle", -360.0, 360.0, 0.0), ("Sweep", 1.0, 360.0, 270.0), ("Hole %", 0.0, 95.0, 0.0)]
  of lsBlob: @[("Lobes", 3.0, 12.0, 5.0), ("Wobble %", 0.0, 60.0, 22.0), ("Seed", 0.0, 999.0, 7.0)]

proc defaultParams*(k: LiveShape): ShapeParams =
  ## A kind with its numbers where they start.
  result.kind = k
  for i, p in paramsOf(k): result.v[i] = p.default

proc toJson*(p: ShapeParams): JsonNode =
  ## (kept with its layer, to draw it again)
  %*{"live": $p.kind, "v": [p.v[0], p.v[1], p.v[2], p.v[3]]}

proc paramsFrom*(j: JsonNode): tuple[ok: bool; p: ShapeParams] =
  ## A live shape's settings back from `toJson` (`ok` false: not one).
  if j == nil or j.kind != JObject or not j.hasKey("live"): return
  for k in LiveShape:
    if $k == j["live"].getStr:
      result.ok = true
      result.p.kind = k
  if not result.ok: return
  let v = j{"v"}.getElems
  let ps = paramsOf(result.p.kind)
  for i in 0 ..< min(4, v.len):
    result.p.v[i] = if i < ps.len: clamp(v[i].getFloat, ps[i].lo, ps[i].hi) else: 0.0

# ---- building outlines ------------------------------------------------------------------------------------

type Pt = (float, float)

proc corner(p: Pt): PathPoint = PathPoint(p: p, inH: p, outH: p)

proc polySub(pts: openArray[Pt]; closed = true): SubPath =
  result = SubPath(closed: closed)
  for p in pts: result.pts.add corner(p)

proc roundedPoly(pts: openArray[Pt]; r: float): SubPath =
  ## (a closed polygon with its corners rounded by `r` pixels -- at most half of each side)
  if r <= 0.01 or pts.len < 3: return polySub(pts)
  result = SubPath(closed: true)
  let n = pts.len
  const k = 0.5523
  for i in 0 ..< n:
    let a = pts[(i + n - 1) mod n]
    let p = pts[i]
    let b = pts[(i + 1) mod n]
    let la = hypot(a[0] - p[0], a[1] - p[1])
    let lb = hypot(b[0] - p[0], b[1] - p[1])
    let rr = min(r, min(la, lb) / 2)
    if rr <= 0.01 or la < 1e-9 or lb < 1e-9:
      result.pts.add corner(p)
      continue
    let s = (p[0] + (a[0] - p[0]) * rr / la, p[1] + (a[1] - p[1]) * rr / la)
    let e = (p[0] + (b[0] - p[0]) * rr / lb, p[1] + (b[1] - p[1]) * rr / lb)
    var ps = corner(s)
    ps.outH = (s[0] + (p[0] - s[0]) * k, s[1] + (p[1] - s[1]) * k)
    var pe = corner(e)
    pe.inH = (e[0] + (p[0] - e[0]) * k, e[1] + (p[1] - e[1]) * k)
    result.pts.add ps
    result.pts.add pe

proc ellipseSub(cx, cy, rx, ry: float; reverse = false): SubPath =
  ## (an ellipse as four curves)
  const k = 0.5523
  result = SubPath(closed: true)
  var ps = [((cx + rx, cy), (0.0, -ry * k), (0.0, ry * k)), ((cx, cy + ry), (rx * k, 0.0), (-rx * k, 0.0)),
            ((cx - rx, cy), (0.0, ry * k), (0.0, -ry * k)), ((cx, cy - ry), (-rx * k, 0.0), (rx * k, 0.0))]
  if reverse:
    var r: typeof(ps)
    for i in 0 .. 3:
      let (p, a, b) = ps[3 - i]
      r[i] = (p, b, a)
    ps = r
  for (p, a, b) in ps:
    result.pts.add PathPoint(p: p, inH: (p[0] + a[0], p[1] + a[1]), outH: (p[0] + b[0], p[1] + b[1]))

proc smoothClosed(pts: openArray[Pt]): SubPath =
  ## (a closed curve through the points: Catmull-Rom)
  result = SubPath(closed: true)
  let n = pts.len
  for i in 0 ..< n:
    let a = pts[(i + n - 1) mod n]
    let p = pts[i]
    let b = pts[(i + 1) mod n]
    let t = ((b[0] - a[0]) / 6, (b[1] - a[1]) / 6)
    result.pts.add PathPoint(p: p, inH: (p[0] - t[0], p[1] - t[1]), outH: (p[0] + t[0], p[1] + t[1]))

proc liveShapePath*(p: ShapeParams; x0, y0, x1, y1: float): Path =
  ## The shape `p` drawn in the box `x0`, `y0` .. `x1`, `y1`.
  let x0 = min(x0, x1)
  let y0 = min(y0, y1)
  let x1 = max(x0, x1)
  let y1 = max(y0, y1)
  let w = max(1e-6, x1 - x0)
  let h = max(1e-6, y1 - y0)
  let cx = (x0 + x1) / 2
  let cy = (y0 + y1) / 2
  let v = p.v
  let m = min(w, h)
  template pct(i: int): float = v[i] / 100
  var subs: seq[SubPath]
  case p.kind
  of lsArrow:
    let sw = h * pct(0) / 2
    let hl = w * pct(1)
    subs.add polySub([(x0, cy - sw), (x1 - hl, cy - sw), (x1 - hl, y0), (x1, cy), (x1 - hl, y1), (x1 - hl, cy + sw),
                      (x0, cy + sw)])
  of lsDoubleArrow:
    let sw = h * pct(0) / 2
    let hl = w * pct(1) / 2
    subs.add polySub([(x0, cy), (x0 + hl, y0), (x0 + hl, cy - sw), (x1 - hl, cy - sw), (x1 - hl, y0), (x1, cy),
                      (x1 - hl, y1), (x1 - hl, cy + sw), (x0 + hl, cy + sw), (x0 + hl, y1)])
  of lsChevron:
    let dd = w * pct(0)
    subs.add polySub([(x0, y0), (x1 - dd, y0), (x1, cy), (x1 - dd, y1), (x0, y1), (x0 + dd, cy)])
  of lsBubble:
    let tl = h * pct(3)
    let bodyB = y1 - tl
    let r = min(w, bodyB - y0) * pct(0)
    let tx = x0 + w * pct(1)
    let tw = w * pct(2)
    let a = clamp(tx - tw / 2, x0 + r, x1 - r - tw)
    var pts: seq[Pt] = @[(x0, y0), (x1, y0), (x1, bodyB), (a + tw, bodyB), (a + tw * 0.15, y1), (a, bodyB), (x0, bodyB)]
    # (the body's corners rounded, the tail's sharp)
    var sp = roundedPoly(pts, r)
    subs.add sp
  of lsCloud:
    let nb = max(5, int(round(v[0])))
    let dd = pct(1)
    var pts: seq[Pt]
    for i in 0 ..< nb * 2:
      let a = -PI / 2 + i.float / (nb * 2).float * 2 * PI
      let f = if i mod 2 == 0: 1.0 else: 1.0 - dd
      pts.add (cx + w / 2 * f * cos(a), cy + h / 2 * f * sin(a))
    subs.add smoothClosed(pts)
  of lsBadge:
    let np = max(6, int(round(v[0])))
    var pts: seq[Pt]
    for i in 0 ..< np * 2:
      let a = -PI / 2 + i.float / (np * 2).float * 2 * PI
      let f = if i mod 2 == 0: 1.0 else: 1.0 - pct(1)
      pts.add (cx + w / 2 * f * cos(a), cy + h / 2 * f * sin(a))
    subs.add polySub(pts)
  of lsRibbon:
    let fw = w * pct(0)
    let notch = fw * pct(1)
    let drop = h * pct(2)
    let bt = y0
    let bb = y1 - drop
    # (the band, then the folds at its ends, a step lower, notched)
    subs.add polySub([(x0 + fw, bt), (x1 - fw, bt), (x1 - fw, bb), (x0 + fw, bb)])
    var l = polySub([(x0, bt + drop), (x0 + fw * 1.4, bt + drop), (x0 + fw * 1.4, y1), (x0, y1),
                     (x0 + notch, (bt + drop + y1) / 2)])
    l.joined = false
    subs.add l
    var r = polySub([(x1, bt + drop), (x1 - fw * 1.4, bt + drop), (x1 - fw * 1.4, y1), (x1, y1),
                     (x1 - notch, (bt + drop + y1) / 2)])
    subs.add r
  of lsHeart:
    let pt = y0 + h * pct(0)
    var sp = SubPath(closed: true)
    let top = y0 + h * 0.28
    sp.pts.add PathPoint(p: (cx, top), inH: (cx - w * 0.05, y0 - h * 0.05), outH: (cx + w * 0.05, y0 - h * 0.05))
    sp.pts.add PathPoint(p: (x1, y0 + h * 0.3), inH: (x1, y0 - h * 0.02), outH: (x1, y0 + h * 0.55))
    sp.pts.add PathPoint(p: (cx, pt), inH: (cx + w * 0.3, y0 + h * 0.75), outH: (cx - w * 0.3, y0 + h * 0.75))
    sp.pts.add PathPoint(p: (x0, y0 + h * 0.3), inH: (x0, y0 + h * 0.55), outH: (x0, y0 - h * 0.02))
    # (its top dip: the two lobes meet at the middle)
    sp.pts[0].inH = (cx - w * 0.02, top - h * 0.12)
    sp.pts[0].outH = (cx + w * 0.02, top - h * 0.12)
    sp.pts[1].inH = (x1 - w * 0.02, y0 - h * 0.04)
    sp.pts[3].outH = (x0 + w * 0.02, y0 - h * 0.04)
    subs.add sp
  of lsGear:
    let teeth = max(4, int(round(v[0])))
    let depth = pct(1)
    var pts: seq[Pt]
    for i in 0 ..< teeth:
      for (f, r) in [(0.0, 1.0 - depth), (0.15, 1.0), (0.45, 1.0), (0.6, 1.0 - depth)]:
        let a = -PI / 2 + (i.float + f) / teeth.float * 2 * PI
        pts.add (cx + w / 2 * r * cos(a), cy + h / 2 * r * sin(a))
    subs.add polySub(pts)
    if v[2] > 0:
      var hole = ellipseSub(cx, cy, w / 2 * pct(2) * (1 - depth), h / 2 * pct(2) * (1 - depth))
      hole.op = poSubtract
      subs.add hole
  of lsPolygon, lsStar:
    let star = p.kind == lsStar
    let n = max(3, int(round(v[0])))
    let inner = if star: pct(1) else: 1.0
    var pts: seq[Pt]
    let k = if star: n * 2 else: n
    for i in 0 ..< k:
      let a = -PI / 2 + i.float / k.float * 2 * PI
      let f = if star and i mod 2 == 1: inner else: 1.0
      pts.add (cx + w / 2 * f * cos(a), cy + h / 2 * f * sin(a))
    let round = (if star: v[2] else: v[1]) / 100 * m / 2
    subs.add roundedPoly(pts, round)
  of lsRoundRect:
    let rs = [m / 2 * pct(0), m / 2 * pct(1), m / 2 * pct(2), m / 2 * pct(3)]
    var sp = SubPath(closed: true)
    const k = 0.5523
    let cs = [((x0, y0), (1.0, 0.0), (0.0, 1.0)), ((x1, y0), (0.0, 1.0), (-1.0, 0.0)),
              ((x1, y1), (-1.0, 0.0), (0.0, -1.0)), ((x0, y1), (0.0, -1.0), (1.0, 0.0))]
    for i, (c, outDir, inDir) in cs:
      let r = rs[i]
      if r <= 0.01:
        sp.pts.add corner(c)
        continue
      let s = (c[0] + inDir[0] * r, c[1] + inDir[1] * r)
      let e = (c[0] + outDir[0] * r, c[1] + outDir[1] * r)
      var ps = corner(s)
      ps.outH = (s[0] - inDir[0] * r * k, s[1] - inDir[1] * r * k)
      var pe = corner(e)
      pe.inH = (e[0] - outDir[0] * r * k, e[1] - outDir[1] * r * k)
      sp.pts.add ps
      sp.pts.add pe
    subs.add sp
  of lsCross:
    let tw = w * pct(0) / 2
    let th = h * pct(0) / 2
    subs.add roundedPoly([(cx - tw, y0), (cx + tw, y0), (cx + tw, cy - th), (x1, cy - th), (x1, cy + th),
                          (cx + tw, cy + th), (cx + tw, y1), (cx - tw, y1), (cx - tw, cy + th), (x0, cy + th),
                          (x0, cy - th), (cx - tw, cy - th)], v[1] / 100 * min(tw, th))
  of lsRing:
    subs.add ellipseSub(cx, cy, w / 2, h / 2)
    var hole = ellipseSub(cx, cy, w / 2 * (1 - pct(0)), h / 2 * (1 - pct(0)))
    hole.op = poSubtract
    subs.add hole
  of lsTriangle:
    subs.add roundedPoly([(x0 + w * pct(0), y0), (x1, y1), (x0, y1)], v[1] / 100 * m / 2)
  of lsParallelogram:
    let s = w * v[0] / 100 / 2
    subs.add roundedPoly([(x0 + max(0.0, s), y0), (x1 + min(0.0, s), y0), (x1 - max(0.0, s), y1),
                          (x0 - min(0.0, s), y1)], v[1] / 100 * m / 2)
  of lsTrapezoid:
    let tw = w * pct(0) / 2
    subs.add roundedPoly([(cx - tw, y0), (cx + tw, y0), (x1, y1), (x0, y1)], v[1] / 100 * m / 2)
  of lsTag:
    let pl = w * pct(0)
    subs.add roundedPoly([(x0 + pl, y0), (x1, y0), (x1, y1), (x0 + pl, y1), (x0, cy)], v[2] / 100 * m / 2)
    if v[1] > 0:
      var hole = ellipseSub(x0 + pl * 0.9, cy, m * pct(1), m * pct(1))
      hole.op = poSubtract
      subs.add hole
  of lsPie:
    let a0 = (v[0] - 90) * PI / 180
    let sweep = clamp(v[1], 1.0, 360.0) * PI / 180
    let hole = pct(2)
    let n = max(8, int(sweep / (PI / 18)))
    var pts: seq[Pt]
    for i in 0 .. n:
      let a = a0 + sweep * i.float / n.float
      pts.add (cx + w / 2 * cos(a), cy + h / 2 * sin(a))
    if hole > 0:
      for i in countdown(n, 0):
        let a = a0 + sweep * i.float / n.float
        pts.add (cx + w / 2 * hole * cos(a), cy + h / 2 * hole * sin(a))
    elif sweep < 2 * PI - 1e-6:
      pts.add (cx, cy)
    subs.add polySub(pts)
  of lsBlob:
    let lobes = max(3, int(round(v[0])))
    let wob = pct(1)
    var s = uint32(max(0.0, v[2])) * 2654435761'u32 + 12345
    var pts: seq[Pt]
    for i in 0 ..< lobes * 2:
      s = s * 1103515245'u32 + 12345'u32
      let rnd = float((s shr 8) and 0xFFFF) / 65535.0
      let a = -PI / 2 + i.float / (lobes * 2).float * 2 * PI
      let f = 1.0 - wob * rnd
      pts.add (cx + w / 2 * f * cos(a), cy + h / 2 * f * sin(a))
    subs.add smoothClosed(pts)
  for i, sp in subs:
    var x = sp
    if i > 0 and x.op == poAdd: x.joined = false
    result.subs.add x
