## Tests of today's Photoshop features made offline: Layer Cleanup,
## Harmonize with a shadow, Colorize from color hints, Content-Aware
## Expand, artboards, the Patch's options, Dynamic Text, the Clarity,
## Dehaze and Grain adjustment layers, the locks and linked layers.

import std/[os, math]
import retroui/[gfx, photo, photosmart, photocc, textengine]

proc rgbOf(p: uint32): (int, int, int) = (rOf(p), gOf(p), bOf(p))

proc scene(w, h: int): Doc =
  ## (a sky over ground: brighter at the top left)
  result = newDoc(w, h)
  let L = result.layer
  for y in 0 ..< h:
    for x in 0 ..< w:
      let k = 255 - (x + y) * 160 div (w + h)
      L.px[y * w + x] = if y < h div 2: argb(255, k * 3 div 5, k * 4 div 5, k) else: argb(255, 90, 120 - y div 8, 60)
  inc L.ver
  result.markAll()

block cleanup:
  let d = newDoc(60, 40)
  let a = d.addLayer()                       # empty
  let b = d.addLayer()                       # a blue square
  for y in 5 ..< 15:
    for x in 5 ..< 15: b.px[y * 60 + x] = argb(255, 20, 40, 220)
  inc b.ver
  let c = d.addLayer("Kept")                 # a name of the user's: kept
  c.px[0] = argb(255, 255, 0, 0)
  discard d.addGroup()                       # an empty group
  let hid = d.addLayer()
  hid.px[5] = argb(255, 0, 0, 0)
  hid.visible = false
  let n0 = d.layers.len
  d.beginStep("Layer Cleanup")
  let rep = d.cleanupLayers(removeHidden = true)
  d.endStep()
  doAssert rep.emptyRemoved == 1 and rep.groupsRemoved == 1 and rep.hiddenRemoved == 1, $rep
  doAssert d.layers.len == n0 - 3
  doAssert a notin d.layers and hid notin d.layers
  doAssert b.name == "Blue Shape", b.name
  doAssert c.name == "Kept"
  doAssert genericName("Layer 12") and genericName("Layer 3 copy 2") and genericName("Group 1") and
           not genericName("Sky")
  d.undo()
  doAssert d.layers.len == n0, "undone"

block harmonizeWithShadow:
  let d = scene(120, 90)
  let obj = d.addLayer("Object")
  for y in 30 ..< 60:
    for x in 50 ..< 70: obj.px[y * 120 + x] = argb(255, 250, 40, 40)   # a loud red box
  inc obj.ver
  let before = obj.px[45 * 120 + 60]
  d.beginStep("Harmonize")
  let sh = d.harmonizeLayer(obj, 80, 60)
  d.endStep()
  doAssert obj.px[45 * 120 + 60] != before, "its colors moved toward the picture's"
  doAssert sh != nil and sh.name == "Shadow" and sh.mode == bmMultiply
  doAssert d.layers.find(sh) == d.layers.find(obj) - 1, "under the object"
  # the light is at the top left: the shadow falls to the bottom right of the object
  var sx, sy, sw = 0.0
  for y in 0 ..< 90:
    for x in 0 ..< 120:
      let a = float(sh.px[y * 120 + x] shr 24)
      sx += a * x.float; sy += a * y.float; sw += a
  doAssert sw > 0
  doAssert sx / sw > 60 and sy / sw > 45, "away from the light: " & $(sx / sw, sy / sw)

block colorizeHints:
  # a gray picture: left half dark, right half light, an edge between
  var px = newSeq[uint32](80 * 40)
  for y in 0 ..< 40:
    for x in 0 ..< 80: px[y * 80 + x] = if x < 40: grayPx(70) else: grayPx(190)
  let o = colorizePixels(px, 80, 40, [(10.0, 20.0, 0xFFFF0000'u32), (70.0, 20.0, 0xFF0000FF'u32)])
  let (lr, _, lb) = rgbOf(o[20 * 80 + 30])
  let (rr, _, rb) = rgbOf(o[20 * 80 + 50])
  doAssert lr > lb + 20, "the red ran over the dark half: " & $rgbOf(o[20 * 80 + 30])
  doAssert rb > rr + 20, "the blue over the light half: " & $rgbOf(o[20 * 80 + 50])
  # the light kept
  let y0 = rOf(o[20 * 80 + 30]).float * 0.299 + gOf(o[20 * 80 + 30]).float * 0.587 + bOf(o[20 * 80 + 30]).float * 0.114
  doAssert abs(y0 - 70) < 6, $y0
  # no hints: a warm tint
  let t = colorizePixels(px, 80, 40, [])
  doAssert rOf(t[20 * 80 + 60]) > bOf(t[20 * 80 + 60])

block contentAwareExpand:
  let d = scene(80, 60)
  d.beginStep("Crop")
  d.contentAwareExpand(rect(-20, 0, 120, 60))
  d.endStep()
  doAssert d.w == 120 and d.h == 60
  # the new room is made up: opaque, like what is near it (not the background color)
  var opaque = true
  for y in 0 ..< 60:
    for x in 0 ..< 20:
      if (d.layer.px[y * 120 + x] shr 24) < 250: opaque = false
  doAssert opaque
  let p = d.layer.px[10 * 120 + 5]
  doAssert bOf(p) > rOf(p), "sky goes on into the new room: " & $rgbOf(p)
  # cut down as a crop too
  d.beginStep("Crop")
  d.contentAwareExpand(rect(10, 10, 50, 30))
  d.endStep()
  doAssert d.w == 50 and d.h == 30

block artboards:
  let d = newDoc(200, 120, 0xFFC0C0C0'u32)
  d.beginStep("New Artboard")
  let G = d.addArtboard(rect(10, 10, 60, 40), color = 0xFFFFFFFF'u32)
  d.endStep()
  doAssert G != nil and G.isArtboard and G.board == rect(10, 10, 60, 40)
  doAssert d.artboards == @[d.layers.find(G)]
  # a layer put in it shows only on its page
  let k = d.layers.find(G)
  let L = d.addLayer("Red", above = k - 1)
  for p in L.px.mitems: p = argb(255, 255, 0, 0)
  inc L.ver
  doAssert d.blockStart(d.layers.find(G)) <= d.layers.find(L), "in the artboard's group"
  d.markAll()
  let flat = d.flattened()
  doAssert rgbOf(flat[30 * 200 + 30]) == (255, 0, 0), "on the page"
  doAssert rgbOf(flat[100 * 200 + 150]) == (192, 192, 192), "off the page: not shown"
  doAssert d.artboardAt(20, 20) == d.layers.find(G) and d.artboardAt(150, 100) == -1
  # its picture: the page alone
  let pic = d.artboardPicture(d.layers.find(G))
  doAssert pic.w == 60 and pic.h == 40 and rgbOf(pic.px[10 * 60 + 10]) == (255, 0, 0)
  # moved, with all on it
  d.beginStep("Move Artboard")
  d.moveArtboard(d.layers.find(G), 100, 50)
  d.endStep()
  doAssert G.board == rect(110, 60, 60, 40)
  d.markAll()
  let flat2 = d.flattened()
  doAssert rgbOf(flat2[30 * 200 + 30]) == (192, 192, 192)
  doAssert rgbOf(flat2[80 * 200 + 130]) == (255, 0, 0)
  # kept in a .rpd
  let path = getTempDir() / "retro-artboard.rpd"
  d.saveRpd(path)
  let back = loadRpd(path)
  doAssert back.artboards.len == 1 and back.layers[back.artboards[0]].board == rect(110, 60, 60, 40)
  removeFile(path)
  # undone: back where it was
  d.undo()
  doAssert G.board == rect(10, 10, 60, 40)

block patchOptions:
  let d = scene(100, 80)
  # a dark spot to patch, and the sky to patch it from
  for y in 10 ..< 20:
    for x in 10 ..< 20: d.layer.px[y * 100 + x] = argb(255, 0, 0, 0)
  inc d.layer.ver
  var m = newSeq[uint8](100 * 80)
  for y in 10 ..< 20:
    for x in 10 ..< 20: m[y * 100 + x] = 255
  d.setSelection(m)
  d.beginStep("Patch")
  d.patch(30, 0, contentAware = true, structure = 4, color = 5)
  d.endStep()
  doAssert rOf(d.layer.px[15 * 100 + 15]) + bOf(d.layer.px[15 * 100 + 15]) > 100, "the spot made like the sky"
  # Destination: the selection's texture copied where it was dragged (its
  # light and color fitted to the place)
  let d2 = scene(100, 80)
  for y in 10 ..< 20:
    for x in 10 ..< 20: d2.layer.px[y * 100 + x] = if (x + y) mod 2 == 0: grayPx(0) else: grayPx(255)
  inc d2.layer.ver
  d2.setSelection(m)
  d2.beginStep("Patch")
  d2.patch(40, 30, destination = true)
  d2.endStep()
  var lo = 255
  var hi = 0
  for y in 42 ..< 48:
    for x in 52 ..< 58:
      lo = min(lo, gOf(d2.layer.px[y * 100 + x]))
      hi = max(hi, gOf(d2.layer.px[y * 100 + x]))
  doAssert hi - lo > 100, "the checks copied there: " & $(lo, hi)
  doAssert rgbOf(d2.layer.px[15 * 100 + 15]) == (0, 0, 0), "the source stays"

block dynamicText:
  var t = newText("Fit me", CharStyle(family: "", size: 20, color: 0xFF000000'u32, hScale: 1, vScale: 1), 10, 10)
  t.boxW = 300
  t.boxH = 200
  doAssert t.fitScale == 1, "not fitted until asked"
  t.fit = true
  let k1 = t.fitScale
  doAssert k1 > 1.5, "a big box: bigger letters (" & $k1 & ")"
  t.boxW = 100
  t.boxH = 60
  let k2 = t.fitScale
  doAssert k2 < k1
  let l = layoutText(t)
  doAssert l.lines.len > 0 and l.x1 - l.x0 <= 100 + 1 and l.lines[^1].baseline + l.lines[^1].descent <= 10 + 60 + 1
  doAssert textFrom(t.toJson).fit

block areaAdjustments:
  let d = newDoc(160, 120)
  for y in 0 ..< 120:
    for x in 0 ..< 160:
      d.layer.px[y * 160 + x] = argb(255, 100 + (if (x div 16) mod 2 == 0: 40 else: 0), 120, 110 + y div 3)
  inc d.layer.ver
  d.markAll()
  let before = d.flattened()
  let L = d.newAdjustmentLayer(Adjustment(kind: "Clarity", args: @[80.0]))
  let c1 = d.flattened()
  doAssert c1 != before, "Clarity"
  # (the midtone edges stronger: the bright stripe's last column brighter)
  doAssert rOf(c1[60 * 160 + 15]) > rOf(before[60 * 160 + 15])
  L.adjust = Adjustment(kind: "Grain", args: @[60.0, 25, 50, 3])
  inc L.ver
  let g1 = d.flattened()
  doAssert g1 != before and g1 != c1, "Grain"
  L.adjust = Adjustment(kind: "Dehaze", args: @[70.0])
  inc L.ver
  let h1 = d.flattened()
  doAssert h1 != before, "Dehaze"
  # hidden, or its mask black: nothing
  L.visible = false
  doAssert d.flattened() == before
  L.visible = true
  for p in L.px.mitems: p = grayPx(0)
  inc L.ver
  doAssert d.flattened() == before
  # kept in a .rpd
  let path = getTempDir() / "retro-area.rpd"
  d.saveRpd(path)
  doAssert loadRpd(path).layers[^1].adjust.kind == "Dehaze"
  removeFile(path)

block locksAndLinks:
  let d = newDoc(40, 30)
  let a = d.addLayer("A")
  let b = d.addLayer("B")
  let c = d.addLayer("C")
  for L in [a, b, c]:
    L.px[0] = argb(255, 1, 2, 3)
    inc L.ver
  d.cur = d.layers.find(a)
  doAssert d.movedLayers == @[d.layers.find(a)]
  d.linkLayers(@[d.layers.find(a), d.layers.find(c)])
  doAssert a.link != 0 and a.link == c.link and b.link == 0
  doAssert d.movedLayers == @[d.layers.find(a), d.layers.find(c)], "linked: they move together"
  # the move: both moved, not B
  d.beginStep("Move")
  var lift = d.beginMove(0)
  d.moveTo(lift, 5, 0)
  d.endMove(lift)
  d.endStep()
  doAssert (a.px[5] shr 24) == 255 and (c.px[5] shr 24) == 255 and (b.px[0] shr 24) == 255
  # locked in place: not moved
  c.lockPosition = true
  d.beginStep("Move")
  lift = d.beginMove(0)
  d.moveTo(lift, 3, 0)
  d.endMove(lift)
  d.endStep()
  doAssert (a.px[8] shr 24) == 255 and (c.px[5] shr 24) == 255 and (c.px[8] shr 24) == 0
  d.unlinkLayers(@[d.layers.find(a)])
  doAssert a.link == 0 and c.link == 0, "a link of one goes"
  # kept in a .rpd
  c.lockPixels = true
  let path = getTempDir() / "retro-locks.rpd"
  d.saveRpd(path)
  let back = loadRpd(path)
  doAssert back.layers[^1].lockPixels and back.layers[^1].lockPosition
  removeFile(path)

echo "test_photocc: ok"
