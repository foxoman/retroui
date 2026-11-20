## Tests of books (retroui/photobook) and of what the image editor's engine
## has for them: text that keeps out of other layers (Text Wrap), page
## numbers in text, master pages, facing pages bound on either side, text
## that goes on from page to page, the book's file and its PDF. With
## PHOTO_DUMP set to a folder, pages are written there as pictures.

import std/[os, strutils, json]
import retroui/[imaging, photo, photobook, photopdf, photoshapes, photowarp, textengine, zip]

let dump = getEnv("PHOTO_DUMP")
if dump.len > 0: createDir(dump)

proc style(size = 20.0): CharStyle =
  CharStyle(family: "", size: size, color: 0xFF000000'u32, hScale: 1, vScale: 1)

proc words(n: int): string =
  for k in 0 ..< n: result.add "word" & $k & " "

proc ink(d: Doc; L: Layer; x0, y0, x1, y1: int): int =
  for y in max(0, y0) ..< min(d.h, y1):
    for x in max(0, x0) ..< min(d.w, x1):
      if (L.px[y * d.w + x] shr 24) > 0: inc result

proc block0(d: Doc; name: string; x0, y0, x1, y1: int; color = 0xFF2040C0'u32): Layer =
  ## (a layer with a filled rectangle)
  result = d.addLayer(name)
  for y in y0 ..< y1:
    for x in x0 ..< x1: result.px[y * d.w + x] = color
  inc result.ver

block linesKeepOutOfAHole:
  # the type engine: lines beside a hole are shorter, and none is in it
  var t = newText(words(60), style(), 10, 10)
  t.boxW = 400
  t.boxH = 600
  let plain = layoutText(t)
  t.holes = @[(200'f32, 40'f32, 420'f32, 140'f32)]
  let held = layoutText(t)
  doAssert held.lines.len > plain.lines.len, "shorter lines beside the hole: more of them"
  for g in held.glyphs:
    # (no letter starts inside the hole)
    doAssert not (g.x >= 205 and g.x < 410 and g.y > 60 and g.y < 135), "a letter in the hole at " & $g.x & "," & $g.y
  # a hole across the whole box: the lines go on under it
  t.holes = @[(0'f32, 60'f32, 500'f32, 200'f32)]
  let jumped = layoutText(t)
  var between = 0
  for g in jumped.glyphs:
    if g.y > 80 and g.y < 195: inc between
  doAssert between == 0, "nothing set where the hole is"
  doAssert jumped.glyphs.len == plain.glyphs.len, "all of it is set"

block columnsKeepOutOfAHole:
  var t = newText(words(120), style(16), 0, 0)
  t.boxW = 500
  t.boxH = 400
  t.columns = 2
  t.gutter = 20
  t.holes = @[(200'f32, 100'f32, 300'f32, 200'f32)]      # (across the gutter: in both columns)
  let lay = layoutText(t)
  for g in lay.glyphs:
    doAssert not (g.x >= 202 and g.x < 296 and g.y > 118 and g.y < 196), "a letter in the hole"
  doAssert lay.glyphs.len > 100

block textWrapInADocument:
  let d = newDoc(600, 400, 0xFFFFFFFF'u32)
  var t = newText(words(150), style(16), 20, 20)
  t.boxW = 560
  t.boxH = 360
  let T = d.addTextLayer(t)
  let B = d.block0("Picture", 200, 100, 400, 220)
  doAssert d.wrapHoles(T).len == 0, "no wrap asked for"
  doAssert d.ink(T, 200, 100, 400, 220) > 0, "text under the picture"
  # round its box, with room
  d.beginStep("Text Wrap")
  d.touchLayers()
  B.wrap = 1
  B.wrapGap = 6
  d.endStep()                      # (the text is set again: `rewrap`)
  doAssert d.wrapHoles(T) == @[(194'f32, 94'f32, 406'f32, 226'f32)]
  doAssert d.ink(T, 196, 100, 404, 220) == 0, "the text keeps out of the picture"
  doAssert d.ink(T, 20, 100, 190, 220) > 0 and d.ink(T, 410, 100, 580, 220) > 0, "... and is beside it"
  if dump.len > 0: discard d.toBitmap(0xFFFFFFFF'u32).savePng(dump / "wrap-box.png")
  # a line beside it goes on at its other side, on the same baseline
  block:
    let lay = layoutText(d.effectiveText(T))
    var left, right: seq[float32]
    for g in lay.glyphs:
      if g.y > 110 and g.y < 210:
        if g.x < 194: left.add g.y elif g.x > 406: right.add g.y
    doAssert left.len > 0 and right.len > 0
    for y in right: doAssert y in left, "the same baselines on both sides"
  # on one side only; on the side with more room
  B.wrapSide = 1
  d.rewrap()
  doAssert d.ink(T, 20, 100, 190, 220) > 0 and d.ink(T, 196, 100, 600, 220) == 0, "at its left only"
  B.wrapSide = 2
  d.rewrap()
  doAssert d.ink(T, 0, 100, 404, 220) == 0 and d.ink(T, 410, 100, 580, 220) > 0, "at its right only"
  B.wrapSide = 0
  d.rewrap()
  # the picture moved: the text follows
  d.beginStep("Move")
  d.shiftLayers(@[B], -180, 0)
  d.endStep()
  doAssert d.ink(T, 20, 104, 220, 216) == 0 and d.ink(T, 240, 100, 400, 220) > 0, "wrapped where it is now"
  B.wrapSide = 3
  d.rewrap()
  doAssert d.ink(T, 0, 104, 226, 216) == 0 and d.ink(T, 240, 100, 580, 220) > 0, "the side with more room"
  B.wrapSide = 0
  d.rewrap()
  d.undo()
  doAssert d.ink(T, 196, 100, 404, 220) == 0, "undone: where it was"
  d.undo()
  doAssert B.wrap == 0 and d.ink(T, 200, 100, 400, 220) > 0, "the wrap undone: text under the picture again"
  d.redo()
  doAssert B.wrap == 1 and d.ink(T, 196, 100, 404, 220) == 0
  # a text that ignores Text Wrap: a caption on the picture
  let cap = d.addTextLayer(block:
    var c = newText(words(8), style(14), 210, 110)
    c.boxW = 180
    c.boxH = 100
    c)
  doAssert d.ink(cap, 200, 100, 400, 220) == 0, "kept out, as any text"
  cap.ignoreWrap = true
  d.drawText(cap)
  doAssert d.ink(cap, 200, 100, 400, 220) > 0 and d.wrapHoles(cap).len == 0, "on the picture"
  d.layers.delete(d.layers.find(cap))
  d.cur = d.layers.find(T)
  # jump: nothing beside it
  B.wrap = 3
  B.wrapGap = 0
  d.rewrap()
  doAssert d.ink(T, 0, 104, 600, 216) == 0, "the lines go on under it"
  # its shape: a triangle lets the text come close on its narrow end
  let S = d.addLayer("Shape")
  for y in 240 ..< 360:
    for x in 300 ..< 300 + (y - 240): S.px[y * d.w + x] = 0xFF00A000'u32
  inc S.ver
  B.wrap = 0
  S.wrap = 2
  d.rewrap()
  let holes = d.wrapHoles(T)
  doAssert holes.len > 20, "row by row"
  doAssert holes[0].x1 - holes[0].x0 < 12 and holes[^1].x1 - holes[^1].x0 > 100
  # hidden: not in the way; at Opacity 0 it still is (a wrap drawn with the pen)
  S.visible = false
  doAssert d.wrapHoles(T).len == 0
  S.visible = true
  S.opacity = 0
  doAssert d.wrapHoles(T).len > 20
  # as a PDF: the type keeps out there too (its lines are not those of the text without wrap)
  S.opacity = 100
  let pa = getTempDir() / "retro-wrap-a.pdf"
  let pb = getTempDir() / "retro-wrap-b.pdf"
  d.savePdf(pa, pdfPreset(ppWeb))
  S.wrap = 0
  d.rewrap()
  d.savePdf(pb, pdfPreset(ppWeb))
  doAssert getFileSize(pa) != getFileSize(pb), "the PDF's type is set round the shape"
  S.wrap = 2
  d.rewrap()
  removeFile(pa)
  removeFile(pb)
  # saved and read back
  let path = getTempDir() / "retro-wrap.rpd"
  d.saveRpd(path)
  let e = loadRpd(path)
  var found = 0
  for L in e.layers:
    if L.wrap == 2: inc found
  doAssert found == 1
  removeFile(path)

block pageNumbersInText:
  let d = newDoc(300, 100, 0xFFFFFFFF'u32)
  let L = d.addTextLayer(newText("Page <#> of <##>", style(), 10, 40))
  doAssert d.effectiveText(L).plainText == "Page <#> of <##>", "not a page of a book: as written"
  d.pageLabel = "7"
  d.pageTotal = "12"
  doAssert d.effectiveText(L).plainText == "Page 7 of 12"
  d.rawText = uidOf(L)                # (typed in: shown as written)
  doAssert d.effectiveText(L).plainText == "Page <#> of <##>"
  d.rawText = 0
  doAssert L.text.plainText == "Page <#> of <##>", "the text itself keeps its markers"

block numbersWritten:
  doAssert formatNumber(7, nsDigits) == "7"
  doAssert formatNumber(14, nsRomanLower) == "xiv" and formatNumber(1999, nsRomanUpper) == "MCMXCIX"
  doAssert formatNumber(0, nsRomanLower) == "0"
  doAssert formatNumber(1, nsLetterLower) == "a" and formatNumber(26, nsLetterUpper) == "Z" and
           formatNumber(27, nsLetterLower) == "aa" and formatNumber(28, nsLetterLower) == "ab"
  doAssert formatNumber(120, nsArabicIndic) == "١٢٠" and formatNumber(45, nsPersian) == "۴۵"
  doAssert formatNumber(1, nsAbjad) == "أ" and formatNumber(3, nsAbjad) == "ج" and formatNumber(29, nsAbjad) == "أأ"

block sidesAndMargins:
  var s = bookSetup(100, 150, dpi = 72, facing = true)
  s.inside = 40
  s.outside = 20
  let b = newBook(s, pages = 6)
  doAssert b.sideOf(0) == psRight and b.sideOf(1) == psLeft and b.sideOf(2) == psRight
  doAssert b.partner(0) == -1 and b.partner(1) == 2 and b.partner(2) == 1 and b.partner(5) == -1
  doAssert b.spreadOf(1) == @[1, 2] and b.spreadOf(2) == @[1, 2] and b.spreadOf(0) == @[0]
  doAssert b.marginBox(0).x == 40 and b.marginBox(1).x == 20, "the inside margin is at the spine"
  doAssert b.marginBox(0).w == b.setup.w - 60
  # bound on the right: the first page is a left page, and a spread reads from the right
  s.binding = bindRight
  b.setSetup(s)
  doAssert b.sideOf(0) == psLeft and b.sideOf(1) == psRight and b.sideOf(2) == psLeft
  doAssert b.spreadOf(1) == @[2, 1], "page 2 on the right, page 3 on the left"
  doAssert b.marginBox(0).x == 20 and b.marginBox(1).x == 40
  # not facing
  s.facing = false
  b.setSetup(s)
  doAssert b.sideOf(3) == psSingle and b.partner(3) == -1 and b.marginBox(3).x == 40
  # numbers: from a first number, started again at a page
  s.firstNumber = 5
  b.setSetup(s)
  doAssert b.label(0) == "5" and b.label(3) == "8"
  b.pages[2].restart = 1
  doAssert b.label(1) == "6" and b.label(2) == "1" and b.label(5) == "4"
  s.numbers = nsRomanLower
  b.setSetup(s)
  doAssert b.label(5) == "iv"
  b.close()

block snapLinesAndTheBaselineGrid:
  # boxes snap to the margins, the columns' edges and the baseline grid; text on the grid
  # follows it when Document Setup changes it
  var s = bookSetup(100, 150, dpi = 72, facing = true)
  s.columns = 2
  s.gutter = 10
  s.baseline = 14
  let b = newBook(s, pages = 3)
  let m = b.marginBox(1)
  let (xs, ys) = b.snapLines(psLeft)
  doAssert m.x.float in xs and float(m.x + m.w) in xs and xs.len == 4, $xs
  doAssert m.y.float in ys and float(m.y + m.h) in ys
  let g = b.gridLines
  doAssert g.len > 10 and g[0] == m.y.float and abs(g[1] - g[0] - 14) < 1e-9 and g[^1] <= float(m.y + m.h)
  doAssert g[0] in ys and g[^1] in ys
  # a text on the grid
  let d = b.doc(1)
  var t = b.boxed(newText("Lines on the grid of the book, long enough for a few of them.", style(11), 0, 0), 1)
  b.alignToGrid(t)
  doAssert t.gridStep == 14 and t.gridStart == m.y.float32
  let L = d.addTextLayer(t)
  # the grid made wider: the text follows
  s.baseline = 20
  b.setSetup(s)
  let L2 = b.doc(1).layers[^1]
  doAssert L2.isText and L2.text.gridStep == 20
  for ln in layoutText(L2.text).lines:
    let k = (ln.baseline - L2.text.gridStart) / 20
    doAssert abs(k - float32(int(k + 0.5))) < 0.01, "on the wider grid: " & $ln.baseline
  # no grid: none to snap to, the text as its leading puts it
  s.baseline = 0
  b.setSetup(s)
  doAssert b.gridLines.len == 0 and b.doc(1).layers[^1].text.gridStep == 0
  discard L
  b.close()

block exportPagesAndSpreads:
  # File > Export: a range of pages, as pages or as spreads, a PDF or a picture a sheet
  var s = bookSetup(100, 140, dpi = 72, facing = true)
  let b = newBook(s, pages = 5)
  for i in 0 ..< 5:
    discard b.doc(i).addShapeLayer(ShapeData(path: rectPath(0, 200, float(s.w), 260), fill: solidPaint(0xFFC02020'u32)))
  b.park()
  b.saveBook(getTempDir() / "retro-export-test.rpb")
  doAssert not b.changed
  doAssert b.pageList("") == @[0, 1, 2, 3, 4] and b.pageList("all") == @[0, 1, 2, 3, 4]
  doAssert b.pageList("2-3, 5") == @[1, 2, 4] and b.pageList("4-") == @[3, 4] and b.pageList("-2") == @[0, 1]
  doAssert b.pageList("9, x, 3, 3") == @[2] and b.pageList("3-1") == @[0, 1, 2]
  doAssert b.exportSheets(@[0, 1, 2, 3, 4], true) == @[@[0], @[1, 2], @[3, 4]]
  doAssert b.exportSheets(@[0, 2, 3], true) == @[@[0], @[2], @[3]], "a spread's page alone when its partner is not asked for"
  doAssert b.exportSheets(@[1, 2], false) == @[@[1], @[2]]
  let dir = getTempDir() / "retro-export-test"
  createDir(dir)
  var e = BookExport(kind: exPdf, spreads: true, pdf: pdfPreset(ppPress))
  let pdf = b.exportBook(dir / "book.pdf", e)
  doAssert pdf == @[dir / "book.pdf"]
  let data = readFile(pdf[0])
  doAssert data.count("/Type /Page\n") + data.count("/Type /Page ") + data.count("/Type/Page\n") >= 3 or
           data.count("/MediaBox") == 3, "three sheets: " & $data.count("/MediaBox")
  e.spreads = false
  e.pages = "2-3"
  discard b.exportBook(dir / "two.pdf", e)
  doAssert readFile(dir / "two.pdf").count("/MediaBox") == 2
  # pictures: a file a sheet, named by its pages; a spread twice as wide; at the resolution asked
  e = BookExport(kind: exPng, spreads: true, ppi: 144)
  let pics = b.exportBook(dir / "p.png", e)
  doAssert pics == @[dir / "p-1.png", dir / "p-2-3.png", dir / "p-4-5.png"], $pics
  let sp = decodePng(readFile(pics[1]))
  doAssert sp.w == s.w * 4 and sp.h == s.h * 2, $sp.w & "x" & $sp.h
  e = BookExport(kind: exJpeg, pages: "1", quality: 80)
  let one = b.exportBook(dir / "cover.jpg", e)
  doAssert one == @[dir / "cover.jpg"] and readFile(one[0]).startsWith("\xFF\xD8")
  doAssert b.exportBook(dir / "none.pdf", BookExport(kind: exPdf, pages: "40-50", pdf: pdfPreset(ppWeb))).len == 0
  # nothing of it is a change to the book
  doAssert not b.changed
  b.close()
  removeDir(dir)
  removeFile(getTempDir() / "retro-export-test.rpb")

block mastersAndNumbers:
  var s = bookSetup(120, 160, dpi = 72, facing = true)
  let b = newBook(s, pages = 3)
  let m = b.addMaster()
  doAssert m.name == "A"
  for side in [psLeft, psRight]:
    let md = b.masterDoc(m, side)
    var t = newText("<#>", style(18), 0, 0)
    let box = b.marginBox(side)
    t.x = box.x.float32
    t.y = float32(s.h - 40)
    t.boxW = box.w.float32
    t.boxH = 30
    t.para.align = if side == psLeft: textLeft else: textRight
    discard md.addTextLayer(t)
    md.markAll()
  for i in 0 ..< 3: b.setMaster(i, m.id)
  let d0 = b.doc(0)
  var folio: Layer
  for L in d0.layers:
    if L.fromMaster == m.id: folio = L
  doAssert folio != nil and folio.locked, "the master's layer is on the page, locked"
  # what is added to the page goes over the master's layers
  let own = d0.addLayer("Own")
  doAssert d0.layers.find(own) > d0.layers.find(folio), "a new layer is over the master's"
  d0.layers.delete(d0.layers.find(own))
  d0.cur = 0
  doAssert d0.effectiveText(folio).plainText == "1"
  # a right page: its number at the right; a left page: at the left
  let half = s.w div 2
  doAssert d0.ink(folio, half, 0, s.w, s.h) > 0 and d0.ink(folio, 0, 0, half, s.h) == 0
  let d1 = b.doc(1)
  var f1: Layer
  for L in d1.layers:
    if L.fromMaster != 0: f1 = L
  doAssert d1.effectiveText(f1).plainText == "2"
  doAssert d1.ink(f1, 0, 0, half, s.h) > 0 and d1.ink(f1, half, 0, s.w, s.h) == 0
  # a page put in before it: page 2 is page 3 now, and a right page
  b.park()
  discard b.insertPage(1)
  let d2 = b.doc(2)
  var f2: Layer
  var n = 0
  for L in d2.layers:
    if L.fromMaster != 0:
      f2 = L
      inc n
  doAssert n == 1, "the master's layers once"
  doAssert d2.effectiveText(f2).plainText == "3"
  doAssert d2.ink(f2, half, 0, s.w, s.h) > 0 and d2.ink(f2, 0, 0, half, s.h) == 0, "it changed sides"
  # the master changed: the pages follow
  let md = b.masterDoc(m, psRight)
  let rule = md.block0("Rule", 10, 10, 110, 12)
  md.markAll()
  doAssert rule != nil
  let d2b = b.doc(2)
  n = 0
  for L in d2b.layers:
    if L.fromMaster != 0: inc n
  doAssert n == 2, "the rule came to the page"
  # no master: its layers go
  b.setMaster(2, 0)
  n = 0
  for L in b.doc(2).layers:
    if L.fromMaster != 0: inc n
  doAssert n == 0
  doAssert b.changed
  b.close()

block mastersBasedOnMasters:
  # a master based on another (Based on Master): the other's layers on its pages too, under its
  # own -- and on it, as it is edited; never round; kept in the book's file
  var s = bookSetup(120, 160, dpi = 72, facing = false)
  let b = newBook(s, pages = 2)
  let a = b.addMaster()
  let c = b.addMaster()
  doAssert c.name == "B"
  let ra = b.masterDoc(a, psRight).block0("Frame", 5, 5, 115, 10)
  doAssert ra != nil
  b.masterDoc(a, psRight).markAll()
  discard b.masterDoc(c, psRight).block0("Logo", 50, 140, 70, 155)
  b.masterDoc(c, psRight).markAll()
  doAssert b.setBasedOn(c.id, a.id)
  doAssert not b.setBasedOn(a.id, c.id), "never round"
  doAssert not b.setBasedOn(c.id, c.id)
  doAssert b.masterChain(c) == @[a, c]
  b.setMaster(0, c.id)
  let d0 = b.doc(0)
  var names: seq[string]
  for L in d0.layers:
    if L.fromMaster != 0: names.add L.name
  doAssert names == @["Frame", "Logo"], $names           # (A's under B's)
  # on B as it is edited: A's layer, locked
  var onB = 0
  for L in b.masterDoc(c, psRight).layers:
    if L.fromMaster == a.id:
      inc onB
      doAssert L.locked
  doAssert onB == 1
  # A changed: B's pages follow
  b.park()
  discard b.masterDoc(a, psRight).block0("Band", 5, 60, 115, 70)
  b.masterDoc(a, psRight).markAll()
  var n = 0
  for L in b.doc(0).layers:
    if L.fromMaster != 0: inc n
  doAssert n == 3, $n
  # kept with the book; based on none: A's go
  let path = getTempDir() / "retro-based-on.rpb"
  b.saveBook(path)
  let b2 = loadBook(path)
  doAssert b2.masterOf(c.id).basedOn == a.id
  n = 0
  for L in b2.doc(0).layers:
    if L.fromMaster != 0: inc n
  doAssert n == 3, "after loading: " & $n
  doAssert b2.setBasedOn(c.id, 0)
  n = 0
  for L in b2.doc(0).layers:
    if L.fromMaster != 0: inc n
  doAssert n == 1, $n
  b.removeMaster(a.id)
  doAssert c.basedOn == 0
  b.close()
  b2.close()
  removeFile(path)

block textFromPageToPage:
  var s = bookSetup(120, 170, dpi = 72, facing = true)        # (340 x 482 pixels)
  s.top = 30
  s.bottom = 30
  let b = newBook(s, pages = 1)
  let d = b.doc(0)
  let story = newText(words(900), style(14), 0, 0)
  let L = d.addTextLayer(b.boxed(story, 0))
  let added = b.autoflow(0, L)
  doAssert added >= 3, "pages were added: " & $added
  doAssert b.pages.len == added + 1
  doAssert b.isOpen(0) and not b.isOpen(1), "only the page worked on stays in memory"
  # every word once, in order, through the pages
  var all = ""
  for i in 0 ..< b.pages.len:
    let pd = b.doc(i)
    var box: Layer
    for M in pd.layers:
      if M.isText and M.text.boxW > 0: box = M
    doAssert box != nil
    var st = pd.effectiveText(box)
    st.clipOverflow = true
    let lay = layoutText(st)
    let whole = st.plainText
    let shown = if lay.overflow >= 0: whole.substr(0, lay.overflow - 1) else: whole
    doAssert i == b.pages.high or lay.overflow > 0, "page " & $i & " is full"
    all.add shown
    doAssert pd.ink(box, 0, 0, s.w, s.h) > 0, "page " & $i & " shows text"
    if i > 0: doAssert box.flowPage == b.pages[i - 1].id
    if dump.len > 0: discard b.pagePicture(i).savePng(dump / ("book-page" & $i & ".png"))
    b.park([0])
  doAssert all.splitWhitespace == words(900).splitWhitespace, "all of the text, once"
  # the first box made smaller: more goes on, and a page is added
  let before = b.pages.len
  var t = L.text
  t.boxH = t.boxH / 2
  d.setText(L, t)
  doAssert b.autoflow(0, L) >= 1
  doAssert b.pages.len > before
  # saved, opened again
  let path = getTempDir() / "retro-test-book.rpb"
  b.saveBook(path)
  doAssert not b.changed
  let count = b.pages.len
  b.close()
  let c = loadBook(path)
  doAssert c.pages.len == count and c.setup.facing and c.setup.w == s.w
  doAssert c.thumb(1) != nil, "a small picture of a page without opening it"
  doAssert not c.isOpen(1)
  let last = c.doc(c.pages.high)
  var box: Layer
  for M in last.layers:
    if M.isText and M.text.boxW > 0: box = M
  doAssert "word899" in last.effectiveText(box).plainText, "the text's end is on the last page"
  c.park()
  # as a PDF: a page each
  let pdfPath = getTempDir() / "retro-test-book.pdf"
  c.saveBookPdf(pdfPath, pdfPreset(ppWeb))
  let pdfText = readFile(pdfPath)
  doAssert pdfText.startsWith("%PDF") and pdfText.len > 2000
  doAssert not c.changed, "made a PDF, looked at: not changed"
  removeFile(pdfPath)
  # pages moved, copied, taken out
  let firstId = c.pages[0].id
  c.movePage(0, 2)
  doAssert c.pages[2].id == firstId
  c.movePage(2, 0)
  let copy = c.duplicatePage(0)
  doAssert c.pages[1] == copy and c.pages.len == count + 1
  doAssert c.doc(1).layers.len == c.doc(0).layers.len
  c.deletePage(1)
  doAssert c.pages.len == count
  c.close()
  # a damaged book is refused, not crashed on
  var raw = readFile(path)
  for cut in [0, 10, raw.len div 2]:
    writeFile(path, raw[0 ..< cut])
    try:
      let x = loadBook(path)
      x.close()
    except IOError: discard
  var z = newZipWriter()
  z.addFile("book.json", """{"retroBook":1,"setup":{"w":100000,"h":100000},"pages":[]}""")
  writeFile(path, z.finish())
  doAssertRaises(IOError): discard loadBook(path)
  var z2 = newZipWriter()
  z2.addFile("book.json", """{"retroBook":1,"setup":{"w":50,"h":50},"pages":[{"id":1,"storedWith":-9000000000000000000,"inSig":9000000000000000000},{"id":1},{"id":-4}],"masters":[{"id":1}]}""")
  writeFile(path, z2.finish())
  let odd = loadBook(path)
  doAssert odd.pages.len == 1 and odd.masters.len == 0, "an id comes once"       # (and marks too big for a
                                                                                 # 32-bit program are cut to fit)
  doAssert odd.doc(0).w == 50
  odd.close()
  removeFile(path)

block objectsAcrossTheSpine:
  # a shape, a placed picture and a text box of a left page that reach past the spine go
  # on, on the right page; they follow when they move; wholly past it they are that page's
  var s = bookSetup(100, 140, dpi = 72, facing = true)        # (283 x 397 pixels)
  let b = newBook(s, pages = 3)
  let w = s.w
  doAssert b.spreadOf(1) == @[1, 2]
  let d = b.doc(1)                                             # (the left page of the spread)
  proc spans(dd: Doc): seq[Layer] =
    for L in dd.layers:
      if L.fromSpan != 0: result.add L
  doAssert not b.syncSpread(1).changed, "nothing across: nothing done"
  # a shape: 50 pixels on this page, 60 past its edge
  let shape = d.addShapeLayer(ShapeData(path: rectPath(float(w - 50), 40, float(w + 60), 80),
                                        fill: solidPaint(0xFFC02020'u32)), "Band")
  # a placed picture (a Smart Object): 200 wide, half of it past the edge
  var pic = newSeq[uint32](200 * 60)
  for k in 0 ..< pic.len: pic[k] = if k mod 200 < 100: 0xFF2040C0'u32 else: 0xFF20A040'u32
  let photo = d.addLayer("Photo")
  photo.smart = SmartData(src: pic, w: 200, h: 60, quad: quadOf(rect(w - 100, 120, 200, 60)), name: "photo")
  photo.px = renderSmart(photo.smart, d.w, d.h)
  inc photo.ver
  # a text box across the spine
  var t = newText(words(60), style(14), float32(w - 120), 200)
  t.boxW = 240
  t.boxH = 120
  let text = d.addTextLayer(t)
  d.markAll()
  doAssert d.ink(shape, w - 50, 40, w, 80) == 50 * 40, "its part on its own page"
  let r = b.syncSpread(1)
  doAssert r.changed and r.moved == 0
  doAssert b.isOpen(2), "the facing page is in memory with its parts"
  let f = b.doc(2)
  doAssert f.spans.len == 3, $f.spans.len
  var fs, fp, ft: Layer
  for L in f.spans:
    doAssert L.locked and L.fromSpan == b.pages[1].id
    if L.isShape: fs = L
    elif L.smart != nil: fp = L
    elif L.isText: ft = L
  doAssert fs != nil and fp != nil and ft != nil
  # the shape goes on from the facing page's edge: 60 pixels, and no further
  doAssert f.ink(fs, 0, 40, 60, 80) == 60 * 40 and f.ink(fs, 60, 0, w, f.h) == 0
  # the picture: its green half is there (its blue half is on the first page)
  doAssert (fp.px[150 * w + 50] and 0xFFFFFF'u32) == 0x20A040'u32 and f.ink(fp, 100, 0, w, f.h) == 0
  doAssert (photo.px[150 * w + w - 50] and 0xFFFFFF'u32) == 0x2040C0'u32
  # the text: the same lines, cut at the spine -- a letter's row on both pages
  doAssert f.ink(ft, 0, 200, 120, 320) > 0 and d.ink(text, w - 120, 200, w, 320) > 0
  let whole = layoutText(d.effectiveText(text))
  let part = layoutText(f.effectiveText(ft))
  doAssert whole.lines.len == part.lines.len and abs(whole.lines[0].x0 - w.float32 - part.lines[0].x0) < 0.01
  # under the page's own layers
  discard f.addLayer("Own")
  doAssert f.layers.find(fs) < f.layers.high
  # a box flowed onto the facing page goes over the parts there
  let flowed = b.flowOnto(1, text, 2)
  doAssert flowed != nil and f.layers.find(flowed) > f.layers.find(fp), "over the facing page's parts"
  b.unlinkPages(2, flowed)
  f.layers.delete(f.layers.find(flowed))
  # nothing more to do; and the first page has no parts of its own objects
  doAssert not b.syncSpread(1).changed
  doAssert d.spans.len == 0
  if dump.len > 0: discard b.spreadPicture(1, [1, 2]).savePng(dump / "across-spine.png")
  # the shape moved 20 further: its part follows
  d.beginStep("Move")
  d.shiftLayers(@[shape], 20, 0)
  d.endStep()
  doAssert b.syncSpread(1).changed
  var fs2: Layer
  for L in b.doc(2).spans:
    if L.isShape: fs2 = L
  doAssert b.doc(2).ink(fs2, 0, 40, 80, 80) == 80 * 40 and b.doc(2).spans.len == 3
  # moved wholly past the spine: it is the facing page's own now, to pick and to move there
  d.beginStep("Move")
  d.shiftLayers(@[shape], 60, 0)
  d.endStep()
  let m = b.syncSpread(1)
  doAssert m.moved == 1 and shape notin d.layers
  var own: Layer
  for L in b.doc(2).layers:
    if L.isShape and L.fromSpan == 0: own = L
  doAssert own != nil and not own.locked and b.doc(2).spans.len == 2
  doAssert b.doc(2).ink(own, 30, 40, 140, 80) == 110 * 40
  # an object of the right page that reaches back over the spine: its part on the left page
  d.beginStep("x")
  d.endStep()
  let f2 = b.doc(2)
  f2.beginStep("Move")
  f2.shiftLayers(@[own], -60, 0)
  f2.endStep()
  doAssert b.syncSpread(2).changed
  var back: Layer
  for L in b.doc(1).spans:
    if L.isShape: back = L
  doAssert back != nil and b.doc(1).ink(back, w - 30, 40, w, 80) == 30 * 40
  # saved, opened: each page has its parts, and they are not made again
  let path = getTempDir() / "retro-test-across.rpb"
  b.saveBook(path)
  b.close()
  let c = loadBook(path)
  doAssert c.doc(2).spans.len == 2 and c.doc(1).spans.len == 1
  doAssert not c.changed, "read back as it was"
  doAssert not c.syncSpread(1).changed and not c.syncSpread(2).changed, "nothing to make again"
  c.park()
  discard c.doc(1)
  doAssert not c.syncSpread(1).changed, "a page turned to: its facing page is not made again"
  doAssert not c.isOpen(2), "... nor read"
  # the picture taken off its page: its part goes from the facing page
  let d1 = c.doc(1)
  for k in countdown(d1.layers.high, 0):
    if d1.layers[k].smart != nil and d1.layers[k].fromSpan == 0: d1.layers.delete(k)
  d1.cur = 0
  d1.markAll()
  doAssert c.syncSpread(1).changed
  doAssert c.doc(2).spans.len == 1
  # a page put in before them: the pages no longer face each other, the parts go
  discard c.insertPage(1)
  doAssert c.partner(2) == 1 and c.doc(3).spans.len == 0, $c.doc(3).spans.len
  c.close()
  removeFile(path)
  # pages that do not face have none
  let single = newBook(bookSetup(100, 140, dpi = 72, facing = false), pages = 2)
  let sd = single.doc(0)
  discard sd.addShapeLayer(ShapeData(path: rectPath(250, 40, 400, 80), fill: solidPaint(0xFFC02020'u32)))
  doAssert not single.syncSpread(0).changed
  single.close()

block aBoxThatHoldsNothingEnds:
  # a letter bigger than the page: pages are not added for ever
  let b = newBook(bookSetup(30, 30, dpi = 72, facing = false), pages = 1)
  let d = b.doc(0)
  let L = d.addTextLayer(b.boxed(newText("WWWW", style(300), 0, 0), 0))
  doAssert b.autoflow(0, L) <= 4
  b.close()

block anchoredObjects:
  # a shape anchored to a line of text: it moves with the line as text comes before it, stays
  # beside it as the text after it changes; the anchor takes no room in the text, the caret's
  # places stay one a character; saved and read back; released, it stays where it is
  let d = newDoc(600, 500, 0xFFFFFFFF'u32)
  var st = defaultStyle()
  st.size = 20
  var t = newText("First paragraph.\nThe line the picture goes with.\nThe end.", st, 20, 20)
  t.boxW = 400
  t.boxH = 400
  let T = d.addTextLayer(t)
  let plainGlyphs = layoutText(T.text).glyphs.len
  let S = d.addShapeLayer(ShapeData(path: rectPath(450, 60, 520, 100), fill: solidPaint(0xFFFF0000'u32)), "Box")
  let o0 = d.anchorOrigin(S)
  doAssert d.anchorToText(S, T)
  doAssert T.text.anchorMarks.len == 1 and S.anchorTo == T.uid
  doAssert layoutText(T.text).glyphs.len == plainGlyphs, "the anchor draws nothing"
  doAssert layoutText(T.text).caretX.len == T.text.runeLen + 1
  doAssert d.anchorOrigin(S) == o0, "anchored where it is"
  # two lines before it: it goes down with its line
  var t2 = T.text
  t2.insertText(0, "A new first line.\nAnother.\n", st)
  d.setText(T, t2)
  let o1 = d.anchorOrigin(S)
  doAssert o1.x == o0.x and o1.y > o0.y + 30, $o1
  # text after it: it stays
  var t3 = T.text
  t3.insertText(T.text.runeLen, " More at the end.", st)
  d.setText(T, t3)
  doAssert d.anchorOrigin(S) == o1
  # saved and read back
  let path = getTempDir() / "retro-anchor-test.rpd"
  d.saveRpd(path)
  let back = loadRpd(path)
  removeFile(path)
  var S2, T2: Layer
  for L in back.layers:
    if L.name == "Box": S2 = L
    if L.isText: T2 = L
  doAssert S2.anchorTo == T2.uid and S2.anchorAt == S.anchorAt
  var t4 = T2.text
  t4.insertText(0, "One more.\n", st)
  back.setText(T2, t4)
  doAssert back.anchorOrigin(S2).y > o1.y + 15, "still following after it was opened"
  # released: the anchor out of the text, the shape where it was
  d.releaseAnchor(S)
  doAssert T.text.anchorMarks.len == 0 and S.anchorTo == 0
  var t5 = T.text
  t5.insertText(0, "And another.\n", st)
  d.setText(T, t5)
  doAssert d.anchorOrigin(S) == o1

block threadedFrames:
  # text frames threaded as the layout program does it: the text goes on from the first box into
  # the next; a box with its own text, threaded, adds it to the story's end; one threaded in
  # between; a box already in the thread before cannot be next; the thread broken: the box empty,
  # its text overset in the box before
  let d = newDoc(600, 400, 0xFFFFFFFF'u32)
  var t = newText(words(80), style(), 10, 10)
  t.boxW = 180
  t.boxH = 120
  let A = d.addTextLayer(t)
  var tb = newText("", style(), 210, 10)
  tb.boxW = 180
  tb.boxH = 120
  let B = d.addTextLayer(tb)
  var tc = newText("Own words.", style(), 410, 10)
  tc.boxW = 180
  tc.boxH = 120
  let C = d.addTextLayer(tc)
  doAssert layoutText(A.text).overflow > 0, "overset"
  d.beginStep("Thread")
  d.touchLayers()
  doAssert d.threadText(A, B)
  d.endStep()
  doAssert B.flowFrom == A.uid and d.followerOf(A) == B and d.flowsOn(A)
  let shownB = d.effectiveText(B).plainText
  doAssert shownB.startsWith("word") and "word0 " notin shownB, "B goes on where A stops"
  # C has its own text: added to the end of A's story, C after B
  doAssert d.threadText(B, C)
  doAssert C.flowFrom == B.uid and A.text.plainText.endsWith("Own words.")
  doAssert C.text.plainText.len == 0
  # not before itself, not twice
  doAssert not d.canThread(C, A) and not d.canThread(A, C)
  # a box between A and B
  var tx = newText("", style(), 10, 200)
  tx.boxW = 180
  tx.boxH = 120
  let X = d.addTextLayer(tx)
  doAssert d.threadText(A, X)
  doAssert X.flowFrom == A.uid and B.flowFrom == X.uid and d.storyHead(C) == A
  # broken between X and B: B and C empty, A and X keep theirs
  d.unthreadText(B)
  doAssert B.flowFrom == 0 and C.flowFrom == B.uid
  doAssert d.effectiveText(B).plainText.len == 0 and d.effectiveText(C).plainText.len == 0
  doAssert d.effectiveText(X).plainText.len > 0
  doAssert layoutText(d.effectiveText(X)).overflow >= 0, "the rest overset in X"
  # undone: as it was before the first thread
  d.undo()
  doAssert B.flowFrom == 0 and B.text.plainText.len == 0

block threadedAcrossPages:
  # a box on one page threaded into a box on another: the text goes on there; broken: empty
  let b = newBook(bookSetup(148, 210, dpi = 72, facing = false), pages = 3, name = "Thread")
  let d0 = b.doc(0)
  let S = d0.addTextLayer(b.boxed(newText(words(400), style(14)), 0))
  let d2 = b.doc(2)
  var mt = b.boxed(newText("The end.", style(14)), 2)
  mt.boxH = 80
  let M = d2.addTextLayer(mt)
  doAssert b.threadPages(0, S, 2, M)
  doAssert M.flowPage == b.pages[0].id and M.flowFrom == S.uid and S.flowOut
  let shown = b.doc(2).effectiveText(M).plainText
  doAssert shown.startsWith("word") and "word0 " notin shown, shown[0 ..< min(40, shown.len)]
  doAssert S.text.plainText.endsWith("The end."), "its own words at the story's end"
  doAssert b.storyStart(2, M) == (0, S)
  b.unlinkPages(2, M, keepText = false)
  doAssert M.flowFrom == 0 and b.doc(2).effectiveText(M).plainText.len == 0
  b.close()

block olderFilesKeepTheirText:
  # a box from before text kept to its box -- its text drawn below it then -- opened: made as tall
  # as its text (Auto-Size), so it shows what it showed; saved now, nothing changes when opened
  let d = newDoc(400, 300, 0xFFFFFFFF'u32)
  var t = newText(words(60), style(), 10, 10)
  t.boxW = 200
  t.boxH = 40
  let L = d.addTextLayer(t)
  doAssert layoutText(L.text).overflow > 0
  var parts = d.rpdParts
  for p in parts.mitems:
    if p.name == "document.json":
      let j = parseJson(p.data)
      j.delete("overset")
      p.data = $j
  let path = getTempDir() / "older-text.rpd"
  writeRpd(parts, path)
  let back = loadRpd(path)
  var B: Layer
  for X in back.layers:
    if X.isText: B = X
  doAssert B.text.autoSize == asHeight and B.text.boxH > 100 and layoutText(B.text).overflow < 0
  # saved by this version: as it is
  d.saveRpd(path)
  let now = loadRpd(path)
  for X in now.layers:
    if X.isText: doAssert X.text.autoSize == asOff and X.text.boxH == 40
  removeFile(path)

block freeSpansOfALine:
  # the line breaker's question: what room does a line lying from ya to yb have, beside the holes
  let box = (0'f32, 500'f32)
  doAssert freeSpans([], 10, 30, box[0], box[1], 24) == @[(0'f32, 500'f32)], "no hole: the whole line"
  # two objects on one line: three pieces, left to right
  let two = [(100'f32, 0'f32, 160'f32, 100'f32), (300'f32, 20'f32, 360'f32, 80'f32)]
  doAssert freeSpans(two, 30, 50, box[0], box[1], 24) == @[(0'f32, 100'f32), (160'f32, 300'f32), (360'f32, 500'f32)]
  # a band only one of them is in
  doAssert freeSpans(two, 85, 99, box[0], box[1], 24) == @[(0'f32, 100'f32), (160'f32, 500'f32)]
  # the shortest piece: what is narrower is left empty
  let near = [(30'f32, 0'f32, 470'f32, 100'f32)]
  doAssert freeSpans(near, 10, 30, box[0], box[1], 24) == @[(470'f32, 500'f32)] or
           freeSpans(near, 10, 30, box[0], box[1], 24) == @[(0'f32, 30'f32), (470'f32, 500'f32)]
  doAssert freeSpans(near, 10, 30, box[0], box[1], 40).len == 0, "no piece 40 wide: none"
  # an outline's place in a band (a turned square, a diamond)
  let diamond = [(100'f32, 0'f32), (200'f32, 100'f32), (100'f32, 200'f32), (0'f32, 100'f32)]
  let mid = bandSpan(diamond, 95, 105)
  doAssert mid.ok and abs(mid.x0) < 0.01 and abs(mid.x1 - 200) < 0.01, $mid
  let top = bandSpan(diamond, 10, 20)
  doAssert top.ok and abs(top.x0 - 80) < 0.01 and abs(top.x1 - 120) < 0.01, $top
  doAssert not bandSpan(diamond, 210, 220).ok

proc arabicWords(n: int): string =
  for k in 0 ..< n: result.add "كلمة" & $k & " "

proc textLayer(d: Doc; n: int; x, y, w, h: float32; size = 16.0; rtl = false): Layer =
  var t = newText((if rtl: arabicWords(n) else: words(n)), style(size), x, y)
  t.boxW = w
  t.boxH = h
  if rtl: t.para.rtl = 2
  d.addTextLayer(t)

block textWrapSidesAndOffsets:
  let d = newDoc(600, 400, 0xFFFFFFFF'u32)
  d.dpi = 144                                  # (two pixels a point)
  let T = d.textLayer(150, 20, 20, 560, 360)
  let B = d.block0("Picture", 200, 100, 400, 220)
  # offsets of their own on each side, points: top 3, bottom 6, left 9, right 12
  B.wrap = 1
  B.wrapOpts.offsets = [3'f32, 6, 9, 12]
  doAssert d.wrapHoles(T) == @[(182'f32, 94'f32, 424'f32, 232'f32)], $d.wrapHoles(T)
  d.rewrap()
  doAssert d.ink(T, 184, 100, 422, 220) == 0 and d.ink(T, 20, 100, 178, 220) > 0
  # the old gap (a file before them): every side
  B.wrapOpts.offsets = [0'f32, 0, 0, 0]
  B.wrapGap = 5
  doAssert d.wrapHoles(T) == @[(195'f32, 95'f32, 405'f32, 225'f32)]
  B.wrapGap = 0
  # two objects on one line: the line goes on beside both of them, on one baseline
  let C = d.block0("Second", 460, 120, 500, 200)
  C.wrap = 1
  d.rewrap()
  block:
    let lay = layoutText(d.effectiveText(T))
    var pieces = 0
    for ln in lay.lines:
      if ln.baseline > 140 and ln.baseline < 180: inc pieces
    doAssert pieces >= 3 * 2, "three pieces a line beside the two (" & $pieces & ")"
  d.layers.delete(d.layers.find(C))
  # the side with more room -- Arabic: on its right when they are the same
  let R = d.textLayer(150, 20, 20, 560, 360, rtl = true)
  T.visible = false
  B.wrapSide = 3
  d.layers.delete(d.layers.find(B))
  let mid = d.block0("Middle", 250, 100, 350, 220)
  mid.wrap = 1
  mid.wrapSide = 3
  d.rewrap()
  doAssert d.ink(R, 360, 104, 580, 216) > 0 and d.ink(R, 20, 104, 240, 216) == 0,
           "the same room either side: Arabic on its right"
  R.visible = false
  T.visible = true
  d.rewrap()
  doAssert d.ink(T, 20, 104, 240, 216) > 0 and d.ink(T, 360, 104, 580, 216) == 0, "... Latin on its left"
  # Invert: the text inside it only
  mid.wrapSide = 0
  mid.wrapOpts.invert = true
  d.rewrap()
  doAssert d.ink(T, 20, 20, 240, 380) == 0 and d.ink(T, 360, 20, 580, 380) == 0 and d.ink(T, 252, 100, 348, 220) > 0,
           "the text inside its box only"
  mid.wrapOpts.invert = false
  # the shortest piece of a line beside it, points: 200 points (400 pixels) -- no line beside it
  T.wrapOpts.least = 200
  d.drawText(T)
  doAssert d.ink(T, 20, 104, 240, 216) == 0 and d.ink(T, 360, 104, 580, 216) == 0, "nothing beside it"
  T.wrapOpts.least = 0
  d.drawText(T)
  doAssert d.ink(T, 20, 104, 240, 216) > 0
  if dump.len > 0: discard d.toBitmap(0xFFFFFFFF'u32).savePng(dump / "wrap-sides.png")

block textWrapTurned:
  # a turned picture (a placed one, its corners where they are): the text comes into the corners
  # of its box -- its own outline is what it keeps out of, band by band
  let d = newDoc(600, 400, 0xFFFFFFFF'u32)
  let T = d.textLayer(220, 10, 10, 580, 380, size = 12)
  var pic = newSeq[uint32](100 * 100)
  for k in 0 ..< pic.len: pic[k] = 0xFF2040C0'u32
  let P = d.addLayer("Turned")
  # (a square turned 45 degrees round (300, 200): a diamond 200 across)
  P.smart = SmartData(src: pic, w: 100, h: 100,
                      quad: [(300.0, 129.29), (370.71, 200.0), (300.0, 270.71), (229.29, 200.0)])
  P.px = renderSmart(P.smart, d.w, d.h)
  inc P.ver
  P.wrap = 1
  d.rewrap()
  let holes = d.wrapHoles(T)
  doAssert holes.len > 50, "band by band: " & $holes.len
  var widest = 0'f32
  for h in holes: widest = max(widest, h.x1 - h.x0)
  doAssert widest > 130 and widest < 146 and holes[0].x1 - holes[0].x0 < 10, "a diamond, not its box"
  doAssert d.ink(T, 285, 190, 315, 210) == 0, "nothing in its middle"
  doAssert d.ink(T, 232, 132, 262, 160) > 0, "text in its box's corner, where the diamond is not"
  if dump.len > 0: discard d.toBitmap(0xFFFFFFFF'u32).savePng(dump / "wrap-turned.png")

block textWrapJumpsToTheNextColumn:
  let d = newDoc(600, 400, 0xFFFFFFFF'u32)
  var t = newText(words(200), style(14), 10, 10)
  t.boxW = 580
  t.boxH = 380
  t.columns = 2
  t.gutter = 20
  let T = d.addTextLayer(t)
  let B = d.block0("Picture", 40, 150, 200, 250)
  B.wrap = 4
  d.rewrap()
  doAssert d.ink(T, 10, 150, 290, 390) == 0, "below its top the first column takes no more"
  doAssert d.ink(T, 10, 10, 290, 140) > 0 and d.ink(T, 310, 10, 590, 390) > 0, "the text goes on in the next one"

block textWrapTowardTheSpine:
  # a book's pages: toward the spine is right on a left page and left on a right page, as the
  # binding has them -- and bound on the right, the other way round
  for binding in [bindLeft, bindRight]:
    let s = bookSetup(140, 100, dpi = 72, facing = true, binding = binding)
    let b = newBook(s, pages = 3)
    for i in [1, 2]:
      let d = b.doc(i)
      let T = d.textLayer(120, 10, 10, float32(d.w - 20), float32(d.h - 20), size = 10)
      let B = d.block0("Picture", d.w div 2 - 40, 80, d.w div 2 + 40, 160)
      B.wrap = 1
      B.wrapSide = 4
      d.rewrap()
      let spineRight = b.sideOf(i) == psLeft
      let l = d.ink(T, 10, 84, d.w div 2 - 44, 156)
      let r = d.ink(T, d.w div 2 + 44, 84, d.w - 10, 156)
      doAssert (if spineRight: r > 0 and l == 0 else: l > 0 and r == 0),
               "toward the spine, page " & $i & " " & $binding & ": " & $l & " " & $r
      B.wrapSide = 5
      d.rewrap()
      let l2 = d.ink(T, 10, 84, d.w div 2 - 44, 156)
      let r2 = d.ink(T, d.w div 2 + 44, 84, d.w - 10, 156)
      doAssert (if spineRight: l2 > 0 and r2 == 0 else: r2 > 0 and l2 == 0), "away from it"
    b.close()

block textWrapAcrossTheSpine:
  # a picture across the spine, wrapped: the text on both pages keeps out of it
  let s = bookSetup(100, 140, dpi = 72, facing = true)
  let b = newBook(s, pages = 3)
  let w = s.w
  let d = b.doc(1)
  let f = b.doc(2)
  let Tl = d.textLayer(120, 10, 10, float32(w - 20), float32(d.h - 20), size = 10)
  let Tr = f.textLayer(120, 10, 10, float32(w - 20), float32(f.h - 20), size = 10)
  var pic = newSeq[uint32](120 * 60)
  for k in 0 ..< pic.len: pic[k] = 0xFF2040C0'u32
  let P = d.addLayer("Photo")
  P.smart = SmartData(src: pic, w: 120, h: 60, quad: quadOf(rect(w - 60, 150, 120, 60)), name: "photo")
  P.px = renderSmart(P.smart, d.w, d.h)
  inc P.ver
  P.wrap = 1
  d.markAll()
  d.rewrap()
  discard b.syncSpread(1)
  f.rewrap()
  doAssert d.ink(Tl, w - 58, 152, w, 208) == 0, "kept out on its own page"
  doAssert f.ink(Tr, 0, 152, 58, 208) == 0 and f.ink(Tr, 70, 152, w - 10, 208) > 0, "and on the facing page"
  b.close()

block textWrapKept:
  # in the document's file, in an Object Style; a file from before -- its gap -- as it was
  let d = newDoc(300, 200, 0xFFFFFFFF'u32)
  let B = d.block0("Picture", 50, 50, 150, 150)
  B.wrap = 1
  B.wrapSide = 5
  B.wrapOpts = WrapOptions(offsets: [1'f32, 2, 3, 4], linked: false, invert: true)
  let path = getTempDir() / "wrap-kept.rpd"
  d.saveRpd(path)
  let back = loadRpd(path)
  var K: Layer
  for X in back.layers:
    if X.name == "Picture": K = X
  doAssert K.wrap == 1 and K.wrapSide == 5 and K.wrapOpts == B.wrapOpts, "kept in its file"
  removeFile(path)
  var def = objectStyleOf(B, "Wrapped")
  doAssert def.useWrap and def.wrapOpts == B.wrapOpts
  d.redefineObjectStyle(def)
  let C = d.block0("Other", 200, 50, 250, 100)
  d.applyObjectStyle(C, "Wrapped")
  doAssert C.wrap == 1 and C.wrapSide == 5 and C.wrapOpts == B.wrapOpts, "given by the Object Style"
  let j = objectStyleToJson(def)
  doAssert objectStyleFromJson(j).wrapOpts == def.wrapOpts and objectStyleFromJson(parseJson($j)).useWrap


echo "test_photobook: ok"
