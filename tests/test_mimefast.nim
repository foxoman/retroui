## Mail's text sixteen bytes at a time (src/retroui/simdtext.h, in
## retroui/mime): base64, quoted-printable, UTF-8 checked, 8-bit charsets
## made UTF-8 -- the very bytes of the plain loops (kept here, as they
## were), on made-up text and on random bytes; and how fast each is (a
## message's attachments, a newsletter's HTML).
##
## Developed by Sultan Al Isaiee @foxoman -- www.foxoman.net -- sultan@foxoman.net

import std/[strutils, random, times, base64, monotimes]
import retroui/mime

var failures = 0
template check(cond: bool; what: string) =
  if cond: echo "  ok   ", what
  else:
    echo "  FAIL ", what
    inc failures

# ---- the plain loops, as they were ----------------------------------------------------

const b64Values = block:
  var t: array[256, int8]
  for i in 0 .. 255: t[i] = -1
  for i, c in "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/": t[ord(c)] = int8(i)
  t[ord('-')] = 62
  t[ord('_')] = 63
  t

proc oldB64(s: string): string =
  var acc = 0'u32
  var bits = 0
  for c in s:
    let v = b64Values[ord(c)]
    if v >= 0:
      acc = ((acc shl 6) or uint32(v)) and 0xFFFFFF'u32
      bits += 6
      if bits >= 8:
        bits -= 8
        result.add char((acc shr bits) and 0xFF)
    elif c == '=':
      bits = 0
      acc = 0

proc hexVal(c: char): int =
  case c
  of '0'..'9': ord(c) - ord('0')
  of 'a'..'f': ord(c) - ord('a') + 10
  of 'A'..'F': ord(c) - ord('A') + 10
  else: -1

proc oldQp(s: string): string =
  var i = 0
  while i < s.len:
    let c = s[i]
    if c == '=':
      if i + 2 < s.len and hexVal(s[i+1]) >= 0 and hexVal(s[i+2]) >= 0:
        result.add char(hexVal(s[i+1]) * 16 + hexVal(s[i+2]))
        i += 3
        continue
      var j = i + 1
      while j < s.len and s[j] in {' ', '\t'}: inc j
      if j >= s.len: i = j
      elif s[j] == '\n': i = j + 1
      elif s[j] == '\r':
        i = j + 1
        if i < s.len and s[i] == '\n': inc i
      else:
        result.add '='
        inc i
    elif c in {' ', '\t'}:
      var j = i
      while j < s.len and s[j] in {' ', '\t'}: inc j
      if j < s.len and s[j] notin {'\r', '\n'}: result.add s[i ..< j]
      i = j
    else:
      result.add c
      inc i

proc oldLatin1(s: string): string =
  for c in s:
    if ord(c) < 0x80: result.add c
    else:
      let cp = ord(c)
      result.add chr(0xC0 or (cp shr 6))
      result.add chr(0x80 or (cp and 0x3F))

proc oldUtf8Len(s: string; i: int): int =
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

proc oldValid(s: string): string =
  let start = if s.startsWith("\xEF\xBB\xBF"): 3 else: 0
  block whole:
    var i = 0
    while i < s.len:
      if ord(s[i]) < 0x80: inc i
      else:
        let n = oldUtf8Len(s, i)
        if n == 0: break whole
        i += n
    return (if start == 0: s else: s[start .. ^1])
  var i = start
  while i < s.len:
    let n = oldUtf8Len(s, i)
    if n == 0:
      result.add "\xEF\xBF\xBD"
      inc i
    else:
      result.add s[i ..< i + n]
      i += n

# ---- the same bytes -----------------------------------------------------------------------

randomize(2026)
proc randomBytes(n: int; pick: string = ""): string =
  result = newString(n)
  for i in 0 ..< n:
    result[i] = if pick.len > 0: pick[rand(pick.high)] else: char(rand(255))

echo "the same bytes as the plain loops"
block:
  var bad = 0
  for round in 0 ..< 400:
    let data = randomBytes(rand(3000))
    var enc = encode(data)
    # (lines of 76, sometimes CRLF, sometimes LF, a stray space, pieces padded one after another)
    var lined = ""
    var k = 0
    while k < enc.len:
      lined.add enc[k ..< min(k + 76, enc.len)]
      lined.add(if round mod 3 == 0: "\n" else: "\r\n")
      if round mod 7 == 0: lined.add " "
      k += 76
    if round mod 5 == 0: lined.add encode("tail") & "\r\n"
    if round mod 11 == 0: lined = lined.replace('+', '-').replace('/', '_')
    if base64UrlDecode(lined) != oldB64(lined): inc bad
    let junk = randomBytes(rand(500), "ABCabc019+/-_= \r\n\t#")
    if base64UrlDecode(junk) != oldB64(junk): inc bad
  check bad == 0, "base64: 800 inputs, lines and junk (" & $bad & " differ)"
block:
  var bad = 0
  for round in 0 ..< 600:
    let s = randomBytes(rand(2000), "ab c\t=\r\n=3D=20=0AxyzZ09F ") &
            (if round mod 2 == 0: "  " else: "=") & randomBytes(rand(20), " \t\r\n=AF")
    if quotedPrintableDecode(s) != oldQp(s): inc bad
    let r = randomBytes(rand(1000))
    if quotedPrintableDecode(r) != oldQp(r): inc bad
  check bad == 0, "quoted-printable: 1200 inputs (" & $bad & " differ)"
block:
  var bad = 0
  for round in 0 ..< 400:
    var s = randomBytes(rand(400), "Plain text, mostly ASCII. ") & "مرحبا" & randomBytes(rand(300), "abc ")
    if round mod 3 == 0: s.add randomBytes(rand(20))          # (bytes that are not UTF-8)
    if round mod 5 == 0: s = "\xEF\xBB\xBF" & s
    if toUtf8(s, "utf-8") != oldValid(s): inc bad
    var l = randomBytes(rand(800))
    for c in l.mitems:          # (0x80..0x9F are windows-1252's here, as browsers read them)
      if ord(c) in 0x80 .. 0x9F: c = 'x'
    if toUtf8(l, "iso-8859-1") != oldLatin1(l): inc bad
  check bad == 0, "UTF-8 checked, Latin-1 made UTF-8: 800 inputs (" & $bad & " differ)"

# ---- how fast -------------------------------------------------------------------------

echo "how fast (MB/s; the plain loop's in brackets)"
proc mbps(bytes: int; t: float): string = formatFloat(float(bytes) / 1e6 / max(t, 1e-9), ffDecimal, 0)
template timed(body: untyped): float =
  let t0 = getMonoTime()
  for rep in 0 ..< 5: body
  (getMonoTime() - t0).inNanoseconds.float / 1e9 / 5
block:
  let raw = randomBytes(8_000_000)
  var lined = ""
  let enc = encode(raw)
  var k = 0
  while k < enc.len:
    lined.add enc[k ..< min(k + 76, enc.len)]
    lined.add "\r\n"
    k += 76
  var a, b: string
  let tNew = timed((a = base64UrlDecode(lined)))
  let tOld = timed((b = oldB64(lined)))
  check a == raw and b == raw, "base64, an 8 MB attachment: " & mbps(lined.len, tNew) & " (" & mbps(lined.len, tOld) & ")"
block:
  var html = ""
  while html.len < 4_000_000:
    html.add "<p style=3D\"margin:0\">Dear reader, here is this week's news.=20\r\n" &
             "Prices are up 3% and the weather is fine.</p>=\r\n"
  var a, b: string
  let tNew = timed((a = quotedPrintableDecode(html)))
  let tOld = timed((b = oldQp(html)))
  check a == b, "quoted-printable, a 4 MB newsletter: " & mbps(html.len, tNew) & " (" & mbps(html.len, tOld) & ")"
block:
  var text = ""
  while text.len < 8_000_000:
    text.add "Hello, this is a mostly plain message with an odd word here and there: café. "
  var a, b: string
  let tNew = timed((a = toUtf8(text, "utf-8")))
  let tOld = timed((b = oldValid(text)))
  check a == b, "UTF-8 checked, 8 MB: " & mbps(text.len, tNew) & " (" & mbps(text.len, tOld) & ")"
  let latin = text.replace("é", "\xE9")
  let tNew2 = timed((a = toUtf8(latin, "iso-8859-1")))
  let tOld2 = timed((b = oldLatin1(latin)))
  check a == b, "Latin-1 made UTF-8, 8 MB: " & mbps(latin.len, tNew2) & " (" & mbps(latin.len, tOld2) & ")"

if failures > 0:
  echo failures, " failed"
  quit 1
echo "test_mimefast: all passed"
