## Tests of what makes the image editor's engine light and quick with many
## layers of type and shapes: a new layer takes memory only where it is
## drawn, and the composite mixes such layers only where they drew -- and
## looks the same as mixing every layer over all of the image (every way a
## layer is mixed: modes, opacity, masks, clipping, groups, effects, the
## screen's sampled view).

import std/[strutils, math]
import retroui/[photo, photoshapes, textengine]

proc rss(): int =
  ## (memory in use, MB; 0 where it cannot be read)
  try:
    for l in lines("/proc/self/status"):
      if l.startsWith("VmRSS:"): return parseInt(l.splitWhitespace()[1]) div 1024
  except CatchableError: discard

proc st(size: float): CharStyle =
  CharStyle(family: "", size: size, color: 0xFF202060'u32, hScale: 1, vScale: 1)

block memoryOfVectorLayers:
  # an A4 page at 300 ppi: a layer of it is 35 MB; twenty small shapes and ten captions take
  # far less than one each
  let d = newDoc(2480, 3508, 0xFFFFFFFF'u32)
  let before = rss()
  for k in 0 ..< 20:
    let x = 100 + (k mod 5) * 450
    let y = 100 + (k div 5) * 450
    discard d.addShapeLayer(ShapeData(path: ellipsePath(x.float, y.float, float(x + 200), float(y + 200)),
                                      fill: solidPaint(0xFFC02020'u32)))
  for k in 0 ..< 10:
    discard d.addTextLayer(newText("A caption " & $k, st(40), 200, float32(2400 + k * 90)))
  let grown = rss() - before
  when defined(useMalloc) and defined(linux):
    doAssert grown < 200, "thirty small layers took " & $grown & " MB (35 MB a full layer)"
  # drawn again where it was: what was there is cleared, nothing else touched
  let L = d.layers[3]
  d.beginStep("Move")
  d.shiftLayers(@[L], 300, 0)
  d.endStep()
  var left = 0
  for y in 0 ..< d.h:
    for x in 0 ..< 450:
      if (L.px[y * d.w + x] shr 24) != 0: inc left
  doAssert left == 0, "the shape is no longer where it was"
  echo "thirty layers of type and shapes on an A4 page at 300 ppi: ", grown, " MB"

block memoryOfPaintedLayers:
  # a layer painted in a corner takes the corner's memory: copied (Duplicate Layer) or read back
  # from its file, the copy too
  let d = newDoc(4000, 3000, 0xFFFFFFFF'u32)         # (48 MB a layer)
  let L = d.addLayer("Corner", fresh = true)
  for y in 0 ..< 200:
    for x in 0 ..< 200: L.px[y * d.w + x] = 0xFF2060C0'u32
  let before = rss()
  var copies: seq[Layer]
  for k in 0 ..< 5:
    d.cur = d.layers.find(L)
    copies.add d.duplicateLayer()
  let grown = rss() - before
  when defined(useMalloc) and defined(linux):
    doAssert grown < 60, "five copies of a painted corner took " & $grown & " MB (48 MB a full layer)"
  doAssert copies[^1].px[100 * d.w + 100] == 0xFF2060C0'u32 and copies[^1].px[2000 * d.w + 3000] == 0
  echo "five copies of a layer painted in a corner (4000 x 3000): ", grown, " MB"

proc mixed(d: Doc; spans: bool): seq[uint32] =
  compositeSpans = spans
  d.markAll()
  result = d.toBitmap(0'u32).px
  compositeSpans = true

proc sampled(d: Doc; spans: bool): seq[uint32] =
  compositeSpans = spans
  d.markAll()
  var xs, ys: seq[int32]
  # (a view at half size, a little off the image's edges: -1 there)
  for x in 0 ..< 157: xs.add int32(if -3 + x * 2 in 0 ..< d.w: -3 + x * 2 else: -1)
  for y in 0 ..< 117: ys.add int32(if -2 + y * 2 in 0 ..< d.h: -2 + y * 2 else: -1)
  d.compositeSampled(xs, ys, result)
  compositeSpans = true

block sameLookEveryWay:
  let d = newDoc(300, 220, 0xFFF0E8D8'u32)
  # a layer of pixels under all
  let P = d.addLayer("Pixels")
  for y in 0 ..< d.h:
    for x in 0 ..< d.w:
      if (x div 16 + y div 16) mod 2 == 0: P.px[y * d.w + x] = 0xFF3070C0'u32
  inc P.ver
  # shapes in several modes, at opacities, one with fill opacity
  var shapes: seq[Layer]
  for k, m in [bmNormal, bmMultiply, bmScreen, bmOverlay, bmDifference, bmLuminosity]:
    let x = 10 + k * 46
    let S = d.addShapeLayer(ShapeData(path: ellipsePath(x.float, 20, float(x + 70), 120),
                                      fill: solidPaint(0xFFE04020'u32 + uint32(k * 0x1810))), "S" & $k)
    S.mode = m
    S.opacity = 100 - k * 9
    shapes.add S
  shapes[2].fill = 60
  # a mask on a shape
  d.cur = d.layers.find(shapes[1])
  d.addLayerMask()
  for y in 0 ..< d.h:
    for x in 0 ..< 60: shapes[1].mask.px[y * d.w + x] = 0xFF000000'u32
  inc shapes[1].mask.ver
  # a layer of pixels clipped to a shape (the shape is read everywhere: it is a base)
  let base = d.addShapeLayer(ShapeData(path: rectPath(40, 140, 140, 200), fill: solidPaint(0xFF40A040'u32)), "Base")
  let C = d.addLayer("Clipped")
  for i in 0 ..< C.px.len: C.px[i] = 0xC0FFFF00'u32
  inc C.ver
  C.clipped = true
  # a shape clipped to a layer of pixels
  let P2 = d.addLayer("Under")
  for y in 150 ..< 210:
    for x in 160 ..< 290: P2.px[y * d.w + x] = 0xFF8080FF'u32
  inc P2.ver
  let S2 = d.addShapeLayer(ShapeData(path: ellipsePath(150, 130, 260, 220), fill: solidPaint(0xFF101010'u32)), "On it")
  S2.clipped = true
  S2.mode = bmSoftLight
  # type with a drop shadow and a stroke, in a group of its own (isolated), at an opacity
  let G = d.addGroup("Group")
  let T = d.addTextLayer(newText("Spans", st(44), 160, 60))
  T.fx.fx[fxDropShadow] = Effect(on: true, mode: bmMultiply, opacity: 75, color: 0xFF000000'u32,
                                 angle: 120, distance: 6, size: 5)
  T.mode = bmHardLight
  discard d.groupLayers(@[d.layers.find(T)], "Type")
  G.opacity = 80
  # text in a box, partly off the image
  var t = newText("words that go off the edge of the image", st(22), 220, 100)
  t.boxW = 140
  t.boxH = 80
  discard d.addTextLayer(t)
  let a = d.mixed(true)
  let b = d.mixed(false)
  var diff = 0
  for i in 0 ..< a.len:
    if a[i] != b[i]: inc diff
  doAssert diff == 0, $diff & " pixels differ"
  let sa = d.sampled(true)
  let sb = d.sampled(false)
  var sd = 0
  var where: seq[(int, int, uint32, uint32)]
  for i in 0 ..< min(sa.len, sb.len):
    if sa[i] != sb[i]:
      inc sd
      if where.len < 6: where.add (i mod 157, i div 157, sa[i], sb[i])
  doAssert sa.len == sb.len and sd == 0, "the screen's view is the same too: " & $sd & " " & $where
  # a shape moved: still the same both ways
  d.beginStep("Move")
  d.shiftLayers(@[shapes[0], base], 17, 11)
  d.endStep()
  doAssert d.mixed(true) == d.mixed(false)
  d.undo()
  doAssert d.mixed(true) == a, "undone: as it was"
  echo "the composite with spans is the same as without, every way"

echo "test_photospeed: ok"
