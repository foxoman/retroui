## Picture files beyond PNG and JPEG, in plain Nim: TIFF (read: none, LZW,
## Deflate, PackBits, the horizontal predictor; 1, 8, 16 and 32 bits;
## gray, RGB, palette, CMYK, Lab, alpha; strips or tiles -- write: 8 bits,
## gray, RGB or CMYK, alpha, none, LZW, Deflate or PackBits, its strips
## compressed on all the cores), TGA (read and write, run-length coded),
## GIF (write: up to 256 colors, dithered, a transparent color), PNG with a
## palette, and the colors of a picture brought down to a palette
## (`quantize`).
##
## .. code-block:: nim
##   writeFile("photo.tif", encodeTiff(bmp, compression = tcLzw))
##   let q = quantize(bmp.px, 64, dither = true)          # palette + indexes
##   writeFile("photo.gif", encodeGif(bmp.w, bmp.h, q))

import std/[math, algorithm]
import gfx, codec, busy

type
  FormatError* = object of CatchableError
    ## A file that is not of the kind, or is damaged.

  TiffCompression* = enum
    ## How a TIFF that is written packs its pixels (the strings: their names
    ## as Photoshop's TIFF Options show them).
    tcNone = "None", tcLzw = "LZW", tcDeflate = "ZIP", tcPackBits = "PackBits"

  Quantized* = object
    ## A picture brought down to a palette: its colors (0xAARRGGBB; a
    ## transparent one first when there is transparency) and, for each
    ## pixel, which.
    palette*: seq[uint32]       ## the colors, at most 256
    index*: seq[uint8]          ## each pixel's color: an index of `palette`, row by row
    transparent*: int          ## the palette's transparent entry (-1 none)

proc fail(msg: string) {.noreturn.} = raise newException(FormatError, msg)

template pieces(n: int; body: proc (lo, hi: int) {.closure.}) =
  if compressPieces != nil and n > 1: compressPieces(n, body) else: body(0, n)

# ---- the colors of a picture brought down to a palette ---------------------------------------

proc quantize*(px: openArray[uint32]; colors = 256; alphaCut = 128): Quantized =
  ## Up to `colors` colors (2..256) standing for the picture (median cut,
  ## the boxes of the most varied colors split first), and each pixel's
  ## nearest (`ditherTo` diffuses the error instead). Pixels less opaque
  ## than `alphaCut` become the transparent entry.
  let n = px.len
  let want = clamp(colors, 2, 256)
  var anyClear = false
  for p in px:
    if int(p shr 24) < alphaCut:
      anyClear = true
      break
  # a sample of the colors (at most a quarter of a million)
  let step = max(1, n div 250_000)
  var sample: seq[uint32]
  var i = 0
  while i < n:
    if int(px[i] shr 24) >= alphaCut: sample.add px[i] and 0xFFFFFF'u32
    i += step
  let slots = want - ord(anyClear)
  var palette: seq[uint32]
  if sample.len > 0:
    # (few colors: all of them)
    var sorted = sample
    sorted.sort()
    var uniq: seq[uint32]
    for c in sorted:
      if uniq.len == 0 or uniq[^1] != c: uniq.add c
    if uniq.len <= slots:
      palette = uniq
    else:
      type Box = tuple[a, b: int; score: float]
      proc boxScore(s: seq[uint32]; a, b: int): float =
        var lo = [255, 255, 255]
        var hi = [0, 0, 0]
        for k in a ..< b:
          let c = s[k]
          for ch in 0 .. 2:
            let v = int((c shr (16 - 8 * ch)) and 255)
            lo[ch] = min(lo[ch], v); hi[ch] = max(hi[ch], v)
        let span = max(hi[0] - lo[0], max(hi[1] - lo[1], hi[2] - lo[2]))
        float(span) * sqrt(float(b - a))
      var boxes: seq[Box] = @[(0, sample.len, boxScore(sample, 0, sample.len))]
      while boxes.len < slots:
        var bi = -1
        var best = 0.0
        for k, bx in boxes:
          if bx.b - bx.a >= 2 and bx.score > best:
            best = bx.score
            bi = k
        if bi < 0: break
        let bx = boxes[bi]
        # split at the median of the widest channel
        var lo = [255, 255, 255]
        var hi = [0, 0, 0]
        for k in bx.a ..< bx.b:
          for ch in 0 .. 2:
            let v = int((sample[k] shr (16 - 8 * ch)) and 255)
            lo[ch] = min(lo[ch], v); hi[ch] = max(hi[ch], v)
        var ch = 0
        for c in 1 .. 2:
          if hi[c] - lo[c] > hi[ch] - lo[ch]: ch = c
        let sh = 16 - 8 * ch
        sample.toOpenArray(bx.a, bx.b - 1).sort(proc (x, y: uint32): int =
          cmp((x shr sh) and 255, (y shr sh) and 255))
        let mid = (bx.a + bx.b) div 2
        boxes[bi] = (bx.a, mid, boxScore(sample, bx.a, mid))
        boxes.add (mid, bx.b, boxScore(sample, mid, bx.b))
      for bx in boxes:
        if bx.b <= bx.a: continue
        var sr, sg, sb = 0
        for k in bx.a ..< bx.b:
          let c = sample[k]
          sr += int((c shr 16) and 255); sg += int((c shr 8) and 255); sb += int(c and 255)
        let m = bx.b - bx.a
        palette.add (uint32(sr div m) shl 16) or (uint32(sg div m) shl 8) or uint32(sb div m)
  if palette.len == 0: palette.add 0
  result.transparent = -1
  if anyClear:
    result.transparent = 0
    result.palette.add 0'u32
  for c in palette: result.palette.add c or 0xFF000000'u32
  let first = ord(anyClear)
  # the nearest entry of each 32 x 32 x 32 cell of colors (looked up for every pixel)
  var cells = newSeq[uint8](32 * 32 * 32)
  for r in 0 ..< 32:
    for g in 0 ..< 32:
      for b in 0 ..< 32:
        let cr = r * 8 + 4
        let cg = g * 8 + 4
        let cb = b * 8 + 4
        var bestD = high(int)
        var bestK = first
        for k in first ..< result.palette.len:
          let c = result.palette[k]
          let dr = int((c shr 16) and 255) - cr
          let dg = int((c shr 8) and 255) - cg
          let db = int(c and 255) - cb
          let dd = 3 * dr * dr + 4 * dg * dg + 2 * db * db
          if dd < bestD:
            bestD = dd
            bestK = k
        cells[(r * 32 + g) * 32 + b] = uint8(bestK)
  result.index = newSeq[uint8](n)
  template nearest(r, g, b: int): int =
    int(cells[((clamp(r, 0, 255) shr 3) * 32 + (clamp(g, 0, 255) shr 3)) * 32 + (clamp(b, 0, 255) shr 3)])
  for k in 0 ..< n:
    let p = px[k]
    result.index[k] = if anyClear and int(p shr 24) < alphaCut: 0'u8
                      else: uint8(nearest(int((p shr 16) and 255), int((p shr 8) and 255), int(p and 255)))

proc ditherTo*(q: var Quantized; px: openArray[uint32]; w, h: int; alphaCut = 128) =
  ## The pixels mapped to `q.palette` again, with Floyd and Steinberg's error
  ## diffusion (smooth gradients instead of bands).
  let first = if q.transparent >= 0: 1 else: 0
  var cache = newSeq[int16](32 * 32 * 32)
  for c in cache.mitems: c = -1
  let pal = q.palette
  proc nearest(r, g, b: int): int =
    let key = ((r shr 3) * 32 + (g shr 3)) * 32 + (b shr 3)
    if cache[key] >= 0:
      # (the cell's guess, checked against its neighbours in the palette is
      # not needed for diffusion: close enough)
      return int(cache[key])
    var bestD = high(int)
    var bestK = first
    for k in first ..< pal.len:
      let c = pal[k]
      let dr = int((c shr 16) and 255) - r
      let dg = int((c shr 8) and 255) - g
      let db = int(c and 255) - b
      let dd = 3 * dr * dr + 4 * dg * dg + 2 * db * db
      if dd < bestD:
        bestD = dd
        bestK = k
    cache[key] = int16(bestK)
    bestK
  var cur = newSeq[array[3, int]](w + 2)
  var nxt = newSeq[array[3, int]](w + 2)
  for y in 0 ..< h:
    for x in 0 .. w + 1: nxt[x] = [0, 0, 0]
    for x in 0 ..< w:
      let i = y * w + x
      let p = px[i]
      if q.transparent >= 0 and int(p shr 24) < alphaCut:
        q.index[i] = uint8(q.transparent)
        continue
      let r = clamp(int((p shr 16) and 255) + cur[x + 1][0] div 16, 0, 255)
      let g = clamp(int((p shr 8) and 255) + cur[x + 1][1] div 16, 0, 255)
      let b = clamp(int(p and 255) + cur[x + 1][2] div 16, 0, 255)
      let k = nearest(r, g, b)
      q.index[i] = uint8(k)
      let c = q.palette[k]
      let e = [r - int((c shr 16) and 255), g - int((c shr 8) and 255), b - int(c and 255)]
      for ch in 0 .. 2:
        cur[x + 2][ch] += e[ch] * 7
        nxt[x][ch] += e[ch] * 3
        nxt[x + 1][ch] += e[ch] * 5
        nxt[x + 2][ch] += e[ch]
    swap(cur, nxt)
    if (y and 63) == 63: busyTick()

# ---- PNG with a palette ----------------------------------------------------------------------

proc putBe32(o: var string; v: uint32) =
  o.add char((v shr 24) and 255); o.add char((v shr 16) and 255)
  o.add char((v shr 8) and 255); o.add char(v and 255)
proc putBe32(o: var string; v: int) = o.putBe32(uint32(v))

proc pngChunk(o: var string; kind: string; data: openArray[byte]) =
  o.putBe32(data.len)
  let at = o.len
  o.add kind
  if data.len > 0:
    let p = o.len
    o.setLen(p + data.len)
    copyMem(addr o[p], unsafeAddr data[0], data.len)
  var c = 0xFFFFFFFF'u32
  for i in at ..< o.len: c = crcStep(c, byte(o[i]))
  o.putBe32(c xor 0xFFFFFFFF'u32)

proc encodePngIndexed*(w, h: int; q: Quantized; level = 6; dpi = 0): string =
  ## A PNG of a picture with a palette (8 bits a pixel; fewer when the
  ## palette is small).
  let bits = if q.palette.len <= 2: 1 elif q.palette.len <= 4: 2 elif q.palette.len <= 16: 4 else: 8
  let stride = 1 + (w * bits + 7) div 8
  var raw = newSeq[byte](stride * h)
  for y in 0 ..< h:
    let at = y * stride
    raw[at] = 0
    var acc = 0
    var nb = 0
    var o = at + 1
    for x in 0 ..< w:
      acc = (acc shl bits) or int(q.index[y * w + x])
      nb += bits
      if nb == 8:
        raw[o] = byte(acc)
        inc o
        acc = 0
        nb = 0
    if nb > 0:
      raw[o] = byte(acc shl (8 - nb))
  let z = zlibCompressLevel(raw, level)
  result = "\x89PNG\r\n\x1a\n"
  var ihdr: seq[byte]
  for v in [w, h]:
    ihdr.add [byte((v shr 24) and 255), byte((v shr 16) and 255), byte((v shr 8) and 255), byte(v and 255)]
  ihdr.add [byte(bits), 3, 0, 0, 0]
  result.pngChunk("IHDR", ihdr)
  var plte: seq[byte]
  var trns: seq[byte]
  var anyAlpha = false
  for c in q.palette:
    plte.add [byte((c shr 16) and 255), byte((c shr 8) and 255), byte(c and 255)]
    trns.add byte(c shr 24)
    if (c shr 24) != 255: anyAlpha = true
  result.pngChunk("PLTE", plte)
  if anyAlpha:
    while trns.len > 0 and trns[^1] == 255: trns.setLen(trns.len - 1)
    result.pngChunk("tRNS", trns)
  if dpi > 0:
    let ppm = int(dpi.float / 0.0254 + 0.5)
    var ph: seq[byte]
    for v in [ppm, ppm]:
      ph.add [byte((v shr 24) and 255), byte((v shr 16) and 255), byte((v shr 8) and 255), byte(v and 255)]
    ph.add 1
    result.pngChunk("pHYs", ph)
  result.pngChunk("IDAT", z)
  result.pngChunk("IEND", [])

# ---- GIF ---------------------------------------------------------------------------------------

proc encodeGif*(w, h: int; q: Quantized): string =
  ## A GIF of a picture with a palette (its transparent entry kept).
  if w <= 0 or h <= 0 or w > 65535 or h > 65535: fail("a GIF is at most 65535 pixels a side")
  var palBits = 1
  while (1 shl palBits) < q.palette.len: inc palBits
  palBits = clamp(palBits, 1, 8)
  var o = "GIF89a"
  proc u16(v: int) =
    o.add char(v and 255); o.add char((v shr 8) and 255)
  u16(w); u16(h)
  o.add char(0x80 or ((palBits - 1) shl 4) or (palBits - 1))
  o.add '\0'; o.add '\0'
  for k in 0 ..< (1 shl palBits):
    let c = if k < q.palette.len: q.palette[k] else: 0'u32
    o.add char((c shr 16) and 255); o.add char((c shr 8) and 255); o.add char(c and 255)
  if q.transparent >= 0:
    o.add "\x21\xF9\x04"; o.add char(1); u16(0); o.add char(q.transparent); o.add '\0'
  o.add '\x2C'; u16(0); u16(0); u16(w); u16(h); o.add '\0'
  # the pixels, LZW coded (least significant bits first)
  let minCode = max(2, palBits)
  o.add char(minCode)
  let clearCode = 1 shl minCode
  let eoi = clearCode + 1
  var data: string
  var acc = 0
  var nbits = 0
  var width = minCode + 1
  proc emit(code: int) =
    acc = acc or (code shl nbits)
    nbits += width
    while nbits >= 8:
      data.add char(acc and 255)
      acc = acc shr 8
      nbits -= 8
  var dict = newSeq[int32](4096 * 256)      # (prefix, byte) -> code + 1
  var next = eoi + 1
  emit(clearCode)
  let n = w * h
  if n > 0:
    var cur = int(q.index[0])
    for i in 1 ..< n:
      let b = int(q.index[i])
      let key = cur * 256 + b
      let found = dict[key]
      if found != 0:
        cur = int(found) - 1
        continue
      emit(cur)
      if next < 4096:
        dict[key] = int32(next + 1)
        inc next
        if next > (1 shl width) and width < 12: inc width
      else:
        emit(clearCode)
        for x in dict.mitems: x = 0
        next = eoi + 1
        width = minCode + 1
      cur = b
      if (i and 0xFFFFF) == 0: busyTick()
    emit(cur)
    if next >= (1 shl width) and width < 12: inc width
  emit(eoi)
  if nbits > 0: data.add char(acc and 255)
  var at = 0
  while at < data.len:
    let k = min(255, data.len - at)
    o.add char(k)
    o.add data[at ..< at + k]
    at += k
  o.add '\0'
  o.add ';'
  o

# ---- TGA --------------------------------------------------------------------------------------

proc encodeTga*(b: Bitmap; alpha = true; rle = true): string =
  ## A TGA of `b` (32 bits with its transparency, or 24), run-length coded.
  let bpp = if alpha: 4 else: 3
  result = newStringOfCap(18 + b.w * b.h * bpp)
  result.add '\0'; result.add '\0'
  result.add char(if rle: 10 else: 2)
  for _ in 0 ..< 9: result.add '\0'
  result.add char(b.w and 255); result.add char(b.w shr 8)
  result.add char(b.h and 255); result.add char(b.h shr 8)
  result.add char(bpp * 8)
  result.add char((if alpha: 8 else: 0) or 0x20)     # (rows from the top)
  template pixel(p: uint32) =
    result.add char(p and 255); result.add char((p shr 8) and 255); result.add char((p shr 16) and 255)
    if alpha: result.add char(p shr 24)
  for y in 0 ..< b.h:
    let row = y * b.w
    if not rle:
      for x in 0 ..< b.w: pixel(b.px[row + x])
      continue
    var x = 0
    while x < b.w:
      # a run of one color, or a stretch of different ones
      var run = 1
      let p = b.px[row + x] or (if alpha: 0'u32 else: 0xFF000000'u32)
      while x + run < b.w and run < 128 and (b.px[row + x + run] or (if alpha: 0'u32 else: 0xFF000000'u32)) == p:
        inc run
      if run >= 2:
        result.add char(0x80 or (run - 1))
        pixel(b.px[row + x])
        x += run
      else:
        var k = 1
        while x + k < b.w and k < 128 and
              (x + k + 1 >= b.w or b.px[row + x + k] != b.px[row + x + k + 1]):
          inc k
        result.add char(k - 1)
        for j in 0 ..< k: pixel(b.px[row + x + j])
        x += k

type TgaInfo* = object
  ## A TGA's header and color map (`tgaInfo`): what its pixels are, and
  ## where they begin.
  kind*: int                 ## 1, 2, 3 (color map, true color, gray); 9, 10, 11 run-length coded
  w*, h*, bpp*, desc*: int
    ## its size, bits a pixel, and the image descriptor byte (alpha bits,
    ## where the first row is)
  pb*: int                   ## bytes a pixel
  pos*: int                  ## where the pixels begin
  cmapFirst*: int            ## the index of the color map's first color
  cmap*: seq[uint32]         ## the color map's colors (ARGB)

var maxFilePixels* = 300_000_000
  ## TIFF and TGA pictures with more pixels are refused (rather than taking
  ## gigabytes); `retroui/bigpicture` reads bigger ones in bands.

proc tgaColor(data: openArray[char]; bits, at: int): uint32 {.inline.} =
  case bits
  of 8: (let v = uint32(ord(data[at])); 0xFF000000'u32 or (v shl 16) or (v shl 8) or v)
  of 15, 16:
    let v = ord(data[at]) or (ord(data[at + 1]) shl 8)
    let r = ((v shr 10) and 31) * 255 div 31
    let g = ((v shr 5) and 31) * 255 div 31
    let b = (v and 31) * 255 div 31
    0xFF000000'u32 or (uint32(r) shl 16) or (uint32(g) shl 8) or uint32(b)
  of 24: 0xFF000000'u32 or (uint32(ord(data[at + 2])) shl 16) or (uint32(ord(data[at + 1])) shl 8) or
         uint32(ord(data[at]))
  else: (uint32(ord(data[at + 3])) shl 24) or (uint32(ord(data[at + 2])) shl 16) or
        (uint32(ord(data[at + 1])) shl 8) or uint32(ord(data[at]))

proc tgaPixel*(t: TgaInfo; data: openArray[char]; at: int): uint32 {.inline.} =
  ## The pixel whose `pb` bytes are at `data[at]` (its color-map entry
  ## looked up).
  if t.kind in [1, 9]:
    let idx = (if t.pb == 1: ord(data[at]) else: ord(data[at]) or (ord(data[at + 1]) shl 8)) - t.cmapFirst
    if idx >= 0 and idx < t.cmap.len: t.cmap[idx] else: 0xFF000000'u32
  elif t.kind in [3, 11]:
    let v = uint32(ord(data[at]))
    (if t.bpp == 16: uint32(ord(data[at + 1])) shl 24 else: 0xFF000000'u32) or (v shl 16) or (v shl 8) or v
  else: tgaColor(data, t.bpp, at)

proc tgaInfo*(data: openArray[char]; maxPixels = maxFilePixels): TgaInfo =
  ## The header and color map of the TGA in `data`. Raises `FormatError`
  ## when it is not a TGA this can read, or when its pixels are more than
  ## its bytes can hold (a damaged header cannot ask for gigabytes).
  if data.len < 18: fail("not a TGA file")
  let idLen = ord(data[0])
  let cmapType = ord(data[1])
  result.kind = ord(data[2])
  result.cmapFirst = ord(data[3]) or (ord(data[4]) shl 8)
  let cmapLen = ord(data[5]) or (ord(data[6]) shl 8)
  let cmapBits = ord(data[7])
  result.w = ord(data[12]) or (ord(data[13]) shl 8)
  result.h = ord(data[14]) or (ord(data[15]) shl 8)
  result.bpp = ord(data[16])
  result.desc = ord(data[17])
  if result.kind notin [1, 2, 3, 9, 10, 11] or result.w <= 0 or result.h <= 0:
    fail("not a TGA picture this can read")
  if result.bpp notin [8, 15, 16, 24, 32]: fail("TGA: bad bits per pixel")
  var pos = 18 + idLen
  if cmapType == 1:
    if cmapBits notin [8, 15, 16, 24, 32]: fail("TGA: bad color map")
    let cb = (cmapBits + 7) div 8
    if pos + cmapLen * cb > data.len: fail("TGA: cut short")
    for k in 0 ..< cmapLen: result.cmap.add tgaColor(data, cmapBits, pos + k * cb)
    pos += cmapLen * cb
  result.pos = pos
  result.pb = (result.bpp + 7) div 8
  # (the size against the bytes: a run of up to 128 pixels takes 2 bytes at least)
  let total = result.w.int64 * result.h.int64
  let avail = max(0, data.len - pos).int64
  if total > maxPixels.int64: fail("TGA: too big")
  if result.kind >= 9:
    if total > avail * 128: fail("TGA: cut short")
  elif total * result.pb > avail: fail("TGA: cut short")

proc decodeTga*(data: string): Bitmap =
  ## A TGA picture (true color, gray or with a color map; run-length coded
  ## or not; 8, 15, 16, 24 or 32 bits).
  let t = tgaInfo(data)
  let w = t.w
  let h = t.h
  let pb = t.pb
  var pos = t.pos
  result = newBitmap(w, h)
  let total = w * h
  var i = 0
  while i < total:
    if t.kind >= 9:
      if pos >= data.len: fail("TGA: cut short")
      let head = ord(data[pos])
      inc pos
      let count = (head and 0x7F) + 1
      if (head and 0x80) != 0:
        if pos + pb > data.len: fail("TGA: cut short")
        let p = t.tgaPixel(data, pos)
        pos += pb
        for _ in 0 ..< count:
          if i < total:
            result.px[i] = p
            inc i
      else:
        if pos + count * pb > data.len: fail("TGA: cut short")
        for _ in 0 ..< count:
          if i < total:
            result.px[i] = t.tgaPixel(data, pos)
            inc i
          pos += pb
    else:
      if pos + pb > data.len: fail("TGA: cut short")
      result.px[i] = t.tgaPixel(data, pos)
      pos += pb
      inc i
  # (an alpha that is all zero means none)
  if t.bpp == 32 and (t.desc and 15) == 0:
    for p in result.px.mitems: p = p or 0xFF000000'u32
  if (t.desc and 0x20) == 0:
    # rows from the bottom
    for y in 0 ..< h div 2:
      for x in 0 ..< w:
        swap(result.px[y * w + x], result.px[(h - 1 - y) * w + x])
  if (t.desc and 0x10) != 0:
    for y in 0 ..< h:
      for x in 0 ..< w div 2: swap(result.px[y * w + x], result.px[y * w + w - 1 - x])
  result.changed()

# ---- TIFF -------------------------------------------------------------------------------------

proc packBits(src: openArray[byte]): seq[byte] =
  ## PackBits (Apple's run-length code: TIFF and PSD use it).
  var i = 0
  let n = src.len
  while i < n:
    var run = 1
    while i + run < n and run < 128 and src[i + run] == src[i]: inc run
    if run >= 2:
      result.add byte(257 - run)
      result.add src[i]
      i += run
    else:
      var k = 1
      while i + k < n and k < 128 and not (i + k + 1 < n and src[i + k] == src[i + k + 1]): inc k
      result.add byte(k - 1)
      for j in 0 ..< k: result.add src[i + j]
      i += k

proc unpackBits*(src: openArray[byte]; at: var int; outLen: int; o: var seq[byte]; oat: int) =
  ## PackBits data from `src[at..]` into `o[oat ..< oat + outLen]`.
  var n = 0
  while n < outLen:
    if at >= src.len: fail("PackBits data cut short")
    let c = int(src[at])
    inc at
    if c < 128:
      let k = c + 1
      if at + k > src.len: fail("PackBits data cut short")
      for j in 0 ..< k:
        if n < outLen: o[oat + n] = src[at + j]
        inc n
      at += k
    elif c > 128:
      let k = 257 - c
      if at >= src.len: fail("PackBits data cut short")
      let v = src[at]
      inc at
      for _ in 0 ..< k:
        if n < outLen: o[oat + n] = v
        inc n

proc lzwTiffEncode(src: openArray[byte]): seq[byte] =
  ## TIFF's LZW (most significant bits first, the code width growing one
  ## code early).
  var acc = 0'u64
  var nbits = 0
  var width = 9
  proc emit(o: var seq[byte]; code: int) =
    acc = (acc shl uint64(width)) or uint64(code)
    nbits += width
    while nbits >= 8:
      o.add byte((acc shr uint64(nbits - 8)) and 255)
      nbits -= 8
  var dict = newSeq[int32](4096 * 256)
  var next = 258
  result.emit(256)
  if src.len > 0:
    var cur = int(src[0])
    for i in 1 ..< src.len:
      let b = int(src[i])
      let key = cur * 256 + b
      let found = dict[key]
      if found != 0:
        cur = int(found) - 1
        continue
      result.emit(cur)
      dict[key] = int32(next + 1)
      inc next
      if next == 4094:
        # (the table full: begun again)
        result.emit(256)
        for x in dict.mitems: x = 0
        next = 258
        width = 9
      elif next > (1 shl width) - 1 and width < 12: inc width
      cur = b
    result.emit(cur)
    inc next
    if next == 4094:
      result.emit(256)
      width = 9
    elif next > (1 shl width) - 1 and width < 12: inc width
  result.emit(257)
  if nbits > 0: result.add byte((acc shl uint64(8 - nbits)) and 255)

proc lzwTiffDecode(src: openArray[byte]; outLen: int): seq[byte] =
  result = newSeqOfCap[byte](outLen)
  var tab = newSeq[seq[byte]](4096)
  for i in 0 .. 255: tab[i] = @[byte(i)]
  var next = 258
  var width = 9
  var prev = -1
  var bitPos = 0
  let total = src.len * 8
  while bitPos + width <= total and result.len < outLen:
    var code = 0
    for k in 0 ..< width:
      let bit = (int(src[(bitPos + k) shr 3]) shr (7 - ((bitPos + k) and 7))) and 1
      code = (code shl 1) or bit
    bitPos += width
    if code == 256:
      next = 258
      width = 9
      prev = -1
      continue
    if code == 257: break
    var entry: seq[byte]
    if prev < 0:
      if code > 255: fail("TIFF: bad LZW data")
      entry = tab[code]
    elif code < next and tab[code].len > 0:
      entry = tab[code]
      if next < 4096:
        tab[next] = tab[prev] & entry[0]
        inc next
    else:
      if prev >= next or tab[prev].len == 0: fail("TIFF: bad LZW data")
      entry = tab[prev] & tab[prev][0]
      if next < 4096:
        tab[next] = entry
        inc next
    result.add entry
    if next + 1 > (1 shl width) - 1 and width < 12: inc width
    prev = code

type
  TiffEntry = tuple[tag, kind, count, value: int]

  TiffInfo* = object
    ## A TIFF's first picture as its tags lay it out (`tiffInfo`): what
    ## `decodeTiff`, and `retroui/bigpicture` a band at a time, read it with.
    le*: bool                    ## Intel order
    w*, h*: int                  ## its size in pixels
    bits*, spp*: int             ## bits a sample, samples a pixel
    comp*, photo*, planar*, predictor*, fmt*: int
      ## the tags' values: Compression, PhotometricInterpretation,
      ## PlanarConfiguration, Predictor, SampleFormat
    extra*, cmap*: seq[int]      ## the ExtraSamples and ColorMap tags' values
    offs*, lens*: seq[int]       ## where each piece (strip or tile) is, how long
    tiled*: bool                 ## in tiles (else in strips)
    tileW*, tileH*: int          ## a piece's size (a strip: the width x its rows)
    across*, down*: int          ## pieces across and down (in each plane)
    planes*: int                 ## 1, or `spp` when each sample has a plane of its own
    perPixel*: int               ## samples a pixel in a plane
    rowBytes*: int               ## the bytes of a row of a piece
    alphaAt*: int                ## which sample is the alpha (-1: none)

proc tiff16(data: openArray[char]; le: bool; at: int): int =
  if at < 0 or at + 2 > data.len: fail("TIFF: cut short")
  if le: ord(data[at]) or (ord(data[at + 1]) shl 8) else: (ord(data[at]) shl 8) or ord(data[at + 1])

proc tiff32(data: openArray[char]; le: bool; at: int): int =
  if at < 0 or at + 4 > data.len: fail("TIFF: cut short")
  if le: ord(data[at]) or (ord(data[at + 1]) shl 8) or (ord(data[at + 2]) shl 16) or (ord(data[at + 3]) shl 24)
  else: (ord(data[at]) shl 24) or (ord(data[at + 1]) shl 16) or (ord(data[at + 2]) shl 8) or ord(data[at + 3])

proc tiffValues(data: openArray[char]; le: bool; entries: seq[TiffEntry]; tag: int): seq[int] =
  proc sizeOf(kind: int): int =
    case kind
    of 1, 2, 6, 7: 1
    of 3, 8: 2
    of 4, 9, 11: 4
    of 5, 10, 12: 8
    else: 1
  for e in entries:
    if e.tag != tag: continue
    let sz = sizeOf(e.kind)
    # (no more values than the file has room for: a damaged count is not a
    # reason to take gigabytes)
    if e.count < 0 or sz.int64 * e.count.int64 > data.len.int64: fail("TIFF: cut short")
    let at = if sz * e.count <= 4: e.value else: tiff32(data, le, e.value)
    for k in 0 ..< e.count:
      case e.kind
      of 1, 7:
        if at + k >= data.len: fail("TIFF: cut short")
        result.add ord(data[at + k])
      of 3: result.add tiff16(data, le, at + 2 * k)
      of 4: result.add tiff32(data, le, at + 4 * k)
      of 5:
        let d = tiff32(data, le, at + 8 * k + 4)
        result.add (if d != 0: tiff32(data, le, at + 8 * k) div d else: 0)
      else: result.add 0
    return

proc tiffInfo*(data: openArray[char]; maxPixels = maxFilePixels): TiffInfo =
  ## The layout of the first picture of the TIFF in `data` (its tags read,
  ## nothing decoded). Raises `FormatError` when it is not a TIFF this can
  ## read, or has more than `maxPixels`.
  if data.len < 8: fail("not a TIFF file")
  let le = data[0] == 'I' and data[1] == 'I'
  if not le and not (data[0] == 'M' and data[1] == 'M'): fail("not a TIFF file")
  result.le = le
  if tiff16(data, le, 2) != 42: fail("not a TIFF file this can read (BigTIFF?)")
  let ifd = tiff32(data, le, 4)
  let count = tiff16(data, le, ifd)
  var entries: seq[TiffEntry]
  for k in 0 ..< count:
    let at = ifd + 2 + 12 * k
    entries.add (tiff16(data, le, at), tiff16(data, le, at + 2), tiff32(data, le, at + 4), at + 8)
  template values(tag: int): seq[int] = tiffValues(data, le, entries, tag)
  proc one(v: seq[int]; def: int): int = (if v.len > 0: v[0] else: def)
  let w = one(values(256), 0)
  let h = one(values(257), 0)
  if w <= 0 or h <= 0 or w.int64 * h.int64 > maxPixels.int64: fail("TIFF: bad size")
  result.w = w
  result.h = h
  var bps = values(258)
  if bps.len == 0: bps = @[1]
  result.spp = one(values(277), 1)
  result.comp = one(values(259), 1)
  result.photo = one(values(262), 2)
  result.planar = one(values(284), 1)
  result.predictor = one(values(317), 1)
  result.fmt = one(values(339), 1)
  result.extra = values(338)
  result.bits = bps[0]
  if result.comp notin [1, 5, 8, 32946, 32773]:
    fail("TIFF: this compression is not supported (" & $result.comp & ")")
  if result.bits notin [1, 2, 4, 8, 16, 32]: fail("TIFF: bad bits per sample")
  if result.spp < 1 or result.spp > 16 or (result.photo in [5, 8] and result.spp < 3):
    fail("TIFF: bad samples per pixel")
  result.cmap = values(320)
  # the pieces: strips, or tiles
  result.offs = values(273)
  result.lens = values(279)
  result.tileW = one(values(322), 0)
  result.tileH = one(values(323), 0)
  if result.tileW > 0:
    result.tiled = true
    result.offs = values(324)
    result.lens = values(325)
  else:
    result.tileW = w
    result.tileH = min(h, one(values(278), h))
  if result.offs.len == 0 or result.offs.len != result.lens.len: fail("TIFF: no picture data")
  if result.tileW <= 0 or result.tileH <= 0: fail("TIFF: bad tiles")
  result.across = (w + result.tileW - 1) div result.tileW
  result.down = (h + result.tileH - 1) div result.tileH
  result.planes = if result.planar == 2: result.spp else: 1
  result.perPixel = if result.planar == 2: 1 else: result.spp
  result.rowBytes = (result.tileW * result.perPixel * result.bits + 7) div 8
  result.alphaAt = if result.extra.len > 0: result.spp - result.extra.len else: -1

proc tiffCheck*(t: TiffInfo; fileLen: int) =
  ## Raises `FormatError` when the pixels the tags claim are more than the
  ## data in the file can hold, however well packed (Deflate packs at most
  ## about 1000 to 1, LZW about 4000; uncompressed may be cut short to a
  ## quarter): a damaged header cannot ask for gigabytes.
  let ratio = case t.comp
              of 1: 4
              of 32773: 64
              of 8, 32946: 1100
              else: 4100
  var avail = 0'i64
  for k, o in t.offs:
    if o >= 0 and o < fileLen and t.lens[k] > 0: avail += min(t.lens[k], fileLen - o).int64
  let need = t.planes.int64 * t.across.int64 * t.down.int64 * t.rowBytes.int64 * t.tileH.int64
  if need > avail * ratio + 65536: fail("TIFF: the picture is bigger than its data")

proc tiffUnpredict*(t: TiffInfo; row: var openArray[byte]) =
  ## The horizontal predictor undone on a row of a piece.
  if t.predictor != 2: return
  let pp = t.perPixel
  if t.bits == 8:
    for x in pp ..< t.tileW * pp:
      row[x] = row[x] + row[x - pp]
  elif t.bits == 16:
    let le = t.le
    for x in pp ..< t.tileW * pp:
      let at = 2 * x
      let pa = 2 * (x - pp)
      var v = if le: int(row[at]) or (int(row[at + 1]) shl 8) else: (int(row[at]) shl 8) or int(row[at + 1])
      let p = if le: int(row[pa]) or (int(row[pa + 1]) shl 8) else: (int(row[pa]) shl 8) or int(row[pa + 1])
      v = (v + p) and 0xFFFF
      if le: (row[at] = byte(v and 255); row[at + 1] = byte(v shr 8))
      else: (row[at] = byte(v shr 8); row[at + 1] = byte(v and 255))

proc tiffPiece*(data: openArray[char]; t: TiffInfo; k: int): seq[byte] =
  ## Piece `k` (a strip or a tile) decompressed, the predictor undone:
  ## `rowBytes * tileH` bytes (what the data lacks as zeros).
  let a = t.offs[k]
  let b = a + t.lens[k]
  if a < 0 or b > data.len or b < a: fail("TIFF: damaged data")
  let need = t.rowBytes * t.tileH
  template src: untyped = data.toOpenArrayByte(a, b - 1)
  case t.comp
  of 1:
    result = newSeq[byte](need)
    for j in 0 ..< min(need, b - a): result[j] = byte(data[a + j])
  of 5: result = lzwTiffDecode(src, need)
  of 8, 32946:
    result = try: zlibDecompress(src, need + 64) except CatchableError: fail("TIFF: damaged ZIP data")
  else:
    # (the rows there are: a picture's last strip may have fewer)
    let rows = if t.tiled: t.tileH else: min(t.tileH, t.h - (k mod t.down) * t.tileH)
    result = newSeq[byte](need)
    var at = 0
    unpackBits(src, at, t.rowBytes * max(0, rows), result, 0)
  if result.len < need: result.setLen(need)
  if t.predictor == 2:
    for y in 0 ..< t.tileH:
      tiffUnpredict(t, result.toOpenArray(y * t.rowBytes, (y + 1) * t.rowBytes - 1))

proc tiffSample*(t: TiffInfo; raw: openArray[byte]; at, si: int): int {.inline.} =
  ## Sample `si` of the row at `raw[at]` of a piece, at 16 bits (of a
  ## palette: the index).
  case t.bits
  of 8: int(raw[at + si]) * 257
  of 16:
    let i = at + 2 * si
    if t.le: int(raw[i]) or (int(raw[i + 1]) shl 8) else: (int(raw[i]) shl 8) or int(raw[i + 1])
  of 32:
    let i = at + 4 * si
    let u = if t.le: uint32(raw[i]) or (uint32(raw[i + 1]) shl 8) or (uint32(raw[i + 2]) shl 16) or
                     (uint32(raw[i + 3]) shl 24)
            else: (uint32(raw[i]) shl 24) or (uint32(raw[i + 1]) shl 16) or (uint32(raw[i + 2]) shl 8) or
                  uint32(raw[i + 3])
    if t.fmt == 3:
      let f = cast[float32](u)
      # (linear light: to sRGB)
      let l = clamp(f.float, 0.0, 1.0)
      let sv = if l <= 0.0031308: 12.92 * l else: 1.055 * pow(l, 1 / 2.4) - 0.055
      int(sv * 65535 + 0.5)
    else: int(u shr 16)
  else:
    # 1, 2, 4 bits
    let bitAt = si * t.bits
    let byt = int(raw[at + (bitAt shr 3)])
    let raw1 = (byt shr (8 - t.bits - (bitAt and 7))) and ((1 shl t.bits) - 1)
    if t.photo == 3: raw1 else: raw1 * 65535 div ((1 shl t.bits) - 1)

proc labInv(t: float): float = (if t > 0.206893: t * t * t else: (t - 16 / 116) / 7.787)
proc labGamma(c: float): int =
  let v = clamp(c, 0.0, 1.0)
  int((if v <= 0.0031308: 12.92 * v else: 1.055 * pow(v, 1 / 2.4) - 0.055) * 255 + 0.5)

proc tiffPixel*(t: TiffInfo; s: openArray[uint16]; at: int): uint32 {.inline.} =
  ## The color of the pixel whose `spp` samples (`tiffSample`) begin at
  ## `s[at]`: gray, palette, RGB, CMYK, Lab, with alpha.
  template c8(k: int): int = int(s[at + k]) shr 8
  let spp = t.spp
  let alphaAt = t.alphaAt
  var a = if alphaAt >= 0 and alphaAt < spp: c8(alphaAt) else: 255
  var r, g, b: int
  case t.photo
  of 0, 1:
    var v = if t.bits < 8 and t.photo == 3: 0 else: c8(0)
    if t.photo == 0: v = 255 - v
    r = v; g = v; b = v
    if spp >= 2 and alphaAt < 0: a = c8(1)
  of 3:
    let idx = int(s[at])
    let n = t.cmap.len div 3
    if idx < n:
      r = t.cmap[idx] shr 8; g = t.cmap[n + idx] shr 8; b = t.cmap[2 * n + idx] shr 8
  of 5:
    let c = c8(0)
    let m = c8(1)
    let y = c8(2)
    let k = if spp >= 4: c8(3) else: 0
    r = (255 - c) * (255 - k) div 255
    g = (255 - m) * (255 - k) div 255
    b = (255 - y) * (255 - k) div 255
    if spp >= 5 and alphaAt < 0: a = c8(4)
  of 8:
    # CIE L*a*b* (a and b signed)
    let L = c8(0).float * 100 / 255
    let aa = float(cast[int8](uint8(c8(1))))
    let bb = float(cast[int8](uint8(c8(2))))
    let fy = (L + 16) / 116
    let fx = fy + aa / 500
    let fz = fy - bb / 200
    let X = labInv(fx) * 0.95047
    let Y = labInv(fy)
    let Z = labInv(fz) * 1.08883
    r = labGamma(3.2406 * X - 1.5372 * Y - 0.4986 * Z)
    g = labGamma(-0.9689 * X + 1.8758 * Y + 0.0415 * Z)
    b = labGamma(0.0557 * X - 0.2040 * Y + 1.0570 * Z)
  else:
    r = c8(0)
    g = if spp > 1: c8(1) else: r
    b = if spp > 2: c8(2) else: r
    if spp >= 4 and alphaAt < 0: a = c8(3)
  (uint32(clamp(a, 0, 255)) shl 24) or (uint32(clamp(r, 0, 255)) shl 16) or
    (uint32(clamp(g, 0, 255)) shl 8) or uint32(clamp(b, 0, 255))

proc decodeTiff*(data: string; cmyk: ptr seq[uint8] = nil): Bitmap =
  ## A TIFF picture (its first page). With `cmyk`, a CMYK picture's ink
  ## (4 bytes a pixel, 255 = full ink) is given there too.
  let t = tiffInfo(data)
  tiffCheck(t, data.len)
  let w = t.w
  let h = t.h
  let spp = t.spp
  # all the samples, chunky, as 16 bits
  var samples = newSeq[uint16](w * h * spp)
  for pl in 0 ..< t.planes:
    for ty in 0 ..< t.down:
      for tx in 0 ..< t.across:
        let k = pl * t.across * t.down + ty * t.across + tx
        if k >= t.offs.len: continue
        let raw = tiffPiece(data, t, k)
        # into the samples
        for y in 0 ..< t.tileH:
          let iy = ty * t.tileH + y
          if iy >= h: break
          for x in 0 ..< t.tileW:
            let ix = tx * t.tileW + x
            if ix >= w: break
            for s in 0 ..< t.perPixel:
              samples[(iy * w + ix) * spp + (if t.planar == 2: pl else: s)] =
                uint16(t.tiffSample(raw, y * t.rowBytes, x * t.perPixel + s))
      busyTick()
  # the colors
  result = newBitmap(w, h)
  if cmyk != nil and t.photo == 5: cmyk[] = newSeq[uint8](w * h * 4)
  for i in 0 ..< w * h:
    let s = i * spp
    if cmyk != nil and t.photo == 5:
      for c in 0 .. 3:
        cmyk[][4 * i + c] = (if c < 3 or spp >= 4: uint8(int(samples[s + c]) shr 8) else: 0'u8)
    result.px[i] = t.tiffPixel(samples, s)
  result.changed()

proc encodeTiff*(b: Bitmap; compression = tcLzw; alpha = true; gray = false; dpi = 72;
                 cmyk: seq[uint8] = @[]; icc = ""; photoshop = ""): string =
  ## A TIFF of `b`: 8 bits, RGB (gray when `gray`; CMYK when `cmyk` holds
  ## the ink of each pixel, 4 bytes, 255 full), with its transparency when
  ## `alpha`; in strips compressed at once on all the cores (LZW and ZIP
  ## with the horizontal predictor). `photoshop`: Photoshop's layers
  ## (`psd.tiffLayerBlock`) kept in tag 37724 (ImageSourceData) -- the file
  ## is then in Motorola order ("MM"), as those layers are big-endian.
  let w = b.w
  let h = b.h
  let isCmyk = cmyk.len == w * h * 4
  let colorS = if isCmyk: 4 elif gray: 1 else: 3
  let spp = colorS + ord(alpha)
  let rowBytes = w * spp
  let rowsPer = max(1, min(h, (1 shl 20) div max(1, rowBytes)))
  let strips = (h + rowsPer - 1) div rowsPer
  var outs = newSeq[seq[byte]](strips)
  let op = cast[ptr UncheckedArray[seq[byte]]](addr outs[0])
  let src = cast[ptr UncheckedArray[uint32]](unsafeAddr b.px[0])
  let ink = if isCmyk: cast[ptr UncheckedArray[uint8]](unsafeAddr cmyk[0]) else: nil
  let body = proc (lo, hi: int) =
    for k in lo ..< hi:
      let y0 = k * rowsPer
      let y1 = min(h, y0 + rowsPer)
      var raw = newSeq[byte]((y1 - y0) * rowBytes)
      var o = 0
      for y in y0 ..< y1:
        for x in 0 ..< w:
          let i = y * w + x
          let p = src[i]
          if ink != nil:
            for c in 0 .. 3: raw[o + c] = ink[4 * i + c]
          elif gray:
            raw[o] = byte((int((p shr 16) and 255) * 299 + int((p shr 8) and 255) * 587 + int(p and 255) * 114 + 500) div 1000)
          else:
            raw[o] = byte((p shr 16) and 255); raw[o + 1] = byte((p shr 8) and 255); raw[o + 2] = byte(p and 255)
          if alpha: raw[o + colorS] = byte(p shr 24)
          o += spp
      if compression in {tcLzw, tcDeflate}:
        # (the horizontal predictor: each sample less the one to its left)
        for y in 0 ..< y1 - y0:
          for x in countdown(w * spp - 1, spp):
            raw[y * rowBytes + x] = raw[y * rowBytes + x] - raw[y * rowBytes + x - spp]
      op[k] = case compression
              of tcNone: raw
              of tcLzw: lzwTiffEncode(raw)
              of tcDeflate: zlibCompressLevel(raw, 6)
              of tcPackBits:
                var o2: seq[byte]
                for y in 0 ..< y1 - y0: o2.add packBits(raw.toOpenArray(y * rowBytes, (y + 1) * rowBytes - 1))
                o2
  pieces(strips, body)
  # the file: header, the strips, the tags
  let mm = photoshop.len > 0            # (Motorola order: big-endian)
  var o = if mm: "MM\0*" else: "II*\0"
  o.add "\0\0\0\0"                    # (where the tags are, filled in after)
  var offsets: seq[int]
  for s in outs:
    offsets.add o.len
    if s.len > 0:
      let at = o.len
      o.setLen(at + s.len)
      copyMem(addr o[at], unsafeAddr s[0], s.len)
    if (o.len and 1) == 1: o.add '\0'
  proc le16(v: int) =
    if mm: (o.add char((v shr 8) and 255); o.add char(v and 255))
    else: (o.add char(v and 255); o.add char((v shr 8) and 255))
  proc le32(v: int) =
    if mm:
      o.add char((v shr 24) and 255); o.add char((v shr 16) and 255); o.add char((v shr 8) and 255); o.add char(v and 255)
    else:
      o.add char(v and 255); o.add char((v shr 8) and 255); o.add char((v shr 16) and 255); o.add char((v shr 24) and 255)
  # values that do not fit in a tag
  let bpsAt = o.len
  for _ in 0 ..< spp: le16(8)
  let offAt = o.len
  for v in offsets: le32(v)
  let cntAt = o.len
  for s in outs: le32(s.len)
  let resAt = o.len
  le32(dpi); le32(1)
  let iccAt = o.len
  o.add icc                             # (its color profile)
  if (o.len and 1) == 1: o.add '\0'
  let psAt = o.len
  o.add photoshop                       # (Photoshop's layers)
  if (o.len and 1) == 1: o.add '\0'
  let ifd = o.len
  if mm:
    o[4] = char((ifd shr 24) and 255); o[5] = char((ifd shr 16) and 255); o[6] = char((ifd shr 8) and 255); o[7] = char(ifd and 255)
  else:
    o[4] = char(ifd and 255); o[5] = char((ifd shr 8) and 255); o[6] = char((ifd shr 16) and 255); o[7] = char((ifd shr 24) and 255)
  var tags: seq[(int, int, int, int)]      # tag, type, count, value
  tags.add (256, 4, 1, w)
  tags.add (257, 4, 1, h)
  tags.add (258, 3, spp, (if spp <= 2: 8 or (if spp == 2: 8 shl 16 else: 0) else: bpsAt))
  tags.add (259, 3, 1, (case compression
                        of tcNone: 1
                        of tcLzw: 5
                        of tcDeflate: 8
                        of tcPackBits: 32773))
  tags.add (262, 3, 1, (if isCmyk: 5 elif gray: 1 else: 2))
  tags.add (273, 4, strips, (if strips == 1: offsets[0] else: offAt))
  tags.add (277, 3, 1, spp)
  tags.add (278, 4, 1, rowsPer)
  tags.add (279, 4, strips, (if strips == 1: outs[0].len else: cntAt))
  tags.add (282, 5, 1, resAt)
  tags.add (283, 5, 1, resAt)
  tags.add (284, 3, 1, 1)
  tags.add (296, 3, 1, 2)
  if compression in {tcLzw, tcDeflate}: tags.add (317, 3, 1, 2)
  if alpha: tags.add (338, 3, 1, 2)
  if icc.len > 0: tags.add (34675, 7, icc.len, iccAt)
  if photoshop.len > 0: tags.add (37724, 7, photoshop.len, psAt)
  le16(tags.len)
  for (tag, kind, cnt, v) in tags:
    le16(tag); le16(kind); le32(cnt)
    if kind == 3 and cnt == 1:
      le16(v); le16(0)
    elif kind == 3 and cnt == 2:
      le16(v and 0xFFFF); le16(v shr 16)
    else: le32(v)
  le32(0)
  o

proc tiffImageSource*(data: string): tuple[layers: string; littleEndian: bool; photometric: int] =
  ## What a TIFF's first directory keeps in tag 37724 (ImageSourceData:
  ## Photoshop's layers; "" none), whether the file is in Intel order, and
  ## its photometric interpretation (1 gray, 2 RGB, 5 CMYK...).
  result.photometric = 2
  if data.len < 8 or data[0 .. 1] notin ["II", "MM"]: return
  let le = data[0] == 'I'
  result.littleEndian = le
  proc r16(at: int): int =
    if at < 0 or at + 2 > data.len: return 0
    if le: ord(data[at]) or (ord(data[at + 1]) shl 8) else: (ord(data[at]) shl 8) or ord(data[at + 1])
  proc r32(at: int): int =
    if at < 0 or at + 4 > data.len: return 0
    if le: ord(data[at]) or (ord(data[at + 1]) shl 8) or (ord(data[at + 2]) shl 16) or (ord(data[at + 3]) shl 24)
    else: (ord(data[at]) shl 24) or (ord(data[at + 1]) shl 16) or (ord(data[at + 2]) shl 8) or ord(data[at + 3])
  let ifd = r32(4)
  let n = r16(ifd)
  for i in 0 ..< min(n, 1000):
    let e = ifd + 2 + 12 * i
    case r16(e)
    of 262: result.photometric = r16(e + 8)
    of 37724:
      let cnt = r32(e + 4)
      let off = if cnt <= 4: e + 8 else: r32(e + 8)
      if cnt > 0 and off >= 0 and off + cnt <= data.len: result.layers = data[off ..< off + cnt]
    else: discard
