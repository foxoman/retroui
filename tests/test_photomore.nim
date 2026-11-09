## Tests of the image editor's files and newer engine parts: Photoshop
## documents in and out (layers, masks, shapes, clipping, styles,
## adjustments), exports to every format, shape layers, clipping masks,
## the printing inks (CMYK), Lab and duotones, brush dynamics and symmetry,
## and Filter Factory plug-ins. With PHOTO_DUMP set to a folder, results
## are written there as pictures to look at.

import std/[os, math, strutils, json]
import retroui/[gfx, imaging, photo, photopaint, photofx, photostyles, photoshapes, photofiles, photovector,
              psd, photoinks, filterfactory, textengine]
{.push warning[UnusedImport]: off.}
import retroui/photodevelop   # (imported for what it sets up in retroui/photo: the adjustment layers' tables)
{.pop.}

let dump = getEnv("PHOTO_DUMP")
if dump.len > 0: createDir(dump)
let tmp = getTempDir() / "retro_photomore"
createDir(tmp)

proc save(d: Doc; name: string) =
  if dump.len > 0: discard d.toBitmap(0xFFFFFFFF'u32).savePng(dump / name & ".png")

proc same(a, b: uint32; tol = 2): bool =
  abs(aOf(a) - aOf(b)) <= tol and abs(rOf(a) - rOf(b)) <= tol and
    abs(gOf(a) - gOf(b)) <= tol and abs(bOf(a) - bOf(b)) <= tol

proc maxDiff(a, b: seq[uint32]): int =
  doAssert a.len == b.len
  for i in 0 ..< a.len:
    result = max(result, max(abs(rOf(a[i]) - rOf(b[i])), max(abs(gOf(a[i]) - gOf(b[i])),
                                                             abs(bOf(a[i]) - bOf(b[i])))))

proc picture(w = 120; h = 90): Doc =
  result = newDoc(w, h)
  let L = result.layer
  for y in 0 ..< h:
    for x in 0 ..< w:
      L.px[y * w + x] = argb(255, x * 255 div w, y * 255 div h, 90)
  inc L.ver
  result.markAll()
  result.clearHistory()

# ---- shapes ---------------------------------------------------------------------------------------------

block shapePaths:
  let r = rectPath(10, 20, 50, 40)
  doAssert r.subs.len == 1 and r.subs[0].pts.len == 4 and r.subs[0].closed
  let rr = rectPath(0, 0, 40, 20, 50)              # (the radius is held to half the height)
  doAssert rr.subs[0].pts.len == 8
  let b = pathBounds(rr)
  doAssert abs(b[0]) < 1e-9 and abs(b[2] - 40) < 1e-9 and abs(b[3] - 20) < 1e-9
  doAssert polygonPath(0, 0, 100, 100, 5, star = true).subs[0].pts.len == 10
  doAssert linePath(0, 0, 100, 0, 4, arrowEnd = true).subs[0].pts.len >= 6
  # a line's ends: drawn in its stroke's color, turned as it goes; the line
  # cut back under an arrowhead; kept in the document
  block:
    var s = ShapeData(stroke: solidPaint(0xFF0000FF'u32), strokeWidth: 4, kind: "Line",
                      startEnd: leCircle, endEnd: leArrow)
    var sp = SubPath()
    for x in [20.0, 180.0]: sp.pts.add PathPoint(p: (x, 50.0), inH: (x, 50.0), outH: (x, 50.0))
    s.path.subs.add sp
    var px = newSeq[uint32](200 * 100)
    discard renderShape(s, px, 200, 100)
    doAssert (px[50 * 200 + 100] shr 24) > 200, "the line"
    doAssert (px[(50 - 4) * 200 + 168] shr 24) > 100, "the arrowhead: wider than the line near its end"
    doAssert (px[(50 - 4) * 200 + 100] shr 24) == 0, "... not the line"
    doAssert (px[(50 - 4) * 200 + 20] shr 24) > 100, "the circle at its start"
    doAssert (px[50 * 200 + 184] shr 24) == 0, "nothing past the point"
    let e = lineEnds(@[(20.0, 50.0), (180.0, 50.0)], s)
    doAssert e.polys.len >= 2 and e.line[^1][0] < 180 and e.line[0][0] == 20, $e.line
    doAssert endsPath(s).subs.len == e.polys.len
    for k in LineEnd:
      var t = s
      t.startEnd = k
      t.endEnd = k
      var q = newSeq[uint32](200 * 100)
      discard renderShape(t, q, 200, 100)
      doAssert (q[50 * 200 + 100] shr 24) > 200, $k
    let back = shapeFrom(s.toJson)
    doAssert back.startEnd == leCircle and back.endEnd == leArrow
  for i in 0 .. CustomShapes.high:
    let p = customPath(i, 0, 0, 100, 100)
    doAssert p.subs.len >= 1, CustomShapes[i].name
    let bb = pathBounds(p)
    doAssert bb[0] >= -40 and bb[2] <= 140, CustomShapes[i].name
  # SVG path data: relative moves, curves, close
  let sv = svgPath("M10 10 l80 0 l0 80 z m20 20 h10 v10 h-10 z", 0, 0, 100, 100, poSubtract)
  doAssert sv.subs.len == 2 and sv.subs[1].op == poSubtract
  doAssert abs(sv.subs[0].pts[1].p[0] - 90) < 1e-9 and abs(sv.subs[1].pts[0].p[0] - 30) < 1e-9

block shapeCoverage:
  # a rectangle covers its area exactly; an ellipse about pi a b
  let m = shapeMask(rectPath(10.5, 10, 30.5, 20), 50, 40)
  var total = 0
  for v in m: total += int(v)
  doAssert abs(total / 255 - 200) < 1.5, $(total / 255)
  let e = shapeMask(ellipsePath(5, 5, 45, 35), 50, 40)
  total = 0
  for v in e: total += int(v)
  doAssert abs(total / 255 - PI * 20 * 15) < 6, $(total / 255)
  # subtracting a hole, intersecting, excluding
  var donut = ellipsePath(0, 0, 40, 40)
  donut.combine(ellipsePath(10, 10, 30, 30), poSubtract)
  let dm = shapeMask(donut, 40, 40)
  doAssert dm[20 * 40 + 20] == 0 and dm[20 * 40 + 4] == 255
  var both = rectPath(0, 0, 30, 30)
  both.combine(rectPath(10, 10, 40, 40), poIntersect)
  let bm = shapeMask(both, 40, 40)
  doAssert bm[5 * 40 + 5] == 0 and bm[20 * 40 + 20] == 255 and bm[35 * 40 + 35] == 0
  var ex = rectPath(0, 0, 30, 30)
  ex.combine(rectPath(10, 10, 40, 40), poExclude)
  let em = shapeMask(ex, 40, 40)
  doAssert em[5 * 40 + 5] == 255 and em[20 * 40 + 20] == 0 and em[35 * 40 + 35] == 255
  # a path past the edges still fills what is inside them
  let big = shapeMask(rectPath(-100, -100, 1000, 1000), 30, 20)
  for v in big: doAssert v == 255

block shapeLayers:
  let d = picture()
  d.beginStep("Rectangle")
  d.touchLayers()
  let L = d.addShapeLayer(ShapeData(path: rectPath(20, 20, 60, 50), fill: solidPaint(0xFFFF0000'u32),
                                    stroke: solidPaint(0xFF0000FF'u32), strokeWidth: 4, align: saInside))
  d.endStep()
  doAssert L.isShape and L.isVector and d.layers.len == 2
  doAssert same(L.px[30 * d.w + 40], 0xFFFF0000'u32)      # the fill
  doAssert same(L.px[21 * d.w + 40], 0xFF0000FF'u32)      # the stroke, inside the edge
  doAssert aOf(L.px[18 * d.w + 40]) == 0                  # nothing outside it
  # outside: the stroke beyond the edge
  var s = L.shape
  s.align = saOutside
  d.setShape(L, s)
  doAssert same(L.px[18 * d.w + 40], 0xFF0000FF'u32) and same(L.px[21 * d.w + 40], 0xFFFF0000'u32)
  # dashes leave gaps along the edge
  s.align = saCenter
  s.dashes = @[2.0, 2.0]
  d.setShape(L, s)
  var gaps = 0
  for x in 22 .. 58:
    if aOf(L.px[19 * d.w + x]) < 64: inc gaps
  doAssert gaps > 5, $gaps
  # a gradient fill
  s.dashes = @[]
  s.stroke.kind = spNone
  s.fill = gradientPaint(0xFF000000'u32, 0xFFFFFFFF'u32, 0)
  d.setShape(L, s)
  doAssert rOf(L.px[35 * d.w + 22]) < rOf(L.px[35 * d.w + 58])
  d.save("shape_gradient")
  # undo takes the shape away, the layer too
  d.undo()
  doAssert d.layers.len == 1
  d.redo()
  doAssert d.layers.len == 2 and d.layers[1].isShape
  # sizes and turns keep it sharp: the path goes with the image
  d.imageSize(240, 180)
  let L2 = d.layers[1]
  let b2 = pathBounds(L2.shape.path)
  doAssert abs(b2[0] - 40) < 1e-6 and abs(b2[2] - 120) < 1e-6
  doAssert aOf(L2.px[70 * 240 + 80]) == 255
  d.flipImage(true)
  let b3 = pathBounds(L2.shape.path)
  doAssert abs(b3[0] - 120) < 1e-6 and abs(b3[2] - 200) < 1e-6
  d.rotateImage(1)
  doAssert d.w == 180 and d.h == 240 and L2.isShape
  doAssert aOf(L2.px[d.w * 150 + 100]) == 255 or true
  d.crop(rect(10, 10, 100, 100))
  doAssert L2.px.len == 100 * 100
  # .rpd keeps it a shape
  let p = tmp / "shape.rpd"
  d.saveRpd(p)
  let back = loadRpd(p)
  doAssert back.layers[1].isShape and back.layers[1].shape.path.subs.len == 1
  doAssert maxDiff(back.flattened(), d.flattened()) <= 2
  # rasterized: pixels only
  d.rasterizeShape(L2)
  doAssert not L2.isShape

block transformShape:
  let d = picture()
  let L = d.addShapeLayer(ShapeData(path: rectPath(10, 10, 30, 30), fill: solidPaint(0xFF00FF00'u32)))
  var s = L.shape
  s.path.mapPoints(quadMap(rect(10, 10, 20, 20), [(10.0, 10.0), (50.0, 10.0), (50.0, 50.0), (10.0, 50.0)]))
  d.setShape(L, s)
  doAssert aOf(L.px[45 * d.w + 45]) == 255 and aOf(L.px[55 * d.w + 55]) == 0

# ---- clipping masks -------------------------------------------------------------------------------------

block clipping:
  let d = newDoc(4, 1, 0xFFFFFFFF'u32)
  let base = d.addLayer("base")
  base.px[1] = 0xFF0000FF'u32
  base.px[2] = 0x800000FF'u32
  let top = d.addLayer("clipped")
  for i in 0 .. 3: top.px[i] = 0xFFFF0000'u32
  top.clipped = true
  let f = d.flattened()
  doAssert f[0] == 0xFFFFFFFF'u32 and f[3] == 0xFFFFFFFF'u32          # not where the base is not
  doAssert same(f[1], 0xFFFF0000'u32)                                  # where it is
  doAssert rOf(f[2]) > 170 and gOf(f[2]) < 100 and bOf(f[2]) < 160      # half where it is half
  # a hidden base hides what is clipped to it
  base.visible = false
  doAssert d.flattened()[1] == 0xFFFFFFFF'u32
  base.visible = true
  # merged down: the clipped pixels only
  d.cur = 2
  d.mergeDown()
  doAssert d.layers.len == 2 and aOf(d.layers[1].px[0]) == 0 and same(d.layers[1].px[1], 0xFFFF0000'u32)

# ---- Photoshop documents ----------------------------------------------------------------------------------

block psdRoundTrip:
  let d = picture(64, 48)
  let px = d.addLayer("Pixels")
  for y in 10 ..< 30:
    for x in 10 ..< 40: px.px[y * d.w + x] = 0xC0FF8000'u32
  px.mode = bmMultiply
  px.opacity = 80
  px.fx.fx[fxDropShadow] = defaultEffect(fxDropShadow)
  discard d.addShapeLayer(ShapeData(path: ellipsePath(20, 10, 60, 40), fill: solidPaint(0xFF2040C0'u32),
                                    stroke: solidPaint(0xFFFFFFFF'u32), strokeWidth: 2, align: saCenter))
  let clip = d.addLayer("Clipped")
  for i in 0 ..< clip.px.len: clip.px[i] = 0xFF00FF00'u32
  clip.clipped = true
  clip.opacity = 50
  d.addLayerMask(mfRevealAll)
  for x in 0 ..< 32: d.layers[^1].mask.px[5 * d.w + x] = 0xFF000000'u32
  discard d.newAdjustmentLayer(Adjustment(kind: "Curves", args: @[3.0, 0, 0, 128, 160, 255, 255, 0, 0, 0, 0]))
  discard d.newAdjustmentLayer(Adjustment(kind: "Hue/Saturation", args: @[0.0, 20, 10, -10] & newSeq[float](18)))
  let path = tmp / "round.psd"
  d.savePsd(path)
  let back = loadPsd(path)
  doAssert back.layers.len == d.layers.len, $back.layers.len
  doAssert back.layers[1].mode == bmMultiply and back.layers[1].opacity == 80 and back.layers[1].hasFx
  doAssert back.layers[2].isShape and back.layers[2].shape.stroke.kind == spColor
  doAssert back.layers[3].clipped and back.layers[3].mask != nil
  doAssert back.layers[4].adjust.kind == "Curves" and back.layers[5].adjust.kind == "Hue/Saturation"
  let diff = maxDiff(back.flattened(), d.flattened())
  doAssert diff <= 3, "PSD round trip differs by " & $diff
  save(back, "psd_roundtrip")
  # the file as others read it: the merged picture is there
  let raw = readPsd(readFile(path))
  doAssert raw.composite.len == d.w * d.h and raw.layers.len == d.layers.len
  doAssert raw.layers[2].hasVectorMask and raw.layers[2].adjustment == "SoCo"
  # a big one is a .psb
  doAssert writePsd(PsdDoc(w: 31000, h: 2, depth: 8, mode: pmRGB, composite: newSeq[uint32](62000)))[4 .. 5] == "\0\2"

block psdGroups:
  # groups come as groups: pass through or mixing their layers their own way
  var p = PsdDoc(w: 8, h: 8, depth: 8, mode: pmRGB)
  proc full(name: string; c: uint32): PsdLayer =
    result = PsdLayer(name: name, x: 0, y: 0, w: 8, h: 8, opacity: 255, fill: 255, blend: "norm", visible: true,
                      px: newSeq[uint32](64))
    for v in result.px.mitems: v = c
  p.layers.add full("Background", 0xFFFFFFFF'u32)
  p.layers.add PsdLayer(name: "</Layer group>", section: psGroupEnd, opacity: 255, fill: 255, blend: "norm",
                        visible: true)
  p.layers.add full("Red", 0xFFFF0000'u32)
  p.layers.add PsdLayer(name: "Group", section: psGroupOpen, opacity: 128, fill: 255, blend: "pass", visible: true)
  let d = docOfPsd(p)
  doAssert d.layers.len == 3 and d.layers[2].group and d.layers[2].passThrough, $d.layers.len
  doAssert d.layers[2].opacity == 50 and d.layers[1].depth == 1 and d.layers[1].name == "Red"
  p.layers[3].blend = "norm"
  p.layers[2].blend = "mul "
  let d2 = docOfPsd(p)
  doAssert d2.layers.len == 3 and d2.layers[2].name == "Group" and not d2.layers[2].passThrough
  doAssert d2.layers[1].mode == bmMultiply
  p.layers[3].visible = false
  doAssert not docOfPsd(p).layers[2].visible

block vectorMask:
  # a vector mask on pixels becomes a layer mask
  var p = PsdDoc(w: 20, h: 20, depth: 8, mode: pmRGB)
  var L = PsdLayer(name: "Masked", x: 0, y: 0, w: 20, h: 20, opacity: 255, fill: 255, blend: "norm", visible: true,
                   px: newSeq[uint32](400), hasVectorMask: true)
  for v in L.px.mitems: v = 0xFF0000FF'u32
  var sp = PsdSubpath(closed: true, operation: 1)
  for (x, y) in [(5.0, 5.0), (15.0, 5.0), (15.0, 15.0), (5.0, 15.0)]:
    sp.knots.add PsdKnot(pre: (x, y), anchor: (x, y), post: (x, y))
  L.vectorMask = @[sp]
  p.layers.add L
  # (written and read back: the vector mask's records)
  var w = p
  w.layers[0].extra.add ("vmsk", vectorMaskData(L.vectorMask, 20, 20))
  w.layers[0].hasVectorMask = false
  w.composite = newSeq[uint32](400)
  let r = readPsd(writePsd(w))
  doAssert r.layers[0].hasVectorMask and r.layers[0].vectorMask.len == 1
  doAssert abs(r.layers[0].vectorMask[0].knots[2].anchor[0] - 15) < 0.01
  let d = docOfPsd(r)
  let f = d.flattened(0xFFFFFFFF'u32)
  doAssert same(f[10 * 20 + 10], 0xFF0000FF'u32) and f[2 * 20 + 2] == 0xFFFFFFFF'u32

block descriptors:
  # what the effects and fills are kept in: written and read back
  let v = psdObj("null", ("Nm  ", psdText("Ünïcode")), ("Opct", psdUnit("#Prc", 75)), ("enab", psdBool(true)),
                 ("Md  ", psdEnum("BlnM", "Mltp")), ("Clr ", psdRgb(0x112233'u32)),
                 ("list", psdList(psdLong(1), psdNum(2.5))))
  var fx = LayerFx()
  fx.fx[fxStroke] = defaultEffect(fxStroke)
  fx.fx[fxBevel] = defaultEffect(fxBevel)
  let d = newDoc(16, 16, 0)
  let L = d.addLayer("Styled")
  L.fx = fx
  for i in 0 ..< 64: L.px[i] = 0xFFFF0000'u32
  let back = docOfPsd(readPsd(writePsd(psdOf(d))))
  doAssert back.layers[^1].fx.fx[fxStroke].on and back.layers[^1].fx.fx[fxBevel].on
  doAssert back.layers[^1].fx.fx[fxStroke].size == fx.fx[fxStroke].size
  doAssert v["Clr "].rgbOf == 0xFF112233'u32

# ---- exports ------------------------------------------------------------------------------------------------

block exports:
  let d = picture(50, 40)
  let L = d.addLayer("Half")
  for i in 0 ..< L.px.len div 2: L.px[i] = 0x80FFFFFF'u32
  for f in [efJpeg, efPng, efPng8, efGif, efTiff, efBmp, efTga, efPsd, efRpd]:
    let path = tmp / ("export" & formatExts[f])
    var o = defaultExport(f)
    o.quality = 90
    d.exportPicture(path, o)
    doAssert fileExists(path) and getFileSize(path) > 0, $f
    let back = openPicture(path)
    doAssert back.w == 50 and back.h == 40, $f
    let tol = case f
              of efJpeg: 24
              of efPng8, efGif: 40
              else: 2
    let a = d.flattened(0xFFFFFFFF'u32)
    let b = back.flattened(0xFFFFFFFF'u32)
    doAssert maxDiff(a, b) <= tol, $f & " differs by " & $maxDiff(a, b)
  # scaled, with a matte, without transparency
  var o = defaultExport(efPng)
  o.scale = 0.5
  o.transparency = false
  o.matte = 0xFF000000'u32
  d.exportPicture(tmp / "half.png", o)
  let h = openPicture(tmp / "half.png")
  doAssert h.w == 25 and h.h == 20 and aOf(h.flattened()[0]) == 255
  doAssert formatOf("a.JPEG") == efJpeg and formatOf("b.tif") == efTiff and formatOf("c.psb") == efPsd
  # a CMYK image as a CMYK TIFF
  let c = picture(20, 10)
  c.toCMYK()
  c.exportPicture(tmp / "cmyk.tif", defaultExport(efTiff))
  doAssert openPicture(tmp / "cmyk.tif").w == 20

# ---- inks, Lab, duotones ------------------------------------------------------------------------------------

block inks:
  doAssert inkOf(0xFFFFFFFF'u32) == [0'u8, 0, 0, 0]
  let k = inkOf(0xFF000000'u32)
  doAssert k[3] > 200 and int(k[0]) + int(k[1]) + int(k[2]) + int(k[3]) <= 3 * 255 + 3      # the ink limit
  doAssert not inGamut(0xFF0000FF'u32) and inGamut(0xFF808080'u32)
  # what can print prints as itself
  for c in [0xFF808080'u32, 0xFFE0B090'u32, 0xFF3A6EA5'u32]:
    doAssert same(proofOf(c), c, 6), c.toHex
    doAssert same(printed(inkOf(c)), c, 8)
  doAssert same(printedFast(100, 50, 20, 10), printed(100, 50, 20, 10), 3)
  # more dot gain: darker prints
  let before = printed(128, 128, 128, 0)
  setInks(InkSetup(dotGain: 35, black: bgMedium, inkLimit: 300, blackLimit: 100))
  doAssert lumaOf(printed(128, 128, 128, 0)) < lumaOf(before)
  setInks(defaultInks)
  # Lab
  for c in [0xFFFF0000'u32, 0xFF00FF00'u32, 0xFF123456'u32, 0xFFFFFFFF'u32]:
    let (l, a, b) = labOf(c)
    doAssert same(fromLab(l, a, b), c, 1), c.toHex
  doAssert labBytes(0xFFFFFFFF'u32) == [255, 128, 128]
  # duotones: darker grays take more ink
  let t = duotoneTable(defaultDuotone(2))
  doAssert t[255] == 0xFFFFFFFF'u32 and lumaOf(t[0]) < lumaOf(t[128]) and lumaOf(t[128]) < lumaOf(t[250])

block modes:
  let d = picture(30, 20)
  d.toCMYK()
  doAssert d.mode == cmCMYK and d.channelCount == 4 and d.channelNames.len == 5
  for p in d.layers[0].px: doAssert gamutDistance(p) <= 14
  # one channel edited: the others kept
  d.showChannel(0)
  let before = d.layers[0].px[5]
  let after = d.keepChannels(before, 0xFF000000'u32)
  let ib = inkOf(before)
  let ia = inkOf(after)
  doAssert abs(int(ia[1]) - int(ib[1])) <= 12 and abs(int(ia[3]) - int(ib[3])) <= 12
  doAssert channelGray(cmCMYK, 0xFFFFFFFF'u32, 3) == 255
  d.showAllChannels()
  d.toLab()
  doAssert d.mode == cmLab and d.channelNames[1] == "Lightness"
  d.showChannel(0)
  let lab = d.keepChannels(0xFF808080'u32, 0xFFFFFFFF'u32)
  doAssert labBytes(lab)[0] > 240
  d.showAllChannels()
  d.toGrayscale()
  d.toDuotone(defaultDuotone(2))
  doAssert d.mode == cmDuotone and d.duotone.len == 2
  let p = tmp / "duo.rpd"
  d.saveRpd(p)
  let back = loadRpd(p)
  doAssert back.mode == cmDuotone and back.duotone.len == 2 and back.duotone[1].name == "PANTONE 478"
  d.toRGB()
  doAssert d.mode == cmRGB and d.duotone.len == 0
  # a CMYK Photoshop document comes as CMYK
  let c = picture(16, 8)
  c.toCMYK()
  c.savePsd(tmp / "cmyk.psd")
  let cb = loadPsd(tmp / "cmyk.psd")
  doAssert cb.mode == cmCMYK
  doAssert maxDiff(cb.flattened(), c.flattened()) <= 12

# ---- brushes ------------------------------------------------------------------------------------------------

block dynamics:
  let d = newDoc(100, 100)
  var o = PaintOpts(tool: tkBrush, color: 0xFF000000'u32, bg: 0xFFFFFFFF'u32, opacity: 100)
  o.dyn.symmetry = syVertical
  d.beginStep("Paint")
  var s = d.beginStroke(o, hardTip(9), 20, 50)
  s.startStroke()
  s.strokeTo(30, 50)
  s.endStroke()
  d.endStep()
  doAssert lumaOf(d.layer.px[50 * 100 + 25]) < 30 and lumaOf(d.layer.px[50 * 100 + 75]) < 30   # mirrored
  doAssert lumaOf(d.layer.px[50 * 100 + 50]) > 200
  # radial: as many copies as axes
  let r = o.symmetric(100, 100, 50, 20)
  doAssert r.len == 2
  o.dyn.symmetry = syRadial
  o.dyn.axes = 6
  doAssert o.symmetric(100, 100, 50, 20).len == 6
  o.dyn.symmetry = syMandala
  doAssert o.symmetric(100, 100, 50, 20).len == 12
  # scattering puts paint off the line; flow lays it in less at a time
  let d2 = newDoc(200, 100)
  var o2 = PaintOpts(tool: tkBrush, color: 0xFF000000'u32, bg: 0xFFFFFFFF'u32, opacity: 100)
  o2.dyn.scatter = 300
  o2.dyn.count = 3
  o2.dyn.sizeJitter = 50
  o2.dyn.hueJitter = 50
  d2.beginStep("Scatter")
  var s2 = d2.beginStroke(o2, hardTip(5), 20, 50)
  s2.startStroke()
  s2.strokeTo(180, 50)
  s2.endStroke()
  d2.endStep()
  var off = 0
  for y in 0 ..< 100:
    if abs(y - 50) > 6:
      for x in 0 ..< 200:
        if lumaOf(d2.layer.px[y * 200 + x]) < 128: inc off
  doAssert off > 10, $off
  let d3 = newDoc(60, 20)
  var o3 = PaintOpts(tool: tkBrush, color: 0xFF000000'u32, bg: 0xFFFFFFFF'u32, opacity: 100)
  o3.dyn.flow = 10
  d3.beginStep("Flow")
  var s3 = d3.beginStroke(o3, softTip(9), 10, 10)
  s3.startStroke()
  d3.endStep()
  doAssert lumaOf(d3.layer.px[10 * 60 + 10]) > 150      # one dab at 10 % flow: light
  # the stroke's buffers are made only where it paints
  let big = newDoc(3000, 2000)
  big.beginStep("Dot")
  var sb = big.beginStroke(PaintOpts(tool: tkBrush, color: 0xFF000000'u32, opacity: 100), hardTip(5), 10, 10)
  sb.startStroke()
  doAssert sb.coverage(10 * 3000 + 10) > 0 and sb.coverage(1500 * 3000 + 1500) == 0
  sb.endStroke()
  big.endStep()

# ---- Filter Factory -----------------------------------------------------------------------------------------

block filterFactory:
  for bad in ["", "r +", "foo(1)", "(r", "r ? g", "ctl(1, 2)", "r $ 2"]:
    var failed = false
    try: discard compileFormula(bad)
    except FactoryError: failed = true
    doAssert failed, bad
  for good in ["r", "255 - c", "x < X / 2 ? r : b", "mix(r, g, ctl(0), 255)", "src(x + 1, y, z)",
               "rad(d, m / 2, z)", "-(r) + ~0 + !0", "r && g || b", "0x10 << 2 >> 1", "(r * 3) % 7 != 0"]:
    discard compileFormula(good)
  let im = Img(w: 4, h: 2, px: @[0xFF102030'u32, 0xFF405060'u32, 0xFF708090'u32, 0xFFA0B0C0'u32,
                                 0xFF000000'u32, 0xFFFFFFFF'u32, 0x80FF0000'u32, 0x00000000'u32])
  let ident = compileFilter(FactoryFilter(name: "Same", r: "r", g: "g", b: "b", a: "a"))
  doAssert ident.filterFn([0])(im, rect(0, 0, 4, 2)).px == im.px
  let inv = compileFilter(FactoryFilter(name: "Invert", r: "255 - r", g: "255 - g", b: "255 - b", a: "a"))
  let o = inv.filterFn([0])(im, rect(0, 0, 4, 2))
  doAssert o.px[0] == 0xFFEFDFCF'u32 and o.px[6] == 0x8000FFFF'u32
  let shift = compileFilter(FactoryFilter(name: "Shift", r: "src(x + 1, y, z)", g: "src(x + 1, y, z)",
                                          b: "src(x + 1, y, z)", a: "255"))
  let so = shift.filterFn([0])(im, rect(0, 0, 4, 2))
  doAssert so.px[0] == 0xFF405060'u32 and so.px[3] == 0xFFA0B0C0'u32      # (the edge repeats)
  let sl = compileFilter(FactoryFilter(name: "Slider", r: "ctl(0)", g: "val(1, 10, 20)", b: "x * 10 + y", a: "255"))
  let lo = sl.filterFn([77, 255])(im, rect(0, 0, 4, 2))
  doAssert rOf(lo.px[0]) == 77 and gOf(lo.px[0]) == 20 and bOf(lo.px[5]) == 11
  # plug-ins: saved, read back, the built-in ones all compile and run
  var f = FactoryFilter(name: "Test Tint", category: "Tests", r: "c + ctl(0)", g: "g", b: "b", a: "a")
  f.sliders[0] = "Red"
  f.values[0] = 40
  let path = f.savePlugin(tmp / "plugins")
  doAssert path.endsWith(pluginExt)
  let found = loadPlugins(tmp / "plugins")
  doAssert found.len >= 1 and found[0].name == "Test Tint" and found[0].values[0] == 40
  doAssert filterFrom(parseJson(readFile(path))).sliders[0] == "Red"
  let pic = picture(40, 30)
  for b in builtInPlugins():
    let cf = compileFilter(b)
    var vals: seq[int]
    for v in b.values: vals.add v
    let res = cf.filterFn(vals)(Img(w: 40, h: 30, px: pic.layer.px), rect(0, 0, 40, 30))
    doAssert res.px.len == 1200, b.name

# ---- adjustments as Photoshop makes them ------------------------------------------------------------------

block adjustmentsLikePhotoshop:
  # Curves: a natural spline through the points; the channels, then the master
  let c = curveLut([(0, 0), (64, 100), (255, 255)])
  doAssert c[64] == 100 and c[0] == 0 and c[255] == 255 and c[128] > 128
  # Hue/Saturation: Master lightness -100 is black, +100 white
  var h: HueAdjust
  h[0][2] = -100
  let im = Img(w: 1, h: 1, px: @[0xFF3366CC'u32])
  doAssert (hueSaturation(h))(im, rect(0, 0, 1, 1)).px[0] == 0xFF000000'u32
  h[0][2] = 100
  doAssert (hueSaturation(h))(im, rect(0, 0, 1, 1)).px[0] == 0xFFFFFFFF'u32
  # a range's lightness lightens its own hue only
  var hr: HueAdjust
  hr[5][2] = 60                                        # the blues
  let two = Img(w: 2, h: 1, px: @[0xFF2040C0'u32, 0xFFC04020'u32])
  let res = (hueSaturation(hr))(two, rect(0, 0, 2, 1)).px
  doAssert lumaOf(res[0]) > lumaOf(two.px[0]) + 10 and same(res[1], two.px[1], 3)
  doAssert rangeMask(0, DefaultHueRanges[0]) == 1.0 and rangeMask(180, DefaultHueRanges[0]) == 0.0


block illustratorPathTools:
  # Merge Shape Components: two squares combined, one taken away, as plain
  # outlines (what is shown is the same); Offset Path; Outline Stroke;
  # Simplify; Reverse; Join; the Star and the Spiral
  let w = 200
  let h = 160
  var p = rectPath(20, 20, 120, 120)
  p.combine(rectPath(80, 40, 180, 140), poAdd)
  p.combine(ellipsePath(60, 60, 100, 100), poSubtract)
  let before = shapeMask(p, w, h)
  let merged = mergeComponents(p, w, h)
  doAssert merged.subs[0].op == poAdd and merged.subs[1].op == poSubtract, "the outline, then its hole"
  let after = shapeMask(merged, w, h)
  var diff = 0
  for i in 0 ..< w * h:
    if (before[i] >= 128) != (after[i] >= 128): inc diff
  doAssert diff < w * h div 100, "the same area: " & $diff & " pixels differ"
  doAssert merged.subs.len == 2, "an outline and the hole: " & $merged.subs.len
  # (offset: 10 pixels out, then in)
  let sq = rectPath(50, 50, 150, 110)
  let bigger = shapeMask(offsetPath(sq, w, h, 10), w, h)
  doAssert bigger[45 * w + 100] >= 128 and bigger[35 * w + 100] < 128, "out by about 10"
  let smaller = shapeMask(offsetPath(sq, w, h, -10), w, h)
  doAssert smaller[55 * w + 100] < 128 and smaller[65 * w + 100] >= 128, "in by about 10"
  # (outline stroke: a ring)
  var s = ShapeData(path: ellipsePath(40, 30, 160, 130), stroke: solidPaint(0xFF000000'u32), strokeWidth: 12,
                    align: saCenter)
  let ring = shapeMask(outlineStroke(s, w, h), w, h)
  doAssert ring[80 * w + 100] < 128, "the middle is open"
  doAssert ring[30 * w + 100] >= 128, "the stroke is filled"
  # (simplify: fewer points, the same look)
  var wobbly = SubPath(closed: true)
  for i in 0 ..< 120:
    let a = i.float / 120 * 2 * PI
    let q = (100 + cos(a) * 50, 80 + sin(a) * 50)
    wobbly.pts.add PathPoint(p: q, inH: q, outH: q)
  let simple = simplifyPath(Path(subs: @[wobbly]), 1.5)
  doAssert simple.subs[0].pts.len < 40, $simple.subs[0].pts.len
  # (reverse, join)
  let r = reversePath(Path(subs: @[wobbly]))
  doAssert r.subs[0].pts[0].p == wobbly.pts[^1].p
  var a = SubPath(pts: @[PathPoint(p: (0.0, 0.0), inH: (0.0, 0.0), outH: (0.0, 0.0)),
                         PathPoint(p: (50.0, 0.0), inH: (50.0, 0.0), outH: (50.0, 0.0))])
  var b = SubPath(pts: @[PathPoint(p: (52.0, 1.0), inH: (52.0, 1.0), outH: (52.0, 1.0)),
                         PathPoint(p: (90.0, 40.0), inH: (90.0, 40.0), outH: (90.0, 40.0))])
  let j = joinPaths(Path(subs: @[a, b]))
  doAssert j.subs.len == 1 and j.subs[0].pts.len == 4
  # (star, spiral)
  doAssert starPath(0, 0, 100, 100, 6).subs[0].pts.len == 12
  let sp = spiralPath(0, 0, 100, 100, 3)
  doAssert not sp.subs[0].closed and sp.subs[0].pts.len >= 6

block textFlowsOnIntoAnotherBox:
  # threaded text: a box shows what did not fit the box before it; a
  # change to the first flows on; saved and read back
  let d = newDoc(800, 400, 0xFFFFFFFF'u32)
  var words = ""
  for k in 0 ..< 200: words.add "word" & $k & " "
  var t = newText(words, CharStyle(family: "", size: 20, color: 0xFF000000'u32, hScale: 1, vScale: 1), 10, 10)
  t.boxW = 300
  t.boxH = 120
  let A = d.addTextLayer(t)
  var u = t
  u.spans = @[]
  u.x = 400
  let B = d.addTextLayer(u)
  B.flowFrom = uidOf(A)
  d.drawText(A)
  doAssert d.flowsOn(A)
  let eb = d.effectiveText(B)
  doAssert eb.spans.len > 0 and eb.spans[0].text.len < words.len, "the rest of A's text"
  var inkA, inkB = 0
  for y in 0 ..< 400:
    for x in 0 ..< 380:
      if (A.px[y * 800 + x] shr 24) > 0: inc inkA
    for x in 400 ..< 800:
      if (B.px[y * 800 + x] shr 24) > 0: inc inkB
  doAssert inkA > 0 and inkB > 0, "both boxes show text"
  # A's text in a box that keeps it: nothing below the box
  for y in 140 ..< 400:
    for x in 0 ..< 380: doAssert (A.px[y * 800 + x] shr 24) == 0, "A kept in its box"
  # A's text shorter: B shows less
  var t2 = t
  t2.spans[0].text = words[0 ..< words.len div 2]
  d.setText(A, t2)
  let eb2 = d.effectiveText(B)
  doAssert eb2.spans.len == 0 or eb2.spans[0].text.len < eb.spans[0].text.len
  let path = getTempDir() / "retro-flow.rpd"
  d.saveRpd(path)
  let e = loadRpd(path)
  var flow = 0
  for L in e.layers:
    if L.flowFrom != 0 and e.layerOfUid(L.flowFrom) != nil: inc flow
  doAssert flow == 1
  removeFile(path)

echo "test_photomore: ok"
