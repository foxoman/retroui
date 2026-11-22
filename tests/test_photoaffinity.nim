## Tests of what Retro Atelier 5.15 took from the Affinity apps (and the placeholder text with it),
## run as the program, headless: studios (workspaces by name, as files), a help card for every
## tool, paint on type making a pixel layer, live blends and Expand Blend, Hue Curves, the Mask
## Brush, the Tone Brush, Fill with Placeholder Text (Arabic too, so many paragraphs, as many as fill the box).

import std/[strutils, os, json, tables]
from std/unicode import runeLen
import retroui/uirelays/input
import harness

const photoUnderTest = true
include ../examples/photo

let home = getTempDir() / "retro-photo-affinity"
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

proc stroke(dw: DocWin; x0, y0, x1, y1: float; alt = false) =
  pressOn(dw, PhotoEvent(over: true, x: x0, y: y0, pressed: true, down: true, clicks: 1, alt: alt))
  drag.on = true
  dragOn(PhotoEvent(over: true, x: x1, y: y1, down: true, alt: alt))
  releaseOn(PhotoEvent(over: true, x: x1, y: y1, released: true, alt: alt))

block studios:
  keepStudio("Painting")
  keepStudio("Layout")
  check studioNames() == @["Painting", "Layout"], "two studios kept by name"
  let j = studioJson("Painting")
  check j{"retroAtelierWorkspace"}.getInt == 1 and j{"dock"} != nil, "a studio as a file: its panels"
  dropStudio("Painting")
  check studioNames() == @["Layout"], "one deleted"
  j["name"] = %"Shared"
  check studioFromJson(j) == "Shared" and "Shared" in studioNames(), "a studio file brought in"
  check studioFromJson(%*{"name": "x"}) == "", "not a studio file: nothing"

block toolHelpCards:
  var missing: seq[string]
  for g in toolGroups:
    for it in g.items:
      if "\n" notin toolCard(it.name, ""): missing.add it.name
  check missing.len == 0, "every tool of the toolbar has a help card: " & $missing
  let c = toolCard("Mask Brush Tool", "B")
  check c.startsWith("Mask Brush Tool (B)\n") and "mask" in c and "F1" in c, "the Mask Brush's card"

block autoPixelLayer:
  let (d, dw) = fresh()
  var t = newText("Type", defaultStyle(), 20, 20)
  d.layersChange("type"): discard d.addTextLayer(t)
  let n = d.layers.len
  prefs.autoPixelLayer = true
  tool = tBrush
  brushTool = 0
  stroke(dw, 30, 30, 90, 30)
  check d.layers.len == n + 1 and not d.current.isText and d.layers[n - 1].isText,
        "a brush stroke on type: a new pixel layer above it takes the paint"
  check d.layers[n - 1].text.plainText == "Type", "the type as it was"

block liveBlend:
  let (d, _) = fresh()
  d.layersChange("shapes"):
    discard d.addShapeLayer(ShapeData(path: rectPath(20, 20, 60, 60), fill: solidPaint(0xFFFF0000'u32)), "A")
    discard d.addShapeLayer(ShapeData(path: rectPath(140, 90, 180, 130), fill: solidPaint(0xFF0000FF'u32)), "B")
  d.layers[^2].picked = true
  d.layers[^1].picked = true
  blendSpacing = 1
  blendSteps = 3
  startMakeBlend()
  makeBlend()
  let g = d.current
  check g.group and g.meta.startsWith("{\"blend\"") and d.blendParts(g).steps.len == 3,
        "Make Blend: a live group, three steps"
  d.keepLiveBlends()                      # (seen as made)
  let (ends, steps0) = d.blendParts(g)
  let mid0 = d.layerBox(steps0[1])
  d.layersChange("move an end"):
    ends[1].shape.path = ends[1].shape.path.translated(30, 0)
    inc ends[1].ver
  d.keepLiveBlends()
  let steps1 = d.blendParts(g).steps
  check steps1.len == 3 and d.layerBox(steps1[1]).x > mid0.x, "an end moved: the steps follow it"
  d.cur = d.layers.find(g)
  d.expandBlend()
  check g.meta == "" and d.blendParts(g).steps.len == 0, "Expand Blend: plain shapes"

block hueCurves:
  # (reds made gray, the rest left)
  let f = hueCurves([@[(0, 128), (255, 128)], @[(0, 0), (40, 128), (215, 128), (255, 0)],
                     @[(0, 128), (255, 128)]])
  var im = newImg(3, 1)
  im.px = @[0xFFFF0000'u32, 0xFF0000FF'u32, 0xFF808080'u32]
  let px = f(im, rect(0, 0, 3, 1)).px
  check rOf(px[0]) == gOf(px[0]) and gOf(px[0]) == bOf(px[0]), "Hue Curves: red's saturation taken away"
  check px[1] == 0xFF0000FF'u32 and px[2] == 0xFF808080'u32, "blue and gray as they were"

block maskBrush:
  let (d, dw) = fresh()
  d.layersChange("layer"): discard d.addLayer("Paint")
  let L = d.current
  for i in 0 ..< L.px.len: L.px[i] = 0xFF00FF00'u32
  inc L.ver
  tool = tBrush
  brushTool = 4
  maskBrushShow = false
  opts[tBrush].opacity = 100
  stroke(dw, 30, 40, 120, 40)
  check L.mask != nil and d.editMask, "the Mask Brush: a mask made, painting on it"
  check (L.mask.px[40 * 200 + 70] and 0xFF) < 40, "black where it went: hidden there"
  check (L.mask.px[120 * 200 + 150] and 0xFF) == 255, "white elsewhere: shown"
  check L.px[40 * 200 + 70] == 0xFF00FF00'u32, "the layer's pixels not touched"
  stroke(dw, 60, 40, 80, 40, alt = true)
  check (L.mask.px[40 * 200 + 70] and 0xFF) > 200, "Alt: shown again"
  check d.undoName == "Mask Brush", "one step a stroke"
  # (on the Background: made a layer first)
  let (d2, dw2) = fresh(name = "bg")
  d2.editMask = false
  stroke(dw2, 30, 40, 120, 40)
  check not d2.current.background and d2.current.mask != nil, "on the Background: a layer with a mask"

block toneBrush:
  let (d, dw) = fresh()
  let n = d.layers.len
  tool = tBrush
  brushTool = 5
  toneDarker = false
  opts[tBrush].opacity = 100
  stroke(dw, 30, 40, 120, 40)
  let L = d.current
  check d.layers.len == n + 1 and L.meta == ToneMeta and L.mode == bmSoftLight, "the Tone Brush: a Tone layer made"
  check d.layers[0].px[40 * 200 + 70] == 0xFF808080'u32, "the picture's pixels not touched"
  d.updateComposite()
  check rOf(d.compPtr[40 * 200 + 70]) > 0x90 and rOf(d.compPtr[120 * 200 + 150]) == 0x80,
        "lighter where it painted, as it was elsewhere"
  stroke(dw, 30, 100, 120, 100, alt = true)
  d.updateComposite()
  check d.layers.len == n + 1 and rOf(d.compPtr[100 * 200 + 70]) < 0x70, "Alt: darker, on the same Tone layer"

block proceduralTextureDialog:
  let (d, _) = fresh(64, 64)
  runCommand("Procedural Texture...")
  run(3)
  check ptOpen and ptPreview != nil and ptEdit.name == texturePresets[0].name, "Procedural Texture: its dialog, a preview"
  for i, t in texturePresets:
    if t.name == "Checkerboard": ptLoad(i)
  check ptEdit.name == "Checkerboard" and abs(ptValues()[0] - 32) < 0.5, "a preset loaded, its sliders where it says"
  ptEdit.r = "sin("
  run(2)
  check ptError.startsWith("R: "), "a formula wrong: said under them"
  ptOpen = false
  run(1)

block constraintsAndBoardGrip:
  let (d, dw) = fresh(400, 300)
  d.beginStep("New Artboard")
  let G = d.addArtboard(rect(10, 10, 200, 100), color = 0xFFFFFFFF'u32)
  d.endStep()
  d.layersChange("bar"):
    let made = d.addShapeLayer(ShapeData(path: rectPath(20, 90, 200, 100), fill: solidPaint(0xFF0000FF'u32)), "Bar",
                               above = d.layers.find(G) - 1)
    made.pins = {lpLeft, lpRight, lpBottom}
  let bar = d.layers[d.layers.find(G) - 1]
  tool = tMove
  moveKind = 1
  stroke(dw, 210, 110, 310, 170)
  check G.board == rect(10, 10, 300, 160) and d.undoName == "Resize Artboard",
        "the Artboard tool: its corner dragged sizes it"
  check d.layerBox(bar) == rect(20, 150, 280, 10), "what is on it follows by its Constraints"
  stroke(dw, 100, 60, 120, 60)
  check G.board == rect(30, 10, 300, 160) and d.undoName == "Move Artboard", "inside it: moved, as before"
  moveKind = 0

block symbolsInTheApp:
  let (d, _) = fresh(300, 200)
  d.layersChange("shapes"):
    discard d.addShapeLayer(ShapeData(path: rectPath(10, 10, 50, 30), fill: solidPaint(0xFFFF0000'u32)), "Body")
    discard d.addShapeLayer(ShapeData(path: rectPath(15, 15, 25, 25), fill: solidPaint(0xFF0000FF'u32)), "Dot")
  d.layers[^1].picked = true
  d.layers[^2].picked = true
  runCommand("Create Symbol")
  run(2)
  let sym = d.current
  check sym.symbolOf.id == 1 and d.undoName == "Create Symbol", "Layer > Symbols > Create Symbol"
  runCommand("Insert Symbol:1")
  run(2)
  let other = d.current
  check other != sym and other.symbolOf.id == 1 and d.symbolInstances(1).len == 2, "Insert: another instance"
  var dot: Layer
  let oi = d.layers.find(other)
  for j in d.blockStart(oi) ..< oi:
    if d.layers[j].name == "Dot": dot = d.layers[j]
  d.beginStep("Edit")
  d.touchLayers()
  var s = dot.shape
  s.fill = solidPaint(0xFF00FF00'u32)
  d.setShape(dot, s)
  d.endStep()
  run(2)
  var green = 0
  for L in d.layers:
    if L.name == "Dot" and L.shape.fill.color == 0xFF00FF00'u32: inc green
  check green == 2, "changed in one: the other the same (the app keeps them alike)"
  d.cur = d.layers.find(other)
  runCommand("Detach from Symbol")
  check other.symbolOf.id == 0, "Detach from Symbol"

block menuCommandsReachTheirWork:
  # (each new menu command, run by its name as the menu runs it, does its work -- a command the
  # dispatch does not know does nothing and says nothing)
  let (d, _) = fresh(400, 300)
  runCommand("Isometric Grid")
  check d.pgOf.kind == pkIsometric and d.pgOf.shown, "View > Perspective Grid > Isometric"
  var sp = SubPath(closed: true)
  sp.pts.add PathPoint(p: (100.0, 20.0), inH: (60.0, 20.0), outH: (130.0, 20.0))
  sp.pts.add PathPoint(p: (180.0, 100.0), inH: (180.0, 40.0), outH: (180.0, 150.0))
  sp.pts.add PathPoint(p: (100.0, 160.0), inH: (150.0, 160.0), outH: (70.0, 160.0))
  sp.pts.add PathPoint(p: (20.0, 100.0), inH: (20.0, 120.0), outH: (20.0, 60.0))
  d.layersChange("egg"):
    discard d.addShapeLayer(ShapeData(path: Path(subs: @[sp]), fill: solidPaint(0xFF3A86FF'u32)), "Egg")
  runCommand("Smooth Curvature (G2)")
  check d.undoName == "Smooth Curvature (G2)" and pathCurvatureJump(d.current.shape.path) < 0.05,
        "Object > Path Operations > Smooth Curvature (G2)"
  if panelShown("textwrap"): runCommand("Text Wrap Panel")
  runCommand("Text Wrap Panel")
  check panelShown("textwrap"), "Window > Text Wrap Panel (Ctrl+Shift+W)"
  d.cur = 0                                # (the Background: pixels to adjust)
  runCommand("Hue Curves...")
  run(2)
  check adjKind == akHueCurves, "Image > Adjustments > Hue Curves..."
  key(KeyEsc)
  run(2)
  runCommand("Delete Workspace...")
  check studioDlg.deleting, "Window > Workspace > Delete Workspace..."
  studioDlg.deleting = false
  run(1)

block placeholderText:
  let (d, _) = fresh(400, 300)
  prefs.loremLang = 1
  prefs.loremParas = 4
  prefs.loremFill = false
  let n = d.layers.len
  runCommand("Fill with Placeholder Text...")
  run(2)
  check loremOpen, "Fill with Placeholder Text...: its dialog"
  loremOpen = false
  fillPlaceholder(d, true)
  let t = d.current.text.plainText
  check d.layers.len == n + 1 and d.current.isText and t.count('\n') == 3 and "تجريبي" in t,
        "Arabic, four paragraphs, in a new text box"
  check d.undoName == "Fill with Placeholder Text", "one step"
  prefs.loremLang = 0
  prefs.loremParas = 1
  fillPlaceholder(d, false)
  let t2 = d.current.text.plainText
  check t2.startsWith(t) and t2.count('\n') == 4 and t2.endsWith("."), "added after its text: one Latin paragraph more"
  prefs.loremLang = 2
  prefs.loremFill = true
  fillPlaceholder(d, true)
  let L = d.current
  let t3 = L.text.plainText
  check layoutText(d.effectiveText(L)).overflow == -1 and t3.count('\n') >= 2, "as many as fill the box: none overset"
  check t3[^1] == '.' or t3.endsWith("؟"), "... cut at the end of a sentence"
  var more = L.text
  more.spans[^1].text.add " " & loremParagraph(9)
  check layoutText(TextData(spans: more.spans, boxW: L.text.boxW, boxH: L.text.boxH, x: L.text.x,
                            y: L.text.y, antialias: true)).overflow >= 0, "... a sentence more would not fit"
  prefs.loremFill = false
  prefs.loremLang = 3
  prefs.lorem = "One.\nTwo."
  prefs.loremParas = 3
  check placeholderText() == "One.\nTwo.\nOne.", "your own text, its paragraphs again"
  savePrefs()
  prefs.loremParas = 9
  loadPrefs()
  check prefs.loremParas == 3 and prefs.loremLang == 3, "the choices kept"

echo "test_photoaffinity: ", passed, " passed"
