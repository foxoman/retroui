## Tests of today's Photoshop features made offline: Layer Cleanup,
## Harmonize with a shadow, Colorize from color hints, Content-Aware
## Expand, artboards, the Patch's options, Dynamic Text, the Clarity,
## Dehaze and Grain adjustment layers, the locks and linked layers.

import std/[os, math, sequtils]
import retroui/[gfx, photo, photosmart, photocc, textengine]
{.push warning[UnusedImport]: off.}
import retroui/photoshapes   # (imported for what it sets up in retroui/photo: how shape layers are drawn)
{.pop.}
{.push warning[UnusedImport]: off.}
import retroui/photodevelop   # (imported for what it sets up in retroui/photo: the adjustment layers' tables)
{.pop.}

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
  doAssert b.name == "Blue Shape, Top Left", b.name
  doAssert c.name == "Kept"
  doAssert genericName("Layer 12") and genericName("Layer 3 copy 2") and genericName("Group 1") and
           not genericName("Sky")
  d.undo()
  doAssert d.layers.len == n0, "undone"

block renameByContent:
  # Rename Layers by Content: the picked layers, whatever their names; a group after its layers
  let d = newDoc(80, 60)
  let sky = d.addLayer("My layer")
  for y in 0 ..< 25:
    for x in 0 ..< 80: sky.px[y * 80 + x] = argb(255, 90, 150, 230)
  inc sky.ver
  let grass = d.addLayer("Another")
  for y in 40 ..< 60:
    for x in 0 ..< 80: grass.px[y * 80 + x] = argb(255, 40, 160, 50)
  inc grass.ver
  let dot = d.addLayer("Dot")
  for y in 45 ..< 50:
    for x in 70 ..< 75: dot.px[y * 80 + x] = argb(255, 230, 30, 30)
  inc dot.ver
  d.beginStep("Rename Layers")
  let n = d.autoRename(@[d.layers.find(sky), d.layers.find(grass), d.layers.find(dot), 0])
  d.endStep()
  doAssert n == 3, $n
  doAssert sky.name == "Sky" and grass.name == "Grass", sky.name & " / " & grass.name
  doAssert dot.name == "Red Shape, Bottom Right", dot.name
  doAssert d.layers[0].name == "Background"
  let g = d.groupLayers(@[d.layers.find(dot), d.layers.find(grass)])
  doAssert g != nil
  discard d.autoRename(@[d.layers.find(g)])
  doAssert g.name == "Red Shape, Bottom Right and Grass", g.name
  d.undo()
  d.undo()
  doAssert d.layers.anyIt(it.name == "My layer"), "undone"

block objectFindChange:
  # Find/Change's Object search: shapes by their fill, stroke and width, texts by their color,
  # by kind, name, opacity, Object Style -- and changed all at once, in one step
  let d = newDoc(100, 80)
  let red1 = d.addShapeLayer(ShapeData(path: rectPath(5, 5, 30, 30), fill: solidPaint(0xFFE02020'u32)), "Box A")
  let red2 = d.addShapeLayer(ShapeData(path: rectPath(40, 5, 70, 30), fill: solidPaint(0xFFE12121'u32),
                                       stroke: solidPaint(0xFF000000'u32), strokeWidth: 3), "Box B")
  let blue = d.addShapeLayer(ShapeData(path: rectPath(5, 40, 30, 70), fill: solidPaint(0xFF2020E0'u32)), "Other")
  var st = defaultStyle()
  st.color = 0xFFE02020'u32
  let txt = d.addTextLayer(newText("Red words", st, 40, 60))
  let q = ObjectQuery(kind: okAny, byFill: true, fill: 0xFFE02020'u32)
  doAssert d.findObjects(q) == @[d.layers.find(red1), d.layers.find(red2), d.layers.find(txt)], $d.findObjects(q)
  doAssert d.findObjects(ObjectQuery(kind: okShape, byFill: true, fill: 0xFFE02020'u32)).len == 2
  doAssert d.findObjects(ObjectQuery(kind: okShape, byWidth: true, strokeWidth: 3)) == @[d.layers.find(red2)]
  doAssert d.findObjects(ObjectQuery(kind: okShape, byStroke: true, stroke: 0xFF000000'u32)).len == 1
  doAssert d.findObjects(ObjectQuery(kind: okText)) == @[d.layers.find(txt)]
  doAssert d.findObjects(ObjectQuery(name: "box")).len == 2
  doAssert d.findObjects(ObjectQuery(byOpacity: true, opacity: 100)).len == 4
  d.beginStep("Change All")
  let n = d.changeObjects(q, ObjectChange(setFill: true, fill: 0xFF20A040'u32, setOpacity: true, opacity: 60))
  d.endStep()
  doAssert n == 3
  doAssert red1.shape.fill.color == 0xFF20A040'u32 and red2.shape.fill.color == 0xFF20A040'u32
  doAssert txt.text.spans[0].style.color == 0xFF20A040'u32 and txt.opacity == 60
  doAssert blue.shape.fill.color == 0xFF2020E0'u32 and blue.opacity == 100
  doAssert red1.px[15 * 100 + 15] == 0xFF20A040'u32, "drawn again"
  d.undo()
  doAssert red1.shape.fill.color == 0xFFE02020'u32 and txt.opacity == 100, "undone"
  # by Object Style; and one given
  d.objectStyles.add ObjectStyleDef(name: "Thick", useStroke: true,
                                    shape: ShapeData(stroke: solidPaint(0xFF0000FF'u32), strokeWidth: 6))
  doAssert d.changeObjects(ObjectQuery(kind: okShape, name: "Other"), ObjectChange(objectStyle: "Thick")) == 1
  doAssert blue.objectStyle == "Thick" and blue.shape.strokeWidth == 6
  doAssert d.findObjects(ObjectQuery(objectStyle: "Thick")) == @[d.layers.find(blue)]
  doAssert d.findObjects(ObjectQuery(kind: okShape, objectStyle: "[None]")).len == 2

block graphicStylesArtboardsFeather:
  # Graphic Styles: a shape's look kept by name, given to another (its outline kept), saved;
  # Artboard Options: its color and lock; Gradient Feather: the layer fading across
  let d = newDoc(200, 100, 0xFFFFFFFF'u32)
  let a = d.addShapeLayer(ShapeData(path: rectPath(10, 10, 60, 60), fill: solidPaint(0xFFC03030'u32),
                                    stroke: solidPaint(0xFF000000'u32), strokeWidth: 4), "A")
  a.opacity = 70
  let b = d.addShapeLayer(ShapeData(path: rectPath(100, 10, 190, 90), fill: solidPaint(0xFF3030C0'u32)), "B")
  var g = graphicStyleOf(a, "Red Box")
  d.graphicStyles.add g
  d.beginStep("Graphic Style")
  d.touchLayers()
  d.applyGraphicStyle(b, "Red Box")
  d.endStep()
  doAssert b.shape.fill.color == 0xFFC03030'u32 and b.shape.strokeWidth == 4 and b.opacity == 70
  let (x0, y0, x1, y1) = pathBounds(b.shape.path)
  doAssert x0 == 100 and y0 == 10 and x1 == 190 and y1 == 90, "its outline kept"
  let back = graphicStyleFromJson(graphicStyleToJson(g))
  doAssert back.name == "Red Box" and back.look.fill.color == 0xFFC03030'u32 and back.opacity == 70
  d.undo()
  doAssert b.shape.fill.color == 0xFF3030C0'u32, "undone"
  # an artboard's color (its paper)
  let ab = d.addArtboard(rect(0, 0, 100, 100), "Board")
  doAssert d.artboardColor(ab) == 0xFFFFFFFF'u32
  d.setArtboardColor(ab, 0xFFEEDDCC'u32)
  doAssert d.artboardColor(ab) == 0xFFEEDDCC'u32
  d.setArtboardColor(ab, 0)
  doAssert d.artboardColor(ab) == 0, "transparent: no paper shown"
  # Gradient Feather: opaque at its start, gone at its end
  let e = newDoc(200, 50, 0xFFFFFFFF'u32)
  let L = e.addLayer("Fade")
  for k in 0 ..< L.px.len: L.px[k] = 0xFFFF0000'u32
  L.gradFeather = GradientFeather(on: true, angle: 0, startOpacity: 100, endOpacity: 0, startAt: 0, endAt: 100)
  inc L.ver
  e.markAll()
  let f = e.flattened(0xFFFFFFFF'u32)
  let left = f[25 * 200 + 2]
  let right = f[25 * 200 + 197]
  doAssert gOf(left) < 20 and gOf(right) > 235, $(gOf(left), gOf(right))
  let mid = gOf(f[25 * 200 + 100])
  doAssert mid in 90 .. 165, $mid
  L.gradFeather.on = false
  inc L.ver
  e.markAll()
  doAssert gOf(e.flattened(0xFFFFFFFF'u32)[25 * 200 + 197]) < 5, "off: as it was"

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
  # (the drawing program's: pages of the canvas the document keeps, not layers -- the artwork
  # anywhere on the canvas, on one or round them)
  let d = newDoc(200, 120, 0)
  d.beginStep("New Artboard")
  let n = d.addArtboard(rect(10, 10, 60, 40), color = 0xFFFFFFFF'u32)
  d.endStep()
  doAssert n == 0 and d.boards.len == 1 and d.boardCur == 0 and d.artboardName(0) == "01 - Artboard 1"
  doAssert d.w == 230 and d.h == 150 and d.boards[0].r == rect(40, 40, 60, 40) and d.grown == (30, 30),
           "the canvas grown round it (room for artwork beside it): " & $d.boards[0].r & " " & $d.w & "x" & $d.h
  doAssert d.layers.len == 1, "no layer made for it"
  let L = d.layers[0]
  for y in 50 ..< 60:
    for x in 50 ..< 60: L.px[y * d.w + x] = argb(255, 255, 0, 0)
  inc L.ver
  let M = d.addLayer("Blue")
  for y in 120 ..< 130:
    for x in 150 ..< 160: M.px[y * d.w + x] = argb(255, 0, 0, 255)
  inc M.ver
  d.markAll()
  doAssert d.artboardArt(0) == @[L], "on it: the red, not the blue off it"
  doAssert d.artboardAt(45, 45) == 0 and d.artboardAt(150, 100) == -1
  # its picture: what is on it over its paper
  let pic = d.artboardPicture(0)
  doAssert pic.w == 60 and pic.h == 40 and rgbOf(pic.px[15 * 60 + 15]) == (255, 0, 0) and
           pic.px[0] == 0xFFFFFFFF'u32, "its picture: the red over white paper"
  # moved, with its artwork
  d.beginStep("Move Artboard")
  d.moveArtboard(0, 50, 20)
  d.endStep()
  doAssert d.boards[0].r == rect(90, 60, 60, 40) and d.w == 230
  doAssert L.px[75 * d.w + 105] == argb(255, 255, 0, 0) and L.px[55 * d.w + 55] == 0, "its artwork with it"
  # alone (Move Artwork with Artboard off): its artwork stays
  d.beginStep("Move Artboard")
  d.moveArtboard(0, -50, -20, withArt = false)
  d.endStep()
  doAssert d.boards[0].r == rect(40, 40, 60, 40) and L.px[75 * d.w + 105] == argb(255, 255, 0, 0)
  doAssert d.artboardArt(0).len == 0
  d.undo()
  doAssert d.boards[0].r == rect(90, 60, 60, 40), "undone"
  # a copy (Alt+drag): its artwork copied too, the canvas grown for it
  d.beginStep("Duplicate Artboard")
  let c = d.duplicateArtboard(0, 0, 50)
  d.endStep()
  doAssert c == 1 and d.boards[1].r == rect(90, 110, 60, 40) and d.boards[1].name == "Artboard 1 copy" and
           d.h == 190, $d.boards[1].r & " " & $d.h
  proc copyOf(d: Doc; a, b: Layer): Layer =
    for X in d.layers:
      if X != a and X != b: return X
  doAssert d.layers.len == 3 and d.copyOf(L, M).px[125 * d.w + 105] == argb(255, 255, 0, 0), "its artwork copied"
  d.undo()
  doAssert d.boards.len == 1 and d.layers.len == 2 and d.h == 150, "the copy undone: the canvas as it was"
  d.redo()
  doAssert d.boards.len == 2 and d.layers.len == 3 and d.h == 190 and d.boards[1].r == rect(90, 110, 60, 40), "redone"
  # rearranged in a row, 10 apart, their artwork with them
  d.beginStep("Rearrange All Artboards")
  d.rearrangeArtboards(alRow, 1, 10)
  d.endStep()
  doAssert d.boards[0].r == rect(90, 60, 60, 40) and d.boards[1].r == rect(160, 60, 60, 40), $d.boards[1].r
  doAssert d.copyOf(L, M).px[75 * d.w + 175] == argb(255, 255, 0, 0), "the copy's artwork with it"
  d.beginStep("Rearrange All Artboards")
  d.rearrangeArtboards(alGridByRow, 1, 10, withArt = false)
  d.endStep()
  doAssert d.boards[1].r == rect(90, 110, 60, 40), "a grid of one column: under it"
  d.undo()
  # fitted to its artwork
  d.beginStep("Fit to Artwork Bounds")
  d.fitArtboardTo(0)
  d.endStep()
  doAssert d.boards[0].r == rect(100, 70, 10, 10), "fitted to the red: " & $d.boards[0].r
  d.undo()
  # renamed, reordered
  d.beginStep("Rename Artboard")
  d.renameArtboard(1, "Back")
  d.endStep()
  d.beginStep("Reorder Artboards")
  d.reorderArtboard(1, 0)
  d.endStep()
  doAssert d.boards[0].name == "Back" and d.boardCur == 0 and d.artboardName(1) == "02 - Artboard 1"
  # kept in a .rpd: their places, names, paper and what they show
  d.boards[1].centerMark = true
  d.setArtboardColor(0, 0xFF102030'u32)
  let path = getTempDir() / "retro-artboard.rpd"
  d.saveRpd(path)
  let back = loadRpd(path)
  removeFile(path)
  doAssert back.boards.len == 2 and back.boards[0].name == "Back" and back.boards[0].r == d.boards[0].r and
           back.boards[0].color == 0xFF102030'u32 and back.boards[1].centerMark and back.boardCur == 0, "kept"
  # deleted: its artwork stays
  d.beginStep("Delete Artboard")
  d.deleteArtboard(0)
  d.endStep()
  doAssert d.boards.len == 1 and d.layers.len == 3
  # a rectangle made an artboard (it goes), then empty ones deleted
  d.beginStep("shape")
  d.touchLayers()
  let S = d.addShapeLayer(ShapeData(path: rectPath(5, 100, 35, 120), fill: solidPaint(0xFF00FF00'u32)), "Rect")
  d.endStep()
  d.beginStep("Convert to Artboards")
  let made = d.convertToArtboards(@[S])
  d.endStep()
  doAssert made.len == 1 and d.boards[made[0]].r.w == 30 and d.boards[made[0]].r.h == 20 and S notin d.layers,
           "a rectangle made an artboard: " & $d.boards[made[0]].r
  d.beginStep("Delete Empty Artboards")
  doAssert d.deleteEmptyArtboards() == 1 and d.boards.len == 1, "the empty one deleted"
  d.endStep()
  # a file of before: its artboard groups made the document's artboards
  let o = newDoc(100, 80, 0)
  let P = o.addShapeLayer(ShapeData(path: rectPath(10, 10, 60, 50), fill: solidPaint(0xFFFFEEDD'u32)), "Page")
  let G = o.groupLayers(@[o.layers.find(P)], "Old Board")
  G.board = rect(10, 10, 50, 40)
  doAssert G.isArtboard
  o.boardsFromGroups()
  doAssert o.boards.len == 1 and o.boards[0].name == "Old Board" and o.boards[0].r == rect(10, 10, 50, 40) and
           o.boards[0].color == 0xFFFFEEDD'u32 and not G.isArtboard and P notin o.layers, "an old file's artboard"

block artboardPages:
  # (artboards as pages: `<#>` in type on one its number, `<##>` how many; facing in spreads;
  # placed by another; dragged in line with them; the artwork moved onto another; page numbers)
  let d = newDoc(400, 300, 0)
  for x in [0, 140, 280]:
    d.beginStep("New Artboard")
    discard d.addArtboard(rect(x, 0, 120, 160), color = 0xFFFFFFFF'u32)
    d.endStep()
  let b1 = d.boards[1].r
  var t = newText("Page <#> of <##>", defaultStyle(), 0, 0)
  t.x = float32(b1.x + 10)
  t.y = float32(b1.y + 20)
  t.boxW = 100
  t.boxH = 30
  d.beginStep("type")
  d.touchLayers()
  let T = d.addTextLayer(t)
  d.endStep()
  doAssert d.boardOfText(T) == 1
  doAssert d.effectiveText(T).plainText == "Page 2 of 3", d.effectiveText(T).plainText
  discard d.syncBoardNumbers()
  doAssert not d.syncBoardNumbers(), "drawn again only when its number changed"
  # numbered from 5: the second is page 6
  d.beginStep("Artboard Numbers")
  d.touchLayers()
  d.boardFirst = 5
  d.endStep()
  doAssert d.effectiveText(T).plainText == "Page 6 of 3" and d.syncBoardNumbers()
  d.undo()
  doAssert d.boardFirst == 0 and d.effectiveText(T).plainText == "Page 2 of 3", "the numbering undone"
  # facing pages: the first alone (a right page), then left and right
  doAssert d.boardSpreads == @[@[0], @[1], @[2]] and d.boardSide(1) == 0
  d.boardFacing = true
  doAssert d.boardSpreads == @[@[0], @[1, 2]] and d.boardSide(0) == 1 and d.boardSide(1) == -1 and
           d.boardSide(2) == 1, $d.boardSpreads
  # Rearrange All > Spreads: the spread's pages touching at the spine, the first where a right page goes
  d.beginStep("Rearrange All Artboards")
  d.rearrangeArtboards(alSpreads, 1, 20)
  d.endStep()
  doAssert d.boards[1].r.x + d.boards[1].r.w == d.boards[2].r.x and d.boards[1].r.y == d.boards[2].r.y,
           "a spread's pages touching: " & $d.boards[1].r & " " & $d.boards[2].r
  doAssert d.boards[0].r.x == d.boards[2].r.x and d.boards[1].r.y == d.boards[0].r.y + d.boards[0].r.h + 20,
           "the first alone on the right of the spine, a spread to a row: " & $d.boards[0].r & " " & $d.boards[1].r
  doAssert d.boardOfText(T) == 1 and d.effectiveText(T).plainText == "Page 2 of 3", "its type moved with it"
  d.undo()
  # placed by another: under it, the gap apart; at its left, touching
  d.beginStep("Place Artboard")
  d.placeArtboard(2, 0, 2, 10)
  d.endStep()
  doAssert d.boards[2].r.x == d.boards[0].r.x and d.boards[2].r.y == d.boards[0].r.y + d.boards[0].r.h + 10,
           "under it: " & $d.boards[2].r
  d.beginStep("Place Artboard")
  d.placeArtboard(2, 1, 1, 0)
  d.endStep()
  doAssert d.boards[2].r.x + d.boards[2].r.w == d.boards[1].r.x and d.boards[2].r.y == d.boards[1].r.y,
           "at its left, touching: " & $d.boards[2].r & " " & $d.boards[1].r
  d.undo()
  d.undo()
  # the Artboard tool's drag: in line with another when near it
  let a0 = d.boards[0].r
  let a1 = d.boards[1].r
  let (sx, sy) = d.snapArtboardMove(1, a0.x + a0.w + 3 - a1.x, a0.y - a1.y + 4, 8, 20)
  doAssert a1.x + sx == a0.x + a0.w and a1.y + sy == a0.y, "touching it, tops in line: " & $(sx, sy) & " " & $d.boards
  let (fx, fy) = d.snapArtboardMove(1, 300, 300, 8, 20)
  doAssert (fx, fy) == (300, 300), "far from all: as dragged"
  # the type moved onto the third: where it was on the second, its number the third's
  d.beginStep("Move to Artboard")
  d.moveToArtboard(@[T], 2)
  d.endStep()
  doAssert d.boardOfText(T) == 2 and d.effectiveText(T).plainText == "Page 3 of 3" and
           int(T.text.x) - d.boards[2].r.x == 10, "moved: " & $T.text.x & " " & $d.boards[2].r
  doAssert d.syncBoardNumbers(), "drawn again: on another one"
  d.undo()
  doAssert d.boardOfText(T) == 1, "undone"
  # page numbers: a folio on each, outside -- the right of a right page, the left of a left one
  d.beginStep("Page Numbers")
  let n = d.artboardFolios(bfBottomOutside, bhTopInside, "Retro", skipEnds = false)
  d.endStep()
  doAssert n == 6, "a folio and a running head on each of the three: " & $n
  var folios: seq[Layer]
  for L in d.layers:
    if L.isText and L.name == "Folio": folios.add L
  doAssert folios.len == 3
  for L in folios:
    let k = d.boardOfText(L)
    doAssert d.effectiveText(L).plainText == $(k + 1), "its number: " & d.effectiveText(L).plainText
    doAssert L.text.para.align == (if d.boardSide(k) < 0: textLeft else: textRight), "outside"
    doAssert L.text.y > float32(d.boards[k].r.y + d.boards[k].r.h div 2), "at the bottom"
  doAssert d.artboardFolios(bfBottomMiddle, skipEnds = true) == 1, "again: the old ones gone, not on the ends"
  doAssert d.artboardFolios(bfNone) == 0
  for L in d.layers: doAssert L.name notin ["Folio", "Running Head"], "removed"
  # kept in a .rpd: the first number and facing
  d.boardFirst = 3
  let path = getTempDir() / "retro-artboard-pages.rpd"
  d.saveRpd(path)
  let back = loadRpd(path)
  removeFile(path)
  doAssert back.boardFirst == 3 and back.boardFacing, "kept"

block constraints:
  # (where a box goes when its board changes size, by its pins; then layers on a board resized)
  let was = rect(0, 0, 200, 100)
  let now = rect(0, 0, 300, 160)
  let b = rect(150, 70, 40, 20)            # (10 from the right, 10 from the bottom)
  doAssert pinnedBox(b, was, now, {}) == b, "no pins: it stays"
  doAssert pinnedBox(b, was, now, {lpRight, lpBottom}) == rect(250, 130, 40, 20), "right and bottom kept"
  doAssert pinnedBox(b, was, now, {lpLeft, lpRight, lpTop}) == rect(150, 70, 140, 20), "both sides: stretched"
  doAssert pinnedBox(b, was, now, {lpCenterX, lpTop}) == rect(235, 70, 40, 20), "centered across, in proportion"
  doAssert pinnedBox(b, was, now, {lpScale}) == rect(225, 112, 60, 32), "scaled with the board"
  doAssert pinnedBox(b, was, rect(50, 20, 200, 100), {lpLeft}) == rect(200, 90, 40, 20), "the board moved: with it"
  let d = newDoc(400, 300, 0xFFC0C0C0'u32)
  d.beginStep("New Artboard")
  let gi = d.addArtboard(rect(10, 10, 200, 100), color = 0xFFFFFFFF'u32)
  d.endStep()
  let ob = d.boards[gi].r
  d.beginStep("shapes")
  d.touchLayers()
  let bar = d.addShapeLayer(ShapeData(path: rectPath(ob.x.float + 10, ob.y.float + 80, ob.x.float + 190,
                                                     ob.y.float + 90), fill: solidPaint(0xFF0000FF'u32)), "Bar")
  bar.pins = {lpLeft, lpRight, lpBottom}
  let free = d.addShapeLayer(ShapeData(path: rectPath(ob.x.float + 20, ob.y.float + 20, ob.x.float + 40,
                                                      ob.y.float + 40), fill: solidPaint(0xFFFF0000'u32)), "Free")
  d.endStep()
  doAssert bar in d.artboardArt(gi) and free in d.artboardArt(gi), "both on the board"
  d.beginStep("Resize Artboard")
  d.resizeArtboard(gi, rect(ob.x, ob.y, 300, 160))
  d.endStep()
  let nb = d.boards[gi].r
  doAssert nb.w == 300 and nb.h == 160
  doAssert d.layerBox(bar) == rect(nb.x + 10, nb.y + 140, 280, 10),
           "the bar: along the bottom, as wide as the board less its gaps: " & $d.layerBox(bar)
  doAssert d.layerBox(free) == rect(nb.x + 20, nb.y + 20, 20, 20), "no pins: where it was"
  let path = getTempDir() / "retro-pins.rpd"
  d.saveRpd(path)
  let back = loadRpd(path)
  removeFile(path)
  var kept = false
  for L in back.layers:
    if L.name == "Bar": kept = L.pins == {lpLeft, lpRight, lpBottom}
  doAssert kept, "the pins kept in the file"
  d.undo()
  doAssert d.boards[gi].r == ob and d.layerBox(bar).w == 180, "undone"

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
