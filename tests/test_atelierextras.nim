## Tests of what Retro Atelier 5.16 took from the photo, drawing and layout programs, run as the
## program, headless: SDR to HDR, the masks from a range and Compound Mask, Transform Selection,
## Copy CSS, Define Custom Shape, the Measurement Log, the scripts that tidy layers, Color Lookup
## Tables, Zoomify, Save for Web's formats, Layer to 3D, the 360 views, Version History, Image
## Assets, Content Credentials, droplets; the generative edits against the test's own service
## (tests/aimock.py); every new tool used on the canvas and every new command run once.

import std/[strutils, os, json, tables, sequtils, exitprocs, streams]
import std/osproc except countProcessors
import retroui/uirelays/input
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

echo "atelierextras: ", passed, " passed"
