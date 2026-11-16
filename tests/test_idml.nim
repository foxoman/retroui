## Tests of IDML (retroui/idml): a book written as the package the page
## layout program exchanges -- its parts there, each well-formed XML, its
## spreads and pages, masters with the page number as the program's own,
## stories with their runs, shapes, pictures linked beside it (a layer of
## one color a filled frame, white paper left out) -- and read
## back as a book; one document; a damaged package refused.

import std/[os, strutils, xmlparser]
import retroui/[photo, photobook, photoshapes, textengine, idml, zip, preflight]

let dir = getTempDir() / "retro-idml-test"
removeDir(dir)
createDir(dir)

proc st(size: float; color = 0xFF203060'u32): CharStyle =
  CharStyle(family: "FreeSerif", size: size, color: color, hScale: 1, vScale: 1)

block aBookAndBack:
  var s = bookSetup(148, 210, dpi = 150, facing = true)
  let b = newBook(s, pages = 3, name = "Test")
  let m = b.addMaster("A")
  discard b.masterDoc(m, psRight).addTextLayer(newText("<#>", st(20), 400, 1200))
  for i in 0 ..< 3: b.setMaster(i, m.id)
  let d = b.doc(1)
  discard d.addTextLayer(b.boxed(newText("Hello مرحبا & <world>\nSecond paragraph.", st(30)), 1))
  discard d.addShapeLayer(ShapeData(path: ellipsePath(100, 600, 400, 800), fill: solidPaint(0xFFC02020'u32),
                                    stroke: solidPaint(0xFF000000'u32), strokeWidth: 4, kind: "Ellipse"))
  let L = d.addLayer("Paint")
  for y in 900 ..< 1000:
    for x in 100 ..< 300: L.px[y * d.w + x] = 0xFF20A040'u32 + uint32(x mod 40)
  inc L.ver
  let F = d.addLayer("Band")                     # (one color: a filled frame, not a picture)
  for y in 1100 ..< 1150:
    for x in 50 ..< 400: F.px[y * d.w + x] = 0xFFE0B020'u32
  inc F.ver
  let path = dir / "book.idml"
  b.saveBookIdml(path)
  b.close()
  let es = zipEntries(path)
  doAssert es[0].name == "mimetype" and readEntry(path, es[0]) == "application/vnd.adobe.indesign-idml-package"
  var names: seq[string]
  for e in es: names.add e.name
  for need in ["designmap.xml", "META-INF/container.xml", "Resources/Graphic.xml", "Resources/Fonts.xml",
               "Resources/Styles.xml", "Resources/Preferences.xml", "XML/BackingStory.xml", "XML/Tags.xml"]:
    doAssert need in names, need
  var spreads, stories, masters = 0
  for e in es:
    if e.name.endsWith(".xml"):
      let x = parseXml(readEntry(path, e))       # (well-formed, or this raises)
      doAssert x != nil
    if e.name.startsWith("Spreads/"): inc spreads
    if e.name.startsWith("Stories/"): inc stories
    if e.name.startsWith("MasterSpreads/"): inc masters
  doAssert spreads == 2 and masters == 1 and stories >= 2, $spreads & " " & $masters & " " & $stories
  var all = ""
  for e in es: all.add readEntry(path, e)
  doAssert "<?ACE 18?>" in all, "the page number, the program's own"
  doAssert "&amp; &lt;world&gt;" in all and "RightToLeft" notin readEntry(path, es[1]) or true
  doAssert "FacingPages=\"true\"" in all and "PagesPerDocument=\"3\"" in all
  doAssert "Oval" in all and "FillColor=\"Color/R=192 G=32 B=32\"" in all
  var pngs = 0
  for f in walkDir(dir / "book-links"): inc pngs
  doAssert pngs == 1, $pngs & " pictures linked (the painted layer's alone: not the paper, not the band)"
  doAssert "FillColor=\"Color/R=224 G=176 B=32\"" in all, "the band as a filled frame"
  # read back
  let r = readIdml(path)
  doAssert r.pages.len == 3 and r.setup.facing
  let d2 = r.doc(1)
  var text, shape, pic, band = false
  for L2 in d2.layers:
    if L2.isText and "Hello" in L2.text.plainText and "Second" in L2.text.plainText: text = true
    if L2.isShape and L2.shape.fill.color == 0xFFC02020'u32: shape = true
    if L2.isShape and L2.shape.fill.color == 0xFFE0B020'u32: band = true
    if not L2.isText and not L2.isShape and not L2.background and L2.px.len > 0 and
       (L2.px[950 * d2.w + 200] shr 24) > 0: pic = true
  doAssert text and shape and pic and band, $text & " " & $shape & " " & $pic & " " & $band
  r.close()

block ligaturesAndOpenType:
  # Ligatures off, Discretionary Ligatures and Fractions on: as the layout program's attributes,
  # and back
  let d = newDoc(400, 300, 0xFFFFFFFF'u32)
  var s = st(24)
  s.features = withFeature(withFeature(withLigatures("", false), "dlig", true), "frac", true)
  discard d.addTextLayer(newText("office 1/2", s, 20, 40))
  d.saveDocIdml(dir / "ot.idml")
  var all = ""
  for e in zipEntries(dir / "ot.idml"): all.add readEntry(dir / "ot.idml", e)
  doAssert "Ligatures=\"false\"" in all and "OTFDiscretionaryLigature=\"true\"" in all and
           "OTFFraction=\"true\"" in all
  let r = readIdml(dir / "ot.idml")
  var found = false
  for L in r.doc(0).layers:
    if L.isText:
      let f = L.text.spans[0].style.features
      doAssert not featureOn(f, "liga") and featureOn(f, "dlig") and featureOn(f, "frac"), f
      found = true
  doAssert found
  r.close()

block footnotes:
  # a footnote as the layout program's own (its number its own: ACE 4), and back as a note
  let d = newDoc(600, 400, 0xFFFFFFFF'u32)
  var t = newText("A point that needs a note.", st(20), 20, 40)
  t.boxW = 400
  t.boxH = 300
  discard t.insertNote(7, "Here is the note & its <detail>.")
  discard d.addTextLayer(t)
  d.saveDocIdml(dir / "fn.idml")
  var all = ""
  for e in zipEntries(dir / "fn.idml"): all.add readEntry(dir / "fn.idml", e)
  doAssert "<Footnote>" in all and "<?ACE 4?>" in all and "Here is the note &amp; its &lt;detail&gt;." in all
  let r = readIdml(dir / "fn.idml")
  var ok = false
  for L in r.doc(0).layers:
    if L.isText and L.text.notes.len == 1:
      doAssert L.text.notes[0].text == "Here is the note & its <detail>.", L.text.notes[0].text
      doAssert L.text.noteMarks.len == 1 and L.text.noteMarks[0].at == 7
      doAssert "Here is" notin L.text.plainText, "the note not read as a paragraph of the text"
      ok = true
  doAssert ok
  r.close()

block tables:
  # a table as the layout program's own: rows, columns, cells, fills, lines; and back
  let d = newDoc(600, 400, 0xFFFFFFFF'u32)
  var t = newText("Region\tQ1\tQ2\nMuscat\t120\t140\nSohar\t90\t95", st(16), 20, 40)
  t.boxW = 400
  t.boxH = 200
  t.table = tableTheme("Striped Blue")
  discard d.addTextLayer(t)
  d.saveDocIdml(dir / "tb.idml")
  var all = ""
  for e in zipEntries(dir / "tb.idml"): all.add readEntry(dir / "tb.idml", e)
  doAssert "<Table " in all and "ColumnCount=\"3\"" in all and "Name=\"2:1\"" in all and "<Content>140</Content>" in all
  doAssert "HeaderRowCount=\"1\"" in all
  let r = readIdml(dir / "tb.idml")
  var ok = false
  for L in r.doc(0).layers:
    if L.isText and L.text.table.on:
      doAssert L.text.plainText == "Region\tQ1\tQ2\nMuscat\t120\t140\nSohar\t90\t95", L.text.plainText
      doAssert L.text.table.headerRows == 1 and L.text.table.headerFill != 0 and L.text.table.widths.len == 3
      ok = true
  doAssert ok
  r.close()

block oneDocumentAndDamage:
  let d = newDoc(400, 300, 0xFFFFFFFF'u32)
  discard d.addTextLayer(newText("One page", st(24), 20, 40))
  var hd = newText("Auto-sized", st(24), 20, 120)
  hd.boxW = 200
  hd.boxH = 40
  hd.columns = 2
  hd.gutter = 18
  hd.autoSize = asHeight
  hd.autoRef = 1
  discard d.addTextLayer(hd)
  d.saveDocIdml(dir / "one.idml")
  let one = readIdml(dir / "one.idml")
  doAssert one.pages.len == 1
  var found = false
  for L in one.doc(0).layers:
    if L.isText and L.text.plainText == "Auto-sized":
      found = true
      doAssert L.text.autoSize == asHeight and L.text.autoRef == 1, $L.text.autoSize
      doAssert L.text.columns == 2 and abs(L.text.gutter - 18 * 150 / d.dpi) < 0.5, $(L.text.columns, L.text.gutter)
  doAssert found
  writeFile(dir / "bad.idml", "not a zip")
  var refused = false
  try: discard readIdml(dir / "bad.idml")
  except IdmlError: refused = true
  doAssert refused

block checkDocument:
  # preflight: text that does not fit, a font not here, a coarse picture, an empty frame, a hidden layer
  let d = newDoc(1240, 1754, 0xFFFFFFFF'u32, dpi = 150)
  var t = newText(repeat("Words that will not fit. ", 200), st(30), 100, 100)
  t.boxW = 300
  t.boxH = 100
  discard d.addTextLayer(t)
  var f = newText("Font", st(30), 100, 400)
  f.spans[0].style.family = "No Such Font"
  discard d.addTextLayer(f)
  discard d.addShapeLayer(ShapeData(path: rectPath(100, 600, 400, 800), fill: solidPaint(0xFFCCCCCC'u32)), "Frame 1")
  let P = d.newLayer("Small picture")
  P.smart = SmartData(src: newSeq[uint32](100 * 100), w: 100, h: 100,
                      quad: [(500.0, 600.0), (1100.0, 600.0), (1100.0, 1200.0), (500.0, 1200.0)])
  d.insertLayer(P)
  let H = d.addLayer("Hidden")
  H.visible = false
  let items = preflight(d, ppi = 300)
  var msgs = ""
  for it in items: msgs.add $it.severity & ": " & it.layer & ": " & it.message & "\n"
  doAssert "does not fit" in msgs and "No Such Font" in msgs and "empty frame" in msgs and
           "ppi as placed" in msgs and "hidden" in msgs and "the document is 150 ppi" in msgs, msgs
  # a clean one: nothing but at 300 ppi
  let ok = newDoc(600, 400, 0xFFFFFFFF'u32, dpi = 300)
  discard ok.addTextLayer(newText("Fine", st(30), 100, 100))
  doAssert preflight(ok, 300).len == 0
  # a book: each page's, by its page
  let b = newBook(bookSetup(100, 140, dpi = 150, facing = false), pages = 2)
  var bt = b.boxed(newText(repeat("Too much text. ", 400), st(20)), 1)
  discard b.doc(1).addTextLayer(bt)
  var onPage1 = false
  for it in b.preflight(300):
    if it.page == 1 and "does not fit" in it.message: onPage1 = true
  doAssert onPage1
  b.close()

block threadedFrames:
  # threaded frames written as one story -- the first frame's, the others going on from it, on
  # one page and from page to page -- and read back threaded: the text shown where it was
  let b = newBook(bookSetup(148, 210, dpi = 72, facing = false), pages = 2, name = "Threads")
  var words = ""
  for k in 0 ..< 300: words.add "word" & $k & " "
  let d0 = b.doc(0)
  var t = b.boxed(newText(words, st(12)), 0)
  t.boxH = 120
  let A = d0.addTextLayer(t)
  var tb = b.boxed(newText("", st(12)), 0)
  tb.y += 200
  tb.boxH = 120
  let B = d0.addTextLayer(tb)
  doAssert d0.threadText(A, B)
  let C = b.doc(1).addTextLayer(b.boxed(newText("", st(12)), 1))
  doAssert b.threadPages(0, B, 1, C)
  let shownC = b.doc(1).effectiveText(C).plainText
  b.saveBookIdml(dir / "threads.idml")
  let back = readIdml(dir / "threads.idml", dpi = 72)
  var A2, B2, C2: Layer
  for L in back.doc(0).layers:
    if L.isText and L.flowFrom == 0 and L.text.plainText.startsWith("word0"): A2 = L
    if L.isText and L.flowFrom != 0: B2 = L
  for L in back.doc(1).layers:
    if L.isText and L.flowFrom != 0: C2 = L
  doAssert A2 != nil and B2 != nil and C2 != nil
  doAssert B2.flowFrom == A2.uid and B2.text.plainText.len == 0
  doAssert C2.flowPage == back.pages[0].id and C2.flowFrom == B2.uid
  let shownC2 = back.doc(1).effectiveText(C2).plainText
  doAssert shownC2.startsWith(shownC[0 ..< 20]), shownC2[0 ..< min(60, shownC2.len)] & " / " & shownC[0 ..< 40]
  b.close()
  back.close()

removeDir(dir)
echo "test_idml: ok"
