## Tests of the text engine (fonts, Arabic, bidi), shapes, the layout
## helpers, the new widgets and Markdown -- headless, on the fake driver.

import std/[strutils, tables, times, unicode, math, os]
import retroui
import retroui/[typeset, ttf, raster]
import retroui/uirelays/input
import harness

fakeDriver()
startApp("text", W, H)

# ---- fonts -----------------------------------------------------------------------------

block faces:
  # FreeSans: 1000 units to the em, Latin and the rest, no Arabic of its
  # own (FreeSerif's stands in); kerning from GPOS (the legacy table is
  # gone from the subsets)
  let f = face(fSans)
  doAssert f.unitsPerEm == 1000 and f.family == "FreeSans"
  doAssert f.glyphOf(ord('A')) != 0 and f.glyphOf(0x0628) == 0, "Latin, and no Arabic of its own"
  doAssert face(fSerif).glyphOf(0x0628) != 0 and face(fSerif).glyphOf(0xFE91) != 0, "FreeSerif's Arabic"
  doAssert face(fIcons).glyphOf(0xF07B) != 0, "the folder icon"
  doAssert f.tableRange("kern").at < 0 and f.hasKerning
  # (FreeSans 0412 kerns no Latin pairs; FreeSerif and the Oblique do)
  for id in [fSerif, fSerifBold, fSerifItalic, fSansItalic]:
    let k = face(id)
    doAssert k.kerning(k.glyphOf(ord('A')), k.glyphOf(ord('V'))) < 0, "A V kerns in " & $id
    doAssert k.kerning(k.glyphOf(ord('T')), k.glyphOf(ord('o'))) < 0, "T o kerns in " & $id
  # (the values fontTools reads from GPOS)
  let fs = face(fSerif)
  doAssert fs.kerning(fs.glyphOf(ord('A')), fs.glyphOf(ord('V'))) == -70
  doAssert fs.kerning(fs.glyphOf(ord('f')), fs.glyphOf(ord('f'))) == -50
  doAssert fs.kerning(fs.glyphOf(ord('n')), fs.glyphOf(ord('n'))) == 0
  let fi = face(fSansItalic)
  doAssert fi.kerning(fi.glyphOf(ord('r')), fi.glyphOf(ord('n'))) == -10
  doAssert widthEm("AV", fSerif) < widthEm("A", fSerif) + widthEm("V", fSerif)
  let m = f.render(f.glyphOf(ord('H')), 20)
  doAssert m.w > 5 and m.h > 10
  var full = 0
  for a in m.a:
    if a == 255: inc full
  doAssert full > 20, "the stems are solid"

block widths:
  doAssert textWidth("") == 0
  let a = textWidth("Hello")
  doAssert a > 20 and a < 60, $a
  let b = textWidth("Hello", style(size = 2.0))
  doAssert b >= 2 * a - 2 and b <= 2 * a + 2, $(a, b)
  doAssert textWidth("Hello", bold = true) >= a
  doAssert textWidth("WWW", style(mono = true)) == textWidth("iii", style(mono = true))
  doAssert lineHeight(style(size = 2.0)) > FontH * 3 div 2
  doAssert textWidth(nfFolder) > 0, "icons have width"

block arabic:
  let r = shape("بب")                  # beh beh: initial + final
  doAssert r.glyphs.len == 2 and r.rtl and not r.missing
  let f = face(fSerif)                  # (FreeSans has no Arabic: FreeSerif's)
  var gids: seq[int]
  for g in r.glyphs:
    gids.add int(g.gid)
    doAssert g.face == fSerif, $g.face
  doAssert f.glyphOf(0xFE91) in gids and f.glyphOf(0xFE90) in gids, $gids
  # visual order: the first letter (initial form) is on the right
  doAssert r.glyphs[0].gid == uint16(f.glyphOf(0xFE90))
  let la = shape("لا")                 # lam alef: one ligature
  doAssert la.glyphs.len == 1 and int(la.glyphs[0].gid) == f.glyphOf(0xFEFB)
  doAssert textIsRtl("مرحبا hello")
  doAssert not textIsRtl("hello مرحبا")
  doAssert not textIsRtl("123")

block bidi:
  # "ab ARABIC" in a left-to-right line: Latin first, the Arabic after it
  let f = face(fSans)
  let r = shape("ab بت")
  doAssert not r.rtl
  doAssert r.glyphs[0].gid == uint16(f.glyphOf(ord('a')))
  doAssert r.glyphs[0].x < r.glyphs[^1].x
  # numbers in Arabic text stay left to right
  let n = shape("ب 12")
  var order: seq[int]
  for g in n.glyphs:
    if g.gid == uint16(f.glyphOf(ord('1'))): order.add 1
    if g.gid == uint16(f.glyphOf(ord('2'))): order.add 2
  doAssert order == @[1, 2], $order
  # brackets around a number in Arabic text pair up
  let p = shape("ب (1)")
  doAssert p.glyphs.len == 5
  # an Arabic interface: a line that mixes Arabic with Latin and numbers
  # reads right to left ("1.0 GB" at the right, "252 GB" at the left); a
  # line without Arabic (a file's name) keeps left to right
  let mixed = "1.0 GB متاحة من 252 GB"
  doAssert not shape(mixed).rtl
  setRtlInterface(true)
  let m = shape(mixed)
  doAssert m.rtl
  var one, two = -1.0'f32
  for g in m.glyphs:
    if g.gid == uint16(f.glyphOf(ord('1'))) and one < 0: one = g.x
    if g.gid == uint16(f.glyphOf(ord('5'))): two = g.x
  doAssert one > two, "1.0 at the right of 252: " & $(one, two)
  doAssert not shape("notes (draft)!").rtl
  let v = visualCodepoints(mixed)
  doAssert v[^1].cp == ord('0') and v[^3].cp == ord('1'), "the line ends (at the right) with 1.0"
  setRtlInterface(false)
  doAssert not shape(mixed).rtl

block rasterizer:
  var r = newRaster(10, 10)
  r.line(2, 2, 2, 8)
  r.line(2, 8, 8, 8)
  r.line(8, 8, 8, 2)
  r.line(8, 2, 2, 2)
  let c = r.coverage()
  doAssert c[5 * 10 + 5] == 255 and c[0] == 0 and c[5 * 10 + 9] == 0

block textSize:
  let h = FontH
  setTextScale(150)
  doAssert FontH > h and textSize() > 12
  setTextScale(100)
  doAssert FontH == h

# ---- layout ------------------------------------------------------------------------------

var
  rects: seq[Rect]
  springR: Rect
  formR: Rect

block sizeClasses:
  doAssert sizeClass() == scMedium, "640 pixels wide"
  doAssert responsive(1, 2, 3) == 2
  doAssert columnsFor(200) == 3

block rows:
  view = proc () =
    rects.setLen(0)
    row([-1, -2]):
      discard button("A")
      rects.add ui.lastRect
      discard button("B")
      rects.add ui.lastRect
    row:
      label "left"
      spring()
      discard button("Right")
      springR = ui.lastRect
  run(3)
  doAssert abs(rects[1].w - 2 * rects[0].w) <= 2, $rects
  doAssert springR.x + springR.w >= W - 2 * Pad - 2, $springR

block adaptiveCols:
  view = proc () =
    rects.setLen(0)
    adaptive(180):
      for i in 0 ..< 5:
        card("Card " & $i):
          label "x"
        rects.add ui.lastRect
  run(3)
  doAssert rects[0].y == rects[1].y and rects[1].y == rects[2].y, "three in a row"
  doAssert rects[3].y > rects[0].y, "then the next row"

block smartForm:
  var s = ""
  view = proc () =
    form(0):
      field "Name:": edit s
      formR = ui.lastRect
  run(3)
  doAssert formR.x > Pad + textWidth("Name:"), "the label column fits the label"

block pageScroll:
  view = proc () =
    for i in 0 ..< 40:
      discard button("Button " & $i)
  run(3)
  doAssert ui.pageOn and ui.pageMax > 0
  queue.add Event(kind: MouseMoveEvent, x: 100, y: 100)
  queue.add Event(kind: MouseWheelEvent, y: -3)
  run(2)
  doAssert ui.pageY > 0, "the wheel scrolls the window's content"

block pageScrollBars:
  # fingers get the standard scroll bar too (not a thin indicator)
  ui.touch = true
  view = proc () =
    for i in 0 ..< 40:
      discard button("Button " & $i)
  ui.pageY = 0
  run(3)
  doAssert ui.pageOn
  let bx = W - SbW div 2
  # (the track is a white and gray checkerboard: two pixels side by side)
  doAssert px(bx, H div 2) != 0xFFFFFF or px(bx + 1, H div 2) != 0xFFFFFF,
    "a scroll bar at the right edge on touch screens"
  # its down arrow scrolls
  let y0 = ui.pageY
  down(bx, H - SbW div 2 - 1)
  run()
  up(bx, H - SbW div 2 - 1)
  run()
  doAssert ui.pageY > y0, "the arrow scrolls the page"
  ui.touch = false
  # a row of fixed widths wider than the window: a bar along the bottom
  var far: Rect
  view = proc () =
    row([400, 400]):
      discard button("Left")
      discard button("Far right")
      far = ui.lastRect
  ui.pageY = 0
  run(3)
  doAssert ui.pageMaxX > 0 and not ui.pageOn, "wider: scrolls sideways"
  doAssert px(W div 2, H - SbW div 2) != 0xFFFFFF or
           px(W div 2 + 1, H - SbW div 2) != 0xFFFFFF, "the bottom bar is drawn"
  let x0 = far.x
  queue.add Event(kind: MouseMoveEvent, x: 100, y: 50)
  queue.add Event(kind: MouseWheelEvent, y: -3)
  run(2)
  doAssert ui.pageX > 0 and far.x < x0, "the wheel scrolls sideways"
  # Tab to the far button brings it into view
  ui.pageX = 0
  run(2)                                   # ("Left" has the focus)
  key(KeyTab)
  run(2)
  doAssert far.x + far.w <= W, "the focused button is scrolled into view: " & $far
  # ... and down: Tab to a button below the window scrolls the page
  view = proc () =
    for i in 0 ..< 40:
      discard button("Button " & $i)
      if i == 30: far = ui.lastRect
  ui.pageX = 0
  ui.pageY = 0
  ui.focus = 0
  run(3)
  for i in 0 .. 30:
    key(KeyTab)
    run()
  run()
  doAssert far.y >= 0 and far.y + far.h <= H, "Tab scrolls down to the focus: " & $far
  view = proc () = discard button("small")
  run(3)
  doAssert ui.pageMaxX == 0 and ui.pageX == 0, "back to fitting"

block barsDoNotScroll:
  # a tool bar too narrow for its buttons (a "more" button at its right
  # end), a status bar drawn first and content down to it: no page bars
  ui.pageX = 0
  ui.pageY = 0
  var s = "text"
  view = proc () =
    toolbar:
      for i in 0 ..< 20:
        discard toolButton(pxCopy, "Copy " & $i)
    statusbar("Ready")
    scrollPanel -1:
      edit s
  run(4)
  doAssert ui.pageMaxX == 0 and not ui.pageOn,
    "bars and content that fills down to the status bar fit the window"

block uiScale:
  let c = CtrlH
  setUiScale(150)
  doAssert CtrlH > c and dp(10) == 15
  setUiScale(100)
  doAssert CtrlH == c

# ---- new widgets --------------------------------------------------------------------------

block switches:
  var on = false
  var seg = 0
  var q = "abc"
  var stars = 0
  view = proc () =
    toggle("Wi-Fi", on)
    rects.setLen(0)
    rects.add ui.lastRect
    segmented(["One", "Two", "Three"], seg)
    rects.add ui.lastRect
    searchBox(q)
    rects.add ui.lastRect
    rating(stars)
    rects.add ui.lastRect
  run(2)
  click(rects[0], 8)
  run()
  doAssert on
  click(rects[1], rects[1].w - 10)
  run()
  doAssert seg == 2
  click(rects[2], rects[2].w - 6)                  # the clear button
  run()
  doAssert q == ""
  click(rects[3], rects[3].w - 4)
  run()
  doAssert stars == 5

block expanderCard:
  var open = false
  var shown = false
  view = proc () =
    shown = false
    expander("More", open):
      shown = true
      label "inside"
    rects.setLen(0)
    rects.add ui.lastRect
  run(2)
  doAssert not shown
  key(KeyTab)
  key(KeyRight)
  run()
  doAssert open and shown

block chipsBadges:
  var ev: ChipEvent
  view = proc () =
    ev = chips(["a", "b"], [true, false], closable = true)
    badge("3")
    spinner()
  run(2)
  doAssert ev.clicked == -1

block lineViewer:
  var sel = 0
  var ev: LineViewEvent
  view = proc () =
    ev = lineView(1000, proc (i: int): string = "line " & $i, sel, height = 200,
                  numbers = true)
  run(2)
  key(KeyTab)
  key(KeyDown)
  key(KeyDown)
  run()
  doAssert sel == 2, $sel
  key(KeyC, {CtrlPressed})
  run()
  doAssert getClipboardText() == "line 2\n"

block colors:
  var c = color(0, 0, 0)
  doAssert hexOf(color(255, 128, 0)) == "#FF8000"
  doAssert parseHexColor("#0f0", c) and c == color(0, 255, 0)
  doAssert not parseHexColor("nope", c)

# ---- Markdown -----------------------------------------------------------------------------

const md = """
# Title

Some *text* with **bold** and a [link](http://x.org).

1. one
2. two
   - nested

- [ ] open
- [x] done

> quoted

```nim
echo 1
```

| A | B |
|:--|--:|
| 1 | 2 |

---
"""

block parse:
  let d = parseMarkdown(md)
  var kinds: seq[BlockKind]
  for b in d.blocks: kinds.add b.kind
  doAssert kinds == @[bkHeading, bkPara, bkList, bkList, bkQuote, bkCode, bkTable,
                      bkRule], $kinds
  doAssert d.blocks[0].level == 1 and d.blocks[0].text == "Title"
  doAssert d.blocks[2].ordered and d.blocks[2].kids.len == 2
  doAssert d.blocks[2].kids[1].kids[^1].kind == bkList, "nested list"
  doAssert d.blocks[3].kids[0].task == 0 and d.blocks[3].kids[1].task == 1
  doAssert d.tasks == 2
  doAssert d.blocks[5].lang == "nim" and d.blocks[5].text == "echo 1"
  doAssert d.blocks[6].rows.len == 2 and d.blocks[6].aligns == @['l', 'r']

block setextAndRefs:
  let d = parseMarkdown("Heading\n=======\n\nSee [the site][s].\n\n[s]: http://s.org\n")
  doAssert d.blocks[0].kind == bkHeading and d.blocks[0].level == 1
  doAssert d.refs["s"] == "http://s.org"

block tasks:
  var s = "- [ ] a\n- [ ] b\n"
  toggleTask(s, 1)
  doAssert s == "- [ ] a\n- [x] b\n", s
  toggleTask(s, 1)
  doAssert s == "- [ ] a\n- [ ] b\n"

block mdView:
  var ev: MdEvent
  var r: Rect
  view = proc () =
    ev = markdownView(md, height = 400)
    r = ui.lastRect
  run(2)
  doAssert ev.link == "" and ev.task == -1
  # find the link's pixels: blue-ish text in the first lines
  var found = false
  for y in r.y .. r.y + 120:
    for x in r.x .. r.x + r.w - 20:
      let p = px(x, y)
      if (p and 0xFF) >= 128 and ((p shr 16) and 0xFF) < 80 and
         ((p shr 8) and 0xFF) < 80: found = true      # (navy in the 3.1 colors)
  doAssert found, "the link is drawn in the link color"

proc inkIn(x0, x1, y0, y1: int): int =
  ## Dark pixels (text, a bullet, a rule) in the box.
  for y in y0 ..< y1:
    for x in x0 ..< x1:
      let p = px(x, y)
      if (p and 0xFF) < 100 and ((p shr 8) and 0xFF) < 100 and ((p shr 16) and 0xFF) < 100: inc result

block mdRightToLeft:
  # a list in Arabic: its bullets and words at the right; in English at the left
  var r: Rect
  for (md, rtl) in [("- بند أول\n- بند ثان\n", true), ("- first\n- second\n", false)]:
    view = proc () =
      discard markdownView(md, height = 200, w = 400)
      r = ui.lastRect
    run(2)
    let left = inkIn(r.x + 4, r.x + 140, r.y + 4, r.y + 60)
    let right = inkIn(r.x + r.w - 160, r.x + r.w - 20, r.y + 4, r.y + 60)
    if rtl: doAssert right > 0 and left == 0, "the list at the right: " & $(left, right)
    else: doAssert left > 0 and right == 0, "the list at the left: " & $(left, right)
  # a table in Arabic: its first column at the right (the short "F1" near the
  # right edge); in English at the left
  for (md, rtl) in [("| المفتاح | عمله |\n|---|---|\n| F1 | التعليمات |\n", true),
                    ("| Key | What it does |\n|---|---|\n| F1 | Help |\n", false)]:
    view = proc () =
      discard markdownView(md, height = 200, w = 400)
      r = ui.lastRect
    run(2)
    # (the text's columns in the second row: ink that is not a grid line)
    let rowH = lineHeight() + dp(12)
    let y0 = r.y + 4 + rowH + 4
    var lo = high(int)
    var hi = -1
    for x in r.x + 4 ..< r.x + r.w - 20:
      let ink = inkIn(x, x + 1, y0, y0 + rowH - 8)
      if ink > 0 and ink < rowH - 10:
        lo = min(lo, x)
        hi = max(hi, x)
    if rtl: doAssert hi > r.x + r.w - 70, "the first column at the right: " & $(lo, hi, r)
    else: doAssert lo < r.x + 60, "the first column at the left: " & $(lo, hi, r)

block wrapping:
  let words = wrapLines("one two three four five six", textWidth("one two three"))
  doAssert words[0] == "one two three", $words
  # a long path breaks after a "/" rather than inside a name
  let path = "/storage/emulated/0/Pictures/Holidays/IMG_20240101.jpg"
  let lines = wrapLines(path, textWidth("/storage/emulated/0/Pict"))
  doAssert lines.join("") == path, $lines
  doAssert lines[0].endsWith("/"), $lines
  for l in lines: doAssert textWidth(l) <= textWidth("/storage/emulated/0/Pict")
  # nothing to break at: cut where it must
  let solid = wrapLines(repeat('x', 200), 50)
  doAssert solid.join("") == repeat('x', 200) and solid.len > 2

block arabicEdgeCases:
  # tatweel and the zero width joiner join letters but have no forms
  for s in ["ـ", "بـب", "\u200Dب", "ب\u200D", "لا", "ل\u0651ا", "\u064Bب", "ﻻ"]:
    doAssert textWidth(s) >= 0
    doAssert wrapLines(s & " " & s, 20).len >= 1

block hostileMarkdown:
  # deep nesting and long runs of markup: shown (as text), quickly, no crash
  var hostile = @["> ".repeat(20000) & "x", "- ".repeat(20000) & "x",
                  "*".repeat(30000) & "x" & "*".repeat(30000),
                  "[".repeat(20000) & "x" & "](u)".repeat(2000), "![".repeat(20000),
                  "`".repeat(20000), "|".repeat(5000) & "\n|-|\n" & "|".repeat(5000)]
  var nested = ""
  for i in 0 ..< 400: nested.add " ".repeat(i * 2) & "- item\n"
  hostile.add nested
  for md in hostile:
    let t0 = epochTime()
    view = proc () = discard markdownView(md, height = 300)
    run(2)
    doAssert epochTime() - t0 < 5.0, "too slow: " & md[0 .. 20]

# ---- GNU FreeFont, the UI's fonts ---------------------------------------------------------------

proc solidColumns(x0, y0, w, h: int): int =
  ## Columns of the rectangle with half its height or more in pure black.
  for x in x0 ..< x0 + w:
    var col = 0
    for y in y0 ..< y0 + h:
      if px(x, y) == 0: inc col
    if col >= h div 2: inc result

proc darkColumns(x0, y0, w, h: int; limit = 0x50'u32): int =
  ## Columns of the rectangle with half its height or more darker than
  ## `limit` (a stem: gray text draws one a little over a pixel as it is,
  ## on one column or shared by two).
  for x in x0 ..< x0 + w:
    var col = 0
    for y in y0 ..< y0 + h:
      if (px(x, y) and 0xFF) <= limit: inc col
    if col >= h div 2: inc result

proc colored(x0, y0, w, h: int): bool =
  ## Some pixel of the rectangle is not gray (the screen's color strips).
  for y in y0 ..< y0 + h:
    for x in x0 ..< x0 + w:
      let p = px(x, y)
      if ((p shr 16) and 0xFF) != (p and 0xFF): return true

block freeSans:
  view = proc () = discard
  setZoom(0)
  setTextScale(100)
  doAssert uiFont() == ufSans, "the default font"
  doAssert $ufSans == "FreeSans" and $ufSerif == "FreeSerif" and $ufMono == "FreeMono"
  doAssert builtinUiFonts == @[ufSans, ufSerif, ufMono]
  doAssert fontName(faceOf(TextStyle())) == "FreeSans" and builtinFace(fSans)
  run(2)
  # the line from the font: FreeSans's ascent, descent and line gap
  # (0.9 + 0.2 + 0.1 em), as a font file's always were
  doAssert textSize() == DesktopTextEm and DesktopTextEm == 12
  doAssert FontH == int(round(12 * (lineFactor(fSans, withGap = true) + 0.02))), $FontH
  doAssert FontH == 15 and FontAscent == 12, $(FontH, FontAscent)
  # every Latin-1 and Latin Extended-A letter in all four styles
  for cp in 0xA1 .. 0x17F:
    if cp == 0xAD: continue
    for id in [fSans, fSansBold, fSansItalic, fSansBoldItalic]:
      doAssert face(id).glyphOf(cp) != 0, $id & " U+" & toHex(cp, 4)
  for s in ["€", "…", "•", "‹", "›", "„", "‚", "™", "→", "≤", "Ω", "Ж", "ש", "■", "▸", "═"]:
    doAssert face(fSans).hasGlyph(s.runeAt(0).int), s
  # (what FreeSans lacks, FreeSerif or FreeMono has: ✓ ✗ ★)
  for s in ["✓", "✗", "★", "☐", "♥"]:
    doAssert not shape(s).missing and not shape(s, fSansBoldItalic).missing, s
  # vector text: twice the size, twice the width (within a pixel or two)
  let w1 = textWidth("Hello")
  doAssert abs(textWidth("Hello", style(size = 2.0)) - 2 * w1) <= 2

block realStyles:
  # bold, italic and bold italic are FreeSans Bold, Oblique and Bold Oblique
  # -- the fonts' own, not the regular thickened or slanted
  doAssert faceOf(style(bold = true)) == fSansBold
  doAssert faceOf(style(italic = true)) == fSansItalic
  doAssert faceOf(style(bold = true, italic = true)) == fSansBoldItalic
  doAssert faceOf(style(mono = true, italic = true)) == fMonoItalic
  doAssert faceOf(style(serif = true, bold = true, italic = true)) == fSerifBoldItalic
  for (id, st) in [(fSansBold, "Bold"), (fSansItalic, "Oblique"), (fSansBoldItalic, "Bold Oblique"),
                   (fSerifItalic, "Italic"), (fMonoBoldItalic, "Bold Oblique")]:
    doAssert face(id).style == st and face(id) != face(regularOf(id)), $id
    doAssert fauxStyle(id) == (false, false), $id
  doAssert face(fSansItalic).italic and face(fSansBold).weight >= 600
  # an italic line has the italic's own widths
  doAssert textWidth("Hello world", style(italic = true)) != textWidth("Hello world") or
           widthEm("Hello world", fSansItalic) != widthEm("Hello world", fSans)
  # drawn: the oblique's pixels are not the regular's
  view = proc () =
    text(10, 10, "Hamburg", color(0, 0, 0))
    text(10, 40, "Hamburg", color(0, 0, 0), style(italic = true))
    text(10, 70, "Hamburg", color(0, 0, 0), style(bold = true, italic = true))
  run(3)
  var same = true
  for y in 0 ..< FontH:
    for x in 0 ..< 60:
      if px(10 + x, 10 + y) != px(10 + x, 40 + y): same = false
  doAssert not same

block crisp:
  # at 100 % the stems of H and l are dark columns (gray, as the font
  # draws them), the baseline and cap height on whole rows
  view = proc () = text(10, 10, "HlHl", color(0, 0, 0))
  run(3)
  doAssert darkColumns(10, 10, textWidth("HlHl"), FontH, 0x90) >= 6,
           $darkColumns(10, 10, textWidth("HlHl"), FontH, 0x90)
  doAssert not colored(10, 10, textWidth("HlHl"), FontH), "gray by default"
  var bottom = -1
  for y in 10 ..< 10 + FontH:
    for x in 10 ..< 10 + textWidth("HlHl"):
      if px(x, y) == 0: bottom = y
  doAssert bottom == 10 + FontAscent - 1, $(bottom, FontAscent)
  # and at 125 %, 150 % and 200 % (twice the pixels)
  for (z, sc) in [(0, 125), (0, 150), (2, 100)]:
    setZoom(z)
    setTextScale(sc)
    view = proc () = text(5, 5, "HlHl", color(0, 0, 0))
    run(3)
    let s = if z == 2: 2 else: 1
    doAssert darkColumns(5 * s, 5 * s, textWidth("HlHl") * s, FontH * s, 0x90) >= 6, $(z, sc)
  setZoom(0)
  setTextScale(100)
  run(2)
  # Sharp text: the screen's color strips, the stems fitted to the pixels
  doAssert not subpixelText()
  setSubpixelText(true)
  view = proc () = text(10, 10, "HlHl", color(0, 0, 0))
  run(3)
  doAssert colored(10, 10, textWidth("HlHl"), FontH), "in the color strips"
  doAssert darkColumns(10, 10, textWidth("HlHl"), FontH) >= 6
  setSubpixelText(false)
  run(2)

block arabicEverywhere:
  # Arabic in every face draws real glyphs, joined: FreeSerif's for FreeSans
  # (its bold for bold), FreeMono's own in its regular, FreeSerif's in its
  # other styles
  let word = "مرحبا بكم"
  for (base, want) in [(fSans, fSerif), (fSansBold, fSerifBold), (fSansItalic, fSerif),
                       (fSansBoldItalic, fSerifBold), (fSerif, fSerif), (fSerifBold, fSerifBold),
                       (fSerifItalic, fSerif), (fMono, fMono), (fMonoBold, fSerifBold),
                       (fMonoItalic, fSerif), (fMonoBoldItalic, fSerifBold)]:
    let r = shape(word, base)
    doAssert not r.missing and r.rtl, $base
    for g in r.glyphs:
      if g.gid == uint16(face(g.face).glyphOf(32)): continue
      doAssert g.face == want and g.gid != 0, $base & ": " & $g.face
    # joined: the beh of بكم is in its initial form, the meem final
    let f = face(want)
    var gids: seq[int]
    for g in r.glyphs: gids.add int(g.gid)
    doAssert f.glyphOf(0xFE91) in gids and f.glyphOf(0xFEE2) in gids, $base
  # drawn, in bold and in a text box: ink, nothing measured as missing
  view = proc () =
    label "ملف جديد (12)", bold = true
    var t = "تحرير النص"
    discard edit(t, w = 200)
  run(3)
  var ink = 0
  for y in 0 ..< 60:
    for x in 0 ..< 220:
      if px(x, y) == 0: inc ink
  doAssert ink > 30, $ink
  doAssert textWidth("بب", bold = true) > 0 and hasGlyphs("مرحبا", fSansBold)

block thaiAndVietnamese:
  # Vietnamese in all twelve faces; Thai from FreeSerif (its bold for bold),
  # its marks stacked: a tone mark over a vowel above (กี่) higher than over
  # its letter alone (ก่), the marks of a tall letter (ปั้) left of its stem,
  # a vowel under a letter with a tail (ฎุ) under the tail
  for id in fSans .. fMonoBoldItalic:
    doAssert face(id).glyphOf(0x1EBF) != 0 and face(id).glyphOf(0x1EF9) != 0, $id
  doAssert hasGlyphs("Tiếng Việt: Xin chào thế giới") and hasGlyphs("Đồng hồ", fMonoBoldItalic)
  doAssert hasGlyphs("สวัสดีครับ") and hasGlyphs("ภาษาไทย", fSansBold)
  let th = shape("สวัสดี")
  doAssert not th.missing and not th.rtl
  for g in th.glyphs: doAssert g.face == fSerif, $g.face
  for g in shape("สวัสดี", fSansBold).glyphs: doAssert g.face == fSerifBold, $g.face
  proc markOf(s: string; base = fSans): PGlyph =
    let r = shape(s, base)
    r.glyphs[^1]
  let alone = markOf("ก่")
  let overVowel = markOf("กี่")
  doAssert alone.y < 0 and overVowel.y > 0.05, $(alone.y, overVowel.y)
  doAssert markOf("ก่ำ".runeSubStr(0, 2)).y == alone.y
  let am = shape("น้ำ")
  doAssert am.glyphs[1].y > alone.y + 0.1, "the tone over sara am's circle: " & $am.glyphs[1].y
  let normal = shape("กั")
  let tall = shape("ปั")
  doAssert tall.glyphs[1].x - tall.glyphs[0].x < normal.glyphs[1].x - normal.glyphs[0].x - 0.05,
           "left of the stem"
  doAssert markOf("ฎุ").y < -0.15 and markOf("กุ").y == 0
  # caret steps and word letters: a letter and its marks are one
  doAssert isMark(0x0E35) and isMark(0x0E48) and not isMark(0x0E33)
  doAssert clusterAfter("กี่ข", 0) == "กี่".len and clusterBefore("กี่ข", "กี่".len) == 0
  # drawn
  view = proc () =
    label "ภาษาไทย ที่นี่"
    label "Tiếng Việt", bold = true
  run(3)
  var ink = 0
  for y in 0 ..< 50:
    for x in 0 ..< 200:
      if px(x, y) == 0: inc ink
  doAssert ink > 30, $ink

block switchFonts:
  let h = FontH
  setUiFont(ufMono)
  view = proc () = discard button("OK")
  run(2)
  doAssert uiFont() == ufMono and faceOf(TextStyle()) == fMono
  doAssert FontH == int(round(textSize() * (lineFactor(fMono) + 0.02))), "FreeMono's own line"
  doAssert textWidth("iii") == textWidth("WWW"), "monospaced"
  var s: Settings
  storeAppearance(s)
  doAssert s.getOrDefault("look.font") == "mono" and s.getOrDefault("look.fontv") == "3"
  setUiFont(ufSerif)
  run(2)
  doAssert faceOf(TextStyle()) == fSerif and faceOf(style(mono = true)) == fMono
  restoreAppearance(s)
  run(2)
  doAssert uiFont() == ufMono
  setUiFont(ufSans)
  run(2)
  doAssert FontH == h

block oldSettings:
  # the fonts of before: their words still read (FreeSans or FreeMono) --
  # and a store from before FreeFont ("look.fontv" under 3) is the default,
  # FreeSans, whatever it named; a font from a file stays one
  var f: UiFont
  for (key, want) in [("w98", ufSans), ("retro", ufSans), ("smooth", ufSans), ("opensans", ufSans),
                      ("kawkab", ufMono), ("fixedsys", ufMono), ("sans", ufSans), ("serif", ufSerif),
                      ("mono", ufMono), ("system", ufSans)]:
    doAssert uiFontOfKey(key, f) and f == want, key
  doAssert not uiFontOfKey("file", f) and not uiFontOfKey("nonsense", f)
  for u in UiFont:
    if u != ufFile: doAssert uiFontOfKey(uiFontKey(u), f) and f == u, $u
  for (font, v) in [("w98", "2"), ("kawkab", "2"), ("kawkab", ""), ("fixedsys", "2"), ("opensans", "2"),
                    ("retro", ""), ("smooth", "2")]:
    var old: Settings
    old["look.font"] = font
    if v.len > 0: old["look.fontv"] = v
    setUiFont(ufSerif)
    restoreAppearance(old)
    doAssert uiFont() == ufSans, font & " " & v
  var chosen: Settings
  chosen["look.font"] = "serif"
  chosen["look.fontv"] = "3"
  restoreAppearance(chosen)
  doAssert uiFont() == ufSerif, "a choice made now is kept"
  setUiFont(ufSans)
  # the old names compile (deprecated) as the fonts that took their place
  {.push warning[Deprecated]: off.}
  doAssert ufW98 == ufSans and ufRetro == ufSans and ufSmooth == ufSans and ufOpenSans == ufSans
  doAssert ufKawkab == ufMono and ufFixedsys == ufMono
  {.pop.}
  run(2)

block wrappedLinesKeepTheParagraphDirection:
  # an English paragraph wrapped so that a line starts with Arabic: that
  # line is still laid out from the left (and the other way round)
  let p = "Their Arabic is what letters say: a tag as #[الجنسية]# gives عماني for Omani people here."
  var lines: seq[string]
  view = proc () =
    lines = wrapLines(p, 120)
  run(1)
  doAssert lines.len > 2
  for l in lines: doAssert not textIsRtl(l), "line read from the right: " & l
  let q = "تشهد إدارة الفندق بأن السيد أحمد يعمل لدينا بوظيفة Receptionist منذ عام 2018 وما زال"
  view = proc () =
    lines = wrapLines(q, 90)
  run(1)
  for l in lines: doAssert textIsRtl(l), "line read from the left: " & l

# ---- a font from a file ------------------------------------------------------------------------------------

block fontFile:
  view = proc () = discard
  let dir = currentSourcePath().parentDir.parentDir / "src" / "retroui" / "fonts"
  # FreeSerif as the user's font, given as bytes: its own Arabic
  setUiFontFile(readFile(dir / "FreeSerif.ttf"), readFile(dir / "FreeSerifBold.ttf"))
  run(2)
  doAssert uiFont() == ufFile and hasUserFont() and faceOf(TextStyle()) == fUser
  doAssert face(fUser).family == "FreeSerif" and fauxStyle(fUserBold) == (false, false)
  doAssert fauxStyle(fUserItalic) == (false, true), "no italic given: the regular slanted"
  doAssert fauxStyle(fUserBoldItalic) == (false, true), "made from its bold"
  for g in shape("مرحبا", fUser).glyphs: doAssert g.face == fUser
  doAssert textWidth("Hello", bold = true) > 0
  # a font without Arabic: FreeSerif's stands in, joined
  setUiFontFile(readFile(dir / "FreeSans.ttf"))
  doAssert fauxStyle(fUserBold) == (true, false), "no bold given: the regular thickened"
  doAssert widthEm("Hello", fUserBold) > widthEm("Hello", fUser), "a little wider, as FreeType makes it"
  let r = shape("بكم", fUser)
  doAssert not r.missing
  for g in r.glyphs: doAssert g.face == fSerif
  for g in shape("بكم", fUserBold).glyphs: doAssert g.face == fSerifBold
  view = proc () = text(10, 10, "مرحبا Hello", color(0, 0, 0), style(bold = true))
  run(3)
  var ink = 0
  for y in 8 ..< 30:
    for x in 8 ..< 150:
      if px(x, y) == 0: inc ink
  doAssert ink > 20
  # not a font
  var failed = false
  try: setUiFontFile("not a font at all, really not")
  except FontError: failed = true
  doAssert failed and uiFont() == ufFile
  # kept, and found again -- its bold, italic and bold italic beside it
  let tmp = getTempDir() / "retro-fonts"
  createDir(tmp)
  writeFile(tmp / "Mine-Regular.ttf", readFile(dir / "FreeSans.ttf"))
  writeFile(tmp / "Mine-Bold.ttf", readFile(dir / "FreeSansBold.ttf"))
  writeFile(tmp / "Mine-Italic.ttf", readFile(dir / "FreeSansOblique.ttf"))
  writeFile(tmp / "Mine-BoldItalic.ttf", readFile(dir / "FreeSansBoldOblique.ttf"))
  doAssert boldBeside(tmp / "Mine-Regular.ttf") == tmp / "Mine-Bold.ttf"
  doAssert styleBeside(tmp / "Mine-Regular.ttf", false, true) == tmp / "Mine-Italic.ttf"
  doAssert styleBeside(tmp / "Mine-Regular.ttf", true, true) == tmp / "Mine-BoldItalic.ttf"
  loadUiFontFile(tmp / "Mine-Regular.ttf")
  for id in [fUserBold, fUserItalic, fUserBoldItalic]: doAssert fauxStyle(id) == (false, false), $id
  doAssert face(fUserBoldItalic).style == "Bold Oblique"
  var st: Settings
  storeAppearance(st)
  doAssert st.getOrDefault("look.font") == "file" and st.getOrDefault("look.fontfile") == tmp / "Mine-Regular.ttf"
  setUiFont(ufMono)
  restoreAppearance(st)
  doAssert uiFont() == ufFile and face(fUser).family == "FreeSans"
  # a font file stored before FreeFont stays a font file
  st["look.fontv"] = "2"
  setUiFont(ufMono)
  restoreAppearance(st)
  doAssert uiFont() == ufFile
  removeDir(tmp)
  setUiFont(ufSans)
  run(2)

echo "text tests passed"

block rasterOddNumbers:
  # NaN, infinite and absurdly large coordinates (a chart of NaN, a path
  # scaled by nothing): no area, and nothing written outside the raster
  var r = newRaster(64, 48)
  let nan = NaN.float32
  let inf = Inf.float32
  for (a, b, c, d) in [(nan, 0'f32, 10'f32, 40'f32), (0'f32, nan, 10'f32, 40'f32),
                       (inf, 0'f32, 10'f32, 40'f32), (-inf, 5'f32, 30'f32, 20'f32),
                       (1e35'f32, 0'f32, -1e35'f32, 40'f32), (5'f32, -1e35'f32, 6'f32, 1e35'f32),
                       (10'f32, 1e-7'f32, 1e37'f32, 1e-5'f32), (-1e30'f32, -1e30'f32, 1e30'f32, 1e30'f32)]:
    r.line(a, b, c, d)
    r.edge(a, b, c, d)
  # a real square still fills as it should next to them
  r.edge(8, 8, 24, 8); r.edge(24, 8, 24, 24); r.edge(24, 24, 8, 24); r.edge(8, 24, 8, 8)
  r.accumulate()
  doAssert r[16 * 64 + 16] > 0.99
  for i in 0 ..< 64 * 48:
    let v = r[i]
    doAssert v == v and v >= 0 and v <= 1, $i
