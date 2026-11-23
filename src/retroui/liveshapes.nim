## Shapes that keep their settings: arrows, chevrons, speech and thought
## bubbles, badges, ribbons, hearts, gears, polygons and stars, rectangles
## with each corner its own, crosses, rings, triangles, parallelograms,
## trapezoids, tags, pies; Affinity's diamonds, double and square stars,
## segments, callouts, tears, crescents, clouds and cats -- each drawn in a box from a few numbers
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
    lsTag = "Tag", lsPie = "Pie", lsBlob = "Blob",
    lsDiamond = "Diamond", lsDoubleStar = "Double Star", lsSquareStar = "Square Star", lsSegment = "Segment",
    lsCalloutRect = "Callout Rounded Rectangle", lsCalloutEllipse = "Callout Ellipse", lsTear = "Tear",
    lsCrescent = "Crescent", lsCloudShape = "Cloud", lsCat = "Cat"
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
  of lsDiamond: @[("Middle at %", 5.0, 95.0, 50.0), ("Roundness %", 0.0, 50.0, 0.0)]
  of lsDoubleStar: @[("Points", 3.0, 40.0, 8.0), ("Inner radius %", 5.0, 95.0, 70.0),
                     ("Second radius %", 5.0, 95.0, 40.0)]
  of lsSquareStar: @[("Points", 3.0, 40.0, 8.0), ("Inner radius %", 5.0, 95.0, 70.0)]
  of lsSegment: @[("Start angle", -360.0, 360.0, 0.0), ("Sweep", 1.0, 360.0, 120.0), ("Hole %", 0.0, 95.0, 50.0)]
  of lsCalloutRect: @[("Corners %", 0.0, 50.0, 18.0), ("Tail across %", 0.0, 100.0, 20.0),
                      ("Tail down %", 0.0, 100.0, 30.0), ("Tail width %", 2.0, 60.0, 16.0)]
  of lsCalloutEllipse: @[("Tail across %", 0.0, 100.0, 20.0), ("Tail down %", 0.0, 100.0, 30.0),
                         ("Tail width %", 2.0, 60.0, 16.0)]
  of lsTear: @[("Point %", 0.0, 100.0, 60.0), ("Turn", -180.0, 180.0, 0.0)]
  of lsCrescent: @[("Thickness %", 5.0, 100.0, 40.0), ("Turn", -180.0, 180.0, 0.0)]
  of lsCloudShape: @[("Bumps", 3.0, 16.0, 6.0), ("Flat base %", 0.0, 60.0, 30.0)]
  of lsCat: @[("Ears %", 0.0, 100.0, 40.0), ("Head %", 40.0, 100.0, 70.0)]

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

proc fitInto(sp: var SubPath; x0, y0, x1, y1: float) =
  ## (a smoothed outline whose curves swell past the box brought back into it: its points and
  ## handles -- the curves stay within them -- scaled toward the box's middle)
  var lo = (1e18, 1e18)
  var hi = (-1e18, -1e18)
  for q in sp.pts:
    for p in [q.p, q.inH, q.outH]:
      lo = (min(lo[0], p[0]), min(lo[1], p[1]))
      hi = (max(hi[0], p[0]), max(hi[1], p[1]))
  if lo[0] >= x0 and lo[1] >= y0 and hi[0] <= x1 and hi[1] <= y1: return
  let kx = if hi[0] - lo[0] > x1 - x0: (x1 - x0) / max(1e-9, hi[0] - lo[0]) else: 1.0
  let ky = if hi[1] - lo[1] > y1 - y0: (y1 - y0) / max(1e-9, hi[1] - lo[1]) else: 1.0
  proc map(p: Pt): Pt =
    var x = (p[0] - lo[0]) * kx + lo[0]
    var y = (p[1] - lo[1]) * ky + lo[1]
    (x, y)
  for q in sp.pts.mitems:
    q.p = map(q.p)
    q.inH = map(q.inH)
    q.outH = map(q.outH)
  # (then moved inside, scaled to fit)
  var lo2 = (1e18, 1e18)
  var hi2 = (-1e18, -1e18)
  for q in sp.pts:
    for p in [q.p, q.inH, q.outH]:
      lo2 = (min(lo2[0], p[0]), min(lo2[1], p[1]))
      hi2 = (max(hi2[0], p[0]), max(hi2[1], p[1]))
  let dx = if lo2[0] < x0: x0 - lo2[0] elif hi2[0] > x1: x1 - hi2[0] else: 0.0
  let dy = if lo2[1] < y0: y0 - lo2[1] elif hi2[1] > y1: y1 - hi2[1] else: 0.0
  for q in sp.pts.mitems:
    q.p = (q.p[0] + dx, q.p[1] + dy)
    q.inH = (q.inH[0] + dx, q.inH[1] + dy)
    q.outH = (q.outH[0] + dx, q.outH[1] + dy)

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
  of lsDiamond:
    let my = y0 + h * pct(0)
    subs.add roundedPoly([(cx, y0), (x1, my), (cx, y1), (x0, my)], v[1] / 100 * m / 2)
  of lsDoubleStar:
    # (points of two lengths, one after the other, with the dips between)
    let n = max(3, int(round(v[0])))
    var pts: seq[Pt]
    for i in 0 ..< n * 4:
      let a = -PI / 2 + i.float / (n * 4).float * 2 * PI
      let f = case i mod 4
              of 0: 1.0
              of 2: pct(2) + (1 - pct(2)) * 0.6
              else: pct(1) * 0.55
      pts.add (cx + w / 2 * f * cos(a), cy + h / 2 * f * sin(a))
    subs.add polySub(pts)
  of lsSquareStar:
    # (a star of squared points: each point a little square tooth)
    let n = max(3, int(round(v[0])))
    let inner = pct(1)
    var pts: seq[Pt]
    for i in 0 ..< n:
      for (f, r) in [(-0.5, inner), (-0.16, 1.0), (0.16, 1.0)]:
        let a = -PI / 2 + (i.float + f) / n.float * 2 * PI
        pts.add (cx + w / 2 * r * cos(a), cy + h / 2 * r * sin(a))
    subs.add polySub(pts)
  of lsSegment:
    let a0 = (v[0] - 90) * PI / 180
    let sweep = clamp(v[1], 1.0, 360.0) * PI / 180
    let hole = clamp(pct(2), 0.0, 0.95)
    let n = max(8, int(sweep / (PI / 18)))
    var pts: seq[Pt]
    for i in 0 .. n:
      let a = a0 + sweep * i.float / n.float
      pts.add (cx + w / 2 * cos(a), cy + h / 2 * sin(a))
    for i in countdown(n, 0):
      let a = a0 + sweep * i.float / n.float
      pts.add (cx + w / 2 * hole * cos(a), cy + h / 2 * hole * sin(a))
    subs.add polySub(pts)
  of lsCalloutRect, lsCalloutEllipse:
    let rect = p.kind == lsCalloutRect
    let o = if rect: 1 else: 0
    let tailDown = h * pct(o + 1)
    let bodyB = y1 - tailDown
    let tipX = x0 + w * pct(o)
    let tw = w * pct(o + 2)
    let bx = clamp(tipX, x0 + tw, x1 - tw)
    if rect:
      let r = min(w, bodyB - y0) * pct(0)
      subs.add roundedPoly([(x0, y0), (x1, y0), (x1, bodyB), (bx + tw / 2, bodyB), (tipX, y1),
                            (bx - tw / 2, bodyB), (x0, bodyB)], r)
    else:
      # (an ellipse with a tail: its outline broken where the tail leaves it)
      let ry = (bodyB - y0) / 2
      let ecy = y0 + ry
      var pts: seq[Pt]
      let aL = arctan2((bodyB - ecy) * 0.9, (bx - tw / 2) - cx)
      let aR = arctan2((bodyB - ecy) * 0.9, (bx + tw / 2) - cx)
      let n = 48
      var a = aR
      let span = (aL - aR + 2 * PI) mod (2 * PI)
      let rest = 2 * PI - span
      for i in 0 .. n:
        a = aL + rest * i.float / n.float
        pts.add (cx + w / 2 * cos(a), ecy + ry * sin(a))
      pts.add (tipX, y1)
      subs.add polySub(pts)
  of lsTear:
    # (a drop: round below, pointed above, turned)
    let r = m / 2 * 0.62
    let ccx = cx
    let ccy = y1 - r * (h / m)
    let tip = (cx, y0 + (ccy - r - y0) * (1 - pct(0)) * 0.4)
    var sp = SubPath(closed: true)
    const k = 0.5523
    sp.pts.add PathPoint(p: tip, inH: (tip[0] - r * 0.2, tip[1] + r * 0.6), outH: (tip[0] + r * 0.2, tip[1] + r * 0.6))
    sp.pts.add PathPoint(p: (ccx + r, ccy), inH: (ccx + r, ccy - r * 1.1), outH: (ccx + r, ccy + r * k))
    sp.pts.add PathPoint(p: (ccx, ccy + r), inH: (ccx + r * k, ccy + r), outH: (ccx - r * k, ccy + r))
    sp.pts.add PathPoint(p: (ccx - r, ccy), inH: (ccx - r, ccy + r * k), outH: (ccx - r, ccy - r * 1.1))
    if v[1] != 0:
      let a = v[1] * PI / 180
      let ca = cos(a)
      let sa = sin(a)
      template rot(q: Pt): Pt = (cx + (q[0] - cx) * ca - (q[1] - cy) * sa, cy + (q[0] - cx) * sa + (q[1] - cy) * ca)
      for pp in sp.pts.mitems:
        pp.p = rot(pp.p); pp.inH = rot(pp.inH); pp.outH = rot(pp.outH)
    subs.add sp
  of lsCrescent:
    # (a disc with a disc taken out of its side)
    let a = v[1] * PI / 180
    let n = 64
    let th = clamp(pct(0), 0.05, 1.0)
    let off = th * 2 * 0.5
    var outer, inner: seq[Pt]
    let ocx = cx + cos(a) * w / 2 * off
    let ocy = cy + sin(a) * h / 2 * off
    var pts: seq[Pt]
    for i in 0 .. n:
      let t = float(i) / float(n) * 2 * PI
      let q = (cx + w / 2 * cos(t), cy + h / 2 * sin(t))
      # (outside the inner disc: the crescent's own outline)
      let dx = (q[0] - ocx) / (w / 2)
      let dy = (q[1] - ocy) / (h / 2)
      if dx * dx + dy * dy >= 0.999: outer.add q
    for i in 0 .. n:
      let t = float(i) / float(n) * 2 * PI
      let q = (ocx + w / 2 * cos(t), ocy + h / 2 * sin(t))
      let dx = (q[0] - cx) / (w / 2)
      let dy = (q[1] - cy) / (h / 2)
      if dx * dx + dy * dy <= 1.0: inner.add q
    # (the outer arc, then the inner one back)
    var start = 0
    for i in 1 ..< outer.len:
      if hypot(outer[i][0] - outer[i - 1][0], outer[i][1] - outer[i - 1][1]) > max(w, h) / 6: start = i
    for i in 0 ..< outer.len: pts.add outer[(start + i) mod outer.len]
    var ins = inner
    var istart = 0
    for i in 1 ..< ins.len:
      if hypot(ins[i][0] - ins[i - 1][0], ins[i][1] - ins[i - 1][1]) > max(w, h) / 6: istart = i
    var ordered: seq[Pt] = @[]
    for i in 0 ..< ins.len: ordered.add ins[(istart + i) mod ins.len]
    if ordered.len > 1 and pts.len > 1 and
       hypot(ordered[0][0] - pts[^1][0], ordered[0][1] - pts[^1][1]) >
       hypot(ordered[^1][0] - pts[^1][0], ordered[^1][1] - pts[^1][1]):
      var rev: seq[Pt]
      for i in countdown(ordered.high, 0): rev.add ordered[i]
      ordered = rev
    pts.add ordered
    if pts.len >= 3: subs.add polySub(pts)
  of lsCloudShape:
    # (round bumps along the top, a flat-ish base)
    let nb = max(3, int(round(v[0])))
    let base = y1 - h * pct(1) * 0.3
    var pts: seq[Pt]
    pts.add (x0 + w * 0.08, base)
    for i in 0 .. nb * 6:
      let t = float(i) / float(nb * 6)
      let a = PI + t * PI
      let bump = 1 + 0.18 * abs(sin(t * float(nb) * PI))
      pts.add (cx + w / 2 * cos(a) * 0.96, (base + y0) / 2 + (base - y0) / 2 * sin(a) * bump * 0.92)
    pts.add (x1 - w * 0.08, base)
    pts.add (cx, y1)
    var c = smoothClosed(pts)
    c.fitInto(x0, y0, x1, y1)
    subs.add c
  of lsCat:
    # (a cat's head: round, two ears)
    let hs = clamp(pct(1), 0.4, 1.0)
    let ear = pct(0)
    let rx = w / 2 * hs
    let ry = h / 2 * hs * 0.9
    let hcy = y1 - ry
    var pts: seq[Pt]
    let n = 40
    for i in 0 ..< n:
      let a = float(i) / float(n) * 2 * PI
      pts.add (cx + rx * cos(a), hcy + ry * sin(a))
    subs.add smoothClosed(pts)
    for side in [-1.0, 1.0]:
      let bx0 = cx + side * rx * 0.25
      let bx1 = cx + side * rx * 0.85
      let tipX = cx + side * rx * 0.8
      let tipY = max(y0, hcy - ry - (hcy - ry - y0) * ear - ry * 0.25 * ear)
      let a0 = (bx0, hcy - ry * 0.8)
      let a1 = (bx1, hcy - ry * 0.45)
      subs.add polySub([a0, (tipX, min(tipY, hcy - ry)), a1])
  for i, sp in subs:
    var x = sp
    if i > 0 and x.op == poAdd: x.joined = false
    result.subs.add x
