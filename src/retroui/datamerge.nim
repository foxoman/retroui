## Data Merge: one design, many pages -- a certificate, a badge, a card for
## each row of a table (CSV). The design's text says where a field goes:
## «Name» (or <<Name>>), the column's name between the marks; a frame
## (a shape) named @Photo gets the picture whose file the row's @Photo (or
## Photo) column names, fitted to fill it.
##
## - `fieldsOf`: the fields a document's text asks for.
## - `merged`: a copy of a document with one row's values in it -- its text
##   filled in, each in the style of its field, and its frames' pictures
##   (`pictures`: a proc that opens a file as pixels).
## - `exportRows`: a file a row instead (PNG or JPEG), each named by a column
##   or numbered (`fileNameFor`) -- for a single image, Photoshop's Data Sets
##   as Files.
##
## .. code-block:: nim
##   import retroui/[photo, charts, datamerge]
##   let table = readCsv("staff.csv")
##   for i in 0 ..< table.rows.len:
##     let page = merged(design, table, i, nil)
##
## Developed by Sultan Al Isaiee @foxoman -- www.foxoman.net -- sultan@foxoman.net

import std/[strutils, os, algorithm]
import photo, photoshapes, photowarp, textengine, charts, gfx

type PictureOpener* = proc (path: string): Bitmap {.closure.}
  ## (a file opened as pixels: nil when it cannot be)

proc fieldNames(s: string): seq[string] =
  ## (the fields a text asks for, in the order they come, each once)
  var found: seq[(int, string)]
  for (o, c) in [("«", "»"), ("<<", ">>")]:
    var at = s.find(o)
    while at >= 0:
      let e = s.find(c, at + o.len)
      if e < 0: break
      let name = s[at + o.len ..< e].strip
      if name.len > 0 and name.len <= 64 and '\n' notin name: found.add (at, name)
      at = s.find(o, e + c.len)
  found.sort()
  for (_, name) in found:
    if name notin result: result.add name

proc fieldsOf*(d: Doc): seq[string] =
  ## The fields `d`'s text asks for («Name»), and its frames' (@Photo), each once.
  for L in d.layers:
    if L.isText:
      for f in fieldNames(L.text.plainText):
        if f notin result: result.add f
    elif L.isShape and L.name.startsWith("@") and L.name notin result:
      result.add L.name

proc valueOf(t: DataTable; row: int; field: string): string =
  let f = field.strip(chars = {'@'})
  for i, h in t.headers:
    let hh = h.strip
    if cmpIgnoreCase(hh, field) == 0 or cmpIgnoreCase(hh.strip(chars = {'@'}), f) == 0:
      if row >= 0 and row < t.rows.len and i < t.rows[row].len: return t.rows[row][i]
      return ""

proc fillText(t: TextData; table: DataTable; row: int): TextData =
  ## (each «Field» of the text its value, in the style of the field's first letter)
  result = t
  for sp in result.spans.mitems:
    for (o, c) in [("«", "»"), ("<<", ">>")]:
      var at = sp.text.find(o)
      while at >= 0:
        let e = sp.text.find(c, at + o.len)
        if e < 0: break
        let name = sp.text[at + o.len ..< e].strip
        let v = valueOf(table, row, name)
        sp.text = sp.text[0 ..< at] & v & sp.text[e + c.len .. ^1]
        at = sp.text.find(o, at + v.len)

proc merged*(design: Doc; table: DataTable; row: int; pictures: PictureOpener; folder = ""): Doc =
  ## A copy of `design` with row `row`'s values in it: its text's fields filled in, each frame
  ## named @Field given the picture its value names (relative to `folder`), filling the frame.
  let tmp = getTempDir() / ("retro-merge-" & $getCurrentProcessId() & ".rpd")
  design.saveRpd(tmp)
  result = loadRpd(tmp)
  removeFile(tmp)
  for L in result.layers:
    if L.isText and ("«" in L.text.plainText or "<<" in L.text.plainText):
      result.setText(L, fillText(L.text, table, row))
  if pictures == nil: return
  let frames = block:
    var fs: seq[Layer]
    for L in result.layers:
      if L.isShape and L.name.startsWith("@"): fs.add L
    fs
  for F in frames:
    var file = valueOf(table, row, F.name)
    if file.len == 0: continue
    if not file.isAbsolute and folder.len > 0: file = folder / file
    let b = pictures(file)
    if b == nil or b.w <= 0 or b.h <= 0: continue
    let (x0, y0, x1, y1) = pathBounds(F.shape.path)
    let frame = rect(int(x0), int(y0), max(1, int(x1 - x0)), max(1, int(y1 - y0)))
    let q = contentQuad(frame, b.w, b.h, ffFill)
    let P = result.newLayer(F.name.strip(chars = {'@'}))
    P.smart = SmartData(src: b.px, w: b.w, h: b.h, quad: q)
    P.px = renderSmart(P.smart, result.w, result.h)
    P.clipped = true                # (in the frame: a clipping mask of it)
    result.insertLayer(P, result.layers.find(F))
  result.markAll()

proc fileNameFor*(table: DataTable; row: int; base: string; column = ""): string =
  ## A file's name, without its extension, for row `row` of `table`: the value in its column
  ## `column` when one is named (and not empty), else `base` and the row's number, three digits
  ## ("Card 001"). Made safe for a file name: no slashes, colons, quotes...
  var s = if column.len > 0: valueOf(table, row, column).strip else: ""
  if s.len == 0: s = (if base.len > 0: base else: "Row") & " " & align($(row + 1), 3, '0')
  for c in s.mitems:
    if c in {'/', '\\', ':', '*', '?', '"', '<', '>', '|'} or c < ' ': c = '_'
  s = s.strip(chars = {' ', '.'})
  if s.len > 120: s.setLen(120)
  if s.len == 0: s = "Row " & align($(row + 1), 3, '0')
  s

proc exportRows*(design: Doc; table: DataTable; folder: string; format = "png"; pictures: PictureOpener = nil;
                 source = ""; column = ""; base = ""; quality = 90;
                 progress: proc (done, total: int) {.closure.} = nil): seq[string] =
  ## Data Merge into files: a file a row of `table` -- the design with that row's values in it
  ## (`merged`) saved flat in `folder` as "png" or "jpg" (Photoshop's Export > Data Sets as Files);
  ## each named by `fileNameFor`, made unique ("Name 2"). `source`: the folder the pictures'
  ## files are named from. The files written, in the rows' order.
  createDir(folder)
  let ext = if format in ["jpg", "jpeg"]: ".jpg" else: ".png"
  var used: seq[string]
  for i in 0 ..< table.rows.len:
    let m = merged(design, table, i, pictures, source)
    var name = fileNameFor(table, i, if base.len > 0: base else: design.name.splitFile.name, column)
    var k = 2
    let stem = name
    while name.toLowerAscii in used:
      name = stem & " " & $k
      inc k
    used.add name.toLowerAscii
    let path = folder / (name & ext)
    m.saveFlat(path, if ext == ".jpg": "jpg" else: "png", quality)
    result.add path
    if progress != nil: progress(i + 1, table.rows.len)
