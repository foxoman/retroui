## Tests of `retroui/photodeep`: 16 and 32 bits a channel for real -- Levels
## and Curves read between their tables, changes of each pixel through a
## table of them, the blurs and sharpening on floats, a tool's 8-bit change
## kept only where it changed, undo of the 16 bits, the .rpd keeping them,
## the image composited at 16 bits, the gradient at 16 bits.

import std/[os, sets, math]
import retroui/[gfx, photo, photofx, photohdr, photodeep, photopaint]
{.push warning[UnusedImport]: off.}
import retroui/photodevelop   # (imported for what it sets up in retroui/photo: the adjustment layers' tables)
{.pop.}

let S = getTempDir()

proc ramp(w, h: int; lo, hi: int): Doc =
  ## A 16-bit document: a gentle ramp across (`lo` .. `hi` of 65535).
  result = newDoc(w, h, 0xFF808080'u32)
  result.setDepth(16)
  var v = newSeq[uint16](w * h * 4)
  for y in 0 ..< h:
    for x in 0 ..< w:
      let t = uint16(lo + (hi - lo) * x div max(1, w - 1))
      let i = (y * w + x) * 4
      v[i] = t; v[i + 1] = t; v[i + 2] = t; v[i + 3] = 65535
  result.setHi(result.layer, v)

proc distinct16(d: Doc; L: Layer; ch = 0): int =
  var s = initHashSet[uint16]()
  let hi = d.hiPixels(L)
  for i in 0 ..< d.w * d.h: s.incl hi[4 * i + ch]
  s.len

proc distinct8(d: Doc; L: Layer): int =
  var s = initHashSet[uint32]()
  for p in L.px: s.incl((p shr 16) and 255)
  s.len

proc consistent(d: Doc; L: Layer): bool =
  for i in 0 ..< d.w * d.h:
    let p = L.px[i]
    if to8(L.hi[4 * i]) != ((p shr 16) and 255) or to8(L.hi[4 * i + 3]) != (p shr 24): return false
  true

block levelsAt16:
  # a ramp 3 levels tall stretched to all of them: smooth at 16 bits
  let d = ramp(1024, 4, 116 * 257, 119 * 257)
  doAssert d.distinct8(d.layer) <= 4
  var lv = defaultLevels()
  lv.inLo = 116
  lv.inHi = 119
  d.beginStep("Levels")
  d.applyFilter(0, applyLuts(levelsLut(lv), identityLut(), identityLut(), identityLut()))
  d.endStep()
  let n16 = d.distinct16(d.layer)
  doAssert n16 > 500, "16 bits: " & $n16 & " values"
  doAssert d.distinct8(d.layer) > 200, "its 8 bits made from them: " & $d.distinct8(d.layer) & " " & $d.layer.px[500]
  doAssert d.consistent(d.layer)
  # undone: the 16 bits as they were
  let before = ramp(1024, 4, 116 * 257, 119 * 257).layer.hi
  d.undo()
  doAssert d.layer.hi == before, "undo brings the 16 bits back"
  d.redo()
  doAssert d.distinct16(d.layer) == n16

block pointAt16:
  # a change of each pixel by itself (Invert as a function): through its table
  let d = ramp(512, 2, 1000, 3000)
  d.beginStep("Invert")
  d.applyFilter(0, mapFn(proc (p: uint32): uint32 = argb(aOf(p), 255 - rOf(p), 255 - gOf(p), 255 - bOf(p))))
  d.endStep()
  let hi = d.layer.hi
  doAssert abs(int(hi[0]) - (65535 - 1000)) < 300, $hi[0]
  doAssert d.distinct16(d.layer) > 300
  doAssert d.consistent(d.layer)

block toolAt8:
  # a tool changing pixels at 8 bits: there they are 8 bits, elsewhere their 16 kept
  let d = ramp(64, 4, 30000, 30100)
  let was = d.layer.hi
  d.beginStep("Brush")
  d.touch(d.layer, rect(0, 0, 4, 1))
  for x in 0 ..< 4: d.layer.px[x] = 0xFFFF0000'u32
  d.endStep()
  let hi = d.hiPixels(d.layer)
  doAssert hi[0] == 65535 and hi[1] == 0
  doAssert hi[4 * 10] == was[4 * 10], "the untouched pixels keep their 16 bits"
  d.undo()
  doAssert d.layer.hi == was

block blurAt16:
  # a hard edge blurred at 16 bits: many more steps than 8 bits have
  let d = newDoc(400, 3, 0xFF000000'u32)
  d.setDepth(16)
  var v = newSeq[uint16](400 * 3 * 4)
  for i in 0 ..< 400 * 3:
    let x = i mod 400
    let t = if x >= 200: 2000'u16 else: 1000'u16
    v[4 * i] = t; v[4 * i + 1] = t; v[4 * i + 2] = t; v[4 * i + 3] = 65535
  d.setHi(d.layer, v)
  d.beginStep("Gaussian Blur")
  d.applyFilter(60, gaussianBlur(30))
  d.endStep()
  # (8 bits would have 5 steps here: 1000 to 2000 of 65535 is 4 to 8; three
  # box passes, as the 8-bit blur makes a big radius, give one a pixel)
  doAssert d.distinct16(d.layer) > 60, $d.distinct16(d.layer)
  let hi = d.layer.hi
  for x in 1 ..< 400: doAssert hi[4 * (400 + x)] >= hi[4 * (400 + x - 1)], "smooth, rising"
  doAssert d.consistent(d.layer)

block sharpenAt16:
  let d = ramp(200, 3, 20000, 40000)
  d.beginStep("Unsharp Mask")
  d.applyFilter(10, unsharpMask(100, 2.0, 0))
  d.endStep()
  doAssert d.consistent(d.layer)

block selectionAt16:
  # only the selection changed, at 16 bits
  let d = ramp(100, 2, 10000, 20000)
  let was = d.layer.hi
  d.sel = newSeq[uint8](d.w * d.h)
  for i in 0 ..< 50: d.sel[i] = 255
  inc d.selVer
  d.beginStep("Invert")
  d.applyFilter(0, applyLuts(curveLut([(0, 255), (255, 0)]), identityLut(), identityLut(), identityLut()))
  d.endStep()
  doAssert d.layer.hi[4 * 10] > 40000 and d.layer.hi[4 * 60] == was[4 * 60]

block rpdKeeps16:
  let d = ramp(300, 2, 30000, 30300)
  let p = S / "deep16.rpd"
  saveRpd(d, p)
  let e = loadRpd(p)
  doAssert e != nil and e.depth == 16
  doAssert e.hiPixels(e.layer) == d.layer.hi, "the 16 bits kept in the .rpd"
  removeFile(p)

block composite16:
  # two layers at 16 bits: the top one at 50 %
  let d = ramp(256, 2, 0, 65535)
  let L2 = d.addLayer("Top")
  var v = newSeq[uint16](256 * 2 * 4)
  for i in 0 ..< 512:
    v[4 * i] = 50000; v[4 * i + 1] = 10000; v[4 * i + 2] = 30001; v[4 * i + 3] = 65535
  d.setHi(L2, v)
  L2.opacity = 50
  let f = d.flattened16()
  let lo = d.layers[0].hi
  for i in [0, 100, 255]:
    let want = (int(lo[4 * i]) + 50000) div 2
    doAssert abs(int(f[4 * i]) - want) <= 2, $i & ": " & $f[4 * i] & " vs " & $want
  doAssert f[4 * 5 + 2] mod 257 != 0 or f[4 * 6 + 2] mod 257 != 0, "really 16 bits"
  # an adjustment layer (Invert) at 16 bits, close to the 8-bit composite
  L2.opacity = 0
  let A = d.newAdjustmentLayer(Adjustment(kind: "Invert"))
  doAssert A != nil
  let g = d.flattened16()
  d.updateComposite()
  for i in [3, 77, 200]:
    let c8 = int((d.compPtr[i] shr 16) and 255) * 257
    doAssert abs(int(g[4 * i]) - c8) <= 2 * 257, $i & ": " & $g[4 * i] & " vs " & $c8
  doAssert abs(int(g[4 * 77]) - (65535 - int(lo[4 * 77]))) <= 300

block hdrBlurAndLevels:
  # 32 bits: a blur in light, and Levels keeping what is brighter than white
  let d = newDoc(64, 2, 0xFF000000'u32)
  d.toHdr()
  for i in 0 ..< 128:
    let x = i mod 64
    let v = if x == 32: 8.0'f32 else: 0.1'f32
    d.layer.hdr[4 * i] = v; d.layer.hdr[4 * i + 1] = v; d.layer.hdr[4 * i + 2] = v
  d.hdrToPx(d.layer)               # (what is shown made from the light set)
  d.beginStep("Gaussian Blur")
  d.applyFilter(20, gaussianBlur(2))
  d.endStep()
  let h = d.layer.hdr
  var total = 0.0
  for x in 0 ..< 64: total += h[4 * x]
  doAssert abs(total - (8.0 + 63 * 0.1)) < 0.05, "light kept as it spreads: " & $total
  doAssert h[4 * 33] > 1.0, "brighter than white beside it"
  d.beginStep("Curves")
  d.applyFilter(0, applyLuts(curveLut([(0, 0), (128, 160), (255, 255)]), identityLut(), identityLut(), identityLut()))
  d.endStep()
  doAssert d.layer.hdr[4 * 32] > 1.0, "past white kept"

block gradient16:
  let d = newDoc(1000, 1, 0xFF000000'u32)
  d.setDepth(16)
  d.beginStep("Gradient")
  d.gradientDeep(d.layer, d.bounds, 1, proc (x, y: int): array[4, float32] =
    let t = float32(x) / 999 * 0.02 + 0.5
    [float32(t), float32(t), float32(t), 1'f32])
  d.endStep()
  doAssert d.distinct16(d.layer) > 900, $d.distinct16(d.layer)
  doAssert d.consistent(d.layer)
  # the Gradient tool itself, at 16 bits
  let e = newDoc(2000, 1, 0xFF000000'u32)
  e.setDepth(16)
  e.beginStep("Gradient")
  e.gradientFill(0, 0, 2000, 0, PaintOpts(opacity: 100, mode: bmNormal),
                 @[GradientStop(at: 0, color: 0xFF404040'u32, mid: 0.5), GradientStop(at: 1, color: 0xFF484848'u32)])
  e.endStep()
  doAssert e.distinct16(e.layer) > 1500, $e.distinct16(e.layer)

echo "photodeep: all passed"

block geometryKeeps16:
  # crop, canvas, flip, turn, resize, rotate: the 16 bits go along
  let d = ramp(64, 32, 30000, 30200)
  let at = proc (d: Doc; x, y: int): uint16 = d.hiPixels(d.layer)[(y * d.w + x) * 4]
  let v = at(d, 40, 5)
  d.crop(rect(8, 2, 50, 20))
  doAssert d.w == 50 and at(d, 32, 3) == v
  d.flipImage(true)
  doAssert at(d, 50 - 1 - 32, 3) == v
  d.rotateImage(1)
  doAssert d.w == 20 and d.h == 50
  d.canvasSizeAt(30, 60, 5, 5, 0xFFFFFFFF'u32)
  doAssert d.w == 30 and d.distinct16(d.layer) > 40
  d.imageSize(60, 120)
  doAssert d.w == 60 and d.hiValid(d.layer) and d.distinct16(d.layer) > 100, $d.distinct16(d.layer)
  doAssert d.consistent(d.layer)
  d.rotateArbitrary(10, 0xFFFFFFFF'u32)
  doAssert d.hiValid(d.layer) and d.consistent(d.layer) and d.distinct16(d.layer) > 100
  # 32 bits: the light kept through a resize
  let e = newDoc(40, 20, 0xFF000000'u32)
  e.toHdr()
  for i in 0 ..< 800: e.layer.hdr[4 * i] = 5.0
  e.hdrToPx(e.layer)
  e.imageSize(80, 40)
  doAssert e.layer.hdr.len == 80 * 40 * 4 and abs(e.layer.hdr[4 * 100] - 5.0) < 0.01
echo "photodeep geometry: passed"
