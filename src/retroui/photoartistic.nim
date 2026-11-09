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

proc texturizer*(kind = tkCanvas; scaling = 100; relief = 4; angle = 135.0): FilterFn =
  ## Texture > Texturizer: the picture on canvas, brick, burlap or
  ## sandstone, lit from `angle` degrees (`scaling` 50 .. 200 %,
  ## `relief` 0 .. 50).
  result = proc (src: Img; inner: Rect): Img =
    let k = float(clamp(scaling, 50, 200)) / 100
    var hgt = newSeqUninit[float32](src.w * src.h)
    let hp = pf(hgt)
    let w = src.w
    parallelRows(src.h, y):
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

{.pop.}
