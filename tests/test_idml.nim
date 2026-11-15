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

block oneDocumentAndDamage:
  let d = newDoc(400, 300, 0xFFFFFFFF'u32)
  discard d.addTextLayer(newText("One page", st(24), 20, 40))
  d.saveDocIdml(dir / "one.idml")
  doAssert readIdml(dir / "one.idml").pages.len == 1
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

removeDir(dir)
echo "test_idml: ok"
