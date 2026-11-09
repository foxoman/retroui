## Tests of the UI's fonts beyond FreeSans (test_text has it): the names
## and choices, a .ttc collection read (a font file the user picks), FreeSerif
## and FreeMono in the canvas's font names, and every character the kit's
## own strings and the examples' translations use found in the fonts --
## headless, on the fake driver.

import std/[unicode, math, os, strutils, tables]
import retroui
import retroui/[typeset, ttf, canvas2d]
import harness

fakeDriver()
startApp("uifonts", W, H)

let fontDir = currentSourcePath().parentDir.parentDir / "src" / "retroui" / "fonts"

proc ink(x0, y0, w, h: int): int =
  ## Pixels of black text in the rectangle (device pixels).
  for y in y0 ..< y0 + h:
    for x in x0 ..< x0 + w:
      if px(x, y) == 0: inc result

# ---- the names, the choices ---------------------------------------------------------------------

block names:
  doAssert uiFont() == ufSans
  doAssert ord(ufSans) == 0 and ufFile notin builtinUiFonts
  doAssert builtinUiFonts == @[ufSans, ufSerif, ufMono] and $ufFile == "Font File"
  for u in UiFont:
    var g = ufMono
    doAssert uiFontOfKey(uiFontKey(u), g) == (u != ufFile), $u
    if u != ufFile: doAssert g == u
  doAssert RetroFontCredit.contains("GNU FreeFont")

# ---- a .ttc collection ------------------------------------------------------------------------------

proc be32(s: string; i: int): int =
  (ord(s[i]) shl 24) or (ord(s[i + 1]) shl 16) or (ord(s[i + 2]) shl 8) or ord(s[i + 3])

proc put32(s: var string; i, v: int) =
  for k in 0 .. 3: s[i + k] = char((v shr (8 * (3 - k))) and 255)

proc makeTtc(fonts: openArray[string]): string =
  ## A TrueType collection of the fonts given (each copied whole, its
  ## tables' offsets moved).
  result = "ttcf\x00\x01\x00\x00"
  result.setLen(12 + 4 * fonts.len)
  result.put32(8, fonts.len)
  for i, f in fonts:
    while result.len mod 4 != 0: result.add '\0'
    let base = result.len
    result.put32(12 + 4 * i, base)
    var font = f
    let n = (ord(font[4]) shl 8) or ord(font[5])
    for t in 0 ..< n: font.put32(12 + 16 * t + 8, be32(font, 12 + 16 * t + 8) + base)
    result.add font

block collection:
  let sans = readFile(fontDir / "FreeSans.ttf")
  let serif = readFile(fontDir / "FreeSerif.ttf")
  let ttc = makeTtc([sans, serif])
  doAssert fontCount(ttc) == 2
  doAssert parseFace(ttc, 0).family == "FreeSans" and parseFace(ttc, 1).family == "FreeSerif"
  # one face as a file of its own (what the PDF writer and the threads read)
  let one = sfntOf(ttc, 1)
  doAssert one.startsWith("\x00\x01\x00\x00") and fontCount(one) == 1
  let f = parseFace(one)
  doAssert f.family == "FreeSerif" and f.numGlyphs == parseFace(serif).numGlyphs
  doAssert f.glyphOf(0xFE91) != 0 and f.advance(f.glyphOf(ord('W'))) == parseFace(serif).advance(f.glyphOf(ord('W')))
  doAssert sfntOf(sans, 0) == sans, "a plain font: itself"
  let tmp = getTempDir() / "retro-ttc"
  createDir(tmp)
  writeFile(tmp / "Both.ttc", ttc)
  let info = faceInfo(tmp / "Both.ttc")
  doAssert info.len == 2 and info[0].family == "FreeSans" and info[1].family == "FreeSerif" and info[1].index == 1
  doAssert not info[0].variable
  # as the UI's font: its first face
  loadUiFontFile(tmp / "Both.ttc")
  doAssert uiFont() == ufFile and face(fUser).family == "FreeSans"
  removeDir(tmp)
  setUiFont(ufSans)

# ---- the canvas's font names ----------------------------------------------------------------------

block canvasFonts:
  let c = newCanvas2D(200, 60)
  c.font = "20px serif"
  let serifW = c.measureText("Hello world").width
  c.font = "20px FreeSerif"
  doAssert abs(c.measureText("Hello world").width - serifW) < 0.01
  doAssert abs(serifW - widthEm("Hello world", fSerif) * 20) < 0.01
  c.font = "20px monospace"
  doAssert abs(c.measureText("Hello").width - widthEm("Hello", fMono) * 20) < 0.01
  c.font = "italic bold 20px sans-serif"
  doAssert abs(c.measureText("Hello").width - widthEm("Hello", fSansBoldItalic) * 20) < 0.01
  c.font = "20px Helvetica"
  doAssert abs(c.measureText("Hello").width - widthEm("Hello", fSans) * 20) < 0.01
  c.font = "20px sans-serif"           # (the UI's font: FreeSerif when it is)
  setUiFont(ufSerif)
  c.font = "20px sans-serif"
  doAssert abs(c.measureText("Hello").width - widthEm("Hello", fSerif) * 20) < 0.01
  setUiFont(ufSans)
  # Arabic on the canvas: joined, drawn
  c.font = "24px sans-serif"
  c.fillStyle = "#000000"
  c.fillText("مرحبا", 10, 40)
  var dark = 0
  for p in c.toBitmap.px:
    if (p shr 24) > 128: inc dark
  doAssert dark > 30, $dark

# ---- every character the kit's strings use --------------------------------------------------------

block coverage:
  # the characters of every string of the kit and its examples -- the
  # Arabic translations (lang_ar.nim) too -- are in the built-in fonts, in
  # every style (CJK, emoji and the full-width forms are the system's to
  # draw: FreeFont has none)
  let root = currentSourcePath().parentDir.parentDir
  var seen: Table[int, string]
  var files = 0
  for dir in [root / "src", root / "examples"]:
    for p in walkDirRec(dir):
      if not p.endsWith(".nim"): continue
      inc files
      for r in readFile(p).runes:
        let cp = int(r)
        if cp < 0x80 or cp in seen: continue
        seen[cp] = p.extractFilename
  doAssert files > 100 and seen.len > 300, $(files, seen.len)
  var missing: seq[string]
  for cp, file in seen:
    if cp in 0x2E80 .. 0x9FFF or cp in 0xAC00 .. 0xD7AF or cp in 0xFF00 .. 0xFFEF or cp >= 0x1F000 or
       cp in 0xE000 .. 0xF8FF or cp in 0xF0000 .. 0x10FFFF: continue
    for base in [fSans, fSansBold, fSansItalic, fSansBoldItalic, fSerif, fMono, fMonoBold]:
      if shape($Rune(cp), base).missing:
        missing.add "U+" & toHex(cp, 4) & " " & $Rune(cp) & " (" & file & ", " & $base & ")"
  doAssert missing.len == 0, missing.join("\n")
  # the Arabic translations, line by line: joined, nothing missing
  for f in [root / "src" / "retroui" / "lang_ar.nim", root / "examples" / "photo" / "lang_ar.nim",
            root / "examples" / "filemanager" / "lang_ar.nim"]:
    if not fileExists(f): continue
    var n = 0
    for line in readFile(f).splitLines:
      if not line.contains("\""): continue
      for piece in line.split('"'):
        if piece.len > 0 and textIsRtl(piece):
          doAssert not shape(piece).missing and not shape(piece, fSansBold).missing, piece
          inc n
    doAssert n > 20, f

echo "ui font tests passed"
