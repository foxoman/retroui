## Tests of the four-lanes-at-a-time kernels (retroui/simd): each gives what the plain loop it
## stands for gives -- the layers' mix exactly, the blurs and resampling within a level.

import std/[random, math, algorithm]
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

proc refAmt(op: int; mk, b, bm, cv: uint32; hasMask, hasBase, hasBm, hasCover, blut, bif: bool; ch: int;
            this, under: array[4, int]; s, d: uint32): int =
  ## (a pixel's amount as mixLayers' plain loop works it out)
  var a = op
  if hasMask: a = a * int((mk shr 16) and 255) div 255
  if hasCover: a = a * int(cv) div 255
  elif hasBase:
    var ba = int(b shr 24)
    if blut: ba = int((b shr 16) and 255) * ba div 255
    if hasBm: ba = ba * int((bm shr 16) and 255) div 255
    a = a * ba div 255
  if bif: a = a * rangeAmt(this, chanOf(s, ch)) div 255 * rangeAmt(under, chanOf(d, ch)) div 255
  a

block mixWithMaskClipBlendIf:
  # masked, clipped (to a layer, its mask, an adjustment; to a group), Blend If: the kernel gives
  # what the plain loop gives, where what is under is opaque; it stops where it is not
  for trial in 0 ..< 400:
    let n = [1, 3, 4, 5, 8, 9, 16, 33, 64][trial mod 9]
    let hasMask = r.rand(1) == 0
    let hasCover = r.rand(3) == 0
    let hasBase = not hasCover and r.rand(1) == 0
    let hasBm = hasBase and r.rand(1) == 0
    let blut = hasBase and r.rand(2) == 0
    let bif = r.rand(1) == 0
    let ch = r.rand(3)
    let op = [255, 230, 128, 7][r.rand(3)]
    let m = [bmNormal, bmMultiply, bmScreen, bmOverlay][r.rand(3)]
    let lut = sepLut(m)
    var this = [0, 0, 255, 255]
    var under = [0, 0, 255, 255]
    if bif:
      let t0 = r.rand(100)
      this = [t0, t0 + r.rand(50), 150 + r.rand(50), 210 + r.rand(45)]
      let u0 = r.rand(100)
      under = [u0, u0 + r.rand(60), 160 + r.rand(40), 220 + r.rand(35)]
    var thisT, underT: array[256, uint8]
    for v in 0 .. 255:
      thisT[v] = uint8(rangeAmt(this, v))
      underT[v] = uint8(rangeAmt(under, v))
    var dst, src, mk, b, bm, cv: seq[uint32]
    for i in 0 ..< n:
      dst.add rnd(i != n div 2 or trial mod 5 != 0)
      src.add rnd(false)
      mk.add 0xFF000000'u32 or uint32(r.rand(255)) * 0x010101'u32
      b.add rnd(false)
      bm.add 0xFF000000'u32 or uint32(r.rand(255)) * 0x010101'u32
      cv.add uint32(r.rand(255))
    template pa(sq: seq[uint32]): ptr UncheckedArray[uint32] = cast[ptr UncheckedArray[uint32]](addr sq[0])
    var o = MixOpt(mask: (if hasMask: pa(mk) else: nil), cover: (if hasCover: pa(cv) else: nil),
                   base: (if hasBase: pa(b) else: nil), bmask: (if hasBm: pa(bm) else: nil),
                   blut: cint(ord(blut)), bif: cint(ord(bif)), ch: cint(ch),
                   thisT: cast[ptr UncheckedArray[uint8]](addr thisT[0]),
                   underT: cast[ptr UncheckedArray[uint8]](addr underT[0]))
    var want = dst
    var wantStop = n
    for i in 0 ..< n:
      let s = src[i]
      if (s shr 24) == 0: continue
      let a = refAmt(op, mk[i], b[i], bm[i], cv[i], hasMask, hasBase, hasBm, hasCover, blut, bif, ch,
                     this, under, s, want[i])
      if a <= 0: continue
      if (want[i] shr 24) != 255:
        wantStop = i
        break
      let ea = a * int(s shr 24) div 255
      if ea > 0: want[i] = overOpaque(want[i], s, ea, lut)
    for wide in [0, 1]:
      if wide == 1 and hasAvx2() == 0: continue
      forceAvx2(cint(wide))
      var got = dst
      let stop = mixOpt(pa(got), pa(src), 0, n, op, lut, addr o)
      doAssert stop == wantStop, $trial & " stop " & $stop & " want " & $wantStop
      for i in 0 ..< wantStop: doAssert got[i] == want[i], $trial & " at " & $i
    forceAvx2(-1)

block eightLanesAsFour:
  # with AVX2 the same pixels and the same blur as with four lanes
  if hasAvx2() == 1:
    for trial in 0 ..< 50:
      let n = 1 + r.rand(70)
      var dst, src: seq[uint32]
      for i in 0 ..< n:
        dst.add rnd(r.rand(9) != 0)
        src.add rnd(false)
      let lut = sepLut([bmNormal, bmScreen][trial mod 2])
      var a4 = dst
      var a8 = dst
      forceAvx2(0)
      var x = 0
      while x < n:
        x = mixOpaque(cast[ptr UncheckedArray[uint32]](addr a4[0]), cast[ptr UncheckedArray[uint32]](addr src[0]), x, n, 200, lut) + 1
      forceAvx2(1)
      x = 0
      while x < n:
        x = mixOpaque(cast[ptr UncheckedArray[uint32]](addr a8[0]), cast[ptr UncheckedArray[uint32]](addr src[0]), x, n, 200, lut) + 1
      doAssert a4 == a8
    let w = 77
    let h = 31
    var px = newSeq[uint32](w * h)
    for i in 0 ..< px.len: px[i] = rnd(false)
    forceAvx2(0)
    let g4 = gaussianBlurImg(Img(w: w, h: h, px: px), 5.0)
    forceAvx2(1)
    let g8 = gaussianBlurImg(Img(w: w, h: h, px: px), 5.0)
    forceAvx2(-1)
    doAssert g4.px == g8.px

proc refLutAt(lut: seq[uint32]; p: uint32): uint32 =
  ## (photo's lutAt, the plain way)
  const n = LutN - 1
  let r = int((p shr 16) and 255) * n
  let g = int((p shr 8) and 255) * n
  let b = int(p and 255) * n
  let ri = r div 255
  let gi = g div 255
  let bi = b div 255
  let rf = r - ri * 255
  let gf = g - gi * 255
  let bf = b - bi * 255
  let r1 = min(ri + 1, n)
  let g1 = min(gi + 1, n)
  let b1 = min(bi + 1, n)
  template at(i, j, k: int): uint32 = lut[(i * LutN + j) * LutN + k]
  var o: array[3, int]
  for c in 0 .. 2:
    let sh = 16 - 8 * c
    template v(i, j, k: int): int = int((at(i, j, k) shr sh) and 255)
    let c00 = v(ri, gi, bi) * (255 - bf) + v(ri, gi, b1) * bf
    let c01 = v(ri, g1, bi) * (255 - bf) + v(ri, g1, b1) * bf
    let c10 = v(r1, gi, bi) * (255 - bf) + v(r1, gi, b1) * bf
    let c11 = v(r1, g1, bi) * (255 - bf) + v(r1, g1, b1) * bf
    let c0 = c00 * (255 - gf) + c01 * gf
    let c1 = c10 * (255 - gf) + c11 * gf
    o[c] = int((int64(c0) * (255 - rf) + int64(c1) * rf + 255 * 255 * 255 div 2) div (255 * 255 * 255))
  (p and 0xFF000000'u32) or (uint32(o[0]) shl 16) or (uint32(o[1]) shl 8) or uint32(o[2])

proc refInk(t: seq[uint32]; p: uint32): uint32 =
  ## (photoinks' lookup, the plain way)
  const N = 33
  const n = N - 1
  let r = int((p shr 16) and 255) * n
  let g = int((p shr 8) and 255) * n
  let b = int(p and 255) * n
  let ri = min(r div 255, n - 1)
  let gi = min(g div 255, n - 1)
  let bi = min(b div 255, n - 1)
  let rf = r - ri * 255
  let gf = g - gi * 255
  let bf = b - bi * 255
  let i000 = (ri * N + gi) * N + bi
  for sh in [24, 16, 8, 0]:
    template v(i: int): int = int((t[i] shr sh) and 255)
    let c00 = v(i000) * (255 - bf) + v(i000 + 1) * bf
    let c01 = v(i000 + N) * (255 - bf) + v(i000 + N + 1) * bf
    let c10 = v(i000 + N * N) * (255 - bf) + v(i000 + N * N + 1) * bf
    let c11 = v(i000 + N * N + N) * (255 - bf) + v(i000 + N * N + N + 1) * bf
    let c0 = c00 * (255 - gf) + c01 * gf
    let c1 = c10 * (255 - gf) + c11 * gf
    let c = (c0 div 255 * (255 - rf) + c1 div 255 * rf + 255 * 127) div (255 * 255)
    result = result or (uint32(clamp(c, 0, 255)) shl sh)

block colorTables:
  # a color through a table of colors: the same whole numbers as the plain way, every corner
  # case of the table's cells (0, 255, values just past a grid line)
  var t = newSeq[uint32](LutN * LutN * LutN)
  for trial in 0 ..< 3:
    for i in 0 ..< t.len:
      t[i] = if trial == 0: 0xFFFFFFFF'u32 elif trial == 1: uint32(i) * 2654435761'u32 else: rnd(false)
    let tp = cast[ptr UncheckedArray[uint32]](addr t[0])
    var ps = @[0'u32, 0xFFFFFFFF'u32, 0xFF808080'u32, 0x00070809'u32, 0x80F8F9FA'u32]
    for i in 0 ..< 20000: ps.add uint32(r.rand(high(int32))) * 2'u32 + uint32(r.rand(1))
    for p in ps:
      doAssert lutAdj(tp, LutN, p) == refLutAt(t, p), $trial & " " & $p
      doAssert lutInk(tp, LutN, p) == refInk(t, p), $trial & " " & $p

proc refSetSat(r, g, b: var float; s: float) =
  ## (the old setSat: a sort)
  var c = [r, g, b]
  var idx = [0, 1, 2]
  idx.sort(proc (i, j: int): int = cmp(c[i], c[j]))
  let (mn, md, mx) = (idx[0], idx[1], idx[2])
  if c[mx] > c[mn]:
    c[md] = (c[md] - c[mn]) * s / (c[mx] - c[mn])
    c[mx] = s
  else:
    c[md] = 0; c[mx] = 0
  c[mn] = 0
  r = c[0]; g = c[1]; b = c[2]

block saturationAsSorted:
  # Hue and Saturation (setSat without a sort): the same as with one, ties too
  let vals = [0.0, 0.25, 0.5, 0.5, 1.0, 0.1, 0.9]
  for a in vals:
    for b in vals:
      for c in vals:
        for sv in [0.0, 0.3, 1.0]:
          var (r1, g1, b1) = (a, b, c)
          var (r2, g2, b2) = (a, b, c)
          setSat(r1, g1, b1, sv)
          refSetSat(r2, g2, b2, sv)
          doAssert r1 == r2 and g1 == g2 and b1 == b2, $(a, b, c, sv)

echo "test_simd: ok (", (if simdOn: "kernels" else: "plain loops"), ")"
