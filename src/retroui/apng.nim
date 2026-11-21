## Animated PNG (APNG): its frames read -- each put on the picture as it says, over what was
## there or in place of it, the area cleared or put back after it -- and frames written as one,
## the first its picture for a program that shows only that.
##
## ```nim
## if isApng(data):
##   for f in decodeApng(data): echo f.delayMs   # each frame as it is shown, the whole picture
## writeFile("a.png", encodeApng(w, h, frames, loop = 0))
## ```
##
## Developed by Sultan Al Isaiee @foxoman -- www.foxoman.net -- sultan@foxoman.net

import gfx, imaging, codec

type ApngFrame* = tuple[bmp: Bitmap; delayMs: int]
  ## A frame as it is shown: the whole picture, and for how long (milliseconds).

proc be32(s: string; i: int): int =
  (ord(s[i]) shl 24) or (ord(s[i + 1]) shl 16) or (ord(s[i + 2]) shl 8) or ord(s[i + 3])

proc be16(s: string; i: int): int = (ord(s[i]) shl 8) or ord(s[i + 1])

proc put32(s: var string; v: int) =
  s.add char((v shr 24) and 255)
  s.add char((v shr 16) and 255)
  s.add char((v shr 8) and 255)
  s.add char(v and 255)

proc put16(s: var string; v: int) =
  s.add char((v shr 8) and 255)
  s.add char(v and 255)

proc chunk(tag, data: string): string =
  result.put32(data.len)
  result.add tag
  result.add data
  let body = tag & data
  result.put32(int(crc32(body.toOpenArrayByte(0, body.high))))

iterator chunks(data: string): tuple[tag, body: string] =
  ## (each chunk after the signature: its tag and what it holds)
  var i = 8
  while i + 8 <= data.len:
    let n = be32(data, i)
    if n < 0 or i + 12 + n > data.len: break
    yield (data[i + 4 ..< i + 8], data[i + 8 ..< i + 8 + n])
    i += 12 + n

const Signature = "\x89PNG\r\n\x1a\n"

proc isApng*(data: string): bool =
  ## The bytes are an animated PNG (an acTL chunk before its picture).
  if data.len < 8 or data[0 .. 7] != Signature: return false
  for (tag, _) in chunks(data):
    if tag == "acTL": return true
    if tag == "IDAT": return false
  false

proc apngLoop*(data: string): int =
  ## How many times it plays (0: for ever); -1 not an animated PNG.
  if not isApng(data): return -1
  for (tag, body) in chunks(data):
    if tag == "acTL" and body.len >= 8: return be32(body, 4)
  -1

proc decodeApng*(data: string; maxFrames = 2000): seq[ApngFrame] =
  ## The frames of an animated PNG as they are shown, each the whole picture. A PNG that is
  ## not animated: its one picture. Raises `ImageError` on a damaged one.
  if data.len < 8 or data[0 .. 7] != Signature: raise newException(ImageError, "not a PNG file")
  if not isApng(data): return @[(decodePng(data), 0)]
  var ihdr = ""
  var extra: seq[tuple[tag, body: string]]      # (PLTE, tRNS, gAMA...: each frame's PNG has them)
  type Fr = object
    w, h, x, y, delay, dispose, blend: int
    data: string
  var frames: seq[Fr]
  var cur = -1
  var seenIdat = false
  for (tag, body) in chunks(data):
    case tag
    of "IHDR": ihdr = body
    of "fcTL":
      if body.len < 26: raise newException(ImageError, "damaged APNG")
      let num = be16(body, 20)
      let den = be16(body, 22)
      frames.add Fr(w: be32(body, 4), h: be32(body, 8), x: be32(body, 12), y: be32(body, 16),
                    delay: (if num == 0: 0 else: num * 1000 div (if den == 0: 100 else: den)),
                    dispose: ord(body[24]), blend: ord(body[25]))
      cur = frames.high
      if frames.len > maxFrames: raise newException(ImageError, "too many frames")
    of "IDAT":
      seenIdat = true
      if cur == 0: frames[0].data.add body      # (its picture is the first frame when a fcTL came first)
    of "fdAT":
      if cur >= 0 and body.len >= 4: frames[cur].data.add body[4 .. ^1]
    of "IEND", "acTL": discard
    else:
      if not seenIdat and tag notin ["fcTL", "fdAT"]: extra.add (tag, body)
  if ihdr.len < 13: raise newException(ImageError, "damaged APNG")
  let W = be32(ihdr, 0)
  let H = be32(ihdr, 4)
  if W <= 0 or H <= 0 or W > 16384 or H > 16384: raise newException(ImageError, "too big")
  var canvas = newSeq[uint32](W * H)
  for f in frames:
    if f.data.len == 0 or f.w <= 0 or f.h <= 0 or f.x < 0 or f.y < 0 or f.x + f.w > W or f.y + f.h > H:
      continue
    # (the frame as a PNG of its own: its size in the header, the same palette and the rest)
    var hd = ihdr
    var sz = ""
    sz.put32(f.w)
    sz.put32(f.h)
    hd[0 .. 7] = sz
    var png = Signature & chunk("IHDR", hd)
    for (t, b) in extra: png.add chunk(t, b)
    png.add chunk("IDAT", f.data)
    png.add chunk("IEND", "")
    let b = decodePng(png)
    let before = if f.dispose == 2: canvas else: @[]
    for yy in 0 ..< f.h:
      for xx in 0 ..< f.w:
        let s = b.px[yy * f.w + xx]
        let i = (f.y + yy) * W + f.x + xx
        if f.blend == 0: canvas[i] = s
        else:
          # (over what is there)
          let sa = int(s shr 24)
          if sa == 255: canvas[i] = s
          elif sa > 0:
            let d = canvas[i]
            let da = int(d shr 24)
            let oa = sa + da * (255 - sa) div 255
            template ch(sh: int): uint32 =
              uint32((int((s shr sh) and 255) * sa + int((d shr sh) and 255) * da * (255 - sa) div 255) div
                     max(1, oa)) shl sh
            canvas[i] = (uint32(oa) shl 24) or ch(16) or ch(8) or ch(0)
    let shown = newBitmap(W, H)
    shown.px = canvas
    result.add (shown, f.delay)
    case f.dispose
    of 1:
      for yy in 0 ..< f.h:
        for xx in 0 ..< f.w: canvas[(f.y + yy) * W + f.x + xx] = 0
    of 2: canvas = before
    else: discard
  if result.len == 0: result.add (decodePng(data), 0)

proc encodeApng*(w, h: int; frames: openArray[tuple[px: seq[uint32]; delayMs: int]]; loop = 0): string =
  ## Frames (each `w` x `h`, shown so many milliseconds) as an animated PNG playing `loop` times
  ## (0: for ever); each frame whole, the first the picture a program that shows only one shows.
  result = Signature
  var seq0 = 0
  # (every frame stored the same way as the header says: with transparency when any has some)
  var alpha = 0
  for f in frames:
    for p in f.px:
      if (p shr 24) != 255:
        alpha = 1
        break
    if alpha == 1: break
  for k, f in frames:
    let b = newBitmap(w, h)
    b.px = f.px
    let png = encodePng(b, alpha = alpha, gray = 0)
    var idat = ""
    var hdr = ""
    for (tag, body) in chunks(png):
      if tag == "IHDR": hdr = body
      elif tag == "IDAT": idat.add body
    if k == 0:
      result.add chunk("IHDR", hdr)
      var ac = ""
      ac.put32(frames.len)
      ac.put32(max(0, loop))
      result.add chunk("acTL", ac)
    var fc = ""
    fc.put32(seq0)
    inc seq0
    fc.put32(w)
    fc.put32(h)
    fc.put32(0)
    fc.put32(0)
    fc.put16(clamp(f.delayMs, 0, 65535))
    fc.put16(1000)
    fc.add '\0'       # (left as it is)
    fc.add '\0'       # (in place of what was there)
    result.add chunk("fcTL", fc)
    if k == 0: result.add chunk("IDAT", idat)
    else:
      var fd = ""
      fd.put32(seq0)
      inc seq0
      fd.add idat
      result.add chunk("fdAT", fd)
  result.add chunk("IEND", "")
