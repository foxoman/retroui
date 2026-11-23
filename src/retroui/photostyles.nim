## Layer styles (Layer > Layer Style), made from a layer's pixels: Drop
## Shadow, Outer Glow, Pattern, Gradient and Color Overlay, Satin, Inner
## Glow, Inner Shadow, Stroke, Bevel and Emboss. Importing this module turns them on
## (`photo.layerFxRender`); a layer's style is in `Layer.fx`:
##
## ```nim
## L.fx.fx[fxDropShadow] = defaultEffect(fxDropShadow)   # on, as Photoshop sets it
## L.fx.fx[fxStroke] = defaultEffect(fxStroke)
## L.fx.fx[fxStroke].size = 4
## ```

import std/math
import gfx, photo, parallel

{.push boundChecks: off, overflowChecks: off.}

const
  StyleNames*: array[FxKind, string] = ["Drop Shadow", "Outer Glow", "Pattern Overlay", "Gradient Overlay",
                                        "Color Overlay", "Satin", "Inner Glow", "Inner Shadow", "Stroke",
                                        "Bevel and Emboss"]
    ## Each effect's name, as the Layer Style dialog shows it.
  BevelStyles* = ["Inner Bevel", "Outer Bevel", "Emboss", "Pillow Emboss"]
    ## Bevel and Emboss's styles, by `Effect.style`.
  StrokePositions* = ["Outside", "Inside", "Center"]
    ## Stroke's positions, by `Effect.style`.
  GradientStyles* = ["Linear", "Radial", "Angle", "Reflected", "Diamond"]
    ## Gradient Overlay's styles, by `Effect.style`.
  GlowSources* = ["Edge", "Center"]
    ## Inner Glow's sources, by `Effect.style`.
  DialogOrder*: array[10, FxKind] = [fxBevel, fxStroke, fxInnerShadow, fxInnerGlow, fxSatin,
                                     fxColorOverlay, fxGradientOverlay, fxPatternOverlay, fxOuterGlow,
                                     fxDropShadow]
    ## The effects as the Layer Style dialog lists them.

proc patternTile*(name: string): tuple[px: seq[uint32]; w, h: int] =
  ## One of the patterns that come with it, by name (`PatternNames`): small
  ## tiles that repeat without a seam.
  const n = 32
  var px = newSeq[uint32](n * n)
  for y in 0 ..< n:
    for x in 0 ..< n:
      let g = case name
              of "Dots":
                let dx = (x mod 16) - 8
                let dy = (y mod 16) - 8
                (if dx * dx + dy * dy < 16: 90 else: 235)
              of "Stripes": (if (x + y) mod 16 < 8: 110 else: 230)
              of "Grid": (if x mod 16 == 0 or y mod 16 == 0: 120 else: 240)
              of "Bricks":
                let row = y div 8
                let bx = (x + (if row mod 2 == 1: 8 else: 0)) mod 16
                (if y mod 8 == 0 or bx == 0: 200 else: 160 + ((x * 7 + y * 13) mod 11))
              of "Weave":
                let a = (x div 8 + y div 8) mod 2 == 0
                let t = if a: x mod 8 else: y mod 8
                150 + int(60 * sin(PI * t.float / 8))
              of "Canvas": 200 + ((x * 37 + y * 91) mod 7) * 4 - (if (x + y) mod 2 == 0: 10 else: 0)
              else: (if (x div 8 + y div 8) mod 2 == 0: 120 else: 230)     # Checkerboard
      let v = clamp(g, 0, 255)
      px[y * n + x] = 0xFF000000'u32 or (uint32(v) shl 16) or (uint32(v) shl 8) or uint32(v)
  (px, n, n)

const PatternNames* = ["Checkerboard", "Dots", "Stripes", "Grid", "Bricks", "Weave", "Canvas"]
  ## The patterns that come with it (`patternTile`).

proc defaultEffect*(k: FxKind): Effect =
  ## An effect turned on with the settings it starts with.
  const black = 0xFF000000'u32
  const glow = 0xFFFFFFBE'u32
  case k
  of fxDropShadow: Effect(on: true, mode: bmMultiply, opacity: 75, color: black, angle: 120, distance: 5, size: 5)
  of fxInnerShadow: Effect(on: true, mode: bmMultiply, opacity: 75, color: black, angle: 120, distance: 5, size: 5)
  of fxOuterGlow: Effect(on: true, mode: bmScreen, opacity: 75, color: glow, size: 5)
  of fxInnerGlow: Effect(on: true, mode: bmScreen, opacity: 75, color: glow, size: 5)
  of fxBevel: Effect(on: true, mode: bmScreen, opacity: 75, color: 0xFFFFFFFF'u32, mode2: bmMultiply,
                     opacity2: 75, color2: black, angle: 120, altitude: 30, size: 5, depth: 100)
  of fxSatin: Effect(on: true, mode: bmMultiply, opacity: 50, color: black, angle: 19, distance: 11, size: 14,
                     down: true)
  of fxColorOverlay: Effect(on: true, mode: bmNormal, opacity: 100, color: 0xFFFF0000'u32)
  of fxGradientOverlay: Effect(on: true, mode: bmNormal, opacity: 100, color: black, color2: 0xFFFFFFFF'u32,
                               angle: 90, scale: 100)
  of fxStroke: Effect(on: true, mode: bmNormal, opacity: 100, color: black, size: 3)
  of fxPatternOverlay:
    let t = patternTile("Checkerboard")
    Effect(on: true, mode: bmNormal, opacity: 100, scale: 100, pattern: t.px, patternW: t.w, patternH: t.h,
           patternName: "Checkerboard")

proc reach*(e: Effect; k: FxKind): int =
  ## How far past the layer's pixels an effect goes.
  if not e.on: return 0
  case k
  of fxDropShadow: e.distance + e.size + 2
  of fxOuterGlow: e.size + 2
  of fxStroke: (if e.style == 1: 0 else: e.size + 2)
  of fxBevel: (if e.style == 0: 0 else: e.size + e.soften + 2)
  else: 0

# ---- maps -----------------------------------------------------------------------------------------------

template forAll(n: int; i, body: untyped) =
  ## `body` for each `i` in `0 ..< n`, shared out among the cores (the
  ## work on each pixel alone).
  parallelChunks(n, lo, hi):
    for i in lo ..< hi:
      body

type Map = object
  w, h: int
  v: seq[float32]

template mp(m: Map): ptr UncheckedArray[float32] = cast[ptr UncheckedArray[float32]](unsafeAddr m.v[0])

proc newMap(w, h: int; fill = 0'f32): Map =
  result = Map(w: w, h: h, v: newSeq[float32](w * h))
  if fill != 0:
    for x in result.v.mitems: x = fill

proc boxPass(m: var Map; r: int; horizontal: bool; outside: float32) =
  ## One running-sum box blur of radius `r` (what lies past the edges:
  ## `outside`), in place: each line copied first; down the columns a band
  ## of them at a time, along the rows (kind to the cache).
  if r <= 0 or m.w <= 0 or m.h <= 0: return
  let w = m.w
  let h = m.h
  let dp = mp(m)
  let inv = 1'f32 / float32(2 * r + 1)
  if horizontal:
    parallelChunks(h, lo, hi):
      var line = newSeqUninit[float32](w + 2 * r + 2)
      let lp = cast[ptr UncheckedArray[float32]](addr line[0])
      for y in lo ..< hi:
        # (the row with `r` + 1 of `outside` each side: no tests in the loop)
        for i in 0 ..< r + 1: lp[i] = outside
        copyMem(addr lp[r + 1], addr dp[y * w], w * 4)
        for i in w + r + 1 ..< w + 2 * r + 2: lp[i] = outside
        var acc = 0'f32
        for i in 1 .. 2 * r + 1: acc += lp[i]
        let o = cast[ptr UncheckedArray[float32]](addr dp[y * w])
        for i in 0 ..< w:
          o[i] = acc * inv
          acc += lp[i + 2 * r + 2] - lp[i + 1]
  else:
    const Band = 64
    let bands = (w + Band - 1) div Band
    parallelChunks(bands, lo, hi):
      var col = newSeqUninit[float32]((h + 2 * r + 2) * Band)
      var acc = newSeqUninit[float32](Band)
      let cp = cast[ptr UncheckedArray[float32]](addr col[0])
      let ap = cast[ptr UncheckedArray[float32]](addr acc[0])
      for band in lo ..< hi:
        let x0 = band * Band
        let bw = min(Band, w - x0)
        # (the band's rows, `r` + 1 rows of `outside` above and below)
        for i in 0 ..< (r + 1) * bw: cp[i] = outside
        for y in 0 ..< h: copyMem(addr cp[(y + r + 1) * bw], addr dp[y * w + x0], bw * 4)
        for i in (h + r + 1) * bw ..< (h + 2 * r + 2) * bw: cp[i] = outside
        for x in 0 ..< bw: ap[x] = 0
        for k in 1 .. 2 * r + 1:
          for x in 0 ..< bw: ap[x] += cp[k * bw + x]
        for y in 0 ..< h:
          let o = y * w + x0
          let add = (y + 2 * r + 2) * bw
          let sub = (y + 1) * bw
          for x in 0 ..< bw:
            dp[o + x] = ap[x] * inv
            ap[x] += cp[add + x] - cp[sub + x]

proc blur(m: var Map; size: float; outside = 0'f32) =
  ## Nearly a Gaussian blur reaching `size` pixels (three box blurs).
  if size < 0.5: return
  let r = max(1, int(round(size / 3)))
  for k in 0 .. 2:
    m.boxPass(r, true, outside)
    m.boxPass(r, false, outside)

proc shifted(m: Map; dx, dy: int; outside: float32): Map =
  result = newMap(m.w, m.h)
  let w = m.w
  let h = m.h
  let sp = mp(m)
  let dp = mp(result)
  parallelRows(h, y):
    let sy = y - dy
    for x in 0 ..< w:
      let sx = x - dx
      dp[y * w + x] = if sx < 0 or sy < 0 or sx >= w or sy >= h: outside else: sp[sy * w + sx]

const Far = 1e12'f32

proc edt1(f: ptr UncheckedArray[float32]; n, stride: int; d: var seq[float32]; v: var seq[int];
          z: var seq[float32]) =
  ## Squared distances along one line (Felzenszwalb and Huttenlocher), in
  ## place.
  var k = 0
  v[0] = 0
  z[0] = -Far
  z[1] = Far
  for q in 1 ..< n:
    let fq = f[q * stride]
    if fq >= Far: continue
    if f[v[0] * stride] >= Far:
      v[0] = q
      continue
    while true:
      let p = v[k]
      let s = ((fq + float32(q * q)) - (f[p * stride] + float32(p * p))) / float32(2 * q - 2 * p)
      if s <= z[k]:
        if k == 0:
          v[0] = q
          z[1] = Far
          break
        dec k
      else:
        inc k
        v[k] = q
        z[k] = s
        z[k + 1] = Far
        break
  if f[v[0] * stride] >= Far: return
  k = 0
  for q in 0 ..< n:
    while z[k + 1] < float32(q): inc k
    let p = v[k]
    d[q] = float32((q - p) * (q - p)) + f[p * stride]
  for q in 0 ..< n: f[q * stride] = d[q]

proc distances(inside: Map; want: bool): Map =
  ## How far each pixel is from the nearest one that is (`want`) or is not
  ## inside (alpha at least a half), in pixels.
  result = newMap(inside.w, inside.h)
  let w = inside.w
  let h = inside.h
  let ip = mp(inside)
  let dp = mp(result)
  forAll(w * h, i): dp[i] = if (ip[i] >= 0.5) == want: 0'f32 else: Far
  parallelChunks(h, lo, hi):
    var d = newSeq[float32](w)
    var v = newSeq[int](w)
    var z = newSeq[float32](w + 1)
    for y in lo ..< hi:
      edt1(cast[ptr UncheckedArray[float32]](addr dp[y * w]), w, 1, d, v, z)
  # (down the columns a band of them at a time: copied out to lie along
  # rows, done, copied back -- kind to the cache)
  const Band = 32
  parallelChunks((w + Band - 1) div Band, lo, hi):
    var d = newSeq[float32](h)
    var v = newSeq[int](h)
    var z = newSeq[float32](h + 1)
    var t = newSeqUninit[float32](h * Band)
    let tp = cast[ptr UncheckedArray[float32]](addr t[0])
    for band in lo ..< hi:
      let x0 = band * Band
      let bw = min(Band, w - x0)
      for y in 0 ..< h:
        for x in 0 ..< bw: tp[x * h + y] = dp[y * w + x0 + x]
      for x in 0 ..< bw: edt1(cast[ptr UncheckedArray[float32]](addr tp[x * h]), h, 1, d, v, z)
      for y in 0 ..< h:
        for x in 0 ..< bw:
          let q = tp[x * h + y]
          dp[y * w + x0 + x] = if q >= Far: 1e6'f32 else: sqrt(q)

proc signedDistance(a: Map): Map =
  ## Out from the edge (> 0 outside, < 0 inside), in pixels, smoothed by
  ## the edge's alpha.
  let dout = distances(a, true)
  let din = distances(a, false)
  result = newMap(a.w, a.h)
  let ap = mp(a)
  let op = mp(dout)
  let ip = mp(din)
  let rp = mp(result)
  forAll(a.w * a.h, i):
    let al = ap[i]
    var sd = if al >= 0.5: -(ip[i] - 0.5'f32) else: op[i] - 0.5'f32
    if abs(sd) <= 1 and al > 0 and al < 1: sd = 0.5'f32 - al
    rp[i] = sd

proc signedDistances*(cover: seq[float32]; w, h: int): seq[float32] =
  ## How far each pixel is from the edge of what `cover` covers (0..1):
  ## > 0 outside, < 0 inside, in pixels (for strokes along an edge).
  signedDistance(Map(w: w, h: h, v: cover)).v

proc clamp01(x: float32): float32 {.inline.} = (if x < 0: 0'f32 elif x > 1: 1'f32 else: x)
proc smooth(t: float32): float32 {.inline.} =
  let u = clamp01(t)
  u * u * (3 - 2 * u)

proc toPlane(m: Map; e: Effect; color: uint32; mode: BlendMode; opacity: int): FxPlane =
  result = FxPlane(color: color, mode: mode, opacity: clamp(opacity, 0, 100) * 255 div 100,
                   a: newSeqUninit[uint8](m.w * m.h))
  let sp = mp(m)
  let op = cast[ptr UncheckedArray[uint8]](addr result.a[0])
  forAll(m.w * m.h, i): op[i] = uint8(clamp01(sp[i]) * 255 + 0.5)

proc lightOffset(e: Effect): (int, int) =
  ## Where a shadow falls: away from the light.
  let a = degToRad(e.angle.float)
  (int(round(-cos(a) * e.distance.float)), int(round(sin(a) * e.distance.float)))

# ---- the effects ---------------------------------------------------------------------------------------

proc renderFx*(w, h: int; L: Layer): FxRender =
  ## A layer's effects (its style), made from its pixels and its mask.
  # where its pixels are, and how far the effects go past them
  var x0 = w
  var y0 = h
  var x1 = -1
  var y1 = -1
  if L.px.len != w * h or w * h == 0: return FxRender()
  let maskOn = L.mask != nil and not L.maskOff and L.mask.px.len == L.px.len
  let pp = cast[ptr UncheckedArray[uint32]](unsafeAddr L.px[0])
  let mk = if maskOn: cast[ptr UncheckedArray[uint32]](unsafeAddr L.mask.px[0]) else: nil
  var rowMin = newSeq[int32](h)
  var rowMax = newSeq[int32](h)
  let rmin = cast[ptr UncheckedArray[int32]](addr rowMin[0])
  let rmax = cast[ptr UncheckedArray[int32]](addr rowMax[0])
  # (type: only where its letters were drawn)
  let ta = L.textArea
  let (sx0, sx1, sy0, sy1) = if ta.w > 0: (max(0, ta.x), min(w, ta.x + ta.w), max(0, ta.y), min(h, ta.y + ta.h))
                             else: (0, w, 0, h)
  for y in 0 ..< h: rowMin[y] = -1
  parallelRows(max(0, sy1 - sy0), yy):
    let y = sy0 + yy
    let row = y * w
    var a = int32(-1)
    var b = int32(-1)
    for x in sx0 ..< sx1:
      if (pp[row + x] shr 24) != 0 and (mk == nil or (mk[row + x] and 0xFF0000'u32) != 0):
        if a < 0: a = int32(x)
        b = int32(x)
    rmin[y] = a
    rmax[y] = b
  for y in 0 ..< h:
    if rowMin[y] >= 0:
      x0 = min(x0, rowMin[y].int)
      x1 = max(x1, rowMax[y].int)
      if y < y0: y0 = y
      y1 = y
  if x1 < 0: return FxRender()
  var reachMax = 2
  for k, e in L.fx.fx: reachMax = max(reachMax, e.reach(k))
  let r = rect(max(0, x0 - reachMax), max(0, y0 - reachMax),
               min(w, x1 + reachMax + 1) - max(0, x0 - reachMax),
               min(h, y1 + reachMax + 1) - max(0, y0 - reachMax))
  result = FxRender(r: r)
  # its alpha (with its mask) over the rectangle
  var a = newMap(r.w, r.h)
  let ap = mp(a)
  let rr = r
  parallelRows(r.h, y):
    for x in 0 ..< rr.w:
      let i = (rr.y + y) * w + rr.x + x
      var v = float32(pp[i] shr 24) / 255
      if mk != nil: v *= float32((mk[i] shr 16) and 255) / 255
      ap[y * rr.w + x] = v
  let fx = L.fx.fx
  var needSd = false
  for k in [fxOuterGlow, fxInnerGlow, fxStroke, fxBevel]:
    if fx[k].on: needSd = true
  let sd = if needSd: signedDistance(a) else: Map()
  let sdp = if needSd: mp(sd) else: nil
  let n = r.w * r.h
  let knock = L.fill < 100        # (no shadow, glow or outer stroke shows through the layer)
  # -- under it
  if fx[fxDropShadow].on:
    let e = fx[fxDropShadow]
    let (dx, dy) = e.lightOffset
    var s = a.shifted(dx, dy, 0)
    s.blur(e.size.float * (1 - e.spread / 100))
    let k = 1 / max(0.02, 1 - e.spread / 100)
    let spp = mp(s)
    forAll(n, i): spp[i] = clamp01(spp[i] * k) * (1 - ap[i])
    result.below.add s.toPlane(e, e.color, e.mode, e.opacity)
  if fx[fxOuterGlow].on:
    let e = fx[fxOuterGlow]
    let size = max(1'f32, e.size.float32)
    let sp = e.spread.float32 / 100
    var g = newMap(r.w, r.h)
    let gp = mp(g)
    forAll(n, i):
      let t = (sdp[i] - sp * size) / max(0.5'f32, (1 - sp) * size)
      gp[i] = (1 - smooth(t)) * (1 - ap[i])
    result.below.add g.toPlane(e, e.color, e.mode, e.opacity)
  if fx[fxStroke].on and fx[fxStroke].style == 0:
    let e = fx[fxStroke]
    let s = e.size.float32
    var m = newMap(r.w, r.h)
    let mm = mp(m)
    forAll(n, i):
      mm[i] = clamp01(s + 0.5'f32 - sdp[i])
      if knock: mm[i] *= 1 - ap[i]
    result.below.add m.toPlane(e, e.color, e.mode, e.opacity)
  # -- over it (inside its shape)
  if fx[fxPatternOverlay].on and fx[fxPatternOverlay].pattern.len > 0 and
     fx[fxPatternOverlay].pattern.len == fx[fxPatternOverlay].patternW * fx[fxPatternOverlay].patternH:
    # the tile repeated from the layer's corner (Link with Layer), scaled and turned
    let e = fx[fxPatternOverlay]
    var pl = FxPlane(mode: e.mode, opacity: clamp(e.opacity, 0, 100) * 255 div 100,
                     a: newSeq[uint8](n), colors: newSeq[uint32](n))
    let pw = e.patternW
    let ph = e.patternH
    let k = 100 / max(1, (if e.scale <= 0: 100 else: e.scale)).float
    let ang = degToRad(e.angle.float)
    let ca = cos(ang) * k
    let sa = sin(ang) * k
    let ox = float(x0 - r.x)
    let oy = float(y0 - r.y)
    let tp = cast[ptr UncheckedArray[uint32]](unsafeAddr e.pattern[0])
    let cp = cast[ptr UncheckedArray[uint32]](addr pl.colors[0])
    let aq = cast[ptr UncheckedArray[uint8]](addr pl.a[0])
    let rw = r.w
    parallelChunks(r.h, lo, hi):
      for y in lo ..< hi:
        for x in 0 ..< rw:
          let i = y * rw + x
          let fx0 = x.float - ox
          let fy0 = y.float - oy
          let u = fx0 * ca + fy0 * sa
          let v = -fx0 * sa + fy0 * ca
          let tx = ((int(floor(u)) mod pw) + pw) mod pw
          let ty = ((int(floor(v)) mod ph) + ph) mod ph
          let c = tp[ty * pw + tx]
          cp[i] = c or 0xFF000000'u32
          aq[i] = uint8(clamp01(ap[i]) * float32(c shr 24) + 0.5'f32)
    result.above.add pl
  if fx[fxGradientOverlay].on:
    let e = fx[fxGradientOverlay]
    var pl = FxPlane(mode: e.mode, opacity: clamp(e.opacity, 0, 100) * 255 div 100,
                     a: newSeq[uint8](n), colors: newSeq[uint32](n))
    let cx = float((x0 + x1) / 2 - r.x.float)
    let cy = float((y0 + y1) / 2 - r.y.float)
    let ang = degToRad(e.angle.float)
    let dirx = cos(ang)
    let diry = -sin(ang)
    let bw = float(x1 - x0 + 1)
    let bh = float(y1 - y0 + 1)
    let half = max(1.0, (abs(dirx) * bw + abs(diry) * bh) / 2)
    let scale = (if e.scale <= 0: 100 else: e.scale).float / 100
    let rad = max(1.0, max(bw, bh) / 2)
    for y in 0 ..< r.h:
      for x in 0 ..< r.w:
        let i = y * r.w + x
        let fx0 = x.float - cx
        let fy0 = y.float - cy
        var t = case e.style
                of 1: hypot(fx0, fy0) / (rad * scale)
                of 2: (arctan2(-fy0, fx0) - ang) / (2 * PI)
                of 3: abs(fx0 * dirx + fy0 * diry) / (half * scale)
                of 4: (abs(fx0) + abs(fy0)) / (rad * scale)
                else: (fx0 * dirx + fy0 * diry) / (half * scale) / 2 + 0.5
        if e.style == 2: t = t - floor(t)
        t = clamp(t, 0, 1)
        if e.down: t = 1 - t
        let c1 = e.color
        let c2 = e.color2
        # (dithered: rounded up or down by a pattern that stays put -- no bands)
        const bayer = [0.0, 8, 2, 10, 12, 4, 14, 6, 3, 11, 1, 9, 15, 7, 13, 5]
        let dth = (bayer[(y and 3) * 4 + (x and 3)] + 0.5) / 16
        template mix(sh: int): uint32 =
          uint32(clamp(floor(float((c1 shr sh) and 255) * (1 - t) + float((c2 shr sh) and 255) * t + dth), 0.0, 255.0)) shl sh
        pl.colors[i] = 0xFF000000'u32 or mix(16) or mix(8) or mix(0)
        pl.a[i] = uint8(clamp01(ap[i]) * 255 + 0.5)
    result.above.add pl
  if fx[fxColorOverlay].on:
    let e = fx[fxColorOverlay]
    result.above.add a.toPlane(e, e.color, e.mode, e.opacity)
  if fx[fxSatin].on:
    let e = fx[fxSatin]
    let (dx, dy) = e.lightOffset
    var p1 = a.shifted(dx, dy, 0)
    var p2 = a.shifted(-dx, -dy, 0)
    p1.blur(e.size.float)
    p2.blur(e.size.float)
    let q1 = mp(p1)
    let q2 = mp(p2)
    forAll(n, i):
      var v = abs(q1[i] - q2[i])
      if e.down: v = 1 - v
      q1[i] = clamp01(v) * ap[i]
    result.above.add p1.toPlane(e, e.color, e.mode, e.opacity)
  if fx[fxInnerGlow].on:
    let e = fx[fxInnerGlow]
    let size = max(1'f32, e.size.float32)
    let ch = e.spread.float32 / 100
    var g = newMap(r.w, r.h)
    let gp = mp(g)
    forAll(n, i):
      let t = (-sdp[i] - ch * size) / max(0.5'f32, (1 - ch) * size)
      let v = 1 - smooth(t)
      gp[i] = (if e.style == 1: 1 - v else: v) * ap[i]
    result.above.add g.toPlane(e, e.color, e.mode, e.opacity)
  if fx[fxInnerShadow].on:
    let e = fx[fxInnerShadow]
    let (dx, dy) = e.lightOffset
    var inv = newMap(r.w, r.h)
    let ip = mp(inv)
    forAll(n, i): ip[i] = 1 - ap[i]
    var s = inv.shifted(dx, dy, 1)
    s.blur(e.size.float * (1 - e.spread / 100), 1)
    let k = 1 / max(0.02, 1 - e.spread / 100)
    let spp = mp(s)
    forAll(n, i): spp[i] = clamp01(spp[i] * k) * ap[i]
    result.above.add s.toPlane(e, e.color, e.mode, e.opacity)
  if fx[fxStroke].on and fx[fxStroke].style != 0:
    let e = fx[fxStroke]
    let s = e.size.float32
    var m = newMap(r.w, r.h)
    let mm = mp(m)
    forAll(n, i):
      mm[i] = if e.style == 1: clamp01(s + 0.5'f32 + sdp[i]) * ap[i]
              else: clamp01(s / 2 + 0.5'f32 - abs(sdp[i]))
    result.above.add m.toPlane(e, e.color, e.mode, e.opacity)
  if fx[fxBevel].on:
    let e = fx[fxBevel]
    let size = max(1'f32, e.size.float32)
    var hm = newMap(r.w, r.h)
    let hp = mp(hm)
    var region = newMap(r.w, r.h)
    let rg = mp(region)
    forAll(n, i):
      let d = sdp[i]
      case e.style
      of 1:          # outer bevel: rises from the backdrop to the edge
        hp[i] = 1 - smooth(d / size)
        rg[i] = (1 - ap[i]) * (if d <= size + 1: 1'f32 else: 0'f32)
      of 2:          # emboss: half in, half out
        hp[i] = 1 - smooth((d + size) / (2 * size))
        rg[i] = if abs(d) <= size + 1: 1'f32 else: 0'f32
      of 3:          # pillow emboss: the edge pressed in
        hp[i] = if d < 0: smooth(-d / size) else: -(1 - smooth(d / size))
        rg[i] = if abs(d) <= size + 1: 1'f32 else: 0'f32
      else:          # inner bevel
        hp[i] = smooth(-d / size)
        rg[i] = ap[i]
    hm.blur(max(1.0, e.soften.float))
    let height = size * e.depth.float32 / 100 * (if e.down: -1'f32 else: 1'f32)
    let az = degToRad(e.angle.float)
    let al = degToRad(clamp(e.altitude, 0, 90).float)
    let lx = float32(cos(al) * cos(az))
    let ly = float32(-cos(al) * sin(az))
    let lz = float32(sin(al))
    var hi = newMap(r.w, r.h)
    var lo = newMap(r.w, r.h)
    let hip = mp(hi)
    let lop = mp(lo)
    let rw = r.w
    let rh = r.h
    parallelRows(rh, y):
      for x in 0 ..< rw:
        let i = y * rw + x
        if rg[i] <= 0: continue
        let xa = max(0, x - 1)
        let xb = min(rw - 1, x + 1)
        let ya = max(0, y - 1)
        let yb = min(rh - 1, y + 1)
        let gx = (hp[y * rw + xb] - hp[y * rw + xa]) / float32(max(1, xb - xa)) * height
        let gy = (hp[yb * rw + x] - hp[ya * rw + x]) / float32(max(1, yb - ya)) * height
        let nl = sqrt(gx * gx + gy * gy + 1)
        let shade = (-gx * lx - gy * ly + lz) / nl
        let diff = shade - lz
        hip[i] = clamp01(diff * 2) * rg[i]
        lop[i] = clamp01(-diff * 2) * rg[i]
    result.above.add hi.toPlane(e, e.color, e.mode, e.opacity)
    result.above.add lo.toPlane(e, e.color2, e.mode2, e.opacity2)

{.pop.}

layerFxRender = renderFx

# ---- Scale Effects, Create Layers ----------------------------------------------------------------------------

proc scaleEffects*(fx: var LayerFx; percent: float) =
  ## Layer > Layer Style > Scale Effects: every effect's distance, size and
  ## softening (and the overlays' pattern and gradient scale) times `percent`
  ## / 100 -- the look kept for a layer made bigger or smaller.
  fx.scaleFx(max(0.0, percent) / 100)

proc effectLayers*(d: Doc; L: Layer; nameOf: proc (layer, effect: string): string = nil):
                   tuple[below, above: seq[Layer]] =
  ## Layer > Layer Style > Create Layers: each effect of `L`'s style as a layer
  ## of its own, named for it ("Layer 1's Drop Shadow"; `nameOf` names it in another
  ## language, from the layer's name and the effect's), in its blend mode and
  ## opacity -- the ones drawn under `L` (shadows, glows) in `below`, bottom
  ## first; the ones drawn over it (overlays, inner effects, the stroke, the
  ## bevel's highlights and shadows) in `above`, bottom first, to be clipped to
  ## `L`. Not put in the document (`createEffectLayers` does that).
  if not L.hasStyle or L.px.len != d.w * d.h: return
  for k in FxKind:
    if not L.fx.fx[k].on: continue
    var one = LayerFx()
    one.fx[k] = L.fx.fx[k]
    let tmp = Layer(pxRaw: L.px, opacity: 100, mode: bmNormal, visible: true, fx: one, mask: L.mask,
                    maskOff: L.maskOff)
    let fr = renderFx(d.w, d.h, tmp)
    if fr == nil: continue
    for side in 0 .. 1:
      let planes = if side == 0: fr.below else: fr.above
      for i, p in planes:
        var what = StyleNames[k]
        if k == fxBevel and planes.len == 2: what.add(if i == 0: " Highlights" else: " Shadows")
        let name = if nameOf != nil: nameOf(L.name, what) else: L.name & "'s " & what
        let n = newLayer(d, name)
        n.mode = p.mode
        n.opacity = clamp((p.opacity * 100 + 127) div 255, 0, 100)
        let r = fr.r
        for y in 0 ..< r.h:
          let iy = r.y + y
          if iy < 0 or iy >= d.h: continue
          for x in 0 ..< r.w:
            let ix = r.x + x
            if ix < 0 or ix >= d.w: continue
            let j = y * r.w + x
            if j >= p.a.len or p.a[j] == 0: continue
            let c = if p.colors.len == p.a.len: p.colors[j] else: p.color
            n.px[iy * d.w + ix] = withAlpha(c, aOf(c) * int(p.a[j]) div 255)
        inc n.ver
        if side == 0: result.below.add n else: result.above.add n

proc createEffectLayers*(d: Doc; L: Layer; nameOf: proc (layer, effect: string): string = nil): int =
  ## `effectLayers` put in the document round `L` (those over it clipped to
  ## it) and its style taken off -- what it looked like kept. The number of
  ## layers made. (An undoable change: `touchLayers` first.)
  let (below, above) = d.effectLayers(L, nameOf)
  if below.len + above.len == 0: return 0
  if L.fill < 100:
    L.opacity = L.opacity * L.fill div 100
    L.fill = 100
  L.fx = LayerFx()
  var at = d.layers.find(L)
  for n in below:
    n.depth = L.depth
    d.layers.insert(n, at)
    inc at
  for i, n in above:
    n.depth = L.depth
    n.clipped = true
    d.layers.insert(n, at + 1 + i)
  d.cur = d.layers.find(L)
  d.markAll()
  below.len + above.len
