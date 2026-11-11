## Importing Excel and CSV sheets, smartly: the header row is found under
## any title rows, each column is matched to a field by its header (in
## English or Arabic, with short forms and typos) and by what its values
## look like, the hotel by the sheet's or file's name, and each row to an
## employee by number, civil ID, passport or name. What is not sure is
## asked; what differs is shown; nothing is lost (unknown columns become
## extra fields).
##
## Developed by Sultan Al Isaiee @foxoman -- www.foxoman.net -- sultan@foxoman.net

import std/[strutils, tables, os, math, sets, sequtils]
from std/unicode import runes
import retroui/[xlsx, templates]
from retroui/charts import parseCsv
import model

type
  ColMap* = object
    header*: string
    samples*: string           ## the first values, for the screen
    field*: string             ## a field key; "" skip; "+" a new extra field, "+$" a new allowance
    sure*: float
    why*: string

  SheetIn* = object
    file*, sheet*: string
    rows*: seq[seq[string]]
    headerRow*: int
    cols*: seq[ColMap]
    hotel*: string             ## the hotel of all its rows ("" per row / unknown)
    hotelWhy*: string
    looksLike*: string
    use*: bool
    remembered*: bool
    dataRows*: int

  RowMatch* = object
    sheet*, row*: int
    emp*: int                  ## index in the book's employees; -1: a new person
    how*: string
    sure*: float
    use*: bool
    hotel*: string             ## a new person's hotel when the sheet does not say
    sameAs*: int               ## a new person met in an earlier row (its match), or -1

  Question* = object
    kind*: string              ## "person" (same person?) or "value" (they differ)
    match*: int                ## index in `matches`
    field*: string
    current*, incoming*: string
    take*: bool                ## person: they are the same; value: take the sheet's

  Plan* = object
    sheets*: seq[SheetIn]
    matches*: seq[RowMatch]
    questions*: seq[Question]
    fills*, newPeople*, matched*: int
    errors*: seq[string]

  ImportResult* = object
    updated*, added*, filled*, changed*, newFields*: int
    newNames*: seq[string]       ## the fields made ("Phone Allowance (an allowance)")

# ---- reading files ----------------------------------------------------------------------------

proc readSheets*(path: string; errors: var seq[string]): seq[SheetIn] =
  ## The sheets of an .xlsx or .csv file (an old .xls cannot be read:
  ## Excel saves it as .xlsx).
  let ext = path.splitFile.ext.toLowerAscii
  let file = path.extractFilename
  try:
    case ext
    of ".xlsx", ".xlsm":
      for s in readXlsx(path):
        result.add SheetIn(file: file, sheet: s.name, rows: s.rows, use: true)
    of ".csv", ".txt", ".tsv":
      let t = parseCsv(readFile(path), header = false)
      if t.error.len > 0: errors.add file & ": " & t.error
      else: result.add SheetIn(file: file, sheet: "", rows: t.rows, use: true)
    of ".xls":
      errors.add file & ": the old Excel format (.xls) -- open it in Excel and save it as .xlsx"
    else:
      errors.add file & ": not an Excel (.xlsx) or CSV file"
  except XlsxError as e: errors.add e.msg
  except IOError, OSError: errors.add "cannot read " & file

# ---- what a value looks like -------------------------------------------------------------------

proc isDigits(s: string): bool =
  s.len > 0 and s.allCharsInSet({'0'..'9'})

proc looksDate(s: string): bool = parseDateText(s).ok and s.len >= 6
proc looksNumber(s: string): bool =
  let t = s.replace(",", "").strip
  if t.len == 0: return false
  try:
    discard parseFloat(t)
    true
  except ValueError: false
proc looksMoney(s: string): bool =
  looksNumber(s) and (let v = num(s); v >= 50 and v < 100000)
proc looksPhone(s: string): bool =
  ## An Omani phone number: 8 digits starting with 2, 7 or 9, or any 8
  ## digits written after the country code (+968 or 00968).
  if s.contains('.'): return false
  var d = ""
  for c in s:
    if c in {'0'..'9'}: d.add c
  let t = s.strip
  if (t.startsWith("+968") and d.len == 11) or (t.startsWith("00968") and d.len == 13): return true
  if d.startsWith("968") and d.len == 11: d = d[3 .. ^1]
  d.len == 8 and d[0] in {'7', '9', '2'}
proc looksEmail(s: string): bool = '@' in s and '.' in s and ' ' notin s.strip
proc looksIban(s: string): bool =
  let t = s.replace(" ", "").toUpperAscii
  (t.len >= 15 and t[0 .. 1] == "OM" and t[2 .. 3].isDigits) or (t.len >= 10 and t.len <= 20 and t.isDigits)
proc looksCivil(s: string): bool = s.strip.isDigits and s.strip.len in 6 .. 9
proc looksPassport(s: string): bool =
  let t = s.strip.toUpperAscii
  t.len in 6 .. 10 and t[0] in {'A'..'Z'} and t[^1] in {'0'..'9'} and t[1 .. ^1].replace(" ", "").isDigits
proc hasArabic(s: string): bool =
  for r in s.runes:
    if int(r) in 0x0600 .. 0x06FF: return true
proc looksName(s: string): bool =
  let t = s.strip
  if t.len < 4 or looksNumber(t) or looksDate(t): return false
  var words = 0
  for w in t.splitWhitespace:
    if w.len >= 2: inc words
  words >= 2 and not hasArabic(t)

type Profile = object
  n: int
  dates, numbers, money, phones, emails, ibans, civil, passports, names, arabic, serial: float
  kinds: int

proc profile(vals: seq[string]): Profile =
  var seen = initHashSet[string]()
  var prev = NaN
  var steps = 0
  for v in vals:
    let s = v.strip
    if s.len == 0: continue
    inc result.n
    seen.incl s
    if looksDate(s) and not looksNumber(s): result.dates += 1
    if looksNumber(s): result.numbers += 1
    if looksMoney(s): result.money += 1
    if looksPhone(s): result.phones += 1
    if looksEmail(s): result.emails += 1
    if looksIban(s) and not looksPhone(s): result.ibans += 1
    if looksCivil(s): result.civil += 1
    if looksPassport(s): result.passports += 1
    if looksName(s): result.names += 1
    if hasArabic(s): result.arabic += 1
    let x = num(s)
    if not x.isNaN and not prev.isNaN and x == prev + 1: inc steps
    prev = x
  result.kinds = seen.len
  if result.n > 0:
    let n = float(result.n)
    result.dates /= n; result.numbers /= n; result.money /= n; result.phones /= n
    result.emails /= n; result.ibans /= n; result.civil /= n; result.passports /= n
    result.names /= n; result.arabic /= n
    result.serial = float(steps) / max(1.0, n - 1)

# ---- matching a column to a field -----------------------------------------------------------------

proc words(s: string): seq[string] =
  for w in s.toLowerAscii.split({' ', '.', '_', '-', '/', '(', ')', '#', ':', '\t'}):
    if w.len > 0: result.add w

proc lev(a, b: string): int =
  ## Edit distance (for typos in headers: "Nationalty").
  if a.len == 0: return b.len
  if b.len == 0: return a.len
  var prev = newSeq[int](b.len + 1)
  var cur = newSeq[int](b.len + 1)
  for j in 0 .. b.len: prev[j] = j
  for i in 1 .. a.len:
    cur[0] = i
    for j in 1 .. b.len:
      cur[j] = min(min(prev[j] + 1, cur[j - 1] + 1), prev[j - 1] + ord(a[i - 1] != b[j - 1]))
    swap(prev, cur)
  prev[b.len]

proc headerScore(header, name: string): float =
  let a = tagKey(header)
  let b = tagKey(name)
  if a.len == 0 or b.len == 0: return 0
  if a == b: return 1.0
  if a.len >= 4 and b.len >= 4:
    let d = lev(a, b)
    if d <= max(1, min(a.len, b.len) div 6): return 0.9
  let wa = words(header)
  let wb = words(name)
  if wa.len > 0 and wb.len > 0:
    var common = 0
    for w in wa:
      if w in wb: inc common
    if common > 0:
      let j = float(common) / float(max(wa.len, wb.len))
      if j >= 0.99: return 0.95
      if j >= 0.5: return 0.7
  if (a.len >= 4 and b.contains(a)) or (b.len >= 4 and a.contains(b)): return 0.6
  0

const totalHeaders = ["total", "totalsalary", "gross", "grosssalary", "totalpay", "net", "netsalary",
                      "netpay", "grandtotal", "الإجمالي", "الاجمالي", "المجموع", "إجماليالراتب",
                      "اجماليالراتب", "الراتبالإجمالي", "صافيالراتب"]
const serialHeaders = ["sno", "sn", "sr", "srno", "sl", "slno", "serial", "no", "", "م", "مسلسل", "رقم"]

proc matchHeader*(b: Book; header: string): tuple[field: string; sure: float; why: string] =
  ## The field a column is, from its header alone.
  result = ("", 0.0, "")
  for f in b.fields:
    if f.hidden: continue
    var names = @[f.label, f.labelAr, f.key]
    for x in f.also: names.add x
    for n in names:
      let s = headerScore(header, n)
      if s > result.sure:
        result = (f.key, s, if s >= 1.0: "the header" elif s >= 0.9: "the header (spelt a little differently)"
                            else: "a header like \"" & n & "\"")

proc guessFromValues(b: Book; p: Profile; header: string): tuple[field: string; sure: float; why: string] =
  if p.n == 0: return ("", 1.0, "empty column")
  if p.serial > 0.8 and p.numbers > 0.95: return ("", 0.9, "a row counter (1, 2, 3...)")
  if p.emails > 0.7: return ("email", 0.85, "the values are e-mail addresses")
  if p.ibans > 0.7: return ("iban", 0.75, "the values look like IBANs")
  if p.phones > 0.7: return ("phone", 0.8, "the values are Omani phone numbers")
  if p.passports > 0.7: return ("passportNo", 0.75, "a letter and digits, as passport numbers")
  if p.names > 0.7: return ("nameEn", 0.7, "the values are names")
  if p.arabic > 0.7 and p.kinds > max(2, p.n div 2): return ("nameAr", 0.6, "Arabic names")
  ("", 0.0, "")

proc allowanceHeader(h: string): bool =
  ## "Phone Allowance", "Food allow.", "بدل هاتف", "علاوة"...
  let t = h.toLowerAscii
  for w in ["allowance", "allow.", "allow ", "allw", "بدل", "علاوة", "علاوه"]:
    if w in t: return true
  t.endsWith("allow")

proc valuesOf(s: SheetIn; col: int; limit = 40): seq[string] =
  for r in s.headerRow + 1 ..< s.rows.len:
    if col < s.rows[r].len and s.rows[r][col].strip.len > 0:
      result.add s.rows[r][col]
      if result.len >= limit: break

proc findHeaderRow(b: Book; s: var SheetIn) =
  ## The row with the most cells that look like headers of known fields
  ## (title rows above it are left out).
  var best = -1.0
  s.headerRow = 0
  for r in 0 ..< min(20, s.rows.len):
    var score = 0.0
    var cells = 0
    for c in s.rows[r]:
      let t = c.strip
      if t.len == 0: continue
      inc cells
      if looksNumber(t) or looksDate(t): score -= 0.5
      else:
        score += 0.3
        if matchHeader(b, t).sure >= 0.6: score += 2
    if cells >= 2 and score > best:
      best = score
      s.headerRow = r

proc layoutKey(headers: seq[string]): string =
  var ks: seq[string]
  for h in headers: ks.add tagKey(h)
  ks.join("|")

proc headersOf*(s: SheetIn): seq[string] =
  if s.headerRow < s.rows.len:
    for i, c in s.rows[s.headerRow]: result.add c.strip
  var w = 0
  for r in s.rows: w = max(w, r.len)
  while result.len < w: result.add ""
  for i in 0 ..< result.len:
    if result[i].len == 0:
      var col = ""
      var n = i + 1
      while n > 0:
        col.insert($chr(ord('A') + (n - 1) mod 26), 0)
        n = (n - 1) div 26
      result[i] = "Col " & col

proc matchHotel(b: Book; text: string): int =
  ## A hotel named in `text` (a sheet or file name, a cell): by its name,
  ## Arabic name, code, or a word of its name.
  let t = text.toLowerAscii
  if t.strip.len == 0: return -1
  for i, h in b.hotels:
    if h.name.len > 0 and t.contains(h.name.toLowerAscii): return i
    if h.nameAr.len > 0 and text.contains(h.nameAr): return i
  for i, h in b.hotels:
    if h.code.len >= 2 and (t == h.code.toLowerAscii or
       (" " & t & " ").contains(" " & h.code.toLowerAscii & " ")): return i
  for i, h in b.hotels:
    for w in words(h.name):
      if w.len >= 4 and w notin ["hotel", "hotels", "resort", "suites", "inn"] and t.contains(w):
        return i
  -1

proc analyze*(b: Book; s: var SheetIn) =
  ## Finds the header row, the field of each column, the hotel and what
  ## the sheet seems to be.
  findHeaderRow(b, s)
  let headers = headersOf(s)
  s.cols.setLen(0)
  # a layout the user confirmed before
  let key = layoutKey(headers)
  var layout = -1
  for i, l in b.layouts:
    if l.headers == key: layout = i
  s.remembered = layout >= 0
  for c, h in headers:
    let vals = valuesOf(s, c)
    var m = ColMap(header: h, samples: vals[0 ..< min(3, vals.len)].join(", "))
    if layout >= 0:
      m.field = b.layouts[layout].map.getOrDefault(tagKey(h))
      m.sure = 1.0
      m.why = "remembered from \"" & b.layouts[layout].name & "\""
      s.cols.add m
      continue
    let p = profile(vals)
    var (f, sure, why) = matchHeader(b, h)
    if tagKey(h) in serialHeaders and p.serial > 0.5:
      (f, sure, why) = ("", 0.9, "a row counter (1, 2, 3...)")
    elif tagKey(h) in totalHeaders and (f.len == 0 or b.field(f).kind == fkMoney) and p.numbers >= 0.6:
      (f, sure, why) = ("", 0.9, "a total: HR Book adds up the salary itself")
    elif p.n == 0:
      (f, sure, why) = ("", 1.0, "empty column")
    elif sure < 0.6:
      let g = guessFromValues(b, p, h)
      if g.sure > sure: (f, sure, why) = g
    else:
      # the values agree with the header?
      let fk = b.field(f).kind
      if fk == fkDate and p.dates < 0.5: sure *= 0.6; why.add ", but the values are not dates"
      elif fk == fkMoney and p.numbers < 0.6: sure *= 0.6; why.add ", but the values are not amounts"
      elif fk == fkDate and p.dates >= 0.8: why.add " and the values are dates"
      elif fk == fkMoney and p.numbers >= 0.8: why.add " and the values are amounts"
      # values with a shape of their own
      let shape = case f
                  of "phone": p.phones
                  of "email": p.emails
                  of "iban": p.ibans
                  of "civilId": max(p.civil, p.numbers)
                  of "passportNo": p.passports
                  else: 1.0
      if shape < 0.5:
        sure *= 0.5
        why.add ", but the values do not look like it"
    # an allowance HR Book does not have yet: a new one, counted in the total
    if allowanceHeader(h) and p.numbers >= 0.6 and (f.len == 0 or sure < 0.6 or
       b.field(f).kind != fkMoney):
      (f, sure, why) = ("+$", 0.8, "a new allowance (amounts): added to the salary")
    if f.len == 0 and p.n > 0 and sure < 0.6:
      (f, sure, why) = ("+", 0.6, "not known: kept as an extra field")
    m.field = f
    m.sure = sure
    m.why = why
    s.cols.add m
  # one column per field: the surest keeps it
  for i in 0 ..< s.cols.len:
    let f = s.cols[i].field
    if f.len == 0 or f.startsWith("+"): continue
    for j in i + 1 ..< s.cols.len:
      if s.cols[j].field == f:
        let lose = if s.cols[j].sure > s.cols[i].sure: i else: j
        s.cols[lose].field = "+"
        s.cols[lose].sure = 0.5
        s.cols[lose].why = "another column is \"" & b.field(f).label & "\": kept as an extra field"
  # the hotel: a column, or the sheet's / file's name
  var hotelCol = false
  for c in s.cols:
    if c.field == "hotel": hotelCol = true
  s.hotel = ""
  s.hotelWhy = ""
  if hotelCol:
    s.hotelWhy = "from its Hotel column"
  else:
    var i = matchHotel(b, s.sheet)
    var src = "the sheet's name"
    if i < 0:
      i = matchHotel(b, s.file)
      src = "the file's name"
    if i < 0 and s.headerRow > 0:
      for r in 0 ..< s.headerRow:
        for c in s.rows[r]:
          if i < 0:
            i = matchHotel(b, c)
            src = "the title"
    if i >= 0:
      s.hotel = b.hotels[i].id
      s.hotelWhy = "from " & src
    elif b.hotels.len == 1:
      s.hotel = b.hotels[0].id
      s.hotelWhy = "the only hotel"
  # what it looks like
  var fields = initHashSet[string]()
  for c in s.cols:
    if c.field.len > 0: fields.incl c.field
  s.looksLike =
    if "basic" in fields or "housing" in fields: "Payroll"
    elif "visaExpiry" in fields or "passportExpiry" in fields or "civilIdExpiry" in fields:
      "Documents and expiry dates"
    elif "department" in fields and ("nameEn" in fields or "nameAr" in fields): "Staff list"
    elif "nameEn" in fields or "empNo" in fields: "Employee details"
    else: "Extra fields only"
  if s.remembered: s.looksLike = b.layouts[layout].name & " (seen before)"
  s.dataRows = 0
  for r in s.headerRow + 1 ..< s.rows.len:
    if s.rows[r].len > 0: inc s.dataRows

# ---- matching rows to people -----------------------------------------------------------------------

proc colOf(s: SheetIn; field: string): int =
  for i, c in s.cols:
    if c.field == field: return i
  -1

proc cell(s: SheetIn; r, c: int): string =
  if c >= 0 and c < s.rows[r].len: s.rows[r][c].strip else: ""

proc normNo(s: string): string = s.toUpperAscii.replace(" ", "").replace("-", "").replace("/", "")
proc digitsOf(s: string): string =
  result = ""         # (a value at once: see tools/writecheck.py)
  for c in s:
    if c in {'0'..'9'}: result.add c
  result = result.strip(trailing = false, chars = {'0'})
proc normName(s: string): string =
  var ws: seq[string]
  for w in s.toLowerAscii.multiReplace(("-", " "), (".", " "), ("'", "")).splitWhitespace:
    if w notin ["al", "bin", "bint", "el"]: ws.add w
  ws.join(" ")
proc nameSim(a, b: string): float =
  let wa = normName(a).splitWhitespace
  let wb = normName(b).splitWhitespace
  if wa.len == 0 or wb.len == 0: return 0
  var common = 0
  for w in wa:
    for x in wb:
      if w == x or (w.len == 1 and x.startsWith(w)) or (x.len == 1 and w.startsWith(x)):
        inc common
        break
  float(common) / float(max(wa.len, wb.len))

proc isTotalRow(s: SheetIn; r: int): bool =
  for c in s.rows[r]:
    let t = c.strip.toLowerAscii
    if t in ["total", "grand total", "totals", "sub total", "subtotal", "المجموع", "الإجمالي"]:
      return true

proc rowHotel*(b: Book; s: SheetIn; r: int): string =
  let hc = colOf(s, "hotel")
  if hc >= 0:
    let i = matchHotel(b, cell(s, r, hc))
    if i >= 0: return b.hotels[i].id
  s.hotel

proc sameValue(b: Book; f: FieldDef; cur, incoming: string): bool =
  ## The sheet's value says what the book has (in another form: a date
  ## written differently, a number without its letters, a shorter name).
  case f.kind
  of fkMoney, fkNumber: result = abs(num(cur) - num(incoming)) < 0.0005
  of fkDate: result = isoDate(cur) == isoDate(incoming)
  of fkHotel:
    let i = matchHotel(b, incoming)
    result = (i >= 0 and b.hotels[i].id == cur) or cmpIgnoreCase(b.hotelName(cur), incoming) == 0
  else: result = cmpIgnoreCase(cur.strip, incoming.strip) == 0
  if result or cur.len == 0: return
  if f.key == "empNo" and digitsOf(cur) == digitsOf(incoming) and
     normNo(cur).endsWith(normNo(incoming)): return true
  if f.key == "nameEn" and nameSim(cur, incoming) >= 0.75: return true
  if f.key == "phone":
    var a, c = ""
    for ch in cur:
      if ch in {'0'..'9'}: a.add ch
    for ch in incoming:
      if ch in {'0'..'9'}: c.add ch
    if a.len >= 7 and c.len >= 7 and (a.endsWith(c) or c.endsWith(a)): return true

type Seen = object
  mi, sheet: int
  no, civil, pass, nm, nmAr, hotel: string

proc samePerson(a, b: Seen): bool =
  ## Two rows (of different sheets) that are one new person.
  if a.civil.len > 0 and b.civil.len > 0: return a.civil.strip == b.civil.strip
  if a.pass.len > 0 and b.pass.len > 0 and normNo(a.pass) == normNo(b.pass): return true
  let hotelOk = a.hotel.len == 0 or b.hotel.len == 0 or a.hotel == b.hotel
  let names = if a.nm.len > 0 and b.nm.len > 0: nameSim(a.nm, b.nm)
              elif a.nmAr.len > 0 and b.nmAr.len > 0: (if a.nmAr.strip == b.nmAr.strip: 1.0 else: 0.0)
              else: -1.0
  if a.no.len > 0 and b.no.len > 0 and hotelOk:
    if normNo(a.no) == normNo(b.no): return names < 0 or names >= 0.5
    let d = digitsOf(a.no)
    if d.len >= 2 and d == digitsOf(b.no): return names >= 0.5
  hotelOk and names >= 0.75 and (a.no.len == 0 or b.no.len == 0)

proc matchRows*(b: Book; plan: var Plan) =
  ## Each data row to an employee (or a new one), and the questions: the
  ## people that are not sure, and the values that differ.
  plan.matches.setLen(0)
  plan.questions.setLen(0)
  plan.fills = 0
  plan.newPeople = 0
  plan.matched = 0
  var seen: seq[Seen]              # the new people so far, to meet them again
  for si, s in plan.sheets:
    if not s.use: continue
    let cNo = colOf(s, "empNo")
    let cCivil = colOf(s, "civilId")
    let cPass = colOf(s, "passportNo")
    let cName = colOf(s, "nameEn")
    let cNameAr = colOf(s, "nameAr")
    var taken = initHashSet[int]()
    for r in s.headerRow + 1 ..< s.rows.len:
      if s.rows[r].len == 0 or isTotalRow(s, r): continue
      let no = cell(s, r, cNo)
      let civil = cell(s, r, cCivil)
      let pass = cell(s, r, cPass)
      let nm = cell(s, r, cName)
      let nmAr = cell(s, r, cNameAr)
      if no.len == 0 and civil.len == 0 and pass.len == 0 and nm.len == 0 and nmAr.len == 0:
        continue
      let hotel = rowHotel(b, s, r)
      var m = RowMatch(sheet: si, row: r, emp: -1, use: true, sameAs: -1)
      template tryFind(howV: string; sureV: float; cond: untyped) =
        if m.emp < 0:
          for i, it {.inject.} in b.employees:
            if it.deleted or i in taken: continue
            if cond:
              m.emp = i
              m.how = howV
              m.sure = sureV
              break
      # how much the names say it is the same person: 1 yes, 0 not at all,
      # -1 nothing to compare
      proc nameAgrees(it: Employee): float =
        if nm.len > 0 and it.get("nameEn").len > 0:
          return max(nameSim(it.get("nameEn"), nm),
                     if nmAr.len > 0 and it.get("nameAr").strip == nmAr: 1.0 else: 0.0)
        if nmAr.len > 0 and it.get("nameAr").len > 0:
          return (if it.get("nameAr").strip == nmAr: 1.0 else: nameSim(it.get("nameAr"), nmAr))
        -1.0
      if no.len > 0:
        tryFind("employee no.", 1.0, normNo(it.get("empNo")) == normNo(no))
        let d = digitsOf(no)
        if d.len >= 2 and m.emp < 0:
          # the digits alone: only when they point at one person (or the
          # name picks one of them)
          var cands: seq[int]
          for i, it in b.employees:
            if not it.deleted and i notin taken and digitsOf(it.get("empNo")) == d and
               (hotel.len == 0 or it.get("hotel") == hotel): cands.add i
          if cands.len == 1:
            (m.emp, m.how, m.sure) = (cands[0], "employee no. (without its letters)", 0.9)
          elif cands.len > 1:
            var best = -1
            var bestSim = 0.5
            for i in cands:
              let a = nameAgrees(b.employees[i])
              if a >= bestSim: (best, bestSim) = (i, a)
            if best >= 0:
              (m.emp, m.how, m.sure) = (best, "employee no. (without its letters) and the name", 0.9)
      if civil.len > 0: tryFind("civil ID", 1.0, it.get("civilId").strip == civil)
      if pass.len > 0: tryFind("passport", 1.0, normNo(it.get("passportNo")) == normNo(pass))
      if nm.len > 0:
        tryFind("name", 0.85, normName(it.get("nameEn")) == normName(nm) and
                (hotel.len == 0 or it.get("hotel") == hotel))
        tryFind("a similar name", 0.6, nameSim(it.get("nameEn"), nm) >= 0.75 and
                (hotel.len == 0 or it.get("hotel") == hotel))
      if nmAr.len > 0:
        tryFind("Arabic name", 0.85, it.get("nameAr").strip == nmAr)
      # found by a number, but the names differ: the number may be wrong (or
      # be another person's), so ask
      var notSame = false
      if m.emp >= 0 and m.sure >= 0.9:
        let a = nameAgrees(b.employees[m.emp])
        if a >= 0 and a < 0.5:
          let other = m.emp
          m.emp = -1
          if nm.len > 0:
            tryFind("name (the no. is " & b.employees[other].name & "'s)", 0.7,
                    normName(it.get("nameEn")) == normName(nm) and
                    (hotel.len == 0 or it.get("hotel") == hotel))
          if m.emp < 0:
            (m.emp, m.how, m.sure) = (other, m.how & ", but another name", 0.5)
            notSame = a < 0.25
      # a new person (or likely one): the same as one met in another row?
      if m.emp < 0 or notSame:
        let me = Seen(no: no, civil: civil, pass: pass, nm: nm, nmAr: nmAr, hotel: hotel)
        for p in seen:
          if p.sheet != si and samePerson(p, me):
            m.sameAs = p.mi
            m.emp = -1
            m.how = "the same new person as in " & plan.sheets[p.sheet].file & ", row " &
                    $(plan.matches[p.mi].row + 1)
            m.sure = 0.9
            break
        if m.sameAs < 0:
          var me2 = me
          me2.mi = plan.matches.len
          me2.sheet = si
          seen.add me2
      if m.sameAs >= 0:
        notSame = false
      elif m.emp >= 0 and not notSame:
        taken.incl m.emp
        inc plan.matched
      elif m.emp < 0:
        m.how = "new"
        m.sure = 1.0
        inc plan.newPeople
      else:
        inc plan.newPeople
      plan.matches.add m
      let mi = plan.matches.high
      if m.emp >= 0 and m.sure < 0.9:
        plan.questions.add Question(kind: "person", match: mi, field: "",
                                    current: b.employees[m.emp].name & " (" &
                                      b.employees[m.emp].get("empNo") & ")",
                                    incoming: (if nm.len > 0: nm else: nmAr) &
                                      (if no.len > 0: " (" & no & ")" else: ""),
                                    take: not notSame)
      # the values (not for one who is likely someone else; nor the name
      # when the question is whether it is the same person)
      if m.emp >= 0 and not notSame:
        let e = b.employees[m.emp]
        for c, cm in s.cols:
          if cm.field.len == 0 or cm.field.startsWith("+"): continue
          if m.sure < 0.9 and cm.field in ["nameEn", "nameAr"]: continue
          let incoming = cell(s, r, c)
          if incoming.len == 0: continue
          let f = b.field(cm.field)
          let cur = e.get(cm.field)
          let same = sameValue(b, f, cur, incoming)
          if same: continue
          if cur.len == 0: inc plan.fills
          else:
            let shown = case f.kind
                        of fkDate: (let d = isoDate(incoming); if d.len > 0: showDate(d) else: incoming)
                        of fkMoney: b.display(f, incoming)
                        else: incoming
            # an expiry date older than the book's: the book has the renewal
            let older = f.kind == fkDate and f.expiry and isoDate(incoming).len > 0 and
                        isoDate(incoming) < isoDate(cur)
            plan.questions.add Question(kind: "value", match: mi, field: cm.field,
                                        current: b.display(f, cur), incoming: shown,
                                        take: not older)

proc newHotel*(b: Book; plan: Plan; mi: int): string =
  ## The hotel of a new person: chosen, from the row, or from another row
  ## of the same person.
  let m = plan.matches[mi]
  if m.hotel.len > 0: return m.hotel
  result = rowHotel(b, plan.sheets[m.sheet], m.row)
  if result.len > 0: return
  for o in plan.matches:
    if o.sameAs == mi:
      result = rowHotel(b, plan.sheets[o.sheet], o.row)
      if result.len > 0: return

proc isNew*(plan: Plan; mi: int): bool =
  ## Match `mi` becomes a new person: nobody found, or the user (or the
  ## guess) says the one found is someone else.
  if plan.matches[mi].sameAs >= 0: return false
  if plan.matches[mi].emp < 0: return true
  for q in plan.questions:
    if q.kind == "person" and q.match == mi and not q.take: return true

proc newPlan*(b: Book; paths: seq[string]): Plan =
  for p in paths:
    for s in readSheets(p, result.errors): result.sheets.add s
  for s in result.sheets.mitems: analyze(b, s)

# ---- putting it in ---------------------------------------------------------------------------------

proc convert(b: var Book; f: FieldDef; s: string): string =
  ## A sheet's value as the field keeps it.
  let t = s.strip
  case f.kind
  of fkDate: (let d = isoDate(t); if d.len > 0: d else: t)
  of fkMoney, fkNumber: (let v = num(t); if v.isNaN: t else: (if v == round(v): $int64(v) else: $v))
  of fkHotel:
    let i = matchHotel(b, t)
    if i >= 0: b.hotels[i].id else: t
  of fkYesNo: (if t.toLowerAscii in ["1", "yes", "y", "true", "نعم"]: "1" else: "0")
  of fkChoice:
    var v = t
    if f.key == "gender":
      let l = t.toLowerAscii
      if l in ["m", "male", "ذكر"]: v = "Male"
      elif l in ["f", "female", "أنثى", "انثى"]: v = "Female"
    if f.key == "status":
      let l = t.toLowerAscii
      if l in ["active", "yes", "working", "1", "true"]: v = "Active"
      elif l in ["left", "resigned", "terminated", "no", "0", "false", "inactive", "exit"]: v = "Left"
    if f.list.len > 0 and v.len > 0:
      var l = b.lists.getOrDefault(f.list)
      var found = false
      for x in l:
        if cmpIgnoreCase(x, v) == 0:
          v = x
          found = true
      if not found:
        l.add v
        b.lists[f.list] = l
    v
  else: t

proc apply*(b: var Book; plan: var Plan): ImportResult =
  ## Puts the plan in the book (the changes go into each person's history,
  ## with the file and sheet they came from).
  let at = nowT()
  # extra fields for the columns not known
  for s in plan.sheets.mitems:
    if not s.use: continue
    for ci in 0 ..< s.cols.len:
      template c: untyped = s.cols[ci]
      if c.field.startsWith("+"):
        var key = ""
        for f in b.fields:
          if tagKey(f.label) == tagKey(c.header) or tagKey(c.header) in f.also.mapIt(tagKey(it)):
            key = f.key
        if key.len == 0:
          key = newId("f_")
          let allowance = c.field == "+$"
          # what the values are: amounts, numbers, dates or text
          let p = profile(valuesOf(s, ci))
          let kind = if allowance: fkMoney
                     elif p.n > 0 and p.dates >= 0.8: fkDate
                     elif p.n > 0 and p.numbers >= 0.9: fkNumber
                     else: fkLine
          var label = c.header.strip
          var labelAr = if hasArabic(label): label else: ""
          if allowance:
            let n = allowanceNames(label)
            if n.en.len > 0: label = n.en
            labelAr = n.ar
            if not allowanceHeader(label): label.add " Allowance"
          b.fields.add FieldDef(key: key, label: label, labelAr: labelAr, kind: kind,
                                section: (if allowance: secSalary else: secOther),
                                inTotal: allowance, inList: false,
                                also: @[c.header], modified: at)
          inc result.newFields
          result.newNames.add label & (if allowance: " (an allowance, in the total salary)"
                                       elif kind == fkDate: " (dates)"
                                       elif kind == fkNumber: " (numbers)" else: "")
        c.field = key
  # people the user said are not the same: new people
  for q in plan.questions:
    if q.kind == "person" and not q.take:
      plan.matches[q.match].emp = -1
  var touched = initHashSet[int]()
  var madeFor = initTable[int, int]()       # match -> the employee it went to
  for mi, m in plan.matches:
    if not m.use: continue
    let s = plan.sheets[m.sheet]
    let source = s.file & (if s.sheet.len > 0: " › " & s.sheet else: "")
    var ei = m.emp
    if m.sameAs >= 0:
      # the same person as an earlier row: where that one went
      ei = madeFor.getOrDefault(m.sameAs, -1)
      if ei < 0: continue                        # (that one was not added)
    elif ei < 0:
      var e = newEmployee()
      e.v["status"] = "Active"
      let h = newHotel(b, plan, mi)
      if h.len > 0: e.v["hotel"] = h
      b.employees.add e
      ei = b.employees.high
      inc result.added
    madeFor[mi] = ei
    for c, cm in s.cols:
      if cm.field.len == 0: continue
      let raw = if c < s.rows[m.row].len: s.rows[m.row][c].strip else: ""
      if raw.len == 0: continue
      # a value the user chose to keep
      var keep = false
      for q in plan.questions:
        if q.kind == "value" and q.match == mi and q.field == cm.field and not q.take: keep = true
      if keep: continue
      let f = b.field(cm.field)
      if (m.emp >= 0 or m.sameAs >= 0) and sameValue(b, f, b.employees[ei].get(cm.field), raw): continue
      let v = convert(b, f, raw)
      let was = b.employees[ei].get(cm.field)
      if b.employees[ei].setValue(cm.field, v, source, at):
        if m.emp >= 0:
          touched.incl ei
          if was.len == 0: inc result.filled else: inc result.changed
  result.updated = touched.len
  # the layouts, remembered
  for s in plan.sheets:
    if not s.use: continue
    let key = layoutKey(headersOf(s))
    var map = initTable[string, string]()
    for c in s.cols: map[tagKey(c.header)] = c.field
    var found = false
    for l in b.layouts.mitems:
      if l.headers == key:
        l.map = map
        inc l.used
        l.modified = at
        found = true
    if not found:
      let name = if s.looksLike.endsWith("(seen before)"): s.looksLike else:
                   s.looksLike & (if s.sheet.len > 0: " (" & s.sheet & ")" else: "")
      b.layouts.add Layout(headers: key, name: name, map: map, used: 1, modified: at)
