## Filter > Neural Filters, made without a neural network: they run on the
## device, offline, at once. JPEG Artifacts Removal (the 8 x 8 blocks and
## the ringing of a compressed photo smoothed away), Photo Restoration (an
## old print's scratches, dust, noise, halftone dots and faded colors),
## Depth Blur (the background blurred as a lens would, by how far it is:
## the subject found, the ground assumed nearer at the bottom, what is
## already soft taken as far), Color Transfer and Harmonization (one
## picture's colors given another's), Super Zoom (bigger, its edges kept
## sharp). Skin Smoothing is in `photomerge`.
##
## Each takes an `Img` and gives one back, so they go into `FilterFn`s and
## previews like the other filters.
##
## ```nim
## d.beginStep("JPEG Artifacts Removal")
## d.applyFilter(8, jpegArtifactsRemoval(strength = 2))
## d.endStep()
## let look = colorStatsOf(other.px)      # another picture's colors (an Img)
## d.applyFilter(0, colorTransfer(look))
## ```

import std/[math, algorithm]
import gfx, photo, photofx, photosmart, parallel

{.push boundChecks: off, overflowChecks: off.}

template pixPtr(s: seq[uint32]): ptr UncheckedArray[uint32] =
  cast[ptr UncheckedArray[uint32]](if s.len > 0: unsafeAddr s[0] else: nil)

template fPtr(s: seq[float32]): ptr UncheckedArray[float32] =
  cast[ptr UncheckedArray[float32]](if s.len > 0: unsafeAddr s[0] else: nil)

proc ch(p: uint32; sh: int): float32 {.inline.} = float32((p shr sh) and 255)

proc pack(a: uint32; r, g, b: float32): uint32 {.inline.} =
  (a and 0xFF000000'u32) or (uint32(clamp(int(r + 0.5), 0, 255)) shl 16) or
    (uint32(clamp(int(g + 0.5), 0, 255)) shl 8) or uint32(clamp(int(b + 0.5), 0, 255))

proc boxBlurF(v: var seq[float32]; w, h, r: int) =
  ## A box blur of radius `r`, rows then columns (running sums), on all the cores.
  if r <= 0 or w <= 0 or h <= 0: return
  var tmp = newSeq[float32](w * h)
  let sp = fPtr(v)
  let tp = fPtr(tmp)
  parallelRows(h, y):
    var acc = 0'f32
    let row = y * w
    for x in -r .. r: acc += sp[row + clamp(x, 0, w - 1)]
    let k = 1'f32 / float32(2 * r + 1)
    for x in 0 ..< w:
      tp[row + x] = acc * k
      acc += sp[row + min(x + r + 1, w - 1)] - sp[row + max(x - r, 0)]
  parallelRows(w, x):
    var acc = 0'f32
    for y in -r .. r: acc += tp[clamp(y, 0, h - 1) * w + x]
    let k = 1'f32 / float32(2 * r + 1)
    for y in 0 ..< h:
      sp[y * w + x] = acc * k
      acc += tp[min(y + r + 1, h - 1) * w + x] - tp[max(y - r, 0) * w + x]

proc gaussF(v: var seq[float32]; w, h: int; sigma: float) =
  ## Close to a gaussian blur: three box blurs.
  if sigma <= 0.3: return
  let r = max(1, int(round(sigma * 0.87)))
  for _ in 0 ..< 3: boxBlurF(v, w, h, r)

# ---- YCbCr planes ----------------------------------------------------------------------------------------------

type Ycc = object
  w, h: int
  y, cb, cr: seq[float32]

proc toYcc(im: Img): Ycc =
  result = Ycc(w: im.w, h: im.h, y: newSeq[float32](im.w * im.h), cb: newSeq[float32](im.w * im.h),
               cr: newSeq[float32](im.w * im.h))
  let p = pixPtr(im.px)
  let yp = fPtr(result.y)
  let bp = fPtr(result.cb)
  let rp = fPtr(result.cr)
  let w = im.w
  parallelRows(im.h, j):
    for i in j * w ..< (j + 1) * w:
      let c = p[i]
      let r = ch(c, 16)
      let g = ch(c, 8)
      let b = ch(c, 0)
      yp[i] = 0.299'f32 * r + 0.587'f32 * g + 0.114'f32 * b
      bp[i] = -0.168736'f32 * r - 0.331264'f32 * g + 0.5'f32 * b
      rp[i] = 0.5'f32 * r - 0.418688'f32 * g - 0.081312'f32 * b

proc fromYcc(c: Ycc; alphaOf: Img): Img =
  result = newImg(c.w, c.h)
  let ap = pixPtr(alphaOf.px)
  let op = pixPtr(result.px)
  let yp = fPtr(c.y)
  let bp = fPtr(c.cb)
  let rp = fPtr(c.cr)
  let w = c.w
  parallelRows(c.h, j):
    for i in j * w ..< (j + 1) * w:
      let y = yp[i]
      let cb = bp[i]
      let cr = rp[i]
      op[i] = pack(ap[i], y + 1.402'f32 * cr, y - 0.344136'f32 * cb - 0.714136'f32 * cr, y + 1.772'f32 * cb)

# ---- JPEG Artifacts Removal ------------------------------------------------------------------------------------

proc deblock(v: var seq[float32]; w, h: int; t: float32) =
  ## The steps at the edges of the 8 x 8 blocks, where both sides are
  ## flat (a real edge is left), spread over three pixels each side.
  let p = fPtr(v)
  # (the edges between columns 8k-1 and 8k)
  parallelRows(h, y):
    let row = y * w
    var x = 8
    while x + 2 < w:
      if x >= 3:
        let a = p[row + x - 1]
        let b = p[row + x]
        let d = b - a
        let actL = abs(p[row + x - 1] - p[row + x - 2]) + abs(p[row + x - 2] - p[row + x - 3])
        let actR = abs(p[row + x + 1] - p[row + x]) + abs(p[row + x + 2] - p[row + x + 1])
        if abs(d) < t and actL < t * 0.6 and actR < t * 0.6:
          p[row + x - 3] += d * (1 / 8)
          p[row + x - 2] += d * (2 / 8)
          p[row + x - 1] += d * (3 / 8)
          p[row + x] -= d * (3 / 8)
          p[row + x + 1] -= d * (2 / 8)
          p[row + x + 2] -= d * (1 / 8)
      x += 8
  # (the edges between rows)
  parallelRows(w, x):
    var y = 8
    while y + 2 < h:
      if y >= 3:
        template at(k: int): untyped = p[(y + k) * w + x]
        let d = at(0) - at(-1)
        let actU = abs(at(-1) - at(-2)) + abs(at(-2) - at(-3))
        let actD = abs(at(1) - at(0)) + abs(at(2) - at(1))
        if abs(d) < t and actU < t * 0.6 and actD < t * 0.6:
          at(-3) += d * (1 / 8)
          at(-2) += d * (2 / 8)
          at(-1) += d * (3 / 8)
          at(0) -= d * (3 / 8)
          at(1) -= d * (2 / 8)
          at(2) -= d * (1 / 8)
      y += 8

proc edgeAwareSmooth(v: var seq[float32]; guide: seq[float32]; w, h: int; sigmaR: float32; radius: int) =
  ## A bilateral filter of `v` (3 x 3 or 5 x 5), its weights by how alike
  ## `guide` is: ringing and mosquito noise go, edges stay.
  let src = v
  let sp = fPtr(src)
  let gp = fPtr(guide)
  let dp = fPtr(v)
  let k = -1'f32 / (2 * sigmaR * sigmaR)
  parallelRows(h, y):
    for x in 0 ..< w:
      let c = gp[y * w + x]
      var acc = 0'f32
      var tot = 0'f32
      for dy in -radius .. radius:
        let yy = clamp(y + dy, 0, h - 1)
        for dx in -radius .. radius:
          let xx = clamp(x + dx, 0, w - 1)
          let g = gp[yy * w + xx] - c
          let ws = exp(k * g * g) * (if dx == 0 and dy == 0: 1'f32 else: 0.6'f32)
          acc += sp[yy * w + xx] * ws
          tot += ws
      dp[y * w + x] = acc / max(1e-6'f32, tot)

proc jpegCleanImg*(src: Img; strength = 1): Img =
  ## JPEG Artifacts Removal: the blocks and the ringing of a photo saved
  ## too small, smoothed away; edges and texture kept. `strength` 0 Low,
  ## 1 Medium, 2 High.
  let s = clamp(strength, 0, 2)
  var c = toYcc(src)
  let t = [7'f32, 11, 17][s]
  deblock(c.y, c.w, c.h, t)
  deblock(c.cb, c.w, c.h, t * 1.4)
  deblock(c.cr, c.w, c.h, t * 1.4)
  let guide = c.y
  edgeAwareSmooth(c.y, guide, c.w, c.h, [3.5'f32, 5, 7.5][s], 1)
  # (the colors were kept at half size: smoothed more, along the light's edges)
  edgeAwareSmooth(c.cb, guide, c.w, c.h, [8'f32, 12, 18][s], 2)
  edgeAwareSmooth(c.cr, guide, c.w, c.h, [8'f32, 12, 18][s], 2)
  fromYcc(c, src)

proc jpegArtifactsRemoval*(strength = 1): FilterFn =
  ## Filter > Neural Filters > JPEG Artifacts Removal.
  result = proc (src: Img; inner: Rect): Img = jpegCleanImg(src, strength)

# ---- Photo Restoration --------------------------------------------------------------------------------------------

proc autoTone(src: Img; amount: float): Img =
  ## Each channel stretched to its range (its darkest and lightest half
  ## percent clipped), by `amount` (0..1): a faded print's colors back.
  var hist: array[3, array[256, int]]
  for p in src.px:
    if (p shr 24) == 0: continue
    inc hist[0][(p shr 16) and 255]
    inc hist[1][(p shr 8) and 255]
    inc hist[2][p and 255]
  var lut: array[3, array[256, float32]]
  for c in 0 .. 2:
    var n = 0
    for v in hist[c]: n += v
    let cut = max(1, n div 200)
    var lo = 0
    var acc = 0
    while lo < 255 and acc + hist[c][lo] < cut:
      acc += hist[c][lo]
      inc lo
    var hi = 255
    acc = 0
    while hi > 0 and acc + hist[c][hi] < cut:
      acc += hist[c][hi]
      dec hi
    if hi <= lo + 8: (lo, hi) = (0, 255)
    for v in 0 .. 255:
      let s = clamp((v - lo).float / (hi - lo).float * 255, 0.0, 255.0)
      lut[c][v] = float32(v.float + (s - v.float) * amount)
  result = newImg(src.w, src.h)
  for i, p in src.px:
    result.px[i] = pack(p, lut[0][(p shr 16) and 255], lut[1][(p shr 8) and 255], lut[2][p and 255])

proc restoreImg*(src: Img; enhance = 50; scratches = 50; noise = 30; colorNoise = 40; halftone = 0): Img =
  ## Photo Restoration: an old photo (a scan of a print) mended -- its
  ## scratches and dust, its grain and color noise, halftone dots, its
  ## faded tones. Each 0..100 (0: not done).
  var c = toYcc(src)
  let w = c.w
  let h = c.h
  if halftone > 0:
    # (the dots blurred away at their size, the detail sharpened back a little)
    let sig = 0.8 + halftone.float / 100 * 1.6
    gaussF(c.y, w, h, sig)
    gaussF(c.cb, w, h, sig)
    gaussF(c.cr, w, h, sig)
  if scratches > 0:
    # (a pixel much lighter or darker than the middle value round it, in a
    # thin line or a speck, takes that value)
    let t = 70'f32 - scratches.float32 * 0.55'f32
    let r = if scratches > 60: 2 else: 1
    let srcY = c.y
    let sp = fPtr(srcY)
    let yp = fPtr(c.y)
    parallelRows(h, y):
      var win: array[25, float32]
      for x in 0 ..< w:
        var n = 0
        for dy in -r .. r:
          let yy = clamp(y + dy, 0, h - 1)
          for dx in -r .. r:
            win[n] = sp[yy * w + clamp(x + dx, 0, w - 1)]
            inc n
        # (the middle value: a partial sort of so few)
        for i in 0 .. n div 2:
          var m = i
          for j in i + 1 ..< n:
            if win[j] < win[m]: m = j
          swap(win[i], win[m])
        let med = win[n div 2]
        if abs(sp[y * w + x] - med) > t: yp[y * w + x] = med
  if noise > 0:
    edgeAwareSmooth(c.y, c.y, w, h, 2'f32 + noise.float32 * 0.09'f32, 1)
  if colorNoise > 0:
    let g = c.y
    edgeAwareSmooth(c.cb, g, w, h, 6'f32 + colorNoise.float32 * 0.2'f32, 2)
    edgeAwareSmooth(c.cr, g, w, h, 6'f32 + colorNoise.float32 * 0.2'f32, 2)
  if halftone > 0:
    var bl = c.y
    gaussF(bl, w, h, 1.2)
    let k = halftone.float32 / 100 * 0.6'f32
    for i in 0 ..< w * h: c.y[i] += (c.y[i] - bl[i]) * k
  result = fromYcc(c, src)
  if enhance > 0:
    result = autoTone(result, enhance / 100)
    # (and a little more local contrast: a soft unsharp mask)
    var lum = newSeq[float32](w * h)
    for i, p in result.px: lum[i] = 0.299'f32 * ch(p, 16) + 0.587'f32 * ch(p, 8) + 0.114'f32 * ch(p, 0)
    var bl = lum
    gaussF(bl, w, h, max(2.0, min(w, h).float / 60))
    let k = enhance.float32 / 100 * 0.35'f32
    for i in 0 ..< w * h:
      let d = (lum[i] - bl[i]) * k
      let p = result.px[i]
      result.px[i] = pack(p, ch(p, 16) + d, ch(p, 8) + d, ch(p, 0) + d)

proc photoRestoration*(enhance = 50; scratches = 50; noise = 30; colorNoise = 40; halftone = 0): FilterFn =
  ## Filter > Neural Filters > Photo Restoration.
  result = proc (src: Img; inner: Rect): Img = restoreImg(src, enhance, scratches, noise, colorNoise, halftone)

# ---- Depth Blur -----------------------------------------------------------------------------------------------------

var depthHook*: proc (src: Img): seq[uint8] {.closure.} = nil
  ## When set, `depthMapOf` asks it first -- a model trained to see depth in one picture
  ## (`retroui/vision`'s `depthOf`, as Retro Atelier sets it when one is on the device) -- 0 near
  ## .. 255 far per pixel of `src`; empty: the picture's own cues, as without it.

proc depthMapOf*(src: Img; subject: seq[uint8] = @[]): seq[uint8] =
  ## How far each pixel seems (0 near .. 255 far), without a depth camera:
  ## the subject is near (`subject`: its mask, as `selectSubject` finds;
  ## empty: found here), the ground nearer toward the bottom, what is
  ## already soft (out of focus, haze) farther. (`depthHook`, when set, first.)
  let w = src.w
  let h = src.h
  if depthHook != nil and w >= 8 and h >= 8:
    let m = depthHook(src)
    if m.len == w * h: return m
  let subj = if subject.len == w * h: subject else: selectSubject(src)
  # (sharpness: the local contrast of the light, blurred wide)
  var lum = newSeq[float32](w * h)
  for i, p in src.px: lum[i] = 0.299'f32 * ch(p, 16) + 0.587'f32 * ch(p, 8) + 0.114'f32 * ch(p, 0)
  var bl = lum
  gaussF(bl, w, h, 1.5)
  var sharp = newSeq[float32](w * h)
  for i in 0 ..< w * h: sharp[i] = abs(lum[i] - bl[i])
  gaussF(sharp, w, h, max(3.0, min(w, h).float / 40))
  var top = 1e-3'f32
  for v in sharp: top = max(top, v)
  # (the subject's own depth: near; blurred so its edge goes gently)
  var sf = newSeq[float32](w * h)
  for i in 0 ..< w * h: sf[i] = subj[i].float32 / 255
  gaussF(sf, w, h, max(2.0, min(w, h).float / 120))
  result = newSeq[uint8](w * h)
  for y in 0 ..< h:
    let ground = 1 - y.float32 / max(1, h - 1).float32       # (1 at the top: farther)
    for x in 0 ..< w:
      let i = y * w + x
      let soft = 1 - min(1'f32, sharp[i] / (top * 0.6'f32))
      var far = 0.55'f32 * ground + 0.45'f32 * soft
      far = far * (1 - sf[i]) + 0.02'f32 * sf[i]
      result[i] = uint8(clamp(int(far * 255 + 0.5), 0, 255))

proc depthBlurImg*(src: Img; depth: seq[uint8]; strength = 50; focal = 0; focalRange = 30; haze = 0;
                   warmth = 0; brightness = 0; saturation = 0; grain = 0): Img =
  ## Depth Blur: what is far from the focal distance (`focal` 0 near ..
  ## 100 far, within `focalRange` sharp) blurred as a lens would, by how
  ## far it is (`depth`: `depthMapOf`); then haze in the distance, warmth,
  ## brightness and saturation, grain.
  let w = src.w
  let h = src.h
  if depth.len != w * h: return src
  let maxSigma = max(0.5, strength.float / 100 * min(w, h).float / 45)
  # (the picture blurred to a few depths, mixed between at each pixel)
  const levels = 5
  var planes: array[levels, array[3, seq[float32]]]
  var base: array[3, seq[float32]]
  for c in 0 .. 2:
    base[c] = newSeq[float32](w * h)
    let sh = 16 - 8 * c
    for i, p in src.px: base[c][i] = ch(p, sh)
  for l in 0 ..< levels:
    let sig = maxSigma * l.float / (levels - 1).float
    for c in 0 .. 2:
      planes[l][c] = base[c]
      gaussF(planes[l][c], w, h, sig)
  let f0 = clamp(focal, 0, 100).float32 / 100 * 255
  let rng = max(1'f32, clamp(focalRange, 0, 100).float32 / 100 * 255 * 0.5'f32)
  result = newImg(w, h)
  var rnd = 0x9E3779B9'u32
  let warm = warmth.float32 / 100 * 30
  let bright = brightness.float32 / 100 * 60
  let sat = 1 + saturation.float32 / 100
  for i in 0 ..< w * h:
    let dd = depth[i].float32
    let off = max(0'f32, abs(dd - f0) - rng) / max(1'f32, 255 - rng)
    let lv = clamp(off * (levels - 1).float32 * 1.4'f32, 0, (levels - 1).float32)
    let l0 = int(lv)
    let l1 = min(l0 + 1, levels - 1)
    let t = lv - l0.float32
    var col: array[3, float32]
    for c in 0 .. 2: col[c] = planes[l0][c][i] * (1 - t) + planes[l1][c][i] * t
    let farK = dd / 255
    if haze > 0:
      let hz = haze.float32 / 100 * farK * farK * 0.8'f32
      for c in 0 .. 2: col[c] = col[c] + (235 - col[c]) * hz
    col[0] += warm * (0.4'f32 + 0.6'f32 * farK)
    col[2] -= warm * (0.4'f32 + 0.6'f32 * farK)
    for c in 0 .. 2: col[c] += bright
    if saturation != 0:
      let g = 0.299'f32 * col[0] + 0.587'f32 * col[1] + 0.114'f32 * col[2]
      for c in 0 .. 2: col[c] = g + (col[c] - g) * sat
    if grain > 0:
      rnd = rnd xor (rnd shl 13); rnd = rnd xor (rnd shr 17); rnd = rnd xor (rnd shl 5)
      let n = (float32(rnd and 0xFFFF) / 65535 - 0.5'f32) * grain.float32 * 0.5'f32
      for c in 0 .. 2: col[c] += n
    result.px[i] = pack(src.px[i], col[0], col[1], col[2])

# ---- Color Transfer, Harmonization ----------------------------------------------------------------------------------

type ColorStats* = object
  ## The colors of a picture in short: the mean and the spread of its
  ## lightness and of its two color axes (Lab).
  mean*, sd*: array[3, float]   ## the mean and standard deviation of L, a, b

var srgbLin: array[256, float32]
for i in 0 .. 255:
  let c = i.float / 255
  srgbLin[i] = float32(if c <= 0.04045: c / 12.92 else: pow((c + 0.055) / 1.055, 2.4))

proc labOf(p: uint32): array[3, float32] {.inline.} =
  let r = srgbLin[(p shr 16) and 255]
  let g = srgbLin[(p shr 8) and 255]
  let b = srgbLin[p and 255]
  let x = (0.4124'f32 * r + 0.3576'f32 * g + 0.1805'f32 * b) / 0.95047'f32
  let y = 0.2126'f32 * r + 0.7152'f32 * g + 0.0722'f32 * b
  let z = (0.0193'f32 * r + 0.1192'f32 * g + 0.9505'f32 * b) / 1.08883'f32
  template f(t: float32): float32 =
    (if t > 0.008856'f32: pow(t, 1'f32 / 3) else: 7.787'f32 * t + 16'f32 / 116)
  let fx = f(x)
  let fy = f(y)
  let fz = f(z)
  [116 * fy - 16, 500 * (fx - fy), 200 * (fy - fz)]

proc fromLab(a: uint32; lab: array[3, float32]): uint32 {.inline.} =
  let fy = (lab[0] + 16) / 116
  let fx = fy + lab[1] / 500
  let fz = fy - lab[2] / 200
  template finv(t: float32): float32 =
    (if t * t * t > 0.008856'f32: t * t * t else: (t - 16'f32 / 116) / 7.787'f32)
  let x = finv(fx) * 0.95047'f32
  let y = finv(fy)
  let z = finv(fz) * 1.08883'f32
  var rgb = [3.2406'f32 * x - 1.5372'f32 * y - 0.4986'f32 * z,
             -0.9689'f32 * x + 1.8758'f32 * y + 0.0415'f32 * z,
             0.0557'f32 * x - 0.2040'f32 * y + 1.0570'f32 * z]
  for c in rgb.mitems:
    c = clamp(c, 0, 1)
    c = (if c <= 0.0031308'f32: 12.92'f32 * c else: 1.055'f32 * pow(c, 1 / 2.4'f32) - 0.055'f32) * 255
  pack(a, rgb[0], rgb[1], rgb[2])

proc colorStatsOf*(px: openArray[uint32]; mask: openArray[uint8] = []): ColorStats =
  ## The colors of `px` (where `mask` is, when given; transparent pixels
  ## left out), in short. (A big picture: every so many pixels.)
  var s, s2: array[3, float]
  var n = 0.0
  let step = max(1, px.len div 250_000)
  var i = 0
  while i < px.len:
    let p = px[i]
    let wgt = (if mask.len == px.len: mask[i].float / 255 else: 1.0) * float(p shr 24) / 255
    if wgt > 0.01:
      let l = labOf(p)
      for c in 0 .. 2:
        s[c] += l[c] * wgt
        s2[c] += l[c] * l[c] * wgt
      n += wgt
    i += step
  if n <= 0: return ColorStats(sd: [1.0, 1.0, 1.0])
  for c in 0 .. 2:
    result.mean[c] = s[c] / n
    result.sd[c] = sqrt(max(1e-4, s2[c] / n - result.mean[c] * result.mean[c]))

proc colorTransferImg*(src: Img; target: ColorStats; luminance = 100; intensity = 100; saturation = 0;
                       fade = 0; mask: seq[uint8] = @[]): Img =
  ## Color Transfer: `src` given the colors of the picture `target` sums up
  ## -- its lightness (`luminance` %), its colors (`intensity` %) -- then
  ## `saturation` (-100..100), and faded back toward `src` by `fade` %.
  ## (`mask`: where, as big as `src`; empty everywhere.)
  let me = colorStatsOf(src.px)
  let kl = clamp(luminance, 0, 100).float / 100
  let kc = clamp(intensity, 0, 200).float / 100
  let sat = float32(1 + clamp(saturation, -100, 100).float / 100)
  let keep = clamp(fade, 0, 100).float / 100
  result = newImg(src.w, src.h)
  let sp = pixPtr(src.px)
  let op = pixPtr(result.px)
  let mp = if mask.len == src.w * src.h: cast[ptr UncheckedArray[uint8]](unsafeAddr mask[0]) else: nil
  let w = src.w
  let mm = me
  let tg = target
  parallelRows(src.h, y):
    for i in y * w ..< (y + 1) * w:
      let p = sp[i]
      if (p shr 24) == 0 or (mp != nil and mp[i] == 0):
        op[i] = p
        continue
      var l = labOf(p)
      for c in 0 .. 2:
        let k = if c == 0: kl else: kc
        let want = (l[c] - mm.mean[c].float32) * float32(tg.sd[c] / max(1e-3, mm.sd[c])) + tg.mean[c].float32
        l[c] = l[c] + (want - l[c]) * float32(min(1.0, k))
      if sat != 1:
        l[1] *= sat
        l[2] *= sat
      var q = fromLab(p, l)
      var amt = 1 - keep
      if mp != nil: amt *= mp[i].float / 255
      if amt < 0.999:
        q = pack(p, ch(p, 16) + (ch(q, 16) - ch(p, 16)) * amt, ch(p, 8) + (ch(q, 8) - ch(p, 8)) * amt,
                 ch(p, 0) + (ch(q, 0) - ch(p, 0)) * amt)
      op[i] = q

proc colorTransfer*(target: ColorStats; luminance = 100; intensity = 100; saturation = 0; fade = 0): FilterFn =
  ## Filter > Neural Filters > Color Transfer.
  result = proc (src: Img; inner: Rect): Img =
    colorTransferImg(src, target, luminance, intensity, saturation, fade)

proc harmonize*(d: Doc; L: Layer; intensity = 70; brightness = 0; saturation = 0): FilterFn =
  ## Filter > Neural Filters > Harmonization: the layer's colors and light
  ## made to fit what is under it (the layers below, mixed), so it sits in
  ## the picture. Make it before the step (it reads the layers below).
  var below = newSeq[uint32](d.w * d.h)
  let k = d.layers.find(L)
  var cnt = 0
  for j in 0 ..< max(0, k):
    let B = d.layers[j]
    if not B.visible or B.group or B.adjust.kind.len > 0 or B.px.len != d.w * d.h: continue
    for i in 0 ..< d.w * d.h:
      below[i] = blendPx(below[i], B.px[i], B.opacity * 255 div 100, B.mode)
    inc cnt
  let target = if cnt > 0: colorStatsOf(below) else: colorStatsOf(L.px)
  result = proc (src: Img; inner: Rect): Img =
    var o = colorTransferImg(src, target, intensity * 6 div 10, intensity, saturation)
    if brightness != 0:
      let b = brightness.float32 * 0.6'f32
      for p in o.px.mitems: p = pack(p, ch(p, 16) + b, ch(p, 8) + b, ch(p, 0) + b)
    o

# ---- Super Zoom ------------------------------------------------------------------------------------------------------

proc superZoomImg*(src: Img; factor = 2; details = 50; removeJpeg = false; noise = 0): Img =
  ## Super Zoom: `src` made `factor` times bigger (2..4) -- cleaned first
  ## (`removeJpeg`, `noise` 0..100), enlarged smoothly (Lanczos), its edges
  ## made sharp again and its fine detail brought up (`details` 0..100),
  ## without halos on smooth parts.
  var s = src
  if removeJpeg: s = jpegCleanImg(s, 1)
  if noise > 0:
    var c = toYcc(s)
    edgeAwareSmooth(c.y, c.y, c.w, c.h, 2'f32 + noise.float32 * 0.08'f32, 1)
    edgeAwareSmooth(c.cb, c.y, c.w, c.h, 8'f32, 2)
    edgeAwareSmooth(c.cr, c.y, c.w, c.h, 8'f32, 2)
    s = fromYcc(c, s)
  let f = clamp(factor, 2, 4)
  let nw = s.w * f
  let nh = s.h * f
  result = Img(w: nw, h: nh, px: resample(s.px, s.w, s.h, nw, nh, rsLanczos))
  if details <= 0: return
  # (an unsharp mask on the light at the scale of the old pixels, its
  # strength by how strong the edge is: crisp edges, quiet flat parts)
  var lum = newSeq[float32](nw * nh)
  for i, p in result.px: lum[i] = 0.299'f32 * ch(p, 16) + 0.587'f32 * ch(p, 8) + 0.114'f32 * ch(p, 0)
  var bl = lum
  gaussF(bl, nw, nh, f.float * 0.9)
  let amt = details.float32 / 100 * 1.4'f32
  let rp = pixPtr(result.px)
  let lp = fPtr(lum)
  let bp = fPtr(bl)
  parallelRows(nh, y):
    for i in y * nw ..< (y + 1) * nw:
      let dd = lp[i] - bp[i]
      let gate = min(1'f32, abs(dd) / 6'f32)        # (tiny differences: noise, left)
      let add = dd * amt * gate
      let p = rp[i]
      rp[i] = pack(p, ch(p, 16) + add, ch(p, 8) + add, ch(p, 0) + add)

{.pop.}
