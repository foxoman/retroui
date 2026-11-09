## PDF files in plain Nim: pages of any size, lines, shapes and curves,
## colors, dashes, clipping, pictures, links and text in the kit's built-in
## fonts (FreeSans and FreeMono in their four styles, Arabic from FreeSerif
## joined and right to left; the icon font) -- no libraries, nothing to
## install.
##
## Text is real text: the glyphs used are put into the file once each (as
## small Type 3 fonts drawn from the TrueType outlines), with a map back to
## their characters, so a reader can select, search and copy it.
##
## Coordinates are points (1/72 inch, `mm` converts) from the top-left
## corner of the page, y going down -- as on the screen.
##
## .. code-block:: nim
##   import retroui/pdf
##   var doc = newPdf("Invoice 42", author = "Acme Trading")
##   let p = doc.addPage(A4)
##   p.text(mm(20), mm(20), "Invoice 42", size = 22, bold = true)
##   p.line(mm(20), mm(32), mm(190), mm(32))
##   p.text(mm(20), mm(38), "مرحبا بالعالم -- Hello", size = 12)
##   doc.save("invoice.pdf")

import std/[tables, math, strutils, unicode, sequtils, os, algorithm]
import gfx, typeset, ttf, codec, jpeg

type
  PageSize* = tuple[w, h: float]
    ## A page's width and height in points.

const
  A3* : PageSize = (841.89, 1190.55)    ## 297 x 420 mm
  A4* : PageSize = (595.28, 841.89)     ## 210 x 297 mm
  A5* : PageSize = (419.53, 595.28)     ## 148 x 210 mm
  Letter* : PageSize = (612.0, 792.0)   ## 8.5 x 11 inches
  Legal* : PageSize = (612.0, 1008.0)   ## 8.5 x 14 inches
  MaxPages = 100_000            ## more pages are not added
  MaxCoord = 1e7                ## coordinates are kept inside +- this

proc mm*(v: float): float = v * 72 / 25.4
  ## Millimetres in points: `mm(20)` is 56.7.
proc inch*(v: float): float = v * 72
  ## Inches in points.
proc landscape*(s: PageSize): PageSize = (max(s.w, s.h), min(s.w, s.h))
  ## The page turned on its side: `addPage(landscape(A4))`.

type
  LineCap* = enum
    ## How the ends of stroked lines look.
    capButt, capRound, capSquare
  LineJoin* = enum
    ## How stroked lines meet at corners.
    joinMiter, joinRound, joinBevel

  T3Font = object
    face: FaceId
    gids: seq[uint16]                 ## code -> glyph

  EmbFont = object
    ## (a TrueType font embedded whole: its text stays text -- found,
    ## copied, edited in a PDF editor)
    face: Face
    used: Table[int, string]          ## glyph -> the characters it stands for
    widths: Table[int, int]           ## glyph -> its advance (font units)

  PdfImage = object
    w, h: int
    data: string                      ## the stream, compressed (or JPEG)
    filter: string
    colorSpace: string
    alpha: string                     ## the soft mask stream ("" none)

  PdfLink = object
    x0, y0, x1, y1: float
    uri: string

  PdfPage* = ref object
    ## A page: draw on it with the procs below. Made by `addPage`.
    w*, h*: float                     ## its size in points (1/72 inch)
    trim*, bleed*: tuple[x, y, w, h: float]
      ## (print) where the page is cut, and how far its pictures go past
      ## that (from its top-left corner, in points; w = 0: the whole page)
    doc: PdfDoc
    ops: string                       ## the content stream
    links: seq[PdfLink]
    fontsUsed, imagesUsed, alphasUsed: seq[int]   ## what its resources list
    embUsed: seq[int]                 ## the embedded fonts it uses

  PdfDoc* = ref object
    ## A PDF document: its pages, and what they share (fonts, pictures).
    title*, author*, subject*, keywords*: string  ## its information, as readers show it ("" none)
    creator*: string                  ## the app that made it
    pages*: seq[PdfPage]              ## in order (`addPage` adds them)
    fonts: seq[T3Font]
    current: array[FaceId, int]       ## the font each face adds glyphs to (-1 none)
    codes: Table[uint32, uint16]      ## (face shl 16 or gid) -> (font shl 8 or code)
    images: seq[PdfImage]
    imageOf: Table[uint64, int]       ## a Bitmap's address -> its image
    held: seq[Bitmap]                 ## (kept, so no other takes that address)
    embFonts: seq[EmbFont]
    outputIntent*: tuple[icc, name, info: string]
      ## PDF/X: the printing condition the colors are for (its ICC profile,
      ## a name, a description); "" none
    pdfx*: string                     ## "PDF/X-4", "PDF/X-1a:2003"...: the standard it claims
    lang*: string
      ## the document's language, a BCP 47 tag ("ar", "fa", "en-GB"), for
      ## screen readers, search and copying; "" -- "ar" when the first text
      ## with letters is Arabic, "he" Hebrew, none for the others
    firstLang: string                 ## (what the first text with letters says: "-" none yet)

proc newPdf*(title = ""; author = ""; creator = "Retro Nim UI"): PdfDoc =
  ## A new, empty document; add pages with `addPage`.
  result = PdfDoc(title: title, author: author, creator: creator, firstLang: "-")
  for f in FaceId: result.current[f] = -1

proc addPage*(d: PdfDoc; size = A4): PdfPage =
  ## A new page at the end of the document, `size` in points (`A4`,
  ## `Letter`, `landscape(A4)`, `(mm(100), mm(150))`...).
  let w = if size.w.classify in {fcNormal} and size.w > 0: min(size.w, 14400.0) else: A4.w
  let h = if size.h.classify in {fcNormal} and size.h > 0: min(size.h, 14400.0) else: A4.h
  result = PdfPage(w: w, h: h, doc: d)
  if d.pages.len < MaxPages: d.pages.add result

# ---- numbers and strings in the file ----------------------------------------------------------

proc num(s: var string; v: float) =
  ## `v` with at most 3 decimals, no exponent (what PDF readers want).
  var v = v
  if v.classify notin {fcNormal, fcSubnormal, fcZero, fcNegZero}: v = 0
  v = clamp(v, -MaxCoord, MaxCoord)
  let n = int64(round(v * 1000))
  if n < 0: s.add '-'
  let a = abs(n)
  s.add $(a div 1000)
  var frac = a mod 1000
  if frac != 0:
    s.add '.'
    var digits = 3
    while frac mod 10 == 0:
      frac = frac div 10
      dec digits
    let f = $frac
    for _ in f.len ..< digits: s.add '0'
    s.add f

proc nums(s: var string; vs: varargs[float]) =
  for i, v in vs:
    if i > 0: s.add ' '
    s.num(v)

proc pdfString(s: string): string =
  ## A PDF text string: plain when it is ASCII, else UTF-16 with a BOM.
  var ascii = true
  for c in s:
    if ord(c) >= 128 or ord(c) < 32: ascii = false
  if ascii:
    result = "("
    for c in s:
      if c in {'(', ')', '\\'}: result.add '\\'
      result.add c
    result.add ')'
  else:
    result = "<FEFF"
    for r in s.runes:
      var cp = int(r)
      if cp > 0xFFFF:
        cp -= 0x10000
        result.add toHex(0xD800 + (cp shr 10), 4)
        result.add toHex(0xDC00 + (cp and 0x3FF), 4)
      else: result.add toHex(cp, 4)
    result.add '>'

proc zlib(data: string): string =
  ## The zlib stream (RFC 1950) of `data`, for /FlateDecode.
  let b = toBytes(data)
  var z = newStringOfCap(data.len div 3 + 16)
  z.add "\x78\x9C"
  for x in deflate(b): z.add char(x)
  let a = adler32(b)
  for i in countdown(3, 0): z.add char((a shr (8 * i)) and 0xFF)
  z

# ---- drawing ---------------------------------------------------------------------------------------

proc py(p: PdfPage; y: float): float {.inline.} = p.h - y

proc colorOps(p: PdfPage; c: Color; stroke: bool) =
  p.ops.nums(float(c.r) / 255, float(c.g) / 255, float(c.b) / 255)
  p.ops.add(if stroke: " RG\n" else: " rg\n")

proc fillColor*(p: PdfPage; c: Color) =
  ## The color shapes and text are filled with from now on.
  p.colorOps(c, false)

proc strokeColor*(p: PdfPage; c: Color) =
  ## The color lines are drawn with from now on.
  p.colorOps(c, true)

proc fillCmyk*(p: PdfPage; c, m, y, k: float) =
  ## Fill with printing inks from now on (each 0.0 .. 1.0): for presses.
  p.ops.nums(clamp(c, 0.0, 1.0), clamp(m, 0.0, 1.0), clamp(y, 0.0, 1.0), clamp(k, 0.0, 1.0))
  p.ops.add " k\n"

proc strokeCmyk*(p: PdfPage; c, m, y, k: float) =
  ## Lines in printing inks from now on (each 0.0 .. 1.0).
  p.ops.nums(clamp(c, 0.0, 1.0), clamp(m, 0.0, 1.0), clamp(y, 0.0, 1.0), clamp(k, 0.0, 1.0))
  p.ops.add " K\n"

proc lineWidth*(p: PdfPage; w: float) =
  ## The width of lines from now on, in points.
  p.ops.num(max(0.0, w))
  p.ops.add " w\n"

proc lineCap*(p: PdfPage; c: LineCap) =
  ## How the ends of lines look.
  p.ops.add $ord(c) & " J\n"

proc lineJoin*(p: PdfPage; j: LineJoin) =
  ## How lines meet at corners.
  p.ops.add $ord(j) & " j\n"

proc dash*(p: PdfPage; pattern: openArray[float] = []; phase = 0.0) =
  ## Dashed lines from now on: `dash([4.0, 2.0])` draws 4 points, skips 2;
  ## no pattern: solid again.
  p.ops.add '['
  var n = 0
  for v in pattern:
    if v.classify in {fcNormal, fcZero} and v >= 0 and n < 16:
      if n > 0: p.ops.add ' '
      p.ops.num(v)
      inc n
  p.ops.add "] "
  p.ops.num(phase)
  p.ops.add " d\n"

proc opacity*(p: PdfPage; a: float) =
  ## How opaque what is drawn from now on is, 0.0 (invisible) to 1.0.
  let k = if a.classify in {fcNormal, fcZero, fcNegZero, fcSubnormal}:
            clamp(int(round(clamp(a, 0.0, 1.0) * 255)), 0, 255)
          else: 255
  if k notin p.alphasUsed: p.alphasUsed.add k
  p.ops.add "/GA" & $k & " gs\n"

proc saveState*(p: PdfPage) =
  ## Remember colors, line styles, clipping and opacity (`restoreState`).
  p.ops.add "q\n"

proc restoreState*(p: PdfPage) =
  ## Back to what `saveState` remembered.
  p.ops.add "Q\n"

proc moveTo*(p: PdfPage; x, y: float) =
  ## Starts a new outline at `x`, `y` (then `lineTo`, `curveTo`...).
  p.ops.nums(x, p.py(y))
  p.ops.add " m\n"

proc lineTo*(p: PdfPage; x, y: float) =
  ## A straight line from the current point to `x`, `y`.
  p.ops.nums(x, p.py(y))
  p.ops.add " l\n"

proc curveTo*(p: PdfPage; c1x, c1y, c2x, c2y, x, y: float) =
  ## A cubic Bezier curve to `x`, `y` with the control points c1 and c2.
  p.ops.nums(c1x, p.py(c1y), c2x, p.py(c2y), x, p.py(y))
  p.ops.add " c\n"

proc closePath*(p: PdfPage) =
  ## Back to the outline's start with a straight line.
  p.ops.add "h\n"

proc rect*(p: PdfPage; x, y, w, h: float) =
  ## A rectangle outline (then `fill`, `stroke` or `clip`).
  p.ops.nums(x, p.py(y) - h, w, h)
  p.ops.add " re\n"

const kappa = 0.5522847498

proc ellipse*(p: PdfPage; cx, cy, rx, ry: float) =
  ## An ellipse outline centered on `cx`, `cy` (a circle when rx = ry).
  let ox = rx * kappa
  let oy = ry * kappa
  p.moveTo(cx + rx, cy)
  p.curveTo(cx + rx, cy + oy, cx + ox, cy + ry, cx, cy + ry)
  p.curveTo(cx - ox, cy + ry, cx - rx, cy + oy, cx - rx, cy)
  p.curveTo(cx - rx, cy - oy, cx - ox, cy - ry, cx, cy - ry)
  p.curveTo(cx + ox, cy - ry, cx + rx, cy - oy, cx + rx, cy)
  p.closePath()

proc roundRect*(p: PdfPage; x, y, w, h, r: float) =
  ## A rectangle outline with round corners of radius `r`.
  let r = clamp(r, 0.0, min(w, h) / 2)
  if r <= 0:
    p.rect(x, y, w, h)
    return
  let o = r * (1 - kappa)
  p.moveTo(x + r, y)
  p.lineTo(x + w - r, y)
  p.curveTo(x + w - o, y, x + w, y + o, x + w, y + r)
  p.lineTo(x + w, y + h - r)
  p.curveTo(x + w, y + h - o, x + w - o, y + h, x + w - r, y + h)
  p.lineTo(x + r, y + h)
  p.curveTo(x + o, y + h, x, y + h - o, x, y + h - r)
  p.lineTo(x, y + r)
  p.curveTo(x, y + o, x + o, y, x + r, y)
  p.closePath()

proc fill*(p: PdfPage; evenOdd = false) =
  ## Fills the outline drawn (nonzero winding, or even-odd).
  p.ops.add(if evenOdd: "f*\n" else: "f\n")

proc stroke*(p: PdfPage) =
  ## Draws the outline's lines.
  p.ops.add "S\n"

proc fillStroke*(p: PdfPage; evenOdd = false) =
  ## Fills the outline, then draws its lines.
  p.ops.add(if evenOdd: "B*\n" else: "B\n")

proc clip*(p: PdfPage; evenOdd = false) =
  ## What is drawn from now on shows only inside the outline (until
  ## `restoreState`).
  p.ops.add(if evenOdd: "W* n\n" else: "W n\n")

proc line*(p: PdfPage; x0, y0, x1, y1: float; color = color(0, 0, 0); width = 0.75) =
  ## A straight line in `color`, `width` points wide.
  p.saveState()
  p.strokeColor(color)
  p.lineWidth(width)
  p.moveTo(x0, y0)
  p.lineTo(x1, y1)
  p.stroke()
  p.restoreState()

proc box*(p: PdfPage; x, y, w, h: float; fill = Color(); stroke = Color(); width = 0.75) =
  ## A rectangle filled with `fill` and outlined with `stroke` (alpha 0:
  ## not filled / not outlined).
  if fill.a == 0 and stroke.a == 0: return
  p.saveState()
  if fill.a != 0: p.fillColor(fill)
  if stroke.a != 0:
    p.strokeColor(stroke)
    p.lineWidth(width)
  p.rect(x, y, w, h)
  if fill.a != 0 and stroke.a != 0: p.fillStroke()
  elif fill.a != 0: p.fill()
  else: p.stroke()
  p.restoreState()

proc link*(p: PdfPage; x, y, w, h: float; uri: string) =
  ## A link: a click on that part of the page opens `uri`.
  if uri.len == 0 or uri.len > 4096: return
  p.links.add PdfLink(x0: x, y0: p.py(y + h), x1: x + w, y1: p.py(y), uri: uri)

# ---- pictures --------------------------------------------------------------------------------------

proc image*(p: PdfPage; b: Bitmap; x, y, w, h: float) =
  ## The picture `b` stretched into the rectangle (stored once per
  ## document, however often it is used; transparency kept).
  if b == nil or b.w <= 0 or b.h <= 0 or b.px.len < b.w * b.h: return
  if b.w > 65535 or b.h > 65535: return
  let d = p.doc
  let key = cast[uint64](b)              # (the same picture: stored once)
  var idx = d.imageOf.getOrDefault(key, -1)
  if idx < 0:
    var rgb = newStringOfCap(b.w * b.h * 3)
    var a = newString(b.w * b.h)
    var anyAlpha = false
    for i in 0 ..< b.w * b.h:
      let px = b.px[i]
      rgb.add char((px shr 16) and 0xFF)
      rgb.add char((px shr 8) and 0xFF)
      rgb.add char(px and 0xFF)
      let al = (px shr 24) and 0xFF
      a[i] = char(al)
      if al != 0xFF: anyAlpha = true
    d.images.add PdfImage(w: b.w, h: b.h, data: zlib(rgb), filter: "/FlateDecode",
                          colorSpace: "/DeviceRGB",
                          alpha: if anyAlpha: zlib(a) else: "")
    idx = d.images.high
    d.imageOf[key] = idx
    d.held.add b
  if idx notin p.imagesUsed: p.imagesUsed.add idx
  p.ops.add "q\n"
  p.ops.nums(w, 0.0, 0.0, h, x, p.py(y) - h)
  p.ops.add " cm\n/Im" & $idx & " Do\nQ\n"

proc jpegImage*(p: PdfPage; data: string; x, y, w, h: float): bool {.discardable.} =
  ## A JPEG file's bytes put in as they are (no decoding, no loss), in the
  ## rectangle. False (and nothing drawn) when it is not a baseline or
  ## progressive JPEG in gray or RGB.
  if data.len < 4 or data[0] != '\xFF' or data[1] != '\xD8': return false
  let (iw, ih) = jpegSize(data)
  if iw <= 0 or ih <= 0: return false
  # the number of components, from the frame header
  var comps = 0
  var i = 2
  while i + 9 < data.len:
    if data[i] != '\xFF':
      inc i
      continue
    let m = ord(data[i + 1])
    if m in [0xC0, 0xC1, 0xC2]:
      comps = ord(data[i + 9])
      break
    if m == 0xD8 or m == 0xFF or m in 0xD0 .. 0xD7:
      i += (if m == 0xFF: 1 else: 2)
      continue
    i += 2 + ((ord(data[i + 2]) shl 8) or ord(data[i + 3]))
  if comps notin [1, 3]: return false
  let d = p.doc
  d.images.add PdfImage(w: iw, h: ih, data: data, filter: "/DCTDecode",
                        colorSpace: if comps == 1: "/DeviceGray" else: "/DeviceRGB")
  p.imagesUsed.add d.images.high
  p.ops.add "q\n"
  p.ops.nums(w, 0.0, 0.0, h, x, p.py(y) - h)
  p.ops.add " cm\n/Im" & $d.images.high & " Do\nQ\n"
  true

proc putImage(p: PdfPage; im: PdfImage; x, y, w, h: float) =
  let d = p.doc
  d.images.add im
  p.imagesUsed.add d.images.high
  p.ops.add "q\n"
  p.ops.nums(w, 0.0, 0.0, h, x, p.py(y) - h)
  p.ops.add " cm\n/Im" & $d.images.high & " Do\nQ\n"

proc alphaOf(b: Bitmap): string =
  ## (the alpha of `b`, compressed; "" when it is all opaque)
  var a = newString(b.w * b.h)
  var any = false
  for i in 0 ..< b.w * b.h:
    let v = (b.px[i] shr 24) and 0xFF
    a[i] = char(v)
    if v != 0xFF: any = true
  if any: zlib(a) else: ""

proc imageJpeg*(p: PdfPage; b: Bitmap; x, y, w, h: float; quality = 85) =
  ## The picture `b` in the rectangle, compressed as a JPEG of `quality`
  ## (small: for the screen and the web); its transparency kept losslessly.
  if b == nil or b.w <= 0 or b.h <= 0 or b.px.len < b.w * b.h: return
  p.putImage(PdfImage(w: b.w, h: b.h, data: encodeJpeg(b, quality = clamp(quality, 1, 100)),
                      filter: "/DCTDecode", colorSpace: "/DeviceRGB", alpha: alphaOf(b)), x, y, w, h)

proc imageCmyk*(p: PdfPage; iw, ih: int; cmyk: string; x, y, w, h: float; alpha = "") =
  ## A picture in printing inks: `cmyk` holds 4 bytes a pixel (cyan,
  ## magenta, yellow, black; 255 full ink), `iw` x `ih`, put in the
  ## rectangle losslessly. `alpha`: one byte a pixel ("" opaque).
  if iw <= 0 or ih <= 0 or cmyk.len < iw * ih * 4: return
  var a = ""
  if alpha.len >= iw * ih:
    var any = false
    for i in 0 ..< iw * ih:
      if alpha[i] != '\xFF':
        any = true
        break
    if any: a = zlib(alpha[0 ..< iw * ih])
  p.putImage(PdfImage(w: iw, h: ih, data: zlib(cmyk), filter: "/FlateDecode", colorSpace: "/DeviceCMYK",
                      alpha: a), x, y, w, h)

# ---- text --------------------------------------------------------------------------------------------

proc pdfFace*(bold, mono: bool; italic = false): FaceId =
  ## The face of a text style: FreeSans or FreeMono, in its bold, oblique
  ## or bold oblique.
  styled(if mono: fMono else: fSans, bold, italic)

proc pdfTextWidth*(s: string; size: float; bold = false; mono = false; rtl = -1; italic = false): float =
  ## How wide the line `s` is at `size` points, in points (as `text` writes
  ## it).
  if s.len == 0 or size.classify notin {fcNormal}: return 0
  float(widthEm(s, pdfFace(bold, mono, italic), rtl)) * size

proc pdfLineHeight*(size: float): float =
  ## The height of a line of text at `size` points, in points.
  float(lineFactor()) * size

proc codeOf(d: PdfDoc; face: FaceId; gid: uint16): tuple[font, code: int] =
  let key = (uint32(ord(face)) shl 16) or uint32(gid)
  let v = d.codes.getOrDefault(key, 0xFFFF'u16)
  if v != 0xFFFF'u16: return (int(v shr 8), int(v and 0xFF))
  var f = d.current[face]
  if f < 0 or d.fonts[f].gids.len >= 256:
    d.fonts.add T3Font(face: face)
    f = d.fonts.high
    d.current[face] = f
  let code = d.fonts[f].gids.len
  d.fonts[f].gids.add gid
  if d.fonts.len <= 255:
    d.codes[key] = uint16((f shl 8) or code)
  (f, code)

proc langOf(s: string): string =
  ## (the language the first letter of `s` says: "ar" Arabic, "he" Hebrew,
  ## "" another script, "-" no letter)
  for r in s.runes:
    let c = int(r)
    case strongDir($r)
    of 0: return ""
    of 1: return (if c in 0x0590 .. 0x05FF or c in 0xFB1D .. 0xFB4F: "he" else: "ar")
    else: discard
  "-"

proc readsBothWays(s: string): bool =
  ## (a line with right-to-left text in it, or direction controls: its
  ## glyphs do not stand in the order it is written)
  for r in s.runes:
    let c = int(r)
    if c in 0x0590 .. 0x08FF or c in 0xFB1D .. 0xFDFF or c in 0xFE70 .. 0xFEFC or
       c in 0x202A .. 0x202E or c in 0x2066 .. 0x2069 or c in 0x10800 .. 0x10FFF or
       c in 0x1E800 .. 0x1EFFF:
      return true

proc text*(p: PdfPage; x, y: float; s: string; size = 11.0; color = color(0, 0, 0);
           bold = false; italic = false; mono = false; rtl = -1): float {.discardable.} =
  ## Writes the line `s` with its top-left corner at `x`, `y`, `size`
  ## points high, and returns its width. Arabic letters are joined and
  ## right-to-left text is ordered (`rtl` 1 makes the line a right-to-left
  ## paragraph, 0 left-to-right, -1 from its first letter). `italic` is
  ## FreeSans Oblique (FreeMono Oblique).
  ##
  ## A line with Arabic or right-to-left text in it goes into the file with
  ## its text as written (`/ActualText`: in reading order, the letters
  ## themselves, a zero width non-joiner kept): a reader copies and
  ## searches it as it reads, not in the order its glyphs stand on the
  ## page. Each glyph maps back to its letters too, not their joined shapes.
  if s.len == 0 or size.classify notin {fcNormal} or size <= 0 or size > 2000: return 0
  let line = s.replace('\n', ' ').replace('\r', ' ')
  let run = shape(line, pdfFace(bold, mono, italic), rtl)
  if run.glyphs.len == 0: return float(run.width) * size
  let d = p.doc
  if d.firstLang == "-": d.firstLang = langOf(line)
  let actual = readsBothWays(line)
  if actual: p.ops.add "/Span << /ActualText " & pdfString(plainLetters(line)) & " >> BDC\n"
  let base = p.py(y + float(ascentFactor()) * size)
  p.ops.add "BT\n"
  p.fillColor(color)
  var curFont = -1
  var penX = 0.0                     # where the next glyph goes by the advances
  var lastY = 0'f32
  var inRun = false
  template endTj() =
    if inRun:
      p.ops.add ">] TJ\n"
      inRun = false
  for g in run.glyphs:
    let (fnt, code) = d.codeOf(g.face, g.gid)
    let gx = x + float(g.x) * size
    let gy = base + float(g.y) * size
    let f = face(g.face)
    let adv = float(f.advance(int(g.gid))) / float(f.unitsPerEm) * size
    if fnt != curFont:
      endTj()
      if fnt notin p.fontsUsed: p.fontsUsed.add fnt
      p.ops.add "/T" & $fnt & " "
      p.ops.num(size)
      p.ops.add " Tf\n"
      curFont = fnt
    let off = gx - penX
    if inRun and g.y == 0 and lastY == 0 and abs(off) < size * 4:
      if abs(off) > 0.0005 * size:
        # kerning, a tab, an icon's cell: an adjustment inside the run
        p.ops.add "> "
        p.ops.num(-off * 1000 / size)
        p.ops.add " <"
    else:
      endTj()
      p.ops.nums(1.0, 0.0, (if fauxStyle(g.face).italic: 0.2 else: 0.0), 1.0, gx, gy)
      p.ops.add " Tm\n[<"
      inRun = true
    p.ops.add toHex(code, 2)
    penX = gx + adv
    lastY = g.y
  endTj()
  p.ops.add "ET\n"
  if actual: p.ops.add "EMC\n"
  float(run.width) * size

proc subsetTtf*(data: string; keep: openArray[int]): string =
  ## The TrueType font with only glyphs `keep` drawn (and those they are
  ## made of) -- the others left empty, every glyph keeping its number: a
  ## small font to embed. The font as it is when it cannot be read.
  proc be16(i: int): int = (if i + 1 < data.len: (ord(data[i]) shl 8) or ord(data[i + 1]) else: 0)
  proc be32(i: int): int = (be16(i) shl 16) or be16(i + 2)
  if data.len < 12: return data
  let n = be16(4)
  var tabs: seq[tuple[tag: string; off, len: int]]
  for i in 0 ..< n:
    let e = 12 + 16 * i
    if e + 16 > data.len: return data
    tabs.add (data[e ..< e + 4], be32(e + 8), be32(e + 12))
  proc find(tag: string): int =
    for i, t in tabs:
      if t.tag == tag: return i
    -1
  let hi = find("head")
  let li = find("loca")
  let gi = find("glyf")
  let mi = find("maxp")
  if hi < 0 or li < 0 or gi < 0 or mi < 0: return data
  let numGlyphs = be16(tabs[mi].off + 4)
  let longLoca = be16(tabs[hi].off + 50) == 1
  proc gstart(g: int): int =
    if longLoca: be32(tabs[li].off + 4 * g) else: be16(tabs[li].off + 2 * g) * 2
  var want = newSeq[bool](numGlyphs)
  var todo = @[0]
  for g in keep:
    if g in 0 ..< numGlyphs: todo.add g
  while todo.len > 0:
    let g = todo.pop()
    if g < 0 or g >= numGlyphs or want[g]: continue
    want[g] = true
    let a = tabs[gi].off + gstart(g)
    let b = tabs[gi].off + gstart(g + 1)
    if b - a >= 10 and be16(a) >= 0x8000:
      # (a composite: its parts too)
      var at = a + 10
      while at + 4 <= b:
        let flags = be16(at)
        todo.add be16(at + 2)
        at += 4 + (if (flags and 1) != 0: 4 else: 2)
        if (flags and 8) != 0: at += 2
        elif (flags and 0x40) != 0: at += 4
        elif (flags and 0x80) != 0: at += 8
        if (flags and 0x20) == 0: break
  var glyf = ""
  var loca = newSeq[int](numGlyphs + 1)
  for g in 0 ..< numGlyphs:
    loca[g] = glyf.len
    if want[g]:
      let a = tabs[gi].off + gstart(g)
      let b = tabs[gi].off + gstart(g + 1)
      if b > a and b <= data.len: glyf.add data[a ..< b]
      while glyf.len mod 4 != 0: glyf.add '\0'
  loca[numGlyphs] = glyf.len
  var locaS = newString(4 * (numGlyphs + 1))
  for g, v in loca:
    for k in 0 .. 3: locaS[4 * g + k] = char((v shr (24 - 8 * k)) and 255)
  var head = data[tabs[hi].off ..< min(data.len, tabs[hi].off + tabs[hi].len)]
  if head.len >= 54:
    head[50] = '\0'
    head[51] = '\1'                       # (the glyph places as 32 bits)
    for k in 8 .. 11: head[k] = '\0'       # (checkSumAdjustment)
  # the font again: the same tables, glyf, loca and head new
  var bodies: seq[string]
  for t in tabs:
    bodies.add(case t.tag
               of "glyf": glyf
               of "loca": locaS
               of "head": head
               else: data[t.off ..< min(data.len, t.off + t.len)])
  result = data[0 ..< 12]
  var off = 12 + 16 * n
  var dir = ""
  var payload = ""
  for i, t in tabs:
    let body = bodies[i]
    var sum = 0'u32
    var k = 0
    while k < body.len:
      var v = 0'u32
      for q in 0 .. 3: v = (v shl 8) or (if k + q < body.len: uint32(ord(body[k + q])) else: 0'u32)
      sum += v
      k += 4
    dir.add t.tag
    for v in [sum, uint32(off + payload.len), uint32(body.len)]:
      for q in 0 .. 3: dir.add char((v shr (24 - 8 * q)) and 255)
    payload.add body
    while payload.len mod 4 != 0: payload.add '\0'
  result.add dir
  result.add payload

proc embedded(d: PdfDoc; f: Face): int =
  for i, e in d.embFonts:
    if e.face == f: return i
  d.embFonts.add EmbFont(face: f)
  d.embFonts.high

proc canEmbed*(f: Face): bool =
  ## The font can go into a PDF whole (a TrueType font with outlines).
  f != nil and fontData(f).len > 12 and fontData(f)[0 .. 3] in ["\x00\x01\x00\x00", "true"]

proc textRender*(p: PdfPage; mode: int) =
  ## How the next text is painted: 0 filled, 1 stroked, 2 both, 3 not at all.
  p.ops.add $clamp(mode, 0, 7) & " Tr\n"

proc glyphText*(p: PdfPage; f: Face; size: float; glyphs: openArray[tuple[gid: int; x, y: float; text: string]];
                hScale = 1.0; vScale = 1.0; shear = 0.0) =
  ## Glyphs of font `f` as text (the font embedded whole, the characters
  ## each stands for kept): each at `x`, `y` (its baseline, from the page's
  ## top left, points), `size` points, in the fill color set. A PDF editor
  ## finds, copies and edits it as text.
  if glyphs.len == 0 or size <= 0 or size.classify notin {fcNormal}: return
  let d = p.doc
  let fi = d.embedded(f)
  if fi notin p.embUsed: p.embUsed.add fi
  p.ops.add "BT\n/E" & $fi & " "
  p.ops.num(size)
  p.ops.add " Tf\n"
  for g in glyphs:
    if g.gid <= 0: continue
    if g.text.len > 0 and not d.embFonts[fi].used.hasKey(g.gid): d.embFonts[fi].used[g.gid] = g.text
    elif not d.embFonts[fi].used.hasKey(g.gid): d.embFonts[fi].used[g.gid] = ""
    d.embFonts[fi].widths[g.gid] = f.advance(g.gid)
    p.ops.nums(hScale, 0.0, shear * vScale, vScale, g.x, p.py(g.y))
    p.ops.add " Tm <" & toHex(g.gid, 4) & "> Tj\n"
  p.ops.add "ET\n"

# ---- the glyph outlines (TrueType glyf) ---------------------------------------------------------

type GlyfReader = object
  data: ptr string
  loca, glyf, numGlyphs: int
  longLoca: bool
  upem: int
  ok: bool

var
  readers: array[FaceId, GlyfReader]
  fontBytes: array[FaceId, string]

proc u8(r: GlyfReader; i: int): int {.inline.} =
  if i < 0 or i >= r.data[].len: 0 else: ord(r.data[][i])
proc u16(r: GlyfReader; i: int): int {.inline.} = (r.u8(i) shl 8) or r.u8(i + 1)
proc i16(r: GlyfReader; i: int): int {.inline.} =
  let v = r.u16(i)
  if v >= 0x8000: v - 0x10000 else: v
proc u32(r: GlyfReader; i: int): int {.inline.} = (r.u16(i) shl 16) or r.u16(i + 2)

proc reader(face: FaceId): ptr GlyfReader =
  let r = addr readers[face]
  if r.data == nil:
    fontBytes[face] = fontData(face)
    r.data = addr fontBytes[face]
    let n = r[].u16(4)
    var head, maxp = -1
    for i in 0 ..< min(n, 64):
      let e = 12 + 16 * i
      let tag = r.data[][e ..< min(e + 4, r.data[].len)]
      let off = r[].u32(e + 8)
      case tag
      of "head": head = off
      of "maxp": maxp = off
      of "loca": r.loca = off
      of "glyf": r.glyf = off
      else: discard
    r.ok = head > 0 and maxp > 0 and r.loca > 0 and r.glyf > 0
    if r.ok:
      r.upem = r[].u16(head + 18)
      r.longLoca = r[].i16(head + 50) == 1
      r.numGlyphs = r[].u16(maxp + 4)
  r

proc span(r: GlyfReader; g: int): (int, int) =
  if g < 0 or g >= r.numGlyphs: return (0, 0)
  if r.longLoca: (r.glyf + r.u32(r.loca + 4 * g), r.glyf + r.u32(r.loca + 4 * g + 4))
  else: (r.glyf + 2 * r.u16(r.loca + 2 * g), r.glyf + 2 * r.u16(r.loca + 2 * g + 2))

type GPoint = tuple[x, y: float; on: bool]

proc outline(r: GlyfReader; g: int; pts: var seq[GPoint]; ends: var seq[int];
             depth = 0; m = [1.0, 0, 0, 1, 0, 0]) =
  let (a, b) = r.span(g)
  if b - a < 10 or depth > 8 or a < 0 or b > r.data[].len or pts.len > 20000: return
  let n = r.i16(a)
  if n >= 0:
    let base = pts.len
    var p = a + 10
    var count = 0
    for i in 0 ..< n:
      let e = r.u16(p + 2 * i) + 1
      if e < count or e > 5000: return
      ends.add base + e
      count = e
    p += 2 * n
    p += 2 + r.u16(p)
    var flags = newSeq[int](count)
    var i = 0
    while i < count and p < b:
      let fl = r.u8(p)
      inc p
      flags[i] = fl
      inc i
      if (fl and 8) != 0:
        var rep = r.u8(p)
        inc p
        while rep > 0 and i < count:
          flags[i] = fl
          inc i
          dec rep
    var xs = newSeq[float](count)
    var v = 0
    for k in 0 ..< count:
      let fl = flags[k]
      if (fl and 2) != 0:
        let dd = r.u8(p)
        inc p
        v += (if (fl and 16) != 0: dd else: -dd)
      elif (fl and 16) == 0:
        v += r.i16(p)
        p += 2
      xs[k] = float(v)
    v = 0
    for k in 0 ..< count:
      let fl = flags[k]
      if (fl and 4) != 0:
        let dd = r.u8(p)
        inc p
        v += (if (fl and 32) != 0: dd else: -dd)
      elif (fl and 32) == 0:
        v += r.i16(p)
        p += 2
      let x = xs[k]
      let y = float(v)
      pts.add (m[0] * x + m[2] * y + m[4], m[1] * x + m[3] * y + m[5], (fl and 1) != 0)
  else:
    var p = a + 10
    var guard = 0
    while p + 4 <= b and guard < 64:
      inc guard
      let fl = r.u16(p)
      let sub = r.u16(p + 2)
      p += 4
      var dx, dy: float
      if (fl and 1) != 0:
        dx = float(r.i16(p)); dy = float(r.i16(p + 2)); p += 4
      else:
        dx = float(cast[int8](r.u8(p))); dy = float(cast[int8](r.u8(p + 1))); p += 2
      if (fl and 2) == 0: dx = 0; dy = 0
      var c = [1.0, 0, 0, 1]
      template f2d14(i: int): float = float(r.i16(i)) / 16384
      if (fl and 8) != 0:
        c[0] = f2d14(p); c[3] = c[0]; p += 2
      elif (fl and 0x40) != 0:
        c[0] = f2d14(p); c[3] = f2d14(p + 2); p += 4
      elif (fl and 0x80) != 0:
        c[0] = f2d14(p); c[1] = f2d14(p + 2); c[2] = f2d14(p + 4); c[3] = f2d14(p + 6)
        p += 8
      let k = [m[0] * c[0] + m[2] * c[1], m[1] * c[0] + m[3] * c[1],
               m[0] * c[2] + m[2] * c[3], m[1] * c[2] + m[3] * c[3],
               m[0] * dx + m[2] * dy + m[4], m[1] * dx + m[3] * dy + m[5]]
      r.outline(sub, pts, ends, depth + 1, k)
      if (fl and 0x20) == 0: break

proc glyphProc(face: FaceId; gid: int): string =
  ## The drawing of one glyph, in font units, for a Type 3 font.
  let f = typeset.face(face)
  let r = reader(face)
  let adv = f.advance(gid)
  let bb = f.bounds(gid)
  result.add $adv & " 0 " & $bb.x0 & " " & $bb.y0 & " " & $bb.x1 & " " & $bb.y1 & " d1\n"
  if not r.ok: return
  var pts: seq[GPoint]
  var ends: seq[int]
  r[].outline(gid, pts, ends)
  if pts.len == 0: return
  var start = 0
  proc pt(s: var string; x, y: float) =
    s.num(x)
    s.add ' '
    s.num(y)
  for e in ends:
    let n = e - start
    if n >= 2 and e <= pts.len:
      template P(i: int): GPoint = pts[start + i]
      var first: GPoint
      var k0 = 0
      var k1 = n
      if P(0).on:
        first = P(0); k0 = 1
      elif P(n - 1).on:
        first = P(n - 1); k1 = n - 1
      else:
        first = ((P(0).x + P(n - 1).x) / 2, (P(0).y + P(n - 1).y) / 2, true)
      var cx = first.x
      var cy = first.y
      result.pt(cx, cy)
      result.add " m\n"
      var ctrl: GPoint
      var hasCtrl = false
      template quad(qx, qy, ex, ey: float) =
        # a quadratic curve as the cubic PDF draws
        result.pt(cx + 2 / 3 * (qx - cx), cy + 2 / 3 * (qy - cy))
        result.add ' '
        result.pt(ex + 2 / 3 * (qx - ex), ey + 2 / 3 * (qy - ey))
        result.add ' '
        result.pt(ex, ey)
        result.add " c\n"
      for k in k0 ..< k1:
        let q = P(k)
        if q.on:
          if hasCtrl:
            quad(ctrl.x, ctrl.y, q.x, q.y)
            hasCtrl = false
          else:
            result.pt(q.x, q.y)
            result.add " l\n"
          cx = q.x
          cy = q.y
        else:
          if hasCtrl:
            let mx = (ctrl.x + q.x) / 2
            let my = (ctrl.y + q.y) / 2
            quad(ctrl.x, ctrl.y, mx, my)
            cx = mx
            cy = my
          ctrl = q
          hasCtrl = true
      if hasCtrl: quad(ctrl.x, ctrl.y, first.x, first.y)
      result.add "h\n"
    start = e
  result.add "f\n"

# ---- characters back from glyphs (for copying and searching) ------------------------------------

var unicodeOf: array[FaceId, Table[uint16, int32]]
var unicodeDone: array[FaceId, bool]

proc charOf(face: FaceId; gid: uint16): int =
  if not unicodeDone[face]:
    unicodeDone[face] = true
    let f = typeset.face(face)
    const ranges = [(0x20, 0x7E), (0xA0, 0x24F), (0x250, 0x36F), (0x370, 0x52F),
                    (0x600, 0x6FF), (0x750, 0x77F), (0x8A0, 0x8FF), (0x2000, 0x206F),
                    (0x20A0, 0x20CF), (0x2100, 0x218F), (0x2190, 0x21FF), (0x2200, 0x22FF),
                    (0x2300, 0x23FF), (0x2500, 0x25FF), (0x2600, 0x27BF), (0xFB50, 0xFDFF),
                    (0xFE70, 0xFEFF), (0xE000, 0xF8FF)]
    for (a, b) in ranges:
      for cp in a .. b:
        let g = f.glyphOf(cp)
        if g != 0 and not unicodeOf[face].hasKey(uint16(g)):
          unicodeOf[face][uint16(g)] = int32(cp)
  int(unicodeOf[face].getOrDefault(gid, 0))

proc toUnicodeCMap(f: T3Font): string =
  result = "/CIDInit /ProcSet findresource begin\n12 dict begin\nbegincmap\n" &
    "/CIDSystemInfo << /Registry (Adobe) /Ordering (UCS) /Supplement 0 >> def\n" &
    "/CMapName /Adobe-Identity-UCS def\n/CMapType 2 def\n" &
    "1 begincodespacerange\n<00> <FF>\nendcodespacerange\n"
  var entries: seq[string]
  for code, gid in f.gids:
    let cp = charOf(f.face, gid)
    if cp <= 0: continue
    # (an Arabic letter's joined shape maps to the letter itself, a ligature
    # to its letters: the text copied is the text, not its presentation forms)
    var u = ""
    for r in plainLetters($Rune(cp)).runes:
      let c = int(r)
      if c > 0xFFFF:
        u.add toHex(0xD800 + ((c - 0x10000) shr 10), 4) & toHex(0xDC00 + ((c - 0x10000) and 0x3FF), 4)
      else: u.add toHex(c, 4)
    entries.add "<" & toHex(code, 2) & "> <" & u & ">"
  var i = 0
  while i < entries.len:
    let n = min(100, entries.len - i)
    result.add $n & " beginbfchar\n"
    for k in i ..< i + n: result.add entries[k] & "\n"
    result.add "endbfchar\n"
    i += n
  result.add "endcmap\nCMapName currentdict /CMap defineresource pop\nend\nend\n"

# ---- writing the file -------------------------------------------------------------------------------

proc render*(d: PdfDoc): string =
  ## The document as the bytes of a PDF file (the same bytes for the same
  ## document: no dates or random ids in it).
  var objs: seq[string] = @["", "", ""]           # 1 catalog, 2 pages, 3 info
  proc put(objs: var seq[string]; body: string): int =
    objs.add body
    objs.len
  proc stream(dict, data: string; compress = true): string =
    if compress and data.len > 64:
      let z = zlib(data)
      "<< " & dict & " /Length " & $z.len & " /Filter /FlateDecode >>\nstream\n" & z &
        "\nendstream"
    else:
      "<< " & dict & " /Length " & $data.len & " >>\nstream\n" & data & "\nendstream"
  if d.pages.len == 0: discard d.addPage(A4)
  # fonts
  var fontObj: seq[int]
  for fi, f in d.fonts:
    let tf = typeset.face(f.face)
    let scale = 1.0 / float(max(1, tf.unitsPerEm))
    var procs = ""
    var widths = ""
    var diffs = "0"
    var x0, y0 = 1e9
    var x1, y1 = -1e9
    for code, gid in f.gids:
      let gp = objs.put(stream("", glyphProc(f.face, int(gid))))
      procs.add " /g" & $code & " " & $gp & " 0 R"
      widths.add " " & $tf.advance(int(gid))
      diffs.add " /g" & $code
      let bb = tf.bounds(int(gid))
      x0 = min(x0, float(bb.x0)); y0 = min(y0, float(bb.y0))
      x1 = max(x1, float(bb.x1)); y1 = max(y1, float(bb.y1))
    if x0 > x1:
      x0 = 0; y0 = 0; x1 = 0; y1 = 0
    let cmap = objs.put(stream("", toUnicodeCMap(f)))
    let sc = formatFloat(scale, ffDecimal, 10)
    let m = sc & " 0 0 " & sc & " 0 0"
    var bbox = ""
    bbox.nums(x0, y0, x1, y1)
    let fo = objs.put("<< /Type /Font /Subtype /Type3 /FontBBox [" & bbox & "] /FontMatrix [" &
                      m & "] /CharProcs <<" & procs & " >> /Encoding << /Type /Encoding " &
                      "/Differences [" & diffs & "] >> /FirstChar 0 /LastChar " &
                      $max(0, f.gids.high) & " /Widths [" & widths & " ] /Resources << >> " &
                      "/ToUnicode " & $cmap & " 0 R >>")
    fontObj.add fo
  # the fonts embedded whole (Type 0, TrueType outlines, Identity-H)
  var embObj: seq[int]
  for ei, e in d.embFonts:
    # (only the glyphs used: the font small; its glyphs keep their numbers)
    let data = subsetTtf(fontData(e.face), toSeq(e.widths.keys))
    let z = zlib(data)
    let ff = objs.put("<< /Length1 " & $data.len & " /Length " & $z.len &
                      " /Filter /FlateDecode >>\nstream\n" & z & "\nendstream")
    let upem = float(max(1, e.face.unitsPerEm))
    let k = 1000 / upem
    var name = (e.face.family & "-" & e.face.style).multiReplace((" ", ""), ("(", ""), (")", ""), ("/", ""))
    if name.len == 0 or name == "-": name = "Font"
    # (a subset's name: six capitals and a plus before it)
    var tag = ""
    for q in 0 ..< 6: tag.add char(ord('A') + (ei * 7 + q * 3 + name.len) mod 26)
    name = tag & "+" & name
    var bb = ""
    bb.nums(0.0, float(e.face.descent) * k, 1000.0, float(e.face.ascent) * k)
    let fd = objs.put("<< /Type /FontDescriptor /FontName /" & name & " /Flags 32 /FontBBox [" & bb &
                      "] /ItalicAngle 0 /Ascent " & $int(float(e.face.ascent) * k) & " /Descent " &
                      $int(float(e.face.descent) * k) & " /CapHeight " & $int(float(e.face.ascent) * k) &
                      " /StemV 80 /FontFile2 " & $ff & " 0 R >>")
    var gids = toSeq(e.widths.keys)
    gids.sort()
    var w = ""
    for g in gids: w.add " " & $g & " [" & $int(round(float(e.widths[g]) * k)) & "]"
    let cid = objs.put("<< /Type /Font /Subtype /CIDFontType2 /BaseFont /" & name &
                       " /CIDSystemInfo << /Registry (Adobe) /Ordering (Identity) /Supplement 0 >>" &
                       " /FontDescriptor " & $fd & " 0 R /CIDToGIDMap /Identity /DW 500 /W [" & w & " ] >>")
    var cmap = "/CIDInit /ProcSet findresource begin\n12 dict begin\nbegincmap\n" &
      "/CIDSystemInfo << /Registry (Adobe) /Ordering (UCS) /Supplement 0 >> def\n" &
      "/CMapName /Adobe-Identity-UCS def\n/CMapType 2 def\n" &
      "1 begincodespacerange\n<0000> <FFFF>\nendcodespacerange\n"
    var entries: seq[string]
    for g in gids:
      let t = e.used.getOrDefault(g, "")
      if t.len == 0: continue
      var u = ""
      for r in t.runes:
        let cp = int(r)
        if cp > 0xFFFF:
          let c = cp - 0x10000
          u.add toHex(0xD800 + (c shr 10), 4) & toHex(0xDC00 + (c and 0x3FF), 4)
        else: u.add toHex(cp, 4)
      entries.add "<" & toHex(g, 4) & "> <" & u & ">"
    var i = 0
    while i < entries.len:
      let n = min(100, entries.len - i)
      cmap.add $n & " beginbfchar\n"
      for k2 in i ..< i + n: cmap.add entries[k2] & "\n"
      cmap.add "endbfchar\n"
      i += n
    cmap.add "endcmap\nCMapName currentdict /CMap defineresource pop\nend\nend\n"
    let tu = objs.put(stream("", cmap))
    embObj.add objs.put("<< /Type /Font /Subtype /Type0 /BaseFont /" & name &
                        " /Encoding /Identity-H /DescendantFonts [" & $cid & " 0 R] /ToUnicode " & $tu & " 0 R >>")
  # pictures
  var imageObj: seq[int]
  for ii, im in d.images:
    var smask = ""
    if im.alpha.len > 0:
      let s = objs.put("<< /Type /XObject /Subtype /Image /Width " & $im.w & " /Height " & $im.h &
                       " /ColorSpace /DeviceGray /BitsPerComponent 8 /Filter /FlateDecode /Length " &
                       $im.alpha.len & " >>\nstream\n" & im.alpha & "\nendstream")
      smask = " /SMask " & $s & " 0 R"
    let io = objs.put("<< /Type /XObject /Subtype /Image /Width " & $im.w & " /Height " & $im.h &
                      " /ColorSpace " & im.colorSpace & " /BitsPerComponent 8 /Filter " &
                      im.filter & smask & " /Length " & $im.data.len & " >>\nstream\n" &
                      im.data & "\nendstream")
    imageObj.add io
  # pages, each with the fonts, pictures and opacities it uses
  proc resources(p: PdfPage): string =
    result = "<< /ProcSet [/PDF /Text /ImageB /ImageC]"
    if p.fontsUsed.len > 0 or p.embUsed.len > 0:
      result.add " /Font <<"
      for f in p.fontsUsed: result.add " /T" & $f & " " & $fontObj[f] & " 0 R"
      for f in p.embUsed: result.add " /E" & $f & " " & $embObj[f] & " 0 R"
      result.add " >>"
    if p.imagesUsed.len > 0:
      result.add " /XObject <<"
      for i in p.imagesUsed: result.add " /Im" & $i & " " & $imageObj[i] & " 0 R"
      result.add " >>"
    if p.alphasUsed.len > 0:
      result.add " /ExtGState <<"
      for a in p.alphasUsed:
        var v = ""
        v.num(float(a) / 255)
        result.add " /GA" & $a & " << /Type /ExtGState /ca " & v & " /CA " & v & " >>"
      result.add " >>"
    result.add " >>"
  var kids: seq[int]
  for p in d.pages:
    let content = objs.put(stream("", p.ops))
    var annots = ""
    if p.links.len > 0:
      annots = " /Annots ["
      for l in p.links:
        var r = ""
        r.nums(l.x0, l.y0, l.x1, l.y1)
        let a = objs.put("<< /Type /Annot /Subtype /Link /Rect [" & r &
                         "] /Border [0 0 0] /A << /S /URI /URI " & pdfString(l.uri) & " >> >>")
        annots.add " " & $a & " 0 R"
      annots.add " ]"
    var box = ""
    box.nums(0.0, 0.0, p.w, p.h)
    var boxes = ""
    for (name, b) in [("TrimBox", p.trim), ("BleedBox", p.bleed)]:
      if b.w > 0 and b.h > 0:
        var r = ""
        r.nums(b.x, p.h - b.y - b.h, b.x + b.w, p.h - b.y)
        boxes.add " /" & name & " [" & r & "]"
    kids.add objs.put("<< /Type /Page /Parent 2 0 R /MediaBox [" & box & "]" & boxes &
                      " /Resources " & resources(p) & " /Contents " & $content & " 0 R" & annots & " >>")
  var intents = ""
  if d.outputIntent.icc.len > 0 or d.outputIntent.name.len > 0:
    # (PDF/X: the printing condition the colors are for -- its profile
    # when there is one; else a condition registered at color.org by name)
    var dest = ""
    if d.outputIntent.icc.len > 0:
      let cmykProf = d.outputIntent.icc.len > 20 and d.outputIntent.icc[16 .. 19] == "CMYK"
      let prof = objs.put(stream("/N " & (if cmykProf: "4" else: "3"), d.outputIntent.icc))
      dest = " /DestOutputProfile " & $prof & " 0 R"
    let oi = objs.put("<< /Type /OutputIntent /S /GTS_PDFX /OutputConditionIdentifier " &
                      pdfString(if d.outputIntent.name.len > 0: d.outputIntent.name else: "Custom") &
                      " /OutputCondition " & pdfString(d.outputIntent.info) & " /Info " &
                      pdfString(d.outputIntent.info) & " /RegistryName (http://www.color.org)" & dest & " >>")
    intents = " /OutputIntents [" & $oi & " 0 R]"
  # the language (Arabic, Hebrew: the pages read right to left, as viewers
  # lay them out side by side)
  let lang = if d.lang.len > 0: d.lang elif d.firstLang != "-": d.firstLang else: ""
  var cat = ""
  if lang.len > 0: cat.add " /Lang " & pdfString(lang)
  if lang.len > 0 and lang.toLowerAscii.split('-')[0] in ["ar", "fa", "ur", "he", "yi", "ps", "sd", "ug", "ku", "dv"]:
    cat.add " /ViewerPreferences << /Direction /R2L >>"
  objs[0] = "<< /Type /Catalog /Pages 2 0 R" & intents & cat & " >>"
  objs[1] = "<< /Type /Pages /Kids [" & kids.mapIt($it & " 0 R").join(" ") & "] /Count " &
            $kids.len & " >>"
  var info = "<< /Producer (Retro Nim UI)"
  if d.title.len > 0: info.add " /Title " & pdfString(d.title)
  if d.author.len > 0: info.add " /Author " & pdfString(d.author)
  if d.subject.len > 0: info.add " /Subject " & pdfString(d.subject)
  if d.keywords.len > 0: info.add " /Keywords " & pdfString(d.keywords)
  if d.creator.len > 0: info.add " /Creator " & pdfString(d.creator)
  if d.pdfx.len > 0:
    info.add " /GTS_PDFXVersion " & pdfString(d.pdfx) & " /Trapped /False"
  info.add " >>"
  objs[2] = info
  # the file: header, objects, cross-reference table, trailer
  result = "%PDF-1.7\n%\xE2\xE3\xCF\xD3\n"
  var offsets = newSeq[int](objs.len)
  for i, o in objs:
    offsets[i] = result.len
    result.add $(i + 1) & " 0 obj\n" & o & "\nendobj\n"
  let xref = result.len
  result.add "xref\n0 " & $(objs.len + 1) & "\n0000000000 65535 f \n"
  for o in offsets: result.add align($o, 10, '0') & " 00000 n \n"
  result.add "trailer\n<< /Size " & $(objs.len + 1) & " /Root 1 0 R /Info 3 0 R >>\n" &
             "startxref\n" & $xref & "\n%%EOF\n"

proc save*(d: PdfDoc; path: string) =
  ## Writes the document to the file `path` (through a temporary file
  ## moved into place). Raises `IOError` or `OSError` when it cannot be
  ## written.
  let part = path & ".part"
  writeFile(part, d.render())
  try:
    moveFile(part, path)
  except OSError as e:
    removeFile(part)
    raise e
