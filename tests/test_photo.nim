## Tests of the image editor's engine (retroui/photo, photopaint, photofx):
## colors and blend modes, layers, the selection, undo, painting, the
## filters and adjustments, transforms, modes and files. With PHOTO_DUMP
## set to a folder, the results are written there as pictures to look at.

import std/[os, math, strutils, times, algorithm]
import retroui/[busy, gfx, imaging, photo, photopaint, photofx, photodevelop, photosmart, photowarp, photostyles,
              textengine]

let dump = getEnv("PHOTO_DUMP")
if dump.len > 0: createDir(dump)

proc save(d: Doc; name: string) =
  if dump.len > 0: discard d.toBitmap(0xFFFFFFFF'u32).savePng(dump / name & ".png")

proc test(w = 160; h = 120): Doc =
  ## A picture with something in it: a gradient, a red disc, a blue bar.
  result = newDoc(w, h)
  let L = result.layer
  for y in 0 ..< h:
    for x in 0 ..< w:
      var c = argb(255, x * 255 div w, y * 255 div h, 128)
      if (x - w div 3) ^ 2 + (y - h div 2) ^ 2 < (h div 4) ^ 2: c = argb(255, 220, 30, 30)
      if x > w * 2 div 3 and x < w * 2 div 3 + 12: c = argb(255, 20, 40, 200)
      L.px[y * w + x] = c
  inc L.ver
  result.markAll()
  result.clearHistory()
  result.modified = false

proc same(a, b: uint32; tol = 2): bool =
  abs(aOf(a) - aOf(b)) <= tol and abs(rOf(a) - rOf(b)) <= tol and
    abs(gOf(a) - gOf(b)) <= tol and abs(bOf(a) - bOf(b)) <= tol

block colors:
  let c = argb(255, 200, 100, 50)
  doAssert rOf(c) == 200 and gOf(c) == 100 and bOf(c) == 50 and aOf(c) == 255
  doAssert argb(300, -5, 256, 10) == argb(255, 0, 255, 10), "argb clamps"
  let hsb = toHsb(c)
  doAssert same(fromHsb(hsb.h, hsb.s, hsb.b), c, 1)
  let hsl = toHsl(c)
  doAssert same(fromHsl(hsl.h, hsl.s, hsl.l), c, 1)
  let k = toCmyk(argb(255, 0, 0, 0))
  doAssert k.k > 80 and k.c + k.m + k.y + k.k <= 301          # (a rich black within the ink limit)
  doAssert toCmyk(argb(255, 255, 255, 255)) == (0, 0, 0, 0)
  doAssert lumaOf(0xFFFFFFFF'u32) == 255 and lumaOf(0xFF000000'u32) == 0

block blendModes:
  let base = argb(255, 100, 150, 200)
  let top = argb(255, 200, 100, 50)
  doAssert blendPx(base, top, 255, bmNormal) == top
  doAssert same(blendPx(base, top, 0, bmNormal), base)
  let m = blendPx(base, top, 255, bmMultiply)
  doAssert same(m, argb(255, 100 * 200 div 255, 150 * 100 div 255, 200 * 50 div 255))
  let s = blendPx(base, top, 255, bmScreen)
  doAssert rOf(s) >= 200 and gOf(s) >= 150
  doAssert blendPx(base, top, 255, bmDarken) == argb(255, 100, 100, 50)
  doAssert blendPx(base, top, 255, bmLighten) == argb(255, 200, 150, 200)
  doAssert blendPx(base, top, 255, bmDifference) == argb(255, 100, 50, 150)
  # a transparent pixel under: the paint shows as it is
  doAssert same(blendPx(0'u32, top, 255, bmMultiply), top)
  # Behind paints only where it is transparent
  doAssert blendPx(base, top, 255, bmBehind) == base
  doAssert same(blendPx(0'u32, top, 255, bmBehind), top)
  # Clear takes the pixel away
  doAssert aOf(blendPx(base, top, 255, bmClear)) == 0
  # Color keeps the base's lightness
  let col = blendPx(argb(255, 128, 128, 128), argb(255, 255, 0, 0), 255, bmColor)
  doAssert abs(lumaOf(col) - 128) <= 3 and rOf(col) > gOf(col)
  for mode in BlendMode:
    discard blendPx(base, top, 128, mode, 3, 4)
    discard blendPx(0'u32, top, 128, mode, 3, 4)
  # the newer modes, by their formulas (base 100,150,200 under 200,100,50)
  doAssert blendPx(base, top, 255, bmLinearDodge) == argb(255, 255, 250, 250)
  doAssert blendPx(base, top, 255, bmLinearBurn) == argb(255, 45, 0, 0)
  doAssert blendPx(base, top, 255, bmSubtract) == argb(255, 0, 50, 150)
  doAssert blendPx(base, top, 255, bmExclusion) == argb(255, 300 - 2 * 100 * 200 div 255, 250 - 2 * 150 * 100 div 255,
                                                         250 - 2 * 200 * 50 div 255)
  doAssert blendPx(base, top, 255, bmDivide) == argb(255, 100 * 255 div 200, 255, 255)
  doAssert blendPx(base, top, 255, bmColorDodge) == argb(255, 255, 150 * 255 div 155, 200 * 255 div 205)
  doAssert blendPx(base, top, 255, bmColorBurn) == argb(255, 255 - 155 * 255 div 200, 0, 0)
  doAssert blendPx(base, top, 255, bmHardMix) == argb(255, 255, 0, 0)
  doAssert blendPx(base, top, 255, bmPinLight) == argb(255, 144, 150, 100)
  doAssert blendPx(base, top, 255, bmDarkerColor) == top and blendPx(base, top, 255, bmLighterColor) == base
  # gray over anything: Linear Light and Vivid Light leave it (nearly) as it was
  doAssert same(blendPx(base, argb(255, 128, 128, 128), 255, bmLinearLight), base, 2)
  doAssert same(blendPx(base, argb(255, 128, 128, 128), 255, bmVividLight), base, 3)
  for mode in LayerModes: doAssert mode notin {bmBehind, bmClear}
  doAssert LayerModes.len == 27 and PaintModes.len == 29

block layersAndUndo:
  let d = test()
  doAssert d.layers.len == 1 and d.layers[0].background
  d.snapStep("New Layer")
  let L = d.addLayer("One")
  d.endStep()
  doAssert d.layers.len == 2 and d.cur == 1 and L.name == "One"
  d.beginStep("Fill")
  d.fillSelection(argb(255, 0, 255, 0), 50)
  d.endStep()
  d.updateComposite()
  let p = d.compCopy[0]
  doAssert gOf(p) > 120, "half the green over the picture"
  d.undo()
  d.updateComposite()
  doAssert d.compCopy[0] == d.layers[0].px[0], "undo took the fill back"
  d.redo()
  d.updateComposite()
  doAssert d.compCopy[0] == p
  d.undo(); d.undo()
  doAssert d.layers.len == 1, "undo took the layer back"
  d.redo()
  doAssert d.layers.len == 2
  # opacity and modes of the layer
  d.layers[1].opacity = 0
  d.markAll()
  d.updateComposite()
  doAssert d.compCopy[5] == d.layers[0].px[5]
  # merge, flatten
  d.layers[1].opacity = 100
  d.snapStep("Merge Down")
  d.mergeDown()
  d.endStep()
  doAssert d.layers.len == 1
  d.undo()
  doAssert d.layers.len == 2
  d.snapStep("Flatten")
  d.flatten()
  d.endStep()
  doAssert d.layers.len == 1 and d.layers[0].background
  # duplicate, move, delete
  d.snapStep("x")
  discard d.duplicateLayer()
  discard d.addLayer("Top")
  d.moveLayer(2, 1)
  doAssert d.layers[1].name == "Top"
  d.deleteLayer(1)
  d.endStep()
  doAssert d.layers.len == 2

block cancelling:
  # a cancelled step (an adjustment's dialog cancelled) changes nothing:
  # not the pixels, the redo steps, nor "modified"
  let d = test()
  d.beginStep("Fill")
  d.fillSelection(argb(255, 0, 0, 255))
  d.endStep()
  d.undo()
  d.modified = false
  doAssert d.canRedo
  let before = d.layer.px
  d.beginStep("Levels")
  d.touch(d.layer, d.bounds)
  for p in d.layer.px.mitems: p = 0xFF000000'u32
  d.markAll()
  d.cancelStep()
  doAssert d.layer.px == before and d.canRedo and not d.modified
  # an empty step leaves the redo steps too
  d.beginStep("Nothing")
  d.endStep()
  doAssert d.canRedo and d.undoSteps.len == 0
  # cancelling an empty step does not undo the step before
  d.redo()
  doAssert d.undoSteps.len == 1
  d.beginStep("Empty")
  d.cancelStep()
  doAssert d.undoSteps.len == 1 and d.undoName == "Fill"

block quickMaskAndSize:
  # the Quick Mask follows the image when its size changes (and back)
  let d = test()
  d.setSelection(d.rectMask(rect(10, 10, 30, 30)))
  d.enterQuickMask()
  d.snapStep("Crop")
  d.crop(rect(5, 5, 50, 40))
  d.endStep()
  doAssert d.maskLayer.px.len == d.w * d.h
  d.undo()
  doAssert d.w == 160 and d.maskLayer.px.len == d.w * d.h
  d.snapStep("Image Size")
  d.imageSize(80, 60, rsBilinear)
  d.endStep()
  doAssert d.maskLayer.px.len == 80 * 60
  d.leaveQuickMask()
  doAssert d.sel.len == 0 or d.sel.len == d.w * d.h

block masksAndAdjustments:
  let d = test(64, 48)
  let L = d.addLayer()
  for p in L.px.mitems: p = argb(255, 0, 200, 0)
  inc L.ver
  d.markAll()
  # a mask: black hides the layer there
  d.beginStep("Add Layer Mask")
  d.addLayerMask(mfRevealAll)
  d.endStep()
  doAssert L.mask != nil and L.mask.gray and L.mask.px.len == 64 * 48
  d.updateComposite()
  doAssert d.compCopy[0] == argb(255, 0, 200, 0)
  d.editMask = true
  doAssert d.layer == L.mask and d.current == L
  d.beginStep("Paint")
  d.touch(d.layer, rect(0, 0, 32, 48))
  for y in 0 ..< 48:
    for x in 0 ..< 32: d.layer.px[y * 64 + x] = grayPx(0)
  d.markDirty(rect(0, 0, 32, 48))
  d.endStep()
  d.updateComposite()
  doAssert d.compCopy[10 * 64 + 5] == d.layers[0].px[10 * 64 + 5], "hidden by the mask"
  doAssert d.compCopy[10 * 64 + 50] == argb(255, 0, 200, 0)
  # the mask off: all of it shows; undo brings the mask back as it was
  L.maskOff = true
  d.markAll()
  d.updateComposite()
  doAssert d.compCopy[10 * 64 + 5] == argb(255, 0, 200, 0)
  L.maskOff = false
  d.undo()
  doAssert rOf(L.mask.px[10 * 64 + 5]) == 255, "the painting undone"
  d.undo()
  doAssert L.mask == nil, "the mask undone"
  d.redo()
  doAssert L.mask != nil
  # painting on a mask is gray
  d.editMask = true
  d.beginStep("Brush")
  var st = d.beginStroke(PaintOpts(tool: tkBrush, color: argb(255, 255, 0, 0), opacity: 100), hardTip(5), 20, 20)
  st.startStroke()
  st.endStroke()
  d.endStep()
  let mp = L.mask.px[20 * 64 + 20]
  doAssert rOf(mp) == gOf(mp) and gOf(mp) == bOf(mp) and rOf(mp) < 255, mp.toHex
  d.editMask = false
  # the mask follows the image: size, crop, flip
  d.imageSize(32, 24, rsBilinear)
  doAssert L.mask.px.len == 32 * 24
  d.flipImage(true)
  d.crop(rect(2, 2, 20, 16))
  doAssert L.mask.px.len == 20 * 16
  # applied: the layer's alpha made by it
  d.beginStep("Apply")
  d.removeLayerMask(apply = true)
  d.endStep()
  doAssert L.mask == nil
  d.undo()
  doAssert L.mask != nil and L.mask.px.len == 20 * 16
  d.redo()
  doAssert L.mask == nil
  # an adjustment layer: what is under it changed where its mask lets
  let e = test(64, 48)
  let before = e.layers[0].px[30 * 64 + 40]
  e.beginStep("New Adjustment Layer")
  let A = e.newAdjustmentLayer(Adjustment(kind: "Invert"))
  e.endStep()
  doAssert A.adjust.kind == "Invert" and A.gray and e.layers.len == 2
  e.undo()
  doAssert e.layers.len == 1
  e.redo()
  doAssert e.layers.len == 2 and e.layers[1] == A and e.cur == 1
  e.updateComposite()
  let inv = e.compCopy[30 * 64 + 40]
  doAssert same(inv, argb(255, 255 - rOf(before), 255 - gOf(before), 255 - bOf(before)), 1), inv.toHex
  # its mask (its pixels) black: no change there
  for y in 0 ..< 48:
    for x in 0 ..< 32: A.px[y * 64 + x] = grayPx(0)
  e.markAll()
  e.updateComposite()
  doAssert e.compCopy[10 * 64 + 5] == e.layers[0].px[10 * 64 + 5]
  # the table gives what the adjustment itself gives
  let hs = Adjustment(kind: "Hue/Saturation", args: @[0.0, 30, 20, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0])
  e.setAdjustment(A, hs)
  for p in A.px.mitems: p = grayPx(255)
  A.opacity = 100
  e.markAll()
  e.updateComposite()
  let direct = adjustmentFn(hs)(Img(w: 64, h: 48, px: e.layers[0].px), rect(0, 0, 64, 48))
  for i in countup(0, 64 * 48 - 1, 37): doAssert same(e.compCopy[i], direct.px[i], 3), $i
  # half opacity: half way
  A.opacity = 50
  e.markAll()
  e.updateComposite()
  let half = e.compCopy[30 * 64 + 40]
  doAssert same(half, mix(e.layers[0].px[30 * 64 + 40], direct.px[30 * 64 + 40], 0.5), 3)
  # every kind makes a table
  for k in ["Levels", "Curves", "Brightness/Contrast", "Color Balance", "Hue/Saturation", "Selective Color",
            "Vibrance", "Exposure", "Photo Filter", "Black & White", "Channel Mixer", "Invert", "Threshold",
            "Posterize"]:
    doAssert adjustmentFn(Adjustment(kind: k)) != nil, k
  # merging down puts the adjustment in the pixels
  A.opacity = 100
  e.mergeDown()
  doAssert e.layers.len == 1 and same(e.layers[0].px[30 * 64 + 40], direct.px[30 * 64 + 40], 3)
  # saved and opened again: masks and adjustment layers are kept
  let f = newDoc(40, 30)
  let P = f.addLayer()
  for p in P.px.mitems: p = argb(255, 10, 20, 250)
  f.addLayerMask(mfHideAll)
  P.maskOff = true
  discard f.newAdjustmentLayer(Adjustment(kind: "Levels", args: @[10.0, 240, 1.2, 0, 255]))
  let path = getTempDir() / "masks_test.rpd"
  f.saveRpd(path)
  let g = openImage(path)
  doAssert g.layers.len == 3
  doAssert g.layers[1].mask != nil and g.layers[1].maskOff and rOf(g.layers[1].mask.px[0]) == 0
  doAssert g.layers[2].adjust.kind == "Levels" and g.layers[2].adjust.args[2] == 1.2 and g.layers[2].gray
  removeFile(path)

block selection:
  let d = test()
  doAssert not d.hasSelection
  d.beginStep("Marquee")
  d.touchSel()
  d.setSelection(d.rectMask(rect(10, 10, 20, 20)))
  d.endStep()
  doAssert d.hasSelection and d.selBounds == rect(10, 10, 20, 20)
  d.beginStep("Add")
  d.touchSel()
  d.setSelection(d.rectMask(rect(50, 50, 10, 10)), soAdd)
  d.endStep()
  doAssert d.selBounds == rect(10, 10, 50, 50)
  d.beginStep("Subtract")
  d.touchSel()
  d.setSelection(d.rectMask(rect(50, 50, 10, 10)), soSubtract)
  d.endStep()
  doAssert d.selBounds == rect(10, 10, 20, 20)
  d.undo()
  doAssert d.selBounds == rect(10, 10, 50, 50)
  d.redo()
  d.invertSelection()
  doAssert d.selAt(0) == 255 and d.selAt(15 * d.w + 15) == 0
  d.invertSelection()
  d.feather(3)
  doAssert d.selAt(10 * d.w + 10) in 1 .. 254, "feathered: soft at the corner"
  d.selectNone()
  doAssert not d.hasSelection
  let e = d.ellipseMask(0, 0, 40, 20, true)
  doAssert e[10 * d.w + 20] == 255 and e[0] == 0
  let poly = d.polygonMask(@[(0.0, 0.0), (40.0, 0.0), (0.0, 40.0)], false)
  doAssert poly[5 * d.w + 5] == 255 and poly[39 * d.w + 39] == 0
  # the magic wand: the red disc
  let m = d.regionMask(d.w div 3, d.h div 2, 10)
  var n = 0
  for v in m:
    if v > 128: inc n
  let disc = PI * (d.h div 4).float ^ 2
  doAssert abs(n.float - disc) < disc * 0.1, $n & " vs " & $disc
  d.setSelection(m)
  d.expandSelection(2)
  d.contractSelection(2)
  d.smoothSelection(2)
  d.borderSelection(4)
  doAssert d.hasSelection
  # channels
  d.setSelection(m)
  let ch = d.saveSelection("disc")
  d.selectNone()
  d.loadSelection(ch)
  doAssert d.hasSelection
  # Quick Mask round trip
  d.enterQuickMask()
  doAssert d.quickMask
  d.leaveQuickMask()
  doAssert not d.quickMask and d.hasSelection
  # a path from the selection, and back
  let p = d.pathFromSelection()
  doAssert p.subs.len >= 1
  let pm = d.pathMask(p)
  var both = 0
  for i in 0 ..< pm.len:
    if pm[i] > 128 and d.sel[i] > 128: inc both
  doAssert both.float > disc * 0.85

block painting:
  let d = newDoc(200, 120)
  let o = PaintOpts(tool: tkBrush, color: argb(255, 0, 0, 0), bg: 0xFFFFFFFF'u32, opacity: 100, mode: bmNormal)
  d.beginStep("Brush")
  var s = d.beginStroke(o, hardTip(9), 20, 60)
  s.startStroke()
  s.strokeTo(180, 60)
  s.endStroke()
  d.endStep()
  doAssert d.layer.px[60 * 200 + 100] == argb(255, 0, 0, 0), "a hard brush paints solid"
  doAssert d.layer.px[20 * 200 + 100] == 0xFFFFFFFF'u32
  # a soft brush reaches full strength in the middle
  d.beginStep("Soft")
  s = d.beginStroke(o, softTip(21), 20, 20)
  s.startStroke()
  s.strokeTo(180, 20)
  s.endStroke()
  d.endStep()
  doAssert lumaOf(d.layer.px[20 * 200 + 100]) < 20, $lumaOf(d.layer.px[20 * 200 + 100])
  doAssert lumaOf(d.layer.px[29 * 200 + 100]) > 60, "soft at the edge"
  # every tool runs
  for t in ToolKind:
    var o2 = o
    o2.tool = t
    o2.srcX = 10
    o2.srcY = 10
    o2.color = argb(255, 200, 0, 0)
    d.beginStep($t)
    s = d.beginStroke(o2, softTip(13), 30, 100)
    s.startStroke()
    s.strokeTo(170, 90)
    s.strokeTick()
    s.endStroke()
    d.endStep()
  # the eraser on the Background paints the background color
  d.beginStep("Erase")
  var oe = o
  oe.tool = tkEraser
  oe.bg = argb(255, 0, 255, 0)
  s = d.beginStroke(oe, hardTip(9), 100, 60)
  s.startStroke()
  s.endStroke()
  d.endStep()
  doAssert d.layer.px[60 * 200 + 100] == argb(255, 0, 255, 0)
  # the stamp From Snapshot and the eraser's Erase to Saved bring back a picture
  let snap = newDoc(60, 40)
  var saved = newSeq[uint32](60 * 40)
  for p in saved.mitems: p = argb(255, 10, 200, 30)
  var os = PaintOpts(tool: tkStamp, stamp: smFromSnapshot, saved: saved, opacity: 100, mode: bmNormal)
  snap.beginStep("Stamp")
  var st = snap.beginStroke(os, hardTip(9), 20, 20)
  st.startStroke()
  st.endStroke()
  snap.endStep()
  doAssert snap.layer.px[20 * 60 + 20] == argb(255, 10, 200, 30)
  snap.fillSelection(argb(255, 0, 0, 0))
  var oe2 = PaintOpts(tool: tkEraser, eraseToSaved: true, saved: saved, opacity: 100, mode: bmNormal)
  snap.beginStep("Erase")
  st = snap.beginStroke(oe2, hardTip(9), 40, 20)
  st.startStroke()
  st.endStroke()
  snap.endStep()
  doAssert snap.layer.px[20 * 60 + 40] == argb(255, 10, 200, 30)
  doAssert snap.layer.px[0] == argb(255, 0, 0, 0)
  # bucket, gradient, line, type
  let b = newDoc(100, 100)
  b.beginStep("Bucket")
  b.bucketFill(50, 50, o, 32, false)
  b.endStep()
  doAssert b.layer.px[0] == argb(255, 0, 0, 0)
  var og = o
  og.bg = 0xFFFFFFFF'u32
  b.gradient(0, 0, 100, 0, og, dither = false)
  doAssert lumaOf(b.layer.px[1]) < 10 and lumaOf(b.layer.px[98]) > 245
  b.gradient(50, 50, 100, 50, og, kind = gkRadial, dither = false)
  doAssert lumaOf(b.layer.px[50 * 100 + 50]) < 10
  b.drawLine(10, 90, 90, 90, 3, o, Arrowhead(atEnd: true, width: 500, length: 1000), true)
  doAssert lumaOf(b.layer.px[90 * 100 + 50]) < 30
  let tl = b.typeLayer(TypeOpts(text: "Hi", font: "Sans", size: 40, antialias: true), 10, 10, argb(255, 255, 0, 0))
  var painted = 0
  for p in tl.px:
    if aOf(p) > 0: inc painted
  doAssert painted > 100 and b.layers.len == 2
  save(d, "painting")
  save(b, "shapes")

block pathEditing:
  let d = newDoc(100, 100)
  var p = Path(name: "Work Path", subs: @[SubPath(pts: @[
    PathPoint(p: (10.0, 10.0), inH: (10.0, 10.0), outH: (40.0, 0.0)),
    PathPoint(p: (90.0, 10.0), inH: (60.0, 0.0), outH: (90.0, 10.0)),
    PathPoint(p: (50.0, 90.0), inH: (50.0, 90.0), outH: (50.0, 90.0))], closed: true)])
  let before = p.flatten(64)
  # a point put in the middle of a curve leaves the curve as it was
  let h = p.nearestSegment(50, 3, 4)
  doAssert h.sub == 0 and h.i == 0, $h
  p.addPoint(h)
  doAssert p.subs[0].pts.len == 4
  let after = p.flatten(64)
  for q in before[0]:
    var best = 1e9
    for r in after[0]: best = min(best, sqrt((q[0] - r[0]) ^ 2 + (q[1] - r[1]) ^ 2))
    doAssert best < 1.5, "the curve moved: " & $best
  doAssert p.hitPoint(90, 10, 2, handles = false).i == 2
  let hin = p.subs[0].pts[1].inH
  doAssert p.hitPoint(hin[0], hin[1], 0.5).part == 1
  p.deletePoint(0, 1)
  doAssert p.subs[0].pts.len == 3
  p.convertPoint(0, 0)
  doAssert p.subs[0].pts[0].outH == p.subs[0].pts[0].p
  # path changes are undone
  d.paths.add p
  d.curPath = 0
  d.beginStep("Pen")
  d.touchPaths()
  d.paths[0].subs[0].pts.add PathPoint(p: (5.0, 5.0), inH: (5.0, 5.0), outH: (5.0, 5.0))
  d.endStep()
  doAssert d.paths[0].subs[0].pts.len == 4 and d.modified
  d.undo()
  doAssert d.paths[0].subs[0].pts.len == 3
  d.redo()
  doAssert d.paths[0].subs[0].pts.len == 4

block warping:
  # the corners as they were: the same picture; moved: the pixels move
  let d = test(64, 48)
  let r = rect(10, 10, 20, 16)
  let same = d.warpedPixels(d.layer.px, r, @[], quadOf(r), 0xFFFFFFFF'u32)
  for y in 11 .. 24:
    for x in 11 .. 28:
      doAssert same(same[y * 64 + x], d.layer.px[y * 64 + x], 3), "warp at " & $x & "," & $y
  var q = quadOf(r)
  for c in 0 .. 3: q[c] = (q[c][0] + 20, q[c][1] + 5)
  let moved = d.warpedPixels(d.layer.px, r, @[], q, 0xFFFFFFFF'u32)
  doAssert moved[12 * 64 + 12] == 0xFFFFFFFF'u32, "what was taken up leaves the background"
  doAssert same(moved[(20 + 5) * 64 + 20 + 20], d.layer.px[20 * 64 + 20], 3)
  # a perspective: narrower at the top
  q = quadOf(r)
  q[0] = (q[0][0] + 6, q[0][1]); q[1] = (q[1][0] - 6, q[1][1])
  doAssert quadIsFine(q)
  let m = d.warpedMask(@[], r, q)
  doAssert m[11 * 64 + 12] == 0 and m[11 * 64 + 20] == 255 and m[24 * 64 + 13] == 255, $m[11 * 64 + 12] & " " & $m[11 * 64 + 20] & " " & $m[24 * 64 + 13]
  # a folded quad is refused
  var bad = quadOf(r)
  swap(bad[0], bad[1])
  doAssert not quadIsFine(bad)

block transforms:
  let d = test(64, 48)
  let corner = d.layer.px[0]
  d.flipImage(true)
  doAssert d.layer.px[63] == corner
  d.flipImage(true)
  d.rotateImage(1)
  doAssert d.w == 48 and d.h == 64
  doAssert d.layer.px[47] == corner, "the top-left corner went to the top-right"
  d.rotateImage(3)
  doAssert d.w == 64 and d.layer.px[0] == corner
  d.imageSize(32, 24, rsBicubic)
  doAssert d.w == 32 and d.h == 24 and d.layer.px.len == 32 * 24
  d.canvasSize(40, 30, 0, 0, 0xFFFFFFFF'u32)
  doAssert d.w == 40 and d.layer.px[39] == 0xFFFFFFFF'u32
  d.crop(rect(0, 0, 32, 24))
  doAssert d.w == 32 and d.h == 24
  d.rotateArbitrary(30, 0xFFFFFFFF'u32)
  doAssert d.w > 32 and d.h > 24
  # moving the selection
  let m = test(64, 48)
  m.setSelection(m.rectMask(rect(0, 0, 10, 10)))
  let p = m.layer.px[0]
  m.beginStep("Move")
  var l = m.beginMove(0xFFFFFFFF'u32)
  m.moveTo(l, 20, 5)
  m.endMove(l)
  m.endStep()
  doAssert m.layer.px[5 * 64 + 20] == p and m.layer.px[0] == 0xFFFFFFFF'u32
  m.undo()
  doAssert m.layer.px[0] == p
  # copy and paste
  m.setSelection(m.rectMask(rect(0, 0, 10, 10)))
  let c = m.copySelection()
  doAssert c.w == 10 and c.px[0] == p
  m.snapStep("Paste")
  discard m.pasteAsLayer(c)
  m.endStep()
  doAssert m.layers.len == 2 and m.layers[1].px[0] == p

block modes:
  let d = test(40, 30)
  d.toGrayscale()
  doAssert d.mode == cmGray
  for p in d.layer.px: doAssert rOf(p) == gOf(p) and gOf(p) == bOf(p)
  d.toBitmapMode(true)
  doAssert d.mode == cmBitmap
  for p in d.layer.px: doAssert rOf(p) in [0, 255]
  let e = test(40, 30)
  e.toIndexed(medianCut(e.flattened(0xFFFFFFFF'u32), 16), true)
  doAssert e.mode == cmIndexed and e.palette.len <= 16
  for p in e.layer.px: doAssert (p or 0xFF000000'u32) in e.palette
  e.toRGB()
  doAssert e.mode == cmRGB

proc runAll(d: Doc; name: string; f: FilterFn; margin = 8) =
  let before = d.layer.px
  d.beginStep(name)
  d.applyFilter(margin, f)
  d.endStep()
  save(d, "filter-" & name.replace(" ", "_").replace("/", "_").toLowerAscii)
  d.undo()
  doAssert d.layer.px == before, name & ": undo"

block filters:
  let d = test()
  let t0 = epochTime()
  let h = d.histogram()
  let all = [("Blur", blur()), ("Blur More", blurMore()), ("Gaussian Blur", gaussianBlur(3)),
             ("Motion Blur", motionBlur(30, 10)), ("Radial Blur", radialBlur(10, false)),
             ("Zoom Blur", radialBlur(20, true)),
             ("Unsharp Mask", unsharpMask(100, 2, 0)), ("Sharpen", sharpen()), ("Sharpen More", sharpenMore()),
             ("Sharpen Edges", sharpenEdges()), ("Add Noise", addNoise(40, true, false)),
             ("Median", median(2)), ("Despeckle", despeckle()), ("Dust", dustAndScratches(2, 10)),
             ("Mosaic", mosaic(8)), ("Crystallize", crystallize(10)), ("Pointillize", pointillize(6, 0xFFFFFFFF'u32)),
             ("Fragment", fragment()), ("Facet", facet()), ("Color Halftone", colorHalftone(6)),
             ("Mezzotint", mezzotint(0)), ("Pinch", pinch(60)), ("Spherize", spherize(80, 0)),
             ("Twirl", twirl(120)), ("Ripple", ripple(200, 1)), ("Wave", wave(40, 6, false)),
             ("ZigZag", zigzag(20, 5)), ("Polar", polarCoordinates(true)),
             ("Clouds", clouds(argb(255, 0, 0, 0), 0xFFFFFFFF'u32)),
             ("Difference Clouds", clouds(argb(255, 0, 0, 0), 0xFFFFFFFF'u32, difference = true)),
             ("Lens Flare", lensFlare(100, 40, 100)), ("Find Edges", findEdges()),
             ("Emboss", emboss(135, 3, 100)), ("Diffuse", diffuse(0)), ("Solarize", solarize()),
             ("Tiles", tiles(6, 10, 0xFFFFFFFF'u32)), ("Trace Contour", traceContour(128, false)),
             ("Wind", wind(false, true)), ("De-Interlace", deInterlace(true, true)), ("NTSC", ntscColors()),
             ("High Pass", highPass(4)), ("Maximum", maximum(2)), ("Minimum", minimum(2)),
             ("Offset", offsetFilter(20, 10, 2, 0)),
             ("Custom", custom([0.0, 0, 0, 0, 0, 0, 0, -1, 0, 0, 0, -1, 5, -1, 0, 0, 0, -1, 0, 0, 0, 0, 0, 0, 0], 1, 0)),
             ("Levels", applyLuts(levelsLut(Levels(inLo: 30, inHi: 220, gamma: 1.4, outLo: 0, outHi: 255)),
                                  identityLut(), identityLut(), identityLut())),
             ("Curves", applyLuts(curveLut(@[(0, 0), (64, 40), (192, 220), (255, 255)]), identityLut(),
                                  identityLut(), identityLut())),
             ("Brightness", brightnessContrast(30, 40)),
             ("Color Balance", colorBalance([0, 0, 0], [40, 0, -40], [0, 0, 0], true)),
             ("Hue Saturation", hueSaturation(60, 20, 0)), ("Colorize", hueSaturation(200, 50, 0, true)),
             ("Invert", invert()), ("Desaturate", desaturate()), ("Threshold", threshold(128)),
             ("Posterize", posterize(4)), ("Equalize", equalize(h)),
             ("Variations", variations([20, 0, -20], 10, 10, trMidtones)),
             ("Shear", shear(@[(0.0, 0.0), (0.5, 0.5), (0.0, 1.0)], true)),
             ("Shear Edge", shear(@[(-0.3, 0.0), (0.3, 1.0)], false)),
             ("Extrude Blocks", extrude(12, 30)), ("Extrude Pyramids", extrude(12, 30, pyramids = true)),
             ("Extrude Random", extrude(10, 40, randomDepth = true, frontsSolid = true)),
             ("Selective Color", selectiveColor(block:
                var a: SelectiveColor
                a[0] = [-50, 30, 0, 0]
                a[7] = [10, 0, -10, 0]
                a, true)),
             ("Selective Absolute", selectiveColor(block:
                var a: SelectiveColor
                a[8] = [0, 0, 0, 40]
                a, false))]
  for (name, f) in all: d.runAll(name, f)
  let secs = epochTime() - t0
  doAssert secs < 20, "the filters took " & $secs & " s"
  # a filter keeps to the selection
  d.setSelection(d.rectMask(rect(0, 0, 20, 20)))
  let far = d.layer.px[100 * d.w + 150]
  d.applyFilter(0, invert())
  doAssert d.layer.px[100 * d.w + 150] == far
  doAssert d.layer.px[0] != test().layer.px[0]
  # Invert twice is the same picture
  d.applyFilter(0, invert())
  doAssert d.layer.px == test().layer.px
  # the lens flare stays bright only near its middle
  let f = test(200, 200)
  f.applyFilter(0, lensFlare(100, 100, 100))
  doAssert lumaOf(f.layer.px[100 * 200 + 100]) > 240
  let far2 = test(200, 200).layer.px[100 * 200 + 190]
  let now2 = f.layer.px[100 * 200 + 190]
  doAssert lumaOf(now2) >= lumaOf(far2) and lumaOf(now2) - lumaOf(far2) < 60,
    "far from the flare the picture stays: " & $lumaOf(far2) & " -> " & $lumaOf(now2)
  # the gradient of the splash: dark at the top, warm at the bottom
  let g = newDoc(100, 100)
  g.gradient(0, 0, 0, 100, PaintOpts(color: argb(255, 20, 16, 64), bg: argb(255, 214, 96, 54), opacity: 100))
  doAssert bOf(g.layer.px[50]) > 50 and rOf(g.layer.px[99 * 100 + 50]) > 180

block medianAgainstSorting:
  # the sliding median gives what sorting each disc gives
  var im = newImg(37, 23)
  var seed = 12345'u32
  for p in im.px.mitems:
    seed = seed * 1103515245'u32 + 12345'u32
    p = 0xFF000000'u32 or (seed shr 8)
  for radius in [1, 2, 4]:
    let got = median(radius)(im, rect(0, 0, im.w, im.h))
    for y in 0 ..< im.h:
      for x in 0 ..< im.w:
        var rs, gs, bs: seq[int]
        for j in -radius .. radius:
          for i in -radius .. radius:
            if i * i + j * j > radius * radius + radius: continue
            let p = im.at(x + i, y + j)
            rs.add rOf(p); gs.add gOf(p); bs.add bOf(p)
        rs.sort(); gs.sort(); bs.sort()
        let m = rs.len div 2
        doAssert got.px[y * im.w + x] == argb(255, rs[m], gs[m], bs[m]), "median " & $radius & " at " & $x & "," & $y
  # and a big radius is quick
  let big = newImg(400, 300)
  let t1 = epochTime()
  discard median(16)(big, rect(0, 0, 400, 300))
  doAssert epochTime() - t1 < 3, "median 16 took " & $(epochTime() - t1) & " s"

block selectiveColorRanges:
  # less cyan in the reds makes a red redder; a gray is no red
  var a: SelectiveColor
  a[0] = [-100, 0, 0, 0]
  let f = selectiveColor(a, relative = false)
  var im = newImg(2, 1)
  im.px[0] = argb(255, 180, 40, 40)
  im.px[1] = argb(255, 128, 128, 128)
  let o = f(im, rect(0, 0, 2, 1))
  doAssert rOf(o.px[0]) > 180 and o.px[1] == im.px[1], $o.px[0].toHex & " " & $o.px[1].toHex
  # Shear with a straight line moves nothing
  let st = shear(@[(0.0, 0.0), (0.0, 1.0)], true)(im, rect(0, 0, 2, 1))
  doAssert st.px == im.px
  doAssert abs(shearCurve(@[(0.0, 0.0), (1.0, 0.5), (0.0, 1.0)], 0.5) - 1.0) < 1e-9

block applyAndCalculate:
  let d = test(40, 30)
  let src = newSeq[uint32](40 * 30)
  var white2 = src
  for p in white2.mitems: p = 0xFFFFFFFF'u32
  let before = d.layer.px
  d.beginStep("Apply Image")
  d.applyImage(white2, bmMultiply, 100)
  d.endStep()
  doAssert d.layer.px == before, "multiplying by white changes nothing"
  d.applyImage(white2, bmNormal, 50)
  doAssert lumaOf(d.layer.px[0]) > lumaOf(before[0])
  let a = channelOf(before, 1)
  doAssert a[0] == uint8(rOf(before[0]))
  let inv = channelOf(before, 2, invert = true)
  doAssert inv[5] == uint8(255 - gOf(before[5]))
  let m = calculate(a, a, bmDifference)
  for v in m: doAssert v == 0
  doAssert d.sourcePixels(-1).len == 40 * 30

proc refBlur(im: Img; radius: float): Img =
  ## A gaussian blur done slowly in floating point (straight colours,
  ## opaque pictures), to check the quick one against.
  let sigma = max(0.1, radius / 2)
  let r = int(ceil(sigma * 3))
  var k = newSeq[float](2 * r + 1)
  var s = 0.0
  for i in -r .. r:
    k[i + r] = exp(-(i * i).float / (2 * sigma * sigma))
    s += k[i + r]
  for v in k.mitems: v /= s
  var tmp = newSeq[array[3, float]](im.w * im.h)
  for y in 0 ..< im.h:
    for x in 0 ..< im.w:
      var a: array[3, float]
      for i in -r .. r:
        let p = im.px[y * im.w + clamp(x + i, 0, im.w - 1)]
        a[0] += k[i + r] * rOf(p).float; a[1] += k[i + r] * gOf(p).float; a[2] += k[i + r] * bOf(p).float
      tmp[y * im.w + x] = a
  result = newImg(im.w, im.h)
  for y in 0 ..< im.h:
    for x in 0 ..< im.w:
      var a: array[3, float]
      for i in -r .. r:
        let t = tmp[clamp(y + i, 0, im.h - 1) * im.w + x]
        for c in 0 .. 2: a[c] += k[i + r] * t[c]
      result.px[y * im.w + x] = argb(255, int(round(a[0])), int(round(a[1])), int(round(a[2])))

proc noisy(w, h: int; seed: uint32): Img =
  result = newImg(w, h)
  var s = seed
  for y in 0 ..< h:
    for x in 0 ..< w:
      s = s * 1103515245'u32 + 12345'u32
      let n = int((s shr 16) and 63)
      result.px[y * w + x] = argb(255, clamp(x * 255 div w + n - 32, 0, 255),
                                  clamp(y * 255 div h + n - 32, 0, 255), (x xor y) and 255)

block engineAccuracy:
  # the quick blur in whole numbers is the gaussian, to a level
  let im = noisy(97, 61, 99)
  for radius in [0.7, 1.5, 4.0, 8.0]:
    let got = gaussianBlurImg(im, radius)
    let want = refBlur(im, radius)
    var worst = 0
    for i in 0 ..< im.px.len:
      for (a, b) in [(rOf(got.px[i]), rOf(want.px[i])), (gOf(got.px[i]), gOf(want.px[i])),
                     (bOf(got.px[i]), bOf(want.px[i]))]:
        worst = max(worst, abs(a - b))
    doAssert worst <= 1, "blur " & $radius & " off by " & $worst
  # a big blur goes through a smaller picture: close to the real thing
  let big = noisy(320, 240, 7)
  for radius in [12.0, 30.0]:
    let got = gaussianBlurImg(big, radius)
    let want = refBlur(big, radius)
    var sum, worst = 0
    for i in 0 ..< big.px.len:
      let e = abs(lumaOf(got.px[i]) - lumaOf(want.px[i]))
      sum += e
      worst = max(worst, e)
    doAssert sum div big.px.len <= 2 and worst <= 12,
      "big blur " & $radius & ": mean " & $(sum div big.px.len) & ", worst " & $worst
  # transparent pixels do not darken a blur
  var edge = newImg(20, 20)
  for y in 0 ..< 20:
    for x in 0 ..< 10: edge.px[y * 20 + x] = argb(255, 250, 250, 250)
  let eb = gaussianBlurImg(edge, 3)
  doAssert aOf(eb.px[10 * 20 + 10]) in 40 .. 215 and rOf(eb.px[10 * 20 + 10]) >= 248
  # the colour table of a big picture gives what working each pixel out gives
  let photo = noisy(1000, 640, 3)
  let tile = Img(w: 50, h: 1, px: photo.px[320_000 ..< 320_050])
  for f in [hueSaturation(40, 30, -10), hueSaturation(-120, -50, 20, colorize = true),
            colorBalance([10, 0, -20], [-30, 20, 10], [0, 0, 40])]:
    let all = f(photo, rect(0, 0, photo.w, photo.h))
    let one = f(tile, rect(0, 0, 50, 1))
    for i in 0 ..< 50:
      doAssert same(all.px[320_000 + i], one.px[i], 4), all.px[320_000 + i].toHex & " " & one.px[i].toHex
  # the smaller copies of the image (the view zoomed out): each pixel is the
  # four under it, and they follow a change
  let m = newDoc(9, 6)
  for i in 0 ..< m.layer.px.len: m.layer.px[i] = argb(255, (i * 37) and 255, (i * 11) and 255, i * 4)
  m.markAll()
  let (l1, w1, h1) = m.mipLevel(1)
  doAssert w1 == 5 and h1 == 3
  let c = m.layer.px
  let want1 = (rOf(c[0]) + rOf(c[1]) + rOf(c[9]) + rOf(c[10]) + 2) div 4
  doAssert abs(rOf(l1[0]) - want1) <= 1, $rOf(l1[0]) & " vs " & $want1
  let (l2, w2, h2) = m.mipLevel(2)
  doAssert w2 == 3 and h2 == 2 and aOf(l2[0]) == 255
  m.layer.px[0] = 0xFFFFFFFF'u32
  m.layer.px[1] = 0xFFFFFFFF'u32
  m.layer.px[9] = 0xFFFFFFFF'u32
  m.layer.px[10] = 0xFFFFFFFF'u32
  inc m.layer.ver
  m.markDirty(rect(0, 0, 2, 2))
  let (l1b, _, _) = m.mipLevel(1)
  doAssert l1b[0] == 0xFFFFFFFF'u32, l1b[0].toHex
  # half transparent: the colour of what is there, not darker
  let tdoc = newDoc(4, 4, contents = 0)
  tdoc.layer.px[0] = argb(255, 200, 0, 0)
  tdoc.layer.px[1] = argb(255, 200, 0, 0)
  inc tdoc.layer.ver
  tdoc.markAll()
  let (t1, _, _) = tdoc.mipLevel(1)
  doAssert aOf(t1[0]) in 126 .. 129 and rOf(t1[0]) >= 198, t1[0].toHex

proc flat(w, h: int; c: uint32): Img =
  result = newImg(w, h)
  for p in result.px.mitems: p = c

proc meanLuma(im: Img; r: Rect): float =
  for y in r.y ..< r.y + r.h:
    for x in r.x ..< r.x + r.w: result += lumaOf(im.px[y * im.w + x]).float
  result /= float(r.w * r.h)

proc sdLuma(im: Img; r: Rect): float =
  let m = meanLuma(im, r)
  for y in r.y ..< r.y + r.h:
    for x in r.x ..< r.x + r.w: result += (lumaOf(im.px[y * im.w + x]).float - m) ^ 2
  sqrt(result / float(r.w * r.h))

proc dev(im: Img; s: Develop): Img = develop(s)(im, rect(0, 0, im.w, im.h))

block develop:
  # nothing set: the picture as it was; the colors survive the trip to
  # light and back exactly (the middle is untouched by a vignette)
  var all = newImg(256, 256)
  for y in 0 ..< 256:
    for x in 0 ..< 256: all.px[y * 256 + x] = argb(255, x, (x + y) and 255, (x * 7 + y) and 255)
  doAssert dev(all, Develop()).px == all.px
  let v = dev(all, Develop(vignette: -100))
  for y in 110 ..< 146:
    for x in 110 ..< 146: doAssert v.px[y * 256 + x] == all.px[y * 256 + x], $x & "," & $y
  doAssert lumaOf(v.px[0]) < lumaOf(all.px[0]) or lumaOf(all.px[0]) == 0
  doAssert lumaOf(v.px[255 * 256 + 255]) < lumaOf(all.px[255 * 256 + 255]) div 2
  # exposure: one stop is twice the light
  let gray = flat(32, 32, argb(255, 118, 118, 118))
  doAssert rOf(dev(gray, Develop(exposure: 100)).px[0]) in 155 .. 165
  doAssert rOf(dev(gray, Develop(exposure: -100)).px[0]) in 80 .. 90
  # white balance: warmer is redder and less blue, a gray stays as light
  let warm = dev(gray, Develop(temperature: 50)).px[0]
  doAssert rOf(warm) > 125 and bOf(warm) < 110 and abs(lumaOf(warm) - 118) <= 6, warm.toHex
  let pink = dev(gray, Develop(tint: 50)).px[0]
  doAssert gOf(pink) < rOf(pink) and gOf(pink) < bOf(pink)
  # shadows and highlights: by the light around
  var halves = newImg(200, 100)
  for y in 0 ..< 100:
    for x in 0 ..< 200:
      halves.px[y * 200 + x] = if x < 100: argb(255, 30 + (x + y) mod 7, 30, 30) else: argb(255, 215 + (x + y) mod 7, 215, 215)
  let sh = dev(halves, Develop(shadows: 60))
  let dk = rect(10, 10, 60, 80)
  let lt = rect(130, 10, 60, 80)
  doAssert meanLuma(sh, dk) > meanLuma(halves, dk) + 15, $meanLuma(sh, dk)
  doAssert abs(meanLuma(sh, lt) - meanLuma(halves, lt)) < 4
  let hl = dev(halves, Develop(highlights: -60))
  doAssert meanLuma(hl, lt) < meanLuma(halves, lt) - 15
  doAssert abs(meanLuma(hl, dk) - meanLuma(halves, dk)) < 4
  # the detail in the dark half survives lifting it
  doAssert sdLuma(sh, dk) >= sdLuma(halves, dk)
  # clarity: more local contrast in a textured middle gray; less with minus
  var tex = newImg(200, 150)
  for y in 0 ..< 150:
    for x in 0 ..< 200:
      let v2 = 128 + int(30 * sin(x.float / 3) * cos(y.float / 4))
      tex.px[y * 200 + x] = argb(255, v2, v2, v2)
  let mid = rect(40, 30, 120, 90)
  doAssert sdLuma(dev(tex, Develop(clarity: 80)), mid) > sdLuma(tex, mid) * 1.15
  doAssert sdLuma(dev(tex, Develop(clarity: -80)), mid) < sdLuma(tex, mid) * 0.85
  # dehaze: a hazy picture gets its contrast back
  var hazy = newImg(160, 120)
  for y in 0 ..< 120:
    for x in 0 ..< 160:
      let v2 = 150 + int(40 * sin(x.float / 9)) + (if y > 60: 20 else: 0)
      hazy.px[y * 160 + x] = argb(255, v2, v2 + 5, v2 + 12)
  doAssert sdLuma(dev(hazy, Develop(dehaze: 70)), rect(0, 0, 160, 120)) > sdLuma(hazy, rect(0, 0, 160, 120)) * 1.2
  # vibrance: a dull color more saturated, a vivid one about as it was
  var two = newImg(2, 1)
  two.px[0] = argb(255, 140, 120, 110)
  two.px[1] = argb(255, 30, 60, 230)
  let vb = dev(two, Develop(vibrance: 80))
  doAssert rOf(vb.px[0]) - bOf(vb.px[0]) > 30 + 8
  doAssert abs(bOf(vb.px[1]) - 230) <= 25
  doAssert dev(two, Develop(saturation: -100)).px[1].rOf == dev(two, Develop(saturation: -100)).px[1].bOf
  # contrast, whites and blacks
  let s3 = dev(all, Develop(contrast: 80))
  doAssert lumaOf(s3.px[30]) < lumaOf(all.px[30]) and lumaOf(s3.px[220]) >= lumaOf(all.px[220])
  doAssert rOf(dev(flat(4, 4, argb(255, 20, 20, 20)), Develop(blacks: 100)).px[0]) > 50
  doAssert rOf(dev(flat(4, 4, argb(255, 235, 235, 235)), Develop(whites: -100)).px[0]) < 215
  # noise reduction: a noisy flat part gets flat, an edge stays sharp
  var noisy2 = newImg(120, 80)
  var seed = 77'u32
  for y in 0 ..< 80:
    for x in 0 ..< 120:
      seed = seed * 1103515245'u32 + 12345'u32
      let n = int((seed shr 16) and 31) - 16
      let base = if x < 60: 70 else: 190
      noisy2.px[y * 120 + x] = argb(255, base + n, base + n, base + n)
  let dn = dev(noisy2, Develop(noise: 80))
  doAssert sdLuma(dn, rect(5, 5, 45, 70)) < sdLuma(noisy2, rect(5, 5, 45, 70)) * 0.6
  doAssert meanLuma(dn, rect(56, 5, 2, 70)) < 100 and meanLuma(dn, rect(62, 5, 2, 70)) > 160
  # color noise: specks of color calmed, the light kept
  var cn = flat(60, 60, argb(255, 128, 128, 128))
  for i in countup(0, cn.px.len - 1, 7): cn.px[i] = argb(255, 128 + 40, 128 - 20, 128 - 20)
  let cnd = dev(cn, Develop(colorNoise: 100))
  var worst = 0
  for p in cnd.px[600 ..< 3000]: worst = max(worst, rOf(p) - gOf(p))
  doAssert worst < 30, $worst
  # sharpening: an edge with an overshoot each side
  var edge = newImg(40, 10)
  for y in 0 ..< 10:
    for x in 0 ..< 40: edge.px[y * 40 + x] = if x < 20: argb(255, 80, 80, 80) else: argb(255, 170, 170, 170)
  let sp = dev(edge, Develop(sharpen: 100))
  doAssert lumaOf(sp.px[5 * 40 + 19]) < 80 and lumaOf(sp.px[5 * 40 + 20]) > 170
  # grain: something on a flat gray
  doAssert sdLuma(dev(flat(64, 64, argb(255, 128, 128, 128)), Develop(grain: 60)), rect(0, 0, 64, 64)) > 2
  # a part of the picture developed as it is in the whole
  let s4 = Develop(shadows: 40, highlights: -30, clarity: 30, dehaze: 20, vignette: -40, grain: 30,
                   exposure: 20, contrast: 10, vibrance: 20)
  let small = smallCopy(tex, 400)
  let b4 = developBase(small, s4, tex.w, tex.h)
  let whole = developImg(tex, s4, b4)
  var part = newImg(50, 40)
  for y in 0 ..< 40:
    for x in 0 ..< 50: part.px[y * 50 + x] = tex.px[(y + 70) * 200 + x + 90]
  let pd = developImg(part, s4, b4, 90, 70)
  for y in 0 ..< 40:
    for x in 0 ..< 50: doAssert same(pd.px[y * 50 + x], whole.px[(y + 70) * 200 + x + 90], 1)
  # Auto: a dark photo lighter, a bright one darker
  var dark = newImg(100, 80)
  for i in 0 ..< dark.px.len:
    let v2 = 10 + (i * 13) mod 50
    dark.px[i] = argb(255, v2, v2 + 3, v2)
  doAssert autoDevelop(dark).exposure > 50
  var bright = newImg(100, 80)
  for i in 0 ..< bright.px.len:
    let v2 = 190 + (i * 13) mod 60
    bright.px[i] = argb(255, v2, v2, v2)
  doAssert autoDevelop(bright).exposure < 0
  var cast2 = newImg(100, 80)
  for i in 0 ..< cast2.px.len:
    let v2 = 40 + (i * 13) mod 170
    cast2.px[i] = argb(255, min(255, v2 + 30), v2, max(0, v2 - 20))
  let ac = autoDevelop(cast2)
  doAssert ac.temperature < 0, $ac
  # the settings as text and back
  let st = Develop(exposure: -35, clarity: 20, grain: 5, temperature: -100)
  doAssert parseDevelop($st) == st
  doAssert parseDevelop("exposure=12 nonsense=4 clarity=x shadows=-7") == Develop(exposure: 12, shadows: -7)
  for (n, p) in developPresets(): doAssert not p.isNeutral and n.len > 0
  # a big picture in good time
  var bigIm = newImg(1500, 1000)
  for i in 0 ..< bigIm.px.len: bigIm.px[i] = argb(255, i and 255, (i shr 8) and 255, (i * 3) and 255)
  let t0 = epochTime()
  discard dev(bigIm, Develop(exposure: 30, shadows: 30, highlights: -30, clarity: 20, dehaze: 10,
                             vibrance: 20, noise: 30, colorNoise: 30, sharpen: 40, vignette: -20, grain: 10))
  doAssert epochTime() - t0 < (when defined(retroSanitized): 32 else: 8), "develop took " & $(epochTime() - t0)

block newAdjustments:
  # Black & White: the default weights (red 40%), a gray stays
  let bw = blackAndWhite(defaultBlackAndWhite())
  var im = newImg(3, 1)
  im.px[0] = argb(255, 255, 0, 0)
  im.px[1] = argb(255, 255, 255, 0)
  im.px[2] = argb(255, 77, 77, 77)
  let o = bw(im, rect(0, 0, 3, 1))
  doAssert rOf(o.px[0]) == 102 and gOf(o.px[0]) == 102
  doAssert rOf(o.px[1]) == 153
  doAssert o.px[2] == im.px[2]
  let tinted = blackAndWhite(defaultBlackAndWhite(), true, 30, 40)(im, rect(0, 0, 3, 1))
  doAssert rOf(tinted.px[2]) > bOf(tinted.px[2])
  # Channel Mixer: as is, swapped, gray
  let same3 = channelMixer([[100, 0, 0, 0], [0, 100, 0, 0], [0, 0, 100, 0]])(im, rect(0, 0, 3, 1))
  doAssert same3.px == im.px
  let sw = channelMixer([[0, 0, 100, 0], [0, 100, 0, 0], [100, 0, 0, 0]])(im, rect(0, 0, 3, 1))
  doAssert sw.px[0] == argb(255, 0, 0, 255)
  let mono = channelMixer([[30, 59, 11, 0], [0, 0, 0, 0], [0, 0, 0, 0]], true)(im, rect(0, 0, 3, 1))
  doAssert rOf(mono.px[0]) == gOf(mono.px[0]) and rOf(mono.px[0]) in 75 .. 78
  # Photo Filter: warmer, as light with Preserve Luminosity
  let g = flat(2, 2, argb(255, 128, 128, 128))
  let pf = photoFilter(0xFFEC8A00'u32, 50)(g, rect(0, 0, 2, 2)).px[0]
  doAssert rOf(pf) > bOf(pf) + 20 and abs(lumaOf(pf) - 128) <= 6, pf.toHex
  # Exposure: +1 stop, gamma, offset
  doAssert rOf(exposureFn(1, 0, 1)(g, rect(0, 0, 2, 2)).px[0]) in 170 .. 178
  doAssert exposureFn(0, 0, 1)(im, rect(0, 0, 3, 1)).px == im.px
  doAssert rOf(exposureFn(0, 0, 2)(g, rect(0, 0, 2, 2)).px[0]) > 160
  # Vibrance, Shadows/Highlights as filters
  doAssert vibranceFn(0, -100)(im, rect(0, 0, 3, 1)).px[0].gOf == vibranceFn(0, -100)(im, rect(0, 0, 3, 1)).px[0].rOf
  # Auto Contrast keeps the colors' balance; Auto Color makes a cast gray
  let d = newDoc(64, 64)
  for i in 0 ..< d.layer.px.len:
    let v2 = 60 + (i * 7) mod 120
    d.layer.px[i] = argb(255, min(255, v2 + 25), v2, max(0, v2 - 15))
  inc d.layer.ver
  d.markAll()
  let h = d.histogram()
  let acn = autoContrast(h)
  doAssert acn[0] == acn[1] and acn[1] == acn[2]
  let at = autoTone(h)
  doAssert at[0].inLo > at[2].inLo
  let acol = autoColor(Img(w: 64, h: 64, px: d.layer.px))
  let fixed = applyLuts(identityLut(), levelsLut(acol[0]), levelsLut(acol[1]), levelsLut(acol[2]))(
    Img(w: 64, h: 64, px: d.layer.px), rect(0, 0, 64, 64))
  var spread = 0
  for p in fixed.px[1000 ..< 1100]: spread = max(spread, max(rOf(p), bOf(p)) - min(rOf(p), bOf(p)))
  doAssert spread < 20, $spread

proc edmondsKarp(n: int; edges: seq[(int, int, float, float)]; terms: seq[(float, float)]): float =
  ## The maximum flow, slowly (to check the quick one): node n the source, n+1 the sink.
  let N = n + 2
  var cap = newSeq[seq[float]](N)
  for i in 0 ..< N: cap[i] = newSeq[float](N)
  for (i, j, a, b) in edges:
    cap[i][j] += a
    cap[j][i] += b
  for i, (s, t) in terms:
    cap[n][i] += s
    cap[i][n + 1] += t
  while true:
    var prev = newSeq[int](N)
    for v in prev.mitems: v = -1
    prev[n] = n
    var q = @[n]
    var k = 0
    while k < q.len and prev[n + 1] < 0:
      let u = q[k]
      inc k
      for v in 0 ..< N:
        if prev[v] < 0 and cap[u][v] > 1e-9:
          prev[v] = u
          q.add v
    if prev[n + 1] < 0: break
    var b = Inf
    var v = n + 1
    while v != n:
      b = min(b, cap[prev[v]][v])
      v = prev[v]
    v = n + 1
    while v != n:
      cap[prev[v]][v] -= b
      cap[v][prev[v]] += b
      v = prev[v]
    result += b

block cutGraph:
  # the quick maximum flow gives what the slow one gives
  var seed = 3'u32
  proc rnd(m: int): int =
    seed = seed * 1103515245'u32 + 12345'u32
    int((seed shr 16) mod uint32(m))
  for trial in 0 ..< 60:
    let n = 2 + rnd(14)
    var edges: seq[(int, int, float, float)]
    var terms: seq[(float, float)]
    var g = initCutGraph(n)
    for i in 0 ..< n:
      let s = float(rnd(6))
      let t = float(rnd(6))
      terms.add (s, t)
      g.addTerminal(i, s.float32, t.float32)
    for e in 0 ..< n * 2:
      let i = rnd(n)
      let j = rnd(n)
      if i == j: continue
      let a = float(rnd(5))
      let b = float(rnd(5))
      edges.add (i, j, a, b)
      g.addEdge(i, j, a.float32, b.float32)
    let want = edmondsKarp(n, edges, terms)
    let got = g.maxflow()
    doAssert abs(got - want) < 1e-3, "trial " & $trial & ": " & $got & " vs " & $want
    # the cut costs the flow
    var cost = 0.0
    for i in 0 ..< n:
      if g.sourceSide(i): cost += terms[i][1] else: cost += terms[i][0]
    for (i, j, a, b) in edges:
      if g.sourceSide(i) and not g.sourceSide(j): cost += a
      if g.sourceSide(j) and not g.sourceSide(i): cost += b
    doAssert abs(cost - want) < 1e-3, "trial " & $trial & ": cut " & $cost & " vs " & $want

block smartTools:
  # Content-Aware Fill: a hole in a regular texture made again like it
  var tex = newImg(120, 90)
  for y in 0 ..< 90:
    for x in 0 ..< 120:
      let v2 = if ((x div 6) + (y div 6)) mod 2 == 0: 200 else: 60
      tex.px[y * 120 + x] = argb(255, v2, v2 div 2 + 40, 255 - v2)
  var hole = newSeq[uint8](120 * 90)
  for y in 35 ..< 55:
    for x in 50 ..< 72: hole[y * 120 + x] = 255
  var punched = tex
  for i in 0 ..< hole.len:
    if hole[i] != 0: punched.px[i] = argb(255, 255, 0, 255)
  let t0 = epochTime()
  let filled = contentAwareFill(punched, hole)
  var bad = 0
  for i in 0 ..< hole.len:
    if hole[i] != 0 and not same(filled.px[i], tex.px[i], 40): inc bad
    if hole[i] == 0: doAssert filled.px[i] == punched.px[i]
  doAssert bad < 22 * 20 div 6, "content-aware fill: " & $bad & " pixels off"
  doAssert epochTime() - t0 < 5
  # a hole in a smooth gradient: no magenta left, the gradient goes on
  var grad = newImg(100, 80)
  for y in 0 ..< 80:
    for x in 0 ..< 100: grad.px[y * 100 + x] = argb(255, x * 2, 100, y * 3)
  var h2 = newSeq[uint8](100 * 80)
  for y in 30 ..< 50:
    for x in 40 ..< 60: h2[y * 100 + x] = 255
  var g2 = grad
  for i in 0 ..< h2.len:
    if h2[i] != 0: g2.px[i] = argb(255, 255, 0, 255)
  let gf = contentAwareFill(g2, h2)
  var errSum, errN, errMax = 0
  for i in 0 ..< h2.len:
    if h2[i] != 0:
      let e = max(abs(rOf(gf.px[i]) - rOf(grad.px[i])), abs(bOf(gf.px[i]) - bOf(grad.px[i])))
      errSum += e
      inc errN
      errMax = max(errMax, e)
  doAssert errSum div errN <= 10 and errMax <= 48, "gradient fill: mean " & $(errSum div errN) & ", worst " & $errMax
  # a long thin stroke across a big picture (the Spot Healing Brush dragged corner to corner): done
  # in a moment -- it once looked through the whole picture for each patch, for many minutes
  var big = newImg(1400, 1000)
  for y in 0 ..< 1000:
    for x in 0 ..< 1400:
      let v3 = if ((x div 9) + (y div 9)) mod 2 == 0: 190 else: 70
      big.px[y * 1400 + x] = argb(255, v3, (x * 255) div 1400, (y * 255) div 1000)
  var h3 = newSeq[uint8](1400 * 1000)
  for k in 0 ..< 1300:
    let cx = 50 + k
    let cy = 50 + k * 900 div 1300
    for dy in -3 .. 3:
      for dx in -3 .. 3: h3[(cy + dy) * 1400 + cx + dx] = 255
  var b3 = big
  for i in 0 ..< h3.len:
    if h3[i] != 0: b3.px[i] = argb(255, 255, 0, 255)
  let t3 = epochTime()
  let bf = contentAwareFill(b3, h3)
  let took = epochTime() - t3
  var magenta = 0
  for i in 0 ..< h3.len:
    if h3[i] != 0 and bf.px[i] == argb(255, 255, 0, 255): inc magenta
  doAssert magenta == 0, "a thin stroke's fill: " & $magenta & " pixels left as they were"
  doAssert took < 20, "a thin stroke across a big picture filled in " & $took & " s"
  # healing: the texture brought in, the light of where it goes
  var dst = newImg(60, 60)
  var src = newImg(60, 60)
  for y in 0 ..< 60:
    for x in 0 ..< 60:
      dst.px[y * 60 + x] = argb(255, 180, 160, 140)
      let t = if (x + y) mod 4 == 0: 30 else: 0
      src.px[y * 60 + x] = argb(255, 60 + t, 50 + t, 40 + t)
  var m = newSeq[uint8](60 * 60)
  for y in 20 ..< 40:
    for x in 20 ..< 40: m[y * 60 + x] = 255
  let hd = heal(dst, src, m)
  # inside: as light as around, with the texture's ups and downs
  let c0 = hd.px[30 * 60 + 30]
  let c1 = hd.px[30 * 60 + 31]
  doAssert abs(rOf(c0) - 180) <= 32 and abs(rOf(c1) - 180) <= 32, c0.toHex & " " & c1.toHex
  doAssert abs(rOf(c0) - rOf(c1)) >= 20
  # at the edge it meets what is there
  doAssert same(hd.px[20 * 60 + 25], dst.px[20 * 60 + 25], 34)
  doAssert hd.px[5 * 60 + 5] == dst.px[5 * 60 + 5]
  # Select Subject: a thing in the middle, off a plain background
  var scene = newImg(240, 180)
  var sd = 11'u32
  for y in 0 ..< 180:
    for x in 0 ..< 240:
      sd = sd * 1103515245'u32 + 12345'u32
      let n = int((sd shr 16) and 7)
      let inDisc = (x - 120) ^ 2 + (y - 95) ^ 2 < 50 ^ 2
      scene.px[y * 240 + x] = if inDisc: argb(255, 230 - n * 3, 120 + n, 30 + (x - 70) div 2)
                              else: argb(255, 90 + y div 6 + n, 110 + y div 6 + n, 140 + n)
  let subj = selectSubject(scene)
  var inside, outside, inN, outN = 0
  for y in 0 ..< 180:
    for x in 0 ..< 240:
      let d2 = (x - 120) ^ 2 + (y - 95) ^ 2
      if d2 < 46 ^ 2:
        inc inN
        if subj[y * 240 + x] >= 128: inc inside
      elif d2 > 54 ^ 2:
        inc outN
        if subj[y * 240 + x] >= 128: inc outside
  doAssert inside * 100 >= inN * 95, "subject: " & $inside & " of " & $inN
  doAssert outside * 100 <= outN * 3, "subject spills: " & $outside & " of " & $outN
  # ... a person (a face of skin, a coat) in a big photo: the finer second
  # look keeps the outline close (and the face is found as part of them)
  block:
    let W = 1000
    let H = 750
    var big = newImg(W, H)
    for y in 0 ..< H:
      for x in 0 ..< W:
        sd = sd * 1103515245'u32 + 12345'u32
        let n = int((sd shr 16) and 15)
        var c = argb(255, 70 + y div 12 + n, 120 + y div 15 + n, 150 + n)        # (sky, then hills)
        if y > 520 + int(30 * sin(x / 90)): c = argb(255, 50 + n, 110 + n, 50 + n)
        let face = (x - 500) ^ 2 + (y - 230) ^ 2 < 70 ^ 2
        let coat = y >= 300 and y < 700 and abs(x - 500) < 90 + (y - 300) div 6
        if face: c = argb(255, 225 - n, 180 - n, 150 - n)
        elif coat: c = argb(255, 190 + n, 30 + n, 40 + n)
        big.px[y * W + x] = c
    let m = selectSubject(big)
    var good, bad, total = 0
    for y in 0 ..< H:
      for x in 0 ..< W:
        let face = (x - 500) ^ 2 + (y - 230) ^ 2 < 64 ^ 2
        let coat = y >= 306 and y < 694 and abs(x - 500) < 84 + (y - 300) div 6
        let farOut = abs(x - 500) > 220 or y < 140
        if face or coat:
          inc total
          if m[y * W + x] >= 128: inc good
        elif farOut and m[y * W + x] >= 128: inc bad
    doAssert good * 100 >= total * 90, "the person: " & $good & " of " & $total
    doAssert bad < W * H div 100, "spills: " & $bad
  # Select Sky: a blue sky over green, busy ground; none over a wall
  var land = newImg(200, 150)
  for y in 0 ..< 150:
    for x in 0 ..< 200:
      sd = sd * 1103515245'u32 + 12345'u32
      let n = int((sd shr 16) and 63)
      land.px[y * 200 + x] = if y < 60 + int(8 * sin(x / 15)): argb(255, 70 + y div 3, 130 + y div 3, 235)
                             else: argb(255, 40 + n div 2, 90 + n, 30 + n div 3)
  let sky = selectSky(land)
  var right, wrong = 0
  for y in 0 ..< 150:
    for x in 0 ..< 200:
      let isSky = y < 60 + int(8 * sin(x / 15))
      if (sky[y * 200 + x] >= 128) == isSky: inc right else: inc wrong
  doAssert wrong * 100 < 200 * 150 * 3, "sky: " & $wrong & " wrong"
  var wall = newImg(120, 90)
  for y in 0 ..< 90:
    for x in 0 ..< 120:
      sd = sd * 1103515245'u32 + 12345'u32
      let n = int((sd shr 16) and 63)
      wall.px[y * 120 + x] = argb(255, 120 + n, 70 + n div 2, 50 + n div 3)
  for v in selectSky(wall): doAssert v == 0
  # Content-Aware Scale: the size asked for, a thing in the middle keeps
  # its shape (its width), the plain parts give
  let cas = newDoc(240, 180)
  for i in 0 ..< cas.layer.px.len: cas.layer.px[i] = scene.px[i]
  inc cas.layer.ver
  cas.markAll()
  cas.contentAwareScale(170, 180)
  doAssert cas.w == 170 and cas.h == 180 and cas.layer.px.len == 170 * 180
  var orange = 0
  for x in 0 ..< 170:
    let p = cas.layer.px[95 * 170 + x]
    if rOf(p) > 180 and bOf(p) < 120: inc orange
  doAssert orange >= 88, "the disc lost its width: " & $orange
  let wide = newDoc(240, 180)
  for i in 0 ..< wide.layer.px.len: wide.layer.px[i] = scene.px[i]
  inc wide.layer.ver
  wide.markAll()
  wide.contentAwareScale(320, 200)
  doAssert wide.w == 320 and wide.h == 200
  orange = 0
  for x in 0 ..< 320:
    let p = wide.layer.px[105 * 320 + x]
    if rOf(p) > 180 and bOf(p) < 120: inc orange
  doAssert orange in 88 .. 125, "the disc's width when wider: " & $orange
  # Preserve Details: bigger, crisper than bicubic at an edge
  let small2 = newDoc(40, 30)
  for y in 0 ..< 30:
    for x in 0 ..< 40: small2.layer.px[y * 40 + x] = if x < 20: argb(255, 40, 40, 40) else: argb(255, 220, 220, 220)
  inc small2.layer.ver
  small2.markAll()
  let bic = newDoc(40, 30)
  bic.layer.px = small2.layer.px
  inc bic.layer.ver
  bic.imageSize(160, 120, rsBicubic)
  small2.enlarge(160, 120)
  doAssert small2.w == 160 and small2.h == 120
  # the step from dark to light: steeper
  let sharpStep = lumaOf(small2.layer.px[60 * 160 + 82]) - lumaOf(small2.layer.px[60 * 160 + 77])
  let softStep = lumaOf(bic.layer.px[60 * 160 + 82]) - lumaOf(bic.layer.px[60 * 160 + 77])
  doAssert sharpStep > softStep, $sharpStep & " vs " & $softStep
  # red eye: the red pupil dark, the white around it kept
  var eye = newImg(40, 40)
  for y in 0 ..< 40:
    for x in 0 ..< 40:
      let d2 = (x - 20) ^ 2 + (y - 20) ^ 2
      eye.px[y * 40 + x] = if d2 < 36: argb(255, 200, 30, 35) elif d2 < 100: argb(255, 90, 70, 50) else: argb(255, 235, 230, 225)
  let fixedEye = redEye(eye, 21, 19, 12)
  let pc = fixedEye.px[20 * 40 + 20]
  doAssert rOf(pc) < 60 and abs(rOf(pc) - gOf(pc)) < 25, pc.toHex
  doAssert fixedEye.px[2 * 40 + 2] == eye.px[2 * 40 + 2]
  doAssert fixedEye.px[20 * 40 + 28] == eye.px[20 * 40 + 28]

block warps:
  # Liquify: an untouched mesh changes nothing
  var pic = newImg(100, 80)
  for y in 0 ..< 80:
    for x in 0 ..< 100:
      pic.px[y * 100 + x] = if (x - 50) ^ 2 + (y - 40) ^ 2 < 36: argb(255, 255, 255, 255) else: argb(255, 0, 0, 0)
  var m = newLiquifyMesh(100, 80, 64)
  doAssert m.isFlat and liquifyImg(pic, m).px == pic.px
  # Forward Warp: the dot pushed right, in small steps (a drag)
  for k in 0 ..< 10: m.push(50.0 + k.float, 40, 1, 0, radius = 30, pressure = 1)
  let pushed = liquifyImg(pic, m)
  doAssert lumaOf(pushed.px[40 * 100 + 58]) > 128, "pushed: " & $lumaOf(pushed.px[40 * 100 + 58])
  doAssert lumaOf(pushed.px[40 * 100 + 45]) < 64
  # Reconstruct: back
  for k in 0 ..< 30: m.reconstruct(55, 40, 40, 1)
  let back = liquifyImg(pic, m)
  doAssert lumaOf(back.px[40 * 100 + 50]) > 200 and lumaOf(back.px[40 * 100 + 58]) < 64
  # Bloat makes the dot bigger, Pucker smaller
  var mb = newLiquifyMesh(100, 80, 64)
  for k in 0 ..< 5: mb.pucker(50, 40, 25, 1, bloat = true)
  var big = 0
  for p in liquifyImg(pic, mb).px:
    if lumaOf(p) > 128: inc big
  var mp = newLiquifyMesh(100, 80, 64)
  for k in 0 ..< 5: mp.pucker(50, 40, 25, 1)
  var small = 0
  for p in liquifyImg(pic, mp).px:
    if lumaOf(p) > 128: inc small
  var was = 0
  for p in pic.px:
    if lumaOf(p) > 128: inc was
  doAssert big > was + 10 and small < was - 10, $big & " " & $was & " " & $small
  # Twirl turns stripes around the middle
  var stripes = newImg(80, 80)
  for y in 0 ..< 80:
    for x in 0 ..< 80: stripes.px[y * 80 + x] = if (x div 8) mod 2 == 0: 0xFFFFFFFF'u32 else: 0xFF000000'u32
  var mt = newLiquifyMesh(80, 80, 80)
  for k in 0 ..< 6: mt.twirl(40, 40, 35, 1)
  let tw = liquifyImg(stripes, mt)
  doAssert tw.px != stripes.px and tw.px[2 * 80 + 2] == stripes.px[2 * 80 + 2]
  # a preview (a smaller copy) shows the same
  let half = smallCopy(pic, 50)
  let prev = liquifyImg(half, m, 0, 0, 2.0)
  doAssert prev.w == 50 and prev.h == 40
  # Lens Correction: nothing set changes nothing; each setting does what it says
  let grid = noisy(120, 90, 5)
  doAssert lensImg(grid, lensDefault()).px == grid.px
  var lc = lensDefault()
  lc.vignette = 80
  let vg = lensImg(flat(60, 40, argb(255, 100, 100, 100)), lc)
  doAssert lumaOf(vg.px[0]) > 130 and lumaOf(vg.px[20 * 60 + 30]) == 100
  lc = lensDefault()
  lc.distortion = 60
  let dist = lensImg(grid, lc)
  doAssert dist.px[45 * 120 + 60] == grid.px[45 * 120 + 60] and dist.px[5 * 120 + 5] != grid.px[5 * 120 + 5]
  lc = lensDefault()
  lc.angle = 10
  let turned = lensImg(grid, lc)
  doAssert aOf(turned.px[0]) == 0, "a turned corner is empty"
  lc.edge = leExtend
  doAssert aOf(lensImg(grid, lc).px[0]) == 255
  lc = lensDefault()
  lc.redCyan = 100
  doAssert lensImg(grid, lc).px != grid.px
  # Straighten: turned and cut to what it fills
  doAssert innerRect(100, 100, 0) == (100, 100)
  let (iw, ih) = innerRect(100, 100, 45)
  doAssert iw in 69 .. 71 and ih in 69 .. 71
  let sd = test(160, 120)
  sd.straighten(8, 0xFFFFFFFF'u32)
  let (ew, eh) = innerRect(160, 120, 8)
  doAssert abs(sd.w - ew) <= 2 and abs(sd.h - eh) <= 2
  for p in sd.layers[0].px: doAssert aOf(p) == 255

block histogramAndLevels:
  let d = test()
  let h = d.histogram()
  doAssert h.total == d.w * d.h
  let s = h.stats(1)
  doAssert s.mean > 0 and s.median in 0 .. 255
  let a = autoLevels(h)
  for c in 0 .. 2: doAssert a[c].inLo <= a[c].inHi
  let lut = levelsLut(Levels(inLo: 0, inHi: 255, gamma: 1, outLo: 0, outHi: 255))
  for i in 0 .. 255: doAssert int(lut[i]) == i
  let cl = curveLut(@[(0, 0), (255, 255)])
  for i in 0 .. 255: doAssert abs(int(cl[i]) - i) <= 1

block cancelWork:
  # Cancel pressed while a filter runs: it stops, and the step takes back
  # what it had done
  markUiThread()
  var ticks = 0
  busyHook = proc () =
    inc ticks
    if ticks == 3: busyCancelAsked = true
  var d = test(900, 700)
  let before = d.layer.px
  beginBusy("Blur", cancel = true)
  ticks = 0
  var stopped = false
  try:
    d.beginStep("Gaussian Blur")
    d.applyFilter(30, gaussianBlur(12))
    d.endStep()
  except BusyCancelled:
    stopped = true
    d.cancelStep()
  endBusy(cancel = true)
  busyHook = nil
  doAssert stopped and ticks >= 3
  doAssert d.layer.px == before and not d.canUndo
  # without a region that can be cancelled: never stopped
  ticks = 0
  busyHook = proc () = busyCancelAsked = true
  d.beginStep("Gaussian Blur")
  d.applyFilter(30, gaussianBlur(4))
  d.endStep()
  busyHook = nil
  busyCancelAsked = false
  doAssert d.canUndo

block scratchDisk:
  # old undo steps go to the scratch disk and come back when undone
  let dir = getTempDir() / "retro_scratch_test"
  removeDir(dir)
  scratchDir = dir
  let budget = undoRamBudget
  undoRamBudget = 1 shl 20
  var d = test(800, 600)
  var states = @[d.layer.px]
  for k in 0 ..< 5:
    d.beginStep("Invert")
    d.applyFilter(0, invert())
    d.endStep()
    states.add d.layer.px
  # (the writer thread finishes; the memory of the old steps is given back)
  for _ in 0 ..< 200:
    d.collectSpills()
    var files = 0
    for f in walkFiles(dir / "*.raw"): inc files
    if files >= 3: break
    sleep(10)
  d.collectSpills()
  var files = 0
  for f in walkFiles(dir / "*.raw"): inc files
  doAssert files >= 3, $files
  for k in countdown(4, 0):
    d.undo()
    doAssert d.layer.px == states[k], "undo " & $k
  for k in 1 .. 5:
    d.redo()
    doAssert d.layer.px == states[k], "redo " & $k
  d.clearHistory()
  waitScratch()                  # (old files are deleted by the writer thread)
  files = 0
  for f in walkFiles(dir / "*.raw"): inc files
  doAssert files == 0
  undoRamBudget = budget
  scratchDir = ""
  removeDir(dir)

block typeLayers:
  var d = newDoc(200, 100, 0xFFFFFFFF'u32)
  var st = defaultStyle()
  st.size = 40
  st.color = 0xFFFF0000'u32
  d.beginStep("Type")
  d.touchLayers()
  let L = d.addTextLayer(newText("Hi", st, 20, 60))
  d.endStep()
  doAssert L.isText and L.name == "Hi" and d.layers.len == 2 and d.cur == 1
  proc ink(L: Layer): int =
    for p in L.px:
      if (p shr 24) > 0: inc result
  let n0 = L.ink
  doAssert n0 > 100
  d.updateComposite()
  var reds = 0
  for p in d.compCopy:
    if p == 0xFFFF0000'u32: inc reds
  doAssert reds > 50
  # edited: drawn again; undone: as it was, pixels too
  let before = L.px
  d.beginStep("Edit Type")
  d.touchLayers()
  var t = L.text
  t.insertText(2, " there", st)
  d.setText(L, t)
  d.endStep()
  doAssert L.text.plainText == "Hi there" and L.ink > n0
  d.undo()
  doAssert L.text.plainText == "Hi" and L.px == before
  d.redo()
  doAssert L.text.plainText == "Hi there" and L.ink > n0
  d.undo()
  d.undo()
  doAssert d.layers.len == 1
  d.redo()
  doAssert d.layers.len == 2 and d.layers[1].isText
  # Image Size: the type set again at the new size (not resampled)
  d.snapStep("Image Size")
  d.imageSize(400, 200)
  d.endStep()
  let T = d.layers[1]
  doAssert T.isText and T.text.spans[0].style.size == 80 and T.text.x == 40
  doAssert abs(T.ink - 4 * n0) < n0              # (four times the ink, about)
  var crisp = 0
  for p in T.px:
    if (p shr 24) == 255: inc crisp
  doAssert crisp > 3 * n0 div 2
  d.undo()
  doAssert d.w == 200 and d.layers[1].text.spans[0].style.size == 40
  # Crop and Canvas Size move it
  d.snapStep("Crop")
  d.crop(rect(10, 0, 150, 100))
  d.endStep()
  doAssert d.layers[1].text.x == 10
  d.drawText(d.layers[1])
  doAssert d.layers[1].ink > n0 div 2
  d.undo()
  d.snapStep("Canvas Size")
  d.canvasSize(240, 100, 2, 1, 0xFFFFFFFF'u32)
  d.endStep()
  doAssert d.layers[1].text.x == 60
  d.undo()
  # turning the image makes it pixels; undone, type again
  d.snapStep("Rotate")
  d.rotateImage(1)
  d.endStep()
  doAssert not d.layers[1].isText and d.layers[1].ink > n0 div 2
  d.undo()
  doAssert d.layers[1].isText
  # rasterized by hand, undoably
  d.beginStep("Rasterize Type")
  d.touchLayers()
  d.rasterizeText(d.layers[1])
  d.endStep()
  doAssert not d.layers[1].isText and d.layers[1].ink > n0 div 2
  d.undo()
  doAssert d.layers[1].isText
  # duplicated: type too
  d.snapStep("Duplicate")
  let c = d.duplicateLayer(1)
  d.endStep()
  doAssert c.isText and c.text == d.layers[1].text
  d.undo()
  # merged down: pixels
  d.beginStep("Merge Down")
  d.touchLayers()
  d.touch(d.layers[0], d.bounds)
  d.cur = 1
  d.mergeDown()
  d.endStep()
  doAssert d.layers.len == 1 and not d.layers[0].isText
  d.undo()
  doAssert d.layers.len == 2 and d.layers[1].isText
  d.save("type")

block layerStyles:
  var d = newDoc(120, 120, 0xFFFFFFFF'u32)
  let L = d.addLayer("Square")
  for y in 40 ..< 80:
    for x in 40 ..< 80: L.px[y * 120 + x] = 0xFF2040C0'u32
  d.markAll()
  d.updateComposite()
  let plain = d.compCopy
  # a drop shadow: darker below right of the square, not above left
  d.beginStep("Layer Style")
  d.touchLayers()
  L.fx.fx[fxDropShadow] = defaultEffect(fxDropShadow)
  d.markAll()
  d.endStep()
  doAssert L.hasFx
  d.updateComposite()
  doAssert rOf(d.compCopy[82 * 120 + 80]) < 200
  doAssert d.compCopy[37 * 120 + 37] == 0xFFFFFFFF'u32
  doAssert d.compCopy[60 * 120 + 60] == plain[60 * 120 + 60]
  d.undo()
  doAssert not L.hasFx
  d.updateComposite()
  doAssert d.compCopy == plain
  d.redo()
  doAssert L.hasFx
  # hidden: nothing; on again
  L.fx.hidden = true
  d.markAll()
  d.updateComposite()
  doAssert d.compCopy == plain
  L.fx.hidden = false
  # a stroke outside: 3 pixels around in black
  L.fx.fx[fxDropShadow].on = false
  L.fx.fx[fxStroke] = defaultEffect(fxStroke)
  d.markAll()
  d.updateComposite()
  doAssert d.compCopy[60 * 120 + 38] == 0xFF000000'u32
  doAssert d.compCopy[60 * 120 + 81] == 0xFF000000'u32
  doAssert d.compCopy[60 * 120 + 35] == 0xFFFFFFFF'u32
  doAssert d.compCopy[60 * 120 + 41] == 0xFF2040C0'u32
  # inside
  L.fx.fx[fxStroke].style = 1
  d.markAll()
  d.updateComposite()
  doAssert d.compCopy[60 * 120 + 38] == 0xFFFFFFFF'u32 and d.compCopy[60 * 120 + 41] == 0xFF000000'u32
  L.fx.fx[fxStroke].on = false
  # a color overlay; fill 0: the overlay shows, the pixels not
  L.fx.fx[fxColorOverlay] = defaultEffect(fxColorOverlay)
  d.markAll()
  d.updateComposite()
  doAssert d.compCopy[60 * 120 + 60] == 0xFFFF0000'u32
  L.fx.fx[fxColorOverlay].on = false
  L.fx.fx[fxBevel] = defaultEffect(fxBevel)
  L.fill = 0
  d.markAll()
  d.updateComposite()
  doAssert d.compCopy[60 * 120 + 60] == 0xFFFFFFFF'u32           # (the middle: flat, no fill)
  doAssert d.compCopy[77 * 120 + 60] != 0xFFFFFFFF'u32           # (the dark edge)
  L.fill = 100
  d.markAll()
  d.updateComposite()
  doAssert rOf(d.compCopy[42 * 120 + 60]) > 0x20                 # (the lit edge: lighter)
  doAssert rOf(d.compCopy[77 * 120 + 60]) < 0x20 or bOf(d.compCopy[77 * 120 + 60]) < 0xC0
  # every effect, every style: something drawn, nothing breaks (on gray)
  for p in d.layers[0].px.mitems: p = 0xFF808080'u32
  L.fx = LayerFx()
  d.markAll()
  d.updateComposite()
  let gray = d.compCopy
  for k in FxKind:
    L.fx = LayerFx()
    L.fx.fx[k] = defaultEffect(k)
    for style in 0 .. 4:
      L.fx.fx[k].style = style
      d.markAll()
      d.updateComposite()
      doAssert d.compCopy != gray, $k & " " & $style
  for p in d.layers[0].px.mitems: p = 0xFFFFFFFF'u32
  # an outer glow reaches past the square
  L.fx = LayerFx()
  L.fx.fx[fxOuterGlow] = defaultEffect(fxOuterGlow)
  L.fx.fx[fxOuterGlow].mode = bmNormal
  L.fx.fx[fxOuterGlow].color = 0xFF00FF00'u32
  L.fx.fx[fxOuterGlow].size = 10
  d.markAll()
  d.updateComposite()
  doAssert gOf(d.compCopy[60 * 120 + 36]) > rOf(d.compCopy[60 * 120 + 36])
  doAssert d.compCopy[60 * 120 + 20] == 0xFFFFFFFF'u32
  # merged down: the style in the pixels
  let shown = d.compCopy
  d.beginStep("Merge Down")
  d.touchLayers()
  d.touch(d.layers[0], d.bounds)
  d.cur = 1
  d.mergeDown()
  d.endStep()
  d.updateComposite()
  doAssert d.layers.len == 1 and not d.layers[0].hasFx
  var diff = 0
  for i in 0 ..< shown.len: diff = max(diff, abs(gOf(shown[i]) - gOf(d.compCopy[i])))
  doAssert diff <= 2
  d.undo()
  doAssert d.layers[1].hasFx
  # with a mask: the effects follow the masked shape
  var m = newDoc(120, 120, 0xFFFFFFFF'u32)
  let S = m.addLayer("S")
  for y in 40 ..< 80:
    for x in 40 ..< 80: S.px[y * 120 + x] = 0xFF2040C0'u32
  m.beginStep("Mask")
  m.addLayerMask(mfHideAll)
  m.endStep()
  S.fx.fx[fxStroke] = defaultEffect(fxStroke)
  m.markAll()
  m.updateComposite()
  for p in m.compCopy: doAssert p == 0xFFFFFFFF'u32
  # Image Size scales the style
  m.snapStep("Image Size")
  m.imageSize(240, 240)
  m.endStep()
  doAssert S.fx.fx[fxStroke].size == 6
  # on a type layer
  var t = newDoc(200, 100, 0xFFFFFFFF'u32)
  var st = defaultStyle()
  st.size = 50
  let T = t.addTextLayer(newText("Fx", st, 20, 70))
  T.fx.fx[fxDropShadow] = defaultEffect(fxDropShadow)
  t.markAll()
  t.updateComposite()
  var grey = 0
  for p in t.compCopy:
    if p != 0xFFFFFFFF'u32 and p != 0xFF000000'u32 and rOf(p) > 100: inc grey
  doAssert grey > 30
  t.save("styles")

block typeAndStyleFiles:
  let dir = getTempDir() / "retro_photo_type"
  createDir(dir)
  var d = newDoc(160, 90, 0xFFFFFFFF'u32)
  var st = defaultStyle()
  st.size = 30
  st.color = 0xFF008000'u32
  var tx = newText("Saved", st, 10, 50)
  tx.warp = TextWarp(style: wsArc, bend: 30)
  let L = d.addTextLayer(tx)
  L.fx.fx[fxStroke] = defaultEffect(fxStroke)
  L.fx.fx[fxBevel] = defaultEffect(fxBevel)
  L.fx.fx[fxBevel].style = 2
  L.fill = 40
  d.saveRpd(dir / "t.rpd")
  let e = loadRpd(dir / "t.rpd")
  let E = e.layers[1]
  doAssert E.isText and E.text == L.text
  doAssert E.fx == L.fx and E.fill == 40
  doAssert E.px == L.px
  d.updateComposite()
  e.updateComposite()
  doAssert d.compCopy == e.compCopy
  removeDir(dir)

block files:
  let dir = getTempDir() / "retro-photo-test"
  createDir(dir)
  let d = test()
  d.snapStep("x")
  let L = d.addLayer("Top")
  L.px[0] = argb(128, 255, 0, 0)
  L.opacity = 70
  L.mode = bmMultiply
  discard d.saveSelection("sel")
  d.paths.add Path(name: "p", subs: @[SubPath(pts: @[PathPoint(p: (1.0, 2.0), inH: (1.0, 2.0), outH: (3.0, 4.0))])])
  d.info.caption = "A test"
  d.endStep()
  d.saveRpd(dir / "t.rpd")
  let e = loadRpd(dir / "t.rpd")
  doAssert e.w == d.w and e.layers.len == 2 and e.layers[1].name == "Top"
  doAssert e.layers[1].opacity == 70 and e.layers[1].mode == bmMultiply
  doAssert e.layers[1].px[0] == argb(128, 255, 0, 0)
  doAssert e.layers[0].px == d.layers[0].px
  doAssert e.alphas.len == 1 and e.paths.len == 1 and e.info.caption == "A test"
  for fmt in ["png", "jpg", "bmp"]:
    d.saveFlat(dir / "t." & fmt, fmt, 90)
    let o = openImage(dir / "t." & fmt)
    doAssert o.w == d.w and o.h == d.h, fmt
    let p = o.layer.px[60 * d.w + 120]
    d.updateComposite()
    doAssert same(p, d.compCopy[60 * d.w + 120], if fmt == "jpg": 24 else: 0), fmt & ": " & $p.toHex & " " & $d.compCopy[60 * d.w + 120].toHex
  removeDir(dir)

block liveComposite:
  # a layer being moved or turned is shown straight from the layers at the
  # view's points (`compositeSampled`): at 1:1 exactly what putting it down
  # makes -- groups, masks, clipping, adjustment layers, effects
  let d = test(96, 72)
  let a = d.addLayer("a")
  for y in 10 ..< 50:
    for x in 20 ..< 70: a.px[y * 96 + x] = argb(200, 30, 200, 90)
  a.mode = bmMultiply
  a.opacity = 80
  d.cur = d.layers.find(a)
  d.addLayerMask(mfRevealAll)
  for y in 0 ..< 72:
    for x in 0 ..< 30: a.mask.px[y * 96 + x] = 0xFF404040'u32
  let g = d.addGroup("g")
  let b = d.addLayer("b")
  b.depth = g.depth + 1
  for y in 30 ..< 55:
    for x in 40 ..< 75: b.px[y * 96 + x] = argb(255, 250, 220, 10)
  let c = d.addLayer("c")
  c.depth = g.depth + 1
  c.clipped = true
  for y in 0 ..< 72:
    for x in 0 ..< 96:
      if (x + y) mod 7 < 3: c.px[y * 96 + x] = argb(180, 10, 10, 240)
  b.fx.fx[fxDropShadow] = defaultEffect(fxDropShadow)
  d.cur = d.layers.high
  discard d.newAdjustmentLayer(Adjustment(kind: "Invert"))
  for y in 0 ..< 72:
    for x in 0 ..< 48: d.layers[^1].px[y * 96 + x] = 0xFF808080'u32
  d.markAll()
  var xs = newSeq[int32](96)
  var ys = newSeq[int32](72)
  for i in 0 ..< 96: xs[i] = int32(i)
  for i in 0 ..< 72: ys[i] = int32(i)
  # nothing live: the same as the composite
  d.updateComposite()
  var o: seq[uint32]
  d.compositeSampled(xs, ys, o)
  doAssert o == d.compCopy, "sampled = composite"
  # the layer with the shadow moved: shown, then put down
  d.cur = d.layers.find(b)
  d.clearHistory()
  d.beginStep("Move")
  var m = d.beginMove(0xFFFFFFFF'u32)
  d.moveTo(m, -7, -5)       # (inside: past the edges its shadow is made again from less)
  doAssert d.live.len > 0
  doAssert b.px[35 * 96 + 45] == argb(255, 250, 220, 10), "not changed while shown"
  d.compositeSampled(xs, ys, o)
  d.endMove(m)
  d.endStep()
  doAssert d.live.len == 0
  d.updateComposite()
  var diff = 0
  for i in 0 ..< o.len:
    if o[i] != d.compCopy[i]: inc diff
  doAssert diff == 0, "moved: " & $diff & " pixels differ"
  d.undo()
  doAssert b.px[35 * 96 + 45] == argb(255, 250, 220, 10)
  # a selection moved (what is left behind, the selection with it)
  d.cur = d.layers.find(a)
  d.setSelection(d.rectMask(rect(25, 15, 20, 20)))
  d.beginStep("Move")
  m = d.beginMove(0xFFFFFFFF'u32)
  d.moveTo(m, -9, 11)
  d.compositeSampled(xs, ys, o)
  d.endMove(m)
  d.endStep()
  d.updateComposite()
  diff = 0
  for i in 0 ..< o.len:
    if o[i] != d.compCopy[i]: inc diff
  doAssert diff == 0, "selection moved: " & $diff & " pixels differ"
  doAssert d.selBounds == rect(16, 26, 20, 20), $d.selBounds
  d.selectNone()
  # a warp shown live is close to the warp put down (read between pixels
  # the same way; a half-pixel's rounding apart)
  let L0 = d.layers[0]
  let r = rect(10, 10, 40, 30)
  var (part, base) = d.liftForWarp(L0.px, r, @[], 0xFFFFFFFF'u32)
  var q = quadOf(r)
  q[1] = (q[1][0] + 15, q[1][1] + 4)
  q[2] = (q[2][0] + 10, q[2][1] + 8)
  d.setLive(@[LivePart(layer: L0, kind: lkWarp, base: cast[ptr UncheckedArray[uint32]](addr base[0]),
                       src: cast[ptr UncheckedArray[uint32]](addr part[0]), srcR: r, quad: q)])
  d.compositeSampled(xs, ys, o)
  d.endLive()
  var put = base
  d.warpOnto(put, part, r, q)
  L0.px = put
  inc L0.ver
  d.markAll()
  d.updateComposite()
  var far = 0
  for i in 0 ..< o.len:
    let p = o[i]
    let e = d.compCopy[i]
    if abs(rOf(p) - rOf(e)) > 3 or abs(gOf(p) - gOf(e)) > 3 or abs(bOf(p) - bOf(e)) > 3: inc far
  doAssert far <= 2, "warped: " & $far & " pixels differ"   # (an edge pixel or two)
  # an adjustment shown live (a slider dragged): the layer's pixels at the
  # points changed, in the selection -- as applying it to all of it
  d.cur = 0
  d.setSelection(d.rectMask(rect(10, 5, 50, 40)))
  let inv = mapFn(proc (p: uint32): uint32 = p xor 0x00FFFFFF'u32)
  d.setLive(@[LivePart(layer: d.layers[0], kind: lkMap, keepAlpha: true,
                       map: proc (px: var seq[uint32]; w, h: int) =
                         px = inv(Img(w: w, h: h, px: px), rect(0, 0, w, h)).px)])
  d.compositeSampled(xs, ys, o)
  d.endLive()
  d.beginStep("Invert")
  d.applyFilter(0, inv)
  d.endStep()
  d.updateComposite()
  doAssert o == d.compCopy, "adjusted live = adjusted"
  d.undo()
  d.selectNone()
  d.updateComposite()
  # zoomed out: every third point of the composite
  var xs3, ys3: seq[int32]
  for i in countup(1, 95, 3): xs3.add int32(i)
  for i in countup(1, 71, 3): ys3.add int32(i)
  d.compositeSampled(xs3, ys3, o)
  for j, y in ys3:
    for i, x in xs3: doAssert o[j * xs3.len + i] == d.compCopy[y * 96 + x]

block wholeLayerSteps:
  # a change of all of a layer hands its old pixels to the step (no copy):
  # undo and redo swap them; a step that saved tiles first still undoes right
  let d = test(64, 48)
  let L = d.layer
  let before = L.px
  d.beginStep("Invert")
  d.applyFilter(0, mapFn(proc (p: uint32): uint32 = p xor 0x00FFFFFF'u32))
  d.endStep()
  let after = L.px
  doAssert after != before
  d.undo()
  doAssert L.px == before
  d.redo()
  doAssert L.px == after
  d.undo()
  # tiles first (a dab), then the whole layer, in one step
  d.beginStep("Both")
  d.touch(L, rect(5, 5, 10, 10))
  for y in 5 ..< 15:
    for x in 5 ..< 15: L.px[y * 64 + x] = 0xFF00FF00'u32
  let mid = L.px
  d.applyFilter(0, mapFn(proc (p: uint32): uint32 = p xor 0x00FFFFFF'u32))
  d.endStep()
  let both = L.px
  doAssert both[7 * 64 + 7] == (0xFF00FF00'u32 xor 0x00FFFFFF'u32) and both != mid
  d.undo()
  doAssert L.px == before
  d.redo()
  doAssert L.px == both
  # what the History Brush reads: the state before
  doAssert d.statePixels(L, 0) == before
  # a whole save, then a dab in the same step: undone to before
  d.undo()
  d.beginStep("Then")
  d.applyFilter(0, mapFn(proc (p: uint32): uint32 = p xor 0x00FFFFFF'u32))
  doAssert d.original(L, 30, 20) == before[20 * 64 + 30]
  d.touch(L, rect(0, 0, 8, 8))
  L.px[0] = 0xFF123456'u32
  d.endStep()
  d.undo()
  doAssert L.px == before
  # cancelled: as it was
  d.beginStep("Cancelled")
  d.applyFilter(0, mapFn(proc (p: uint32): uint32 = p xor 0x00FFFFFF'u32))
  d.cancelStep()
  doAssert L.px == before

echo "photo: all passed"
