## WebP pictures in plain Nim, read and written.
##
## Read, giving the very pixels libwebp gives: lossy (VP8 key frames: every
## intra mode, segments, both loop filters and their sharpness, the token
## probabilities a file updates, several partitions; YUV 4:2:0 brought to
## RGB with libwebp's "fancy" upsampling), lossless (VP8L: all four
## transforms, the color cache, LZ77, the meta prefix codes), extended files
## (VP8X; ICC, EXIF, XMP and unknown chunks passed over), transparency
## (ALPH: raw or lossless, its filters) and animations (ANIM / ANMF: each
## frame placed, blended and disposed of as libwebp's WebPAnimDecoder does).
##
## Written: lossless (VP8L: subtract green, the predictor and cross-color
## transforms, or a palette when there are few colors; LZ77 by hash chains
## then re-parsed for the fewest bits, a color cache, the prefix codes of
## each group of tiles alike); lossy (VP8 key frames: the 16x16 and 4x4
## intra modes of each macroblock chosen by rate and distortion, the
## quantizers from a quality 0..100 as libwebp maps it, the token
## probabilities fitted to the picture, the loop filter's level chosen by
## trying; transparency kept losslessly in an ALPH chunk); animations (only
## the rectangle that changed, each frame).
##
## Pixels are `Bitmap`s: 0xAARRGGBB, straight (not premultiplied) alpha.
## Damaged files raise `WebpError`.
##
## .. code-block:: nim
##   let pic = decodeWebp(readFile("photo.webp"))
##   writeFile("small.webp", encodeWebp(pic, quality = 75))
##   writeFile("exact.webp", encodeWebpLossless(pic))
##   for (frame, ms) in decodeWebpFrames(readFile("anim.webp")):
##     echo frame.w, "x", frame.h, " for ", ms, " ms"

import std/[math, bitops, algorithm]
import gfx

type
  WebpError* = object of CatchableError
    ## A file that is not WebP, or is damaged, or uses what WebP does not have.

proc fail(msg: string) {.noreturn.} = raise newException(WebpError, msg)

template bytesOf(s: string): ptr UncheckedArray[byte] =
  cast[ptr UncheckedArray[byte]](unsafeAddr s[0])

proc u8(s: string; i: int): int {.inline.} = int(uint8(s[i]))
proc le16(s: string; i: int): int {.inline.} = u8(s, i) or (u8(s, i + 1) shl 8)
proc le24(s: string; i: int): int {.inline.} = le16(s, i) or (u8(s, i + 2) shl 16)
proc le32(s: string; i: int): int {.inline.} = le24(s, i) or (u8(s, i + 3) shl 24)

proc toBitmap(w, h: int; px: sink seq[uint32]): Bitmap =
  result = newBitmap(0, 0)
  result.w = w
  result.h = h
  result.px = px
  var opaque = true
  for p in result.px:
    if p < 0xFF000000'u32:
      opaque = false
      break
  result.opaque = opaque
  result.changed()

{.push boundChecks: off, overflowChecks: off, rangeChecks: off.}

# ---- VP8L: the lossless bitstream, read -------------------------------------------------------

type
  LBits = object
    ## Bits read from the lowest of each byte up (as VP8L stores them).
    buf: ptr UncheckedArray[byte]
    len, pos: int
    val: uint64
    nb: int              # bits in `val`
    past: int            # bytes put in past the end (zeros)

proc lbits(data: string; a, b: int): LBits =
  result.len = b - a
  if result.len > 0: result.buf = cast[ptr UncheckedArray[byte]](unsafeAddr data[a])

proc fill(r: var LBits) {.inline.} =
  while r.nb <= 56:
    if r.pos < r.len:
      r.val = r.val or (uint64(r.buf[r.pos]) shl r.nb)
      inc r.pos
    else:
      inc r.past
    r.nb += 8

proc bits(r: var LBits; n: int): int {.inline.} =
  if r.nb < n: r.fill()
  result = int(r.val and ((1'u64 shl n) - 1))
  r.val = r.val shr n
  r.nb -= n

proc overrun(r: LBits): bool {.inline.} = r.past * 8 > r.nb
  ## Bits were taken from beyond the end of the data.

const
  HRoot = 8              # bits looked up at once (the first level of a table)
  CodeLengthOrder = [17, 18, 0, 1, 2, 3, 4, 5, 16, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15]
  # the 120 nearby places a distance code can name: (dx, dy), distance = dx + dy * width
  PlaneCodes = [(0, 1), (1, 0), (1, 1), (-1, 1), (0, 2), (2, 0), (1, 2), (-1, 2),
    (2, 1), (-2, 1), (2, 2), (-2, 2), (0, 3), (3, 0), (1, 3), (-1, 3),
    (3, 1), (-3, 1), (2, 3), (-2, 3), (3, 2), (-3, 2), (0, 4), (4, 0),
    (1, 4), (-1, 4), (4, 1), (-4, 1), (3, 3), (-3, 3), (2, 4), (-2, 4),
    (4, 2), (-4, 2), (0, 5), (3, 4), (-3, 4), (4, 3), (-4, 3), (5, 0),
    (1, 5), (-1, 5), (5, 1), (-5, 1), (2, 5), (-2, 5), (5, 2), (-5, 2),
    (4, 4), (-4, 4), (3, 5), (-3, 5), (5, 3), (-5, 3), (0, 6), (6, 0),
    (1, 6), (-1, 6), (6, 1), (-6, 1), (2, 6), (-2, 6), (6, 2), (-6, 2),
    (4, 5), (-4, 5), (5, 4), (-5, 4), (3, 6), (-3, 6), (6, 3), (-6, 3),
    (0, 7), (7, 0), (1, 7), (-1, 7), (5, 5), (-5, 5), (7, 1), (-7, 1),
    (4, 6), (-4, 6), (6, 4), (-6, 4), (2, 7), (-2, 7), (7, 2), (-7, 2),
    (3, 7), (-3, 7), (7, 3), (-7, 3), (5, 6), (-5, 6), (6, 5), (-6, 5),
    (8, 0), (4, 7), (-4, 7), (7, 4), (-7, 4), (8, 1), (8, 2), (6, 6),
    (-6, 6), (8, 3), (5, 7), (-5, 7), (7, 5), (-7, 5), (8, 4), (6, 7),
    (-6, 7), (7, 6), (-7, 6), (8, 5), (7, 7), (-7, 7), (8, 6), (8, 7)]

proc subSize(size, bits: int): int {.inline.} = (size + (1 shl bits) - 1) shr bits

proc planeDistance(width, code: int): int {.inline.} =
  if code > 120: return code - 120
  let (dx, dy) = PlaneCodes[code - 1]
  max(1, dx + dy * width)

proc nextKey(key: uint32; len: int): uint32 {.inline.} =
  var step = 1'u32 shl (len - 1)
  while (key and step) != 0: step = step shr 1
  if step != 0: (key and (step - 1)) + step else: key

proc replicate(t: var seq[uint32]; at, step, size: int; code: uint32) {.inline.} =
  var e = size
  while e > 0:
    e -= step
    t[at + e] = code

proc buildHuffman(t: var seq[uint32]; lengths: openArray[int32]): int =
  ## Adds the lookup table of the prefix code with these code lengths (0 for
  ## an unused symbol) to the end of `t` (entries: symbol shl 16 or bits);
  ## its size, or 0 when the lengths make no code (as libwebp judges).
  var count: array[16, int]
  for l in lengths:
    if l < 0 or l > 15: return 0
    inc count[l]
  if count[0] == lengths.len: return 0
  var offset: array[16, int]
  for l in 1 ..< 15:
    if count[l] > (1 shl l): return 0
    offset[l + 1] = offset[l] + count[l]
  var sorted = newSeq[int](lengths.len)
  for s, l in lengths:
    if l > 0:
      sorted[offset[l]] = s
      inc offset[l]
  let root = t.len
  var total = 1 shl HRoot
  t.setLen(root + total)
  if offset[15] == 1:              # one symbol: no bits at all
    for i in 0 ..< total: t[root + i] = uint32(sorted[0]) shl 16
    return total
  var key = 0'u32
  var nodes = 1
  var open = 1
  var sym = 0
  var step = 2
  for len in 1 .. HRoot:
    open = open shl 1
    nodes += open
    open -= count[len]
    if open < 0:
      t.setLen(root)
      return 0
    for _ in 0 ..< count[len]:
      replicate(t, root + int(key), step, 1 shl HRoot, (uint32(sorted[sym]) shl 16) or uint32(len))
      inc sym
      key = nextKey(key, len)
    step = step shl 1
  var tableAt = root
  var tableSize = 1 shl HRoot
  var low = 0xFFFFFFFF'u32
  let mask = uint32((1 shl HRoot) - 1)
  step = 2
  for len in HRoot + 1 .. 15:
    open = open shl 1
    nodes += open
    open -= count[len]
    if open < 0:
      t.setLen(root)
      return 0
    while count[len] > 0:
      if (key and mask) != low:
        tableAt += tableSize
        # the width of the next second-level table
        var l = len
        var left = 1 shl (l - HRoot)
        while l < 15:
          left -= count[l]
          if left <= 0: break
          inc l
          left = left shl 1
        tableSize = 1 shl (l - HRoot)
        total += tableSize
        t.setLen(root + total)
        low = key and mask
        t[root + int(low)] = (uint32(tableAt - root - int(low)) shl 16) or uint32(l)
      replicate(t, tableAt + int(key shr HRoot), step, tableSize,
                (uint32(sorted[sym]) shl 16) or uint32(len - HRoot))
      inc sym
      key = nextKey(key, len)
      dec count[len]
    step = step shl 1
  if nodes != 2 * offset[15] - 1:
    t.setLen(root)
    return 0
  total

proc readSym(r: var LBits; t: ptr UncheckedArray[uint32]): int {.inline.} =
  if r.nb < 15: r.fill()
  var i = int(r.val and 0xFF)
  var e = t[i]
  var n = int(e and 0xFF)
  if n > HRoot:
    r.val = r.val shr HRoot
    r.nb -= HRoot
    i += int(e shr 16) + int(r.val and ((1'u64 shl (n - HRoot)) - 1))
    e = t[i]
    n = int(e and 0xFF)
  r.val = r.val shr n
  r.nb -= n
  int(e shr 16)

proc readCodeLengths(r: var LBits; clLengths: openArray[int32]; lengths: var seq[int32];
                     alphabet: int) =
  var t: seq[uint32]
  if buildHuffman(t, clLengths) == 0: fail("damaged lossless WebP (code lengths)")
  let tp = cast[ptr UncheckedArray[uint32]](addr t[0])
  var maxSym = alphabet
  if r.bits(1) == 1:
    let n = 2 + 2 * r.bits(3)
    maxSym = 2 + r.bits(n)
    if maxSym > alphabet: fail("damaged lossless WebP (code lengths)")
  var sym = 0
  var prev = 8'i32
  while sym < alphabet:
    if maxSym == 0: break
    dec maxSym
    let c = readSym(r, tp)
    if c < 16:
      lengths[sym] = int32(c)
      inc sym
      if c != 0: prev = int32(c)
    else:
      let slot = c - 16
      let repeat = r.bits([2, 3, 7][slot]) + [3, 3, 11][slot]
      if sym + repeat > alphabet: fail("damaged lossless WebP (code lengths)")
      let v = if c == 16: prev else: 0'i32
      for _ in 0 ..< repeat:
        lengths[sym] = v
        inc sym

proc readCode(r: var LBits; alphabet: int; t: var seq[uint32]; keep: bool): int =
  ## Reads one prefix code; adds its table to `t` (when `keep`), giving where.
  var lengths = newSeq[int32](alphabet)
  if r.bits(1) == 1:                      # one or two symbols, given outright
    let n = r.bits(1) + 1
    let s0 = r.bits(if r.bits(1) == 0: 1 else: 8)
    if s0 < alphabet: lengths[s0] = 1
    if n == 2:
      let s1 = r.bits(8)
      if s1 < alphabet: lengths[s1] = 1
  else:
    var cl: array[19, int32]
    let n = r.bits(4) + 4
    for i in 0 ..< n: cl[CodeLengthOrder[i]] = int32(r.bits(3))
    readCodeLengths(r, cl, lengths, alphabet)
  if r.overrun: fail("damaged lossless WebP (truncated)")
  result = t.len
  if buildHuffman(t, lengths) == 0: fail("damaged lossless WebP (prefix code)")
  if not keep: t.setLen(result)

proc prefixValue(r: var LBits; sym: int): int {.inline.} =
  if sym < 4: return sym + 1
  let extra = (sym - 2) shr 1
  ((2 + (sym and 1)) shl extra) + r.bits(extra) + 1

proc addPixels(a, b: uint32): uint32 {.inline.} =
  (((a and 0xFF00FF00'u32) + (b and 0xFF00FF00'u32)) and 0xFF00FF00'u32) or
    (((a and 0x00FF00FF'u32) + (b and 0x00FF00FF'u32)) and 0x00FF00FF'u32)

proc avg2(a, b: uint32): uint32 {.inline.} = (((a xor b) and 0xFEFEFEFE'u32) shr 1) + (a and b)

proc clip255(v: int): uint32 {.inline.} = uint32(if v < 0: 0 elif v > 255: 255 else: v)

proc selectPred(t, l, tl: uint32): uint32 {.inline.} =
  var s = 0
  for sh in [24, 16, 8, 0]:
    let a = int((t shr sh) and 255)
    let b = int((l shr sh) and 255)
    let c = int((tl shr sh) and 255)
    s += abs(b - c) - abs(a - c)
  if s <= 0: t else: l

proc clampAddSubFull(a, b, c: uint32): uint32 {.inline.} =
  for sh in [24, 16, 8, 0]:
    let v = int((a shr sh) and 255) + int((b shr sh) and 255) - int((c shr sh) and 255)
    result = result or (clip255(v) shl sh)

proc clampAddSubHalf(a, b, c: uint32): uint32 {.inline.} =
  let ave = avg2(a, b)
  for sh in [24, 16, 8, 0]:
    let x = int((ave shr sh) and 255)
    let y = int((c shr sh) and 255)
    result = result or (clip255(x + (x - y) div 2) shl sh)

proc predict(mode: int; p: ptr UncheckedArray[uint32]; i, w: int): uint32 {.inline.} =
  ## The prediction of pixel `i` (not on the first row or column) by `mode`.
  case mode
  of 1: p[i - 1]
  of 2: p[i - w]
  of 3: p[i - w + 1]
  of 4: p[i - w - 1]
  of 5: avg2(avg2(p[i - 1], p[i - w + 1]), p[i - w])
  of 6: avg2(p[i - 1], p[i - w - 1])
  of 7: avg2(p[i - 1], p[i - w])
  of 8: avg2(p[i - w - 1], p[i - w])
  of 9: avg2(p[i - w], p[i - w + 1])
  of 10: avg2(avg2(p[i - 1], p[i - w - 1]), avg2(p[i - w], p[i - w + 1]))
  of 11: selectPred(p[i - w], p[i - 1], p[i - w - 1])
  of 12: clampAddSubFull(p[i - 1], p[i - w], p[i - w - 1])
  of 13: clampAddSubHalf(p[i - 1], p[i - w], p[i - w - 1])
  else: 0xFF000000'u32

proc unpredict(px: var seq[uint32]; w, h, bits: int; modes: seq[uint32]) =
  let p = cast[ptr UncheckedArray[uint32]](addr px[0])
  p[0] = addPixels(p[0], 0xFF000000'u32)
  for x in 1 ..< w: p[x] = addPixels(p[x], p[x - 1])
  let tiles = subSize(w, bits)
  let tw = 1 shl bits
  for y in 1 ..< h:
    let row = y * w
    p[row] = addPixels(p[row], p[row - w])
    let mrow = (y shr bits) * tiles
    var x = 1
    while x < w:
      let mode = int((modes[mrow + (x shr bits)] shr 8) and 15)
      let xe = min(w, (x and not (tw - 1)) + tw)
      case mode
      of 1:
        for i in row + x ..< row + xe: p[i] = addPixels(p[i], p[i - 1])
      of 2:
        for i in row + x ..< row + xe: p[i] = addPixels(p[i], p[i - w])
      of 0, 14, 15:
        for i in row + x ..< row + xe: p[i] = addPixels(p[i], 0xFF000000'u32)
      else:
        for i in row + x ..< row + xe: p[i] = addPixels(p[i], predict(mode, p, i, w))
      x = xe

proc uncross(px: var seq[uint32]; w, h, bits: int; data: seq[uint32]) =
  let tiles = subSize(w, bits)
  for y in 0 ..< h:
    let mrow = (y shr bits) * tiles
    for x in 0 ..< w:
      let m = data[mrow + (x shr bits)]
      let g2r = int(cast[int8](m and 255))
      let g2b = int(cast[int8]((m shr 8) and 255))
      let r2b = int(cast[int8]((m shr 16) and 255))
      let i = y * w + x
      let argb = px[i]
      let g = int(cast[int8]((argb shr 8) and 255))
      var r = int((argb shr 16) and 255)
      var b = int(argb and 255)
      r = (r + ((g2r * g) shr 5)) and 255
      b = (b + ((g2b * g) shr 5)) and 255
      b = (b + ((r2b * int(cast[int8](r))) shr 5)) and 255
      px[i] = (argb and 0xFF00FF00'u32) or (uint32(r) shl 16) or uint32(b)

type
  LTransform = object
    kind, bits, xsize: int
    data: seq[uint32]

proc decodeLImage(r: var LBits; xsize, ysize: int; level0: bool): seq[uint32] =
  ## One entropy-coded image of the VP8L stream (with its transforms undone
  ## when it is the picture itself, `level0`).
  var w = xsize
  var transforms: seq[LTransform]
  if level0:
    var seen = 0
    while r.bits(1) == 1:
      let kind = r.bits(2)
      if (seen and (1 shl kind)) != 0: fail("damaged lossless WebP (transform twice)")
      seen = seen or (1 shl kind)
      var t = LTransform(kind: kind, xsize: w)
      case kind
      of 0, 1:
        t.bits = r.bits(3) + 2
        t.data = decodeLImage(r, subSize(w, t.bits), subSize(ysize, t.bits), false)
      of 3:
        let n = r.bits(8) + 1
        t.bits = if n > 16: 0 elif n > 4: 1 elif n > 2: 2 else: 3
        let pal = decodeLImage(r, n, 1, false)
        t.data = newSeq[uint32](1 shl (8 shr t.bits))
        t.data[0] = pal[0]
        for i in 1 ..< n: t.data[i] = addPixels(pal[i], t.data[i - 1])
        w = subSize(w, t.bits)
      else: discard
      transforms.add t
  var cacheBits = 0
  if r.bits(1) == 1:
    cacheBits = r.bits(4)
    if cacheBits < 1 or cacheBits > 11: fail("damaged lossless WebP (color cache)")
  # the prefix codes: one group, or a group for each tile of a meta image
  var metaBits = 0
  var meta: seq[uint32]
  var groups = 1
  if level0 and r.bits(1) == 1:
    metaBits = r.bits(3) + 2
    meta = decodeLImage(r, subSize(w, metaBits), subSize(ysize, metaBits), false)
    for m in meta.mitems:
      m = (m shr 8) and 0xFFFF
      groups = max(groups, int(m) + 1)
  if r.overrun: fail("damaged lossless WebP (truncated)")
  var used = newSeq[bool](groups)
  if meta.len == 0: used[0] = true
  for m in meta: used[m] = true
  var tables: seq[uint32]
  var at = newSeq[array[5, int]](groups)
  let cacheSize = if cacheBits > 0: 1 shl cacheBits else: 0
  for g in 0 ..< groups:
    for j in 0 .. 4:
      let alphabet = [256 + 24 + cacheSize, 256, 256, 256, 40][j]
      at[g][j] = readCode(r, alphabet, tables, used[g])
  let tp = cast[ptr UncheckedArray[uint32]](addr tables[0])
  # the pixels
  let h = ysize
  let total = w * h
  result = newSeq[uint32](total)
  let px = cast[ptr UncheckedArray[uint32]](addr result[0])
  var cache = newSeq[uint32](max(1, cacheSize))
  let cacheShift = 32 - cacheBits
  let mask = if metaBits == 0: -1 else: (1 shl metaBits) - 1
  let mw = subSize(w, metaBits)
  var x, y, i = 0
  var g = 0
  var green, red, blue, alpha, dist: ptr UncheckedArray[uint32]
  template setGroup() =
    g = if metaBits == 0: 0 else: int(meta[(y shr metaBits) * mw + (x shr metaBits)])
    green = cast[ptr UncheckedArray[uint32]](addr tp[at[g][0]])
    red = cast[ptr UncheckedArray[uint32]](addr tp[at[g][1]])
    blue = cast[ptr UncheckedArray[uint32]](addr tp[at[g][2]])
    alpha = cast[ptr UncheckedArray[uint32]](addr tp[at[g][3]])
    dist = cast[ptr UncheckedArray[uint32]](addr tp[at[g][4]])
  setGroup()
  while i < total:
    if (x and mask) == 0: setGroup()
    let code = readSym(r, green)
    if code < 256:
      let rr = readSym(r, red)
      let bb = readSym(r, blue)
      let aa = readSym(r, alpha)
      let c = (uint32(aa) shl 24) or (uint32(rr) shl 16) or (uint32(code) shl 8) or uint32(bb)
      px[i] = c
      if cacheBits > 0: cache[int((c * 0x1E35A7BD'u32) shr cacheShift)] = c
      inc i
      inc x
      if x >= w:
        x = 0
        inc y
        if r.overrun: fail("damaged lossless WebP (truncated)")
    elif code < 280:
      let length = prefixValue(r, code - 256)
      let d = planeDistance(w, prefixValue(r, readSym(r, dist)))
      if d > i or length > total - i: fail("damaged lossless WebP (distance)")
      for k in i ..< i + length:
        let c = px[k - d]
        px[k] = c
        if cacheBits > 0: cache[int((c * 0x1E35A7BD'u32) shr cacheShift)] = c
      i += length
      x += length
      while x >= w:
        x -= w
        inc y
      if (x and mask) != 0 and i < total: setGroup()
      if r.overrun: fail("damaged lossless WebP (truncated)")
    elif code - 280 < cacheSize:
      px[i] = cache[code - 280]
      inc i
      inc x
      if x >= w:
        x = 0
        inc y
    else:
      fail("damaged lossless WebP (symbol)")
  if r.overrun: fail("damaged lossless WebP (truncated)")
  # the transforms undone, the last first
  for k in countdown(transforms.high, 0):
    let t = transforms[k]
    case t.kind
    of 0: unpredict(result, t.xsize, h, t.bits, t.data)
    of 1: uncross(result, t.xsize, h, t.bits, t.data)
    of 2:
      for p in result.mitems:
        let g = (p shr 8) and 255
        p = (p and 0xFF00FF00'u32) or (((p and 0x00FF00FF'u32) + ((g shl 16) or g)) and 0x00FF00FF'u32)
    else:
      let tw = t.xsize
      if t.bits == 0:
        for p in result.mitems: p = t.data[(p shr 8) and 255]
      else:
        let pw = subSize(tw, t.bits)          # the packed width
        let per = 1 shl t.bits
        let bitsPer = 8 shr t.bits
        let m = (1'u32 shl bitsPer) - 1
        var full = newSeq[uint32](tw * h)
        for yy in 0 ..< h:
          for xx in 0 ..< tw:
            let packed = (result[yy * pw + (xx shr t.bits)] shr 8) and 255
            let idx = (packed shr uint32((xx and (per - 1)) * bitsPer)) and m
            full[yy * tw + xx] = t.data[idx]
        result = move full
    w = t.xsize

proc decodeVp8l(data: string; a, b: int; alphaUsed: var bool): tuple[w, h: int; px: seq[uint32]] =
  ## The picture of a VP8L chunk's payload `data[a ..< b]`.
  if b - a < 5 or u8(data, a) != 0x2F: fail("not a lossless WebP stream")
  var r = lbits(data, a, b)
  discard r.bits(8)
  result.w = r.bits(14) + 1
  result.h = r.bits(14) + 1
  alphaUsed = r.bits(1) == 1
  if r.bits(3) != 0: fail("unknown lossless WebP version")
  result.px = decodeLImage(r, result.w, result.h, true)

# ---- VP8: the lossy bitstream, read ----------------------------------------------------------

# The tables of VP8 (RFC 6386): the default token probabilities, the chance
# each is updated, the 4x4 mode probabilities by the modes above and left, and
# the quantizer steps.
const coeffsProba0: array[1056, uint8] = [
  128, 128, 128, 128, 128, 128, 128, 128, 128, 128, 128,
  128, 128, 128, 128, 128, 128, 128, 128, 128, 128, 128,
  128, 128, 128, 128, 128, 128, 128, 128, 128, 128, 128,
  253, 136, 254, 255, 228, 219, 128, 128, 128, 128, 128,
  189, 129, 242, 255, 227, 213, 255, 219, 128, 128, 128,
  106, 126, 227, 252, 214, 209, 255, 255, 128, 128, 128,
  1, 98, 248, 255, 236, 226, 255, 255, 128, 128, 128,
  181, 133, 238, 254, 221, 234, 255, 154, 128, 128, 128,
  78, 134, 202, 247, 198, 180, 255, 219, 128, 128, 128,
  1, 185, 249, 255, 243, 255, 128, 128, 128, 128, 128,
  184, 150, 247, 255, 236, 224, 128, 128, 128, 128, 128,
  77, 110, 216, 255, 236, 230, 128, 128, 128, 128, 128,
  1, 101, 251, 255, 241, 255, 128, 128, 128, 128, 128,
  170, 139, 241, 252, 236, 209, 255, 255, 128, 128, 128,
  37, 116, 196, 243, 228, 255, 255, 255, 128, 128, 128,
  1, 204, 254, 255, 245, 255, 128, 128, 128, 128, 128,
  207, 160, 250, 255, 238, 128, 128, 128, 128, 128, 128,
  102, 103, 231, 255, 211, 171, 128, 128, 128, 128, 128,
  1, 152, 252, 255, 240, 255, 128, 128, 128, 128, 128,
  177, 135, 243, 255, 234, 225, 128, 128, 128, 128, 128,
  80, 129, 211, 255, 194, 224, 128, 128, 128, 128, 128,
  1, 1, 255, 128, 128, 128, 128, 128, 128, 128, 128,
  246, 1, 255, 128, 128, 128, 128, 128, 128, 128, 128,
  255, 128, 128, 128, 128, 128, 128, 128, 128, 128, 128,
  198, 35, 237, 223, 193, 187, 162, 160, 145, 155, 62,
  131, 45, 198, 221, 172, 176, 220, 157, 252, 221, 1,
  68, 47, 146, 208, 149, 167, 221, 162, 255, 223, 128,
  1, 149, 241, 255, 221, 224, 255, 255, 128, 128, 128,
  184, 141, 234, 253, 222, 220, 255, 199, 128, 128, 128,
  81, 99, 181, 242, 176, 190, 249, 202, 255, 255, 128,
  1, 129, 232, 253, 214, 197, 242, 196, 255, 255, 128,
  99, 121, 210, 250, 201, 198, 255, 202, 128, 128, 128,
  23, 91, 163, 242, 170, 187, 247, 210, 255, 255, 128,
  1, 200, 246, 255, 234, 255, 128, 128, 128, 128, 128,
  109, 178, 241, 255, 231, 245, 255, 255, 128, 128, 128,
  44, 130, 201, 253, 205, 192, 255, 255, 128, 128, 128,
  1, 132, 239, 251, 219, 209, 255, 165, 128, 128, 128,
  94, 136, 225, 251, 218, 190, 255, 255, 128, 128, 128,
  22, 100, 174, 245, 186, 161, 255, 199, 128, 128, 128,
  1, 182, 249, 255, 232, 235, 128, 128, 128, 128, 128,
  124, 143, 241, 255, 227, 234, 128, 128, 128, 128, 128,
  35, 77, 181, 251, 193, 211, 255, 205, 128, 128, 128,
  1, 157, 247, 255, 236, 231, 255, 255, 128, 128, 128,
  121, 141, 235, 255, 225, 227, 255, 255, 128, 128, 128,
  45, 99, 188, 251, 195, 217, 255, 224, 128, 128, 128,
  1, 1, 251, 255, 213, 255, 128, 128, 128, 128, 128,
  203, 1, 248, 255, 255, 128, 128, 128, 128, 128, 128,
  137, 1, 177, 255, 224, 255, 128, 128, 128, 128, 128,
  253, 9, 248, 251, 207, 208, 255, 192, 128, 128, 128,
  175, 13, 224, 243, 193, 185, 249, 198, 255, 255, 128,
  73, 17, 171, 221, 161, 179, 236, 167, 255, 234, 128,
  1, 95, 247, 253, 212, 183, 255, 255, 128, 128, 128,
  239, 90, 244, 250, 211, 209, 255, 255, 128, 128, 128,
  155, 77, 195, 248, 188, 195, 255, 255, 128, 128, 128,
  1, 24, 239, 251, 218, 219, 255, 205, 128, 128, 128,
  201, 51, 219, 255, 196, 186, 128, 128, 128, 128, 128,
  69, 46, 190, 239, 201, 218, 255, 228, 128, 128, 128,
  1, 191, 251, 255, 255, 128, 128, 128, 128, 128, 128,
  223, 165, 249, 255, 213, 255, 128, 128, 128, 128, 128,
  141, 124, 248, 255, 255, 128, 128, 128, 128, 128, 128,
  1, 16, 248, 255, 255, 128, 128, 128, 128, 128, 128,
  190, 36, 230, 255, 236, 255, 128, 128, 128, 128, 128,
  149, 1, 255, 128, 128, 128, 128, 128, 128, 128, 128,
  1, 226, 255, 128, 128, 128, 128, 128, 128, 128, 128,
  247, 192, 255, 128, 128, 128, 128, 128, 128, 128, 128,
  240, 128, 255, 128, 128, 128, 128, 128, 128, 128, 128,
  1, 134, 252, 255, 255, 128, 128, 128, 128, 128, 128,
  213, 62, 250, 255, 255, 128, 128, 128, 128, 128, 128,
  55, 93, 255, 128, 128, 128, 128, 128, 128, 128, 128,
  128, 128, 128, 128, 128, 128, 128, 128, 128, 128, 128,
  128, 128, 128, 128, 128, 128, 128, 128, 128, 128, 128,
  128, 128, 128, 128, 128, 128, 128, 128, 128, 128, 128,
  202, 24, 213, 235, 186, 191, 220, 160, 240, 175, 255,
  126, 38, 182, 232, 169, 184, 228, 174, 255, 187, 128,
  61, 46, 138, 219, 151, 178, 240, 170, 255, 216, 128,
  1, 112, 230, 250, 199, 191, 247, 159, 255, 255, 128,
  166, 109, 228, 252, 211, 215, 255, 174, 128, 128, 128,
  39, 77, 162, 232, 172, 180, 245, 178, 255, 255, 128,
  1, 52, 220, 246, 198, 199, 249, 220, 255, 255, 128,
  124, 74, 191, 243, 183, 193, 250, 221, 255, 255, 128,
  24, 71, 130, 219, 154, 170, 243, 182, 255, 255, 128,
  1, 182, 225, 249, 219, 240, 255, 224, 128, 128, 128,
  149, 150, 226, 252, 216, 205, 255, 171, 128, 128, 128,
  28, 108, 170, 242, 183, 194, 254, 223, 255, 255, 128,
  1, 81, 230, 252, 204, 203, 255, 192, 128, 128, 128,
  123, 102, 209, 247, 188, 196, 255, 233, 128, 128, 128,
  20, 95, 153, 243, 164, 173, 255, 203, 128, 128, 128,
  1, 222, 248, 255, 216, 213, 128, 128, 128, 128, 128,
  168, 175, 246, 252, 235, 205, 255, 255, 128, 128, 128,
  47, 116, 215, 255, 211, 212, 255, 255, 128, 128, 128,
  1, 121, 236, 253, 212, 214, 255, 255, 128, 128, 128,
  141, 84, 213, 252, 201, 202, 255, 219, 128, 128, 128,
  42, 80, 160, 240, 162, 185, 255, 205, 128, 128, 128,
  1, 1, 255, 128, 128, 128, 128, 128, 128, 128, 128,
  244, 1, 255, 128, 128, 128, 128, 128, 128, 128, 128,
  238, 1, 255, 128, 128, 128, 128, 128, 128, 128, 128
]
const coeffsUpdateProba: array[1056, uint8] = [
  255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255,
  255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255,
  255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255,
  176, 246, 255, 255, 255, 255, 255, 255, 255, 255, 255,
  223, 241, 252, 255, 255, 255, 255, 255, 255, 255, 255,
  249, 253, 253, 255, 255, 255, 255, 255, 255, 255, 255,
  255, 244, 252, 255, 255, 255, 255, 255, 255, 255, 255,
  234, 254, 254, 255, 255, 255, 255, 255, 255, 255, 255,
  253, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255,
  255, 246, 254, 255, 255, 255, 255, 255, 255, 255, 255,
  239, 253, 254, 255, 255, 255, 255, 255, 255, 255, 255,
  254, 255, 254, 255, 255, 255, 255, 255, 255, 255, 255,
  255, 248, 254, 255, 255, 255, 255, 255, 255, 255, 255,
  251, 255, 254, 255, 255, 255, 255, 255, 255, 255, 255,
  255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255,
  255, 253, 254, 255, 255, 255, 255, 255, 255, 255, 255,
  251, 254, 254, 255, 255, 255, 255, 255, 255, 255, 255,
  254, 255, 254, 255, 255, 255, 255, 255, 255, 255, 255,
  255, 254, 253, 255, 254, 255, 255, 255, 255, 255, 255,
  250, 255, 254, 255, 254, 255, 255, 255, 255, 255, 255,
  254, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255,
  255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255,
  255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255,
  255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255,
  217, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255,
  225, 252, 241, 253, 255, 255, 254, 255, 255, 255, 255,
  234, 250, 241, 250, 253, 255, 253, 254, 255, 255, 255,
  255, 254, 255, 255, 255, 255, 255, 255, 255, 255, 255,
  223, 254, 254, 255, 255, 255, 255, 255, 255, 255, 255,
  238, 253, 254, 254, 255, 255, 255, 255, 255, 255, 255,
  255, 248, 254, 255, 255, 255, 255, 255, 255, 255, 255,
  249, 254, 255, 255, 255, 255, 255, 255, 255, 255, 255,
  255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255,
  255, 253, 255, 255, 255, 255, 255, 255, 255, 255, 255,
  247, 254, 255, 255, 255, 255, 255, 255, 255, 255, 255,
  255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255,
  255, 253, 254, 255, 255, 255, 255, 255, 255, 255, 255,
  252, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255,
  255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255,
  255, 254, 254, 255, 255, 255, 255, 255, 255, 255, 255,
  253, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255,
  255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255,
  255, 254, 253, 255, 255, 255, 255, 255, 255, 255, 255,
  250, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255,
  254, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255,
  255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255,
  255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255,
  255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255,
  186, 251, 250, 255, 255, 255, 255, 255, 255, 255, 255,
  234, 251, 244, 254, 255, 255, 255, 255, 255, 255, 255,
  251, 251, 243, 253, 254, 255, 254, 255, 255, 255, 255,
  255, 253, 254, 255, 255, 255, 255, 255, 255, 255, 255,
  236, 253, 254, 255, 255, 255, 255, 255, 255, 255, 255,
  251, 253, 253, 254, 254, 255, 255, 255, 255, 255, 255,
  255, 254, 254, 255, 255, 255, 255, 255, 255, 255, 255,
  254, 254, 254, 255, 255, 255, 255, 255, 255, 255, 255,
  255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255,
  255, 254, 255, 255, 255, 255, 255, 255, 255, 255, 255,
  254, 254, 255, 255, 255, 255, 255, 255, 255, 255, 255,
  254, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255,
  255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255,
  254, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255,
  255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255,
  255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255,
  255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255,
  255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255,
  255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255,
  255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255,
  255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255,
  255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255,
  255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255,
  255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255,
  248, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255,
  250, 254, 252, 254, 255, 255, 255, 255, 255, 255, 255,
  248, 254, 249, 253, 255, 255, 255, 255, 255, 255, 255,
  255, 253, 253, 255, 255, 255, 255, 255, 255, 255, 255,
  246, 253, 253, 255, 255, 255, 255, 255, 255, 255, 255,
  252, 254, 251, 254, 254, 255, 255, 255, 255, 255, 255,
  255, 254, 252, 255, 255, 255, 255, 255, 255, 255, 255,
  248, 254, 253, 255, 255, 255, 255, 255, 255, 255, 255,
  253, 255, 254, 254, 255, 255, 255, 255, 255, 255, 255,
  255, 251, 254, 255, 255, 255, 255, 255, 255, 255, 255,
  245, 251, 254, 255, 255, 255, 255, 255, 255, 255, 255,
  253, 253, 254, 255, 255, 255, 255, 255, 255, 255, 255,
  255, 251, 253, 255, 255, 255, 255, 255, 255, 255, 255,
  252, 253, 254, 255, 255, 255, 255, 255, 255, 255, 255,
  255, 254, 255, 255, 255, 255, 255, 255, 255, 255, 255,
  255, 252, 255, 255, 255, 255, 255, 255, 255, 255, 255,
  249, 255, 254, 255, 255, 255, 255, 255, 255, 255, 255,
  255, 255, 254, 255, 255, 255, 255, 255, 255, 255, 255,
  255, 255, 253, 255, 255, 255, 255, 255, 255, 255, 255,
  250, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255,
  255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255,
  255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255,
  254, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255,
  255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255
]
const bModesProba: array[900, uint8] = [
  231, 120, 48, 89, 115, 113, 120, 152, 112,
  152, 179, 64, 126, 170, 118, 46, 70, 95,
  175, 69, 143, 80, 85, 82, 72, 155, 103,
  56, 58, 10, 171, 218, 189, 17, 13, 152,
  114, 26, 17, 163, 44, 195, 21, 10, 173,
  121, 24, 80, 195, 26, 62, 44, 64, 85,
  144, 71, 10, 38, 171, 213, 144, 34, 26,
  170, 46, 55, 19, 136, 160, 33, 206, 71,
  63, 20, 8, 114, 114, 208, 12, 9, 226,
  81, 40, 11, 96, 182, 84, 29, 16, 36,
  134, 183, 89, 137, 98, 101, 106, 165, 148,
  72, 187, 100, 130, 157, 111, 32, 75, 80,
  66, 102, 167, 99, 74, 62, 40, 234, 128,
  41, 53, 9, 178, 241, 141, 26, 8, 107,
  74, 43, 26, 146, 73, 166, 49, 23, 157,
  65, 38, 105, 160, 51, 52, 31, 115, 128,
  104, 79, 12, 27, 217, 255, 87, 17, 7,
  87, 68, 71, 44, 114, 51, 15, 186, 23,
  47, 41, 14, 110, 182, 183, 21, 17, 194,
  66, 45, 25, 102, 197, 189, 23, 18, 22,
  88, 88, 147, 150, 42, 46, 45, 196, 205,
  43, 97, 183, 117, 85, 38, 35, 179, 61,
  39, 53, 200, 87, 26, 21, 43, 232, 171,
  56, 34, 51, 104, 114, 102, 29, 93, 77,
  39, 28, 85, 171, 58, 165, 90, 98, 64,
  34, 22, 116, 206, 23, 34, 43, 166, 73,
  107, 54, 32, 26, 51, 1, 81, 43, 31,
  68, 25, 106, 22, 64, 171, 36, 225, 114,
  34, 19, 21, 102, 132, 188, 16, 76, 124,
  62, 18, 78, 95, 85, 57, 50, 48, 51,
  193, 101, 35, 159, 215, 111, 89, 46, 111,
  60, 148, 31, 172, 219, 228, 21, 18, 111,
  112, 113, 77, 85, 179, 255, 38, 120, 114,
  40, 42, 1, 196, 245, 209, 10, 25, 109,
  88, 43, 29, 140, 166, 213, 37, 43, 154,
  61, 63, 30, 155, 67, 45, 68, 1, 209,
  100, 80, 8, 43, 154, 1, 51, 26, 71,
  142, 78, 78, 16, 255, 128, 34, 197, 171,
  41, 40, 5, 102, 211, 183, 4, 1, 221,
  51, 50, 17, 168, 209, 192, 23, 25, 82,
  138, 31, 36, 171, 27, 166, 38, 44, 229,
  67, 87, 58, 169, 82, 115, 26, 59, 179,
  63, 59, 90, 180, 59, 166, 93, 73, 154,
  40, 40, 21, 116, 143, 209, 34, 39, 175,
  47, 15, 16, 183, 34, 223, 49, 45, 183,
  46, 17, 33, 183, 6, 98, 15, 32, 183,
  57, 46, 22, 24, 128, 1, 54, 17, 37,
  65, 32, 73, 115, 28, 128, 23, 128, 205,
  40, 3, 9, 115, 51, 192, 18, 6, 223,
  87, 37, 9, 115, 59, 77, 64, 21, 47,
  104, 55, 44, 218, 9, 54, 53, 130, 226,
  64, 90, 70, 205, 40, 41, 23, 26, 57,
  54, 57, 112, 184, 5, 41, 38, 166, 213,
  30, 34, 26, 133, 152, 116, 10, 32, 134,
  39, 19, 53, 221, 26, 114, 32, 73, 255,
  31, 9, 65, 234, 2, 15, 1, 118, 73,
  75, 32, 12, 51, 192, 255, 160, 43, 51,
  88, 31, 35, 67, 102, 85, 55, 186, 85,
  56, 21, 23, 111, 59, 205, 45, 37, 192,
  55, 38, 70, 124, 73, 102, 1, 34, 98,
  125, 98, 42, 88, 104, 85, 117, 175, 82,
  95, 84, 53, 89, 128, 100, 113, 101, 45,
  75, 79, 123, 47, 51, 128, 81, 171, 1,
  57, 17, 5, 71, 102, 57, 53, 41, 49,
  38, 33, 13, 121, 57, 73, 26, 1, 85,
  41, 10, 67, 138, 77, 110, 90, 47, 114,
  115, 21, 2, 10, 102, 255, 166, 23, 6,
  101, 29, 16, 10, 85, 128, 101, 196, 26,
  57, 18, 10, 102, 102, 213, 34, 20, 43,
  117, 20, 15, 36, 163, 128, 68, 1, 26,
  102, 61, 71, 37, 34, 53, 31, 243, 192,
  69, 60, 71, 38, 73, 119, 28, 222, 37,
  68, 45, 128, 34, 1, 47, 11, 245, 171,
  62, 17, 19, 70, 146, 85, 55, 62, 70,
  37, 43, 37, 154, 100, 163, 85, 160, 1,
  63, 9, 92, 136, 28, 64, 32, 201, 85,
  75, 15, 9, 9, 64, 255, 184, 119, 16,
  86, 6, 28, 5, 64, 255, 25, 248, 1,
  56, 8, 17, 132, 137, 255, 55, 116, 128,
  58, 15, 20, 82, 135, 57, 26, 121, 40,
  164, 50, 31, 137, 154, 133, 25, 35, 218,
  51, 103, 44, 131, 131, 123, 31, 6, 158,
  86, 40, 64, 135, 148, 224, 45, 183, 128,
  22, 26, 17, 131, 240, 154, 14, 1, 209,
  45, 16, 21, 91, 64, 222, 7, 1, 197,
  56, 21, 39, 155, 60, 138, 23, 102, 213,
  83, 12, 13, 54, 192, 255, 68, 47, 28,
  85, 26, 85, 85, 128, 128, 32, 146, 171,
  18, 11, 7, 63, 144, 171, 4, 4, 246,
  35, 27, 10, 146, 174, 171, 12, 26, 128,
  190, 80, 35, 99, 180, 80, 126, 54, 45,
  85, 126, 47, 87, 176, 51, 41, 20, 32,
  101, 75, 128, 139, 118, 146, 116, 128, 85,
  56, 41, 15, 176, 236, 85, 37, 9, 62,
  71, 30, 17, 119, 118, 255, 17, 18, 138,
  101, 38, 60, 138, 55, 70, 43, 26, 142,
  146, 36, 19, 30, 171, 255, 97, 27, 20,
  138, 45, 61, 62, 219, 1, 81, 188, 64,
  32, 41, 20, 117, 151, 142, 20, 21, 163,
  112, 19, 12, 61, 195, 128, 48, 4, 24
]
const dcTable: array[128, int32] = [
  4, 5, 6, 7, 8, 9, 10, 10, 11, 12, 13, 14, 15, 16, 17, 17,
  18, 19, 20, 20, 21, 21, 22, 22, 23, 23, 24, 25, 25, 26, 27, 28,
  29, 30, 31, 32, 33, 34, 35, 36, 37, 37, 38, 39, 40, 41, 42, 43,
  44, 45, 46, 46, 47, 48, 49, 50, 51, 52, 53, 54, 55, 56, 57, 58,
  59, 60, 61, 62, 63, 64, 65, 66, 67, 68, 69, 70, 71, 72, 73, 74,
  75, 76, 76, 77, 78, 79, 80, 81, 82, 83, 84, 85, 86, 87, 88, 89,
  91, 93, 95, 96, 98, 100, 101, 102, 104, 106, 108, 110, 112, 114, 116, 118,
  122, 124, 126, 128, 130, 132, 134, 136, 138, 140, 143, 145, 148, 151, 154, 157
]
const acTable: array[128, int32] = [
  4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19,
  20, 21, 22, 23, 24, 25, 26, 27, 28, 29, 30, 31, 32, 33, 34, 35,
  36, 37, 38, 39, 40, 41, 42, 43, 44, 45, 46, 47, 48, 49, 50, 51,
  52, 53, 54, 55, 56, 57, 58, 60, 62, 64, 66, 68, 70, 72, 74, 76,
  78, 80, 82, 84, 86, 88, 90, 92, 94, 96, 98, 100, 102, 104, 106, 108,
  110, 112, 114, 116, 119, 122, 125, 128, 131, 134, 137, 140, 143, 146, 149, 152,
  155, 158, 161, 164, 167, 170, 173, 177, 181, 185, 189, 193, 197, 201, 205, 209,
  213, 217, 221, 225, 229, 234, 239, 245, 249, 254, 259, 264, 269, 274, 279, 284
]


type
  BoolDec = object
    ## The boolean (arithmetic) decoder of VP8, as libwebp's.
    buf: ptr UncheckedArray[byte]
    pos, stop: int
    value: uint64
    range: uint32        # the range minus 1
    bits: int
    eof: bool

proc loadFinal(d: var BoolDec) =
  if d.pos < d.stop:
    d.bits += 8
    d.value = uint64(d.buf[d.pos]) or (d.value shl 8)
    inc d.pos
  elif not d.eof:
    d.value = d.value shl 8
    d.bits += 8
    d.eof = true
  else:
    d.bits = 0

proc loadNew(d: var BoolDec) {.inline.} =
  if d.pos + 8 <= d.stop:
    var v = 0'u64
    for k in 0 .. 6: v = (v shl 8) or uint64(d.buf[d.pos + k])
    d.pos += 7
    d.value = v or (d.value shl 56)
    d.bits += 56
  else:
    d.loadFinal()

proc initBool(d: var BoolDec; buf: ptr UncheckedArray[byte]; a, b: int) =
  d = BoolDec(buf: buf, pos: a, stop: b, range: 254, bits: -8)
  d.loadNew()

proc getBit(d: var BoolDec; prob: int): int {.inline.} =
  var range = d.range
  if d.bits < 0: d.loadNew()
  let pos = d.bits
  let split = (range * uint32(prob)) shr 8
  let value = uint32(d.value shr pos)
  if value > split:
    range -= split
    d.value -= uint64(split + 1) shl pos
    result = 1
  else:
    range = split + 1
  let shift = 7 xor fastLog2(range)
  range = range shl shift
  d.bits -= shift
  d.range = range - 1

proc getValue(d: var BoolDec; n: int): int =
  for k in countdown(n - 1, 0): result = result or (d.getBit(0x80) shl k)

proc getSignedValue(d: var BoolDec; n: int): int =
  let v = d.getValue(n)
  if d.getBit(0x80) == 1: -v else: v

const
  Bps = 32                                   # the stride of the work block
  YOff = Bps + 8
  UOff = YOff + Bps * 16 + Bps
  VOff = UOff + 16
  Zigzag = [0, 1, 4, 8, 5, 2, 3, 6, 9, 12, 13, 10, 7, 11, 14, 15]
  Bands = [0, 1, 2, 3, 6, 4, 5, 6, 6, 6, 6, 6, 6, 6, 6, 7, 0]
  Cat3 = [173, 148, 140]
  Cat4 = [176, 155, 140, 135]
  Cat5 = [180, 157, 141, 134, 130]
  Cat6 = [254, 254, 243, 230, 196, 177, 153, 140, 133, 130, 129]
  Scan = [0 + 0 * Bps, 4 + 0 * Bps, 8 + 0 * Bps, 12 + 0 * Bps,
          0 + 4 * Bps, 4 + 4 * Bps, 8 + 4 * Bps, 12 + 4 * Bps,
          0 + 8 * Bps, 4 + 8 * Bps, 8 + 8 * Bps, 12 + 8 * Bps,
          0 + 12 * Bps, 4 + 12 * Bps, 8 + 12 * Bps, 12 + 12 * Bps]

type
  Work = ptr UncheckedArray[uint8]
  Coeffs = ptr UncheckedArray[int16]

proc clip8b(v: int): uint8 {.inline.} = uint8(if v < 0: 0 elif v > 255: 255 else: v)

# -- prediction (on the work block, `d` the top-left of the block) --

proc avg3(a, b, c: int): uint8 {.inline.} = uint8((a + 2 * b + c + 2) shr 2)
proc avg2b(a, b: int): uint8 {.inline.} = uint8((a + b + 1) shr 1)

proc trueMotion(p: Work; d, size: int) =
  let tl = int(p[d - Bps - 1])
  for y in 0 ..< size:
    let l = int(p[d + y * Bps - 1]) - tl
    for x in 0 ..< size:
      p[d + y * Bps + x] = clip8b(int(p[d - Bps + x]) + l)

proc fillBlock(p: Work; d, size, v: int) =
  for y in 0 ..< size:
    for x in 0 ..< size: p[d + y * Bps + x] = uint8(v)

proc predLuma16(p: Work; d, mode: int) =
  case mode
  of 0:                                       # DC, both sides
    var dc = 16
    for j in 0 ..< 16: dc += int(p[d - 1 + j * Bps]) + int(p[d + j - Bps])
    fillBlock(p, d, 16, dc shr 5)
  of 1: trueMotion(p, d, 16)
  of 2:
    for y in 0 ..< 16:
      for x in 0 ..< 16: p[d + y * Bps + x] = p[d - Bps + x]
  of 3:
    for y in 0 ..< 16:
      let v = p[d + y * Bps - 1]
      for x in 0 ..< 16: p[d + y * Bps + x] = v
  of 4:                                       # DC without the top
    var dc = 8
    for j in 0 ..< 16: dc += int(p[d - 1 + j * Bps])
    fillBlock(p, d, 16, dc shr 4)
  of 5:                                       # DC without the left
    var dc = 8
    for j in 0 ..< 16: dc += int(p[d + j - Bps])
    fillBlock(p, d, 16, dc shr 4)
  else: fillBlock(p, d, 16, 0x80)

proc predChroma8(p: Work; d, mode: int) =
  case mode
  of 0:
    var dc = 8
    for j in 0 ..< 8: dc += int(p[d + j - Bps]) + int(p[d - 1 + j * Bps])
    fillBlock(p, d, 8, dc shr 4)
  of 1: trueMotion(p, d, 8)
  of 2:
    for y in 0 ..< 8:
      for x in 0 ..< 8: p[d + y * Bps + x] = p[d - Bps + x]
  of 3:
    for y in 0 ..< 8:
      let v = p[d + y * Bps - 1]
      for x in 0 ..< 8: p[d + y * Bps + x] = v
  of 4:
    var dc = 4
    for j in 0 ..< 8: dc += int(p[d - 1 + j * Bps])
    fillBlock(p, d, 8, dc shr 3)
  of 5:
    var dc = 4
    for j in 0 ..< 8: dc += int(p[d + j - Bps])
    fillBlock(p, d, 8, dc shr 3)
  else: fillBlock(p, d, 8, 0x80)

proc predLuma4(p: Work; d, mode: int) =
  template P(x, y: int): int = int(p[d + x + y * Bps])
  template S(x, y: int; v: uint8) = p[d + x + y * Bps] = v
  case mode
  of 0:                                       # DC
    var dc = 4
    for i in 0 .. 3: dc += P(i, -1) + P(-1, i)
    fillBlock(p, d, 4, dc shr 3)
  of 1: trueMotion(p, d, 4)
  of 2:                                       # vertical, smoothed
    for i in 0 .. 3:
      let v = avg3(P(i - 1, -1), P(i, -1), P(i + 1, -1))
      for y in 0 .. 3: S(i, y, v)
  of 3:                                       # horizontal, smoothed
    let A = P(-1, -1)
    let B = P(-1, 0)
    let C = P(-1, 1)
    let D = P(-1, 2)
    let E = P(-1, 3)
    let r = [avg3(A, B, C), avg3(B, C, D), avg3(C, D, E), avg3(D, E, E)]
    for y in 0 .. 3:
      for x in 0 .. 3: S(x, y, r[y])
  of 4:                                       # down-right
    let I = P(-1, 0)
    let J = P(-1, 1)
    let K = P(-1, 2)
    let L = P(-1, 3)
    let X = P(-1, -1)
    let A = P(0, -1)
    let B = P(1, -1)
    let C = P(2, -1)
    let D = P(3, -1)
    S(0, 3, avg3(J, K, L))
    let v1 = avg3(I, J, K)
    S(1, 3, v1); S(0, 2, v1)
    let v2 = avg3(X, I, J)
    S(2, 3, v2); S(1, 2, v2); S(0, 1, v2)
    let v3 = avg3(A, X, I)
    S(3, 3, v3); S(2, 2, v3); S(1, 1, v3); S(0, 0, v3)
    let v4 = avg3(B, A, X)
    S(3, 2, v4); S(2, 1, v4); S(1, 0, v4)
    let v5 = avg3(C, B, A)
    S(3, 1, v5); S(2, 0, v5)
    S(3, 0, avg3(D, C, B))
  of 5:                                       # vertical-right
    let I = P(-1, 0)
    let J = P(-1, 1)
    let K = P(-1, 2)
    let X = P(-1, -1)
    let A = P(0, -1)
    let B = P(1, -1)
    let C = P(2, -1)
    let D = P(3, -1)
    let a = avg2b(X, A)
    S(0, 0, a); S(1, 2, a)
    let b = avg2b(A, B)
    S(1, 0, b); S(2, 2, b)
    let c = avg2b(B, C)
    S(2, 0, c); S(3, 2, c)
    S(3, 0, avg2b(C, D))
    S(0, 3, avg3(K, J, I))
    S(0, 2, avg3(J, I, X))
    let e = avg3(I, X, A)
    S(0, 1, e); S(1, 3, e)
    let f = avg3(X, A, B)
    S(1, 1, f); S(2, 3, f)
    let g = avg3(A, B, C)
    S(2, 1, g); S(3, 3, g)
    S(3, 1, avg3(B, C, D))
  of 6:                                       # down-left
    let A = P(0, -1)
    let B = P(1, -1)
    let C = P(2, -1)
    let D = P(3, -1)
    let E = P(4, -1)
    let F = P(5, -1)
    let G = P(6, -1)
    let H = P(7, -1)
    S(0, 0, avg3(A, B, C))
    let a = avg3(B, C, D)
    S(1, 0, a); S(0, 1, a)
    let b = avg3(C, D, E)
    S(2, 0, b); S(1, 1, b); S(0, 2, b)
    let c = avg3(D, E, F)
    S(3, 0, c); S(2, 1, c); S(1, 2, c); S(0, 3, c)
    let e = avg3(E, F, G)
    S(3, 1, e); S(2, 2, e); S(1, 3, e)
    let f = avg3(F, G, H)
    S(3, 2, f); S(2, 3, f)
    S(3, 3, avg3(G, H, H))
  of 7:                                       # vertical-left
    let A = P(0, -1)
    let B = P(1, -1)
    let C = P(2, -1)
    let D = P(3, -1)
    let E = P(4, -1)
    let F = P(5, -1)
    let G = P(6, -1)
    let H = P(7, -1)
    S(0, 0, avg2b(A, B))
    let a = avg2b(B, C)
    S(1, 0, a); S(0, 2, a)
    let b = avg2b(C, D)
    S(2, 0, b); S(1, 2, b)
    let c = avg2b(D, E)
    S(3, 0, c); S(2, 2, c)
    S(0, 1, avg3(A, B, C))
    let e = avg3(B, C, D)
    S(1, 1, e); S(0, 3, e)
    let f = avg3(C, D, E)
    S(2, 1, f); S(1, 3, f)
    let g = avg3(D, E, F)
    S(3, 1, g); S(2, 3, g)
    S(3, 2, avg3(E, F, G))
    S(3, 3, avg3(F, G, H))
  of 8:                                       # horizontal-down
    let I = P(-1, 0)
    let J = P(-1, 1)
    let K = P(-1, 2)
    let L = P(-1, 3)
    let X = P(-1, -1)
    let A = P(0, -1)
    let B = P(1, -1)
    let C = P(2, -1)
    let a = avg2b(I, X)
    S(0, 0, a); S(2, 1, a)
    let b = avg2b(J, I)
    S(0, 1, b); S(2, 2, b)
    let c = avg2b(K, J)
    S(0, 2, c); S(2, 3, c)
    S(0, 3, avg2b(L, K))
    S(3, 0, avg3(A, B, C))
    S(2, 0, avg3(X, A, B))
    let e = avg3(I, X, A)
    S(1, 0, e); S(3, 1, e)
    let f = avg3(J, I, X)
    S(1, 1, f); S(3, 2, f)
    let g = avg3(K, J, I)
    S(1, 2, g); S(3, 3, g)
    S(1, 3, avg3(L, K, J))
  else:                                       # horizontal-up
    let I = P(-1, 0)
    let J = P(-1, 1)
    let K = P(-1, 2)
    let L = P(-1, 3)
    S(0, 0, avg2b(I, J))
    let a = avg2b(J, K)
    S(2, 0, a); S(0, 1, a)
    let b = avg2b(K, L)
    S(2, 1, b); S(0, 2, b)
    S(1, 0, avg3(I, J, K))
    let c = avg3(J, K, L)
    S(3, 0, c); S(1, 1, c)
    let e = avg3(K, L, L)
    S(3, 1, e); S(1, 2, e)
    let l = uint8(L)
    S(3, 2, l); S(2, 2, l); S(0, 3, l); S(1, 3, l); S(2, 3, l); S(3, 3, l)

# -- the inverse transforms, added to the prediction --

template mul1(a: int): int = ((a * 20091) shr 16) + a
template mul2(a: int): int = (a * 35468) shr 16

proc idctAdd(c: Coeffs; o: int; p: Work; d: int) =
  ## The inverse DCT of the 16 coefficients at `c[o]`, added to the 4x4 at `d`.
  var tmp: array[16, int]
  for i in 0 .. 3:
    let a = int(c[o + i]) + int(c[o + i + 8])
    let b = int(c[o + i]) - int(c[o + i + 8])
    let cc = mul2(int(c[o + i + 4])) - mul1(int(c[o + i + 12]))
    let dd = mul1(int(c[o + i + 4])) + mul2(int(c[o + i + 12]))
    tmp[i * 4 + 0] = a + dd
    tmp[i * 4 + 1] = b + cc
    tmp[i * 4 + 2] = b - cc
    tmp[i * 4 + 3] = a - dd
  for i in 0 .. 3:
    let dc = tmp[i] + 4
    let a = dc + tmp[i + 8]
    let b = dc - tmp[i + 8]
    let cc = mul2(tmp[i + 4]) - mul1(tmp[i + 12])
    let dd = mul1(tmp[i + 4]) + mul2(tmp[i + 12])
    let q = d + i * Bps
    p[q + 0] = clip8b(int(p[q + 0]) + ((a + dd) shr 3))
    p[q + 1] = clip8b(int(p[q + 1]) + ((b + cc) shr 3))
    p[q + 2] = clip8b(int(p[q + 2]) + ((b - cc) shr 3))
    p[q + 3] = clip8b(int(p[q + 3]) + ((a - dd) shr 3))

proc idctAc3Add(c: Coeffs; o: int; p: Work; d: int) =
  let a = int(c[o]) + 4
  let c4 = mul2(int(c[o + 4]))
  let d4 = mul1(int(c[o + 4]))
  let c1 = mul2(int(c[o + 1]))
  let d1 = mul1(int(c[o + 1]))
  let rows = [a + d4, a + c4, a - c4, a - d4]
  for y in 0 .. 3:
    let dc = rows[y]
    let q = d + y * Bps
    p[q + 0] = clip8b(int(p[q + 0]) + ((dc + d1) shr 3))
    p[q + 1] = clip8b(int(p[q + 1]) + ((dc + c1) shr 3))
    p[q + 2] = clip8b(int(p[q + 2]) + ((dc - c1) shr 3))
    p[q + 3] = clip8b(int(p[q + 3]) + ((dc - d1) shr 3))

proc idctDcAdd(c: Coeffs; o: int; p: Work; d: int) =
  let dc = (int(c[o]) + 4) shr 3
  for y in 0 .. 3:
    for x in 0 .. 3:
      let q = d + y * Bps + x
      p[q] = clip8b(int(p[q]) + dc)

proc doTransform(bits: uint32; c: Coeffs; o: int; p: Work; d: int) {.inline.} =
  case bits shr 30
  of 3: idctAdd(c, o, p, d)
  of 2: idctAc3Add(c, o, p, d)
  of 1: idctDcAdd(c, o, p, d)
  else: discard

proc doUVTransform(bits: uint32; c: Coeffs; o: int; p: Work; d: int) =
  if (bits and 0xFF) != 0:
    if (bits and 0xAA) != 0:
      idctAdd(c, o, p, d)
      idctAdd(c, o + 16, p, d + 4)
      idctAdd(c, o + 32, p, d + 4 * Bps)
      idctAdd(c, o + 48, p, d + 4 * Bps + 4)
    else:
      if c[o] != 0: idctDcAdd(c, o, p, d)
      if c[o + 16] != 0: idctDcAdd(c, o + 16, p, d + 4)
      if c[o + 32] != 0: idctDcAdd(c, o + 32, p, d + 4 * Bps)
      if c[o + 48] != 0: idctDcAdd(c, o + 48, p, d + 4 * Bps + 4)

proc wht(input: array[16, int16]; c: Coeffs) =
  ## The inverse Walsh-Hadamard transform: the DCs of the 16 luma blocks.
  var tmp: array[16, int]
  for i in 0 .. 3:
    let a0 = int(input[i]) + int(input[12 + i])
    let a1 = int(input[4 + i]) + int(input[8 + i])
    let a2 = int(input[4 + i]) - int(input[8 + i])
    let a3 = int(input[i]) - int(input[12 + i])
    tmp[i] = a0 + a1
    tmp[8 + i] = a0 - a1
    tmp[4 + i] = a3 + a2
    tmp[12 + i] = a3 - a2
  var o = 0
  for i in 0 .. 3:
    let dc = tmp[i * 4] + 3
    let a0 = dc + tmp[3 + i * 4]
    let a1 = tmp[1 + i * 4] + tmp[2 + i * 4]
    let a2 = tmp[1 + i * 4] - tmp[2 + i * 4]
    let a3 = dc - tmp[3 + i * 4]
    c[o] = cast[int16]((a0 + a1) shr 3)
    c[o + 16] = cast[int16]((a3 + a2) shr 3)
    c[o + 32] = cast[int16]((a0 - a1) shr 3)
    c[o + 48] = cast[int16]((a3 - a2) shr 3)
    o += 64

# -- the loop filters (on the picture's planes) --

proc sclip1(v: int): int {.inline.} = (if v < -128: -128 elif v > 127: 127 else: v)
proc sclip2(v: int): int {.inline.} = (if v < -16: -16 elif v > 15: 15 else: v)

proc filter2(p: Work; i, s: int) {.inline.} =
  let p1 = int(p[i - 2 * s])
  let p0 = int(p[i - s])
  let q0 = int(p[i])
  let q1 = int(p[i + s])
  let a = 3 * (q0 - p0) + sclip1(p1 - q1)
  let a1 = sclip2((a + 4) shr 3)
  let a2 = sclip2((a + 3) shr 3)
  p[i - s] = clip8b(p0 + a2)
  p[i] = clip8b(q0 - a1)

proc filter4(p: Work; i, s: int) {.inline.} =
  let p1 = int(p[i - 2 * s])
  let p0 = int(p[i - s])
  let q0 = int(p[i])
  let q1 = int(p[i + s])
  let a = 3 * (q0 - p0)
  let a1 = sclip2((a + 4) shr 3)
  let a2 = sclip2((a + 3) shr 3)
  let a3 = (a1 + 1) shr 1
  p[i - 2 * s] = clip8b(p1 + a3)
  p[i - s] = clip8b(p0 + a2)
  p[i] = clip8b(q0 - a1)
  p[i + s] = clip8b(q1 - a3)

proc filter6(p: Work; i, s: int) {.inline.} =
  let p2 = int(p[i - 3 * s])
  let p1 = int(p[i - 2 * s])
  let p0 = int(p[i - s])
  let q0 = int(p[i])
  let q1 = int(p[i + s])
  let q2 = int(p[i + 2 * s])
  let a = sclip1(3 * (q0 - p0) + sclip1(p1 - q1))
  let a1 = (27 * a + 63) shr 7
  let a2 = (18 * a + 63) shr 7
  let a3 = (9 * a + 63) shr 7
  p[i - 3 * s] = clip8b(p2 + a3)
  p[i - 2 * s] = clip8b(p1 + a2)
  p[i - s] = clip8b(p0 + a1)
  p[i] = clip8b(q0 - a1)
  p[i + s] = clip8b(q1 - a2)
  p[i + 2 * s] = clip8b(q2 - a3)

proc hev(p: Work; i, s, t: int): bool {.inline.} =
  abs(int(p[i - 2 * s]) - int(p[i - s])) > t or abs(int(p[i + s]) - int(p[i])) > t

proc needsFilter(p: Work; i, s, t: int): bool {.inline.} =
  4 * abs(int(p[i - s]) - int(p[i])) + abs(int(p[i - 2 * s]) - int(p[i + s])) <= t

proc needsFilter2(p: Work; i, s, t, it: int): bool {.inline.} =
  let p3 = int(p[i - 4 * s])
  let p2 = int(p[i - 3 * s])
  let p1 = int(p[i - 2 * s])
  let p0 = int(p[i - s])
  let q0 = int(p[i])
  let q1 = int(p[i + s])
  let q2 = int(p[i + 2 * s])
  let q3 = int(p[i + 3 * s])
  if 4 * abs(p0 - q0) + abs(p1 - q1) > t: return false
  abs(p3 - p2) <= it and abs(p2 - p1) <= it and abs(p1 - p0) <= it and
    abs(q3 - q2) <= it and abs(q2 - q1) <= it and abs(q1 - q0) <= it

proc simpleFilter(p: Work; i, s, along, n, thresh: int) =
  ## The simple filter across an edge: `n` places from `i`, `along` apart,
  ## the edge between `- s` and 0.
  let t2 = 2 * thresh + 1
  for k in 0 ..< n:
    let j = i + k * along
    if needsFilter(p, j, s, t2): filter2(p, j, s)

proc edgeFilter(p: Work; i, s, along, n, thresh, ithresh, hevT: int; mbEdge: bool) =
  let t2 = 2 * thresh + 1
  for k in 0 ..< n:
    let j = i + k * along
    if needsFilter2(p, j, s, t2, ithresh):
      if hev(p, j, s, hevT): filter2(p, j, s)
      elif mbEdge: filter6(p, j, s)
      else: filter4(p, j, s)

# -- the frame --

type
  FInfo = object
    limit, ilevel, hevThresh: int
    inner: bool

  MBData = object
    i4x4, skip: bool
    segment, uvmode: int
    modes: array[16, uint8]

  Vp8 = object
    w, h, mbW, mbH: int
    br: BoolDec
    parts: seq[BoolDec]
    useSegment, updateMap, absDelta: bool
    quantizer, fstrength: array[4, int]
    segProb: array[3, int]
    filterType, level, sharpness: int
    useLfDelta: bool
    refLfDelta, modeLfDelta: array[4, int]
    dq: array[4, array[6, int]]           # y1 dc, ac; y2 dc, ac; uv dc, ac
    probas: array[1056, uint8]            # [type][band][ctx][11]
    useSkip: bool
    skipP: int
    finfo: array[4, array[2, FInfo]]
    y, u, v: seq[uint8]                   # the planes (whole macroblocks)
    yStride, uvStride: int

proc parseHeader(dec: var Vp8; data: string; a, b: int) =
  if b - a < 10: fail("damaged lossy WebP (too short)")
  let bits = le24(data, a)
  if (bits and 1) != 0: fail("damaged lossy WebP (not a key frame)")
  if ((bits shr 1) and 7) > 3: fail("damaged lossy WebP (profile)")
  if ((bits shr 4) and 1) == 0: fail("lossy WebP frame not shown")
  let partLen = bits shr 5
  if u8(data, a + 3) != 0x9D or u8(data, a + 4) != 0x01 or u8(data, a + 5) != 0x2A:
    fail("damaged lossy WebP (signature)")
  dec.w = le16(data, a + 6) and 0x3FFF
  dec.h = le16(data, a + 8) and 0x3FFF
  if dec.w == 0 or dec.h == 0: fail("damaged lossy WebP (size)")
  dec.mbW = (dec.w + 15) shr 4
  dec.mbH = (dec.h + 15) shr 4
  let p0 = a + 10
  if partLen > b - p0: fail("damaged lossy WebP (partition length)")
  let buf = bytesOf(data)
  dec.br.initBool(buf, p0, p0 + partLen)
  template br: untyped = dec.br
  discard br.getBit(0x80)                   # color space
  discard br.getBit(0x80)                   # clamping type
  # segments
  dec.useSegment = br.getBit(0x80) == 1
  dec.segProb = [255, 255, 255]
  if dec.useSegment:
    dec.updateMap = br.getBit(0x80) == 1
    if br.getBit(0x80) == 1:
      dec.absDelta = br.getBit(0x80) == 1
      for s in 0 .. 3: dec.quantizer[s] = (if br.getBit(0x80) == 1: br.getSignedValue(7) else: 0)
      for s in 0 .. 3: dec.fstrength[s] = (if br.getBit(0x80) == 1: br.getSignedValue(6) else: 0)
    if dec.updateMap:
      for s in 0 .. 2: dec.segProb[s] = (if br.getBit(0x80) == 1: br.getValue(8) else: 255)
  # the loop filter
  let simple = br.getBit(0x80) == 1
  dec.level = br.getValue(6)
  dec.sharpness = br.getValue(3)
  dec.useLfDelta = br.getBit(0x80) == 1
  if dec.useLfDelta and br.getBit(0x80) == 1:
    for i in 0 .. 3:
      if br.getBit(0x80) == 1: dec.refLfDelta[i] = br.getSignedValue(6)
    for i in 0 .. 3:
      if br.getBit(0x80) == 1: dec.modeLfDelta[i] = br.getSignedValue(6)
  dec.filterType = if dec.level == 0: 0 elif simple: 1 else: 2
  # the token partitions
  let last = (1 shl br.getValue(2)) - 1
  let q = p0 + partLen
  if b - q < 3 * last: fail("damaged lossy WebP (partitions)")
  var start = q + 3 * last
  var left = b - start
  dec.parts.setLen(last + 1)
  for p in 0 ..< last:
    let size = min(le24(data, q + 3 * p), left)
    dec.parts[p].initBool(buf, start, start + size)
    start += size
    left -= size
  dec.parts[last].initBool(buf, start, b)
  if start >= b: fail("damaged lossy WebP (truncated)")
  # the quantizers
  let base = br.getValue(7)
  var dqs: array[5, int]
  for k in 0 .. 4: dqs[k] = (if br.getBit(0x80) == 1: br.getSignedValue(4) else: 0)
  for s in 0 .. 3:
    var q = base
    if dec.useSegment:
      q = dec.quantizer[s]
      if not dec.absDelta: q += base
    elif s > 0:
      dec.dq[s] = dec.dq[0]
      continue
    let m = addr dec.dq[s]
    m[0] = int(dcTable[clamp(q + dqs[0], 0, 127)])
    m[1] = int(acTable[clamp(q, 0, 127)])
    m[2] = int(dcTable[clamp(q + dqs[1], 0, 127)]) * 2
    m[3] = max(8, (int(acTable[clamp(q + dqs[2], 0, 127)]) * 101581) shr 16)
    m[4] = int(dcTable[clamp(q + dqs[3], 0, 117)])
    m[5] = int(acTable[clamp(q + dqs[4], 0, 127)])
  discard br.getBit(0x80)                   # "refresh entropy probs": unused
  for i in 0 ..< 1056:
    dec.probas[i] = if br.getBit(int(coeffsUpdateProba[i])) == 1: uint8(br.getValue(8))
                    else: coeffsProba0[i]
  dec.useSkip = br.getBit(0x80) == 1
  if dec.useSkip: dec.skipP = br.getValue(8)
  if br.eof: fail("damaged lossy WebP (header)")
  # the filter strengths by segment and kind of macroblock
  if dec.filterType > 0:
    for s in 0 .. 3:
      var base = dec.level
      if dec.useSegment:
        base = dec.fstrength[s]
        if not dec.absDelta: base += dec.level
      for i4 in 0 .. 1:
        var level = base
        if dec.useLfDelta:
          level += dec.refLfDelta[0]
          if i4 == 1: level += dec.modeLfDelta[0]
        level = clamp(level, 0, 63)
        var f = FInfo(inner: i4 == 1)
        if level > 0:
          var ilevel = level
          if dec.sharpness > 0:
            ilevel = if dec.sharpness > 4: ilevel shr 2 else: ilevel shr 1
            ilevel = min(ilevel, 9 - dec.sharpness)
          ilevel = max(ilevel, 1)
          f.ilevel = ilevel
          f.limit = 2 * level + ilevel
          f.hevThresh = if level >= 40: 2 elif level >= 15: 1 else: 0
        dec.finfo[s][i4] = f

proc parseModes(dec: var Vp8; mb: var MBData; top: var openArray[uint8]; tx: int;
                left: var array[4, uint8]) {.inline.} =
  template br: untyped = dec.br
  mb.segment = 0
  if dec.updateMap:
    mb.segment = if br.getBit(dec.segProb[0]) == 0: br.getBit(dec.segProb[1])
                 else: br.getBit(dec.segProb[2]) + 2
  mb.skip = dec.useSkip and br.getBit(dec.skipP) == 1
  mb.i4x4 = br.getBit(145) == 0
  if not mb.i4x4:
    let ymode = if br.getBit(156) == 1: (if br.getBit(128) == 1: 1 else: 3)
                else: (if br.getBit(163) == 1: 2 else: 0)
    mb.modes[0] = uint8(ymode)
    for k in 0 .. 3:
      top[tx + k] = uint8(ymode)
      left[k] = uint8(ymode)
  else:
    for y in 0 .. 3:
      var ymode = int(left[y])
      for x in 0 .. 3:
        let pb = (int(top[tx + x]) * 10 + ymode) * 9
        template pr(k: int): int = int(bModesProba[pb + k])
        ymode =
          if br.getBit(pr(0)) == 0: 0
          elif br.getBit(pr(1)) == 0: 1
          elif br.getBit(pr(2)) == 0: 2
          elif br.getBit(pr(3)) == 0:
            (if br.getBit(pr(4)) == 0: 3 elif br.getBit(pr(5)) == 0: 4 else: 5)
          elif br.getBit(pr(6)) == 0: 6
          elif br.getBit(pr(7)) == 0: 7
          elif br.getBit(pr(8)) == 0: 8
          else: 9
        top[tx + x] = uint8(ymode)
        mb.modes[y * 4 + x] = uint8(ymode)
      left[y] = uint8(ymode)
  mb.uvmode = if br.getBit(142) == 0: 0
              elif br.getBit(114) == 0: 2
              elif br.getBit(183) == 1: 1
              else: 3

proc largeValue(d: var BoolDec; p: ptr UncheckedArray[uint8]; o: int): int =
  if d.getBit(int(p[o + 3])) == 0:
    if d.getBit(int(p[o + 4])) == 0: 2
    else: 3 + d.getBit(int(p[o + 5]))
  elif d.getBit(int(p[o + 6])) == 0:
    if d.getBit(int(p[o + 7])) == 0: 5 + d.getBit(159)
    else:
      var v = 7 + 2 * d.getBit(165)
      v + d.getBit(145)
  else:
    let b1 = d.getBit(int(p[o + 8]))
    let b0 = d.getBit(int(p[o + 9 + b1]))
    let cat = 2 * b1 + b0
    var v = 0
    case cat
    of 0:
      for pr in Cat3: v = v + v + d.getBit(pr)
    of 1:
      for pr in Cat4: v = v + v + d.getBit(pr)
    of 2:
      for pr in Cat5: v = v + v + d.getBit(pr)
    else:
      for pr in Cat6: v = v + v + d.getBit(pr)
    v + 3 + (8 shl cat)

proc getCoeffs(dd: var BoolDec; probas: ptr UncheckedArray[uint8]; typ, ctx, dc, ac, first: int;
               c: Coeffs; o: int): int =
  ## Reads one block's coefficients (from `first`), dequantized, into
  ## `c[o ..]`; the place after the last one not zero.
  var d = dd                                 # (in registers while it reads)
  let base = typ * 264                       # 8 bands * 3 contexts * 11
  var n = first
  var p = base + (Bands[n] * 3 + ctx) * 11
  result = 16
  block reading:
    while n < 16:
      if d.getBit(int(probas[p])) == 0:
        result = n
        break reading
      while d.getBit(int(probas[p + 1])) == 0:
        inc n
        if n == 16: break reading
        p = base + Bands[n] * 33
      var v: int
      let nb = base + Bands[n + 1] * 33
      if d.getBit(int(probas[p + 2])) == 0:
        v = 1
        p = nb + 11
      else:
        v = largeValue(d, probas, p)
        p = nb + 22
      if d.getBit(0x80) == 1: v = -v
      c[o + Zigzag[n]] = cast[int16](v * (if n > 0: ac else: dc))
      inc n
  dd = d

proc nzCode(nzCoeffs: uint32; nz: int; dcNz: bool): uint32 {.inline.} =
  (nzCoeffs shl 2) or uint32(if nz > 3: 3 elif nz > 1: 2 elif dcNz: 1 else: 0)

proc decodeFrame(dec: var Vp8) =
  ## Reads all macroblocks, reconstructs and filters them into `dec.y/u/v`.
  dec.yStride = dec.mbW * 16
  dec.uvStride = dec.mbW * 8
  dec.y = newSeqUninit[uint8](dec.yStride * dec.mbH * 16)
  dec.u = newSeqUninit[uint8](dec.uvStride * dec.mbH * 8)
  dec.v = newSeqUninit[uint8](dec.uvStride * dec.mbH * 8)
  var work: array[Bps * 17 + Bps * 9, uint8]
  let p = cast[Work](addr work[0])
  var coeffBuf: array[384, int16]
  let c = cast[Coeffs](addr coeffBuf[0])
  var intraT = newSeq[uint8](4 * dec.mbW)
  var intraL: array[4, uint8]
  var nzT = newSeq[uint8](dec.mbW)            # the contexts above: bits 0-3 Y, 4-5 U, 6-7 V
  var nzDcT = newSeq[uint8](dec.mbW)
  var topY = newSeq[uint8](dec.mbW * 16)      # the unfiltered row above
  var topU = newSeq[uint8](dec.mbW * 8)
  var topV = newSeq[uint8](dec.mbW * 8)
  var mbs = newSeq[MBData](dec.mbW)
  var fis = newSeq[FInfo](dec.mbW)
  let probas = cast[ptr UncheckedArray[uint8]](addr dec.probas[0])
  let lastPart = dec.parts.high
  for mbY in 0 ..< dec.mbH:
    # the modes of the row
    intraL = [0'u8, 0, 0, 0]
    for mbX in 0 ..< dec.mbW:
      parseModes(dec, mbs[mbX], intraT, 4 * mbX, intraL)
    if dec.br.eof: fail("damaged lossy WebP (truncated modes)")
    var nzL, nzDcL: uint8
    # the left column of the work block, and its corner
    for j in 0 ..< 16: p[YOff + j * Bps - 1] = 129
    for j in 0 ..< 8:
      p[UOff + j * Bps - 1] = 129
      p[VOff + j * Bps - 1] = 129
    if mbY > 0:
      p[YOff - Bps - 1] = 129
      p[UOff - Bps - 1] = 129
      p[VOff - Bps - 1] = 129
    else:
      for k in 0 ..< 21: p[YOff - Bps - 1 + k] = 127
      for k in 0 ..< 9:
        p[UOff - Bps - 1 + k] = 127
        p[VOff - Bps - 1 + k] = 127
    template tok: untyped = dec.parts[mbY and lastPart]
    for mbX in 0 ..< dec.mbW:
      let mb = addr mbs[mbX]
      let q = addr dec.dq[mb.segment]
      # the coefficients
      var nonZeroY, nonZeroUV: uint32
      var skip = mb.skip
      if not skip:
        zeroMem(c, sizeof(coeffBuf))
        var first: int
        var acType: int
        if not mb.i4x4:
          var dcs: array[16, int16]
          let ctx = int(nzDcT[mbX]) + int(nzDcL)
          let nz = getCoeffs(tok, probas, 1, ctx, q[2], q[3], 0,
                             cast[Coeffs](addr dcs[0]), 0)
          let f = uint8(nz > 0)
          nzDcT[mbX] = f
          nzDcL = f
          if nz > 1:
            wht(dcs, c)
          else:
            let dc0 = cast[int16]((int(dcs[0]) + 3) shr 3)
            for i in 0 .. 15: c[i * 16] = dc0
          first = 1
          acType = 0
        else:
          first = 0
          acType = 3
        var tnz = nzT[mbX] and 0x0F
        var lnz = nzL and 0x0F
        var o = 0
        for y in 0 .. 3:
          var l = lnz and 1
          var nzc = 0'u32
          for x in 0 .. 3:
            let ctx = int(l) + int(tnz and 1)
            let nz = getCoeffs(tok, probas, acType, ctx, q[0], q[1], first, c, o)
            l = uint8(nz > first)
            tnz = (tnz shr 1) or (l shl 7)
            nzc = nzCode(nzc, nz, c[o] != 0)
            o += 16
          tnz = tnz shr 4
          lnz = (lnz shr 1) or (l shl 7)
          nonZeroY = (nonZeroY shl 8) or nzc
        var outT = tnz
        var outL = lnz shr 4
        for ch in [0, 2]:
          var nzc = 0'u32
          tnz = nzT[mbX] shr (4 + ch)
          lnz = nzL shr (4 + ch)
          for y in 0 .. 1:
            var l = lnz and 1
            for x in 0 .. 1:
              let ctx = int(l) + int(tnz and 1)
              let nz = getCoeffs(tok, probas, 2, ctx, q[4], q[5], 0, c, o)
              l = uint8(nz > 0)
              tnz = (tnz shr 1) or (l shl 3)
              nzc = nzCode(nzc, nz, c[o] != 0)
              o += 16
            tnz = tnz shr 2
            lnz = (lnz shr 1) or (l shl 5)
          nonZeroUV = nonZeroUV or (nzc shl (4 * ch))
          outT = outT or ((tnz shl 4) shl ch)
          outL = outL or ((lnz and 0xF0) shl ch)
        nzT[mbX] = outT
        nzL = outL
        skip = (nonZeroY or nonZeroUV) == 0
      else:
        nzT[mbX] = 0
        nzL = 0
        if not mb.i4x4:
          nzDcT[mbX] = 0
          nzDcL = 0
      if tok.eof: fail("damaged lossy WebP (truncated)")
      if dec.filterType > 0:
        var f = dec.finfo[mb.segment][ord(mb.i4x4)]
        f.inner = f.inner or not skip
        fis[mbX] = f
      # reconstruct in the work block
      if mbX > 0:
        for j in -1 ..< 16:
          for k in 0 .. 3: p[YOff + j * Bps - 4 + k] = p[YOff + j * Bps + 12 + k]
        for j in -1 ..< 8:
          for k in 0 .. 3:
            p[UOff + j * Bps - 4 + k] = p[UOff + j * Bps + 4 + k]
            p[VOff + j * Bps - 4 + k] = p[VOff + j * Bps + 4 + k]
      if mbY > 0:
        copyMem(addr p[YOff - Bps], addr topY[mbX * 16], 16)
        copyMem(addr p[UOff - Bps], addr topU[mbX * 8], 8)
        copyMem(addr p[VOff - Bps], addr topV[mbX * 8], 8)
      var bits = nonZeroY
      if mb.i4x4:
        let tr = YOff - Bps + 16
        if mbY > 0:
          if mbX >= dec.mbW - 1:
            for k in 0 .. 3: p[tr + k] = topY[mbX * 16 + 15]
          else:
            copyMem(addr p[tr], addr topY[mbX * 16 + 16], 4)
        for r in 1 .. 3:
          for k in 0 .. 3: p[tr + r * 4 * Bps + k] = p[tr + k]
        for n in 0 .. 15:
          let d = YOff + Scan[n]
          predLuma4(p, d, int(mb.modes[n]))
          doTransform(bits, c, n * 16, p, d)
          bits = bits shl 2
      else:
        var mode = int(mb.modes[0])
        if mode == 0:
          mode = if mbX == 0: (if mbY == 0: 6 else: 5) else: (if mbY == 0: 4 else: 0)
        predLuma16(p, YOff, mode)
        if bits != 0:
          for n in 0 .. 15:
            doTransform(bits, c, n * 16, p, YOff + Scan[n])
            bits = bits shl 2
      var uvmode = mb.uvmode
      if uvmode == 0:
        uvmode = if mbX == 0: (if mbY == 0: 6 else: 5) else: (if mbY == 0: 4 else: 0)
      predChroma8(p, UOff, uvmode)
      predChroma8(p, VOff, uvmode)
      doUVTransform(nonZeroUV, c, 256, p, UOff)
      doUVTransform(nonZeroUV shr 8, c, 320, p, VOff)
      if mbY < dec.mbH - 1:
        copyMem(addr topY[mbX * 16], addr p[YOff + 15 * Bps], 16)
        copyMem(addr topU[mbX * 8], addr p[UOff + 7 * Bps], 8)
        copyMem(addr topV[mbX * 8], addr p[VOff + 7 * Bps], 8)
      # into the planes
      for j in 0 ..< 16:
        copyMem(addr dec.y[(mbY * 16 + j) * dec.yStride + mbX * 16], addr p[YOff + j * Bps], 16)
      for j in 0 ..< 8:
        copyMem(addr dec.u[(mbY * 8 + j) * dec.uvStride + mbX * 8], addr p[UOff + j * Bps], 8)
        copyMem(addr dec.v[(mbY * 8 + j) * dec.uvStride + mbX * 8], addr p[VOff + j * Bps], 8)
    # the loop filter over the row
    if dec.filterType > 0:
      let yp = cast[Work](addr dec.y[0])
      let up = cast[Work](addr dec.u[0])
      let vp = cast[Work](addr dec.v[0])
      let ys = dec.yStride
      let uvs = dec.uvStride
      for mbX in 0 ..< dec.mbW:
        let f = fis[mbX]
        let limit = f.limit
        if limit == 0: continue
        let yo = mbY * 16 * ys + mbX * 16
        let uvo = mbY * 8 * uvs + mbX * 8
        if dec.filterType == 1:
          if mbX > 0: simpleFilter(yp, yo, 1, ys, 16, limit + 4)
          if f.inner:
            for k in 1 .. 3: simpleFilter(yp, yo + 4 * k, 1, ys, 16, limit)
          if mbY > 0: simpleFilter(yp, yo, ys, 1, 16, limit + 4)
          if f.inner:
            for k in 1 .. 3: simpleFilter(yp, yo + 4 * k * ys, ys, 1, 16, limit)
        else:
          let il = f.ilevel
          let ht = f.hevThresh
          if mbX > 0:
            edgeFilter(yp, yo, 1, ys, 16, limit + 4, il, ht, true)
            edgeFilter(up, uvo, 1, uvs, 8, limit + 4, il, ht, true)
            edgeFilter(vp, uvo, 1, uvs, 8, limit + 4, il, ht, true)
          if f.inner:
            for k in 1 .. 3: edgeFilter(yp, yo + 4 * k, 1, ys, 16, limit, il, ht, false)
            edgeFilter(up, uvo + 4, 1, uvs, 8, limit, il, ht, false)
            edgeFilter(vp, uvo + 4, 1, uvs, 8, limit, il, ht, false)
          if mbY > 0:
            edgeFilter(yp, yo, ys, 1, 16, limit + 4, il, ht, true)
            edgeFilter(up, uvo, uvs, 1, 8, limit + 4, il, ht, true)
            edgeFilter(vp, uvo, uvs, 1, 8, limit + 4, il, ht, true)
          if f.inner:
            for k in 1 .. 3: edgeFilter(yp, yo + 4 * k * ys, ys, 1, 16, limit, il, ht, false)
            edgeFilter(up, uvo + 4 * uvs, uvs, 1, 8, limit, il, ht, false)
            edgeFilter(vp, uvo + 4 * uvs, uvs, 1, 8, limit, il, ht, false)

# -- YUV 4:2:0 to RGB, with libwebp's "fancy" upsampling --

proc clipRgb(v: int): uint32 {.inline.} =
  uint32(if (v and not 16383) == 0: v shr 6 elif v < 0: 0 else: 255)

proc yuvToArgb(y, u, v: int): uint32 {.inline.} =
  let yy = (y * 19077) shr 8
  let r = clipRgb(yy + ((v * 26149) shr 8) - 14234)
  let g = clipRgb(yy - ((u * 6419) shr 8) - ((v * 13320) shr 8) + 8708)
  let b = clipRgb(yy + ((u * 33050) shr 8) - 17685)
  0xFF000000'u32 or (r shl 16) or (g shl 8) or b

proc upsamplePair(ty, by: Work; tu, tv, cu, cv: Work; td, bd: ptr UncheckedArray[uint32];
                  len: int) =
  ## Two rows of pixels (the bottom one when `by` is not nil) from the chroma
  ## rows above (`tu`, `tv`) and below (`cu`, `cv`) them; libwebp's way.
  template uv(u, v: Work; i: int): uint32 = uint32(u[i]) or (uint32(v[i]) shl 16)
  let last = (len - 1) shr 1
  var tl = uv(tu, tv, 0)
  var l = uv(cu, cv, 0)
  block:
    let uv0 = (3'u32 * tl + l + 0x00020002'u32) shr 2
    td[0] = yuvToArgb(int(ty[0]), int(uv0 and 255), int(uv0 shr 16))
  if by != nil:
    let uv0 = (3'u32 * l + tl + 0x00020002'u32) shr 2
    bd[0] = yuvToArgb(int(by[0]), int(uv0 and 255), int(uv0 shr 16))
  for x in 1 .. last:
    let t = uv(tu, tv, x)
    let cur = uv(cu, cv, x)
    let avg = tl + t + l + cur + 0x00080008'u32
    let diag12 = (avg + 2'u32 * (t + l)) shr 3
    let diag03 = (avg + 2'u32 * (tl + cur)) shr 3
    block:
      let uv0 = (diag12 + tl) shr 1
      let uv1 = (diag03 + t) shr 1
      td[2 * x - 1] = yuvToArgb(int(ty[2 * x - 1]), int(uv0 and 255), int(uv0 shr 16))
      td[2 * x] = yuvToArgb(int(ty[2 * x]), int(uv1 and 255), int(uv1 shr 16))
    if by != nil:
      let uv0 = (diag03 + l) shr 1
      let uv1 = (diag12 + cur) shr 1
      bd[2 * x - 1] = yuvToArgb(int(by[2 * x - 1]), int(uv0 and 255), int(uv0 shr 16))
      bd[2 * x] = yuvToArgb(int(by[2 * x]), int(uv1 and 255), int(uv1 shr 16))
    tl = t
    l = cur
  if (len and 1) == 0:
    block:
      let uv0 = (3'u32 * tl + l + 0x00020002'u32) shr 2
      td[len - 1] = yuvToArgb(int(ty[len - 1]), int(uv0 and 255), int(uv0 shr 16))
    if by != nil:
      let uv0 = (3'u32 * l + tl + 0x00020002'u32) shr 2
      bd[len - 1] = yuvToArgb(int(by[len - 1]), int(uv0 and 255), int(uv0 shr 16))

proc toArgb(dec: Vp8): seq[uint32] =
  let w = dec.w
  let h = dec.h
  result = newSeqUninit[uint32](w * h)
  let o = cast[ptr UncheckedArray[uint32]](addr result[0])
  let yp = cast[Work](unsafeAddr dec.y[0])
  let up = cast[Work](unsafeAddr dec.u[0])
  let vp = cast[Work](unsafeAddr dec.v[0])
  template yr(r: int): Work = cast[Work](addr yp[r * dec.yStride])
  template ur(r: int): Work = cast[Work](addr up[r * dec.uvStride])
  template vr(r: int): Work = cast[Work](addr vp[r * dec.uvStride])
  template orow(r: int): ptr UncheckedArray[uint32] = cast[ptr UncheckedArray[uint32]](addr o[r * w])
  upsamplePair(yr(0), nil, ur(0), vr(0), ur(0), vr(0), orow(0), nil, w)
  var k = 1
  while 2 * k - 1 < h:
    let top = 2 * k - 1
    if top + 1 < h:
      upsamplePair(yr(top), yr(top + 1), ur(k - 1), vr(k - 1), ur(k), vr(k),
                   orow(top), orow(top + 1), w)
    else:
      upsamplePair(yr(top), nil, ur(k - 1), vr(k - 1), ur(k - 1), vr(k - 1), orow(top), nil, w)
    inc k

proc decodeVp8(data: string; a, b: int): tuple[w, h: int; px: seq[uint32]] =
  ## The picture of a VP8 chunk's payload `data[a ..< b]`, opaque.
  var dec: Vp8
  parseHeader(dec, data, a, b)
  decodeFrame(dec)
  (dec.w, dec.h, toArgb(dec))

# ---- transparency (ALPH) -----------------------------------------------------------------------

proc unfilterRow(filter: int; prev: ptr UncheckedArray[uint8]; row: ptr UncheckedArray[uint8];
                 w: int) =
  ## Undoes the alpha filter of one row in place (`prev` nil on the first).
  if filter == 0: return
  if prev == nil or filter == 1:
    var pred = if prev == nil: 0'u8 else: prev[0]
    for i in 0 ..< w:
      row[i] = row[i] + pred
      pred = row[i]
  elif filter == 2:
    for i in 0 ..< w: row[i] = row[i] + prev[i]
  else:
    var top = prev[0]
    var tl = top
    var left = top
    for i in 0 ..< w:
      top = prev[i]
      let g = int(left) + int(top) - int(tl)
      left = row[i] + uint8(if g < 0: 0 elif g > 255: 255 else: g)
      tl = top
      row[i] = left

proc decodeAlpha(data: string; a, b, w, h: int): seq[uint8] =
  if b - a <= 1: fail("damaged WebP transparency")
  let hd = u8(data, a)
  let meth = hd and 3
  let filter = (hd shr 2) and 3
  let pre = (hd shr 4) and 3
  if meth > 1 or pre > 1 or (hd shr 6) != 0: fail("damaged WebP transparency")
  result = newSeq[uint8](w * h)
  if meth == 0:
    if b - a - 1 < w * h: fail("damaged WebP transparency (truncated)")
    copyMem(addr result[0], unsafeAddr data[a + 1], w * h)
  else:
    var r = lbits(data, a + 1, b)
    let px = decodeLImage(r, w, h, true)
    for i in 0 ..< w * h: result[i] = uint8((px[i] shr 8) and 255)
  let p = cast[ptr UncheckedArray[uint8]](addr result[0])
  for y in 0 ..< h:
    let prev = if y == 0: nil else: cast[ptr UncheckedArray[uint8]](addr p[(y - 1) * w])
    unfilterRow(filter, prev, cast[ptr UncheckedArray[uint8]](addr p[y * w]), w)

{.pop.}

# ---- the file: chunks, frames, animation --------------------------------------------------------

type
  WFrame = object
    x, y, w, h, duration: int
    dispose, blend: bool                 # to the background after; blended over the canvas
    alphA, alphB: int                    # the ALPH payload (alphA < 0: none)
    bsA, bsB: int                        # the VP8 / VP8L payload
    lossless, hasAlpha: bool

  WFile = object
    w, h: int
    animated, alpha: bool
    loops: int
    frames: seq[WFrame]

proc bitstreamInfo(data: string; f: var WFrame) =
  ## The size and kind of a frame's bitstream.
  if f.lossless:
    if f.bsB - f.bsA < 5 or u8(data, f.bsA) != 0x2F: fail("damaged lossless WebP header")
    let v = le32(data, f.bsA + 1)
    f.w = (v and 0x3FFF) + 1
    f.h = ((v shr 14) and 0x3FFF) + 1
    f.hasAlpha = ((v shr 28) and 1) == 1
  else:
    if f.bsB - f.bsA < 10: fail("damaged lossy WebP header")
    f.w = le16(data, f.bsA + 6) and 0x3FFF
    f.h = le16(data, f.bsA + 8) and 0x3FFF
    f.hasAlpha = f.alphA >= 0

proc nextChunk(data: string; p: var int; stop: int): tuple[id: string; a, b: int] =
  ## The chunk at `p` (its payload `a ..< b`), `p` moved past it; id "" at the end.
  if p + 8 > stop: return ("", 0, 0)
  let n = le32(data, p + 4)
  let a = p + 8
  if n < 0 or a + n > stop: fail("damaged WebP file (chunk size)")
  result = (data[p ..< p + 4], a, a + n)
  p = a + n + (n and 1)

proc parseWebp(data: string): WFile =
  if data.len < 20 or data[0 .. 3] != "RIFF" or data[8 .. 11] != "WEBP": fail("not a WebP file")
  let stop = min(data.len, 8 + le32(data, 4))
  var p = 12
  template next(p: var int; stop: int): tuple[id: string; a, b: int] = nextChunk(data, p, stop)
  let first = next(p, stop)
  case first.id
  of "VP8 ", "VP8L":
    var f = WFrame(bsA: first.a, bsB: first.b, alphA: -1, lossless: first.id == "VP8L",
                   blend: false)
    bitstreamInfo(data, f)
    result.w = f.w
    result.h = f.h
    result.alpha = f.hasAlpha
    result.frames.add f
  of "VP8X":
    if first.b - first.a < 10: fail("damaged WebP file (VP8X)")
    let flags = u8(data, first.a)
    result.w = le24(data, first.a + 4) + 1
    result.h = le24(data, first.a + 7) + 1
    result.alpha = (flags and 0x10) != 0
    var alphA, alphB = -1
    while true:
      let c = next(p, stop)
      case c.id
      of "": break
      of "ANIM":
        if c.b - c.a >= 6: result.loops = le16(data, c.a + 4)
        result.animated = true
      of "ANMF":
        if c.b - c.a < 16: fail("damaged WebP file (ANMF)")
        var f = WFrame(alphA: -1, bsA: -1)
        f.x = 2 * le24(data, c.a)
        f.y = 2 * le24(data, c.a + 3)
        let fw = le24(data, c.a + 6) + 1
        let fh = le24(data, c.a + 9) + 1
        f.duration = le24(data, c.a + 12)
        let fl = u8(data, c.a + 15)
        f.dispose = (fl and 1) != 0
        f.blend = (fl and 2) == 0
        var q = c.a + 16
        while true:
          let s = next(q, c.b)
          case s.id
          of "": break
          of "ALPH":
            if f.alphA < 0:
              f.alphA = s.a
              f.alphB = s.b
          of "VP8 ", "VP8L":
            f.bsA = s.a
            f.bsB = s.b
            f.lossless = s.id == "VP8L"
            break
          else: discard
        if f.bsA < 0: fail("damaged WebP file (frame without a picture)")
        if f.lossless: f.alphA = -1
        bitstreamInfo(data, f)
        if f.w != fw or f.h != fh: fail("damaged WebP file (frame size)")
        if f.x + f.w > result.w or f.y + f.h > result.h: fail("damaged WebP file (frame outside)")
        result.frames.add f
        result.animated = true
      of "ALPH":
        if alphA < 0:
          alphA = c.a
          alphB = c.b
      of "VP8 ", "VP8L":
        if result.frames.len == 0 and not result.animated:
          var f = WFrame(bsA: c.a, bsB: c.b, lossless: c.id == "VP8L", alphA: -1)
          if not f.lossless and alphA >= 0:
            f.alphA = alphA
            f.alphB = alphB
          bitstreamInfo(data, f)
          if f.w != result.w or f.h != result.h: fail("damaged WebP file (picture size)")
          result.frames.add f
      else: discard
    if result.frames.len == 0: fail("WebP file without a picture")
  else:
    fail("not a WebP file")
  if result.w * result.h > (1 shl 28): fail("WebP picture too large")

proc decodeFramePixels(data: string; f: WFrame): seq[uint32] =
  ## A frame's own pixels (f.w x f.h), 0xAARRGGBB.
  if f.lossless:
    var used: bool
    var r = decodeVp8l(data, f.bsA, f.bsB, used)
    if r.w != f.w or r.h != f.h: fail("damaged WebP file (size)")
    result = move r.px
  else:
    result = decodeVp8(data, f.bsA, f.bsB).px
    if f.alphA >= 0:
      let a = decodeAlpha(data, f.alphA, f.alphB, f.w, f.h)
      for i in 0 ..< result.len: result[i] = (result[i] and 0x00FFFFFF'u32) or (uint32(a[i]) shl 24)

proc blendPixel(src, dst: uint32): uint32 =
  ## `src` over `dst`, straight alpha, libwebp's integer arithmetic.
  let sa = src shr 24
  if sa == 0: return dst
  let da = dst shr 24
  let dfa = (da * (256 - sa)) shr 8
  let ba = sa + dfa
  let scale = (1'u32 shl 24) div ba
  result = ba shl 24
  for sh in [0, 8, 16]:
    let s = (src shr sh) and 255
    let d = (dst shr sh) and 255
    let v = ((s * sa + d * dfa) * scale) shr 24
    result = result or ((v and 255) shl sh)

proc webpFrames(data: string; first: bool): seq[tuple[bmp: Bitmap; delayMs: int]] =
  let file = parseWebp(data)
  if not file.animated:
    let f = file.frames[0]
    return @[(toBitmap(f.w, f.h, decodeFramePixels(data, f)), 0)]
  let w = file.w
  let h = file.h
  var canvas = newSeq[uint32](w * h)
  var disposed = newSeq[uint32](w * h)       # the previous canvas, its frame disposed of
  var prev: WFrame
  var prevKey = false
  for n, f in file.frames:
    let key = n == 0 or
      ((not f.hasAlpha or not f.blend) and f.w == w and f.h == h) or
      (prev.dispose and ((prev.w == w and prev.h == h) or prevKey))
    if key:
      for p in canvas.mitems: p = 0
    else:
      canvas = disposed
    let px = decodeFramePixels(data, f)
    for y in 0 ..< f.h:
      copyMem(addr canvas[(f.y + y) * w + f.x], unsafeAddr px[y * f.w], f.w * 4)
    if n > 0 and f.blend and not key:
      template blendSpan(y, x0, x1: int) =
        for x in x0 ..< x1:
          let i = y * w + x
          if (canvas[i] shr 24) != 255: canvas[i] = blendPixel(canvas[i], disposed[i])
      for y in f.y ..< f.y + f.h:
        if not prev.dispose:
          blendSpan(y, f.x, f.x + f.w)
        elif y < prev.y or y >= prev.y + prev.h or f.x >= prev.x + prev.w or
             f.x + f.w <= prev.x:
          blendSpan(y, f.x, f.x + f.w)
        else:
          if f.x < prev.x: blendSpan(y, f.x, prev.x)
          if f.x + f.w > prev.x + prev.w: blendSpan(y, prev.x + prev.w, f.x + f.w)
    result.add (toBitmap(w, h, canvas), f.duration)
    if first: return
    disposed = canvas
    if f.dispose:
      for y in f.y ..< f.y + f.h:
        for x in f.x ..< f.x + f.w: disposed[y * w + x] = 0
    prev = f
    prevKey = key

proc isWebp*(data: string): bool =
  ## Whether `data` begins as a WebP file does.
  data.len >= 16 and data[0 .. 3] == "RIFF" and data[8 .. 11] == "WEBP" and
    data[12 .. 15] in ["VP8 ", "VP8L", "VP8X"]

proc webpInfo*(data: string): tuple[w, h: int; frames: int; alpha, lossless, animated: bool] =
  ## The size of the picture (the canvas of an animation), how many frames,
  ## whether it says it has transparency, whether every frame is lossless,
  ## whether it is an animation; without decoding the pixels.
  let f = parseWebp(data)
  var lossless = true
  for fr in f.frames: lossless = lossless and fr.lossless
  (f.w, f.h, f.frames.len, f.alpha, lossless, f.animated)

proc decodeWebp*(data: string): Bitmap =
  ## The picture of a WebP file (the first frame of an animation, on its
  ## canvas). Raises `WebpError` when it is not WebP or is damaged.
  webpFrames(data, true)[0].bmp

proc decodeWebpFrames*(data: string): seq[tuple[bmp: Bitmap; delayMs: int]] =
  ## Each frame of an animation as it is shown -- on the whole canvas, blended
  ## over and disposed of as the file says (transparent where nothing was
  ## drawn; the file's background color is only a hint, as in libwebp) --
  ## and how long, in milliseconds. A still picture gives one frame (0 ms).
  webpFrames(data, false)

# ---- VP8L written ---------------------------------------------------------------------------------

{.push boundChecks: off, overflowChecks: off, rangeChecks: off.}

type
  BitWriter = object
    ## Bits written from the lowest of each byte up.
    buf: string
    acc: uint64
    n: int

  HCode = object
    ## A prefix code: each symbol's length and (bit-reversed) code.
    lens, codes: seq[int]
    used: int            # symbols with a code; 0 or 1: nothing is written

proc put(w: var BitWriter; v, bits: int) {.inline.} =
  w.acc = w.acc or (uint64(v) shl w.n)
  w.n += bits
  while w.n >= 8:
    w.buf.add char(w.acc and 255)
    w.acc = w.acc shr 8
    w.n -= 8

proc finish(w: var BitWriter): string =
  if w.n > 0: w.buf.add char(w.acc and 255)
  w.acc = 0
  w.n = 0
  move w.buf

proc huffLengths(freq: openArray[int]; maxBits: int): seq[int] =
  ## Huffman code lengths for these counts, none longer than `maxBits`
  ## (small counts raised until the tree is shallow enough).
  result = newSeq[int](freq.len)
  var syms: seq[int]
  for s, f in freq:
    if f > 0: syms.add s
  if syms.len == 0: return
  if syms.len == 1:
    result[syms[0]] = 1
    return
  let n = syms.len
  var least = 1
  while true:
    var weight = newSeq[int](2 * n - 1)
    var parent = newSeq[int](2 * n - 1)
    var order = newSeq[int](n)
    for i, s in syms:
      weight[i] = max(freq[s], least)
      order[i] = i
    order.sort(proc (a, b: int): int = cmp((weight[a], a), (weight[b], b)))
    # two queues: the leaves by weight, the made nodes (made in order of weight)
    var qa = 0
    var qb = n
    var made = n
    template takeLeast(): int =
      var r: int
      if qa < n and (qb >= made or weight[order[qa]] <= weight[qb]):
        r = order[qa]
        inc qa
      else:
        r = qb
        inc qb
      r
    while made < 2 * n - 1:
      let a = takeLeast()
      let b = takeLeast()
      weight[made] = weight[a] + weight[b]
      parent[a] = made
      parent[b] = made
      inc made
    var depth = newSeq[int](2 * n - 1)
    var deepest = 0
    for i in countdown(2 * n - 3, 0):
      depth[i] = depth[parent[i]] + 1
      if i < n: deepest = max(deepest, depth[i])
    if deepest <= maxBits:
      for i, s in syms: result[s] = depth[i]
      return
    least *= 2

proc makeCode(freq: openArray[int]; maxBits = 15): HCode =
  result.lens = huffLengths(freq, maxBits)
  result.codes = newSeq[int](freq.len)
  var count: array[16, int]
  for l in result.lens:
    if l > 0:
      inc count[l]
      inc result.used
  var next: array[16, int]
  var code = 0
  for l in 1 .. 15:
    code = (code + count[l - 1]) shl 1
    next[l] = code
  for s, l in result.lens:
    if l > 0:
      var c = next[l]
      inc next[l]
      var r = 0
      for _ in 0 ..< l:
        r = (r shl 1) or (c and 1)
        c = c shr 1
      result.codes[s] = r

proc sym(w: var BitWriter; c: HCode; s: int) {.inline.} =
  if c.used > 1: w.put(c.codes[s], c.lens[s])

proc writeCode(w: var BitWriter; c: HCode) =
  ## The description of a prefix code, as the decoder reads it.
  var syms: seq[int]
  for s, l in c.lens:
    if l > 0: syms.add s
  if syms.len == 0:                              # nothing: say "symbol 0"
    w.put(1, 1); w.put(0, 1); w.put(0, 1); w.put(0, 1)
    return
  if syms.len <= 2 and syms[^1] < 256:
    w.put(1, 1)
    w.put(syms.len - 1, 1)
    if syms[0] < 2:
      w.put(0, 1)
      w.put(syms[0], 1)
    else:
      w.put(1, 1)
      w.put(syms[0], 8)
    if syms.len == 2: w.put(syms[1], 8)
    return
  w.put(0, 1)
  # the lengths, run-length coded: 16 repeats the last length 3-6 times,
  # 17 and 18 give 3-10 and 11-138 zeros
  var toks: seq[(int, int)]
  var prev = 8
  var i = 0
  let n = c.lens.len
  while i < n:
    let l = c.lens[i]
    var run = 1
    while i + run < n and c.lens[i + run] == l: inc run
    var r = run
    if l == 0:
      while r > 0:
        if r < 3:
          toks.add (0, 0)
          dec r
        elif r <= 10:
          toks.add (17, r - 3)
          r = 0
        else:
          let k = min(r, 138)
          toks.add (18, k - 11)
          r -= k
    else:
      if prev != l:
        toks.add (l, 0)
        dec r
        prev = l
      while r > 0:
        if r < 3:
          toks.add (l, 0)
          dec r
        else:
          let k = min(r, 6)
          toks.add (16, k - 3)
          r -= k
    i += run
  var hist: array[19, int]
  for t in toks: inc hist[t[0]]
  let cl = makeCode(hist, 7)
  var count = 19
  while count > 4 and cl.lens[CodeLengthOrder[count - 1]] == 0: dec count
  w.put(count - 4, 4)
  for k in 0 ..< count: w.put(cl.lens[CodeLengthOrder[k]], 3)
  w.put(0, 1)                                    # every symbol's length follows
  for (s, extra) in toks:
    w.sym(cl, s)
    case s
    of 16: w.put(extra, 2)
    of 17: w.put(extra, 3)
    of 18: w.put(extra, 7)
    else: discard

proc prefixCode(v: int): tuple[sym, nbits, extra: int] {.inline.} =
  ## The prefix symbol and extra bits of a length or distance code `v` >= 1.
  let d = v - 1
  if d < 4: return (d, 0, 0)
  let hi = fastLog2(d)
  let second = (d shr (hi - 1)) and 1
  (2 * hi + second, hi - 1, d and ((1 shl (hi - 1)) - 1))

var planeLut: array[128, int]
for i in 0 ..< 128: planeLut[i] = -1
for k, (dx, dy) in PlaneCodes: planeLut[dy * 16 + 8 - dx] = k

proc distanceCode(width, dist: int): int {.inline.} =
  let yo = dist div width
  let xo = dist - yo * width
  if xo <= 8 and yo < 8:
    let k = planeLut[yo * 16 + 8 - xo]
    if k >= 0: return k + 1
  elif xo > width - 8 and yo < 7:
    let k = planeLut[(yo + 1) * 16 + 8 + (width - xo)]
    if k >= 0: return k + 1
  dist + 120

type
  LTok = object
    ## A literal pixel (len 0) or a copy of `len` pixels from `v` back.
    len: int32
    v: uint32

const
  MaxCopy = 4095
  Window = 1048456                      # the farthest a copy may reach back

proc lz77(px: openArray[uint32]; width: int; chainLen: int): seq[LTok] =
  ## The pixels as literals and copies: hash chains on pairs of pixels, the
  ## pixel to the left and the one above always tried, one step of lazy matching.
  let n = px.len
  result = newSeqOfCap[LTok](n div 2 + 16)
  if n < 3:
    for p in px: result.add LTok(v: p)
    return
  const hb = 18
  var head = newSeq[int32](1 shl hb)
  for h in head.mitems: h = -1
  var chain = newSeq[int32](n)
  template hashAt(i: int): int =
    int(((px[i] * 0x1E35A7BD'u32) + (px[i + 1] * 0x9E3779B1'u32)) shr (32 - hb))
  var inserted = 0
  template insertUpTo(e: int) =
    while inserted < min(e, n - 1):
      let h = hashAt(inserted)
      chain[inserted] = head[h]
      head[h] = int32(inserted)
      inc inserted
  proc matchLen(px: openArray[uint32]; a, b, most: int): int {.inline.} =
    while result < most and px[a + result] == px[b + result]: inc result
  proc best(px: openArray[uint32]; i, width: int; head: seq[int32]; chain: seq[int32];
            chainLen: int): (int, int) =
    let n = px.len
    let most = min(MaxCopy, n - i)
    var bl = 0
    var bd = 0
    for d in [1, width]:
      if d <= i:
        let l = matchLen(px, i, i - d, most)
        if l > bl:
          bl = l
          bd = d
    if bl < most and i + 1 < n:
      var j = int(head[int(((px[i] * 0x1E35A7BD'u32) + (px[i + 1] * 0x9E3779B1'u32)) shr (32 - hb))])
      var steps = 0
      while j >= 0 and i - j <= Window and steps < chainLen:
        if px[j + bl] == px[i + bl]:
          let l = matchLen(px, i, j, most)
          if l > bl:
            bl = l
            bd = i - j
            if l == most: break
        j = int(chain[j])
        inc steps
    (bl, bd)
  var i = 0
  while i < n:
    insertUpTo(i)
    var (l, d) = best(px, i, width, head, chain, chainLen)
    if l >= 3 and l < MaxCopy and i + 1 < n:
      insertUpTo(i + 1)
      let (l2, d2) = best(px, i + 1, width, head, chain, chainLen)
      if l2 > l + 1:                           # better a pixel later: this one a literal
        result.add LTok(v: px[i])
        inc i
        l = l2
        d = d2
    if l >= 3 or (l == 2 and (d == 1 or d == width)):
      result.add LTok(len: int32(l), v: uint32(d))
      i += l
    else:
      result.add LTok(v: px[i])
      inc i

proc cacheKey(p: uint32; bits: int): int {.inline.} = int((p * 0x1E35A7BD'u32) shr (32 - bits))

var nlog2nTable: array[4096, float32]
for i in 1 ..< 4096: nlog2nTable[i] = float32(float(i) * log2(float(i)))

proc nlog2n(c: int): float {.inline.} =
  if c < 4096: float(nlog2nTable[c]) else: float(c) * log2(float(c))

proc entropyBits(h: openArray[int]): float =
  ## The bits a code fitted to these counts would take (Shannon).
  var total = 0
  var s = 0.0
  var used = 0
  for c in h:
    if c > 0:
      total += c
      s += nlog2n(c)
      inc used
  if used <= 1: return 0.0
  nlog2n(total) - s + float(used) * 4.0          # and a guess at the code's description

proc cacheCost(toks: seq[LTok]; bits: int): float =
  ## The bits the literals would take with a color cache of `bits`.
  var green = newSeq[int](280 + (if bits > 0: 1 shl bits else: 0))
  var red, blue, alpha: array[256, int]
  var cache = newSeq[uint32](if bits > 0: 1 shl bits else: 1)
  for t in toks:
    if t.len == 0:
      let p = t.v
      if bits > 0:
        let k = cacheKey(p, bits)
        if cache[k] == p:
          inc green[280 + k]
          continue
        cache[k] = p
      inc green[int((p shr 8) and 255)]
      inc red[int((p shr 16) and 255)]
      inc blue[int(p and 255)]
      inc alpha[int(p shr 24)]
    else:
      inc green[256 + prefixCode(int(t.len)).sym]
  entropyBits(green) + entropyBits(red) + entropyBits(blue) + entropyBits(alpha)

type
  FTok = object
    ## A symbol to write: a literal (kind 0), a cache hit (1, `a` its key) or
    ## a copy (2, `a` its length, `d` its distance code); `pos` its first pixel.
    pos: int32
    kind: uint8
    a: uint32
    d: int32

proc bitLengths(h: openArray[int]): seq[float32] =
  ## The cost in bits of each symbol under these counts (unseen ones dear).
  result = newSeq[float32](h.len)
  var total = 0
  for c in h: total += c
  let lt = log2(float(total + 1))
  for i, c in h: result[i] = float32(if c > 0: lt - log2(float(c)) else: lt + 4.0)

proc lz77Parse(px: openArray[uint32]; width, chainLen, cacheBits: int; prior: seq[LTok]): seq[LTok] =
  ## The pixels as literals and copies at the least cost (in bits, by the
  ## counts of the `prior` parse): the longest match found at each place and
  ## its shorter lengths weighed against literals and cache hits.
  let n = px.len
  # costs from the first parse
  let cacheSize = if cacheBits > 0: 1 shl cacheBits else: 0
  var green = newSeq[int](280 + cacheSize)
  var red, blue, alpha: array[256, int]
  var dist: array[40, int]
  var cache = newSeq[uint32](max(1, cacheSize))
  var pos = 0
  for t in prior:
    if t.len == 0:
      let p = t.v
      if cacheBits > 0:
        let k = cacheKey(p, cacheBits)
        if cache[k] == p:
          inc green[280 + k]
          inc pos
          continue
        cache[k] = p
      inc green[int((p shr 8) and 255)]
      inc red[int((p shr 16) and 255)]
      inc blue[int(p and 255)]
      inc alpha[int(p shr 24)]
      inc pos
    else:
      inc green[256 + prefixCode(int(t.len)).sym]
      inc dist[prefixCode(distanceCode(width, int(t.v))).sym]
      if cacheBits > 0:
        for k in pos ..< pos + int(t.len): cache[cacheKey(px[k], cacheBits)] = px[k]
      pos += int(t.len)
  let cg = bitLengths(green)
  let cr = bitLengths(red)
  let cb = bitLengths(blue)
  let ca = bitLengths(alpha)
  let cd = bitLengths(dist)
  var lenCost = newSeq[float32](MaxCopy + 1)
  for l in 1 .. MaxCopy:
    let pc = prefixCode(l)
    lenCost[l] = cg[256 + pc.sym] + float32(pc.nbits)
  # the longest match at each place (one search; a long match carries on)
  const hb = 18
  var head = newSeq[int32](1 shl hb)
  for h in head.mitems: h = -1
  var chain = newSeq[int32](n)
  var mlen = newSeq[int16](n)
  var mdist = newSeq[int32](n)
  proc matchLen(px: openArray[uint32]; a, b, most: int): int {.inline.} =
    while result < most and px[a + result] == px[b + result]: inc result
  for i in 0 ..< n:
    if i + 1 < n:
      let h = int(((px[i] * 0x1E35A7BD'u32) + (px[i + 1] * 0x9E3779B1'u32)) shr (32 - hb))
      let most = min(MaxCopy, n - i)
      var bl = 0
      var bd = 0
      if i > 0 and mlen[i - 1] > 32:
        bl = int(mlen[i - 1]) - 1
        bd = int(mdist[i - 1])
        if bl < most:
          bl = matchLen(px, i, i - bd, most)
      else:
        for d in [1, width]:
          if d <= i:
            let l = matchLen(px, i, i - d, most)
            if l > bl:
              bl = l
              bd = d
        var j = int(head[h])
        var steps = 0
        while j >= 0 and i - j <= Window and steps < chainLen and bl < most:
          if px[j + bl] == px[i + bl]:
            let l = matchLen(px, i, j, most)
            if l > bl:
              bl = l
              bd = i - j
          j = int(chain[j])
          inc steps
      mlen[i] = int16(bl)
      mdist[i] = int32(bd)
      chain[i] = head[h]
      head[h] = int32(i)
  # the cheapest way to each place
  var cost = newSeq[float32](n + 1)
  var back = newSeq[int16](n + 1)          # the length of the step that got there (0: literal)
  for i in 1 .. n: cost[i] = Inf
  for c in cache.mitems: c = 0
  for i in 0 ..< n:
    if (i and 0xFFFF) == 0 and i > 0:
      # (the costs ahead made small again, so float32 keeps them apart)
      let off = cost[i]
      for k in i .. min(n, i + MaxCopy): cost[k] -= off
    let p = px[i]
    var lit: float32
    if cacheBits > 0:
      let k = cacheKey(p, cacheBits)
      lit = if cache[k] == p: cg[280 + k]
            else: cg[int((p shr 8) and 255)] + cr[int((p shr 16) and 255)] +
                  cb[int(p and 255)] + ca[int(p shr 24)]
      cache[k] = p
    else:
      lit = cg[int((p shr 8) and 255)] + cr[int((p shr 16) and 255)] +
            cb[int(p and 255)] + ca[int(p shr 24)]
    if cost[i] + lit < cost[i + 1]:
      cost[i + 1] = cost[i] + lit
      back[i + 1] = 0
    let l = int(mlen[i])
    if l >= 2:
      let dc = prefixCode(distanceCode(width, int(mdist[i])))
      let base = cost[i] + cd[dc.sym] + float32(dc.nbits)
      let top = min(l, 32)
      for k in 2 .. top:
        let c = base + lenCost[k]
        if c < cost[i + k]:
          cost[i + k] = c
          back[i + k] = int16(k)
      if l > top:
        let c = base + lenCost[l]
        if c < cost[i + l]:
          cost[i + l] = c
          back[i + l] = int16(l)
  # back from the end
  var steps: seq[int32]
  var at = n
  while at > 0:
    let k = int(back[at])
    steps.add int32(k)
    at -= (if k == 0: 1 else: k)
  result = newSeqOfCap[LTok](steps.len)
  at = 0
  for s in countdown(steps.high, 0):
    let k = int(steps[s])
    if k == 0:
      result.add LTok(v: px[at])
      inc at
    else:
      result.add LTok(len: int32(k), v: uint32(mdist[at]))
      at += k

proc symbols(px: seq[uint32]; width: int; toks: seq[LTok]; cacheBits: int): seq[FTok] =
  result = newSeqOfCap[FTok](toks.len)
  var cache = newSeq[uint32](if cacheBits > 0: 1 shl cacheBits else: 1)
  var pos = 0
  for t in toks:
    if t.len == 0:
      let p = t.v
      if cacheBits > 0:
        let k = cacheKey(p, cacheBits)
        if cache[k] == p:
          result.add FTok(pos: int32(pos), kind: 1, a: uint32(k))
          inc pos
          continue
        cache[k] = p
      result.add FTok(pos: int32(pos), kind: 0, a: p)
      inc pos
    else:
      result.add FTok(pos: int32(pos), kind: 2, a: uint32(t.len),
                      d: int32(distanceCode(width, int(t.v))))
      if cacheBits > 0:
        for k in pos ..< pos + int(t.len): cache[cacheKey(px[k], cacheBits)] = px[k]
      pos += int(t.len)

template countTok(h: var openArray[int32]; base: int; t: FTok; offs: array[5, int]) =
  case t.kind
  of 0:
    inc h[base + offs[0] + int((t.a shr 8) and 255)]
    inc h[base + offs[1] + int((t.a shr 16) and 255)]
    inc h[base + offs[2] + int(t.a and 255)]
    inc h[base + offs[3] + int(t.a shr 24)]
  of 1:
    inc h[base + offs[0] + 280 + int(t.a)]
  else:
    inc h[base + offs[0] + 256 + prefixCode(int(t.a)).sym]
    inc h[base + offs[4] + prefixCode(int(t.d)).sym]

proc histBits(h: openArray[int32]; a: int; offs: array[5, int]; size: int): float =
  ## The bits of the symbols counted in `h[a ..< a + size]`, each part coded apart.
  for part in 0 .. 4:
    let lo = a + offs[part]
    let hi = if part == 4: a + size else: a + offs[part + 1]
    var total = 0
    var s = 0.0
    var used = 0
    for i in lo ..< hi:
      let c = int(h[i])
      if c > 0:
        total += c
        s += nlog2n(c)
        inc used
    if used > 1: result += nlog2n(total) - s + float(used) * 4.0
    result += 12.0

proc clusterTiles(hist: seq[int32]; tiles, size: int; offs: array[5, int]): seq[int] =
  ## Groups the tiles whose symbols are alike (each group gets its own codes):
  ## binned by their literal statistics, merged while that saves bits, then
  ## each tile moved to the group that codes it best. The group of each tile.
  result = newSeq[int](tiles)
  # 1. bins of tiles alike
  var feat = newSeq[array[3, float]](tiles)
  var lo = [Inf, Inf, Inf]
  var hi = [-Inf, -Inf, -Inf]
  var empty = newSeq[bool](tiles)
  for t in 0 ..< tiles:
    let a = t * size
    var n = 0
    for i in 0 ..< 256: n += int(hist[a + offs[0] + i])
    if n == 0:
      empty[t] = true
      continue
    for k in 0 .. 2:
      let part = [0, 1, 2][k]
      var s = 0.0
      var tot = 0
      for i in offs[part] ..< offs[part] + 256:
        let c = int(hist[a + i])
        if c > 0:
          s += nlog2n(c)
          tot += c
      feat[t][k] = (nlog2n(tot) - s) / float(max(1, tot))
      lo[k] = min(lo[k], feat[t][k])
      hi[k] = max(hi[k], feat[t][k])
  var binOf = newSeq[int](64)
  for b in binOf.mitems: b = -1
  var clusters: seq[seq[int32]]           # their counts
  for t in 0 ..< tiles:
    var bin = 0
    if not empty[t]:
      for k in 0 .. 2:
        let span = hi[k] - lo[k]
        let q = if span <= 0: 0 else: min(3, int(4.0 * (feat[t][k] - lo[k]) / span))
        bin = bin * 4 + q
    if binOf[bin] < 0:
      binOf[bin] = clusters.len
      clusters.add newSeq[int32](size)
    let c = binOf[bin]
    result[t] = c
    for i in 0 ..< size: clusters[c][i] += hist[t * size + i]
  # 2. merge the pairs of groups that save the most, while any saves
  var k = clusters.len
  var alive = newSeq[bool](k)
  var bits = newSeq[float](k)
  for c in 0 ..< k:
    alive[c] = true
    bits[c] = histBits(clusters[c], 0, offs, size)
  var merged = newSeq[int32](size)
  proc mergedBits(a, b: seq[int32]; merged: var seq[int32]; offs: array[5, int]; size: int): float =
    for i in 0 ..< size: merged[i] = a[i] + b[i]
    histBits(merged, 0, offs, size)
  var gain = newSeq[float](k * k)
  for a in 0 ..< k:
    for b in a + 1 ..< k:
      gain[a * k + b] = bits[a] + bits[b] - mergedBits(clusters[a], clusters[b], merged, offs, size)
  while true:
    var best = 0.0
    var ba, bb = -1
    for a in 0 ..< k:
      if not alive[a]: continue
      for b in a + 1 ..< k:
        if alive[b] and gain[a * k + b] > best:
          best = gain[a * k + b]
          ba = a
          bb = b
    if ba < 0: break
    for i in 0 ..< size: clusters[ba][i] += clusters[bb][i]
    alive[bb] = false
    bits[ba] = histBits(clusters[ba], 0, offs, size)
    for c in 0 ..< k:
      if alive[c] and c != ba:
        let (x, y) = if c < ba: (c, ba) else: (ba, c)
        gain[x * k + y] = bits[x] + bits[y] - mergedBits(clusters[x], clusters[y], merged, offs, size)
  var live: seq[int]
  for c in 0 ..< k:
    if alive[c]: live.add c
  # 3. each tile to the group that codes it in the fewest bits
  for round in 0 .. 1:
    var costs = newSeq[seq[float32]](live.len)
    for j, c in live:
      costs[j] = newSeq[float32](size)
      for part in 0 .. 4:
        let a = offs[part]
        let b = if part == 4: size else: offs[part + 1]
        var tot = 0
        for i in a ..< b: tot += int(clusters[c][i])
        let lt = log2(float(tot + 1))
        for i in a ..< b:
          let n = int(clusters[c][i])
          costs[j][i] = float32(if n > 0: lt - log2(float(n)) else: lt + 6.0)
    var fresh = newSeq[seq[int32]](live.len)
    for j in 0 ..< live.len: fresh[j] = newSeq[int32](size)
    var nz: seq[int]
    for t in 0 ..< tiles:
      let a = t * size
      nz.setLen(0)
      for i in 0 ..< size:
        if hist[a + i] > 0: nz.add i
      var best = Inf
      var bj = 0
      for j in 0 ..< live.len:
        var c = 0.0
        for i in nz: c += float(hist[a + i]) * float(costs[j][i])
        if c < best:
          best = c
          bj = j
      result[t] = bj
      for i in nz: fresh[bj][i] += hist[a + i]
    var newLive: seq[int]
    var remap = newSeq[int](live.len)
    for j in 0 ..< live.len:
      var n = 0'i64
      for v in fresh[j]: n += v
      if n > 0:
        remap[j] = newLive.len
        clusters[live[j]] = fresh[j]
        newLive.add live[j]
      else:
        remap[j] = -1
    for t in 0 ..< tiles: result[t] = remap[result[t]]
    var compact: seq[seq[int32]]
    for c in newLive: compact.add clusters[c]
    clusters = compact
    live = @[]
    for j in 0 ..< clusters.len: live.add j

proc writeSymbols(w: var BitWriter; syms: seq[FTok]; width, groups: int; groupOf: seq[int];
                  tileBits, tilesW, size: int; offs: array[5, int]) =
  ## The prefix codes of each group, then the symbols.
  # the codes of each group
  var counts = newSeq[int32](groups * size)
  for t in syms:
    var g = 0
    if groups > 1:
      let x = int(t.pos) mod width
      let y = int(t.pos) div width
      g = groupOf[(y shr tileBits) * tilesW + (x shr tileBits)]
    countTok(counts, g * size, t, offs)
  var codes = newSeq[array[5, HCode]](groups)
  for g in 0 ..< groups:
    for part in 0 .. 4:
      let a = g * size + offs[part]
      let b = if part == 4: g * size + size else: g * size + offs[part + 1]
      var f = newSeq[int](b - a)
      for i in a ..< b: f[i - a] = int(counts[i])
      codes[g][part] = makeCode(f)
      w.writeCode(codes[g][part])
  # the symbols
  for t in syms:
    var g = 0
    if groups > 1:
      let x = int(t.pos) mod width
      let y = int(t.pos) div width
      g = groupOf[(y shr tileBits) * tilesW + (x shr tileBits)]
    let c = addr codes[g]
    case t.kind
    of 0:
      w.sym(c[0], int((t.a shr 8) and 255))
      w.sym(c[1], int((t.a shr 16) and 255))
      w.sym(c[2], int(t.a and 255))
      w.sym(c[3], int(t.a shr 24))
    of 1:
      w.sym(c[0], 280 + int(t.a))
    else:
      let lc = prefixCode(int(t.a))
      w.sym(c[0], 256 + lc.sym)
      w.put(lc.extra, lc.nbits)
      let dc = prefixCode(int(t.d))
      w.sym(c[4], dc.sym)
      w.put(dc.extra, dc.nbits)

proc writeImage(w: var BitWriter; px: seq[uint32]; width: int; level0, cacheOk: bool;
                chainLen = 64) =
  ## One entropy-coded image: its color cache, its prefix codes (one set, or
  ## a set for each group of tiles alike, for the picture itself), its symbols.
  let toks = lz77(px, width, chainLen)
  var cacheBits = 0
  if cacheOk and px.len > 64:
    var best = cacheCost(toks, 0)
    for b in [4, 6, 8, 10]:
      if (1 shl b) > px.len div 2: break
      let c = cacheCost(toks, b) + float(1 shl b) * 0.5
      if c < best:
        best = c
        cacheBits = b
  if cacheBits > 0:
    w.put(1, 1)
    w.put(cacheBits, 4)
  else:
    w.put(0, 1)
  let parsed = if level0 and px.len >= 64: lz77Parse(px, width, chainLen, cacheBits, toks) else: toks
  let syms = symbols(px, width, parsed, cacheBits)
  let gsize = 280 + (if cacheBits > 0: 1 shl cacheBits else: 0)
  let offs = [0, gsize, gsize + 256, gsize + 512, gsize + 768]
  let size = gsize + 768 + 40
  let height = px.len div width
  var groups = 1
  var groupOf: seq[int]                 # by tile
  var tileBits = 0
  var tilesW = 1
  if level0 and px.len >= 4096:
    tileBits = 3
    while subSize(width, tileBits) * subSize(height, tileBits) > 2600: inc tileBits
    tileBits = min(tileBits, 9)
    tilesW = subSize(width, tileBits)
    let tiles = tilesW * subSize(height, tileBits)
    var hist = newSeq[int32](tiles * size)
    for t in syms:
      let x = int(t.pos) mod width
      let y = int(t.pos) div width
      let tile = (y shr tileBits) * tilesW + (x shr tileBits)
      countTok(hist, tile * size, t, offs)
    groupOf = clusterTiles(hist, tiles, size, offs)
    for g in groupOf: groups = max(groups, g + 1)
  if groups > 1:
    # also with one set of codes: the shorter
    var one = w
    one.put(0, 1)
    writeSymbols(one, syms, width, 1, groupOf, 0, 0, size, offs)
    w.put(1, 1)
    w.put(tileBits - 2, 3)
    var meta = newSeq[uint32](groupOf.len)
    for i, g in groupOf: meta[i] = 0xFF000000'u32 or (uint32(g) shl 8)
    writeImage(w, meta, tilesW, false, false)
    writeSymbols(w, syms, width, groups, groupOf, tileBits, tilesW, size, offs)
    if one.buf.len * 8 + one.n < w.buf.len * 8 + w.n: w = one
  else:
    if level0: w.put(0, 1)
    writeSymbols(w, syms, width, 1, groupOf, 0, 0, size, offs)

proc subPixels(a, b: uint32): uint32 {.inline.} =
  (((a or 0x00FF00FF'u32) - (b and 0xFF00FF00'u32)) and 0xFF00FF00'u32) or
    (((a or 0xFF00FF00'u32) - (b and 0x00FF00FF'u32)) and 0x00FF00FF'u32)

proc costTable(hist: array[256, int]; total: int; t: var array[256, float32]) =
  ## The bits of each value, coded with these counts (one more each, so none is free).
  let lt = log2(float(total + 256))
  for v in 0 .. 255: t[v] = float32(lt - log2(float(hist[v] + 1)))

proc chooseModes(px: seq[uint32]; w, h, bits: int): seq[uint32] =
  ## For each tile, the predictor (0..13) whose residuals cost the least
  ## under the counts of the residuals chosen so far.
  let p = cast[ptr UncheckedArray[uint32]](unsafeAddr px[0])
  let tw = subSize(w, bits)
  let th = subSize(h, bits)
  result = newSeq[uint32](tw * th)
  var acc: array[4, array[256, int]]
  var total = 0
  # a start: small residuals likely
  for ch in 0 .. 3:
    for v in 0 .. 255:
      let d = min(v, 256 - v)
      acc[ch][v] = max(0, 8 - d)
      if ch == 0 and v == 0: acc[ch][v] += 64
  total = 0
  for v in 0 .. 255: total += acc[1][v]
  var cost: array[4, array[256, float32]]
  for ty in 0 ..< th:
    for tx in 0 ..< tw:
      for ch in 0 .. 3: costTable(acc[ch], total, cost[ch])
      var bestMode = 0
      var bestCost = Inf
      let x0 = tx shl bits
      let y0 = ty shl bits
      let x1 = min(w, x0 + (1 shl bits))
      let y1 = min(h, y0 + (1 shl bits))
      for mode in 0 .. 13:
        var c = 0.0
        for y in y0 ..< y1:
          for x in x0 ..< x1:
            let i = y * w + x
            let pred = if y == 0: (if x == 0: 0xFF000000'u32 else: p[i - 1])
                       elif x == 0: p[i - w]
                       else: predict(mode, p, i, w)
            let r = subPixels(p[i], pred)
            c += float(cost[0][int(r shr 24)] + cost[1][int((r shr 16) and 255)] +
                       cost[2][int((r shr 8) and 255)] + cost[3][int(r and 255)])
          if c >= bestCost: break
        if c < bestCost:
          bestCost = c
          bestMode = mode
      result[ty * tw + tx] = 0xFF000000'u32 or (uint32(bestMode) shl 8)
      for y in y0 ..< y1:
        for x in x0 ..< x1:
          let i = y * w + x
          let pred = if y == 0: (if x == 0: 0xFF000000'u32 else: p[i - 1])
                     elif x == 0: p[i - w]
                     else: predict(bestMode, p, i, w)
          let r = subPixels(p[i], pred)
          inc acc[0][int(r shr 24)]
          inc acc[1][int((r shr 16) and 255)]
          inc acc[2][int((r shr 8) and 255)]
          inc acc[3][int(r and 255)]
          inc total

proc predictResiduals(px: seq[uint32]; w, h, bits: int; modes: seq[uint32]): seq[uint32] =
  let p = cast[ptr UncheckedArray[uint32]](unsafeAddr px[0])
  let tw = subSize(w, bits)
  result = newSeq[uint32](px.len)
  for y in 0 ..< h:
    for x in 0 ..< w:
      let i = y * w + x
      let pred = if y == 0: (if x == 0: 0xFF000000'u32 else: p[i - 1])
                 elif x == 0: p[i - w]
                 else: predict(int((modes[(y shr bits) * tw + (x shr bits)] shr 8) and 15), p, i, w)
      result[i] = subPixels(p[i], pred)

proc crossTile(px: var seq[uint32]; w, x0, y0, x1, y1: int; cands: seq[(int, int, int)];
               costR, costB: array[256, float32]): (int, int, int) =
  ## The cross-color multipliers (green to red, green to blue, red to blue)
  ## among `cands` and the least-squares ones, whose red and blue cost least.
  var sgg, sgr, srr, sgb, sbr = 0.0
  for y in y0 ..< y1:
    for x in x0 ..< x1:
      let a = px[y * w + x]
      let g = float(cast[int8]((a shr 8) and 255))
      let r = float(cast[int8]((a shr 16) and 255))
      let b = float(cast[int8](a and 255))
      sgg += g * g
      sgr += g * r
      srr += r * r
      sgb += g * b
      sbr += b * r
  var all = cands
  if sgg > 0:
    let g2r = clamp(int(round(32.0 * sgr / sgg)), -128, 127)
    let det = sgg * srr - sgr * sgr
    var g2b, r2b = 0
    if abs(det) > 1e-6:
      g2b = clamp(int(round(32.0 * (sgb * srr - sbr * sgr) / det)), -128, 127)
      r2b = clamp(int(round(32.0 * (sbr * sgg - sgb * sgr) / det)), -128, 127)
    all.add (g2r, g2b, r2b)
    all.add (g2r, clamp(int(round(32.0 * sgb / sgg)), -128, 127), 0)
    for k in [-2, -1, 1, 2]:
      all.add (clamp(g2r + k, -128, 127), clamp(g2b + k, -128, 127), r2b)
  var bestR = (Inf, 0)
  var bestB = (Inf, 0, 0)
  for (g2r, g2b, r2b) in all:
    var cr, cb = 0.0
    for y in y0 ..< y1:
      for x in x0 ..< x1:
        let a = px[y * w + x]
        let g = int(cast[int8]((a shr 8) and 255))
        let r = int(cast[int8]((a shr 16) and 255))
        let nr = (int((a shr 16) and 255) - ((g2r * g) shr 5)) and 255
        let nb = (int(a and 255) - ((g2b * g) shr 5) - ((r2b * r) shr 5)) and 255
        cr += float(costR[nr])
        cb += float(costB[nb])
    if cr < bestR[0] - 0.5: bestR = (cr, g2r)
    if cb < bestB[0] - 0.5: bestB = (cb, g2b, r2b)
  (bestR[1], bestB[1], bestB[2])

proc crossColor(px: var seq[uint32]; w, h, bits: int): seq[uint32] =
  ## Chooses and applies the cross-color transform; its multipliers image.
  let tw = subSize(w, bits)
  let th = subSize(h, bits)
  result = newSeq[uint32](tw * th)
  var got = newSeq[(int, int, int)](tw * th)
  var accR, accB: array[256, int]
  for v in 0 .. 255:
    accR[v] = max(0, 8 - min(v, 256 - v))
    accB[v] = accR[v]
  var total = 0
  for v in accR: total += v
  var costR, costB: array[256, float32]
  for ty in 0 ..< th:
    for tx in 0 ..< tw:
      costTable(accR, total, costR)
      costTable(accB, total, costB)
      let x0 = tx shl bits
      let y0 = ty shl bits
      let x1 = min(w, x0 + (1 shl bits))
      let y1 = min(h, y0 + (1 shl bits))
      var cands = @[(0, 0, 0)]
      if tx > 0: cands.add got[ty * tw + tx - 1]
      if ty > 0: cands.add got[(ty - 1) * tw + tx]
      let (g2r, g2b, r2b) = crossTile(px, w, x0, y0, x1, y1, cands, costR, costB)
      got[ty * tw + tx] = (g2r, g2b, r2b)
      result[ty * tw + tx] = 0xFF000000'u32 or (uint32(r2b and 255) shl 16) or
                             (uint32(g2b and 255) shl 8) or uint32(g2r and 255)
      for y in y0 ..< y1:
        for x in x0 ..< x1:
          let i = y * w + x
          let a = px[i]
          let g = int(cast[int8]((a shr 8) and 255))
          let r = int(cast[int8]((a shr 16) and 255))
          let nr = (int((a shr 16) and 255) - ((g2r * g) shr 5)) and 255
          let nb = (int(a and 255) - ((g2b * g) shr 5) - ((r2b * r) shr 5)) and 255
          px[i] = (a and 0xFF00FF00'u32) or (uint32(nr) shl 16) or uint32(nb)
          inc accR[nr]
          inc accB[nb]
          inc total

proc writeVp8lStream(w: var BitWriter; argb: seq[uint32]; width, height: int) =
  ## The picture as a VP8L image stream (no header): its transforms, then
  ## its pixels.
  # few colors: a palette, the indexes packed several to a byte
  var colors: seq[uint32]
  block count:
    var seen = newSeq[uint32](4096)
    var full = newSeq[bool](4096)
    for p in argb:
      var k = int((p * 0x9E3779B1'u32) shr 20)
      while full[k] and seen[k] != p: k = (k + 1) and 4095
      if not full[k]:
        full[k] = true
        seen[k] = p
        colors.add p
        if colors.len > 256: break count
  if colors.len <= 256:
    colors.sort()
    let n = colors.len
    let bits = if n > 16: 0 elif n > 4: 1 elif n > 2: 2 else: 3
    w.put(1, 1)
    w.put(3, 2)
    w.put(n - 1, 8)
    var deltas = newSeq[uint32](n)
    deltas[0] = colors[0]
    for i in 1 ..< n: deltas[i] = subPixels(colors[i], colors[i - 1])
    writeImage(w, deltas, n, false, false)
    let pw = subSize(width, bits)
    var packed = newSeq[uint32](pw * height)
    let per = 1 shl bits
    let depth = 8 shr bits
    for y in 0 ..< height:
      for x in 0 ..< width:
        let idx = colors.lowerBound(argb[y * width + x])
        let j = y * pw + (x shr bits)
        packed[j] = packed[j] or (uint32(idx) shl (8 + depth * (x and (per - 1))))
    for p in packed.mitems: p = p or 0xFF000000'u32
    w.put(0, 1)
    writeImage(w, packed, pw, true, true)
    return
  # subtract green; then predict and decorrelate the colors, or not (for
  # drawings, long copies may do better): the shorter
  var px = argb
  for p in px.mitems:
    let g = (p shr 8) and 255
    p = (p and 0xFF00FF00'u32) or (((p or 0xFF00FF00'u32) - ((g shl 16) or g)) and 0x00FF00FF'u32)
  var same = 0
  for i in 1 ..< px.len:
    if px[i] == px[i - 1] or (i >= width and px[i] == px[i - width]): inc same
  let drawn = same * 4 > px.len                # many pixels repeat a neighbor
  var plain = w
  if drawn:
    plain.put(1, 1)
    plain.put(2, 2)
    plain.put(0, 1)
    writeImage(plain, px, width, true, true)
  w.put(1, 1)
  w.put(2, 2)
  let pbits = if width * height > 512 * 512: 4 else: 3
  let modes = chooseModes(px, width, height, pbits)
  px = predictResiduals(px, width, height, pbits, modes)
  w.put(1, 1)
  w.put(0, 2)
  w.put(pbits - 2, 3)
  writeImage(w, modes, subSize(width, pbits), false, false)
  let cbits = 5
  let mult = crossColor(px, width, height, cbits)
  w.put(1, 1)
  w.put(1, 2)
  w.put(cbits - 2, 3)
  writeImage(w, mult, subSize(width, cbits), false, false)
  w.put(0, 1)
  writeImage(w, px, width, true, true)
  if drawn and plain.buf.len * 8 + plain.n < w.buf.len * 8 + w.n: w = plain

proc vp8lBitstream(argb: seq[uint32]; width, height: int): string =
  ## A whole VP8L bitstream (the payload of a VP8L chunk).
  var w: BitWriter
  w.put(0x2F, 8)
  w.put(width - 1, 14)
  w.put(height - 1, 14)
  var alpha = false
  for p in argb:
    if p < 0xFF000000'u32:
      alpha = true
      break
  w.put(ord(alpha), 1)
  w.put(0, 3)
  writeVp8lStream(w, argb, width, height)
  w.finish()

{.pop.}

proc chunk(id, body: string): string =
  result = id
  let n = body.len
  result.add char(n and 255)
  result.add char((n shr 8) and 255)
  result.add char((n shr 16) and 255)
  result.add char((n shr 24) and 255)
  result.add body
  if (n and 1) == 1: result.add '\0'

proc riff(body: string): string =
  let n = body.len + 4
  result = "RIFF"
  result.add char(n and 255)
  result.add char((n shr 8) and 255)
  result.add char((n shr 16) and 255)
  result.add char((n shr 24) and 255)
  result.add "WEBP"
  result.add body

proc encodeWebpLossless*(b: Bitmap): string =
  ## `b` as a lossless WebP file (VP8L): every pixel kept exactly, the color
  ## under transparent ones too. ValueError when a side is not 1 to 16384.
  if b.w <= 0 or b.h <= 0 or b.w > 16384 or b.h > 16384:
    raise newException(ValueError, "a WebP picture is 1 to 16384 pixels a side")
  riff(chunk("VP8L", vp8lBitstream(b.px, b.w, b.h)))

# ---- VP8 written ----------------------------------------------------------------------------------

{.push boundChecks: off, overflowChecks: off, rangeChecks: off.}

type
  BoolEnc = object
    ## The boolean (arithmetic) coder of VP8, as libwebp's.
    buf: string
    range, value, run, nbBits: int

proc initBoolEnc(): BoolEnc = BoolEnc(range: 254, nbBits: -8)

proc flushBits(e: var BoolEnc) =
  let s = 8 + e.nbBits
  let bits = e.value shr s
  e.value -= bits shl s
  e.nbBits -= 8
  if (bits and 0xFF) != 0xFF:
    if (bits and 0x100) != 0 and e.buf.len > 0:
      e.buf[^1] = char((ord(e.buf[^1]) + 1) and 255)
    if e.run > 0:
      let v = if (bits and 0x100) != 0: '\x00' else: '\xFF'
      for _ in 0 ..< e.run: e.buf.add v
      e.run = 0
    e.buf.add char(bits and 0xFF)
  else:
    inc e.run

proc putBit(e: var BoolEnc; bit, prob: int) =
  let split = (e.range * prob) shr 8
  if bit != 0:
    e.value += split + 1
    e.range -= split + 1
  else:
    e.range = split
  if e.range < 127:
    let shift = 7 - fastLog2(e.range + 1)
    e.range = ((e.range + 1) shl shift) - 1
    e.value = e.value shl shift
    e.nbBits += shift
    if e.nbBits > 0: e.flushBits()

proc putBitR(e: var BoolEnc; bit, prob: int): bool {.inline.} =
  e.putBit(bit, prob)
  bit != 0

proc putBits(e: var BoolEnc; v, n: int) =
  for k in countdown(n - 1, 0): e.putBit((v shr k) and 1, 128)

proc putSignedBits(e: var BoolEnc; v, n: int) =
  e.putBit(ord(v != 0), 128)
  if v == 0: return
  if v < 0: e.putBits(((-v) shl 1) or 1, n + 1)
  else: e.putBits(v shl 1, n + 1)

proc finish(e: var BoolEnc): string =
  e.putBits(0, 9 - e.nbBits)
  e.nbBits = 0
  e.flushBits()
  move e.buf

var bitCost0: array[256, int]          # 1/256 bits of a 0 coded with probability p/256
for p in 0 .. 255: bitCost0[p] = int(round(-log2(max(float(p), 0.5) / 256.0) * 256.0))

proc costOf(bit, p: int): int {.inline.} =
  if bit == 0: bitCost0[p] else: bitCost0[255 - p]

type
  CostSink = object
    probas: ptr UncheckedArray[uint8]
    cost: int
  StatSink = object
    stats: ptr array[1056, array[2, int]]  # ones, all
  WriteSink = object
    probas: ptr UncheckedArray[uint8]
    enc: ptr BoolEnc

proc bitS(s: var CostSink; b, slot: int): bool {.inline.} =
  s.cost += costOf(b, int(s.probas[slot]))
  b != 0
proc fixedS(s: var CostSink; b, prob: int) {.inline.} = s.cost += costOf(b, prob)
proc bitS(s: var StatSink; b, slot: int): bool {.inline.} =
  inc s.stats[slot][1]
  if b != 0: inc s.stats[slot][0]
  b != 0
proc fixedS(s: var StatSink; b, prob: int) {.inline.} = discard
proc bitS(s: var WriteSink; b, slot: int): bool {.inline.} =
  s.enc[].putBit(b, int(s.probas[slot]))
  b != 0
proc fixedS(s: var WriteSink; b, prob: int) {.inline.} = s.enc[].putBit(b, prob)

proc emitCoeffs[S](s: var S; typ, ctx: int; lv: openArray[int16]; first, last: int) =
  ## The tokens of one block's levels (zigzag order), as VP8 codes them.
  var n = first
  var p = typ * 264 + (Bands[n] * 3 + ctx) * 11
  if not s.bitS(ord(last >= 0), p): return
  while n < 16:
    let c = int(lv[n])
    inc n
    var v = abs(c)
    if not s.bitS(ord(v != 0), p + 1):
      p = typ * 264 + Bands[n] * 33
      continue
    if not s.bitS(ord(v > 1), p + 2):
      p = typ * 264 + Bands[n] * 33 + 11
    else:
      if not s.bitS(ord(v > 4), p + 3):
        if s.bitS(ord(v != 2), p + 4): discard s.bitS(ord(v == 4), p + 5)
      elif not s.bitS(ord(v > 10), p + 6):
        if not s.bitS(ord(v > 6), p + 7):
          s.fixedS(ord(v == 6), 159)
        else:
          s.fixedS(ord(v >= 9), 165)
          s.fixedS(ord((v and 1) == 0), 145)
      else:
        if v < 3 + (8 shl 1):
          discard s.bitS(0, p + 8)
          discard s.bitS(0, p + 9)
          v -= 3 + (8 shl 0)
          for k, pr in Cat3: s.fixedS((v shr (2 - k)) and 1, pr)
        elif v < 3 + (8 shl 2):
          discard s.bitS(0, p + 8)
          discard s.bitS(1, p + 9)
          v -= 3 + (8 shl 1)
          for k, pr in Cat4: s.fixedS((v shr (3 - k)) and 1, pr)
        elif v < 3 + (8 shl 3):
          discard s.bitS(1, p + 8)
          discard s.bitS(0, p + 10)
          v -= 3 + (8 shl 2)
          for k, pr in Cat5: s.fixedS((v shr (4 - k)) and 1, pr)
        else:
          discard s.bitS(1, p + 8)
          discard s.bitS(1, p + 10)
          v -= 3 + (8 shl 3)
          for k, pr in Cat6: s.fixedS((v shr (10 - k)) and 1, pr)
      p = typ * 264 + Bands[n] * 33 + 22
    s.fixedS(ord(c < 0), 128)
    if n == 16 or not s.bitS(ord(n <= last), p): return

proc i4ModeCost(e: var CostSink; top, left, mode: int) =
  let pb = (top * 10 + left) * 9
  template b(bit, k: int): bool = (e.cost += costOf(bit, int(bModesProba[pb + k])); bit != 0)
  if b(ord(mode != 0), 0):
    if b(ord(mode != 1), 1):
      if b(ord(mode != 2), 2):
        if not b(ord(mode >= 6), 3):
          if b(ord(mode != 3), 4): discard b(ord(mode != 4), 5)
        else:
          if b(ord(mode != 6), 6):
            if b(ord(mode != 7), 7): discard b(ord(mode != 8), 8)

var i4Costs: array[1000, int]          # [top][left][mode]
for t in 0 .. 9:
  for l in 0 .. 9:
    for m in 0 .. 9:
      var e = CostSink()
      i4ModeCost(e, t, l, m)
      i4Costs[(t * 10 + l) * 10 + m] = e.cost

proc i16ModeCost(mode: int): int =
  costOf(1, 145) + (if mode == 1 or mode == 3: costOf(1, 156) + costOf(ord(mode == 1), 128)
                    else: costOf(0, 156) + costOf(ord(mode == 2), 163))

proc uvModeCost(mode: int): int =
  if mode == 0: costOf(0, 142)
  elif mode == 2: costOf(1, 142) + costOf(0, 114)
  else: costOf(1, 142) + costOf(1, 114) + costOf(ord(mode != 3), 183)

const
  FreqSharpening = [0, 30, 60, 90, 30, 60, 90, 90, 60, 90, 90, 90, 90, 90, 90, 90]

type
  QMat = object
    q, iq, bias, zthresh, sharpen: array[16, int]

  EncMB = object
    i4, skip: bool
    modes: array[16, uint8]               # the i16 mode in modes[0]
    uvmode: uint8
    lv: array[25, array[16, int16]]       # levels, zigzag: 0..15 Y, 16..19 U, 20..23 V, 24 Y2
    last: array[25, int8]

proc makeQMat(dc, ac, biasDc, biasAc: int; sharpen: bool): QMat =
  for i in 0 .. 15:
    let q = if i == 0: dc else: ac
    result.q[i] = q
    result.iq[i] = (1 shl 17) div q
    result.bias[i] = (if i == 0: biasDc else: biasAc) shl 9
    result.zthresh[i] = ((1 shl 17) - 1 - result.bias[i]) div result.iq[i]
    result.sharpen[i] = if sharpen: (FreqSharpening[i] * q) shr 11 else: 0

proc quantizeBlock(c: var array[16, int]; m: QMat; lv: var array[16, int16]; first: int): int =
  ## Quantizes `c` (raster order) into `lv` (zigzag order) from `first`, and
  ## leaves `c` dequantized; the place of the last level not zero (-1: none).
  result = -1
  for n in 0 ..< first: lv[n] = 0
  for n in first .. 15:
    let j = Zigzag[n]
    let neg = c[j] < 0
    let coeff = abs(c[j]) + m.sharpen[j]
    if coeff > m.zthresh[j]:
      var level = (coeff * m.iq[j] + m.bias[j]) shr 17
      if level > 2047: level = 2047
      if neg: level = -level
      c[j] = level * m.q[j]
      lv[n] = int16(level)
      if level != 0: result = n
    else:
      c[j] = 0
      lv[n] = 0

proc fdct(src: Work; so: int; pred: Work; po: int; o: var array[16, int]) =
  ## libwebp's forward DCT of the 4x4 source minus prediction.
  var tmp: array[16, int]
  for i in 0 .. 3:
    let s = so + i * Bps
    let r = po + i * Bps
    let d0 = int(src[s]) - int(pred[r])
    let d1 = int(src[s + 1]) - int(pred[r + 1])
    let d2 = int(src[s + 2]) - int(pred[r + 2])
    let d3 = int(src[s + 3]) - int(pred[r + 3])
    let a0 = d0 + d3
    let a1 = d1 + d2
    let a2 = d1 - d2
    let a3 = d0 - d3
    tmp[i * 4] = (a0 + a1) * 8
    tmp[i * 4 + 1] = (a2 * 2217 + a3 * 5352 + 1812) shr 9
    tmp[i * 4 + 2] = (a0 - a1) * 8
    tmp[i * 4 + 3] = (a3 * 2217 - a2 * 5352 + 937) shr 9
  for i in 0 .. 3:
    let a0 = tmp[i] + tmp[12 + i]
    let a1 = tmp[4 + i] + tmp[8 + i]
    let a2 = tmp[4 + i] - tmp[8 + i]
    let a3 = tmp[i] - tmp[12 + i]
    o[i] = (a0 + a1 + 7) shr 4
    o[4 + i] = ((a2 * 2217 + a3 * 5352 + 12000) shr 16) + ord(a3 != 0)
    o[8 + i] = (a0 - a1 + 7) shr 4
    o[12 + i] = (a3 * 2217 - a2 * 5352 + 51000) shr 16

proc fwht(dcs: array[16, int]): array[16, int] =
  ## libwebp's forward Walsh-Hadamard transform of the 16 luma DCs.
  var tmp: array[16, int]
  for i in 0 .. 3:
    let a0 = dcs[i * 4] + dcs[i * 4 + 2]
    let a1 = dcs[i * 4 + 1] + dcs[i * 4 + 3]
    let a2 = dcs[i * 4 + 1] - dcs[i * 4 + 3]
    let a3 = dcs[i * 4] - dcs[i * 4 + 2]
    tmp[i * 4] = a0 + a1
    tmp[i * 4 + 1] = a3 + a2
    tmp[i * 4 + 2] = a3 - a2
    tmp[i * 4 + 3] = a0 - a1
  for i in 0 .. 3:
    let a0 = tmp[i] + tmp[8 + i]
    let a1 = tmp[4 + i] + tmp[12 + i]
    let a2 = tmp[4 + i] - tmp[12 + i]
    let a3 = tmp[i] - tmp[8 + i]
    result[i] = (a0 + a1) shr 1
    result[4 + i] = (a3 + a2) shr 1
    result[8 + i] = (a3 - a2) shr 1
    result[12 + i] = (a0 - a1) shr 1

proc sse(a: Work; ao: int; b: Work; bo, w, h: int): int {.inline.} =
  for y in 0 ..< h:
    for x in 0 ..< w:
      let d = int(a[ao + y * Bps + x]) - int(b[bo + y * Bps + x])
      result += d * d

proc reconstructAdd(c: array[16, int]; p: Work; d: int) {.inline.} =
  var t: array[16, int16]
  for i in 0 .. 15: t[i] = int16(c[i])
  idctAdd(cast[Coeffs](addr t[0]), 0, p, d)

proc copyBlock(src: Work; so: int; dst: Work; d, w, h: int) {.inline.} =
  for y in 0 ..< h: copyMem(addr dst[d + y * Bps], addr src[so + y * Bps], w)

proc toYuv(px: openArray[uint32]; w, h: int; y, u, v: var seq[uint8]; yStride, uvStride, rows: int) =
  ## RGB to YUV 4:2:0 (libwebp's coefficients), the edges repeated to whole macroblocks.
  let uvRows = rows div 2
  y = newSeq[uint8](yStride * rows)
  u = newSeq[uint8](uvStride * uvRows)
  v = newSeq[uint8](uvStride * uvRows)
  for yy in 0 ..< rows:
    let sy = min(yy, h - 1)
    for xx in 0 ..< yStride:
      let p = px[sy * w + min(xx, w - 1)]
      let r = int((p shr 16) and 255)
      let g = int((p shr 8) and 255)
      let b = int(p and 255)
      y[yy * yStride + xx] = uint8((16839 * r + 33059 * g + 6420 * b + (16 shl 16) + (1 shl 15)) shr 16)
  for cy in 0 ..< uvRows:
    for cx in 0 ..< uvStride:
      var r, g, b, n = 0
      for dy in 0 .. 1:
        for dx in 0 .. 1:
          let sx = 2 * cx + dx
          let sy = 2 * cy + dy
          if sx < w and sy < h:
            let p = px[sy * w + sx]
            r += int((p shr 16) and 255)
            g += int((p shr 8) and 255)
            b += int(p and 255)
            inc n
      if n == 0:
        # beyond the picture: repeat the last chroma inside it
        let sx = min(cx, (w - 1) div 2)
        let sy = min(cy, (h - 1) div 2)
        u[cy * uvStride + cx] = u[sy * uvStride + sx]
        v[cy * uvStride + cx] = v[sy * uvStride + sx]
        continue
      if n != 4:
        r = (r * 4 + n div 2) div n
        g = (g * 4 + n div 2) div n
        b = (b * 4 + n div 2) div n
      let uu = (-9719 * r - 19081 * g + 28800 * b + (128 shl 18) + (1 shl 17)) shr 18
      let vv = (28800 * r - 24116 * g - 4684 * b + (128 shl 18) + (1 shl 17)) shr 18
      u[cy * uvStride + cx] = uint8(clamp(uu, 0, 255))
      v[cy * uvStride + cx] = uint8(clamp(vv, 0, 255))

proc filterLuma(recon: seq[uint8]; stride, mbW, mbH: int; inner: seq[bool]; level: int;
                rows: seq[int]): seq[uint8] =
  ## The luma plane as the decoder's normal loop filter at `level` leaves it
  ## (only the macroblock rows `rows`).
  result = recon
  if level == 0: return
  let p = cast[Work](addr result[0])
  let ilevel = level
  let limit = 2 * level + ilevel
  let ht = if level >= 40: 2 elif level >= 15: 1 else: 0
  for mbY in rows:
    for mbX in 0 ..< mbW:
      let yo = mbY * 16 * stride + mbX * 16
      let inn = inner[mbY * mbW + mbX]
      if mbX > 0: edgeFilter(p, yo, 1, stride, 16, limit + 4, ilevel, ht, true)
      if inn:
        for k in 1 .. 3: edgeFilter(p, yo + 4 * k, 1, stride, 16, limit, ilevel, ht, false)
      if mbY > 0: edgeFilter(p, yo, stride, 1, 16, limit + 4, ilevel, ht, true)
      if inn:
        for k in 1 .. 3: edgeFilter(p, yo + 4 * k * stride, stride, 1, 16, limit, ilevel, ht, false)

proc emitTokens[S](sink: var S; mbs: seq[EncMB]; mbW, mbH: int; useSkip: bool;
                   parts: ptr seq[BoolEnc]) =
  ## Every macroblock's tokens in order, with the decoder's contexts (a
  ## skipped macroblock leaves them empty); into `parts` row by row when writing.
  var nzTY = newSeq[array[4, bool]](mbW)
  var nzTU = newSeq[array[2, bool]](mbW)
  var nzTV = newSeq[array[2, bool]](mbW)
  var nzTDc = newSeq[bool](mbW)
  for mbY in 0 ..< mbH:
    when S is WriteSink:
      sink.enc = addr parts[][mbY and (parts[].len - 1)]
    var nzLY: array[4, bool]
    var nzLU, nzLV: array[2, bool]
    var nzLDc = false
    for mbX in 0 ..< mbW:
      let mb = unsafeAddr mbs[mbY * mbW + mbX]
      if useSkip and mb.skip:
        for k in 0 .. 3:
          nzTY[mbX][k] = false
          nzLY[k] = false
        for k in 0 .. 1:
          nzTU[mbX][k] = false
          nzTV[mbX][k] = false
          nzLU[k] = false
          nzLV[k] = false
        if not mb.i4:
          nzTDc[mbX] = false
          nzLDc = false
        continue
      var first = 0
      var typ = 3
      if not mb.i4:
        emitCoeffs(sink, 1, ord(nzTDc[mbX]) + ord(nzLDc), mb.lv[24], 0, int(mb.last[24]))
        nzTDc[mbX] = mb.last[24] >= 0
        nzLDc = mb.last[24] >= 0
        first = 1
        typ = 0
      for n in 0 .. 15:
        let x = n and 3
        let y = n shr 2
        emitCoeffs(sink, typ, ord(nzTY[mbX][x]) + ord(nzLY[y]), mb.lv[n], first, int(mb.last[n]))
        nzTY[mbX][x] = mb.last[n] >= 0
        nzLY[y] = mb.last[n] >= 0
      for n in 0 .. 3:
        let x = n and 1
        let y = n shr 1
        emitCoeffs(sink, 2, ord(nzTU[mbX][x]) + ord(nzLU[y]), mb.lv[16 + n], 0, int(mb.last[16 + n]))
        nzTU[mbX][x] = mb.last[16 + n] >= 0
        nzLU[y] = mb.last[16 + n] >= 0
      for n in 0 .. 3:
        let x = n and 1
        let y = n shr 1
        emitCoeffs(sink, 2, ord(nzTV[mbX][x]) + ord(nzLV[y]), mb.lv[20 + n], 0, int(mb.last[20 + n]))
        nzTV[mbX][x] = mb.last[20 + n] >= 0
        nzLV[y] = mb.last[20 + n] >= 0

proc vp8Bitstream(px: openArray[uint32]; w, h, quality: int; opaqueOnly: bool): string =
  ## A whole VP8 key frame (the payload of a VP8 chunk) of the picture.
  let mbW = (w + 15) shr 4
  let mbH = (h + 15) shr 4
  let yStride = mbW * 16
  let uvStride = mbW * 8
  var srcY, srcU, srcV: seq[uint8]
  toYuv(px, w, h, srcY, srcU, srcV, yStride, uvStride, mbH * 16)
  if not opaqueOnly:
    # 8x8 blocks wholly transparent: flat (the value of the last such block,
    # or their own mean), so they cost next to nothing
    var lastY, lastU, lastV = -1
    for by in 0 ..< mbH * 2:
      for bx in 0 ..< mbW * 2:
        var clear = true
        for yy in by * 8 ..< min(h, by * 8 + 8):
          for xx in bx * 8 ..< min(w, bx * 8 + 8):
            if (px[yy * w + xx] shr 24) != 0:
              clear = false
              break
          if not clear: break
        if not clear:
          lastY = -1
          continue
        if lastY < 0:
          var sy, su, sv = 0
          for yy in 0 ..< 8:
            for xx in 0 ..< 8: sy += int(srcY[(by * 8 + yy) * yStride + bx * 8 + xx])
          for yy in 0 ..< 4:
            for xx in 0 ..< 4:
              su += int(srcU[(by * 4 + yy) * uvStride + bx * 4 + xx])
              sv += int(srcV[(by * 4 + yy) * uvStride + bx * 4 + xx])
          lastY = (sy + 32) shr 6
          lastU = (su + 8) shr 4
          lastV = (sv + 8) shr 4
        for yy in 0 ..< 8:
          for xx in 0 ..< 8: srcY[(by * 8 + yy) * yStride + bx * 8 + xx] = uint8(lastY)
        for yy in 0 ..< 4:
          for xx in 0 ..< 4:
            srcU[(by * 4 + yy) * uvStride + bx * 4 + xx] = uint8(lastU)
            srcV[(by * 4 + yy) * uvStride + bx * 4 + xx] = uint8(lastV)
  # the quantizers, as libwebp maps the quality
  let qf = clamp(quality, 0, 100).float / 100.0
  let linear = if qf < 0.75: qf * (2.0 / 3.0) else: 2.0 * qf - 1.0
  let q = clamp(int(127.0 * (1.0 - pow(linear, 1.0 / 3.0))), 0, 127)
  let dqUvDc = -2
  let y1 = makeQMat(int(dcTable[q]), int(acTable[q]), 96, 110, true)
  let y2 = makeQMat(int(dcTable[q]) * 2, max(8, (int(acTable[q]) * 101581) shr 16), 96, 108, false)
  let uvq = makeQMat(int(dcTable[clamp(q + dqUvDc, 0, 117)]), int(acTable[q]), 110, 115, false)
  proc avgQ(m: QMat): int = (m.q[0] + 15 * m.q[1] + 8) shr 4
  let qI4 = avgQ(y1)
  let qI16 = avgQ(y2)
  let qUv = avgQ(uvq)
  # (the scores in 64 bits: a cost times a lambda passes 2^31 where int has 32)
  let lambdaI4 = int64(max(1, (3 * qI4 * qI4) shr 7))
  let lambdaI16 = int64(max(1, 3 * qI16 * qI16))
  let lambdaUv = int64(max(1, (3 * qUv * qUv) shr 6))
  let lambdaMode = int64(max(1, (qI4 * qI4) shr 7))
  var probas: array[1056, uint8]
  for i in 0 ..< 1056: probas[i] = coeffsProba0[i]
  var cs = CostSink(probas: cast[ptr UncheckedArray[uint8]](addr probas[0]))
  # the work blocks: reconstruction (with the decoder's borders) and source
  var work: array[Bps * 17 + Bps * 9, uint8]
  var srcBlk: array[Bps * 17 + Bps * 9, uint8]
  var best16: array[Bps * 17 + Bps * 9, uint8]
  let p = cast[Work](addr work[0])
  let s = cast[Work](addr srcBlk[0])
  let b16 = cast[Work](addr best16[0])
  var topY = newSeq[uint8](mbW * 16)
  var topU = newSeq[uint8](mbW * 8)
  var topV = newSeq[uint8](mbW * 8)
  var reconY = newSeq[uint8](yStride * mbH * 16)
  var mbs = newSeq[EncMB](mbW * mbH)
  var inner = newSeq[bool](mbW * mbH)
  var intraT = newSeq[uint8](4 * mbW)
  var nzTY = newSeq[array[4, bool]](mbW)
  var nzTU = newSeq[array[2, bool]](mbW)
  var nzTV = newSeq[array[2, bool]](mbW)
  var nzTDc = newSeq[bool](mbW)
  for mbY in 0 ..< mbH:
    var intraL: array[4, uint8]
    var nzLY: array[4, bool]
    var nzLU, nzLV: array[2, bool]
    var nzLDc = false
    for j in 0 ..< 16: p[YOff + j * Bps - 1] = 129
    for j in 0 ..< 8:
      p[UOff + j * Bps - 1] = 129
      p[VOff + j * Bps - 1] = 129
    if mbY > 0:
      p[YOff - Bps - 1] = 129
      p[UOff - Bps - 1] = 129
      p[VOff - Bps - 1] = 129
    else:
      for k in 0 ..< 21: p[YOff - Bps - 1 + k] = 127
      for k in 0 ..< 9:
        p[UOff - Bps - 1 + k] = 127
        p[VOff - Bps - 1 + k] = 127
    for mbX in 0 ..< mbW:
      let mb = addr mbs[mbY * mbW + mbX]
      # the borders, as the decoder has them
      if mbX > 0:
        for j in -1 ..< 16:
          for k in 0 .. 3: p[YOff + j * Bps - 4 + k] = p[YOff + j * Bps + 12 + k]
        for j in -1 ..< 8:
          for k in 0 .. 3:
            p[UOff + j * Bps - 4 + k] = p[UOff + j * Bps + 4 + k]
            p[VOff + j * Bps - 4 + k] = p[VOff + j * Bps + 4 + k]
      if mbY > 0:
        copyMem(addr p[YOff - Bps], addr topY[mbX * 16], 16)
        copyMem(addr p[UOff - Bps], addr topU[mbX * 8], 8)
        copyMem(addr p[VOff - Bps], addr topV[mbX * 8], 8)
      let tr = YOff - Bps + 16
      if mbY > 0:
        if mbX >= mbW - 1:
          for k in 0 .. 3: p[tr + k] = topY[mbX * 16 + 15]
        else:
          copyMem(addr p[tr], addr topY[mbX * 16 + 16], 4)
      for r in 1 .. 3:
        for k in 0 .. 3: p[tr + r * 4 * Bps + k] = p[tr + k]
      # the source
      for j in 0 ..< 16:
        copyMem(addr s[YOff + j * Bps], addr srcY[(mbY * 16 + j) * yStride + mbX * 16], 16)
      for j in 0 ..< 8:
        copyMem(addr s[UOff + j * Bps], addr srcU[(mbY * 8 + j) * uvStride + mbX * 8], 8)
        copyMem(addr s[VOff + j * Bps], addr srcV[(mbY * 8 + j) * uvStride + mbX * 8], 8)
      let dcVariant = if mbX == 0: (if mbY == 0: 6 else: 5) else: (if mbY == 0: 4 else: 0)
      # -- 16x16 --
      var best16Score = high(int64)
      var best16R, best16D = 0
      var lv16: array[17, array[16, int16]]   # 16 AC blocks, the Y2 block last
      var last16: array[17, int]
      var bestMode16 = 0
      for mode in 0 .. 3:
        predLuma16(p, YOff, if mode == 0: dcVariant else: mode)
        var blocks: array[16, array[16, int]]
        var dcs: array[16, int]
        for n in 0 .. 15:
          fdct(s, YOff + Scan[n], p, YOff + Scan[n], blocks[n])
          dcs[n] = blocks[n][0]
        var y2c = fwht(dcs)
        var lv: array[17, array[16, int16]]
        var last: array[17, int]
        last[16] = quantizeBlock(y2c, y2, lv[16], 0)
        for n in 0 .. 15:
          blocks[n][0] = 0
          last[n] = quantizeBlock(blocks[n], y1, lv[n], 1)
        var y2d: array[16, int16]
        for i in 0 .. 15: y2d[i] = int16(y2c[i])
        var coeffs: array[256, int16]
        for n in 0 .. 15:
          for j in 1 .. 15: coeffs[n * 16 + j] = int16(blocks[n][j])
        wht(y2d, cast[Coeffs](addr coeffs[0]))
        for n in 0 .. 15: idctAdd(cast[Coeffs](addr coeffs[0]), n * 16, p, YOff + Scan[n])
        let d = sse(s, YOff, p, YOff, 16, 16)
        cs.cost = i16ModeCost(mode)
        emitCoeffs(cs, 1, ord(nzTDc[mbX]) + ord(nzLDc), lv[16], 0, last[16])
        var tnz = nzTY[mbX]
        var lnz = nzLY
        for n in 0 .. 15:
          let x = n and 3
          let y = n shr 2
          emitCoeffs(cs, 0, ord(tnz[x]) + ord(lnz[y]), lv[n], 1, last[n])
          let f = last[n] >= 0
          tnz[x] = f
          lnz[y] = f
        let score = int64(cs.cost) * lambdaI16 + 256 * int64(d)
        if score < best16Score:
          best16Score = score
          best16R = cs.cost
          best16D = d
          bestMode16 = mode
          lv16 = lv
          last16 = last
          copyBlock(p, YOff, b16, YOff, 16, 16)
      # -- 4x4 --
      var i4Score = int64(costOf(0, 145)) * lambdaMode
      let i16Final = int64(best16R) * lambdaMode + 256 * int64(best16D)
      var i4Wins = true
      var modes4: array[16, uint8]
      var lv4: array[16, array[16, int16]]
      var last4: array[16, int]
      block i4:
        var tnz = nzTY[mbX]
        var lnz = nzLY
        for n in 0 .. 15:
          let x = n and 3
          let y = n shr 2
          let d0 = YOff + Scan[n]
          let top = if y == 0: int(intraT[4 * mbX + x]) else: int(modes4[n - 4])
          let left = if x == 0: int(intraL[y]) else: int(modes4[n - 1])
          let ctx = ord(tnz[x]) + ord(lnz[y])
          var bestS = high(int64)
          var bestR, bestD, bestM = 0
          var bestLv: array[16, int16]
          var bestLast = -1
          var bestPix: array[4 * Bps, uint8]
          for mode in 0 .. 9:
            predLuma4(p, d0, mode)
            var blk: array[16, int]
            fdct(s, d0, p, d0, blk)
            var lv: array[16, int16]
            let last = quantizeBlock(blk, y1, lv, 0)
            reconstructAdd(blk, p, d0)
            let d = sse(s, d0, p, d0, 4, 4)
            cs.cost = i4Costs[(top * 10 + left) * 10 + mode]
            emitCoeffs(cs, 3, ctx, lv, 0, last)
            let sc = int64(cs.cost) * lambdaI4 + 256 * int64(d)
            if sc < bestS:
              bestS = sc
              bestR = cs.cost
              bestD = d
              bestM = mode
              bestLv = lv
              bestLast = last
              copyBlock(p, d0, cast[Work](addr bestPix[0]), 0, 4, 4)
          copyBlock(cast[Work](addr bestPix[0]), 0, p, d0, 4, 4)
          modes4[n] = uint8(bestM)
          lv4[n] = bestLv
          last4[n] = bestLast
          let f = bestLast >= 0
          tnz[x] = f
          lnz[y] = f
          i4Score += int64(bestR) * lambdaMode + 256 * int64(bestD)
          if i4Score >= i16Final:
            i4Wins = false
            break i4
      if i4Wins:
        mb.i4 = true
        mb.modes = modes4
        for n in 0 .. 15:
          mb.lv[n] = lv4[n]
          mb.last[n] = int8(last4[n])
          nzTY[mbX][n and 3] = last4[n] >= 0
          nzLY[n shr 2] = last4[n] >= 0
        for x in 0 .. 3: intraT[4 * mbX + x] = modes4[12 + x]
        for y in 0 .. 3: intraL[y] = modes4[y * 4 + 3]
      else:
        mb.i4 = false
        copyBlock(b16, YOff, p, YOff, 16, 16)
        mb.modes[0] = uint8(bestMode16)
        for n in 0 .. 15:
          mb.lv[n] = lv16[n]
          mb.last[n] = int8(last16[n])
          nzTY[mbX][n and 3] = last16[n] >= 0
          nzLY[n shr 2] = last16[n] >= 0
        mb.lv[24] = lv16[16]
        mb.last[24] = int8(last16[16])
        nzTDc[mbX] = last16[16] >= 0
        nzLDc = last16[16] >= 0
        for k in 0 .. 3:
          intraT[4 * mbX + k] = uint8(bestMode16)
          intraL[k] = uint8(bestMode16)
      # -- chroma --
      var bestUv = high(int64)
      var uvBest: array[2 * 8 * Bps, uint8]   # U rows then V rows, Bps apart
      var lvUv: array[8, array[16, int16]]
      var lastUv: array[8, int]
      var modeUv = 0
      for mode in 0 .. 3:
        let pm = if mode == 0: dcVariant else: mode
        predChroma8(p, UOff, pm)
        predChroma8(p, VOff, pm)
        var lv: array[8, array[16, int16]]
        var last: array[8, int]
        var d = 0
        cs.cost = uvModeCost(mode)
        for ch in 0 .. 1:
          let base = if ch == 0: UOff else: VOff
          var tnz = if ch == 0: nzTU[mbX] else: nzTV[mbX]
          var lnz = if ch == 0: nzLU else: nzLV
          for n in 0 .. 3:
            let x = n and 1
            let y = n shr 1
            let d0 = base + y * 4 * Bps + x * 4
            var blk: array[16, int]
            fdct(s, d0, p, d0, blk)
            let k = ch * 4 + n
            last[k] = quantizeBlock(blk, uvq, lv[k], 0)
            reconstructAdd(blk, p, d0)
            emitCoeffs(cs, 2, ord(tnz[x]) + ord(lnz[y]), lv[k], 0, last[k])
            tnz[x] = last[k] >= 0
            lnz[y] = last[k] >= 0
          d += sse(s, base, p, base, 8, 8)
        let sc = int64(cs.cost) * lambdaUv + 256 * int64(d)
        if sc < bestUv:
          bestUv = sc
          modeUv = mode
          lvUv = lv
          lastUv = last
          copyBlock(p, UOff, cast[Work](addr uvBest[0]), 0, 8, 8)
          copyBlock(p, VOff, cast[Work](addr uvBest[0]), 8 * Bps, 8, 8)
      copyBlock(cast[Work](addr uvBest[0]), 0, p, UOff, 8, 8)
      copyBlock(cast[Work](addr uvBest[0]), 8 * Bps, p, VOff, 8, 8)
      mb.uvmode = uint8(modeUv)
      for k in 0 .. 7:
        mb.lv[16 + k] = lvUv[k]
        mb.last[16 + k] = int8(lastUv[k])
      for n in 0 .. 3:
        nzTU[mbX][n and 1] = lastUv[n] >= 0
        nzLU[n shr 1] = lastUv[n] >= 0
        nzTV[mbX][n and 1] = lastUv[4 + n] >= 0
        nzLV[n shr 1] = lastUv[4 + n] >= 0
      var any = false
      for k in 0 .. 23:
        if mb.last[k] >= 0: any = true
      if not mb.i4 and mb.last[24] >= 0: any = true
      mb.skip = not any
      inner[mbY * mbW + mbX] = mb.i4 or any
      # keep the reconstruction
      if mbY < mbH - 1:
        copyMem(addr topY[mbX * 16], addr p[YOff + 15 * Bps], 16)
        copyMem(addr topU[mbX * 8], addr p[UOff + 7 * Bps], 8)
        copyMem(addr topV[mbX * 8], addr p[VOff + 7 * Bps], 8)
      for j in 0 ..< 16:
        copyMem(addr reconY[(mbY * 16 + j) * yStride + mbX * 16], addr p[YOff + j * Bps], 16)
  # the loop filter's level: the one leaving the luma nearest the source
  var rows: seq[int]
  let stepRows = max(1, mbH div 24)
  var r0 = 0
  while r0 < mbH:
    rows.add r0
    r0 += stepRows
  proc lumaErr(level: int): int =
    let f = filterLuma(reconY, yStride, mbW, mbH, inner, level, rows)
    for mbY in rows:
      for yy in mbY * 16 ..< min(h, mbY * 16 + 16):
        for xx in 0 ..< w:
          let d = int(f[yy * yStride + xx]) - int(srcY[yy * yStride + xx])
          result += d * d
  var level = 0
  var bestErr = lumaErr(0)
  for cand in [8, 16, 24, 32, 40, 48, 63]:
    let e = lumaErr(cand)
    if e < bestErr:
      bestErr = e
      level = cand
  for stepL in [4, 2, 1]:
    for cand in [level - stepL, level + stepL]:
      if cand >= 1 and cand <= 63:
        let e = lumaErr(cand)
        if e < bestErr:
          bestErr = e
          level = cand
  # skipping all-zero macroblocks, and the probabilities fitted to the tokens
  var nbSkip = 0
  for mb in mbs:
    if mb.skip: inc nbSkip
  let total = mbs.len
  let skipP = (total - nbSkip) * 255 div total
  let useSkip = skipP < 250
  var stats: array[1056, array[2, int]]
  var ss = StatSink(stats: addr stats)
  emitTokens(ss, mbs, mbW, mbH, useSkip, nil)
  var update: array[1056, bool]
  for i in 0 ..< 1056:
    let nb = stats[i][0]
    let all = stats[i][1]
    let old = int(coeffsProba0[i])
    let newP = if nb > 0: 255 - nb * 255 div all else: 255
    let upd = int(coeffsUpdateProba[i])
    let oldCost = nb * costOf(1, old) + (all - nb) * costOf(0, old) + costOf(0, upd)
    let newCost = nb * costOf(1, newP) + (all - nb) * costOf(0, newP) + costOf(1, upd) + 8 * 256
    if all > 0 and oldCost > newCost:
      probas[i] = uint8(newP)
      update[i] = true
  # partition 0: the header, then each macroblock's modes
  var e0 = initBoolEnc()
  e0.putBit(0, 128)                       # color space
  e0.putBit(0, 128)                       # clamping
  e0.putBit(0, 128)                       # no segments
  e0.putBit(0, 128)                       # the normal loop filter
  e0.putBits(level, 6)
  e0.putBits(0, 3)                        # sharpness
  e0.putBit(0, 128)                       # no filter deltas
  let numParts = if mbW * mbH > 16384: 8 else: 1
  e0.putBits(fastLog2(numParts), 2)
  e0.putBits(q, 7)
  e0.putSignedBits(0, 4)
  e0.putSignedBits(0, 4)
  e0.putSignedBits(0, 4)
  e0.putSignedBits(dqUvDc, 4)
  e0.putSignedBits(0, 4)
  e0.putBit(0, 128)                       # (refresh entropy probs)
  for i in 0 ..< 1056:
    e0.putBit(ord(update[i]), int(coeffsUpdateProba[i]))
    if update[i]: e0.putBits(int(probas[i]), 8)
  e0.putBit(ord(useSkip), 128)
  if useSkip: e0.putBits(skipP, 8)
  for x in 0 ..< intraT.len: intraT[x] = 0
  for mbY in 0 ..< mbH:
    var intraL: array[4, uint8]
    for mbX in 0 ..< mbW:
      let mb = addr mbs[mbY * mbW + mbX]
      if useSkip: e0.putBit(ord(mb.skip), skipP)
      e0.putBit(ord(not mb.i4), 145)
      if not mb.i4:
        let m = int(mb.modes[0])
        if m == 1 or m == 3:
          e0.putBit(1, 156)
          e0.putBit(ord(m == 1), 128)
        else:
          e0.putBit(0, 156)
          e0.putBit(ord(m == 2), 163)
        for k in 0 .. 3:
          intraT[4 * mbX + k] = uint8(m)
          intraL[k] = uint8(m)
      else:
        for y in 0 .. 3:
          var left = int(intraL[y])
          for x in 0 .. 3:
            let mode = int(mb.modes[y * 4 + x])
            let pb = (int(intraT[4 * mbX + x]) * 10 + left) * 9
            template pr(k: int): int = int(bModesProba[pb + k])
            if e0.putBitR(ord(mode != 0), pr(0)):
              if e0.putBitR(ord(mode != 1), pr(1)):
                if e0.putBitR(ord(mode != 2), pr(2)):
                  if not e0.putBitR(ord(mode >= 6), pr(3)):
                    if e0.putBitR(ord(mode != 3), pr(4)): e0.putBit(ord(mode != 4), pr(5))
                  else:
                    if e0.putBitR(ord(mode != 6), pr(6)):
                      if e0.putBitR(ord(mode != 7), pr(7)): e0.putBit(ord(mode != 8), pr(8))
            intraT[4 * mbX + x] = uint8(mode)
            left = mode
          intraL[y] = uint8(left)
      let um = int(mb.uvmode)
      if e0.putBitR(ord(um != 0), 142):
        if e0.putBitR(ord(um != 2), 114): e0.putBit(ord(um != 3), 183)
  let part0 = e0.finish()
  if part0.len >= (1 shl 19): raise newException(WebpError, "picture too large for lossy WebP")
  # the tokens
  var parts = newSeq[BoolEnc](numParts)
  for k in 0 ..< numParts: parts[k] = initBoolEnc()
  var ws = WriteSink(probas: cast[ptr UncheckedArray[uint8]](addr probas[0]))
  emitTokens(ws, mbs, mbW, mbH, useSkip, addr parts)
  var tokens: seq[string]
  for k in 0 ..< numParts: tokens.add parts[k].finish()
  # the frame
  let bits = 0 or (0 shl 1) or (1 shl 4) or (part0.len shl 5)
  result = newStringOfCap(10 + part0.len + 3 * numParts + tokens[0].len)
  result.add char(bits and 255)
  result.add char((bits shr 8) and 255)
  result.add char((bits shr 16) and 255)
  result.add "\x9d\x01\x2a"
  result.add char(w and 255)
  result.add char((w shr 8) and 0x3F)
  result.add char(h and 255)
  result.add char((h shr 8) and 0x3F)
  result.add part0
  for k in 0 ..< numParts - 1:
    let n = tokens[k].len
    if n >= (1 shl 24): raise newException(WebpError, "picture too large for lossy WebP")
    result.add char(n and 255)
    result.add char((n shr 8) and 255)
    result.add char((n shr 16) and 255)
  for t in tokens: result.add t

{.pop.}

proc alphaChunk(px: openArray[uint32]; w, h: int): string =
  ## The ALPH payload of the picture's alpha: lossless (VP8L, the alpha in
  ## green), with whichever of the four filters makes it smallest.
  var a = newSeq[int](w * h)
  for i in 0 ..< w * h: a[i] = int(px[i] shr 24)
  proc filtered(a: seq[int]; w, h, f: int): seq[uint32] =
    result = newSeq[uint32](w * h)
    for y in 0 ..< h:
      for x in 0 ..< w:
        let i = y * w + x
        let pred =
          if f == 0: 0
          elif y == 0: (if x == 0: 0 else: a[i - 1])
          elif x == 0: a[i - w]
          elif f == 1: a[i - 1]
          elif f == 2: a[i - w]
          else: clamp(a[i - 1] + a[i - w] - a[i - w - 1], 0, 255)
        result[i] = 0xFF000000'u32 or (uint32((a[i] - pred) and 255) shl 8)
  var best = ""
  for f in 0 .. 3:
    var bw: BitWriter
    writeVp8lStream(bw, filtered(a, w, h, f), w, h)
    let body = char(1 or (f shl 2)) & bw.finish()
    if best.len == 0 or body.len < best.len: best = body
  best

proc le24s(v: int): string = char(v and 255) & char((v shr 8) and 255) & char((v shr 16) and 255)

proc vp8xChunk(flags, w, h: int): string =
  chunk("VP8X", char(flags) & "\0\0\0" & le24s(w - 1) & le24s(h - 1))

proc hasAlpha(px: openArray[uint32]): bool =
  for p in px:
    if p < 0xFF000000'u32: return true

proc frameChunks(px: seq[uint32]; w, h: int; lossless: bool; quality: int): string =
  ## The chunks of one picture: VP8L, or VP8 with ALPH before it when it has
  ## transparency.
  if lossless: return chunk("VP8L", vp8lBitstream(px, w, h))
  let alpha = hasAlpha(px)
  if alpha: result = chunk("ALPH", alphaChunk(px, w, h))
  result.add chunk("VP8 ", vp8Bitstream(px, w, h, quality, not alpha))

proc checkSize(w, h: int) =
  if w <= 0 or h <= 0 or w > 16383 or h > 16383:
    raise newException(ValueError, "a WebP picture is 1 to 16383 pixels a side")

proc encodeWebp*(b: Bitmap; quality = 80): string =
  ## `b` as a lossy WebP file (VP8), `quality` 0..100 as libwebp and Pillow
  ## read it (the quantizer libwebp would choose for it, though without its
  ## segments); transparency is kept, losslessly, in an ALPH chunk.
  ## ValueError when a side is not 1 to 16383.
  checkSize(b.w, b.h)
  if hasAlpha(b.px):
    riff(vp8xChunk(0x10, b.w, b.h) & frameChunks(b.px, b.w, b.h, false, quality))
  else:
    riff(chunk("VP8 ", vp8Bitstream(b.px, b.w, b.h, quality, true)))

proc encodeWebpFrames*(frames: openArray[tuple[bmp: Bitmap; delayMs: int]]; loop = 0;
                       lossless = false; quality = 80): string =
  ## An animation (ANIM / ANMF): each frame a whole picture of the size of
  ## the first, shown `delayMs`; `loop` times round (0: for ever). Each frame
  ## stores only the rectangle that changed since the one before (replacing
  ## what was there, no blending); unchanged frames lengthen the one before.
  if frames.len == 0: raise newException(ValueError, "an animation needs a frame")
  let w = frames[0].bmp.w
  let h = frames[0].bmp.h
  checkSize(w, h)
  for f in frames:
    if f.bmp.w != w or f.bmp.h != h:
      raise newException(ValueError, "the frames of an animation have one size")
  type Piece = tuple[x, y, w, h, ms: int; px: seq[uint32]]
  var pieces: seq[Piece]
  var anyAlpha = false
  for k, f in frames:
    let px = f.bmp.px
    anyAlpha = anyAlpha or hasAlpha(px)
    var x0 = 0
    var y0 = 0
    var x1 = w
    var y1 = h
    if k > 0:
      let prev = frames[k - 1].bmp.px
      x0 = w
      y0 = h
      x1 = 0
      y1 = 0
      for y in 0 ..< h:
        for x in 0 ..< w:
          if px[y * w + x] != prev[y * w + x]:
            x0 = min(x0, x)
            y0 = min(y0, y)
            x1 = max(x1, x + 1)
            y1 = max(y1, y + 1)
      if x1 == 0:                          # the same as before
        pieces[^1].ms += max(0, f.delayMs)
        continue
      x0 = x0 and not 1
      y0 = y0 and not 1
    var sub = newSeq[uint32]((x1 - x0) * (y1 - y0))
    for y in y0 ..< y1:
      for x in x0 ..< x1: sub[(y - y0) * (x1 - x0) + (x - x0)] = px[y * w + x]
    pieces.add (x0, y0, x1 - x0, y1 - y0, max(0, f.delayMs), sub)
  var body = vp8xChunk(0x02 or (if anyAlpha: 0x10 else: 0), w, h)
  let loops = clamp(loop, 0, 65535)
  body.add chunk("ANIM", "\0\0\0\0" & char(loops and 255) & char((loops shr 8) and 255))
  for pc in pieces:
    let head = le24s(pc.x div 2) & le24s(pc.y div 2) & le24s(pc.w - 1) & le24s(pc.h - 1) &
               le24s(min(pc.ms, 0xFFFFFF)) & "\x02"       # no blending, not disposed of
    body.add chunk("ANMF", head & frameChunks(pc.px, pc.w, pc.h, lossless, quality))
  riff(body)
