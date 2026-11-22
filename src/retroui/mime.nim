## E-mail messages (MIME, RFC 5322 and 2045-2049) in plain Nim: reading them
## -- a Gmail message in "raw" format, an .eml file, a forwarded message --
## and making them to send (Gmail's send takes the raw message too).
##
## .. code-block:: nim
##   let m = parseMime(readFile("letter.eml"))
##   echo m.decodedHeader("Subject"), " -- ", parseMailDate(m.header("Date"))
##   for a in parseAddresses(m.header("From")): echo a.name, " <", a.email, ">"
##   let (html, text) = m.bodies
##   for f in m.attachments: writeFile(f.filename, f.data)
##
##   writeFile("out.eml", buildMail(OutMail(
##     fromAddr: MailAddress(name: "سلطان", email: "sultan@example.om"),
##     to: @[MailAddress(name: "Maryam", email: "maryam@example.om")],
##     subject: "التقرير الشهري", text: "مرفق التقرير.", html: "<p>مرفق التقرير.</p>",
##     attachments: @[MailAttachment(filename: "تقرير.pdf", data: readFile("r.pdf"))])))
##
## Reading never raises: a broken or cut-off message gives what can be read
## of it. Text comes out as UTF-8 from UTF-8, UTF-16, the ISO-8859 and
## Windows code pages (Arabic windows-1256 and ISO-8859-6 among them) and
## KOI8-R; Chinese, Japanese and Korean through the system (Windows, Linux)
## where it has them. What is made is 7-bit, with CRLF lines of at most 76
## characters.

import std/[strutils, base64, sysrand, times, random, math, algorithm, os]
import codepages

const
  textSimd = not defined(retroNoSimd)
    ## (sixteen bytes at a time: src/retroui/simdtext.h; -d:retroNoSimd the plain loops)
  textKernels = currentSourcePath().substr(0, currentSourcePath().rfind({'/', '\\'})) & "simdtext.h"

proc asciiRun(p: ptr char; n: int): int {.importc: "rut_ascii_run", header: textKernels, cdecl.}
proc find3(p: ptr char; n: int; a, b, c: char): int {.importc: "rut_find3", header: textKernels, cdecl.}
proc b64Decode16(inp: ptr char; n: int; outp: ptr char): int
  {.importc: "rut_b64_decode16", header: textKernels, cdecl.}

type
  MimePart* = ref object
    ## One part of a message (the message itself is the first one).
    headers*: seq[(string, string)]   ## as written, unfolded, not decoded
    contentType*: string              ## lower case, e.g. "text/html"
    params*: seq[(string, string)]    ## its parameters (charset, name, boundary), RFC 2231 decoded, names lower case
    disposition*: string              ## "attachment", "inline" or ""
    filename*: string                 ## decoded (RFC 2231 and 2047) to UTF-8
    contentId*: string                ## without < >
    body*: string                     ## the decoded bytes (base64 / quoted-printable undone), not charset-converted; "" for a multipart
    parts*: seq[MimePart]             ## a multipart's parts; a message/rfc822's message
  MailAddress* = object
    ## A mailbox: "Name <email>".
    name*, email*: string  ## the name shown ("" none) and the address
  MailAttachment* = object
    ## A file in a message, or a picture shown in its HTML (`inline`, by
    ## its `contentId`).
    filename*, contentType*, contentId*: string
      ## its name, its type ("application/pdf"; "" from the name) and, for a
      ## picture the HTML shows, its id (without < >)
    data*: string                     ## its bytes
    inline*: bool                     ## a picture the HTML shows (`cid:`), not a file to save
  OutMail* = object
    ## A message to send (see `buildMail`).
    fromAddr*: MailAddress              ## who sends it
    to*, cc*, bcc*, replyTo*: seq[MailAddress]  ## who it goes to, and where answers go (see `buildMail` for Bcc)
    subject*, text*, html*: string      ## its subject, and its body as plain text and as HTML ("" none)
    inReplyTo*, references*, messageId*: string
      ## the ids it answers and follows (`references`: separated by spaces),
      ## and its own ("" a new one is made); with or without < >
    attachments*: seq[MailAttachment]   ## inline ones (contentId set) go with the html in multipart/related
    date*: float                        ## epoch seconds; 0: now
    extraHeaders*: seq[(string, string)]  ## more header fields (those the message makes itself are left out)

const
  MaxDepth = 30              ## parts inside parts
  MaxParts = 1000            ## parts in a message
  MaxHeaders = 1000          ## header fields in a part
  MaxSize = 256 * 1024 * 1024  ## bytes read of a message

proc addRange(s: var string; src: openArray[char]; a, b: int) =
  ## Appends src[a .. b].
  if b < a: return
  let n = s.len
  s.setLen(n + b - a + 1)
  copyMem(addr s[n], unsafeAddr src[a], b - a + 1)

# ---- base64, quoted-printable ----------------------------------------------------------------

const b64Values = block:
  var t: array[256, int8]
  for i in 0 .. 255: t[i] = -1
  for i, c in "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/": t[ord(c)] = int8(i)
  t[ord('-')] = 62           # (the URL-safe alphabet too)
  t[ord('_')] = 63
  t

proc b64decode(s: openArray[char]): string =
  ## Lenient: other characters are skipped, padding is optional, and "="
  ## ends a group (so two encoded pieces one after the other both come out).
  ## Sixteen letters at a time where a line has them (`simdtext.h`).
  result = newString(s.len * 3 div 4 + 16)
  var used = 0
  var acc = 0'u32
  var bits = 0
  var letters = 0              # (in this group of four: the fast way starts at a group's start)
  var i = 0
  while i < s.len:
    when textSimd:
      if letters == 0 and i + 16 <= s.len:
        let k = b64Decode16(unsafeAddr s[i], s.len - i, addr result[used])
        if k > 0:
          i += k
          used += k div 4 * 3
          continue
    let c = s[i]
    let v = b64Values[ord(c)]
    if v >= 0:
      acc = ((acc shl 6) or uint32(v)) and 0xFFFFFF'u32
      bits += 6
      letters = (letters + 1) and 3
      if bits >= 8:
        bits -= 8
        result[used] = char((acc shr bits) and 0xFF)
        inc used
    elif c == '=':
      bits = 0
      acc = 0
      letters = 0
    inc i
  result.setLen(used)

proc wrap76(s: string): string =
  result = newStringOfCap(s.len + s.len div 38 + 2)
  var i = 0
  while i < s.len:
    if i > 0: result.add "\r\n"
    result.addRange(s, i, min(i + 76, s.len) - 1)
    i += 76

proc base64UrlEncode*(s: string; pad = false): string =
  ## Base64 with the URL-safe alphabet ("-" and "_"), as Gmail's API wants
  ## a raw message; without the "=" padding unless `pad`.
  result = encode(s, safe = true)
  if not pad:
    while result.len > 0 and result[^1] == '=': result.setLen(result.len - 1)

proc base64UrlDecode*(s: string): string =
  ## Base64 in either alphabet, padded or not (other characters skipped).
  b64decode(s)

proc hexVal(c: char): int {.inline.} =
  case c
  of '0'..'9': ord(c) - ord('0')
  of 'a'..'f': ord(c) - ord('a') + 10
  of 'A'..'F': ord(c) - ord('A') + 10
  else: -1

proc quotedPrintableDecode*(s: string): string =
  ## Undoes quoted-printable: "=XX" bytes, "=" soft line breaks, and the
  ## spaces a line may have gathered at its end. A stray "=" stays. The
  ## plain stretches between are copied whole (`simdtext.h` finds where
  ## they end).
  result = newStringOfCap(s.len)
  var i = 0
  var keep = 0          # (result[0 ..< keep] stays: spaces after it, at a line's end, go)
  template trim() =
    while result.len > keep and result[^1] in {' ', '\t'}: result.setLen(result.len - 1)
  while i < s.len:
    # a plain stretch, up to the next "=" or line end
    var n = 0
    when textSimd:
      n = find3(unsafeAddr s[i], s.len - i, '=', '\r', '\n')
    else:
      while i + n < s.len and s[i + n] notin {'=', '\r', '\n'}: inc n
    if n > 0:
      result.addRange(s, i, i + n - 1)
      i += n
      if i >= s.len: break
    let c = s[i]
    if c == '=':
      if i + 2 < s.len and hexVal(s[i+1]) >= 0 and hexVal(s[i+2]) >= 0:
        result.add char(hexVal(s[i+1]) * 16 + hexVal(s[i+2]))
        i += 3
      else:
        var j = i + 1
        while j < s.len and s[j] in {' ', '\t'}: inc j
        if j >= s.len: i = j                         # (at the end)
        elif s[j] == '\n': i = j + 1                 # a soft line break
        elif s[j] == '\r':
          i = j + 1
          if i < s.len and s[i] == '\n': inc i
        else:
          result.add '='
          inc i
      keep = result.len
    else:
      trim()                                       # (spaces at a line's end: dropped)
      result.add c
      inc i
      keep = result.len
  trim()

proc quotedPrintableEncode*(s: string): string =
  ## Quoted-printable with CRLF line breaks (a "\n", "\r\n" or "\r" in `s`
  ## is a line break) and lines of at most 76 characters.
  const hexd = "0123456789ABCDEF"
  result = newStringOfCap(s.len + s.len div 8 + 8)
  var line = 0
  var i = 0
  while i < s.len:
    let c = s[i]
    if c in {'\r', '\n'}:
      result.add "\r\n"
      line = 0
      if c == '\r' and i + 1 < s.len and s[i+1] == '\n': inc i
      inc i
      continue
    let atEnd = i + 1 >= s.len or s[i+1] in {'\r', '\n'}
    var enc = c == '=' or ord(c) > 126 or (ord(c) < 32 and c != '\t') or (c in {' ', '\t'} and atEnd)
    # (a line starting "From " or "." is left alone by no mail server: encoded)
    if line == 0 and (c == '.' or (c == 'F' and s.continuesWith("From ", i))): enc = true
    let w = if enc: 3 else: 1
    if line + w > 75:
      result.add "=\r\n"
      line = 0
    if enc:
      result.add '='
      result.add hexd[ord(c) shr 4]
      result.add hexd[ord(c) and 15]
    else: result.add c
    line += w
    inc i

# ---- UTF-8 and the charsets ------------------------------------------------------------------

proc addCp(s: var string; c: int) =
  ## Appends the code point `c` as UTF-8.
  if c < 0x80: s.add chr(c)
  elif c < 0x800:
    s.add chr(0xC0 or (c shr 6))
    s.add chr(0x80 or (c and 0x3F))
  elif c < 0x10000:
    s.add chr(0xE0 or (c shr 12))
    s.add chr(0x80 or ((c shr 6) and 0x3F))
    s.add chr(0x80 or (c and 0x3F))
  else:
    s.add chr(0xF0 or (c shr 18))
    s.add chr(0x80 or ((c shr 12) and 0x3F))
    s.add chr(0x80 or ((c shr 6) and 0x3F))
    s.add chr(0x80 or (c and 0x3F))

proc utf8Len(s: openArray[char]; i: int): int =
  ## The length of the valid UTF-8 sequence at `i` (1 for ASCII), 0 if
  ## the bytes there are not one.
  let b = ord(s[i])
  if b < 0x80: return 1
  var n, cp, least: int
  if b in 0xC2 .. 0xDF: (n = 1; cp = b and 0x1F; least = 0x80)
  elif b in 0xE0 .. 0xEF: (n = 2; cp = b and 0x0F; least = 0x800)
  elif b in 0xF0 .. 0xF4: (n = 3; cp = b and 0x07; least = 0x10000)
  else: return 0
  if i + n > s.high: return 0
  for k in 1 .. n:
    let c = ord(s[i + k])
    if (c and 0xC0) != 0x80: return 0
    cp = (cp shl 6) or (c and 0x3F)
  if cp < least or cp > 0x10FFFF or cp in 0xD800 .. 0xDFFF: return 0
  n + 1

proc isUtf8(s: string): bool =
  var i = 0
  while i < s.len:
    when textSimd:
      i += asciiRun(unsafeAddr s[i], s.len - i)    # (the ASCII, sixteen at a time)
      if i >= s.len: break
    if ord(s[i]) < 0x80: inc i
    else:
      let n = utf8Len(s, i)
      if n == 0: return false
      i += n
  true

proc validUtf8(s: string): string =
  ## `s` with each byte that is not part of valid UTF-8 replaced by U+FFFD
  ## (and a byte order mark at the start dropped).
  let start = if s.startsWith("\xEF\xBB\xBF"): 3 else: 0
  if isUtf8(s): return (if start == 0: s else: s[start .. ^1])
  result = newStringOfCap(s.len + 16)
  var i = start
  while i < s.len:
    let n = utf8Len(s, i)
    if n == 0:
      result.add "\xEF\xBF\xBD"
      inc i
    else:
      result.addRange(s, i, i + n - 1)
      i += n

proc utf16ToUtf8(u: openArray[uint16]): string =
  result = newStringOfCap(u.len * 2)
  var i = 0
  while i < u.len:
    let c = int(u[i])
    if c in 0xD800 .. 0xDBFF and i + 1 < u.len and int(u[i+1]) in 0xDC00 .. 0xDFFF:
      result.addCp(0x10000 + ((c - 0xD800) shl 10) + (int(u[i+1]) - 0xDC00))
      i += 2
    else:
      result.addCp(if c in 0xD800 .. 0xDFFF: 0xFFFD else: c)
      inc i

proc decodeUtf16(s: string; kind: string): string =
  var le = kind == "utf-16le"
  var start = 0
  if s.len >= 2:
    if s[0] == '\xFF' and s[1] == '\xFE': (le = true; start = 2)
    elif s[0] == '\xFE' and s[1] == '\xFF': (le = false; start = 2)
    elif kind == "utf-16":
      # no byte order mark: the side the zeros of Latin text fall on
      var even, odd = 0
      for i in 0 ..< min(s.len, 400):
        if s[i] == '\0':
          if i mod 2 == 0: inc even else: inc odd
      le = odd > even
  var u = newSeq[uint16]((s.len - start) div 2)
  for k in 0 ..< u.len:
    let a = uint16(ord(s[start + 2*k]))
    let b = uint16(ord(s[start + 2*k + 1]))
    u[k] = if le: a or (b shl 8) else: (a shl 8) or b
  result = utf16ToUtf8(u)
  if (s.len - start) mod 2 == 1: result.add "\xEF\xBF\xBD"

proc normCharset(cs: string): string =
  ## A charset's name as one spelling of it ("CP1256" -> "windows-1256").
  var s = cs.strip(chars = Whitespace + {'"', '\''}).toLowerAscii.replace('_', '-')
  if s.startsWith("x-"): s = s[2 .. ^1]
  if s.startsWith("cp125") and s.len == 6: return "windows-" & s[2 .. ^1]
  if s.startsWith("win-125") and s.len == 8: return "windows-" & s[4 .. ^1]
  if s.startsWith("windows-125") and s.len == 12: return s
  for pre in ["iso-8859-", "iso8859-", "iso-8859", "iso8859"]:
    if s.startsWith(pre):
      var n = ""
      for c in s[pre.len .. ^1]:
        if c in Digits: n.add c else: break
      if n.len > 0: return (if n == "1": "windows-1252" else: "iso-8859-" & n)
  case s
  of "utf8", "utf-8", "unicode-1-1-utf-8": "utf-8"
  of "", "us-ascii", "ascii", "ansi-x3.4-1968", "iso646-us", "us", "cp367", "csascii", "7bit",
     "8bit", "unknown", "unknown-8bit", "default": "us-ascii"
  of "latin1", "l1", "cp819", "ibm819", "iso-ir-100", "csisolatin1": "windows-1252"
  of "latin2", "l2": "iso-8859-2"
  of "cyrillic": "iso-8859-5"
  of "arabic", "asmo-708", "ecma-114": "iso-8859-6"
  of "greek", "greek8", "ecma-118", "elot-928": "iso-8859-7"
  of "hebrew", "visual", "logical": "iso-8859-8"
  of "latin5", "l5": "iso-8859-9"
  of "latin9", "latin-9", "l9": "iso-8859-15"
  of "koi8-r", "koi8r", "koi", "cskoi8r": "koi8-r"
  of "ms-ansi": "windows-1252"
  of "utf-16", "ucs-2", "unicode", "csunicode", "iso-10646-ucs-2": "utf-16"
  of "utf-16le", "unicodefffe": "utf-16le"
  of "utf-16be", "unicodefeff": "utf-16be"
  of "gb2312", "gbk", "cp936", "euc-cn", "chinese", "csgb2312", "gb-2312", "ms936", "windows-936": "gbk"
  of "big5", "big5-hkscs", "cp950", "csbig5", "cn-big5": "big5"
  of "shift-jis", "sjis", "ms-kanji", "cp932", "windows-31j", "csshiftjis", "mskanji": "shift-jis"
  of "euc-jp", "eucjp", "cseucpkdfmtjapanese": "euc-jp"
  of "iso-2022-jp", "csiso2022jp", "jis": "iso-2022-jp"
  of "euc-kr", "ks-c-5601-1987", "ks-c-5601", "cp949", "uhc", "korean", "ksc5601", "windows-949",
     "ksc-5601", "cseuckr": "euc-kr"
  of "tis-620", "windows-874", "cp874": "windows-874"
  else: s

proc decode8(s: string; t: ptr Table8): string =
  result = newStringOfCap(s.len + s.len div 2)
  var i = 0
  while i < s.len:
    when textSimd:
      let n = asciiRun(unsafeAddr s[i], s.len - i)   # (the ASCII as it is, at once)
      if n > 0:
        result.addRange(s, i, i + n - 1)
        i += n
        if i >= s.len: break
    let c = s[i]
    if ord(c) < 0x80: result.add c
    else: result.addCp int(t[][ord(c) - 0x80])
    inc i

# the rest, through the system where it can
when defined(windows):
  proc MultiByteToWideChar(cp, flags: uint32; src: cstring; srcLen: cint; dst: ptr uint16;
                           dstLen: cint): cint {.importc, stdcall, dynlib: "kernel32".}

  proc systemDecode(s, cs: string; ok: var bool): string =
    let cp = case cs
      of "gbk": 936'u32
      of "gb18030": 54936
      of "big5": 950
      of "shift-jis": 932
      of "euc-jp": 20932
      of "iso-2022-jp": 50220
      of "euc-kr": 949
      of "iso-2022-kr": 50225
      of "windows-874": 874
      of "koi8-u": 21866
      of "iso-8859-3": 28593
      of "iso-8859-4": 28594
      of "iso-8859-13": 28603
      of "cp866", "ibm866": 866
      of "cp850", "ibm850": 850
      of "cp437", "ibm437": 437
      of "utf-7": 65000
      else: 0
    if cp == 0 or s.len == 0 or s.len > high(int32) div 2: return
    let n = MultiByteToWideChar(cp, 0, s.cstring, cint(s.len), nil, 0)
    if n <= 0: return
    var u = newSeq[uint16](n)
    if MultiByteToWideChar(cp, 0, s.cstring, cint(s.len), addr u[0], n) != n: return
    ok = true
    utf16ToUtf8(u)

elif defined(linux) and not defined(android):
  proc iconv_open(tocode, fromcode: cstring): pointer {.importc, cdecl.}
  proc iconv(cd: pointer; inbuf: ptr cstring; inleft: ptr csize_t; outbuf: ptr cstring;
             outleft: ptr csize_t): csize_t {.importc, cdecl.}
  proc iconv_close(cd: pointer): cint {.importc, cdecl.}
  proc errnoLocation(): ptr cint {.importc: "__errno_location", cdecl.}

  proc systemDecode(s, cs: string; ok: var bool): string =
    let name = case cs
      of "gbk": "GB18030"                     # (a superset of GBK and GB2312)
      of "big5": "BIG5-HKSCS"
      of "shift-jis": "CP932"
      of "euc-kr": "CP949"
      of "windows-874": "CP874"
      else: cs
    if s.len == 0 or name.len == 0: return
    let cd = iconv_open("UTF-8", name.cstring)
    if cast[int](cd) == -1: return
    var input = s
    var inPtr = input.cstring
    var inLeft = csize_t(input.len)
    var output = newString(input.len * 3 + 16)
    var used = 0
    while inLeft > 0:
      var outPtr = cast[cstring](addr output[used])
      var outLeft = csize_t(output.len - used)
      let before = outLeft
      let r = iconv(cd, addr inPtr, addr inLeft, addr outPtr, addr outLeft)
      used += int(before - outLeft)
      if r != high(csize_t): break
      let err = errnoLocation()[]
      if err == 7:                              # E2BIG: more room
        output.setLen(output.len * 2)
      else:                                     # a bad or cut-off sequence: U+FFFD
        if output.len - used < 4: output.setLen(output.len * 2)
        for c in "\xEF\xBF\xBD":
          output[used] = c
          inc used
        inPtr = cast[cstring](cast[int](inPtr) + 1)
        dec inLeft
    discard iconv_close(cd)
    output.setLen(used)
    ok = true
    validUtf8(output)

else:
  proc systemDecode(s, cs: string; ok: var bool): string = discard

proc toUtf8*(data, charset: string): string =
  ## `data` in `charset` as UTF-8: utf-8, us-ascii, iso-8859-1/2/5/6/7/8/9/15,
  ## windows-1250..1258, koi8-r, utf-16le/be (with or without a byte order
  ## mark); gb2312/gbk/big5/shift_jis/euc-kr and others through Windows or
  ## Linux. Anything else, and bytes that are not of the charset: valid
  ## UTF-8 is kept, other bytes become U+FFFD. (iso-8859-1 and us-ascii are
  ## read as windows-1252, as browsers do.)
  let cs = normCharset(charset)
  case cs
  of "utf-8": return validUtf8(data)
  of "us-ascii":
    return (if isUtf8(data): validUtf8(data) else: decode8(data, table8("windows-1252")))
  of "utf-16", "utf-16le", "utf-16be": return decodeUtf16(data, cs)
  else: discard
  let t = table8(cs)
  if t != nil:
    var ascii = true
    when textSimd:
      ascii = data.len == 0 or asciiRun(unsafeAddr data[0], data.len) == data.len
    else:
      for c in data:
        if ord(c) >= 0x80: (ascii = false; break)
    return (if ascii: data else: decode8(data, t))
  var ok = false
  let s = systemDecode(data, cs, ok)
  if ok: s else: validUtf8(data)

# ---- encoded words (RFC 2047) -----------------------------------------------------------------

proc qDecode(s: string): string =
  var i = 0
  while i < s.len:
    if s[i] == '_': result.add ' '
    elif s[i] == '=' and i + 2 < s.len and hexVal(s[i+1]) >= 0 and hexVal(s[i+2]) >= 0:
      result.add char(hexVal(s[i+1]) * 16 + hexVal(s[i+2]))
      i += 2
    else: result.add s[i]
    inc i

proc encodedWordAt(s: string; i: int; cs, bytes: var string; stop: var int): bool =
  ## An encoded word "=?charset?B|Q?text?=" at `i`.
  var j = i + 2
  let csStart = j
  while j < s.len and j - csStart < 80 and s[j] notin {'?', ' ', '\t', '\r', '\n', '"'}: inc j
  if j >= s.len or s[j] != '?' or j == csStart: return false
  cs = s[csStart ..< j]
  let star = cs.find('*')                      # (charset*language)
  if star >= 0: cs.setLen(star)
  inc j
  if j + 1 >= s.len or s[j+1] != '?' or s[j] notin {'b', 'B', 'q', 'Q'}: return false
  let enc = s[j]
  j += 2
  # (a word is at most 75 long; a few times that is allowed, no more, so a
  # header full of "=?" stays quick)
  let e = s.find("?=", j, min(s.high, j + 1000))
  if e < 0: return false
  let text = s[j ..< e]
  if ' ' in text and enc in {'b', 'B'}: return false
  bytes = if enc in {'b', 'B'}: b64decode(text) else: qDecode(text)
  stop = e + 2
  true

proc decodeWords*(s: string): string =
  ## A header's RFC 2047 encoded words ("=?utf-8?B?...?=", B and Q) as
  ## UTF-8, the space between two of them dropped (and their bytes joined
  ## first, for a character cut in two). The rest: valid UTF-8 kept.
  var plain, cs, bytes: string
  var inWords = false
  var i = 0
  template flushWords() =
    if inWords:
      result.add toUtf8(bytes, cs)
      inWords = false
      bytes.setLen(0)
  template flushPlain() =
    if plain.len > 0:
      result.add validUtf8(plain)
      plain.setLen(0)
  while i < s.len:
    if s[i] == '=' and i + 1 < s.len and s[i+1] == '?':
      var wcs, wbytes: string
      var stop: int
      if encodedWordAt(s, i, wcs, wbytes, stop):
        if inWords:
          plain.setLen(0)                         # (only spaces since the last word)
          if normCharset(wcs) == normCharset(cs): bytes.add wbytes
          else:
            flushWords()
            (cs = wcs; bytes = wbytes; inWords = true)
        else:
          flushPlain()
          (cs = wcs; bytes = wbytes; inWords = true)
        i = stop
        continue
    plain.add s[i]
    if inWords and s[i] notin {' ', '\t', '\r', '\n'}:
      flushWords()                                 # (then the spaces and this go after)
    inc i
  flushWords()
  flushPlain()

proc isPlainAscii(s: string): bool =
  for c in s:
    if ord(c) < 32 or ord(c) > 126: return false
  true

proc encodeWords(s: string): string =
  ## `s` (UTF-8) as encoded words of at most 64 characters, separated by
  ## spaces (where a header may be folded).
  var chunk = ""
  var i = 0
  template flush() =
    if chunk.len > 0:
      if result.len > 0: result.add ' '
      result.add "=?UTF-8?B?" & encode(chunk) & "?="
      chunk.setLen(0)
  while i < s.len:
    var n = utf8Len(s, i)
    let piece = if n == 0: "\xEF\xBF\xBD" else: s[i ..< i + n]
    if n == 0: n = 1
    if chunk.len + piece.len > 39: flush()      # (39 bytes: 52 characters of base64)
    chunk.add piece
    i += n
  flush()

proc cleanLine(s: string): string =
  ## No line breaks or NULs in a header value.
  result = newStringOfCap(s.len)
  for c in s:
    if c in {'\r', '\n', '\t'}: result.add ' '
    elif c != '\0': result.add c

proc headerText(s: string): string =
  ## An unstructured header's text (Subject): as it is when plain ASCII,
  ## else encoded words.
  let t = cleanLine(s)
  if isPlainAscii(t) and "=?" notin t: t else: encodeWords(t)

proc fold(name, value: string): string =
  ## "Name: value" CRLF, folded before spaces so lines stay within 76
  ## characters where the words allow (unfolding gives `value` back).
  result = name & ":"
  var line = result.len
  let start = line
  for w in value.split(' '):
    if w.len > 0 and line > start and line + 1 + w.len > 76:
      result.add "\r\n"
      line = 0
    result.add ' '
    result.add w
    line += 1 + w.len
  result.add "\r\n"

# ---- header values ---------------------------------------------------------------------------

proc percentDecode(s: string): string =
  var i = 0
  while i < s.len:
    if s[i] == '%' and i + 2 < s.len and hexVal(s[i+1]) >= 0 and hexVal(s[i+2]) >= 0:
      result.add char(hexVal(s[i+1]) * 16 + hexVal(s[i+2]))
      i += 3
    else:
      result.add s[i]
      inc i

proc splitValue(v: string): tuple[main: string, params: seq[(string, string)]] =
  ## "text/plain; charset=\"utf-8\"; format=flowed" -> its parts, raw.
  var i = 0
  var q = false
  while i < v.len and (v[i] != ';' or q):
    if v[i] == '"': q = not q
    inc i
  result.main = v[0 ..< i].strip
  while i < v.len:
    while i < v.len and v[i] in {';', ' ', '\t', '\r', '\n'}: inc i
    let ns = i
    while i < v.len and v[i] notin {'=', ';'}: inc i
    let name = v[ns ..< i].strip.toLowerAscii
    if i >= v.len or v[i] == ';': continue         # (a name without a value: skipped)
    inc i                                          # '='
    while i < v.len and v[i] in {' ', '\t'}: inc i
    var val = ""
    if i < v.len and v[i] == '"':
      inc i
      while i < v.len and v[i] != '"':
        if v[i] == '\\' and i + 1 < v.len: inc i
        val.add v[i]
        inc i
      inc i
      while i < v.len and v[i] != ';': inc i       # (anything after the quotes)
    else:
      let vs = i
      while i < v.len and v[i] != ';': inc i
      val = v[vs ..< i].strip
    if name.len > 0 and result.params.len < 100: result.params.add (name, val)

proc decodeParams(raw: seq[(string, string)]): seq[(string, string)] =
  ## RFC 2231: "name*=utf-8''%D8%A7", "name*0*=...; name*1=..." joined and
  ## decoded to UTF-8; a plain value with 8-bit bytes kept as valid UTF-8.
  type Piece = tuple[index: int, ext: bool, value: string]
  var names: seq[string]
  var pieces: seq[seq[Piece]]
  var plain: seq[(string, string)]
  for (n, v) in raw:
    let star = n.find('*')
    if star < 0:
      plain.add (n, v)
      continue
    let base = n[0 ..< star]
    var rest = n[star + 1 .. ^1]
    var ext = false
    var index = 0
    if rest.len == 0: ext = true
    else:
      if rest.endsWith("*"):
        ext = true
        rest.setLen(rest.len - 1)
      try: index = parseInt(rest)
      except ValueError: continue
      if index < 0 or index > 1000: continue
    var k = names.find(base)
    if k < 0:
      names.add base
      pieces.add @[]
      k = names.high
    pieces[k].add (index, ext, v)
  for (n, v) in plain:
    if n notin names: result.add (n, validUtf8(v))
  for k, base in names:
    var ps = pieces[k]
    ps.sort(proc (a, b: Piece): int = cmp(a.index, b.index))
    var charset = "utf-8"
    var bytes = ""
    for j, p in ps:
      var v = p.value
      if p.ext:
        if j == 0:
          let a = v.find('\'')
          let b = if a >= 0: v.find('\'', a + 1) else: -1
          if a >= 0 and b > a:
            if a > 0: charset = v[0 ..< a]
            v = v[b + 1 .. ^1]
        bytes.add percentDecode(v)
      else: bytes.add v
    result.add (base, toUtf8(bytes, charset))

proc param(ps: seq[(string, string)]; name: string): string =
  for (k, v) in ps:
    if k == name: return v

proc param*(p: MimePart; name: string): string =
  ## The value of the Content-Type parameter `name` ("charset", "name"),
  ## "" when there is none.
  if p.isNil: "" else: p.params.param(name.toLowerAscii)

proc header*(p: MimePart; name: string): string =
  ## The first header field `name` (any case), as written (unfolded); ""
  ## when there is none.
  if p.isNil: return
  for (k, v) in p.headers:
    if cmpIgnoreCase(k, name) == 0: return v

proc headerValues*(p: MimePart; name: string): seq[string] =
  ## Every header field `name` (Received, ...), in order.
  if p.isNil: return
  for (k, v) in p.headers:
    if cmpIgnoreCase(k, name) == 0: result.add v

proc decodedHeader*(p: MimePart; name: string): string =
  ## The header field `name` with its encoded words decoded, as UTF-8.
  decodeWords(p.header(name))

# ---- reading ---------------------------------------------------------------------------------

type ParseState = object
  parts: int
  budget: int                ## bytes the forwarded messages may still copy

proc parseHeaders(raw: string; a, b: int; p: MimePart): int =
  ## Reads the header fields of the part in raw[a ..< b]; its body's start.
  var i = a
  var first = true
  while i < b:
    var e = raw.find('\n', i, b - 1)
    if e < 0: e = b
    var lineEnd = e
    if lineEnd > i and raw[lineEnd - 1] == '\r': dec lineEnd
    let next = if e < b: e + 1 else: b
    if lineEnd == i: return next                    # the empty line: the body follows
    if raw[i] in {' ', '\t'}:
      if p.headers.len > 0 and p.headers[^1][1].len < 1_000_000:
        p.headers[^1][1].addRange(raw, i, lineEnd - 1)
      i = next
      continue
    var c = i
    while c < lineEnd and raw[c] != ':' and ord(raw[c]) in 33 .. 126: inc c
    var colon = c
    while colon < lineEnd and raw[colon] in {' ', '\t'}: inc colon
    if c == i or colon >= lineEnd or raw[colon] != ':':
      if first and raw.continuesWith("From ", i):   # (an mbox file's first line)
        first = false
        i = next
        continue
      return i                                     # not a header: the body starts here
    first = false
    if p.headers.len < MaxHeaders:
      p.headers.add (raw[i ..< c], raw[colon + 1 ..< lineEnd])
    i = next
  b

proc findDelimiter(raw, bnd: string; a, b: int): tuple[at, after: int, close: bool] =
  ## The next "--boundary" line in raw[a ..< b]: where it starts, where the
  ## line after it starts, whether it is the closing one.
  let d = "--" & bnd
  var pos = a
  while pos < b:
    let k = raw.find(d, pos, b - 1)
    if k < 0: break
    if k == a or raw[k - 1] == '\n':
      var j = k + d.len
      var close = false
      if j + 1 < b and raw[j] == '-' and raw[j + 1] == '-':
        close = true
        j += 2
      var e = j
      while e < b and raw[e] in {' ', '\t'}: inc e
      if e >= b or raw[e] in {'\r', '\n'}:
        var after = e
        if after < b and raw[after] == '\r': inc after
        if after < b and raw[after] == '\n': inc after
        return (k, after, close)
    pos = k + 1
  (-1, b, false)

proc decodeBody(s: openArray[char]; cte: string): string =
  case cte
  of "base64": b64decode(s)
  of "quoted-printable":
    var t = newString(s.len)
    if s.len > 0: copyMem(addr t[0], unsafeAddr s[0], s.len)
    quotedPrintableDecode(t)
  else:
    var t = newString(s.len)
    if s.len > 0: copyMem(addr t[0], unsafeAddr s[0], s.len)
    t

proc parsePart(raw: string; a, b, depth: int; st: var ParseState; defaultType: string): MimePart

proc parseChildren(p: MimePart; raw: string; a, b, depth: int; st: var ParseState): bool =
  ## The parts of a multipart in raw[a ..< b]; false when its boundary is
  ## not there.
  let bnd = p.params.param("boundary")
  if bnd.len == 0 or bnd.len > 200: return false
  let first = findDelimiter(raw, bnd, a, b)
  if first.at < 0: return false
  let childType = if p.contentType == "multipart/digest": "message/rfc822" else: "text/plain"
  var pos = first.after
  var done = first.close
  while not done and pos < b and st.parts < MaxParts:
    let nx = findDelimiter(raw, bnd, pos, b)
    var stop = b
    if nx.at >= 0:
      stop = nx.at
      if stop > pos and raw[stop - 1] == '\n': dec stop     # (the line break is the delimiter's)
      if stop > pos and raw[stop - 1] == '\r': dec stop
    p.parts.add parsePart(raw, pos, stop, depth + 1, st, childType)
    if nx.at < 0 or nx.close: done = true
    else: pos = nx.after
  true

proc parsePart(raw: string; a, b, depth: int; st: var ParseState; defaultType: string): MimePart =
  result = MimePart()
  inc st.parts
  let p = result
  let bodyAt = parseHeaders(raw, a, b, p)
  for k in 0 ..< p.headers.len:
    p.headers[k][1] = p.headers[k][1].strip
  let (ct, rawParams) = splitValue(p.header("Content-Type"))
  p.params = decodeParams(rawParams)
  let main = ct.toLowerAscii
  let slash = main.find('/')
  p.contentType = if slash > 0 and slash < main.high and ' ' notin main: main else: defaultType
  let (disp, dispParams) = splitValue(p.header("Content-Disposition"))
  let d = disp.toLowerAscii
  p.disposition = if d.len == 0: "" elif d == "inline": "inline" else: "attachment"
  let dps = decodeParams(dispParams)
  var fname = dps.param("filename")
  if fname.len == 0: fname = p.params.param("name")
  p.filename = decodeWords(fname).strip
  var cid = p.header("Content-ID")
  let lt = cid.find('<')
  if lt >= 0:
    let gt = cid.find('>', lt + 1)
    cid = if gt > lt: cid[lt + 1 ..< gt] else: cid[lt + 1 .. ^1]
  p.contentId = cid.strip
  let cte = p.header("Content-Transfer-Encoding").strip.toLowerAscii
  if p.contentType.startsWith("multipart/"):
    var ok = false
    if depth < MaxDepth and st.parts < MaxParts:
      if cte in ["base64", "quoted-printable"]:
        # (not allowed, but sent: the parts are inside the encoding)
        let inner = decodeBody(raw.toOpenArray(bodyAt, b - 1), cte)
        ok = parseChildren(p, inner, 0, inner.len, depth, st)
      else:
        ok = parseChildren(p, raw, bodyAt, b, depth, st)
    if not ok:
      # no boundary to be found: the text as it is
      p.contentType = "text/plain"
      p.body = decodeBody(raw.toOpenArray(bodyAt, b - 1), cte)
  elif p.contentType in ["message/rfc822", "message/global"]:
    p.body = decodeBody(raw.toOpenArray(bodyAt, b - 1), cte)
    if depth < MaxDepth and st.parts < MaxParts and st.budget >= p.body.len:
      st.budget -= p.body.len
      p.parts.add parsePart(p.body, 0, p.body.len, depth + 1, st, "text/plain")
  else:
    p.body = decodeBody(raw.toOpenArray(bodyAt, b - 1), cte)

proc parseMime*(raw: string): MimePart =
  ## A message (RFC 5322 with its MIME parts) read from its raw bytes, CRLF
  ## or LF lines. Never raises: what cannot be read is left out; at most 30
  ## parts deep, 1000 parts and 256 MB.
  var st = ParseState(budget: 2 * raw.len + 1_000_000)
  parsePart(raw, 0, min(raw.len, MaxSize), 0, st, "text/plain")

proc parseMailFile*(path: string): MimePart =
  ## The .eml file at `path` read (an empty message when it cannot be).
  try: parseMime(readFile(path))
  except IOError, OSError: parseMime("")

# ---- the text of a message -------------------------------------------------------------------

proc sniffCharset(html: string): string =
  ## The charset an HTML part declares in a <meta> (when its header does not).
  let head = html[0 ..< min(html.len, 4096)].toLowerAscii
  let k = head.find("charset=")
  if k < 0: return
  var i = k + 8
  while i < head.len and head[i] in {'"', '\'', ' '}: inc i
  while i < head.len and head[i] in {'a'..'z', '0'..'9', '-', '_', ':', '.'}:
    result.add head[i]
    inc i

proc unflow(s: string; delsp: bool): string =
  ## format=flowed text (RFC 3676): the lines that end with a space joined.
  var lines = s.split('\n')
  if s.endsWith("\n"): lines.setLen(lines.len - 1)
  var para = ""
  var paraDepth = -1
  for ln in lines:
    var depth = 0
    while depth < ln.len and ln[depth] == '>': inc depth
    var t = ln[depth .. ^1]
    if t.startsWith(" "): t = t[1 .. ^1]          # (space-stuffing)
    let flowed = t.endsWith(" ") and t != "-- "
    if paraDepth >= 0 and depth != paraDepth:
      result.add para & "\n"
      para = ""
      paraDepth = -1
    if paraDepth < 0:
      para = (if depth > 0: repeat('>', depth) & " " else: "")
      paraDepth = depth
    para.add(if flowed and delsp: t[0 ..< t.high] else: t)
    if not flowed:
      result.add para & "\n"
      para = ""
      paraDepth = -1
  if paraDepth >= 0: result.add para & "\n"
  if result.len > 0 and not s.endsWith("\n"): result.setLen(result.len - 1)

proc textOf*(p: MimePart): string =
  ## A text part's body as UTF-8 (its charset converted, "\n" lines;
  ## format=flowed lines joined).
  if p.isNil: return
  var cs = p.param("charset")
  if cs.len == 0 and p.contentType == "text/html": cs = sniffCharset(p.body)
  let t = toUtf8(p.body, cs)
  result = newStringOfCap(t.len)
  var i = 0
  while i < t.len:
    if t[i] == '\r':
      result.add '\n'
      if i + 1 < t.len and t[i + 1] == '\n': inc i
    else: result.add t[i]
    inc i
  if p.contentType == "text/plain" and p.param("format").toLowerAscii == "flowed":
    result = unflow(result, p.param("delsp").toLowerAscii == "yes")

proc isBodyPart(p: MimePart): bool =
  p.parts.len == 0 and p.contentType in ["text/plain", "text/html"] and
    p.disposition != "attachment" and (p.filename.len == 0 or p.disposition == "inline")

proc textToHtml(t: string): string =
  result = "<pre>"
  for c in t:
    case c
    of '<': result.add "&lt;"
    of '>': result.add "&gt;"
    of '&': result.add "&amp;"
    else: result.add c
  result.add "</pre>"

proc collect(p: MimePart; used: var seq[MimePart]): tuple[html, text: string] =
  ## The best HTML and text of `p`, and the parts they came from.
  if p.contentType.startsWith("multipart/"):
    if p.parts.len == 0: return
    case p.contentType
    of "multipart/alternative":
      # the last (richest) alternative of each kind
      var hi, ti = -1
      var got: seq[tuple[html, text: string]]
      var uses: seq[seq[MimePart]]
      for k, c in p.parts:
        var u: seq[MimePart]
        got.add collect(c, u)
        uses.add u
        if got[k].html.len > 0: hi = k
        if got[k].text.len > 0: ti = k
      if hi >= 0:
        result.html = got[hi].html
        used.add uses[hi]
      if ti >= 0:
        result.text = got[ti].text
        if ti != hi: used.add uses[ti]
    of "multipart/related":
      var root = p.parts[0]
      var start = p.param("start").strip(chars = {'<', '>', ' '})
      if start.len > 0:
        for c in p.parts:
          if c.contentId == start: root = c
      result = collect(root, used)
    of "multipart/signed":
      result = collect(p.parts[0], used)
    of "multipart/encrypted": discard
    else:
      # mixed and the rest: the texts one after the other
      var got: seq[tuple[html, text: string]]
      var anyHtml = false
      for c in p.parts:
        if c.parts.len == 0 and not c.isBodyPart: continue
        if c.contentType in ["message/rfc822", "message/global"]: continue
        let r = collect(c, used)
        if r.html.len > 0 or r.text.len > 0:
          got.add r
          anyHtml = anyHtml or r.html.len > 0
      for r in got:
        if r.text.len > 0:
          if result.text.len > 0 and not result.text.endsWith("\n"): result.text.add "\n"
          result.text.add r.text
        if anyHtml:
          result.html.add(if r.html.len > 0: r.html else: textToHtml(r.text))
  elif p.isBodyPart:
    used.add p
    if p.contentType == "text/html": result.html = textOf(p)
    else: result.text = textOf(p)

proc bodies*(root: MimePart): tuple[html, text: string] =
  ## The message's HTML and plain text, as UTF-8 -- the best of
  ## multipart/alternative, the root of multipart/related, the texts of
  ## multipart/mixed one after another. "" when it has none of a kind.
  if root.isNil: return
  var used: seq[MimePart]
  collect(root, used)

const extOf = [("image/png", ".png"), ("image/jpeg", ".jpg"), ("image/gif", ".gif"),
               ("image/webp", ".webp"), ("image/bmp", ".bmp"), ("image/svg+xml", ".svg"),
               ("image/tiff", ".tif"), ("image/heic", ".heic"), ("application/pdf", ".pdf"),
               ("text/plain", ".txt"), ("text/html", ".html"), ("text/calendar", ".ics"),
               ("text/csv", ".csv"), ("application/zip", ".zip"), ("application/json", ".json"),
               ("message/delivery-status", ".txt"), ("text/rfc822-headers", ".txt"),
               ("application/pkcs7-signature", ".p7s"), ("application/x-pkcs7-signature", ".p7s"),
               ("application/pgp-signature", ".asc"), ("application/ics", ".ics"),
               ("audio/mpeg", ".mp3"), ("video/mp4", ".mp4"), ("audio/wav", ".wav"),
               ("application/msword", ".doc"), ("application/vnd.ms-excel", ".xls"),
               ("application/vnd.ms-powerpoint", ".ppt"),
               ("application/vnd.openxmlformats-officedocument.wordprocessingml.document", ".docx"),
               ("application/vnd.openxmlformats-officedocument.spreadsheetml.sheet", ".xlsx"),
               ("application/vnd.openxmlformats-officedocument.presentationml.presentation", ".pptx"),
               ("application/xml", ".xml"), ("text/xml", ".xml"), ("message/rfc822", ".eml")]

proc mimeTypeOf*(filename: string): string =
  ## The content type a file's extension stands for ("application/pdf");
  ## "application/octet-stream" when it is not known.
  let dot = filename.rfind('.')
  if dot < 0: return "application/octet-stream"
  let ext = filename[dot .. ^1].toLowerAscii
  case ext
  of ".jpeg", ".jpe", ".jfif": return "image/jpeg"
  of ".htm": return "text/html"
  of ".tiff": return "image/tiff"
  of ".log", ".text", ".md": return "text/plain"
  of ".7z": return "application/x-7z-compressed"
  of ".rar": return "application/vnd.rar"
  of ".odt": return "application/vnd.oasis.opendocument.text"
  of ".ods": return "application/vnd.oasis.opendocument.spreadsheet"
  of ".rtf": return "application/rtf"
  of ".m4a": return "audio/mp4"
  of ".mov": return "video/quicktime"
  else: discard
  for (t, e) in extOf:
    if e == ext: return t
  "application/octet-stream"

proc safeFileName(s: string): string =
  ## A file name from a message, safe to save: no folders, no characters
  ## Windows refuses, not too long.
  result = ""         # (a value at once: see tools/writecheck.py)
  var t = s
  let slash = max(t.rfind('/'), t.rfind('\\'))
  if slash >= 0: t = t[slash + 1 .. ^1]
  for c in t:
    if ord(c) < 32 or c in {'<', '>', ':', '"', '|', '?', '*', '\x7F'}: result.add '_'
    else: result.add c
  result = result.strip(chars = {' ', '.'})
  if result.len > 200:
    var n = 200
    while n > 0 and (ord(result[n]) and 0xC0) == 0x80: dec n   # (a whole character)
    result.setLen(n)

proc attachments*(root: MimePart): seq[MailAttachment] =
  ## The message's files and inline pictures (`inline` when the HTML shows
  ## them by `contentId`); a forwarded message (message/rfc822) is an .eml
  ## file. File names are made safe to save; a part without one gets one.
  if root.isNil: return
  var used: seq[MimePart]
  let html = collect(root, used).html
  var n = 0
  proc walk(p: MimePart; res: var seq[MailAttachment]) =
    if p in used: return
    if p.contentType.startsWith("multipart/"):
      for c in p.parts: walk(c, res)
      return
    if p.isBodyPart: return                        # (a text that was not the best)
    inc n
    var a = MailAttachment(contentType: p.contentType, contentId: p.contentId, data: p.body)
    a.filename = safeFileName(p.filename)
    if p.contentType in ["message/rfc822", "message/global"]:
      if a.filename.len == 0 and p.parts.len > 0:
        a.filename = safeFileName(p.parts[0].decodedHeader("Subject"))
      if a.filename.len == 0: a.filename = "message"
      if not a.filename.toLowerAscii.endsWith(".eml"): a.filename.add ".eml"
    if a.filename.len == 0:
      var ext = ""
      for (t, e) in extOf:
        if t == p.contentType: (ext = e; break)
      let at = p.contentId.find('@')
      let cidName = if at > 0: safeFileName(p.contentId[0 ..< at]) else: ""
      if cidName.len > 0 and '.' in cidName: a.filename = cidName
      elif p.contentType == "application/pkcs7-signature": a.filename = "smime.p7s"
      else: a.filename = "attachment" & (if n > 1: "-" & $n else: "") & (if ext.len > 0: ext else: ".bin")
    if p.contentId.len > 0 and html.len > 0:
      a.inline = ("cid:" & p.contentId) in html or ("cid:" & p.contentId.replace("@", "%40")) in html
    res.add a
  walk(root, result)

# ---- addresses -------------------------------------------------------------------------------

proc parseAddresses*(s: string): seq[MailAddress] =
  ## The mailboxes of an address header: "A <a@x>, \"B, C\" <b@y>, c@z
  ## (Cee)", groups ("Team: a@x, b@y;"), encoded-word names, and Outlook's
  ## ";" between addresses.
  var name, bare, angle, comment: string
  var hasAngle = false
  var inGroup = false
  template finish() =
    var email = ""
    var nm = ""
    if hasAngle:
      email = angle.strip
      let colon = email.rfind(':')                 # (an old route: "@a,@b:x@y")
      if colon >= 0 and email.startsWith("@"): email = email[colon + 1 .. ^1]
      nm = name
    else:
      # no <...>: the word with an "@" is the address, the rest a name
      var words = bare.splitWhitespace
      var at = -1
      for k, w in words:
        if '@' in w: at = k
      if at >= 0:
        email = words[at]
        words.delete(at)
        nm = words.join(" ")
      elif words.len == 1:
        email = words[0]
    nm = decodeWords(nm.splitWhitespace.join(" ")).strip
    if nm.len >= 2 and nm[0] == '\'' and nm[^1] == '\'': nm = nm[1 .. ^2].strip
    if nm.len >= 2 and nm[0] == '"' and nm[^1] == '"': nm = nm[1 .. ^2].strip
    if nm.len == 0: nm = decodeWords(comment.strip)
    email = email.strip(chars = Whitespace + {'<', '>', '"'})
    if email.len > 0 and ' ' notin email and result.len < 10_000:
      result.add MailAddress(name: nm, email: email)
    name.setLen(0); bare.setLen(0); angle.setLen(0); comment.setLen(0)
    hasAngle = false
  var i = 0
  while i < s.len:
    let c = s[i]
    case c
    of '"':
      inc i
      var q = ""
      while i < s.len and s[i] != '"':
        if s[i] == '\\' and i + 1 < s.len: inc i
        q.add s[i]
        inc i
      if name.len > 0 and name[^1] != ' ': name.add ' '
      name.add q
      bare.add '"' & q & '"'
    of '(':
      var depth = 1
      inc i
      var t = ""
      while i < s.len and depth > 0:
        if s[i] == '\\' and i + 1 < s.len: inc i
        elif s[i] == '(': inc depth
        elif s[i] == ')':
          dec depth
          if depth == 0: break
        t.add s[i]
        inc i
      comment = t
      bare.add ' '
    of '<':
      inc i
      var t = ""
      while i < s.len and s[i] != '>':
        t.add s[i]
        inc i
      angle = t
      hasAngle = true
    of ':':
      if not hasAngle and '@' notin bare:          # a group's name
        name.setLen(0); bare.setLen(0); comment.setLen(0)
        inGroup = true
      else:
        name.add c
        bare.add c
    of ';':
      finish()
      inGroup = false
    of ',':
      finish()
    else:
      name.add c
      bare.add c
    inc i
  finish()

proc cleanEmail(s: string): string =
  for c in s:
    if c notin {'\r', '\n', '\t', ' ', '<', '>', '\0', '"', ',', ';'}: result.add c

proc `$`*(a: MailAddress): string =
  ## The address as written in a header: `Name <email>`, the name quoted or
  ## made encoded words when it needs to be.
  let email = cleanEmail(a.email)
  let name = cleanLine(a.name).strip
  if name.len == 0: return email
  const atext = {'a'..'z', 'A'..'Z', '0'..'9', '!', '#', '$', '%', '&', '\'', '*', '+', '-',
                 '/', '=', '?', '^', '_', '`', '{', '|', '}', '~', ' '}
  var plain = isPlainAscii(name) and "=?" notin name
  var simple = plain
  for c in name:
    if c notin atext: simple = false
  if simple: name & " <" & email & ">"
  elif plain: "\"" & name.replace("\\", "\\\\").replace("\"", "\\\"") & "\" <" & email & ">"
  else: encodeWords(name) & " <" & email & ">"

# ---- dates -----------------------------------------------------------------------------------

proc daysFromCivil(y, m, d: int): int64 =
  let y = if m <= 2: y - 1 else: y
  let era = (if y >= 0: y else: y - 399) div 400
  let yoe = y - era * 400
  let doy = (153 * (if m > 2: m - 3 else: m + 9) + 2) div 5 + d - 1
  let doe = yoe * 365 + yoe div 4 - yoe div 100 + doy
  int64(era) * 146097 + int64(doe) - 719468

proc civilFromDays(z: int64): tuple[y, m, d: int] =
  let z = z + 719468
  let era = (if z >= 0: z else: z - 146096) div 146097
  let doe = int(z - era * 146097)
  let yoe = (doe - doe div 1460 + doe div 36524 - doe div 146096) div 365
  let doy = doe - (365 * yoe + yoe div 4 - yoe div 100)
  let mp = (5 * doy + 2) div 153
  result.d = doy - (153 * mp + 2) div 5 + 1
  result.m = if mp < 10: mp + 3 else: mp - 9
  result.y = int(yoe + era * 400) + (if result.m <= 2: 1 else: 0)

const
  monthNames = ["jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec"]
  dayNames = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]

proc parseMailDate*(s: string): float =
  ## A Date header (RFC 5322: "Mon, 3 Nov 2025 14:05:09 +0400") as epoch
  ## seconds; also two-digit years, missing seconds or weekday, zone names
  ## (GMT, EST...), "Mon Nov  3 14:05:09 2025" and ISO 8601. 0 when it is
  ## not a date.
  var t = ""
  var depth = 0
  for c in s:                                      # (comments out)
    if c == '(': inc depth
    elif c == ')': (if depth > 0: dec depth)
    elif depth == 0: t.add c
  t = t.strip
  var year, month, day = -1
  var hour, minute, second = 0
  var zone = 0
  var pm = 0
  # ISO 8601: 2025-11-03T14:05:09+04:00
  if t.len >= 10 and t[4] == '-' and t[7] == '-' and t[0 .. 3].allCharsInSet(Digits):
    try:
      year = parseInt(t[0 .. 3])
      month = parseInt(t[5 .. 6])
      day = parseInt(t[8 .. 9])
    except ValueError: return 0
    t = t[10 .. ^1]
    if t.len > 0 and t[0] in {'T', 't'}: t[0] = ' '
    t = t.replace("Z", " +0000").replace("z", " +0000")
    # a zone written right after the time: "14:05:09+04:00"
    for k in 1 ..< t.len:
      if t[k] in {'+', '-'} and t[k - 1] in Digits:
        t = t[0 ..< k] & " " & t[k .. ^1]
        break
  var tokens: seq[string]
  for w in t.split({' ', '\t', ',', '\r', '\n'}):
    if w.len > 0: tokens.add w
  for tok in tokens:
    let low = tok.toLowerAscii
    try:
      if ':' in tok and tok[0] in Digits:
        let f = tok.split(':')
        if f.len >= 2:
          hour = parseInt(f[0])
          minute = parseInt(f[1])
          if f.len > 2: second = parseInt(f[2].split('.')[0])
      elif tok[0] in {'+', '-'} and tok.len >= 3 and tok[1 .. ^1].replace(":", "").allCharsInSet(Digits):
        let d = tok[1 .. ^1].replace(":", "")
        let v = if d.len <= 2: parseInt(d) * 100 else: parseInt(d)
        zone = (v div 100) * 60 + v mod 100
        if tok[0] == '-': zone = -zone
      elif tok.allCharsInSet(Digits):
        let v = parseInt(tok)
        if tok.len >= 3 and year < 0: year = (if tok.len == 3: v + 1900 else: v)
        elif day < 0 and v in 1 .. 31 and tok.len <= 2: day = v
        elif year < 0: year = (if v < 50: v + 2000 elif v < 100: v + 1900 else: v)
      elif low.len >= 3 and low[0 .. 2] in monthNames and month < 0:
        month = monthNames.find(low[0 .. 2]) + 1
      else:
        case low
        of "ut", "utc", "gmt", "z": zone = 0
        of "edt": zone = -4 * 60
        of "est", "cdt": zone = -5 * 60
        of "cst", "mdt": zone = -6 * 60
        of "mst", "pdt": zone = -7 * 60
        of "pst": zone = -8 * 60
        of "am": pm = 1
        of "pm": pm = 2
        else: discard
    except ValueError: discard
  if pm == 2 and hour < 12: hour += 12
  elif pm == 1 and hour == 12: hour = 0
  if year < 1 or year > 9999 or month notin 1 .. 12 or day < 1: return 0
  let dim = [31, (if (year mod 4 == 0 and year mod 100 != 0) or year mod 400 == 0: 29 else: 28),
             31, 30, 31, 30, 31, 31, 30, 31, 30, 31]
  if day > dim[month - 1] or hour notin 0 .. 24 or minute notin 0 .. 59 or second notin 0 .. 61:
    return 0
  float(daysFromCivil(year, month, day) * 86400 + hour * 3600 + minute * 60 + min(second, 59) -
        zone * 60)

proc formatMailDate*(t: float): string =
  ## Epoch seconds as an RFC 5322 date, in UTC: "Tue, 03 Nov 2026 09:30:00 +0000".
  let secs = if t != t: 0'i64 else: int64(floor(clamp(t, -62_135_596_800.0, 253_402_300_799.0)))
  let days = floorDiv(secs, 86400)
  let rest = int(secs - days * 86400)
  let (y, m, d) = civilFromDays(days)
  dayNames[int(floorMod(days + 4, 7))] & ", " & align($d, 2, '0') & " " &
    monthNames[m - 1].capitalizeAscii & " " & $y & " " & align($(rest div 3600), 2, '0') & ":" &
    align($(rest div 60 mod 60), 2, '0') & ":" & align($(rest mod 60), 2, '0') & " +0000"

# ---- making a message ------------------------------------------------------------------------

proc randomHex(n: int): string =
  var b = newSeq[byte](n)
  if not urandom(b):
    var r = initRand(int64(epochTime() * 1e6))
    for x in b.mitems: x = byte(r.rand(255))
  for x in b: result.add toHex(int(x), 2).toLowerAscii

proc newMessageId*(domain: string): string =
  ## A new, unique Message-ID for `domain`: "<random@domain>".
  var d = ""
  for c in domain:
    if c in {'a'..'z', 'A'..'Z', '0'..'9', '-', '.', '_'}: d.add c
  if d.len == 0: d = "localhost"
  "<" & randomHex(12) & "." & toHex(int64(epochTime()), 8).toLowerAscii & "@" & d & ">"

type Entity = object
  headers: seq[(string, string)]
  body: string
  boundary: string
  parts: seq[Entity]

proc paramText(name, value: string): string =
  ## "; name=value", quoted, or RFC 2231 (continued over lines when long).
  let v = cleanLine(value)
  const token = {'a'..'z', 'A'..'Z', '0'..'9', '!', '#', '$', '%', '&', '\'', '*', '+', '-',
                 '.', '^', '_', '`', '{', '|', '}', '~'}
  if v.len > 0 and v.len <= 60 and v.allCharsInSet(token): return "; " & name & "=" & v
  if isPlainAscii(v) and v.len <= 60:
    return "; " & name & "=\"" & v.replace("\\", "\\\\").replace("\"", "\\\"") & "\""
  const hexd = "0123456789ABCDEF"
  var chunks: seq[string]
  var cur = ""
  var i = 0
  while i < v.len:
    var n = utf8Len(v, i)
    if n == 0: n = 1
    var piece = ""
    for k in i ..< i + n:
      let c = v[k]
      if c in token and c notin {'%', '\'', '*'}: piece.add c
      else: piece.add '%' & hexd[ord(c) shr 4] & hexd[ord(c) and 15]
    if cur.len + piece.len > 48:
      chunks.add cur
      cur = ""
    cur.add piece
    i += n
  chunks.add cur
  if chunks.len == 1: return "; " & name & "*=utf-8''" & chunks[0]
  for k, c in chunks:
    result.add "; " & name & "*" & $k & "*=" & (if k == 0: "utf-8''" else: "") & c

proc nameParam(value: string): string =
  ## Content-Type's "name", as most mail programs read it: encoded words
  ## inside the quotes when it is not plain ASCII.
  let v = cleanLine(value)
  if isPlainAscii(v): paramText("name", v)
  else: "; name=\"" & encodeWords(v) & "\""

proc crlf(s: string): string =
  ## Lines ended by CRLF.
  result = newStringOfCap(s.len + s.len div 40)
  var i = 0
  while i < s.len:
    if s[i] == '\r':
      result.add "\r\n"
      if i + 1 < s.len and s[i + 1] == '\n': inc i
    elif s[i] == '\n': result.add "\r\n"
    else: result.add s[i]
    inc i

proc textEntity(text, subtype: string): Entity =
  let t = crlf(validUtf8(text))
  let qp = quotedPrintableEncode(t)
  result.headers.add ("Content-Type", "text/" & subtype & "; charset=utf-8")
  if qp == t:
    result.headers.add ("Content-Transfer-Encoding", "7bit")
    result.body = t
  else:
    # quoted-printable, or base64 when it is shorter (Arabic, mostly)
    let b64 = wrap76(encode(t))
    if b64.len < qp.len:
      result.headers.add ("Content-Transfer-Encoding", "base64")
      result.body = b64
    else:
      result.headers.add ("Content-Transfer-Encoding", "quoted-printable")
      result.body = qp

proc fileEntity(a: MailAttachment; inline: bool): Entity =
  let fname = if a.filename.len > 0: a.filename else: "attachment"
  var ct = a.contentType.strip.toLowerAscii
  if ct.len == 0 or ct == "application/octet-stream" or '/' notin ct or ' ' in ct or ';' in ct:
    ct = mimeTypeOf(fname)
  result.headers.add ("Content-Type", ct & nameParam(fname))
  result.headers.add ("Content-Disposition", (if inline: "inline" else: "attachment") &
                      paramText("filename", fname))
  if a.contentId.len > 0:
    result.headers.add ("Content-ID", "<" & cleanEmail(a.contentId) & ">")
  var sevenBit = ct == "message/rfc822"
  if sevenBit:
    for c in a.data:
      if ord(c) > 127 or c == '\0': (sevenBit = false; break)
  if sevenBit:
    # (a message stays readable as it is; RFC 2046 wants it unencoded)
    result.headers.add ("Content-Transfer-Encoding", "7bit")
    result.body = crlf(a.data)
  else:
    result.headers.add ("Content-Transfer-Encoding", "base64")
    result.body = wrap76(encode(a.data))

proc multipart(subtype: string; parts: seq[Entity]; extra = ""): Entity =
  # ("=_" cannot come out of quoted-printable, nor out of base64)
  result.boundary = "=_retro_" & randomHex(12)
  result.headers.add ("Content-Type", "multipart/" & subtype & "; boundary=\"" & result.boundary &
                      "\"" & extra)
  result.parts = parts

proc render(e: Entity; s: var string) =
  for (k, v) in e.headers: s.add fold(k, v)
  s.add "\r\n"
  if e.parts.len == 0:
    s.add e.body
  else:
    for p in e.parts:
      s.add "--" & e.boundary & "\r\n"
      render(p, s)
      s.add "\r\n"
    s.add "--" & e.boundary & "--\r\n"

proc addressList(a: seq[MailAddress]): string =
  for k, x in a:
    if k > 0: result.add ", "
    result.add $x

proc angled(id: string): string =
  let t = cleanEmail(id)
  if t.len == 0: "" elif t.startsWith("<"): t else: "<" & t & ">"

proc buildMail*(m: OutMail): string =
  ## The message, ready to send: CRLF lines, 7-bit (quoted-printable or
  ## base64 text, base64 files, lines of at most 76), text and HTML as
  ## multipart/alternative, inline pictures with the HTML in
  ## multipart/related, files in multipart/mixed, encoded words in the
  ## headers, MIME-Version, and a Date and Message-ID when not given. A Bcc
  ## header is written when `bcc` is set (Gmail's and Graph's send read and
  ## drop it; for SMTP leave it out and give the addresses to the server).
  var inlines, files: seq[Entity]
  for a in m.attachments:
    if a.contentId.len > 0 and m.html.len > 0: inlines.add fileEntity(a, true)
    else: files.add fileEntity(a, false)
  var content: Entity
  if m.html.len > 0:
    var h = textEntity(m.html, "html")
    if inlines.len > 0: h = multipart("related", @[h] & inlines, "; type=\"text/html\"")
    content = if m.text.len > 0: multipart("alternative", @[textEntity(m.text, "plain"), h]) else: h
  else:
    content = textEntity(m.text, "plain")
  if files.len > 0: content = multipart("mixed", @[content] & files)

  let date = if m.date == 0: epochTime() else: m.date
  result.add fold("Date", formatMailDate(date))
  result.add fold("From", $m.fromAddr)
  if m.replyTo.len > 0: result.add fold("Reply-To", addressList(m.replyTo))
  if m.to.len > 0: result.add fold("To", addressList(m.to))
  if m.cc.len > 0: result.add fold("Cc", addressList(m.cc))
  if m.bcc.len > 0: result.add fold("Bcc", addressList(m.bcc))
  result.add fold("Subject", headerText(m.subject))
  let at = m.fromAddr.email.rfind('@')
  let id = if m.messageId.len > 0: angled(m.messageId)
           else: newMessageId(if at >= 0: m.fromAddr.email[at + 1 .. ^1] else: "")
  result.add fold("Message-ID", id)
  if m.inReplyTo.len > 0: result.add fold("In-Reply-To", angled(m.inReplyTo))
  if m.references.len > 0:
    var refs: seq[string]
    for r in cleanLine(m.references).splitWhitespace: refs.add angled(r)
    result.add fold("References", refs.join(" "))
  const own = ["date", "from", "reply-to", "to", "cc", "bcc", "subject", "message-id",
               "in-reply-to", "references", "mime-version", "content-type",
               "content-transfer-encoding", "content-disposition"]
  for (k, v) in m.extraHeaders:
    if k.len == 0 or not k.allCharsInSet({'!'..'~'} - {':'}) or k.toLowerAscii in own: continue
    result.add fold(k, headerText(v))
  result.add "MIME-Version: 1.0\r\n"
  render(content, result)
