## Islamic geometric patterns as shapes: the eight-pointed stars and crosses (khatam: two squares
## turned through each other on a square grid, the crosses between them), six-pointed stars on a
## grid of triangles (hexagons and triangles between them), and octagons with an eight-pointed star
## inside each and squares between them; a border of eight-pointed stars along a frame's four
## sides, a star in each corner. Each motif a closed subpath of one path, whole motifs over the area
## (put inside a frame to cut them to its edge): a shape layer's outline, to fill and stroke.
##
## .. code-block:: nim
##   let p = geoPattern(gpStarCross, 0, 0, 800, 600, cell = 80)
##   discard d.addShapeLayer(ShapeData(path: p, fill: solidPaint(gold), stroke: solidPaint(navy),
##                                     strokeWidth: 2), "Khatam")
##
## Developed by Sultan Al Isaiee @foxoman -- www.foxoman.net -- sultan@foxoman.net

import std/math
import photo

type
  GeoPattern* = enum
    ## The patterns `geoPattern` draws.
    gpStarCross = "Eight-Pointed Stars and Crosses", gpHexagrams = "Six-Pointed Stars",
    gpOctagons = "Octagons and Stars"

proc ring(cx, cy: float; radii: openArray[float]; turn: float): SubPath =
  ## (a closed motif round (cx, cy): its corners at the radii given in turn, evenly round, the first
  ## at angle `turn`)
  result = SubPath(closed: true)
  let n = radii.len
  for i in 0 ..< n:
    let a = turn + i.float * 2 * PI / n.float
    let p = (cx + cos(a) * radii[i], cy + sin(a) * radii[i])
    result.pts.add PathPoint(p: p, inH: p, outH: p)

proc star(cx, cy, r: float; points, step: int; turn = 0.0): SubPath =
  ## (a star polygon {points/step}: its points at `r`, its inner corners where the lines cross)
  let inner = r * cos(PI * step.float / points.float) / cos(PI * (step - 1).float / points.float)
  var radii: seq[float]
  for i in 0 ..< points:
    radii.add r
    radii.add inner
  ring(cx, cy, radii, turn)

proc inside(cx, cy, x0, y0, x1, y1: float): bool = cx >= x0 and cx <= x1 and cy >= y0 and cy <= y1

proc geoPattern*(kind: GeoPattern; x0, y0, x1, y1, cell: float): Path =
  ## `kind` over the box `x0, y0` .. `x1, y1`, its grid `cell` pixels: each star (and, for the
  ## octagons, each octagon round its star, the star cut out of it) a closed subpath; whole motifs, every one whose middle
  ## is in the box.
  let c = max(4.0, cell)
  let (a, b) = (min(x0, x1), min(y0, y1))
  let (e, f) = (max(x0, x1), max(y0, y1))
  result.name = $kind
  case kind
  of gpStarCross:
    # (the stars' axis points touch their neighbours': crosses left between them)
    let r = c / 2
    var y = b + c / 2
    while y <= f + 0.01:
      var x = a + c / 2
      while x <= e + 0.01:
        result.subs.add star(x, y, r, 8, 2, -PI / 2)
        x += c
      y += c
  of gpHexagrams:
    # (on a grid of triangles: each star's points meet its six neighbours')
    let r = c / 2
    let dy = c * sqrt(3.0) / 2
    var row = 0
    var y = b + r
    while y <= f + 0.01:
      var x = a + r + (if row mod 2 == 1: c / 2 else: 0.0)
      while x <= e + 0.01:
        if inside(x, y, a, b, e, f): result.subs.add star(x, y, r, 6, 2, -PI / 2)
        x += c
      y += dy
      inc row
  of gpOctagons:
    # (octagons edge to edge on a square grid, squares between them; an eight-pointed star in each)
    let ro = c / 2 / cos(PI / 8)               # (the octagon's corners: its sides touch the cell's)
    var y = b + c / 2
    while y <= f + 0.01:
      var x = a + c / 2
      while x <= e + 0.01:
        result.subs.add ring(x, y, [ro, ro, ro, ro, ro, ro, ro, ro], PI / 8)
        # (the star cut out of its octagon: the paper showing)
        var s = star(x, y, c / 2 * 0.86, 8, 3, -PI / 2)
        s.op = poSubtract
        result.subs.add s
        x += c
      y += c

proc geoBorder*(x0, y0, x1, y1, band: float): Path =
  ## A border of eight-pointed stars in a band `band` pixels wide inside the box's edges: a row of
  ## them along each side, as many as fit evenly, one in each corner.
  let w = max(4.0, band)
  let (a, b) = (min(x0, x1), min(y0, y1))
  let (e, f) = (max(x0, x1), max(y0, y1))
  result.name = "Star Border"
  let r = w / 2
  # (the corners first)
  for (cx, cy) in [(a + r, b + r), (e - r, b + r), (e - r, f - r), (a + r, f - r)]:
    result.subs.add star(cx, cy, r, 8, 2, -PI / 2)
  # (the sides: as many as fit between the corners, spread evenly)
  for (sx, sy, ex, ey) in [(a + w, b + r, e - w, b + r), (a + w, f - r, e - w, f - r),
                           (a + r, b + w, a + r, f - w), (e - r, b + w, e - r, f - w)]:
    let len = hypot(ex - sx, ey - sy)
    let n = int(floor(len / w))
    if n <= 0: continue
    let step = len / n.float
    for i in 0 ..< n:
      let t = (i.float + 0.5) * step / len
      result.subs.add star(sx + (ex - sx) * t, sy + (ey - sy) * t, min(r, step / 2), 8, 2, -PI / 2)
