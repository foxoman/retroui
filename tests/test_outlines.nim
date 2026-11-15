## Tests of type made shapes (Convert to Shape: `textShapes`) and the shapes
## between two (Make Blend: `blendShapes`, `colorSteps`) -- retroui/photovector.

import std/math
import std/[json, os]
import retroui/[photo, photoshapes, photovector, textengine, liveshapes]

proc st(size: float; color = 0xFF202060'u32): CharStyle =
  CharStyle(family: "", size: size, color: color, hScale: 1, vScale: 1)

proc drawnText(t: TextData; w, h: int): seq[uint32] =
  let d = newDoc(w, h, 0xFFFFFFFF'u32)
  discard d.addTextLayer(t)
  d.toBitmap(0xFFFFFFFF'u32).px

proc drawnShapes(s: seq[ShapeData]; w, h: int): seq[uint32] =
  let d = newDoc(w, h, 0xFFFFFFFF'u32)
  for x in s: discard d.addShapeLayer(x)
  d.toBitmap(0xFFFFFFFF'u32).px

proc differs(a, b: seq[uint32]; by = 60): float =
  ## (the part of the pixels more than `by` levels apart in a channel)
  var n = 0
  for i in 0 ..< a.len:
    for sh in [16, 8, 0]:
      if abs(int((a[i] shr sh) and 255) - int((b[i] shr sh) and 255)) > by:
        inc n
        break
  n / a.len

proc inked(px: seq[uint32]): int =
  for c in px:
    if (c and 255) < 200: inc result

block typeAsShapes:
  # big and small letters, with holes and curves: the shapes draw what the type drew
  for size in [120.0, 36.0, 14.0]:
    let w = 900
    let h = int(size * 2.2)
    let t = newText("Rog@ 8&B pq", st(size), 10, float32(size * 1.3))
    let s = textShapes(t)
    doAssert s.len == 1, "one color: one shape (" & $s.len & ")"
    doAssert s[0].path.subs.len >= 10, "the letters' outlines and holes"
    let a = drawnText(t, w, h)
    let b = drawnShapes(s, w, h)
    let ink = inked(a)
    doAssert ink > 200
    let bad = differs(a, b) * a.len.float / ink.float
    doAssert bad < 0.06, "at " & $size & " px the shapes look like the type: " & $(bad * 100) & "% of its ink differs"
    # curves, not a point for every pixel of the outline
    var pts = 0
    var flat = 0
    for sp in s[0].path.subs: pts += sp.pts.len
    for o in textOutlines(t, layoutText(t), fine = true):
      for poly in o.polys: flat += poly.len
    doAssert pts * 3 < flat, $pts & " points at " & $size & " (" & $flat & " flat)"

block colorsAndFauxBold:
  var t = newText("Two ", st(60, 0xFFC02020'u32), 10, 80)
  t.spans.add TextSpan(text: "colors", style: st(60, 0xFF2040C0'u32))
  t.spans[^1].style.fauxBold = true
  let s = textShapes(t)
  doAssert s.len == 2, $s.len
  doAssert s[0].fill.color == 0xFFC02020'u32 and s[1].fill.color == 0xFF2040C0'u32
  doAssert s[0].stroke.kind == spNone and s[1].stroke.kind == spColor and s[1].strokeWidth > 0, "faux bold: a stroke"
  let a = drawnText(t, 520, 120)
  let b = drawnShapes(s, 520, 120)
  let fb = differs(a, b) * a.len.float / inked(a).float
  doAssert fb < 0.2, "faux bold near enough as the type draws it (its edges): " & $(fb * 100) & "% differs"
  # nothing to draw: no shapes
  doAssert textShapes(newText("", st(40), 0, 40)).len == 0
  doAssert textShapes(newText("   ", st(40), 0, 40)).len == 0

block blendSameKinds:
  # two rectangles (four corners each): the steps between, in even steps of place and color
  let a = ShapeData(path: rectPath(0, 0, 100, 100), fill: solidPaint(0xFFFF0000'u32), strokeWidth: 2)
  let b = ShapeData(path: rectPath(400, 0, 600, 200), fill: solidPaint(0xFF0000FF'u32), strokeWidth: 10)
  let m = blendShapes(a, b, 3)
  doAssert m.len == 3
  let mid = m[1]
  doAssert mid.path.subs.len == 1 and mid.path.subs[0].pts.len == a.path.subs[0].pts.len, "point by point"
  var x0 = Inf
  var x1 = -Inf
  for q in mid.path.subs[0].pts:
    x0 = min(x0, q.p[0])
    x1 = max(x1, q.p[0])
  doAssert abs(x0 - 200) < 0.01 and abs(x1 - 350) < 0.01, $x0 & " " & $x1
  doAssert abs(int((mid.fill.color shr 16) and 255) - 128) <= 1 and abs(int(mid.fill.color and 255) - 128) <= 1
  doAssert abs(mid.strokeWidth - 6) < 1e-9
  doAssert colorSteps(a, b) > 30 and colorSteps(a, a) == 1
  # eased: the steps bunched toward the start; the colors on their own ease
  let e = blendShapes(a, b, 3, beIn, 1.0, beEven)
  var ex0 = Inf
  for q in e[0].path.subs[0].pts: ex0 = min(ex0, q.p[0])
  doAssert ex0 < 50, "ease in: the first step near the start: " & $ex0
  doAssert abs(int((e[1].fill.color shr 16) and 255) - 128) <= 1, "its colors still even"
  doAssert abs(eased(0.5, beInOut) - 0.5) < 1e-9 and eased(0.0, beOut) == 0 and eased(1.0, beIn) == 1

block blendOtherKinds:
  # a circle (curves) to a star (corners), and a shape with a hole to one without
  let a = ShapeData(path: ellipsePath(0, 0, 200, 200), fill: solidPaint(0xFF20A040'u32))
  let b = ShapeData(path: starPath(600, 0, 800, 200, points = 5), fill: solidPaint(0xFFFFFFFF'u32))
  let m = blendShapes(a, b, 5)
  doAssert m.len == 5
  for k, s in m:
    doAssert s.path.subs.len == 1 and s.path.subs[0].closed and s.path.subs[0].pts.len >= 64
    var cx = 0.0
    for q in s.path.subs[0].pts: cx += q.p[0]
    cx /= s.path.subs[0].pts.len.float
    let want = 100 + 600 * (k + 1) / 6
    doAssert abs(cx - want) < 25, "step " & $k & " in between: " & $cx & " (" & $want & ")"
  # every step drawn, none empty or inside out
  for s in m:
    let (x0, y0, x1, y1) = pathBounds(s.path)
    doAssert x1 - x0 > 100 and y1 - y0 > 100
    let px = drawnShapes(@[s], 820, 220)
    let (cx, cy) = (int((x0 + x1) / 2), int((y0 + y1) / 2))
    doAssert (px[cy * 820 + cx] and 255) < 250 or (s.fill.color and 0xFF) > 200, "filled, not inside out"
  var holed = ShapeData(path: ellipsePath(0, 0, 200, 200), fill: solidPaint(0xFF000000'u32))
  var hole = ellipsePath(60, 60, 140, 140).subs[0]
  hole.op = poSubtract
  holed.path.subs.add hole
  let h = blendShapes(holed, ShapeData(path: rectPath(500, 0, 700, 200), fill: solidPaint(0xFF000000'u32)), 4)
  doAssert h.len == 4 and h[0].path.subs.len == 2, "the hole shrinks away"
  # odd ones: a step count out of range, an empty shape
  doAssert blendShapes(a, b, 0).len == 1 and blendShapes(a, b, 99999).len == 1000
  doAssert blendShapes(ShapeData(), ShapeData(), 3).len == 3

block liveShapes:
  # every kind drawn in its box, at its start and at its ends; its settings kept
  for k in LiveShape:
    var p = defaultParams(k)
    for which in 0 .. 2:
      for i, prm in paramsOf(k):
        p.v[i] = case which
                 of 0: prm.default
                 of 1: prm.lo
                 else: prm.hi
      let path = liveShapePath(p, 100, 50, 300, 200)
      doAssert path.subs.len >= 1, $k
      let (x0, y0, x1, y1) = pathBounds(path)
      doAssert x0 >= 90 and y0 >= 40 and x1 <= 310 and y1 <= 210, $k & " in its box (handles a little past it): " & $(x0, y0, x1, y1)
      let px = drawnShapes(@[ShapeData(path: path, fill: solidPaint(0xFF000000'u32))], 400, 260)
      doAssert inked(px) > (if which == 0: 300 else: 20), $k & " draws (" & $which & ")"
    let back = paramsFrom(parseJson($defaultParams(k).toJson))
    doAssert back.ok and back.p == defaultParams(k)
  # a ring has its hole; a gear its hole; a star its points
  let ring = drawnShapes(@[ShapeData(path: liveShapePath(defaultParams(lsRing), 0, 0, 200, 200),
                                     fill: solidPaint(0xFF000000'u32))], 200, 200)
  doAssert (ring[100 * 200 + 100] and 255) > 200 and (ring[100 * 200 + 5] and 255) < 60
  var st = defaultParams(lsStar)
  st.v[0] = 7
  doAssert liveShapePath(st, 0, 0, 100, 100).subs[0].pts.len == 14
  doAssert not paramsFrom(parseJson("{\"live\": \"Nothing\"}")).ok and not paramsFrom(newJNull()).ok

block shapeBuilder:
  # two overlapping squares: their overlap a region of its own; merged with one of them; the
  # other's part taken away
  let a = ShapeData(path: rectPath(20, 20, 120, 120), fill: solidPaint(0xFFFF0000'u32))
  let b = ShapeData(path: rectPath(80, 80, 180, 180), fill: solidPaint(0xFF0000FF'u32))
  let regs = shapeRegions([a, b], 200, 200)
  doAssert regs[50 * 200 + 50] == 1 and regs[100 * 200 + 100] == 3 and regs[150 * 200 + 150] == 2 and regs[5] == 0
  let r = buildShapes([a, b], 200, 200, merge = [(50.0, 50.0), (100.0, 100.0)], remove = [(150.0, 150.0)])
  doAssert r.merged.subs.len >= 1 and r.rest.len == 2
  doAssert r.rest[0].subs.len == 0, "a: all of it merged"
  doAssert r.rest[1].subs.len == 0, "b: its overlap merged, the rest taken away"
  let px = drawnShapes(@[ShapeData(path: r.merged, fill: solidPaint(0xFF000000'u32))], 200, 200)
  doAssert (px[100 * 200 + 100] and 255) < 60 and (px[50 * 200 + 50] and 255) < 60 and (px[150 * 200 + 150] and 255) > 200
  # nothing picked: each as it was
  let n = buildShapes([a, b], 200, 200, [], [])
  doAssert n.merged.subs.len == 0 and n.rest[0].subs.len >= 1 and n.rest[1].subs.len >= 1

block freeformGradient:
  # colors at points of the shape's box, each its own at its point, smooth between; kept
  let pts = @[(0.0, 0.0, 0xFFFF0000'u32), (1.0, 0.0, 0xFF00FF00'u32), (0.5, 1.0, 0xFF0000FF'u32)]
  doAssert freeformAt(pts, 0, 0) == 0xFFFF0000'u32 and freeformAt(pts, 1, 0) == 0xFF00FF00'u32
  let mid = freeformAt(pts, 0.5, 0.4)
  doAssert ((mid shr 16) and 255) > 20 and ((mid shr 8) and 255) > 20 and (mid and 255) > 20
  let s = ShapeData(path: rectPath(0, 0, 100, 100), fill: freeformPaint(pts))
  let px = drawnShapes(@[s], 100, 100)
  doAssert ((px[1 * 100 + 1] shr 16) and 255) > 200 and ((px[1 * 100 + 98] shr 8) and 255) > 200 and
           (px[98 * 100 + 50] and 255) > 200
  let d = newDoc(100, 100, 0xFFFFFFFF'u32)
  discard d.addShapeLayer(s)
  let tmp = getTempDir() / "retro-freeform.rpd"
  d.saveRpd(tmp)
  let back = loadRpd(tmp)
  removeFile(tmp)
  var found = false
  for L in back.layers:
    if L.isShape: found = L.shape.fill.style == 5 and L.shape.fill.points.len == 3
  doAssert found

echo "test_outlines: ok"
