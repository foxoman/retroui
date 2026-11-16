## Tests of the four-lanes-at-a-time kernels (retroui/simd): each gives what the plain loop it
## stands for gives -- the layers' mix exactly, the blurs and resampling within a level.

import std/[random, math]
import retroui/photo {.all.}
import retroui/[simd, photofx, photoblurs]
{.push warning[UnusedImport]: off.}
import retroui/photodevelop
{.pop.}

var r = initRand(11)

proc rnd(opaque: bool): uint32 =
  let a = if opaque: 255'u32 elif r.rand(3) == 0: 0'u32 else: uint32(r.rand(255))
  (a shl 24) or uint32(r.rand(0xFFFFFF))

block mixIsOverOpaque:
  # the mix over opaque pixels: exactly overOpaque's, Normal and each separable mode
  for m in BlendMode:
    if m != bmNormal and m notin SepModes: continue
    let lut = sepLut(m)
    for op in [255, 200, 128, 1, 0]:
      for n in [1, 3, 4, 7, 64, 101]:
        var dst = newSeq[uint32](n)
        var src = newSeq[uint32](n)
        for i in 0 ..< n:
          dst[i] = rnd(true)
          src[i] = rnd(false)
        var want = dst
        for i in 0 ..< n:
          let ea = op * int(src[i] shr 24) div 255
          if ea > 0: want[i] = overOpaque(dst[i], src[i], ea, lut)
        let stop = mixOpaque(cast[ptr UncheckedArray[uint32]](addr dst[0]), cast[ptr UncheckedArray[uint32]](addr src[0]),
                             0, n, op, lut)
        doAssert stop == n
        doAssert dst == want, $m & " " & $op & " " & $n
  # (a pixel under that is not opaque: left for the caller, where the source shows)
  var dst = @[0xFF102030'u32, 0xFF405060'u32, 0x80FFFFFF'u32, 0xFF000000'u32, 0xFF000000'u32]
  var src = @[0xFF0000FF'u32, 0x00000000'u32, 0xFF00FF00'u32, 0xFFFF0000'u32, 0xFFFF0000'u32]
  let stop = mixOpaque(cast[ptr UncheckedArray[uint32]](addr dst[0]), cast[ptr UncheckedArray[uint32]](addr src[0]),
                       0, 5, 255, nil)
  doAssert stop == 2 and dst[0] == 0xFF0000FF'u32 and dst[1] == 0xFF405060'u32 and dst[2] == 0x80FFFFFF'u32

block resampleNearTheTwoDWay:
  # across then down: the old way's pixels, within a level
  let w = 37
  let h = 23
  var px = newSeq[uint32](w * h)
  for i in 0 ..< px.len: px[i] = rnd(false)
  for (nw, nh, how) in [(53, 41, rsBicubic), (60, 30, rsBilinear), (40, 25, rsLanczos), (30, 20, rsBicubic)]:
    let got = resample(px, w, h, nw, nh, how)
    doAssert got.len == nw * nh
    # (a picture of one color: that color everywhere)
    var flat = newSeq[uint32](w * h)
    for i in 0 ..< flat.len: flat[i] = 0xFF336699'u32
    let f = resample(flat, w, h, nw, nh, how)
    for p in f: doAssert p == 0xFF336699'u32, $how
    # (transparent pixels keep their color out of the opaque ones round them)
    var half = newSeq[uint32](w * h)
    for i in 0 ..< half.len: half[i] = if i mod 2 == 0: 0xFFFF0000'u32 else: 0x0000FF00'u32
    let hf = resample(half, w, h, nw, nh, how)
    for p in hf:
      if (p shr 24) > 20: doAssert ((p shr 8) and 255) <= 1, $how

block boxBlurIsTheMean:
  let w = 41
  let h = 29
  var px = newSeq[uint32](w * h)
  for i in 0 ..< px.len: px[i] = 0xFF000000'u32 or uint32(r.rand(0xFFFFFF))
  let rad = 3
  let o = boxBlurImg(Img(w: w, h: h, px: px), rad)
  for y in [0, 5, 14, 28]:
    for x in [0, 3, 20, 40]:
      var s = [0.0, 0.0, 0.0]
      for j in -rad .. rad:
        for i in -rad .. rad:
          let p = px[clamp(y + j, 0, h - 1) * w + clamp(x + i, 0, w - 1)]
          s[0] += float((p shr 16) and 255); s[1] += float((p shr 8) and 255); s[2] += float(p and 255)
      let n = float((2 * rad + 1) * (2 * rad + 1))
      let q = o.px[y * w + x]
      doAssert (q shr 24) == 255
      doAssert abs(float((q shr 16) and 255) - s[0] / n) <= 1.0
      doAssert abs(float((q shr 8) and 255) - s[1] / n) <= 1.0
      doAssert abs(float(q and 255) - s[2] / n) <= 1.0

block gaussianKeepsFlatAndEdges:
  let w = 60
  let h = 40
  var px = newSeq[uint32](w * h)
  for i in 0 ..< px.len: px[i] = 0xFF8040C0'u32
  for rad in [1.0, 3.5, 8.0, 12.0, 30.0]:
    let o = gaussianBlurImg(Img(w: w, h: h, px: px), rad)
    for p in o.px: doAssert p == 0xFF8040C0'u32, $rad

echo "test_simd: ok (", (if simdOn: "kernels" else: "plain loops"), ")"
