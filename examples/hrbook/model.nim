## HR Book's data: hotels, the fields an employee has (built in, and the
## user's own), employees, groups, letter templates, and how it is all
## saved as JSON (read back tolerantly: a newer or older file still opens).
##
## Developed by Sultan Al Isaiee @foxoman -- www.foxoman.net -- sultan@foxoman.net

import std/[json, tables, strutils, times, sysrand, algorithm, math, sequtils]
import std/unicode except strip   # (its strip cuts letters: docs/nim-bugs.md)
import retroui/templates

type
  FieldKind* = enum
    fkLine = "text", fkNumber = "number", fkMoney = "money", fkDate = "date",
    fkChoice = "choice", fkYesNo = "yesno", fkLongText = "longtext", fkHotel = "hotel"
  Section* = enum
    secPersonal = "Personal", secJob = "Job", secSalary = "Salary",
    secDocuments = "Documents", secOther = "Other"

  FieldDef* = object
    key*: string               ## stable: built-in names ("basic") or "f_<random>"
    label*, labelAr*: string   ## "Housing Allowance", "بدل السكن"
    kind*: FieldKind
    section*: Section
    list*: string              ## fkChoice: the list it picks from ("departments")
    builtin*: bool             ## (renamed and hidden, never deleted)
    hidden*: bool
    inList*: bool              ## a column of the employees list
    inTotal*: bool             ## money: part of the total salary (an allowance)
    expiry*: bool              ## date: watched by Alerts
    also*: seq[string]         ## other names it has in sheets (for importing)
    modified*: float

  Hotel* = object
    id*, name*, nameAr*, code*: string
    cr*, vat*, address*, addressAr*, phone*, email*, website*: string
    color*: string             ## "#1f4e79"
    refPrefix*: string         ## "SOH/HR" -> SOH/HR/2026/007
    nextRef*: Table[string, int]   ## per year
    logo*, letterhead*, signature*, stamp*: string   ## PNG bytes ("" none)
    signer*, signerTitle*, signerAr*, signerTitleAr*: string
    modified*: float

  Group* = object
    id*, name*, color*: string
    modified*: float

  Change* = object
    at*: float
    field*, was*, now*, source*: string

  Employee* = object
    id*: string
    v*: Table[string, string]  ## field key -> value (dates "yyyy-mm-dd", numbers plain)
    groups*: seq[string]       ## group ids
    created*, modified*: float
    deleted*: bool             ## (kept, so a merge knows it was removed)
    history*: seq[Change]

  LetterLang* = enum llEnglish = "en", llArabic = "ar", llBoth = "both"
  Template* = object
    id*, name*: string
    lang*: LetterLang
    hotel*: string             ## "" = the employee's hotel
    body*: string              ## light markup with #[tags]#
    modified*: float
    deleted*: bool

  Issued* = object
    at*: float
    emp*, empName*, templ*, templName*, refNo*, hotel*: string

  Layout* = object
    ## A sheet's columns as the user confirmed them (found again by its
    ## headers next time).
    headers*: string           ## the headers' keys, joined
    name*: string              ## "Payroll", what the user saw it as
    map*: Table[string, string]   ## header key -> field key ("" skip)
    used*: int
    modified*: float

  Book* = object
    version*: int
    device*: string            ## which tablet saved it last
    savedAt*: float
    hotels*: seq[Hotel]
    fields*: seq[FieldDef]
    lists*: OrderedTable[string, seq[string]]
    arabic*: Table[string, string] ## a list value in Arabic ("Omani" -> "عماني"), for letters
    groups*: seq[Group]
    employees*: seq[Employee]
    templates*: seq[Template]
    issued*: seq[Issued]
    layouts*: seq[Layout]
    lockMinutes*: int
    hideSalaries*: bool
    lastBackup*: float

const
  BookVersion* = 1
  ListNames* = ["departments", "positions", "grades", "nationalities", "visaTypes",
                "contracts", "statuses", "genders"]
  ListTitles* = ["Departments", "Positions", "Grades", "Nationalities", "Visa types",
                 "Contract types", "Statuses", "Genders"]

proc newId*(prefix = ""): string =
  var b: array[8, byte]
  if not urandom(b):
    let t = epochTime()
    for i in 0 .. 7: b[i] = byte((int64(t * 1e6) shr (i * 8)) and 0xFF)
  result = prefix
  for x in b: result.add toHex(x, 2).toLowerAscii

proc nowT*(): float = epochTime()

# ---- the fields an employee has from the start -------------------------------------------------

proc fd(key, label, labelAr: string; kind: FieldKind; sec: Section; list = "";
        inList = false; inTotal = false; expiry = false; also: openArray[string] = []): FieldDef =
  FieldDef(key: key, label: label, labelAr: labelAr, kind: kind, section: sec, list: list,
           builtin: true, inList: inList, inTotal: inTotal, expiry: expiry, also: @also)

proc builtinFields*(): seq[FieldDef] =
  @[
    fd("empNo", "Employee No.", "الرقم الوظيفي", fkLine, secPersonal, inList = true,
       also = ["Emp No", "Staff No", "Staff ID", "Employee ID", "Emp ID", "Emp Code",
               "Employee Code", "ID No", "Badge", "Badge No", "File No", "رقم الموظف",
               "الرقم", "كود الموظف"]),
    fd("nameEn", "Name", "الاسم بالإنجليزية", fkLine, secPersonal, inList = true,
       also = ["Employee Name", "Full Name", "Staff Name", "Name (English)", "English Name",
               "Emp Name", "Name of Employee", "اسم الموظف"]),
    fd("nameAr", "Name (Arabic)", "الاسم", fkLine, secPersonal,
       also = ["Arabic Name", "الاسم", "الاسم بالعربي", "الاسم بالعربية", "اسم الموظف بالعربي"]),
    fd("gender", "Gender", "الجنس", fkChoice, secPersonal, list = "genders",
       also = ["Sex", "M/F", "النوع"]),
    fd("dob", "Date of Birth", "تاريخ الميلاد", fkDate, secPersonal,
       also = ["DOB", "Birth Date", "Birthdate", "D.O.B", "تاريخ الميلاد"]),
    fd("nationality", "Nationality", "الجنسية", fkChoice, secPersonal, list = "nationalities",
       inList = false, also = ["Country", "Nat", "Nationality", "الجنسية"]),
    fd("civilId", "Civil ID", "الرقم المدني", fkLine, secPersonal,
       also = ["Civil No", "Civil Number", "National ID", "ID Card", "ID Card No",
               "Resident Card", "RC No", "Resident Card No", "الرقم المدني", "رقم البطاقة"]),
    fd("civilIdExpiry", "Civil ID Expiry", "انتهاء البطاقة", fkDate, secDocuments, expiry = true,
       also = ["ID Expiry", "Civil Expiry", "RC Expiry", "Card Expiry", "انتهاء البطاقة"]),
    fd("passportNo", "Passport No.", "رقم الجواز", fkLine, secDocuments,
       also = ["Passport", "Passport Number", "PP No", "PP #", "Passport #", "رقم الجواز"]),
    fd("passportExpiry", "Passport Expiry", "انتهاء الجواز", fkDate, secDocuments, expiry = true,
       also = ["PP Exp", "PP Expiry", "Passport Exp", "Passport Expiry Date", "انتهاء الجواز"]),
    fd("phone", "Phone", "الهاتف", fkLine, secPersonal,
       also = ["Mobile", "Mob", "Mobile No", "GSM", "Contact No", "Tel", "Phone No", "الهاتف", "النقال"]),
    fd("email", "Email", "البريد الإلكتروني", fkLine, secPersonal, also = ["E-mail", "Mail"]),
    fd("emergency", "Emergency Contact", "جهة الاتصال للطوارئ", fkLine, secPersonal,
       also = ["Emergency", "Emergency No", "Next of Kin"]),
    fd("hotel", "Hotel", "الفندق", fkHotel, secJob, inList = true,
       also = ["Property", "Unit", "Location", "Branch", "Company", "الفندق", "الموقع"]),
    fd("department", "Department", "القسم", fkChoice, secJob, list = "departments", inList = true,
       also = ["Dept", "Dep", "Division", "Section", "القسم", "الإدارة"]),
    fd("position", "Position", "المسمى الوظيفي", fkChoice, secJob, list = "positions", inList = true,
       also = ["Job Title", "Title", "Designation", "Occupation", "Profession", "Job",
               "المسمى الوظيفي", "الوظيفة", "المهنة"]),
    fd("grade", "Grade", "الدرجة", fkChoice, secJob, list = "grades",
       also = ["Level", "Band", "Job Grade", "الدرجة"]),
    fd("joined", "Joining Date", "تاريخ الالتحاق", fkDate, secJob,
       also = ["DOJ", "Date of Joining", "Join Date", "Joined", "Start Date", "Hire Date",
               "Date Joined", "تاريخ التعيين", "تاريخ الالتحاق"]),
    fd("contract", "Contract Type", "نوع العقد", fkChoice, secJob, list = "contracts",
       also = ["Contract", "Contract Status"]),
    fd("contractEnd", "Contract End", "انتهاء العقد", fkDate, secJob, expiry = true,
       also = ["Contract Expiry", "Contract End Date", "End of Contract", "انتهاء العقد"]),
    fd("status", "Status", "الحالة", fkChoice, secJob, list = "statuses",
       also = ["Employment Status", "Active", "الحالة"]),
    fd("leftOn", "Leaving Date", "تاريخ ترك العمل", fkDate, secJob,
       also = ["Last Working Day", "Resignation Date", "Termination Date", "LWD", "Exit Date"]),
    fd("visaUnder", "Visa Under", "الكفالة", fkHotel, secDocuments,
       also = ["Visa Company", "Sponsor", "Visa Sponsor", "Sponsorship", "Visa On", "الكفيل", "الكفالة"]),
    fd("visaType", "Visa Type", "نوع التأشيرة", fkChoice, secDocuments, list = "visaTypes",
       also = ["Visa Category"]),
    fd("visaNo", "Visa / RC No.", "رقم التأشيرة", fkLine, secDocuments,
       also = ["Visa No", "Visa Number", "Labour Card", "Labour Card No", "رقم التأشيرة"]),
    fd("visaExpiry", "Visa Expiry", "انتهاء التأشيرة", fkDate, secDocuments, expiry = true,
       also = ["Visa Exp", "Visa Expiry Date", "Visa Valid Till", "انتهاء التأشيرة", "انتهاء الإقامة"]),
    fd("leaveBalance", "Leave Balance", "رصيد الإجازات", fkNumber, secJob,
       also = ["Leave Days", "Annual Leave Balance", "Leave Bal", "AL Balance", "رصيد الإجازة"]),
    fd("basic", "Basic Salary", "الراتب الأساسي", fkMoney, secSalary, inTotal = true,
       also = ["Basic", "B. Salary", "Basic Pay", "Basic Sal", "الراتب الأساسي", "الأساسي"]),
    fd("housing", "Housing Allowance", "بدل السكن", fkMoney, secSalary, inTotal = true,
       also = ["Housing", "HRA", "Accommodation", "House Allowance", "بدل السكن", "السكن"]),
    fd("transport", "Transport Allowance", "بدل النقل", fkMoney, secSalary, inTotal = true,
       also = ["Transport", "Transportation", "Conveyance", "Travel Allowance", "بدل النقل", "بدل المواصلات"]),
    fd("otherAllowance", "Other Allowance", "بدلات أخرى", fkMoney, secSalary, inTotal = true,
       also = ["Other", "Others", "Other Allowances", "Misc Allowance", "بدلات أخرى"]),
    fd("bank", "Bank", "البنك", fkLine, secSalary, also = ["Bank Name", "البنك"]),
    fd("iban", "IBAN / Account", "رقم الحساب", fkLine, secSalary,
       also = ["IBAN", "Account", "Account No", "Bank Account", "A/C No", "رقم الحساب", "الآيبان"]),
    fd("notes", "Notes", "ملاحظات", fkLongText, secOther, also = ["Remarks", "Comments", "ملاحظات"])]

proc defaultLists*(): OrderedTable[string, seq[string]] =
  result["departments"] = @["Front Office", "Housekeeping", "F&B Service", "Kitchen",
                            "Engineering", "Security", "Sales & Marketing", "Finance",
                            "Human Resources", "IT", "Purchasing", "Recreation"]
  result["positions"] = @[]
  result["grades"] = @[]
  result["nationalities"] = @["Omani", "Indian", "Filipino", "Nepali", "Bangladeshi",
                              "Sri Lankan", "Pakistani", "Egyptian", "Jordanian", "Kenyan"]
  result["visaTypes"] = @["Employment", "Family", "Investor", "Other"]
  result["contracts"] = @["Unlimited", "Limited", "Part time", "Trainee"]
  result["statuses"] = @["Active", "On leave", "Left"]
  result["genders"] = @["Male", "Female"]

proc defaultArabic*(): Table[string, string] =
  ## The usual list values in Arabic (a nationality is said of a man; a
  ## woman's gets its ة in the letter).
  for (en, ar) in [
      ("Front Office", "المكاتب الأمامية"), ("Housekeeping", "التدبير الفندقي"),
      ("F&B Service", "خدمة الأغذية والمشروبات"), ("Kitchen", "المطبخ"), ("Engineering", "الهندسة"),
      ("Security", "الأمن"), ("Sales & Marketing", "المبيعات والتسويق"), ("Finance", "المالية"),
      ("Human Resources", "الموارد البشرية"), ("IT", "تقنية المعلومات"), ("Purchasing", "المشتريات"),
      ("Recreation", "الترفيه"), ("Administration", "الإدارة"),
      ("Omani", "عماني"), ("Indian", "هندي"), ("Filipino", "فلبيني"), ("Nepali", "نيبالي"),
      ("Bangladeshi", "بنغلاديشي"), ("Sri Lankan", "سريلانكي"), ("Pakistani", "باكستاني"),
      ("Egyptian", "مصري"), ("Jordanian", "أردني"), ("Kenyan", "كيني"), ("Syrian", "سوري"),
      ("Lebanese", "لبناني"), ("Sudanese", "سوداني"), ("Tunisian", "تونسي"), ("Moroccan", "مغربي"),
      ("Indonesian", "إندونيسي"), ("Thai", "تايلندي"), ("Chinese", "صيني"), ("British", "بريطاني"),
      ("American", "أمريكي"), ("Yemeni", "يمني"), ("Emirati", "إماراتي"), ("Saudi", "سعودي"),
      ("Bahraini", "بحريني"), ("Qatari", "قطري"), ("Kuwaiti", "كويتي"), ("Iranian", "إيراني"),
      ("Ugandan", "أوغندي"), ("Ethiopian", "إثيوبي"), ("Vietnamese", "فيتنامي"),
      ("Employment", "عمل"), ("Family", "عائلية"), ("Investor", "مستثمر"), ("Other", "أخرى"),
      ("Unlimited", "غير محدد المدة"), ("Limited", "محدد المدة"), ("Part time", "دوام جزئي"),
      ("Trainee", "متدرب"), ("Active", "على رأس العمل"), ("On leave", "في إجازة"),
      ("Left", "ترك العمل"), ("Male", "ذكر"), ("Female", "أنثى")]:
    result[en] = ar

const allowanceWords = [
  (@["phone", "mobile", "telephone", "tel"], "هاتف", "Phone"),
  (@["food", "meal", "meals"], "طعام", "Food"),
  (@["fuel", "petrol"], "وقود", "Fuel"),
  (@["uniform"], "زي", "Uniform"),
  (@["shift"], "مناوبة", "Shift"),
  (@["night"], "ليلي", "Night"),
  (@["overtime", "ot"], "عمل إضافي", "Overtime"),
  (@["education", "school"], "تعليم", "Education"),
  (@["car", "vehicle"], "سيارة", "Car"),
  (@["living", "col"], "غلاء معيشة", "Cost of Living"),
  (@["responsibility"], "مسؤولية", "Responsibility"),
  (@["special"], "خاص", "Special"),
  (@["utility", "utilities", "electricity"], "خدمات", "Utilities"),
  (@["site", "remote", "area"], "موقع", "Site"),
  (@["hardship"], "مشقة", "Hardship"),
  (@["family"], "عائلي", "Family"),
  (@["ticket", "travel", "air"], "تذاكر سفر", "Ticket"),
  (@["medical"], "علاج", "Medical"),
  (@["language"], "لغة", "Language"),
  (@["laundry"], "غسيل", "Laundry"),
  (@["attendance"], "حضور", "Attendance"),
  (@["risk"], "مخاطر", "Risk")]

proc allowanceNames*(header: string): tuple[en, ar: string] =
  ## A new allowance's names in English and Arabic from a sheet's header
  ## ("Phone Allowance" -> "بدل هاتف", "بدل الهاتف" -> "Phone Allowance");
  ## "" for the one that is not known.
  let h = header.strip
  var arabic = false
  for ch in h:
    if ord(ch) >= 0xD8 and ord(ch) <= 0xDB: arabic = true
  if arabic:
    result.ar = h
    for (words, ar, en) in allowanceWords:
      for w in strutils.splitWhitespace(ar):
        if w in h:
          result.en = en & " Allowance"
          return
  else:
    result.en = h
    var ws: seq[string]
    for w in strutils.splitWhitespace(h.toLowerAscii.multiReplace((".", " "), ("-", " "), ("/", " "), ("_", " "))):
      ws.add w
    for (words, ar, en) in allowanceWords:
      for w in words:
        if w in ws:
          result.ar = "بدل " & ar
          return

proc arabicOf*(b: Book; value: string): string =
  ## `value` in Arabic when the book knows it, else as it is.
  if value.len == 0: return ""
  result = b.arabic.getOrDefault(value)
  if result.len > 0: return
  for k, v in b.arabic:
    if cmpIgnoreCase(k, value) == 0: result = v; return
  result = value

proc newBook*(hotelNames: openArray[string] = ["Hotel 1", "Hotel 2", "Hotel 3"]): Book =
  result = Book(version: BookVersion, fields: builtinFields(), lists: defaultLists(),
                arabic: defaultArabic(), lockMinutes: 5, device: newId("dev-"))
  let colors = ["#1f4e79", "#7b2c2c", "#2e6b3a", "#6e4a9c", "#a86b16"]
  for i, n in hotelNames:
    let code = (if n.len >= 3: n[0 .. 2] else: n).toUpperAscii
    result.hotels.add Hotel(id: newId("h-"), name: n, code: code, color: colors[i mod colors.len],
                            refPrefix: code & "/HR", modified: nowT())
  result.groups = @[Group(id: newId("g-"), name: "Probation", color: "#d6a219", modified: nowT()),
                    Group(id: newId("g-"), name: "Night shift", color: "#6e4a9c", modified: nowT())]

# ---- reading the fields ------------------------------------------------------------------------

proc field*(b: Book; key: string): FieldDef =
  for f in b.fields:
    if f.key == key: return f
  FieldDef(key: key, label: key)

proc hasField*(b: Book; key: string): bool =
  for f in b.fields:
    if f.key == key: return true

proc hotelIndex*(b: Book; id: string): int =
  for i, h in b.hotels:
    if h.id == id: return i
  -1

proc hotelName*(b: Book; id: string): string =
  let i = b.hotelIndex(id)
  if i >= 0: b.hotels[i].name else: id      # (a company outside the three)

proc get*(e: Employee; key: string): string = e.v.getOrDefault(key)

proc num*(s: string): float =
  ## A number from text ("1,234.500", " 610 ", "OMR 610"); NaN when none.
  var t = ""
  for c in s:
    if c in {'0'..'9', '.', '-'}: t.add c
  if t.len == 0 or t == "-" or t == ".": return NaN
  try: parseFloat(t) except ValueError: NaN

proc totalSalary*(b: Book; e: Employee): float =
  for f in b.fields:
    if f.kind == fkMoney and f.inTotal and not f.hidden:
      let v = num(e.get(f.key))
      if not v.isNaN: result += v

proc active*(e: Employee): bool =
  not e.deleted and e.get("status") notin ["Left"]

proc name*(e: Employee): string =
  result = e.get("nameEn")
  if result.len == 0: result = e.get("nameAr")
  if result.len == 0: result = e.get("empNo")
  if result.len == 0: result = "(no name)"

proc otherVisa*(e: Employee): bool =
  ## On the visa of another hotel (or company) than the one they work at.
  let u = e.get("visaUnder")
  u.len > 0 and u != e.get("hotel")

proc fmtNum*(v: float; decimals: int): string =
  ## "1,234.500"
  if v.isNaN: return ""
  var s = formatFloat(abs(v), ffDecimal, decimals)
  if s.endsWith("."): s.setLen(s.len - 1)
  let dot = s.find('.')
  var whole = if dot < 0: s else: s[0 ..< dot]
  var g = ""
  for i, c in whole:
    if i > 0 and (whole.len - i) mod 3 == 0: g.add ','
    g.add c
  result = (if v < 0: "-" else: "") & g & (if dot < 0: "" else: s[dot .. ^1])

proc money*(v: float; decimals = 3): string =
  if v.isNaN: "" else: fmtNum(v, decimals)

proc parseDateText*(s: string): tuple[ok: bool; y, m, d: int] =
  ## "2018-09-02", "02/09/2018", "2/9/18", "02-Sep-2018", "2 September 2018".
  let t = s.strip
  if t.len == 0: return
  const months = ["jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec"]
  try:
    if t.len >= 10 and t[4] == '-' and t[7] == '-':
      result = (true, parseInt(t[0 .. 3]), parseInt(t[5 .. 6]), parseInt(t[8 .. 9]))
    else:
      let p = t.split({'/', '.', '-', ' ', ','}).filterIt(it.len > 0)
      if p.len >= 3:
        var d, m, y: int
        var mi = -1
        for k, w in months:
          if p[1].toLowerAscii.startsWith(w): mi = k
          if p[0].toLowerAscii.startsWith(w) and mi < 0: mi = k + 100
        if mi >= 100:              # "Sep 2, 2018"
          m = mi - 99
          d = parseInt(p[1])
          y = parseInt(p[2])
        elif mi >= 0:
          d = parseInt(p[0]); m = mi + 1; y = parseInt(p[2])
        elif p[0].len == 4:        # 2018/09/02
          y = parseInt(p[0]); m = parseInt(p[1]); d = parseInt(p[2])
        else:                      # day first, as in Oman
          d = parseInt(p[0]); m = parseInt(p[1]); y = parseInt(p[2])
          if m > 12 and d <= 12: swap(d, m)
        if y < 100: y += (if y < 50: 2000 else: 1900)
        result = (true, y, m, d)
  except ValueError:
    result = (false, 0, 0, 0); return
  if result.ok and (result.m notin 1 .. 12 or result.d notin 1 .. 31 or result.y notin 1900 .. 2200):
    result = (false, 0, 0, 0)

proc isoDate*(s: string): string =
  ## Any date text as "yyyy-mm-dd" ("" when it is not one).
  let d = parseDateText(s)
  if d.ok: $d.y & "-" & align($d.m, 2, '0') & "-" & align($d.d, 2, '0') else: ""

proc showDate*(iso: string): string =
  ## "2018-09-02" -> "02/09/2018"
  let d = parseDateText(iso)
  if d.ok: align($d.d, 2, '0') & "/" & align($d.m, 2, '0') & "/" & $d.y else: iso

proc dayNum*(iso: string): int =
  ## Days since 1970-01-01 (for comparing dates); low(int) when none.
  let d = parseDateText(iso)
  if not d.ok: return low(int)
  try:
    int(dateTime(d.y, Month(d.m), MonthdayRange(min(d.d, getDaysInMonth(Month(d.m), d.y))),
                 0, 0, 0, 0, utc()).toTime.toUnix div 86400)
  except ValueError: low(int)

proc todayNum*(): int = int(getTime().toUnix div 86400)

proc todayIso*(): string = now().format("yyyy-MM-dd")

proc display*(b: Book; f: FieldDef; raw: string): string =
  ## A value as it is shown.
  case f.kind
  of fkMoney: (let v = num(raw); if v.isNaN: raw else: money(v))
  of fkDate: showDate(raw)
  of fkHotel: b.hotelName(raw)
  of fkYesNo: (if raw in ["1", "true", "yes", "Yes", "TRUE"]: "Yes" elif raw.len > 0: "No" else: "")
  else: raw

proc yearsBetween*(a, b: int): float = float(b - a) / 365.2425

# ---- changing an employee (with its history) -----------------------------------------------------

proc setValue*(e: var Employee; key, value, source: string; at = nowT()): bool {.discardable.} =
  ## Sets a field, keeping the change in the history; true when it changed.
  let was = e.v.getOrDefault(key)
  if was == value: return false
  if value.len == 0: e.v.del(key) else: e.v[key] = value
  e.history.add Change(at: at, field: key, was: was, now: value, source: source)
  if e.history.len > 400: e.history.delete(0)
  e.modified = at
  true

proc newEmployee*(): Employee =
  Employee(id: newId("e-"), created: nowT(), modified: nowT())

# ---- the tags of letters --------------------------------------------------------------------------

proc tagValues*(b: Book; e: Employee; hotel: Hotel; refNo = ""): Table[string, string] =
  ## What the #[tags]# of a letter are filled in from: every field by its
  ## label (and its Arabic label), and the computed ones.
  for f in b.fields:
    let raw = e.get(f.key)
    var v = case f.kind
            of fkMoney: (let x = num(raw); if x.isNaN: raw else: money(x))
            of fkDate: raw                   # (filters format it; plain: dd/mm/yyyy below)
            of fkHotel: b.hotelName(raw)
            else: raw
    if f.kind == fkDate: v = showDate(raw)
    result[tagKey(f.label)] = v
    if f.labelAr.len > 0:
      # by its Arabic name, a field says its value in Arabic when known
      var va = v
      case f.kind
      of fkHotel:
        let hi = b.hotelIndex(raw)
        if hi >= 0 and b.hotels[hi].nameAr.len > 0: va = b.hotels[hi].nameAr
      of fkChoice, fkLine:
        va = b.arabicOf(raw)
        if f.key == "nationality" and va != raw and e.get("gender") == "Female" and va.endsWith("ي"):
          va.add "ة"
      else: discard
      result[tagKey(f.labelAr)] = va
    result[tagKey(f.key)] = v
    if f.kind == fkDate:     # (for |long, |date: the ISO form works with both)
      result[tagKey(f.label)] = (if raw.len > 0: showDate(raw) else: "")
  let total = b.totalSalary(e)
  for k in ["Total Salary", "Gross Salary", "Total", "الراتب الإجمالي", "إجمالي الراتب"]:
    result[tagKey(k)] = money(total)
  var allow = 0.0
  for f in b.fields:
    if f.kind == fkMoney and f.inTotal and f.key != "basic":
      let x = num(e.get(f.key))
      if not x.isNaN: allow += x
  result[tagKey("Total Allowances")] = money(allow)
  result[tagKey("Hotel Name")] = hotel.name
  result[tagKey("Hotel Name Arabic")] = hotel.nameAr
  result[tagKey("اسم الفندق")] = (if hotel.nameAr.len > 0: hotel.nameAr else: hotel.name)
  result[tagKey("Hotel CR")] = hotel.cr
  result[tagKey("CR")] = hotel.cr
  result[tagKey("Hotel VAT")] = hotel.vat
  result[tagKey("VAT")] = hotel.vat
  result[tagKey("Hotel Address")] = hotel.address
  result[tagKey("Hotel Address Arabic")] = hotel.addressAr
  result[tagKey("Hotel Phone")] = hotel.phone
  result[tagKey("Hotel Email")] = hotel.email
  result[tagKey("Signer")] = hotel.signer
  result[tagKey("Signer Title")] = hotel.signerTitle
  result[tagKey("Signer Arabic")] = hotel.signerAr
  result[tagKey("Signer Title Arabic")] = hotel.signerTitleAr
  result[tagKey("Today")] = showDate(todayIso())
  result[tagKey("التاريخ")] = showDate(todayIso())
  result[tagKey("Ref No")] = refNo
  result[tagKey("الرقم المرجعي")] = refNo
  let j = dayNum(e.get("joined"))
  if j != low(int):
    let y = yearsBetween(j, todayNum())
    result[tagKey("Years of Service")] = formatFloat(floor(y * 10) / 10, ffDecimal, 1)
  result[tagKey("Visa Under Hotel")] = b.hotelName(e.get("visaUnder"))
  let g = e.get("gender")
  result[tagKey("Mr/Ms")] = (if g == "Female": "Ms." elif g == "Male": "Mr." else: "")
  result[tagKey("السيد/ة")] = (if g == "Female": "السيدة" elif g == "Male": "السيد" else: "")
  result[tagKey("He/She")] = (if g == "Female": "She" elif g == "Male": "He" else: "He/She")
  result[tagKey("His/Her")] = (if g == "Female": "Her" elif g == "Male": "His" else: "His/Her")
  result[tagKey("Him/Her")] = (if g == "Female": "her" elif g == "Male": "him" else: "him/her")
  # Arabic words that change for a woman
  let fem = g == "Female"
  for (m, f) in [("يعمل", "تعمل"), ("ويتقاضى", "وتتقاضى"), ("له", "لها"), ("طلبه", "طلبها"),
                 ("عمله", "عملها"), ("ه", "ها"), ("وما زال", "وما زالت"), ("الموظف", "الموظفة"),
                 ("عمل", "عملت"), ("كان", "كانت")]:
    result[tagKey(m & "/" & f)] = (if fem: f else: m)
  # the salary as table rows: every allowance in the total that he has
  var rowsEn, rowsAr: seq[string]
  for f in b.fields:
    if f.kind != fkMoney or not f.inTotal or f.hidden: continue
    let x = num(e.get(f.key))
    if x.isNaN or x == 0: continue
    rowsEn.add "| " & f.label & " | OMR " & money(x) & " |"
    rowsAr.add "| " & (if f.labelAr.len > 0: f.labelAr else: f.label) & " | " & money(x) & " ر.ع. |"
  rowsEn.add "| **Total** | **OMR " & money(total) & "** |"
  rowsAr.add "| **الإجمالي** | **" & money(total) & " ر.ع.** |"
  result[tagKey("Salary Table")] = rowsEn.join("\n")
  result[tagKey("جدول الراتب")] = rowsAr.join("\n")

proc tagNames*(b: Book; arabic = false): seq[string] =
  ## The tags a letter can use, for the "Insert tag" menu (`arabic`: the
  ## fields by their Arabic names, which give their values in Arabic).
  if arabic:
    for f in b.fields:
      if not f.hidden: result.add(if f.labelAr.len > 0: f.labelAr else: f.label)
    result.add ["اسم الفندق", "السيد/ة", "جدول الراتب", "التاريخ", "الرقم المرجعي",
                "يعمل/تعمل", "ويتقاضى/وتتقاضى", "له/لها", "طلبه/طلبها", "عمله/عملها", "ه/ها",
                "وما زال/وما زالت", "الموظف/الموظفة", "كان/كانت", "Total Salary",
                "Hotel Name Arabic", "Hotel Address Arabic", "Signer Arabic", "Signer Title Arabic",
                "Hotel CR", "Hotel VAT", "Years of Service"]
    return
  for f in b.fields:
    if not f.hidden: result.add f.label
  result.add ["Total Salary", "Total Allowances", "Years of Service", "Hotel Name",
              "Hotel Name Arabic", "Hotel CR", "Hotel VAT", "Hotel Address",
              "Hotel Address Arabic", "Hotel Phone", "Signer", "Signer Title",
              "Signer Arabic", "Signer Title Arabic", "Today", "Ref No", "Mr/Ms",
              "السيد/ة", "He/She", "His/Her", "Him/Her", "Visa Under Hotel", "Salary Table",
              "جدول الراتب", "يعمل/تعمل", "ويتقاضى/وتتقاضى", "له/لها", "طلبه/طلبها",
              "عمله/عملها", "ه/ها", "وما زال/وما زالت", "الموظف/الموظفة", "كان/كانت"]

# ---- saving: JSON, read back tolerantly ----------------------------------------------------------

proc gs(n: JsonNode; k: string; d = ""): string =
  if n != nil and n.kind == JObject and n.hasKey(k) and n[k].kind == JString: n[k].str else: d
proc gf(n: JsonNode; k: string; d = 0.0): float =
  if n != nil and n.kind == JObject and n.hasKey(k):
    let x = n[k]
    if x.kind == JFloat: return x.fnum
    if x.kind == JInt: return float(x.num)
  d
proc gi(n: JsonNode; k: string; d = 0): int =
  if n != nil and n.kind == JObject and n.hasKey(k) and n[k].kind == JInt: int(n[k].num) else: d
proc gb(n: JsonNode; k: string; d = false): bool =
  if n != nil and n.kind == JObject and n.hasKey(k) and n[k].kind == JBool: n[k].bval else: d
proc ga(n: JsonNode; k: string): seq[JsonNode] =
  if n != nil and n.kind == JObject and n.hasKey(k) and n[k].kind == JArray: n[k].elems else: @[]
proc gss(n: JsonNode; k: string): seq[string] =
  for x in ga(n, k):
    if x.kind == JString: result.add x.str
proc gtab(n: JsonNode; k: string): Table[string, string] =
  if n != nil and n.kind == JObject and n.hasKey(k) and n[k].kind == JObject:
    for kk, vv in n[k].pairs:
      if vv.kind == JString: result[kk] = vv.str
proc genum[T: enum](n: JsonNode; k: string; d: T): T =
  let s = gs(n, k)
  for x in T:
    if $x == s: return x
  d

proc toJ(t: Table[string, string]): JsonNode =
  result = newJObject()
  var keys = toSeq(t.keys)
  keys.sort()
  for k in keys: result[k] = %t[k]

proc toJson*(b: Book): JsonNode =
  result = %*{"app": "HR Book", "version": b.version, "device": b.device,
              "savedAt": b.savedAt, "lockMinutes": b.lockMinutes,
              "hideSalaries": b.hideSalaries, "lastBackup": b.lastBackup}
  var hs = newJArray()
  for h in b.hotels:
    var nr = newJObject()
    for y, n in h.nextRef: nr[y] = %n
    hs.add %*{"id": h.id, "name": h.name, "nameAr": h.nameAr, "code": h.code, "cr": h.cr,
              "vat": h.vat, "address": h.address, "addressAr": h.addressAr, "phone": h.phone,
              "email": h.email, "website": h.website, "color": h.color,
              "refPrefix": h.refPrefix, "nextRef": nr, "logo": h.logo,
              "letterhead": h.letterhead, "signature": h.signature, "stamp": h.stamp,
              "signer": h.signer, "signerTitle": h.signerTitle, "signerAr": h.signerAr,
              "signerTitleAr": h.signerTitleAr, "modified": h.modified}
  result["hotels"] = hs
  var fs = newJArray()
  for f in b.fields:
    fs.add %*{"key": f.key, "label": f.label, "labelAr": f.labelAr, "kind": $f.kind,
              "section": $f.section, "list": f.list, "builtin": f.builtin, "hidden": f.hidden,
              "inList": f.inList, "inTotal": f.inTotal, "expiry": f.expiry, "also": f.also,
              "modified": f.modified}
  result["fields"] = fs
  var ls = newJObject()
  for k, v in b.lists: ls[k] = %v
  result["lists"] = ls
  var ar = newJObject()
  for k, v in b.arabic: ar[k] = %v
  result["arabic"] = ar
  var gr = newJArray()
  for g in b.groups: gr.add %*{"id": g.id, "name": g.name, "color": g.color, "modified": g.modified}
  result["groups"] = gr
  var es = newJArray()
  for e in b.employees:
    var hist = newJArray()
    for c in e.history:
      hist.add %*{"at": c.at, "field": c.field, "was": c.was, "now": c.now, "source": c.source}
    es.add %*{"id": e.id, "v": toJ(e.v), "groups": e.groups, "created": e.created,
              "modified": e.modified, "deleted": e.deleted, "history": hist}
  result["employees"] = es
  var ts = newJArray()
  for t in b.templates:
    ts.add %*{"id": t.id, "name": t.name, "lang": $t.lang, "hotel": t.hotel, "body": t.body,
              "modified": t.modified, "deleted": t.deleted}
  result["templates"] = ts
  var iss = newJArray()
  for i in b.issued:
    iss.add %*{"at": i.at, "emp": i.emp, "empName": i.empName, "templ": i.templ,
               "templName": i.templName, "refNo": i.refNo, "hotel": i.hotel}
  result["issued"] = iss
  var lay = newJArray()
  for l in b.layouts:
    lay.add %*{"headers": l.headers, "name": l.name, "map": toJ(l.map), "used": l.used,
               "modified": l.modified}
  result["layouts"] = lay

proc fromJson*(j: JsonNode): Book =
  ## A book from its JSON (fields it does not know are left out, fields
  ## it misses take their defaults; built-in fields it lacks are added).
  result = Book(version: gi(j, "version", BookVersion), device: gs(j, "device", newId("dev-")),
                savedAt: gf(j, "savedAt"), lockMinutes: gi(j, "lockMinutes", 5),
                hideSalaries: gb(j, "hideSalaries"), lastBackup: gf(j, "lastBackup"))
  for h in ga(j, "hotels"):
    var x = Hotel(id: gs(h, "id"), name: gs(h, "name"), nameAr: gs(h, "nameAr"),
                  code: gs(h, "code"), cr: gs(h, "cr"), vat: gs(h, "vat"),
                  address: gs(h, "address"), addressAr: gs(h, "addressAr"),
                  phone: gs(h, "phone"), email: gs(h, "email"), website: gs(h, "website"),
                  color: gs(h, "color", "#1f4e79"), refPrefix: gs(h, "refPrefix"),
                  logo: gs(h, "logo"), letterhead: gs(h, "letterhead"),
                  signature: gs(h, "signature"), stamp: gs(h, "stamp"),
                  signer: gs(h, "signer"), signerTitle: gs(h, "signerTitle"),
                  signerAr: gs(h, "signerAr"), signerTitleAr: gs(h, "signerTitleAr"),
                  modified: gf(h, "modified"))
    if h.hasKey("nextRef") and h["nextRef"].kind == JObject:
      for y, n in h["nextRef"].pairs:
        if n.kind == JInt: x.nextRef[y] = int(n.num)
    if x.id.len > 0: result.hotels.add x
  for f in ga(j, "fields"):
    let x = FieldDef(key: gs(f, "key"), label: gs(f, "label"), labelAr: gs(f, "labelAr"),
                     kind: genum(f, "kind", fkLine), section: genum(f, "section", secOther),
                     list: gs(f, "list"), builtin: gb(f, "builtin"), hidden: gb(f, "hidden"),
                     inList: gb(f, "inList"), inTotal: gb(f, "inTotal"), expiry: gb(f, "expiry"),
                     also: gss(f, "also"), modified: gf(f, "modified"))
    if x.key.len > 0: result.fields.add x
  for d in builtinFields():                 # (built-in fields a newer version added)
    if not result.hasField(d.key): result.fields.add d
  if j.hasKey("lists") and j["lists"].kind == JObject:
    for k, v in j["lists"].pairs:
      var l: seq[string]
      if v.kind == JArray:
        for x in v.elems:
          if x.kind == JString: l.add x.str
      result.lists[k] = l
  for k, v in defaultLists():
    if not result.lists.hasKey(k): result.lists[k] = v
  if j.hasKey("arabic") and j["arabic"].kind == JObject:
    for k, v in j["arabic"].pairs:
      if v.kind == JString: result.arabic[k] = v.str
  else:
    result.arabic = defaultArabic()
  for g in ga(j, "groups"):
    result.groups.add Group(id: gs(g, "id"), name: gs(g, "name"), color: gs(g, "color", "#808080"),
                            modified: gf(g, "modified"))
  for e in ga(j, "employees"):
    var x = Employee(id: gs(e, "id"), v: gtab(e, "v"), groups: gss(e, "groups"),
                     created: gf(e, "created"), modified: gf(e, "modified"),
                     deleted: gb(e, "deleted"))
    for c in ga(e, "history"):
      x.history.add Change(at: gf(c, "at"), field: gs(c, "field"), was: gs(c, "was"),
                           now: gs(c, "now"), source: gs(c, "source"))
    if x.id.len > 0: result.employees.add x
  for t in ga(j, "templates"):
    result.templates.add Template(id: gs(t, "id"), name: gs(t, "name"),
                                  lang: genum(t, "lang", llEnglish), hotel: gs(t, "hotel"),
                                  body: gs(t, "body"), modified: gf(t, "modified"),
                                  deleted: gb(t, "deleted"))
  for i in ga(j, "issued"):
    result.issued.add Issued(at: gf(i, "at"), emp: gs(i, "emp"), empName: gs(i, "empName"),
                             templ: gs(i, "templ"), templName: gs(i, "templName"),
                             refNo: gs(i, "refNo"), hotel: gs(i, "hotel"))
  for l in ga(j, "layouts"):
    result.layouts.add Layout(headers: gs(l, "headers"), name: gs(l, "name"), map: gtab(l, "map"),
                              used: gi(l, "used"), modified: gf(l, "modified"))
