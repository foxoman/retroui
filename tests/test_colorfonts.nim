## Colour fonts (`retroui/ttf`, `retroui/textengine`, `retroui/photopdf`): a small font made by
## tools/gencolorfont.py whose "A" is two layers of colour (COLR and CPAL), whose "B" is a
## picture (sbix), whose "C" is a picture too (CBDT and CBLC, as Noto Color Emoji is made) and
## whose "D" is a layer in the text's own colour.
## The font reader finds each glyph's layers in either palette and its pictures, where they go
## and how big; the text engine draws the layers in their colours (the text's own colour where
## the palette says so) and the pictures as pictures, a picture turned with its text; a PDF has
## the layers filled, the pictures in it as pictures and the other letters still text; SVG has
## the pictures as pictures. A font with no colour has none of it.

import std/[os, strutils, math]
import retroui/[ttf, textengine, photo, photopdf, photoimport, photosvg]

const data = currentSourcePath().parentDir / "data" / "fonts"

var failures = 0
template check(cond: bool; what: string) =
  if cond: echo "  ok   ", what
  else:
    echo "  FAIL ", what
    inc failures

let bytes = readFile(data / "ColorTest.ttf")
let f = parseFace(bytes)
let gA = f.glyphOf(ord('A'))
let gB = f.glyphOf(ord('B'))
let gC = f.glyphOf(ord('C'))

proc near(c: uint32; r, g, b: int; slack = 40): bool =
  ## (a pixel this colour, near enough, and opaque)
  (c shr 24) > 200 and abs(int((c shr 16) and 255) - r) <= slack and
    abs(int((c shr 8) and 255) - g) <= slack and abs(int(c and 255) - b) <= slack

block layers:
  check f.hasColorLayers and f.hasColorPictures, "the font has layers and pictures"
  let a = f.colorLayers(gA)
  check a.len == 2 and a[0].color == 0xFFFF0000'u32 and a[1].color == 0xFF0000FF'u32,
        "A: a red layer under a blue one (" & $a.len & ")"
  check a.len == 2 and a[0].gid != gA and a[1].gid != a[0].gid, "each layer a glyph of its own"
  let a2 = f.colorLayers(gA, palette = 1)
  check a2.len == 2 and a2[0].color == 0xFF009900'u32, "the second palette: green under blue"
  check f.colorLayers(gA, palette = 9).len == 2, "a palette it has not: the last it has"
  let d = f.colorLayers(f.glyphOf(ord('D')))
  check d.len == 1 and d[0].color == 0, "D: one layer, in the text's own colour"
  check f.colorLayers(gB).len == 0 and f.colorLayers(-1).len == 0 and f.colorLayers(9999).len == 0,
        "a glyph with none: no layers"

block pictures:
  let b = f.colorPicture(gB, 64)
  check b.png.len > 24 and b.png[0 .. 3] == "\x89PNG", "B: a PNG (sbix)"
  check b.strike == 64 and b.w == 2 and b.h == 2 and b.x == 8 and b.y == -6,
        "B: at 64 pixels an em, 2 x 2, 8 right of the pen, its top 6 above the baseline (" &
        $b.strike & " " & $b.x & "," & $b.y & ")"
  let c = f.colorPicture(gC, 20)
  check c.png.len > 24 and c.strike == 64 and c.w == 2 and c.h == 2 and c.x == 4 and c.y == -20,
        "C: a PNG of CBDT, 4 right of the pen, its top 20 above (" & $c.x & "," & $c.y & ")"
  check f.colorPicture(gA, 64).png.len == 0 and f.colorPicture(-3, 64).png.len == 0,
        "A and no glyph: no picture"
  let plain = parseFace(readFile(data / "NotoSansArabic-Subset.ttf"))
  check not plain.hasColorLayers and not plain.hasColorPictures and
        plain.colorLayers(plain.glyphOf(0x628)).len == 0 and plain.colorPicture(3, 32).png.len == 0,
        "a font with no colour: nothing"

addFontData("Color Test", "Regular", bytes)
let st = CharStyle(family: "Color Test", size: 640, color: 0xFF000000'u32, hScale: 1, vScale: 1)
let t = newText("ABC", st, 20, 700)
let lay = layoutText(t)

block drawn:
  check lay.glyphs.len == 3 and lay.glyphs[0].face != nil and lay.glyphs[0].face.family == "Color Test",
        "laid out in the colour font"
  check lay.glyphs[0].isColorGlyph and lay.glyphs[1].isColorGlyph and lay.glyphs[2].isColorGlyph,
        "each of its glyphs a colour one"
  let outs = textOutlines(t, lay)
  var reds, blues, pics = 0
  for o in outs:
    if o.picture != nil: inc pics
    elif o.color == 0xFFFF0000'u32: inc reds
    elif o.color == 0xFF0000FF'u32: inc blues
  check reds == 1 and blues == 1 and pics == 2, "outlines: a red and a blue layer, two pictures"
  let W = 2100
  let H = 900
  let px = t.renderText(W, H, lay)
  let base = int(lay.glyphs[0].y)
  let x0 = int(lay.glyphs[0].x)
  # A: the square (font units 100..900 across, 0..800 up) red, the diamond's middle blue
  check px[(base - 30) * W + x0 + 90].near(255, 0, 0), "A's square red"
  check px[(base - 256) * W + x0 + 320].near(0, 0, 255), "A's diamond blue over it"
  # B: its 2 x 2 picture ten times as big: 80..100 right of the pen, 60..40 above the baseline
  let xb = int(lay.glyphs[1].x)
  check px[(base - 55) * W + xb + 85].near(255, 0, 0) and px[(base - 55) * W + xb + 95].near(0, 255, 0) and
        px[(base - 45) * W + xb + 85].near(0, 0, 255) and px[(base - 45) * W + xb + 95].near(255, 255, 0),
        "B's picture: red, green over blue, yellow"
  check (px[(base - 30) * W + xb + 300] shr 24) == 0, "B's outline not drawn under its picture"
  let xc = int(lay.glyphs[2].x)
  check px[(base - 195) * W + xc + 45].near(255, 0, 0) and px[(base - 185) * W + xc + 55].near(255, 255, 0),
        "C's picture (CBDT) where its metrics put it"
  # the text's own colour where the palette says so
  var t2 = t
  t2.spans[0].style.color = 0xFF00AA00'u32
  let px2 = t2.renderText(W, H, lay)
  check px2[(base - 30) * W + x0 + 90].near(255, 0, 0), "a layer of its own colour: as it is, whatever the text's"
  let td = newText("D", CharStyle(family: "Color Test", size: 640, color: 0xFF00AA00'u32, hScale: 1, vScale: 1), 20, 700)
  let pd = td.renderText(W, H)
  check pd[(base - 256) * W + x0 + 320].near(0, 170, 0) and (pd[(base - 30) * W + x0 + 90] shr 24) == 0,
        "D: its layer in the text's colour (and its own outline not drawn)"
  # turned: the picture turned with it
  var g = lay.glyphs[1]
  g.angle = 90
  var lt = lay
  lt.glyphs = @[g]
  let tp = textOutlines(t, lt)
  check tp.len == 1 and tp[0].picture != nil and abs(tp[0].polys[0][1][1] - tp[0].polys[0][0][1]) > 15 and
        abs(tp[0].polys[0][1][0] - tp[0].polys[0][0][0]) < 1,
        "turned a quarter: the picture's top edge runs up"

block emojiFromTheFontFolders:
  # (a character no font of the text's has: from an emoji font in the font folders, when there is one)
  const noto = "/usr/share/fonts/truetype/noto/NotoColorEmoji.ttf"
  if fileExists(noto):
    let e = newText("Hi \u{1F600}\uFE0F", CharStyle(family: "", size: 109, color: 0xFF000000'u32, hScale: 1,
                                                      vScale: 1), 10, 150)
    let el = layoutText(e)
    var emoji = -1
    for i, g in el.glyphs:
      if g.face != nil and "Emoji" in g.face.family: emoji = i
    check emoji >= 0 and el.glyphs[emoji].isColorGlyph, "an emoji from Noto Color Emoji, in colour"
    var shown = 0
    for g in el.glyphs:
      if g.index == 4: inc shown
    check shown == 0, "its variation selector drawn as nothing"
    let ep = e.renderText(400, 220, el)
    var yellow = 0
    for c in ep:
      if (c shr 24) > 200 and ((c shr 16) and 255) > 200 and ((c shr 8) and 255) > 150 and (c and 255) < 90:
        inc yellow
    check yellow > 1500, "its face yellow (" & $yellow & " pixels)"
    # (a sun in FreeSans: as text alone, an emoji with U+FE0F after it)
    let plainSun = layoutText(newText("\u2600", CharStyle(family: "", size: 40, hScale: 1, vScale: 1)))
    let emojiSun = layoutText(newText("\u2600\uFE0F", CharStyle(family: "", size: 40, hScale: 1, vScale: 1)))
    check plainSun.glyphs.len == 1 and not plainSun.glyphs[0].isColorGlyph and
          emojiSun.glyphs.len == 1 and emojiSun.glyphs[0].isColorGlyph,
          "U+2600 as text; with U+FE0F, an emoji"
  else: echo "  (no Noto Color Emoji here: not tried)"

block inAPdf:
  let d = newDoc(1200, 500, 0xFFFFFFFF'u32, dpi = 72, name = "emoji")
  var st2 = st
  st2.size = 200
  discard d.addTextLayer(newText("ABC", st2, 20, 300))
  var plain = st2
  plain.family = ""
  plain.size = 60
  discard d.addTextLayer(newText("Hello", plain, 700, 300))
  d.markAll()
  let path = getTempDir() / "retro-colorfont.pdf"
  d.savePdf(path, pdfPreset(ppPrint))
  let pdfData = readFile(path)
  check "/Subtype /Image" in pdfData or "/Subtype/Image" in pdfData, "the pictures in it as pictures"
  check "/FontFile2" in pdfData, "the other letters still text"
  let back = importPdf(pdfData, "emoji", ImportOptions(ppi: 72))
  check back.w == 1200 and back.h == 500, "read back at its size"
  if back.layers.len > 0:
    let L = back.layers[0]
    let s = 200 / 640
    template at(x, y: float): uint32 = L.px[int(300 - y * s) * 1200 + int(20 + x * s)]
    check at(90, 30).near(255, 0, 0, 60), "A's red layer filled"
    check at(320, 256).near(0, 0, 255, 60), "A's blue layer over it"
    let xb = 20 + 200
    check L.px[int(300 - 55 * s) * 1200 + int(xb.float + 85 * s)].near(255, 0, 0, 70) and
          L.px[int(300 - 45 * s) * 1200 + int(xb.float + 95 * s)].near(255, 255, 0, 70),
          "B's picture there"
  removeFile(path)

block inSvg:
  let d = newDoc(800, 400, 0xFFFFFFFF'u32, name = "emoji")
  var st2 = st
  st2.size = 100
  let L = d.addTextLayer(newText("BC", st2, 20, 200))
  discard L
  d.markAll()
  let svg = d.svgOf(outlines = true)
  check svg.count("<image width=\"2\" height=\"2\"") == 2, "SVG (type as outlines): the pictures as pictures"

if failures > 0:
  echo "test_colorfonts: ", failures, " failed"
  quit(1)
echo "test_colorfonts: all passed"
