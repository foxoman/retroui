## The GPU renderer against the CPU one: the photo editor's frames (menus,
## palettes, icons, a picture with a see-through part, the marching ants,
## text at 100 % and 200 %) drawn both ways must be the same pixels. Off
## screen (EGL, a pbuffer); skipped where there is no OpenGL.

import std/[os, strutils]
import retroui/uirelays/[input, eglload, screen]
import harness

const photoUnderTest = true
include ../examples/photo

let home = getTempDir() / "retro-gpu-test"
removeDir(home)
createDir(home)
putEnv("HOME", home)
setCurrentDir(home)
putEnv("RETRO_GPU", "1")                 # (llvmpipe counts: it is what there is here)

var egl: Egl
if not egl.openOffscreen(W, H):
  echo "gpu tests skipped: no OpenGL here"
  quit 0
eglload.current = egl
gpuRelays = GpuRelays(
  startGpu: proc (): bool = true,
  stopGpu: proc () = discard,
  swapGpu: proc (): bool = true,
  gpuProc: proc (name: cstring): pointer = eglload.current.glProc(name),
  gpuIsEs: proc (): bool = true,
  gpuGeneration: proc (): int = 0,
  gpuReady: proc (): bool = true)

fakeDriver()
setup()
startApp("photo", W, H)
view = photoFrame

proc compare(what: string) =
  ## The frame now on the GPU, and the same drawn on the CPU.
  # (the same moment each time: what moves -- the ants, a sliding tab -- is
  # where it was)
  let t0 = ticks
  setGpuMode(gmGpu)
  invalidate()
  run(1)
  ticks = t0
  doAssert drawnWithGpu(), "the GPU draws"
  let g = gpuSnapshot()
  setGpuMode(gmCpu)
  invalidate()
  run(1)
  ticks = t0
  let cpu1 = pixels
  invalidate()
  run(1)
  ticks = t0
  doAssert cpu1 == pixels, what & ": the frame is still changing"
  doAssert not drawnWithGpu()
  var worst = 0
  var off = 0
  for i in 0 ..< W * H:
    let a = g[i]
    let b = pixels[i] and 0xFFFFFF'u32
    var m = 0
    for k in 0 .. 2:
      m = max(m, abs(int((a shr (8 * k)) and 255) - int((b shr (8 * k)) and 255)))
    worst = max(worst, m)
    if m > 2: inc off
  echo what, ": ", off, " pixels off by more than 2 (worst ", worst, ")"
  if off > 0:
    var bx0, by0 = 100000
    var bx1, by1 = -1
    for i in 0 ..< W * H:
      let a = g[i]
      let b = pixels[i] and 0xFFFFFF'u32
      var m = 0
      for k in 0 .. 2: m = max(m, abs(int((a shr (8 * k)) and 255) - int((b shr (8 * k)) and 255)))
      if m > 2:
        bx0 = min(bx0, i mod W); bx1 = max(bx1, i mod W); by0 = min(by0, i div W); by1 = max(by1, i div W)
    echo "  where: ", bx0, ",", by0, " .. ", bx1, ",", by1
    for (name, img) in [("gpu", g), ("cpu", pixels)]:
      var f = "P6\n" & $W & " " & $H & "\n255\n"
      for p in img: f.add char((p shr 16) and 255); f.add char((p shr 8) and 255); f.add char(p and 255)
      writeFile(getTempDir() / ("diff-" & name & ".ppm"), f)
  doAssert off <= W * H div 2000, what & ": the GPU draws it differently"
  setGpuMode(gmGpu)

run(3)
compare("no picture")
let d = newDoc(300, 200, white, name = "gpu")
let L = d.addLayer("see-through")
for y in 0 ..< 200:
  for x in 0 ..< 300:
    L.px[y * 300 + x] = argb(x * 255 div 300, x mod 256, y mod 256, 180)
inc L.ver
d.markAll()
addDoc(d)
run(3)
compare("a picture")
d.setSelection(d.rectMask(rect(20, 30, 150, 100)))
run(2)
compare("a selection")
runCommand("Zoom In")
run(2)
compare("zoomed in")
# painted on: only what changed sent to the GPU again
setGpuMode(gmGpu)
run(1)
for y in 50 ..< 80:
  for x in 60 ..< 120: L.px[y * 300 + x] = 0xFF0000FF'u32
inc L.ver
d.markDirty(rect(60, 50, 60, 30))
run(1)
compare("painted on")
# zoomed out: the half-size copy, on the GPU as on the CPU
let big = newDoc(1200, 900, white, name = "big")
let B = big.layer
for y in 0 ..< 900:
  for x in 0 ..< 1200:
    B.px[y * 1200 + x] = argb(255, x * 255 div 1200, (x xor y) and 255, y * 255 div 900)
inc B.ver
big.markAll()
addDoc(big)
run(2)
active.view.setZoom(big, -2)
run(30)                                  # (the tabs slide to the new one first)
compare("zoomed out 1:2")
# an eyedropper's pixel from anywhere: read from the GPU's frame as it is drawn
setGpuMode(gmGpu)
invalidate()
run(1)
let shot = gpuSnapshot()
for (x, y) in [(W div 2, H div 2), (20, 60), (W - 30, 100)]:
  readScreenPixel(x, y)
  run(1)
  let (done, c) = screenPixelRead()
  doAssert done and (c and 0xFFFFFF'u32) == shot[y * W + x], $(x, y) & ": " & toHex(c) & " " & toHex(shot[y * W + x])
# the Arabic interface: the frame mirrored, the picture and its checkerboard where their view
# is, as the CPU has them (the GPU drew them where the frame would be unmirrored: off to one side)
prefs.language = 1
applyLanguage()
run(4)
compare("Arabic interface")
for dw in docs:
  if dw.doc == d: showDoc(dw)
run(30)
compare("Arabic interface, a see-through picture")
prefs.language = 0
applyLanguage()
run(4)
# the Glass look: rounded shapes everywhere -- on the GPU a card's middle and sides rectangles,
# its corners small masks; on the CPU spans -- and the faces shaded from top to foot
let themeBefore = ui.theme
for (lookName, look) in [("Glass", lookGlass), ("Matte", lookMatte), ("Gloss", lookGloss)]:
  # (and Matte's flat faces, Gloss's shine, its pinstripes and its lit bars)
  uiLook = look
  let (l, d) = lookSchemes(look)
  for (name, t) in [("light", l), ("dark", d)]:
    ui.theme = t
    run(4)
    compare("the " & lookName & " look, " & name)
uiLook = lookClassic
ui.theme = themeBefore
run(2)
echo "gpu tests passed"
