## Tests of Photoshop PDF export (retroui/photopdf): a document with pixels,
## type and a shape becomes a PDF page -- type and shapes as outlines, the
## rest as a picture at the resolution asked; CMYK for a press with crop
## marks and bleed; several documents as a presentation. (When poppler's
## tools are there, they read the files back.)

import std/[os, osproc, strutils]
import retroui/[photo, photopdf, photoimport, textengine, photoshapes, pdfread, pdf, ttf, codec]

let dir = getTempDir() / "retro-photopdf-test"
removeDir(dir)
createDir(dir)

proc page(): Doc =
  result = newDoc(600, 800, 0xFFFFFFFF'u32, dpi = 150, name = "Page")
  let L = result.addLayer("photo")
  for y in 100 ..< 400:
    for x in 50 ..< 550: L.px[y * 600 + x] = argb(255, x * 255 div 600, y * 255 div 800, 160)
  inc L.ver
  let T = result.addTextLayer(newText("RETRO MAGAZINE", CharStyle(family: "", size: 48, color: 0xFFCC2200'u32,
                                                                  hScale: 1, vScale: 1), 60, 480))
  discard T
  var s = ShapeData(kind: "Ellipse")
  s.path = ellipsePath(180, 590, 420, 710)
  s.fill = ShapePaint(kind: spColor, color: 0xFF0050A0'u32)
  s.stroke = ShapePaint(kind: spColor, color: 0xFF000000'u32)
  s.strokeWidth = 4
  s.align = saCenter
  discard result.addShapeLayer(s, "badge")
  result.markAll()

let d = page()
let web = dir / "web.pdf"
d.savePdf(web, pdfPreset(ppWeb))
let webData = readFile(web)
doAssert webData.startsWith("%PDF-1.7") and webData.endsWith("%%EOF\n")
doAssert "/DCTDecode" in webData, "the picture as a JPEG"
let press = dir / "press.pdf"
var o = pdfPreset(ppPress)
o.ppi = 600
d.savePdf(press, o)
let pressData = readFile(press)
doAssert "/DeviceCMYK" in pressData and "/TrimBox" in pressData and "/BleedBox" in pressData
# (the page: the document's size at 150 ppi, plus the marks' room)
doAssert "/MediaBox [0 0 360 456]" in pressData, "4 x 5.33 inches + 1 inch"
let doc2 = page()
doc2.name = "Second"
let pres = dir / "presentation.pdf"
savePdfPresentation([d, doc2], pres, pdfPreset(ppPrint), "Magazine")
doAssert "/Count 2" in readFile(pres)
# the layers are as they were
doAssert d.layers.len == 4 and d.layers[2].visible and d.layers[1].visible

if findExe("pdfinfo").len > 0:
  for f in [web, press, pres]:
    let (outp, code) = execCmdEx("pdfinfo " & quoteShell(f))
    doAssert code == 0, outp
  let (info, _) = execCmdEx("pdfinfo " & quoteShell(pres))
  doAssert "Pages:           2" in info, info
if findExe("pdftoppm").len > 0:
  let (_, code) = execCmdEx("pdftoppm -r 40 -png " & quoteShell(press) & " " & quoteShell(dir / "p"))
  doAssert code == 0
# read back: a page as pixels; an Illustrator-like drawing as shape layers
let back = importPdf(readFile(web), "web", ImportOptions(ppi: 150))
doAssert (back.w, back.h) == (600, 800), $(back.w, back.h)
let mid = back.layers[0].px[650 * 600 + 300]
doAssert ((mid shr 16) and 255) < 60 and (mid and 255) > 120, "the blue badge: " & toHex(mid)
let vec = importPdf(readFile(press), "press", ImportOptions(ppi: 150, shapes: true))
var shapes = 0
for L in vec.layers:
  if L.isShape: inc shapes
doAssert shapes >= 2, "the badge's fill and stroke (and the crop marks) as shapes: " & $shapes
doAssert vec.layers[^1].name == "Text and Pictures"
# PostScript and EPS: written, read back
let ps = dir / "page.ps"
d.savePs(ps)
let psData = readFile(ps)
doAssert psData.startsWith("%!PS-Adobe-3.0") and "%ImageData: 600 800 8 3" in psData
doAssert " curveto" in psData and "setrgbcolor" in psData, "type and the shape as outlines"
let eps = dir / "page.eps"
d.savePs(eps, eps = true, cmyk = true)
doAssert readFile(eps).startsWith("%!PS-Adobe-3.0 EPSF-3.0") and "setcmykcolor" in readFile(eps)
let psBack = importPs(psData, "page")
doAssert (psBack.w, psBack.h) == (600, 800) and abs(psBack.dpi - 150) < 1
doAssert psBack.layers[0].px[250 * 600 + 300] == d.layers[1].px[250 * 600 + 300] or
         abs(int(psBack.layers[0].px[250 * 600 + 300] and 255) - int(d.layers[1].px[250 * 600 + 300] and 255)) < 3
let epsBack = importPs(readFile(eps), "eps")
doAssert (epsBack.w, epsBack.h) == (600, 800)
if findExe("gs").len > 0:
  let (_, code) = execCmdEx("gs -q -dNOPAUSE -dBATCH -sDEVICE=nullpage " & quoteShell(ps))
  doAssert code == 0
block pressAndLiveText:
  # for a press: PDF/X with its printing condition, trim and bleed boxes,
  # registration marks, color bars; type as text in its embedded (subset)
  # font, the characters found again -- Arabic too
  let d = newDoc(600, 400, 0xFFFFFFFF'u32, dpi = 300, name = "flyer")
  let st = CharStyle(family: "", size: 40, color: 0xFF000000'u32, hScale: 1, vScale: 1)
  discard d.addTextLayer(newText("Grand Opening", st, 40, 100))
  discard d.addTextLayer(newText("مرحبا بكم", st, 560, 250))
  d.markAll()
  let path = getTempDir() / "retro-press.pdf"
  d.savePdf(path, pdfPreset(ppPress))
  let data = readFile(path)
  for k in ["/FontFile2", "/CIDFontType2", "/Identity-H", "/ToUnicode", "/OutputIntents", "/GTS_PDFX",
            "PDF/X-4", "FOGRA39", "/TrimBox", "/BleedBox"]:
    doAssert k in data, k
  let f = openPdf(data)
  doAssert f.pageCount == 1
  if findExe("pdftotext").len > 0:
    let (txt, code) = execCmdEx("pdftotext " & quoteShell(path) & " -")
    doAssert code == 0 and "Grand Opening" in txt, txt
    doAssert "مرحبا" in txt, txt
  # the font is a subset: smaller than the font file
  # (the output intent's CMYK profile is in the file too: the font's own
  # stream measured)
  let full = fontData(fontFace("", "").face).len
  let at = data.find("/Length1 ")
  doAssert at > 0
  var n = 0
  for c in data[at + 9 .. ^1]:
    if c notin '0' .. '9': break
    n = n * 10 + ord(c) - ord('0')
  doAssert n > 0 and n < full div 4, $n & " vs " & $full
  # outlines when asked: no font in the file
  var o = pdfPreset(ppPrint)
  o.liveText = false
  d.savePdf(path, o)
  doAssert "/FontFile2" notin readFile(path)
  removeFile(path)
  # the subsetter keeps a font a reader takes
  let face = fontFace("", "").face
  let sub = subsetTtf(fontData(face), [36, 37, 38])
  doAssert sub.len < fontData(face).len div 4
  doAssert sub[0 .. 3] == fontData(face)[0 .. 3]

block taggedInksAndForms:
  # Create Tagged PDF: headings and paragraphs, pictures with their alt text, decorations left
  # out; a spot ink on its plate (unless the Ink Manager prints it in process), overprint;
  # layers made form fields and buttons, the page's transition; a nonprinting layer left out
  var d = newDoc(600, 800, 0xFFFFFFFF'u32, dpi = 72, name = "Form")
  let ph = d.addLayer("photo")
  for y in 100 ..< 300:
    for x in 50 ..< 550: ph.px[y * 600 + x] = argb(255, x * 255 div 600, 90, 160)
  inc ph.ver
  ph.attrs.alt = "A sunset over the sea"
  var st = CharStyle(family: "", size: 30, color: 0xFF000000'u32, hScale: 1, vScale: 1)
  var title = newText("Order form", st, 60, 40)
  title.para.styleName = "Heading 1"
  discard d.addTextLayer(title)
  discard d.addTextLayer(newText("Fill in your name below.", st, 60, 340))
  d.spotInks.add spotInk("Retro Red", 0xFFC8102E'u32)
  var s = ShapeData(kind: "Rectangle")
  s.path = rectPath(60, 400, 540, 440)
  s.fill = ShapePaint(kind: spColor, color: 0xFFC8102E'u32, spot: "Retro Red", tint: 60)
  let band = d.addShapeLayer(s, "band")
  band.attrs.overprintFill = true
  var f = ShapeData(kind: "Rectangle")
  f.path = rectPath(60, 460, 400, 500)
  f.fill = ShapePaint(kind: spColor, color: 0xFFEEEEEE'u32)
  let field = d.addShapeLayer(f, "name field")
  field.attrs.field = FieldSpec(kind: "text", name: "name", tooltip: "Your name")
  var b = ShapeData(kind: "Rectangle")
  b.path = rectPath(420, 700, 540, 740)
  b.fill = ShapePaint(kind: spColor, color: 0xFF2050A0'u32)
  let btn = d.addShapeLayer(b, "next")
  btn.attrs.field = FieldSpec(kind: "button", caption: "Next", action: "next")
  var g = ShapeData(kind: "Rectangle")
  g.path = rectPath(0, 0, 20, 20)
  g.fill = ShapePaint(kind: spColor, color: 0xFF00FF00'u32)
  let guide = d.addShapeLayer(g, "a note to self")
  guide.attrs.nonprinting = true
  d.transition = ("Dissolve", 0.8, 0, 0.0)
  d.markAll()
  var o = pdfPreset(ppPress)
  o.tagged = true
  o.interactive = true
  o.marks = false; o.regMarks = false; o.colorBars = false; o.pageInfo = false
  let path = dir / "form.pdf"
  d.savePdf(path, o)
  let raw = readFile(path)
  var all = raw
  var at = raw.find("/FlateDecode >>\nstream\n")
  while at >= 0:
    let a0 = at + "/FlateDecode >>\nstream\n".len
    let e = raw.find("\nendstream", a0)
    try: all.add "\n" & cast[string](zlibDecompress(toBytes(raw[a0 ..< e])))
    except CatchableError: discard
    at = raw.find("/FlateDecode >>\nstream\n", e)
  for k in ["/StructTreeRoot", "/S /H1", "/S /P", "/S /Figure", "/Alt (A sunset over the sea)",
            "/Separation /Retro#20Red", "/OPM 1", "/AcroForm", "/T (name)", "/TU (Your name)",
            "/S /Named /N /NextPage", "/Trans << /Type /Trans /S /Dissolve /D 0.8"]:
    doAssert k in all, k
  doAssert " scn" in all and "0.6 scn" in all
  doAssert "0 1 0 rg" notin all and "0 0 1 0 k" notin all       # (the nonprinting green: not there)
  doAssert guide.visible                                         # (still seen here)
  # the Ink Manager: the spot in process inks -- no plate of its own
  d.inkSettings.toProcess.add "Retro Red"
  d.savePdf(path, o)
  doAssert "/Separation" notin readFile(path)
  if findExe("qpdf").len > 0:
    let (q, code) = execCmdEx("qpdf --check " & quoteShell(path))
    doAssert code == 0, q
  # saved and read back with the document
  d.inkSettings.aliases.add ("Retro Red", "Black")
  let rp = dir / "form.rpd"
  d.saveRpd(rp)
  let back = openImage(rp)
  doAssert back.spotInks.len == 1 and back.spotInks[0].name == "Retro Red"
  doAssert back.inkSettings.toProcess == @["Retro Red"] and back.inkSettings.aliases.len == 1
  doAssert back.transition.style == "Dissolve"
  var found = 0
  for L in back.layers:
    if L.name == "band":
      doAssert L.attrs.overprintFill and L.shape.fill.spot == "Retro Red" and L.shape.fill.tint == 60
      inc found
    if L.name == "name field":
      doAssert L.attrs.field.kind == "text" and L.attrs.field.tooltip == "Your name"
      inc found
    if L.name == "photo":
      doAssert L.attrs.alt == "A sunset over the sea"
      inc found
  doAssert found == 3

echo "photo pdf tests passed"
