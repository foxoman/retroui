## Very big pictures -- gigapixel scans, panoramas, maps 30000 pixels a
## side -- read without taking their whole size in memory: decoded a band
## of rows at a time straight from the file (mapped, never read whole), and
## either made smaller on the way (`readScaled`: each new pixel the average
## of those it covers) or cut to a part (`readRegion`). The memory is about
## one band and what is made.
##
## - PNG: every color type and depth, a row at a time (the data inflated
##   as it goes); interlaced ones too, their passes summed in any order;
## - JPEG: baseline a few rows of blocks at a time (whole restart intervals
##   above a part skipped); progressive ones with only the coefficients of
##   the rows wanted kept (in passes when they are many), or at an eighth
##   of the size with only each block's average; the EXIF orientation
##   followed;
## - BMP and TGA, row by row (bottom-up ones read in the file's order);
## - TIFF in strips (none, LZW, Deflate, PackBits: each strip inflated as
##   it goes, whatever its size) or in tiles (a row of tiles at a time).
##
## The sizes and parts are those of the picture as it is shown (a turned
## JPEG: turned). `retroui/imaging`'s `loadPicture` uses `readScaled` for
## big PNG, JPEG and BMP files, so thumbnails and viewers stay small.
##
## .. code-block:: nim
##   let (w, h, kind) = bigPictureInfo("scan.png")            # from the header
##   let small = readScaled("scan.png", 1024, 1024)          # all of it, fitted
##   let part = readRegion("scan.png", 12000, 8000, 2000, 1500)   # 1:1
##   let half = readRegion("scan.png", 0, 0, 8000, 8000, scale = 4)
##
## Work on the drawing thread keeps the window alive and stops when Cancel
## is pressed (`BusyCancelled`, inside a cancellable `beginBusy`); a
## `progress` callback hears how far it is (it may raise to stop too).

import std/[memfiles, os, strutils]
import gfx, codec, jpeg, imageformats, busy

type
  BigPictureError* = object of CatchableError
    ## The file is not a picture this module reads, or it is damaged.

  BigProgress* = proc (done: float) {.closure, gcsafe.}
    ## How much of the work is done (0 .. 1).

var maxReadPixels* = 400_000_000
  ## Pictures made bigger than this (`readScaled`, `readRegion`) are
  ## refused: what is made is in memory whole.

var coefficientBudget* = 256 shl 20
  ## The memory a progressive JPEG's coefficients may take in one pass over
  ## the file (more: more passes).

proc fail(msg: string) {.noreturn.} = raise newException(BigPictureError, msg)

const
  SideLimit = 1 shl 20          ## (a side longer is refused: a damaged header)
  PixelLimit = 1'i64 shl 34     ## (and more pixels than this)

# ---- the file, mapped -----------------------------------------------------------------------------

type Mapped = ref object
  mf: MemFile
  mapped: bool
  bytes: string
  p: ptr UncheckedArray[char]
  n: int

proc openMapped(path: string): Mapped =
  ## The file's bytes: mapped into memory (the system reads what is
  ## touched), or read when it cannot be mapped and is not too big.
  result = Mapped()
  try:
    result.mf = memfiles.open(path)
    result.mapped = true
    result.p = cast[ptr UncheckedArray[char]](result.mf.mem)
    result.n = result.mf.size
  except CatchableError:
    let size = try: getFileSize(path) except CatchableError: -1'i64
    if size < 0: fail("cannot read " & path.extractFilename)
    if size > 512'i64 shl 20: fail("cannot map " & path.extractFilename)
    result.bytes = try: readFile(path) except CatchableError: fail("cannot read " & path.extractFilename)
    result.n = result.bytes.len
    if result.n > 0: result.p = cast[ptr UncheckedArray[char]](addr result.bytes[0])

proc close(m: Mapped) =
  if m.mapped:
    m.mapped = false
    m.mf.close()

template bytesOf(m: Mapped): openArray[char] = toOpenArray(m.p, 0, m.n - 1)

proc be32(p: ptr UncheckedArray[char]; i: int): int =
  (ord(p[i]) shl 24) or (ord(p[i+1]) shl 16) or (ord(p[i+2]) shl 8) or ord(p[i+3])
proc le16(p: ptr UncheckedArray[char]; i: int): int = ord(p[i]) or (ord(p[i+1]) shl 8)
proc le32(p: ptr UncheckedArray[char]; i: int): int =
  int(cast[int32](uint32(ord(p[i])) or (uint32(ord(p[i+1])) shl 8) or
                  (uint32(ord(p[i+2])) shl 16) or (uint32(ord(p[i+3])) shl 24)))

# ---- PNG rows ---------------------------------------------------------------------------------------

type PngLayout* = object
  ## How a PNG's rows make pixels (`pngLayout`): what `pngRowPixels` turns
  ## a row with. Also `retroui/imaging`'s `decodePng` reads with it.
  w*, h*, depth*, ctype*, interlace*: int
    ## the header's (IHDR) values: size, bits a sample, color type, interlace (0, 1)
  channels*: int               ## samples a pixel (1 gray .. 4 RGBA)
  bpp*: int                    ## bytes a pixel, for the filters (at least 1)
  palette*: seq[uint32]        ## (its tRNS alphas in it)
  key*: int                    ## gray or RGB: the color that is transparent (-1: none)

proc pngLayout*(w, h, depth, ctype, interlace: int; palette: seq[uint32]; trns: string;
                L: var PngLayout): string =
  ## The layout of a PNG with these header values (IHDR, PLTE, tRNS): ""
  ## or what is wrong with them.
  let channels = case ctype
    of 0: 1
    of 2: 3
    of 3: 1
    of 4: 2
    of 6: 4
    else: return "bad PNG color type"
  let depthOk = case ctype
    of 0: depth in [1, 2, 4, 8, 16]
    of 3: depth in [1, 2, 4, 8]
    else: depth in [8, 16]
  if not depthOk: return "bad PNG bit depth"
  if interlace notin [0, 1]: return "bad PNG interlace method"
  L = PngLayout(w: w, h: h, depth: depth, ctype: ctype, interlace: interlace, channels: channels,
                bpp: max(1, channels * depth div 8), palette: palette, key: -1)
  for i, a in trns:
    if ctype == 3 and i < L.palette.len:
      L.palette[i] = (L.palette[i] and 0xFFFFFF'u32) or (uint32(ord(a)) shl 24)
  # tRNS of gray and RGB images: one color that is transparent
  proc keyOf(v: int): int =
    if depth == 16: v shr 8 elif depth == 8: v else: v * 255 div ((1 shl depth) - 1)
  if ctype == 0 and trns.len >= 2:
    L.key = keyOf((ord(trns[0]) shl 8) or ord(trns[1]))
  elif ctype == 2 and trns.len >= 6:
    L.key = (keyOf((ord(trns[0]) shl 8) or ord(trns[1])) shl 16) or
            (keyOf((ord(trns[2]) shl 8) or ord(trns[3])) shl 8) or
            keyOf((ord(trns[4]) shl 8) or ord(trns[5]))
  ""

{.push boundChecks: off, overflowChecks: off.}

proc pngUnfilter*(filter: int; src, line, prev: ptr UncheckedArray[byte]; stride, bpp: int): bool =
  ## A row's filter undone: its `stride` bytes after the filter byte, `src`,
  ## into `line`; `prev` is the row above (unfiltered; zeros for the
  ## first). False when `filter` is not one.
  let lead = min(bpp, stride)
  # the filters, each a loop of its own (bytes wrap around)
  case filter
  of 0:
    for i in 0 ..< stride: line[i] = src[i]
  of 1:
    for i in 0 ..< lead: line[i] = src[i]
    for i in bpp ..< stride: line[i] = src[i] + line[i - bpp]
  of 2:
    for i in 0 ..< stride: line[i] = src[i] + prev[i]
  of 3:
    for i in 0 ..< lead: line[i] = src[i] + (prev[i] shr 1)
    for i in bpp ..< stride:
      line[i] = src[i] + byte((int(line[i - bpp]) + int(prev[i])) shr 1)
  of 4:
    for i in 0 ..< lead: line[i] = src[i] + prev[i]
    for i in bpp ..< stride:
      let a = int(line[i - bpp])
      let b = int(prev[i])
      let c = int(prev[i - bpp])
      let pa = abs(b - c)
      let pb = abs(a - c)
      let pc = abs(a + b - 2 * c)
      line[i] = src[i] + byte(if pa <= pb and pa <= pc: a elif pb <= pc: b else: c)
  else: return false
  true

proc pngRowPixels*(L: PngLayout; line: ptr UncheckedArray[byte]; i0, i1: int;
                   dst: ptr UncheckedArray[uint32]; x0 = 0; dx = 1) =
  ## Pixels `i0 ..< i1` of an unfiltered row (`pngUnfilter`), pixel `i`
  ## into `dst[x0 + i * dx]` (an interlaced pass's: every `dx`-th).
  let channels = L.channels
  let depth = L.depth
  let ctype = L.ctype
  let key = L.key
  template sample(x, c: int): int =
    ## (channel `c` of pixel `x`, scaled to 0..255; a palette's: the index)
    (case depth
     of 8: int(line[x * channels + c])
     of 16: int(line[(x * channels + c) * 2])
     else:
       let bitsAt = (x * channels + c) * depth
       let v = (int(line[bitsAt shr 3]) shr (8 - depth - (bitsAt and 7))) and ((1 shl depth) - 1)
       if ctype == 3: v else: v * 255 div ((1 shl depth) - 1))
  if depth == 8 and ctype != 3:
    # 8 bits a channel: straight from the bytes
    var x = x0 + i0 * dx
    var k = i0 * channels
    case ctype
    of 0:
      for i in i0 ..< i1:
        let g = uint32(line[k])
        var px = 0xFF000000'u32 or (g shl 16) or (g shl 8) or g
        if int(g) == key: px = px and 0xFFFFFF'u32
        dst[x] = px
        x += dx
        k += 1
    of 2:
      for i in i0 ..< i1:
        var px = 0xFF000000'u32 or (uint32(line[k]) shl 16) or
                 (uint32(line[k + 1]) shl 8) or uint32(line[k + 2])
        if key >= 0 and int(px and 0xFFFFFF'u32) == key: px = px and 0xFFFFFF'u32
        dst[x] = px
        x += dx
        k += 3
    of 4:
      for i in i0 ..< i1:
        let g = uint32(line[k])
        dst[x] = (uint32(line[k + 1]) shl 24) or (g shl 16) or (g shl 8) or g
        x += dx
        k += 2
    else:
      for i in i0 ..< i1:
        dst[x] = (uint32(line[k + 3]) shl 24) or (uint32(line[k]) shl 16) or
                 (uint32(line[k + 1]) shl 8) or uint32(line[k + 2])
        x += dx
        k += 4
  else:
    for i in i0 ..< i1:
      var px: uint32
      case ctype
      of 0:
        let g = uint32(sample(i, 0))
        px = 0xFF000000'u32 or (g shl 16) or (g shl 8) or g
        if int(g) == key: px = px and 0xFFFFFF'u32
      of 2:
        px = 0xFF000000'u32 or (uint32(sample(i, 0)) shl 16) or
             (uint32(sample(i, 1)) shl 8) or uint32(sample(i, 2))
        if key >= 0 and int(px and 0xFFFFFF'u32) == key: px = px and 0xFFFFFF'u32
      of 3:
        let k = sample(i, 0)
        px = if k < L.palette.len: L.palette[k] else: 0xFF000000'u32
      of 4:
        let g = uint32(sample(i, 0))
        px = (uint32(sample(i, 1)) shl 24) or (g shl 16) or (g shl 8) or g
      else:
        px = (uint32(sample(i, 3)) shl 24) or
             (uint32(sample(i, 0)) shl 16) or
             (uint32(sample(i, 1)) shl 8) or uint32(sample(i, 2))
      dst[x0 + i * dx] = px

{.pop.}

# ---- BMP rows ----------------------------------------------------------------------------------------

type BmpLayout* = object
  ## An uncompressed BMP's layout (`bmpLayout`): what `bmpRow` reads.
  w*, h*, bits*: int           ## its size, and bits a pixel (1, 4, 8, 16, 24, 32)
  offset*, stride*: int        ## where the rows begin; the bytes of one
  topDown*: bool               ## the first row is the top one
  useAlpha*: bool              ## 32 bits: their alpha kept
  palette*: seq[uint32]        ## the colors of 1, 4 and 8 bits a pixel (ARGB)

proc bmpLayout*(data: ptr UncheckedArray[char]; len, maxPixels: int; L: var BmpLayout;
                scanAlpha = true): string =
  ## The layout of the BMP in `data[0 ..< len]`: "" or what is wrong with
  ## it. A 32-bit one with a plain header keeps its alpha when some pixel's
  ## is not 0 (looked for when `scanAlpha`).
  if len < 54 or data[0] != 'B' or data[1] != 'M': return "not a BMP file"
  let offset = le32(data, 10)
  let hsize = le32(data, 14)
  let w = le32(data, 18)
  var h = le32(data, 22)
  let bits = le16(data, 28)
  let compression = le32(data, 30)
  let topDown = h < 0
  h = abs(h)
  if w <= 0 or h == 0 or w > 65535 or h > 65535 or w * h > maxPixels: return "bad BMP size"
  if compression notin [0, 3]: return "compressed BMP files are not supported"
  if bits notin [1, 4, 8, 16, 24, 32]: return "BMP with " & $bits & " bits per pixel is not supported"
  if offset < 26 or hsize < 12 or hsize > len: return "damaged BMP header"
  L = BmpLayout(w: w, h: h, bits: bits, offset: offset, topDown: topDown)
  if bits <= 8:
    let n = 1 shl bits
    let at = 14 + hsize
    for i in 0 ..< n:
      if at + 4 * i + 3 >= len: break
      L.palette.add 0xFF000000'u32 or (uint32(ord(data[at + 4*i + 2])) shl 16) or
                    (uint32(ord(data[at + 4*i + 1])) shl 8) or uint32(ord(data[at + 4*i]))
  L.stride = ((w * bits + 31) div 32) * 4
  if offset + L.stride * h > len: return "BMP data ends too soon"
  # (32 bits: their alpha kept when the header has an alpha mask -- a V4
  # or V5 header -- or when some pixel has an alpha that is not 0)
  L.useAlpha = bits == 32 and hsize >= 56 and 70 <= len and le32(data, 14 + 40 + 12) != 0
  if bits == 32 and not L.useAlpha and hsize == 40 and scanAlpha:
    block scan:
      for j in 0 ..< h:
        let row = offset + j * L.stride
        for x in 0 ..< w:
          if data[row + 4 * x + 3] != '\0':
            L.useAlpha = true
            break scan
  ""

{.push boundChecks: off, overflowChecks: off.}

proc bmpRow*(L: BmpLayout; data: ptr UncheckedArray[char]; y, x0, x1: int; dst: ptr UncheckedArray[uint32]) =
  ## Pixels `x0 ..< x1` of row `y` (from the top) into `dst[x0 ..< x1]`.
  let row = L.offset + (if L.topDown: y else: L.h - 1 - y) * L.stride
  for x in x0 ..< x1:
    var px: uint32
    case L.bits
    of 32:
      let i = row + 4 * x
      let a = if L.useAlpha: uint32(ord(data[i+3])) shl 24 else: 0xFF000000'u32
      px = a or (uint32(ord(data[i+2])) shl 16) or (uint32(ord(data[i+1])) shl 8) or uint32(ord(data[i]))
    of 24:
      let i = row + 3 * x
      px = 0xFF000000'u32 or (uint32(ord(data[i+2])) shl 16) or
           (uint32(ord(data[i+1])) shl 8) or uint32(ord(data[i]))
    of 16:
      let v = le16(data, row + 2 * x)
      px = 0xFF000000'u32 or (uint32(((v shr 10) and 31) * 255 div 31) shl 16) or
           (uint32(((v shr 5) and 31) * 255 div 31) shl 8) or
           uint32((v and 31) * 255 div 31)
    else:
      let bitsAt = x * L.bits
      let k = (ord(data[row + (bitsAt shr 3)]) shr (8 - L.bits - (bitsAt and 7))) and ((1 shl L.bits) - 1)
      px = if k < L.palette.len: L.palette[k] else: 0xFF000000'u32
    dst[x] = px

{.pop.}

# ---- where the rows go: copied, or averaged ------------------------------------------------------------

type
  Axis = object
    ## One side of the picture as stored: the pixels `lo ..< hi` read, and
    ## the pixel of what is made each goes to.
    lo, hi: int
    map: seq[int32]            # (index - lo) -> the pixel made
    cnt: seq[int32]            # pixels read for each pixel made
    n: int                     # pixels made
    one: bool                  # one each: copied

  Sink = object
    ## Rows of the picture as stored, summed into what is made (as stored
    ## too: turned at the end).
    ax, ay: Axis
    outp: Bitmap
    acc: seq[uint64]           # four sums a pixel made: of one row (or of all)
    cur: int                   # the row being summed (-1: none)
    unordered: bool            # rows in any order (an interlaced PNG): all summed at once
    progress: BigProgress

proc scaledAxis(len, outN: int; flip: bool): Axis =
  ## A side of `len` pixels made `outN`, each the average of those it
  ## covers -- as `thumbnail` does it, on the picture turned (`flip`: this
  ## side runs the other way there).
  result = Axis(lo: 0, hi: len, n: outN, one: len == outN)
  result.map = newSeq[int32](len)
  result.cnt = newSeq[int32](outN)
  for b in 0 ..< outN:
    let s0 = b * len div outN
    let s1 = max(s0 + 1, (b + 1) * len div outN)
    let o = if flip: outN - 1 - b else: b
    result.cnt[o] = int32(s1 - s0)
    for j in s0 ..< min(s1, len):
      result.map[(if flip: len - 1 - j else: j)] = int32(o)

proc regionAxis(len, start, count, s: int; flip: bool): Axis =
  ## The part `start ..< start + count` of a side of `len` (on the picture
  ## turned), in squares of `s`.
  let n = (count + s - 1) div s
  let lo = if flip: len - start - count else: start
  result = Axis(lo: lo, hi: lo + count, n: n, one: s == 1)
  result.map = newSeq[int32](count)
  result.cnt = newSeq[int32](n)
  for j in start ..< start + count:
    let b = (j - start) div s
    let o = if flip: n - 1 - b else: b
    result.map[(if flip: len - 1 - j else: j) - lo] = int32(o)
    result.cnt[o] = int32(min(s, count - b * s))

proc initSink(ax, ay: Axis; unordered = false; progress: BigProgress = nil): Sink =
  if ax.n.int64 * ay.n.int64 > maxReadPixels.int64: fail("the picture to make is too big")
  result = Sink(ax: ax, ay: ay, cur: -1, unordered: unordered, progress: progress)
  result.outp = newBitmap(ax.n, ay.n)
  if not (ax.one and ay.one):
    if unordered:
      if ax.n.int64 * ay.n.int64 * 32 > 1'i64 shl 30: fail("the picture to make is too big for this file")
      result.acc = newSeq[uint64](ax.n * ay.n * 4)
    else:
      result.acc = newSeq[uint64](ax.n * 4)

{.push boundChecks: off, overflowChecks: off.}

proc flushRow(s: var Sink; oy: int) =
  ## A row made: its sums divided.
  let ow = s.ax.n
  let base = if s.unordered: oy * ow * 4 else: 0
  let dst = cast[ptr UncheckedArray[uint32]](addr s.outp.px[oy * ow])
  let ry = uint64(s.ay.cnt[oy])
  for o in 0 ..< ow:
    let n = uint64(s.ax.cnt[o]) * ry
    let j = base + o * 4
    dst[o] = (uint32(s.acc[j] div n) shl 24) or (uint32(s.acc[j + 1] div n) shl 16) or
             (uint32(s.acc[j + 2] div n) shl 8) or uint32(s.acc[j + 3] div n)
    if not s.unordered:
      s.acc[j] = 0; s.acc[j + 1] = 0; s.acc[j + 2] = 0; s.acc[j + 3] = 0

proc put(s: var Sink; y: int; row: ptr UncheckedArray[uint32]) =
  ## Row `y` of the picture (as stored): pixels `ax.lo ..< ax.hi` of `row`.
  if y < s.ay.lo or y >= s.ay.hi: return
  let oy = int(s.ay.map[y - s.ay.lo])
  let lo = s.ax.lo
  let n = s.ax.hi - lo
  let mp = cast[ptr UncheckedArray[int32]](addr s.ax.map[0])
  if s.ax.one and s.ay.one:
    let dst = cast[ptr UncheckedArray[uint32]](addr s.outp.px[oy * s.ax.n])
    if n > 0 and mp[0] == 0: copyMem(addr dst[0], addr row[lo], n * 4)
    else:
      for i in 0 ..< n: dst[mp[i]] = row[lo + i]
    return
  if not s.unordered and oy != s.cur:
    if s.cur >= 0: s.flushRow(s.cur)
    s.cur = oy
  let acc = cast[ptr UncheckedArray[uint64]](addr s.acc[if s.unordered: oy * s.ax.n * 4 else: 0])
  for i in 0 ..< n:
    let p = row[lo + i]
    let j = int(mp[i]) * 4
    acc[j] += p shr 24
    acc[j + 1] += (p shr 16) and 255
    acc[j + 2] += (p shr 8) and 255
    acc[j + 3] += p and 255

proc putEvery(s: var Sink; y: int; row: ptr UncheckedArray[uint32]; x0, dx, n: int) =
  ## Pixels `x0`, `x0 + dx` ... (`n` of them) of row `y` (an interlaced
  ## pass's); the sink takes rows in any order.
  if y < s.ay.lo or y >= s.ay.hi: return
  let oy = int(s.ay.map[y - s.ay.lo])
  let ow = s.ax.n
  for i in 0 ..< n:
    let x = x0 + i * dx
    if x < s.ax.lo or x >= s.ax.hi: continue
    let o = int(s.ax.map[x - s.ax.lo])
    let p = row[x]
    if s.ax.one and s.ay.one:
      s.outp.px[oy * ow + o] = p
    else:
      let j = (oy * ow + o) * 4
      s.acc[j] += p shr 24
      s.acc[j + 1] += (p shr 16) and 255
      s.acc[j + 2] += (p shr 8) and 255
      s.acc[j + 3] += p and 255

{.pop.}

proc finish(s: var Sink): Bitmap =
  ## What was made (as stored).
  if not (s.ax.one and s.ay.one):
    if s.unordered:
      for oy in 0 ..< s.ay.n: s.flushRow(oy)
    elif s.cur >= 0: s.flushRow(s.cur)
  s.acc = @[]
  s.outp.changed()
  s.outp

proc tick(s: var Sink; done: float) =
  ## How far it is: told, the window kept alive (Cancel heard).
  if s.progress != nil: s.progress(done)
  if onUiThread(): busyFraction = done
  busyTick()

# ---- the readers: each gives the rows of its picture --------------------------------------------------

proc readPng(m: Mapped; s: var Sink) =
  let p = m.p
  let n = m.n
  if n < 33: fail("not a PNG file")
  var w, h, depth, ctype, interlace = 0
  var palette: seq[uint32]
  var trns = ""
  var at = 8
  var firstIdat = -1
  while at + 8 <= n:
    let len = be32(p, at)
    if len < 0 or at + 12 + len > n: fail("damaged PNG chunk")
    let kind = [p[at + 4], p[at + 5], p[at + 6], p[at + 7]]
    if kind == ['I', 'D', 'A', 'T']:
      firstIdat = at
      break
    if kind == ['I', 'H', 'D', 'R']:
      if len < 13: fail("damaged PNG header")
      w = be32(p, at + 8)
      h = be32(p, at + 12)
      depth = ord(p[at + 16])
      ctype = ord(p[at + 17])
      interlace = ord(p[at + 20])
    elif kind == ['P', 'L', 'T', 'E']:
      for i in 0 ..< len div 3:
        let b = at + 8 + 3 * i
        palette.add 0xFF000000'u32 or (uint32(ord(p[b])) shl 16) or (uint32(ord(p[b + 1])) shl 8) or
                    uint32(ord(p[b + 2]))
    elif kind == ['t', 'R', 'N', 'S']:
      trns = newString(len)
      if len > 0: copyMem(addr trns[0], addr p[at + 8], len)
    elif kind == ['I', 'E', 'N', 'D']: break
    at += 12 + len
  if w <= 0 or h <= 0 or w > SideLimit or h > SideLimit: fail("bad PNG size")
  if firstIdat < 0: fail("no picture data in the PNG file")
  var L: PngLayout
  let err = pngLayout(w, h, depth, ctype, interlace, palette, trns, L)
  if err.len > 0: fail(err)
  # (the rows against the data: deflate packs no tighter than about 1000
  # to 1 -- a damaged header cannot ask for more)
  var packed = 0'i64
  var c = firstIdat
  while c + 8 <= n:
    let len = be32(p, c)
    if len < 0 or c + 12 + len > n: break
    if p[c + 4] == 'I' and p[c + 5] == 'D' and p[c + 6] == 'A' and p[c + 7] == 'T': packed += len
    c += 12 + len
  let rowBytes = (w.int64 * L.channels * depth + 7) div 8 + 1
  if rowBytes * h.int64 > packed * 1100 + 65536: fail("PNG data ends too soon")
  # the data chunks one after the other, inflated as the rows are read
  var cp = firstIdat
  let pieces: InflatePiece = proc (): tuple[p: pointer; n: int] {.closure, gcsafe.} =
    while cp + 8 <= n:
      let len = be32(p, cp)
      if len < 0 or cp + 12 + len > n: raise newException(InflateError, "damaged PNG chunk")
      let a = cp
      cp += 12 + len
      if p[a + 4] == 'I' and p[a + 5] == 'D' and p[a + 6] == 'A' and p[a + 7] == 'T':
        if len > 0: return (pointer(addr p[a + 8]), len)
      elif p[a + 4] == 'I' and p[a + 5] == 'E' and p[a + 6] == 'N' and p[a + 7] == 'D':
        break
    (nil, 0)
  var z = initInflater(pieces)
  var px = newSeq[uint32](w)
  let pxp = cast[ptr UncheckedArray[uint32]](addr px[0])
  let passes = if interlace == 1:
      @[(0, 0, 8, 8), (4, 0, 8, 8), (0, 4, 4, 8), (2, 0, 4, 4), (0, 2, 2, 4), (1, 0, 2, 2), (0, 1, 1, 2)]
    else: @[(0, 0, 1, 1)]
  var rowsDone = 0
  for (x0, y0, dx, dy) in passes:
    let pw = (w - x0 + dx - 1) div dx
    let ph = (h - y0 + dy - 1) div dy
    if pw <= 0 or ph <= 0: continue
    let stride = (pw * L.channels * depth + 7) div 8
    var raw = newSeq[byte](stride + 1)
    var prev = newSeq[byte](stride)
    var line = newSeq[byte](stride)
    # (the pixels wanted of a row of this pass)
    let i0 = max(0, (s.ax.lo - x0 + dx - 1) div dx)
    let i1 = min(pw, (s.ax.hi - x0 + dx - 1) div dx)
    for j in 0 ..< ph:
      let y = y0 + j * dy
      if interlace == 0 and y >= s.ay.hi: return       # (the rest is not wanted)
      if z.inflateRead(addr raw[0], stride + 1) < stride + 1: fail("PNG data ends too soon")
      if not pngUnfilter(int(raw[0]), cast[ptr UncheckedArray[byte]](addr raw[1]),
                         cast[ptr UncheckedArray[byte]](addr line[0]),
                         cast[ptr UncheckedArray[byte]](addr prev[0]), stride, L.bpp):
        fail("bad PNG filter")
      if y >= s.ay.lo and y < s.ay.hi and i1 > i0:
        pngRowPixels(L, cast[ptr UncheckedArray[byte]](addr line[0]), i0, i1, pxp, x0, dx)
        if interlace == 0: s.put(y, pxp)
        else: s.putEvery(y, pxp, x0 + i0 * dx, dx, i1 - i0)
      swap(prev, line)
      inc rowsDone
      if (rowsDone and 31) == 0:
        s.tick(if interlace == 0: rowsDone / s.ay.hi else: rowsDone / (2 * h))

proc readBmp(m: Mapped; s: var Sink) =
  var L: BmpLayout
  let err = bmpLayout(m.p, m.n, high(int), L)
  if err.len > 0: fail(err)
  var px = newSeq[uint32](L.w)
  let pxp = cast[ptr UncheckedArray[uint32]](addr px[0])
  # (in the file's order: a bottom-up one from its last row up)
  let count = s.ay.hi - s.ay.lo
  for k in 0 ..< count:
    let y = if L.topDown: s.ay.lo + k else: s.ay.hi - 1 - k
    bmpRow(L, m.p, y, s.ax.lo, s.ax.hi, pxp)
    s.put(y, pxp)
    if (k and 63) == 63: s.tick(k / count)

proc readTga(m: Mapped; s: var Sink) =
  let t = tgaInfo(m.bytesOf, high(int))
  let w = t.w
  let h = t.h
  let pb = t.pb
  let p = m.p
  let n = m.n
  let fromBottom = (t.desc and 0x20) == 0
  let mirrored = (t.desc and 0x10) != 0
  let noAlpha = t.bpp == 32 and (t.desc and 15) == 0
  var px = newSeq[uint32](w)
  var tmp = newSeq[uint32](w)
  let pxp = cast[ptr UncheckedArray[uint32]](addr px[0])
  # the file's rows wanted (the first at the bottom, when they go up)
  let f0 = if fromBottom: h - s.ay.hi else: s.ay.lo
  let f1 = if fromBottom: h - s.ay.lo else: s.ay.hi
  var pos = t.pos
  var left = 0                       # (a run-length packet: pixels left of it)
  var isRun = false
  var runPx = 0'u32
  for fr in 0 ..< f1:
    if t.kind < 9:
      if fr < f0: continue
      pos = t.pos + fr * w * pb
      if pos + w * pb > n: fail("TGA: cut short")
      for x in 0 ..< w: tmp[x] = t.tgaPixel(m.bytesOf, pos + x * pb)
    else:
      for x in 0 ..< w:
        if left == 0:
          if pos >= n: fail("TGA: cut short")
          let head = ord(p[pos])
          inc pos
          left = (head and 0x7F) + 1
          isRun = (head and 0x80) != 0
          if isRun:
            if pos + pb > n: fail("TGA: cut short")
            runPx = t.tgaPixel(m.bytesOf, pos)
            pos += pb
          elif pos + left * pb > n: fail("TGA: cut short")
        if isRun: tmp[x] = runPx
        else:
          tmp[x] = t.tgaPixel(m.bytesOf, pos)
          pos += pb
        dec left
      if fr < f0: continue
    for x in 0 ..< w:
      var c = tmp[if mirrored: w - 1 - x else: x]
      if noAlpha: c = c or 0xFF000000'u32
      px[x] = c
    s.put(if fromBottom: h - 1 - fr else: fr, pxp)
    if (fr and 63) == 63: s.tick(fr / f1)

# -- TIFF: strips a row at a time ---------------------------------------------------------------------

type
  Lzw = object
    ## TIFF's LZW a few bytes at a time (as `lzwTiffDecode` does it whole).
    src: ptr UncheckedArray[byte]
    n, bitPos: int
    prefix: array[4096, int16]
    suffix, first: array[4096, byte]
    lens: array[4096, int32]
    next, width, prev: int
    pend: array[4100, byte]
    pendAt, pendLen: int
    done: bool

  Strip = object
    ## A strip read row by row.
    comp: int
    p: ptr UncheckedArray[byte]
    n, at: int
    z: Inflater
    lzw: ref Lzw
    runLeft, litLeft: int        # (PackBits)
    runByte: byte

proc initLzw(z: var Lzw; p: ptr UncheckedArray[byte]; n: int) =
  z.src = p
  z.n = n
  for i in 0 .. 255:
    z.suffix[i] = byte(i)
    z.first[i] = byte(i)
    z.lens[i] = 1
  z.next = 258
  z.width = 9
  z.prev = -1

proc lzwRead(z: var Lzw; dst: ptr UncheckedArray[byte]; count: int) =
  ## `count` bytes (zeros where the data ends).
  var got = 0
  template emit(code: int) =
    let L = int(z.lens[code])
    var c = code
    for j in countdown(L - 1, 0):
      z.pend[j] = z.suffix[c]
      c = int(z.prefix[c])
    z.pendAt = 0
    z.pendLen = L
  while got < count:
    if z.pendAt < z.pendLen:
      let k = min(z.pendLen - z.pendAt, count - got)
      copyMem(addr dst[got], addr z.pend[z.pendAt], k)
      z.pendAt += k
      got += k
      continue
    if z.done or z.bitPos + z.width > z.n * 8:
      z.done = true
      zeroMem(addr dst[got], count - got)
      return
    let b = z.bitPos shr 3
    let v = (int(z.src[b]) shl 16) or (if b + 1 < z.n: int(z.src[b + 1]) shl 8 else: 0) or
            (if b + 2 < z.n: int(z.src[b + 2]) else: 0)
    let code = (v shr (24 - (z.bitPos and 7) - z.width)) and ((1 shl z.width) - 1)
    z.bitPos += z.width
    if code == 256:
      z.next = 258
      z.width = 9
      z.prev = -1
      continue
    if code == 257:
      z.done = true
      continue
    if z.prev < 0:
      if code > 255: raise newException(FormatError, "TIFF: bad LZW data")
      emit(code)
    elif code < z.next:
      emit(code)
      if z.next < 4096:
        z.prefix[z.next] = int16(z.prev)
        z.suffix[z.next] = z.first[code]
        z.first[z.next] = z.first[z.prev]
        z.lens[z.next] = z.lens[z.prev] + 1
        inc z.next
    else:
      if z.prev >= z.next or z.lens[z.prev] == 0: raise newException(FormatError, "TIFF: bad LZW data")
      emit(z.prev)
      z.pend[z.pendLen] = z.first[z.prev]
      inc z.pendLen
      if z.next < 4096:
        z.prefix[z.next] = int16(z.prev)
        z.suffix[z.next] = z.first[z.prev]
        z.first[z.next] = z.first[z.prev]
        z.lens[z.next] = z.lens[z.prev] + 1
        inc z.next
    if z.next + 1 > (1 shl z.width) - 1 and z.width < 12: inc z.width
    z.prev = code

proc openStrip(m: Mapped; t: TiffInfo; k: int): Strip =
  let a = t.offs[k]
  let b = a + t.lens[k]
  if a < 0 or b > m.n or b < a: fail("TIFF: damaged data")
  result = Strip(comp: t.comp, p: cast[ptr UncheckedArray[byte]](addr m.p[a]), n: b - a)
  case t.comp
  of 5:
    result.lzw = new Lzw
    result.lzw[].initLzw(result.p, result.n)
  of 8, 32946:
    var given = false
    let sp = result.p
    let sn = result.n
    result.z = initInflater(proc (): tuple[p: pointer; n: int] {.closure, gcsafe.} =
      if given or sn == 0: result = (nil, 0); return
      given = true
      (pointer(sp), sn))
  else: discard

proc readRow(st: var Strip; dst: var seq[byte]; count: int) =
  ## The next `count` bytes of the strip (zeros past its data).
  let o = cast[ptr UncheckedArray[byte]](addr dst[0])
  case st.comp
  of 1:
    let k = max(0, min(count, st.n - st.at))
    if k > 0: copyMem(addr o[0], addr st.p[st.at], k)
    if k < count: zeroMem(addr o[k], count - k)
    st.at += count
  of 5: st.lzw[].lzwRead(o, count)
  of 8, 32946:
    let got = try: st.z.inflateRead(o, count) except InflateError: fail("TIFF: damaged ZIP data")
    if got < count: zeroMem(addr o[got], count - got)
  else:
    var got = 0
    while got < count:
      if st.runLeft > 0:
        let k = min(st.runLeft, count - got)
        for i in 0 ..< k: o[got + i] = st.runByte
        st.runLeft -= k
        got += k
      elif st.litLeft > 0:
        let k = min(st.litLeft, count - got)
        copyMem(addr o[got], addr st.p[st.at], k)
        st.at += k
        st.litLeft -= k
        got += k
      else:
        if st.at >= st.n: fail("PackBits data cut short")
        let c = int(st.p[st.at])
        inc st.at
        if c < 128:
          if st.at + c + 1 > st.n: fail("PackBits data cut short")
          st.litLeft = c + 1
        elif c > 128:
          if st.at >= st.n: fail("PackBits data cut short")
          st.runByte = st.p[st.at]
          inc st.at
          st.runLeft = 257 - c

proc readTiff(m: Mapped; s: var Sink) =
  let t = tiffInfo(m.bytesOf, high(int))
  tiffCheck(t, m.n)
  let w = t.w
  let h = t.h
  let spp = t.spp
  let lo = s.ax.lo
  let hi = s.ax.hi
  var px = newSeq[uint32](w)
  let pxp = cast[ptr UncheckedArray[uint32]](addr px[0])
  var samples = newSeq[uint16](w * spp)
  if not t.tiled:
    # strips: each plane's read along, row by row
    var raws = newSeq[seq[byte]](t.planes)
    for r in raws.mitems: r = newSeq[byte](t.rowBytes)
    for sy in 0 ..< t.down:
      let r0 = sy * t.tileH
      let r1 = min(h, r0 + t.tileH)
      if r1 <= s.ay.lo: continue
      if r0 >= s.ay.hi: break
      var strips = newSeq[Strip](t.planes)
      for pl in 0 ..< t.planes:
        let k = pl * t.down + sy
        if k < t.offs.len: strips[pl] = openStrip(m, t, k)
      for y in r0 ..< min(r1, s.ay.hi):
        for pl in 0 ..< t.planes:
          if strips[pl].p != nil: strips[pl].readRow(raws[pl], t.rowBytes)
          else: zeroMem(addr raws[pl][0], t.rowBytes)
          tiffUnpredict(t, raws[pl])
        if y < s.ay.lo: continue
        for x in lo ..< hi:
          for pl in 0 ..< t.planes:
            for c in 0 ..< t.perPixel:
              samples[x * spp + (if t.planar == 2: pl else: c)] =
                uint16(t.tiffSample(raws[pl], 0, x * t.perPixel + c))
          px[x] = t.tiffPixel(samples, x * spp)
        s.put(y, pxp)
        if (y and 31) == 31: s.tick(y / s.ay.hi)
  else:
    # tiles: a row of them at a time
    if t.tileH.int64 * w.int64 * 4 > 1'i64 shl 30: fail("TIFF: its tiles are too big")
    var band = newSeq[uint32](t.tileH * w)
    var one = newSeq[uint16](spp)
    for ty in 0 ..< t.down:
      let r0 = ty * t.tileH
      let r1 = min(h, r0 + t.tileH)
      if r1 <= s.ay.lo: continue
      if r0 >= s.ay.hi: break
      for tx in 0 ..< t.across:
        let c0 = tx * t.tileW
        let c1 = min(w, c0 + t.tileW)
        if c1 <= lo or c0 >= hi: continue
        var raws = newSeq[seq[byte]](t.planes)
        for pl in 0 ..< t.planes:
          let k = pl * t.across * t.down + ty * t.across + tx
          raws[pl] = if k < t.offs.len: tiffPiece(m.bytesOf, t, k) else: newSeq[byte](t.rowBytes * t.tileH)
        for y in 0 ..< r1 - r0:
          for x in max(c0, lo) ..< min(c1, hi):
            for pl in 0 ..< t.planes:
              for c in 0 ..< t.perPixel:
                one[if t.planar == 2: pl else: c] =
                  uint16(t.tiffSample(raws[pl], y * t.rowBytes, (x - c0) * t.perPixel + c))
            band[y * w + x] = t.tiffPixel(one, 0)
      for y in max(r0, s.ay.lo) ..< min(r1, s.ay.hi):
        s.put(y, cast[ptr UncheckedArray[uint32]](addr band[(y - r0) * w]))
      s.tick(r1 / s.ay.hi)

# ---- what kind of file -------------------------------------------------------------------------------

proc kindOf(m: Mapped; path: string): string =
  let p = m.p
  let n = m.n
  if n >= 8 and p[0] == '\x89' and p[1] == 'P' and p[2] == 'N' and p[3] == 'G': "png"
  elif n >= 4 and p[0] == '\xFF' and p[1] == '\xD8': "jpeg"
  elif n >= 2 and p[0] == 'B' and p[1] == 'M': "bmp"
  elif n >= 8 and ((p[0] == 'I' and p[1] == 'I' and p[2] == '*' and p[3] == '\0') or
                   (p[0] == 'M' and p[1] == 'M' and p[2] == '\0' and p[3] == '*')): "tiff"
  elif path.splitFile.ext.toLowerAscii in [".tga", ".icb", ".vda", ".vst"]: "tga"
  else: ""

proc storedSize(m: Mapped; kind: string): tuple[w, h, orientation: int] =
  ## The picture's size as stored, and how it is turned (JPEG's EXIF).
  result.orientation = 1
  case kind
  of "png":
    if m.n < 24 or m.p[12] != 'I' or m.p[13] != 'H': fail("damaged PNG header")
    result.w = be32(m.p, 16)
    result.h = be32(m.p, 20)
  of "jpeg":
    let L = jpegLayout(m.p, m.n)
    result = (L.w, L.h, L.orientation)
  of "bmp":
    var L: BmpLayout
    let err = bmpLayout(m.p, m.n, high(int), L, scanAlpha = false)
    if err.len > 0: fail(err)
    result.w = L.w
    result.h = L.h
  of "tiff":
    let t = tiffInfo(m.bytesOf, high(int))
    result.w = t.w
    result.h = t.h
  of "tga":
    let t = tgaInfo(m.bytesOf, high(int))
    result.w = t.w
    result.h = t.h
  else: fail("not a picture this can read in parts")
  if result.w <= 0 or result.h <= 0 or result.w > SideLimit or result.h > SideLimit or
     result.w.int64 * result.h.int64 > PixelLimit:
    fail("bad picture size")

template guarded(body: untyped) =
  ## (the decoders' errors as `BigPictureError`; Cancel as it is)
  try:
    body
  except BusyCancelled, BigPictureError:
    raise
  except CatchableError as e:
    raise newException(BigPictureError, e.msg)
  finally:
    if onUiThread(): busyFraction = -1

proc decodeInto(m: Mapped; kind: string; ax, ay: Axis; jpegScale, orientation: int;
                progress: BigProgress): Bitmap =
  ## The rows `ay` x `ax` of the picture (as stored), summed into what is
  ## made, turned.
  let interlaced = kind == "png" and m.n > 28 and ord(m.p[28]) == 1
  var s = initSink(ax, ay, unordered = interlaced, progress = progress)
  case kind
  of "png": readPng(m, s)
  of "bmp": readBmp(m, s)
  of "tga": readTga(m, s)
  of "tiff": readTiff(m, s)
  else:
    let sp = addr s
    let told: JpegProgress = proc (f: float) {.closure, gcsafe.} =
      if progress != nil: progress(f)
      if onUiThread(): busyFraction = f
    jpegBands(m.p, m.n, jpegScale, ay.lo, ay.hi, ax.lo, ax.hi,
              proc (y: int; row: ptr UncheckedArray[uint32]) {.closure, gcsafe.} = sp[].put(y, row),
              told, coefficientBudget)
  if progress != nil: progress(1.0)
  exifTurned(s.finish(), orientation)

# ---- the API ------------------------------------------------------------------------------------------

proc fittedSize*(w, h, maxW, maxH: int): tuple[w, h: int] =
  ## The size a `w` x `h` picture is made to fit in `maxW` x `maxH`, its
  ## shape kept (as `thumbnail` and `readScaled` make it): as it is when it
  ## fits.
  if w <= maxW and h <= maxH: return (w, h)
  let k = min(maxW / w, maxH / h)
  (max(1, int(w.float * k)), max(1, int(h.float * k)))

proc bigPictureInfo*(path: string): tuple[w, h: int; kind: string] =
  ## The size of the picture in `path` as it is shown (a turned JPEG:
  ## turned) and its kind -- "png", "jpeg", "bmp", "tiff" or "tga" -- from
  ## its header (quick, whatever its size). (0, 0, "") when it is not one
  ## of these or cannot be read.
  try:
    let m = openMapped(path)
    try:
      let kind = kindOf(m, path)
      if kind.len == 0: return
      let (w, h, o) = storedSize(m, kind)
      result = if o >= 5: (h, w, kind) else: (w, h, kind)
    finally: m.close()
  except CatchableError:
    result = (0, 0, "")

proc flips(o: int): tuple[x, y, turn: bool] =
  ## (which sides of the picture as stored run the other way when it is
  ## turned by EXIF orientation `o`, and whether they swap)
  (o in [2, 3, 7, 8], o in [3, 4, 6, 7], o >= 5)

proc readScaled*(path: string; maxW, maxH: int; progress: BigProgress = nil): Bitmap =
  ## The whole picture in `path` made to fit in `maxW` x `maxH`, each new
  ## pixel the average of those it covers (the same pixels as
  ## `thumbnail(<the picture decoded whole>, maxW, maxH)`; a JPEG made much
  ## smaller is read at an eighth first, as `loadPicture` does): read a
  ## band at a time, the memory about one band and the picture made. The
  ## picture as it is when it fits. Raises `BigPictureError` (or
  ## `BusyCancelled`).
  guarded:
    let m = openMapped(path)
    try:
      let kind = kindOf(m, path)
      if kind.len == 0: fail("not a picture this can read in parts")
      var (w, h, o) = storedSize(m, kind)
      var jpegScale = 1
      if kind == "jpeg":
        # (much bigger than wanted: only each block's average, as `loadPicture` decides it)
        if w div 8 >= maxW or h div 8 >= maxH: jpegScale = 8
        w = (w + jpegScale - 1) div jpegScale
        h = (h + jpegScale - 1) div jpegScale
      let f = flips(o)
      let (tw, th) = if f.turn: (h, w) else: (w, h)
      let (ow, oh) = fittedSize(tw, th, maxW, maxH)
      let (rw, rh) = if f.turn: (oh, ow) else: (ow, oh)
      result = decodeInto(m, kind, scaledAxis(w, rw, f.x), scaledAxis(h, rh, f.y), jpegScale, o, progress)
    finally: m.close()

proc readRegion*(path: string; x, y, w, h: int; scale = 1; progress: BigProgress = nil): Bitmap =
  ## The part `x`, `y`, `w` x `h` of the picture in `path` (in its pixels
  ## as shown; clipped to it), at full size -- or at 1/`scale`, each
  ## `scale` x `scale` square averaged. Read a band at a time: the memory
  ## about the part and one band (a progressive JPEG: also 8 bytes a block
  ## of the whole). Raises `BigPictureError` (or `BusyCancelled`), also
  ## when the part is outside the picture.
  guarded:
    let m = openMapped(path)
    try:
      let kind = kindOf(m, path)
      if kind.len == 0: fail("not a picture this can read in parts")
      let (sw, sh, o) = storedSize(m, kind)
      let f = flips(o)
      let (tw, th) = if f.turn: (sh, sw) else: (sw, sh)
      let x0 = max(0, x)
      let y0 = max(0, y)
      let x1 = min(tw, x + w)
      let y1 = min(th, y + h)
      if x1 <= x0 or y1 <= y0: fail("the part is outside the picture")
      let s = max(1, scale)
      let ax = if f.turn: regionAxis(sw, y0, y1 - y0, s, f.x) else: regionAxis(sw, x0, x1 - x0, s, f.x)
      let ay = if f.turn: regionAxis(sh, x0, x1 - x0, s, f.y) else: regionAxis(sh, y0, y1 - y0, s, f.y)
      result = decodeInto(m, kind, ax, ay, 1, o, progress)
    finally: m.close()
