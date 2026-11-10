## retroui/pdf: the file's structure (the cross-reference table, the objects),
## pages of any size, drawing, pictures, text in every style with Arabic,
## links, the document's information, the same bytes every time, speed --
## and, when Python's pypdf is there (PYTHONPATH), that a PDF reader gets
## the pages, the text, the pictures and the links back out; when qpdf is
## there, its check too.

import std/[os, osproc, strutils, times, json]
import std/unicode except splitWhitespace, strip   # (its strip cuts letters: docs/nim-bugs.md)
import retroui/gfx
import retroui/pdf

let outDir = getTempDir() / "retro-test-pdf"
createDir(outDir)

# ---- reading the file back: the cross-reference table ----------------------------------------

proc checkXref(pdf: string): int =
  ## Checks that every object is where the table says; the object count.
  doAssert pdf.startsWith("%PDF-1.")
  doAssert pdf.strip.endsWith("%%EOF")
  let sx = pdf.rfind("startxref")
  doAssert sx > 0
  let at = parseInt(pdf[sx + 9 .. ^1].strip.splitLines[0])
  doAssert pdf.continuesWith("xref", at), "startxref points at the table"
  var lines = pdf[at .. ^1].splitLines
  let head = lines[1].splitWhitespace
  doAssert head[0] == "0"
  let n = parseInt(head[1])
  doAssert lines[2].startsWith("0000000000 65535 f")
  for i in 1 ..< n:
    let e = lines[2 + i]
    doAssert e.len == 18 or e.len == 19, "entries are 20 bytes: " & e
    let off = parseInt(e[0 ..< 10])
    doAssert e[17] == 'n'
    doAssert pdf.continuesWith($i & " 0 obj", off), "object " & $i & " at " & $off
  let trailer = pdf.find("trailer", at)
  doAssert trailer > 0 and pdf.find("/Size " & $n, trailer) > 0
  n

proc count(s, sub: string): int =
  var i = s.find(sub)
  while i >= 0:
    inc result
    i = s.find(sub, i + sub.len)

# ---- a document with everything --------------------------------------------------------------

proc picture(w, h: int; alpha: bool): Bitmap =
  result = newBitmap(w, h, 0xFFFFFFFF'u32)
  for y in 0 ..< h:
    for x in 0 ..< w:
      let a = if alpha: uint32(255 * x div max(1, w - 1)) else: 255'u32
      result.px[y * w + x] = (a shl 24) or (uint32(x * 255 div w) shl 16) or
                             (uint32(y * 255 div h) shl 8) or 0x80

let arabic = "مرحبا بالعالم"

proc sample(): PdfDoc =
  result = newPdf("Test document", "Retro tests")
  result.subject = "Everything retroui/pdf draws"
  result.keywords = "pdf, test"
  let d = result
  # page 1: A4, text in every style
  let p = d.addPage(A4)
  doAssert abs(p.w - 595.28) < 0.01 and abs(p.h - 841.89) < 0.01
  var y = 40.0
  let w = p.text(40, y, "Hello PDF: Invoice 42", 20, bold = true)
  doAssert abs(w - pdfTextWidth("Hello PDF: Invoice 42", 20, bold = true)) < 0.01
  y += pdfLineHeight(20)
  discard p.text(40, y, "Plain sans text AV Wa To", 12)
  y += 18
  discard p.text(40, y, "Italic words here", 12, italic = true)
  y += 18
  discard p.text(40, y, "mono 0123456789", 12, mono = true)
  y += 18
  discard p.text(40, y, "bold mono", 12, bold = true, mono = true)
  y += 18
  discard p.text(40, y, "Colored text", 12, color = color(200, 0, 0))
  y += 18
  let aw = pdfTextWidth(arabic, 14)
  discard p.text(555 - aw, y, arabic, 14)
  y += 22
  discard p.text(40, y, "Accents: café, naïve, Ærø, €100, ±5°", 12)
  y += 22
  discard p.text(40, y, "A link to example.com", 12, color = color(0, 0, 200))
  p.link(40, y, pdfTextWidth("A link to example.com", 12), pdfLineHeight(12),
         "https://example.com/?a=1&b=(2)")
  # page 2: Letter landscape, drawing
  let q = d.addPage(landscape(Letter))
  doAssert q.w == 792 and q.h == 612
  q.line(20, 20, 300, 20, color(0, 0, 0), 2)
  q.box(20, 40, 100, 60, fill = color(255, 220, 220), stroke = color(200, 0, 0), width = 1.5)
  q.saveState()
  q.dash([6.0, 3.0])
  q.lineCap(capRound)
  q.lineJoin(joinRound)
  q.strokeColor(color(0, 0, 255))
  q.lineWidth(3)
  q.moveTo(150, 40)
  q.lineTo(250, 100)
  q.curveTo(260, 120, 300, 120, 320, 40)
  q.closePath()
  q.stroke()
  q.restoreState()
  q.saveState()
  q.opacity(0.5)
  q.fillColor(color(0, 160, 0))
  q.ellipse(400, 80, 50, 30)
  q.fill()
  q.restoreState()
  q.saveState()
  q.roundRect(20, 120, 200, 100, 12)
  q.clip()
  q.fillColor(color(255, 200, 0))
  q.rect(0, 100, 400, 200)
  q.fill()
  q.restoreState()
  # pictures: with and without transparency, the same one twice (stored once)
  let pic = picture(64, 48, false)
  q.image(pic, 300, 150, 128, 96)
  q.image(pic, 450, 150, 64, 48)
  q.image(picture(32, 32, true), 550, 150, 64, 64)
  let jpg = readFile(currentSourcePath.parentDir / "fuzz" / "seeds" / "quad.jpg")
  doAssert q.jpegImage(jpg, 300, 300, 100, 100)
  doAssert not q.jpegImage("not a jpeg", 0, 0, 10, 10)
  # page 3: a custom size, nothing on it but a line of text
  let r = d.addPage((mm(100), mm(150)))
  doAssert abs(r.w - 283.46) < 0.01
  discard r.text(10, 10, "Small page", 10)

block structure:
  let d = sample()
  let pdf = d.render()
  let n = checkXref(pdf)
  doAssert n > 10
  doAssert pdf.count("/Type /Page ") + pdf.count("/Type /Page\n") + pdf.count("/Type /Page>") == 3 or
           pdf.count("/Type /Page") - pdf.count("/Type /Pages") == 3
  doAssert pdf.contains("/Count 3")
  doAssert pdf.contains("/Title (Test document)")
  doAssert pdf.contains("/Author (Retro tests)")
  doAssert pdf.contains("/Type3")
  doAssert pdf.contains("/ToUnicode")
  doAssert pdf.contains("/FlateDecode")
  doAssert pdf.contains("/DCTDecode")
  doAssert pdf.contains("/SMask")
  doAssert pdf.contains("/URI")
  doAssert pdf.count("/Subtype /Image") == 4, "the picture used twice is stored once (and its mask)"
  # the same document gives the same bytes
  doAssert sample().render() == pdf, "deterministic"
  d.save(outDir / "sample.pdf")
  doAssert readFile(outDir / "sample.pdf") == pdf

block emptyAndBad:
  # no pages: still a valid file, with one blank page
  let e = newPdf()
  let pdf = e.render()
  discard checkXref(pdf)
  doAssert pdf.contains("/Count 1")
  # nonsense in: nothing breaks
  let d = newPdf("(parens) and \\ backslash \0 nul")
  let p = d.addPage((NaN, -5.0))
  doAssert p.w == A4.w and p.h == A4.h
  discard p.text(NaN, Inf, "nan", NaN)
  discard p.text(10, 10, "", 10)
  discard p.text(10, 10, "\xFF\xFE broken utf-8 \xC3", 10)
  p.line(NaN, 0, Inf, -Inf)
  p.box(0, 0, NaN, 10, fill = color(1, 2, 3))
  p.dash([NaN, -1.0, 1e300])
  p.opacity(NaN)
  p.lineWidth(-3)
  p.image(nil, 0, 0, 10, 10)
  p.image(newBitmap(0, 0), 0, 0, 10, 10)
  p.link(0, 0, 10, 10, "")
  discard p.text(10, 10, "x".repeat(20000), 10)
  discard checkXref(d.render())

block manyGlyphs:
  # more than 256 different glyphs of one face: more than one font
  let d = newPdf()
  let p = d.addPage()
  var s = ""
  for c in 0x20 .. 0x17F:
    if c notin 0x7F .. 0x9F: s.add Rune(c).toUTF8
  for i in 0 ..< 8:
    discard p.text(20, 20 + float(i) * 14, s.runeSubStr(i * 45, 45), 9)
  let pdf = d.render()
  discard checkXref(pdf)
  doAssert pdf.count("/Subtype /Type3") >= 2

block speed:
  # 100 pages of 50 lines of table text
  let t0 = epochTime()
  let d = newPdf("Speed")
  for pg in 0 ..< 100:
    let p = d.addPage()
    for i in 0 ..< 50:
      let y = 40 + float(i) * 15
      discard p.text(40, y, "Row " & $(pg * 50 + i) & " Paper A4 box of 5 reams", 9)
      discard p.text(400, y, formatFloat(float(i) * 12.5, ffDecimal, 2), 9)
      p.line(40, y + 13, 555, y + 13, color(200, 200, 200), 0.25)
  let pdf = d.render()
  let dt = epochTime() - t0
  discard checkXref(pdf)
  echo "100 pages: ", pdf.len div 1024, " KB in ", formatFloat(dt * 1000, ffDecimal, 0), " ms"
  doAssert dt < (when defined(release) or defined(danger): 1.0 else: 10.0),
           "100 pages well under a second (in a release build)"
  writeFile(outDir / "speed.pdf", pdf)

# ---- what PDF readers see --------------------------------------------------------------------

if findExe("qpdf").len > 0:
  for f in ["sample.pdf", "speed.pdf"]:
    let (o, code) = execCmdEx("qpdf --check " & quoteShell(outDir / f))
    doAssert code == 0, o
  echo "qpdf --check: ok"
else:
  echo "qpdf not found: its check skipped"

let py = findExe("python3")
if py.len > 0 and execCmdEx(py & " -c 'import pypdf'").exitCode == 0:
  let script = """
import json, sys, unicodedata, pypdf
r = pypdf.PdfReader(sys.argv[1])
out = {"pages": len(r.pages), "sizes": [], "text": [], "images": [], "links": [],
       "info": {k: str(v) for k, v in (r.metadata or {}).items()}}
for p in r.pages:
    out["sizes"].append([float(p.mediabox.width), float(p.mediabox.height)])
    out["text"].append(unicodedata.normalize("NFKC", p.extract_text()))
    out["images"].append(len(p.images))
    for a in p.get("/Annots") or []:
        a = a.get_object()
        if a.get("/A"): out["links"].append(str(a["/A"]["/URI"]))
print(json.dumps(out))
"""
  writeFile(outDir / "read.py", script)
  let (o, code) = execCmdEx(py & " " & quoteShell(outDir / "read.py") & " " &
                            quoteShell(outDir / "sample.pdf"))
  doAssert code == 0, o
  let j = parseJson(o.strip.splitLines[^1])
  doAssert j["pages"].getInt == 3
  doAssert abs(j["sizes"][0][0].getFloat - 595.28) < 0.1
  doAssert j["sizes"][1][0].getFloat == 792 and j["sizes"][1][1].getFloat == 612
  let t0 = j["text"][0].getStr
  for want in ["Hello PDF: Invoice 42", "Plain sans text", "Italic words here",
               "mono 0123456789", "bold mono", "Colored text", "café", "€100",
               "A link to example.com"]:
    doAssert want in t0, "text read back: " & want & " in " & t0
  # Arabic comes back as letters (joined forms normalized), in reading order
  doAssert "مرحبا" in t0 and "بالعالم" in t0, "Arabic read back: " & t0
  doAssert j["text"][2].getStr.contains("Small page")
  doAssert j["images"][1].getInt == 3 and j["images"][0].getInt == 0, $j["images"]
  doAssert j["links"].len == 1 and j["links"][0].getStr == "https://example.com/?a=1&b=(2)"
  doAssert j["info"]["/Title"].getStr == "Test document"
  doAssert j["info"]["/Author"].getStr == "Retro tests"
  let (o2, code2) = execCmdEx(py & " " & quoteShell(outDir / "read.py") & " " &
                              quoteShell(outDir / "speed.pdf"))
  doAssert code2 == 0, o2
  let j2 = parseJson(o2.strip.splitLines[^1])
  doAssert j2["pages"].getInt == 100
  doAssert "Row 4999 Paper A4 box of 5 reams" in j2["text"][99].getStr
  echo "pypdf: pages, sizes, text (Arabic too), pictures, links and information read back"
else:
  echo "pypdf not found (set PYTHONPATH): reading back skipped"

echo "test_pdf: ok"
