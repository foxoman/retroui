## Tests of `retroui/photoanim`: frames made from layers, shown, synced with
## the layers, tweened, composited, flattened into layers, opened from
## frames, kept in a .rpd.

import std/os
import retroui/[photo, photoanim]

proc solid(d: Doc; L: Layer; c: uint32; x0, y0, w, h: int) =
  for y in y0 ..< y0 + h:
    for x in x0 ..< x0 + w: L.px[y * d.w + x] = c
  inc L.ver

block framesFromLayers:
  let d = newDoc(40, 20, 0xFFFFFFFF'u32)
  let a = d.addLayer("A")
  d.solid(a, 0xFFFF0000'u32, 0, 0, 10, 10)
  let b = d.addLayer("B")
  d.solid(b, 0xFF0000FF'u32, 20, 5, 10, 10)
  d.framesFromLayers(150)
  doAssert d.frames.len == 2
  doAssert a.visible and not b.visible
  d.showFrame(1)
  doAssert b.visible and not a.visible and d.layers[0].visible, "the Background under each"
  let shots = d.animationFrames()
  doAssert shots.len == 2 and shots[0].delay == 150
  doAssert shots[0].px[0] == 0xFFFF0000'u32 and shots[0].px[5 * 40 + 25] == 0xFFFFFFFF'u32
  doAssert shots[1].px[5 * 40 + 25] == 0xFF0000FF'u32 and shots[1].px[0] == 0xFFFFFFFF'u32
  doAssert d.frameCur == 1, "the frame shown kept"

block syncAndMove:
  let d = newDoc(40, 20, 0xFFFFFFFF'u32)
  let a = d.addLayer("A")
  d.solid(a, 0xFFFF0000'u32, 0, 0, 5, 5)
  d.ensureFrames()
  d.addFrame()
  doAssert d.frames.len == 2 and d.frameCur == 1
  # moved and faded in frame 2 only
  d.shiftLayers(@[a], 20, 10)
  a.opacity = 50
  d.syncFrame()
  d.showFrame(0)
  doAssert a.opacity == 100 and a.px[0] == 0xFFFF0000'u32, "frame 1 as it was"
  d.showFrame(1)
  doAssert a.opacity == 50 and a.px[10 * 40 + 20] == 0xFFFF0000'u32 and a.px[0] == 0
  # tweened: in between
  d.tweenFrames(0, 1, 3)
  doAssert d.frames.len == 5
  d.showFrame(2)
  doAssert a.opacity in 70 .. 80 and a.px[5 * 40 + 10] == 0xFFFF0000'u32, $a.opacity

block openAndKeep:
  var fr: seq[tuple[px: seq[uint32]; delay: int]]
  for k in 0 ..< 3:
    var px = newSeq[uint32](16)
    for v in px.mitems: v = argb(255, k * 100, 0, 0)
    fr.add (px, 80 + k * 10)
  let d = docFromFrames(4, 4, fr, "anim", loop = 2)
  doAssert d.layers.len == 3 and d.frames.len == 3 and d.animLoop == 2
  let shots = d.animationFrames()
  doAssert shots[2].px[0] == argb(255, 200, 0, 0) and shots[1].delay == 90
  let p = getTempDir() / "anim.rpd"
  saveRpd(d, p)
  let e = loadRpd(p)
  doAssert e.frames.len == 3 and e.animLoop == 2 and e.frames[2].delay == 100
  e.showFrame(2)
  doAssert e.layers[2].visible and not e.layers[0].visible
  removeFile(p)
  # flattened into layers
  d.flattenFramesIntoLayers()
  doAssert d.layers.len == 6 and d.layers[^1].px[0] == argb(255, 200, 0, 0)

echo "photoanim: all passed"
