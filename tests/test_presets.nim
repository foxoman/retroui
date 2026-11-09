## Tests of `retroui/photopresets`: the Adjustment Presets -- the built-in
## ones, put on an image as a group of adjustment layers, their look on a
## picture, presets made from layers, kept in a file and read back, and a
## batch of files.

import std/os
import retroui/[gfx, imaging, photo, photodevelop, photopresets]

proc photo(w, h: int): Doc =
  result = newDoc(w, h)
  let L = result.layer
  for y in 0 ..< h:
    for x in 0 ..< w:
      L.px[y * w + x] = argb(255, x * 255 div w, y * 255 div h, (x + y) * 127 div (w + h) + 64)
  inc L.ver
  result.markAll()

block builtIn:
  let ps = builtinPresets()
  doAssert ps.len >= 30, $ps.len
  for c in PresetCategories:
    var n = 0
    for p in ps:
      if p.category == c: inc n
    doAssert n >= 5, c & ": " & $n
  for p in ps:
    doAssert p.steps.len > 0, p.name
    for s in p.steps: doAssert adjustmentFn(s.adjust) != nil, p.name & ": " & s.adjust.kind

block onAnImage:
  let d = photo(64, 48)
  let before = d.toBitmap.px
  let ps = builtinPresets()
  var p: AdjPreset
  for q in ps:
    if q.name == "Vintage Film": p = q
  doAssert p.steps.len == 3
  d.beginStep("Adjustment Preset")
  let g = d.applyPreset(p)
  d.endStep()
  doAssert g != nil and g.group and g.name == "Vintage Film"
  doAssert d.layers.len == 1 + 1 + 3, $d.layers.len
  var adj = 0
  for L in d.layers:
    if L.adjust.kind.len > 0: inc adj
  doAssert adj == 3
  d.updateComposite()
  let after = d.toBitmap.px
  doAssert after != before, "the look changed the picture"
  # the look on a picture: as the layers make it (the layers read a table
  # between its colors: a little off)
  let look = presetLook(before, 64, 48, p)
  var worst = 0
  for i in 0 ..< look.len:
    for sh in [16, 8, 0]:
      worst = max(worst, abs(int((look[i] shr sh) and 255) - int((after[i] shr sh) and 255)))
  doAssert worst <= 12, "presetLook is what the layers show: " & $worst
  # undone: as it was
  d.undo()
  doAssert d.layers.len == 1
  # a black & white one: gray
  for q in ps:
    if q.name == "Classic B&W":
      let o = presetLook(before, 64, 48, q)
      for v in o: doAssert rOf(v) == gOf(v) and gOf(v) == bOf(v)

block yoursInAFile:
  let d = photo(32, 24)
  discard d.newAdjustmentLayer(adjCurves([(0, 20), (255, 230)]))
  discard d.newAdjustmentLayer(adjVibrance(30, 5))
  d.layers[^1].opacity = 60
  d.layers[^1].mode = bmSoftLight
  let p = d.presetFromLayers("Mine", "My Presets", @[1, 2, 0])
  doAssert p.steps.len == 2 and p.steps[0].adjust.kind == "Curves" and p.steps[1].opacity == 60
  doAssert p.steps[1].mode == bmSoftLight
  let path = getTempDir() / "retro-presets-test.radj"
  savePresetFile(path, [p, builtinPresets()[0]])
  let back = loadPresetFile(path)
  doAssert back.len == 2 and back[0] == p, $back[0]
  writeFile(path, "{\"x\": 1}")
  var refused = false
  try: discard loadPresetFile(path)
  except IOError: refused = true
  doAssert refused
  removeFile(path)

block batch:
  let dir = getTempDir() / "retro-preset-batch"
  removeDir(dir)
  createDir(dir)
  let d = photo(40, 30)
  discard d.toBitmap.savePng(dir / "a.png")
  let p = builtinPresets()[^1]               # Day for Night: darker
  applyPresetToFile(dir / "a.png", dir / "a-night.jpg", p)
  applyPresetToFile(dir / "a.png", dir / "a-night.png", p)
  let o = loadPicture(dir / "a-night.png")
  let i0 = loadPicture(dir / "a.png")
  doAssert o != nil and o.w == 40 and o.h == 30
  var s0, s1 = 0
  for k in 0 ..< o.px.len:
    s0 += rOf(i0.px[k]) + gOf(i0.px[k]) + bOf(i0.px[k])
    s1 += rOf(o.px[k]) + gOf(o.px[k]) + bOf(o.px[k])
  doAssert s1 < s0 * 3 div 4, "Day for Night is darker"
  doAssert getFileSize(dir / "a-night.jpg") > 100
  var failed = false
  try: applyPresetToFile(dir / "none.png", dir / "x.png", p)
  except IOError: failed = true
  doAssert failed
  removeDir(dir)

echo "test_presets: ok"
