## Tests of brushes along a path (retroui/pathbrush): Art stretches the artwork over the whole
## path, bent with it -- its ends at the path's ends, as wide as asked across it; Pattern lays
## copies one after another, a whole number of them; Scatter sets copies turned, not bent; a
## closed path goes all round; drawn, the outlines fill along the path.

import std/[math]
import retroui/[photo, photoshapes, pathbrush]

proc linePath(pts: openArray[(float, float)]; closed = false): Path =
  var sp = SubPath(closed: closed)
  for p in pts: sp.pts.add PathPoint(p: p, inH: p, outH: p)
  Path(subs: @[sp])

block artAlongALine:
  let line = linePath([(10.0, 50.0), (210.0, 50.0)])
  let b = builtinBrush("Taper", width = 20)
  let r = brushedPath(line, b)
  doAssert r.subs.len == 1 and r.subs[0].closed
  let (x0, y0, x1, y1) = pathBounds(r)
  doAssert abs(x0 - 10) < 0.5 and abs(x1 - 210) < 0.5, $(x0, x1)
  doAssert abs((y1 - y0) - 20) < 0.5 and abs((y0 + y1) / 2 - 50) < 0.5, $(y0, y1)

block artBendsAroundACorner:
  let l = linePath([(0.0, 0.0), (100.0, 0.0), (100.0, 100.0)])
  let r = brushedPath(l, builtinBrush("Arrow", width = 10))
  let (x0, y0, x1, y1) = pathBounds(r)
  doAssert x1 > 100 and y1 > 95 and y0 < 0, "along both legs"
  # (the arrow's head on the last leg: as wide as the brush there)
  var far = 0.0
  for p in r.subs[0].pts:
    if p.p[1] > 55: far = max(far, abs(p.p[0] - 100))
  doAssert far > 4, $far

block patternAndScatter:
  let line = linePath([(0.0, 0.0), (300.0, 0.0)])
  let z = brushedPath(line, builtinBrush("Zigzag", width = 10))
  doAssert z.subs.len == 30, $z.subs.len          # (10 wide copies of a 10-wide art: 30 along 300)
  let d = brushedPath(line, builtinBrush("Dots", width = 10))
  doAssert d.subs.len == 17, $d.subs.len          # (each with room of 0.8 of itself)
  # scattered copies not bent: each a circle still
  let (cx0, cy0, cx1, cy1) = pathBounds(Path(subs: @[d.subs[3]]))
  doAssert abs((cx1 - cx0) - (cy1 - cy0)) < 0.5
  # along a diagonal: turned with it
  let diag = linePath([(0.0, 0.0), (200.0, 200.0)])
  let a = brushedPath(diag, builtinBrush("Arrow", width = 10))
  let (ax0, ay0, ax1, ay1) = pathBounds(a)
  doAssert abs((ax1 - ax0) - (ay1 - ay0)) < 2

block closedAndDrawn:
  let ring = ellipsePath(50, 50, 250, 250)
  let r = brushedPath(ring, builtinBrush("Chain", width = 16))
  doAssert r.subs.len > 10 and r.subs.len mod 2 == 0
  let d = newDoc(300, 300, 0xFFFFFFFF'u32)
  let L = d.addShapeLayer(ShapeData(path: r, fill: solidPaint(0xFF202020'u32)), "Chain")
  # (ink on the ring, none in the middle)
  doAssert (L.px[150 * 300 + 51] shr 24) > 0 or (L.px[150 * 300 + 50] shr 24) > 0
  doAssert (L.px[150 * 300 + 150] shr 24) == 0
  doAssert brushedPath(ring, PathBrush()).subs.len == 0
  doAssert builtinBrush("Nothing").art.subs.len == 0
  for n in BuiltinBrushes: doAssert builtinBrush(n).art.subs.len > 0, n

echo "test_pathbrush: ok"
