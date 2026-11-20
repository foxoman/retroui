## Tests of Retro Photo's books as a program, run headless: a book in a
## window, pages turned, added, copied and taken out, master pages, page
## numbers typed in, text that goes on through new pages, Text Wrap, the
## book's file and PDF, the workspaces, the Move tool's box that picks
## layers; New Drawing and New Book, Image Trace, Convert to Shape, Make
## Blend, drop caps and the baseline grid.

import std/[strutils, os]
import retroui/uirelays/input
import harness

const photoUnderTest = true
include ../examples/photo

let home = getTempDir() / "retro-photo-booktest"
removeDir(home)
createDir(home)
putEnv("HOME", home)
setCurrentDir(home)

fakeDriver()
setup()
startApp("photo", W, H)
view = photoFrame
run(3)

proc folio(d: Doc): string =
  for L in d.layers:
    if L.fromMaster != 0 and L.isText: return d.effectiveText(L).plainText

block aBookInAWindow:
  var s = bookSetup(100, 140, dpi = 72, facing = true)
  addBook(newBook(s, 3, "Test Book"))
  run(3)
  let bw = curBook()
  doAssert bw != nil and bw.page == 0 and docs.len == 1
  doAssert "Test Book" in active.doc.name and "page 1 of 3" in active.doc.name
  doAssert panelShown("pages")
  doAssert not active.doc.modified, "a new book has nothing to save"
  # pages turned: the window's document is the page; the one before is parked
  let first = active.doc
  runCommand("Next Page")
  run(2)
  doAssert bw.page == 1 and active.doc != first
  doAssert bw.book.isOpen(1) and not bw.book.isOpen(0)
  runCommand("Last Page")
  doAssert bw.page == 2
  runCommand("Next Page")
  doAssert bw.page == 2, "no page after the last"
  runCommand("First Page")
  doAssert bw.page == 0
  # Shift+Page Down and Up
  key(KeyPageDown, {ShiftPressed})
  run(2)
  doAssert bw.page == 1
  key(KeyPageUp, {ShiftPressed})
  run(2)
  doAssert bw.page == 0
  # added, copied, taken out
  runCommand("Add Page")
  doAssert bw.book.pages.len == 4 and bw.page == 1
  runCommand("Duplicate Page")
  doAssert bw.book.pages.len == 5 and bw.page == 2
  runCommand("Delete Page")
  doAssert bw.book.pages.len == 4 and bw.page == 2
  run(2)
  doAssert active.doc.modified, "the book changed: its window says so"
  # the window shows the page turned to, read back from where it was parked (another
  # document in the same view: all of it is drawn, whatever its version says)
  proc fill(c: uint32) =
    let d = active.doc
    for k in 0 ..< d.layers[0].px.len: d.layers[0].px[k] = c
    inc d.layers[0].ver
    d.markAll()
  proc middle(): uint32 =
    run(3)
    let v = active.view.view
    px(v.x + v.w div 2, v.y + v.h div 2)
  bw.showPage(0)
  fill(0xFFC02020'u32)
  doAssert middle() == 0xC02020'u32, toHex(middle().int, 6)
  bw.showPage(1)
  fill(0xFF2040C0'u32)
  doAssert middle() == 0x2040C0'u32
  bw.showPage(0)
  doAssert middle() == 0xC02020'u32, "page 1 again, not page 2's picture: " & toHex(middle().int, 6)
  bw.showPage(1)
  doAssert middle() == 0x2040C0'u32
  bw.showPage(2)

block mastersAndNumbers:
  let bw = curBook()
  runCommand("New Master")
  run(2)
  doAssert bw.master > 0 and "Master" in active.doc.name
  # a folio typed on the master with the Type tool's own procs
  let md = active.doc
  var t = newText("- <#> -", typeStyle, 20, 60)
  t.spans[0].style.size = 14
  md.beginStep("Type")
  md.touchLayers()
  discard md.addTextLayer(t)
  md.endStep()
  runCommand("Back to the Page")
  run(2)
  doAssert bw.master == 0
  runCommand("Master: A")
  run(2)
  doAssert active.doc.folio == "- " & bw.book.label(bw.page) & " -", active.doc.folio
  runCommand("Master for All Pages: A")
  runCommand("First Page")
  run(2)
  doAssert active.doc.folio == "- 1 -"
  runCommand("Last Page")
  run(2)
  doAssert active.doc.folio == "", "a left page: the master's left page has nothing on it"
  bw.showPage(2)
  doAssert active.doc.folio == "- 3 -"
  # numbers started again; in Roman numerals
  bw.book.pages[bw.page].restart = 9
  var s = bw.book.setup
  s.numbers = nsRomanLower
  bw.book.setSetup(s)
  bw.showPage(bw.page)
  doAssert active.doc.folio == "- ix -"
  runCommand("Page Numbers Go On Here")
  doAssert active.doc.folio == "- iii -"
  runCommand("No Master")
  doAssert active.doc.folio == ""

block pageNumberTypedIn:
  let bw = curBook()
  bw.showPage(0)
  let d = active.doc
  tool = tType
  d.beginStep("Type")
  d.touchLayers()
  let L = d.addTextLayer(newText("Page ", typeStyle, 20, 100))
  d.endStep()
  startTypeEdit(active, L, false, 5)
  runCommand("Insert Page Number")
  doAssert te.on, "the text is still being typed"
  doAssert L.text.plainText == "Page <#>"
  doAssert d.effectiveText(L).plainText == "Page <#>", "as written while it is typed"
  commitType()
  doAssert d.effectiveText(L).plainText == "Page i"
  tool = tMove

block textThroughNewPages:
  let bw = curBook()
  bw.showPage(1)
  let d = active.doc
  var words = ""
  for k in 0 ..< 700: words.add "w" & $k & " "
  var st = typeStyle
  st.size = 12
  d.beginStep("Type")
  d.touchLayers()
  let L = d.addTextLayer(bw.book.boxed(newText(words, st, 0, 0), 1))
  d.endStep()
  let before = bw.book.pages.len
  runCommand("Autoflow Through New Pages")
  run(2)
  doAssert bw.book.pages.len > before + 1, "pages were added: " & $bw.book.pages.len
  doAssert bw.page == 1 and active.doc == d, "the page worked on stays"
  runCommand("Next Page")
  run(2)
  var cont: Layer
  for M in active.doc.layers:
    if M.isText and M.flowPage != 0: cont = M
  doAssert cont != nil and active.doc.effectiveText(cont).plainText.len > 0, "the text goes on here"
  doAssert bw.book.pages[bw.page].master == bw.book.pages[1].master, "new pages have the master of the page they come from"

block textWrapByCommand:
  let bw = curBook()
  bw.showPage(1)
  let d = active.doc
  d.beginStep("Picture")
  d.touchLayers()
  let P = d.addLayer("Picture")
  let m = bw.book.marginBox(1)
  for y in m.y + 60 ..< m.y + 120:
    for x in m.x + 40 ..< m.x + 120: P.px[y * d.w + x] = 0xFF3060C0'u32
  inc P.ver
  d.markAll()
  d.endStep()
  var box: Layer
  for M in d.layers:
    if M.isText and M.text.boxW > 0 and M.fromMaster == 0: box = M
  proc inkUnder(): int =
    for y in m.y + 62 ..< m.y + 118:
      for x in m.x + 42 ..< m.x + 118:
        if (box.px[y * d.w + x] shr 24) > 0: inc result
  doAssert inkUnder() > 0
  d.wrapStep(P, "Text Wrap", proc () = P.wrap = 1)
  doAssert inkUnder() == 0, "the text keeps out of the picture"
  runCommand("Undo")
  doAssert P.wrap == 0 and inkUnder() > 0
  # the panel: opened by the command, drawn; its offsets in points (the rulers' unit shown)
  runCommand("Text Wrap...")
  doAssert panelShown("textwrap")
  run(3)
  d.wrapStep(P, "Text Wrap", proc () =
    P.wrap = 1
    P.wrapOpts.offsets = [4'f32, 4, 4, 4])
  run(2)
  doAssert inkUnder() == 0 and d.wrapOffsetsPx(P)[0] > 3.9 * d.dpi / 72
  # its bottom handle dragged down with the Move tool: that offset only, the layer not moved
  selectTool(tMove)
  d.cur = d.layers.find(P)
  run(2)
  var hb: tuple[side: int; x, y, nx, ny: float32]
  for h in d.wrapHandles(P):
    if h.side == 1: hb = h
  let (hx, hy) = active.view.toScreen(d, hb.x.float, hb.y.float)
  let px0 = P.px
  let steps = d.stepsMade
  down(hx, hy)
  run()
  move(hx, hy + 30)
  run()
  up(hx, hy + 30)
  run(2)
  doAssert P.wrapOpts.offsets[1] > 4 and P.wrapOpts.offsets[0] == 4 and P.wrapOpts.offsets[3] == 4,
           "the bottom one only: " & $P.wrapOpts.offsets
  doAssert P.px == px0, "not moved"
  doAssert d.stepsMade == steps + 1, "one step"
  runCommand("Undo")
  doAssert P.wrapOpts.offsets[1] == 4
  # dragged away with the Move tool: the text flows back in as it goes, before the mouse is up
  let (cx, cy) = active.view.toScreen(d, float(m.x + 80), float(m.y + 90))
  let (fx, _) = active.view.toScreen(d, float(m.x + 80 + 160), float(m.y + 90))
  down(cx, cy)
  run()
  move(cx + (fx - cx) div 2, cy)
  run()
  move(fx, cy)
  run(2)
  doAssert ui.mouseDown and d.stepOpen, "still dragging"
  doAssert inkUnder() > 0, "the text where it was, at once"
  up(fx, cy)
  run(2)
  doAssert inkUnder() > 0 and not d.stepOpen
  runCommand("Undo")
  run(2)
  doAssert inkUnder() == 0, "undone: round it again"
  runCommand("Undo")
  togglePanel("textwrap")
  run(2)

block savedOpenedAndAsPdf:
  let bw = curBook()
  let count = bw.book.pages.len
  let path = home / "test.rpb"
  bw.writeBook(path)
  doAssert fileExists(path) and bw.book.path == path
  run(2)
  doAssert not active.doc.modified, "saved: nothing to save"
  let pdf = home / "test.pdf"
  proc pdfPages(f: string): int =
    let s = readFile(f)
    var i = 0
    while true:
      i = s.find("/Type /Page ", i)
      if i < 0: break
      inc result
      i += 11
  bookPdf = bw
  doAssert bookPdfWrite(pdf, pdfPreset(ppWeb))
  doAssert readFile(pdf).startsWith("%PDF") and pdfPages(pdf) == count, "every page: " & $pdfPages(pdf)
  # File > Save as PDF of a book's page: the book -- all of it, the page shown, a range, spreads
  startSavePdf(bw.dw)
  doAssert pdfPath.endsWith(bw.book.name & ".pdf"), "named after the book: " & pdfPath
  pdfPick = false
  startPdfOptions(@[bw.dw.doc], pdf)
  bookPdfFor(bw.dw)
  doAssert bookPdf == bw and bookPdfNote() == $count & " pages"
  bookPdfPages = (1, "", false)
  doAssert bookPdfNote() == "1 page"
  bookPdfPages = (2, "1-2", false)
  doAssert bookPdfNote() == "2 pages"
  pdfDlg.open = false
  writePdfNow()
  doAssert pdfPages(pdf) == 2, "a range: " & $pdfPages(pdf)
  startPdfOptions(@[bw.dw.doc], pdf)
  bookPdfFor(bw.dw)
  bookPdfPages = (0, "", true)
  pdfDlg.open = false
  writePdfNow()
  doAssert pdfPages(pdf) < count, "as spreads, fewer sheets: " & $pdfPages(pdf)
  bookPdfPages = (0, "", false)
  # a picture's own Save as PDF: no book in it
  startPdfOptions(@[bw.dw.doc], pdf)
  doAssert bookPdf == nil
  pdfDlg.open = false
  # closed, opened again through File > Open
  active.win.open = false
  run(3)
  doAssert docs.len == 0 and books.len == 0, "the book went with its window"
  openFile(path)
  run(3)
  let again = curBook()
  doAssert again != nil and again.book.pages.len == count and again.page == 0
  doAssert "page i of" in active.doc.name
  again.showPage(2)
  var cont: Layer
  for M in active.doc.layers:
    if M.isText and M.flowPage != 0: cont = M
  doAssert cont != nil and active.doc.effectiveText(cont).plainText.len > 0, "the text still goes on"
  active.win.open = false
  run(3)

block workspaces:
  runCommand("Workspace: Layout")
  run(3)
  doAssert panelShown("pages") and panelShown("character")
  doAssert "Brush" in prefs.toolHidden
  runCommand("Workspace: Drawing")
  run(3)
  doAssert panelShown("layers") and panelShown("properties")
  doAssert "Healing" in prefs.toolHidden and "Pen" notin prefs.toolHidden
  runCommand("Workspace: Photo")
  run(3)
  doAssert prefs.toolHidden == "" and panelShown("layers")

block acrossTheSpine:
  # a shape of a page drawn out past the spine: its other part is on the facing page by
  # itself, once the mouse is up; turned to, it is there, locked
  addBook(newBook(bookSetup(100, 140, dpi = 72, facing = true), 4, "Spread"))
  run(3)
  let bw = curBook()
  bw.showPage(1)
  let d = active.doc
  d.beginStep("Rectangle")
  d.touchLayers()
  let band = d.addShapeLayer(ShapeData(path: rectPath(float(d.w - 40), 50, float(d.w + 70), 90),
                                       fill: solidPaint(0xFF20A040'u32)), "Band")
  d.endStep()
  run(3)
  doAssert bw.book.isOpen(2), "the facing page was made to follow"
  proc parts(dd: Doc): int =
    for L in dd.layers:
      if L.fromSpan != 0: inc result
  doAssert bw.book.doc(2).parts == 1
  doAssert active.doc == d and band in d.layers
  bw.showPage(2)
  run(3)
  doAssert active.doc.parts == 1
  var part: Layer
  for L in active.doc.layers:
    if L.fromSpan != 0: part = L
  doAssert part.locked and (part.px[70 * active.doc.w + 30] and 0xFFFFFF'u32) == 0x20A040'u32
  # the window shows it at the page's left edge
  block:
    run(2)
    let v = active.view
    let (sx, sy) = v.toScreen(active.doc, 30, 70)
    doAssert px(sx, sy) == 0x20A040'u32, toHex(px(sx, sy).int, 6)
  active.win.open = false
  run(2)
  doAssert flowRunning("close"), "its changes not saved: asked first"
  for dw in docs: cancelFlows(docKey(dw))
  var mine: seq[DocWin]
  for dw in docs:
    if isBookWin(dw): mine.add dw
  for dw in mine: closeDoc(dw)
  run(2)

block theMoveToolsBox:
  # dragged from where nothing is: the layers the box touches are picked
  let d = newDoc(300, 200, white, name = "pick")
  addDoc(d)
  run(3)
  for (name, x) in [("One", 20), ("Two", 120), ("Three", 220)]:
    let L = d.addLayer(name)
    for y in 40 ..< 80:
      for xx in x ..< x + 40: L.px[y * d.w + xx] = 0xFFAA2020'u32
    inc L.ver
  d.markAll()
  tool = tMove
  moveAutoSelect = true
  moveShowControls = false           # (no handles under a mouse that is nowhere)
  pressOn(active, PhotoEvent(over: true, x: 5, y: 10, down: true, pressed: true))
  doAssert drag.on and drag.band, "a box, not a move"
  dragOn(PhotoEvent(over: true, x: 170, y: 120, down: true))
  releaseOn(PhotoEvent(over: true, x: 170, y: 120))
  doAssert d.pickedLayers.len == 2, $d.pickedLayers.len
  doAssert d.current.name == "Two"
  # a click on nothing: none picked
  pressOn(active, PhotoEvent(over: true, x: 5, y: 150, down: true, pressed: true))
  releaseOn(PhotoEvent(over: true, x: 5, y: 150))
  doAssert d.pickedLayers.len <= 1

block newDrawingBookTraceShapesBlend:
  # File > New Drawing and New Book with their templates; Image Trace; Convert to Shape; Make
  # Blend; drop caps and the baseline grid in the Paragraph palette's book
  let n0 = docs.len
  startNewDrawing()
  doAssert nlDraw.open
  run(2)
  setUiLanguage("ar", @toolkitArabic, @photoArabic)
  run(2)
  setUiLanguage("")
  nlDraw.open = false
  startNewBook()
  doAssert nlBook.open
  run(2)
  nlBook.open = false
  # a picture traced: shape layers in a group, the picture hidden
  let d = newDoc(160, 120, 0xFFFFFFFF'u32)
  for y in 30 ..< 90:
    for x in 40 ..< 120: d.layers[0].px[y * 160 + x] = 0xFF2040C0'u32
  inc d.layers[0].ver
  addDoc(d)
  run(2)
  runCommand("Image Trace...")
  doAssert itDlg
  run(3)
  itMake()
  itDlg = false
  doAssert d.current.group and d.current.name == "Image Trace"
  var traced = 0
  for L in d.layers:
    if L.isShape: inc traced
  doAssert traced >= 2
  d.undo()
  doAssert d.layers.len == 1, "one step"
  # type made shapes: one layer a color, the type layer gone, one step
  let T = d.addTextLayer(newText("Shape", CharStyle(family: "", size: 40, color: 0xFFC02020'u32, hScale: 1,
                                 vScale: 1), 10, 60))
  T.opacity = 70
  d.cur = d.layers.find(T)
  runCommand("Convert to Shape")
  doAssert d.current.isShape and d.current.opacity == 70 and d.current.name == "Shape"
  for L in d.layers: doAssert not L.isText
  d.undo()
  doAssert d.current.isText
  # a blend between two shapes, in a group with them
  let A = d.addShapeLayer(ShapeData(path: rectPath(5, 5, 25, 25), fill: solidPaint(0xFFFF0000'u32)), "A")
  let B = d.addShapeLayer(ShapeData(path: ellipsePath(120, 80, 150, 110), fill: solidPaint(0xFF0000FF'u32)), "B")
  d.cur = d.layers.find(B)
  blendSpacing = 1
  blendSteps = 4
  runCommand("Make Blend...")
  doAssert blendDlg and blendPair[0] == A and blendPair[1] == B
  run(2)
  makeBlend()
  blendDlg = false
  doAssert d.current.group and d.current.name == "Blend"
  var steps = 0
  for L in d.layers:
    if L.isShape and L.name.startsWith("Blend "): inc steps
  doAssert steps == 4
  # Smooth Color: as many as the colors need
  d.undo()
  blendSpacing = 0
  runCommand("Make Blend...")
  makeBlend()
  blendDlg = false
  steps = 0
  for L in d.layers:
    if L.isShape and L.name.startsWith("Blend "): inc steps
  doAssert steps == colorSteps(A.shape, B.shape) and steps > 10
  # one shape alone: nothing to blend with
  let lone = newDoc(50, 50, 0xFFFFFFFF'u32)
  discard lone.addShapeLayer(ShapeData(path: rectPath(5, 5, 25, 25), fill: solidPaint(0xFFFF0000'u32)))
  addDoc(lone)
  runCommand("Make Blend...")
  doAssert not blendDlg
  doAssert docs.len >= n0

block dropCapAndGridInABook:
  var s = bookSetup(100, 140, dpi = 72, facing = false)
  s.baseline = 12
  addBook(newBook(s, 1, "Grid Book"))
  run(3)
  let d = active.doc
  doAssert bookGrid(active).step == 12
  let (xs, ys) = bookSnapLines(active)
  doAssert xs.len >= 2 and ys.len > 10
  # a box drawn snaps to a margin
  snapOn = true
  snapGuides = true
  tool = tShape
  let ev = snapped(active, PhotoEvent(x: float(s.inside) + 2, y: 50.3))
  doAssert ev.x == float(s.inside), $ev.x
  var t = curBook().book.boxed(newText("Lines of a book on its grid, long enough to make several of them here.",
                               CharStyle(family: "", size: 10, color: 0xFF000000'u32, hScale: 1, vScale: 1), 0, 0), 0)
  let L = d.addTextLayer(t)
  d.cur = d.layers.find(L)
  showBaseline = true
  run(2)
  showBaseline = false
  doAssert L.text.gridStep == 0
  # the Paragraph palette's settings, as its controls set them
  applyText("Align to Baseline Grid", proc (t: var TextData) = (t.gridStep = 12; t.gridStart = float32(s.top)))
  applyText("Drop Cap", proc (t: var TextData) = t.para.dropLines = 3)
  doAssert L.text.gridStep == 12 and L.text.para.dropLines == 3
  var big = false
  for g in layoutText(L.text).glyphs:
    if g.size > 25: big = true
  doAssert big

block tablesChartsMapsFramesExport:
  # Insert Table (Tab to the next cell, a new row after the last), Table Options; a chart and a
  # map inserted, then changed from their dialog; a picture in a shape fitted; Export of a book
  let d = newDoc(800, 600, 0xFFFFFFFF'u32)
  addDoc(d)
  run(2)
  tblIns = (true, 3, 2, 1, 1)
  run(2)
  setUiLanguage("ar", @toolkitArabic, @photoArabic)
  run(2)
  setUiLanguage("")
  tblIns.open = false
  insertTableNow()
  let T = d.current
  doAssert T.isText and T.text.table.on and T.text.table.theme == tableThemes[1]
  doAssert T.text.plainText.count('\n') == 2 and T.text.plainText.count('\t') == 3
  runCommand("Table Options...")
  doAssert tblDlg
  run(3)
  applyText("Table Options", proc (t: var TextData) = t.table.headerRows = 2)
  doAssert T.text.table.headerRows == 2
  tblDlg = false
  # typing: Tab goes from cell to cell, after the last a new row
  run(2)
  let tb = d.layerBox(T)
  tool = tMove
  moveKind = 0
  pressOn(active, PhotoEvent(over: true, x: float(tb.x + 10), y: float(tb.y + 10), pressed: true, down: true,
                             clicks: 2))
  doAssert te.on and te.layer == T, "editing the table"
  te.caret = 0
  te.anchor = 0
  let n0 = T.text.plainText.count('\n')
  for _ in 0 ..< 6: key(KeyTab)
  run(2)
  doAssert T.text.plainText.count('\n') == n0 + 1, "a new row after the last cell"
  commitType()
  # a chart: its group of shape and type layers, its settings kept; changed from its dialog
  startInfographic(false)
  doAssert igDlg.open and not igDlg.isMap
  run(3)
  igDlg.open = false
  igMake()
  let C = d.current
  doAssert C.group and C.name == "Chart" and C.meta.startsWith("{\"chart\"")
  let before = d.layers.len
  startInfographic(false, edit = true)
  doAssert igDlg.editing == C
  igDlg.chart.kind = ckDonut
  igDlg.chart.title = "Share"
  run(2)
  igDlg.open = false
  igMake()
  doAssert d.current.group and d.current.meta.contains("Donut") and d.layers.len < before + 5
  d.undo()
  doAssert d.layers.find(C) >= 0, "undo: the chart as it was"
  # a map
  startInfographic(true)
  run(3)
  igDlg.open = false
  igMake()
  doAssert d.current.name == "Map" and d.current.meta.startsWith("{\"map\"")
  # a picture in a shape: fitted, filled, centered; Frame Options and its Cancel
  let F = d.addShapeLayer(ShapeData(path: ellipsePath(100, 100, 300, 260), fill: solidPaint(0xFFCCCCCC'u32)), "Frame")
  let P = d.newLayer("Photo")
  var src = newSeq[uint32](400 * 100)
  for p in src.mitems: p = 0xFF2040C0'u32
  P.smart = SmartData(src: src, w: 400, h: 100, quad: [(0.0, 0.0), (400.0, 0.0), (400.0, 100.0), (0.0, 100.0)])
  d.cur = d.layers.find(F)
  d.insertLayer(P)
  P.clipped = true
  d.renderSmartLayer(P)
  d.cur = d.layers.find(P)
  doAssert frameAndContent(d).frame == F
  runCommand("Fill Frame Proportionally")
  doAssert abs(P.smart.quad[2][1] - P.smart.quad[0][1] - 160) < 0.5, "as tall as the frame"
  runCommand("Fit Content Proportionally")
  doAssert abs(P.smart.quad[1][0] - P.smart.quad[0][0] - 200) < 0.5, "as wide as the frame"
  let q = P.smart.quad
  runCommand("Frame Options...")
  doAssert frDlg.open
  frDlg.scale = 150
  run(2)
  doAssert P.smart.quad != q
  frDlg.open = false
  run(2)
  doAssert P.smart.quad == q, "Cancel: as it was"
  # a book exported as spreads through its dialog's settings
  addBook(newBook(bookSetup(100, 140, dpi = 72, facing = true), 4, "Export Book"))
  run(3)
  startBookExport(exPng)
  doAssert exDlg.open and exDlg.e.kind == exPng
  exDlg.e.spreads = true
  run(3)
  setUiLanguage("ar", @toolkitArabic, @photoArabic)
  for sec in 0 ..< exSections.len:
    exDlg.e.kind = exPdf
    exDlg.section = sec
    run(1)
  setUiLanguage("")
  exDlg.open = false
  let files = curBook().book.exportBook(home / "eb.png", BookExport(kind: exPng, spreads: true))
  doAssert files.len == 3 and files[1].endsWith("eb-2-3.png")
  # the Character palette's fonts for Arabic and Latin
  let A = d.addTextLayer(newText("Hello مرحبا", CharStyle(family: "", size: 30, color: 0xFF000000'u32, hScale: 1,
                                 vScale: 1), 10, 400))
  discard A

block shapesAndQuickDesign:
  # More Shapes: a live shape, its Shape Options live, Cancel puts it back; Resize for; a photo
  # grid; text effects; Recolor Design; the Brand Kit's fonts
  let d = newDoc(600, 400, 0xFFFFFFFF'u32)
  addDoc(d)
  run(2)
  runCommand("More Shapes...")
  run(3)
  msDlg = false
  insertLiveShape(lsStar)
  let S = d.current
  doAssert S.isShape and liveOf(S).ok and liveOf(S).p.kind == lsStar
  let pts0 = S.shape.path.subs[0].pts.len
  runCommand("Shape Options...")
  doAssert lsOpt
  run(2)
  lsOpt = false
  run(2)
  doAssert S.shape.path.subs[0].pts.len == pts0
  # its points changed through the kit's redraw, after the layer was moved: it stays where it went
  d.shiftLayers(@[S], 40, 10)
  var p = liveOf(S).p
  p.v[0] = 8
  d.redrawLive(S, p)
  doAssert S.shape.path.subs[0].pts.len == 16
  let (bx0, _, _, _) = pathBounds(S.shape.path)
  doAssert bx0 > d.w.float * 0.3, "drawn where it was moved to"
  # Resize for: two sizes, two documents
  let n0 = docs.len
  rsDlg.open = true
  rsDlg.picks = newSeq[bool](resizeTargets.len)
  rsDlg.picks[0] = true
  rsDlg.picks[2] = true
  run(2)
  let made = resizedCopy(d, 1080, 1920, false)
  doAssert made.w == 1080 and made.h == 1920 and made.layers.len == d.layers.len
  rsDlg.open = false
  doAssert docs.len == n0
  # a photo grid of five frames, in a group
  active = docs[n0 - 1]
  gridDlg.layout = 7
  makePhotoGrid()
  doAssert d.current.group and d.current.name == "Photo Grid"
  doAssert gridCells(2, rect(0, 0, 210, 210), 10).len == 4 and gridCells(4, rect(0, 0, 300, 200), 10).len == 3
  # text effects and a palette
  let T = d.addTextLayer(newText("Look", CharStyle(family: "", size: 40, color: 0xFF000000'u32, hScale: 1,
                                 vScale: 1), 20, 300))
  d.cur = d.layers.find(T)
  applyTextLook("Neon")
  doAssert T.fx.fx[fxOuterGlow].on
  applyTextLook("Hollow")
  doAssert T.fill == 0 and T.fx.fx[fxStroke].on
  applyTextLook("Curve")
  doAssert T.text.warp.style == wsArc
  recolorDlg.open = true
  run(2)
  recolorDlg.open = false
  d.recolor(palettes[0][1], "Sea")
  doAssert S.shape.fill.color in palettes[0][1] or (S.shape.fill.color or 0xFF000000'u32) in palettes[0][1]
  brand = BrandKit(colors: @[0xFFFF0000'u32], heading: "FreeSerif", body: "FreeMono")
  brandLoaded = true
  d.applyBrandFonts()
  doAssert T.text.spans[0].style.family == "FreeSerif"
  brandDlg = true
  fxDlg = true
  run(2)
  brandDlg = false
  fxDlg = false

block builderFreeformCheckCommands:
  # Shape Builder from its dialog's picks; a freeform gradient; Check Document; the one list of
  # commands the menus, Search, scripts and the command line share
  let d = newDoc(400, 300, 0xFFFFFFFF'u32)
  addDoc(d)
  let A = d.addShapeLayer(ShapeData(path: rectPath(20, 20, 160, 160), fill: solidPaint(0xFFFF0000'u32)), "A")
  let B = d.addShapeLayer(ShapeData(path: rectPath(100, 100, 240, 240), fill: solidPaint(0xFF0000FF'u32)), "B")
  A.picked = true
  B.picked = true
  runCommand("Shape Builder...")
  doAssert sbDlg.open and sbDlg.layers.len == 2
  run(3)
  sbDlg.merge = @[(130.0, 130.0), (50.0, 50.0)]
  run(2)
  sbDlg.open = false
  shapeBuilderNow()
  doAssert d.current.name == "Built Shape" and d.layers.find(A) < 0, "A all merged: gone"
  doAssert d.layers.find(B) >= 0
  d.undo()
  doAssert d.layers.find(A) >= 0
  # a freeform gradient on B, its points from the dialog; Cancel puts it back
  d.cur = d.layers.find(B)
  runCommand("Freeform Gradient...")
  doAssert ffDlg.open and ffDlg.pts.len == 3
  run(2)
  ffDlg.pts.add (0.9, 0.9, 0xFF00FF00'u32)
  run(2)
  doAssert B.shape.fill.style == 5 and B.shape.fill.points.len == 4
  ffDlg.open = false
  run(2)
  doAssert B.shape.fill.kind == spColor, "Cancel: as it was"
  # Check Document
  runCommand("Check Document...")
  doAssert pfDlg.open
  run(2)
  pfDlg.open = false
  # the commands
  var cmds: seq[string]
  for (path, label, cmd) in searchIndex(): cmds.add cmd
  for c in ["Image Trace...", "Make Blend...", "Shape Builder...", "Insert Table...", "Insert Chart...",
            "Fill Frame Proportionally", "Check Document...", "Export Book...", "Ligatures",
            "OpenType: Discretionary Ligatures", "OpenType: Fractions"]:
    doAssert c in cmds, c

block ligaturesAndOpenType:
  # the Character panel's Ligatures and OpenType menu (Type's too), on a type layer
  let d = newDoc(400, 200, 0xFFFFFFFF'u32)
  addDoc(d)
  let T = d.addTextLayer(newText("office fi", typeStyle, 20, 80))
  d.cur = d.layers.find(T)
  let before = layoutText(T.text).glyphs.len
  doAssert T.text.spans[0].style.ligaturesOn
  runCommand("Ligatures")
  doAssert not T.text.spans[0].style.ligaturesOn, T.text.spans[0].style.features
  doAssert layoutText(T.text).glyphs.len > before, "the letters apart"
  d.undo()
  doAssert T.text.spans[0].style.ligaturesOn and layoutText(T.text).glyphs.len == before
  runCommand("OpenType: Discretionary Ligatures")
  doAssert featureOn(T.text.spans[0].style.features, "dlig")
  runCommand("OpenType: All Small Caps")
  doAssert featureOn(T.text.spans[0].style.features, "c2sc") and featureOn(T.text.spans[0].style.features, "smcp")
  # (a font without the feature: in brackets, as the layout program shows it)
  doAssert otLabel("Swash", "swsh", T.text.spans[0].style) == "[Swash]"
  doAssert otLabel("Ligatures", "liga", T.text.spans[0].style) == "Ligatures"

block tableOfContentsAndIndex:
  # Layout > Table of Contents: the headings' styles offered, picked; OK puts the list on a new
  # first page; a heading added and Update Table of Contents makes it again; Layout > Index
  let b = newBook(bookSetup(148, 210, dpi = 100, facing = false), pages = 3, name = "Lists")
  for i in 0 ..< 3:
    var t = newText("Chapter " & $(i + 1), typeStyle, 40, 60)
    t.para.styleName = "Chapter"
    discard b.doc(i).addTextLayer(t)
    var bt = b.boxed(newText("Words about Sohar and the sea.", typeStyle), i)
    bt.y += 120
    discard b.doc(i).addTextLayer(bt)
  addBook(b)
  run(3)
  runCommand("Table of Contents...")
  doAssert listDlg.open and listDlg.styles == @["Chapter"] and listDlg.picked == @[true]
  run(2)
  listOk()
  let bw = curBook()
  doAssert b.pages.len == 4 and bw.page == 0
  var tocL: Layer
  for L in bw.dw.doc.layers:
    if L.meta.startsWith("{\"toc\""): tocL = L
  doAssert tocL != nil
  doAssert "Chapter 1\t2" in tocL.text.plainText and "Chapter 3\t4" in tocL.text.plainText, tocL.text.plainText
  # a new heading on the last page; the list made again
  var t4 = newText("Epilogue", typeStyle, 40, 300)
  t4.para.styleName = "Chapter"
  discard b.doc(3).addTextLayer(t4)
  b.park([bw.page])
  runCommand("Update Table of Contents")
  doAssert "Epilogue\t4" in tocL.text.plainText, tocL.text.plainText
  # the index, at the end
  runCommand("Index...")
  doAssert listDlg.open and listDlg.index
  listDlg.words = "Sohar\nsea\nnowhere"
  listOk()
  doAssert b.pages.len == 5 and curBook().page == 4
  var ixL: Layer
  for L in curBook().dw.doc.layers:
    if L.meta.startsWith("{\"index\""): ixL = L
  doAssert ixL != nil and "Sohar\t2, 3, 4" in ixL.text.plainText and "nowhere" notin ixL.text.plainText,
           ixL.text.plainText

block dataMergeInTheApp:
  # Layout > Data Merge: the design's fields, a table's rows; Create Merged Document makes a
  # book, a page a row, each page's text filled in
  let d = newDoc(400, 300, 0xFFFFFFFF'u32, dpi = 150)
  addDoc(d)
  discard d.addTextLayer(newText("Badge: «Name», <<Dept>>", typeStyle, 20, 80))
  runCommand("Data Merge...")
  doAssert dmDlg.open
  dmDlg.path = getTempDir() / "staff.csv"
  dmDlg.table = parseCsv("Name,Dept\nSara,Training\nAli,Quality\nMona,HR")
  run(3)
  doAssert dmDlg.preview != nil, "a row shown as it will be"
  let before = docs.len
  dmDlg.open = false
  mergeNow()
  doAssert docs.len == before + 1
  let b = curBook().book
  doAssert b.pages.len == 3
  var texts: seq[string]
  for i in 0 ..< 3:
    for L in b.doc(i).layers:
      if L.isText: texts.add L.text.plainText
  doAssert texts == @["Badge: Sara, Training", "Badge: Ali, Quality", "Badge: Mona, HR"], $texts
  doAssert b.doc(0).w == 400 and b.doc(0).h == 300, "the design's size"

block findChangeAndStoryEditor:
  # Edit > Find/Change: the next found selected where it is (typing in it), changed one by one,
  # then all of them on the page in one step; Type > Story Editor
  let d = newDoc(500, 300, 0xFFFFFFFF'u32)
  addDoc(d)
  let A = d.addTextLayer(newText("A cat and another cat.", typeStyle, 20, 60))
  let B = d.addTextLayer(newText("The cat on page one.", typeStyle, 20, 160))
  d.cur = d.layers.find(A)
  runCommand("Find/Change...")
  doAssert fcDlg.open
  fcDlg.what = "cat"
  fcDlg.change = "dog"
  fcDlg.scope = 1
  fcNext()
  doAssert te.on and te.layer == A and min(te.anchor, te.caret) == 2 and max(te.anchor, te.caret) == 5
  fcChangeOne()
  doAssert A.text.plainText == "A dog and another cat."
  doAssert te.on and te.layer == A and min(te.anchor, te.caret) == 18, "the next one selected"
  commitType()
  fcChangeAll()
  doAssert A.text.plainText == "A dog and another dog." and B.text.plainText == "The dog on page one."
  doAssert fcDlg.note == "2 changes", fcDlg.note
  d.undo()
  doAssert B.text.plainText == "The cat on page one.", "one step"
  # patterns
  fcDlg.patterns = true
  fcDlg.what = r"(\w+) one"
  fcDlg.change = "$1 two"
  fcChangeAll()
  doAssert B.text.plainText == "The cat on page two.", B.text.plainText
  fcDlg.open = false
  # the story editor
  d.cur = d.layers.find(B)
  runCommand("Story Editor...")
  doAssert seDlg.open and seDlg.words == "The cat on page two."
  seDlg.words = "The black cat on page two."
  seDlg.open = false
  var t = B.text
  t.editPlain(seDlg.words)
  d.setText(B, t)
  doAssert B.text.plainText == "The black cat on page two."

block gradientMeshAndAnchors:
  # Path Operations > Gradient Mesh: a grid on the shape, a point moved and colored, live;
  # closed from outside: as Cancel. Layer > Anchor to Text: the shape follows its line
  let d = newDoc(500, 400, 0xFFFFFFFF'u32)
  addDoc(d)
  let S = d.addShapeLayer(ShapeData(path: rectPath(300, 40, 460, 200), fill: solidPaint(0xFF2040A0'u32)), "Mesh")
  runCommand("Gradient Mesh...")
  doAssert gmDlg.open and gmDlg.pts.len == 9
  run(2)
  doAssert S.shape.fill.style == 6, "on the shape while the box is open"
  gmDlg.pts[4] = (0.7, 0.3, 0xFFFF0000'u32)
  run(2)
  doAssert S.shape.fill.points[4] == (0.7, 0.3, 0xFFFF0000'u32)
  gmDlg.open = false
  run(2)
  doAssert S.shape.fill.kind == spColor, "Cancel: as it was"
  # anchored to the text nearest it
  var t = newText("One line here.\nThe line it goes with.\nThe last.", typeStyle, 20, 40)
  t.boxW = 260
  t.boxH = 300
  let T = d.addTextLayer(t)
  d.cur = d.layers.find(S)
  runCommand("Anchor to Text")
  doAssert S.anchorTo == T.uid and T.text.anchorMarks.len == 1
  let y0 = d.anchorOrigin(S).y
  var t2 = T.text
  t2.insertText(0, "A new line.\n", typeStyle)
  d.setText(T, t2)
  doAssert d.anchorOrigin(S).y > y0, "down with its line"
  d.cur = d.layers.find(S)
  runCommand("Release Anchor")
  doAssert S.anchorTo == 0 and T.text.anchorMarks.len == 0

block footnotesInTheApp:
  # Type > Insert Footnote at the caret while typing: the number there, the Footnotes box for
  # its text; OK keeps it, drawn at the foot of the box; Cancel takes a change back; a note whose
  # number is deleted goes when the typing ends
  let d = newDoc(500, 400, 0xFFFFFFFF'u32)
  addDoc(d)
  var t = newText("A point to note, and more.", typeStyle, 20, 20)
  t.spans[0].style.size = 18
  t.boxW = 400
  t.boxH = 340
  let T = d.addTextLayer(t)
  d.cur = d.layers.find(T)
  startTypeEdit(active, T, false, 11)
  runCommand("Insert Footnote")
  doAssert T.text.notes.len == 1 and T.text.noteMarks[0].at == 11
  doAssert fnDlg.open and not te.on, "the box open, the typing done"
  run(2)
  fnDlg.layer.text.notes[0].text = "unused"           # (the box edits its own copy each frame)
  var tt = T.text
  tt.notes[0].text = "The note's own words."
  d.setText(T, tt)
  fnApplied = ""
  run(2)
  fnDlg.open = false
  fnPending = false
  if d.stepOpen: d.endStep()
  doAssert T.text.notes[0].text == "The note's own words."
  var low = 0
  for y in 300 ..< 360:
    for x in 20 ..< 420:
      if (T.px[y * d.w + x] shr 24) > 0: inc low
  doAssert low > 100, "the note drawn at the foot of the box"
  # Cancel: the numbers' style put back
  runCommand("Footnotes...")
  doAssert fnDlg.open
  var t2 = T.text
  t2.noteOpts.numbers = nsArabicIndic
  d.setText(T, t2)
  run(2)
  fnDlg.open = false
  run(2)
  doAssert T.text.noteOpts.numbers == nsDigits, "Cancel: as it was"
  # its number deleted while typing: the note goes with it
  startTypeEdit(active, T, false, 12)
  editText(proc (t: var TextData) = t.deleteText(11, 12))
  commitType()
  doAssert T.text.notes.len == 0
  # an endnote on a text without notes: the text's notes are endnotes
  runCommand("Insert Endnote")
  doAssert T.text.noteOpts.kind == nkEndnotes and T.text.notes.len == 1
  fnDlg.open = false
  run(2)


block perspectiveGridInTheApp:
  # View > Perspective Grid: shown, kept with the document; a rectangle drawn with the active
  # plane lies on it (the corners dragged stay); No Active Plane: flat; a handle dragged moves
  # the horizon; Attach to Active Plane lays a shape on the plane; the Define Grid box is live
  let d = newDoc(600, 400, 0xFFFFFFFF'u32)
  addDoc(d)
  run(2)
  runCommand("Show Perspective Grid")
  doAssert d.pgOf.shown and d.perspective.len > 0
  run(2)
  runCommand("Perspective Plane: Left Wall")
  let g = d.pgOf
  let p = vpPlane(g.planeQuad(ppLeft))
  let (x0, y0) = p.toImage(0.3, 0.3)
  let (x1, y1) = p.toImage(0.7, 0.7)
  tool = tShape
  shapeKind = 0
  shapeMode = 0
  shapeOp = 0
  let n0 = d.layers.len
  pressOn(active, PhotoEvent(over: true, x: x0, y: y0, down: true, pressed: true))
  dragOn(PhotoEvent(over: true, x: x1, y: y1, down: true))
  releaseOn(PhotoEvent(over: true, x: x1, y: y1))
  doAssert d.layers.len == n0 + 1 and d.current.isShape
  let a = d.current.shape.path.subs[0].pts
  doAssert abs(a[0].p[0] - x0) < 1e-6 and abs(a[2].p[1] - y1) < 1e-6, "the corners dragged stay"
  doAssert abs(a[3].p[1] - a[0].p[1]) < abs(a[2].p[1] - a[1].p[1]) - 1, "its far side shorter"
  # no active plane: flat
  runCommand("Perspective Plane: None")
  pressOn(active, PhotoEvent(over: true, x: 20, y: 300, down: true, pressed: true))
  dragOn(PhotoEvent(over: true, x: 80, y: 360, down: true))
  releaseOn(PhotoEvent(over: true, x: 80, y: 360))
  let b = d.current.shape.path.subs[0].pts
  doAssert b[0].p[1] == b[1].p[1] and b[2].p[1] == b[3].p[1], "flat"
  # the horizon's handle dragged down
  runCommand("Perspective Plane: Left Wall")
  let h0 = d.pgOf.horizon
  let (hx, hy) = active.view.toScreen(d, d.pgOf.nearX, h0)
  ui.mx = hx
  ui.my = hy
  doAssert active.canvasExtras(PhotoEvent(over: true, x: d.pgOf.nearX, y: h0, pressed: true, down: true))
  discard active.canvasExtras(PhotoEvent(over: true, x: d.pgOf.nearX, y: h0 + 30, down: true, released: true))
  doAssert abs(d.pgOf.horizon - (h0 + 30)) < 1e-6 and not pgDrag.on
  # Attach to Active Plane: the flat shape on the floor
  runCommand("Perspective Plane: Floor")
  let f = vpPlane(d.pgOf.planeQuad(ppFloor))
  let (fcx, fcy) = f.toImage(0.5, 0.5)
  let (fx0, fy0, fx1, fy1) = (fcx - 30, fcy - 15, fcx + 30, fcy + 15)
  let F = d.addShapeLayer(ShapeData(path: rectPath(fx0, fy0, fx1, fy1), fill: solidPaint(0xFF20A040'u32)), "Tile")
  d.cur = d.layers.find(F)
  runCommand("Attach to Active Plane")
  let c = F.shape.path.subs[0].pts
  doAssert abs(c[1].p[0] - fx1) > 0.5 or abs(c[1].p[1] - fy0) > 0.5, "bent onto the floor"
  d.undo()
  doAssert F.shape.path.subs[0].pts[1].p == (fx1, fy0)
  # kept with the document
  let saved = home / "persp.rpd"
  d.saveRpd(saved)
  let e = loadRpd(saved)
  doAssert e.perspective == d.perspective and gridFrom(e.perspective, e.w, e.h).shown
  # Define Grid: live; Cancel puts it back
  let before = d.perspective
  runCommand("Define Perspective Grid...")
  doAssert pgDlg.open
  pgDlg.kind = 0
  run(2)
  doAssert d.pgOf.kind == pkOnePoint
  pgDlg.open = false
  run(2)
  doAssert d.perspective == before, "Cancel: as it was"
  runCommand("Hide Perspective Grid")
  doAssert not d.pgOf.shown
block threadingWithThePorts:
  # the out port clicked loads the text; a box clicked takes it; the out port again and the next
  # box: the thread broken; a click where there is no box makes one that takes it; a double-click
  # on an in port breaks the thread; Esc lets loaded text go
  let d = newDoc(700, 500, 0xFFFFFFFF'u32)
  addDoc(d)
  run(2)
  var t = newText(("Words that go on and on. ").repeat(40), typeStyle, 20, 20)
  t.boxW = 200
  t.boxH = 140
  let S = d.addTextLayer(t)
  var mt = newText("", typeStyle, 260, 20)
  mt.boxW = 200
  mt.boxH = 140
  let M = d.addTextLayer(mt)
  d.cur = d.layers.find(S)
  tool = tMove
  te.on = false
  proc pressAt(sx, sy: int; x, y: float; clicks = 1): bool =
    ui.mx = sx
    ui.my = sy
    result = active.canvasExtras(PhotoEvent(over: true, x: x, y: y, pressed: true, down: true, clicks: clicks))
  proc screenOf(x, y: float): (int, int) = active.view.toScreen(d, x, y)
  proc center(r: Rect): (int, int) = (r.x + r.w div 2, r.y + r.h div 2)
  let (ox, oy) = center(active.outPort(S))
  doAssert pressAt(ox, oy, 0, 0) and tl.loaded and tl.mode == 0
  let (mx, my) = screenOf(300, 60)
  doAssert pressAt(mx, my, 300, 60)
  doAssert not tl.loaded and M.flowFrom == S.uid, status
  doAssert d.effectiveText(M).plainText.len > 0
  # the out port again: breaking mode; the next box clicked: broken
  doAssert pressAt(ox, oy, 0, 0) and tl.mode == 1
  doAssert pressAt(mx, my, 300, 60)
  doAssert M.flowFrom == 0 and d.effectiveText(M).plainText.len == 0
  # a new box where there is none (a click: as big as the box it comes from)
  let n0 = d.layers.len
  doAssert pressAt(ox, oy, 0, 0) and tl.loaded
  let (ex, ey) = screenOf(480, 260)
  doAssert pressAt(ex, ey, 480, 260) and tl.pressing
  discard active.canvasExtras(PhotoEvent(over: true, x: 480, y: 260, released: true))
  doAssert d.layers.len == n0 + 1
  let N = d.followerOf(S)
  doAssert N != nil and N != M and N.text.boxW == S.text.boxW and N.text.x == 480, $(N != nil)
  # undo takes the new box away
  d.undo()
  doAssert d.layers.len == n0
  d.redo()
  # a double-click on its in port: broken
  let N2 = d.followerOf(S)
  d.cur = d.layers.find(N2)
  let (ix, iy) = center(active.inPort(N2))
  doAssert pressAt(ix, iy, 0, 0, clicks = 2)
  doAssert N2.flowFrom == 0
  # Esc: the loaded text let go
  d.cur = d.layers.find(S)
  doAssert pressAt(ox, oy, 0, 0) and tl.loaded
  doAssert threadEscape() and not tl.loaded
  # drawn: the ports, the thread's line (nothing to fail)
  doAssert d.threadText(S, M)
  run(2)

block textFrameOptionsAndAutoSize:
  # Type > Text Frame Options: Auto-Size live, OK keeps it, Cancel takes it back; a title of the
  # Arabic Book's template follows a size changed
  let d = newDoc(600, 400, 0xFFFFFFFF'u32)
  addDoc(d)
  var t = newText("A heading", typeStyle, 20, 20)
  t.spans[0].style.size = 40
  t.boxW = 400
  t.boxH = 20
  let L = d.addTextLayer(t)
  d.cur = d.layers.find(L)
  runCommand("Text Frame Options...")
  doAssert tfDlg.open
  tfDlg.auto = ord(asHeight)
  run(2)
  doAssert L.text.autoSize == asHeight and L.text.boxH > 40, $L.text.boxH
  tfDlg.open = false
  run(2)
  doAssert L.text.autoSize == asOff and L.text.boxH == 20, "Cancel: as it was"
  runCommand("Text Frame Options...")
  tfDlg.auto = ord(asHeight)
  tfDlg.cols = 1
  run(2)
  tfPending = false
  tfDlg.open = false
  if d.stepOpen: d.endStep()
  doAssert L.text.autoSize == asHeight
  # a bigger size: the box grows with it
  let h0 = L.text.boxH
  var t2 = L.text
  t2.spans[0].style.size = 70
  d.setText(L, t2)
  doAssert L.text.boxH > h0 * 1.4, $(L.text.boxH, h0)
  # the template's chapter heading
  var tmpl: BookTemplate
  for bt in bookTemplates():
    if bt.name == "Arabic Book": tmpl = bt
  let b = tmpl.build()
  let pd = b.doc(1)
  var H: Layer
  for X in pd.layers:
    if X.isText and X.text.plainText == "الفصل الأول": H = X
  doAssert H != nil and H.text.autoSize == asHeight
  var ht = H.text
  for sp in ht.spans.mitems: sp.style.size = 60
  pd.setText(H, ht)
  doAssert layoutText(pd.effectiveText(H)).overflow < 0, "the heading fits its box"
  doAssert H.text.boxH >= 60
  b.close()

block brushesAlongAPath:
  # Layer > Path Operations > Apply Brush to Path: a new layer of the brush's outlines over the
  # path's own (hidden), live as the brush changes; OK keeps it, Cancel takes it all back
  let d = newDoc(500, 300, 0xFFFFFFFF'u32)
  addDoc(d)
  let S = d.addShapeLayer(ShapeData(path: ellipsePath(50, 50, 450, 250), stroke: solidPaint(0xFF803020'u32),
                                    strokeWidth: 4, fill: ShapePaint(kind: spNone)), "Ring")
  d.cur = d.layers.find(S)
  let n0 = d.layers.len
  runCommand("Apply Brush to Path...")
  doAssert pbDlg.open
  run(2)
  doAssert d.layers.len == n0 + 1 and not S.visible
  let M = pbDlg.made
  doAssert M.shape.fill.color == 0xFF803020'u32 and M.shape.path.subs.len == 1, "Taper: one outline"
  pbDlg.brush = BuiltinBrushes.find("Dots")
  run(2)
  doAssert pbDlg.kind == ord(pbScatter) and M.shape.path.subs.len > 10
  let (bx0, by0, bx1, by1) = pathBounds(M.shape.path)
  doAssert bx0 > 30 and bx1 < 470 and by0 > 30 and by1 < 270 and bx1 - bx0 > 380, "along the ring, not along the brushed outline"
  pbDlg.open = false
  run(2)
  doAssert d.layers.len == n0 and S.visible, "Cancel: as it was"
  # OK
  runCommand("Apply Brush to Path...")
  pbDlg.brush = BuiltinBrushes.find("Chain")
  run(2)
  pbPending = false
  pbDlg.open = false
  if d.stepOpen: d.endStep()
  doAssert d.layers.len == n0 + 1 and pbDlg.made.shape.path.subs.len > 10

block tabsPanel:
  # the Tabs panel: a click on its ruler puts a stop there (a right one, picked first), a drag
  # moves it, off the ruler takes it away -- each the text's own at once, one step a drag;
  # Shift+Tab typed: a Right Indent Tab
  let d = newDoc(600, 300, 0xFFFFFFFF'u32)
  addDoc(d)
  run(2)
  var ts = typeStyle
  ts.size = 16
  var t = newText("Chapter\t12", ts, 20, 20)
  t.boxW = 400
  t.boxH = 100
  var L: Layer
  d.layersChange("Type"): L = d.addTextLayer(t)
  d.cur = d.layers.find(L)
  showPanel("tabs")
  run(3)
  let r = tabsUi.ruler
  doAssert r.w > 50, "the ruler drawn: " & $r
  tabsUi.kind = tabRight
  let x = r.x + dp(6) + (r.w - dp(12)) div 2                       # (the middle: 200 pixels in)
  down(x, r.y + r.h div 2)
  run()
  up(x, r.y + r.h div 2)
  run(2)
  doAssert L.text.para.tabs.len == 1 and L.text.para.tabs[0].align == tabRight and
           abs(L.text.para.tabs[0].pos - 200) < 3, $L.text.para.tabs
  let lay = layoutText(d.effectiveText(L))
  doAssert abs(lay.lines[0].x1 - 220) < 3, "the number ends at it: " & $lay.lines[0].x1
  # dragged further: moved, one step
  let steps = d.stepsMade
  down(x, r.y + r.h div 2)
  run()
  move(x + (r.w - dp(12)) div 4, r.y + r.h div 2)
  run()
  move(x + (r.w - dp(12)) div 4, r.y + r.h div 2)
  run()
  up(x + (r.w - dp(12)) div 4, r.y + r.h div 2)
  run(2)
  doAssert L.text.para.tabs.len == 1 and abs(L.text.para.tabs[0].pos - 300) < 3, $L.text.para.tabs
  doAssert d.stepsMade == steps + 1, "a drag, one step: " & $(d.stepsMade - steps)
  # off the ruler: gone
  let x2 = x + (r.w - dp(12)) div 4
  down(x2, r.y + r.h div 2)
  run()
  move(x2, r.y + r.h + dp(40))
  run()
  up(x2, r.y + r.h + dp(40))
  run(2)
  doAssert L.text.para.tabs.len == 0, "taken away"
  togglePanel("tabs")
  active.win.open = false
  run(3)

block picturesIntoFrames:
  # File > Place with a photo placeholder picked: the picture inside it, covering it, clipped;
  # placed again: in the first one's place. Layer > Put Inside; Edit > Paste Into a frame.
  let d = newDoc(400, 300, 0xFFFFFFFF'u32)
  addDoc(d)
  run(2)
  var F: Layer
  d.layersChange("Frame"):
    F = d.addShapeLayer(ShapeData(path: rectPath(100, 50, 300, 250), fill: solidPaint(0xFFC8C8C8'u32),
                                  kind: "Rectangle"), "Frame")
    F.attrs.placeholder = 1
  let pic = home / "pic.png"
  var bm = newBitmap(80, 40)
  for k in 0 ..< bm.px.len: bm.px[k] = 0xFF3080C0'u32
  discard bm.savePng(pic)
  d.cur = d.layers.find(F)
  placeSmart(d, pic)
  var at = d.layers.find(F)
  doAssert d.layers[at + 1].isSmart and d.layers[at + 1].clipped, "inside it"
  let b = d.layerBox(d.layers[at + 1])
  doAssert b.w >= 200 and b.h >= 200, "covering it: " & $b
  run(2)
  d.cur = d.layers.find(F)
  let n = d.layers.len
  placeSmart(d, pic)
  doAssert d.layers.len == n, "in the first one's place"
  # fitting it whole, as a placeholder of that kind says
  F.attrs.placeholder = 2
  d.cur = d.layers.find(F)
  placeSmart(d, pic)
  at = d.layers.find(F)
  let fb = d.layerBox(d.layers[at + 1])
  doAssert fb.w <= 201 and fb.h < 150, "fitting it: " & $fb
  # Layer > Put Inside: the picked layers into the frame picked last
  var D: Layer
  d.layersChange("Dot"):
    D = d.addShapeLayer(ShapeData(path: ellipsePath(20, 20, 60, 60), fill: solidPaint(0xFF000000'u32),
                                  kind: "Ellipse"), "Dot")
  d.clearPicks()
  D.picked = true
  F.picked = true
  d.cur = d.layers.find(F)
  runCommand("Put Inside")
  doAssert D.clipped and d.layers.find(D) > d.layers.find(F), "inside the frame"
  runCommand("Undo")
  doAssert not D.clipped, "one step"
  # Edit > Paste Into, nothing selected, the frame picked: over its middle, clipped to it
  d.selectAll()
  d.cur = d.layers.find(D)
  copyToClip(d, false)
  d.selectNone()
  d.cur = d.layers.find(F)
  runCommand("Paste Into")
  let P = d.current
  doAssert P.clipped and d.layers.find(P) > d.layers.find(F), "pasted inside it"
  active.win.open = false
  run(3)

echo "photo book app tests passed"
