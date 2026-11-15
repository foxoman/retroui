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
  d.setWrap(P, 1, 0, 2)
  doAssert inkUnder() == 0, "the text keeps out of the picture"
  runCommand("Undo")
  doAssert P.wrap == 0 and inkUnder() > 0
  runCommand("Text Wrap...")
  doAssert wrapDlg
  run(3)                           # (the dialog is drawn)
  wrapDlg = false
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
  bookPdf = bw
  doAssert bookPdfWrite(pdf, pdfPreset(ppWeb))
  doAssert readFile(pdf).startsWith("%PDF")
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
  closeAsk.on = false
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
            "Fill Frame Proportionally", "Check Document...", "Export Book..."]:
    doAssert c in cmds, c

echo "photo book app tests passed"
