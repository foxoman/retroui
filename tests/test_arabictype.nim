## Arabic typesetting, as an Arabic layout program has it: Find/Change with Arabic as written either
## way (harakat, tatweel, hamza's seats, ى/ي, ة/ه), the places mapped back onto the text as it is;
## a paragraph started in the next column (Insert Break Character); the jump lines' page numbers
## (`<#->`, `<#+>`: the box before's and after's page, in a document and across a book's pages);
## white spaces of a set width (em, en, thin, hair, figure); Copyfit (the type made to fill its box);
## the Quran's text (a Tanzil file's lines: looked up, searched either way, a passage with each
## ayah's number -- in ornate brackets or after the end-of-ayah sign --, a text typed by hand checked
## against it); the tashkeel moved by hand; Islamic patterns as shapes (stars and crosses, octagons
## with stars, six-pointed stars, a border).

import std/[strutils, math, tables]
import std/unicode except strip
import retroui/[photo, photobook, photoshapes, textengine, textsearch, quran, geopatterns]

var failures = 0
template check(cond: bool; what: string) =
  if cond: echo "  ok   ", what
  else:
    echo "  FAIL ", what
    inc failures

proc runes(s: string): seq[int] =
  for r in s.runes: result.add int(r)

block arabicFind:
  let t = newText("قَالَ: بِسْمِ اللَّهِ، وَكِتَـــابٌ فِي مَدْرَسَةٍ لِأَحْمَدَ عَلَى الطَّاوِلَةِ", defaultStyle(), 0, 0)
  for (what, label) in [("الله", "a word with its shadda and kasra: found without them"),
                        ("كتاب", "tatweel and tanwin left out"),
                        ("مدرسه", "ة as ه"),
                        ("لاحمد", "أ as ا"),
                        ("علي", "ى as ي")]:
    let m = t.findIn(what, arabic = true)
    check m.len == 1, label & " (" & $m.len & ")"
    check t.findIn(what).len == 0, "... and not without the option: " & what
  let m = t.findIn("الله", arabic = true)
  let cps = runes(t.plainText)
  var got = ""
  for i in m[0].a ..< m[0].b: got.add $Rune(cps[i])
  check got == "اللَّهِ", "the place as written, its marks with it: " & got
  var u = t
  check u.changeIn("كتاب", "دفتر", arabic = true) == 1 and "دفتر" in u.plainText and "كِتَـــابٌ" notin u.plainText,
        "Change: as written either way, the rest kept"
  check arabicFolded("أَإِآٱؤئىة") == "ااااوييه", "the letters as matched: " & arabicFolded("أَإِآٱؤئىة")
  let p = patternOf(arabicFolded("الحمد"), false, false, false)
  let f = p.findFolded(runes("قُلِ الْحَمْدُ لِلَّهِ"), 0)
  check f.a == 5 and f.b == 14, "a search found where it is written, the last letter's mark with it (" &
        $f.a & ".." & $f.b & ")"

block breakChars:
  var t = newText("One short line.\nThe next paragraph starts in the next column.", defaultStyle(), 0, 0)
  t.boxW = 400
  t.boxH = 300
  t.columns = 2
  let plain = layoutText(t)
  t.changeParas(17, 17, proc (p: var ParaStyle) = p.startAt = psNextColumn)
  let broken = layoutText(t)
  var lastX0, lastX1 = 0'f32
  for ln in plain.lines: lastX0 = max(lastX0, ln.x0)
  for ln in broken.lines: lastX1 = max(lastX1, ln.x0)
  check lastX0 < 150 and lastX1 > 150, "a column break: the next paragraph in the second column (" &
        $lastX0.int & " -> " & $lastX1.int & ")"
  t.changeParas(17, 17, proc (p: var ParaStyle) = p.startAt = psNextFrame)
  check layoutText(t).overflow >= 0, "a frame break: the rest goes on in the next frame (overset here)"

block jumps:
  let d = newDoc(400, 300, 0xFFFFFFFF'u32)
  var a = newText("Story <#+> end", defaultStyle(), 10, 10)
  a.boxW = 150
  a.boxH = 40
  let La = d.addTextLayer(a)
  var b = newText("", defaultStyle(), 200, 10)
  b.boxW = 150
  b.boxH = 100
  let Lb = d.addTextLayer(b)
  Lb.flowFrom = uidOf(La)
  check "1" in d.effectiveText(La).plainText and "<#+>" notin d.effectiveText(La).plainText,
        "in one document: the next box's page (" & d.effectiveText(La).plainText & ")"
  var st = bookSetup(200, 300, dpi = 72, facing = false)
  let bk = newBook(st, pages = 3, name = "Jumps")
  let d0 = bk.doc(0)
  var s0 = newText("Continued on page <#+>. " & repeat("A line of the story. ", 60), defaultStyle(), 0, 0)
  let L0 = d0.addTextLayer(bk.boxed(s0, 0))
  let M = bk.flowOnto(0, L0, 2)
  var mt = M.text
  mt.spans = @[TextSpan(text: "From page <#->: ", style: defaultStyle())]
  bk.doc(2).setText(M, mt)
  discard bk.settle(0)
  discard bk.doc(0)
  discard bk.doc(2)
  discard bk.settle(2)
  let e0 = bk.doc(0).effectiveText(L0).plainText
  check "Continued on page 3" in e0, "a book: the next box is on page 3 (" & e0[0 ..< min(30, e0.len)] & ")"
  let jm = bk.doc(2).jumps.getOrDefault(uidOf(M), ("", ""))
  check jm.prev == "1", "... and the box there comes from page 1 (" & jm.prev & ")"
  bk.close()

block whiteSpaces:
  var st = defaultStyle()
  st.size = 40
  proc widthOf(s: string): float32 =
    let l = layoutText(newText(s, st, 0, 0))
    l.lines[0].x1 - l.lines[0].x0
  let ab = widthOf("ab")
  check abs(widthOf("a b") - ab - 40) < 0.6, "an em space: the size across (" & $(widthOf("a b") - ab) & ")"
  check abs(widthOf("a b") - ab - 20) < 0.6, "an en space: half"
  check abs(widthOf("a b") - ab - 5) < 0.6, "a thin space: an eighth"
  check abs(widthOf("a b") - ab - 40 / 24) < 0.6, "a hair space: a 24th"
  check abs(widthOf("a b") - widthOf("a0b")) < 0.6, "a figure space: as wide as a digit"
  check fixedSpaceEm(0x20) == 0 and fixedSpaceEm(0x2003) == 1, "only those of a set width"

block copyfitting:
  var t = newText(repeat("Words that fill the box. ", 30), defaultStyle(), 0, 0)
  t.boxW = 300
  t.boxH = 200
  check layoutText(t).overflow >= 0, "the text overset at first"
  let (u, k) = copyfit(t)
  check k < 1 and layoutText(u).overflow < 0, "Copyfit: smaller, all of it in (" & formatFloat(k, ffDecimal, 3) & ")"
  check layoutText(scaledType(t, k * 1.01)).overflow >= 0, "... and no bigger would fit"
  var short = newText("A few words.", defaultStyle(), 0, 0)
  short.boxW = 300
  short.boxH = 200
  let (v, k2) = copyfit(short)
  check k2 > 1 and layoutText(v).overflow < 0, "a short text made bigger to fill it (" & formatFloat(k2, ffDecimal, 2) & ")"
  check abs(v.spans[0].style.size - short.spans[0].style.size * k2) < 0.01, "its sizes in proportion"

block quranText:
  # (a few lines in a Tanzil file's form: the program's own test, not the text to typeset)
  let data = "# a test\n" &
    "1|1|بِسْمِ اللَّهِ الرَّحْمَٰنِ الرَّحِيمِ\n" &
    "1|2|الْحَمْدُ لِلَّهِ رَبِّ الْعَالَمِينَ\n" &
    "1|3|الرَّحْمَٰنِ الرَّحِيمِ\n" &
    "1|4|مَالِكِ يَوْمِ الدِّينِ\n" &
    "112|1|قُلْ هُوَ اللَّهُ أَحَدٌ\n" &
    "\n# Tanzil's note\n"
  let q = parseQuran(data)
  check q.ayat.len == 5 and q.suras == 2 and q.ayatIn(1) == 4 and q.ayatIn(112) == 1, "read: 5 ayat in 2 suras"
  check suraName(1) == "الفاتحة" and suraName(114) == "الناس" and suraName(115) == "", "the suras' names"
  check q.ayah(1, 2).startsWith("الْحَمْدُ"), "an ayah looked up"
  let hits = q.search("الحمد لله")
  check hits.len == 1 and hits[0] == (1, 2), "searched without harakat: " & $hits
  check q.search("احد").len == 1, "... أ as ا"
  let p = q.passage(1, 1, 2, aeSign)
  check p.count(AyahEnd) == 2 and "۱" notin p and arabicDigits(2) in p and p.endsWith(ayahMark(2, aeSign)),
        "a passage: each ayah's end sign and number"
  let pb = q.passage(1, 1, 2)
  check pb.endsWith(" ﴿٢﴾") and pb.count("﴿") == 2 and AyahEnd notin pb and
        q.passage(1, 1, 2, aeNone).count(" ") == q.ayah(1, 1).count(" ") + q.ayah(1, 2).count(" ") + 1,
        "... or the number in ornate brackets, or none"
  check q.checkTyped(pb, 1, 1, 2).len == 0, "typed with the brackets: the same"
  check q.checkTyped(q.passage(1, 1, 3), 1, 1, 3).len == 0, "the text itself checked: the same"
  check q.checkTyped("بِسْمِ اللَّهِ الرَّحْمَٰنِ الرَّحِيمِ الْحَمْدُ لِلَّهِ رَبِّ الْعَالَمِينَ", 1, 1, 2).len == 0,
        "typed without the numbers: the same"
  let typed = "بِسْمِ اللَّهِ الرَّحْمَنِ الرَّحِيمِ"      # (the dagger alif left out)
  let diffs = q.checkTyped(typed, 1, 1, 1)
  check diffs.len == 1, "a mark left out: one place (" & $diffs & ")"
  let wrong = "بِسْمِ اللَّهِ الرَّحْمَٰنِ الرَّحِيمُ"     # (a damma for the kasra)
  let d2 = q.checkTyped(wrong, 1, 1, 1)
  var at = ""
  if d2.len == 1:
    var i = 0
    for r in wrong.runes:
      if i >= d2[0].a and i < d2[0].b: at.add r.toUTF8
      inc i
  check d2.len == 1 and at == "ُ", "a wrong mark: found where it is"
  var raised = false
  try: discard parseQuran("not a quran")
  except ValueError: raised = true
  check raised, "not a Tanzil file: said so"

block marksMoved:
  var st = defaultStyle()
  st.size = 48
  st.family = "FreeSerif"
  let t0 = newText("بِسْمِ", st, 100, 100)
  var st2 = st
  st2.markShift = 6
  st2.markRaise = 4
  let t1 = newText("بِسْمِ", st2, 100, 100)
  let a = layoutText(t0)
  let b = layoutText(t1)
  var moved, kept = 0
  if a.glyphs.len == b.glyphs.len:
    for i in 0 ..< a.glyphs.len:
      let dx = b.glyphs[i].x - a.glyphs[i].x
      let dy = b.glyphs[i].y - a.glyphs[i].y
      if abs(abs(dx) - 6) < 0.01 and abs(dy + 4) < 0.01: inc moved
      elif abs(dx) < 0.01 and abs(dy) < 0.01: inc kept
  check moved >= 2 and kept >= 2 and moved + kept == a.glyphs.len,
        "the marks moved by hand -- across and up --, the letters where they were (" & $moved & " marks, " & $kept & ")"
  check charStyleFrom(toJson(st2)).markShift == 6, "kept in the file"

block patterns:
  let d = newDoc(400, 400, 0xFFFFFFFF'u32)
  let p = geoPattern(gpStarCross, 0, 0, 400, 400, 100)
  check p.subs.len == 16 and p.subs[0].pts.len == 16, "eight-pointed stars on a grid: 16, each of 16 corners"
  discard d.addShapeLayer(ShapeData(path: p, fill: solidPaint(0xFF204080'u32)), "Khatam")
  d.markAll()
  d.updateComposite()
  let c = d.compPtr
  check c[50 * 400 + 50] == 0xFF204080'u32 and c[100 * 400 + 100] == 0xFFFFFFFF'u32,
        "a star's middle filled, the cross between four of them not"
  let d2 = newDoc(400, 400, 0xFFFFFFFF'u32)
  let o = geoPattern(gpOctagons, 0, 0, 400, 400, 100)
  check o.subs.len == 32, "octagons, each with its star: 32"
  discard d2.addShapeLayer(ShapeData(path: o, fill: solidPaint(0xFF802020'u32)), "Octagons")
  d2.markAll()
  d2.updateComposite()
  let c2 = d2.compPtr
  # (between two of the star's points, inside the octagon: 40 px out at 202.5 degrees)
  check c2[50 * 400 + 50] == 0xFFFFFFFF'u32 and c2[35 * 400 + 13] == 0xFF802020'u32,
        "an octagon filled round its star, the star the paper (" & c2[50 * 400 + 50].toHex & ", " &
        c2[35 * 400 + 13].toHex & ")"
  check geoPattern(gpHexagrams, 0, 0, 400, 400, 80).subs.len >= 20, "six-pointed stars"
  let br = geoBorder(0, 0, 400, 300, 40)
  check br.subs.len == 4 + 2 * 8 + 2 * 5, "a border: a star in each corner, the sides between (" & $br.subs.len & ")"

if failures > 0:
  echo "test_arabictype: ", failures, " failed"
  quit(1)
echo "test_arabictype: all passed"
