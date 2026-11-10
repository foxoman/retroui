## Text templates in the Mustache style, for HTML reports, letters, e-mails
## and anything else made from a pattern and some data.
##
## .. code-block:: nim
##   import std/json, retroui/templates
##   let tpl = "<h1>Invoice {{number}}</h1>{{#items}}<p>{{name}}: {{price|n2}}</p>{{/items}}" &
##             "{{^items}}<p>Nothing ordered.</p>{{/items}}"
##   echo renderTemplate(tpl, %*{"number": 42,
##                               "items": [{"name": "Paper", "price": 4.5}]})
##
## What a template can hold:
##
## - `{{name}}`: the value of `name`, HTML-escaped (`<` becomes `&lt;`...);
##   `{{{name}}}` or `{{& name}}`: the value as it is
## - `{{a.b.c}}`: a value inside objects; `{{.}}`: the item itself (in a list
##   of plain values)
## - `{{#name}}...{{/name}}`: the part once for each item of a list (inside
##   it, the item's fields are names too), once when the value is an object
##   or is true / non-empty / non-zero, never when it is false, empty, zero
##   or missing
## - `{{^name}}...{{/name}}`: the part when the value is false, empty or
##   missing
## - `{{! a comment }}`: nothing
## - filters after a `|`: `{{price|n2}}` a number with 2 decimals and
##   thousands separators (`n0` .. `n6`), `upper`, `lower`, `trim`
##
## Names are looked up in the innermost item first, then outwards. Missing
## names are empty. A broken template (a section never closed, a stray
## `{{`) still gives its best output: it never raises.

import std/[json, strutils, tables, math]
import std/unicode except strip   # (its strip cuts letters: docs/nim-bugs.md)

type
  NodeKind = enum nkText, nkValue, nkSection
  Node = object
    kind: NodeKind
    text: string             ## nkText: the text; else the name
    escape: bool             ## nkValue: HTML-escaped
    filters: seq[string]
    inverted: bool           ## nkSection: {{^...}}
    kids: seq[Node]

const
  MaxDepth = 64              ## sections inside sections, at most
  MaxOutput = 64 * 1024 * 1024

proc htmlEscape(s: string): string =
  ## `s` with `&`, `<`, `>`, `"` and `'` written as HTML entities.
  result = newStringOfCap(s.len + 8)
  for c in s:
    case c
    of '&': result.add "&amp;"
    of '<': result.add "&lt;"
    of '>': result.add "&gt;"
    of '"': result.add "&quot;"
    of '\'': result.add "&#39;"
    else: result.add c

proc parseTemplate(tpl: string): seq[Node] =
  ## The template as a tree. Unclosed sections end at the end; closing
  ## tags that close nothing are left out.
  var stack: seq[Node] = @[Node(kind: nkSection)]
  var i = 0
  var text = ""
  template flushText() =
    if text.len > 0:
      stack[^1].kids.add Node(kind: nkText, text: text)
      text = ""
  while i < tpl.len:
    if i + 1 < tpl.len and tpl[i] == '{' and tpl[i + 1] == '{':
      var triple = i + 2 < tpl.len and tpl[i + 2] == '{'
      let close = if triple: "}}}" else: "}}"
      let start = i + (if triple: 3 else: 2)
      let e = tpl.find(close, start)
      if e < 0:
        text.add tpl[i .. ^1]                 # a stray {{: shown as it is
        break
      var tag = tpl[start ..< e].strip
      i = e + close.len
      flushText()
      if tag.len == 0: continue
      var kind = tag[0]
      if triple: kind = '&'
      elif kind in {'#', '^', '/', '!', '&', '>', '='}: tag = tag[1 .. ^1].strip
      else: kind = ' '
      case kind
      of '!', '>', '=': discard              # comments, partials, delimiters: nothing
      of '#', '^':
        if stack.len <= MaxDepth:
          stack.add Node(kind: nkSection, text: tag, inverted: kind == '^')
      of '/':
        # close the innermost open section of that name (and the ones in it)
        var at = -1
        for k in countdown(stack.high, 1):
          if stack[k].text == tag:
            at = k
            break
        if at > 0:
          while stack.len > at:
            let n = stack.pop()
            stack[^1].kids.add n
      else:
        var parts = tag.split('|')
        var filters: seq[string]
        for p in parts[1 .. ^1]: filters.add p.strip.toLowerAscii
        stack[^1].kids.add Node(kind: nkValue, text: parts[0].strip,
                                escape: kind != '&', filters: filters)
    else:
      text.add tpl[i]
      inc i
  flushText()
  while stack.len > 1:
    let n = stack.pop()
    stack[^1].kids.add n
  stack[0].kids

proc lookup(stack: seq[JsonNode]; name: string): JsonNode =
  if name == "." and stack.len > 0: return stack[^1]
  let parts = name.split('.')
  for i in countdown(stack.high, 0):
    let c = stack[i]
    if c != nil and c.kind == JObject and c.hasKey(parts[0]):
      var v = c[parts[0]]
      for p in parts[1 .. ^1]:
        if v != nil and v.kind == JObject and v.hasKey(p): v = v[p]
        else: return nil
      return v
  nil

proc truthy(v: JsonNode): bool =
  if v == nil: return false
  case v.kind
  of JNull: false
  of JBool: v.bval
  of JString: v.str.len > 0
  of JInt: v.num != 0
  of JFloat: v.fnum != 0 and not v.fnum.isNaN
  of JArray: v.len > 0
  of JObject: true

proc grouped(s: string): string =
  ## "1234567" -> "1,234,567"
  let neg = s.startsWith('-')
  let d = if neg: s[1 .. ^1] else: s
  for i, c in d:
    if i > 0 and (d.len - i) mod 3 == 0: result.add ','
    result.add c
  if neg: result = "-" & result

proc formatNum(f: float; decimals: int): string =
  ## `f` with `decimals` decimals, halves rounded away from zero as a
  ## spreadsheet does (11.325 -> 11.33, though the float is a hair under).
  if f.isNaN or f.classify in {fcInf, fcNegInf} or abs(f) > 1e300: return ""
  let k = pow(10.0, float(decimals))
  let m = abs(f) * k
  let r = round(m + 1e-9 * max(1.0, m)) / k
  var s = formatFloat(r, ffDecimal, decimals)
  if s.endsWith('.'): s.setLen(s.len - 1)
  let dot = s.find('.')
  let whole = if dot < 0: s else: s[0 ..< dot]
  result = grouped(whole)
  if dot >= 0: result.add s[dot .. ^1]
  if f < 0 and result.strip(chars = {'0', '.', ','}).len > 0: result = "-" & result

proc valueText(v: JsonNode): string =
  if v == nil: return ""
  case v.kind
  of JNull: ""
  of JBool: $v.bval
  of JString: v.str
  of JInt: $v.num
  of JFloat:
    let f = v.fnum
    if f.isNaN or f.classify in {fcInf, fcNegInf}: ""
    elif f == round(f) and abs(f) < 1e15: $int64(f)
    else: $f
  of JArray, JObject: ""

proc applyFilters(v: JsonNode; s: string; filters: seq[string]): string =
  result = s
  for f in filters:
    if f.len == 2 and f[0] == 'n' and f[1] in '0'..'6':
      var x = NaN
      if v != nil and v.kind == JInt: x = float(v.num)
      elif v != nil and v.kind == JFloat: x = v.fnum
      else:
        try: x = parseFloat(result.replace(",", "").strip)
        except ValueError: discard
      if not x.isNaN: result = formatNum(x, ord(f[1]) - ord('0'))
    else:
      case f
      of "upper": result = unicode.toUpper(result)
      of "lower": result = unicode.toLower(result)
      of "trim": result = result.strip
      else: discard

proc render(nodes: seq[Node]; stack: var seq[JsonNode]; outS: var string; depth: int) =
  if depth > MaxDepth: return
  for n in nodes:
    if outS.len > MaxOutput: return
    case n.kind
    of nkText: outS.add n.text
    of nkValue:
      let v = lookup(stack, n.text)
      var s = applyFilters(v, valueText(v), n.filters)
      outS.add(if n.escape: htmlEscape(s) else: s)
    of nkSection:
      let v = lookup(stack, n.text)
      if n.inverted:
        if not truthy(v): render(n.kids, stack, outS, depth + 1)
      elif truthy(v):
        if v.kind == JArray:
          for item in v.elems:
            stack.add item
            render(n.kids, stack, outS, depth + 1)
            discard stack.pop()
            if outS.len > MaxOutput: return
        else:
          stack.add v
          render(n.kids, stack, outS, depth + 1)
          discard stack.pop()

var parsed: Table[string, seq[Node]]

proc renderTemplate*(tpl: string; data: JsonNode): string =
  ## The template `tpl` filled in from `data` (see the module's notes for
  ## what a template holds). Parsed templates are kept, so rendering the
  ## same one again is quick.
  var nodes: seq[Node]
  if parsed.hasKey(tpl): nodes = parsed[tpl]
  else:
    nodes = parseTemplate(tpl)
    if tpl.len < 1_000_000:
      if parsed.len > 32: parsed.clear()
      parsed[tpl] = nodes
  var stack = @[if data == nil: newJObject() else: data]
  render(nodes, stack, result, 0)

proc renderTemplate*[T: not JsonNode](tpl: string; data: T): string =
  ## The template filled in from any Nim value that `%` (std/json) turns
  ## into JSON: objects, tables, sequences, tuples.
  renderTemplate(tpl, %data)

# ---- amounts in words ---------------------------------------------------------------------------

type
  Currency* = object
    ## How an amount is named in words: "Omani Rial" / "Omani Rials" and
    ## "Baisa", 1000 baisa to the rial (Arabic: `arOne`, `arTwo`, `arFew`
    ## (3 to 10), `arMany` (11 to 99), and the same for the small unit).
    one*, many*, minorOne*, minorMany*: string
      ## the unit's name for one and for more, and the small unit's
    minorUnits*: int           ## small units to the unit (1000 baisa, 100 cents)
    arOne*, arTwo*, arFew*, arMany*: string
      ## the unit in Arabic, for one, two, 3 to 10, 11 to 99
    arMinorOne*, arMinorTwo*, arMinorFew*, arMinorMany*: string
      ## ... and the small unit

const omaniRial* = Currency(one: "Omani Rial", many: "Omani Rials",
                            minorOne: "Baisa", minorMany: "Baisa", minorUnits: 1000,
                            arOne: "ريال عماني", arTwo: "ريالان عمانيان",
                            arFew: "ريالات عمانية", arMany: "ريالاً عمانياً",
                            arMinorOne: "بيسة", arMinorTwo: "بيستان",
                            arMinorFew: "بيسات", arMinorMany: "بيسة")
  ## The Omani rial: 1000 baisa.

const
  enOnes = ["", "One", "Two", "Three", "Four", "Five", "Six", "Seven", "Eight", "Nine",
            "Ten", "Eleven", "Twelve", "Thirteen", "Fourteen", "Fifteen", "Sixteen",
            "Seventeen", "Eighteen", "Nineteen"]
  enTens = ["", "", "Twenty", "Thirty", "Forty", "Fifty", "Sixty", "Seventy", "Eighty", "Ninety"]
  arOnes = ["", "واحد", "اثنان", "ثلاثة", "أربعة", "خمسة", "ستة", "سبعة", "ثمانية", "تسعة",
            "عشرة", "أحد عشر", "اثنا عشر", "ثلاثة عشر", "أربعة عشر", "خمسة عشر",
            "ستة عشر", "سبعة عشر", "ثمانية عشر", "تسعة عشر"]
  arTens = ["", "", "عشرون", "ثلاثون", "أربعون", "خمسون", "ستون", "سبعون", "ثمانون", "تسعون"]
  arHundreds = ["", "مائة", "مائتان", "ثلاثمائة", "أربعمائة", "خمسمائة", "ستمائة",
                "سبعمائة", "ثمانمائة", "تسعمائة"]

proc enUnder1000(n: int): string =
  var parts: seq[string]
  if n >= 100: parts.add enOnes[n div 100] & " Hundred"
  let r = n mod 100
  if r > 0:
    if r < 20: parts.add enOnes[r]
    else: parts.add enTens[r div 10] & (if r mod 10 > 0: "-" & enOnes[r mod 10] else: "")
  parts.join(" ")

proc numberWords*(n: int64): string =
  ## A whole number in English words: 1250 -> "One Thousand Two Hundred Fifty".
  if n == 0: return "Zero"
  if n < 0: return "Minus " & numberWords(-n)
  const scales = ["", " Thousand", " Million", " Billion", " Trillion"]
  var parts: seq[string]
  var x = n
  var i = 0
  while x > 0 and i < scales.len:
    let chunk = int(x mod 1000)
    if chunk > 0: parts.insert(enUnder1000(chunk) & scales[i], 0)
    x = x div 1000
    inc i
  parts.join(" ")

proc arUnder1000(n: int): string =
  var parts: seq[string]
  if n >= 100: parts.add arHundreds[n div 100]
  let r = n mod 100
  if r > 0:
    if r < 20: parts.add arOnes[r]
    elif r mod 10 == 0: parts.add arTens[r div 10]
    else: parts.add arOnes[r mod 10] & " و" & arTens[r div 10]
  parts.join(" و")

proc arScale(chunk: int; one, two, few, many: string): string =
  ## 1000s, 1000000s: "ألف", "ألفان", "ثلاثة آلاف", "أحد عشر ألفاً"...
  if chunk == 1: one
  elif chunk == 2: two
  elif chunk mod 100 in 3 .. 10: arUnder1000(chunk) & " " & few
  elif chunk mod 100 >= 11: arUnder1000(chunk) & " " & many
  else: arUnder1000(chunk) & " " & one

proc arabicNumberWords*(n: int64): string =
  ## A whole number in Arabic words: 790 -> "سبعمائة وتسعون".
  if n == 0: return "صفر"
  if n < 0: return "سالب " & arabicNumberWords(-n)
  var parts: seq[string]
  let billions = int(n div 1_000_000_000)
  let millions = int((n div 1_000_000) mod 1000)
  let thousands = int((n div 1000) mod 1000)
  let rest = int(n mod 1000)
  if billions > 0: parts.add arScale(billions, "مليار", "ملياران", "مليارات", "ملياراً")
  if millions > 0: parts.add arScale(millions, "مليون", "مليونان", "ملايين", "مليوناً")
  if thousands > 0: parts.add arScale(thousands, "ألف", "ألفان", "آلاف", "ألفاً")
  if rest > 0: parts.add arUnder1000(rest)
  parts.join(" و")

proc arCounted(n: int64; one, two, few, many: string; feminine = false): string =
  ## `n` things in Arabic, with the noun in the form the number takes.
  if n == 1: return one & (if feminine: " واحدة" else: " واحد")
  if n == 2: return two
  let r = n mod 100
  let w = arabicNumberWords(n)
  if r in 3 .. 10: w & " " & few
  elif r in 11 .. 99: w & " " & many
  else: w & " " & one

proc amountWords*(v: float; cur = omaniRial; arabic = false): string =
  ## An amount in words: 790.5 -> "Seven Hundred Ninety Omani Rials and Five
  ## Hundred Baisa", or (`arabic`) "سبعمائة وتسعون ريالاً عمانياً وخمسمائة بيسة".
  if v.isNaN or abs(v) > 1e15: return ""
  let units = max(1, cur.minorUnits)
  let total = int64(round(abs(v) * float(units)))
  let major = total div units
  let minor = total mod units
  if arabic:
    if major > 0 or minor == 0:
      result = arCounted(major, cur.arOne, cur.arTwo, cur.arFew, cur.arMany)
      if major == 0: result = "صفر " & cur.arOne
    if minor > 0:
      let m = arCounted(minor, cur.arMinorOne, cur.arMinorTwo, cur.arMinorFew,
                        cur.arMinorMany, feminine = true)
      result = if result.len > 0: result & " و" & m else: m
  else:
    if major > 0 or minor == 0:
      result = numberWords(major) & " " & (if major == 1: cur.one else: cur.many)
    if minor > 0:
      let m = numberWords(minor) & " " & (if minor == 1: cur.minorOne else: cur.minorMany)
      result = if result.len > 0: result & " and " & m else: m

# ---- #[tags]#: letters and forms filled in from a record ------------------------------------------

type
  TagRef* = object
    ## A tag of a letter: `#[Total Salary|words]#`, or `#[?Addressed to]#`
    ## (a blank the user fills in when the letter is made).
    name*: string            ## "Total Salary", "Addressed to"
    filters*: seq[string]    ## "words", "long"...
    ask*: bool               ## `#[?...]#`
    at*, len*: int           ## where it is in the text

const
  TagOpen* = "#["
    ## What starts a letter's tag (`TagRef`).
  TagClose* = "]#"
    ## What ends it.
  enMonths = ["January", "February", "March", "April", "May", "June", "July",
              "August", "September", "October", "November", "December"]
  arMonths = ["يناير", "فبراير", "مارس", "أبريل", "مايو", "يونيو", "يوليو",
              "أغسطس", "سبتمبر", "أكتوبر", "نوفمبر", "ديسمبر"]

proc tagKey*(name: string): string =
  ## The name a tag is looked up by: lower case, letters and digits only
  ## ("Total Salary", "total_salary" and "TotalSalary" are one tag).
  for r in name.runes:
    if r.isAlpha or (r.int < 128 and char(r.int) in {'0'..'9'}):
      result.add $r.toLower

proc findTags*(text: string): seq[TagRef] =
  ## The tags in `text`, in order (a `#[` never closed is left as text).
  var i = 0
  while i < text.len:
    let a = text.find(TagOpen, i)
    if a < 0: break
    let b = text.find(TagClose, a + 2)
    if b < 0: break
    let inner = text[a + 2 ..< b]
    if inner.contains(TagOpen) or inner.len > 200:   # (not a tag)
      i = a + 2
      continue
    var parts = inner.split('|')
    var t = TagRef(at: a, len: b + 2 - a)
    var name = parts[0].strip
    if name.startsWith("?"):
      t.ask = true
      name = name[1 .. ^1].strip
    t.name = name
    for f in parts[1 .. ^1]:
      let s = f.strip.toLowerAscii
      if s.len > 0: t.filters.add s
    if name.len > 0: result.add t
    i = b + 2

proc parseIsoDate(s: string): tuple[ok: bool; y, m, d: int] =
  ## "2018-09-02" or "02/09/2018" (day first, as in Oman).
  let t = s.strip
  try:
    if t.len >= 10 and t[4] == '-' and t[7] == '-':
      return (true, parseInt(t[0 .. 3]), parseInt(t[5 .. 6]), parseInt(t[8 .. 9]))
    let p = t.split({'/', '.', '-'})
    if p.len == 3 and p[2].len == 4:
      return (true, parseInt(p[2]), parseInt(p[1]), parseInt(p[0]))
  except ValueError: discard
  (false, 0, 0, 0)

proc arabicDigits*(s: string): string =
  ## "2026" -> "٢٠٢٦" (the digits Arabic text is often written with).
  for c in s:
    if c in {'0'..'9'}: result.add $Rune(0x0660 + ord(c) - ord('0'))
    else: result.add c

proc tagFilter*(value, filter: string; cur = omaniRial): string =
  ## One filter applied to a tag's value:
  ##
  ## - `words`, `words-ar`: an amount in words (English, Arabic)
  ## - `number-words`, `number-words-ar`: a whole number in words
  ## - `long`, `long-ar`: a date as "2 September 2018" / "2 سبتمبر 2018"
  ## - `date`: a date as 02/09/2018
  ## - `n0` .. `n3`: a number with that many decimals and separators
  ## - `ar-digits`: the digits as Arabic-Indic ones
  ## - `upper`, `lower`, `trim`
  let num = value.replace(",", "").strip
  proc asFloat(): float =
    try: parseFloat(num) except ValueError: NaN
  case filter
  of "words", "words-en": (let f = asFloat(); if f.isNaN: value else: amountWords(f, cur))
  of "words-ar": (let f = asFloat(); if f.isNaN: value else: amountWords(f, cur, arabic = true))
  of "number-words":
    (let f = asFloat(); if f.isNaN: value else: numberWords(int64(round(f))))
  of "number-words-ar":
    (let f = asFloat(); if f.isNaN: value else: arabicNumberWords(int64(round(f))))
  of "long", "long-ar", "date":
    let d = parseIsoDate(value)
    if not d.ok or d.m notin 1 .. 12: value
    elif filter == "date": align($d.d, 2, '0') & "/" & align($d.m, 2, '0') & "/" & $d.y
    elif filter == "long": $d.d & " " & enMonths[d.m - 1] & " " & $d.y
    else: $d.d & " " & arMonths[d.m - 1] & " " & $d.y
  of "ar-digits": arabicDigits(value)
  of "upper": unicode.toUpper(value)
  of "lower": unicode.toLower(value)
  of "trim": value.strip
  else:
    if filter.len == 2 and filter[0] == 'n' and filter[1] in '0'..'6':
      let f = asFloat()
      if f.isNaN: value else: formatNum(f, ord(filter[1]) - ord('0'))
    else: value

proc fillTags*(text: string; values: Table[string, string];
               answers: Table[string, string] = initTable[string, string]();
               escape = false; cur = omaniRial): string =
  ## `text` with its tags replaced: `#[Name]#` by `values` (keyed by
  ## `tagKey`), `#[?Question]#` by `answers` (the same), each through its
  ## filters (`tagFilter`). Unknown tags stay as they are, so a missing
  ## field shows. `escape`: the values HTML-escaped (for HTML letters).
  var at = 0
  for t in findTags(text):
    result.add text[at ..< t.at]
    let key = tagKey(t.name)
    let src = if t.ask: answers else: values
    if src.hasKey(key):
      var v = src[key]
      for f in t.filters: v = tagFilter(v, f, cur)
      result.add(if escape: htmlEscape(v) else: v)
    else:
      result.add text[t.at ..< t.at + t.len]
    at = t.at + t.len
  result.add text[at .. ^1]
