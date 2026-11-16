## Tests of Retro Atelier's additions to stand with Photoshop, Illustrator
## and InDesign (5.4), run headless: every new filter from its menu name,
## Lens Blur's sources, the new layers, tools, panels and dialogs.

import std/[strutils, os, math]
import retroui/uirelays/input
import harness

const photoUnderTest = true
include ../examples/photo

let home = getTempDir() / "retro-photo-paritytest"
removeDir(home)
createDir(home)
putEnv("HOME", home)
setCurrentDir(home)

fakeDriver()
setup()
startApp("photo", W, H)
view = photoFrame
run(3)

proc sample(w, h: int): Doc =
  result = newDoc(w, h, 0xFFFFFFFF'u32, name = "sample")
  let L = result.layer
  for y in 0 ..< h:
    for x in 0 ..< w:
      let v = if (x div 6 + y div 6) mod 2 == 0: 50 else: 200
      L.px[y * w + x] = argb(255, (v + x * 2) mod 256, (v + y * 3) mod 256, (x * y) mod 256)
  inc L.ver
  result.markAll()
  result.modified = false

proc mouse(kind: EventKind; x, y: int; mods: set[Modifier] = {}; clicks = 1) =
  var e = Event(kind: kind, x: x, y: y, mods: mods, fromMouse: true)
  if kind in {MouseDownEvent, MouseUpEvent}:
    e.button = LeftButton
    e.clicks = clicks
  queue.add e

proc strokeAt(d: Doc; pts: seq[(float, float)]; mods: set[Modifier] = {}) =
  ## (down at the first point of the image, moved through the rest, up at the last -- the window's input)
  proc at(x, y: float): (int, int) = active.view.toScreen(d, x, y)
  let a = at(pts[0][0], pts[0][1])
  mouse(MouseMoveEvent, a[0], a[1], mods)
  mouse(MouseDownEvent, a[0], a[1], mods)
  run(1)
  for k in 1 ..< pts.len:
    let b = at(pts[k][0], pts[k][1])
    mouse(MouseMoveEvent, b[0], b[1], mods)
    run(1)
  let e = at(pts[^1][0], pts[^1][1])
  mouse(MouseUpEvent, e[0], e[1], mods)
  run(2)

proc line(x0, y0, x1, y1: float; n = 8): seq[(float, float)] =
  for k in 0 .. n: result.add (x0 + (x1 - x0) * k.float / n.float, y0 + (y1 - y0) * k.float / n.float)

proc openLine(x0, y0, x1, y1: float): Path =
  var sp = SubPath()
  for (x, y) in [(x0, y0), (x1, y1)]: sp.pts.add PathPoint(p: (x, y), inH: (x, y), outH: (x, y))
  Path(subs: @[sp])

proc commitPara() =
  ## (the paragraph dialog's OK)
  okPara = true
  run(2)
  doAssert not poDlg.open

proc useVector(mode: int) =
  for g, grp in toolGroups:
    for k, it in grp.items:
      if it.tool == tVector and it.mode == mode: pickTool(g, k)
  run(1)
  doAssert tool == tVector and vecMode == mode

block everyNewFilter:
  # each new filter is in the menus' lists, runs by its name with its first settings, changes
  # the picture and is undone
  let d = sample(80, 60)
  addDoc(d)
  run(2)
  for n in @galleryArtistic & @galleryBrush & @galleryDistort & @gallerySketch & @galleryStylize & @galleryTexture:
    doAssert filters.hasKey(n), n
  let fresh = @["Fresco", "Neon Glow", "Palette Knife", "Rough Pastels", "Smudge Stick", "Underpainting",
                "Dark Strokes", "Sprayed Strokes", "Diffuse Glow", "Glass", "Ocean Ripple", "Chalk & Charcoal",
                "Conté Crayon", "Note Paper", "Plaster", "Water Paper", "Glowing Edges", "HSB/HSL", "Average",
                "Box Blur", "Shape Blur", "Smart Blur", "Lens Blur"]
  let before = d.layer.px
  for n in fresh:
    let s = filters[n]
    var vals: seq[float]
    for p in s.params: vals.add p.val
    runFilter(n, vals)
    doAssert d.layer.px != before, n & " changed nothing"
    doAssert lastFilter.name == n
    runCommand("Undo")
    doAssert d.layer.px == before, n & ": undone"

block lensBlurSources:
  # Lens Blur's Source list: None, Transparency, Layer Mask, Estimated Depth and the saved
  # selections; a depth map keeps what is at the focal distance sharp
  let d = sample(80, 60)
  addDoc(d)
  run(2)
  var m = newSeq[uint8](d.w * d.h)
  for y in 0 ..< d.h:
    for x in 0 ..< d.w: m[y * d.w + x] = if x < 40: 0 else: 255
  d.alphas.add AlphaChannel(name: "Far Half", m: m)
  runCommand("Lens Blur...")
  doAssert fOpen and fSpec.name == "Lens Blur"
  doAssert fSpec.params[0].choices == @["None", "Transparency", "Layer Mask", "Estimated Depth", "Far Half"]
  fOpen = false
  run(2)
  let before = d.layer.px
  var vals: seq[float]
  for p in filters["Lens Blur"].params: vals.add p.val
  vals[0] = 4                 # (the saved selection: the left half near, in focus)
  vals[4] = 8
  runFilter("Lens Blur", vals)
  for y in 0 ..< d.h:
    for x in 0 ..< 30: doAssert d.layer.px[y * d.w + x] == before[y * d.w + x], "in focus: kept"
  var changed = 0
  for y in 0 ..< d.h:
    for x in 50 ..< d.w:
      if d.layer.px[y * d.w + x] != before[y * d.w + x]: inc changed
  doAssert changed > d.h * 30 div 2
  runCommand("Undo")
  vals[0] = 3                 # (the depth estimated from the photo: runs, changes it)
  runFilter("Lens Blur", vals)
  doAssert d.layer.px != before
  runCommand("Undo")

block lightPatternMattingPreview:
  # Image > Adjustments > Light, as a dialog and as an adjustment layer
  let d = sample(60, 40)
  addDoc(d)
  run(2)
  let before = d.layer.px
  runCommand("Light...")
  doAssert adjOpen and adjKind == akLight
  lgE = 50
  lgS = 40
  run(3)
  doAssert d.layer.px != before
  endAdjust(true)
  run(2)
  runCommand("Undo")
  doAssert d.layer.px == before
  startAdjustLayer(akLight)
  lgH = -50
  run(3)
  doAssert d.layers[^1].adjust.kind == "Light" and d.layers[^1].adjust.args[2] == -50
  endAdjust(true)
  # a Pattern Overlay from the Layer Style dialog's page
  let L = d.addLayer("Shape")
  for y in 5 ..< 30:
    for x in 5 ..< 50: L.px[y * d.w + x] = 0xFFC02020'u32
  d.cur = d.layers.find(L)
  d.markAll()
  startLayerStyle(ord(fxPatternOverlay))
  run(2)
  doAssert lsDlg.open and L.fx.fx[fxPatternOverlay].on and L.fx.fx[fxPatternOverlay].pattern.len > 0
  lsDlg.open = false
  if d.stepOpen: d.endStep()
  # Layer > Matting: Remove White Matte and Defringe by their menu names
  doAssert filters.hasKey("Defringe") and filters.hasKey("Remove Black Matte") and filters.hasKey("Remove White Matte")
  for i in 0 ..< L.px.len:
    if L.px[i] == 0: L.px[i] = 0x80FFFFFF'u32
  let wasL = L.px
  runFilter("Defringe", @[2.0])
  doAssert L.px != wasL
  # View > Pattern Preview: the brush wraps round; View > Show > Pixel Grid
  runCommand("Pattern Preview")
  doAssert d.patternPreview and paintOpts(tBrush, d).wrap
  run(2)
  runCommand("Pattern Preview")
  doAssert not d.patternPreview
  let pg = pixelGridOn
  runCommand("Pixel Grid")
  doAssert pixelGridOn != pg
  runCommand("Pixel Grid")

block theDrawingProgramsTools:
  let d = newDoc(400, 300, 0xFFFFFFFF'u32)
  addDoc(d)
  runCommand("Fit on Screen")
  run(3)
  fg = 0xFF2040C0'u32
  # the Paintbrush (Vector): a stroke with the brush, its path kept to edit
  useVector(3)
  vbrush = StrokeBrush(kind: sbCalligraphic, name: "10 pt. Flat", angle: 30, roundness: 10)
  let n0 = d.layers.len
  d.strokeAt(@[(40.0, 200.0), (80.0, 150.0), (120.0, 130.0), (160.0, 150.0), (200.0, 190.0)])
  doAssert d.layers.len == n0 + 1 and d.current.isShape
  doAssert d.current.shape.brush.kind == sbCalligraphic and d.current.shape.stroke.color == fg
  doAssert d.current.shape.path.subs[0].pts.len >= 2
  runCommand("Undo")
  doAssert d.layers.len == n0
  # the Blob Brush: two strokes of one color, one shape
  useVector(4)
  d.strokeAt(line(50, 50, 150, 50))
  doAssert d.layers.len == n0 + 1
  let B = d.current
  d.strokeAt(line(100, 30, 100, 120))
  doAssert d.layers.len == n0 + 1 and d.current == B, "merged with the blob of its color"
  let (bx0, by0, bx1, by1) = pathBounds(B.shape.path)
  doAssert bx0 < 50 and bx1 > 150 and by0 < 35 and by1 > 115
  # the Eraser (Shapes) through it
  useVector(8)
  d.clearPicks()
  d.cur = d.layers.find(B)
  let before = B.shape.path
  d.strokeAt(line(120, 20, 120, 130))
  doAssert B.shape.path != before
  # Scissors on a closed ellipse: open
  let E = d.addShapeLayer(ShapeData(path: ellipsePath(220, 40, 360, 140), fill: solidPaint(0xFFC03030'u32)))
  useVector(9)
  d.strokeAt(@[(360.0, 90.0)])
  doAssert not E.shape.path.subs[0].closed, status
  # the Knife right across a rectangle: two shapes
  let R = d.addShapeLayer(ShapeData(path: rectPath(220, 180, 360, 260), fill: solidPaint(0xFF30A040'u32)))
  d.clearPicks()
  d.cur = d.layers.find(R)
  let nk = d.layers.len
  useVector(10)
  d.strokeAt(line(290, 170, 290, 270))
  doAssert d.layers.len == nk + 1, status
  # the Path Eraser across a line: two pieces; Join puts them together again
  let Ln = d.addShapeLayer(ShapeData(path: openLine(20, 270, 200, 270), stroke: solidPaint(0xFF000000'u32),
                                     strokeWidth: 3, fill: ShapePaint(kind: spNone)))
  d.clearPicks()
  d.cur = d.layers.find(Ln)
  useVector(6)
  d.strokeAt(line(110, 260, 110, 280, 4))
  doAssert Ln.shape.path.subs.len == 2, $Ln.shape.path.subs.len
  useVector(7)
  let gapA = Ln.shape.path.subs[0].pts[^1].p
  let gapB = Ln.shape.path.subs[1].pts[0].p
  d.strokeAt(line(gapA[0], gapA[1], gapB[0], gapB[1], 3))
  doAssert Ln.shape.path.subs.len == 1, status
  # Smooth: a jagged line made smooth (fewer points)
  var z = SubPath()
  for i in 0 .. 20:
    let q = (20.0 + i.float * 8, 230.0 + (if i mod 2 == 0: 4.0 else: -4.0))
    z.pts.add PathPoint(p: q, inH: q, outH: q)
  let Z = d.addShapeLayer(ShapeData(path: Path(subs: @[z]), stroke: solidPaint(0xFF000000'u32), strokeWidth: 2,
                                    fill: ShapePaint(kind: spNone)))
  d.clearPicks()
  d.cur = d.layers.find(Z)
  useVector(5)
  pathEraserSize = 12
  d.strokeAt(line(20, 230, 180, 230))
  doAssert Z.shape.path.subs[0].pts.len < 10, $Z.shape.path.subs[0].pts.len
  # the Magic Wand (Shapes): the shapes of a color
  let d2 = newDoc(300, 200, 0xFFFFFFFF'u32)
  addDoc(d2)
  runCommand("Fit on Screen")
  run(2)
  let A1 = d2.addShapeLayer(ShapeData(path: rectPath(10, 10, 60, 60), fill: solidPaint(0xFFFF0000'u32)))
  let A2 = d2.addShapeLayer(ShapeData(path: rectPath(100, 10, 150, 60), fill: solidPaint(0xFFF00808'u32)))
  let A3 = d2.addShapeLayer(ShapeData(path: rectPath(200, 10, 250, 60), fill: solidPaint(0xFF0000FF'u32)))
  useVector(1)
  d2.strokeAt(@[(30.0, 30.0)])
  doAssert A1.picked and A2.picked and not A3.picked, $d2.pickedLayers.len
  # Group Selection: one, then its group; dragged, they move
  d2.clearPicks()
  A1.picked = true
  A2.picked = true
  discard d2.groupLayers(@[d2.layers.find(A1), d2.layers.find(A2)], "Pair")
  useVector(0)
  d2.strokeAt(@[(30.0, 30.0)])
  doAssert A1.picked and not A2.picked
  d2.strokeAt(@[(30.0, 30.0)])
  doAssert A1.picked and A2.picked, "the second click: its group"
  d2.strokeAt(line(30, 30, 50, 60, 4))
  doAssert abs(pathBounds(A2.shape.path)[0] - 120) < 1.5, $pathBounds(A2.shape.path)
  runCommand("Undo")
  doAssert abs(pathBounds(A2.shape.path)[0] - 100) < 0.5
  # the Lasso (Points): two corners picked, Delete takes them
  d2.clearPicks()
  d2.cur = d2.layers.find(A3)
  useVector(2)
  d2.strokeAt(@[(190.0, 0.0), (240.0, 0.0), (240.0, 20.0), (190.0, 20.0), (190.0, 0.0)])
  doAssert vecPts.layer == A3 and vecPts.pts.len == 1, $vecPts.pts.len
  d2.strokeAt(@[(190.0, 0.0), (260.0, 0.0), (260.0, 20.0), (190.0, 20.0), (190.0, 0.0)])
  doAssert vecPts.pts.len == 2
  runCommand("Clear")
  doAssert A3.shape.path.subs[0].pts.len == 2
  # the Width tool: a press on the stroke, dragged out: wider there
  let W = d2.addShapeLayer(ShapeData(path: openLine(20, 150, 280, 150), stroke: solidPaint(0xFF000000'u32),
                                     strokeWidth: 4, fill: ShapePaint(kind: spNone)))
  useVector(11)
  d2.strokeAt(@[(150.0, 150.0), (150.0, 160.0), (150.0, 170.0)])
  doAssert W.shape.widths.len >= 3, $W.shape.widths.len
  var widest = 0.0
  for wp in W.shape.widths: widest = max(widest, wp.w)
  doAssert widest > 5, $widest
  # Arc, the grids, the Flare: the Shape tool's new kinds
  for (kind, grp) in [(9, false), (10, false), (11, false), (12, true)]:
    for g, gr in toolGroups:
      for k, it in gr.items:
        if it.tool == tShape and it.mode == kind: pickTool(g, k)
    run(1)
    let nl = d2.layers.len
    d2.strokeAt(line(40, 80, 140, 130, 4))
    doAssert d2.layers.len > nl, shapeNames[kind]
    if grp: doAssert d2.current.group or d2.layers.len >= nl + 4, "the Flare: its parts in a group"

block liveEffectsBrushesAppearance:
  let d = newDoc(300, 200, 0xFFFFFFFF'u32)
  addDoc(d)
  run(2)
  let S = d.addShapeLayer(ShapeData(path: rectPath(50, 50, 150, 150), fill: solidPaint(0xFF3060C0'u32),
                                    stroke: solidPaint(0xFF000000'u32), strokeWidth: 3))
  let p0 = S.shape.path
  # a live effect: in its box, on the shape as it is set; Cancel takes it back, OK keeps it
  runCommand("Zig Zag...")
  doAssert leDlg.open
  run(2)
  doAssert S.shape.effects.len == 1 and S.shape.path == p0, "the path itself as it was"
  leDlg.open = false
  run(2)
  doAssert S.shape.effects.len == 0
  runCommand("Warp: Flag...")
  run(2)
  doAssert S.shape.effects.len == 1 and S.shape.effects[0].kind == leWarp and S.shape.effects[0].style == 7
  lePending = false                 # (OK)
  leDlg.open = false
  if d.stepOpen: d.endStep()
  doAssert S.shape.effects.len == 1
  # Brushes (Vector) and Appearance panels drawn; a brush given to the shape from the panel's list
  showPanel("vbrushes")
  showPanel("appearance")
  run(3)
  S.picked = true
  vbrush = strokeBrushOf("Chain")
  var sh = S.shape
  sh.brush = vbrush
  sh.appearance.add Appearance(kind: apStroke, paint: solidPaint(0xFFFF0000'u32), width: 12, align: saCenter,
                               opacity: 100, below: true)
  d.setShape(S, sh)
  run(2)
  doAssert S.px.len > 0
  # Expand Appearance: what it draws made shapes of their own
  let n0 = d.layers.len
  runCommand("Expand Appearance")
  doAssert d.layers.len == n0 + 2, $d.layers.len
  runCommand("Undo")
  doAssert d.layers.len == n0
  # saved and opened: brush, widths, effects, appearance kept
  let path = getTempDir() / "parity-shapes.rpd"
  saveRpd(d, path)
  let back = loadRpd(path)
  var found = false
  for L in back.layers:
    if L.isShape and L.shape.brush.kind == sbPattern and L.shape.effects.len == 1 and L.shape.appearance.len == 1:
      found = true
  doAssert found

block repeatTransformEachFramesEyedropper:
  let d = newDoc(400, 300, 0xFFFFFFFF'u32)
  addDoc(d)
  runCommand("Fit on Screen")
  run(2)
  let A = d.addShapeLayer(ShapeData(path: rectPath(20, 20, 60, 60), fill: solidPaint(0xFFFF0000'u32)))
  let B = d.addShapeLayer(ShapeData(path: ellipsePath(100, 20, 160, 80), fill: solidPaint(0xFF00A000'u32),
                                    stroke: solidPaint(0xFF000000'u32), strokeWidth: 5,
                                    brush: StrokeBrush(kind: sbCalligraphic, angle: 45, roundness: 30)))
  # Repeat: Radial, live
  d.cur = d.layers.find(A)
  runCommand("Radial Repeat...")
  run(2)
  doAssert A.shape.effects.len == 1 and A.shape.effects[0].kind == leRepeatRadial
  lePending = false
  leDlg.open = false
  if d.stepOpen: d.endStep()
  # Transform Each: both picked, each turned about its own middle
  d.clearPicks()
  A.picked = true
  B.picked = true
  let a0 = A.shape.path
  let b0 = B.shape.path
  runCommand("Transform Each...")
  doAssert teDlg.open
  teDlg.angle = 45
  run(2)
  doAssert A.shape.path != a0 and B.shape.path != b0
  let (ax0, ay0, ax1, ay1) = pathBounds(A.shape.path)
  doAssert abs((ax0 + ax1) / 2 - 40) < 0.5 and abs((ay0 + ay1) / 2 - 40) < 0.5, "about its own middle"
  teDlg.open = false
  run(2)
  doAssert A.shape.path == a0 and B.shape.path == b0, "closed: taken back"
  # the Eyedropper (Appearance): A takes B's look
  d.clearPicks()
  d.cur = d.layers.find(A)
  tool = tEyedropper
  dropKind = 0
  eyeAppearance = true
  d.strokeAt(@[(130.0, 50.0)])
  doAssert A.shape.fill.color == 0xFF00A000'u32 and A.shape.strokeWidth == 5 and A.shape.brush.kind == sbCalligraphic,
           status
  eyeAppearance = false
  # the Ellipse and Polygon Frame tools
  for (mode, kind) in [(1, "Ellipse"), (2, "Polygon")]:
    for g, gr in toolGroups:
      for k, it in gr.items:
        if it.tool == tCrop and it.mv == mvFrame and it.mode == mode: pickTool(g, k)
    run(1)
    doAssert tool == tCrop and cropKind == 2 and frameShape == mode
    let n = d.layers.len
    d.strokeAt(line(200, 150, 300, 250, 4))
    doAssert d.layers.len == n + 1 and d.current.shape.kind == kind, d.current.shape.kind

block meshAndPerspectiveSelection:
  let d = newDoc(600, 400, 0xFFFFFFFF'u32)
  addDoc(d)
  runCommand("Fit on Screen")
  run(2)
  # the Mesh tool: a click in a shape makes it a mesh with a point there, in the foreground color
  let S = d.addShapeLayer(ShapeData(path: rectPath(50, 50, 250, 250), fill: solidPaint(0xFF2080FF'u32)))
  useVector(12)
  fg = 0xFFFFE000'u32
  d.strokeAt(@[(150.0, 150.0)])
  doAssert S.shape.fill.style == 6 and S.shape.fill.meshCols == 3, $S.shape.fill.meshCols
  let k = S.shape.fill.meshNearest(0.5, 0.5, 0.05)
  doAssert k >= 0 and S.shape.fill.points[k].color == 0xFFFFE000'u32
  # dragged: it moves
  d.strokeAt(@[(150.0, 150.0), (170.0, 150.0), (190.0, 160.0)])
  doAssert abs(S.shape.fill.points[k].x - 0.7) < 0.03, $S.shape.fill.points[k].x
  runCommand("Undo")
  doAssert abs(S.shape.fill.points[k].x - 0.5) < 0.01
  # Perspective Selection: the three-point grid shown, a shape dragged along its left wall
  runCommand("Three Point Perspective")
  let g = d.pgOf
  doAssert g.shown and g.kind == pkThreePoint
  var gg = g
  gg.active = ppLeft
  gg.noActive = false
  d.pgSet(gg)
  let wall = vpPlane(gg.planeQuad(ppLeft))
  let (ax, ay) = wall.toImage(0.6, 0.5)
  let (bx, by) = wall.toImage(0.75, 0.6)
  let T = d.addShapeLayer(ShapeData(path: ontoPlane(rectPath(ax - 6, ay - 6, ax + 6, ay + 6), gg, ppLeft),
                                    fill: solidPaint(0xFF00A040'u32)))
  let before = pathBounds(T.shape.path)
  useVector(13)
  let c = ((before[0] + before[2]) / 2, (before[1] + before[3]) / 2)
  d.strokeAt(@[c, (c[0] - 20, c[1] + 4), (c[0] - 40, c[1] + 8)])
  let after = pathBounds(T.shape.path)
  doAssert after != before, status
  runCommand("Undo")
  doAssert pathBounds(T.shape.path) == before
  discard bx
  discard by

block paragraphsOfTheirOwn:
  # the Paragraph panel while typing: the paragraphs the selection is in, each its own format
  let d = newDoc(600, 400, 0xFFFFFFFF'u32)
  addDoc(d)
  run(2)
  var t = newText("Heading\nFirst body paragraph here.\nSecond one.", typeStyle, 20, 20)
  t.boxW = 500
  t.boxH = 300
  t.columns = 2
  let L = d.addTextLayer(t)
  d.cur = d.layers.find(L)
  tool = tType
  run(1)
  startTypeEdit(active, L, false, 2)
  run(1)
  doAssert te.on
  applyPara("Paragraph Alignment", proc (p: var ParaStyle) = p.align = textCenter)
  doAssert L.text.paraFmtAt(0).align == textCenter and L.text.paraFmtAt(10).align == textLeft
  doAssert curPara().align == textCenter
  # (typing Enter in it: both halves keep it)
  te.caret = 4
  te.anchor = 4
  insertTyped("\n")
  doAssert L.text.paraFmtAt(0).align == textCenter and L.text.paraFmtAt(6).align == textCenter
  # Keep Options: Preview shows it, Cancel puts it back
  te.caret = 0
  te.anchor = 0
  runCommand("Keep Options...")
  run(1)
  doAssert poDlg.open and poDlg.editing
  poDlg.f.keepWithNext = 2
  poDlg.f.startAt = psNextColumn
  run(2)
  doAssert L.text.paraFmtAt(0).keepWithNext == 2, "Preview"
  poDlg.open = false            # (closed from outside: as Cancel)
  run(2)
  doAssert L.text.paraFmtAt(0).keepWithNext == 0
  # ... OK keeps it, for that paragraph only
  runCommand("Keep Options...")
  run(1)
  poDlg.f.keepWithNext = 2
  run(1)
  commitPara()
  doAssert L.text.paraFmtAt(0).keepWithNext == 2 and L.text.paraFmtAt(20).keepWithNext == 0
  # Span Columns and Justification
  runCommand("Span Columns...")
  run(1)
  poDlg.f.spanAll = true
  run(1)
  commitPara()
  doAssert L.text.paraFmtAt(0).spanAll and not L.text.paraFmtAt(20).spanAll
  te.caret = 12
  te.anchor = L.text.runeLen
  runCommand("Justification...")
  run(1)
  doAssert poDlg.f.wordSpacing == [80'i16, 100, 133]
  poDlg.f.wordSpacing = [70'i16, 95, 160]
  poDlg.f.composer = cpParagraph
  run(1)
  commitPara()
  doAssert L.text.paraFmtAt(20).wordSpacing == [70'i16, 95, 160] and L.text.paraFmtAt(20).composer == cpParagraph
  doAssert L.text.paraFmtAt(0).composer == cpAuto
  commitType()
  run(2)
  # (undone with the typing)
  runCommand("Undo")
  doAssert L.text.paraFmts.len == 0 and L.text.para.align == textLeft
  runCommand("Redo")
  doAssert L.text.paraFmtAt(0).spanAll
  # Paragraph Styles to the paragraph the caret is in
  d.redefineStyle(true, "Head", typeStyle, ParaStyle(align: textRight, spanAll: true))
  startTypeEdit(active, L, false, L.text.runeLen - 2)
  run(1)
  let (a, b) = selRange()
  d.applyParaStyle(L, "Head", a, b)
  doAssert L.text.paraFmtAt(L.text.runeLen - 2).styleName == "Head"
  doAssert L.text.paraFmtAt(0).styleName == ""
  doAssert not d.styleOverridden(L, true, L.text.runeLen - 2)
  # (the style redefined: the paragraph that has it changes)
  d.redefineStyle(true, "Head", typeStyle, ParaStyle(align: textCenter))
  doAssert L.text.paraFmtAt(L.text.runeLen - 2).align == textCenter
  doAssert L.text.paraFmtAt(0).align == textCenter and L.text.paraFmtAt(0).styleName == ""
  commitType()
  run(2)
  # Text Frame Options: inset, vertical justification, balance
  d.cur = d.layers.find(L)
  runCommand("Text Frame Options...")
  run(1)
  doAssert tfDlg.open
  tfDlg.inset = [5, 6, 7, 8]
  tfDlg.vjust = ord(vjCenter)
  tfDlg.balance = true
  run(2)
  doAssert L.text.inset == [5'f32, 6, 7, 8] and L.text.vjust == vjCenter and L.text.balance
  tfDlg.open = false
  run(2)
  doAssert L.text.inset == [0'f32, 0, 0, 0] and L.text.vjust == vjTop, "cancelled"

block stylesAsTheLayoutProgram:
  # Next Style: Enter at the end of a Heading paragraph, the next one in Body
  let d = newDoc(600, 400, 0xFFFFFFFF'u32)
  addDoc(d)
  run(2)
  var big = typeStyle
  big.size = 40
  d.redefineStyle(true, "Body", typeStyle, ParaStyle(align: textLeft))
  d.redefineStyle(true, "Heading", big, ParaStyle(align: textCenter, nextStyle: "Body"))
  var t = newText("Title", typeStyle, 20, 20)
  t.boxW = 500
  t.boxH = 300
  let L = d.addTextLayer(t)
  d.cur = d.layers.find(L)
  d.applyParaStyle(L, "Heading")
  tool = tType
  run(1)
  startTypeEdit(active, L, false, 5)
  run(1)
  insertTyped("\n")
  insertTyped("Text")
  doAssert L.text.plainText == "Title\nText"
  doAssert L.text.paraFmtAt(0).styleName == "Heading" and L.text.paraFmtAt(0).align == textCenter
  doAssert L.text.paraFmtAt(7).styleName == "Body" and L.text.paraFmtAt(7).align == textLeft, L.text.paraFmtAt(7).styleName
  doAssert L.text.styleAt(8).size == typeStyle.size        # (Body's letters, not the heading's)
  # Drop Caps and Nested Styles, GREP Styles for the paragraph the caret is in
  d.redefineStyle(false, "Lead", big)
  te.caret = 8
  te.anchor = 8
  runCommand("Drop Caps and Nested Styles...")
  run(1)
  doAssert poDlg.open
  poDlg.f.nested = @[NestedStyle(name: "Lead", look: d.lookOf("Lead"), count: 1, unit: nuWords, through: true)]
  run(1)
  commitPara()
  doAssert L.text.paraFmtAt(7).nested.len == 1 and L.text.paraFmtAt(0).nested.len == 0
  runCommand("GREP Styles...")
  run(1)
  poDlg.f.grepStyles = @[GrepStyle(name: "Lead", look: d.lookOf("Lead"), pattern: "x")]
  run(1)
  commitPara()
  doAssert L.text.paraFmtAt(7).grepStyles.len == 1
  commitType()
  run(2)
  # (the character style redefined: the nested style's look follows)
  var red = big
  red.color = 0xFFFF0000'u32
  d.redefineStyle(false, "Lead", red)
  doAssert L.text.paraFmtAt(7).nested[0].look.color == 0xFFFF0000'u32
  # Paragraph Style Options: renamed, its Next Style kept by the other style, the paragraphs
  # that have it changed
  startStyleOptions("Body")
  run(1)
  doAssert psoDlg.open
  psoDlg.name = "Text Body"
  psoDlg.f.keepTogether = true
  run(1)
  psoDlg.open = false                      # (closed without OK: nothing changed)
  run(1)
  doAssert d.paraStyles.styleIndex("Text Body") < 0
  startStyleOptions("Body")
  run(1)
  psoDlg.name = "Text Body"
  psoDlg.f.keepTogether = true
  psoDlg.f.align = textRight
  psoOk = true
  run(2)
  doAssert not psoDlg.open
  let kb = d.paraStyles.styleIndex("Text Body")
  doAssert kb >= 0 and d.paraStyles[kb].para.keepTogether
  doAssert d.paraStyles[d.paraStyles.styleIndex("Heading")].para.nextStyle == "Text Body"
  doAssert L.text.paraFmtAt(7).styleName == "Text Body" and L.text.paraFmtAt(7).align == textRight
  doAssert L.text.paraFmtAt(0).align == textCenter
  # Object Styles: made from a shape, given to another, redefined, saved
  let A = d.addShapeLayer(ShapeData(path: rectPath(20, 20, 80, 80), fill: solidPaint(0xFF2060C0'u32),
                                    stroke: solidPaint(0xFF000000'u32), strokeWidth: 6))
  let B = d.addShapeLayer(ShapeData(path: ellipsePath(120, 20, 200, 90), fill: solidPaint(0xFFFFFFFF'u32)))
  A.opacity = 70
  var def = objectStyleOf(A, "Card")
  d.redefineObjectStyle(def)
  d.applyObjectStyle(A, "Card")
  d.cur = d.layers.find(B)
  d.applyObjectStyle(B, "Card")
  doAssert B.shape.fill == A.shape.fill and B.shape.strokeWidth == 6 and B.opacity == 70
  doAssert B.shape.path.subs.len > 0 and pathBounds(B.shape.path)[0] >= 119      # (its own outline)
  doAssert not d.objectStyleOverridden(B)
  B.opacity = 40
  doAssert d.objectStyleOverridden(B)
  d.applyObjectStyle(B, "Card")                                                   # (Clear Overrides)
  doAssert B.opacity == 70
  def.shape.fill = solidPaint(0xFF00A040'u32)
  d.redefineObjectStyle(def)
  doAssert A.shape.fill == solidPaint(0xFF00A040'u32) and B.shape.fill == solidPaint(0xFF00A040'u32)
  # (a text frame's options)
  var tf = L.text
  tf.columns = 2
  tf.inset = [4'f32, 4, 4, 4]
  tf.vjust = vjCenter
  d.setText(L, tf)
  let fdef = objectStyleOf(L, "Frame")
  doAssert fdef.useFrame and fdef.columns == 2
  d.redefineObjectStyle(fdef)
  var t2 = newText("Another", typeStyle, 20, 200)
  t2.boxW = 300
  t2.boxH = 100
  let T2 = d.addTextLayer(t2)
  d.applyObjectStyle(T2, "Frame")
  doAssert T2.text.columns == 2 and T2.text.vjust == vjCenter and T2.text.inset == [4'f32, 4, 4, 4]
  # (the panel: shown, a click gives the style to the layer picked)
  togglePanel("objectstyles")
  run(2)
  doAssert panelShown("objectstyles")
  # saved and read back
  let path = home / "styles.rpd"
  d.saveRpd(path)
  let back = loadRpd(path)
  doAssert back.objectStyles.len == 2 and back.objectStyleIndex("Card") >= 0
  doAssert back.objectStyles[back.objectStyleIndex("Card")].shape.fill.color == 0xFF00A040'u32
  var named = 0
  for M in back.layers:
    if M.objectStyle == "Card": inc named
  doAssert named == 2
  var found = false
  for st in back.paraStyles:
    if st.name == "Heading": found = st.para.nextStyle == "Text Body"
  doAssert found

block spellingLinksBookmarks:
  let d = newDoc(600, 400, 0xFFFFFFFF'u32)
  addDoc(d)
  run(2)
  var t = newText("We recieve the mesage today", typeStyle, 20, 60)
  t.boxW = 500
  t.boxH = 200
  let L = d.addTextLayer(t)
  d.cur = d.layers.find(L)
  run(1)
  if spellAvailable():
    # Dynamic Spelling: the two words marked
    let bad = misspelled(L.text)
    doAssert bad.len == 2 and bad[0].word == "recieve" and bad[1].word == "mesage", $bad
    runCommand("Dynamic Spelling")
    doAssert dynamicSpelling
    run(2)
    doAssert d.spellMarksOf(L).len == 2
    # Check Spelling: the first changed to its first suggestion, the next skipped
    runCommand("Check Spelling...")
    run(1)
    doAssert spellDlg.open and spellDlg.word == "recieve" and "receive" in spellDlg.sugg
    spellDlg.change = "receive"
    let delta = spellDlg.change.runeCount - (spellDlg.b - spellDlg.a)
    spellReplace(spellDlg.layer, spellDlg.a, spellDlg.b, spellDlg.change)
    spellDlg.b += delta
    spellNext()
    doAssert L.text.plainText == "We receive the mesage today"
    doAssert spellDlg.word == "mesage"
    spellNext()
    doAssert spellDlg.done
    spellDlg.open = false
    runCommand("Undo")
    doAssert L.text.plainText == "We recieve the mesage today"
    runCommand("Dynamic Spelling")
    doAssert not dynamicSpelling
  # a hyperlink on the words selected, a destination, a cross-reference to it
  tool = tType
  run(1)
  startTypeEdit(active, L, false, 0)
  run(1)
  te.anchor = 3
  te.caret = 10
  runCommand("New Hyperlink...")
  run(1)
  doAssert hlDlg.open and hlDlg.mode == "New Hyperlink..."
  hlDlg.url = "https://www.foxoman.net"
  hlDlg.open = false
  discard
  # (OK: as its button does)
  setLink("New Hyperlink", "https://www.foxoman.net")
  doAssert L.text.styleAt(5).link == "https://www.foxoman.net" and L.text.styleAt(1).link == ""
  te.anchor = 15
  te.caret = 21
  setLink("New Hyperlink Destination", "=msg")
  doAssert "msg" in d.knownDests
  te.anchor = L.text.runeLen
  te.caret = L.text.runeLen
  runCommand("Insert Cross-Reference...")
  run(1)
  doAssert hlDlg.open and hlDlg.dest == "msg"
  hlDlg.open = false
  insertTyped(" (page <ref:msg>)")
  doAssert d.effectiveText(L).plainText.endsWith("(page <ref:msg>)")     # (as written while typed)
  # Text Variables at the caret
  runCommand("Insert File Name")
  doAssert "<file>" in L.text.plainText
  # a bookmark from the words selected: a destination made on them
  te.anchor = 0
  te.caret = 2
  runCommand("New Bookmark")
  doAssert d.bookmarks.len == 1 and d.bookmarks[0].title == "We" and d.bookmarks[0].dest.len > 0
  doAssert L.text.styleAt(0).link == "=" & d.bookmarks[0].dest
  commitType()
  run(2)
  doAssert d.effectiveText(L).plainText.contains("(page 1)")
  # the Bookmarks panel
  togglePanel("bookmarks")
  run(2)
  doAssert panelShown("bookmarks")
  # (saved: the links, the bookmarks)
  let path = home / "links.rpd"
  d.saveRpd(path)
  let back = loadRpd(path)
  doAssert back.bookmarks.len == 1
  var linked = false
  for M in back.layers:
    if M.isText and M.text.linkRuns.len >= 3: linked = true
  doAssert linked

block linksAndPackage:
  # Place Linked: the picture keeps its file; changed there, Modified; updated; missing; embedded
  let d = newDoc(400, 300, 0xFFFFFFFF'u32, name = "Flyer")
  addDoc(d)
  run(2)
  let pic = home / "logo.png"
  var b = newBitmap(20, 10)
  for i in 0 ..< b.px.len: b.px[i] = 0xFFFF0000'u32
  writeFile(pic, encodePng(b))
  placeLinking = true
  d.placeSmart(pic)
  let L = d.current
  doAssert L.isSmart and L.smart.link == pic.absolutePath and linkState(L) == lsOk
  os.sleep(1100)
  for i in 0 ..< b.px.len: b.px[i] = 0xFF0000FF'u32
  writeFile(pic, encodePng(b))
  doAssert linkState(L) == lsModified
  doAssert d.relinked(L, L.smart.link) and linkState(L) == lsOk and L.smart.src[0] == 0xFF0000FF'u32
  togglePanel("links")
  run(2)
  doAssert panelShown("links")
  # (saved and read back: still linked)
  d.saveRpd(home / "flyer.rpd")
  let back = loadRpd(home / "flyer.rpd")
  var kept = false
  for M in back.layers:
    if M.isSmart and M.smart.link == pic.absolutePath: kept = true
  doAssert kept
  # File > Package: the document, its picture and fonts, IDML, PDF, the report
  var t = newText("Hello", typeStyle, 20, 60)
  discard d.addTextLayer(t)
  runCommand("Package...")
  run(1)
  doAssert pkgDlg.open
  let outDir = home / "out"
  createDir(outDir)
  pkgOk = outDir
  run(2)
  let root = outDir / "Flyer Folder"
  doAssert fileExists(root / "Flyer.rpd") and fileExists(root / "Links" / "logo.png")
  doAssert fileExists(root / "Flyer.idml") and fileExists(root / "Flyer.pdf") and fileExists(root / "Instructions.txt")
  doAssert "LINKS" in readFile(root / "Instructions.txt") and "FONTS" in readFile(root / "Instructions.txt")
  # (the package's copy linked to its own Links folder; the document as it was)
  let pk = loadRpd(root / "Flyer.rpd")
  var inPkg = false
  for M in pk.layers:
    if M.isSmart and M.smart.link == root / "Links" / "logo.png": inPkg = true
  doAssert inPkg and L.smart.link == pic.absolutePath
  # missing, then embedded
  removeFile(pic)
  doAssert linkState(L) == lsMissing
  d.embedLink(L)
  doAssert linkState(L) == lsEmbedded
  runCommand("Undo")
  doAssert linkState(L) == lsMissing

echo "photo parity app tests passed"
