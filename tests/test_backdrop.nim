## Frosted glass and masks (`backdropBlur`, `beginMask`): what is under a blur is smoothed, its
## rounded corners keep what is outside them; a mask keeps what is drawn in it inside its
## rounded corners; a change near a blur, or far from it, gives the pixels a whole frame does;
## the GPU draws them as the CPU does (where there is OpenGL).

import std/os
import retroui/uirelays/[coords, input, eglload, screen]
import retroui
import harness

fakeDriver()

const panel = rect(100, 80, 240, 160)
const ring = rect(420, 100, 120, 120)
var
  mover = rect(84, 120, 12, 12)        # (outside the panel, inside what its blur reads)
  far = rect(560, 400, 20, 20)
  tintA = 110
  word = "Frosted"

view = proc () =
  for i in 0 ..< W div 10:
    fill(rect(i * 10, 0, 5, H), if i mod 2 == 0: color(220, 40, 40) else: color(40, 90, 220))
  fill(mover, color(255, 255, 0))
  fill(far, color(0, 160, 0))
  backdropBlur(panel, 12, color(255, 255, 255, uint8(tintA)), 16)
  drawLabel(panel.x + 20, panel.y + 60, word, color(0, 0, 0), true)
  masked(ring, 60):
    fill(rect(ring.x - 20, ring.y - 20, ring.w + 40, ring.h + 40), color(250, 250, 250))
    masked(rect(ring.x + 30, ring.y + 30, 60, 60), 10):
      fill(rect(ring.x, ring.y, ring.w, ring.h), color(0, 0, 0))

proc px(x, y: int): uint32 = pixels[y * W + x] and 0xFFFFFF'u32
proc red(x, y: int): int = int((px(x, y) shr 16) and 255)

startApp("backdrop", W, H)
setGpuMode(gmCpu)
run(3)

block blurred:
  # (along a row in the panel's middle, the stripes nearly gone; outside it, as they are)
  var lo = 255
  var hi = 0
  for x in panel.x + 30 ..< panel.x + 200:
    lo = min(lo, red(x, panel.y + 20))
    hi = max(hi, red(x, panel.y + 20))
  doAssert hi - lo < 40, "smoothed: " & $lo & ".." & $hi
  doAssert red(panel.x + 30, panel.y + 20) > 120, "and lighter: the white over it"
  doAssert px(22, 300) == 0xDC2828'u32 and px(32, 300) == 0x285ADC'u32
  # (a rounded corner: outside it, the stripes)
  doAssert px(panel.x, panel.y) == px(panel.x, panel.y + panel.h + 2), "the corner kept"
  doAssert px(panel.x + 2, panel.y + 2) == 0xDC2828'u32 or px(panel.x + 2, panel.y + 2) == 0x285ADC'u32

block maskKept:
  doAssert px(ring.x + 60, ring.y + 10) == 0xFAFAFA'u32, "inside the circle"
  doAssert px(ring.x + 2, ring.y + 2) != 0xFAFAFA'u32, "its corner: what was under it"
  doAssert px(ring.x - 5, ring.y + 60) != 0xFAFAFA'u32, "clipped to its box"
  doAssert px(ring.x + 60, ring.y + 60) == 0, "the mask inside it"
  doAssert px(ring.x + 31, ring.y + 31) == 0xFAFAFA'u32, "its own corners"

proc sameAsWhole(what: string) =
  run(1)
  let part = pixels
  invalidate()
  run(1)
  var off = 0
  for i in 0 ..< W * H:
    if part[i] != pixels[i]: inc off
  doAssert off == 0, what & ": " & $off & " pixels differ from a whole frame"

block partFrames:
  let before = px(panel.x + 2, mover.y + 6)
  mover.x += 3                         # (what the blur reads changed)
  sameAsWhole("near the blur")
  doAssert px(panel.x + 2, mover.y + 6) != before, "the blur shows it"
  far.x -= 30                          # (far from it)
  sameAsWhole("far from the blur")
  tintA = 180                          # (the panel itself)
  sameAsWhole("the tint")
  word = "Frosted glass"               # (over it: its blur kept)
  sameAsWhole("the text over it")

# the GPU as the CPU
putEnv("RETRO_GPU", "1")
var egl: Egl
if not egl.openOffscreen(W, H):
  echo "test_backdrop: ok (no OpenGL here: the GPU not tried)"
  quit 0
eglload.current = egl
var age = 1
gpuRelays = GpuRelays(
  startGpu: proc (): bool = true,
  stopGpu: proc () = discard,
  swapGpu: proc (): bool = true,
  gpuProc: proc (name: cstring): pointer = eglload.current.glProc(name),
  gpuIsEs: proc (): bool = true,
  gpuGeneration: proc (): int = 0,
  gpuReady: proc (): bool = true,
  gpuBufferAge: proc (): int = age)

proc gpuLikeCpu(what: string) =
  setGpuMode(gmGpu)
  invalidate()
  run(2)
  doAssert drawnWithGpu()
  let g = gpuSnapshot()
  setGpuMode(gmCpu)
  invalidate()
  run(2)
  var off, worst = 0
  for i in 0 ..< W * H:
    let a = g[i]
    let b = pixels[i] and 0xFFFFFF'u32
    var m = 0
    for k in 0 .. 2: m = max(m, abs(int((a shr (8 * k)) and 255) - int((b shr (8 * k)) and 255)))
    worst = max(worst, m)
    if m > 3: inc off
  doAssert off == 0, what & ": " & $off & " pixels off by more than 3 (worst " & $worst & ")"

gpuLikeCpu("a frosted panel and masks")

block gpuParts:
  setGpuMode(gmGpu)
  for a in [1, 2, 0]:
    age = a
    invalidate()
    run(2)
    for what in ["near", "far", "tint", "text"]:
      case what
      of "near": mover.y += 4
      of "far": far.y -= 9
      of "tint": tintA = 60 + (tintA + 37) mod 150
      else: word.add "!"
      run(1)
      let part = gpuSnapshot()
      invalidate()
      run(1)
      let whole = gpuSnapshot()
      var off = 0
      let slack = if age == 0: 1 else: 0
      for i in 0 ..< W * H:
        for k in 0 .. 2:
          if abs(int((part[i] shr (8 * k)) and 255) - int((whole[i] shr (8 * k)) and 255)) > slack:
            inc off
            break
      doAssert off == 0, "GPU, age " & $a & ", " & what & ": " & $off & " pixels differ from a whole frame"

echo "test_backdrop: ok"
