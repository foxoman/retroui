## Pictures from files: PNG, JPEG and BMP decoded in plain Nim (JPEG by
## the platform first where it has a faster decoder), every other kind
## (WebP, GIF, HEIC...) by the platform where it offers one (Android, iOS).
## Plus `thumbnail` to make small, smooth copies.
##
## .. code-block:: nim
##   let photo = loadPicture("/sdcard/DCIM/Camera/IMG_0001.jpg", 1600, 1600)
##   if photo != nil: drawBitmap(rect(10, 10, 160, 120), photo)

import gfx, codec, jpeg, appicon, bigpicture
import uirelays/services

export jpeg.decodeJpeg, jpeg.jpegSize, jpeg.JpegError

type ImageError* = object of CatchableError
  ## A picture that cannot be read: not of a kind decoded here, damaged,
  ## or too large (`maxPicturePixels`).

var maxPicturePixels* = 120_000_000
  ## Larger pictures are refused (rather than taking gigabytes): a damaged
  ## or hostile file cannot make the app run out of memory.

proc fail(msg: string) {.noreturn.} = raise newException(ImageError, msg)

proc be32(s: string; i: int): int =
  (ord(s[i]) shl 24) or (ord(s[i+1]) shl 16) or (ord(s[i+2]) shl 8) or ord(s[i+3])
proc le16(s: string; i: int): int = ord(s[i]) or (ord(s[i+1]) shl 8)
proc le32(s: string; i: int): int =
  int(cast[int32](uint32(ord(s[i])) or (uint32(ord(s[i+1])) shl 8) or
                  (uint32(ord(s[i+2])) shl 16) or (uint32(ord(s[i+3])) shl 24)))

# ---- PNG ------------------------------------------------------------------------

{.push boundChecks: off, overflowChecks: off.}

proc decodePng*(data: string; hi: ptr seq[uint16] = nil): Bitmap =
  ## Any PNG: gray, RGB, palette, with alpha, 1 to 16 bits, interlaced.
  ## With `hi`, a 16-bit one also gives its pixels at 16 bits there (R G B
  ## A each; empty when it is not 16-bit).
  if data.len < 33 or data[0 .. 7] != "\x89PNG\r\n\x1a\n": fail("not a PNG file")
  var w, h, depth, ctype, interlace = 0
  var palette: seq[uint32]
  var trns: string
  var idat: seq[byte]
  var p = 8
  while p + 8 <= data.len:
    let n = be32(data, p)
    let kind = data[p + 4 ..< p + 8]
    if n < 0 or p + 12 + n > data.len: fail("damaged PNG chunk")
    if kind == "IDAT":
      # (the image data gathered without copies on the way)
      if n > 0:
        let at = idat.len
        idat.setLen(at + n)
        copyMem(addr idat[at], unsafeAddr data[p + 8], n)
      p += 12 + n
      continue
    let body = data[p + 8 ..< p + 8 + n]
    case kind
    of "IHDR":
      if n < 13: fail("damaged PNG header")
      w = be32(body, 0)
      h = be32(body, 4)
      depth = ord(body[8])
      ctype = ord(body[9])
      interlace = ord(body[12])
    of "PLTE":
      for i in 0 ..< n div 3:
        palette.add 0xFF000000'u32 or (uint32(ord(body[3*i])) shl 16) or
                    (uint32(ord(body[3*i+1])) shl 8) or uint32(ord(body[3*i+2]))
    of "tRNS": trns = body
    of "IEND": break
    else: discard
    p += 12 + n
  if w <= 0 or h <= 0 or w > 65535 or h > 65535 or w * h > maxPicturePixels:
    fail("bad PNG size")
  var L: PngLayout
  let err = pngLayout(w, h, depth, ctype, interlace, palette, trns, L)
  if err.len > 0: fail(err)
  let channels = L.channels
  # the most the data can be: every row of every pass with its filter byte
  let most = (w * channels * depth + 7) div 8 * h + 2 * h + 64 * (w + h) + 1024
  var raw = try: zlibDecompress(idat, most)
            except InflateError as e: fail("PNG data: " & e.msg)
  # (let go of now, before the pixels are made -- not `idat = @[]`: Nim
  # 2.2 made that a bare overwrite here, and every PNG read leaked its data)
  reset(idat)
  result = newBitmap(w, h)
  let deep = depth == 16 and hi != nil and ctype != 3
  if hi != nil: hi[] = (if deep: newSeq[uint16](w * h * 4) else: @[])
  let bpp = L.bpp
  var pos = 0
  let passes = if interlace == 1:
      @[(0, 0, 8, 8), (4, 0, 8, 8), (0, 4, 4, 8), (2, 0, 4, 4), (0, 2, 2, 4),
        (1, 0, 2, 2), (0, 1, 1, 2)]
    else: @[(0, 0, 1, 1)]
  let op = cast[ptr UncheckedArray[uint32]](addr result.px[0])
  for (x0, y0, dx, dy) in passes:
    let pw = (w - x0 + dx - 1) div dx
    let ph = (h - y0 + dy - 1) div dy
    if pw <= 0 or ph <= 0: continue
    let stride = (pw * channels * depth + 7) div 8
    var prev = newSeq[byte](stride)
    var line = newSeq[byte](stride)
    for j in 0 ..< ph:
      if pos + 1 + stride > raw.len: fail("PNG data ends too soon")
      # (the filter undone, the row's pixels made: `retroui/bigpicture`'s, which
      # reads big pictures a row at a time)
      if not pngUnfilter(int(raw[pos]), cast[ptr UncheckedArray[byte]](addr raw[pos + 1]),
                         cast[ptr UncheckedArray[byte]](addr line[0]),
                         cast[ptr UncheckedArray[byte]](addr prev[0]), stride, bpp):
        fail("bad PNG filter")
      pos += 1 + stride
      let y = y0 + j * dy
      let row = y * w
      pngRowPixels(L, cast[ptr UncheckedArray[byte]](addr line[0]), 0, pw,
                   cast[ptr UncheckedArray[uint32]](addr op[row]), x0, dx)
      if deep:
        # (the 16 bits as they are)
        for i in 0 ..< pw:
          let x = x0 + i * dx
          let px = op[row + x]
          template s16(c: int): uint16 =
            (uint16(line[(i * channels + c) * 2]) shl 8) or uint16(line[(i * channels + c) * 2 + 1])
          let o = (row + x) * 4
          case ctype
          of 0, 4:
            let g = s16(0)
            hi[][o] = g; hi[][o + 1] = g; hi[][o + 2] = g
            hi[][o + 3] = if ctype == 4: s16(1) elif (px shr 24) == 0: 0'u16 else: 65535'u16
          else:
            hi[][o] = s16(0); hi[][o + 1] = s16(1); hi[][o + 2] = s16(2)
            hi[][o + 3] = if ctype == 6: s16(3) elif (px shr 24) == 0: 0'u16 else: 65535'u16
      swap(prev, line)
  result.changed()

# ---- BMP ------------------------------------------------------------------------

{.pop.}

proc decodeBmp*(data: string): Bitmap =
  ## Uncompressed BMP: 1, 4, 8 bits with a palette, 16, 24 and 32 bits.
  if data.len < 54 or data[0 .. 1] != "BM": fail("not a BMP file")
  let p = cast[ptr UncheckedArray[char]](unsafeAddr data[0])
  var L: BmpLayout
  let err = bmpLayout(p, data.len, maxPicturePixels, L)
  if err.len > 0: fail(err)
  result = newBitmap(L.w, L.h)
  # (each row: `retroui/bigpicture`'s, which reads big ones a row at a time)
  for j in 0 ..< L.h:
    bmpRow(L, p, j, 0, L.w, cast[ptr UncheckedArray[uint32]](addr result.px[j * L.w]))
  result.changed()

# ---- scaling and loading ------------------------------------------------------------

proc thumbnail*(b: Bitmap; maxW, maxH: int): Bitmap =
  ## A copy of `b` that fits in `maxW` x `maxH`, averaging the pixels each
  ## new pixel covers (smooth, not jagged). `b` itself when it fits.
  if b == nil or (b.w <= maxW and b.h <= maxH): return b
  let k = min(maxW / b.w, maxH / b.h)
  let w = max(1, int(b.w.float * k))
  let h = max(1, int(b.h.float * k))
  result = newBitmap(w, h)
  for y in 0 ..< h:
    let sy0 = y * b.h div h
    let sy1 = max(sy0 + 1, (y + 1) * b.h div h)
    for x in 0 ..< w:
      let sx0 = x * b.w div w
      let sx1 = max(sx0 + 1, (x + 1) * b.w div w)
      var a, r, g, bl, n = 0'u32
      for sy in sy0 ..< sy1:
        for sx in sx0 ..< sx1:
          let p = b.px[sy * b.w + sx]
          a += p shr 24
          r += (p shr 16) and 255
          g += (p shr 8) and 255
          bl += p and 255
          inc n
      result.px[y * w + x] = ((a div n) shl 24) or ((r div n) shl 16) or
                             ((g div n) shl 8) or (bl div n)
  result.changed()

proc pictureSize*(path: string): tuple[w, h: int] =
  ## The size of a PNG, JPEG, GIF or BMP picture from its header (0, 0 when
  ## it is not known), without decoding it.
  try:
    var f: File
    if not open(f, path): return
    defer: f.close()
    var head = newString(65536)
    head.setLen(f.readBuffer(addr head[0], head.len))
    if head.len >= 24 and head[0 .. 7] == "\x89PNG\r\n\x1a\n":
      return (be32(head, 16), be32(head, 20))
    if head.len >= 10 and head[0 .. 2] == "GIF":
      return (le16(head, 6), le16(head, 8))
    if head.len >= 26 and head[0 .. 1] == "BM":
      return (le32(head, 18), abs(le32(head, 22)))
    if head.len >= 4 and head[0] == '\xFF' and head[1] == '\xD8':
      return jpegSize(head)
  except CatchableError: discard

const pictureKinds* = [".png", ".bmp", ".jpg", ".jpeg", ".gif", ".webp",
                       ".heic", ".heif", ".ico"]
  ## Extensions `loadPicture` may read (PNG, JPEG and BMP everywhere, the
  ## rest where the platform decodes them).

var bigPictureBytes* = 24 shl 20
  ## PNG, JPEG and BMP pictures that would take more than this decoded
  ## whole -- or, over 2 MP, more than twice the pixels asked for -- are
  ## read by `loadPicture` a band at a time (`retroui/bigpicture`): only the
  ## picture made is in memory, however big the file's.

proc readBigPicture*(path: string; maxW, maxH: int): tuple[read: bool; b: Bitmap] =
  ## A big picture (PNG, JPEG, BMP, TIFF, TGA: more than `bigPictureBytes`
  ## decoded, or twice the pixels asked for) made to fit in `maxW` x
  ## `maxH` as it is read, a band at a time (`retroui/bigpicture`); `read`
  ## false when it is not one to read so (`b` nil, too, when what is made
  ## would be more than `maxPicturePixels`). Raises `BigPictureError`.
  let (w, h, kind) = bigPictureInfo(path)
  if kind.len == 0: return
  let px = w.int64 * h.int64
  # (small pictures -- 2 MP and less -- are decoded whole: quicker, and little)
  if px * 4 <= bigPictureBytes.int64 and
     (px <= 2 * max(1, maxW).int64 * max(1, maxH).int64 or px <= 2_000_000): return
  result.read = true
  let (ow, oh) = fittedSize(w, h, maxW, maxH)
  if ow.int64 * oh.int64 > maxPicturePixels.int64: return    # (that big: refused, as ever)
  result.b = readScaled(path, maxW, maxH)

proc loadPicture*(path: string; maxW = 4096; maxH = 4096): Bitmap =
  ## The picture in the file `path`, no larger than `maxW` x `maxH`; nil
  ## when it cannot be read or decoded here. (Kinds of file a program
  ## taught it, `addPictureReader`, first.) A big PNG, JPEG or BMP is read
  ## a band at a time (`bigPictureBytes`).
  result = nil         # (a value at once: see tools/writecheck.py)
  try:
    let rd = pictureReaderFor(path)
    if rd != nil:
      let b = rd(path, maxW, maxH)
      result = (if b == nil: nil else: thumbnail(b, maxW, maxH)); return
    var head = newString(8)
    var f: File
    if not open(f, path):
      # not a file this app can open (a document of another app, on
      # Android): the system may still decode it
      var d = systemRelays.decodeImage(path, maxW, maxH)
      if d.w <= 0 or d.h <= 0 or d.px.len < d.w * d.h: result = nil; return
      result = newBitmap(d.w, d.h)
      result.px = move d.px
      result.changed()
      result = thumbnail(result, maxW, maxH); return
    let n = f.readBuffer(addr head[0], 8)
    f.close()
    if n >= 8 and head == "\x89PNG\r\n\x1a\n":
      let big = readBigPicture(path, maxW, maxH)
      if big.read: result = big.b; return
      result = thumbnail(decodePng(readFile(path)), maxW, maxH); return
    if n >= 2 and head[0 .. 1] == "BM":
      let big = readBigPicture(path, maxW, maxH)
      if big.read: result = big.b; return
      result = thumbnail(decodeBmp(readFile(path)), maxW, maxH); return
    var d = systemRelays.decodeImage(path, maxW, maxH)
    if d.w > 0 and d.h > 0 and d.px.len >= d.w * d.h:
      result = newBitmap(d.w, d.h)
      result.px = move d.px
      result.changed()
      result = thumbnail(result, maxW, maxH); return
    if n >= 2 and head[0] == '\xFF' and head[1] == '\xD8':
      let big = readBigPicture(path, maxW, maxH)
      if big.read: result = big.b; return
      let data = readFile(path)
      let (w, h) = jpegSize(data)
      # much bigger than wanted: only the blocks' averages (8 times faster)
      let scale = if w div 8 >= maxW or h div 8 >= maxH: 8 else: 1
      result = thumbnail(decodeJpeg(data, scale), maxW, maxH); return
  except CatchableError:
    result = nil

proc pngColors*(px: openArray[uint32]): tuple[gray, alpha: bool] =
  ## Whether a picture is all grays, whether it has transparency (what a
  ## PNG of it must keep).
  result.gray = true
  for p in px:
    if (p shr 24) != 255: result.alpha = true
    if result.gray and (((p shr 16) and 255) != ((p shr 8) and 255) or ((p shr 8) and 255) != (p and 255)):
      result.gray = false
    if result.alpha and not result.gray: return

proc paeth(a, bb, c: int): int {.inline.} =
  ## (PNG's Paeth guess: the neighbour nearest left + up - up-left)
  let pa = abs(bb - c)            # (|p - a|, p = a + bb - c)
  let pb = abs(a - c)
  let pc = abs(a + bb - 2 * c)
  if pa <= pb and pa <= pc: a elif pb <= pc: bb else: c

proc encodePng*(b: Bitmap; level = 6; dpi = 0; alpha = -1; gray = -1): string =
  ## `b` as the bytes of a PNG file: gray or color, with transparency when
  ## it has some (`alpha`, `gray`: 0 no, 1 yes, -1 as the picture is); each
  ## row filtered the way that packs best; compressed at `level` (1 quick
  ## .. 9 smallest) on all the cores; `dpi` written (pHYs).
  if b == nil or b.w <= 0 or b.h <= 0: return ""
  let w = b.w
  let h = b.h
  var kinds = (gray: gray == 1, alpha: alpha == 1)
  if alpha < 0 or gray < 0:
    let k = pngColors(b.px)
    if alpha < 0: kinds.alpha = k.alpha
    if gray < 0: kinds.gray = k.gray
  let ch = (if kinds.gray: 1 else: 3) + (if kinds.alpha: 1 else: 0)
  let ctype = if kinds.gray: (if kinds.alpha: 4 else: 0) else: (if kinds.alpha: 6 else: 2)
  let stride = 1 + w * ch
  var raw = newSeqUninit[byte](stride * h)
  let rp = cast[ptr UncheckedArray[byte]](addr raw[0])
  let src = cast[ptr UncheckedArray[uint32]](unsafeAddr b.px[0])
  # the rows: their bytes, then the filter that leaves the smallest numbers
  let rows = proc (lo, hi: int) =
    {.push boundChecks: off, overflowChecks: off.}
    let rw = w * ch
    var cur = newSeqUninit[byte](rw)
    var up = newSeqUninit[byte](rw)
    var best = newSeqUninit[byte](rw)
    var trial = newSeqUninit[byte](rw)
    # (a template: a proc in here would be a closure of its own, its
    # environment let go on a worker thread)
    template bytesOf(y: int; o: var seq[byte]) =
      let row = y * w
      let op = cast[ptr UncheckedArray[byte]](addr o[0])
      if kinds.gray:
        if kinds.alpha:
          for x in 0 ..< w:
            let p = src[row + x]
            op[2 * x] = byte((p shr 8) and 255); op[2 * x + 1] = byte(p shr 24)
        else:
          for x in 0 ..< w: op[x] = byte((src[row + x] shr 8) and 255)
      elif kinds.alpha:
        for x in 0 ..< w:
          let p = src[row + x]
          op[4 * x] = byte((p shr 16) and 255); op[4 * x + 1] = byte((p shr 8) and 255)
          op[4 * x + 2] = byte(p and 255); op[4 * x + 3] = byte(p shr 24)
      else:
        for x in 0 ..< w:
          let p = src[row + x]
          op[3 * x] = byte((p shr 16) and 255); op[3 * x + 1] = byte((p shr 8) and 255)
          op[3 * x + 2] = byte(p and 255)
    template mag(f: byte): int = (if f < 128: int(f) else: 256 - int(f))
    # (a quick save: Up or Paeth, which suit photos, picked from every
    # fourth byte; else all five tried on all of them)
    let quick = level <= 3 and rw >= 64
    for y in lo ..< hi:
      # (the row above is the one done before, but for a piece's first)
      if y == lo:
        if y > 0: bytesOf(y - 1, up)
        else: zeroMem(addr up[0], rw)
      else: swap(cur, up)
      bytesOf(y, cur)
      let cp = cast[ptr UncheckedArray[byte]](addr cur[0])
      let up0 = cast[ptr UncheckedArray[byte]](addr up[0])
      let at = y * stride
      let op = cast[ptr UncheckedArray[byte]](addr rp[at + 1])
      if quick:
        # (byte 0 has nothing to its left; every fourth after it has)
        var sumUp = mag(byte((int(cp[0]) - int(up0[0])) and 255))
        var sumPa = mag(byte((int(cp[0]) - paeth(0, int(up0[0]), 0)) and 255))
        var i = 4
        while i < rw:
          let x = int(cp[i])
          let bb = int(up0[i])
          sumUp += mag(byte((x - bb) and 255))
          sumPa += mag(byte((x - paeth(int(cp[i - ch]), bb, int(up0[i - ch]))) and 255))
          i += 4
        if sumUp <= sumPa:
          rp[at] = 2
          for i in 0 ..< rw: op[i] = byte((int(cp[i]) - int(up0[i])) and 255)
        else:
          rp[at] = 4
          for i in 0 ..< ch: op[i] = byte((int(cp[i]) - paeth(0, int(up0[i]), 0)) and 255)
          for i in ch ..< rw:
            op[i] = byte((int(cp[i]) - paeth(int(cp[i - ch]), int(up0[i]), int(up0[i - ch]))) and 255)
        continue
      var bestSum = high(int)
      var bestKind = 0
      for kind in 0 .. 4:
        var sum = 0
        let tp = cast[ptr UncheckedArray[byte]](addr trial[0])
        template run(expr: untyped) =
          var i = 0
          while i < rw:
            let x {.inject.} = int(cp[i])
            let a {.inject.} = if i >= ch: int(cp[i - ch]) else: 0
            let bb {.inject.} = int(up0[i])
            let c {.inject.} = if i >= ch: int(up0[i - ch]) else: 0
            let f = byte(expr and 255)
            tp[i] = f
            sum += mag(f)
            if sum >= bestSum: break
            inc i
        case kind
        of 0: run(x)
        of 1: run(x - a)
        of 2: run(x - bb)
        of 3: run(x - (a + bb) div 2)
        else: run(x - paeth(a, bb, c))
        if sum < bestSum:
          bestSum = sum
          bestKind = kind
          swap(best, trial)
      rp[at] = byte(bestKind)
      if rw > 0: copyMem(addr rp[at + 1], addr best[0], rw)
    {.pop.}
  if compressPieces != nil and h > 64: compressPieces(h, rows) else: rows(0, h)
  let z = zlibCompressLevel(raw, level)
  raw = @[]
  # the file: the data in pieces of 8 MB (their checks made at once)
  var o = newStringOfCap(z.len + 256)
  o.add "\x89PNG\r\n\x1a\n"
  proc add32(v: uint32) =
    o.add char((v shr 24) and 255); o.add char((v shr 16) and 255)
    o.add char((v shr 8) and 255); o.add char(v and 255)
  proc chunk(kind: string; data: openArray[byte]) =
    add32(uint32(data.len))
    let at = o.len
    o.add kind
    if data.len > 0:
      let p = o.len
      o.setLen(p + data.len)
      copyMem(addr o[p], unsafeAddr data[0], data.len)
    var c = 0xFFFFFFFF'u32
    for i in at ..< o.len: c = crcStep(c, byte(o[i]))
    add32(c xor 0xFFFFFFFF'u32)
  var ihdr: seq[byte]
  for v in [w, h]:
    ihdr.add [byte((v shr 24) and 255), byte((v shr 16) and 255), byte((v shr 8) and 255), byte(v and 255)]
  ihdr.add [8'u8, byte(ctype), 0, 0, 0]
  chunk("IHDR", ihdr)
  if dpi > 0:
    let ppm = int(dpi.float / 0.0254 + 0.5)
    var ph: seq[byte]
    for v in [ppm, ppm]:
      ph.add [byte((v shr 24) and 255), byte((v shr 16) and 255), byte((v shr 8) and 255), byte(v and 255)]
    ph.add 1
    chunk("pHYs", ph)
  const Piece = 8 shl 20
  # (the checks of the pieces made at once on all the cores)
  let np = (z.len + Piece - 1) div Piece
  var crcs = newSeq[uint32](max(1, np))
  if np > 0:
    let zp = cast[ptr UncheckedArray[byte]](unsafeAddr z[0])
    let cp = cast[ptr UncheckedArray[uint32]](addr crcs[0])
    let zl = z.len
    let crcBody = proc (lo, hi: int) =
      for k in lo ..< hi:
        var c = 0xFFFFFFFF'u32
        for ch in "IDAT": c = crcStep(c, byte(ch))
        for i in k * Piece ..< min(zl, (k + 1) * Piece): c = crcStep(c, zp[i])
        cp[k] = c xor 0xFFFFFFFF'u32
    if compressPieces != nil and np > 1: compressPieces(np, crcBody) else: crcBody(0, np)
  for k in 0 ..< np:
    let a0 = k * Piece
    let e = min(z.len, a0 + Piece)
    add32(uint32(e - a0))
    o.add "IDAT"
    let p0 = o.len
    o.setLen(p0 + e - a0)
    copyMem(addr o[p0], unsafeAddr z[a0], e - a0)
    add32(crcs[k])
  chunk("IEND", [])
  o


proc encodePng16*(w, h: int; px: openArray[uint16]; level = 6; dpi = 0; alpha = true): string =
  ## A 16-bit PNG (RGB, or RGBA with `alpha`) of `px` (R G B A each, w x h):
  ## rows filtered Up (photos pack well), compressed at `level`.
  if w <= 0 or h <= 0 or px.len < w * h * 4: return ""
  let ch = if alpha: 4 else: 3
  let rw = w * ch * 2
  let stride = 1 + rw
  var raw = newSeq[byte](stride * h)
  var prev = newSeq[byte](rw)
  var cur = newSeq[byte](rw)
  for y in 0 ..< h:
    var k = 0
    for x in 0 ..< w:
      let o = (y * w + x) * 4
      for c in 0 ..< ch:
        let v = px[o + c]
        cur[k] = byte(v shr 8)
        cur[k + 1] = byte(v and 255)
        k += 2
    let at = y * stride
    raw[at] = 2                                    # (Up)
    for i in 0 ..< rw: raw[at + 1 + i] = byte((int(cur[i]) - int(prev[i])) and 255)
    swap(prev, cur)
  let z = zlibCompressLevel(raw, level)
  var o = "\x89PNG\r\n\x1a\n"
  proc add32(v: uint32) =
    o.add char((v shr 24) and 255); o.add char((v shr 16) and 255)
    o.add char((v shr 8) and 255); o.add char(v and 255)
  proc chunk(kind: string; data: openArray[byte]) =
    add32(uint32(data.len))
    let at = o.len
    o.add kind
    for v in data: o.add char(v)
    var c = 0xFFFFFFFF'u32
    for i in at ..< o.len: c = crcStep(c, byte(o[i]))
    add32(c xor 0xFFFFFFFF'u32)
  var ihdr: seq[byte]
  for v in [w, h]:
    ihdr.add [byte((v shr 24) and 255), byte((v shr 16) and 255), byte((v shr 8) and 255), byte(v and 255)]
  ihdr.add [16'u8, byte(if alpha: 6 else: 2), 0, 0, 0]
  chunk("IHDR", ihdr)
  if dpi > 0:
    let ppm = int(dpi.float / 0.0254 + 0.5)
    var ph: seq[byte]
    for v in [ppm, ppm]:
      ph.add [byte((v shr 24) and 255), byte((v shr 16) and 255), byte((v shr 8) and 255), byte(v and 255)]
    ph.add 1
    chunk("pHYs", ph)
  chunk("IDAT", z)
  chunk("IEND", [])
  o

proc savePng*(b: Bitmap; path: string): bool {.discardable.} =
  ## Writes `b` to the PNG file `path`; false if it cannot be written.
  try:
    writeFile(path, encodePng(b))
    true
  except IOError, OSError:
    false


proc windowIconFromPng*(data: string; sizes: openArray[int] = [16, 24, 32, 48, 64, 128]): seq[uint32] =
  ## A window icon (`windowIcon`, set before `startApp`; `app`'s `icon`
  ## option does it) from an app's icon as a PNG: the picture at each of
  ## `sizes`, made smaller by averaging (its edges soft, as a desktop draws
  ## them). Empty when it is not a PNG.
  var b: Bitmap
  try: b = decodePng(data)
  except CatchableError: return
  if b == nil or b.w <= 0 or b.h <= 0: return
  for n in sizes:
    result.add uint32(n)
    result.add uint32(n)
    for y in 0 ..< n:
      for x in 0 ..< n:
        # (the source pixels this one covers, averaged by their alpha)
        let sx0 = x * b.w div n
        let sx1 = max(sx0 + 1, (x + 1) * b.w div n)
        let sy0 = y * b.h div n
        let sy1 = max(sy0 + 1, (y + 1) * b.h div n)
        var a, r, g, bl, cnt = 0
        for yy in sy0 ..< sy1:
          for xx in sx0 ..< sx1:
            let p = b.px[yy * b.w + xx]
            let pa = int(p shr 24)
            a += pa
            r += int((p shr 16) and 255) * pa
            g += int((p shr 8) and 255) * pa
            bl += int(p and 255) * pa
            inc cnt
        if a == 0:
          result.add 0'u32
        else:
          result.add (uint32(a div cnt) shl 24) or (uint32(r div a) shl 16) or (uint32(g div a) shl 8) or
                     uint32(bl div a)
