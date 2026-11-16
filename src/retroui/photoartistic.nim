## The rest of Photoshop's Filter menu, for Retro Photo: the Filter
## Gallery (Artistic, Brush Strokes, Sketch, Texture) and Oil Paint,
## Fibers, Lighting Effects, Displace, Smart Sharpen, Plastic Wrap.
##
## Each is a `FilterFn` (see `photofx`): it takes the part of a layer with
## a margin round it and gives a picture as big. They work on all the
## cores; the painterly ones (Dry Brush, Paint Daubs, Oil Paint,
## Watercolor) are Kuwahara filters made of box sums, as quick at a large
## brush as at a small one. The Sketch filters draw in the foreground and
## background colors, as Photoshop's do (`fg`, `bg`).
##
## ```nim
## d.applyFilter(30, oilPaint(4, 6, 5, 3))
## d.applyFilter(4, charcoal(2, 3, 50, black, white))
## ```

import std/math
import gfx, photo, photofx, parallel

{.push boundChecks: off, overflowChecks: off.}

template pf(s: seq[float32]): ptr UncheckedArray[float32] =
  cast[ptr UncheckedArray[float32]](unsafeAddr s[0])
template pu(s: seq[uint32]): ptr UncheckedArray[uint32] =
  cast[ptr UncheckedArray[uint32]](unsafeAddr s[0])
template pb(s: seq[uint8]): ptr UncheckedArray[uint8] =
  cast[ptr UncheckedArray[uint8]](unsafeAddr s[0])
template pi(s: seq[int32]): ptr UncheckedArray[int32] =
  cast[ptr UncheckedArray[int32]](unsafeAddr s[0])

proc c255(v: float): int {.inline.} = clamp(int(v + 0.5), 0, 255)

proc mixc(a, b: uint32; t: float): uint32 {.inline.} =
  ## (`a` to `b` by `t`, alpha kept from `a`)
  let u = clamp(t, 0.0, 1.0)
  argb(int(aOf(a)), c255(rOf(a).float + (rOf(b).float - rOf(a).float) * u),
       c255(gOf(a).float + (gOf(b).float - gOf(a).float) * u),
       c255(bOf(a).float + (bOf(b).float - bOf(a).float) * u))

proc hash01(x, y, seed: int): float32 {.inline.} =
  ## A number 0 ..< 1 for a pixel: the same each time (noise that stays put).
  var h = uint32(x) * 374761393'u32 + uint32(y) * 668265263'u32 + uint32(seed) * 2246822519'u32
  h = (h xor (h shr 13)) * 1274126177'u32
  h = h xor (h shr 16)
  float32(h and 0xFFFFFF) / 16777216'f32

proc smoothNoise(x, y: float; cell: float; seed: int): float32 =
  ## Value noise, `cell` pixels between its points (soft blotches).
  let fx = x / cell
  let fy = y / cell
  let ix = int(floor(fx))
  let iy = int(floor(fy))
  var tx = fx - ix.float
  var ty = fy - iy.float
  tx = tx * tx * (3 - 2 * tx)
  ty = ty * ty * (3 - 2 * ty)
  let a = hash01(ix, iy, seed)
  let b = hash01(ix + 1, iy, seed)
  let c = hash01(ix, iy + 1, seed)
  let d = hash01(ix + 1, iy + 1, seed)
  float32((a + (b - a) * tx) * (1 - ty) + (c + (d - c) * tx) * ty)

proc lumPlane(im: Img): seq[float32] =
  ## The picture's lightness, 0 .. 1.
  result = newSeqUninit[float32](im.w * im.h)
  let o = pf(result)
  let s = pu(im.px)
  let w = im.w
  parallelRows(im.h, y):
    for x in 0 ..< w:
      let p = s[y * w + x]
      o[y * w + x] = float32(lumaOf(p)) / 255'f32

proc boxPassH(p: ptr UncheckedArray[float32]; w, h, r: int) =
  parallelRows(h, y):
    var line = newSeqUninit[float32](w)
    let row = y * w
    for x in 0 ..< w: line[x] = p[row + x]
    var acc = 0'f32
    for k in -r .. r: acc += line[clamp(k, 0, w - 1)]
    let n = float32(2 * r + 1)
    for x in 0 ..< w:
      p[row + x] = acc / n
      acc += line[min(x + r + 1, w - 1)] - line[max(x - r, 0)]

proc boxPassV(p: ptr UncheckedArray[float32]; w, h, r: int) =
  # (columns in bands: each band runs down the rows, kind to the cache)
  let band = 64
  parallelRows((w + band - 1) div band, b):
    let x0 = b * band
    let x1 = min(w, x0 + band)
    let bw = x1 - x0
    var acc = newSeq[float32](bw)
    var col = newSeqUninit[float32](bw * h)
    for y in 0 ..< h:
      for i in 0 ..< bw: col[y * bw + i] = p[y * w + x0 + i]
    for k in -r .. r:
      let yy = clamp(k, 0, h - 1)
      for i in 0 ..< bw: acc[i] += col[yy * bw + i]
    let n = float32(2 * r + 1)
    for y in 0 ..< h:
      let ya = min(y + r + 1, h - 1) * bw
      let yb = max(y - r, 0) * bw
      for i in 0 ..< bw:
        p[y * w + x0 + i] = acc[i] / n
        acc[i] += col[ya + i] - col[yb + i]

proc blurPlane(s: var seq[float32]; w, h: int; radius: float) =
  ## A gaussian-like blur of a plane (three box passes).
  if radius < 0.5 or s.len == 0: return
  let r = max(1, int(radius * 0.58 + 0.5))
  let p = pf(s)
  for k in 0 ..< 3:
    boxPassH(p, w, h, r)
    boxPassV(p, w, h, r)

proc gradients(l: seq[float32]; w, h: int): tuple[gx, gy: seq[float32]] =
  ## The slope of a plane (Sobel), left to right and top to bottom.
  result.gx = newSeqUninit[float32](w * h)
  result.gy = newSeqUninit[float32](w * h)
  let lp = pf(l)
  let gxp = pf(result.gx)
  let gyp = pf(result.gy)
  parallelRows(h, y):
    let y0 = max(0, y - 1) * w
    let y1 = y * w
    let y2 = min(h - 1, y + 1) * w
    for x in 0 ..< w:
      let x0 = max(0, x - 1)
      let x2 = min(w - 1, x + 1)
      gxp[y1 + x] = (lp[y0 + x2] + 2 * lp[y1 + x2] + lp[y2 + x2]) - (lp[y0 + x0] + 2 * lp[y1 + x0] + lp[y2 + x0])
      gyp[y1 + x] = (lp[y2 + x0] + 2 * lp[y2 + x] + lp[y2 + x2]) - (lp[y0 + x0] + 2 * lp[y0 + x] + lp[y0 + x2])

proc edgePlane(l: seq[float32]; w, h: int): seq[float32] =
  ## How strong an edge each pixel is on, 0 .. about 1.
  let (gx, gy) = gradients(l, w, h)
  result = newSeqUninit[float32](w * h)
  let o = pf(result)
  let a = pf(gx)
  let b = pf(gy)
  parallelRows(h, y):
    for x in 0 ..< w:
      let i = y * w + x
      o[i] = min(1'f32, sqrt(a[i] * a[i] + b[i] * b[i]) * 0.35'f32)

proc kuwahara(im: Img; r: int): Img =
  ## Each pixel the mean color of the quietest of the four squares that
  ## meet at it (`r` + 1 a side): flat strokes, sharp edges -- paint.
  let w = im.w
  let h = im.h
  result = newImgUninit(w, h)
  if w == 0 or h == 0: return
  let n = r + 1
  # the means of the (r+1) squares whose top left corner is each pixel:
  # red, green, blue, lightness and its square
  var means: array[5, seq[float32]]
  let s = pu(im.px)
  for c in 0 .. 4:
    var plane = newSeqUninit[float32](w * h)
    let pp = pf(plane)
    parallelRows(h, y):
      for x in 0 ..< w:
        let p = s[y * w + x]
        let v = case c
                of 0: float32(rOf(p))
                of 1: float32(gOf(p))
                of 2: float32(bOf(p))
                of 3: float32(lumaOf(p))
                else: (let l = float32(lumaOf(p)); l * l)
        pp[y * w + x] = v
    # (a box of n anchored at its corner: a centered box, then shifted)
    var tmp = newSeqUninit[float32](w * h)
    let tp = pf(tmp)
    parallelRows(h, y):
      var acc = 0'f32
      for k in 0 ..< n: acc += pp[y * w + min(k, w - 1)]
      for x in 0 ..< w:
        tp[y * w + x] = acc
        acc += pp[y * w + min(x + n, w - 1)] - pp[y * w + x]
    let band = 64
    let nf = float32(n * n)
    parallelRows((w + band - 1) div band, b):
      let x0 = b * band
      let x1 = min(w, x0 + band)
      var acc = newSeq[float32](x1 - x0)
      for k in 0 ..< n:
        let yy = min(k, h - 1)
        for x in x0 ..< x1: acc[x - x0] += tp[yy * w + x]
      for y in 0 ..< h:
        let ya = min(y + n, h - 1)
        for x in x0 ..< x1:
          pp[y * w + x] = acc[x - x0] / nf
          acc[x - x0] += tp[ya * w + x] - tp[y * w + x]
    means[c] = move plane
  let m0 = pf(means[0])
  let m1 = pf(means[1])
  let m2 = pf(means[2])
  let ml = pf(means[3])
  let mq = pf(means[4])
  let o = pu(result.px)
  parallelRows(h, y):
    for x in 0 ..< w:
      var best = high(float32)
      var bi = y * w + x
      for (dx, dy) in [(-r, -r), (0, -r), (-r, 0), (0, 0)]:
        let i = clamp(y + dy, 0, h - 1) * w + clamp(x + dx, 0, w - 1)
        let v = mq[i] - ml[i] * ml[i]
        if v < best:
          best = v
          bi = i
      o[y * w + x] = argb(int(aOf(s[y * w + x])), c255(m0[bi].float), c255(m1[bi].float), c255(m2[bi].float))

proc shade(l: seq[float32]; w, h: int; angle, height: float): seq[float32] =
  ## The light on a surface whose heights are `l` (0 .. 1), from `angle`
  ## degrees: 1 flat, more facing it, less facing away.
  let (gx, gy) = gradients(l, w, h)
  result = newSeqUninit[float32](w * h)
  let o = pf(result)
  let a = pf(gx)
  let b = pf(gy)
  let lx = float32(cos(degToRad(angle)))
  let ly = float32(-sin(degToRad(angle)))
  let k = float32(height)
  parallelRows(h, y):
    for x in 0 ..< w:
      let i = y * w + x
      o[i] = 1'f32 + (a[i] * lx + b[i] * ly) * k

proc lit(im: Img; s: seq[float32]; amount: float): Img =
  ## The picture under light `s` (1: as it is).
  result = newImgUninit(im.w, im.h)
  let src = pu(im.px)
  let o = pu(result.px)
  let sp = pf(s)
  let w = im.w
  let k = float32(amount)
  parallelRows(im.h, y):
    for x in 0 ..< w:
      let i = y * w + x
      let p = src[i]
      let f = 1'f32 + (sp[i] - 1'f32) * k
      let add = max(0'f32, f - 1'f32) * 60
      o[i] = argb(int(aOf(p)), c255(rOf(p).float * f + add), c255(gOf(p).float * f + add),
                  c255(bOf(p).float * f + add))

proc mapPixels(im: Img; f: proc (p: uint32; i, x, y: int): uint32 {.gcsafe.}): Img =
  result = newImgUninit(im.w, im.h)
  let s = pu(im.px)
  let o = pu(result.px)
  let w = im.w
  parallelRows(im.h, y):
    for x in 0 ..< w:
      let i = y * w + x
      o[i] = f(s[i], i, x, y)

proc posterized(v: int; levels: int): int {.inline.} =
  let n = max(2, levels)
  (v * (n - 1) + 127) div 255 * 255 div (n - 1)

proc directional(im: Img; angle: float; length: int): Img =
  ## Smeared along `angle` degrees, `length` pixels (strokes).
  motionBlur(angle, max(1, length))(im, rect(0, 0, im.w, im.h))

# ---- Artistic -----------------------------------------------------------------------------------------

proc cutout*(levels = 4; simplicity = 4; fidelity = 2): FilterFn =
  ## Artistic > Cutout: the picture as shapes cut from colored paper, in
  ## `levels` (2 .. 8) steps a channel.
  result = proc (src: Img; inner: Rect): Img =
    let sm = gaussianBlurImg(src, float(simplicity) * 0.9 + float(4 - clamp(fidelity, 1, 3)) * 0.8)
    let k = kuwahara(sm, 1 + simplicity div 3)
    let lv = clamp(levels, 2, 8)
    mapPixels(k, proc (p: uint32; i, x, y: int): uint32 =
      argb(int(aOf(p)), posterized(int(rOf(p)), lv), posterized(int(gOf(p)), lv), posterized(int(bOf(p)), lv)))

proc dryBrush*(size = 2; detail = 8; texture = 1): FilterFn =
  ## Artistic > Dry Brush: flat dabs of paint (`size` 0 .. 10), the detail
  ## kept (0 .. 10), a little texture (1 .. 3).
  result = proc (src: Img; inner: Rect): Img =
    let k = kuwahara(src, 1 + size)
    let tex = float(clamp(texture, 1, 3)) * 7
    let lv = 4 + detail
    mapPixels(k, proc (p: uint32; i, x, y: int): uint32 =
      let n = (hash01(x div 2, y div 2, 7) - 0.5) * tex
      argb(int(aOf(p)), c255(posterized(int(rOf(p)), lv).float + n), c255(posterized(int(gOf(p)), lv).float + n),
           c255(posterized(int(bOf(p)), lv).float + n)))

proc filmGrain*(grain = 4; highlight = 0; intensity = 10): FilterFn =
  ## Artistic > Film Grain: grain over the darks and mids (`grain` 0 ..
  ## 20), the lights opened (`highlight` 0 .. 20, `intensity` 0 .. 10).
  result = proc (src: Img; inner: Rect): Img =
    let g = float(grain) * 4
    let hl = float(highlight) / 20 * float(intensity) / 10
    mapPixels(src, proc (p: uint32; i, x, y: int): uint32 =
      let l = lumaOf(p).float / 255
      let n = (hash01(x, y, 11).float - 0.5) * g * (1 - l * 0.7)
      let lift = hl * max(0.0, l - 0.6) * 160
      argb(int(aOf(p)), c255(rOf(p).float + n + lift), c255(gOf(p).float + n + lift), c255(bOf(p).float + n + lift)))

proc paintDaubs*(size = 8; sharpness = 7): FilterFn =
  ## Artistic > Paint Daubs: paint laid on in dabs `size` (1 .. 50) big,
  ## sharpened (`sharpness` 0 .. 40).
  result = proc (src: Img; inner: Rect): Img =
    let k = kuwahara(src, max(1, size div 2))
    if sharpness <= 0: result = k; return
    unsharpMask(sharpness * 8, 1.5, 0)(k, rect(0, 0, k.w, k.h))

proc posterEdges*(thickness = 2; intensity = 1; posterization = 2): FilterFn =
  ## Artistic > Poster Edges: fewer colors (`posterization` 0 .. 6), the
  ## edges drawn in black (`thickness` 0 .. 10, `intensity` 0 .. 10).
  result = proc (src: Img; inner: Rect): Img =
    var e = edgePlane(lumPlane(src), src.w, src.h)
    blurPlane(e, src.w, src.h, float(thickness) * 0.4)
    let ep = pf(e)
    let lv = 2 + posterization
    let k = float(intensity) * 0.35 + 0.4
    mapPixels(src, proc (p: uint32; i, x, y: int): uint32 =
      let dark = clamp(1 - ep[i] * k * 2.2, 0.0, 1.0)
      argb(int(aOf(p)), c255(posterized(int(rOf(p)), lv).float * dark),
           c255(posterized(int(gOf(p)), lv).float * dark), c255(posterized(int(bOf(p)), lv).float * dark)))

proc watercolor*(detail = 9; shadow = 1; texture = 1): FilterFn =
  ## Artistic > Watercolor: washes of color (`detail` 1 .. 14), their
  ## edges darker where they dry (`shadow` 0 .. 10), on paper.
  result = proc (src: Img; inner: Rect): Img =
    let soft = gaussianBlurImg(src, float(15 - clamp(detail, 1, 14)) * 0.5)
    let k = kuwahara(soft, 2 + (14 - clamp(detail, 1, 14)) div 3)
    var e = edgePlane(lumPlane(k), k.w, k.h)
    blurPlane(e, k.w, k.h, 1.2)
    let ep = pf(e)
    let sh = float(shadow) * 0.09 + 0.15
    let tex = float(clamp(texture, 1, 3)) * 5
    mapPixels(k, proc (p: uint32; i, x, y: int): uint32 =
      let paper = (smoothNoise(x.float, y.float, 3, 5) - 0.5) * tex
      let d = 1 - ep[i] * sh * 2
      # (pigment: the colors a little richer than the photo's)
      let l = lumaOf(p).float
      let r = l + (rOf(p).float - l) * 1.15
      let g = l + (gOf(p).float - l) * 1.15
      let b = l + (bOf(p).float - l) * 1.15
      argb(int(aOf(p)), c255(r * d + paper), c255(g * d + paper), c255(b * d + paper)))

proc sponge*(size = 2; definition = 12; smoothness = 5): FilterFn =
  ## Artistic > Sponge: color dabbed on with a sponge -- blotches of light
  ## and dark (`size` 0 .. 10, `definition` 0 .. 25, `smoothness` 1 .. 15).
  result = proc (src: Img; inner: Rect): Img =
    let k = kuwahara(src, 1 + size)
    let cell = 2.0 + float(smoothness) * 0.5
    let amp = float(definition) * 3
    mapPixels(k, proc (p: uint32; i, x, y: int): uint32 =
      let n = (smoothNoise(x.float, y.float, cell, 23) - 0.5) * amp
      argb(int(aOf(p)), c255(rOf(p).float + n), c255(gOf(p).float + n), c255(bOf(p).float + n)))

proc coloredPencil*(width = 4; pressure = 8; paper = 25; paperColor = 0xFFFFFFFF'u32): FilterFn =
  ## Artistic > Colored Pencil: the picture hatched in pencil (`width` 1 ..
  ## 24, `pressure` 0 .. 15) on paper (`paper` 0 .. 50 its brightness).
  result = proc (src: Img; inner: Rect): Img =
    let soft = gaussianBlurImg(src, float(width) * 0.3)
    let strokes = directional(soft, 45, 2 + width)
    let pr = float(pressure) / 15
    let pb = float(paper) / 50
    mapPixels(strokes, proc (p: uint32; i, x, y: int): uint32 =
      let n = hash01((x + y) div max(1, width div 2), (x - y) div 7, 3).float
      let cover = clamp((1 - lumaOf(p).float / 255) * (0.55 + pr * 0.9) + (n - 0.5) * 0.5, 0.0, 1.0)
      let base = mixc(paperColor, 0xFF000000'u32, (1 - pb) * 0.35)
      mixc(base, p, cover) and 0x00FFFFFF'u32 or (aOf(p).uint32 shl 24))

proc plasticWrap*(highlight = 15; detail = 9; smoothness = 7): FilterFn =
  ## Artistic > Plastic Wrap: the picture under shiny film, its lights
  ## where the surface bends (`highlight` 0 .. 20, `detail` 1 .. 15,
  ## `smoothness` 1 .. 15).
  result = proc (src: Img; inner: Rect): Img =
    var l = lumPlane(src)
    blurPlane(l, src.w, src.h, float(smoothness) * 0.6 + float(16 - detail) * 0.3)
    let s = shade(l, src.w, src.h, 135, 6)
    let sp = pf(s)
    let k = float(highlight) / 20
    mapPixels(src, proc (p: uint32; i, x, y: int): uint32 =
      let shine = pow(clamp(sp[i] - 1.0, 0.0, 1.0), 1.6) * k * 255
      argb(int(aOf(p)), c255(rOf(p).float * 0.85 + shine), c255(gOf(p).float * 0.85 + shine),
           c255(bOf(p).float * 0.85 + shine)))

# ---- Brush Strokes ---------------------------------------------------------------------------------

proc accentedEdges*(width = 2; brightness = 38; smoothness = 5): FilterFn =
  ## Brush Strokes > Accented Edges: the edges traced in light (or dark,
  ## `brightness` 0 .. 50 under 25), `width` 1 .. 14.
  result = proc (src: Img; inner: Rect): Img =
    var e = edgePlane(lumPlane(src), src.w, src.h)
    blurPlane(e, src.w, src.h, float(width) * 0.4 + float(smoothness) * 0.15)
    let ep = pf(e)
    let k = (float(brightness) - 25) / 25 * 255
    mapPixels(src, proc (p: uint32; i, x, y: int): uint32 =
      let a = min(1.0, ep[i].float * 2.5) * k
      argb(int(aOf(p)), c255(rOf(p).float + a), c255(gOf(p).float + a), c255(bOf(p).float + a)))

proc angledStrokes*(balance = 50; length = 15; sharpness = 3): FilterFn =
  ## Brush Strokes > Angled Strokes: the lights stroked one way, the darks
  ## the other (`balance` 0 .. 100), `length` 3 .. 50.
  result = proc (src: Img; inner: Rect): Img =
    let a = directional(src, 45, length)
    let b = directional(src, -45, length)
    let ap = pu(a.px)
    let bp = pu(b.px)
    let t = float(balance) / 100
    let sh = float(sharpness) * 6
    mapPixels(src, proc (p: uint32; i, x, y: int): uint32 =
      let l = lumaOf(p).float / 255
      let q = if l > 1 - t: ap[i] else: bp[i]
      let n = (hash01(x, y, 5).float - 0.5) * sh
      argb(int(aOf(p)), c255(rOf(q).float + n), c255(gOf(q).float + n), c255(bOf(q).float + n)))

proc crosshatch*(length = 9; sharpness = 6; strength = 1): FilterFn =
  ## Brush Strokes > Crosshatch: pencil hatching both ways over the
  ## picture's colors (`length` 3 .. 50, `sharpness` 0 .. 20,
  ## `strength` 1 .. 3).
  result = proc (src: Img; inner: Rect): Img =
    let a = directional(src, 45, length)
    let b = directional(src, -45, length)
    let ap = pu(a.px)
    let bp = pu(b.px)
    let k = float(clamp(strength, 1, 3)) * 14 + float(sharpness) * 2
    mapPixels(src, proc (p: uint32; i, x, y: int): uint32 =
      let h1 = (hash01((x + y) div 3, 0, 9).float - 0.5)
      let h2 = (hash01((x - y + 100000) div 3, 1, 9).float - 0.5)
      let q = mixc(ap[i], bp[i], 0.5)
      let n = (h1 + h2) * k
      argb(int(aOf(p)), c255(rOf(q).float + n), c255(gOf(q).float + n), c255(bOf(q).float + n)))

proc inkOutlines*(length = 4; dark = 20; light = 10): FilterFn =
  ## Brush Strokes > Ink Outlines: the picture redrawn with fine lines of
  ## ink over its edges (`length` 1 .. 50, `dark` 0 .. 50, `light` 0 .. 50).
  result = proc (src: Img; inner: Rect): Img =
    let s = directional(src, 45, length)
    var e = edgePlane(lumPlane(src), src.w, src.h)
    let ep = pf(e)
    let sp = pu(s.px)
    let dk = float(dark) / 50
    let lt = float(light) / 50
    mapPixels(src, proc (p: uint32; i, x, y: int): uint32 =
      let q = sp[i]
      let l = lumaOf(q).float / 255
      var f = 1 - ep[i] * dk * 2.5
      f += (l - 0.5) * lt * 0.6
      argb(int(aOf(p)), c255(rOf(q).float * f), c255(gOf(q).float * f), c255(bOf(q).float * f)))

proc spatter*(radius = 10; smoothness = 5): FilterFn =
  ## Brush Strokes > Spatter: as if sprayed with an airbrush -- each pixel
  ## from up to `radius` (0 .. 25) pixels away (`smoothness` 1 .. 15).
  result = proc (src: Img; inner: Rect): Img =
    var res = newImgUninit(src.w, src.h)
    let o = pu(res.px)
    let r = float(radius)
    let cell = 1.0 + float(smoothness) * 0.35
    let w = src.w
    let h = src.h
    let sp = pu(src.px)
    parallelRows(h, y):
      for x in 0 ..< w:
        let dx = (smoothNoise(x.float, y.float, cell, 31) - 0.5) * 2 * r
        let dy = (smoothNoise(x.float, y.float, cell, 37) - 0.5) * 2 * r
        o[y * w + x] = sp[clamp(y + int(dy), 0, h - 1) * w + clamp(x + int(dx), 0, w - 1)]
    res

proc sumiE*(width = 10; pressure = 2; contrast = 16): FilterFn =
  ## Brush Strokes > Sumi-e: Japanese ink on rice paper: soft, rich blacks
  ## (`width` 3 .. 15, `pressure` 0 .. 15, `contrast` 0 .. 40).
  result = proc (src: Img; inner: Rect): Img =
    let soft = gaussianBlurImg(src, float(width) * 0.25)
    let k = kuwahara(soft, 1 + width div 5)
    let ct = 1 + float(contrast) / 25
    let pr = float(pressure) * 4
    mapPixels(k, proc (p: uint32; i, x, y: int): uint32 =
      let l = lumaOf(p).float
      let f = clamp(((l - 128) * ct + 128 - pr) / max(1.0, l), 0.0, 2.0)
      argb(int(aOf(p)), c255(rOf(p).float * f), c255(gOf(p).float * f), c255(bOf(p).float * f)))

# ---- Sketch (in the foreground and background colors) ------------------------------------------------

proc twoTone(src: Img; v: seq[float32]; fg, bg: uint32): Img =
  ## (`v` 0: the foreground color, 1: the background, between: mixed)
  let vp = pf(v)
  mapPixels(src, proc (p: uint32; i, x, y: int): uint32 =
    (mixc(fg, bg, vp[i].float) and 0x00FFFFFF'u32) or (aOf(p).uint32 shl 24))

proc charcoal*(thickness = 1; detail = 5; balance = 50; fg = 0xFF000000'u32; bg = 0xFFFFFFFF'u32): FilterFn =
  ## Sketch > Charcoal: smudged charcoal strokes (the foreground color) on
  ## paper (the background), `thickness` 1 .. 7, `detail` 0 .. 5,
  ## `balance` 0 .. 100.
  result = proc (src: Img; inner: Rect): Img =
    let s = directional(src, 45, 2 + thickness * 2)
    var l = lumPlane(s)
    let e = edgePlane(lumPlane(src), src.w, src.h)
    let lp = pf(l)
    let ep = pf(e)
    let t = float32(balance) / 100
    let dt = float32(detail) / 5
    parallelRows(src.h, y):
      for x in 0 ..< src.w:
        let i = y * src.w + x
        let n = hash01((x + y) div (1 + thickness), (x - y) div 9, 13) - 0.5'f32
        lp[i] = clamp((lp[i] - (1 - t)) * 3'f32 + 0.5'f32 + n * 0.5'f32 - ep[i] * dt, 0'f32, 1'f32)
    twoTone(src, l, fg, bg)

proc pencilSketch*(width = 8; darkness = 50; colored = 0; fg = 0xFF000000'u32; bg = 0xFFFFFFFF'u32): FilterFn =
  ## Sketch > Pencil Sketch: the picture as drawn with a pencil -- its edges
  ## and shading as strokes (the foreground color) on paper (the
  ## background): the lightness divided by its blurred negative, as a
  ## dodge. `width` 1 .. 40: how broad the strokes are; `darkness` 0 .. 100;
  ## `colored` 0 .. 100: the picture's own colors kept in its strokes.
  result = proc (src: Img; inner: Rect): Img =
    let w = src.w
    let l = lumPlane(src)
    var inv = newSeqUninit[float32](l.len)
    let lp = pf(l)
    let ip = pf(inv)
    for i in 0 ..< l.len: ip[i] = 1'f32 - lp[i]
    blurPlane(inv, w, src.h, max(0.5, width.float))
    let ip2 = pf(inv)
    let g = 1'f32 + float32(darkness) / 25'f32          # (how far the strokes are deepened)
    var v = newSeqUninit[float32](l.len)
    let vp = pf(v)
    parallelRows(src.h, y):
      for x in 0 ..< w:
        let i = y * w + x
        # (a color dodge of the lightness by its blurred negative: flat areas go to paper,
        # where it changes a line is left)
        let d = min(1'f32, lp[i] / max(0.001'f32, 1'f32 - ip2[i]))
        vp[i] = pow(d, g)
    if colored <= 0:
      twoTone(src, v, fg, bg)
    else:
      let k = float32(colored) / 100'f32
      let s = pu(src.px)
      mapPixels(src, proc (p: uint32; i, x, y: int): uint32 =
        let t = vp[i]
        let gray = mixc(fg, bg, t.float)
        # (the picture's own color, lightened as the paper shows through)
        let c = s[i]
        let own = mixc(c, bg, t.float * 0.85)
        (mixc(gray, own, k.float) and 0x00FFFFFF'u32) or (aOf(p).uint32 shl 24))

proc graphicPen*(length = 15; balance = 50; direction = 0; fg = 0xFF000000'u32; bg = 0xFFFFFFFF'u32): FilterFn =
  ## Sketch > Graphic Pen: fine straight ink strokes (the foreground color)
  ## along a direction (0 right diagonal, 1 left, 2 across, 3 down).
  result = proc (src: Img; inner: Rect): Img =
    var l = lumPlane(src)
    let lp = pf(l)
    let t = float32(balance) / 100
    let ln = max(1, length)
    parallelRows(src.h, y):
      for x in 0 ..< src.w:
        let i = y * src.w + x
        let (a, b) = case direction
                     of 1: (x - y + 1_000_000, (x + y) div ln)
                     of 2: (y, x div ln)
                     of 3: (x, y div ln)
                     else: (x + y, (x - y + 1_000_000) div ln)
        let n = hash01(a, b, 41)
        lp[i] = if lp[i] + (t - 0.5'f32) > n: 1'f32 else: 0'f32
    twoTone(src, l, fg, bg)

proc halftonePattern*(size = 1; contrast = 5; kind = 0; fg = 0xFF000000'u32; bg = 0xFFFFFFFF'u32): FilterFn =
  ## Sketch > Halftone Pattern: a screen of dots, circles or lines
  ## (`kind` 0, 1, 2) in the two colors (`size` 1 .. 12, `contrast` 0 .. 50).
  result = proc (src: Img; inner: Rect): Img =
    var l = lumPlane(src)
    let lp = pf(l)
    let cell = float32(3 + size * 2)
    let ct = 1 + float32(contrast) / 10
    parallelRows(src.h, y):
      for x in 0 ..< src.w:
        let i = y * src.w + x
        let u = (x.float32 mod cell) / cell - 0.5'f32
        let v = (y.float32 mod cell) / cell - 0.5'f32
        let screen = case kind
                     of 1: abs(sqrt(float32(x * x + y * y)) mod cell / cell - 0.5'f32) * 2
                     of 2: abs(v) * 2
                     else: sqrt(u * u + v * v) * 1.41'f32
        lp[i] = clamp((lp[i] - screen) * ct * 4 + 0.5'f32, 0'f32, 1'f32)
    twoTone(src, l, fg, bg)

proc photocopy*(detail = 7; darkness = 8; fg = 0xFF000000'u32; bg = 0xFFFFFFFF'u32): FilterFn =
  ## Sketch > Photocopy: the edges and darks as a copier keeps them
  ## (`detail` 1 .. 24, `darkness` 1 .. 50).
  result = proc (src: Img; inner: Rect): Img =
    var l = lumPlane(src)
    var b = l
    blurPlane(b, src.w, src.h, 26 - float(clamp(detail, 1, 24)))
    let lp = pf(l)
    let bp = pf(b)
    let k = float32(darkness) * 0.6'f32
    parallelRows(src.h, y):
      for x in 0 ..< src.w:
        let i = y * src.w + x
        lp[i] = clamp(1 + (lp[i] - bp[i]) * k, 0'f32, 1'f32)
    twoTone(src, l, fg, bg)

proc stamp*(balance = 25; smoothness = 5; fg = 0xFF000000'u32; bg = 0xFFFFFFFF'u32): FilterFn =
  ## Sketch > Stamp: as a rubber or wood stamp prints it (`balance` 0 ..
  ## 50 light and dark, `smoothness` 1 .. 50).
  result = proc (src: Img; inner: Rect): Img =
    var l = lumPlane(src)
    blurPlane(l, src.w, src.h, float(smoothness) * 0.3)
    let lp = pf(l)
    let t = float32(balance) / 50
    parallelRows(src.h, y):
      for x in 0 ..< src.w:
        let i = y * src.w + x
        lp[i] = clamp((lp[i] - (1 - t)) * 12 + 0.5'f32, 0'f32, 1'f32)
    twoTone(src, l, fg, bg)

proc basRelief*(detail = 13; smoothness = 3; angle = 135.0; fg = 0xFF000000'u32; bg = 0xFFFFFFFF'u32): FilterFn =
  ## Sketch > Bas Relief: carved in low relief, lit from `angle` degrees
  ## (`detail` 1 .. 15, `smoothness` 1 .. 15).
  result = proc (src: Img; inner: Rect): Img =
    var l = lumPlane(src)
    blurPlane(l, src.w, src.h, float(smoothness) * 0.5 + float(16 - detail) * 0.2)
    var s = shade(l, src.w, src.h, angle, 2.5)
    let sp = pf(s)
    parallelRows(src.h, y):
      for x in 0 ..< src.w:
        let i = y * src.w + x
        sp[i] = clamp(sp[i] - 0.5'f32, 0'f32, 1'f32)
    twoTone(src, s, fg, bg)

proc chrome*(detail = 4; smoothness = 7): FilterFn =
  ## Sketch > Chrome: polished metal; the lights and darks of the picture
  ## made bands of reflection (`detail` 0 .. 10, `smoothness` 0 .. 10).
  result = proc (src: Img; inner: Rect): Img =
    var l = lumPlane(src)
    blurPlane(l, src.w, src.h, float(smoothness) * 0.8 + float(10 - detail) * 0.3 + 0.5)
    let lp = pf(l)
    mapPixels(src, proc (p: uint32; i, x, y: int): uint32 =
      let v = 0.5 + 0.5 * sin(lp[i].float * PI * 3.2 - 1.2)
      let g = c255(v * 255)
      argb(int(aOf(p)), g, g, g))

proc tornEdges*(balance = 25; smoothness = 11; contrast = 17; fg = 0xFF000000'u32; bg = 0xFFFFFFFF'u32): FilterFn =
  ## Sketch > Torn Edges: as torn pieces of paper, ragged at their edges.
  result = proc (src: Img; inner: Rect): Img =
    var l = lumPlane(src)
    blurPlane(l, src.w, src.h, float(smoothness) * 0.25)
    let lp = pf(l)
    let t = float32(balance) / 50
    let ct = float32(contrast)
    parallelRows(src.h, y):
      for x in 0 ..< src.w:
        let i = y * src.w + x
        let n = (hash01(x, y, 47) - 0.5'f32) * 0.18'f32
        lp[i] = clamp((lp[i] + n - (1 - t)) * ct + 0.5'f32, 0'f32, 1'f32)
    twoTone(src, l, fg, bg)

proc reticulation*(density = 12; fgLevel = 40; bgLevel = 5; fg = 0xFF000000'u32; bg = 0xFFFFFFFF'u32): FilterFn =
  ## Sketch > Reticulation: the emulsion shrunk and puckered -- clumps in
  ## the darks, grain in the lights (`density` 0 .. 50).
  result = proc (src: Img; inner: Rect): Img =
    var l = lumPlane(src)
    let lp = pf(l)
    let dn = float32(density) / 50
    let fl = float32(fgLevel) / 50
    let bl = float32(bgLevel) / 50
    parallelRows(src.h, y):
      for x in 0 ..< src.w:
        let i = y * src.w + x
        let n = smoothNoise(x.float, y.float, 1.6, 53) * 0.6'f32 + hash01(x, y, 59) * 0.4'f32
        lp[i] = clamp((lp[i] - 0.5'f32) * (1 + fl) + (n - 0.5'f32) * dn * 1.6'f32 + 0.5'f32 + bl * 0.2'f32,
                      0'f32, 1'f32)
    twoTone(src, l, fg, bg)

# ---- Texture ------------------------------------------------------------------------------------------

proc voronoi(x, y: float; cell: float; seed: int): tuple[id: int; d1, d2: float; cx, cy: float] =
  ## The nearest of points scattered one a cell: which, how far, how far
  ## the second nearest (their difference: near 0 on a border).
  let gx = int(floor(x / cell))
  let gy = int(floor(y / cell))
  result.d1 = 1e18
  result.d2 = 1e18
  for j in -1 .. 1:
    for i in -1 .. 1:
      let cx = gx + i
      let cy = gy + j
      let px = (cx.float + hash01(cx, cy, seed).float * 0.9 + 0.05) * cell
      let py = (cy.float + hash01(cx, cy, seed + 1).float * 0.9 + 0.05) * cell
      let d = hypot(x - px, y - py)
      if d < result.d1:
        result.d2 = result.d1
        result.d1 = d
        result.id = cx * 73856093 xor cy * 19349663
        result.cx = px
        result.cy = py
      elif d < result.d2: result.d2 = d

proc craquelure*(spacing = 15; depth = 6; brightness = 9): FilterFn =
  ## Texture > Craquelure: the picture as on old plaster, finely cracked
  ## (`spacing` 2 .. 100, `depth` 0 .. 10, `brightness` 0 .. 10).
  result = proc (src: Img; inner: Rect): Img =
    let cell = float(max(2, spacing))
    let dk = float(depth) / 10
    let br = (float(brightness) - 5) * 6
    mapPixels(src, proc (p: uint32; i, x, y: int): uint32 =
      let v = voronoi(x.float, y.float, cell, 61)
      let crack = clamp(1 - (v.d2 - v.d1) / 2.2, 0.0, 1.0)
      let f = 1 - crack * dk * 0.8
      argb(int(aOf(p)), c255(rOf(p).float * f + br), c255(gOf(p).float * f + br), c255(bOf(p).float * f + br)))

type GrainKind* = enum
  ## Texture > Grain's kinds.
  gkRegular = "Regular", gkSoft = "Soft", gkSprinkles = "Sprinkles", gkClumped = "Clumped",
  gkContrasty = "Contrasty", gkEnlarged = "Enlarged", gkStippled = "Stippled",
  gkHorizontal = "Horizontal", gkVertical = "Vertical", gkSpeckle = "Speckle"

proc grainTexture*(intensity = 40; contrast = 50; kind = gkRegular): FilterFn =
  ## Texture > Grain: grain of ten kinds (`intensity` 0 .. 100, `contrast`
  ## 0 .. 100).
  result = proc (src: Img; inner: Rect): Img =
    let it = float(intensity) / 100 * 120
    let ct = 0.5 + float(contrast) / 100
    mapPixels(src, proc (p: uint32; i, x, y: int): uint32 =
      let n = case kind
              of gkSoft: smoothNoise(x.float, y.float, 1.5, 3).float - 0.5
              of gkSprinkles: (if hash01(x, y, 3) > 0.93: 0.5 else: 0.0)
              of gkClumped: smoothNoise(x.float, y.float, 3, 4).float - 0.5
              of gkContrasty: (if hash01(x, y, 5) > 0.5: 0.5 else: -0.5)
              of gkEnlarged: smoothNoise(x.float, y.float, 6, 6).float - 0.5
              of gkStippled: (if hash01(x, y, 7) > 0.92: -0.5 else: 0.0)
              of gkHorizontal: hash01(0, y, 8).float - 0.5
              of gkVertical: hash01(x, 0, 9).float - 0.5
              of gkSpeckle: (if hash01(x, y, 10) > 0.96: 0.5 elif hash01(x, y, 11) > 0.96: -0.5 else: 0.0)
              else: hash01(x, y, 2).float - 0.5
      let a = n * it
      let l = lumaOf(p).float
      let f = ct
      argb(int(aOf(p)), c255((rOf(p).float - l) + (l - 128) * f + 128 + a),
           c255((gOf(p).float - l) + (l - 128) * f + 128 + a), c255((bOf(p).float - l) + (l - 128) * f + 128 + a)))

proc mosaicTiles*(size = 12; grout = 3; lighten = 9): FilterFn =
  ## Texture > Mosaic Tiles: the picture on small tiles with grout between
  ## (`size` 2 .. 100, `grout` 1 .. 15, `lighten` 0 .. 10).
  result = proc (src: Img; inner: Rect): Img =
    let cell = float(max(2, size))
    let gw = float(clamp(grout, 1, 15)) * 0.5
    let lt = float(lighten) / 10
    mapPixels(src, proc (p: uint32; i, x, y: int): uint32 =
      let v = voronoi(x.float, y.float, cell, 67)
      let edge = v.d2 - v.d1
      if edge < gw:
        # (the grout: gray, lightened as asked)
        (mixc(0xFF606060'u32, 0xFFFFFFFF'u32, lt * 0.8) and 0x00FFFFFF'u32) or (aOf(p).uint32 shl 24)
      else:
        let bevel = clamp((edge - gw) / 2.5, 0.0, 1.0)
        mixc(p, 0xFF000000'u32, (1 - bevel) * 0.25))

proc patchwork*(size = 4; relief = 8): FilterFn =
  ## Texture > Patchwork: squares of the picture's colors, raised
  ## (`size` 0 .. 10, `relief` 0 .. 25).
  result = proc (src: Img; inner: Rect): Img =
    let cell = 3 + size * 2
    let rf = float(relief) / 25
    let sp = pu(src.px)
    let w = src.w
    let h = src.h
    mapPixels(src, proc (p: uint32; i, x, y: int): uint32 =
      let cx = min(w - 1, (x div cell) * cell + cell div 2)
      let cy = min(h - 1, (y div cell) * cell + cell div 2)
      let q = sp[cy * w + cx]
      let u = x mod cell
      let v = y mod cell
      let f = if u == 0 or v == 0: 1 + rf * 0.5
              elif u == cell - 1 or v == cell - 1: 1 - rf * 0.6
              else: 1.0 + (hash01(x div cell, y div cell, 71).float - 0.5) * rf * 0.3
      argb(int(aOf(p)), c255(rOf(q).float * f), c255(gOf(q).float * f), c255(bOf(q).float * f)))

proc stainedGlass*(cellSize = 10; border = 4; light = 3; lead = 0xFF000000'u32): FilterFn =
  ## Texture > Stained Glass: cells of one color each, leaded (the
  ## foreground color) between them, lit from the middle (`cellSize` 2 ..
  ## 50, `border` 1 .. 20, `light` 0 .. 10).
  result = proc (src: Img; inner: Rect): Img =
    let cell = float(max(2, cellSize)) * 1.6
    let bw = float(clamp(border, 1, 20)) * 0.5
    let lt = float(light) / 10
    let sp = pu(src.px)
    let w = src.w
    let h = src.h
    let cx0 = w.float / 2
    let cy0 = h.float / 2
    let far = max(1.0, hypot(cx0, cy0))
    mapPixels(src, proc (p: uint32; i, x, y: int): uint32 =
      let v = voronoi(x.float, y.float, cell, 79)
      if v.d2 - v.d1 < bw: result = (lead and 0x00FFFFFF'u32) or (aOf(p).uint32 shl 24); return
      let q = sp[clamp(int(v.cy), 0, h - 1) * w + clamp(int(v.cx), 0, w - 1)]
      let glow = (1 - hypot(x.float - cx0, y.float - cy0) / far) * lt * 60
      argb(int(aOf(p)), c255(rOf(q).float + glow), c255(gOf(q).float + glow), c255(bOf(q).float + glow)))

type TextureKind* = enum
  ## Texture > Texturizer's textures.
  tkCanvas = "Canvas", tkBrick = "Brick", tkBurlap = "Burlap", tkSandstone = "Sandstone"

proc textureHeight(kind: TextureKind; scaling, w, h: int): seq[float32] =
  ## The heights of a texture (0 .. 1) over a picture `w` x `h`, `scaling` 50 .. 200 %.
  let k = float(clamp(scaling, 50, 200)) / 100
  result = newSeqUninit[float32](w * h)
  let hp = pf(result)
  parallelRows(h, y):
    for x in 0 ..< w:
      let fx = x.float / k
      let fy = y.float / k
      let v = case kind
              of tkBrick:
                let row = int(fy / 18)
                let bx = (fx + (if row mod 2 == 1: 21.0 else: 0.0)) mod 42
                let by = fy mod 18
                (if bx < 2 or by < 2: 0.0 else: 0.8 + smoothNoise(fx, fy, 4, 83).float * 0.2)
              of tkBurlap:
                let a = sin(fx * 1.1) * 0.5 + 0.5
                let b = sin(fy * 1.1) * 0.5 + 0.5
                (if (int(fx / 3) + int(fy / 3)) mod 2 == 0: a else: b) * 0.7 + hash01(int(fx), int(fy), 89).float * 0.3
              of tkSandstone:
                smoothNoise(fx, fy, 2, 97).float * 0.5 + hash01(int(fx), int(fy), 101).float * 0.5
              else:
                let a = sin(fx * 1.6) * 0.5 + 0.5
                let b = sin(fy * 1.6) * 0.5 + 0.5
                (if (int(fx / 2) + int(fy / 2)) mod 2 == 0: a else: b) * 0.85 + hash01(int(fx), int(fy), 103).float * 0.15
      hp[y * w + x] = float32(v)

proc texturizer*(kind = tkCanvas; scaling = 100; relief = 4; angle = 135.0): FilterFn =
  ## Texture > Texturizer: the picture on canvas, brick, burlap or
  ## sandstone, lit from `angle` degrees (`scaling` 50 .. 200 %,
  ## `relief` 0 .. 50).
  result = proc (src: Img; inner: Rect): Img =
    let hgt = textureHeight(kind, scaling, src.w, src.h)
    let s = shade(hgt, src.w, src.h, angle, float(relief) / 50 * 3)
    lit(src, s, 1.0)

# ---- the rest of the Filter menu ---------------------------------------------------------------------

proc oilPaint*(stylization = 4.0; cleanliness = 6.0; scale = 5.0; bristle = 3.0; angle = 135.0;
               shine = 3.0): FilterFn =
  ## Filter > Stylize > Oil Paint: the picture painted in thick oils --
  ## strokes as big as `stylization` (0.1 .. 10) and `cleanliness`
  ## (0 .. 10) make them, their ridges (`scale`, `bristle` 0 .. 10) lit
  ## from `angle` degrees (`shine` 0 .. 10).
  result = proc (src: Img; inner: Rect): Img =
    let r = max(1, int(stylization * 0.9 + cleanliness * 0.35))
    var k = kuwahara(src, r)
    if cleanliness > 5: k = kuwahara(k, max(1, r div 2))
    var hgt = lumPlane(k)
    let hp = pf(hgt)
    let w = k.w
    let bs = float32(bristle) / 10 * 0.15'f32
    parallelRows(k.h, y):
      for x in 0 ..< w:
        hp[y * w + x] += (hash01((x + y) div 2, (x - y) div 6, 107) - 0.5'f32) * bs
    blurPlane(hgt, k.w, k.h, scale * 0.2)
    let s = shade(hgt, k.w, k.h, angle, 1.5 + scale * 0.3)
    lit(k, s, shine / 10 + 0.2)

proc fibers*(variance = 16; strength = 4; fg = 0xFF000000'u32; bg = 0xFFFFFFFF'u32; seed = 1): FilterFn =
  ## Filter > Render > Fibers: woven fibers in the foreground and
  ## background colors (`variance` 1 .. 64: how the colors vary along a
  ## fiber; `strength` 1 .. 64: how long the fibers are).
  result = proc (src: Img; inner: Rect): Img =
    var v = newSeqUninit[float32](src.w * src.h)
    let vp = pf(v)
    let w = src.w
    let along = float(max(1, strength)) * 6
    let across = 2.2
    parallelRows(src.h, y):
      for x in 0 ..< w:
        var n = 0.0
        var amp = 1.0
        var cell = float(max(1, 65 - variance)) / 8 + 1
        for o in 0 ..< 3:
          n += (smoothNoise(x.float / across * cell / 4, y.float / along * cell / 4, 1, seed + o).float - 0.5) * amp
          amp *= 0.5
          cell *= 2
        vp[y * w + x] = float32(clamp(n * 1.4 + 0.5, 0.0, 1.0))
    twoTone(src, v, fg, bg)

type LightKind* = enum
  ## Lighting Effects' lights.
  lkSpot = "Spot", lkPoint = "Point", lkInfinite = "Infinite"

proc lightingEffects*(kind = lkSpot; x = 0.5; y = 0.4; intensity = 35; ambience = 8; angle = 135.0;
                      height = 0; color = 0xFFFFFFFF'u32): FilterFn =
  ## Filter > Render > Lighting Effects: a light (a spot, a bulb or the
  ## sun) on the picture -- at `x`, `y` (0 .. 1 of it), `intensity` -100 ..
  ## 100, `ambience` -100 .. 100; `height` 0 .. 100: the picture's lights
  ## raised as a relief.
  result = proc (src: Img; inner: Rect): Img =
    let w = src.w
    let h = src.h
    var bump: seq[float32]
    if height > 0:
      var l = lumPlane(src)
      blurPlane(l, w, h, 1.0)
      bump = shade(l, w, h, angle, float(height) / 25)
    let bp = if bump.len > 0: pf(bump) else: nil
    let lx = x * w.float
    let ly = y * h.float
    let reach = max(w, h).float * 0.6
    let it = float(intensity) / 100 * 1.6
    let amb = 0.35 + float(ambience) / 100 * 0.35
    let dx = cos(degToRad(angle))
    let dy = -sin(degToRad(angle))
    let lr = rOf(color).float / 255
    let lg = gOf(color).float / 255
    let lb = bOf(color).float / 255
    mapPixels(src, proc (p: uint32; i, px, py: int): uint32 =
      let d = hypot(px.float - lx, py.float - ly) / reach
      var f = case kind
              of lkPoint: max(0.0, 1 - d)
              of lkInfinite: 0.8
              else:
                # (a spot: brightest in its middle, an oval falling off)
                let ax = (px.float - lx) / reach
                let ay = (py.float - ly) / reach
                let along = ax * dx + ay * dy
                let side = -ax * dy + ay * dx
                max(0.0, 1 - hypot(along * 0.7, side * 1.4))
      f = f * f * it
      if bp != nil: f *= bp[i].float
      let k = amb + f
      argb(int(aOf(p)), c255(rOf(p).float * k * (0.6 + 0.4 * lr)), c255(gOf(p).float * k * (0.6 + 0.4 * lg)),
           c255(bOf(p).float * k * (0.6 + 0.4 * lb))))

proc displace*(hScale = 10; vScale = 10; map: seq[uint32] = @[]; mapW = 0; mapH = 0; wrap = false): FilterFn =
  ## Filter > Distort > Displace: each pixel moved by a map's lightness --
  ## `map` (`mapW` x `mapH`, stretched over the picture), or the picture
  ## itself when none -- up to `hScale`, `vScale` % of 128 pixels; what
  ## comes from outside: the edge repeated, or wrapped round.
  result = proc (src: Img; inner: Rect): Img =
    var res = newImgUninit(src.w, src.h)
    let o = pu(res.px)
    let sp = pu(src.px)
    let w = src.w
    let h = src.h
    let hasMap = map.len > 0 and mapW > 0 and mapH > 0 and map.len == mapW * mapH
    let mp = if hasMap: pu(map) else: sp
    let mw = if hasMap: mapW else: w
    let mh = if hasMap: mapH else: h
    let kx = float(hScale) / 100 * 128
    let ky = float(vScale) / 100 * 128
    parallelRows(h, y):
      for x in 0 ..< w:
        let q = mp[min(mh - 1, y * mh div max(1, h)) * mw + min(mw - 1, x * mw div max(1, w))]
        let m = (lumaOf(q).float - 128) / 128
        var sx = x + int(m * kx)
        var sy = y + int(m * ky)
        if wrap:
          sx = ((sx mod w) + w) mod w
          sy = ((sy mod h) + h) mod h
        else:
          sx = clamp(sx, 0, w - 1)
          sy = clamp(sy, 0, h - 1)
        o[y * w + x] = sp[sy * w + sx]
    res

proc smartSharpen*(amount = 150; radius = 1.0; reduceNoise = 10): FilterFn =
  ## Filter > Sharpen > Smart Sharpen: an unsharp mask that leaves flat
  ## parts (where noise is) alone, `reduceNoise` 0 .. 100 % of them.
  result = proc (src: Img; inner: Rect): Img =
    var l = lumPlane(src)
    var b = l
    blurPlane(b, src.w, src.h, radius * 1.4)
    let e = edgePlane(l, src.w, src.h)
    let lp = pf(l)
    let bp = pf(b)
    let ep = pf(e)
    let k = float(amount) / 100
    let quiet = float(reduceNoise) / 100 * 0.35
    mapPixels(src, proc (p: uint32; i, x, y: int): uint32 =
      let edge = ep[i].float
      let gate = if quiet <= 0: 1.0 else: clamp((edge - quiet * 0.3) / max(0.01, quiet), 0.0, 1.0)
      let d = (lp[i] - bp[i]).float * 255 * k * gate
      argb(int(aOf(p)), c255(rOf(p).float + d), c255(gOf(p).float + d), c255(bOf(p).float + d)))

# ---- the Filter Gallery's others: Artistic, Brush Strokes, Distort, Sketch, Stylize -----------------

proc chanPlane(im: Img; shift: int): seq[float32] =
  ## One channel of the picture (16 red, 8 green, 0 blue), 0 .. 1.
  result = newSeqUninit[float32](im.w * im.h)
  let o = pf(result)
  let s = pu(im.px)
  let w = im.w
  parallelRows(im.h, y):
    for x in 0 ..< w:
      o[y * w + x] = float32((s[y * w + x] shr shift) and 255) / 255'f32

proc screenc(a, b: uint32; t: float): uint32 {.inline.} =
  ## (`b` screened over `a` by `t`, alpha kept from `a`)
  let u = clamp(t, 0.0, 1.0)
  template sc(x, y: float): int = c255(x + (255 - (255 - x) * (255 - y) / 255 - x) * u)
  argb(int(aOf(a)), sc(rOf(a).float, rOf(b).float), sc(gOf(a).float, gOf(b).float), sc(bOf(a).float, bOf(b).float))

proc fresco*(size = 2; detail = 8; texture = 1): FilterFn =
  ## Artistic > Fresco: coarse, round dabs of paint, dark at their edges,
  ## the colors strong (`size` 0 .. 10, `detail` 0 .. 10, `texture` 1 .. 3).
  result = proc (src: Img; inner: Rect): Img =
    let k = kuwahara(src, 1 + size)
    var e = edgePlane(lumPlane(k), k.w, k.h)
    blurPlane(e, k.w, k.h, 0.8 + float(10 - clamp(detail, 0, 10)) * 0.12)
    let ep = pf(e)
    let tex = float(clamp(texture, 1, 3)) * 9
    let dk = 0.9 + float(10 - clamp(detail, 0, 10)) * 0.06
    mapPixels(k, proc (p: uint32; i, x, y: int): uint32 =
      let n = (smoothNoise(x.float, y.float, 1.8, 149).float - 0.5) * tex
      let f = max(0.0, 1 - ep[i].float * dk * 1.6)
      template c(v: float): int = c255(((v - 128) * 1.35 + 128) * f + n)
      argb(int(aOf(p)), c(rOf(p).float), c(gOf(p).float), c(bOf(p).float)))

proc neonGlow*(size = 5; brightness = 15; glowColor = 0xFF3C5AFF'u32; fg = 0xFF000000'u32;
               bg = 0xFFFFFFFF'u32): FilterFn =
  ## Artistic > Neon Glow: the picture toned from the foreground color (its
  ## darks) to the background (its lights), glowing in `glowColor` --
  ## `size` -24 .. 24 (more: the glow spreads from the darks; less: from
  ## the lights), `brightness` 0 .. 50.
  result = proc (src: Img; inner: Rect): Img =
    let w = src.w
    let h = src.h
    let l = lumPlane(src)
    var g = newSeqUninit[float32](w * h)
    let lp = pf(l)
    let gp = pf(g)
    let outward = size >= 0
    for i in 0 ..< w * h: gp[i] = if outward: 1'f32 - lp[i] else: lp[i]
    blurPlane(g, w, h, abs(size).float * 0.9 + 0.6)
    let b = float(brightness) / 50
    mapPixels(src, proc (p: uint32; i, x, y: int): uint32 =
      let base = mixc(fg, bg, lp[i].float)
      let own = if outward: 1 - lp[i].float else: lp[i].float
      # (the glow: where the blurred darks reach past their own pixels, and in them a little)
      let halo = clamp(max(0.0, gp[i].float - own) * 3 + gp[i].float * 1.1, 0.0, 1.0) * min(1.0, b * 2.4)
      (screenc(base, glowColor, halo) and 0x00FFFFFF'u32) or (aOf(p).uint32 shl 24))

proc paletteKnife*(size = 25; detail = 3; softness = 0): FilterFn =
  ## Artistic > Palette Knife: paint laid on thinly with a knife, flat
  ## planes of color (`size` 1 .. 50, `detail` 1 .. 3, `softness` 0 .. 10).
  result = proc (src: Img; inner: Rect): Img =
    var k = kuwahara(src, max(1, size div 4))
    k = kuwahara(k, max(1, size div 9))
    let lv = 3 + clamp(detail, 1, 3) * 3
    var res = mapPixels(k, proc (p: uint32; i, x, y: int): uint32 =
      argb(int(aOf(p)), posterized(int(rOf(p)), lv), posterized(int(gOf(p)), lv), posterized(int(bOf(p)), lv)))
    if softness > 0: res = gaussianBlurImg(res, float(softness) * 0.35)
    res

proc roughPastels*(length = 6; detail = 4; kind = tkCanvas; scaling = 100; relief = 20; angle = 135.0): FilterFn =
  ## Artistic > Rough Pastels: chalk pastel stroked over a texture --
  ## strokes `length` 0 .. 40 long, `detail` 1 .. 20 kept, the texture
  ## `scaling` 50 .. 200 %, `relief` 0 .. 50, lit from `angle` degrees.
  result = proc (src: Img; inner: Rect): Img =
    let st = directional(src, 45, max(1, length + 1))
    let sp = pu(st.px)
    let d = float(clamp(detail, 1, 20)) / 20
    let mixed = mapPixels(src, proc (p: uint32; i, x, y: int): uint32 =
      let q = mixc(sp[i], p, d * 0.6)
      # (pastel: the colors a little lighter and stronger)
      let l = lumaOf(q).float
      argb(int(aOf(p)), c255(l + (rOf(q).float - l) * 1.2 + 10), c255(l + (gOf(q).float - l) * 1.2 + 10),
           c255(l + (bOf(q).float - l) * 1.2 + 10)))
    let hgt = textureHeight(kind, scaling, src.w, src.h)
    lit(mixed, shade(hgt, src.w, src.h, angle, float(relief) / 50 * 0.6), 1.0)

proc smudgeStick*(length = 2; highlight = 0; intensity = 10): FilterFn =
  ## Artistic > Smudge Stick: the darks smudged in short diagonal strokes,
  ## the lights brighter and their detail lost (`length` 0 .. 10,
  ## `highlight` 0 .. 20, `intensity` 0 .. 10).
  result = proc (src: Img; inner: Rect): Img =
    let st = directional(src, 45, 2 + length * 2)
    let sp = pu(st.px)
    let hl = float(highlight) / 20 * float(intensity) / 10
    mapPixels(src, proc (p: uint32; i, x, y: int): uint32 =
      let q = sp[i]
      let l = lumaOf(p).float / 255
      let t = clamp(1.2 - l, 0.35, 1.0)
      let c = mixc(p, q, t)
      # (the smudge darkens: the darker of the two in the shadows)
      let r = if l < 0.5: min(rOf(c), rOf(q)) else: rOf(c)
      let g = if l < 0.5: min(gOf(c), gOf(q)) else: gOf(c)
      let b = if l < 0.5: min(bOf(c), bOf(q)) else: bOf(c)
      let lift = hl * max(0.0, l - 0.45) * 230
      argb(int(aOf(p)), c255(r.float + lift), c255(g.float + lift), c255(b.float + lift)))

proc underpainting*(size = 6; coverage = 16; kind = tkCanvas; scaling = 100; relief = 4; angle = 135.0): FilterFn =
  ## Artistic > Underpainting: painted first on a textured ground, then
  ## painted over -- soft, broad color (`size` 0 .. 40), the texture
  ## showing through (`coverage` 0 .. 40; `scaling`, `relief`, `angle` as
  ## Texturizer's).
  result = proc (src: Img; inner: Rect): Img =
    let soft = gaussianBlurImg(src, float(size) * 0.35 + 0.5)
    let k = kuwahara(soft, 1 + size div 6)
    let hgt = textureHeight(kind, scaling, src.w, src.h)
    let cov = float(clamp(coverage, 0, 40)) / 40
    let s = shade(hgt, src.w, src.h, angle, float(relief) / 50 * 1.5 * (0.3 + cov))
    let base = mapPixels(k, proc (p: uint32; i, x, y: int): uint32 =
      # (a thin wash: the colors a little paler)
      mixc(p, 0xFFFFFFFF'u32, 0.08 + cov * 0.12))
    lit(base, s, 0.25 + cov * 0.5)

proc darkStrokes*(balance = 5; black = 6; white = 2): FilterFn =
  ## Brush Strokes > Dark Strokes: the darks painted with short, tight dark
  ## strokes, the lights with long white ones (`balance` 0 .. 10, `black`
  ## and `white` 0 .. 10 their intensity).
  result = proc (src: Img; inner: Rect): Img =
    let short = directional(src, -45, 4)
    let long = directional(src, 45, 14)
    let sp = pu(short.px)
    let lp = pu(long.px)
    let edge = 0.3 + float(clamp(balance, 0, 10)) / 10 * 0.4
    let bk = float(black) / 10
    let wt = float(white) / 10
    mapPixels(src, proc (p: uint32; i, x, y: int): uint32 =
      let l = lumaOf(p).float / 255
      if l < edge:
        let q = sp[i]
        let f = 1 - bk * 0.75 * (1 - l / edge)
        argb(int(aOf(p)), c255(rOf(q).float * f), c255(gOf(q).float * f), c255(bOf(q).float * f))
      else:
        let q = lp[i]
        let a = wt * (l - edge) / max(0.01, 1 - edge) * 120
        argb(int(aOf(p)), c255(rOf(q).float + a), c255(gOf(q).float + a), c255(bOf(q).float + a)))

proc sprayedStrokes*(length = 12; radius = 7; direction = 0): FilterFn =
  ## Brush Strokes > Sprayed Strokes: the picture sprayed on in angled
  ## strokes -- `length` 0 .. 20, `radius` 0 .. 25 of the spray,
  ## `direction` 0 right diagonal, 1 across, 2 left diagonal, 3 down.
  result = proc (src: Img; inner: Rect): Img =
    let ang = [45.0, 0.0, -45.0, 90.0][clamp(direction, 0, 3)]
    let st = directional(src, ang, max(1, length))
    spatter(radius, 4)(st, rect(0, 0, st.w, st.h))

type GlassTexture* = enum
  ## Distort > Glass's textures.
  gtBlocks = "Blocks", gtCanvas = "Canvas", gtFrosted = "Frosted", gtTinyLens = "Tiny Lens"

proc glassHeight(kind: GlassTexture; scaling, w, h: int): seq[float32] =
  let k = float(clamp(scaling, 50, 200)) / 100
  result = newSeqUninit[float32](w * h)
  let hp = pf(result)
  parallelRows(h, y):
    for x in 0 ..< w:
      let fx = x.float / k
      let fy = y.float / k
      let v = case kind
              of gtBlocks:
                let u = (fx mod 24) / 24 - 0.5
                let t = (fy mod 24) / 24 - 0.5
                1 - max(abs(u), abs(t)) * 2
              of gtCanvas:
                let a = sin(fx * 1.6) * 0.5 + 0.5
                let b = sin(fy * 1.6) * 0.5 + 0.5
                (if (int(fx / 2) + int(fy / 2)) mod 2 == 0: a else: b)
              of gtTinyLens:
                let u = (fx mod 10) / 10 - 0.5
                let t = (fy mod 10) / 10 - 0.5
                max(0.0, 1 - (u * u + t * t) * 4)
              of gtFrosted:
                smoothNoise(fx, fy, 2.5, 113).float * 0.7 + smoothNoise(fx, fy, 6, 127).float * 0.3
      hp[y * w + x] = float32(v)

proc displaced(src: Img; dx, dy: seq[float32]): Img =
  ## (each pixel read from where `dx`, `dy` send it, between pixels)
  result = newImgUninit(src.w, src.h)
  let o = pu(result.px)
  let ap = pf(dx)
  let bp = pf(dy)
  let w = src.w
  parallelRows(src.h, y):
    for x in 0 ..< w:
      let i = y * w + x
      o[i] = src.sample(x.float + ap[i].float, y.float + bp[i].float)

proc glass*(distortion = 5; smoothness = 3; texture = gtFrosted; scaling = 100; invert = false): FilterFn =
  ## Distort > Glass: the picture seen through glass of a texture (Blocks,
  ## Canvas, Frosted, Tiny Lens; `scaling` 50 .. 200 %), bent
  ## `distortion` 0 .. 20, the glass smoothed `smoothness` 1 .. 15;
  ## `invert`: its bumps the other way.
  result = proc (src: Img; inner: Rect): Img =
    let w = src.w
    let h = src.h
    var hgt = glassHeight(texture, scaling, w, h)
    blurPlane(hgt, w, h, float(clamp(smoothness, 1, 15)) * 0.4)
    var (gx, gy) = gradients(hgt, w, h)
    let k = float32(distortion) * 2.5'f32 * (if invert: -1'f32 else: 1'f32)
    let ax = pf(gx)
    let ay = pf(gy)
    for i in 0 ..< w * h:
      ax[i] *= k
      ay[i] *= k
    displaced(src, gx, gy)

proc oceanRipple*(size = 9; magnitude = 9): FilterFn =
  ## Distort > Ocean Ripple: as if under rippling water -- ripples `size`
  ## 1 .. 15 apart, `magnitude` 0 .. 20 strong.
  result = proc (src: Img; inner: Rect): Img =
    let w = src.w
    let h = src.h
    let cell = 2.5 + float(clamp(size, 1, 15)) * 1.3
    let amp = float32(magnitude) * 0.9'f32
    var hgt = newSeqUninit[float32](w * h)
    let hp = pf(hgt)
    parallelRows(h, y):
      for x in 0 ..< w:
        # (a water surface: its waves sharpened at their crests)
        let n = smoothNoise(x.float, y.float, cell, 131) * 0.65'f32 + smoothNoise(x.float, y.float, cell * 0.5, 137) * 0.35'f32
        hp[y * w + x] = abs(n - 0.5'f32) * 2
    var (gx, gy) = gradients(hgt, w, h)
    let ax = pf(gx)
    let ay = pf(gy)
    let k = amp * float32(cell) * 0.12'f32
    for i in 0 ..< w * h:
      ax[i] = clamp(ax[i] * k, -amp * 0.7'f32, amp * 0.7'f32)
      ay[i] = clamp(ay[i] * k, -amp * 0.7'f32, amp * 0.7'f32)
    displaced(src, gx, gy)

proc diffuseGlow*(graininess = 6; glow = 10; clear = 15; glowColor = 0xFFFFFFFF'u32): FilterFn =
  ## Distort > Diffuse Glow: as through a soft diffusion filter -- the
  ## lights glow in `glowColor` (the background color), with grain of it
  ## (`graininess` 0 .. 10); `glow` 0 .. 20 how much, `clear` 0 .. 20 how
  ## much of the picture is left clear of it.
  result = proc (src: Img; inner: Rect): Img =
    let w = src.w
    let h = src.h
    var l = lumPlane(src)
    let lp = pf(l)
    let th = float32(clamp(clear, 0, 20)) / 20 * 0.75'f32
    for i in 0 ..< w * h: lp[i] = clamp((lp[i] - th) / max(0.08'f32, 1 - th), 0'f32, 1'f32)
    blurPlane(l, w, h, 2.0 + float(glow) * 0.5)
    let g = float(clamp(glow, 0, 20)) / 20
    let gr = float(clamp(graininess, 0, 10)) / 10
    mapPixels(src, proc (p: uint32; i, x, y: int): uint32 =
      var t = lp[i].float * g * 1.5
      if hash01(x, y, 139).float < gr * 0.45 * (0.25 + lp[i].float): t += 0.35 + gr * 0.3
      (mixc(p, glowColor, t) and 0x00FFFFFF'u32) or (aOf(p).uint32 shl 24))

proc chalkCharcoal*(charcoal = 6; chalk = 6; pressure = 1; fg = 0xFF000000'u32; bg = 0xFFFFFFFF'u32): FilterFn =
  ## Sketch > Chalk & Charcoal: the lights and mids in coarse chalk (the
  ## background color) on a mid gray, the darks in diagonal lines of
  ## charcoal (the foreground color); `charcoal`, `chalk` 0 .. 20 how far
  ## each reaches, `pressure` 0 .. 5.
  result = proc (src: Img; inner: Rect): Img =
    var l = lumPlane(src)
    let lp = pf(l)
    let darkEdge = 0.2'f32 + float32(clamp(charcoal, 0, 20)) / 20 * 0.4'f32
    let lightEdge = 0.75'f32 - float32(clamp(chalk, 0, 20)) / 20 * 0.45'f32
    let pr = float32(clamp(pressure, 0, 5)) / 5
    parallelRows(src.h, y):
      for x in 0 ..< src.w:
        let i = y * src.w + x
        let v = lp[i]
        var o = 0.5'f32
        if v < darkEdge:
          let line = hash01((x + y) div 2, (x - y + 1_000_000) div 7, 157)
          if line > v / darkEdge * (0.7'f32 - pr * 0.3'f32): o = 0'f32
        elif v > lightEdge:
          let grain = hash01((x - y + 1_000_000) div 2, (x + y) div 5, 151) * 0.6'f32 + hash01(x, y, 163) * 0.4'f32
          if grain < (v - lightEdge) / max(0.01'f32, 1 - lightEdge) * (0.7'f32 + pr * 0.3'f32) + 0.15'f32: o = 1'f32
        lp[i] = o
    twoTone(src, l, fg, bg)

proc conteCrayon*(fgLevel = 11; bgLevel = 7; kind = tkCanvas; scaling = 100; relief = 4; angle = 45.0;
                  invert = false; fg = 0xFF000000'u32; bg = 0xFFFFFFFF'u32): FilterFn =
  ## Sketch > Conté Crayon: the dense darks and pure whites of a Conté
  ## crayon -- the foreground color for the darks, the background for the
  ## lights (`fgLevel`, `bgLevel` 1 .. 15), on a texture (as Texturizer's;
  ## `invert`: its bumps the other way).
  result = proc (src: Img; inner: Rect): Img =
    var l = lumPlane(src)
    let lp = pf(l)
    let hgt = textureHeight(kind, scaling, src.w, src.h)
    let s = shade(hgt, src.w, src.h, angle + (if invert: 180.0 else: 0.0), float(relief) / 50 * 3)
    let sp = pf(s)
    let fl = float32(clamp(fgLevel, 1, 15)) / 15
    let bl = float32(clamp(bgLevel, 1, 15)) / 15
    parallelRows(src.h, y):
      for x in 0 ..< src.w:
        let i = y * src.w + x
        let v = (lp[i] - 0.5'f32) * (1.6'f32 + fl + bl) + 0.5'f32 + (bl - fl) * 0.25'f32
        lp[i] = clamp(v + (sp[i] - 1'f32) * 0.45'f32, 0'f32, 1'f32)
    twoTone(src, l, fg, bg)

proc notePaper*(balance = 25; graininess = 10; relief = 11; fg = 0xFF000000'u32; bg = 0xFFFFFFFF'u32): FilterFn =
  ## Sketch > Note Paper: as if made of handmade paper -- the darks raised
  ## in the foreground color, the rest the background's, grained
  ## (`balance` 0 .. 50, `graininess` 0 .. 20, `relief` 0 .. 25).
  result = proc (src: Img; inner: Rect): Img =
    let w = src.w
    let h = src.h
    var l = lumPlane(src)
    blurPlane(l, w, h, 1.0)
    let lp = pf(l)
    let th = float32(clamp(balance, 0, 50)) / 50
    let gr = float32(clamp(graininess, 0, 20)) / 20
    for i in 0 ..< w * h: lp[i] = clamp((th - lp[i]) * 14 + 0.5'f32, 0'f32, 1'f32)   # (1: raised)
    var hgt = l
    blurPlane(hgt, w, h, 0.8)
    let s = shade(hgt, w, h, 135, float(relief) / 25 * 2.5)
    let sp = pf(s)
    var v = newSeqUninit[float32](w * h)
    let vp = pf(v)
    parallelRows(h, y):
      for x in 0 ..< w:
        let i = y * w + x
        let n = (hash01(x, y, 167) - 0.5'f32) * gr * 0.5'f32
        vp[i] = clamp(1 - lp[i] * 0.85'f32 + (sp[i] - 1) * 0.6'f32 + n, 0'f32, 1'f32)
    twoTone(src, v, fg, bg)

proc plaster*(balance = 20; smoothness = 2; angle = 90.0; fg = 0xFF000000'u32; bg = 0xFFFFFFFF'u32): FilterFn =
  ## Sketch > Plaster: molded in plaster, colored in the foreground and
  ## background colors -- the darks raised, the lights sunk (`balance`
  ## 0 .. 50, `smoothness` 1 .. 15), lit from `angle` degrees.
  result = proc (src: Img; inner: Rect): Img =
    let w = src.w
    let h = src.h
    var l = lumPlane(src)
    blurPlane(l, w, h, float(clamp(smoothness, 1, 15)) * 0.6)
    let lp = pf(l)
    let th = float32(clamp(balance, 0, 50)) / 50
    for i in 0 ..< w * h: lp[i] = clamp((th - lp[i]) * 10 + 0.5'f32, 0'f32, 1'f32)
    var m = l
    blurPlane(m, w, h, 1.0 + float(smoothness) * 0.3)
    let s = shade(m, w, h, angle, 4.0)
    let sp = pf(s)
    var v = newSeqUninit[float32](w * h)
    let vp = pf(v)
    for i in 0 ..< w * h: vp[i] = clamp(0.88'f32 - lp[i] * 0.4'f32 + (sp[i] - 1) * 0.7'f32, 0'f32, 1'f32)
    twoTone(src, v, fg, bg)

proc waterPaper*(fiber = 15; brightness = 60; contrast = 80): FilterFn =
  ## Sketch > Water Paper: as if painted on damp, fibrous paper: the
  ## colors run along its fibers (`fiber` 3 .. 50 how long) and blend
  ## (`brightness`, `contrast` 0 .. 100).
  result = proc (src: Img; inner: Rect): Img =
    let w = src.w
    let h = src.h
    let ln = float32(clamp(fiber, 3, 50)) * 0.5'f32
    var dx = newSeqUninit[float32](w * h)
    var dy = newSeqUninit[float32](w * h)
    let ap = pf(dx)
    let bp = pf(dy)
    parallelRows(h, y):
      for x in 0 ..< w:
        let i = y * w + x
        # (each pixel's fiber: a direction and a reach, from noise that stays put)
        let t = smoothNoise(x.float, y.float, 5, 173) * 6.2832'f32
        let r = (hash01(x, y, 179) - 0.5'f32) * ln
        ap[i] = cos(t) * r
        bp[i] = sin(t) * r
    let run = displaced(src, dx, dy)
    let ct = float(clamp(contrast, 0, 100)) / 50
    let br = (float(clamp(brightness, 0, 100)) - 50) * 2
    mapPixels(gaussianBlurImg(run, 0.8), proc (p: uint32; i, x, y: int): uint32 =
      template c(v: float): int = c255((v - 128) * ct + 128 + br)
      argb(int(aOf(p)), c(rOf(p).float), c(gOf(p).float), c(bOf(p).float)))

proc glowingEdges*(width = 2; brightness = 6; smoothness = 5): FilterFn =
  ## Stylize > Glowing Edges: the edges glowing like neon on black, in
  ## their own colors (`width` 1 .. 14, `brightness` 0 .. 20, `smoothness`
  ## 1 .. 15).
  result = proc (src: Img; inner: Rect): Img =
    let w = src.w
    let h = src.h
    var planes: array[3, seq[float32]]
    for c, sh in [16, 8, 0]:
      var pl = chanPlane(src, sh)
      blurPlane(pl, w, h, float(clamp(smoothness, 1, 15)) * 0.2)
      var e = edgePlane(pl, w, h)
      blurPlane(e, w, h, float(clamp(width, 1, 14)) * 0.35)
      planes[c] = move e
    let r = pf(planes[0])
    let g = pf(planes[1])
    let b = pf(planes[2])
    let k = 0.6 + float(clamp(brightness, 0, 20)) / 20 * 2.6
    mapPixels(src, proc (p: uint32; i, x, y: int): uint32 =
      argb(int(aOf(p)), c255(r[i].float * 255 * k), c255(g[i].float * 255 * k), c255(b[i].float * 255 * k)))

# ---- Other > HSB/HSL ---------------------------------------------------------------------------------

proc toModel(r, g, b: float; model: int): (float, float, float) =
  ## (RGB, 0 .. 1, as HSB (1) or HSL (2), each 0 .. 1)
  let mx = max(r, max(g, b))
  let mn = min(r, min(g, b))
  let d = mx - mn
  var hue = 0.0
  if d > 1e-9:
    hue = if mx == r: (g - b) / d
          elif mx == g: (b - r) / d + 2
          else: (r - g) / d + 4
    hue = hue / 6
    if hue < 0: hue += 1
  if model == 1:
    (hue, (if mx > 0: d / mx else: 0.0), mx)
  else:
    let li = (mx + mn) / 2
    (hue, (if d <= 1e-9: 0.0 else: d / (1 - abs(2 * li - 1))), li)

proc fromModel(hue, s, v: float; model: int): (float, float, float) =
  ## (HSB (1) or HSL (2) back to RGB)
  let c = if model == 1: v * s else: (1 - abs(2 * v - 1)) * s
  let hp = hue * 6
  let x = c * (1 - abs(hp mod 2 - 1))
  let (r, g, b) = if hp < 1: (c, x, 0.0)
                  elif hp < 2: (x, c, 0.0)
                  elif hp < 3: (0.0, c, x)
                  elif hp < 4: (0.0, x, c)
                  elif hp < 5: (x, 0.0, c)
                  else: (c, 0.0, x)
  let m = if model == 1: v - c else: v - c / 2
  (r + m, g + m, b + m)

proc hsbHsl*(input = 0; rows = 1): FilterFn =
  ## Other > HSB/HSL: the color channels read in one model and written in
  ## another -- 0 RGB, 1 HSB, 2 HSL (`input`: what the channels hold;
  ## `rows`: what they are made to hold). RGB to HSB puts the hue in red,
  ## the saturation in green and the brightness in blue; HSB to RGB takes
  ## them back.
  let i = clamp(input, 0, 2)
  let o = clamp(rows, 0, 2)
  mapFn(proc (p: uint32): uint32 =
    var r = rOf(p).float / 255
    var g = gOf(p).float / 255
    var b = bOf(p).float / 255
    if i != 0: (r, g, b) = fromModel(r, g, b, i)
    if o != 0: (r, g, b) = toModel(r, g, b, o)
    argb(int(aOf(p)), c255(r * 255), c255(g * 255), c255(b * 255)))

{.pop.}
