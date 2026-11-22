## Tests of the older and other kinds of font file the kit reads (`retroui/fontconv`, through
## `retroui/ttf`): a WOFF web font, a Windows bitmap font (.fon: each size a face, each pixel a
## square), PostScript Type 1 fonts (.pfb: their outlines, an accented letter made of two, a
## font whose codes are other letters), symbol fonts typed as Windows types them, CFF2 (at its
## default instance), variation sequences (cmap 14), an Arabic font of before Unicode -- each
## against the font it was made from (tools/genoldfonts.py,
## tools/genlegacy.py; FreeSerif and FreeMono, GPL with the font exception), and what a font
## folder learns of each without reading it.

import std/os
import retroui/[ttf, otshape, fontconv, textengine]

let dir = currentSourcePath().parentDir / "data" / "fonts"
let serif = parseFace(readFile(currentSourcePath().parentDir.parentDir / "src" / "retroui" / "fonts" /
                               "FreeSerif.ttf"))
var passed = 0
template check(cond: bool; what: string) =
  doAssert cond, what
  inc passed
  echo "  ok   ", what

block woff:
  let ttf = readFile(dir / "ArabicNoLayout-Test.ttf")
  let w = readFile(dir / "ArabicNoLayout-Test.woff")
  check woffToSfnt(w).len > 0, "WOFF: its tables unpacked"
  let a = parseFace(ttf)
  let b = parseFace(w)
  check a.numGlyphs == b.numGlyphs and a.glyphOf(0x0628) == b.glyphOf(0x0628), "WOFF: the same font"
  var cps: seq[int]
  for c in "Hello": cps.add ord(c)
  let sa = a.shape(cps, false)
  let sb = b.shape(cps, false)
  var same = sa.len == sb.len
  for i in 0 ..< min(sa.len, sb.len):
    if sa[i].gid != sb[i].gid or sa[i].xAdv != sb[i].xAdv: same = false
  check same, "WOFF: shaped as the TrueType font"
  let fi = faceInfo(dir / "ArabicNoLayout-Test.woff")
  check fi.len == 1 and fi[0].family == "Arabic No Layout Test", "WOFF: its name, for a font folder"

block windowsBitmapFont:
  let data = readFile(dir / "OldBitmap-Test.fon")
  check isBitmapFon(data) and fontCount(data) == 2, ".fon: two sizes, two faces"
  let fi = faceInfo(dir / "OldBitmap-Test.fon")
  check fi.len == 2 and fi[0].family == "Old Bitmap Test" and fi[0].style == "Regular 13px" and
        fi[1].style == "Regular 20px" and fi[1].index == 1, ".fon: family and sizes from the file"
  for (index, px) in [(0, 13), (1, 20)]:
    let f = parseFace(data, index)
    check f.unitsPerEm == 64 * px, ".fon " & $px & " px: a pixel 64 units"
    let g = f.glyphOf(ord('H'))
    let bx = f.bounds(g)
    check g != 0 and bx.x0 mod 64 == 0 and bx.x1 mod 64 == 0 and bx.y0 mod 64 == 0 and
          bx.y1 mod 64 == 0 and f.advance(g) mod 64 == 0, ".fon " & $px & " px: H on the pixel grid"
    # (at its own size each pixel is all ink or none)
    let m = f.render(g, float32(px), hint = false)
    var ink, partial = 0
    for v in m.a:
      if v > 0: inc ink
      if v in 20'u8 .. 235'u8: inc partial
    check ink > 0 and partial == 0, ".fon " & $px & " px: sharp at its own size (" & $ink & " pixels)"
  check parseFace(data, 0).glyphOf(ord('a')) != parseFace(data, 0).glyphOf(ord('b')), ".fon: its letters apart"

block type1:
  let data = readFile(dir / "OldType1-Test.pfb")
  check isType1(data), "Type 1: known by its first bytes"
  let fi = faceInfo(dir / "OldType1-Test.pfb")
  check fi.len == 1 and fi[0].family == "Old Type1 Test" and fi[0].style == "Regular" and fi[0].weight == 400,
        "Type 1: family and style from its clear part"
  let f = parseFace(data)
  for c in "AHOSagos0258!?":
    let g = f.glyphOf(ord(c))
    let s = serif.glyphOf(ord(c))
    let a = f.bounds(g)
    let b = serif.bounds(s)
    doAssert g != 0, $c
    doAssert abs(a.x0 - b.x0) <= 2 and abs(a.y0 - b.y0) <= 2 and abs(a.x1 - b.x1) <= 2 and
             abs(a.y1 - b.y1) <= 2, $c & ": " & $a & " " & $b
    doAssert f.advance(g) == serif.advance(s), $c
  check true, "Type 1: outlines and advances as FreeSerif's (14 letters)"
  let aa = f.glyphOf(0xC1)
  let ab = f.bounds(aa)
  let ac = f.bounds(f.glyphOf(ord('A')))
  check aa != 0 and ab.y1 > ac.y1 + 100 and ab.y0 == ac.y0, "Type 1: Á made of A and the acute above it (seac)"

block symbolFonts:
  # (Symbol's kind: what is typed is a code -- "a" is alpha)
  let f = parseFace(readFile(dir / "OldSymbol-Test.pfb"))
  let g = f.glyphOf(ord('a'))
  let bx = f.bounds(g)
  let alpha = serif.bounds(serif.glyphOf(0x03B1))
  check g != 0 and abs(bx.x1 - alpha.x1) <= 2 and abs(bx.y1 - alpha.y1) <= 2, "symbol font: a is its alpha"
  check f.glyphOf(0xF061) == g, "symbol font: and at 0xF061, as Windows has it"

block oldArabic:
  let f = parseFace(readFile(dir / "ArabicLegacy-Test.ttf"))
  let u = parseFace(readFile(dir / "ArabicNoLayout-Test.ttf"))
  check f.glyphOf(0x0644) == u.glyphOf(0xFEDD), "an Arabic font of before Unicode: lam found"
  check f.glyphOf(0xF2BE) == f.glyphOf(0x0644), "... and at its own code"

block cff2:
  # (a variable font's PostScript outlines: read at its default instance)
  let f = parseFace(readFile(dir / "VarCFF2-Test.otf"))
  check f.bounds(f.glyphOf(ord('A'))) == (100, 0, 500, 700) and f.advance(f.glyphOf(ord('A'))) == 600,
        "CFF2: A at its default instance (its blends' defaults)"
  check f.bounds(f.glyphOf(ord('B'))) == (50, 0, 250, 500), "CFF2: B too"
  let fi = faceInfo(dir / "VarCFF2-Test.otf")
  check fi.len == 1 and fi[0].family == "Var CFF2 Test" and fi[0].variable, "CFF2: listed, a variable font"

block variationSequences:
  let u = parseFace(readFile(dir / "ArabicNoLayout-Test.ttf"))
  check u.variationGlyph(0x41, 0xFE00) == u.glyphOf(0x42), "cmap 14: A + VS1 its own glyph"
  check u.variationGlyph(0x43, 0xFE00) == u.glyphOf(0x43), "cmap 14: C + VS1 C (the default)"
  check u.variationGlyph(0x44, 0xFE00) == -1 and u.variationGlyph(0x41, 0xFE01) == -1, "cmap 14: none for others"

block aFontFolder:
  # (every kind offered from a folder, listed by family)
  let tmp = getTempDir() / "retroui-fontkinds"
  createDir(tmp)
  for n in ["OldBitmap-Test.fon", "OldType1-Test.pfb", "ArabicNoLayout-Test.woff"]:
    copyFile(dir / n, tmp / n)
  addFontDir(tmp)
  scanFonts(force = true)
  let fams = fontFamilies()
  check "Old Bitmap Test" in fams and "Old Type1 Test" in fams and "Arabic No Layout Test" in fams,
        "a font folder: the bitmap, Type 1 and WOFF fonts listed"
  check "Regular 13px" in fontStyles("Old Bitmap Test") and "Regular 20px" in fontStyles("Old Bitmap Test"),
        "a font folder: a bitmap font's sizes its styles"
  check fontFace("Old Type1 Test", "Regular").face.glyphOf(ord('Q')) != 0, "a font folder: Type 1 drawn"
  removeDir(tmp)

echo "test_fontkinds: ", passed, " passed"
