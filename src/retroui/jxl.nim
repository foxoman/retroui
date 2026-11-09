## JPEG XL pictures in plain Nim, read and written.
##
## Read: the codestream and the ISO BMFF container (``jxlc`` or ``jxlp``
## boxes, other boxes passed over); VarDCT (what cjxl writes by default:
## every transform from 2x2 to 256x256, the quantization matrices however
## coded, chroma from luma, adaptive LF smoothing, progressive passes, LF
## frames), modular (the MA tree with every predictor and the weighted one,
## RCT, palette and delta palette, squeeze), JPEG recompressed files (YCbCr
## and chroma subsampling: the pixels, not the JPEG file), the restoration
## filters (Gaborish and the edge preserving filter), patches, splines,
## noise, upsampling, extra channels and alpha (premultiplied or not),
## animations (each frame blended over the reference it names, cropped,
## shown as the canvas looks) and the image orientation. XYB pictures come
## out as sRGB; other pictures as their samples are (sRGB in practice).
##
## Written: lossless (modular: a reversible color transform chosen per
## image, a palette when there are few colors, the MA tree learned from the
## picture with the weighted predictor when the effort allows, prefix codes
## or ANS) and lossy, at a quality as cjxl's -q takes it (modular too, as
## cjxl -m 1 writes it: the picture in XYB, squeezed into averages and
## differences level by level, the differences quantized the more the finer
## they are and the lower the quality -- each against what the decoder will
## have by then -- through the MA tree's multipliers; alpha kept exactly).
## Every file it writes decodes to the same pixels in libjxl (a lossy one
## within a level: float arithmetic done in another order).
##
## Pixels are `Bitmap`s: 0xAARRGGBB, straight (not premultiplied) alpha.
## Damaged or unsupported files raise `JxlError`.
##
## .. code-block:: nim
##   let pic = decodeJxl(readFile("photo.jxl"))
##   writeFile("exact.jxl", encodeJxlLossless(pic))
##   writeFile("small.jxl", encodeJxl(pic, quality = 85))
##   for (frame, ms) in decodeJxlFrames(readFile("anim.jxl")):
##     echo frame.w, "x", frame.h, " for ", ms, " ms"
##
## The decoder follows ISO/IEC 18181-1 as libjxl reads it; it was written
## with libjxl (BSD-3-Clause), jxl-oxide (MIT) and J40 (public domain) at
## hand -- see vendor/LICENSE-jxl-references.txt.

import std/[math, algorithm, bitops]
import gfx

{.localPassC: "-fno-math-errno".}   # sqrt as one instruction, loops with it vectorized

type
  JxlError* = object of CatchableError
    ## A file that is not JPEG XL, or is damaged, or uses what this module
    ## does not read.

proc fail(msg: string) {.noreturn.} = raise newException(JxlError, msg)

{.push overflowChecks: off, rangeChecks: off.}

type FBuf = ptr UncheckedArray[float32]

proc cdiv(a, b: int): int {.inline.} = (a + b - 1) div b

proc cut[T](s: var seq[T]; a, b: int) =
  ## Removes s[a ..< b].
  if b <= a: return
  let n = b - a
  for i in a ..< s.len - n: s[i] = move s[i + n]
  s.setLen(s.len - n)
proc ceilLog2(x: int): int =
  ## The bits that count 0 ..< x (0 for x <= 1).
  var n = 0
  while (1 shl n) < x: inc n
  n
proc floorLog2(x: uint64): int {.inline.} =
  if x == 0: -1 else: 63 - countLeadingZeroBits(x)
proc addLog2Ceil(x: int): int =
  ## The bits that hold x itself: ceil(log2(x + 1)).
  ceilLog2(x + 1)

# ---- bits -------------------------------------------------------------------------------------

type
  Bits = object
    ## Bits read from the lowest of each byte up.
    data: ptr UncheckedArray[byte]
    len: int             # bytes there are
    pos: int             # the next byte to take
    buf: uint64
    nb: int              # bits in `buf`
    base: int            # where `data` is in the string

proc initBits(s: string; a = 0; b = -1): Bits =
  let e = if b < 0: s.len else: min(b, s.len)
  result.base = a
  if e > a:
    result.data = cast[ptr UncheckedArray[byte]](unsafeAddr s[a])
    result.len = e - a

proc refill(r: var Bits) =
  when cpuEndian == littleEndian:
    if r.pos + 8 <= r.len:
      var v: uint64
      copyMem(addr v, addr r.data[r.pos], 8)
      r.buf = r.buf or (v shl r.nb)
      let k = (63 - r.nb) shr 3
      r.pos += k
      r.nb += k * 8
      return
  while r.nb <= 56:
    if r.pos < r.len:
      r.buf = r.buf or (uint64(r.data[r.pos]) shl r.nb)
    elif r.pos > r.len + 64:
      fail("the JPEG XL file is cut short")
    inc r.pos
    r.nb += 8

proc bits(r: var Bits; n: int): int {.inline.} =
  ## n <= 32 bits as a number.
  if r.nb < n: r.refill()
  result = int(r.buf and ((1'u64 shl n) - 1))
  r.buf = r.buf shr n
  r.nb -= n

proc peek(r: var Bits; n: int): int {.inline.} =
  if r.nb < n: r.refill()
  int(r.buf and ((1'u64 shl n) - 1))

proc drop(r: var Bits; n: int) {.inline.} =
  r.buf = r.buf shr n
  r.nb -= n

proc flag(r: var Bits): bool {.inline.} = r.bits(1) == 1

proc bitPos(r: Bits): int = r.pos * 8 - r.nb
proc overrun(r: Bits): bool = r.bitPos > r.len * 8

proc skipBits(r: var Bits; n: int) =
  var n = n
  while n > 32:
    discard r.bits(32)
    n -= 32
  discard r.bits(n)

proc zeroPad(r: var Bits) = r.drop(r.nb and 7)

type Dist = tuple[off, n: int]       ## offset + n bits, of a U32 field

proc u32(r: var Bits; d0, d1, d2, d3: Dist): int =
  let d = [d0, d1, d2, d3][r.bits(2)]
  d.off + r.bits(d.n)

proc u64(r: var Bits): uint64 =
  case r.bits(2)
  of 0: 0'u64
  of 1: 1'u64 + uint64(r.bits(4))
  of 2: 17'u64 + uint64(r.bits(8))
  else:
    var v = uint64(r.bits(12))
    var shift = 12
    while r.flag:
      if shift == 60:
        v = v or (uint64(r.bits(4)) shl 60)
        break
      v = v or (uint64(r.bits(8)) shl shift)
      shift += 8
    v

proc f16(r: var Bits): float32 =
  let b = r.bits(16)
  let sign = b shr 15
  let e = (b shr 10) and 31
  let m = b and 1023
  if e == 31: fail("damaged JPEG XL (a number that is not finite)")
  let v = if e == 0: float32(m) * pow(2.0'f32, -24) else: float32(m + 1024) * pow(2.0'f32, float32(e - 25))
  if sign == 1: -v else: v

proc readEnum(r: var Bits): int = r.u32((0, 0), (1, 0), (2, 4), (18, 6))

proc unpackSigned(v: uint32): int32 {.inline.} =
  cast[int32]((v shr 1) xor (((not v) and 1) - 1))

proc readExtensions(r: var Bits) =
  let ext = r.u64()
  var total = 0'u64
  for i in 0 ..< 64:
    if ((ext shr i) and 1) != 0: total += r.u64()
  if total > 1'u64 shl 32: fail("damaged JPEG XL (extensions)")
  r.skipBits(int(total))

# ---- entropy coding ---------------------------------------------------------------------------

type
  HConf = object
    ## How a token and raw bits make an integer.
    splitExp, split, msb, lsb: int
  AnsEntry = object
    cutoff, rightSym, rightOff, dist, rightDist: int32
  Histo = object
    ## One distribution (a cluster of contexts): ANS alias table or prefix code.
    logBucket: int
    ans: seq[AnsEntry]
    table: seq[uint32]       # prefix: sym shl 16 or len; second level: offset shl 16 or (16 + bits)
    rootBits: int
    single: int              # the only symbol it gives, or -1
  Code = object
    ## The distributions of an entropy coded stream, and its contexts.
    lz77: bool
    lzMinSym, lzMinLen: int
    lzConf: HConf
    clusters: seq[uint8]
    confs: seq[HConf]
    histos: seq[Histo]
    prefix: bool
  Reader = object
    ## The state of one entropy coded stream.
    state: uint32
    win: seq[uint32]
    numToCopy, copyPos, numDecoded: int
    distMult: int

proc readHConf(r: var Bits; logAlpha: int): HConf =
  result.splitExp = r.bits(addLog2Ceil(logAlpha))
  if result.splitExp > logAlpha: fail("damaged JPEG XL (integer coding)")
  if result.splitExp != logAlpha:
    result.msb = r.bits(addLog2Ceil(result.splitExp))
    if result.msb > result.splitExp: fail("damaged JPEG XL (integer coding)")
    result.lsb = r.bits(addLog2Ceil(result.splitExp - result.msb))
  if result.msb + result.lsb > result.splitExp: fail("damaged JPEG XL (integer coding)")
  result.split = 1 shl result.splitExp

proc readU8(r: var Bits): int =
  if r.flag:
    let n = r.bits(3)
    (1 shl n) + r.bits(n)
  else: 0

proc readLogCount(r: var Bits): int =
  case r.bits(3)
  of 0: 10
  of 1:
    for v in [4, 0, 11, 13]:
      if r.flag: return v
    12
  of 2: 7
  of 3: (if r.flag: 1 else: 3)
  of 4: 6
  of 5: 8
  of 6: 9
  else: (if r.flag: 2 else: 5)

proc buildAlias(d: var Histo; dist: openArray[int]; logAlpha: int) =
  ## The alias table libjxl builds (the pairing must be the same as the encoder's).
  let tableSize = 1 shl logAlpha
  d.logBucket = 12 - logAlpha
  let bucket = 1 shl d.logBucket
  d.ans = newSeq[AnsEntry](tableSize)
  d.single = -1
  for i, v in dist:
    if v == 4096: d.single = i
  if d.single >= 0:
    for i in 0 ..< tableSize:
      d.ans[i] = AnsEntry(cutoff: 0, rightSym: int32(d.single), rightOff: int32(bucket * i),
                          dist: 4096, rightDist: 4096)
    return
  var cutoff = newSeq[int](tableSize)
  var under, over: seq[int]
  for i in 0 ..< tableSize:
    cutoff[i] = if i < dist.len: dist[i] else: 0
    if cutoff[i] > bucket: over.add i
    elif cutoff[i] < bucket: under.add i
  var rightSym = newSeq[int](tableSize)
  var rightOff = newSeq[int](tableSize)
  for i in 0 ..< tableSize: rightSym[i] = i
  while over.len > 0:
    let o = over.pop()
    if under.len == 0: fail("damaged JPEG XL (distribution)")
    let u = under.pop()
    let by = bucket - cutoff[u]
    cutoff[o] -= by
    rightSym[u] = o
    rightOff[u] = cutoff[o]
    if cutoff[o] < bucket: under.add o
    elif cutoff[o] > bucket: over.add o
  for i in 0 ..< tableSize:
    let own = if i < dist.len: dist[i] else: 0
    if cutoff[i] == bucket:
      d.ans[i] = AnsEntry(cutoff: int32(bucket), rightSym: int32(i), dist: int32(own),
                          rightDist: int32(own))
    else:
      let rs = rightSym[i]
      d.ans[i] = AnsEntry(cutoff: int32(cutoff[i]), rightSym: int32(rs),
                          rightOff: int32(rightOff[i] - cutoff[i]), dist: int32(own),
                          rightDist: int32(if rs < dist.len: dist[rs] else: 0))

proc readAnsHisto(r: var Bits; logAlpha: int): Histo =
  let tableSize = 1 shl logAlpha
  var dist = newSeq[int](tableSize)
  if r.flag:
    if r.flag:
      let v0 = r.readU8()
      let v1 = r.readU8()
      if v0 == v1 or max(v0, v1) >= tableSize: fail("damaged JPEG XL (distribution)")
      let p = r.bits(12)
      dist[v0] = p
      dist[v1] = 4096 - p
    else:
      let v = r.readU8()
      if v >= tableSize: fail("damaged JPEG XL (distribution)")
      dist[v] = 4096
  elif r.flag:
    let alphabet = r.readU8() + 1
    if alphabet > tableSize: fail("damaged JPEG XL (distribution)")
    let base = 4096 div alphabet
    let left = 4096 mod alphabet
    for i in 0 ..< alphabet: dist[i] = base + (if i < left: 1 else: 0)
  else:
    var len = 0
    while len < 3:
      if r.flag: inc len
      else: break
    let shift = r.bits(len) + (1 shl len) - 1
    if shift > 13: fail("damaged JPEG XL (distribution)")
    let alphabet = r.readU8() + 3
    if alphabet > tableSize: fail("damaged JPEG XL (distribution)")
    var repeat = newSeq[bool](tableSize)
    var omitLog = -1
    var omitPos = -1
    var i = 0
    while i < alphabet:
      dist[i] = r.readLogCount()
      if dist[i] == 13:
        let n = r.readU8() + 4
        if i + n > alphabet: fail("damaged JPEG XL (distribution)")
        for k in i ..< i + n: repeat[k] = true
        i += n
        continue
      if dist[i] > omitLog:
        omitLog = dist[i]
        omitPos = i
      inc i
    if omitPos < 0 or (omitPos + 1 < alphabet and repeat[omitPos + 1] and not repeat[omitPos]):
      fail("damaged JPEG XL (distribution)")
    var total = 0
    var prev = 0
    for i in 0 ..< tableSize:
      if repeat[i]:
        dist[i] = prev
        total += prev
        if total > 4096: fail("damaged JPEG XL (distribution)")
        continue
      let code = dist[i]
      if code == 0 or i == omitPos:
        prev = 0
        continue
      var v = 1
      if code > 1:
        let zeros = code - 1
        let bitcount = clamp(shift - ((12 - zeros) shr 1), 0, zeros)
        v = (1 shl zeros) + (r.bits(bitcount) shl (zeros - bitcount))
      dist[i] = v
      prev = v
      total += v
      if total > 4096: fail("damaged JPEG XL (distribution)")
    dist[omitPos] = 4096 - total
  result.buildAlias(dist, logAlpha)

proc buildPrefix(d: var Histo; lengths: openArray[int]) =
  ## A canonical prefix code read from the lowest bit up: a root table of up
  ## to 10 bits, second tables for longer codes.
  var count: array[16, int]
  var maxLen = 0
  var nsym = 0
  var last = 0
  for s, l in lengths:
    if l > 0:
      inc count[l]
      maxLen = max(maxLen, l)
      inc nsym
      last = s
  d.single = -1
  if nsym == 0: fail("damaged JPEG XL (prefix code)")
  if nsym == 1:
    d.single = last
    d.rootBits = 0
    d.table = @[uint32(last) shl 16]
    return
  var kraft = 0
  for l in 1 .. 15: kraft += count[l] shl (15 - l)
  if kraft != 1 shl 15: fail("damaged JPEG XL (prefix code)")
  var next: array[17, int]
  var code = 0
  for l in 1 .. 15:
    next[l] = code
    code = (code + count[l]) shl 1
  let root = min(maxLen, 10)
  d.rootBits = root
  d.table = newSeq[uint32](1 shl root)
  var codes = newSeq[int](lengths.len)
  for s, l in lengths:
    if l > 0:
      var c = next[l]
      inc next[l]
      var rev = 0
      for i in 0 ..< l:
        rev = (rev shl 1) or ((c shr i) and 1)
      codes[s] = rev
  # short codes in the root
  for s, l in lengths:
    if l > 0 and l <= root:
      var k = codes[s]
      while k < (1 shl root):
        d.table[k] = (uint32(s) shl 16) or uint32(l)
        k += 1 shl l
  if maxLen > root:
    var subBits = newSeq[int](1 shl root)
    for s, l in lengths:
      if l > root:
        let k = codes[s] and ((1 shl root) - 1)
        subBits[k] = max(subBits[k], l - root)
    for k in 0 ..< (1 shl root):
      if subBits[k] > 0:
        let at = d.table.len
        d.table.setLen(at + (1 shl subBits[k]))
        d.table[k] = (uint32(at) shl 16) or uint32(16 + subBits[k])
    for s, l in lengths:
      if l > root:
        let k = codes[s] and ((1 shl root) - 1)
        let e = d.table[k]
        let at = int(e shr 16)
        let sb = int(e and 0xFF) - 16
        var j = codes[s] shr root
        while j < (1 shl sb):
          d.table[at + j] = (uint32(s) shl 16) or uint32(l)
          j += 1 shl (l - root)

proc readPrefixHisto(r: var Bits; alphabet: int): Histo =
  if alphabet == 1:
    result.single = 0
    result.table = @[0'u32]
    return
  var lengths = newSeq[int](alphabet)
  let hskip = r.bits(2)
  if hskip == 1:
    let abits = ceilLog2(alphabet)
    let nsym = r.bits(2) + 1
    var syms: array[4, int]
    for i in 0 ..< nsym:
      syms[i] = r.bits(abits)
      if syms[i] >= alphabet: fail("damaged JPEG XL (prefix code)")
    case nsym
    of 1:
      lengths[syms[0]] = 1
      result.single = syms[0]
      result.table = @[uint32(syms[0]) shl 16]
      return
    of 2:
      lengths[syms[0]] = 1
      lengths[syms[1]] = 1
    of 3:
      lengths[syms[0]] = 1
      lengths[syms[1]] = 2
      lengths[syms[2]] = 2
    else:
      if r.flag:
        lengths[syms[0]] = 1
        lengths[syms[1]] = 2
        lengths[syms[2]] = 3
        lengths[syms[3]] = 3
      else:
        for i in 0 .. 3: lengths[syms[i]] = 2
    for i in 0 ..< nsym:
      for j in 0 ..< i:
        if syms[i] == syms[j]: fail("damaged JPEG XL (prefix code)")
    result.buildPrefix(lengths)
    return
  const order = [1, 2, 3, 4, 0, 5, 17, 6, 16, 7, 8, 9, 10, 11, 12, 13, 14, 15]
  var clLens: array[18, int]
  var acc = 0
  var nonzero = 0
  var nzSym = 0
  for i in hskip ..< 18:
    let idx = order[i]
    var l = [0, 4, 3, 8][r.bits(2)]
    if l == 8:
      l = if r.flag: (if r.flag: 5 else: 1) else: 2
    clLens[idx] = l
    if l != 0:
      inc nonzero
      nzSym = idx
      acc += 32 shr l
      if acc == 32: break
      if acc > 32: fail("damaged JPEG XL (prefix code)")
  var cl: Histo
  if nonzero == 1:
    cl.single = nzSym
    cl.table = @[uint32(nzSym) shl 16]
  elif acc != 32: fail("damaged JPEG XL (prefix code)")
  else: cl.buildPrefix(clLens)
  var space = 0
  var prevSym = 8
  var lastNonzero = 8
  var lastRepeat = 0
  var repeat = 0
  var repeatSym = 0
  var i = 0
  while i < alphabet:
    if repeat > 0:
      lengths[i] = repeatSym
      dec repeat
    else:
      var sym: int
      if cl.rootBits == 0: sym = cl.single
      else:
        let v = r.peek(15)
        var e = cl.table[v and ((1 shl cl.rootBits) - 1)]
        r.drop(int(e and 0xFF))
        sym = int(e shr 16)
      if sym < 16:
        if sym != 0:
          lengths[i] = sym
          lastNonzero = sym
      elif sym == 16:
        repeat = r.bits(2) + 3
        if prevSym == 16:
          repeat += lastRepeat * 3 - 8
          lastRepeat += repeat
        else: lastRepeat = repeat
        repeatSym = lastNonzero
        lengths[i] = repeatSym
        dec repeat
      else:
        repeat = r.bits(3) + 3
        if prevSym == 17:
          repeat += lastRepeat * 7 - 16
          lastRepeat += repeat
        else: lastRepeat = repeat
        repeatSym = 0
        lengths[i] = 0
        dec repeat
      prevSym = sym
    if lengths[i] != 0:
      space += 1 shl (15 - lengths[i])
      if space > 1 shl 15: fail("damaged JPEG XL (prefix code)")
      if space == 1 shl 15 and repeat == 0:
        break
    inc i
  if space != 1 shl 15 or repeat > 0: fail("damaged JPEG XL (prefix code)")
  result.buildPrefix(lengths)


proc readToken(c: Code; rd: var Reader; r: var Bits; cluster: int): int {.inline.} =
  let h = unsafeAddr c.histos[cluster]
  if c.prefix:
    if h.rootBits == 0: return h.single
    let v = r.peek(15)
    var e = h.table[v and ((1 shl h.rootBits) - 1)]
    var n = int(e and 0xFF)
    if n > 15:
      e = h.table[int(e shr 16) + ((v shr h.rootBits) and ((1 shl (n - 16)) - 1))]
      n = int(e and 0xFF)
    r.drop(n)
    return int(e shr 16)
  else:
    let idx = int(rd.state and 0xFFF)
    let i = idx shr h.logBucket
    let pos = int32(idx and ((1 shl h.logBucket) - 1))
    let e = unsafeAddr h.ans[i]
    var off, dist: uint32
    if pos < e.cutoff:
      result = i
      off = uint32(pos)
      dist = uint32(e.dist)
    else:
      result = int(e.rightSym)
      off = uint32(e.rightOff + pos)
      dist = uint32(e.rightDist)
    rd.state = dist * (rd.state shr 12) + off
    if rd.state < 65536'u32:
      rd.state = (rd.state shl 16) or uint32(r.bits(16))

proc readUint(r: var Bits; c: HConf; token: int): uint32 {.inline.} =
  if token < c.split: return uint32(token)
  let n = c.splitExp - (c.msb + c.lsb) + ((token - c.split) shr (c.msb + c.lsb))
  if n > 31: fail("damaged JPEG XL (integer too large)")
  let low = token and ((1 shl c.lsb) - 1)
  let t = ((token shr c.lsb) and ((1 shl c.msb) - 1)) or (1 shl c.msb)
  let rest = r.bits(n)
  uint32((((uint64(t) shl n) or uint64(rest)) shl c.lsb) or uint64(low))

const SpecialDistances = [
  (0, 1), (1, 0), (1, 1), (-1, 1), (0, 2), (2, 0), (1, 2), (-1, 2), (2, 1), (-2, 1),
  (2, 2), (-2, 2), (0, 3), (3, 0), (1, 3), (-1, 3), (3, 1), (-3, 1), (2, 3), (-2, 3),
  (3, 2), (-3, 2), (0, 4), (4, 0), (1, 4), (-1, 4), (4, 1), (-4, 1), (3, 3), (-3, 3),
  (2, 4), (-2, 4), (4, 2), (-4, 2), (0, 5), (3, 4), (-3, 4), (4, 3), (-4, 3), (5, 0),
  (1, 5), (-1, 5), (5, 1), (-5, 1), (2, 5), (-2, 5), (5, 2), (-5, 2), (4, 4), (-4, 4),
  (3, 5), (-3, 5), (5, 3), (-5, 3), (0, 6), (6, 0), (1, 6), (-1, 6), (6, 1), (-6, 1),
  (2, 6), (-2, 6), (6, 2), (-6, 2), (4, 5), (-4, 5), (5, 4), (-5, 4), (3, 6), (-3, 6),
  (6, 3), (-6, 3), (0, 7), (7, 0), (1, 7), (-1, 7), (5, 5), (-5, 5), (7, 1), (-7, 1),
  (4, 6), (-4, 6), (6, 4), (-6, 4), (2, 7), (-2, 7), (7, 2), (-7, 2), (3, 7), (-3, 7),
  (7, 3), (-7, 3), (5, 6), (-5, 6), (6, 5), (-6, 5), (8, 0), (4, 7), (-4, 7), (7, 4),
  (-7, 4), (8, 1), (8, 2), (6, 6), (-6, 6), (8, 3), (5, 7), (-5, 7), (7, 5), (-7, 5),
  (8, 4), (6, 7), (-6, 7), (7, 6), (-7, 6), (8, 5), (7, 7), (-7, 7), (8, 6), (8, 7)]

proc readHybrid(c: Code; rd: var Reader; r: var Bits; ctx: int): uint32 =
  ## The next integer in context `ctx` (with LZ77 copies, when the stream has them).
  let cl = int(c.clusters[ctx])
  if not c.lz77:
    return r.readUint(c.confs[cl], c.readToken(rd, r, cl))
  if rd.numToCopy > 0:
    result = rd.win[rd.copyPos and 0xFFFFF]
    inc rd.copyPos
    dec rd.numToCopy
  else:
    let tok = c.readToken(rd, r, cl)
    if tok >= c.lzMinSym:
      if rd.numDecoded == 0: fail("damaged JPEG XL (LZ77)")
      rd.numToCopy = int(r.readUint(c.lzConf, tok - c.lzMinSym)) + c.lzMinLen
      let dc = int(c.clusters[^1])
      var distance = int(r.readUint(c.confs[dc], c.readToken(rd, r, dc)))
      if rd.distMult != 0:
        if distance < 120:
          let (dx, dy) = SpecialDistances[distance]
          distance = max(dx + rd.distMult * dy - 1, 0)
        else: distance -= 120
      distance = min(min(distance, (1 shl 20) - 1) + 1, rd.numDecoded)
      rd.copyPos = rd.numDecoded - distance
      result = rd.win[rd.copyPos and 0xFFFFF]
      inc rd.copyPos
      dec rd.numToCopy
    else:
      result = r.readUint(c.confs[cl], tok)
  let at = rd.numDecoded and 0xFFFFF
  if at >= rd.win.len: rd.win.add result
  else: rd.win[at] = result
  inc rd.numDecoded

template hybrid(c: Code; rd: var Reader; r: var Bits; ctx: int): uint32 =
  (if c.lz77: readHybrid(c, rd, r, ctx)
   else: (let cl = int(c.clusters[ctx]); r.readUint(c.confs[cl], c.readToken(rd, r, cl))))

proc begin(c: Code; r: var Bits; distMult = 0): Reader =
  result.distMult = distMult
  if not c.prefix: result.state = uint32(r.bits(32))

proc finish(c: Code; rd: Reader) =
  if not c.prefix and rd.state != 0x130000'u32: fail("damaged JPEG XL (ANS stream)")

proc readCode(r: var Bits; numDist: int; noLz77 = false): Code

proc readClusters(r: var Bits; numDist: int): seq[uint8] =
  if numDist == 1: return @[0'u8]
  result = newSeq[uint8](numDist)
  if r.flag:
    let nbits = r.bits(2)
    for i in 0 ..< numDist: result[i] = uint8(r.bits(nbits))
  else:
    let mtf = r.flag
    let c = readCode(r, 1, noLz77 = numDist <= 2)
    var rd = c.begin(r)
    for i in 0 ..< numDist:
      let v = c.hybrid(rd, r, 0)
      if v > 255: fail("damaged JPEG XL (clusters)")
      result[i] = uint8(v)
    c.finish(rd)
    if mtf:
      var m: array[256, uint8]
      for i in 0 .. 255: m[i] = uint8(i)
      for i in 0 ..< numDist:
        let idx = int(result[i])
        let v = m[idx]
        result[i] = v
        for k in countdown(idx, 1): m[k] = m[k - 1]
        m[0] = v
  var most = 0
  for v in result: most = max(most, int(v))
  var seen = newSeq[bool](most + 1)
  for v in result: seen[int(v)] = true
  for s in seen:
    if not s: fail("damaged JPEG XL (clusters)")

proc readCode(r: var Bits; numDist: int; noLz77 = false): Code =
  var nd = numDist
  result.lz77 = r.flag
  if result.lz77:
    if noLz77: fail("damaged JPEG XL (LZ77 where it may not be)")
    result.lzMinSym = r.u32((224, 0), (512, 0), (4096, 0), (8, 15))
    result.lzMinLen = r.u32((3, 0), (4, 0), (5, 2), (9, 8))
    result.lzConf = r.readHConf(8)
    inc nd
  # (what a reader that may fail gives goes into a local first: a damaged
  # file stops it half way, and Nim 2.2 frees what it had read only from a
  # local, not from a field it was going into)
  let clusters = r.readClusters(nd)
  result.clusters = clusters
  var numClusters = 0
  for v in result.clusters: numClusters = max(numClusters, int(v) + 1)
  result.prefix = r.flag
  let logAlpha = if result.prefix: 15 else: 5 + r.bits(2)
  result.confs = newSeq[HConf](numClusters)
  for i in 0 ..< numClusters: result.confs[i] = r.readHConf(logAlpha)
  result.histos = newSeq[Histo](numClusters)
  if result.prefix:
    var counts = newSeq[int](numClusters)
    for i in 0 ..< numClusters:
      counts[i] = 1
      if r.flag:
        let n = r.bits(4)
        counts[i] = 1 + (1 shl n) + r.bits(n)
      if counts[i] > 1 shl 15: fail("damaged JPEG XL (prefix code)")
    for i in 0 ..< numClusters:
      let histo = r.readPrefixHisto(counts[i])
      result.histos[i] = histo
  else:
    for i in 0 ..< numClusters:
      let histo = r.readAnsHisto(logAlpha)
      result.histos[i] = histo
  if r.overrun: fail("the JPEG XL file is cut short")

# ---- headers ---------------------------------------------------------------------------------

type
  ExtraChannel = object
    kind: int            # 0 alpha, 1 depth, 2 spot color, 3 selection mask, 4 black, ...
    bits, expBits: int
    floatSamples: bool
    dimShift: int
    associated: bool     # (alpha) premultiplied
    spot: array[4, float32]
  Header = object
    w, h: int
    orientation: int
    havePreview: bool
    previewW, previewH: int
    animated: bool
    tpsNum, tpsDen: int
    haveTimecodes: bool
    bits, expBits: int
    floatSamples: bool
    ec: seq[ExtraChannel]
    xyb: bool
    colorSpace: int      # 0 RGB, 1 grey, 2 XYB, 3 unknown
    wantIcc: bool
    tf: int              # transfer function: 13 sRGB, 8 linear, 1 BT.709, 16 PQ, 18 HLG, 17 DCI, -1 gamma
    gamma: float
    intensityTarget: float32
    invMat: array[9, float32]
    opsinBias: array[3, float32]
    quantBias: array[3, float32]
    quantBiasNum: float32
    up2, up4, up8: seq[float32]

const
  DefaultUp2 = [-0.01716200'f32, -0.03452303, -0.04022174, -0.02921014, -0.00624645,
    0.14111091, 0.28896755, 0.00278718, -0.01610267, 0.56661550,
    0.03777607, -0.01986694, -0.03144731, -0.01185068, -0.00213539]
  DefaultUp4 = [-0.02419067'f32, -0.03491987, -0.03693351, -0.03094285, -0.00529785,
    -0.01663432, -0.03556863, -0.03888905, -0.03516850, -0.00989469,
    0.23651958, 0.33392945, -0.01073543, -0.01313181, -0.03556694,
    0.13048175, 0.40103025, 0.03951150, -0.02077584, 0.46914198,
    -0.00209270, -0.01484589, -0.04064806, 0.18942530, 0.56279892,
    0.06674400, -0.02335494, -0.03551682, -0.00754830, -0.02267919,
    -0.02363578, 0.00315804, -0.03399098, -0.01359519, -0.00091653,
    -0.00335467, -0.01163294, -0.01610294, -0.00974088, -0.00191622,
    -0.01095446, -0.03198464, -0.04455121, -0.02799790, -0.00645912,
    0.06390599, 0.22963888, 0.00630981, -0.01897349, 0.67537268,
    0.08483369, -0.02534994, -0.02205197, -0.01667999, -0.00384443]
  DefaultUp8 = [-0.02928613'f32, -0.03706353, -0.03783812, -0.03324558, -0.00447632,
    -0.02519406, -0.03752601, -0.03901508, -0.03663285, -0.00646649,
    -0.02066407, -0.03838633, -0.04002101, -0.03900035, -0.00901973,
    -0.01626393, -0.03954148, -0.04046620, -0.03979621, -0.01224485,
    0.29895328, 0.35757708, -0.02447552, -0.01081748, -0.04314594,
    0.23903219, 0.41119301, -0.00573046, -0.01450239, -0.04246845,
    0.17567618, 0.45220643, 0.02287757, -0.01936783, -0.03583255,
    0.11572472, 0.47416733, 0.06284440, -0.02685066, 0.42720050,
    -0.02248939, -0.01155273, -0.04562755, 0.28689496, 0.49093869,
    -0.00007891, -0.01545926, -0.04562659, 0.21238920, 0.53980934,
    0.03369474, -0.02070211, -0.03866988, 0.14229550, 0.56593398,
    0.08045181, -0.02888298, -0.03680918, -0.00542229, -0.02920477,
    -0.02788574, -0.02118180, -0.03942402, -0.00775547, -0.02433614,
    -0.03193943, -0.02030828, -0.04044014, -0.01074016, -0.01930822,
    -0.03620399, -0.01974125, -0.03919545, -0.01456093, -0.00045072,
    -0.00360110, -0.01020207, -0.01231907, -0.00638988, -0.00071592,
    -0.00279122, -0.00957115, -0.01288327, -0.00730937, -0.00107783,
    -0.00210156, -0.00890705, -0.01317668, -0.00813895, -0.00153491,
    -0.02128481, -0.04173044, -0.04831487, -0.03293190, -0.00525260,
    -0.01720322, -0.04052736, -0.05045706, -0.03607317, -0.00738030,
    -0.01341764, -0.03965629, -0.05151616, -0.03814886, -0.01005819,
    0.18968273, 0.33063684, -0.01300105, -0.01372950, -0.04017465,
    0.13727832, 0.36402234, 0.01027890, -0.01832107, -0.03365072,
    0.08734506, 0.38194295, 0.04338228, -0.02525993, 0.56408126,
    0.00458352, -0.01648227, -0.04887868, 0.24585519, 0.62026135,
    0.04314807, -0.02213737, -0.04158014, 0.16637289, 0.65027023,
    0.09621636, -0.03101388, -0.04082742, -0.00904519, -0.02790922,
    -0.02117818, 0.00798662, -0.03995711, -0.01243427, -0.02231705,
    -0.02946266, 0.00992055, -0.03600283, -0.01684920, -0.00111684,
    -0.00411204, -0.01297130, -0.01723725, -0.01022545, -0.00165306,
    -0.00313110, -0.01218016, -0.01763266, -0.01125620, -0.00231663,
    -0.01374149, -0.03797620, -0.05142937, -0.03117307, -0.00581914,
    -0.01064003, -0.03608089, -0.05272168, -0.03375670, -0.00795586,
    0.09628104, 0.27129991, -0.00353779, -0.01734151, -0.03153981,
    0.05686230, 0.28500998, 0.02230594, -0.02374955, 0.68214326,
    0.05018048, -0.02320852, -0.04383616, 0.18459474, 0.71517975,
    0.10805613, -0.03263677, -0.03637639, -0.01394373, -0.02511203,
    -0.01728636, 0.05407331, -0.02867568, -0.01893131, -0.00240854,
    -0.00446511, -0.01636187, -0.02377053, -0.01522848, -0.00333334,
    -0.00819975, -0.02964169, -0.04499287, -0.02745350, -0.00612408,
    0.02727416, 0.19446600, 0.00159832, -0.02232473, 0.74982506,
    0.11452620, -0.03348048, -0.01605681, -0.02070339, -0.00458223]
  DefaultInvMat = [11.031566901960783'f32, -9.866943921568629, -0.16462299647058826,
    -3.254147380392157, 4.418770392156863, -0.16462299647058826,
    -3.6588512862745097, 2.7129230470588235, 1.9459282392156863]

proc readSize(r: var Bits; small: bool): (int, int) =
  ## (width, height) of a SizeHeader.
  var h, w: int
  let div8 = r.flag
  if div8: h = 8 * (1 + r.bits(5))
  else: h = r.u32((1, 9), (1, 13), (1, 18), (1, 30))
  let ratio = r.bits(3)
  if ratio == 0:
    if div8: w = 8 * (1 + r.bits(5))
    else: w = r.u32((1, 9), (1, 13), (1, 18), (1, 30))
  else:
    w = case ratio
      of 1: h
      of 2: h * 12 div 10
      of 3: h * 4 div 3
      of 4: h * 3 div 2
      of 5: h * 16 div 9
      of 6: h * 5 div 4
      else: h * 2
  discard small
  (w, h)

proc readBitDepth(r: var Bits): (int, int, bool) =
  if r.flag:
    let bits = r.u32((32, 0), (16, 0), (24, 0), (1, 6))
    let exp = r.bits(4) + 1
    let mant = bits - exp - 1
    if exp < 2 or exp > 8 or mant < 2 or mant > 23: fail("damaged JPEG XL (sample format)")
    (bits, exp, true)
  else:
    let bits = r.u32((8, 0), (10, 0), (12, 0), (1, 6))
    if bits > 31: fail("damaged JPEG XL (sample format)")
    (bits, 0, false)

proc readName(r: var Bits) =
  let n = r.u32((0, 0), (0, 4), (16, 5), (48, 10))
  r.skipBits(8 * n)

proc readCustomXY(r: var Bits) =
  for _ in 0 .. 1: discard r.u32((0, 19), (524288, 19), (1048576, 20), (2097152, 21))

proc readHeader(r: var Bits): Header =
  if r.bits(16) != 0x0AFF: fail("not a JPEG XL file")
  (result.w, result.h) = r.readSize(false)
  result.orientation = 1
  result.bits = 8
  result.xyb = true
  result.tf = 13
  result.intensityTarget = 255
  result.invMat = DefaultInvMat
  result.opsinBias = [-0.0037930732552754493'f32, -0.0037930732552754493, -0.0037930732552754493]
  result.quantBias = [float32(1.0 - 0.05465007330715401), float32(1.0 - 0.07005449891748593),
                      float32(1.0 - 0.049935103337343655)]
  result.quantBiasNum = 0.145
  result.up2 = @DefaultUp2
  result.up4 = @DefaultUp4
  result.up8 = @DefaultUp8
  let allDefault = r.flag
  if not allDefault:
    let extra = r.flag
    if extra:
      result.orientation = 1 + r.bits(3)
      if r.flag: discard r.readSize(false)                # intrinsic size
      if r.flag:                                           # preview
        result.havePreview = true
        let div8 = r.flag
        if div8: result.previewH = 8 * r.u32((16, 0), (32, 0), (1, 5), (33, 9))
        else: result.previewH = r.u32((1, 6), (65, 8), (321, 10), (1345, 12))
        let ratio = r.bits(3)
        if ratio == 0:
          if div8: result.previewW = 8 * r.u32((16, 0), (32, 0), (1, 5), (33, 9))
          else: result.previewW = r.u32((1, 6), (65, 8), (321, 10), (1345, 12))
        else:
          let h = result.previewH
          result.previewW = [0, h, h * 12 div 10, h * 4 div 3, h * 3 div 2, h * 16 div 9,
                             h * 5 div 4, h * 2][ratio]
      if r.flag:                                           # animation
        result.animated = true
        result.tpsNum = r.u32((100, 0), (1000, 0), (1, 10), (1, 30))
        result.tpsDen = r.u32((1, 0), (1001, 0), (1, 8), (1, 10))
        discard r.u32((0, 0), (0, 3), (0, 16), (0, 32))   # loops
        result.haveTimecodes = r.flag
    (result.bits, result.expBits, result.floatSamples) = r.readBitDepth()
    discard r.flag                                         # 16-bit buffers suffice
    let numExtra = r.u32((0, 0), (1, 0), (2, 4), (1, 12))
    if numExtra > 256: fail("damaged JPEG XL (too many extra channels)")
    for i in 0 ..< numExtra:
      var e = ExtraChannel(bits: 8)
      if not r.flag:
        e.kind = r.readEnum()
        (e.bits, e.expBits, e.floatSamples) = r.readBitDepth()
        e.dimShift = r.u32((0, 0), (3, 0), (4, 0), (1, 3))
        r.readName()
        case e.kind
        of 0: e.associated = r.flag
        of 2:
          for k in 0 .. 3: e.spot[k] = r.f16()
        of 5: discard r.u32((1, 0), (0, 2), (3, 4), (19, 8))
        of 1, 3, 4, 6, 15, 16: discard
        else: fail("damaged JPEG XL (extra channel type)")
      result.ec.add e
    result.xyb = r.flag
    # color encoding
    if not r.flag:
      result.wantIcc = r.flag
      result.colorSpace = r.readEnum()
      if result.colorSpace > 3: fail("damaged JPEG XL (color space)")
      if not result.wantIcc:
        if result.colorSpace != 2:
          let wp = r.readEnum()
          if wp == 2: r.readCustomXY()
        if result.colorSpace != 2 and result.colorSpace != 1:
          let pr = r.readEnum()
          if pr == 2:
            for _ in 0 .. 2: r.readCustomXY()
        if r.flag:
          result.tf = -1
          result.gamma = float(r.bits(24)) / 1e7
        else:
          result.tf = r.readEnum()
        discard r.readEnum()                               # rendering intent
    if extra:
      if not r.flag:                                       # tone mapping
        result.intensityTarget = r.f16()
        discard r.f16()
        discard r.flag
        discard r.f16()
        if result.intensityTarget <= 0: fail("damaged JPEG XL (intensity target)")
    r.readExtensions()
  # the custom transform data
  if not r.flag:
    if result.xyb:
      if not r.flag:
        for i in 0 .. 8: result.invMat[i] = r.f16()
        for i in 0 .. 2: result.opsinBias[i] = r.f16()
        for i in 0 .. 2: result.quantBias[i] = r.f16()
        result.quantBiasNum = r.f16()
    let mask = r.bits(3)
    if (mask and 1) != 0:
      for i in 0 ..< 15: result.up2[i] = r.f16()
    if (mask and 2) != 0:
      for i in 0 ..< 55: result.up4[i] = r.f16()
    if (mask and 4) != 0:
      for i in 0 ..< 210: result.up8[i] = r.f16()
  if result.w <= 0 or result.h <= 0: fail("damaged JPEG XL (size)")
  if result.w.int64 * result.h.int64 > (1'i64 shl 30): fail("JPEG XL picture too large")

proc byteKind1(b: int): int =
  if b in 'a'.ord .. 'z'.ord or b in 'A'.ord .. 'Z'.ord: 0
  elif b in '0'.ord .. '9'.ord or b == '.'.ord or b == ','.ord: 1
  elif b == 0: 2
  elif b == 1: 3
  elif b < 16: 4
  elif b == 255: 6
  elif b > 240: 5
  else: 7

proc byteKind2(b: int): int =
  if b in 'a'.ord .. 'z'.ord or b in 'A'.ord .. 'Z'.ord: 0
  elif b in '0'.ord .. '9'.ord or b == '.'.ord or b == ','.ord: 1
  elif b < 16: 2
  elif b > 240: 3
  else: 4

proc skipIcc(r: var Bits) =
  ## The ICC profile is entropy coded; read through it (its bytes are not kept).
  let size = r.u64()
  if size > 1'u64 shl 28: fail("damaged JPEG XL (ICC profile)")
  let c = readCode(r, 41)
  var rd = c.begin(r)
  var b1, b2 = 0
  for i in 0 ..< int(size):
    let ctx = if i <= 128: 0 else: 1 + byteKind1(b1) + byteKind2(b2) * 8
    let v = int(c.hybrid(rd, r, ctx)) and 255
    b2 = b1
    b1 = v
    if (i and 4095) == 0 and r.overrun: fail("the JPEG XL file is cut short")
  c.finish(rd)

# ---- the container -----------------------------------------------------------------------------

const
  CodestreamMagic = "\xFF\x0A"
  ContainerMagic = "\0\0\0\x0CJXL \r\n\x87\n"

proc be32(s: string; i: int): uint64 =
  (uint64(s[i].ord) shl 24) or (uint64(s[i + 1].ord) shl 16) or (uint64(s[i + 2].ord) shl 8) or
    uint64(s[i + 3].ord)

proc isJxl*(data: string): bool =
  ## Whether `data` begins as a JPEG XL file does: a bare codestream (FF 0A)
  ## or the ISO BMFF container.
  (data.len >= 2 and data[0 .. 1] == CodestreamMagic) or
    (data.len >= 12 and data[0 .. 11] == ContainerMagic)

proc codestream(data: string): string =
  ## The codestream of a file: itself, or the jxlc / jxlp boxes put together.
  if data.len >= 2 and data[0 .. 1] == CodestreamMagic: return data
  if not (data.len >= 12 and data[0 .. 11] == ContainerMagic): fail("not a JPEG XL file")
  var pos = 0
  var found = false
  while pos + 8 <= data.len:
    var size = be32(data, pos)
    let kind = data[pos + 4 ..< pos + 8]
    var head = 8
    if size == 1:
      if pos + 16 > data.len: break
      size = (be32(data, pos + 8) shl 32) or be32(data, pos + 12)
      head = 16
    elif size == 0:
      size = uint64(data.len - pos)
    if size < uint64(head): fail("damaged JPEG XL container")
    let stop = if size > uint64(data.len - pos): data.len else: pos + int(size)
    if kind == "jxlc":
      result.add data[pos + head ..< stop]
      found = true
    elif kind == "jxlp":
      if stop - pos - head >= 4: result.add data[pos + head + 4 ..< stop]
      found = true
    pos = stop
  if not found: fail("a JPEG XL container without a codestream")

# ---- modular ---------------------------------------------------------------------------------

type
  WPHeader = object
    p1C, p2C, p3Ca, p3Cb, p3Cc, p3Cd, p3Ce: int64
    w: array[4, uint32]
  MChannel = object
    w, h, hshift, vshift: int
    px: seq[int32]
  Squeeze = object
    horizontal, inPlace: bool
    beginC, numC: int
  MTransform = object
    id: int                  # 0 RCT, 1 palette, 2 squeeze
    beginC, rctType, numC, nbColors, nbDeltas, predictor: int
    squeezes: seq[Squeeze]
  MImage = object
    ch: seq[MChannel]
    nbMeta: int
    bitDepth: int
    transforms: seq[MTransform]
    wp: WPHeader
  TreeNode = object
    prop: int32              # -1 for a leaf
    split: int32
    left, right: int32       # left when the property is greater than split
    ctx: int32
    pred: int32
    offset: int64
    mult: int64
  MATree = object
    nodes: seq[TreeNode]
    code: Code

proc newChannel(w, h: int; hs = 0; vs = 0): MChannel =
  if w < 0 or h < 0 or w.int64 * h.int64 > (1'i64 shl 31): fail("damaged JPEG XL (channel size)")
  MChannel(w: w, h: h, hshift: hs, vshift: vs, px: newSeq[int32](w * h))

proc defaultWP(): WPHeader =
  WPHeader(p1C: 16, p2C: 10, p3Ca: 7, p3Cb: 7, p3Cc: 7, p3Cd: 0, p3Ce: 0, w: [13'u32, 12, 12, 12])

proc readWP(r: var Bits): WPHeader =
  if r.flag: return defaultWP()
  result.p1C = r.bits(5)
  result.p2C = r.bits(5)
  result.p3Ca = r.bits(5)
  result.p3Cb = r.bits(5)
  result.p3Cc = r.bits(5)
  result.p3Cd = r.bits(5)
  result.p3Ce = r.bits(5)
  for i in 0 .. 3: result.w[i] = uint32(r.bits(4))

proc readTransform(r: var Bits): MTransform =
  result.id = r.u32((0, 0), (1, 0), (2, 0), (3, 0))
  case result.id
  of 0, 1:
    result.beginC = r.u32((0, 3), (8, 6), (72, 10), (1096, 13))
    if result.id == 0:
      result.rctType = r.u32((6, 0), (0, 2), (2, 4), (10, 6))
      if result.rctType >= 42: fail("damaged JPEG XL (RCT)")
    else:
      result.numC = r.u32((1, 0), (3, 0), (4, 0), (1, 13))
      result.nbColors = r.u32((0, 8), (256, 10), (1280, 12), (5376, 16))
      result.nbDeltas = r.u32((0, 0), (1, 8), (257, 10), (1281, 16))
      result.predictor = r.bits(4)
      if result.predictor >= 14: fail("damaged JPEG XL (palette predictor)")
  of 2:
    let n = r.u32((0, 0), (1, 4), (9, 6), (41, 8))
    for _ in 0 ..< n:
      var s: Squeeze
      s.horizontal = r.flag
      s.inPlace = r.flag
      s.beginC = r.u32((0, 3), (8, 6), (72, 10), (1096, 13))
      s.numC = r.u32((1, 0), (2, 0), (3, 0), (4, 4))
      result.squeezes.add s
  else: fail("damaged JPEG XL (transform)")

proc checkEqual(img: MImage; c1, c2: int) =
  if c1 < 0 or c1 >= img.ch.len or c2 >= img.ch.len or c2 < c1: fail("damaged JPEG XL (channel range)")
  if c1 < img.nbMeta and c2 >= img.nbMeta: fail("damaged JPEG XL (channel range)")
  for c in c1 + 1 .. c2:
    let a = img.ch[c1]
    let b = img.ch[c]
    if a.w != b.w or a.h != b.h or a.hshift != b.hshift or a.vshift != b.vshift:
      fail("damaged JPEG XL (channels differ)")

proc defaultSqueezes(img: MImage): seq[Squeeze] =
  let nb = img.ch.len - img.nbMeta
  if nb <= 0: fail("damaged JPEG XL (squeeze)")
  var w = img.ch[img.nbMeta].w
  var h = img.ch[img.nbMeta].h
  if nb > 2 and img.ch[img.nbMeta + 1].w == w and img.ch[img.nbMeta + 1].h == h:
    result.add Squeeze(horizontal: true, inPlace: false, beginC: img.nbMeta + 1, numC: 2)
    result.add Squeeze(horizontal: false, inPlace: false, beginC: img.nbMeta + 1, numC: 2)
  var p = Squeeze(beginC: img.nbMeta, numC: nb, inPlace: true)
  if not (w > h) and h > 8:
    p.horizontal = false
    result.add p
    h = (h + 1) div 2
  while w > 8 or h > 8:
    if w > 8:
      p.horizontal = true
      result.add p
      w = (w + 1) div 2
    if h > 8:
      p.horizontal = false
      result.add p
      h = (h + 1) div 2

proc metaApply(img: var MImage; t: var MTransform) =
  case t.id
  of 0: img.checkEqual(t.beginC, t.beginC + 2)
  of 1:
    let endC = t.beginC + t.numC - 1
    img.checkEqual(t.beginC, endC)
    if t.beginC >= img.nbMeta: inc img.nbMeta
    else:
      if endC >= img.nbMeta: fail("damaged JPEG XL (palette)")
      img.nbMeta += 2 - t.numC
    img.ch.cut(t.beginC + 1, endC + 1)
    var p = newChannel(t.nbColors + t.nbDeltas, t.numC)
    p.hshift = -1
    p.vshift = -1
    img.ch.insert(p, 0)
  else:
    if t.squeezes.len == 0: t.squeezes = defaultSqueezes(img)
    for s in t.squeezes:
      let c1 = s.beginC
      let c2 = s.beginC + s.numC - 1
      if c1 < 0 or c1 >= img.ch.len or c2 >= img.ch.len or c2 < c1: fail("damaged JPEG XL (squeeze)")
      if c1 < img.nbMeta:
        if c2 >= img.nbMeta or not s.inPlace: fail("damaged JPEG XL (squeeze)")
        img.nbMeta += s.numC
      let offset = if s.inPlace: c2 + 1 else: img.ch.len
      for c in c1 .. c2:
        if img.ch[c].hshift > 30 or img.ch[c].vshift > 30: fail("damaged JPEG XL (squeeze)")
        var w = img.ch[c].w
        var h = img.ch[c].h
        if w == 0 or h == 0: fail("damaged JPEG XL (squeeze)")
        if s.horizontal:
          img.ch[c].w = (w + 1) div 2
          if img.ch[c].hshift >= 0: inc img.ch[c].hshift
          w = w - (w + 1) div 2
        else:
          img.ch[c].h = (h + 1) div 2
          if img.ch[c].vshift >= 0: inc img.ch[c].vshift
          h = h - (h + 1) div 2
        img.ch[c].px.setLen(img.ch[c].w * img.ch[c].h)
        img.ch.insert(newChannel(w, h, img.ch[c].hshift, img.ch[c].vshift), offset + (c - c1))

# -- predictors

const DivLookup = block:
  var t: array[64, uint32]
  for i in 0 .. 63: t[i] = uint32((1 shl 24) div (i + 1))
  t

type
  WPState = object
    pred: array[4, int64]
    sum: int64                # the prediction before rounding
    errs: array[4, seq[uint32]]
    err: seq[int32]
    hdr: WPHeader

proc initWP(h: WPHeader; w: int): WPState =
  result.hdr = h
  for i in 0 .. 3: result.errs[i] = newSeq[uint32]((w + 2) * 2)
  result.err = newSeq[int32]((w + 2) * 2)

proc errorWeight(x: uint64; maxweight: uint32): uint32 {.inline.} =
  var shift = floorLog2(x + 1) - 5
  if shift < 0: shift = 0
  4'u32 + ((maxweight * DivLookup[int(x shr shift)]) shr shift)

proc wpPredict(s: var WPState; x, y, w: int; n, wv, ne, nw, nn: int64; maxErr: var int64): int64 {.inline.} =
  let cur = if (y and 1) != 0: 0 else: w + 2
  let prev = if (y and 1) != 0: w + 2 else: 0
  let posN = prev + x
  let posNE = if x < w - 1: posN + 1 else: posN
  let posNW = if x > 0: posN - 1 else: posN
  var weights: array[4, uint32]
  for i in 0 .. 3:
    let er = cast[ptr UncheckedArray[uint32]](addr s.errs[i][0])
    let e = uint64(er[posN]) + uint64(er[posNE]) + uint64(er[posNW])
    weights[i] = errorWeight(e, s.hdr.w[i])
  let N = n shl 3
  let W = wv shl 3
  let NE = ne shl 3
  let NW = nw shl 3
  let NN = nn shl 3
  let te = cast[ptr UncheckedArray[int32]](addr s.err[0])
  let teW = if x == 0: 0'i64 else: int64(te[cur + x - 1])
  let teN = int64(te[posN])
  let teNW = int64(te[posNW])
  let sumWN = teN + teW
  let teNE = int64(te[posNE])
  var p = teW
  if abs(teN) > abs(p): p = teN
  if abs(teNW) > abs(p): p = teNW
  if abs(teNE) > abs(p): p = teNE
  maxErr = p
  s.pred[0] = W + NE - N
  s.pred[1] = N - (((sumWN + teNE) * s.hdr.p1C) shr 5)
  s.pred[2] = W - (((sumWN + teNW) * s.hdr.p2C) shr 5)
  s.pred[3] = N - ((teNW * s.hdr.p3Ca + teN * s.hdr.p3Cb + teNE * s.hdr.p3Cc +
                    (NN - N) * s.hdr.p3Cd + (NW - W) * s.hdr.p3Ce) shr 5)
  var wsum = 0'u32
  for i in 0 .. 3: wsum += weights[i]
  let logw = floorLog2(uint64(wsum))
  wsum = 0
  for i in 0 .. 3:
    weights[i] = weights[i] shr (logw - 4)
    wsum += weights[i]
  var sum = int64(wsum shr 1) - 1
  for i in 0 .. 3: sum += s.pred[i] * int64(weights[i])
  s.sum = (sum * int64(DivLookup[int(wsum) - 1])) shr 24
  if ((teN xor teW) or (teN xor teNW)) > 0:
    return (s.sum + 3) shr 3
  let mx = max(W, max(NE, N))
  let mn = min(W, min(NE, N))
  s.sum = max(mn, min(mx, s.sum))
  (s.sum + 3) shr 3

proc wpUpdate(s: var WPState; val: int64; x, y, w: int) {.inline.} =
  let cur = if (y and 1) != 0: 0 else: w + 2
  let prev = if (y and 1) != 0: w + 2 else: 0
  let v = val shl 3
  s.err[cur + x] = int32(s.sum - v)
  for i in 0 .. 3:
    let e = uint32((abs(s.pred[i] - v) + 3) shr 3)
    let er = cast[ptr UncheckedArray[uint32]](addr s.errs[i][0])
    er[cur + x] = e
    er[prev + x + 1] += e

proc clampedGradient(n, w, l: int64): int64 {.inline.} =
  let m = min(n, w)
  let M = max(n, w)
  let g = n + w - l
  if l > M: m elif l < m: M else: g

proc predictOne(p: int; left, top, toptop, topleft, topright, leftleft, toprightright, wp: int64): int64 {.inline.} =
  case p
  of 0: 0
  of 1: left
  of 2: top
  of 3: (left + top) div 2
  of 4:
    let pp = left + top - topleft
    if abs(pp - left) < abs(pp - top): left else: top
  of 5: clampedGradient(left, top, topleft)
  of 6: wp
  of 7: topright
  of 8: topleft
  of 9: leftleft
  of 10: (left + topleft) div 2
  of 11: (topleft + top) div 2
  of 12: (top + topright) div 2
  else: (6 * top - 2 * toptop + 7 * left + leftleft + toprightright + 3 * topright + 8) div 16

proc readTree(r: var Bits; limit: int): MATree =
  let c = readCode(r, 6)
  var rd = c.begin(r)
  var toDecode = 1
  var leaves = 0'i32
  while toDecode > 0:
    if result.nodes.len > limit: fail("damaged JPEG XL (tree too large)")
    dec toDecode
    let prop = int(c.hybrid(rd, r, 1)) - 1
    if prop > 255: fail("damaged JPEG XL (tree)")
    if prop == -1:
      let pred = int(c.hybrid(rd, r, 2))
      if pred >= 14: fail("damaged JPEG XL (predictor)")
      let off = unpackSigned(c.hybrid(rd, r, 3))
      let mulLog = int(c.hybrid(rd, r, 4))
      if mulLog >= 31: fail("damaged JPEG XL (tree)")
      let mulBits = int(c.hybrid(rd, r, 5))
      if mulBits >= (1 shl (31 - mulLog)) - 1: fail("damaged JPEG XL (tree)")
      result.nodes.add TreeNode(prop: -1, ctx: leaves, pred: int32(pred), offset: off,
                                mult: int64((mulBits + 1) shl mulLog))
      inc leaves
    else:
      let split = unpackSigned(c.hybrid(rd, r, 0))
      let at = result.nodes.len
      result.nodes.add TreeNode(prop: int32(prop), split: split,
                                left: int32(at + toDecode + 1), right: int32(at + toDecode + 2))
      toDecode += 2
    if r.overrun: fail("the JPEG XL file is cut short")
  c.finish(rd)
  let code = readCode(r, (result.nodes.len + 1) div 2)   # (a local first: see `readCode`)
  result.code = code

proc filterTree(t: seq[TreeNode]; chan, stream: int): seq[TreeNode] =
  ## The tree with the static properties (channel, stream) decided.
  proc resolve(t: seq[TreeNode]; i: int; chan, stream: int): int =
    var i = i
    while t[i].prop == 0 or t[i].prop == 1:
      let v = if t[i].prop == 0: chan else: stream
      i = if v > t[i].split: int(t[i].left) else: int(t[i].right)
    i
  var queue = @[resolve(t, 0, chan, stream)]
  var q = 0
  while q < queue.len:
    let i = queue[q]
    inc q
    var n = t[i]
    if n.prop >= 0:
      let l = resolve(t, int(n.left), chan, stream)
      let r = resolve(t, int(n.right), chan, stream)
      n.left = int32(queue.len)
      queue.add l
      n.right = int32(queue.len)
      queue.add r
    result.add n

proc decodeChannel(r: var Bits; tree: MATree; rd: var Reader; img: var MImage; chan, stream: int;
                   wph: WPHeader) =
  let ft = filterTree(tree.nodes, chan, stream)
  let w = img.ch[chan].w
  let h = img.ch[chan].h
  if w == 0 or h == 0: return
  var useWP = false
  var maxProp = 0
  for n in ft:
    if n.prop < 0:
      if n.pred == 6: useWP = true
    else:
      maxProp = max(maxProp, int(n.prop))
      if n.prop == 15: useWP = true
  let c = tree.code
  var wp: WPState
  if useWP: wp = initWP(wph, w)
  let p = cast[ptr UncheckedArray[int32]](addr img.ch[chan].px[0])
  # a single leaf
  if ft.len == 1:
    let leaf = ft[0]
    let ctx = int(leaf.ctx)
    let cl = int(c.clusters[ctx])
    if leaf.pred == 0 and not c.lz77 and c.histos[cl].single >= 0 and
        c.histos[cl].single < c.confs[cl].split and (c.prefix or true):
      # no bits at all: every sample the same
      let v = int32(int64(unpackSigned(uint32(c.histos[cl].single))) * leaf.mult + leaf.offset)
      for i in 0 ..< w * h: p[i] = v
      return
    if leaf.pred == 5 and not useWP:
      for y in 0 ..< h:
        let row = y * w
        for x in 0 ..< w:
          var guess: int64
          if y == 0:
            guess = if x > 0: int64(p[row + x - 1]) else: 0
          elif x == 0:
            guess = int64(p[row - w])
          else:
            guess = clampedGradient(int64(p[row + x - 1]), int64(p[row - w + x]), int64(p[row - w + x - 1]))
          let v = c.hybrid(rd, r, ctx)
          p[row + x] = int32(int64(unpackSigned(v)) * leaf.mult + leaf.offset + guess)
        if r.overrun: fail("the JPEG XL file is cut short")
      return
  # the general case: properties as the tree asks for them
  var refs: seq[int]                   # previous channels like this one
  var refProps: seq[int64]
  let nref = if maxProp >= 16: (maxProp - 16) div 4 + 1 else: 0
  if nref > 0:
    var j = chan - 1
    while j >= 0 and refs.len < nref:
      let o = img.ch[j]
      if o.w == w and o.h == h and o.hshift == img.ch[chan].hshift and o.vshift == img.ch[chan].vshift:
        refs.add j
      dec j
    refProps = newSeq[int64](w * nref * 4)
  for y in 0 ..< h:
    let row = y * w
    if nref > 0:
      for k in 0 ..< refProps.len: refProps[k] = 0
      for ri, j in refs:
        let q = cast[ptr UncheckedArray[int32]](addr img.ch[j].px[0])
        for x in 0 ..< w:
          let v = int64(q[row + x])
          let vleft = if x > 0: int64(q[row + x - 1]) else: 0'i64
          let vtop = if y > 0: int64(q[row - w + x]) else: vleft
          let vtopleft = if x > 0 and y > 0: int64(q[row - w + x - 1]) else: vleft
          let pr = clampedGradient(vleft, vtop, vtopleft)
          let o = (x * nref + ri) * 4
          refProps[o] = abs(v)
          refProps[o + 1] = v
          refProps[o + 2] = abs(v - pr)
          refProps[o + 3] = v - pr
    var prevGrad = 0'i64
    for x in 0 ..< w:
      let left = if x > 0: int64(p[row + x - 1]) elif y > 0: int64(p[row - w + x]) else: 0'i64
      let top = if y > 0: int64(p[row - w + x]) else: left
      let topleft = if x > 0 and y > 0: int64(p[row - w + x - 1]) else: left
      let topright = if x + 1 < w and y > 0: int64(p[row - w + x + 1]) else: top
      let leftleft = if x > 1: int64(p[row + x - 2]) else: left
      let toptop = if y > 1: int64(p[row - 2 * w + x]) else: top
      let toprightright = if x + 2 < w and y > 0: int64(p[row - w + x + 2]) else: topright
      var maxErr = 0'i64
      var wpv = 0'i64
      if useWP: wpv = wp.wpPredict(x, y, w, top, left, topright, topleft, toptop, maxErr)
      let grad = left + top - topleft
      var n = 0
      while ft[n].prop >= 0:
        let pr = int(ft[n].prop)
        let v = case pr
          of 2: int64(y)
          of 3: int64(x)
          of 4: abs(top)
          of 5: abs(left)
          of 6: top
          of 7: left
          of 8: left - prevGrad
          of 9: grad
          of 10: left - topleft
          of 11: topleft - top
          of 12: top - topright
          of 13: top - toptop
          of 14: left - leftleft
          of 15: maxErr
          else:
            let k = pr - 16
            if k < nref * 4: refProps[x * nref * 4 + k] else: 0'i64
        n = if v > int64(ft[n].split): int(ft[n].left) else: int(ft[n].right)
      prevGrad = grad
      let leaf = addr ft[n]
      let guess = predictOne(int(leaf.pred), left, top, toptop, topleft, topright, leftleft,
                             toprightright, wpv)
      let v = c.hybrid(rd, r, int(leaf.ctx))
      let val = int32(int64(unpackSigned(v)) * leaf.mult + leaf.offset + guess)
      p[row + x] = val
      if useWP: wp.wpUpdate(int64(val), x, y, w)
    if r.overrun: fail("the JPEG XL file is cut short")

# -- the inverse transforms

proc invRct(img: var MImage; t: MTransform) =
  let m = t.beginC
  img.checkEqual(m, m + 2)
  if t.rctType == 0: return
  let perm = t.rctType div 7
  let custom = t.rctType mod 7
  let n = img.ch[m].w * img.ch[m].h
  var a = move img.ch[m].px
  var b = move img.ch[m + 1].px
  var c = move img.ch[m + 2].px
  if custom == 6:
    for i in 0 ..< n:
      let Y = a[i]
      let Co = b[i]
      let Cg = c[i]
      let tmp = Y - (Cg shr 1)
      let G = Cg + tmp
      let B = tmp - (Co shr 1)
      a[i] = B + Co
      b[i] = G
      c[i] = B
  elif custom != 0:
    let second = custom shr 1
    let third = custom and 1
    for i in 0 ..< n:
      let f = a[i]
      var s = b[i]
      var th = c[i]
      if third == 1: th = th + f
      if second == 1: s = s + f
      elif second == 2: s = s + ((f + th) shr 1)
      b[i] = s
      c[i] = th
  img.ch[m + (perm mod 3)].px = move a
  img.ch[m + ((perm + 1 + perm div 3) mod 3)].px = move b
  img.ch[m + ((perm + 2 - perm div 3) mod 3)].px = move c

const DeltaPalette = [
  [0'i32, 0, 0], [4'i32, 4, 4], [11'i32, 0, 0], [0'i32, 0, -13], [0'i32, -12, 0], [-10'i32, -10, -10],
  [-18'i32, -18, -18], [-27'i32, -27, -27], [-18'i32, -18, 0], [0'i32, 0, -32], [-32'i32, 0, 0],
  [-37'i32, -37, -37], [0'i32, -32, -32], [24'i32, 24, 45], [50'i32, 50, 50], [-45'i32, -24, -24],
  [-24'i32, -45, -45], [0'i32, -24, -24], [-34'i32, -34, 0], [-24'i32, 0, -24], [-45'i32, -45, -24],
  [64'i32, 64, 64], [-32'i32, 0, -32], [0'i32, -32, 0], [-32'i32, 0, 32], [-24'i32, -45, -24],
  [45'i32, 24, 45], [24'i32, -24, -45], [-45'i32, -24, 24], [80'i32, 80, 80], [64'i32, 0, 0],
  [0'i32, 0, -64], [0'i32, -64, -64], [-24'i32, -24, 45], [96'i32, 96, 96], [64'i32, 64, 0],
  [45'i32, -24, -24], [34'i32, -34, 0], [112'i32, 112, 112], [24'i32, -45, -45], [45'i32, 45, -24],
  [0'i32, -32, 32], [24'i32, -24, 45], [0'i32, 96, 96], [45'i32, -24, 24], [24'i32, -45, -24],
  [-24'i32, -45, 24], [0'i32, -64, 0], [96'i32, 0, 0], [128'i32, 128, 128], [64'i32, 0, 64],
  [144'i32, 144, 144], [96'i32, 96, 0], [-36'i32, -36, 36], [45'i32, -24, -45], [45'i32, -45, -24],
  [0'i32, 0, -96], [0'i32, 128, 128], [0'i32, 96, 0], [45'i32, 24, -45], [-128'i32, 0, 0],
  [24'i32, -45, 24], [-45'i32, 24, -45], [64'i32, 0, -64], [64'i32, -64, -64], [96'i32, 0, 96],
  [45'i32, -45, 24], [24'i32, 45, -45], [64'i32, 64, -64], [128'i32, 128, 0], [0'i32, 0, -128],
  [-24'i32, 45, -45]]

proc paletteValue(pal: MChannel; index, c, size, bitDepth: int): int32 =
  if index < 0:
    if c >= 3: return 0
    var i = -(index + 1)
    i = i mod (1 + 2 * (DeltaPalette.len - 1))
    result = DeltaPalette[(i + 1) shr 1][c] * (if (i and 1) == 0: -1'i32 else: 1'i32)
    if bitDepth > 8: result = result * (1'i32 shl (bitDepth - 8))
  elif index >= size and index < size + 64:
    if c >= 3: return 0
    let i = (index - size) shr (c * 2)
    result = int32(((uint64(i mod 4) * ((1'u64 shl bitDepth) - 1)) shr 2) +
                   uint64(1 shl max(0, bitDepth - 3)))
  elif index >= size + 64:
    if c >= 3: return 0
    var i = index - size - 64
    if c == 1: i = i div 5
    elif c == 2: i = i div 25
    result = int32((uint64(i mod 5) * ((1'u64 shl bitDepth) - 1)) shr 2)
  else:
    result = pal.px[c * pal.w + index]

proc invPalette(img: var MImage; t: MTransform) =
  if img.nbMeta < 1: fail("damaged JPEG XL (palette)")
  let nb = img.ch[0].h
  let c0 = t.beginC + 1
  if c0 >= img.ch.len or nb < 1: fail("damaged JPEG XL (palette)")
  let w = img.ch[c0].w
  let h = img.ch[c0].h
  for i in 1 ..< nb:
    img.ch.insert(newChannel(w, h, img.ch[c0].hshift, img.ch[c0].vshift), c0 + 1)
  let pal = img.ch[0]
  let size = pal.w
  let bd = min(img.bitDepth, 24)
  if w > 0:
    if t.nbDeltas == 0 and t.predictor == 0:
      let idx = img.ch[c0].px
      for c in 0 ..< nb:
        var o = addr img.ch[c0 + c].px
        for i in 0 ..< w * h:
          var k = int(idx[i])
          if nb == 1: k = clamp(k, 0, size - 1)
          o[i] = paletteValue(pal, k, c, size, bd)
    else:
      let idx = img.ch[c0].px
      for c in 0 ..< nb:
        let pp = cast[ptr UncheckedArray[int32]](addr img.ch[c0 + c].px[0])
        var wp: WPState
        if t.predictor == 6: wp = initWP(img.wp, w)
        for y in 0 ..< h:
          for x in 0 ..< w:
            let k = int(idx[y * w + x])
            var v = int64(paletteValue(pal, k, c, size, bd))
            if k < t.nbDeltas:
              let row = y * w
              let left = if x > 0: int64(pp[row + x - 1]) elif y > 0: int64(pp[row - w + x]) else: 0'i64
              let top = if y > 0: int64(pp[row - w + x]) else: left
              let topleft = if x > 0 and y > 0: int64(pp[row - w + x - 1]) else: left
              let topright = if x + 1 < w and y > 0: int64(pp[row - w + x + 1]) else: top
              let leftleft = if x > 1: int64(pp[row + x - 2]) else: left
              let toptop = if y > 1: int64(pp[row - 2 * w + x]) else: top
              let trr = if x + 2 < w and y > 0: int64(pp[row - w + x + 2]) else: topright
              var me = 0'i64
              var wpv = 0'i64
              if t.predictor == 6: wpv = wp.wpPredict(x, y, w, top, left, topright, topleft, toptop, me)
              v += predictOne(t.predictor, left, top, toptop, topleft, topright, leftleft, trr, wpv)
            elif t.predictor == 6:
              let row = y * w
              let left = if x > 0: int64(pp[row + x - 1]) elif y > 0: int64(pp[row - w + x]) else: 0'i64
              let top = if y > 0: int64(pp[row - w + x]) else: left
              let topleft = if x > 0 and y > 0: int64(pp[row - w + x - 1]) else: left
              let topright = if x + 1 < w and y > 0: int64(pp[row - w + x + 1]) else: top
              let toptop = if y > 1: int64(pp[row - 2 * w + x]) else: top
              var me = 0'i64
              discard wp.wpPredict(x, y, w, top, left, topright, topleft, toptop, me)
            pp[y * w + x] = int32(v)
            if t.predictor == 6: wp.wpUpdate(int64(pp[y * w + x]), x, y, w)
  if c0 >= img.nbMeta: dec img.nbMeta
  else: img.nbMeta -= 2 - nb
  img.ch.delete(0)

proc smoothTendency(B, a, n: int64): int64 {.inline.} =
  if B >= a and a >= n:
    result = (4 * B - 3 * n - a + 6) div 12
    if result - (result and 1) > 2 * (B - a): result = 2 * (B - a) + 1
    if result + (result and 1) > 2 * (a - n): result = 2 * (a - n)
  elif B <= a and a <= n:
    result = (4 * B - 3 * n - a - 6) div 12
    if result + (result and 1) < 2 * (B - a): result = 2 * (B - a) - 1
    if result - (result and 1) < 2 * (a - n): result = 2 * (a - n)

proc invHSqueeze(img: var MImage; c, rc: int) =
  let chin = addr img.ch[c]
  let res = addr img.ch[rc]
  if res.w == 0: return
  if chin.w != cdiv(chin.w + res.w, 2) or chin.h != res.h: fail("damaged JPEG XL (squeeze)")
  var o = newChannel(chin.w + res.w, chin.h, chin.hshift - 1, chin.vshift)
  for y in 0 ..< chin.h:
    let ri = y * res.w
    let ai = y * chin.w
    let oi = y * o.w
    for x in 0 ..< res.w:
      let diffMinusTendency = int64(res.px[ri + x])
      let avg = int64(chin.px[ai + x])
      let nextAvg = if x + 1 < chin.w: int64(chin.px[ai + x + 1]) else: avg
      let left = if x > 0: int64(o.px[oi + 2 * x - 1]) else: avg
      let diff = diffMinusTendency + smoothTendency(left, avg, nextAvg)
      let A = avg + diff div 2
      o.px[oi + 2 * x] = int32(A)
      o.px[oi + 2 * x + 1] = int32(A - diff)
    if (o.w and 1) == 1: o.px[oi + o.w - 1] = chin.px[ai + chin.w - 1]
  img.ch[c] = move o

proc invVSqueeze(img: var MImage; c, rc: int) =
  let chin = addr img.ch[c]
  let res = addr img.ch[rc]
  if res.h == 0: return
  if chin.h != cdiv(chin.h + res.h, 2) or chin.w != res.w: fail("damaged JPEG XL (squeeze)")
  var o = newChannel(chin.w, chin.h + res.h, chin.hshift, chin.vshift - 1)
  let w = chin.w
  for y in 0 ..< res.h:
    for x in 0 ..< w:
      let avg = int64(chin.px[y * w + x])
      let nextAvg = if y + 1 < chin.h: int64(chin.px[(y + 1) * w + x]) else: avg
      let top = if y > 0: int64(o.px[(2 * y - 1) * w + x]) else: avg
      let diff = int64(res.px[y * w + x]) + smoothTendency(top, avg, nextAvg)
      let v = avg + diff div 2
      o.px[2 * y * w + x] = int32(v)
      o.px[(2 * y + 1) * w + x] = int32(v - diff)
  if (o.h and 1) == 1:
    let y = chin.h - 1
    for x in 0 ..< w: o.px[2 * y * w + x] = chin.px[y * w + x]
  img.ch[c] = move o

proc invSqueeze(img: var MImage; t: MTransform) =
  for i in countdown(t.squeezes.high, 0):
    let s = t.squeezes[i]
    let c1 = s.beginC
    let c2 = s.beginC + s.numC - 1
    if c1 < 0 or c1 >= img.ch.len or c2 >= img.ch.len or c2 < c1: fail("damaged JPEG XL (squeeze)")
    let offset = if s.inPlace: c2 + 1 else: img.ch.len + c1 - c2 - 1
    if c1 < img.nbMeta:
      if img.nbMeta <= s.numC: fail("damaged JPEG XL (squeeze)")
      img.nbMeta -= s.numC
    for c in c1 .. c2:
      let rc = offset + c - c1
      if rc >= img.ch.len: fail("damaged JPEG XL (squeeze)")
      if img.ch[c].w < img.ch[rc].w or img.ch[c].h < img.ch[rc].h: fail("damaged JPEG XL (squeeze)")
      if s.horizontal: img.invHSqueeze(c, rc)
      else: img.invVSqueeze(c, rc)
    img.ch.cut(offset, offset + s.numC)

proc undoTransforms(img: var MImage) =
  for i in countdown(img.transforms.high, 0):
    let t = img.transforms[i]
    case t.id
    of 0: img.invRct(t)
    of 1: img.invPalette(t)
    else: img.invSqueeze(t)
  img.transforms.setLen(0)

proc decodeModular(r: var Bits; img: var MImage; stream: int; global: ptr MATree;
                   maxChanSize = high(int); undo = true) =
  ## One modular stream: its header, its transforms, its channels (those not
  ## larger than `maxChanSize`; the rest come with the groups).
  if img.ch.len == 0: return
  let useGlobal = r.flag
  img.wp = r.readWP()
  let nt = r.u32((0, 0), (1, 0), (2, 4), (18, 8))
  img.transforms.setLen(0)
  for _ in 0 ..< nt:
    var t = r.readTransform()
    img.metaApply(t)
    img.transforms.add t
  if r.overrun: fail("the JPEG XL file is cut short")
  var distMult = 0
  var numChans = 0
  var pixels = 0
  for i, ch in img.ch:
    if i >= img.nbMeta and (ch.w > maxChanSize or ch.h > maxChanSize): break
    if ch.w == 0 or ch.h == 0: continue
    distMult = max(distMult, ch.w)
    pixels += ch.w * ch.h
    inc numChans
  if numChans > 0:
    var local: MATree
    var tree: ptr MATree
    if useGlobal:
      if global == nil or global.nodes.len == 0: fail("damaged JPEG XL (no global tree)")
      tree = global
    else:
      let got = readTree(r, min(1 shl 20, 1024 + pixels))   # (a local first: see `readCode`)
      local = got
      tree = addr local
    var rd = tree.code.begin(r, distMult)
    for i in 0 ..< img.ch.len:
      let ch = img.ch[i]
      if i >= img.nbMeta and (ch.w > maxChanSize or ch.h > maxChanSize): break
      if ch.w == 0 or ch.h == 0: continue
      decodeChannel(r, tree[], rd, img, i, stream, img.wp)
    tree.code.finish(rd)
  if undo: img.undoTransforms()

# ---- frames ----------------------------------------------------------------------------------

type
  BlendInfo = object
    mode, alpha, source: int     # mode: 0 replace, 1 add, 2 blend, 3 alpha-weighted add, 4 multiply
    clamp: bool
  FrameHeader = object
    kind: int                    # 0 regular, 1 LF, 2 reference only, 3 skip progressive
    modular: bool
    flags: uint64
    ycbcr: bool
    hs, vs: array[3, int]        # chroma subsampling of each channel (Cb, Y, Cr)
    upsampling: int
    ecUps: seq[int]
    groupShift: int
    xqm, bqm: int
    numPasses: int
    shift: seq[int]
    downsample, lastPass: seq[int]
    lfLevel: int
    x0, y0: int
    width, height: int           # in pixels, as on the canvas
    custom: bool                 # a size or an origin of its own
    blend: BlendInfo
    ecBlend: seq[BlendInfo]
    duration: int
    isLast: bool
    saveAs: int
    saveBeforeCt: bool
    gab: bool
    gabW: array[6, float32]
    epfIters: int
    epfSharp: array[8, float32]
    epfScale: array[3, float32]
    epfPass1Zero, epfPass2Zero: float32
    epfQuantMul, epfPass0Sigma, epfPass2Sigma, epfBorderSad, epfSigmaModular: float32
    # sizes that follow
    sw, sh: int                  # samples (before the upsampling)
    gdim: int
    xblocks, yblocks: int
    xgroups, numGroups: int
    xlfgroups, numLfGroups: int

const
  FlagNoise = 1'u64
  FlagPatches = 2'u64
  FlagSplines = 16'u64
  FlagUseLf = 32'u64
  FlagSkipSmoothing = 128'u64

proc canBeReferenced(f: FrameHeader): bool =
  not f.isLast and f.kind != 1 and (f.duration == 0 or f.saveAs != 0)

proc readBlend(r: var Bits; numEc: int; partial: bool): BlendInfo =
  result.mode = r.u32((0, 0), (1, 0), (2, 0), (3, 2))
  if result.mode > 4: fail("damaged JPEG XL (blend mode)")
  let usesAlpha = numEc > 0 and (result.mode == 2 or result.mode == 3)
  if usesAlpha:
    result.alpha = r.u32((0, 0), (1, 0), (2, 0), (3, 3))
    if result.alpha >= numEc: fail("damaged JPEG XL (blend alpha)")
  if usesAlpha or result.mode == 4: result.clamp = r.flag
  if result.mode != 0 or partial: result.source = r.u32((0, 0), (1, 0), (2, 0), (3, 0))

proc setLoopFilterDefaults(f: var FrameHeader) =
  f.gab = true
  for i in 0 .. 2:
    f.gabW[2 * i] = 1.1'f32 * 0.104699568'f32
    f.gabW[2 * i + 1] = 1.1'f32 * 0.055680538'f32
  f.epfIters = 2
  for i in 0 .. 7: f.epfSharp[i] = float32(i) / 7
  f.epfScale = [40.0'f32, 5.0, 3.5]
  f.epfPass1Zero = 0.45
  f.epfPass2Zero = 0.6
  f.epfQuantMul = 0.46
  f.epfPass0Sigma = 0.9
  f.epfPass2Sigma = 6.5
  f.epfBorderSad = 0.6666666666666666
  f.epfSigmaModular = 1.0

proc readFrameHeader(r: var Bits; h: Header): FrameHeader =
  template f: untyped = result
  f.setLoopFilterDefaults()
  f.upsampling = 1
  f.groupShift = 1
  f.numPasses = 1
  f.isLast = true
  f.width = h.w
  f.height = h.h
  let numEc = h.ec.len
  f.ecUps = newSeq[int](numEc)
  for i in 0 ..< numEc: f.ecUps[i] = 1
  f.ecBlend = newSeq[BlendInfo](numEc)
  f.xqm = if h.xyb: 3 else: 2
  f.bqm = 2
  let allDefault = r.flag
  if not allDefault:
    f.kind = r.bits(2)
    f.modular = r.flag
    f.flags = r.u64()
    if not h.xyb: f.ycbcr = r.flag
    if f.ycbcr and (f.flags and FlagUseLf) == 0:
      var rh, rv: array[3, int]          # each channel's sampling factor (log2)
      for i in 0 .. 2:
        let m = r.bits(2)
        rh[i] = [0, 1, 1, 0][m]
        rv[i] = [0, 1, 0, 1][m]
      for i in 0 .. 2:
        f.hs[i] = max(rh) - rh[i]
        f.vs[i] = max(rv) - rv[i]
    if (f.flags and FlagUseLf) == 0:
      f.upsampling = r.u32((1, 0), (2, 0), (4, 0), (8, 0))
      for i in 0 ..< numEc:
        f.ecUps[i] = r.u32((1, 0), (2, 0), (4, 0), (8, 0)) shl h.ec[i].dimShift
        if f.ecUps[i] < f.upsampling or f.ecUps[i] > 8: fail("damaged JPEG XL (upsampling)")
    if f.modular: f.groupShift = r.bits(2)
    if not f.modular and h.xyb:
      f.xqm = r.bits(3)
      f.bqm = r.bits(3)
    if f.kind != 2:
      f.numPasses = r.u32((1, 0), (2, 0), (3, 0), (4, 3))
      if f.numPasses != 1:
        let numDs = r.u32((0, 0), (1, 0), (2, 0), (3, 1))
        if numDs > f.numPasses: fail("damaged JPEG XL (passes)")
        for i in 0 ..< f.numPasses - 1: f.shift.add r.bits(2)
        for i in 0 ..< numDs: f.downsample.add r.u32((1, 0), (2, 0), (4, 0), (8, 0))
        for i in 0 ..< numDs: f.lastPass.add r.u32((0, 0), (1, 0), (2, 0), (0, 3))
        for i in 0 ..< numDs:
          if f.lastPass[i] >= f.numPasses: fail("damaged JPEG XL (passes)")
    if f.kind == 1: f.lfLevel = r.u32((1, 0), (2, 0), (3, 0), (4, 0))
    var partial = false
    if f.kind != 1:
      f.custom = r.flag
      if f.custom:
        const enc = [(0, 8), (256, 11), (2304, 14), (18688, 30)]
        if f.kind == 0 or f.kind == 3:
          f.x0 = unpackSigned(uint32(r.u32(enc[0], enc[1], enc[2], enc[3])))
          f.y0 = unpackSigned(uint32(r.u32(enc[0], enc[1], enc[2], enc[3])))
        f.width = r.u32(enc[0], enc[1], enc[2], enc[3])
        f.height = r.u32(enc[0], enc[1], enc[2], enc[3])
        if f.width == 0 or f.height == 0: fail("damaged JPEG XL (frame size)")
        if f.kind == 0 or f.kind == 3:
          partial = f.x0 > 0 or f.y0 > 0 or f.width + f.x0 < h.w or f.height + f.y0 < h.h
    if f.kind == 0 or f.kind == 3:
      f.blend = r.readBlend(numEc, partial)
      for i in 0 ..< numEc: f.ecBlend[i] = r.readBlend(numEc, partial)
      if h.animated:
        f.duration = r.u32((0, 0), (1, 0), (0, 8), (0, 32))
        if h.haveTimecodes: discard r.bits(32)
      f.isLast = r.flag
    else:
      f.isLast = false
    if f.kind != 1 and not f.isLast: f.saveAs = r.u32((0, 0), (1, 0), (2, 0), (3, 0))
    if f.kind != 1:
      if f.canBeReferenced and f.blend.mode == 0 and not partial and (f.kind == 0 or f.kind == 3):
        f.saveBeforeCt = r.flag
      elif f.kind == 2:
        f.saveBeforeCt = r.flag
    else:
      f.saveBeforeCt = true
    r.readName()
    # the restoration filters
    if not r.flag:
      f.gab = r.flag
      if f.gab and r.flag:
        for i in 0 .. 5: f.gabW[i] = r.f16()
        for i in 0 .. 2:
          if abs(1 + (f.gabW[2 * i] + f.gabW[2 * i + 1]) * 4) < 1e-8: fail("damaged JPEG XL (Gaborish)")
      f.epfIters = r.bits(2)
      if f.epfIters > 0:
        if not f.modular and r.flag:
          for i in 0 .. 7: f.epfSharp[i] = r.f16()
        if r.flag:
          for i in 0 .. 2: f.epfScale[i] = r.f16()
          f.epfPass1Zero = r.f16()
          f.epfPass2Zero = r.f16()
        if r.flag:
          if not f.modular: f.epfQuantMul = r.f16()
          f.epfPass0Sigma = r.f16()
          f.epfPass2Sigma = r.f16()
          f.epfBorderSad = r.f16()
        if f.modular:
          f.epfSigmaModular = r.f16()
          if f.epfSigmaModular < 1e-8: fail("damaged JPEG XL (EPF)")
      r.readExtensions()
    r.readExtensions()
  # the sizes that follow
  var w = f.width
  var hh = f.height
  if f.lfLevel > 0:
    w = cdiv(w, 1 shl (3 * f.lfLevel))
    hh = cdiv(hh, 1 shl (3 * f.lfLevel))
    f.width = w
    f.height = hh
  f.sw = cdiv(w, f.upsampling)
  f.sh = cdiv(hh, f.upsampling)
  f.gdim = 128 shl f.groupShift
  let mhs = max(f.hs[0], max(f.hs[1], f.hs[2]))
  let mvs = max(f.vs[0], max(f.vs[1], f.vs[2]))
  f.xblocks = cdiv(f.sw, 8 shl mhs) shl mhs
  f.yblocks = cdiv(f.sh, 8 shl mvs) shl mvs
  f.xgroups = cdiv(f.sw, f.gdim)
  f.numGroups = f.xgroups * cdiv(f.sh, f.gdim)
  f.xlfgroups = cdiv(f.xblocks, f.gdim)
  f.numLfGroups = f.xlfgroups * cdiv(f.yblocks, f.gdim)
  if w.int64 * hh.int64 > (1'i64 shl 30): fail("JPEG XL frame too large")

proc downsamplingBracket(f: FrameHeader; pass: int): (int, int) =
  var maxShift = 2
  var minShift = 3
  var i = 0
  while true:
    for j in 0 ..< f.downsample.len:
      if i == f.lastPass[j]:
        case f.downsample[j]
        of 8: minShift = 3
        of 4: minShift = 2
        of 2: minShift = 1
        else: minShift = 0
    if i == f.numPasses - 1: minShift = 0
    if i == pass: return (minShift, maxShift)
    maxShift = minShift - 1
    inc i

type
  Toc = object
    offsets, sizes: seq[int]     # of each section (in their logical order), from the codestream start

proc readPermutation(r: var Bits; c: Code; rd: var Reader; size, skip: int): seq[int] =
  proc ctxOf(x: int): int = min(addLog2Ceil(x), 7)
  let stop = int(c.hybrid(rd, r, ctxOf(size)))
  if stop > size - skip: fail("damaged JPEG XL (permutation)")
  var lehmer = newSeq[int](stop)
  var prev = 0
  for i in 0 ..< stop:
    lehmer[i] = int(c.hybrid(rd, r, ctxOf(prev)))
    if lehmer[i] >= size - skip - i: fail("damaged JPEG XL (permutation)")
    prev = lehmer[i]
  var rest = newSeq[int]()
  for i in skip ..< size: rest.add i
  for i in 0 ..< skip: result.add i
  for l in lehmer:
    result.add rest[l]
    rest.delete(l)
  result.add rest

proc readToc(r: var Bits; f: FrameHeader): Toc =
  let n = if f.numGroups == 1 and f.numPasses == 1: 1
          else: 2 + f.numLfGroups + f.numGroups * f.numPasses
  if n > 65536 * 4: fail("damaged JPEG XL (too many sections)")
  var perm: seq[int]
  if r.flag:
    let c = readCode(r, 8)
    var rd = c.begin(r)
    perm = readPermutation(r, c, rd, n, 0)
    c.finish(rd)
  r.zeroPad()
  var sizes = newSeq[int](n)
  for i in 0 ..< n: sizes[i] = r.u32((0, 10), (1024, 14), (17408, 22), (4211712, 30))
  r.zeroPad()
  if r.overrun: fail("the JPEG XL file is cut short")
  var offsets = newSeq[int](n)
  var acc = r.base + r.bitPos div 8
  for i in 0 ..< n:
    offsets[i] = acc
    acc += sizes[i]
  if perm.len > 0:
    result.offsets = newSeq[int](n)
    result.sizes = newSeq[int](n)
    for i in 0 ..< n:
      result.offsets[i] = offsets[perm[i]]
      result.sizes[i] = sizes[perm[i]]
  else:
    result.offsets = offsets
    result.sizes = sizes

proc tocEnd(t: Toc): int =
  for i in 0 ..< t.sizes.len: result = max(result, t.offsets[i] + t.sizes[i])

# ---- images in floats ------------------------------------------------------------------------

type
  Plane = object
    w, h: int
    d: seq[float32]
  FImage = object
    w, h: int
    p: seq[Plane]              # three color planes, then the extra channels
  Slot = object
    img: FImage
    beforeCt: bool             # saved before the color transform (what patches use)
    used: bool
  State = object
    hdr: Header
    refs: array[4, Slot]
    lf: array[4, FImage]       # LF frames, by level - 1
    visible, invisible: int    # frames counted as libjxl does (they seed the noise)

proc newPlane(w, h: int): Plane =
  if w < 0 or h < 0 or w.int64 * h.int64 > (1'i64 shl 31): fail("damaged JPEG XL (plane size)")
  Plane(w: w, h: h, d: newSeq[float32](w * h))

proc newPlaneUninit(w, h: int): Plane =
  ## (for planes every sample of which is written before it is read)
  if w < 0 or h < 0 or w.int64 * h.int64 > (1'i64 shl 31): fail("damaged JPEG XL (plane size)")
  Plane(w: w, h: h, d: newSeqUninit[float32](w * h))

proc mirror(x, size: int): int {.inline.} =
  var x = x
  while x < 0 or x >= size:
    if x < 0: x = -x - 1
    else: x = 2 * size - 1 - x
  x

# ---- the frame sections ----------------------------------------------------------------------

type
  Frame = object
    ## What one frame needs while it is decoded.
    fh: FrameHeader
    dcQuant: array[3, float32]
    tree: MATree
    gimg: MImage               # the frame's modular image
    nbColor: int               # color channels in it (0 for VarDCT)
    vd: ref VarDct             # VarDCT state
    patches: seq[Patch]
    splines: Splines
    noiseLut: array[8, float32]
  QSpline = object
    ## One spline as coded: its control points as second differences, then
    ## the X, Y, B and sigma along it as 32 DCT coefficients each.
    ddx, ddy: seq[int32]
    dct: array[4, array[32, int32]]
  Splines = object
    qadj: int32
    sx, sy: seq[int64]         # where each spline starts
    sp: seq[QSpline]
  Patch = object
    slot, rx, ry, w, h: int    # where it comes from
    x, y: int                  # where it goes
    blends: seq[BlendLike]     # color, then each extra channel
  BlendLike = object
    mode, alpha: int
    clamp: bool
  HfOrders = array[13, array[3, seq[uint16]]]   ## coefficient orders: x + y * 256 (wide layout)
  VarDct = object
    globalScale, quantLf: int
    numCtxs, numDcCtx: int
    dcThresh: array[3, seq[int32]]
    qfThresh: seq[int32]
    ctxMap: seq[uint8]
    colorFactor: float32
    baseX, baseB: float32
    xDc, bDc: float32          # LF chroma from luma
    lf: array[3, Plane]        # the LF image (block averages), X Y B
    acs: seq[int8]             # per block: the transform of a varblock's first block, -1 the rest
    qf: seq[int32]
    sharp: seq[uint8]
    lfIdx: seq[uint8]
    ytox, ytob: seq[int8]      # per 64x64 tile
    xtiles: int
    weights: array[17, array[3, seq[float32]]]   # dequantization multipliers (wide layout)
    numHisto: int
    orders: seq[HfOrders]      # per pass
    codes: seq[Code]           # per pass
    coeffs: seq[array[3, seq[int32]]]   # per group, when there are several passes
    planes: array[3, Plane]    # the decoded pixels (X Y B, or Cb Y Cr)

proc sectionIndex(f: FrameHeader; single: bool; kind: int; a = 0; b = 0): int =
  ## kind: 0 LF global, 1 LF group a, 2 HF global, 3 pass a group b.
  if single: return 0
  case kind
  of 0: 0
  of 1: 1 + a
  of 2: 1 + f.numLfGroups
  else: 2 + f.numLfGroups + a * f.numGroups + b

proc decodeModularGroup(fr: var Frame; r: var Bits; x0, y0, size, minShift, maxShift, stream: int) =
  ## The part of the frame's modular channels in one rectangle of pixels.
  let g = addr fr.gimg
  var c = g.nbMeta
  while c < g.ch.len and not (g.ch[c].w > fr.fh.gdim or g.ch[c].h > fr.fh.gdim): inc c
  var sub = MImage(bitDepth: g.bitDepth)
  var map: seq[(int, int, int)]
  while c < g.ch.len:
    let ch = addr g.ch[c]
    let s = min(ch.hshift, ch.vshift)
    if s >= minShift and s <= maxShift:
      let cx = x0 shr ch.hshift
      let cy = y0 shr ch.vshift
      let w = min(size shr ch.hshift, ch.w - cx)
      let h = min(size shr ch.vshift, ch.h - cy)
      if w > 0 and h > 0:
        sub.ch.add newChannel(w, h, ch.hshift, ch.vshift)
        map.add (c, cx, cy)
    inc c
  if sub.ch.len == 0: return
  decodeModular(r, sub, stream, addr fr.tree)
  if sub.ch.len != map.len: fail("damaged JPEG XL (group channels)")
  for k, (ci, cx, cy) in map:
    let s = addr sub.ch[k]
    let d = addr g.ch[ci]
    for y in 0 ..< s.h:
      copyMem(addr d.px[(cy + y) * d.w + cx], addr s.px[y * s.w], s.w * 4)

proc modularToPlanes(fr: var Frame; st: State; img: var FImage) =
  ## The modular channels as samples in floats: color (unless VarDCT) and extra.
  let h = st.hdr
  let g = addr fr.gimg
  var c = 0
  proc intToFloat(v: int32; bits, expBits: int): float32 =
    if bits == 32: return cast[float32](v)
    let expBias = (1 shl (expBits - 1)) - 1
    let signShift = bits - 1
    let mantBits = bits - expBits - 1
    let mantShift = 23 - mantBits
    var f = cast[uint32](v)
    let sign = (f shr signShift) and 1
    f = f and ((1'u32 shl signShift) - 1)
    if f == 0: return (if sign == 1: -0.0'f32 else: 0.0'f32)
    var e = int(f shr mantBits)
    var mant = f and ((1'u32 shl mantBits) - 1)
    if e == (1 shl expBits) - 1:
      return cast[float32]((sign shl 31) or (0xFF'u32 shl 23) or (mant shl mantShift))
    mant = mant shl mantShift
    if e == 0 and expBits < 8:
      while (mant and 0x800000) == 0:
        mant = mant shl 1
        dec e
      inc e
      mant = mant and 0x7FFFFF
    e = e - expBias + 127
    if e < 0: return 0
    cast[float32]((sign shl 31) or (uint32(e) shl 23) or mant)
  if fr.nbColor > 0:
    let gray = fr.nbColor == 1
    for cc in 0 .. 2:
      var cin = cc
      var factor = if g.bitDepth < 32: 1.0 / float((1'u64 shl g.bitDepth) - 1) else: 0.0
      if h.xyb:
        factor = float(fr.dcQuant[cc])
        if cc < 2: cin = 1 - cc
      elif gray: cin = 0
      if cin >= g.ch.len: fail("damaged JPEG XL (channels)")
      let ch = addr g.ch[cin]
      var p = newPlane(ch.w, ch.h)
      if h.xyb and cc == 2:
        let y = addr g.ch[0]
        if y.w != ch.w or y.h != ch.h: fail("damaged JPEG XL (channels)")
        for i in 0 ..< ch.w * ch.h: p.d[i] = float32(float(int64(ch.px[i]) + int64(y.px[i])) * factor)
      elif h.floatSamples and not h.xyb:
        for i in 0 ..< ch.w * ch.h: p.d[i] = intToFloat(ch.px[i], h.bits, h.expBits)
      else:
        for i in 0 ..< ch.w * ch.h: p.d[i] = float32(float(ch.px[i]) * factor)
      img.p[cc] = move p
    c = fr.nbColor
  for e in 0 ..< h.ec.len:
    if c >= g.ch.len: fail("damaged JPEG XL (channels)")
    let ch = addr g.ch[c]
    let info = h.ec[e]
    var p = newPlane(ch.w, ch.h)
    if info.floatSamples:
      for i in 0 ..< ch.w * ch.h: p.d[i] = intToFloat(ch.px[i], info.bits, info.expBits)
    else:
      let factor = 1.0 / float((1'u64 shl info.bits) - 1)
      for i in 0 ..< ch.w * ch.h: p.d[i] = float32(float(ch.px[i]) * factor)
    img.p[3 + e] = move p
    inc c

proc decodeVarDctLfGlobal(fr: var Frame; st: State; r: var Bits)
proc decodeVarDctLfGroup(fr: var Frame; st: State; r: var Bits; g: int)
proc decodeAcMeta(fr: var Frame; st: State; r: var Bits; g: int)
proc decodeVarDctHfGlobal(fr: var Frame; st: State; r: var Bits)
proc decodeVarDctPass(fr: var Frame; st: State; r: var Bits; pass, g: int)
proc finishVarDct(fr: var Frame; st: State; img: var FImage)
proc readPatches(fr: var Frame; st: State; r: var Bits)
proc readSplines(fr: var Frame; st: State; r: var Bits)
proc readNoise(fr: var Frame; r: var Bits)
proc renderStages(fr: var Frame; st: State; img: var FImage)

proc decodeFrame(st: var State; cs: string; r: var Bits; fh: FrameHeader): (FImage, int) =
  ## The frame's pixels before the color transform, at its own size; and
  ## where the codestream goes on.
  let h = st.hdr
  var fr = Frame(fh: fh)
  let toc = readToc(r, fh)
  let single = toc.sizes.len == 1
  var secs = newSeq[Bits](toc.sizes.len)
  for i in 0 ..< toc.sizes.len:
    if toc.offsets[i] + toc.sizes[i] > cs.len: fail("the JPEG XL file is cut short")
    secs[i] = initBits(cs, toc.offsets[i], toc.offsets[i] + toc.sizes[i])
  let next = toc.tocEnd()
  # LF global
  block:
    let r = addr secs[0]
    if (fh.flags and FlagPatches) != 0: fr.readPatches(st, r[])
    if (fh.flags and FlagSplines) != 0: fr.readSplines(st, r[])
    if (fh.flags and FlagNoise) != 0: fr.readNoise(r[])
    fr.dcQuant = [1.0'f32 / 4096, 1.0 / 512, 1.0 / 256]
    if not r[].flag:
      for c in 0 .. 2: fr.dcQuant[c] = r[].f16() / 128
    if not fh.modular: fr.decodeVarDctLfGlobal(st, r[])
    let gray = h.colorSpace == 1 and not fh.ycbcr and not h.xyb
    fr.nbColor = if not fh.modular: 0 elif gray: 1 else: 3
    if r[].flag:
      let limit = min(1 shl 22, 1024 + fh.sw * fh.sh * (fr.nbColor + h.ec.len) div 16)
      let tree = readTree(r[], limit)      # (a local first: see `readCode`)
      fr.tree = tree
    fr.gimg = MImage(bitDepth: h.bits)
    for c in 0 ..< fr.nbColor:
      fr.gimg.ch.add newChannel(cdiv(fh.sw, 1 shl fh.hs[c]), cdiv(fh.sh, 1 shl fh.vs[c]),
                                fh.hs[c], fh.vs[c])
    let lups = ceilLog2(fh.upsampling)
    for e in 0 ..< h.ec.len:
      let s = ceilLog2(fh.ecUps[e]) - lups
      fr.gimg.ch.add newChannel(cdiv(fh.width, fh.ecUps[e]), cdiv(fh.height, fh.ecUps[e]), s, s)
    decodeModular(r[], fr.gimg, 0, addr fr.tree, maxChanSize = fh.gdim, undo = false)
    if r[].overrun: fail("the JPEG XL file is cut short")
  # LF groups
  for g in 0 ..< fh.numLfGroups:
    let r = addr secs[sectionIndex(fh, single, 1, g)]
    if not fh.modular and (fh.flags and FlagUseLf) == 0: fr.decodeVarDctLfGroup(st, r[], g)
    let gx = g mod fh.xlfgroups
    let gy = g div fh.xlfgroups
    let d = fh.gdim * 8
    fr.decodeModularGroup(r[], gx * d, gy * d, d, 3, 1000, 1 + fh.numLfGroups + g)
    if not fh.modular: fr.decodeAcMeta(st, r[], g)
    if r[].overrun: fail("the JPEG XL file is cut short")
  # HF global
  if not fh.modular:
    let r = addr secs[sectionIndex(fh, single, 2)]
    fr.decodeVarDctHfGlobal(st, r[])
  # the passes
  for p in 0 ..< fh.numPasses:
    let (minShift, maxShift) = fh.downsamplingBracket(p)
    for g in 0 ..< fh.numGroups:
      let r = addr secs[sectionIndex(fh, single, 3, p, g)]
      if not fh.modular: fr.decodeVarDctPass(st, r[], p, g)
      let gx = g mod fh.xgroups
      let gy = g div fh.xgroups
      fr.decodeModularGroup(r[], gx * fh.gdim, gy * fh.gdim, fh.gdim, minShift, maxShift,
                            1 + 3 * fh.numLfGroups + 17 + fh.numGroups * p + g)
      if r[].overrun: fail("the JPEG XL file is cut short")
  # the pixels
  fr.gimg.undoTransforms()
  var img = FImage(w: fh.width, h: fh.height)
  img.p.setLen(3 + h.ec.len)
  fr.modularToPlanes(st, img)
  if not fh.modular: fr.finishVarDct(st, img)
  fr.renderStages(st, img)
  (img, next)

# ---- the render stages -----------------------------------------------------------------------

proc cropTo(p: var Plane; w, h: int) =
  if p.w == w and p.h == h: return
  var o = newPlane(w, h)
  for y in 0 ..< min(h, p.h):
    copyMem(addr o.d[y * w], addr p.d[y * p.w], min(w, p.w) * 4)
  p = move o

proc padded(p: Plane; b: int): Plane =
  ## A copy with `b` more samples on every side, mirrored.
  result = newPlane(p.w + 2 * b, p.h + 2 * b)
  let ow = result.w
  for y in 0 ..< result.h:
    let sy = mirror(y - b, p.h)
    copyMem(addr result.d[y * ow + b], unsafeAddr p.d[sy * p.w], p.w * 4)
    for x in 0 ..< b:
      result.d[y * ow + x] = p.d[sy * p.w + mirror(x - b, p.w)]
      result.d[y * ow + b + p.w + x] = p.d[sy * p.w + mirror(p.w + x, p.w)]

proc chromaUpH(p: var Plane) =
  let src = p.padded(1)
  var o = newPlane(p.w * 2, p.h)
  for y in 0 ..< p.h:
    let s = cast[ptr UncheckedArray[float32]](unsafeAddr src.d[(y + 1) * src.w + 1])
    for x in 0 ..< p.w:
      let cur = s[x] * 0.75'f32
      o.d[y * o.w + 2 * x] = cur + 0.25'f32 * s[x - 1]
      o.d[y * o.w + 2 * x + 1] = cur + 0.25'f32 * s[x + 1]
  p = move o

proc chromaUpV(p: var Plane) =
  var o = newPlane(p.w, p.h * 2)
  for y in 0 ..< p.h:
    let t = mirror(y - 1, p.h)
    let b = mirror(y + 1, p.h)
    for x in 0 ..< p.w:
      let cur = p.d[y * p.w + x] * 0.75'f32
      o.d[2 * y * p.w + x] = cur + 0.25'f32 * p.d[t * p.w + x]
      o.d[(2 * y + 1) * p.w + x] = cur + 0.25'f32 * p.d[b * p.w + x]
  p = move o

type
  Ring = object
    ## The original rows y - b .. y + b of a plane being filtered in place,
    ## each with b mirrored samples on either side.
    b, w, h: int
    rows: seq[seq[float32]]
    loaded: int                # rows 0 ..< loaded are in

proc initRing(p: Plane; b: int): Ring =
  result = Ring(b: b, w: p.w, h: p.h)
  result.rows = newSeq[seq[float32]](2 * b + 1)
  for r in result.rows.mitems: r = newSeq[float32](p.w + 2 * b)

proc load(g: var Ring; p: Plane; upto: int) =
  ## Takes the original rows up to `upto` (before they are overwritten).
  while g.loaded <= min(upto, g.h - 1):
    let y = g.loaded
    let row = addr g.rows[y mod g.rows.len]
    copyMem(addr row[][g.b], unsafeAddr p.d[y * p.w], p.w * 4)
    for x in 0 ..< g.b:
      row[][x] = p.d[y * p.w + mirror(x - g.b, p.w)]
      row[][g.b + p.w + x] = p.d[y * p.w + mirror(p.w + x, p.w)]
    inc g.loaded

proc row(g: var Ring; y: int): FBuf {.inline.} =
  ## The original row y (mirrored when outside), from its sample at x = -b.
  cast[FBuf](addr g.rows[mirror(y, g.h) mod g.rows.len][0])

proc gaborish(fr: Frame; img: var FImage) =
  for c in 0 .. 2:
    let w1 = fr.fh.gabW[2 * c]
    let w2 = fr.fh.gabW[2 * c + 1]
    let mul = 1'f32 / (1'f32 + 4'f32 * (w1 + w2))
    let k0 = mul
    let k1 = w1 * mul
    let k2 = w2 * mul
    let w = img.p[c].w
    var ring = initRing(img.p[c], 1)
    for y in 0 ..< img.p[c].h:
      ring.load(img.p[c], y + 1)
      let t = cast[FBuf](addr ring.row(y - 1)[1])
      let m = cast[FBuf](addr ring.row(y)[1])
      let b = cast[FBuf](addr ring.row(y + 1)[1])
      let o = cast[FBuf](addr img.p[c].d[y * w])
      for x in 0 ..< w:
        let side = m[x - 1] + m[x + 1] + t[x] + b[x]
        let corner = t[x - 1] + t[x + 1] + b[x - 1] + b[x + 1]
        o[x] = m[x] * k0 + side * k1 + corner * k2

const
  InvSigmaNum = -1.1715728752538099024'f32
  MinSigma = -3.90524291751269967465540850526868'f32

proc epf(fr: Frame; img: var FImage; sigma: seq[float32]; sbw: int) =
  ## The edge preserving filter; `sigma`: per 8x8 block, kInvSigmaNum / sigma.
  let f = fr.fh
  let w = img.p[0].w
  let h = img.p[0].h
  for c in 1 .. 2:
    if img.p[c].w != w or img.p[c].h != h: fail("damaged JPEG XL (EPF on subsampled channels)")
  let sc = f.epfScale
  var hd: array[3, seq[float32]]       # stage 1: |I(x+1) - I(x)| of rows y-1 .. y+1
  var vd: array[4, seq[float32]]       # stage 1: |I(y+1) - I(y)| of rows y-2 .. y+1
  for k in 0 .. 2: hd[k] = newSeq[float32](w + 4)
  for k in 0 .. 3: vd[k] = newSeq[float32](w + 2)
  for stage in [0, 1, 2]:
    if stage == 0 and f.epfIters < 3: continue
    if stage == 2 and f.epfIters < 2: continue
    let b = if stage == 0: 3 elif stage == 1: 2 else: 1
    let sm = if stage == 0: f.epfPass0Sigma * 1.65'f32 elif stage == 1: 1.65'f32
             else: f.epfPass2Sigma * 1.65'f32
    let bsm = sm * f.epfBorderSad
    var rings: array[3, Ring]
    for c in 0 .. 2: rings[c] = initRing(img.p[c], b)
    var r: array[3, array[7, FBuf]]    # rows y-b .. y+b of each channel (x = 0 at index b)
    for y in 0 ..< h:
      for c in 0 .. 2:
        rings[c].load(img.p[c], y + b)
        for k in -b .. b: r[c][k + b] = cast[FBuf](addr rings[c].row(y + k)[b])
      let border = (y and 7) == 0 or (y and 7) == 7
      let srow = cast[FBuf](unsafeAddr sigma[(y shr 3) * sbw])
      let o0 = cast[FBuf](addr img.p[0].d[y * w])
      let o1 = cast[FBuf](addr img.p[1].d[y * w])
      let o2 = cast[FBuf](addr img.p[2].d[y * w])
      if stage == 1:
        # the differences the 4 sums of absolute differences share
        for k in 0 .. 2:
          let hk = cast[FBuf](addr hd[k][2])
          for x in -2 .. w:
            hk[x] = abs(r[0][k + 1][x + 1] - r[0][k + 1][x]) * sc[0] +
                    abs(r[1][k + 1][x + 1] - r[1][k + 1][x]) * sc[1] +
                    abs(r[2][k + 1][x + 1] - r[2][k + 1][x]) * sc[2]
        for k in 0 .. 3:
          let vk = cast[FBuf](addr vd[k][1])
          for x in -1 .. w:
            vk[x] = abs(r[0][k + 1][x] - r[0][k][x]) * sc[0] +
                    abs(r[1][k + 1][x] - r[1][k][x]) * sc[1] +
                    abs(r[2][k + 1][x] - r[2][k][x]) * sc[2]
      let h0 = cast[FBuf](addr hd[0][2])
      let h1 = cast[FBuf](addr hd[1][2])
      let h2 = cast[FBuf](addr hd[2][2])
      let v0 = cast[FBuf](addr vd[0][1])
      let v1 = cast[FBuf](addr vd[1][1])
      let v2 = cast[FBuf](addr vd[2][1])
      let v3 = cast[FBuf](addr vd[3][1])
      let c0 = r[0][b]
      let c1 = r[1][b]
      let c2 = r[2][b]
      for x in 0 ..< w:
        let bs = srow[x shr 3]
        if bs < MinSigma:
          o0[x] = c0[x]
          o1[x] = c1[x]
          o2[x] = c2[x]
          continue
        let ix = x and 7
        let invSigma = bs * (if border or ix == 0 or ix == 7: bsm else: sm)
        var X = c0[x]
        var Y = c1[x]
        var B = c2[x]
        var wsum = 1'f32
        template add(row: int; xx: int; sad: float32) =
          let wt = max(0'f32, 1'f32 + sad * invSigma)
          wsum += wt
          X += wt * r[0][row][xx]
          Y += wt * r[1][row][xx]
          B += wt * r[2][row][xx]
        case stage
        of 1:
          add(1, x, v0[x] + v1[x] + v2[x] + v1[x - 1] + v1[x + 1])            # up
          add(2, x - 1, h1[x - 2] + h1[x - 1] + h1[x] + h0[x - 1] + h2[x - 1])  # left
          add(2, x + 1, h1[x - 1] + h1[x] + h1[x + 1] + h0[x] + h2[x])          # right
          add(3, x, v1[x] + v2[x] + v3[x] + v2[x - 1] + v2[x + 1])            # down
        of 2:
          for (row, xx) in [(0, x), (1, x - 1), (1, x + 1), (2, x)]:
            let sad = abs(r[0][row][xx] - c0[x]) * sc[0] + abs(r[1][row][xx] - c1[x]) * sc[1] +
                      abs(r[2][row][xx] - c2[x]) * sc[2]
            add(row, xx, sad)
        else:
          for (dy, dx) in [(-2, 0), (-1, -1), (-1, 0), (-1, 1), (0, -2), (0, -1),
                           (0, 1), (0, 2), (1, -1), (1, 0), (1, 1), (2, 0)]:
            var sad = 0'f32
            for ch in 0 .. 2:
              var s = 0'f32
              for (oy, ox) in [(0, 0), (-1, 0), (0, -1), (1, 0), (0, 1)]:
                s += abs(r[ch][b + oy][x + ox] - r[ch][b + dy + oy][x + dx + ox])
              sad += s * sc[ch]
            add(b + dy, x + dx, sad)
        let inv = 1'f32 / wsum
        o0[x] = X * inv
        o1[x] = Y * inv
        o2[x] = B * inv

proc upsample(p: var Plane; n: int; weights: seq[float32]) =
  ## 2x, 4x or 8x as the image's upsampling weights say.
  let hh = n div 2
  var kernel = newSeq[float32](n * n * 25)
  for ky in 0 ..< hh:
    for kx in 0 ..< hh:
      let o0 = (ky * n + kx) * 25
      let o1 = (ky * n + (n - 1 - kx)) * 25
      let o2 = ((n - 1 - ky) * n + kx) * 25
      let o3 = ((n - 1 - ky) * n + (n - 1 - kx)) * 25
      for py in 0 ..< 5:
        for px in 0 ..< 5:
          let j = 5 * ky + py
          let i = 5 * kx + px
          let my = min(i, j)
          let mx = max(i, j)
          let wv = weights[5 * hh * my - my * (my - 1) div 2 + mx - my]
          kernel[o0 + py * 5 + px] = wv
          kernel[o1 + py * 5 + (4 - px)] = wv
          kernel[o2 + (4 - py) * 5 + px] = wv
          kernel[o3 + (4 - py) * 5 + (4 - px)] = wv
  let src = p.padded(2)
  let sw = src.w
  var o = newPlane(p.w * n, p.h * n)
  var win: array[25, float32]
  for y in 0 ..< p.h:
    for x in 0 ..< p.w:
      var lo = Inf.float32
      var hi = -Inf.float32
      for iy in 0 .. 4:
        for ix in 0 .. 4:
          let v = src.d[(y + iy) * sw + x + ix]
          win[iy * 5 + ix] = v
          lo = min(lo, v)
          hi = max(hi, v)
      for oy in 0 ..< n:
        for ox in 0 ..< n:
          let k = (oy * n + ox) * 25
          var acc = 0'f32
          for i in 0 .. 24: acc += win[i] * kernel[k + i]
          o.d[(y * n + oy) * o.w + x * n + ox] = max(lo, min(hi, acc))
  p = move o

proc applyPatches(fr: var Frame; st: State; img: var FImage)
proc drawSplines(fr: var Frame; st: State; img: var FImage)
proc addNoise(fr: var Frame; st: State; img: var FImage)
proc epfSigma(fr: Frame): (seq[float32], int)

proc renderStages(fr: var Frame; st: State; img: var FImage) =
  let f = fr.fh
  let h = st.hdr
  # the color planes at the samples' size
  for c in 0 .. 2:
    if img.p[c].d.len == 0: fail("damaged JPEG XL (no color)")
    img.p[c].cropTo(cdiv(f.sw, 1 shl f.hs[c]), cdiv(f.sh, 1 shl f.vs[c]))
  for c in 0 .. 2:
    if f.hs[c] > 0:
      img.p[c].chromaUpH()
      img.p[c].cropTo(f.sw, img.p[c].h)
    if f.vs[c] > 0:
      img.p[c].chromaUpV()
      img.p[c].cropTo(img.p[c].w, f.sh)
  if f.gab: fr.gaborish(img)
  if f.epfIters > 0:
    let (sigma, sbw) = fr.epfSigma()
    fr.epf(img, sigma, sbw)
  var late = f.upsampling != 1
  for e in f.ecUps:
    if e != f.upsampling: late = false
  if not late:
    for e in 0 ..< h.ec.len:
      if f.ecUps[e] != 1:
        let n = f.ecUps[e]
        img.p[3 + e].upsample(n, if n == 2: h.up2 elif n == 4: h.up4 else: h.up8)
        img.p[3 + e].cropTo(f.width, f.height)
  if (f.flags and FlagPatches) != 0: fr.applyPatches(st, img)
  if (f.flags and FlagSplines) != 0: fr.drawSplines(st, img)
  if f.upsampling != 1:
    let n = f.upsampling
    let ws = if n == 2: h.up2 elif n == 4: h.up4 else: h.up8
    for c in 0 ..< (if late: 3 + h.ec.len else: 3):
      img.p[c].upsample(n, ws)
  for c in 0 ..< img.p.len: img.p[c].cropTo(f.width, f.height)
  if (f.flags and FlagNoise) != 0: fr.addNoise(st, img)

# ---- colors ----------------------------------------------------------------------------------

const SrgbLutSize = 4096

let srgbLut = block:
  # sRGB encoding of v = u * u (u in 0..1), so that small values have room
  var t = newSeq[float32](SrgbLutSize + 2)
  for i in 0 .. SrgbLutSize + 1:
    let u = min(1.0, float(i) / SrgbLutSize)
    let v = u * u
    t[i] = float32(if v <= 0.0031308: 12.92 * v else: 1.055 * pow(v, 1 / 2.4) - 0.055)
  t

proc srgbEncode(v: float32): float32 {.inline.} =
  if v <= 0: return (if v < 0: -srgbEncode(-v) else: 0)
  if v >= 1: return float32(1.055 * pow(float(v), 1 / 2.4) - 0.055)
  let u = sqrt(v) * SrgbLutSize
  let i = int(u)
  let f = u - float32(i)
  srgbLut[i] + (srgbLut[i + 1] - srgbLut[i]) * f

proc toOutputColors(st: State; f: FrameHeader; img: var FImage) =
  ## From the frame's color space to the pictures' (sRGB for XYB).
  let h = st.hdr
  let n = img.p[0].d.len
  let p0 = cast[ptr UncheckedArray[float32]](addr img.p[0].d[0])
  let p1 = cast[ptr UncheckedArray[float32]](addr img.p[1].d[0])
  let p2 = cast[ptr UncheckedArray[float32]](addr img.p[2].d[0])
  if h.xyb:
    var m: array[9, float32]
    let scale = 255'f32 / h.intensityTarget
    for i in 0 .. 8: m[i] = h.invMat[i] * scale
    var cb: array[3, float32]
    for i in 0 .. 2: cb[i] = float32(cbrt(float(h.opsinBias[i])))
    let bias = h.opsinBias
    let gray = h.colorSpace == 1
    for i in 0 ..< n:
      let x = p0[i]
      let y = p1[i]
      let b = p2[i]
      let gr = y + x - cb[0]
      let gg = y - x - cb[1]
      let gb = b - cb[2]
      let mr = gr * gr * gr + bias[0]
      let mg = gg * gg * gg + bias[1]
      let mb = gb * gb * gb + bias[2]
      var r = m[0] * mr + m[1] * mg + m[2] * mb
      var g = m[3] * mr + m[4] * mg + m[5] * mb
      var bb = m[6] * mr + m[7] * mg + m[8] * mb
      if gray:
        let l = 0.2126'f32 * r + 0.7152'f32 * g + 0.0722'f32 * bb
        r = l
        g = l
        bb = l
      p0[i] = srgbEncode(r)
      p1[i] = srgbEncode(g)
      p2[i] = srgbEncode(bb)
  elif f.ycbcr:
    for i in 0 ..< n:
      let y = p1[i] + 128'f32 / 255
      let cb = p0[i]
      let cr = p2[i]
      p0[i] = y + 1.402'f32 * cr
      p1[i] = y + (-0.114'f32 * 1.772'f32 / 0.587'f32) * cb + (-0.299'f32 * 1.402'f32 / 0.587'f32) * cr
      p2[i] = y + 1.772'f32 * cb

type
  PBlend = BlendLike
    ## How a layer goes over another (libjxl's PatchBlending): 0 keep, 1 replace,
    ## 2 add, 3 multiply, 4 blend above, 5 blend below, 6 alpha-weighted add
    ## above, 7 below.
  Rows = seq[ptr UncheckedArray[float32]]

proc toPBlend(b: BlendInfo): PBlend =
  PBlend(mode: [1, 2, 4, 6, 3][b.mode], alpha: b.alpha, clamp: b.clamp)

proc performBlending(bg, fg, outp: Rows; n: int; color: PBlend; ec: seq[PBlend]; h: Header) =
  ## libjxl's PerformBlending over n samples of each row (bg under, fg over).
  let numEc = h.ec.len
  var hasAlpha = false
  for e in h.ec:
    if e.kind == 0: hasAlpha = true
  var tmp = newSeq[seq[float32]](3 + numEc)
  for c in 0 ..< 3 + numEc: tmp[c] = newSeq[float32](n)
  proc cl(v: float32): float32 {.inline.} = max(0'f32, min(1'f32, v))
  proc alphaBlend(bgv, bga, fgv, fga: float32; same, prem, clamp: bool): float32 {.inline.} =
    let fa = if clamp: cl(fga) else: fga
    if same: 1 - (1 - fa) * (1 - bga)
    elif prem: fgv + bgv * (1 - fa)
    else:
      let na = 1 - (1 - fa) * (1 - bga)
      if na > 0: (fgv * fa + bgv * bga * (1 - fa)) / na else: 0
  for i in 0 ..< numEc:
    let e = ec[i]
    let o = 3 + i
    let a = 3 + e.alpha
    let prem = e.alpha < numEc and h.ec[e.alpha].associated
    for x in 0 ..< n:
      tmp[o][x] = case e.mode
        of 2: bg[o][x] + fg[o][x]
        of 4: alphaBlend(bg[o][x], bg[a][x], fg[o][x], fg[a][x], o == a, prem, e.clamp)
        of 5: alphaBlend(fg[o][x], fg[a][x], bg[o][x], bg[a][x], o == a, prem, e.clamp)
        of 6:
          if o == a: bg[o][x]
          else: bg[o][x] + fg[o][x] * (if e.clamp: cl(fg[a][x]) else: fg[a][x])
        of 7:
          if o == a: fg[o][x]
          else: fg[o][x] + bg[o][x] * (if e.clamp: cl(bg[a][x]) else: bg[a][x])
        of 3: bg[o][x] * (if e.clamp: cl(fg[o][x]) else: fg[o][x])
        of 1: fg[o][x]
        else: bg[o][x]
  let a = 3 + color.alpha
  let prem = color.alpha < numEc and h.ec[color.alpha].associated
  template weightedAdd(bottom, top: Rows) =
    for x in 0 ..< n:
      let ta = if color.clamp: cl(top[a][x]) else: top[a][x]
      for c in 0 .. 2: tmp[c][x] = bottom[c][x] + top[c][x] * ta
  template blendWeighted(bottom, top: Rows) =
    for x in 0 ..< n:
      let fa = if color.clamp: cl(top[a][x]) else: top[a][x]
      let ba = bottom[a][x]
      let na = 1 - (1 - fa) * (1 - ba)
      if prem:
        for c in 0 .. 2: tmp[c][x] = top[c][x] + bottom[c][x] * (1 - fa)
      else:
        let rna = if na > 0: 1 / na else: 0
        for c in 0 .. 2: tmp[c][x] = (top[c][x] * fa + bottom[c][x] * ba * (1 - fa)) * rna
      tmp[a][x] = na
  template copyFrom(src: Rows) =
    for c in 0 .. 2:
      for x in 0 ..< n: tmp[c][x] = src[c][x]
  case color.mode
  of 2:
    for c in 0 .. 2:
      for x in 0 ..< n: tmp[c][x] = bg[c][x] + fg[c][x]
  of 6:
    if hasAlpha: weightedAdd(bg, fg)
    else:
      for c in 0 .. 2:
        for x in 0 ..< n: tmp[c][x] = bg[c][x] + fg[c][x]
  of 7:
    if hasAlpha: weightedAdd(fg, bg)
    else:
      for c in 0 .. 2:
        for x in 0 ..< n: tmp[c][x] = bg[c][x] + fg[c][x]
  of 4:
    if hasAlpha: blendWeighted(bg, fg)
    else: copyFrom(fg)
  of 5:
    if hasAlpha: blendWeighted(fg, bg)
    else: copyFrom(fg)
  of 3:
    for c in 0 .. 2:
      for x in 0 ..< n: tmp[c][x] = bg[c][x] * (if color.clamp: cl(fg[c][x]) else: fg[c][x])
  of 1: copyFrom(fg)
  else: copyFrom(bg)
  for c in 0 ..< 3 + numEc:
    for x in 0 ..< n: outp[c][x] = tmp[c][x]

proc composite(st: State; f: FrameHeader; img: FImage): FImage =
  ## The frame on the canvas: blended over the references its blending names.
  let h = st.hdr
  let numEc = h.ec.len
  result = FImage(w: h.w, h: h.h)
  result.p.setLen(3 + numEc)
  # the background
  for c in 0 ..< 3 + numEc:
    let src = if c < 3: f.blend.source else: f.ecBlend[c - 3].source
    let s = addr st.refs[src]
    if s.used and s.img.w >= h.w and s.img.h >= h.h and c < s.img.p.len and s.img.p[c].d.len > 0:
      var p = newPlane(h.w, h.h)
      for y in 0 ..< h.h:
        copyMem(addr p.d[y * h.w], unsafeAddr s.img.p[c].d[y * s.img.p[c].w], h.w * 4)
      result.p[c] = move p
    else:
      result.p[c] = newPlane(h.w, h.h)
  # the frame over it
  let x0 = max(0, f.x0)
  let x1 = min(h.w, f.x0 + img.w)
  if x1 <= x0: return
  var bg = newSeq[ptr UncheckedArray[float32]](3 + numEc)
  var fg = newSeq[ptr UncheckedArray[float32]](3 + numEc)
  var row = newSeq[seq[float32]](3 + numEc)
  var ecb: seq[PBlend]
  for e in f.ecBlend: ecb.add e.toPBlend
  for c in 0 ..< 3 + numEc: row[c] = newSeq[float32](x1 - x0)
  for y in max(0, f.y0) ..< min(h.h, f.y0 + img.h):
    let fy = y - f.y0
    for c in 0 ..< 3 + numEc:
      bg[c] = cast[ptr UncheckedArray[float32]](addr result.p[c].d[y * h.w + x0])
      copyMem(addr row[c][0], unsafeAddr img.p[c].d[fy * img.w + x0 - f.x0], (x1 - x0) * 4)
      fg[c] = cast[ptr UncheckedArray[float32]](addr row[c][0])
    performBlending(bg, fg, bg, x1 - x0, f.blend.toPBlend, ecb, h)

proc needsBlending(f: FrameHeader): bool =
  if not (f.kind == 0 or f.kind == 3): return false
  var replaceAll = f.blend.mode == 0
  for e in f.ecBlend:
    if e.mode != 0: replaceAll = false
  not (not f.custom and replaceAll)

proc copyImage(a: FImage): FImage = a

type Shown = object
  img: FImage
  durationTicks: int

proc decodeAll(data: string; first: bool; info: var Header): seq[Shown] =
  ## The frames as they are shown (all of them, or just the first).
  let cs = codestream(data)
  var st: State
  var r = initBits(cs)
  let hdr = readHeader(r)                 # (a local first: see `readCode`)
  st.hdr = hdr
  info = st.hdr
  if st.hdr.wantIcc: r.skipIcc()
  r.zeroPad()
  if st.hdr.havePreview:
    var ph = st.hdr
    ph.w = st.hdr.previewW
    ph.h = st.hdr.previewH
    let fh = readFrameHeader(r, ph)
    let toc = readToc(r, fh)
    r = initBits(cs, toc.tocEnd())
  var pos = r.base + r.bitPos div 8
  var frames = 0
  while true:
    if pos >= cs.len: fail("the JPEG XL file is cut short (no last frame)")
    r = initBits(cs, pos)
    let fh = readFrameHeader(r, st.hdr)
    inc frames
    if frames > 1_000_000: fail("damaged JPEG XL (too many frames)")
    if (fh.isLast or fh.duration > 0) and (fh.kind == 0 or fh.kind == 3):
      inc st.visible
      st.invisible = 0
    else:
      inc st.invisible
    var (img, next) = decodeFrame(st, cs, r, fh)
    pos = next
    if fh.lfLevel > 0:
      st.lf[fh.lfLevel - 1] = move img
      continue
    if fh.canBeReferenced and fh.saveBeforeCt:
      st.refs[fh.saveAs] = Slot(img: img, beforeCt: true, used: true)
    if fh.kind == 2 and fh.saveBeforeCt: continue
    st.toOutputColors(fh, img)
    var canvas: FImage
    if needsBlending(fh): canvas = st.composite(fh, img)
    else: canvas = move img
    if fh.canBeReferenced and not fh.saveBeforeCt:
      st.refs[fh.saveAs] = Slot(img: canvas, beforeCt: false, used: true)
    if fh.kind == 2: continue
    if fh.isLast or fh.duration > 0:
      result.add Shown(img: canvas, durationTicks: fh.duration)
      if first: return
    if fh.isLast: return

proc orient(w, h, orientation: int; x, y: int): (int, int) {.inline.} =
  ## Where the stored pixel (x, y) goes in the shown picture.
  case orientation
  of 2: (w - 1 - x, y)
  of 3: (w - 1 - x, h - 1 - y)
  of 4: (x, h - 1 - y)
  of 5: (y, x)
  of 6: (h - 1 - y, x)
  of 7: (h - 1 - y, w - 1 - x)
  of 8: (y, w - 1 - x)
  else: (x, y)

proc alphaIndex(h: Header): int =
  result = -1
  for i, e in h.ec:
    if e.kind == 0: return i

const Dither = [   # libjxl's 32x32 blue noise, added to 8-bit samples as it writes them
  -0.26057'f32, 0.32619, 0.21039, -0.03281, -0.10616, 0.16792, 0.43042, -0.48061, -0.00965, -0.31075, 0.24899, -0.35322, -0.02509, -0.25285, 0.02895, 0.10230, -0.28373, -0.00193, 0.23355, 0.43428, -0.23741, 0.18336, -0.31847, -0.11002, -0.36094, 0.26057, -0.19108, -0.29531, 0.40726, -0.09458, 0.11002, -0.48833,
  0.16020, -0.35708, -0.18336, 0.36094, -0.28373, -0.34550, -0.20267, 0.07914, 0.35708, -0.41498, 0.47675, -0.21811, -0.12546, 0.44200, -0.41884, -0.17178, 0.39954, 0.33778, -0.33778, 0.04053, -0.46517, 0.27215, -0.16792, 0.39182, 0.20653, -0.43814, -0.02895, 0.17950, -0.41498, 0.01737, 0.24899, 0.49219,
  -0.00965, 0.08300, 0.41112, -0.46903, 0.04053, 0.47289, 0.26057, -0.05983, -0.13704, 0.14862, 0.03281, 0.29531, -0.45744, 0.22583, 0.14862, -0.09072, -0.37638, 0.19881, -0.14476, 0.14476, -0.09072, 0.48447, -0.39954, 0.06369, -0.05983, -0.26829, 0.43428, -0.12546, 0.28759, -0.22969, -0.32619, -0.15248,
  -0.42270, 0.23741, -0.23355, -0.11774, 0.18722, 0.11388, -0.43814, -0.24899, 0.41884, 0.21039, -0.28373, -0.06756, 0.07914, 0.36480, -0.31075, 0.30303, -0.03281, 0.07142, -0.42656, 0.38024, -0.27987, 0.00579, 0.12546, -0.22197, 0.29917, 0.36866, 0.13704, -0.47289, 0.09072, 0.35708, -0.04825, 0.38796,
  -0.28759, -0.07142, 0.44200, 0.27601, -0.38024, -0.16020, -0.01737, 0.30303, -0.33006, -0.40340, -0.16792, 0.40726, -0.36480, -0.00579, -0.19108, 0.41498, -0.26443, 0.46903, -0.21811, 0.28759, -0.04053, 0.22197, 0.34550, -0.44972, -0.14476, -0.34164, 0.04053, -0.19494, 0.45358, -0.37252, 0.21425, 0.05597,
  0.31075, 0.14090, -0.33778, 0.00579, 0.34550, -0.29917, 0.38796, 0.13704, 0.05983, -0.10230, 0.34164, 0.10616, -0.23741, 0.19494, -0.47675, 0.04439, -0.39568, 0.24127, 0.10616, -0.49219, -0.17950, -0.36094, -0.30303, 0.45744, -0.01351, 0.24513, -0.39182, -0.07528, 0.18722, -0.26057, -0.11002, -0.45358,
  0.46903, -0.17178, -0.41112, 0.07528, -0.09458, 0.21811, -0.20267, -0.48833, 0.44972, 0.00965, 0.24127, -0.42656, 0.48447, -0.11774, 0.26443, 0.14090, -0.15634, -0.07142, -0.32233, 0.36094, 0.42270, 0.19108, 0.07142, -0.11002, 0.15634, 0.38024, -0.28759, 0.27987, -0.00193, 0.33006, 0.11388, -0.21039,
  0.02123, 0.17950, 0.38024, -0.24127, -0.44586, 0.48833, -0.03667, 0.26829, -0.36866, -0.22583, 0.17178, -0.30689, 0.29145, -0.04825, -0.35322, 0.43042, 0.34936, 0.00193, 0.16792, -0.12932, 0.03667, -0.06756, 0.31847, -0.40726, -0.24513, 0.09458, -0.17564, 0.47675, -0.43042, -0.32233, 0.40340, 0.26057,
  -0.47675, -0.12160, -0.04825, 0.28759, 0.10230, 0.15634, -0.14862, -0.27601, 0.36094, -0.12932, -0.05983, -0.45358, -0.17950, 0.01737, 0.09458, -0.29145, -0.22969, -0.43428, 0.45744, -0.38796, -0.27601, -0.21039, -0.46131, 0.22969, 0.41112, -0.05211, -0.48061, 0.16406, 0.05211, -0.14862, -0.03281, -0.36866,
  -0.27215, 0.34164, -0.31075, 0.42656, -0.38410, -0.32619, 0.02895, 0.19881, 0.08300, 0.42270, 0.31461, 0.13318, 0.45744, 0.37638, -0.40726, 0.31847, -0.08686, 0.21425, 0.29917, 0.07914, 0.26829, 0.13704, 0.48447, -0.15248, 0.02509, -0.34936, 0.34936, -0.10230, 0.42656, -0.23741, 0.22583, 0.09072,
  0.44972, 0.20267, 0.04825, -0.21425, 0.24513, -0.07142, 0.39954, -0.46131, -0.39568, -0.01351, -0.33392, 0.05597, -0.26443, 0.22197, -0.20653, 0.15248, 0.04439, -0.46517, -0.16406, -0.04439, -0.34936, 0.37252, -0.01351, -0.30689, 0.29917, 0.20653, -0.26829, 0.26443, 0.13318, -0.39954, 0.30303, -0.08686,
  -0.42656, 0.12932, -0.14476, -0.46903, -0.00579, 0.34936, -0.18722, 0.28373, -0.23741, 0.22969, -0.16020, -0.38024, -0.08300, -0.48447, -0.02123, -0.14862, 0.48061, -0.31847, 0.39568, -0.24899, 0.18722, -0.41884, 0.10230, -0.08300, -0.38796, 0.06369, -0.19881, -0.44972, 0.00579, -0.33392, 0.37252, -0.19108,
  -0.02509, -0.35708, 0.32619, 0.46517, 0.17178, -0.28373, 0.10616, 0.47675, -0.09458, 0.15248, 0.43428, 0.35322, 0.17564, 0.27215, 0.41112, -0.36480, 0.24899, 0.11774, 0.01351, 0.33006, -0.11388, -0.18336, 0.41884, -0.23355, 0.16406, 0.46131, 0.38410, -0.04825, -0.15634, 0.49219, 0.17564, 0.03667,
  0.40726, 0.23355, -0.25285, -0.08300, -0.41112, -0.12160, -0.35708, 0.05211, -0.41884, -0.29531, 0.02123, -0.21425, 0.09844, -0.30689, -0.11388, 0.34550, -0.26443, -0.07142, -0.39954, 0.44586, 0.05983, -0.48833, 0.24127, 0.34936, -0.44200, -0.12546, 0.12160, -0.30303, 0.27215, 0.07528, -0.48447, -0.29145,
  0.28373, -0.17564, 0.09458, 0.02123, 0.30689, 0.41884, 0.20653, -0.03667, 0.32233, 0.25671, -0.45744, -0.05597, 0.46517, -0.41498, 0.00965, 0.07142, -0.44586, 0.16406, -0.20653, 0.21811, -0.29917, 0.28759, -0.05597, 0.03281, -0.32619, -0.00965, 0.31847, -0.37252, 0.18722, -0.11002, -0.22969, -0.06369,
  -0.39568, 0.36866, -0.45744, -0.31847, 0.14476, -0.22583, -0.49219, 0.37638, -0.19494, -0.13318, 0.39182, -0.35322, 0.29531, -0.24127, 0.21039, -0.18722, 0.45358, 0.31461, -0.13318, -0.01737, -0.36094, 0.12932, -0.25671, 0.43814, -0.16792, 0.23355, -0.22197, 0.44972, -0.42270, 0.33392, 0.42656, 0.11774,
  -0.13318, 0.19494, -0.03667, 0.44972, 0.24513, -0.15248, 0.08300, -0.33006, 0.00579, 0.12546, 0.19494, 0.05983, -0.15634, 0.14476, 0.36480, -0.04053, -0.33006, 0.25671, -0.46903, 0.37252, 0.48833, -0.09458, -0.41112, 0.19108, 0.08686, -0.46903, -0.07528, 0.04053, -0.26829, -0.02895, 0.22197, -0.34164,
  0.47289, -0.21811, 0.06756, -0.38410, -0.27987, -0.06369, 0.27987, 0.43814, -0.25671, -0.39182, 0.49219, -0.27601, -0.07914, -0.48061, 0.42656, -0.38410, 0.11002, 0.03667, -0.27215, 0.15634, 0.07528, -0.22197, 0.33006, 0.38410, -0.34936, 0.27987, 0.15248, 0.40340, 0.09844, -0.16406, -0.46131, 0.03281,
  -0.29531, 0.31461, -0.10616, 0.39954, 0.01351, 0.33778, -0.43814, 0.17178, -0.08686, 0.23741, -0.44586, 0.33778, -0.00193, -0.31461, 0.23741, -0.12932, -0.22583, -0.06756, 0.40340, -0.16792, -0.43428, 0.01351, -0.14476, -0.04053, -0.29145, 0.46517, -0.13704, -0.39182, -0.32233, 0.29531, 0.38410, 0.16020,
  -0.44200, 0.26443, 0.12546, -0.42270, 0.21425, -0.19881, -0.35708, 0.04825, 0.36480, -0.02895, -0.21425, 0.09072, 0.41498, 0.18336, 0.04439, 0.29917, 0.47675, -0.40340, 0.27601, -0.31461, 0.31075, 0.17564, 0.24899, -0.45744, 0.05597, -0.19494, 0.00193, 0.36094, 0.24127, -0.09844, -0.24513, -0.00965,
  -0.17564, -0.05597, -0.34550, -0.24899, 0.48061, 0.15248, -0.11388, 0.45358, -0.16406, -0.32233, 0.31461, -0.11774, -0.36866, -0.18722, -0.25671, -0.44200, 0.13318, -0.02123, 0.19881, -0.10616, 0.43042, -0.36866, -0.24899, 0.41112, 0.11002, 0.21425, -0.25671, -0.47675, -0.04439, 0.13704, -0.37252, 0.43814,
  0.19108, 0.03667, 0.35708, -0.14090, 0.08300, -0.02123, -0.30303, -0.48061, 0.11774, 0.20267, -0.43042, 0.25285, 0.14090, -0.04439, 0.38796, 0.34550, -0.34164, -0.19494, 0.05983, -0.48447, 0.09844, -0.00579, -0.07914, 0.33778, -0.41498, -0.10230, 0.30689, 0.17178, 0.48833, -0.20267, 0.07914, 0.33392,
  -0.48833, -0.30689, 0.41498, 0.22969, -0.44586, 0.32233, 0.25285, 0.39182, -0.23355, 0.01737, 0.42270, -0.27987, 0.46903, -0.47289, 0.02123, -0.09072, 0.21811, 0.44586, -0.25285, 0.36480, -0.29145, 0.47289, -0.18722, 0.14476, -0.31461, 0.43814, -0.36094, 0.04439, -0.29917, -0.41884, 0.25285, -0.11774,
  0.46131, 0.11388, -0.21039, -0.07528, -0.38024, -0.26057, 0.06369, -0.05983, 0.29145, -0.40340, -0.09072, 0.06756, -0.16020, 0.27601, -0.31075, 0.10616, -0.14090, -0.43042, 0.25671, -0.05211, -0.13318, 0.23355, -0.44972, 0.02895, 0.26829, -0.02895, -0.17950, 0.37252, -0.13704, 0.40726, 0.01351, -0.26443,
  -0.03281, -0.40340, 0.27987, 0.17564, 0.02509, 0.44200, -0.15248, -0.34550, 0.14862, -0.19881, -0.01351, 0.36866, -0.38796, 0.19494, -0.22197, 0.32619, -0.37638, 0.00193, 0.30689, 0.12160, -0.39182, 0.16792, -0.34550, 0.39954, -0.23355, 0.09072, -0.43428, 0.22969, -0.06369, 0.12546, -0.35322, 0.30689,
  -0.09844, 0.06756, 0.38410, -0.33392, -0.18336, 0.35322, 0.21039, -0.42270, 0.48833, 0.33006, 0.21811, -0.33392, 0.12932, -0.05211, 0.39568, 0.04825, 0.48061, 0.17950, -0.31847, -0.21811, 0.38024, 0.05211, 0.32233, -0.06756, -0.12546, 0.46131, 0.16020, -0.25285, 0.29531, -0.44972, 0.17950, -0.16406,
  0.22583, -0.46131, -0.27601, -0.00579, 0.12932, -0.47289, -0.09844, 0.10230, -0.28759, -0.12160, -0.49219, -0.24127, 0.44586, -0.11388, -0.45358, -0.27215, -0.17178, -0.07528, -0.47675, 0.43042, -0.02509, -0.27215, -0.19108, 0.19881, -0.49219, -0.37252, 0.33392, -0.00193, -0.33006, -0.20267, 0.48061, 0.34164,
  -0.22969, 0.42270, -0.12160, 0.31075, 0.46903, -0.22583, 0.27215, -0.02509, 0.03281, 0.40340, 0.25671, 0.08686, 0.00965, 0.29145, -0.41112, 0.14090, 0.24513, 0.34164, 0.08686, -0.14862, 0.27601, -0.42656, 0.48447, 0.09844, 0.26443, -0.27987, 0.05597, -0.10230, 0.43428, 0.08686, 0.02895, -0.38024,
  0.15634, 0.09458, -0.36480, 0.18336, -0.05211, -0.40726, 0.36866, -0.33778, -0.19881, 0.16020, -0.37638, -0.16020, -0.29917, 0.20267, 0.41884, -0.01737, -0.34936, -0.24127, 0.02509, 0.20653, -0.36480, -0.08686, 0.01737, -0.33778, 0.41498, -0.03667, 0.37638, -0.17178, -0.47289, 0.26829, -0.28759, -0.05597,
  0.35708, 0.00193, 0.25285, -0.15634, -0.30303, 0.06369, 0.22197, 0.45358, -0.43814, 0.30303, -0.04053, 0.46517, 0.35322, -0.21039, 0.06756, -0.14090, 0.37638, -0.43042, 0.45744, -0.29531, 0.39568, 0.14862, 0.23741, -0.13704, -0.21425, 0.16406, -0.40726, 0.22583, 0.13318, 0.38796, -0.12932, -0.43428,
  -0.31461, -0.20653, 0.46131, -0.45358, 0.39568, -0.24513, -0.14090, 0.11002, -0.08300, -0.26829, 0.05211, -0.46517, -0.09844, -0.39568, -0.32619, -0.06369, 0.16792, 0.28373, 0.11388, -0.04439, -0.18336, -0.44200, 0.35322, -0.26057, -0.46517, 0.31075, -0.07914, -0.34164, -0.24513, -0.02123, 0.19108, 0.44200,
  0.04825, -0.07914, -0.39954, 0.12160, 0.29145, 0.00965, -0.37638, 0.32233, 0.20267, -0.17564, 0.39182, 0.12160, 0.18336, 0.32619, 0.26057, 0.49219, -0.48447, -0.20653, -0.10616, -0.38796, 0.31847, 0.07528, -0.01737, 0.44586, 0.11774, 0.02509, 0.47289, 0.07142, 0.33392, -0.38410, -0.17950, 0.28373]

proc toBitmap(h: Header; img: FImage): Bitmap =
  ## 8 bits a sample, dithered as libjxl writes them; straight alpha; oriented.
  let w = img.w
  let hh = img.h
  let (ow, oh) = if h.orientation >= 5: (hh, w) else: (w, hh)
  result = newBitmap(ow, oh)
  let a = h.alphaIndex
  let prem = a >= 0 and h.ec[a].associated
  var opaque = true
  let p0 = cast[FBuf](unsafeAddr img.p[0].d[0])
  let p1 = cast[FBuf](unsafeAddr img.p[1].d[0])
  let p2 = cast[FBuf](unsafeAddr img.p[2].d[0])
  let pa = if a >= 0: cast[FBuf](unsafeAddr img.p[3 + a].d[0]) else: nil
  let o = cast[ptr UncheckedArray[uint32]](addr result.px[0])
  for y in 0 ..< hh:
    let d0 = cast[FBuf](unsafeAddr Dither[(y and 31) * 32])
    let d1 = cast[FBuf](unsafeAddr Dither[((y + 13) and 31) * 32])
    let d2 = cast[FBuf](unsafeAddr Dither[((y + 26) and 31) * 32])
    let d3 = cast[FBuf](unsafeAddr Dither[((y + 39) and 31) * 32])
    for x in 0 ..< w:
      let i = y * w + x
      var al = 1'f32
      if pa != nil: al = max(0'f32, min(1'f32, pa[i]))
      var r = p0[i]
      var g = p1[i]
      var b = p2[i]
      if prem:
        let m = 1'f32 / max(1'f32 / float32(1 shl 26), al)
        r *= m
        g *= m
        b *= m
      let rv = uint32(max(0'f32, min(255'f32, r * 255'f32 + d0[x and 31])) + 0.5'f32)
      let gv = uint32(max(0'f32, min(255'f32, g * 255'f32 + d1[(x + 23) and 31])) + 0.5'f32)
      let bv = uint32(max(0'f32, min(255'f32, b * 255'f32 + d2[(x + 46) and 31])) + 0.5'f32)
      var av = 255'u32
      if pa != nil:
        av = uint32(max(0'f32, min(255'f32, al * 255'f32 + d3[(x + 69) and 31])) + 0.5'f32)
        if av != 255: opaque = false
      let v = (av shl 24) or (rv shl 16) or (gv shl 8) or bv
      if h.orientation == 1: o[i] = v
      else:
        let (ox, oy) = orient(w, hh, h.orientation, x, y)
        o[oy * ow + ox] = v
  result.opaque = opaque
  result.changed()

proc to16(h: Header; img: FImage): tuple[w, h: int; px: seq[uint16]] =
  let w = img.w
  let hh = img.h
  let (ow, oh) = if h.orientation >= 5: (hh, w) else: (w, hh)
  result.w = ow
  result.h = oh
  result.px = newSeq[uint16](ow * oh * 4)
  let a = h.alphaIndex
  let prem = a >= 0 and h.ec[a].associated
  for y in 0 ..< hh:
    for x in 0 ..< w:
      let i = y * w + x
      var al = 1'f32
      if a >= 0: al = max(0'f32, min(1'f32, img.p[3 + a].d[i]))
      var v = [img.p[0].d[i], img.p[1].d[i], img.p[2].d[i]]
      if prem:
        let m = 1'f32 / max(1'f32 / float32(1 shl 26), al)
        for k in 0 .. 2: v[k] *= m
      let (ox, oy) = orient(w, hh, h.orientation, x, y)
      let o = (oy * ow + ox) * 4
      for k in 0 .. 2: result.px[o + k] = uint16(max(0'f32, min(1'f32, v[k])) * 65535'f32 + 0.5'f32)
      result.px[o + 3] = uint16(al * 65535'f32 + 0.5'f32)

template guarded(body: untyped) =
  try:
    body
  except JxlError as e:
    raise e
  except IndexDefect, RangeDefect, DivByZeroDefect, OverflowDefect, AccessViolationDefect:
    fail("damaged JPEG XL file")

proc jxlInfo*(data: string): tuple[w, h: int; frames: int; hasAlpha: bool; bits: int] =
  ## The size of the picture (as shown, the orientation applied), how many
  ## frames it shows (1 for a still picture), whether it has transparency
  ## and the bits of each sample; reading only the headers and the frame
  ## headers, not the pixels.
  guarded:
    let cs = codestream(data)
    var r = initBits(cs)
    let h = readHeader(r)
    result.w = if h.orientation >= 5: h.h else: h.w
    result.h = if h.orientation >= 5: h.w else: h.h
    result.hasAlpha = h.alphaIndex >= 0
    result.bits = h.bits
    if h.wantIcc: r.skipIcc()
    r.zeroPad()
    if h.havePreview:
      var ph = h
      ph.w = h.previewW
      ph.h = h.previewH
      let fh = readFrameHeader(r, ph)
      r = initBits(cs, readToc(r, fh).tocEnd())
    if r.overrun: fail("the JPEG XL file is cut short")
    var pos = r.base + r.bitPos div 8
    while true:
      if pos >= cs.len: fail("the JPEG XL file is cut short (no last frame)")
      r = initBits(cs, pos)
      let fh = readFrameHeader(r, h)
      pos = readToc(r, fh).tocEnd()
      if r.overrun or pos > cs.len: fail("the JPEG XL file is cut short")
      if (fh.kind == 0 or fh.kind == 3) and (fh.isLast or fh.duration > 0): inc result.frames
      if fh.isLast: break
    if result.frames == 0: result.frames = 1

proc decodeJxl*(data: string): Bitmap =
  ## The picture of a JPEG XL file (the first frame of an animation). Raises
  ## `JxlError` when it is not JPEG XL or is damaged.
  guarded:
    var h: Header
    let shown = decodeAll(data, true, h)
    if shown.len == 0: fail("damaged JPEG XL (no frame)")
    result = toBitmap(h, shown[0].img)

proc decodeJxl16*(data: string): tuple[w, h: int; px: seq[uint16]] =
  ## The picture with 16 bits a sample: R, G, B, A for each pixel, row by
  ## row (for files of more than 8 bits; 8-bit ones are widened, v * 257).
  guarded:
    var h: Header
    let shown = decodeAll(data, true, h)
    if shown.len == 0: fail("damaged JPEG XL (no frame)")
    result = to16(h, shown[0].img)

proc decodeJxlFrames*(data: string): seq[tuple[bmp: Bitmap; delayMs: int]] =
  ## Each frame of an animation as it is shown -- on the whole canvas, blended
  ## over the frame it names, as libjxl coalesces them -- and how long, in
  ## milliseconds. A still picture gives one frame (0 ms).
  guarded:
    var h: Header
    let shown = decodeAll(data, false, h)
    for s in shown:
      var ms = 0
      if h.animated and h.tpsNum > 0:
        ms = int(round(float(s.durationTicks) * 1000.0 * float(h.tpsDen) / float(h.tpsNum)))
      result.add (toBitmap(h, s.img), ms)

# ---- (VarDCT and the image features follow) ----------------------------------------------------

# ---- splines ---------------------------------------------------------------------------------

const SplinePosLimit = 1'i64 shl 23

proc readSplines(fr: var Frame; st: State; r: var Bits) =
  ## The splines in LF global: kept as coded, drawn after the frame is.
  let f = fr.fh
  let c = readCode(r, 6)
  var rd = c.begin(r)
  let maxPoints = min(1 shl 20, f.sw * f.sh div 2)
  var n = int(c.hybrid(rd, r, 2))
  if n + 1 > maxPoints: fail("damaged JPEG XL (too many splines)")
  inc n
  var lx, ly: int64
  for i in 0 ..< n:
    let dx = c.hybrid(rd, r, 1)
    let dy = c.hybrid(rd, r, 1)
    let x = if i == 0: int64(dx) else: lx + unpackSigned(dx)
    let y = if i == 0: int64(dy) else: ly + unpackSigned(dy)
    if abs(x) >= SplinePosLimit or abs(y) >= SplinePosLimit:
      fail("damaged JPEG XL (spline out of bounds)")
    fr.splines.sx.add x
    fr.splines.sy.add y
    lx = x
    ly = y
  fr.splines.qadj = unpackSigned(c.hybrid(rd, r, 0))
  var total = n
  for i in 0 ..< n:
    var q: QSpline
    let np = int(c.hybrid(rd, r, 3))
    total += np
    if np > maxPoints or total > maxPoints: fail("damaged JPEG XL (too many spline points)")
    q.ddx.setLen(np)
    q.ddy.setLen(np)
    for k in 0 ..< np:
      q.ddx[k] = unpackSigned(c.hybrid(rd, r, 4))
      q.ddy[k] = unpackSigned(c.hybrid(rd, r, 4))
      if abs(int64(q.ddx[k])) >= 1 shl 30 or abs(int64(q.ddy[k])) >= 1 shl 30:
        fail("damaged JPEG XL (spline out of bounds)")
      if r.overrun: fail("the JPEG XL file is cut short")
    for ch in 0 .. 3:
      for k in 0 .. 31:
        q.dct[ch][k] = unpackSigned(c.hybrid(rd, r, 5))
        if q.dct[ch][k] == low(int32): fail("damaged JPEG XL (spline)")
    if r.overrun: fail("the JPEG XL file is cut short")
    fr.splines.sp.add q
  c.finish(rd)

template fastErf(x0: float32): float32 =
  ## libjxl's erf, which the splines' look depends on.
  let x = x0
  let a = abs(x)
  var d = a * 7.77394369e-02'f32 + 2.05260015e-04'f32
  d = d * a + 2.32120216e-01'f32
  d = d * a + 2.77820801e-01'f32
  d = d * a + 1'f32
  let i = 1'f32 / (d * d)
  let v = 1'f32 - i * i
  (if x <= 0: -v else: v)

proc continuousIdct(dct: array[32, float32]; t: float32): float32 =
  for i in 0 .. 31:
    result += sqrt(2'f32) * dct[i] * cos(float32(PI / 32) * float32(i) * (t + 0.5'f32))

proc catmullRom(px, py: seq[float32]; ox, oy: var seq[float32]) =
  ## The centripetal Catmull-Rom curve through the control points, 16 points
  ## between each two.
  ox.setLen(0)
  oy.setLen(0)
  if px.len == 1:
    ox.add px[0]
    oy.add py[0]
    return
  var x = newSeq[float32](px.len + 2)
  var y = newSeq[float32](px.len + 2)
  for i in 0 ..< px.len:
    x[i + 1] = px[i]
    y[i + 1] = py[i]
  x[0] = px[0] + (px[0] - px[1])
  y[0] = py[0] + (py[0] - py[1])
  x[^1] = px[^1] + (px[^1] - px[^2])
  y[^1] = py[^1] + (py[^1] - py[^2])
  for s in 0 ..< x.len - 3:
    ox.add x[s + 1]
    oy.add y[s + 1]
    var d: array[3, float32]
    var t: array[4, float32]
    for k in 0 .. 2:
      d[k] = sqrt(hypot(x[s + k + 1] - x[s + k], y[s + k + 1] - y[s + k]))
      t[k + 1] = t[k] + d[k]
    for i in 1 ..< 16:
      let tt = d[0] + (float32(i) / 16) * d[1]
      var ax, ay: array[3, float32]
      for k in 0 .. 2:
        let m = (tt - t[k]) / d[k]
        ax[k] = x[s + k] + m * (x[s + k + 1] - x[s + k])
        ay[k] = y[s + k] + m * (y[s + k + 1] - y[s + k])
      var bx, by: array[2, float32]
      for k in 0 .. 1:
        let m = (tt - t[k]) / (d[k] + d[k + 1])
        bx[k] = ax[k] + m * (ax[k + 1] - ax[k])
        by[k] = ay[k] + m * (ay[k + 1] - ay[k])
      let m = (tt - t[1]) / d[1]
      ox.add bx[0] + m * (bx[1] - bx[0])
      oy.add by[0] + m * (by[1] - by[0])
  ox.add x[^2]
  oy.add y[^2]

proc toU64(f: float32): uint64 {.inline.} =
  if f >= 1.8e19'f32: 0xFFFF_FFFF_FFFF_FFFF'u64 elif f > 0: uint64(f) else: 0

proc drawSplines(fr: var Frame; st: State; img: var FImage) =
  ## Each spline as a row of Gaussian dots one pixel apart, their color and
  ## width following the curve, added to the three color planes.
  const weight = [0.0042'f32, 0.075, 0.07, 0.3333]
  let f = fr.fh
  let s = addr fr.splines
  let (yx, yb) = if fr.vd != nil: (fr.vd.baseX, fr.vd.baseB) else: (0'f32, 1'f32)
  let areaLimit = min(1024'u64 * uint64(f.width) * uint64(f.height) + (1'u64 shl 32), 1'u64 shl 42)
  let adj = float32(s.qadj)
  let invQ = if s.qadj >= 0: 1'f32 / (1 + 0.125'f32 * adj) else: 1 - 0.125'f32 * adj
  let w = img.p[0].w
  let h = img.p[0].h
  for c in 0 .. 2:
    if img.p[c].w != w or img.p[c].h != h: fail("damaged JPEG XL (splines)")
  var area = 0'u64
  var cpx, cpy, ix, iy, vals: seq[float32]
  for si, q in s.sp:
    # the control points
    var x = s.sx[si]
    var y = s.sy[si]
    cpx.setLen(0)
    cpy.setLen(0)
    cpx.add float32(x)
    cpy.add float32(y)
    var dx, dy: int64
    var manhattan = 0'u64
    for k in 0 ..< q.ddx.len:
      dx += q.ddx[k]
      dy += q.ddy[k]
      manhattan += uint64(abs(dx) + abs(dy))
      if manhattan > areaLimit: fail("damaged JPEG XL (spline too long)")
      if abs(dx) >= SplinePosLimit or abs(dy) >= SplinePosLimit:
        fail("damaged JPEG XL (spline out of bounds)")
      x += dx
      y += dy
      if abs(x) >= SplinePosLimit or abs(y) >= SplinePosLimit:
        fail("damaged JPEG XL (spline out of bounds)")
      if cpx[^1] == float32(x) and cpy[^1] == float32(y):
        fail("damaged JPEG XL (spline with a repeated point)")
      cpx.add float32(x)
      cpy.add float32(y)
    # the coefficients, and the area they may cover
    var dct: array[4, array[32, float32]]
    for c in 0 .. 3:
      for k in 0 .. 31:
        dct[c][k] = float32(q.dct[c][k]) * (if k == 0: sqrt(0.5'f32) else: 1'f32) * weight[c] * invQ
    for k in 0 .. 31:
      dct[0][k] += yx * dct[1][k]
      dct[2][k] += yb * dct[1][k]
    var color: array[3, uint64]
    for c in 0 .. 2:
      for k in 0 .. 31: color[c] += toU64(ceil(invQ * abs(float32(q.dct[c][k]))))
    color[0] += toU64(ceil(abs(yx))) * color[1]
    color[2] += toU64(ceil(abs(yb))) * color[1]
    let maxColor = max(color[0], max(color[1], color[2]))
    let logColor = uint64(max(1, 64 - countLeadingZeroBits(maxColor)))  # ceil(log2(1 + maxColor))
    let weightLimit = ceil(sqrt((float32(areaLimit) / float32(logColor)) /
                                float32(max(1'u64, manhattan))))
    var widthEst = 0'u64
    for k in 0 .. 31:
      let wf = ceil(invQ * abs(float32(q.dct[3][k])))
      let wt = toU64(min(weightLimit, max(1'f32, wf)))
      widthEst += wt * wt * logColor
    area += widthEst * manhattan
    # (libjxl's limit, and 16 times the area past which it warns that drawing
    # will be slow: libjxl's own test of splines needs 3.6 times)
    if area > areaLimit or area > 16'u64 * min(8'u64 * uint64(f.width) * uint64(f.height) +
                                               (1'u64 shl 25), 1'u64 shl 30):
      fail("JPEG XL splines too large to draw")
    # the curve, then the points one pixel apart along it
    catmullRom(cpx, cpy, ix, iy)
    var dpx, dpy, dmul: seq[float32]
    var curx = ix[0]
    var cury = iy[0]
    dpx.add curx
    dpy.add cury
    dmul.add 1
    var next = 0
    block walk:
      while next < ix.len:
        var prevx = curx
        var prevy = cury
        var arc = 0'f32
        while true:
          if next == ix.len:
            dpx.add prevx
            dpy.add prevy
            dmul.add arc
            break walk
          let ex = ix[next] - prevx
          let ey = iy[next] - prevy
          let toNext = sqrt(ex * ex + ey * ey)
          if arc + toNext >= 1:
            let m = (1 - arc) / toNext
            curx = prevx + m * ex
            cury = prevy + m * ey
            dpx.add curx
            dpy.add cury
            dmul.add 1
            break
          arc += toNext
          prevx = ix[next]
          prevy = iy[next]
          inc next
    let arcLen = float32(dpx.len - 2) + dmul[^1]
    if arcLen <= 0: continue
    let invArc = 1'f32 / arcLen
    for k in 0 ..< dpx.len:
      let t = 31'f32 * min(1'f32, float32(k) * invArc)
      var col: array[3, float32]
      for c in 0 .. 2: col[c] = continuousIdct(dct[c], t)
      let sigma = continuousIdct(dct[3], t)
      let intensity = dmul[k]
      if not (classify(sigma) in {fcNormal, fcSubnormal} and
              classify(1'f32 / sigma) in {fcNormal, fcSubnormal}): continue
      var mc = 0.01'f32
      for c in 0 .. 2: mc = max(mc, abs(col[c] * intensity))
      let maxDist = sqrt(-2'f32 * sigma * sigma * (ln(0.1'f32) * 5 - ln(mc)))
      if classify(maxDist) notin {fcNormal, fcSubnormal, fcZero}: continue
      let cx = dpx[k]
      let cy = dpy[k]
      let y0 = max(int(round(cy - maxDist)), 0)
      let y1 = min(int(round(cy + maxDist)) + 1, h)
      let x0 = max(int(round(cx - maxDist)), 0)
      let x1 = min(int(round(cx + maxDist)) + 1, w)
      if y1 <= y0 or x1 <= x0: continue
      let invSigma = 1'f32 / sigma
      let s4 = 0.25'f32 * sigma * intensity
      if vals.len < x1 - x0: vals.setLen(x1 - x0)
      let vs = cast[FBuf](addr vals[0])
      for yy in y0 ..< y1:
        let ddy = float32(yy) - cy
        let dy2 = ddy * ddy
        let ax = int32(x0)
        for i in 0'i32 ..< int32(x1 - x0):
          let ddx = float32(ax + i) - cx   # (32-bit: a packed conversion)
          let dist = sqrt(ddx * ddx + dy2)
          let one = fastErf((dist * 0.5'f32 + 0.353553391'f32) * invSigma) -
                    fastErf((dist * 0.5'f32 - 0.353553391'f32) * invSigma)
          vs[i] = s4 * one * one
        for c in 0 .. 2:
          let row = cast[FBuf](addr img.p[c].d[yy * w + x0])
          let k = col[c]
          for i in 0 ..< x1 - x0: row[i] += k * vs[i]

# ---- VarDCT: the transforms ------------------------------------------------------------------

const
  AcsCx = [1, 1, 1, 1, 2, 4, 1, 2, 1, 4, 2, 4, 1, 1, 1, 1, 1, 1, 8, 4, 8, 16, 8, 16, 32, 16, 32]
  AcsCy = [1, 1, 1, 1, 2, 4, 2, 1, 4, 1, 4, 2, 1, 1, 1, 1, 1, 1, 8, 8, 4, 16, 16, 8, 32, 32, 16]
  AcsMatrix = [0, 1, 2, 3, 4, 5, 6, 6, 7, 7, 8, 8, 9, 9, 10, 10, 10, 10, 11, 12, 12, 13, 14, 14, 15, 16, 16]
  AcsOrder = [0, 1, 1, 1, 2, 3, 4, 4, 5, 5, 6, 6, 1, 1, 1, 1, 1, 1, 7, 8, 8, 9, 10, 10, 11, 12, 12]
  MatRx = [1, 1, 1, 1, 2, 4, 1, 1, 2, 1, 1, 8, 4, 16, 8, 32, 16]     # rows / 8 (the smaller side)
  MatRy = [1, 1, 1, 1, 2, 4, 2, 4, 4, 1, 1, 8, 8, 16, 16, 32, 32]    # columns / 8 (the larger side)
  OrderW = [8, 8, 16, 32, 16, 32, 32, 64, 64, 128, 128, 256, 256]
  OrderH = [8, 8, 16, 32, 8, 8, 16, 64, 32, 128, 64, 256, 128]
  DefaultCtxMap = [0'u8, 1, 2, 2, 3, 3, 4, 5, 6, 6, 6, 6, 6, 7, 8, 9, 9, 10, 11, 12, 13, 14, 14, 14,
                   14, 14, 7, 8, 9, 9, 10, 11, 12, 13, 14, 14, 14, 14, 14]
  CoeffFreqCtx = [0xBAD, 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14,
    15, 15, 16, 16, 17, 17, 18, 18, 19, 19, 20, 20, 21, 21, 22, 22,
    23, 23, 23, 23, 24, 24, 24, 24, 25, 25, 25, 25, 26, 26, 26, 26,
    27, 27, 27, 27, 28, 28, 28, 28, 29, 29, 29, 29, 30, 30, 30, 30]
  CoeffNumNonzeroCtx = [0xBAD, 0, 31, 62, 62, 93, 93, 93, 93, 123, 123, 123, 123,
    152, 152, 152, 152, 152, 152, 152, 152, 180, 180, 180, 180, 180,
    180, 180, 180, 180, 180, 180, 180, 206, 206, 206, 206, 206, 206,
    206, 206, 206, 206, 206, 206, 206, 206, 206, 206, 206, 206, 206,
    206, 206, 206, 206, 206, 206, 206, 206, 206, 206, 206, 206]

proc isSpecial(t: int): bool {.inline.} = t in {1, 2, 3, 12, 13, 14, 15, 16, 17}
proc transposed(t: int): bool {.inline.} = not isSpecial(t) and AcsCy[t] >= AcsCx[t]

var naturalOrders: array[13, seq[uint16]]

proc naturalOrder(o: int): lent seq[uint16] =
  ## libjxl's natural order of a block's coefficients: x + 256 * y in the wide layout.
  if naturalOrders[o].len == 0:
    let bw = OrderW[o]
    let bh = OrderH[o]
    let yscale = bw div bh
    let lbw = bw div 8
    let lbh = bh div 8
    var res = newSeq[uint16](bw * bh)
    var idx = 0
    while idx < lbw * lbh:
      res[idx] = uint16((idx mod lbw) + 256 * (idx div lbw))
      inc idx
    for dist in 1 ..< 2 * bw:
      let margin = max(0, dist - bw)
      for order in margin ..< dist - margin:
        var x, y: int
        if dist mod 2 == 1:
          x = order
          y = dist - 1 - order
        else:
          x = dist - 1 - order
          y = order
        if x < lbw and y < lbw: continue
        if y mod yscale != 0: continue
        res[idx] = uint16(x + 256 * (y div yscale))
        inc idx
    naturalOrders[o] = res
  naturalOrders[o]

var secTables: array[9, seq[float32]]
for lg in 2 .. 8:
  let n = 1 shl lg
  secTables[lg] = newSeq[float32](n div 2)
  for k in 0 ..< n div 2:
    secTables[lg][k] = float32(1.0 / (2.0 * cos(float(2 * k + 1) * PI / float(2 * n))))

const Sqrt2 = 1.4142135623730951'f32

proc dct4(i0, i1, i2, i3: float32; inverse: bool): array[4, float32] {.inline.} =
  const sec0 = 0.5411961'f32
  const sec1 = 1.306563'f32
  if not inverse:
    let sum03 = i0 + i3
    let sum12 = i1 + i2
    let tmp0 = (i0 - i3) * sec0
    let tmp1 = (i1 - i2) * sec1
    let out0 = (tmp0 + tmp1) / 4
    let out1 = (tmp0 - tmp1) / 4
    [(sum03 + sum12) / 4, out0 * Sqrt2 + out1, (sum03 - sum12) / 4, out1]
  else:
    let tmp0 = i1 * Sqrt2
    let tmp1 = i1 + i3
    let out0 = (tmp0 + tmp1) * sec0
    let out1 = (tmp0 - tmp1) * sec1
    let sum02 = i0 + i2
    let sub02 = i0 - i2
    [sum02 + out0, sub02 + out1, sub02 - out1, sum02 - out0]

proc dct1d(io: FBuf; n: int; scratch: FBuf; inverse: bool) =
  ## X[k] = 1/n sum x[i] cos(k (2i+1) pi / 2n) (times sqrt 2 for k > 0); and back.
  case n
  of 0, 1: discard
  of 2:
    let a = io[0]
    let b = io[1]
    if inverse:
      io[0] = a + b
      io[1] = a - b
    else:
      io[0] = (a + b) / 2
      io[1] = (a - b) / 2
  of 4:
    let o = dct4(io[0], io[1], io[2], io[3], inverse)
    for i in 0 .. 3: io[i] = o[i]
  of 8:
    let sec = cast[FBuf](unsafeAddr secTables[3][0])
    if not inverse:
      let a = dct4((io[0] + io[7]) / 2, (io[1] + io[6]) / 2, (io[2] + io[5]) / 2, (io[3] + io[4]) / 2, false)
      var b = dct4((io[0] - io[7]) * sec[0] / 2, (io[1] - io[6]) * sec[1] / 2,
                   (io[2] - io[5]) * sec[2] / 2, (io[3] - io[4]) * sec[3] / 2, false)
      b[0] *= Sqrt2
      for i in 0 .. 3: io[2 * i] = a[i]
      for i in 0 .. 2: io[2 * i + 1] = b[i] + b[i + 1]
      io[7] = b[3]
    else:
      let a = dct4(io[0], io[2], io[4], io[6], true)
      let b = dct4(io[1] * Sqrt2, io[3] + io[1], io[5] + io[3], io[7] + io[5], true)
      for i in 0 .. 3:
        let r = b[i] * sec[i]
        io[i] = a[i] + r
        io[7 - i] = a[i] - r
  else:
    let h = n div 2
    let in0 = scratch
    let in1 = cast[FBuf](addr scratch[h])
    let out1 = cast[FBuf](addr io[h])
    let sec = cast[FBuf](unsafeAddr secTables[ceilLog2(n)][0])
    if not inverse:
      for i in 0 ..< h:
        in0[i] = (io[i] + io[n - 1 - i]) / 2
        in1[i] = (io[i] - io[n - 1 - i]) / 2 * sec[i]
      dct1d(in0, h, io, false)
      dct1d(in1, h, out1, false)
      in1[0] *= Sqrt2
      for i in 0 ..< h - 1: in1[i] += in1[i + 1]
      for i in 0 ..< h:
        io[2 * i] = in0[i]
        io[2 * i + 1] = in1[i]
    else:
      for i in 0 ..< h:
        in0[i] = io[2 * i]
        in1[i] = io[2 * i + 1]
      for i in 1 ..< h: in1[h - i] += in1[h - i - 1]
      in1[0] *= Sqrt2
      dct1d(in0, h, io, true)
      dct1d(in1, h, out1, true)
      for i in 0 ..< h:
        let r = in1[i] * sec[i]
        io[i] = in0[i] + r
        io[n - 1 - i] = in0[i] - r

proc dct2d(b: FBuf; stride, w, h: int; inverse: bool) =
  ## A 2D DCT of the w x h block at b (rows `stride` apart).
  var tmp {.noinit.}: array[256, float32]
  var scratch {.noinit.}: array[256, float32]
  let t = cast[FBuf](addr tmp[0])
  let s = cast[FBuf](addr scratch[0])
  if w > 1:
    for y in 0 ..< h: dct1d(cast[FBuf](addr b[y * stride]), w, s, inverse)
  if h > 1:
    for x in 0 ..< w:
      for y in 0 ..< h: t[y] = b[y * stride + x]
      dct1d(t, h, s, inverse)
      for y in 0 ..< h: b[y * stride + x] = t[y]

proc auxIdct2(b: FBuf; stride, size: int) =
  var s {.noinit.}: array[64, float32]
  let n2 = size div 2
  for y in 0 ..< n2:
    for x in 0 ..< n2:
      let c00 = b[y * stride + x]
      let c01 = b[y * stride + x + n2]
      let c10 = b[(y + n2) * stride + x]
      let c11 = b[(y + n2) * stride + x + n2]
      s[2 * y * 8 + 2 * x] = c00 + c01 + c10 + c11
      s[2 * y * 8 + 2 * x + 1] = c00 + c01 - c10 - c11
      s[(2 * y + 1) * 8 + 2 * x] = c00 - c01 + c10 - c11
      s[(2 * y + 1) * 8 + 2 * x + 1] = c00 - c01 - c10 + c11
  for y in 0 ..< size:
    for x in 0 ..< size: b[y * stride + x] = s[y * 8 + x]

const AfvBasis = [
  [0.25'f32, 0.25, 0.25, 0.25, 0.25, 0.25, 0.25, 0.25, 0.25, 0.25, 0.25, 0.25, 0.25, 0.25, 0.25, 0.25],
  [0.876902929799142'f32, 0.2206518106944235, -0.10140050393753763, -0.1014005039375375,
   0.2206518106944236, -0.10140050393753777, -0.10140050393753772, -0.10140050393753763,
   -0.10140050393753758, -0.10140050393753769, -0.1014005039375375, -0.10140050393753768,
   -0.10140050393753768, -0.10140050393753759, -0.10140050393753763, -0.10140050393753741],
  [0.0'f32, 0.0, 0.40670075830260755, 0.44444816619734445, 0.0, 0.0, 0.19574399372042936,
   0.2929100136981264, -0.40670075830260716, -0.19574399372042872, 0.0, 0.11379074460448091,
   -0.44444816619734384, -0.29291001369812636, -0.1137907446044814, 0.0],
  [0.0'f32, 0.0, -0.21255748058288748, 0.3085497062849767, 0.0, 0.4706702258572536,
   -0.1621205195722993, 0.0, -0.21255748058287047, -0.16212051957228327, -0.47067022585725277,
   -0.1464291867126764, 0.3085497062849487, 0.0, -0.14642918671266536, 0.4251149611657548],
  [0.0'f32, -0.7071067811865474, 0.0, 0.0, 0.7071067811865476, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0,
   0.0, 0.0, 0.0, 0.0, 0.0],
  [-0.4105377591765233'f32, 0.6235485373547691, -0.06435071657946274, -0.06435071657946266,
   0.6235485373547694, -0.06435071657946284, -0.0643507165794628, -0.06435071657946274,
   -0.06435071657946272, -0.06435071657946279, -0.06435071657946266, -0.06435071657946277,
   -0.06435071657946277, -0.06435071657946273, -0.06435071657946274, -0.0643507165794626],
  [0.0'f32, 0.0, -0.4517556589999482, 0.15854503551840063, 0.0, -0.04038515160822202,
   0.0074182263792423875, 0.39351034269210167, -0.45175565899994635, 0.007418226379244351,
   0.1107416575309343, 0.08298163094882051, 0.15854503551839705, 0.3935103426921022,
   0.0829816309488214, -0.45175565899994796],
  [0.0'f32, 0.0, -0.304684750724869, 0.5112616136591823, 0.0, 0.0, -0.290480129728998,
   -0.06578701549142804, 0.304684750724884, 0.2904801297290076, 0.0, -0.23889773523344604,
   -0.5112616136592012, 0.06578701549142545, 0.23889773523345467, 0.0],
  [0.0'f32, 0.0, 0.3017929516615495, 0.25792362796341184, 0.0, 0.16272340142866204,
   0.09520022653475037, 0.0, 0.3017929516615503, 0.09520022653475055, -0.16272340142866173,
   -0.35312385449816297, 0.25792362796341295, 0.0, -0.3531238544981624, -0.6035859033230976],
  [0.0'f32, 0.0, 0.40824829046386274, 0.0, 0.0, 0.0, 0.0, -0.4082482904638628,
   -0.4082482904638635, 0.0, 0.0, -0.40824829046386296, 0.0, 0.4082482904638634,
   0.408248290463863, 0.0],
  [0.0'f32, 0.0, 0.1747866975480809, 0.0812611176717539, 0.0, 0.0, -0.3675398009862027,
   -0.307882213957909, -0.17478669754808135, 0.3675398009862011, 0.0, 0.4826689115059883,
   -0.08126111767175039, 0.30788221395790305, -0.48266891150598584, 0.0],
  [0.0'f32, 0.0, -0.21105601049335784, 0.18567180916109802, 0.0, 0.0, 0.49215859013738733,
   -0.38525013709251915, 0.21105601049335806, -0.49215859013738905, 0.0, 0.17419412659916217,
   -0.18567180916109904, 0.3852501370925211, -0.1741941265991621, 0.0],
  [0.0'f32, 0.0, -0.14266084808807264, -0.3416446842253372, 0.0, 0.7367497537172237,
   0.24627107722075148, -0.08574019035519306, -0.14266084808807344, 0.24627107722075137,
   0.14883399227113567, -0.04768680350229251, -0.3416446842253373, -0.08574019035519267,
   -0.047686803502292804, -0.14266084808807242],
  [0.0'f32, 0.0, -0.13813540350758585, 0.3302282550303788, 0.0, 0.08755115000587084,
   -0.07946706605909573, -0.4613374887461511, -0.13813540350758294, -0.07946706605910261,
   0.49724647109535086, 0.12538059448563663, 0.3302282550303805, -0.4613374887461554,
   0.12538059448564315, -0.13813540350758452],
  [0.0'f32, 0.0, -0.17437602599651067, 0.0702790691196284, 0.0, -0.2921026642334881,
   0.3623817333531167, 0.0, -0.1743760259965108, 0.36238173335311646, 0.29210266423348785,
   -0.4326608024727445, 0.07027906911962818, 0.0, -0.4326608024727457, 0.34875205199302267],
  [0.0'f32, 0.0, 0.11354987314994337, -0.07417504595810355, 0.0, 0.19402893032594343,
   -0.435190496523228, 0.21918684838857466, 0.11354987314994257, -0.4351904965232251,
   0.5550443808910661, -0.25468277124066463, -0.07417504595810233, 0.2191868483885728,
   -0.25468277124066413, 0.1135498731499429]]

proc inverseTransform(b: FBuf; stride, t: int) =
  ## The varblock at b, coefficients to samples (the LLF already in place).
  template at(x, y: int): var float32 = b[(y) * stride + (x)]
  case t
  of 2:                                         # DCT2x2
    auxIdct2(b, stride, 2)
    auxIdct2(b, stride, 4)
    auxIdct2(b, stride, 8)
  of 3, 1:                                      # DCT4x4, Hornuss
    auxIdct2(b, stride, 2)
    var s: array[64, float32]
    for y in 0 .. 1:
      for x in 0 .. 1:
        let o = (y * 2 + x) * 16
        if t == 3:
          for iy in 0 .. 3:
            for ix in 0 .. 3: s[o + ix * 4 + iy] = at(x + ix * 2, y + iy * 2)
          dct2d(cast[FBuf](addr s[o]), 4, 4, 4, true)
        else:
          for iy in 0 .. 3:
            for ix in 0 .. 3: s[o + iy * 4 + ix] = at(x + ix * 2, y + iy * 2)
          var sum = 0'f32
          for k in 1 .. 15: sum += s[o + k]
          let avg = s[o] - sum / 16
          s[o] = s[o + 5]
          s[o + 5] = 0
          for k in 0 .. 15: s[o + k] += avg
    for y in 0 .. 1:
      for x in 0 .. 1:
        let o = (y * 2 + x) * 16
        for iy in 0 .. 3:
          for ix in 0 .. 3: at(x * 4 + ix, y * 4 + iy) = s[o + iy * 4 + ix]
  of 12, 13:                                    # DCT4x8, DCT8x4
    let c0 = at(0, 0)
    let c1 = at(0, 1)
    at(0, 0) = c0 + c1
    at(0, 1) = c0 - c1
    var s: array[64, float32]
    for idx in 0 .. 1:
      for iy in 0 .. 3:
        for ix in 0 .. 7: s[idx * 32 + iy * 8 + ix] = at(ix, iy * 2 + idx)
      dct2d(cast[FBuf](addr s[idx * 32]), 8, 8, 4, true)
    for y in 0 .. 7:
      for x in 0 .. 7:
        if t == 13: at(y, x) = s[y * 8 + x]
        else: at(x, y) = s[y * 8 + x]
  of 14, 15, 16, 17:                            # AFV
    let n = t - 14
    let flipX = n mod 2
    let flipY = n div 2
    var cafv: array[16, float32]
    cafv[0] = (at(0, 0) + at(1, 0) + at(0, 1)) * 4
    for idx in 1 .. 15: cafv[idx] = at(2 * (idx mod 4), 2 * (idx div 4))
    var samples: array[16, float32]
    for k in 0 .. 15:
      for i in 0 .. 15: samples[i] += cafv[k] * AfvBasis[k][i]
    var s44: array[16, float32]
    var s48: array[32, float32]
    s44[0] = at(0, 0) - at(1, 0) + at(0, 1)
    for iy in 0 .. 3:
      for ix in 0 .. 3:
        if (ix or iy) == 0: continue
        s44[ix * 4 + iy] = at(2 * ix + 1, 2 * iy)
    dct2d(cast[FBuf](addr s44[0]), 4, 4, 4, true)
    s48[0] = at(0, 0) - at(0, 1)
    for iy in 0 .. 3:
      for ix in 0 .. 7:
        if (ix or iy) == 0: continue
        s48[iy * 8 + ix] = at(ix, 2 * iy + 1)
    dct2d(cast[FBuf](addr s48[0]), 8, 8, 4, true)
    for iy in 0 .. 3:
      let ay = if flipY == 0: iy else: 3 - iy
      for ix in 0 .. 3:
        let ax = if flipX == 0: ix else: 3 - ix
        at(flipX * 4 + ix, flipY * 4 + iy) = samples[ay * 4 + ax]
    for iy in 0 .. 3:
      for ix in 0 .. 3: at((1 - flipX) * 4 + ix, flipY * 4 + iy) = s44[iy * 4 + ix]
    for iy in 0 .. 3:
      for ix in 0 .. 7: at(ix, (1 - flipY) * 4 + iy) = s48[iy * 8 + ix]
  else:
    dct2d(b, stride, AcsCx[t] * 8, AcsCy[t] * 8, true)

proc scaleF(i: int): float32 =
  if i == 0: 1'f32
  else: float32(sin(float(i) * PI / 64) / (8 * sin(float(i) * PI / 512)))

# ---- VarDCT: quantization weights ------------------------------------------------------------

type QEnc = object
  mode: int                    # 0 the default, 1 Hornuss, 2 DCT2, 3 DCT4, 4 DCT4x8, 5 AFV, 6 DCT, 7 raw
  params: array[3, seq[float32]]
  dct, dct4: array[3, seq[float32]]
  den: float32
  raw: array[3, seq[int32]]

proc dctParams(a, b, c: openArray[float32]): array[3, seq[float32]] = [@a, @b, @c]

proc defaultEnc(m: int): QEnc =
  const seqA = [-1.025'f32, -0.78, -0.65012, -0.19041574, -0.20819396, -0.421064, -0.32733846]
  const seqB = [-0.30419582'f32, -0.36330363, -0.3566038, -0.34430745, -0.33699593, -0.30180866, -0.27321684]
  const seqC = [-1.2'f32, -1.2, -0.8, -0.7, -0.7, -0.4, -0.5]
  const dct4x8 = [[2198.0505'f32, -0.96269625, -0.7619425, -0.65511405],
                  [764.36554'f32, -0.926302, -0.967523, -0.2784529],
                  [527.10754'f32, -1.4594386, -1.4500821, -1.5843723]]
  const dct4p = [[2200.0'f32, 0.0, 0.0, 0.0], [392.0'f32, 0.0, 0.0, 0.0], [112.0'f32, -0.25, -0.25, -0.5]]
  proc common(a, b, c: float32): QEnc =
    QEnc(mode: 6, dct: [@[a] & @seqA, @[b] & @seqB, @[c] & @seqC])
  case m
  of 0: QEnc(mode: 6, dct: dctParams([3150.0'f32, 0.0, -0.4, -0.4, -0.4, -2.0],
                                     [560.0'f32, 0.0, -0.3, -0.3, -0.3, -0.3],
                                     [512.0'f32, -2.0, -1.0, 0.0, -1.0, -2.0]))
  of 1: QEnc(mode: 1, params: [@[280.0'f32, 3160.0, 3160.0], @[60.0'f32, 864.0, 864.0],
                               @[18.0'f32, 200.0, 200.0]])
  of 2: QEnc(mode: 2, params: [@[3840.0'f32, 2560.0, 1280.0, 640.0, 480.0, 300.0],
                               @[960.0'f32, 640.0, 320.0, 180.0, 140.0, 120.0],
                               @[640.0'f32, 320.0, 128.0, 64.0, 32.0, 16.0]])
  of 3: QEnc(mode: 3, params: [@[1.0'f32, 1.0], @[1.0'f32, 1.0], @[1.0'f32, 1.0]],
             dct: [@(dct4p[0]), @(dct4p[1]), @(dct4p[2])])
  of 4: QEnc(mode: 6, dct: dctParams([8996.873'f32, -1.3000778, -0.4942453, -0.43909377, -0.6350102, -0.9017726, -1.6162099],
                                     [3191.4836'f32, -0.67424583, -0.80745816, -0.4492584, -0.3586544, -0.3132239, -0.37615025],
                                     [1157.504'f32, -2.0531423, -1.4, -0.5068713, -0.4270873, -1.4856834, -4.920914]))
  of 5: QEnc(mode: 6, dct: dctParams([15718.408'f32, -1.025, -0.98, -0.9012, -0.4, -0.48819396, -0.421064, -0.27],
                                     [7305.7637'f32, -0.8041958, -0.76330364, -0.5566038, -0.49785304, -0.43699592, -0.40180868, -0.27321684],
                                     [3803.5317'f32, -3.0607336, -2.041327, -2.023565, -0.54953897, -0.4, -0.4, -0.3]))
  of 6: QEnc(mode: 6, dct: dctParams([7240.7734'f32, -0.7, -0.7, -0.2, -0.2, -0.2, -0.5],
                                     [1448.1547'f32, -0.5, -0.5, -0.5, -0.2, -0.2, -0.2],
                                     [506.85413'f32, -1.4, -0.2, -0.5, -0.5, -1.5, -3.6]))
  of 7: QEnc(mode: 6, dct: dctParams([16283.249'f32, -1.7812846, -1.6309059, -1.0382179, -0.85, -0.7, -0.9, -1.2360638],
                                     [5089.1577'f32, -0.3200494, -0.3536285, -0.3034, -0.61, -0.5, -0.5, -0.6],
                                     [3397.7761'f32, -0.32132736, -0.3450762, -0.7034, -0.9, -1.0, -1.0, -1.1754606]))
  of 8: QEnc(mode: 6, dct: dctParams([13844.971'f32, -0.971138, -0.658, -0.42026, -0.22712, -0.2206, -0.226, -0.6],
                                     [4798.964'f32, -0.6112531, -0.8377079, -0.7901486, -0.26927274, -0.38272768, -0.22924222, -0.20719099],
                                     [1807.2369'f32, -1.2, -1.2, -0.7, -0.7, -0.7, -0.4, -0.5]))
  of 9: QEnc(mode: 4, params: [@[1.0'f32], @[1.0'f32], @[1.0'f32]],
             dct: [@(dct4x8[0]), @(dct4x8[1]), @(dct4x8[2])])
  of 10: QEnc(mode: 5, params: [@[3072.0'f32, 3072.0, 256.0, 256.0, 256.0, 414.0, 0.0, 0.0, 0.0],
                                @[1024.0'f32, 1024.0, 50.0, 50.0, 50.0, 58.0, 0.0, 0.0, 0.0],
                                @[384.0'f32, 384.0, 12.0, 12.0, 12.0, 22.0, -0.25, -0.25, -0.25]],
              dct: [@(dct4x8[0]), @(dct4x8[1]), @(dct4x8[2])],
              dct4: [@(dct4p[0]), @(dct4p[1]), @(dct4p[2])])
  of 11: common(23966.166, 8380.191, 4493.024)
  of 12: common(15358.898, 5597.3604, 2919.9617)
  of 13: common(47932.332, 16760.383, 8986.048)
  of 14: common(30717.797, 11194.721, 5839.9233)
  of 15: common(95864.664, 33520.766, 17972.096)
  else: common(61435.594, 24209.441, 12979.847)

proc interpolate(pos, mx: float32; bands: openArray[float32]): float32 =
  if bands.len == 1: return bands[0]
  let scaled = pos * float32(bands.len - 1) / mx
  let i = min(int(scaled), bands.len - 2)
  let frac = scaled - float32(i)
  let a = bands[i]
  let b = bands[i + 1]
  a * pow(b / a, frac)

proc qmult(x: float32): float32 = (if x > 0: 1 + x else: 1 / (1 - x))

proc dctWeights(params: seq[float32]; w, h: int): seq[float32] =
  var bands = @[params[0]]
  for i in 1 ..< params.len:
    let b = bands[^1] * qmult(params[i])
    if b <= 0: fail("damaged JPEG XL (quantization weights)")
    bands.add b
  result = newSeq[float32](w * h)
  for y in 0 ..< h:
    for x in 0 ..< w:
      let dx = float32(x) / float32(w - 1)
      let dy = float32(y) / float32(h - 1)
      result[y * w + x] = interpolate(sqrt(dx * dx + dy * dy), Sqrt2 + 1e-6'f32, bands)

proc computeWeights(e: QEnc; m: int): array[3, seq[float32]] =
  ## The dequantization multipliers of table m, in the wide layout.
  let w = MatRy[m] * 8
  let h = MatRx[m] * 8
  for c in 0 .. 2:
    var wt: seq[float32]
    case e.mode
    of 6: wt = dctWeights(e.dct[c], w, h)
    of 1:
      let p = e.params[c]
      wt = newSeq[float32](64)
      for v in wt.mitems: v = p[0]
      wt[0] = 1
      wt[1] = p[1]
      wt[8] = p[1]
      wt[9] = p[2]
    of 2:
      let p = e.params[c]
      wt = newSeq[float32](64)
      wt[0] = 1
      for idx in 0 .. 5:
        let dim = 1 shl (idx div 2)
        if idx mod 2 == 0:
          for y in 0 ..< dim:
            for x in dim ..< dim * 2:
              wt[y * 8 + x] = p[idx]
              wt[x * 8 + y] = p[idx]
        else:
          for y in dim ..< dim * 2:
            for x in dim ..< dim * 2: wt[y * 8 + x] = p[idx]
    of 3:
      let mat = dctWeights(e.dct[c], 4, 4)
      wt = newSeq[float32](64)
      for y in 0 .. 7:
        for x in 0 .. 7: wt[y * 8 + x] = mat[(y div 2) * 4 + x div 2]
      wt[1] /= e.params[c][0]
      wt[8] /= e.params[c][0]
      wt[9] /= e.params[c][1]
    of 4:
      let mat = dctWeights(e.dct[c], 8, 4)
      wt = newSeq[float32](64)
      for y in 0 .. 7:
        for x in 0 .. 7: wt[y * 8 + x] = mat[(y div 2) * 8 + x]
      wt[8] /= e.params[c][0]
    of 5:
      const freqs = [0.0'f32, 0.0, 0.8517779, 5.3777843, 0.0, 0.0, 4.734748, 5.4492455, 1.659827,
                     4.0, 7.275749, 10.423227, 2.6629324, 7.6306577, 8.962389, 12.971662]
      let p = e.params[c]
      let w48 = dctWeights(e.dct[c], 8, 4)
      let w44 = dctWeights(e.dct4[c], 4, 4)
      var bands = [p[5], 0'f32, 0, 0]
      for i in 1 .. 3: bands[i] = bands[i - 1] * qmult(p[5 + i])
      wt = newSeq[float32](64)
      for y in 0 .. 3:
        for x in 0 .. 3:
          wt[16 * y + 2 * x] =
            if x == 0 and y == 0: 1'f32
            elif x == 0 and y == 1: p[2]
            elif x == 1 and y == 0: p[3]
            elif x == 1 and y == 1: p[4]
            else: interpolate(freqs[y * 4 + x] - freqs[2], freqs[15] - freqs[2] + 1e-6'f32, bands)
      for y in 0 .. 3:
        for x in 0 .. 7:
          wt[16 * y + 8 + x] = if y == 0 and x == 0: p[0] else: w48[y * 8 + x]
        for x in 0 .. 3:
          wt[16 * y + 2 * x + 1] = if y == 0 and x == 0: p[1] else: w44[y * 4 + x]
    else:
      # raw: an image rx*8 wide, ry*8 tall, read as one flat table
      wt = newSeq[float32](w * h)
      for i in 0 ..< w * h: wt[i] = float32(e.raw[c][i]) * e.den
      for v in wt:
        if v <= 0 or v >= 1e8: fail("damaged JPEG XL (quantization table)")
      result[c] = wt
      continue
    for v in wt.mitems:
      if v <= 0: fail("damaged JPEG XL (quantization weights)")
      v = 1 / v
      if v >= 1e8: fail("damaged JPEG XL (quantization weights)")
    result[c] = wt

proc readDctParams(r: var Bits): array[3, seq[float32]] =
  let n = r.bits(4) + 1
  for c in 0 .. 2:
    result[c] = newSeq[float32](n)
    for i in 0 ..< n: result[c][i] = r.f16()
    result[c][0] *= 64

proc readFixed(r: var Bits; n: int): array[3, seq[float32]] =
  for c in 0 .. 2:
    result[c] = newSeq[float32](n)
    for i in 0 ..< n: result[c][i] = r.f16()

# ---- VarDCT: the stream ----------------------------------------------------------------------

proc decodeVarDctLfGlobal(fr: var Frame; st: State; r: var Bits) =
  let f = fr.fh
  new(fr.vd)
  let vd = fr.vd
  vd.globalScale = r.u32((1, 11), (2049, 11), (4097, 12), (8193, 16))
  vd.quantLf = r.u32((16, 0), (1, 5), (1, 8), (1, 16))
  if r.flag:
    vd.numDcCtx = 1
    vd.ctxMap = @DefaultCtxMap
    vd.numCtxs = 15
  else:
    vd.numDcCtx = 1
    for j in 0 .. 2:
      let n = r.bits(4)
      vd.numDcCtx *= n + 1
      for i in 0 ..< n:
        vd.dcThresh[j].add unpackSigned(uint32(r.u32((0, 4), (16, 8), (272, 16), (65808, 32))))
    let nq = r.bits(4)
    for i in 0 ..< nq: vd.qfThresh.add int32(r.u32((0, 2), (4, 3), (12, 5), (44, 8)) + 1)
    if vd.numDcCtx * (nq + 1) > 64: fail("damaged JPEG XL (block contexts)")
    vd.ctxMap = readClusters(r, 39 * vd.numDcCtx * (nq + 1))
    vd.numCtxs = 0
    for v in vd.ctxMap: vd.numCtxs = max(vd.numCtxs, int(v) + 1)
    if vd.numCtxs > 16: fail("damaged JPEG XL (block contexts)")
  vd.colorFactor = 84
  vd.baseX = 0
  vd.baseB = 1                       # as libjxl: JPEG files code their own (0)
  var xdc, bdc = 0
  if not r.flag:
    vd.colorFactor = float32(r.u32((84, 0), (256, 0), (2, 8), (258, 16)))
    vd.baseX = r.f16()
    vd.baseB = r.f16()
    if abs(vd.baseX) > 4 or abs(vd.baseB) > 4: fail("damaged JPEG XL (chroma from luma)")
    xdc = r.bits(8) - 128
    bdc = r.bits(8) - 128
  vd.xDc = vd.baseX + float32(xdc) / vd.colorFactor
  vd.bDc = vd.baseB + float32(bdc) / vd.colorFactor
  # the frame's block arrays
  let nb = f.xblocks * f.yblocks
  vd.acs = newSeq[int8](nb)
  for v in vd.acs.mitems: v = -2
  vd.qf = newSeq[int32](nb)
  vd.sharp = newSeq[uint8](nb)
  vd.lfIdx = newSeq[uint8](nb)
  vd.xtiles = cdiv(f.xblocks, 8)
  vd.ytox = newSeq[int8](vd.xtiles * cdiv(f.yblocks, 8))
  vd.ytob = newSeq[int8](vd.ytox.len)
  for c in 0 .. 2:
    vd.lf[c] = newPlane(f.xblocks shr f.hs[c], f.yblocks shr f.vs[c])

proc decodeVarDctLfGroup(fr: var Frame; st: State; r: var Bits; g: int) =
  ## The LF coefficients of one LF group.
  let f = fr.fh
  let vd = fr.vd
  let extra = r.bits(2)
  let gx = g mod f.xlfgroups
  let gy = g div f.xlfgroups
  let bx0 = gx * f.gdim
  let by0 = gy * f.gdim
  let bw = min(f.gdim, f.xblocks - bx0)
  let bh = min(f.gdim, f.yblocks - by0)
  var img = MImage(bitDepth: st.hdr.bits)
  for k in 0 .. 2:
    let c = if k < 2: k xor 1 else: k            # channel 0 is Y, 1 is X
    img.ch.add newChannel(bw shr f.hs[c], bh shr f.vs[c])
  decodeModular(r, img, 1 + g, addr fr.tree)
  if img.ch.len != 3: fail("damaged JPEG XL (LF)")
  let mul = 1'f32 / float32(1 shl extra)
  let inv = 65536'f32 / (float32(vd.globalScale) * float32(vd.quantLf))
  let subsampled = f.hs != [0, 0, 0] or f.vs != [0, 0, 0]
  for c in 0 .. 2:
    let ch = addr img.ch[if c < 2: c xor 1 else: c]
    let fac = fr.dcQuant[c] * inv * mul
    let p = addr vd.lf[c]
    let ox = bx0 shr f.hs[c]
    let oy = by0 shr f.vs[c]
    for y in 0 ..< ch.h:
      for x in 0 ..< ch.w:
        p.d[(oy + y) * p.w + ox + x] = float32(ch.px[y * ch.w + x]) * fac
  if not subsampled:
    let px = addr vd.lf[0]
    let py = addr vd.lf[1]
    let pb = addr vd.lf[2]
    for y in 0 ..< bh:
      for x in 0 ..< bw:
        let i = (by0 + y) * px.w + bx0 + x
        let yv = py.d[i]
        px.d[i] += vd.xDc * yv
        pb.d[i] += vd.bDc * yv
  if vd.numDcCtx > 1:
    for y in 0 ..< bh:
      for x in 0 ..< bw:
        var bucket: array[3, int]
        for c in 0 .. 2:
          let ch = addr img.ch[if c < 2: c xor 1 else: c]
          let q = ch.px[(y shr f.vs[c]) * ch.w + (x shr f.hs[c])]
          for t in vd.dcThresh[c]:
            if q > t: inc bucket[c]
        var b = bucket[0]
        b = b * (vd.dcThresh[2].len + 1) + bucket[2]
        b = b * (vd.dcThresh[1].len + 1) + bucket[1]
        vd.lfIdx[(by0 + y) * f.xblocks + bx0 + x] = uint8(b)

proc decodeAcMeta(fr: var Frame; st: State; r: var Bits; g: int) =
  ## The transforms, quantizers, chroma from luma and sharpness of one LF group.
  let f = fr.fh
  let vd = fr.vd
  let gx = g mod f.xlfgroups
  let gy = g div f.xlfgroups
  let bx0 = gx * f.gdim
  let by0 = gy * f.gdim
  let bw = min(f.gdim, f.xblocks - bx0)
  let bh = min(f.gdim, f.yblocks - by0)
  let count = r.bits(ceilLog2(bw * bh)) + 1
  var img = MImage(bitDepth: st.hdr.bits)
  img.ch.add newChannel(cdiv(bw, 8), cdiv(bh, 8), 3, 3)
  img.ch.add newChannel(cdiv(bw, 8), cdiv(bh, 8), 3, 3)
  img.ch.add newChannel(count, 2)
  img.ch.add newChannel(bw, bh)
  decodeModular(r, img, 1 + 2 * f.numLfGroups + g, addr fr.tree)
  if img.ch.len != 4: fail("damaged JPEG XL (AC metadata)")
  for y in 0 ..< img.ch[0].h:
    for x in 0 ..< img.ch[0].w:
      let i = (by0 div 8 + y) * vd.xtiles + bx0 div 8 + x
      vd.ytox[i] = int8(clamp(img.ch[0].px[y * img.ch[0].w + x], -128, 127))
      vd.ytob[i] = int8(clamp(img.ch[1].px[y * img.ch[1].w + x], -128, 127))
  let is444 = f.hs == [0, 0, 0] and f.vs == [0, 0, 0]
  let acsRow = addr img.ch[2]
  var num = 0
  for iy in 0 ..< bh:
    let y = by0 + iy
    for ix in 0 ..< bw:
      let x = bx0 + ix
      let s = img.ch[3].px[iy * bw + ix]
      if s < 0 or s >= 8: fail("damaged JPEG XL (sharpness)")
      vd.sharp[y * f.xblocks + x] = uint8(s)
      if vd.acs[y * f.xblocks + x] != -2: continue
      if num >= count: fail("damaged JPEG XL (AC strategy)")
      let t = int(acsRow.px[num])
      if t < 0 or t > 26: fail("damaged JPEG XL (AC strategy)")
      let cx = AcsCx[t]
      let cy = AcsCy[t]
      if (cx > 1 or cy > 1) and not is444: fail("damaged JPEG XL (AC strategy with subsampling)")
      if x + cx > (x div 32 + 1) * 32 or x + cx > min(f.xblocks, bx0 + bw) or
         y + cy > (y div 32 + 1) * 32 or y + cy > min(f.yblocks, by0 + bh):
        fail("damaged JPEG XL (AC strategy out of bounds)")
      for dy in 0 ..< cy:
        for dx in 0 ..< cx:
          let i = (y + dy) * f.xblocks + x + dx
          if vd.acs[i] != -2: fail("damaged JPEG XL (overlapping blocks)")
          vd.acs[i] = -1
      vd.acs[y * f.xblocks + x] = int8(t)
      vd.qf[y * f.xblocks + x] = 1 + clamp(acsRow.px[count + num], 0'i32, 255'i32)
      inc num

proc finalizeLf(fr: var Frame; st: State) =
  ## The LF image complete: from an LF frame, or smoothed.
  let f = fr.fh
  let vd = fr.vd
  if (f.flags and FlagUseLf) != 0:
    let src = addr st.lf[f.lfLevel]
    if src.p.len < 3: fail("damaged JPEG XL (no LF frame)")
    for c in 0 .. 2:
      let p = addr vd.lf[c]
      for y in 0 ..< p.h:
        for x in 0 ..< p.w:
          p.d[y * p.w + x] = src.p[c].d[min(y, src.h - 1) * src.w + min(x, src.w - 1)]
    return
  if (f.flags and FlagSkipSmoothing) != 0: return
  const w1 = 0.20345139757231578'f32
  const w2 = 0.0334829185968739'f32
  const w0 = 1'f32 - 4'f32 * (w1 + w2)
  let inv = 65536'f32 / (float32(vd.globalScale) * float32(vd.quantLf))
  var fac: array[3, float32]
  for c in 0 .. 2: fac[c] = fr.dcQuant[c] * inv
  let is444 = f.hs == [0, 0, 0] and f.vs == [0, 0, 0]
  proc smooth(p: Plane; fc: float32; x, y: int; gap: var float32): (float32, float32) {.inline.} =
    let w = p.w
    let mc = p.d[y * w + x]
    let side = p.d[y * w + x - 1] + p.d[y * w + x + 1] + p.d[(y - 1) * w + x] + p.d[(y + 1) * w + x]
    let corner = p.d[(y - 1) * w + x - 1] + p.d[(y - 1) * w + x + 1] +
                 p.d[(y + 1) * w + x - 1] + p.d[(y + 1) * w + x + 1]
    let sm = corner * w2 + side * w1 + mc * w0
    gap = max(gap, abs((mc - sm) / fc))
    (mc, sm)
  if is444:
    let w = vd.lf[0].w
    let h = vd.lf[0].h
    if w <= 2 or h <= 2: return
    var o: array[3, Plane]
    for c in 0 .. 2: o[c] = vd.lf[c]
    for y in 1 ..< h - 1:
      for x in 1 ..< w - 1:
        var gap = 0.5'f32
        let a = smooth(vd.lf[0], fac[0], x, y, gap)
        let b = smooth(vd.lf[1], fac[1], x, y, gap)
        let c = smooth(vd.lf[2], fac[2], x, y, gap)
        let factor = max(0'f32, 3'f32 - 4'f32 * gap)
        o[0].d[y * w + x] = (a[1] - a[0]) * factor + a[0]
        o[1].d[y * w + x] = (b[1] - b[0]) * factor + b[0]
        o[2].d[y * w + x] = (c[1] - c[0]) * factor + c[0]
    for c in 0 .. 2: vd.lf[c] = move o[c]
  else:
    for c in 0 .. 2:
      let w = vd.lf[c].w
      let h = vd.lf[c].h
      if w <= 2 or h <= 2: continue
      var o = vd.lf[c]
      for y in 1 ..< h - 1:
        for x in 1 ..< w - 1:
          var gap = 0.5'f32
          let a = smooth(vd.lf[c], fac[c], x, y, gap)
          let factor = max(0'f32, 3'f32 - 4'f32 * gap)
          o.d[y * w + x] = (a[1] - a[0]) * factor + a[0]
      vd.lf[c] = move o

var weightCache: array[17, array[3, seq[float32]]]   # (the default tables, computed once)

proc decodeVarDctHfGlobal(fr: var Frame; st: State; r: var Bits) =
  let f = fr.fh
  let vd = fr.vd
  fr.finalizeLf(st)
  # the quantization tables
  var encs: array[17, QEnc]
  let allDefault = r.flag
  for m in 0 .. 16:
    if allDefault:
      encs[m] = QEnc(mode: 0)
      continue
    let mode = r.bits(3)
    if mode in 1 .. 5 and m notin {0, 1, 2, 3, 9, 10}: fail("damaged JPEG XL (quantization table)")
    var e: QEnc
    case mode
    of 0: e = QEnc(mode: 0)
    of 1: e = QEnc(mode: 1, params: r.readFixed(3))
    of 2: e = QEnc(mode: 2, params: r.readFixed(6))
    of 3:
      e = QEnc(mode: 3, params: r.readFixed(2))
      e.dct = r.readDctParams()
    of 4:
      e = QEnc(mode: 4, params: r.readFixed(1))
      e.dct = r.readDctParams()
    of 5:
      e = QEnc(mode: 5, params: r.readFixed(9))
      for c in 0 .. 2:
        for i in 0 .. 5: e.params[c][i] *= 64
      e.dct = r.readDctParams()
      e.dct4 = r.readDctParams()
    of 6: e = QEnc(mode: 6, dct: r.readDctParams())
    else:
      e = QEnc(mode: 7, den: r.f16())
      if e.den < 1e-8: fail("damaged JPEG XL (quantization table)")
      var img = MImage(bitDepth: 8)
      for c in 0 .. 2: img.ch.add newChannel(MatRx[m] * 8, MatRy[m] * 8)
      decodeModular(r, img, 1 + 3 * f.numLfGroups + m, addr fr.tree)
      if img.ch.len != 3: fail("damaged JPEG XL (quantization table)")
      for c in 0 .. 2: e.raw[c] = img.ch[c].px
    encs[m] = e
  var used: array[17, bool]
  for t in vd.acs:
    if t >= 0: used[AcsMatrix[t]] = true
  for m in 0 .. 16:
    if not used[m]: continue
    if encs[m].mode == 0:
      if weightCache[m][0].len == 0: weightCache[m] = computeWeights(defaultEnc(m), m)
      vd.weights[m] = weightCache[m]
    else:
      vd.weights[m] = computeWeights(encs[m], m)
  # the coefficient orders and distributions of each pass
  vd.numHisto = 1 + r.bits(ceilLog2(f.numGroups))
  vd.orders.setLen(f.numPasses)
  vd.codes.setLen(f.numPasses)
  for p in 0 ..< f.numPasses:
    let usedOrders = r.u32((0x5F, 0), (0x13, 0), (0, 0), (0, 13))
    if usedOrders != 0:
      let c = readCode(r, 8)
      var rd = c.begin(r)
      for o in 0 .. 12:
        if ((usedOrders shr o) and 1) == 0: continue
        let size = OrderW[o] * OrderH[o]
        let nat = naturalOrder(o)
        for ch in 0 .. 2:
          let perm = readPermutation(r, c, rd, size, size div 64)
          var ord = newSeq[uint16](size)
          for i in 0 ..< size: ord[i] = nat[perm[i]]
          vd.orders[p][o][ch] = ord
      c.finish(rd)
    let code = readCode(r, vd.numHisto * 495 * vd.numCtxs)   # (a local first: see `readCode`)
    vd.codes[p] = code
    for k in 0 ..< 16: vd.codes[p].clusters.add 0
  if r.overrun: fail("the JPEG XL file is cut short")
  for c in 0 .. 2:
    vd.planes[c] = newPlaneUninit((f.xblocks * 8) shr f.hs[c], (f.yblocks * 8) shr f.vs[c])
  if f.numPasses > 1: vd.coeffs.setLen(f.numGroups)

proc reconstructGroup(fr: var Frame; st: State; g: int; coeffs: var array[3, seq[int32]]) =
  ## Dequantizes the group's coefficients, adds the LF, inverse transforms, into the planes.
  let f = fr.fh
  let vd = fr.vd
  let h = st.hdr
  let gd = f.gdim
  let gx = g mod f.xgroups
  let gy = g div f.xgroups
  let bx0 = gx * (gd div 8)
  let by0 = gy * (gd div 8)
  let gbw = min(gd div 8, f.xblocks - bx0)
  let gbh = min(gd div 8, f.yblocks - by0)
  let is444 = f.hs == [0, 0, 0] and f.vs == [0, 0, 0]
  let qmScale = [pow(0.8'f32, float32(f.xqm - 2)), 1'f32, pow(0.8'f32, float32(f.bqm - 2))]
  var fbuf: array[3, seq[float32]]
  for c in 0 .. 2: fbuf[c] = newSeqUninit[float32](gd * gd)
  var ydq = newSeqUninit[float32](256 * 256)
  for by in 0 ..< gbh:
    for bx in 0 ..< gbw:
      let fbx = bx0 + bx
      let fby = by0 + by
      let t = int(vd.acs[fby * f.xblocks + fbx])
      if t < 0: continue
      let cx = AcsCx[t]
      let cy = AcsCy[t]
      let W = cx * 8
      let H = cy * 8
      let tr = transposed(t)
      let m = AcsMatrix[t]
      let qf = vd.qf[fby * f.xblocks + fbx]
      let tile = (fby div 8) * vd.xtiles + fbx div 8
      let kx = vd.baseX + float32(vd.ytox[tile]) / vd.colorFactor
      let kb = vd.baseB + float32(vd.ytob[tile]) / vd.colorFactor
      let mulBase = 65536'f32 / (float32(vd.globalScale) * float32(qf))
      for c in [1, 0, 2]:
        let sbx = bx shr f.hs[c]
        let sby = by shr f.vs[c]
        if (sbx shl f.hs[c]) != bx or (sby shl f.vs[c]) != by: continue
        let wts = cast[FBuf](unsafeAddr vd.weights[m][c][0])
        let mul = mulBase * qmScale[c]
        let qb = h.quantBias[c]
        let qn = h.quantBiasNum
        let cf = cast[ptr UncheckedArray[int32]](addr coeffs[c][0])
        let fb = cast[FBuf](addr fbuf[c][0])
        let origin = sby * 8 * gd + sbx * 8
        for py in 0 ..< H:
          for px in 0 ..< W:
            let q = cf[origin + py * gd + px]
            var v: float32
            if q == 0: v = 0
            else:
              v = float32(q)
              if q == 1 or q == -1: v *= qb
              else: v -= qn / v
              let wi = if tr: px * H + py else: py * W + px
              v *= wts[wi] * mul
            if is444:
              if c == 1: ydq[py * W + px] = v
              elif c == 0: v += kx * ydq[py * W + px]
              else: v += kb * ydq[py * W + px]
            fb[origin + py * gd + px] = v
        # the lowest frequencies from the LF image
        let lfp = addr vd.lf[c]
        let lx = (fbx shr f.hs[c])
        let ly = (fby shr f.vs[c])
        if cx == 1 and cy == 1:
          fb[origin] = lfp.d[ly * lfp.w + lx]
        else:
          var llf {.noinit.}: array[1024, float32]
          for y in 0 ..< cy:
            for x in 0 ..< cx: llf[y * cx + x] = lfp.d[(ly + y) * lfp.w + lx + x]
          dct2d(cast[FBuf](addr llf[0]), cx, cx, cy, false)
          let lbx = 5 - ceilLog2(cx)
          let lby = 5 - ceilLog2(cy)
          for y in 0 ..< cy:
            for x in 0 ..< cx:
              fb[origin + y * gd + x] = llf[y * cx + x] / (scaleF(y shl lby) * scaleF(x shl lbx))
        inverseTransform(cast[FBuf](addr fb[origin]), gd, t)
  # into the planes
  for c in 0 .. 2:
    let p = addr vd.planes[c]
    let ox = (bx0 * 8) shr f.hs[c]
    let oy = (by0 * 8) shr f.vs[c]
    let w = min((gbw * 8) shr f.hs[c], p.w - ox)
    let hh = min((gbh * 8) shr f.vs[c], p.h - oy)
    for y in 0 ..< hh:
      copyMem(addr p.d[(oy + y) * p.w + ox], addr fbuf[c][y * gd], w * 4)

proc decodeVarDctPass(fr: var Frame; st: State; r: var Bits; pass, g: int) =
  let f = fr.fh
  let vd = fr.vd
  let gd = f.gdim
  let gx = g mod f.xgroups
  let gy = g div f.xgroups
  let bx0 = gx * (gd div 8)
  let by0 = gy * (gd div 8)
  let gbw = min(gd div 8, f.xblocks - bx0)
  let gbh = min(gd div 8, f.yblocks - by0)
  var local: array[3, seq[int32]]
  let multi = f.numPasses > 1
  if multi and vd.coeffs[g][0].len == 0:
    for c in 0 .. 2: vd.coeffs[g][c] = newSeq[int32](gd * gd)
  if not multi:
    for c in 0 .. 2: local[c] = newSeq[int32](gd * gd)
  let cbuf = if multi: addr vd.coeffs[g] else: addr local
  var sel = 0
  if vd.numHisto > 1:
    sel = r.bits(ceilLog2(vd.numHisto))
    if sel >= vd.numHisto: fail("damaged JPEG XL (histogram selector)")
  let numCtxs = vd.numCtxs
  let ctxOffset = sel * 495 * numCtxs
  let code = addr vd.codes[pass]
  var rd = code[].begin(r)
  let shift = if pass < f.shift.len: f.shift[pass] else: 0
  var nz: array[3, seq[int32]]
  var nzw: array[3, int]
  for c in 0 .. 2:
    nzw[c] = max(1, cdiv(gbw, 1 shl f.hs[c]))
    nz[c] = newSeq[int32](nzw[c] * max(1, cdiv(gbh, 1 shl f.vs[c])))
  let nq = vd.qfThresh.len
  for by in 0 ..< gbh:
    for bx in 0 ..< gbw:
      let fbx = bx0 + bx
      let fby = by0 + by
      let t = int(vd.acs[fby * f.xblocks + fbx])
      if t < 0:
        if t == -2: fail("damaged JPEG XL (no transform for a block)")
        continue
      let cx = AcsCx[t]
      let cy = AcsCy[t]
      let covered = cx * cy
      let lg = ceilLog2(covered)
      let size = covered * 64
      let ord = AcsOrder[t]
      let tr = transposed(t)
      let lfIdx = int(vd.lfIdx[fby * f.xblocks + fbx])
      for c in [1, 0, 2]:
        let sbx = bx shr f.hs[c]
        let sby = by shr f.vs[c]
        if (sbx shl f.hs[c]) != bx or (sby shl f.vs[c]) != by: continue
        let nzr = addr nz[c]
        let w = nzw[c]
        var predicted: int
        if sbx == 0:
          predicted = if sby == 0: 32 else: int(nzr[][(sby - 1) * w])
        elif sby == 0:
          predicted = int(nzr[][sbx - 1])
        else:
          predicted = (int(nzr[][(sby - 1) * w + sbx]) + int(nzr[][sby * w + sbx - 1]) + 1) div 2
        let qfv = vd.qf[fby * f.xblocks + bx0 + sbx]
        var qfIdx = 0
        for th in vd.qfThresh:
          if qfv > th: inc qfIdx
        let cidx = if c < 2: c xor 1 else: 2
        let blockCtx = int(vd.ctxMap[((cidx * 13 + ord) * (nq + 1) + qfIdx) * vd.numDcCtx + lfIdx])
        let p = min(predicted, 64)
        let nzCtx = (if p < 8: p else: 4 + p div 2) * numCtxs + blockCtx + ctxOffset
        var nzeros = int(code[].hybrid(rd, r, nzCtx))
        if nzeros > size - covered: fail("damaged JPEG XL (too many coefficients)")
        let nzv = int32((nzeros + covered - 1) shr lg)
        for y in 0 ..< cy:
          for x in 0 ..< cx:
            let i = (sby + y) * w + sbx + x
            if i < nzr[].len: nzr[][i] = nzv
        if nzeros == 0: continue
        let histo = ctxOffset + numCtxs * 37 + 458 * blockCtx
        let order = if vd.orders[pass][ord][c].len > 0: cast[ptr UncheckedArray[uint16]](addr vd.orders[pass][ord][c][0])
                    else: cast[ptr UncheckedArray[uint16]](unsafeAddr naturalOrder(ord)[0])
        var prev = if nzeros > size div 16: 0 else: 1
        let cf = cast[ptr UncheckedArray[int32]](addr cbuf[][c][0])
        let origin = sby * 8 * gd + sbx * 8
        var k = covered
        while k < size and nzeros != 0:
          let ctx = histo + (CoeffNumNonzeroCtx[(nzeros + covered - 1) shr lg] + CoeffFreqCtx[k shr lg]) * 2 + prev
          let u = code[].hybrid(rd, r, ctx)
          if u != 0:
            let o = int(order[k])
            var x = o and 255
            var y = o shr 8
            if tr: swap(x, y)
            cf[origin + y * gd + x] += unpackSigned(u) shl shift
            prev = 1
            dec nzeros
          else: prev = 0
          inc k
        if nzeros != 0: fail("damaged JPEG XL (coefficients)")
    if r.overrun: fail("the JPEG XL file is cut short")
  code[].finish(rd)
  if not multi: fr.reconstructGroup(st, g, local)
  elif pass == f.numPasses - 1: fr.reconstructGroup(st, g, vd.coeffs[g])

proc finishVarDct(fr: var Frame; st: State; img: var FImage) =
  let vd = fr.vd
  for c in 0 .. 2: img.p[c] = move vd.planes[c]
  vd.coeffs.setLen(0)

proc epfSigma(fr: Frame): (seq[float32], int) =
  ## kInvSigmaNum / sigma of each 8x8 block (as libjxl's ComputeSigma).
  let f = fr.fh
  if f.modular:
    let bw = cdiv(f.sw, 8)
    var s = newSeq[float32](bw * cdiv(f.sh, 8))
    for v in s.mitems: v = InvSigmaNum / f.epfSigmaModular
    return (s, bw)
  let vd = fr.vd
  var s = newSeq[float32](f.xblocks * f.yblocks)
  let quantScale = float32(vd.globalScale) / 65536'f32
  for by in 0 ..< f.yblocks:
    for bx in 0 ..< f.xblocks:
      let t = int(vd.acs[by * f.xblocks + bx])
      if t < 0: continue
      let sq = f.epfQuantMul / (quantScale * float32(vd.qf[by * f.xblocks + bx]) * InvSigmaNum)
      for iy in 0 ..< AcsCy[t]:
        for ix in 0 ..< AcsCx[t]:
          let i = (by + iy) * f.xblocks + bx + ix
          let sigma = min(-1e-4'f32, sq * f.epfSharp[vd.sharp[i]])
          s[i] = 1'f32 / sigma
  (s, f.xblocks)


# ---- patches ---------------------------------------------------------------------------------

proc readPatches(fr: var Frame; st: State; r: var Bits) =
  let f = fr.fh
  let numEc = st.hdr.ec.len
  let xs = if f.modular: f.sw else: f.xblocks * 8
  let ys = if f.modular: f.sh else: f.yblocks * 8
  let c = readCode(r, 10)
  var rd = c.begin(r)
  let numRef = int(c.hybrid(rd, r, 0))
  let maxRef = 1024 + xs * ys div 4
  if numRef > maxRef: fail("damaged JPEG XL (patches)")
  var total = 0
  for id in 0 ..< numRef:
    let slot = int(c.hybrid(rd, r, 1))
    if slot >= 4 or not st.refs[slot].used or not st.refs[slot].beforeCt:
      fail("damaged JPEG XL (patch reference)")
    let src = addr st.refs[slot].img
    let rx = int(c.hybrid(rd, r, 3))
    let ry = int(c.hybrid(rd, r, 3))
    let w = int(c.hybrid(rd, r, 2)) + 1
    let h = int(c.hybrid(rd, r, 2)) + 1
    if rx + w > src.w or ry + h > src.h: fail("damaged JPEG XL (patch reference)")
    let count = int(c.hybrid(rd, r, 7)) + 1
    total += count
    if total > maxRef * 4: fail("damaged JPEG XL (patches)")
    for i in 0 ..< count:
      var p = Patch(slot: slot, rx: rx, ry: ry, w: w, h: h)
      if i == 0:
        p.x = int(c.hybrid(rd, r, 4))
        p.y = int(c.hybrid(rd, r, 4))
      else:
        p.x = fr.patches[^1].x + unpackSigned(c.hybrid(rd, r, 6))
        p.y = fr.patches[^1].y + unpackSigned(c.hybrid(rd, r, 6))
      if p.x < 0 or p.y < 0 or p.x + w > xs or p.y + h > ys: fail("damaged JPEG XL (patch position)")
      for j in 0 .. numEc:
        var b = BlendLike(mode: int(c.hybrid(rd, r, 5)))
        if b.mode >= 8: fail("damaged JPEG XL (patch blending)")
        let usesAlpha = b.mode >= 4
        if usesAlpha and numEc > 1:
          b.alpha = int(c.hybrid(rd, r, 8))
          if b.alpha >= numEc: fail("damaged JPEG XL (patch blending)")
        if usesAlpha or b.mode == 3: b.clamp = c.hybrid(rd, r, 9) != 0
        p.blends.add b
      fr.patches.add p
    if r.overrun: fail("the JPEG XL file is cut short")
  c.finish(rd)

proc applyPatches(fr: var Frame; st: State; img: var FImage) =
  let numEc = st.hdr.ec.len
  var bg, fg: Rows
  bg.setLen(3 + numEc)
  fg.setLen(3 + numEc)
  for p in fr.patches:
    let src = addr st.refs[p.slot].img
    if src.p.len < 3 + numEc: fail("damaged JPEG XL (patch reference)")
    let w = min(p.w, img.p[0].w - p.x)
    if w <= 0: continue
    for c in 3 ..< 3 + numEc:
      if img.p[c].w != img.p[0].w or img.p[c].h != img.p[0].h:
        fail("JPEG XL patches over extra channels of another size")
    let ec = p.blends[1 .. ^1]
    for iy in 0 ..< p.h:
      let y = p.y + iy
      if y >= img.p[0].h: break
      for c in 0 ..< 3 + numEc:
        bg[c] = cast[ptr UncheckedArray[float32]](addr img.p[c].d[y * img.p[c].w + p.x])
        fg[c] = cast[ptr UncheckedArray[float32]](addr src.p[c].d[(p.ry + iy) * src.p[c].w + p.rx])
      performBlending(bg, fg, bg, w, p.blends[0], ec, st.hdr)


# ---- noise -----------------------------------------------------------------------------------

proc readNoise(fr: var Frame; r: var Bits) =
  for i in 0 .. 7: fr.noiseLut[i] = float32(r.bits(10)) / 1024

proc splitMix64(z: uint64): uint64 =
  var z = (z xor (z shr 30)) * 0xBF58476D1CE4E5B9'u64
  z = (z xor (z shr 27)) * 0x94D049BB133111EB'u64
  z xor (z shr 31)

type Xorshift = object
  s0, s1: array[8, uint64]

proc initXorshift(seed0, seed1: uint64): Xorshift =
  result.s0[0] = splitMix64(seed0 + 0x9E3779B97F4A7C15'u64)
  result.s1[0] = splitMix64(seed1 + 0x9E3779B97F4A7C15'u64)
  for i in 1 .. 7:
    result.s0[i] = splitMix64(result.s0[i - 1])
    result.s1[i] = splitMix64(result.s1[i - 1])

proc fill(g: var Xorshift; o: var array[16, uint32]) =
  for i in 0 .. 7:
    var s1 = g.s0[i]
    let s0 = g.s1[i]
    let v = s1 + s0
    g.s0[i] = s0
    s1 = s1 xor (s1 shl 23)
    g.s1[i] = s1 xor (s0 xor (s1 shr 18) xor (s0 shr 5))
    o[2 * i] = uint32(v and 0xFFFFFFFF'u64)
    o[2 * i + 1] = uint32(v shr 32)

proc addNoise(fr: var Frame; st: State; img: var FImage) =
  let w = img.w
  let h = img.h
  let gd = fr.fh.gdim
  var noise: array[3, Plane]
  for c in 0 .. 2: noise[c] = newPlane(w, h)
  let seed0 = (uint64(st.visible) shl 32) + uint64(st.invisible)
  var bits: array[16, uint32]
  for ty in 0 ..< cdiv(h, gd):
    for tx in 0 ..< cdiv(w, gd):
      let x0 = tx * gd
      let y0 = ty * gd
      let tw = min(gd, w - x0)
      let th = min(gd, h - y0)
      var g = initXorshift(seed0, (uint64(x0) shl 32) + uint64(y0))
      for c in 0 .. 2:
        for y in 0 ..< th:
          for b in 0 ..< cdiv(tw, 16):
            g.fill(bits)
            for k in 0 .. 15:
              let x = b * 16 + k
              if x < tw:
                noise[c].d[(y0 + y) * w + x0 + x] = cast[float32]((bits[k] shr 9) or 0x3F800000'u32)
  # 4 (1 - the 5x5 box): the noise's high frequencies
  for c in 0 .. 2:
    let src = noise[c].padded(2)
    let sw = src.w
    for y in 0 ..< h:
      for x in 0 ..< w:
        var sum = 0'f32
        for dy in 0 .. 4:
          for dx in 0 .. 4: sum += src.d[(y + dy) * sw + x + dx]
        noise[c].d[y * w + x] = sum * 0.16'f32 - src.d[(y + 2) * sw + x + 2] * 4'f32
  var lut: array[9, float32]
  for i in 0 .. 7: lut[i] = fr.noiseLut[i]
  lut[8] = lut[7]
  let corrX = if fr.vd != nil: fr.vd.baseX else: 0'f32
  let corrB = if fr.vd != nil: fr.vd.baseB else: 1'f32
  proc strength(lut: array[9, float32]; v: float32): float32 =
    let s = max(0'f32, v * 3)
    let i = min(int(s), 7)
    let f = s - float32(i)
    max(0'f32, min(1'f32, (lut[i + 1] - lut[i]) * f + lut[i]))
  for i in 0 ..< w * h:
    let x = img.p[0].d[i]
    let y = img.p[1].d[i]
    let sr = strength(lut, x + y)
    let sg = strength(lut, y - x)
    let nr = 0.22'f32 * sr * (0.0078125'f32 * noise[0].d[i] + 0.9921875'f32 * noise[2].d[i])
    let ng = 0.22'f32 * sg * (0.0078125'f32 * noise[1].d[i] + 0.9921875'f32 * noise[2].d[i])
    let rg = nr + ng
    img.p[0].d[i] += corrX * rg + nr - ng
    img.p[1].d[i] += rg
    img.p[2].d[i] += corrB * rg


# ==== writing ====================================================================================

var log2Tab: array[4096, float32]
for i in 1 ..< 4096: log2Tab[i] = float32(log2(float(i)))

proc lg2(x: int): float {.inline.} =
  if x < 4096: float(log2Tab[x]) else: log2(float(x))

type
  BitWriter = object
    ## Bits written from the lowest of each byte up.
    data: string
    acc: uint64
    n: int

proc put(w: var BitWriter; v: uint64; nbits: int) {.inline.} =
  if nbits == 0: return
  w.acc = w.acc or ((v and ((1'u64 shl nbits) - 1)) shl w.n)
  w.n += nbits
  while w.n >= 8:
    w.data.add char(w.acc and 0xFF)
    w.acc = w.acc shr 8
    w.n -= 8

proc put(w: var BitWriter; v: int; nbits: int) {.inline.} = w.put(uint64(v), nbits)
proc putBool(w: var BitWriter; b: bool) {.inline.} = w.put(ord(b), 1)

proc padToByte(w: var BitWriter) =
  if w.n > 0: w.put(0, 8 - w.n)

proc bytes(w: var BitWriter): string =
  w.padToByte()
  w.data

proc putU32(w: var BitWriter; v: int; d0, d1, d2, d3: Dist) =
  let ds = [d0, d1, d2, d3]
  for i, d in ds:
    if v >= d.off and v - d.off < (1 shl d.n):
      w.put(i, 2)
      w.put(v - d.off, d.n)
      return
  raise newException(JxlError, "a value too large to write")

proc putU64(w: var BitWriter; v: uint64) =
  if v == 0: w.put(0, 2)
  elif v <= 16:
    w.put(1, 2)
    w.put(v - 1, 4)
  elif v <= 272:
    w.put(2, 2)
    w.put(v - 17, 8)
  else:
    w.put(3, 2)
    w.put(v and 4095, 12)
    var rest = v shr 12
    var shift = 12
    while rest != 0:
      w.put(1, 1)
      if shift == 60:
        w.put(rest and 15, 4)
        return
      w.put(rest and 255, 8)
      rest = rest shr 8
      shift += 8
    w.put(0, 1)

proc packSigned(v: int64): uint32 {.inline.} =
  if v >= 0: uint32(2 * v) else: uint32(-2 * v - 1)

# -- integers as tokens and raw bits (the hybrid uint configuration 4, 2, 0)

const
  EncSplitExp = 4
  EncMsb = 2
  EncLsb = 0

proc tokenOf(v: uint32): (int, int, uint32) {.inline.} =
  ## (token, extra bit count, extra bits) of v.
  if v < (1'u32 shl EncSplitExp): return (int(v), 0, 0'u32)
  let n = floorLog2(uint64(v))
  let m = v - (1'u32 shl n)
  let token = (1 shl EncSplitExp) + ((n - EncSplitExp) shl (EncMsb + EncLsb)) +
              int((m shr (n - EncMsb)) shl EncLsb) + int(m and ((1'u32 shl EncLsb) - 1))
  let nb = n - EncMsb - EncLsb
  (token, nb, (m shr EncLsb) and ((1'u32 shl nb) - 1))

# -- prefix codes

proc huffmanLengths(counts: openArray[int]; maxLen: int): seq[int] =
  ## Code lengths of an optimal prefix code no longer than maxLen (counts
  ## halved until it fits).
  result = newSeq[int](counts.len)
  var used: seq[int]
  for i, c in counts:
    if c > 0: used.add i
  if used.len == 0: return
  if used.len == 1:
    result[used[0]] = 1
    return
  var c = newSeq[int](counts.len)
  for i in 0 ..< counts.len: c[i] = counts[i]
  while true:
    used.sort(proc (a, b: int): int = cmp(c[a], c[b]))
    # two queues: the leaves in order, and the merged nodes (made in order)
    let n = used.len
    var weight = newSeq[int](2 * n)
    var parent = newSeq[int](2 * n)
    for i, s in used: weight[i] = c[s]
    var leafAt = 0
    var nodeAt = n
    var made = n
    proc take(weight: seq[int]; leafAt, nodeAt: var int; n, made: int): int =
      if leafAt < n and (nodeAt >= made or weight[leafAt] <= weight[nodeAt]):
        result = leafAt
        inc leafAt
      else:
        result = nodeAt
        inc nodeAt
    for _ in 0 ..< n - 1:
      let a = take(weight, leafAt, nodeAt, n, made)
      let b = take(weight, leafAt, nodeAt, n, made)
      weight[made] = weight[a] + weight[b]
      parent[a] = made
      parent[b] = made
      inc made
    var depth = newSeq[int](made)
    for i in countdown(made - 2, 0): depth[i] = depth[parent[i]] + 1
    var deepest = 0
    for i in 0 ..< n:
      result[used[i]] = depth[i]
      deepest = max(deepest, depth[i])
    if deepest <= maxLen: return
    for i in used: c[i] = max(1, c[i] shr 1)

proc canonicalCodes(lengths: openArray[int]): seq[uint32] =
  ## Each symbol's code, bits reversed (written from the lowest bit up).
  result = newSeq[uint32](lengths.len)
  var count: array[16, int]
  for l in lengths: inc count[l]
  count[0] = 0
  var next: array[17, int]
  var code = 0
  for l in 1 .. 15:
    next[l] = code
    code = (code + count[l]) shl 1
  for s, l in lengths:
    if l > 0:
      let c = next[l]
      inc next[l]
      var rev = 0
      for i in 0 ..< l: rev = (rev shl 1) or ((c shr i) and 1)
      result[s] = uint32(rev)

proc writePrefixCode(w: var BitWriter; lengths: seq[int]) =
  ## One prefix code as JPEG XL (Brotli) stores it; the alphabet is lengths.len > 1.
  var used = 0
  var last = 0
  for i, l in lengths:
    if l > 0:
      inc used
      last = i
  if used == 1:
    w.put(1, 2)                                   # a simple code
    w.put(0, 2)                                   # of one symbol
    w.put(last, ceilLog2(lengths.len))
    return
  # the code lengths, run-length coded as Brotli does
  var syms, extras: seq[int]
  var i = 0
  var prev = 8
  while i <= last:
    let v = lengths[i]
    var reps = 1
    while i + reps <= last and lengths[i + reps] == v: inc reps
    i += reps
    if v == 0:
      var r = reps
      if r == 11:
        syms.add 0
        extras.add 0
        dec r
      if r < 3:
        for _ in 0 ..< r:
          syms.add 0
          extras.add 0
      else:
        let start = syms.len
        r -= 3
        while true:
          syms.add 17
          extras.add r and 7
          r = r shr 3
          if r == 0: break
          dec r
        syms.reverse(start, syms.high)
        extras.reverse(start, extras.high)
    else:
      var r = reps
      if prev != v:
        syms.add v
        extras.add 0
        dec r
      if r == 7:
        syms.add v
        extras.add 0
        dec r
      if r < 3:
        for _ in 0 ..< r:
          syms.add v
          extras.add 0
      else:
        let start = syms.len
        r -= 3
        while true:
          syms.add 16
          extras.add r and 3
          r = r shr 2
          if r == 0: break
          dec r
        syms.reverse(start, syms.high)
        extras.reverse(start, extras.high)
      prev = v
  var clCounts = newSeq[int](18)
  for s in syms: inc clCounts[s]
  let clLens = huffmanLengths(clCounts, 5)
  const order = [1, 2, 3, 4, 0, 5, 17, 6, 16, 7, 8, 9, 10, 11, 12, 13, 14, 15]
  var nonzero = 0
  for l in clLens:
    if l > 0: inc nonzero
  var hskip = 0
  if clLens[1] == 0 and clLens[2] == 0:
    hskip = if clLens[3] == 0: 3 else: 2
  w.put(hskip, 2)
  var acc = 0
  for k in hskip ..< 18:
    let l = clLens[order[k]]
    case l
    of 0: w.put(0, 2)
    of 4: w.put(1, 2)
    of 3: w.put(2, 2)
    of 2:
      w.put(3, 2)
      w.put(0, 1)
    of 1:
      w.put(3, 2)
      w.put(1, 1)
      w.put(0, 1)
    else:
      w.put(3, 2)
      w.put(1, 1)
      w.put(1, 1)
    if l != 0 and nonzero > 1:
      acc += 32 shr l
      if acc == 32: break
  let clCodes = canonicalCodes(clLens)
  for k, s in syms:
    if nonzero > 1: w.put(uint64(clCodes[s]), clLens[s])
    if s == 16: w.put(extras[k], 2)
    elif s == 17: w.put(extras[k], 3)

type
  EncCode = object
    ## A written entropy code: contexts to clusters; a prefix code or an ANS
    ## distribution for each cluster.
    clusters: seq[int]
    lens: seq[seq[int]]
    codes: seq[seq[uint32]]
    ans: bool
    freq: seq[seq[int]]                    # ANS: each token's share of 4096
    rev: seq[seq[seq[uint16]]]             # ANS: the state slot of each token and offset
  TokenBuf = object
    ## An ANS stream's tokens, written backwards when it is complete.
    cl: seq[uint8]
    tok: seq[uint8]
    nb: seq[uint8]
    extra: seq[uint32]

proc writeSymbol(w: var BitWriter; e: EncCode; ctx: int; v: uint32) {.inline.} =
  let (t, nb, extra) = tokenOf(v)
  let cl = e.clusters[ctx]
  w.put(uint64(e.codes[cl][t]), e.lens[cl][t])
  w.put(uint64(extra), nb)

proc add(b: var TokenBuf; e: EncCode; ctx: int; v: uint32) {.inline.} =
  let (t, nb, extra) = tokenOf(v)
  b.cl.add uint8(e.clusters[ctx])
  b.tok.add uint8(t)
  b.nb.add uint8(nb)
  b.extra.add extra

proc flush(w: var BitWriter; e: EncCode; b: var TokenBuf) =
  ## The stream: the final ANS state, then each token's renormalization and raw bits.
  let n = b.tok.len
  var outs = newSeq[int32](n)              # -1: none
  var x = 0x130000'u32
  for i in countdown(n - 1, 0):
    let cl = int(b.cl[i])
    let t = int(b.tok[i])
    let f = uint32(e.freq[cl][t])
    outs[i] = -1
    if (x shr 20) >= f:
      outs[i] = int32(x and 0xFFFF)
      x = x shr 16
    x = ((x div f) shl 12) + uint32(e.rev[cl][t][int(x mod f)])
  w.put(uint64(x), 32)
  for i in 0 ..< n:
    if outs[i] >= 0: w.put(uint64(outs[i]), 16)
    w.put(uint64(b.extra[i]), int(b.nb[i]))
  b = TokenBuf()

proc normalize(counts: seq[int]): seq[int] =
  ## Shares of 4096, none of a used token below 1.
  var total = 0
  for c in counts: total += c
  result = newSeq[int](counts.len)
  if total == 0:
    result[0] = 4096
    return
  var sum = 0
  var big = 0
  for i, c in counts:
    if c > 0:
      result[i] = max(1, int(float(c) * 4096 / float(total) + 0.5))
      sum += result[i]
      if result[i] > result[big]: big = i
  var diff = 4096 - sum
  if result[big] + diff >= 1:
    result[big] += diff
  else:
    # too many tiny shares: take from the large ones
    result[big] = 1
    diff = 4096 - (sum - result[big] + 1)
    while diff < 0:
      var m = 0
      for i in 0 ..< result.len:
        if result[i] > result[m]: m = i
      let take = min(-diff, result[m] - 1)
      result[m] -= take
      diff += take

proc writeU8(w: var BitWriter; v: int) =
  if v == 0: w.put(0, 1)
  else:
    let n = floorLog2(uint64(v))
    w.put(1, 1)
    w.put(n, 3)
    w.put(v - (1 shl n), n)

const LogCountBits = [1 + 2 + 1, 3 + 1, 3 + 1, 3 + 1, 3 + 1, 3 + 1, 3, 3, 3, 3, 3, 3 + 3, 3 + 4]
  ## (the bits of each log count's code, 0 .. 12)

proc quantizeAns(d: seq[int]; shift: int; q: var seq[int]; omit: var int): bool =
  ## d (shares of 4096) as precise as `shift` lets them be stored; false when it cannot.
  q = d
  var lc = newSeq[int](d.len)
  omit = 0
  for i, v in d:
    lc[i] = if v == 0: 0 else: floorLog2(uint64(v)) + 1
    if lc[i] > lc[omit]: omit = i
  var sum = 0
  for i, v in d:
    if i == omit or v == 0: continue
    if v > 1:
      let zeros = lc[i] - 1
      let bc = clamp(shift - ((12 - zeros) shr 1), 0, zeros)
      let unit = 1 shl (zeros - bc)
      q[i] = max(1, ((v + unit div 2) div unit) * unit)
    sum += q[i]
  q[omit] = 4096 - sum
  if q[omit] < 1: return false
  # the omitted one must stay the first of the largest log counts
  let lo = floorLog2(uint64(q[omit])) + 1
  for i, v in q:
    if i == omit or v == 0: continue
    let l = floorLog2(uint64(v)) + 1
    if l > lo or (l == lo and i < omit): return false
  true

proc writeAnsHisto(w: var BitWriter; d: seq[int]; counts: seq[int]): seq[int] =
  ## A distribution (shares of 4096) as JPEG XL stores it, at the precision
  ## that costs the fewest bits; the distribution as stored.
  var nz: seq[int]
  for i, v in d:
    if v > 0: nz.add i
  if nz.len == 1:
    w.put(1, 1)
    w.put(0, 1)
    w.writeU8(nz[0])
    return d
  if nz.len == 2:
    w.put(1, 1)
    w.put(1, 1)
    w.writeU8(nz[0])
    w.writeU8(nz[1])
    w.put(d[nz[0]], 12)
    return d
  var bestShift = 13
  var bestCost = Inf
  var bestQ: seq[int]
  var bestOmit = 0
  for shift in 0 .. 13:
    var q: seq[int]
    var omit: int
    if not quantizeAns(d, shift, q, omit): continue
    var cost = 0.0
    for i, v in q:
      if v > 0:
        cost += float(counts[i]) * (12 - lg2(v))
        if i != omit and v > 1:
          let zeros = floorLog2(uint64(v))
          cost += float(clamp(shift - ((12 - zeros) shr 1), 0, zeros))
        cost += float(LogCountBits[min(12, floorLog2(uint64(v)) + 1)])
    if cost < bestCost:
      bestCost = cost
      bestShift = shift
      bestQ = q
      bestOmit = omit
  if bestQ.len == 0: raise newException(JxlError, "internal: no ANS precision fits")
  let q = bestQ
  w.put(0, 1)
  w.put(0, 1)
  # the shift: (1 shl len) - 1 + len bits
  var len = 0
  while len < 3 and bestShift >= (1 shl (len + 1)) - 1: inc len
  for _ in 0 ..< len: w.put(1, 1)
  if len < 3: w.put(0, 1)
  w.put(bestShift - ((1 shl len) - 1), len)
  let alphabet = nz[^1] + 1
  w.writeU8(alphabet - 3)
  var lc = newSeq[int](alphabet)
  for i in 0 ..< alphabet:
    lc[i] = if q[i] == 0: 0 else: floorLog2(uint64(q[i])) + 1
  for i in 0 ..< alphabet:
    case lc[i]
    of 10: w.put(0, 3)
    of 4: w.put(1, 3); w.put(1, 1)
    of 0: w.put(1, 3); w.put(0, 1); w.put(1, 1)
    of 11: w.put(1, 3); w.put(0, 2); w.put(1, 1)
    of 12: w.put(1, 3); w.put(0, 4)
    of 7: w.put(2, 3)
    of 1: w.put(3, 3); w.put(1, 1)
    of 3: w.put(3, 3); w.put(0, 1)
    of 6: w.put(4, 3)
    of 8: w.put(5, 3)
    of 9: w.put(6, 3)
    of 2: w.put(7, 3); w.put(1, 1)
    else: w.put(7, 3); w.put(0, 1)             # 5
  for i in 0 ..< alphabet:
    if lc[i] > 1 and i != bestOmit:
      let zeros = lc[i] - 1
      let bc = clamp(bestShift - ((12 - zeros) shr 1), 0, zeros)
      w.put((q[i] - (1 shl zeros)) shr (zeros - bc), bc)
  q

proc histoCost(h: openArray[int]): float =
  ## The bits a histogram's symbols take with a code made for them, and the code.
  var total = 0
  var nz = 0
  for c in h:
    if c > 0:
      total += c
      inc nz
      result -= float(c) * lg2(c)
  if total == 0: return 0
  result += float(total) * lg2(total) + float(nz) * 5 + 16

proc mergedCost(a, b: seq[int]): float =
  var total = 0
  var nz = 0
  for i in 0 ..< max(a.len, b.len):
    let c = (if i < a.len: a[i] else: 0) + (if i < b.len: b[i] else: 0)
    if c > 0:
      total += c
      inc nz
      result -= float(c) * lg2(c)
  if total == 0: return 0
  result += float(total) * lg2(total) + float(nz) * 5 + 16

proc clusterHistograms(hs: seq[seq[int]]; maxClusters: int): seq[int] =
  ## Contexts to clusters: the pair of clusters whose merging saves the most
  ## bits merged, while that saves bits (and while there are too many).
  let n = hs.len
  result = newSeq[int](n)
  var groups: seq[seq[int]]
  var members: seq[seq[int]]
  for i in 0 ..< n:
    var empty = true
    for c in hs[i]:
      if c > 0: empty = false
    if empty and groups.len > 0:
      members[0].add i
      continue
    groups.add hs[i]
    members.add @[i]
  var k = groups.len
  var cost = newSeq[float](k)
  for i in 0 ..< k: cost[i] = histoCost(groups[i])
  var delta = newSeq[float](k * k)
  for i in 0 ..< k:
    for j in i + 1 ..< k: delta[i * k + j] = mergedCost(groups[i], groups[j]) - cost[i] - cost[j]
  var alive = newSeq[bool](k)
  for i in 0 ..< k: alive[i] = true
  var count = k
  while count > 1:
    var best = Inf
    var bi, bj = -1
    for i in 0 ..< k:
      if not alive[i]: continue
      for j in i + 1 ..< k:
        if alive[j] and delta[i * k + j] < best:
          best = delta[i * k + j]
          bi = i
          bj = j
    if best > 0 and count <= maxClusters: break
    var m = newSeq[int](max(groups[bi].len, groups[bj].len))
    for t in 0 ..< groups[bi].len: m[t] += groups[bi][t]
    for t in 0 ..< groups[bj].len: m[t] += groups[bj][t]
    groups[bi] = m
    members[bi].add members[bj]
    alive[bj] = false
    dec count
    cost[bi] = histoCost(m)
    for o in 0 ..< k:
      if alive[o] and o != bi:
        let (a, b) = if o < bi: (o, bi) else: (bi, o)
        delta[a * k + b] = mergedCost(groups[a], groups[b]) - cost[a] - cost[b]
  var g = 0
  for i in 0 ..< k:
    if alive[i]:
      for m in members[i]: result[m] = g
      inc g

proc writeEntropyCode(w: var BitWriter; numCtx: int; hs: seq[seq[int]]; maxClusters = 255;
                      ans = false; alias: seq[int] = @[]): EncCode

proc writeClusters(w: var BitWriter; map: seq[int]) =
  if map.len == 1: return
  var nc = 0
  for v in map: nc = max(nc, v + 1)
  if nc <= 8:
    w.put(1, 1)
    let nbits = ceilLog2(nc)
    w.put(nbits, 2)
    for v in map: w.put(v, nbits)
  else:
    w.put(0, 1)
    w.put(0, 1)                                  # no move-to-front
    var h = newSeq[int](256)
    for v in map: inc h[tokenOf(uint32(v))[0]]
    let e = writeEntropyCode(w, 1, @[h], 1)
    for v in map: w.writeSymbol(e, 0, uint32(v))

proc writeEntropyCode(w: var BitWriter; numCtx: int; hs: seq[seq[int]]; maxClusters = 255;
                      ans = false; alias: seq[int] = @[]): EncCode =
  ## Writes the distributions of numCtx contexts (token histograms `hs`), as
  ## prefix codes or (`ans`) ANS distributions. A context i with alias[i] != i
  ## shares the distribution of context alias[i] (its own histogram is empty).
  result.clusters = clusterHistograms(hs, maxClusters)
  if alias.len > 0:
    for i, a in alias: result.clusters[i] = result.clusters[a]
    var renum = newSeq[int](result.clusters.len)   # (libjxl wants every cluster used)
    for v in renum.mitems: v = -1
    var next = 0
    for c in result.clusters.mitems:
      if renum[c] < 0:
        renum[c] = next
        inc next
      c = renum[c]
  var nc = 0
  for v in result.clusters: nc = max(nc, v + 1)
  var ch = newSeq[seq[int]](nc)
  for i in 0 ..< nc: ch[i] = newSeq[int](1)
  for i, h in hs:
    let c = result.clusters[i]
    if ch[c].len < h.len: ch[c].setLen(h.len)
    for t, v in h: ch[c][t] += v
  w.put(0, 1)                                    # no LZ77
  w.writeClusters(result.clusters)
  if ans:
    var most = 0
    for h in ch:
      for t, v in h:
        if v > 0: most = max(most, t)
    let logAlpha = max(5, ceilLog2(most + 1))
    if logAlpha > 8: raise newException(JxlError, "internal: too many tokens for ANS")
    w.put(0, 1)                                  # ANS
    w.put(logAlpha - 5, 2)
    for i in 0 ..< nc:
      w.put(EncSplitExp, addLog2Ceil(logAlpha))
      w.put(EncMsb, addLog2Ceil(EncSplitExp))
      w.put(EncLsb, addLog2Ceil(EncSplitExp - EncMsb))
    result.ans = true
    result.freq = newSeq[seq[int]](nc)
    result.rev = newSeq[seq[seq[uint16]]](nc)
    for i in 0 ..< nc:
      var counts = ch[i]
      counts.setLen(1 shl logAlpha)
      let d = w.writeAnsHisto(normalize(counts), counts)
      var hd: Histo
      hd.buildAlias(d, logAlpha)
      result.freq[i] = d
      result.rev[i] = newSeq[seq[uint16]](d.len)
      for t in 0 ..< d.len: result.rev[i][t] = newSeq[uint16](d[t])
      let bucket = 1 shl hd.logBucket
      for j in 0 ..< 4096:
        let e = hd.ans[j shr hd.logBucket]
        let pos = int32(j and (bucket - 1))
        if pos < e.cutoff: result.rev[i][j shr hd.logBucket][pos] = uint16(j)
        else: result.rev[i][e.rightSym][e.rightOff + pos] = uint16(j)
    return
  w.put(1, 1)                                    # prefix codes
  for i in 0 ..< nc:                             # the integer configuration
    w.put(EncSplitExp, 4)
    w.put(EncMsb, 3)
    w.put(EncLsb, 2)
  result.lens = newSeq[seq[int]](nc)
  result.codes = newSeq[seq[uint32]](nc)
  var alphabets = newSeq[int](nc)
  for i in 0 ..< nc:
    var last = 0
    for t, v in ch[i]:
      if v > 0: last = t
    alphabets[i] = last + 1
    let a = alphabets[i]
    if a == 1: w.put(0, 1)
    else:
      w.put(1, 1)
      let n = floorLog2(uint64(a - 1))
      w.put(n, 4)
      w.put(a - 1 - (1 shl n), n)
  for i in 0 ..< nc:
    let a = alphabets[i]
    var counts = ch[i][0 ..< a]
    if a == 1:
      result.lens[i] = @[0]
      result.codes[i] = @[0'u32]
      continue
    var lens = huffmanLengths(counts, 15)
    var used = 0
    for l in lens:
      if l > 0: inc used
    if used == 0:
      lens[0] = 1
      used = 1
    w.writePrefixCode(lens)
    if used == 1:
      for l in lens.mitems:
        if l > 0: l = 0
    result.lens[i] = lens
    result.codes[i] = canonicalCodes(lens)


# -- the MA tree, as the encoder builds it

type
  ENode = ref object
    prop: int                  # -1 for a leaf
    split: int32
    left, right: ENode         # left: property > split
    pred: int
    mult: int                  # (a leaf) what its residuals are multiplied by; 0 as 1

proc leaf(pred: int): ENode = ENode(prop: -1, pred: pred)

proc chainChannels(subs: seq[ENode]; first: int): ENode =
  ## Subtrees chosen by property 0 (the channel): subs[i] for channel first + i.
  if subs.len == 1: return subs[0]
  let mid = subs.len div 2
  ENode(prop: 0, split: int32(first + mid - 1), left: chainChannels(subs[mid .. ^1], first + mid),
        right: chainChannels(subs[0 ..< mid], first))

proc fixedTree(prop, pred, pixels: int): ENode =
  ## libjxl's fixed trees (its efforts 2 and 3): one predictor, contexts by
  ## the value of one property at set cutoffs; fewer of them for small pictures.
  const cutoffs = [-500'i32, -392, -255, -191, -127, -95, -63, -47, -31, -23, -15, -11, -7,
                   -4, -3, -1, 0, 1, 3, 5, 7, 11, 15, 23, 31, 47, 63, 95, 127, 191, 255, 392, 500]
  let logPx = ceilLog2(max(1, pixels))
  let minGap = if logPx < 14: 8 * (14 - logPx) else: 0
  proc build(b, e: int): ENode =
    if b + minGap >= e: return leaf(pred)
    let s = (b + e) div 2
    ENode(prop: prop, split: cutoffs[s], left: build(s + 1, e), right: build(b, s))
  build(0, cutoffs.len)

proc flatten(root: ENode; alias: var seq[int]): seq[TreeNode] =
  ## In the order the decoder reads it (breadth first); leaves numbered so.
  ## A subtree met more than once is written each time; alias[ctx] is the
  ## context of the leaf's first copy (its own when it has no other).
  var queue = @[root]
  var q = 0
  var leaves = 0'i32
  var first: seq[(ENode, int)]                 # (shared leaves: the first context of each)
  while q < queue.len:
    let n = queue[q]
    inc q
    if n.prop < 0:
      result.add TreeNode(prop: -1, ctx: leaves, pred: int32(n.pred), offset: 0,
                          mult: int64(max(1, n.mult)))
      var a = int(leaves)
      for (e, c) in first:
        if e == n:
          a = c
          break
      if a == int(leaves): first.add (n, a)
      alias.add a
      inc leaves
    else:
      let at = result.len
      let pending = queue.len - q
      result.add TreeNode(prop: int32(n.prop), split: n.split, left: int32(at + pending + 1),
                          right: int32(at + pending + 2))
      queue.add n.left
      queue.add n.right

proc flatten(root: ENode): seq[TreeNode] =
  var alias: seq[int]
  flatten(root, alias)

proc writeTree(w: var BitWriter; nodes: seq[TreeNode]) =
  var hs = newSeq[seq[int]](6)
  for i in 0 .. 5: hs[i] = newSeq[int](64)
  template count(ctx: int; v: uint32) =
    let t = tokenOf(v)[0]
    if t >= hs[ctx].len: hs[ctx].setLen(t + 1)
    inc hs[ctx][t]
  proc mulParts(m: int64): (uint32, uint32) =   # (log, bits): m = (bits + 1) shl log
    let lg = countTrailingZeroBits(uint64(m))
    (uint32(lg), uint32((m shr lg) - 1))
  for n in nodes:
    if n.prop < 0:
      let (ml, mb) = mulParts(n.mult)
      count(1, 0)
      count(2, uint32(n.pred))
      count(3, packSigned(n.offset))
      count(4, ml)
      count(5, mb)
    else:
      count(1, uint32(n.prop + 1))
      count(0, packSigned(n.split))
  let e = writeEntropyCode(w, 6, hs, 6)
  for n in nodes:
    if n.prop < 0:
      let (ml, mb) = mulParts(n.mult)
      w.writeSymbol(e, 1, 0)
      w.writeSymbol(e, 2, uint32(n.pred))
      w.writeSymbol(e, 3, packSigned(n.offset))
      w.writeSymbol(e, 4, ml)
      w.writeSymbol(e, 5, mb)
    else:
      w.writeSymbol(e, 1, uint32(n.prop + 1))
      w.writeSymbol(e, 0, packSigned(n.split))

# -- predicting the samples of a channel, as the decoder will

template scanChannel(img: MImage; chan, stream: int; nodes: seq[TreeNode]; wph: WPHeader;
                     rowStep: int; ctxName, valName: untyped; action: untyped) =
  ## Runs `action` with ctxName (the context) and valName (the packed residual)
  ## for each sample of img.ch[chan], in the decoder's order (or, to estimate,
  ## of every rowStep-th row, the row above each run first).
  block:
    let ft = filterTree(nodes, chan, stream)
    let w = img.ch[chan].w
    let h = img.ch[chan].h
    var useWP = false
    var maxProp = 0
    for n in ft:
      if n.prop < 0:
        if n.pred == 6: useWP = true
      else:
        maxProp = max(maxProp, int(n.prop))
        if n.prop == 15: useWP = true
    if maxProp >= 16: raise newException(JxlError, "internal: reference properties")
    var wp: WPState
    if useWP: wp = initWP(wph, w)
    let p = if w * h == 0: nil else: cast[ptr UncheckedArray[int32]](unsafeAddr img.ch[chan].px[0])
    for y in 0 ..< (if w == 0: 0 else: h):
      let phase = y mod rowStep
      if rowStep > 1 and phase != 0 and phase != rowStep - 1: continue
      let emit = phase == 0
      let row = y * w
      var prevGrad = 0'i64
      for x in 0 ..< w:
        let left = if x > 0: int64(p[row + x - 1]) elif y > 0: int64(p[row - w + x]) else: 0'i64
        let top = if y > 0: int64(p[row - w + x]) else: left
        let topleft = if x > 0 and y > 0: int64(p[row - w + x - 1]) else: left
        let topright = if x + 1 < w and y > 0: int64(p[row - w + x + 1]) else: top
        let leftleft = if x > 1: int64(p[row + x - 2]) else: left
        let toptop = if y > 1: int64(p[row - 2 * w + x]) else: top
        let toprightright = if x + 2 < w and y > 0: int64(p[row - w + x + 2]) else: topright
        var maxErr = 0'i64
        var wpv = 0'i64
        if useWP: wpv = wp.wpPredict(x, y, w, top, left, topright, topleft, toptop, maxErr)
        let grad = left + top - topleft
        var n = 0
        while ft[n].prop >= 0:
          let v = case ft[n].prop
            of 2: int64(y)
            of 3: int64(x)
            of 4: abs(top)
            of 5: abs(left)
            of 6: top
            of 7: left
            of 8: left - prevGrad
            of 9: grad
            of 10: left - topleft
            of 11: topleft - top
            of 12: top - topright
            of 13: top - toptop
            of 14: left - leftleft
            else: maxErr
          n = if v > int64(ft[n].split): int(ft[n].left) else: int(ft[n].right)
        prevGrad = grad
        let guess = predictOne(int(ft[n].pred), left, top, toptop, topleft, topright, leftleft,
                               toprightright, wpv)
        let val = int64(p[row + x])
        if emit:
          let ctxName {.inject.} = int(ft[n].ctx)
          let d = val - guess - ft[n].offset
          let valName {.inject.} = packSigned(if ft[n].mult == 1: d else: d div ft[n].mult)
          action
        if useWP: wp.wpUpdate(val, x, y, w)

# -- learning a tree from the picture

const
  LearnProps = [15, 9, 10, 11, 12, 13, 14, 4, 5, 6, 7, 8, 2, 3]
  TokenBins = 160

type
  Samples = object
    n: int
    preds: seq[int]                     # the predictors tried
    tokens: seq[seq[uint8]]             # [predictor][sample]
    extra: seq[seq[uint8]]              # extra bits of each
    props: seq[seq[int32]]              # [property][sample]
    propIds: seq[int]                   # which property each of `props` is

proc gatherSamples(img: MImage; chan: int; preds: seq[int]; wph: WPHeader; step: int;
                   propIds: seq[int] = @LearnProps; mult = 1): Samples =
  ## The residual tokens of each predictor (the residuals divided by `mult`)
  ## and the properties, at every `step`th row of the channel.
  let w = img.ch[chan].w
  let h = img.ch[chan].h
  result.preds = preds
  result.propIds = propIds
  result.tokens = newSeq[seq[uint8]](preds.len)
  result.extra = newSeq[seq[uint8]](preds.len)
  result.props = newSeq[seq[int32]](propIds.len)
  let useWP = 6 in preds or 15 in propIds
  var wp: WPState
  if useWP: wp = initWP(wph, w)
  let p = cast[ptr UncheckedArray[int32]](unsafeAddr img.ch[chan].px[0])
  for y in 0 ..< h:
    let take = y mod step == 0
    if not take and y mod step != step - 1: continue
    let row = y * w
    var prevGrad = 0'i64
    for x in 0 ..< w:
      let left = if x > 0: int64(p[row + x - 1]) elif y > 0: int64(p[row - w + x]) else: 0'i64
      let top = if y > 0: int64(p[row - w + x]) else: left
      let topleft = if x > 0 and y > 0: int64(p[row - w + x - 1]) else: left
      let topright = if x + 1 < w and y > 0: int64(p[row - w + x + 1]) else: top
      let leftleft = if x > 1: int64(p[row + x - 2]) else: left
      let toptop = if y > 1: int64(p[row - 2 * w + x]) else: top
      let toprightright = if x + 2 < w and y > 0: int64(p[row - w + x + 2]) else: topright
      var maxErr = 0'i64
      var wpv = 0'i64
      if useWP: wpv = wp.wpPredict(x, y, w, top, left, topright, topleft, toptop, maxErr)
      let grad = left + top - topleft
      let val = int64(p[row + x])
      if take:
        for k, pr in preds:
          let d = val - predictOne(pr, left, top, toptop, topleft, topright, leftleft, toprightright, wpv)
          let (t, nb, _) = tokenOf(packSigned(if mult == 1: d else: d div mult))
          result.tokens[k].add uint8(min(t, TokenBins - 1))
          result.extra[k].add uint8(nb)
        for k, pr in propIds:
          let v = case pr
            of 2: int64(y)
            of 3: int64(x)
            of 4: abs(top)
            of 5: abs(left)
            of 6: top
            of 7: left
            of 8: left - prevGrad
            of 9: grad
            of 10: left - topleft
            of 11: topleft - top
            of 12: top - topright
            of 13: top - toptop
            of 14: left - leftleft
            else: maxErr
          result.props[k].add int32(clamp(v, -(1'i64 shl 30), 1'i64 shl 30))
        inc result.n
      prevGrad = grad
      if useWP: wp.wpUpdate(val, x, y, w)

var log2Table: array[4096, float32]
for i in 1 ..< 4096: log2Table[i] = float32(log2(float(i)))

proc flog2(x: int): float {.inline.} =
  if x < 4096: float(log2Table[x]) else: log2(float(x))

proc costOf(h: openArray[int32]; extraBits: int): float =
  ## The bits these tokens take (their entropy), their raw bits and their code.
  var total = 0
  var nz = 0
  for c in h:
    if c > 0:
      total += c
      inc nz
      result -= float(c) * flog2(int(c))
  if total == 0: return 0
  result += float(total) * flog2(total) + float(extraBits) + float(nz) * 7

proc sortI32(a: var seq[int32]; lo0, hi0: int) =
  ## Ascending, in place (a[lo0 .. hi0]): quicksort, insertion sort for short runs.
  var lo = lo0
  var hi = hi0
  while hi - lo > 16:
    let m = (lo + hi) shr 1
    if a[m] < a[lo]: swap(a[m], a[lo])
    if a[hi] < a[lo]: swap(a[hi], a[lo])
    if a[hi] < a[m]: swap(a[hi], a[m])
    let pivot = a[m]
    var i = lo
    var j = hi
    while i <= j:
      while a[i] < pivot: inc i
      while pivot < a[j]: dec j
      if i <= j:
        swap(a[i], a[j])
        inc i
        dec j
    if j - lo < hi - i:                  # the shorter side first, by recursion
      sortI32(a, lo, j)
      lo = i
    else:
      sortI32(a, i, hi)
      hi = j
  for i in lo + 1 .. hi:
    let v = a[i]
    var j = i - 1
    while j >= lo and a[j] > v:
      a[j + 1] = a[j]
      dec j
    a[j + 1] = v

proc learn(s: Samples; idx: seq[int32]; depth, maxDepth: int; leaves: var int; maxLeaves: int;
           numThresholds: int): ENode =
  ## A tree for these samples: each leaf with its best predictor, split while
  ## the bits saved pay for the split.
  let np = s.preds.len
  var bestPred = 0
  var bestCost = Inf
  for k in 0 ..< np:
    var h = newSeq[int32](TokenBins)
    var eb = 0
    for i in idx:
      inc h[s.tokens[k][i]]
      eb += int(s.extra[k][i])
    let c = costOf(h, eb)
    if c < bestCost:
      bestCost = c
      bestPred = s.preds[k]
  if depth >= maxDepth or idx.len < 256 or leaves + 1 >= maxLeaves:
    return leaf(bestPred)
  # each property: split at a few quantiles; the best split over all
  var bestGain = 0.0
  var bestProp = -1
  var bestSplit = 0'i32
  var vals = newSeq[int32](idx.len)
  type U8s = ptr UncheckedArray[uint8]
  type I32s = ptr UncheckedArray[int32]
  var toks, extras: array[16, U8s]          # (the hot loops below without bound checks)
  for k in 0 ..< np:
    toks[k] = cast[U8s](unsafeAddr s.tokens[k][0])
    extras[k] = cast[U8s](unsafeAddr s.extra[k][0])
  let ix = cast[I32s](unsafeAddr idx[0])
  let vp = cast[I32s](addr vals[0])
  for pk in 0 ..< s.propIds.len:
    let pp = cast[I32s](unsafeAddr s.props[pk][0])
    for j in 0 ..< idx.len: vp[j] = pp[ix[j]]
    var sorted: seq[int32]               # (thresholds from at most 1024 of them)
    let every = max(1, vals.len div 1024)
    var j = 0
    while j < vals.len:
      sorted.add vals[j]
      j += every
    sortI32(sorted, 0, sorted.high)
    if sorted[0] == sorted[^1]: continue
    var cands: seq[int32]
    for q in 1 .. numThresholds:
      let v = sorted[min(sorted.high, sorted.len * q div (numThresholds + 1))]
      if v < sorted[^1] and (cands.len == 0 or cands[^1] != v): cands.add v
    if cands.len == 0: continue
    # per bin (between thresholds) token histograms of every predictor
    let nb = cands.len + 1
    var hist = newSeq[int32](nb * np * TokenBins)
    var ebits = newSeq[int](nb * np)
    let hp = cast[I32s](addr hist[0])
    let ep = cast[ptr UncheckedArray[int]](addr ebits[0])
    let cp = cast[I32s](addr cands[0])
    let nc = cands.len
    for j in 0 ..< idx.len:
      let v = vp[j]
      let i = ix[j]
      var b = 0                            # the bin: how many thresholds are below v
      var e = nc
      while b < e:
        let m = (b + e) shr 1
        if cp[m] < v: b = m + 1 else: e = m
      for k in 0 ..< np:
        inc hp[(b * np + k) * TokenBins + int(toks[k][i])]
        ep[b * np + k] += int(extras[k][i])
    # sweep the thresholds: right (<= t) grows, left (> t) is the rest
    var total = newSeq[int32](np * TokenBins)
    var etotal = newSeq[int](np)
    for b in 0 ..< nb:
      for k in 0 ..< np:
        let base = (b * np + k) * TokenBins
        for tk in 0 ..< TokenBins: total[k * TokenBins + tk] += hist[base + tk]
        etotal[k] += ebits[b * np + k]
    var right = newSeq[int32](np * TokenBins)
    var eright = newSeq[int](np)
    var left = newSeq[int32](TokenBins)
    for t in 0 ..< cands.len:
      var lo = Inf
      var hi = Inf
      for k in 0 ..< np:
        let base = (t * np + k) * TokenBins
        for tk in 0 ..< TokenBins: right[k * TokenBins + tk] += hist[base + tk]
        eright[k] += ebits[t * np + k]
        for tk in 0 ..< TokenBins: left[tk] = total[k * TokenBins + tk] - right[k * TokenBins + tk]
        lo = min(lo, costOf(left, etotal[k] - eright[k]))
        hi = min(hi, costOf(right.toOpenArray(k * TokenBins, k * TokenBins + TokenBins - 1), eright[k]))
      let gain = bestCost - (lo + hi) - 48
      if gain > bestGain:
        bestGain = gain
        bestProp = s.propIds[pk]
        bestSplit = cands[t]
  if bestProp < 0: return leaf(bestPred)
  let pk = s.propIds.find(bestProp)
  var l, r: seq[int32]
  for i in idx:
    if s.props[pk][i] > bestSplit: l.add i
    else: r.add i
  inc leaves
  let left = learn(s, l, depth + 1, maxDepth, leaves, maxLeaves, numThresholds)
  let right = learn(s, r, depth + 1, maxDepth, leaves, maxLeaves, numThresholds)
  ENode(prop: bestProp, split: bestSplit, left: left, right: right)


# -- the headers

proc writeSize(w: var BitWriter; width, height: int) =
  w.put(0, 1)                                   # not a multiple of 8
  w.putU32(height, (1, 9), (1, 13), (1, 18), (1, 30))
  w.put(0, 3)                                   # no ratio
  w.putU32(width, (1, 9), (1, 13), (1, 18), (1, 30))

proc writeImageHeader(w: var BitWriter; width, height: int; gray, alpha, xyb: bool) =
  w.put(0x0AFF, 16)
  w.writeSize(width, height)
  w.put(0, 1)                                   # not all default
  w.put(0, 1)                                   # no extra fields
  w.put(0, 1)                                   # integer samples
  w.putU32(8, (8, 0), (10, 0), (12, 0), (1, 6))
  w.putBool(not xyb)                            # 16-bit buffers suffice (not for XYB's scaled samples)
  w.putU32(ord(alpha), (0, 0), (1, 0), (2, 4), (1, 12))
  if alpha: w.put(1, 1)                         # the default alpha channel
  w.putBool(xyb)
  if gray:
    w.put(0, 1)                                 # a color encoding of its own:
    w.put(0, 1)                                 # no ICC profile
    w.putU32(1, (0, 0), (1, 0), (2, 4), (18, 6))   # grey
    w.putU32(1, (0, 0), (1, 0), (2, 4), (18, 6))   # D65
    w.put(0, 1)                                 # no gamma:
    w.putU32(13, (0, 0), (1, 0), (2, 4), (18, 6))  # the sRGB transfer function
    w.putU32(1, (0, 0), (1, 0), (2, 4), (18, 6))   # relative rendering intent
  else:
    w.put(1, 1)                                 # sRGB
  w.putU64(0)                                   # no extensions
  w.put(1, 1)                                   # the default transform data
  w.padToByte()

proc writeToc(w: var BitWriter; sizes: seq[int]) =
  w.put(0, 1)                                   # in order
  w.padToByte()
  for n in sizes: w.putU32(n, (0, 10), (1024, 14), (17408, 22), (4211712, 30))
  w.padToByte()

# -- lossless

type
  ColorSet = object
    keys: seq[uint32]
    used: seq[bool]
    vals: seq[int32]

proc initHashSetJxl(): ColorSet =
  ColorSet(keys: newSeq[uint32](4096), used: newSeq[bool](4096), vals: newSeq[int32](4096))

proc slot(s: ColorSet; k: uint32): int {.inline.} =
  var i = int((k * 2654435761'u32) shr 20) and (s.keys.len - 1)
  while s.used[i] and s.keys[i] != k: i = (i + 1) and (s.keys.len - 1)
  i

proc incl(s: var ColorSet; k: uint32): bool =
  ## Adds k; whether it was new.
  let i = s.slot(k)
  if s.used[i]: return false
  s.used[i] = true
  s.keys[i] = k
  true

proc initTableJxl(colors: seq[uint32]): ColorSet =
  result = initHashSetJxl()
  for i, c in colors:
    let k = result.slot(c)
    result.used[k] = true
    result.keys[k] = c
    result.vals[k] = int32(i)

proc get(s: ColorSet; k: uint32): int = int(s.vals[s.slot(k)])

proc forwardRct(img: var MImage; t: int) =
  ## The inverse of the decoder's RCT t on channels 0..2.
  let perm = t div 7
  let custom = t mod 7
  let pos = [perm mod 3, (perm + 1 + perm div 3) mod 3, (perm + 2 - perm div 3) mod 3]
  let n = img.ch[0].px.len
  var a = newSeq[int32](n)
  var b = newSeq[int32](n)
  var c = newSeq[int32](n)
  let o0 = addr img.ch[pos[0]].px
  let o1 = addr img.ch[pos[1]].px
  let o2 = addr img.ch[pos[2]].px
  for i in 0 ..< n:
    let r = o0[][i]
    let g = o1[][i]
    let bb = o2[][i]
    if custom == 6:
      let co = r - bb
      let tmp = bb + (co shr 1)
      let cg = g - tmp
      a[i] = tmp + (cg shr 1)
      b[i] = co
      c[i] = cg
    else:
      let second = custom shr 1
      let third = custom and 1
      a[i] = r
      c[i] = if third == 1: bb - r else: bb
      b[i] = if second == 1: g - r elif second == 2: g - ((r + bb) shr 1) else: g
  img.ch[0].px = a
  img.ch[1].px = b
  img.ch[2].px = c

proc gradientCost(img: MImage; chans: openArray[int]; step: int): float =
  ## The bits the gradient predictor's residuals would take (every step-th row).
  for c in chans:
    let ch = addr img.ch[c]
    var h = newSeq[int32](TokenBins)
    var eb = 0
    var y = 1
    while y < ch.h:
      let row = y * ch.w
      for x in 1 ..< ch.w:
        let g = clampedGradient(int64(ch.px[row + x - 1]), int64(ch.px[row - ch.w + x]),
                                int64(ch.px[row - ch.w + x - 1]))
        let (t, nb, _) = tokenOf(packSigned(int64(ch.px[row + x]) - g))
        inc h[min(t, TokenBins - 1)]
        eb += nb
      y += step
    result += costOf(h, eb)

proc cropChannel(c: MChannel; x0, y0, w, h: int): MChannel =
  result = newChannel(w, h, c.hshift, c.vshift)
  for y in 0 ..< h:
    copyMem(addr result.px[y * w], unsafeAddr c.px[(y0 + y) * c.w + x0], w * 4)

proc writeStream(bw: var BitWriter; si: MImage; sid: int; ts: seq[MTransform]; nodes: seq[TreeNode];
                 code: EncCode; wph: WPHeader) =
  ## One modular stream (stream id `sid`) coded with the global tree: its
  ## header, its transforms, its channels.
  bw.put(1, 1)                                  # the global tree
  bw.put(1, 1)                                  # the default weighted predictor
  bw.putU32(ts.len, (0, 0), (1, 0), (2, 4), (18, 8))
  for t in ts:
    bw.putU32(t.id, (0, 0), (1, 0), (2, 0), (3, 0))
    if t.id == 2:                               # squeeze: its steps (none: the default ones)
      bw.putU32(t.squeezes.len, (0, 0), (1, 4), (9, 6), (41, 8))
      for s in t.squeezes:
        bw.putBool(s.horizontal)
        bw.putBool(s.inPlace)
        bw.putU32(s.beginC, (0, 3), (8, 6), (72, 10), (1096, 13))
        bw.putU32(s.numC, (1, 0), (2, 0), (3, 0), (4, 4))
      continue
    bw.putU32(t.beginC, (0, 3), (8, 6), (72, 10), (1096, 13))
    if t.id == 0:
      bw.putU32(t.rctType, (6, 0), (0, 2), (2, 4), (10, 6))
    else:
      bw.putU32(t.numC, (1, 0), (3, 0), (4, 0), (1, 13))
      bw.putU32(t.nbColors, (0, 8), (256, 10), (1280, 12), (5376, 16))
      bw.putU32(t.nbDeltas, (0, 0), (1, 8), (257, 10), (1281, 16))
      bw.put(t.predictor, 4)
  if code.ans:
    var buf: TokenBuf
    for c in 0 ..< si.ch.len:
      scanChannel(si, c, sid, nodes, wph, 1, ctx, v):
        buf.add(code, ctx, v)
    if buf.tok.len > 0: bw.flush(code, buf)
  else:
    for c in 0 ..< si.ch.len:
      scanChannel(si, c, sid, nodes, wph, 1, ctx, v):
        bw.writeSymbol(code, ctx, v)

proc frameFile(w, h: int; gray, alpha, xyb: bool; sections: seq[string]): string =
  ## The file: the headers, one modular frame of these sections.
  var fw: BitWriter
  fw.writeImageHeader(w, h, gray, alpha, xyb)
  fw.put(0, 1)                                  # a frame header of its own:
  fw.put(0, 2)                                  # a regular frame
  fw.put(1, 1)                                  # modular
  fw.putU64(0)                                  # no flags
  if not xyb: fw.put(0, 1)                      # not YCbCr
  fw.put(0, 2)                                  # no upsampling
  if alpha: fw.put(0, 2)
  fw.put(1, 2)                                  # groups of 256
  fw.put(0, 2)                                  # one pass
  fw.put(0, 1)                                  # no crop
  fw.put(0, 2)                                  # replace
  if alpha: fw.put(0, 2)
  fw.put(1, 1)                                  # the last frame
  fw.put(0, 2)                                  # no name
  fw.put(0, 1)                                  # restoration filters:
  fw.put(0, 1)                                  # no Gaborish
  fw.put(0, 2)                                  # no EPF
  fw.putU64(0)
  fw.putU64(0)                                  # no extensions
  var sizes: seq[int]
  for sct in sections: sizes.add sct.len
  fw.writeToc(sizes)
  result = fw.bytes
  for sct in sections: result.add sct

proc encodeJxlLossless*(b: Bitmap; effort = 3): string =
  ## A JPEG XL file of the picture, every pixel kept exactly (the color under
  ## transparent pixels too), as libjxl decodes it as well. `effort` 1..9
  ## trades time for size: 1 the gradient predictor and prefix codes; 2 and
  ## 3 libjxl's fixed trees (the gradient predictor, contexts by its value;
  ## the weighted predictor, contexts by its error) and ANS; 4 and up the MA
  ## tree learned from the picture, with more predictors and samples at each
  ## step, and from 5 the reversible color transform chosen out of 42. A
  ## 12-megapixel photo takes some 2 s at 1, 6 s at 3 and 50 s at 7 on one
  ## core. A palette (of up to 256 colors; 1024 from effort 3) is used
  ## whenever it pays.
  let w = b.w
  let h = b.h
  if w <= 0 or h <= 0: raise newException(JxlError, "an empty picture")
  let effort = clamp(effort, 1, 9)
  var gray = true
  var alpha = false
  for p in b.px:
    if (p shr 24) != 255: alpha = true
    let r = (p shr 16) and 255
    if r != ((p shr 8) and 255) or r != (p and 255): gray = false
  var img = MImage(bitDepth: 8)
  if gray:
    img.ch.add newChannel(w, h)
    for i, p in b.px: img.ch[0].px[i] = int32(p and 255)
  else:
    for c in 0 .. 2:
      img.ch.add newChannel(w, h)
      let sh = 16 - 8 * c
      for i, p in b.px: img.ch[c].px[i] = int32((p shr sh) and 255)
  if alpha:
    img.ch.add newChannel(w, h)
    for i, p in b.px: img.ch[^1].px[i] = int32(p shr 24)
  let nch = img.ch.len
  var transforms: seq[MTransform]
  # a palette, when there are few colors
  var colors: seq[uint32]
  block:
    let limit = if effort >= 3: 1024 else: 256
    var seen = initHashSetJxl()
    for p in b.px:
      if seen.incl(p):
        colors.add p
        if colors.len > limit: break
  let usePalette = colors.len <= (if effort >= 3: 1024 else: 256) and colors.len * nch * 4 < w * h
  if usePalette:
    proc luma(p: uint32): int = int((p shr 16) and 255) * 3 + int((p shr 8) and 255) * 6 +
                                int(p and 255) + int(p shr 24) * 4
    colors.sort(proc (a, b: uint32): int = cmp(luma(a), luma(b)))
    var pal = newChannel(colors.len, nch)
    pal.hshift = -1
    pal.vshift = -1
    var index = initTableJxl(colors)
    var idx = newChannel(w, h)
    for i, p in b.px: idx.px[i] = int32(index.get(p))
    for k, p in colors:
      if gray:
        pal.px[k] = int32(p and 255)
        if alpha: pal.px[colors.len + k] = int32(p shr 24)
      else:
        for c in 0 .. 2: pal.px[c * colors.len + k] = int32((p shr (16 - 8 * c)) and 255)
        if alpha: pal.px[3 * colors.len + k] = int32(p shr 24)
    img.ch = @[pal, idx]
    img.nbMeta = 1
    transforms.add MTransform(id: 1, beginC: 0, numC: nch, nbColors: colors.len, nbDeltas: 0,
                              predictor: 0)
  elif not gray:
    let step = max(1, h div 64)
    var cands = @[0, 6, 10]
    if effort >= 5:
      cands = @[]
      for t in 0 ..< 42:
        if t mod 7 != 0 or t == 0: cands.add t
    var best = 0
    var bestCost = Inf
    for t in cands:
      var trial = MImage(bitDepth: 8, ch: img.ch[0 .. 2])
      if t != 0: trial.forwardRct(t)
      let c = trial.gradientCost([0, 1, 2], step)
      if c < bestCost:
        bestCost = c
        best = t
    if best != 0:
      img.forwardRct(best)
      transforms.add MTransform(id: 0, beginC: 0, rctType: best)
  # the tree: one part for each channel
  let gdim = 256
  let numGroups = cdiv(w, gdim) * cdiv(h, gdim)
  var subs: seq[ENode]
  var totalPx = 0
  for ch in img.ch: totalPx += ch.w * ch.h
  for c in 0 ..< img.ch.len:
    if c < img.nbMeta or effort == 1:
      subs.add leaf(if c < img.nbMeta: 1 else: 5)
      continue
    if effort <= 3:                   # gradient by its value, or weighted by its error
      subs.add (if effort == 2: fixedTree(9, 5, totalPx) else: fixedTree(15, 6, totalPx))
      continue
    let preds = if effort >= 9: @[5, 6, 1, 2, 3, 4, 11, 12] elif effort >= 7: @[5, 6, 1, 2, 3]
                elif effort >= 5: @[5, 6, 1, 2] else: @[5, 6]
    let budget = [0, 0, 0, 0, 300_000, 800_000, 1_500_000, 3_000_000, 6_000_000, 1 shl 30][effort]
    let px = img.ch[c].w * img.ch[c].h
    let step = max(1, cdiv(px, budget))
    let s = gatherSamples(img, c, preds, defaultWP(), step)
    var idx = newSeq[int32](s.n)
    for i in 0 ..< s.n: idx[i] = int32(i)
    var leaves = 0
    let maxLeaves = [0, 0, 0, 0, 32, 64, 96, 128, 192, 256][effort]
    let thresholds = if effort >= 7: 16 else: 8
    subs.add learn(s, idx, 0, 14, leaves, maxLeaves, thresholds)
  let single = numGroups == 1
  var root: ENode
  if single or img.nbMeta == 0: root = chainChannels(subs, 0)
  else:
    root = ENode(prop: 1, split: 0, left: chainChannels(subs[img.nbMeta .. ^1], 0),
                 right: chainChannels(subs[0 ..< img.nbMeta], 0))
  let nodes = flatten(root)
  var numLeaves = 0
  for n in nodes:
    if n.prop < 0: inc numLeaves
  # the streams: the global one (meta channels; all, for one group), one a group
  var streams: seq[(MImage, int)]             # (channels, stream id)
  var globalImg = MImage(bitDepth: 8, nbMeta: img.nbMeta)
  for c in 0 ..< img.ch.len:
    if c < img.nbMeta or single: globalImg.ch.add img.ch[c]
  streams.add (globalImg, 0)
  let xgroups = cdiv(w, gdim)
  let numLfGroups = cdiv(w, gdim * 8) * cdiv(h, gdim * 8)
  if not single:
    for g in 0 ..< numGroups:
      let gx = (g mod xgroups) * gdim
      let gy = (g div xgroups) * gdim
      var gi = MImage(bitDepth: 8)
      for c in img.nbMeta ..< img.ch.len:
        gi.ch.add cropChannel(img.ch[c], gx, gy, min(gdim, w - gx), min(gdim, h - gy))
      streams.add (gi, 1 + 3 * numLfGroups + 17 + g)
  # the histograms
  var hs = newSeq[seq[int]](numLeaves)
  for i in 0 ..< numLeaves: hs[i] = newSeq[int](TokenBins)
  let wph = defaultWP()
  let estimate = w * h > 4_000_000
  let rowStep = if estimate: 4 else: 1
  for (si, sid) in streams:
    for c in 0 ..< si.ch.len:
      scanChannel(si, c, sid, nodes, wph, rowStep, ctx, v):
        let t = tokenOf(v)[0]
        if t >= hs[ctx].len: hs[ctx].setLen(t + 1)
        inc hs[ctx][t]
  if estimate:
    # (every token a residual can make keeps a code: none is more than 6 times
    # the largest sample from the prediction)
    var most = 0'i64
    for ch in img.ch:
      for v in ch.px: most = max(most, abs(int64(v)))
    let bound = tokenOf(packSigned(-(6 * most + 16)))[0]
    for hh in hs.mitems:
      if hh.len <= bound: hh.setLen(bound + 1)
      for t in 0 .. bound: inc hh[t]
  # the sections
  var sections: seq[string]
  var lfg: BitWriter
  lfg.put(1, 1)                                 # the default LF dequantization
  lfg.put(1, 1)                                 # a global tree:
  lfg.writeTree(nodes)
  let code = writeEntropyCode(lfg, numLeaves, hs, ans = effort >= 2)
  lfg.writeStream(streams[0][0], 0, transforms, nodes, code, wph)
  sections.add lfg.bytes
  if not single:
    for i in 0 ..< numLfGroups: sections.add ""
    sections.add ""                             # HF global
    for k in 1 ..< streams.len:
      var gw: BitWriter
      gw.writeStream(streams[k][0], streams[k][1], @[], nodes, code, wph)
      sections.add gw.bytes
  frameFile(w, h, gray, alpha, false, sections)


# -- lossy: XYB, squeezed, the residuals quantized

proc jxlDistance*(quality: int): float =
  ## The distance cjxl takes its -q quality for (butteraugli's measure of how
  ## far the picture may stray: about 1.0 is where a difference starts to
  ## show): 90 is 1.0, 75 is 2.35, 50 is 4.6, 100 is 0 (lossless).
  let q = clamp(quality, 0, 100)
  if q >= 100: 0.0
  elif q >= 30: float(10 + 9 * (100 - q)) / 100        # (0.1 + (100 - q) * 0.09, exactly)
  else: 53.0 / 3000.0 * float(q * q) - 23.0 / 20.0 * float(q) + 25.0

const
  XybScale = [4096.0, 65536.0, 4096.0]
    ## Channels 0, 1 and 2 hold Y, X and B - Y as integers: XYB times these
    ## (libjxl's; the LF dequantization the file gives says so).
  LossyQuant = [305.0, 1331.0, 717.0]
    ## Y, X and B - Y: what the finest squeeze residuals are quantized by at
    ## distance 1, half that at each coarser step (libjxl 0.12 has 244, 1024
    ## and 2048; these, tried on photos with SSIMULACRA 2, give the same
    ## quality at a distance in some 9% fewer bytes).
  ResidualProps = @[4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14]
    ## (the neighbors: not the position, which a group sees from its own corner,
    ## nor the weighted predictor's error, which would cost the decoder time)
  PlainProps = @[15, 9, 10, 11, 12, 13, 14, 4, 5, 6, 7, 8]

proc opsinMatrix(): array[9, float] =
  ## Linear sRGB to the opsin mix: the inverse of the decoder's matrix.
  var m: array[9, float]
  for i in 0 .. 8: m[i] = float(DefaultInvMat[i])
  let det = m[0] * (m[4] * m[8] - m[5] * m[7]) - m[1] * (m[3] * m[8] - m[5] * m[6]) +
            m[2] * (m[3] * m[7] - m[4] * m[6])
  [(m[4] * m[8] - m[5] * m[7]) / det, (m[2] * m[7] - m[1] * m[8]) / det, (m[1] * m[5] - m[2] * m[4]) / det,
   (m[5] * m[6] - m[3] * m[8]) / det, (m[0] * m[8] - m[2] * m[6]) / det, (m[2] * m[3] - m[0] * m[5]) / det,
   (m[3] * m[7] - m[4] * m[6]) / det, (m[1] * m[6] - m[0] * m[7]) / det, (m[0] * m[4] - m[1] * m[3]) / det]

proc cubeRoot(x: float): float {.inline.} =
  ## (x > 0) A guess from the bits, then two of Halley's steps: as exact as
  ## `cbrt`, in a third of the time.
  var y = cast[float](cast[uint64](x) div 3 + 0x2A9F7893782DA1CE'u64)
  for _ in 0 .. 1:
    let y3 = y * y * y
    y = y * (y3 + 2 * x) / (2 * y3 + x)
  y

proc toXyb(b: Bitmap; gray: bool): array[3, MChannel] =
  ## The picture in XYB, as integers: Y, X, B - Y (X and B - Y 0 for a gray one).
  for k in 0 .. 2: result[k] = newChannel(b.w, b.h)
  var lin: array[256, float]
  for i in 0 .. 255:
    let v = i / 255
    lin[i] = if v <= 0.04045: v / 12.92 else: pow((v + 0.055) / 1.055, 2.4)
  let m = opsinMatrix()
  const bias = 0.0037930732552754493                   # (the decoder's opsin bias, negated)
  let cb = cbrt(bias)
  let py = cast[ptr UncheckedArray[int32]](addr result[0].px[0])
  if gray:
    var lut: array[256, int32]
    for i in 0 .. 255:
      let l = cbrt((m[0] + m[1] + m[2]) * lin[i] + bias) - cb
      let mm = cbrt((m[3] + m[4] + m[5]) * lin[i] + bias) - cb
      lut[i] = int32(round((l + mm) * 0.5 * XybScale[0]))
    for i, p in b.px: py[i] = lut[p and 255]
    return
  let px = cast[ptr UncheckedArray[int32]](addr result[1].px[0])
  let pb = cast[ptr UncheckedArray[int32]](addr result[2].px[0])
  var last = not b.px[0]
  var ly, lx, lb: int32
  for i, p in b.px:
    let c = p and 0xFFFFFF
    if c != last:                                       # (runs of one color: once)
      last = c
      let r = lin[(c shr 16) and 255]
      let g = lin[(c shr 8) and 255]
      let bb = lin[c and 255]
      let l = cubeRoot(m[0] * r + m[1] * g + m[2] * bb + bias) - cb
      let mm = cubeRoot(m[3] * r + m[4] * g + m[5] * bb + bias) - cb
      let s = cubeRoot(m[6] * r + m[7] * g + m[8] * bb + bias) - cb
      ly = int32(round((l + mm) * 0.5 * XybScale[0]))
      lx = int32(round((l - mm) * 0.5 * XybScale[1]))
      lb = int32(round(s * XybScale[2])) - ly
    py[i] = ly
    px[i] = lx
    pb[i] = lb

proc squeezeAvg(c: MChannel; horizontal: bool): MChannel =
  ## The first half of a squeeze step: the average of each pair of samples
  ## (side by side, or one above the other), as the decoder takes them apart.
  if horizontal:
    result = newChannel((c.w + 1) div 2, c.h, c.hshift + 1, c.vshift)
    let half = c.w div 2
    for y in 0 ..< c.h:
      let i = y * c.w
      let o = y * result.w
      for x in 0 ..< half:
        let a = c.px[i + 2 * x]
        let b = c.px[i + 2 * x + 1]
        result.px[o + x] = (a + b + int32(a > b)) shr 1
      if (c.w and 1) == 1: result.px[o + half] = c.px[i + c.w - 1]
  else:
    result = newChannel(c.w, (c.h + 1) div 2, c.hshift, c.vshift + 1)
    let w = c.w
    for y in 0 ..< c.h div 2:
      for x in 0 ..< w:
        let a = c.px[2 * y * w + x]
        let b = c.px[(2 * y + 1) * w + x]
        result.px[y * w + x] = (a + b + int32(a > b)) shr 1
    if (c.h and 1) == 1:
      for x in 0 ..< w: result.px[(result.h - 1) * w + x] = c.px[(c.h - 1) * w + x]

proc quantize(v, q, half: int64): int64 {.inline.} =
  ## v to a multiple of q: the one nearer 0, or the next when |v| is at least
  ## q - half past it (half = q div 2: the nearer one).
  if v >= 0: ((v + half) div q) * q else: -(((half - v) div q) * q)

proc squeezeBack(fine: var MChannel; coarse: MChannel; horizontal: bool; q, half: int): MChannel =
  ## The second half of a squeeze step, quantized: the residuals (multiples
  ## of q) that bring the decoder's coarse samples nearest to `fine`, each
  ## worked out from the samples the decoder will have; `fine` becomes what
  ## the decoder makes of them.
  let q = int64(q)
  let half = int64(half)
  template pick(d, t: int64): int64 =
    if q == 1: d - t else: quantize(d - t, q, half)
  if horizontal:
    let rw = fine.w - coarse.w
    result = newChannel(rw, fine.h, coarse.hshift, coarse.vshift)
    let f = cast[ptr UncheckedArray[int32]](addr fine.px[0])
    for y in 0 ..< fine.h:
      let fi = y * fine.w
      let ci = y * coarse.w
      let ri = y * rw
      for x in 0 ..< rw:
        let avg = int64(coarse.px[ci + x])
        let nextAvg = if x + 1 < coarse.w: int64(coarse.px[ci + x + 1]) else: avg
        let left = if x > 0: int64(f[fi + 2 * x - 1]) else: avg
        let t = smoothTendency(left, avg, nextAvg)
        let r = pick(int64(f[fi + 2 * x]) - int64(f[fi + 2 * x + 1]), t)
        result.px[ri + x] = int32(r)
        let diff = r + t
        let a = avg + diff div 2
        f[fi + 2 * x] = int32(a)
        f[fi + 2 * x + 1] = int32(a - diff)
      if (fine.w and 1) == 1: f[fi + fine.w - 1] = coarse.px[ci + coarse.w - 1]
  else:
    let rh = fine.h - coarse.h
    let w = fine.w
    result = newChannel(w, rh, coarse.hshift, coarse.vshift)
    if w == 0: return
    let f = cast[ptr UncheckedArray[int32]](addr fine.px[0])
    for y in 0 ..< rh:
      for x in 0 ..< w:
        let avg = int64(coarse.px[y * w + x])
        let nextAvg = if y + 1 < coarse.h: int64(coarse.px[(y + 1) * w + x]) else: avg
        let top = if y > 0: int64(f[(2 * y - 1) * w + x]) else: avg
        let t = smoothTendency(top, avg, nextAvg)
        let r = pick(int64(f[2 * y * w + x]) - int64(f[(2 * y + 1) * w + x]), t)
        result.px[y * w + x] = int32(r)
        let diff = r + t
        let a = avg + diff div 2
        f[2 * y * w + x] = int32(a)
        f[(2 * y + 1) * w + x] = int32(a - diff)
    if (fine.h and 1) == 1:
      for x in 0 ..< w: f[(fine.h - 1) * w + x] = coarse.px[(coarse.h - 1) * w + x]

proc lossyQuant(k, shift: int; f: float): int =
  ## The quantizer of component k's channel `shift` (its hshift + vshift) steps squeezed.
  max(1, int(round(LossyQuant[k] * f / float(1 shl clamp(shift - 1, 0, 30)))))

proc setMult(n: ENode; q: int) =
  if n.prop < 0: n.mult = q
  else:
    setMult(n.left, q)
    setMult(n.right, q)

proc fixedResidualTree(q, nonzero: int): ENode =
  ## Contexts by how large the residuals left of and above are (in steps of
  ## q); one when there are few residuals other than 0.
  if nonzero < 1024: return leaf(0)
  proc by(prop, q: int; inner: proc (): ENode): ENode =
    ENode(prop: prop, split: int32(q), left: ENode(prop: prop, split: int32(3 * q), left: inner(), right: inner()),
          right: ENode(prop: prop, split: 0, left: inner(), right: inner()))
  by(5, q, proc (): ENode = by(4, q, proc (): ENode = leaf(0)))

proc lossySubtree(img: MImage; c, q, kind, effort: int): ENode =
  ## The tree of one channel: kind 0 squeeze residuals (the zero predictor),
  ## 1 what is left of a component (a few samples), 2 alpha (kept exactly).
  let px = img.ch[c].w * img.ch[c].h
  if px == 0: result = leaf(0)
  elif kind == 1: result = leaf(5)
  elif kind == 2:
    if effort <= 3:
      result = if effort == 1: leaf(5) elif effort == 2: fixedTree(9, 5, px) else: fixedTree(15, 6, px)
    else:
      let preds = if effort >= 9: @[5, 6, 1, 2, 3, 4, 11, 12] elif effort >= 7: @[5, 6, 1, 2, 3]
                  elif effort >= 5: @[5, 6, 1, 2] else: @[5, 6]
      let budget = [0, 0, 0, 0, 300_000, 800_000, 1_500_000, 3_000_000, 6_000_000, 1 shl 30][effort]
      let s = gatherSamples(img, c, preds, defaultWP(), max(1, cdiv(px, budget)), PlainProps)
      var idx = newSeq[int32](s.n)
      for i in 0 ..< s.n: idx[i] = int32(i)
      var leaves = 0
      result = learn(s, idx, 0, 14, leaves, [0, 0, 0, 0, 32, 64, 96, 128, 192, 256][effort],
                     if effort >= 7: 16 else: 8)
  else:
    var nonzero = 0
    for v in img.ch[c].px:
      if v != 0: inc nonzero
    if nonzero == 0: result = leaf(0); return                  # (all 0: no multiplier, the same leaf as others)
    if effort <= 2: result = fixedResidualTree(q, nonzero)
    else:
      let budget = [0, 0, 0, 50_000, 200_000, 400_000, 800_000, 1_600_000, 3_200_000, 1 shl 30][effort]
      let s = gatherSamples(img, c, @[0], defaultWP(), max(1, cdiv(px, budget)), ResidualProps, q)
      var idx = newSeq[int32](s.n)
      for i in 0 ..< s.n: idx[i] = int32(i)
      var leaves = 0
      result = learn(s, idx, 0, 12, leaves, [0, 0, 0, 24, 32, 48, 64, 96, 128, 160][effort],
                     if effort >= 7: 16 else: 8)
  setMult(result, q)

proc f16Bits(v: float): int =
  ## A positive normal number as a half float's bits.
  var e = int(floor(log2(v)))
  var m = int(round((v / pow(2.0, float(e)) - 1) * 1024))
  if m == 1024:
    m = 0
    inc e
  ((e + 15) shl 10) or m

proc encodeLossy(b: Bitmap; distance: float; effort: int): string =
  let w = b.w
  let h = b.h
  let effort = clamp(effort, 1, 9)
  var gray = true
  var alpha = false
  for p in b.px:
    if (p shr 24) != 255: alpha = true
    let r = (p shr 16) and 255
    if r != ((p shr 8) and 255) or r != (p and 255): gray = false
  let f = pow(distance, 1.2)
  var planes = toXyb(b, gray)
  # the squeeze steps (libjxl's default ones, of the color channels), and
  # where each puts its residuals: the channels of the squeezed picture as
  # (component, step), step 0 what is left of the component itself
  let sq = defaultSqueezes(MImage(ch: @[MChannel(w: w, h: h), MChannel(w: w, h: h), MChannel(w: w, h: h)]))
  var layout = @[(0, 0), (1, 0), (2, 0)]
  if alpha: layout.add (3, 0)
  var steps: array[3, seq[bool]]                       # (horizontal or not)
  for s in sq:
    let c2 = s.beginC + s.numC - 1
    let offset = if s.inPlace: c2 + 1 else: layout.len
    for c in s.beginC .. c2:
      let k = layout[c][0]
      steps[k].add s.horizontal
      layout.insert((k, steps[k].len), offset + c - s.beginC)
  # each component squeezed down, then built up again as the decoder will,
  # each step's residuals quantized against what the decoder has by then
  var parts: array[3, seq[MChannel]]
  var partQ: array[3, seq[int]]
  for k in 0 .. 2:
    var levels = @[move planes[k]]
    for hz in steps[k]: levels.add squeezeAvg(levels[^1], hz)
    let n = steps[k].len
    parts[k] = newSeq[MChannel](n + 1)
    partQ[k] = newSeq[int](n + 1)
    partQ[k][0] = 1                                     # (what is left, 8x8 at most, kept exactly)
    for j in countdown(n, 1):
      let q = lossyQuant(k, levels[j].hshift + levels[j].vshift, f)
      partQ[k][j] = q
      parts[k][j] = squeezeBack(levels[j - 1], levels[j], steps[k][j - 1], q,
                                q * 9 div 20)          # (a little toward 0: fewer bytes, as good)
      if j < n: levels[j] = MChannel()
    parts[k][0] = move levels[n]
  var img = MImage(bitDepth: 8)
  var qOf, kindOf: seq[int]
  for (k, j) in layout:
    if k == 3:
      var a = newChannel(w, h)
      for i, p in b.px: a.px[i] = int32(p shr 24)
      img.ch.add a
      qOf.add 1
      kindOf.add 2
    else:
      img.ch.add move parts[k][j]
      qOf.add partQ[k][j]
      kindOf.add (if j == 0: 1 else: 0)
  # each channel's part of the tree, its leaves' multipliers its quantizer
  var subs: seq[ENode]
  for c in 0 ..< img.ch.len: subs.add lossySubtree(img, c, qOf[c], kindOf[c], effort)
  # the streams: the global one (the channels up to the first larger than a
  # group), one for each LF group (the channels squeezed 3 times or more
  # across, of 2048x2048 pixels), one for each group (the others)
  const gdim = 256
  var firstBig = img.ch.len
  for c in 0 ..< img.ch.len:
    if img.ch[c].w > gdim or img.ch[c].h > gdim:
      firstBig = c
      break
  let xgroups = cdiv(w, gdim)
  let numGroups = xgroups * cdiv(h, gdim)
  let xlf = cdiv(w, gdim * 8)
  let numLfGroups = xlf * cdiv(h, gdim * 8)
  type Stream = object
    img: MImage
    id: int
    chans: seq[int]                                     # the picture's channels in it
  var streams = newSeq[Stream](1 + numLfGroups + numGroups)
  for c in 0 ..< firstBig:
    streams[0].img.ch.add img.ch[c]
    streams[0].chans.add c
  for g in 0 ..< numLfGroups: streams[1 + g].id = 1 + numLfGroups + g
  for g in 0 ..< numGroups: streams[1 + numLfGroups + g].id = 1 + 3 * numLfGroups + 17 + g
  for c in firstBig ..< img.ch.len:
    let ch = addr img.ch[c]
    let lf = min(ch.hshift, ch.vshift) >= 3
    let (n, size, xg, base) = if lf: (numLfGroups, gdim * 8, xlf, 1)
                              else: (numGroups, gdim, xgroups, 1 + numLfGroups)
    for g in 0 ..< n:
      let cx = ((g mod xg) * size) shr ch.hshift
      let cy = ((g div xg) * size) shr ch.vshift
      let cw = min(size shr ch.hshift, ch.w - cx)
      let chh = min(size shr ch.vshift, ch.h - cy)
      if cw > 0 and chh > 0:
        streams[base + g].img.ch.add cropChannel(ch[], cx, cy, cw, chh)
        streams[base + g].chans.add c
    ch.px = @[]                                         # (all in the groups now)
  # the tree: by the stream, the streams with the same channels together;
  # then by the channel (in the stream); then the channel's own part
  var classes: seq[seq[int]]
  var runs: seq[(int, int, int)]                        # (first stream id, last, class)
  for s in streams:
    if s.chans.len == 0: continue
    var k = classes.find(s.chans)
    if k < 0:
      k = classes.len
      classes.add s.chans
    if runs.len > 0 and runs[^1][2] == k: runs[^1][1] = s.id
    else: runs.add (s.id, s.id, k)
  proc sameLeaf(a, b: ENode): bool =
    a.prop < 0 and b.prop < 0 and a.pred == b.pred and max(1, a.mult) == max(1, b.mult)
  proc byChannel(items: seq[(int, ENode)]): ENode =    # (the last channel of a run, its tree)
    if items.len == 1: return items[0][1]
    let mid = items.len div 2
    ENode(prop: 0, split: int32(items[mid - 1][0]), left: byChannel(items[mid .. ^1]),
          right: byChannel(items[0 ..< mid]))
  proc byStream(runs: seq[(int, int, int)]; trees: seq[ENode]): ENode =
    if runs.len == 1: return trees[runs[0][2]]
    let mid = runs.len div 2
    ENode(prop: 1, split: int32(runs[mid - 1][1]), left: byStream(runs[mid .. ^1], trees),
          right: byStream(runs[0 ..< mid], trees))
  proc whole(subs: seq[ENode]; classes: seq[seq[int]]; runs: seq[(int, int, int)]): ENode =
    var classTrees: seq[ENode]
    for cl in classes:
      var items: seq[(int, ENode)]                      # (channels side by side with one leaf: one run)
      for i, c in cl:
        if items.len > 0 and sameLeaf(items[^1][1], subs[c]): items[^1][0] = i
        else: items.add (i, subs[c])
      classTrees.add byChannel(items)
    byStream(runs, classTrees)
  var alias: seq[int]
  var nodes = flatten(whole(subs, classes, runs), alias)
  if nodes.len > min(1 shl 22, 1024 + w * h * (3 + ord(alpha)) div 16):
    # (more nodes than a decoder takes: a leaf a channel, its predictor and multiplier)
    for n in subs.mitems:
      var l = n
      while l.prop >= 0: l = l.right
      n = ENode(prop: -1, pred: l.pred, mult: l.mult)
    alias.setLen(0)
    nodes = flatten(whole(subs, classes, runs), alias)
  let numLeaves = alias.len
  # the histograms (of each leaf the first time it is met: the others share it)
  var hs = newSeq[seq[int]](numLeaves)
  for i in 0 ..< numLeaves: hs[i] = newSeq[int](1)
  let wph = defaultWP()
  for s in streams:
    for c in 0 ..< s.img.ch.len:
      scanChannel(s.img, c, s.id, nodes, wph, 1, ctx, v):
        let a = alias[ctx]
        let t = tokenOf(v)[0]
        if t >= hs[a].len: hs[a].setLen(t + 1)
        inc hs[a][t]
  # the sections
  var lfg: BitWriter
  lfg.put(0, 1)                                         # the LF dequantization: XYB's scales
  for k in [1, 0, 2]: lfg.put(f16Bits(128 / XybScale[k]), 16)
  lfg.put(1, 1)                                         # a global tree:
  lfg.writeTree(nodes)
  let code = writeEntropyCode(lfg, numLeaves, hs, ans = true, alias = alias)
  let squeeze = MTransform(id: 2, squeezes: if alpha: sq else: @[])   # (the default ones: none)
  lfg.writeStream(streams[0].img, 0, @[squeeze], nodes, code, wph)
  var sections = @[lfg.bytes]
  if numGroups > 1:
    proc bytesOf(s: Stream; nodes: seq[TreeNode]; code: EncCode; wph: WPHeader): string =
      if s.chans.len == 0: return ""
      var gw: BitWriter
      gw.writeStream(s.img, s.id, @[], nodes, code, wph)
      gw.bytes
    for g in 0 ..< numLfGroups: sections.add bytesOf(streams[1 + g], nodes, code, wph)
    sections.add ""                                     # HF global
    for g in 0 ..< numGroups: sections.add bytesOf(streams[1 + numLfGroups + g], nodes, code, wph)
  frameFile(w, h, gray, alpha, true, sections)

proc encodeJxlDistance*(b: Bitmap; distance: float; effort = 3): string =
  ## A JPEG XL file of the picture at this distance (`jxlDistance`; 0 or
  ## less is lossless: `encodeJxlLossless`), as cjxl -m 1 writes one: in
  ## XYB, squeezed, the differences quantized (the multipliers of the MA
  ## tree's leaves), alpha kept exactly; a gray picture costs one channel.
  ## libjxl reads these files, to within a level of what `decodeJxl` gives.
  ## `effort` 1..9 changes the bytes, never the pixels: 1 and 2 contexts set
  ## beforehand, 3 and up learned from the picture (from more of it the
  ## higher). A 12-megapixel photo takes some 3.5 s at 3, 10 s at 7 on one core.
  if b.w <= 0 or b.h <= 0: raise newException(JxlError, "an empty picture")
  if distance <= 0: return encodeJxlLossless(b, effort)
  encodeLossy(b, min(distance, 25.0), effort)

proc encodeJxl*(b: Bitmap; quality = 90; effort = 3): string =
  ## A JPEG XL file of the picture at this quality, 1..100 as cjxl's -q
  ## takes it (`jxlDistance`: 90 is distance 1, about where a difference
  ## starts to show); 100 is lossless (`encodeJxlLossless`). See
  ## `encodeJxlDistance`.
  encodeJxlDistance(b, jxlDistance(quality), effort)

{.pop.}
