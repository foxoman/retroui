## Tests of right-to-left text: the bidirectional algorithm against the
## Unicode reference (a corpus of Arabic, Persian and mixed lines, and lines
## of Unicode's own conformance tests), Arabic joining with the zero width
## joiners, then text boxes, the rich editor, PDF files and workbooks with
## Arabic in them, and the right-to-left interface -- headless, on the fake
## driver.
##
##   nim c -r tests/test_bidi.nim

import std/[strutils, sequtils, os]
from std/unicode import runes, toUTF8, Rune, `$`
import retroui, retroui/[typeset, richedit, charts, pdf, pdfread, xlsx, codec, lang_ar, canvas2d]
import retroui/uirelays/[input, services]
import harness

# ---- the bidi algorithm ------------------------------------------------------------------------

proc display(s: string; dir: int): string =
  ## (line `s` as shown, left to right: its characters in visual order,
  ## not mirrored, those the algorithm leaves out -- joiners, embeddings --
  ## dropped: as the reference gives it)
  let rs = toSeq(s.runes)
  let bi = bidiInfo(s, dir)
  var order = visualOrderOf(bi.levels)
  if order.len == 0: order = toSeq(0 ..< rs.len)
  for i in order:
    let c = int(rs[i])
    if c in 0x202A .. 0x202E or c in [0x200B, 0x200C, 0x200D, 0x2060, 0xFEFF, 0xAD]: continue
    result.add $rs[i]

const corpus = [
  # (the text, its paragraph direction: -1 from the text, 0 left to right,
  # 1 right to left; as the reference shows it -- python-bidi, the Rust
  # unicode-bidi crate)
  ("مرحبا بالعالم", -1, "ملاعلاب ابحرم"),
  ("مرحبا بالعالم", 0, "ملاعلاب ابحرم"),
  ("مرحبا بالعالم", 1, "ملاعلاب ابحرم"),
  ("العدد 123 والعدد ١٢٣ و ۴۵۶", -1, "۴۵۶ و ١٢٣ ددعلاو 123 ددعلا"),
  ("العدد 123 والعدد ١٢٣ و ۴۵۶", 0, "۴۵۶ و ١٢٣ ددعلاو 123 ددعلا"),
  ("العدد 123 والعدد ١٢٣ و ۴۵۶", 1, "۴۵۶ و ١٢٣ ددعلاو 123 ددعلا"),
  ("ارتفع الأداء بنسبة 25% في Q4 2026.", -1, ".Q4 2026 يف %25 ةبسنب ءادألا عفترا"),
  ("ارتفع الأداء بنسبة 25% في Q4 2026.", 0, "يف %25 ةبسنب ءادألا عفترا Q4 2026."),
  ("ارتفع الأداء بنسبة 25% في Q4 2026.", 1, ".Q4 2026 يف %25 ةبسنب ءادألا عفترا"),
  ("يعتمد النظام على GPS وTCP/IP.", -1, ".TCP/IPو GPS ىلع ماظنلا دمتعي"),
  ("يعتمد النظام على GPS وTCP/IP.", 0, "ىلع ماظنلا دمتعي GPS وTCP/IP."),
  ("يعتمد النظام على GPS وTCP/IP.", 1, ".TCP/IPو GPS ىلع ماظنلا دمتعي"),
  ("v2.1", -1, "v2.1"),
  ("v2.1", 0, "v2.1"),
  ("v2.1", 1, "v2.1"),
  ("الإصدار v2.1 جاهز", -1, "زهاج v2.1 رادصإلا"),
  ("الإصدار v2.1 جاهز", 0, "رادصإلا v2.1 زهاج"),
  ("الإصدار v2.1 جاهز", 1, "زهاج v2.1 رادصإلا"),
  ("(مثال)", -1, ")لاثم("),
  ("(مثال)", 0, "(لاثم)"),
  ("(مثال)", 1, ")لاثم("),
  ("[a (ب) c]", -1, "[a (ب) c]"),
  ("[a (ب) c]", 0, "[a (ب) c]"),
  ("[a (ب) c]", 1, "]c )ب( a["),
  ("النص (مثال) هنا", -1, "انه )لاثم( صنلا"),
  ("النص (مثال) هنا", 0, "انه )لاثم( صنلا"),
  ("النص (مثال) هنا", 1, "انه )لاثم( صنلا"),
  ("2026/11/06", -1, "2026/11/06"),
  ("2026/11/06", 0, "2026/11/06"),
  ("2026/11/06", 1, "2026/11/06"),
  ("التاريخ 2026/11/06 م", -1, "م 2026/11/06 خيراتلا"),
  ("التاريخ 2026/11/06 م", 0, "م 2026/11/06 خيراتلا"),
  ("التاريخ 2026/11/06 م", 1, "م 2026/11/06 خيراتلا"),
  ("زوروا https://www.foxoman.net/ar?q=1 اليوم", -1, "مويلا https://www.foxoman.net/ar?q=1 اوروز"),
  ("زوروا https://www.foxoman.net/ar?q=1 اليوم", 0, "اوروز https://www.foxoman.net/ar?q=1 مويلا"),
  ("زوروا https://www.foxoman.net/ar?q=1 اليوم", 1, "مويلا https://www.foxoman.net/ar?q=1 اوروز"),
  ("می\u200Cخواهم", -1, "مهاوخیم"),
  ("می\u200Cخواهم", 0, "مهاوخیم"),
  ("می\u200Cخواهم", 1, "مهاوخیم"),
  ("من می\u200Cخواهم بروم", -1, "مورب مهاوخیم نم"),
  ("من می\u200Cخواهم بروم", 0, "مورب مهاوخیم نم"),
  ("من می\u200Cخواهم بروم", 1, "مورب مهاوخیم نم"),
  ("I said می\u200Cخواهم today", -1, "I said مهاوخیم today"),
  ("I said می\u200Cخواهم today", 0, "I said مهاوخیم today"),
  ("I said می\u200Cخواهم today", 1, "today مهاوخیم I said"),
  ("abc \u202Bمرحبا 123\u202C def", -1, "abc 123 ابحرم def"),
  ("abc \u202Bمرحبا 123\u202C def", 0, "abc 123 ابحرم def"),
  ("abc \u202Bمرحبا 123\u202C def", 1, "def 123 ابحرم abc"),
  ("مرحبا \u202Aabc 123\u202C عالم", -1, "ملاع abc 123 ابحرم"),
  ("مرحبا \u202Aabc 123\u202C عالم", 0, "ابحرم abc 123 ملاع"),
  ("مرحبا \u202Aabc 123\u202C عالم", 1, "ملاع abc 123 ابحرم"),
  ("\u202Eabc def\u202C", -1, "fed cba"),
  ("\u202Eabc def\u202C", 0, "fed cba"),
  ("\u202Eabc def\u202C", 1, "fed cba"),
  ("مرحبا \u202Dabc 12\u202C", -1, "abc 12 ابحرم"),
  ("مرحبا \u202Dabc 12\u202C", 0, "ابحرم abc 12"),
  ("مرحبا \u202Dabc 12\u202C", 1, "abc 12 ابحرم"),
  ("Name: \u2067محمد\u2069 (5)", -1, "Name: \u2067دمحم\u2069 (5)"),
  ("Name: \u2067محمد\u2069 (5)", 0, "Name: \u2067دمحم\u2069 (5)"),
  ("Name: \u2067محمد\u2069 (5)", 1, "Name: \u2067دمحم\u2069 (5)"),
  ("الاسم: \u2066John Smith\u2069 (5)", -1, ")5( \u2069John Smith\u2066 :مسالا"),
  ("الاسم: \u2066John Smith\u2069 (5)", 0, ")5( \u2069John Smith\u2066 :مسالا"),
  ("الاسم: \u2066John Smith\u2069 (5)", 1, ")5( \u2069John Smith\u2066 :مسالا"),
  ("User \u2068علي\u2069 wrote 3", -1, "User \u2068يلع\u2069 wrote 3"),
  ("User \u2068علي\u2069 wrote 3", 0, "User \u2068يلع\u2069 wrote 3"),
  ("User \u2068علي\u2069 wrote 3", 1, "User \u2068يلع\u2069 wrote 3"),
  ("مرحبا\u200E (1)", -1, "\u200E (1)ابحرم"),
  ("مرحبا\u200E (1)", 0, "ابحرم\u200E (1)"),
  ("مرحبا\u200E (1)", 1, "\u200E (1)ابحرم"),
  ("Hello\u200F (1)", -1, "Hello)1( \u200F"),
  ("Hello\u200F (1)", 0, "Hello)1( \u200F"),
  ("Hello\u200F (1)", 1, ")1( \u200FHello"),
  ("\u061C-5 مرحبا", -1, "ابحرم 5-\u061C"),
  ("\u061C-5 مرحبا", 0, "ابحرم 5-\u061C"),
  ("\u061C-5 مرحبا", 1, "ابحرم 5-\u061C"),
  ("السعر $100 أو 50% أو 3.5€ أو ١٠٠٪", -1, "٪١٠٠ وأ €3.5 وأ %50 وأ 100$ رعسلا"),
  ("السعر $100 أو 50% أو 3.5€ أو ١٠٠٪", 0, "١٠٠ وأ €3.5 وأ %50 وأ 100$ رعسلا٪"),
  ("السعر $100 أو 50% أو 3.5€ أو ١٠٠٪", 1, "٪١٠٠ وأ €3.5 وأ %50 وأ 100$ رعسلا"),
  ("خصم -20% على 1,250.50 ر.ع.", -1, ".ع.ر 1,250.50 ىلع %20- مصخ"),
  ("خصم -20% على 1,250.50 ر.ع.", 0, "ع.ر 1,250.50 ىلع %20- مصخ."),
  ("خصم -20% على 1,250.50 ر.ع.", 1, ".ع.ر 1,250.50 ىلع %20- مصخ"),
  ("Total: 1,250.50 ر.ع (15%)", -1, "Total: 1,250.50 )%15( ع.ر"),
  ("Total: 1,250.50 ر.ع (15%)", 0, "Total: 1,250.50 )%15( ع.ر"),
  ("Total: 1,250.50 ر.ع (15%)", 1, ")%15( ع.ر Total: 1,250.50")]

block corpusAgainstTheReference:
  for (text, dir, want) in corpus:
    doAssert display(text, dir) == want,
      "\n" & text & " (" & $dir & ")\n  shown: " & display(text, dir) & "\n  wants: " & want

const conformance = [
  # lines of Unicode's BidiCharacterTest.txt (18.0): characters; direction
  # (0 left to right, 1 right to left, 2 from the text); the paragraph's
  # level; each character's level (x: left out); the order shown
  "0661 2069 0028 0662 0029;2;0;2 1 1 2 1;4 3 2 1 0",
  "05D0 2066 202D 2069 05D1;0;0;1 1 x 1 1;4 3 1 0",
  "0661 0028 0627 2069 0029;0;0;2 1 1 1 1;4 3 2 1 0",
  "202A 202E 0061 202C 0028 005B 05D0 202C 202D 005D 0029 202C;2;0;x x 3 x 3 3 3 x x 2 2 x;6 5 4 2 9 10",
  "202D 0028 202C 202A 05D0 0029 05D1 202C;2;1;x 2 x x 3 3 3 x;1 6 5 4",
  "05D0 0028 05D1 202A 202C 0029 0020 0031 0020 0032;0;0;1 1 1 x x 1 1 2 1 2;9 8 7 6 5 2 1 0",
  "05D0 0028 0028 0061 0029 05D1 0029 0062;1;1;1 1 1 2 1 1 1 2;7 6 5 4 3 2 1 0",
  "0028 05D0 2680 0028 2681 005B 05D1 005D 0029;1;1;1 1 1 1 1 1 1 1 1;8 7 6 5 4 3 2 1 0",
  "0041 200F 005B 05D0 005D 200D 20D6;0;0;0 1 1 1 1 x 1;0 6 4 3 2 1",
  "05D0 2066 2060 2069 05D1;0;0;1 1 x 1 1;4 3 1 0",
  "0041 200F 005B 200D 20D6 05D0 005D;1;1;2 1 1 x 1 1 1;6 5 4 2 1 0",
  "0661 002D 0031;0;0;2 0 0;0 1 2",
  "06F1 0028 0627 0029;1;1;2 1 1 1;3 2 1 0",
  "05D0 0020 2329 05D1 002E 0031 3009;0;0;1 1 1 1 1 2 1;6 5 4 3 2 1 0",
  "0061 0020 3008 0062 002E 0031 3009;1;1;2 2 2 2 2 2 2;0 1 2 3 4 5 6",
  "0061 202B 0062 202C 0020 0031 0020 0032;0;0;0 x 2 x 1 2 1 2;0 7 6 5 4 2"]

block unicodeConformance:
  for line in conformance:
    let f = line.split(';')
    var s = ""
    let cps = f[0].splitWhitespace.mapIt(parseHexInt(it))
    for c in cps: s.add Rune(c).toUTF8
    let dir = parseInt(f[1])
    let bi = bidiInfo(s, if dir == 2: -1 else: dir)
    doAssert ord(bi.rtlPara) == parseInt(f[2]), line
    let want = f[3].splitWhitespace
    var lv = bi.levels
    if lv.len == 0: lv = newSeq[int8](cps.len)
    for i, w in want:
      if w != "x": doAssert $lv[i] == w, line & ": level " & $i & " is " & $lv[i]
    var order = visualOrderOf(lv)
    order.keepItIf(want[it] != "x")
    doAssert order == f[4].splitWhitespace.mapIt(parseInt(it)), line & ": " & $order

block directionOfText:
  # the first strong letter, what is inside isolates left out (P2, P3)
  doAssert textIsRtl("⁦abc⁩ مرحبا")
  doAssert not textIsRtl("⁧مرحبا⁩ abc")
  doAssert strongDir("⁨abc⁩ ١٢") == 2
  doAssert textIsRtl("‏(1)") and not textIsRtl("‎(١)")
  # a zero width non-joiner does not break a Persian word in two: it reads
  # as one right-to-left run in a left-to-right line
  doAssert display("I said می‌خواهم", 0) == "I said مهاوخیم"

block joiners:
  # ZWNJ keeps the letters on its sides apart, ZWJ joins them; marks,
  # direction marks and the word joiner let the join through
  proc forms(s: string): seq[int] =
    for c in bidiInfo(s, 1).cps:
      if c >= 0: result.add c
  doAssert forms("بب") == @[0xFE91, 0xFE90]
  doAssert forms("ب‌ب") == @[0xFE8F, 0xFE8F]
  doAssert forms("ب‍ب") == @[0xFE91, 0xFE90]
  doAssert forms("ب‍") == @[0xFE91] and forms("‍ب") == @[0xFE90]
  doAssert forms("ب‎ب") == @[0xFE91, 0xFE90]
  doAssert forms("ب⁠ب") == @[0xFE91, 0xFE90]
  doAssert forms("بَب") == @[0xFE91, 0x064E, 0xFE90]
  doAssert forms("می‌خواهم")[0 .. 1] == @[0xFEE3, 0xFBFD], "ی before ZWNJ: its final form"
  # where a piece of a word cut and drawn alone needs a joiner
  doAssert joinsAt("بب", 2) and not joinsAt("رب", 2) and not joinsAt("ب ب", 2)
  doAssert joinsAt("بَب", 4), "past the mark"

block plainLettersBack:
  doAssert plainLetters("ﻣﺮﺣﺒﺎ") == "مرحبا"
  doAssert plainLetters("ﻻ ﻼ") == "لا لا"
  doAssert plainLetters("abc مرحبا") == "abc مرحبا"

block mirroring:
  doAssert mirrored(ord('(')) == ord(')') and mirrored(0x2264) == 0x2265 and
           mirrored(0xAB) == 0xBB and mirrored(0x3008) == 0x3009 and mirrored(ord('a')) == ord('a')
  # a line drawn: brackets in a right-to-left run are their mirror images
  let v = visualCodepoints("(مثال)")
  doAssert v[0].cp == ord('(') and v[^1].cp == ord(')'), $v

block canvasDirection:
  # the canvas's `direction`: "rtl" makes `start` the text's right end
  proc inkSide(dir: string): tuple[left, right: int] =
    let c = newCanvas2D(200, 40)
    c.font = "20px sans-serif"
    c.fillStyle = "#000"
    c.direction = dir
    c.fillText("مرحبا", 100, 30)
    let b = c.toBitmap()
    result = (high(int), -1)
    for y in 0 ..< b.h:
      for x in 0 ..< b.w:
        if (b.px[y * b.w + x] shr 24) > 128:
          result.left = min(result.left, x)
          result.right = max(result.right, x)
  let rtl = inkSide("rtl")
  let inherit = inkSide("inherit")
  doAssert rtl.right <= 101 and rtl.left < 90, "right to left: it ends at x: " & $rtl
  doAssert inherit.left >= 99 and inherit.right > 110, "start at the left by default: " & $inherit

# ---- PDF ----------------------------------------------------------------------------------------

proc streams(pdfData: string): seq[string] =
  ## (the file's streams, unpacked)
  var at = 0
  while true:
    let s = pdfData.find("stream\n", at)
    if s < 0: break
    let e = pdfData.find("\nendstream", s)
    if e < 0: break
    var body = pdfData[s + 7 ..< e]
    if "/FlateDecode" in pdfData[max(0, pdfData.rfind("<<", last = s)) ..< s]:
      let b = zlibDecompress(body.toOpenArrayByte(0, body.high))
      body = newString(b.len)
      for i in 0 ..< b.len: body[i] = char(b[i])
    result.add body
    at = e + 10

proc toUnicodeTargets(pdfData: string): seq[int] =
  ## (every character the file's ToUnicode maps glyphs to)
  for body in streams(pdfData):
    if "beginbfchar" notin body: continue
    for ln in body.splitLines:
      let p = ln.split("> <")
      if p.len == 2:
        let h = p[1].strip(chars = {'>', ' '})
        var k = 0
        while k + 4 <= h.len:
          result.add parseHexInt(h[k ..< k + 4])
          k += 4

block pdfArabicText:
  # Arabic lines go into the file with their text as written (/ActualText,
  # in reading order), each glyph mapped to its letters: the kit's reader
  # takes the text out as it reads
  let d = newPdf("تقرير")
  let p = d.addPage()
  let lines = ["ارتفع الأداء بنسبة 25% في Q4 2026.", "يعتمد النظام على GPS وTCP/IP.",
               "من می‌خواهم بروم", "Plain English, 2026/11/06"]
  for i, l in lines: p.text(40, 40 + 30 * float(i), l, size = 14)
  let data = d.render()
  doAssert streams(data).anyIt("/ActualText" in it)
  doAssert "/Lang (ar)" in data and "/Direction /R2L" in data, "the first text is Arabic"
  let back = openPdf(data).pageText(0).strip.splitLines
  doAssert back.len == lines.len, $back
  for i, l in lines: doAssert back[i] == l, "\n  read: " & back[i] & "\n  wrote: " & l
  for c in toUnicodeTargets(data):
    doAssert c notin 0xFB50 .. 0xFDFF and c notin 0xFE70 .. 0xFEFF, "a presentation form in ToUnicode: " & toHex(c, 4)
  # a Latin document: no language unless one is given
  let e = newPdf()
  e.addPage().text(40, 40, "Hello", size = 12)
  doAssert "/Lang" notin e.render() and not streams(e.render()).anyIt("/ActualText" in it)
  e.lang = "en-GB"
  doAssert "/Lang (en-GB)" in e.render() and "/Direction" notin e.render()

block pdfActualText:
  # a file that gives a line's text as it reads (/ActualText): read as given
  var content = "/Span << /ActualText <FEFF06450631062D0628062700200031> >> BDC\n" &
                "BT /F1 12 Tf 20 50 Td (xyzw v) Tj ET EMC\n"
  var objs = @["<< /Type /Catalog /Pages 2 0 R >>",
               "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
               "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 300 100] " &
                 "/Resources << /Font << /F1 4 0 R >> >> /Contents 5 0 R >>",
               "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>",
               "<< /Length " & $content.len & " >>\nstream\n" & content & "endstream"]
  var file = "%PDF-1.4\n"
  var offs: seq[int]
  for i, o in objs:
    offs.add file.len
    file.add $(i + 1) & " 0 obj\n" & o & "\nendobj\n"
  let xref = file.len
  file.add "xref\n0 " & $(objs.len + 1) & "\n0000000000 65535 f \n"
  for o in offs: file.add align($o, 10, '0') & " 00000 n \n"
  file.add "trailer\n<< /Size " & $(objs.len + 1) & " /Root 1 0 R >>\nstartxref\n" & $xref & "\n%%EOF\n"
  doAssert openPdf(file).pageText(0).strip == "مرحبا 1", openPdf(file).pageText(0)

# ---- workbooks -------------------------------------------------------------------------------------

block xlsxRightToLeft:
  # a sheet whose first letters are Arabic opens right to left; one can say
  let path = getTempDir() / "retro-test-rtl.xlsx"
  writeXlsx(path, [XlsxSheet(name: "الرواتب", rows: @[@["الاسم", "الراتب"], @["مريم", "610"]]),
                   XlsxSheet(name: "Staff", rows: @[@["Name", "الاسم"], @["Maryam", "مريم"]]),
                   XlsxSheet(name: "Forced", rows: @[@["Name"]], direction: sdRtl),
                   XlsxSheet(name: "Kept", rows: @[@["الاسم"]], direction: sdLtr)])
  let back = readXlsx(path)
  doAssert back.mapIt(it.direction) == @[sdRtl, sdLtr, sdRtl, sdLtr], $back.mapIt(it.direction)
  doAssert back[0].rows[1] == @["مريم", "610"]
  removeFile(path)
  doAssert readsRtl(XlsxSheet(rows: @[@["١٢٣", "مرحبا"]])), "digits are not letters"
  doAssert not readsRtl(XlsxSheet(rows: @[@["123", "Total"]])) and not readsRtl(XlsxSheet())

# ---- text boxes ----------------------------------------------------------------------------------

fakeDriver()
startApp("bidi", W, H)
var caretAt = -1
textCaretRelay = proc (x, y, w, h: int) {.nimcall.} = caretAt = x

proc caret(): int = state(ui.focus).caret
proc selColor(): uint32 =
  let c = ui.theme.select
  (uint32(c.r) shl 16) or (uint32(c.g) shl 8) or uint32(c.b)

block editBoxArabicKeys:
  # in an Arabic line Left goes on through the text; a letter and its
  # vowel are one step; Backspace takes a vowel off its letter, Delete a
  # letter with its vowel
  var t = "بَبُ"
  var r: Rect
  view = proc () =
    edit(t, w = 300)
    r = ui.lastRect
  run(2)
  click(r, dx = r.w - 3)
  doAssert caret() == 0
  key(KeyLeft)
  run()
  doAssert caret() == "بَ".len, "one step over the letter and its mark: " & $caret()
  key(KeyLeft)
  run()
  doAssert caret() == t.len
  key(KeyRight)
  run()
  doAssert caret() == "بَ".len
  key(KeyBackspace)
  run()
  doAssert t == "ببُ" and caret() == "ب".len, t
  key(KeyDelete)
  run()
  doAssert t == "ب", t
  key(KeyEnd)
  run()
  key(KeyHome)
  run()
  doAssert caret() == 0

block editBoxClipboard:
  # what is copied is the text as written; joined shapes pasted come in as
  # their letters
  var t = "مرحبا GPS"
  var r: Rect
  view = proc () =
    edit(t, w = 300)
    r = ui.lastRect
  run(2)
  click(r, dx = 8)
  key(KeyA, {CtrlPressed})
  key(KeyC, {CtrlPressed})
  run()
  doAssert getClipboardText() == "مرحبا GPS", getClipboardText()
  putClipboardText("ﻣﺮﺣﺒﺎ ﻻ")
  key(KeyA, {CtrlPressed})
  key(KeyV, {CtrlPressed})
  run()
  doAssert t == "مرحبا لا", t

block editBoxMixedLine:
  # Latin with an Arabic word in it: the caret goes into the word from its
  # right, as it reads; a selection across the two is drawn in pieces
  var t = "abc مرحبا def"
  var r: Rect
  view = proc () =
    edit(t, w = 300)
    r = ui.lastRect
  run(2)
  click(r, dx = 3)
  key(KeyHome)
  run()
  for _ in 1 .. 5: key(KeyRight)          # "abc " and the word's first letter
  run()
  doAssert caret() == "abc م".len
  let afterFirst = caretAt
  for _ in 1 .. 4: key(KeyRight)
  run()
  doAssert caret() == "abc مرحبا".len
  let afterWord = caretAt
  doAssert afterFirst > afterWord + textWidth("رحب") div 2,
    "after the word's first letter is at its right end: " & $(afterFirst, afterWord)
  doAssert abs(afterWord - (r.x + 3 + textWidth("abc "))) <= 3, "after the word: its left end"
  # "c مر" selected: "c " at the left, "مر" at the word's right end
  key(KeyHome)
  run()
  key(KeyRight)
  key(KeyRight)
  for _ in 1 .. 4: key(KeyRight, {ShiftPressed})
  run()
  let st = state(ui.focus)
  doAssert min(st.caret, st.anchor) == 2 and max(st.caret, st.anchor) == "abc مر".len
  var cols: seq[int]
  for x in r.x + 2 ..< r.x + r.w - 2:
    for y in r.y + 2 ..< r.y + r.h - 2:
      if px(x, y) == selColor():
        cols.add x
        break
  var pieces = 0
  for i, x in cols:
    if i == 0 or x - cols[i - 1] > 2: inc pieces
  doAssert pieces == 2, "the selection in two places: " & $pieces & " " & $cols

block editBoxTypingLatinInArabic:
  # Latin typed into an Arabic line: the caret follows the last letter
  # typed -- at the Latin word's right end, by the Arabic before it (the
  # Arabic after it is what moves on)
  var t = "النظام  هنا"
  var r: Rect
  view = proc () =
    edit(t, w = 300)
    r = ui.lastRect
  run(2)
  click(r, dx = r.w - 3)
  for _ in 1 .. 7: key(KeyLeft)           # (forward: past "النظام ")
  run()
  doAssert caret() == "النظام ".len, $caret()
  typeText("G")
  run()
  let x1 = caretAt
  typeText("PS")
  run()
  doAssert t == "النظام GPS هنا", t
  let edge = r.x + r.w - 5 - textWidth("النظام ")     # (the text's right end: r.x + r.w - 5)
  doAssert abs(x1 - edge) <= 3 and abs(caretAt - edge) <= 3,
    "after G and after GPS: by the Arabic before them: " & $(x1, caretAt, edge)

# ---- the rich editor ----------------------------------------------------------------------------------

block richEditArabic:
  var doc = richDoc("بَبُ")
  view = proc () =
    discard richEdit(doc, height = 120)
  run(2)
  richSelect(doc, RichPos(para: 0, off: 0), RichPos(para: 0, off: 0))
  ui.focus = ui.lastId
  run()
  key(KeyLeft)                            # (an Arabic paragraph: on through it)
  run()
  doAssert richCaret(doc).off == "بَ".len, $richCaret(doc)
  key(KeyBackspace)
  run()
  doAssert paraText(doc.paras[0]) == "ببُ", paraText(doc.paras[0])
  key(KeyDelete)
  run()
  doAssert paraText(doc.paras[0]) == "ب"
  # copied: the letters as written; pasted shapes: letters
  doc = richDoc("مرحبا GPS")
  run()
  richSelectAll(doc)
  key(KeyC, {CtrlPressed})
  run()
  doAssert getClipboardText() == "مرحبا GPS", getClipboardText()
  putClipboardText("ﻣﺮﺣﺒﺎ")
  key(KeyV, {CtrlPressed})
  run()
  doAssert paraText(doc.paras[0]) == "مرحبا", paraText(doc.paras[0])

block richEditLatinInArabic:
  var doc = richDoc("النظام  هنا")
  view = proc () =
    discard richEdit(doc, height = 120)
  run(2)
  richSelect(doc, RichPos(para: 0, off: 0), RichPos(para: 0, off: 0))
  run()
  let start = richCaretRect(doc).x                   # (an Arabic paragraph: its right end)
  let at = RichPos(para: 0, off: "النظام ".len)
  richSelect(doc, at, at)
  ui.focus = ui.lastId
  run()
  typeText("G")
  run()
  let x1 = richCaretRect(doc).x
  typeText("PS")
  run()
  doAssert paraText(doc.paras[0]) == "النظام GPS هنا"
  let edge = start - textWidth("النظام ")
  doAssert abs(x1 - edge) <= 3 and abs(richCaretRect(doc).x - edge) <= 3,
    "after G and after GPS: by the Arabic before them: " & $(x1, richCaretRect(doc).x, edge)

block richEditStyleInAWord:
  # a word with a color in the middle keeps its letters joined
  var doc = richFromHtml("<p>مر<span style=\"color:#ff0000\">حب</span>ا</p>")
  view = proc () =
    discard richEdit(doc, height = 120)
  run(2)
  doAssert doc.paras[0].runs.len == 3
  richSelect(doc, RichPos(para: 0, off: 0), RichPos(para: 0, off: 0))
  run()
  let a = richCaretRect(doc).x
  let n = paraText(doc.paras[0]).len
  richSelect(doc, RichPos(para: 0, off: n), RichPos(para: 0, off: n))
  run()
  let b = richCaretRect(doc).x
  doAssert abs((a - b) - textWidth("مرحبا")) <= 2, "as wide as the word joined: " & $(a - b, textWidth("مرحبا"))

# ---- the right-to-left interface ----------------------------------------------------------------------

proc onScreen(r: Rect): Rect =
  ## (where layout rectangle `r` is on the screen: mirrored in a
  ## right-to-left interface)
  if ui.rtl: rect(W - r.x - r.w, r.y, r.w, r.h) else: r

block rtlInterfaceTextBoxes:
  # a text box keeps its text as it reads: Latin from its left, Arabic
  # from its right, the caret with the letters
  setUiLanguage("ar", @toolkitArabic)
  var t = "hello"
  var r: Rect
  view = proc () =
    edit(t, w = 300)
    r = ui.lastRect
  run(2)
  let sr = onScreen(r)
  click(sr, dx = 8)                       # (the mouse is where the screen shows it)
  key(KeyHome)
  run()
  let home = caretAt
  key(KeyEnd)
  run()
  doAssert home < caretAt and home - sr.x < 8, "Latin starts at the box's left: " & $(home, caretAt, sr)
  t = "مرحبا"
  run(2)
  key(KeyHome)
  run()
  doAssert sr.x + sr.w - caretAt < 8, "Arabic starts at its right: " & $(caretAt, sr)
  t = ""
  run(2)
  doAssert sr.x + sr.w - caretAt < 8, "an empty box's caret at the right"
  setUiLanguage("")
  run(2)

block rtlInterfaceCharts:
  # a chart is not mirrored: its tallest bar (March) at the same place
  proc tallestBar(): int =
    var r: Rect
    view = proc () =
      discard chart("", chBar, ["Jan", "Feb", "Mar"], [series("s", [1.0, 5, 9])], height = 200, w = 300)
      r = ui.lastRect
    run(2)
    let sr = onScreen(r)
    var top = high(int)
    for x in sr.x ..< sr.x + sr.w:
      for y in sr.y + 20 ..< sr.y + sr.h - 30:
        let p = px(x, y)
        let (cr, cg, cb) = (int(p shr 16 and 0xFF), int(p shr 8 and 0xFF), int(p and 0xFF))
        if max(cr, max(cg, cb)) - min(cr, min(cg, cb)) > 60:
          if y < top:
            top = y
            result = x - sr.x
          break
  let ltr = tallestBar()
  setUiLanguage("ar", @toolkitArabic)
  let rtl = tallestBar()
  setUiLanguage("")
  doAssert ltr == rtl and ltr > 150, "the same chart: " & $(ltr, rtl)

block rtlInterfaceCheckerboard:
  # a checkerboard (and a GPU's picture: its rectangle kept the same way) drawn in
  # `beginKeepSides` stays where it is in its area; outside it, mirrored with the frame
  # (Atelier's canvas was drawn off to one side in an Arabic interface)
  proc span(keep: bool): (int, int) =
    var r: Rect
    view = proc () =
      r = place(300, 60)
      if keep: beginKeepSides(r)
      checkerAt(rect(r.x + 200, r.y, 100, 60), 8, r.x + 200, r.y, color(255, 0, 0), color(0, 0, 255))
      if keep: endKeepSides()
    run(2)
    let sr = onScreen(r)
    result = (int.high, -1)
    for x in sr.x ..< sr.x + sr.w:
      let p = px(x, sr.y + 4)
      if p == 0xFF0000'u32 or p == 0x0000FF'u32:
        result[0] = min(result[0], x - sr.x)
        result[1] = max(result[1], x - sr.x)
  doAssert span(true) == (200, 299) and span(false) == (200, 299)
  setUiLanguage("ar", @toolkitArabic)
  doAssert span(true) == (200, 299), "kept: " & $span(true)
  doAssert span(false) == (0, 99), "mirrored: " & $span(false)
  setUiLanguage("")
  run(2)

echo "bidi tests passed"
