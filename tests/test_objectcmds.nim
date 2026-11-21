## Objects as the drawing and layout programs have them: Corner Options (rounded, inverse
## rounded, inset, bevel, fancy) as a live effect, kept in the file; Release to Layers, a part a
## layer or built up; Make and Release Opacity Mask, undone; a layer copied for Paste in Front.

import std/math
import retroui/[photo, photoshapes, liveeffects, pathtools]

var failures = 0
template check(cond: bool; what: string) =
  if cond: echo "  ok   ", what
  else:
    echo "  FAIL ", what
    inc failures

block corners:
  let sq = rectPath(0, 0, 100, 100)
  check sq.subs[0].pts.len == 4, "a square: four corners"
  let r = cornerEffect(sq, 10, 0)
  check r.subs[0].pts.len == 8, "rounded: two points for each corner"
  let b = pathBounds(r)
  check abs(b[0]) < 1e-6 and abs(b[2] - 100) < 1e-6, "rounded: as wide as it was"
  let inv = cornerEffect(sq, 10, 1)
  # (the inverse round's middle bites in: its curve's handles point inside the square)
  let h = inv.subs[0].pts[0].outH
  check h[0] > 0 and h[1] > 0 and h[0] < 15 and h[1] < 15, "inverse rounded: it bites in at the corner"
  let ins = cornerEffect(sq, 10, 2)
  check ins.subs[0].pts.len == 12, "inset: three points for each corner"
  var inside = false
  for p in ins.subs[0].pts:
    if abs(p.p[0] - 10) < 1e-6 and abs(p.p[1] - 10) < 1e-6: inside = true
  check inside, "inset: a square bite, its inner corner 10 in"
  let bev = cornerEffect(sq, 10, 3)
  check bev.subs[0].pts.len == 8 and bev.subs[0].pts[0].inH == bev.subs[0].pts[0].p, "bevel: straight cuts"
  check cornerEffect(sq, 10, 4).subs[0].pts.len == 20, "fancy: a step and a curl at each corner"
  check cornerEffect(sq, 0, 2).subs[0].pts.len == 4, "size 0: as it was"
  # as a live effect, kept in the file
  let d = newDoc(200, 200, 0xFFFFFFFF'u32)
  var s = ShapeData(kind: "Rectangle", fill: solidPaint(0xFF2266AA'u32))
  s.path = rectPath(50, 50, 150, 150)
  var e = defaultLiveEffect(leCornerOptions)
  e.style = 1
  e.amount = 25
  s.effects.add e
  let L = d.addShapeLayer(s)
  check (L.px[52 * 200 + 52] shr 24) == 0 and (L.px[100 * 200 + 100] shr 24) == 255,
        "drawn: the corner bitten out, the middle filled"
  let back = shapeFrom(toJson(L.shape))
  check back.effects.len == 1 and back.effects[0].kind == leCornerOptions and back.effects[0].style == 1 and
        back.effects[0].amount == 25, "kept in the file"

block release:
  let d = newDoc(300, 100, 0xFFFFFFFF'u32)
  var s = ShapeData(kind: "Path", fill: solidPaint(0xFFCC3300'u32))
  s.path = rectPath(10, 10, 60, 60)
  s.path.subs.add rectPath(110, 10, 160, 60).subs[0]
  s.path.subs.add rectPath(210, 10, 260, 60).subs[0]
  let L = d.addShapeLayer(s, "Dots")
  d.beginStep("Release to Layers")
  d.touchLayers()
  let seqL = d.releaseToLayers(L)
  d.endStep()
  check seqL.len == 3 and L notin d.layers and seqL[0].name == "Dots 1", "Sequence: three layers, the shape gone"
  check seqL[1].shape.path.subs.len == 1 and d.layers.find(seqL[0]) < d.layers.find(seqL[2]),
        "each one part, the first lowest"
  d.undo()
  check L in d.layers and d.layers.len == 2, "undone: the shape back"
  d.beginStep("Release to Layers")
  d.touchLayers()
  let built = d.releaseToLayers(L, build = true)
  d.endStep()
  check built.len == 3 and built[0].shape.path.subs.len == 1 and built[2].shape.path.subs.len == 3,
        "Build: one more part each"
  var one = ShapeData(kind: "Rectangle", fill: solidPaint(0xFF000000'u32))
  one.path = rectPath(0, 0, 10, 10)
  check d.releaseToLayers(d.addShapeLayer(one)).len == 0, "a shape of one part: nothing to release"

block opacityMask:
  let d = newDoc(100, 100, 0xFFFFFFFF'u32)
  let art = d.addLayer("Art")
  for p in art.px.mitems: p = 0xFF0000FF'u32
  inc art.ver
  var s = ShapeData(kind: "Ellipse", fill: solidPaint(0xFFFFFFFF'u32))
  s.path = ellipsePath(25, 25, 75, 75)
  let m = d.addShapeLayer(s, "Mask")
  d.beginStep("Make Opacity Mask")
  d.touchLayers()
  check d.makeOpacityMask(art, m), "made"
  d.endStep()
  check m notin d.layers and art.mask != nil, "the white circle is the art's mask now"
  check (art.mask.px[50 * 100 + 50] and 255) == 255 and (art.mask.px[5 * 100 + 5] and 255) == 0,
        "white where the circle was, black where nothing was"
  d.updateComposite()
  let c = d.compCopy
  check (c[50 * 100 + 50] and 0xFFFFFF'u32) == 0x0000FF'u32 and (c[5 * 100 + 5] and 0xFFFFFF'u32) == 0xFFFFFF'u32,
        "the art shows in the circle only"
  d.beginStep("Release Opacity Mask")
  d.touchLayers()
  let r = d.releaseOpacityMask(art)
  d.endStep()
  check r != nil and art.mask == nil and (r.px[50 * 100 + 50] and 0xFFFFFF'u32) == 0xFFFFFF'u32 and r.px[5 * 100 + 5] == 0,
        "released: the mask a layer of its grays again"
  d.undo()
  d.undo()
  check m in d.layers and art.mask == nil, "undone both: as it was"
  check not d.makeOpacityMask(d.layers[0], art), "not on the Background"

block copyForPaste:
  let d = newDoc(50, 50, 0xFFFFFFFF'u32)
  var s = ShapeData(kind: "Rectangle", fill: solidPaint(0xFF00AA00'u32))
  s.path = rectPath(5, 5, 20, 20)
  let L = d.addShapeLayer(s, "Box")
  let c = layerCopy(L)
  check c != L and c.isShape and c.shape.path.subs.len == 1 and c.uidOf != L.uidOf and c.px == L.px,
        "a copy: the shape and its pixels, its own uid"

if failures > 0:
  echo "test_objectcmds: ", failures, " failed"
  quit(1)
echo "test_objectcmds: all passed"
