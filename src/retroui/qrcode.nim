## QR codes made here, nothing to install: any text (UTF-8) to the dark and
## light modules of a QR code (ISO/IEC 18004, versions 1 to 40, error
## correction L, M, Q, H), drawn as a picture or as outlines for a vector
## shape layer.
##
## ```nim
## let q = qrEncode("WIFI:T:WPA;S:Hotel;P:secret;;", qrQ)
## echo q.version, " ", q.size, " x ", q.size, " mask ", q.mask
## let b = qrBitmap(q, scale = 8)                  # 4 modules of quiet zone around it
## for poly in qrPath(q): discard poly             # closed outlines, in modules
## ```
##
## The text is written in one segment: numeric when it is all digits,
## alphanumeric when it is all `0-9 A-Z space $ % * + - . / :`, else bytes
## (its UTF-8, without an ECI header: what phones read). The smallest
## version that holds it (from `minVersion`; `qrFits` tells) is taken, and
## the mask with the lowest penalty (ISO 18004:2015 7.8.3, judged before
## the format information is written, as segno judges it) unless one is
## given. The modules equal segno's and python-qrcode's for the same
## version and mask.

import std/[math, strutils]
import gfx

type
  QrEcc* = enum
    ## How much of the code may be lost and still read: about 7 %, 15 %,
    ## 25 %, 30 %.
    qrL, qrM, qrQ, qrH
  QrMode* = enum
    ## How the text is written.
    qmNumeric, qmAlphanumeric, qmByte
  QrCode* = object
    ## A QR code: `size` x `size` modules, `q[x, y]` dark or light.
    version*: int          ## 1..40
    ecc*: QrEcc            ## how much of it can be damaged and still read
    mask*: int             ## 0..7
    mode*: QrMode          ## how its text is written
    size*: int             ## modules a side: 17 + 4 * version
    dark: seq[bool]

const
  # error correction codewords per block, and blocks, by level and version (index 0 unused)
  eccPerBlock: array[QrEcc, array[41, int8]] = [
    [-1'i8, 7, 10, 15, 20, 26, 18, 20, 24, 30, 18, 20, 24, 26, 30, 22, 24, 28, 30, 28, 28,
     28, 28, 30, 30, 26, 28, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30],
    [-1'i8, 10, 16, 26, 18, 24, 16, 18, 22, 22, 26, 30, 22, 22, 24, 24, 28, 28, 26, 26, 26,
     26, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28],
    [-1'i8, 13, 22, 18, 26, 18, 24, 18, 22, 20, 24, 28, 26, 24, 20, 30, 24, 28, 28, 26, 30,
     28, 30, 30, 30, 30, 28, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30],
    [-1'i8, 17, 28, 22, 16, 22, 28, 26, 26, 24, 28, 24, 28, 22, 24, 24, 30, 28, 28, 26, 28,
     30, 24, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30]]
  eccBlocks: array[QrEcc, array[41, int8]] = [
    [-1'i8, 1, 1, 1, 1, 1, 2, 2, 2, 2, 4, 4, 4, 4, 4, 6, 6, 6, 6, 7, 8,
     8, 9, 9, 10, 12, 12, 12, 13, 14, 15, 16, 17, 18, 19, 19, 20, 21, 22, 24, 25],
    [-1'i8, 1, 1, 1, 2, 2, 4, 4, 4, 5, 5, 5, 8, 9, 9, 10, 10, 11, 13, 14, 16,
     17, 17, 18, 20, 21, 23, 25, 26, 28, 29, 31, 33, 35, 37, 38, 40, 43, 45, 47, 49],
    [-1'i8, 1, 1, 2, 2, 4, 4, 6, 6, 8, 8, 8, 10, 12, 16, 12, 17, 16, 18, 21, 20,
     23, 23, 25, 27, 29, 34, 34, 35, 38, 40, 43, 45, 48, 51, 53, 56, 59, 62, 65, 68],
    [-1'i8, 1, 1, 2, 4, 4, 4, 5, 6, 8, 8, 11, 11, 16, 16, 18, 16, 19, 21, 25, 25,
     25, 34, 30, 32, 35, 37, 40, 42, 45, 48, 51, 54, 57, 60, 63, 66, 70, 74, 77, 81]]
  eccFormatBits: array[QrEcc, int] = [1, 0, 3, 2]
  alnumChars = "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ $%*+-./:"

proc `[]`*(q: QrCode; x, y: int): bool {.inline.} =
  ## The module in column `x`, row `y` is dark (outside the code: light).
  x >= 0 and y >= 0 and x < q.size and y < q.size and q.dark[y * q.size + x]

# ---- the bits ------------------------------------------------------------------------------------

type Bits = object
  b: seq[bool]

proc add(s: var Bits; v, n: int) =
  for i in countdown(n - 1, 0): s.b.add ((v shr i) and 1) != 0

proc rawModules(ver: int): int =
  ## Modules left for data and error correction (with the remainder bits).
  result = (16 * ver + 128) * ver + 64
  if ver >= 2:
    let na = ver div 7 + 2
    result -= (25 * na - 10) * na - 55
    if ver >= 7: result -= 36

proc dataCodewords(ver: int; ecc: QrEcc): int =
  rawModules(ver) div 8 - int(eccPerBlock[ecc][ver]) * int(eccBlocks[ecc][ver])

proc countBits(mode: QrMode; ver: int): int =
  let k = if ver <= 9: 0 elif ver <= 26: 1 else: 2
  case mode
  of qmNumeric: [10, 12, 14][k]
  of qmAlphanumeric: [9, 11, 13][k]
  of qmByte: [8, 16, 16][k]

proc modeOf(text: string): QrMode =
  if text.len == 0: return qmByte
  var num, alnum = true
  for c in text:
    if c notin {'0'..'9'}: num = false
    if alnumChars.find(c) < 0: alnum = false
  if num: qmNumeric elif alnum: qmAlphanumeric else: qmByte

proc dataBits(text: string; mode: QrMode): Bits =
  case mode
  of qmNumeric:
    var i = 0
    while i < text.len:
      let n = min(3, text.len - i)
      var v = 0
      for k in 0 ..< n: v = v * 10 + (ord(text[i + k]) - ord('0'))
      result.add v, n * 3 + 1
      i += n
  of qmAlphanumeric:
    var i = 0
    while i + 1 < text.len:
      result.add alnumChars.find(text[i]) * 45 + alnumChars.find(text[i + 1]), 11
      i += 2
    if i < text.len: result.add alnumChars.find(text[i]), 6
  of qmByte:
    for c in text: result.add ord(c), 8

# ---- Reed-Solomon over GF(256), x^8 + x^4 + x^3 + x^2 + 1 --------------------------------------------

proc gfMul(x, y: int): int =
  var z = 0
  for i in countdown(7, 0):
    z = (z shl 1) xor ((z shr 7) * 0x11D)
    z = z xor (((y shr i) and 1) * x)
  z

proc rsDivisor(degree: int): seq[int] =
  result = newSeq[int](degree)
  result[degree - 1] = 1
  var root = 1
  for i in 0 ..< degree:
    for j in 0 ..< degree:
      result[j] = gfMul(result[j], root)
      if j + 1 < degree: result[j] = result[j] xor result[j + 1]
    root = gfMul(root, 2)

proc rsRemainder(data: openArray[int]; divisor: seq[int]): seq[int] =
  result = newSeq[int](divisor.len)
  for b in data:
    let factor = b xor result[0]
    for i in 0 ..< result.len - 1: result[i] = result[i + 1]
    result[^1] = 0
    for i in 0 ..< result.len: result[i] = result[i] xor gfMul(divisor[i], factor)

proc interleaved(data: seq[int]; ver: int; ecc: QrEcc): seq[int] =
  ## The data codewords in their blocks, each with its error correction,
  ## then interleaved.
  let nb = int(eccBlocks[ecc][ver])
  let el = int(eccPerBlock[ecc][ver])
  let raw = rawModules(ver) div 8
  let numShort = nb - raw mod nb
  let shortLen = raw div nb
  let divisor = rsDivisor(el)
  var blocks: seq[seq[int]]
  var k = 0
  for i in 0 ..< nb:
    let dl = shortLen - el + (if i < numShort: 0 else: 1)
    var blk = data[k ..< k + dl]
    k += dl
    let e = rsRemainder(blk, divisor)
    if i < numShort: blk.add 0                 # (a place kept, skipped below)
    blk.add e
    blocks.add blk
  for i in 0 ..< blocks[0].len:
    for j in 0 ..< nb:
      if i != shortLen - el or j >= numShort: result.add blocks[j][i]

# ---- the symbol -------------------------------------------------------------------------------------

type Grid = object
  n: int
  m, fn: seq[bool]           # dark; part of a function pattern

proc put(g: var Grid; x, y: int; dark: bool) =
  g.m[y * g.n + x] = dark
  g.fn[y * g.n + x] = true

proc alignPositions(ver: int; size: int): seq[int] =
  if ver == 1: return
  let na = ver div 7 + 2
  let step = (ver * 8 + na * 3 + 5) div (na * 4 - 4) * 2
  result = newSeq[int](na)
  result[0] = 6
  var pos = size - 7
  for i in countdown(na - 1, 1):
    result[i] = pos
    pos -= step

proc formatBits(ecc: QrEcc; mask: int): int =
  let data = eccFormatBits[ecc] shl 3 or mask
  var rem = data
  for i in 0 ..< 10: rem = (rem shl 1) xor ((rem shr 9) * 0x537)
  (data shl 10 or rem) xor 0x5412

proc drawFormat(g: var Grid; bits: int) =
  ## The format information (-1: its places, light).
  template bit(i: int): bool = bits >= 0 and ((bits shr i) and 1) != 0
  for i in 0 .. 5: g.put(8, i, bit(i))
  g.put(8, 7, bit(6))
  g.put(8, 8, bit(7))
  g.put(7, 8, bit(8))
  for i in 9 .. 14: g.put(14 - i, 8, bit(i))
  for i in 0 .. 7: g.put(g.n - 1 - i, 8, bit(i))
  for i in 8 .. 14: g.put(8, g.n - 15 + i, bit(i))
  g.put(8, g.n - 8, bits >= 0)                 # the dark module (light while masks are judged)

proc drawVersion(g: var Grid; ver: int; blank: bool) =
  if ver < 7: return
  var rem = ver
  for i in 0 ..< 12: rem = (rem shl 1) xor ((rem shr 11) * 0x1F25)
  let bits = ver shl 12 or rem
  for i in 0 ..< 18:
    let b = not blank and ((bits shr i) and 1) != 0
    let a = g.n - 11 + i mod 3
    g.put(a, i div 3, b)
    g.put(i div 3, a, b)

proc functionPatterns(ver: int): Grid =
  let n = 17 + 4 * ver
  result = Grid(n: n, m: newSeq[bool](n * n), fn: newSeq[bool](n * n))
  for i in 0 ..< n:
    result.put(6, i, i mod 2 == 0)
    result.put(i, 6, i mod 2 == 0)
  for (cx, cy) in [(3, 3), (n - 4, 3), (3, n - 4)]:
    for dy in -4 .. 4:
      for dx in -4 .. 4:
        let x = cx + dx
        let y = cy + dy
        if x >= 0 and x < n and y >= 0 and y < n:
          let d = max(abs(dx), abs(dy))
          result.put(x, y, d != 2 and d != 4)
  let ap = alignPositions(ver, n)
  for i in 0 ..< ap.len:
    for j in 0 ..< ap.len:
      if (i == 0 and j == 0) or (i == 0 and j == ap.high) or (i == ap.high and j == 0): continue
      for dy in -2 .. 2:
        for dx in -2 .. 2:
          result.put(ap[i] + dx, ap[j] + dy, max(abs(dx), abs(dy)) != 1)
  # the format and version areas, and the dark module: light while the masks are judged
  result.drawFormat(-1)
  result.drawVersion(ver, blank = true)

proc placeCodewords(g: var Grid; cw: seq[int]) =
  let n = g.n
  var i = 0
  let total = cw.len * 8
  var right = n - 1
  while right >= 1:
    if right == 6: right = 5
    for vert in 0 ..< n:
      for j in 0 .. 1:
        let x = right - j
        let upward = ((right + 1) and 2) == 0
        let y = if upward: n - 1 - vert else: vert
        if not g.fn[y * n + x]:
          if i < total:
            g.m[y * n + x] = ((cw[i shr 3] shr (7 - (i and 7))) and 1) != 0
            inc i
          else: g.m[y * n + x] = false    # remainder bits
    right -= 2

proc maskBit(mask, x, y: int): bool {.inline.} =
  case mask
  of 0: (x + y) mod 2 == 0
  of 1: y mod 2 == 0
  of 2: x mod 3 == 0
  of 3: (x + y) mod 3 == 0
  of 4: (x div 3 + y div 2) mod 2 == 0
  of 5: x * y mod 2 + x * y mod 3 == 0
  of 6: (x * y mod 2 + x * y mod 3) mod 2 == 0
  else: ((x + y) mod 2 + x * y mod 3) mod 2 == 0

proc applyMask(g: var Grid; mask: int) =
  for y in 0 ..< g.n:
    for x in 0 ..< g.n:
      let i = y * g.n + x
      if not g.fn[i] and maskBit(mask, x, y): g.m[i] = not g.m[i]

proc findPattern(line: openArray[bool]; start: int): int =
  const pat = [true, false, true, true, true, false, true]
  var i = max(0, start)
  while i + 7 <= line.len:
    var ok = true
    for k in 0 ..< 7:
      if line[i + k] != pat[k]:
        ok = false
        break
    if ok: return i
    inc i
  -1

proc lightRange(line: openArray[bool]; a, b: int): bool =
  for k in max(a, 0) ..< min(b, line.len):
    if line[k]: return false
  true

proc n3Score(line: openArray[bool]): int =
  ## Finder-like 1:1:3:1:1 runs with 4 light modules before or after (or
  ## the symbol's edge), the way segno counts them.
  let n = line.len
  var idx = findPattern(line, 0)
  while idx != -1:
    var offset = idx + 7
    if idx == 0 or idx == n - 7 or lightRange(line, idx - 4, idx) or
       lightRange(line, offset, offset + 4):
      result += 40
    else:
      offset = idx + 4
    idx = findPattern(line, offset)

proc penalty(g: Grid): int =
  let n = g.n
  var dark = 0
  var col = newSeq[bool](n)
  var row = newSeq[bool](n)
  for i in 0 ..< n:
    var rowRun, colRun = 0
    for j in 0 ..< n:
      let r = g.m[i * n + j]
      let c = g.m[j * n + i]
      row[j] = r
      col[j] = c
      if r: inc dark
      if j > 0 and r == g.m[i * n + j - 1]: inc rowRun
      else:
        if rowRun >= 5: result += rowRun - 2
        rowRun = 1
      if j > 0 and c == g.m[(j - 1) * n + i]: inc colRun
      else:
        if colRun >= 5: result += colRun - 2
        colRun = 1
      if i > 0 and j > 0 and r == g.m[i * n + j - 1] and r == g.m[(i - 1) * n + j] and
         r == g.m[(i - 1) * n + j - 1]:
        result += 3
    if rowRun >= 5: result += rowRun - 2
    if colRun >= 5: result += colRun - 2
    result += n3Score(row) + n3Score(col)
  let percent = float(dark) / float(n * n)
  result += 10 * int(abs(percent * 100 - 50) / 5)

proc qrFits*(text: string; ec = qrM; version: int): bool =
  ## `text` fits in a QR code of `version` at `ec`.
  if version notin 1 .. 40: return false
  let mode = modeOf(text)
  let bits = dataBits(text, mode)
  let cb = countBits(mode, version)
  version in 1 .. 40 and text.len < (1 shl cb) and
    4 + cb + bits.b.len <= dataCodewords(version, ec) * 8

proc qrEncode*(text: string; ec = qrM; minVersion = 1; mask = -1): QrCode =
  ## The QR code of `text` (UTF-8): the smallest version from `minVersion`
  ## that holds it at the error correction `ec`; the best mask, or `mask`
  ## (0..7). Raises `ValueError` when it is too long for version 40 (2953
  ## bytes at L, 2331 at M, 1663 at Q, 1273 at H; more digits).
  if mask notin -1 .. 7: raise newException(ValueError, "QR mask must be -1..7")
  let mode = modeOf(text)
  let payload = dataBits(text, mode)
  var ver = max(1, minVersion)
  while ver <= 40:
    let cb = countBits(mode, ver)
    if text.len < (1 shl cb) and 4 + cb + payload.b.len <= dataCodewords(ver, ec) * 8: break
    inc ver
  if ver > 40: raise newException(ValueError, "the text is too long for a QR code")
  # the bit stream: mode, count, data, terminator, padding
  let capacity = dataCodewords(ver, ec) * 8
  var bs: Bits
  bs.add [1, 2, 4][ord(mode)], 4
  bs.add text.len, countBits(mode, ver)
  bs.b.add payload.b
  bs.add 0, min(4, capacity - bs.b.len)
  bs.add 0, (8 - bs.b.len mod 8) mod 8
  var data: seq[int]
  for i in countup(0, bs.b.len - 1, 8):
    var v = 0
    for k in 0 ..< 8: v = v shl 1 or ord(bs.b[i + k])
    data.add v
  var pad = 0xEC
  while data.len < capacity div 8:
    data.add pad
    pad = pad xor (0xEC xor 0x11)
  var g = functionPatterns(ver)
  g.placeCodewords(interleaved(data, ver, ec))
  var best = mask
  if best < 0:
    var low = high(int)
    for m in 0 .. 7:
      var t = g
      t.applyMask(m)
      let p = t.penalty()
      if p < low:
        low = p
        best = m
  g.applyMask(best)
  g.drawFormat(formatBits(ec, best))
  g.drawVersion(ver, blank = false)
  QrCode(version: ver, ecc: ec, mask: best, mode: mode, size: g.n, dark: g.m)

# ---- pictures and outlines -------------------------------------------------------------------------------

proc qrBitmap*(q: QrCode; scale = 4; border = 4; dark = color(0, 0, 0);
               light = color(255, 255, 255)): Bitmap =
  ## The code as a picture: `scale` pixels a module, `border` modules of
  ## quiet zone (`light`) around it (4 is what the standard asks).
  let s = max(1, scale)
  let bd = max(0, border)
  let side = (q.size + 2 * bd) * s
  template argb(c: Color): uint32 =
    uint32(c.a) shl 24 or uint32(c.r) shl 16 or uint32(c.g) shl 8 or uint32(c.b)
  let dk = argb(dark)
  let lt = argb(light)
  result = newBitmap(side, side, lt)
  result.opaque = dark.a == 255 and light.a == 255
  for y in 0 ..< q.size:
    for x in 0 ..< q.size:
      if q.dark[y * q.size + x]:
        for yy in 0 ..< s:
          let row = ((bd + y) * s + yy) * side + (bd + x) * s
          for xx in 0 ..< s: result.px[row + xx] = dk

proc qrPath*(q: QrCode; scale = 1.0; x = 0.0; y = 0.0): seq[seq[(float, float)]] =
  ## The dark modules as closed outlines (one per region of modules joined
  ## by their sides; a point only where they turn): the outside of each
  ## region clockwise (y down), its holes anticlockwise, so they fill
  ## right with the non-zero and the even-odd rule alike. In modules from
  ## the code's top left corner (no quiet zone), times `scale`, moved by
  ## `x`, `y`.
  let n = q.size
  let w = n + 1                               # corner points a row
  # an edge from each corner point along the side of a dark module, with
  # the dark on its right (y down): up to two leave a point (diagonal touch)
  type Edge = tuple[to, dir: int]             # dir: 0 right, 1 down, 2 left, 3 up
  var outs = newSeq[array[2, int]](w * w)     # edge ids + 1 leaving each point
  var edges: seq[Edge]
  var froms: seq[int]
  proc addEdge(a, b, dir: int) =
    edges.add (b, dir)
    froms.add a
    if outs[a][0] == 0: outs[a][0] = edges.len else: outs[a][1] = edges.len
  for yy in 0 ..< n:
    for xx in 0 ..< n:
      if not q[xx, yy]: continue
      let tl = yy * w + xx
      let tr = tl + 1
      let bl = tl + w
      let br = bl + 1
      if not q[xx, yy - 1]: addEdge(tl, tr, 0)
      if not q[xx + 1, yy]: addEdge(tr, br, 1)
      if not q[xx, yy + 1]: addEdge(br, bl, 2)
      if not q[xx - 1, yy]: addEdge(bl, tl, 3)
  var used = newSeq[bool](edges.len)
  for start in 0 ..< edges.len:
    if used[start]: continue
    var poly: seq[(float, float)]
    var e = start
    var lastDir = -1
    while not used[e]:
      used[e] = true
      let p = froms[e]
      if edges[e].dir != lastDir:
        poly.add (x + float(p mod w) * scale, y + float(p div w) * scale)
        lastDir = edges[e].dir
      # next: of the edges leaving where this one ends, the one turning right
      # (dark on the right: diagonal neighbours stay apart)
      let o = outs[edges[e].to]
      var nxt = o[0] - 1
      if o[1] != 0:
        let a = o[0] - 1
        let b = o[1] - 1
        nxt = if edges[a].dir == (edges[e].dir + 1) mod 4: a else: b
      if nxt < 0: break
      e = nxt
    # the first point may sit in the middle of a straight side
    if poly.len >= 3:
      let a = poly[^1]
      let b = poly[0]
      let c = poly[1]
      if (a[0] == b[0] and b[0] == c[0]) or (a[1] == b[1] and b[1] == c[1]): poly.delete(0)
    if poly.len >= 3: result.add poly

# ==== reading QR codes ===========================================================================
#
# A picture is made black and white against the light round each pixel; the three finder
# patterns (their 1:1:3:1:1 runs, across and down) are found; from them -- and the alignment
# pattern near the fourth corner, when the version has one -- the code's grid is laid over the
# picture in perspective and each module read at its middle; then its format, its codewords
# unmasked and put back into their blocks, each block mended by Reed-Solomon where it can be
# (up to the code's level), and the text read from the data.

type
  QrRead* = object
    ## A QR code read from a picture (`qrRead`).
    text*: string          ## what it says (bytes as they are: UTF-8 in practice)
    version*: int
    ecc*: QrEcc
    corners*: array[4, (float, float)]   ## where it is: top left, top right, bottom right, bottom left
    mended*: int           ## codewords put right by its error correction

# ---- GF(256) for mending -----------------------------------------------------------------------

var gfExp: array[512, int]
var gfLog: array[256, int]
block:
  var x = 1
  for i in 0 ..< 255:
    gfExp[i] = x
    gfLog[x] = i
    x = x shl 1
    if x >= 256: x = x xor 0x11D
  for i in 255 ..< 512: gfExp[i] = gfExp[i - 255]

proc gm(a, b: int): int {.inline.} =
  if a == 0 or b == 0: 0 else: gfExp[gfLog[a] + gfLog[b]]

proc gdiv(a, b: int): int {.inline.} =
  if a == 0: 0 else: gfExp[(gfLog[a] + 255 - gfLog[b]) mod 255]

proc gpow(e: int): int {.inline.} = gfExp[((e mod 255) + 255) mod 255]

proc rsMend(blk: var seq[int]; ecLen: int): int =
  ## Mends the codewords `blk` (its last `ecLen` the error correction): the number put right, -1
  ## when there are too many wrong to.
  let n = blk.len
  var synd = newSeq[int](ecLen)
  var bad = false
  for i in 0 ..< ecLen:
    var s = 0
    let a = gpow(i)
    for c in blk: s = gm(s, a) xor c
    synd[i] = s
    if s != 0: bad = true
  if not bad: return 0
  # Berlekamp-Massey: the error locator
  var lam = @[1]
  var prev = @[1]
  var l = 0
  var m = 1
  var b = 1
  for k in 0 ..< ecLen:
    var d = synd[k]
    for i in 1 .. l:
      if i < lam.len: d = d xor gm(lam[i], synd[k - i])
    if d == 0:
      inc m
      continue
    let coef = gdiv(d, b)
    var t = lam
    if lam.len < prev.len + m: lam.setLen(prev.len + m)
    for i in 0 ..< prev.len: lam[i + m] = lam[i + m] xor gm(coef, prev[i])
    if 2 * l <= k:
      l = k + 1 - l
      prev = t
      b = d
      m = 1
    else: inc m
  while lam.len > 1 and lam[^1] == 0: lam.setLen(lam.len - 1)
  if l != lam.len - 1 or 2 * l > ecLen: return -1
  # Chien: where they are
  var pos: seq[int]
  for j in 0 ..< n:
    let xinv = gpow(-(n - 1 - j))
    var v = 0
    for i in countdown(lam.high, 0): v = gm(v, xinv) xor lam[i]
    if v == 0: pos.add j
  if pos.len != l: return -1
  # Forney: how far off each is
  var omega = newSeq[int](ecLen)
  for i in 0 ..< ecLen:
    var v = 0
    for j in 0 .. min(i, lam.high): v = v xor gm(lam[j], synd[i - j])
    omega[i] = v
  for j in pos:
    let xj = gpow(n - 1 - j)
    let xinv = gpow(-(n - 1 - j))
    var num = 0
    for i in countdown(omega.high, 0): num = gm(num, xinv) xor omega[i]
    var den = 0
    var i = 1
    while i <= lam.high:
      den = den xor gm(lam[i], gpow(-(n - 1 - j) * (i - 1)))
      i += 2
    if den == 0: return -1
    blk[j] = blk[j] xor gm(xj, gdiv(num, den))
  pos.len

# ---- from a grid of modules to its text ----------------------------------------------------------

proc countSetBitsInt(x: int): int =
  var x = x
  while x != 0:
    x = x and (x - 1)
    inc result

proc formatOf(bits: int): tuple[ok: bool; ecc: QrEcc; mask: int] =
  ## (the format nearest the 15 bits read -- three may be wrong)
  var best = 99
  for e in QrEcc:
    for mask in 0 .. 7:
      let d = countSetBitsInt(formatBits(e, mask) xor bits)
      if d < best:
        best = d
        result = (true, e, mask)
  if best > 3: result.ok = false

proc versionOf(bits: int): int =
  ## (the version nearest the 18 bits read, 0 none)
  var best = 99
  for ver in 7 .. 40:
    var rem = ver
    for i in 0 ..< 12: rem = (rem shl 1) xor ((rem shr 11) * 0x1F25)
    let d = countSetBitsInt((ver shl 12 or rem) xor bits)
    if d < best:
      best = d
      result = ver
  if best > 3: result = 0

proc textOf(data: seq[int]; ver: int; ok: var bool): string =
  ## (the segments of the data codewords: numbers, letters, bytes)
  var bitPos = 0
  let total = data.len * 8
  proc take(n: int): int =
    for i in 0 ..< n:
      if bitPos >= total: return -1
      result = (result shl 1) or ((data[bitPos shr 3] shr (7 - (bitPos and 7))) and 1)
      inc bitPos
  let k = if ver <= 9: 0 elif ver <= 26: 1 else: 2
  ok = true
  while bitPos + 4 <= total:
    let mode = take(4)
    case mode
    of 0: break
    of 1:                                 # numeric
      var count = take([10, 12, 14][k])
      while count >= 3:
        let v = take(10)
        if v < 0 or v > 999: (ok = false; return)
        result.add align($v, 3, '0')
        count -= 3
      if count == 2:
        let v = take(7)
        if v < 0 or v > 99: (ok = false; return)
        result.add align($v, 2, '0')
      elif count == 1:
        let v = take(4)
        if v < 0 or v > 9: (ok = false; return)
        result.add $v
    of 2:                                 # letters and digits
      var count = take([9, 11, 13][k])
      while count >= 2:
        let v = take(11)
        if v < 0 or v >= 45 * 45: (ok = false; return)
        result.add alnumChars[v div 45]
        result.add alnumChars[v mod 45]
        count -= 2
      if count == 1:
        let v = take(6)
        if v < 0 or v >= 45: (ok = false; return)
        result.add alnumChars[v]
    of 4:                                 # bytes
      let count = take([8, 16, 16][k])
      if count < 0: (ok = false; return)
      for i in 0 ..< count:
        let v = take(8)
        if v < 0: (ok = false; return)
        result.add char(v)
    of 7:                                 # ECI: the bytes' character set (taken as UTF-8)
      let first = take(8)
      if first < 0: (ok = false; return)
      if (first and 0x80) != 0: discard take(if (first and 0x40) != 0: 16 else: 8)
    of 8:                                 # kanji: not read (each a '?')
      let count = take([8, 10, 12][k])
      for i in 0 ..< count:
        discard take(13)
        result.add '?'
    else:
      ok = false
      return

proc qrDecodeModules*(dark: openArray[bool]; size: int; mended: var int): tuple[ok: bool; text: string;
                      version: int; ecc: QrEcc] =
  ## The text of a QR code's modules, `size` x `size`, row by row (true: dark) -- as `qrRead`
  ## reads them from a picture; `ok` false when they don't make a code (too damaged).
  if size < 21 or (size - 17) mod 4 != 0 or dark.len < size * size: return
  var ver = (size - 17) div 4
  template at(x, y: int): bool = dark[(y) * size + (x)]
  # its format: the copy beside the top left finder, else the one split along the others
  var f1, f2 = 0
  for i in 0 .. 5: f1 = f1 or (ord(at(8, i)) shl i)
  f1 = f1 or (ord(at(8, 7)) shl 6) or (ord(at(8, 8)) shl 7) or (ord(at(7, 8)) shl 8)
  for i in 9 .. 14: f1 = f1 or (ord(at(14 - i, 8)) shl i)
  for i in 0 .. 7: f2 = f2 or (ord(at(size - 1 - i, 8)) shl i)
  for i in 8 .. 14: f2 = f2 or (ord(at(8, size - 15 + i)) shl i)
  var fmt = formatOf(f1)
  if not fmt.ok: fmt = formatOf(f2)
  if not fmt.ok: return
  if ver >= 7:
    var vb = 0
    for i in 0 ..< 18: vb = vb or (ord(at(size - 11 + i mod 3, i div 3)) shl i)
    let v2 = versionOf(vb)
    if v2 > 0 and 17 + 4 * v2 == size: ver = v2
  # the codewords, unmasked, in the order they were placed
  let g = functionPatterns(ver)
  let n = size
  var cw: seq[int]
  var cur = 0
  var nb = 0
  var right = n - 1
  while right >= 1:
    if right == 6: right = 5
    for vert in 0 ..< n:
      for j in 0 .. 1:
        let x = right - j
        let upward = ((right + 1) and 2) == 0
        let y = if upward: n - 1 - vert else: vert
        if not g.fn[y * n + x]:
          var bit = at(x, y)
          if maskBit(fmt.mask, x, y): bit = not bit
          cur = (cur shl 1) or ord(bit)
          inc nb
          if nb == 8:
            cw.add cur
            cur = 0
            nb = 0
    right -= 2
  let raw = rawModules(ver) div 8
  if cw.len < raw: return
  cw.setLen(raw)
  # back into their blocks, each mended, their data together
  let blocks = int(eccBlocks[fmt.ecc][ver])
  let el = int(eccPerBlock[fmt.ecc][ver])
  let numShort = blocks - raw mod blocks
  let shortLen = raw div blocks
  var bl = newSeq[seq[int]](blocks)
  var k = 0
  for i in 0 .. shortLen:
    for j in 0 ..< blocks:
      if i == shortLen - el and j < numShort: continue
      if k < cw.len:
        bl[j].add cw[k]
        inc k
  var data: seq[int]
  for j in 0 ..< blocks:
    let r = rsMend(bl[j], el)
    if r < 0: return
    mended += r
    for i in 0 ..< bl[j].len - el: data.add bl[j][i]
  var ok = false
  let text = textOf(data, ver, ok)
  if not ok: return
  (true, text, ver, fmt.ecc)

# ---- finding codes in a picture ------------------------------------------------------------------

type
  Finder = object
    x, y, module: float
    count: int

proc lumaOf(b: Bitmap): seq[uint8] =
  result = newSeq[uint8](b.w * b.h)
  for i, p in b.px:
    let r = int((p shr 16) and 255)
    let g = int((p shr 8) and 255)
    let bl = int(p and 255)
    var l = (r * 77 + g * 151 + bl * 28) shr 8
    let a = int(p shr 24)
    if a < 255: l = (l * a + 255 * (255 - a)) div 255       # (see-through: on white)
    result[i] = uint8(l)

proc binarize(l: seq[uint8]; w, h: int): seq[bool] =
  ## (dark: darker than the light round it -- the mean of a square about a sixteenth of the
  ## picture across -- by a little; a page in shade or a screen's glare are read alike)
  var integ = newSeq[int]((w + 1) * (h + 1))
  for y in 0 ..< h:
    var row = 0
    for x in 0 ..< w:
      row += int(l[y * w + x])
      integ[(y + 1) * (w + 1) + x + 1] = integ[y * (w + 1) + x + 1] + row
  let half = max(8, min(w, h) div 16)
  result = newSeq[bool](w * h)
  for y in 0 ..< h:
    let y0 = max(0, y - half)
    let y1 = min(h, y + half + 1)
    for x in 0 ..< w:
      let x0 = max(0, x - half)
      let x1 = min(w, x + half + 1)
      let sum = integ[y1 * (w + 1) + x1] - integ[y0 * (w + 1) + x1] - integ[y1 * (w + 1) + x0] + integ[y0 * (w + 1) + x0]
      let mean = sum div ((y1 - y0) * (x1 - x0))
      result[y * w + x] = int(l[y * w + x]) * 100 < mean * 92 or l[y * w + x] < 40

proc ratioOk(r: array[5, int]): bool =
  ## (runs of 1:1:3:1:1)
  let total = r[0] + r[1] + r[2] + r[3] + r[4]
  if total < 7: return false
  let m = total / 7
  let v = m / 2
  abs(m - r[0].float) < v and abs(m - r[1].float) < v and abs(3 * m - r[2].float) < 3 * v and
    abs(m - r[3].float) < v and abs(m - r[4].float) < v

proc crossDown(bw: seq[bool]; w, h: int; cx, cy, maxRun: int): float =
  ## (the middle of a finder down the column `cx` about `cy`, NaN when it isn't one)
  var r: array[5, int]
  var y = cy
  while y >= 0 and bw[y * w + cx]: (inc r[2]; dec y)
  if y < 0: return NaN
  while y >= 0 and not bw[y * w + cx] and r[1] <= maxRun: (inc r[1]; dec y)
  if y < 0 or r[1] > maxRun: return NaN
  while y >= 0 and bw[y * w + cx] and r[0] <= maxRun: (inc r[0]; dec y)
  if r[0] > maxRun: return NaN
  y = cy + 1
  while y < h and bw[y * w + cx]: (inc r[2]; inc y)
  if y >= h: return NaN
  while y < h and not bw[y * w + cx] and r[3] < maxRun: (inc r[3]; inc y)
  if y >= h or r[3] >= maxRun: return NaN
  while y < h and bw[y * w + cx] and r[4] < maxRun: (inc r[4]; inc y)
  if r[4] >= maxRun: return NaN
  if not ratioOk(r): return NaN
  float(y - r[4] - r[3]) - r[2].float / 2

proc crossAcross(bw: seq[bool]; w, h: int; cx, cy, maxRun: int): float =
  ## (the same along the row `cy` about `cx`)
  var r: array[5, int]
  var x = cx
  let row = cy * w
  while x >= 0 and bw[row + x]: (inc r[2]; dec x)
  if x < 0: return NaN
  while x >= 0 and not bw[row + x] and r[1] <= maxRun: (inc r[1]; dec x)
  if x < 0 or r[1] > maxRun: return NaN
  while x >= 0 and bw[row + x] and r[0] <= maxRun: (inc r[0]; dec x)
  if r[0] > maxRun: return NaN
  x = cx + 1
  while x < w and bw[row + x]: (inc r[2]; inc x)
  if x >= w: return NaN
  while x < w and not bw[row + x] and r[3] < maxRun: (inc r[3]; inc x)
  if x >= w or r[3] >= maxRun: return NaN
  while x < w and bw[row + x] and r[4] < maxRun: (inc r[4]; inc x)
  if r[4] >= maxRun: return NaN
  if not ratioOk(r): return NaN
  float(x - r[4] - r[3]) - r[2].float / 2

proc addFinder(fs: var seq[Finder]; cx, cy, module: float) =
  for f in fs.mitems:
    if abs(f.x - cx) <= module * 2 and abs(f.y - cy) <= module * 2 and
       abs(f.module - module) <= max(1.0, module * 0.5):
      f.x = (f.x * f.count.float + cx) / float(f.count + 1)
      f.y = (f.y * f.count.float + cy) / float(f.count + 1)
      f.module = (f.module * f.count.float + module) / float(f.count + 1)
      inc f.count
      return
  fs.add Finder(x: cx, y: cy, module: module, count: 1)

proc findFinders(bw: seq[bool]; w, h: int): seq[Finder] =
  ## (the finder patterns: runs of dark, light, dark, light, dark of 1:1:3:1:1 along a row, the
  ## same down the column through their middle and along the row again)
  for y in countup(0, h - 1, max(1, h div 600)):
    var r: array[5, int]
    var state = 0
    let row = y * w
    for x in 0 ..< w:
      if bw[row + x]:
        if (state and 1) == 1: inc state
        inc r[state]
      elif (state and 1) == 0:
        if state == 0 and r[0] == 0: continue        # (light before any dark)
        if state == 4:
          if ratioOk(r):
            let total = r[0] + r[1] + r[2] + r[3] + r[4]
            let cx = int(float(x - r[4] - r[3]) - r[2] / 2)
            let cy = crossDown(bw, w, h, cx, y, r[2])
            if not cy.isNaN:
              let cx2 = crossAcross(bw, w, h, cx, int(cy), r[2])
              if not cx2.isNaN: result.addFinder(cx2, cy, total / 7)
          # (on: its last dark, light and dark the start of the next one)
          r = [r[2], r[3], r[4], 1, 0]
          state = 3
        else:
          inc state
          inc r[state]
      else: inc r[state]

proc solve8(src, dst: array[4, (float, float)]): array[9, float] =
  ## (the perspective taking the square `src` corners to `dst`: a 3x3 matrix, by Gauss)
  var a: array[8, array[9, float]]
  for i in 0 .. 3:
    let (x, y) = src[i]
    let (u, v) = dst[i]
    a[2 * i] = [x, y, 1.0, 0.0, 0.0, 0.0, -u * x, -u * y, u]
    a[2 * i + 1] = [0.0, 0.0, 0.0, x, y, 1.0, -v * x, -v * y, v]
  for c in 0 ..< 8:
    var p = c
    for r in c + 1 ..< 8:
      if abs(a[r][c]) > abs(a[p][c]): p = r
    swap(a[c], a[p])
    if abs(a[c][c]) < 1e-12: return
    for r in 0 ..< 8:
      if r != c:
        let f = a[r][c] / a[c][c]
        for k in c .. 8: a[r][k] -= f * a[c][k]
  for i in 0 ..< 8: result[i] = a[i][8] / a[i][i]
  result[8] = 1.0

proc mapPt(m: array[9, float]; x, y: float): (float, float) {.inline.} =
  let d = m[6] * x + m[7] * y + m[8]
  ((m[0] * x + m[1] * y + m[2]) / d, (m[3] * x + m[4] * y + m[5]) / d)

proc findAlign(bw: seq[bool]; w, h: int; ex, ey, module: float): tuple[ok: bool; x, y: float] =
  ## (the alignment pattern -- a dark module in a light ring in a dark one -- nearest where it
  ## should be: its middle)
  let reach = int(module * 4)
  var best = 1e9
  for dy in -reach .. reach:
    for dx in -reach .. reach:
      let x = int(ex) + dx
      let y = int(ey) + dy
      if x < 2 or y < 2 or x >= w - 2 or y >= h - 2 or not bw[y * w + x]: continue
      # (light a module out every way, dark again two out)
      let m = max(1, int(module + 0.5))
      var good = true
      for (ax, ay) in [(m, 0), (-m, 0), (0, m), (0, -m)]:
        let lx = x + ax
        let ly = y + ay
        if lx < 0 or ly < 0 or lx >= w or ly >= h or bw[ly * w + lx]: (good = false; break)
        let fx = x + 2 * ax
        let fy = y + 2 * ay
        if fx < 0 or fy < 0 or fx >= w or fy >= h or not bw[fy * w + fx]: (good = false; break)
      if good:
        let d = float(dx * dx + dy * dy)
        if d < best:
          best = d
          result = (true, x.float, y.float)

proc readAt(bw: seq[bool]; w, h: int; f: array[3, Finder]; mended: var int): tuple[ok: bool; r: QrRead] =
  ## (a code whose three finders are `f`: top left, top right, bottom left)
  let (tl, tr, bl) = (f[0], f[1], f[2])
  let module = (tl.module + tr.module + bl.module) / 3
  let dTop = hypot(tr.x - tl.x, tr.y - tl.y)
  let dLeft = hypot(bl.x - tl.x, bl.y - tl.y)
  var dim = int(round((dTop + dLeft) / 2 / module)) + 7
  case dim and 3
  of 0: inc dim
  of 2: dec dim
  of 3: dim -= 2
  else: discard
  for tryDim in [dim, dim + 4, dim - 4]:
    if tryDim < 21 or tryDim > 177: continue
    let ver = (tryDim - 17) div 4
    let d = tryDim.float
    # the fourth corner: by the alignment pattern when there is one, else as a parallelogram
    var br = (tr.x + bl.x - tl.x, tr.y + bl.y - tl.y)
    var brModule = (d - 3.5, d - 3.5)
    if ver >= 2:
      let k = 1.0 - 3.0 / (d - 7.0)
      let ex = tl.x + k * (tr.x - tl.x + bl.x - tl.x)
      let ey = tl.y + k * (tr.y - tl.y + bl.y - tl.y)
      let a = findAlign(bw, w, h, ex, ey, module)
      if a.ok:
        br = (a.x, a.y)
        brModule = (d - 6.5, d - 6.5)
    let m = solve8([(3.5, 3.5), (d - 3.5, 3.5), brModule, (3.5, d - 3.5)],
                   [(tl.x, tl.y), (tr.x, tr.y), br, (bl.x, bl.y)])
    if m[8] == 0: continue
    var mods = newSeq[bool](tryDim * tryDim)
    for y in 0 ..< tryDim:
      for x in 0 ..< tryDim:
        let (px, py) = mapPt(m, x.float + 0.5, y.float + 0.5)
        let ix = int(px)
        let iy = int(py)
        if ix >= 0 and iy >= 0 and ix < w and iy < h: mods[y * tryDim + x] = bw[iy * w + ix]
    var fixed = 0
    let got = qrDecodeModules(mods, tryDim, fixed)
    if got.ok:
      mended += fixed
      var r = QrRead(text: got.text, version: got.version, ecc: got.ecc, mended: fixed)
      r.corners = [mapPt(m, 0, 0), mapPt(m, d, 0), mapPt(m, d, d), mapPt(m, 0, d)]
      return (true, r)

proc qrRead*(b: Bitmap; most = 4): seq[QrRead] =
  ## The QR codes in the picture `b` -- a camera's, a screenshot, a scan -- read: what each says,
  ## where it is. Upright or turned any way, in perspective, a little damaged (as much as its
  ## level of error correction mends). At most `most` of them.
  if b == nil or b.w < 21 or b.h < 21: return
  let bw = binarize(lumaOf(b), b.w, b.h)
  var fs = findFinders(bw, b.w, b.h)
  if fs.len < 3: return
  # (the surest first: seen in the most rows)
  for i in 1 ..< fs.len:
    var j = i
    while j > 0 and fs[j].count > fs[j - 1].count:
      swap(fs[j], fs[j - 1])
      dec j
  if fs.len > 12: fs.setLen(12)
  var used = newSeq[bool](fs.len)
  var mended = 0
  for i in 0 ..< fs.len:
    for j in i + 1 ..< fs.len:
      for k in j + 1 ..< fs.len:
        if used[i] or used[j] or used[k] or result.len >= most: continue
        let a = [fs[i], fs[j], fs[k]]
        let ms = [a[0].module, a[1].module, a[2].module]
        if max(ms) > min(ms) * 1.6: continue
        # (the corner of the right angle: the one opposite the longest side)
        let d01 = hypot(a[0].x - a[1].x, a[0].y - a[1].y)
        let d02 = hypot(a[0].x - a[2].x, a[0].y - a[2].y)
        let d12 = hypot(a[1].x - a[2].x, a[1].y - a[2].y)
        var tl, p, q: Finder
        if d12 >= d01 and d12 >= d02: (tl = a[0]; p = a[1]; q = a[2])
        elif d02 >= d01: (tl = a[1]; p = a[0]; q = a[2])
        else: (tl = a[2]; p = a[0]; q = a[1])
        let longest = max(d01, max(d02, d12))
        if longest < 14 * min(ms): continue
        # (top right and bottom left: clockwise from top left, y going down)
        let cross = (p.x - tl.x) * (q.y - tl.y) - (p.y - tl.y) * (q.x - tl.x)
        if cross < 0: swap(p, q)
        let got = readAt(bw, b.w, b.h, [tl, p, q], mended)
        if got.ok:
          result.add got.r
          used[i] = true
          used[j] = true
          used[k] = true
