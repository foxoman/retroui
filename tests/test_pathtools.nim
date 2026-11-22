## Tests of the drawing program's tools and live shapes: `retroui/pathtools`
## (Scissors, Knife, Path Eraser, Smooth, Join, the Eraser and the Blob
## Brush on shapes, the Magic Wand's and Group Selection's picking, points
## in a lasso; Arc, the grids, Flare), `retroui/liveeffects` (every effect,
## the path left as it was), and a shape's brush, width profile and
## Appearance items as they are drawn, saved and exported (SVG, PDF parts).

import std/[math, strutils]
import retroui/[photo, photoshapes, pathtools, liveeffects, pathbrush, photosvg, photovector]

proc openLine(x0, y0, x1, y1: float): Path =
  var sp = SubPath()
  for (x, y) in [(x0, y0), (x1, y1)]: sp.pts.add PathPoint(p: (x, y), inH: (x, y), outH: (x, y))
  Path(subs: @[sp])

let circle = ellipsePath(0, 0, 100, 100)

block pieces:
  # a piece of a curve: its ends on the curve, the curve between as it was
  let sp = circle.subs[0]
  let half = piece(sp, 0, 2)
  doAssert half.pts.len == 3 and half.pts[0].p == sp.pts[0].p and half.pts[^1].p == sp.pts[2].p
  let mid = piece(sp, 0.5, 1.5)
  doAssert mid.pts.len == 3
  # round past the end of a closed one
  let wrap = piece(sp, 3.5, 4.5)
  doAssert wrap.pts.len == 3 and wrap.pts[1].p == sp.pts[0].p

block scissors:
  let o = cutAt(circle, 0, 1.5)
  doAssert o.subs.len == 1 and not o.subs[0].closed and o.subs[0].pts.len == 6
  doAssert hypot(o.subs[0].pts[0].p[0] - o.subs[0].pts[^1].p[0], o.subs[0].pts[0].p[1] - o.subs[0].pts[^1].p[1]) < 1e-6
  let l = cutAt(openLine(0, 0, 100, 0), 0, 0.25)
  doAssert l.subs.len == 2 and l.subs[0].pts[^1].p == l.subs[1].pts[0].p and l.subs[0].pts[^1].p[0] in 10.0 .. 30.0
  doAssert circle.nearestPlace(100, 50, 3).sub == 0

block pathEraser:
  let e = erasePath(openLine(0, 50, 100, 50), @[(50.0, 40.0), (50.0, 60.0)], 5)
  doAssert e.subs.len == 2 and e.subs[0].pts[^1].p[0] < 46 and e.subs[1].pts[0].p[0] > 54
  let top = erasePath(circle, @[(50.0, -10.0), (50.0, 10.0)], 6)
  doAssert top.subs.len == 1 and not top.subs[0].closed
  doAssert erasePath(circle, @[(500.0, 500.0)], 5) == circle, "not touched: as it was"

block smooth:
  var z = SubPath()
  for i in 0 .. 20:
    let q = (i.float * 5, 50.0 + (if i mod 2 == 0: 3.0 else: -3.0))
    z.pts.add PathPoint(p: q, inH: q, outH: q)
  let sm = smoothPath(Path(subs: @[z]), @[(0.0, 50.0), (100.0, 50.0)], 10, 4)
  doAssert sm.subs[0].pts.len < 5, $sm.subs[0].pts.len
  # part of it: the rest left as it was, joined to the smooth part
  let part = smoothPath(Path(subs: @[z]), @[(60.0, 50.0), (100.0, 50.0)], 6, 3)
  doAssert part.subs.len == 1 and part.subs[0].pts[0].p == z.pts[0].p and part.subs[0].pts.len < z.pts.len

block join:
  let a = openLine(0, 50, 100, 50)
  let b = openLine(100.5, 50, 200, 50)
  let j = joinEnds(a, 0, true, b, 0, false)
  doAssert j.path.subs[0].pts.len == 3 and j.path.subs[0].pts[^1].p == (200.0, 50.0), "close ends: one point"
  let far = joinEnds(a, 0, true, openLine(150, 80, 200, 80), 0, true)
  doAssert far.path.subs[0].pts.len == 4 and far.path.subs[0].pts[^1].p == (150.0, 80.0), "the far end comes last"
  let c = joinEnds(a, 0, true, Path(), -1, false)
  doAssert c.closed and c.path.subs[0].closed
  doAssert openEnds(a).len == 2 and openEnds(circle).len == 0

block knifeEraserBlob:
  let pcs = knifeCut(circle, @[(-10.0, 50.0), (110.0, 50.0)])
  doAssert pcs.len == 2
  let (_, ay0, _, ay1) = pathBounds(pcs[0])
  let (_, by0, _, by1) = pathBounds(pcs[1])
  doAssert (ay1 < 52 and by0 > 48) or (by1 < 52 and ay0 > 48), "a top half and a bottom half"
  doAssert knifeCut(circle, @[(-10.0, -50.0), (110.0, -50.0)]).len == 1, "not across it: as it was"
  let er = eraseShape(circle, @[(50.0, -10.0), (50.0, 110.0)], 8)
  doAssert er.subs.len == 2
  let blob = blobMerge(Path(), @[(10.0, 10.0), (90.0, 10.0)], 5)
  let (x0, y0, x1, y1) = pathBounds(blob)
  doAssert x0 < 6 and x1 > 94 and y0 < 6 and y1 > 14
  let more = blobMerge(blob, @[(50.0, 10.0), (50.0, 80.0)], 5)
  doAssert pathBounds(more)[3] > 84 and more.subs.len == 1, "one shape"

block picking:
  var d = newDoc(200, 100)
  let a = d.addShapeLayer(ShapeData(path: rectPath(0, 0, 20, 20), fill: solidPaint(0xFFFF0000'u32)))
  let b = d.addShapeLayer(ShapeData(path: rectPath(30, 0, 50, 20), fill: solidPaint(0xFFF81010'u32)))
  let c = d.addShapeLayer(ShapeData(path: rectPath(60, 0, 80, 20), fill: solidPaint(0xFF0000FF'u32)))
  let like = d.similarShapes(a)
  doAssert a in like and b in like and c notin like
  doAssert d.similarShapes(a, tolerance = 4).len == 1
  doAssert d.groupOfLayer(c) == @[c]
  a.picked = true
  b.picked = true
  discard d.groupLayers(@[d.layers.find(a), d.layers.find(b)], "G")
  let g = d.groupOfLayer(a)
  doAssert a in g and b in g and c notin g
  let pts = anchorsIn(rectPath(0, 0, 20, 20), @[(-5.0, -5.0), (25.0, -5.0), (25.0, 5.0), (-5.0, 5.0)])
  doAssert pts.len == 2

block illustratorShapes:
  let arc = arcPath(0, 0, 100, 50)
  doAssert arc.subs[0].pts.len == 2 and not arc.subs[0].closed and pathBounds(arc) == (0.0, 0.0, 100.0, 50.0)
  doAssert arcPath(0, 0, 100, 50, closed = true).subs[0].closed
  let g = rectGridPath(0, 0, 100, 100, 4, 3)
  doAssert g.subs.len == 1 + 3 + 2
  let pg = polarGridPath(0, 0, 100, 100, 3, 6)
  doAssert pg.subs.len == 4 + 6
  let fl = flareShapes(50, 50, 200, 200, 20, rays = 12, rings = 5)
  doAssert fl.len == 3 + 5 and fl[1].path.subs[0].pts.len == 24

block liveEffects:
  let sq = rectPath(0, 0, 100, 100)
  for k in LiveEffectKind:
    let e = defaultLiveEffect(k)
    let r = applyEffects(sq, @[e])
    doAssert r.subs.len >= 1, $k
    if k notin {leFreeDistort, leTransform}: doAssert r != sq, $k & " changed nothing"
  # Repeat: radial, grid, mirror -- copies of the one path
  doAssert applyEffects(sq, @[LiveEffect(kind: leRepeatRadial, copies: 6, amount: 200)]).subs.len == 6
  doAssert applyEffects(sq, @[LiveEffect(kind: leRepeatGrid, copies: 3, detail: 2, dx: 10, dy: 10)]).subs.len == 6
  let mir = applyEffects(sq, @[LiveEffect(kind: leRepeatMirror, dx: 20)])
  doAssert mir.subs.len == 2 and abs(pathBounds(mir)[2] - 240) < 1e-6, $pathBounds(mir)
  # off: as it was; one after another
  var off = defaultLiveEffect(leZigZag)
  off.off = true
  doAssert applyEffects(sq, @[off]) == sq
  doAssert applyEffects(sq, @[LiveEffect(kind: leTransform, sx: 100, sy: 100, copies: 3, dx: 10)]).subs.len == 4
  let fd = applyEffects(sq, @[LiveEffect(kind: leFreeDistort, corners: [(10.0, 0.0), (0.0, 0.0), (0.0, 0.0), (0.0, 0.0)])])
  doAssert abs(fd.subs[0].pts[0].p[0] - 10) < 1e-6
  # a shape's effects are drawn; its path is left as it was
  var s = ShapeData(path: sq, fill: solidPaint(0xFF000000'u32), effects: @[LiveEffect(kind: leWarp, style: 0, amount: 60)])
  var px = newSeq[uint32](300 * 300)
  let moved = translated(sq, 100, 100)
  s.path = moved
  discard renderShape(s, px, 300, 300)
  doAssert s.path == moved
  var flatPx = newSeq[uint32](300 * 300)
  discard renderShape(ShapeData(path: moved, fill: solidPaint(0xFF000000'u32)), flatPx, 300, 300)
  doAssert px != flatPx and (px[150 * 300 + 150] shr 24) > 0, "bent: not as the square, its middle still in it"
  # subdivided keeps the curve
  let sub = subdivided(circle, 3)
  doAssert sub.subs[0].pts.len == 12 and pathBounds(sub) == pathBounds(circle)

block brushesWidthsAppearance:
  var sp = SubPath()
  sp.pts.add PathPoint(p: (20.0, 100.0), inH: (20.0, 100.0), outH: (80.0, 20.0))
  sp.pts.add PathPoint(p: (180.0, 100.0), inH: (120.0, 180.0), outH: (180.0, 100.0))
  let curve = Path(subs: @[sp])
  proc cover(s: ShapeData): int =
    var px = newSeq[uint32](200 * 200)
    discard renderShape(s, px, 200, 200)
    for c in px:
      if (c shr 24) > 127: inc result
  let plain = ShapeData(path: curve, stroke: solidPaint(0xFF000000'u32), strokeWidth: 8, fill: ShapePaint(kind: spNone))
  var wide = plain
  wide.widths = @[WidthPoint(t: 0, w: 1), WidthPoint(t: 0.5, w: 3), WidthPoint(t: 1, w: 1)]
  doAssert cover(wide) > cover(plain) * 3 div 2, "wider in the middle"
  doAssert widthAt(wide.widths, 0.25) == 2
  var nib = plain
  nib.brush = StrokeBrush(kind: sbCalligraphic, angle: 0, roundness: 10)
  doAssert cover(nib) < cover(plain), "a flat nib: thinner where the line runs along it"
  var art = plain
  art.brush = strokeBrushOf("Leaves")
  doAssert art.brush.kind == sbScatter and cover(art) > 0
  var ap = plain
  ap.appearance = @[Appearance(kind: apStroke, paint: solidPaint(0xFFFF0000'u32), width: 20, align: saCenter,
                               opacity: 100, below: true)]
  doAssert cover(ap) > cover(plain) * 2
  # the parts a file is given: plain fills and strokes
  for s in [wide, nib, art, ap]:
    for (part, op, mode) in exportParts(s):
      doAssert part.isPlain and part.widths.len == 0 and part.brush.kind == sbNone
  doAssert plain.isPlain and not wide.isPlain
  # kept in the document's file: all of it
  var full = plain
  full.brush = strokeBrushOf("Chain")
  full.widths = wide.widths
  full.effects = @[defaultLiveEffect(leRoughen)]
  full.appearance = ap.appearance
  full.appearance[0].effects = @[defaultLiveEffect(leOffset)]
  let back = shapeFrom(full.toJson)
  doAssert back.brush.kind == sbPattern and back.brush.art.subs.len == full.brush.art.subs.len
  doAssert back.widths == full.widths and back.effects.len == 1 and back.effects[0].kind == leRoughen
  doAssert back.appearance.len == 1 and back.appearance[0].width == 20 and back.appearance[0].effects[0].kind == leOffset
  # SVG: a group of paths for it
  var d = newDoc(200, 200)
  discard d.addShapeLayer(art)
  let svg = d.svgOf()
  doAssert "<g" in svg and svg.count("<path") >= 2

block meshTool:
  var p = meshPaint(1, 1, [0xFFFFFFFF'u32])
  doAssert p.meshCols == 2 and p.meshRows == 2
  let i = p.meshAddLines(0.3, 0.6, 0xFFFF0000'u32)
  doAssert p.meshCols == 3 and p.meshRows == 3 and i == 4
  doAssert p.points[i].color == 0xFFFF0000'u32 and abs(p.points[i].x - 0.3) < 1e-9 and abs(p.points[i].y - 0.6) < 1e-9
  doAssert p.meshNearest(0.31, 0.61, 0.05) == i and p.meshNearest(0.5, 0.1, 0.01) < 0
  doAssert p.meshAddLines(1.5, 0.5, 0) == -1, "outside the mesh"
  p.meshRemoveAt(i)
  doAssert p.meshCols == 2 and p.meshRows == 2
  # drawn: the red where its point was
  let s = ShapeData(path: rectPath(0, 0, 100, 100), fill: block:
    var q = meshPaint(1, 1, [0xFFFFFFFF'u32])
    discard q.meshAddLines(0.5, 0.5, 0xFFFF0000'u32)
    q)
  var px = newSeq[uint32](100 * 100)
  discard renderShape(s, px, 100, 100)
  doAssert ((px[50 * 100 + 50] shr 16) and 255) > 200 and ((px[50 * 100 + 50] shr 8) and 255) < 80
  doAssert ((px[1 * 100 + 1] shr 8) and 255) > 200, "its corner still white"

block snapsSpineCornersScribble:
  # Smart Guides' tangent and perpendicular; Replace Spine; Stylize > Round Corners, Scribble
  let circle = ellipsePath(100, 100, 200, 200)
  let sq = rectPath(300, 100, 400, 200)
  # (from (250, 300): the foot on the square's bottom side, straight up)
  let perp = snapTangentPerp([sq], (350.0, 300.0), (352.0, 203.0), 8)
  doAssert perp.kind == "perpendicular" and abs(perp.p[0] - 350) < 0.5 and abs(perp.p[1] - 200) < 0.5, $perp
  # (from far left of the circle: its top touching point)
  let anchor = (150.0 - 300.0, 150.0)
  let tan = snapTangentPerp([circle], anchor, (140.0, 101.0), 10)
  doAssert tan.kind == "tangent", $tan
  let dx = tan.p[0] - 150
  let dy = tan.p[1] - 150
  let rx = tan.p[0] - anchor[0]
  let ry = tan.p[1] - anchor[1]
  doAssert abs(dx * rx + dy * ry) / (hypot(dx, dy) * hypot(rx, ry)) < 0.06, "the radius at a right angle to the line"
  doAssert snapTangentPerp([sq], (350.0, 300.0), (10.0, 10.0), 8).kind == "", "nothing near"
  # Replace Spine: three shapes along a straight spine, evenly apart, the ends at its ends
  var spine = Path(subs: @[SubPath(pts: @[PathPoint(p: (0.0, 500.0), inH: (0.0, 500.0), outH: (0.0, 500.0)),
                                          PathPoint(p: (400.0, 500.0), inH: (400.0, 500.0), outH: (400.0, 500.0))])])
  let dots = @[ShapeData(path: ellipsePath(0, 0, 20, 20)), ShapeData(path: ellipsePath(50, 50, 70, 70)),
               ShapeData(path: ellipsePath(90, 0, 110, 20))]
  let along = alongSpine(dots, spine)
  for k, sh in along:
    let (x0, y0, x1, y1) = pathBounds(sh.path)
    doAssert abs((x0 + x1) / 2 - 200.0 * k.float) < 0.5 and abs((y0 + y1) / 2 - 500) < 0.5, $k
  # Round Corners: a square's corners curved, its size kept within
  let rc = roundCorners(rectPath(0, 0, 100, 100), 20)
  doAssert rc.subs[0].pts.len == 8, $rc.subs[0].pts.len
  let (bx0, by0, bx1, by1) = pathBounds(rc)
  doAssert bx0 >= -0.01 and by0 >= -0.01 and bx1 <= 100.01 and by1 <= 100.01
  # Scribble: the inside as lines across it, within the shape
  let sc = scribble(rectPath(0, 0, 200, 100), spacing = 10, width = 2, angle = 30, variation = 0)
  doAssert sc.subs.len > 0
  let (sx0, sy0, sx1, sy1) = pathBounds(sc)
  doAssert sx0 > -15 and sy0 > -15 and sx1 < 215 and sy1 < 115, $(sx0, sy0, sx1, sy1)

block selectSameAndAlign:
  # Select > Same; Align to a key object, to the artboard; Distribute Spacing by a value
  let d = newDoc(800, 600, 0xFFFFFFFF'u32)
  var red = ShapeData(kind: "Rectangle", fill: solidPaint(0xFFFF0000'u32), stroke: solidPaint(0xFF000000'u32),
                      strokeWidth: 2)
  red.path = rectPath(10, 10, 60, 60)
  let A = d.addShapeLayer(red, "a")
  red.path = rectPath(200, 100, 260, 180)
  let B = d.addShapeLayer(red, "b")
  var blue = ShapeData(kind: "Ellipse", fill: solidPaint(0xFF0000FF'u32), stroke: solidPaint(0xFF000000'u32),
                       strokeWidth: 4)
  blue.path = ellipsePath(400, 300, 500, 380)
  let C = d.addShapeLayer(blue, "c")
  doAssert d.selectSame(A, sbFillColor) == @[A, B]
  doAssert d.selectSame(A, sbStrokeColor).len == 3
  doAssert d.selectSame(C, sbStrokeWeight) == @[C]
  doAssert d.selectSame(A, sbShapeKind) == @[A, B]
  doAssert d.selectSame(A, sbFillAndStroke) == @[A, B]
  B.opacity = 50
  doAssert d.selectSame(A, sbAppearance) == @[A]
  B.opacity = 100
  let ia = d.layers.find(A)
  let ib = d.layers.find(B)
  let ic = d.layers.find(C)
  # (the key object stays; the others line up with it)
  let kb = d.alignBox(@[ia, ib, ic], atKeyObject, B)
  doAssert kb == d.contentBounds(B)
  let bBefore = d.contentBounds(B)
  d.alignLayers(@[ia, ib, ic], alTop, kb)
  doAssert d.contentBounds(B) == bBefore and d.contentBounds(A).y == bBefore.y and d.contentBounds(C).y == bBefore.y
  doAssert d.alignBox(@[ia], atArtboard) == d.bounds
  # spaced 20 apart across, out from the key object
  d.distributeSpacing(@[ia, ib, ic], 20, horizontal = true, key = B)
  let ra = d.contentBounds(A)
  let rb = d.contentBounds(B)
  let rc = d.contentBounds(C)
  doAssert rb == bBefore, "the key stays"
  doAssert ra.x + ra.w + 20 == rb.x and rb.x + rb.w + 20 == rc.x, $(ra, rb, rc)

block isolationAndDrawModes:
  let d = newDoc(400, 300, 0xFFFFFFFF'u32)
  var s = ShapeData(kind: "Rectangle", fill: solidPaint(0xFF00AA00'u32))
  s.path = rectPath(10, 10, 100, 100)
  let A = d.addShapeLayer(s, "a")
  s.path = rectPath(150, 10, 250, 100)
  let B = d.addShapeLayer(s, "b")
  d.isolate([A])
  doAssert d.inIsolation(A) and not d.inIsolation(B)
  doAssert d.selectSame(A, sbFillColor) == @[A], "what is not isolated is not picked"
  d.exitIsolation()
  doAssert d.inIsolation(B)
  # Draw Behind: a new shape under everything (over the Background)
  d.drawMode = dmBehind
  s.path = rectPath(20, 20, 40, 40)
  let C = d.addShapeLayer(s, "behind")
  doAssert d.layers.find(C) == 1 and d.layers[0].background
  # Draw Inside: a new one inside B, clipped to it
  d.drawMode = dmInside
  d.drawInto = B.uidOf
  s.path = rectPath(200, 50, 300, 150)
  let D = d.addShapeLayer(s, "inside")
  doAssert D.clipped and d.layers.find(D) == d.layers.find(B) + 1
  d.drawMode = dmNormal
  s.path = rectPath(0, 0, 5, 5)
  let E = d.addShapeLayer(s, "normal")
  doAssert not E.clipped and d.layers.find(E) == d.layers.high

block pixelGridAndStrokeGradients:
  # Align to Pixel Grid: straight sides on whole pixels (an odd stroke on the middle of one)
  var s = ShapeData(kind: "Rectangle", fill: solidPaint(0xFF000000'u32))
  s.path = rectPath(10.3, 20.6, 50.4, 70.2)
  alignToPixels(s)
  let (x0, y0, x1, y1) = pathBounds(s.path)
  doAssert (x0, y0, x1, y1) == (10.0, 21.0, 50.0, 70.0), $(x0, y0, x1, y1)
  s.stroke = solidPaint(0xFFFF0000'u32)
  s.strokeWidth = 1
  s.align = saCenter
  s.path = rectPath(10.3, 20.6, 50.4, 70.2)
  alignToPixels(s)
  doAssert pathBounds(s.path)[0] == 10.5
  let curve = ellipsePath(0.3, 0.3, 40.7, 40.7)
  var e = ShapeData(kind: "Ellipse", fill: solidPaint(0xFF000000'u32), path: curve)
  alignToPixels(e)
  doAssert e.path == curve, "curves as they are"
  let d = newDoc(200, 100, 0xFFFFFFFF'u32)
  d.pixelAlign = true
  var r = ShapeData(kind: "Rectangle", fill: solidPaint(0xFF000000'u32))
  r.path = rectPath(5.4, 5.4, 30.6, 30.6)
  let L = d.addShapeLayer(r)
  doAssert pathBounds(L.shape.path) == (5.0, 5.0, 31.0, 31.0)
  # a gradient along a line: red at its start, blue at its end; across: red on one side, blue on the other
  var g = ShapeData(kind: "Line", stroke: ShapePaint(kind: spGradient, color: 0xFFFF0000'u32,
                                                      color2: 0xFF0000FF'u32, onStroke: 1), strokeWidth: 20)
  g.path = openLine(10, 50, 190, 50)
  var px = newSeq[uint32](200 * 100)
  discard renderShape(g, px, 200, 100)
  let a = px[50 * 200 + 15]
  let b = px[50 * 200 + 185]
  doAssert ((a shr 16) and 255) > 200 and (a and 255) < 50, "along: red at the start"
  doAssert ((b shr 16) and 255) < 50 and (b and 255) > 200, "along: blue at the end"
  g.stroke.onStroke = 2
  px = newSeq[uint32](200 * 100)
  discard renderShape(g, px, 200, 100)
  let up = px[42 * 200 + 100]          # (left of the way it goes: above, y down)
  let down = px[58 * 200 + 100]
  doAssert ((up shr 16) and 255) > 160 and ((down) and 255) > 160, "across: one color each side"
  let mid = px[50 * 200 + 100]
  doAssert abs(int((mid shr 16) and 255) - int(mid and 255)) < 60, "across: between them in the middle"

block smoothCurvatureG2:
  # (an egg of four points, its handles uneven: the curve bends more on one side of each point
  # than on the other; made G2, it bends as much on both)
  var sp = SubPath(closed: true)
  sp.pts.add PathPoint(p: (100.0, 20.0), inH: (60.0, 20.0), outH: (130.0, 20.0))
  sp.pts.add PathPoint(p: (180.0, 100.0), inH: (180.0, 40.0), outH: (180.0, 150.0))
  sp.pts.add PathPoint(p: (100.0, 160.0), inH: (150.0, 160.0), outH: (70.0, 160.0))
  sp.pts.add PathPoint(p: (20.0, 100.0), inH: (20.0, 120.0), outH: (20.0, 60.0))
  let egg = Path(subs: @[sp])
  doAssert pathCurvatureJump(egg) > 0.5, "uneven before: " & $pathCurvatureJump(egg)
  let g2 = smoothCurvature(egg)
  doAssert pathCurvatureJump(g2) < 0.05, "G2: the curvature the same on both sides: " & $pathCurvatureJump(g2)
  for i in 0 ..< 4:
    let q = g2.subs[0].pts[i]
    doAssert q.p == sp.pts[i].p, "the points stay"
    let (ax, ay) = (q.outH[0] - q.p[0], q.outH[1] - q.p[1])
    let (bx, by) = (q.p[0] - q.inH[0], q.p[1] - q.inH[1])
    doAssert abs(ax * by - ay * bx) < 1e-6 * hypot(ax, ay) * hypot(bx, by) + 1e-9, "its handles in line"
  # (a corner stays a corner; an open path's ends are kept)
  var c = SubPath(closed: false)
  c.pts.add PathPoint(p: (0.0, 0.0), inH: (0.0, 0.0), outH: (30.0, 0.0))
  c.pts.add PathPoint(p: (100.0, 0.0), inH: (70.0, 0.0), outH: (100.0, 30.0))
  c.pts.add PathPoint(p: (100.0, 100.0), inH: (100.0, 70.0), outH: (100.0, 100.0))
  let k = smoothCurvature(Path(subs: @[c]))
  doAssert k.subs[0].pts == c.pts, "a corner (90 degrees) and the ends: as they were"

echo "test_pathtools: ok"
