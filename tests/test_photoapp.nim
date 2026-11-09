## Tests of the image editor example (examples/photo) as a program, run
## headless: its actions (recording, playing, keeping them), Batch, Fit
## Image, Trim and the options bar.

import std/[strutils, os, math, random]
import retroui/uirelays/input
import harness

const photoUnderTest = true
include ../examples/photo

# (the modules Retro Photo imports for what they set up are imported: a
# cleanup of unused imports once took photodeep out, and 16-bit filters
# went with it)
doAssert adjustmentLut != nil and shapeRender != nil and layerFxRender != nil and
         syncHdrHook != nil and showHdrHook != nil and hiFilterHook != nil and
         flatten16Hook != nil and deepGradientHook != nil and cameraRawReader != nil,
         "every hook of retroui/photo is set"

# a home of its own: the settings (and the actions) go there
let home = getTempDir() / "retro-photo-apptest"
removeDir(home)
createDir(home)
putEnv("HOME", home)
setCurrentDir(home)

fakeDriver()
setup()
startApp("photo", W, H)
view = photoFrame

proc sample(w, h: int): Doc =
  result = newDoc(w, h, white, name = "sample")
  let L = result.layer
  for y in 0 ..< h:
    for x in 0 ..< w:
      L.px[y * w + x] = argb(255, x * 255 div w, y * 255 div h, (x * y) mod 256)
  inc L.ver
  result.markAll()
  result.modified = false

block actionsRecordAndPlay:
  loadActions()
  doAssert actions.len > 0
  let before = actions.len
  addDoc(sample(40, 30))
  run(2)
  newAction("Test")
  doAssert recording and actSel == actions.high
  runCommand("Invert")
  runFilter("Gaussian Blur", @[2.0])
  runCommand("Zoom In")                # (not a step)
  recording = false
  doAssert actions.len == before + 1
  let a = actions[^1]
  doAssert a.steps.len == 2
  doAssert a.steps[0].kind == acCommand and a.steps[0].name == "Invert"
  doAssert a.steps[1].kind == acFilter and a.steps[1].vals == @[2.0]
  doAssert stepTitle(a.steps[1]).startsWith("Gaussian Blur (Radius 2")
  # kept, and read back as it was
  let back = parseActions(actionsText(actions))
  doAssert back.len == actions.len and back[^1].steps.len == 2 and back[^1].steps[1].name == "Gaussian Blur"
  loadActions()
  doAssert actions.len == before + 1 and actions[^1].name == "Test"
  # played on another image: the same as doing it by hand
  addDoc(sample(40, 30))
  let byHand = cur()
  runCommand("Invert")
  runFilter("Gaussian Blur", @[2.0])
  addDoc(sample(40, 30))
  let played = cur()
  playAction(actions.high)
  doAssert played.layer.px == byHand.layer.px
  doAssert played.historyStates.len == 3
  # a step left out
  addDoc(sample(40, 30))
  let part = cur()
  actions[^1].steps[1].on = false
  playAction(actions.high)
  doAssert part.layer.px[0] == (sample(40, 30).layer.px[0] xor 0x00FFFFFF'u32)
  doAssert part.historyStates.len == 2
  # a stop
  actions[^1].steps.insert(ActStep(kind: acStop, name: "Look", on: true), 0)
  addDoc(sample(40, 30))
  let stopped = cur()
  playAction(actions.high)
  doAssert stopped.historyStates.len == 1 and status == "Look"

block adjustmentsAndDialogs:
  addDoc(sample(40, 30))
  let d = cur()
  newAction("Dialogs")
  startAdjust(akHS)
  hsColorize = true
  hsH = 30
  hsS = 40
  endAdjust(true)
  startImageSize()
  isPW = 20
  isPH = 15
  # (the dialog's OK, as the test cannot click it: what it records)
  d.snapStep("Image Size")
  d.imageSize(20, 15, rsBicubic, d.dpi)
  d.endStep()
  record(ActStep(kind: acImageSize, name: "Image Size", vals: @[20.0, 15, 2, d.dpi, 0]))
  isOpen = false
  recording = false
  let a = actions[^1]
  doAssert a.steps.len == 2 and a.steps[0].kind == acAdjust and a.steps[0].name == "Hue/Saturation"
  doAssert a.steps[1].kind == acImageSize
  addDoc(sample(40, 30))
  let e = cur()
  playAction(actions.high)
  doAssert e.w == 20 and e.h == 15
  doAssert e.layer.px == d.layer.px

block fitAndTrim:
  let d = sample(400, 200)
  d.fitImage(100, 100, true)
  doAssert d.w == 100 and d.h == 50
  d.fitImage(1000, 1000, true)
  doAssert d.w == 100                       # (Don't Enlarge)
  d.fitImage(1000, 1000, false)
  doAssert d.w == 1000 and d.h == 500
  # Trim: the transparent edges
  let t = newDoc(50, 40, 0'u32, name = "t")
  let L = t.addLayer("dot")
  for y in 10 .. 19:
    for x in 5 .. 24: L.px[y * 50 + x] = 0xFF00FF00'u32
  inc L.ver
  t.markAll()
  doAssert t.trimRect() == rect(5, 10, 20, 10)
  # no transparency: the color of the top left corner
  let u = newDoc(30, 30, white, name = "u")
  u.layer.px[15 * 30 + 20] = black
  inc u.layer.ver
  u.markAll()
  doAssert u.trimRect() == rect(20, 15, 1, 1)

block batch:
  let src = home / "batch-in"
  let dst = home / "batch-out"
  createDir(src / "sub")
  for i, (w, h) in [(80, 40), (60, 60), (30, 90)]:
    sample(w, h).exportPicture(src / ("pic" & $i & ".png"), defaultExport(efPng))
  sample(50, 50).exportPicture(src / "sub" / "deep.png", defaultExport(efPng))
  writeFile(src / "notes.txt", "not a picture")
  writeFile(src / "broken.png", "not a png either")
  actions.add Action(name: "Small", steps: @[
    ActStep(kind: acFitImage, name: "Fit Image", vals: @[20.0, 20, 1], on: true),
    ActStep(kind: acCommand, name: "Horizontal", on: true)])
  let open0 = docs.len
  batchAction = actions.high
  batchSrc = src
  batchDst = dst
  batchFormat = 1
  batchSuffix = "-small"
  batchSubfolders = true
  runBatch()
  doAssert docs.len == open0                     # (each one closed again)
  doAssert fileExists(dst / "pic0-small.png") and fileExists(dst / "pic2-small.png")
  doAssert fileExists(dst / "sub" / "deep-small.png")
  let p = openPicture(dst / "pic0-small.png")
  doAssert p.w == 20 and p.h == 10
  let q = openPicture(dst / "pic2-small.png")
  doAssert q.w == 7 and q.h == 20
  doAssert batchLog.len == 1 and "broken.png" in batchLog[0]
  doAssert "3 of 4" notin status and "4 of 5" in status

proc scene(w, h: int; seed = 3): Img =
  ## Something with corners: boxes and discs of many colors on a gradient.
  var r = initRand(seed)
  result = newImg(w, h)
  for y in 0 ..< h:
    for x in 0 ..< w:
      result.px[y * w + x] = argb(255, 60 + x * 120 div w, 80, 60 + y * 120 div h)
  for _ in 0 ..< (w * h) div 900:
    let c = argb(255, r.rand(255), r.rand(255), r.rand(255))
    let cx = r.rand(w - 1)
    let cy = r.rand(h - 1)
    let s = 4 + r.rand(18)
    for y in max(0, cy - s) .. min(h - 1, cy + s):
      for x in max(0, cx - s) .. min(w - 1, cx + s):
        if (x - cx) ^ 2 + (y - cy) ^ 2 <= s * s: result.px[y * w + x] = c

proc docOf(im: Img; name: string): Doc =
  result = newDoc(im.w, im.h, white, name = name)
  result.layer.px = im.px
  inc result.layer.ver
  result.markAll()
  result.modified = false

proc cropOf(im: Img; x, y, w, h: int): Img =
  result = newImg(w, h)
  for yy in 0 ..< h:
    for xx in 0 ..< w: result.px[yy * w + xx] = im.px[(y + yy) * im.w + x + xx]

block combine:
  let big = scene(900, 360, 21)
  addDoc(docOf(cropOf(big, 0, 0, 520, 360), "left"))
  addDoc(docOf(cropOf(big, 380, 0, 520, 360), "right"))
  let n0 = docs.len
  startMerge(mkPanorama)
  mgFiles = @["doc:" & $(n0 - 1), "doc:" & $(n0 - 2)]
  mgLayout = 2
  mgCrop = true
  runMerge()
  doAssert docs.len == n0 + 1 and cur().name == "Untitled Panorama", status
  doAssert abs(cur().w - 900) <= 3 and abs(cur().h - 360) <= 3, $(cur().w, cur().h)
  doAssert cur().layers.len == 2 and cur().layers[1].mask != nil
  # HDR from a dark and a bright copy
  var dark = newImg(300, 200)
  var bright = newImg(300, 200)
  let s0 = scene(300, 200, 8)
  for i, p in s0.px:
    dark.px[i] = argb(255, rOf(p) div 3, gOf(p) div 3, bOf(p) div 3)
    bright.px[i] = argb(255, min(255, rOf(p) * 2), min(255, gOf(p) * 2), min(255, bOf(p) * 2))
  addDoc(docOf(dark, "dark"))
  addDoc(docOf(bright, "bright"))
  startMerge(mkHdr)
  mgFiles = @["doc:" & $(docs.len - 2), "doc:" & $(docs.len - 1)]
  runMerge()
  doAssert cur().name == "Untitled HDR" and cur().w == 300
  # a stack, aligned
  startMerge(mkStack)
  mgStackAlign = true
  mgFiles = @["doc:" & $(n0 - 2), "doc:" & $(n0 - 1)]
  runMerge()
  doAssert cur().name == "Untitled Stack" and cur().layers.len == 2
  # Auto-Align: a layer moved 15, 9 back onto the Background
  let base = scene(400, 300, 31)
  let d = docOf(base, "align")
  let L = d.addLayer("moved")
  for y in 0 ..< 300:
    for x in 0 ..< 400:
      let sx = x - 15
      let sy = y - 9
      L.px[y * 400 + x] = if sx >= 0 and sy >= 0: base.px[sy * 400 + sx] else: 0'u32
  inc L.ver
  addDoc(d)
  d.layers[0].picked = true
  d.cur = 1
  d.autoAlign(amTranslation)
  var off = 0
  for y in 40 ..< 260:
    for x in 40 ..< 360:
      if d.layers[0].px[y * 400 + x] != d.layers[1].px[y * 400 + x] and
         d.layers[1].px[y * 400 + x] != d.layers[0].px[y * 400 + x]:
        let a = d.layers[0].px[y * 400 + x]
        let b = d.layers[1].px[y * 400 + x]
        if abs(rOf(a) - rOf(b)) > 30: inc off
  doAssert off < 200, $off
  # Auto-Blend as a stack: masks on the layers above the bottom one
  d.autoBlend(true)
  doAssert d.layers[1].mask != nil
  # Sky Replacement on a picture with a sky
  var sk = newImg(240, 160)
  let ground = scene(240, 160, 4)
  for y in 0 ..< 160:
    for x in 0 ..< 240:
      sk.px[y * 240 + x] = if y < 70: argb(255, 90 + y, 150 + y div 2, 235) else: ground.px[y * 240 + x]
  let sd = docOf(sk, "sky")
  addDoc(sd)
  startSky()
  doAssert skOpen, status
  skOpen = false
  applySky(sd)
  doAssert sd.layers.len == 4 and sd.layers[^1].group and sd.layers[^1].name == "Sky Replacement Group"
  doAssert sd.layers[2].name == "Sky" and sd.layers[2].mask != nil
  # the filters: Surface Blur, Skin Smoothing
  runFilter("Surface Blur", @[4.0, 20])
  runFilter("Skin Smoothing", @[6.0, 50])

block smartObjects:
  let d = docOf(scene(200, 150, 41), "smart")
  addDoc(d)
  run(2)
  runCommand("Convert to Smart Object")
  let L = d.current
  doAssert L.isSmart and L.smart.w == 200 and not L.background
  let before = L.px
  # a filter: a Smart Filter, the pixels drawn again
  runFilter("Gaussian Blur", @[3.0])
  doAssert L.smart.filters.len == 1 and L.smart.filters[0].name == "Gaussian Blur"
  doAssert L.px != before
  d.undo()
  doAssert L.smart.filters.len == 0 and L.px == before
  d.redo()
  doAssert L.smart.filters.len == 1
  # turned off in Properties: as it was
  L.smart = L.smart.withFilters(@[SmartFilter(name: "Gaussian Blur", args: @[3.0], off: true)])
  d.renderSmartLayer(L)
  doAssert L.px == before
  # scaled down and back up: nothing lost
  startTransform(xkScale)
  doAssert xf.on and xfSmart != nil
  xf.quad = quadOf(rect(50, 40, 100, 75))
  xfApply()
  finishTransform(true)
  doAssert abs(L.smart.quad[2][0] - 150) < 1e-6
  startTransform(xkScale)
  xf.quad = quadOf(rect(0, 0, 200, 150))
  xfApply()
  finishTransform(true)
  var off = 0
  for i in 0 ..< before.len:
    if L.px[i] != before[i]: inc off
  doAssert off < before.len div 50, $off
  # flipped twice: itself
  runCommand("Flip Layer Horizontal")
  runCommand("Flip Layer Horizontal")
  doAssert L.px == before
  # Edit Contents: a window of its own; saving puts it back
  let n0 = docs.len
  runCommand("Edit Contents")
  doAssert docs.len == n0 + 1
  let child = cur()
  child.beginStep("Invert")
  child.applyFilter(0, invert())
  child.endStep()
  active.save()
  doAssert not child.modified
  doAssert L.smart.src[0] == (before[0] xor 0x00FFFFFF'u32)
  closeDoc(active)
  for dw in docs:
    if dw.doc == d: active = dw
  # Warp: a style on the options bar's settings, then back flat
  startWarpMode(wkWarp)
  doAssert wm.kind == wkWarp and wm.smart0 != nil
  wm.mesh = presetMesh(TextWarp(style: wsBulge, bend: 40), 0.75)
  wmApply()
  doAssert L.smart.warp.len == 16
  modeFinish(true)
  doAssert wm.kind == wkNone
  d.undo()
  doAssert L.smart.warp.len == 0
  # Perspective Warp on pixels
  let p = docOf(scene(160, 120, 42), "persp")
  addDoc(p)
  let pl = p.addLayer("pix")
  pl.px = scene(160, 120, 43).px
  inc pl.ver
  startWarpMode(wkPersp)
  doAssert wm.kind == wkPersp and wm.layout
  modeFinish(true)                      # (Enter in Layout: on to Warp)
  doAssert wm.kind == wkPersp and not wm.layout
  wm.q1[1] = (wm.q1[1][0] + 10, wm.q1[1][1])
  wmApply()
  let warped = pl.px
  modeFinish(true)
  doAssert pl.px == warped and wm.kind == wkNone
  # Puppet Warp: two pins, one moved
  startWarpMode(wkPuppet)
  wm.pins = @[(40.0, 60.0), (120.0, 60.0)]
  wm.moved = @[(40.0, 60.0), (130.0, 70.0)]
  wmApply()
  modeFinish(true)
  doAssert pl.px != warped
  # Esc: as it was
  let kept = pl.px
  startWarpMode(wkWarp)
  wm.mesh[5] = (0.5, 0.5)
  wmApply()
  modeFinish(false)
  doAssert pl.px == kept
  # the Blur Gallery
  startBlurGallery(1)
  doAssert bgOpen
  run(2)
  bgOpen = false
  # (its OK)
  let rad = bgRadius(p.w, p.h, 1.0)
  doAssert rad[0] > rad[60 * 160 + 80]
  # Place: a Smart Object
  let pic = home / "place.png"
  docOf(scene(50, 40, 3), "pic").exportPicture(pic, defaultExport(efPng))
  p.placeSmart(pic)
  doAssert p.current.isSmart and p.current.smart.w == 50
  # saved and opened again
  let path = home / "smart.rpd"
  p.saveRpd(path)
  let q = loadRpd(path)
  doAssert q.layers[^1].smart != nil and q.layers[^1].smart.w == 50

block cameraRaw:
  var raw = RawImage(w: 120, h: 80, px: newSeq[float32](120 * 80 * 3))
  for i in 0 ..< 120 * 80:
    raw.px[3 * i] = float32(i mod 120) / 120
    raw.px[3 * i + 1] = 0.4
    raw.px[3 * i + 2] = float32(i div 120) / 80
  let d = docOfRaw(raw, "raw")
  addDoc(d)
  startCameraRaw(raw)
  doAssert dvOpen and dvRawOn
  dvS.exposure = 100
  dvS.contrast = 30
  run(3)
  doAssert dvBmp != nil
  # (Auto from the photo as shot)
  discard dvAuto()
  dvOpen = false
  dvRawOn = false
  run(1)

block brushesAndProfiles:
  # brushes from a file: presets in a folder named for it
  let n0 = presets.len
  let t = BrushTip(name: "Dot", custom: newSeq[uint8](25), cw: 5, ch: 5, spacing: 25)
  writeFile(home / "b.abr", writeAbr([t, t]))
  brushFilePath = home / "b.abr"
  brushFileSave = false
  brushFilePick = true
  for b in readBrushes(brushFilePath, readFile(brushFilePath)):
    presets.add BrushPreset(name: b.name, folder: "b", tip: b)
  brushFilePick = false
  doAssert presets.len == n0 + 2 and presets[^1].folder == "b"
  presets.setLen(n0)
  # Convert to Profile from the dialog's state
  let d = docOf(scene(40, 30, 2), "prof")
  addDoc(d)
  startProfile(true)
  doAssert profOpen
  profPick = 1
  run(2)
  profOpen = false
  d.convertProfile(builtInProfile("Adobe RGB (1998)"))
  doAssert d.profileName == "Adobe RGB (1998)"
  run(2)                                  # (shown converted)

block backgroundSave:
  # a big image: saved in the background, the program going on
  let d = newDoc(2000, 1600, white, name = "big")
  let L = d.addLayer("noise")
  for i in 0 ..< L.px.len: L.px[i] = 0xFF000000'u32 or uint32((i * 2654435761) and 0xFFFFFF)
  inc L.ver
  d.modified = true
  addDoc(d)
  let path = home / "big.rpd"
  saveCopy = false
  active.writeDoc(path)
  doAssert saving() and not d.modified and d.path == path
  var frames = 0
  while saving() and frames < 4000:
    run(1)
    inc frames
    os.sleep(2)
  doAssert not saving() and status == "Saved big.rpd", status
  let e = loadRpd(path)
  doAssert e.layers.len == 2 and e.layers[1].px == L.px
  # a small one: at once
  let small = docOf(scene(50, 40, 3), "small")
  addDoc(small)
  active.writeDoc(home / "small.png")
  doAssert not saving() and fileExists(home / "small.png")
  # Purge > Everything
  runCommand("Everything")
  doAssert not d.canUndo and "Purged" in status

block optionsBar:
  # every tool's options in the bar, drawn (and nothing goes wrong)
  addDoc(sample(60, 40))
  for t in Tool:
    selectTool(t)
    run(2)
  for k in 0 .. 5:
    shapeKind = k
    selectTool(tShape)
    run(1)
  optionsBarOn = false
  run(2)
  optionsBarOn = true
  run(2)

block brushPresets:
  mgOpen = false                      # (the Photomerge dialog of a block before)
  run(2)
  # the presets: four folders; chosen, the brush takes the preset's tip and dynamics
  doAssert presets.len >= 28
  var folders: seq[string]
  for p in presets:
    if p.folder notin folders: folders.add p.folder
  doAssert folders.len >= 4
  addDoc(sample(80, 60))
  selectTool(tBrush)
  let leaves = presetIndex("Leaves")
  doAssert leaves >= 0
  applyPreset(presets[leaves])
  doAssert opts[tBrush].preset == "Leaves" and opts[tBrush].tip.custom.len > 0
  doAssert opts[tBrush].dyn.scatter > 0 and opts[tBrush].dyn.fgBgJitter == 100
  # , and . step through them; [ and ] the size; Shift+[ the hardness
  applyPreset(presets[presetIndex("Hard Round")])
  let size0 = opts[tBrush].tip.diameter
  run(1)
  key(KeyRightBracket)
  run(1)
  doAssert opts[tBrush].tip.diameter == size0 + 10, $opts[tBrush].tip.diameter
  key(KeyLeftBracket)
  key(KeyLeftBracket)
  run(1)
  doAssert opts[tBrush].tip.diameter == size0 - 10
  key(KeyLeftBracket, {ShiftPressed})
  run(1)
  doAssert opts[tBrush].tip.hardness == 75
  key(KeyPeriod)
  run(1)
  doAssert opts[tBrush].preset == presets[presetIndex("Hard Round") + 1].name
  # the size: from 1 to 5000 by the slider's (log) scale and the steps
  for s in [1, 7, 50, 300, 2500, 5000]: doAssert abs(posToSize(sizeToPos(s)) - s) <= max(1, s div 100), $s
  doAssert stepSize(5000, true) == 5000 and stepSize(1, false) == 1 and stepSize(9, true) == 10
  doAssert stepSize(100, true) == 125 and stepSize(1000, false) == 900
  # Brush Settings: a section switched off keeps its values, back when on
  applyPreset(presets[presetIndex("Spatter")])
  doAssert sectionOn(tBrush, bsScatter)
  let sc = opts[tBrush].dyn.scatter
  setSection(tBrush, bsScatter, false)
  doAssert not sectionOn(tBrush, bsScatter) and opts[tBrush].dyn.scatter == 0
  setSection(tBrush, bsScatter, true)
  doAssert opts[tBrush].dyn.scatter == sc
  setSection(tBrush, bsWet, true)
  doAssert opts[tBrush].wet
  # the palettes and the picker drawn: every page of Brush Settings
  showPanel("brushsettings")
  doAssert panelShown("brushsettings")
  for s in BrushSection:
    settingsPage = s
    run(2)
  showPanel("brushes")
  doAssert panelShown("brushes") and not panelShown("brushsettings"), "one of a group shown"
  for i in 0 .. 20: run(1)                  # (the strokes are made a few a frame)
  # a stroke with every built-in brush, on the image
  let d = cur()
  for p in presets:
    applyPreset(p)
    opts[tBrush].tip.diameter = min(opts[tBrush].tip.diameter, 30)
    d.beginStep("Paint")
    var st = d.beginStroke(paintOpts(tBrush, d), tipFor(tBrush), 10, 30)
    st.startStroke()
    for i in 1 .. 10: st.strokeTo(10 + i.float * 6, 30 + (i mod 3).float * 4)
    st.endStroke()
    d.endStep()
  # a new preset from the brush, kept in Brushes.json and read back
  let before = presets.len
  presetDlg = (true, 0, "My Brush", -1)
  run(1)
  var p = presetOfTool(tBrush, "My Brush")
  presets.add p
  savePresets()
  presets = @[]
  loadPresets()
  doAssert presets.len == before + 1 and presets[^1].name == "My Brush"
  presetDlg.open = false
  presets.setLen(before)
  savePresets()
  run(1)

block docTabs:
  # documents open as tabs; one floats in a window, then they are tabs again
  docs.setLen(0)                       # (closed without asking)
  active = nil
  tabCur = nil
  run(3)
  prefs.docTabs = true
  addDoc(sample(50, 40))
  addDoc(sample(60, 30))
  run(3)
  doAssert not docs[0].floating and not docs[1].floating
  doAssert tabCur == docs[1] and active == docs[1]
  runCommand("Next Document")
  run(2)
  doAssert active == docs[0] and tabCur == docs[0]
  # tabs only: in all the room between the toolbar and the panels
  doAssert tabWin.r == tabArea()
  let ta = tabArea()
  doAssert ta.y == 0 and ta.h == mdiAreaRect("ws").h
  doAssert ta.x + ta.w <= docsRight
  # windows of their own (MDI): every one; and tabs again
  runCommand("Floating Windows (MDI)")
  run(3)
  doAssert not prefs.docTabs
  doAssert docs[0].floating and docs[1].floating, $docs[0].floating & " " & $docs[1].floating
  doAssert active == docs[0], $docs.find(active)
  addDoc(sample(30, 30))
  doAssert docs[^1].floating
  runCommand("Tabbed Documents")
  run(3)
  doAssert prefs.docTabs
  for o in docs: doAssert not o.floating
  # one made a window another way (a session reopened): a tab again
  docs[0].floating = true
  run(2)
  doAssert not docs[0].floating
  # the status bar: what it shows, and a zoom typed
  for si in StatusInfo:
    statusInfo = si
    doAssert statusInfoText(cur()).len > 0
    run(1)
  statusInfo = siSizes
  doAssert zoomFromPercent(100) == 1 and zoomFromPercent(200) == 2 and zoomFromPercent(50) == -2
  doAssert zoomFromPercent(33) == -3 and zoomFromPercent(1600) == 16 and zoomFromPercent(12.5) == -8
  prefs.docTabs = true

block preferences:
  # every page drawn; OK keeps them, a new start reads them back
  startPrefs(0)
  for p in PrefPage:
    prefPage = ord(p)
    run(2)
  prefs.history = 37
  prefs.recent = 4
  viewPrefs.rulerUnit = ruCentimeters
  viewPrefs.checkerSize = ckLarge
  applyPrefs()
  savePrefs()
  prefsOpen = false
  doAssert maxHistoryStates == 37
  prefs = DefaultPrefs
  viewPrefs.rulerUnit = ruPixels
  loadPrefs()
  doAssert prefs.history == 37 and prefs.recent == 4
  doAssert viewPrefs.rulerUnit == ruCentimeters and viewPrefs.checkerSize == ckLarge
  # units on the rulers and in the status bar
  doAssert inUnits(300, ruInches, 300, 1000) == "1.00 in"
  doAssert inUnits(118.11, ruCentimeters, 300, 1000) == "1.00 cm"
  doAssert inUnits(50, ruPercent, 72, 200) == "25 %"
  # recent files: opened and saved ones first
  let f1 = home / "r1.png"
  let f2 = home / "r2.png"
  addDoc(sample(20, 20))
  active.writeDoc(f1)
  addDoc(sample(20, 20))
  active.writeDoc(f2)
  let rec = recentFiles(loadSettings(AppName))
  doAssert rec.len >= 2 and rec[0] == f2 and rec[1] == f1
  openFile(f1)
  doAssert recentFiles(loadSettings(AppName))[0] == f1
  # smart quotes
  prefs.smartQuotes = true
  doAssert smartQuote("\"Hi\"", "") == "“Hi”" and smartQuote("it's", "") == "it’s"
  prefs.smartQuotes = false
  doAssert smartQuote("\"x\"", "") == "\"x\""
  # reset at the next start: the defaults come back
  prefs.resetOnQuit = true
  savePrefs()
  loadPrefs()
  doAssert prefs.history == DefaultPrefs.history and viewPrefs.rulerUnit == ruPixels
  # tablets: desktop sizes unless asked
  setControlSizes(csTouch)
  run(2)
  doAssert fingers()
  setControlSizes(csDesktop)
  run(2)
  doAssert not fingers()
  setControlSizes(csAuto)
  run(2)

block presetFiles:
  # Photoshop's preset files, imported
  let n0 = swatches.len
  writeFile(home / "s.aco", writeAco([("A", 0xFF102030'u32), ("B", 0xFF405060'u32)]))
  importPresets(home / "s.aco")
  doAssert swatches.len == n0 + 2 and swatches[^1] == 0xFF405060'u32
  presetReplace = true
  writeFile(home / "s.ase", writeAse([("C", 0xFF00FF00'u32)]))
  importPresets(home / "s.ase")
  doAssert swatches == @[0xFF00FF00'u32]
  presetReplace = false
  writeFile(home / "c.acv", writeAcv([@[(0, 0), (128, 160), (255, 255)]]))
  importPresets(home / "c.acv")
  doAssert cv[0] == @[(0, 0), (128, 160), (255, 255)]
  writeFile(home / "l.alv", writeAlv([LevelsRecord(inLo: 12, inHi: 240, outHi: 255, gamma: 1.5)]))
  importPresets(home / "l.alv")
  doAssert lv[0].inLo == 12 and abs(lv[0].gamma - 1.5) < 0.01
  # saved, and read back
  presetFor = pfCurves
  exportPresets(home / "c2.acv")
  doAssert readAcv(readFile(home / "c2.acv"))[0] == cv[0]
  presetFor = pfSwatches
  exportPresets(home / "s2.aco")
  doAssert readAco(readFile(home / "s2.aco")).len == 1
  # the Preset dialogs' file pickers come up
  startPresetFile(pfGradients)
  run(2)
  doAssert presetPick
  presetPick = false
  run(1)
  initSwatches()

block shortcuts:
  # Photoshop's keys by default; 1994's when asked; the user's own over them
  addDoc(sample(40, 30))
  run(2)
  prefs.keySet = 0
  applyKeySet()
  doAssert keymap.keyFor("Free Transform") == "Ctrl+T" and keymap.keyFor("Color Balance...") == "Ctrl+B"
  doAssert keymap.keyFor("Search...") == "Ctrl+F" and keymap.keyFor("Last Filter") == "Ctrl+Alt+F"
  doAssert keymap.keyFor("Hide Layers") == "Ctrl+," and keymap.keyFor("Toggle Last State") == "Ctrl+Alt+Z"
  doAssert keymap.keyFor("Save As...") == "Ctrl+Shift+S" and keymap.keyFor("Feather...") == "Shift+F6"
  prefs.keySet = 1
  applyKeySet()
  doAssert keymap.keyFor("Threshold...") == "Ctrl+T" and keymap.keyFor("Brightness/Contrast...") == "Ctrl+B"
  prefs.keySet = 0
  applyKeySet()
  # a key of one's own: pressed, its command runs; another command loses it
  keymap.setKey("Invert", "Ctrl+Alt+Shift+I")
  doAssert keymap.keyFor("Invert") == "Ctrl+Alt+Shift+I"
  keymap.setKey("Desaturate", "Ctrl+Alt+Shift+I")
  doAssert keymap.keyFor("Desaturate") == "Ctrl+Alt+Shift+I" and keymap.keyFor("Invert") == ""
  let d = cur()
  let before = d.layer.px[15 * 40 + 30]
  key(KeyI, {CtrlPressed, AltPressed, ShiftPressed})
  run(2)
  doAssert d.layer.px[15 * 40 + 30] != before, "the user's key ran its command"
  # kept and read back
  var st: Settings
  storeKeymap(st, keymap)
  var km2 = Keymap(defaults: keymap.defaults)
  restoreKeymap(st, km2)
  doAssert km2.keyFor("Desaturate") == "Ctrl+Alt+Shift+I" and km2.keyFor("Invert") == ""
  keymap.custom.setLen(0)
  applyKeySet()
  keysOpen = true
  run(2)
  keysOpen = false
  run(1)

block recoveryAndWorkspace:
  # a changed document kept aside after the autosave time; after a run that
  # ended badly, offered back at the start
  prefs.autosave = 1
  let d = sample(30, 20)
  addDoc(d)
  d.layer.px[0] = 0xFF123456'u32
  inc d.layer.ver
  inc d.ver
  d.modified = true
  lastAutosave = ui.now - 61_000       # (a minute gone)
  run(1)
  var frames = 0
  while (saving() or recoverySaving.len > 0) and frames < 2000:
    run(1)
    inc frames
    os.sleep(1)
  let f = active.recovery
  doAssert f.len > 0 and fileExists(f) and fileExists(f & ".txt"), f
  doAssert d.modified, "a recovery copy does not count as saved"
  # (as if left by another run that crashed)
  let other = recoveryDir / "doc-1-test.rpd"
  moveFile(f, other)
  moveFile(f & ".txt", other & ".txt")
  active.recovery = ""
  findRecovery()
  doAssert recoverOpen and recoverFound.len == 1 and recoverFound[0].name == "sample"
  let n = docs.len
  run(2)
  key(KeyEnter)
  run(2)
  doAssert not recoverOpen and docs.len == n + 1 and docs[^1].doc.name == "sample (recovered)"
  doAssert docs[^1].doc.layers[0].px[0] == 0xFF123456'u32 and docs[^1].doc.modified
  doAssert not fileExists(other)
  # saved: its copy goes
  docs[^1].recovery = recoveryDir / "doc-2-x.rpd"
  writeFile(docs[^1].recovery, "x")
  docs[^1].writeDoc(home / "back.png")
  doAssert not fileExists(recoveryDir / "doc-2-x.rpd")
  prefs.autosave = 0
  # the panels: kept as they are, and put back
  dock.closePanel("layers")
  doAssert not panelShown("layers")
  saveWorkspace("saved")
  showPanel("layers")
  doAssert panelShown("layers")
  doAssert loadWorkspace("saved")
  doAssert "layers" notin dock.keys and not panelShown("layers")
  showPanel("layers")
  doAssert panelShown("layers"), "back where it was"
  runCommand("Reset Workspace")
  run(2)
  doAssert palettesPlaced and panelShown("layers") and panelShown("color")


block photoshopHabits:
  # keys held for a moment: Space the Hand, Ctrl the Move tool, Alt the
  # Eyedropper; let go, the tool before
  prefs.keySet = 0
  docs.setLen(0)                       # (closed without asking)
  active = nil
  tabCur = nil
  run(3)
  let d = sample(60, 40)
  addDoc(d)
  run(3)
  selectTool(tBrush)
  queue.add Event(kind: KeyDownEvent, key: KeySpace)
  run(2)
  doAssert tool == tHand, "Space: the Hand"
  queue.add Event(kind: KeyUpEvent, key: KeySpace)
  run(2)
  doAssert tool == tBrush, "Space let go: the brush again"
  ui.mods = {CtrlPressed}
  run(1)
  doAssert tool == tMove, "Ctrl: the Move tool"
  ui.mods = {AltPressed}
  run(1)
  doAssert tool == tEyedropper, "Alt with a brush: the Eyedropper"
  ui.mods = {}
  run(1)
  doAssert tool == tBrush
  # Alt+drag with the Move tool: a copy of the layer moves
  discard d.addLayer("top")
  d.markAll()
  let n = d.layers.len
  selectTool(tMove)
  # (the middle of the image, the palettes out of the way)
  palettesHidden = true
  run(2)
  let va = active.view.view
  let (sx, sy) = (va.x + va.w div 2, va.y + va.h div 2)
  queue.add Event(kind: MouseMoveEvent, x: sx, y: sy)
  queue.add Event(kind: MouseDownEvent, x: sx, y: sy, button: LeftButton, clicks: 1, mods: {AltPressed}, hasMods: true)
  run(1)
  queue.add Event(kind: MouseMoveEvent, x: sx + 10, y: sy + 5, mods: {AltPressed}, hasMods: true)
  run(1)
  queue.add Event(kind: MouseUpEvent, x: sx + 10, y: sy + 5, button: LeftButton, mods: {AltPressed}, hasMods: true)
  run(2)
  ui.mods = {}
  palettesHidden = false
  doAssert d.layers.len == n + 1, "Alt+drag: a copy"
  # layers: the one above and below; Stamp Visible; fills; Reselect
  d.cur = 0
  runCommand("Select Layer Above")
  doAssert d.cur == 1
  runCommand("Select Layer Below")
  doAssert d.cur == 0
  let m = d.layers.len
  runCommand("Stamp Visible")
  doAssert d.layers.len == m + 1 and d.cur == d.layers.high
  fg = 0xFF336699'u32
  runCommand("Fill with Foreground Color")
  doAssert d.current.px[0] == 0xFF336699'u32
  d.setSelection(d.rectMask(rect(5, 5, 10, 10)))
  runCommand("None")
  doAssert not d.hasSelection
  runCommand("Reselect")
  doAssert d.hasSelection and d.sel[7 * 60 + 7] == 255
  # the tabs fill the documents' room
  prefs.docTabs = true
  addDoc(sample(30, 20))
  run(2)
  doAssert tabWin.r == tabArea()

block colorModesAndLibraries:
  # New in CMYK, Lab, Grayscale, Bitmap; 16 bits
  for (k, m) in [(3, cmCMYK), (4, cmLab), (1, cmGray), (0, cmBitmap)]:
    let d = newUntitled(40, 30, white, 72, newModeOf(k), "m" & $k, 16)
    doAssert d.mode == m, $m
    doAssert (d.depth == 16) == (m != cmBitmap) or m == cmBitmap
  # a color book imported: in Color Libraries, kept for the next start
  var book = ColorBook(title: "My Inks", prefix: "MY ", model: bkCmyk, pageSize: 5, spot: true)
  book.colors.add BookColor(name: "Sunset", code: "SUN", cmyk: [0, 60, 100, 0])
  writeFile(home / "my.acb", writeAcb(book))
  presetReplace = false
  importPresets(home / "my.acb")
  doAssert colorBooks.len >= 5 and colorBooks[^1].title == "My Inks"
  doAssert fileExists(dataDir(AppName) / "Color Books" / "my.acb")
  # the picker: the libraries in its place, a color taken from them
  var c = 0xFF000000'u32
  var open = true
  var st: ColorPickerState
  discard colorPickerDialog(open, "Color", c, st)
  st.libraries = true
  st.book = colorBooks.high
  run(1)
  showFgPicker = true
  run(2)
  showFgPicker = false
  colorSettingsOpen = true
  run(2)
  colorSettingsOpen = false
  run(1)

block transformControls:
  # Photoshop's Move tool: Auto-Select picks the layer clicked; a handle
  # of the blue box sizes it; type stays type (its letters get bigger)
  docs.setLen(0)
  active = nil
  tabCur = nil
  run(2)
  let d = newDoc(200, 150, white, name = "xf")
  addDoc(d)
  run(2)
  let red = d.addLayer("red")
  for y in 20 ..< 60:
    for x in 30 ..< 90: red.px[y * 200 + x] = 0xFFFF0000'u32
  inc red.ver
  d.markAll()
  d.cur = 0
  doAssert d.layerAt(50, 40) == 1 and d.layerAt(150, 120) == 0
  doAssert d.layerBox(red) == rect(30, 20, 60, 40)
  # a type layer, sized by its box: bigger letters, still text
  let L = d.addTextLayer(newText("Hi", CharStyle(family: "", size: 20, color: 0xFF000000'u32, hScale: 1,
                                                 vScale: 1), 40, 100))
  run(2)
  d.cur = d.layers.find(L)
  let b0 = d.layerBox(L)
  doAssert b0.w > 0
  startTransform(xkScale)
  doAssert xf.on and xfText.on
  xf.quad = quadOf(rect(b0.x, b0.y, b0.w * 2, b0.h * 2))
  xfApply()
  finishTransform(true)
  doAssert L.isText and abs(L.text.spans[0].style.size - 40) < 2, $L.text.spans[0].style.size
  doAssert d.layerBox(L).w > b0.w * 3 div 2
  # Ctrl+T on pixels, a side's middle dragged: wider only
  d.cur = d.layers.find(red)
  startTransform(xkScale)
  doAssert xf.r == rect(30, 20, 60, 40), "the layer's own box"
  let q0 = xf.quad
  xf.quad = q0
  xf.quad[1][0] += 30
  xf.quad[2][0] += 30
  xfApply()
  finishTransform(true)
  doAssert d.layerBox(red).w > 80
  # the Move tool pressed away from the box (no handle there): just a move
  tool = tMove
  moveAutoSelect = false
  let (sx, sy) = active.view.toScreen(d, 195.0, 145.0)
  ui.mx = sx
  ui.my = sy
  pressOn(active, PhotoEvent(over: true, x: 195, y: 145, pressed: true, down: true, clicks: 1))
  doAssert not xf.on
  drag.on = false
  moveAutoSelect = true

block moveToolLikePhotoshop:
  # the box's handles take the mouse from a few pixels away (and light up),
  # the pointer says what a drag does; a double-click on type edits it (then
  # the Move tool again); Smart Guides line a move up with the rest; the
  # right click lists the layers there; Auto-Select: Group
  docs.setLen(0)
  active = nil
  tabCur = nil
  run(2)
  let d = newDoc(300, 200, white, name = "move")
  addDoc(d)
  run(2)
  let a = d.addLayer("A")
  for y in 40 ..< 100:
    for x in 40 ..< 100: a.px[y * 300 + x] = 0xFFFF0000'u32
  inc a.ver
  let b = d.addLayer("B")
  for y in 120 ..< 160:
    for x in 150 ..< 230: b.px[y * 300 + x] = 0xFF0000FF'u32
  inc b.ver
  d.markAll()
  run(2)
  let dw = active
  let q = quadOf(rect(40, 40, 60, 60))
  let (cx0, cy0) = dw.view.toScreen(d, 40.0, 40.0)
  # a corner from a few pixels away, a side anywhere along it, the inside, where it turns
  doAssert dw.boxHit(q, cx0 - dp(6), cy0 - dp(5)) == 0
  let q2 = quadOf(rect(20, 20, 260, 160))
  let (mx, my) = dw.view.toScreen(d, 85.0, 20.0)    # (a side, far from its handles)
  doAssert dw.boxHit(q2, mx, my + 2) == 6, $dw.boxHit(q2, mx, my + 2)
  let (rx, ry) = dw.view.toScreen(d, 280.0, 60.0)
  doAssert dw.boxHit(q2, rx - 2, ry) == 7
  let (ix, iy) = dw.view.toScreen(d, 60.0, 70.0)
  doAssert dw.boxHit(q, ix, iy) == 4
  doAssert dw.boxHit(q, cx0 - dp(18), cy0 - dp(18)) == 5
  dw.boxCursor(q, 0)
  doAssert ui.cursor == curSizeNWSE
  dw.boxCursor(q, 1)
  doAssert ui.cursor == curSizeNESW
  dw.boxCursor(q, 7)
  doAssert ui.cursor == curSizeWE
  dw.boxCursor(q, 4)
  doAssert ui.cursor == curMove
  # the right click's list: the layers there, the top first
  doAssert d.layersUnder(50, 50) == @[d.layers.find(a), 0], $d.layersUnder(50, 50)
  doAssert d.layersUnder(160, 130) == @[d.layers.find(b), 0]
  # Smart Guides: A dragged near B's left edge snaps to it (and Ctrl held: free)
  d.cur = d.layers.find(a)
  smartGuidesOn = true
  snapOn = true
  dw.smartBegin()
  doAssert sg.on and sg.box == (40.0, 40.0, 100.0, 100.0), $sg.box
  var fx = 48.0                     # (A's right edge to 148: B's left edge is 150)
  var fy = 0.0
  dw.smartSnap(fx, fy)
  doAssert abs(fx - 50.0) < 1e-9, $fx
  doAssert sg.hitX.len > 0
  ui.mods = {CtrlPressed}
  fx = 48.0
  dw.smartSnap(fx, fy)
  doAssert abs(fx - 48.0) < 1e-9, "Ctrl held: no snapping"
  ui.mods = {}
  # the image's middle too: A's middle (70) to 150
  fx = 79.0
  fy = 0.0
  dw.smartSnap(fx, fy)
  doAssert abs(fx - 80.0) < 1e-9, $fx
  sg.on = false
  # Auto-Select: Group picks the outermost group
  let g = d.groupLayers(@[d.layers.find(b)], "G")
  doAssert g != nil
  let bi = d.layers.find(b)
  moveAutoGroup = false
  doAssert d.autoPicked(bi) == bi
  moveAutoGroup = true
  doAssert d.autoPicked(bi) == d.layers.find(g)
  moveAutoGroup = false
  # a double-click on type with the Move tool: the Type tool, editing; done: the Move tool again
  let t = d.addTextLayer(newText("Hello", CharStyle(family: "", size: 24, color: 0xFF000000'u32,
                                                     hScale: 1, vScale: 1), 20, 180))
  run(2)
  let tb = d.layerBox(t)
  doAssert tb.w > 0
  tool = tMove
  moveKind = 0
  let px = (tb.x + tb.w div 2).float
  let py = (tb.y + tb.h div 2).float
  let (sx, sy) = dw.view.toScreen(d, px, py)
  ui.mx = sx
  ui.my = sy
  pressOn(dw, PhotoEvent(over: true, x: px, y: py, pressed: true, down: true, clicks: 2))
  doAssert tool == tType and te.on and te.layer == t, "editing the text"
  doAssert typeBackToMove
  commitType()
  run(2)
  doAssert tool == tMove and not te.on, "the Move tool again"
  drag = Drag()

block selectionAndAdjustmentBrushes:
  # the Selection Brush paints the selection (Alt takes away); the
  # Adjustment Brush paints an adjustment layer's mask (a new layer the first
  # time, the same one after), the amount changes it afterwards
  docs.setLen(0)
  active = nil
  tabCur = nil
  run(2)
  let d = newDoc(200, 150, 0xFF808080'u32, name = "brushes")
  addDoc(d)
  run(2)
  let dw = active
  tool = tWand
  wandMode = 3
  quickSize = 20
  selBrushHard = 100
  selBrushSub = false
  pressOn(dw, PhotoEvent(over: true, x: 50, y: 50, pressed: true, down: true, clicks: 1))
  drag.on = true
  dragOn(PhotoEvent(over: true, x: 120, y: 50, down: true))
  releaseOn(PhotoEvent(over: true, x: 120, y: 50, released: true))
  doAssert d.hasSelection
  doAssert d.sel[50 * 200 + 50] == 255 and d.sel[50 * 200 + 85] == 255 and d.sel[50 * 200 + 120] == 255
  doAssert d.sel[10 * 200 + 10] == 0 and d.sel[100 * 200 + 85] == 0
  # Alt: taken away
  pressOn(dw, PhotoEvent(over: true, x: 85, y: 50, pressed: true, down: true, clicks: 1, alt: true))
  releaseOn(PhotoEvent(over: true, x: 85, y: 50, released: true, alt: true))
  doAssert d.sel[50 * 200 + 85] == 0 and d.sel[50 * 200 + 50] == 255
  doAssert dw.view.scaleOf > 0
  dw.drawSelOverlay()                       # (the overlay: made from the selection)
  doAssert selOverlay.b != nil and selOverlay.ver == d.selVer
  d.selectNone()
  # the Adjustment Brush
  tool = tBrush
  brushTool = 3
  adjBrushKind = adjBrushPresets.find("Brightness")
  adjBrushAmount = 60
  adjBrushSub = false
  let n0 = d.layers.len
  pressOn(dw, PhotoEvent(over: true, x: 40, y: 40, pressed: true, down: true, clicks: 1))
  drag.on = true
  dragOn(PhotoEvent(over: true, x: 80, y: 40, down: true))
  releaseOn(PhotoEvent(over: true, x: 80, y: 40, released: true))
  doAssert d.layers.len == n0 + 1, "a new adjustment layer"
  let L = d.current
  doAssert L.adjust.kind == "Brightness/Contrast" and L.adjust.data == "brush:Brightness"
  doAssert (L.px[40 * 200 + 60] and 0xFF) > 128, "painted white where the brush went"
  doAssert (L.px[120 * 200 + 150] and 0xFF) == 0, "black elsewhere: nothing changed there"
  d.updateComposite()
  doAssert rOf(d.compPtr[40 * 200 + 60]) > 0x90, "lighter where painted"
  doAssert rOf(d.compPtr[120 * 200 + 150]) == 0x80, "as it was elsewhere"
  # the next stroke: the same layer
  pressOn(dw, PhotoEvent(over: true, x: 40, y: 100, pressed: true, down: true, clicks: 1))
  releaseOn(PhotoEvent(over: true, x: 40, y: 100, released: true))
  doAssert d.layers.len == n0 + 1
  # the amount afterwards
  adjBrushAmount = -60
  adjBrushChanged()
  doAssert L.adjust.args[0] < 0
  # another adjustment: a layer of its own
  adjBrushKind = adjBrushPresets.find("Saturation")
  pressOn(dw, PhotoEvent(over: true, x: 150, y: 100, pressed: true, down: true, clicks: 1))
  releaseOn(PhotoEvent(over: true, x: 150, y: 100, released: true))
  doAssert d.layers.len == n0 + 2 and d.current.adjust.kind == "Hue/Saturation"
  brushTool = 0
  tool = tMove
  drag = Drag()

block contentAwareTracing:
  # point at an edge: it lights up; a click: a path along it (closed round a
  # disc); Shift+click: on from where it ended
  docs.setLen(0)
  active = nil
  tabCur = nil
  run(2)
  let d = newDoc(240, 180, white, name = "trace")
  addDoc(d)
  run(2)
  let L = d.addLayer("disc")
  for y in 0 ..< 180:
    for x in 0 ..< 240:
      if hypot(x.float + 0.5 - 120, y.float + 0.5 - 90) <= 50: L.px[y * 240 + x] = 0xFF2040C0'u32
  inc L.ver
  d.markAll()
  run(2)
  let dw = active
  tool = tPen
  penMode = 8
  let m = d.traceEdges()
  doAssert m.chains.len >= 1
  doAssert m.chainAt(170, 90, 6) >= 0, "the disc's edge"
  doAssert m.chainAt(120, 90, 6) < 0, "nothing in its middle"
  let paths0 = d.paths.len
  tracePress(dw, PhotoEvent(over: true, x: 170, y: 90, pressed: true, down: true, clicks: 1))
  doAssert d.paths.len == paths0 + 1 or (d.curPath >= 0 and d.paths[d.curPath].subs.len > 0)
  let sub = d.paths[d.curPath].subs[^1]
  doAssert sub.closed and sub.pts.len >= 4, $sub.pts.len
  # the path runs round the disc: its points 50 pixels from the middle
  for p in sub.pts:
    doAssert abs(hypot(p.p[0] - 120, p.p[1] - 90) - 50) < 3, $p.p
  # the same picture: the edges are not found again
  let again = d.traceEdges()
  doAssert again == m
  # a click where there is no edge: nothing
  let n = d.paths[d.curPath].subs.len
  tracePress(dw, PhotoEvent(over: true, x: 120, y: 90, pressed: true, down: true, clicks: 1))
  doAssert d.paths[d.curPath].subs.len == n
  penMode = 1
  tool = tMove

block toolsOnTheImageOnly:
  # off the image (the gray round it) the tools wait; the Hand works anywhere
  docs.setLen(0)
  active = nil
  tabCur = nil
  run(2)
  let d = newDoc(120, 80, white, name = "off")
  addDoc(d)
  run(2)
  let dw = active
  tool = tMarquee
  marqueeShape = 0
  pressOn(dw, PhotoEvent(over: true, x: -20, y: 30, pressed: true, down: true, clicks: 1))
  doAssert not drag.on, "no marquee from outside"
  tool = tBrush
  brushTool = 0
  let steps = d.undoSteps.len
  pressOn(dw, PhotoEvent(over: true, x: 140, y: 30, pressed: true, down: true, clicks: 1))
  doAssert not drag.on and d.undoSteps.len == steps, "no stroke from outside"
  pressOn(dw, PhotoEvent(over: true, x: 60, y: 40, pressed: true, down: true, clicks: 1))
  doAssert drag.on, "on the image: it paints"
  releaseOn(PhotoEvent(over: true, x: 60, y: 40, released: true))
  tool = tHand
  pressOn(dw, PhotoEvent(over: true, x: -20, y: -10, pressed: true, down: true, clicks: 1))
  doAssert drag.on, "the Hand works anywhere"
  drag = Drag()
  tool = tMove

block groupWhenSeveral:
  # several layers picked: Group (a folder of their own), Ungroup, Merge --
  # in the bar under the image, the Layers panel's menu, the right click
  docs.setLen(0)
  active = nil
  tabCur = nil
  run(2)
  let d = newDoc(100, 80, white, name = "groups")
  addDoc(d)
  run(2)
  let dw = active
  let a = d.addLayer("a")
  let b = d.addLayer("b")
  for i in 0 ..< 100 * 20: a.px[i] = 0xFFFF0000'u32
  for i in 100 * 40 ..< 100 * 60: b.px[i] = 0xFF00FF00'u32
  inc a.ver
  inc b.ver
  d.markAll()
  d.cur = d.layers.find(b)
  a.picked = true
  doAssert d.pickedLayers.len == 2
  var labels: seq[string]
  for (l, _) in taskBarItems(dw): labels.add l
  doAssert "Group" in labels and "Merge" in labels, $labels
  runCommand("Group Layers")
  let g = d.current
  doAssert g.group and d.blockStart(d.cur) <= d.layers.find(a) and d.layers.find(b) < d.cur
  labels.setLen(0)
  for (l, _) in taskBarItems(dw): labels.add l
  doAssert "Ungroup" in labels, $labels
  runCommand("Ungroup Layers")
  doAssert not d.current.group and g notin d.layers
  # Merge: the two made one
  let n = d.layers.len
  d.cur = d.layers.find(b)
  d.clearPicks()
  a.picked = true
  runCommand("Merge Layers")
  doAssert d.layers.len == n - 1, $d.layers.len
  d.updateComposite()
  doAssert d.compPtr[10 * 100 + 10] == 0xFFFF0000'u32 and d.compPtr[50 * 100 + 10] == 0xFF00FF00'u32

block typeMovedOffTheImage:
  # type moved off the image is still there: its box shows round it (on the
  # gray), a press there drags it back; Properties gives its X and Y
  docs.setLen(0)
  active = nil
  tabCur = nil
  run(2)
  let d = newDoc(200, 150, white, name = "off")
  addDoc(d)
  run(2)
  let dw = active
  let t = d.addTextLayer(newText("Hello", CharStyle(family: "", size: 24, color: 0xFF000000'u32,
                                                     hScale: 1, vScale: 1), 20, 100))
  run(2)
  let b0 = d.layerBox(t)
  doAssert b0.w > 0 and b0.intersects(d.bounds)
  d.beginStep("Move")
  d.touchLayers()
  d.setText(t, t.text.moved(-300, 0))             # (all of it off the image, at the left)
  d.endStep()
  run(2)
  let b1 = d.layerBox(t)
  doAssert b1.w == b0.w and b1.x == b0.x - 300, $b1 & " " & $b0
  doAssert not b1.intersects(d.bounds)
  # a press on its box (off the image) with the Move tool: it is picked and dragged back
  d.cur = 0
  tool = tMove
  moveKind = 0
  let cx = (b1.x + b1.w div 2).float
  let cy = (b1.y + b1.h div 2).float
  let (sx, sy) = dw.view.toScreen(d, cx, cy)
  ui.mx = sx
  ui.my = sy
  pressOn(dw, PhotoEvent(over: true, x: cx, y: cy, pressed: true, down: true, clicks: 1))
  doAssert drag.on and d.current == t, "picked, off the image"
  dragOn(PhotoEvent(over: true, x: cx + 300, y: cy, down: true))
  releaseOn(PhotoEvent(over: true, x: cx + 300, y: cy, released: true))
  run(2)
  doAssert d.layerBox(t).intersects(d.bounds), "back on the image: " & $d.layerBox(t)
  drag = Drag()

block photoshopCC:
  # today's Photoshop, for its tutorials: its menu paths, Search, its newer
  # commands and panels, the Contextual Task Bar, Free Transform's keys
  docs.setLen(0)
  active = nil
  tabCur = nil
  prefs.keySet = 0
  applyKeySet()
  run(2)
  let idx = searchIndex()
  var paths: seq[string]
  for e in idx: paths.add e.path & " > " & e.label
  for want in ["Image > Adjustments > Curves...", "Image > Mode > Grayscale", "Edit > Free Transform",
               "Edit > Transform > Flip Horizontal", "Image > Image Rotation > 90° Clockwise",
               "Layer > New > Layer...", "Select > Modify > Feather...", "Filter > Blur > Gaussian Blur...",
               "Filter > Camera Raw Filter...", "View > Show > Grid", "Window > Histogram",
               "Window > Layer Comps", "Type > Panels > Glyphs Panel", "Select > Deselect"]:
    doAssert want in paths, want
  doAssert searchScore("Curves...", "Image > Adjustments", "curv") == 4
  # Search: typed, Enter runs the first match
  let d = newDoc(120, 90, white, name = "cc")
  addDoc(d)
  run(2)
  runCommand("Search...")
  run(2)
  doAssert searchDlg.open
  searchDlg.q = "gaussian"
  searchDlg.shown.setLen(0)
  run(2)
  doAssert searchDlg.shown.len > 0 and searchIndex()[searchDlg.shown[0]].label == "Gaussian Blur..."
  searchDlg.open = false
  run(1)
  # a layer turned 90° (Edit > Transform), and Again turns it once more
  let L = d.addLayer("bar")
  for y in 40 ..< 50:
    for x in 20 ..< 100: L.px[y * 120 + x] = 0xFF0000FF'u32
  inc L.ver
  d.markAll()
  d.cur = d.layers.find(L)
  runCommand("Rotate Layer 90° CW")
  let b1 = d.layerBox(L)
  doAssert b1.h > b1.w and b1.h >= 75, $b1
  doAssert lastXf.set
  runCommand("Transform Again")
  let b2 = d.layerBox(L)
  doAssert b2.w > b2.h, $b2
  # Hide Layers (Ctrl+,), All Layers, Deselect Layers
  runCommand("Hide Layers")
  doAssert not L.visible
  runCommand("Undo")
  doAssert L.visible
  runCommand("All Layers")
  doAssert L.picked
  runCommand("Deselect Layers")
  doAssert not L.picked
  # Toggle Last State: undo, then back
  runCommand("Rotate Layer 90° CW")
  let before = d.layerBox(L)
  runCommand("Toggle Last State")
  let undone = d.layerBox(L)
  doAssert undone != before
  runCommand("Toggle Last State")
  doAssert d.layerBox(L) == before
  # Free Transform: a corner keeps the proportions (Shift: free), Ctrl moves it alone
  d.cur = d.layers.find(L)
  runCommand("Free Transform")
  doAssert xf.on
  let q0 = xf.quad
  let (cx, cy) = active.view.toScreen(d, q0[2][0], q0[2][1])
  ui.mx = cx
  ui.my = cy
  active.transformMouse(PhotoEvent(over: true, x: q0[2][0], y: q0[2][1], pressed: true, down: true, clicks: 1))
  if xf.grab == 2:
    active.transformMouse(PhotoEvent(over: true, x: q0[2][0] + 20, y: q0[2][1], down: true, moved: true))
    let w0 = q0[1][0] - q0[0][0]
    let h0 = q0[3][1] - q0[0][1]
    let w1 = xf.quad[1][0] - xf.quad[0][0]
    let h1 = xf.quad[3][1] - xf.quad[0][1]
    doAssert abs(w1 / w0 - h1 / h0) < 0.05, "proportional: " & $(w0, h0, w1, h1)
  finishTransform(false)
  # every new panel draws (and Window > ... shows it)
  for (cmd, key) in [("Adjustments", "adjustments"), ("Histogram", "histogram"), ("Gradients", "gradients"),
                     ("Patterns", "patterns"), ("Styles", "styles"), ("Shapes", "shapes"),
                     ("Tool Presets", "toolpresets"), ("Layer Comps", "layercomps"), ("Clone Source", "clonesource"),
                     ("Glyphs", "glyphs")]:
    if panelShown(key): runCommand(cmd)     # (shown: Window hides it first)
    doAssert not panelShown(key), cmd
    runCommand(cmd)
    doAssert panelShown(key), cmd
    run(3)
  # a style from Styles, a layer comp kept and put back
  d.cur = d.layers.find(L)
  let presets = stylePresets()
  doAssert presets.len >= 12
  d.stepOnce("Apply Style", proc () =
    L.fx = presets[1].fx
    d.markAll())
  doAssert L.hasStyle
  d.comps.add d.captureComp("A")
  L.visible = false
  d.applyComp(d.comps[0])
  doAssert L.visible
  # (a comp keeps where the layers were, and is kept in the .rpd)
  let b0 = d.contentBounds(L)
  d.shiftLayers(@[L], 15, 7)
  doAssert d.contentBounds(L).x == b0.x + 15
  d.applyComp(d.comps[0])
  doAssert d.contentBounds(L).x == b0.x and d.contentBounds(L).y == b0.y, "back where it was"
  d.saveRpd(home / "comps.rpd")
  let back = loadRpd(home / "comps.rpd")
  doAssert back.comps.len == 1 and back.comps[0].name == "A" and back.comps[0].position
  let bl = back.layers[d.layers.find(L)]
  bl.visible = false
  back.applyComp(back.comps[0])
  doAssert bl.visible, "the comp finds its layers again in the file"
  doAssert allPatterns().len >= 8
  # the Contextual Task Bar: there under the image, with what fits a pixel layer
  prefs.taskBar = true
  run(2)
  doAssert taskBarItems(active)[0][0] == "Select Subject"
  d.selectAll()
  doAssert taskBarItems(active)[^1][0] == "Deselect"
  d.selectNone()
  # the Magic Eraser: the white around a red square gone, the Background a layer now
  block:
    let m = newDoc(60, 40, white, name = "magic")
    for y in 10 ..< 30:
      for x in 20 ..< 40: m.layers[0].px[y * 60 + x] = 0xFFFF0000'u32
    m.markAll()
    m.magicErase(2, 2)
    doAssert not m.layers[0].background
    doAssert (m.layers[0].px[2 * 60 + 2] shr 24) == 0 and m.layers[0].px[20 * 60 + 30] == 0xFFFF0000'u32
    m.undo()
    doAssert m.layers[0].px[2 * 60 + 2] == 0xFFFFFFFF'u32
  # the Ruler: a slanted line made level by Straighten Layer
  block:
    let r = newDoc(200, 200, white, name = "ruler")
    addDoc(r)
    run(2)
    for x in 20 ..< 180:
      let yc = 90 + (x - 20) * 20 div 160
      for y in yc - 2 .. yc + 2: r.layers[0].px[y * 200 + x] = 0xFF000000'u32
    r.markAll()
    proc rowOf(d: Doc; x: int): float =
      var s, n = 0.0
      for y in 0 ..< d.h:
        if lumaOf(d.layers[0].px[y * d.w + x]) < 100:
          s += y.float
          n += 1
      if n > 0: s / n else: -1.0
    let cx = r.w div 2
    doAssert abs(rowOf(r, cx + 50) - rowOf(r, cx - 50)) > 10
    ruler = (true, r, 20.0, 90.0, 180.0, 110.0)
    doAssert rulerAngle() < -5 and rulerAngle() > -9
    straightenByRuler()
    let cx2 = r.w div 2
    doAssert abs(rowOf(r, cx2 + 50) - rowOf(r, cx2 - 50)) < 3, $(rowOf(r, cx2 + 50), rowOf(r, cx2 - 50))
  # the Color Sampler: up to four points an image
  block:
    let dd = cur()
    samplers.setLen(0)
    for k in 0 ..< 5:
      if samplers.len < 4: samplers.add (dd, k, k)
    doAssert samplers.len == 4
    samplers.setLen(0)
  # the 1994 keys: Photoshop 3's menus (no Type menu)
  prefs.keySet = 1
  applyKeySet()
  run(2)
  prefs.keySet = 0
  applyKeySet()
  run(1)

block styledTypeMovedLeavesNoTrail:
  # a type layer with a drop shadow moved frame by frame (the Move tool):
  # the view keeps no shadow where the text was (its style reaches past
  # the letters; the view is made again there too)
  docs.setLen(0)
  active = nil
  tabCur = nil
  run(2)
  let d = newDoc(240, 140, white, name = "trail")
  addDoc(d)
  run(2)
  let T = d.addTextLayer(newText("hello", CharStyle(family: "", size: 28, color: 0xFF000000'u32, hScale: 1,
                                                    vScale: 1), 20, 50))
  var sh = defaultEffect(fxDropShadow)
  sh.on = true
  sh.distance = 14
  sh.size = 4
  sh.opacity = 100
  T.fx.fx[fxDropShadow] = sh
  d.markAll()
  run(3)
  let t0 = T.text
  for k in 1 .. 12:
    d.setText(T, t0.moved(float32(k * 7), float32(k * 4)))
    run(1)
  run(2)
  let va = active.view.view
  var before: seq[uint32]
  for y in va.y ..< va.y + va.h:
    for x in va.x ..< va.x + va.w: before.add px(x, y)
  # (the view made again from nothing: what it should show)
  let z = active.view.zoom
  active.view.zoom = if z == 1: 2 else: 1
  run(2)
  active.view.zoom = z
  run(2)
  var after: seq[uint32]
  for y in va.y ..< va.y + va.h:
    for x in va.x ..< va.x + va.w: after.add px(x, y)
  var diff = 0
  for i in 0 ..< min(before.len, after.len):
    if before[i] != after[i]: inc diff
  doAssert diff == 0, "stale pixels in the view: " & $diff

block masksPhotoshopWays:
  docs.setLen(0)
  active = nil
  tabCur = nil
  run(2)
  let d = newDoc(160, 120, white, name = "masks")
  addDoc(d)
  run(2)
  let pic = d.addLayer("picture")
  for i in 0 ..< pic.px.len: pic.px[i] = 0xFF2266AA'u32
  inc pic.ver
  d.markAll()
  # a gradient mask: the Gradient tool on the mask, in grays
  fg = 0xFFFF0000'u32                     # (a color: on the mask it is its gray)
  runCommand("Gradient Mask")
  doAssert pic.mask != nil and d.editMask and tool == tGradient
  d.beginStep("Gradient")
  var stops = toolStops()
  for st in stops.mitems: st.color = grayOf(st.color)
  d.gradientFill(0, 0, 160, 0, paintOpts(tGradient, d), stops, gkLinear, false, false, 0)
  d.endStep()
  let m0 = pic.mask.px[60 * 160 + 2] and 255
  let m1 = pic.mask.px[60 * 160 + 157] and 255
  doAssert m0 < 40 and m1 > 215, $(m0, m1)
  let mp = pic.mask.px[60 * 160 + 80]
  doAssert ((mp shr 16) and 255) == (mp and 255), "grays on the mask"
  # a picture into type: clipped to it, covering it
  d.editMask = false
  let T = d.addTextLayer(newText("PHOTO", CharStyle(family: "", size: 40, color: 0xFF000000'u32, hScale: 1,
                                                    vScale: 1), 10, 80))
  run(2)
  d.cur = d.layers.find(T)
  let src = newDoc(50, 20, 0xFFFF8800'u32, name = "fill")
  src.saveRpd(home / "fill.rpd")
  placeInto = true
  d.placeSmart(home / "fill.rpd")
  let P = d.current
  doAssert P.isSmart and P.clipped and d.layers.find(P) == d.layers.find(T) + 1
  let tb = d.layerBox(T)
  let pb = d.layerBox(P)
  doAssert pb.x <= tb.x and pb.y <= tb.y and pb.x + pb.w >= tb.x + tb.w and pb.y + pb.h >= tb.y + tb.h,
           "it covers the letters: " & $(tb, pb)
  # a frame
  runCommand("New Frame")
  doAssert d.current.isShape and d.current.name.startsWith("Frame")
  # the Type Mask tool: what is typed becomes a selection
  typeMaskMode = true
  selectTool(tType)
  let before = d.layers.len
  d.beginStep("Type Tool")
  d.touchLayers()
  let TL = d.addTextLayer(newText("Hi", CharStyle(family: "", size: 40, color: 0xFF000000'u32, hScale: 1,
                                                  vScale: 1), 20, 60))
  d.drawText(TL)
  startTypeEdit(active, TL, true, 0)
  commitType()
  typeMaskMode = false
  doAssert d.hasSelection and d.layers.len == before, "the letters selected, no layer left"

block smartExtraction:
  # a red ball on gray: Remove Background keeps the ball; the Object Finder
  # shows it under the mouse and a click selects it
  docs.setLen(0)
  active = nil
  tabCur = nil
  run(2)
  let d = newDoc(160, 120, 0xFF9A9A9A'u32, name = "ball")
  let L = d.layer
  for y in 0 ..< 120:
    for x in 0 ..< 160:
      let dx = x - 80
      let dy = y - 60
      if dx * dx + dy * dy < 30 * 30: L.px[y * 160 + x] = 0xFFD02020'u32
      elif ((x div 7 + y div 5) and 1) == 0: L.px[y * 160 + x] = 0xFF8C8C8C'u32
  inc L.ver
  d.markAll()
  addDoc(d)
  run(2)
  runCommand("Remove Background")
  let M = d.current
  doAssert not M.background and M.mask != nil, status
  doAssert (M.mask.px[60 * 160 + 80] and 255) > 200, "the ball kept"
  doAssert (M.mask.px[5 * 160 + 5] and 255) < 60, "the background hidden"
  let segs = d.findSegments()
  let k = segs.regionAt(80, 60)
  doAssert k >= 0 and k != segs.regionAt(5, 5)
  let m = findObject(Img(w: d.w, h: d.h, px: d.compCopy), segs, k)
  doAssert m[60 * 160 + 80] > 200 and m[5 * 160 + 5] < 60
  # Refine Hair leaves a plain edge alone and keeps the mask's size
  let r = refineHair(Img(w: d.w, h: d.h, px: L.px), m)
  doAssert r.len == m.len and r[60 * 160 + 80] > 200

block photoshopToolbar:
  # the tools in Photoshop's groups: a letter picks the group's tool, Shift
  # and the letter the next one; the Polygonal Lasso clicks its corners
  docs.setLen(0)
  active = nil
  tabCur = nil
  run(2)
  let d = newDoc(120, 90, white, name = "tb")
  addDoc(d)
  run(2)
  prefs.keySet = 0
  doAssert toolKeyPressed(KeyM, false) and tool == tMarquee and marqueeShape == 0
  doAssert toolKeyPressed(KeyM, true) and tool == tMarquee and marqueeShape == 1, "Shift+M: the elliptical"
  doAssert toolKeyPressed(KeyV, false) and tool == tMove
  doAssert toolKeyPressed(KeyM, false) and marqueeShape == 1, "the group remembers its tool"
  doAssert toolKeyPressed(KeyJ, false) and tool == tHeal
  for i in 0 ..< 5: discard toolKeyPressed(KeyJ, true)
  doAssert tool == tRedEye, "J's group goes round to the red eye"
  doAssert toolKeyPressed(KeyY, false) and tool == tStamp and stampTool == 1, "Y: the History Brush"
  doAssert toolKeyPressed(KeyS, false) and tool == tStamp and stampTool == 0
  doAssert toolKeyPressed(KeyA, false) and tool == tPen and penMode == 5, "A: Path Selection"
  doAssert not toolKeyPressed(KeyX, false), "X swaps the colors, no group"
  # every tool of every group is that tool when picked
  for g, grp in toolGroups:
    for k, it in grp.items:
      pickTool(g, k)
      doAssert itemOn(it) and groupOf(tool) == g, it.name
  # the Polygonal Lasso: four corners, the first clicked again closes it
  for g, grp in toolGroups:
    if grp.name == "Lasso": pickTool(g, 1)
  doAssert tool == tLasso and lassoMode == 1
  let dw = active
  for (x, y) in [(20.0, 20.0), (80.0, 20.0), (80.0, 60.0), (20.0, 60.0)]:
    let (sx, sy) = dw.view.toScreen(d, x, y)
    ui.mx = sx
    ui.my = sy
    polyLassoClick(dw, PhotoEvent(over: true, x: x, y: y, pressed: true, clicks: 1), soReplace)
  doAssert polyLasso.on and polyLasso.pts.len == 4
  let (fx, fy) = dw.view.toScreen(d, 20.0, 20.0)
  ui.mx = fx
  ui.my = fy
  polyLassoClick(dw, PhotoEvent(over: true, x: 20, y: 20, pressed: true, clicks: 1), soReplace)
  doAssert not polyLasso.on and d.hasSelection
  let b = d.selBounds
  doAssert abs(b.x - 20) <= 1 and abs(b.w - 60) <= 2 and abs(b.h - 40) <= 2, $b
  # a tool chosen in the middle lets the corners go
  polyLassoClick(dw, PhotoEvent(over: true, x: 10, y: 10, pressed: true, clicks: 1), soReplace)
  doAssert polyLasso.on
  selectTool(tBrush)
  doAssert not polyLasso.on
  # the toolbar fits: one column, or more on a short screen
  prefs.toolCols = 0
  doAssert toolColumns() in 1 .. 3
  prefs.toolCols = 2
  doAssert toolColumns() in 2 .. 3, $(ui.h, prefs.toolHidden, toolColumns())   # (3 on a short screen)
  prefs.toolCols = 0

block newPhotoshopTools:
  # Perspective Crop, the crop box's handles, the Background Eraser, the
  # Freeform and Curvature Pens, Vertical Type
  docs.setLen(0)
  active = nil
  tabCur = nil
  run(2)
  # (the engine) a perspective crop of an upright box is a crop of it
  block:
    let a = sample(160, 120)
    let b = sample(160, 120)
    a.crop(rect(20, 10, 100, 80))
    b.perspectiveCrop(quadOf(rect(20, 10, 100, 80)), 0xFFFFFFFF'u32)
    doAssert (b.w, b.h) == (100, 80), $(b.w, b.h)
    var off = 0
    for i in 0 ..< a.w * a.h:
      let p = a.layer.px[i]
      let q = b.layer.px[i]
      off = max(off, max(abs(rOf(p) - rOf(q)), abs(gOf(p) - gOf(q))))
    doAssert off <= 3, "perspective of an upright box: " & $off
    # a trapezoid made a rectangle: its size the sides' average lengths
    let q: Quad = [(30.0, 20.0), (130.0, 20.0), (150.0, 100.0), (10.0, 100.0)]
    let (pw, ph) = perspectiveSize(q)
    doAssert pw == 120 and ph in 80 .. 84, $(pw, ph)
  let d = sample(200, 150)
  addDoc(d)
  run(2)
  let dw = active
  template at(px, py: float; body: untyped) =
    block:
      let (sx, sy) = dw.view.toScreen(d, px, py)
      ui.mx = sx
      ui.my = sy
      let ev {.inject.} = PhotoEvent(over: true, x: px, y: py, pressed: true, down: true, clicks: 1)
      body
  proc dragLine(x0, y0, x1, y1: float; steps = 8) =
    at(x0, y0): pressOn(dw, ev)
    for k in 1 .. steps:
      let t = k / steps
      at(x0 + (x1 - x0) * t, y0 + (y1 - y0) * t): dragOn(ev)
    at(x1, y1): releaseOn(ev)
  # the Crop tool: a box, its right side pulled, then a click inside crops
  for g, grp in toolGroups:
    if grp.name == "Crop": pickTool(g, 0)
  doAssert tool == tCrop and cropKind == 0
  dragLine(40, 30, 140, 110)
  doAssert pendingCrop.on and not pendingCrop.persp and pendingCrop.r == rect(40, 30, 100, 80), $pendingCrop.r
  dragLine(140, 70, 160, 70)
  doAssert pendingCrop.r.w == 120, "the right side's handle: " & $pendingCrop.r
  dragLine(90, 70, 100, 75)
  doAssert pendingCrop.r.x == 50 and pendingCrop.r.y == 35, "moved from inside: " & $pendingCrop.r
  at(100, 75): pressOn(dw, ev)
  at(100, 75): releaseOn(ev)
  doAssert not pendingCrop.on and (d.w, d.h) == (120, 80), $(d.w, d.h)
  doAssert d.undoName == "Crop", d.undoName
  # the Perspective Crop: a box, a corner pulled in, Enter
  for g, grp in toolGroups:
    if grp.name == "Crop": pickTool(g, 1)
  doAssert tool == tCrop and cropKind == 1
  dragLine(10, 10, 110, 70)
  doAssert pendingCrop.on and pendingCrop.persp
  dragLine(110, 10, 100, 20)
  doAssert abs(pendingCrop.q[1][0] - 100) < 0.5 and abs(pendingCrop.q[1][1] - 20) < 0.5, $pendingCrop.q
  commitCropNow()
  let (ew, eh) = (d.w, d.h)
  doAssert not pendingCrop.on and ew in 93 .. 97 and eh in 55 .. 59, $(ew, eh)
  doAssert d.undoName == "Perspective Crop", d.undoName
  runCommand("Undo")
  doAssert (d.w, d.h) == (120, 80), "undone"
  # the Background Eraser: red on the left, blue on the right; a stroke down
  # the middle, sampling the red, rubs out the red only (the Background
  # becomes a layer)
  let e = newDoc(120, 80, white, name = "bgerase")
  for y in 0 ..< 80:
    for x in 0 ..< 120:
      e.layer.px[y * 120 + x] = if x < 60: 0xFFE02020'u32 else: 0xFF2040E0'u32
  inc e.layer.ver
  e.markAll()
  addDoc(e)
  run(2)
  let ew2 = active
  for g, grp in toolGroups:
    if grp.name == "Eraser":
      for k, it in grp.items:
        if it.name == "Background Eraser Tool": pickTool(g, k)
  doAssert tool == tEraser and eraseKind == 2
  opts[tEraser].tip.diameter = 40
  opts[tEraser].tip.hardness = 100
  opts[tEraser].opacity = 100
  bgEraseSampling = 1
  bgEraseLimits = 1
  bgEraseTol = 20
  block:
    let (sx, sy) = ew2.view.toScreen(e, 50.0, 10.0)
    ui.mx = sx
    ui.my = sy
    pressOn(ew2, PhotoEvent(over: true, x: 50, y: 10, pressed: true, down: true, clicks: 1))
    for k in 1 .. 12:
      let y = 10.0 + k.float * 5
      let (tx, ty) = ew2.view.toScreen(e, 50.0, y)
      ui.mx = tx
      ui.my = ty
      dragOn(PhotoEvent(over: true, x: 50, y: y, down: true))
    releaseOn(PhotoEvent(over: true, x: 50, y: 70))
  doAssert not e.layers[0].background, "the Background became a layer"
  let L = e.current
  doAssert aOf(L.px[40 * 120 + 50]) == 0, "the red under the brush is gone"
  doAssert aOf(L.px[40 * 120 + 62]) == 255, "the blue under the brush stays"
  doAssert aOf(L.px[40 * 120 + 10]) == 255, "the red away from the brush stays"
  # the Color Replacement tool: blue painted over the red keeps its light; the blue stays as it was
  block:
    let c = newDoc(120, 80, white, name = "recolor")
    for y in 0 ..< 80:
      for x in 0 ..< 120:
        c.layer.px[y * 120 + x] = if x < 60: argb(255, 200 - y, 30, 30) else: 0xFF2040E0'u32
    inc c.layer.ver
    c.markAll()
    addDoc(c)
    run(2)
    let cw = active
    for g, grp in toolGroups:
      if grp.name == "Brush":
        for k, it in grp.items:
          if it.name == "Color Replacement Tool": pickTool(g, k)
    doAssert tool == tBrush and brushTool == 2
    opts[tBrush].tip.diameter = 40
    opts[tBrush].tip.hardness = 100
    opts[tBrush].opacity = 100
    crSampling = 1
    crTol = 25
    fg = 0xFF0000FF'u32
    let (sx, sy) = cw.view.toScreen(c, 50.0, 10.0)
    ui.mx = sx
    ui.my = sy
    pressOn(cw, PhotoEvent(over: true, x: 50, y: 10, pressed: true, down: true, clicks: 1))
    for k in 1 .. 12:
      let y = 10.0 + k.float * 5
      dragOn(PhotoEvent(over: true, x: 50, y: y, down: true))
    releaseOn(PhotoEvent(over: true, x: 50, y: 70))
    let p0 = c.layer.px[40 * 120 + 50]
    doAssert (p0 and 0xFF) > ((p0 shr 16) and 0xFF), "the red turned blue: " & toHex(p0)
    doAssert c.layer.px[40 * 120 + 64] == 0xFF2040E0'u32, "the blue stays"
    doAssert ((c.layer.px[40 * 120 + 10] shr 16) and 0xFF) > 100, "red away from the brush stays"
  # the Freeform Pen: a circle drawn by hand becomes a closed path of a few points
  for g, grp in toolGroups:
    if grp.name == "Pen": pickTool(g, 1)
  doAssert tool == tPen and penMode == 6
  e.paths.setLen(0)
  e.curPath = -1
  block:
    let cx = 60.0
    let cy = 40.0
    let (sx, sy) = ew2.view.toScreen(e, cx + 30, cy)
    ui.mx = sx
    ui.my = sy
    pressOn(ew2, PhotoEvent(over: true, x: cx + 30, y: cy, pressed: true, down: true, clicks: 1))
    for k in 1 .. 72:
      let a = k.float / 72 * 2 * PI
      let (x, y) = (cx + 30 * cos(a), cy + 30 * sin(a))
      let (tx, ty) = ew2.view.toScreen(e, x, y)
      ui.mx = tx
      ui.my = ty
      dragOn(PhotoEvent(over: true, x: x, y: y, down: true))
    releaseOn(PhotoEvent(over: true, x: cx + 30, y: cy))
  doAssert e.paths.len == 1 and e.paths[0].subs.len == 1
  let fp = e.paths[0].subs[0]
  doAssert fp.closed and fp.pts.len in 4 .. 30, $(fp.closed, fp.pts.len)
  doAssert fp.pts[1].outH != fp.pts[1].p, "smooth curves"
  # the Curvature Pen: three clicks, the middle point smooth; the first closes it
  for g, grp in toolGroups:
    if grp.name == "Pen": pickTool(g, 2)
  doAssert tool == tPen and penMode == 7
  e.paths.setLen(0)
  e.curPath = -1
  for (x, y) in [(20.0, 60.0), (60.0, 20.0), (100.0, 60.0)]:
    let (sx, sy) = ew2.view.toScreen(e, x, y)
    ui.mx = sx
    ui.my = sy
    pressOn(ew2, PhotoEvent(over: true, x: x, y: y, pressed: true, down: true, clicks: 1))
    releaseOn(PhotoEvent(over: true, x: x, y: y))
  let cp = e.paths[0].subs[0]
  doAssert cp.pts.len == 3 and not cp.closed
  doAssert abs(cp.pts[1].outH[0] - 60) > 5 and abs(cp.pts[1].outH[1] - 20) < 0.01, $cp.pts[1]
  block:
    let (sx, sy) = ew2.view.toScreen(e, 20.0, 60.0)
    ui.mx = sx
    ui.my = sy
    pressOn(ew2, PhotoEvent(over: true, x: 20, y: 60, pressed: true, down: true, clicks: 1))
    releaseOn(PhotoEvent(over: true, x: 20, y: 60))
  doAssert e.paths[0].subs[0].closed, "the first point clicked closes it"
  # Vertical Type: the letters go down
  for g, grp in toolGroups:
    if grp.name == "Type": pickTool(g, 1)
  doAssert tool == tType and typeVertical and not typeMaskMode
  ew2.newTextAt(newText("ABCD", CharStyle(family: "", size: 20, color: 0xFF000000'u32, hScale: 1, vScale: 1),
                        40, 10))
  let T = te.layer
  commitType()
  doAssert T.text.vertical
  let tb = e.layerBox(T)
  doAssert tb.h > tb.w * 2, "vertical: " & $tb
  for g, grp in toolGroups:
    if grp.name == "Type": pickTool(g, 0)
  doAssert not typeVertical

block sessionAndQuit:
  # the close box (or Back) with documents open: asked, never straight
  # away; the documents open again at the next start, their changes too
  docs.setLen(0)
  active = nil
  tabCur = nil
  run(2)
  let saved = home / "kept.png"
  let a = sample(50, 40)
  a.saveFlat(saved, "png")
  openFile(saved)
  run(2)
  let b = sample(60, 30)
  b.name = "Untitled-7"
  addDoc(b)
  run(2)
  b.beginStep("Fill")
  b.layer.px[0] = 0xFF123456'u32
  b.endStep()
  b.modified = true
  closeWindow()
  run(2)
  doAssert quitConfirm, "asked first"
  doAssert beginFrame(), "still running"
  view()
  endFrame()
  quitConfirm = false
  writeSession()
  let st = loadSettings(AppName)
  doAssert st.getInt("session.count") == 2
  doAssert st.get("session.0.path") == saved and st.get("session.0.file") == ""
  doAssert st.get("session.1.file").endsWith(".rpd") and fileExists(st.get("session.1.file"))
  docs.setLen(0)
  active = nil
  run(2)
  restoreSession()
  run(2)
  doAssert docs.len == 2, $docs.len
  doAssert docs[0].doc.path == saved and not docs[0].doc.modified
  let r = docs[1].doc
  doAssert r.name == "Untitled-7" and r.modified and r.layer.px[0] == 0xFF123456'u32, "the changes came back"
  doAssert (r.w, r.h) == (60, 30)

block documentPreviews:
  # .rpd files carry a small picture of themselves: file lists and the Open
  # dialog show it without opening the document
  let d = sample(300, 200)
  let L = d.addLayer("top")
  for i in 0 ..< 50 * 300: L.px[i] = 0xFFFF0000'u32
  d.markAll()
  let p = home / "preview.rpd"
  d.saveRpd(p)
  let b = rpdPreview(p)
  doAssert b != nil and (b.w, b.h) == (300, 200), "the merged picture, small"
  doAssert (b.px[10 * 300 + 10] and 0xFFFFFF'u32) == 0xFF0000'u32, "the top layer is in it"
  let t = loadPicture(p, 64, 64)
  doAssert t != nil and t.w == 64, "loadPicture reads .rpd (as the file widgets do)"
  doAssert isPicture(infoOf(p))
  let back = loadRpd(p)
  doAssert back.layers.len == 2, "the preview does not get in the way"

block filterPreviewOnCanvas:
  # a filter's dialog shows it on the image as it is set; Cancel takes it
  # back, OK keeps it (one step)
  docs.setLen(0)
  active = nil
  run(2)
  let d = sample(90, 60)
  addDoc(d)
  run(2)
  let before = d.layer.px
  fCanvas = true
  startFilter("Gaussian Blur")
  fVals[0] = 4
  run(3)
  doAssert d.stepOpen and d.layer.px != before, "seen on the image"
  fOpen = false
  run(2)
  doAssert not d.stepOpen and d.layer.px == before, "Cancel: as it was"
  let undoBefore = d.undoName
  startFilter("Gaussian Blur")
  fVals[0] = 3
  run(3)
  let shown = d.layer.px
  # (OK: what is shown is kept)
  fOpen = false
  d.endStep()
  fCanvasOn = (nil, "")
  run(2)
  doAssert d.layer.px == shown and d.undoName == "Gaussian Blur" and undoBefore != "Gaussian Blur"
  # the Filter Gallery's and the new filters: each opens, shows itself on
  # the image, and goes back on Cancel
  for name in @galleryArtistic & @galleryBrush & @gallerySketch & @galleryTexture &
              @["Oil Paint", "Fibers", "Lighting Effects", "Displace", "Smart Sharpen"]:
    doAssert filters.hasKey(name), name
    let was = d.layer.px
    startFilter(name)
    run(3)
    doAssert fOpen and d.layer.px != was, name & ": seen on the image"
    fOpen = false
    run(2)
    doAssert d.layer.px == was, name & ": Cancel"

block pdfSaveAndPresentation:
  # Save As .pdf: the Save PDF dialog, a preset, then the file; PDF
  # Presentation: the open documents as pages
  docs.setLen(0)
  active = nil
  run(2)
  let a = sample(120, 80)
  addDoc(a)
  let b = sample(100, 100)
  addDoc(b)
  run(2)
  let p1 = home / "one.pdf"
  startPdfOptions(@[a], p1)
  run(2)
  doAssert pdfDlg.open
  pdfDlg.o = pdfPreset(ppPress)
  pdfDlg.open = false
  writePdfNow()
  doAssert fileExists(p1) and "/DeviceCMYK" in readFile(p1)
  startPdfPresentation()
  run(2)
  doAssert presDlg.open and presDlg.order.len == 2
  presDlg.open = false
  let p2 = home / "two.pdf"
  startPdfOptions(@[a, b], p2)
  pdfDlg.open = false
  writePdfNow()
  doAssert "/Count 2" in readFile(p2)
  # opening a PDF: the Import PDF dialog, its page drawn small
  startPdfImport(p2)
  run(3)
  doAssert impDlg.open and impDlg.pages.len == 2 and impDlg.thumbs[0] != nil
  impDlg.open = false
  run(2)
  let opened = openPicture(p2)
  doAssert opened.w > 0 and opened.layers.len >= 1
  # EPS: the options, then the file
  startEpsOptions(docs[0], home / "a.eps")
  run(2)
  doAssert epsDlg.open
  epsDlg.open = false

block autoSelectIsSmart:
  # the Move tool is the first tool, with Auto-Select on; a click picks the
  # thing on the page -- not the texture laid over the whole page
  doAssert moveAutoSelect
  let d = newDoc(400, 300, 0xFFFFFFFF'u32)
  let shape = d.addShapeLayer(ShapeData(path: rectPath(100, 100, 200, 160), fill: solidPaint(0xFFFF0000'u32)),
                              "Box")
  let thin = d.addShapeLayer(ShapeData(path: linePath(20, 250, 380, 250, 1), fill: solidPaint(0xFF0000FF'u32)),
                             "Hairline")
  let grain = d.addLayer("Grain")
  for p in grain.px.mitems: p = 0xFF808080'u32
  grain.mode = bmOverlay
  grain.opacity = 20
  doAssert d.layerAt(150, 130) == d.layers.find(shape), "the box, under the grain"
  doAssert d.layerAt(50, 50) == 0, "nothing else there: the page itself, not the texture over it"
  doAssert d.layerAt(150, 253) == 0, "a hairline missed without room"
  doAssert d.layerAt(150, 253, radius = 4) == d.layers.find(thin), "... picked with a few pixels' room"
  shape.visible = false
  doAssert d.layerAt(150, 130) == 0, "hidden layers are not picked"
  shape.visible = true
  d.addLayerMask(mfHideAll, d.layers.find(shape))
  doAssert d.layerAt(150, 130) == 0, "hidden by its mask"
  d.layers[0].visible = false
  doAssert d.layerAt(50, 50) == d.layers.find(grain), "with no page, the texture"

block selectionToolsAsPhotoshop:
  # the selection tools as Photoshop's: a drag inside the selection moves
  # its outline (the pixels stay); a click there deselects; Ctrl+drag moves
  # the pixels; Shift (after the drag began) a square, Alt from the middle;
  # the arrows move the outline; the number keys set the layer's opacity
  let d = sample(200, 150)
  addDoc(d)
  run(2)
  let dw = active
  template at(px, py: float; mods: string; body: untyped) =
    block:
      let (sx, sy) = dw.view.toScreen(d, px, py)
      ui.mx = sx
      ui.my = sy
      let ev {.inject.} = PhotoEvent(over: true, x: px, y: py, pressed: true, down: true, clicks: 1,
                                     shift: 's' in mods, alt: 'a' in mods, ctrl: 'c' in mods)
      body
  proc dragLine(x0, y0, x1, y1: float; mods = ""; first = "") =
    at(x0, y0, first): pressOn(dw, ev)
    for k in 1 .. 6:
      let t = k / 6
      at(x0 + (x1 - x0) * t, y0 + (y1 - y0) * t, mods): dragOn(ev)
    at(x1, y1, mods): releaseOn(ev)
  selectTool(tMarquee)
  marqueeShape = 0
  marqueeStyle = 0
  marqueeFeather = 0
  dragLine(20, 20, 60, 50)
  doAssert d.hasSelection and d.selBounds == rect(20, 20, 40, 30), $d.selBounds
  let px0 = d.layer.px
  # a drag inside: the outline moves by it, the pixels do not
  dragLine(30, 30, 50, 40)
  doAssert d.selBounds == rect(40, 30, 40, 30), $d.selBounds
  doAssert d.layer.px == px0, "the pixels stay"
  doAssert d.undoName == "Move Selection", d.undoName
  d.undo()
  doAssert d.selBounds == rect(20, 20, 40, 30)
  d.redo()
  # the arrow keys: the outline, one pixel (Shift: ten)
  key(KeyRight)
  run(1)
  doAssert d.selBounds == rect(41, 30, 40, 30), $d.selBounds
  key(KeyDown, {ShiftPressed})
  run(1)
  doAssert d.selBounds == rect(41, 40, 40, 30), $d.selBounds
  doAssert d.layer.px == px0
  # a click inside: Deselect
  at(50, 50, ""): pressOn(dw, ev)
  at(50, 50, ""): releaseOn(ev)
  doAssert not d.hasSelection
  # Shift after the drag began: a square; Alt: from the middle
  dragLine(100, 60, 140, 80, mods = "s")
  doAssert d.selBounds == rect(100, 60, 40, 40), "a square: " & $d.selBounds
  at(10, 10, ""): pressOn(dw, ev)
  at(10, 10, ""): releaseOn(ev)
  dragLine(100, 75, 120, 85, mods = "a")
  doAssert d.selBounds == rect(80, 65, 40, 20), "from the middle: " & $d.selBounds
  # Ctrl+drag inside: the pixels move (as the Move tool)
  dragLine(100, 75, 110, 75, mods = "c", first = "c")
  doAssert d.layer.px != px0, "Ctrl: the pixels moved"
  d.undo()
  doAssert d.layer.px == px0
  # the Gradient tool with Shift: at 45 degrees
  selectTool(tGradient)
  at(20, 20, ""): pressOn(dw, ev)
  at(70, 40, "s"): dragOn(ev)
  doAssert abs(drag.y1 - 20) < 0.01 or abs((drag.x1 - 20) - (drag.y1 - 20)) < 0.01, $(drag.x1, drag.y1)
  drag = Drag()
  # the Paint Bucket: Contiguous off fills every pixel alike
  let b = newDoc(30, 10, 0xFFFFFFFF'u32)
  for y in 0 ..< 10: b.layer.px[y * 30 + 15] = 0xFF000000'u32     # (a wall)
  inc b.layer.ver
  var o = PaintOpts(color: 0xFFFF0000'u32, opacity: 100, mode: bmNormal)
  b.beginStep("Fill")
  b.bucketFill(2, 2, o, 10, false)
  b.endStep()
  doAssert b.layer.px[5 * 30 + 25] == 0xFFFFFFFF'u32, "contiguous: the wall stops it"
  b.undo()
  b.beginStep("Fill")
  b.bucketFill(2, 2, PaintOpts(color: 0xFF00FF00'u32, opacity: 100, mode: bmNormal), 10, false,
               contiguous = false)
  b.endStep()
  doAssert b.layer.px[5 * 30 + 25] != 0xFFFFFFFF'u32 and b.layer.px[5 * 30 + 15] == 0xFF000000'u32
  # the number keys: the painting tool's opacity; the layer's with the others; two quickly: that
  selectTool(tBrush)
  key(Key5)
  run(1)
  doAssert opts[tBrush].opacity == 50
  selectTool(tMarquee)
  let L = d.addLayer("Over")
  d.cur = d.layers.find(L)
  digitFirst = -1
  key(Key4)
  run(1)
  key(Key5)
  run(1)
  doAssert L.opacity == 45, $L.opacity
  digitFirst = -1
  key(Key0)
  run(1)
  doAssert L.opacity == 100
  # the Zoom tool: a click zooms a step, a box zooms to show it
  selectTool(tZoom)
  dw.view.setZoom(d, 1)
  at(100, 75, ""): pressOn(dw, ev)
  at(100, 75, ""): releaseOn(ev)
  doAssert dw.view.zoom == 2, $dw.view.zoom
  dw.view.setZoom(d, 1)
  dragLine(90, 70, 110, 80)
  doAssert dw.view.zoom >= 4, "zoomed to the box: " & $dw.view.zoom
  let (cx, cy) = dw.view.toImage(d, dw.view.view.x + dw.view.view.w div 2, dw.view.view.y + dw.view.view.h div 2)
  doAssert abs(cx - 100) < 4 and abs(cy - 75) < 4, $(cx, cy)
  # the Polygonal Lasso with Shift: sides at 45 degrees
  let (qx, qy) = at45(0, 0, 10, 1)
  doAssert abs(qy) < 1e-9 and abs(qx - hypot(10.0, 1.0)) < 1e-9
  # the Move tool: Shift+click picks a second layer with the first; with
  # Auto-Select off, Ctrl+click picks
  let e = newDoc(200, 150, 0xFFFFFFFF'u32)
  let s1 = e.addShapeLayer(ShapeData(path: rectPath(10, 10, 50, 50), fill: solidPaint(0xFFFF0000'u32)), "One")
  let s2 = e.addShapeLayer(ShapeData(path: rectPath(100, 60, 150, 110), fill: solidPaint(0xFF0000FF'u32)), "Two")
  addDoc(e)
  run(2)
  let ew = active
  selectTool(tMove)
  moveKind = 0
  template on(px, py: float; mods: string; body: untyped) =
    block:
      let (sx, sy) = ew.view.toScreen(e, px, py)
      ui.mx = sx
      ui.my = sy
      let ev {.inject.} = PhotoEvent(over: true, x: px, y: py, pressed: true, down: true, clicks: 1,
                                     shift: 's' in mods, alt: 'a' in mods, ctrl: 'c' in mods)
      body
  on(30, 30, ""): pressOn(ew, ev)
  on(30, 30, ""): releaseOn(ev)
  doAssert e.current == s1
  on(120, 80, "s"): pressOn(ew, ev)
  on(120, 80, "s"): releaseOn(ev)
  doAssert e.current == s2 and s1.picked and s2.picked
  moveAutoSelect = false
  on(30, 30, ""): pressOn(ew, ev)
  on(30, 30, ""): releaseOn(ev)
  doAssert e.current == s2, "Auto-Select off: the click picks nothing"
  on(30, 30, "c"): pressOn(ew, ev)
  on(30, 30, "c"): releaseOn(ev)
  doAssert e.current == s1, "Ctrl+click picks"
  moveAutoSelect = true
  # a click with a shape tool: Create Rectangle, the size typed
  selectTool(tShape)
  shapeKind = 0
  shapeMode = 0
  shapeOp = 0
  let nShapes = e.layers.len
  on(60, 40, ""): pressOn(ew, ev)
  on(60, 40, ""): releaseOn(ev)
  doAssert shapeDlg.on
  shapeDlg.w = 30
  shapeDlg.h = 20
  run(2)
  key(KeyEnter)
  run(3)
  doAssert not shapeDlg.on and e.layers.len == nShapes + 1, $e.layers.len
  let nb = e.layerBox(e.current)
  doAssert nb.x in 59 .. 61 and nb.y in 39 .. 41 and nb.w in 29 .. 32 and nb.h in 19 .. 22, $nb
  # the Note tool: a note where clicked, written; the Count tool: numbers;
  # the Slice tool: boxes, exported as PNGs
  selectTool(tEyedropper)
  dropKind = 3
  on(40, 40, ""): pressOn(ew, ev)
  doAssert noteDlg.on and notes.len >= 1 and notes[^1].d == e
  noteDlg.text = "Fix the sky"
  run(2)
  key(KeyEnter)
  run(2)
  doAssert notes[^1].text == "Fix the sky" or noteDlg.on
  noteDlg.on = false
  notes[^1].text = "Fix the sky"
  dropKind = 4
  for (x, y) in [(10.0, 10.0), (60.0, 20.0), (90.0, 90.0)]:
    on(x, y, ""): pressOn(ew, ev)
  var nc = 0
  for c in counts:
    if c.d == e: inc nc
  doAssert nc == 3
  on(60, 20, "a"): pressOn(ew, ev)
  nc = 0
  for c in counts:
    if c.d == e: inc nc
  doAssert nc == 2, "Alt+click takes one away"
  dropKind = 0
  selectTool(tCrop)
  cropKind = 3
  on(10, 10, ""): pressOn(ew, ev)
  on(60, 50, ""): dragOn(ev)
  on(60, 50, ""): releaseOn(ev)
  doAssert slicesOf(e).len == 1 and slicesOf(e)[0] == rect(10, 10, 50, 40), $slicesOf(e)
  e.path = getTempDir() / "retro-slices.rpd"
  e.name = "slicetest"
  exportSlices(e)
  let sliceFile = getTempDir() / "slicetest Slices" / "slicetest_01.png"
  doAssert fileExists(sliceFile), status
  let sb = loadPicture(sliceFile)
  doAssert sb != nil and sb.w == 50 and sb.h == 40
  removeDir(getTempDir() / "slicetest Slices")
  # Slices From Guides: the parts the guides make
  e.guides = @[Guide(vertical: true, pos: 100), Guide(vertical: false, pos: 75)]
  slicesFromGuides(e)
  doAssert slicesOf(e).len == 4
  cropKind = 0
  # the toolbar: docked at the left edge, its header as the docked panels'
  doAssert toolbox.bare and toolbox.r.x == 0 and toolbox.r.y == 0
  doAssert toolboxBodyH > 0 and toolbox.r.h > panelHeaderH() + toolboxBodyH
  # the selection made by shiftedMask: off the edge is lost
  let m = shiftedMask([1'u8, 2, 3, 4, 5, 6], 3, 2, 1, -1)
  doAssert m == @[0'u8, 4, 5, 0, 0, 0], $m

block release44:
  # Retro Photo 4.4/4.5: scripts, styles, Rotate View, the Arabic interface
  let d = sample(60, 40)
  addDoc(d)
  run(2)
  # a script: the app, the document, its layers, a filter, a command
  scriptOut.setLen(0)
  runScript("""let d = app.activeDocument;
d.newLayer("Script layer");
d.activeLayer.opacity = 40;
d.applyFilter("Gaussian Blur", 2);
print(d.layers.length + " " + d.width + "x" + d.height);
d.layers[1].name = "Renamed";
d.resizeCanvas(80, 50, "#ff0000");""", "test")
  doAssert scriptOut.len >= 1 and "2 60x40" in scriptOut.join("\n"), scriptOut.join("\n")
  doAssert d.layers.len == 2 and d.layers[1].name == "Renamed" and d.layers[1].opacity == 40
  doAssert d.w == 80 and d.h == 50 and d.layers[0].px[0] == 0xFFFF0000'u32
  runScript("app.activeDocument.nosuch()", "bad")
  doAssert scriptOut[^1].startsWith("!!"), scriptOut[^1]
  # Character and Paragraph Styles: made, given, redefined everywhere
  var t = newText("Hello", CharStyle(family: "DejaVu Sans", style: "Book", size: 20, color: 0xFF000000'u32,
                                     hScale: 1, vScale: 1), 5, 25)
  d.beginStep("Type")
  d.touchLayers()
  let T = d.addTextLayer(t)
  d.endStep()
  var big = T.text.styleAt(0)
  big.size = 30
  d.redefineStyle(false, "Big", big)
  d.applyCharStyle(T, 0, 0, "Big")
  doAssert T.text.styleAt(0).styleName == "Big" and T.text.styleAt(0).size == 30
  big.size = 12
  d.redefineStyle(false, "Big", big)
  doAssert T.text.styleAt(0).size == 12, "redefined: the text follows"
  doAssert not d.styleOverridden(T, false)
  # Rotate View: the screen turned, the image not
  let dw = active
  dw.view.angle = 30
  run(2)
  let (ix, iy) = dw.view.toImage(d, dw.view.view.x + dw.view.view.w div 2, dw.view.view.y + dw.view.view.h div 2)
  let (sx, sy) = dw.view.toScreen(d, ix, iy)
  doAssert abs(sx - (dw.view.view.x + dw.view.view.w div 2)) <= 1 and
           abs(sy - (dw.view.view.y + dw.view.view.h div 2)) <= 1
  dw.view.angle = 0
  # (no Timeline in the app: an animated GIF opens as its first picture)
  doAssert not openAnimations
  # the Arabic interface: labels translated, the frame mirrored
  setUiLanguage("ar", @toolkitArabic, @photoArabic)
  doAssert ui.rtl and tr("File") != "File" and splitMnemonic("&Edit").text == tr("Edit")
  run(2)
  setUiLanguage("")
  doAssert not ui.rtl and tr("File") == "File"
  run(2)

block bigPictureOpen:
  # a picture too big to edit whole here: Open asks -- a smaller copy, or a
  # part picked on a preview -- each a new image of its own (no path)
  let f = home / "big.png"
  var b = newBitmap(600, 400)
  for y in 0 ..< 400:
    for x in 0 ..< 600: b.px[y * 600 + x] = argb(255, x * 255 div 600, y * 255 div 400, (x xor y) and 255)
  writeFile(f, encodePng(b))
  let saved = maxPixels
  maxPixels = 60_000
  let n0 = docs.len
  openFile(f)
  doAssert bigAsk.on and bigAsk.w == 600 and bigAsk.h == 400 and docs.len == n0
  run(2)
  setUiLanguage("ar", @toolkitArabic, @photoArabic)
  run(2)
  setUiLanguage("")
  bigAsk.on = false
  openBig(f, part = false)
  doAssert docs.len == n0 + 1 and cur().w * cur().h <= 60_000 and cur().w > 250 and cur().path == ""
  startBigPart(f, 600, 400)
  doAssert bigPart.on and bigPart.preview != nil and bigPart.pw * bigPart.ph <= 60_000
  run(2)
  setUiLanguage("ar", @toolkitArabic, @photoArabic)
  run(2)
  setUiLanguage("")
  bigPart.on = false
  openBig(f, part = true)
  doAssert docs.len == n0 + 2 and cur().w == bigPart.pw and cur().h == bigPart.ph and cur().path == ""
  maxPixels = saved
  run(2)

block escapeAndNewContents:
  # Esc lets go what is under way (a stroke, a box being drawn, the
  # Polygonal Lasso, the path drawn), else the selection; New Document's
  # Transparent is transparent (it made black); File > Save as PDF
  docs.setLen(0)
  active = nil
  tabCur = nil
  scriptOpen = false                   # (an earlier test's dialog: the keys go to it)
  run(2)
  let d = newDoc(100, 80, white, name = "esc")
  addDoc(d)
  run(2)
  let dw = active
  # a brush stroke, Esc in the middle: the pixels as they were, no step
  selectTool(tBrush)
  brushTool = 0
  fg = black
  let steps = d.undoSteps.len
  pressOn(dw, PhotoEvent(over: true, x: 20, y: 20, pressed: true, down: true, clicks: 1))
  dragOn(PhotoEvent(over: true, x: 70, y: 50, down: true))
  doAssert drag.on
  doAssert escapeKey() and not drag.on
  var allWhite = true
  for c in d.layers[0].px:
    if (c and 0xFFFFFF'u32) != 0xFFFFFF'u32: allWhite = false
  doAssert allWhite, "the stroke taken back"
  doAssert d.undoSteps.len == steps and d.redoSteps.len == 0, "and not in the history"
  # a marquee being drawn: none
  selectTool(tMarquee)
  marqueeShape = 0
  pressOn(dw, PhotoEvent(over: true, x: 10, y: 10, pressed: true, down: true, clicks: 1))
  dragOn(PhotoEvent(over: true, x: 60, y: 50, down: true))
  doAssert escapeKey() and not d.hasSelection, "the box drawn let go"
  # a selection made: Esc (the key) deselects it -- (first: an earlier
  # test's panel flown out of the dock's icons goes, as on a press here)
  ui.focus = 0
  queue.add Event(kind: KeyDownEvent, key: KeyEsc)
  run(2)
  pressOn(dw, PhotoEvent(over: true, x: 10, y: 10, pressed: true, down: true, clicks: 1))
  dragOn(PhotoEvent(over: true, x: 60, y: 50, down: true))
  releaseOn(PhotoEvent(over: true, x: 60, y: 50, released: true))
  doAssert d.hasSelection
  ui.focus = 0                         # (a press on the image takes the keys there)
  queue.add Event(kind: KeyDownEvent, key: KeyEsc)
  run(2)
  doAssert not d.hasSelection, "Esc: deselected"
  # the Polygonal Lasso's corners: let go
  polyLassoClick(dw, PhotoEvent(over: true, x: 10, y: 10, pressed: true, clicks: 1), soReplace)
  polyLassoClick(dw, PhotoEvent(over: true, x: 50, y: 10, pressed: true, clicks: 1), soReplace)
  doAssert polyLasso.on
  queue.add Event(kind: KeyDownEvent, key: KeyEsc)
  run(2)
  doAssert not polyLasso.on and not d.hasSelection
  # the pen: Esc ends the path; the next click starts another
  selectTool(tPen)
  penMode = 1
  for (x, y) in [(10.0, 10.0), (40.0, 10.0)]:
    pressOn(dw, PhotoEvent(over: true, x: x, y: y, pressed: true, down: true, clicks: 1))
    releaseOn(PhotoEvent(over: true, x: x, y: y, released: true))
  let subs = d.paths[d.curPath].subs.len
  doAssert escapeKey() and penEnded
  pressOn(dw, PhotoEvent(over: true, x: 60, y: 60, pressed: true, down: true, clicks: 1))
  releaseOn(PhotoEvent(over: true, x: 60, y: 60, released: true))
  doAssert d.paths[d.curPath].subs.len == subs + 1, "a new subpath"
  selectTool(tMove)
  # New Document: each name of the list makes what it says
  for (name, want) in [("White", 0xFFFFFFFF'u32), ("Black", 0xFF000000'u32), ("Transparent", 0'u32)]:
    newContents = ndContentsCodes[ndContents.find(name)]
    newW = 20
    newH = 10
    ndTemplate = -1
    ndArtboards = false
    ndCreate()
    let n = cur()
    doAssert n.layers[0].px[0] == want, name & ": " & $n.layers[0].px[0]
    doAssert n.layers[0].background == (name != "Transparent"), name
  # File > Save as PDF: where, then its options
  runCommand("Save as PDF...")
  doAssert pdfPick and pdfPath.endsWith(".pdf"), pdfPath
  pdfPick = false
  # Image Size's units: pixels in each
  doAssert pxPerUnit(2, 600, 300) == 300 and abs(pxPerUnit(3, 600, 254) - 100) < 1e-9
  doAssert abs(pxPerUnit(4, 600, 254) - 10) < 1e-9 and pxPerUnit(1, 600, 72) == 6
  doAssert pxPerUnit(5, 0, 144) == 2 and pxPerUnit(6, 0, 72) == 12

block lineWithEnds:
  # the Line tool: a line layer with arrowheads (or other ends) that the
  # Move tool reshapes by its ends; the options change the one picked
  docs.setLen(0)
  active = nil
  tabCur = nil
  run(2)
  let d = newDoc(200, 120, white, name = "line")
  addDoc(d)
  run(2)
  let dw = active
  selectTool(tShape)
  shapeKind = 4
  shapeMode = 0
  lineWidth = 4
  lineStart = leNone
  lineEnd = leArrow
  pressOn(dw, PhotoEvent(over: true, x: 20, y: 60, pressed: true, down: true, clicks: 1))
  dragOn(PhotoEvent(over: true, x: 180, y: 60, down: true))
  releaseOn(PhotoEvent(over: true, x: 180, y: 60, released: true))
  let L = d.current
  doAssert L.isLine and L.shape.endEnd == leArrow and L.shape.stroke.kind == spColor
  doAssert L.shape.path.subs[0].pts[^1].p == (180.0, 60.0)
  run(2)
  # the options bar changes the line picked: a circle at its start
  lineStart = leCircle
  applyLineOptions()
  doAssert L.shape.startEnd == leCircle
  # the Move tool: its end dragged, the line follows
  selectTool(tMove)
  let (sx, sy) = dw.view.toScreen(d, 180, 60)
  ui.mx = sx
  ui.my = sy
  pressOn(dw, PhotoEvent(over: true, x: 180, y: 60, pressed: true, down: true, clicks: 1))
  doAssert lineGrab.on
  dragOn(PhotoEvent(over: true, x: 150, y: 100, down: true))
  releaseOn(PhotoEvent(over: true, x: 150, y: 100, released: true))
  doAssert not lineGrab.on and L.shape.path.subs[0].pts[^1].p == (150.0, 100.0)
  d.undo()
  doAssert L.shape.path.subs[0].pts[^1].p == (180.0, 60.0), "undone"
  # Esc while an end is dragged: back where it was
  pressOn(dw, PhotoEvent(over: true, x: 180, y: 60, pressed: true, down: true, clicks: 1))
  dragOn(PhotoEvent(over: true, x: 100, y: 20, down: true))
  doAssert escapeKey()
  doAssert d.current.shape.path.subs[0].pts[^1].p == (180.0, 60.0), "Esc: as it was"

echo "photo app tests passed"
