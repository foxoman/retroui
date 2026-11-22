## Tests of styled text (retroui/textengine): fonts, layout, editing, drawing,
## warps, text on a path.

import std/[math, json, strutils, os]
import std/unicode except strip   # (its strip cuts letters: docs/nim-bugs.md)
import retroui/[textengine, ttf, typeset, hyphenate, unpacking, dastkhat, pdf]

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

block arabicSetFiner:
  # the room between words; the tashkeel in a color of its own, raised, left out
  var st = CharStyle(family: "", size: 40, color: 0xFF000000'u32, hScale: 1, vScale: 1)
  var t = newText("كِتَابٌ جَدِيدٌ", st, 10, 60)
  let plain = layoutText(t)
  t.spans[0].style.wordSpace = 500
  let wide = layoutText(t)
  doAssert abs((wide.x1 - wide.x0) - (plain.x1 - plain.x0) - 20) < 0.5, "half an em more at the one space"
  t.spans[0].style.wordSpace = 0
  t.spans[0].style.markColor = 0xFFC00000'u32
  t.spans[0].style.markRaise = 4
  let marked = layoutText(t)
  doAssert marked.glyphs.len == plain.glyphs.len
  var marks = 0
  for i, g in marked.glyphs:
    if g.color == 0xFFC00000'u32:
      inc marks
      doAssert abs(plain.glyphs[i].y - g.y - 4) < 0.01, "raised"
    else:
      doAssert g.color == 0xFF000000'u32 and g.y == plain.glyphs[i].y, "the letters as they were"
  doAssert marks == 6, "six tashkeel: " & $marks
  t.spans[0].style.noMarks = true
  let bare = layoutText(t)
  doAssert bare.glyphs.len == plain.glyphs.len - 6
  doAssert abs((bare.x1 - bare.x0) - (plain.x1 - plain.x0)) < 2, "as wide without them"
  # kept in a document
  let back = charStyleFrom(t.spans[0].style.toJson)
  doAssert back.markColor == 0xFFC00000'u32 and back.markRaise == 4 and back.noMarks and back.wordSpace == 0
  # Latin accents typed as marks are marks too
  var l = newText("e\u0301", st, 0, 50)
  l.spans[0].style.markColor = 0xFF0000FF'u32
  var blue = 0
  for g in layoutText(l).glyphs:
    if g.color == 0xFF0000FF'u32: inc blue
  doAssert blue <= 1

block dastkhatCarried:
  # (Dastkhat carried: one variable font, its nine weights styles of the family, a weight drawn
  # by its axis -- not made bold --, Arabic, Persian and Latin in it, PDF given its outlines)
  carryDastkhat()
  doAssert DastkhatFamily in fontFamilies()
  doAssert fontStyles(DastkhatFamily) == @["Thin", "ExtraLight", "Light", "Regular", "Medium", "SemiBold",
                                          "Bold", "ExtraBold", "Black"], $fontStyles(DastkhatFamily)
  let reg = fontFace(DastkhatFamily, "Regular")
  let bold = fontFace(DastkhatFamily, "Bold")
  doAssert not reg.face.isInstance and bold.face.isInstance and not bold.fauxBold
  let a = reg.face.glyphOf(ord('m'))
  doAssert bold.face.advance(a) == 1650 and reg.face.advance(a) == 1670, "its axis' advances (as fontTools)"
  doAssert bold.face.bounds(a).x1 - bold.face.bounds(a).x0 > reg.face.bounds(a).x1 - reg.face.bounds(a).x0,
           "Bold's strokes heavier"
  doAssert fontFace(DastkhatFamily, "Black").face == fontFace(DastkhatFamily, "Black").face
  doAssert fontFace(DastkhatFamily, "Bold Italic").fauxItalic and fontFace(DastkhatFamily, "Bold Italic").face.isInstance
  for r in "العربية كتب يوم فارسی پگچژ Latin ٠١٢ ۴۵۶".runes:
    if r != Rune(' '): doAssert reg.face.glyphOf(int(r)) != 0, "missing " & $r
  doAssert reg.face.glyphOf(0x0416) == 0          # (Cyrillic: the kit's fonts draw it)
  doAssert canEmbed(reg.face) and not canEmbed(bold.face), "an instance's outlines go to a PDF as drawn"
  var st = defaultStyle()
  st.family = DastkhatFamily
  st.style = "SemiBold"
  let t = newText("Retro مرحبا سلام Жук", st)
  doAssert layoutText(t).glyphs.len > 10

block dotsAreTheLettersNotTashkeel:
  # a font that builds ب ت ي ق... from a dotless letter and dot glyphs (Reem Kufi: the dots are
  # mark glyphs, placed by `mark`): the tashkeel's color, raise and "without tashkeel" leave them
  # with their letter -- raised 24 px, the dots under ي went into the letter's own ink, those over
  # ق floated with the tashkeel (a tablet, Reem Kufi at 150 px)
  addFontData("Reem Kufi Test", "Regular",
              readFile(currentSourcePath().parentDir / "data" / "fonts" / "ReemKufi-Subset.ttf"))
  let st = CharStyle(family: "Reem Kufi Test", size: 60, color: 0xFF000000'u32, hScale: 1, vScale: 1)
  let voweled = "الْخَيْلُ وَاللَّيْلُ وَالْقَلَمُ بِئْرٌ"
  var bareText = ""
  for r in voweled.runes:
    if int(r) notin 0x064B .. 0x0652: bareText.add r
  let letters = layoutText(newText(bareText, st, 10, 80)).glyphs.len
  var t = newText(voweled, st, 10, 80)
  let plain = layoutText(t)
  doAssert plain.glyphs.len > letters
  t.spans[0].style.markColor = 0xFFC00000'u32
  t.spans[0].style.markRaise = 24
  let marked = layoutText(t)
  var red, black = 0
  for i, g in marked.glyphs:
    if g.color == 0xFFC00000'u32:
      inc red
      doAssert abs(plain.glyphs[i].y - g.y - 24) < 0.01
    else:
      inc black
      doAssert g.y == plain.glyphs[i].y and g.x == plain.glyphs[i].x, "a letter or its dots moved"
  doAssert black == letters, "the letters with all their dots: " & $black & " of " & $letters
  doAssert red == plain.glyphs.len - letters
  t.spans[0].style.noMarks = true
  doAssert layoutText(t).glyphs.len == letters, "without tashkeel: the dots stay"

block rightToLeftLinesStayInTheirBox:
  # a line broken at a space: the space hangs out at the line's end (its left), the letters
  # start at the box's right edge -- every line, not only the last
  var t = newText("كان يا ما كان في قديم الزمان بحار يحب البحر ويعرف نجومه واحدة واحدة كل صباح يرفع شراعه",
                  CharStyle(family: "", size: 21, color: 0xFF000000'u32, hScale: 1, vScale: 1), 0, 0)
  t.boxW = 300
  t.boxH = 400
  t.para.rtl = 2
  for align in [textLeft, justifyLeft]:
    t.para.align = align
    let l = layoutText(t)
    doAssert l.lines.len >= 3
    for line in l.lines:
      doAssert abs(line.x1 - 300) < 0.6, $align & ": a line ends at " & $line.x1
    for g in l.glyphs: doAssert g.x + g.adv <= 300.6, "a letter past the box's right edge"

block aTextOfNoSpans:
  # nothing to set: no lines of letters, and no crash (a box that takes what did not fit
  # another one, when all of it fit)
  var t: TextData
  t.boxW = 200
  t.boxH = 100
  doAssert layoutText(t).glyphs.len == 0
  t.columns = 2
  doAssert layoutText(t).glyphs.len == 0
  t.holes = @[(50'f32, 0'f32, 80'f32, 40'f32)]
  doAssert layoutText(t).glyphs.len == 0
  var p: TextData
  doAssert layoutText(p).glyphs.len == 0
  doAssert renderText(t, 64, 64).len == 64 * 64

block listsInABox:
  # a mark before every paragraph that says something; the text stands in from it; marks
  # are numbered in any style; right-to-left lists have theirs at the right
  let st = CharStyle(family: "", size: 20, color: 0xFF000000'u32, hScale: 1, vScale: 1)
  var t = newText("First point, long enough to go on to a second line of the box\nSecond\n\nThird", st, 10, 10)
  t.boxW = 300
  t.boxH = 300
  let plain = layoutText(t)
  t.para.list = lkBullet
  let l = layoutText(t)
  doAssert l.lines.len >= 5
  # three marks (the empty paragraph has none), each at the box's left, on its line's baseline
  var marks: seq[LaidGlyph]
  for g in l.glyphs:
    if g.x < 10 + 20: marks.add g
  doAssert marks.len == 3, $marks.len
  doAssert l.glyphs.len == plain.glyphs.len + 3
  doAssert marks[0].y == l.lines[0].baseline and abs(marks[0].x - 10) < 4
  # every line of the text stands in: the second line of the first point too
  for line in l.lines:
    if line.last > line.first: doAssert line.x0 >= 10 + 30, "a line under the marks: " & $line.x0
  # numbers: 1. 2. 3.; from 4 in Roman numerals with a bracket; in a color of their own
  t.para.list = lkNumber
  doAssert layoutText(t).glyphs.len == plain.glyphs.len + 6
  t.para.listNumbers = nsRomanLower
  t.para.listStart = 4
  t.para.listSuffix = ")"
  t.para.listColor = 0xFFC02020'u32
  var red = 0
  for g in layoutText(t).glyphs:
    if g.color == 0xFFC02020'u32: inc red
  doAssert red == 3 + 2 + 3, "iv) v) vi): " & $red
  # kept with the text
  let back = textFrom(t.toJson)
  doAssert back.para.list == lkNumber and back.para.listNumbers == nsRomanLower and back.para.listStart == 4 and
           back.para.listSuffix == ")" and back.para.listColor == 0xFFC02020'u32
  doAssert paraFrom(paraToJson(t.para)).list == lkNumber
  doAssert textFrom(newText("x", st).toJson).para.list == lkNone
  # right to left: the marks at the box's right edge, the lines standing in from it
  var a = newText("البند الأول\nالبند الثاني", st, 10, 10)
  a.boxW = 300
  a.boxH = 200
  a.para.rtl = 2
  a.para.list = lkNumber
  a.para.listNumbers = nsArabicIndic
  let al = layoutText(a)
  var right = 0
  for g in al.glyphs:
    if g.x > 310 - 30: inc right
  doAssert right == 4, "two numbers and their periods at the right: " & $right
  for line in al.lines: doAssert line.x1 <= 310 - 30
  # point text has no list (it has no box to stand in from)
  var pt = newText("One\nTwo", st, 10, 30)
  pt.para.list = lkBullet
  doAssert layoutText(pt).glyphs.len == 6
  doAssert formatNumber(14, nsRomanLower) == "xiv" and formatNumber(3, nsArabicIndic) == "٣"

block dropCaps:
  # the first letters as tall as three lines: from the first line's capitals to the third
  # one's baseline; those lines stand in from them, the fourth does not; Arabic at the right
  let st = CharStyle(family: "", size: 20, color: 0xFF000000'u32, hScale: 1, vScale: 1)
  var t = newText("Once upon a time there was a long paragraph that went on for many lines in its " &
                  "narrow box, so that the drop cap has lines beside it and lines under it as well.\nNext",
                  st, 10, 10)
  t.boxW = 260
  t.boxH = 400
  let plain = layoutText(t)
  t.para.dropLines = 3
  let l = layoutText(t)
  doAssert l.glyphs.len == plain.glyphs.len, "the same letters, one of them big"
  var big: LaidGlyph
  for g in l.glyphs:
    if g.index == 0: big = g
  doAssert big.size > 50, "three lines tall: " & $big.size
  doAssert abs(big.y - l.lines[2].baseline) < 0.5, "on the third line's baseline"
  doAssert abs(big.x - 10) < 4
  for i in 0 .. 2: doAssert l.lines[i].x0 > 10 + big.adv * 0.7, "line " & $i & " beside it: " & $l.lines[i].x0
  doAssert l.lines[3].x0 < 14, "the fourth under it"
  for i in 0 .. 3: doAssert abs(l.lines[i].baseline - plain.lines[i].baseline) < 0.5, "the lines where they were"
  # two letters; kept with the text; the remainder that flows on has none
  t.para.dropChars = 2
  var two = 0
  for g in layoutText(t).glyphs:
    if g.size > 50: inc two
  doAssert two == 2
  let back = textFrom(t.toJson)
  doAssert back.para.dropLines == 3 and back.para.dropChars == 2
  doAssert t.remainder(40).para.dropLines == 0 and t.remainder(0).para.dropLines == 3
  # point text, a list, an empty text: none
  var pt = newText("Point", st, 10, 30)
  pt.para.dropLines = 3
  doAssert layoutText(pt).glyphs.len == 5
  var e = newText("", st, 10, 30)
  e.boxW = 100
  e.para.dropLines = 3
  discard layoutText(e)
  # right to left: at the right
  var a = newText("كان يا ما كان في قديم الزمان نص طويل يملأ عدة أسطر في مربعه الضيق حتى يكون للحرف الكبير أسطر بجانبه",
                  st, 10, 10)
  a.boxW = 260
  a.boxH = 400
  a.para.dropLines = 2
  let al = layoutText(a)
  var ab: LaidGlyph
  for g in al.glyphs:
    if g.index == 0: ab = g
  doAssert ab.size > 30 and ab.x > 10 + 260 - 80, "at the right: " & $ab.x
  for i in 0 .. 1: doAssert al.lines[i].x1 < 10 + 260 - ab.adv * 0.7

block baselineGrid:
  # Align to Baseline Grid: every line on the next grid line down -- a bigger heading too, so
  # the lines under it are back on the grid
  let st = CharStyle(family: "", size: 16, color: 0xFF000000'u32, hScale: 1, vScale: 1)
  var t = newText("A heading\n", CharStyle(family: "", size: 30, color: 0xFF000000'u32, hScale: 1, vScale: 1),
                  10, 37)
  t.spans.add TextSpan(text: "and the text under it, in lines long enough to make a few of them in the box.", style: st)
  t.boxW = 200
  t.boxH = 400
  t.gridStep = 24
  t.gridStart = 30
  let l = layoutText(t)
  doAssert l.lines.len >= 3
  for ln in l.lines:
    let k = (ln.baseline - 30) / 24
    doAssert abs(k - round(k)) < 0.01, "on the grid: " & $ln.baseline
  for i in 1 ..< l.lines.len: doAssert l.lines[i].baseline > l.lines[i - 1].baseline
  # kept with the text; off: as the leading puts them
  doAssert textFrom(t.toJson).gridStep == 24 and textFrom(t.toJson).gridStart == 30
  t.gridStep = 0
  let free = layoutText(t)
  doAssert abs((free.lines[2].baseline - free.lines[1].baseline) - 16 * 1.2) < 0.5

proc runeOffsetOf(s, sub: string): int = s[0 ..< s.find(sub)].runeLen

block tables:
  # each paragraph a row, tabs between cells; every cell's text in its column; the rows as tall
  # as their tallest cell; fills under the letters, lines over; kept with the text
  let st = CharStyle(family: "", size: 16, color: 0xFF000000'u32, hScale: 1, vScale: 1)
  var t = newText("Item\tQty\tPrice\nA long name that wraps in its narrow column\t12\t4.50\nPens\t3\t1.20", st, 10, 10)
  t.boxW = 300
  t.boxH = 400
  let plain = layoutText(t)
  t.table = tableTheme("Striped Blue")
  t.table.widths = @[2'f32, 1, 1]
  let l = layoutText(t)
  doAssert l.glyphs.len > 0 and l.backs.len >= 2, "the header and a stripe filled"
  doAssert l.decorations.len >= 3, "lines"
  # the columns: Qty's "12" starts at the second column (half the box in), the name wraps in the first
  var x12 = -1'f32
  let plainText = t.plainText
  let i12 = plainText.runeOffsetOf("12")
  for g in l.glyphs:
    if g.index == i12: x12 = g.x
  doAssert x12 > 10 + 150 - 1 and x12 < 10 + 225, "in the second column: " & $x12
  var nameLines = 0
  for ln in l.lines:
    if ln.first >= plainText.runeOffsetOf("A long") and ln.last <= plainText.runeOffsetOf("\t12"): inc nameLines
  doAssert nameLines >= 2, "the name wraps in its column"
  doAssert l.y1 > plain.lines[0].baseline + 60
  # the caret: every character has a place, a click in a cell lands in it
  doAssert l.caretX.len == plainText.runeLen + 1
  let c = l.charAt(x12 + 2, l.caretAt(i12).top + 4)
  doAssert c in i12 .. i12 + 2, $c
  # themes; saved with the text; off: the text as it was
  for th in tableThemes: doAssert tableTheme(th).theme == th
  let back = textFrom(t.toJson)
  doAssert back.table.on and back.table.theme == "Striped Blue" and back.table.widths == @[2'f32, 1, 1]
  t.table = TableStyle()
  doAssert layoutText(t).glyphs.len == plain.glyphs.len
  # drawn: the header's fill under its white letters
  t.table = tableTheme("Dark Header")
  var px = newSeq[uint32](340 * 200)
  discard t.renderTextInto(px, 340, 200, layoutText(t))
  doAssert (px[(10 + 3) * 340 + 290] and 0xFFFFFF'u32) == 0x222222'u32, "the header's fill"
  # Arabic: the first column at the right
  var a = newText("البند\tالعدد\nورق\t١٢", st, 10, 10)
  a.boxW = 300
  a.boxH = 200
  a.table = tableTheme("Gold")
  var first = 1e9'f32
  for g in layoutText(a).glyphs:
    if g.index == 0: first = g.x
  doAssert first > 10 + 150, "the first cell at the right: " & $first
  # an empty table, a table of one cell
  var e = newText("", st, 0, 0)
  e.boxW = 100
  e.table = tableTheme("Minimal")
  discard layoutText(e)
  var one = newText("x", st, 0, 0)
  one.boxW = 100
  one.table = tableTheme("")
  doAssert layoutText(one).glyphs.len == 1

block realTables:
  # cells merged across and down, several paragraphs in one, a cell's own fill, lines, inset,
  # place up and down, turned text; rows at least or exactly so tall; a table too long for its box:
  # the rows that fit, the footer under them, the rest on in the next box under the header again;
  # right to left; kept with the text
  let st = CharStyle(family: "", size: 16, color: 0xFF000000'u32, hScale: 1, vScale: 1)
  var t = newText("A\tB\tC\nD\tE\tF\nG\tH\tI", st, 10, 10)
  t.boxW = 300
  t.boxH = 400
  t.table = tableTheme("Plain Grid")
  t.table.cellRef(0, 0).colSpan = 2
  t.table.cellRef(0, 0).fill = 0xFFFF0000'u32
  t.table.cellRef(1, 2).rowSpan = 2
  proc glyphOf(l: TextLayout; i: int): int =
    result = -1
    for k, g in l.glyphs:
      if g.index == i: return k
  var l = layoutText(t)
  doAssert l.glyphOf(2) < 0, "B, merged into A, not drawn"
  doAssert l.glyphOf(16) < 0 and l.glyphOf(10) >= 0, "I, merged into F, not drawn"
  var wide = false
  for b in l.backs:
    if b.color == 0xFFFF0000'u32 and abs(b.x0 - 10) < 0.5 and abs(b.x1 - 210) < 0.5: wide = true
  doAssert wide, "A's fill over two columns"
  # F as tall as two rows: its text at the top of them, the row line under E not across it
  let fY = l.glyphs[l.glyphOf(10)].y
  let eY = l.glyphs[l.glyphOf(8)].y
  doAssert abs(fY - eY) < 0.5
  # several paragraphs in a cell; a cell's own inset; at the foot of its row
  var u = newText("One\u2029Two\tX\nY\tZ", st, 10, 10)
  u.boxW = 300
  u.boxH = 400
  u.table = tableTheme("Plain Grid")
  u.table.cellRef(0, 1).inset = [20'f32, 20, 20, 20]
  u.table.cellRef(0, 1).vAlign = vjBottom
  let ul = layoutText(u)
  let gOne = ul.glyphs[ul.glyphOf(0)]
  let gTwo = ul.glyphs[ul.glyphOf(4)]
  doAssert gTwo.y > gOne.y + 10 and abs(gTwo.x - gOne.x) < 0.5, "two paragraphs, one under the other"
  let gX = ul.glyphs[ul.glyphOf(8)]
  doAssert gX.x >= 160 + 20 - 0.5, "its inset: " & $gX.x
  doAssert gX.y > gOne.y + 5, "at the foot of its row: " & $gX.y & " " & $gOne.y
  # rows: at least so tall, exactly so tall (what passes its foot not drawn)
  var h = newText("a\tb\nc\td", st, 10, 10)
  h.boxW = 300
  h.boxH = 400
  h.table = tableTheme("Plain Grid")
  h.table.rowFmts = @[TableRowFmt(kind: rhAtLeast, height: 80)]
  let hl = layoutText(h)
  doAssert hl.glyphs[hl.glyphOf(4)].y > 10 + 80, "the second row under a row 80 tall"
  var x = newText("a b c d e f g h i j k l m n o p q r s t u v w x y z a b c d e f g h\tq", st, 10, 10)
  x.boxW = 200
  x.boxH = 400
  x.table = tableTheme("Plain Grid")
  x.table.rowFmts = @[TableRowFmt(kind: rhExactly, height: 24)]
  let xl = layoutText(x)
  doAssert xl.y1 - 10 < 25 and xl.glyphs.len < 30, "exactly 24 tall, the rest cut: " & $xl.glyphs.len
  # turned up: its glyphs turned, up the cell
  var r = newText("Up\tside", st, 10, 10)
  r.boxW = 300
  r.boxH = 400
  r.table = tableTheme("Plain Grid")
  r.table.cellRef(0, 0).rotation = 90
  let rl = layoutText(r)
  let gU = rl.glyphs[rl.glyphOf(0)]
  let gP = rl.glyphs[rl.glyphOf(1)]
  doAssert gU.angle == 90 and gP.y < gU.y - 3 and abs(gP.x - gU.x) < 0.5, "up the cell: " & $gU & " " & $gP
  # a cell's own line
  var sk = newText("a\tb", st, 10, 10)
  sk.boxW = 300
  sk.table = tableTheme("Plain Grid")
  sk.table.cellRef(0, 0).strokes[1] = CellStroke(on: true, width: 4, color: 0xFF00FF00'u32)
  var green = false
  for d in layoutText(sk).decorations:
    if d.color == 0xFF00FF00'u32 and abs(d.x1 - d.x0 - 4) < 0.1 and abs((d.x0 + d.x1) / 2 - 160) < 0.5: green = true
  doAssert green, "its right side, green and 4 wide"
  # too long for its box: the rows that fit, the footer under them; the rest under the header again
  var rows = "Name\tValue"
  for k in 1 .. 30: rows.add "\nRow " & $k & "\t" & $(k * 10)
  rows.add "\nTotal\t4650"
  var lt = newText(rows, st, 10, 10)
  lt.boxW = 300
  lt.boxH = 260
  lt.table = tableTheme("Plain Grid")
  lt.table.headerRows = 1
  lt.table.footerRows = 1
  let ll = layoutText(lt)
  doAssert ll.overflow > 0 and ll.y1 <= 10 + 260 + 0.5, "cut at a row, within the box: " & $ll.y1
  var copies = 0
  for g in ll.glyphs:
    if g.index == -1: inc copies
  doAssert copies >= 5, "the footer under the rows that fit"
  let rest = lt.remainder(ll.overflow)
  doAssert rest.tableRow0 > 1 and rest.tableHead.len > 0, $rest.tableRow0
  var r2 = rest
  r2.x = 10
  r2.y = 300
  let rl2 = layoutText(r2)
  var top = 1e9'f32
  var headSeen = false
  for g in rl2.glyphs:
    top = min(top, g.y)
    if g.index == -1 and g.y < 300 + 30: headSeen = true
  doAssert headSeen, "the header again at its top"
  # right to left: a cell merged across, from the right
  var ar = newText("البند\tالعدد\tالسعر\nورق\t١٢\t٣", st, 10, 10)
  ar.boxW = 300
  ar.table = tableTheme("Plain Grid")
  ar.table.cellRef(0, 0).colSpan = 2
  ar.table.cellRef(0, 0).fill = 0xFF0000FF'u32
  var rightSpan = false
  for b in layoutText(ar).backs:
    if b.color == 0xFF0000FF'u32 and abs(b.x1 - 310) < 0.5 and abs(b.x0 - 110) < 0.5: rightSpan = true
  doAssert rightSpan, "from the right, two columns"
  # kept with the text
  let back = textFrom(t.toJson)
  doAssert back.table.cellAt(0, 0).colSpan == 2 and back.table.cellAt(1, 2).rowSpan == 2 and
           back.table.cellAt(0, 0).fill == 0xFFFF0000'u32
  let back2 = textFrom(lt.toJson)
  doAssert back2.table.footerRows == 1
  let back3 = textFrom(h.toJson)
  doAssert back3.table.rowFmts == h.table.rowFmts

block tableRowsColumnsMerging:
  # rows and columns put in and taken out, the cells' own looks moving with them; cells merged
  # (what they said gathered, a paragraph each) and apart
  let st = CharStyle(family: "", size: 16, color: 0xFF000000'u32, hScale: 1, vScale: 1)
  var t = newText("a\tb\nc\td", st, 10, 10)
  t.boxW = 300
  t.table = tableTheme("Plain Grid")
  t.table.cellRef(1, 1).fill = 0xFF00FF00'u32
  t.insertRow(1)
  doAssert t.plainText == "a\tb\n\t\nc\td" and t.table.cellAt(2, 1).fill == 0xFF00FF00'u32, t.plainText
  t.insertRow(3)
  doAssert t.plainText == "a\tb\n\t\nc\td\n\t", t.plainText
  t.deleteRow(3)
  t.deleteRow(1)
  doAssert t.plainText == "a\tb\nc\td" and t.table.cellAt(1, 1).fill == 0xFF00FF00'u32
  t.insertColumn(1)
  doAssert t.plainText == "a\t\tb\nc\t\td" and t.table.cellAt(1, 2).fill == 0xFF00FF00'u32, t.plainText
  t.deleteColumn(1)
  doAssert t.plainText == "a\tb\nc\td"
  doAssert t.cellOfChar(4) == (1, 0) and t.cellOfChar(6) == (1, 1) and t.cellOfChar(3) == (0, 1)
  t.mergeCells(0, 0, 1, 0)
  doAssert t.plainText == "a\u2029c\tb\n\td" and t.table.cellAt(0, 0).rowSpan == 2, t.plainText
  let l = layoutText(t)
  doAssert l.glyphs.len == 4, "a, c in one cell; b, d"
  t.unmergeCells(0, 0)
  doAssert t.table.cellAt(0, 0).rowSpan <= 1

block tableEditing:
  # the grid as laid (for its edges dragged), right to left too; columns and rows made even; a
  # cell split across and down, merged cells parted; the body sorted by a column; a row no
  # taller than so much; rows kept with the next, started in the next box; header and footer
  # skipped in the first and last box; kept with the text
  let st = CharStyle(family: "", size: 16, color: 0xFF000000'u32, hScale: 1, vScale: 1)
  proc glyphOf(l: TextLayout; i: int): int =
    result = -1
    for k, g in l.glyphs:
      if g.index == i: return k
  var t = newText("a\tb\tc\nd\te\tf", st, 10, 10)
  t.boxW = 300
  t.table = tableTheme("Plain Grid")
  var l = layoutText(t)
  doAssert l.gridCols.len == 4 and abs(l.gridCols[1] - 110) < 0.5 and abs(l.gridCols[3] - 310) < 0.5, $l.gridCols
  doAssert l.gridRows.len == 2 and l.gridRows[1].row == 1 and abs(l.gridRows[0].y1 - l.gridRows[1].y0) < 0.01
  # (right to left: the first column at the right, its own width)
  var ar = newText("البند\tالعدد\tالسعر", st, 10, 10)
  ar.boxW = 300
  ar.table = tableTheme("Plain Grid")
  ar.table.widths = @[2'f32, 1, 1]
  let al = layoutText(ar)
  doAssert al.gridRtl and abs(al.gridCols[1] - 85) < 0.5 and abs(al.gridCols[2] - 160) < 0.5, $al.gridCols
  doAssert al.glyphs[al.glyphOf(0)].x > 160, "the first, wide column at the right"
  # (the edges found under the pointer and dragged)
  doAssert l.tableEdgeAt(111, 20, 3) == (1, 1) and l.tableEdgeAt(60, 20, 3).kind == 0
  doAssert l.tableEdgeAt(60, l.gridRows[0].y1 + 1, 3) == (2, 0)
  var dg = t
  dg.dragColumnEdge(l, 1, 40)
  let dl = layoutText(dg)
  doAssert abs(dl.gridCols[1] - 150) < 0.5 and abs(dl.gridCols[2] - 210) < 0.5 and abs(dl.gridCols[3] - 310) < 0.5,
           "the two beside it: " & $dl.gridCols
  var gw = t
  gw.dragColumnEdge(l, 1, 40, grow = true)
  let gl = layoutText(gw)
  doAssert abs(gw.boxW - 340) < 0.01 and abs(gl.gridCols[2] - 250) < 0.5 and abs(gl.gridCols[3] - 350) < 0.5,
           "the table wider: " & $gl.gridCols
  var ad = ar
  ad.dragColumnEdge(al, 2, 30)                 # (right to left: the first column, at the right, narrower)
  doAssert ad.tableParts == @[120'f32, 105, 75] and abs(layoutText(ad).gridCols[2] - 190) < 0.5, $ad.tableParts
  var rh = t
  rh.dragRowEdge(l, 0, 30)
  let rl = layoutText(rh)
  doAssert rh.table.rowFmts[0].kind == rhAtLeast and
           abs((rl.gridRows[0].y1 - rl.gridRows[0].y0) - (l.gridRows[0].y1 - l.gridRows[0].y0) - 30) < 0.5
  t.table.widths = @[3'f32, 1, 1]
  t.distributeColumns(0, 2)
  doAssert t.tableParts == @[5'f32 / 3, 5'f32 / 3, 5'f32 / 3], $t.tableParts
  t.table.widths = @[]
  t.table.rowFmts = @[TableRowFmt(kind: rhAtLeast, height: 80)]
  let tall = layoutText(t).gridRows
  t.distributeRows(0, 1)
  let even = layoutText(t).gridRows
  doAssert abs((even[0].y1 - even[0].y0) - (even[1].y1 - even[1].y0)) < 0.5 and
           abs((even[1].y1 - even[0].y0) - (tall[1].y1 - tall[0].y0)) < 0.5, $even
  # split
  var sp = newText("a\tb\nc\td", st, 10, 10)
  sp.boxW = 300
  sp.table = tableTheme("Plain Grid")
  sp.splitCell(0, 0, across = false)
  doAssert sp.plainText == "a\t\tb\nc\t\td" and sp.table.cellAt(1, 0).colSpan == 2 and
           sp.tableParts == @[0.5'f32, 0.5, 1], sp.plainText & " " & $sp.tableParts
  var sa = newText("a\tb\nc\td", st, 10, 10)
  sa.boxW = 300
  sa.table = tableTheme("Plain Grid")
  sa.splitCell(0, 1, across = true)
  doAssert sa.plainText == "a\tb\n\t\nc\td" and sa.table.cellAt(0, 0).rowSpan == 2 and
           sa.table.cellAt(0, 1).rowSpan <= 1, sa.plainText
  doAssert layoutText(sa).gridRows.len == 3
  var sm = newText("a\tb\tc", st, 10, 10)
  sm.boxW = 300
  sm.table = tableTheme("Plain Grid")
  sm.mergeCells(0, 0, 0, 2)
  sm.splitCell(0, 0, across = false)
  doAssert sm.table.cellAt(0, 0).colSpan == 2 and sm.table.cellAt(0, 2).colSpan == 1, "parted 2 and 1"
  # sort
  var so = newText("Item\tQty\nPens\t12\nPaper\t3\nInk\t100\nTotal\t115", st, 10, 10)
  so.boxW = 300
  so.table = tableTheme("Plain Grid")
  so.table.headerRows = 1
  so.table.footerRows = 1
  so.table.cellRef(1, 0).fill = 0xFF00FF00'u32
  doAssert so.sortTable(1)
  doAssert so.plainText == "Item\tQty\nPaper\t3\nPens\t12\nInk\t100\nTotal\t115", so.plainText
  doAssert so.table.cellAt(2, 0).fill == 0xFF00FF00'u32, "Pens' fill went with it"
  doAssert so.sortTable(0, descending = true)
  doAssert so.plainText == "Item\tQty\nPens\t12\nPaper\t3\nInk\t100\nTotal\t115", so.plainText
  var sar = newText("باسم\nإدريس\nأحمد", st, 10, 10)
  sar.boxW = 300
  sar.table = tableTheme("Plain Grid")
  sar.table.headerRows = 0
  doAssert sar.sortTable(0)
  doAssert sar.plainText == "أحمد\nإدريس\nباسم", sar.plainText
  var sg = newText("a\tb\nc\td\ne\tf", st, 10, 10)
  sg.boxW = 300
  sg.table = tableTheme("Plain Grid")
  sg.mergeCells(0, 0, 1, 0)
  doAssert not sg.sortTable(1), "rows merged: not sorted"
  # no taller than so much: the rest cut off
  var mx = newText("a b c d e f g h i j k l m n o p q r s t u v w x y z a b c d e f g h\tq", st, 10, 10)
  mx.boxW = 200
  mx.boxH = 400
  mx.table = tableTheme("Plain Grid")
  mx.table.rowFmts = @[TableRowFmt(kind: rhAtLeast, height: 10, maxHeight: 30)]
  let ml = layoutText(mx)
  doAssert ml.y1 - 10 < 31 and ml.glyphs.len < 40, "no taller than 30: " & $(ml.y1 - 10)
  # kept with the next, started in the next box
  var rows = "Name\tValue"
  for k in 1 .. 30: rows.add "\nRow " & $k & "\t" & $(k * 10)
  var lt = newText(rows, st, 10, 10)
  lt.boxW = 300
  lt.boxH = 260
  lt.table = tableTheme("Plain Grid")
  lt.table.headerRows = 1
  let cells = lt.tableCells
  let natural = layoutText(lt).overflow
  var cutRow = 0
  for r, row in cells:
    if row[0].a == natural: cutRow = r
  doAssert cutRow > 3, $cutRow
  lt.table.rowFmts = newSeq[TableRowFmt](cutRow)
  lt.table.rowFmts[cutRow - 1].keepNext = true
  doAssert layoutText(lt).overflow == cells[cutRow - 1][0].a, "kept with the row after it"
  lt.table.rowFmts[cutRow - 1].keepNext = false
  lt.table.rowFmts[3].startNext = true
  doAssert layoutText(lt).overflow == cells[3][0].a, "row 3 in the next box"
  # header skipped in the first box, footer in the last
  var sk = newText("Head\tH\na\tb\nFoot\tF", st, 10, 10)
  sk.boxW = 300
  sk.boxH = 400
  sk.table = tableTheme("Plain Grid")
  sk.table.headerRows = 1
  sk.table.footerRows = 1
  sk.table.skipFirstHeader = true
  sk.table.skipLastFooter = true
  let kl = layoutText(sk)
  doAssert kl.glyphOf(0) < 0 and kl.glyphOf(7) >= 0 and kl.glyphOf(11) < 0, "only the body"
  doAssert kl.gridRows.len == 1 and kl.gridRows[0].row == 1
  let back = textFrom(sk.toJson)
  doAssert back.table.skipFirstHeader and back.table.skipLastFooter
  let back2 = textFrom(lt.toJson)
  doAssert back2.table.rowFmts == lt.table.rowFmts
  let back3 = textFrom(mx.toJson)
  doAssert back3.table.rowFmts[0].maxHeight == 30

block baselineOptionsAndColumnWidths:
  # a box's first baseline under its top: the ascent, the capitals' height, the small letters',
  # the leading, a fixed distance, at least so far; columns of a fixed width (as many as fit, the
  # text as wide as they are) or of a most width (as many as keep each no wider); kept
  let st = CharStyle(family: "", size: 40, color: 0xFF000000'u32, hScale: 1, vScale: 1)
  var t = newText("Hxample text that goes on and on over several lines of the box", st, 10, 10)
  t.boxW = 600
  t.boxH = 400
  let asc = layoutText(t).lines[0].baseline - 10
  t.firstBase = fbCapHeight
  let cap = layoutText(t).lines[0].baseline - 10
  t.firstBase = fbXHeight
  let xh = layoutText(t).lines[0].baseline - 10
  t.firstBase = fbLeading
  let lead = layoutText(t).lines[0].baseline - 10
  doAssert xh < cap and cap < asc and abs(lead - 48) < 0.5, $(asc, cap, xh, lead)
  t.firstBase = fbFixed
  t.firstMin = 70
  doAssert abs(layoutText(t).lines[0].baseline - 80) < 0.5
  t.firstBase = fbCapHeight
  doAssert abs(layoutText(t).lines[0].baseline - 80) < 0.5, "at least 70 down"
  let back = textFrom(t.toJson)
  doAssert back.firstBase == fbCapHeight and back.firstMin == 70
  var c = newText(repeat("words and more words ", 60), CharStyle(family: "", size: 14, color: 0xFF000000'u32,
                  hScale: 1, vScale: 1), 0, 0)
  c.boxW = 700
  c.boxH = 300
  c.gutter = 20
  c.colMode = cmFixedWidth
  c.colWidth = 200
  doAssert c.columnsOf == 3
  var right = 0'f32
  for g in layoutText(c).glyphs: right = max(right, g.x)
  doAssert right < 660 and right > 400, "three columns 200 wide: " & $right
  c.colMode = cmFlexible
  c.colWidth = 300
  doAssert c.columnsOf == 3, "no wider than 300: three"
  c.colWidth = 400
  doAssert c.columnsOf == 2
  let back2 = textFrom(c.toJson)
  doAssert back2.colMode == cmFlexible and back2.colWidth == 400

block scriptFonts:
  # a font for the Arabic letters and one for the Latin: each run in its own, its size, raise,
  # color; the spaces and digits with the letters about them; kept with the text
  var st = CharStyle(family: "FreeSans", size: 30, color: 0xFF000000'u32, hScale: 1, vScale: 1)
  st.latinFont = ScriptFont(family: "FreeSerif", style: "Bold", color: 0xFF0000FF'u32)
  st.arabicFont = ScriptFont(scale: 1.5, shift: 3, color: 0xFFFF0000'u32)
  let t = newText("Hello مرحبا 2026 world", st, 10, 50)
  let l = layoutText(t)
  var red, blue = 0
  var bigSize = 0'f32
  for g in l.glyphs:
    if g.color == 0xFFFF0000'u32:
      inc red
      bigSize = max(bigSize, g.size)
    if g.color == 0xFF0000FF'u32: inc blue
  doAssert red >= 5 and blue >= 10, $red & " " & $blue
  doAssert abs(bigSize - 45) < 0.5, "Arabic at 150 %: " & $bigSize
  let sp = scriptFontsApplied(t)
  doAssert sp.spans.len >= 3 and sp.spans[0].style.family == "FreeSerif" and sp.spans[0].style.style == "Bold"
  doAssert sp.plainText == t.plainText, "the same text, cut where its script changes"
  let back = textFrom(t.toJson)
  doAssert back.spans[0].style.latinFont.family == "FreeSerif" and back.spans[0].style.arabicFont.scale == 1.5
  # none set: nothing changes
  var plain = st
  plain.arabicFont = ScriptFont()
  plain.latinFont = ScriptFont()
  doAssert scriptFontsApplied(newText("abc", plain)).spans.len == 1

block alternatesOfAWord:
  # the features of a font that draw a word otherwise; none that a script needs to be set
  let alts = alternatesFor("affine", CharStyle(family: "", size: 20))
  var liga = false
  for a in alts:
    doAssert a.tag notin ["kern", "mark", "init", "ccmp"]
    if a.tag == "liga":
      liga = true
      doAssert a.on and a.name == "Standard Ligatures"
  doAssert liga, "FreeSans has an fi ligature"
  var st = CharStyle(family: "", size: 20, features: "-liga")
  for a in alternatesFor("affine", st):
    if a.tag == "liga": doAssert not a.on, "turned off by the style"
  doAssert alternatesFor("xyz", CharStyle(family: "", size: 20)).len == 0, "nothing to choose for these letters"
  doAssert alternatesFor("", st).len == 0

block footnotes:
  # a reference's number in the text, the note at the foot of the box under a line, the text
  # kept above it; numbered in order, in Arabic digits too; deleted with its reference; flowing
  # on with the text, its numbers going on; endnotes after the text; saved
  var st = defaultStyle()
  st.size = 20
  var t = newText(repeat("Words that fill the box line after line. ", 14), st, 10, 10)
  t.boxW = 300
  t.boxH = 260
  let a = t.insertNote(5, "The first note.")
  let b = t.insertNote(t.runeLen, "The second, at the end.")
  doAssert a == 1 and b == 2 and t.notes.len == 2 and t.noteMarks.len == 2
  doAssert t.noteNumber(a) == "1" and t.noteNumber(b) == "2"
  let c = t.insertNote(2, "Before them both.")         # (put first: the others numbered after it)
  doAssert t.noteNumber(c) == "1" and t.noteNumber(a) == "2" and t.notes[0].id == c
  let lay = layoutText(t)
  doAssert lay.caretX.len == t.runeLen + 1, "the caret's places: the text's characters"
  var mainBottom, noteTop = 0'f32
  noteTop = 1e9
  for g in lay.glyphs:
    if g.index >= 0: mainBottom = max(mainBottom, g.y)
    else: noteTop = min(noteTop, g.y - g.size * 0.8)
  doAssert noteTop < 1e9, "the notes drawn"
  doAssert mainBottom < noteTop, "the text above the notes"
  doAssert noteTop > t.y + t.boxH * 0.5 and noteTop < t.y + t.boxH, "at the foot of the box"
  doAssert lay.decorations.len >= 1, "the line above them"
  # the text past the box: flows on, the notes' numbers going on
  doAssert lay.overflow > 0, "not all of it fits above the notes"
  let rest = t.remainder(lay.overflow)
  doAssert rest.notes.len == 3, "the box it flows into keeps the notes"
  doAssert rest.noteNumber(b) == "3"
  # deleted with its reference
  var t2 = t
  for sp in t2.spans.mitems: sp.text = sp.text.replace(noteMark(a), "")
  t2.tidyNotes()
  doAssert t2.notes.len == 2 and t2.noteNumber(b) == "2"
  # Arabic digits, round the reference
  var t3 = t
  t3.noteOpts.numbers = nsArabicIndic
  t3.noteOpts.prefix = "("
  t3.noteOpts.suffix = ")"
  doAssert t3.noteNumber(b) == "٣"
  doAssert layoutText(t3).caretX.len == t3.runeLen + 1
  # endnotes: after the text, under a heading
  var e = t
  e.boxH = 2000
  e.noteOpts.kind = nkEndnotes
  let el = layoutText(e)
  var lastMain, firstNote = 0'f32
  firstNote = 1e9
  for g in el.glyphs:
    if g.index >= 0: lastMain = max(lastMain, g.y)
    else: firstNote = min(firstNote, g.y)
  doAssert firstNote > lastMain, "after the text"
  doAssert el.overflow == -1
  # saved and read back
  let back = textFrom(t3.toJson)
  doAssert back.notes == t3.notes and back.noteOpts.numbers == nsArabicIndic and back.noteOpts.prefix == "("
  doAssert layoutText(back).glyphs.len == layoutText(t3).glyphs.len

block footnoteOptions:
  # numbers again in each box, by the references' order there; the prefix and suffix round the
  # reference, the note or both; the reference as big as the text; room between notes; the line
  # above them standing in, so far above, in dashes; kept
  var st = defaultStyle()
  st.size = 20
  var t = newText(repeat("Words that fill the box line after line. ", 14), st, 10, 10)
  t.boxW = 300
  t.boxH = 260
  let a = t.insertNote(5, "The first note.")
  let b = t.insertNote(t.runeLen, "The second, at the end.")
  t.noteOpts.prefix = "["
  t.noteOpts.suffix = "]"
  let lay0 = layoutText(t)
  let rest = t.remainder(lay0.overflow)
  doAssert rest.noteNumber(b) == "2"
  var r2 = rest
  r2.noteOpts.restart = true
  doAssert r2.noteNumber(b) == "1", "again from the first in the next box"
  t.noteOpts.restart = true
  doAssert t.noteNumber(a) == "1"
  # the prefix and suffix: round the note's number only
  t.noteOpts.affixIn = 2
  let ex = layoutText(t)
  var u = t
  u.noteOpts.affixIn = 0
  proc inText(l: TextLayout): int =
    for g in l.glyphs:
      if g.index >= 0: inc result
  doAssert inText(ex) < inText(layoutText(u)), "no brackets round the reference"
  # the reference as the text is: not raised
  t.noteOpts.affixIn = 0
  t.noteOpts.refNormal = true
  var raised = false
  for g in layoutText(t).glyphs:
    if g.index >= 5 and g.index <= 7 and g.size < 19: raised = true
  doAssert not raised, "the reference full size"
  # the line: in from the edge, so far above, in dashes
  t.noteOpts.ruleIndent = 30
  t.noteOpts.ruleOffset = 12
  t.noteOpts.ruleDash = true
  t.noteOpts.between = 6
  var dashes = 0
  var left = 1e9'f32
  for d in layoutText(t).decorations:
    inc dashes
    left = min(left, d.x0)
  doAssert dashes > 3 and abs(left - 40) < 0.5, $dashes & " " & $left
  let back = textFrom(t.toJson)
  doAssert back.noteOpts.restart and back.noteOpts.refNormal and back.noteOpts.ruleDash and
           back.noteOpts.ruleIndent == 30 and back.noteOpts.ruleOffset == 12 and back.noteOpts.between == 6

block hyphenation:
  # Liang's patterns: where English words break; a paragraph that hyphenates breaks the word
  # that does not fit at a line's end, a hyphen after it, and fills its lines better
  doAssert hyphenated("typesetting") == "type-set-ting"
  doAssert hyphenated("hyphenation") == "hy-phen-ation"
  doAssert hyphenated("table") == "ta-ble", "the patterns' own exceptions"
  doAssert hyphenated("project") == "project"
  doAssert hyphenPoints("cat").len == 0 and hyphenPoints("don't").len == 0
  var st = defaultStyle()
  st.size = 19
  var t = newText("Typesetting with hyphenation gives justified paragraphs an even texture: international " &
                  "organizations, extraordinary considerations and characteristically long words.", st, 0, 0)
  t.boxW = 290
  t.boxH = 400
  t.para.align = justifyLeft
  let plain = layoutText(t)
  t.para.hyphenate = true
  let hy = layoutText(t)
  var hyphens = 0
  for ln in hy.lines:
    let txt = t.textSlice(ln.first, ln.last)
    if ln.last < t.runeLen and txt.len > 0 and txt[^1] notin {' ', ','}: inc hyphens
  doAssert hyphens >= 1, "a word broken"
  doAssert hy.glyphs.len > plain.glyphs.len, "its hyphen drawn"
  doAssert hy.caretX.len == plain.caretX.len
  # Arabic is never hyphenated; nor point text
  var a = newText("كلمات عربية طويلة جدا في سطر قصير", st, 0, 0)
  a.boxW = 120
  a.boxH = 400
  a.para.hyphenate = true
  var a2 = a
  a2.para.hyphenate = false
  doAssert layoutText(a).glyphs.len == layoutText(a2).glyphs.len
  doAssert textFrom(t.toJson).para.hyphenate
  # other languages' patterns: French, German, Spanish, Italian, Portuguese, Dutch -- accented
  # letters, an apostrophe in a French word, each language's own least letters at the ends
  doAssert "fr" in hyphenLanguages and hasPatterns("de-DE") and not hasPatterns("ar")
  doAssert hyphenated("Silbentrennung", lang = "de") == "Sil-ben-tren-nung", hyphenated("Silbentrennung", lang = "de")
  doAssert hyphenated("hyphénation", lang = "fr") == "hy-phé-na-tion", hyphenated("hyphénation", lang = "fr")
  doAssert hyphenated("separación", lang = "es") == "se-pa-ra-ción", hyphenated("separación", lang = "es")
  doAssert hyphenated("divisione", lang = "it") == "di-vi-sio-ne", hyphenated("divisione", lang = "it")
  doAssert hyphenated("lettergreep", lang = "nl") == "let-ter-greep", hyphenated("lettergreep", lang = "nl")
  doAssert hyphenated("hifenização", lang = "pt") == "hi-fe-ni-za-ção", hyphenated("hifenização", lang = "pt")
  doAssert hyphenPoints("l'homme", lang = "fr").len >= 0 and hyphenPoints("l'avertissement", lang = "fr").len > 0
  doAssert hyphenated("typesetting", lang = "xx") == "type-set-ting", "a language with none: English's"
  # (the packed patterns the programs carry: the same as the files beside them)
  let vendor = currentSourcePath().parentDir.parentDir / "src" / "retroui" / "vendor"
  for f in ["en-us", "fr", "de-1996", "es", "it", "pt", "nl"]:
    doAssert unpackBytes(readFile(vendor / ("hyph-" & f & ".tex.z"))) == readFile(vendor / ("hyph-" & f & ".tex")), f
  # a paragraph in German: its words broken by German's patterns (the Character panel's Language)
  var g = defaultStyle()
  g.size = 19
  g.lang = "de"
  var tg = newText("Die Silbentrennung macht Blocksatz gleichmäßiger: Donaudampfschifffahrtsgesellschaft " &
                   "und Rechtsschutzversicherungsgesellschaften sind lange Wörter.", g, 0, 0)
  tg.boxW = 260
  tg.boxH = 600
  tg.para.align = justifyLeft
  tg.para.hyphenate = true
  let lg = layoutText(tg)
  var broken = 0
  for ln in lg.lines:
    let txt = tg.textSlice(ln.first, ln.last)
    if ln.last < tg.runeLen and txt.len > 0 and txt[^1] notin {' ', ',', ':'}: inc broken
  doAssert broken >= 1, "a German word broken"
  doAssert textFrom(tg.toJson).spans[0].style.lang == "de"

block typesettingOptions:
  # Hyphenation Settings (the shortest word broken, the letters before and after a hyphen, hyphens
  # in a row, the zone, capitals, the last word); Balance Ragged Lines; Single Word Justification;
  # Auto Leading; Paragraph Rules; Underline and Strikethrough Options; figure styles and positional
  # forms; all kept
  var st = defaultStyle()
  st.size = 19
  let words = "Typesetting with hyphenation gives justified paragraphs an even texture: international " &
              "organizations, extraordinary considerations and characteristically long words."
  proc hyphensIn(t: TextData): int =
    let l = layoutText(t)
    for ln in l.lines:
      let txt = t.textSlice(ln.first, ln.last)
      if ln.last < t.runeLen and txt.len > 0 and txt[^1] notin {' ', ',', ':', '.'}: inc result
  var t = newText(words, st, 0, 0)
  t.boxW = 290
  t.boxH = 600
  t.para.align = justifyLeft
  t.para.composer = cpSingle
  t.para.hyphenate = true
  let many = hyphensIn(t)
  doAssert many >= 1, $many
  var long = t
  long.para.hyphWord = 20
  doAssert hyphensIn(long) == 0, "no word of 20 letters"
  var lim = t
  lim.para.hyphLimit = 1
  doAssert hyphensIn(lim) <= many
  var caps = newText("Internationalization Internationalization Internationalization Internationalization",
                     st, 0, 0)
  caps.boxW = 260
  caps.boxH = 400
  caps.para.hyphenate = true
  caps.para.composer = cpSingle
  doAssert hyphensIn(caps) >= 1
  caps.para.noHyphCaps = true
  doAssert hyphensIn(caps) == 0, "words with a capital not broken"
  # Balance Ragged Lines: two lines nearer each other's length
  var h = newText("A heading long enough to go on to a second short line", CharStyle(family: "", size: 30,
                  color: 0xFF000000'u32, hScale: 1, vScale: 1), 0, 0)
  h.boxW = 560
  h.boxH = 300
  let l0 = layoutText(h)
  doAssert l0.lines.len == 2
  h.para.balanceRagged = true
  let l1 = layoutText(h)
  doAssert l1.lines.len == 2 and
           abs((l1.lines[0].x1 - l1.lines[0].x0) - (l1.lines[1].x1 - l1.lines[1].x0)) <
           abs((l0.lines[0].x1 - l0.lines[0].x0) - (l0.lines[1].x1 - l0.lines[1].x0)), "more even"
  # Single Word Justification: a line of one word, spread or in the middle
  var sw = newText("Extraordinarily\nmore words here", st, 0, 0)
  sw.boxW = 400
  sw.boxH = 300
  sw.para.align = justifyLeft
  var w1 = newText("Extraordinarily more words", st, 0, 0)
  w1.boxW = 140
  w1.boxH = 300
  w1.para.align = justifyLeft
  w1.para.composer = cpSingle
  let spread = layoutText(w1)
  doAssert spread.lines.len >= 2 and spread.lines[0].last <= 16 and spread.lines[0].x1 > 139,
           "spread across the line: " & $spread.lines[0]
  w1.para.singleWord = swCenter
  let mid = layoutText(w1)
  doAssert mid.lines[0].x0 > 3 and mid.lines[0].x1 < 137, "in the middle: " & $mid.lines[0]
  # Auto Leading
  var al = newText("one\ntwo", st, 0, 0)
  al.boxW = 300
  al.boxH = 300
  let a0 = layoutText(al)
  al.para.autoLead = 200
  let a1 = layoutText(al)
  doAssert abs((a1.lines[1].baseline - a1.lines[0].baseline) - 38) < 0.5 and
           abs((a0.lines[1].baseline - a0.lines[0].baseline) - 22.8) < 0.5
  # Paragraph Rules: over the first line, under the last, as wide as the column or the text
  var pr = newText("A heading", st, 10, 10)
  pr.boxW = 300
  pr.boxH = 100
  pr.para.ruleAbove = ParaRule(on: true, weight: 3, color: 0xFFFF0000'u32, offset: 20)
  pr.para.ruleBelow = ParaRule(on: true, weight: 2, color: 0xFF0000FF'u32, toText: true, offset: 4, dashed: true)
  let rl = layoutText(pr)
  var red, blue = 0
  for d in rl.decorations:
    if d.color == 0xFFFF0000'u32 and abs(d.x0 - 10) < 0.5 and abs(d.x1 - 310) < 0.5 and
       abs(d.y - (rl.lines[0].baseline - 20 - 1.5)) < 0.1: inc red
    if d.color == 0xFF0000FF'u32 and d.x1 <= rl.lines[0].x1 + 0.5: inc blue
  doAssert red == 1 and blue >= 2, $red & " " & $blue
  # Underline and Strikethrough Options
  var ul = newText("under", st, 0, 40)
  ul.spans[0].style.underline = true
  ul.spans[0].style.ulWeight = 4
  ul.spans[0].style.ulOffset = 6
  ul.spans[0].style.ulColor = 0xFF00FF00'u32
  ul.spans[0].style.strike = true
  ul.spans[0].style.stColor = 0xFF0000FF'u32
  var green, sblue = false
  for d in layoutText(ul).decorations:
    if d.color == 0xFF00FF00'u32 and abs(d.thick - 4) < 0.01 and abs(d.y - (40 + 6 + 2)) < 0.01: green = true
    if d.color == 0xFF0000FF'u32: sblue = true
  doAssert green and sblue
  # figure styles, positional forms
  let f1 = withFigureStyle("", 0)
  doAssert featureOn(f1, "tnum") and featureOn(f1, "lnum") and figureStyleOf(f1) == 0
  let f2 = withFigureStyle(f1, 1)
  doAssert not featureOn(f2, "tnum") and featureOn(f2, "onum") and figureStyleOf(f2) == 1
  doAssert figureStyleOf(withFigureStyle(f2, FigureStyles.high)) == FigureStyles.high
  doAssert positionalFormOf(withPositionalForm("", 3)) == 3 and positionalFormOf(withPositionalForm("+fina", 0)) == 0
  # kept
  t.para.hyphLimit = 2
  t.para.hyphZone = 12
  t.para.noHyphLast = true
  t.para.balanceRagged = true
  t.para.singleWord = swRight
  t.para.autoLead = 140
  t.para.ruleAbove = pr.para.ruleAbove
  let back = textFrom(t.toJson)
  doAssert back.para.hyphLimit == 2 and back.para.hyphZone == 12 and back.para.noHyphLast and
           back.para.balanceRagged and back.para.singleWord == swRight and back.para.autoLead == 140 and
           back.para.ruleAbove == pr.para.ruleAbove
  let back2 = textFrom(ul.toJson)
  doAssert back2.spans[0].style.ulWeight == 4 and back2.spans[0].style.ulColor == 0xFF00FF00'u32 and
           back2.spans[0].style.stColor == 0xFF0000FF'u32

block ligatures:
  # Ligatures off: the font's standard ones apart (fi, ffi); Arabic's lam + alef stays joined
  # (a required ligature), Hebrew's marks stay placed
  doAssert featureOn("", "liga") and featureOn("", "kern") and not featureOn("", "dlig")
  doAssert featureOn("+dlig", "dlig") and not featureOn("-liga", "liga")
  doAssert withLigatures("", false) == "-liga -clig" and withLigatures("-liga -clig", true) == ""
  doAssert withFeature("+ss01", "dlig", true) == "+ss01 +dlig" and withFeature("+dlig", "dlig", false) == ""
  let st = defaultStyle()
  proc count(s, feats: string): int =
    var x = st
    x.features = feats
    layoutText(newText(s, x)).glyphs.len
  doAssert count("office fi fl", "") < count("office fi fl", withLigatures("", false)), "fi, ffi, fl apart"
  doAssert count("لا الله", "") == count("لا الله", withLigatures("", false)), "lam + alef: required"
  doAssert count("لا", withLigatures("", false)) == 1, "lam + alef one"
  doAssert count("שָׁלוֹם", "") == count("שָׁלוֹם", withLigatures("", false))
  var s2 = st
  s2.features = withLigatures("", false)
  doAssert not s2.ligaturesOn

block oversetAndAutoSize:
  # text in a box keeps to it as the layout programs have it: a line too tall for the box is
  # overset, not drawn below it; Auto-Size makes the box as big as the text, its reference point
  # staying; kept with the text
  var t = newText("A heading", style(40), 50, 60)
  t.boxW = 400
  t.boxH = 20
  let lay = layoutText(t)
  doAssert lay.overflow == 0, "too tall for its box: overset (" & $lay.overflow & ")"
  for g in lay.glyphs: doAssert false, "nothing drawn of it"
  t.autoSize = asHeight
  var a = t.autoSized
  doAssert a.boxW == 400 and a.y == 60 and a.boxH > 40 and a.boxH < 80, $a.boxH
  doAssert layoutText(a).overflow < 0
  # smaller again: the box shorter too
  var t2 = a
  for sp in t2.spans.mitems: sp.style.size = 20
  let a2 = t2.autoSized
  doAssert a2.boxH < a.boxH * 0.7, $(a2.boxH, a.boxH)
  # its bottom middle stays
  t.autoRef = 7
  a = t.autoSized
  doAssert abs((a.y + a.boxH) - (t.y + t.boxH)) < 1e-3 and a.x == t.x
  # Width Only: one line as long as it is, its left side staying
  var w = newText("A line that is long enough to wrap in a narrow box", style(20), 50, 60)
  w.boxW = 120
  w.boxH = 300
  doAssert layoutText(w).lines.len > 1
  w.autoSize = asWidth
  let aw = w.autoSized
  doAssert aw.boxH == 300 and aw.x == 50 and aw.boxW > 300
  doAssert layoutText(aw).lines.len == 1
  # its right side staying
  w.autoRef = 2
  let ar = w.autoSized
  doAssert abs((ar.x + ar.boxW) - (w.x + w.boxW)) < 1e-3
  # Height and Width: the longest line wide, as tall as its lines
  var hw = newText("First\nThe second, longer", style(24), 10, 10)
  hw.boxW = 30
  hw.boxH = 500
  hw.autoSize = asBoth
  let ab = hw.autoSized
  doAssert layoutText(ab).lines.len == 2 and ab.boxH < 120 and ab.boxW > 100
  # Keep Proportions: as the box was, the smallest that holds it
  var kp = newText("Some words to hold in a box of its own shape here", style(20), 0, 0)
  kp.boxW = 100
  kp.boxH = 50
  kp.autoSize = asProportional
  let ak = kp.autoSized
  doAssert abs(ak.boxH / ak.boxW - 0.5) < 1e-3 and layoutText(ak).overflow < 0
  # kept with the text
  let back = textFrom(toJson(kp))
  doAssert back.autoSize == asProportional and back.autoRef == 0
  var none = newText("Point text", style(20), 0, 40)
  none.autoSize = asHeight
  doAssert none.autoSized.boxW == 0, "not in a box: as it is"

block aRightTabAtTheBoxEdge:
  # a table of contents: the page number on a right tab at the box's edge stays on its line,
  # whatever the sizes' sums round to
  carryDastkhat()
  var wrapped = 0
  for k in 0 ..< 300:
    let st = CharStyle(family: DastkhatFamily, style: "Regular", size: 14'f32 + float32(k) * 0.0937,
                       color: 0xFF000000'u32, hScale: 1, vScale: 1)
    var t = newText("", st, 118, 89)
    t.spans = @[TextSpan(text: "Contents\n", style: st), TextSpan(text: "Muscat and the coast\t2", style: st),
                TextSpan(text: "\nDhofar\t14", style: st)]
    t.boxW = 667 + float32(k mod 7) * 0.333
    t.boxH = 400
    t.para.tabs = @[TabStop(pos: t.boxW, align: tabRight, leader: ". ")]
    if layoutText(t).lines.len != 3: inc wrapped
  doAssert wrapped == 0, $wrapped & " entries broken at their number"

block justifiedPointText:
  # point text justified: each line as wide as the widest, where the lines were -- an Arabic
  # title's second line lengthened at its joins (Insert Kashida) to the first one's width
  carryDastkhat()
  var big = CharStyle(family: DastkhatFamily, style: "Bold", size: 60, color: 0xFF000000'u32, hScale: 1, vScale: 1)
  var small = big
  small.size = 40
  var t = newText("", big, 100, 100)
  t.spans = @[TextSpan(text: "النخلة العمانية\n", style: big),
              TextSpan(text: "من الحذر للثمره", style: small)]
  t.para.rtl = 2
  let plain = layoutText(t)
  doAssert plain.lines.len == 2
  let w0 = plain.lines[0].x1 - plain.lines[0].x0
  doAssert plain.lines[1].x1 - plain.lines[1].x0 < w0 - 50
  t.para.align = justifyAll
  t.para.kashida = kaLong
  let j = layoutText(t)
  doAssert j.lines.len == 2
  for ln in j.lines:
    doAssert abs((ln.x1 - ln.x0) - w0) < 1, $(ln.x0, ln.x1, w0)
    doAssert abs(ln.x0 - 100) < 1, "Justify All: from where it was (its left), as before"
  doAssert abs(j.lines[0].baseline - plain.lines[0].baseline) < 0.01 and
           abs(j.lines[1].baseline - plain.lines[1].baseline) < 0.01, "the lines where they were"
  doAssert j.glyphs.len > plain.glyphs.len, "lengthened at its joins: tatweels drawn"
  # Justify with the last line at the start: the last lines as before (a paragraph each)
  t.para.align = justifyLeft
  let jl = layoutText(t)
  for i in 0 .. 1:
    doAssert abs(jl.lines[i].x0 - plain.lines[i].x0) < 0.5 and abs(jl.lines[i].x1 - plain.lines[i].x1) < 0.5
  # one line, or a paragraph not justified: as it was
  var one = newText("Just one line", style(30), 50, 50)
  one.para.align = justifyAll
  let o = layoutText(one)
  one.para.align = textLeft
  doAssert abs(o.lines[0].x0 - layoutText(one).lines[0].x0) < 0.01

echo "textengine ok"
