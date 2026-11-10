## JPEG pictures in plain Nim: baseline and progressive, any chroma
## subsampling, restart markers, gray, YCbCr, CMYK and YCCK, and the EXIF
## orientation phones write. `scale` 8 decodes only each block's average
## (DC), an eighth of the size -- thumbnails of big photos in a blink.
##
## .. code-block:: nim
##   let photo = decodeJpeg(readFile("IMG_0001.jpg"))
##   let thumb = decodeJpeg(readFile("IMG_0001.jpg"), scale = 8)

import std/bitops
import gfx, parallel, busy

type JpegError* = object of CatchableError
  ## A JPEG that cannot be decoded: damaged, of a kind not read (lossless,
  ## arithmetic coding, 12 bits), or too large.

const maxJpegPixels = 120_000_000   ## larger is refused (memory), at the scale asked

proc fail(msg: string) {.noreturn.} = raise newException(JpegError, msg)

const zigzag = [
  0, 1, 8, 16, 9, 2, 3, 10, 17, 24, 32, 25, 18, 11, 4, 5, 12, 19, 26, 33, 40, 48,
  41, 34, 27, 20, 13, 6, 7, 14, 21, 28, 35, 42, 49, 56, 57, 50, 43, 36, 29, 22,
  15, 23, 30, 37, 44, 51, 58, 59, 52, 45, 38, 31, 39, 46, 53, 60, 61, 54, 47, 55,
  62, 63]

type
  Huffman = object
    lookup: array[512, uint16]     ## 9-bit fast path: (length shl 8) or symbol
    maxCode: array[18, int32]
    valPtr: array[17, int32]
    minCode: array[17, int32]
    symbols: seq[uint8]
    present: bool

  Component = object
    id, h, v, tq: int
    td, ta: int                    ## DC and AC table of the current scan
    bw, bh: int                    ## blocks across and down (padded to MCUs)
    coefs: seq[int16]              ## progressive: every block's coefficients
    pixels: seq[uint8]             ## the decoded plane, bw*8 x bh*8 (or /8)
    rowBase: int                   ## the plane's row `pixels` begins with (read in bands: a window)
    cx0, cy0, cw: int              ## the blocks `coefs` holds: from block cx0, cy0, cw across
    nz: seq[uint64]                ## (read in bands) which coefficients of each block are not 0
    pred: int

  Decoder = object
    data: ptr UncheckedArray[char] ## the file's bytes (a string's, or a mapped file's)
    dataLen: int
    stream: bool                   ## read in bands (`jpegBands`): no whole planes
    pos: int
    bitBuf: uint32
    bitCnt: int
    marker: int                    ## a marker met while reading bits
    qt: array[4, array[64, int32]]
    dc, ac: array[4, Huffman]
    comps: seq[Component]
    width, height: int
    progressive: bool
    hmax, vmax, mcusX, mcusY: int
    restart: int
    eobrun: int
    adobe: int                     ## Adobe transform: -1 none, 0 CMYK, 1 YCC, 2 YCCK
    orientation: int
    scale: int

proc u8(d: var Decoder): int =
  if d.pos >= d.dataLen: fail("the JPEG data ends too soon")
  result = ord(d.data[d.pos])
  inc d.pos

proc u16(d: var Decoder): int = (d.u8 shl 8) or d.u8

proc i16(v: int): int16 {.inline.} =
  ## A coefficient, kept in range whatever a damaged file says.
  int16(clamp(v, -32768, 32767))

# ---- Huffman ---------------------------------------------------------------------------

proc build(t: var Huffman; counts: openArray[int]; syms: seq[uint8]) =
  t.symbols = syms
  t.present = true
  for i in 0 ..< 512: t.lookup[i] = 0
  var code = 0
  var k = 0
  for len in 1 .. 16:
    t.valPtr[len] = int32(k)
    t.minCode[len] = int32(code)
    for _ in 0 ..< counts[len - 1]:
      if code >= (1 shl len) or k >= syms.len: fail("bad Huffman table")
      if len <= 9:
        let first = code shl (9 - len)
        for j in 0 ..< (1 shl (9 - len)):
          t.lookup[first + j] = uint16((len shl 8) or int(syms[k]))
      inc code
      inc k
    t.maxCode[len] = int32(if counts[len - 1] > 0: code - 1 else: -1)
    code = code shl 1
  t.maxCode[17] = int32.high

{.push boundChecks: off, overflowChecks: off.}
# (the hot loops: their indexes are checked by hand -- the data's end, the
# 9-bit look-up, the symbols' range)

proc fill(d: var Decoder) =
  ## Tops the bit buffer up to at least 25 bits (zeros past a marker).
  while d.bitCnt <= 24:
    var b = 0
    if d.marker == 0 and d.pos < d.dataLen:
      b = ord(d.data[d.pos])
      inc d.pos
      if b == 0xFF:
        var c = if d.pos < d.dataLen: ord(d.data[d.pos]) else: 0xD9
        while c == 0xFF and d.pos + 1 < d.dataLen:      # fill bytes
          inc d.pos
          c = ord(d.data[d.pos])
        if c == 0:
          inc d.pos
        else:
          d.marker = c                   # left in place for the parser
          dec d.pos
          b = 0
    d.bitBuf = d.bitBuf or (uint32(b) shl (24 - d.bitCnt))
    d.bitCnt += 8

proc bits(d: var Decoder; n: int): int =
  if n == 0: return 0
  if d.bitCnt < n: d.fill()
  result = int(d.bitBuf shr (32 - n))
  d.bitBuf = d.bitBuf shl n
  d.bitCnt -= n

proc bit(d: var Decoder): int = d.bits(1)

proc extend(v, n: int): int {.inline.} =
  ## JPEG's signed value of an `n`-bit magnitude.
  if n == 0: 0
  elif v < (1 shl (n - 1)): v - (1 shl n) + 1
  else: v

proc decodeSym(d: var Decoder; t: Huffman): int =
  if not t.present: fail("a Huffman table is missing")
  if d.bitCnt < 16: d.fill()
  let peek = int(d.bitBuf shr 23)
  let e = t.lookup[peek]
  if e != 0:
    let len = int(e shr 8)
    d.bitBuf = d.bitBuf shl len
    d.bitCnt -= len
    return int(e and 0xFF)
  var code = int(d.bitBuf shr 23)               # 9 bits
  var len = 9
  d.bitBuf = d.bitBuf shl 9
  d.bitCnt -= 9
  while len < 16 and code > t.maxCode[len]:
    code = (code shl 1) or d.bit
    inc len
  if code > t.maxCode[len]: fail("bad Huffman code")
  let si = t.valPtr[len] + code - t.minCode[len]
  if si < 0 or si >= t.symbols.len: fail("bad Huffman code")
  int(t.symbols[si])

{.pop.}

proc resetBits(d: var Decoder) =
  d.bitBuf = 0
  d.bitCnt = 0
  d.marker = 0

# ---- the IDCT --------------------------------------------------------------------------

# The integer IDCT of stb_image (after the IJG's jidctint): 12-bit fixed
# point, columns then rows, the rows written as clamped bytes. In 64 bits
# where `int` has 32 (WebAssembly, 32-bit programs): a broken file's
# coefficients overflow 32 bits, which C leaves undefined.

const
  c0541 = 2217     ## round(0.5411961 * 4096) ...
  c1847 = -7567
  c0765 = 3135
  c1175 = 4816
  c0298 = 1223
  c2053 = 8410
  c3072 = 12586
  c1501 = 6149
  c0899 = -3685
  c2562 = -10497
  c1961 = -8034
  c0390 = -1597

template idct1d(s0, s1, s2, s3, s4, s5, s6, s7: int64;
                t0, t1, t2, t3, x0, x1, x2, x3: untyped) =
  var t0, t1, t2, t3, x0, x1, x2, x3: int64
  block:
    var p2 = s2
    var p3 = s6
    var p1 = (p2 + p3) * c0541
    t2 = p1 + p3 * c1847
    t3 = p1 + p2 * c0765
    p2 = s0
    p3 = s4
    t0 = (p2 + p3) * 4096
    t1 = (p2 - p3) * 4096
    x0 = t0 + t3
    x3 = t0 - t3
    x1 = t1 + t2
    x2 = t1 - t2
    t0 = s7
    t1 = s5
    t2 = s3
    t3 = s1
    p3 = t0 + t2
    var p4 = t1 + t3
    p1 = t0 + t3
    p2 = t1 + t2
    let p5 = (p3 + p4) * c1175
    t0 = t0 * c0298
    t1 = t1 * c2053
    t2 = t2 * c3072
    t3 = t3 * c1501
    p1 = p5 + p1 * c0899
    p2 = p5 + p2 * c2562
    p3 = p3 * c1961
    p4 = p4 * c0390
    t3 += p1 + p4
    t2 += p2 + p3
    t1 += p2 + p4
    t0 += p1 + p3

template clampByte(v: int64): uint8 =
  (let x = v; if x < 0: 0'u8 elif x > 255: 255'u8 else: uint8(x))

{.push boundChecks: off, overflowChecks: off.}
proc idct(blk: array[64, int32]; outp: var seq[uint8]; at, stride: int) =
  ## Dequantized coefficients (natural order) -> 8x8 pixels at `at`.
  var v: array[64, int64]
  for i in 0 .. 7:                               # columns
    if blk[8 + i] == 0 and blk[16 + i] == 0 and blk[24 + i] == 0 and
       blk[32 + i] == 0 and blk[40 + i] == 0 and blk[48 + i] == 0 and blk[56 + i] == 0:
      let dc = int64(blk[i]) * 4                 # (most columns are only that)
      for k in 0 .. 7: v[k * 8 + i] = dc
    else:
      idct1d(int64(blk[i]), int64(blk[8 + i]), int64(blk[16 + i]), int64(blk[24 + i]),
             int64(blk[32 + i]), int64(blk[40 + i]), int64(blk[48 + i]), int64(blk[56 + i]),
             t0, t1, t2, t3, x0, x1, x2, x3)
      x0 += 512; x1 += 512; x2 += 512; x3 += 512
      v[i] = (x0 + t3) shr 10
      v[56 + i] = (x0 - t3) shr 10
      v[8 + i] = (x1 + t2) shr 10
      v[48 + i] = (x1 - t2) shr 10
      v[16 + i] = (x2 + t1) shr 10
      v[40 + i] = (x2 - t1) shr 10
      v[24 + i] = (x3 + t0) shr 10
      v[32 + i] = (x3 - t0) shr 10
  for r in 0 .. 7:                               # rows
    let k = r * 8
    idct1d(v[k], v[k + 1], v[k + 2], v[k + 3], v[k + 4], v[k + 5], v[k + 6], v[k + 7],
           t0, t1, t2, t3, x0, x1, x2, x3)
    const bias = 65536 + (128 shl 17)            # rounding, and +128
    x0 += bias; x1 += bias; x2 += bias; x3 += bias
    let o = at + r * stride
    outp[o] = clampByte((x0 + t3) shr 17)
    outp[o + 7] = clampByte((x0 - t3) shr 17)
    outp[o + 1] = clampByte((x1 + t2) shr 17)
    outp[o + 6] = clampByte((x1 - t2) shr 17)
    outp[o + 2] = clampByte((x2 + t1) shr 17)
    outp[o + 5] = clampByte((x2 - t1) shr 17)
    outp[o + 3] = clampByte((x3 + t0) shr 17)
    outp[o + 4] = clampByte((x3 - t0) shr 17)
{.pop.}

# ---- markers -------------------------------------------------------------------------------

proc exifOrientation(s: ptr UncheckedArray[char]; t, stop: int): int =
  ## The orientation tag of the TIFF data at `t` (1 when there is none).
  result = 1
  let le = s[t] == 'I'
  template r16(i: int): int =
    (if le: ord(s[i]) or (ord(s[i+1]) shl 8) else: (ord(s[i]) shl 8) or ord(s[i+1]))
  template r32(i: int): int =
    (if le: r16(i) or (r16(i + 2) shl 16) else: (r16(i) shl 16) or r16(i + 2))
  if t + 8 > stop: return
  let off = r32(t + 4)
  # (on a 32-bit system a number past 2^31 reads negative: no such place)
  if off < 0 or off > stop - t: return
  let ifd = t + off
  if ifd + 2 > stop: return
  for k in 0 ..< r16(ifd):
    let e = ifd + 2 + 12 * k
    if e + 12 > stop: break
    if r16(e) == 0x0112: return r16(e + 8)

proc startsWith(d: Decoder; s: string; at: int): bool =
  ## Whether the bytes at `at` are `s`.
  if at < 0 or at + s.len > d.dataLen: return false
  for i in 0 ..< s.len:
    if d.data[at + i] != s[i]: return false
  true

proc readTables(d: var Decoder; marker: int) =
  let len = d.u16
  if len < 2 or d.pos + len - 2 > d.dataLen: fail("damaged JPEG segment")
  let stop = d.pos + len - 2
  case marker
  of 0xDB:                                       # quantization tables
    while d.pos < stop:
      let pq = d.u8
      let t = pq and 15
      if t > 3: fail("bad quantization table")
      for i in 0 ..< 64:
        d.qt[t][zigzag[i]] = int32(if (pq shr 4) == 0: d.u8 else: d.u16)
  of 0xC4:                                       # Huffman tables
    while d.pos < stop:
      let tc = d.u8
      var counts: array[16, int]
      var n = 0
      for i in 0 ..< 16:
        counts[i] = d.u8
        n += counts[i]
      var syms = newSeq[uint8](n)
      for i in 0 ..< n: syms[i] = uint8(d.u8)
      let k = tc and 3
      if (tc shr 4) == 0: d.dc[k].build(counts, syms) else: d.ac[k].build(counts, syms)
  of 0xDD: d.restart = d.u16
  of 0xEE:                                       # Adobe
    if len >= 14 and d.startsWith("Adobe", d.pos):
      d.adobe = ord(d.data[d.pos + 11])
  of 0xE1:                                       # EXIF orientation
    if len > 20 and d.startsWith("Exif\0\0", d.pos):
      d.orientation = exifOrientation(d.data, d.pos + 6, stop)
  else: discard
  d.pos = stop

proc readFrame(d: var Decoder) =
  discard d.u16
  if d.u8 != 8: fail("only 8-bit JPEG pictures are supported")
  d.height = d.u16
  d.width = d.u16
  let n = d.u8
  # (read whole: at most 16384 a side; in bands, `jpegBands`, any size)
  if d.width <= 0 or d.height <= 0 or (not d.stream and (d.width > 16384 or d.height > 16384)):
    fail("bad JPEG size")
  if n notin [1, 3, 4]: fail("unsupported number of JPEG components")
  let k = if d.scale == 8: 8 else: 1
  # (progressive pictures keep every coefficient, whatever the scale)
  if not d.stream and ((d.width div k) * (d.height div k) > maxJpegPixels or
     (d.progressive and d.width * d.height > maxJpegPixels)):
    fail("the JPEG picture is too large")
  d.comps.setLen(0)                    # (a second frame replaces the first)
  d.hmax = 1
  d.vmax = 1
  for i in 0 ..< n:
    var c = Component(id: d.u8)
    let hv = d.u8
    c.h = max(1, hv shr 4)
    c.v = max(1, hv and 15)
    c.tq = d.u8 and 3
    d.hmax = max(d.hmax, c.h)
    d.vmax = max(d.vmax, c.v)
    d.comps.add c
  d.mcusX = (d.width + 8 * d.hmax - 1) div (8 * d.hmax)
  d.mcusY = (d.height + 8 * d.vmax - 1) div (8 * d.vmax)
  for c in d.comps.mitems:
    c.bw = d.mcusX * c.h
    c.bh = d.mcusY * c.v
    c.cw = c.bw
    if d.stream: continue              # (`jpegBands` keeps what it needs itself)
    if d.progressive: c.coefs = newSeq[int16](c.bw * c.bh * 64)
    let k = if d.scale == 8: 1 else: 8
    c.pixels = newSeq[uint8](c.bw * k * c.bh * k)

# ---- decoding blocks --------------------------------------------------------------------------

proc putBlock(d: var Decoder; c: var Component; bx, by: int; blk: array[64, int32]) =
  ## Dequantized coefficients (natural order) -> pixels of block bx, by.
  if d.scale == 8:
    let dc = int(blk[0])
    c.pixels[(by - c.rowBase) * c.bw + bx] = clampByte((if dc >= 0: dc + 4 else: dc - 4) div 8 + 128)
  else:
    idct(blk, c.pixels, (by * 8 - c.rowBase) * c.bw * 8 + bx * 8, c.bw * 8)

{.push boundChecks: off, overflowChecks: off.}
proc baselineCoefs(d: var Decoder; c: var Component; blk: var array[64, int32]) =
  ## A block's coefficients, dequantized (natural order).
  let q = addr d.qt[c.tq]
  let t = d.decodeSym(d.dc[c.td])
  if t > 15: fail("bad JPEG data")
  c.pred = clamp(c.pred + extend(d.bits(t), t), -65536, 65536)
  blk[0] = int32(clamp(c.pred * q[0], -1_000_000, 1_000_000))
  var k = 1
  while k < 64:
    let rs = d.decodeSym(d.ac[c.ta])
    let r = rs shr 4
    let s = rs and 15
    if s == 0:
      if r != 15: break
      k += 16
      continue
    k += r
    if k > 63: break
    let z = zigzag[k]
    blk[z] = int32(clamp(extend(d.bits(s), s) * q[z], -1_000_000, 1_000_000))
    inc k
{.pop.}

proc baselineBlock(d: var Decoder; c: var Component; bx, by: int) =
  var blk: array[64, int32]
  d.baselineCoefs(c, blk)
  d.putBlock(c, bx, by, blk)

template blockAt(c: Component; bx, by: int): int =
  ## Where block bx, by's coefficients are in `coefs`.
  ((by - c.cy0) * c.cw + (bx - c.cx0)) * 64

proc dcFirst(d: var Decoder; c: var Component; bx, by, al: int) =
  let t = d.decodeSym(d.dc[c.td])
  if t > 15: fail("bad JPEG data")
  c.pred = clamp(c.pred + extend(d.bits(t), t), -65536, 65536)
  c.coefs[c.blockAt(bx, by)] = i16(c.pred shl al)

proc dcRefine(d: var Decoder; c: var Component; bx, by, al: int) =
  if d.bit == 1:
    let i = c.blockAt(bx, by)
    c.coefs[i] = c.coefs[i] or i16(1 shl al)

proc acFirst(d: var Decoder; c: var Component; bx, by, ss, se, al: int) =
  if d.eobrun > 0:
    dec d.eobrun
    return
  let base = c.blockAt(bx, by)
  var k = ss
  while k <= se:
    let rs = d.decodeSym(d.ac[c.ta])
    let r = rs shr 4
    let s = rs and 15
    if s == 0:
      if r < 15:
        d.eobrun = (1 shl r) - 1
        if r > 0: d.eobrun += d.bits(r)
        break
      k += 16
      continue
    k += r
    if k > 63: break
    c.coefs[base + zigzag[k]] = i16(extend(d.bits(s), s) * (1 shl al))
    inc k

proc acRefine(d: var Decoder; c: var Component; bx, by, ss, se, al: int) =
  let base = c.blockAt(bx, by)
  let p1 = 1 shl al
  let m1 = -1 shl al
  var k = ss
  template refineNonZero(z: int) =
    let v = c.coefs[base + z]
    if d.bit == 1 and (int(v) and p1) == 0:
      c.coefs[base + z] = i16(if v >= 0: int(v) + p1 else: int(v) + m1)
  if d.eobrun <= 0:
    while k <= se:
      let rs = d.decodeSym(d.ac[c.ta])
      var r = rs shr 4
      let s = rs and 15
      var value = 0
      if s == 0:
        if r < 15:
          d.eobrun = (1 shl r)
          if r > 0: d.eobrun += d.bits(r)
          break
      else:
        value = if d.bit == 1: p1 else: m1
      while k <= se:
        let z = zigzag[k]
        if c.coefs[base + z] != 0:
          refineNonZero(z)
        else:
          if r == 0:
            if value != 0: c.coefs[base + z] = i16(value)
            inc k
            break
          dec r
        inc k
  if d.eobrun > 0:
    while k <= se:
      let z = zigzag[k]
      if c.coefs[base + z] != 0: refineNonZero(z)
      inc k
    dec d.eobrun

proc readScan(d: var Decoder) =
  discard d.u16
  let n = d.u8
  var sc: seq[int]
  for i in 0 ..< n:
    let id = d.u8
    let t = d.u8
    for k in 0 ..< d.comps.len:          # (by index: a component holds its pixels -- not copied)
      if d.comps[k].id == id and k notin sc:
        d.comps[k].td = (t shr 4) and 3
        d.comps[k].ta = t and 3
        sc.add k
  let ss = d.u8
  let se = d.u8
  let a = d.u8
  let ah = a shr 4
  let al = a and 15
  if sc.len == 0: return
  if d.progressive and (ss > se or se > 63 or al > 13 or (ss == 0 and se != 0)):
    fail("bad JPEG scan")
  d.resetBits()
  d.eobrun = 0
  for c in d.comps.mitems: c.pred = 0
  let single = sc.len == 1
  # blocks of one component are not interleaved: they run over its own grid
  let unitsX = if single: (d.width * d.comps[sc[0]].h + 8 * d.hmax - 1) div (8 * d.hmax)
               else: d.mcusX
  let unitsY = if single: (d.height * d.comps[sc[0]].v + 8 * d.vmax - 1) div (8 * d.vmax)
               else: d.mcusY
  var todo = if d.restart > 0: d.restart else: int.high
  # baseline at full size: the blocks of a band of rows decoded (in turn),
  # then turned into pixels on all the cores
  let banded = not d.progressive and d.scale == 1
  const BandRows = 8
  var qComp, qBx, qBy: seq[int32]
  var qBlk: seq[array[64, int32]]
  var qn = 0
  proc flushBand(d: var Decoder) =
    if qn == 0: return
    let cp = cast[ptr UncheckedArray[Component]](addr d.comps[0])
    let qc = cast[ptr UncheckedArray[int32]](addr qComp[0])
    let qx = cast[ptr UncheckedArray[int32]](addr qBx[0])
    let qy = cast[ptr UncheckedArray[int32]](addr qBy[0])
    let qb = cast[ptr UncheckedArray[array[64, int32]]](addr qBlk[0])
    parallelFor(qn, proc (lo, hi: int) =
      for i in lo ..< hi:
        let c = addr cp[int(qc[i])]
        idct(qb[i], c[].pixels, int(qy[i]) * 8 * c[].bw * 8 + int(qx[i]) * 8, c[].bw * 8), grain = 64)
    qn = 0
  for my in 0 ..< unitsY:
    for mx in 0 ..< unitsX:
      if todo == 0:
        # a restart marker: align, skip it, reset the predictors
        d.resetBits()
        while d.pos + 1 < d.dataLen and not (d.data[d.pos] == '\xFF' and
              ord(d.data[d.pos + 1]) in 0xD0 .. 0xD7):
          inc d.pos
        d.pos += 2
        for c in d.comps.mitems: c.pred = 0
        d.eobrun = 0
        todo = d.restart
      for k in sc:
        let c = addr d.comps[k]
        let (nh, nv) = if single: (1, 1) else: (c.h, c.v)
        for v in 0 ..< nv:
          for h in 0 ..< nh:
            let bx = if single: mx else: mx * c.h + h
            let by = if single: my else: my * c.v + v
            if banded:
              if qn >= qBlk.len:
                let m = max(1024, qBlk.len * 2)
                qBlk.setLen(m); qComp.setLen(m); qBx.setLen(m); qBy.setLen(m)
              for z in 0 ..< 64: qBlk[qn][z] = 0
              d.baselineCoefs(c[], qBlk[qn])
              qComp[qn] = int32(k)
              qBx[qn] = int32(bx)
              qBy[qn] = int32(by)
              inc qn
            elif not d.progressive: d.baselineBlock(c[], bx, by)
            elif ss == 0:
              if ah == 0: d.dcFirst(c[], bx, by, al) else: d.dcRefine(c[], bx, by, al)
            else:
              if ah == 0: d.acFirst(c[], bx, by, ss, se, al)
              else: d.acRefine(c[], bx, by, ss, se, al)
      dec todo
    if banded and ((my + 1) mod BandRows == 0 or my == unitsY - 1): d.flushBand()
    if (my and 7) == 7:
      if onUiThread(): busyFraction = (my + 1) / unitsY
      busyTick()
  # find the next marker
  d.resetBits()
  while d.pos + 1 < d.dataLen and not (d.data[d.pos] == '\xFF' and
        ord(d.data[d.pos + 1]) notin [0, 0xFF] and
        ord(d.data[d.pos + 1]) notin 0xD0 .. 0xD7):
    inc d.pos

proc finishProgressive(d: var Decoder) =
  for c in d.comps.mitems:
    let q = d.qt[c.tq]
    var blk: array[64, int32]
    for by in 0 ..< c.bh:
      for bx in 0 ..< c.bw:
        let base = (by * c.bw + bx) * 64
        for i in 0 ..< 64:
          blk[i] = int32(clamp(int(c.coefs[base + i]) * q[i], -1_000_000, 1_000_000))
        d.putBlock(c, bx, by, blk)
    c.coefs = @[]

# ---- pixels --------------------------------------------------------------------------------------

proc upsampleRow(d: var Decoder; ci, y: int; outp: var seq[uint8]) =
  ## Row `y` of component `ci` at full size: each output pixel blends the
  ## nearest sample (3/4) with the next nearest (1/4), across and down
  ## (the "fancy" upsampling of libjpeg).
  let c = addr d.comps[ci]
  let hs = d.hmax div c.h
  let vs = d.vmax div c.v
  let stride = c.bw * 8
  let w = d.width
  let validW = max(1, (d.width * c.h + d.hmax - 1) div d.hmax)
  let validH = max(1, (d.height * c.v + d.vmax - 1) div d.vmax)
  let cy = min(y div vs, validH - 1)
  let near = (cy - c.rowBase) * stride
  var far = near
  if vs == 2:
    far = ((if (y and 1) == 0: max(cy - 1, 0) else: min(cy + 1, validH - 1)) - c.rowBase) * stride
  let p = addr c.pixels
  template t(i: int): int =
    (if vs == 2: 3 * int(p[][near + i]) + int(p[][far + i]) else: 4 * int(p[][near + i]))
  if (hs == 1 or hs == 2) and (vs == 1 or vs == 2) and hs * c.h == d.hmax and
     vs * c.v == d.vmax:
    if hs == 1:
      for x in 0 ..< w: outp[x] = uint8((t(x) + 2) shr 2)
    elif validW == 1:
      let v = uint8((t(0) + 2) shr 2)
      for x in 0 ..< w: outp[x] = v
    else:
      var t1 = t(0)
      outp[0] = uint8((t1 + 2) shr 2)
      for i in 1 ..< validW:
        let t0 = t1
        t1 = t(i)
        if 2 * i - 1 < w: outp[2 * i - 1] = uint8((3 * t0 + t1 + 8) shr 4)
        if 2 * i < w: outp[2 * i] = uint8((3 * t1 + t0 + 8) shr 4)
      if 2 * validW - 1 < w: outp[2 * validW - 1] = uint8((t1 + 2) shr 2)
  else:
    # other samplings: the nearest sample
    for x in 0 ..< w: outp[x] = p[][near + x * c.h div d.hmax]

proc xmapOf(d: Decoder; w, k: int): array[4, seq[int32]] =
  ## Where each pixel's samples are in the (subsampled) planes.
  for i in 0 ..< d.comps.len:
    result[i] = newSeq[int32](w)
    for x in 0 ..< w: result[i][x] = int32(x * d.comps[i].h div d.hmax)

{.push boundChecks: off, overflowChecks: off.}
proc colorRow(d: ptr Decoder; y, k: int; xm: ptr array[4, seq[int32]]; cbRow, crRow: var seq[uint8];
              o: ptr UncheckedArray[uint32]; x0, x1: int) =
  ## Pixels `x0 ..< x1` of row `y` (of the picture at 1/`k`) into `o`, from
  ## the planes: YCbCr to RGB in integers -- the color planes of subsampled
  ## pictures scaled up smoothly, as libjpeg does --, gray, RGB, CMYK.
  let n = d.comps.len
  var rows: array[4, int]
  var pl: array[4, ptr UncheckedArray[uint8]]
  var xs: array[4, ptr UncheckedArray[int32]]
  for i in 0 ..< n:
    let c = addr d.comps[i]
    rows[i] = ((y * c.v div d.vmax) - c.rowBase) * c.bw * (8 div k)
    pl[i] = cast[ptr UncheckedArray[uint8]](addr c.pixels[0])
    xs[i] = cast[ptr UncheckedArray[int32]](addr xm[][i][0])
  let ycc = if n == 3: d.adobe != 0 else: d.adobe == 2
  if n == 1:
    for x in x0 ..< x1:
      let g = uint32(pl[0][rows[0] + int(xs[0][x])])
      o[x] = 0xFF000000'u32 or (g shl 16) or (g shl 8) or g
  elif n == 3 and ycc:
    # the usual photo (a color plane at half size or full -- the ones
    # libjpeg scales up smoothly -- made smooth; others: the nearest sample)
    let smooth = k == 1 and d.comps[0].h == d.hmax and d.comps[0].v == d.vmax
    template fancy(c: Component): bool =
      let hs = d.hmax div c.h
      let vs = d.vmax div c.v
      smooth and hs in 1 .. 2 and vs in 1 .. 2 and hs * c.h == d.hmax and vs * c.v == d.vmax
    let sb = fancy(d.comps[1])
    let sr = fancy(d.comps[2])
    if sb: d[].upsampleRow(1, y, cbRow)
    if sr: d[].upsampleRow(2, y, crRow)
    for x in x0 ..< x1:
      let yy = int(pl[0][rows[0] + int(xs[0][x])]) shl 16 + 32768
      let cb = (if sb: int(cbRow[x]) else: int(pl[1][rows[1] + int(xs[1][x])])) - 128
      let cr = (if sr: int(crRow[x]) else: int(pl[2][rows[2] + int(xs[2][x])])) - 128
      let r = clampByte((yy + 91881 * cr) shr 16)
      let g = clampByte((yy - 22554 * cb - 46802 * cr) shr 16)
      let b = clampByte((yy + 116130 * cb) shr 16)
      o[x] = 0xFF000000'u32 or (uint32(r) shl 16) or (uint32(g) shl 8) or uint32(b)
  else:
    for x in x0 ..< x1:
      var s: array[4, int]
      for i in 0 ..< n: s[i] = int(pl[i][rows[i] + int(xs[i][x])])
      var r, g, b: int
      if ycc:
        let yy = s[0] shl 16 + 32768
        let cb = s[1] - 128
        let cr = s[2] - 128
        r = clamp((yy + 91881 * cr) shr 16, 0, 255)
        g = clamp((yy - 22554 * cb - 46802 * cr) shr 16, 0, 255)
        b = clamp((yy + 116130 * cb) shr 16, 0, 255)
      else:
        r = s[0]; g = s[1]; b = s[2]
      if n == 4:
        # Adobe CMYK is stored inverted
        let kk = s[3]
        r = r * kk div 255
        g = g * kk div 255
        b = b * kk div 255
      o[x] = 0xFF000000'u32 or (uint32(r) shl 16) or (uint32(g) shl 8) or uint32(b)
{.pop.}

proc toBitmap(d: var Decoder): Bitmap =
  let k = if d.scale == 8: 8 else: 1
  let w = max(1, (d.width + k - 1) div k)
  let h = max(1, (d.height + k - 1) div k)
  result = newBitmap(w, h)
  var xmap = d.xmapOf(w, k)
  # (the rows shared out among the cores)
  let dp = addr d
  let op = cast[ptr UncheckedArray[uint32]](addr result.px[0])
  let xm = addr xmap
  parallelChunks(h, lo, hi):
    var cbRow = newSeq[uint8](w + 2)
    var crRow = newSeq[uint8](w + 2)
    for y in lo ..< hi:
      colorRow(dp, y, k, xm, cbRow, crRow, cast[ptr UncheckedArray[uint32]](addr op[y * w]), 0, w)

proc orient(b: Bitmap; o: int): Bitmap =
  ## The picture turned the way the camera's EXIF orientation says.
  if o <= 1 or o > 8: return b
  let swap = o >= 5
  let w = if swap: b.h else: b.w
  let h = if swap: b.w else: b.h
  result = newBitmap(w, h)
  for y in 0 ..< h:
    for x in 0 ..< w:
      let (sx, sy) = case o
        of 2: (b.w - 1 - x, y)
        of 3: (b.w - 1 - x, b.h - 1 - y)
        of 4: (x, b.h - 1 - y)
        of 5: (y, x)
        of 6: (y, b.h - 1 - x)
        of 7: (b.w - 1 - y, b.h - 1 - x)
        else: (b.w - 1 - y, x)
      result.px[y * w + x] = b.px[sy * b.w + sx]
  result.changed()

proc jpegSize*(data: string): tuple[w, h: int] =
  ## The size of a JPEG picture, read from its frame header (0, 0 if none).
  var i = 2
  while i + 9 < data.len:
    if data[i] != '\xFF':
      inc i
      continue
    let m = ord(data[i + 1])
    if m in [0xC0, 0xC1, 0xC2]:
      return ((ord(data[i + 7]) shl 8) or ord(data[i + 8]),
              (ord(data[i + 5]) shl 8) or ord(data[i + 6]))
    if m == 0xD8 or m == 0xFF or m in 0xD0 .. 0xD7:
      i += (if m == 0xFF: 1 else: 2)
      continue
    i += 2 + ((ord(data[i + 2]) shl 8) or ord(data[i + 3]))

proc decodeJpeg*(data: string; scale = 1): Bitmap =
  ## A JPEG picture; `scale` 8 gives it at an eighth of its size (fast).
  if data.len < 4 or data[0] != '\xFF' or data[1] != '\xD8': fail("not a JPEG file")
  var d = Decoder(data: cast[ptr UncheckedArray[char]](unsafeAddr data[0]), dataLen: data.len, pos: 2,
                  adobe: -1, scale: if scale >= 8: 8 else: 1)
  var frame = false
  while d.pos < data.len:
    # next marker
    if d.u8 != 0xFF: continue
    var m = d.u8
    while m == 0xFF: m = d.u8
    case m
    of 0xD8, 0x01, 0xD0 .. 0xD7: discard
    of 0xD9: break
    of 0xC0, 0xC1, 0xC2:
      d.progressive = m == 0xC2
      d.readFrame()
      frame = true
    of 0xC3, 0xC5 .. 0xC7, 0xC9 .. 0xCB, 0xCD .. 0xCF:
      fail("this kind of JPEG (lossless or arithmetic) is not supported")
    of 0xDA:
      if not frame: fail("a JPEG scan before its frame")
      d.readScan()
    of 0xC4, 0xDB, 0xDD, 0xE1, 0xEE: d.readTables(m)
    else:
      let len = d.u16
      if len < 2: fail("damaged JPEG segment")
      d.pos += len - 2
  if not frame: fail("no picture in the JPEG file")
  if onUiThread(): busyFraction = -1
  if d.progressive: d.finishProgressive()
  result = d.toBitmap()
  result.changed()
  result = orient(result, d.orientation)

proc exifTurned*(b: Bitmap; orientation: int): Bitmap =
  ## `b` turned the way an EXIF orientation (1 .. 8) says: `b` itself for 1.
  orient(b, orientation)

# ---- big pictures: a band of rows at a time ------------------------------------------------------

type
  JpegLayout* = object
    ## What a JPEG's headers say (`jpegLayout`).
    w*, h*: int                    ## its size as stored (before the EXIF orientation)
    orientation*: int              ## the EXIF orientation: 1 as stored .. 8
    progressive*: bool             ## progressive (else baseline)
    components*: int               ## 1 gray, 3 YCbCr or RGB, 4 CMYK or YCCK

  JpegRow* = proc (y: int; row: ptr UncheckedArray[uint32]) {.closure, gcsafe.}
    ## A row `jpegBands` made (`y` from the top of the picture as stored).

  JpegProgress* = proc (done: float) {.closure, gcsafe.}
    ## How much of the work is done (0 .. 1).

  Band = object
    k, bs, w, h: int               # the picture at 1/k: w x h; a block's side in it
    ya, yb, xa, xb: int            # the rows and columns asked for
    mh: int                        # an MCU row's height in it
    m0, m1, cx0, cx1: int          # the MCU rows given, the MCU columns made
    nb: int                        # MCU rows a band
    row: JpegRow
    progress: JpegProgress
    outp: seq[uint32]
    xmap: array[4, seq[int32]]

proc nextScan(d: var Decoder; frames: bool): bool =
  ## Reads markers up to the next scan -- true, left at its header -- or to
  ## the end of the picture (false). A frame is read when `frames`, else
  ## passed over.
  while d.pos < d.dataLen:
    if d.u8 != 0xFF: continue
    var m = d.u8
    while m == 0xFF: m = d.u8
    case m
    of 0xD8, 0x01, 0xD0 .. 0xD7: discard
    of 0xD9: return false
    of 0xC0, 0xC1, 0xC2:
      if frames:
        d.progressive = m == 0xC2
        d.readFrame()
      else:
        let len = d.u16
        if len < 2: fail("damaged JPEG segment")
        d.pos += len - 2
    of 0xC3, 0xC5 .. 0xC7, 0xC9 .. 0xCB, 0xCD .. 0xCF:
      fail("this kind of JPEG (lossless or arithmetic) is not supported")
    of 0xDA:
      if d.comps.len == 0: fail("a JPEG scan before its frame")
      return true
    of 0xC4, 0xDB, 0xDD, 0xE1, 0xEE: d.readTables(m)
    else:
      let len = d.u16
      if len < 2: fail("damaged JPEG segment")
      d.pos += len - 2
  false

proc scanHeader(d: var Decoder): tuple[sc: seq[int]; ss, se, ah, al: int] =
  ## A scan's header: its components (their tables set), its band of
  ## coefficients, its bits.
  discard d.u16
  let n = d.u8
  for i in 0 ..< n:
    let id = d.u8
    let t = d.u8
    for k in 0 ..< d.comps.len:
      if d.comps[k].id == id and k notin result.sc:
        d.comps[k].td = (t shr 4) and 3
        d.comps[k].ta = t and 3
        result.sc.add k
  result.ss = d.u8
  result.se = d.u8
  let a = d.u8
  result.ah = a shr 4
  result.al = a and 15
  if d.progressive and (result.ss > result.se or result.se > 63 or result.al > 13 or
                        (result.ss == 0 and result.se != 0)):
    fail("bad JPEG scan")

proc toNextMarker(d: var Decoder) =
  ## (past a scan's data, to the marker after it)
  d.resetBits()
  while d.pos + 1 < d.dataLen and not (d.data[d.pos] == '\xFF' and
        ord(d.data[d.pos + 1]) notin [0, 0xFF] and
        ord(d.data[d.pos + 1]) notin 0xD0 .. 0xD7):
    inc d.pos

proc restartMarker(d: var Decoder) =
  ## A restart marker: aligned, passed, the predictors reset.
  d.resetBits()
  while d.pos + 1 < d.dataLen and not (d.data[d.pos] == '\xFF' and
        ord(d.data[d.pos + 1]) in 0xD0 .. 0xD7):
    inc d.pos
  d.pos += 2
  for c in d.comps.mitems: c.pred = 0
  d.eobrun = 0

proc jpegLayout*(data: ptr UncheckedArray[char]; len: int): JpegLayout =
  ## The size, orientation and kind of the JPEG in `data[0 ..< len]`, from
  ## its headers at the start (nothing decoded). Raises `JpegError`.
  if len < 4 or data[0] != '\xFF' or data[1] != '\xD8': fail("not a JPEG file")
  var d = Decoder(data: data, dataLen: len, pos: 2, adobe: -1, scale: 1, stream: true)
  discard d.nextScan(true)
  if d.comps.len == 0: fail("no picture in the JPEG file")
  JpegLayout(w: d.width, h: d.height, progressive: d.progressive, components: d.comps.len,
             orientation: (if d.orientation in 1 .. 8: d.orientation else: 1))

{.push boundChecks: off, overflowChecks: off.}
proc quantCoefs(d: var Decoder; c: var Component; o: ptr UncheckedArray[int16]) =
  ## A baseline block's coefficients as they are in the file (not
  ## dequantized), into `o` (natural order; it is all zeros).
  let t = d.decodeSym(d.dc[c.td])
  if t > 15: fail("bad JPEG data")
  c.pred = clamp(c.pred + extend(d.bits(t), t), -65536, 65536)
  o[0] = i16(c.pred)
  var k = 1
  while k < 64:
    let rs = d.decodeSym(d.ac[c.ta])
    let r = rs shr 4
    let s = rs and 15
    if s == 0:
      if r != 15: break
      k += 16
      continue
    k += r
    if k > 63: break
    o[zigzag[k]] = i16(extend(d.bits(s), s))
    inc k
{.pop.}

proc acFirstMask(d: var Decoder; c: var Component; bx, by, ss, se: int) =
  ## `acFirst` for a block whose coefficients are not kept: only which are not 0.
  if d.eobrun > 0:
    dec d.eobrun
    return
  let m = addr c.nz[by * c.bw + bx]
  var k = ss
  while k <= se:
    let rs = d.decodeSym(d.ac[c.ta])
    let r = rs shr 4
    let s = rs and 15
    if s == 0:
      if r < 15:
        d.eobrun = (1 shl r) - 1
        if r > 0: d.eobrun += d.bits(r)
        break
      k += 16
      continue
    k += r
    if k > 63: break
    discard d.bits(s)
    m[] = m[] or (1'u64 shl zigzag[k])
    inc k

proc acRefineMask(d: var Decoder; c: var Component; bx, by, ss, se: int) =
  ## `acRefine` for a block whose coefficients are not kept: its bits read,
  ## which are not 0 kept.
  let m = addr c.nz[by * c.bw + bx]
  var k = ss
  template isSet(z: int): bool = (m[] and (1'u64 shl z)) != 0
  if d.eobrun <= 0:
    while k <= se:
      let rs = d.decodeSym(d.ac[c.ta])
      var r = rs shr 4
      let s = rs and 15
      var value = false
      if s == 0:
        if r < 15:
          d.eobrun = (1 shl r)
          if r > 0: d.eobrun += d.bits(r)
          break
      else:
        discard d.bit
        value = true
      while k <= se:
        let z = zigzag[k]
        if isSet(z):
          discard d.bit
        else:
          if r == 0:
            if value: m[] = m[] or (1'u64 shl z)
            inc k
            break
          dec r
        inc k
  if d.eobrun > 0:
    while k <= se:
      if isSet(zigzag[k]): discard d.bit
      inc k
    dec d.eobrun

proc openWindow(d: var Decoder; bd: Band; first: int) =
  ## The planes of a band of MCU rows from `first` on (and a row above).
  for c in d.comps.mitems:
    let ch = c.v * bd.bs
    c.pixels = newSeq[uint8]((1 + (bd.nb + 1) * ch) * c.bw * bd.bs)
    c.rowBase = first * ch - 1

proc slideWindow(d: var Decoder; bd: Band; be: int) =
  ## Keeps MCU row `be - 1` and the row above it, at the top.
  for c in d.comps.mitems:
    let ch = c.v * bd.bs
    let pw = c.bw * bd.bs
    let src = (be - 1) * ch - 1 - c.rowBase
    if src > 0: moveMem(addr c.pixels[0], addr c.pixels[src * pw], (ch + 1) * pw)
    c.rowBase = (be - 1) * ch - 1

proc emitRows(d: var Decoder; bd: var Band; ma, mb: int) =
  ## The rows of MCU rows `ma .. mb` asked for: made (on all the cores), given.
  let ra = max(bd.ya, ma * bd.mh)
  let rb = min(bd.yb, (mb + 1) * bd.mh)
  if ra >= rb: return
  let w = bd.w
  if bd.outp.len < (rb - ra) * w: bd.outp.setLen((rb - ra) * w)
  let dp = addr d
  let op = cast[ptr UncheckedArray[uint32]](addr bd.outp[0])
  let xm = addr bd.xmap
  let k = bd.k
  let xa = bd.xa
  let xb = bd.xb
  parallelFor(rb - ra, proc (lo, hi: int) =
    var cbRow = newSeq[uint8](w + 2)
    var crRow = newSeq[uint8](w + 2)
    for i in lo ..< hi:
      colorRow(dp, ra + i, k, xm, cbRow, crRow, cast[ptr UncheckedArray[uint32]](addr op[i * w]), xa, xb))
  for i in 0 ..< rb - ra: bd.row(ra + i, cast[ptr UncheckedArray[uint32]](addr op[i * w]))

template bands(d: var Decoder; bd: var Band; first, last, e0, e1: int; fill: untyped) =
  ## MCU rows `first .. last` a band at a time: `fill` puts MCU rows `bm ..<
  ## be` in the planes; then the rows they finish, of MCU rows `e0 .. e1`,
  ## are given.
  d.openWindow(bd, first)
  var bm {.inject.} = first
  var emitFrom = e0
  while bm <= last:
    let be {.inject.} = min(last + 1, bm + bd.nb)
    fill
    let emitTo = if be > last: e1 else: min(e1, be - 2)
    if emitTo >= emitFrom:
      d.emitRows(bd, emitFrom, emitTo)
      emitFrom = emitTo + 1
    if be <= last: d.slideWindow(bd, be)
    bm = be

proc idctBlocks(d: var Decoder; q: var seq[tuple[c, bx, by: int32; blk: array[64, int32]]]; n: int) =
  ## The blocks waiting, into the planes on all the cores.
  if n == 0: return
  let cp = cast[ptr UncheckedArray[Component]](addr d.comps[0])
  let qp = cast[ptr UncheckedArray[tuple[c, bx, by: int32; blk: array[64, int32]]]](addr q[0])
  parallelFor(n, proc (lo, hi: int) =
    for i in lo ..< hi:
      let c = addr cp[int(qp[i].c)]
      idct(qp[i].blk, c[].pixels, (int(qp[i].by) * 8 - c[].rowBase) * c[].bw * 8 + int(qp[i].bx) * 8,
           c[].bw * 8), grain = 64)

proc baselineBands(d: var Decoder; bd: var Band; sc: seq[int]) =
  ## A baseline picture of one scan, all its components in it: its MCU rows
  ## decoded in turn (those before the rows asked for passed over: whole
  ## restart intervals skipped), a band at a time in the planes.
  let first = max(0, bd.m0 - 1)
  let last = min(d.mcusY - 1, bd.m1 + 1)
  d.resetBits()
  d.eobrun = 0
  for c in d.comps.mitems: c.pred = 0
  var todo = if d.restart > 0: d.restart else: int.high
  var mx, my = 0
  if d.restart > 0 and first > 0:
    # (the restart markers counted, not the data decoded)
    let want = (first * d.mcusX) div d.restart
    var p = d.pos
    var found = 0
    while found < want and p + 1 < d.dataLen:
      if d.data[p] == '\xFF':
        let m = ord(d.data[p + 1])
        if m in 0xD0 .. 0xD7:
          inc found
          p += 2
          continue
        elif m notin [0, 0xFF]: break
      inc p
    if found == want and want > 0:
      d.pos = p
      let at = want * d.restart
      my = at div d.mcusX
      mx = at mod d.mcusX
      todo = d.restart
  var q: seq[tuple[c, bx, by: int32; blk: array[64, int32]]]
  var scratch: array[64, int32]
  let total = max(1, last + 1)
  var qn = 0
  template decodeTo(stop: int; keep: bool) =
    ## MCUs up to the start of MCU row `stop`; their blocks kept for the
    ## planes when `keep` (those in the columns made).
    while my < stop:
      if todo == 0:
        d.restartMarker()
        todo = d.restart
      let inCols = mx >= bd.cx0 and mx <= bd.cx1
      for k in sc:
        let c = addr d.comps[k]
        for v in 0 ..< c.v:
          for h in 0 ..< c.h:
            let bx = mx * c.h + h
            let by = my * c.v + v
            if keep and inCols:
              if bd.k == 8:
                d.baselineCoefs(c[], scratch)
                d.putBlock(c[], bx, by, scratch)
              else:
                if qn >= q.len: q.setLen(max(256, q.len * 2))
                for z in 0 ..< 64: q[qn].blk[z] = 0
                d.baselineCoefs(c[], q[qn].blk)
                q[qn].c = int32(k)
                q[qn].bx = int32(bx)
                q[qn].by = int32(by)
                inc qn
            else:
              d.baselineCoefs(c[], scratch)
      dec todo
      inc mx
      if mx >= d.mcusX:
        mx = 0
        inc my
        if (my and 7) == 0:
          if bd.progress != nil: bd.progress(my / total)
          busyTick()
  decodeTo(first, false)
  d.bands(bd, first, last, bd.m0, bd.m1):
    qn = 0
    decodeTo(be, true)
    d.idctBlocks(q, qn)

proc coefPasses(d: var Decoder; bd: var Band; budget: int) =
  ## A progressive picture (or a baseline one in several scans): every scan
  ## read, the coefficients kept only for the blocks of the rows asked for
  ## (of the rest: which coefficients are not 0, that the later scans need)
  ## -- in passes over the file when those are more than `budget` bytes.
  ## At 1/8 only each block's first coefficient, and the scans of the rest
  ## passed over.
  let dcMode = bd.k == 8
  let per = if dcMode: 1 else: 64
  var rowBytes = 0
  for c in d.comps:
    rowBytes += (bd.cx1 - bd.cx0 + 1) * c.h * c.v * per * 2
  let rowsPer = if dcMode: d.mcusY else: max(1, budget div max(1, rowBytes) - 2)
  if d.progressive and not dcMode:
    var masks = 0
    for c in d.comps: masks += c.bw * c.bh * 8
    if masks > 4 * budget: fail("the JPEG picture is too large to read in parts")
    for c in d.comps.mitems: c.nz = newSeq[uint64](c.bw * c.bh)
  let passes = (bd.m1 - bd.m0 + rowsPer) div rowsPer
  var pass = 0
  var a = bd.m0
  while a <= bd.m1:
    let b = min(bd.m1, a + rowsPer - 1)
    let first = max(0, a - 1)
    let last = min(d.mcusY - 1, b + 1)
    var regRows: array[4, int]
    for i, c in d.comps.mpairs:
      c.cx0 = bd.cx0 * c.h
      c.cw = (bd.cx1 - bd.cx0 + 1) * c.h
      c.cy0 = first * c.v
      regRows[i] = (last - first + 1) * c.v
      c.coefs = newSeq[int16](c.cw * regRows[i] * per)
      if c.nz.len > 0: zeroMem(addr c.nz[0], c.nz.len * 8)
    # every scan
    d.pos = 2
    d.restart = 0
    while d.nextScan(false):
      let (sc, ss, se, ah, al) = d.scanHeader()
      if sc.len == 0: continue
      if dcMode and d.progressive and ss > 0:
        d.toNextMarker()                   # (the rest of the coefficients: not needed)
        continue
      d.resetBits()
      d.eobrun = 0
      for c in d.comps.mitems: c.pred = 0
      let single = sc.len == 1
      let unitsX = if single: (d.width * d.comps[sc[0]].h + 8 * d.hmax - 1) div (8 * d.hmax)
                   else: d.mcusX
      let unitsY = if single: (d.height * d.comps[sc[0]].v + 8 * d.vmax - 1) div (8 * d.vmax)
                   else: d.mcusY
      var todo = if d.restart > 0: d.restart else: int.high
      var scratch: array[64, int16]
      for my in 0 ..< unitsY:
        for mx in 0 ..< unitsX:
          if todo == 0:
            d.restartMarker()
            todo = d.restart
          for k in sc:
            let c = addr d.comps[k]
            let (nh, nv) = if single: (1, 1) else: (c.h, c.v)
            for v in 0 ..< nv:
              for h in 0 ..< nh:
                let bx = if single: mx else: mx * c.h + h
                let by = if single: my else: my * c.v + v
                let inReg = bx >= c.cx0 and bx < c.cx0 + c.cw and by >= c.cy0 and by < c.cy0 + regRows[k]
                let at = if not inReg: 0
                         elif dcMode: (by - c.cy0) * c.cw + (bx - c.cx0)
                         else: c[].blockAt(bx, by)
                if not d.progressive:
                  if inReg and not dcMode:
                    d.quantCoefs(c[], cast[ptr UncheckedArray[int16]](addr c.coefs[at]))
                  else:
                    d.quantCoefs(c[], cast[ptr UncheckedArray[int16]](addr scratch[0]))
                    if inReg: c.coefs[at] = scratch[0]
                elif ss == 0:
                  if ah == 0:
                    let t = d.decodeSym(d.dc[c.td])
                    if t > 15: fail("bad JPEG data")
                    c.pred = clamp(c.pred + extend(d.bits(t), t), -65536, 65536)
                    if inReg: c.coefs[at] = i16(c.pred shl al)
                  elif d.bit == 1 and inReg:
                    c.coefs[at] = c.coefs[at] or i16(1 shl al)
                elif inReg:
                  if ah == 0: d.acFirst(c[], bx, by, ss, se, al) else: d.acRefine(c[], bx, by, ss, se, al)
                else:
                  if ah == 0: d.acFirstMask(c[], bx, by, ss, se) else: d.acRefineMask(c[], bx, by, ss, se)
          dec todo
        if (my and 7) == 7:
          if bd.progress != nil: bd.progress((pass.float + d.pos / d.dataLen) / passes.float)
          busyTick()
      d.toNextMarker()
    # the rows of this pass, from the coefficients kept
    d.bands(bd, first, last, a, b):
      for ci in 0 ..< d.comps.len:
        let cp = addr d.comps[ci]
        let q = d.qt[cp.tq]
        let by0 = bm * cp.v
        let n = (be - bm) * cp.v * cp.cw
        let cw = cp.cw
        let bsz = bd.bs
        parallelFor(n, proc (lo, hi: int) =
          var blk: array[64, int32]
          for i in lo ..< hi:
            let by = by0 + i div cw
            let bx = cp.cx0 + i mod cw
            if bsz == 1:
              let dc = clamp(int(cp.coefs[(by - cp.cy0) * cw + (bx - cp.cx0)]) * q[0], -1_000_000, 1_000_000)
              cp.pixels[(by - cp.rowBase) * cp.bw + bx] = clampByte((if dc >= 0: dc + 4 else: dc - 4) div 8 + 128)
            else:
              let base = cp[].blockAt(bx, by)
              for z in 0 ..< 64:
                blk[z] = int32(clamp(int(cp.coefs[base + z]) * q[z], -1_000_000, 1_000_000))
              idct(blk, cp.pixels, (by * 8 - cp.rowBase) * cp.bw * 8 + bx * 8, cp.bw * 8), grain = 16)
    for c in d.comps.mitems: c.coefs = @[]
    inc pass
    a = b + 1

proc jpegBands*(data: ptr UncheckedArray[char]; len: int; scale: int; y0, y1, x0, x1: int;
                row: JpegRow; progress: JpegProgress = nil; budget = 256 shl 20) =
  ## Decodes the JPEG in `data[0 ..< len]` -- at 1/`scale`: 1, or 8 (each
  ## block's average: quick) -- a band of rows at a time, and gives rows
  ## `y0 ..< y1` of it (as stored: not turned) to `row` in order; only
  ## pixels `x0 ..< x1` of each are made. Any size (to 65535 a side).
  ## Memory: a few rows of blocks for a baseline picture; for a progressive
  ## one, the coefficients of the rows asked for (in passes over the file
  ## when they are more than `budget` bytes) and 8 bytes a block of the
  ## rest -- at 1/8, 2 bytes a block. Raises `JpegError` (or what `row`
  ## raises: `BusyCancelled` from a tick when Cancel was pressed).
  if len < 4 or data[0] != '\xFF' or data[1] != '\xD8': fail("not a JPEG file")
  var d = Decoder(data: data, dataLen: len, pos: 2, adobe: -1, scale: (if scale >= 8: 8 else: 1),
                  stream: true)
  if not d.nextScan(true): fail("no picture in the JPEG file")
  var bd = Band(k: d.scale, bs: 8 div d.scale, row: row, progress: progress)
  bd.w = max(1, (d.width + bd.k - 1) div bd.k)
  bd.h = max(1, (d.height + bd.k - 1) div bd.k)
  bd.ya = max(0, y0)
  bd.yb = min(bd.h, y1)
  bd.xa = max(0, x0)
  bd.xb = min(bd.w, x1)
  if bd.ya >= bd.yb or bd.xa >= bd.xb: return
  # (a block takes 2 bits at least: a damaged header cannot ask for more
  # blocks than the data can hold)
  var blocks = 0'i64
  for c in d.comps: blocks += c.bw.int64 * c.bh.int64
  if blocks > d.dataLen.int64 * 8 + 4096: fail("the JPEG data is too short for its size")
  bd.mh = d.vmax * bd.bs
  let mw = d.hmax * bd.bs
  bd.m0 = bd.ya div bd.mh
  bd.m1 = min(d.mcusY - 1, (bd.yb - 1) div bd.mh)
  bd.cx0 = max(0, bd.xa div mw - 1)
  bd.cx1 = min(d.mcusX - 1, (bd.xb - 1) div mw + 1)
  var perRow = 0
  for c in d.comps: perRow += (bd.cx1 - bd.cx0 + 1) * c.h * c.v
  bd.nb = clamp(8192 div max(1, perRow), 1, 16)
  bd.xmap = d.xmapOf(bd.w, bd.k)
  let (sc, _, _, _, _) = d.scanHeader()
  if not d.progressive and sc.len == d.comps.len and (sc.len > 1 or (d.hmax == 1 and d.vmax == 1)):
    d.baselineBands(bd, sc)
  else:
    d.coefPasses(bd, budget)
  if bd.progress != nil: bd.progress(1.0)

# ---- writing -------------------------------------------------------------------------------------

const
  stdLuma = [16, 11, 10, 16, 24, 40, 51, 61, 12, 12, 14, 19, 26, 58, 60, 55,
             14, 13, 16, 24, 40, 57, 69, 56, 14, 17, 22, 29, 51, 87, 80, 62,
             18, 22, 37, 56, 68, 109, 103, 77, 24, 35, 55, 64, 81, 104, 113, 92,
             49, 64, 78, 87, 103, 121, 120, 101, 72, 92, 95, 98, 112, 100, 103, 99]
  stdChroma = [17, 18, 24, 47, 99, 99, 99, 99, 18, 21, 26, 66, 99, 99, 99, 99,
               24, 26, 56, 99, 99, 99, 99, 99, 47, 66, 99, 99, 99, 99, 99, 99,
               99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99,
               99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99]
  dcLumaBits = [0, 1, 5, 1, 1, 1, 1, 1, 1, 0, 0, 0, 0, 0, 0, 0]
  dcLumaVals = [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11]
  dcChromaBits = [0, 3, 1, 1, 1, 1, 1, 1, 1, 1, 1, 0, 0, 0, 0, 0]
  dcChromaVals = [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11]
  acLumaBits = [0, 2, 1, 3, 3, 2, 4, 3, 5, 5, 4, 4, 0, 0, 1, 0x7d]
  acLumaVals = [
    0x01, 0x02, 0x03, 0x00, 0x04, 0x11, 0x05, 0x12, 0x21, 0x31, 0x41, 0x06, 0x13, 0x51, 0x61,
    0x07, 0x22, 0x71, 0x14, 0x32, 0x81, 0x91, 0xa1, 0x08, 0x23, 0x42, 0xb1, 0xc1, 0x15, 0x52,
    0xd1, 0xf0, 0x24, 0x33, 0x62, 0x72, 0x82, 0x09, 0x0a, 0x16, 0x17, 0x18, 0x19, 0x1a, 0x25,
    0x26, 0x27, 0x28, 0x29, 0x2a, 0x34, 0x35, 0x36, 0x37, 0x38, 0x39, 0x3a, 0x43, 0x44, 0x45,
    0x46, 0x47, 0x48, 0x49, 0x4a, 0x53, 0x54, 0x55, 0x56, 0x57, 0x58, 0x59, 0x5a, 0x63, 0x64,
    0x65, 0x66, 0x67, 0x68, 0x69, 0x6a, 0x73, 0x74, 0x75, 0x76, 0x77, 0x78, 0x79, 0x7a, 0x83,
    0x84, 0x85, 0x86, 0x87, 0x88, 0x89, 0x8a, 0x92, 0x93, 0x94, 0x95, 0x96, 0x97, 0x98, 0x99,
    0x9a, 0xa2, 0xa3, 0xa4, 0xa5, 0xa6, 0xa7, 0xa8, 0xa9, 0xaa, 0xb2, 0xb3, 0xb4, 0xb5, 0xb6,
    0xb7, 0xb8, 0xb9, 0xba, 0xc2, 0xc3, 0xc4, 0xc5, 0xc6, 0xc7, 0xc8, 0xc9, 0xca, 0xd2, 0xd3,
    0xd4, 0xd5, 0xd6, 0xd7, 0xd8, 0xd9, 0xda, 0xe1, 0xe2, 0xe3, 0xe4, 0xe5, 0xe6, 0xe7, 0xe8,
    0xe9, 0xea, 0xf1, 0xf2, 0xf3, 0xf4, 0xf5, 0xf6, 0xf7, 0xf8, 0xf9, 0xfa]
  acChromaBits = [0, 2, 1, 2, 4, 4, 3, 4, 7, 5, 4, 4, 0, 1, 2, 0x77]
  acChromaVals = [
    0x00, 0x01, 0x02, 0x03, 0x11, 0x04, 0x05, 0x21, 0x31, 0x06, 0x12, 0x41, 0x51, 0x07, 0x61,
    0x71, 0x13, 0x22, 0x32, 0x81, 0x08, 0x14, 0x42, 0x91, 0xa1, 0xb1, 0xc1, 0x09, 0x23, 0x33,
    0x52, 0xf0, 0x15, 0x62, 0x72, 0xd1, 0x0a, 0x16, 0x24, 0x34, 0xe1, 0x25, 0xf1, 0x17, 0x18,
    0x19, 0x1a, 0x26, 0x27, 0x28, 0x29, 0x2a, 0x35, 0x36, 0x37, 0x38, 0x39, 0x3a, 0x43, 0x44,
    0x45, 0x46, 0x47, 0x48, 0x49, 0x4a, 0x53, 0x54, 0x55, 0x56, 0x57, 0x58, 0x59, 0x5a, 0x63,
    0x64, 0x65, 0x66, 0x67, 0x68, 0x69, 0x6a, 0x73, 0x74, 0x75, 0x76, 0x77, 0x78, 0x79, 0x7a,
    0x82, 0x83, 0x84, 0x85, 0x86, 0x87, 0x88, 0x89, 0x8a, 0x92, 0x93, 0x94, 0x95, 0x96, 0x97,
    0x98, 0x99, 0x9a, 0xa2, 0xa3, 0xa4, 0xa5, 0xa6, 0xa7, 0xa8, 0xa9, 0xaa, 0xb2, 0xb3, 0xb4,
    0xb5, 0xb6, 0xb7, 0xb8, 0xb9, 0xba, 0xc2, 0xc3, 0xc4, 0xc5, 0xc6, 0xc7, 0xc8, 0xc9, 0xca,
    0xd2, 0xd3, 0xd4, 0xd5, 0xd6, 0xd7, 0xd8, 0xd9, 0xda, 0xe2, 0xe3, 0xe4, 0xe5, 0xe6, 0xe7,
    0xe8, 0xe9, 0xea, 0xf2, 0xf3, 0xf4, 0xf5, 0xf6, 0xf7, 0xf8, 0xf9, 0xfa]

type
  HuffCode = array[256, tuple[code, len: int]]
  BitWriter = object
    s: string
    acc: uint32
    n: int

proc makeCodes(bits, vals: openArray[int]): HuffCode =
  var code = 0
  var k = 0
  for len in 1 .. 16:
    for _ in 0 ..< bits[len - 1]:
      result[vals[k]] = (code, len)
      inc code
      inc k
    code = code shl 1

proc put(w: var BitWriter; code, len: int) =
  w.acc = (w.acc shl uint32(len)) or uint32(code and ((1 shl len) - 1))
  w.n += len
  while w.n >= 8:
    let b = char((w.acc shr uint32(w.n - 8)) and 0xFF)
    w.s.add b
    if b == '\xFF': w.s.add '\x00'
    w.n -= 8

proc flush(w: var BitWriter) =
  if w.n > 0: w.put(0x7F, 8 - w.n)

const aan = [1.0, 1.387039845, 1.306562965, 1.175875602, 1.0, 0.785694958, 0.541196100, 0.275899379]
  ## (the scales of the fast DCT's outputs)

proc fdct(d: var array[64, float32]) =
  ## The forward DCT of an 8 x 8 block, the quick way (Arai, Agui and
  ## Nakajima, as the IJG library does it): its outputs scaled by 8 and by
  ## `aan` (taken out with the quantization).
  template pass(i0, st: int) =
    let t0 = d[i0] + d[i0 + 7 * st]
    let t7 = d[i0] - d[i0 + 7 * st]
    let t1 = d[i0 + st] + d[i0 + 6 * st]
    let t6 = d[i0 + st] - d[i0 + 6 * st]
    let t2 = d[i0 + 2 * st] + d[i0 + 5 * st]
    let t5 = d[i0 + 2 * st] - d[i0 + 5 * st]
    let t3 = d[i0 + 3 * st] + d[i0 + 4 * st]
    let t4 = d[i0 + 3 * st] - d[i0 + 4 * st]
    var t10 = t0 + t3
    let t13 = t0 - t3
    var t11 = t1 + t2
    var t12 = t1 - t2
    d[i0] = t10 + t11
    d[i0 + 4 * st] = t10 - t11
    let z1 = (t12 + t13) * 0.707106781'f32
    d[i0 + 2 * st] = t13 + z1
    d[i0 + 6 * st] = t13 - z1
    t10 = t4 + t5
    t11 = t5 + t6
    t12 = t6 + t7
    let z5 = (t10 - t12) * 0.382683433'f32
    let z2 = 0.541196100'f32 * t10 + z5
    let z4 = 1.306562965'f32 * t12 + z5
    let z3 = t11 * 0.707106781'f32
    let z11 = t7 + z3
    let z13 = t7 - z3
    d[i0 + 5 * st] = z13 + z2
    d[i0 + 3 * st] = z13 - z2
    d[i0 + st] = z11 + z4
    d[i0 + 7 * st] = z11 - z4
  for r in 0 .. 7: pass(r * 8, 1)
  for c in 0 .. 7: pass(c, 8)

proc divisors(q: array[64, int]): array[64, float32] =
  ## What each output of `fdct` is multiplied by to be quantized (natural
  ## order: `q` is too).
  for r in 0 .. 7:
    for c in 0 .. 7:
      result[r * 8 + c] = float32(1.0 / (q[r * 8 + c].float * aan[r] * aan[c] * 8.0))

proc encodeJpeg*(b: Bitmap; quality = 85; chroma420 = false; dpi = 0): string =
  ## A baseline JPEG of `b` (transparency is dropped). `quality` 1
  ## (smallest) .. 100 (best); `chroma420`: the colors at half the size
  ## (smaller files, as cameras save them); `dpi` written in the header.
  ## The blocks are worked out on all the cores, a band at a time.
  let q = clamp(quality, 1, 100)
  let scale = if q < 50: 5000 div q else: 200 - 2 * q
  var ql, qc: array[64, int]
  for i in 0 .. 63:
    ql[i] = clamp((stdLuma[i] * scale + 50) div 100, 1, 255)
    qc[i] = clamp((stdChroma[i] * scale + 50) div 100, 1, 255)
  var o = "\xFF\xD8"
  proc u16(v: int) =
    o.add char((v shr 8) and 255); o.add char(v and 255)
  # JFIF (with the resolution)
  o.add "\xFF\xE0"; u16(16); o.add "JFIF\x00\x01\x01"
  if dpi > 0:
    o.add '\x01'; u16(clamp(dpi, 1, 65535)); u16(clamp(dpi, 1, 65535))
  else:
    o.add '\x00'; u16(1); u16(1)
  o.add "\x00\x00"
  # the quantization tables (in zigzag order)
  for (id, t) in [(0, ql), (1, qc)]:
    o.add "\xFF\xDB"; u16(67); o.add char(id)
    for i in 0 .. 63: o.add char(t[zigzag[i]])
  # the frame
  let sub = if chroma420: 2 else: 1
  o.add "\xFF\xC0"; u16(17); o.add '\x08'; u16(b.h); u16(b.w); o.add '\x03'
  o.add "\x01"; o.add char(sub * 16 + sub); o.add "\x00\x02\x11\x01\x03\x11\x01"
  # the Huffman tables
  for (cls, id, bits, vals) in [(0, 0, @dcLumaBits, @dcLumaVals), (1, 0, @acLumaBits, @acLumaVals),
                                (0, 1, @dcChromaBits, @dcChromaVals), (1, 1, @acChromaBits, @acChromaVals)]:
    o.add "\xFF\xC4"; u16(19 + vals.len); o.add char(cls * 16 + id)
    for v in bits: o.add char(v)
    for v in vals: o.add char(v)
  # an MCU: 8 x 8 pixels (or 16 x 16 with the colors at half size); a
  # restart after each row of them, so the rows are coded at once on all
  # the cores and put one after the other
  let mcu = 8 * sub
  let mcusX = (b.w + mcu - 1) div mcu
  let mcusY = (b.h + mcu - 1) div mcu
  o.add "\xFF\xDD"; u16(4); u16(mcusX)
  o.add "\xFF\xDA"; u16(12); o.add '\x03'; o.add "\x01\x00\x02\x11\x03\x11"; o.add "\x00\x3F\x00"
  let fl = divisors(ql)
  let fc = divisors(qc)
  let dcL = makeCodes(dcLumaBits, dcLumaVals)
  let acL = makeCodes(acLumaBits, acLumaVals)
  let dcC = makeCodes(dcChromaBits, dcChromaVals)
  let acC = makeCodes(acChromaBits, acChromaVals)
  let src = cast[ptr UncheckedArray[uint32]](unsafeAddr b.px[0])
  let bw = b.w
  let bh = b.h
  const bandRows = 32
  var outs = newSeq[seq[byte]](bandRows)
  let op = cast[ptr UncheckedArray[seq[byte]]](addr outs[0])
  var my0 = 0
  while my0 < mcusY:
    let rows = min(bandRows, mcusY - my0)
    let first = my0
    let job = proc (lo, hi: int) =
      var yb, cb, cr: array[256, float32]
      var blk: array[64, float32]
      for k in lo ..< hi:
        let my = first + k
        var buf = newSeqOfCap[byte](mcusX * 64)
        var bitAcc = 0'u64
        var nbits = 0
        template put(code, len: int) =
          bitAcc = (bitAcc shl uint64(len)) or uint64(code and ((1 shl len) - 1))
          nbits += len
          while nbits >= 8:
            let v = byte((bitAcc shr uint64(nbits - 8)) and 0xFF)
            buf.add v
            if v == 0xFF: buf.add 0
            nbits -= 8
        template bitsOf(v: int): (int, int) =
          let a = abs(v)
          let n = if a == 0: 0 else: 64 - countLeadingZeroBits(uint64(a))
          ((if v < 0: v + (1 shl n) - 1 else: v), n)
        var prev = [0, 0, 0]
        for mx in 0 ..< mcusX:
          let x0 = mx * mcu
          let y0 = my * mcu
          # the MCU's colors as Y, Cb, Cr
          for y in 0 ..< mcu:
            let row = min(bh - 1, y0 + y) * bw
            for x in 0 ..< mcu:
              let p = src[row + min(bw - 1, x0 + x)]
              let r = float32((p shr 16) and 255)
              let g = float32((p shr 8) and 255)
              let bl = float32(p and 255)
              yb[y * mcu + x] = 0.299'f32 * r + 0.587'f32 * g + 0.114'f32 * bl - 128
              cb[y * mcu + x] = -0.168736'f32 * r - 0.331264'f32 * g + 0.5'f32 * bl
              cr[y * mcu + x] = 0.5'f32 * r - 0.418688'f32 * g - 0.081312'f32 * bl
          template code(c: int; qt: array[64, float32]; dc, ac: HuffCode) =
            fdct(blk)
            var z: array[64, int]
            for i in 0 .. 63:
              let v = blk[zigzag[i]] * qt[zigzag[i]]
              z[i] = if v >= 0: int(v + 0.5'f32) else: -int(0.5'f32 - v)
            let diff = z[0] - prev[c]
            prev[c] = z[0]
            let (dv, dn) = bitsOf(diff)
            put(dc[dn].code, dc[dn].len)
            if dn > 0: put(dv, dn)
            var run = 0
            for i in 1 .. 63:
              let zi = z[i]
              if zi == 0:
                inc run
                continue
              while run >= 16:
                put(ac[0xF0].code, ac[0xF0].len)
                run -= 16
              let (av, an) = bitsOf(zi)
              let sym = run * 16 + an
              put(ac[sym].code, ac[sym].len)
              put(av, an)
              run = 0
            if run > 0: put(ac[0].code, ac[0].len)
          for by in 0 ..< sub:
            for bx in 0 ..< sub:
              for y in 0 .. 7:
                for x in 0 .. 7: blk[y * 8 + x] = yb[(by * 8 + y) * mcu + bx * 8 + x]
              code(0, fl, dcL, acL)
          for c in 1 .. 2:
            let plane = if c == 1: addr cb else: addr cr
            for y in 0 .. 7:
              for x in 0 .. 7:
                if sub == 1: blk[y * 8 + x] = plane[][y * 8 + x]
                else:
                  # (the average of four)
                  let a = (y * 2) * 16 + x * 2
                  blk[y * 8 + x] = (plane[][a] + plane[][a + 1] + plane[][a + 16] + plane[][a + 17]) * 0.25'f32
            code(c, fc, dcC, acC)
        if nbits > 0: put(0x7F, 8 - nbits)     # (the last byte filled with ones)
        op[k] = buf
    parallelFor(rows, job)
    for k in 0 ..< rows:
      let my = first + k
      let bytes = op[k]
      if bytes.len > 0:
        let at = o.len
        o.setLen(at + bytes.len)
        copyMem(addr o[at], unsafeAddr bytes[0], bytes.len)
      if my < mcusY - 1: o.add "\xFF" & char(0xD0 + (my mod 8))    # RSTn
      op[k] = @[]
    if onUiThread(): busyFraction = (my0 + rows) / mcusY
    busyTick()
    my0 += rows
  o.add "\xFF\xD9"
  if onUiThread(): busyFraction = -1
  o
