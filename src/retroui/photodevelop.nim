## Develop: the everyday corrections of a photo in one go, as camera raw
## programs make them -- white balance, exposure, contrast, highlights,
## shadows, whites, blacks, clarity, dehaze, vibrance, saturation, noise
## reduction, sharpening, vignette and grain -- with Auto and presets. And
## the automatic corrections and newer adjustments of the Image menu: Auto
## Tone, Auto Contrast, Auto Color, Shadows/Highlights, Vibrance, Exposure,
## Photo Filter, Black & White, Channel Mixer.
##
## Develop works in three parts so a dialog can preview it quickly:
##
## ```nim
## let small = smallCopy(img, 400)              # the whole picture, small
## let base = developBase(small, s, img.w, img.h) # the light around each pixel
## let out = developImg(img, s, base)           # (or a part, or a small copy)
## ```
##
## `develop(s)` is the same as a filter of a whole layer.

import std/[math, algorithm, strutils]
import gfx, photo, photofx, parallel

type
  Develop* = object
    ## The settings, each 0 when it changes nothing.
    temperature*, tint*: int       ## -100..100: bluer..yellower, greener..more magenta
    exposure*: int                 ## -500..500: hundredths of a stop (+100: twice the light)
    contrast*, highlights*, shadows*, whites*, blacks*: int   ## -100..100
    clarity*, dehaze*, vibrance*, saturation*: int            ## -100..100
    sharpen*: int                  ## 0..150
    sharpenRadius*: int            ## 5..30: tenths of a pixel (0: 1 pixel)
    noise*, colorNoise*: int       ## 0..100: noise reduction, of the light and of the color
    vignette*: int                 ## -100..100: darker..lighter corners
    grain*: int                    ## 0..100

  DevelopBase* = object
    ## What Develop works out from a small copy of the whole picture: the
    ## light around each pixel (for highlights, shadows and clarity) and
    ## the haze.
    fullW*, fullH*: int            ## the picture's size
    w, h: int                      ## the small copy's
    f: float                       ## picture pixels per small pixel
    coef: seq[float32]             ## per small pixel: 5 numbers (see `developBase`)
    air: array[3, float32]         ## the color of the haze (linear)
    local, haze: bool

const
  CoefN = 5                        # a, b of the shadows / highlights light, of clarity; haze

template fptr(s: seq[float32]): ptr UncheckedArray[float32] =
  cast[ptr UncheckedArray[float32]](if s.len > 0: unsafeAddr s[0] else: nil)

template pptr(s: seq[uint32]): ptr UncheckedArray[uint32] =
  cast[ptr UncheckedArray[uint32]](if s.len > 0: unsafeAddr s[0] else: nil)

proc isNeutral*(s: Develop): bool =
  ## True when `s` changes nothing.
  var z = s
  z.sharpenRadius = 0
  z == Develop()

# ---- colors as numbers ----------------------------------------------------------------------------------

var
  linOf: array[256, float32]       # a level as light (sRGB decoded)
  gamOf: array[4097, float32]      # light 0..1 as a level 0..1 (sRGB encoded)

proc initTables() =
  if gamOf[4096] != 0: return
  for i in 0 .. 255:
    let v = i / 255
    linOf[i] = float32(if v <= 0.04045: v / 12.92 else: pow((v + 0.055) / 1.055, 2.4))
  for i in 0 .. 4096:
    let v = i / 4096
    gamOf[i] = float32(if v <= 0.0031308: v * 12.92 else: 1.055 * pow(v, 1 / 2.4) - 0.055)

initTables()

{.push boundChecks: off, overflowChecks: off.}

proc toGam(x: float32): float32 {.inline.} =
  ## Light (0..1) to a level (0..1).
  if x <= 0: return 0
  if x >= 1: return 1
  let t = x * 4096
  let i = int(t)
  let f = t - float32(i)
  gamOf[i] + (gamOf[min(i + 1, 4096)] - gamOf[i]) * f

proc toLin(x: float32): float32 {.inline.} =
  ## A level (0..1) to light (the exact formula: for values between levels).
  if x <= 0.04045: x / 12.92 else: pow((x + 0.055) / 1.055, 2.4)

proc lvl(x: float32): uint32 {.inline.} =
  uint32(clamp(int(x * 255 + 0.5), 0, 255))

proc smooth01(t: float32): float32 {.inline.} =
  let u = clamp(t, 0, 1)
  u * u * (3 - 2 * u)

# ---- box means of planes of numbers ---------------------------------------------------------------------

proc boxMean(src, dst, tmp: ptr UncheckedArray[float32]; w, h, r: int;
             acc: ptr UncheckedArray[float64]) =
  ## The mean of each pixel's (2r+1) x (2r+1) square (cut at the edges) of
  ## `src` into `dst` (which may be `src`). `tmp` holds w*h, `acc` w.
  if r <= 0:
    if dst != src: copyMem(dst, src, w * h * sizeof(float32))
    return
  for y in 0 ..< h:
    let row = y * w
    var s = 0.0
    for x in 0 .. min(r, w - 1): s += src[row + x].float
    for x in 0 ..< w:
      let n = min(x + r, w - 1) - max(x - r, 0) + 1
      tmp[row + x] = float32(s / n.float)
      if x + r + 1 < w: s += src[row + x + r + 1].float
      if x - r >= 0: s -= src[row + x - r].float
  for x in 0 ..< w: acc[x] = 0
  for y in 0 .. min(r, h - 1):
    for x in 0 ..< w: acc[x] += tmp[y * w + x].float
  for y in 0 ..< h:
    let n = float(min(y + r, h - 1) - max(y - r, 0) + 1)
    let row = y * w
    for x in 0 ..< w: dst[row + x] = float32(acc[x] / n)
    if y + r + 1 < h:
      let add = (y + r + 1) * w
      for x in 0 ..< w: acc[x] += tmp[add + x].float
    if y - r >= 0:
      let sub = (y - r) * w
      for x in 0 ..< w: acc[x] -= tmp[sub + x].float

proc guidedCoef(I: ptr UncheckedArray[float32]; w, h, r: int; eps: float32;
                outA, outB: ptr UncheckedArray[float32]) =
  ## The guided filter of `I` by itself (edges kept): the smoothed `a` and
  ## `b` with which `a * I + b` is `I` smoothed.
  let n = w * h
  var mI = newSeq[float32](n)
  var mII = newSeq[float32](n)
  var tmp = newSeq[float32](n)
  var acc = newSeq[float64](w)
  for i in 0 ..< n: mII[i] = I[i] * I[i]
  boxMean(I, fptr(mI), fptr(tmp), w, h, r, cast[ptr UncheckedArray[float64]](addr acc[0]))
  boxMean(fptr(mII), fptr(mII), fptr(tmp), w, h, r, cast[ptr UncheckedArray[float64]](addr acc[0]))
  for i in 0 ..< n:
    let v = max(0'f32, mII[i] - mI[i] * mI[i])
    let a = v / (v + eps)
    outA[i] = a
    outB[i] = mI[i] - a * mI[i]
  boxMean(outA, outA, fptr(tmp), w, h, r, cast[ptr UncheckedArray[float64]](addr acc[0]))
  boxMean(outB, outB, fptr(tmp), w, h, r, cast[ptr UncheckedArray[float64]](addr acc[0]))

{.pop.}

# ---- a small copy ---------------------------------------------------------------------------------------

proc smallCopy*(px: seq[uint32]; stride: int; r: Rect; maxSide: int): Img =
  ## The part `r` of the pixels `px` (`stride` wide) made at most `maxSide`
  ## pixels long, each pixel the average of the ones it stands for.
  if r.w <= 0 or r.h <= 0 or px.len < (r.y + r.h - 1) * stride + r.x + r.w: return Img()
  let f = max(1.0, max(r.w, r.h) / max(1, maxSide))
  let w = max(1, int(round(r.w.float / f)))
  let h = max(1, int(round(r.h.float / f)))
  result = newImg(w, h)
  let sp = pptr(px)
  let dp = pptr(result.px)
  let rx = r.x
  let ry = r.y
  let sw = r.w
  let sh = r.h
  parallelRows(h, y):
    let y0 = y * sh div h
    let y1 = max(y0 + 1, (y + 1) * sh div h)
    for x in 0 ..< w:
      let x0 = x * sw div w
      let x1 = max(x0 + 1, (x + 1) * sw div w)
      var a, rr, g, b: uint64
      for yy in y0 ..< y1:
        let row = (ry + yy) * stride + rx
        for xx in x0 ..< x1:
          let p = sp[row + xx]
          let pa = uint64(p shr 24)
          a += pa
          rr += uint64((p shr 16) and 255) * pa
          g += uint64((p shr 8) and 255) * pa
          b += uint64(p and 255) * pa
      let n = uint64((y1 - y0) * (x1 - x0))
      dp[y * w + x] = if a == 0: 0'u32
                      else: (uint32((a + n div 2) div n) shl 24) or (uint32(rr div a) shl 16) or
                            (uint32(g div a) shl 8) or uint32(b div a)

proc smallCopy*(src: Img; maxSide: int): Img =
  ## `src` made at most `maxSide` pixels long, each pixel the average of the
  ## ones it stands for (as is, when it is small enough).
  if src.w <= maxSide and src.h <= maxSide or src.w <= 0 or src.h <= 0: return src
  smallCopy(src.px, src.w, rect(0, 0, src.w, src.h), maxSide)

# ---- the settings as numbers ------------------------------------------------------------------------------

type Prepared = object
  gain: array[3, float32]          # white balance and exposure
  shoulder: float32                # how much the light past white is rolled off (0..1)
  tone: array[1025, float32]       # contrast, whites, blacks: level to level
  toned: bool
  sh, hl, cl, dh: float32          # shadows, highlights, clarity, dehaze (-1..1)
  sat, vib: float32
  vig, grain: float32

proc prepare(s: Develop): Prepared =
  let t = float32(clamp(s.temperature, -100, 100)) / 100
  let ti = float32(clamp(s.tint, -100, 100)) / 100
  var g = [exp(0.45'f32 * t), exp(-0.35'f32 * ti), exp(-0.45'f32 * t)]
  # (a gray keeps its lightness)
  let l = 0.2126'f32 * g[0] + 0.7152'f32 * g[1] + 0.0722'f32 * g[2]
  let e = pow(2'f32, float32(clamp(s.exposure, -500, 500)) / 100)
  for c in 0 .. 2: result.gain[c] = g[c] / l * e
  result.shoulder = clamp((max(result.gain[0], max(result.gain[1], result.gain[2])) - 1) * 3, 0, 1)
  let co = float32(clamp(s.contrast, -100, 100)) / 100
  let wh = float32(clamp(s.whites, -100, 100)) / 100
  let bl = float32(clamp(s.blacks, -100, 100)) / 100
  result.toned = co != 0 or wh != 0 or bl != 0
  for i in 0 .. 1024:
    var y = float32(i) / 1024
    if co != 0: y = y + co * 0.4 * (y * y * (3 - 2 * y) - y)
    if wh != 0: y = y + wh * 0.2 * pow(y, 5)
    if bl != 0: y = y + bl * 0.2 * pow(1 - y, 5)
    result.tone[i] = clamp(y, 0, 1)
  result.sh = float32(clamp(s.shadows, -100, 100)) / 100
  result.hl = float32(clamp(s.highlights, -100, 100)) / 100
  result.cl = float32(clamp(s.clarity, -100, 100)) / 100
  result.dh = float32(clamp(s.dehaze, -100, 100)) / 100
  result.sat = float32(clamp(s.saturation, -100, 100)) / 100
  result.vib = float32(clamp(s.vibrance, -100, 100)) / 100
  result.vig = float32(clamp(s.vignette, -100, 100)) / 100
  result.grain = float32(clamp(s.grain, 0, 100)) / 100

{.push boundChecks: off, overflowChecks: off.}

template exposeLin(pr: Prepared; r, g, b: var float32) =
  ## White balance and exposure on light; what goes past white rolled off.
  r *= pr.gain[0]
  g *= pr.gain[1]
  b *= pr.gain[2]
  if pr.shoulder > 0:
    for v in [addr r, addr g, addr b]:
      if v[] > 0.75:
        let soft = 0.75'f32 + 0.25'f32 * (1 - exp(-(v[] - 0.75'f32) / 0.25'f32))
        v[] = min(v[], 1) + (soft - min(v[], 1)) * pr.shoulder

proc toneAt(pr: ptr Prepared; x: float32): float32 {.inline.} =
  let t = clamp(x, 0, 1) * 1024
  let i = min(int(t), 1023)
  let f = t - float32(i)
  pr.tone[i] + (pr.tone[i + 1] - pr.tone[i]) * f

proc hash01(x, y: int): float32 {.inline.} =
  var h = uint32(x) * 374761393'u32 + uint32(y) * 668265263'u32   # (wraps: no overflow where int has 32 bits)
  h = (h xor (h shr 13)) * 1274126177'u32
  h = h xor (h shr 16)
  float32(h and 0xFFFF) / 32767.5'f32 - 1

{.pop.}

# ---- the light around each pixel --------------------------------------------------------------------------

proc developBase*(small: Img; s: Develop; fullW, fullH: int): DevelopBase =
  ## What `developImg` needs of the whole picture (`fullW` x `fullH`),
  ## worked out from `small`, a small copy of it (`smallCopy`).
  result.fullW = max(1, fullW)
  result.fullH = max(1, fullH)
  result.w = max(1, small.w)
  result.h = max(1, small.h)
  result.f = result.fullW / result.w
  let pr = prepare(s)
  result.local = pr.sh != 0 or pr.hl != 0 or pr.cl != 0
  result.haze = pr.dh != 0
  if not (result.local or result.haze) or small.px.len < result.w * result.h: return
  let w = result.w
  let h = result.h
  let n = w * h
  result.coef = newSeq[float32](n * CoefN)
  let side = max(fullW, fullH).float / result.f      # the picture's length, in small pixels
  # the haze: the darkest of the three lights around each pixel
  var hz = newSeq[float32](n)
  var air: array[3, float32]
  if result.haze:
    var dark = newSeq[float32](n)
    for i in 0 ..< n:
      let p = small.px[i]
      dark[i] = min(linOf[rOf(p)], min(linOf[gOf(p)], linOf[bOf(p)]))
    let rh = max(1, int(round(side * 0.006)))
    var mn = newSeq[float32](n)
    for y in 0 ..< h:
      for x in 0 ..< w:
        var m = 1'f32
        for yy in max(0, y - rh) .. min(h - 1, y + rh):
          for xx in max(0, x - rh) .. min(w - 1, x + rh):
            m = min(m, dark[yy * w + xx])
        mn[y * w + x] = m
    # the color of the haze: of the haziest pixels
    var order = mn
    order.sort()
    let cut = order[max(0, n - 1 - n div 1000)]
    var cnt = 0
    for i in 0 ..< n:
      if mn[i] >= cut:
        let p = small.px[i]
        air[0] += linOf[rOf(p)]; air[1] += linOf[gOf(p)]; air[2] += linOf[bOf(p)]
        inc cnt
    for c in 0 .. 2: air[c] = max(0.35'f32, air[c] / max(1, cnt).float32)
    var tmp = newSeq[float32](n)
    var acc = newSeq[float64](w)
    let accp = cast[ptr UncheckedArray[float64]](addr acc[0])
    boxMean(fptr(mn), fptr(hz), fptr(tmp), w, h, 2 * rh, accp)
    boxMean(fptr(hz), fptr(hz), fptr(tmp), w, h, 2 * rh, accp)
    let am = max(air[0], max(air[1], air[2]))
    for i in 0 ..< n: hz[i] = clamp(hz[i] / am, 0, 1)
  result.air = air
  # the lightness after exposure and dehaze, smoothed keeping the edges
  if result.local:
    var Y = newSeq[float32](n)
    for i in 0 ..< n:
      let p = small.px[i]
      var r = linOf[rOf(p)]
      var g = linOf[gOf(p)]
      var b = linOf[bOf(p)]
      if result.haze:
        let t = if pr.dh > 0: min(0.9'f32, pr.dh * 0.95'f32 * hz[i]) else: -pr.dh * 0.5'f32
        if pr.dh > 0:
          r = max(0, (r - air[0] * t) / (1 - t)); g = max(0, (g - air[1] * t) / (1 - t))
          b = max(0, (b - air[2] * t) / (1 - t))
        else:
          r = r * (1 - t) + air[0] * t; g = g * (1 - t) + air[1] * t; b = b * (1 - t) + air[2] * t
      exposeLin(pr, r, g, b)
      Y[i] = 0.2126'f32 * toGam(r) + 0.7152'f32 * toGam(g) + 0.0722'f32 * toGam(b)
    var a = newSeq[float32](n)
    var bb = newSeq[float32](n)
    guidedCoef(fptr(Y), w, h, max(1, int(round(side * 0.035))), 0.02, fptr(a), fptr(bb))
    for i in 0 ..< n:
      result.coef[i * CoefN] = a[i]
      result.coef[i * CoefN + 1] = bb[i]
    guidedCoef(fptr(Y), w, h, max(1, int(round(side * 0.012))), 0.008, fptr(a), fptr(bb))
    for i in 0 ..< n:
      result.coef[i * CoefN + 2] = a[i]
      result.coef[i * CoefN + 3] = bb[i]
  if result.haze:
    for i in 0 ..< n: result.coef[i * CoefN + 4] = hz[i]

# ---- the detail: noise reduction and sharpening ----------------------------------------------------------

proc detailImg*(im: Img; noise, colorNoise, sharpen: int; sharpenRadius = 1.0; scale = 1.0): Img =
  ## Less noise (of the light: edges kept; of the color: smoothed), then
  ## sharper: the detail part of Develop, and Reduce Noise. `scale`: picture
  ## pixels per pixel of `im` (a small copy shows less of it). In strips
  ## of rows, on all the cores.
  let w = im.w
  let h = im.h
  if w <= 0 or h <= 0: return im
  let sc = max(1.0, scale)
  let nr = if noise > 0: int(round((1 + noise / 40) / sc)) else: 0
  let eps = float32((clamp(noise, 0, 100) / 100 * 0.07) ^ 2)
  let cr = if colorNoise > 0: int(round((1 + colorNoise / 25) / sc)) else: 0
  let cAmt = float32(clamp(colorNoise, 0, 100)) / 100
  let sig = max(0.5, sharpenRadius) / sc
  let doSharp = sharpen > 0 and sig >= 0.3
  let sAmt = float32(clamp(sharpen, 0, 500)) / 100
  if nr == 0 and cr == 0 and not doSharp: return im
  var kern: seq[float32]
  var kr = 0
  if doSharp:
    kr = max(1, int(ceil(sig * 3)))
    kern = newSeq[float32](2 * kr + 1)
    var tot = 0'f32
    for i in -kr .. kr:
      kern[i + kr] = exp(-float32(i * i) / float32(2 * sig * sig))
      tot += kern[i + kr]
    for v in kern.mitems: v /= tot
  let kp = fptr(kern)
  let margin = max(2 * nr, max(4 * cr, kr)) + 1
  result = newImg(w, h)
  let sp = pptr(im.px)
  let dp = pptr(result.px)
  const strip = 32
  let nStrips = (h + strip - 1) div strip
  parallelFor(nStrips, proc (lo, hi: int) =
    let bmax = strip + 2 * margin
    var Y = newSeq[float32](bmax * w)
    var Cb = newSeq[float32](bmax * w)
    var Cr = newSeq[float32](bmax * w)
    var t1 = newSeq[float32](bmax * w)
    var t2 = newSeq[float32](bmax * w)
    var t3 = newSeq[float32](bmax * w)
    var acc = newSeq[float64](w)
    let yp = cast[ptr UncheckedArray[float32]](addr Y[0])
    let bp = cast[ptr UncheckedArray[float32]](addr Cb[0])
    let rp = cast[ptr UncheckedArray[float32]](addr Cr[0])
    let p1 = cast[ptr UncheckedArray[float32]](addr t1[0])
    let p2 = cast[ptr UncheckedArray[float32]](addr t2[0])
    let p3 = cast[ptr UncheckedArray[float32]](addr t3[0])
    let ap = cast[ptr UncheckedArray[float64]](addr acc[0])
    for s in lo ..< hi:
      let y0 = s * strip
      let y1 = min(h, y0 + strip)
      let by0 = max(0, y0 - margin)
      let by1 = min(h, y1 + margin)
      let bh = by1 - by0
      let n = bh * w
      for j in 0 ..< n:
        let p = sp[by0 * w + j]
        let r = float32((p shr 16) and 255) / 255
        let g = float32((p shr 8) and 255) / 255
        let b = float32(p and 255) / 255
        let yy = 0.299'f32 * r + 0.587'f32 * g + 0.114'f32 * b
        yp[j] = yy
        bp[j] = b - yy
        rp[j] = r - yy
      if nr > 0:
        # the guided filter of the light by itself: flat parts smoothed, edges kept
        for j in 0 ..< n: p2[j] = yp[j] * yp[j]
        boxMean(yp, p1, p3, w, bh, nr, ap)                 # mean
        boxMean(p2, p2, p3, w, bh, nr, ap)                 # mean of squares
        for j in 0 ..< n:
          let v = max(0'f32, p2[j] - p1[j] * p1[j])
          let a = v / (v + eps)
          p2[j] = p1[j] - a * p1[j]                        # b
          p1[j] = a
        boxMean(p1, p1, p3, w, bh, nr, ap)
        boxMean(p2, p2, p3, w, bh, nr, ap)
        for j in 0 ..< n: yp[j] = p1[j] * yp[j] + p2[j]
      if cr > 0:
        for c in [bp, rp]:
          boxMean(c, p1, p3, w, bh, cr, ap)
          boxMean(p1, p1, p3, w, bh, cr, ap)
          for j in 0 ..< n: c[j] = c[j] + (p1[j] - c[j]) * cAmt
      if doSharp:
        # unsharp mask of the light
        for row in 0 ..< bh:
          let o = row * w
          for x in 0 ..< w:
            var a = 0'f32
            for i in -kr .. kr: a += kp[i + kr] * yp[o + clamp(x + i, 0, w - 1)]
            p1[o + x] = a
        for row in 0 ..< bh:
          let o = row * w
          for x in 0 ..< w:
            var a = 0'f32
            for i in -kr .. kr: a += kp[i + kr] * p1[clamp(row + i, 0, bh - 1) * w + x]
            p2[o + x] = a
        for j in 0 ..< n: yp[j] = yp[j] + (yp[j] - p2[j]) * sAmt
      for y in y0 ..< y1:
        let o = (y - by0) * w
        for x in 0 ..< w:
          let yy = yp[o + x]
          let r = yy + rp[o + x]
          let b = yy + bp[o + x]
          let g = (yy - 0.299'f32 * r - 0.114'f32 * b) / 0.587'f32
          let a = sp[y * w + x] and 0xFF000000'u32
          dp[y * w + x] = a or (lvl(r) shl 16) or (lvl(g) shl 8) or lvl(b))

# ---- Develop -------------------------------------------------------------------------------------------

proc developImg*(src: Img; s: Develop; base: DevelopBase; ox = 0.0; oy = 0.0; scale = 1.0): Img =
  ## `src` developed by `s`. `src` is the picture `base` was made for, or a
  ## part of it whose top left is at `ox`, `oy` in the picture, or a smaller
  ## copy (`scale` picture pixels per pixel: a preview). On all the cores.
  let w = src.w
  let h = src.h
  if w <= 0 or h <= 0 or s.isNeutral: return src
  var pr = prepare(s)
  let prp = addr pr
  let local = base.local and base.coef.len == base.w * base.h * CoefN
  let haze = base.haze and base.coef.len == base.w * base.h * CoefN
  # where each column and row is in the small copy (bilinear)
  var xi = newSeq[int32](w)
  var xf = newSeq[float32](w)
  var yi = newSeq[int32](h)
  var yf = newSeq[float32](h)
  if local or haze:
    for x in 0 ..< w:
      let sx = clamp((ox + (x.float + 0.5) * scale) / base.f - 0.5, 0, float(base.w - 1))
      xi[x] = int32(min(int(sx), base.w - 2).max(0))
      xf[x] = float32(sx - xi[x].float)
    for y in 0 ..< h:
      let sy = clamp((oy + (y.float + 0.5) * scale) / base.f - 0.5, 0, float(base.h - 1))
      yi[y] = int32(min(int(sy), base.h - 2).max(0))
      yf[y] = float32(sy - yi[y].float)
  let xip = cast[ptr UncheckedArray[int32]](addr xi[0])
  let xfp = cast[ptr UncheckedArray[float32]](addr xf[0])
  let yip = cast[ptr UncheckedArray[int32]](addr yi[0])
  let yfp = cast[ptr UncheckedArray[float32]](addr yf[0])
  let cp = fptr(base.coef)
  let bw = base.w
  let bh1 = base.h > 1
  let bw1 = base.w > 1
  let air = base.air
  let fw = base.fullW.float32
  let fh = base.fullH.float32
  result = newImg(w, h)
  let sp = pptr(src.px)
  let dp = pptr(result.px)
  {.push boundChecks: off, overflowChecks: off.}
  parallelRows(h, y):
    let y0 = int(yip[y])
    let fy = yfp[y]
    let y1 = if bh1: y0 + 1 else: y0
    for x in 0 ..< w:
      let p = sp[y * w + x]
      var r = linOf[(p shr 16) and 255]
      var g = linOf[(p shr 8) and 255]
      var b = linOf[p and 255]
      # the small copy's numbers here
      var c: array[CoefN, float32]
      if local or haze:
        let x0 = int(xip[x])
        let x1 = if bw1: x0 + 1 else: x0
        let fx = xfp[x]
        let i00 = (y0 * bw + x0) * CoefN
        let i01 = (y0 * bw + x1) * CoefN
        let i10 = (y1 * bw + x0) * CoefN
        let i11 = (y1 * bw + x1) * CoefN
        for k in 0 ..< CoefN:
          let top = cp[i00 + k] + (cp[i01 + k] - cp[i00 + k]) * fx
          let bot = cp[i10 + k] + (cp[i11 + k] - cp[i10 + k]) * fx
          c[k] = top + (bot - top) * fy
      if haze:
        let t = if prp.dh > 0: min(0.9'f32, prp.dh * 0.95'f32 * c[4]) else: -prp.dh * 0.5'f32
        if prp.dh > 0:
          r = max(0, (r - air[0] * t) / (1 - t)); g = max(0, (g - air[1] * t) / (1 - t))
          b = max(0, (b - air[2] * t) / (1 - t))
        else:
          r = r * (1 - t) + air[0] * t; g = g * (1 - t) + air[1] * t; b = b * (1 - t) + air[2] * t
      exposeLin(prp[], r, g, b)
      r = toGam(r)
      g = toGam(g)
      b = toGam(b)
      # highlights, shadows, clarity: by the light around
      if local:
        let Y = 0.2126'f32 * r + 0.7152'f32 * g + 0.0722'f32 * b
        var Y2 = Y
        let around = clamp(c[0] * Y + c[1], 0, 1)
        if prp.sh != 0:
          let ws = 1 - smooth01(around / 0.55'f32)
          Y2 = Y2 * (1 + prp.sh * (if prp.sh > 0: 1.6'f32 else: 0.7'f32) * ws)
        if prp.hl != 0:
          let wh = smooth01((around - 0.45'f32) / 0.55'f32)
          if prp.hl < 0: Y2 = Y2 * (1 + prp.hl * 0.6'f32 * wh)
          else: Y2 = Y2 + prp.hl * 0.5'f32 * wh * max(0'f32, 1 - Y2)
        if prp.cl != 0:
          let near = c[2] * Y + c[3]
          let mid = max(0'f32, 1 - (2 * Y - 1) * (2 * Y - 1))
          Y2 = Y2 + prp.cl * (if prp.cl > 0: 1.3'f32 else: 0.9'f32) * (Y - near) * (0.3'f32 + 0.7'f32 * mid)
        Y2 = max(0'f32, Y2)
        if Y > 0.004:
          let k = Y2 / Y
          r *= k; g *= k; b *= k
        else:
          r += Y2 - Y; g += Y2 - Y; b += Y2 - Y
      if prp.toned:
        r = toneAt(prp, r); g = toneAt(prp, g); b = toneAt(prp, b)
      if prp.sat != 0 or prp.vib != 0:
        let Y = 0.2126'f32 * r + 0.7152'f32 * g + 0.0722'f32 * b
        let sat = clamp(max(r, max(g, b)) - min(r, min(g, b)), 0, 1)
        var k = 1 + prp.sat
        if prp.vib != 0:
          var wv = (1 - sat) * (1 - sat)
          if r > g and g > b: wv *= 0.55          # (skin)
          k += prp.vib * wv
        k = max(0'f32, k)
        r = Y + (r - Y) * k; g = Y + (g - Y) * k; b = Y + (b - Y) * k
      if prp.vig != 0:
        let dx = (float32(ox) + (float32(x) + 0.5'f32) * float32(scale)) / fw * 2 - 1
        let dy = (float32(oy) + (float32(y) + 0.5'f32) * float32(scale)) / fh * 2 - 1
        let m = smooth01((sqrt((dx * dx + dy * dy) * 0.5'f32) - 0.3'f32) / 0.75'f32)
        if prp.vig < 0:
          let k = 1 + prp.vig * 0.85'f32 * m
          r *= k; g *= k; b *= k
        else:
          let k = prp.vig * 0.8'f32 * m
          r += (1 - r) * k; g += (1 - g) * k; b += (1 - b) * k
      if prp.grain > 0:
        # (in picture pixels: a part shows the grain the whole has there)
        let gx = (ox + (x.float + 0.5) * scale) / 1.4
        let gy = (oy + (y.float + 0.5) * scale) / 1.4
        let ix = int(gx)
        let iy = int(gy)
        let fx2 = float32(gx - ix.float)
        let fy2 = float32(gy - iy.float)
        let n0 = hash01(ix, iy) + (hash01(ix + 1, iy) - hash01(ix, iy)) * fx2
        let n1 = hash01(ix, iy + 1) + (hash01(ix + 1, iy + 1) - hash01(ix, iy + 1)) * fx2
        let Y = 0.2126'f32 * r + 0.7152'f32 * g + 0.0722'f32 * b
        let d = (n0 + (n1 - n0) * fy2) * prp.grain * 0.14'f32 * (1 - abs(2 * Y - 1) * 0.6'f32)
        r += d; g += d; b += d
      dp[y * w + x] = (p and 0xFF000000'u32) or (lvl(r) shl 16) or (lvl(g) shl 8) or lvl(b)
  {.pop.}
  if s.noise > 0 or s.colorNoise > 0 or s.sharpen > 0:
    result = detailImg(result, s.noise, s.colorNoise, s.sharpen,
                       (if s.sharpenRadius > 0: s.sharpenRadius / 10 else: 1.0), scale)

proc develop*(s: Develop): FilterFn =
  ## Develop as a filter: the part worked on is the picture.
  result = proc (src: Img; inner: Rect): Img =
    let needs = s.shadows != 0 or s.highlights != 0 or s.clarity != 0 or s.dehaze != 0
    let base = if needs: developBase(smallCopy(src, 400), s, src.w, src.h)
               else: DevelopBase(fullW: max(1, src.w), fullH: max(1, src.h), w: 1, h: 1, f: 1)
    developImg(src, s, base)

proc developMargin*(s: Develop): int =
  ## How far around a selection Develop looks (`applyFilter`'s margin).
  if s.noise > 0 or s.colorNoise > 0 or s.sharpen > 0: 12 else: 0

# ---- Auto ----------------------------------------------------------------------------------------------

proc autoDevelop*(src: Img): Develop =
  ## Settings that make a typical photo look right: a neutral white balance,
  ## the exposure to put the middle tones in the middle, whites and blacks
  ## that reach (nearly) white and black, highlights and shadows that keep
  ## their detail, a little contrast and vibrance where they are missing.
  let im = smallCopy(src, 256)
  var lum: seq[float32]
  var avg: array[3, float64]
  var cnt = 0
  var satSum = 0.0
  for p in im.px:
    if (p shr 24) < 128: continue
    let r = rOf(p) / 255
    let g = gOf(p) / 255
    let b = bOf(p) / 255
    let y = 0.2126 * r + 0.7152 * g + 0.0722 * b
    lum.add float32(y)
    let sat = max(r, max(g, b)) - min(r, min(g, b))
    satSum += sat
    # (the white balance from what is nearly gray: a warm scene stays warm)
    if y > 0.15 and y < 0.9 and sat < 0.2:
      avg[0] += linOf[rOf(p)]; avg[1] += linOf[gOf(p)]; avg[2] += linOf[bOf(p)]
      inc cnt
  if lum.len == 0: return
  lum.sort()
  template pct(q: float): float = float(lum[clamp(int(q * float(lum.len - 1)), 0, lum.len - 1)])
  # white balance: the middle tones gray on average (gently)
  if cnt > 20 and cnt * 100 >= im.px.len * 3:
    for c in 0 .. 2: avg[c] /= cnt.float
    if avg[0] > 0.001 and avg[2] > 0.001 and avg[1] > 0.001:
      let t = ln(avg[2] / avg[0]) / 0.9 * 100            # exp(0.45 t) each way
      let ti = -ln(sqrt(avg[0] * avg[2]) / avg[1]) / 0.35 * 100
      result.temperature = clamp(int(round(t * 0.7)), -35, 35)
      result.tint = clamp(int(round(ti * 0.5)), -20, 20)
  # exposure: the middle of the tones toward the middle
  let med = max(0.01, pct(0.5))
  var ev = log2(toLin(0.46).float / max(0.0005, toLin(float32(med)).float))
  ev = clamp(ev * 0.75, -1.5, 1.5)
  if abs(ev) < 0.08: ev = 0
  result.exposure = int(round(ev * 100))
  let k = pow(2.0, ev)
  template after(v: float): float = float(toGam(float32(toLin(float32(v)).float * k)))
  # whites and blacks: the ends of the tones near white and black
  let hi = after(pct(0.995))
  let lo = after(pct(0.005))
  if hi < 0.97 and hi > 0.2: result.whites = clamp(int(round((0.98 - hi) / (0.2 * pow(hi, 5)) * 100)), 0, 60)
  if lo > 0.03 and lo < 0.8: result.blacks = clamp(int(round((0.02 - lo) / (0.2 * pow(1 - lo, 5)) * 100)), -60, 0)
  # highlights and shadows: detail back where much is near white or black
  var bright, darkN = 0
  for v in lum:
    let a = after(v.float)
    if a > 0.92: inc bright
    if a < 0.12: inc darkN
  let fb = bright / lum.len
  let fd = darkN / lum.len
  if fb > 0.02: result.highlights = -clamp(int(round(fb * 350)), 10, 60)
  if fd > 0.05: result.shadows = clamp(int(round(fd * 180)), 10, 50)
  # contrast where the tones are bunched up, vibrance where colors are dull
  var mean = 0.0
  for v in lum: mean += v.float
  mean /= lum.len.float
  var sd = 0.0
  for v in lum: sd += (v.float - mean) ^ 2
  sd = sqrt(sd / lum.len.float)
  if sd < 0.22: result.contrast = clamp(int(round((0.22 - sd) * 220)), 0, 30)
  result.vibrance = if satSum / lum.len.float < 0.2: 20 else: 10

proc developPresets*(): seq[tuple[name: string; s: Develop]] =
  ## Looks to start from.
  @[
    ("Vivid", Develop(contrast: 20, vibrance: 35, saturation: 5, clarity: 15)),
    ("Soft", Develop(contrast: -15, clarity: -20, highlights: -20, shadows: 15)),
    ("Matte", Develop(blacks: 45, contrast: -10, saturation: -10, highlights: -10)),
    ("Dramatic", Develop(contrast: 30, clarity: 45, dehaze: 15, vignette: -30, highlights: -40, shadows: 30)),
    ("Warm", Develop(temperature: 25, vibrance: 10)),
    ("Cool", Develop(temperature: -25, tint: 5)),
    ("Black & White", Develop(saturation: -100, contrast: 20, clarity: 10)),
    ("Vintage", Develop(temperature: 15, saturation: -25, blacks: 35, grain: 30, vignette: -25, contrast: -10)),
    ("Landscape", Develop(dehaze: 20, clarity: 25, vibrance: 30, highlights: -25, shadows: 15)),
    ("Portrait", Develop(clarity: -15, vibrance: 10, shadows: 10, sharpen: 20)),
    ("Night", Develop(exposure: 30, shadows: 25, noise: 40, colorNoise: 50)),
    ("Clear Sky", Develop(dehaze: 30, highlights: -35, temperature: -5, vibrance: 15)),
  ]

proc `$`*(s: Develop): string =
  ## The settings as text (name=value, those not 0), for a presets file.
  for name, v in s.fieldPairs:
    if v != 0:
      if result.len > 0: result.add ' '
      result.add name & "=" & $v

proc parseDevelop*(text: string): Develop =
  ## The settings from their text (`$`); what it does not know is left out.
  var i = 0
  while i < text.len:
    while i < text.len and text[i] in {' ', ',', ';', '\t'}: inc i
    var j = i
    while j < text.len and text[j] notin {' ', ',', ';', '\t'}: inc j
    let part = text[i ..< j]
    let eq = part.find('=')
    if eq > 0:
      let key = part[0 ..< eq]
      var v = 0
      var neg = false
      var k = eq + 1
      if k < part.len and part[k] == '-':
        neg = true
        inc k
      var ok = k < part.len
      while k < part.len:
        if part[k] notin {'0' .. '9'}:
          ok = false
          break
        v = v * 10 + (ord(part[k]) - ord('0'))
        if v > 100_000: ok = false
        inc k
      if ok:
        if neg: v = -v
        for name, f in result.fieldPairs:
          if name == key: f = v
    i = j

# ---- the automatic corrections of the Image menu ----------------------------------------------------------

proc autoTone*(h: Histogram): array[3, Levels] =
  ## Auto Tone: each channel stretched from its darkest to its lightest
  ## (0.1% clipped at each end).
  autoLevels(h, 0.001)

proc autoContrast*(h: Histogram): array[3, Levels] =
  ## Auto Contrast: the three channels stretched together (the colors kept).
  let a = autoLevels(h, 0.001)
  var lo = 255
  var hi = 0
  for c in 0 .. 2:
    lo = min(lo, a[c].inLo)
    hi = max(hi, a[c].inHi)
  for c in 0 .. 2: result[c] = Levels(inLo: lo, inHi: max(hi, lo + 2), gamma: 1.0, outLo: 0, outHi: 255)

proc autoColor*(im: Img): array[3, Levels] =
  ## Auto Color: the darkest colors to black and the lightest to white,
  ## then the middle tones that are nearly gray made gray.
  for c in 0 .. 2: result[c] = Levels(inLo: 0, inHi: 255, gamma: 1.0, outLo: 0, outHi: 255)
  let s = smallCopy(im, 512)
  var lum: seq[int]
  for p in s.px:
    if (p shr 24) >= 128: lum.add lumaOf(p)
  if lum.len < 16: return
  var sorted = lum
  sorted.sort()
  let loT = sorted[sorted.len div 1000]
  let hiT = sorted[sorted.len - 1 - sorted.len div 1000]
  if hiT - loT < 16: return
  var dark, light: array[3, float]
  var nd, nl = 0
  for p in s.px:
    if (p shr 24) < 128: continue
    let l = lumaOf(p)
    if l <= loT:
      dark[0] += rOf(p).float; dark[1] += gOf(p).float; dark[2] += bOf(p).float
      inc nd
    if l >= hiT:
      light[0] += rOf(p).float; light[1] += gOf(p).float; light[2] += bOf(p).float
      inc nl
  for c in 0 .. 2:
    let lo = clamp(int(round(dark[c] / max(1, nd).float)), 0, 200)
    let hi = clamp(int(round(light[c] / max(1, nl).float)), lo + 40, 255)
    result[c].inLo = lo
    result[c].inHi = hi
  # the middle tones that are nearly gray: made gray
  var m: array[3, float]
  var nm = 0
  for p in s.px:
    if (p shr 24) < 128: continue
    var v: array[3, float]
    for c in 0 .. 2:
      let x = [rOf(p), gOf(p), bOf(p)][c]
      v[c] = clamp((x - result[c].inLo) / (result[c].inHi - result[c].inLo), 0.0, 1.0)
    let l = (v[0] + v[1] + v[2]) / 3
    if l < 0.25 or l > 0.75: continue
    if max(v[0], max(v[1], v[2])) - min(v[0], min(v[1], v[2])) > 0.12: continue
    for c in 0 .. 2: m[c] += v[c]
    inc nm
  if nm < 16: return
  let gray = (m[0] + m[1] + m[2]) / 3 / nm.float
  for c in 0 .. 2:
    let mc = m[c] / nm.float
    if mc > 0.02 and mc < 0.98 and gray > 0.02 and gray < 0.98:
      result[c].gamma = clamp(ln(mc) / ln(gray), 0.7, 1.4)

# ---- newer adjustments ------------------------------------------------------------------------------------

proc vibranceFn*(vibrance, saturation: int): FilterFn =
  ## Vibrance: dull colors more saturated than vivid ones (skin spared);
  ## Saturation: all alike.
  develop(Develop(vibrance: vibrance, saturation: saturation))

proc shadowsHighlights*(shadows, highlights: int): FilterFn =
  ## Shadows/Highlights: dark parts lighter, light parts darker, by the
  ## light around each pixel (detail kept).
  develop(Develop(shadows: shadows, highlights: -highlights))

proc exposureFn*(exposure, offset, gamma: float): FilterFn =
  ## Exposure, as on light: `exposure` stops brighter, `offset` (-0.5..0.5)
  ## added to the shadows, then `gamma` (0.01..9.99, 1: as is).
  var lut: array[256, uint8]
  let k = pow(2.0, exposure)
  let g = 1 / clamp(gamma, 0.01, 9.99)
  for i in 0 .. 255:
    let v = max(0.0, linOf[i].float * k + offset)
    lut[i] = uint8(lvl(toGam(float32(pow(v, g)))))
  mapFn(proc (p: uint32): uint32 =
    (p and 0xFF000000'u32) or (uint32(lut[(p shr 16) and 255]) shl 16) or
      (uint32(lut[(p shr 8) and 255]) shl 8) or uint32(lut[p and 255]))

const photoFilters* = [
  ("Warming Filter (85)", 0xFFEC8A00'u32), ("Warming Filter (LBA)", 0xFFFA9600'u32),
  ("Warming Filter (81)", 0xFFEBB113'u32), ("Cooling Filter (80)", 0xFF006DFF'u32),
  ("Cooling Filter (LBB)", 0xFF005DFF'u32), ("Cooling Filter (82)", 0xFF00B5FF'u32),
  ("Red", 0xFFEA1A1A'u32), ("Orange", 0xFFF38400'u32), ("Yellow", 0xFFF9E31C'u32),
  ("Green", 0xFF19C919'u32), ("Cyan", 0xFF1DCBEA'u32), ("Blue", 0xFF1D35EA'u32),
  ("Violet", 0xFF9B1DEA'u32), ("Magenta", 0xFFE318E3'u32), ("Sepia", 0xFFAC7A33'u32),
  ("Deep Red", 0xFFFF0000'u32), ("Deep Blue", 0xFF0022CD'u32), ("Deep Emerald", 0xFF008C00'u32),
  ("Deep Yellow", 0xFFFFD500'u32), ("Underwater", 0xFF00C1B1'u32)]
  ## The filters of Photo Filter, by name.

proc photoFilter*(color: uint32; density: int; preserveLuminosity = true): FilterFn =
  ## Photo Filter: the light through a colored filter of `density` (0..100).
  let d = float32(clamp(density, 0, 100)) / 100
  let f = [linOf[rOf(color)], linOf[gOf(color)], linOf[bOf(color)]]
  let m = [1 - d + d * f[0], 1 - d + d * f[1], 1 - d + d * f[2]]
  mapFn3D(proc (p: uint32): uint32 =
    let r = linOf[rOf(p)]
    let g = linOf[gOf(p)]
    let b = linOf[bOf(p)]
    var r2 = r * m[0]
    var g2 = g * m[1]
    var b2 = b * m[2]
    if preserveLuminosity:
      let l1 = 0.2126'f32 * r + 0.7152'f32 * g + 0.0722'f32 * b
      let l2 = 0.2126'f32 * r2 + 0.7152'f32 * g2 + 0.0722'f32 * b2
      if l2 > 0.00001:
        let k = l1 / l2
        r2 *= k; g2 *= k; b2 *= k
    (p and 0xFF000000'u32) or (lvl(toGam(r2)) shl 16) or (lvl(toGam(g2)) shl 8) or lvl(toGam(b2)))

proc hslPx(h, s, l: float): (float, float, float) =
  let c = (1 - abs(2 * l - 1)) * s
  let hh = (h mod 360 + 360) mod 360 / 60
  let x = c * (1 - abs(hh mod 2 - 1))
  let (r, g, b) = if hh < 1: (c, x, 0.0) elif hh < 2: (x, c, 0.0) elif hh < 3: (0.0, c, x)
                  elif hh < 4: (0.0, x, c) elif hh < 5: (x, 0.0, c) else: (c, 0.0, x)
  let m = l - c / 2
  (r + m, g + m, b + m)

proc blackAndWhite*(weights: array[6, int]; tint = false; hue = 35; sat = 25): FilterFn =
  ## Black & White: gray from the colors, each range (reds, yellows,
  ## greens, cyans, blues, magentas: percents, -200..300) as light as its
  ## weight; with `tint`, colored as one hue.
  var w: array[6, float]
  for i in 0 .. 5: w[i] = clamp(weights[i], -200, 300) / 100
  mapFn3D(proc (p: uint32): uint32 =
    let c = [rOf(p).float, gOf(p).float, bOf(p).float]
    var mx = 0
    for i in 1 .. 2:
      if c[i] > c[mx]: mx = i
    var mn = if mx == 0: 1 else: 0
    for i in 0 .. 2:
      if i != mx and c[i] < c[mn]: mn = i
    let md = 3 - mx - mn
    # the primary range is the most's; the secondary the most's and the middle's
    let primary = mx * 2
    let secondary = if (mx == 0 and md == 1) or (mx == 1 and md == 0): 1
                    elif (mx == 1 and md == 2) or (mx == 2 and md == 1): 3
                    else: 5
    let gray = clamp(c[mn] + (c[md] - c[mn]) * w[secondary] + (c[mx] - c[md]) * w[primary], 0, 255) / 255
    if not tint:
      let v = int(round(gray * 255))
      return argb(int(p shr 24), v, v, v)
    let (r, g, b) = hslPx(hue.float, clamp(sat, 0, 100) / 100, gray)
    argb(int(p shr 24), int(round(clamp(r, 0, 1) * 255)), int(round(clamp(g, 0, 1) * 255)),
         int(round(clamp(b, 0, 1) * 255))))

proc defaultBlackAndWhite*(): array[6, int] = [40, 60, 40, 60, 20, 80]
  ## The weights `blackAndWhite` starts with: reds 40, yellows 60, greens
  ## 40, cyans 60, blues 20, magentas 80.

proc channelMixer*(m: array[3, array[4, int]]; monochrome = false): FilterFn =
  ## Channel Mixer: each output channel from the red, green and blue in
  ## percents (-200..200) and a constant (-200..200); `monochrome`: gray
  ## from the first row.
  mapFn3D(proc (p: uint32): uint32 =
    let r = rOf(p).float
    let g = gOf(p).float
    let b = bOf(p).float
    var o: array[3, int]
    for c in 0 .. 2:
      let k = if monochrome: m[0] else: m[c]
      o[c] = clamp(int(round((r * k[0].float + g * k[1].float + b * k[2].float) / 100 + k[3].float * 2.55)), 0, 255)
    argb(int(p shr 24), o[0], o[1], o[2]))

# ---- adjustment layers ----------------------------------------------------------------------------------

proc dehazeFn*(amount: int): FilterFn =
  ## Dehaze (-100..100): the haze taken away -- each color's darkest channel
  ## taken as how much haze is in it, the airlight taken out by that much
  ## (more contrast and color where it is hazy); negative: haze added.
  let k = clamp(amount, -100, 100).float / 100
  result = proc (src: Img; inner: Rect): Img =
    result = newImg(src.w, src.h)
    const air = 236.0
    for i, p in src.px:
      let r = rOf(p).float
      let g = gOf(p).float
      let b = bOf(p).float
      var o: array[3, float]
      if k >= 0:
        let t = max(0.3, 1 - k * 0.85 * min(r, min(g, b)) / air)
        o = [(r - air) / t + air, (g - air) / t + air, (b - air) / t + air]
      else:
        let h = -k * 0.6
        o = [r * (1 - h) + air * h, g * (1 - h) + air * h, b * (1 - h) + air * h]
      result.px[i] = argb(aOf(p), int(o[0] + 0.5), int(o[1] + 0.5), int(o[2] + 0.5))

proc adjustmentFn*(a: Adjustment): FilterFn =
  ## The adjustment an adjustment layer makes, from its kind and settings
  ## (nil when it is not known). The settings, in order:
  ##
  ## - "Levels": for the master, red, green, blue: in low, in high, gamma,
  ##   out low, out high (20)
  ## - "Curves": for each of the four: the number of points, then x, y of each
  ## - "Brightness/Contrast": brightness, contrast
  ## - "Color Balance": shadows, midtones, highlights (r, g, b each), preserve luminosity (0/1)
  ## - "Hue/Saturation": colorize (0/1), then hue, saturation, lightness when
  ##   colorizing, else those three for each of master, reds, yellows,
  ##   greens, cyans, blues, magentas (21)
  ## - "Selective Color": relative (0/1), then c, m, y, k for each of 9 ranges
  ## - "Vibrance": vibrance, saturation
  ## - "Exposure": exposure (stops), offset, gamma
  ## - "Photo Filter": r, g, b, density, preserve luminosity (0/1)
  ## - "Black & White": the 6 weights, tint (0/1), hue, saturation
  ## - "Channel Mixer": the 12 numbers (r, g, b, constant for each output), monochrome (0/1)
  ## - "Invert"; "Threshold": level; "Posterize": levels
  ## - "Gradient Map": as `gradientMapArgs`; "Color Lookup": its look in `data`
  ## - "Dehaze": amount (-100..100)
  ## - ("Clarity": amount; "Grain": amount, size, roughness, seed -- they
  ##   look at the pixels around: the composite does them, `nil` here)
  let v = a.args
  template at(i: int): float = (if i < v.len: v[i] else: 0.0)
  template ai(i: int): int = int(round(at(i)))
  case a.kind
  of "Levels":
    var l: array[4, Levels]
    for c in 0 .. 3:
      l[c] = if v.len >= 20: Levels(inLo: ai(c * 5), inHi: ai(c * 5 + 1), gamma: at(c * 5 + 2),
                                    outLo: ai(c * 5 + 3), outHi: ai(c * 5 + 4))
             else: defaultLevels()
    applyLuts(levelsLut(l[0]), levelsLut(l[1]), levelsLut(l[2]), levelsLut(l[3]))
  of "Curves":
    var c: array[4, seq[(int, int)]]
    var i = 0
    for ch in 0 .. 3:
      let n = ai(i)
      inc i
      for k in 0 ..< n:
        c[ch].add (ai(i), ai(i + 1))
        i += 2
      if c[ch].len < 2: c[ch] = @[(0, 0), (255, 255)]
    applyLuts(curveLut(c[0]), curveLut(c[1]), curveLut(c[2]), curveLut(c[3]))
  of "Brightness/Contrast": brightnessContrast(ai(0), ai(1))
  of "Color Balance":
    colorBalance([ai(0), ai(1), ai(2)], [ai(3), ai(4), ai(5)], [ai(6), ai(7), ai(8)], ai(9) != 0)
  of "Hue/Saturation":
    if ai(0) != 0: hueSaturation(ai(1), ai(2), ai(3), true)
    else:
      var h: HueAdjust
      for r in 0 .. 6:
        for k in 0 .. 2: h[r][k] = ai(1 + r * 3 + k)
      var ranges = DefaultHueRanges
      if v.len >= 22 + 24:
        for r in 0 .. 5:
          for k in 0 .. 3: ranges[r][k] = ai(22 + r * 4 + k)
      hueSaturation(h, ranges)
  of "Selective Color":
    var sc: SelectiveColor
    for r in 0 .. 8:
      for k in 0 .. 3: sc[r][k] = ai(1 + r * 4 + k)
    selectiveColor(sc, ai(0) != 0)
  of "Vibrance": vibranceFn(ai(0), ai(1))
  of "Exposure": exposureFn(at(0), at(1), (if v.len >= 3: at(2) else: 1.0))
  of "Photo Filter":
    photoFilter(argb(255, ai(0), ai(1), ai(2)), ai(3), ai(4) != 0)
  of "Black & White":
    var wts: array[6, int]
    for k in 0 .. 5: wts[k] = if v.len >= 6: ai(k) else: defaultBlackAndWhite()[k]
    blackAndWhite(wts, ai(6) != 0, ai(7), ai(8))
  of "Channel Mixer":
    var m: array[3, array[4, int]]
    for o in 0 .. 2:
      for k in 0 .. 3: m[o][k] = if v.len >= 12: ai(o * 4 + k) else: (if k == o: 100 else: 0)
    channelMixer(m, ai(12) != 0)
  of "Invert": invert()
  of "Threshold": threshold(if v.len > 0: ai(0) else: 128)
  of "Posterize": posterize(if v.len > 0: max(2, ai(0)) else: 4)
  of "Gradient Map":
    let g = gradientMapOf(v)
    gradientMap(g.stops, g.reverse, g.dither)
  of "Color Lookup": colorLookup(a.data)
  of "Dehaze": dehazeFn(if v.len > 0: ai(0) else: 30)
  else: nil

proc adjustmentTable(a: Adjustment): seq[uint32] =
  ## The adjustment as a table of `LutN`^3 colors (for the composite).
  let f = adjustmentFn(a)
  if f == nil: return
  const n = LutN
  var grid = newImg(n * n, n)
  for r in 0 ..< n:
    for g in 0 ..< n:
      for b in 0 ..< n:
        grid.px[(r * n + g) * n + b] = argb(255, (r * 255 + (n - 1) div 2) div (n - 1),
                                            (g * 255 + (n - 1) div 2) div (n - 1),
                                            (b * 255 + (n - 1) div 2) div (n - 1))
  f(grid, rect(0, 0, grid.w, grid.h)).px

adjustmentLut = adjustmentTable
