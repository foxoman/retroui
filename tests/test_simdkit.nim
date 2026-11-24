## Tests of the kit's own several-pixels-at-a-time loops (retroui/simdkit): each gives the very
## pixels of the plain loop it stands for, with AVX2 and without, every length and offset.

import std/random
import retroui/simdkit

var r = initRand(7)

proc blendRef(q, c, a: uint32): uint32 =
  # (gfx.nim's blend, as it is)
  let na = 255'u32 - a
  var rb = (c and 0xFF00FF'u32) * a + (q and 0xFF00FF'u32) * na + 0x800080'u32
  rb = ((rb + ((rb shr 8) and 0xFF00FF'u32)) shr 8) and 0xFF00FF'u32
  var gg = (c and 0xFF00'u32) * a + (q and 0xFF00'u32) * na + 0x8000'u32
  gg = ((gg + ((gg shr 8) and 0xFF00'u32)) shr 8) and 0xFF00'u32
  rb or gg

proc px(): uint32 = (uint32(r.rand(0xFFFF)) shl 16) or uint32(r.rand(0xFFFF))

proc alphaPx(): uint32 =
  let a = case r.rand(3)
          of 0: 0'u32
          of 1: 255'u32
          else: uint32(r.rand(255))
  (a shl 24) or (px() and 0xFFFFFF'u32)

let lengths = [0, 1, 2, 3, 4, 5, 7, 8, 15, 16, 17, 31, 33, 64, 100, 257]

for avx in [0'i32, 1]:
  kitForceAvx2(avx)

  block fills:
    for n in lengths:
      for off in 0 .. 3:
        var a = newSeq[uint32](n + 8)
        for i in 0 ..< a.len: a[i] = px()
        var want = a
        let c = px()
        for i in 0 ..< n: want[off + i] = c
        if n > 0: fill32(addr a[off], n, c)
        doAssert a == want, "fill " & $n

  block glyphCoverage:
    var lut: array[256, uint8]
    for i in 0 .. 255: lut[i] = uint8(min(255, i + i div 3))
    for useLut in [false, true]:
      for n in lengths:
        var fp = newSeq[uint32](n + 1)
        var m = newSeq[uint8](n + 1)
        for i in 0 ..< fp.len:
          fp[i] = px()
          m[i] = case r.rand(3)
                 of 0: 0'u8
                 of 1: 255'u8
                 else: uint8(r.rand(255))
        # (runs of nothing and of everything, as a glyph has)
        if n >= 8:
          for i in 0 ..< 4: m[i] = 0
          for i in 4 ..< 8: m[i] = 255
        let col = px()
        var want = fp
        for i in 0 ..< n:
          var a = uint32(m[i])
          if a == 0: continue
          if useLut: a = lut[a]
          want[i] = if a >= 255: col else: blendRef(want[i], col, a)
        if n > 0:
          blendMaskRow(addr fp[0], addr m[0], n, col, if useLut: addr lut[0] else: nil)
        doAssert fp == want, "coverage " & $n & " lut " & $useLut
    # every coverage, through no table and through one that makes some of them nothing and
    # others full early -- under pixels and colors of every kind (the kernel in 16-bit lanes)
    var lut2: array[256, uint8]
    for i in 0 .. 255: lut2[i] = uint8(if i < 6: 0 elif i > 200: 255 else: (i - 6) * 255 div 195)
    for useLut in 0 .. 2:
      for trial in 0 ..< 200:
        var fp = newSeq[uint32](256)
        var m = newSeq[uint8](256)
        for i in 0 ..< 256:
          fp[i] = px()
          m[i] = uint8((i + trial * 37) mod 256)
        let col = if trial mod 7 == 0: 0xFFFFFFFF'u32 elif trial mod 7 == 1: 0'u32 else: px()
        let t = case useLut
                of 1: addr lut[0]
                of 2: addr lut2[0]
                else: nil
        var want = fp
        for i in 0 ..< 256:
          var a = uint32(m[i])
          if a == 0: continue
          if t != nil: a = cast[ptr UncheckedArray[uint8]](t)[a]
          want[i] = if a >= 255: col else: blendRef(want[i], col, a)
        blendMaskRow(addr fp[0], addr m[0], 256, col, t)
        doAssert fp == want, "every coverage, table " & $useLut & " trial " & $trial

  block constCoverage:
    # (one coverage for a whole span -- a see-through card: the values of the mask's kernel)
    for n in lengths:
      for a in [0'u32, 1, 7, 100, 128, 150, 254, 255]:
        var fp = newSeq[uint32](n + 1)
        for i in 0 ..< fp.len: fp[i] = px()
        let col = px() and 0xFFFFFF'u32
        var want = fp
        var m = newSeq[uint8](n + 1)
        for i in 0 ..< n: m[i] = uint8(a)
        if n > 0: blendMaskRow(addr want[0], addr m[0], n, col, nil)
        if n > 0: blendConstRow(addr fp[0], n, col, a)
        doAssert fp == want, "one coverage " & $a & " over " & $n

  block pictureOver:
    for n in lengths:
      var fp = newSeq[uint32](n + 1)
      var sp = newSeq[uint32](n + 1)
      for i in 0 ..< fp.len:
        fp[i] = px()
        sp[i] = alphaPx()
      if n >= 12:
        for i in 0 ..< 4: sp[i] = sp[i] or 0xFF000000'u32
        for i in 4 ..< 8: sp[i] = sp[i] and 0xFFFFFF'u32
      var want = fp
      for i in 0 ..< n:
        let p = sp[i]
        let a = p shr 24
        if a == 255: want[i] = p and 0xFFFFFF'u32
        elif a != 0: want[i] = blendRef(want[i], p, a)
      if n > 0: overRow(addr fp[0], addr sp[0], n)
      doAssert fp == want, "over " & $n

  block widened:
    for k in 1 .. 4:
      for n in lengths:
        var src = newSeq[uint32](n + 1)
        for i in 0 ..< src.len: src[i] = px()
        var dst = newSeq[uint32](n * k + 1)
        var want = dst
        for i in 0 ..< n:
          for j in 0 ..< k: want[i * k + j] = src[i] and 0xFFFFFF'u32
        if n > 0: widenRow(addr dst[0], addr src[0], n, cint(k))
        doAssert dst == want, "widen " & $n & " x" & $k

  block zoomedRow:
    for n in lengths:
      let w = 50
      var src = newSeq[uint32](w)
      for i in 0 ..< w: src[i] = if r.rand(9) == 0: alphaPx() else: px() or 0xFF000000'u32
      var xs = newSeq[int32](n + 1)
      for i in 0 ..< xs.len: xs[i] = if r.rand(30) == 0: -1'i32 else: int32(r.rand(w - 1))
      var dst = newSeq[uint32](n + 1)
      var want = dst
      var stop = 0
      while stop < n and xs[stop] >= 0 and src[xs[stop]] >= 0xFF000000'u32:
        want[stop] = src[xs[stop]]
        inc stop
      let got = if n > 0: gatherOpaque(addr dst[0], addr src[0], addr xs[0], n) else: 0
      doAssert got == stop, "gather " & $n & ": " & $got & " not " & $stop
      doAssert dst == want, "gather " & $n

  block alphaExtents:
    # (where a layer has something, a row at a time: the first and the last pixel with alpha)
    for n in lengths:
      var row = newSeq[uint32](n + 1)
      for i in 0 ..< n:
        row[i] = if r.rand(3) == 0: (px() and 0x00FFFFFF'u32) or (uint32(r.rand(1 .. 255)) shl 24)
                 else: px() and 0x00FFFFFF'u32
      if n > 0 and r.rand(4) == 0:
        for i in 0 ..< n: row[i] = row[i] and 0x00FFFFFF'u32      # (nothing in it)
      var first = n
      for i in 0 ..< n:
        if (row[i] shr 24) != 0: (first = i; break)
      var last = -1
      for i in countdown(n - 1, 0):
        if (row[i] shr 24) != 0: (last = i; break)
      let f = if n > 0: firstAlpha(addr row[0], n) else: 0
      let l = if n > 0: lastAlpha(addr row[0], n) else: -1
      doAssert f == first and l == last, "alpha extents " & $n & ": " & $f & ", " & $l & " not " & $first & ", " & $last

  block jpegIdct:
    # (the 64-bit loop of jpeg.nim, here as it is)
    proc idctRef(blk: array[64, int32]; o: var array[64, uint8]) =
      template one(s0, s1, s2, s3, s4, s5, s6, s7: int64; t0, t1, t2, t3, x0, x1, x2, x3: untyped) =
        var t0, t1, t2, t3, x0, x1, x2, x3: int64
        block:
          var p2 = s2
          var p3 = s6
          var p1 = (p2 + p3) * 2217
          t2 = p1 + p3 * -7567
          t3 = p1 + p2 * 3135
          p2 = s0
          p3 = s4
          t0 = (p2 + p3) * 4096
          t1 = (p2 - p3) * 4096
          x0 = t0 + t3; x3 = t0 - t3; x1 = t1 + t2; x2 = t1 - t2
          t0 = s7; t1 = s5; t2 = s3; t3 = s1
          p3 = t0 + t2
          var p4 = t1 + t3
          p1 = t0 + t3
          p2 = t1 + t2
          let p5 = (p3 + p4) * 4816
          t0 = t0 * 1223; t1 = t1 * 8410; t2 = t2 * 12586; t3 = t3 * 6149
          p1 = p5 + p1 * -3685
          p2 = p5 + p2 * -10497
          p3 = p3 * -8034
          p4 = p4 * -1597
          t3 += p1 + p4; t2 += p2 + p3; t1 += p2 + p4; t0 += p1 + p3
      var v: array[64, int64]
      for i in 0 .. 7:
        one(int64(blk[i]), int64(blk[8 + i]), int64(blk[16 + i]), int64(blk[24 + i]),
            int64(blk[32 + i]), int64(blk[40 + i]), int64(blk[48 + i]), int64(blk[56 + i]),
            t0, t1, t2, t3, x0, x1, x2, x3)
        x0 += 512; x1 += 512; x2 += 512; x3 += 512
        v[i] = (x0 + t3) shr 10; v[56 + i] = (x0 - t3) shr 10
        v[8 + i] = (x1 + t2) shr 10; v[48 + i] = (x1 - t2) shr 10
        v[16 + i] = (x2 + t1) shr 10; v[40 + i] = (x2 - t1) shr 10
        v[24 + i] = (x3 + t0) shr 10; v[32 + i] = (x3 - t0) shr 10
      template cl(e: int64): uint8 = (let q = e; if q < 0: 0'u8 elif q > 255: 255'u8 else: uint8(q))
      for r in 0 .. 7:
        let k = r * 8
        one(v[k], v[k + 1], v[k + 2], v[k + 3], v[k + 4], v[k + 5], v[k + 6], v[k + 7],
            t0, t1, t2, t3, x0, x1, x2, x3)
        const bias = 65536 + (128 shl 17)
        x0 += bias; x1 += bias; x2 += bias; x3 += bias
        o[k] = cl((x0 + t3) shr 17); o[k + 7] = cl((x0 - t3) shr 17)
        o[k + 1] = cl((x1 + t2) shr 17); o[k + 6] = cl((x1 - t2) shr 17)
        o[k + 2] = cl((x2 + t1) shr 17); o[k + 5] = cl((x2 - t1) shr 17)
        o[k + 3] = cl((x3 + t0) shr 17); o[k + 4] = cl((x3 - t0) shr 17)
    var done, left = 0
    for t in 0 ..< 3000:
      var blk: array[64, int32]
      let big = [8, 300, 2000, 30000, 1_000_000][t mod 5]
      let dense = t mod 7
      for k in 0 ..< 64:
        if k == 0 or r.rand(6) < dense: blk[k] = int32(r.rand(2 * big) - big)
      if t mod 11 == 0:
        for k in 1 ..< 64: blk[k] = 0       # (only the average)
      var want: array[64, uint8]
      idctRef(blk, want)
      var got: array[80, uint8]          # (8 rows 10 apart)
      for k in 0 ..< got.len: got[k] = 77
      if idctBlock(addr blk[0], addr got[0], 10) != 0:
        inc done
        for y in 0 .. 7:
          for x in 0 .. 7: doAssert got[y * 10 + x] == want[y * 8 + x], "idct " & $t
          for x in 8 .. 9:
            if y < 7: doAssert got[y * 10 + x] == 77, "idct wrote past its row"
      else:
        inc left
        for k in 0 ..< got.len: doAssert got[k] == 77, "idct left a block but wrote"
    # (x86 without AVX2: only the blocks of an average done here, the rest left to the loop)
    doAssert done > 200 and left > 0

  block jpegColors:
    for n in lengths:
      var y, cb, cr = newSeq[uint8](n + 1)
      for i in 0 .. n:
        y[i] = uint8(r.rand(255)); cb[i] = uint8(r.rand(255)); cr[i] = uint8(r.rand(255))
      var o = newSeq[uint32](n + 1)
      var want = o
      for i in 0 ..< n:
        let yy = int(y[i]) shl 16 + 32768
        let b0 = int(cb[i]) - 128
        let r0 = int(cr[i]) - 128
        let cr8 = clamp((yy + 91881 * r0) shr 16, 0, 255)
        let cg8 = clamp((yy - 22554 * b0 - 46802 * r0) shr 16, 0, 255)
        let cb8 = clamp((yy + 116130 * b0) shr 16, 0, 255)
        want[i] = 0xFF000000'u32 or (uint32(cr8) shl 16) or (uint32(cg8) shl 8) or uint32(cb8)
      if n > 0: yccRow(addr o[0], addr y[0], addr cb[0], addr cr[0], n)
      doAssert o == want, "ycc " & $n

  block jpegUpsample:
    for vs in 1 .. 2:
      for vw in [2, 3, 5, 8, 9, 16, 17, 40, 101]:
        for w in [2 * vw - 1, 2 * vw]:
          var nr, fr = newSeq[uint8](vw)
          for i in 0 ..< vw:
            nr[i] = uint8(r.rand(255)); fr[i] = uint8(r.rand(255))
          template t(i: int): int = (if vs == 2: 3 * int(nr[i]) + int(fr[i]) else: 4 * int(nr[i]))
          var want = newSeq[uint8](w + 1)
          var t1 = t(0)
          want[0] = uint8((t1 + 2) shr 2)
          for i in 1 ..< vw:
            let t0 = t1
            t1 = t(i)
            if 2 * i - 1 < w: want[2 * i - 1] = uint8((3 * t0 + t1 + 8) shr 4)
            if 2 * i < w: want[2 * i] = uint8((3 * t1 + t0 + 8) shr 4)
          if 2 * vw - 1 < w: want[2 * vw - 1] = uint8((t1 + 2) shr 2)
          var got = newSeq[uint8](w + 1)
          fancyRow(addr got[0], addr nr[0], addr fr[0], vw, w, cint(vs))
          doAssert got == want, "upsample " & $vw & " " & $w & " " & $vs

  block pngFilters:
    proc paeth(a, b, c: int): int =
      let pa = abs(b - c)
      let pb = abs(a - c)
      let pc = abs(a + b - 2 * c)
      if pa <= pb and pa <= pc: a elif pb <= pc: b else: c
    for ch in 1 .. 4:
      for n0 in lengths:
        let n = n0 * ch
        if n == 0: continue
        var cp, up = newSeq[uint8](n)
        for i in 0 ..< n:
          cp[i] = uint8(r.rand(255)); up[i] = uint8(if r.rand(2) == 0: int(cp[i]) else: r.rand(255))
        var sums: array[5, int64]
        pngFilterSums(addr cp[0], addr up[0], n, cint(ch), addr sums[0])
        for kind in 0 .. 4:
          var want = newSeq[uint8](n)
          var sum = 0'i64
          for i in 0 ..< n:
            let x = int(cp[i])
            let a = if i >= ch: int(cp[i - ch]) else: 0
            let b = int(up[i])
            let c = if i >= ch: int(up[i - ch]) else: 0
            let f = case kind
                    of 0: x
                    of 1: x - a
                    of 2: x - b
                    of 3: x - (a + b) div 2
                    else: x - paeth(a, b, c)
            want[i] = uint8(f and 255)
            sum += (if want[i] < 128: int64(want[i]) else: 256 - int64(want[i]))
          doAssert sums[kind] == sum, "png sum " & $kind & " " & $n
          var got = newSeq[uint8](n)
          pngFilterRow(addr got[0], addr cp[0], addr up[0], n, cint(ch), cint(kind))
          doAssert got == want, "png filter " & $kind & " " & $n

  block adler:
    for n in [1, 5, 15, 16, 17, 100, 5551, 5552, 5553, 20000, 100_003]:
      var d = newSeq[uint8](n)
      for i in 0 ..< n: d[i] = uint8(if i mod 3 == 0: 255 else: r.rand(255))
      var s1 = 1'u32
      var s2 = 0'u32
      for x in d:
        s1 = (s1 + x) mod 65521
        s2 = (s2 + s1) mod 65521
      doAssert adlerUpdate(1, addr d[0], n) == ((s2 shl 16) or s1), "adler " & $n

  block cameraAndVideo:
    for pairs in [1, 3, 4, 5, 8, 33]:
      var s = newSeq[uint8](pairs * 4)
      for i in 0 ..< s.len: s[i] = uint8(r.rand(255))
      var want = newSeq[uint32](pairs * 2)
      template clip(v: int): uint32 = uint32(max(0, min(255, v)))
      for k in 0 ..< pairs:
        let i = k * 4
        let y0 = (int(s[i]) - 16) * 298
        let u = int(s[i + 1]) - 128
        let y1 = (int(s[i + 2]) - 16) * 298
        let v = int(s[i + 3]) - 128
        let rr = 409 * v + 128
        let g = -100 * u - 208 * v + 128
        let b = 516 * u + 128
        want[2 * k] = 0xFF000000'u32 or clip((y0 + rr) shr 8) shl 16 or clip((y0 + g) shr 8) shl 8 or
                      clip((y0 + b) shr 8)
        want[2 * k + 1] = 0xFF000000'u32 or clip((y1 + rr) shr 8) shl 16 or clip((y1 + g) shr 8) shl 8 or
                          clip((y1 + b) shr 8)
      var got = newSeq[uint32](pairs * 2)
      yuyvRow(addr got[0], addr s[0], pairs)
      doAssert got == want, "yuyv " & $pairs
    for n in lengths:
      if n == 0: continue
      var p = newSeq[uint32](n)
      for i in 0 ..< n: p[i] = px()
      var want = newSeq[uint8](n)
      for (cr, cg, cb) in [(18492'i32, 36101'i32, 7011'i32), (11966'i32, 40254'i32, 4064'i32)]:
        for i in 0 ..< n:
          let v = ((int(cr) * int((p[i] shr 16) and 255) + int(cg) * int((p[i] shr 8) and 255) +
                    int(cb) * int(p[i] and 255) + 32768) shr 16) + 16
          want[i] = uint8(clamp(v, 16, 235))
        var got = newSeq[uint8](n)
        lumaRow(addr got[0], addr p[0], n, cr, cg, cb)
        doAssert got == want, "luma " & $n

kitForceAvx2(-1)
echo "simdkit ok (AVX2 here: ", kitHasAvx2(), ")"
