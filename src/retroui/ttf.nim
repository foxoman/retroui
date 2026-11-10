## TrueType fonts in plain Nim: reads a .ttf (`cmap` formats 4 and 12,
## `glyf` simple and composite outlines, `hmtx`, `kern`) and renders glyphs
## to anti-aliased coverage masks at any pixel size. Variable fonts (`fvar`,
## `avar`, `gvar`, `HVAR`) give a face at any axis values:
##
## ```nim
## let f = parseFace(readFile("NotoSansArabic[wdth,wght].ttf"))
## echo f.axes                                   # wght 100..900, wdth 62.5..100
## let bold = f.variation([("wght", 700.0)])     # advance, contours, render, bounds at wght 700
## ```
##
## The rasterizer computes the exact area each pixel's square has inside
## the outline (signed-area accumulation, as font-rs does), so edges are
## smooth at any size. Small sizes get a light vertical hinting: the
## baseline, x-height, cap height and ascender land on whole pixels, which
## keeps text crisp on 1x screens; 2x and 4K screens need none.

import std/[tables, math, algorithm, bitops]
import raster

type
  FontError* = object of CatchableError
    ## Raised when a font file cannot be read (damaged, or not TrueType/CFF).

  FontSrc = ref object
    ## The bytes of a font file (shared by a face and its variations).
    bytes: string

  VarAxis = object
    tag: string
    minV, defV, maxV: float
    nameId: int

  VarFont = ref object
    ## What a variable font's tables say (shared by all its instances).
    axes: seq[VarAxis]
    named: seq[tuple[nameId: int; coords: seq[float]]]
    avar: int                          ## the avar table (-1 none)
    gvar, gvarData, gvarOffsets: int   ## gvar, its glyph variation data, the offsets
    gvarLong: bool
    shared: seq[seq[int]]              ## the shared peak tuples
    hvar, hvarStore, hvarAdvMap: int   ## HVAR, its item variation store, its advance map (-1 none)
    made: seq[tuple[coords: seq[int]; face: Face]]  ## instances made (newest last)

  Face* = ref object
    ## One font file, parsed lazily from its bytes.
    src: FontSrc
    tabs: Table[string, tuple[at, len: int]]  ## the table directory
    vf: VarFont                        ## the variation tables (nil: not read yet)
    coords: seq[int]                   ## this instance's normalized axis values (2.14); empty: the default
    advs: seq[int32]                   ## this instance's advances (-1 not known yet)
    shaper*: RootRef                   ## kept for the OpenType shaper (otshape): its parsed tables
    unitsPerEm*: int
    ascent*, descent*, lineGap*: int   ## hhea; `descent` is negative
    numGlyphs*: int                    ## glyphs in the font (0 ..< numGlyphs)
    locaLong: bool
    loca, glyf, hmtx, numHMetrics: int
    cmap: int                          ## the subtable used
    cmapTable: int                     ## the cmap table (-1 none)
    cmapFormat: int
    kern: Table[uint32, int16]         ## (left shl 16) or right -> units (the `kern` table)
    gposPairs: seq[int]                ## GPOS: the pair adjustment subtables of its kerning
    gposRead: bool                     ## (`gposPairs` looked for)
    kernMemo: Table[uint32, int16]     ## pairs looked up in GPOS
    ascii: array[128, uint16]          ## glyph of each ASCII character
    zones: seq[tuple[lo, hi: float32]] ## vertical alignment zones
    fixedAdvance*: int                 ## > 0: every glyph this wide
    family*, style*: string            ## from the name table ("FreeSans", "Bold")
    weight*: int                       ## 100..900 (OS/2), 400 regular
    italic*: bool
    underlinePos*, underlineThick*: int ## (post) font units
    clockwise: int8                    ## filled regions to the right of the contours (TrueType): 1;
                                       ## to their left: -1; 0 not known yet
    stem: int                          ## the width of an upright stem (of "l"), font units; -1 not
                                       ## known yet, 0 none found

  Point = object
    x, y: float32
    on: bool

  Outline = object
    pts: seq[Point]
    ends: seq[int]                     ## index after each contour's last point

  Mask* = object
    ## A rendered glyph: `a` is coverage (0..255), `w` x `h`, row by row.
    ## Its top-left pixel is `left`, `top` from the pen on the baseline
    ## (y grows down, so `top` is negative for what is above).
    w*, h*: int      ## size in pixels
    left*, top*: int ## the top-left pixel from the pen (see above)
    a*: seq[uint8]   ## coverage, `w` x `h` (`lcd`: three per pixel)
    lcd*: bool       ## three per pixel (red, green, blue: the screen's strips)


proc fontData*(f: Face): string =
  ## The font file's bytes (as it is embedded in a PDF).
  f.src.bytes

proc fontBytes*(f: Face): tuple[p: ptr UncheckedArray[uint8]; len: int] =
  ## The font file's bytes, not copied (for the readers of more tables, as
  ## otshape's GSUB, GPOS and GDEF): valid while the face (or a variation
  ## of it) lives.
  if f.src.bytes.len == 0: return (nil, 0)
  (cast[ptr UncheckedArray[uint8]](unsafeAddr f.src.bytes[0]), f.src.bytes.len)

proc tableRange*(f: Face; tag: string): tuple[at, len: int] =
  ## Where table `tag` ("GSUB", "GPOS"...) is in `fontBytes`: (-1, 0) when
  ## the font has none.
  f.tabs.getOrDefault(tag, (-1, 0))

proc fail(msg: string) {.noreturn.} = raise newException(FontError, msg)

template u8(f: Face; i: int): int = ord(f.src.bytes[i])
proc u16(f: Face; i: int): int {.inline.} =
  (ord(f.src.bytes[i]) shl 8) or ord(f.src.bytes[i+1])
proc i16(f: Face; i: int): int {.inline.} =
  let v = f.u16(i)
  if v >= 0x8000: v - 0x10000 else: v
proc u32(f: Face; i: int): int {.inline.} =
  ## (an offset or a length: on a 32-bit system one past what an int holds
  ## is the most it holds, so that it points past the end of any file)
  let v = (uint32(f.u16(i)) shl 16) or uint32(f.u16(i + 2))
  when sizeof(int) == 8: int(v)
  else: (if v > 0x7FFFFFFF'u32: high(int) else: int(v))

proc s32(f: Face; i: int): int {.inline.} =
  int(cast[int32]((uint32(f.u16(i)) shl 16) or uint32(f.u16(i + 2))))

# ---- parsing ------------------------------------------------------------------------

proc glyphOf*(f: Face; cp: int): int =
  ## The glyph for character `cp`; 0 (the "missing" box) when there is none.
  if cp < 128 and cp >= 0 and f.ascii[cp] != 0: return int(f.ascii[cp])
  if f.cmap == 0: return 0
  let t = f.cmap
  case f.cmapFormat
  of 4:
    if cp > 0xFFFF: return 0
    let segX2 = f.u16(t + 6)
    let ends = t + 14
    let starts = ends + segX2 + 2
    let deltas = starts + segX2
    let ranges = deltas + segX2
    var lo = 0
    var hi = segX2 div 2 - 1
    while lo <= hi:
      let m = (lo + hi) div 2
      let e = f.u16(ends + 2 * m)
      if e < cp: lo = m + 1
      else:
        let s = f.u16(starts + 2 * m)
        if s > cp: hi = m - 1
        else:
          let delta = f.u16(deltas + 2 * m)
          let ro = f.u16(ranges + 2 * m)
          if ro == 0: return (cp + delta) and 0xFFFF
          let at = ranges + 2 * m + ro + 2 * (cp - s)
          if at + 1 >= f.src.bytes.len: return 0
          let g = f.u16(at)
          return if g == 0: 0 else: (g + delta) and 0xFFFF
    0
  of 12:
    let n = f.u32(t + 12)
    var lo = 0
    var hi = n - 1
    while lo <= hi:
      let m = (lo + hi) div 2
      let g = t + 16 + 12 * m
      if f.u32(g + 4) < cp: lo = m + 1
      elif f.u32(g) > cp: hi = m - 1
      else: return f.u32(g + 8) + cp - f.u32(g)
    0
  else: 0

proc subtableGlyph(f: Face; t, code: int): int =
  ## (a character map subtable of format 0, 4 or 6: the glyph of `code`)
  case f.u16(t)
  of 0:
    if code in 0 .. 255 and t + 6 + code < f.src.bytes.len: f.u8(t + 6 + code) else: 0
  of 6:
    let first = f.u16(t + 6)
    let n = f.u16(t + 8)
    if code >= first and code < first + n: f.u16(t + 10 + 2 * (code - first)) else: 0
  of 4:
    let segX2 = f.u16(t + 6)
    let ends = t + 14
    let starts = ends + segX2 + 2
    let deltas = starts + segX2
    let ranges = deltas + segX2
    for m in 0 ..< segX2 div 2:
      if f.u16(ends + 2 * m) < code: continue
      let st = f.u16(starts + 2 * m)
      if st > code: return 0
      let delta = f.u16(deltas + 2 * m)
      let ro = f.u16(ranges + 2 * m)
      if ro == 0: return (code + delta) and 0xFFFF
      let at = ranges + 2 * m + ro + 2 * (code - st)
      if at + 1 >= f.src.bytes.len: return 0
      let g = f.u16(at)
      return if g == 0: 0 else: (g + delta) and 0xFFFF
    0
  else: 0

proc codeGlyph*(f: Face; code: int): int =
  ## The glyph a symbol font (or a font cut for a document) gives the byte
  ## `code`: its Windows symbol map (0xF000 + code), then its Mac map, then
  ## the plain code -- 0 none. (For text use `glyphOf`.)
  let cm = f.cmapTable
  if cm < 0 or cm + 4 > f.src.bytes.len: return 0
  for want in [(3, 0), (1, 0), (3, 1)]:
    for i in 0 ..< f.u16(cm + 2):
      let r = cm + 4 + 8 * i
      if r + 8 > f.src.bytes.len: break
      if f.u16(r) != want[0] or f.u16(r + 2) != want[1]: continue
      let t = cm + f.u32(r + 4)
      if t + 6 > f.src.bytes.len: continue
      var g = 0
      if want == (3, 0):
        g = f.subtableGlyph(t, 0xF000 + code)
        if g == 0: g = f.subtableGlyph(t, code)
      else: g = f.subtableGlyph(t, code)
      if g != 0: return g
  0

proc hasGlyph*(f: Face; cp: int): bool {.inline.} = f.glyphOf(cp) != 0
  ## The face has a glyph for the code point `cp`.

proc varAdvance(f: Face; g: int): int
proc varBounds(f: Face; g: int): tuple[x0, y0, x1, y1: int]
proc varOutline(f: Face; g: int; o: var Outline; m: array[6, float32])
proc findZones(f: Face)

proc advance*(f: Face; g: int): int =
  ## Advance width of glyph `g` in font units.
  if f.fixedAdvance > 0: return f.fixedAdvance
  if f.coords.len > 0: return f.varAdvance(g)
  if f.numHMetrics == 0: return 0
  let i = if g < f.numHMetrics: g else: f.numHMetrics - 1
  f.u16(f.hmtx + 4 * i)

proc readGposKern(f: Face)
proc gposKerning(f: Face; left, right: int): int

proc kerning*(f: Face; left, right: int): int =
  ## Extra space between `left` and `right` (font units, usually < 0): from
  ## the `kern` table, or from the pair adjustments of GPOS's kerning.
  if f.kern.len > 0: return int(f.kern.getOrDefault((uint32(left) shl 16) or uint32(right), 0))
  if not f.gposRead: f.readGposKern()
  if f.gposPairs.len == 0: return 0
  let key = (uint32(left) shl 16) or uint32(right)
  f.kernMemo.withValue(key, v):
    return int(v[])
  result = f.gposKerning(left, right)
  if f.kernMemo.len > 20000: f.kernMemo.clear()
  f.kernMemo[key] = int16(clamp(result, -32768, 32767))

proc hasKerning*(f: Face): bool =
  ## The face kerns some pairs (a `kern` table, or kerning in GPOS).
  if f.kern.len > 0: return true
  if not f.gposRead: f.readGposKern()
  f.gposPairs.len > 0

proc glyphSpan(f: Face; g: int): (int, int) =
  if g < 0 or g >= f.numGlyphs: return (0, 0)
  if f.locaLong:
    (f.glyf + f.u32(f.loca + 4 * g), f.glyf + f.u32(f.loca + 4 * g + 4))
  else:
    (f.glyf + 2 * f.u16(f.loca + 2 * g), f.glyf + 2 * f.u16(f.loca + 2 * g + 2))

proc bounds*(f: Face; g: int): tuple[x0, y0, x1, y1: int] =
  ## The bounding box of glyph `g` in font units (all 0 when empty).
  if f.coords.len > 0: return f.varBounds(g)
  let (a, b) = f.glyphSpan(g)
  if b - a < 10: return
  (f.i16(a + 2), f.i16(a + 4), f.i16(a + 6), f.i16(a + 8))

proc readOutline(f: Face; g: int; o: var Outline; depth = 0;
                 m: array[6, float32] = [1'f32, 0, 0, 1, 0, 0]) =
  ## Appends the contours of glyph `g`, transformed by the 2x3 matrix `m`.
  if f.coords.len > 0 and depth == 0:
    f.varOutline(g, o, m)
    return
  let (a, b) = f.glyphSpan(g)
  if b - a < 10 or depth > 8: return
  let n = f.i16(a)
  if n >= 0:
    let base = o.pts.len
    var p = a + 10
    var count = 0
    for i in 0 ..< n:
      let e = f.u16(p + 2 * i) + 1
      o.ends.add base + e
      count = e
    p += 2 * n
    p += 2 + f.u16(p)                   # skip the instructions
    var flags = newSeq[uint8](count)
    var i = 0
    while i < count:
      let fl = uint8(f.u8(p))
      inc p
      flags[i] = fl
      inc i
      if (fl and 8) != 0:
        var r = f.u8(p)
        inc p
        while r > 0 and i < count:
          flags[i] = fl
          inc i
          dec r
    var xs = newSeq[float32](count)
    var v = 0
    for k in 0 ..< count:
      let fl = flags[k]
      if (fl and 2) != 0:
        let d = f.u8(p)
        inc p
        v += (if (fl and 16) != 0: d else: -d)
      elif (fl and 16) == 0:
        v += f.i16(p)
        p += 2
      xs[k] = float32(v)
    v = 0
    for k in 0 ..< count:
      let fl = flags[k]
      if (fl and 4) != 0:
        let d = f.u8(p)
        inc p
        v += (if (fl and 32) != 0: d else: -d)
      elif (fl and 32) == 0:
        v += f.i16(p)
        p += 2
      let x = xs[k]
      let y = float32(v)
      o.pts.add Point(x: m[0] * x + m[2] * y + m[4],
                      y: m[1] * x + m[3] * y + m[5], on: (fl and 1) != 0)
  else:
    var p = a + 10
    while true:
      let fl = f.u16(p)
      let sub = f.u16(p + 2)
      p += 4
      var dx, dy: float32
      if (fl and 1) != 0:
        dx = float32(f.i16(p)); dy = float32(f.i16(p + 2)); p += 4
      else:
        dx = float32(cast[int8](f.u8(p))); dy = float32(cast[int8](f.u8(p + 1))); p += 2
      if (fl and 2) == 0: dx = 0; dy = 0  # point matching: rare, ignored
      var c = [1'f32, 0, 0, 1]
      template f2d14(i: int): float32 = float32(f.i16(i)) / 16384'f32
      if (fl and 8) != 0:
        c[0] = f2d14(p); c[3] = c[0]; p += 2
      elif (fl and 0x40) != 0:
        c[0] = f2d14(p); c[3] = f2d14(p + 2); p += 4
      elif (fl and 0x80) != 0:
        c[0] = f2d14(p); c[1] = f2d14(p + 2); c[2] = f2d14(p + 4); c[3] = f2d14(p + 6)
        p += 8
      # child -> this glyph -> m
      let k = [m[0] * c[0] + m[2] * c[1], m[1] * c[0] + m[3] * c[1],
               m[0] * c[2] + m[2] * c[3], m[1] * c[2] + m[3] * c[3],
               m[0] * dx + m[2] * dy + m[4], m[1] * dx + m[3] * dy + m[5]]
      f.readOutline(sub, o, depth + 1, k)
      if (fl and 0x20) == 0: break

proc utf16be(s: string): string =
  var i = 0
  while i + 1 < s.len:
    var c = (ord(s[i]) shl 8) or ord(s[i + 1])
    i += 2
    if c >= 0xD800 and c < 0xDC00 and i + 1 < s.len:
      let lo = (ord(s[i]) shl 8) or ord(s[i + 1])
      c = 0x10000 + ((c - 0xD800) shl 10) + (lo - 0xDC00)
      i += 2
    if c < 0x80: result.add char(c)
    elif c < 0x800:
      result.add char(0xC0 or (c shr 6)); result.add char(0x80 or (c and 63))
    elif c < 0x10000:
      result.add char(0xE0 or (c shr 12)); result.add char(0x80 or ((c shr 6) and 63))
      result.add char(0x80 or (c and 63))
    else:
      result.add char(0xF0 or (c shr 18)); result.add char(0x80 or ((c shr 12) and 63))
      result.add char(0x80 or ((c shr 6) and 63)); result.add char(0x80 or (c and 63))

proc readNames(f: Face; nameTab: int) =
  ## The family and style names (the typographic ones when there are).
  if nameTab < 0 or nameTab + 6 > f.src.bytes.len: return
  let count = f.u16(nameTab + 2)
  let strings = nameTab + f.u16(nameTab + 4)
  var best: array[4, tuple[score: int; s: string]]   # name ids 1, 2, 16, 17
  for i in 0 ..< count:
    let r = nameTab + 6 + 12 * i
    if r + 12 > f.src.bytes.len: break
    let pid = f.u16(r)
    let eid = f.u16(r + 2)
    let lang = f.u16(r + 4)
    let nid = f.u16(r + 6)
    let len = f.u16(r + 8)
    let off = strings + f.u16(r + 10)
    let slot = case nid
               of 1: 0
               of 2: 1
               of 16: 2
               of 17: 3
               else: -1
    if slot < 0 or off + len > f.src.bytes.len: continue
    let raw = f.src.bytes[off ..< off + len]
    var score = 0
    var text = ""
    if pid == 3 and (eid == 1 or eid == 10 or eid == 0):
      score = if lang == 0x409: 3 else: 2
      text = utf16be(raw)
    elif pid == 0:
      score = 2
      text = utf16be(raw)
    elif pid == 1 and eid == 0:
      score = 1
      text = raw
    if score > best[slot].score and text.len > 0: best[slot] = (score, text)
  f.family = if best[2].s.len > 0: best[2].s else: best[0].s
  f.style = if best[3].s.len > 0: best[3].s elif best[1].s.len > 0: best[1].s else: "Regular"

proc fontCount*(data: string): int =
  ## How many faces a font file holds (more than one: a .ttc collection).
  if data.len >= 16 and data[0 .. 3] == "ttcf":
    ((ord(data[8]) shl 24) or (ord(data[9]) shl 16) or (ord(data[10]) shl 8) or ord(data[11]))
  elif data.len >= 4: 1
  else: 0

proc sfntOf*(data: string; index: int): string =
  ## Face `index` of a .ttc collection as a font file of its own (its
  ## tables copied out): what code that reads a font's tables from the
  ## start of the file (the PDF writer) takes. A plain font file: itself.
  if fontCount(data) <= 1 or data[0 .. 3] != "ttcf": return data
  proc be32(i: int): int =
    (ord(data[i]) shl 24) or (ord(data[i + 1]) shl 16) or (ord(data[i + 2]) shl 8) or ord(data[i + 3])
  proc be16(i: int): int = (ord(data[i]) shl 8) or ord(data[i + 1])
  if index < 0 or index >= fontCount(data) or 12 + 4 * index + 4 > data.len: return ""
  let at = be32(12 + 4 * index)
  if at + 12 > data.len: return ""
  let n = be16(at + 4)
  if at + 12 + 16 * n > data.len: return ""
  result = data[at ..< at + 12 + 16 * n]
  var body = ""
  for i in 0 ..< n:
    let r = at + 12 + 16 * i
    let off = be32(r + 8)
    let len = be32(r + 12)
    if off < 0 or len < 0 or off + len > data.len: result = ""; return
    let newOff = 12 + 16 * n + body.len
    for k in 0 .. 3: result[12 + 16 * i + 8 + k] = char((newOff shr (8 * (3 - k))) and 255)
    body.add data[off ..< off + len]
    while body.len mod 4 != 0: body.add '\0'
  result.add body

proc faceInfo*(path: string): seq[tuple[family, style: string; weight: int; italic: bool; index: int;
                                       variable: bool]] =
  ## The faces a font file holds (their names, weight and slant, whether it
  ## is a variable font), read without loading it: only TrueType outlines
  ## (.ttf, .ttc). Empty when it is not one.
  var f: File
  if not open(f, path): return
  defer: close(f)
  proc readAt(f: File; pos, n: int): string =
    result = newString(n)
    f.setFilePos(pos)
    if n > 0:
      let got = f.readBuffer(addr result[0], n)
      result.setLen(got)
  let head = f.readAt(0, 16)
  if head.len < 12: return
  var offsets: seq[int]
  proc be32(s: string; i: int): int =
    (ord(s[i]) shl 24) or (ord(s[i + 1]) shl 16) or (ord(s[i + 2]) shl 8) or ord(s[i + 3])
  proc be16(s: string; i: int): int = (ord(s[i]) shl 8) or ord(s[i + 1])
  if head[0 .. 3] == "ttcf":
    let n = be32(head, 8)
    if n <= 0 or n > 64: return
    let offs = f.readAt(12, 4 * n)
    if offs.len < 4 * n: return
    for i in 0 ..< n: offsets.add be32(offs, 4 * i)
  else: offsets.add 0
  for idx, at in offsets:
    let hdr = f.readAt(at, 12)
    if hdr.len < 12: continue
    if hdr[0 .. 3] != "\x00\x01\x00\x00" and hdr[0 .. 3] != "true": continue
    let n = be16(hdr, 4)
    if n <= 0 or n > 200: continue
    let dir = f.readAt(at + 12, 16 * n)
    if dir.len < 16 * n: continue
    var nameAt, nameLen, os2At, os2Len = 0
    var glyf, fvar = false
    for i in 0 ..< n:
      let tag = dir[16 * i ..< 16 * i + 4]
      if tag == "name": (nameAt, nameLen) = (be32(dir, 16 * i + 8), be32(dir, 16 * i + 12))
      elif tag == "OS/2": (os2At, os2Len) = (be32(dir, 16 * i + 8), be32(dir, 16 * i + 12))
      elif tag == "glyf": glyf = true
      elif tag == "fvar": fvar = true
    if not glyf or nameLen <= 0 or nameLen > 1_000_000: continue
    let fake = Face(src: FontSrc(bytes: f.readAt(nameAt, nameLen)))
    fake.readNames(0)
    if fake.family.len == 0: continue
    var weight = 400
    var italic = false
    if os2Len >= 64:
      let o = f.readAt(os2At, 64)
      if o.len >= 64:
        weight = be16(o, 4)
        italic = (be16(o, 62) and 1) != 0
    let st = fake.style
    for w in ["Italic", "Oblique"]:
      for k in 0 .. st.len - w.len:
        if st[k ..< k + w.len] == w: italic = true
    result.add (fake.family, fake.style, weight, italic, idx, fvar)

proc parseFace*(data: string; index = 0; loose = false): Face =
  ## A face from the bytes of a .ttf file (or the `index`th of a .ttc).
  ## `loose`: a font cut down to what a document uses (a PDF's), which may
  ## have no character map -- its glyphs are reached by number.
  let f = Face(src: FontSrc(bytes: data))
  if data.len < 12: fail("not a font file")
  var at = 0
  if data[0 .. 3] == "ttcf":
    if index < 0 or index >= fontCount(data) or 12 + 4 * index + 4 > data.len: fail("no such face")
    at = f.u32(12 + 4 * index)
    if at + 12 > data.len: fail("damaged font collection")
  let tag0 = data[at .. at + 3]
  if tag0 != "\x00\x01\x00\x00" and tag0 != "true":
    fail("only TrueType outlines are supported")
  var tables: Table[string, int]
  let n = f.u16(at + 4)
  for i in 0 ..< n:
    let r = at + 12 + 16 * i
    if r + 16 > data.len: fail("damaged font directory")
    tables[data[r ..< r + 4]] = f.u32(r + 8)
    f.tabs[data[r ..< r + 4]] = (f.u32(r + 8), f.u32(r + 12))
  for t in ["head", "hhea", "maxp", "loca", "glyf", "hmtx"]:
    if t notin tables: fail("the font has no " & t & " table")
  if "cmap" notin tables and not loose: fail("the font has no cmap table")
  let head = tables["head"]
  f.unitsPerEm = f.u16(head + 18)
  f.locaLong = f.i16(head + 50) == 1
  let hhea = tables["hhea"]
  f.ascent = f.i16(hhea + 4)
  f.descent = f.i16(hhea + 6)
  f.lineGap = f.i16(hhea + 8)
  f.numHMetrics = f.u16(hhea + 34)
  f.numGlyphs = f.u16(tables["maxp"] + 4)
  f.loca = tables["loca"]
  f.glyf = tables["glyf"]
  f.hmtx = tables["hmtx"]
  # cmap: a Unicode subtable, the full-range one if there is one
  let cm = tables.getOrDefault("cmap", -1)
  f.cmapTable = cm
  var best = 0
  for i in 0 ..< (if cm < 0: 0 else: f.u16(cm + 2)):
    let r = cm + 4 + 8 * i
    let pid = f.u16(r)
    let eid = f.u16(r + 2)
    let off = cm + f.u32(r + 4)
    let fmt = f.u16(off)
    let score =
      if fmt == 12 and (pid == 3 and eid == 10 or pid == 0): 3
      elif fmt == 4 and (pid == 3 and eid == 1 or pid == 0): 2
      else: 0
    if score > best:
      best = score
      f.cmap = off
      f.cmapFormat = fmt
  for c in 32 .. 126:
    f.ascii[c] = 0
    f.ascii[c] = uint16(f.glyphOf(c))
  # kern: format 0 horizontal pairs
  if "kern" in tables:
    let k = tables["kern"]
    if f.u16(k) == 0:
      var p = k + 4
      for _ in 0 ..< f.u16(k + 2):
        let len = f.u16(p + 2)
        let cov = f.u16(p + 4)
        if (cov shr 8) == 0 and (cov and 1) != 0:
          let pairs = f.u16(p + 6)
          for i in 0 ..< pairs:
            let q = p + 14 + 6 * i
            if q + 6 > data.len: break
            f.kern[(uint32(f.u16(q)) shl 16) or uint32(f.u16(q + 2))] =
              int16(f.i16(q + 4))
        p += len
  # the names, the weight, italic, the underline
  f.readNames(tables.getOrDefault("name", -1))
  f.weight = 400
  if "OS/2" in tables:
    let o = tables["OS/2"]
    if o + 64 <= data.len:
      f.weight = f.u16(o + 4)
      f.italic = (f.u16(o + 62) and 1) != 0
  if "post" in tables:
    let p = tables["post"]
    if p + 12 <= data.len:
      f.underlinePos = f.i16(p + 8)
      f.underlineThick = f.i16(p + 10)
  if f.underlineThick <= 0:
    f.underlineThick = max(1, f.unitsPerEm div 16)
    f.underlinePos = -f.unitsPerEm div 10
  if not f.italic:
    let st = f.style
    for w in ["Italic", "Oblique", "italic", "oblique"]:
      for k in 0 .. st.len - w.len:
        if st[k ..< k + w.len] == w: f.italic = true
  f.stem = -1
  f.findZones()
  f

proc findZones(f: Face) =
  ## The alignment zones from the Latin letters, for hinting small sizes.
  proc top(c: char): int = f.bounds(f.glyphOf(ord(c))).y1
  proc bottom(c: char): int = f.bounds(f.glyphOf(ord(c))).y0
  f.zones = @[]
  if f.hasGlyph(ord('x')) and f.hasGlyph(ord('o')) and f.hasGlyph(ord('H')):
    f.zones = @[(float32(min(0, bottom('o'))), 0'f32),
                (float32(top('x')), float32(max(top('x'), top('o')))),
                (float32(top('H')), float32(max(top('H'), top('O'))))]
    if f.hasGlyph(ord('d')) and top('d') > top('O'):
      f.zones.add (float32(top('d')), float32(top('d')))

proc fontName*(f: Face; nameId: int): string =
  ## The string the `name` table gives `nameId` (an English Windows one
  ## when there is), "" when it has none.
  let (tab, _) = f.tableRange("name")
  if tab < 0 or tab + 6 > f.src.bytes.len: return
  let count = f.u16(tab + 2)
  let strings = tab + f.u16(tab + 4)
  var best = 0
  for i in 0 ..< count:
    let r = tab + 6 + 12 * i
    if r + 12 > f.src.bytes.len: break
    if f.u16(r + 6) != nameId: continue
    let pid = f.u16(r)
    let eid = f.u16(r + 2)
    let lang = f.u16(r + 4)
    let len = f.u16(r + 8)
    let off = strings + f.u16(r + 10)
    if off + len > f.src.bytes.len: continue
    let raw = f.src.bytes[off ..< off + len]
    var score = 0
    var text = ""
    if pid == 3 and (eid == 1 or eid == 10 or eid == 0):
      score = if lang == 0x409: 3 else: 2
      text = utf16be(raw)
    elif pid == 0:
      score = 2
      text = utf16be(raw)
    elif pid == 1 and eid == 0:
      score = 1
      text = raw
    if score > best and text.len > 0:
      best = score
      result = text

# ---- kerning from GPOS ------------------------------------------------------------------
#
# Most fonts of today kern in GPOS only (pair adjustments, often by classes
# of glyphs): the subtables of the lookups the `kern` feature names are
# found once, and a pair is looked up in them when asked (and kept).

proc readGposKern(f: Face) =
  f.gposRead = true
  let (g, glen) = f.tableRange("GPOS")
  let n = f.src.bytes.len
  if g < 0 or glen < 10 or g + 10 > n or f.u16(g) != 1: return
  let featAt = g + f.u16(g + 6)
  let lookAt = g + f.u16(g + 8)
  if featAt + 2 > n or lookAt + 2 > n: return
  var lookups: seq[int]
  for i in 0 ..< f.u16(featAt):
    let r = featAt + 2 + 6 * i
    if r + 6 > n: break
    if f.src.bytes[r ..< r + 4] != "kern": continue
    let ft = featAt + f.u16(r + 4)
    if ft + 4 > n: continue
    for k in 0 ..< f.u16(ft + 2):
      if ft + 4 + 2 * k + 2 > n: break
      let li = f.u16(ft + 4 + 2 * k)
      if li notin lookups: lookups.add li
  lookups.sort()
  let lookCount = f.u16(lookAt)
  for li in lookups:
    if li >= lookCount or lookAt + 2 + 2 * li + 2 > n: continue
    let L = lookAt + f.u16(lookAt + 2 + 2 * li)
    if L + 6 > n: continue
    let kind = f.u16(L)
    for k in 0 ..< f.u16(L + 4):
      if L + 6 + 2 * k + 2 > n: break
      var st = L + f.u16(L + 6 + 2 * k)
      var t = kind
      if t == 9 and st + 8 <= n:          # (an extension: the real subtable further on)
        t = f.u16(st + 2)
        st = st + f.u32(st + 4)
      if t == 2 and st + 10 <= n and f.u16(st) in [1, 2]: f.gposPairs.add st
    if f.gposPairs.len > 0: f.gposPairs.add -1   # (the end of a lookup's subtables)

proc coverageIndex(f: Face; at, g: int): int =
  ## Where glyph `g` is in the coverage table at `at` (-1 not there).
  let n = f.src.bytes.len
  if at + 4 > n: return -1
  let count = f.u16(at + 2)
  case f.u16(at)
  of 1:
    var lo = 0
    var hi = count - 1
    while lo <= hi:
      let m = (lo + hi) shr 1
      if at + 4 + 2 * m + 2 > n: return -1
      let v = f.u16(at + 4 + 2 * m)
      if v == g: return m
      if v < g: lo = m + 1 else: hi = m - 1
  of 2:
    var lo = 0
    var hi = count - 1
    while lo <= hi:
      let m = (lo + hi) shr 1
      let r = at + 4 + 6 * m
      if r + 6 > n: return -1
      if g < f.u16(r): hi = m - 1
      elif g > f.u16(r + 2): lo = m + 1
      else: return f.u16(r + 4) + g - f.u16(r)
  else: discard
  -1

proc classOf(f: Face; at, g: int): int =
  ## The class glyph `g` has in the class definition at `at` (0 none).
  let n = f.src.bytes.len
  if at + 6 > n: return 0
  case f.u16(at)
  of 1:
    let first = f.u16(at + 2)
    let count = f.u16(at + 4)
    if g >= first and g < first + count and at + 6 + 2 * (g - first) + 2 <= n:
      return f.u16(at + 6 + 2 * (g - first))
  of 2:
    var lo = 0
    var hi = f.u16(at + 2) - 1
    while lo <= hi:
      let m = (lo + hi) shr 1
      let r = at + 4 + 6 * m
      if r + 6 > n: return 0
      if g < f.u16(r): hi = m - 1
      elif g > f.u16(r + 2): lo = m + 1
      else: return f.u16(r + 4)
  else: discard
  0

proc valueSize(fmt: int): int {.inline.} = 2 * countSetBits(fmt and 0xFF)

proc xKern(f: Face; at, fmt1, fmt2: int): int =
  ## The horizontal adjustment of a pair's two value records at `at`: the
  ## first glyph's advance, and the second's placement.
  var p = at
  if (fmt1 and 4) != 0:
    result += f.i16(p + 2 * countSetBits(fmt1 and 3))
  p += valueSize(fmt1)
  if (fmt2 and 1) != 0: result += f.i16(p)

proc gposKerning(f: Face; left, right: int): int =
  let n = f.src.bytes.len
  var i = 0
  while i < f.gposPairs.len:
    # (the subtables of one lookup: the first that has the pair applies)
    var done = false
    while i < f.gposPairs.len and f.gposPairs[i] >= 0:
      let st = f.gposPairs[i]
      inc i
      if done: continue
      let cov = f.coverageIndex(st + f.u16(st + 2), left)
      if cov < 0: continue
      let fmt1 = f.u16(st + 4)
      let fmt2 = f.u16(st + 6)
      let recSize = valueSize(fmt1) + valueSize(fmt2)
      if f.u16(st) == 1:
        if cov >= f.u16(st + 8) or st + 10 + 2 * cov + 2 > n: continue
        let ps = st + f.u16(st + 10 + 2 * cov)
        if ps + 2 > n: continue
        var lo = 0
        var hi = f.u16(ps) - 1
        let size = 2 + recSize
        while lo <= hi:
          let m = (lo + hi) shr 1
          let r = ps + 2 + size * m
          if r + size > n: break
          let g2 = f.u16(r)
          if g2 == right:
            result += f.xKern(r + 2, fmt1, fmt2)
            done = true
            break
          if g2 < right: lo = m + 1 else: hi = m - 1
      else:
        let c1 = f.classOf(st + f.u16(st + 8), left)
        let c2 = f.classOf(st + f.u16(st + 10), right)
        let n1 = f.u16(st + 12)
        let n2 = f.u16(st + 14)
        if c1 >= n1 or c2 >= n2: continue
        let r = st + 16 + (c1 * n2 + c2) * recSize
        if r + recSize <= n: result += f.xKern(r, fmt1, fmt2)
        done = true
    inc i                                  # (past the end of the lookup)

proc kerningTable*(f: Face; glyphs: openArray[int]): seq[int] =
  ## The kerning of every pair of `glyphs` (`result[i * glyphs.len + j]`:
  ## `glyphs[i]` then `glyphs[j]`, font units), each as `kerning` gives it:
  ## worked out a subtable at a time -- where each glyph is in its coverage
  ## and its classes found once, not once a pair (the kit's table of the
  ## ASCII pairs of a face: 9,000 pairs).
  let m = glyphs.len
  result = newSeq[int](m * m)
  if f.kern.len > 0:
    for a in 0 ..< m:
      for b in 0 ..< m:
        result[a * m + b] = int(f.kern.getOrDefault((uint32(glyphs[a]) shl 16) or uint32(glyphs[b]), 0))
    return
  if not f.gposRead: f.readGposKern()
  if f.gposPairs.len == 0: return
  let n = f.src.bytes.len
  var done = newSeq[bool](m * m)
  var cov = newSeq[int](m)
  var cls = newSeq[int](m)
  var i = 0
  while i < f.gposPairs.len:
    # (the subtables of one lookup: the first that has the pair applies)
    for d in done.mitems: d = false
    while i < f.gposPairs.len and f.gposPairs[i] >= 0:
      let st = f.gposPairs[i]
      inc i
      var any = false
      for a in 0 ..< m:
        cov[a] = f.coverageIndex(st + f.u16(st + 2), glyphs[a])
        if cov[a] >= 0: any = true
      if not any: continue
      let fmt1 = f.u16(st + 4)
      let fmt2 = f.u16(st + 6)
      let recSize = valueSize(fmt1) + valueSize(fmt2)
      if f.u16(st) == 1:
        let size = 2 + recSize
        for a in 0 ..< m:
          let c = cov[a]
          if c < 0 or c >= f.u16(st + 8) or st + 10 + 2 * c + 2 > n: continue
          let ps = st + f.u16(st + 10 + 2 * c)
          if ps + 2 > n: continue
          let count = f.u16(ps)
          for b in 0 ..< m:
            if done[a * m + b]: continue
            let right = glyphs[b]
            var lo = 0
            var hi = count - 1
            while lo <= hi:
              let mid = (lo + hi) shr 1
              let r = ps + 2 + size * mid
              if r + size > n: break
              let g2 = f.u16(r)
              if g2 == right:
                result[a * m + b] += f.xKern(r + 2, fmt1, fmt2)
                done[a * m + b] = true
                break
              if g2 < right: lo = mid + 1 else: hi = mid - 1
      else:
        let n1 = f.u16(st + 12)
        let n2 = f.u16(st + 14)
        for b in 0 ..< m: cls[b] = f.classOf(st + f.u16(st + 10), glyphs[b])
        for a in 0 ..< m:
          if cov[a] < 0: continue
          let c1 = f.classOf(st + f.u16(st + 8), glyphs[a])
          if c1 >= n1: continue
          for b in 0 ..< m:
            if done[a * m + b] or cls[b] >= n2: continue
            let r = st + 16 + (c1 * n2 + cls[b]) * recSize
            if r + recSize <= n: result[a * m + b] += f.xKern(r, fmt1, fmt2)
            done[a * m + b] = true
    inc i                                  # (past the end of the lookup)

# ---- variable fonts -----------------------------------------------------------------
#
# A variable font (fvar) keeps one outline per glyph and, in gvar, how its
# points move along each axis; HVAR says how the advances change (without
# it, the "phantom" points after the outline carry them); avar bends each
# axis. `variation` makes a Face at given axis values that shares the font's
# bytes: its advance, contours, render and bounds follow those values.

type
  Axis* = object
    ## One axis of a variable font: its tag ("wght"), its name ("Weight")
    ## and its range in design units (400 a regular weight).
    tag*, name*: string       ## "wght", "Weight"
    minV*, defV*, maxV*: float ## its lowest, default and highest values

proc halfUp(x: float32): int =
  ## Rounds as HarfBuzz and fontTools do: halves up (-2.5 to -2).
  int(floor(float64(x) + 0.5))

proc fixed1616(f: Face; i: int): float =
  float(f.s32(i)) / 65536

proc varFont(f: Face): VarFont =
  ## The variation tables, read the first time they are asked for.
  if f.vf != nil: return f.vf
  let v = VarFont(avar: -1, gvar: -1, hvar: -1, hvarStore: -1, hvarAdvMap: -1)
  f.vf = v
  let n = f.src.bytes.len
  let (fv, _) = f.tableRange("fvar")
  if fv >= 0 and fv + 16 <= n:
    let axesAt = fv + f.u16(fv + 4)
    let count = f.u16(fv + 8)
    let size = f.u16(fv + 10)
    let icount = f.u16(fv + 12)
    let isize = f.u16(fv + 14)
    if size >= 20:
      for i in 0 ..< count:
        let r = axesAt + i * size
        if r + 20 > n: break
        v.axes.add VarAxis(tag: f.src.bytes[r ..< r + 4], minV: f.fixed1616(r + 4),
                           defV: f.fixed1616(r + 8), maxV: f.fixed1616(r + 12),
                           nameId: f.u16(r + 18))
      if isize >= 4 + 4 * v.axes.len:
        for i in 0 ..< icount:
          let r = axesAt + count * size + i * isize
          if r + isize > n: break
          var c: seq[float]
          for k in 0 ..< v.axes.len: c.add f.fixed1616(r + 4 + 4 * k)
          v.named.add (f.u16(r), c)
  if v.axes.len == 0: return v
  let (av, _) = f.tableRange("avar")
  if av >= 0 and av + 8 <= n and f.u16(av) == 1: v.avar = av
  let (gv, _) = f.tableRange("gvar")
  if gv >= 0 and gv + 20 <= n and f.u16(gv + 4) == v.axes.len:
    v.gvar = gv
    let sharedCount = f.u16(gv + 6)
    let sharedAt = gv + f.u32(gv + 8)
    v.gvarLong = (f.u16(gv + 14) and 1) != 0
    v.gvarData = gv + f.u32(gv + 16)
    v.gvarOffsets = gv + 20
    for i in 0 ..< sharedCount:
      var t: seq[int]
      for k in 0 ..< v.axes.len:
        let at = sharedAt + 2 * (i * v.axes.len + k)
        t.add (if at + 2 <= n: f.i16(at) else: 0)
      v.shared.add t
  let (hv, _) = f.tableRange("HVAR")
  if hv >= 0 and hv + 20 <= n and f.u16(hv) == 1:
    v.hvar = hv
    if f.u32(hv + 4) != 0: v.hvarStore = hv + f.u32(hv + 4)
    if f.u32(hv + 8) != 0: v.hvarAdvMap = hv + f.u32(hv + 8)
  v

proc axes*(f: Face): seq[Axis] =
  ## The axes of a variable font (empty for other fonts).
  for a in f.varFont.axes:
    result.add Axis(tag: a.tag, name: f.fontName(a.nameId), minV: a.minV, defV: a.defV,
                    maxV: a.maxV)

proc instances*(f: Face): seq[tuple[name: string; coords: seq[(string, float)]]] =
  ## The named instances of a variable font ("Bold", "Condensed Light"...)
  ## with their axis values.
  let v = f.varFont
  for ins in v.named:
    var c: seq[(string, float)]
    for k, a in v.axes: c.add (a.tag, ins.coords[k])
    result.add (f.fontName(ins.nameId), c)

proc avarMap(f: Face; at: int; count: int; value: float32): float32 =
  ## One axis's avar segment map (as HarfBuzz reads it, with its error recovery).
  if count < 2:
    if count == 0: return value
    return value - float32(f.i16(at)) / 16384 + float32(f.i16(at + 2)) / 16384
  template fromC(i: int): float32 = float32(f.i16(at + 4 * i)) / 16384
  template toC(i: int): float32 = float32(f.i16(at + 4 * i + 2)) / 16384
  var start = 0
  var stop = count
  if fromC(start) == -1 and toC(start) == -1 and fromC(start + 1) == -1: inc start
  if fromC(stop - 1) == 1 and toC(stop - 1) == 1 and fromC(stop - 2) == 1: dec stop
  var i = start
  while i < stop and value != fromC(i): inc i
  if i < stop:
    var j = i
    while j + 1 < stop and value == fromC(j + 1): inc j
    if i == j: return toC(i)
    if i + 2 == j: return toC(i + 1)
    if value < 0: return toC(j)
    if value > 0: return toC(i)
    return (if abs(toC(i)) < abs(toC(j)): toC(i) else: toC(j))
  i = start
  while i < stop and not (value < fromC(i)): inc i
  if i == start: return value - fromC(start) + toC(start)
  if i == stop: return value - fromC(stop - 1) + toC(stop - 1)
  let denom = fromC(i) - fromC(i - 1)
  toC(i - 1) + ((toC(i) - toC(i - 1)) * (value - fromC(i - 1))) / denom

proc normalized(f: Face; coords: openArray[(string, float)]): seq[int] =
  ## Axis values in design units as normalized 2.14 values (avar applied).
  let v = f.varFont
  result = newSeq[int](v.axes.len)
  for (tag, value) in coords:
    for k, a in v.axes:
      if a.tag != tag: continue
      let lo = float32(min(a.defV, a.minV))
      let hi = float32(max(a.defV, a.maxV))
      let d = float32(a.defV)
      let x = clamp(float32(value), lo, hi)
      var t = 0'f32
      if x < d: t = (x - d) / (d - lo)
      elif x > d: t = (x - d) / (hi - d)
      result[k] = halfUp(t * 65536'f32)
      break
  if v.avar >= 0:
    var p = v.avar + 8
    let n = f.src.bytes.len
    for k in 0 ..< min(f.u16(v.avar + 6), v.axes.len):
      if p + 2 > n: break
      let count = f.u16(p)
      if p + 2 + 4 * count > n: break
      let m = f.avarMap(p + 2, count, float32(result[k]) / 65536'f32)
      result[k] = halfUp(m * 65536'f32)
      p += 2 + 4 * count
  for k in 0 ..< result.len: result[k] = (result[k] + 2) shr 2

proc varCoords*(f: Face): lent seq[int] =
  ## This face's normalized axis values (2.14 fixed point, as OpenType
  ## layout tables compare them); empty for a font's default instance.
  f.coords

proc regionScalar(f: Face; list, region: int; coords: openArray[int]): float32 =
  ## How much of a variation region (of an item variation store) applies.
  let axisCount = f.u16(list)
  if region >= f.u16(list + 2): return 0
  result = 1
  for k in 0 ..< axisCount:
    let at = list + 4 + 6 * (region * axisCount + k)
    if at + 6 > f.src.bytes.len: return 0
    let start = f.i16(at)
    let peak = f.i16(at + 2)
    let stop = f.i16(at + 4)
    let c = if k < coords.len: coords[k] else: 0
    if peak == 0 or c == peak: continue
    if c == 0: return 0
    if start > peak or peak > stop: continue
    if start < 0 and stop > 0: continue
    if c <= start or stop <= c: return 0
    if c < peak: result *= float32(c - start) / float32(peak - start)
    else: result *= float32(stop - c) / float32(stop - peak)

proc varStoreDelta*(f: Face; store, outer, inner: int): float32 =
  ## The delta an item variation store (at `store` in `fontBytes`, as GDEF's
  ## or HVAR's) gives item (`outer`, `inner`) at this face's axis values;
  ## 0 at the default instance.
  if f.coords.len == 0 or store < 0: return 0
  let n = f.src.bytes.len
  if store + 8 > n or outer >= f.u16(store + 6) or store + 12 + 4 * outer > n: return 0
  let list = store + f.u32(store + 2)
  let data = store + f.u32(store + 8 + 4 * outer)
  if data + 6 > n or list + 4 > n: return 0
  let itemCount = f.u16(data)
  let wordField = f.u16(data + 2)
  let longWords = (wordField and 0x8000) != 0
  let words = wordField and 0x7FFF
  let regions = f.u16(data + 4)
  if inner >= itemCount: return 0
  let rowSize = (if longWords: 4 * words + 2 * (regions - words) else: 2 * words + (regions - words))
  var p = data + 6 + 2 * regions + inner * rowSize
  if p + rowSize > n: return 0
  for i in 0 ..< regions:
    var d: int
    if i < words:
      if longWords:
        d = f.s32(p); p += 4
      else:
        d = f.i16(p); p += 2
    else:
      if longWords:
        d = f.i16(p); p += 2
      else:
        d = int(cast[int8](uint8(f.u8(p)))); p += 1
    if d == 0: continue
    let s = f.regionScalar(list, f.u16(data + 6 + 2 * i), f.coords)
    if s != 0: result += s * float32(d)

proc tupleScalar(f: Face; v: VarFont; peak, start, stop: seq[int]; inter: bool): float32 =
  ## How much of a gvar tuple applies at this face's axis values.
  result = 1
  for k in 0 ..< v.axes.len:
    let c = if k < f.coords.len: f.coords[k] else: 0
    let p = peak[k]
    if p == 0 or c == p: continue
    if inter:
      let s = start[k]
      let e = stop[k]
      if s > p or p > e or (s < 0 and e > 0): continue
      if c < s or c > e: return 0
      if c < p:
        if p != s: result *= float32(c - s) / float32(p - s)
      else:
        if p != e: result *= float32(e - c) / float32(e - p)
    elif c == 0 or c < min(0, p) or c > max(0, p): return 0
    else: result *= float32(c) / float32(p)

proc readPoints(f: Face; p: var int; stop: int): seq[int] =
  ## Packed point numbers of gvar; empty: all the points.
  if p >= stop: return
  var count = f.u8(p)
  inc p
  if (count and 0x80) != 0:
    if p >= stop: return
    count = ((count and 0x7F) shl 8) or f.u8(p)
    inc p
  var last = 0
  while result.len < count and p < stop:
    let c = f.u8(p)
    inc p
    let run = (c and 0x7F) + 1
    for _ in 0 ..< run:
      if result.len >= count: break
      if (c and 0x80) != 0:
        if p + 2 > stop: return
        last += f.u16(p); p += 2
      else:
        if p >= stop: return
        last += f.u8(p); inc p
      result.add last

proc readDeltas(f: Face; p: var int; stop, count: int): seq[int] =
  ## Packed deltas of gvar.
  result = newSeq[int](count)
  var i = 0
  while i < count and p < stop:
    let c = f.u8(p)
    inc p
    let run = (c and 0x3F) + 1
    for _ in 0 ..< run:
      if i >= count: break
      case c and 0xC0
      of 0x80: result[i] = 0
      of 0x40:
        if p + 2 > stop: return
        result[i] = f.i16(p); p += 2
      of 0xC0:
        if p + 4 > stop: return
        result[i] = f.s32(p); p += 4
      else:
        if p >= stop: return
        result[i] = int(cast[int8](uint8(f.u8(p)))); inc p
      inc i

proc inferDelta(t, a, b, da, db: float32): float32 =
  ## A point's delta between two moved points (gvar's interpolation, IUP).
  if a == b: return (if da == db: da else: 0)
  if t <= min(a, b): return (if a < b: da else: db)
  if t >= max(a, b): return (if a > b: da else: db)
  da + (t - a) / (b - a) * (db - da)

proc applyGvar(f: Face; g: int; pts: var seq[(float32, float32)]; ends: seq[int]) =
  ## Moves the points of glyph `g` (its outline's or components', then the
  ## four phantom points) as gvar says for this face's axis values.
  ## `ends`: the index after each contour's last point (simple glyphs).
  let v = f.varFont
  if v.gvar < 0 or g >= f.numGlyphs: return
  let n = f.src.bytes.len
  if v.gvarOffsets + (if v.gvarLong: 4 else: 2) * (g + 2) > n: return
  let o0 = if v.gvarLong: f.u32(v.gvarOffsets + 4 * g) else: 2 * f.u16(v.gvarOffsets + 2 * g)
  let o1 = if v.gvarLong: f.u32(v.gvarOffsets + 4 * g + 4) else: 2 * f.u16(v.gvarOffsets + 2 * g + 2)
  if o1 <= o0: return
  let base = v.gvarData + o0
  let stop = min(n, v.gvarData + o1)
  if base + 4 > stop: return
  let count = pts.len
  let orig = pts
  let tuples = f.u16(base)
  var data = base + f.u16(base + 2)
  var shared: seq[int]
  if (tuples and 0x8000) != 0: shared = f.readPoints(data, stop)
  var h = base + 4
  let axisN = v.axes.len
  var peak, start, finish = newSeq[int](axisN)
  for _ in 0 ..< (tuples and 0x0FFF):
    if h + 4 > stop: return
    let size = f.u16(h)
    let index = f.u16(h + 2)
    h += 4
    if (index and 0x8000) != 0:
      if h + 2 * axisN > stop: return
      for k in 0 ..< axisN: peak[k] = f.i16(h + 2 * k)
      h += 2 * axisN
    else:
      let s = index and 0x0FFF
      if s >= v.shared.len: return
      peak = v.shared[s]
    let inter = (index and 0x4000) != 0
    if inter:
      if h + 4 * axisN > stop: return
      for k in 0 ..< axisN:
        start[k] = f.i16(h + 2 * k)
        finish[k] = f.i16(h + 2 * axisN + 2 * k)
      h += 4 * axisN
    let here = data
    data += size
    let scalar = f.tupleScalar(v, peak, start, finish, inter)
    if scalar == 0: continue
    var p = here
    let tupleEnd = min(stop, here + size)
    let points = if (index and 0x2000) != 0: f.readPoints(p, tupleEnd) else: shared
    let all = points.len == 0
    let m = if all: count else: points.len
    let dx = f.readDeltas(p, tupleEnd, m)
    let dy = f.readDeltas(p, tupleEnd, m)
    if all:
      for i in 0 ..< count:
        pts[i][0] += float32(dx[i]) * scalar
        pts[i][1] += float32(dy[i]) * scalar
      continue
    var d = newSeq[(float32, float32)](count)
    var touched = newSeq[bool](count)
    for i in 0 ..< m:
      let k = points[i]
      if k >= count: continue
      touched[k] = true
      d[k][0] += float32(dx[i]) * scalar
      d[k][1] += float32(dy[i]) * scalar
    # the points no delta names follow the ones around them on their contour
    var s = 0
    for e in ends:
      if e > count or e <= s: break
      var refs: seq[int]
      for i in s ..< e:
        if touched[i]: refs.add i
      if refs.len > 0 and refs.len < e - s:
        for r in 0 ..< refs.len:
          let a = refs[r]
          let b = refs[(r + 1) mod refs.len]
          var i = a + 1
          if i >= e: i = s
          while i != b:
            for ax in 0 .. 1:
              let t = if ax == 0: orig[i][0] else: orig[i][1]
              let ca = if ax == 0: orig[a][0] else: orig[a][1]
              let cb = if ax == 0: orig[b][0] else: orig[b][1]
              let da = if ax == 0: d[a][0] else: d[a][1]
              let db = if ax == 0: d[b][0] else: d[b][1]
              let x = inferDelta(t, ca, cb, da, db)
              if ax == 0: d[i][0] = x else: d[i][1] = x
            inc i
            if i >= e: i = s
      s = e
    for i in 0 ..< count:
      pts[i][0] += d[i][0]
      pts[i][1] += d[i][1]

proc varGlyph(f: Face; g, depth: int; o: var Outline; ph, ph0: var array[4, (float32, float32)]) =
  ## Glyph `g`'s points at this face's axis values, in its own units
  ## (components placed), and its four phantom points (`ph0`: where they
  ## are at the default).
  let (a, b) = f.glyphSpan(g)
  var adv = 0
  var lsb = 0
  if f.numHMetrics > 0:
    let i = if g < f.numHMetrics: g else: f.numHMetrics - 1
    adv = f.u16(f.hmtx + 4 * i)
    let at = if g < f.numHMetrics: f.hmtx + 4 * g + 2
             else: f.hmtx + 4 * f.numHMetrics + 2 * (g - f.numHMetrics)
    if at + 2 <= f.src.bytes.len: lsb = f.i16(at)
  let xMin = if b - a >= 10: f.i16(a + 2) else: 0
  let x0 = float32(xMin - lsb)
  ph = [(x0, 0'f32), (x0 + float32(adv), 0'f32), (0'f32, 0'f32), (0'f32, 0'f32)]
  ph0 = ph
  if b - a < 10 or depth > 8:
    var pts = @[ph[0], ph[1], ph[2], ph[3]]
    f.applyGvar(g, pts, @[])
    for k in 0 .. 3: ph[k] = pts[k]
    return
  let n = f.i16(a)
  if n >= 0:
    var tmp: Outline
    f.readOutline(g, tmp, 1)            # (depth 1: the plain points)
    var pts = newSeq[(float32, float32)](tmp.pts.len + 4)
    for i, p in tmp.pts: pts[i] = (p.x, p.y)
    for k in 0 .. 3: pts[tmp.pts.len + k] = ph[k]
    f.applyGvar(g, pts, tmp.ends)
    let base = o.pts.len
    for i, p in tmp.pts:
      o.pts.add Point(x: pts[i][0], y: pts[i][1], on: p.on)
    for e in tmp.ends: o.ends.add base + e
    for k in 0 .. 3: ph[k] = pts[tmp.pts.len + k]
  else:
    type Comp = object
      glyph, flags: int
      dx, dy: float32
      c: array[4, float32]
    var comps: seq[Comp]
    var p = a + 10
    while p + 4 <= b:
      var c = Comp(flags: f.u16(p), glyph: f.u16(p + 2), c: [1'f32, 0, 0, 1])
      p += 4
      if (c.flags and 1) != 0:
        c.dx = float32(f.i16(p)); c.dy = float32(f.i16(p + 2)); p += 4
      else:
        c.dx = float32(cast[int8](f.u8(p))); c.dy = float32(cast[int8](f.u8(p + 1))); p += 2
      if (c.flags and 2) == 0: c.dx = 0; c.dy = 0
      template f2d14(i: int): float32 = float32(f.i16(i)) / 16384'f32
      if (c.flags and 8) != 0:
        c.c[0] = f2d14(p); c.c[3] = c.c[0]; p += 2
      elif (c.flags and 0x40) != 0:
        c.c[0] = f2d14(p); c.c[3] = f2d14(p + 2); p += 4
      elif (c.flags and 0x80) != 0:
        c.c[0] = f2d14(p); c.c[1] = f2d14(p + 2); c.c[2] = f2d14(p + 4); c.c[3] = f2d14(p + 6)
        p += 8
      comps.add c
      if (c.flags and 0x20) == 0: break
    var pts = newSeq[(float32, float32)](comps.len + 4)
    for i, c in comps: pts[i] = (c.dx, c.dy)
    for k in 0 .. 3: pts[comps.len + k] = ph[k]
    f.applyGvar(g, pts, @[])
    for k in 0 .. 3: ph[k] = pts[comps.len + k]
    for i, c in comps:
      var child: Outline
      var cph, cph0: array[4, (float32, float32)]
      f.varGlyph(c.glyph, depth + 1, child, cph, cph0)
      let (tx, ty) = if (c.flags and 2) != 0: pts[i] else: (0'f32, 0'f32)
      let base = o.pts.len
      for q in child.pts:
        o.pts.add Point(x: c.c[0] * q.x + c.c[2] * q.y + tx,
                        y: c.c[1] * q.x + c.c[3] * q.y + ty, on: q.on)
      for e in child.ends: o.ends.add base + e
      if (c.flags and 0x200) != 0:     # USE_MY_METRICS: the component's (untransformed)
        ph = cph
        ph0 = cph0

proc varOutline(f: Face; g: int; o: var Outline; m: array[6, float32]) =
  ## Glyph `g`'s contours at this face's axis values, moved left as much
  ## as the variation moved its left phantom point, transformed by `m`.
  var mine: Outline
  var ph, ph0: array[4, (float32, float32)]
  f.varGlyph(g, 0, mine, ph, ph0)
  let shift = ph0[0][0] - ph[0][0]
  let base = o.pts.len
  for p in mine.pts:
    let x = p.x + shift
    o.pts.add Point(x: m[0] * x + m[2] * p.y + m[4], y: m[1] * x + m[3] * p.y + m[5], on: p.on)
  for e in mine.ends: o.ends.add base + e

proc varAdvance(f: Face; g: int): int =
  ## Glyph `g`'s advance at this face's axis values: HVAR's, else the
  ## distance between its moved phantom points.
  if g < 0 or g >= f.numGlyphs or f.numHMetrics == 0: return 0
  if f.advs.len != f.numGlyphs:
    f.advs = newSeq[int32](f.numGlyphs)
    for x in f.advs.mitems: x = -1
  if f.advs[g] >= 0: return int(f.advs[g])
  let i = if g < f.numHMetrics: g else: f.numHMetrics - 1
  let plain = f.u16(f.hmtx + 4 * i)
  let v = f.varFont
  var r: int
  if v.hvar >= 0:
    var outer = 0
    var inner = g
    let m = v.hvarAdvMap
    if m >= 0 and m + 6 <= f.src.bytes.len:
      let fmt = f.u8(m)
      let entry = f.u8(m + 1)
      let count = if fmt == 0: f.u16(m + 2) else: f.u32(m + 2)
      let at = m + (if fmt == 0: 4 else: 6)
      let size = ((entry shr 4) and 3) + 1
      let innerBits = (entry and 0xF) + 1
      if count > 0:
        let k = min(g, count - 1)
        var x = 0
        for j in 0 ..< size:
          if at + k * size + j < f.src.bytes.len: x = (x shl 8) or f.u8(at + k * size + j)
        outer = x shr innerBits
        inner = x and ((1 shl innerBits) - 1)
    r = plain + halfUp(f.varStoreDelta(v.hvarStore, outer, inner))
  elif v.gvar >= 0:
    var o: Outline
    var ph, ph0: array[4, (float32, float32)]
    f.varGlyph(g, 0, o, ph, ph0)
    r = halfUp(ph[1][0] - ph[0][0])
  else: r = plain
  r = max(0, r)
  f.advs[g] = int32(r)
  r

proc varBounds(f: Face; g: int): tuple[x0, y0, x1, y1: int] =
  ## Glyph `g`'s bounding box at this face's axis values.
  var o: Outline
  f.varOutline(g, o, [1'f32, 0, 0, 1, 0, 0])
  if o.pts.len == 0: return
  var x0, y0 = 1e9'f32
  var x1, y1 = -1e9'f32
  for p in o.pts:
    x0 = min(x0, p.x); x1 = max(x1, p.x)
    y0 = min(y0, p.y); y1 = max(y1, p.y)
  (halfUp(x0), halfUp(y0), halfUp(x1), halfUp(y1))

proc variation*(f: Face; coords: openArray[(string, float)]): Face =
  ## The face at the axis values `coords` (("wght", 700.0), ("wdth", 75.0)...;
  ## axes not named keep their default): it shares this face's font data,
  ## its advances and outlines follow those values, and it is kept, so asking
  ## again for the same values gives the same Face. This face is unchanged.
  ## A font that is not variable gives itself.
  let v = f.varFont
  if v.axes.len == 0: return f
  let c = f.normalized(coords)
  var plain = true
  for x in c:
    if x != 0: plain = false
  if plain and f.coords.len == 0: return f
  for m in v.made:
    if m.coords == c: return m.face
  result = Face()
  result[] = f[]
  result.coords = if plain: @[] else: c
  result.advs = @[]
  result.clockwise = 0
  result.stem = -1
  result.findZones()
  v.made.add (c, result)
  if v.made.len > 16: v.made.delete(0)

# ---- rasterizing --------------------------------------------------------------------

proc hintMap(f: Face; s: float32): seq[tuple[lo, hi, t: float32]] =
  ## The alignment zones at scale `s`, each with the pixel row it snaps to.
  for z in f.zones:
    var t = round(z.lo * s)
    if result.len > 0 and t <= result[^1].t: t = result[^1].t + 1
    result.add (z.lo, z.hi, t)

proc mapY(zs: seq[tuple[lo, hi, t: float32]]; y, s: float32): float32 =
  if zs.len == 0: return y * s
  if y < zs[0].lo: return zs[0].t + (y - zs[0].lo) * s
  for i, z in zs:
    if y <= z.hi: return z.t
    if i + 1 < zs.len and y < zs[i+1].lo:
      let n = zs[i+1]
      return z.t + (y - z.hi) / (n.lo - z.hi) * (n.t - z.t)
  zs[^1].t + (y - zs[^1].hi) * s

proc contours*(f: Face; g: int; steps = 6): seq[seq[(float32, float32)]] =
  ## The outline of glyph `g` as closed polygons, in font units (y up),
  ## each curve cut into `steps` straight pieces: to transform (warp, set
  ## along a path) and fill.
  var o: Outline
  f.readOutline(g, o)
  var start = 0
  for e in o.ends:
    let n = e - start
    if n >= 2 and e <= o.pts.len:
      template P(i: int): Point = o.pts[start + i]
      var poly: seq[(float32, float32)]
      var first: Point
      var k0 = 0
      var k1 = n
      if P(0).on:
        first = P(0); k0 = 1
      elif P(n - 1).on:
        first = P(n - 1); k1 = n - 1
      else:
        first = Point(x: (P(0).x + P(n-1).x) / 2, y: (P(0).y + P(n-1).y) / 2, on: true)
      poly.add (first.x, first.y)
      var cx = first.x
      var cy = first.y
      var ctrl: Point
      var hasCtrl = false
      template quadTo(qx, qy, ex, ey: float32) =
        for k in 1 .. steps:
          let t = float32(k) / float32(steps)
          let u = 1 - t
          poly.add (u * u * cx + 2 * u * t * qx + t * t * ex, u * u * cy + 2 * u * t * qy + t * t * ey)
      for k in k0 ..< k1:
        let p = P(k)
        if p.on:
          if hasCtrl:
            quadTo(ctrl.x, ctrl.y, p.x, p.y)
            hasCtrl = false
          else:
            poly.add (p.x, p.y)
          cx = p.x
          cy = p.y
        else:
          if hasCtrl:
            let mx = (ctrl.x + p.x) / 2
            let my = (ctrl.y + p.y) / 2
            quadTo(ctrl.x, ctrl.y, mx, my)
            cx = mx
            cy = my
          ctrl = p
          hasCtrl = true
      if hasCtrl: quadTo(ctrl.x, ctrl.y, first.x, first.y)
      result.add poly
    start = e

# ---- fitting stems to the pixels (small sizes) ------------------------------------------
#
# A light autohinter: the straight upright and level strokes of a glyph --
# the stems of n, l, H, alef, the bars of e, t and of the joined Arabic
# letters -- are made a whole number of pixels thick and set on the pixel
# grid, the rest of the outline stretched between them. Text then stays
# crisp at the small sizes of a 1x screen (and at fractional scales); big
# text needs none.

type Edge = object
  at, lo, hi: float32          # where (x of an upright edge, y of a level one); its extent
  side: int8                   # 1: the filled side is after it (a left or bottom edge), -1 before

proc orientation(f: Face): int8 =
  ## Which side of its contours a face fills (from the outline of "o").
  if f.clockwise != 0: return f.clockwise
  f.clockwise = 1
  var o: Outline
  f.readOutline(f.glyphOf(ord('o')), o)
  if o.ends.len > 0:
    # the biggest contour: the outer one
    var best = 0.0'f32
    var start = 0
    for e in o.ends:
      var a = 0'f32
      for i in start ..< e:
        let p = o.pts[i]
        let q = o.pts[if i + 1 < e: i + 1 else: start]
        a += p.x * q.y - q.x * p.y
      if abs(a) > abs(best): best = a
      start = e
    if best > 0: f.clockwise = -1       # (counterclockwise outer contours: PostScript's way)
  f.clockwise

proc edgesOf(o: Outline; upright: bool; minLen: float32; turn: int8): seq[Edge] =
  ## The straight upright (or level) pieces of the outline between its
  ## on-curve points, as edges of filled regions.
  var start = 0
  for e in o.ends:
    for i in start ..< e:
      let p = o.pts[i]
      let q = o.pts[if i + 1 < e: i + 1 else: start]
      if not (p.on and q.on): continue
      let along = if upright: q.y - p.y else: q.x - p.x
      let across = if upright: q.x - p.x else: q.y - p.y
      if abs(along) < minLen or abs(across) > max(2'f32, 0.06'f32 * abs(along)): continue
      # (filled to the right of the travel, TrueType's way: going up is a
      # left edge, going right a top edge)
      var side: int8 = if upright: (if along > 0: 1 else: -1) else: (if along > 0: -1 else: 1)
      side = side * turn
      let at = if upright: (p.x + q.x) / 2 else: (p.y + q.y) / 2
      let a = if upright: min(p.y, q.y) else: min(p.x, q.x)
      let b = if upright: max(p.y, q.y) else: max(p.x, q.x)
      var merged = false
      for ed in result.mitems:
        if ed.side == side and abs(ed.at - at) <= 3 and a <= ed.hi + 20 and b >= ed.lo - 20:
          ed.lo = min(ed.lo, a)
          ed.hi = max(ed.hi, b)
          merged = true
          break
      if not merged: result.add Edge(at: at, lo: a, hi: b, side: side)
    start = e

proc stemAnchors(edges: seq[Edge]; maxW: float32; toPx: proc (v: float32): float32;
                 bold: bool): seq[(float32, float32)] =
  ## Pairs of edges (a stem's two sides) and where each lands: its sides
  ## on whole pixels, its width a whole number of them. (In the units of
  ## `toPx`'s result: device pixels.)
  var used = newSeq[bool](edges.len)
  var pairs: seq[(float32, int, int)]
  for i, a in edges:
    if a.side != 1: continue
    for j, b in edges:
      if b.side != -1 or b.at <= a.at or b.at - a.at > maxW: continue
      let overlap = min(a.hi, b.hi) - max(a.lo, b.lo)
      if overlap < 0.3'f32 * min(a.hi - a.lo, b.hi - b.lo): continue
      pairs.add (b.at - a.at, i, j)
  pairs.sort(proc (x, y: (float32, int, int)): int = cmp(x[0], y[0]))
  for (_, i, j) in pairs:
    if used[i] or used[j]: continue
    used[i] = true
    used[j] = true
    let p0 = toPx(edges[i].at)
    let p1 = toPx(edges[j].at)
    let w = p1 - p0
    let wp = if bold: max(1'f32, floor(w + 0.75'f32)) else: max(1'f32, round(w))
    # (an edge already on a pixel stays there; else the stem keeps its middle)
    var lo: float32
    if abs(p0 - round(p0)) < 0.08'f32: lo = round(p0)
    elif abs(p1 - round(p1)) < 0.08'f32: lo = round(p1) - wp
    else: lo = round((p0 + p1) / 2 - wp / 2)
    result.add (p0, lo)
    result.add (p1, lo + wp)
  result.sort(proc (x, y: (float32, float32)): int = cmp(x[0], y[0]))
  # (in order, never crossing: what would cross is left as it is)
  var kept: seq[(float32, float32)]
  for a in result:
    if kept.len > 0 and (a[1] <= kept[^1][1] and a[0] > kept[^1][0] + 0.01'f32): continue
    if kept.len > 0 and a[0] - kept[^1][0] < 0.01'f32: continue
    kept.add a
  kept

proc withZones(anchors: seq[(float32, float32)]; zs: seq[tuple[lo, hi, t: float32]]): seq[(float32, float32)] =
  ## The stems' anchors with the alignment zones' rows held where they are
  ## (the baseline, x-height, cap height): a bar set on its pixels moves
  ## what is between it and the next zone, never the zone itself -- an H's
  ## top stays on the cap height when its bar moves. A stem that would
  ## cross a zone gives way.
  var all: seq[tuple[src, dst: float32; zone: bool]]
  for a in anchors: all.add (a[0], a[1], false)
  for z in zs: all.add (z.t, z.t, true)
  all.sort(proc (x, y: tuple[src, dst: float32; zone: bool]): int =
    result = cmp(x.src, y.src)
    if result == 0: result = cmp(ord(y.zone), ord(x.zone)))
  var kept: seq[tuple[src, dst: float32; zone: bool]]
  for a in all:
    if kept.len > 0 and a.src - kept[^1].src < 0.01'f32: continue      # (the same point: the zone's)
    var ok = true
    while kept.len > 0 and a.dst <= kept[^1].dst:
      # (out of order: a stem gives way to a zone)
      if a.zone and not kept[^1].zone: kept.setLen(kept.len - 1)
      else:
        ok = false
        break
    if ok: kept.add a
  for k in kept: result.add (k.src, k.dst)

proc fit(anchors: seq[(float32, float32)]; v: float32): float32 =
  ## A coordinate (device pixels) moved as the anchors around it are.
  if anchors.len == 0: return v
  if v <= anchors[0][0]: return v + anchors[0][1] - anchors[0][0]
  for k in 1 ..< anchors.len:
    let b = anchors[k]
    if v <= b[0]:
      let a = anchors[k - 1]
      return a[1] + (v - a[0]) / (b[0] - a[0]) * (b[1] - a[1])
  v + anchors[^1][1] - anchors[^1][0]

proc offsetOutline(o: var Outline; h, dx: float32; turn: int8) =
  ## Every contour moved out by `h` (font units; in, when it is less than
  ## 0) along its normals, as FreeType emboldens an outline, then `dx` to
  ## the right.
  var start = 0
  var moved = newSeq[Point](o.pts.len)
  for e in o.ends:
    let n = e - start
    if n >= 3 and e <= o.pts.len:
      for i in 0 ..< n:
        let p = o.pts[start + i]
        # (the neighbors that are somewhere else)
        var a = (i + n - 1) mod n
        var k = 0
        while k < n and abs(o.pts[start + a].x - p.x) + abs(o.pts[start + a].y - p.y) < 0.01:
          a = (a + n - 1) mod n
          inc k
        var b = (i + 1) mod n
        k = 0
        while k < n and abs(o.pts[start + b].x - p.x) + abs(o.pts[start + b].y - p.y) < 0.01:
          b = (b + 1) mod n
          inc k
        let p0 = o.pts[start + a]
        let p1 = o.pts[start + b]
        var ax = p.x - p0.x
        var ay = p.y - p0.y
        var bx = p1.x - p.x
        var by = p1.y - p.y
        let la = sqrt(ax * ax + ay * ay)
        let lb = sqrt(bx * bx + by * by)
        moved[start + i] = p
        if la < 1e-3 or lb < 1e-3: continue
        ax /= la; ay /= la; bx /= lb; by /= lb
        # (outward: the left of the way a TrueType contour goes, its filled
        # side being the right)
        let s = float32(turn)
        let n0x = -ay * s
        let n0y = ax * s
        let n1x = -by * s
        let n1y = bx * s
        let d = 1 + n0x * n1x + n0y * n1y
        var vx, vy: float32
        if d < 0.2:                       # (a sharp turn back: not too far)
          vx = (n0x + n1x) * h / 0.2
          vy = (n0y + n1y) * h / 0.2
        else:
          vx = (n0x + n1x) * h / d
          vy = (n0y + n1y) * h / d
        moved[start + i].x = p.x + vx + dx
        moved[start + i].y = p.y + vy
    else:
      for i in 0 ..< n: moved[start + i] = o.pts[start + i]
    start = e
  for i in 0 ..< min(moved.len, o.pts.len):
    o.pts[i].x = moved[i].x
    o.pts[i].y = moved[i].y

proc stemWidth*(f: Face): int =
  ## The width of the face's upright stems (of "l", else "I"), in font
  ## units; 0 when it has none (an italic, a script).
  if f.stem >= 0: return f.stem
  f.stem = 0
  for c in [ord('l'), ord('I'), ord('i')]:
    let g = f.glyphOf(c)
    if g == 0: continue
    var o: Outline
    f.readOutline(g, o)
    let edges = edgesOf(o, true, 0.12'f32 * float32(f.unitsPerEm), f.orientation())
    var best = high(int)
    for a in edges:
      if a.side != 1: continue
      for b in edges:
        if b.side == -1 and b.at > a.at: best = min(best, int(round(b.at - a.at)))
    if best < high(int) and best < f.unitsPerEm div 3:
      f.stem = best
      return best

proc darkening*(f: Face; size: float32): float32 =
  ## How much thicker (pixels) a thin face's strokes are drawn at a small
  ## size, so that they are as dark as a pixel (FreeMono's are half one at
  ## 12 pixels to the em): what its stems lack of a whole pixel, at most
  ## 0.6, none from 26 pixels to the em.
  if size >= 26: return 0
  let w = float32(f.stemWidth) * size / float32(f.unitsPerEm)
  if w <= 0: return 0
  clamp(0.95'f32 - w, 0, 0.6)

proc render*(f: Face; g: int; size: float32; dx = 0'f32; shear = 0'f32;
             embolden = 0'f32; hint = true; fitStems = false; bold = false;
             grid = 0; darken = 0'f32; xScale = 1'f32): Mask =
  ## Glyph `g` at `size` pixels per em, moved right by `dx` (a fraction of
  ## a pixel), slanted by `shear` (0.2 for italic), made bold by `embolden`
  ## pixels (its outline that much wider, to the right: as FreeType makes a
  ## style a font lacks). `hint` aligns the main heights to whole pixels at
  ## small sizes; `fitStems` (small sizes, upright text) also sets its
  ## straight strokes on the pixels, a whole number thick (`bold`: rounded
  ## up sooner). `darken` (pixels, see `darkening`) thickens a thin face's
  ## strokes all round. `grid` (a pixel font's pixels per em) puts every
  ## point on that grid first: at a multiple of it, every edge is a pixel's.
  ## `xScale` widens it (3: a column per color strip of the screen; `dx`
  ## is then in those columns).
  var o: Outline
  f.readOutline(g, o)
  if o.pts.len == 0: return
  if embolden > 0 or darken > 0:
    let u = float32(f.unitsPerEm) / size
    o.offsetOutline((embolden + darken) / 2 * u, embolden / 2 * u, f.orientation())
  if grid > 0:
    let cell = float32(f.unitsPerEm) / float32(grid)
    for p in o.pts.mitems:
      p.x = round(p.x / cell) * cell
      p.y = round(p.y / cell) * cell
  let s = size / float32(f.unitsPerEm)
  let sx = s * xScale
  let zs = if hint and size < 26 and f.zones.len > 0: f.hintMap(s) else: @[]
  var xs, ys: seq[(float32, float32)]
  if fitStems and size < 30 and shear == 0:
    let turn = f.orientation()
    let em = float32(f.unitsPerEm)
    let maxW = 0.24'f32 * em
    let xEdges = edgesOf(o, true, 0.12'f32 * em, turn)
    # (stems on whole pixels in the strips too: a stem is one dark column,
    # the strips sharpen the curves and slants)
    xs = stemAnchors(xEdges, maxW, proc (v: float32): float32 = v * s + dx / xScale, bold)
    if xScale != 1:
      for a in xs.mitems: a = (a[0] * xScale, a[1] * xScale)
    let yEdges = edgesOf(o, false, 0.10'f32 * em, turn)
    ys = stemAnchors(yEdges, maxW, proc (v: float32): float32 = zs.mapY(v, s), bold)
    if zs.len > 0: ys = withZones(ys, zs)
  var minX, minY = 1e9'f32
  var maxX, maxY = -1e9'f32
  for p in o.pts.mitems:
    let y = ys.fit(zs.mapY(p.y, s))
    p.x = xs.fit(p.x * sx + dx) + shear * y * xScale
    p.y = -y
    minX = min(minX, p.x); maxX = max(maxX, p.x)
    minY = min(minY, p.y); maxY = max(maxY, p.y)
  let x0 = int(floor(minX)) - 1
  let y0 = int(floor(minY))
  let w = int(ceil(maxX)) - x0 + 1
  let h = int(ceil(maxY)) - y0
  if w <= 0 or h <= 0 or w > 2048 or h > 2048: return
  var r = newRaster(w, h)
  let ox = float32(x0)
  let oy = float32(y0)
  var start = 0
  for e in o.ends:
    let n = e - start
    if n >= 2 and e <= o.pts.len:
      template P(i: int): Point = o.pts[start + i]
      var first: Point
      var k0 = 0
      var k1 = n
      if P(0).on:
        first = P(0); k0 = 1
      elif P(n - 1).on:
        first = P(n - 1); k1 = n - 1
      else:
        first = Point(x: (P(0).x + P(n-1).x) / 2, y: (P(0).y + P(n-1).y) / 2, on: true)
      var cx = first.x
      var cy = first.y
      var ctrl: Point
      var hasCtrl = false
      for k in k0 ..< k1:
        let p = P(k)
        if p.on:
          if hasCtrl:
            r.quad(cx - ox, cy - oy, ctrl.x - ox, ctrl.y - oy, p.x - ox, p.y - oy)
            hasCtrl = false
          else:
            r.line(cx - ox, cy - oy, p.x - ox, p.y - oy)
          cx = p.x
          cy = p.y
        else:
          if hasCtrl:
            let mx = (ctrl.x + p.x) / 2
            let my = (ctrl.y + p.y) / 2
            r.quad(cx - ox, cy - oy, ctrl.x - ox, ctrl.y - oy, mx - ox, my - oy)
            cx = mx
            cy = my
          ctrl = p
          hasCtrl = true
      if hasCtrl:
        r.quad(cx - ox, cy - oy, ctrl.x - ox, ctrl.y - oy, first.x - ox, first.y - oy)
      else:
        r.line(cx - ox, cy - oy, first.x - ox, first.y - oy)
    start = e
  result = Mask(w: w, h: h, left: x0, top: y0)
  result.a = r.coverage()
