## Tests of e-books and web pages made of pages (retroui/publish): an EPUB 3, reflowable and
## fixed layout -- what a reader needs in it, in order, well formed -- and a web page.

import std/[os, osproc, strutils]
import retroui/[publish, zip, gfx, imaging, photo, photobook, photopublish, textengine, photoshapes]

let dir = getTempDir() / "retro-test-publish"
removeDir(dir)
createDir(dir)

proc png(c: uint32): string =
  let b = newBitmap(4, 3)
  for i in 0 ..< b.px.len: b.px[i] = c
  encodePng(b)

var p1 = PubPage(w: 800, h: 1000)
p1.blocks.add PubBlock(kind: pbPicture, x: 60, y: 300, w: 680, h: 400, picture: png(0xFF2060A0'u32),
                       alt: "The harbour at dusk")
p1.blocks.add PubBlock(kind: pbText, x: 60, y: 60, w: 680, h: 120,
                       paras: @[PubPara(tag: "h1", runs: @[PubRun(text: "Muscat & the sea", size: 40, bold: true)]),
                                PubPara(runs: @[PubRun(text: "A city ", size: 16),
                                                PubRun(text: "between", size: 16, italic: true),
                                                PubRun(text: " mountains and water <1>.", size: 16)])])
p1.blocks.add PubBlock(kind: pbPicture, x: 0, y: 0, w: 800, h: 20, picture: png(0xFFEEEEEE'u32), decorative: true)
var p2 = PubPage(w: 800, h: 1000, title: "الفصل الثاني")
p2.blocks.add PubBlock(kind: pbText, x: 60, y: 60, w: 680, h: 300,
                       paras: @[PubPara(tag: "h2", rtl: true, runs: @[PubRun(text: "مرحبا", size: 30)]),
                                PubPara(tag: "li", runs: @[PubRun(text: "one", size: 16, link: "https://www.foxoman.net")]),
                                PubPara(tag: "li", runs: @[PubRun(text: "two", size: 16)])])
let book = PubDoc(title: "Coast", author: "Sultan", lang: "en", pages: @[p1, p2], cover: png(0xFFFF0000'u32),
                  stamp: "2026-11-17T09:00:00Z")

block reflowable:
  let e = epubOf(book)
  let path = dir / "coast.epub"
  writeFile(path, e)
  let es = zipEntries(path)
  doAssert es[0].name == "mimetype" and readEntry(path, es[0]) == "application/epub+zip"
  doAssert e[30 ..< 38] == "mimetype" and e[8] == '\0'          # (first, stored, no extra field)
  var names: seq[string]
  for x in es: names.add x.name
  for n in ["META-INF/container.xml", "OEBPS/content.opf", "OEBPS/nav.xhtml", "OEBPS/page1.xhtml",
            "OEBPS/page2.xhtml", "OEBPS/book.css", "OEBPS/images/cover.png", "OEBPS/images/pic1.png"]:
    doAssert n in names, n
  proc entry(n: string): string =
    for x in es:
      if x.name == n: return readEntry(path, x)
  let opf = entry("OEBPS/content.opf")
  doAssert "<dc:title>Coast</dc:title>" in opf and "<dc:creator>Sultan</dc:creator>" in opf
  doAssert "properties=\"cover-image\"" in opf and "properties=\"nav\"" in opf
  doAssert "dcterms:modified\">2026-11-17T09:00:00Z" in opf and "alternativeText" in opf
  doAssert "<itemref idref=\"p1\"/>" in opf and "<itemref idref=\"p2\"/>" in opf
  let pg1 = entry("OEBPS/page1.xhtml")
  # (in reading order: the heading before the picture under it; the band at the top a decoration)
  doAssert pg1.find("<h1>") < pg1.find("<figure>") and pg1.find("role=\"presentation\"") < pg1.find("<h1>")
  doAssert "alt=\"The harbour at dusk\"" in pg1 and "Muscat &amp; the sea" in pg1 and "&lt;1&gt;" in pg1
  doAssert "<em>between</em>" in pg1
  let pg2 = entry("OEBPS/page2.xhtml")
  doAssert "dir=\"rtl\"" in pg2 and "<ul><li>" in pg2 and "href=\"https://www.foxoman.net\"" in pg2
  doAssert "الفصل الثاني" in entry("OEBPS/nav.xhtml")
  # well formed, every file of it
  let py = findExe("python3")
  if py.len > 0:
    for n in names:
      if n.endsWith(".xhtml") or n.endsWith(".opf") or n.endsWith(".xml"):
        let f = dir / n.replace("/", "_")
        writeFile(f, entry(n))
        let (o, code) = execCmdEx(py & " -I -c \"import sys, xml.dom.minidom; xml.dom.minidom.parse(sys.argv[1])\" " &
                                  quoteShell(f))
        doAssert code == 0, n & ": " & o
  # the same book again: the same bytes
  doAssert epubOf(book) == e

block fixedLayout:
  let e = epubOf(book, fixed = true)
  let path = dir / "coast-fixed.epub"
  writeFile(path, e)
  for x in zipEntries(path):
    if x.name == "OEBPS/content.opf":
      let opf = readEntry(path, x)
      doAssert "rendition:layout\">pre-paginated" in opf and "rendition:layout-pre-paginated" in opf
    if x.name == "OEBPS/page1.xhtml":
      let pg = readEntry(path, x)
      doAssert "width=800, height=1000" in pg and "position:absolute;left:60.0px;top:300.0px" in pg

block webPageAndSite:
  let html = webPage(book)
  doAssert html.startsWith("<!DOCTYPE html>") and "<title>Coast</title>" in html
  doAssert "data:image/png;base64," in html and "alt=\"The harbour at dusk\"" in html
  doAssert "name=\"viewport\"" in html and "aspect-ratio:800.00 / 1000.00" in html
  doAssert "<nav class=\"pages\"" in html and "href=\"#page2\"" in html
  let site = dir / "site"
  publishSite(book, site)
  doAssert fileExists(site / "index.html") and fileExists(site / "images" / "pic1.png")
  let idx = readFile(site / "index.html")
  doAssert "src=\"images/pic1.png\"" in idx and "data:image" notin idx

block fromDocuments:
  # a document's type as text (headings by their styles, links kept), its other layers pictures
  # with their alt text; a book's pages in order, its cover the first page
  let d = newDoc(600, 400, 0xFFFFFFFF'u32, name = "Flyer")
  var st = defaultStyle()
  st.size = 36
  var h = newText("Summer Fair", st, 40, 60)
  h.para.styleName = "Heading 1"
  discard d.addTextLayer(h)
  var b = defaultStyle()
  b.size = 16
  b.link = "https://www.foxoman.net"
  discard d.addTextLayer(newText("Tickets online", b, 40, 120))
  let pic = d.addLayer("photo")
  for y in 150 ..< 350:
    for x in 40 ..< 560: pic.px[y * 600 + x] = 0xFF3080C0'u32
  inc pic.ver
  pic.attrs.alt = "A crowd at the fair"
  let deco = d.addShapeLayer(ShapeData(path: rectPath(0, 380, 600, 400), fill: solidPaint(0xFFFF8800'u32)), "band")
  discard deco
  d.markAll()
  let pd = pubDocOf(@[d])
  doAssert pd.pages.len == 1 and pd.title == "Flyer"
  let pg = pd.pages[0]
  doAssert pg.background == 0xFFFFFFFF'u32
  var heads, links, alts, decos = 0
  for blk in pg.blocks:
    for q in blk.paras:
      if q.tag == "h1": inc heads
      for r in q.runs:
        if r.link == "https://www.foxoman.net": inc links
    if blk.kind == pbPicture and blk.alt == "A crowd at the fair" and blk.picture.len > 0: inc alts
    if blk.kind == pbPicture and blk.decorative: inc decos
  doAssert heads == 1 and links == 1 and alts == 1 and decos == 1
  let html = webPage(pd)
  doAssert "<h1>" in html and "Summer Fair" in html and "alt=\"A crowd at the fair\"" in html
  # a book
  let bk = newBook(bookSetup(148, 210, dpi = 72, facing = false), pages = 2, name = "Little Book")
  let p0 = bk.doc(0)
  discard p0.addTextLayer(newText("Chapter One", st, 30, 60))
  p0.markAll()
  let pb = pubDocOf(bk)
  doAssert pb.pages.len == 2 and pb.title == "Little Book" and pb.cover.len > 0
  let e = epubOf(pb)
  doAssert e.len > 1000 and "Chapter One" notin e[0 .. 100]

echo "publish ok"
