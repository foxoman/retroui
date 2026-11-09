## Brushes of other programs: Photoshop's .abr files (versions 1, 2 and
## 6 to 10: their sampled brushes) and GIMP's .gbr, as brush tips
## (`BrushTip` of `retroui/photopaint`). Use it to bring a user's brush files
## into a paint program; `writeAbr` writes tips back as an .abr.
##
## ```nim
## for tip in readAbr(readFile("Watercolor.abr")): brushes.add tip
## for tip in readBrushes(path, readFile(path)): brushes.add tip   # .abr or .gbr
## ```

import std/strutils
import photopaint

proc be16(s: string; at: int): int =
  if at < 0 or at + 2 > s.len: raise newException(ValueError, "the file ends early")
  (ord(s[at]) shl 8) or ord(s[at + 1])

proc be32(s: string; at: int): int =
  if at < 0 or at + 4 > s.len: raise newException(ValueError, "the file ends early")
  (ord(s[at]) shl 24) or (ord(s[at + 1]) shl 16) or (ord(s[at + 2]) shl 8) or ord(s[at + 3])

proc signed32(v: int): int = int(cast[int32](uint32(int64(v) and 0xFFFF_FFFF'i64)))

const MaxSide = 1024               ## (a bigger brush's picture is kept this size, painted at its own)

proc fitTip(px: seq[uint8]; w, h: int): (seq[uint8], int, int) =
  ## The brush made smaller (averaged) when it is bigger than we paint with.
  if w <= MaxSide and h <= MaxSide: return (px, w, h)
  let k = MaxSide / max(w, h)
  let nw = max(1, int(w.float * k))
  let nh = max(1, int(h.float * k))
  var o = newSeq[uint8](nw * nh)
  for y in 0 ..< nh:
    let y0 = y * h div nh
    let y1 = max(y0 + 1, (y + 1) * h div nh)
    for x in 0 ..< nw:
      let x0 = x * w div nw
      let x1 = max(x0 + 1, (x + 1) * w div nw)
      var s = 0
      for yy in y0 ..< y1:
        for xx in x0 ..< x1: s += int(px[yy * w + xx])
      o[y * nw + x] = uint8(s div ((y1 - y0) * (x1 - x0)))
  (o, nw, nh)

proc tipOf(name: string; px: seq[uint8]; w, h, spacing: int): BrushTip =
  let (p, tw, th) = fitTip(px, w, h)
  BrushTip(name: name, custom: p, cw: tw, ch: th, diameter: min(MaxDiameter, max(w, h)),
           spacing: clamp(spacing, 1, 999), roundness: 100, hardness: 100)

proc sample(s: string; at: var int; w, h, depth: int; rle: bool): seq[uint8] =
  ## A brush's picture: raw or PackBits rows, 8 or 16 bits a pixel.
  if w <= 0 or h <= 0 or w > 30000 or h > 30000 or w * h > 64_000_000:
    raise newException(ValueError, "a brush too big")
  let bpp = max(1, depth div 8)
  let rowBytes = w * bpp
  var raw = newSeq[uint8](rowBytes * h)
  if not rle:
    if at + raw.len > s.len: raise newException(ValueError, "the file ends early")
    for i in 0 ..< raw.len: raw[i] = uint8(ord(s[at + i]))
    at += raw.len
  else:
    var counts = newSeq[int](h)
    for y in 0 ..< h:
      counts[y] = be16(s, at)
      at += 2
    for y in 0 ..< h:
      var p = at
      let stop = at + counts[y]
      var o = y * rowBytes
      let rowEnd = o + rowBytes
      while p < stop and o < rowEnd:
        if p >= s.len: raise newException(ValueError, "the file ends early")
        var n = ord(s[p])
        inc p
        if n >= 128: n -= 256
        if n >= 0:
          for _ in 0 .. n:
            if o < rowEnd and p < s.len: raw[o] = uint8(ord(s[p]))
            inc o
            inc p
        elif n != -128:
          if p >= s.len: raise newException(ValueError, "the file ends early")
          let v = uint8(ord(s[p]))
          inc p
          for _ in 0 .. -n:
            if o < rowEnd: raw[o] = v
            inc o
      at = stop
  if bpp == 1: return raw
  result = newSeq[uint8](w * h)
  for i in 0 ..< w * h: result[i] = raw[i * bpp]       # (the high byte of 16)

proc readAbrV12(s: string; version: int): seq[BrushTip] =
  let count = be16(s, 2)
  var at = 4
  for i in 0 ..< count:
    if at + 6 > s.len: break
    let kind = be16(s, at)
    let size = be32(s, at + 2)
    at += 6
    let next = at + size
    if kind == 2:
      var p = at + 4                         # (misc)
      let spacing = be16(s, p)
      p += 2
      var name = ""
      if version == 2:
        let n = be32(s, p)
        p += 4
        for k in 0 ..< min(n, 512):
          let c = be16(s, p + 2 * k)
          if c > 0 and c < 128: name.add char(c)
        p += 2 * n
      p += 1 + 8                             # (anti-aliasing, the short bounds)
      let top = signed32(be32(s, p))
      let left = signed32(be32(s, p + 4))
      let bottom = signed32(be32(s, p + 8))
      let right = signed32(be32(s, p + 12))
      let depth = be16(s, p + 16)
      let rle = ord(s[p + 18]) != 0
      p += 19
      let w = right - left
      let h = bottom - top
      let px = sample(s, p, w, h, depth, rle)
      result.add tipOf(if name.len > 0: name.strip(chars = {'\0', ' '}) else: "Brush " & $(i + 1), px, w, h,
                       if spacing > 0: spacing else: 25)
    at = next

proc readAbrV6(s: string): seq[BrushTip] =
  let sub = be16(s, 2)
  # the "samp" section
  var at = 4
  while at + 12 <= s.len:
    if s[at ..< at + 4] != "8BIM": break
    let key = s[at + 4 ..< at + 8]
    let len = be32(s, at + 8)
    at += 12
    if key != "samp":
      at += len + (len and 1)
      continue
    let stop = min(s.len, at + len)
    var k = 0
    while at + 4 <= stop:
      var size = be32(s, at)
      at += 4
      while size mod 4 != 0: inc size
      let next = at + size
      var p = at + (if sub == 1: 47 else: 301)
      let top = signed32(be32(s, p))
      let left = signed32(be32(s, p + 4))
      let bottom = signed32(be32(s, p + 8))
      let right = signed32(be32(s, p + 12))
      let depth = be16(s, p + 16)
      let rle = ord(s[p + 18]) != 0
      p += 19
      inc k
      try:
        let w = right - left
        let h = bottom - top
        let px = sample(s, p, w, h, depth, rle)
        result.add tipOf("Sampled Brush " & $k, px, w, h, 25)
      except ValueError: discard
      at = next
    break

proc readGbr*(s: string): BrushTip =
  ## A GIMP brush (.gbr): its picture as the brush (gray; or the alpha of a
  ## colored one).
  let head = be32(s, 0)
  let version = be32(s, 4)
  let w = be32(s, 8)
  let h = be32(s, 12)
  let bytes = be32(s, 16)
  if version notin [1, 2] or w <= 0 or h <= 0 or w * h > 64_000_000 or bytes notin [1, 4]:
    raise newException(ValueError, "not a GIMP brush")
  var spacing = 25
  var name = ""
  if version == 2 and head >= 28:
    spacing = be32(s, 24)
    name = s[28 ..< min(s.len, head)].strip(chars = {'\0', ' '})
  if head + w * h * bytes > s.len: raise newException(ValueError, "the file ends early")
  var px = newSeq[uint8](w * h)
  for i in 0 ..< w * h:
    px[i] = if bytes == 1: uint8(ord(s[head + i])) else: uint8(ord(s[head + 4 * i + 3]))
  tipOf(if name.len > 0: name else: "GIMP Brush", px, w, h, spacing)

proc readAbr*(s: string): seq[BrushTip] =
  ## The sampled brushes of a Photoshop brush file (.abr); raises
  ## `ValueError` when it is not one we read.
  if s.len < 4: raise newException(ValueError, "not a brush file")
  let version = be16(s, 0)
  case version
  of 1, 2: readAbrV12(s, version)
  of 6, 7, 10: readAbrV6(s)
  else: raise newException(ValueError, "a brush file of version " & $version)

proc readBrushes*(path: string; data: string): seq[BrushTip] =
  ## The brushes of a file, by its kind: `path`'s extension or `data`'s
  ## signature (.gbr: one tip; anything else is read as an .abr). Raises
  ## `ValueError` when it is neither.
  if path.toLowerAscii.endsWith(".gbr") or (data.len > 24 and data[20 ..< 24] == "GIMP"):
    @[readGbr(data)]
  else: readAbr(data)

# ---- writing (for tests and sharing): version 2 ---------------------------------------------------------------

proc writeAbr*(tips: openArray[BrushTip]): string =
  ## Sampled brushes as a version 2 .abr (raw, 8 bits).
  proc w16(o: var string; v: int) = (o.add char((v shr 8) and 255); o.add char(v and 255))
  proc w32(o: var string; v: int) =
    o.add char((v shr 24) and 255); o.add char((v shr 16) and 255); o.add char((v shr 8) and 255); o.add char(v and 255)
  result.w16(2)
  var n = 0
  for t in tips:
    if t.custom.len == t.cw * t.ch and t.cw > 0: inc n
  result.w16(n)
  for t in tips:
    if t.custom.len != t.cw * t.ch or t.cw == 0: continue
    var b = ""
    b.w32(0)
    b.w16(t.spacing)
    b.w32(t.name.len + 1)
    for c in t.name: b.w16(ord(c))
    b.w16(0)
    b.add '\0'
    for _ in 0 .. 3: b.w16(0)
    b.w32(0); b.w32(0); b.w32(t.ch); b.w32(t.cw)
    b.w16(8)
    b.add '\0'
    for v in t.custom: b.add char(v)
    result.w16(2)
    result.w32(b.len)
    result.add b
