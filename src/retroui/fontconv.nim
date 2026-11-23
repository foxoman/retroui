## Fonts of other kinds made TrueType ones, which is how retroui/ttf reads them (`parseFace`
## does it by itself, and the font folders list them):
##
## * WOFF (".woff", a web font): its tables unpacked (`woffToSfnt`);
## * the bitmap fonts of Windows (".fon", ".fnt": MS Sans Serif, Courier, System, Terminal...):
##   each size in the file a face of its own ("Regular 13px"), each pixel a square of the outline,
##   so they draw sharp at their size and blocky at others (`fonToSfnt`, `fonFaces`);
## * PostScript Type 1 fonts (".pfb", ".pfa": the fonts of Adobe Type Manager): their Type 1
##   charstrings followed -- flex, hint replacement, accented letters made of two (seac) -- and
##   each curve cut into quadratic ones (`type1ToSfnt`).
##
## ```nim
## let ttf = fonToSfnt(readFile("C:/Windows/Fonts/sserife.fon"), 2)   # its third size
## let face = parseFace(ttf)
## ```
##
## Developed by Sultan Al Isaiee @foxoman -- www.foxoman.net -- sultan@foxoman.net

import std/[tables, strutils, algorithm, math, sequtils]
import codec, cff, pdfencodings, codepages

# ---- bytes ----------------------------------------------------------------------------------------

proc u8(s: string; i: int): int {.inline.} = (if i >= 0 and i < s.len: ord(s[i]) else: 0)
proc be16(s: string; i: int): int {.inline.} = (u8(s, i) shl 8) or u8(s, i + 1)
proc be32(s: string; i: int): int {.inline.} = (be16(s, i) shl 16) or be16(s, i + 2)
proc le16(s: string; i: int): int {.inline.} = u8(s, i) or (u8(s, i + 1) shl 8)
proc le32(s: string; i: int): int {.inline.} = le16(s, i) or (le16(s, i + 2) shl 16)
proc w16(s: var string; v: int) =
  s.add char((v shr 8) and 255)
  s.add char(v and 255)
proc w32(s: var string; v: int) =
  s.w16((v shr 16) and 0xFFFF)
  s.w16(v and 0xFFFF)
proc w32(s: var string; v: uint32) =
  ## (a value with its top bit set: as an int it would not fit a 32-bit build)
  s.w16(int(v shr 16))
  s.w16(int(v and 0xFFFF))
proc put32(s: var string; at, v: int) =
  for k in 0 .. 3: s[at + k] = char((v shr (24 - 8 * k)) and 255)

proc sfntFromTables*(tables: seq[(string, string)]; version = "\x00\x01\x00\x00"): string =
  ## A font file of these tables (tag, bytes): its directory, the tables each on four bytes,
  ## their checksums and head's checksum adjustment worked out.
  var ts = tables
  ts.sort(proc (a, b: (string, string)): int = cmp(a[0], b[0]))
  let nt = ts.len
  var es = 0
  while (1 shl (es + 1)) <= nt: inc es
  let sr = (1 shl es) * 16
  result = version[0 .. 3]
  result.w16(nt)
  result.w16(sr)
  result.w16(es)
  result.w16(nt * 16 - sr)
  result.setLen(12 + 16 * nt)
  proc sum(s: string): uint32 =
    var i = 0
    while i < s.len:
      var w = 0'u32
      for k in 0 .. 3: w = (w shl 8) or (if i + k < s.len: uint32(ord(s[i + k])) else: 0'u32)
      result += w
      i += 4
  var headAt = -1
  for i, (tag, body0) in ts:
    var body = body0
    if tag == "head" and body.len >= 12: body.put32(8, 0)
    let r = 12 + 16 * i
    for k in 0 .. 3: result[r + k] = tag[k]
    result.put32(r + 4, int(cast[int32](sum(body))))
    result.put32(r + 8, result.len)
    result.put32(r + 12, body.len)
    if tag == "head": headAt = result.len
    result.add body
    while result.len mod 4 != 0: result.add '\0'
  if headAt >= 0: result.put32(headAt + 8, int(cast[int32](0xB1B0AFBA'u32 - sum(result))))

# ---- WOFF -----------------------------------------------------------------------------------------

proc woffToSfnt*(data: string): string =
  ## A WOFF font's bytes ("wOFF") as the font file they pack: each table inflated (zlib) or as
  ## it is. "" when it is not one, or damaged.
  if data.len < 44 or data[0 .. 3] != "wOFF": return ""
  let n = be16(data, 12)
  if n == 0 or 44 + 20 * n > data.len: return ""
  var tabs: seq[(string, string)]
  for i in 0 ..< n:
    let r = 44 + 20 * i
    let tag = data[r ..< r + 4]
    let off = be32(data, r + 4)
    let comp = be32(data, r + 8)
    let orig = be32(data, r + 12)
    if off < 0 or comp < 0 or orig < 0 or off + comp > data.len or orig > 64_000_000: return ""
    if comp < orig:
      let bytes = try: zlibDecompress(data.toOpenArrayByte(off, off + comp - 1), maxOut = orig)
                  except CatchableError: return ""
      if bytes.len != orig: return ""
      var body = newString(orig)
      for k, b in bytes: body[k] = char(b)
      tabs.add (tag, body)
    elif comp == orig: tabs.add (tag, data[off ..< off + comp])
    else: return ""
  sfntFromTables(tabs, data[4 .. 7])

# ---- a TrueType font made from glyphs ------------------------------------------------------------------

type
  MadeGlyph = object
    glyf: string                       ## its glyf entry ("" empty)
    adv: int
    box: tuple[x0, y0, x1, y1: int]
    pts, cons: int
  MadeFont = object
    family, style: string
    weight: int
    italic, fixed, symbol: bool
    upem, ascent, descent, lineGap: int
    glyphs: seq[MadeGlyph]
    cmap: seq[(int, int)]              ## code point (or symbol code) -> glyph

proc nameTable(family, style: string): string =
  var recs: seq[(int, string)]
  proc utf16(s: string): string =
    for ch in s:
      result.add '\0'
      result.add(if ord(ch) < 128: ch else: '?')
  let full = if style == "Regular": family else: family & " " & style
  var ps = ""
  for ch in full:
    if ch in {'A' .. 'Z', 'a' .. 'z', '0' .. '9'}: ps.add ch
  for (id, v) in [(1, family), (2, style), (3, full), (4, full), (6, ps)]:
    recs.add (id, utf16(v))
  result.w16(0)
  result.w16(recs.len)
  result.w16(6 + 12 * recs.len)
  var strs = ""
  for (id, v) in recs:
    result.w16(3); result.w16(1); result.w16(0x409); result.w16(id)
    result.w16(v.len); result.w16(strs.len)
    strs.add v
  result.add strs

proc cmapTable(pairs: seq[(int, int)]; symbol: bool): string =
  ## (one format 4 subtable, a segment for each run of codes whose glyphs follow on)
  var ps = pairs
  ps.keepItIf(it[0] in 0 .. 0xFFFE and it[1] > 0)
  ps.sort(proc (a, b: (int, int)): int = cmp(a[0], b[0]))
  var segs: seq[(int, int, int)]       # start, end, delta
  for (c, g) in ps:
    if segs.len > 0 and segs[^1][1] == c - 1 and ((c + segs[^1][2]) and 0xFFFF) == g:
      segs[^1][1] = c
    elif segs.len == 0 or segs[^1][1] < c:
      segs.add (c, c, (g - c) and 0xFFFF)
  segs.add (0xFFFF, 0xFFFF, 1)
  let n = segs.len
  var es = 0
  while (1 shl (es + 1)) <= n: inc es
  var sub = ""
  sub.w16(4)
  sub.w16(16 + 8 * n)
  sub.w16(0)
  sub.w16(2 * n)
  sub.w16(2 * (1 shl es))
  sub.w16(es)
  sub.w16(2 * n - 2 * (1 shl es))
  for s in segs: sub.w16(s[1])
  sub.w16(0)
  for s in segs: sub.w16(s[0])
  for s in segs: sub.w16(s[2])
  for s in segs: sub.w16(0)
  result.w16(0)
  result.w16(1)
  result.w16(3)
  result.w16(if symbol: 0 else: 1)
  result.w32(12)
  result.add sub

proc buildTtf(m: MadeFont): string =
  var glyf, loca = ""
  var box: tuple[x0, y0, x1, y1: int] = (high(int), high(int), low(int), low(int))
  var maxPts, maxCons, maxAdv = 0
  var minL, minR, maxExt = high(int)
  maxExt = low(int)
  var hmtx = ""
  for g in m.glyphs:
    loca.w32(glyf.len)
    glyf.add g.glyf
    maxPts = max(maxPts, g.pts)
    maxCons = max(maxCons, g.cons)
    maxAdv = max(maxAdv, g.adv)
    hmtx.w16(g.adv)
    if g.glyf.len > 0:
      box = (min(box.x0, g.box.x0), min(box.y0, g.box.y0), max(box.x1, g.box.x1), max(box.y1, g.box.y1))
      hmtx.w16(g.box.x0 and 0xFFFF)
      minL = min(minL, g.box.x0)
      minR = min(minR, g.adv - g.box.x1)
      maxExt = max(maxExt, g.box.x1)
    else: hmtx.w16(0)
  loca.w32(glyf.len)
  if box.x0 > box.x1: box = (0, 0, 0, 0)
  if minL == high(int): (minL, minR, maxExt) = (0, 0, 0)
  let n = m.glyphs.len
  var head = ""
  head.w32(0x00010000); head.w32(0x00010000); head.w32(0); head.w32(0x5F0F3CF5)
  head.w16(0x000B); head.w16(m.upem)
  for _ in 0 .. 3: head.w32(0)                       # (created, modified)
  head.w16(box.x0 and 0xFFFF); head.w16(box.y0 and 0xFFFF)
  head.w16(box.x1 and 0xFFFF); head.w16(box.y1 and 0xFFFF)
  head.w16((if m.weight >= 700: 1 else: 0) or (if m.italic: 2 else: 0))
  head.w16(8); head.w16(2); head.w16(1); head.w16(0)
  var hhea = ""
  hhea.w32(0x00010000)
  hhea.w16(m.ascent and 0xFFFF); hhea.w16((-m.descent) and 0xFFFF); hhea.w16(m.lineGap and 0xFFFF)
  hhea.w16(maxAdv); hhea.w16(minL and 0xFFFF); hhea.w16(minR and 0xFFFF); hhea.w16(maxExt and 0xFFFF)
  hhea.w16(1); hhea.w16(0); hhea.w16(0)
  for _ in 0 .. 3: hhea.w16(0)
  hhea.w16(0); hhea.w16(n)
  var maxp = ""
  maxp.w32(0x00010000); maxp.w16(n); maxp.w16(maxPts); maxp.w16(maxCons)
  maxp.w16(0); maxp.w16(0); maxp.w16(2)
  for _ in 0 .. 7: maxp.w16(0)
  var avg, cnt = 0
  var first, last = 0xFFFF
  last = 0
  for (c, g) in m.cmap:
    if g > 0 and g < n:
      avg += m.glyphs[g].adv
      inc cnt
      first = min(first, c)
      last = max(last, c)
  if cnt > 0: avg = avg div cnt
  var os2 = ""
  os2.w16(4); os2.w16(avg); os2.w16(m.weight); os2.w16(5); os2.w16(0)
  for v in [m.upem div 2, m.upem div 2, 0, m.upem div 10, m.upem div 2, m.upem div 2, 0, m.upem div 3]:
    os2.w16(v)
  os2.w16(m.upem div 20); os2.w16(m.upem * 3 div 10); os2.w16(0)
  for _ in 0 .. 9: os2.add '\0'                      # (panose)
  for _ in 0 .. 3: os2.w32(0)                        # (Unicode ranges)
  os2.add "    "
  os2.w16(if m.weight >= 700 and m.italic: 0x21 elif m.weight >= 700: 0x20 elif m.italic: 1 else: 0x40)
  os2.w16(min(first, 0xFFFF)); os2.w16(min(last, 0xFFFF))
  os2.w16(m.ascent and 0xFFFF); os2.w16((-m.descent) and 0xFFFF); os2.w16(m.lineGap and 0xFFFF)
  os2.w16(max(0, box.y1)); os2.w16(max(0, -box.y0))
  os2.w32(if m.symbol: 0x80000000'u32 else: 1'u32); os2.w32(0)
  os2.w16(m.ascent div 2); os2.w16(m.ascent * 7 div 10); os2.w16(0); os2.w16(32); os2.w16(1)
  var post = ""
  post.w32(0x00030000)
  post.w32(if m.italic: cast[uint32](-12 * 65536) else: 0'u32)
  post.w16((-m.upem div 10) and 0xFFFF); post.w16(m.upem div 20)
  post.w32(if m.fixed: 1 else: 0)
  for _ in 0 .. 3: post.w32(0)
  sfntFromTables(@[("head", head), ("hhea", hhea), ("maxp", maxp), ("hmtx", hmtx), ("loca", loca),
                   ("glyf", glyf), ("cmap", cmapTable(m.cmap, m.symbol)),
                   ("name", nameTable(m.family, m.style)), ("OS/2", os2), ("post", post)])

proc glyphOfPath(path: CffPath; mat: array[6, float]; upem, adv: int): MadeGlyph =
  result.adv = adv
  var b: tuple[x0, y0, x1, y1: int] = (high(int), high(int), low(int), low(int))
  result.glyf = glyfOf(path, mat, upem, upem / 1000, b, result.pts, result.cons)
  if result.glyf.len > 0: result.box = b

# ---- the bitmap fonts of Windows: .fnt, and .fon holding them -------------------------------------------

proc fntFaces(data: string): seq[(int, int)] =
  ## (where each FNT in `data` is and how long: a .fon's FONT resources, or the file itself)
  if data.len >= 0x40 and data[0 .. 1] == "MZ":
    let ne = le32(data, 0x3C)
    if ne <= 0 or ne + 64 > data.len or data[ne ..< ne + 2] != "NE": return
    var r = ne + le16(data, ne + 0x24)
    let shift = le16(data, r)
    if shift > 16: return
    r += 2
    while r + 8 <= data.len:
      let typ = le16(data, r)
      if typ == 0: break
      let count = le16(data, r + 2)
      r += 8
      for k in 0 ..< count:
        let e = r + 12 * k
        if e + 12 > data.len: return
        let off = le16(data, e) shl shift
        let ln = le16(data, e + 2) shl shift
        if typ == 0x8008 and off > 0 and off + 118 <= data.len:
          result.add (off, min(ln, data.len - off))
      r += 12 * count
  elif data.len >= 118 and le16(data, 0) in [0x200, 0x300]:
    result.add (0, data.len)

proc fntInfo(data: string; at: int): tuple[family, style: string; weight: int; italic: bool;
                                           height: int; ok: bool] =
  let v = le16(data, at)
  if v notin [0x200, 0x300]: return
  if (le16(data, at + 66) and 1) != 0: return           # (a vector font: lines, not bitmaps)
  let height = le16(data, at + 88)
  if height <= 0 or height > 255: return
  let weight = le16(data, at + 83)
  let italic = u8(data, at + 80) != 0
  var name = ""
  var p = at + le32(data, at + 105)
  while p < data.len and data[p] != '\0' and name.len < 64:
    name.add data[p]
    inc p
  if name.len == 0: name = "Bitmap Font"
  let w = if weight >= 600: "Bold" else: "Regular"
  let style = (if italic: (if w == "Regular": "Italic" else: w & " Italic") else: w) & " " & $height & "px"
  (name, style, (if weight > 0: (weight + 50) div 100 * 100 else: 400), italic, height, true)

proc fonFaces*(data: string): seq[tuple[family, style: string; weight: int; italic: bool]] =
  ## The faces of a Windows bitmap font file (".fon": each size one; ".fnt": one) -- their
  ## family ("MS Sans Serif"), style ("Regular 13px"), weight and slant. Vector fonts (lines,
  ## not bitmaps) are left out.
  for (off, _) in fntFaces(data):
    let i = fntInfo(data, off)
    if i.ok: result.add (i.family, i.style, i.weight, i.italic)

proc fonToSfnt*(data: string; index = 0): string =
  ## Face `index` of a Windows bitmap font (`fonFaces`) as a TrueType font: each pixel a square
  ## (64 units), the characters its code page's (the ANSI, OEM, symbol... one it names). ""
  ## when there is no such face.
  var k = 0
  var at = -1
  for (off, _) in fntFaces(data):
    if not fntInfo(data, off).ok: continue
    if k == index:
      at = off
      break
    inc k
  if at < 0: return ""
  let info = fntInfo(data, at)
  let v = le16(data, at)
  let height = info.height
  let ascent = min(le16(data, at + 74), height)
  let charset = u8(data, at + 85)
  let firstCh = u8(data, at + 95)
  let lastCh = u8(data, at + 96)
  let fixedW = le16(data, at + 86)
  if lastCh < firstCh: return ""
  const u = 64                                         # (units to a pixel)
  var m = MadeFont(family: info.family, style: info.style, weight: info.weight, italic: info.italic,
                   fixed: fixedW > 0, upem: u * height, ascent: u * ascent,
                   descent: u * (height - ascent), lineGap: u * le16(data, at + 78))
  m.glyphs.add MadeGlyph(adv: u * max(1, le16(data, at + 91)))   # (.notdef: empty)
  let table = at + (if v == 0x300: 148 else: 118)
  let entry = if v == 0x300: 6 else: 4
  let cs = case charset
           of 0, 1: "windows-1252"
           of 161: "windows-1253"
           of 162: "windows-1254"
           of 163: "windows-1258"
           of 177: "windows-1255"
           of 178: "windows-1256"
           of 186: "windows-1257"
           of 204: "windows-1251"
           of 238: "windows-1250"
           of 255: "cp437"
           else: ""
  let cp = table8(cs)
  m.symbol = charset == 2
  for ch in firstCh .. lastCh:
    let e = table + entry * (ch - firstCh)
    if e + entry > data.len: break
    let w = le16(data, e + 0)
    let off = at + (if v == 0x300: le32(data, e + 2) else: le16(data, e + 2))
    let cols = (w + 7) div 8
    if w <= 0 or w > 1024 or off < 0 or off + cols * height > data.len:
      m.glyphs.add MadeGlyph(adv: u * max(0, w))
    else:
      # (each row's runs of pixels; a run the row below repeats grows down instead)
      var rects: seq[tuple[x0, x1, y0, y1: int]]       # pixels: x0 ..< x1, rows y0 ..< y1
      var open: seq[int]                               # (rects still growing)
      for row in 0 ..< height:
        var runs: seq[(int, int)]
        var x = 0
        while x < w:
          let on = (ord(data[off + (x div 8) * height + row]) shr (7 - x mod 8)) and 1
          if on == 1:
            let s = x
            while x < w and ((ord(data[off + (x div 8) * height + row]) shr (7 - x mod 8)) and 1) == 1: inc x
            runs.add (s, x)
          else: inc x
        var still: seq[int]
        for (s, e) in runs:
          var grown = false
          for ri in open:
            if rects[ri].x0 == s and rects[ri].x1 == e and rects[ri].y1 == row:
              rects[ri].y1 = row + 1
              still.add ri
              grown = true
              break
          if not grown:
            rects.add (s, e, row, row + 1)
            still.add rects.high
        open = still
      var path: CffPath
      for r in rects:
        # (counterclockwise, as PostScript's: glyfOf turns them round)
        let x0 = float(u * r.x0)
        let x1 = float(u * r.x1)
        let yt = float(u * (ascent - r.y0))
        let yb = float(u * (ascent - r.y1))
        path.add ('m', x0, yt, 0.0, 0.0, 0.0, 0.0)
        path.add ('l', x0, yb, 0.0, 0.0, 0.0, 0.0)
        path.add ('l', x1, yb, 0.0, 0.0, 0.0, 0.0)
        path.add ('l', x1, yt, 0.0, 0.0, 0.0, 0.0)
        path.add ('h', 0.0, 0.0, 0.0, 0.0, 0.0, 0.0)
      let up = 1.0 / float(m.upem)
      m.glyphs.add glyphOfPath(path, [up, 0, 0, up, 0, 0], m.upem, u * w)
    let g = m.glyphs.high
    if m.symbol:
      m.cmap.add (0xF000 + ch, g)
    elif ch < 0x80:
      if ch >= 0x20: m.cmap.add (ch, g)
      elif charset == 255 and ch > 0: m.cmap.add (int(cp437Low[ch]), g)
    elif cp != nil:
      let c = int(cp[][ch - 0x80])
      if c != 0xFFFD: m.cmap.add (c, g)
    if charset == 255 and ch == 0x7F: m.cmap.add (0x2302, g)
  buildTtf(m)

# ---- PostScript Type 1 ---------------------------------------------------------------------------------

proc t1Decrypt(s: string; r0: uint16; skip: int): string =
  var r = r0
  result = newStringOfCap(s.len)
  for i, c in s:
    let ci = uint16(ord(c))
    let p = ci xor (r shr 8)
    # (in 32 bits without a sign, then its low 16: C makes two 16-bit numbers signed ints before
    # it multiplies them, and 55882 * 52845 overflows one -- undefined, as a 32-bit program and
    # WebAssembly found)
    r = uint16(((uint32(ci) + uint32(r)) * 52845'u32 + 22719'u32) and 0xFFFF'u32)
    if i >= skip: result.add char(p and 255)

const Ws = {' ', '\t', '\r', '\n', '\f', '\0'}

proc t1Token(s: string; p: var int): string =
  ## (the next PostScript token: a name "/x", a number, a word, a string "(...)" kept with its
  ## parentheses, or one of [ ] { })
  while p < s.len and s[p] in Ws: inc p
  if p < s.len and s[p] == '%':
    while p < s.len and s[p] notin {'\r', '\n'}: inc p
    return s.t1Token(p)
  if p >= s.len: return ""
  let st = p
  case s[p]
  of '(':
    var depth = 0
    while p < s.len:
      if s[p] == '\\': inc p
      elif s[p] == '(': inc depth
      elif s[p] == ')':
        dec depth
        if depth == 0:
          inc p
          break
      inc p
  of '[', ']', '{', '}': inc p
  of '/':
    inc p
    while p < s.len and s[p] notin Ws + {'/', '[', ']', '{', '}', '(', '<', '>'}: inc p
  else:
    while p < s.len and s[p] notin Ws + {'/', '[', ']', '{', '}', '(', '<', '>'}: inc p
    if p == st: inc p
  s[st ..< p]

proc t1String(t: string): string =
  if t.len >= 2 and t[0] == '(': t[1 .. ^2].replace("\\(", "(").replace("\\)", ")") else: t

type T1 = object
  family, full, weightName, fontName: string
  italicAngle: float
  fixed: bool
  matrix: array[6, float]
  bbox: array[4, float]
  encoding: array[256, string]
  subrs: seq[string]
  charStrings: OrderedTable[string, string]

proc parseT1(data: string): (T1, bool) =
  var t = T1(matrix: [0.001, 0, 0, 0.001, 0, 0])
  var d = data
  if d.len > 6 and d[0] == '\x80':
    var o = ""
    var p = 0
    while p + 6 <= d.len and d[p] == '\x80' and d[p + 1] in {'\x01', '\x02'}:
      let n = le32(d, p + 2)
      if n < 0: break
      o.add d[p + 6 ..< min(d.len, p + 6 + n)]
      p += 6 + n
    d = o
  let ee = d.find("eexec")
  if ee < 0: return (t, false)
  let clear = d[0 ..< ee]
  if "FontType" in clear and "/FontType 1" notin clear: return (t, false)
  # the clear part: names, the matrix, the box, the encoding
  var p = 0
  var prev, prev2 = ""
  while p < clear.len:
    let tok = clear.t1Token(p)
    if tok.len == 0: break
    case tok
    of "/FamilyName": t.family = clear.t1Token(p).t1String
    of "/FullName": t.full = clear.t1Token(p).t1String
    of "/Weight": t.weightName = clear.t1Token(p).t1String
    of "/FontName": t.fontName = clear.t1Token(p).strip(chars = {'/'})
    of "/ItalicAngle":
      try: t.italicAngle = parseFloat(clear.t1Token(p)) except ValueError: discard
    of "/isFixedPitch": t.fixed = clear.t1Token(p) == "true"
    of "/FontMatrix", "/FontBBox":
      let isM = tok == "/FontMatrix"
      discard clear.t1Token(p)                      # ([ or {)
      var vals: seq[float]
      for _ in 0 .. 5:
        let v = clear.t1Token(p)
        if v in ["]", "}"]: break
        try: vals.add parseFloat(v) except ValueError: break
      if isM and vals.len == 6:
        for k in 0 .. 5: t.matrix[k] = vals[k]
      elif not isM and vals.len >= 4:
        for k in 0 .. 3: t.bbox[k] = vals[k]
    of "StandardEncoding":
      if prev == "/Encoding":
        for c in 0 .. 255: t.encoding[c] = standardEncoding[c]
    of "put":
      discard
    else:
      if tok.startsWith("/") and prev2 == "dup":
        try:
          let c = parseInt(prev)
          if c in 0 .. 255: t.encoding[c] = tok[1 .. ^1]
        except ValueError: discard
    prev2 = prev
    prev = tok
  # the private part, decrypted (binary, or hex)
  var e = ee + 5
  while e < d.len and d[e] in Ws: inc e
  var enc = d[e .. ^1]
  var isHex = enc.len >= 4
  for k in 0 ..< min(4, enc.len):
    if enc[k] notin HexDigits: isHex = false
  if isHex:
    var raw = newStringOfCap(enc.len div 2)
    var hi = -1
    for c in enc:
      let v = if c in {'0' .. '9'}: ord(c) - 48 elif c in {'a' .. 'f'}: ord(c) - 87
              elif c in {'A' .. 'F'}: ord(c) - 55 elif c in Ws: -1 else: -2
      if v == -2: break
      if v < 0: continue
      if hi < 0: hi = v
      else:
        raw.add char(hi * 16 + v)
        hi = -1
    enc = raw
  let priv = t1Decrypt(enc, 55665, 4)
  var lenIV = 4
  let li = priv.find("/lenIV")
  if li >= 0:
    var q = li + 6
    try: lenIV = parseInt(priv.t1Token(q)) except ValueError: discard
  # Subrs (dup i n RD <bytes> NP) and CharStrings (/name n RD <bytes> ND)
  p = 0
  var section = 0
  var toks: seq[string]
  while p < priv.len:
    let tok = priv.t1Token(p)
    if tok.len == 0: break
    if tok == "/Subrs": section = 1
    elif tok == "/CharStrings": section = 2
    elif (tok == "RD" or tok == "-|") and toks.len >= 2:
      var n = -1
      try: n = parseInt(toks[^1]) except ValueError: discard
      if n < 0 or p + 1 + n > priv.len:
        toks.setLen(0)
        continue
      let bin = priv[p + 1 ..< p + 1 + n]
      p += 1 + n
      let cs = if lenIV >= 0: t1Decrypt(bin, 4330, lenIV) else: bin
      if section == 1:
        var idx = -1
        try: idx = parseInt(toks[^2]) except ValueError: discard
        if idx in 0 .. 65535:
          while t.subrs.len <= idx: t.subrs.add ""
          t.subrs[idx] = cs
      elif section == 2 and toks[^2].startsWith("/"):
        t.charStrings[toks[^2][1 .. ^1]] = cs
      toks.setLen(0)
      continue
    toks.add tok
    if toks.len > 8: toks.delete(0)
  (t, t.charStrings.len > 0)

proc t1Glyph(t: T1; name: string; adv: var float; depth = 0): CffPath =
  ## (a glyph's outline from its Type 1 charstring, and its advance)
  if depth > 2 or name notin t.charStrings: return
  var stack, ps: seq[float]
  var x, y, sbx = 0.0
  var flexing = false
  var flexPts: seq[(float, float)]
  var open = false
  var path: CffPath
  var calls = 0
  var done = false
  var width = adv
  proc moveTo(nx, ny: float) =
    if flexing:
      flexPts.add (nx, ny)
      x = nx; y = ny
      return
    if open: path.add ('h', 0.0, 0.0, 0.0, 0.0, 0.0, 0.0)
    x = nx; y = ny
    path.add ('m', x, y, 0.0, 0.0, 0.0, 0.0)
    open = true
  proc lineTo(nx, ny: float) =
    if not open: moveTo(x, y)
    x = nx; y = ny
    path.add ('l', x, y, 0.0, 0.0, 0.0, 0.0)
  proc curveTo(ax, ay, bx, by, cx, cy: float) =
    if not open: moveTo(x, y)
    path.add ('c', ax, ay, bx, by, cx, cy)
    x = cx; y = cy
  proc run(cs: string; level: int) =
    if level > 10 or done: return
    var i = 0
    while i < cs.len and not done:
      inc calls
      if calls > 100_000: return
      let v = ord(cs[i])
      inc i
      if v >= 32:
        if v <= 246: stack.add float(v - 139)
        elif v <= 250:
          stack.add float((v - 247) * 256 + u8(cs, i) + 108)
          inc i
        elif v <= 254:
          stack.add float(-(v - 251) * 256 - u8(cs, i) - 108)
          inc i
        else:
          stack.add float(cast[int32](uint32(be32(cs, i))))
          i += 4
        if stack.len > 64: stack.delete(0)
        continue
      case v
      of 13:                                     # hsbw
        if stack.len >= 2:
          sbx = stack[0]
          width = stack[1]
          x = sbx
          y = 0
        stack.setLen(0)
      of 21:
        if stack.len >= 2: moveTo(x + stack[^2], y + stack[^1])
        stack.setLen(0)
      of 22:
        if stack.len >= 1: moveTo(x + stack[^1], y)
        stack.setLen(0)
      of 4:
        if stack.len >= 1: moveTo(x, y + stack[^1])
        stack.setLen(0)
      of 5:
        if stack.len >= 2: lineTo(x + stack[^2], y + stack[^1])
        stack.setLen(0)
      of 6:
        if stack.len >= 1: lineTo(x + stack[^1], y)
        stack.setLen(0)
      of 7:
        if stack.len >= 1: lineTo(x, y + stack[^1])
        stack.setLen(0)
      of 8:
        if stack.len >= 6:
          let s = stack.len - 6
          let ax = x + stack[s]; let ay = y + stack[s + 1]
          let bx = ax + stack[s + 2]; let by = ay + stack[s + 3]
          curveTo(ax, ay, bx, by, bx + stack[s + 4], by + stack[s + 5])
        stack.setLen(0)
      of 30:                                     # vhcurveto
        if stack.len >= 4:
          let s = stack.len - 4
          let ax = x; let ay = y + stack[s]
          let bx = ax + stack[s + 1]; let by = ay + stack[s + 2]
          curveTo(ax, ay, bx, by, bx + stack[s + 3], by)
        stack.setLen(0)
      of 31:                                     # hvcurveto
        if stack.len >= 4:
          let s = stack.len - 4
          let ax = x + stack[s]; let ay = y
          let bx = ax + stack[s + 1]; let by = ay + stack[s + 2]
          curveTo(ax, ay, bx, by, bx, by + stack[s + 3])
        stack.setLen(0)
      of 9:                                      # closepath
        if open: path.add ('h', 0.0, 0.0, 0.0, 0.0, 0.0, 0.0)
        open = false
        stack.setLen(0)
      of 10:                                     # callsubr
        if stack.len > 0:
          let n = int(stack.pop())
          if n >= 0 and n < t.subrs.len: run(t.subrs[n], level + 1)
      of 11: return                              # return
      of 14:                                     # endchar
        done = true
        stack.setLen(0)
      of 1, 3: stack.setLen(0)                   # hstem, vstem
      of 12:
        let e = u8(cs, i)
        inc i
        case e
        of 7:                                    # sbw
          if stack.len >= 4:
            sbx = stack[0]
            x = stack[0]
            y = stack[1]
            width = stack[2]
          stack.setLen(0)
        of 12:                                   # div
          if stack.len >= 2:
            let b = stack.pop()
            let a = stack.pop()
            stack.add(if b != 0: a / b else: 0.0)
        of 16:                                   # callothersubr
          if stack.len >= 2:
            let n = int(stack.pop())
            let argc = int(stack.pop())
            var args: seq[float]
            for _ in 0 ..< min(max(argc, 0), stack.len): args.insert(stack.pop(), 0)
            case n
            of 1:
              flexing = true
              flexPts.setLen(0)
            of 2: discard
            of 0:
              flexing = false
              if flexPts.len >= 7:
                let q = flexPts
                curveTo(q[1][0], q[1][1], q[2][0], q[2][1], q[3][0], q[3][1])
                curveTo(q[4][0], q[4][1], q[5][0], q[5][1], q[6][0], q[6][1])
              ps = @[y, x]
            of 3: ps = @[3.0]
            else: ps = args.reversed
        of 17:                                   # pop
          if ps.len > 0: stack.add ps.pop()
        of 33:                                   # setcurrentpoint
          if stack.len >= 2:
            x = stack[^2]
            y = stack[^1]
          stack.setLen(0)
        of 6:                                    # seac: an accented letter made of two
          if stack.len >= 5:
            let s = stack.len - 5
            let asb = stack[s]
            let adx = stack[s + 1]
            let ady = stack[s + 2]
            let bc = int(stack[s + 3])
            let ac = int(stack[s + 4])
            stack.setLen(0)
            var a0 = 0.0
            let bn = if bc in 0 .. 255: standardEncoding[bc] else: ""
            let an = if ac in 0 .. 255: standardEncoding[ac] else: ""
            if open: path.add ('h', 0.0, 0.0, 0.0, 0.0, 0.0, 0.0)
            open = false
            for o in t.t1Glyph(bn, a0, depth + 1): path.add o
            let dx = adx - asb + sbx
            for o in t.t1Glyph(an, a0, depth + 1):
              path.add (o.op, o.x1 + dx, o.y1 + ady, o.x2 + dx, o.y2 + ady, o.x3 + dx, o.y3 + ady)
            done = true
        of 0, 1, 2: stack.setLen(0)              # dotsection, vstem3, hstem3
        else: stack.setLen(0)
      else: stack.setLen(0)
  run(t.charStrings[name], 0)
  if open: path.add ('h', 0.0, 0.0, 0.0, 0.0, 0.0, 0.0)
  adv = width
  path

var aglTable {.threadvar.}: Table[string, int]   # (fonts are read on several threads)

proc unicodeOfGlyphName*(n: string): int =
  ## The character a glyph's PostScript name stands for: the Adobe Glyph List, "uniXXXX",
  ## "uXXXX[XX]" (-1: not known).
  if aglTable.len == 0:
    for item in glyphListData.split('|'):
      let k = item.find('=')
      if k > 0:
        try: aglTable[item[0 ..< k]] = parseHexInt(item[k + 1 .. ^1]) except ValueError: discard
  var base = n
  let dot = base.find('.')
  if dot > 0: base = base[0 ..< dot]
  if aglTable.hasKey(base): return aglTable[base]
  if base.len == 7 and base.startsWith("uni"):
    try: return parseHexInt(base[3 .. 6]) except ValueError: discard
  if base.len in 5 .. 7 and base[0] == 'u':
    try: return parseHexInt(base[1 .. ^1]) except ValueError: discard
  -1

proc type1Info*(data: string): tuple[family, style: string; weight: int; italic, ok: bool] =
  ## A Type 1 font's family, style, weight and slant, read without its outlines.
  let (t, ok) = parseT1(data)
  if not ok: return
  var fam = t.family
  if fam.len == 0: fam = t.fontName
  var style = t.full
  if style.startsWith(fam): style = style[fam.len .. ^1].strip(chars = {' ', '-'})
  if style.len == 0: style = t.weightName
  if style.len == 0 or style in ["Normal", "Roman", "Book", "Medium"]: style = "Regular"
  let wl = (t.weightName & " " & style).toLowerAscii
  let weight = if "black" in wl or "heavy" in wl: 900 elif "extrabold" in wl: 800
               elif "semibold" in wl or "demi" in wl: 600 elif "bold" in wl: 700
               elif "light" in wl: 300 elif "thin" in wl: 100 else: 400
  let italic = t.italicAngle != 0 or "italic" in wl or "oblique" in wl
  if italic and "italic" notin style.toLowerAscii and "oblique" notin style.toLowerAscii:
    style = if style == "Regular": "Italic" else: style & " Italic"
  (fam, style, weight, italic, fam.len > 0)

proc type1ToSfnt*(data: string): string =
  ## A PostScript Type 1 font (a .pfb's bytes, or a .pfa's text) as a TrueType font: each glyph's
  ## curves cut into quadratic ones, its characters from the glyphs' names (a font whose names
  ## are not letters -- Symbol, Dingbats -- by its own codes, as a symbol font). "" when it is
  ## not one.
  let (t, ok) = parseT1(data)
  if not ok: return ""
  let info = type1Info(data)
  let upem = clamp(int(round(1.0 / max(abs(t.matrix[0]), 1e-6))), 16, 16384)
  var m = MadeFont(family: info.family, style: info.style, weight: info.weight, italic: info.italic,
                   fixed: t.fixed, upem: upem)
  m.ascent = int(round(t.bbox[3] * t.matrix[3] * float(upem)))
  m.descent = -int(round(t.bbox[1] * t.matrix[3] * float(upem)))
  if m.ascent <= 0: m.ascent = upem * 8 div 10
  if m.descent < 0: m.descent = upem div 5
  var order = @[".notdef"]
  for nm in t.charStrings.keys:
    if nm != ".notdef": order.add nm
  var gidOf: Table[string, int]
  var known = 0
  for nm in order:
    var adv = 0.0
    let path = t.t1Glyph(nm, adv)
    let a = int(round(adv * t.matrix[0] * float(upem)))
    gidOf[nm] = m.glyphs.len
    m.glyphs.add glyphOfPath(path, t.matrix, upem, max(0, a))
    let uc = unicodeOfGlyphName(nm)
    if uc >= 0 and nm != ".notdef":
      inc known
      if uc <= 0xFFFF: m.cmap.add (uc, gidOf[nm])
  # (a font of pictures or of another alphabet -- Symbol's "a" is alpha, Dingbats -- by its
  # own codes, as a symbol font)
  var coded, other, ascii = 0
  for c in 0 .. 255:
    let nm = t.encoding[c]
    if nm.len == 0 or nm notin gidOf: continue
    inc coded
    if c in 0x21 .. 0x7E:
      inc ascii
      if unicodeOfGlyphName(nm) != c: inc other
  if known * 2 < coded or other * 2 > ascii:
    m.symbol = true
    m.cmap.setLen(0)
    for c in 0 .. 255:
      if t.encoding[c].len > 0 and t.encoding[c] in gidOf: m.cmap.add (0xF000 + c, gidOf[t.encoding[c]])
  else:
    # (one glyph for each character: the first name that gives it)
    var seen: Table[int, bool]
    var kept: seq[(int, int)]
    for (c, g) in m.cmap:
      if c notin seen:
        seen[c] = true
        kept.add (c, g)
    m.cmap = kept
  buildTtf(m)

# ---- what a file is ----------------------------------------------------------------------------------

proc isType1*(data: string): bool =
  ## The bytes are a PostScript Type 1 font (.pfb or .pfa).
  (data.len > 6 and data[0] == '\x80' and data[1] == '\x01') or
    data.startsWith("%!PS-AdobeFont") or data.startsWith("%!FontType1")

proc isBitmapFon*(data: string): bool =
  ## The bytes are a Windows bitmap font (.fon, .fnt).
  (data.len >= 0x40 and data[0 .. 1] == "MZ") or (data.len >= 118 and le16(data, 0) in [0x200, 0x300])
