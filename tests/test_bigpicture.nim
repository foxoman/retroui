## Tests of `retroui/bigpicture`: very big pictures read a band at a time.
##
## - Each kind it reads, made here at an odd size (with the kit's encoders;
##   an interlaced PNG and BMPs by hand): `readScaled` and `readRegion`
##   must give exactly what decoding the file whole and then `thumbnail`,
##   or cutting, gives -- tests/data's progressive and turned JPEGs too,
##   the progressive one also read in many passes.
## - A 12000 x 9000 PNG and JPEG of a known pattern: made small and cut,
##   checked against the pattern; and, each read in a process of its own,
##   the memory that took at its peak (VmHWM): a small part of the 432 MB
##   the picture takes whole.
## - Retro Photo's way in (`retroui/photofiles`): a picture too big to edit
##   whole refused plainly, opened as a smaller copy or as a part.
## - TIFF and TGA headers that claim more pixels than their data holds
##   refused before the memory is taken; valid ones read as before.
## - The files damaged a few hundred ways (cut short, bytes changed) and
##   read again: a picture or `BigPictureError`, never another error or a
##   crash.

{.passC: "-O2".}   # (the C optimized, in a debug build too: the big pictures made and read in seconds)

import std/[os, osproc, strutils, random, times, monotimes]
import retroui/[gfx, imaging, jpeg, imageformats, codec, busy, bigpicture, photo, photofiles]

const
  rounds {.intdefine.} = 200      ## damaged copies of each file (-d:rounds=2000: a longer run)
  seed {.intdefine.} = 20261101
  bigW = 12000
  bigH = 9000

let dataDir = currentSourcePath().parentDir / "data"

proc heapPeak(): int =
  ## The most memory Nim's allocator has held (0 with -d:useMalloc: the
  ## checks below then rest on the error coming before any memory is taken).
  when defined(useMalloc): 0 else: getMaxMem()

proc peakKb(): int =
  ## (this process's peak memory, VmHWM, in KB; 0 where it is not told)
  try:
    for line in lines("/proc/self/status"):
      if line.startsWith("VmHWM:"): return parseInt(line.splitWhitespace()[1])
  except CatchableError: discard

# ---- helpers ------------------------------------------------------------------------------------

proc madePicture(w, h: int; alpha, gray: bool; seed: int): Bitmap =
  ## (gradients, a checker, some noise, holes in the alpha: every filter
  ## and block has work)
  var r = initRand(seed)
  result = newBitmap(w, h)
  for y in 0 ..< h:
    for x in 0 ..< w:
      let n = r.rand(31)
      let red = (x * 255 div w + n) and 255
      let green = ((y * 255 div h) xor (if ((x shr 5) + (y shr 5)) mod 2 == 0: 0 else: 60)) and 255
      let blue = (x + 2 * y) and 255
      let a = if not alpha: 255
              elif ((x shr 4) + (y shr 4)) mod 5 == 0: 0
              else: 128 + (x and 127)
      result.px[y * w + x] =
        if gray: (uint32(a) shl 24) or (uint32(red) * 0x010101'u32)
        else: (uint32(a) shl 24) or (uint32(red) shl 16) or (uint32(green) shl 8) or uint32(blue)
  result.changed()

proc samePixels(a, b: Bitmap): bool =
  a != nil and b != nil and a.w == b.w and a.h == b.h and a.px == b.px

proc cutOut(b: Bitmap; x, y, w, h: int): Bitmap =
  result = newBitmap(w, h)
  for j in 0 ..< h:
    for i in 0 ..< w: result.px[j * w + i] = b.px[(y + j) * b.w + x + i]

proc boxed(b: Bitmap; s: int): Bitmap =
  ## (each `s` x `s` square averaged, as `readRegion` makes it)
  let w = (b.w + s - 1) div s
  let h = (b.h + s - 1) div s
  result = newBitmap(w, h)
  for y in 0 ..< h:
    for x in 0 ..< w:
      var a, r, g, bl, n = 0'u64
      for yy in y * s ..< min(b.h, y * s + s):
        for xx in x * s ..< min(b.w, x * s + s):
          let p = b.px[yy * b.w + xx]
          a += p shr 24; r += (p shr 16) and 255; g += (p shr 8) and 255; bl += p and 255
          inc n
      result.px[y * w + x] = (uint32(a div n) shl 24) or (uint32(r div n) shl 16) or
                             (uint32(g div n) shl 8) or uint32(bl div n)

proc pngChunk(o: var string; kind: string; data: openArray[byte]) =
  ## (a PNG chunk, its CRC)
  var body = newSeq[byte]()
  for c in kind: body.add byte(c)
  body.add data
  for v in [data.len shr 24, data.len shr 16, data.len shr 8, data.len]: o.add char(v and 255)
  for v in body: o.add char(v)
  let c = crc32(body)
  for sh in [24, 16, 8, 0]: o.add char((c shr sh) and 255)

proc interlacedPng(b: Bitmap): string =
  ## (an Adam7 PNG, RGBA, 8 bits, each row's filter in turn 0 .. 4: the kit
  ## writes none)
  const passes = [(0, 0, 8, 8), (4, 0, 8, 8), (0, 4, 4, 8), (2, 0, 4, 4), (0, 2, 2, 4), (1, 0, 2, 2), (0, 1, 1, 2)]
  var raw: seq[byte]
  var k = 0
  for (x0, y0, dx, dy) in passes:
    let pw = (b.w - x0 + dx - 1) div dx
    let ph = (b.h - y0 + dy - 1) div dy
    if pw <= 0 or ph <= 0: continue
    var prev = newSeq[byte](pw * 4)
    for j in 0 ..< ph:
      var cur = newSeq[byte](pw * 4)
      for i in 0 ..< pw:
        let p = b.px[(y0 + j * dy) * b.w + x0 + i * dx]
        cur[4 * i] = byte((p shr 16) and 255); cur[4 * i + 1] = byte((p shr 8) and 255)
        cur[4 * i + 2] = byte(p and 255); cur[4 * i + 3] = byte(p shr 24)
      let f = k mod 5
      inc k
      raw.add byte(f)
      for i in 0 ..< cur.len:
        let a = if i >= 4: int(cur[i - 4]) else: 0
        let up = int(prev[i])
        let c = if i >= 4: int(prev[i - 4]) else: 0
        let pa = abs(up - c)
        let pb = abs(a - c)
        let pc = abs(a + up - 2 * c)
        let guess = case f
                    of 0: 0
                    of 1: a
                    of 2: up
                    of 3: (a + up) div 2
                    else: (if pa <= pb and pa <= pc: a elif pb <= pc: up else: c)
        raw.add byte((int(cur[i]) - guess) and 255)
      prev = cur
  result = "\x89PNG\r\n\x1a\n"
  var ihdr: seq[byte]
  for v in [b.w, b.h]:
    for sh in [24, 16, 8, 0]: ihdr.add byte((v shr sh) and 255)
  ihdr.add [8'u8, 6, 0, 0, 1]
  result.pngChunk("IHDR", ihdr)
  result.pngChunk("IDAT", zlibCompress(raw))
  result.pngChunk("IEND", [])

proc bmpOf(b: Bitmap; bits: int; topDown: bool): string =
  ## (a BMP of 24 or 32 bits, its rows from the bottom up or the top down)
  let stride = ((b.w * bits + 31) div 32) * 4
  proc le(o: var string; v, n: int) =
    for i in 0 ..< n: o.add char((v shr (8 * i)) and 255)
  result = "BM"
  result.le(54 + stride * b.h, 4); result.le(0, 4); result.le(54, 4)
  result.le(40, 4); result.le(b.w, 4); result.le(if topDown: -b.h else: b.h, 4)
  result.le(1, 2); result.le(bits, 2); result.le(0, 4); result.le(stride * b.h, 4)
  result.le(2835, 4); result.le(2835, 4); result.le(0, 4); result.le(0, 4)
  for j in 0 ..< b.h:
    let y = if topDown: j else: b.h - 1 - j
    let start = result.len
    for x in 0 ..< b.w:
      let p = b.px[y * b.w + x]
      result.add char(p and 255); result.add char((p shr 8) and 255); result.add char((p shr 16) and 255)
      if bits == 32: result.add char(p shr 24)
    while result.len - start < stride: result.add '\0'

proc checkFile(path: string; whole: Bitmap; jpegData = "") =
  ## `readScaled` and `readRegion` of `path` against `whole`, the file
  ## decoded whole (a JPEG made much smaller: at an eighth first, as
  ## `loadPicture` does it).
  let name = path.extractFilename
  let info = bigPictureInfo(path)
  doAssert info.w == whole.w and info.h == whole.h, name & ": its size from the header"
  for (mw, mh) in [(100000, 100000), (512, 512), (300, 97), (whole.w, whole.h div 3), (1, 1)]:
    var want: Bitmap
    if jpegData.len > 0:
      let (rw, rh) = jpegSize(jpegData)
      want = thumbnail(decodeJpeg(jpegData, (if rw div 8 >= mw or rh div 8 >= mh: 8 else: 1)), mw, mh)
    else:
      want = thumbnail(whole, mw, mh)
    doAssert samePixels(readScaled(path, mw, mh), want), name & ": readScaled " & $mw & " x " & $mh
  for (x, y, w, h, s) in [(0, 0, 100000, 100000, 1), (17, 33, 200, 150, 1), (whole.w - 5, whole.h - 7, 50, 50, 1),
                          (3, 5, 400, 300, 3), (0, 0, 100000, 100000, 7)]:
    let x1 = min(whole.w, x + w)
    let y1 = min(whole.h, y + h)
    let want = boxed(cutOut(whole, x, y, x1 - x, y1 - y), s)
    doAssert samePixels(readRegion(path, x, y, w, h, s), want), name & ": readRegion " & $(x, y, w, h, s)

# ---- every kind, against its whole decode ----------------------------------------------------------

proc everyKind(dir: string): seq[string] =
  ## Writes a picture of each kind (1201 x 857) and checks it; the files written.
  let t0 = epochTime()
  let rgba = madePicture(1201, 857, alpha = true, gray = false, 1)
  let rgb = madePicture(1201, 857, alpha = false, gray = false, 2)
  let gray = madePicture(1201, 857, alpha = false, gray = true, 3)
  var files: seq[(string, string)]           # (name, bytes)
  files.add ("rgba.png", encodePng(rgba))
  files.add ("rgb.png", encodePng(rgb, alpha = 0))
  files.add ("gray.png", encodePng(gray, gray = 1))
  var deep = newSeq[uint16](rgba.w * rgba.h * 4)
  for i, p in rgba.px:
    for c, sh in [16, 8, 0, 24]: deep[4 * i + c] = uint16((p shr sh) and 255) * 257 + uint16(i and 3)
  files.add ("deep.png", encodePng16(rgba.w, rgba.h, deep))
  files.add ("palette.png", encodePngIndexed(rgb.w, rgb.h, quantize(rgb.px, 16)))
  files.add ("interlaced.png", interlacedPng(rgba))
  files.add ("rgb444.jpg", encodeJpeg(rgb, 90))
  files.add ("rgb420.jpg", encodeJpeg(rgb, 80, chroma420 = true))
  files.add ("progressive.jpg", readFile(dataDir / "quad-progressive.jpg"))
  files.add ("turned.jpg", readFile(dataDir / "quad-rotated.jpg"))
  files.add ("rgb24up.bmp", bmpOf(rgb, 24, topDown = false))
  files.add ("rgba32down.bmp", bmpOf(rgba, 32, topDown = true))
  for c in TiffCompression:
    files.add ("rgb-" & $c & ".tif", encodeTiff(rgb, c, alpha = false))
  files.add ("rgba-lzw.tif", encodeTiff(rgba, tcLzw))
  files.add ("gray-zip.tif", encodeTiff(gray, tcDeflate, alpha = false, gray = true))
  files.add ("rgb.tga", encodeTga(rgb, alpha = false, rle = false))
  files.add ("rgba-rle.tga", encodeTga(rgba, alpha = true, rle = true))
  for (name, bytes) in files:
    let path = dir / name
    writeFile(path, bytes)
    result.add path
    let ext = name.splitFile.ext
    let whole = case ext
      of ".png": decodePng(bytes)
      of ".jpg": decodeJpeg(bytes)
      of ".bmp": decodeBmp(bytes)
      of ".tif": decodeTiff(bytes)
      else: decodeTga(bytes)
    if ext in [".bmp", ".tif", ".tga"] or name in ["rgba.png", "rgb.png", "interlaced.png"]:
      # (kept exactly: the whole decode is right, and so the reference)
      let src = if name.startsWith("rgba"): rgba elif name == "interlaced.png": rgba elif name.startsWith("gray"): gray else: rgb
      doAssert samePixels(whole, src), name & ": decoded whole"
    checkFile(path, whole, (if ext == ".jpg": bytes else: ""))
  # a progressive JPEG read in passes (its coefficients a few rows at a time)
  let saved = coefficientBudget
  coefficientBudget = 4096
  checkFile(dir / "progressive.jpg", decodeJpeg(readFile(dir / "progressive.jpg")),
            readFile(dir / "progressive.jpg"))
  coefficientBudget = saved
  echo "  ", files.len, " kinds of file read in bands, as their whole decode: ",
       formatFloat(epochTime() - t0, ffDecimal, 1), " s"

# ---- a big picture of a known pattern ------------------------------------------------------------------

proc bigPattern(x, y: int): uint32 =
  ## (red across, green down, blue in squares of 64)
  0xFF000000'u32 or (uint32(x and 255) shl 16) or (uint32(y and 255) shl 8) or
    uint32(((x shr 6) + 3 * (y shr 6)) and 255)

proc patternBox(x0, y0, x1, y1: int): uint32 =
  ## (the pattern averaged over x0 ..< x1, y0 ..< y1)
  var r, g, b, n = 0'u64
  for y in y0 ..< y1:
    for x in x0 ..< x1:
      let p = bigPattern(x, y)
      r += (p shr 16) and 255; g += (p shr 8) and 255; b += p and 255
      inc n
  0xFF000000'u32 or (uint32(r div n) shl 16) or (uint32(g div n) shl 8) or uint32(b div n)

proc colorDiff(a, b: uint32): int =
  abs(int((a shr 16) and 255) - int((b shr 16) and 255)) + abs(int((a shr 8) and 255) - int((b shr 8) and 255)) +
    abs(int(a and 255) - int(b and 255))

proc checkScaled(b: Bitmap; exact: bool; name: string; probes = 400; tolerance = 4.0) =
  ## (`readScaled` of the pattern: each pixel the average of its box --
  ## or near it, by `tolerance` on average)
  var r = initRand(seed)
  var err = 0
  for _ in 0 ..< probes:
    let x = r.rand(b.w - 1)
    let y = r.rand(b.h - 1)
    let sx0 = x * bigW div b.w
    let sy0 = y * bigH div b.h
    let want = patternBox(sx0, sy0, max(sx0 + 1, (x + 1) * bigW div b.w), max(sy0 + 1, (y + 1) * bigH div b.h))
    if exact: doAssert b.px[y * b.w + x] == want, name & ": pixel " & $(x, y)
    err += colorDiff(b.px[y * b.w + x], want)
  if not exact:
    doAssert err / (3 * probes) < tolerance, name & ": off by " & $(err / (3 * probes)) & " on average"

proc measured(args: string): tuple[w, h, kb, ms: int] =
  ## (a read in a process of its own: what it made, its peak memory, its time)
  let (o, code) = execCmdEx(quoteShell(getAppFilename()) & " --measure " & args)
  doAssert code == 0, o
  for line in o.splitLines:
    if line.startsWith("measured "):
      let f = line.splitWhitespace()
      return (parseInt(f[1]), parseInt(f[2]), parseInt(f[3]), parseInt(f[4]))
  doAssert false, "no answer: " & o

proc bigPictures(dir: string) =
  var t0 = epochTime()
  let png = dir / "big.png"
  let jpg = dir / "big.jpg"
  block:
    var b = newBitmap(bigW, bigH)
    let p = cast[ptr UncheckedArray[uint32]](addr b.px[0])
    for y in 0 ..< bigH:
      for x in 0 ..< bigW: p[y * bigW + x] = bigPattern(x, y)
    writeFile(png, encodePng(b, 1, alpha = 0, gray = 0))
    writeFile(jpg, encodeJpeg(b, 90))
  echo "  a ", bigW, " x ", bigH, " PNG (", getFileSize(png) div 1024, " KB) and JPEG (",
       getFileSize(jpg) div 1024, " KB) made: ", formatFloat(epochTime() - t0, ffDecimal, 1), " s"
  t0 = epochTime()
  for (path, kind) in [(png, "png"), (jpg, "jpeg")]:
    let info = bigPictureInfo(path)
    doAssert info.w == bigW and info.h == bigH and info.kind == kind
  # the PNG: made small, cut, made small in squares -- exactly the pattern's averages
  let s = readScaled(png, 1024, 1024)
  doAssert s.w == 1024 and s.h == 768
  checkScaled(s, exact = true, "big.png")
  let part = readRegion(png, 5000, 4000, 2000, 1500)
  doAssert part.w == 2000 and part.h == 1500
  for j in 0 ..< 1500:
    for i in 0 ..< 2000: doAssert part.px[j * 2000 + i] == bigPattern(5000 + i, 4000 + j), "big.png: a part"
  let quarter = readRegion(png, 101, 203, 1000, 802, scale = 4)
  doAssert quarter.w == 250 and quarter.h == 201
  for j in 0 ..< quarter.h:
    for i in 0 ..< quarter.w:
      doAssert quarter.px[j * 250 + i] ==
               patternBox(101 + 4 * i, 203 + 4 * j, 101 + 4 * i + 4, min(203 + 802, 203 + 4 * j + 4))
  let thumb = loadPicture(png, 256, 256)                    # (loadPicture reads it in bands)
  doAssert thumb.w == 256 and thumb.h == 192
  checkScaled(thumb, exact = true, "loadPicture(big.png)", 100)
  # the JPEG: near the pattern (it is lossy)
  let js = readScaled(jpg, 1024, 1024)
  doAssert js.w == 1024 and js.h == 768
  # (made from each block's average, as `loadPicture` always did: as the
  # picture decoded whole at an eighth, then `thumbnail`; and near the pattern)
  doAssert samePixels(js, thumbnail(decodeJpeg(readFile(jpg), 8), 1024, 1024)), "big.jpg: made small"
  checkScaled(js, exact = false, "big.jpg", tolerance = 12.0)
  let jp = readRegion(jpg, 5003, 4001, 2000, 1500)
  doAssert jp.w == 2000 and jp.h == 1500
  var err = 0
  for j in 0 ..< 1500:
    for i in 0 ..< 2000: err += colorDiff(jp.px[j * 2000 + i], bigPattern(5003 + i, 4001 + j))
  doAssert err / (3 * 2000 * 1500) < 4.0, "big.jpg: a part, off by " & $(err / (3 * 2000 * 1500))
  echo "  made small and cut, checked against the pattern: ", formatFloat(epochTime() - t0, ffDecimal, 1), " s"
  # the memory each read takes at its peak, in a process of its own
  if peakKb() > 0:
    let whole = bigW * bigH * 4 div 1024
    let base = measured("none").kb
    for (what, args) in [("PNG made 1024 px", "scaled " & quoteShell(png) & " 1024 1024"),
                         ("JPEG made 1024 px", "scaled " & quoteShell(jpg) & " 1024 1024"),
                         ("PNG part 2000 x 1500", "region " & quoteShell(png) & " 5000 4000 2000 1500"),
                         ("JPEG part 2000 x 1500", "region " & quoteShell(jpg) & " 5000 4000 2000 1500"),
                         ("PNG by loadPicture 256 px", "load " & quoteShell(png) & " 256 256")]:
      let m = measured(args)
      echo "  ", what, ": ", m.ms, " ms, at most ", (m.kb - base) div 1024, " MB more than an idle process (",
           base div 1024, " MB); the picture whole: ", whole div 1024, " MB"
      # (under the sanitizers each allocation carries their own bookkeeping: the
      # memory is theirs as much as ours, and not measured)
      when not defined(retroSanitized):
        doAssert m.kb - base < whole div 8, what & ": " & $(m.kb - base) & " KB"

# ---- Retro Photo: a picture too big to edit whole ------------------------------------------------------

proc photoWay(dir: string) =
  let path = dir / "rgb.png"                       # (1201 x 857: 1.03 megapixels)
  let small = dir / "small.png"
  writeFile(small, encodePng(madePicture(96, 64, false, false, 9)))
  let saved = maxPixels
  maxPixels = 300_000                              # (a device that edits 0.3 megapixels at most)
  try:
    doAssert bigPictureSize(path) == (1201, 857)
    doAssert pictureTooBig(path)
    doAssert not pictureTooBig(small)
    doAssert pictureTooBig(small, freeBytes = 10_000)     # (96 x 64 x 12 bytes: more than is free)
    let (lw, lh) = largestSize(1201, 857)
    doAssert sizeOk(lw, lh) and lw * lh > 290_000 and abs(lw / lh - 1201 / 857) < 0.01
    doAssert largestSize(96, 64) == (96, 64)
    try:
      discard openPicture(path)
      doAssert false, "openPicture: too big, opened"
    except PictureTooBigError as e:
      doAssert e.w == 1201 and e.h == 857
    let d = openPictureScaled(path)
    doAssert (d.w, d.h) == fittedSize(1201, 857, lw, lh) and d.path == "" and d.layers.len == 1
    doAssert d.layers[0].px == readScaled(path, lw, lh).px
    let p = openPictureRegion(path, 100, 50, 400, 300)
    doAssert p.w == 400 and p.h == 300 and p.path == ""
    doAssert p.layers[0].px == readRegion(path, 100, 50, 400, 300).px
    let all = openPictureRegion(path, 0, 0, 1201, 857)    # (more than allowed: its middle)
    doAssert sizeOk(all.w, all.h) and all.w * all.h > 290_000
    doAssert all.layers[0].px == readRegion(path, (1201 - all.w) div 2, (857 - all.h) div 2, all.w, all.h).px
  finally:
    maxPixels = saved
  echo "  Retro Photo: too big to edit whole -- a smaller copy, a part"

# ---- headers that claim too much ---------------------------------------------------------------------

proc claims(dir: string) =
  let pic = madePicture(40, 30, alpha = false, gray = false, 5)
  # valid files read as before
  for c in TiffCompression:
    doAssert samePixels(decodeTiff(encodeTiff(pic, c, alpha = false)), pic), "TIFF " & $c
  doAssert samePixels(decodeTga(encodeTga(pic, alpha = false)), pic)
  doAssert samePixels(decodeTga(encodeTga(pic, alpha = false, rle = false)), pic)
  # a TIFF whose width and height say 17000 x 17000 (under the cap; 2.3 GB of samples)
  var t = encodeTiff(pic, tcLzw, alpha = false)
  let ifd = ord(t[4]) or (ord(t[5]) shl 8) or (ord(t[6]) shl 16) or (ord(t[7]) shl 24)
  for k in 0 ..< (ord(t[ifd]) or (ord(t[ifd + 1]) shl 8)):
    let e = ifd + 2 + 12 * k
    let tag = ord(t[e]) or (ord(t[e + 1]) shl 8)
    if tag in [256, 257, 278]:
      t[e + 8] = char(17000 and 255); t[e + 9] = char(17000 shr 8)
  let before = heapPeak()
  try:
    discard decodeTiff(t)
    doAssert false, "TIFF of 17000 x 17000 in a few bytes: read"
  except FormatError as e:
    doAssert "bigger than its data" in e.msg, e.msg
  doAssert heapPeak() - before < 64 shl 20, "TIFF: memory taken before the check"
  writeFile(dir / "claims.tif", t)
  try:
    discard readScaled(dir / "claims.tif", 100, 100)
    doAssert false
  except BigPictureError: discard
  # TGAs that say 15000 x 15000 (run-length coded) and 10000 x 10000 (not)
  for (rle, side) in [(true, 15000), (false, 10000)]:
    var g = encodeTga(pic, alpha = false, rle = rle)
    g[12] = char(side and 255); g[13] = char(side shr 8); g[14] = char(side and 255); g[15] = char(side shr 8)
    let before = heapPeak()
    try:
      discard decodeTga(g)
      doAssert false, "TGA of " & $side & " in a few bytes: read"
    except FormatError: discard
    doAssert heapPeak() - before < 64 shl 20, "TGA: memory taken before the check"
    writeFile(dir / "claims.tga", g)
    try:
      discard readScaled(dir / "claims.tga", 100, 100)
      doAssert false
    except BigPictureError: discard
  echo "  TIFF and TGA headers claiming more than their data: refused first"

# ---- progress, Cancel --------------------------------------------------------------------------------

proc progressAndCancel(dir: string) =
  var seen: seq[float]
  let sp = addr seen
  discard readScaled(dir / "rgba.png", 100, 100, proc (f: float) {.closure, gcsafe.} = sp[].add f)
  doAssert seen.len > 0 and seen[^1] == 1.0
  for i in 1 ..< seen.len: doAssert seen[i] >= seen[i - 1]
  for name in ["rgba.png", "rgb444.jpg", "rgb-LZW.tif"]:
    try:
      discard readScaled(dir / name, 1000, 1000,
                         proc (f: float) {.closure, gcsafe.} = raise newException(BusyCancelled, "stop"))
      doAssert false, name & ": not stopped"
    except BusyCancelled: discard
  echo "  progress told; stopped when asked"

# ---- damaged files -------------------------------------------------------------------------------------

proc damaged(dir: string; files: seq[string]) =
  let t0 = epochTime()
  var rng = initRand(seed)
  var reads, pictures = 0
  for path in files:
    let good = readFile(path)
    let bad = dir / ("bad" & path.splitFile.ext)
    for k in 0 ..< rounds:
      var d = good
      if k mod 3 == 0:
        d.setLen(rng.rand(d.len - 1))                   # (cut short)
      else:
        # (bytes changed: most often where the headers are)
        for _ in 0 .. rng.rand(1 .. 8):
          let i = if rng.rand(1) == 0: rng.rand(min(d.len, 600) - 1) else: rng.rand(d.len - 1)
          d[i] = char(rng.rand(255))
      writeFile(bad, d)
      template tried(what: string; body: untyped) =
        try:
          let b = body
          doAssert b != nil and b.w > 0 and b.h > 0 and b.px.len == b.w * b.h
          inc pictures
        except BigPictureError: discard
        except CatchableError, Defect:
          doAssert false, path.extractFilename & " (" & $k & ", " & what & "): " & getCurrentExceptionMsg()
        inc reads
      discard bigPictureInfo(bad)
      tried("scaled"): readScaled(bad, (if k mod 4 == 0: 2000 else: 37), 29)
      tried("region"): readRegion(bad, rng.rand(80), rng.rand(60), 1 + rng.rand(90), 1 + rng.rand(70), 1 + rng.rand(2))
  echo "  ", reads, " reads of damaged files (", pictures, " gave a picture, the rest BigPictureError): ",
       formatFloat(epochTime() - t0, ffDecimal, 1), " s"

# ---- main --------------------------------------------------------------------------------------------

proc main() =
  if paramCount() >= 2 and paramStr(1) == "--measure":
    # (a read in a process of its own, for its peak memory)
    let t0 = getMonoTime()
    var b = newBitmap(1, 1)
    case paramStr(2)
    of "scaled": b = readScaled(paramStr(3), parseInt(paramStr(4)), parseInt(paramStr(5)))
    of "region": b = readRegion(paramStr(3), parseInt(paramStr(4)), parseInt(paramStr(5)),
                                parseInt(paramStr(6)), parseInt(paramStr(7)))
    of "load": b = loadPicture(paramStr(3), parseInt(paramStr(4)), parseInt(paramStr(5)))
    else: discard
    echo "measured ", b.w, " ", b.h, " ", peakKb(), " ", (getMonoTime() - t0).inMilliseconds
    return
  let t0 = epochTime()
  let dir = getTempDir() / ("retro-bigpicture-" & $getCurrentProcessId())
  removeDir(dir)
  createDir(dir)
  try:
    let files = everyKind(dir)
    progressAndCancel(dir)
    photoWay(dir)
    claims(dir)
    # (small ones to damage: each kind)
    var few: seq[string]
    for name in ["rgba.png", "interlaced.png", "palette.png", "rgb420.jpg", "progressive.jpg", "rgb24up.bmp",
                 "rgb-LZW.tif", "rgb-ZIP.tif", "rgb-PackBits.tif", "rgba-rle.tga"]:
      let src = dir / name
      let b = readScaled(src, 61, 47)
      let small = dir / ("small-" & name)
      let ext = name.splitFile.ext
      writeFile(small, case name
        of "interlaced.png": interlacedPng(b)
        of "palette.png": encodePngIndexed(b.w, b.h, quantize(b.px, 16))
        of "rgb420.jpg": encodeJpeg(b, 80, chroma420 = true)
        of "progressive.jpg": readFile(src)
        of "rgb24up.bmp": bmpOf(b, 24, topDown = false)
        of "rgb-LZW.tif": encodeTiff(b, tcLzw, alpha = false)
        of "rgb-ZIP.tif": encodeTiff(b, tcDeflate)
        of "rgb-PackBits.tif": encodeTiff(b, tcPackBits, alpha = false)
        of "rgba-rle.tga": encodeTga(b, alpha = true, rle = true)
        else: encodePng(b))
      discard ext
      few.add small
    damaged(dir, few)
    discard files
    bigPictures(dir)
  finally:
    removeDir(dir)
  echo "bigpicture: ok (", formatFloat(epochTime() - t0, ffDecimal, 1), " s)"

main()
