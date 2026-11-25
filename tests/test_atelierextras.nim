## Tests of what Retro Atelier 5.16 took from the photo, drawing and layout programs, run as the
## program, headless: SDR to HDR, the masks from a range and Compound Mask, Transform Selection,
## Copy CSS, Define Custom Shape, the Measurement Log, the scripts that tidy layers, Color Lookup
## Tables, Zoomify, Save for Web's formats, Layer to 3D, the 360 views, Version History, Image
## Assets, Content Credentials, droplets; the generative edits against the test's own service
## (tests/aimock.py); every new tool used on the canvas and every new command run once. And 5.17's:
## a text box sized by its handles, a glyph put with its feature, the brush's outline, a color
## from anywhere in the window, a gradient's color stop made transparent, every tool its own icon.

import std/[strutils, os, json, tables, sequtils, exitprocs, streams]
import std/osproc except countProcessors
import retroui/uirelays/input
import retroui/lineicons
from std/unicode import runeAt
import harness

const photoUnderTest = true
include ../examples/photo

let home = getTempDir() / "retro-atelier-extras"
removeDir(home)
createDir(home)
putEnv("HOME", home)
setCurrentDir(home)

fakeDriver()
setup()
startApp("photo", W, H)
typeStyle.size = 48        # (the type these were written with: 48 points, 48 pixels at 72 ppi)
view = photoFrame

var passed = 0
template check(cond: bool; what: string) =
  doAssert cond, what
  inc passed
  echo "  ok   ", what

proc fresh(w = 200, h = 150; color = 0xFF808080'u32; name = "test"): (Doc, DocWin) =
  docs.setLen(0)
  active = nil
  tabCur = nil
  run(2)
  let d = newDoc(w, h, color, name = name)
  addDoc(d)
  run(2)
  (d, active)

proc selRect(d: Doc; r: Rect) =
  var m = newSeq[uint8](d.w * d.h)
  for y in r.y ..< r.y + r.h:
    for x in r.x ..< r.x + r.w: m[y * d.w + x] = 255
  d.setSelection(m)

proc stroke(dw: DocWin; x0, y0, x1, y1: float) =
  pressOn(dw, PhotoEvent(over: true, x: x0, y: y0, pressed: true, down: true, clicks: 1))
  drag.on = true
  dragOn(PhotoEvent(over: true, x: (x0 + x1) / 2, y: (y0 + y1) / 2, down: true))
  dragOn(PhotoEvent(over: true, x: x1, y: y1, down: true))
  releaseOn(PhotoEvent(over: true, x: x1, y: y1, released: true))

proc okDialog() =
  run(2)
  ui.touch = true
  ui.focus = 0
  run(1)
  key(KeyEnter)
  run(1)
  ui.touch = false
  run(2)

proc boxShape(d: Doc; r: Rect; c: uint32; name = "box"): Layer =
  d.layersChange("shape"):
    result = d.addShapeLayer(ShapeData(path: rectPath(r.x.float, r.y.float, float(r.x + r.w), float(r.y + r.h)),
                                       fill: solidPaint(c)), name)
  d.markAll()

block hdrAndMasks:
  let (d, _) = fresh()
  runCommand("SDR to HDR...")
  run(2)
  check hdrUp.open, "SDR to HDR: its dialog"
  okDialog()
  check d.depth == 32, "SDR to HDR: 32 bits a channel"
  let (d2, _) = fresh()
  for y in 0 ..< d2.h:
    for x in 0 ..< d2.w: d2.layer.px[y * d2.w + x] = grayPx(x * 255 div d2.w)
  inc d2.layer.ver
  d2.markAll()
  d2.layersChange("layer"): discard d2.addLayer("top")
  d2.cur = d2.layers.high
  runCommand("From Luminosity Range...")
  run(2)
  rangeMask.lo = 128
  rangeMask.hi = 255
  rangeMask.soft = 0
  okDialog()
  let L = d2.current
  check L.mask != nil and (L.mask.px[10 * d2.w + 10] and 0xFF'u32) == 0 and
        (L.mask.px[10 * d2.w + 190] and 0xFF'u32) == 255, "a mask from the lightness: shown where it is light"
  d2.selRect(rect(0, 0, 50, 150))
  runCommand("Compound Mask...")
  run(2)
  compound.op = 0
  okDialog()
  check (L.mask.px[10 * d2.w + 10] and 0xFF'u32) == 255 and (L.mask.px[10 * d2.w + 100] and 0xFF'u32) == 0,
        "Compound Mask, Add: the selection's part shown too"

block selectionAndLayers:
  let (d, _) = fresh()
  d.selRect(rect(80, 60, 40, 30))
  xfSelDlg = (false, 200.0, 0.0, 0, 0)
  d.transformSelection()
  check d.selBounds == rect(60, 45, 80, 60), "Transform Selection: twice as big round its middle -- " & $d.selBounds
  let S = d.boxShape(rect(10, 10, 60, 40), 0xFF2A9D8F'u32, "Card Box")
  d.cur = d.layers.find(S)
  runCommand("Copy CSS")
  let css = getClipboardText()
  check ".card-box {" in css and "background: #2a9d8f;" in css and "width: 60px;" in css, "Copy CSS: " & css
  runCommand("Copy SVG")
  check "<svg" in getClipboardText() and "path" in getClipboardText(), "Copy SVG"
  let n0 = CustomShapes.len
  runCommand("Define Custom Shape...")
  check CustomShapes.len == n0 + 1 and CustomShapes[^1].category == "Defined" and
        fileExists(dataDir(AppData) / "Defined Shapes.json"), "Define Custom Shape: in the Shapes panel, kept"
  d.layersChange("empty"): discard d.addLayer("Empty")
  let before = d.layers.len
  runCommand("Delete All Empty Layers")
  check d.layers.len == before - 1 and d.layers.allIt(it.name != "Empty"), "Delete All Empty Layers"
  d.selRect(rect(0, 0, 20, 10))
  measureLog = @[]
  runCommand("Record Measurements")
  check measureLog.len == 1 and measureLog[0].area == 200 and measureLog[0].perimeter > 50,
        "the Measurement Log: the selection's area"

block typedOnTheCanvas:
  # Arabic typed on the canvas with the Type tool as a keyboard sends it -- a key, then its
  # letter -- in the English interface and the Arabic one: a click where the screen shows the
  # picture, all of the words in the layer, and a space at the end moving the caret on
  for lang in [0, 1]:
    prefs.language = lang
    applyLanguage()
    let (d, dw) = fresh(400, 300, 0xFFFFFFFF'u32, "typed")
    selectTool(tType)
    run(2)
    let v = dw.view.view
    let lx = v.x + v.w div 2
    let ly = v.y + v.h div 2
    let sx = if ui.rtl: W - 1 - lx else: lx           # (the mirrored frame: where the screen has it)
    down(sx, ly)
    run()
    up(sx, ly)
    run(2)
    check te.on and te.dw == dw, "a click with the Type tool starts a text (" & $lang & ")"
    let words = "مرحبا بالعالم"
    for r in words.runes:
      queue.add Event(kind: KeyDownEvent, key: KeyNone)
      var e = Event(kind: TextInputEvent)
      let u = r.toUTF8
      for i in 0 ..< u.len: e.text[i] = u[i]
      queue.add e
    run(4)
    # (the keys typed while the font was loaded are kept for the next frames: `eventsWaiting`)
    while eventsWaiting() > 0: run()
    check te.layer.text.plainText == words, "all of it typed (" & $lang & "): " & te.layer.text.plainText
    let l0 = typeLayout()
    let before = te.layer.text.caretLine(l0, te.caret).x0
    typeText(" ")
    run(2)
    let l1 = typeLayout()
    let after = te.layer.text.caretLine(l1, te.caret).x0
    check abs(after - before) > 5, "a space typed moves the caret (" & $lang & ")"
    let (ix, _) = dw.view.toImage(d, lx, ly)
    let b = te.layer.textBounds(0)
    check ix >= b.x0 - 2 and ix <= b.x1 + 2, "the text where it was clicked (" & $lang & ")"
    commitType()
    run(2)
  prefs.language = 0
  applyLanguage()
  run(2)

block aTextBoxSizedAndAGlyphPut:
  # a text box dragged with the Type tool: then the middle of its right side dragged -- the box
  # wider, its letters as big as they were, its lines flowing again; a glyph of the font's put
  # where the text is typed, with the feature the font makes it by on for it alone
  let (d, dw) = fresh(500, 400, 0xFFFFFFFF'u32, "box")
  selectTool(tType)
  run(2)
  let v = dw.view
  let (ax, ay) = v.toScreen(d, 60, 60)
  let (bx, by) = v.toScreen(d, 260, 260)
  down(ax, ay)
  run()
  move(bx, by)
  run()
  up(bx, by)
  run(2)
  check te.on and te.layer.text.boxW > 100, "a box dragged: " & $te.layer.text.boxW
  typeText("Words that flow on in their box as it is made wider or narrower")
  run(2)
  while eventsWaiting() > 0: run()        # (keys kept while a font was read: `eventsWaiting`)
  let t0 = te.layer.text
  let line0 = layoutText(te.layer.text).lines[0].last           # (the first line's letters)
  # (the view as it is now: the bars of typing may have moved it)
  let (rx, ry) = dw.view.toScreen(d, float(t0.x + t0.boxW), float(t0.y + t0.boxH / 2))
  let (rx2, _) = dw.view.toScreen(d, float(t0.x + t0.boxW + 150), float(t0.y))
  down(rx, ry)
  run()
  move(rx2, ry)
  run()
  up(rx2, ry)
  run(2)
  while eventsWaiting() > 0: run()
  let t1 = te.layer.text
  check t1.boxW > t0.boxW + 100 and t1.boxH == t0.boxH and t1.x == t0.x, "the box wider: " & $(t0.boxW, t1.boxW)
  check t1.spans[0].style.size == t0.spans[0].style.size, "its letters as big as they were"
  let line1 = layoutText(te.layer.text).lines[0].last
  check line1 > line0, "its lines flowing again: more on the first: " & $(line0, line1)
  let n0 = te.layer.text.runeLen
  putGlyph("\u{FDF2}", "")
  putGlyph("Q", "ss01")
  run(2)
  let t2 = te.layer.text
  check t2.runeLen == n0 + 2 and "\u{FDF2}Q" in t2.plainText, "the glyphs put where the text is typed"
  check featureOn(t2.styleAt(t2.runeLen - 1).features, "ss01") and not featureOn(te.style.features, "ss01"),
        "the feature on for the glyph alone"
  commitType()
  selectTool(tMove)
  run(2)

block brushOutline:
  # a brush tool picked or its size changed: its outline a moment in the view's middle, its size
  # under it -- a finger has no pointer to show it at; then gone
  let (d, dw) = fresh(400, 300, 0xFFFFFFFF'u32, "outline")
  move(W - 3, H - 3)                    # (the pointer off the picture: no outline at it)
  selectTool(tMove)
  run(2)
  opts[tBrush].tip.hardness = 100      # (a hard tip: its outline as big as it is)
  selectTool(tBrush)
  setBrushSize(tBrush, 120)
  run(2)
  check ui.now < outlinePreview, "the outline shown when the brush is picked"
  let v = dw.view
  let (ix, iy) = v.toImage(d, v.view.x + v.view.w div 2, v.view.y + v.view.h div 2)
  let (cx, cy) = v.toScreen(d, ix, iy)
  let (ex, _) = v.toScreen(d, ix + 60, iy)
  proc darkNear(x, y: int): bool =
    for dy in -2 .. 2:
      for dx in -2 .. 2:
        if x + dx in 0 ..< W and y + dy in 0 ..< H and px(x + dx, y + dy) == 0: return true
  check darkNear(ex, cy) and not darkNear((cx + ex) div 2, cy - dp(12)), "a circle its size round the middle"
  ticks += 1500
  run(3)
  check ui.now >= outlinePreview and not darkNear(ex, cy), "gone after a moment"
  selectTool(tMove)
  run(2)

block colorFromAnywhere:
  # the Color panel's eyedropper: a press anywhere in the window takes the color shown there --
  # the press its own, not the tool's; and its colors to choose from, the swatches or a library
  let (d, dw) = fresh(200, 150, 0xFFD02020'u32, "pick")
  selectTool(tBrush)
  run(2)
  let before = d.layers[0].px
  let v = dw.view
  let (sx, sy) = v.toScreen(d, 100, 75)
  pickAnywhere.on = true
  down(sx, sy)
  run()
  up(sx, sy)
  run(3)
  check (fg and 0xFFFFFF'u32) == 0xD02020'u32 and not pickAnywhere.on, "the color under the press: " & toHex(fg)
  check d.layers[0].px == before, "nothing painted by that press"
  ensureBooksLoaded()
  check colorBooks.len > 0, "libraries to choose from"
  colorSource = 1
  run(2)
  colorSource = 0
  selectTool(tMove)
  run(2)

block aTransparentColorStop:
  # the color picker with its opacity (a gradient's color stop): Transparent, kept by OK; without
  # it, the color opaque as before; the Gradient Editor's stop taking the picker's see-through color
  let keep = view
  var c = 0xFF2060C0'u32
  var open = true
  var st: ColorPickerState
  view = proc () = discard colorPickerDialog(open, "Stop", c, st, alpha = true)
  run(2)
  check st.alpha == 255, "opened opaque, at the stop's opacity"
  st.alpha = 0                                     # (its Transparent button)
  okDialog()
  check not open and c == 0x002060C0'u32, "OK: the color transparent, its own color kept: " & toHex(c)
  c = 0x802060C0'u32
  open = true
  st = ColorPickerState()
  view = proc () = discard colorPickerDialog(open, "Plain", c, st)
  run(2)
  okDialog()
  check c == 0xFF2060C0'u32, "a picker without opacity: opaque, as before: " & toHex(c)
  view = keep
  run(2)
  startGradientEditor(0, @[stop(0, 0xFFE03020'u32), stop(1, 0xFF2060C0'u32)])
  geSel = 1
  run(2)
  # (the stop's well, then the picker's OK with Transparent: what they hand back)
  well = (false, "gestop", 0x002060C0'u32, true, well.picker, true)
  run(2)
  check geStops[1].color == 0x002060C0'u32, "the stop see-through: " & toHex(geStops[1].color)
  check gradientColor(geStops, 1.0) shr 24 == 0 and gradientColor(geStops, 0.0) shr 24 == 255,
        "the gradient fading out to it"
  geOpen = false
  run(2)
  # a shape's see-through fill: the options keep its opacity (they gave it back opaque), and its
  # pixels are half see-through
  let (sd, _) = fresh(120, 90, 0xFFFFFFFF'u32, "glass")
  let L = sd.boxShape(rect(10, 10, 60, 40), 0x80FF0000'u32)
  syncShapeOptions(L)
  check shapeFill == 0x80FF0000'u32, "the options keep the fill's opacity: " & toHex(shapeFill)
  let a = L.px[30 * 120 + 40] shr 24
  check a in 120'u32 .. 136'u32, "the shape's pixels half see-through: " & $a
  run(2)

block everyToolItsOwnIcon:
  # no two tools of the toolbar with the same icon; the one in use shown (the Options bar) with
  # its button's; every icon drawn at both sizes, with a line twin for the dark themes
  var seen = initTable[string, string]()
  for grp in toolGroups:
    for it in grp.items:
      check it.glyph notin seen, it.name & " has the icon of " & seen.getOrDefault(it.glyph)
      seen[it.glyph] = it.name
      let a = pixelIcon(it.glyph)
      let b = pixelIcon(it.glyph, big = true)
      check a.w == 16 and a.h == 16 and b.w == 32 and b.h == 32, it.name & ": its art"
      let i = int(it.glyph.runeAt(0)) - PixIconFirst
      check lineTwins.anyIt(it[0] == i), it.name & ": its line twin"
  for g, grp in toolGroups:
    for k, it in grp.items:
      pickTool(g, k)
      check toolGlyph(it.tool) == it.glyph, it.name & ": the tool in use shown with its icon"
  selectTool(tMove)
  run(2)

block scaleStrokesAndEffects:
  # Free Transform (and the Scale tool, which is it) on a shape: its stroke and style twice as big
  # with Scale Strokes & Effects on; as they were with it off
  for on in [false, true]:
    let (d, _) = fresh()
    let S = d.boxShape(rect(40, 40, 60, 30), 0xFF2A9D8F'u32, "s")
    d.layersChange("stroke"):
      var sh = S.shape
      sh.stroke = solidPaint(0xFF000000'u32)
      sh.strokeWidth = 3
      d.setShape(S, sh)
    S.fx.fx[fxDropShadow].on = true
    S.fx.fx[fxDropShadow].distance = 4
    d.cur = d.layers.find(S)
    prefs.scaleStrokes = on
    startTransform(xkScale)
    check xf.on, "Free Transform on the shape"
    let r = xf.r
    xf.quad = [(r.x.float, r.y.float), (float(r.x + r.w * 2), r.y.float), (float(r.x + r.w * 2), float(r.y + r.h * 2)),
               (r.x.float, float(r.y + r.h * 2))]
    xfApply()
    finishTransform(true)
    let k = if on: 2.0 else: 1.0
    check abs(S.shape.strokeWidth - 3 * k) < 0.05 and S.fx.fx[fxDropShadow].distance == int(4 * k),
          "Scale Strokes & Effects " & (if on: "on: twice as wide" else: "off: as it was") & " -- " &
          $S.shape.strokeWidth
  prefs.scaleStrokes = false

block exports:
  let (d, _) = fresh(64, 48, 0xFF336699'u32, "exp")
  d.layersChange("adj"): discard d.newAdjustmentLayer(Adjustment(kind: "Invert"))
  d.markAll()
  let cube = home / "look.cube"
  d.exportCube(cube)
  let lines = readFile(cube).splitLines
  check "LUT_3D_SIZE 33" in lines and lines[2] == "1.000000 1.000000 1.000000",
        "Color Lookup Tables: black made white by the Invert layer"
  let zd = home / "zoom"
  createDir(zd)
  d.exportZoomify(zd)
  check fileExists(zd / "exp.dzi") and fileExists(zd / "exp.html") and fileExists(zd / "exp_files" / "0" / "0_0.jpg"),
        "Zoomify: the tiles, the .dzi and a page"
  d.updateComposite()
  let b = d.toBitmap(0xFFFFFFFF'u32)
  var sigs: seq[string]
  for f in 0 .. 4:
    webDlg.format = f
    webDlg.quality = 80
    webDlg.colors = 64
    sigs.add webEncode(b)[0 .. 3]
  check sigs[0].startsWith("\xFF\xD8") and sigs[1] == "\x89PNG" and sigs[2] == "\x89PNG" and sigs[3] == "GIF8" and
        sigs[4] == "RIFF", "Save for Web: JPEG, PNG-24, PNG-8, GIF, WebP"
  d.cur = 0
  d.layerTo3d()
  let glb = picturesDir() / (d.layers[0].name & ".glb")
  check fileExists(glb) and readFile(glb).startsWith("glTF"), "Layer to 3D: a .glb"
  crDlg = (true, false, "Sultan")
  run(2)
  crDlg.open = false

block panorama:
  let (d, _) = fresh(400, 200, 0xFF4080C0'u32, "pano")
  runCommand("Edit 360 View...")
  run(2)
  check pano360Dlg.open, "Edit 360 View: its dialog"
  okDialog()
  let v = cur()
  check v != d and v.name.endsWith("360 View"), "a flat view, a document of its own"
  for p in v.layer.px.mitems: p = 0xFFFF0000'u32
  inc v.layer.ver
  v.markAll()
  runCommand("Apply 360 View")
  check rOf(d.layer.px[100 * 400 + 200]) > 200, "Apply 360 View: the change put back"

block versionsAndAssets:
  let (d, dw) = fresh(80, 60, 0xFFFFFFFF'u32, "ver")
  d.path = home / "ver.rpd"
  d.format = "rpd"
  discard d.boxShape(rect(5, 5, 30, 20), 0xFFCC0000'u32, "logo.png")
  runCommand("Image Assets")
  check d.imageAssetsOn, "Generate > Image Assets on"
  runCommand("Save")
  run(3)
  d.layer.px[0] = 0xFF000000'u32
  d.modified = true
  run(2)
  runCommand("Save")
  run(3)
  var versions: seq[string]
  for f in walkFiles(d.versionDir / "*"): versions.add f
  check versions.len == 2, "Version History: one kept each save -- " & $versions.len
  check fileExists(home / "ver-assets" / "logo.png"), "Image Assets: the layer named logo.png saved as a file"
  runCommand("Version History...")
  run(2)
  check versionsDlg.open and versionsDlg.list.len == 2, "Version History's list"
  versionsDlg.open = false
  discard dw

block droplets:
  loadActions()
  check actions.len > 0, "actions"
  let (d, _) = fresh()
  let before = d.layer.px[0]
  let a = actions[0].name
  runCommand("Play Action: " & a)
  run(3)
  check true, "Play Action: by name -- " & a
  discard before
  dropletDlg = (true, 0, home / "out")
  run(1)
  dropletDlg.open = false
  createDir(home / "Desktop")
  # (made as the dialog's Create makes it)
  let base = droplets() / "x"
  check droplets() == home / "Desktop", "a droplet goes on the desktop"
  discard base

block accessibility:
  let (d, _) = fresh()
  var st = defaultStyle()
  st.size = 5
  var t = newText("tiny words", st, 10, 20)
  d.layersChange("type"): discard d.addTextLayer(t)
  d.checkDocument()
  check checkDlg.issues.len > 0, "Accessibility Check: the too small text found"

block generative:
  let python = if findExe("python3").len > 0: "python3" else: "python"
  let mock = startProcess(python, args = [currentSourcePath().parentDir / "aimock.py"], options = {poUsePath})
  proc stopAtExit(p: Process) =
    addExitProc(proc () = p.terminate())
  stopAtExit(mock)
  let base = "http://127.0.0.1:" & mock.outputStream.readLine.strip
  template waitUntil(cond: untyped) =
    for i in 0 ..< 1500:
      run()
      if cond: break
      os.sleep(10)
    doAssert cond, astToStr(cond)
  imgAi.s = AiImageSettings(url: base & "/v1/images/generations", model: "gpt-image-1")
  imgAi.loaded = true
  imgAi.keyed = true
  aiDlg.s = AiSettings(kind: akOpenAi, url: base & "/v1/chat/completions", model: "mock")
  aiDlg.loaded = true
  aiDlg.keyed = true
  let (d, _) = fresh(120, 90, 0xFF808080'u32, "gen")
  d.selRect(rect(40, 30, 40, 30))
  runCommand("Generate Background...")
  run(2)
  check aiEditDlg.open and aiEditDlg.kind == aeBackground, "Generate Background: its dialog"
  aiEditDlg.words = "a beach"
  okDialog()
  waitUntil(aiRun.job == nil and aiRun.tasks.len == 0)
  let L = d.current
  check L.name == "Generate Background" and L.mask != nil and (L.mask.px[5 * 120 + 5] and 0xFF'u32) == 255 and
        (L.mask.px[45 * 120 + 60] and 0xFF'u32) == 0 and gOf(L.px[5 * 120 + 5]) > 150,
        "Generate Background: a layer of what was made, shown round the subject"
  let st = parseJson(httpRequest("GET", base & "/state").body)
  check "a beach" in st["edits"]["prompt"].getStr, "the words sent"
  # Generative Upscale: a new document twice the size, a tile at a time
  aiEditDlg.kind = aeUpscale
  aiEditDlg.factor = 0
  d.startAiEdit()
  waitUntil(aiRun.job == nil and aiRun.tasks.len == 0)
  let up = cur()
  check up != d and up.w == 240 and up.h == 180 and gOf(up.layer.px[90 * 240 + 120]) > 150,
        "Generative Upscale: a new document, twice as big"
  # Style Transfer from another open picture: the right part of the answer used
  docs.setLen(0)
  active = nil
  let refD = newDoc(60, 90, 0xFFFF00FF'u32, name = "look")
  addDoc(refD)
  let tgt = newDoc(120, 90, 0xFF808080'u32, name = "target")
  addDoc(tgt)
  run(2)
  aiEditDlg.kind = aeStyle
  aiEditDlg.source = 1
  aiEditDlg.style = 0
  aiEditDlg.strength = 70
  tgt.startAiEdit()
  waitUntil(aiRun.job == nil and aiRun.tasks.len == 0)
  check tgt.current.name == "Style Transfer" and tgt.current.opacity == 70 and gOf(tgt.current.px[45 * 120 + 60]) > 150,
        "Style Transfer from a picture: a layer, at the strength set"
  # by the AI service: Rewrite, Generative Recolor
  var ts = defaultStyle()
  ts.size = 20
  tgt.layersChange("type"): discard tgt.addTextLayer(newText("Hello there", ts, 10, 30))
  textAi.what = 3
  textAi.how = 0
  textAi.words = ""
  tgt.startTextAi()
  waitUntil(textRun.job == nil)
  check tgt.current.text.plainText.startsWith("You said: Rewrite this to be shorter"), "Rewrite: the words written again"
  discard tgt.boxShape(rect(5, 5, 20, 20), 0xFF000000'u32, "dark")
  discard tgt.boxShape(rect(30, 5, 20, 20), 0xFFFFFFFF'u32, "light")
  textAi.what = 0
  textAi.words = "#102030 #405060 #708090"
  tgt.startTextAi()
  waitUntil(textRun.job == nil)
  var fills: seq[uint32]
  for M in tgt.layers:
    if M.isShape: fills.add M.shape.fill.color
  check 0xFF102030'u32 in fills and 0xFF708090'u32 in fills, "Generative Recolor: the palette the service named"
  textAi.what = 1
  textAi.words = "leaves"
  tgt.startTextAi()
  waitUntil(textRun.img == nil)
  check pattern.len == 1024 * 1024 and patternW == 1024, "Text to Pattern: the pattern set"
  imgAi.s = AiImageSettings()
  aiDlg.s = AiSettings()
  mock.terminate()

block everyNewTool:
  # each new vector tool dragged on a page with shapes and type: nothing breaks
  for m in 19 .. 71:
    let (d, dw) = fresh(200, 150, 0xFFFFFFFF'u32, "tool" & $m)
    discard d.boxShape(rect(40, 40, 60, 40), 0xFF3366CC'u32)
    var st = defaultStyle()
    st.size = 18
    d.layersChange("type"): discard d.addTextLayer(newText("Type", st, 120, 100))
    d.cur = 1
    tool = tVector
    vecMode = m
    run(1)
    stroke(dw, 50, 50, 90, 70)
    run(2)
    discard escapeKey()
    run(1)
  tool = tMove
  check true, "every new tool (" & $(71 - 19 + 1) & ") dragged on the canvas"

block everyNewCommand:
  # every command of the new modules run once on a page with a shape, type and a picture
  var names: seq[string]
  for f in ["extras", "objectmore", "layoutextra", "filemore", "aimore"]:
    let src = readFile(currentSourcePath().parentDir.parentDir / "examples" / "photo" / (f & ".nim"))
    var at = -1
    for k, line in src.splitLines.toSeq:
      if line.startsWith("proc ") and line.endsWith("Command(name: string): bool ="): at = k
    for line in src.splitLines.toSeq[at .. ^1]:
      let l = line.strip
      if l.startsWith("of \""):
        # (each quoted name before the colon)
        let parts = l[3 .. ^1].split(':')[0].split('"')
        for i in countup(1, parts.high, 2):
          let n = parts[i]
          if n.len > 0 and n notin names: names.add n
  check names.len > 60, "the new commands found: " & $names.len
  var ran = 0
  for n in names:
    let (d, _) = fresh(160, 120, 0xFFFFFFFF'u32, "cmd")
    for y in 0 ..< d.h:
      for x in 0 ..< d.w: d.layer.px[y * d.w + x] = argb(255, x, y, 128)
    inc d.layer.ver
    discard d.boxShape(rect(20, 20, 50, 40), 0xFFCC3333'u32)
    var st = defaultStyle()
    st.size = 16
    d.layersChange("type"): discard d.addTextLayer(newText("Some words here", st, 80, 60))
    d.selRect(rect(10, 10, 60, 50))
    runCommand(n)
    run(3)
    inc ran
  check ran == names.len, "every new command ran"

block aBigPatternPreview:
  # Pattern Options with a tile thousands of pixels a side (the random-input run's): its preview at
  # most 600 pixels a side -- 3 x 3 of the tile took gigabytes and failed -- the tile itself whole
  let (d, _) = fresh(200, 150, 0xFFFFFFFF'u32, "pattern")
  discard d.boxShape(rect(20, 20, 80, 60), 0xFFCC3333'u32)
  d.cur = d.layers.high
  patOpts.w = 3000
  patOpts.h = 2500
  patOpts.key = ""
  showPanel("patternoptions")
  run(3)
  check patOpts.prev != nil and patOpts.prev.w <= 600 and patOpts.prev.h <= 600 and patOpts.tw == 3000 and
        patOpts.th == 2500, "the preview small, the tile whole: " & $(patOpts.tw, patOpts.th)
  togglePanel("patternoptions")
  patOpts.w = 0
  patOpts.h = 0
  run(2)

block artboardsAsPages:
  # artboards as pages in the program: the panel, Facing Pages, Page Numbers (its dialog), Move to
  # Artboard, `<#>` drawn again when the type goes onto another, Save PDF as spreads, Print asking
  let (d, dw) = fresh(500, 300, 0xFFFFFFFF'u32, "pages")
  d.beginStep("New Artboard")
  discard d.addArtboard(rect(0, 0, 100, 140))
  d.endStep()
  for k in 1 .. 2:
    let b = d.boards[0].r
    d.beginStep("New Artboard")
    discard d.addArtboard(rect(b.x + k * 120, b.y, 100, 140))
    d.endStep()
  let b0 = d.boards[0].r
  var t = newText("<#>/<##>", defaultStyle(), 0, 0)
  t.x = float32(b0.x + 10)
  t.y = float32(b0.y + 10)
  t.boxW = 80
  t.boxH = 30
  var T: Layer
  d.layersChange("type"): T = d.addTextLayer(t)
  runCommand("Artboards")
  run(3)
  check panelShown("artboards"), "the Artboards panel"
  check T.boardMark == "1/3", "its number drawn: " & T.boardMark
  runCommand("Facing Artboards")
  run(2)
  check d.boardFacing and d.boardSpreads == @[@[0], @[1, 2]], "facing pages: in spreads"
  d.cur = d.layers.find(T)
  for i, L in d.layers: L.picked = L == T
  runCommand("Move to Artboard 3")
  run(2)
  check d.boardOfText(T) == 2 and T.boardMark == "3/3", "moved onto the third: its number drawn again"
  d.undo()
  run(2)
  check d.boardOfText(T) == 0 and T.boardMark == "1/3", "undone: back on the first"
  runCommand("Artboard Page Numbers...")
  run(2)
  check folioDlg.open, "Page Numbers asks"
  applyBoardFolios(d)                      # (its OK)
  run(2)
  var folios = 0
  for L in d.layers:
    if L.name == "Folio": inc folios
  check not folioDlg.open and folios == 3, "a folio on each: " & $folios
  # Save PDF: the artboards as spreads (they face), three sheets
  let pdfPath = home / "pages.pdf"
  startPdfOptions(@[d], pdfPath)
  run(2)
  check abPages.d == d and abPages.what == 1, "Save PDF: the artboards, as spreads"
  pdfDlg.open = false
  writePdfNow()
  check fileExists(pdfPath) and "as spreads" in status, "saved as spreads: " & status
  # Print asks: pages, spreads or the whole canvas
  runCommand("Print...")
  run(2)
  check prDlg.open and prDlg.d == d, "Print asks how"
  prDlg.open = false
  run(2)

block typeInPoints:
  # type in points at the document's resolution, as the photo program has it: on an A4 page at 400
  # ppi new type is 12 points (67 pixels), the Character panel's 18 is 100 pixels there and 18 at
  # 72 ppi; the next text's size kept in points from one document to another; Pixels shows pixels
  let saved = (typeStyle, viewPrefs.typeUnit)
  typeStyle.size = 12
  viewPrefs.typeUnit = tuPoints
  let (d, _) = fresh(400, 300, 0xFFFFFFFF'u32, "a4")
  d.dpi = 400
  check abs(typingStyle().size - 12 * 400 / 72) < 0.01, "new type on a 400 ppi page: 12 pt, " &
        $typingStyle().size & " px"
  check abs(d.pointsOf(typingStyle().size) - 12) < 0.01 and typeShort() == "pt", "shown as 12 pt"
  applyChar("Font Size", proc (x: var CharStyle) = x.size = float32(d.pixelsOf(18)))
  check abs(typeStyle.size - 18) < 0.01 and abs(typingStyle().size - 100) < 0.01,
        "18 pt set there: 100 px on it, kept as 18 pt"
  let (e, _) = fresh(400, 300, 0xFFFFFFFF'u32, "screen")
  check e.dpi == 72 and abs(typingStyle().size - 18) < 0.01, "... 18 px on a 72 ppi one"
  viewPrefs.typeUnit = tuPixels
  check typeShort() == "px" and abs(e.typePixels - 1) < 1e-9, "Type: Pixels"
  viewPrefs.typeUnit = tuMillimeters
  check abs(d.typePixels - 400 / 25.4) < 1e-6, "Type: Millimeters"
  (typeStyle, viewPrefs.typeUnit) = saved

block panelsWhileTyping:
  # the Glyphs panel opened while typing -- the bar's Glyphs, Window > Glyphs -- and Character, a
  # panel of colors: the text still being typed, the glyph clicked going where the caret is
  # (last: the panels stay where they were put)
  let (d, dw) = fresh(300, 200, 0xFFFFFFFF'u32, "panels")
  var st = defaultStyle()
  st.size = 24
  var L: Layer
  d.layersChange("type"): L = d.addTextLayer(newText("Words", st, 40, 60))
  d.cur = d.layers.find(L)
  selectTool(tType)
  run(2)
  startTypeEdit(dw, L, false, 5)
  run(2)
  check te.on, "typing"
  for panel in ["Glyphs", "Character", "Swatches"]:
    runCommand(panel)
    run(2)
    check te.on, "the " & panel & " panel shown or hidden while typing: the text still being typed"
  let n0 = te.layer.text.runeLen
  putGlyph("*", "")
  run(2)
  check te.layer.text.runeLen == n0 + 1, "a glyph clicked: where the caret is"
  commitType()
  run(2)

echo "atelierextras: ", passed, " passed"
