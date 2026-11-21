## 3D on shapes (`retroui/threed`): a square extruded and turned -- its front and the sides that
## face the eye, each a face of its own shade, the lit ones lighter --, a bevel making more
## faces, a profile revolved, a circle inflated; the faces drawn (the shape's pixels), kept in
## the file and given to SVG and PDF as faces; no 3D, no faces.

import std/[math, strutils, json]
import retroui/[photo, photoshapes, threed, photosvg]

var failures = 0
template check(cond: bool; what: string) =
  if cond: echo "  ok   ", what
  else:
    echo "  FAIL ", what
    inc failures

var sq = ShapeData(kind: "Rectangle", fill: solidPaint(0xFF3080C0'u32))
sq.path = rectPath(100, 100, 200, 200)

block extrude:
  var s = sq
  s.threeD = defaultThreeD(tdExtrude)
  let faces = threeDParts(s)
  check faces.len >= 2 and faces.len <= 4, "the front and the sides facing the eye (" & $faces.len & ")"
  var shades: seq[uint32]
  for f in faces:
    if f.fill.color notin shades: shades.add f.fill.color
  check shades.len >= 2, "faces in different shades (" & $shades.len & ")"
  # (turned: the faces reach past the square)
  var x0, y0 = 1e9
  var x1, y1 = -1e9
  for f in faces:
    let b = pathBounds(f.path)
    x0 = min(x0, b[0]); y0 = min(y0, b[1]); x1 = max(x1, b[2]); y1 = max(y1, b[3])
  check x1 - x0 > 100 and y1 - y0 > 100, "turned in depth: wider and taller than the square"
  var flat = s
  flat.threeD.rx = 0
  flat.threeD.ry = 0
  let ff = threeDParts(flat)
  check ff.len == 1, "seen straight on: only its front"
  s.threeD.bevel = 10
  check threeDParts(s).len > faces.len, "a bevel: more faces"
  var none = sq
  check threeDParts(none).len == 0, "no 3D: no faces"

block revolveAndInflate:
  var prof = ShapeData(kind: "Path", stroke: solidPaint(0xFFCC5500'u32), strokeWidth: 2)
  var sp = SubPath()
  for (x, y) in [(100.0, 100.0), (140.0, 130.0), (120.0, 200.0)]:
    sp.pts.add PathPoint(p: (x, y), inH: (x, y), outH: (x, y))
  prof.path = Path(subs: @[sp])
  prof.threeD = defaultThreeD(tdRevolve)
  let rv = threeDParts(prof)
  check rv.len > 20 and rv[0].fill.kind == spColor, "a profile revolved: many faces in its stroke's color's shades (" &
        $rv.len & ")"
  var c = ShapeData(kind: "Ellipse", fill: solidPaint(0xFF20A040'u32))
  c.path = ellipsePath(0, 0, 100, 100)
  c.threeD = defaultThreeD(tdInflate)
  let inf = threeDParts(c)
  check inf.len > 30, "a circle inflated: rings of faces and a top (" & $inf.len & ")"

block drawnAndKept:
  let d = newDoc(320, 320, 0xFFFFFFFF'u32)
  var s = sq
  s.threeD = defaultThreeD(tdExtrude)
  let L = d.addShapeLayer(s)
  # (drawn: pixels where the faces are, past the square)
  check (L.px[150 * 320 + 150] shr 24) == 255, "the front drawn"
  var past = false
  for y in 0 ..< 320:
    for x in 205 ..< 320:
      if (L.px[y * 320 + x] shr 24) > 200: past = true
  check past, "the sides drawn past it"
  let j = toJson(L.shape)
  check j.hasKey("threeD"), "kept in the file"
  let back = shapeFrom(j)
  check back.threeD.kind == tdExtrude and back.threeD.depth == s.threeD.depth and back.threeD.ry == s.threeD.ry,
        "read back as it was"
  let svg = d.svgOf()
  check svg.count("<path") >= 2, "SVG: the faces as paths"

if failures > 0:
  echo "test_threed: ", failures, " failed"
  quit(1)
echo "test_threed: all passed"
