## Excel workbooks (.xlsx) in plain Nim: every sheet's cells as text, for
## importing. The values Excel saved are read (formulas are not computed);
## dates come out as "yyyy-mm-dd" (with " hh:mm" when they have a time),
## numbers without Excel's float noise ("350", not "350.00000000000006").
##
## .. code-block:: nim
##   for sheet in readXlsx("Payroll.xlsx"):
##     echo sheet.name, ": ", sheet.rows.len, " rows"
##     for row in sheet.rows: echo row.join(" | ")

import std/[strutils, parsexml, streams, tables, math, os]
import std/unicode except strip   # (its strip cuts letters: docs/nim-bugs.md)
import zip

type
  XlsxError* = object of CatchableError
    ## A file that cannot be read as a workbook (missing, not a zip, not an
    ## Excel file, damaged).
  SheetDirection* = enum
    ## Which way a sheet's columns go, as Excel shows it.
    sdAuto,                   ## from its cells: right to left when its first cell with
                              ## letters is Arabic (or Hebrew), else left to right
    sdLtr,                    ## left to right: column A at the left
    sdRtl                     ## right to left: column A at the right (Excel's
                              ## "Sheet Right-to-Left"), as Arabic sheets read
  XlsxSheet* = object
    ## A sheet of a workbook, its cells as text.
    name*: string             ## its name on its tab ("Sheet1")
    rows*: seq[seq[string]]   ## the cells, row by row ("" where empty)
    direction*: SheetDirection
      ## which way it reads (`readXlsx`: as the file has it; `writeXlsx`
      ## writes it so)

const
  MaxColumns = 2048            ## (a damaged "XFD1048576" does not allocate gigabytes)

proc colIndex(r: string): int =
  ## "AB12" -> 27 (0-based); -1 when it is not a cell reference.
  result = 0
  var n = 0
  for c in r:
    if c in {'A'..'Z'}:
      result = result * 26 + (ord(c) - ord('A') + 1)
      inc n
      if result > MaxColumns: return -1
    elif c in {'a'..'z'}:
      result = result * 26 + (ord(c) - ord('a') + 1)
      inc n
      if result > MaxColumns: return -1
    else: break
  if n == 0: return -1
  dec result

proc isDateFormat(code: string): bool =
  ## A number format that shows a date or a time (d, m, y, h, s outside
  ## quotes, brackets and escapes; not "General").
  if code.len == 0 or cmpIgnoreCase(code, "General") == 0: return false
  var i = 0
  var quoted = false
  while i < code.len:
    let c = code[i]
    if quoted:
      if c == '"': quoted = false
    elif c == '"': quoted = true
    elif c == '\\' or c == '_' or c == '*': inc i
    elif c == '[':
      # [h] and [mm] are elapsed time; [Red], [$-409] are not dates
      let e = code.find(']', i)
      if e < 0: break
      let inner = code[i + 1 ..< e].toLowerAscii
      if inner.len > 0 and inner[0] in {'h', 'm', 's'}: return true
      i = e
    elif c in {'d', 'D', 'm', 'M', 'y', 'Y', 'h', 'H', 's', 'S'}: return true
    inc i
  false

proc builtinDate(id: int): bool =
  id in 14 .. 22 or id in 27 .. 36 or id in 45 .. 47 or id in 50 .. 58

proc serialToDate(v: float; date1904: bool): string =
  ## An Excel date serial as "yyyy-mm-dd" (and " hh:mm" with a time).
  if v.isNaN or v < 0 or v > 2_958_465: return ""
  var days = int(floor(v))
  let frac = v - float(days)
  # day 0 is 1899-12-30 in the 1900 system (Excel's leap day of 1900 is
  # behind that), 1904-01-01 in the 1904 one
  var z = days + (if date1904: 1462 else: 0) - 25569 + 719468   # days from 0000-03-01
  let era = (if z >= 0: z else: z - 146096) div 146097
  let doe = z - era * 146097
  let yoe = (doe - doe div 1460 + doe div 36524 - doe div 146096) div 365
  var y = yoe + era * 400
  let doy = doe - (365 * yoe + yoe div 4 - yoe div 100)
  let mp = (5 * doy + 2) div 153
  let d = doy - (153 * mp + 2) div 5 + 1
  let m = if mp < 10: mp + 3 else: mp - 9
  if m <= 2: inc y
  result = align($y, 4, '0') & "-" & align($m, 2, '0') & "-" & align($d, 2, '0')
  let mins = int(round(frac * 1440))
  if mins > 0 and mins < 1440:
    result.add " " & align($(mins div 60), 2, '0') & ":" & align($(mins mod 60), 2, '0')

proc cleanNumber(s: string): string =
  ## "350.00000000000006" -> "350", "0.1" stays; anything else as it is.
  try:
    let v = parseFloat(s)
    if v.isNaN or v.classify == fcInf: return s
    if v == round(v) and abs(v) < 1e15: return $int64(v)
    result = formatFloat(v, ffDecimal, 10)
    result.trimZeros()
    if result.endsWith("."): result.setLen(result.len - 1)
  except ValueError:
    result = s

proc parser(xml: string): XmlParser =
  var s = newStringStream(xml)
  result.open(s, "xlsx", {reportWhitespace})
  result.next()

proc attrOf(x: var XmlParser; name: string): string =
  ## The attribute `name` of the element being opened (moves past them).
  result = ""
  while true:
    x.next()
    case x.kind
    of xmlAttribute:
      if x.attrKey == name or x.attrKey.endsWith(":" & name): result = x.attrValue
    else: break

proc attrsOf(x: var XmlParser): Table[string, string] =
  ## All attributes of the element being opened (moves past them); names
  ## without their namespace prefix.
  while true:
    x.next()
    if x.kind != xmlAttribute: break
    let k = x.attrKey
    let c = k.find(':')
    result[if c >= 0: k[c + 1 .. ^1] else: k] = x.attrValue

proc localName(s: string): string =
  let c = s.find(':')
  if c >= 0: s[c + 1 .. ^1] else: s

proc textUntil(x: var XmlParser; tag: string): string =
  ## The text inside the element `tag` just opened (its <t> parts, as in
  ## a rich text string; phonetic <rPh> runs left out).
  var inT = false
  var skip = 0
  while x.kind != xmlEof:
    case x.kind
    of xmlElementStart, xmlElementOpen:
      let n = localName(x.elementName)
      if n == "rPh": inc skip
      elif n == "t": inT = true
    of xmlElementEnd:
      let n = localName(x.elementName)
      if n == "rPh": dec skip
      elif n == "t": inT = false
      elif n == tag: return
    of xmlCharData, xmlWhitespace, xmlCData:
      if inT and skip == 0: result.add x.charData
    of xmlEntity:
      if inT and skip == 0: result.add x.entityName   # (parsexml decodes the common ones)
    else: discard
    x.next()

proc sharedStrings(xml: string): seq[string] =
  var x = parser(xml)
  while x.kind != xmlEof:
    if x.kind in {xmlElementStart, xmlElementOpen} and localName(x.elementName) == "si":
      x.next()
      result.add textUntil(x, "si")
    x.next()

proc dateStyles(xml: string): seq[bool] =
  ## For each cell style (cellXfs index): does it show a date?
  var custom: Table[int, bool]
  var x = parser(xml)
  var inXfs = false
  while x.kind != xmlEof:
    case x.kind
    of xmlElementOpen:
      let n = localName(x.elementName)
      if n == "numFmt":
        let a = attrsOf(x)
        try: custom[parseInt(a.getOrDefault("numFmtId", "-1"))] = isDateFormat(a.getOrDefault("formatCode"))
        except ValueError: discard
        continue
      elif n == "xf" and inXfs:
        let a = attrsOf(x)
        var id = 0
        try: id = parseInt(a.getOrDefault("numFmtId", "0"))
        except ValueError: discard
        result.add(builtinDate(id) or custom.getOrDefault(id, false))
        continue
      elif n == "cellXfs": inXfs = true
    of xmlElementStart:
      let n = localName(x.elementName)
      if n == "cellXfs": inXfs = true
      elif n == "xf" and inXfs: result.add false
    of xmlElementEnd:
      if localName(x.elementName) == "cellXfs": inXfs = false
    else: discard
    x.next()

proc readSheet(xml: string; strings: seq[string]; dates: seq[bool];
               date1904: bool; maxRows: int; rtl: var bool): seq[seq[string]] =
  var x = parser(xml)
  var row: seq[string]
  var rowAt = -1
  var inRow = false
  while x.kind != xmlEof:
    case x.kind
    of xmlElementOpen, xmlElementStart:
      let n = localName(x.elementName)
      if n == "sheetView" and x.kind == xmlElementOpen:
        if attrsOf(x).getOrDefault("rightToLeft") in ["1", "true"]: rtl = true
        continue
      if n == "row":
        inRow = true
        row.setLen(0)
        var r = -1
        if x.kind == xmlElementOpen:
          let a = attrsOf(x)
          try: r = parseInt(a.getOrDefault("r", "-1")) - 1
          except ValueError: discard
        rowAt = if r >= 0 and r < maxRows * 4: r else: result.len
        continue
      elif n == "c" and inRow:
        var a: Table[string, string]
        if x.kind == xmlElementOpen: a = attrsOf(x) else: x.next()
        var col = colIndex(a.getOrDefault("r"))
        if col < 0: col = row.len
        let t = a.getOrDefault("t", "n")
        var style = -1
        try: style = parseInt(a.getOrDefault("s", "-1"))
        except ValueError: discard
        # the value: <v>, or the text of an inline string
        var v = ""
        var got = false
        while x.kind != xmlEof:
          if x.kind == xmlElementEnd and localName(x.elementName) == "c": break
          if x.kind in {xmlElementStart, xmlElementOpen}:
            let k = localName(x.elementName)
            if k == "v":
              x.next()
              while x.kind in {xmlCharData, xmlWhitespace, xmlEntity, xmlCData}:
                v.add(if x.kind == xmlEntity: x.entityName else: x.charData)
                x.next()
              got = true
              continue
            elif k == "is":
              x.next()
              v = textUntil(x, "is")
              got = true
          x.next()
        if got:
          let text =
            case t
            of "s":
              var i = -1
              try: i = parseInt(v.strip)
              except ValueError: discard
              if i >= 0 and i < strings.len: strings[i] else: ""
            of "b": (if v.strip == "1": "TRUE" else: "FALSE")
            of "str", "inlineStr", "e", "d": v
            else:
              if style >= 0 and style < dates.len and dates[style]:
                var f = NaN
                try: f = parseFloat(v.strip)
                except ValueError: discard
                let d = serialToDate(f, date1904)
                if d.len > 0: d else: cleanNumber(v.strip)
              else: cleanNumber(v.strip)
          if text.len > 0:
            while row.len <= col: row.add ""
            row[col] = text
      x.next()
      continue
    of xmlElementEnd:
      if localName(x.elementName) == "row" and inRow:
        inRow = false
        if rowAt < maxRows:
          while result.len < rowAt: result.add @[]
          if result.len == rowAt: result.add row
          else: result[rowAt] = row
    else: discard
    x.next()
  # (trailing empty rows go)
  while result.len > 0 and result[^1].len == 0: result.setLen(result.len - 1)

proc entryText(path: string; entries: seq[ZipEntry]; name: string): string =
  let want = name.strip(chars = {'/'})
  for e in entries:
    if cmpIgnoreCase(e.name, want) == 0: return readEntry(path, e)
  ""

proc readXlsx*(path: string; maxRows = 200_000): seq[XlsxSheet] =
  ## The sheets of the workbook `path`, in their order, with their cells as
  ## text (see the module). Raises `XlsxError` when it is not a workbook.
  if not fileExists(path): raise newException(XlsxError, "cannot open " & path)
  var entries: seq[ZipEntry]
  try: entries = zipEntries(path)
  except ZipError as e: raise newException(XlsxError, path.extractFilename & " is not an Excel file (" & e.msg & ")")
  try:
    let book = entryText(path, entries, "xl/workbook.xml")
    if book.len == 0: raise newException(XlsxError, path.extractFilename & " is not an Excel workbook")
    let rels = entryText(path, entries, "xl/_rels/workbook.xml.rels")
    let strings = sharedStrings(entryText(path, entries, "xl/sharedStrings.xml"))
    let dates = dateStyles(entryText(path, entries, "xl/styles.xml"))
    # the relationships: id -> target
    var targets: Table[string, string]
    var x = parser(rels)
    while x.kind != xmlEof:
      if x.kind == xmlElementOpen and localName(x.elementName) == "Relationship":
        let a = attrsOf(x)
        targets[a.getOrDefault("Id")] = a.getOrDefault("Target")
        continue
      x.next()
    # the sheets, in order
    var date1904 = false
    x = parser(book)
    var sheets: seq[(string, string)]
    while x.kind != xmlEof:
      if x.kind == xmlElementOpen:
        let n = localName(x.elementName)
        if n == "workbookPr":
          let a = attrsOf(x)
          date1904 = a.getOrDefault("date1904") in ["1", "true"]
          continue
        elif n == "sheet":
          let a = attrsOf(x)
          sheets.add (a.getOrDefault("name"), targets.getOrDefault(a.getOrDefault("id")))
          continue
      x.next()
    for (name, target) in sheets:
      if target.len == 0: continue
      let p = if target.startsWith("/"): target else: "xl/" & target
      let xml = entryText(path, entries, p)
      if xml.len == 0: continue
      var rtl = false
      let rows = readSheet(xml, strings, dates, date1904, maxRows, rtl)
      result.add XlsxSheet(name: name, rows: rows, direction: if rtl: sdRtl else: sdLtr)
  except ZipError as e:
    raise newException(XlsxError, path.extractFilename & ": " & e.msg)
  except IOError, OSError:
    raise newException(XlsxError, "cannot read " & path.extractFilename)
  except ValueError as e:
    raise newException(XlsxError, path.extractFilename & ": " & e.msg)

proc readsRtl*(sh: XlsxSheet): bool =
  ## Whether sheet `sh` reads right to left: its `direction`, or (`sdAuto`)
  ## its first cell with letters, row by row, begins with an Arabic or
  ## Hebrew one.
  case sh.direction
  of sdRtl: return true
  of sdLtr: return false
  of sdAuto: discard
  for row in sh.rows:
    for cell in row:
      for r in cell.runes:
        let c = int(r)
        if c in 0x0590 .. 0x08FF or c in 0xFB1D .. 0xFDFF or c in 0xFE70 .. 0xFEFC:
          if c notin 0x0660 .. 0x066C and c notin 0x06F0 .. 0x06F9 and c notin 0x0600 .. 0x060F:
            return true             # (an Arabic letter, not a digit or a sign)
        elif r.isAlpha: return false
  false

proc writeXlsx*(path: string; sheets: openArray[XlsxSheet]) =
  ## A plain workbook of `sheets` (text and numbers; the first row bold
  ## is left to the reader): for exporting lists back to Excel. A sheet
  ## that reads right to left (`readsRtl`: an Arabic one) opens so, column
  ## A at the right.
  proc esc(s: string): string =
    for c in s:
      case c
      of '&': result.add "&amp;"
      of '<': result.add "&lt;"
      of '>': result.add "&gt;"
      of '"': result.add "&quot;"
      else:
        if ord(c) >= 32 or c in {'\t', '\n', '\r'}: result.add c
  proc colName(i: int): string =
    var n = i + 1
    while n > 0:
      let r = (n - 1) mod 26
      result.insert($chr(ord('A') + r), 0)
      n = (n - 1) div 26
  var z = newZipWriter()
  var ct = """<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>
<Default Extension="xml" ContentType="application/xml"/>
<Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/>
"""
  var book = """<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"><sheets>"""
  var rels = """<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">"""
  for i, sh in sheets:
    let n = i + 1
    ct.add "<Override PartName=\"/xl/worksheets/sheet" & $n & ".xml\" ContentType=\"application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml\"/>\n"
    book.add "<sheet name=\"" & esc(if sh.name.len > 0: sh.name[0 ..< min(31, sh.name.len)] else: "Sheet" & $n) &
             "\" sheetId=\"" & $n & "\" r:id=\"rId" & $n & "\"/>"
    rels.add "<Relationship Id=\"rId" & $n & "\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet\" Target=\"worksheets/sheet" & $n & ".xml\"/>"
    var xml = """<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">"""
    if sh.readsRtl: xml.add """<sheetViews><sheetView rightToLeft="1" workbookViewId="0"/></sheetViews>"""
    xml.add "<sheetData>"
    for r, row in sh.rows:
      xml.add "<row r=\"" & $(r + 1) & "\">"
      for c, cell in row:
        if cell.len == 0: continue
        let refs = colName(c) & $(r + 1)
        var isNum = false
        try:
          discard parseFloat(cell)
          isNum = cell.len < 16 and cell[0] != '0' or cell == "0" or cell.startsWith("0.")
        except ValueError: discard
        if isNum: xml.add "<c r=\"" & refs & "\"><v>" & cell & "</v></c>"
        else: xml.add "<c r=\"" & refs & "\" t=\"inlineStr\"><is><t xml:space=\"preserve\">" & esc(cell) & "</t></is></c>"
      xml.add "</row>"
    xml.add "</sheetData></worksheet>"
    z.addFile("xl/worksheets/sheet" & $n & ".xml", xml)
  ct.add "</Types>"
  book.add "</sheets></workbook>"
  rels.add "</Relationships>"
  z.addFile("[Content_Types].xml", ct)
  z.addFile("_rels/.rels", """<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/></Relationships>""")
  z.addFile("xl/workbook.xml", book)
  z.addFile("xl/_rels/workbook.xml.rels", rels)
  writeFile(path, z.finish())
