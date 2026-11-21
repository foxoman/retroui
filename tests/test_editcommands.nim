## Edit > Fade (`fadeLast`): a blur made half as strong, then in another mode, its own step,
## undone; nothing to fade after a step that left the layer's pixels alone. Paste in Place
## (`pasteAsLayer(keepPlace)`). The Spin and Path blurs. Scale Effects; Create Layers (a
## style's effects as layers of their own, the look kept). Split and Merge Channels, there and
## back. Proofs for color blindness. Sums in number boxes (`evalNumber`).

import std/[math, strutils]
import retroui/[gfx, photo, photofx, photowarp, photostyles, widgets]

var failures = 0
template check(cond: bool; what: string) =
  if cond: echo "  ok   ", what
  else:
    echo "  FAIL ", what
    inc failures

proc stripes(w, h: int): Doc =
  result = newDoc(w, h, 0xFFFFFFFF'u32, name = "photo.png")
  let L = result.layer
  for y in 0 ..< h:
    for x in 0 ..< w:
      L.px[y * w + x] = if (x div 8) mod 2 == 0: 0xFF000000'u32 else: 0xFFFFFFFF'u32
  inc L.ver
  result.markAll()

proc r(p: uint32): int = int((p shr 16) and 255)

block fade:
  let d = stripes(64, 64)
  let before = d.layer.px
  d.beginStep("Gaussian Blur")
  d.applyFilter(12, gaussianBlur(4.0))
  d.endStep()
  let blurred = d.layer.px
  check blurred != before, "blurred"
  check d.fadeLast(50), "faded to 50%"
  check d.undoName == "Fade Gaussian Blur", "a step of its own: " & d.undoName
  var off = 0
  for i in 0 ..< before.len:
    let want = (r(before[i]) + r(blurred[i])) div 2
    off = max(off, abs(r(d.layer.px[i]) - want))
  check off <= 1, "half way between before and after (" & $off & ")"
  d.undo()
  check d.layer.px == blurred, "undone: the blur as it was"
  check d.fadeLast(100, bmMultiply), "faded in Multiply"
  var darker = true
  for i in 0 ..< before.len:
    if r(d.layer.px[i]) > min(r(before[i]), r(blurred[i])) + 1: darker = false
  check darker, "Multiply: never lighter than either"
  d.undo()
  d.dropRedo()
  check not d.canRedo, "a fade tried and taken back leaves nothing to redo"
  # (a step that changed no pixels of the layer: nothing to fade)
  d.beginStep("Rename")
  d.touchLayers()
  d.layer.name = "Backdrop"
  d.endStep()
  check not d.fadeLast(50), "nothing to fade after a rename"

block pasteInPlace:
  let d = stripes(40, 40)
  var c = Clip(w: 20, h: 20, x: 30, y: 30, px: newSeq[uint32](400))
  for p in c.px.mitems: p = 0xFFFF0000'u32
  d.beginStep("Paste")
  d.touchLayers()
  let L = d.pasteAsLayer(c, keepPlace = true)
  d.endStep()
  check (L.px[35 * 40 + 35] and 0xFFFFFF'u32) == 0xFF0000'u32 and L.px[10 * 40 + 10] == 0,
        "where it was copied from, what falls past the edge cut off"
  d.beginStep("Paste")
  d.touchLayers()
  let M = d.pasteAsLayer(c)
  d.endStep()
  check (M.px[20 * 40 + 20] and 0xFFFFFF'u32) == 0xFF0000'u32, "plain Paste: in the middle when it would not fit"

block spinAndPath:
  var im = newImg(80, 80)
  for y in 0 ..< 80:
    for x in 0 ..< 80:
      im.px[y * 80 + x] = if (x div 4) mod 2 == 0: 0xFF000000'u32 else: 0xFFFFFFFF'u32
  let sp = spinBlurImg(im, 40, 40, 30, 30, 0, 90)
  check sp.px[10 * 80 + 10] == im.px[10 * 80 + 10], "Spin: the corner (outside the circle) untouched"
  let v = r(sp.px[40 * 80 + 60])
  check v > 30 and v < 225, "Spin: a stripe inside smeared to a gray (" & $v & ")"
  let still = spinBlurImg(im, 40, 40, 30, 30, 0, 0)
  check still.px == im.px, "Spin of nothing: as it was"
  let along = pathBlurImg(im, [(0.0, 40.0), (80.0, 40.0)], 16)
  let a = r(along.px[40 * 80 + 41])
  check a > 30 and a < 225, "Path across the stripes: smeared to a gray (" & $a & ")"
  var stripesDown = newImg(80, 80)
  for y in 0 ..< 80:
    for x in 0 ..< 80:
      stripesDown.px[y * 80 + x] = if (x div 4) mod 2 == 0: 0xFF000000'u32 else: 0xFFFFFFFF'u32
  let down = pathBlurImg(stripesDown, [(40.0, 0.0), (40.0, 80.0)], 16)
  check r(down.px[40 * 80 + 41]) == r(stripesDown.px[40 * 80 + 41]), "Path along the stripes: they stay sharp"

block styles:
  var fx = LayerFx()
  fx.fx[fxDropShadow] = defaultEffect(fxDropShadow)
  fx.fx[fxDropShadow].distance = 10
  fx.fx[fxDropShadow].size = 6
  fx.fx[fxStroke] = defaultEffect(fxStroke)
  fx.fx[fxStroke].size = 4
  var big = fx
  big.scaleEffects(200)
  check big.fx[fxDropShadow].distance == 20 and big.fx[fxDropShadow].size == 12 and big.fx[fxStroke].size == 8,
        "Scale Effects 200%: distances and sizes doubled"
  # Create Layers: the shadow under, the stroke (inside) over, clipped; the look kept
  fx.fx[fxStroke].style = 1
  let d = newDoc(60, 60, 0xFFFFFFFF'u32)
  let L = d.addLayer("Box")
  for y in 20 ..< 40:
    for x in 20 ..< 40: L.px[y * 60 + x] = 0xFF2060C0'u32
  inc L.ver
  L.fx = fx
  d.markAll()
  d.updateComposite()
  let look = d.compCopy
  d.beginStep("Create Layers")
  d.touchLayers()
  let n = d.createEffectLayers(L)
  d.endStep()
  check n == 2, "two layers made (" & $n & ")"
  let at = d.layers.find(L)
  check at >= 1 and d.layers[at - 1].name == "Box's Drop Shadow" and d.layers[at + 1].name == "Box's Stroke" and
        d.layers[at + 1].clipped and not L.hasStyle, "the shadow under it, the stroke over it clipped, the style gone"
  d.updateComposite()
  let now = d.compCopy
  var worst = 0
  for i in 0 ..< look.len:
    worst = max(worst, abs(r(look[i]) - r(now[i])))
  check worst <= 40, "it looks as it did (" & $worst & ")"
  d.undo()
  check L.hasStyle and d.layers.len == 2, "undone: the style back, the layers gone"

block channels:
  let d = newDoc(4, 4, 0xFF336699'u32, name = "sky.png")
  let parts = d.splitChannels()
  check parts.len == 3 and parts[0].name == "sky_Red" and parts[2].name == "sky_Blue", "three, named for them"
  check r(parts[0].px[0]) == 0x33 and r(parts[1].px[0]) == 0x66 and r(parts[2].px[0]) == 0x99, "each its channel as a gray"
  let back = mergeChannels([parts[0].px, parts[1].px, parts[2].px])
  check back.len == 16 and back[5] == 0xFF336699'u32, "merged: the color again"
  check mergeChannels([parts[0].px, parts[1].px]).len == 0, "too few: nothing"
  let swapped = mergeChannels([parts[2].px, parts[1].px, parts[0].px])
  check swapped[0] == 0xFF996633'u32, "red and blue swapped"

block colorBlind:
  let red = 0xFFFF0000'u32
  let green = 0xFF00A000'u32
  let pr = colorBlind(red, 1)
  let pg = colorBlind(green, 1)
  check colorBlind(red, 0) == red, "off: as it is"
  check abs(r(pr) - r(pg)) < 120, "Protanopia: red and green much alike"
  let gray = 0xFF808080'u32
  check abs(r(colorBlind(gray, 2)) - 0x80) <= 3, "Deuteranopia: a gray stays gray"

block sums:
  var v = 0.0
  check evalNumber("1200/2", v) and v == 600, "1200/2 is 600"
  check evalNumber("40 + 15", v) and v == 55, "40 + 15"
  check evalNumber("3*(8-2)", v) and v == 18, "brackets"
  check evalNumber("-2.5", v) and v == -2.5, "a negative decimal"
  check evalNumber("1,250", v) and v == 1250, "thousands"
  v = 7
  check not evalNumber("12*", v) and v == 7, "not finished: left alone"
  check not evalNumber("5/0", v), "divided by nothing: no"
  check not evalNumber("", v), "nothing: no"

if failures > 0:
  echo "test_editcommands: ", failures, " failed"
  quit(1)
echo "test_editcommands: all passed"
