## Filters and color adjustments for `photo` documents: blurs, sharpening,
## noise, pixelate, distortions, render (clouds, lens flare), stylize,
## video and the others; levels, curves, color balance, brightness and
## contrast, hue and saturation, replace color, invert, equalize,
## threshold, posterize, desaturate. Each works on the current layer in
## the selection, as an undoable change when a step is open.
##
## The filters take an `Img` and give one back (`filterImg`), so the same
## code makes a filter dialog's preview (`previewFilter`).
##
## ```nim
## d.beginStep("Gaussian Blur")
## d.applyFilter(8, gaussianBlur(2.5))           # margin: how far it reads around
## d.endStep()
## let lut = levelsLut(Levels(inLo: 20, inHi: 235, gamma: 1.2, outLo: 0, outHi: 255))
## d.applyFilter(0, applyLuts(lut, identityLut(), identityLut(), identityLut()))
## ```

import std/[math, algorithm, random, strutils]
import gfx, photo, photopaint, parallel

template pixPtr(s: seq[uint32]): ptr UncheckedArray[uint32] =
  ## The pixels, for the cores to share (each writes its own rows).
  cast[ptr UncheckedArray[uint32]](if s.len > 0: unsafeAddr s[0] else: nil)

type
  Img* = object
    ## Pixels to filter, `w` x `h`.
    w*, h*: int                 ## its size
    px*: seq[uint32]            ## ARGB, row by row

  FilterFn* = proc (src: Img; inner: Rect): Img {.closure.}
    ## A filter: `src` holds the part of the layer worked on with a margin
    ## around it; `inner` is that part (what is written back) in `src`.

  DeepImg* = object
    ## Pixels at 16 or 32 bits a channel, as floats: R G B A for each, the
    ## alpha straight (not multiplied in), 0 .. 1 (light at 32 bits may be
    ## more).
    w*, h*: int                 ## its size
    px*: seq[float32]           ## R G B A of each pixel, row by row

  DeepFn* = proc (src: DeepImg; inner: Rect): DeepImg {.closure.}
    ## A filter on `DeepImg`s (as `FilterFn`).

  HiWay* = object
    ## How a filter is done at 16 and 32 bits a channel (`withHi`).
    point*: proc (p: uint32): uint32 {.closure.}
      ## it changes each pixel by itself, as this does at 8 bits: done at 16
      ## bits through a table of it read between its colors
    luts*: seq[Lut]
      ## it is tables of each channel (rgb, r, g, b: Levels, Curves): read
      ## between their entries
    deep*: DeepFn
      ## it has a way of its own on floats (blurs, sharpening)

  Lut* = array[256, uint8]
    ## A table: what each level becomes.

proc newImg*(w, h: int): Img = Img(w: w, h: h, px: newSeq[uint32](w * h))
  ## A `w` x `h` picture, every pixel 0 (transparent).

proc newImgUninit*(w, h: int): Img =
  ## A picture whose pixels are all about to be written (not cleared first).
  Img(w: w, h: h, px: newSeqUninit[uint32](w * h))

var hiWays: array[48, tuple[f: FilterFn; w: HiWay]]
var hiWayNext = 0

proc withHi*(f: FilterFn; w: HiWay): FilterFn =
  ## `f`, known to be done at 16 and 32 bits as `w` says (`hiWayOf`).
  hiWays[hiWayNext] = (f, w)
  hiWayNext = (hiWayNext + 1) mod hiWays.len
  f

proc hiWayOf*(f: FilterFn): HiWay =
  ## How `f` is done at 16 and 32 bits (nothing set: only at 8 bits).
  if f == nil: return
  for k in 1 .. hiWays.len:
    let e = hiWays[(hiWayNext - k + hiWays.len) mod hiWays.len]     # (the newest first)
    if e.f != nil and e.f == f: return e.w

var hiFilterHook*: proc (d: Doc; L: Layer; margin: int; f: FilterFn; r: Rect): bool {.nimcall.}
  ## Runs a filter at 16 or 32 bits when the document is (and the filter
  ## knows how: `withHi`), true when it did. Set by `retroui/photodeep`.

proc at*(im: Img; x, y: int): uint32 {.inline.} =
  ## Pixel `x`, `y`, the edges repeated outside the picture.
  im.px[clamp(y, 0, im.h - 1) * im.w + clamp(x, 0, im.w - 1)]

proc sample*(im: Img; x, y: float): uint32 =
  ## Bilinear, the edges repeated.
  let x0 = int(floor(x))
  let y0 = int(floor(y))
  let fx = x - x0.float
  let fy = y - y0.float
  var acc = [0.0, 0.0, 0.0, 0.0]
  for (dx, dy, wt) in [(0, 0, (1 - fx) * (1 - fy)), (1, 0, fx * (1 - fy)), (0, 1, (1 - fx) * fy),
                       (1, 1, fx * fy)]:
    if wt <= 0: continue
    let p = im.at(x0 + dx, y0 + dy)
    let a = aOf(p).float * wt
    acc[0] += a; acc[1] += rOf(p).float * a; acc[2] += gOf(p).float * a; acc[3] += bOf(p).float * a
  if acc[0] <= 0.0001: return 0
  argb(int(round(acc[0])), int(round(acc[1] / acc[0])), int(round(acc[2] / acc[0])),
       int(round(acc[3] / acc[0])))

# ---- applying ---------------------------------------------------------------------------------------

proc workRect*(d: Doc): Rect =
  ## The part a filter works on: the selection's rectangle.
  d.clip(d.selBounds)

proc filterImg*(d: Doc; L: Layer; margin: int; f: FilterFn; r: Rect): Img =
  ## `f` applied to `r` of `L` (with `margin` pixels around it); the result
  ## is `r`'s size.
  let ext = d.clip(rect(r.x - margin, r.y - margin, r.w + 2 * margin, r.h + 2 * margin))
  let inner = rect(r.x - ext.x, r.y - ext.y, r.w, r.h)
  var o: Img
  if ext == d.bounds and L.px.len == d.w * d.h:
    # the whole layer: lent to the filter, not copied (a big photo: a
    # copy less of it in memory)
    var src = Img(w: d.w, h: d.h, px: move(L.px))
    try: o = f(src, inner)
    finally: L.px = move(src.px)
  else:
    var src = Img(w: ext.w, h: ext.h, px: newSeqUninit[uint32](ext.w * ext.h))
    let lp = pixPtr(L.px)
    let sp = pixPtr(src.px)
    let w = d.w
    parallelRows(ext.h, y):
      copyMem(addr sp[y * ext.w], addr lp[(ext.y + y) * w + ext.x], ext.w * 4)
    o = f(src, inner)
  if o.w == r.w and o.h == r.h and (o.w != ext.w or o.h != ext.h or inner == rect(0, 0, r.w, r.h)):
    return o
  var res = newImg(r.w, r.h)
  if o.w == ext.w and o.h == ext.h:
    let op = pixPtr(o.px)
    let rp = pixPtr(res.px)
    parallelRows(r.h, y):
      copyMem(addr rp[y * r.w], addr op[(inner.y + y) * ext.w + inner.x], r.w * 4)
  res

proc writeBack*(d: Doc; L: Layer; r: Rect; o: Img; amount: seq[uint8] = @[]; base = Img()) =
  ## `o` (`r`'s size) put into `L` in `r`, in the selection (and by
  ## `amount`, as big as the image, when given), keeping what must be kept
  ## (channels not edited, the alpha of the Background and of Preserve
  ## Transparency); over `base` (`r`'s size: the layer as it was, for a
  ## preview made again and again) or what is there. On all the cores.
  if r.w <= 0 or r.h <= 0 or o.px.len < r.w * r.h: return
  d.touch(L, r)
  let dst = pixPtr(L.px)
  let op = pixPtr(o.px)
  let bp = if base.px.len == r.w * r.h: pixPtr(base.px) else: nil
  let w = d.w
  let plain = d.sel.len == 0 and amount.len == 0 and d.colorChannelsAll and L != d.maskLayer and not L.gray
  if plain and not (L.lockAlpha or L.background):
    parallelRows(r.h, y):
      copyMem(addr dst[(r.y + y) * w + r.x], addr op[y * r.w], r.w * 4)
  elif plain:
    parallelRows(r.h, y):
      let row = (r.y + y) * w + r.x
      for x in 0 ..< r.w:
        dst[row + x] = (op[y * r.w + x] and 0xFFFFFF'u32) or (dst[row + x] and 0xFF000000'u32)
  else:
    let am = if amount.len == d.w * d.h: cast[ptr UncheckedArray[uint8]](unsafeAddr amount[0]) else: nil
    parallelRows(r.h, y):
      for x in 0 ..< r.w:
        let i = (r.y + y) * w + r.x + x
        let before = if bp != nil: bp[y * r.w + x] else: dst[i]
        let k = if am != nil: int(am[i]) else: 255
        if d.selAt(i) == 0 or k == 0:
          dst[i] = before
          continue
        dst[i] = d.applyAt(L, i, before, op[y * r.w + x], k)
  inc L.ver
  if L == d.maskLayer: d.syncQuickMask()
  d.markDirty(r)

proc applyFilter*(d: Doc; margin: int; f: FilterFn) =
  ## Runs `f` on the current layer in the selection (at 16 or 32 bits when
  ## the document is and `f` knows how).
  let L = d.layer
  let r = d.workRect
  if r.w <= 0 or r.h <= 0: return
  if d.depth >= 16 and hiFilterHook != nil and hiFilterHook(d, L, margin, f, r): return
  var o = d.filterImg(L, margin, f, r)
  if r == d.bounds and o.px.len == L.px.len and d.sel.len == 0 and d.colorChannelsAll and
     L != d.maskLayer and not L.gray and not (L.lockAlpha or L.background):
    # the whole layer: the result becomes its pixels, the old ones go to the
    # step (neither copied)
    if not d.touchWhole(L): d.touch(L, r)
    L.px = move(o.px)
    inc L.ver
    d.markDirty(r)
    return
  d.writeBack(L, r, o)

proc previewFilter*(d: Doc; margin: int; f: FilterFn; cx, cy, w, h: int): Bitmap =
  ## A filter dialog's preview: `w` x `h` pixels around `cx`, `cy` of the
  ## current layer, filtered (where selected), over a checkerboard.
  let L = d.layer
  let r = d.clip(rect(cx - w div 2, cy - h div 2, w, h))
  result = newBitmap(w, h)
  if r.w <= 0 or r.h <= 0: return
  let o = d.filterImg(L, margin, f, r)
  for y in 0 ..< h:
    for x in 0 ..< w:
      let bg = if ((x div 8) + (y div 8)) mod 2 == 0: 0xFFFFFFFF'u32 else: 0xFFCCCCCC'u32
      if x >= r.w or y >= r.h:
        result.px[y * w + x] = bg
        continue
      let i = (r.y + y) * d.w + r.x + x
      let before = L.px[i]
      let after = mix(before, o.px[y * r.w + x], d.selAt(i) / 255)
      result.px[y * w + x] = blendPx(bg, after, 255, bmNormal)

proc mapFn*(f: proc (p: uint32): uint32): FilterFn =
  ## A filter from a change of each pixel by itself (an adjustment), on all
  ## the cores (`f` must only read what it shares). At 16 and 32 bits it is
  ## done through a table of `f`.
  result = proc (src: Img; inner: Rect): Img =
    var o = newImgUninit(src.w, src.h)
    let sp = pixPtr(src.px)
    let dp = pixPtr(o.px)
    parallelFor(src.px.len, proc (lo, hi: int) =
      for i in lo ..< hi: dp[i] = f(sp[i]), grain = 4096)
    o
  discard withHi(result, HiWay(point: f))

{.push boundChecks: off, overflowChecks: off.}
# (the hot loops below: indexes checked by their construction, sums sized
# so they cannot overflow)

proc mapFn3D*(f: proc (p: uint32): uint32): FilterFn =
  ## Like `mapFn`, for colour changes that keep the alpha and do not depend
  ## on it (hue and saturation, color balance...): a big picture goes
  ## through a table of the change, made from 52 x 52 x 52 colours and
  ## read between them (trilinear), as photo programs do -- several times
  ## quicker than working each pixel out.
  result = proc (src: Img; inner: Rect): Img =
    if src.px.len < 600_000: result = mapFn(f)(src, inner); return
    const N = 52                       # grid colours 0, 5, 10 .. 255
    var lut = newSeq[uint32](N * N * N)
    let lp = cast[ptr UncheckedArray[uint32]](addr lut[0])
    parallelFor(N, proc (lo, hi: int) =
      for ri in lo ..< hi:
        for gi in 0 ..< N:
          for bi in 0 ..< N:
            lp[(ri * N + gi) * N + bi] = f(argb(255, ri * 5, gi * 5, bi * 5)) and 0xFFFFFF'u32)
    if gpuFiltersReady():
      # (on the GPU when frames are drawn with it: the table read between)
      let g = gpuColorTable(src.px, src.w, src.h, lut, N)
      if g.len == src.px.len: result = Img(w: src.w, h: src.h, px: g); return
    # (each entry its three channels 16 bits apart: one multiplication
    # weighs all three; read in the tetrahedron the color falls in -- four
    # entries, not eight)
    var packed = newSeq[uint64](N * N * N)
    let pk = cast[ptr UncheckedArray[uint64]](addr packed[0])
    for k in 0 ..< N * N * N:
      let c = lp[k]
      pk[k] = (uint64((c shr 16) and 255) shl 32) or (uint64((c shr 8) and 255) shl 16) or uint64(c and 255)
    var o = newImgUninit(src.w, src.h)
    let sp = pixPtr(src.px)
    let dp = pixPtr(o.px)
    parallelFor(src.px.len, proc (lo, hi: int) =
      for i in lo ..< hi:
        let p = sp[i]
        let r = int((p shr 16) and 255)
        let g = int((p shr 8) and 255)
        let b = int(p and 255)
        let r0 = r div 5
        let g0 = g div 5
        let b0 = b div 5
        let r1 = min(r0 + 1, N - 1)
        let g1 = min(g0 + 1, N - 1)
        let b1 = min(b0 + 1, N - 1)
        let fr = uint64(r - r0 * 5)          # 0..4 fifths
        let fg = uint64(g - g0 * 5)
        let fb = uint64(b - b0 * 5)
        template L(a, bb, c: int): uint64 = pk[(a * N + bb) * N + c]
        let c000 = L(r0, g0, b0)
        let c111 = L(r1, g1, b1)
        var acc: uint64
        if fr >= fg:
          if fg >= fb:
            acc = c000 * (5 - fr) + L(r1, g0, b0) * (fr - fg) + L(r1, g1, b0) * (fg - fb) + c111 * fb
          elif fr >= fb:
            acc = c000 * (5 - fr) + L(r1, g0, b0) * (fr - fb) + L(r1, g0, b1) * (fb - fg) + c111 * fg
          else:
            acc = c000 * (5 - fb) + L(r0, g0, b1) * (fb - fr) + L(r1, g0, b1) * (fr - fg) + c111 * fg
        else:
          if fb >= fg:
            acc = c000 * (5 - fb) + L(r0, g0, b1) * (fb - fg) + L(r0, g1, b1) * (fg - fr) + c111 * fr
          elif fb >= fr:
            acc = c000 * (5 - fg) + L(r0, g1, b0) * (fg - fb) + L(r0, g1, b1) * (fb - fr) + c111 * fr
          else:
            acc = c000 * (5 - fg) + L(r0, g1, b0) * (fg - fr) + L(r1, g1, b0) * (fr - fb) + c111 * fb
        let ro = uint32(((acc shr 32) and 0xFFFF) + 2) div 5
        let go = uint32(((acc shr 16) and 0xFFFF) + 2) div 5
        let bo = uint32((acc and 0xFFFF) + 2) div 5
        dp[i] = (p and 0xFF000000'u32) or (ro shl 16) or (go shl 8) or bo, grain = 4096)
    o
  discard withHi(result, HiWay(point: f))

# ---- blur -----------------------------------------------------------------------------------------------

proc gaussKernel(radius: float): seq[float32] =
  let sigma = max(0.1, radius / 2)
  let r = int(ceil(sigma * 3))
  result = newSeq[float32](2 * r + 1)
  var s = 0.0
  for i in -r .. r:
    let v = exp(-(i * i).float / (2 * sigma * sigma))
    result[i + r] = v.float32
    s += v
  for v in result.mitems: v = float32(v / s)

proc blurKernel(im: Img; radius: float): Img =
  ## A gaussian blur in whole numbers, premultiplied (transparent pixels do
  ## not darken the edges), in strips of rows: each core blurs a strip
  ## across, then down, in a buffer a few rows tall -- little memory even
  ## for a big photo.
  let w = im.w
  let h = im.h
  let kf = gaussKernel(radius)
  let kr = kf.len div 2
  var k = newSeq[int32](kf.len)
  var tot = 0
  for i, v in kf:
    k[i] = int32(round(v * 65536))
    tot += k[i]
  k[kr] += int32(65536 - tot)                  # (the weights add up to 65536)
  var o = newImg(w, h)
  let sp = pixPtr(im.px)
  let dp = pixPtr(o.px)
  let kp = cast[ptr UncheckedArray[int32]](addr k[0])
  const strip = 32
  let nStrips = (h + strip - 1) div strip
  parallelFor(nStrips, proc (lo, hi: int) =
    var pre = newSeq[int32](w * 4)              # a row, premultiplied
    var buf = newSeq[uint16]((strip + 2 * kr) * w * 4)
    var acc = newSeq[uint32](w * 4)
    for s in lo ..< hi:
      let y0 = s * strip
      let y1 = min(h, y0 + strip)
      # across: the strip's rows and `kr` more above and below (the edges repeated)
      for j in 0 ..< (y1 - y0) + 2 * kr:
        let srow = clamp(y0 - kr + j, 0, h - 1) * w
        for x in 0 ..< w:
          let p = sp[srow + x]
          let a = int32(p shr 24)
          let q = x * 4
          if a == 255:
            pre[q] = 255
            pre[q + 1] = int32((p shr 16) and 255)
            pre[q + 2] = int32((p shr 8) and 255)
            pre[q + 3] = int32(p and 255)
          else:
            pre[q] = a
            pre[q + 1] = (int32((p shr 16) and 255) * a + 127) div 255
            pre[q + 2] = (int32((p shr 8) and 255) * a + 127) div 255
            pre[q + 3] = (int32(p and 255) * a + 127) div 255
        let brow = j * w * 4
        for x in 0 ..< w:
          var a0, a1, a2, a3: int32
          if x >= kr and x + kr < w:
            var q = (x - kr) * 4
            for i in 0 .. 2 * kr:
              let kw = kp[i]
              a0 += kw * pre[q]; a1 += kw * pre[q + 1]; a2 += kw * pre[q + 2]; a3 += kw * pre[q + 3]
              q += 4
          else:
            for i in -kr .. kr:
              let q = clamp(x + i, 0, w - 1) * 4
              let kw = kp[i + kr]
              a0 += kw * pre[q]; a1 += kw * pre[q + 1]; a2 += kw * pre[q + 2]; a3 += kw * pre[q + 3]
          let t = brow + x * 4
          buf[t] = uint16((a0 + 128) shr 8); buf[t + 1] = uint16((a1 + 128) shr 8)
          buf[t + 2] = uint16((a2 + 128) shr 8); buf[t + 3] = uint16((a3 + 128) shr 8)
      # down: each row of the strip from the rows around it
      for y in y0 ..< y1:
        zeroMem(addr acc[0], acc.len * sizeof(uint32))
        for i in 0 .. 2 * kr:
          let kw = uint32(kp[i])
          let brow = (y - y0 + i) * w * 4
          for t in 0 ..< w * 4: acc[t] += kw * uint32(buf[brow + t])
        let orow = y * w
        for x in 0 ..< w:
          let q = x * 4
          let a = (acc[q] + (1'u32 shl 23)) shr 24
          if a == 0:
            dp[orow + x] = 0
            continue
          var r = (acc[q + 1] + (1'u32 shl 23)) shr 24
          var g = (acc[q + 2] + (1'u32 shl 23)) shr 24
          var b = (acc[q + 3] + (1'u32 shl 23)) shr 24
          if a < 255:
            r = min(255'u32, (r * 255 + a div 2) div a)
            g = min(255'u32, (g * 255 + a div 2) div a)
            b = min(255'u32, (b * 255 + a div 2) div a)
          dp[orow + x] = (min(a, 255'u32) shl 24) or (r shl 16) or (g shl 8) or b)
  o

proc gaussianBlurImg*(im: Img; radius: float): Img =
  ## A gaussian blur. Up to a radius of 8 directly; past that the picture
  ## is made smaller, blurred, and made big again (what a big blur leaves
  ## has no fine detail to lose) -- as quick at 200 pixels as at 20.
  if radius <= 0.05 or im.w <= 0 or im.h <= 0: return im
  if im.w * im.h >= 250_000 and radius <= 40 and gpuFiltersReady():
    # (on the GPU when frames are drawn with it: the same blur, sooner)
    let g = gpuBlur(im.px, im.w, im.h, radius)
    if g.len == im.px.len: return Img(w: im.w, h: im.h, px: g)
  if radius <= 8 or im.w < 16 or im.h < 16: return blurKernel(im, radius)
  let f = max(2, int(radius / 4))
  let sw = max(1, (im.w + f - 1) div f)
  let sh = max(1, (im.h + f - 1) div f)
  let small = Img(w: sw, h: sh, px: resample(im.px, im.w, im.h, sw, sh, rsBilinear))
  let sb = blurKernel(small, radius / f.float)
  Img(w: im.w, h: im.h, px: resample(sb.px, sw, sh, im.w, im.h, rsBilinear))

proc kernelImg*(im: Img; k: openArray[float]; size: int; scale = 1.0; offset = 0.0;
                keepAlpha = true): Img =
  ## A `size` x `size` convolution (Custom, sharpen, emboss...).
  var o = newImg(im.w, im.h)
  let r = size div 2
  let kk = @k
  let sp = pixPtr(im.px)
  let dp = pixPtr(o.px)
  let w = im.w
  let h = im.h
  parallelRows(h, y):
    for x in 0 ..< w:
      var acc = [0.0, 0.0, 0.0]
      for j in -r .. r:
        let yy = clamp(y + j, 0, h - 1) * w
        for i in -r .. r:
          let wt = kk[(j + r) * size + i + r]
          if wt == 0: continue
          let p = sp[yy + clamp(x + i, 0, w - 1)]
          acc[0] += rOf(p).float * wt; acc[1] += gOf(p).float * wt; acc[2] += bOf(p).float * wt
      dp[y * w + x] = argb(aOf(sp[y * w + x]), int(round(acc[0] / scale + offset)),
                           int(round(acc[1] / scale + offset)), int(round(acc[2] / scale + offset)))
  o

{.pop.}

# ---- on floats (16 and 32 bits a channel) ---------------------------------------------------------------

proc newDeepImg*(w, h: int): DeepImg = DeepImg(w: w, h: h, px: newSeq[float32](w * h * 4))
  ## A `w` x `h` picture of floats, every pixel 0 (transparent).

template fpx(s: seq[float32]): ptr UncheckedArray[float32] =
  cast[ptr UncheckedArray[float32]](if s.len > 0: unsafeAddr s[0] else: nil)

proc boxPass(src, dst: ptr UncheckedArray[float32]; w, h, r: int; across: bool) =
  ## (a box blur of `r` either side, premultiplied floats, edges repeated)
  let n = float32(2 * r + 1)
  if across:
    parallelRows(h, y):
      let row = y * w * 4
      for c in 0 .. 3:
        var acc = 0'f32
        for i in -r .. r: acc += src[row + clamp(i, 0, w - 1) * 4 + c]
        for x in 0 ..< w:
          dst[row + x * 4 + c] = acc / n
          acc += src[row + min(x + r + 1, w - 1) * 4 + c] - src[row + max(x - r, 0) * 4 + c]
  else:
    let nStrips = (w + 63) div 64
    parallelFor(nStrips, proc (lo, hi: int) =
      var acc = newSeq[float32](64 * 4)
      for s in lo ..< hi:
        let x0 = s * 64
        let x1 = min(w, x0 + 64)
        let span = (x1 - x0) * 4
        for t in 0 ..< span: acc[t] = 0
        for i in -r .. r:
          let row = clamp(i, 0, h - 1) * w * 4 + x0 * 4
          for t in 0 ..< span: acc[t] += src[row + t]
        for y in 0 ..< h:
          let o = y * w * 4 + x0 * 4
          let add = min(y + r + 1, h - 1) * w * 4 + x0 * 4
          let sub = max(y - r, 0) * w * 4 + x0 * 4
          for t in 0 ..< span:
            dst[o + t] = acc[t] / n
            acc[t] += src[add + t] - src[sub + t])

proc deepGaussian*(im: DeepImg; radius: float): DeepImg =
  ## A gaussian blur on floats, the colors weighed by their alpha: exact
  ## up to a radius of 12, three box blurs past it.
  if radius <= 0.05 or im.w <= 0 or im.h <= 0: return im
  let w = im.w
  let h = im.h
  var a = newSeqUninit[float32](w * h * 4)
  var b = newSeqUninit[float32](w * h * 4)
  let sp = fpx(im.px)
  let ap = fpx(a)
  let bp = fpx(b)
  parallelFor(w * h, proc (lo, hi: int) =
    for i in lo ..< hi:
      let al = sp[4 * i + 3]
      ap[4 * i] = sp[4 * i] * al; ap[4 * i + 1] = sp[4 * i + 1] * al
      ap[4 * i + 2] = sp[4 * i + 2] * al; ap[4 * i + 3] = al, grain = 8192)
  if radius <= 12:
    let kf = gaussKernel(radius)
    var k = newSeq[float32](kf.len)
    for i, v in kf: k[i] = float32(v)
    let kr = k.len div 2
    let kp = cast[ptr UncheckedArray[float32]](addr k[0])
    parallelRows(h, y):
      let row = y * w * 4
      for x in 0 ..< w:
        var c0, c1, c2, c3: float32
        for i in -kr .. kr:
          let q = row + clamp(x + i, 0, w - 1) * 4
          let kw = kp[i + kr]
          c0 += kw * ap[q]; c1 += kw * ap[q + 1]; c2 += kw * ap[q + 2]; c3 += kw * ap[q + 3]
        let t = row + x * 4
        bp[t] = c0; bp[t + 1] = c1; bp[t + 2] = c2; bp[t + 3] = c3
    parallelRows(h, y):
      let row = y * w * 4
      for t in 0 ..< w * 4: ap[row + t] = 0
      for i in -kr .. kr:
        let srow = clamp(y + i, 0, h - 1) * w * 4
        let kw = kp[i + kr]
        for t in 0 ..< w * 4: ap[row + t] += kw * bp[srow + t]
  else:
    # (three boxes as wide as a gaussian of that size spreads)
    let sigma = radius / 2
    let wIdeal = sqrt(12 * sigma * sigma / 3 + 1)
    var wl = int(floor(wIdeal))
    if wl mod 2 == 0: dec wl
    let wu = wl + 2
    let m = int(round((12 * sigma * sigma - 3.0 * float(wl * wl) - 12.0 * float(wl) - 9) / (-4.0 * float(wl) - 4)))
    for pass in 0 ..< 3:
      let r = (if pass < m: wl else: wu) div 2
      boxPass(ap, bp, w, h, r, true)
      boxPass(bp, ap, w, h, r, false)
  # back to straight alpha
  var o = DeepImg(w: w, h: h, px: move(a))
  let op = fpx(o.px)
  parallelFor(w * h, proc (lo, hi: int) =
    for i in lo ..< hi:
      let al = op[4 * i + 3]
      if al <= 1e-7:
        op[4 * i] = 0; op[4 * i + 1] = 0; op[4 * i + 2] = 0; op[4 * i + 3] = 0
      else:
        op[4 * i] /= al; op[4 * i + 1] /= al; op[4 * i + 2] /= al, grain = 8192)
  o

proc deepUnsharp*(im: DeepImg; amount, radius: float; threshold: float): DeepImg =
  ## Unsharp masking on floats (`threshold` 0 .. 1).
  let b = deepGaussian(im, radius)
  result = DeepImg(w: im.w, h: im.h, px: newSeqUninit[float32](im.px.len))
  let sp = fpx(im.px)
  let bp = fpx(b.px)
  let op = fpx(result.px)
  let thr = float32(threshold)
  let amt = float32(amount)
  parallelFor(im.w * im.h, proc (lo, hi: int) =
    for i in lo ..< hi:
      for c in 0 .. 2:
        let v = sp[4 * i + c]
        let diff = v - bp[4 * i + c]
        op[4 * i + c] = if abs(diff) < thr: v else: max(0'f32, v + diff * amt)
      op[4 * i + 3] = sp[4 * i + 3], grain = 8192)

proc deepHighPass*(im: DeepImg; radius: float): DeepImg =
  ## High Pass on floats: the detail around a middle gray.
  let b = deepGaussian(im, radius)
  result = DeepImg(w: im.w, h: im.h, px: newSeqUninit[float32](im.px.len))
  let sp = fpx(im.px)
  let bp = fpx(b.px)
  let op = fpx(result.px)
  parallelFor(im.w * im.h, proc (lo, hi: int) =
    for i in lo ..< hi:
      for c in 0 .. 2: op[4 * i + c] = clamp(sp[4 * i + c] - bp[4 * i + c] + 0.5'f32, 0'f32, 1'f32)
      op[4 * i + 3] = sp[4 * i + 3], grain = 8192)

proc gaussianBlur*(radius: float): FilterFn =
  ## Blur > Gaussian Blur, `radius` pixels.
  result = proc (src: Img; inner: Rect): Img = gaussianBlurImg(src, radius)
  discard withHi(result, HiWay(deep: proc (src: DeepImg; inner: Rect): DeepImg = deepGaussian(src, radius)))

proc blur*(): FilterFn =
  ## Blur > Blur: a slight blur.
  result = proc (src: Img; inner: Rect): Img = gaussianBlurImg(src, 1.0)
  discard withHi(result, HiWay(deep: proc (src: DeepImg; inner: Rect): DeepImg = deepGaussian(src, 1.0)))

proc blurMore*(): FilterFn =
  ## Blur > Blur More: a stronger `blur`.
  result = proc (src: Img; inner: Rect): Img = gaussianBlurImg(src, 2.5)
  discard withHi(result, HiWay(deep: proc (src: DeepImg; inner: Rect): DeepImg = deepGaussian(src, 2.5)))

proc motionBlur*(angle: float; distance: int): FilterFn =
  ## Blur along a direction, `distance` pixels.
  result = proc (src: Img; inner: Rect): Img =
    var o = newImg(src.w, src.h)
    let a = degToRad(angle)
    let dx = cos(a)
    let dy = -sin(a)
    let n = max(1, distance)
    let dp = pixPtr(o.px)
    parallelRows(src.h, y):
      for x in 0 ..< src.w:
        var acc = [0.0, 0.0, 0.0, 0.0]
        for k in 0 .. n:
          let t = k.float - n.float / 2
          let p = src.at(int(round(x.float + dx * t)), int(round(y.float + dy * t)))
          let al = aOf(p).float
          acc[0] += al; acc[1] += rOf(p).float * al; acc[2] += gOf(p).float * al
          acc[3] += bOf(p).float * al
        let m = float(n + 1)
        dp[y * src.w + x] = if acc[0] <= 0: 0'u32
          else: argb(int(round(acc[0] / m)), int(round(acc[1] / acc[0])), int(round(acc[2] / acc[0])),
                     int(round(acc[3] / acc[0])))
    o

proc radialBlur*(amount: int; zoom: bool): FilterFn =
  ## Spin (round about the middle) or Zoom (out from it).
  result = proc (src: Img; inner: Rect): Img =
    var o = newImg(src.w, src.h)
    let cx = inner.x.float + inner.w.float / 2
    let cy = inner.y.float + inner.h.float / 2
    let steps = 12
    let dp = pixPtr(o.px)
    parallelRows(src.h, y):
      for x in 0 ..< src.w:
        var acc = [0.0, 0.0, 0.0, 0.0]
        let dx = x.float - cx
        let dy = y.float - cy
        for k in 0 ..< steps:
          let t = (k.float / (steps - 1).float - 0.5) * amount.float / 100
          var sx, sy: float
          if zoom:
            sx = cx + dx * (1 + t * 0.5)
            sy = cy + dy * (1 + t * 0.5)
          else:
            let ang = t * 0.6
            sx = cx + dx * cos(ang) - dy * sin(ang)
            sy = cy + dx * sin(ang) + dy * cos(ang)
          let p = src.sample(sx, sy)
          let al = aOf(p).float
          acc[0] += al; acc[1] += rOf(p).float * al; acc[2] += gOf(p).float * al
          acc[3] += bOf(p).float * al
        dp[y * src.w + x] = if acc[0] <= 0: 0'u32
          else: argb(int(round(acc[0] / steps.float)), int(round(acc[1] / acc[0])),
                     int(round(acc[2] / acc[0])), int(round(acc[3] / acc[0])))
    o

# ---- sharpen ---------------------------------------------------------------------------------------------

proc unsharpImg(src: Img; amount: float; radius: float; threshold: int): Img =
  let b = gaussianBlurImg(src, radius)
  var o = newImg(src.w, src.h)
  let sp = pixPtr(src.px)
  let bp = pixPtr(b.px)
  let dp = pixPtr(o.px)
  parallelFor(src.px.len, proc (lo, hi: int) =
    for i in lo ..< hi:
      let p = sp[i]
      let q = bp[i]
      var ch: array[3, int]
      for c, (v, bv) in [(rOf(p), rOf(q)), (gOf(p), gOf(q)), (bOf(p), bOf(q))]:
        let diff = v - bv
        ch[c] = if abs(diff) < threshold: v else: int(round(v.float + diff.float * amount))
      dp[i] = argb(aOf(p), ch[0], ch[1], ch[2]), grain = 4096)
  o

proc unsharpMask*(amount: int; radius: float; threshold: int): FilterFn =
  ## Sharpen > Unsharp Mask: `amount` %, over `radius` pixels, only where a
  ## pixel differs from the blur by `threshold` levels or more.
  result = proc (src: Img; inner: Rect): Img = unsharpImg(src, amount / 100, radius, threshold)
  discard withHi(result, HiWay(deep: proc (src: DeepImg; inner: Rect): DeepImg =
    deepUnsharp(src, amount / 100, radius, threshold / 255)))

proc sharpen*(): FilterFn =
  ## Sharpen > Sharpen: a slight sharpening.
  result = proc (src: Img; inner: Rect): Img = unsharpImg(src, 0.5, 1.0, 0)
  discard withHi(result, HiWay(deep: proc (src: DeepImg; inner: Rect): DeepImg = deepUnsharp(src, 0.5, 1.0, 0)))

proc sharpenMore*(): FilterFn =
  ## Sharpen > Sharpen More: a stronger `sharpen`.
  result = proc (src: Img; inner: Rect): Img = unsharpImg(src, 1.2, 1.0, 0)
  discard withHi(result, HiWay(deep: proc (src: DeepImg; inner: Rect): DeepImg = deepUnsharp(src, 1.2, 1.0, 0)))

proc sharpenEdges*(): FilterFn =
  ## Sharpen > Sharpen Edges: sharpens where it changes, not the smooth parts.
  result = proc (src: Img; inner: Rect): Img = unsharpImg(src, 0.9, 1.0, 10)

# ---- noise -----------------------------------------------------------------------------------------------

var gaussTable: array[4096, float32]   ## (standard normal numbers, for noise)
block:
  var r = initRand(20260)
  for v in gaussTable.mitems: v = float32(r.gauss())

proc addNoise*(amount: int; gaussian: bool; mono = false; seed = 1): FilterFn =
  ## Noise > Add Noise: `amount` levels, uniform or `gaussian`; the
  ## same for the three channels with `mono`. (Each row has numbers of its
  ## own, from the seed and the row: the same noise however many cores
  ## make it, on all of them.)
  result = proc (src: Img; inner: Rect): Img =
    result = newImg(src.w, src.h)
    let sp = pixPtr(src.px)
    let op = pixPtr(result.px)
    let w = src.w
    let amt = amount.float32
    parallelFor(src.h, proc (lo, hi: int) =
      {.push boundChecks: off, overflowChecks: off.}
      for y in lo ..< hi:
        var st = uint32(seed) * 2654435761'u32 xor uint32(y + 1) * 2246822519'u32 xor 0x9E3779B9'u32
        if st == 0: st = 1
        template next(): uint32 =
          st = st xor (st shl 13)
          st = st xor (st shr 17)
          st = st xor (st shl 5)
          st
        template n(): int =
          (if gaussian: int(gaussTable[int(next() shr 20)] * amt * 0.5'f32)
           else: int((float32(next() shr 8) / 16777216'f32 * 2 - 1) * amt))
        for x in 0 ..< w:
          let i = y * w + x
          let p = sp[i]
          if mono:
            let k = n()
            op[i] = argb(aOf(p), rOf(p) + k, gOf(p) + k, bOf(p) + k)
          else:
            op[i] = argb(aOf(p), rOf(p) + n(), gOf(p) + n(), bOf(p) + n())
      {.pop.}
    , grain = 16)

{.push boundChecks: off, overflowChecks: off.}

proc medianImg(src: Img; radius: int): Img =
  ## The median of each channel over a disc of `radius`, with a histogram
  ## that slides along each row (so a big radius stays quick), found
  ## through 16 coarse bins first.
  let r = max(1, radius)
  var half = newSeq[int](2 * r + 1)          # the disc's half width on each of its rows
  var n = 0
  for j in -r .. r:
    half[j + r] = int(floor(sqrt(float(r * r + r - j * j))))
    n += 2 * half[j + r] + 1
  let target = int32(n div 2)
  var o = newImg(src.w, src.h)
  let dp = pixPtr(o.px)
  let sp = pixPtr(src.px)
  let hp = cast[ptr UncheckedArray[int]](addr half[0])
  let w = src.w
  let h = src.h
  parallelRows(h, y):
    var fine: array[3, array[256, int32]]      # (each row its own)
    var coarse: array[3, array[16, int32]]
    template put(p: uint32; k: int32) =
      let q = p
      let rr = int((q shr 16) and 255)
      let gg = int((q shr 8) and 255)
      let bb = int(q and 255)
      fine[0][rr] += k; fine[1][gg] += k; fine[2][bb] += k
      coarse[0][rr shr 4] += k; coarse[1][gg shr 4] += k; coarse[2][bb shr 4] += k
    template pix(xx, yy: int): uint32 = sp[clamp(yy, 0, h - 1) * w + clamp(xx, 0, w - 1)]
    for j in -r .. r:
      let hw = hp[j + r]
      for i in -hw .. hw: put(pix(i, y + j), 1)
    for x in 0 ..< w:
      if x > 0:
        for j in -r .. r:
          let hw = hp[j + r]
          put(pix(x - 1 - hw, y + j), -1)
          put(pix(x + hw, y + j), 1)
      var m: array[3, int]
      for c in 0 .. 2:
        var cum = 0'i32
        var bin = 0
        while bin < 15 and cum + coarse[c][bin] <= target:
          cum += coarse[c][bin]
          inc bin
        var v = bin * 16
        while v < 255:
          cum += fine[c][v]
          if cum > target: break
          inc v
        m[c] = v
      dp[y * w + x] = argb(int(sp[y * w + x] shr 24), m[0], m[1], m[2])
  result = o

proc warp(src: Img; inner: Rect; f: proc (u, v: float): (float, float)): Img =
  ## Each pixel of `inner` taken from where `f` says (in -1..1 around the
  ## middle of `inner`), bilinear; the rest as it was.
  var o = src
  let cx = inner.x.float + inner.w.float / 2
  let cy = inner.y.float + inner.h.float / 2
  let rx = max(1.0, inner.w.float / 2)
  let ry = max(1.0, inner.h.float / 2)
  let dp = pixPtr(o.px)
  let sp = pixPtr(src.px)
  let w = src.w
  let h = src.h
  parallelRows(inner.h, yy):
    let y = inner.y + yy
    for x in inner.x ..< inner.x + inner.w:
      let u = (x.float + 0.5 - cx) / rx
      let v = (y.float + 0.5 - cy) / ry
      let (su, sv) = f(u, v)
      let sx = cx + su * rx - 0.5
      let sy = cy + sv * ry - 0.5
      let x0 = int(floor(sx))
      let y0 = int(floor(sy))
      let fx = float32(sx - x0.float)
      let fy = float32(sy - y0.float)
      if x0 >= 0 and y0 >= 0 and x0 + 1 < w and y0 + 1 < h:
        # inside: four pixels, premultiplied
        var a, r, g, b: float32
        for (dx, dy, wt) in [(0, 0, (1 - fx) * (1 - fy)), (1, 0, fx * (1 - fy)),
                             (0, 1, (1 - fx) * fy), (1, 1, fx * fy)]:
          let p = sp[(y0 + dy) * w + x0 + dx]
          let pa = float32(p shr 24) * wt
          a += pa
          r += float32((p shr 16) and 255) * pa
          g += float32((p shr 8) and 255) * pa
          b += float32(p and 255) * pa
        dp[y * w + x] = if a <= 0.001: 0'u32
                        else: argb(int(a + 0.5), int(r / a + 0.5), int(g / a + 0.5), int(b / a + 0.5))
      else:
        dp[y * w + x] = src.sample(sx, sy)
  o

{.pop.}

proc median*(radius: int): FilterFn =
  ## Noise > Median: each channel the median over a disc of `radius`.
  result = proc (src: Img; inner: Rect): Img = medianImg(src, radius)

proc despeckle*(): FilterFn =
  ## A median where the image is smooth; the edges kept.
  result = proc (src: Img; inner: Rect): Img =
    let m = medianImg(src, 1)
    result = newImg(src.w, src.h)
    for y in 0 ..< src.h:
      for x in 0 ..< src.w:
        let p = src.px[y * src.w + x]
        let gx = lumaOf(src.at(x + 1, y)) - lumaOf(src.at(x - 1, y))
        let gy = lumaOf(src.at(x, y + 1)) - lumaOf(src.at(x, y - 1))
        result.px[y * src.w + x] = if abs(gx) + abs(gy) > 60: p else: m.px[y * src.w + x]

proc dustAndScratches*(radius, threshold: int): FilterFn =
  ## A median, only where the pixel differs from it by more than `threshold`.
  result = proc (src: Img; inner: Rect): Img =
    let m = medianImg(src, radius)
    result = newImg(src.w, src.h)
    for i, p in src.px:
      let q = m.px[i]
      let diff = max(abs(rOf(p) - rOf(q)), max(abs(gOf(p) - gOf(q)), abs(bOf(p) - bOf(q))))
      result.px[i] = if diff > threshold: q else: p

# ---- pixelate --------------------------------------------------------------------------------------------

proc mosaic*(cell: int): FilterFn =
  ## Squares of the average color.
  result = proc (src: Img; inner: Rect): Img =
    result = newImg(src.w, src.h)
    let c = max(2, cell)
    var by = inner.y
    while by < inner.y + inner.h:
      var bx = inner.x
      while bx < inner.x + inner.w:
        var acc = [0, 0, 0, 0]
        var n = 0
        for y in by ..< min(by + c, src.h):
          for x in bx ..< min(bx + c, src.w):
            let p = src.px[y * src.w + x]
            let a = aOf(p)
            acc[0] += a; acc[1] += rOf(p) * a; acc[2] += gOf(p) * a; acc[3] += bOf(p) * a
            inc n
        let col = if acc[0] == 0: 0'u32
                  else: argb(acc[0] div max(1, n), acc[1] div acc[0], acc[2] div acc[0], acc[3] div acc[0])
        for y in by ..< min(by + c, src.h):
          for x in bx ..< min(bx + c, src.w): result.px[y * src.w + x] = col
        bx += c
      by += c

proc cellPoints(w, h, cell: int; seed: int): seq[(float, float)] =
  var rng = initRand(seed)
  let c = max(3, cell)
  for gy in countup(-c, h + c, c):
    for gx in countup(-c, w + c, c):
      result.add (gx.float + rng.rand(c.float), gy.float + rng.rand(c.float))

proc crystallize*(cell: int; seed = 7): FilterFn =
  ## Cells of one color each (around points scattered on a grid).
  result = proc (src: Img; inner: Rect): Img =
    result = newImg(src.w, src.h)
    let c = max(3, cell)
    let pts = cellPoints(src.w, src.h, c, seed)
    let cols = (src.w + 2 * c) div c + 1
    var owner = newSeq[int](src.w * src.h)
    for y in 0 ..< src.h:
      for x in 0 ..< src.w:
        var best = -1
        var bd = 1e18
        let gx = (x + c) div c
        let gy = (y + c) div c
        for j in gy - 1 .. gy + 1:
          for i in gx - 1 .. gx + 1:
            let k = j * cols + i
            if k < 0 or k >= pts.len or i < 0 or i >= cols: continue
            let dd = (pts[k][0] - x.float) ^ 2 + (pts[k][1] - y.float) ^ 2
            if dd < bd:
              bd = dd
              best = k
        owner[y * src.w + x] = best
    var sums = newSeq[array[5, int]](pts.len)
    for i, k in owner:
      if k < 0: continue
      let p = src.px[i]
      let a = aOf(p)
      sums[k][0] += a; sums[k][1] += rOf(p) * a; sums[k][2] += gOf(p) * a; sums[k][3] += bOf(p) * a
      inc sums[k][4]
    for i, k in owner:
      if k < 0: continue
      let s = sums[k]
      result.px[i] = if s[0] == 0: 0'u32
                     else: argb(s[0] div max(1, s[4]), s[1] div s[0], s[2] div s[0], s[3] div s[0])

proc pointillize*(cell: int; bg: uint32; seed = 11): FilterFn =
  ## Dots of color on the background color.
  result = proc (src: Img; inner: Rect): Img =
    result = newImg(src.w, src.h)
    for p in result.px.mitems: p = bg
    let c = max(3, cell)
    let pts = cellPoints(src.w, src.h, c, seed)
    let r = c.float * 0.62
    for (px, py) in pts:
      let col = src.at(int(px), int(py))
      for y in max(0, int(py - r)) .. min(src.h - 1, int(py + r)):
        for x in max(0, int(px - r)) .. min(src.w - 1, int(px + r)):
          let d = sqrt((x.float + 0.5 - px) ^ 2 + (y.float + 0.5 - py) ^ 2)
          if d <= r:
            let a = clamp((r - d) * 1.5, 0.0, 1.0)
            result.px[y * src.w + x] = blendPx(result.px[y * src.w + x], col, int(a * 255), bmNormal)

proc fragment*(): FilterFn =
  ## Four copies, offset, averaged.
  result = proc (src: Img; inner: Rect): Img =
    result = newImg(src.w, src.h)
    for y in 0 ..< src.h:
      for x in 0 ..< src.w:
        var acc = [0, 0, 0, 0]
        for (dx, dy) in [(-4, -4), (4, -4), (-4, 4), (4, 4)]:
          let p = src.at(x + dx, y + dy)
          acc[0] += aOf(p); acc[1] += rOf(p); acc[2] += gOf(p); acc[3] += bOf(p)
        result.px[y * src.w + x] = argb(acc[0] div 4, acc[1] div 4, acc[2] div 4, acc[3] div 4)

proc facet*(): FilterFn =
  ## Blocks of similar color made flat (each pixel the median of its 5 x 5).
  result = proc (src: Img; inner: Rect): Img = medianImg(medianImg(src, 2), 1)

proc colorHalftone*(maxRadius: int): FilterFn =
  ## Each channel as dots on a grid, sized by its amount.
  result = proc (src: Img; inner: Rect): Img =
    result = newImg(src.w, src.h)
    let cell = max(4, maxRadius * 2)
    var chans: array[3, seq[float]]
    for c in 0 .. 2: chans[c] = newSeq[float](src.w * src.h)
    for c in 0 .. 2:
      let ang = degToRad([108.0, 162.0, 90.0][c])
      let ca = cos(ang)
      let sa = sin(ang)
      for y in 0 ..< src.h:
        for x in 0 ..< src.w:
          # rotated grid
          let u = x.float * ca + y.float * sa
          let v = -x.float * sa + y.float * ca
          let cu = (floor(u / cell.float) + 0.5) * cell.float
          let cv = (floor(v / cell.float) + 0.5) * cell.float
          let sx = cu * ca - cv * sa
          let sy = cu * sa + cv * ca
          let p = src.at(int(sx), int(sy))
          let val = [rOf(p), gOf(p), bOf(p)][c].float / 255
          let r = sqrt(1 - val) * cell.float * 0.71
          let d = sqrt((u - cu) ^ 2 + (v - cv) ^ 2)
          chans[c][y * src.w + x] = clamp(r - d + 0.5, 0.0, 1.0)
    for i in 0 ..< result.px.len:
      result.px[i] = argb(aOf(src.px[i]), int(255 * (1 - chans[0][i])), int(255 * (1 - chans[1][i])),
                          int(255 * (1 - chans[2][i])))

proc mezzotint*(kind: int; seed = 3): FilterFn =
  ## Random dots (0), short lines (1) or strokes (2) of the pure colors.
  result = proc (src: Img; inner: Rect): Img =
    result = newImg(src.w, src.h)
    for y in 0 ..< src.h:
      for x in 0 ..< src.w:
        let p = src.px[y * src.w + x]
        var ch: array[3, int]
        for c, v in [rOf(p), gOf(p), bOf(p)]:
          let hx = case kind
                   of 1: hash2(x div 4 + c * 977, y + seed)
                   of 2: hash2(x div 9 + c * 977, (y + x div 3) div 2 + seed)
                   else: hash2(x + c * 977, y + seed)
          ch[c] = if int(hx and 255) < v: 255 else: 0
        result.px[y * src.w + x] = argb(aOf(p), ch[0], ch[1], ch[2])

# ---- distort ----------------------------------------------------------------------------------------------

proc pinch*(amount: int): FilterFn =
  ## -100 (out) .. 100 (in).
  result = proc (src: Img; inner: Rect): Img =
    let k = amount.float / 100
    warp(src, inner, proc (u, v: float): (float, float) =
      let r = sqrt(u * u + v * v)
      if r >= 1 or r <= 0: result = (u, v); return
      let f = pow(sin(PI / 2 * r), -k) * r
      let s = (if k > 0: pow(r, k) else: f) / r
      (u * s, v * s))

proc spherize*(amount: int; mode = 0): FilterFn =
  ## The selection as if on a ball (`mode` 0 both ways, 1 across, 2 down).
  result = proc (src: Img; inner: Rect): Img =
    let k = amount.float / 100
    warp(src, inner, proc (u, v: float): (float, float) =
      # (no inner procs here: the cores share this; a closure made per
      # pixel would touch the shared environment's reference count)
      template bend(t0: float): float =
        let t = t0
        let a = abs(t)
        if a >= 1: t
        else:
          let s = sin(a * PI / 2)
          let m = a + (s - a) * k
          if t < 0: -m else: m
      let r = sqrt(u * u + v * v)
      case mode
      of 1: (bend(u), v)
      of 2: (u, bend(v))
      else:
        if r >= 1 or r <= 0: result = (u, v); return
        let nr = r + (arcsin(r) * 2 / PI - r) * k
        (u * nr / r, v * nr / r))

proc twirl*(angle: float): FilterFn =
  ## Turns the middle more than the edge (degrees, -999..999).
  result = proc (src: Img; inner: Rect): Img =
    let a = degToRad(angle)
    warp(src, inner, proc (u, v: float): (float, float) =
      let r = sqrt(u * u + v * v)
      if r >= 1: result = (u, v); return
      let t = a * (1 - r)
      (u * cos(t) - v * sin(t), u * sin(t) + v * cos(t)))

proc ripple*(amount: int; size: int): FilterFn =
  ## Ripples like water: `size` 0 small, 1 medium, 2 large.
  result = proc (src: Img; inner: Rect): Img =
    result = src
    let wl = [6.0, 12.0, 24.0][clamp(size, 0, 2)]
    let amp = amount.float / 100 * wl / 3
    for y in inner.y ..< inner.y + inner.h:
      for x in inner.x ..< inner.x + inner.w:
        let sx = x.float + amp * sin(y.float * 2 * PI / wl)
        let sy = y.float + amp * sin(x.float * 2 * PI / wl)
        result.px[y * src.w + x] = src.sample(sx, sy)

proc wave*(wavelength, amplitude: int; square = false): FilterFn =
  ## Bends the image in waves (`wavelength`, `amplitude` in pixels), square
  ## ones with `square`.
  result = proc (src: Img; inner: Rect): Img =
    result = src
    let wl = max(2, wavelength).float
    for y in inner.y ..< inner.y + inner.h:
      for x in inner.x ..< inner.x + inner.w:
        var s1 = sin(y.float * 2 * PI / wl)
        var s2 = sin(x.float * 2 * PI / wl * 0.77)
        if square:
          s1 = (if s1 >= 0: 1.0 else: -1.0)
          s2 = (if s2 >= 0: 1.0 else: -1.0)
        result.px[y * src.w + x] = src.sample(x.float + amplitude.float * s1, y.float + amplitude.float * s2)

proc zigzag*(amount, ridges: int): FilterFn =
  ## Ripples going out from the middle, as from a stone in a pond.
  result = proc (src: Img; inner: Rect): Img =
    let k = amount.float / 100 * 0.12
    let n = max(1, ridges).float
    warp(src, inner, proc (u, v: float): (float, float) =
      let r = sqrt(u * u + v * v)
      if r >= 1 or r <= 0: result = (u, v); return
      let nr = r + k * sin(r * n * 2 * PI) * (1 - r)
      (u * nr / r, v * nr / r))

proc shearCurve*(points: seq[(float, float)]; y: float): float =
  ## The line of Shear at height `y` (0 top .. 1 bottom): `points` are
  ## (sideways -1..1, height 0..1), joined smoothly (Catmull-Rom).
  if points.len == 0: return 0
  var pts = points
  pts.sort(proc (a, b: (float, float)): int = cmp(a[1], b[1]))
  if y <= pts[0][1]: return pts[0][0]
  if y >= pts[^1][1]: return pts[^1][0]
  var k = 0
  while k < pts.high - 1 and pts[k + 1][1] < y: inc k
  let p1 = pts[k]
  let p2 = pts[k + 1]
  let p0 = if k > 0: pts[k - 1] else: p1
  let p3 = if k + 2 < pts.len: pts[k + 2] else: p2
  let span = max(1e-9, p2[1] - p1[1])
  let t = (y - p1[1]) / span
  let t2 = t * t
  let t3 = t2 * t
  0.5 * (2 * p1[0] + (p2[0] - p0[0]) * t + (2 * p0[0] - 5 * p1[0] + 4 * p2[0] - p3[0]) * t2 +
         (3 * p1[0] - p0[0] - 3 * p2[0] + p3[0]) * t3)

proc shear*(points: seq[(float, float)]; wrap: bool): FilterFn =
  ## Distort > Shear: each row moved sideways by the line bent through
  ## `points` (-1..1: half the width each way); what is uncovered comes
  ## from the other side (`wrap`) or is the edge repeated.
  result = proc (src: Img; inner: Rect): Img =
    result = src
    let half = inner.w.float / 2
    for y in inner.y ..< inner.y + inner.h:
      let v = (y - inner.y).float / max(1, inner.h - 1).float
      let off = shearCurve(points, v) * half
      for x in inner.x ..< inner.x + inner.w:
        var sx = x.float - off
        let lo = inner.x.float
        let hi = (inner.x + inner.w).float
        if wrap:
          sx = lo + floorMod(sx - lo, inner.w.float)
        else:
          sx = clamp(sx, lo, hi - 1)
        result.px[y * src.w + x] = src.sample(sx, y.float)

proc extrude*(size, depth: int; pyramids = false; randomDepth = false; frontsSolid = false;
              levelBased = false; seed = 3): FilterFn =
  ## Stylize > Extrude: the image cut in blocks (or pyramids) of `size`
  ## that come out toward you, the farther from the middle the more they
  ## lean (`randomDepth`: as far as chance says; `levelBased`: the lighter
  ## the farther); each block's front is its average color (`frontsSolid`)
  ## or the image, its sides darker.
  result = proc (src: Img; inner: Rect): Img =
    result = src
    let sz = max(2, size)
    let cx = inner.x.float + inner.w.float / 2
    let cy = inner.y.float + inner.h.float / 2
    # the blocks, the far ones first so the near ones cover them
    var blocks: seq[(int, int, float)]
    var by = inner.y
    while by < inner.y + inner.h:
      var bx = inner.x
      while bx < inner.x + inner.w:
        let h = hash2(bx + seed, by)
        var dep = if randomDepth: float(h mod uint32(max(1, depth) + 1)) else: depth.float
        if levelBased:
          var sum = 0
          var n = 0
          for y in by ..< min(by + sz, inner.y + inner.h):
            for x in bx ..< min(bx + sz, inner.x + inner.w):
              sum += lumaOf(src.px[y * src.w + x])
              inc n
          dep = depth.float * sum.float / max(1, n).float / 255
        blocks.add (bx, by, dep)
        bx += sz
      by += sz
    blocks.sort(proc (a, b: (int, int, float)): int = cmp(a[2], b[2]))
    let room = max(inner.w, inner.h).float
    for (bx, by, dep) in blocks:
      let bw = min(sz, inner.x + inner.w - bx)
      let bh = min(sz, inner.y + inner.h - by)
      var a = 0; var rr = 0; var gg = 0; var bb = 0; var n = 0
      for y in by ..< by + bh:
        for x in bx ..< bx + bw:
          let p = src.px[y * src.w + x]
          a += aOf(p); rr += rOf(p); gg += gOf(p); bb += bOf(p); inc n
      let avg = argb(a div max(1, n), rr div max(1, n), gg div max(1, n), bb div max(1, n))
      # the front, moved away from the middle as if seen in perspective
      let k = dep / max(1.0, room) * 0.9
      let mx = bx.float + bw.float / 2
      let my = by.float + bh.float / 2
      let ox = int(round((mx - cx) * k))
      let oy = int(round((my - cy) * k))
      # the sides: the block's color darker, from where it was to the front
      let steps = max(abs(ox), abs(oy))
      for st in 0 ..< steps:
        let t = st / max(1, steps)
        let sx = bx + int(round(ox.float * t))
        let sy = by + int(round(oy.float * t))
        let dark = argb(aOf(avg), rOf(avg) * 6 div 10, gOf(avg) * 6 div 10, bOf(avg) * 6 div 10)
        for y in sy ..< sy + bh:
          for x in sx ..< sx + bw:
            if x < inner.x or y < inner.y or x >= inner.x + inner.w or y >= inner.y + inner.h: continue
            if pyramids: continue
            result.px[y * src.w + x] = dark
      let fx = bx + ox
      let fy = by + oy
      for y in 0 ..< bh:
        for x in 0 ..< bw:
          let tx = fx + x
          let ty = fy + y
          if tx < inner.x or ty < inner.y or tx >= inner.x + inner.w or ty >= inner.y + inner.h: continue
          var c = if frontsSolid or pyramids: avg else: src.px[(by + y) * src.w + bx + x]
          if pyramids:
            # four faces lit from the top left
            let u = (x.float + 0.5) / bw.float - 0.5
            let v = (y.float + 0.5) / bh.float - 0.5
            let f = if abs(u) > abs(v): (if u < 0: 1.15 else: 0.75) else: (if v < 0: 1.3 else: 0.6)
            c = argb(aOf(c), int(rOf(c).float * f), int(gOf(c).float * f), int(bOf(c).float * f))
          result.px[ty * src.w + tx] = c

proc polarCoordinates*(toPolar: bool): FilterFn =
  ## Rectangular to polar (a rectangle made a round thing), or back.
  result = proc (src: Img; inner: Rect): Img =
    result = src
    let cx = inner.x.float + inner.w.float / 2
    let cy = inner.y.float + inner.h.float / 2
    let rmax = sqrt((inner.w.float / 2) ^ 2 + (inner.h.float / 2) ^ 2)
    for y in inner.y ..< inner.y + inner.h:
      for x in inner.x ..< inner.x + inner.w:
        var sx, sy: float
        if toPolar:
          let dx = x.float + 0.5 - cx
          let dy = y.float + 0.5 - cy
          var a = arctan2(dx, -dy)
          if a < 0: a += 2 * PI
          sx = inner.x.float + a / (2 * PI) * inner.w.float
          sy = inner.y.float + sqrt(dx * dx + dy * dy) / rmax * inner.h.float
        else:
          let a = (x.float - inner.x.float) / inner.w.float * 2 * PI
          let r = (y.float - inner.y.float) / inner.h.float * rmax
          sx = cx + sin(a) * r
          sy = cy - cos(a) * r
        result.px[y * src.w + x] = src.sample(sx - 0.5, sy - 0.5)

# ---- render -----------------------------------------------------------------------------------------------

proc noise2(x, y: int; seed: int): float =
  float(hash2(x + seed * 7919, y - seed * 104729) and 0xFFFF) / 65535

proc smoothNoise(x, y: float; seed: int): float =
  let x0 = int(floor(x))
  let y0 = int(floor(y))
  let fx = x - x0.float
  let fy = y - y0.float
  let sx = fx * fx * (3 - 2 * fx)
  let sy = fy * fy * (3 - 2 * fy)
  let a = noise2(x0, y0, seed)
  let b = noise2(x0 + 1, y0, seed)
  let c = noise2(x0, y0 + 1, seed)
  let d = noise2(x0 + 1, y0 + 1, seed)
  (a + (b - a) * sx) + ((c + (d - c) * sx) - (a + (b - a) * sx)) * sy

proc cloudValue*(x, y: float; seed: int): float =
  ## Fractal noise, 0..1.
  var amp = 0.5
  var freq = 1.0 / 64
  var s = 0.0
  var norm = 0.0
  for o in 0 ..< 7:
    s += amp * smoothNoise(x * freq, y * freq, seed + o)
    norm += amp
    amp *= 0.5
    freq *= 2
  s / norm

proc clouds*(fg, bg: uint32; seed = 1; difference = false): FilterFn =
  ## Soft clouds between the foreground and background colors (Difference
  ## Clouds: mixed with what is there by Difference).
  result = proc (src: Img; inner: Rect): Img =
    result = newImg(src.w, src.h)
    for y in 0 ..< src.h:
      for x in 0 ..< src.w:
        var t = cloudValue(x.float, y.float, seed)
        t = clamp((t - 0.5) * 1.8 + 0.5, 0.0, 1.0)
        let c = mix(fg or 0xFF000000'u32, bg or 0xFF000000'u32, t)
        let p = src.px[y * src.w + x]
        result.px[y * src.w + x] = if difference: blendPx(p, c, 255, bmDifference).withAlpha(max(aOf(p), 1))
                                   else: c

proc lensFlare*(cx, cy: float; brightness: int): FilterFn =
  ## A bright light and its rings at (`cx`, `cy`) of the part filtered.
  result = proc (src: Img; inner: Rect): Img =
    result = src
    let px = inner.x.float + cx
    let py = inner.y.float + cy
    let b = brightness.float / 100
    let mx = inner.x.float + inner.w.float / 2
    let my = inner.y.float + inner.h.float / 2
    let size = max(inner.w, inner.h).float
    # the spots along the line through the middle
    let spots = [(0.6, 0.05, 0xFFFFE0C0'u32), (1.2, 0.03, 0xFFC0E0FF'u32), (1.6, 0.08, 0xFFE0FFE0'u32),
                 (2.1, 0.02, 0xFFFFC0FF'u32)]
    for y in inner.y ..< inner.y + inner.h:
      for x in inner.x ..< inner.x + inner.w:
        let i = y * src.w + x
        var p = src.px[i]
        let d = sqrt((x.float - px) ^ 2 + (y.float - py) ^ 2) / size
        var glow = b * (0.025 / (d + 0.025)) * 1.4
        let ring = b * 0.35 * exp(-(((d - 0.09) * 60) ^ 2))
        var add = [glow * 255 + ring * 200, glow * 245 + ring * 230, glow * 220 + ring * 255]
        for (t, r, col) in spots:
          let sx = px + (mx - px) * t
          let sy = py + (my - py) * t
          let sd = sqrt((x.float - sx) ^ 2 + (y.float - sy) ^ 2) / size
          if sd < r:
            let k = b * 0.25 * (1 - sd / r)
            add[0] += k * rOf(col).float; add[1] += k * gOf(col).float; add[2] += k * bOf(col).float
        glow = 0
        p = argb(aOf(p), int(rOf(p).float + add[0]), int(gOf(p).float + add[1]), int(bOf(p).float + add[2]))
        result.px[i] = p

# ---- stylize ------------------------------------------------------------------------------------------------

proc findEdges*(): FilterFn =
  ## The edges dark on white, as if drawn.
  result = proc (src: Img; inner: Rect): Img =
    var o = newImg(src.w, src.h)
    let dp = pixPtr(o.px)
    parallelRows(src.h, y):
      for x in 0 ..< src.w:
        var ch: array[3, int]
        for c in 0 .. 2:
          template v(xx, yy: int): int =
            ((src.at(xx, yy) shr (16 - 8 * c)) and 255).int
          let gx = (v(x + 1, y - 1) + 2 * v(x + 1, y) + v(x + 1, y + 1)) -
                   (v(x - 1, y - 1) + 2 * v(x - 1, y) + v(x - 1, y + 1))
          let gy = (v(x - 1, y + 1) + 2 * v(x, y + 1) + v(x + 1, y + 1)) -
                   (v(x - 1, y - 1) + 2 * v(x, y - 1) + v(x + 1, y - 1))
          ch[c] = 255 - min(255, int(sqrt(float(gx * gx + gy * gy)) / 2))
        dp[y * src.w + x] = argb(aOf(src.px[y * src.w + x]), ch[0], ch[1], ch[2])
    o

proc emboss*(angle: float; height: int; amount: int): FilterFn =
  ## Gray relief lit from `angle`.
  result = proc (src: Img; inner: Rect): Img =
    var o = newImg(src.w, src.h)
    let a = degToRad(angle)
    let dx = cos(a) * max(1, height).float
    let dy = -sin(a) * max(1, height).float
    let k = amount.float / 100
    let dp = pixPtr(o.px)
    parallelRows(src.h, y):
      for x in 0 ..< src.w:
        let p1 = src.sample(x.float + dx, y.float + dy)
        let p2 = src.sample(x.float - dx, y.float - dy)
        let v = clamp(128 + int((lumaOf(p1) - lumaOf(p2)).float * k), 0, 255)
        dp[y * src.w + x] = grayPx(v, aOf(src.px[y * src.w + x]))
    o

proc diffuse*(mode = 0; seed = 5): FilterFn =
  ## Each pixel swapped with one near it (0 normal, 1 only darker, 2 only lighter).
  result = proc (src: Img; inner: Rect): Img =
    result = src
    for y in 0 ..< src.h:
      for x in 0 ..< src.w:
        let h = hash2(x + seed, y)
        let q = src.at(x + int(h and 3) - 1, y + int((h shr 2) and 3) - 1)
        let p = src.px[y * src.w + x]
        let take = case mode
                   of 1: lumaOf(q) < lumaOf(p)
                   of 2: lumaOf(q) > lumaOf(p)
                   else: true
        if take: result.px[y * src.w + x] = q

proc solarize*(): FilterFn =
  ## Stylize > Solarize: the light levels inverted, as a print exposed to
  ## light.
  mapFn(proc (p: uint32): uint32 =
    template s(v: int): int = (if v > 127: 255 - v else: v)
    argb(aOf(p), s(rOf(p)), s(gOf(p)), s(bOf(p))))

proc tiles*(number: int; maxOffset: int; bg: uint32; seed = 9): FilterFn =
  ## The image in square tiles, each moved a little (`number` across the
  ## smaller side; `maxOffset` % of a tile).
  result = proc (src: Img; inner: Rect): Img =
    result = newImg(src.w, src.h)
    for p in result.px.mitems: p = bg
    let t = max(4, min(inner.w, inner.h) div max(1, number))
    let mo = t * clamp(maxOffset, 1, 99) div 100
    var ty = inner.y
    while ty < inner.y + inner.h:
      var tx = inner.x
      while tx < inner.x + inner.w:
        let h = hash2(tx + seed, ty)
        let ox = int(h mod uint32(2 * mo + 1)) - mo
        let oy = int((h shr 8) mod uint32(2 * mo + 1)) - mo
        for y in ty ..< min(ty + t, src.h):
          for x in tx ..< min(tx + t, src.w):
            let nx = x + ox
            let ny = y + oy
            if nx >= 0 and ny >= 0 and nx < src.w and ny < src.h:
              result.px[ny * src.w + nx] = src.px[y * src.w + x]
        tx += t
      ty += t

proc traceContour*(level: int; upper: bool): FilterFn =
  ## Thin lines where each channel crosses `level`.
  result = proc (src: Img; inner: Rect): Img =
    result = newImg(src.w, src.h)
    for y in 0 ..< src.h:
      for x in 0 ..< src.w:
        var ch = [255, 255, 255]
        let p = src.px[y * src.w + x]
        for c in 0 .. 2:
          proc v(q: uint32): int = [rOf(q), gOf(q), bOf(q)][c]
          let here = v(p) >= level
          let right = v(src.at(x + 1, y)) >= level
          let down = v(src.at(x, y + 1)) >= level
          if (here != right or here != down) and (here == upper): ch[c] = 0
        result.px[y * src.w + x] = argb(aOf(p), ch[0], ch[1], ch[2])

proc wind*(strong = false; fromLeft = true; seed = 13): FilterFn =
  ## Streaks blown from the lighter parts.
  result = proc (src: Img; inner: Rect): Img =
    result = src
    let maxLen = if strong: 40 else: 14
    for y in 0 ..< src.h:
      var streak = 0
      var col = 0'u32
      for k in 0 ..< src.w:
        let x = if fromLeft: k else: src.w - 1 - k
        let p = src.px[y * src.w + x]
        if streak > 0:
          let t = streak.float / maxLen.float
          result.px[y * src.w + x] = mix(p, col, t * 0.85)
          if lumaOf(p) <= lumaOf(col): dec streak else: streak = 0
        let h = hash2(x + seed, y)
        if lumaOf(p) > 140 and int(h and 31) == 0:
          streak = maxLen div 2 + int((h shr 5) mod uint32(maxLen div 2 + 1))
          col = p

# ---- video, other ------------------------------------------------------------------------------------------------

proc deInterlace*(oddLines = true; interpolate = true): FilterFn =
  ## Drops the odd (or even) lines of a video frame, made up again.
  result = proc (src: Img; inner: Rect): Img =
    result = src
    for y in 0 ..< src.h:
      if (y mod 2 == 1) != oddLines: continue
      for x in 0 ..< src.w:
        let a = src.at(x, y - 1)
        let b = src.at(x, y + 1)
        result.px[y * src.w + x] = if interpolate: mix(a, b, 0.5) else: a

proc ntscColors*(): FilterFn =
  ## Colors kept within what television shows (saturation limited).
  mapFn(proc (p: uint32): uint32 =
    var h = toHsl(p)
    h.s = min(h.s, 0.78)
    if h.l > 0.92: h.l = 0.92
    fromHsl(h.h, h.s, h.l, aOf(p)))

proc highPass*(radius: float): FilterFn =
  ## Keeps the detail (gray where it is smooth).
  result = proc (src: Img; inner: Rect): Img =
    let b = gaussianBlurImg(src, radius)
    var o = newImg(src.w, src.h)
    let sp = pixPtr(src.px)
    let bp = pixPtr(b.px)
    let dp = pixPtr(o.px)
    parallelFor(src.px.len, proc (lo, hi: int) =
      for i in lo ..< hi:
        let p = sp[i]
        let q = bp[i]
        dp[i] = argb(aOf(p), rOf(p) - rOf(q) + 128, gOf(p) - gOf(q) + 128, bOf(p) - bOf(q) + 128),
      grain = 4096)
    o
  discard withHi(result, HiWay(deep: proc (src: DeepImg; inner: Rect): DeepImg = deepHighPass(src, radius)))

proc maxMin(src: Img; radius: int; grow: bool): Img =
  ## The lightest (darkest) of each channel in a square around each pixel:
  ## along the rows, then down the columns.
  let r = max(1, radius)
  let w = src.w
  let h = src.h
  var mid = newImg(w, h)
  var o = newImg(w, h)
  let sp = pixPtr(src.px)
  let mp = pixPtr(mid.px)
  let dp = pixPtr(o.px)
  template pick(a, b: int): int = (if grow: max(a, b) else: min(a, b))
  parallelRows(h, y):
    for x in 0 ..< w:
      var ch = if grow: [0, 0, 0] else: [255, 255, 255]
      for i in max(0, x - r) .. min(w - 1, x + r):
        let p = sp[y * w + i]
        ch[0] = pick(ch[0], rOf(p)); ch[1] = pick(ch[1], gOf(p)); ch[2] = pick(ch[2], bOf(p))
      mp[y * w + x] = argb(aOf(sp[y * w + x]), ch[0], ch[1], ch[2])
  parallelRows(h, y):
    for x in 0 ..< w:
      var ch = if grow: [0, 0, 0] else: [255, 255, 255]
      for j in max(0, y - r) .. min(h - 1, y + r):
        let p = mp[j * w + x]
        ch[0] = pick(ch[0], rOf(p)); ch[1] = pick(ch[1], gOf(p)); ch[2] = pick(ch[2], bOf(p))
      dp[y * w + x] = argb(aOf(sp[y * w + x]), ch[0], ch[1], ch[2])
  o

proc maximum*(radius: int): FilterFn =
  ## The lightest pixel around each one (white parts grow).
  result = proc (src: Img; inner: Rect): Img = maxMin(src, radius, true)

proc minimum*(radius: int): FilterFn =
  ## The darkest pixel around each one (black parts grow).
  result = proc (src: Img; inner: Rect): Img = maxMin(src, radius, false)

proc offsetFilter*(dx, dy: int; how = 0; bg = 0'u32): FilterFn =
  ## Moves the pixels by `dx`, `dy`: what is uncovered is `bg` (0),
  ## the edge repeated (1), or what went out at the other side (2).
  result = proc (src: Img; inner: Rect): Img =
    result = src
    for y in inner.y ..< inner.y + inner.h:
      for x in inner.x ..< inner.x + inner.w:
        var sx = x - dx
        var sy = y - dy
        let inside = sx >= inner.x and sy >= inner.y and sx < inner.x + inner.w and sy < inner.y + inner.h
        if not inside:
          case how
          of 1:
            sx = clamp(sx, inner.x, inner.x + inner.w - 1)
            sy = clamp(sy, inner.y, inner.y + inner.h - 1)
          of 2:
            sx = inner.x + (((sx - inner.x) mod inner.w) + inner.w) mod inner.w
            sy = inner.y + (((sy - inner.y) mod inner.h) + inner.h) mod inner.h
          else:
            result.px[y * src.w + x] = bg
            continue
        result.px[y * src.w + x] = src.px[sy * src.w + sx]

proc custom*(k: openArray[float]; scale: float; offset: float): FilterFn =
  ## Other > Custom: a 5 x 5 convolution.
  let kk = @k
  result = proc (src: Img; inner: Rect): Img =
    kernelImg(src, kk, 5, if scale == 0: 1.0 else: scale, offset)

# ---- adjustments ------------------------------------------------------------------------------------------------

type
  Levels* = object
    ## Input black, gray (gamma 0.1..9.99) and white; output black and white.
    inLo*, inHi*: int           ## the input's black and white (0..255)
    gamma*: float               ## the midtones (1: unchanged)
    outLo*, outHi*: int         ## the output's black and white (0..255)

proc identityLut*(): Lut =
  ## A table that changes nothing.
  for i in 0 .. 255: result[i] = uint8(i)

proc levelsLut*(l: Levels): Lut =
  ## The table of a Levels adjustment.
  let lo = clamp(l.inLo, 0, 253)
  let hi = clamp(l.inHi, lo + 2, 255)
  let g = clamp(l.gamma, 0.1, 9.99)
  for i in 0 .. 255:
    let t = clamp((i - lo).float / (hi - lo).float, 0.0, 1.0)
    let v = pow(t, 1 / g)
    result[i] = uint8(clamp(int(round(l.outLo.float + v * (l.outHi - l.outLo).float)), 0, 255))

proc defaultLevels*(): Levels = Levels(inLo: 0, inHi: 255, gamma: 1.0, outLo: 0, outHi: 255)
  ## Levels that change nothing: 0..255 in and out, gamma 1.

proc applyLuts*(rgb, r, g, b: Lut): FilterFn =
  ## Each channel's, then the master (`rgb`), as Photoshop's Levels and
  ## Curves (at 16 bits: the tables read between their entries).
  let fn = proc (p: uint32): uint32 =
    argb(aOf(p), int(rgb[r[rOf(p)]]), int(rgb[g[gOf(p)]]), int(rgb[b[bOf(p)]]))
  withHi(mapFn(fn), HiWay(point: fn, luts: @[rgb, r, g, b]))

proc autoLevels*(h: Histogram; clip = 0.005): array[3, Levels] =
  ## Each channel stretched from its darkest to its lightest (`clip` of
  ## the pixels at each end ignored).
  for c in 0 .. 2:
    let counts = h.counts[c + 1]
    let n = max(1, h.total)
    var lo = 0
    var acc = 0
    while lo < 254:
      acc += counts[lo]
      if acc.float / n.float > clip: break
      inc lo
    var hi = 255
    acc = 0
    while hi > lo + 1:
      acc += counts[hi]
      if acc.float / n.float > clip: break
      dec hi
    result[c] = Levels(inLo: lo, inHi: max(hi, lo + 2), gamma: 1.0, outLo: 0, outHi: 255)

proc curveLut*(pts: openArray[(int, int)]): Lut =
  ## A smooth curve through the points (input, output), as Curves draws it.
  var p = @pts
  p.sort(proc (a, b: (int, int)): int = cmp(a[0], b[0]))
  if p.len == 0: return identityLut()
  if p.len == 1:
    for i in 0 .. 255: result[i] = uint8(clamp(p[0][1], 0, 255))
    return
  # a natural cubic spline through the points (as Photoshop's Curves),
  # flat past the first and last
  let n = p.len
  var xs = newSeq[float](n)
  var ys = newSeq[float](n)
  for i in 0 ..< n:
    xs[i] = p[i][0].float
    ys[i] = p[i][1].float
  var h = newSeq[float](n - 1)
  for i in 0 ..< n - 1: h[i] = max(1e-9, xs[i + 1] - xs[i])
  var m = newSeq[float](n)          # second derivatives (0 at the ends)
  if n > 2:
    var a = newSeq[float](n)
    var b = newSeq[float](n)
    var c = newSeq[float](n)
    var r = newSeq[float](n)
    for i in 1 ..< n - 1:
      a[i] = h[i - 1]
      b[i] = 2 * (h[i - 1] + h[i])
      c[i] = h[i]
      r[i] = 6 * ((ys[i + 1] - ys[i]) / h[i] - (ys[i] - ys[i - 1]) / h[i - 1])
    for i in 2 ..< n - 1:
      let w = a[i] / b[i - 1]
      b[i] -= w * c[i - 1]
      r[i] -= w * r[i - 1]
    for i in countdown(n - 2, 1):
      m[i] = (r[i] - (if i + 1 < n - 1: c[i] * m[i + 1] else: 0.0)) / b[i]
  for x in 0 .. 255:
    var v: float
    if x.float <= xs[0]: v = ys[0]
    elif x.float >= xs[^1]: v = ys[^1]
    else:
      var k = 0
      while k < n - 2 and x.float > xs[k + 1]: inc k
      let t = x.float - xs[k]
      let hk = h[k]
      let bk = (ys[k + 1] - ys[k]) / hk - hk * (2 * m[k] + m[k + 1]) / 6
      v = ys[k] + bk * t + m[k] / 2 * t * t + (m[k + 1] - m[k]) / (6 * hk) * t * t * t
    result[x] = uint8(clamp(int(round(v)), 0, 255))

proc brightnessContrast*(brightness, contrast: int): FilterFn =
  ## -100..100 each.
  var lut: Lut
  let c = clamp(contrast, -100, 100).float / 100
  let k = if c >= 0: 1 / max(0.01, 1 - c) else: 1 + c
  for i in 0 .. 255:
    var v = i.float + brightness.float * 1.275
    v = (v - 127.5) * k + 127.5
    lut[i] = uint8(clamp(int(round(v)), 0, 255))
  applyLuts(lut, identityLut(), identityLut(), identityLut())

proc colorBalance*(shadows, midtones, highlights: array[3, int]; preserveLum = true): FilterFn =
  ## Each tone range moved toward red / green / blue (or cyan / magenta /
  ## yellow), -100..100.
  result = mapFn3D(proc (p: uint32): uint32 =
    let l = lumaOf(p).float / 255
    let ws = clamp(1 - l * 3.3, 0.0, 1.0)
    let wh = clamp((l - 0.7) * 3.3, 0.0, 1.0)
    let wm = clamp(1 - abs(l - 0.5) * 2.4, 0.0, 1.0)
    var ch: array[3, float]
    for c, v in [rOf(p), gOf(p), bOf(p)]:
      let shift = shadows[c].float * ws + midtones[c].float * wm + highlights[c].float * wh
      ch[c] = v.float + shift * 0.9
    var q = argb(aOf(p), int(round(ch[0])), int(round(ch[1])), int(round(ch[2])))
    if preserveLum:
      let d = lumaOf(p) - lumaOf(q)
      q = argb(aOf(q), rOf(q) + d, gOf(q) + d, bOf(q) + d)
    q)

proc hueSaturation*(hue, saturation, lightness: int; colorize = false): FilterFn =
  ## Hue -180..180, saturation and lightness -100..100 (Colorize: all of
  ## it in one hue, 0..360, saturation 0..100).
  result = mapFn3D(proc (p: uint32): uint32 =
    var h = toHsl(p)
    if colorize:
      h.h = ((hue mod 360) + 360).float mod 360
      h.s = clamp(saturation.float / 100, 0.0, 1.0)
    else:
      h.h = ((h.h + hue.float) mod 360 + 360) mod 360
      let s = saturation.float / 100
      h.s = clamp(if s > 0: h.s + (1 - h.s) * s * h.s * 2 else: h.s * (1 + s), 0.0, 1.0)
    let li = lightness.float / 100
    h.l = clamp(if li > 0: h.l + (1 - h.l) * li else: h.l * (1 + li), 0.0, 1.0)
    fromHsl(h.h, h.s, h.l, aOf(p)))

type HueAdjust* = array[7, array[3, int]]
  ## Hue/Saturation by color: `[0]` all colors (Master), `[1..6]` the reds,
  ## yellows, greens, cyans, blues and magentas; each hue (-180..180),
  ## saturation and lightness (-100..100).

proc rangeWeight*(hue, sat: float; range: int): float =
  ## How much of color range `range` (1 reds .. 6 magentas) a color is: all
  ## of it within 15 degrees of the range's hue, none past 45; grays none.
  if range <= 0: return 1.0
  if sat < 0.02: return 0.0
  var dh = abs(hue - float(range - 1) * 60)
  if dh > 180: dh = 360 - dh
  if dh <= 15: 1.0 elif dh >= 45: 0.0 else: (45 - dh) / 30

type HueRanges* = array[6, array[4, int]]
  ## Where each color range of Hue/Saturation lies on the color wheel
  ## (degrees): where it starts to count, where it fully counts, where it
  ## stops fully counting, where it stops.

const DefaultHueRanges*: HueRanges = [[315, 345, 15, 45], [15, 45, 75, 105], [75, 105, 135, 165],
                                       [135, 165, 195, 225], [195, 225, 255, 285], [255, 285, 315, 345]]
  ## Photoshop's ranges: reds, yellows, greens, cyans, blues, magentas.

proc rangeMask*(hue: float; r: array[4, int]): float =
  ## How much a hue (degrees) is in range `r` (0..1).
  let c = floorMod(hue - r[0].float, 360.0)
  let ls = floorMod(float(r[1] - r[0]), 360.0)
  let cs = floorMod(float(r[2] - r[0]), 360.0)
  let rs = floorMod(float(r[3] - r[0]), 360.0)
  if c >= ls and c <= cs: 1.0
  elif c < ls: (if ls > 1e-6: c / ls else: 0.0)
  elif c <= rs: (if rs - cs > 1e-6: (rs - c) / (rs - cs) else: 0.0)
  else: 0.0

proc hueSaturation*(adj: HueAdjust; ranges = DefaultHueRanges): FilterFn =
  ## Hue/Saturation with the colors edited one range at a time, as
  ## Photoshop does it: Master lightness first (toward white or black),
  ## a range's lightness by how saturated a color is; the ranges are judged
  ## by the color as it was.
  result = mapFn3D(proc (p: uint32): uint32 =
    var r = rOf(p) / 255
    var g = gOf(p) / 255
    var b = bOf(p) / 255
    let ml = adj[0][2].float / 100
    if ml > 0:
      r = r * (1 - ml) + ml; g = g * (1 - ml) + ml; b = b * (1 - ml) + ml
    elif ml < 0:
      r *= 1 + ml; g *= 1 + ml; b *= 1 + ml
    let q = argb(aOf(p), int(round(r * 255)), int(round(g * 255)), int(round(b * 255)))
    var (h, sl, l) = toHsl(q)
    # what the ranges add
    var ch, cs, cl = 0.0
    for k in 1 .. 6:
      let a = adj[k]
      if a[0] == 0 and a[1] == 0 and a[2] == 0: continue
      let m = rangeMask(h, ranges[k - 1])
      if m <= 0: continue
      ch += a[0].float * m
      cl = clamp(cl + a[2].float / 100 * m, -1.0, 1.0)
      let sat = a[1].float / 100
      let contrib = if sat > 0: sat * (1 - pow(1 - m, 1.5 / (1 - pow(sat, 4) + 0.05))) else: sat * m
      cs = clamp(cs + contrib, -1.0, 1.0)
    if cl != 0:
      # (in HSV: a range's lightness)
      var v = l + sl * min(l, 1 - l)
      var sv = if v > 1e-6: 2 * (1 - l / v) else: 0.0
      if cl < 0: v = clamp(v * (1 + cl * sv), 0.0, 1.0)
      sv = if cl >= 0: clamp(sv * (1 - cl), 0.0, 1.0)
           else: (let dv = 1 / (sv + 1e-3); clamp(1 + (dv - 1) / (abs(cl) - dv + 1e-3), 0.0, 1.0))
      l = v * (1 - sv / 2)
      let den = min(l, 1 - l)
      sl = if den > 1e-6: (v - l) / den else: 0.0
    h = floorMod(h + ch + adj[0][0].float, 360.0)
    proc satApply(x, s: float): float =
      clamp(if s > 0: x / (1 - s + 0.01) else: x * (1 + s), 0.0, 1.0)
    sl = satApply(satApply(sl, adj[0][1].float / 100), cs)
    fromHsl(h, clamp(sl, 0.0, 1.0), clamp(l, 0.0, 1.0), aOf(p)))

type SelectiveColor* = array[9, array[4, int]]
  ## Selective Color: for the reds, yellows, greens, cyans, blues,
  ## magentas, whites, neutrals and blacks, how much more (or less) cyan,
  ## magenta, yellow and black (-100..100 %).

proc selectiveColor*(adj: SelectiveColor; relative = true): FilterFn =
  ## Image > Adjust > Selective Color: more or less of each printing ink in
  ## the colors chosen (`relative`: in proportion to what is there).
  result = mapFn3D(proc (p: uint32): uint32 =
    let r = rOf(p).float / 255
    let g = gOf(p).float / 255
    let b = bOf(p).float / 255
    let mx = max(r, max(g, b))
    let mn = min(r, min(g, b))
    let hsb = toHsb(p)
    var w: array[9, float]
    for k in 1 .. 6: w[k - 1] = rangeWeight(hsb.h, hsb.s, k) * (mx - mn)
    w[6] = clamp((mn - 0.5) * 2, 0.0, 1.0)                 # whites
    w[8] = clamp((0.5 - mx) * 2, 0.0, 1.0)                 # blacks
    w[7] = clamp(1 - (mx - mn) * 2, 0.0, 1.0) * (1 - abs(mx + mn - 1))   # neutrals
    var cmy = [1 - r, 1 - g, 1 - b]
    for k in 0 .. 8:
      if w[k] <= 0: continue
      let a = adj[k]
      if a[0] == 0 and a[1] == 0 and a[2] == 0 and a[3] == 0: continue
      for c in 0 .. 2:
        let have = cmy[c]
        let amount = (a[c] + a[3]).float / 100
        let delta = if relative: amount * have else: amount
        cmy[c] = clamp(have + delta * w[k], 0.0, 1.0)
    argb(aOf(p), int(round((1 - cmy[0]) * 255)), int(round((1 - cmy[1]) * 255)),
         int(round((1 - cmy[2]) * 255))))

proc invert*(): FilterFn =
  ## Image > Adjust > Invert: a negative (alpha kept).
  mapFn(proc (p: uint32): uint32 = argb(aOf(p), 255 - rOf(p), 255 - gOf(p), 255 - bOf(p)))

proc desaturate*(): FilterFn =
  ## Image > Adjust > Desaturate: the pixels' lightness as gray.
  mapFn(proc (p: uint32): uint32 = grayPx(lumaOf(p), aOf(p)))

proc threshold*(level: int): FilterFn =
  ## Image > Adjust > Threshold: white where the lightness is `level` or
  ## more, black elsewhere.
  mapFn(proc (p: uint32): uint32 = grayPx(if lumaOf(p) >= level: 255 else: 0, aOf(p)))

proc posterize*(levels: int): FilterFn =
  ## Image > Adjust > Posterize: `levels` levels for each channel (2..255).
  let n = clamp(levels, 2, 255)
  result = mapFn(proc (p: uint32): uint32 =
    # (as Photoshop does it: the 256 values cut in `n` equal runs, each the
    # level its run is at)
    template q(v: int): int = int(round(floor(v.float * n.float / 256) / (n - 1).float * 255))
    argb(aOf(p), q(rOf(p)), q(gOf(p)), q(bOf(p))))

proc equalize*(h: Histogram): FilterFn =
  ## Spreads the lightness levels evenly (by the image's histogram).
  var lut: Lut
  var acc = 0
  let n = max(1, h.total)
  var first = 0
  while first < 255 and h.counts[0][first] == 0: inc first
  for i in 0 .. 255:
    acc += h.counts[0][i]
    let base = h.counts[0][first]
    lut[i] = uint8(clamp(int(round((acc - base).float / max(1, n - base).float * 255)), 0, 255))
  result = mapFn(proc (p: uint32): uint32 =
    let l = lumaOf(p)
    let nl = int(lut[l])
    if l == 0: result = grayPx(nl, aOf(p)); return
    let k = nl.float / l.float
    argb(aOf(p), int(rOf(p).float * k), int(gOf(p).float * k), int(bOf(p).float * k)))

proc variations*(shifts: array[3, int]; lighter: int; saturation: int; tone: ToneRange): FilterFn =
  ## What Variations piles up: color shifts toward red, green, blue (-n
  ## toward cyan, magenta, yellow), lighter/darker and more/less saturation.
  var sh, mid, hi: array[3, int]
  case tone
  of trShadows: sh = shifts
  of trMidtones: mid = shifts
  of trHighlights: hi = shifts
  let cb = colorBalance(sh, mid, hi, false)
  let hs = hueSaturation(0, saturation, lighter)
  result = proc (src: Img; inner: Rect): Img = hs(cb(src, inner), inner)

proc colorRangeMask*(d: Doc; sample: uint32; fuzziness: int; merged = true): seq[uint8] =
  ## Select > Color Range: how close each pixel is to `sample` (within
  ## `fuzziness`, soft beyond it).
  if merged: d.updateComposite()
  result = newSeq[uint8](d.w * d.h)
  if (if merged: d.compPtr == nil else: d.layer.px.len < d.w * d.h): return
  let f = max(1, fuzziness).float
  let sp = if merged: d.compPtr else: pixPtr(d.layer.px)
  let rp = cast[ptr UncheckedArray[uint8]](addr result[0])
  let sr = rOf(sample)
  let sg = gOf(sample)
  let sb = bOf(sample)
  parallelFor(d.w * d.h, proc (lo, hi: int) =
    for i in lo ..< hi:
      let p = sp[i]
      let dr = rOf(p) - sr
      let dg = gOf(p) - sg
      let db = bOf(p) - sb
      let dd = sqrt(float(dr * dr + dg * dg + db * db)) / 1.2
      rp[i] = uint8(clamp(int(round((1 - dd / f) * 255 * 1.6)), 0, 255)), grain = 4096)

proc replaceColor*(mask: seq[uint8]; hue, saturation, lightness: int): proc (d: Doc) =
  ## Image > Adjust > Replace Color: Hue/Saturation where `mask` is.
  result = proc (d: Doc) =
    let f = hueSaturation(hue, saturation, lightness)
    let L = d.layer
    let r = d.workRect
    d.touch(L, r)
    var one = newImg(1, 1)
    for y in r.y ..< r.y + r.h:
      for x in r.x ..< r.x + r.w:
        let i = y * d.w + x
        let m = int(mask[i])
        if m == 0 or d.selAt(i) == 0: continue
        one.px[0] = L.px[i]
        let after = f(one, rect(0, 0, 1, 1)).px[0]
        L.px[i] = d.applyAt(L, i, L.px[i], after, m)
    inc L.ver
    d.markDirty(r)

# ---- Gradient Map, Color Lookup ------------------------------------------------------------------------------

proc gradientMap*(stops: seq[GradientStop]; reverse = false; dither = false): FilterFn =
  ## Image > Adjust > Gradient Map: each pixel's lightness becomes the
  ## gradient's color there (its alpha kept).
  var table: array[256, uint32]
  for k in 0 .. 255:
    let t = k / 255
    table[k] = gradientColor(stops, if reverse: 1 - t else: t)
  mapFn(proc (p: uint32): uint32 =
    let l = (rOf(p) * 77 + gOf(p) * 151 + bOf(p) * 28) shr 8
    let c = table[l]
    (p and 0xFF000000'u32) or (c and 0xFFFFFF'u32))

proc gradientMapArgs*(stops: seq[GradientStop]; reverse = false; dither = false): seq[float] =
  ## A gradient map's settings as an adjustment layer keeps them: reverse,
  ## dither, the number of stops, then each: where, alpha, red, green,
  ## blue, midpoint.
  result = @[(if reverse: 1.0 else: 0.0), (if dither: 1.0 else: 0.0), stops.len.float]
  for s in stops:
    result.add [s.at, aOf(s.color).float, rOf(s.color).float, gOf(s.color).float, bOf(s.color).float, s.mid]

proc gradientMapOf*(args: seq[float]): tuple[stops: seq[GradientStop]; reverse, dither: bool] =
  ## A gradient map's settings back from `gradientMapArgs` (black to white
  ## when there are no stops).
  template at(i: int): float = (if i < args.len: args[i] else: 0.0)
  result.reverse = at(0) != 0
  result.dither = at(1) != 0
  let n = clamp(int(at(2)), 0, 64)
  for k in 0 ..< n:
    let b = 3 + k * 6
    result.stops.add GradientStop(at: clamp(at(b), 0.0, 1.0),
                                  color: argb(int(at(b + 1)), int(at(b + 2)), int(at(b + 3)), int(at(b + 4))),
                                  mid: at(b + 5))
  if result.stops.len == 0:
    result.stops = @[GradientStop(at: 0, color: 0xFF000000'u32), GradientStop(at: 1, color: 0xFFFFFFFF'u32)]

type CubeLut* = object
  ## A 3D color table (a .cube file): `n`^3 colors, red fastest, 0..1.
  n*: int                     ## points along each side
  data*: seq[float32]         ## R G B of each point
  lo*, hi*: array[3, float32] ## the input's range for each channel (DOMAIN_MIN, DOMAIN_MAX)
  oneD*: bool                 ## a 1D table: `n` steps of each channel

proc parseCube*(text: string): CubeLut =
  ## A .cube file (Adobe / Resolve): LUT_3D_SIZE or LUT_1D_SIZE, then the
  ## colors. Raises `ValueError` when it is not one.
  result.hi = [1'f32, 1, 1]
  var vals: seq[float32]
  for raw in text.splitLines:
    let line = raw.strip
    if line.len == 0 or line[0] == '#': continue
    let parts = line.splitWhitespace
    case parts[0].toUpperAscii
    of "LUT_3D_SIZE":
      result.n = parseInt(parts[1])
    of "LUT_1D_SIZE":
      result.n = parseInt(parts[1])
      result.oneD = true
    of "DOMAIN_MIN":
      for k in 0 .. 2: result.lo[k] = parseFloat(parts[k + 1]).float32
    of "DOMAIN_MAX":
      for k in 0 .. 2: result.hi[k] = parseFloat(parts[k + 1]).float32
    of "TITLE", "LUT_3D_INPUT_RANGE", "LUT_1D_INPUT_RANGE": discard
    else:
      if parts.len >= 3 and parts[0][0] in {'0'..'9', '-', '.', '+'}:
        for k in 0 .. 2: vals.add parseFloat(parts[k]).float32
  if result.n < 2 or result.n > 256: raise newException(ValueError, "not a .cube color table")
  let want = if result.oneD: result.n * 3 else: result.n * result.n * result.n * 3
  if vals.len < want: raise newException(ValueError, "a .cube table with too few colors")
  vals.setLen(want)
  result.data = vals

proc cubeFn*(c: CubeLut): FilterFn =
  ## A color table as an adjustment (read between its colors).
  let n = c.n
  let data = c.data
  let lo = c.lo
  let hi = c.hi
  if c.oneD:
    var t: array[3, array[256, uint8]]
    for ch in 0 .. 2:
      for v in 0 .. 255:
        let x = clamp((v / 255 - lo[ch]) / max(1e-6, hi[ch] - lo[ch]), 0.0, 1.0) * float(n - 1)
        let i0 = min(int(x), n - 2)
        let f = x - i0.float
        let y = data[i0 * 3 + ch] * (1 - f) + data[(i0 + 1) * 3 + ch] * f
        t[ch][v] = uint8(clamp(int(round(y * 255)), 0, 255))
    return mapFn(proc (p: uint32): uint32 =
      argb(aOf(p), int(t[0][rOf(p)]), int(t[1][gOf(p)]), int(t[2][bOf(p)])))
  mapFn3D(proc (p: uint32): uint32 =
    var q: array[3, float]
    for ch, v in [rOf(p), gOf(p), bOf(p)]:
      q[ch] = clamp((v / 255 - lo[ch]) / max(1e-6, hi[ch] - lo[ch]), 0.0, 1.0) * float(n - 1)
    let r0 = min(int(q[0]), n - 2)
    let g0 = min(int(q[1]), n - 2)
    let b0 = min(int(q[2]), n - 2)
    let fr = q[0] - r0.float
    let fg = q[1] - g0.float
    let fb = q[2] - b0.float
    var o: array[3, float]
    for ch in 0 .. 2:
      template at(r, g, b: int): float = data[((b * n + g) * n + r) * 3 + ch].float
      let c00 = at(r0, g0, b0) * (1 - fr) + at(r0 + 1, g0, b0) * fr
      let c10 = at(r0, g0 + 1, b0) * (1 - fr) + at(r0 + 1, g0 + 1, b0) * fr
      let c01 = at(r0, g0, b0 + 1) * (1 - fr) + at(r0 + 1, g0, b0 + 1) * fr
      let c11 = at(r0, g0 + 1, b0 + 1) * (1 - fr) + at(r0 + 1, g0 + 1, b0 + 1) * fr
      let c0 = c00 * (1 - fg) + c10 * fg
      let c1 = c01 * (1 - fg) + c11 * fg
      o[ch] = c0 * (1 - fb) + c1 * fb
    argb(aOf(p), clamp(int(round(o[0] * 255)), 0, 255), clamp(int(round(o[1] * 255)), 0, 255),
         clamp(int(round(o[2] * 255)), 0, 255)))

const LookNames* = ["Warm", "Cool", "Teal & Orange", "Film Stock", "Bleach Bypass", "Faded", "Vintage",
                    "Cross Process", "Sepia", "Night", "Black & White Film", "High Contrast", "Soft Pastel"]
  ## The color looks Color Lookup has of its own (as well as .cube files).

proc lookSCurve(v, k: float): float =
  ## (contrast round the middle: k 0 none, 1 strong)
  let t = clamp(v, 0.0, 1.0)
  let s = t * t * (3 - 2 * t)
  t + (s - t) * k

proc lookLuma(r, g, b: float): float = 0.299 * r + 0.587 * g + 0.114 * b

proc lookSat(r, g, b: var float; k: float) =
  let l = lookLuma(r, g, b)
  r = l + (r - l) * k
  g = l + (g - l) * k
  b = l + (b - l) * k

proc applyLook(name: string; r, g, b: var float) =
  template curve3(k: float) =
    r = lookSCurve(r, k)
    g = lookSCurve(g, k)
    b = lookSCurve(b, k)
  case name
  of "Warm":
    r = r * 1.07 + 0.01
    g = g * 1.01
    b = b * 0.88
  of "Cool":
    r = r * 0.9
    g = g * 0.98 + 0.01
    b = b * 1.08 + 0.02
  of "Teal & Orange":
    let l = lookLuma(r, g, b)
    let sh = clamp(1 - l * 1.6, 0.0, 1.0)
    let hl = clamp(l * 1.6 - 0.6, 0.0, 1.0)
    r = r - 0.08 * sh + 0.10 * hl
    g = g + 0.03 * sh + 0.03 * hl
    b = b + 0.10 * sh - 0.10 * hl
    lookSat(r, g, b, 1.15)
    curve3(0.35)
  of "Film Stock":
    r = 0.04 + lookSCurve(r, 0.45) * 0.93
    g = 0.03 + lookSCurve(g, 0.4) * 0.94
    b = 0.06 + lookSCurve(b, 0.35) * 0.88
    lookSat(r, g, b, 0.9)
  of "Bleach Bypass":
    lookSat(r, g, b, 0.45)
    curve3(0.7)
  of "Faded":
    lookSat(r, g, b, 0.75)
    r = 0.10 + r * 0.82
    g = 0.10 + g * 0.82
    b = 0.12 + b * 0.80
  of "Vintage":
    lookSat(r, g, b, 0.7)
    let l = lookLuma(r, g, b)
    r = 0.08 + r * 0.86 + 0.04 * l
    g = 0.07 + g * 0.84 + 0.03 * (1 - l)
    b = 0.05 + b * 0.72
    curve3(0.25)
  of "Cross Process":
    r = lookSCurve(r, 0.8)
    g = lookSCurve(g, 0.45) * 1.03
    b = 0.18 + b * 0.62
  of "Sepia":
    let l = lookLuma(r, g, b)
    r = l * 1.07 + 0.04
    g = l * 0.92 + 0.02
    b = l * 0.72
  of "Night":
    lookSat(r, g, b, 0.55)
    r = r * 0.55
    g = g * 0.7 + 0.02
    b = b * 0.95 + 0.06
    curve3(0.3)
  of "Black & White Film":
    let v = lookSCurve(clamp(0.45 * r + 0.45 * g + 0.10 * b, 0.0, 1.0), 0.55)
    r = v
    g = v
    b = v
  of "High Contrast":
    curve3(1.0)
    curve3(0.6)
    lookSat(r, g, b, 1.1)
  of "Soft Pastel":
    lookSat(r, g, b, 0.6)
    r = 0.15 + r * 0.85
    g = 0.14 + g * 0.85
    b = 0.16 + b * 0.84
  else: discard

proc lookFn*(name: string): FilterFn =
  ## One of the looks of `LookNames`.
  mapFn3D(proc (p: uint32): uint32 =
    var r = rOf(p) / 255
    var g = gOf(p) / 255
    var b = bOf(p) / 255
    applyLook(name, r, g, b)
    argb(aOf(p), clamp(int(round(r * 255)), 0, 255), clamp(int(round(g * 255)), 0, 255),
         clamp(int(round(b * 255)), 0, 255)))

proc colorLookup*(data: string): FilterFn =
  ## Image > Adjust > Color Lookup: a look ("look:Name", `LookNames`) or a
  ## .cube file's text ("cube:..."). nil when it is not one.
  if data.startsWith("look:"): return lookFn(data[5 .. ^1])
  if data.startsWith("cube:"):
    try: return cubeFn(parseCube(data[5 .. ^1]))
    except ValueError: return nil
  nil
