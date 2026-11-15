## Tests of Retro Photo's books as a program, run headless: a book in a
## window, pages turned, added, copied and taken out, master pages, page
## numbers typed in, text that goes on through new pages, Text Wrap, the
## book's file and PDF, the workspaces, the Move tool's box that picks
## layers.

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

echo "photo book app tests passed"
