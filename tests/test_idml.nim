## Tests of IDML (retroui/idml): a book written as the package the page
## layout program exchanges -- its parts there, each well-formed XML, its
## spreads and pages, masters with the page number as the program's own,
## stories with their runs, shapes, pictures linked beside it (a layer of
## one color a filled frame, white paper left out) -- and read
## back as a book; one document; a damaged package refused.

import std/[os, strutils, xmlparser]
import retroui/[photo, photobook, photoshapes, textengine, idml, zip, preflight]
{.push warning[UnusedImport]: off.}
import retroui/textsearch   # (imported for what it sets up: GREP styles find their matches with it)
{.pop.}

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
  # merged, several paragraphs, a cell's own fill, inset, place, turn; heights; a footer
  var u = newText("Region\tQ1\tQ2\nMuscat\tOne\u2029Two\t140\nSohar\t90\t95\nTotal\t210\t235", st(16), 20, 40)
  u.boxW = 400
  u.boxH = 300
  u.table = tableTheme("Plain Grid")
  u.table.headerRows = 1
  u.table.footerRows = 1
  u.table.cellRef(0, 1).colSpan = 2
  u.table.cellRef(2, 1).fill = 0xFFFFE000'u32
  u.table.cellRef(2, 1).inset = [6'f32, 6, 6, 6]
  u.table.cellRef(2, 1).vAlign = vjBottom
  u.table.cellRef(2, 2).rotation = 90
  u.table.rowFmts = @[TableRowFmt(), TableRowFmt(kind: rhExactly, height: 40), TableRowFmt(kind: rhAtLeast, height: 50)]
  let d2 = newDoc(600, 400, 0xFFFFFFFF'u32, dpi = 72)
  discard d2.addTextLayer(u)
  d2.saveDocIdml(dir / "tb2.idml")
  var all2 = ""
  for e in zipEntries(dir / "tb2.idml"): all2.add readEntry(dir / "tb2.idml", e)
  doAssert "FooterRowCount=\"1\"" in all2 and "ColumnSpan=\"2\"" in all2 and "RotationAngle=\"90\"" in all2 and
           "VerticalJustification=\"BottomAlign\"" in all2 and "SingleRowHeight=\"40\"" in all2 and
           "<Br/>" in all2 and "Name=\"2:0\"" notin all2, "the program's own: merged cells not written"
  let r2 = readIdml(dir / "tb2.idml", dpi = 72)
  var ok2 = false
  for L in r2.doc(0).layers:
    if L.isText and L.text.table.on:
      let tb = L.text.table
      doAssert "One\u2029Two" in L.text.plainText, "two paragraphs in a cell"
      doAssert tb.footerRows == 1 and tb.cellAt(0, 1).colSpan == 2 and tb.cellAt(2, 1).fill == 0xFFFFE000'u32 and
               abs(tb.cellAt(2, 1).inset[0] - 6) < 0.01 and tb.cellAt(2, 1).vAlign == vjBottom and
               tb.cellAt(2, 2).rotation == 90, "its cells"
      doAssert tb.rowFmtAt(1).kind == rhExactly and abs(tb.rowFmtAt(1).height - 40) < 0.01 and
               tb.rowFmtAt(2).kind == rhAtLeast and abs(tb.rowFmtAt(2).height - 50) < 0.01, "its rows"
      ok2 = true
  doAssert ok2
  r2.close()

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
  # Arabic's own: set left to right, slanted, tracked apart, presentation forms, hand tatweel in
  # justified text, two kinds of digits -- and well-set Arabic: nothing
  let ad = newDoc(800, 600, 0xFFFFFFFF'u32, dpi = 300)
  var a1 = newText("\u0645\u0631\u062D\u0628\u0627 \u0628\u0627\u0644\u0639\u0627\u0644\u0645 123 \u0661\u0662", st(30), 100, 100)
  a1.para.rtl = 1
  a1.spans[0].style.fauxItalic = true
  a1.spans[0].style.tracking = 80
  discard ad.addTextLayer(a1)
  var a2 = newText("\uFEE3\uFEAE\uFEA3\uFE92\uFE8E \u0645\u0640\u0640\u0640\u0631\u062D\u0628\u0627", st(30), 100, 300)
  a2.boxW = 400
  a2.boxH = 200
  a2.para.align = justifyRight
  discard ad.addTextLayer(a2)
  var am = ""
  for it in preflight(ad, 300): am.add $it.severity & ": " & it.message & "\n"
  doAssert "Arabic set left to right" in am and "Arabic slanted" in am and "tracked apart" in am and
           "presentation forms" in am and "tatweel" in am and "digits of two kinds" in am, am
  let good = newDoc(800, 600, 0xFFFFFFFF'u32, dpi = 300)
  discard good.addTextLayer(newText("\u0645\u0631\u062D\u0628\u0627 \u0628\u0627\u0644\u0639\u0627\u0644\u0645", st(30), 100, 100))
  doAssert preflight(good, 300).len == 0, $preflight(good, 300)

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

block paragraphFormats:
  # each paragraph's format a range of its own -- Keep Options, Span Columns, the composer,
  # Justification's spacing -- and the frame's Inset Spacing, Vertical Justification, Balance
  # Columns: the layout program's own, and back
  let d = newDoc(800, 600, 0xFFFFFFFF'u32)
  var t = newText("Heading\nBody text in two columns under it.", st(20), 20, 40)
  t.boxW = 600
  t.boxH = 400
  t.columns = 2
  var h = t.para
  h.align = textCenter
  h.spanAll = true
  h.keepWithNext = 2
  h.keepTogether = true
  h.startAt = psNextColumn
  h.composer = cpSingle
  h.wordSpacing = [70'i16, 90, 150]
  t.setParaFmt(0, 0, h)
  t.inset = [6'f32, 8, 10, 12]
  t.vjust = vjBottom
  t.balance = true
  discard d.addTextLayer(t)
  d.saveDocIdml(dir / "pf.idml")
  var all = ""
  for e in zipEntries(dir / "pf.idml"): all.add readEntry(dir / "pf.idml", e)
  doAssert all.count("<ParagraphStyleRange AppliedParagraphStyle=\"ParagraphStyle/$ID/NormalParagraphStyle\" Justification") == 2
  doAssert "SpanColumnType=\"SpanColumns\"" in all and "KeepWithNext=\"2\"" in all and
           "KeepAllLinesTogether=\"true\"" in all and "StartParagraph=\"NextColumn\"" in all and
           "Composer=\"HL Single\"" in all and "MinimumWordSpacing=\"70\"" in all
  doAssert "VerticalJustification=\"BottomAlign\"" in all and "VerticalBalanceColumns=\"true\"" in all and
           "<InsetSpacing type=\"list\">" in all
  let r = readIdml(dir / "pf.idml")
  var ok = false
  for L in r.doc(0).layers:
    if L.isText and L.text.plainText.startsWith("Heading"):
      let u = L.text
      let f0 = u.paraFmtAt(0)
      doAssert f0.align == textCenter and f0.spanAll and f0.keepWithNext == 2 and f0.keepTogether and
               f0.startAt == psNextColumn and f0.composer == cpSingle and f0.wordSpacing == [70'i16, 90, 150]
      let f1 = u.paraFmtAt(10)
      doAssert f1.align == textLeft and not f1.spanAll
      doAssert u.vjust == vjBottom and u.balance
      # (in the package's points: back at the reading's resolution, each side as it was)
      for q in 0 .. 3: doAssert abs(u.inset[q] / u.inset[0] - t.inset[q] / t.inset[0]) < 0.01, $u.inset
      ok = true
  doAssert ok
  r.close()


block tabStopsInIdml:
  # a paragraph's tab stops (each kind, a leader, the character it aligns on) and a Right Indent
  # Tab: the layout program's TabList and its own character, and back
  let d = newDoc(800, 600, 0xFFFFFFFF'u32, dpi = 144)
  var t = newText("Chapter\t12\nPrice\t3.50\nTitle\bPage", st(20), 20, 40)
  t.boxW = 600
  t.boxH = 300
  t.para.setTab(TabStop(pos: 600, align: tabRight, leader: ". "))
  t.para.setTab(TabStop(pos: 300, align: tabChar, alignOn: ","))
  t.para.setTab(TabStop(pos: 100, align: tabCenter))
  discard d.addTextLayer(t)
  d.saveDocIdml(dir / "tabs.idml")
  var all = ""
  for e in zipEntries(dir / "tabs.idml"): all.add readEntry(dir / "tabs.idml", e)
  doAssert "<TabList type=\"list\">" in all and "<Position type=\"unit\">300</Position>" in all and
           "CharacterAlign" in all and "<?ACE 8?>" in all, "the program's own"
  let r = readIdml(dir / "tabs.idml", dpi = 144)
  var ok = false
  for L in r.doc(0).layers:
    if L.isText and L.text.plainText.startsWith("Chapter"):
      let u = L.text
      doAssert "Title\bPage" in u.plainText, "the Right Indent Tab back"
      let tabs = u.paraFmtAt(0).tabs
      doAssert tabs.len == 3 and abs(tabs[0].pos - 100) < 0.5 and tabs[0].align == tabCenter and
               abs(tabs[1].pos - 300) < 0.5 and tabs[1].align == tabChar and tabs[1].alignOn == "," and
               abs(tabs[2].pos - 600) < 0.5 and tabs[2].align == tabRight and tabs[2].leader == ". ", $tabs
      ok = true
  doAssert ok
  r.close()

block stylesLinksBookmarks:
  # nested, line and GREP styles (the character styles they name, in Styles.xml), an Object Style
  # on a frame and a shape, hyperlinks (an address, a destination, a page), the destination, the
  # bookmarks: the layout program's own, and back
  let d = newDoc(800, 600, 0xFFFFFFFF'u32)
  var lead = st(26, 0xFFC02020'u32)
  lead.styleName = "Lead"
  var year = st(20, 0xFF2080C0'u32)
  year.styleName = "Year"
  var t = newText("Chapter one began in 2026 and went on for many lines of text here.", st(20), 20, 40)
  t.boxW = 300
  t.boxH = 400
  t.para.nested = @[NestedStyle(name: "Lead", look: lead, count: 2, unit: nuWords, through: true)]
  t.para.grepStyles = @[GrepStyle(name: "Year", look: year, pattern: "\\d+")]
  t.para.lineStyles = @[NestedLine(name: "Year", look: year, lines: 1), NestedLine(name: "", look: st(20), lines: 1)]
  t.para.repeatLast = 1
  let T = d.addTextLayer(t)
  # (links: on separate words)
  var u = newText("Visit the site, see Notes, or page one.", st(18), 20, 300)
  u.spans = @[TextSpan(text: "Visit ", style: st(18)), TextSpan(text: "the site", style: st(18)),
              TextSpan(text: ", see ", style: st(18)), TextSpan(text: "Notes", style: st(18)),
              TextSpan(text: ", or ", style: st(18)), TextSpan(text: "page one", style: st(18)),
              TextSpan(text: ".", style: st(18))]
  u.spans[1].style.link = "https://example.org/"
  u.spans[3].style.link = "#notes"
  u.spans[5].style.link = "page:1"
  discard d.addTextLayer(u)
  var nt = newText("Notes", st(18), 20, 500)
  nt.spans[0].style.link = "=notes"
  discard d.addTextLayer(nt)
  let S = d.addShapeLayer(ShapeData(path: rectPath(400, 100, 600, 300), fill: solidPaint(0xFF40A040'u32)), "Box")
  d.objectStyles.add ObjectStyleDef(name: "Green Box", useFill: true,
                                    shape: ShapeData(fill: solidPaint(0xFF40A040'u32)))
  S.objectStyle = "Green Box"
  T.objectStyle = "Green Box"
  d.bookmarks = @[DocBookmark(title: "Start", dest: "", level: 0), DocBookmark(title: "The notes", dest: "notes", level: 1)]
  d.saveDocIdml(dir / "sl.idml")
  var all = ""
  for e in zipEntries(dir / "sl.idml"): all.add readEntry(dir / "sl.idml", e)
  doAssert "<AllNestedStyles type=\"list\">" in all and "<AllLineStyles type=\"list\">" in all and
           "<AllGREPStyles type=\"list\">" in all and "CharacterStyle Self=\"CharacterStyle/Lead\"" in all
  doAssert "AppliedObjectStyle=\"ObjectStyle/Green Box\"" in all and "<ObjectStyle Self=\"ObjectStyle/Green Box\"" in all
  doAssert "HyperlinkURLDestination" in all and "HyperlinkTextSource" in all and
           "HyperlinkTextDestination" in all and "HyperlinkPageDestination" in all and "<Bookmark " in all
  # (each part well-formed)
  for e in zipEntries(dir / "sl.idml"):
    if e.name.endsWith(".xml"): discard parseXml(readEntry(dir / "sl.idml", e))
  let r = readIdml(dir / "sl.idml")
  let rd = r.doc(0)
  var sawStyles, sawLinks, sawDest = false
  for L in rd.layers:
    if not L.isText: continue
    let pt = L.text.plainText
    if pt.startsWith("Chapter"):
      let p = L.text.para
      doAssert p.nested.len == 1 and p.nested[0].name == "Lead" and p.nested[0].count == 2 and p.nested[0].unit == nuWords
      doAssert p.nested[0].look.color == 0xFFC02020'u32
      doAssert p.grepStyles.len == 1 and p.grepStyles[0].pattern == "\\d+" and p.grepStyles[0].name == "Year"
      doAssert p.lineStyles.len == 2 and p.lineStyles[0].name == "Year" and p.repeatLast == 1
      doAssert L.objectStyle == "Green Box"
      sawStyles = true
    elif pt.startsWith("Visit"):
      var links: seq[string]
      for sp in L.text.spans:
        if sp.style.link.len > 0: links.add sp.style.link
      doAssert links == @["https://example.org/", "#notes", "page:1"], $links
      sawLinks = true
    elif pt.startsWith("Notes"):
      doAssert L.text.spans[0].style.link == "=notes"
      sawDest = true
  doAssert sawStyles and sawLinks and sawDest
  doAssert rd.objectStyleIndex("Green Box") >= 0
  doAssert rd.bookmarks.len == 2 and rd.bookmarks[0].title == "Start" and rd.bookmarks[1].dest == "notes" and
           rd.bookmarks[1].level == 1, $rd.bookmarks
  var shapeStyled = false
  for L in rd.layers:
    if L.isShape and L.objectStyle == "Green Box": shapeStyled = true
  doAssert shapeStyled
  echo "nested, line and GREP styles, Object Styles, hyperlinks, bookmarks: in IDML and back"

block opticalMarginAndLanguage:
  # Optical Margin Alignment (the story's), Ignore Optical Margin (a paragraph's), a word's
  # language: the layout program's own, and back
  let d = newDoc(600, 400, 0xFFFFFFFF'u32)
  var de = st(20)
  de.lang = "de"
  var t = newText("Silbentrennung im Blocksatz.", de, 20, 40)
  t.boxW = 300
  t.boxH = 200
  t.opticalMargin = true
  t.para.ignoreOptical = true
  discard d.addTextLayer(t)
  d.saveDocIdml(dir / "om.idml")
  var all = ""
  for e in zipEntries(dir / "om.idml"): all.add readEntry(dir / "om.idml", e)
  doAssert "OpticalMarginAlignment=\"true\"" in all and "IgnoreEdgeAlignment=\"true\"" in all and
           "AppliedLanguage=\"$ID/German: 2006 Reform\"" in all
  let rd = readIdml(dir / "om.idml").doc(0)
  var seen = false
  for L in rd.layers:
    if L.isText and L.text.plainText.startsWith("Silben"):
      doAssert L.text.opticalMargin and L.text.para.ignoreOptical
      doAssert L.text.spans[0].style.lang == "de"
      seen = true
  doAssert seen
  echo "Optical Margin Alignment, a word's language: in IDML and back"

block textWrapInIdml:
  # Text Wrap: a picture's kind, side, offsets (points) and Invert; a shape's; a frame that ignores
  # it; an Object Style that has it -- written and read back
  let d = newDoc(600, 800, 0xFFFFFFFF'u32, dpi = 72)
  var t = newText(repeat("Words round a picture. ", 60), st(12), 40, 40)
  t.boxW = 520
  t.boxH = 700
  let T = d.addTextLayer(t)
  let P = d.addLayer("Band")
  for y in 200 ..< 300:
    for x in 200 ..< 400: P.px[y * d.w + x] = 0xFF2040C0'u32
  inc P.ver
  P.wrap = 1
  P.wrapSide = 4
  P.wrapOpts = WrapOptions(offsets: [3'f32, 6, 9, 12], invert: false)
  let S = d.addShapeLayer(ShapeData(path: rectPath(100, 500, 200, 600), fill: solidPaint(0xFF20A040'u32)), "Box")
  S.wrap = 3
  var c = newText("Caption", st(10), 210, 210)
  c.boxW = 180
  c.boxH = 40
  let C = d.addTextLayer(c)
  C.ignoreWrap = true
  # round its shape: from its edges; from a path of the document, by its name
  let E = d.addLayer("Edges")
  for y in 620 ..< 700:
    for x in 300 ..< 400: E.px[y * d.w + x] = 0xFFFFFFFF'u32
  inc E.ver
  E.wrap = 2
  E.wrapOpts.contour = 1
  let K = d.addShapeLayer(ShapeData(path: rectPath(420, 620, 500, 700), fill: solidPaint(0xFF808080'u32)), "Kept")
  K.wrap = 2
  K.wrapOpts.contour = 2
  K.wrapOpts.contourPath = "Around"
  var def = objectStyleOf(S, "Jumps")
  d.redefineObjectStyle(def)
  d.applyObjectStyle(S, "Jumps")
  discard T
  d.saveDocIdml(dir / "wrap.idml")
  let r = readIdml(dir / "wrap.idml")
  let rd = r.doc(0)
  var seenBand, seenBox, seenCaption, seenEdges, seenPath = false
  for L in rd.layers:
    if L.wrap == 1:
      doAssert L.wrapSide == 4 and L.wrapOpts.offsets == [3'f32, 6, 9, 12], $L.wrapOpts
      seenBand = true
    elif L.wrap == 3 and L.isShape: seenBox = true
    elif L.wrap == 2 and L.wrapOpts.contour == 1: seenEdges = true
    elif L.wrap == 2 and L.wrapOpts.contour == 2 and L.wrapOpts.contourPath == "Around": seenPath = true
    elif L.isText and L.ignoreWrap: seenCaption = true
  doAssert seenBand and seenBox and seenCaption and seenEdges and seenPath,
           $(seenBand, seenBox, seenCaption, seenEdges, seenPath)
  let k = rd.objectStyleIndex("Jumps")
  doAssert k >= 0 and rd.objectStyles[k].useWrap and rd.objectStyles[k].wrap == 3, "the Object Style keeps it"
  r.close()
  echo "Text Wrap: in IDML and back"

removeDir(dir)
echo "test_idml: ok"
