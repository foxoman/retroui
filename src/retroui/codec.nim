## Compression for retro, in plain Nim (no zlib): CRC-32, Adler-32,
## deflate (RFC 1951) and inflate, and the zlib wrapper (RFC 1950) PNG uses.
## Use it for zlib data of your own (a file format, a network answer); PNG,
## zip and PDF already use it. `Inflater` decompresses a stream a piece at a
## time.
##
## ```nim
## let packed = zlibCompress("hello, hello, hello".toBytes)
## let back = zlibDecompress(packed)
## echo crc32(back)
## ```

import std/[algorithm, bitops, base64]
import busy

type Bytes* = seq[byte]
  ## Bytes, as the codecs take and give them (`toBytes` makes them of a string).

proc unbase64*(text: string): string =
  ## The bytes of base64 `text` (the standard letters or the web's `-` and
  ## `_`; spaces, tabs and line ends left out). Raises `ValueError` on any
  ## other letter, before anything is made: Nim's own `decode` raising
  ## part way leaks the text it was making.
  var clean = newStringOfCap(text.len)
  for c in text:
    case c
    of 'A'..'Z', 'a'..'z', '0'..'9', '+', '/', '-', '_': clean.add c
    of '=': clean.add c
    of ' ', '\t', '\n', '\r': discard
    else: raise newException(ValueError, "not base64: the letter " & $ord(c))
  # ('=' only at the end: in the middle `decode` would refuse it)
  var k = clean.len
  while k > 0 and clean[k - 1] == '=': dec k
  if '=' in clean.toOpenArray(0, k - 1): raise newException(ValueError, "not base64: '=' inside")
  result = decode(clean)

proc toBytes*(s: string): Bytes =
  ## The bytes of `s`.
  result = newSeq[byte](s.len)
  if s.len > 0: copyMem(addr result[0], unsafeAddr s[0], s.len)

var crcTable: array[256, uint32]
for i in 0 .. 255:
  var c = uint32(i)
  for _ in 0 .. 7: c = if (c and 1) != 0: 0xEDB88320'u32 xor (c shr 1) else: c shr 1
  crcTable[i] = c

proc crcStep*(c: uint32; b: byte): uint32 {.inline.} =
  ## The CRC-32 register after one more byte (start 0xFFFFFFFF, end xor it).
  crcTable[(c xor b) and 0xFF] xor (c shr 8)

proc crc32*(data: openArray[byte]): uint32 =
  ## The CRC-32 of `data` (as zip and PNG use it).
  var c = 0xFFFFFFFF'u32
  for x in data: c = crcTable[(c xor x) and 0xFF] xor (c shr 8)
  c xor 0xFFFFFFFF'u32

# ---- deflate: LZ77 matches and the fixed Huffman codes ------------------------

const
  lenBase = [3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 17, 19, 23, 27, 31, 35, 43,
             51, 59, 67, 83, 99, 115, 131, 163, 195, 227, 258]
  lenExtra = [0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2, 3, 3, 3, 3, 4, 4,
              4, 4, 5, 5, 5, 5, 0]
  distBase = [1, 2, 3, 4, 5, 7, 9, 13, 17, 25, 33, 49, 65, 97, 129, 193, 257,
              385, 513, 769, 1025, 1537, 2049, 3073, 4097, 6145, 8193, 12289,
              16385, 24577]
  distExtra = [0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6, 7, 7, 8, 8, 9, 9,
               10, 10, 11, 11, 12, 12, 13, 13]

type BitWriter = object
  data: Bytes               # (`len` bytes of it used)
  len: int
  acc: uint64
  n: int                    # bits waiting in `acc` (< 32)

proc bits(w: var BitWriter; v, count: int) {.inline.} =
  ## `count` bits of `v` (at most 32), least significant first.
  w.acc = w.acc or (uint64(v) shl w.n)
  w.n += count
  if w.n >= 32:
    if w.len + 8 > w.data.len: w.data.setLen(max(256, w.data.len * 2))
    # (four bytes at once, the low one first)
    let a = w.acc
    w.data[w.len] = byte(a and 0xFF)
    w.data[w.len + 1] = byte((a shr 8) and 0xFF)
    w.data[w.len + 2] = byte((a shr 16) and 0xFF)
    w.data[w.len + 3] = byte((a shr 24) and 0xFF)
    w.len += 4
    w.acc = a shr 32
    w.n -= 32

proc align(w: var BitWriter) =
  ## Zeros to the next whole byte.
  let r = w.n and 7
  if r != 0: w.bits(0, 8 - r)

proc finish(w: var BitWriter): Bytes =
  ## The bytes written (the last ones padded with zeros).
  w.align()
  while w.n > 0:
    if w.len + 1 > w.data.len: w.data.setLen(max(256, w.data.len * 2))
    w.data[w.len] = byte(w.acc and 0xFF)
    inc w.len
    w.acc = w.acc shr 8
    w.n -= 8
  w.n = 0
  w.data.setLen(w.len)
  result = move(w.data)
  w.len = 0

proc revBits(c, len: int): int {.inline.} =
  for i in 0 ..< len: result = (result shl 1) or ((c shr i) and 1)

proc code(w: var BitWriter; c, len: int) =
  ## A Huffman code: its most significant bit goes first.
  w.bits(revBits(c, len), len)

proc literal(w: var BitWriter; v: int) =
  if v < 144: w.code(0x30 + v, 8)
  elif v < 256: w.code(0x190 + v - 144, 9)
  elif v < 280: w.code(v - 256, 7)
  else: w.code(0xC0 + v - 280, 8)

proc deflate*(data: openArray[byte]): Bytes =
  ## Raw deflate (RFC 1951) of `data`: greedy LZ77 over a 32 KB window,
  ## fixed Huffman codes. Small and quick; plenty for icons and libraries.
  var w: BitWriter
  w.bits(1, 1)                              # the last block
  w.bits(1, 2)                              # fixed Huffman codes
  const HashSize = 1 shl 15
  var head = newSeq[int32](HashSize)
  var prev = newSeq[int32](32768)
  for x in head.mitems: x = -1
  template hashAt(i: int): int =
    ((int(data[i]) shl 10) xor (int(data[i+1]) shl 5) xor int(data[i+2])) and
      (HashSize - 1)
  var i = 0
  let n = data.len
  var nextTick = 1 shl 20
  while i < n:
    if i >= nextTick:
      nextTick = i + (1 shl 20)
      busyTick()
    var bestLen = 0
    var bestDist = 0
    if i + 2 < n:
      let h = hashAt(i)
      var cand = int(head[h])
      var tries = 32
      while cand >= 0 and i - cand <= 32768 and tries > 0:
        var l = 0
        let maxLen = min(258, n - i)
        while l < maxLen and data[cand + l] == data[i + l]: inc l
        if l > bestLen:
          bestLen = l
          bestDist = i - cand
          if l == maxLen: break
        cand = int(prev[cand and 32767])
        dec tries
    if bestLen >= 3:
      var li = 0
      while li + 1 < lenBase.len and lenBase[li + 1] <= bestLen: inc li
      w.literal(257 + li)
      if lenExtra[li] > 0: w.bits(bestLen - lenBase[li], lenExtra[li])
      var di = 0
      while di + 1 < distBase.len and distBase[di + 1] <= bestDist: inc di
      w.code(di, 5)
      if distExtra[di] > 0: w.bits(bestDist - distBase[di], distExtra[di])
      for k in 0 ..< bestLen:              # remember every position passed
        if i + 2 < n:
          let h = hashAt(i)
          prev[i and 32767] = head[h]
          head[h] = int32(i)
        inc i
    else:
      w.literal(int(data[i]))
      if i + 2 < n:
        let h = hashAt(i)
        prev[i and 32767] = head[h]
        head[h] = int32(i)
      inc i
  w.literal(256)                            # end of block
  w.finish()


proc adler32*(data: openArray[byte]): uint32 =
  ## The Adler-32 checksum of `data` (the zlib trailer).
  var s1 = 1'u32
  var s2 = 0'u32
  var i = 0
  while i < data.len:
    let e = min(data.len, i + 5552)          # no overflow before the modulo
    while i < e:
      s1 += data[i]
      s2 += s1
      inc i
    s1 = s1 mod 65521
    s2 = s2 mod 65521
  (s2 shl 16) or s1

# ---- deflate with codes of its own: smaller, and on all the cores -----------

proc huffmanLengths(freq: openArray[int]; maxBits: int): seq[int] =
  ## Code lengths for symbols used `freq` times (0: not used), none longer
  ## than `maxBits` (Huffman's, then shortened as miniz does).
  let n = freq.len
  result = newSeq[int](n)
  var used: seq[int]
  for i in 0 ..< n:
    if freq[i] > 0: used.add i
  if used.len == 0: return
  if used.len == 1:
    result[used[0]] = 1
    return
  # Huffman's tree by two queues (the leaves sorted by weight)
  var fr = newSeq[int](n)
  for i in 0 ..< n: fr[i] = freq[i]
  used.sort(proc (a, b: int): int = cmp(fr[a], fr[b]))
  let m = used.len
  var weight = newSeq[int](2 * m)
  var parent = newSeq[int](2 * m)
  for i in 0 ..< m: weight[i] = fr[used[i]]
  var leaf = 0
  var inner = m
  var made = m
  proc pick(leaf, inner: var int; made: int): int =
    if leaf < m and (inner >= made or weight[leaf] <= weight[inner]):
      result = leaf
      inc leaf
    else:
      result = inner
      inc inner
  while made < 2 * m - 1:
    let a = pick(leaf, inner, made)
    let b = pick(leaf, inner, made)
    weight[made] = weight[a] + weight[b]
    parent[a] = made
    parent[b] = made
    inc made
  var depth = newSeq[int](2 * m)
  for k in countdown(2 * m - 3, 0): depth[k] = depth[parent[k]] + 1
  # how many codes of each length, the long ones made shorter
  var count = newSeq[int](max(maxBits, 64) + 1)
  for i in 0 ..< m: inc count[min(depth[i], 64)]
  for l in maxBits + 1 .. 64:
    count[maxBits] += count[l]
    count[l] = 0
  var total = 0
  for l in 1 .. maxBits: total += count[l] shl (maxBits - l)
  while total > (1 shl maxBits):
    dec count[maxBits]
    for l in countdown(maxBits - 1, 1):
      if count[l] > 0:
        dec count[l]
        count[l + 1] += 2
        break
    dec total
  # the shortest codes to the most used symbols
  var k = m - 1
  for l in 1 .. maxBits:
    for _ in 0 ..< count[l]:
      result[used[k]] = l
      dec k

proc canonical(lengths: openArray[int]): seq[int] =
  ## The canonical codes of `lengths` (as deflate numbers them).
  result = newSeq[int](lengths.len)
  var blCount: array[17, int]
  for l in lengths:
    if l > 0: inc blCount[l]
  var next: array[17, int]
  var code = 0
  for bits in 1 .. 16:
    code = (code + blCount[bits - 1]) shl 1
    next[bits] = code
  for i, l in lengths:
    if l > 0:
      result[i] = next[l]
      inc next[l]

proc lenSym(l: int): int {.inline.} =
  var li = 0
  while li + 1 < lenBase.len and lenBase[li + 1] <= l: inc li
  li

var lenTable: array[259, uint8]        # match length -> its length code (- 257)
var distTable: array[512, uint8]       # distance - 1 -> its code (small ones; big: by 128)
block:
  for l in 3 .. 258: lenTable[l] = uint8(lenSym(l))
  for d in 1 .. 32768:
    var di = 0
    while di + 1 < distBase.len and distBase[di + 1] <= d: inc di
    if d <= 256: distTable[d - 1] = uint8(di)
    elif ((d - 1) shr 7) < 256: distTable[256 + ((d - 1) shr 7)] = uint8(di)

proc distSym(d: int): int {.inline.} =
  if d <= 256: int(distTable[d - 1]) else: int(distTable[256 + ((d - 1) shr 7)])

{.push boundChecks: off, overflowChecks: off.}

proc deflateBlocks(w: var BitWriter; data: openArray[byte]; level: int; final: bool) =
  ## `data` as deflate blocks with codes of their own (the last one final
  ## when `final`; else the output ends on a whole byte after an empty
  ## stored block, so pieces made apart can be put one after the other).
  const HashBits = 15
  const HashSize = 1 shl HashBits
  const Window = 32768
  let tries = case level
              of 0, 1: 2
              of 2, 3: 6
              of 4, 5: 16
              of 6, 7: 32
              else: 128
  let lazy = level >= 4
  let quick = level <= 3          # (a long match: only its first places remembered)
  var head = newSeq[int32](HashSize)
  var prev = newSeq[int32](Window)
  for x in head.mitems: x = -1
  let n = data.len
  let data = if n > 0: cast[ptr UncheckedArray[byte]](unsafeAddr data[0]) else: nil
  let hp = cast[ptr UncheckedArray[int32]](addr head[0])
  let pp = cast[ptr UncheckedArray[int32]](addr prev[0])
  template hashAt(i: int): int =
    # (in 64 bits on every target: the constant does not fit a 32-bit int)
    int((((int64(data[i]) shl 16) or (int64(data[i+1]) shl 8) or int64(data[i+2])) *
         2654435761'i64) shr 17 and (HashSize - 1))
  template insert(i: int) =
    if i + 2 < n:
      let h = hashAt(i)
      pp[i and (Window - 1)] = hp[h]
      hp[h] = int32(i)
  template load8(i: int): uint64 =
    # (copied, not read through a uint64 pointer: any byte offset is
    # unaligned, undefined behaviour in C; it is still one load)
    var v: uint64
    copyMem(addr v, addr data[i], 8)
    v
  template matchLen(a, b, maxLen: int): int =
    ## how many bytes at `a` and `b` are the same (at most `maxLen`)
    var l = 0
    var going = true
    while going and l + 8 <= maxLen:
      let x = load8(a + l) xor load8(b + l)
      if x != 0:
        l += countTrailingZeroBits(x) shr 3
        going = false
      else: l += 8
    if going:
      while l < maxLen and data[a + l] == data[b + l]: inc l
    l
  var bestLen, bestDist: int
  template longest(i: int) =
    bestLen = 0
    bestDist = 0
    if i + 2 < n:
      var cand = int(hp[hashAt(i)])
      var t = tries
      let maxLen = min(258, n - i)
      while cand >= 0 and i - cand <= Window and t > 0:
        if data[cand + bestLen] == data[i + bestLen] and data[cand] == data[i]:
          let l = matchLen(cand, i, maxLen)
          if l > bestLen:
            bestLen = l
            bestDist = i - cand
            if l == maxLen: break
        let nxt = int(pp[cand and (Window - 1)])
        if nxt >= cand: break
        cand = nxt
        dec t
  # the symbols of a block: literal or (length, distance), then coded
  const BlockSyms = 1 shl 16
  var symBuf = newSeq[uint32](BlockSyms)   # literal: byte; match: length shl 16 or distance (+ 1 shl 31)
  var nsyms = 0
  let sb = cast[ptr UncheckedArray[uint32]](addr symBuf[0])
  template symAdd(v: uint32) =
    sb[nsyms] = v
    inc nsyms
  proc flushBlock(w: var BitWriter; syms: openArray[uint32]; last: bool) =
    var lf = newSeq[int](286)
    var df = newSeq[int](30)
    for s in syms:
      if (s and 0x8000_0000'u32) == 0: inc lf[int(s)]
      else:
        let l = int((s shr 16) and 0x7FFF)
        let d = int(s and 0xFFFF) + 1
        inc lf[257 + int(lenTable[l])]
        inc df[distSym(d)]
    lf[256] = 1
    var ll = huffmanLengths(lf, 15)
    var dl = huffmanLengths(df, 15)
    var anyDist = false
    for x in dl:
      if x > 0: anyDist = true
    if not anyDist: dl[0] = 1
    var hlit = 286
    while hlit > 257 and ll[hlit - 1] == 0: dec hlit
    var hdist = 30
    while hdist > 1 and dl[hdist - 1] == 0: dec hdist
    # the lengths, run-length coded with 16, 17, 18
    var all: seq[int]
    for i in 0 ..< hlit: all.add ll[i]
    for i in 0 ..< hdist: all.add dl[i]
    var rle: seq[(int, int)]         # (symbol, extra bits value)
    var i = 0
    while i < all.len:
      let v = all[i]
      var run = 1
      while i + run < all.len and all[i + run] == v: inc run
      if v == 0 and run >= 3:
        var r = run
        while r >= 11:
          let k = min(138, r)
          rle.add (18, k - 11)
          r -= k
        if r >= 3:
          rle.add (17, r - 3)
          r = 0
        for _ in 0 ..< r: rle.add (0, 0)
      elif v != 0 and run >= 4:
        rle.add (v, 0)
        var r = run - 1
        while r >= 3:
          let k = min(6, r)
          rle.add (16, k - 3)
          r -= k
        for _ in 0 ..< r: rle.add (v, 0)
      else:
        for _ in 0 ..< run: rle.add (v, 0)
      i += run
    var cf = newSeq[int](19)
    for (sy, _) in rle: inc cf[sy]
    let cl = huffmanLengths(cf, 7)
    const order = [16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15]
    var hclen = 19
    while hclen > 4 and cl[order[hclen - 1]] == 0: dec hclen
    # (the codes turned around once: written least significant bit first)
    var lc = canonical(ll)
    var dc = canonical(dl)
    let cc = canonical(cl)
    for k in 0 ..< lc.len: lc[k] = revBits(lc[k], ll[k])
    for k in 0 ..< dc.len: dc[k] = revBits(dc[k], dl[k])
    w.bits(ord(last), 1)
    w.bits(2, 2)
    w.bits(hlit - 257, 5)
    w.bits(hdist - 1, 5)
    w.bits(hclen - 4, 4)
    for k in 0 ..< hclen: w.bits(cl[order[k]], 3)
    for (sy, ex) in rle:
      w.code(cc[sy], cl[sy])
      case sy
      of 16: w.bits(ex, 2)
      of 17: w.bits(ex, 3)
      of 18: w.bits(ex, 7)
      else: discard
    for s in syms:
      if (s and 0x8000_0000'u32) == 0:
        w.bits(lc[int(s)], ll[int(s)])
      else:
        let l = int((s shr 16) and 0x7FFF)
        let d = int(s and 0xFFFF) + 1
        let li = int(lenTable[l])
        w.bits(lc[257 + li], ll[257 + li])
        if lenExtra[li] > 0: w.bits(l - lenBase[li], lenExtra[li])
        let di = distSym(d)
        w.bits(dc[di], dl[di])
        if distExtra[di] > 0: w.bits(d - distBase[di], distExtra[di])
    w.bits(lc[256], ll[256])
  var i = 0
  var pendLen = 0
  var pendDist = 0
  var havePend = false
  while i < n:
    longest(i)
    var l = bestLen
    let dd = bestDist
    if l < 3: l = 0
    if lazy and havePend:
      # the match one byte on is better: the byte before goes as a literal
      if l > pendLen:
        symAdd uint32(data[i - 1])
        pendLen = l
        pendDist = dd
        insert(i)
        inc i
        continue
      symAdd 0x8000_0000'u32 or (uint32(pendLen) shl 16) or uint32(pendDist - 1)
      # (the match from i - 1: its bytes from i on are passed)
      for k in 1 ..< pendLen:
        insert(i - 1 + k)
      i = i - 1 + pendLen
      havePend = false
    elif l >= 3:
      if lazy and l < 32 and i + 1 < n:
        havePend = true
        pendLen = l
        pendDist = dd
        insert(i)
        inc i
      else:
        symAdd 0x8000_0000'u32 or (uint32(l) shl 16) or uint32(dd - 1)
        if quick and l > 6:
          for k in 0 ..< 3: insert(i + k)
          insert(i + l - 2)
        else:
          for k in 0 ..< l: insert(i + k)
        i += l
    else:
      symAdd uint32(data[i])
      insert(i)
      inc i
    if nsyms >= BlockSyms - 2:
      w.flushBlock(symBuf.toOpenArray(0, nsyms - 1), false)
      nsyms = 0
  if havePend:
    symAdd 0x8000_0000'u32 or (uint32(pendLen) shl 16) or uint32(pendDist - 1)
  w.flushBlock(symBuf.toOpenArray(0, nsyms - 1), final)
  if not final:
    # an empty stored block: the output ends on a whole byte
    w.bits(0, 1)
    w.bits(0, 2)
    w.align()
    w.bits(0, 16)
    w.bits(0xFFFF, 16)
  else: w.align()

{.pop.}

proc deflateLevel*(data: openArray[byte]; level = 6): Bytes =
  ## Raw deflate of `data` with codes made for it (`level` 1 quick .. 9
  ## smallest): what PNG and zip writers want.
  var w: BitWriter
  w.deflateBlocks(data, level, true)
  w.finish()

proc adler32Combine*(a1, a2: uint32; len2: int): uint32 =
  ## The Adler-32 of two pieces put together (`len2`: the second's length).
  const Base = 65521'u32
  let rem = uint32(len2 mod 65521)
  var sum1 = a1 and 0xFFFF
  var sum2 = uint32((uint64(rem) * uint64(sum1)) mod Base)
  sum1 += (a2 and 0xFFFF) + Base - 1
  sum2 += ((a1 shr 16) and 0xFFFF) + ((a2 shr 16) and 0xFFFF) + Base - rem
  if sum1 >= Base: sum1 -= Base
  if sum1 >= Base: sum1 -= Base
  if sum2 >= (Base shl 1): sum2 -= (Base shl 1)
  if sum2 >= Base: sum2 -= Base
  sum1 or (sum2 shl 16)

var compressPieces*: proc (n: int; body: proc (lo, hi: int) {.closure.}) {.nimcall.}
  ## Runs `body` on pieces of `0 ..< n` at once (set by `retroui/parallel`;
  ## without it, one after the other).

proc deflatePieces*(data: openArray[byte]; piece: int; level = 6): tuple[stream: Bytes; sizes: seq[int]] =
  ## Raw deflate of `data` in pieces of `piece` bytes, each compressed on
  ## its own and ending on a whole byte (one stream all the same), with the
  ## compressed size of every piece: what an MSIX's block map lists.
  let n = data.len
  let pieces = max(1, (n + piece - 1) div piece)
  var outs = newSeq[Bytes](pieces)
  let dp = if n > 0: cast[ptr UncheckedArray[byte]](unsafeAddr data[0]) else: nil
  let op = cast[ptr UncheckedArray[Bytes]](addr outs[0])
  let body = proc (lo, hi: int) =
    for k in lo ..< hi:
      let a = k * piece
      let b = min(n, a + piece)
      var w: BitWriter
      if b > a: w.deflateBlocks(toOpenArray(dp, a, b - 1), level, k == pieces - 1)
      else: w.deflateBlocks(newSeq[byte](), level, true)
      op[k] = w.finish()
  if compressPieces != nil and pieces > 1: compressPieces(pieces, body)
  else: body(0, pieces)
  for o in outs:
    result.sizes.add o.len
    result.stream.add o

proc zlibCompressLevel*(data: openArray[byte]; level = 6): Bytes =
  ## A zlib stream of `data`: big data in pieces of a megabyte compressed
  ## at once on all the cores (each piece on its own, a little bigger than
  ## one stream would be).
  const Piece = 1 shl 20
  let n = data.len
  let pieces = max(1, (n + Piece - 1) div Piece)
  var outs = newSeq[Bytes](pieces)
  var adlers = newSeq[uint32](pieces)
  let dp = if n > 0: cast[ptr UncheckedArray[byte]](unsafeAddr data[0]) else: nil
  let op = cast[ptr UncheckedArray[Bytes]](addr outs[0])
  let ap = cast[ptr UncheckedArray[uint32]](addr adlers[0])
  let body = proc (lo, hi: int) =
    for k in lo ..< hi:
      let a = k * Piece
      let b = min(n, a + Piece)
      var w: BitWriter
      if b > a:
        w.deflateBlocks(toOpenArray(dp, a, b - 1), level, k == pieces - 1)
        ap[k] = adler32(toOpenArray(dp, a, b - 1))
      else:
        w.deflateBlocks(newSeq[byte](), level, true)
        ap[k] = 1
      op[k] = w.finish()
  if compressPieces != nil and pieces > 1: compressPieces(pieces, body)
  else: body(0, pieces)
  result = @[0x78'u8, 0x9C]
  var total = 2
  for o in outs: total += o.len
  result.setLen(total + 4)
  var at = 2
  for o in outs:
    if o.len > 0: copyMem(addr result[at], unsafeAddr o[0], o.len)
    at += o.len
  var a = adlers[0]
  for k in 1 ..< pieces:
    a = adler32Combine(a, adlers[k], min(n, (k + 1) * Piece) - k * Piece)
  for i in countdown(3, 0):
    result[at] = byte((a shr (8 * i)) and 0xFF)
    inc at

# ---- inflate -----------------------------------------------------------------

type
  InflateError* = object of CatchableError
    ## The data is not valid deflate (or zlib) data.

const FastBits = 9          ## codes this long or shorter decode in one lookup

type
  Huffman = object
    ## Canonical Huffman codes for decoding: a table for the short codes,
    ## first-code arithmetic for the long ones.
    fast: array[1 shl FastBits, uint16]   ## (length shl 9) or symbol; 0: slow path
    firstCode: array[17, int]
    maxCode: array[18, int]                ## (left-aligned to 16 bits)
    firstSymbol: array[17, int]
    size: array[288, uint8]
    value: array[288, uint16]

proc fail(msg: string) {.noreturn.} =
  raise newException(InflateError, msg)

proc reverseBits(v, n: int): int {.inline.} =
  var v = v
  for _ in 0 ..< n:
    result = (result shl 1) or (v and 1)
    v = v shr 1

proc build(h: var Huffman; lengths: openArray[int]) =
  var count: array[17, int]
  for l in lengths:
    if l < 0 or l > 15: fail("bad code length")
    inc count[l]
  count[0] = 0
  for i in 0 ..< h.fast.len: h.fast[i] = 0
  var nextCode: array[17, int]
  var code = 0
  var k = 0
  for i in 1 .. 15:
    nextCode[i] = code
    h.firstCode[i] = code
    h.firstSymbol[i] = k
    code += count[i]
    if count[i] > 0 and code - 1 >= (1 shl i): fail("bad Huffman lengths")
    h.maxCode[i] = code shl (16 - i)
    code = code shl 1
    k += count[i]
  h.maxCode[16] = 0x10000
  h.maxCode[17] = 0x10000
  for sym, l in lengths:
    if l == 0: continue
    let c = nextCode[l] - h.firstCode[l] + h.firstSymbol[l]
    h.size[c] = uint8(l)
    h.value[c] = uint16(sym)
    if l <= FastBits:
      var j = reverseBits(nextCode[l], l)
      while j < (1 shl FastBits):
        h.fast[j] = uint16((l shl 9) or sym)
        j += 1 shl l
    inc nextCode[l]

{.push boundChecks: off, overflowChecks: off.}

type BitReader = object
  pos: int                  ## next byte to load (past the end: zeros)
  buf: uint64
  bits: int

template fill(br: var BitReader; data: openArray[byte]) =
  while br.bits <= 56:
    if br.pos < data.len: br.buf = br.buf or (uint64(data[br.pos]) shl br.bits)
    elif br.pos > data.len + 8: fail("deflate data ends too soon")
    inc br.pos
    br.bits += 8

proc take(br: var BitReader; data: openArray[byte]; n: int): int {.inline.} =
  if br.bits < n: br.fill(data)
  result = int(br.buf and ((1'u64 shl n) - 1))
  br.buf = br.buf shr n
  br.bits -= n

proc decode(br: var BitReader; data: openArray[byte]; h: Huffman): int {.inline.} =
  if br.bits < 16: br.fill(data)
  let f = h.fast[int(br.buf and ((1'u64 shl FastBits) - 1))]
  if f != 0:
    let n = int(f shr 9)
    br.buf = br.buf shr n
    br.bits -= n
    return int(f and 511)
  # a long code: compare the bits (most significant first) with each length
  let k = reverseBits(int(br.buf and 0xFFFF), 16)
  var s = FastBits + 1
  while s < 16 and k >= h.maxCode[s]: inc s
  if s >= 16: fail("bad Huffman code")
  let b = (k shr (16 - s)) - h.firstCode[s] + h.firstSymbol[s]
  if b < 0 or b >= 288 or int(h.size[b]) != s: fail("bad Huffman code")
  br.buf = br.buf shr s
  br.bits -= s
  int(h.value[b])

proc inflate*(data: openArray[byte]; start = 0;
              consumed: ptr int = nil; maxOut = high(int)): Bytes =
  ## Raw deflate data from `data[start..]` (RFC 1951). `consumed`, if
  ## given, gets the number of bytes the compressed stream used. More than
  ## `maxOut` bytes of output is an error (a "zip bomb" stops there).
  var br = BitReader(pos: start)
  var n = 0                                  # bytes of output so far
  result = newSeq[byte](min(maxOut, max(1024, (data.len - start) * 4)))
  template room(k: int) =
    if n + k > maxOut: fail("more data than expected")
    if n + k > result.len: result.setLen(min(maxOut, max(n + k, result.len * 2)))
  var fixedLit, fixedDist, dynLit, dynDist: Huffman
  var fixedBuilt = false
  var lengths: array[320, int]
  var last = 0
  while last == 0:
    if onUiThread() and data.len > (4 shl 20): busyFraction = br.pos / data.len
    busyTick()                               # (a big picture: the window kept alive)
    last = br.take(data, 1)
    let kind = br.take(data, 2)
    if kind == 0:                            # stored
      discard br.take(data, br.bits and 7)   # to a byte boundary
      let len = br.take(data, 16)
      let nlen = br.take(data, 16)
      if len != (not nlen and 0xFFFF): fail("stored block length is damaged")
      room(len)
      for i in 0 ..< len:
        if br.bits >= 8:
          result[n] = byte(br.take(data, 8))
        else:
          # (the buffer is empty: copy straight from the data)
          let p = br.pos
          if p >= data.len: fail("stored block ends too soon")
          result[n] = data[p]
          inc br.pos
        inc n
      continue
    if kind == 1:                            # fixed codes
      if not fixedBuilt:
        for i in 0 ..< 144: lengths[i] = 8
        for i in 144 ..< 256: lengths[i] = 9
        for i in 256 ..< 280: lengths[i] = 7
        for i in 280 ..< 288: lengths[i] = 8
        fixedLit.build(lengths.toOpenArray(0, 287))
        for i in 0 ..< 30: lengths[i] = 5
        fixedDist.build(lengths.toOpenArray(0, 29))
        fixedBuilt = true
    elif kind == 2:                          # dynamic codes
      let nlen = br.take(data, 5) + 257
      let ndist = br.take(data, 5) + 1
      let ncode = br.take(data, 4) + 4
      if nlen > 286 or ndist > 30: fail("bad code counts")
      const order = [16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15]
      var cl: array[19, int]
      for i in 0 ..< ncode: cl[order[i]] = br.take(data, 3)
      var lencode: Huffman
      lencode.build(cl)
      var i = 0
      while i < nlen + ndist:
        let sym = br.decode(data, lencode)
        if sym < 16:
          lengths[i] = sym
          inc i
        else:
          var rep, val = 0
          case sym
          of 16:
            if i == 0: fail("repeat with no length")
            val = lengths[i - 1]
            rep = 3 + br.take(data, 2)
          of 17: rep = 3 + br.take(data, 3)
          of 18: rep = 11 + br.take(data, 7)
          else: fail("bad code length code")
          if i + rep > nlen + ndist: fail("too many lengths")
          for k in 0 ..< rep:
            lengths[i] = val
            inc i
      if lengths[256] == 0: fail("no end-of-block code")
      dynLit.build(lengths.toOpenArray(0, nlen - 1))
      dynDist.build(lengths.toOpenArray(nlen, nlen + ndist - 1))
    else: fail("bad block type")
    template codes(lit, dist: Huffman) =
      while true:                            # the block's symbols
        let sym = br.decode(data, lit)
        if sym < 256:
          room(1)
          result[n] = byte(sym)
          inc n
        elif sym == 256: break
        else:
          let li = sym - 257
          if li >= 29: fail("bad length code")
          let length = lenBase[li] + br.take(data, lenExtra[li])
          let di = br.decode(data, dist)
          if di >= 30: fail("bad distance code")
          let dst = distBase[di] + br.take(data, distExtra[di])
          if dst > n: fail("distance too far back")
          room(length)
          var src = n - dst
          if dst >= length:
            copyMem(addr result[n], addr result[src], length)
            n += length
          else:
            # (bytes repeat what this very copy writes: one at a time)
            for k in 0 ..< length:
              result[n] = result[src]
              inc n
              inc src
    if kind == 1: codes(fixedLit, fixedDist)
    else: codes(dynLit, dynDist)
  # what the stream used: the bytes loaded, less the whole bytes not used
  let used = br.pos - br.bits div 8
  if used > data.len: fail("deflate data ends too soon")
  result.setLen(n)
  if consumed != nil: consumed[] = used - start
  if onUiThread() and data.len > (4 shl 20): busyFraction = -1

{.pop.}

# ---- inflate a little at a time ----------------------------------------------

type
  InflatePiece* = proc (): tuple[p: pointer; n: int] {.closure, gcsafe.}
    ## The next piece of the compressed data (`n` 0: there is no more).

  Inflater* = object
    ## A deflate or zlib stream inflated a little at a time (`inflateRead`):
    ## its compressed bytes taken from `next` as they are needed, its
    ## output kept in a window of 256 KB -- the memory is that, however big
    ## the data (a big picture read row by row).
    next: InflatePiece
    inp: ptr UncheckedArray[byte]
    inLen, inPos: int
    ended: bool                    # (`next` gave nothing more)
    past: int                      # zero bytes put in past the end
    buf: uint64
    bits: int
    win: seq[byte]
    wpos, rpos: int                # bytes made, bytes handed out (from the start)
    stage: int                     # 0: a block next, 1: stored, 2: coded, 3: the end
    last: bool
    stored: int                    # bytes left of a stored block
    lit, dist: Huffman
    zlib, headDone: bool
    s1, s2: uint32                 # Adler-32 of what was handed out
    want: int64                    # the trailer's Adler-32 (-1: none)

const
  WinBits = 18
  WinSize = 1 shl WinBits
  WinMask = WinSize - 1
  WinRoom = WinSize - 32768 - 258  ## (what may wait to be handed out: the
                                   ## 32 KB looked back at stay)

proc initInflater*(next: InflatePiece; zlib = true): Inflater =
  ## An inflater of the data `next` gives, piece by piece: a zlib stream
  ## (RFC 1950, its checksum checked when all of it was read), or raw
  ## deflate (`zlib` false).
  Inflater(next: next, win: newSeq[byte](WinSize), zlib: zlib, s1: 1, want: -1)

{.push boundChecks: off, overflowChecks: off.}

proc refill(z: var Inflater) =
  while true:
    let (p, n) = z.next()
    if n <= 0 or p == nil:
      z.ended = true
      z.inp = nil
      z.inLen = 0
      z.inPos = 0
      return
    z.inp = cast[ptr UncheckedArray[byte]](p)
    z.inLen = n
    z.inPos = 0
    return

proc fillBits(z: var Inflater) =
  while z.bits <= 56:
    if z.inPos < z.inLen:
      z.buf = z.buf or (uint64(z.inp[z.inPos]) shl z.bits)
      inc z.inPos
    elif not z.ended:
      z.refill()
      continue
    else:
      inc z.past
      if z.past > 8: fail("deflate data ends too soon")
    z.bits += 8

proc take(z: var Inflater; n: int): int {.inline.} =
  if n == 0: return 0
  if z.bits < n: z.fillBits()
  result = int(z.buf and ((1'u64 shl n) - 1))
  z.buf = z.buf shr n
  z.bits -= n

proc decode(z: var Inflater; h: Huffman): int {.inline.} =
  if z.bits < 16: z.fillBits()
  let f = h.fast[int(z.buf and ((1'u64 shl FastBits) - 1))]
  if f != 0:
    let n = int(f shr 9)
    z.buf = z.buf shr n
    z.bits -= n
    return int(f and 511)
  let k = reverseBits(int(z.buf and 0xFFFF), 16)
  var s = FastBits + 1
  while s < 16 and k >= h.maxCode[s]: inc s
  if s >= 16: fail("bad Huffman code")
  let b = (k shr (16 - s)) - h.firstCode[s] + h.firstSymbol[s]
  if b < 0 or b >= 288 or int(h.size[b]) != s: fail("bad Huffman code")
  z.buf = z.buf shr s
  z.bits -= s
  int(h.value[b])

proc blockHeader(z: var Inflater) =
  ## A block's first bits: stored, or its codes.
  z.last = z.take(1) == 1
  let kind = z.take(2)
  case kind
  of 0:
    discard z.take(z.bits and 7)               # (to a byte boundary)
    let len = z.take(16)
    let nlen = z.take(16)
    if len != (not nlen and 0xFFFF): fail("stored block length is damaged")
    z.stored = len
    z.stage = 1
  of 1:
    var lengths: array[288, int]
    for i in 0 ..< 144: lengths[i] = 8
    for i in 144 ..< 256: lengths[i] = 9
    for i in 256 ..< 280: lengths[i] = 7
    for i in 280 ..< 288: lengths[i] = 8
    z.lit.build(lengths)
    for i in 0 ..< 30: lengths[i] = 5
    z.dist.build(lengths.toOpenArray(0, 29))
    z.stage = 2
  of 2:
    let nlen = z.take(5) + 257
    let ndist = z.take(5) + 1
    let ncode = z.take(4) + 4
    if nlen > 286 or ndist > 30: fail("bad code counts")
    const order = [16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15]
    var cl: array[19, int]
    for i in 0 ..< ncode: cl[order[i]] = z.take(3)
    var lencode: Huffman
    lencode.build(cl)
    var lengths: array[320, int]
    var i = 0
    while i < nlen + ndist:
      let sym = z.decode(lencode)
      if sym < 16:
        lengths[i] = sym
        inc i
      else:
        var rep, val = 0
        case sym
        of 16:
          if i == 0: fail("repeat with no length")
          val = lengths[i - 1]
          rep = 3 + z.take(2)
        of 17: rep = 3 + z.take(3)
        of 18: rep = 11 + z.take(7)
        else: fail("bad code length code")
        if i + rep > nlen + ndist: fail("too many lengths")
        for k in 0 ..< rep:
          lengths[i] = val
          inc i
    if lengths[256] == 0: fail("no end-of-block code")
    z.lit.build(lengths.toOpenArray(0, nlen - 1))
    z.dist.build(lengths.toOpenArray(nlen, nlen + ndist - 1))
    z.stage = 2
  else: fail("bad block type")

proc ending(z: var Inflater) =
  ## The last block ended: the zlib trailer, when it is there.
  z.stage = 3
  if not z.zlib: return
  discard z.take(z.bits and 7)
  z.fillBits()
  if z.bits - 8 * z.past >= 32:
    var a = 0
    for _ in 0 .. 3: a = (a shl 8) or z.take(8)
    z.want = a

proc produce(z: var Inflater; want: int) =
  ## Inflates until `want` bytes wait to be handed out, or the window is
  ## full, or the stream ended.
  if not z.headDone:
    z.headDone = true
    if z.zlib:
      let cmf = z.take(8)
      let flg = z.take(8)
      if (cmf and 0x0F) != 8 or ((cmf shl 8) or flg) mod 31 != 0: fail("not a zlib stream")
      if (flg and 0x20) != 0: fail("zlib preset dictionaries are not supported")
  let w = cast[ptr UncheckedArray[byte]](addr z.win[0])
  while z.stage != 3 and z.wpos - z.rpos < want and z.wpos - z.rpos < WinRoom:
    case z.stage
    of 0: z.blockHeader()
    of 1:
      # (stored bytes: those left in the bit buffer, then straight from the data)
      while z.stored > 0 and z.wpos - z.rpos < WinRoom:
        if z.bits >= 8:
          w[z.wpos and WinMask] = byte(z.take(8))
          inc z.wpos
          dec z.stored
        elif z.inPos < z.inLen:
          let k = min(min(z.stored, z.inLen - z.inPos),
                      min(WinRoom - (z.wpos - z.rpos), WinSize - (z.wpos and WinMask)))
          copyMem(addr w[z.wpos and WinMask], addr z.inp[z.inPos], k)
          z.inPos += k
          z.wpos += k
          z.stored -= k
        elif not z.ended: z.refill()
        else: fail("stored block ends too soon")
      if z.stored == 0:
        if z.last: z.ending() else: z.stage = 0
    else:
      while z.wpos - z.rpos < want and z.wpos - z.rpos < WinRoom:
        let sym = z.decode(z.lit)
        if sym < 256:
          w[z.wpos and WinMask] = byte(sym)
          inc z.wpos
        elif sym == 256:
          if z.last: z.ending() else: z.stage = 0
          break
        else:
          let li = sym - 257
          if li >= 29: fail("bad length code")
          let length = lenBase[li] + z.take(lenExtra[li])
          let di = z.decode(z.dist)
          if di >= 30: fail("bad distance code")
          let dst = distBase[di] + z.take(distExtra[di])
          if dst > z.wpos: fail("distance too far back")
          let d0 = z.wpos and WinMask
          let s0 = (z.wpos - dst) and WinMask
          if d0 + length <= WinSize and s0 + length <= WinSize and dst >= length:
            copyMem(addr w[d0], addr w[s0], length)
          elif dst == 1 and d0 + length <= WinSize:
            let v = w[s0]                                    # (a run of one byte)
            for k in 0 ..< length: w[d0 + k] = v
          else:
            for k in 0 ..< length:
              w[(z.wpos + k) and WinMask] = w[(z.wpos - dst + k) and WinMask]
          z.wpos += length

proc inflateRead*(z: var Inflater; dst: pointer; n: int): int =
  ## Up to `n` bytes of the output into `dst`: fewer only where the stream
  ## ends (then 0). Raises `InflateError` when the data is damaged.
  let o = cast[ptr UncheckedArray[byte]](dst)
  while result < n:
    if z.wpos == z.rpos:
      if z.stage == 3: break
      z.produce(n - result)
      if z.wpos == z.rpos: continue
    let k = min(z.wpos - z.rpos, n - result)
    var done = 0
    while done < k:
      let at = (z.rpos + done) and WinMask
      let m = min(k - done, WinSize - at)
      copyMem(addr o[result + done], addr z.win[at], m)
      done += m
    if z.zlib:
      # (the Adler-32 as it goes, for the trailer)
      var i = result
      let e = result + k
      while i < e:
        let stop = min(e, i + 5552)
        while i < stop:
          z.s1 += o[i]
          z.s2 += z.s1
          inc i
        z.s1 = z.s1 mod 65521
        z.s2 = z.s2 mod 65521
    z.rpos += k
    result += k
  if z.stage == 3 and z.rpos == z.wpos and z.want >= 0:
    if uint32(z.want) != ((z.s2 shl 16) or z.s1): fail("zlib checksum does not match")
    z.want = -1

{.pop.}

proc zlibCompress*(data: openArray[byte]): Bytes =
  ## A zlib stream (RFC 1950) of `data`.
  result = @[0x78'u8, 0x9C]
  result.add deflate(data)
  let a = adler32(data)
  for i in countdown(3, 0): result.add byte((a shr (8 * i)) and 0xFF)

proc zlibDecompress*(data: openArray[byte]; maxOut = high(int)): Bytes =
  ## The data of a zlib stream; raises `InflateError` if it is damaged (or
  ## would be longer than `maxOut` bytes).
  if data.len < 6 or (data[0] and 0x0F) != 8 or
     ((int(data[0]) shl 8) or int(data[1])) mod 31 != 0:
    fail("not a zlib stream")
  if (data[1] and 0x20) != 0: fail("zlib preset dictionaries are not supported")
  var used = 0
  result = inflate(data, 2, addr used, maxOut)
  let p = 2 + used
  if p + 4 <= data.len:
    let want = (uint32(data[p]) shl 24) or (uint32(data[p+1]) shl 16) or
               (uint32(data[p+2]) shl 8) or uint32(data[p+3])
    if want != adler32(result): fail("zlib checksum does not match")
