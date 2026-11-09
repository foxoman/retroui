## E-mail messages (retroui/mime): reading what Outlook and Gmail send
## (tests/data/mime), broken and cut-off messages, charsets, encoded words,
## addresses and dates; making messages and reading them back; and damaged
## samples that must not crash it.

import std/[os, strutils, times, random, monotimes, math]
import retroui/mime

const data = currentSourcePath().parentDir / "data" / "mime"

proc sample(name: string): MimePart = parseMime(readFile(data / name))

proc utcTime(y, mo, d, h, mi, s: int): float =
  float(dateTime(y, Month(mo), MonthdayRange(d), HourRange(h), MinuteRange(mi), SecondRange(s),
                 zone = utc()).toTime.toUnix)

proc addr2(name, email: string): MailAddress = MailAddress(name: name, email: email)

# ---- the samples -----------------------------------------------------------------------------

block outlookArabic:
  let m = sample("outlook-arabic.eml")
  doAssert m.contentType == "multipart/alternative" and m.parts.len == 2
  doAssert m.decodedHeader("Subject") == "جدول التدريب لشهر نوفمبر – قسم الموارد البشرية"
  doAssert m.decodedHeader("Thread-Topic") == m.decodedHeader("Subject")
  doAssert parseAddresses(m.header("From")) == @[addr2("مريم البلوشي", "maryam@hotel.example")]
  doAssert parseAddresses(m.header("To")) == @[addr2("Sultan Al Isaiee", "sultan@hotel.example"),
                                              addr2("قسم الموارد البشرية", "hr@hotel.example")]
  doAssert parseMailDate(m.header("Date")) == utcTime(2025, 11, 3, 5, 15, 42)
  doAssert "with mapi id" in m.header("received") and "\n" notin m.header("Received")
  doAssert m.header("X-MS-Has-Attach") == "" and m.headers.len == 12
  doAssert m.parts[0].param("charset") == "windows-1256"
  let (html, text) = m.bodies
  doAssert text == "السلام عليكم،\n\nمرفق جدول التدريب لشهر نوفمبر. يرجى تأكيد الحضور قبل يوم الخميس.\n\n" &
                   "مع التحية،\nمريم البلوشي\nقسم الموارد البشرية – فندق ميركيور صحار\n", text
  doAssert "<b>الخميس</b>" in html and "dir=\"rtl\"" in html
  doAssert m.attachments.len == 0

block gmailInline:
  let m = sample("gmail-inline.eml")
  doAssert m.contentType == "multipart/related"
  let (html, text) = m.bodies
  doAssert text == "Hi Sultan,\n\nThe new pool poster is below. مسبح الفندق مفتوح الآن.\n\nThanks,\nFatma\n"
  doAssert "<img src=\"cid:ii_mh0x1abc0\"" in html and "مسبح الفندق" in html
  let a = m.attachments
  doAssert a.len == 1
  doAssert a[0].filename == "poster.png" and a[0].contentType == "image/png"
  doAssert a[0].contentId == "ii_mh0x1abc0" and a[0].inline
  doAssert a[0].data.startsWith("\x89PNG\r\n\x1A\n") and a[0].data.len == 69
  doAssert parseAddresses(m.header("From")) == @[addr2("Fatma Al Rawahi", "fatma.rawahi@gmail.com")]

block rfc2231:
  let m = sample("attachment-rfc2231.eml")
  doAssert m.contentType == "multipart/mixed" and m.parts.len == 4, $m.parts.len
  doAssert m.bodies.text == "Please find the attendance report attached.\n"
  doAssert m.bodies.html == ""
  doAssert m.parts[1].filename == "تقرير الحضور - نوفمبر ٢٠٢٥.pdf"
  doAssert m.parts[1].param("name").startsWith("=?UTF-8?B?"), "params: RFC 2231 only"
  let a = m.attachments
  doAssert a.len == 3
  doAssert a[0].filename == "تقرير الحضور - نوفمبر ٢٠٢٥.pdf" and a[0].contentType == "application/pdf"
  doAssert a[0].data.startsWith("%PDF-1.4") and a[0].data.endsWith("%%EOF\n") and not a[0].inline
  doAssert a[1].filename == "résumé final.docx" and a[1].data.len == 42
  doAssert a[2].contentType == "text/calendar" and a[2].filename.endsWith(".ics")
  doAssert "BEGIN:VCALENDAR" in a[2].data

block quotedPrintable:
  let m = sample("qp-soft.eml")
  doAssert m.decodedHeader("Subject") == "Café menu – new prices"
  doAssert parseMailDate(m.header("Date")) == utcTime(2025, 11, 5, 12, 30, 0)
  doAssert m.bodies.text ==
    "This is a long line that goes on and on past the seventy-six character limit, so it is " &
    "broken with a soft line break.\nPrices: espresso = 1.200 OMR, café au lait = 1.500 OMR. \n" &
    "Arabic split over a soft break: القهوة\nTrailing spaces above were added on the way and " &
    "are dropped.\nA lone = sign stays, and so does =ZZ.\nLast line without a break", m.bodies.text

block forwarded:
  let m = sample("forwarded.eml")
  doAssert m.bodies.text == "See the forwarded quote below.\n"
  let a = m.attachments
  doAssert a.len == 1
  doAssert a[0].contentType == "message/rfc822" and a[0].filename == "عرض أسعار المناشف.eml"
  doAssert a[0].data.startsWith("From: =?UTF-8?B?")
  let inner = m.parts[1].parts[0]
  doAssert inner.decodedHeader("Subject") == "عرض أسعار المناشف"
  doAssert parseAddresses(inner.header("From"))[0].name == "أحمد الحارثي"
  doAssert "<b>٣٫٥</b>" in inner.bodies.html and inner.bodies.text == "السعر ٣٫٥ ريال للمنشفة."
  # the .eml read on its own is the same message
  let again = parseMime(a[0].data)
  doAssert again.decodedHeader("Subject") == "عرض أسعار المناشف" and again.bodies == inner.bodies
  doAssert parseMailDate(inner.header("Date")) == utcTime(2025, 10, 31, 7, 20, 0)

block truncated:
  let m = sample("truncated.eml")
  let (html, text) = m.bodies
  doAssert text == "The text part is fine." and html == "<p>The HTML part</p>"
  let a = m.attachments
  doAssert a.len == 1 and a[0].filename == "data.bin"
  var big = ""
  for i in 0 ..< 3000: big.add char((i * 37) mod 256)
  doAssert a[0].data.len > 1000 and big.startsWith(a[0].data), "what arrived of it"

block plainAscii:
  let m = sample("plain-ascii.eml")
  doAssert m.contentType == "text/plain" and m.parts.len == 0
  doAssert m.header("Subject") == "Lunch on Thursday?" and m.header("Return-Path") == "<john@example.com>"
  doAssert "by mx.hotel.example" in m.header("Received")
  doAssert parseAddresses(m.header("From")) == @[addr2("John Smith", "john@example.com")]
  doAssert parseAddresses(m.header("To")).len == 0
  doAssert parseMailDate(m.header("Date")) == utcTime(2025, 10, 30, 12, 1, 0)
  doAssert m.bodies.text == "Hi,\n\nAre we still on for lunch on Thursday?\n\n--\nJohn\n"
  doAssert m.bodies.html == "" and m.attachments.len == 0

# ---- pieces ----------------------------------------------------------------------------------

block encodedWords:
  doAssert decodeWords("=?utf-8?Q?a?= =?utf-8?Q?b?=") == "ab"
  doAssert decodeWords("=?utf-8?Q?a?=\r\n =?UTF-8?q?b_c?= d") == "ab c d"
  doAssert decodeWords("x =?utf-8?Q?a?= y") == "x a y"
  doAssert decodeWords("Re: =?ISO-8859-1?Q?Caf=E9?=") == "Re: Café"
  doAssert decodeWords("=?windows-1256?B?48jR5Q==?=") == "مبره"
  # a character cut between two words
  let bytes = "مرحبا"
  let w1 = "=?UTF-8?B?" & base64UrlEncode(bytes[0 .. 4], pad = true).replace('-', '+').replace('_', '/') & "?="
  let w2 = "=?UTF-8?B?" & base64UrlEncode(bytes[5 .. ^1], pad = true).replace('-', '+').replace('_', '/') & "?="
  doAssert decodeWords(w1 & " " & w2) == "مرحبا"
  doAssert decodeWords("=?utf-8*ar?B?2YXYsdit2KjYpw==?=") == "مرحبا", "a language after the charset"
  doAssert decodeWords("=?iso-8859-6?B?5efkxw==?= =?utf-8?Q?_ok?=") == "مهلا ok"
  doAssert decodeWords("=?utf-8?X?abc?= and =? alone") == "=?utf-8?X?abc?= and =? alone"
  doAssert decodeWords("=?utf-8?B?broken") == "=?utf-8?B?broken"
  doAssert decodeWords("raw UTF-8: سلام") == "raw UTF-8: سلام"
  doAssert decodeWords("bad \xFF byte") == "bad \uFFFD byte"
  doAssert decodeWords("") == ""

block charsets:
  doAssert toUtf8("\xE3\xD1\xCD\xC8\xC7", "windows-1256") == "مرحبا"
  doAssert toUtf8("\xE3\xD1\xCD\xC8\xC7", "CP1256") == "مرحبا"
  doAssert toUtf8("\xE5\xD1\xCD\xC8\xC7", "ISO-8859-6") == "مرحبا"
  doAssert toUtf8("caf\xE9", "iso-8859-1") == "café" and toUtf8("caf\xE9", "latin1") == "café"
  doAssert toUtf8("\x80 5", "windows-1252") == "€ 5" and toUtf8("\x80", "iso-8859-1") == "€"
  doAssert toUtf8("\xA4", "iso-8859-15") == "€"
  doAssert toUtf8("\xD0\xD2\xC9\xD7\xC5\xD4", "koi8-r") == "привет"
  doAssert toUtf8("\xEF\xF0\xE8\xE2\xE5\xF2", "windows-1251") == "привет"
  doAssert toUtf8("\xE1\xE5\xE9\xE1", "windows-1253") == "αεια"
  doAssert toUtf8("\xF9\xEC\xE5\xED", "windows-1255") == "שלום"
  doAssert toUtf8("\xF9\xEC\xE5\xED", "iso-8859-8-i") == "שלום"
  doAssert toUtf8("\xFF\xFEH\0i\0", "utf-16") == "Hi"
  doAssert toUtf8("\0H\0i", "utf-16be") == "Hi" and toUtf8("H\0i\0", "UTF-16LE") == "Hi"
  doAssert toUtf8("H\0i\0", "utf-16") == "Hi", "no byte order mark: guessed"
  doAssert toUtf8("\x3D\xD8\x00\xDE", "utf-16le") == "😀"
  doAssert toUtf8("caf\xC3\xA9", "utf-8") == "café" and toUtf8("\xEF\xBB\xBFx", "utf-8") == "x"
  doAssert toUtf8("a\xFFb\xC3", "utf-8") == "a\uFFFDb\uFFFD"
  doAssert toUtf8("\xED\xA0\x80", "utf-8") == "\uFFFD\uFFFD\uFFFD", "no surrogates"
  doAssert toUtf8("caf\xC3\xA9", "us-ascii") == "café", "mislabelled UTF-8"
  doAssert toUtf8("caf\xE9", "us-ascii") == "café", "mislabelled Latin-1"
  doAssert toUtf8("سلام", "x-unknown-charset") == "سلام" and toUtf8("a\xFF", "nonsense") == "a\uFFFD"
  doAssert toUtf8("", "windows-1256") == "" and toUtf8("plain", "koi8-r") == "plain"
  when defined(windows) or (defined(linux) and not defined(android)):
    # Chinese, Japanese and Korean, through the system
    doAssert toUtf8("\xD6\xD0\xCE\xC4", "gb2312") == "中文"
    doAssert toUtf8("\xD6\xD0\xCE\xC4", "GBK") == "中文"
    doAssert toUtf8("\xA4\xA4\xA4\xE5", "big5") == "中文"
    doAssert toUtf8("\x93\xFA\x96\x7B", "shift_jis") == "日本"
    doAssert toUtf8("\xC7\xD1\xB1\xB9", "euc-kr") == "한국"
    doAssert toUtf8("\xC7\xD1\xB1\xB9", "ks_c_5601-1987") == "한국"
    doAssert toUtf8("\xC6\xFC\xCB\xDC", "euc-jp") == "日本"

block qpAndBase64:
  var r = initRand(7)
  for round in 0 ..< 300:
    var s = ""
    for k in 0 ..< r.rand(400):
      case r.rand(9)
      of 0: s.add "\r\n"
      of 1: s.add ' '
      of 2: s.add '='
      of 3: s.add "سلام"
      of 4: s.add char(r.rand(255))
      else: s.add char(r.rand(32 .. 126))
    let q = quotedPrintableEncode(s)
    for ln in q.split("\r\n"):
      doAssert ln.len <= 76, ln
      for c in ln: doAssert ord(c) in 32 .. 126 or c == '\t'
    # (lone CR and LF become CRLF; everything else comes back as it was)
    var norm = s.replace("\r\n", "\n").replace('\r', '\n').replace("\n", "\r\n")
    doAssert quotedPrintableDecode(q) == norm
    let u = base64UrlEncode(s)
    doAssert '=' notin u and '+' notin u and '/' notin u
    doAssert base64UrlDecode(u) == s and base64UrlDecode(base64UrlEncode(s, pad = true)) == s
  doAssert quotedPrintableEncode("From here\n.\nx") == "=46rom here\r\n=2E\r\nx"
  doAssert quotedPrintableEncode("tail \nend\t") == "tail=20\r\nend=09"
  doAssert base64UrlDecode("SGk") == "Hi" and base64UrlDecode("SGk=") == "Hi"

block addresses:
  doAssert parseAddresses("A <a@x.com>, \"B, C\" <b@y.com>, c@z.com (Cee)") ==
    @[addr2("A", "a@x.com"), addr2("B, C", "b@y.com"), addr2("Cee", "c@z.com")]
  doAssert parseAddresses("Team: one@x.com, Two <two@x.com>; three@x.com") ==
    @[addr2("", "one@x.com"), addr2("Two", "two@x.com"), addr2("", "three@x.com")]
  doAssert parseAddresses("a@x.com; b@y.com") == @[addr2("", "a@x.com"), addr2("", "b@y.com")]
  doAssert parseAddresses("\"'Smith, John'\" <js@x.com>")[0] == addr2("Smith, John", "js@x.com")
  doAssert parseAddresses("'Maryam' <m@x.com>")[0] == addr2("Maryam", "m@x.com")
  doAssert parseAddresses("\"=?utf-8?B?2LPZhNi32KfZhg==?=\" <s@x.com>")[0] == addr2("سلطان", "s@x.com")
  doAssert parseAddresses("=?utf-8?Q?Ren=C3=A9?= <r@x.com>")[0] == addr2("René", "r@x.com")
  doAssert parseAddresses("<only@x.com>") == @[addr2("", "only@x.com")]
  doAssert parseAddresses("\"Quote \\\"Q\\\" Me\" <q@x.com>")[0].name == "Quote \"Q\" Me"
  doAssert parseAddresses("Name (comment) <n@x.com>")[0] == addr2("Name", "n@x.com")
  doAssert parseAddresses("undisclosed-recipients:;").len == 0
  doAssert parseAddresses("").len == 0 and parseAddresses(" , ,").len == 0
  doAssert parseAddresses("sultan@hotel.example") == @[addr2("", "sultan@hotel.example")]
  for a in [addr2("Sultan Al Isaiee", "s@x.om"), addr2("Smith, John", "js@x.com"),
            addr2("O'Brien", "ob@x.ie"), addr2("a \"quoted\" name", "q@x.com"),
            addr2("سلطان بن سعيد العيسائي — الموارد البشرية والتدريب والجودة", "hr@x.om"),
            addr2("=?not encoded?=", "n@x.com"), addr2("", "bare@x.com"),
            addr2("Line\r\nBreak", "lb@x.com")]:
    let s = $a
    doAssert '\r' notin s and '\n' notin s
    for c in s: doAssert ord(c) < 128, s
    let back = parseAddresses(s)
    doAssert back.len == 1 and back[0].email == a.email, s
    doAssert back[0].name == a.name.replace("\r\n", " "), s & " -> " & back[0].name

block dates:
  doAssert parseMailDate("Mon, 3 Nov 2025 14:05:09 +0400") == utcTime(2025, 11, 3, 10, 5, 9)
  doAssert parseMailDate("3 Nov 2025 14:05:09 -0230") == utcTime(2025, 11, 3, 16, 35, 9)
  doAssert parseMailDate("Mon, 03 Nov 2025 14:05 GMT") == utcTime(2025, 11, 3, 14, 5, 0)
  doAssert parseMailDate("Mon, 3 Nov 2025 14:05:09 EST") == utcTime(2025, 11, 3, 19, 5, 9)
  doAssert parseMailDate("Mon, 3 Nov 2025 14:05:09 +0400 (GST)") == utcTime(2025, 11, 3, 10, 5, 9)
  doAssert parseMailDate("Mon, 3 Nov 2025 14:05:09") == utcTime(2025, 11, 3, 14, 5, 9)
  doAssert parseMailDate("Mon Nov  3 14:05:09 2025") == utcTime(2025, 11, 3, 14, 5, 9)
  doAssert parseMailDate("2025-11-03T14:05:09+04:00") == utcTime(2025, 11, 3, 10, 5, 9)
  doAssert parseMailDate("2025-11-03 14:05:09Z") == utcTime(2025, 11, 3, 14, 5, 9)
  doAssert parseMailDate("2025-11-03T14:05:09.123Z") == utcTime(2025, 11, 3, 14, 5, 9)
  doAssert parseMailDate("Monday, November 3, 2025 2:05:09 PM +0000") == utcTime(2025, 11, 3, 14, 5, 9)
  doAssert parseMailDate("3 Nov 99 10:00:00 +0000") == utcTime(1999, 11, 3, 10, 0, 0)
  doAssert parseMailDate("29 Feb 2024 00:00:00 +0000") == utcTime(2024, 2, 29, 0, 0, 0)
  for bad in ["", "yesterday", "31 Feb 2025 10:00:00", "3 Nov", "Nov 2025", "99:99", "--",
              "Mon, 32 Nov 2025 10:00:00 +0000", "2025-13-01"]:
    doAssert parseMailDate(bad) == 0, bad
  doAssert formatMailDate(utcTime(2026, 11, 3, 9, 30, 0)) == "Tue, 03 Nov 2026 09:30:00 +0000"
  doAssert formatMailDate(0) == "Thu, 01 Jan 1970 00:00:00 +0000"
  var r = initRand(3)
  for k in 0 ..< 2000:
    let t = floor(r.rand(4_102_444_800.0))
    doAssert parseMailDate(formatMailDate(t)) == t

block flowedAndSniff:
  let f = parseMime("Content-Type: text/plain; charset=utf-8; format=flowed\r\n\r\n" &
                    "This is a long \r\nparagraph that \r\nflows.\r\n> quoted \r\n> on.\r\n-- \r\nSig\r\n")
  doAssert f.bodies.text == "This is a long paragraph that flows.\n> quoted on.\n-- \nSig\n", f.bodies.text
  let d = parseMime("Content-Type: text/plain; format=flowed; delsp=yes\r\n\r\nab \r\ncd\r\n")
  doAssert d.bodies.text == "abcd\n"
  let h = parseMime("Content-Type: text/html\r\n\r\n<meta charset=\"windows-1256\"><p>\xE3\xD1\xCD\xC8\xC7</p>")
  doAssert h.bodies.html == "<meta charset=\"windows-1256\"><p>مرحبا</p>"

block mimeTypes:
  doAssert mimeTypeOf("a.PDF") == "application/pdf" and mimeTypeOf("x.jpeg") == "image/jpeg"
  doAssert mimeTypeOf("r.xlsx") == "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"
  doAssert mimeTypeOf("noext") == "application/octet-stream" and mimeTypeOf("m.eml") == "message/rfc822"

block safeNames:
  let raw = "MIME-Version: 1.0\r\nContent-Type: multipart/mixed; boundary=b\r\n\r\n" &
    "--b\r\nContent-Type: text/plain\r\n\r\nhi\r\n" &
    "--b\r\nContent-Type: application/octet-stream; name=\"../../etc/passwd\"\r\n\r\nx\r\n" &
    "--b\r\nContent-Disposition: attachment; filename=\"C:\\\\temp\\\\evil.exe\"\r\n\r\ny\r\n" &
    "--b\r\nContent-Type: application/octet-stream\r\nContent-Disposition: attachment; filename=\"a<b>?.txt\"\r\n\r\nz\r\n" &
    "--b\r\nContent-Type: image/png\r\nContent-ID: <image001.png@01DA5E7B.2E3F1C40>\r\n\r\np\r\n--b--\r\n"
  let a = parseMime(raw).attachments
  doAssert a.len == 4
  doAssert a[0].filename == "passwd" and a[1].filename == "evil.exe" and a[2].filename == "a_b__.txt"
  doAssert a[3].filename == "image001.png" and not a[3].inline, "no HTML shows it: a file"

block limits:
  # parts inside parts, far too deep
  var deep = ""
  for k in 0 ..< 100:
    deep.add "Content-Type: multipart/mixed; boundary=\"b" & $k & "\"\r\n\r\n--b" & $k & "\r\n"
  deep.add "Content-Type: text/plain\r\n\r\ndeep text\r\n"
  let d = parseMime(deep)
  var depth = 0
  var p = d
  while p.parts.len > 0:
    p = p.parts[0]
    inc depth
  doAssert depth <= 31
  # far too many parts
  var many = "Content-Type: multipart/mixed; boundary=m\r\n\r\n"
  for k in 0 ..< 5000: many.add "--m\r\nContent-Type: text/plain\r\n\r\npart " & $k & "\r\n"
  many.add "--m--\r\n"
  let mm = parseMime(many)
  doAssert mm.parts.len < 1000 and mm.parts.len > 900
  doAssert mm.bodies.text.startsWith("part 0\npart 1\n")
  # nothing much at all
  for s in ["", "\r\n", "\r\n\r\n", "Subject: x", "Subject: x\r\n", "no headers at all",
            ": nothing\r\n\r\nbody", "Content-Type: multipart/mixed\r\n\r\nno boundary",
            "Content-Type: multipart/mixed; boundary=z\r\n\r\nnever the boundary",
            "Content-Type: message/rfc822\r\n\r\n", "\0\0\0"]:
    let m = parseMime(s)
    discard m.bodies
    discard m.attachments
  doAssert parseMime("Subject: x").header("Subject") == "x"
  doAssert parseMime("no headers at all").bodies.text == "no headers at all"
  doAssert parseMime("Content-Type: multipart/mixed; boundary=z\r\n\r\nnever the boundary").bodies.text ==
    "never the boundary"

# ---- making messages -------------------------------------------------------------------------

proc checkWire(raw: string) =
  ## 7-bit, CRLF lines, none longer than 76.
  for c in raw: doAssert ord(c) < 128, "8-bit byte"
  var i = 0
  for ln in raw.split("\r\n"):
    doAssert '\r' notin ln and '\n' notin ln, "a bare CR or LF"
    doAssert ln.len <= 76, "long line: " & ln
    inc i

block buildFull:
  let picture = "\x89PNG\r\n\x1A\n" & repeat("\0\xFF", 300)
  var pdf = "%PDF-1.4\n"
  var r = initRand(11)
  for k in 0 ..< 5000: pdf.add char(r.rand(255))
  let fwd = "From: a@x.com\r\nSubject: old one\r\n\r\nThe forwarded text.\r\n"
  let text = "السلام عليكم،\n\nمرفق التقرير الشهري لقسم الموارد البشرية — يرجى المراجعة.\n" &
             "A line in English that is long enough to need a soft line break somewhere in it, surely.\n"
  let html = "<html dir=\"rtl\"><body><p>السلام عليكم،</p><p><img src=\"cid:logo-1@retro\"></p>" &
             "<p>Price = 5 OMR</p></body></html>"
  let subject = "التقرير الشهري — نوفمبر ٢٠٢٥ 📊 (Monthly report, with a long English tail too)"
  let m = OutMail(
    fromAddr: addr2("سلطان العيسائي", "sultan@hotel.example"),
    to: @[addr2("Maryam Al Balushi", "maryam@hotel.example"), addr2("قسم الجودة", "quality@hotel.example")],
    cc: @[addr2("Smith, John", "john@example.com")],
    bcc: @[addr2("", "archive@hotel.example")],
    replyTo: @[addr2("HR", "hr@hotel.example")],
    subject: subject, text: text, html: html,
    inReplyTo: "abc@hotel.example", references: "<one@x> two@y",
    date: utcTime(2025, 11, 3, 10, 0, 0),
    attachments: @[
      MailAttachment(filename: "logo.png", contentType: "image/png", contentId: "logo-1@retro", data: picture),
      MailAttachment(filename: "تقرير الحضور الشهري لقسم الموارد البشرية - نوفمبر ٢٠٢٥.pdf", data: pdf),
      MailAttachment(filename: "notes.txt", contentType: "text/plain", data: "plain notes\n"),
      MailAttachment(filename: "old one.eml", contentType: "message/rfc822", data: fwd)],
    extraHeaders: @[("X-Mailer", "Retro Mail"), ("Content-Type", "text/evil"), ("Bad Name", "x"),
                    ("X-Note", "line\r\nInjected: yes"), ("X-Arabic", "ملاحظة")])
  let raw = buildMail(m)
  checkWire(raw)
  doAssert "\r\nInjected:" notin raw and "text/evil" notin raw and "Bad Name" notin raw
  let p = parseMime(raw)
  doAssert p.header("MIME-Version") == "1.0"
  doAssert p.decodedHeader("Subject") == subject
  doAssert parseAddresses(p.header("From")) == @[m.fromAddr]
  doAssert parseAddresses(p.header("To")) == m.to
  doAssert parseAddresses(p.header("Cc")) == m.cc and parseAddresses(p.header("Bcc")) == m.bcc
  doAssert parseAddresses(p.header("Reply-To")) == m.replyTo
  doAssert parseMailDate(p.header("Date")) == m.date
  doAssert p.header("Message-ID").startsWith("<") and p.header("Message-ID").endsWith("@hotel.example>")
  doAssert p.header("In-Reply-To") == "<abc@hotel.example>" and p.header("References") == "<one@x> <two@y>"
  doAssert p.header("X-Mailer") == "Retro Mail" and p.decodedHeader("X-Arabic") == "ملاحظة"
  doAssert p.header("X-Note") == "line  Injected: yes"
  # the shape: mixed [alternative [text, related [html, picture]], files...]
  doAssert p.contentType == "multipart/mixed" and p.parts.len == 4
  doAssert p.parts[0].contentType == "multipart/alternative"
  doAssert p.parts[0].parts[0].contentType == "text/plain"
  doAssert p.parts[0].parts[1].contentType == "multipart/related"
  doAssert p.parts[0].parts[1].param("type") == "text/html"
  doAssert p.parts[0].parts[1].parts[1].contentId == "logo-1@retro"
  let (h, t) = p.bodies
  doAssert t == text and h == html
  let a = p.attachments
  doAssert a.len == 4
  doAssert a[0].inline and a[0].contentId == "logo-1@retro" and a[0].data == picture
  doAssert a[1].filename == "تقرير الحضور الشهري لقسم الموارد البشرية - نوفمبر ٢٠٢٥.pdf"
  doAssert a[1].contentType == "application/pdf" and a[1].data == pdf and not a[1].inline
  doAssert a[2].filename == "notes.txt" and a[2].data == "plain notes\n"
  doAssert a[3].contentType == "message/rfc822" and a[3].filename == "old one.eml" and a[3].data == fwd
  doAssert p.parts[3].parts[0].decodedHeader("Subject") == "old one"

block buildSmall:
  # plain ASCII text: one 7-bit part, nothing encoded
  let raw = buildMail(OutMail(fromAddr: addr2("", "a@x.com"), to: @[addr2("", "b@y.com")],
                              subject: "Hello", text: "Just text.\nTwo lines."))
  checkWire(raw)
  doAssert "Content-Transfer-Encoding: 7bit" in raw and "multipart" notin raw
  let p = parseMime(raw)
  doAssert p.bodies.text == "Just text.\nTwo lines." and p.header("Subject") == "Hello"
  doAssert abs(parseMailDate(p.header("Date")) - epochTime()) < 5, "now"
  doAssert p.header("Message-ID").endsWith("@x.com>")
  # HTML alone; inline pictures with no HTML are files
  let h = parseMime(buildMail(OutMail(fromAddr: addr2("", "a@x.com"), html: "<p>only html</p>")))
  doAssert h.contentType == "text/html" and h.bodies == ("<p>only html</p>", "")
  let f = parseMime(buildMail(OutMail(fromAddr: addr2("", "a@x.com"), text: "see",
    attachments: @[MailAttachment(filename: "a.png", contentId: "c1", data: "PNG")])))
  doAssert f.contentType == "multipart/mixed" and f.attachments.len == 1 and not f.attachments[0].inline
  # nothing at all is still a message
  let e = parseMime(buildMail(OutMail(fromAddr: addr2("", "a@x.com"))))
  doAssert e.contentType == "text/plain" and e.bodies.text == ""
  # a long plain subject is folded, and unfolds back
  let long = repeat("word ", 40).strip
  let l = buildMail(OutMail(fromAddr: addr2("", "a@x.com"), subject: long, messageId: "given@x.com"))
  checkWire(l)
  doAssert parseMime(l).header("Subject") == long
  doAssert parseMime(l).header("Message-ID") == "<given@x.com>"
  # Arabic-heavy text goes as base64 (shorter than quoted-printable)
  let ar = buildMail(OutMail(fromAddr: addr2("", "a@x.com"), text: repeat("مرحبا بكم ", 50)))
  doAssert "Content-Transfer-Encoding: base64" in ar
  doAssert parseMime(ar).bodies.text == repeat("مرحبا بكم ", 50)
  # Message-IDs are new each time
  let id1 = newMessageId("hotel.example")
  doAssert id1 != newMessageId("hotel.example") and id1.startsWith("<") and id1.endsWith("@hotel.example>")
  doAssert newMessageId("").endsWith("@localhost>") and newMessageId("a b<c>").endsWith("@abc>")

block bigMessage:
  var blob = newString(8 * 1024 * 1024)
  var r = initRand(5)
  for c in blob.mitems: c = char(r.rand(255))
  let t0 = getMonoTime()
  let raw = buildMail(OutMail(fromAddr: addr2("", "a@x.com"), text: "big",
    attachments: @[MailAttachment(filename: "big.bin", data: blob)]))
  let t1 = getMonoTime()
  let p = parseMime(raw)
  let a = p.attachments
  let t2 = getMonoTime()
  doAssert a.len == 1 and a[0].data == blob
  echo "  8 MB attachment: built in ", (t1 - t0).inMilliseconds, " ms, read back in ",
       (t2 - t1).inMilliseconds, " ms"

# ---- damaged samples: nothing may crash ------------------------------------------------------

block fuzz:
  var seeds: seq[string]
  for f in walkFiles(data / "*.eml"): seeds.add readFile(f)
  doAssert seeds.len == 7
  seeds.add buildMail(OutMail(fromAddr: addr2("سلطان", "s@x.om"), to: @[addr2("", "a@b.c")],
    subject: "اختبار", text: "نص", html: "<p>نص <img src=\"cid:i\"></p>",
    attachments: @[MailAttachment(filename: "ملف.pdf", data: "%PDF"),
                   MailAttachment(filename: "i.png", contentId: "i", data: "PNG")]))
  const bits = ["\r\n", "\n", "--", "=?utf-8?B?", "?=", "=?windows-1256?Q?=E3", "\r\n\r\n", ";",
                "\"", "Content-Type: multipart/mixed; boundary=x\r\n", "--x\r\n", "--x--",
                "Content-Transfer-Encoding: base64\r\n", "Content-Type: message/rfc822\r\n\r\n",
                "filename*0*=utf-8''%D8", "=", "=\r\n", "\0", "\xFF", "<", ">", "(", ")", ":"]
  var r = initRand(2026)
  let rounds = 400
  var n = 0
  for seed in seeds:
    for k in 0 ..< rounds:
      var s = seed
      for j in 0 .. r.rand(6):
        if s.len == 0: break
        let at = r.rand(s.high)
        case r.rand(5)
        of 0: s[at] = char(r.rand(255))
        of 1: s.insert(bits[r.rand(bits.high)], at)
        of 2: s.delete(at .. min(s.high, at + r.rand(40)))
        of 3: s.setLen(at)
        of 4:
          let b = r.rand(s.high)
          let piece = s[min(at, b) .. max(at, b)]
          if s.len + piece.len < 200_000: s.insert(piece, r.rand(s.len))
        else: s[at] = bits[r.rand(bits.high)][0]
      let m = parseMime(s)
      let (h, t) = m.bodies
      discard h.len + t.len
      for a in m.attachments: discard a.filename.len
      discard m.decodedHeader("Subject")
      discard parseAddresses(m.header("From")) & parseAddresses(m.header("To"))
      discard parseMailDate(m.header("Date"))
      proc each(p: MimePart) =
        discard textOf(p)
        for c in p.parts: each(c)
      each(m)
      inc n
  # and the pieces on their own, with random bytes
  for k in 0 ..< 3000:
    var s = ""
    for j in 0 ..< r.rand(80):
      s.add(if r.rand(3) == 0: bits[r.rand(bits.high)] else: $char(r.rand(255)))
    discard decodeWords(s)
    discard parseAddresses(s)
    discard parseMailDate(s)
    discard quotedPrintableDecode(s)
    discard base64UrlDecode(s)
    for cs in ["utf-8", "windows-1256", "utf-16", "gbk", "koi8-r", "us-ascii", s]: discard toUtf8(s, cs)
  echo "  ", n, " damaged messages read without a crash"

echo "test_mime: ok"
