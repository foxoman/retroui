## Fuzzes the image editor example (examples/photo) headlessly: random
## clicks, drags, double-clicks, keys and typing over the whole program --
## tools on the image, palettes, menus, dialogs -- checking after each
## step that every document is still whole.
##
##   nim c -d:release --stackTrace:on --lineTrace:on tests/fuzz/fuzz_photo.nim
##   tests/fuzz/fuzz_photo 2000 7        # steps, random seed

import std/[random, strutils, os]
import retroui/uirelays/input
import ../harness
import retroui/psd

const photoUnderTest = true
include ../../examples/photo

randomize(if paramCount() >= 2: parseInt(paramStr(2)) else: 7)
let steps = if paramCount() >= 1: parseInt(paramStr(1)) else: 600

# a home of its own: what the dialogs save goes there
let home = getTempDir() / "retro-photo-fuzz"
removeDir(home)
createDir(home)
putEnv("HOME", home)
setCurrentDir(home)

fakeDriver()
setup()
startApp("photo", W, H)
view = photoFrame
keepRunning = true          # (File > Exit and Quit, chosen by the random clicks: it goes on)

proc sample(w, h: int): Doc =
  result = newDoc(w, h, white, name = "sample")
  let L = result.layer
  for y in 0 ..< h:
    for x in 0 ..< w:
      L.px[y * w + x] = argb(255, x * 255 div w, y * 255 div h, (x * y) mod 256)
  inc L.ver
  result.markAll()
  result.modified = false

addDoc(sample(120, 90))
run(3)

proc check() =
  for dw in docs:
    let d = dw.doc
    doAssert d.layers.len >= 1, "a document lost its layers"
    doAssert d.cur in 0 ..< d.layers.len, "the current layer is out of range"
    for L in d.layers:
      doAssert L.px.len == d.w * d.h, "a layer is not the image's size"
      if L.mask != nil: doAssert L.mask.px.len == d.w * d.h and L.mask.gray, "a layer mask is not the image's size"
      if L.adjust.kind.len > 0: doAssert L.gray, "an adjustment layer that is not a mask"
      if L.smart != nil: doAssert L.smart.src.len == L.smart.w * L.smart.h, "a Smart Object without its picture"
    doAssert d.sel.len == 0 or d.sel.len == d.w * d.h, "the selection is not the image's size"
    for a in d.alphas: doAssert a.m.len == d.w * d.h, "a channel is not the image's size"
    doAssert d.w > 0 and d.h > 0

const plainKeys = [KeyM, KeyL, KeyV, KeyW, KeyH, KeyZ, KeyC, KeyT, KeyK, KeyG, KeyN, KeyI,
                   KeyE, KeyY, KeyA, KeyB, KeyS, KeyU, KeyR, KeyO, KeyP, KeyX, KeyD, KeyQ,
                   KeyF, KeyTab, KeyEnter, KeyEsc, KeyDelete, KeyBackspace, KeyLeft, KeyRight,
                   KeyUp, KeyDown, Key0, Key3, Key5, KeyComma, KeyPeriod, KeySpace]
const ctrlKeys = [KeyZ, KeyX, KeyC, KeyV, KeyA, KeyD, KeyI, KeyL, KeyM, KeyU, KeyY, KeyB,
                  KeyT, KeyF, KeyN, KeyH, KeyG, KeyR, KeyW, KeyK, KeyJ, Key0, Key1, Key2, Key3,
                  KeyPlus, KeyMinus, KeyEqual]

const commands = ["180°", "90° CCW", "90° CW", "About Retro Photo...", "Actual Pixels",
  "Auto Tone", "Auto Contrast", "Auto Color", "Shadows/Highlights...", "Vibrance...", "Exposure...",
  "Photo Filter...", "Black & White...", "Channel Mixer...", "Develop...", "Reduce Noise...",
  "Content-Aware Fill", "Subject", "Sky", "Content-Aware Scale...", "Liquify...", "Lens Correction...",
  "Add Noise...", "All", "Anti-aliased PICT...", "Apply Image...", "Arbitrary...", "Auto Levels",
  "Bitmap...", "Blur", "Blur More", "Border...", "Brightness/Contrast...", "Brushes", "CMYK Color",
  "CMYK Preview", "Calculations...", "Canvas Size...", "Cascade", "Channels", "Clear", "Clipboard",
  "Close", "Close All", "Clouds", "Color Balance...", "Color Halftone...", "Color Range...",
  "Color Table...", "Commands", "Contents", "Contract...", "Copy", "Copy Merged", "Crop",
  "Crystallize...", "Curves...", "Custom...", "Cut", "De-Interlace...", "Define Pattern",
  "Desaturate", "Despeckle", "Difference Clouds", "Diffuse...", "Displace...", "Distort",
  "Duotone...", "Duplicate...", "Dust & Scratches...", "Emboss...", "Equalize", "Erase Image",
  "Expand...", "Extrude...", "Facet", "Feather...", "File Info...", "Fill...", "Find Edges",
  "Fit on Screen", "Flatten Image", "Flip Layer Horizontal", "Flip Layer Vertical", "Fragment",
  "Free", "Gamut Warning", "Gamut Warning...", "Gaussian Blur...", "General...", "Grayscale",
  "Grow", "Hide Edges", "Hide Palettes", "High Pass...", "Histogram...", "Horizontal",
  "How to Use Help", "Hue/Saturation...", "Image Size...", "Indexed Color...", "Info", "Inverse",
  "Invert", "Lab Color", "Last Filter", "Layers", "Lens Flare...", "Levels...",
  "Lighting Effects...", "Load Selection", "Make Work Path", "Maximum...", "Median...",
  "Mezzotint...", "Minimum...", "Monitor Setup...", "Mosaic...", "Motion Blur...", "Multichannel",
  "NTSC Colors", "New Window", "New...", "None", "Offset...", "Open As...", "Open...", "Options",
  "Page Setup...", "Paste", "Paste Into", "Paste Layer...", "Paths", "Paths to Illustrator...",
  "Pattern", "Perspective", "Picker", "Pinch...", "Place...", "Plug-ins...", "Pointillize...",
  "Polar Coordinates...", "Posterize...", "Printing Inks Setup...", "Profile Setup...",
  "Quick Edit...", "RGB Color", "Radial Blur...", "Redo", "Replace Color...", "Reset Palettes",
  "Revert", "Ripple...", "Save", "Save As...", "Save Selection", "Save a Copy...", "Scale",
  "Scratch", "Scratch Disks...", "Search for Help on...", "Select All", "Select TWAIN Source...",
  "Selective Color...", "Separation Setup...", "Sharpen", "Sharpen Edges", "Sharpen More",
  "Shear...", "Show Rulers", "Similar", "Skew", "Smooth...", "Snapshot", "Solarize", "Spherize...",
  "Stroke...", "Swatches", "TWAIN Acquire...", "TWAIN Export...", "Take Snapshot",
  "Texture Fill...", "Threshold...", "Tile", "Tiles...", "Tools", "Trace Contour...", "Trap...",
  "Twirl...", "Undo", "Undo History", "Units...", "Unsharp Mask...", "Variations...", "Vertical",
  "Wave...", "Wind...", "ZigZag...", "Zoom In", "Zoom Out", "New Layer...", "Duplicate Layer",
  "Delete Layer", "Merge Down", "Merge Visible", "Rasterize Layer Style", "Character", "Paragraph",
  "Export As...", "Quick Export as PNG", "Quick Export as JPEG", "Layer from File...", "Create Clipping Mask",
  "Release Clipping Mask", "Toggle Clipping Mask", "Filter Factory...", "Edit Plug-in...", "Sepia Tone...",
  "Ripples...", "Pixel Blocks...", "Kaleidoscope...", "Emboss Relief...", "Lab Color", "Duotone...",
  "New Group...", "Group Layers", "Ungroup Layers", "Bring to Front", "Bring Forward", "Send Backward",
  "Send to Back", "Lock Layer", "Unlock Layer", "Blending Options...", "Merge Group", "Group Properties...",
  "Layer Options...", "Duplicate Group", "Delete Group",
  "Convert to Smart Object", "Rasterize Smart Object", "New Smart Object via Copy", "Edit Contents",
  "Replace Contents...", "Export Contents...", "Warp", "Puppet Warp", "Perspective Warp...",
  "Field Blur...", "Iris Blur...", "Tilt-Shift...", "Surface Blur...", "Skin Smoothing...",
  "Sky Replacement...", "Auto-Align Layers...", "Auto-Blend Layers...", "Photomerge...",
  "Merge to HDR Pro...", "Load Files into Stack...", "Batch...", "Fit Image...", "Trim",
  "Assign Profile...", "Convert to Profile...", "Everything", "Options Bar", "Actions", "Properties",
  "Navigator", "History", "Select and Mask...", "New Snapshot", "Show Guides", "Show Grid",
  "New Guide...", "Clear Guides", "Solid Color...", "Gradient...", "Gradient Map...", "Color Lookup..."]
  ## every menu command (the ones that only open a dialog included)

proc anywhere(): (int, int) =
  # more often over the image, the menus and the palettes
  case rand(9)
  of 0, 1, 2: (rand(80 .. 420), rand(40 .. 330))
  of 3: (rand(0 .. 330), rand(0 .. 14))
  of 4: (rand(0 .. 330), rand(14 .. 300))          # (an open menu)
  of 5: (rand(400 .. W - 1), rand(20 .. H - 1))    # the palettes
  of 6: (rand(0 .. 80), rand(20 .. 300))           # the toolbox
  else: (rand(W - 1), rand(H - 1))

for step in 1 .. steps:
  let r = rand(1.0)
  if getEnv("FUZZ_TRACE").len > 1:
    echo "> ", step, " r=", formatFloat(r, ffDecimal, 3), " dlg=", ui.dialogTop, " new ", newOpen, " ", newW, "x", newH,
         " size ", isOpen, " ", isPW, "x", isPH, " canvas ", csOpen, " ", csW, "x", csH, " filter ", fOpen, " ", fSpec.name,
         " ", fVals, " adj ", adjOpen
  if r < 0.03 and r >= 0.015 and not drag.on and ui.dialogTop == 0 and cur() != nil:
    # (layer masks and adjustment layers, often)
    let d = cur()
    case rand(6)
    of 0:
      if not d.current.background and d.current.mask == nil and d.current.adjust.kind.len == 0:
        d.layersChange("Add Layer Mask"):
          d.addLayerMask(sample([mfRevealAll, mfHideAll, mfRevealSelection, mfHideSelection]))
          d.editMask = true
    of 1: startAdjustLayer(sample([akLevels, akCurves, akBC, akBalance, akHS, akSelective, akVibrance,
                                  akExposure, akPhotoFilter, akBlackWhite, akMixer, akThreshold, akPosterize]))
    of 2: d.editMask = not d.editMask
    of 3:
      if d.current.mask != nil:
        d.layersChange("Apply Layer Mask"): d.removeLayerMask(apply = rand(1) == 0)
    of 4:
      if d.cur > 0 and d.layers[d.cur - 1].adjust.kind.len == 0:
        d.layersChange("Merge Down"):
          d.touch(d.layers[d.cur - 1], d.bounds)
          d.mergeDown()
    of 5:
      if d.current.mask != nil:
        d.layersChange("Layer Mask"):
          d.current.maskOff = not d.current.maskOff
          d.markAll()
      elif rand(1) == 0:
        # (groups: picked layers grouped, opened and closed, mixing their own way)
        for L in d.layers: L.picked = rand(2) == 0
        d.layersChange("Group Layers"): discard d.groupLayers(d.pickedLayers)
        if rand(1) == 0: d.current.collapsed = not d.current.collapsed
        if rand(1) == 0 and d.current.group: d.current.passThrough = not d.current.passThrough
        d.markAll()
      else:
        d.layersChange("Blend If"):
          d.current.blendIf.this = [rand(0 .. 60), rand(60 .. 120), rand(120 .. 200), 255]
          d.current.maskDensity = rand(0 .. 100)
          d.current.maskFeather = rand(0.0 .. 8.0)
          d.markAll()
    else:
      d.layersChange("New Layer"): discard d.addLayer()
    run()
  elif r < 0.045 and r >= 0.03 and not drag.on and ui.dialogTop == 0 and cur() != nil and active != nil:
    # (type and layer styles, often)
    let d = cur()
    case rand(9)
    of 0:
      selectTool(tType)
      let (x, y) = (rand(100 .. 400), rand(60 .. 300))
      down(x, y)
      run()
      if rand(1) == 0: move(x + rand(10 .. 120), y + rand(10 .. 80))
      run()
      up(x, y)
      run()
      typeText(sample(["Hello", "Retro ", "مرحبا", "abc def ghi", "1 2 3", "\n", "x"]))
      run()
    of 1:
      if te.on:
        applyChar("Fuzz", proc (s: var CharStyle) =
          case rand(9)
          of 0: s.size = float32(rand(1 .. 200))
          of 1: s.family = sample(fontFamilies())
          of 2: s.style = sample(["Regular", "Bold", "Italic", "Book"])
          of 3: s.tracking = rand(-500 .. 2000)
          of 4: s.allCaps = not s.allCaps
          of 5: s.script = sample([scNormal, scSuper, scSub])
          of 6: s.hScale = rand(0.1 .. 3.0)
          of 7: s.underline = not s.underline
          else: s.baselineShift = float32(rand(-50 .. 50)))
    of 2:
      if typeTarget() != nil:
        applyText("Fuzz", proc (t: var TextData) =
          case rand(4)
          of 0: t.para.align = sample([textLeft, textCenter, textRight, justifyLeft, justifyAll])
          of 1: t.warp = TextWarp(style: sample([wsNone, wsArc, wsFlag, wsTwist, wsFisheye]), bend: rand(-100 .. 100),
                                  hDistort: rand(-100 .. 100), vertical: rand(1) == 0)
          of 2: t.boxW = float32(rand(0 .. 200)); t.boxH = float32(rand(0 .. 100))
          of 3: t.para.rtl = rand(2)
          else: t.para.indentFirst = float32(rand(-20 .. 40)))
    of 3: startLayerStyle(rand(-1 .. 8))
    of 4: startWarp()
    of 5:
      if te.on:
        if rand(1) == 0: commitType() else: cancelType()
    of 6:
      if not d.current.background and d.current.adjust.kind.len == 0:
        d.stepOnce("Fuzz Style", proc () =
          let k = sample([fxDropShadow, fxOuterGlow, fxGradientOverlay, fxColorOverlay, fxSatin, fxInnerGlow,
                          fxInnerShadow, fxStroke, fxBevel])
          d.current.fx.fx[k] = defaultEffect(k)
          d.current.fx.fx[k].style = rand(4)
          d.current.fx.fx[k].size = rand(0 .. 30)
          d.current.fill = rand(100)
          d.markAll())
    of 7:
      # text along a path
      d.beginStep("Fuzz Path")
      d.touchPaths()
      d.paths.add Path(name: "Work Path", subs: @[SubPath(pts: @[
        PathPoint(p: (5.0, 60.0), inH: (5.0, 60.0), outH: (5.0, 60.0)),
        PathPoint(p: (100.0, 20.0), inH: (100.0, 20.0), outH: (100.0, 20.0))])])
      d.curPath = d.paths.high
      d.endStep()
      if typeTarget() != nil:
        applyText("Type on Path", proc (t: var TextData) =
          t.path = @[(5'f32, 60'f32), (100'f32, 20'f32)]
          t.pathOffset = float32(rand(0 .. 40)))
      else:
        selectTool(tType)
        down(150, 120)
        run()
        up(150, 120)
    else:
      if te.on: typeKeys()
    run()
  elif r < 0.06 and r >= 0.045 and not drag.on and ui.dialogTop == 0 and cur() != nil and active != nil:
    # (shapes, modes, brush dynamics, Photoshop files, often)
    let d = cur()
    case rand(7)
    of 0, 1:
      selectTool(tShape)
      shapeKind = rand(5)
      shapeMode = sample([0, 0, 0, 1, 2])
      shapeOp = rand(4)
      shapeFillKind = rand(2)
      shapeStrokeKind = rand(1)
      shapeStrokeW = rand(1 .. 20)
      shapeAlign = rand(2)
      shapeDash = rand(2)
      customShape = rand(CustomShapes.high)
      polyStar = rand(1) == 0
      let (x, y) = (rand(100 .. 400), rand(60 .. 300))
      down(x, y)
      run()
      move(x + rand(-150 .. 150), y + rand(-150 .. 150))
      run()
      up(x + rand(-150 .. 150), y + rand(-150 .. 150))
      run()
    of 2:
      if d.current.isShape:
        var sh = d.current.shape
        sh.fill = sample([solidPaint(0xFF808000'u32), gradientPaint(0xFF000000'u32, 0xFFFF00FF'u32, rand(360), rand(4)),
                          ShapePaint()])
        sh.strokeWidth = rand(0.0 .. 30.0)
        sh.stroke = sample([ShapePaint(), solidPaint(0xFF0000FF'u32)])
        sh.dashes = sample([@[], @[2.0, 1.0], @[0.01, 2.0]])
        d.stepOnce("Fuzz Shape", proc () = d.setShape(d.current, sh))
    of 3:
      symmetry = rand(5)
      symAxes = rand(2 .. 16)
      brushSmoothing = rand(0 .. 100)
      let t = sample([tBrush, tPencil, tAirbrush, tEraser])
      opts[t].dyn = BrushDynamics(sizeJitter: rand(100), angleJitter: rand(100), roundJitter: rand(100),
                                  scatter: rand(500), scatterBoth: rand(1) == 0, count: rand(0 .. 5),
                                  countJitter: rand(100), opacityJitter: rand(100), flow: rand(100),
                                  flowJitter: rand(100), hueJitter: rand(100), fgBgJitter: rand(100))
      selectTool(t)
    of 4:
      runCommand(sample(["CMYK Color", "Lab Color", "RGB Color", "Grayscale", "CMYK Preview", "Gamut Warning"]))
      if d.mode == cmGray and rand(1) == 0:
        d.change("Duotone"): d.toDuotone(defaultDuotone(rand(1 .. 4)))
      if rand(1) == 0: d.showChannel(rand(0 .. max(0, d.channelCount - 1)))
      else: d.showAllChannels()
    of 5:
      # written as Photoshop and read back: whole
      try:
        let back = docOfPsd(readPsd(writePsd(psdOf(d))))
        doAssert back.w == d.w and back.h == d.h and back.layers.len >= 1
        for L in back.layers: doAssert L.px.len == back.w * back.h
      except PsdError: doAssert false, "a document we wrote could not be read"
    of 6:
      if d.cur > 0 and not d.current.background:
        d.layersChange("Clip"): d.current.clipped = not d.current.clipped
    else:
      if plugins.len > 0: runCommand(sample(plugins).name)
    run()
  elif r < 0.015 and not drag.on:
    # (the healing tools and the red eye, often: they are slow to reach by chance)
    let t = rand(3)
    if t < 3:
      healMode = t
      selectTool(tHeal)
    else: selectTool(tRedEye)
    if healMode == 1 and cur() != nil: stampSrc = (true, rand(0.0 .. 50.0), rand(0.0 .. 50.0), cur())
  elif r < 0.07:
    # (a menu command: only when a menu could be used -- no dialog up)
    if ui.dialogTop == 0: runCommand(sample(commands))
    run()
  elif r < 0.32:
    let (x, y) = anywhere()
    down(x, y, if rand(9) == 0: 2 else: 1)
    run()
    up(x, y)
    run()
  elif r < 0.55:
    let (x, y) = anywhere()
    down(x, y)
    run()
    var (cx, cy) = (x, y)
    for _ in 0 .. rand(6):
      cx = clamp(cx + rand(-60 .. 60), 0, W - 1)
      cy = clamp(cy + rand(-60 .. 60), 0, H - 1)
      move(cx, cy)
      run()
    up(cx, cy)
    run()
  elif r < 0.72:
    key(sample(plainKeys), if rand(5) == 0: {ShiftPressed} elif rand(7) == 0: {AltPressed} else: {})
    run()
  elif r < 0.86:
    key(sample(ctrlKeys), if rand(4) == 0: {CtrlPressed, ShiftPressed} else: {CtrlPressed})
    run()
  elif r < 0.94:
    var s = ""
    for _ in 0 .. rand(5): s.add sample(["1", "0", "5", "-", ".", "9", "a", "x", " ", "255", "999"])
    typeText(s)
    run()
  else:
    let (x, y) = anywhere()
    move(x, y)
    run(3)
  quitAsked = false
  # (Quit taken -- Enter on its question: a program would end there; this one goes on, as if
  # started again. Left ended, each frame was drawn over the last one and never let go: 4 GB)
  ui.running = true
  if docs.len == 0 and rand(3) == 0:
    addDoc(sample(rand(1 .. 150), rand(1 .. 110)))
    run()
  check()
  if getEnv("FUZZ_TRACE").len > 0:
    var sizes = ""
    for dw in docs: sizes.add " " & $dw.doc.w & "x" & $dw.doc.h & "/" & $dw.doc.layers.len
    echo step, ": r=", formatFloat(r, ffDecimal, 2), " tool ", tool, sizes, " ", status
  if step mod 200 == 0:
    echo "step ", step, ": ", docs.len, " documents; tool ", tool, "; ", status

echo "photo fuzz: ", steps, " steps passed", (if appQuits > 0: " (it quit " & $appQuits & " times and went on)" else: "")
