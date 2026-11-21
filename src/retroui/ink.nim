## Ink: a stroke drawn as dabs of a tip -- round with a hard or soft edge, or a tip of your own
## -- spaced along it, each one's size and opacity from the pen's pressure, turned, squashed,
## scattered, stamped over a picture (or taking it away, an eraser). On the GPU when frames are
## drawn with it (`gpuStampDabs`: the dabs drawn into a texture, read back), else on the CPU --
## the same pixels within a few levels: the CPU does what the GPU does, the tip read between its
## pixels, each dab put down in 8 bits a channel, colors multiplied by their alpha.
##
## ```nim
## var s = InkStroke(size: 24, flow: 0.8, sizeByPressure: true)
## var carry = 0'f32
## let dabs = dabsAlong([(10'f32, 10'f32, 0.3'f32), (200, 80, 1.0)], s, carry)
## discard stampInk(px, w, h, InkTip(hardness: 0.6), dabs, 0xFF2266AA'u32)
## ```
##
## Developed by Sultan Al Isaiee @foxoman -- www.foxoman.net -- sultan@foxoman.net

import std/[math, random]
import gfx, parallel

type
  InkTip* = object
    ## What a dab is: round, its edge `hardness` (0 soft .. 1 hard), or `mask` (`mw` x `mh`, 0..255:
    ## a tip of its own, its middle at the mask's middle).
    hardness*: float32
    mask*: seq[uint8]
    mw*, mh*: int

  InkDab* = object
    ## One dab: its middle, how far across, turned (degrees), squashed (`roundness` 0..1, 1 round),
    ## its opacity (0..1, the stroke's flow).
    x*, y*: float32
    size*: float32
    angle*: float32
    roundness*: float32
    opacity*: float32

  InkPoint* = tuple[x, y, pressure: float32]
    ## A point of a stroke, its pressure 0..1 (a mouse: 1).

  InkStroke* = object
    ## A stroke's settings (`dabsAlong`).
    size*: float32             ## the dabs across at full pressure (pixels)
    spacing*: float32          ## between dabs, a part of their size (0: 0.25)
    flow*: float32             ## each dab's opacity at full pressure, 0..1 (0: 1)
    sizeByPressure*: bool      ## lighter pressure, smaller dabs (to a tenth)
    opacityByPressure*: bool   ## lighter pressure, fainter dabs
    angle*: float32            ## the dabs turned, degrees
    roundness*: float32        ## 0..1 (0: 1, round)
    sizeJitter*: float32       ## 0..1: each dab smaller by up to so much, at random
    angleJitter*: float32      ## 0..1: each dab turned up to so much of a full turn, at random
    scatter*: float32          ## 0..1: each dab moved aside up to so much of its size, at random
    seed*: int                 ## the randomness (the same seed, the same stroke)

const InkTipSide* = 64
  ## A round tip's texture, pixels across.

var gpuInkMinPixels* = 4096
  ## `stampInk` asks the GPU only when the dabs cover at least this many pixels (fewer: the CPU is
  ## quicker than the trip to the GPU and back).

proc tipTexture*(t: InkTip): tuple[px: seq[uint8]; w, h: int] =
  ## The tip as the dabs read it: a round one `InkTipSide` across, its edge falling off smoothly
  ## by its hardness; a tip of its own as it is.
  if t.mask.len > 0 and t.mask.len == t.mw * t.mh and t.mw >= 2 and t.mh >= 2:
    return (t.mask, t.mw, t.mh)
  let n = InkTipSide
  result = (newSeq[uint8](n * n), n, n)
  let hard = clamp(t.hardness, 0, 1)
  for y in 0 ..< n:
    for x in 0 ..< n:
      let dx = (x.float32 + 0.5'f32) / n.float32 * 2 - 1
      let dy = (y.float32 + 0.5'f32) / n.float32 * 2 - 1
      let r = sqrt(dx * dx + dy * dy)
      # (full inside the hard part, a smooth fall to the edge; the last half pixel softened)
      let inner = hard * 0.98'f32
      var a = if r <= inner: 1'f32
              elif r >= 1: 0'f32
              else:
                let k = (r - inner) / max(1e-4'f32, 1 - inner)
                (1 - k) * (1 - k) * (1 + 2 * k)
      result.px[y * n + x] = uint8(clamp(int(a * 255 + 0.5), 0, 255))

proc dabsAlong*(pts: openArray[InkPoint]; s: InkStroke; carry: var float32): seq[InkDab] =
  ## The dabs of a stroke through `pts`, `spacing` apart (pressure read between the points);
  ## `carry`: how far along the next dab goes -- start a stroke at 0 (a dab at once), keep it
  ## between the parts of one stroke drawn as it goes.
  if pts.len == 0 or s.size <= 0: return
  var rng = initRand(max(1, s.seed) + int(max(0, carry) * 1000))
  let step0 = max(0.5'f32, s.size * (if s.spacing > 0: s.spacing else: 0.25'f32))
  let flow = if s.flow > 0: clamp(s.flow, 0, 1) else: 1'f32
  let round0 = if s.roundness > 0: clamp(s.roundness, 0.01, 1) else: 1'f32
  proc dabAt(x, y, p: float32): InkDab =
    var size = s.size * (if s.sizeByPressure: max(0.1'f32, p) else: 1'f32)
    if s.sizeJitter > 0: size *= 1 - clamp(s.sizeJitter, 0, 1) * rng.rand(1.0).float32
    var ang = s.angle
    if s.angleJitter > 0: ang += (rng.rand(2.0).float32 - 1) * 180 * clamp(s.angleJitter, 0, 1)
    var (dx, dy) = (0'f32, 0'f32)
    if s.scatter > 0:
      let a = rng.rand(2 * PI).float32
      let r = rng.rand(1.0).float32 * clamp(s.scatter, 0, 1) * size
      (dx, dy) = (cos(a) * r, sin(a) * r)
    InkDab(x: x + dx, y: y + dy, size: max(0.5'f32, size), angle: ang, roundness: round0,
           opacity: flow * (if s.opacityByPressure: clamp(p, 0, 1) else: 1'f32))
  if pts.len == 1:
    if carry <= 0:
      result.add dabAt(pts[0].x, pts[0].y, pts[0].pressure)
      carry = step0
    return
  var pos = max(0'f32, carry)          # (how far along this part the next dab goes)
  for i in 1 ..< pts.len:
    let (x0, y0, p0) = pts[i - 1]
    let (x1, y1, p1) = pts[i]
    let len = hypot(x1 - x0, y1 - y0)
    if len < 1e-6: continue
    while pos <= len:
      let t = pos / len
      result.add dabAt(x0 + (x1 - x0) * t, y0 + (y1 - y0) * t, p0 + (p1 - p0) * t)
      pos += step0
    pos -= len
  carry = pos

proc dabBox(d: InkDab): (float32, float32, float32, float32) =
  ## (the dab's bounds: x0, y0, x1, y1)
  let r = d.size / 2 * 1.42'f32
  (d.x - r, d.y - r, d.x + r, d.y + r)

proc dabQuads*(dabs: openArray[InkDab]; ox = 0'f32; oy = 0'f32): seq[float32] =
  ## The dabs as the GPU draws them: two triangles each, 6 corners of x, y (less `ox`, `oy`),
  ## u, v (into the tip) and the dab's opacity.
  result = newSeqOfCap[float32](dabs.len * 30)
  for d0 in dabs:
    let d = d0
    let a = degToRad(d.angle)
    let (ca, sa) = (cos(a), sin(a))
    let hx = d.size / 2
    let hy = d.size / 2 * d.roundness
    template corner(u, v: float32): array[5, float32] =
      let lx = (u * 2 - 1) * hx
      let ly = (v * 2 - 1) * hy
      [d.x - ox + lx * ca - ly * sa, d.y - oy + lx * sa + ly * ca, u, v, d.opacity]
    let c00 = corner(0, 0)
    let c10 = corner(1, 0)
    let c01 = corner(0, 1)
    let c11 = corner(1, 1)
    for c in [c00, c10, c01, c01, c10, c11]:
      for v in c: result.add v

{.push boundChecks: off, overflowChecks: off.}

proc sampleTip(t: openArray[uint8]; w, h: int; u, v: float32): float32 {.inline.} =
  ## (the tip at `u`, `v` (0..1) read between its pixels, edges held: as the GPU's linear filter)
  let fx = u * w.float32 - 0.5'f32
  let fy = v * h.float32 - 0.5'f32
  let x0 = int(floor(fx))
  let y0 = int(floor(fy))
  let tx = fx - x0.float32
  let ty = fy - y0.float32
  template at(x, y: int): float32 = t[clamp(y, 0, h - 1) * w + clamp(x, 0, w - 1)].float32
  let a = at(x0, y0) + (at(x0 + 1, y0) - at(x0, y0)) * tx
  let b = at(x0, y0 + 1) + (at(x0 + 1, y0 + 1) - at(x0, y0 + 1)) * tx
  (a + (b - a) * ty) / 255

proc stampCpu*(pre: var seq[uint32]; w, h: int; tip: openArray[uint8]; tw, th: int; dabs: openArray[InkDab];
               color: uint32; erase = false; ox = 0'f32; oy = 0'f32) =
  ## The dabs (`ox`, `oy` taken from their places) put down over `pre` (`w` x `h`, its colors
  ## multiplied by alpha) on the CPU, one after another, each in 8 bits a channel -- as the GPU
  ## does them.
  let cr = float32((color shr 16) and 255) / 255
  let cg = float32((color shr 8) and 255) / 255
  let cb = float32(color and 255) / 255
  let pp = cast[ptr UncheckedArray[uint32]](if pre.len > 0: addr pre[0] else: nil)
  let tp = @tip
  for d in dabs:
    let (bx0, by0, bx1, by1) = dabBox(d)
    let x0 = max(0, int(floor(bx0 - ox)))
    let y0 = max(0, int(floor(by0 - oy)))
    let x1 = min(w - 1, int(ceil(bx1 - ox)))
    let y1 = min(h - 1, int(ceil(by1 - oy)))
    if x1 < x0 or y1 < y0: continue
    let a = degToRad(d.angle)
    let (ca, sa) = (cos(a), sin(a))
    let hx = max(1e-4'f32, d.size / 2)
    let hy = max(1e-4'f32, d.size / 2 * d.roundness)
    let dd = d
    parallelRows(y1 - y0 + 1, ry):
      let y = y0 + ry
      for x in x0 .. x1:
        let px = x.float32 + 0.5'f32 + ox - dd.x
        let py = y.float32 + 0.5'f32 + oy - dd.y
        let lx = px * ca + py * sa
        let ly = -px * sa + py * ca
        let u = (lx / hx + 1) / 2
        let v = (ly / hy + 1) / 2
        if u < 0 or u > 1 or v < 0 or v > 1: continue
        let al = sampleTip(tp, tw, th, u, v) * dd.opacity
        if al <= 0: continue
        let i = y * w + x
        let q = pp[i]
        template ch(sh: int; c: float32): uint32 =
          let dv = float32((q shr sh) and 255)
          let o = if erase: dv * (1 - al) else: c * al * 255 + dv * (1 - al)
          uint32(clamp(int(o + 0.5'f32), 0, 255)) shl sh
        pp[i] = ch(24, 1'f32) or ch(16, cr) or ch(8, cg) or ch(0, cb)

{.pop.}

proc premultiplied(p: uint32): uint32 {.inline.} =
  let a = p shr 24
  if a == 255: return p
  if a == 0: return 0
  template m(sh: int): uint32 = ((((p shr sh) and 255) * a + 127) div 255) shl sh
  (a shl 24) or m(16) or m(8) or m(0)

proc straight(p: uint32): uint32 {.inline.} =
  let a = p shr 24
  if a == 255 or a == 0: return (if a == 0: 0'u32 else: p)
  template d(sh: int): uint32 = min(255'u32, (((p shr sh) and 255) * 255 + a div 2) div a) shl sh
  (a shl 24) or d(16) or d(8) or d(0)

proc stampInk*(px: var seq[uint32]; w, h: int; tip: InkTip; dabs: openArray[InkDab]; color: uint32;
               erase = false; useGpu = true): tuple[r: Rect; gpu: bool] =
  ## The dabs stamped over `px` (`w` x `h`, straight ARGB) in `color`, over what is there -- or
  ## (`erase`) taking it away -- on the GPU when it can (`useGpu`, frames drawn with it, the dabs
  ## covering `gpuInkMinPixels` or more), else on the CPU. The rectangle it changed, and whether the
  ## GPU did it.
  if dabs.len == 0 or px.len != w * h: return
  var bx0 = Inf.float32
  var by0 = Inf.float32
  var bx1 = -Inf.float32
  var by1 = -Inf.float32
  for d in dabs:
    let (a, b, c, e) = dabBox(d)
    bx0 = min(bx0, a); by0 = min(by0, b); bx1 = max(bx1, c); by1 = max(by1, e)
  let x0 = max(0, int(floor(bx0)))
  let y0 = max(0, int(floor(by0)))
  let x1 = min(w, int(ceil(bx1)) + 1)
  let y1 = min(h, int(ceil(by1)) + 1)
  if x1 <= x0 or y1 <= y0: return
  let rw = x1 - x0
  let rh = y1 - y0
  result.r = Rect(x: x0, y: y0, w: rw, h: rh)
  var part = newSeq[uint32](rw * rh)
  for y in 0 ..< rh:
    for x in 0 ..< rw: part[y * rw + x] = premultiplied(px[(y0 + y) * w + x0 + x])
  let t = tipTexture(tip)
  var done = false
  if useGpu and rw * rh >= gpuInkMinPixels and gpuFiltersReady():
    let q = dabQuads(dabs, x0.float32, y0.float32)
    let o = gpuStampDabs(part, rw, rh, t.px, t.w, t.h, q, color, erase)
    if o.len == part.len:
      part = o
      done = true
      result.gpu = true
  if not done: stampCpu(part, rw, rh, t.px, t.w, t.h, dabs, color, erase, x0.float32, y0.float32)
  for y in 0 ..< rh:
    for x in 0 ..< rw: px[(y0 + y) * w + x0 + x] = straight(part[y * rw + x])
