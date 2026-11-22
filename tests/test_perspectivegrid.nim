## Tests of the perspective grid (retroui/perspectivegrid): its planes meet where they should
## (the walls at the near corner, the floor under them), go back toward the vanishing points,
## a shape laid on a plane lies on it -- smaller as it goes back, a curve still a curve -- and
## the grid's lines.

import std/[math]
import retroui/[photo, photoshapes, photovp, perspectivegrid, textengine]

proc near(a, b: (float, float); e = 1e-6): bool = abs(a[0] - b[0]) < e and abs(a[1] - b[1]) < e

block twoPoint:
  let g = defaultGrid(800, 600)
  doAssert g.kind == pkTwoPoint and g.planes == @[ppLeft, ppRight, ppFloor]
  let l = g.planeQuad(ppLeft)
  let r = g.planeQuad(ppRight)
  let f = g.planeQuad(ppFloor)
  # (the walls share the near corner's side; the floor's near corner is its foot)
  doAssert near(l[1], r[0]) and near(l[2], r[3]) and near(f[2], l[2])
  doAssert near(f[3], l[3]) and near(f[1], r[2]), "the floor runs under the walls"
  # (the walls' far sides are shorter, nearer the horizon)
  doAssert abs(l[3][1] - l[0][1]) < abs(l[2][1] - l[1][1])
  doAssert abs(r[2][1] - r[1][1]) < abs(r[3][1] - r[0][1])
  # (the floor's far corner is on the lines to both points)
  let vl = (g.leftX, g.horizon)
  let vr = (g.rightX, g.horizon)
  proc onLine(p, a, b: (float, float)): bool =
    abs((b[0] - a[0]) * (p[1] - a[1]) - (b[1] - a[1]) * (p[0] - a[0])) < 1e-3 * hypot(b[0] - a[0], b[1] - a[1])
  doAssert onLine(f[0], f[3], vr) and onLine(f[0], f[1], vl)
  for pl in g.planes: doAssert vpPlane(g.planeQuad(pl)).ok, $pl
  let lines = g.gridLines(800, 600)
  doAssert lines[0].plane == -1 and abs(lines[0].a[1] - g.horizon) < 1e-9
  doAssert lines.len == 1 + 3 * 2 * (g.cells + 1)

block onePoint:
  var g = defaultGrid(800, 600)
  g.kind = pkOnePoint
  g.leftX = 400
  g.nearX = 250
  g.nearW = 300
  doAssert g.planes.len == 4
  let fw = g.planeQuad(ppFacing)
  doAssert near(fw[0], (250.0, g.top)) and near(fw[2], (550.0, g.ground))
  let fl = g.planeQuad(ppFloor)
  doAssert near(fl[2], fw[2]) and near(fl[3], fw[3]) and fl[0][1] < fw[3][1]
  for pl in g.planes: doAssert vpPlane(g.planeQuad(pl)).ok, $pl

block onAPlane:
  let g = defaultGrid(800, 600)
  let p = vpPlane(g.planeQuad(ppLeft))
  # (a square on the left wall: its top left and bottom right stay, the others follow the
  # plane -- its far (left) side shorter, its top and bottom running toward the point)
  let (x0, y0) = p.toImage(0.3, 0.3)
  let (x1, y1) = p.toImage(0.7, 0.7)
  let r = rectPath(x0, y0, x1, y1).ontoPlane(g, ppLeft)
  doAssert r.subs.len == 1 and r.subs[0].pts.len == 4
  let a = r.subs[0].pts
  doAssert near(a[0].p, (x0, y0), 1e-6) and near(a[2].p, (x1, y1), 1e-6)
  doAssert near(a[1].p, p.toImage(0.7, 0.3), 1e-6) and near(a[3].p, p.toImage(0.3, 0.7), 1e-6)
  doAssert abs(a[3].p[1] - a[0].p[1]) < abs(a[2].p[1] - a[1].p[1]), "farther is smaller"
  for pt in a:
    let (u, v) = p.toPlane(pt.p[0], pt.p[1])
    doAssert u > 0.29 and u < 0.71 and v > 0.29 and v < 0.71, $(u, v)
  # (an ellipse: each curve cut in four, its points where the flat one's go)
  let e = ellipsePath(x0, y0, x1, y1)
  let eo = e.ontoPlane(g, ppLeft)
  doAssert eo.subs[0].pts.len == e.subs[0].pts.len * 4 and eo.subs[0].closed
  proc flatToPlane(q: (float, float)): (float, float) =
    p.toImage(0.3 + (q[0] - x0) / (x1 - x0) * 0.4, 0.3 + (q[1] - y0) / (y1 - y0) * 0.4)
  doAssert near(eo.subs[0].pts[0].p, flatToPlane(e.subs[0].pts[0].p), 1e-6)
  proc bez(a, b, c, d: (float, float); t: float): (float, float) =
    let m = 1 - t
    (m*m*m*a[0] + 3*m*m*t*b[0] + 3*m*t*t*c[0] + t*t*t*d[0], m*m*m*a[1] + 3*m*m*t*b[1] + 3*m*t*t*c[1] + t*t*t*d[1])
  let e0 = e.subs[0].pts[0]
  let e1 = e.subs[0].pts[1]
  let want = flatToPlane(bez(e0.p, e0.outH, e1.inH, e1.p, 0.5))
  let got = eo.subs[0].pts[2].p          # (the cuts are at a quarter, a half, three quarters)
  doAssert hypot(got[0] - want[0], got[1] - want[1]) < 0.5, $(got, want)
  # (over the plane's horizon it cannot lie: left as it was)
  let sky = rectPath(10, 5, 60, 40)
  doAssert sky.ontoPlane(g, ppFloor) == sky

block pixelsOnAPlane:
  let d = newDoc(400, 300)
  let L = d.addLayer("Paint")
  let g = defaultGrid(400, 300)
  let p = vpPlane(g.planeQuad(ppRight))
  let (x0, y0) = p.toImage(0.2, 0.2)
  let (x1, y1) = p.toImage(0.6, 0.6)
  for y in int(y0) ..< int(y1):
    for x in int(x0) ..< int(x1): L.px[y * d.w + x] = 0xFFCC2020'u32
  d.beginStep("Attach")
  doAssert d.pixelsOntoPlane(L, g, ppRight)
  d.endStep()
  # (inside its square on the plane: painted; outside it, where the flat box was, empty)
  let (cx, cy) = p.toImage(0.4, 0.4)
  doAssert L.px[int(cy) * d.w + int(cx)] == 0xFFCC2020'u32
  var outside, painted = 0
  for y in int(y0) ..< int(y1):
    for x in int(x0) ..< int(x1):
      let (u, v) = p.toPlane(x.float + 0.5, y.float + 0.5)
      if u < 0.18 or u > 0.62 or v < 0.18 or v > 0.62:
        inc outside
        if (L.px[y * d.w + x] shr 24) > 0: inc painted
  doAssert outside > 100 and painted == 0, $(outside, painted)
  d.undo()
  doAssert L.px[int(y0 + 2) * d.w + int(x1) - 3] == 0xFFCC2020'u32, "undone"
  echo "perspectivegrid: ok"

block typeOnAPlane:
  # type laid on a plane stays type: set flat and drawn through the plane, its letters inside the
  # plane's quad; typed in flat; kept with the text; released flat again
  let d = newDoc(800, 600)
  let g = defaultGrid(800, 600)
  let p = vpPlane(g.planeQuad(ppLeft))
  let (x0, y0) = p.toImage(0.25, 0.3)
  let (x1, y1) = p.toImage(0.75, 0.6)
  var t = newText("PERSPECTIVE", CharStyle(family: "", size: 40, color: 0xFF2040A0'u32, hScale: 1, vScale: 1),
                  float32(x0), float32(y0))
  t.boxW = float32(x1 - x0)
  t.boxH = float32(y1 - y0)
  let L = d.addTextLayer(t)
  let flat = L.px
  d.beginStep("Attach")
  doAssert d.textOntoPlane(L, g, ppLeft)
  d.endStep()
  doAssert L.isText and L.text.plainText == "PERSPECTIVE" and L.text.perspOn
  # (its letters inside its quad on the plane; changed from flat)
  var inside, outside = 0
  for y in 0 ..< d.h:
    for x in 0 ..< d.w:
      if (L.px[y * d.w + x] shr 24) > 40:
        let (u, v) = p.toPlane(x.float + 0.5, y.float + 0.5)
        if u >= 0.24 and u <= 0.76 and v >= 0.29 and v <= 0.61: inc inside else: inc outside
  doAssert inside > 200 and outside == 0, $(inside, outside)
  doAssert L.px != flat
  # (typed in: flat meanwhile)
  flatTextLayer = L
  d.drawText(L)
  doAssert L.px == flat
  flatTextLayer = nil
  d.drawText(L)
  doAssert L.px != flat
  # (kept with the text; moved with it)
  let back = textFrom(L.text.toJson)
  doAssert back.perspOn and back.persp == L.text.persp and back.perspBox == L.text.perspBox
  let mv = L.text.moved(10, 5)
  doAssert abs(mv.persp[0][0] - L.text.persp[0][0] - 10) < 1e-4 and abs(mv.perspBox[1] - L.text.perspBox[1] - 5) < 1e-4
  # (released: flat again, where it was)
  d.beginStep("Release")
  doAssert d.textOffPlane(L)
  d.endStep()
  doAssert not L.text.perspOn and L.px == flat
  d.undo()
  doAssert L.text.perspOn
  echo "type on a plane: still type"

block threePoint:
  # the walls' uprights meet at the third point: their far sides lean toward it
  let g = threePoint(800, 600)
  doAssert g.kind == pkThreePoint and g.planes == @[ppLeft, ppRight, ppFloor] and g.vertY > 600
  let l = g.planeQuad(ppLeft)
  let r = g.planeQuad(ppRight)
  let v3 = (g.nearX, g.vertY)
  proc onLine(p, a, b: (float, float)): bool =
    abs((b[0] - a[0]) * (p[1] - a[1]) - (b[1] - a[1]) * (p[0] - a[0])) < 1e-3 * hypot(b[0] - a[0], b[1] - a[1])
  doAssert onLine(l[3], l[0], v3) and onLine(r[2], r[1], v3), "the far sides on lines to the third point"
  doAssert abs(l[3][0] - l[0][0]) > 1e-3, "no longer upright"
  doAssert near(l[1], r[0]) and near(l[2], r[3])
  for pl in g.planes: doAssert vpPlane(g.planeQuad(pl)).ok, $pl
  # kept in a document's JSON
  let back = gridFrom(gridToJson(g), 800, 600)
  doAssert back.kind == pkThreePoint and abs(back.vertY - g.vertY) < 1e-9
  # a shape laid on its wall
  let sq = rectPath(380, 200, 400, 240)
  doAssert ontoPlane(sq, g, ppLeft) != sq

block isometricGrid:
  # (no vanishing point: the planes are parallelograms, their sides at 30 degrees, as deep as they
  # are high; a square drawn on a wall stays as wide everywhere -- no side smaller, as perspective
  # makes it -- and a grid kept comes back isometric)
  let g = isometric(800, 600)
  for pl in g.planes:
    let q = g.planeQuad(pl)
    let (a, b) = ((q[1][0] - q[0][0], q[1][1] - q[0][1]), (q[2][0] - q[3][0], q[2][1] - q[3][1]))
    doAssert abs(a[0] - b[0]) < 1e-6 and abs(a[1] - b[1]) < 1e-6, $pl & ": a parallelogram"
  let l = g.planeQuad(ppLeft)
  let slope = (l[3][1] - l[2][1]) / (l[3][0] - l[2][0])
  doAssert abs(arctan(slope) - PI / 6) < 1e-6, "the left wall's foot at 30 degrees: " & $radToDeg(arctan(slope))
  doAssert g.gridLines(800, 600).len > 0 and g.gridLines(800, 600)[0].plane >= 0, "lines, no horizon"
  let sq = rectPath(300, 400, 340, 440)
  let on = ontoPlane(sq, g, ppRight)
  let (x0, y0, x1, y1) = pathBounds(on)
  doAssert on != sq and x1 - x0 > 30, "a square laid on the right wall"
  let p = on.subs[0].pts
  doAssert abs((p[1].p[1] - p[0].p[1]) - (p[2].p[1] - p[3].p[1])) < 1e-6, "its sides parallel: no point"
  let back = gridFrom(gridToJson(g), 800, 600)
  doAssert back.kind == pkIsometric and back.planeQuad(ppFloor) == g.planeQuad(ppFloor), "kept and back"

echo "test_perspectivegrid: isometric ok"
