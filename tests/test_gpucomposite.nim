## Layers mixed on the GPU (retroui/photogpu) against the CPU's composite:
## every blend mode, masks (feathered, less dense), opacity and fill,
## groups mixing through and on their own, clipping masks (onto a layer, an
## adjustment layer, a group), adjustment layers (tables by channel and of
## all colors), Darker / Lighter Color ties, tiles, what is sent again, the
## features left to the CPU, the hook, and the guard's choice by timings.
## Off screen (EGL); skipped where there is no OpenGL.

import std/[os, strutils, tables, monotimes, times]
import retroui/[gfx, photo, photogpu]
import retroui/uirelays/[eglload, screen]

putEnv("RETRO_GPU", "1")                 # (llvmpipe counts: it is what there is here)
var egl: Egl
if not egl.openOffscreen(64, 64):
  echo "gpu composite tests skipped: no OpenGL here"
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
setGpuMode(gmGpu)
discard present(64, 64, true)
doAssert drawnWithGpu(), "the GPU draws"
doAssert gpuFiltersReady(), "the GPU can draw into textures"
doAssert gpuCompositeReady(), "the first check: the GPU mixes as the CPU"
echo "renderer: ", gpuDescription()

# ---- helpers ----------------------------------------------------------------------------------------------

proc rnd(i, seed: int): int = int(hash2(i, seed * 7919 + 13))

proc fillNoise(d: Doc; L: Layer; seed: int; alphas: openArray[int]) =
  ## Random colors (and smooth runs, flat patches) with alphas from `alphas`.
  for y in 0 ..< d.h:
    for x in 0 ..< d.w:
      let i = y * d.w + x
      let v = rnd(i, seed)
      let a = alphas[(v shr 24) mod alphas.len]
      L.px[i] =
        case (x div 16 + y div 16 + seed) mod 3
        of 0: argb(a, v and 255, (v shr 8) and 255, (v shr 16) and 255)
        of 1: argb(a, (x * 3 + seed) and 255, (y * 5) and 255, (x + y) and 255)
        else: argb(a, [0, 255, 128, 37][seed and 3], [255, 0, 200, 90][(x div 16) and 3], (y * 2) and 255)
  inc L.ver

proc pixLayer(d: Doc; name: string; mode = bmNormal; opacity = 100; seed = 1;
              alphas: openArray[int] = [0, 64, 160, 255]; depth = 0): Layer =
  result = d.newLayer(name)
  result.mode = mode
  result.opacity = opacity
  result.depth = depth
  d.fillNoise(result, seed, alphas)
  d.layers.add result

proc maskLayer(d: Doc; seed: int): Layer =
  result = d.newLayer("mask")
  for y in 0 ..< d.h:
    for x in 0 ..< d.w:
      let v = if ((x div 8) + seed) mod 4 == 0: rnd(y * d.w + x, seed) and 255
              elif ((x div 8) + seed) mod 4 == 1: 0
              elif ((x div 8) + seed) mod 4 == 2: 255
              else: (x * 255 div max(1, d.w - 1))
      result.px[y * d.w + x] = argb(255, v, v, v)

proc group(d: Doc; name: string; passThrough: bool; mode = bmNormal; opacity = 100; depth = 0): Layer =
  result = Layer(name: name, group: true, passThrough: passThrough, mode: mode, opacity: opacity,
                 visible: true, depth: depth, px: newSeq[uint32](d.w * d.h))
  d.layers.add result

proc adjustLayer(d: Doc; kind: string; args: seq[float]; mode = bmNormal; opacity = 100;
                 seed = 0; depth = 0): Layer =
  ## An adjustment layer: its pixels (its mask) all white, or (seed > 0) varied.
  result = d.newLayer(kind)
  result.adjust = Adjustment(kind: kind, args: args)
  result.mode = mode
  result.opacity = opacity
  result.depth = depth
  for i in 0 ..< d.w * d.h:
    result.px[i] = if seed == 0: 0xFFFFFFFF'u32
                   else: argb([255, 128, 0, 255][rnd(i, seed) and 3], rnd(i, seed + 1) and 255, 0, 0)
  d.layers.add result

proc cpuComposite(d: Doc): seq[uint32] =
  result = newSeq[uint32](d.w * d.h)
  d.compositeInto(result, d.bounds, d.layers)

proc gpuOut(d: Doc; r = rect(0, 0, 0, 0)): seq[uint32] =
  if d.comp.len != d.w * d.h: d.comp = newSeq[uint32](d.w * d.h)
  doAssert gpuComposite(d, if r.w > 0: r else: d.bounds), "made on the GPU: " &
    gpuCompositeStats.lastReason
  d.comp

proc maxDiff(a, b: seq[uint32]): tuple[worst, off: int] =
  doAssert a.len == b.len
  for i in 0 ..< a.len:
    var m = 0
    for sh in [0, 8, 16, 24]:
      m = max(m, abs(int((a[i] shr sh) and 255) - int((b[i] shr sh) and 255)))
    result.worst = max(result.worst, m)
    if m > 0: inc result.off

var worstAll = 0
proc check(name: string; d: Doc; limit = 1): int =
  ## The CPU's composite and the GPU's: no channel more than `limit` apart.
  let cpu = d.cpuComposite()
  let gpu = d.gpuOut()
  let (w, off) = maxDiff(cpu, gpu)
  worstAll = max(worstAll, w)
  if w > limit:
    for i in 0 ..< cpu.len:
      if cpu[i] != gpu[i]:
        echo "  first at ", i mod d.w, ",", i div d.w, ": cpu ", cpu[i].toHex, " gpu ", gpu[i].toHex
        break
  doAssert w <= limit, name & ": the GPU's pixels differ by " & $w
  if off > 0: echo "  ", name, ": ", off, " of ", cpu.len, " pixels off by ", w
  w

# ---- every blend mode -------------------------------------------------------------------------------------

const W = 150
const H = 110
var modeDiff: OrderedTable[BlendMode, int]
for m in LayerModes:
  if m == bmDissolve: continue
  var worst = 0
  # over pixels of every alpha, the layer see-through, at 80 % opacity, 90 % fill, with a mask
  block:
    let d = newDoc(W, H, 0)
    d.fillNoise(d.layers[0], 3, [0, 1, 50, 128, 200, 254, 255])
    let L = d.pixLayer("mode", m, 80, 5, [0, 1, 30, 128, 254, 255])
    L.fill = 90
    L.mask = d.maskLayer(2)
    d.markAll()
    worst = max(worst, check($m & " (see-through)", d))
  # over an opaque Background, opaque, 100 % (the CPU's quick ways)
  block:
    let d = newDoc(W, H, 0xFF336699'u32)
    d.fillNoise(d.layers[0], 7, [255])
    discard d.pixLayer("mode", m, 100, 9, [255, 255, 255, 0, 77])
    d.markAll()
    worst = max(worst, check($m & " (opaque)", d))
  # an adjustment layer in this mode (a table of all colors, and one by channels)
  block:
    let d = newDoc(W, H, 0xFF000000'u32)
    d.fillNoise(d.layers[0], 11, [255, 255, 128, 0])
    discard d.adjustLayer("Hue/Saturation", @[0.0, 35, 25, 5], m, 85, seed = 4)
    discard d.adjustLayer("Curves", @[3.0, 0, 0, 100, 150, 255, 240, 2, 0, 20, 255, 255, 2, 0, 0, 255, 255,
                                      2, 0, 0, 255, 200], m, 100)
    d.markAll()
    worst = max(worst, check($m & " (adjustment)", d))
  modeDiff[m] = worst

# ---- the color modes: exact (what the GPU cannot be sure of made again on the CPU) -----------------------

block colorModes:
  for m in [bmHue, bmSaturation, bmColor, bmLuminosity]:
    let d = newDoc(512, 384, 0)
    d.fillNoise(d.layers[0], 201, [255, 255, 255, 140])
    discard d.pixLayer("m", m, 100, 202, [255, 255, 200])
    discard d.adjustLayer("Curves", @[3.0, 0, 0, 90, 160, 255, 255, 2, 0, 0, 255, 255, 2, 0, 0, 255, 255,
                                      2, 0, 0, 255, 255], m, 100)
    discard d.pixLayer("m2", m, 90, 203, [255, 128])
    d.markAll()
    let f0 = gpuCompositeStats.fixedPixels
    discard check($m & " stacked", d, limit = 0)
    let f = gpuCompositeStats.fixedPixels - f0
    echo $m, " stacked x3: exact; ", f, " of ", d.w * d.h, " pixels made again on the CPU (",
         formatFloat(f * 100 / (d.w * d.h), ffDecimal, 2), " %)"

# ---- groups, clipping, adjustments, masks ---------------------------------------------------------------

block groups:
  let d = newDoc(W, H, 0xFFFFFFFF'u32)
  d.fillNoise(d.layers[0], 21, [255])
  discard d.pixLayer("under", bmMultiply, 90, 22)
  # a group mixing through, 70 %, with a mask; layers clipped to it
  discard d.pixLayer("p1", bmScreen, 100, 23, depth = 1)
  var L = d.pixLayer("p1c", bmOverlay, 80, 24, depth = 1)
  L.clipped = true
  discard d.pixLayer("p2", bmHue, 100, 25, depth = 1)
  discard d.adjustLayer("Levels", @[10.0, 240, 1.4, 5, 250, 0, 255, 1, 0, 255, 0, 255, 1, 0, 255,
                                    0, 255, 1, 0, 255], bmNormal, 60, seed = 5, depth = 1)
  var G = d.group("pass", true, opacity = 70)
  G.mask = d.maskLayer(26)
  L = d.pixLayer("onPass", bmNormal, 100, 27)
  L.clipped = true
  L = d.pixLayer("onPass2", bmColorBurn, 100, 28)
  L.clipped = true
  # a group of its own (Soft Light, 85 %), a group inside, a mask on it
  discard d.pixLayer("i1", bmNormal, 100, 29, depth = 1)
  discard d.pixLayer("n1", bmDivide, 100, 30, depth = 2)
  L = d.pixLayer("n1c", bmLinearLight, 100, 31, depth = 2)
  L.clipped = true
  G = d.group("inner", false, bmMultiply, 75, depth = 1)
  G.mask = d.maskLayer(32)
  discard d.pixLayer("i2", bmLuminosity, 90, 33, depth = 1)
  G = d.group("iso", false, bmSoftLight, 85)
  L = d.pixLayer("onIso", bmDarken, 100, 34)
  L.clipped = true
  # an adjustment layer and a layer clipped to it; a hidden group; a hidden clip base
  let A = d.adjustLayer("Color Balance", @[20.0, -10, 5, 0, 15, -15, 5, 0, -5, 1], bmNormal, 100, seed = 6)
  A.mask = d.maskLayer(35)
  L = d.pixLayer("onAdjust", bmColor, 100, 36)
  L.clipped = true
  discard d.pixLayer("hid1", bmNormal, 100, 37, depth = 1)
  G = d.group("hidden", true)
  G.visible = false
  L = d.pixLayer("hiddenBase", bmNormal, 100, 38)
  L.visible = false
  L = d.pixLayer("onHidden", bmNormal, 100, 39)
  L.clipped = true
  # a pass-through group inside a pass-through group, covers kept at both
  discard d.pixLayer("pp", bmPinLight, 100, 40, depth = 2)
  G = d.group("pin", true, depth = 1)
  L = d.pixLayer("onPin", bmVividLight, 100, 41, depth = 1)
  L.clipped = true
  G = d.group("outerPass", true, opacity = 90)
  L = d.pixLayer("onOuter", bmExclusion, 70, 42)
  L.clipped = true
  # an isolated group in a pass-through one whose cover is kept
  discard d.pixLayer("q1", bmHardMix, 100, 43, depth = 2)
  discard d.group("isoIn", false, bmSubtract, 100, depth = 1)
  discard d.group("passOut", true, opacity = 100)
  L = d.pixLayer("onPassOut", bmLighterColor, 100, 44)
  L.clipped = true
  # masks feathered and less dense
  L = d.pixLayer("feathered", bmNormal, 90, 45)
  L.mask = d.maskLayer(46)
  L.maskFeather = 3.5
  L.maskDensity = 70
  L = d.pixLayer("dense", bmMultiply, 100, 47)
  L.mask = d.maskLayer(48)
  L.maskDensity = 40
  L.fill = 60
  d.markAll()
  echo "groups and clipping: worst ", check("groups and clipping", d)

block adjustments:
  let d = newDoc(W, H, 0)
  d.fillNoise(d.layers[0], 51, [0, 90, 255, 255])
  discard d.adjustLayer("Invert", @[], bmNormal, 50)
  discard d.adjustLayer("Levels", @[0.0, 255, 1, 0, 255, 30, 220, 0.8, 0, 255, 0, 255, 1.2, 10, 245,
                                    0, 255, 1, 0, 255], bmNormal, 100, seed = 52)
  discard d.adjustLayer("Hue/Saturation", @[1.0, 200, 40, 0], bmNormal, 100, seed = 53)
  discard d.adjustLayer("Channel Mixer", @[60.0, 30, 10, 0, 10, 80, 10, 0, 0, 20, 80, 5, 0], bmNormal, 90)
  discard d.adjustLayer("Brightness/Contrast", @[20.0, 30], bmLinearDodge, 70)
  let A = d.adjustLayer("Posterize", @[5.0], bmDarkerColor, 100, seed = 54)
  A.mask = d.maskLayer(55)
  # Clarity in a group does nothing (as on the CPU)
  discard d.pixLayer("inGroup", bmNormal, 100, 56, depth = 1)
  discard d.adjustLayer("Clarity", @[50.0], bmNormal, 100, depth = 1)
  discard d.group("withClarity", false)
  d.markAll()
  echo "adjustment layers: worst ", check("adjustment layers", d)

# ---- Darker / Lighter Color where both are as light: done again on the CPU ----------------------------------

block ties:
  for m in [bmDarkerColor, bmLighterColor]:
    let d = newDoc(W, H, 0xFF646464'u32)          # (100, 100, 100: 30 r + 59 g + 11 b = 10000)
    let L = d.pixLayer("tie", m, 100, 61, [255])
    for i in 0 ..< d.w * d.h:
      if i mod 3 != 0: L.px[i] = argb(255, 111, 100, 70)   # (3330 + 5900 + 770: as light)
    d.markAll()
    let before = gpuCompositeStats.fixedPixels
    let w = check($m & " ties", d, limit = 0)
    let fixed = gpuCompositeStats.fixedPixels - before
    echo $m, " ties: ", fixed, " pixels made again on the CPU, worst ", w
    doAssert fixed >= d.w * d.h div 2, "the ties were found"

# ---- tiles, a part of the image, what is sent again ----------------------------------------------------------

block tiles:
  let keep = gpuCompositeTile
  gpuCompositeTile = 64                          # (4 x 3 tiles of 64)
  let d = newDoc(230, 170, 0xFFFFFFFF'u32)
  d.fillNoise(d.layers[0], 71, [255])
  discard d.pixLayer("a", bmOverlay, 90, 72)
  let L = d.pixLayer("b", bmNormal, 70, 73)
  L.mask = d.maskLayer(74)
  discard d.pixLayer("c", bmHardLight, 100, 75, depth = 1)
  discard d.group("g", false, bmScreen, 80)
  d.markAll()
  discard check("tiles of 64", d)
  # only a part made: the rest of `comp` left as it was
  let cpu = d.cpuComposite()
  d.comp = newSeq[uint32](d.w * d.h)
  let part = rect(37, 21, 120, 100)
  discard d.gpuOut(part)
  for y in 0 ..< d.h:
    for x in 0 ..< d.w:
      let inside = x >= part.x and y >= part.y and x < part.x + part.w and y < part.y + part.h
      let i = y * d.w + x
      if inside: doAssert d.comp[i] == cpu[i], "the part made"
      else: doAssert d.comp[i] == 0, "nothing made outside the part"
  # painted on: only that rectangle of that layer sent again
  d.comp = cpu
  for y in 50 ..< 80:
    for x in 100 ..< 140: L.px[y * d.w + x] = 0xFF00FF00'u32
  inc L.ver
  d.markDirty(rect(100, 50, 40, 30))
  let sent0 = gpuCompositeStats.uploadedPixels
  discard d.gpuOut(d.dirty)
  let sent = gpuCompositeStats.uploadedPixels - sent0
  echo "painted 40 x 30: ", sent, " pixels sent again"
  doAssert sent == 40 * 30, "only what was painted sent again (" & $sent & ")"
  doAssert maxDiff(d.comp, d.cpuComposite()).worst == 0
  d.dirty = rect(0, 0, 0, 0)
  # the opacity changed: nothing sent
  L.opacity = 40
  d.markAll()
  let sent1 = gpuCompositeStats.uploadedPixels
  discard d.gpuOut()
  doAssert gpuCompositeStats.uploadedPixels == sent1, "nothing sent for a new opacity"
  doAssert maxDiff(d.comp, d.cpuComposite()).worst == 0
  # its pixels another buffer (undo swaps them whole): sent again
  var other = L.px
  for i in 0 ..< other.len: other[i] = other[i] xor 0x00FFFFFF'u32
  swap(L.px, other)
  inc L.ver
  d.markAll()
  discard d.gpuOut()
  doAssert maxDiff(d.comp, d.cpuComposite()).worst == 0, "another buffer: sent again"
  gpuCompositeTile = keep

# ---- what the GPU does not do: left to the CPU ---------------------------------------------------------------

block fallbacks:
  proc base(): Doc =
    result = newDoc(W, H, 0xFFFFFFFF'u32)
    result.fillNoise(result.layers[0], 81, [255])
    discard result.pixLayer("x", bmMultiply, 100, 82)
  var cases: seq[(string, Doc)]
  var d = base()
  d.layers[^1].blendIf = BlendIf(channel: 0, this: [0, 0, 120, 200], under: [0, 0, 0, 0])
  cases.add ("Blend If", d)
  d = base()
  d.layers[^1].mode = bmDissolve
  cases.add ("Dissolve", d)
  d = base()
  d.layers[^1].fx.fx[fxDropShadow] = Effect(on: true, mode: bmMultiply, opacity: 75, color: 0xFF000000'u32,
                                            angle: 120, distance: 4, size: 4)
  cases.add ("layer style", d)
  d = base()
  discard d.adjustLayer("Clarity", @[60.0])
  cases.add ("Clarity", d)
  d = base()
  d.depth = 16
  cases.add ("16-bit", d)
  d = base()
  discard d.pixLayer("in", bmNormal, 100, 83, depth = 1)
  discard d.group("dissolving", false, bmDissolve, 80)
  cases.add ("a Dissolve group", d)
  for (name, d) in cases:
    d.markAll()
    let why = gpuCompositeSupport(d)
    doAssert why.len > 0, name & ": not done on the GPU"
    d.comp = newSeq[uint32](d.w * d.h)
    doAssert not gpuComposite(d, d.bounds), name & ": left to the CPU"
    echo "left to the CPU: ", name, " (", why, ")"

# ---- the hook in updateComposite ----------------------------------------------------------------------------

block hook:
  let keepMin = gpuCompositeMinPixels
  gpuCompositeMinPixels = 1
  enableGpuComposite()
  doAssert gpuCompositeHook != nil
  proc doc(): Doc =
    result = newDoc(W, H, 0xFFFFFFFF'u32)
    result.fillNoise(result.layers[0], 91, [255])
    discard result.pixLayer("x", bmOverlay, 80, 92)
    discard result.pixLayer("y", bmColor, 100, 93)
    result.markAll()
  # on the GPU (the guard tries it first)
  gpuCompositeGuard = CompositeGuard()
  var d = doc()
  let ref1 = d.cpuComposite()
  let g0 = gpuCompositeStats.gpu
  d.updateComposite()
  doAssert gpuCompositeStats.gpu == g0 + 1, "made on the GPU"
  doAssert maxDiff(d.comp, ref1).worst <= 1
  # RETRO_GPU_COMPOSITE=0: the CPU
  putEnv("RETRO_GPU_COMPOSITE", "0")
  d = doc()
  let g1 = gpuCompositeStats.gpu
  d.updateComposite()
  doAssert gpuCompositeStats.gpu == g1, "RETRO_GPU_COMPOSITE=0: on the CPU"
  doAssert d.comp == d.cpuComposite()
  delEnv("RETRO_GPU_COMPOSITE")
  # a feature not done: the CPU, the same pixels
  d = doc()
  d.layers[^1].mode = bmDissolve
  d.markAll()
  let dec0 = gpuCompositeStats.declined
  d.updateComposite()
  doAssert gpuCompositeStats.declined == dec0 + 1
  doAssert d.comp == d.cpuComposite()
  # too small a part: not even asked
  gpuCompositeMinPixels = W * H + 1
  d = doc()
  let g2 = gpuCompositeStats.gpu
  d.updateComposite()
  doAssert gpuCompositeStats.gpu == g2
  doAssert d.comp == d.cpuComposite()
  # frames drawn on the CPU (Preferences: no graphics processor): not on the GPU
  gpuCompositeMinPixels = 1
  setGpuMode(gmCpu)                              # (stops the GPU: no frame drawn here, no screen)
  doAssert not gpuFiltersReady()
  d = doc()
  let g3 = gpuCompositeStats.gpu
  d.updateComposite()
  doAssert gpuCompositeStats.gpu == g3, "no GPU: the CPU"
  doAssert d.comp == d.cpuComposite()
  setGpuMode(gmGpu)
  discard present(64, 64, true)
  doAssert drawnWithGpu() and gpuCompositeReady(), "the GPU again (a new start: checked again)"
  d = doc()
  let g4 = gpuCompositeStats.gpu
  gpuCompositeGuard = CompositeGuard()
  d.updateComposite()
  doAssert gpuCompositeStats.gpu == g4 + 1, "on the GPU again"
  doAssert maxDiff(d.comp, d.cpuComposite()).worst <= 1
  enableGpuComposite(false)
  doAssert gpuCompositeHook == nil
  gpuCompositeMinPixels = keepMin

# ---- the guard: timings put in ----------------------------------------------------------------------------

block guard:
  const px = 3_000_000
  # the GPU three times slower: tried twice, the CPU twice, then the CPU -- the GPU tried again
  # now and then, less and less
  var g = CompositeGuard()
  var gpuRuns = 0
  for i in 0 ..< 400:
    let gpu = g.useGpu(px, 5)
    if gpu: inc gpuRuns
    g.record(gpu, px, 5, (if gpu: 0.3 else: 0.1))
  doAssert g.gpuQuicker(px) == 2, "the CPU found quicker"
  echo "GPU slower: tried on the GPU ", gpuRuns, " times in 400"
  doAssert gpuRuns >= 2 and gpuRuns <= 12, "the GPU rarely tried again"
  # ... and a part twice the size (no timings of its own): the CPU at once
  doAssert not g.useGpu(2 * px, 5)
  # the GPU quicker: used, the CPU tried again now and then
  g = CompositeGuard()
  var cpuRuns = 0
  for i in 0 ..< 400:
    let gpu = g.useGpu(px, 5)
    if not gpu: inc cpuRuns
    g.record(gpu, px, 5, (if gpu: 0.05 else: 0.2))
  doAssert g.gpuQuicker(px) == 1
  echo "GPU quicker: the CPU used ", cpuRuns, " times in 400"
  doAssert cpuRuns >= 2 and cpuRuns <= 12
  # the GPU gets slower (another document, a hot device): found, the CPU used from then on
  for i in 0 ..< 600:
    let gpu = g.useGpu(px, 5)
    g.record(gpu, px, 5, (if gpu: 0.5 else: 0.2))
  doAssert g.gpuQuicker(px) == 2, "the change found"
  # rates by pixels and steps: a part of 10 layers taking twice as long is as quick
  g = CompositeGuard()
  g.record(true, px, 10, 0.2)
  g.record(true, px, 10, 0.2)
  g.record(false, px, 5, 0.11)
  g.record(false, px, 5, 0.11)
  doAssert g.gpuQuicker(px) == 1, "per pixel and step"

# ---- how long, here -------------------------------------------------------------------------------------------

block timing:
  let d = newDoc(1600, 1200, 0xFFFFFFFF'u32)
  d.fillNoise(d.layers[0], 101, [255])
  for k in 0 ..< 6:
    discard d.pixLayer("t" & $k, [bmNormal, bmMultiply, bmScreen, bmOverlay, bmSoftLight, bmColor][k], 80, 102 + k)
  d.markAll()
  d.comp = newSeq[uint32](d.w * d.h)
  discard gpuComposite(d, d.bounds)               # (sent, programs made)
  var t0 = getMonoTime()
  discard gpuComposite(d, d.bounds)
  let tg = (getMonoTime() - t0).inMilliseconds
  let gpu = d.comp
  t0 = getMonoTime()
  let cpu = d.cpuComposite()
  let tc = (getMonoTime() - t0).inMilliseconds
  doAssert maxDiff(cpu, gpu).worst <= 1
  echo "1600 x 1200, 7 layers: GPU ", tg, " ms, CPU ", tc, " ms (", gpuDescription(), ")"

echo "worst difference by mode:"
var line = ""
for m, w in modeDiff:
  line.add $m & " " & $w & ", "
echo "  ", line
echo "worst anywhere: ", worstAll, "; passes drawn ", gpuCompositeStats.passes
releaseGpuComposite()
echo "gpu composite tests passed"
