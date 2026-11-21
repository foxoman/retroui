## Painting behind the stroke (`deferDabs`, `paintDabs`, `strokeInk`): the dabs kept as they are
## placed and painted later -- all at once at the end, or some in each frame's spare time -- give
## the very pixels of painting each at once, with jitter, scatter, symmetry, a fade and the dual
## brush; a dab slower than the frame's time waits for the end (or the pen resting); the whole
## stroke shows as ink (its tip, sizes, strength, color) until `endStroke`; one step undoes it; the
## eraser, the smudge and other modes are painted at once. Then the canvas: the picture held as it
## was while the stroke's ink is drawn over it, the ink growing dab by dab, on the CPU and (off
## screen, EGL) on the GPU straight into a picture of its own -- the two within a few levels --,
## the picture as it is once the stroke ends.

import std/[os, math, strutils]
import retroui/uirelays/[coords, eglload, screen]
import retroui
import retroui/[photo, photopaint, photowidgets, ink]
import harness

var failures = 0
template check(cond: bool; what: string) =
  if cond: echo "  ok   ", what
  else:
    echo "  FAIL ", what
    inc failures

proc picture(): Doc =
  result = newDoc(400, 300, 0xFFFFFFFF'u32)
  for y in 0 ..< 300:
    for x in 0 ..< 400: result.layers[0].px[y * 400 + x] = argb(255, x * 255 div 400, y * 255 div 300, 128)
  inc result.layers[0].ver

proc lively(): (PaintOpts, BrushTip) =
  var o = PaintOpts(tool: tkBrush, color: 0xFF2040C0'u32, bg: 0xFFFFCC00'u32, opacity: 80)
  o.dyn = BrushDynamics(sizeJitter: 40, minDiameter: 20, angleJitter: 30, roundJitter: 30, scatter: 60,
                        count: 2, countJitter: 50, opacityJitter: 30, flow: 70, flowJitter: 20,
                        fgBgJitter: 30, symmetry: syVertical, sizeControl: dcFade, sizeFade: 60)
  o.fade = 50
  o.fadeToBg = true
  o.dual = hardTip(12)
  o.dualScatter = 50
  var t = softTip(40)
  t.roundness = 70
  t.angle = 25
  (o, t)

proc strokeOf(d: Doc; deferIt: bool; budget = -1.0): (int, int) =
  ## (a stroke across the picture; the most dabs left at once and how many dabs were painted
  ## while it went)
  let (o, t) = lively()
  d.beginStep("Brush")
  var s = d.beginStroke(o, t, 30, 40)
  if deferIt: s.deferDabs()
  check s.deferred == deferIt, "painted behind it: " & $deferIt
  s.startStroke()
  var most = 0
  for k in 1 .. 30:
    s.strokeTo(30 + k.float * 11, 40 + sin(k.float / 4) * 90 + k.float * 4, 0.4 + 0.02 * k.float)
    if deferIt:
      most = max(most, s.dabsLeft)
      if budget >= 0: discard s.paintDabs(budget)
  let during = s.dabs
  s.endStroke()
  check s.dabsLeft == 0 and s.dabs == s.placed, "all its dabs painted at the end (" & $s.dabs & ")"
  d.endStep()
  (most, during)

block same:
  let a = picture()
  let b = picture()
  let c = picture()
  discard a.strokeOf(false)
  let (most, during) = b.strokeOf(true)
  let (_, some) = c.strokeOf(true, budget = 50)
  var diffB = 0
  var diffC = 0
  for i in 0 ..< a.layers[0].px.len:
    if a.layers[0].px[i] != b.layers[0].px[i]: inc diffB
    if a.layers[0].px[i] != c.layers[0].px[i]: inc diffC
  check most > 0 and during == 0, "dabs kept while the pen moves, none painted (" & $most & ")"
  check diffB == 0, "painted at the end: the very pixels (" & $diffB & " differ)"
  check some > 0, "some painted in the frames' time (" & $some & ")"
  check diffC == 0, "painted as the frames allowed: the very pixels (" & $diffC & " differ)"
  c.undo()
  let fresh = picture()
  check c.layers[0].px == fresh.layers[0].px, "one step undoes it"

block budget:
  let d = picture()
  d.beginStep("Brush")
  var s = d.beginStroke(PaintOpts(tool: tkBrush, color: 0xFFCC2200'u32, opacity: 60), softTip(120), 50, 150)
  check not s.bigDabs, "120 pixels: not big"
  s.deferDabs()
  s.startStroke()
  s.strokeTo(350, 150)
  let placed = s.placed
  check placed > 8 and s.dabs == 0 and s.dabsLeft == placed, "placed, none painted yet (" & $placed & ")"
  let ink = s.strokeInk()
  check ink.id > 0 and ink.dabs.len == placed and ink.color == 0xFFCC2200'u32 and abs(ink.opacity - 0.6) < 0.01,
        "the ink: each dab, its color, the stroke's opacity"
  check ink.tip.mw >= 2 and ink.tip.mask.len == ink.tip.mw * ink.tip.mh and
        ink.tip.mask[(ink.tip.mh div 2) * ink.tip.mw + ink.tip.mw div 2] > 200 and ink.tip.mask[0] < 20,
        "its tip: the brush's, strong in the middle, nothing in the corner"
  check abs(ink.dabs[0].size - 122) < 4 and abs(ink.dabs[0].x - 50) < 0.01 and abs(ink.dabs[^1].x - 350) < 31,
        "sized and placed as the dabs will be (" & $ink.dabs[0].size & ")"
  check s.paintDabs(1e-6) == placed and s.dabs == 0, "a dab slower than the frame's time: none painted"
  let left = s.paintDabs(1e-6, one = true)
  check left == placed - 1 and s.dabs == 1, "the pen resting: one painted all the same, the rest left"
  check s.paintDabs(1e-6) == left, "... and none more until the end"
  check s.strokeInk().dabs.len == placed, "the ink: the whole stroke, painted or not"
  s.endStroke()
  check s.dabsLeft == 0 and s.strokeInk().dabs.len == 0, "the end: none left, no ink"
  d.endStep()
  var big = d.beginStroke(PaintOpts(tool: tkBrush, opacity: 100), softTip(800), 100, 100)
  check big.bigDabs, "800 pixels: big"
  big.endStroke()
  # painted at once: the eraser, the smudge, another mode, Wet Edges
  for (what, o) in [("the eraser", PaintOpts(tool: tkEraser, opacity: 100)),
                    ("the smudge", PaintOpts(tool: tkSmudge, opacity: 50)),
                    ("Multiply", PaintOpts(tool: tkBrush, opacity: 100, mode: bmMultiply)),
                    ("Wet Edges", PaintOpts(tool: tkBrush, opacity: 100, wet: true))]:
    d.beginStep(what)
    var e = d.beginStroke(o, softTip(60), 100, 100)
    e.deferDabs()
    e.startStroke()
    e.strokeTo(200, 100)
    check not e.deferred and e.dabsLeft == 0 and e.dabs > 0 and e.strokeInk().id == 0, what & ": painted at once"
    e.endStroke()
    d.endStep()

# ---- the canvas -------------------------------------------------------------------------------------------

putEnv("RETRO_GPU", "1")
var egl: Egl
let haveGl = egl.openOffscreen(W, H)
if haveGl:
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
let doc = newDoc(200, 150, 0xFFFFFFFF'u32)
var pv = initPhotoView()
pv.fitWanted = false
pv.zoom = 1
var dabs: seq[InkDab]
for k in 0 ..< 6: dabs.add InkDab(x: 40 + k.float32 * 24, y: 75, size: 50, roundness: 1, opacity: 0.5)
let tip = InkTip(mask: tipTexture(InkTip(hardness: 0.5)).px, mw: InkTipSide, mh: InkTipSide)
pv.ink = StrokeInk(id: 1, tip: tip, dabs: dabs[0 .. 2], color: 0xFFE02010'u32, opacity: 0.8)
view = proc () =
  discard photoView(doc, pv)

proc paintBlue(d: Doc; x, y: int) =
  ## (the picture changed under the ink, as the stroke's dabs are painted behind it)
  for yy in y ..< y + 10:
    for xx in x ..< x + 10: d.layers[0].px[yy * d.w + xx] = 0xFF0000FF'u32
  inc d.layers[0].ver
  d.markDirty(rect(x, y, 10, 10))

startApp("paint behind", W, H)
setGpuMode(gmCpu)
run(3)
let (mx, my) = pv.toScreen(doc, 100, 75)
let (ex, ey) = pv.toScreen(doc, 100, 140)
let (bx, by) = pv.toScreen(doc, 15, 135)
let (fx, fy) = pv.toScreen(doc, 136, 75)
check px(fx, fy) == 0xFFFFFF'u32 and px(mx, my) != 0xFFFFFF'u32, "the first three dabs: none yet where the fifth goes"
pv.ink.dabs = dabs                                 # (three more placed)
doc.paintBlue(10, 130)
run(2)
let cpuMid = px(mx, my)
check ((cpuMid shr 16) and 255) > 200 and (cpuMid and 255) < 120 and ((cpuMid shr 8) and 255) < 150,
      "the CPU: the ink grown over the picture, red where the dabs are (" & $cpuMid.toHex & ")"
check px(ex, ey) == 0xFFFFFF'u32 and px(fx, fy) != 0xFFFFFF'u32, "... white past them"
check px(bx, by) == 0xFFFFFF'u32, "the picture held as it was while the stroke is painted behind it"
pv.ink = StrokeInk()
run(2)
check px(bx, by) == 0x0000FF'u32 and px(mx, my) == 0xFFFFFF'u32, "the stroke ended: the picture as it is, no ink"
if haveGl:
  pv.ink = StrokeInk(id: 2, tip: tip, dabs: dabs[0 .. 2], color: 0xFFE02010'u32, opacity: 0.8)
  setGpuMode(gmGpu)
  run(4)
  check drawnWithGpu(), "the GPU draws"
  pv.ink.dabs = dabs
  doc.paintBlue(30, 130)
  run(3)
  let g = gpuSnapshot()
  if g.len == W * H:
    let gm = g[my * W + mx] and 0xFFFFFF'u32
    var worst = 0
    for sh in [16, 8, 0]: worst = max(worst, abs(int((gm shr sh) and 255) - int((cpuMid shr sh) and 255)))
    check worst <= 6, "the GPU: the CPU's ink within a few levels (" & $gm.toHex & ", " & $worst & ")"
    check (g[ey * W + ex] and 0xFFFFFF'u32) == 0xFFFFFF'u32, "... white past them"
    let (cx, cy) = pv.toScreen(doc, 35, 135)
    check (g[cy * W + cx] and 0xFFFFFF'u32) == 0xFFFFFF'u32, "... the picture held on the GPU too"
    pv.ink = StrokeInk()
    run(3)
    let g2 = gpuSnapshot()
    check (g2[cy * W + cx] and 0xFFFFFF'u32) == 0x0000FF'u32, "... and as it is once the stroke ends"
  else: check false, "a frame read back from the GPU"
else:
  echo "  (no OpenGL here: the GPU's ink not tried)"

if failures > 0:
  echo "test_paintbehind: ", failures, " failed"
  quit(1)
echo "test_paintbehind: all passed"
