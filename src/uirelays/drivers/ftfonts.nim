## The system's fonts through fontconfig and FreeType, loaded at run time:
## the text relays (`FontRelays`) of a driver that has no text stack of its
## own -- Wayland's, a framebuffer's. A font is the face fontconfig matches
## (or a font file given by its path); a letter the face lacks comes from
## the face fontconfig names for it. Letters are drawn as FreeType smooths
## them, into the driver's `PixBuf` or a picture of their own
## (`renderText`). Without the libraries the fonts are 0 and measure
## nothing.

import std/[dynlib, os, tables, strutils]
import ../[coords, screen], pixbuf

type
  FtSizeRec {.bycopy.} = object
    face: pointer
    genericData, genericFinalizer: pointer
    xPpem, yPpem: cushort
    xScale, yScale: clong
    ascender, descender, height, maxAdvance: clong
  FtBitmap {.bycopy.} = object
    rows, width: cuint
    pitch: cint
    buffer: ptr UncheckedArray[uint8]
    numGrays: cushort
    pixelMode, paletteMode: uint8
    palette: pointer
  FtGlyphSlotRec {.bycopy.} = object
    library, face, next: pointer
    glyphIndex: cuint
    genericData, genericFinalizer: pointer
    metrics: array[8, clong]
    linearHoriAdvance, linearVertAdvance: clong
    advanceX, advanceY: clong
    format: uint32
    bitmap: FtBitmap
    bitmapLeft, bitmapTop: cint
  FtFaceRec {.bycopy.} = object
    numFaces, faceIndex, faceFlags, styleFlags, numGlyphs: clong
    familyName, styleName: cstring
    numFixedSizes: cint
    availableSizes: pointer
    numCharmaps: cint
    charmaps: pointer
    genericData, genericFinalizer: pointer
    bbox: array[4, clong]
    unitsPerEM: cushort
    ascender, descender, height, maxAdvanceWidth, maxAdvanceHeight: cshort
    underlinePosition, underlineThickness: cshort
    glyph: ptr FtGlyphSlotRec
    size: ptr FtSizeRec
    charmap: pointer
  FtFace = ptr FtFaceRec

  FontSlot = object
    face: FtFace
    size: int
    style: FontStyles
    metrics: FontMetrics
    open: bool

const
  FT_LOAD_RENDER = 4.cint
  FT_LOAD_TARGET_LIGHT = 0x10000.cint
  FT_PIXEL_MODE_MONO = 1'u8
  FT_PIXEL_MODE_GRAY = 2'u8
  FT_PIXEL_MODE_BGRA = 7'u8
  FT_LOAD_COLOR = 0x100000.cint

var
  ftState = 0                    ## 0 not tried, 1 there, -1 not
  ftLib: pointer
  ftInit: proc (lib: ptr pointer): cint {.cdecl, gcsafe.}
  ftNewFace: proc (lib: pointer; path: cstring; index: clong; face: ptr FtFace): cint {.cdecl, gcsafe.}
  ftDoneFace: proc (face: FtFace): cint {.cdecl, gcsafe.}
  ftSetPixelSizes: proc (face: FtFace; w, h: cuint): cint {.cdecl, gcsafe.}
  ftCharIndex: proc (face: FtFace; cp: culong): cuint {.cdecl, gcsafe.}
  ftLoadGlyph: proc (face: FtFace; gi: cuint; flags: cint): cint {.cdecl, gcsafe.}
  fcInit: proc (): cint {.cdecl, gcsafe.}
  fcNameParse: proc (s: cstring): pointer {.cdecl, gcsafe.}
  fcConfigSubstitute: proc (cfg, pat: pointer; kind: cint): cint {.cdecl, gcsafe.}
  fcDefaultSubstitute: proc (pat: pointer) {.cdecl, gcsafe.}
  fcFontMatch: proc (cfg, pat: pointer; res: ptr cint): pointer {.cdecl, gcsafe.}
  fcGetString: proc (pat: pointer; obj: cstring; n: cint; s: ptr cstring): cint {.cdecl, gcsafe.}
  fcGetInteger: proc (pat: pointer; obj: cstring; n: cint; i: ptr cint): cint {.cdecl, gcsafe.}
  fcPatternDestroy: proc (pat: pointer) {.cdecl, gcsafe.}
  fcCharSetCreate: proc (): pointer {.cdecl, gcsafe.}
  fcCharSetAddChar: proc (cs: pointer; cp: uint32): cint {.cdecl, gcsafe.}
  fcCharSetDestroy: proc (cs: pointer) {.cdecl, gcsafe.}
  fcPatternAddCharSet: proc (pat: pointer; obj: cstring; cs: pointer): cint {.cdecl, gcsafe.}
  slots: seq[FontSlot]
  faces: Table[(string, int), FtFace]          ## (file, index): opened once
  fallbackFile: Table[(int, FontStyles), (string, int)]  ## a block of 128 code points: the file for it
  ftTarget*: proc (): ptr PixBuf {.nimcall.}
    ## Where `drawText` draws: the driver's buffer now.

proc loadFt(): bool =
  if ftState == 0:
    ftState = -1
    let ft = loadLib("libfreetype.so.6")
    let fc = loadLib("libfontconfig.so.1")
    if ft == nil or fc == nil: return false
    template get(lib, v, name) =
      v = cast[typeof(v)](lib.symAddr(name))
    get(ft, ftInit, "FT_Init_FreeType")
    get(ft, ftNewFace, "FT_New_Face")
    get(ft, ftDoneFace, "FT_Done_Face")
    get(ft, ftSetPixelSizes, "FT_Set_Pixel_Sizes")
    get(ft, ftCharIndex, "FT_Get_Char_Index")
    get(ft, ftLoadGlyph, "FT_Load_Glyph")
    get(fc, fcInit, "FcInit")
    get(fc, fcNameParse, "FcNameParse")
    get(fc, fcConfigSubstitute, "FcConfigSubstitute")
    get(fc, fcDefaultSubstitute, "FcDefaultSubstitute")
    get(fc, fcFontMatch, "FcFontMatch")
    get(fc, fcGetString, "FcPatternGetString")
    get(fc, fcGetInteger, "FcPatternGetInteger")
    get(fc, fcPatternDestroy, "FcPatternDestroy")
    get(fc, fcCharSetCreate, "FcCharSetCreate")
    get(fc, fcCharSetAddChar, "FcCharSetAddChar")
    get(fc, fcCharSetDestroy, "FcCharSetDestroy")
    get(fc, fcPatternAddCharSet, "FcPatternAddCharSet")
    if ftInit == nil or ftNewFace == nil or ftSetPixelSizes == nil or ftCharIndex == nil or
       ftLoadGlyph == nil or fcInit == nil or fcNameParse == nil or fcFontMatch == nil or
       fcGetString == nil or fcPatternDestroy == nil or fcConfigSubstitute == nil or
       fcDefaultSubstitute == nil:
      return false
    if ftInit(addr ftLib) != 0 or fcInit() == 0: return false
    ftState = 1
  ftState == 1

proc matchFile(pattern: string; cp = -1): (string, int) =
  ## The font file (and face in it) fontconfig picks for `pattern`, and
  ## that has code point `cp` when one is given.
  let pat = fcNameParse(cstring(pattern))
  if pat == nil: return
  var cs: pointer
  if cp >= 0 and fcCharSetCreate != nil and fcPatternAddCharSet != nil:
    cs = fcCharSetCreate()
    discard fcCharSetAddChar(cs, uint32(cp))
    discard fcPatternAddCharSet(pat, "charset", cs)
  discard fcConfigSubstitute(nil, pat, 0)
  fcDefaultSubstitute(pat)
  var res: cint
  let m = fcFontMatch(nil, pat, addr res)
  fcPatternDestroy(pat)
  if cs != nil: fcCharSetDestroy(cs)
  if m == nil: return
  var file: cstring
  var index: cint
  if fcGetString(m, "file", 0, addr file) == 0 and file != nil:
    result[0] = $file
    if fcGetInteger != nil and fcGetInteger(m, "index", 0, addr index) == 0:
      result[1] = index.int
  fcPatternDestroy(m)

proc faceOf(file: string; index: int): FtFace =
  let key = (file, index)
  if key in faces: return faces[key]
  var f: FtFace
  if file.len > 0 and ftNewFace(ftLib, cstring(file), clong(index), addr f) != 0: f = nil
  faces[key] = f
  f

proc patternOf(path: string; size: int; style: FontStyles): string =
  let lpath = path.toLowerAscii
  var family = "monospace"
  let base = path.extractFilename.toLowerAscii
  for (part, name) in [("dejavusansmono", "DejaVu Sans Mono"), ("dejavu", "DejaVu Sans"),
                       ("consola", "Consolas"), ("courier", "Courier New"), ("arial", "Arial"),
                       ("hack", "Hack"), ("firacode", "Fira Code"), ("jetbrains", "JetBrains Mono"),
                       ("sourcecode", "Source Code Pro"), ("robotomono", "Roboto Mono")]:
    if base.replace("-", "").replace("_", "").contains(part):
      family = name
      break
  result = family & ":pixelsize=" & $size
  if FontStyle.bold in style or lpath.contains("bold"): result.add ":weight=bold"
  if FontStyle.italics in style or lpath.contains("italic") or lpath.contains("oblique"):
    result.add ":slant=italic"

proc ftOpenFont*(path: string; size: int; style: FontStyles; metrics: var FontMetrics): Font =
  ## A font file (`path`), or the face fontconfig has for its name ("" the
  ## system's monospaced one), `size` pixels.
  if not loadFt() or size <= 0: return Font(0)
  var file = ""
  var index = 0
  if path.len > 0 and fileExists(path): file = path
  else: (file, index) = matchFile(patternOf(path, size, style))
  let f = faceOf(file, index)
  if f == nil: return Font(0)
  discard ftSetPixelSizes(f, 0, cuint(size))
  let s = f.size
  metrics.ascent = int((s.ascender + 63) div 64)
  metrics.descent = int((-s.descender + 63) div 64)
  metrics.lineHeight = max(int((s.height + 63) div 64), metrics.ascent + metrics.descent)
  slots.add FontSlot(face: f, size: size, style: style, metrics: metrics, open: true)
  Font(slots.len)

proc slotOf(f: Font): ptr FontSlot =
  let i = f.int - 1
  if i >= 0 and i < slots.len and slots[i].open: addr slots[i] else: nil

proc ftCloseFont*(f: Font) =
  let s = slotOf(f)
  if s != nil: s.open = false   # (the face stays: other sizes share it)

proc ftFontMetrics*(f: Font): FontMetrics =
  let s = slotOf(f)
  if s != nil: s.metrics else: FontMetrics()

iterator codePoints(s: string): int =
  var i = 0
  while i < s.len:
    let c = s[i].uint8
    var cp = int(c)
    var n = 1
    if c >= 0xF0 and i + 3 < s.len:
      cp = (int(c and 7) shl 18) or (int(s[i+1].uint8 and 63) shl 12) or
           (int(s[i+2].uint8 and 63) shl 6) or int(s[i+3].uint8 and 63)
      n = 4
    elif c >= 0xE0 and i + 2 < s.len:
      cp = (int(c and 15) shl 12) or (int(s[i+1].uint8 and 63) shl 6) or int(s[i+2].uint8 and 63)
      n = 3
    elif c >= 0xC0 and i + 1 < s.len:
      cp = (int(c and 31) shl 6) or int(s[i+1].uint8 and 63)
      n = 2
    elif c >= 0x80:
      cp = 0xFFFD
    yield cp
    i += n

proc glyphFace(s: ptr FontSlot; cp: int; gi: var cuint): FtFace =
  ## The face that has `cp` at this font's size: its own, else the one
  ## fontconfig names for it.
  gi = ftCharIndex(s.face, culong(cp))
  if gi != 0 or cp < 0x80: return s.face
  let key = (cp shr 7, s.style)
  if key notin fallbackFile:
    fallbackFile[key] = matchFile(patternOf("", s.size, s.style).replace("monospace", "sans-serif"), cp)
  let (file, index) = fallbackFile[key]
  let f = faceOf(file, index)
  if f == nil: return s.face
  discard ftSetPixelSizes(f, 0, cuint(s.size))
  gi = ftCharIndex(f, culong(cp))
  if gi == 0:
    discard ftSetPixelSizes(s.face, 0, cuint(s.size))
    return s.face
  f

proc measure(s: ptr FontSlot; text: string): int =
  for cp in codePoints(text):
    var gi: cuint
    let f = glyphFace(s, cp, gi)
    if ftLoadGlyph(f, gi, FT_LOAD_TARGET_LIGHT) == 0:
      result += int((f.glyph.advanceX + 32) div 64)
    if f != s.face: discard ftSetPixelSizes(s.face, 0, cuint(s.size))

proc ftMeasureText*(f: Font; text: string): TextExtent =
  let s = slotOf(f)
  if s == nil or text.len == 0: return
  discard ftSetPixelSizes(s.face, 0, cuint(s.size))
  TextExtent(w: measure(s, text), h: s.metrics.lineHeight)

proc coverage(s: ptr FontSlot; text: string; w, h: int): seq[uint8] =
  ## The letters' coverage, `w` x `h`, the baseline at the font's ascent.
  result = newSeq[uint8](w * h)
  var pen = 0
  for cp in codePoints(text):
    var gi: cuint
    let f = glyphFace(s, cp, gi)
    if ftLoadGlyph(f, gi, FT_LOAD_RENDER or FT_LOAD_TARGET_LIGHT or FT_LOAD_COLOR) == 0:
      let g = f.glyph
      let bm = g.bitmap
      let x0 = pen + g.bitmapLeft.int
      let y0 = s.metrics.ascent - g.bitmapTop.int
      for by in 0 ..< bm.rows.int:
        let y = y0 + by
        if y < 0 or y >= h: continue
        let row = by * bm.pitch.int
        for bx in 0 ..< bm.width.int:
          let x = x0 + bx
          if x < 0 or x >= w: continue
          let v = case bm.pixelMode
            of FT_PIXEL_MODE_GRAY: bm.buffer[row + bx]
            of FT_PIXEL_MODE_MONO:
              (if (bm.buffer[row + bx div 8] and (0x80'u8 shr (bx mod 8))) != 0: 255'u8 else: 0'u8)
            of FT_PIXEL_MODE_BGRA: bm.buffer[row + bx * 4 + 3]
            else: 0'u8
          if v > result[y * w + x]: result[y * w + x] = v
      pen += int((g.advanceX + 32) div 64)
    if f != s.face: discard ftSetPixelSizes(s.face, 0, cuint(s.size))

proc ftRenderText*(f: Font; text: string; fg: Color; pixels: var seq[uint32]): TextExtent =
  pixels.setLen 0
  let s = slotOf(f)
  if s == nil or text.len == 0: return
  discard ftSetPixelSizes(s.face, 0, cuint(s.size))
  let w = measure(s, text)
  let h = s.metrics.lineHeight
  if w <= 0 or h <= 0: return
  let cov = coverage(s, text, w, h)
  pixels.setLen w * h
  for i in 0 ..< w * h:
    let a = cov[i].uint32 * fg.a.uint32 div 255
    pixels[i] = (a shl 24) or ((fg.r.uint32 * a div 255) shl 16) or
                ((fg.g.uint32 * a div 255) shl 8) or (fg.b.uint32 * a div 255)
  TextExtent(w: w, h: h)

proc ftDrawText*(f: Font; x, y: int; text: string; fg, bg: Color): TextExtent =
  ## On the driver's buffer (`ftTarget`): the background, then the letters.
  let s = slotOf(f)
  if s == nil or text.len == 0 or ftTarget == nil: return
  let b = ftTarget()
  if b == nil: return
  discard ftSetPixelSizes(s.face, 0, cuint(s.size))
  let w = measure(s, text)
  let h = s.metrics.lineHeight
  result = TextExtent(w: w, h: h)
  if w <= 0 or h <= 0: return
  b[].fill(coords.Rect(x: x, y: y, w: w, h: h), bg)
  b[].cover(coverage(s, text, w, h), w, h, x, y, fg)

proc ftFontRelays*(): FontRelays =
  ## The text relays, drawing on `ftTarget()`.
  FontRelays(openFont: ftOpenFont, closeFont: ftCloseFont, getFontMetrics: ftFontMetrics,
             measureText: ftMeasureText, drawText: ftDrawText, renderText: ftRenderText)
