## Domain names as people read them and as they are written in mail and
## links: the part someone registered ("mail.example.co.uk" ->
## "example.co.uk", from the Public Suffix List), international names
## (IDNA's "xn--" Punycode both ways), and what makes a name look like
## another one -- letters from other alphabets that look the same
## ("pаypal.com" with a Cyrillic а), "rn" for "m", "1" for "l" -- for the
## mail's checks of who a message is from (`retroui/mailauth`) and where
## its links go (`retroui/mailsafety`).
##
## .. code-block:: nim
##   echo registrableDomain("news.bbc.co.uk")          # bbc.co.uk
##   echo toUnicodeHost("xn--mnchen-3ya.de")           # münchen.de
##   echo toAsciiHost("münchen.de")                    # xn--mnchen-3ya.de
##   echo skeleton("pаypa1.com") == skeleton("paypal.com")   # true
##   echo mixedScripts("pаypal")                       # true: Latin and Cyrillic
##
## The list (10,000 rules, the private ones such as github.io among them) is
## carried packed and unpacked the first time it is needed. Safe on any
## thread.
##
## Developed by Sultan Al Isaiee @foxoman -- www.foxoman.net -- sultan@foxoman.net

import std/[strutils, sets, tables, locks]
import std/unicode except strip, splitWhitespace, split
import unpacking

const
  pslPacked = staticRead("vendor/public_suffix_list.dat.z")
  confusablesText = staticRead("vendor/confusables-ascii.txt")

# ---- Punycode (RFC 3492) and IDNA's xn-- labels -------------------------------------------

const
  base = 36
  tMin = 1
  tMax = 26
  skew = 38
  damp = 700
  initialBias = 72
  initialN = 128

proc adapt(delta0, numPoints: int; first: bool): int =
  var delta = if first: delta0 div damp else: delta0 div 2
  delta += delta div numPoints
  var k = 0
  while delta > ((base - tMin) * tMax) div 2:
    delta = delta div (base - tMin)
    k += base
  k + (((base - tMin + 1) * delta) div (delta + skew))

proc digitOf(c: char): int =
  case c
  of '0'..'9': ord(c) - ord('0') + 26
  of 'a'..'z': ord(c) - ord('a')
  of 'A'..'Z': ord(c) - ord('A')
  else: -1

proc digitChar(d: int): char =
  if d < 26: char(ord('a') + d) else: char(ord('0') + d - 26)

proc punyDecode*(s: string): string =
  ## A Punycode string (without "xn--") as UTF-8; "" when it is not one.
  var output: seq[int]
  var n = initialN
  var bias = initialBias
  var i = 0
  let b = s.rfind('-')
  if b > 0:
    for k in 0 ..< b:
      if ord(s[k]) >= 0x80: return ""
      output.add ord(s[k])
  var at = if b > 0: b + 1 else: 0
  while at < s.len:
    let oldi = i
    var w = 1
    var k = base
    while true:
      if at >= s.len: return ""
      let d = digitOf(s[at])
      inc at
      if d < 0: return ""
      if d > (int.high - i) div w: return ""
      i += d * w
      let t = if k <= bias: tMin elif k >= bias + tMax: tMax else: k - bias
      if d < t: break
      if w > int.high div (base - t): return ""
      w *= base - t
      k += base
    bias = adapt(i - oldi, output.len + 1, oldi == 0)
    n += i div (output.len + 1)
    if n > 0x10FFFF or (n >= 0xD800 and n <= 0xDFFF): return ""
    i = i mod (output.len + 1)
    output.insert(n, i)
    inc i
    if output.len > 256: return ""
  for cp in output: result.add $Rune(cp)

proc punyEncode*(s: string): string =
  ## UTF-8 `s` as Punycode (without "xn--").
  var cps: seq[int]
  for r in s.runes: cps.add int(r)
  var n = initialN
  var delta = 0
  var bias = initialBias
  for c in cps:
    if c < 0x80: result.add char(c)
  let b = result.len
  var h = b
  if b > 0: result.add '-'
  while h < cps.len:
    var m = int.high
    for c in cps:
      if c >= n and c < m: m = c
    delta += (m - n) * (h + 1)
    n = m
    for c in cps:
      if c < n: inc delta
      if c == n:
        var q = delta
        var k = base
        while true:
          let t = if k <= bias: tMin elif k >= bias + tMax: tMax else: k - bias
          if q < t: break
          result.add digitChar(t + (q - t) mod (base - t))
          q = (q - t) div (base - t)
          k += base
        result.add digitChar(q)
        bias = adapt(delta, h + 1, h == b)
        delta = 0
        inc h
    inc delta
    inc n

proc toUnicodeHost*(host: string): string =
  ## `host` lower case, its "xn--" labels as the letters they stand for (a
  ## label that is not good Punycode is kept as it is).
  var labels: seq[string]
  for l in host.strip(chars = {'.'}).split('.'):
    let low = unicode.toLower(l)
    if low.startsWith("xn--"):
      let u = punyDecode(low[4 .. ^1])
      labels.add(if u.len > 0: unicode.toLower(u) else: low)
    else: labels.add low
  labels.join(".")

proc toAsciiHost*(host: string): string =
  ## `host` as DNS has it: lower case, each label with letters beyond ASCII
  ## as "xn--" Punycode.
  var labels: seq[string]
  for l in host.strip(chars = {'.'}).split('.'):
    let low = unicode.toLower(l)
    var ascii = true
    for c in low:
      if ord(c) >= 0x80: ascii = false
    labels.add(if ascii: low else: "xn--" & punyEncode(low))
  labels.join(".")

# ---- the Public Suffix List -----------------------------------------------------------

type Psl = object
  rules, wild, exceptions: HashSet[string]
var pslLock: Lock
var psl: ptr Psl
initLock(pslLock)

proc loadPsl(): ptr Psl =
  withLock pslLock:
    if psl == nil:
      let p = cast[ptr Psl](allocShared0(sizeof(Psl)))
      # (busyTick, deep in the unpacking, does nothing off the window's thread)
      var text = ""
      {.cast(gcsafe).}: text = unpackBytes(pslPacked)
      for line in text.splitLines:
        let r = line.strip
        if r.len == 0 or r.startsWith("//"): continue
        let low = unicode.toLower(r)
        if low.startsWith("!"): p.exceptions.incl low[1 .. ^1]
        elif low.startsWith("*."): p.wild.incl low[2 .. ^1]
        else: p.rules.incl low
      psl = p
    result = psl

proc isIpHost*(host: string): bool =
  ## An address written as numbers (1.2.3.4, [::1], 0x7f.1) rather than a name.
  let h = host.strip(chars = {'[', ']'})
  if ':' in h: return true
  if h.len == 0: return false
  var allNum = true
  for c in h:
    if c notin {'0'..'9', '.', 'x', 'X', 'a'..'f', 'A'..'F'}: allNum = false
  if not allNum: return false
  let last = h.strip(chars = {'.'}).split('.')[^1]
  last.len > 0 and (last[0] in {'0'..'9'})

proc publicSuffix*(host: string): string =
  ## The part of `host` anyone may register under ("co.uk", "com",
  ## "github.io"), lower case, letters as letters (not xn--).
  let h = toUnicodeHost(host)
  if h.len == 0 or isIpHost(h): return ""
  let p = loadPsl()
  let labels = h.split('.')
  # (the longest rule that matches: an exception's parent, a rule, a wildcard's child)
  for i in 0 ..< labels.len:
    let cand = labels[i .. ^1].join(".")
    if cand in p.exceptions:
      return labels[i + 1 .. ^1].join(".")
    if cand in p.rules: return cand
    if i + 1 < labels.len:
      let parent = labels[i + 1 .. ^1].join(".")
      if parent in p.wild: return cand
  labels[^1]   # (the default rule: "*")

proc registrableDomain*(host: string): string =
  ## The name someone registered: the public suffix and one label more
  ## ("www.example.co.uk" -> "example.co.uk"); "" for a suffix itself or an
  ## address. Lower case, letters as letters.
  let h = toUnicodeHost(host)
  if h.len == 0 or isIpHost(h): return ""
  let suffix = publicSuffix(h)
  if suffix.len == 0 or suffix.len >= h.len: return ""
  let rest = h[0 ..< h.len - suffix.len - 1]
  let k = rest.rfind('.')
  (if k >= 0: rest[k + 1 .. ^1] else: rest) & "." & suffix

proc sameOrganization*(a, b: string): bool =
  ## Both names registered by the same one ("mail.example.com" and
  ## "example.com"), the way DMARC lines them up.
  let ra = registrableDomain(a)
  ra.len > 0 and ra == registrableDomain(b)

# ---- names that look like other names ---------------------------------------------------

var confLock: Lock
var conf: ptr Table[int32, string]
initLock(confLock)

proc confusables(): ptr Table[int32, string] =
  withLock confLock:
    if conf == nil:
      let t = cast[ptr Table[int32, string]](allocShared0(sizeof(Table[int32, string])))
      for line in confusablesText.splitLines:
        if line.len == 0 or line[0] == '#': continue
        let sp = line.find(' ')
        if sp <= 0: continue
        try: t[][int32(parseHexInt(line[0 ..< sp]))] = line[sp + 1 .. ^1]
        except ValueError: discard
      conf = t
    result = conf

proc skeleton*(s: string): string =
  ## What `s` looks like, in ASCII where it can be: two names with the same
  ## skeleton can be mistaken for each other ("раураl" in Cyrillic and
  ## "paypal"; "rnicrosoft" and "microsoft"; "g00gle" and "google").
  ## Lower case; xn-- labels read as their letters first.
  let t = confusables()
  var mapped = ""
  for r in toUnicodeHost(s).runes:
    let c = int32(r)
    let low = int32(unicode.toLower(r))
    if c in t[]: mapped.add t[][c]
    elif low in t[]: mapped.add t[][low]
    else: mapped.add unicode.toLower($r)
  unicode.toLower(mapped)

type Script = enum scOther, scLatin, scGreek, scCyrillic, scArmenian, scCherokee, scArabic,
                   scHebrew, scHan, scKana, scHangul, scThai, scDevanagari

proc scriptOf(c: int): Script =
  case c
  of 0x41..0x5A, 0x61..0x7A, 0xC0..0x24F, 0x1E00..0x1EFF, 0xFF21..0xFF3A, 0xFF41..0xFF5A: scLatin
  of 0x370..0x3FF, 0x1F00..0x1FFF: scGreek
  of 0x400..0x52F, 0x1C80..0x1C8F, 0x2DE0..0x2DFF, 0xA640..0xA69F: scCyrillic
  of 0x530..0x58F: scArmenian
  of 0x13A0..0x13FF, 0xAB70..0xABBF: scCherokee
  of 0x600..0x6FF, 0x750..0x77F, 0x8A0..0x8FF, 0xFB50..0xFDFF, 0xFE70..0xFEFF: scArabic
  of 0x590..0x5FF: scHebrew
  of 0x4E00..0x9FFF, 0x3400..0x4DBF: scHan
  of 0x3040..0x30FF: scKana
  of 0xAC00..0xD7AF, 0x1100..0x11FF: scHangul
  of 0xE00..0xE7F: scThai
  of 0x900..0x97F: scDevanagari
  else: scOther

proc mixedScripts*(s: string): bool =
  ## A label (or name) that mixes Latin letters with Greek, Cyrillic,
  ## Armenian or Cherokee ones -- the ones that look like Latin letters; a
  ## name written all in one of them, or Japanese with Latin, is fine.
  for label in toUnicodeHost(s).split('.'):
    var seen: set[Script]
    for r in label.runes:
      let sc = scriptOf(int(r))
      if sc != scOther: seen.incl sc
    if scLatin in seen and (seen * {scGreek, scCyrillic, scArmenian, scCherokee}).len > 0:
      return true
    if (seen * {scGreek, scCyrillic}).len == 2: return true

proc editDistance*(a, b: string): int =
  ## Letters to add, take away, change or swap to make `a` into `b`
  ## (Damerau-Levenshtein, optimal string alignment).
  let n = a.len
  let m = b.len
  if n == 0: return m
  if m == 0: return n
  var d = newSeq[seq[int]](n + 1)
  for i in 0 .. n:
    d[i] = newSeq[int](m + 1)
    d[i][0] = i
  for j in 0 .. m: d[0][j] = j
  for i in 1 .. n:
    for j in 1 .. m:
      let cost = if a[i - 1] == b[j - 1]: 0 else: 1
      d[i][j] = min(min(d[i - 1][j] + 1, d[i][j - 1] + 1), d[i - 1][j - 1] + cost)
      if i > 1 and j > 1 and a[i - 1] == b[j - 2] and a[i - 2] == b[j - 1]:
        d[i][j] = min(d[i][j], d[i - 2][j - 2] + 1)
  d[n][m]

proc looksLike*(host, other: string): bool =
  ## `host` is not `other`'s organization but can be taken for it: the
  ## same skeleton ("paypa1.com", "pаypal.com" for "paypal.com").
  let a = registrableDomain(host)
  let b = registrableDomain(other)
  if a.len == 0 or b.len == 0 or a == b: return false
  skeleton(a) == skeleton(b)
