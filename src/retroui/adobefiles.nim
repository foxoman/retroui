## The small files Photoshop shares its presets in: color swatches (.aco,
## and Adobe Swatch Exchange .ase), color books (.acb: Pantone's and others'
## libraries), curves (.acv), levels (.alv), gradients (.grd) and patterns
## (.pat) -- read, and (but the last two) written. Use it to load and share
## the presets of a paint program built on `retroui/photo`; `kindOf` tells
## which kind a file is. Every reader raises `AdobeError` for a file it does
## not read.
##
## ```nim
## for (name, c) in readAco(readFile("Pastels.aco")): swatches.add c
## let curves = readAcv(readFile("Cross Process.acv"))   # composite, R, G, B
## let grads = readGrd(readFile("Metals.grd"))
## ```

import std/[strutils, math]
import psd, photo, photoinks

type
  AdobeError* = object of ValueError
    ## Not a file of that kind (or a damaged one).

  Swatch* = tuple[name: string; color: uint32]
    ## A named color of a swatches file (`color`: ARGB; `name` "" when the
    ## file has none).
  CurvePoint* = tuple[input, output: int]
    ## A point of a Curves curve: `input` to `output`, both 0..255.
  LevelsRecord* = object
    ## One channel of a Levels preset (composite first, then R, G, B).
    inLo*, inHi*, outLo*, outHi*: int  ## input black and white, output black and white (0..255)
    gamma*: float                      ## the midtones' gamma (1: unchanged)

  GradientPreset* = object
    ## A gradient of a .grd file.
    name*: string                ## as Photoshop's Gradient picker shows it
    stops*: seq[GradientStop]    ## its color stops, in order

  PatternPreset* = object
    ## A pattern of a .pat file.
    name*: string                ## as Photoshop's Pattern picker shows it
    w*, h*: int                  ## its size in pixels
    px*: seq[uint32]             ## ARGB

proc bad(what: string) {.noreturn.} = raise newException(AdobeError, what)

proc be16(s: string; at: int): int =
  if at < 0 or at + 2 > s.len: bad("the file ends early")
  (ord(s[at]) shl 8) or ord(s[at + 1])

proc be32(s: string; at: int): int =
  if at < 0 or at + 4 > s.len: bad("the file ends early")
  (ord(s[at]) shl 24) or (ord(s[at + 1]) shl 16) or (ord(s[at + 2]) shl 8) or ord(s[at + 3])

proc signed16(v: int): int = (if v >= 0x8000: v - 0x10000 else: v)

proc w16(o: var string; v: int) =
  o.add char((v shr 8) and 255)
  o.add char(v and 255)

proc w32(o: var string; v: int) =
  o.add char((v shr 24) and 255); o.add char((v shr 16) and 255)
  o.add char((v shr 8) and 255); o.add char(v and 255)

proc utf16be(s: string; at: int; units: int): string =
  ## `units` UTF-16 code units at `at` as UTF-8 (a closing 0 left out).
  var i = 0
  while i < units:
    var u = be16(s, at + 2 * i)
    inc i
    if u == 0: continue
    if u >= 0xD800 and u < 0xDC00 and i < units:
      let lo = be16(s, at + 2 * i)
      inc i
      u = 0x10000 + ((u - 0xD800) shl 10) + (lo - 0xDC00)
    # UTF-8
    if u < 0x80: result.add char(u)
    elif u < 0x800:
      result.add char(0xC0 or (u shr 6)); result.add char(0x80 or (u and 63))
    elif u < 0x10000:
      result.add char(0xE0 or (u shr 12)); result.add char(0x80 or ((u shr 6) and 63))
      result.add char(0x80 or (u and 63))
    else:
      result.add char(0xF0 or (u shr 18)); result.add char(0x80 or ((u shr 12) and 63))
      result.add char(0x80 or ((u shr 6) and 63)); result.add char(0x80 or (u and 63))

proc toUtf16(s: string): seq[int] =
  ## UTF-8 to UTF-16 code units.
  var i = 0
  while i < s.len:
    let c = ord(s[i])
    var cp, n: int
    if c < 0x80: (cp, n) = (c, 1)
    elif c < 0xE0: (cp, n) = (c and 0x1F, 2)
    elif c < 0xF0: (cp, n) = (c and 0x0F, 3)
    else: (cp, n) = (c and 0x07, 4)
    for k in 1 ..< n:
      if i + k < s.len: cp = (cp shl 6) or (ord(s[i + k]) and 63)
    i += n
    if cp >= 0x10000:
      let v = cp - 0x10000
      result.add 0xD800 + (v shr 10)
      result.add 0xDC00 + (v and 0x3FF)
    else: result.add cp

proc hsbToRgb(h, s, v: float): uint32 =
  fromHsb(h, s, v)

proc cmykToRgb(c, m, y, k: float): uint32 =
  ## (a plain conversion: no ink profile)
  argb(255, int(round(255 * (1 - c) * (1 - k))), int(round(255 * (1 - m) * (1 - k))),
       int(round(255 * (1 - y) * (1 - k))))

# ---- swatches: .aco ------------------------------------------------------------------------------

proc acoColor(space, w, x, y, z: int): uint32 =
  case space
  of 0: argb(255, w shr 8, x shr 8, y shr 8)                                    # RGB
  of 1: hsbToRgb(w / 65535 * 360, x / 65535, y / 65535)                          # HSB
  of 2: cmykToRgb(1 - w / 65535, 1 - x / 65535, 1 - y / 65535, 1 - z / 65535)   # CMYK
  of 7:                                                                          # Lab
    let (r, g, b) = labToRgb(w / 100, signed16(x) / 100, signed16(y) / 100)
    argb(255, r, g, b)
  of 8:                                                                          # gray
    let v = 255 - int(round(w / 10000 * 255))
    argb(255, v, v, v)
  else: bad("a color space not read (" & $space & ")")

proc readAco*(s: string): seq[Swatch] =
  ## A Photoshop swatches file: its colors (named, from version 2).
  if s.len < 4: bad("not a swatches file")
  var version = be16(s, 0)
  if version notin [1, 2]: bad("not a swatches file")
  var at = 0
  var names: seq[string]
  var cols: seq[uint32]
  # version 1 (no names); a version 2 part follows it in files from Photoshop 6 on
  while at + 4 <= s.len:
    version = be16(s, at)
    if version notin [1, 2]: break
    let n = be16(s, at + 2)
    at += 4
    var got: seq[Swatch]
    for _ in 0 ..< n:
      let c = acoColor(be16(s, at), be16(s, at + 2), be16(s, at + 4), be16(s, at + 6), be16(s, at + 8))
      at += 10
      var name = ""
      if version == 2:
        discard be16(s, at)                          # (0)
        let len = be16(s, at + 2)
        name = utf16be(s, at + 4, len)
        at += 4 + 2 * len
      got.add (name, c)
    if version == 2 or result.len == 0: result = got
    if version == 2: break

proc writeAco*(sw: openArray[Swatch]): string =
  ## Swatches as a Photoshop .aco (version 1 then 2, with the names), RGB.
  for version in [1, 2]:
    result.w16(version)
    result.w16(sw.len)
    for (name, c) in sw:
      result.w16(0)
      result.w16(int((c shr 16) and 255) * 257)
      result.w16(int((c shr 8) and 255) * 257)
      result.w16(int(c and 255) * 257)
      result.w16(0)
      if version == 2:
        let u = toUtf16(name)
        result.w16(0)
        result.w16(u.len + 1)
        for v in u: result.w16(v)
        result.w16(0)

# ---- swatches: .ase ------------------------------------------------------------------------------

proc f32(s: string; at: int): float =
  float(cast[float32](uint32(be32(s, at))))

proc readAse*(s: string): seq[Swatch] =
  ## An Adobe Swatch Exchange file: its colors (in its groups too).
  if s.len < 12 or s[0 ..< 4] != "ASEF": bad("not a swatch exchange file")
  let n = be32(s, 8)
  var at = 12
  for _ in 0 ..< n:
    if at + 6 > s.len: break
    let kind = be16(s, at)
    let len = be32(s, at + 2)
    let body = at + 6
    at = body + len
    if kind != 1: continue                         # (group start and end)
    let nameLen = be16(s, body)
    let name = utf16be(s, body + 2, nameLen)
    var p = body + 2 + 2 * nameLen
    if p + 4 > s.len: bad("the file ends early")
    let model = s[p ..< p + 4]
    p += 4
    let c = case model
            of "RGB ": argb(255, int(round(f32(s, p) * 255)), int(round(f32(s, p + 4) * 255)),
                            int(round(f32(s, p + 8) * 255)))
            of "CMYK": cmykToRgb(f32(s, p), f32(s, p + 4), f32(s, p + 8), f32(s, p + 12))
            of "Gray":
              let v = int(round(f32(s, p) * 255))
              argb(255, v, v, v)
            of "LAB ":
              let (r, g, b) = labToRgb(f32(s, p) * 100, f32(s, p + 4), f32(s, p + 8))
              argb(255, r, g, b)
            else: bad("a color model not read (" & model & ")")
    result.add (name, c)

proc writeAse*(sw: openArray[Swatch]): string =
  ## Swatches as an Adobe Swatch Exchange file (RGB, global colors).
  result = "ASEF"
  result.w16(1)
  result.w16(0)
  result.w32(sw.len)
  for (name, c) in sw:
    var b = ""
    let u = toUtf16(name)
    b.w16(u.len + 1)
    for v in u: b.w16(v)
    b.w16(0)
    b.add "RGB "
    for sh in [16, 8, 0]:
      b.w32(int(cast[uint32](float32(int((c shr sh) and 255)) / 255)))
    b.w16(0)                                        # (global)
    result.w16(1)
    result.w32(b.len)
    result.add b

# ---- curves (.acv), levels (.alv) ------------------------------------------------------------------

proc readAcv*(s: string): seq[seq[CurvePoint]] =
  ## A Curves preset: the composite curve, then the channels' (R, G, B...),
  ## each its points (input, output 0..255).
  if s.len < 4: bad("not a curves file")
  let version = be16(s, 0)
  if version notin [1, 4]: bad("not a curves file")
  let n = be16(s, 2)
  if n < 1 or n > 32: bad("not a curves file")
  var at = 4
  for _ in 0 ..< n:
    let k = be16(s, at)
    at += 2
    if k < 2 or k > 19: bad("a damaged curve")
    var c: seq[CurvePoint]
    for _ in 0 ..< k:
      let o = be16(s, at)
      let i = be16(s, at + 2)
      at += 4
      c.add (clamp(i, 0, 255), clamp(o, 0, 255))
    result.add c

proc writeAcv*(curves: openArray[seq[CurvePoint]]): string =
  ## Curves as a Photoshop .acv (version 1).
  result.w16(1)
  result.w16(curves.len)
  for c in curves:
    result.w16(c.len)
    for (i, o) in c:
      result.w16(o)
      result.w16(i)

proc readAlv*(s: string): seq[LevelsRecord] =
  ## A Levels preset: the composite, then the channels (29 records; those
  ## after the color channels are not used).
  if s.len < 2 + 10 or be16(s, 0) != 2: bad("not a levels file")
  var at = 2
  while at + 10 <= s.len and result.len < 29:
    result.add LevelsRecord(inLo: be16(s, at), inHi: be16(s, at + 2), outLo: be16(s, at + 4),
                            outHi: be16(s, at + 6), gamma: be16(s, at + 8) / 100)
    at += 10

proc writeAlv*(recs: openArray[LevelsRecord]): string =
  ## Levels as a Photoshop .alv (29 records, the missing ones neutral).
  result.w16(2)
  for k in 0 ..< 29:
    let r = if k < recs.len: recs[k] else: LevelsRecord(inHi: 255, outHi: 255, gamma: 1)
    result.w16(r.inLo); result.w16(r.inHi); result.w16(r.outLo); result.w16(r.outHi)
    result.w16(int(round(r.gamma * 100)))
  result.add "\0\0\0\0"

# ---- gradients (.grd) -----------------------------------------------------------------------------

proc stopsOfGrdn(g: PsdValue): seq[GradientStop] =
  ## A gradient descriptor's colors and opacities, as stops.
  var cs: seq[(float, uint32)]
  var ts: seq[(float, float)]
  let clrs = g["Clrs"]
  if clrs != nil and clrs.kind == pkList:
    for c in clrs.list:
      let kind = c["Type"].enumValue
      let col = if kind == "FrgC": 0xFF000000'u32 elif kind == "BckC": 0xFFFFFFFF'u32 else: c["Clr "].rgbOf
      cs.add (c["Lctn"].num / 4096, col)
  let trns = g["Trns"]
  if trns != nil and trns.kind == pkList:
    for t in trns.list: ts.add (t["Lctn"].num / 4096, t["Opct"].num(100) / 100)
  if cs.len == 0: cs = @[(0.0, 0xFF000000'u32), (1.0, 0xFFFFFFFF'u32)]
  if ts.len == 0: ts = @[(0.0, 1.0)]
  proc alphaAt(t: float): float =
    if t <= ts[0][0]: return ts[0][1]
    for k in 1 .. ts.high:
      if t <= ts[k][0]:
        let span = max(1e-9, ts[k][0] - ts[k - 1][0])
        return ts[k - 1][1] + (ts[k][1] - ts[k - 1][1]) * (t - ts[k - 1][0]) / span
    ts[^1][1]
  for (t, c) in cs:
    result.add GradientStop(at: t, color: (c and 0xFFFFFF'u32) or
                            (uint32(clamp(int(round(alphaAt(t) * 255)), 0, 255)) shl 24), mid: 0.5)

proc readGrd*(s: string): seq[GradientPreset] =
  ## A Photoshop gradients file (version 5, Photoshop 6 and later): each
  ## gradient's name and stops (solid ones; a noise gradient gets its two
  ## ends).
  if s.len < 8 or s[0 ..< 4] != "8BGR": bad("not a gradients file")
  if be16(s, 4) != 5: bad("a gradients file of an old version (" & $be16(s, 4) & ")")
  # (a descriptor after the 16 that says its version)
  let root = try: readDescriptor(s, 10) except PsdError: bad("a damaged gradients file")
  let list = root["GrdL"]
  if list == nil or list.kind != pkList: return
  for item in list.list:
    let g = item["Grad"]
    if g == nil: continue
    var name = g["Nm  "]
    var n = if name != nil and name.kind == pkText: name.s else: "Gradient"
    # ("$$$/key=Name": the name after the =)
    let eq = n.find('=')
    if n.startsWith("$$$") and eq > 0: n = n[eq + 1 .. ^1]
    result.add GradientPreset(name: n, stops: stopsOfGrdn(g))

# ---- patterns (.pat) ------------------------------------------------------------------------------

proc unpackRows(s: string; at: var int; w, h: int; comp: int): seq[uint8] =
  ## A channel's rows: raw, or PackBits with their lengths first.
  result = newSeq[uint8](w * h)
  if comp == 0:
    if at + w * h > s.len: bad("the file ends early")
    for i in 0 ..< w * h: result[i] = uint8(ord(s[at + i]))
    at += w * h
    return
  var lens = newSeq[int](h)
  for y in 0 ..< h:
    lens[y] = be16(s, at)
    at += 2
  for y in 0 ..< h:
    var p = at
    let stop = at + lens[y]
    var x = 0
    while p < stop and x < w:
      if p >= s.len: bad("the file ends early")
      var n = ord(s[p])
      inc p
      if n >= 128: n -= 256
      if n >= 0:
        for _ in 0 .. n:
          if x < w and p < s.len: result[y * w + x] = uint8(ord(s[p]))
          inc x
          inc p
      elif n != -128:
        if p >= s.len: bad("the file ends early")
        let v = uint8(ord(s[p]))
        inc p
        for _ in 0 .. -n:
          if x < w: result[y * w + x] = v
          inc x
    at = stop

proc readPat*(s: string): seq[PatternPreset] =
  ## A Photoshop patterns file: each pattern's name and pixels (RGB,
  ## grayscale, indexed; 8 bits).
  if s.len < 12 or s[0 ..< 4] != "8BPT" or be16(s, 4) != 1: bad("not a patterns file")
  let n = be32(s, 6)
  var at = 10
  for _ in 0 ..< n:
    if at + 12 > s.len: break
    if be32(s, at) != 1: bad("a pattern of a version not read")
    let mode = be32(s, at + 4)
    let h = be16(s, at + 8)
    let w = be16(s, at + 10)
    at += 12
    let nameLen = be32(s, at)
    let name = utf16be(s, at + 4, nameLen)
    at += 4 + 2 * nameLen
    let idLen = ord(s[at])
    at += 1 + idLen
    var palette: seq[uint32]
    if mode == 2:
      for k in 0 ..< 256:
        palette.add argb(255, ord(s[at + 3 * k]), ord(s[at + 3 * k + 1]), ord(s[at + 3 * k + 2]))
      at += 768
    # the virtual memory array list
    if be32(s, at) != 3: bad("a damaged pattern")
    let vlen = be32(s, at + 4)
    let vEnd = at + 8 + vlen
    var p = at + 8 + 16                              # (its rectangle)
    let nch = be32(s, p)
    p += 4
    var chans: seq[seq[uint8]]
    for c in 0 ..< nch + 2:
      if p + 4 > vEnd: break
      let written = be32(s, p)
      if written == 0:
        p += 4
        continue
      let clen = be32(s, p + 4)
      let cEnd = p + 8 + clen
      var q = p + 8
      let depth = be32(s, q)
      let t = be32(s, q + 4)
      let l = be32(s, q + 8)
      let b = be32(s, q + 12)
      let r = be32(s, q + 16)
      let comp = ord(s[q + 22])
      q += 23
      let cw = r - l
      let chh = b - t
      if depth == 8 and cw == w and chh == h and cw > 0 and chh > 0:
        chans.add unpackRows(s, q, cw, chh, comp)
      p = cEnd
    at = vEnd
    if w <= 0 or h <= 0 or w * h > 64_000_000: continue
    var px = newSeq[uint32](w * h)
    case mode
    of 3:                                            # RGB
      if chans.len < 3: continue
      let alpha = if chans.len > 3: chans[3] else: @[]
      for i in 0 ..< w * h:
        px[i] = argb(if alpha.len == w * h: int(alpha[i]) else: 255, int(chans[0][i]), int(chans[1][i]),
                     int(chans[2][i]))
    of 1:                                            # grayscale
      if chans.len < 1: continue
      for i in 0 ..< w * h:
        let v = int(chans[0][i])
        px[i] = argb(255, v, v, v)
    of 2:                                            # indexed
      if chans.len < 1 or palette.len < 256: continue
      for i in 0 ..< w * h: px[i] = palette[int(chans[0][i])]
    else: continue
    result.add PatternPreset(name: name, w: w, h: h, px: px)

# ---- color books: .acb ------------------------------------------------------------------------------
#
# The libraries of named colors Photoshop's Color Libraries show (Pantone,
# Toyo, HKS... the user's own): "8BCB", a version, an id, the title, a
# prefix and a suffix for the names, a description (UTF-16 strings), the
# number of colors, how many a page shows, the color model (0 RGB, 2 CMYK,
# 7 Lab); each color its name, a 6-letter key and its components (CMYK as
# 255 - the ink, Lab's L in 0..255, a and b + 128); at the end "spflspot"
# (spot colors) or "spflproc" (process colors).

type
  BookModel* = enum
    ## The color model a color book's colors are given in.
    bkRgb = "RGB", bkCmyk = "CMYK", bkLab = "Lab"
  BookColor* = object
    ## A named color of a color book.
    name*: string               ## its name (the book's prefix and suffix not in it)
    code*: string               ## a short key (6 letters at most)
    color*: uint32              ## as it looks (ARGB)
    cmyk*: array[4, int]        ## the inks, % (a CMYK book)
    lab*: array[3, int]         ## L 0..100, a and b -128..127 (a Lab book)
  ColorBook* = object
    ## A color book (.acb): a library of named colors such as Pantone's.
    title*, prefix*, postfix*, description*: string
      ## its name ("PANTONE+ Solid Coated"), what comes before and after
      ## each color's name ("PANTONE ", " C"), and a line about it
    id*: int                    ## the book's identifier, as the file gives it
    model*: BookModel           ## the model its colors are given in
    spot*: bool                 ## spot colors (inks of their own), else process (CMYK)
    pageSize*: int              ## colors a page shows in Photoshop's dialog
    colors*: seq[BookColor]     ## its colors, in the book's order

proc fullName*(b: ColorBook; c: BookColor): string =
  ## A color's name as printed: "PANTONE 186 C".
  (b.prefix & c.name & b.postfix).strip

proc readAcb*(data: string): ColorBook =
  ## A color book. Raises `AdobeError` when it is not one.
  if data.len < 32 or not data.startsWith("8BCB"): raise newException(AdobeError, "not a color book")
  var at = 4
  template need(n: int) =
    if at + n > data.len: raise newException(AdobeError, "a damaged color book")
  proc str(data: string; at: var int): string =
    if at + 4 > data.len: raise newException(AdobeError, "a damaged color book")
    let n = be32(data, at)
    at += 4
    if n < 0 or at + 2 * n > data.len: raise newException(AdobeError, "a damaged color book")
    result = utf16be(data, at, n)
    at += 2 * n
    let eq = result.find('=')
    if result.startsWith("$$$") and eq > 0: result = result[eq + 1 .. ^1]
    result = result.replace("^R", "®").replace("^C", "©")
  need(4)
  at += 2                                  # (the version)
  result.id = be16(data, at)
  at += 2
  result.title = str(data, at)
  result.prefix = str(data, at)
  result.postfix = str(data, at)
  result.description = str(data, at)
  need(8)
  let count = be16(data, at)
  result.pageSize = be16(data, at + 2)
  let model = be16(data, at + 6)
  at += 8
  result.model = case model
                 of 0: bkRgb
                 of 2: bkCmyk
                 of 7: bkLab
                 else: raise newException(AdobeError, "a color book in an unknown color model")
  let comps = if result.model == bkCmyk: 4 else: 3
  for i in 0 ..< count:
    var c = BookColor(name: str(data, at))
    need(6 + comps)
    c.code = data[at ..< at + 6].strip
    at += 6
    let v = [ord(data[at]), ord(data[at + 1]), ord(data[at + 2]), (if comps == 4: ord(data[at + 3]) else: 0)]
    at += comps
    case result.model
    of bkRgb: c.color = argb(255, v[0], v[1], v[2])
    of bkCmyk:
      for k in 0 .. 3: c.cmyk[k] = int(round((255 - v[k]) * 100 / 255))
      c.color = printed(255 - v[0], 255 - v[1], 255 - v[2], 255 - v[3])
    of bkLab:
      c.lab = [int(round(v[0] * 100 / 255)), v[1] - 128, v[2] - 128]
      c.color = fromLab(c.lab[0].float, c.lab[1].float, c.lab[2].float)
    if c.name.len > 0 or c.code.len > 0: result.colors.add c
  result.spot = result.model == bkLab
  if at + 8 <= data.len: result.spot = data[at ..< at + 8] == "spflspot"

proc writeAcb*(b: ColorBook): string =
  ## A color book in Photoshop's format (its colors in the book's model).
  proc str(o: var string; s: string) =
    let u = toUtf16(s)
    o.w32(u.len)
    for v in u: o.w16(v)
  result = "8BCB"
  result.w16(1)
  result.w16(b.id)
  result.str(b.title)
  result.str(b.prefix)
  result.str(b.postfix)
  result.str(b.description)
  result.w16(b.colors.len)
  result.w16(clamp(b.pageSize, 1, 9))
  result.w16(0)
  result.w16(case b.model
             of bkRgb: 0
             of bkCmyk: 2
             of bkLab: 7)
  for c in b.colors:
    result.str(c.name)
    var code = c.code
    if code.len > 6: code.setLen(6)
    result.add code.alignLeft(6)
    case b.model
    of bkRgb:
      result.add char(rOf(c.color)); result.add char(gOf(c.color)); result.add char(bOf(c.color))
    of bkCmyk:
      for k in 0 .. 3: result.add char(255 - clamp(int(round(c.cmyk[k] * 255 / 100)), 0, 255))
    of bkLab:
      result.add char(clamp(int(round(c.lab[0] * 255 / 100)), 0, 255))
      result.add char(clamp(c.lab[1] + 128, 0, 255))
      result.add char(clamp(c.lab[2] + 128, 0, 255))
  result.add(if b.spot: "spflspot" else: "spflproc")

proc builtinBooks*(): seq[ColorBook] =
  ## Libraries that come with the kit (open: no one's trademarks or
  ## licensed colors): the web's 216 safe colors, the CSS named colors,
  ## process CMYK tints, and grays. Pantone's and others' books are the
  ## user's own .acb files (`readAcb`).
  var web = ColorBook(title: "Web Safe Colors", model: bkRgb, pageSize: 6)
  for r in 0 .. 5:
    for g in 0 .. 5:
      for b in 0 .. 5:
        let c = argb(255, r * 51, g * 51, b * 51)
        let h = toHex(int(c and 0xFFFFFF'u32), 6)
        web.colors.add BookColor(name: "#" & h, code: h, color: c)
  result.add web
  const css = [("AliceBlue", 0xF0F8FF), ("AntiqueWhite", 0xFAEBD7), ("Aqua", 0x00FFFF),
    ("Aquamarine", 0x7FFFD4), ("Azure", 0xF0FFFF), ("Beige", 0xF5F5DC), ("Bisque", 0xFFE4C4),
    ("Black", 0x000000), ("BlanchedAlmond", 0xFFEBCD), ("Blue", 0x0000FF), ("BlueViolet", 0x8A2BE2),
    ("Brown", 0xA52A2A), ("BurlyWood", 0xDEB887), ("CadetBlue", 0x5F9EA0), ("Chartreuse", 0x7FFF00),
    ("Chocolate", 0xD2691E), ("Coral", 0xFF7F50), ("CornflowerBlue", 0x6495ED), ("Cornsilk", 0xFFF8DC),
    ("Crimson", 0xDC143C), ("Cyan", 0x00FFFF), ("DarkBlue", 0x00008B), ("DarkCyan", 0x008B8B),
    ("DarkGoldenRod", 0xB8860B), ("DarkGray", 0xA9A9A9), ("DarkGreen", 0x006400), ("DarkKhaki", 0xBDB76B),
    ("DarkMagenta", 0x8B008B), ("DarkOliveGreen", 0x556B2F), ("DarkOrange", 0xFF8C00),
    ("DarkOrchid", 0x9932CC), ("DarkRed", 0x8B0000), ("DarkSalmon", 0xE9967A), ("DarkSeaGreen", 0x8FBC8F),
    ("DarkSlateBlue", 0x483D8B), ("DarkSlateGray", 0x2F4F4F), ("DarkTurquoise", 0x00CED1),
    ("DarkViolet", 0x9400D3), ("DeepPink", 0xFF1493), ("DeepSkyBlue", 0x00BFFF), ("DimGray", 0x696969),
    ("DodgerBlue", 0x1E90FF), ("FireBrick", 0xB22222), ("FloralWhite", 0xFFFAF0), ("ForestGreen", 0x228B22),
    ("Fuchsia", 0xFF00FF), ("Gainsboro", 0xDCDCDC), ("GhostWhite", 0xF8F8FF), ("Gold", 0xFFD700),
    ("GoldenRod", 0xDAA520), ("Gray", 0x808080), ("Green", 0x008000), ("GreenYellow", 0xADFF2F),
    ("HoneyDew", 0xF0FFF0), ("HotPink", 0xFF69B4), ("IndianRed", 0xCD5C5C), ("Indigo", 0x4B0082),
    ("Ivory", 0xFFFFF0), ("Khaki", 0xF0E68C), ("Lavender", 0xE6E6FA), ("LavenderBlush", 0xFFF0F5),
    ("LawnGreen", 0x7CFC00), ("LemonChiffon", 0xFFFACD), ("LightBlue", 0xADD8E6), ("LightCoral", 0xF08080),
    ("LightCyan", 0xE0FFFF), ("LightGoldenRodYellow", 0xFAFAD2), ("LightGray", 0xD3D3D3),
    ("LightGreen", 0x90EE90), ("LightPink", 0xFFB6C1), ("LightSalmon", 0xFFA07A),
    ("LightSeaGreen", 0x20B2AA), ("LightSkyBlue", 0x87CEFA), ("LightSlateGray", 0x778899),
    ("LightSteelBlue", 0xB0C4DE), ("LightYellow", 0xFFFFE0), ("Lime", 0x00FF00), ("LimeGreen", 0x32CD32),
    ("Linen", 0xFAF0E6), ("Magenta", 0xFF00FF), ("Maroon", 0x800000), ("MediumAquaMarine", 0x66CDAA),
    ("MediumBlue", 0x0000CD), ("MediumOrchid", 0xBA55D3), ("MediumPurple", 0x9370DB),
    ("MediumSeaGreen", 0x3CB371), ("MediumSlateBlue", 0x7B68EE), ("MediumSpringGreen", 0x00FA9A),
    ("MediumTurquoise", 0x48D1CC), ("MediumVioletRed", 0xC71585), ("MidnightBlue", 0x191970),
    ("MintCream", 0xF5FFFA), ("MistyRose", 0xFFE4E1), ("Moccasin", 0xFFE4B5), ("NavajoWhite", 0xFFDEAD),
    ("Navy", 0x000080), ("OldLace", 0xFDF5E6), ("Olive", 0x808000), ("OliveDrab", 0x6B8E23),
    ("Orange", 0xFFA500), ("OrangeRed", 0xFF4500), ("Orchid", 0xDA70D6), ("PaleGoldenRod", 0xEEE8AA),
    ("PaleGreen", 0x98FB98), ("PaleTurquoise", 0xAFEEEE), ("PaleVioletRed", 0xDB7093),
    ("PapayaWhip", 0xFFEFD5), ("PeachPuff", 0xFFDAB9), ("Peru", 0xCD853F), ("Pink", 0xFFC0CB),
    ("Plum", 0xDDA0DD), ("PowderBlue", 0xB0E0E6), ("Purple", 0x800080), ("RebeccaPurple", 0x663399),
    ("Red", 0xFF0000), ("RosyBrown", 0xBC8F8F), ("RoyalBlue", 0x4169E1), ("SaddleBrown", 0x8B4513),
    ("Salmon", 0xFA8072), ("SandyBrown", 0xF4A460), ("SeaGreen", 0x2E8B57), ("SeaShell", 0xFFF5EE),
    ("Sienna", 0xA0522D), ("Silver", 0xC0C0C0), ("SkyBlue", 0x87CEEB), ("SlateBlue", 0x6A5ACD),
    ("SlateGray", 0x708090), ("Snow", 0xFFFAFA), ("SpringGreen", 0x00FF7F), ("SteelBlue", 0x4682B4),
    ("Tan", 0xD2B48C), ("Teal", 0x008080), ("Thistle", 0xD8BFD8), ("Tomato", 0xFF6347),
    ("Turquoise", 0x40E0D0), ("Violet", 0xEE82EE), ("Wheat", 0xF5DEB3), ("White", 0xFFFFFF),
    ("WhiteSmoke", 0xF5F5F5), ("Yellow", 0xFFFF00), ("YellowGreen", 0x9ACD32)]
  var named = ColorBook(title: "CSS Named Colors", model: bkRgb, pageSize: 7)
  for (n, v) in css:
    named.colors.add BookColor(name: n, code: n[0 ..< min(6, n.len)].toUpperAscii, color: 0xFF000000'u32 or uint32(v))
  result.add named
  var process = ColorBook(title: "Process Tints (CMYK)", model: bkCmyk, pageSize: 5)
  const steps = [100, 75, 50, 25, 10]
  for (inkName, k) in [("Cyan", 0), ("Magenta", 1), ("Yellow", 2), ("Black", 3)]:
    for v in steps:
      var ink = [0, 0, 0, 0]
      ink[k] = v
      process.colors.add BookColor(name: inkName & " " & $v & "%", code: inkName[0 .. 0] & $v,
                                   cmyk: ink, color: printed(ink[0] * 255 div 100, ink[1] * 255 div 100,
                                                             ink[2] * 255 div 100, ink[3] * 255 div 100))
  for (n, ink) in [("Red (M100 Y100)", [0, 100, 100, 0]), ("Green (C100 Y100)", [100, 0, 100, 0]),
                   ("Blue (C100 M100)", [100, 100, 0, 0]), ("Rich Black", [60, 40, 40, 100])]:
    process.colors.add BookColor(name: n, code: n[0 .. 2], cmyk: ink,
                                 color: printed(ink[0] * 255 div 100, ink[1] * 255 div 100,
                                                ink[2] * 255 div 100, ink[3] * 255 div 100))
  result.add process
  var grays = ColorBook(title: "Grays", model: bkRgb, pageSize: 5)
  for k in 0 .. 20:
    let v = 255 - k * 255 div 20
    grays.colors.add BookColor(name: "Gray " & $(k * 5) & "%", code: "G" & $(k * 5), color: argb(255, v, v, v))
  result.add grays

proc kindOf*(path: string; data: string): string =
  ## What kind of preset a file holds: "aco", "ase", "acb", "acv", "alv",
  ## "grd", "pat" (by its first bytes, else its extension), "radj" (Retro
  ## Photo's adjustment presets), "" none of these.
  if data.startsWith("ASEF"): return "ase"
  if data.startsWith("{") and "Retro Photo Adjustment Presets" in data: return "radj"
  if data.startsWith("8BCB"): return "acb"
  if data.startsWith("8BGR"): return "grd"
  if data.startsWith("8BPT"): return "pat"
  let ext = path.toLowerAscii
  for e in ["aco", "ase", "acb", "acv", "alv", "grd", "pat"]:
    if ext.endsWith("." & e): return e
  ""
