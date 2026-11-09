## More kinds of picture file shown by the toolkit: call `addMorePictures()`
## once at the start, and `loadPicture` -- and so the file lists' pictures,
## the previews and the Open dialogs -- shows these files too:
##
## - everywhere: JPEG XL, SVG (drawn at the size asked for), TIFF, TGA,
##   OpenEXR and Radiance HDR (their light made 8-bit sRGB), Photoshop's
##   .psd and .psb (the thumbnail Photoshop keeps in them), Retro Photo
##   documents (.rpd, .rp3: their preview), and camera raw files -- DNG,
##   NEF, NRW, ARW, SRF, SR2, CR2, CR3, CRW, ORF, RW2, PEF, RAF, 3FR, ERF,
##   KDC, MRW, SRW, X3F, IIQ, RWL -- by the preview JPEG the camera put in
##   them;
## - on the desktops also GIF (its first picture), WebP, and HEIC, HEIF and
##   AVIF (by the system's libraries or a converter program:
##   `retroui/systemimage`). Android and iOS decode these themselves.
##
## ```nim
## import retroui/morepictures
## addMorePictures()                                   # before pictures are asked for
## let thumb = loadPicture("IMG_0042.CR3", 256, 256)   # the camera's preview, made small
## let big = rawPreview("DSC_0042.NEF", 2048, 2048)    # its biggest preview, fitted
## let any = readMorePicture("render.exr", 512, 512)   # one of `morePictureKinds`, directly
## ```
##
## A raw photo is never developed here (that is `retroui/rawformats`): of the
## JPEG pictures in it -- found through its TIFF directories (and the
## maker's notes of Nikon, Olympus and Pentax), or else by looking through
## its bytes -- the smallest that still fills the size asked for is decoded
## (at an eighth of its size when that is still enough), and turned the
## way the camera was held. Only the start of a big file is read when the
## preview is there.
##
## Every reader is safe with damaged or hostile files: sizes are checked
## before memory is taken for them, nothing is read outside the file, and
## a file that cannot be read gives nil (its icon is shown instead).

import std/[os, math, strutils]
import uirelays/target   # (androidApp: an APK, not a program in Termux)
import gfx, imaging, jpeg, imageformats, jxl, exr, svgimport, zip

const desktop = not (androidApp or defined(ios))

when desktop:
  import std/locks
  import webp, mediagif, systemimage

const
  cameraRawKinds* = [".dng", ".nef", ".nrw", ".arw", ".srf", ".sr2", ".cr2", ".cr3", ".crw",
                     ".orf", ".rw2", ".pef", ".raf", ".3fr", ".erf", ".kdc", ".mrw", ".srw",
                     ".x3f", ".iiq", ".rwl"]
    ## Camera raw files: shown by the preview they hold (`rawPreview`).
  systemKinds = [".gif", ".webp", ".heic", ".heif", ".hif", ".avif"]
    ## (what Android and iOS decode themselves)
  ownKinds = [".jxl", ".svg", ".tif", ".tiff", ".tga", ".exr", ".hdr", ".rgbe", ".psd", ".psb",
              ".rpd", ".rp3"]

when desktop:
  const morePictureKinds*: seq[string] = @systemKinds & @ownKinds & @cameraRawKinds
    ## The kinds of file (their extensions) `addMorePictures` adds on this
    ## platform.
else:
  const morePictureKinds*: seq[string] = @ownKinds & @cameraRawKinds
    ## The kinds of file (their extensions) `addMorePictures` adds on this
    ## platform.

const
  MaxFileBytes = 512 shl 20     ## (a file read whole for its picture: no bigger)
  HeadBytes = 4 shl 20          ## (of a raw file, what is read first)
  MaxRawBytes = 200 shl 20      ## (... and at most, when its preview is not there)
  MaxPreviewBytes = 64 shl 20   ## (one preview JPEG)
  MaxProbes = 64                ## (places that look like a JPEG's start looked at, a pass)
  MaxRgbPixels = 4 shl 20       ## (an uncompressed thumbnail: no bigger)
  MaxSvgPixels = 16 shl 20      ## (an SVG drawn no bigger, whatever size is asked for)

# ---- small helpers ----------------------------------------------------------------------------------

proc rd16(s: string; i: int; le: bool): int =
  ## (2 bytes at `i`, in that byte order; 0 outside `s`)
  if i < 0 or i + 2 > s.len: return 0
  if le: ord(s[i]) or (ord(s[i + 1]) shl 8) else: (ord(s[i]) shl 8) or ord(s[i + 1])

proc rd32(s: string; i: int; le: bool): int =
  ## (4 bytes at `i`, unsigned; 0 outside `s`)
  if i < 0 or i + 4 > s.len: return 0
  if le: rd16(s, i, true) or (rd16(s, i + 2, true) shl 16)
  else: (rd16(s, i, false) shl 16) or rd16(s, i + 2, false)

proc pixelsOk(w, h: int): bool =
  ## (a size a picture may have here)
  w > 0 and h > 0 and w.int64 * h.int64 <= maxPicturePixels.int64

proc readUpTo(path: string; limit = MaxFileBytes): string =
  ## (the bytes of the file; "" when it cannot be read or is bigger than `limit`)
  var f: File
  if not open(f, path): return ""
  defer: f.close()
  let n = int(getFileSize(f))
  if n <= 0 or n > limit: return ""
  result = newString(n)
  if f.readBuffer(addr result[0], n) != n: result = ""

proc fitted(b: Bitmap; maxW, maxH: int): Bitmap =
  ## (nil, or `b` made no larger than `maxW` x `maxH`)
  if b == nil or b.w <= 0 or b.h <= 0 or b.px.len < b.w * b.h: nil
  else: thumbnail(b, max(1, maxW), max(1, maxH))

proc finished(b: Bitmap): Bitmap =
  ## (whether all of it is opaque, and that it changed)
  var opaque = true
  for p in b.px:
    if (p shr 24) != 255:
      opaque = false
      break
  b.opaque = opaque
  b.changed()
  b

proc oriented(b: Bitmap; o: int): Bitmap =
  ## (the picture turned the way an EXIF orientation says: 3 half a turn, 6
  ## a quarter clockwise, 8 a quarter counter-clockwise; 2, 4, 5, 7 mirrored)
  if b == nil or o <= 1 or o > 8: return b
  let sideways = o >= 5
  let w = if sideways: b.h else: b.w
  let h = if sideways: b.w else: b.h
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
  result.opaque = b.opaque
  result.changed()

# ---- light: OpenEXR and Radiance HDR ----------------------------------------------------------------

proc screenTable(): seq[uint8] =
  ## (light 0 .. 1, in 4096 steps, as sRGB 0 .. 255)
  result = newSeq[uint8](4097)
  for i in 0 .. 4096:
    let v = i / 4096
    let s = if v <= 0.0031308: v * 12.92 else: 1.055 * pow(v, 1 / 2.4) - 0.055
    result[i] = uint8(clamp(int(s * 255 + 0.5), 0, 255))

proc level(t: seq[uint8]; v: float32): uint32 {.inline.} =
  ## (light as 0 .. 255 on the screen: cut at black and at white; NaN black)
  if not (v > 0): 0'u32
  elif v >= 1: uint32(t[4096])
  else: uint32(t[int(v * 4096 + 0.5)])

proc bitmapOfLight*(w, h: int; light: openArray[float32]; alpha = true): Bitmap =
  ## Light -- 4 floats a pixel, R G B A, linear, 1 the white of the screen,
  ## the colors times their alpha (as OpenEXR keeps them) -- as an 8-bit
  ## sRGB picture: what is brighter than white is cut to white. `alpha`
  ## false: every pixel opaque. Nil when `light` is too short.
  if w <= 0 or h <= 0 or light.len < w * h * 4: return nil
  let t = screenTable()
  result = newBitmap(w, h)
  for i in 0 ..< w * h:
    var r = light[4 * i]
    var g = light[4 * i + 1]
    var b = light[4 * i + 2]
    var a8 = 255'u32
    if alpha:
      var a = light[4 * i + 3]
      if not (a > 0): a = 0
      elif a > 1: a = 1
      if a > 0 and a < 1:
        r /= a
        g /= a
        b /= a
      a8 = uint32(a * 255 + 0.5)
    result.px[i] = (a8 shl 24) or (level(t, r) shl 16) or (level(t, g) shl 8) or level(t, b)
  discard finished(result)

proc exrArea(data: string): int64 =
  ## (the most pixels the header's display and data windows hold; -1 when
  ## it names neither)
  result = -1
  var i = 8
  for _ in 0 ..< 1000:
    let n0 = data.find('\0', i)
    if n0 <= i: return                       # (an empty name: the header's end)
    let t0 = data.find('\0', n0 + 1)
    if t0 < 0 or t0 + 5 > data.len: return
    let size = rd32(data, t0 + 1, true)
    let v = t0 + 5
    if v + size > data.len: return
    if size == 16 and data[i ..< n0] in ["displayWindow", "dataWindow"]:
      template at(k: int): int64 = int64(cast[int32](uint32(rd32(data, v + 4 * k, true))))
      let w = at(2) - at(0) + 1
      let h = at(3) - at(1) + 1
      result = max(result, (if w > 0 and h > 0: w * h else: 0'i64))
    i = v + size

proc exrPicture(path: string): Bitmap =
  ## (an OpenEXR picture's light, 8-bit; with its alpha when it has an A)
  let data = readUpTo(path)
  if not isExr(data) or exrArea(data) > maxPicturePixels.int64: return nil
  let e = readExr(data)
  var hasA = false
  for c in e.channels:
    if c == "A" or c.endsWith(".A"): hasA = true
  bitmapOfLight(e.w, e.h, e.px, hasA)

proc hdrPicture(path: string): Bitmap =
  ## (a Radiance picture: RGBE, flat or run-length packed, made 8-bit; its
  ## rows top or bottom first, left or right first)
  let data = readUpTo(path)
  if not (data.startsWith("#?RADIANCE") or data.startsWith("#?RGBE")): return nil
  var i = 0
  while true:                                # (the header, to an empty line)
    let e = data.find('\n', i)
    if e < 0: return nil
    let empty = e == i
    i = e + 1
    if empty: break
  let e = data.find('\n', i)
  if e < 0 or e - i > 64: return nil
  let parts = data[i ..< e].splitWhitespace
  i = e + 1
  if parts.len != 4 or parts[0] notin ["-Y", "+Y"] or parts[2] notin ["+X", "-X"]: return nil
  let h = parseInt(parts[1])
  let w = parseInt(parts[3])
  if w <= 0 or h <= 0 or w > 32767 or h > 32767 or not pixelsOk(w, h): return nil
  # (each row takes some bytes: a file too short for the size it says is not read)
  let least = if w >= 8: min(4 * w, 4 + 8 * ((w + 126) div 127)) else: 4 * w
  if h.int64 * least > int64(data.len - i): return nil
  var factor: array[256, float32]            # (2 to the power of each exponent, over 256)
  for ex in 1 .. 255: factor[ex] = float32(pow(2.0, float(ex - 136)))
  template light(m: uint8; f: float32): float32 =
    # (the middle of the step, as Radiance reads it -- but 0 stays black)
    (if m == 0: 0'f32 else: (m.float32 + 0.5) * f)
  let t = screenTable()
  # (the picture in a local until it is whole: `return nil` after `result`
  # was set leaks it in Nim 2.2)
  let b = newBitmap(w, h)
  var scan = newSeq[uint8](w * 4)
  for y in 0 ..< h:
    if i + 4 <= data.len and data[i] == '\x02' and data[i + 1] == '\x02' and
       (ord(data[i + 2]) and 0x80) == 0 and rd16(data, i + 2, false) == w and w >= 8:
      # (run-length packed: each component in turn)
      i += 4
      for c in 0 .. 3:
        var x = 0
        while x < w:
          if i >= data.len: return nil
          var n = ord(data[i])
          inc i
          if n > 128:
            n -= 128
            if i >= data.len or x + n > w: return nil
            for k in 0 ..< n: scan[(x + k) * 4 + c] = uint8(ord(data[i]))
            inc i
          else:
            if n == 0 or x + n > w or i + n > data.len: return nil
            for k in 0 ..< n: scan[(x + k) * 4 + c] = uint8(ord(data[i + k]))
            i += n
          x += n
    else:
      if i + w * 4 > data.len: return nil
      for k in 0 ..< w * 4: scan[k] = uint8(ord(data[i + k]))
      i += w * 4
    let row = (if parts[0] == "+Y": h - 1 - y else: y) * w
    let flip = parts[2] == "-X"
    for x in 0 ..< w:
      let ex = int(scan[4 * x + 3])
      var p = 0xFF000000'u32
      if ex > 0:
        let f = factor[ex]
        p = p or (level(t, light(scan[4 * x], f)) shl 16) or
            (level(t, light(scan[4 * x + 1], f)) shl 8) or level(t, light(scan[4 * x + 2], f))
      b.px[row + (if flip: w - 1 - x else: x)] = p
  b.opaque = true
  b.changed()
  result = b

# ---- TIFF, TGA, JPEG XL; GIF, WebP and HEIC on the desktops ----------------------------------------

proc tiffSane(data: string): bool =
  ## (the first directory's numbers are ones `decodeTiff` can work with
  ## without taking more memory than a picture in a file this big can need:
  ## no more values than the file has bytes, the pixels no more than 4096
  ## times the file -- deflate and LZW pack no tighter)
  if data.len < 16 or data[0 .. 1] notin ["II", "MM"]: return false
  let le = data[0] == 'I'
  if rd16(data, 2, le) != 42: return false
  let at = rd32(data, 4, le)
  let n = rd16(data, at, le)
  if at < 8 or n == 0 or at + 2 + 12 * n > data.len: return false
  const tags = [256, 257, 258, 277, 322, 323]
  var v = [0, 0, 1, 1, 0, 0]                 # (width, height, bits, samples, tile width, height)
  var got: array[6, bool]
  for k in 0 ..< n:
    let e = at + 2 + 12 * k
    let kind = rd16(data, e + 2, le)
    let count = rd32(data, e + 4, le)
    let size = case kind
      of 3, 8: 2
      of 4, 9, 11: 4
      of 5, 10, 12: 8
      else: 1
    if count < 0 or count.int64 * size > data.len.int64: return false
    let i = tags.find(rd16(data, e, le))
    if i < 0 or got[i] or count == 0: continue
    # (its first value, read where decodeTiff reads it: the first of a tag
    # given twice; in the entry, or where it points when it does not fit)
    got[i] = true
    let p = if count * size <= 4: e + 8 else: rd32(data, e + 8, le)
    v[i] = case kind
      of 1, 7: (if p < data.len: ord(data[p]) else: 0)
      of 3: rd16(data, p, le)
      of 4: rd32(data, p, le)
      else: 0
  let (w, h, bits, spp, tw, th) = (v[0], v[1], v[2], v[3], v[4], v[5])
  let most = data.len.int64 * 4096 * 8      # (bits of pixels)
  pixelsOk(w, h) and spp in 1 .. 16 and bits in 1 .. 32 and
    w.int64 * h.int64 * spp.int64 <= 4 * maxPicturePixels.int64 and
    w.int64 * h.int64 * spp.int64 * bits.int64 <= most and tw in 0 .. 65536 and
    th in 0 .. 65536 and tw.int64 * th.int64 * spp.int64 * bits.int64 <= most

proc tiffPicture(path: string; maxW, maxH: int): Bitmap =
  ## (a TIFF's first page, when its numbers are sane; a big one made small
  ## as it is read, a band at a time)
  let big = readBigPicture(path, maxW, maxH)
  if big.read: return big.b
  let data = readUpTo(path)
  if tiffSane(data): decodeTiff(data) else: nil

proc tgaPicture(path: string; maxW, maxH: int): Bitmap =
  ## (a TGA, when its size is one its bytes can hold: TGA has no signature;
  ## a big one made small as it is read)
  let big = readBigPicture(path, maxW, maxH)
  if big.read: return big.b
  let data = readUpTo(path)
  if data.len < 18: return nil
  let w = rd16(data, 12, true)
  let h = rd16(data, 14, true)
  let pb = (ord(data[16]) + 7) div 8
  let avail = data.len - 18 - ord(data[0])
  if not pixelsOk(w, h) or pb < 1 or avail <= 0: return nil
  if ord(data[2]) >= 9:
    if w.int64 * h > avail.int64 * 128: return nil    # (a packet of 2 bytes or more: 128 pixels at most)
  elif w.int64 * h * pb > avail.int64: return nil
  decodeTga(data)

proc jxlPicture(path: string): Bitmap =
  ## (a JPEG XL's first frame, when its size is one a picture may have)
  let data = readUpTo(path)
  if data.len == 0: return nil
  let info = jxlInfo(data)
  if pixelsOk(info.w, info.h): decodeJxl(data) else: nil

when desktop:
  proc gifFirstEnd(s: string): int =
    ## (where the GIF's first picture ends; -1: not in `s`)
    if s.len < 13: return -1
    var p = 13
    let packed = ord(s[10])
    if (packed and 0x80) != 0: p += 3 * (1 shl ((packed and 7) + 1))
    template blocks() =
      while true:
        if p >= s.len: return -1
        let n = ord(s[p])
        inc p
        if n == 0: break
        p += n
    while p < s.len:
      case s[p]
      of '\x21':                             # (an extension)
        p += 2
        blocks()
      of '\x2C':                             # (a picture)
        if p + 10 > s.len: return -1
        let ip = ord(s[p + 9])
        p += 10
        if (ip and 0x80) != 0: p += 3 * (1 shl ((ip and 7) + 1))
        inc p                                # (the LZW code size)
        blocks()
        return p
      else: return -1
    -1

  proc gifPicture(path: string): Bitmap =
    ## (the first picture of a GIF: an animation's other frames not decoded,
    ## nor read when they come after the first megabyte)
    var f: File
    if not open(f, path): return nil
    defer: f.close()
    let size = int(getFileSize(f))
    if size < 13 or size > MaxFileBytes: return nil
    var data = newString(min(size, 1 shl 20))
    if f.readBuffer(addr data[0], data.len) != data.len: return nil
    var e = gifFirstEnd(data)
    if e < 0 and data.len < size:
      let old = data.len
      data.setLen(size)
      if f.readBuffer(addr data[old], size - old) != size - old: return nil
      e = gifFirstEnd(data)
    if e > 0: data = data[0 ..< e] & "\x3B"
    loadGif(data)[0].image

  proc webpPicture(path: string): Bitmap =
    ## (a WebP's picture: an animation's first frame)
    let data = readUpTo(path)
    if not isWebp(data): return nil
    let info = webpInfo(data)
    if pixelsOk(info.w, info.h): decodeWebp(data) else: nil

  var systemLock: Lock
  initLock(systemLock)

  proc systemPicture(path: string): Bitmap =
    ## (one at a time: a converter program writes to the same file each time)
    withLock systemLock:
      result = decodeWithSystem(path)

# ---- Photoshop and Retro Photo documents ------------------------------------------------------------

proc psdThumbnail(path: string): Bitmap =
  ## (the thumbnail Photoshop keeps in a .psd or .psb's image resources:
  ## resource 1036, or 1033 of Photoshop 4 -- its blue and red swapped; the
  ## rest of the file is not read)
  var f: File
  if not open(f, path): return nil
  defer: f.close()
  let size = int(getFileSize(f))
  var head = newString(30)
  if f.readBuffer(addr head[0], 30) != 30 or not head.startsWith("8BPS") or
     rd16(head, 4, false) notin [1, 2]: return nil
  let modeLen = rd32(head, 26, false)        # (the color mode's data, passed over)
  if 34 + modeLen > size: return nil
  f.setFilePos(30 + modeLen)
  var lenBuf = newString(4)
  if f.readBuffer(addr lenBuf[0], 4) != 4: return nil
  let resLen = rd32(lenBuf, 0, false)
  if resLen <= 0 or resLen > 64 shl 20 or 34 + modeLen + resLen > size: return nil
  var res = newString(resLen)
  if f.readBuffer(addr res[0], resLen) != resLen: return nil
  var p = 0
  while p + 12 <= resLen and res[p ..< p + 4] in ["8BIM", "MeSa", "AgHg", "PHUT", "DCSR", "8B64"]:
    let id = rd16(res, p + 4, false)
    let nameLen = ord(res[p + 6])
    let q = p + 6 + ((2 + nameLen) and not 1)       # (the name: a Pascal string, its length even)
    if q + 4 > resLen: break
    let n = rd32(res, q, false)
    let at = q + 4
    if at + n > resLen: break
    if id in [1036, 1033] and n > 28 and rd32(res, at, false) == 1:    # (format 1: a JPEG)
      let b = try: decodeJpeg(res[at + 28 ..< at + n]) except CatchableError: nil
      if b != nil and b.w > 0:
        if id == 1033:
          for px in b.px.mitems:
            px = (px and 0xFF00FF00'u32) or ((px and 0xFF) shl 16) or ((px shr 16) and 0xFF)
        return b
    p = at + n + (n and 1)

proc rpdThumbnail(path: string): Bitmap =
  ## (a Retro Photo document's picture: its preview, as it looks merged;
  ## older files without one, their bottom layer)
  let entries = zipEntries(path)
  for name in ["preview.png", "layer0.png"]:
    for e in entries:
      if e.name == name and e.size in 1 .. MaxFileBytes and e.packed in 1 .. MaxFileBytes:
        let b = try: decodePng(readEntry(path, e)) except CatchableError: nil
        if b != nil and b.w > 0: return b

# ---- SVG --------------------------------------------------------------------------------------------

proc svgPicture(path: string; maxW, maxH: int): Bitmap =
  ## (an SVG drawn at its size fitted in `maxW` x `maxH`, its aspect kept,
  ## on transparency; nil when it draws nothing)
  let data = readUpTo(path, 64 shl 20)
  if data.len == 0: return nil
  let doc = parseSvg(data)
  if doc.items.len == 0: return nil
  var (sw, sh) = svgSize(doc)
  if not (sw > 0 and sh > 0 and sw < 1e7 and sh < 1e7): (sw, sh) = (1.0, 1.0)
  let bw = max(1, maxW)
  let bh = max(1, maxH)
  var k = min(bw.float / sw, bh.float / sh)
  if sw * k * sh * k > MaxSvgPixels.float: k = sqrt(MaxSvgPixels.float / (sw * sh))
  rasterizeSvg(doc, clamp(int(round(sw * k)), 1, bw), clamp(int(round(sh * k)), 1, bh))

# ---- camera raw files: the preview JPEG in them ----------------------------------------------------

type
  Src = object
    ## (a file: its start read, the rest read where asked)
    f: File
    size: int
    head: string

  TiffAt = object
    ## (a TIFF structure in the file: where its offsets count from, its byte order)
    base: int
    le: bool

  Tag = object
    tag, kind, count: int
    at: int                     ## (where its values are in the file)

  DirKind = enum
    ## (what a directory is: what its tags mean)
    dkMain, dkExif, dkNikon, dkOlympus, dkOlympusCamera, dkPentax

  Cand = object
    ## (a picture found in the file)
    at, len: int                ## (its bytes in the file)
    w, h: int
    own: int                    ## (the JPEG's own EXIF orientation: decodeJpeg turns it)
    rgb: bool                   ## (8-bit RGB pixels, a TIFF thumbnail; not a JPEG)

  JpegHead = object
    ok: bool                    ## (a JPEG decodeJpeg reads: 8 bits, baseline or progressive)
    short: bool                 ## (its header goes on past the bytes there are)
    w, h, own, scan: int        ## (`scan`: where its first scan's segment is)

proc part(s: Src; at, n: int): string =
  ## (`n` bytes of the file at `at`; "" when they are not all in it)
  if at < 0 or n <= 0 or at > s.size - n: return ""
  if at + n <= s.head.len: return s.head[at ..< at + n]
  result = newString(n)
  s.f.setFilePos(at)
  if s.f.readBuffer(addr result[0], n) != n: result = ""

proc exifTurn(s: string; t, stop: int): int =
  ## (the orientation in the TIFF at `t` of an EXIF segment, as decodeJpeg
  ## reads it; 1 when it has none)
  result = 1
  if t + 8 > stop: return
  let le = s[t] == 'I'
  let ifd = t + rd32(s, t + 4, le)
  if ifd + 2 > stop: return
  for k in 0 ..< rd16(s, ifd, le):
    let e = ifd + 2 + 12 * k
    if e + 12 > stop: break
    if rd16(s, e, le) == 0x112: return rd16(s, e + 8, le)

proc jpegHead(s: string; at, stop: int): JpegHead =
  ## (the segments of the JPEG at `at` read up to its first scan: its size,
  ## whether decodeJpeg reads it -- not the lossless JPEG a raw's own
  ## numbers are packed in -- and the orientation it carries)
  result.own = 1
  if at < 0 or at + 4 > stop or s[at] != '\xFF' or s[at + 1] != '\xD8': return
  var i = at + 2
  var frame = false
  for _ in 0 ..< 1024:
    if i + 4 > stop:
      result.short = true
      return
    if s[i] != '\xFF': return
    let m = ord(s[i + 1])
    if m == 0xFF:
      inc i
      continue
    if m in [0x00, 0x01, 0xD8, 0xD9] or m in 0xD0 .. 0xD7: return
    let len = rd16(s, i + 2, false)
    if len < 2: return
    if i + 2 + len > stop:
      result.short = true
      return
    case m
    of 0xC0, 0xC1, 0xC2:
      if len < 8 or ord(s[i + 4]) != 8: return
      result.h = rd16(s, i + 5, false)
      result.w = rd16(s, i + 7, false)
      frame = true
    of 0xC3, 0xC5 .. 0xC7, 0xC9 .. 0xCB, 0xCD .. 0xCF: return   # (lossless, arithmetic)
    of 0xE1:
      if len > 20 and s.continuesWith("Exif\0\0", i + 4):
        result.own = exifTurn(s, i + 10, i + 2 + len)
    of 0xDA:
      result.scan = i
      result.ok = frame and result.w in 1 .. 16384 and result.h in 1 .. 16384
      return
    else: discard
    i += 2 + len

proc jpegEnd(s: string; scan, stop: int): int =
  ## (where the JPEG whose first scan's segment is at `scan` ends, after its
  ## EOI marker; -1 when that is not before `stop`)
  var i = scan
  while i + 2 <= stop:
    if s[i] != '\xFF': return -1
    let m = ord(s[i + 1])
    if m == 0xD9: return i + 2
    if m == 0xFF:
      inc i
      continue
    if m in 0xD0 .. 0xD7 or m == 0x01: i += 2
    else:
      if i + 4 > stop: return -1
      let len = rd16(s, i + 2, false)
      if len < 2: return -1
      i += 2 + len
    if m == 0xDA:
      # (the coded data: to a marker that is not a restart or a 0 after 0xFF)
      while true:
        i = s.find('\xFF', i, stop - 1)
        if i < 0 or i + 1 >= stop: return -1
        let n = ord(s[i + 1])
        if n == 0 or n in 0xD0 .. 0xD7: i += 2
        elif n == 0xFF: inc i
        else: break
  -1

proc addJpeg(s: Src; at, len: int; cands: var seq[Cand]) =
  ## (the JPEG a structure says is at `at`: a candidate when decodeJpeg reads it)
  if len < 64 or len > MaxPreviewBytes or at < 0 or at > s.size - len: return
  for c in cands:
    if c.at == at: return
  var b = s.part(at, min(len, 1 shl 19))
  var j = jpegHead(b, 0, b.len)
  if j.short and b.len < len:
    b = s.part(at, len)
    j = jpegHead(b, 0, b.len)
  if j.ok: cands.add Cand(at: at, len: len, w: j.w, h: j.h, own: j.own)

proc typeSize(kind: int): int =
  ## (the bytes of one value of a TIFF type; 0 for a type not known)
  case kind
  of 1, 2, 6, 7: 1
  of 3, 8: 2
  of 4, 9, 11, 13: 4
  of 5, 10, 12: 8
  else: 0

proc dir(s: Src; t: TiffAt; at: int): tuple[tags: seq[Tag]; next: int] =
  ## (the tags of the directory at `at`, and where the next one is: 0 none)
  let n = rd16(s.part(at, 2), 0, t.le)
  if n <= 0 or n > 1000: return
  var b = s.part(at + 2, 12 * n + 4)
  if b.len == 0: b = s.part(at + 2, 12 * n)    # (the last one may end the file)
  if b.len == 0: return
  for k in 0 ..< n:
    let e = 12 * k
    let kind = rd16(b, e + 2, t.le)
    let count = rd32(b, e + 4, t.le)
    let where = if typeSize(kind) * count <= 4: at + 2 + e + 8 else: t.base + rd32(b, e + 8, t.le)
    result.tags.add Tag(tag: rd16(b, e, t.le), kind: kind, count: count, at: where)
  let nx = rd32(b, 12 * n, t.le)
  result.next = if nx > 0: t.base + nx else: 0

proc tagAt(tags: seq[Tag]; tag: int): int =
  ## (where `tag` is in a directory; -1 when it is not there)
  for i, g in tags:
    if g.tag == tag: return i
  -1

proc values(s: Src; t: TiffAt; g: Tag; most = 4096): seq[int] =
  ## (a tag's numbers: bytes, shorts, longs; the first `most`)
  let sz = typeSize(g.kind)
  let n = min(g.count, most)
  if sz notin [1, 2, 4] or n <= 0: return
  let b = s.part(g.at, n * sz)
  if b.len == 0: return
  for k in 0 ..< n:
    result.add (case sz
                of 1: ord(b[k])
                of 2: rd16(b, 2 * k, t.le)
                else: rd32(b, 4 * k, t.le))

proc value(s: Src; t: TiffAt; tags: seq[Tag]; tag, default: int): int =
  ## (a tag's first number; `default` when it has none)
  let i = tags.tagAt(tag)
  if i < 0: return default
  let v = s.values(t, tags[i], 1)
  if v.len > 0: v[0] else: default

proc strips(s: Src; t: TiffAt; tags: seq[Tag]; joined: bool): tuple[at, len: int] =
  ## (where a directory's strips are, one after another; -1 when they are
  ## not -- or, not `joined`, when there is more than one)
  result = (-1, 0)
  let i = tags.tagAt(0x111)
  let j = tags.tagAt(0x117)
  if i < 0 or j < 0: return
  let offs = s.values(t, tags[i])
  let lens = s.values(t, tags[j])
  if offs.len == 0 or offs.len != lens.len or (offs.len > 1 and not joined): return
  var total = 0
  for k in 0 ..< offs.len:
    if k > 0 and offs[k] != offs[k - 1] + lens[k - 1]: return
    total += lens[k]
  result = (t.base + offs[0], total)

proc addRgb(s: Src; t: TiffAt; tags: seq[Tag]; cands: var seq[Cand]) =
  ## (an uncompressed 8-bit RGB thumbnail, as NEF and DNG keep one)
  if s.value(t, tags, 0x103, 1) != 1 or s.value(t, tags, 0x106, -1) != 2 or
     s.value(t, tags, 0x115, 1) != 3 or s.value(t, tags, 0x11C, 1) != 1: return
  let b = tags.tagAt(0x102)
  if b < 0: return
  for v in s.values(t, tags[b], 3):
    if v != 8: return
  let w = s.value(t, tags, 0x100, 0)
  let h = s.value(t, tags, 0x101, 0)
  if w <= 0 or h <= 0 or w * h > MaxRgbPixels: return
  let (at, len) = s.strips(t, tags, true)
  if at < 0 or len < w * h * 3 or at > s.size - w * h * 3: return
  for c in cands:
    if c.at == at: return
  cands.add Cand(at: at, len: w * h * 3, w: w, h: h, own: 1, rgb: true)

proc walkTiff(s: Src; t0: TiffAt; first: int; cands: var seq[Cand]; turn: var int) =
  ## (the pictures a TIFF structure holds: its directories followed -- the
  ## next ones, SubIFDs, EXIF, the maker's notes -- and how the camera was
  ## held, from the first)
  var todo = @[(at: first, t: t0, kind: dkMain)]
  var seen: seq[int]
  var ifd0 = true
  while todo.len > 0 and seen.len < 64:
    let d = todo.pop()
    if d.at <= 0 or d.at in seen: continue
    seen.add d.at
    let (tags, next) = s.dir(d.t, d.at)
    if tags.len == 0: continue
    let t = d.t
    if ifd0:
      ifd0 = false
      let o = s.value(t, tags, 0x112, 0)
      if o in 1 .. 8: turn = o
    template pair(start, length: int) =
      block:
        let i = tags.tagAt(start)
        let j = tags.tagAt(length)
        if i >= 0 and j >= 0:
          let a = s.values(t, tags[i], 1)
          let n = s.values(t, tags[j], 1)
          if a.len > 0 and n.len > 0: s.addJpeg(t.base + a[0], n[0], cands)
    template follow(tag: int; what: DirKind) =
      block:
        let i = tags.tagAt(tag)
        if i >= 0:
          if tags[i].kind == 7: todo.add (tags[i].at, t, what)   # (the directory is the value)
          else:
            for v in s.values(t, tags[i], 16): todo.add (t.base + v, t, what)
    case d.kind
    of dkMain:
      pair(0x201, 0x202)                    # (JPEGInterchangeFormat and its length)
      let comp = s.value(t, tags, 0x103, 0)
      if comp in [6, 7]:                    # (JPEG strips: one picture; DNG's each its own)
        let (at, len) = s.strips(t, tags, comp == 6)
        if at >= 0: s.addJpeg(at, len, cands)
      s.addRgb(t, tags, cands)
      let k = tags.tagAt(0x2E)              # (Panasonic's JpgFromRaw: the JPEG is the value)
      if k >= 0 and tags[k].kind == 7: s.addJpeg(tags[k].at, tags[k].count, cands)
      follow(0x14A, dkMain)
      follow(0x8769, dkExif)
      if next > 0: todo.add (next, t, dkMain)
    of dkExif:
      pair(0x201, 0x202)
      let k = tags.tagAt(0x927C)            # (the maker's notes: some makers' kinds)
      if k >= 0:
        let m = tags[k].at
        let h = s.part(m, 20)
        if h.startsWith("Nikon\0") and h[10 .. 11] in ["II", "MM"]:
          let nt = TiffAt(base: m + 10, le: h[10] == 'I')
          todo.add (m + 10 + rd32(h, 14, nt.le), nt, dkNikon)
        elif h.startsWith("OLYMPUS\0") and h[8 .. 9] in ["II", "MM"]:
          todo.add (m + 12, TiffAt(base: m, le: h[8] == 'I'), dkOlympus)
        elif h.startsWith("OM SYSTEM\0") and h[12 .. 13] in ["II", "MM"]:
          todo.add (m + 16, TiffAt(base: m, le: h[12] == 'I'), dkOlympus)
        elif h.startsWith("OLYMP\0"):
          todo.add (m + 8, t, dkOlympus)
        elif h.startsWith("AOC\0"):
          let le = if h[4 .. 5] == "II": true elif h[4 .. 5] == "MM": false else: t.le
          todo.add (m + 6, TiffAt(base: t.base, le: le), dkPentax)
        elif h.startsWith("PENTAX \0") and h[8 .. 9] in ["II", "MM"]:
          todo.add (m + 10, TiffAt(base: m, le: h[8] == 'I'), dkPentax)
    of dkNikon: follow(0x11, dkMain)        # (its preview's directory)
    of dkOlympus: follow(0x2020, dkOlympusCamera)
    of dkOlympusCamera: pair(0x101, 0x102)  # (PreviewImageStart and its length)
    of dkPentax: pair(0x5, 0x4)

proc structured(s: Src; cands: var seq[Cand]; turn: var int) =
  ## (the pictures the file's structure tells of, by its kind)
  template h: untyped = s.head
  if h.len < 16: return
  if h[0 ..< 4] in ["II*\0", "MM\0*", "IIRO", "IIRS", "MMOR", "IIU\0"]:
    # (TIFF and its kin: ORF, RW2, RWL)
    let t = TiffAt(base: 0, le: h[0] == 'I')
    s.walkTiff(t, rd32(h, 4, t.le), cands, turn)
  elif h.startsWith("FUJIFILMCCD-RAW"):
    s.addJpeg(rd32(h, 84, false), rd32(h, 88, false), cands)    # (RAF: its JPEG's place)
  elif h.startsWith("\0MRM"):
    # (Minolta's MRW: blocks; TTW holds a TIFF)
    let stop = min(h.len, 8 + rd32(h, 4, false))
    var p = 8
    while p + 16 <= stop:
      if h[p ..< p + 4] == "\0TTW":
        let t = TiffAt(base: p + 8, le: h[p + 8] == 'I')
        s.walkTiff(t, p + 8 + rd32(h, p + 12, t.le), cands, turn)
        break
      p += 8 + rd32(h, p + 4, false)
  elif h[4 ..< 8] == "ftyp":
    # (Canon's CR3: how the camera was held, in CMT1's TIFF)
    let c = h.find("CMT1", 0, min(h.len, 1 shl 20) - 1)
    if c > 0 and c + 12 <= h.len:
      let t = TiffAt(base: c + 4, le: h[c + 4] == 'I')
      s.walkTiff(t, c + 4 + rd32(h, c + 8, t.le), cands, turn)

proc scanJpegs(buf: string; cands: var seq[Cand]; tried: var seq[int]): bool =
  ## (JPEGs found by their start in what was read -- where a structure was
  ## not followed; true when one goes on past it)
  var i = 0
  var probes = 0
  while probes < MaxProbes:
    i = buf.find('\xFF', i)
    if i < 0 or i + 4 > buf.len: break
    if buf[i + 1] == '\xD8' and buf[i + 2] == '\xFF' and i notin tried:
      var known = false
      for c in cands:
        if c.at == i: known = true
      if not known:
        inc probes
        let j = jpegHead(buf, i, buf.len)
        if j.ok:
          let e = jpegEnd(buf, j.scan, buf.len)
          if e > 0:
            cands.add Cand(at: i, len: e - i, w: j.w, h: j.h, own: j.own)
            tried.add i
          else: result = true
        elif j.short: result = true
        else: tried.add i
    inc i

proc shown(c: Cand; turn: int): tuple[w, h: int] =
  ## (its size as shown: turned)
  if (if c.own in 2 .. 8: c.own else: turn) >= 5: (c.h, c.w) else: (c.w, c.h)

proc fills(c: Cand; turn, maxW, maxH: int): bool =
  ## (it is no smaller than the size asked for)
  let (w, h) = c.shown(turn)
  w >= maxW or h >= maxH

proc pick(cands: seq[Cand]; turn, maxW, maxH: int): int =
  ## (the smallest that fills the size asked for -- else the biggest -- of
  ## those shaped as the biggest is: a thumbnail with black bars is not one)
  result = -1
  var big = -1
  for i, c in cands:
    if big < 0 or c.w * c.h > cands[big].w * cands[big].h: big = i
  if big < 0: return
  let shape = cands[big].w / cands[big].h
  for i, c in cands:
    if abs(c.w / c.h / shape - 1) > 0.04: continue
    if result < 0:
      result = i
      continue
    let r = cands[result]
    let cf = c.fills(turn, maxW, maxH)
    let rf = r.fills(turn, maxW, maxH)
    if (cf and not rf) or (cf and rf and c.w * c.h < r.w * r.h) or
       (not cf and not rf and c.w * c.h > r.w * r.h): result = i

proc decoded(s: Src; c: Cand; turn, maxW, maxH: int): Bitmap =
  ## (a picture found decoded, turned and fitted)
  let b = s.part(c.at, c.len)
  if b.len == 0: return nil
  if c.rgb:
    result = newBitmap(c.w, c.h)
    for i in 0 ..< c.w * c.h:
      result.px[i] = 0xFF000000'u32 or (uint32(ord(b[3 * i])) shl 16) or
                     (uint32(ord(b[3 * i + 1])) shl 8) or uint32(ord(b[3 * i + 2]))
    result.opaque = true
    result.changed()
  else:
    # (much bigger than wanted: only the blocks' averages, 8 times quicker)
    let (w, h) = c.shown(turn)
    result = decodeJpeg(b, if w div 8 >= maxW or h div 8 >= maxH: 8 else: 1)
  # (turned as the camera was held, unless the JPEG said so itself)
  result = fitted(oriented(result, if c.own in 2 .. 8: 1 else: turn), maxW, maxH)

proc rawPreview*(path: string; maxW = 512; maxH = 512): Bitmap =
  ## The preview a camera raw file holds, no larger than `maxW` x `maxH`:
  ## of the JPEG pictures in it (and uncompressed TIFF thumbnails), the
  ## smallest that fills that size, else the biggest, turned as the camera
  ## was held. The raw itself is not developed, and of a big file only the
  ## first megabytes are read when the preview is there. Nil when it holds
  ## none this can read.
  try:
    var f: File
    if not open(f, path): return nil
    defer: f.close()
    var s = Src(f: f, size: int(getFileSize(f)))
    if s.size < 16: return nil
    s.head = newString(min(s.size, HeadBytes))
    if f.readBuffer(addr s.head[0], s.head.len) != s.head.len: return nil
    var cands: seq[Cand]
    var tried: seq[int]
    var turn = 1
    s.structured(cands, turn)
    let more = scanJpegs(s.head, cands, tried)
    var best = pick(cands, turn, maxW, maxH)
    if s.head.len < s.size and (best < 0 or (more and not cands[best].fills(turn, maxW, maxH))):
      # (none there -- or a bigger one going on past what was read: the rest
      # of the file, as much as is worth reading)
      let old = s.head.len
      let n = min(s.size, MaxRawBytes)
      if n > old:
        s.head.setLen(n)
        f.setFilePos(old)
        if f.readBuffer(addr s.head[old], n - old) == n - old:
          discard scanJpegs(s.head, cands, tried)
          best = pick(cands, turn, maxW, maxH)
        else: s.head.setLen(old)
    # (one whose data is damaged: the next best)
    for _ in 0 ..< 4:
      if best < 0: break
      result = try: s.decoded(cands[best], turn, maxW, maxH) except CatchableError, Defect: nil
      if result != nil: break
      cands.delete(best)
      best = pick(cands, turn, maxW, maxH)
  except CatchableError, Defect:
    result = nil

# ---- the readers ------------------------------------------------------------------------------------

proc readMorePicture*(path: string; maxW = 4096; maxH = 4096): Bitmap =
  ## The picture of a file of one of `morePictureKinds` (by its extension),
  ## no larger than `maxW` x `maxH`; nil when it is not one of them or
  ## cannot be read. What `addMorePictures` teaches `loadPicture`; it works
  ## without it too, on any thread.
  let name = path.extractFilename
  let dot = name.rfind('.')
  if dot < 0: return nil
  let ext = name[dot .. ^1].toLowerAscii
  if ext notin morePictureKinds: return nil
  try:
    let b = case ext
      of ".jxl": jxlPicture(path)
      of ".svg": svgPicture(path, maxW, maxH)
      of ".tif", ".tiff": tiffPicture(path, maxW, maxH)
      of ".tga": tgaPicture(path, maxW, maxH)
      of ".exr": exrPicture(path)
      of ".hdr", ".rgbe": hdrPicture(path)
      of ".psd", ".psb": psdThumbnail(path)
      of ".rpd", ".rp3": rpdThumbnail(path)
      of ".gif":
        when desktop: gifPicture(path) else: nil
      of ".webp":
        when desktop: webpPicture(path) else: nil
      of ".heic", ".heif", ".hif", ".avif":
        when desktop: systemPicture(path) else: nil
      else: rawPreview(path, maxW, maxH)
    result = fitted(b, maxW, maxH)
  except CatchableError, Defect:
    result = nil

proc readAny(path: string; maxW, maxH: int): Bitmap {.nimcall, gcsafe.} =
  {.cast(gcsafe).}: readMorePicture(path, maxW, maxH)

proc addMorePictures*() =
  ## Teaches `loadPicture` -- the file lists' pictures, the previews, the
  ## Open dialogs -- to show the files of `morePictureKinds`. Call it at
  ## the start, before pictures are asked for; a kind a program already
  ## gave a reader of its own (`addPictureReader`, `addDocumentPreviews`)
  ## keeps it, and calling it again adds nothing.
  var kinds: seq[string]
  for k in morePictureKinds:
    if pictureReaderFor("x" & k) == nil: kinds.add k
  if kinds.len > 0: addPictureReader(kinds, readAny)
