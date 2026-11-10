## OpenEXR pictures (.exr), in plain Nim: the light of a render, a scan or
## a merge to HDR kept as floating point numbers (linear, 1 the white of
## the screen and more brighter), as `retroui/photohdr` keeps it.
##
## Read: scanline and tiled files (of a mipmapped or ripmapped file its
## full-size level), half, float and uint channels (a uint's value as a
## float), compressed with none, RLE, ZIPS, ZIP, PIZ, PXR24, B44 or B44A;
## the data window placed on the display window (transparent black where
## there is no data); the first part of a multi-part file. R G B A are
## read (a layer's "beauty.R" ... when the file has no plain R G B); a Y
## (luminance) file becomes gray, with RY BY its colors (each pixel's
## nearest chroma sample: not filtered as OpenEXR's RGBA interface does).
## Not read: DWAA, DWAB, HTJ2K, deep files. Damaged files raise
## `ValueError`; the file is read on all the cores.
##
## Write: scanline files, half or float, R G B and A (A left out when
## every pixel's alpha is 1), compressed with none, RLE, ZIPS, ZIP or PIZ.
##
## ```nim
## let e = readExr(readFile("render.exr"))        # 4 floats a pixel: R G B A
## echo e.channels                                # every channel in the file
## let d = docFromLight(e.w, e.h, e.px)           # (retroui/photohdr) a 32-bit document
## writeFile("out.exr", writeExr(e.w, e.h, e.px, half = true, compression = "piz"))
## ```

import std/[math, strutils, heapqueue]
import codec, parallel

# ---- half floats ----------------------------------------------------------------------------------------------

var halfTable: array[65536, float32]
for i in 0 .. 65535:
  let s = uint32(i and 0x8000) shl 16
  let e = (i shr 10) and 0x1F
  let m = uint32(i and 0x3FF)
  var bits: uint32
  if e == 0:
    if m == 0: bits = s
    else:
      # (a subnormal half: a normal float)
      var ee = 113'u32
      var mm = m
      while (mm and 0x400) == 0:
        mm = mm shl 1
        dec ee
      bits = s or (ee shl 23) or ((mm and 0x3FF) shl 13)
  elif e == 31: bits = s or 0x7F800000'u32 or (m shl 13)
  else: bits = s or (uint32(e + 112) shl 23) or (m shl 13)
  halfTable[i] = cast[float32](bits)

proc halfToFloat*(h: uint16): float32 {.inline.} =
  ## A half float (16 bits) as a float, exactly.
  halfTable[h]

proc floatToHalf*(f: float32): uint16 =
  ## A float as the nearest half float (ties to even; too big: infinity).
  let x = cast[uint32](f)
  let sign = (x shr 16) and 0x8000
  let e = int((x shr 23) and 0xFF)
  var m = x and 0x7FFFFF
  if e == 255:
    if m == 0: return uint16(sign or 0x7C00)
    m = m shr 13
    return uint16(sign or 0x7C00 or m or uint32(m == 0))      # (NaN stays NaN)
  let he = e - 112
  if he >= 31: return uint16(sign or 0x7C00)
  if he <= 0:
    if he < -10: return uint16(sign)
    m = m or 0x800000
    let shift = 14 - he
    var hm = m shr shift
    let rest = m and ((1'u32 shl shift) - 1)
    let half = 1'u32 shl (shift - 1)
    if rest > half or (rest == half and (hm and 1) == 1): inc hm
    return uint16(sign or hm)
  var r = sign or (uint32(he) shl 10) or (m shr 13)
  let rest = m and 0x1FFF
  if rest > 0x1000 or (rest == 0x1000 and (r and 1) == 1): inc r   # (a carry into the exponent is right)
  uint16(r)

# ---- the file's header -----------------------------------------------------------------------------------------

const
  cNone = 0
  cRle = 1
  cZips = 2
  cZip = 3
  cPiz = 4
  cPxr24 = 5
  cB44 = 6
  cB44a = 7
  linesOf = [1, 1, 1, 16, 32, 16, 32, 32, 32, 256]   # scanlines a block, by compression
  compressionNames = ["none", "RLE", "ZIPS", "ZIP", "PIZ", "PXR24", "B44", "B44A", "DWAA", "DWAB"]
  MaxSide = 65535
  MaxPixels = 134_217_728      # (2 GB of floats read)
  MaxChannels = 1024
  MaxBlock = 1 shl 30          # (bytes of one block's pixels)

type
  Chan = object
    name: string
    kind: int            # 0 uint, 1 half, 2 float
    pLinear: bool
    xs, ys: int          # sampling
  Header = object
    chans: seq[Chan]
    compression: int
    dx0, dy0, dx1, dy1: int          # data window
    vx0, vy0, vx1, vy1: int          # display window
    tiled: bool
    tileW, tileH, levelMode, roundUp: int
    chunkCount: int                  # (multi-part files say it)
    kind: string                     # "type": scanlineimage, tiledimage, deep...

proc bad(msg: string) {.noreturn.} = raise newException(ValueError, "EXR: " & msg)

proc u32At(s: string; i: int): uint32 {.inline.} =
  if i < 0 or i + 4 > s.len: bad("cut short")
  uint32(ord(s[i])) or (uint32(ord(s[i + 1])) shl 8) or (uint32(ord(s[i + 2])) shl 16) or (uint32(ord(s[i + 3])) shl 24)

proc i32At(s: string; i: int): int {.inline.} = int(cast[int32](u32At(s, i)))

proc u64At(s: string; i: int): uint64 {.inline.} =
  uint64(u32At(s, i)) or (uint64(u32At(s, i + 4)) shl 32)

proc cstrAt(s: string; i: var int): string =
  ## A name ended by a 0 byte.
  let e = s.find('\0', i)
  if e < 0: bad("cut short")
  result = s[i ..< e]
  i = e + 1

proc typeSize(kind: int): int {.inline.} = (if kind == 1: 2 else: 4)

proc divp(a, b: int): int {.inline.} =
  ## Division rounding down (`b` > 0).
  if a >= 0: a div b else: -((b - 1 - a) div b)

proc modp(a, b: int): int {.inline.} = a - b * divp(a, b)

proc numSamples(s, a, b: int): int {.inline.} =
  ## How many multiples of `s` there are in `a .. b`.
  let a1 = divp(a, s)
  let b1 = divp(b, s)
  b1 - a1 + (if a1 * s < a: 0 else: 1)

proc readHeader(s: string; at: var int): Header =
  ## One header: attributes up to an empty name.
  result.compression = cNone
  var seen = false
  while true:
    let name = cstrAt(s, at)
    if name.len == 0: break
    let kind = cstrAt(s, at)
    let size = i32At(s, at)
    at += 4
    if size < 0 or at + size > s.len: bad("cut short")
    let v = at
    case name
    of "channels":
      if kind != "chlist": bad("channels of an unknown kind")
      var p = v
      while p < v + size:
        let cn = cstrAt(s, p)
        if cn.len == 0: break
        if p + 16 > v + size: bad("damaged channel list")
        var c = Chan(name: cn, kind: i32At(s, p), pLinear: s[p + 4] != '\0', xs: i32At(s, p + 8), ys: i32At(s, p + 12))
        if c.kind notin 0 .. 2: bad("a channel of an unknown kind")
        if c.xs < 1 or c.ys < 1 or c.xs > 1024 or c.ys > 1024: bad("bad sampling")
        result.chans.add c
        p += 16
      seen = true
    of "compression":
      if size < 1: bad("damaged")
      result.compression = ord(s[v])
    of "dataWindow", "displayWindow":
      if size < 16: bad("damaged")
      let a = [i32At(s, v), i32At(s, v + 4), i32At(s, v + 8), i32At(s, v + 12)]
      if name == "dataWindow":
        (result.dx0, result.dy0, result.dx1, result.dy1) = (a[0], a[1], a[2], a[3])
      else:
        (result.vx0, result.vy0, result.vx1, result.vy1) = (a[0], a[1], a[2], a[3])
    of "tiles":
      if size < 9: bad("damaged")
      result.tileW = int(u32At(s, v))
      result.tileH = int(u32At(s, v + 4))
      result.levelMode = ord(s[v + 8]) and 15
      result.roundUp = ord(s[v + 8]) shr 4
    of "chunkCount":
      if size >= 4: result.chunkCount = i32At(s, v)
    of "type":
      result.kind = s[v ..< v + size].strip(chars = {'\0'})
    else: discard
    at += size
  if not seen: bad("no channels")
  if result.chans.len > MaxChannels: bad("too many channels")

# ---- levels and tiles ------------------------------------------------------------------------------------------

proc roundLog2(x, up: int): int =
  var y = 0
  if up == 0:
    var v = x
    while v > 1:
      v = v shr 1
      inc y
  else:
    var v = 1
    while v < x:
      v = v shl 1
      inc y
  y

proc levelSize(n, l, up: int): int =
  let b = 1 shl l
  var size = n div b
  if up != 0 and size * b < n: inc size
  max(size, 1)

proc tileCount(h: Header): tuple[level0, all: int] =
  ## Tiles of the full-size level, and of every level.
  let w = h.dx1 - h.dx0 + 1
  let hh = h.dy1 - h.dy0 + 1
  proc tiles(lw, lh: int): int = ((lw + h.tileW - 1) div h.tileW) * ((lh + h.tileH - 1) div h.tileH)
  result.level0 = tiles(w, hh)
  case h.levelMode
  of 1:
    let n = roundLog2(max(w, hh), h.roundUp) + 1
    for l in 0 ..< n: result.all += tiles(levelSize(w, l, h.roundUp), levelSize(hh, l, h.roundUp))
  of 2:
    let nx = roundLog2(w, h.roundUp) + 1
    let ny = roundLog2(hh, h.roundUp) + 1
    for ly in 0 ..< ny:
      for lx in 0 ..< nx: result.all += tiles(levelSize(w, lx, h.roundUp), levelSize(hh, ly, h.roundUp))
  else: result.all = result.level0

# ---- the predictor and byte order of ZIP and RLE ----------------------------------------------------------

proc unpredict(t: var seq[byte]): seq[byte] =
  ## (each byte stored as the difference from the one before; the bytes of
  ## even places first, then the odd: put back)
  let n = t.len
  for i in 1 ..< n: t[i] = byte((int(t[i - 1]) + int(t[i]) - 128) and 255)
  result = newSeqUninit[byte](n)
  let half = (n + 1) div 2
  for i in 0 ..< n div 2:
    result[2 * i] = t[i]
    result[2 * i + 1] = t[half + i]
  if (n and 1) == 1: result[n - 1] = t[half - 1]

proc predict(raw: openArray[byte]): seq[byte] =
  let n = raw.len
  result = newSeqUninit[byte](n)
  let half = (n + 1) div 2
  for i in 0 ..< n div 2:
    result[i] = raw[2 * i]
    result[half + i] = raw[2 * i + 1]
  if (n and 1) == 1: result[half - 1] = raw[n - 1]
  var p = if n > 0: int(result[0]) else: 0
  for i in 1 ..< n:
    let c = int(result[i])
    result[i] = byte((c - p + 128 + 256) and 255)
    p = c

proc rleUnpack(src: openArray[byte]; rawLen: int): seq[byte] =
  var t = newSeqUninit[byte](rawLen)
  var o = 0
  var i = 0
  while i < src.len:
    let c = int(cast[int8](src[i]))
    inc i
    if c < 0:
      let n = -c
      if i + n > src.len or o + n > rawLen: bad("damaged RLE data")
      copyMem(addr t[o], unsafeAddr src[i], n)
      i += n
      o += n
    else:
      let n = c + 1
      if i >= src.len or o + n > rawLen: bad("damaged RLE data")
      for k in 0 ..< n: t[o + k] = src[i]
      inc i
      o += n
  if o != rawLen: bad("RLE data cut short")
  unpredict(t)

proc rlePack(raw: openArray[byte]): seq[byte] =
  let t = predict(raw)
  let n = t.len
  var r = 0
  while r < n:
    var e = r + 1
    while e < n and t[r] == t[e] and e - r - 1 < 127: inc e
    if e - r >= 3:
      result.add byte(e - r - 1)
      result.add t[r]
      r = e
    else:
      while e < n and ((e + 1 >= n or t[e] != t[e + 1]) or (e + 2 >= n or t[e + 1] != t[e + 2])) and e - r < 127: inc e
      result.add byte((r - e) and 255)
      while r < e:
        result.add t[r]
        inc r

proc zipUnpack(src: openArray[byte]; rawLen: int): seq[byte] =
  var t: seq[byte]
  try: t = zlibDecompress(src, rawLen)
  except InflateError as e: bad("damaged ZIP data: " & e.msg)
  if t.len != rawLen: bad("ZIP data cut short")
  unpredict(t)

# ---- PXR24 ----------------------------------------------------------------------------------------------------

proc pxr24Unpack(h: Header; src: openArray[byte]; x0, x1, y0, y1, rawLen: int): seq[byte] =
  var want = 0
  for y in y0 .. y1:
    for c in h.chans:
      if modp(y, c.ys) == 0: want += numSamples(c.xs, x0, x1) * [4, 2, 3][c.kind]
  var t: seq[byte]
  try: t = zlibDecompress(src, want)
  except InflateError as e: bad("damaged PXR24 data: " & e.msg)
  if t.len != want: bad("PXR24 data cut short")
  result = newSeqUninit[byte](rawLen)
  var o = 0
  var p = 0
  for y in y0 .. y1:
    for c in h.chans:
      if modp(y, c.ys) != 0: continue
      let n = numSamples(c.xs, x0, x1)
      var pixel = 0'u32
      case c.kind
      of 0:
        for j in 0 ..< n:
          pixel += (uint32(t[p + j]) shl 24) or (uint32(t[p + n + j]) shl 16) or
                   (uint32(t[p + 2 * n + j]) shl 8) or uint32(t[p + 3 * n + j])
          for k in 0 .. 3: result[o + 4 * j + k] = byte((pixel shr (8 * k)) and 255)
        p += 4 * n
        o += 4 * n
      of 1:
        for j in 0 ..< n:
          pixel += (uint32(t[p + j]) shl 8) or uint32(t[p + n + j])
          result[o + 2 * j] = byte(pixel and 255)
          result[o + 2 * j + 1] = byte((pixel shr 8) and 255)
        p += 2 * n
        o += 2 * n
      else:
        for j in 0 ..< n:
          pixel += (uint32(t[p + j]) shl 24) or (uint32(t[p + n + j]) shl 16) or (uint32(t[p + 2 * n + j]) shl 8)
          for k in 0 .. 3: result[o + 4 * j + k] = byte((pixel shr (8 * k)) and 255)
        p += 3 * n
        o += 4 * n
  if o != rawLen: bad("PXR24 sizes differ")

# ---- PIZ: Huffman codes ----------------------------------------------------------------------------------------

const
  HufEncSize = 65537
  HufDecBits = 14
  ShortZeroRun = 59
  LongZeroRun = 63
  ShortestLongRun = 6

proc canonicalCodes(lens: openArray[int]; codes: var seq[uint64]) =
  ## Codes from lengths, as OpenEXR makes them (shorter codes the higher
  ## numbers; of one length, in the order of the symbols).
  var n: array[59, uint64]
  for l in lens: n[l] += 1
  var c = 0'u64
  for i in countdown(58, 1):
    let nc = (c + n[i]) shr 1
    n[i] = c
    c = nc
  codes.setLen(lens.len)
  for i, l in lens:
    if l > 0:
      codes[i] = n[l]
      n[l] += 1

type BitIn = object
  p: ptr UncheckedArray[byte]
  len, pos: int
  acc: uint64
  nb: int

proc refill(b: var BitIn) {.inline.} =
  while b.nb <= 56:
    b.acc = (b.acc shl 8) or (if b.pos < b.len: uint64(b.p[b.pos]) else: 0'u64)
    inc b.pos
    b.nb += 8

proc take(b: var BitIn; n: int): int {.inline.} =
  b.refill()
  b.nb -= n
  int((b.acc shr b.nb) and ((1'u64 shl n) - 1))

proc hufUncompress(src: openArray[byte]; dst: ptr UncheckedArray[uint16]; nOut: int) =
  if src.len == 0:
    if nOut != 0: bad("PIZ data cut short")
    return
  if src.len < 20: bad("PIZ data cut short")
  template u32(i: int): int =
    int(uint32(src[i]) or (uint32(src[i + 1]) shl 8) or (uint32(src[i + 2]) shl 16) or (uint32(src[i + 3]) shl 24))
  let symLo = u32(0)
  let symHi = u32(4)
  let nBits = u32(12)
  if symLo < 0 or symLo >= HufEncSize or symHi < 0 or symHi >= HufEncSize or symLo > symHi: bad("damaged Huffman table")
  # the code lengths (runs of zeros packed)
  var lens = newSeq[int](HufEncSize)
  var tb = BitIn(p: cast[ptr UncheckedArray[byte]](unsafeAddr src[20]), len: src.len - 20)
  var i = symLo
  while i <= symHi:
    if tb.pos > tb.len: bad("damaged Huffman table")
    let l = tb.take(6)
    if l == LongZeroRun:
      let run = tb.take(8) + ShortestLongRun
      if i + run > symHi + 1: bad("damaged Huffman table")
      i += run
    elif l >= ShortZeroRun:
      let run = l - ShortZeroRun + 2
      if i + run > symHi + 1: bad("damaged Huffman table")
      i += run
    else:
      lens[i] = l
      inc i
  # (whole bytes of the table used: the codes start on the next one)
  let used = (tb.pos * 8 - tb.nb + 7) div 8
  let dataAt = 20 + used
  if dataAt > src.len or nBits > 8 * (src.len - dataAt): bad("damaged Huffman data")
  var codes: seq[uint64]
  canonicalCodes(lens, codes)
  # a table for codes of 14 bits or fewer; longer ones looked for by length
  var lut = newSeq[int32](1 shl HufDecBits)
  var count: array[59, int]
  var base: array[59, uint64]
  var first: array[60, int]
  for s in symLo .. symHi:
    let l = lens[s]
    if l == 0: continue
    if (codes[s] shr l) != 0: bad("damaged Huffman table")
    count[l] += 1
    if l <= HufDecBits:
      let a = int(codes[s] shl (HufDecBits - l))
      for k in a ..< a + (1 shl (HufDecBits - l)):
        if lut[k] != 0: bad("damaged Huffman table")
        lut[k] = int32((s shl 6) or l)
  for l in 1 .. 58: first[l + 1] = first[l] + count[l]
  var bySym = newSeq[int32](max(1, first[59]))
  var fill = first
  for s in symLo .. symHi:
    let l = lens[s]
    if l > HufDecBits:
      if fill[l] == first[l]: base[l] = codes[s]
      bySym[fill[l]] = int32(s)
      inc fill[l]
  let rlc = symHi
  var b = BitIn(p: cast[ptr UncheckedArray[byte]](unsafeAddr src[dataAt]), len: src.len - dataAt)
  var usedBits = 0
  var o = 0
  while usedBits < nBits:
    b.refill()
    let e = int(lut[int((b.acc shr (b.nb - HufDecBits)) and ((1 shl HufDecBits) - 1))])
    var sym, l: int
    if (e and 63) != 0:
      l = e and 63
      sym = e shr 6
    else:
      sym = -1
      for k in HufDecBits + 1 .. 58:
        if k > b.nb: break
        if count[k] == 0: continue
        let code = (b.acc shr (b.nb - k)) and ((1'u64 shl k) - 1)
        if code >= base[k] and code - base[k] < uint64(count[k]):
          sym = int(bySym[first[k] + int(code - base[k])])
          l = k
          break
      if sym < 0: bad("damaged Huffman data")
    if usedBits + l > nBits: bad("damaged Huffman data")
    b.nb -= l
    usedBits += l
    if sym == rlc:
      if usedBits + 8 > nBits: bad("damaged Huffman data")
      let cs = b.take(8)
      usedBits += 8
      if o == 0 or o + cs > nOut: bad("damaged Huffman data")
      let v = dst[o - 1]
      for k in 0 ..< cs: dst[o + k] = v
      o += cs
    else:
      if o >= nOut: bad("too much Huffman data")
      dst[o] = uint16(sym)
      inc o
  if o != nOut: bad("Huffman data cut short")

type BitOut = object
  o: seq[byte]
  acc: uint64
  nb: int
  total: int

proc put(b: var BitOut; n: int; v: uint64) {.inline.} =
  if n > 32:
    b.put(n - 32, v shr 32)
    b.put(32, v and 0xFFFFFFFF'u64)
    return
  b.acc = (b.acc shl n) or (v and ((1'u64 shl n) - 1))
  b.nb += n
  b.total += n
  while b.nb >= 8:
    b.nb -= 8
    b.o.add byte((b.acc shr b.nb) and 255)

proc flush(b: var BitOut) =
  if b.nb > 0:
    b.o.add byte((b.acc shl (8 - b.nb)) and 255)
    b.nb = 0

proc huffmanLengths(freq: openArray[int64]; lo, hi: int): seq[int] =
  ## Code lengths for the symbols `lo .. hi` with a count (a Huffman tree).
  result = newSeq[int](HufEncSize)
  var heap: HeapQueue[(int64, int)]
  var parent: seq[int]
  var leaf: seq[int]
  for s in lo .. hi:
    if freq[s] > 0:
      heap.push((freq[s], parent.len))
      parent.add -1
      leaf.add s
  if parent.len == 1:
    result[leaf[0]] = 1
    return
  while heap.len > 1:
    let a = heap.pop()
    let b = heap.pop()
    let n = parent.len
    parent.add -1
    parent[a[1]] = n
    parent[b[1]] = n
    heap.push((a[0] + b[0], n))
  # depths: parents come after their children
  var depth = newSeq[int](parent.len)
  for k in countdown(parent.len - 2, 0): depth[k] = depth[parent[k]] + 1
  for k, s in leaf:
    if depth[k] > 58: bad("a Huffman code too long")
    result[s] = depth[k]

proc hufCompress(data: openArray[uint16]): seq[byte] =
  if data.len == 0: return
  var freq = newSeq[int64](HufEncSize)
  for v in data: freq[v] += 1
  var symLo = 0
  while freq[symLo] == 0: inc symLo
  var symHi = HufEncSize - 2
  while freq[symHi] == 0: dec symHi
  inc symHi                                  # (the symbol saying "repeat the last")
  freq[symHi] = 1
  let lens = huffmanLengths(freq, symLo, symHi)
  var codes: seq[uint64]
  canonicalCodes(lens, codes)
  var t = BitOut()
  var i = symLo
  while i <= symHi:
    let l = lens[i]
    if l == 0:
      var run = 1
      while i < symHi and run < 255 + ShortestLongRun:
        if lens[i + 1] > 0: break
        inc i
        inc run
      if run >= 2:
        if run >= ShortestLongRun:
          t.put(6, LongZeroRun)
          t.put(8, uint64(run - ShortestLongRun))
        else:
          t.put(6, uint64(ShortZeroRun + run - 2))
        inc i
        continue
    t.put(6, uint64(l))
    inc i
  t.flush()
  var d = BitOut()
  let rlc = symHi
  template code(s: int) = d.put(lens[s], codes[s])
  template send(s, run: int) =
    if lens[s] + lens[rlc] + 8 < lens[s] * run:
      code(s)
      code(rlc)
      d.put(8, uint64(run))
    else:
      for k in 0 .. run: code(s)
  var s = int(data[0])
  var cs = 0
  for k in 1 ..< data.len:
    let v = int(data[k])
    if s == v and cs < 255: inc cs
    else:
      send(s, cs)
      cs = 0
    s = v
  send(s, cs)
  let nBits = d.total
  d.flush()
  result = newSeqOfCap[byte](20 + t.o.len + d.o.len)
  for v in [symLo, symHi, t.o.len, nBits, 0]:
    for k in 0 .. 3: result.add byte((v shr (8 * k)) and 255)
  result.add t.o
  result.add d.o

# ---- PIZ: the wavelet ------------------------------------------------------------------------------------------

proc wdec14(l, h: uint16; a, b: var uint16) {.inline.} =
  let ls = int(cast[int16](l))
  let hi = int(cast[int16](h))
  let ai = ls + (hi and 1) + ashr(hi, 1)
  a = uint16(ai and 0xFFFF)
  b = uint16((ai - hi) and 0xFFFF)

proc wenc14(a, b: uint16; l, h: var uint16) {.inline.} =
  let sa = int(cast[int16](a))
  let sb = int(cast[int16](b))
  l = uint16(ashr(sa + sb, 1) and 0xFFFF)
  h = uint16((sa - sb) and 0xFFFF)

proc wdec16(l, h: uint16; a, b: var uint16) {.inline.} =
  let m = int(l)
  let d = int(h)
  let bb = (m - (d shr 1)) and 0xFFFF
  let aa = (d + bb - 0x8000) and 0xFFFF
  b = uint16(bb)
  a = uint16(aa)

proc wenc16(a, b: uint16; l, h: var uint16) {.inline.} =
  let ao = (int(a) + 0x8000) and 0xFFFF
  var m = (ao + int(b)) shr 1
  var d = ao - int(b)
  if d < 0: m = (m + 0x8000) and 0xFFFF
  d = d and 0xFFFF
  l = uint16(m)
  h = uint16(d)

type Words = ptr UncheckedArray[uint16]

proc wav2Decode(t: Words; start, nx, ox, ny, oy, mx: int) =
  let w14 = mx < (1 shl 14)
  let n = min(nx, ny)
  var p = 1
  while p <= n: p = p shl 1
  p = p shr 1
  var p2 = p
  p = p shr 1
  var i00, i01, i10, i11: uint16
  template dec2(a, b: uint16; c, d: var uint16) =
    if w14: wdec14(a, b, c, d) else: wdec16(a, b, c, d)
  while p >= 1:
    var py = start
    let ey = start + oy * (ny - p2)
    let oy1 = oy * p
    let oy2 = oy * p2
    let ox1 = ox * p
    let ox2 = ox * p2
    while py <= ey:
      var px = py
      let ex = py + ox * (nx - p2)
      while px <= ex:
        let p01 = px + ox1
        let p10 = px + oy1
        let p11 = p10 + ox1
        dec2(t[px], t[p10], i00, i10)
        dec2(t[p01], t[p11], i01, i11)
        dec2(i00, i01, t[px], t[p01])
        dec2(i10, i11, t[p10], t[p11])
        px += ox2
      if (nx and p) != 0:
        let p10 = px + oy1
        dec2(t[px], t[p10], i00, t[p10])
        t[px] = i00
      py += oy2
    if (ny and p) != 0:
      var px = py
      let ex = py + ox * (nx - p2)
      while px <= ex:
        let p01 = px + ox1
        dec2(t[px], t[p01], i00, t[p01])
        t[px] = i00
        px += ox2
    p2 = p
    p = p shr 1

proc wav2Encode(t: Words; start, nx, ox, ny, oy, mx: int) =
  let w14 = mx < (1 shl 14)
  let n = min(nx, ny)
  var p = 1
  var p2 = 2
  var i00, i01, i10, i11: uint16
  template enc2(a, b: uint16; c, d: var uint16) =
    if w14: wenc14(a, b, c, d) else: wenc16(a, b, c, d)
  while p2 <= n:
    var py = start
    let ey = start + oy * (ny - p2)
    let oy1 = oy * p
    let oy2 = oy * p2
    let ox1 = ox * p
    let ox2 = ox * p2
    while py <= ey:
      var px = py
      let ex = py + ox * (nx - p2)
      while px <= ex:
        let p01 = px + ox1
        let p10 = px + oy1
        let p11 = p10 + ox1
        enc2(t[px], t[p01], i00, i01)
        enc2(t[p10], t[p11], i10, i11)
        enc2(i00, i10, t[px], t[p10])
        enc2(i01, i11, t[p01], t[p11])
        px += ox2
      if (nx and p) != 0:
        let p10 = px + oy1
        enc2(t[px], t[p10], i00, t[p10])
        t[px] = i00
      py += oy2
    if (ny and p) != 0:
      var px = py
      let ex = py + ox * (nx - p2)
      while px <= ex:
        let p01 = px + ox1
        enc2(t[px], t[p01], i00, t[p01])
        t[px] = i00
        px += ox2
    p = p2
    p2 = p2 shl 1

# ---- PIZ: the whole -----------------------------------------------------------------------------------------

type Region = tuple[start, nx, ny, size, ys: int]

proc regions(h: Header; x0, x1, y0, y1: int; total: var int): seq[Region] =
  ## Where each channel's 16-bit words go (PIZ, B44: one channel after another).
  var at = 0
  for c in h.chans:
    let r: Region = (at, numSamples(c.xs, x0, x1), numSamples(c.ys, y0, y1), typeSize(c.kind) div 2, c.ys)
    result.add r
    at += r.nx * r.ny * r.size
  total = at

proc pizUnpack(h: Header; src: openArray[byte]; x0, x1, y0, y1, rawLen: int): seq[byte] =
  var total = 0
  let regs = h.regions(x0, x1, y0, y1, total)
  if total * 2 != rawLen: bad("PIZ sizes differ")
  if src.len < 4: bad("PIZ data cut short")
  let minNZ = int(src[0]) or (int(src[1]) shl 8)
  let maxNZ = int(src[2]) or (int(src[3]) shl 8)
  if maxNZ >= 8192: bad("damaged PIZ data")
  var bitmap: array[8192, uint8]
  var p = 4
  if minNZ <= maxNZ:
    if p + maxNZ - minNZ + 1 > src.len: bad("PIZ data cut short")
    for k in minNZ .. maxNZ: bitmap[k] = src[p + k - minNZ]
    p += maxNZ - minNZ + 1
  # (the values used, numbered in order: back to the values)
  var lut = newSeq[uint16](65536)
  var k = 0
  for i in 0 ..< 65536:
    if i == 0 or (bitmap[i shr 3] and uint8(1 shl (i and 7))) != 0:
      lut[k] = uint16(i)
      inc k
  let maxValue = k - 1
  if p + 4 > src.len: bad("PIZ data cut short")
  let length = int(cast[int32](uint32(src[p]) or (uint32(src[p + 1]) shl 8) or (uint32(src[p + 2]) shl 16) or
                              (uint32(src[p + 3]) shl 24)))
  p += 4
  if length < 0 or p + length > src.len: bad("PIZ data cut short")
  var tmp = newSeq[uint16](max(1, total))
  let t = cast[Words](addr tmp[0])
  hufUncompress(src.toOpenArray(p, p + length - 1), t, total)
  for r in regs:
    for j in 0 ..< r.size: wav2Decode(t, r.start + j, r.nx, r.size, r.ny, r.nx * r.size, maxValue)
  for i in 0 ..< total: tmp[i] = lut[tmp[i]]
  result = newSeqUninit[byte](rawLen)
  var cur = newSeq[int](regs.len)
  for i, r in regs: cur[i] = r.start
  var o = 0
  for y in y0 .. y1:
    for i, r in regs:
      if modp(y, r.ys) != 0: continue
      let n = r.nx * r.size
      for j in 0 ..< n:
        let v = tmp[cur[i] + j]
        result[o] = byte(v and 255)
        result[o + 1] = byte(v shr 8)
        o += 2
      cur[i] += n

proc pizPack(h: Header; raw: openArray[byte]; x0, x1, y0, y1: int): seq[byte] =
  var total = 0
  let regs = h.regions(x0, x1, y0, y1, total)
  var tmp = newSeq[uint16](max(1, total))
  var cur = newSeq[int](regs.len)
  for i, r in regs: cur[i] = r.start
  var q = 0
  for y in y0 .. y1:
    for i, r in regs:
      if modp(y, r.ys) != 0: continue
      for j in 0 ..< r.nx * r.size:
        tmp[cur[i] + j] = uint16(raw[q]) or (uint16(raw[q + 1]) shl 8)
        q += 2
      cur[i] += r.nx * r.size
  var bitmap: array[8192, uint8]
  for i in 0 ..< total: bitmap[tmp[i] shr 3] = bitmap[tmp[i] shr 3] or uint8(1 shl (tmp[i] and 7))
  bitmap[0] = bitmap[0] and 0xFE                 # (zero is always there)
  var minNZ = 8191
  var maxNZ = 0
  for i in 0 ..< 8192:
    if bitmap[i] != 0:
      minNZ = min(minNZ, i)
      maxNZ = max(maxNZ, i)
  var lut = newSeq[uint16](65536)
  var k = 0
  for i in 0 ..< 65536:
    if i == 0 or (bitmap[i shr 3] and uint8(1 shl (i and 7))) != 0:
      lut[i] = uint16(k)
      inc k
  let maxValue = k - 1
  for i in 0 ..< total: tmp[i] = lut[tmp[i]]
  let t = cast[Words](addr tmp[0])
  for r in regs:
    for j in 0 ..< r.size: wav2Encode(t, r.start + j, r.nx, r.size, r.ny, r.nx * r.size, maxValue)
  result.add [byte(minNZ and 255), byte(minNZ shr 8), byte(maxNZ and 255), byte(maxNZ shr 8)]
  if minNZ <= maxNZ:
    for i in minNZ .. maxNZ: result.add bitmap[i]
  let huf = hufCompress(tmp.toOpenArray(0, total - 1))
  for s in 0 .. 3: result.add byte((huf.len shr (8 * s)) and 255)
  result.add huf

# ---- B44 and B44A ---------------------------------------------------------------------------------------------

var logTable: array[65536, uint16]     # (B44's perceptually linear channels: kept as 8 ln x)
for i in 0 ..< 65536:
  let f = halfTable[i]
  logTable[i] = if (i and 0x7C00) == 0x7C00 or f < 0: 0'u16 else: floatToHalf(float32(8 * ln(float(f))))

proc unpack14(b: openArray[byte]; at: int; s: var array[16, uint16]) =
  template B(i: int): int = int(b[at + i])
  var v: array[16, int]
  v[0] = (B(0) shl 8) or B(1)
  # (every value is kept to 16 bits: a shift past 16 adds nothing more --
  # and past 31 it would be undefined where `int` has 32 bits)
  let shift = min(B(2) shr 2, 16)
  let bias = 0x20 shl shift
  template d(x: int): int = ((x and 0x3F) shl shift) - bias
  v[4] = (v[0] + d((B(2) shl 4) or (B(3) shr 4))) and 0xFFFF
  v[8] = (v[4] + d((B(3) shl 2) or (B(4) shr 6))) and 0xFFFF
  v[12] = (v[8] + d(B(4))) and 0xFFFF
  v[1] = (v[0] + d(B(5) shr 2)) and 0xFFFF
  v[5] = (v[4] + d((B(5) shl 4) or (B(6) shr 4))) and 0xFFFF
  v[9] = (v[8] + d((B(6) shl 2) or (B(7) shr 6))) and 0xFFFF
  v[13] = (v[12] + d(B(7))) and 0xFFFF
  v[2] = (v[1] + d(B(8) shr 2)) and 0xFFFF
  v[6] = (v[5] + d((B(8) shl 4) or (B(9) shr 4))) and 0xFFFF
  v[10] = (v[9] + d((B(9) shl 2) or (B(10) shr 6))) and 0xFFFF
  v[14] = (v[13] + d(B(10))) and 0xFFFF
  v[3] = (v[2] + d(B(11) shr 2)) and 0xFFFF
  v[7] = (v[6] + d((B(11) shl 4) or (B(12) shr 4))) and 0xFFFF
  v[11] = (v[10] + d((B(12) shl 2) or (B(13) shr 6))) and 0xFFFF
  v[15] = (v[14] + d(B(13))) and 0xFFFF
  for i in 0 ..< 16:
    s[i] = if (v[i] and 0x8000) != 0: uint16(v[i] and 0x7FFF) else: uint16((not v[i]) and 0xFFFF)

proc b44Unpack(h: Header; src: openArray[byte]; x0, x1, y0, y1, rawLen: int): seq[byte] =
  var total = 0
  let regs = h.regions(x0, x1, y0, y1, total)
  if total * 2 != rawLen: bad("B44 sizes differ")
  var tmp = newSeq[uint16](max(1, total))
  var ip = 0
  for ci, r in regs:
    let c = h.chans[ci]
    if c.kind != 1:
      let n = r.nx * r.ny * r.size * 2
      if ip + n > src.len: bad("B44 data cut short")
      for j in 0 ..< n div 2: tmp[r.start + j] = uint16(src[ip + 2 * j]) or (uint16(src[ip + 2 * j + 1]) shl 8)
      ip += n
      continue
    var s: array[16, uint16]
    for y in countup(0, r.ny - 1, 4):
      for x in countup(0, r.nx - 1, 4):
        if ip + 3 > src.len: bad("B44 data cut short")
        if src[ip + 2] == 0xFC:
          # (a flat block: 3 bytes)
          var v = (int(src[ip]) shl 8) or int(src[ip + 1])
          v = if (v and 0x8000) != 0: v and 0x7FFF else: (not v) and 0xFFFF
          for i in 0 ..< 16: s[i] = uint16(v)
          ip += 3
        else:
          if ip + 14 > src.len: bad("B44 data cut short")
          unpack14(src, ip, s)
          ip += 14
        if c.pLinear:
          for i in 0 ..< 16: s[i] = logTable[s[i]]
        for dy in 0 .. 3:
          if y + dy >= r.ny: break
          for dx in 0 .. 3:
            if x + dx >= r.nx: break
            tmp[r.start + (y + dy) * r.nx + x + dx] = s[dy * 4 + dx]
  result = newSeqUninit[byte](rawLen)
  var cur = newSeq[int](regs.len)
  for i, r in regs: cur[i] = r.start
  var o = 0
  for y in y0 .. y1:
    for i, r in regs:
      if modp(y, r.ys) != 0: continue
      let n = r.nx * r.size
      for j in 0 ..< n:
        let v = tmp[cur[i] + j]
        result[o] = byte(v and 255)
        result[o + 1] = byte(v shr 8)
        o += 2
      cur[i] += n

# ---- reading --------------------------------------------------------------------------------------------------

proc isExr*(data: string): bool =
  ## `data` starts like an OpenEXR file.
  data.len >= 8 and data[0] == '\x76' and data[1] == '\x2F' and data[2] == '\x31' and data[3] == '\x01'

type
  Target = object
    slot: int                  # 0..3 R G B A; 4 gray (Y); 5 RY; 6 BY; -1 not read
    plane: int                 # its own plane (subsampled), else -1
  Out = object
    px: ptr UncheckedArray[float32]
    w, h, vx0, vy0: int
    planes: ptr UncheckedArray[seq[float32]]
    pw, ph, px0, py0: seq[int]  # each plane's size and first sample (in samples)

proc sampleAt(raw: ptr UncheckedArray[byte]; at, kind: int): float32 {.inline.} =
  case kind
  of 1: halfTable[uint16(raw[at]) or (uint16(raw[at + 1]) shl 8)]
  of 2:
    let u = uint32(raw[at]) or (uint32(raw[at + 1]) shl 8) or (uint32(raw[at + 2]) shl 16) or (uint32(raw[at + 3]) shl 24)
    cast[float32](u)
  else:
    let u = uint32(raw[at]) or (uint32(raw[at + 1]) shl 8) or (uint32(raw[at + 2]) shl 16) or (uint32(raw[at + 3]) shl 24)
    float32(u)

proc scatter(h: Header; tg: seq[Target]; raw: ptr UncheckedArray[byte]; rawLen: int; x0, x1, y0, y1: int; o: Out) =
  ## A block's pixels (line after line, channel after channel) to where they go.
  var p = 0
  for y in y0 .. y1:
    for ci, c in h.chans:
      if modp(y, c.ys) != 0: continue
      let n = numSamples(c.xs, x0, x1)
      let sz = typeSize(c.kind)
      if p + n * sz > rawLen: bad("block cut short")
      let t = tg[ci]
      if t.slot >= 0:
        if t.plane >= 0:
          let row = divp(y, c.ys) - o.py0[t.plane]
          let col0 = divp(x0 + c.xs - 1, c.xs) - o.px0[t.plane]
          if row >= 0 and row < o.ph[t.plane]:
            let pl = cast[ptr UncheckedArray[float32]](addr o.planes[t.plane][0])
            for j in 0 ..< n:
              let col = col0 + j
              if col >= 0 and col < o.pw[t.plane]: pl[row * o.pw[t.plane] + col] = sampleAt(raw, p + j * sz, c.kind)
        else:
          let oy = y - o.vy0
          if oy >= 0 and oy < o.h:
            let a = max(x0, o.vx0)
            let b = min(x1, o.vx0 + o.w - 1)
            let row = oy * o.w - o.vx0
            if t.slot == 4:
              for x in a .. b:
                let v = sampleAt(raw, p + (x - x0) * sz, c.kind)
                let q = (row + x) * 4
                o.px[q] = v
                o.px[q + 1] = v
                o.px[q + 2] = v
            elif c.kind == 1:
              for x in a .. b:
                let at = p + (x - x0) * 2
                o.px[(row + x) * 4 + t.slot] = halfTable[uint16(raw[at]) or (uint16(raw[at + 1]) shl 8)]
            else:
              for x in a .. b: o.px[(row + x) * 4 + t.slot] = sampleAt(raw, p + (x - x0) * sz, c.kind)
      p += n * sz

proc readChunk(data: string; h: Header; tg: seq[Target]; o: Out; multi: bool; lpb, at: int) =
  ## One chunk (a block of scanlines, a tile): unpacked and put in place.
  var p = at
  if multi:
    if i32At(data, p) != 0: bad("a chunk of another part")
    p += 4
  var x0, x1, y0, y1: int
  if h.tiled:
    let tx = i32At(data, p)
    let ty = i32At(data, p + 4)
    if i32At(data, p + 8) != 0 or i32At(data, p + 12) != 0: return    # (a smaller level)
    if tx < 0 or ty < 0 or tx > MaxSide or ty > MaxSide: bad("a tile outside the picture")
    x0 = h.dx0 + tx * h.tileW
    y0 = h.dy0 + ty * h.tileH
    if x0 > h.dx1 or y0 > h.dy1: bad("a tile outside the picture")
    x1 = min(x0 + h.tileW - 1, h.dx1)
    y1 = min(y0 + h.tileH - 1, h.dy1)
    p += 16
  else:
    y0 = i32At(data, p)
    if y0 < h.dy0 or y0 > h.dy1 or (y0 - h.dy0) mod lpb != 0: bad("a chunk outside the picture")
    y1 = min(y0 + lpb - 1, h.dy1)
    x0 = h.dx0
    x1 = h.dx1
    p += 4
  let size = i32At(data, p)
  p += 4
  if size < 0 or p + size > data.len: bad("cut short")
  var rawLen = 0
  for y in y0 .. y1:
    for c in h.chans:
      if modp(y, c.ys) == 0: rawLen += numSamples(c.xs, x0, x1) * typeSize(c.kind)
  if rawLen > MaxBlock: bad("a block too big")
  if size == rawLen or h.compression == cNone:
    # (stored as it is: no smaller compressed)
    if size != rawLen: bad("a block of the wrong size")
    if size > 0: h.scatter(tg, cast[ptr UncheckedArray[byte]](unsafeAddr data[p]), size, x0, x1, y0, y1, o)
    return
  if size > rawLen: bad("a block bigger than its pixels")
  template src: untyped = data.toOpenArrayByte(p, p + size - 1)
  let raw = case h.compression
            of cRle: rleUnpack(src, rawLen)
            of cZips, cZip: zipUnpack(src, rawLen)
            of cPiz: h.pizUnpack(src, x0, x1, y0, y1, rawLen)
            of cPxr24: h.pxr24Unpack(src, x0, x1, y0, y1, rawLen)
            else: h.b44Unpack(src, x0, x1, y0, y1, rawLen)
  if raw.len > 0: h.scatter(tg, cast[ptr UncheckedArray[byte]](unsafeAddr raw[0]), raw.len, x0, x1, y0, y1, o)

proc readExrFile(data: string): tuple[w, h: int; px: seq[float32]; channels: seq[string]] =
  ## (`readExr`, its checks of sizes made as it goes)
  if not isExr(data): bad("not an OpenEXR file")
  let flags = int(u32At(data, 4))
  if (flags and 0xFF) != 2: bad("version " & $(flags and 0xFF) & " not read")
  let multi = (flags and 0x1000) != 0
  if (flags and 0x800) != 0 and not multi: bad("deep pictures are not read")
  var at = 8
  # (read into a local first: `h` is shared with the decoding below, and
  # what a damaged header had read is freed only from a local)
  let first = readHeader(data, at)
  var h = first
  var otherTables = 0
  if multi:
    # (headers to an empty one: the first part read; the other parts' offset tables after its own)
    while at < data.len and data[at] != '\0':
      let o = readHeader(data, at)
      otherTables += max(0, o.chunkCount)
    inc at
  if h.kind.startsWith("deep"): bad("deep pictures are not read")
  h.tiled = h.kind == "tiledimage" or (not multi and (flags and 0x200) != 0)
  if h.tiled and (h.tileW < 1 or h.tileH < 1 or h.tileW > 65536 or h.tileH > 65536): bad("bad tile size")
  if h.compression notin cNone .. cB44a:
    if h.compression < compressionNames.len: bad(compressionNames[h.compression] & " compression is not read")
    bad("compression " & $h.compression & " not read")
  if h.tiled:
    for c in h.chans:
      if c.xs != 1 or c.ys != 1: bad("subsampled channels in tiles")
  let dw = h.dx1 - h.dx0 + 1
  let dh = h.dy1 - h.dy0 + 1
  let vw = h.vx1 - h.vx0 + 1
  let vh = h.vy1 - h.vy0 + 1
  if vw < 1 or vh < 1 or vw > MaxSide or vh > MaxSide or vw * vh > MaxPixels: bad("bad display window")
  if dw > MaxSide * 2 or dh > MaxSide * 2 or (dw > 0 and dh > 0 and dw * dh > MaxPixels): bad("data window too big")
  for c in h.chans:
    if c.xs > 1 or c.ys > 1:
      if modp(h.dx0, c.xs) != 0 or modp(h.dy0, c.ys) != 0: bad("data window not on the sampling")
  # which channels are read: plain R G B A (Y, RY, BY), else a layer's
  for c in h.chans: result.channels.add c.name
  var prefix = ""
  var plain = false
  for c in h.chans:
    if c.name in ["R", "G", "B", "Y"]: plain = true
  if not plain:
    for c in h.chans:
      let d = c.name.rfind('.')
      if d > 0 and c.name[d + 1 .. ^1] in ["R", "G", "B", "Y"]:
        prefix = c.name[0 .. d]
        break
  var tg = newSeq[Target](h.chans.len)
  var hasRgb, hasA, hasY = false
  for i, c in h.chans:
    tg[i] = Target(slot: -1, plane: -1)
    if not c.name.startsWith(prefix): continue
    case c.name[prefix.len .. ^1]
    of "R": tg[i].slot = 0
    of "G": tg[i].slot = 1
    of "B": tg[i].slot = 2
    of "A": tg[i].slot = 3
    of "Y": tg[i].slot = 4
    of "RY": tg[i].slot = 5
    of "BY": tg[i].slot = 6
    else: discard
    if tg[i].slot in 0 .. 2: hasRgb = true
    if tg[i].slot == 3: hasA = true
    if tg[i].slot == 4: hasY = true
  for t in tg.mitems:
    if hasRgb and t.slot >= 4: t.slot = -1
    if not hasY and t.slot >= 5: t.slot = -1
  var planes: seq[seq[float32]]
  var o = Out(w: vw, h: vh, vx0: h.vx0, vy0: h.vy0)
  for i, c in h.chans:
    if tg[i].slot >= 0 and (c.xs != 1 or c.ys != 1 or tg[i].slot >= 5):
      tg[i].plane = planes.len
      let pw = max(0, numSamples(c.xs, h.dx0, h.dx1))
      let ph = max(0, numSamples(c.ys, h.dy0, h.dy1))
      planes.add newSeq[float32](max(1, pw * ph))
      o.pw.add pw
      o.ph.add ph
      o.px0.add divp(h.dx0 + c.xs - 1, c.xs)
      o.py0.add divp(h.dy0 + c.ys - 1, c.ys)
  result.w = vw
  result.h = vh
  result.px = newSeq[float32](vw * vh * 4)
  o.px = cast[ptr UncheckedArray[float32]](addr result.px[0])
  if planes.len > 0: o.planes = cast[ptr UncheckedArray[seq[float32]]](addr planes[0])
  # (the data window on the display window)
  let ax = max(h.dx0, h.vx0)
  let bx = min(h.dx1, h.vx1)
  let ay = max(h.dy0, h.vy0)
  let by = min(h.dy1, h.vy1)
  if not hasA:
    for y in ay .. by:
      for x in ax .. bx: result.px[((y - h.vy0) * vw + x - h.vx0) * 4 + 3] = 1
  if dw <= 0 or dh <= 0: return
  # the chunks: where each starts
  let lpb = if h.tiled: h.tileH else: linesOf[h.compression]
  var want, total: int
  if h.tiled:
    let tc = tileCount(h)
    want = tc.level0
    total = tc.all
  else:
    want = (dh + lpb - 1) div lpb
    total = want
  if multi and h.chunkCount > 0: total = h.chunkCount
  if total > data.len div 8: bad("damaged offsets")
  let tableAt = at
  let dataStart = tableAt + 8 * (total + otherTables)
  if dataStart > data.len: bad("cut short")
  var offs = newSeq[int](want)
  var broken = false
  for i in 0 ..< want:
    let v = u64At(data, tableAt + 8 * i)
    if v < uint64(dataStart) or v >= uint64(data.len): broken = true
    offs[i] = int(min(v, uint64(high(int32))))
  let partHead = if multi: 4 else: 0
  let coordHead = if h.tiled: 16 else: 4
  if broken:
    # (an offset table not written to the end: the chunks found one after another)
    offs.setLen(0)
    var p = dataStart
    while p + partHead + coordHead + 4 <= data.len:
      let size = i32At(data, p + partHead + coordHead)
      let next = p + partHead + coordHead + 4 + size
      if size < 0 or next > data.len: break
      if (not multi or i32At(data, p) == 0) and
         (not h.tiled or (i32At(data, p + partHead + 8) == 0 and i32At(data, p + partHead + 12) == 0)):
        offs.add p
      p = next
  # each chunk: unpacked and put in place, on all the cores
  var errs = newSeq[string](offs.len)
  let dp = unsafeAddr data                 # (not copied into the closure)
  parallelFor(offs.len, proc (lo, hi: int) =
    for k in lo ..< hi:
      try: readChunk(dp[], h, tg, o, multi, lpb, offs[k])
      except CatchableError, IndexDefect, RangeDefect, OverflowDefect:
        errs[k] = getCurrentExceptionMsg()
  )
  for e in errs:
    if e.len > 0: raise newException(ValueError, (if e.startsWith("EXR"): e else: "EXR: " & e))
  # subsampled channels and colors from luminance and chroma
  if planes.len > 0:
    var ryp, byp = -1
    for i, c in h.chans:
      let t = tg[i]
      if t.plane < 0: continue
      if t.slot == 5: ryp = t.plane
      elif t.slot == 6: byp = t.plane
      else:
        let pl = t.plane
        for y in ay .. by:
          let row = clamp(divp(y, c.ys) - o.py0[pl], 0, o.ph[pl] - 1)
          for x in ax .. bx:
            let v = planes[pl][row * o.pw[pl] + clamp(divp(x, c.xs) - o.px0[pl], 0, o.pw[pl] - 1)]
            let q = ((y - h.vy0) * vw + x - h.vx0) * 4
            if t.slot == 4:
              for s in 0 .. 2: result.px[q + s] = v
            else: result.px[q + t.slot] = v
    if ryp >= 0 or byp >= 0:
      var xsOf, ysOf: array[2, int]
      for i, c in h.chans:
        if tg[i].slot == 5: (xsOf[0], ysOf[0]) = (c.xs, c.ys)
        if tg[i].slot == 6: (xsOf[1], ysOf[1]) = (c.xs, c.ys)
      for y in ay .. by:
        for x in ax .. bx:
          let q = ((y - h.vy0) * vw + x - h.vx0) * 4
          let lum = result.px[q]
          var ch: array[2, float32]
          for k, pl in [ryp, byp]:
            if pl < 0: continue
            let row = clamp(divp(y, ysOf[k]) - o.py0[pl], 0, o.ph[pl] - 1)
            ch[k] = planes[pl][row * o.pw[pl] + clamp(divp(x, xsOf[k]) - o.px0[pl], 0, o.pw[pl] - 1)]
          let r = (ch[0] + 1) * lum
          let b = (ch[1] + 1) * lum
          result.px[q] = r
          result.px[q + 1] = (lum - r * 0.2126'f32 - b * 0.0722'f32) / 0.7152'f32
          result.px[q + 2] = b

proc readExr*(data: string): tuple[w, h: int; px: seq[float32]; channels: seq[string]] =
  ## An OpenEXR file as light: the display window's size, 4 floats a pixel
  ## (R G B A, linear; alpha 1 when the file has none, 0 outside the data
  ## window), and the names of every channel in the file. Raises
  ## `ValueError` when it is not an OpenEXR file, is damaged, or is
  ## compressed in a way not read (DWAA, DWAB, HTJ2K) or deep.
  try: readExrFile(data)
  except IndexDefect, RangeDefect, OverflowDefect:
    raise newException(ValueError, "EXR: damaged (" & getCurrentExceptionMsg() & ")")

# ---- writing --------------------------------------------------------------------------------------------------

const ZipLevel = 2               # (deflate at level 2: files about as small as at 4, made quicker)

proc writeExr*(w, h: int; px: openArray[float32]; half = true; compression = "zip"): string =
  ## Light (4 floats a pixel: R G B A) as an OpenEXR file: scanlines, half
  ## floats (`half` false: 32-bit floats), compressed with "none", "rle",
  ## "zips", "zip" or "piz". A is left out when every alpha is 1. Raises
  ## `ValueError` for another compression or too few pixels.
  if w < 1 or h < 1 or w > MaxSide or h > MaxSide: bad("bad size")
  if px.len < w * h * 4: bad("too few pixels")
  let comp = case compression.toLowerAscii
             of "none", "": cNone
             of "rle": cRle
             of "zips": cZips
             of "zip": cZip
             of "piz": cPiz
             else: bad("compression \"" & compression & "\" is not written")
  var alpha = false
  for i in 0 ..< w * h:
    if px[4 * i + 3] != 1:
      alpha = true
      break
  let kind = if half: 1 else: 2
  let sz = typeSize(kind)
  let slots = if alpha: @[3, 2, 1, 0] else: @[2, 1, 0]       # A B G R: in the order of their names
  var hd = Header(compression: comp, dx1: w - 1, dy1: h - 1, vx1: w - 1, vy1: h - 1)
  for s in slots: hd.chans.add Chan(name: $"RGBA"[s], kind: kind, xs: 1, ys: 1)
  # the header
  var o = "\x76\x2F\x31\x01\x02\x00\x00\x00"
  proc i32(o: var string; v: int) =
    for k in 0 .. 3: o.add char((v shr (8 * k)) and 255)
  proc attr(o: var string; name, kind: string; value: string) =
    o.add name; o.add '\0'; o.add kind; o.add '\0'
    o.i32(value.len)
    o.add value
  var cl = ""
  for c in hd.chans:
    cl.add c.name; cl.add '\0'
    cl.i32(kind); cl.add "\0\0\0\0"; cl.i32(1); cl.i32(1)
  cl.add '\0'
  var box = ""
  for v in [0, 0, w - 1, h - 1]: box.i32(v)
  o.attr("channels", "chlist", cl)
  o.attr("compression", "compression", $char(comp))
  o.attr("dataWindow", "box2i", box)
  o.attr("displayWindow", "box2i", box)
  o.attr("lineOrder", "lineOrder", "\0")
  o.attr("pixelAspectRatio", "float", "\x00\x00\x80\x3F")
  o.attr("screenWindowCenter", "v2f", "\0\0\0\0\0\0\0\0")
  o.attr("screenWindowWidth", "float", "\x00\x00\x80\x3F")
  o.add '\0'
  # the blocks, made on all the cores
  let lpb = linesOf[comp]
  let n = (h + lpb - 1) div lpb
  var blocks = newSeq[seq[byte]](n)
  let src = cast[ptr UncheckedArray[float32]](unsafeAddr px[0])
  let bp = cast[ptr UncheckedArray[seq[byte]]](addr blocks[0])
  parallelFor(n, proc (lo, hi: int) =
    for k in lo ..< hi:
      let y0 = k * lpb
      let y1 = min(h - 1, y0 + lpb - 1)
      var raw = newSeqUninit[byte]((y1 - y0 + 1) * w * slots.len * sz)
      var q = 0
      for y in y0 .. y1:
        for s in slots:
          if half:
            for x in 0 ..< w:
              let v = floatToHalf(src[(y * w + x) * 4 + s])
              raw[q] = byte(v and 255)
              raw[q + 1] = byte(v shr 8)
              q += 2
          else:
            for x in 0 ..< w:
              let v = cast[uint32](src[(y * w + x) * 4 + s])
              for b in 0 .. 3: raw[q + b] = byte((v shr (8 * b)) and 255)
              q += 4
      var packed = case comp
                   of cRle: rlePack(raw)
                   of cZips, cZip: zlibCompressLevel(predict(raw), ZipLevel)
                   of cPiz: hd.pizPack(raw, 0, w - 1, y0, y1)
                   else: raw
      if packed.len >= raw.len: packed = move raw                      # (no smaller: kept as it is)
      bp[k] = move packed
  )
  var total = o.len + 8 * n
  for b in blocks: total += 8 + b.len
  var at = o.len + 8 * n
  result = newStringOfCap(total)
  result.add o
  for k in 0 ..< n:
    for b in 0 .. 7: result.add char((uint64(at) shr (8 * b)) and 255)   # (64 bits where int has 32)
    at += 8 + blocks[k].len
  for k in 0 ..< n:
    result.i32(k * lpb)
    result.i32(blocks[k].len)
    if blocks[k].len > 0:
      let p = result.len
      result.setLen(p + blocks[k].len)
      copyMem(addr result[p], addr blocks[k][0], blocks[k].len)
