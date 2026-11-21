## The layout program's help, more of it: a table's stripes in a pattern (so many plain rows, so
## many striped, after some left plain; columns striped) and a cell's diagonal lines, kept in the
## file and in the PDF; column rules down a text box's gutters; Print Booklet's printer's spreads
## (saddle stitch, perfect bound, blanks, creep) and its PDF; Find Font (the fonts used, one
## changed for another); a page's color label kept with the book; Smart Text Reflow (pages added
## for a story's text, the empty ones taken out again).

import std/[os, strutils]
import retroui/[photo, photobook, photopdf, textengine, pdf]

var failures = 0
template check(cond: bool; what: string) =
  if cond: echo "  ok   ", what
  else:
    echo "  FAIL ", what
    inc failures

let dir = getTempDir() / "retro-layoutmore"
removeDir(dir)
createDir(dir)

block stripes:
  var ts = TableStyle(on: true, headerRows: 1, fill: 0xFFFFFFFF'u32, altFill: 0xFFDDDDDD'u32)
  check not ts.rowStriped(0) and not ts.rowStriped(1) and ts.rowStriped(2) and not ts.rowStriped(3),
        "every other row (the header not)"
  ts.altFirst = 2
  ts.altNext = 1
  check not ts.rowStriped(1) and not ts.rowStriped(2) and ts.rowStriped(3) and not ts.rowStriped(4),
        "two plain, one striped"
  ts.altSkip = 3
  check not ts.rowStriped(3) and not ts.rowStriped(4) and not ts.rowStriped(5) and ts.rowStriped(6),
        "the first three left plain, then two plain and one striped"
  ts.colAltFill = 0xFF0000FF'u32
  ts.cells = @[@[TableCell(), TableCell(diagonal: 3, diagColor: 0xFFFF0000'u32, diagWidth: 2)]]
  let back = tableFrom(tableToJson(ts))
  check back.altFirst == 2 and max(1, back.altNext) == 1 and back.altSkip == 3 and back.colAltFill == 0xFF0000FF'u32,
        "the pattern kept in the file"
  check back.cells[0][1].diagonal == 3 and back.cells[0][1].diagColor == 0xFFFF0000'u32 and
        back.cells[0][1].diagWidth == 2, "the diagonals kept"
  # laid out: a striped column's fill, two slanted lines in the cell
  var t = newText("Name\tAge\nAli\t30\nSara\t25\nOmar\t40", defaultStyle(), 10, 10)
  t.boxW = 300
  t.boxH = 200
  t.table = TableStyle(on: true, headerRows: 1, border: 0xFF000000'u32, inner: true, colAltFill: 0xFF0000FF'u32)
  t.table.cells = @[@[], @[TableCell(), TableCell(diagonal: 3)]]
  let lay = layoutText(t)
  var slanted = 0
  for dcr in lay.decorations:
    if dcr.line: inc slanted
  check slanted == 2, "laid out: the cell's two diagonals (" & $slanted & ")"
  var blue = false
  for bk in lay.backs:
    if bk.color == 0xFF0000FF'u32: blue = true
  check blue, "laid out: the second column striped"
  # drawn and in the PDF
  let d = newDoc(320, 220, 0xFFFFFFFF'u32)
  discard d.addTextLayer(t)
  let pdfPath = dir / "table.pdf"
  var pdf = newPressPdf(pdfPreset(ppPrint))
  pdf.addDocPage(d, pdfPreset(ppPrint))
  pdf.save(pdfPath)
  check fileExists(pdfPath) and getFileSize(pdfPath) > 500, "the table in a PDF"

block columnRules:
  var t = newText(repeat("words that fill the columns ", 60), defaultStyle(), 0, 0)
  t.boxW = 400
  t.boxH = 300
  t.columns = 3
  t.gutter = 20
  let plain = layoutText(t)
  t.colRule = ColumnRule(on: true, width: 2, color: 0xFF336699'u32, frameHeight: true)
  let ruled = layoutText(t)
  var rules: seq[Decoration]
  for dcr in ruled.decorations:
    if dcr.color == 0xFF336699'u32: rules.add dcr
  check rules.len == 2 and ruled.decorations.len == plain.decorations.len + 2, "two rules for three columns"
  let colW = (400'f32 - 40) / 3
  check rules.len == 2 and abs((rules[0].x0 + rules[0].x1) / 2 - (colW + 10)) < 0.5 and
        abs(rules[0].thick - 300) < 0.5, "in the middle of the first gutter, the box's height"
  t.colRule.dashed = true
  var dashes = 0
  for dcr in layoutText(t).decorations:
    if dcr.color == 0xFF336699'u32: inc dashes
  check dashes > 10, "dashed: many pieces (" & $dashes & ")"
  let back = textFrom(t.toJson)
  check back.colRule.on and back.colRule.dashed and back.colRule.width == 2 and back.colRule.frameHeight,
        "kept in the file"

block booklet:
  let s = bookletSpreads(8, Booklet(kind: bkSaddle))
  check s.len == 4 and (s[0].left, s[0].right) == (7, 0) and (s[1].left, s[1].right) == (1, 6) and
        (s[2].left, s[2].right) == (5, 2) and (s[3].left, s[3].right) == (3, 4), "8 pages, saddle stitch: 8|1 2|7 6|3 4|5"
  let b6 = bookletSpreads(6, Booklet(kind: bkSaddle))
  check b6.len == 4 and b6[0].left == -1 and b6[1].right == -1, "6 pages: two blanks at the end"
  let pf = bookletSpreads(10, Booklet(kind: bkPerfect, signature: 4))
  check pf.len == 6 and (pf[0].left, pf[0].right) == (3, 0) and (pf[2].left, pf[2].right) == (7, 4) and
        pf[5].left == -1 or pf[5].right == -1, "perfect bound in signatures of 4: each folded on its own"
  let cr = bookletSpreads(16, Booklet(kind: bkSaddle, creep: -24))
  check abs(cr[0].shift) < 1e-9 and abs(cr[6].shift - 12) < 1e-9 and abs(cr[3].shift - 4) < 1e-9,
        "creep -24 pt over 4 sheets: the cover stays, the middle 12 pt each page"
  let cp = bookletSpreads(16, Booklet(kind: bkSaddle, creep: 24))
  check abs(cp[7].shift) < 1e-9 and abs(cp[0].shift + 12) < 1e-9, "creep +24: the middle stays, the cover out"
  var st = bookSetup(100, 140, dpi = 72, facing = true)
  let bk = newBook(st, pages = 6, name = "Booklet")
  let path = dir / "booklet.pdf"
  bk.saveBookletPdf(path, Booklet(kind: bkSaddle, space: 10), pdfPreset(ppPrint))
  let data = readFile(path)
  check data.startsWith("%PDF") and data.count("/Type /Page\n") + data.count("/Type /Page ") +
        data.count("/Type/Page") >= 4, "its PDF: four printer's spreads"
  bk.close()

block findFont:
  let d = newDoc(200, 100, 0xFFFFFFFF'u32)
  var a = defaultStyle()
  a.family = "FreeSerif"
  var t = newText("Serif", a, 10, 30)
  t.spans.add TextSpan(text: " and sans", style: defaultStyle())
  discard d.addTextLayer(t)
  let f0 = d.fontsUsed
  check f0.len == 2 and f0[0].family in ["", "FreeSans"] and f0[1].family == "FreeSerif" and f0[1].chars == 5,
        "the fonts used, the most used first"
  d.beginStep("Find Font")
  d.touchLayers()
  check d.replaceFontAll("FreeSerif", "", "FreeMono", "") == 1, "changed in one layer"
  d.endStep()
  let f1 = d.fontsUsed
  var mono = false
  for x in f1:
    if x.family == "FreeMono": mono = true
    check x.family != "FreeSerif", "no FreeSerif left: " & x.family
  check mono, "set in FreeMono"
  d.undo()
  check d.fontsUsed[1].family == "FreeSerif", "undone"

block pageLabelsAndReflow:
  var st = bookSetup(100, 140, dpi = 72, facing = false)
  let b = newBook(st, pages = 2, name = "Labels")
  b.setPageLabel(1, 3)
  check b.pages[1].label == 3 and b.modified, "page 2 labelled"
  let p = dir / "labels.rpb"
  b.saveBook(p)
  b.close()
  let b2 = loadBook(p)
  check b2.pages[1].label == 3 and b2.pages[0].label == 0, "the label kept with the book"
  # Smart Text Reflow: a story threaded onto page 2 grows: pages added; it shrinks: taken out
  let d0 = b2.doc(0)
  var story = newText(repeat("A line of the story that goes on. ", 40), defaultStyle(), 0, 0)
  let L = d0.addTextLayer(b2.boxed(story, 0))
  discard b2.autoflow(0, L)
  let n0 = b2.pages.len
  var added: seq[int]
  # (the last box gets more: what is set in the first box grows)
  var more = L.text
  more.spans[0].text.add repeat("More words for the story to set. ", 200)
  d0.setText(L, more)
  let r = b2.smartReflow(0, added, deleteEmpty = true)
  check r.added > 0 and b2.pages.len > n0, "pages added for the text (" & $r.added & ")"
  var less = L.text
  less.spans[0].text = "A short story now."
  d0.setText(L, less)
  discard b2.settle(0)
  let r2 = b2.smartReflow(0, added, deleteEmpty = true)
  check r2.removed > 0 and b2.pages.len < n0 + r.added, "the pages it added taken out again (" & $r2.removed & ")"
  b2.close()

removeDir(dir)
if failures > 0:
  echo "test_layoutmore: ", failures, " failed"
  quit(1)
echo "test_layoutmore: all passed"
