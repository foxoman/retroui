## Tests of styled text (retroui/textengine): fonts, layout, editing, drawing,
## warps, text on a path.

import std/[math, json, strutils, os]
import std/unicode except strip   # (its strip cuts letters: docs/nim-bugs.md)
import retroui/[textengine, ttf, typeset]

proc style(size = 40'f32): CharStyle =
  result = defaultStyle()
  result.size = size

proc inked(px: seq[uint32]): int =
  for p in px:
    if (p shr 24) > 0: inc result

block fonts:
  let fams = fontFamilies()
  doAssert "FreeSans" in fams and "FreeSerif" in fams and "FreeMono" in fams
  doAssert fams.find("FreeSans") < 3                   # (the built-in ones first)
  doAssert "Bold" in fontStyles("FreeSans") and "Oblique" in fontStyles("FreeSans")
  doAssert "Bold Italic" in fontStyles("FreeSerif")
  let f = fontFace("FreeSans", "Regular")
  doAssert f.face != nil and not f.fauxBold and not f.fauxItalic
  let unknown = fontFace("No Such Family", "Regular")
  doAssert unknown.face != nil
  # italics are the fonts' own, not slanted copies
  let it = fontFace("FreeSans", "Oblique")
  doAssert not it.fauxItalic and it.face.italic and it.face == face(fSansItalic)
  let it2 = fontFace("FreeSerif", "Italic")
  doAssert not it2.fauxItalic and it2.face == face(fSerifItalic)
  let fb = fontFace("FreeMono", "Bold")
  doAssert not fb.fauxBold and fb.face == face(fMonoBold)
  # the kit's fonts of before, named in documents, are drawn in FreeFont
  # (where they are not installed)
  doAssert fontFace("Amiri", "Regular").face.family in ["Amiri", "FreeSerif"]
  doAssert fontFace("Retro Sans", "Regular").face.family == "FreeSans"
  doAssert fontFace("Kawkab Mono", "Bold").face.family == "FreeMono"
  # the names of a face
  let fs = face(fSans)
  doAssert fs.family == "FreeSans"
  doAssert defaultStyle().family == "FreeSans" and defaultStyle().style == "Regular"

block layoutLine:
  var t = newText("Hello", style(), 10, 50)
  let l = layoutText(t)
  doAssert l.lines.len == 1
  doAssert l.glyphs.len == 5
  doAssert abs(l.lines[0].baseline - 50) < 0.01
  doAssert abs(l.x0 - 10) < 0.01 and abs(l.x1 - (10 + widthEm("Hello", fSans) * 40)) < 0.5
  # the caret goes left to right, and the end is the right edge
  for i in 1 .. 5: doAssert l.caretX[i] > l.caretX[i - 1]
  doAssert abs(l.caretX[5] - l.x1) < 0.01
  # a click finds the character
  for i in 0 .. 5: doAssert l.charAt(l.caretX[i] + 0.5, 45) == i
  # tracking: wider by 5 x 0.1 em
  var tr = t
  tr.restyle(0, 0, proc (s: var CharStyle) = s.tracking = 100)
  let lt = layoutText(tr)
  doAssert abs((lt.x1 - lt.x0) - (l.x1 - l.x0) - 5 * 4) < 0.5
  # kerning: "AV" closer than without it (FreeSerif kerns it; FreeSans 0412
  # does not)
  var ks = style()
  ks.family = "FreeSerif"
  var kv = newText("AVAV", ks, 0, 50)
  let k1 = layoutText(kv)
  kv.restyle(0, 0, proc (s: var CharStyle) = s.noKerning = true)
  let k0 = layoutText(kv)
  doAssert k1.x1 < k0.x1
  # horizontal scale
  var hs = t
  hs.restyle(0, 0, proc (s: var CharStyle) = s.hScale = 2)
  doAssert abs((layoutText(hs).x1 - 10) - 2 * (l.x1 - 10)) < 0.5
  # alignment of point text: the point is its middle, its right end
  var c = t
  c.para.align = textCenter
  let lc = layoutText(c)
  doAssert abs((lc.x0 + lc.x1) / 2 - 10) < 0.5
  c.para.align = textRight
  doAssert abs(layoutText(c).x1 - 10) < 0.5

block layoutBox:
  let words = "The quick brown fox jumps over the lazy dog and keeps running far away"
  var t = newText(words, style(20), 5, 5)
  t.boxW = 200
  t.boxH = 300
  let l = layoutText(t)
  doAssert l.lines.len >= 3
  for ln in l.lines: doAssert ln.x1 <= 205.5, $ln
  # the first baseline under the box's top by its ascent
  doAssert l.lines[0].baseline > 5 and l.lines[0].baseline - l.lines[0].ascent >= 4.9
  # justified: the lines but the last fill the box
  t.para.align = justifyLeft
  let lj = layoutText(t)
  for k in 0 ..< lj.lines.high: doAssert abs(lj.lines[k].x1 - 205) < 1, $lj.lines[k]
  doAssert lj.lines[^1].x1 < 204
  t.para.align = justifyAll
  let la = layoutText(t)
  doAssert abs(la.lines[^1].x1 - 205) < 1
  # right aligned in the box
  t.para.align = textRight
  for ln in layoutText(t).lines: doAssert abs(ln.x1 - 205) < 1
  # indents
  t.para.align = textLeft
  t.para.indentFirst = 30
  t.para.indentLeft = 10
  let li = layoutText(t)
  doAssert abs(li.lines[0].x0 - 45) < 0.5 and abs(li.lines[1].x0 - 15) < 0.5

block paragraphs:
  var t = newText("one\ntwo\n\nfour", style(20), 0, 30)
  t.para.spaceAfter = 10
  let l = layoutText(t)
  doAssert l.lines.len == 4, $l.lines.len
  doAssert abs(l.lines[1].baseline - l.lines[0].baseline - (24 + 10)) < 0.5
  # the caret after a new line at the end: a line of its own
  var e = newText("ab\n", style(20), 0, 30)
  let le = layoutText(e)
  doAssert le.lineOf(3) == 1
  doAssert le.lines.len == 2
  # leading
  var ld = newText("a\nb", style(20), 0, 30)
  ld.restyle(0, 0, proc (s: var CharStyle) = s.leading = 50)
  let ll = layoutText(ld)
  doAssert abs(ll.lines[1].baseline - ll.lines[0].baseline - 50) < 0.5
  # moving up and down, the line's ends
  doAssert l.lineMove(1, 1) in 4 .. 7
  doAssert l.lineStart(5) == 4

block editing:
  var t = newText("Hello", style())
  var red = style()
  red.color = 0xFFFF0000'u32
  t.insertText(5, " World", red)
  doAssert t.plainText == "Hello World"
  doAssert t.spans.len == 2
  doAssert t.styleAt(7).color == 0xFFFF0000'u32
  doAssert t.styleAt(1).color == 0xFF000000'u32
  t.restyle(0, 5, proc (s: var CharStyle) = s.color = 0xFFFF0000'u32)
  doAssert t.spans.len == 1                     # (one style: one span)
  t.deleteText(5, 11)
  doAssert t.plainText == "Hello"
  t.deleteText(0, 5)
  doAssert t.plainText == "" and t.spans.len == 1   # (the style stays for what is typed)
  t.insertText(0, "مرحبا", style())
  doAssert t.runeLen == 5
  doAssert t.wordRight(0) == 5 and t.wordLeft(5) == 0
  var w = newText("one two three", style())
  doAssert w.wordRight(0) == 3 and w.wordRight(3) == 7 and w.wordLeft(13) == 8

block caps:
  var t = newText("abc", style())
  let l0 = layoutText(t)
  t.restyle(0, 0, proc (s: var CharStyle) = s.allCaps = true)
  let l1 = layoutText(t)
  doAssert l1.x1 > l0.x1                          # (capitals are wider)
  doAssert l1.glyphs[0].gid == face(fSans).glyphOf(int('A'))
  t.restyle(0, 0, proc (s: var CharStyle) = (s.allCaps = false; s.smallCaps = true))
  let l2 = layoutText(t)
  doAssert l2.glyphs[0].size < 40 and l2.glyphs[0].gid == face(fSans).glyphOf(int('A'))
  var sup = newText("x2", style())
  sup.restyle(1, 2, proc (s: var CharStyle) = s.script = scSuper)
  let ls = layoutText(sup)
  doAssert ls.glyphs[1].y < ls.glyphs[0].y and ls.glyphs[1].size < ls.glyphs[0].size

block rightToLeft:
  var t = newText("مرحبا", style(), 300, 50)
  let l = layoutText(t)
  doAssert l.lines[0].rtl
  # the first character is drawn rightmost
  doAssert l.caretX[0] > l.caretX[4]
  # joined forms: no letter is drawn as its isolated form in the middle
  doAssert l.glyphs.len == 5

block drawing:
  var t = newText("Hi", style(), 10, 50)
  let px = t.renderText(120, 70)
  doAssert inked(px) > 100
  # the color, and nothing above the letters
  var red = 0
  for p in px:
    if (p shr 24) == 255 and (p and 0xFFFFFF) == 0: inc red
  doAssert red > 50
  for y in 0 ..< 8:
    for x in 0 ..< 120: doAssert px[y * 120 + x] == 0
  # without anti-aliasing: only whole pixels
  t.antialias = false
  for p in t.renderText(120, 70):
    doAssert (p shr 24) in [0'u32, 255'u32]
  # underline: ink under the baseline where there was none
  var u = newText("oo", style(), 10, 50)
  let a = u.renderText(120, 70)
  u.restyle(0, 0, proc (s: var CharStyle) = s.underline = true)
  let b = u.renderText(120, 70)
  var under = 0
  for y in 52 ..< 58:
    for x in 0 ..< 120:
      if (b[y * 120 + x] shr 24) > 0 and (a[y * 120 + x] shr 24) == 0: inc under
  doAssert under > 30
  # faux bold: more ink
  var fb = newText("Hi", style(), 10, 50)
  let n0 = inked(fb.renderText(120, 70))
  fb.restyle(0, 0, proc (s: var CharStyle) = s.fauxBold = true)
  doAssert inked(fb.renderText(120, 70)) > n0
  # into a picture: the pixels it touched
  var pic = newSeq[uint32](120 * 70)
  let box = newText("Hi", style(), 10, 50).renderTextInto(pic, 120, 70, layoutText(newText("Hi", style(), 10, 50)))
  doAssert box.x0 >= 10 and box.x1 <= 80 and box.y1 <= 52 and box.y0 >= 15

block warps:
  # no bend: no change
  for ws in WarpStyle:
    let w = TextWarp(style: ws, bend: 0)
    if ws in {wsArc, wsArch, wsBulge, wsFlag, wsWave, wsRise, wsFisheye, wsInflate, wsSqueeze, wsTwist}:
      let (x, y) = w.warpPoint(0.3, -0.4)
      doAssert abs(x - 0.3) < 1e-9 and abs(y + 0.4) < 1e-9, $ws
  # Arc up: the ends lower than the middle
  let arc = TextWarp(style: wsArc, bend: 50)
  doAssert arc.warpPoint(-1, 0)[1] < arc.warpPoint(0, 0)[1] - 0.1
  doAssert arc.warpPoint(1, 0)[1] < 0
  # Arch down: the middle lower
  let arch = TextWarp(style: wsArch, bend: -50)
  doAssert arch.warpPoint(0, 0)[1] < -0.2
  # Bulge: the middle taller
  let bulge = TextWarp(style: wsBulge, bend: 60)
  doAssert bulge.warpPoint(0, 1)[1] > 1.2
  # drawn warped: different pixels, about as many
  var t = newText("Warped", style(), 20, 60)
  let straight = t.renderText(300, 120)
  t.warp = TextWarp(style: wsFlag, bend: 60)
  let bent = t.renderText(300, 120)
  doAssert bent != straight
  doAssert abs(inked(bent) - inked(straight)) < inked(straight) div 3
  # the caret follows the warp
  let l = layoutText(t)
  let c = t.caretLine(l, 2)
  doAssert abs(c.x0 - c.x1) > 0.01 or abs(c.y0 - l.caretAt(2).top) > 0.5
  doAssert t.charAtDrawn(l, c.x0, (c.y0 + c.y1) / 2) == 2

block onAPath:
  var t = newText("Along a path", style(20), 0, 0)
  for i in 0 .. 50: t.path.add (float32(20 + i * 6), float32(80 - i * 1))
  t.pathOffset = 10
  doAssert t.onPath
  doAssert abs(t.pathLength - 50 * hypot(6.0, 1.0)) < 0.1
  let px = t.renderText(360, 120)
  doAssert inked(px) > 200
  # its ink lies just above the path
  var near, far = 0
  for y in 0 ..< 120:
    for x in 0 ..< 360:
      if (px[y * 360 + x] shr 24) > 128:
        let k = (x - 20) / 6
        let py = 80 - k
        if y.float <= py + 4 and y.float >= py - 24: inc near else: inc far
  doAssert far < near div 20, $near & " " & $far
  # past its end: not drawn
  t.pathOffset = 1000
  doAssert inked(t.renderText(360, 120)) == 0

block wholeText:
  var t = newText("Scale me", style(30), 10, 40)
  t.boxW = 100
  let s = t.scaled(2)
  doAssert s.x == 20 and s.y == 80 and s.boxW == 200 and s.spans[0].style.size == 60
  let m = t.moved(5, -5)
  doAssert m.x == 15 and m.y == 35
  doAssert t.layerName == "Scale me"
  doAssert newText("", style()).layerName == "Text"

block saving:
  var t = newText("Saved ", style(30), 10, 40)
  var b = style(30)
  b.style = "Bold"
  b.color = 0xFF00FF00'u32
  b.underline = true
  b.tracking = 50
  b.script = scSub
  b.hScale = 0.8
  t.insertText(t.runeLen, "text", b)
  t.para.align = justifyCenter
  t.para.indentFirst = 12
  t.boxW = 300
  t.boxH = 100
  t.warp = TextWarp(style: wsWave, bend: -30, hDistort: 10)
  t.antialias = false
  let back = textFrom(parseJson($t.toJson))
  doAssert back == t, $back
  var p = newText("p", style())
  p.path = @[(1'f32, 2'f32), (3'f32, 4'f32)]
  p.pathOffset = 7
  doAssert textFrom(p.toJson) == p
  # damaged: something to edit all the same
  doAssert textFrom(parseJson("{\"spans\": 3}")).spans.len == 1
  doAssert textFrom(nil).spans.len == 0


block arabicOnTheCanvas:
  # right-to-left text starts at the right: point text grows leftward from
  # its point; in a box, lines sit at the right; justified lines get
  # kashidas; digits as Arabic or Persian ones
  let st = CharStyle(family: "", size: 30, color: 0xFF000000'u32, hScale: 1, vScale: 1)
  let t1 = newText("مرحبا بالعالم", st, 400, 100)
  let l1 = layoutText(t1)
  doAssert l1.lines[0].rtl
  doAssert abs(l1.lines[0].x1 - 400) < 1 and l1.lines[0].x0 < 300, "ends at its point: " & $l1.lines[0].x0 & ".." & $l1.lines[0].x1
  var t2 = newText("سطر قصير", st, 100, 100)
  t2.boxW = 400
  t2.boxH = 100
  let l2 = layoutText(t2)
  doAssert abs(l2.lines[0].x1 - 500) < 1, "at the box's right: " & $l2.lines[0].x1
  # (Right in a right-to-left paragraph: its lines' ends, the left)
  t2.para.align = textRight
  doAssert abs(layoutText(t2).lines[0].x0 - 100) < 1
  # justified with kashidas: tatweel glyphs there; without, none
  var t3 = newText("هذا نص عربي طويل داخل صندوق يلتف على عدة أسطر ليختبر المحاذاة والضبط", st, 0, 0)
  t3.boxW = 420
  t3.boxH = 300
  t3.para.align = justifyLeft
  let withK = layoutText(t3).glyphs.len
  t3.para.noKashida = true
  let without = layoutText(t3).glyphs.len
  doAssert withK > without, "kashidas: " & $withK & " glyphs, " & $without & " without"
  # Latin text is not touched by any of it
  let t4 = newText("Hello", st, 400, 100)
  doAssert abs(layoutText(t4).lines[0].x0 - 400) < 1
  # digits
  var st2 = st
  st2.digits = 1
  let t5 = newText("2026", st2, 0, 0)
  let g5 = layoutText(t5).glyphs
  doAssert g5.len == 4
  let plain = layoutText(newText("2026", st, 0, 0)).glyphs
  doAssert g5[0].gid != plain[0].gid, "Arabic-Indic digits are other glyphs"
  doAssert charStyleFrom(st2.toJson).digits == 1

block kashidaRulesAndTashkeel:
  # the kashida goes where the scribes put it (after Seen: "سـ"), and the
  # tashkeel stays over its letter, not over the tatweel drawn out
  let st = CharStyle(family: "", size: 30, color: 0xFF000000'u32, hScale: 1, vScale: 1)
  var t = newText("مَسْجِدٌ كَبِيرٌ جِدًّا فِي وَسَطِ المَدِينَةِ", st, 0, 0)
  t.boxW = 600
  t.boxH = 200
  t.para.align = justifyAll
  let l = layoutText(t)
  var tatweels: seq[LaidGlyph]
  var marks: seq[LaidGlyph]
  var letters: seq[LaidGlyph]
  for g in l.glyphs:
    let cp = runeAtPos(t.spans[0].text, g.index).int
    if g.adv > 0 and g.hScale > 1.01: tatweels.add g
    elif cp in 0x064B .. 0x0652: marks.add g
    else: letters.add g
  doAssert tatweels.len > 0, "kashidas"
  # (the word "مَسْجِدٌ": its kashida after the Seen)
  let seen = runeOffset(t.spans[0].text, 0)
  discard seen
  var afterSeen = false
  for g in tatweels:
    var k = g.index
    while k > 0 and runeAtPos(t.spans[0].text, k).int in 0x064B .. 0x0652: dec k
    if runeAtPos(t.spans[0].text, k).int == 0x0633: afterSeen = true
  doAssert afterSeen, "after the Seen of masjid"
  # every mark drawn where its letter is, not out on a tatweel
  for m in marks:
    var k = m.index
    while k > 0 and runeAtPos(t.spans[0].text, k).int in 0x064B .. 0x0652: dec k
    var base: LaidGlyph
    for g in letters:
      if g.index == k: base = g
    doAssert abs(m.x - base.x) < 1.0, "the mark over its letter: " & $m.x & " vs " & $base.x

block columnsAndFlow:
  # text in a box in three columns: each line in one, side by side, from
  # the box's top; what does not fit: `overflow`, and the rest flows on
  let st = CharStyle(family: "", size: 20, color: 0xFF000000'u32, hScale: 1, vScale: 1)
  var words = ""
  for k in 0 ..< 120: words.add "word" & $k & " "
  var t = newText(words, st, 10, 20)
  t.boxW = 600
  t.boxH = 150
  t.columns = 3
  t.gutter = 30
  let l = layoutText(t)
  doAssert l.overflow > 0, "more than three columns hold"
  var xs: seq[float32]
  for ln in l.lines:
    doAssert ln.baseline - ln.ascent >= 20 - 0.5 and ln.baseline + ln.descent <= 170 + 1, $ln.baseline
    if ln.x0 notin xs: xs.add ln.x0
  doAssert xs.len == 3, "three columns: " & $xs
  let colW = (600'f32 - 60) / 3
  for ln in l.lines: doAssert ln.x1 - ln.x0 <= colW + 1
  # the rest of the text: from the first character not drawn
  let rest = t.remainder(l.overflow)
  doAssert rest.spans[0].text.startsWith(words.runeSubStr(l.overflow).strip(trailing = false)[0 .. 3])
  var all = 0
  for g in l.glyphs: all = max(all, g.index)
  doAssert all < l.overflow
  # one column, kept in its box (it flows on): the same idea
  var one = t
  one.columns = 1
  one.clipOverflow = true
  let lo = layoutText(one)
  doAssert lo.overflow > 0 and lo.lines.len > 0
  # saved and read back
  let back = textFrom(t.toJson)
  doAssert back.columns == 3 and abs(back.gutter - 30) < 1e-3

block openType:
  # Arabic in FreeSerif (built in): set by the font's OpenType tables --
  # joined forms, the lam-alef ligature, its marks placed by the font
  let st = CharStyle(family: "FreeSerif", style: "Regular", size: 40, color: 0xFF000000'u32, hScale: 1, vScale: 1)
  let plainLay = layoutText(newText("لا", st))
  let af = plainLay.glyphs[0].face
  doAssert plainLay.glyphs.len in 1 .. 2
  var nominalAll = true
  for g in plainLay.glyphs:
    if g.gid != af.glyphOf(0x0644) and g.gid != af.glyphOf(0x0627): nominalAll = false
  doAssert not nominalAll, "lam-alef: the font's own forms, not the nominal letters"
  let marked = layoutText(newText("بَ", st))
  doAssert marked.glyphs.len == 2
  doAssert abs(marked.glyphs[0].y - marked.glyphs[1].y) > 1 or abs(marked.glyphs[0].x - marked.glyphs[1].x) > 0.1,
    "the fatha placed by the font"
  # a feature turned off: the ligature taken apart
  var st2 = st
  st2.features = "-rlig -liga"
  let apart = layoutText(newText("لا", st2))
  doAssert apart.glyphs.len >= 1
  # a variable font at an axis: its letters wider or bolder
  addFontDir(currentSourcePath().parentDir / "data" / "fonts")
  scanFonts(force = true)
  let fams = fontFamilies()
  var vf = ""
  for f in fams:
    if "VarTest" in f or "Noto Sans Arabic" in f: vf = f
  if vf.len > 0:
    var a = CharStyle(family: vf, style: fontStyles(vf)[0], size: 40, color: 0xFF000000'u32, hScale: 1, vScale: 1)
    let la = layoutText(newText("abc بيت", a))
    a.variation = "wght=900"
    let lb = layoutText(newText("abc بيت", a))
    doAssert la.glyphs.len > 0 and lb.glyphs.len > 0
    doAssert la.glyphs[^1].face != lb.glyphs[^1].face, "the variable font at another weight"

block thai:
  # Thai in a document: its marks stacked as in the interface (FreeSans's
  # text takes FreeSerif's Thai; FreeSerif's has no Thai tables to shape it)
  for fam in ["", "FreeSerif"]:
    let st = CharStyle(family: fam, style: (if fam == "": "" else: "Regular"), size: 40,
                       color: 0xFF000000'u32, hScale: 1, vScale: 1)
    let alone = layoutText(newText("ก่", st))
    let stacked = layoutText(newText("กี่", st))
    doAssert alone.glyphs.len == 2 and stacked.glyphs.len == 3, $(alone.glyphs.len, stacked.glyphs.len)
    let base = alone.glyphs[0].y
    doAssert alone.glyphs[1].y > base, "a tone mark alone sits low: " & fam
    doAssert stacked.glyphs[2].y < base - 2, "over the vowel: " & fam & " " & $(stacked.glyphs[2].y, base)
    let tall = layoutText(newText("ปั", st))
    let normal = layoutText(newText("กั", st))
    doAssert tall.glyphs[1].x - tall.glyphs[0].x < normal.glyphs[1].x - normal.glyphs[0].x - 2, fam

echo "textengine ok"
