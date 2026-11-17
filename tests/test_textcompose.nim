## Tests of the layout programs' paragraph and frame settings in retroui/textengine: paragraph
## formats of their own, the Paragraph Composer, Justification, Keep Options, Span Columns, nested
## and GREP styles, Inset Spacing, Vertical Justification, Balance Columns.

import std/[json, strutils]
import std/unicode except strip
import retroui/textengine
{.push warning[UnusedImport]: off.}
import retroui/textsearch   # (imported for what it sets up: GREP styles find their matches with it)
{.pop.}

proc style(size = 20'f32): CharStyle =
  result = defaultStyle()
  result.size = size

proc words(n: int; seed = 1): string =
  ## (`n` words of different lengths)
  const ws = ["the", "layout", "of", "a", "paragraph", "is", "weighed", "whole", "so", "its", "spaces",
              "stay", "even", "and", "rivers", "are", "fewer", "than", "line", "by"]
  var k = seed
  for i in 0 ..< n:
    if i > 0: result.add ' '
    result.add ws[k mod ws.len]
    k = (k * 7 + 3) mod 101

proc boxText(s: string; w, h: float32; cols = 1): TextData =
  result = newText(s, style(), 10, 20)
  result.boxW = w
  result.boxH = h
  result.columns = cols
  result.gutter = 10

proc lineText(t: TextData; ln: LaidLine): string =
  let r = t.plainText.toRunes
  $r[ln.first ..< min(ln.last, r.len)]

block paragraphFormats:
  # each paragraph in a format of its own; editing keeps them
  var t = boxText("One\nTwo\nThree", 300, 300)
  var c = t.para
  c.align = textCenter
  t.setParaFmt(5, 5, c)
  doAssert t.paraFmts.len == 1
  doAssert t.paraFmtAt(0).align == textLeft
  doAssert t.paraFmtAt(5).align == textCenter
  doAssert t.paraFmtAt(9).align == textLeft
  let lay = layoutText(t)
  doAssert lay.lines.len == 3
  doAssert lay.paras.len == 3 and lay.paras[1].align == textCenter
  doAssert lay.lines[1].x0 > lay.lines[0].x0 + 50           # (centered)
  # (a paragraph split: both halves keep its format)
  t.insertText(5, "\n", t.styleAt(5))
  doAssert t.paraFmtAt(4).align == textCenter and t.paraFmtAt(6).align == textCenter
  # (two joined: the first one's)
  var u = boxText("One\nTwo", 300, 300)
  u.setParaFmt(4, 4, c)
  u.deleteText(3, 4)
  doAssert u.plainText == "OneTwo"
  doAssert u.paraFmtAt(4).align == textLeft and u.paraFmts.len == 0
  # (all of them: the text's own)
  var v = boxText("A\nB", 300, 300)
  v.setParaFmt(0, 3, c)
  doAssert v.para.align == textCenter and v.paraFmts.len == 0
  # (a change to the paragraphs picked: each keeps the rest of its own format)
  var m = boxText("A\nB\nC", 300, 300)
  m.changeParas(2, 2, proc (p: var ParaStyle) = p.indentLeft = 10)
  m.changeParas(2, 4, proc (p: var ParaStyle) = p.align = textCenter)
  doAssert m.paraFmtAt(0).align == textLeft and m.paraFmtAt(2).align == textCenter and
           m.paraFmtAt(4).align == textCenter
  doAssert m.paraFmtAt(2).indentLeft == 10 and m.paraFmtAt(4).indentLeft == 0
  m.changeParas(0, m.runeLen, proc (p: var ParaStyle) = p.align = textRight)
  doAssert m.paraFmtAt(0).align == textRight and m.paraFmtAt(2).align == textRight and
           m.paraFmtAt(2).indentLeft == 10 and m.paraFmtAt(4).indentLeft == 0
  # (typed at a paragraph's start: in that paragraph's format)
  m.insertText(2, "x", defaultStyle())
  doAssert m.paraFmtAt(2).indentLeft == 10 and m.plainText == "A\nxB\nC"
  # (an empty paragraph at the end keeps a format of its own for what is typed in it)
  var e = boxText("A\n", 300, 300)
  var ce = e.para
  ce.align = textRight
  e.setParaFmt(2, 2, ce)
  doAssert e.paraFmtAt(2).align == textRight and e.paraFmtAt(0).align == textLeft
  doAssert layoutText(e).paras.len == 2 and layoutText(e).paras[1].align == textRight
  doAssert textFrom(parseJson($e.toJson)).paraFmtAt(2).align == textRight
  e.insertText(2, "B", defaultStyle())
  doAssert e.paraFmtAt(2).align == textRight and e.tailFmt == 0 and e.paraFmtAt(0).align == textLeft
  # (the first paragraph's format is the text's own: what the whole text keeps is its)
  var f = boxText("A\nB", 300, 300)
  f.setParaFmt(0, 0, ce)
  doAssert f.para.align == textRight and f.paraFmts.len == 1
  # (one format all through: the text's own)
  var one = boxText("A\nB", 300, 300)
  one.changeParas(0, one.runeLen, proc (p: var ParaStyle) = p.align = textCenter)
  doAssert one.para.align == textCenter and one.paraFmts.len == 0
  # saved and read back
  var w = boxText("Head\nBody text here", 300, 300)
  var h = w.para
  h.spanAll = true
  h.keepWithNext = 2
  h.keepTogether = true
  h.keepStart = 2
  h.keepEnd = 3
  h.startAt = psNextColumn
  h.composer = cpParagraph
  h.wordSpacing = [70'i16, 90, 150]
  h.letterSpacing = [-5'i16, 0, 10]
  h.glyphScaling = [97'i16, 100, 103]
  h.splitColumns = 0
  h.nextStyle = "Body"
  h.nested = @[NestedStyle(name: "Lead", look: style(30), count: 2, unit: nuWords)]
  h.grepStyles = @[GrepStyle(name: "Digits", look: style(12), pattern: "\\d+")]
  w.setParaFmt(0, 0, h)
  w.inset = [4'f32, 5, 6, 7]
  w.vjust = vjCenter
  w.balance = true
  let back = textFrom(parseJson($w.toJson))
  doAssert back.paraFmts == w.paraFmts
  doAssert back.inset == w.inset and back.vjust == vjCenter and back.balance
  doAssert back.spans.len == w.spans.len
  for i in 0 ..< w.spans.len: doAssert back.spans[i].style.para == w.spans[i].style.para
  doAssert paraFrom(parseJson($paraToJson(h))) == h

block composer:
  # the Paragraph Composer: justified lines' spaces more even than a line at a time
  let s = words(90, 3)
  var single = boxText(s, 260, 2000)
  single.para.align = justifyLeft
  single.para.composer = cpSingle
  var whole = single
  whole.para.composer = cpParagraph
  proc spread(t: TextData): float =
    ## (how far the lines' word spaces are from a space's own width, squared and summed)
    let lay = layoutText(t)
    let r = t.plainText.toRunes
    var spaceW = 0'f32
    for g in lay.glyphs:
      if g.index < r.len and int(r[g.index]) == 32: spaceW = g.adv
    for i, ln in lay.lines:
      if i == lay.lines.high: continue
      let spaces = lineText(t, ln).strip.count(' ')
      if spaces == 0: continue
      # (each line spans the box: the room left over is shared by the spaces)
      var natural = 0'f32
      for g in lay.glyphs:
        if g.index >= ln.first and g.index < ln.last and int(r[g.index]) != 32: natural += g.adv
      let each = ((ln.x1 - ln.x0) - natural) / float32(spaces) - spaceW
      result += float(each) * float(each)
  let a = layoutText(single)
  let b = layoutText(whole)
  doAssert a.lines.len > 5 and b.lines.len > 5
  # (every line in the box; every letter laid out once, in order)
  for lay in [a, b]:
    var prev = -1
    for ln in lay.lines:
      doAssert ln.x1 <= 10 + 260 + 0.5 and ln.x0 >= 10 - 0.5
      doAssert ln.first >= prev
      prev = ln.first
  doAssert spread(whole) < spread(single)
  for seed in [5, 8, 11]:
    var a1 = boxText(words(90, seed), 260, 2000)
    a1.para.align = justifyLeft
    a1.para.composer = cpSingle
    var b1 = a1
    b1.para.composer = cpParagraph
    doAssert spread(b1) <= spread(a1) + 0.01
  # (Auto: unjustified text as it was, a line at a time)
  var plainAuto = boxText(s, 260, 2000)
  var plainSingle = plainAuto
  plainSingle.para.composer = cpSingle
  let la = layoutText(plainAuto)
  let ls = layoutText(plainSingle)
  doAssert la.lines.len == ls.lines.len
  for i in 0 ..< la.lines.len: doAssert la.lines[i].first == ls.lines[i].first

block justification:
  # glyph scaling lets a justified line's letters widen
  let s = words(40, 5)
  var t = boxText(s, 240, 2000)
  t.para.align = justifyLeft
  t.para.glyphScaling = [95'i16, 100, 105]
  let lay = layoutText(t)
  var scaled = false
  for g in lay.glyphs:
    if abs(g.hScale - 1) > 0.001 and g.hScale > 0: scaled = true
  doAssert scaled
  # letter spacing: a line's room shared between its letters too
  var u = boxText(s, 240, 2000)
  u.para.align = justifyLeft
  u.para.letterSpacing = [0'i16, 0, 20]
  let lu = layoutText(u)
  doAssert lu.lines.len > 2

block keepOptions:
  # Keep Lines Together: a paragraph not broken between columns
  var paras: seq[string]
  for i in 0 ..< 6: paras.add words(14, i + 2)
  let s = paras.join("\n")
  var t = boxText(s, 400, 180, cols = 2)
  let free = layoutText(t)
  # (where the first column ends without keeps)
  proc colOfLine(lay: TextLayout; i: int): int = (if lay.lines[i].x0 > 10 + 195: 1 else: 0)
  var broken = -1
  for i in 1 ..< free.lines.len:
    if colOfLine(free, i) != colOfLine(free, i - 1) and free.lines[i].para == free.lines[i - 1].para:
      broken = free.lines[i].para
  doAssert broken >= 0
  if broken >= 0:
    var k = t.paraFmtAt(0)
    k.keepTogether = true
    let (a, _) = block:
      var at = 0
      for p in 0 ..< broken: at += paras[p].runeLen + 1
      (at, 0)
    t.setParaFmt(a, a, k)
    let kept = layoutText(t)
    var cols: seq[int]
    for i, ln in kept.lines:
      if ln.para == broken: cols.add colOfLine(kept, i)
    var same = true
    for c in cols:
      if c != cols[0]: same = false
    doAssert same
  # Start Paragraph in the next column
  var u = boxText("First\nSecond\nThird", 400, 300, cols = 2)
  var nc = u.para
  nc.startAt = psNextColumn
  u.setParaFmt(6, 6, nc)
  let lu = layoutText(u)
  doAssert lu.lines.len == 3
  doAssert lu.lines[0].x0 < 200 and lu.lines[1].x0 > 200 and lu.lines[2].x0 > 200
  doAssert abs(lu.lines[1].baseline - lu.lines[0].baseline) < 0.5     # (at the column's top)
  # ... in the next frame: the rest overset
  var nf = u.para
  nf.startAt = psNextFrame
  var v = boxText("First\nSecond", 400, 300, cols = 2)
  v.setParaFmt(6, 6, nf)
  let lv = layoutText(v)
  doAssert lv.lines.len == 1 and lv.overflow == 6
  # Keep with Next: a heading goes along with its paragraph
  var heads = ""
  for i in 0 ..< 5: heads.add words(1, i + 7) & "\n"    # (five short lines, the heading the sixth)
  heads.add "Heading\n" & words(30, 4)
  var w = boxText(heads, 400, 160, cols = 2)
  let lw0 = layoutText(w)
  let hp = 5
  var hk = w.para
  hk.keepWithNext = 2
  let hstart = heads.find("Heading")
  w.setParaFmt(hstart, hstart, hk)
  let lw = layoutText(w)
  var hcol, ncol = -1
  for i, ln in lw.lines:
    if ln.para == hp: hcol = colOfLine(lw, i)
    if ln.para == hp + 1 and ncol < 0: ncol = colOfLine(lw, i)
  doAssert hcol >= 0 and hcol == ncol
  # (without it the heading was left at the foot of the first column)
  var hcol0, ncol0 = -1
  for i, ln in lw0.lines:
    if ln.para == hp: hcol0 = colOfLine(lw0, i)
    if ln.para == hp + 1 and ncol0 < 0: ncol0 = colOfLine(lw0, i)
  doAssert hcol0 != ncol0

block spanColumns:
  # a heading across the columns, the text in columns under it
  let s = "A heading across both of the columns\n" & words(60, 9)
  var t = boxText(s, 400, 400, cols = 2)
  var h = t.para
  h.spanAll = true
  t.setParaFmt(0, 0, h)
  let lay = layoutText(t)
  doAssert lay.lines[0].x1 - lay.lines[0].x0 > 195        # (wider than a column)
  var left, right = 0
  var below = true
  for i in 1 ..< lay.lines.len:
    if lay.lines[i].x0 > 210: inc right else: inc left
    if lay.lines[i].baseline - lay.lines[i].ascent < lay.lines[0].baseline: below = false
  doAssert below and left > 0
  # (the columns above a span balanced, as the layout program has them)
  let before = words(40, 4)
  var u0 = boxText(before & "\nAcross them\n" & words(20, 6), 400, 600, cols = 2)
  u0.setParaFmt(before.len + 2, before.len + 2, h)
  let lu0 = layoutText(u0)
  var l1, r1 = 0
  var headTop = 0'f32
  for ln in lu0.lines:
    if ln.para == 1: headTop = ln.baseline - ln.ascent
  for ln in lu0.lines:
    if ln.para == 0:
      if ln.x0 > 210: inc r1 else: inc l1
      doAssert ln.baseline + ln.descent <= headTop + 0.5
    if ln.para == 2: doAssert ln.baseline - ln.ascent >= headTop
  doAssert r1 > 0 and abs(l1 - r1) <= 1
  # split into columns of its own
  var u = boxText(words(40, 2), 400, 400)
  u.para.splitColumns = 2
  let lu = layoutText(u)
  var xs: seq[float32]
  for ln in lu.lines:
    var found = false
    for x in xs:
      if abs(x - ln.x0) < 2: found = true
    if not found: xs.add ln.x0
  doAssert xs.len == 2

block balance:
  var t = boxText(words(50, 1), 400, 600, cols = 2)
  let free = layoutText(t)
  t.balance = true
  let even = layoutText(t)
  doAssert free.lines.len == even.lines.len
  var l0, r0 = 0
  for ln in even.lines:
    if ln.x0 > 210: inc r0 else: inc l0
  doAssert abs(l0 - r0) <= 1 and r0 > 0

block insetAndVertical:
  var t = boxText("Hello there", 200, 200)
  let a = layoutText(t)
  t.inset = [10'f32, 0, 0, 15]
  let b = layoutText(t)
  doAssert abs((b.lines[0].x0 - a.lines[0].x0) - 15) < 0.5
  doAssert abs((b.lines[0].baseline - a.lines[0].baseline) - 10) < 0.5
  t.inset = [0'f32, 0, 0, 0]
  t.vjust = vjBottom
  let c = layoutText(t)
  doAssert abs(c.lines[0].baseline + c.lines[0].descent - (20 + 200)) < 1
  t.vjust = vjCenter
  let d = layoutText(t)
  let mid = (d.lines[0].baseline - d.lines[0].ascent + d.lines[0].baseline + d.lines[0].descent) / 2
  doAssert abs(mid - (20 + 100)) < 3
  # (Justify: the lines spread from top to bottom)
  var j = boxText("One\nTwo\nThree", 200, 300)
  j.vjust = vjJustify
  let lj = layoutText(j)
  doAssert abs(lj.lines[^1].baseline + lj.lines[^1].descent - 320) < 1
  doAssert abs(lj.lines[0].baseline - layoutText(boxText("One\nTwo\nThree", 200, 300)).lines[0].baseline) < 0.5

block nestedAndGrep:
  # the first two words in a style of their own; digits in another
  var t = boxText("Chapter one 2026 begins here", 400, 200)
  var big = style(40)
  big.color = 0xFFFF0000'u32
  var red = style(20)
  red.color = 0xFF00FF00'u32
  t.para.nested = @[NestedStyle(name: "Lead", look: big, count: 2, unit: nuWords)]
  t.para.grepStyles = @[GrepStyle(name: "Year", look: red, pattern: "\\d+")]
  let lay = layoutText(t)
  var sizes: array[32, float32]
  var colors: array[32, uint32]
  for g in lay.glyphs:
    if g.index < 32:
      sizes[g.index] = g.size
      colors[g.index] = g.color
  doAssert sizes[0] > sizes[20] + 5                 # ("Chapter" big)
  doAssert sizes[8] > sizes[20] + 5                 # ("one" big)
  doAssert colors[12] == 0xFF00FF00'u32             # ("2026" green)
  doAssert colors[20] != 0xFF00FF00'u32
  # up to a character
  var u = boxText("Name: the rest", 400, 200)
  u.para.nested = @[NestedStyle(name: "Lead", look: big, count: 1, unit: nuUpTo, upTo: ":", through: true)]
  let lu = layoutText(u)
  var su: array[16, float32]
  for g in lu.glyphs:
    if g.index < 16: su[g.index] = g.size
  doAssert su[0] > su[8] + 5 and su[4] > su[8] + 5 and su[7] < su[0]

block nestedLineStyles:
  # the first line in a style of its own (Nested Line Styles): where the line breaks, as laid out
  # with it; then two lines each way, repeated; a nested style wins where both reach
  var small = style(14)
  small.color = 0xFF0000FF'u32
  var t = boxText(words(60), 260, 600)
  t.para.lineStyles = @[NestedLine(name: "Small caps", look: small, lines: 1)]
  let lay = layoutText(t)
  doAssert lay.lines.len >= 4
  var firstSmall = true
  var restPlain = true
  for g in lay.glyphs:
    if g.index >= lay.lines[0].first and g.index < lay.lines[0].last:
      if g.color != 0xFF0000FF'u32 or abs(g.size - 14) > 0.01: firstSmall = false
    elif g.index >= lay.lines[1].first:
      if g.color == 0xFF0000FF'u32: restPlain = false
  doAssert firstSmall and restPlain
  # (the first line, smaller, holds more than it did at 20 pixels)
  var plain = t
  plain.para.lineStyles = @[]
  doAssert lay.lines[0].last > layoutText(plain).lines[0].last
  # repeated: two lines blue, one plain, then the last two styles again ([Repeat]): the same
  var r = t
  var blue = style(20)
  blue.color = 0xFF0000FF'u32
  r.para.lineStyles = @[NestedLine(name: "Blue", look: blue, lines: 2), NestedLine(name: "", look: style(), lines: 1)]
  r.para.repeatLast = 2
  let lr = layoutText(r)
  proc lineBlue(l: TextLayout; i: int): bool =
    for g in l.glyphs:
      if g.index >= l.lines[i].first and g.index < l.lines[i].last and g.color == 0xFF0000FF'u32: return true
  doAssert lr.lines.len >= 6
  doAssert lineBlue(lr, 0) and lineBlue(lr, 1) and not lineBlue(lr, 2)
  doAssert lineBlue(lr, 3) and lineBlue(lr, 4) and not lineBlue(lr, 5)
  # a nested style wins
  var n = t
  var big = style(20)
  big.color = 0xFFFF0000'u32
  n.para.nested = @[NestedStyle(name: "Lead", look: big, count: 1, unit: nuWords)]
  let ln = layoutText(n)
  for g in ln.glyphs:
    if g.index == 0: doAssert g.color == 0xFFFF0000'u32
    if g.index == ln.lines[0].last - 2: doAssert g.color == 0xFF0000FF'u32
  # kept with the text
  let back = textFrom(t.toJson).para
  doAssert back.lineStyles.len == 1 and back.lineStyles[0].lines == 1 and back.lineStyles[0].name == "Small caps"
  doAssert textFrom(r.toJson).para.repeatLast == 2
  # [Repeat] of the last one alone: blue twice, plain, then plain on
  r.para.repeatLast = 1
  let l1 = layoutText(r)
  doAssert lineBlue(l1, 0) and lineBlue(l1, 1) and not lineBlue(l1, 2) and not lineBlue(l1, 3) and not lineBlue(l1, 4)

block opticalMargin:
  # quotes and punctuation hung out of the box's edges; the letters' edges too, optically
  proc firstX(l: TextLayout; i: int): float32 =
    result = 1e9
    for g in l.glyphs:
      if g.index == l.lines[i].first: result = min(result, g.x)
  var t = boxText("\u201CQuoted words\u201D start this line. " & words(40), 300, 1000)
  let plain = layoutText(t)
  doAssert abs(firstX(plain, 0) - 10) < 0.01                 # (the box's left edge)
  t.para.hanging = true
  let hung = layoutText(t)
  doAssert firstX(hung, 0) < 10 - 4                          # (the quote out of the box, all of it)
  doAssert hangOf(0x201C, false) == 1 and hangOf(0x2014, false) == 0.5 and hangOf(ord('A'), false) == 0
  doAssert hangOf(ord('A'), true) > 0 and hangOf(ord('a'), true) == 0
  # justified: the line runs out of the right edge by its period
  var j = boxText(words(30) & ".", 260, 1000)
  j.para.align = justifyLeft
  j.opticalMargin = true
  let lj = layoutText(j)
  for i in 0 ..< lj.lines.len - 1:
    doAssert lj.lines[i].x1 >= 10 + 260 - 0.5
  # Ignore Optical Margin: as it was
  j.para.ignoreOptical = true
  let lk = layoutText(j)
  for i in 0 ..< lk.lines.len - 1:
    doAssert abs(lk.lines[i].x1 - (10 + 260)) < 0.5
  # kept with the text
  let back = textFrom(t.toJson)
  doAssert back.para.hanging and not back.opticalMargin
  doAssert textFrom(j.toJson).opticalMargin and textFrom(j.toJson).para.ignoreOptical
  # right aligned: the period hangs out at the right
  var r = boxText("Short line.", 300, 100)
  r.para.align = textRight
  let r0 = layoutText(r)
  r.para.hanging = true
  let r1 = layoutText(r)
  doAssert r1.lines[0].x0 > r0.lines[0].x0 + 1

echo "test_textcompose: ok"
