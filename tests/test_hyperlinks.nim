## Tests of hyperlinks, cross-references, text variables and bookmarks (retroui/photo,
## retroui/photobook, retroui/photopdf, retroui/pdf): links kept with the text, a book's
## cross-references showing the page their destination is on, running headers, the PDF's links
## (web addresses, pages, destinations) and its outline.

import std/[os, strutils, json, times]
import retroui/[photo, photobook, photopdf, pdf, textengine, hijri]

let dir = getTempDir() / "retro-hyperlinks-test"
removeDir(dir)
createDir(dir)

proc st(size = 20'f32): CharStyle =
  result = defaultStyle()
  result.size = size

block linksInText:
  # a hyperlink is a run of the text's own, kept when saved
  var t = newText("Visit our site today", st(), 10, 30)
  t.restyle(6, 14, proc (s: var CharStyle) = s.link = "https://www.foxoman.net")
  let runs = t.linkRuns
  doAssert runs.len == 1 and runs[0].a == 6 and runs[0].b == 14 and runs[0].link == "https://www.foxoman.net"
  let back = textFrom(parseJson($t.toJson))
  doAssert back.linkRuns == runs
  # (typed into: the letters typed in the middle of it are of it)
  t.insertText(8, "x", t.styleAt(7))
  doAssert t.linkRuns[0].b == 15

block textVariables:
  let d = newDoc(400, 300, 0xFFFFFFFF'u32, name = "Annual Report.rpd")
  var t = newText("<file> -- <date> -- <unknown> <b", st(), 10, 30)
  let L = d.addTextLayer(t)
  let shown = d.effectiveText(L).plainText
  doAssert shown.startsWith("Annual Report -- "), shown
  doAssert now().format("yyyy") in shown and "<unknown> <b" in shown
  # (while it is typed in: as written)
  d.rawText = uidOf(L)
  doAssert d.effectiveText(L).plainText.startsWith("<file>")
  d.rawText = 0
  # a running header: the first paragraph on the page in the style
  var h = newText("Chapter One\nSome text\nChapter Two", st(), 10, 100)
  h.boxW = 300
  h.boxH = 150
  var cp = h.para
  cp.styleName = "Chapter"
  h.setParaFmt(0, 0, cp)
  h.setParaFmt(22, 22, cp)
  discard d.addTextLayer(h)
  let R = d.addTextLayer(newText("<head:Chapter>", st(), 10, 10))
  doAssert d.effectiveText(R).plainText == "Chapter One"
  # a cross-reference in the same document: its page
  var dst = newText("Results", st(), 10, 200)
  dst.restyle(0, 7, proc (s: var CharStyle) = s.link = "=results")
  discard d.addTextLayer(dst)
  let X = d.addTextLayer(newText("see page <ref:results>, not <ref:nowhere>", st(), 10, 250))
  doAssert d.effectiveText(X).plainText == "see page 1, not ??", d.effectiveText(X).plainText
  # dates: the Hijri calendar's (Umm al-Qura), in Arabic, as numbers, in a format of its own
  let today = now()
  let hd = toHijri(today.year, ord(today.month), today.monthday)
  let V = d.addTextLayer(newText("<hijri:num>|<hijri:en>|<date:dd/MM/yyyy>|<date:ar-latn>|<hijri>", st(), 10, 280))
  let parts = d.effectiveText(V).plainText.split('|')
  doAssert parts[0] == $hd.year & "/" & align($hd.month, 2, '0') & "/" & align($hd.day, 2, '0'), parts[0]
  doAssert parts[1].endsWith(" AH") and hijriMonthName(hd.month, false) in parts[1], parts[1]
  doAssert parts[2] == today.format("dd/MM/yyyy")
  doAssert parts[3] == $today.monthday & " " & arabicMonthName(ord(today.month)) & " " & $today.year
  doAssert parts[4].endsWith(" \u0647\u0640") and arabicDigits($hd.year) in parts[4], parts[4]
  doAssert toHijri(2026, 11, 17) == (1448, 6, 7) and fromHijri(hd.year, hd.month, hd.day) == (today.year, ord(today.month), today.monthday)
  doAssert hijriDate(dateTime(2026, mNov, 17)) == "\u0667 \u062C\u0645\u0627\u062F\u0649 \u0627\u0644\u0622\u062E\u0631\u0629 \u0661\u0664\u0664\u0668 \u0647\u0640"
  doAssert arabicDate(dateTime(2026, mNov, 17), "ar-sy") == "\u0661\u0667 \u062A\u0634\u0631\u064A\u0646 \u0627\u0644\u062B\u0627\u0646\u064A \u0662\u0660\u0662\u0666"

block bookCrossReferences:
  # a destination on page 3, a cross-reference to it on page 1, a running header from page 2 on 3
  var s = bookSetup(148, 210, dpi = 72, facing = false)
  let b = newBook(s, pages = 3, name = "Refs")
  var dt = newText("The results", st(), 50, 100)
  dt.restyle(4, 11, proc (x: var CharStyle) = x.link = "=results")
  discard b.doc(2).addTextLayer(dt)
  var hd = newText("Part Two", st(), 50, 50)
  hd.para.styleName = "Part"
  discard b.doc(1).addTextLayer(hd)
  discard b.doc(2)
  let R = b.doc(0).addTextLayer(newText("as on page <ref:results>", st(), 50, 50))
  let H = b.doc(2).addTextLayer(newText("<head:Part>", st(), 50, 20))
  discard b.doc(0)
  doAssert b.doc(0).effectiveText(R).plainText == "as on page 3", b.doc(0).effectiveText(R).plainText
  discard b.doc(1)
  doAssert b.doc(2).effectiveText(H).plainText == "Part Two", b.doc(2).effectiveText(H).plainText
  # (saved and read back: where the destinations are is known without opening the pages)
  b.saveBook(dir / "refs.rpb")
  let back = loadBook(dir / "refs.rpb")
  let R2 = block:
    var f: Layer
    for M in back.doc(0).layers:
      if M.isText and "<ref:" in M.text.plainText: f = M
    f
  doAssert back.doc(0).effectiveText(R2).plainText == "as on page 3"
  # the PDF: the cross-reference a link to its page
  var lk = R.text
  lk.restyle(11, 24, proc (x: var CharStyle) = x.link = "#results")
  b.doc(0).setText(R, lk)
  var url = newText("Mail us", st(), 50, 150)
  url.restyle(0, 7, proc (x: var CharStyle) = x.link = "mailto:sultan@example.com")
  discard b.doc(1).addTextLayer(url)
  b.doc(0).bookmarks.add DocBookmark(title: "Start")
  b.doc(2).bookmarks.add DocBookmark(title: "Results", dest: "results", level: 1)
  let path = dir / "refs.pdf"
  b.saveBookPdf(path, pdfPreset(ppWeb))
  let pdfText = readFile(path)
  doAssert "/Subtype /Link" in pdfText and "/Dest [" in pdfText, "a link to a page"
  doAssert "/URI (mailto:sultan@example.com)" in pdfText
  doAssert "/Type /Outlines" in pdfText and "/Title (Start)" in pdfText and "/Title (Results)" in pdfText
  doAssert "/PageMode /UseOutlines" in pdfText
  b.close()
  back.close()

block pdfOutline:
  # the PDF writer's own: links to pages, bookmarks under bookmarks
  let pdf = newPdf("Outline")
  let p1 = pdf.addPage()
  discard pdf.addPage()
  p1.linkToPage(10, 10, 100, 20, 2, 100)
  pdf.bookmarks = @[PdfBookmark(title: "One", page: 1), PdfBookmark(title: "One.A", page: 2, level: 1),
                    PdfBookmark(title: "Two", page: 2)]
  let s = pdf.render
  doAssert s.count("/Title (") >= 3 and "/Count 3" in s and "/First " in s and "/Next " in s and "/Prev " in s
  doAssert "/XYZ 0 " in s

removeDir(dir)
echo "test_hyperlinks: ok"
