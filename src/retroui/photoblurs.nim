## The rest of Photoshop's Blur menu, for Retro Photo: Average, Box Blur,
## Shape Blur, Smart Blur and Lens Blur.
##
## Box Blur is running sums both ways: as quick at a radius of 500 as of
## 5. Shape Blur and Lens Blur take a kernel of any shape (a custom shape,
## an iris of 3 to 8 blades) as runs along its rows, each run read at once
## from its row's running sums: a pixel costs the kernel's height, not its
## area. Past a radius of 48 the picture is blurred smaller and made big
## again, as `gaussianBlurImg` does. Lens Blur works in light rather than
## in the picture's gamma, so bright points blur into bright discs as a
## lens makes them, and a depth map blurs each pixel by how far it is
## from the focal distance.
##
## ```nim
## d.applyFilter(12, boxBlur(10))
## d.applyFilter(20, lensBlur(LensBlur(radius: 15, blades: 6)))
## ```

import std/math
import gfx, photo, photofx, parallel, simd

{.push boundChecks: off, overflowChecks: off.}

template pu(s: seq[uint32]): ptr UncheckedArray[uint32] =
  cast[ptr UncheckedArray[uint32]](unsafeAddr s[0])
template pb(s: seq[uint8]): ptr UncheckedArray[uint8] =
  cast[ptr UncheckedArray[uint8]](unsafeAddr s[0])

type
  KernelRuns* = object
    ## A kernel as runs along its rows: each `(dy, x0, x1)` the pixels
    ## `x0 .. x1` of the row `dy` from its center.
    runs*: seq[tuple[dy, x0, x1: int]]
    count*: int                ## its pixels (all the runs')
    reach*: int                ## how far it goes from its center, any way

  LensBlur* = object
    ## Filter > Blur > Lens Blur's settings (as Photoshop's box has them).
    radius*: int               ## Iris Radius, 0 .. 100 pixels
    blades*: int               ## Shape: 3 Triangle .. 8 Octagon (0: a circle)
    curvature*: int            ## Blade Curvature, 0 .. 100
    rotation*: float           ## Rotation, degrees
    brightness*: int           ## Specular Highlights: Brightness, 0 .. 100
    threshold*: int            ## ... Threshold, 0 .. 255 (the lights at least this bright)
    noise*: int                ## Noise: Amount, 0 .. 100
    gaussian*: bool            ## ... Distribution: Gaussian (else Uniform)
    mono*: bool                ## ... Monochromatic
    focal*: int                ## Blur Focal Distance, 0 .. 255: the depth kept sharp
    invert*: bool              ## Invert: the depth map read the other way

proc runsOf*(mask: seq[uint8]; w, h: int): KernelRuns =
  ## A kernel from a mask (`w` x `h`, its center the kernel's): the runs of
  ## its pixels at least half covered.
  let cx = w div 2
  let cy = h div 2
  for y in 0 ..< h:
    var x = 0
    while x < w:
      if mask[y * w + x] < 128:
        inc x
        continue
      let a = x
      while x < w and mask[y * w + x] >= 128: inc x
      result.runs.add (y - cy, a - cx, x - 1 - cx)
      result.count += x - a
      result.reach = max(result.reach, max(abs(y - cy), max(abs(a - cx), abs(x - 1 - cx))))
  if result.count == 0:
    result.runs = @[(0, 0, 0)]
    result.count = 1

proc irisRuns*(radius: float; blades = 6; curvature = 0; rotation = 0.0): KernelRuns =
  ## The kernel of a lens's iris: a polygon of `blades` sides (0: a
  ## circle) `radius` pixels round, its sides bent toward a circle by
  ## `curvature` (0 .. 100), turned `rotation` degrees.
  let r = max(0.0, radius)
  let ri = int(ceil(r - 0.25))
  if ri <= 0:
    return KernelRuns(runs: @[(0, 0, 0)], count: 1)
  let c = if blades < 3: 1.0 else: clamp(curvature, 0, 100) / 100
  var pts: seq[(float, float)]
  if blades >= 3:
    for k in 0 ..< blades:
      let t = degToRad(rotation - 90) + 2 * PI * k.float / blades.float
      pts.add (r * cos(t), r * sin(t))
  for dy in -ri .. ri:
    let y = dy.float
    if abs(y) > r: continue
    let circ = sqrt(max(0.0, r * r - y * y))
    var lo = -circ
    var hi = circ
    if c < 1:
      var plo = 1e18
      var phi = -1e18
      for k in 0 ..< pts.len:
        let (ax, ay) = pts[k]
        let (bx, by) = pts[(k + 1) mod pts.len]
        if (ay <= y and by >= y) or (by <= y and ay >= y):
          let x = if abs(by - ay) < 1e-9: min(ax, bx) else: ax + (y - ay) / (by - ay) * (bx - ax)
          plo = min(plo, x)
          phi = max(phi, x)
          if abs(by - ay) < 1e-9: phi = max(phi, max(ax, bx))
      if plo > phi: continue            # (the row misses the polygon)
      lo = plo * (1 - c) + lo * c
      hi = phi * (1 - c) + hi * c
    let x0 = int(round(lo))
    let x1 = int(round(hi))
    if x1 < x0: continue
    result.runs.add (dy, x0, x1)
    result.count += x1 - x0 + 1
    result.reach = max(result.reach, max(abs(dy), max(abs(x0), abs(x1))))
  if result.count == 0:
    result.runs = @[(0, 0, 0)]
    result.count = 1

# ---- the kernel's sums ---------------------------------------------------------------------------------

type ToLight = array[256, uint32]

proc gammaTable(linear: bool): ToLight =
  ## Each level as the sums take it: as it is (x 64), or as light.
  for v in 0 .. 255:
    result[v] = if linear: uint32(round(pow(v / 255, 2.2) * 16383)) else: uint32(v * 64)

proc fromLight(linear: bool): seq[uint8] =
  ## (back: 0 .. 16383 to a level)
  result = newSeq[uint8](16384)
  for i in 0 .. 16383:
    result[i] = uint8(if linear: clamp(int(round(pow(i / 16383, 1 / 2.2) * 255)), 0, 255)
                      else: clamp((i + 32) div 64, 0, 255))

proc runsBlur(src: Img; ks: openArray[KernelRuns]; which: seq[uint8]; linear: bool;
              boostAt = 256; boost = 1.0): Img =
  ## Each pixel the mean of its kernel (`ks[which[i]]`, or `ks[0]`), the
  ## colors weighted by their alpha; `linear`: summed as light. Pixels at
  ## least `boostAt` bright count `boost` times as bright (specular lights).
  let w = src.w
  let h = src.h
  result = newImgUninit(w, h)
  if w == 0 or h == 0: return
  var reach = 0
  for k in ks: reach = max(reach, k.reach)
  let toL = gammaTable(linear)
  let back = fromLight(linear)
  let bk = pb(back)
  let sp = pu(src.px)
  let o = pu(result.px)
  let wp = if which.len == w * h: pb(which) else: nil
  let pw = w + 2 * reach + 1                     # (a row's sums: the edges repeated `reach` out)
  let band = clamp(4 * reach, 32, 256)
  let bands = (h + band - 1) div band
  let kp = cast[ptr UncheckedArray[KernelRuns]](unsafeAddr ks[0])
  let boostK = uint32(round(boost * 256))
  parallelRows(bands, b):
    let y0 = b * band
    let y1 = min(h, y0 + band)
    let r0 = y0 - reach
    let rows = (y1 - y0) + 2 * reach
    # the running sums of each row the band reads: alpha, and each color times its alpha
    var sums = newSeqUninit[uint32](rows * pw * 4)
    let sm = cast[ptr UncheckedArray[uint32]](addr sums[0])
    for j in 0 ..< rows:
      let sy = clamp(r0 + j, 0, h - 1) * w
      let base = j * pw * 4
      var a, r, g, bl: uint32
      sm[base] = 0; sm[base + 1] = 0; sm[base + 2] = 0; sm[base + 3] = 0
      for x in 0 ..< pw - 1:
        let p = sp[sy + clamp(x - reach, 0, w - 1)]
        let pa = p shr 24
        if pa != 0:
          var cr = toL[(p shr 16) and 255]
          var cg = toL[(p shr 8) and 255]
          var cb = toL[p and 255]
          if boostAt <= 255 and lumaOf(p) >= boostAt:
            cr = cr * boostK shr 8; cg = cg * boostK shr 8; cb = cb * boostK shr 8
          a += pa
          r += cr * pa shr 6
          g += cg * pa shr 6
          bl += cb * pa shr 6
        let q = base + (x + 1) * 4
        sm[q] = a; sm[q + 1] = r; sm[q + 2] = g; sm[q + 3] = bl
    for y in y0 ..< y1:
      for x in 0 ..< w:
        let i = y * w + x
        let ki = if wp != nil: int(wp[i]) else: 0
        let k = kp[ki].addr
        if k.count == 1:
          o[i] = sp[i]
          continue
        var a, r, g, bl: float
        for run in k.runs:
          let base = (y - r0 + run.dy) * pw * 4
          let qa = base + (x + reach + run.x0) * 4
          let qb = base + (x + reach + run.x1 + 1) * 4
          a += float(sm[qb] - sm[qa])
          r += float(sm[qb + 1] - sm[qa + 1])
          g += float(sm[qb + 2] - sm[qa + 2])
          bl += float(sm[qb + 3] - sm[qa + 3])
        if a <= 0:
          o[i] = 0
          continue
        let oa = clamp(int(round(a / k.count.float)), 0, 255)
        let f = 64 / a
        let cr = bk[min(16383, int(r * f))]
        let cg = bk[min(16383, int(g * f))]
        let cb = bk[min(16383, int(bl * f))]
        o[i] = (uint32(oa) shl 24) or (uint32(cr) shl 16) or (uint32(cg) shl 8) or uint32(cb)

proc shrunkBlur(src: Img; radius: float; make: proc (r: float): KernelRuns; linear: bool;
                boostAt = 256; boost = 1.0): Img =
  ## (one kernel; past a radius of 48 done on the picture made smaller)
  if radius <= 48 or src.w < 16 or src.h < 16:
    return runsBlur(src, [make(radius)], @[], linear, boostAt, boost)
  let f = int(ceil(radius / 40))
  let sw = max(1, (src.w + f - 1) div f)
  let sh = max(1, (src.h + f - 1) div f)
  let small = Img(w: sw, h: sh, px: resample(src.px, src.w, src.h, sw, sh, rsBilinear))
  let sb = runsBlur(small, [make(radius / f.float)], @[], linear, boostAt, boost)
  Img(w: src.w, h: src.h, px: resample(sb.px, sw, sh, src.w, src.h, rsBilinear))

# ---- the filters ---------------------------------------------------------------------------------------

proc averageBlur*(): FilterFn =
  ## Blur > Average: the part worked on filled with its mean color (its
  ## pixels' alpha kept).
  result = proc (src: Img; inner: Rect): Img =
    var a, r, g, b: float
    let sp = pu(src.px)
    for y in inner.y ..< inner.y + inner.h:
      for x in inner.x ..< inner.x + inner.w:
        let p = sp[y * src.w + x]
        let pa = float(p shr 24)
        a += pa
        r += float((p shr 16) and 255) * pa
        g += float((p shr 8) and 255) * pa
        b += float(p and 255) * pa
    result = newImgUninit(src.w, src.h)
    let c = if a > 0: (uint32(round(r / a)) shl 16) or (uint32(round(g / a)) shl 8) or uint32(round(b / a))
            else: 0'u32
    let o = pu(result.px)
    for i in 0 ..< src.px.len: o[i] = (sp[i] and 0xFF000000'u32) or c

proc boxBlurImg*(src: Img; radius: int): Img =
  ## Each pixel the mean of the square `2 * radius + 1` a side round it
  ## (the edges repeated), the colors weighted by their alpha: running
  ## sums across and down, so any radius costs the same.
  let w = src.w
  let h = src.h
  if radius <= 0 or w == 0 or h == 0: return src
  let r = radius
  when simdOn:
    # (the sums four lanes at a time: retroui/simd)
    var mid16 = newSeqUninit[uint16](w * h * 4)
    let m16 = cast[ptr UncheckedArray[uint16]](addr mid16[0])
    let sp0 = pu(src.px)
    parallelRows(h, y):
      boxAcross(cast[ptr UncheckedArray[uint32]](addr sp0[y * w]), w, r,
                cast[ptr UncheckedArray[uint16]](addr m16[y * w * 4]))
    result = newImgUninit(w, h)
    let o0 = pu(result.px)
    const band0 = 64
    parallelRows((w + band0 - 1) div band0, bi):
      var acc = newSeqUninit[uint32](band0 * 4)
      boxDown(m16, w, h, bi * band0, min(w, bi * band0 + band0), r, o0, cast[ptr UncheckedArray[uint32]](addr acc[0]))
  else:
    let n = uint64(2 * r + 1)
    # across: premultiplied sums into 16-bit-a-channel rows
    var mid = newSeqUninit[uint64](w * h)
    let mp = cast[ptr UncheckedArray[uint64]](addr mid[0])
    let sp = pu(src.px)
    parallelRows(h, y):
      var acc: array[4, uint64]
      template px(x: int): uint32 = sp[y * w + clamp(x, 0, w - 1)]
      template add(p: uint32; s: int) =
        let pa = uint64(p shr 24)
        if s > 0:
          acc[0] += pa; acc[1] += uint64((p shr 16) and 255) * pa
          acc[2] += uint64((p shr 8) and 255) * pa; acc[3] += uint64(p and 255) * pa
        else:
          acc[0] -= pa; acc[1] -= uint64((p shr 16) and 255) * pa
          acc[2] -= uint64((p shr 8) and 255) * pa; acc[3] -= uint64(p and 255) * pa
      for k in -r .. r: add(px(k), 1)
      for x in 0 ..< w:
        let q = (y * w + x)
        # (a channel's mean times 256, packed four to the word: 16 bits each)
        let a = acc[0]
        mp[q] = ((a * 256 div n) shl 48) or ((acc[1] * 256 div n div 255) shl 32) or
                ((acc[2] * 256 div n div 255) shl 16) or (acc[3] * 256 div n div 255)
        add(px(x - r), -1)
        add(px(x + r + 1), 1)
    result = newImgUninit(w, h)
    let o = pu(result.px)
    let band = 64
    parallelRows((w + band - 1) div band, bi):
      let x0 = bi * band
      let x1 = min(w, x0 + band)
      var acc = newSeq[array[4, uint64]](x1 - x0)
      template addRow(yy: int; s: int) =
        let row = clamp(yy, 0, h - 1) * w
        for x in x0 ..< x1:
          let v = mp[row + x]
          let k = x - x0
          if s > 0:
            acc[k][0] += v shr 48; acc[k][1] += (v shr 32) and 0xFFFF
            acc[k][2] += (v shr 16) and 0xFFFF; acc[k][3] += v and 0xFFFF
          else:
            acc[k][0] -= v shr 48; acc[k][1] -= (v shr 32) and 0xFFFF
            acc[k][2] -= (v shr 16) and 0xFFFF; acc[k][3] -= v and 0xFFFF
      for k in -r .. r: addRow(k, 1)
      for y in 0 ..< h:
        for x in x0 ..< x1:
          let k = x - x0
          let a = acc[k][0]                 # (the mean alpha x 256, times n)
          let i = y * w + x
          if a == 0:
            o[i] = 0
          else:
            let oa = min(255'u64, (a + n * 128) div (n * 256))
            let cr = min(255'u64, (acc[k][1] * 255 + a div 2) div a)
            let cg = min(255'u64, (acc[k][2] * 255 + a div 2) div a)
            let cb = min(255'u64, (acc[k][3] * 255 + a div 2) div a)
            o[i] = uint32((oa shl 24) or (cr shl 16) or (cg shl 8) or cb)
        addRow(y - r, -1)
        addRow(y + r + 1, 1)

proc boxBlur*(radius: int): FilterFn =
  ## Blur > Box Blur: each pixel the mean of the square round it, `radius`
  ## 1 .. 2000 pixels.
  result = proc (src: Img; inner: Rect): Img = boxBlurImg(src, radius)

proc shapeBlurImg*(src: Img; radius: int; shape: seq[uint8]; side: int): Img =
  ## Each pixel the mean of a shape round it: `shape` (`side` x `side`, any
  ## size: it is stretched) `2 * radius + 1` across.
  proc make(r: float): KernelRuns =
    let m = max(1, 2 * int(round(r)) + 1)
    var k = newSeq[uint8](m * m)
    for y in 0 ..< m:
      for x in 0 ..< m:
        let sx = min(side - 1, x * side div m)
        let sy = min(side - 1, y * side div m)
        k[y * m + x] = if side > 0 and shape.len == side * side: shape[sy * side + sx] else: 255'u8
    runsOf(k, m, m)
  shrunkBlur(src, radius.float, make, false)

proc shapeBlur*(radius: int; shape: seq[uint8]; side: int): FilterFn =
  ## Blur > Shape Blur: each pixel the mean of `shape` round it (a custom
  ## shape, `shapeMask`ed into `side` x `side`), `radius` 5 .. 1000 pixels.
  result = proc (src: Img; inner: Rect): Img = shapeBlurImg(src, radius, shape, side)

proc smartBlur*(radius = 3.0; threshold = 25.0; quality = 1; mode = 0): FilterFn =
  ## Blur > Smart Blur: blurs where the colors are alike and leaves the
  ## edges -- each pixel the mean of the pixels round it (`radius` 0.1 ..
  ## 100) less than `threshold` (0.1 .. 100) levels from it, sampled every
  ## pixel (`quality` 2 High), every second (1 Medium) or third (0 Low).
  ## `mode` 1 Edge Only: the edges in white on black; 2 Overlay Edge: in
  ## white over the picture.
  result = proc (src: Img; inner: Rect): Img =
    let w = src.w
    let h = src.h
    let r = max(1, int(round(radius)))
    let th = int(round(threshold * 2.55))
    let step = case quality
               of 0: 3
               of 1: 2
               else: 1
    let sp = pu(src.px)
    var mid = newImgUninit(w, h)
    result = newImgUninit(w, h)
    let m = pu(mid.px)
    let o = pu(result.px)
    template pass(dst, s: ptr UncheckedArray[uint32]; along: bool) =
      parallelRows(h, y):
        for x in 0 ..< w:
          let c = s[y * w + x]
          let cl = lumaOf(c)
          var a, rr, gg, bb, n = 0
          var k = -r
          while k <= r:
            let q = if along: s[y * w + clamp(x + k, 0, w - 1)] else: s[clamp(y + k, 0, h - 1) * w + x]
            if abs(lumaOf(q) - cl) <= th:
              let qa = int(q shr 24)
              a += qa; rr += int((q shr 16) and 255) * qa; gg += int((q shr 8) and 255) * qa
              bb += int(q and 255) * qa
              inc n
            k += step
          dst[y * w + x] = if a == 0: c
                           else: (uint32((a + n div 2) div max(1, n)) shl 24) or (uint32(rr div a) shl 16) or
                                 (uint32(gg div a) shl 8) or uint32(bb div a)
    pass(m, sp, true)
    pass(o, m, false)
    if mode == 0: return
    # the edges: where the lightness steps more than the threshold
    parallelRows(h, y):
      for x in 0 ..< w:
        let i = y * w + x
        let l = lumaOf(sp[i])
        var edge = false
        if x + 1 < w and abs(lumaOf(sp[i + 1]) - l) > th: edge = true
        if y + 1 < h and abs(lumaOf(sp[i + w]) - l) > th: edge = true
        let a = sp[i] and 0xFF000000'u32
        if mode == 1: o[i] = a or (if edge: 0xFFFFFF'u32 else: 0'u32)
        elif edge: o[i] = a or 0xFFFFFF'u32

proc lensBlurImg*(src: Img; o: LensBlur; depth: seq[uint8] = @[]): Img =
  ## Lens Blur on `src`; `depth` (`src`'s size, 0 near .. 255 far) blurs
  ## each pixel by how far its depth is from `o.focal`, else everything by
  ## `o.radius`. Then the noise asked for.
  let w = src.w
  let h = src.h
  if w == 0 or h == 0: return src
  let boostAt = if o.brightness > 0: clamp(o.threshold, 0, 255) else: 256
  let boost = 1 + o.brightness.float / 100 * 3
  var res: Img
  if depth.len != w * h:
    res = shrunkBlur(src, o.radius.float, proc (r: float): KernelRuns =
                       irisRuns(r, o.blades, o.curvature, o.rotation), true, boostAt, boost)
  else:
    # a kernel for each radius up to the full one; each pixel the one its depth asks for
    let full = clamp(o.radius, 0, 100)
    let f = if full > 48: int(ceil(full / 40)) else: 1
    let rr = int(ceil(full / f))
    var ks: seq[KernelRuns]
    for k in 0 .. rr: ks.add irisRuns(k.float, o.blades, o.curvature, o.rotation)
    var which = newSeqUninit[uint8](w * h)
    let dp = pb(depth)
    let wp = pb(which)
    let focal = clamp(o.focal, 0, 255)
    let inv = o.invert
    parallelRows(h, y):
      for x in 0 ..< w:
        let i = y * w + x
        let dd = if inv: 255 - int(dp[i]) else: int(dp[i])
        wp[i] = uint8(clamp(int(round(abs(dd - focal).float / 255 * rr.float)), 0, rr))
    if f == 1:
      res = runsBlur(src, ks, which, true, boostAt, boost)
    else:
      let sw = max(1, (w + f - 1) div f)
      let sh = max(1, (h + f - 1) div f)
      let small = Img(w: sw, h: sh, px: resample(src.px, w, h, sw, sh, rsBilinear))
      var sWhich = newSeqUninit[uint8](sw * sh)
      for y in 0 ..< sh:
        for x in 0 ..< sw: sWhich[y * sw + x] = which[min(h - 1, y * f) * w + min(w - 1, x * f)]
      let sb = runsBlur(small, ks, sWhich, true, boostAt, boost)
      let big = resample(sb.px, sw, sh, w, h, rsBilinear)
      # (sharp where the depth is in focus: the pixels kept)
      res = newImgUninit(w, h)
      let bp = pu(big)
      let rp = pu(res.px)
      let sp = pu(src.px)
      parallelRows(h, y):
        for x in 0 ..< w:
          let i = y * w + x
          rp[i] = if wp[i] == 0: sp[i] else: bp[i]
  if o.noise > 0:
    let amt = o.noise.float * 1.28
    let rp = pu(res.px)
    let gauss = o.gaussian
    let mono = o.mono
    parallelRows(h, y):
      for x in 0 ..< w:
        let i = y * w + x
        let p = rp[i]
        if p shr 24 == 0: continue
        template rnd(c: int): float =
          var hh = uint32(x) * 374761393'u32 + uint32(y) * 668265263'u32 + uint32(c) * 2246822519'u32
          hh = (hh xor (hh shr 13)) * 1274126177'u32
          hh = hh xor (hh shr 16)
          float(hh and 0xFFFF) / 65536
        template n(c: int): float =
          (if gauss: (rnd(c) + rnd(c + 7) + rnd(c + 13) - 1.5) * 1.15 else: rnd(c) - 0.5) * amt
        let nr = n(1)
        let ng = if mono: nr else: n(2)
        let nb = if mono: nr else: n(3)
        rp[i] = (p and 0xFF000000'u32) or
                (uint32(clamp(int(float((p shr 16) and 255) + nr), 0, 255)) shl 16) or
                (uint32(clamp(int(float((p shr 8) and 255) + ng), 0, 255)) shl 8) or
                uint32(clamp(int(float(p and 255) + nb), 0, 255))
  res

proc lensBlur*(o: LensBlur; depth: seq[uint8] = @[]; depthW = 0; depthH = 0): FilterFn =
  ## Blur > Lens Blur: as a camera's lens blurs -- the iris's shape in the
  ## discs bright points make, the lights brighter, noise to match the
  ## photo's grain. `depth` (`depthW` x `depthH`: the whole layer's, 0
  ## near .. 255 far: a layer mask, an alpha channel, `depthMapOf`) blurs
  ## by distance from the focal one; its part is found by `filterOrigin`.
  result = proc (src: Img; inner: Rect): Img =
    if depth.len == 0 or depthW <= 0 or depth.len != depthW * depthH:
      result = lensBlurImg(src, o, if depth.len == src.w * src.h: depth else: @[])
      return
    let (ox, oy) = filterOrigin
    var part = newSeqUninit[uint8](src.w * src.h)
    for y in 0 ..< src.h:
      let sy = clamp(oy + y, 0, depthH - 1)
      for x in 0 ..< src.w:
        part[y * src.w + x] = depth[sy * depthW + clamp(ox + x, 0, depthW - 1)]
    lensBlurImg(src, o, part)

{.pop.}
