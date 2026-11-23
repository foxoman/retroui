## More filters and adjustments for `photo` documents: what the image editors of 2026 have that
## `photofx` and its neighbours did not. All are made here, without a network.
##
## - **Lens:** Adaptive Wide Angle (a fisheye, a wide lens or a 360 picture made straight).
## - **Sharpening:** Shake Reduction (a camera's shake taken out, found by itself: Affinity's
##   Motion Blur Reduction), Multi Band Sharpen (fine, medium and coarse detail each, its edges
##   only if you like).
## - **Blur and noise:** Bilateral Blur (smooth, its edges kept).
## - **Detail and light:** Texture (the midtones' fine detail), Ambient Occlusion (shade in
##   the creases), Mixed Light Correction (each part's light made white), Tone Compression and
##   Tone Stretch, SDR to HDR (the highlights given back their light, at 32 bits).
## - **Color:** Split Toning and Color Grading (shadows, midtones, highlights each toned),
##   Channel Inversion (a film negative, infrared).
## - **Stylize and render:** Glitch, Flame, Tree, Picture Frame.
## - **Masks:** from a range of lightness or of hues (`luminosityMask`, `hueRangeMask`).
##
## Adjustments that change each pixel by itself are kept as adjustment layers too:
## `paramAdjust` names one and its settings, `paramAdjustFn` makes it again from the numbers
## the layer keeps (`photodevelop`'s `adjustmentFn` asks it for the names it does not know).
##
## .. code-block:: nim
##   d.beginStep("Shake Reduction")
##   let (angle, length) = estimateShake(imgOf(d.layer))   # (or let the filter find them: 0)
##   d.applyFilter(length + 16, shakeReduction(angle, length, 30))
##   d.endStep()
##
## Developed by Sultan Al Isaiee @foxoman -- www.foxoman.net -- sultan@foxoman.net

import std/[math, algorithm, random, tables, sequtils]
import gfx, photo, photofx, parallel

template pixPtr(s: seq[uint32]): ptr UncheckedArray[uint32] =
  cast[ptr UncheckedArray[uint32]](if s.len > 0: unsafeAddr s[0] else: nil)
template fPtr(s: seq[float32]): ptr UncheckedArray[float32] =
  cast[ptr UncheckedArray[float32]](if s.len > 0: unsafeAddr s[0] else: nil)

# ---- settings kept as adjustment layers --------------------------------------------------------------------------

type
  AdjParam* = object
    ## A setting of an adjustment kept by its numbers: a number between `lo` and `hi`, or one of
    ## `choices` (its index), or a box to tick (`check`: 0 or 1).
    label*, unit*: string
    lo*, hi*, val*: float
    dec*: int                  ## decimals shown
    choices*: seq[string]
    check*: bool

  ParamAdjustment* = object
    ## An adjustment of each pixel by itself, its settings numbers (`paramAdjust`).
    name*: string
    params*: seq[AdjParam]
    make*: proc (v: seq[float]): FilterFn {.closure.}

var paramAdjusts: OrderedTable[string, ParamAdjustment]

proc adjNum*(label: string; lo, hi, val: float; unit = ""; dec = 0): AdjParam =
  ## A number setting.
  AdjParam(label: label, lo: lo, hi: hi, val: val, unit: unit, dec: dec)

proc adjPick*(label: string; choices: openArray[string]; val = 0): AdjParam =
  ## One of a few choices.
  AdjParam(label: label, choices: @choices, val: val.float, hi: float(choices.len - 1))

proc paramAdjust*(name: string; params: seq[AdjParam]; make: proc (v: seq[float]): FilterFn {.closure.}) =
  ## Names an adjustment kept by its numbers: an adjustment layer called `name` keeps
  ## `params`' values and is made again by `make`.
  paramAdjusts[name] = ParamAdjustment(name: name, params: params, make: make)

proc isParamAdjust*(name: string): bool = name in paramAdjusts
  ## Whether `name` is one of those (`paramAdjust`).

proc paramAdjustment*(name: string): ParamAdjustment =
  ## Its settings and maker (empty when it is not one).
  paramAdjusts.getOrDefault(name)

proc paramAdjustNames*(): seq[string] =
  ## Their names, in the order they were named.
  for k in paramAdjusts.keys: result.add k

proc paramAdjustFn*(name: string; args: seq[float]): FilterFn =
  ## The adjustment `name` with the settings `args` (missing ones as they start); nil when
  ## `name` is not one.
  if name notin paramAdjusts: return nil
  let p = paramAdjusts[name]
  var v = args
  for i in v.len ..< p.params.len: v.add p.params[i].val
  p.make(v)

# ---- planes of numbers -------------------------------------------------------------------------------------------

type Plane* = object
  ## One number for each pixel (lightness, height, a mask), row by row.
  w*, h*: int
  v*: seq[float32]

proc newPlane*(w, h: int; fill = 0'f32): Plane =
  result = Plane(w: w, h: h, v: newSeq[float32](w * h))
  if fill != 0:
    for x in result.v.mitems: x = fill

proc lumaPlane*(src: Img): Plane =
  ## The image's lightness, 0..1.
  result = Plane(w: src.w, h: src.h, v: newSeqUninit[float32](src.w * src.h))
  let sp = pixPtr(src.px)
  let o = fPtr(result.v)
  parallelFor(src.px.len, proc (lo, hi: int) =
    for i in lo ..< hi:
      let p = sp[i]
      o[i] = float32(rOf(p) * 77 + gOf(p) * 151 + bOf(p) * 28) / (256'f32 * 255'f32))

proc boxBlur*(p: Plane; r: int): Plane =
  ## Each value the mean of the `2r + 1` square round it (the edges carried on).
  if r <= 0: return p
  let (w, h) = (p.w, p.h)
  var tmp = newSeqUninit[float32](w * h)
  result = Plane(w: w, h: h, v: newSeqUninit[float32](w * h))
  let s = fPtr(p.v)
  let t = fPtr(tmp)
  let o = fPtr(result.v)
  let n = float32(2 * r + 1)
  parallelRows(h, y):
    let row = y * w
    var acc = 0'f32
    for k in -r .. r: acc += s[row + clamp(k, 0, w - 1)]
    for x in 0 ..< w:
      t[row + x] = acc / n
      acc += s[row + min(x + r + 1, w - 1)] - s[row + max(x - r, 0)]
  parallelFor(w, proc (lo, hi: int) =
    for x in lo ..< hi:
      var acc = 0'f32
      for k in -r .. r: acc += t[clamp(k, 0, h - 1) * w + x]
      for y in 0 ..< h:
        o[y * w + x] = acc / n
        acc += t[min(y + r + 1, h - 1) * w + x] - t[max(y - r, 0) * w + x])

proc gaussPlane*(p: Plane; sigma: float): Plane =
  ## A Gaussian blur of about `sigma` (three box blurs).
  if sigma <= 0.3: return p
  # (the widths of three boxes whose blur is that Gaussian's)
  let wIdeal = sqrt(12 * sigma * sigma / 3 + 1)
  var wl = int(floor(wIdeal))
  if wl mod 2 == 0: dec wl
  let wu = wl + 2
  let m = int(round((12 * sigma * sigma - 3.0 * float(wl * wl) - 4.0 * float(wl) - 3) / (-4.0 * float(wl) - 4)))
  result = p
  for i in 0 .. 2:
    let wd = if i < m: wl else: wu
    result = boxBlur(result, max(0, (wd - 1) div 2))

proc guided*(I, p: Plane; r: int; eps: float32): Plane =
  ## The guided filter (He, Sun and Tang): `p` smoothed, following the edges of `I`.
  let n = I.v.len
  var ip = Plane(w: I.w, h: I.h, v: newSeqUninit[float32](n))
  var ii = Plane(w: I.w, h: I.h, v: newSeqUninit[float32](n))
  for k in 0 ..< n:
    ip.v[k] = I.v[k] * p.v[k]
    ii.v[k] = I.v[k] * I.v[k]
  let mI = boxBlur(I, r)
  let mp = boxBlur(p, r)
  let mIp = boxBlur(ip, r)
  let mII = boxBlur(ii, r)
  var a = Plane(w: I.w, h: I.h, v: newSeqUninit[float32](n))
  var b = Plane(w: I.w, h: I.h, v: newSeqUninit[float32](n))
  for k in 0 ..< n:
    let cov = mIp.v[k] - mI.v[k] * mp.v[k]
    let vr = mII.v[k] - mI.v[k] * mI.v[k]
    a.v[k] = cov / (vr + eps)
    b.v[k] = mp.v[k] - a.v[k] * mI.v[k]
  let ma = boxBlur(a, r)
  let mb = boxBlur(b, r)
  result = Plane(w: I.w, h: I.h, v: newSeqUninit[float32](n))
  for k in 0 ..< n: result.v[k] = ma.v[k] * I.v[k] + mb.v[k]

template withLight(src: Img; L0, L1: Plane): Img =
  ## (each pixel's color scaled so that its lightness goes from `L0` to `L1`, alpha kept)
  var o = newImgUninit(src.w, src.h)
  let sp = pixPtr(src.px)
  let op = pixPtr(o.px)
  let a0 = fPtr(L0.v)
  let a1 = fPtr(L1.v)
  parallelFor(src.px.len, proc (lo, hi: int) =
    for i in lo ..< hi:
      let p = sp[i]
      let d = (a1[i] - a0[i]) * 255
      op[i] = argb(aOf(p), int(float32(rOf(p)) + d + 0.5), int(float32(gOf(p)) + d + 0.5),
                   int(float32(bOf(p)) + d + 0.5)))
  o

proc smooth01(e0, e1, x: float): float {.inline.} =
  let t = clamp((x - e0) / (e1 - e0), 0.0, 1.0)
  t * t * (3 - 2 * t)

# ---- detail ------------------------------------------------------------------------------------------------------

proc textureDetail*(amount: int): FilterFn =
  ## Texture (Camera Raw's, Affinity's): the fine detail of the midtones -- skin's pores, a
  ## fabric's weave, bark -- made stronger (`amount` > 0) or smoother (< 0), -100..100; the
  ## edges and the flat parts as they were.
  result = proc (src: Img; inner: Rect): Img =
    let L = lumaPlane(src)
    let b1 = gaussPlane(L, 1.2)
    let b2 = gaussPlane(L, 4.0)
    var L1 = Plane(w: L.w, h: L.h, v: newSeqUninit[float32](L.v.len))
    let k = float32(amount) / 100 * 1.6
    for i in 0 ..< L.v.len:
      let y = L.v[i]
      let band = b1.v[i] - b2.v[i]
      let fine = L.v[i] - b1.v[i]
      let mid = 4 * y * (1 - y)                    # (the midtones most)
      # (a band at a time: what is too strong already -- an edge -- held back)
      let w = mid / (1 + abs(band) * 18)
      L1.v[i] = clamp(y + k * w * (band + fine * 0.5), 0, 1)
    withLight(src, L, L1)

proc multiBandSharpen*(fine, medium, coarse: int; edges = 0; threshold = 0): FilterFn =
  ## Multi Band Sharpen (Affinity's): the fine (about a pixel), medium (3 pixels) and coarse
  ## (10 pixels) detail each made stronger by its amount (0..300 %), on the lightness so that
  ## no color fringes come. `edges`: 0 everywhere, 1 only along edges (Multi Band edge
  ## sharpening), 2 along the edges a High Pass finds; `threshold` levels of detail left
  ## alone (noise).
  result = proc (src: Img; inner: Rect): Img =
    let L = lumaPlane(src)
    let b1 = gaussPlane(L, 0.8)
    let b2 = gaussPlane(L, 2.5)
    let b3 = gaussPlane(L, 8.0)
    var mask = Plane()
    if edges > 0:
      mask = Plane(w: L.w, h: L.h, v: newSeqUninit[float32](L.v.len))
      if edges == 1:
        # (how much the lightness changes round each pixel)
        for y in 0 ..< L.h:
          for x in 0 ..< L.w:
            let gx = b1.v[y * L.w + min(x + 1, L.w - 1)] - b1.v[y * L.w + max(x - 1, 0)]
            let gy = b1.v[min(y + 1, L.h - 1) * L.w + x] - b1.v[max(y - 1, 0) * L.w + x]
            mask.v[y * L.w + x] = float32(smooth01(0.01, 0.08, sqrt(gx * gx + gy * gy)))
      else:
        let hp = gaussPlane(L, 3.0)
        for i in 0 ..< L.v.len: mask.v[i] = float32(smooth01(0.008, 0.06, abs(L.v[i] - hp.v[i])))
      mask = gaussPlane(mask, 1.5)
    let t = float32(threshold) / 255
    template cut(x: float32): float32 =
      (if abs(x) <= t: 0'f32 elif x > 0: x - t else: x + t)
    var L1 = Plane(w: L.w, h: L.h, v: newSeqUninit[float32](L.v.len))
    let kf = float32(fine) / 100
    let km = float32(medium) / 100
    let kc = float32(coarse) / 100
    for i in 0 ..< L.v.len:
      var d = kf * cut(L.v[i] - b1.v[i]) + km * cut(b1.v[i] - b2.v[i]) + kc * cut(b2.v[i] - b3.v[i])
      if edges > 0: d *= mask.v[i]
      L1.v[i] = clamp(L.v[i] + d, 0, 1)
    withLight(src, L, L1)

proc bilateralBlur*(radius: int; tolerance: int): FilterFn =
  ## Bilateral Blur (Affinity's): each pixel the mean of those round it, within `radius`, that
  ## are like it -- `tolerance` (1..100 %) how unlike they may be: skin smoothed, its edges and
  ## the eyes sharp.
  let r = clamp(radius, 1, 100)
  let step = max(1, (r + 2) div 4)
  let sigS = float32(r) / 2
  let sigR = max(0.01'f32, float32(tolerance) / 100 * 0.35)
  # (how much a neighbour counts by how unlike it is: a table by the squared difference / 16)
  var like = newSeq[float32](3 * 255 * 255 div 16 + 2)
  for k in 0 ..< like.len:
    like[k] = exp(-float32(k * 16) / 3 / (2 * sigR * sigR * 255 * 255))
  result = proc (src: Img; inner: Rect): Img =
    var o = newImgUninit(src.w, src.h)
    let sp = pixPtr(src.px)
    let op = pixPtr(o.px)
    let (w, h) = (src.w, src.h)
    var offs: seq[(int, int, float32)]
    var dy = -r
    while dy <= r:
      var dx = -r
      while dx <= r:
        let d2 = float32(dx * dx + dy * dy)
        if d2 <= float32(r * r): offs.add (dx, dy, exp(-d2 / (2 * sigS * sigS)))
        dx += step
      dy += step
    let lk = fPtr(like)
    parallelRows(h, y):
      for x in 0 ..< w:
        let p = sp[y * w + x]
        let (pr, pg, pb) = (float32(rOf(p)), float32(gOf(p)), float32(bOf(p)))
        var acc = [0'f32, 0, 0, 0]
        for (ox, oy, ws) in offs:
          let q = sp[clamp(y + oy, 0, h - 1) * w + clamp(x + ox, 0, w - 1)]
          let dr = rOf(q) - int(pr)
          let dg = gOf(q) - int(pg)
          let db = bOf(q) - int(pb)
          let wt = ws * lk[(dr * dr + dg * dg + db * db) shr 4]
          acc[0] += wt
          acc[1] += wt * float32(rOf(q))
          acc[2] += wt * float32(gOf(q))
          acc[3] += wt * float32(bOf(q))
        op[y * w + x] = argb(aOf(p), int(acc[1] / acc[0] + 0.5), int(acc[2] / acc[0] + 0.5),
                             int(acc[3] / acc[0] + 0.5))
    o

proc ambientOcclusion*(radius: int; intensity: int; quality = 12): FilterFn =
  ## Ambient Occlusion (Affinity's): the picture taken as a relief -- light high, dark low --
  ## and shade put where the relief is hemmed in, within `radius` pixels: depth in a texture,
  ## a render, a carving. `intensity` 0..100 %; `quality` how many ways it looks (4..32).
  let r = clamp(radius, 1, 200)
  let n = clamp(quality, 4, 32)
  result = proc (src: Img; inner: Rect): Img =
    let hgt = gaussPlane(lumaPlane(src), max(0.8, float(r) / 12))
    let (w, h) = (src.w, src.h)
    var ao = Plane(w: w, h: h, v: newSeqUninit[float32](w * h))
    let hp = fPtr(hgt.v)
    let ap = fPtr(ao.v)
    var dirs: seq[(float32, float32)]
    for k in 0 ..< n:
      let a = float(k) / float(n) * 2 * PI
      dirs.add (float32(cos(a)), float32(sin(a)))
    let rings = [0.25'f32, 0.5, 0.75, 1.0]
    parallelRows(h, y):
      for x in 0 ..< w:
        let c = hp[y * w + x]
        var occ = 0'f32
        for (dx, dy) in dirs:
          var most = 0'f32
          for t in rings:
            let sx = clamp(x + int(dx * t * float32(r)), 0, w - 1)
            let sy = clamp(y + int(dy * t * float32(r)), 0, h - 1)
            # (how far above this pixel the relief rises there, for how far away it is)
            let rise = (hp[sy * w + sx] - c) / (t * 0.35 + 0.05)
            if rise > most: most = rise
          occ += min(1'f32, most)
        ap[y * w + x] = occ / float32(n)
    let ao2 = gaussPlane(ao, 1.0)
    var o = newImgUninit(w, h)
    let sp = pixPtr(src.px)
    let op = pixPtr(o.px)
    let k = float32(intensity) / 100 * 1.4
    for i in 0 ..< w * h:
      let p = sp[i]
      let m = clamp(1 - ao2.v[i] * k, 0, 1)
      op[i] = argb(aOf(p), int(float32(rOf(p)) * m + 0.5), int(float32(gOf(p)) * m + 0.5),
                   int(float32(bOf(p)) * m + 0.5))
    o

# ---- light -------------------------------------------------------------------------------------------------------

proc mixedLightCorrection*(strength: int; radius = 0; keepWarmth = 25): FilterFn =
  ## Mixed Light Correction (Affinity's): a room lit by a window and a lamp -- blue here,
  ## orange there -- each part's light made the same white. The light's cast round each pixel
  ## is found from what is nearly gray there (walls, paper, clouds: what shows the light's own
  ## color, not a thing's), over about `radius` pixels (0: a fifth of the picture), and taken
  ## away by `strength` %; `keepWarmth` % of the picture's overall cast is kept.
  result = proc (src: Img; inner: Rect): Img =
    let (w, h) = (src.w, src.h)
    let n = w * h
    let rr = if radius > 0: radius else: max(8, min(w, h) div 5)
    var u = newPlane(w, h)
    var v = newPlane(w, h)
    var wt = newPlane(w, h)
    var su, sv, sw = 0.0
    for i in 0 ..< n:
      let p = src.px[i]
      let r = float32(rOf(p)) + 4
      let g = float32(gOf(p)) + 4
      let b = float32(bOf(p)) + 4
      let mx = max(r, max(g, b))
      let mn = min(r, min(g, b))
      let sat = (mx - mn) / mx
      let l = (r * 0.30 + g * 0.59 + b * 0.11) / 259
      # (the grayer and the better lit, the more it says about the light)
      let k = exp(-sat * 5) * float32(smooth01(0.05, 0.25, l) * (1 - smooth01(0.92, 0.99, l)))
      u.v[i] = ln(r / g) * k
      v.v[i] = ln(b / g) * k
      wt.v[i] = k
      su += u.v[i]
      sv += v.v[i]
      sw += k
    let u0 = if sw > 0: su / sw else: 0.0
    let v0 = if sw > 0: sv / sw else: 0.0
    let sig = float(rr) / 2
    let us = gaussPlane(u, sig)
    let vs = gaussPlane(v, sig)
    let ws = gaussPlane(wt, sig)
    let k = float32(strength) / 100
    let keep = float32(keepWarmth) / 100
    var o = newImgUninit(w, h)
    for i in 0 ..< n:
      let p = src.px[i]
      # (where nothing near is gray, the picture's own cast: no change)
      let ww = ws.v[i]
      let lu = if ww > 1e-4: us.v[i] / ww else: float32(u0)
      let lv = if ww > 1e-4: vs.v[i] / ww else: float32(v0)
      let conf = min(1'f32, ww * 8)
      let tu = float32(u0) * keep
      let tv = float32(v0) * keep
      let cu = clamp((lu - tu) * k * conf, -0.6, 0.6)
      let cv = clamp((lv - tv) * k * conf, -0.6, 0.6)
      var r = float32(rOf(p)) * exp(-cu)
      var g = float32(gOf(p))
      var b = float32(bOf(p)) * exp(-cv)
      # (its lightness as it was)
      let l0 = float32(rOf(p)) * 0.30 + float32(gOf(p)) * 0.59 + float32(bOf(p)) * 0.11
      let l1 = r * 0.30 + g * 0.59 + b * 0.11
      if l1 > 0.5:
        let s = l0 / l1
        r *= s; g *= s; b *= s
      o.px[i] = argb(aOf(p), int(r + 0.5), int(g + 0.5), int(b + 0.5))
    o

proc toneCompression*(amount: int; detail = 0; radius = 40): FilterFn =
  ## Tone Compression (Affinity's): the light of the large parts brought together -- a bright
  ## sky and a dark ground nearer -- by `amount` %, their detail kept (`detail` % more);
  ## the parts are about `radius` pixels.
  result = proc (src: Img; inner: Rect): Img =
    let L = lumaPlane(src)
    let n = L.v.len
    var lg = Plane(w: L.w, h: L.h, v: newSeqUninit[float32](n))
    var mean = 0.0
    for i in 0 ..< n:
      lg.v[i] = ln(L.v[i] + 0.01)
      mean += lg.v[i]
    mean /= float(max(1, n))
    let base = guided(lg, lg, max(2, radius), 0.08)
    let c = 1 - clamp(float32(amount) / 100, 0, 0.95)
    let dk = 1 + float32(detail) / 100
    var L1 = Plane(w: L.w, h: L.h, v: newSeqUninit[float32](n))
    for i in 0 ..< n:
      let b = base.v[i]
      let nb = float32(mean) + (b - float32(mean)) * c
      L1.v[i] = clamp(exp(nb + (lg.v[i] - b) * dk) - 0.01, 0, 1)
    # (the colors scaled with their light, so they keep their hue)
    var o = newImgUninit(src.w, src.h)
    for i in 0 ..< n:
      let p = src.px[i]
      let s = (L1.v[i] + 0.004) / (L.v[i] + 0.004)
      o.px[i] = argb(aOf(p), int(float32(rOf(p)) * s + 0.5), int(float32(gOf(p)) * s + 0.5),
                     int(float32(bOf(p)) * s + 0.5))
    o

proc toneStretch*(clipShadows = 0.1; clipHighlights = 0.1; eachChannel = false): FilterFn =
  ## Tone Stretch (Affinity's): the darkest pixels made black and the lightest white
  ## (`clipShadows` and `clipHighlights` % of them let go past), the rest spread between --
  ## a flat, hazy picture given its whole range; `eachChannel` red, green and blue each
  ## (their casts taken away too).
  result = proc (src: Img; inner: Rect): Img =
    var hist: array[4, array[256, int]]
    var total = 0
    for y in inner.y ..< inner.y + inner.h:
      for x in inner.x ..< inner.x + inner.w:
        let p = src.px[y * src.w + x]
        if aOf(p) == 0: continue
        inc hist[0][lumaOf(p)]
        inc hist[1][rOf(p)]
        inc hist[2][gOf(p)]
        inc hist[3][bOf(p)]
        inc total
    if total == 0:
      result = src
      return
    proc ends(hs: array[256, int]): (int, int) =
      let lo = int(float(total) * clipShadows / 100)
      let hi = int(float(total) * clipHighlights / 100)
      var a = 0
      var s = 0
      while a < 255 and s + hs[a] <= lo:
        s += hs[a]
        inc a
      var b = 255
      s = 0
      while b > 0 and s + hs[b] <= hi:
        s += hs[b]
        dec b
      if b <= a: (0, 255) else: (a, b)
    var luts: array[3, Lut]
    for c in 0 .. 2:
      let (a, b) = if eachChannel: ends(hist[c + 1]) else: ends(hist[0])
      for v in 0 .. 255:
        luts[c][v] = uint8(clamp(int(round(float(v - a) / float(b - a) * 255)), 0, 255))
    var o = newImgUninit(src.w, src.h)
    for i in 0 ..< src.px.len:
      let p = src.px[i]
      o.px[i] = argb(aOf(p), int(luts[0][rOf(p)]), int(luts[1][gOf(p)]), int(luts[2][bOf(p)]))
    o

proc sdrToHdrDeep*(peak = 4.0; from0 = 0.6): DeepFn =
  ## SDR to HDR: a picture made for an ordinary screen given back the light of its highlights,
  ## in a 32-bit document's linear light -- a white sky up to `peak` times white (4: two stops
  ## brighter), the rest as it was; from lightness `from0` (0..1) up.
  result = proc (src: DeepImg; inner: Rect): DeepImg =
    var o = DeepImg(w: src.w, h: src.h, px: newSeqUninit[float32](src.px.len))
    let s = fPtr(src.px)
    let d = fPtr(o.px)
    let pk = float32(peak)
    let f0 = float32(from0)
    parallelFor(src.w * src.h, proc (lo, hi: int) =
      for i in lo ..< hi:
        let r = s[i * 4]
        let g = s[i * 4 + 1]
        let b = s[i * 4 + 2]
        let y = r * 0.2126 + g * 0.7152 + b * 0.0722
        # (its lightness as the screen showed it: past `from0`, brighter as it nears white)
        let t = clamp((pow(max(y, 0), 1 / 2.2) - f0) / (1 - f0), 0, 1)
        let gain = 1 + (pk - 1) * t * t * t
        d[i * 4] = r * gain
        d[i * 4 + 1] = g * gain
        d[i * 4 + 2] = b * gain
        d[i * 4 + 3] = s[i * 4 + 3])
    o

# ---- color -------------------------------------------------------------------------------------------------------

proc tintOf(hue, sat: float): (float, float, float) =
  ## (a hue's color as a push away from gray, its lightness none: saturation 0..100)
  let p = fromHsl(hue, 1, 0.5)
  let r = rOf(p) / 255
  let g = gOf(p) / 255
  let b = bOf(p) / 255
  let y = r * 0.30 + g * 0.59 + b * 0.11
  let k = sat / 100 * 0.45
  ((r - y) * k, (g - y) * k, (b - y) * k)

proc colorGrading*(shadows, midtones, highlights: (float, float, float); blending = 50.0;
                   balance = 0.0; global = (0.0, 0.0, 0.0)): FilterFn =
  ## Color Grading (Camera Raw's wheels): the shadows, the midtones and the highlights each
  ## toned with a hue (0..360) by so much (0..100) and made lighter or darker (-100..100);
  ## `global` all over; `blending` (0..100) how far each reaches into the others; `balance`
  ## (-100..100) toward the highlights or the shadows.
  let ts = tintOf(shadows[0], shadows[1])
  let tm = tintOf(midtones[0], midtones[1])
  let th = tintOf(highlights[0], highlights[1])
  let tg = tintOf(global[0], global[1])
  let pivot = clamp(0.5 - balance / 250, 0.1, 0.9)
  let soft = 0.6 + blending / 100 * 1.6
  proc one(p: uint32): uint32 =
    var r = rOf(p) / 255
    var g = gOf(p) / 255
    var b = bOf(p) / 255
    let y = r * 0.30 + g * 0.59 + b * 0.11
    let ws = pow(clamp((pivot - y) / pivot + 0.35, 0, 1), 1 / soft)
    let wh = pow(clamp((y - pivot) / (1 - pivot) + 0.35, 0, 1), 1 / soft)
    let wm = clamp(1 - abs(y - pivot) * 2.2, 0, 1)
    for (wt, t, l) in [(ws, ts, shadows[2]), (wm, tm, midtones[2]), (wh, th, highlights[2]), (1.0, tg, global[2])]:
      if wt <= 0: continue
      r += wt * (t[0] + l / 100 * 0.25)
      g += wt * (t[1] + l / 100 * 0.25)
      b += wt * (t[2] + l / 100 * 0.25)
    argb(aOf(p), int(round(r * 255)), int(round(g * 255)), int(round(b * 255)))
  mapFn(one)

proc splitToning*(shadowHue, shadowSat, highlightHue, highlightSat: float; balance = 0.0): FilterFn =
  ## Split Toning: the shadows toned with one hue (0..360, so much: 0..100) and the
  ## highlights with another; `balance` (-100..100) toward the highlights or the shadows.
  colorGrading((shadowHue, shadowSat, 0.0), (0.0, 0.0, 0.0), (highlightHue, highlightSat, 0.0),
               blending = 70, balance = balance)

proc channelInversion*(mode: int; base = 0'u32; strength = 100): FilterFn =
  ## Channel Inversion (Affinity's): `mode` 0 a color film negative made positive -- the film's
  ## own orange (`base`; 0: found, the lightest part of the frame) taken out, each channel
  ## spread to its whole range --, 1 a black and white negative, 2 infrared (red and blue
  ## swapped: the false-color sky), 3 each channel inverted as it is. `strength` %.
  result = proc (src: Img; inner: Rect): Img =
    var o = newImgUninit(src.w, src.h)
    let k = clamp(strength, 0, 100) / 100
    case mode
    of 0, 1:
      var b = base
      if b == 0:
        # (the film's base: the brightest part of the negative -- the unexposed edge)
        var best = -1
        for p in src.px:
          let l = lumaOf(p)
          if aOf(p) > 0 and l > best:
            best = l
            b = p
        var acc = [0.0, 0.0, 0.0]
        var cnt = 0.0
        for p in src.px:
          if aOf(p) > 0 and lumaOf(p) >= best - 12:
            acc[0] += rOf(p).float; acc[1] += gOf(p).float; acc[2] += bOf(p).float
            cnt += 1
        if cnt > 0: b = argb(255, int(acc[0] / cnt), int(acc[1] / cnt), int(acc[2] / cnt))
      let br = max(1.0, rOf(b).float)
      let bg = max(1.0, gOf(b).float)
      let bb = max(1.0, bOf(b).float)
      var vals = newSeqUninit[array[3, float32]](src.px.len)
      var hist: array[3, array[1024, int]]
      for i, p in src.px:
        var c = [float32(1 - rOf(p).float / br), float32(1 - gOf(p).float / bg), float32(1 - bOf(p).float / bb)]
        if mode == 1:
          let y = c[0] * 0.30'f32 + c[1] * 0.59'f32 + c[2] * 0.11'f32
          c = [y, y, y]
        vals[i] = c
        if aOf(p) > 0:
          for ch in 0 .. 2: inc hist[ch][clamp(int(c[ch] * 1023), 0, 1023)]
      var lo, hi: array[3, float32]
      let n = src.px.len
      for ch in 0 .. 2:
        var s = 0
        var a = 0
        while a < 1023 and s + hist[ch][a] < n div 500:
          s += hist[ch][a]
          inc a
        var z = 1023
        s = 0
        while z > 0 and s + hist[ch][z] < n div 500:
          s += hist[ch][z]
          dec z
        lo[ch] = float32(a) / 1023
        hi[ch] = max(lo[ch] + 0.02, float32(z) / 1023)
      for i, p in src.px:
        var c: array[3, int]
        for ch in 0 .. 2:
          let v = clamp((vals[i][ch] - lo[ch]) / (hi[ch] - lo[ch]), 0, 1)
          let orig = [rOf(p), gOf(p), bOf(p)][ch].float / 255
          c[ch] = int(round((orig + (v - orig) * k) * 255))
        o.px[i] = argb(aOf(p), c[0], c[1], c[2])
    of 2:
      for i, p in src.px:
        let r = rOf(p).float
        let b = bOf(p).float
        o.px[i] = argb(aOf(p), int(round(r + (b - r) * k)), gOf(p), int(round(b + (r - b) * k)))
    else:
      for i, p in src.px:
        o.px[i] = argb(aOf(p), int(round(rOf(p).float + (255 - 2 * rOf(p)).float * k)),
                       int(round(gOf(p).float + (255 - 2 * gOf(p)).float * k)),
                       int(round(bOf(p).float + (255 - 2 * bOf(p)).float * k)))
    o

# ---- masks -------------------------------------------------------------------------------------------------------

proc luminosityMask*(src: Img; lo, hi: int; soft = 20): seq[uint8] =
  ## A mask of the pixels whose lightness (0..255) is from `lo` to `hi`, falling off over
  ## `soft` levels each side (Affinity's Luminosity Range mask; the usual "lights", "darks").
  result = newSeq[uint8](src.px.len)
  let s = max(1, soft)
  for i, p in src.px:
    let l = lumaOf(p)
    let a = if l < lo: 1.0 - min(1.0, float(lo - l) / s.float)
            elif l > hi: 1.0 - min(1.0, float(l - hi) / s.float)
            else: 1.0
    result[i] = uint8(round(a * 255))

proc hueRangeMask*(src: Img; hue, width: float; soft = 30.0; minSat = 10): seq[uint8] =
  ## A mask of the pixels whose hue is within `width` degrees of `hue` (each side), falling off
  ## over `soft` more, the grays (saturation under `minSat` %) out (Affinity's Hue Range mask).
  result = newSeq[uint8](src.px.len)
  for i, p in src.px:
    let (h, s, _) = toHsb(p)
    if s * 100 < minSat.float: continue
    var dh = abs(h - hue)
    if dh > 180: dh = 360 - dh
    let a = if dh <= width: 1.0 else: 1.0 - min(1.0, (dh - width) / max(1.0, soft))
    let sk = min(1.0, (s * 100 - minSat.float) / 15 + 0.2)
    result[i] = uint8(round(clamp(a * sk, 0, 1) * 255))

proc compoundMask*(a, b: seq[uint8]; op: int): seq[uint8] =
  ## Two masks made one (Affinity's Compound mask): `op` 0 added, 1 the second taken from the
  ## first, 2 where both are, 3 where they differ.
  result = newSeq[uint8](min(a.len, b.len))
  for i in 0 ..< result.len:
    let x = int(a[i])
    let y = int(b[i])
    result[i] = uint8(case op
                      of 0: min(255, x + y)
                      of 1: max(0, x - y)
                      of 2: x * y div 255
                      else: abs(x - y))

# ---- stylize -----------------------------------------------------------------------------------------------------

proc glitch*(shift = 6; slices = 8; offset = 24; blocks = 4; noise = 8; scanlines = 25; seed = 1): FilterFn =
  ## Glitch (Affinity's live filter): a broken signal -- red and blue pulled apart by `shift`
  ## pixels, `slices` bands of rows slid up to `offset` pixels, `blocks` squares copied out of
  ## place, `noise` % of static, `scanlines` % dark lines.
  result = proc (src: Img; inner: Rect): Img =
    var rng = initRand(seed)
    let (w, h) = (src.w, src.h)
    var rowShift = newSeq[int](h)
    for k in 0 ..< slices:
      let y0 = rng.rand(h - 1)
      let hh = 2 + rng.rand(max(2, h div 14))
      let dx = rng.rand(2 * offset) - offset
      for y in y0 ..< min(h, y0 + hh): rowShift[y] += dx
    var o = newImgUninit(w, h)
    for y in 0 ..< h:
      let dark = scanlines > 0 and y mod 3 == 0
      for x in 0 ..< w:
        let sx = x - rowShift[y]
        let pr = src.at(sx + shift, y)
        let pg = src.at(sx, y)
        let pb = src.at(sx - shift, y)
        var r = rOf(pr)
        var g = gOf(pg)
        var b = bOf(pb)
        if dark:
          let m = 1 - scanlines / 100 * 0.5
          r = int(r.float * m); g = int(g.float * m); b = int(b.float * m)
        o.px[y * w + x] = argb(aOf(pg), r, g, b)
    for k in 0 ..< blocks:
      let bw = 8 + rng.rand(max(8, w div 6))
      let bh = 4 + rng.rand(max(4, h div 16))
      let sx = rng.rand(max(1, w - bw))
      let sy = rng.rand(max(1, h - bh))
      let tx = clamp(sx + rng.rand(w div 3) - w div 6, 0, max(0, w - bw))
      let ty = clamp(sy + rng.rand(h div 8) - h div 16, 0, max(0, h - bh))
      for y in 0 ..< bh:
        for x in 0 ..< bw:
          if ty + y < h and tx + x < w: o.px[(ty + y) * w + tx + x] = src.at(sx + x, sy + y)
    if noise > 0:
      for i in 0 ..< o.px.len:
        if rng.rand(100) < noise div 3 + 1:
          let n = rng.rand(120) - 60
          let p = o.px[i]
          o.px[i] = argb(aOf(p), rOf(p) + n, gOf(p) + n, bOf(p) + n)
    o

# ---- lens --------------------------------------------------------------------------------------------------------

proc adaptiveWideAngle*(model: int; focal: float; cropFactor = 1.0; scale = 100.0): FilterFn =
  ## Adaptive Wide Angle: the lines a wide lens bends made straight. `model` 0 a fisheye
  ## (equidistant), 1 a wide lens's stretched edges given back their shape (Perspective), 2 a
  ## 360 picture (equirectangular) seen through a lens of `focal` mm; `focal` the lens's (35 mm
  ## film's, times `cropFactor` for a smaller sensor); `scale` % how much of it shows.
  result = proc (src: Img; inner: Rect): Img =
    let (w, h) = (src.w, src.h)
    let cx = float(w - 1) / 2
    let cy = float(h - 1) / 2
    let diag = sqrt(float(w * w + h * h))
    let f = max(1.0, focal * cropFactor) / 43.27 * diag      # (in pixels: 43.27 mm is film's diagonal)
    # (at 100 %: framed so the picture's width is filled, its middle row reaching its edges)
    let half = float(w) / 2
    let fit = case model
              of 0: (if half / f < PI / 2 - 0.05: f * tan(half / f) / half else: 1.0)
              of 1: 2 * f * tan(arctan(half / f) / 2) / half
              else: 1.0
    let s = fit * 100 / max(10.0, scale)
    var o = newImgUninit(w, h)
    parallelRows(h, y):
      for x in 0 ..< w:
        let dx = (float(x) - cx) * s
        let dy = (float(y) - cy) * s
        var sx, sy: float
        case model
        of 0:
          let ro = sqrt(dx * dx + dy * dy)
          if ro < 1e-6:
            sx = cx; sy = cy
          else:
            let th = arctan(ro / f)
            let ri = f * th
            sx = cx + dx * ri / ro
            sy = cy + dy * ri / ro
        of 1:
          # (shown stereographically -- the edges' shapes kept -- from a lens that shows straight)
          let ro = sqrt(dx * dx + dy * dy)
          if ro < 1e-6:
            sx = cx; sy = cy
          else:
            let th = 2 * arctan(ro / (2 * f))
            let ri = f * tan(min(th, 1.5))
            sx = cx + dx * ri / ro
            sy = cy + dy * ri / ro
        else:
          let lon = arctan2(dx, f)
          let lat = arctan2(dy, sqrt(f * f + dx * dx))
          sx = (lon / PI + 1) / 2 * float(w - 1)
          sy = (lat / (PI / 2) + 1) / 2 * float(h - 1)
        if sx < -0.5 or sy < -0.5 or sx > float(w) - 0.5 or sy > float(h) - 0.5:
          o.px[y * w + x] = 0
        else:
          o.px[y * w + x] = src.sample(sx, sy)
    o

# ---- shake: found and taken out ---------------------------------------------------------------------------------

proc fft1(re, im: var openArray[float32]; inverse: bool) =
  ## (a radix-2 Fourier transform, in place; the length a power of two)
  let n = re.len
  var j = 0
  for i in 1 ..< n:
    var bit = n shr 1
    while (j and bit) != 0:
      j = j xor bit
      bit = bit shr 1
    j = j xor bit
    if i < j:
      swap(re[i], re[j])
      swap(im[i], im[j])
  var len = 2
  while len <= n:
    let ang = 2 * PI / float(len) * (if inverse: 1.0 else: -1.0)
    let wr = float32(cos(ang))
    let wi = float32(sin(ang))
    var i = 0
    while i < n:
      var cr = 1'f32
      var ci = 0'f32
      for k in 0 ..< len div 2:
        let a = i + k
        let b = a + len div 2
        let tr = re[b] * cr - im[b] * ci
        let ti = re[b] * ci + im[b] * cr
        re[b] = re[a] - tr
        im[b] = im[a] - ti
        re[a] += tr
        im[a] += ti
        let ncr = cr * wr - ci * wi
        ci = cr * wi + ci * wr
        cr = ncr
      i += len
    len = len shl 1
  if inverse:
    let k = 1 / float32(n)
    for i in 0 ..< n:
      re[i] *= k
      im[i] *= k

proc fft2*(re, im: var seq[float32]; n: int; inverse = false) =
  ## A 2D Fourier transform of an `n` x `n` grid (`n` a power of two), in place.
  let rp = fPtr(re)
  let ip = fPtr(im)
  parallelFor(n, proc (lo, hi: int) =
    var r = newSeq[float32](n)
    var i = newSeq[float32](n)
    for y in lo ..< hi:
      for x in 0 ..< n:
        r[x] = rp[y * n + x]
        i[x] = ip[y * n + x]
      fft1(r, i, inverse)
      for x in 0 ..< n:
        rp[y * n + x] = r[x]
        ip[y * n + x] = i[x])
  parallelFor(n, proc (lo, hi: int) =
    var r = newSeq[float32](n)
    var i = newSeq[float32](n)
    for x in lo ..< hi:
      for y in 0 ..< n:
        r[y] = rp[y * n + x]
        i[y] = ip[y * n + x]
      fft1(r, i, inverse)
      for y in 0 ..< n:
        rp[y * n + x] = r[y]
        ip[y * n + x] = i[y])

proc estimateShake*(src: Img): tuple[angle, length: int] =
  ## Which way and how far the camera moved while the picture was taken (a straight shake):
  ## from the picture's cepstrum -- a blur of a line `length` long leaves a dip that far from
  ## the middle, the way it went. `angle` as Motion Blur takes it (degrees counterclockwise
  ## from across, 0..179). (0, 0) when no shake is found.
  if min(src.w, src.h) < 64: return (0, 0)
  var n = 64
  while n * 2 <= min(src.w, src.h) and n < 256: n *= 2
  # (the spectra of up to 3 x 3 windows across the picture, averaged: what is the picture's own
  # differs from window to window, the shake does not)
  proc spots(len: int): seq[int] =
    let k = clamp(1 + (len - n) div (n div 2), 1, 3)
    for i in 0 ..< k: result.add (if k == 1: (len - n) div 2 else: i * (len - n) div (k - 1))
  var logSum = newSeq[float32](n * n)
  var re = newSeq[float32](n * n)
  var im = newSeq[float32](n * n)
  var tiles = 0
  for y0 in spots(src.h):
    for x0 in spots(src.w):
      for y in 0 ..< n:
        let wy = 0.5 - 0.5 * cos(2 * PI * float(y) / float(n - 1))
        for x in 0 ..< n:
          let wx = 0.5 - 0.5 * cos(2 * PI * float(x) / float(n - 1))
          re[y * n + x] = float32(float(lumaOf(src.at(x0 + x, y0 + y))) / 255 * wx * wy)
          im[y * n + x] = 0
      fft2(re, im, n)
      for k in 0 ..< n * n: logSum[k] += ln(1 + sqrt(re[k] * re[k] + im[k] * im[k]))
      inc tiles
  for k in 0 ..< n * n:
    re[k] = logSum[k] / float32(tiles)
    im[k] = 0
  fft2(re, im, n, inverse = true)
  template cep(x, y: int): float32 = re[((y + n) mod n) * n + ((x + n) mod n)]
  var best = 0'f32
  var bestA = 0
  var bestL = 0
  let maxL = min(80, n div 3)
  for a in 0 ..< 180:
    let ca = cos(float(a) * PI / 180)
    let sa = sin(float(a) * PI / 180)
    for d in 4 .. maxL:
      let x = int(round(ca * float(d)))
      let y = int(round(sa * float(d)))
      let v = cep(x, y) + 0.5 * (cep(x + 1, y) + cep(x - 1, y) + cep(x, y + 1) + cep(x, y - 1)) / 4
      if v < best:
        best = v
        bestA = a
        bestL = d
  # (a dip too shallow is the picture's own detail, not a shake)
  var mean, sd = 0.0
  var cnt = 0
  for d in 4 .. maxL:
    for a in countup(0, 179, 15):
      let v = cep(int(round(cos(float(a) * PI / 180) * float(d))), int(round(sin(float(a) * PI / 180) * float(d))))
      mean += v
      sd += v * v
      inc cnt
  mean /= float(cnt)
  sd = sqrt(max(0.0, sd / float(cnt) - mean * mean))
  if float(best) > mean - 2.5 * sd: return (0, 0)
  ((180 - bestA) mod 180, bestL)

proc localRange(p: Plane; r: int): tuple[lo, hi: Plane] =
  ## (the least and the most of the values within `r` of each)
  let (w, h) = (p.w, p.h)
  var tlo = newSeqUninit[float32](w * h)
  var thi = newSeqUninit[float32](w * h)
  let s = fPtr(p.v)
  let a = fPtr(tlo)
  let b = fPtr(thi)
  parallelRows(h, y):
    for x in 0 ..< w:
      var mn = 1e9'f32
      var mx = -1e9'f32
      for k in max(0, x - r) .. min(w - 1, x + r):
        let v = s[y * w + k]
        if v < mn: mn = v
        if v > mx: mx = v
      a[y * w + x] = mn
      b[y * w + x] = mx
  result.lo = Plane(w: w, h: h, v: newSeqUninit[float32](w * h))
  result.hi = Plane(w: w, h: h, v: newSeqUninit[float32](w * h))
  let lo = fPtr(result.lo.v)
  let hi = fPtr(result.hi.v)
  parallelRows(h, y):
    for x in 0 ..< w:
      var mn = 1e9'f32
      var mx = -1e9'f32
      for k in max(0, y - r) .. min(h - 1, y + r):
        let i = k * w + x
        if a[i] < mn: mn = a[i]
        if b[i] > mx: mx = b[i]
      lo[y * w + x] = mn
      hi[y * w + x] = mx

proc samplePlane(p: Plane; x, y: float): float32 {.inline.} =
  ## (the plane between its points; past its edges, its edges)
  let xf = clamp(x, 0.0, float(p.w - 1))
  let yf = clamp(y, 0.0, float(p.h - 1))
  let x0 = min(int(xf), p.w - 2)
  let y0 = min(int(yf), p.h - 2)
  if x0 < 0 or y0 < 0: return p.v[clamp(int(yf), 0, p.h - 1) * p.w + clamp(int(xf), 0, p.w - 1)]
  let fx = float32(xf - float(x0))
  let fy = float32(yf - float(y0))
  let a = p.v[y0 * p.w + x0]
  let b = p.v[y0 * p.w + x0 + 1]
  let c = p.v[(y0 + 1) * p.w + x0]
  let d = p.v[(y0 + 1) * p.w + x0 + 1]
  (a * (1 - fx) + b * fx) * (1 - fy) + (c * (1 - fx) + d * fx) * fy

proc lineBox(p: Plane; length: float): Plane =
  ## (each row blurred by a box `length` long, its ends weighed by what part of them is in it:
  ## a straight shake along the rows; running sums, so as quick for a long one)
  result = Plane(w: p.w, h: p.h, v: newSeqUninit[float32](p.v.len))
  let (w, h) = (p.w, p.h)
  let s = fPtr(p.v)
  let o = fPtr(result.v)
  let half = length / 2
  parallelFor(h, proc (lo, hi: int) =
    var cum = newSeq[float](w + 1)
    for y in lo ..< hi:
      for x in 0 ..< w: cum[x + 1] = cum[x] + float(s[y * w + x])
      template at(t0: float): float =
        # (the running sum at `t`, between pixels; past the edges the edge pixel carried on)
        let t = t0
        if t <= 0: t * float(s[y * w])
        elif t >= float(w): cum[w] + (t - float(w)) * float(s[y * w + w - 1])
        else:
          let i = int(t)
          cum[i] + (t - float(i)) * float(s[y * w + i])
      for x in 0 ..< w:
        let c = float(x) + 0.5
        o[y * w + x] = float32((at(c + half) - at(c - half)) / length))

proc shakeReduction*(angle, length: int; smoothing = 30; artifacts = 30): FilterFn =
  ## Shake Reduction (Affinity's Motion Blur Reduction): a straight shake `length` pixels at
  ## `angle` degrees (as Motion Blur takes them) taken out of the picture -- both 0: found by
  ## `estimateShake`. `smoothing` (0..100) how much noise it keeps down (fewer steps of the
  ## sharpening); `artifacts` (0..100) how much it lets the light go past what the blurred
  ## picture had round each pixel (the ringing at edges: 0 none). Richardson-Lucy's way, along
  ## the shake: the lightness is sharpened, so no color fringes come.
  result = proc (src: Img; inner: Rect): Img =
    var a = angle
    var L = length
    if L <= 0:
      (a, L) = estimateShake(src)
      if L <= 0:
        result = src
        return
    L = clamp(L, 2, 200)
    let (w, h) = (src.w, src.h)
    let Lsrc = lumaPlane(src)
    # (the picture turned so that the shake goes along its rows)
    let th = float(a) * PI / 180
    let ca = cos(th)
    let sa = sin(th)
    let rw = int(ceil(abs(float(w) * ca) + abs(float(h) * sa))) + 2
    let rh = int(ceil(abs(float(w) * sa) + abs(float(h) * ca))) + 2
    let cx = float(w - 1) / 2
    let cy = float(h - 1) / 2
    let rcx = float(rw - 1) / 2
    let rcy = float(rh - 1) / 2
    var obs = Plane(w: rw, h: rh, v: newSeqUninit[float32](rw * rh))
    let op0 = fPtr(obs.v)
    parallelRows(rh, v):
      for u in 0 ..< rw:
        let du = float(u) - rcx
        let dv = float(v) - rcy
        # (along a row: the way the shake went -- across, and up the picture as y counts down)
        op0[v * rw + u] = samplePlane(Lsrc, cx + du * ca + dv * sa, cy - du * sa + dv * ca)
    let iters = clamp(int(round(45 - float(smoothing) * 0.38)), 6, 45)
    var est = obs
    let eps = 0.003'f32
    var ratio = Plane(w: rw, h: rh, v: newSeqUninit[float32](rw * rh))
    for it in 0 ..< iters:
      let c = lineBox(est, float(L))
      let cp = fPtr(c.v)
      let rp = fPtr(ratio.v)
      let ob = fPtr(obs.v)
      parallelFor(rw * rh, proc (lo, hi: int) =
        for i in lo ..< hi: rp[i] = (ob[i] + eps) / (cp[i] + eps))
      let back = lineBox(ratio, float(L))
      let bp = fPtr(back.v)
      let ep = fPtr(est.v)
      parallelFor(rw * rh, proc (lo, hi: int) =
        for i in lo ..< hi: ep[i] = clamp(ep[i] * bp[i], 0, 1.6))
    # (what it changed, turned back and laid on the lightness: the picture is not resampled)
    var delta = Plane(w: rw, h: rh, v: newSeqUninit[float32](rw * rh))
    for i in 0 ..< delta.v.len: delta.v[i] = est.v[i] - obs.v[i]
    var Lout = Plane(w: w, h: h, v: newSeqUninit[float32](w * h))
    let dp = fPtr(Lout.v)
    let sp = fPtr(Lsrc.v)
    parallelRows(h, y):
      for x in 0 ..< w:
        let dx = float(x) - cx
        let dy = float(y) - cy
        let u = rcx + dx * ca - dy * sa
        let v = rcy + dx * sa + dy * ca
        dp[y * w + x] = sp[y * w + x] + samplePlane(delta, u, v)
    # (no lighter or darker than the blurred picture was round it, give or take `artifacts`)
    let (mn, mx) = localRange(Lsrc, max(1, L div 2 + 1))
    let slack = float32(artifacts) / 100 * 0.4
    for i in 0 ..< w * h:
      let span = mx.v[i] - mn.v[i]
      Lout.v[i] = clamp(Lout.v[i], max(0'f32, mn.v[i] - span * slack - 0.02), min(1'f32, mx.v[i] + span * slack + 0.02))
    withLight(src, Lsrc, Lout)

# ---- render: flames, trees, frames -------------------------------------------------------------------------------

proc noise1(x: float; seed: int): float =
  ## (smooth noise along a line, -1..1)
  let i = int(floor(x))
  let f = x - float(i)
  proc h(k: int): float =
    var v = cast[uint32](k) * 374761393'u32 + cast[uint32](seed) * 668265263'u32   # (wraps: no overflow where int has 32 bits)
    v = (v xor (v shr 13)) * 1274126177'u32
    float(v and 0xFFFF) / 32767.5 - 1
  let u = f * f * (3 - 2 * f)
  h(i) * (1 - u) + h(i + 1) * u

proc over(o: var Img; x, y: int; c: uint32; a: float) {.inline.} =
  ## (color `c` laid over the pixel at `x`, `y` by `a`, 0..1)
  if x < 0 or y < 0 or x >= o.w or y >= o.h or a <= 0: return
  let i = y * o.w + x
  let k = clamp(a, 0, 1) * float(aOf(c)) / 255
  let p = o.px[i]
  let pa = float(aOf(p)) / 255
  let na = k + pa * (1 - k)
  if na <= 0: return
  template ch(s: int): int =
    int(round((float((c shr s) and 255) * k + float((p shr s) and 255) * pa * (1 - k)) / na))
  o.px[i] = argb(int(round(na * 255)), ch(16), ch(8), ch(0))

proc capsule(o: var Img; x0, y0, x1, y1, r0, r1: float; c: uint32) =
  ## (a stroke from one point to another, `r0` thick at its start and `r1` at its end, smooth edged)
  let minx = int(floor(min(x0, x1) - max(r0, r1) - 1))
  let maxx = int(ceil(max(x0, x1) + max(r0, r1) + 1))
  let miny = int(floor(min(y0, y1) - max(r0, r1) - 1))
  let maxy = int(ceil(max(y0, y1) + max(r0, r1) + 1))
  let dx = x1 - x0
  let dy = y1 - y0
  let ll = max(1e-6, dx * dx + dy * dy)
  for y in max(0, miny) .. min(o.h - 1, maxy):
    for x in max(0, minx) .. min(o.w - 1, maxx):
      let px = float(x) + 0.5 - x0
      let py = float(y) + 0.5 - y0
      let t = clamp((px * dx + py * dy) / ll, 0, 1)
      let ex = px - t * dx
      let ey = py - t * dy
      let r = r0 + (r1 - r0) * t
      let d = sqrt(ex * ex + ey * ey) - r
      if d < 0.7: o.over(x, y, c, clamp(0.5 - d, 0, 1))

proc blob(o: var Img; cx, cy, rx, ry, ang: float; c: uint32) =
  ## (an ellipse, turned `ang` radians)
  let r = max(rx, ry) + 1
  let ca = cos(ang)
  let sa = sin(ang)
  for y in max(0, int(cy - r)) .. min(o.h - 1, int(cy + r)):
    for x in max(0, int(cx - r)) .. min(o.w - 1, int(cx + r)):
      let px = float(x) + 0.5 - cx
      let py = float(y) + 0.5 - cy
      let u = (px * ca + py * sa) / max(0.5, rx)
      let v = (-px * sa + py * ca) / max(0.5, ry)
      let d = (sqrt(u * u + v * v) - 1) * min(rx, ry)
      if d < 0.7: o.over(x, y, c, clamp(0.5 - d, 0, 1))

proc flameColor(t: float; fg: uint32; natural: bool): uint32 =
  ## (a flame's color, 0 at its tip and edges to 1 at its heart)
  if not natural:
    return withAlpha(fg, int(clamp(t * 1.6, 0, 1) * 255))
  let a = clamp(t * 1.8, 0, 1)
  let r = clamp(t * 3, 0, 1)
  let g = clamp(t * 2.2 - 0.55, 0, 1)
  let b = clamp(t * 3 - 2.2, 0, 1)
  argb(int(a * 255), int(r * 255), int(g * 235), int(b * 200))

proc flame*(base: seq[(float, float)]; length = 120; width = 26; count = 0; turbulence = 50;
            natural = true; color = 0xFFFF6A00'u32; seed = 1): FilterFn =
  ## Render > Flame: flames rising from the line `base` (points in the document's pixels: a path
  ## or a selection's bottom edge), `length` and `width` pixels, `count` of them (0: as many as
  ## fit), licking about by `turbulence` %; natural fire's colors, or `color`.
  result = proc (src: Img; inner: Rect): Img =
    var o = src
    if base.len < 2:
      result = src
      return
    var pts: seq[(float, float)]
    for p in base: pts.add (p[0] - float(filterOrigin.x), p[1] - float(filterOrigin.y))
    var lens = @[0.0]
    for i in 1 ..< pts.len:
      let next = lens[^1] + hypot(pts[i][0] - pts[i - 1][0], pts[i][1] - pts[i - 1][1])
      lens.add next
    let total = lens[^1]
    if total <= 0:
      result = src
      return
    let nFl = if count > 0: count else: max(1, int(total / (float(width) * 0.55)))
    var rng = initRand(seed)
    # (the heat of all the tongues, added up, then colored: where they meet the fire is hotter)
    var heat = newPlane(o.w, o.h)
    for k in 0 ..< nFl:
      let at = (float(k) + 0.5) / float(nFl) * total + (rng.rand(1.0) - 0.5) * float(width) * 0.3
      var seg = 1
      while seg < lens.high and lens[seg] < at: inc seg
      let t = clamp((at - lens[seg - 1]) / max(1e-6, lens[seg] - lens[seg - 1]), 0, 1)
      let bx = pts[seg - 1][0] + (pts[seg][0] - pts[seg - 1][0]) * t
      let by = pts[seg - 1][1] + (pts[seg][1] - pts[seg - 1][1]) * t
      # (up from the line: the side the image's top is on)
      var nx = -(pts[seg][1] - pts[seg - 1][1])
      var ny = pts[seg][0] - pts[seg - 1][0]
      let nl = max(1e-6, hypot(nx, ny))
      nx /= nl; ny /= nl
      if ny > 0:
        nx = -nx; ny = -ny
      let fl = float(length) * (0.6 + rng.rand(0.7))
      let fw = float(width) * (0.8 + rng.rand(0.5))
      let sd = seed * 131 + k * 17
      let turb = float(turbulence) / 100
      let reach = fl + fw
      let x0 = max(0, int(bx - reach))
      let x1 = min(o.w - 1, int(bx + reach))
      let y0 = max(0, int(by - reach))
      let y1 = min(o.h - 1, int(by + reach))
      for y in y0 .. y1:
        for x in x0 .. x1:
          let px = float(x) + 0.5 - bx
          let py = float(y) + 0.5 - by
          let u = (px * nx + py * ny) / fl                 # (0 at the base, 1 at the tip)
          if u < -0.08 or u > 1: continue
          let uu = max(0.0, u)
          var v = px * (-ny) + py * nx                     # (across)
          # (the tongue sways more toward its tip, and flickers)
          v -= noise1(uu * 2.6 + float(k) * 0.7, sd) * turb * fw * 0.9 * uu +
               noise1(uu * 7 + float(k), sd + 7) * turb * fw * 0.25 * uu
          let half = fw / 2 * pow(1 - uu, 0.75) * (0.6 + 0.4 * min(1.0, uu * 5 + 0.3))
          if half <= 0.3: continue
          let across = abs(v) / half
          if across >= 1.15: continue
          let edge = clamp(1.15 - across, 0, 1)
          let bottom = if u < 0: clamp(1 + u / 0.08, 0, 1) else: 1.0
          heat.v[y * o.w + x] += float32(edge * (1 - uu * 0.75) * bottom * 0.85)
    for i in 0 ..< heat.v.len:
      let hh = float(heat.v[i])
      if hh <= 0.01: continue
      let c = flameColor(clamp(hh, 0, 1.2) / 1.2, color, natural)
      o.over(i mod o.w, i div o.w, c, 1)
    o

proc tree*(box: Rect; kind = 0; leaves = 60; leafSize = 50; thickness = 50; leafColor = 0'u32;
           seed = 1): FilterFn =
  ## Render > Tree: a tree growing from the bottom middle of `box` (document pixels) to its top --
  ## `kind` 0 broad-leaved, 1 a conifer, 2 a willow, 3 bare branches, 4 a palm --, with so many
  ## leaves (0..100 %) of a size (0..100 %), its trunk so thick (0..100 %); leaves of
  ## `leafColor` (0: the tree's own greens).
  result = proc (src: Img; inner: Rect): Img =
    var o = src
    let bx = float(box.x - filterOrigin.x)
    let by = float(box.y - filterOrigin.y)
    let ht = float(max(20, box.h))
    var rng = initRand(seed)
    let bark = 0xFF5B3A21'u32
    let barkHi = 0xFF7A5232'u32
    let trunkW = ht * 0.035 * (0.4 + float(thickness) / 100 * 1.2)
    let leafR = ht * 0.018 * (0.4 + float(leafSize) / 100 * 1.4)
    var greens = @[0xFF2E7D32'u32, 0xFF388E3C'u32, 0xFF43A047'u32, 0xFF1B5E20'u32, 0xFF558B2F'u32]
    if leafColor != 0:
      greens = @[leafColor, mix(leafColor, 0xFF000000'u32, 0.2), mix(leafColor, 0xFFFFFFFF'u32, 0.15)]
    var leafAt: seq[(float, float, float)]
    proc branch(x, y, ang, len, r: float; depth: int) =
      if depth <= 0 or len < 2 or r < 0.3:
        leafAt.add (x, y, ang)
        return
      let x1 = x + cos(ang) * len
      let y1 = y + sin(ang) * len
      o.capsule(x, y, x1, y1, r, r * 0.72, if depth mod 2 == 0: bark else: barkHi)
      let n = if kind == 4: 0 else: 2 + rng.rand(1)
      for k in 0 ..< n:
        let spread = case kind
                     of 1: 0.9
                     of 2: 0.6
                     of 3: 0.8
                     else: 0.55
        var na = ang + (float(k) - float(n - 1) / 2) * spread + (rng.rand(0.4) - 0.2)
        if kind == 2 and depth < 3: na = ang * 0.3 + PI / 2 * 0.7 + (rng.rand(0.6) - 0.3)   # (hanging)
        branch(x1, y1, na, len * (0.68 + rng.rand(0.12)), r * 0.7, depth - 1)
      if kind == 4:
        leafAt.add (x1, y1, ang)
    let x0 = bx + float(box.w) / 2
    let y0 = by + float(box.h)
    case kind
    of 1:
      # (a straight trunk, tiers of branches down it, shorter toward the top)
      o.capsule(x0, y0, x0, y0 - ht, trunkW, trunkW * 0.2, bark)
      let tiers = 9
      for t in 0 ..< tiers:
        let f = float(t) / float(tiers)
        let y = y0 - ht * (0.18 + f * 0.8)
        let reach = ht * 0.34 * (1 - f)
        for side in [-1.0, 1.0]:
          let a = (if side < 0: PI + 0.35 else: -0.35)
          branch(x0, y, a, reach * 0.55, trunkW * 0.35 * (1 - f) + 0.6, 2)
    of 4:
      var x = x0
      var y = y0
      let lean = (rng.rand(0.3) - 0.15)
      for s in 0 ..< 12:
        let nx = x + lean * ht / 12 * float(s) / 6
        let ny = y - ht * 0.8 / 12
        o.capsule(x, y, nx, ny, trunkW * (1 - float(s) / 20), trunkW * (1 - float(s + 1) / 20), bark)
        x = nx; y = ny
      for k in 0 ..< 9:
        let a = -PI / 2 + (float(k) - 4) * 0.42
        var px = x
        var py = y
        for s in 0 ..< 10:
          let fa = a + float(s) * 0.06 * (if a < -PI / 2: -1.0 else: 1.0)
          let nx = px + cos(fa) * ht * 0.035
          let ny = py + sin(fa) * ht * 0.035 + float(s) * 0.6
          o.capsule(px, py, nx, ny, 1.2, 1.0, greens[0])
          for side in [-1.0, 1.0]:
            o.capsule(nx, ny, nx + cos(fa + side * 1.2) * leafR * 2.5, ny + sin(fa + side * 1.2) * leafR * 2.5 + 2,
                      leafR * 0.3, 0.3, greens[s mod greens.len])
          px = nx; py = ny
    else:
      branch(x0, y0, -PI / 2 + (rng.rand(0.12) - 0.06), ht * 0.3, trunkW, (if kind == 3: 7 else: 6))
    if kind != 4 and kind != 3:
      let n = leafAt.len
      let keep = float(leaves) / 100
      for (x, y, a) in leafAt:
        if rng.rand(1.0) > keep: continue
        let tufts = if kind == 1: 9 else: 6
        for t in 0 ..< tufts:
          let ox = (rng.rand(2.0) - 1) * leafR * 2.2
          let oy = (rng.rand(2.0) - 1) * leafR * 2.2
          let c = greens[rng.rand(greens.high)]
          if kind == 1:
            # (needles: short dark strokes, drooping a little)
            let na = PI / 2 + (rng.rand(2.0) - 1) * 1.3
            o.capsule(x + ox, y + oy, x + ox + cos(na) * leafR * 1.8, y + oy + sin(na) * leafR * 1.8, leafR * 0.22, 0.25,
                      mix(c, 0xFF0B2A12'u32, 0.45))
          elif kind == 2:
            o.capsule(x + ox, y + oy, x + ox + (rng.rand(2.0) - 1), y + oy + leafR * 5, leafR * 0.35, 0.2, c)
          else:
            o.blob(x + ox, y + oy, leafR * (0.7 + rng.rand(0.6)), leafR * (0.45 + rng.rand(0.3)),
                   rng.rand(PI), c)
      discard n
    o

proc pictureFrame*(box: Rect; style = 0; margin = 10; size = 24; color = 0xFF6B4E2E'u32;
                   color2 = 0xFFD9B36C'u32; ornaments = 40; seed = 1): FilterFn =
  ## Render > Picture Frame: a frame drawn round `box` (document pixels), `margin` pixels in from
  ## its edges and `size` wide -- `style` 0 a wooden molding, 1 a double line, 2 beads, 3 a vine
  ## with leaves, 4 flowers, 5 a ribbon, 6 zigzag --, in `color` with `color2`, `ornaments` beads,
  ## leaves or flowers along each side.
  result = proc (src: Img; inner: Rect): Img =
    var o = src
    var rng = initRand(seed)
    let x0 = float(box.x - filterOrigin.x + margin)
    let y0 = float(box.y - filterOrigin.y + margin)
    let x1 = float(box.x - filterOrigin.x + box.w - margin)
    let y1 = float(box.y - filterOrigin.y + box.h - margin)
    let s = float(max(2, size))
    let sides = [(x0, y0, x1, y0), (x1, y0, x1, y1), (x1, y1, x0, y1), (x0, y1, x0, y0)]
    proc along(f: proc (x, y, nx, ny, t: float)) =
      for (ax, ay, bx, by) in sides:
        let L = hypot(bx - ax, by - ay)
        let n = max(2, ornaments)
        for k in 0 ..< n:
          let t = (float(k) + 0.5) / float(n)
          let nx = -(by - ay) / L
          let ny = (bx - ax) / L
          f(ax + (bx - ax) * t, ay + (by - ay) * t, nx, ny, t)
    case style
    of 0:
      # (a molding: bands from dark to light and back, mitred at the corners)
      for y in max(0, int(y0)) .. min(o.h - 1, int(y1)):
        for x in max(0, int(x0)) .. min(o.w - 1, int(x1)):
          let d = min(min(float(x) - x0, x1 - float(x)), min(float(y) - y0, y1 - float(y)))
          if d < 0 or d > s: continue
          let t = d / s
          let shade = 0.55 + 0.45 * sin(t * PI * 2.0) * 0.6 + 0.25 * sin(t * PI)
          o.over(x, y, mix(color, color2, clamp(shade, 0, 1)), 1)
    of 1:
      for k in [0.0, s * 0.7]:
        for (ax, ay, bx, by) in sides:
          let ix = if ax == bx: (if ax == x0: k else: -k) else: 0.0
          let iy = if ay == by: (if ay == y0: k else: -k) else: 0.0
          o.capsule(ax + ix, ay + iy, bx + ix, by + iy, s * 0.12, s * 0.12, color)
    of 2:
      for (ax, ay, bx, by) in sides: o.capsule(ax, ay, bx, by, s * 0.08, s * 0.08, color)
      along(proc (x, y, nx, ny, t: float) = o.blob(x, y, s * 0.3, s * 0.3, 0, color2))
    of 3:
      for (ax, ay, bx, by) in sides:
        let L = hypot(bx - ax, by - ay)
        let nx = -(by - ay) / L
        let ny = (bx - ax) / L
        let steps = int(L / 2)
        var px = ax
        var py = ay
        for k in 1 .. steps:
          let t = float(k) / float(steps)
          let wv = sin(t * float(max(2, ornaments)) * PI) * s * 0.35
          let qx = ax + (bx - ax) * t + nx * wv
          let qy = ay + (by - ay) * t + ny * wv
          o.capsule(px, py, qx, qy, s * 0.07, s * 0.07, color)
          px = qx; py = qy
      along(proc (x, y, nx, ny, t: float) =
        let side = if rng.rand(1) == 0: 1.0 else: -1.0
        o.blob(x + nx * s * 0.35 * side, y + ny * s * 0.35 * side, s * 0.28, s * 0.13, arctan2(ny, nx), color2))
    of 4:
      along(proc (x, y, nx, ny, t: float) =
        for p in 0 ..< 5:
          let a = float(p) / 5 * 2 * PI
          o.blob(x + cos(a) * s * 0.22, y + sin(a) * s * 0.22, s * 0.18, s * 0.1, a, color2)
        o.blob(x, y, s * 0.12, s * 0.12, 0, color))
    of 5:
      for y in max(0, int(y0)) .. min(o.h - 1, int(y1)):
        for x in max(0, int(x0)) .. min(o.w - 1, int(x1)):
          let d = min(min(float(x) - x0, x1 - float(x)), min(float(y) - y0, y1 - float(y)))
          if d < 0 or d > s: continue
          let stripe = (int((float(x) + float(y)) / (s * 0.5)) mod 2) == 0
          o.over(x, y, if stripe: color else: color2, 1)
    else:
      for (ax, ay, bx, by) in sides:
        let L = hypot(bx - ax, by - ay)
        let nx = -(by - ay) / L
        let ny = (bx - ax) / L
        let n = max(4, ornaments)
        var px = ax
        var py = ay
        for k in 1 .. n:
          let t = float(k) / float(n)
          let up = if k mod 2 == 1: s * 0.6 else: 0.0
          let qx = ax + (bx - ax) * t + nx * up
          let qy = ay + (by - ay) * t + ny * up
          o.capsule(px, py, qx, qy, s * 0.1, s * 0.1, color)
          px = qx; py = qy
    o

# ---- the adjustment layers named here ----------------------------------------------------------------------------

paramAdjust("Split Toning", @[adjNum("Highlights Hue:", 0, 360, 45, "°"), adjNum("Highlights Saturation:", 0, 100, 0),
                              adjNum("Balance:", -100, 100, 0), adjNum("Shadows Hue:", 0, 360, 220, "°"),
                              adjNum("Shadows Saturation:", 0, 100, 0)],
            proc (v: seq[float]): FilterFn = splitToning(v[3], v[4], v[0], v[1], v[2]))
paramAdjust("Color Grading",
            @[adjNum("Shadows Hue:", 0, 360, 220, "°"), adjNum("Shadows Saturation:", 0, 100, 0),
              adjNum("Shadows Luminance:", -100, 100, 0), adjNum("Midtones Hue:", 0, 360, 30, "°"),
              adjNum("Midtones Saturation:", 0, 100, 0), adjNum("Midtones Luminance:", -100, 100, 0),
              adjNum("Highlights Hue:", 0, 360, 45, "°"), adjNum("Highlights Saturation:", 0, 100, 0),
              adjNum("Highlights Luminance:", -100, 100, 0), adjNum("Global Hue:", 0, 360, 0, "°"),
              adjNum("Global Saturation:", 0, 100, 0), adjNum("Global Luminance:", -100, 100, 0),
              adjNum("Blending:", 0, 100, 50), adjNum("Balance:", -100, 100, 0)],
            proc (v: seq[float]): FilterFn =
              colorGrading((v[0], v[1], v[2]), (v[3], v[4], v[5]), (v[6], v[7], v[8]), v[12], v[13],
                           (v[9], v[10], v[11])))
paramAdjust("Infrared", @[adjNum("Amount:", 0, 100, 100, "%")],
            proc (v: seq[float]): FilterFn = channelInversion(2, strength = int(v[0])))

# ---- 360 pictures: a view of an equirectangular panorama, and back -------------------------------------------

proc viewDir(yaw, pitch: float; x, y, w, h, fov: float): (float, float) =
  ## (the longitude and latitude a pixel of a flat view looks at -- its middle at `yaw`, `pitch`
  ## degrees, `fov` degrees across)
  let f = float(w) / 2 / tan(degToRad(fov) / 2)
  let dx = x - float(w) / 2
  let dy = y - float(h) / 2
  # (the ray in the view's own space: z forward, x right, y down)
  var vx = dx
  var vy = dy
  var vz = f
  # (turned by the pitch round x, then by the yaw round y)
  let p = degToRad(pitch)
  let yv = vy * cos(p) - vz * sin(p)
  let zv = vy * sin(p) + vz * cos(p)
  vy = yv
  vz = zv
  let q = degToRad(yaw)
  let xv = vx * cos(q) + vz * sin(q)
  let zz = -vx * sin(q) + vz * cos(q)
  vx = xv
  vz = zz
  (arctan2(vx, vz), arctan2(vy, sqrt(vx * vx + vz * vz)))

proc equirectView*(src: Img; yaw, pitch, fov: float; w, h: int): Img =
  ## A flat view of the 360 picture `src` (equirectangular: across the whole way round, down from
  ## the top to the bottom), looking `yaw` degrees round and `pitch` up or down, `fov` degrees wide:
  ## to edit as an ordinary picture, then `equirectApply` it back.
  result = newImgUninit(w, h)
  let sw = float(src.w)
  let sh = float(src.h)
  let o = pixPtr(result.px)
  let s = src
  parallelRows(h, y):
    for x in 0 ..< w:
      let (lon, lat) = viewDir(yaw, pitch, float(x) + 0.5, float(y) + 0.5, float(w), float(h), fov)
      var u = (lon / (2 * PI) + 0.5) * sw - 0.5
      let v = (lat / PI + 0.5) * sh - 0.5
      if u < 0: u += sw
      o[y * w + x] = s.sample(u mod sw, v)

proc equirectApply*(pano: var Img; view: Img; yaw, pitch, fov: float) =
  ## The view (as `equirectView` made it, then changed) put back into the 360 picture where it looks.
  let w = view.w
  let h = view.h
  let f = float(w) / 2 / tan(degToRad(fov) / 2)
  let p = degToRad(pitch)
  let q = degToRad(yaw)
  for y in 0 ..< pano.h:
    for x in 0 ..< pano.w:
      let lon = ((float(x) + 0.5) / float(pano.w) - 0.5) * 2 * PI
      let lat = ((float(y) + 0.5) / float(pano.h) - 0.5) * PI
      # (the ray, turned back by the yaw and the pitch: where in the view it is)
      var vx = sin(lon) * cos(lat)
      var vy = sin(lat)
      var vz = cos(lon) * cos(lat)
      let xv = vx * cos(-q) + vz * sin(-q)
      let zv = -vx * sin(-q) + vz * cos(-q)
      vx = xv
      vz = zv
      let yv = vy * cos(-p) - vz * sin(-p)
      let zz = vy * sin(-p) + vz * cos(-p)
      vy = yv
      vz = zz
      if vz <= 1e-6: continue
      let sx = vx / vz * f + float(w) / 2 - 0.5
      let sy = vy / vz * f + float(h) / 2 - 0.5
      if sx < 0 or sy < 0 or sx > float(w - 1) or sy > float(h - 1): continue
      let c = view.sample(sx, sy)
      let a = float(aOf(c)) / 255
      if a <= 0: continue
      pano.px[y * pano.w + x] = if a >= 1: c else: mix(pano.px[y * pano.w + x], c or 0xFF000000'u32, a)

# ---- astrophotography: frames calibrated, lined up and stacked ------------------------------------------------

proc phaseShift*(a, b: Img): tuple[dx, dy: int] =
  ## How far `b` is moved from `a` (their pictures alike: frames of the same stars), by phase
  ## correlation on their lightness -- `b` moved by (-dx, -dy) lies on `a`.
  var n = 64
  while n * 2 <= min(a.w, a.h) and n < 1024: n *= 2
  let k = max(1, min(a.w, a.h) div n)
  proc grid(im: Img): seq[float32] =
    result = newSeq[float32](n * n)
    for y in 0 ..< n:
      for x in 0 ..< n:
        let p = im.at(x * k, y * k)
        let wy = 0.5 - 0.5 * cos(2 * PI * float(y) / float(n - 1))
        let wx = 0.5 - 0.5 * cos(2 * PI * float(x) / float(n - 1))
        result[y * n + x] = float32(float(lumaOf(p)) * wx * wy)
  var ar = grid(a)
  var ai = newSeq[float32](n * n)
  var br = grid(b)
  var bi = newSeq[float32](n * n)
  fft2(ar, ai, n)
  fft2(br, bi, n)
  for i in 0 ..< n * n:
    # (the cross-power spectrum, its size made one: what is left is the shift)
    let re = ar[i] * br[i] + ai[i] * bi[i]
    let im = ai[i] * br[i] - ar[i] * bi[i]
    let m = max(1e-9'f32, sqrt(re * re + im * im))
    ar[i] = re / m
    ai[i] = im / m
  fft2(ar, ai, n, inverse = true)
  var best = -1e30'f32
  var bx, by = 0
  for y in 0 ..< n:
    for x in 0 ..< n:
      if ar[y * n + x] > best:
        best = ar[y * n + x]
        bx = x
        by = y
  if bx > n div 2: bx -= n
  if by > n div 2: by -= n
  (-bx * k, -by * k)

proc meanOf(frames: seq[Img]): seq[float32] =
  if frames.len == 0: return
  let n = frames[0].px.len
  result = newSeq[float32](n * 3)
  for f in frames:
    if f.px.len != n: continue
    for i, p in f.px:
      result[i * 3] += float32(rOf(p))
      result[i * 3 + 1] += float32(gOf(p))
      result[i * 3 + 2] += float32(bOf(p))
  let k = 1'f32 / float32(frames.len)
  for v in result.mitems: v *= k

proc astroStack*(lights: seq[Img]; darks: seq[Img] = @[]; flats: seq[Img] = @[]; bias: seq[Img] = @[];
                 align = true; mode = 2; sigma = 2.5): Img =
  ## The frames of a night sky made one, as astrophotographers stack them: each light frame less the
  ## mean dark frame (the sensor's own glow), divided by the flat frame (dust, the lens' darker
  ## corners -- less the bias), lined up on the first (`phaseShift`), then each pixel the frames'
  ## mean (`mode` 0), median (1) or mean without those more than `sigma` deviations away (2: sigma
  ## clipping -- satellites, planes, hot pixels gone). The faint stars come out of the noise.
  if lights.len == 0: return
  let w = lights[0].w
  let h = lights[0].h
  let n = w * h
  let dark = meanOf(darks.filterIt(it.w == w and it.h == h))
  let biasM = meanOf(bias.filterIt(it.w == w and it.h == h))
  var flat = meanOf(flats.filterIt(it.w == w and it.h == h))
  if flat.len > 0:
    # (the flat less the bias, made 1 at its brightest middle)
    for i in 0 ..< flat.len:
      if biasM.len > 0: flat[i] = max(1'f32, flat[i] - biasM[i])
    var mean = 0.0
    for v in flat: mean += v
    mean /= float(flat.len)
    for v in flat.mitems: v = max(0.05'f32, v / float32(mean))
  var frames: seq[seq[float32]]
  var shifts: seq[(int, int)]
  for f in lights:
    if f.w != w or f.h != h: continue
    var c = newSeq[float32](n * 3)
    for i, p in f.px:
      for ch in 0 .. 2:
        var v = float32((p shr (16 - 8 * ch)) and 255)
        if dark.len > 0: v -= dark[i * 3 + ch]
        elif biasM.len > 0: v -= biasM[i * 3 + ch]
        if flat.len > 0: v /= flat[i * 3 + ch]
        c[i * 3 + ch] = v
    frames.add c
    shifts.add (if align and frames.len > 1: phaseShift(lights[0], f) else: (0, 0))
  result = newImgUninit(w, h)
  var vals = newSeq[float32](frames.len)
  for y in 0 ..< h:
    for x in 0 ..< w:
      var rgb: array[3, float32]
      for ch in 0 .. 2:
        var m = 0
        for k in 0 ..< frames.len:
          let sx = x + shifts[k][0]
          let sy = y + shifts[k][1]
          if sx < 0 or sy < 0 or sx >= w or sy >= h: continue
          vals[m] = frames[k][(sy * w + sx) * 3 + ch]
          inc m
        if m == 0: continue
        case mode
        of 0:
          var s = 0'f32
          for k in 0 ..< m: s += vals[k]
          rgb[ch] = s / float32(m)
        of 1:
          var v = vals[0 ..< m]
          v.sort()
          rgb[ch] = v[m div 2]
        else:
          var s, s2 = 0'f32
          for k in 0 ..< m:
            s += vals[k]
            s2 += vals[k] * vals[k]
          let mu = s / float32(m)
          let sd = sqrt(max(0'f32, s2 / float32(m) - mu * mu))
          var t = 0'f32
          var c = 0
          for k in 0 ..< m:
            if abs(vals[k] - mu) <= float32(sigma) * sd + 0.5:
              t += vals[k]
              inc c
          rgb[ch] = if c > 0: t / float32(c) else: mu
      result.px[y * w + x] = argb(255, int(rgb[0] + 0.5), int(rgb[1] + 0.5), int(rgb[2] + 0.5))

proc removeGradient*(strength = 100): FilterFn =
  ## Background Gradient Removal (astrophotography, Affinity's): the glow of the town and the moon
  ## across the sky -- a smooth slope of light and color -- found from the darker parts (not the
  ## stars) and taken away, `strength` %.
  result = proc (src: Img; inner: Rect): Img =
    let (w, h) = (src.w, src.h)
    # (a coarse grid of the background: each cell's lower quarter of lightness, the stars left out)
    let gx = 8
    let gy = 8
    var samples: seq[(float, float, array[3, float])]
    for j in 0 ..< gy:
      for i in 0 ..< gx:
        let x0 = w * i div gx
        let x1 = w * (i + 1) div gx
        let y0 = h * j div gy
        let y1 = h * (j + 1) div gy
        var ls: seq[(int, uint32)]
        for y in countup(y0, y1 - 1, max(1, (y1 - y0) div 24)):
          for x in countup(x0, x1 - 1, max(1, (x1 - x0) div 24)):
            ls.add (lumaOf(src.px[y * w + x]), src.px[y * w + x])
        if ls.len == 0: continue
        ls.sort(proc (a, b: (int, uint32)): int = cmp(a[0], b[0]))
        let q = ls[ls.len div 4][1]
        samples.add ((float(x0 + x1) / 2) / float(w), (float(y0 + y1) / 2) / float(h),
                     [float(rOf(q)), float(gOf(q)), float(bOf(q))])
    # (a quadratic surface through them, for each channel: least squares)
    proc basis(u, v: float): array[6, float] = [1.0, u, v, u * u, u * v, v * v]
    var coef: array[3, array[6, float]]
    for ch in 0 .. 2:
      var A: array[6, array[7, float]]
      for (u, v, c) in samples:
        let b = basis(u, v)
        for r in 0 .. 5:
          for k in 0 .. 5: A[r][k] += b[r] * b[k]
          A[r][6] += b[r] * c[ch]
      for col in 0 .. 5:
        var piv = col
        for r in col + 1 .. 5:
          if abs(A[r][col]) > abs(A[piv][col]): piv = r
        swap(A[col], A[piv])
        if abs(A[col][col]) < 1e-12: continue
        for r in 0 .. 5:
          if r == col: continue
          let f = A[r][col] / A[col][col]
          for k in col .. 6: A[r][k] -= f * A[col][k]
      for k in 0 .. 5: coef[ch][k] = if abs(A[k][k]) > 1e-12: A[k][6] / A[k][k] else: 0
    var lo = [1e9, 1e9, 1e9]
    for (u, v, c) in samples:
      for ch in 0 .. 2:
        let b = basis(u, v)
        var s = 0.0
        for k in 0 .. 5: s += coef[ch][k] * b[k]
        lo[ch] = min(lo[ch], s)
    var o = newImgUninit(w, h)
    let k = float(strength) / 100
    for y in 0 ..< h:
      for x in 0 ..< w:
        let b = basis(float(x) / float(w), float(y) / float(h))
        let p = src.px[y * w + x]
        var c: array[3, int]
        for ch in 0 .. 2:
          var s = 0.0
          for kk in 0 .. 5: s += coef[ch][kk] * b[kk]
          let v = float((p shr (16 - 8 * ch)) and 255) - (s - lo[ch]) * k
          c[ch] = int(round(v))
        o.px[y * w + x] = argb(aOf(p), c[0], c[1], c[2])
    o

proc heightfieldMesh*(src: Img; depth: float; step = 4): tuple[verts: seq[(float32, float32, float32)];
                                                           tris: seq[array[3, int32]]; colors: seq[uint32]] =
  ## A relief of the picture: a grid of points every `step` pixels raised by their lightness (up to
  ## `depth` pixels), two triangles a cell, each the picture's color there -- Layer to 3D.
  let cols = max(2, src.w div step)
  let rows = max(2, src.h div step)
  for j in 0 .. rows:
    for i in 0 .. cols:
      let x = min(src.w - 1, i * step)
      let y = min(src.h - 1, j * step)
      let l = float(lumaOf(src.px[y * src.w + x])) / 255
      result.verts.add (float32(x), float32(y), float32(l * depth))
  for j in 0 ..< rows:
    for i in 0 ..< cols:
      let a = int32(j * (cols + 1) + i)
      let b = a + 1
      let c = a + int32(cols + 1)
      let d = c + 1
      let p = src.px[min(src.h - 1, j * step + step div 2) * src.w + min(src.w - 1, i * step + step div 2)]
      result.tris.add [a, c, b]
      result.tris.add [b, c, d]
      result.colors.add p
      result.colors.add p
