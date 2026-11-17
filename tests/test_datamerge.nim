## Tests of Data Merge (retroui/datamerge): the fields a design asks for («Name», <<Name>>,
## frames named @Photo); a row's values in a copy of it -- in the style of each field, the
## design itself untouched -- a picture filling its frame, a column not there left empty.

import std/[os, strutils]
import retroui/[photo, photoshapes, textengine, charts, datamerge, gfx]

block fieldsAndRows:
  let d = newDoc(500, 300, 0xFFFFFFFF'u32)
  var st = defaultStyle()
  st.size = 28
  var t = newText("Certificate for ", st, 20, 60)
  var bold = st
  bold.fauxBold = true
  t.spans.add TextSpan(text: "«Name»", style: bold)
  t.spans.add TextSpan(text: "\nof <<Dept>>, «Missing».", style: st)
  discard d.addTextLayer(t)
  discard d.addShapeLayer(ShapeData(path: rectPath(320, 120, 480, 280), fill: solidPaint(0xFFCCCCCC'u32)), "@Photo")
  doAssert d.fieldsOf == @["Name", "Dept", "Missing", "@Photo"], $d.fieldsOf
  let table = parseCsv("Name,Dept,Photo\nSara,Training,p.png\nAli,Quality,none.png")
  var pic = newBitmap(40, 30)
  for i in 0 ..< pic.px.len: pic.px[i] = 0xFF3366CC'u32
  let open = proc (p: string): Bitmap = (if p.endsWith("p.png"): pic else: nil)
  let m = merged(d, table, 0, open, "/data")
  var text = ""
  var nameBold = false
  for L in m.layers:
    if L.isText:
      text = L.text.plainText
      for sp in L.text.spans:
        if "Sara" in sp.text: nameBold = sp.style.fauxBold
  doAssert text == "Certificate for Sara\nof Training, .", text
  doAssert nameBold, "the value in its field's style"
  doAssert "«Name»" in d.layers[1].text.plainText, "the design untouched"
  # the picture: a layer in the frame, filling it
  var placed: Layer
  for L in m.layers:
    if L.smart != nil: placed = L
  doAssert placed != nil and placed.clipped
  let flat = m.flattened(0xFFFFFFFF'u32)
  doAssert flat[200 * m.w + 400] == 0xFF3366CC'u32, "in the frame"
  doAssert flat[200 * m.w + 300] == 0xFFFFFFFF'u32, "cut at the frame's edge (the picture is wider: it fills)"
  # the second row: no picture (its file does not open), the frame as it was
  let m2 = merged(d, table, 1, open, "/data")
  var any = false
  for L in m2.layers:
    if L.smart != nil: any = true
  doAssert not any
  for L in m2.layers:
    if L.isText: doAssert "Ali" in L.text.plainText and "Quality" in L.text.plainText

block aFileARow:
  # Data Merge into files: a PNG (or JPEG) a row, named by a column or numbered
  let d = newDoc(120, 60, 0xFFFFFFFF'u32)
  d.name = "Badge"
  discard d.addTextLayer(newText("«Name»", defaultStyle(), 10, 30))
  let table = parseCsv("Name,City\nSara,Muscat\nAli/Omar,Sur\nSara,Nizwa\n,Salalah")
  doAssert fileNameFor(table, 0, "Badge", "Name") == "Sara"
  doAssert fileNameFor(table, 1, "Badge", "Name") == "Ali_Omar"
  doAssert fileNameFor(table, 3, "Badge", "Name") == "Badge 004", "an empty value: numbered"
  doAssert fileNameFor(table, 0, "Badge") == "Badge 001"
  let dir = getTempDir() / "retro-merge-files"
  removeDir(dir)
  var seen = 0
  let files = d.exportRows(table, dir, "png", column = "Name", progress = proc (a, n: int) = seen = a)
  doAssert seen == 4 and files.len == 4
  doAssert files[0].extractFilename == "Sara.png" and files[2].extractFilename == "Sara 2.png", $files
  for f in files: doAssert fileExists(f) and readFile(f).startsWith("\x89PNG")
  let jpgs = d.exportRows(table, dir / "jpg", "jpg")
  doAssert jpgs[0].extractFilename == "Badge 001.jpg" and readFile(jpgs[0]).startsWith("\xFF\xD8")
  removeDir(dir)

echo "test_datamerge: ok"
