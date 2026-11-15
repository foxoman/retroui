## Tests of books (retroui/photobook) and of what the image editor's engine
## has for them: text that keeps out of other layers (Text Wrap), page
## numbers in text, master pages, facing pages bound on either side, text
## that goes on from page to page, the book's file and its PDF. With
## PHOTO_DUMP set to a folder, pages are written there as pictures.

import std/[os, strutils]
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

echo "test_photobook: ok"
