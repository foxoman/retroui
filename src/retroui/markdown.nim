## Markdown, parsed and shown: headings, paragraphs with **bold**,
## *italic*, ~~strike~~, `code` and [links](url), fenced and indented code
## blocks, block quotes, bullet, numbered and task lists (nested), tables
## with column alignment, rules, images, autolinks, hard breaks, escapes
## and entities (CommonMark with the GitHub extensions). Arabic (and other
## right-to-left) paragraphs are aligned right. A few inline HTML tags are
## understood too: `<b>`, `<i>`, `<u>`, `<s>`, `<code>`, `<kbd>`,
## `<mark>`, `<br>`, `<font color="...">` and `<span style="color: ...">`
## (others are left out, their text kept).
##
## .. code-block:: nim
##   let ev = markdownView(readFile("README.md"), baseDir = ".")
##   if ev.link.len > 0: discard openUrl(ev.link)

import std/[strutils, tables, os, hashes, algorithm]
import std/unicode except strip   # (its strip cuts letters: docs/nim-bugs.md)
import core, widgets, imaging
import uirelays/input

template th: untyped = ui.theme

# ---- the document --------------------------------------------------------------------

type
  BlockKind* = enum
    ## What an `MdBlock` is: a paragraph, a heading, a code block, a quote,
    ## a list, a list's item, a table, a rule, a block of HTML.
    bkPara, bkHeading, bkCode, bkQuote, bkList, bkItem, bkTable, bkRule, bkHtml

  MdBlock* = ref object
    ## A block of a Markdown document; the fields marked so are its kind's.
    kind*: BlockKind           ## what it is
    level*: int                ## heading 1..6
    text*: string              ## inline source, or the code
    lang*: string              ## code fence's language
    ordered*: bool             ## list: numbered
    start*: int                ## list: first number
    task*: int                 ## item: -1 none, 0 open, 1 done
    taskIndex*: int            ## item: which task in the document
    kids*: seq[MdBlock]        ## quote, list, item: the blocks in it
    rows*: seq[seq[string]]    ## table cells (row 0 is the header)
    aligns*: seq[char]         ## table: 'l', 'c', 'r' per column

  MdDoc* = object
    ## A Markdown document parsed (`parseMarkdown`).
    blocks*: seq[MdBlock]          ## its blocks, in order
    refs*: Table[string, string]   ## `[label]: url`
    tasks*: int                    ## how many task boxes (`- [ ]`) it has

proc indentOf(s: string): int =
  for c in s:
    if c == ' ': inc result
    elif c == '\t': result = (result div 4 + 1) * 4
    else: break

proc dropIndent(s: string; n: int): string =
  ## `s` without `n` columns of leading white space.
  var col = 0
  var i = 0
  while i < s.len and col < n:
    if s[i] == ' ': inc col
    elif s[i] == '\t': col = (col div 4 + 1) * 4
    else: break
    inc i
  result = (if col > n: spaces(col - n) else: "") & s[i .. ^1]

proc isBlank(s: string): bool = s.strip.len == 0

proc fenceOf(s: string): (char, int) =
  let t = s.strip(trailing = false)
  if indentOf(s) >= 4 or t.len < 3: return ('\0', 0)
  let c = t[0]
  if c notin {'`', '~'}: return ('\0', 0)
  var n = 0
  while n < t.len and t[n] == c: inc n
  if n < 3: return ('\0', 0)
  if c == '`' and '`' in t[n .. ^1]: return ('\0', 0)
  (c, n)

proc isRule(s: string): bool =
  if indentOf(s) >= 4: return false
  let t = s.strip
  if t.len < 3 or t[0] notin {'-', '*', '_'}: return false
  var n = 0
  for c in t:
    if c == t[0]: inc n
    elif c notin {' ', '\t'}: return false
  n >= 3

proc headingOf(s: string): (int, string) =
  if indentOf(s) >= 4: return (0, "")
  let t = s.strip(trailing = false)
  var n = 0
  while n < t.len and t[n] == '#': inc n
  if n == 0 or n > 6 or (n < t.len and t[n] notin {' ', '\t'}): return (0, "")
  var body = t[n .. ^1].strip
  # closing #s
  var e = body.len
  while e > 0 and body[e-1] == '#': dec e
  if e < body.len and (e == 0 or body[e-1] == ' '): body = body[0 ..< e].strip
  (n, body)

proc listMarker(s: string): tuple[ok, ordered: bool; num, width: int; bullet: char] =
  ## A list item's marker: "- ", "* ", "+ ", "1. ", "1) ".
  let ind = indentOf(s)
  if ind >= 4: return
  let t = s.dropIndent(ind)
  if t.len >= 1 and t[0] in {'-', '*', '+'}:
    if t.len == 1 or t[1] in {' ', '\t'}:
      let pad = if t.len == 1: 1 else: min(5, max(1, indentOf(t[1 .. ^1])))
      return (true, false, 0, ind + 1 + pad, t[0])
  var n = 0
  while n < t.len and n < 9 and t[n] in Digits: inc n
  if n > 0 and n < t.len and t[n] in {'.', ')'}:
    if n + 1 == t.len or t[n+1] in {' ', '\t'}:
      let pad = if n + 1 == t.len: 1 else: min(5, max(1, indentOf(t[n+1 .. ^1])))
      return (true, true, parseInt(t[0 ..< n]), ind + n + 1 + pad, t[n])

proc splitRow(s: string): seq[string] =
  var t = s.strip
  if t.startsWith("|"): t = t[1 .. ^1]
  if t.endsWith("|") and not t.endsWith("\\|"): t = t[0 ..< t.len - 1]
  var cur = ""
  var i = 0
  while i < t.len:
    if t[i] == '\\' and i + 1 < t.len and t[i+1] == '|':
      cur.add '|'
      i += 2
      continue
    if t[i] == '|':
      result.add cur.strip
      cur = ""
    else: cur.add t[i]
    inc i
  result.add cur.strip

proc isDelimRow(s: string): bool =
  if '-' notin s: return false
  for cell in splitRow(s):
    let c = cell.strip
    if c.len == 0: return false
    for ch in c:
      if ch notin {'-', ':', ' '}: return false
    if '-' notin c: return false
  true

proc parseBlocks(lines: seq[string]; doc: var MdDoc): seq[MdBlock]

proc startsBlock(s: string): bool =
  ## Whether line `s` begins a new block (ends a paragraph).
  let (h, _) = headingOf(s)
  h > 0 or isRule(s) or fenceOf(s)[1] > 0 or
    s.strip(trailing = false).startsWith(">") or
    (listMarker(s).ok and s.dropIndent(indentOf(s)).strip.len > 1)

const maxNesting = 24
  ## Quotes in quotes, lists in lists and emphasis in links deeper than this
  ## are kept as plain text: a hostile file cannot exhaust the stack.

var nesting = 0

proc parseBlocks(lines: seq[string]; doc: var MdDoc): seq[MdBlock] =
  if nesting >= maxNesting:
    return @[MdBlock(kind: bkPara, text: lines.join("\n"))]
  inc nesting
  defer: dec nesting
  var i = 0
  var para: seq[string]
  template flush() =
    if para.len > 0:
      result.add MdBlock(kind: bkPara, text: para.join("\n"))
      para.setLen(0)
  while i < lines.len:
    let line = lines[i]
    if isBlank(line):
      flush()
      inc i
      continue
    let ind = indentOf(line)
    # fenced code
    let (fc, fn) = fenceOf(line)
    if fn > 0:
      flush()
      let lang = line.strip.strip(chars = {fc}).strip
      let base = ind
      var code: seq[string]
      inc i
      while i < lines.len:
        let (c2, n2) = fenceOf(lines[i])
        if c2 == fc and n2 >= fn and lines[i].strip.strip(chars = {fc}).len == 0:
          inc i
          break
        code.add lines[i].dropIndent(base)
        inc i
      result.add MdBlock(kind: bkCode, text: code.join("\n"),
                         lang: lang.split(' ')[0])
      continue
    # indented code
    if ind >= 4 and para.len == 0:
      var code: seq[string]
      while i < lines.len and (indentOf(lines[i]) >= 4 or isBlank(lines[i])):
        code.add lines[i].dropIndent(4)
        inc i
      while code.len > 0 and isBlank(code[^1]): code.setLen(code.len - 1)
      result.add MdBlock(kind: bkCode, text: code.join("\n"))
      continue
    # setext heading underline
    if para.len > 0 and ind < 4:
      let t = line.strip
      if t.len > 0 and (t.allCharsInSet({'='}) or t.allCharsInSet({'-'})):
        result.add MdBlock(kind: bkHeading, level: if t[0] == '=': 1 else: 2,
                           text: para.join("\n"))
        para.setLen(0)
        inc i
        continue
    let (hl, htext) = headingOf(line)
    if hl > 0:
      flush()
      result.add MdBlock(kind: bkHeading, level: hl, text: htext)
      inc i
      continue
    if isRule(line):
      flush()
      result.add MdBlock(kind: bkRule)
      inc i
      continue
    # block quote
    if ind < 4 and line.strip(trailing = false).startsWith(">"):
      flush()
      var inner: seq[string]
      while i < lines.len:
        let l = lines[i]
        let t = l.strip(trailing = false)
        if t.startsWith(">"):
          var rest = t[1 .. ^1]
          if rest.startsWith(" "): rest = rest[1 .. ^1]
          inner.add rest
        elif not isBlank(l) and inner.len > 0 and not isBlank(inner[^1]) and
             not startsBlock(l):
          inner.add l                   # lazy continuation
        else: break
        inc i
      result.add MdBlock(kind: bkQuote, kids: parseBlocks(inner, doc))
      continue
    # lists
    let lm = listMarker(line)
    if lm.ok and (para.len == 0 or not lm.ordered or lm.num == 1):
      flush()
      let list = MdBlock(kind: bkList, ordered: lm.ordered, start: lm.num)
      let base = indentOf(line)
      while i < lines.len:
        let m = listMarker(lines[i])
        if not m.ok or m.ordered != lm.ordered or indentOf(lines[i]) > base + 3 or
           indentOf(lines[i]) < base: break
        var body: seq[string]
        let t = lines[i].dropIndent(indentOf(lines[i]))
        var mlen = 1
        if m.ordered:
          mlen = 0
          while mlen < t.len and t[mlen] in Digits: inc mlen
          inc mlen
        let first = if mlen < t.len: t[mlen .. ^1].strip(trailing = false) else: ""
        let contentAt = if first.len == 0: indentOf(lines[i]) + mlen + 1 else: m.width
        body.add first
        inc i
        while i < lines.len:
          let l = lines[i]
          if isBlank(l):
            # a blank line continues the item if more indented text follows
            var j = i + 1
            while j < lines.len and isBlank(lines[j]): inc j
            if j < lines.len and indentOf(lines[j]) >= contentAt:
              while i < j:
                body.add ""
                inc i
              continue
            break
          if indentOf(l) >= contentAt:
            body.add l.dropIndent(contentAt)
          elif listMarker(l).ok or startsBlock(l):
            break
          else:
            body.add l.strip(trailing = false)   # lazy continuation
          inc i
        var item = MdBlock(kind: bkItem, task: -1)
        if body.len > 0:
          let t = body[0]
          if t.len >= 3 and t[0] == '[' and t[2] == ']' and t[1] in {' ', 'x', 'X'} and
             (t.len == 3 or t[3] == ' '):
            item.task = if t[1] == ' ': 0 else: 1
            item.taskIndex = doc.tasks
            inc doc.tasks
            body[0] = if t.len > 4: t[4 .. ^1] else: ""
        item.kids = parseBlocks(body, doc)
        list.kids.add item
        # skip blank lines between items
        var j = i
        while j < lines.len and isBlank(lines[j]): inc j
        if j < lines.len and listMarker(lines[j]).ok and
           listMarker(lines[j]).ordered == lm.ordered and indentOf(lines[j]) >= base and
           indentOf(lines[j]) <= base + 3:
          i = j
      result.add list
      continue
    # tables
    if para.len == 0 and '|' in line and i + 1 < lines.len and isDelimRow(lines[i+1]):
      let head = splitRow(line)
      var aligns: seq[char]
      for c in splitRow(lines[i+1]):
        let t = c.strip
        aligns.add(if t.startsWith(":") and t.endsWith(":"): 'c'
                   elif t.endsWith(":"): 'r' else: 'l')
      let t = MdBlock(kind: bkTable, aligns: aligns)
      t.rows.add head
      i += 2
      while i < lines.len and not isBlank(lines[i]) and
            ('|' in lines[i]) and not startsBlock(lines[i]):
        var r = splitRow(lines[i])
        r.setLen(head.len)
        t.rows.add r
        inc i
      while t.aligns.len < head.len: t.aligns.add 'l'
      result.add t
      continue
    # link reference definitions
    if para.len == 0 and ind < 4:
      let t = line.strip
      if t.startsWith("[") and "]:" in t:
        let k = t.find("]:")
        let label = t[1 ..< k].toLowerAscii.strip
        var url = t[k + 2 .. ^1].strip.split(' ')[0]
        if url.startsWith("<") and url.endsWith(">"): url = url[1 ..< url.len - 1]
        if label.len > 0 and url.len > 0:
          doc.refs[label] = url
          inc i
          continue
    if para.len > 0 and (startsBlock(line)):
      flush()
      continue
    para.add line.strip(trailing = false)
    inc i
  flush()

proc parseMarkdown*(md: string): MdDoc =
  ## The blocks of `md`.
  result.blocks = parseBlocks(md.replace("\r\n", "\n").split('\n'), result)

# ---- inline -----------------------------------------------------------------------------

type
  Span = object
    text: string
    bold, italic, strike, code: bool
    underline, mark: bool    ## <u>, <mark>
    color: Color             ## <font color>, <span style="color">: alpha 0 none
    link: int                ## index into the layout's links, -1 none
    image: string            ## an inline image's source
    brk: bool                ## a hard line break

const entities = {"amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'",
                  "nbsp": " ", "copy": "©", "reg": "®",
                  "trade": "™", "hellip": "…", "mdash": "—",
                  "ndash": "–", "laquo": "«", "raquo": "»",
                  "middot": "·", "times": "×", "deg": "°",
                  "euro": "€", "larr": "←", "rarr": "→",
                  "check": "✓"}.toTable

type InlineCtx = object
  links: ptr seq[string]
  refs: ptr Table[string, string]
  budget: ptr int            ## characters inline tags may still look through

proc addText(res: var seq[Span]; s: string; base: Span) =
  if s.len == 0: return
  if res.len > 0 and not res[^1].brk and res[^1].image.len == 0 and
     res[^1].bold == base.bold and res[^1].italic == base.italic and
     res[^1].strike == base.strike and res[^1].code == base.code and
     res[^1].underline == base.underline and res[^1].mark == base.mark and
     res[^1].color == base.color and res[^1].link == base.link:
    res[^1].text.add s
  else:
    var sp = base
    sp.text = s
    sp.image = ""
    sp.brk = false
    res.add sp

var inlineBudget = 0
  ## Characters the inline scanners may still look through for this
  ## paragraph: a text of thousands of unclosed "*", "[" or "<b>" stays
  ## linear (what is not found in reach stays text).

proc findClose(s: string; i: int; delim: string): int =
  ## Where `delim` closes emphasis opened at `i` (-1: it does not).
  var j = i
  while true:
    if inlineBudget <= 0: return -1
    let f = s.find(delim, j)
    inlineBudget -= (if f < 0: s.len - j else: f - j) + 1
    j = f
    if j < 0: return -1
    if j > i and s[j-1] notin {' ', '\t', '\n'} and s[j-1] != '\\':
      let after = j + delim.len
      if after >= s.len or s[after] != delim[0] or delim.len == 3:
        if delim[0] == '_' and after < s.len and s[after].isAlphaNumeric:
          j = after
          continue
        return j
    j += 1

proc bracketEnd(s: string; i: int): int =
  ## The `]` matching the `[` at `i`.
  var depth = 0
  var j = i
  while j < s.len:
    dec inlineBudget
    if inlineBudget <= 0: return -1
    case s[j]
    of '\\': inc j
    of '[': inc depth
    of ']':
      dec depth
      if depth == 0: return j
    of '`':
      var n = 0
      while j + n < s.len and s[j + n] == '`': inc n
      let k = s.find(repeat('`', n), j + n)
      inlineBudget -= (if k < 0: s.len - j else: k - j)
      if k > 0: j = k + n - 1
    else: discard
    inc j
  -1

proc linkDest(s: string; i: int): (string, int) =
  ## "(url "title")" at `i`: the url and the index after ')'.
  if i >= s.len or s[i] != '(': return ("", -1)
  var depth = 0
  var j = i
  while j < s.len:
    dec inlineBudget
    if inlineBudget <= 0: return ("", -1)
    if s[j] == '\\': j += 2; continue
    if s[j] == '(': inc depth
    elif s[j] == ')':
      dec depth
      if depth == 0: break
    inc j
  if j >= s.len: return ("", -1)
  var inner = s[i + 1 ..< j].strip
  if inner.startsWith("<") and '>' in inner: inner = inner[1 ..< inner.find('>')]
  else:
    let sp = inner.find({' ', '\t', '\n'})
    if sp >= 0: inner = inner[0 ..< sp]
  (inner, j + 1)

proc findBounded(s: string; c: char; start, limit: int): int =
  ## `s.find(c, start)` that looks at most `limit` characters ahead (a
  ## text of thousands of "<" cannot make it slow).
  let e = min(s.len, start + limit)
  for j in start ..< e:
    if s[j] == c: return j
  -1

const styleTags = ["b", "strong", "i", "em", "cite", "var", "dfn", "u", "ins", "s",
                   "del", "strike", "code", "kbd", "samp", "tt", "mark", "font", "span",
                   "small", "big", "sub", "sup", "abbr", "q"]

proc tagNameOf(inner: string): tuple[name: string; closing: bool] =
  ## "b", "/b", "font color=red" -> the lower-case name and whether it closes.
  var i = 0
  if i < inner.len and inner[i] == '/':
    result.closing = true
    inc i
  while i < inner.len and (inner[i].isAlphaNumeric or inner[i] == '-'):
    result.name.add inner[i].toLowerAscii
    inc i

proc attrOf(inner, name: string): string =
  ## The value of attribute `name` in a tag's inside ("font color=\"red\"").
  let low = inner.toLowerAscii
  var at = 0
  while true:
    let k = low.find(name, at)
    if k < 0: return ""
    var j = k + name.len
    if k > 0 and low[k - 1] notin {' ', '\t', '\n'}:
      at = k + 1
      continue
    while j < inner.len and inner[j] == ' ': inc j
    if j >= inner.len or inner[j] != '=':
      at = k + 1
      continue
    inc j
    while j < inner.len and inner[j] == ' ': inc j
    if j < inner.len and inner[j] in {'"', '\''}:
      let q = inner[j]
      let e = inner.find(q, j + 1)
      return if e > j: inner[j + 1 ..< e] else: inner[j + 1 .. ^1]
    var e = j
    while e < inner.len and inner[e] notin {' ', '\t', '/'}: inc e
    return inner[j ..< e]

proc cssColor*(s: string): Color =
  ## A CSS color: "#rgb", "#rrggbb", "rgb(r, g, b)" or a name ("red",
  ## "navy"...); alpha 0 when it is none (or "transparent").
  let t = s.strip.toLowerAscii
  if t.len == 0: return
  try:
    if t[0] == '#':
      if t.len == 7:
        return color(uint8(parseHexInt(t[1..2])), uint8(parseHexInt(t[3..4])),
                     uint8(parseHexInt(t[5..6])))
      if t.len == 4:
        return color(uint8(parseHexInt(t[1..1]) * 17), uint8(parseHexInt(t[2..2]) * 17),
                     uint8(parseHexInt(t[3..3]) * 17))
      return
    if t.startsWith("rgb"):
      let a = t.find('(')
      let b = t.find(')')
      if a > 0 and b > a:
        let parts = t[a + 1 ..< b].split(',')
        if parts.len >= 3:
          var v: array[3, int]
          for k in 0 .. 2:
            let p = parts[k].strip
            v[k] = if p.endsWith("%"): parseInt(p[0 ..< ^1]) * 255 div 100
                   else: int(parseFloat(p))
          return color(uint8(clamp(v[0], 0, 255)), uint8(clamp(v[1], 0, 255)),
                       uint8(clamp(v[2], 0, 255)))
      return
  except ValueError: return
  case t
  of "black": color(0, 0, 0)
  of "white": color(255, 255, 255)
  of "gray", "grey": color(128, 128, 128)
  of "silver", "lightgray", "lightgrey": color(192, 192, 192)
  of "darkgray", "darkgrey": color(96, 96, 96)
  of "red": color(220, 0, 0)
  of "darkred", "maroon": color(128, 0, 0)
  of "green": color(0, 128, 0)
  of "lime": color(0, 200, 0)
  of "darkgreen": color(0, 90, 0)
  of "blue": color(0, 0, 230)
  of "navy", "darkblue": color(0, 0, 128)
  of "yellow": color(200, 160, 0)
  of "olive": color(128, 128, 0)
  of "orange": color(230, 120, 0)
  of "aqua", "cyan": color(0, 160, 170)
  of "teal": color(0, 128, 128)
  of "fuchsia", "magenta": color(200, 0, 200)
  of "purple": color(128, 0, 128)
  of "pink": color(230, 90, 140)
  of "brown": color(140, 70, 20)
  else: Color()

proc styleColor(style, prop: string): Color =
  ## `prop` ("color", "background") of a style attribute.
  for decl in style.split(';'):
    let k = decl.find(':')
    if k <= 0: continue
    let name = decl[0 ..< k].strip.toLowerAscii
    if name == prop or (prop == "background" and name == "background-color"):
      return cssColor(decl[k + 1 .. ^1].split(' ')[0])

proc closeTag(s: string; start: int; name: string; c: InlineCtx): tuple[a, b: int] =
  ## Where the `</name>` closing the tag opened just before `start` is: its
  ## first character and the one after it; (-1, -1) when there is none (in
  ## reach: the search shares a budget, so no text makes it slow).
  var depth = 1
  var j = start
  let low = name
  while j < s.len:
    if c.budget[] <= 0: return (-1, -1)
    dec c.budget[]
    if s[j] == '\\':
      j += 2
      continue
    if s[j] == '<' and j + 1 < s.len:
      var k = j + 1
      let closing = s[k] == '/'
      if closing: inc k
      var n = 0
      while n < low.len and k + n < s.len and s[k + n].toLowerAscii == low[n]: inc n
      if n == low.len and (k + n >= s.len or s[k + n] in {'>', ' ', '/', '\t'}):
        let e = findBounded(s, '>', k + n, 512)
        if e < 0: return (-1, -1)
        if closing:
          dec depth
          if depth == 0: return (j, e + 1)
        else: inc depth
        j = e + 1
        continue
    inc j
  (-1, -1)

proc parseInline(s: string; base: Span; c: InlineCtx; res: var seq[Span]) =
  if nesting >= maxNesting:
    res.addText(s, base)
    return
  inc nesting
  defer: dec nesting
  var i = 0
  var buf = ""
  var nextGt = -1
  template emit() =
    res.addText(buf, base)
    buf.setLen(0)
  while i < s.len:
    let ch = s[i]
    case ch
    of '\\':
      if i + 1 < s.len and s[i+1] == '\n':
        emit()
        res.add Span(brk: true, link: -1)
        i += 2
      elif i + 1 < s.len and s[i+1] in {'!'..'/', ':'..'@', '['..'`', '{'..'~'}:
        buf.add s[i+1]
        i += 2
      else:
        buf.add ch
        inc i
    of '&':
      let k = s.find(';', i)
      if k > i and k - i <= 10:
        let name = s[i + 1 ..< k]
        if name.startsWith("#"):
          try:
            let v = if name.len > 1 and name[1] in {'x', 'X'}: parseHexInt(name[2 .. ^1])
                    else: parseInt(name[1 .. ^1])
            buf.add $Rune(v)
            i = k + 1
            continue
          except ValueError: discard
        elif entities.hasKey(name):
          buf.add entities[name]
          i = k + 1
          continue
      buf.add ch
      inc i
    of '`':
      var n = 0
      while i + n < s.len and s[i + n] == '`': inc n
      var k = i + n
      var found = -1
      while k < s.len:
        k = s.find(repeat('`', n), k)
        if k < 0: break
        var m = 0
        while k + m < s.len and s[k + m] == '`': inc m
        if m == n:
          found = k
          break
        k += m
      if found < 0:
        buf.add repeat('`', n)
        i += n
      else:
        emit()
        var code = s[i + n ..< found].replace('\n', ' ')
        if code.len >= 2 and code[0] == ' ' and code[^1] == ' ' and code.strip.len > 0:
          code = code[1 ..< code.len - 1]
        var sp = base
        sp.code = true
        res.addText(code, sp)
        i = found + n
    of '!', '[':
      let img = ch == '!'
      if img and (i + 1 >= s.len or s[i+1] != '['):
        buf.add ch
        inc i
        continue
      let open = if img: i + 1 else: i
      let close = bracketEnd(s, open)
      if close < 0:
        buf.add ch
        inc i
        continue
      let label = s[open + 1 ..< close]
      var url = ""
      var after = close + 1
      let (u, e) = linkDest(s, close + 1)
      if e > 0:
        url = u
        after = e
      elif close + 1 < s.len and s[close + 1] == '[':
        let e2 = s.find(']', close + 1)
        if e2 > 0:
          var key = s[close + 2 ..< e2].toLowerAscii.strip
          if key.len == 0: key = label.toLowerAscii.strip
          url = c.refs[].getOrDefault(key, "")
          if url.len > 0: after = e2 + 1
      else:
        url = c.refs[].getOrDefault(label.toLowerAscii.strip, "")
      if url.len == 0:
        buf.add ch
        inc i
        continue
      emit()
      if img:
        var sp = base
        sp.image = url
        sp.text = label
        sp.link = base.link
        res.add sp
      else:
        c.links[].add url
        var sp = base
        sp.link = c.links[].high
        parseInline(label, sp, c, res)
      i = after
    of '<':
      # the next '>' (looked for once per paragraph, not once per '<')
      if nextGt < i: nextGt = (let g = s.find('>', i); if g < 0: s.len else: g)
      let k = if nextGt < s.len and nextGt - i <= 2048: nextGt else: -1
      if k > i:
        let inner = s[i + 1 ..< k]
        if (inner.startsWith("http://") or inner.startsWith("https://") or
            inner.startsWith("mailto:") or ('@' in inner and '.' in inner)) and
           ' ' notin inner:
          emit()
          c.links[].add(if '@' in inner and ':' notin inner: "mailto:" & inner else: inner)
          var sp = base
          sp.link = c.links[].high
          res.addText(inner, sp)
          i = k + 1
          continue
        if inner.len > 0 and (inner[0].isAlphaAscii or inner[0] == '/') and '\n' notin inner:
          # a few inline HTML tags style their text; other tags are left out
          let (name, closing) = tagNameOf(inner)
          if not closing and name == "br":
            emit()
            res.add Span(brk: true, link: -1)
            i = k + 1
            continue
          if not closing and name in styleTags and not inner.endsWith("/"):
            let (ca, cb) = closeTag(s, k + 1, name, c)
            if ca >= 0:
              emit()
              var sp = base
              case name
              of "b", "strong": sp.bold = true
              of "i", "em", "cite", "var", "dfn": sp.italic = true
              of "u", "ins": sp.underline = true
              of "s", "del", "strike": sp.strike = true
              of "code", "kbd", "samp", "tt": sp.code = true
              of "mark": sp.mark = true
              of "font":
                let col = cssColor(attrOf(inner, "color"))
                if col.a != 0: sp.color = col
              of "span":
                let st = attrOf(inner, "style")
                let col = styleColor(st, "color")
                if col.a != 0: sp.color = col
                let bg = styleColor(st, "background")
                if bg.a != 0 and bg != color(255, 255, 255): sp.mark = true
              of "q": res.addText("\u201C", base)
              else: discard
              parseInline(s[k + 1 ..< ca], sp, c, res)
              if name == "q": res.addText("\u201D", base)
              i = cb
              continue
          i = k + 1                     # an HTML tag: left out
          continue
      buf.add ch
      inc i
    of '*', '_', '~':
      var n = 0
      while i + n < s.len and s[i + n] == ch: inc n
      if ch == '~' and n != 2:
        buf.add repeat(ch, n)
        i += n
        continue
      if ch == '_' and i > 0 and s[i-1].isAlphaNumeric:
        buf.add repeat(ch, n)
        i += n
        continue
      let d = repeat(ch, min(n, 3))
      let next = i + d.len
      if next >= s.len or s[next] in {' ', '\t', '\n'}:
        buf.add repeat(ch, n)
        i += n
        continue
      let k = findClose(s, next, d)
      if k < 0:
        if d.len > 1:
          # try a shorter delimiter
          let k1 = findClose(s, i + 1, $ch)
          if k1 > 0 and ch != '~':
            emit()
            var sp = base
            sp.italic = true
            parseInline(s[i + 1 ..< k1], sp, c, res)
            i = k1 + 1
            continue
        buf.add repeat(ch, n)
        i += n
        continue
      emit()
      var sp = base
      if ch == '~': sp.strike = true
      elif d.len == 1: sp.italic = true
      elif d.len == 2: sp.bold = true
      else:
        sp.bold = true
        sp.italic = true
      parseInline(s[next ..< k], sp, c, res)
      i = k + d.len
    of '\n':
      # two spaces before a line end: a hard break
      if buf.endsWith("  "):
        buf = buf.strip(leading = false)
        emit()
        res.add Span(brk: true, link: -1)
      else:
        buf = buf.strip(leading = false)
        buf.add ' '
      inc i
    of 'h', 'w':
      # bare web addresses
      if (s.continuesWith("https://", i) or s.continuesWith("http://", i) or
          s.continuesWith("www.", i)) and (i == 0 or s[i-1] in {' ', '\n', '('}):
        var k = i
        while k < s.len and s[k] notin {' ', '\t', '\n', '<', '>'}: inc k
        while k > i and s[k-1] in {'.', ',', ':', ';', ')', '!', '?'}: dec k
        let u = s[i ..< k]
        emit()
        c.links[].add(if u.startsWith("www."): "https://" & u else: u)
        var sp = base
        sp.link = c.links[].high
        res.addText(u, sp)
        i = k
      else:
        buf.add ch
        inc i
    else:
      buf.add ch
      inc i
  emit()

# ---- layout -------------------------------------------------------------------------------

type
  Role = enum roText, roMuted, roLink, roCode, roHeading
  Piece = object
    x, y, w, h: int
    gap: int                   ## the space before it on its line
    text: string
    st: TextStyle
    role: Role
    link: int
    fg: Color                  ## its own color (alpha 0: the role's)
    mark: bool                 ## highlighted (<mark>)
  DecoKind = enum dkFill, dkBox, dkHLine, dkBar, dkCheck, dkImage, dkMissing
  Deco = object
    kind: DecoKind
    r: Rect
    role: int                  ## fill: 0 code, 1 table header, 2 face
    checked: bool
    task: int
    src: string
  Layout = object
    pieces: seq[Piece]
    decos: seq[Deco]
    height: int
    links: seq[string]
    anchors: Table[string, int]
  LayoutKey = tuple[h: Hash; w: int; em: int; dir: string]

var
  layoutCache: seq[(LayoutKey, Layout)]
  pictures: Table[string, Bitmap]

proc picture(src, dir: string): Bitmap =
  let path = if src.isAbsolute or dir.len == 0: src else: dir / src
  if not pictures.hasKey(path):
    if pictures.len > 64: pictures.clear()
    pictures[path] =
      if src.startsWith("http://") or src.startsWith("https://"): nil
      else: loadPicture(path, 2048, 2048)
  pictures[path]

proc slug(s: string): string =
  for r in s.toLower.runes:
    let c = $r
    if r.isAlpha or (c.len == 1 and c[0] in Digits): result.add c
    elif c == " " or c == "-": result.add '-'

type Flow = object
  x0, maxW: int
  rtl: bool
  lay: ptr Layout
  y: int
  line: seq[Piece]
  lineW: int
  pendingSpace: int
  pendingStyle: TextStyle

proc finishLine(f: var Flow; minH = 0) =
  var h = minH
  for p in f.line: h = max(h, p.h)
  if f.line.len == 0 and minH == 0:
    return
  if f.rtl and f.line.len > 0:
    # a right-to-left line: words in bidi order (Latin runs and numbers
    # keep their own order), aligned right
    let n = f.line.len
    var lv = newSeq[int](n)
    for i, p in f.line:
      lv[i] = case strongDir(p.text)
        of 1: 1
        of 0, 2: 2
        else: 0
    for i in 0 ..< n:
      if lv[i] == 0:
        var a = i - 1
        while a >= 0 and lv[a] == 0: dec a
        var b = i + 1
        while b < n and lv[b] == 0: inc b
        lv[i] = if a >= 0 and b < n and lv[a] == 2 and lv[b] == 2: 2 else: 1
    var order = newSeq[int](n)
    for i in 0 ..< n: order[i] = i
    for level in [2, 1]:
      var i = 0
      while i < n:
        if lv[order[i]] >= level:
          var j = i
          while j < n and lv[order[j]] >= level: inc j
          var (a, b) = (i, j - 1)
          while a < b:
            swap(order[a], order[b])
            inc a
            dec b
          i = j
        else: inc i
    let spaceW = textWidth(" ")
    proc gapOf(line: seq[Piece]; a, b: int): int =
      if abs(a - b) == 1: line[max(a, b)].gap else: spaceW
    var total = 0
    for k in 0 ..< n:
      total += f.line[order[k]].w
      if k > 0: total += gapOf(f.line, order[k - 1], order[k])
    var x = f.x0 + max(0, f.maxW - total)
    for k in 0 ..< n:
      let i = order[k]
      if k > 0: x += gapOf(f.line, order[k - 1], i)
      f.line[i].x = x
      f.line[i].st.rtl = lv[i] == 1
      x += f.line[i].w
  for p in f.line.mitems:
    p.y = f.y + (h - p.h)
    f.lay.pieces.add p
  f.y += h
  f.line.setLen(0)
  f.lineW = 0
  f.pendingSpace = 0

proc runesEnd(s: string; start, n: int): int =
  ## The byte after `n` letters of `s` from byte `start` (or `s.len`).
  result = start
  var k = 0
  while result < s.len and k < n:
    result += max(1, runeLenAt(s, result))
    inc k
  result = min(result, s.len)

proc runeCount(s: string; start: int): int =
  var i = start
  while i < s.len:
    i += max(1, runeLenAt(s, i))
    inc result

proc place(f: var Flow; s: string; st: TextStyle; role: Role; link: int;
           fg = Color(); mark = false) =
  ## A word (no spaces) on the current line, or the next.
  var s = s
  var w = textWidth(s, st)
  let gap = if f.line.len > 0: f.pendingSpace else: 0
  if f.line.len > 0 and f.lineW + gap + w > f.maxW:
    f.finishLine()
  # a word wider than the line is broken up; what is left is looked at
  # from a byte offset, never copied or measured whole again (a word of a
  # million letters costs what its lines cost)
  if w > f.maxW:
    var at = 0
    while at < s.len:
      # the rest fits on a line: done
      let probe = runesEnd(s, at, 4 * f.maxW + 4)
      let more = probe < s.len
      if not more and textWidth(s[at ..< probe], st) <= f.maxW: break
      if runesEnd(s, at, 2) >= s.len: break           # one letter left
      # the longest start that fits (no glyph is narrower than a pixel, so
      # it has at most as many letters as the room has pixels)
      let room = f.maxW - f.lineW
      var lo = 1
      var hi = max(1, room)
      if runesEnd(s, at, hi + 1) >= s.len:
        hi = max(1, runeCount(s, at) - 1)
      while lo < hi:
        let mid = (lo + hi + 1) div 2
        if textWidth(s[at ..< runesEnd(s, at, mid)], st) <= room: lo = mid else: hi = mid - 1
      let e = runesEnd(s, at, lo)
      let part = s[at ..< e]
      if textWidth(part, st) > room and f.line.len > 0:
        f.finishLine()
        continue
      f.line.add Piece(x: f.x0 + f.lineW, w: textWidth(part, st), h: lineHeight(st),
                       gap: (if f.line.len > 0: f.pendingSpace else: 0),
                       text: part, st: st, role: role, link: link, fg: fg, mark: mark)
      f.finishLine()
      at = e
    if at > 0:
      s = s[at .. ^1]
      w = textWidth(s, st)
  let x = f.x0 + f.lineW + (if f.line.len > 0: f.pendingSpace else: 0)
  # glue to the piece before when it has the same look (fewer, nicer runs)
  if f.line.len > 0 and not f.rtl and f.line[^1].st == st and f.line[^1].role == role and
     f.line[^1].link == link and f.line[^1].fg == fg and f.line[^1].mark == mark:
    let p = addr f.line[^1]
    let sp = if f.pendingSpace > 0: " " else: ""
    p.text.add sp & s
    p.w = textWidth(p.text, st)
    f.lineW = p.x - f.x0 + p.w
  else:
    f.line.add Piece(x: x, w: w, h: lineHeight(st), text: s, st: st, role: role,
                     gap: (if f.line.len > 0: f.pendingSpace else: 0),
                     link: link, fg: fg, mark: mark)
    f.lineW = x - f.x0 + w
  f.pendingSpace = 0

proc flowSpans(f: var Flow; spans: seq[Span]; size: float; boldAll: bool;
               role: Role; dir: string) =
  for sp in spans:
    if sp.brk:
      f.finishLine(lineHeight(style(size = size)))
      continue
    if sp.image.len > 0:
      # inline image: as a small picture if it loads, else its text
      let b = picture(sp.image, dir)
      let lh = lineHeight(style(size = size))
      if b != nil:
        let ih = min(b.h, max(lh, min(b.h, f.maxW * b.h div max(1, b.w))))
        let iw = max(1, b.w * ih div max(1, b.h))
        if f.line.len > 0 and f.lineW + iw > f.maxW: f.finishLine()
        let x = f.x0 + f.lineW + (if f.line.len > 0: f.pendingSpace else: 0)
        f.line.add Piece(x: x, w: iw, h: ih, text: "", role: roText, link: sp.link,
                         gap: (if f.line.len > 0: f.pendingSpace else: 0))
        f.lay.decos.add Deco(kind: dkImage, src: sp.image, r: rect(x, 0, iw, ih),
                             task: f.line.high + f.lay.pieces.len)
        f.lineW = x - f.x0 + iw
        f.pendingSpace = 0
      else:
        f.place("\u{f03e} " & (if sp.text.len > 0: sp.text else: sp.image),
                style(size = size, italic = true), roMuted, sp.link)
      continue
    var st = style(bold = sp.bold or boldAll, italic = sp.italic, mono = sp.code,
                   size = size, strike = sp.strike,
                   underline = sp.link >= 0 or sp.underline)
    st.rtl = f.rtl
    let r = if sp.link >= 0: roLink elif sp.code: roCode else: role
    let fg = if sp.link >= 0: Color() else: sp.color
    var word = ""
    for ch in sp.text:
      if ch == ' ' or ch == '\t':
        if word.len > 0:
          f.place(word, st, r, sp.link, fg, sp.mark)
          word.setLen(0)
        f.pendingSpace = textWidth(" ", st)
        f.pendingStyle = st
      else: word.add ch
    if word.len > 0: f.place(word, st, r, sp.link, fg, sp.mark)

proc layoutBlocks(lay: var Layout; blocks: seq[MdBlock]; doc: MdDoc; x, w: int;
                  y: var int; dir: string; depth = 0; quoted = false; tight = false)

proc layoutInline(lay: var Layout; src: string; doc: MdDoc; x, w: int; y: var int;
                  size = 1.0; bold = false; role = roText; dir = "") =
  var spans: seq[Span]
  inlineBudget = 4 * src.len + 20_000
  var ctx = InlineCtx(links: addr lay.links, refs: unsafeAddr doc.refs,
                      budget: addr inlineBudget)
  parseInline(src, Span(link: -1), ctx, spans)
  # a paragraph that is just an image: shown as large as fits
  if spans.len == 1 and spans[0].image.len > 0:
    let b = picture(spans[0].image, dir)
    if b != nil:
      let iw = min(b.w, w)
      let ih = max(1, b.h * iw div max(1, b.w))
      lay.decos.add Deco(kind: dkImage, src: spans[0].image, r: rect(x, y, iw, ih), task: -1)
      y += ih
      return
  var plain = ""
  for sp in spans: plain.add sp.text
  var f = Flow(x0: x, maxW: max(20, w), rtl: textIsRtl(plain), lay: addr lay, y: y)
  f.flowSpans(spans, size, bold, role, dir)
  f.finishLine()
  # images placed in lines: their final y
  for d in lay.decos.mitems:
    if d.kind == dkImage and d.task >= 0 and d.task < lay.pieces.len:
      let p = lay.pieces[d.task]
      d.r = rect(p.x, p.y, p.w, p.h)
      d.task = -1
  y = f.y

proc gapAfter(): int = max(4, FontH * 3 div 5)

proc layoutCode(lay: var Layout; code: string; x, w: int; y: var int) =
  let st = style(mono = true)
  let pad = dp(8)
  let lh = lineHeight(st)
  let cw = max(1, textWidth("M", st))
  let cols = max(8, (w - 2 * pad) div cw)
  let top = y
  y += pad
  for raw in code.split('\n'):
    let line = raw.replace("\t", "    ")
    var rest = line
    if rest.len == 0:
      y += lh
      continue
    var at = 0
    while at < rest.len:
      let e = runesEnd(rest, at, cols)
      let part = rest[at ..< e]
      lay.pieces.add Piece(x: x + pad, y: y, w: textWidth(part, st), h: lh,
                           text: part, st: st, role: roCode, link: -1)
      at = e
      y += lh
  y += pad
  lay.decos.add Deco(kind: dkFill, role: 0, r: rect(x, top, w, y - top))

proc firstText(b: MdBlock): string =
  ## The first words of a block (a list item's, a quote's): the direction it
  ## reads in.
  case b.kind
  of bkPara, bkHeading, bkHtml: b.text
  of bkTable:
    for row in b.rows:
      let s = row.join(" ").strip
      if s.len > 0: return s
    ""
  else:
    for k in b.kids:
      let s = firstText(k)
      if s.len > 0: return s
    ""

proc layoutTable(lay: var Layout; t: MdBlock; doc: MdDoc; x, w: int; y: var int;
                 dir: string) =
  let n = t.rows[0].len
  if n == 0: return
  # a table whose first words are Arabic (Hebrew...) reads right to left: its
  # first column at the right, its cells from the right ('l' is the start
  # side, 'r' the end)
  let rtlTable = textIsRtl(firstText(t))
  let pad = dp(6)
  var nat = newSeq[int](n)
  var least = newSeq[int](n)
  for ri, row in t.rows:
    for ci in 0 ..< n:
      let s = if ci < row.len: row[ci] else: ""
      let st = style(bold = ri == 0)
      # (right to left the line is made of its words one by one, each as
      # wide as it is alone -- a bold drawn twice, Arabic's, a pixel more
      # for each; left to right of runs of them; +2: rounding)
      var byWords = -textWidth(" ", st)
      for word in s.split(' '):
        byWords += textWidth(" ", st) + textWidth(word, st)
        least[ci] = max(least[ci], min(textWidth(word, st) + 2 * pad, dp(160)))
      let whole = if textIsRtl(s): max(textWidth(s, st), byWords) else: textWidth(s, st)
      nat[ci] = max(nat[ci], whole + 2 * pad + 2)
  var widths = nat
  var total = 0
  for v in nat: total += v
  if total > w:
    var sumMin = 0
    for v in least: sumMin += v
    if sumMin >= w:
      for ci in 0 ..< n: widths[ci] = max(dp(24), least[ci] * w div max(1, sumMin))
    else:
      for ci in 0 ..< n:
        widths[ci] = least[ci] + (nat[ci] - least[ci]) * (w - sumMin) div max(1, total - sumMin)
  var tw = 0
  for v in widths: tw += v
  # (right to left: a table narrower than the page at its right)
  let x = if rtlTable: x + max(0, w - tw) else: x
  let top = y
  # a header row of empty cells: a table without a header (from HTML)
  var headless = true
  for cell in t.rows[0]:
    if cell.strip.len > 0: headless = false
  for ri, row in t.rows:
    if ri == 0 and headless and t.rows.len > 1: continue
    let rowTop = y
    var rowBottom = y
    var cx = if rtlTable: x + tw else: x
    let start = lay.pieces.len
    for ci in 0 ..< n:
      if rtlTable: cx -= widths[ci]
      var cy = y + pad
      let s = if ci < row.len: row[ci] else: ""
      let first = lay.pieces.len
      layoutInline(lay, s, doc, cx + pad, widths[ci] - 2 * pad, cy, bold = ri == 0,
                   dir = dir)
      # alignment within the cell
      let a = if ci < t.aligns.len: t.aligns[ci] else: 'l'
      if rtlTable or a in {'c', 'r'}:
        let side = if a == 'c': 'c' elif rtlTable: (if a == 'r': 'l' else: 'r') else: a
        var lo, hi: Table[int, int]
        for k in first ..< lay.pieces.len:
          let p = lay.pieces[k]
          lo[p.y] = min(lo.getOrDefault(p.y, high(int)), p.x)
          hi[p.y] = max(hi.getOrDefault(p.y, low(int)), p.x + p.w)
        for k in first ..< lay.pieces.len:
          let ly = lay.pieces[k].y
          let room = max(0, widths[ci] - 2 * pad - (hi[ly] - lo[ly]))
          let want = case side
            of 'c': cx + pad + room div 2
            of 'r': cx + pad + room
            else: cx + pad
          lay.pieces[k].x += want - lo[ly]
      rowBottom = max(rowBottom, cy + pad)
      if not rtlTable: cx += widths[ci]
    discard start
    if ri == 0:
      lay.decos.add Deco(kind: dkFill, role: 1, r: rect(x, rowTop, tw, rowBottom - rowTop))
    lay.decos.add Deco(kind: dkHLine, r: rect(x, rowBottom, tw, 1))
    y = rowBottom
  # grid
  lay.decos.add Deco(kind: dkBox, r: rect(x, top, tw + 1, y - top + 1))
  var cx = if rtlTable: x + tw else: x
  for ci in 0 ..< n - 1:
    if rtlTable: cx -= widths[ci] else: cx += widths[ci]
    lay.decos.add Deco(kind: dkHLine, r: rect(cx, top, 1, y - top))
  y += 1

proc layoutBlocks(lay: var Layout; blocks: seq[MdBlock]; doc: MdDoc; x, w: int;
                  y: var int; dir: string; depth = 0; quoted = false; tight = false) =
  for bi, b in blocks:
    if bi > 0: y += (if tight: dp(2) else: gapAfter())
    case b.kind
    of bkPara, bkHtml:
      layoutInline(lay, b.text, doc, x, w, y, role = if quoted: roMuted else: roText,
                   dir = dir)
    of bkHeading:
      const sizes = [1.9, 1.5, 1.25, 1.1, 1.0, 0.95]
      let size = sizes[clamp(b.level, 1, 6) - 1]
      if bi > 0: y += FontH div 2
      lay.anchors[slug(b.text)] = y
      layoutInline(lay, b.text, doc, x, w, y, size = size, bold = true,
                   role = if b.level >= 6: roMuted else: roHeading, dir = dir)
      if b.level <= 2:
        y += dp(4)
        lay.decos.add Deco(kind: dkHLine, r: rect(x, y, w, 1))
        y += 1
    of bkCode:
      layoutCode(lay, b.text, x, w, y)
    of bkRule:
      y += dp(4)
      lay.decos.add Deco(kind: dkHLine, r: rect(x, y, w, 1))
      y += dp(5)
    of bkQuote:
      let top = y
      let ind = dp(14)
      # (right to left: the bar at the right)
      let rtl = textIsRtl(firstText(b))
      layoutBlocks(lay, b.kids, doc, (if rtl: x else: x + ind), w - ind, y, dir, depth, quoted = true)
      lay.decos.add Deco(kind: dkBar, r: rect((if rtl: x + w - dp(6) else: x + dp(2)), top, dp(4),
                                             max(FontH, y - top)))
    of bkList:
      let ind = if b.ordered: textWidth($(b.start + b.kids.len) & ".") + dp(10)
                else: dp(22)
      let isTight = true
      for k, item in b.kids:
        if k > 0: y += dp(3)
        let top = y
        var cy = y
        # an item in Arabic (Hebrew...): its bullet or number at the right,
        # its text from there
        let rtl = textIsRtl(firstText(item))
        let textX = if rtl: x else: x + ind
        if item.task >= 0:
          let bs = max(dp(13), FontH - 3)
          lay.decos.add Deco(kind: dkCheck, r: rect((if rtl: x + w - bs - 2 else: x + 2),
                                                    top + (FontH - bs) div 2 + 1, bs, bs),
                             checked: item.task == 1, task: item.taskIndex)
        elif b.ordered:
          let m = $(b.start + k) & "."
          let mw = textWidth(m)
          lay.pieces.add Piece(x: (if rtl: x + w - ind + dp(6) else: textX - dp(6) - mw), y: top,
                               w: mw, h: FontH, text: m, role: roText, link: -1)
        else:
          let bullet = ["•", "◦", "▪"][depth mod 3]
          let bw = textWidth(bullet)
          lay.pieces.add Piece(x: (if rtl: x + w - dp(6) - bw else: x + dp(6)), y: top, w: bw,
                               h: FontH, text: bullet, role: roText, link: -1)
        layoutBlocks(lay, item.kids, doc, textX, w - ind, cy, dir, depth + 1,
                     quoted, tight = isTight)
        y = max(cy, top + FontH)
    of bkItem:
      layoutBlocks(lay, b.kids, doc, x, w, y, dir, depth, quoted)
    of bkTable:
      layoutTable(lay, b, doc, x, w, y, dir)

proc layoutOf(md: string; w: int; dir: string): ptr Layout =
  let key: LayoutKey = (hash(md), w, int(textSize() * 100), dir)
  for i in 0 ..< layoutCache.len:
    if layoutCache[i][0] == key:
      if i > 0:
        let e = layoutCache[i]
        layoutCache.delete(i)
        layoutCache.insert(e, 0)
      return addr layoutCache[0][1]
  let doc = parseMarkdown(md)
  var lay = Layout()
  var y = 0
  layoutBlocks(lay, doc.blocks, doc, 0, w, y, dir)
  lay.height = y
  lay.pieces.sort(proc (a, b: Piece): int = cmp(a.y, b.y))
  layoutCache.insert((key, lay), 0)
  if layoutCache.len > 6: layoutCache.setLen(6)
  addr layoutCache[0][1]

# ---- drawing ---------------------------------------------------------------------------------

type MdEvent* = object
  ## What happened in a `markdown` or `markdownView` this frame.
  link*: string        ## a link clicked (its url), or ""
  task*: int           ## a task box clicked (its number), or -1

proc roleColor(r: Role): Color =
  case r
  of roText: th.fieldText
  of roMuted: th.gray
  of roLink: th.link
  of roCode: (if th.field.r < 128: color(230, 200, 140) else: color(140, 30, 30))
  of roHeading: (if th.field.r < 128: th.fieldText else: th.select)

proc drawLayout(lay: ptr Layout; x, y: int; clip: Rect; dir: string;
                clicked: bool; ev: var MdEvent) =
  let codeBg = if th.field.r < 128: color(45, 45, 45) else: color(244, 244, 238)
  let headBg = th.face
  let p = point(ui.mx, ui.my)
  let canClick = canInput() and mouseIn(clip)
  for d in lay.decos:
    let r = rect(d.r.x + x, d.r.y + y, d.r.w, d.r.h)
    if r.y > clip.y + clip.h or r.y + r.h < clip.y: continue
    case d.kind
    of dkFill:
      fill(r, if d.role == 0: codeBg else: headBg)
      if d.role == 0: box(r, th.face)
    of dkBox: box(r, th.shadow)
    of dkHLine: fill(r, th.shadow)
    of dkBar: fill(r, th.shadow)
    of dkCheck:
      fill(r, th.field)
      box(r, th.edge)
      if d.checked:
        let t = max(1.0, float(r.w) / 8)
        let (fx, fy, fw, fh) = (float(r.x), float(r.y), float(r.w), float(r.h))
        thickLine(fx + 2.5, fy + fh / 2, fx + fw / 2.6, fy + fh - 3, t, th.fieldText)
        thickLine(fx + fw / 2.6, fy + fh - 3, fx + fw - 2.5, fy + 2.5, t, th.fieldText)
      if canClick and clicked and r.contains(p):
        ev.task = d.task
    of dkImage:
      let b = picture(d.src, dir)
      if b != nil: drawBitmap(r, b)
    of dkMissing: discard
  # text: from the first piece that can show
  var lo = 0
  var hi = lay.pieces.len
  while lo < hi:
    let m = (lo + hi) div 2
    if lay.pieces[m].y + y + 200 < clip.y: lo = m + 1 else: hi = m
  var hoverLink = -1
  for k in lo ..< lay.pieces.len:
    let pc = lay.pieces[k]
    let py = pc.y + y
    if py > clip.y + clip.h: break
    if pc.text.len == 0: continue
    let r = rect(pc.x + x, py, pc.w, pc.h)
    if pc.link >= 0 and canClick and r.contains(p): hoverLink = pc.link
    if pc.mark:
      fill(rect(r.x - 1, r.y, r.w + 2, r.h),
           if th.field.r < 128: color(110, 95, 10) else: color(255, 240, 120))
    text(r.x, r.y, pc.text, if pc.fg.a != 0: pc.fg else: roleColor(pc.role), pc.st)
  if hoverLink >= 0:
    ui.cursor = curHand
    if clicked: ev.link = lay.links[hoverLink]

proc mdPlainText*(md: string): string =
  ## Markdown as it is read out: the words, without its marks (`#`, `**`,
  ## backticks, a link's address).
  for line in md.splitLines:
    var t = line.strip(trailing = false)
    var k = 0
    while k < t.len and t[k] == '#': inc k
    if k > 0 and k < t.len and t[k] == ' ': t = t[k + 1 .. ^1]
    elif t.startsWith("> "): t = t[2 .. ^1]
    var o = ""
    var i = 0
    while i < t.len:
      let c = t[i]
      if c in {'*', '_', '`'} and (i + 1 >= t.len or t[i + 1] in {'*', '_', '`', ' '} or
                                   i == 0 or t[i - 1] in {'*', '_', '`', ' '}):
        inc i
        continue
      if c == ']' and i + 1 < t.len and t[i + 1] == '(':
        let e = t.find(')', i + 2)
        if e > 0:
          i = e + 1
          continue
      if c == '[' or (c == '!' and i + 1 < t.len and t[i + 1] == '['):
        inc i
        continue
      o.add c
      inc i
    if result.len > 0: result.add '\n'
    result.add o


proc mdNode(md: string; id: Id; r: Rect) =
  ## (a document's node for screen readers: read by the label before it,
  ## else by its first heading)
  var title = ""
  for line in md.splitLines:
    if line.startsWith("#"):
      title = line.strip(chars = {'#', ' '})
      break
  accessNameOr(if title.len > 0: title else: tr("Document"))
  accessNode(arTextArea, value = mdPlainText(md), id = id, r = r, states = {asReadOnly, asMultiLine})

proc markdown*(md: string; baseDir = ""; w = 0): MdEvent {.discardable.} =
  ## Markdown flowing in the layout at its natural height (in a page that
  ## scrolls, a card, a dialog). See `markdownView` for a framed, scrolling
  ## view.
  result.task = -1
  let width = if w > 0: w else: available()
  let lay = layoutOf(md, width, baseDir)
  let r = place(width, lay.height)
  let id = idOf("md" & $hash(md))
  let hit = interact(id, r, focusable = false)
  drawLayout(lay, r.x, r.y, intersect(r, clipRect()), baseDir, hit.clicked, result)
  if accessOn: mdNode(md, id, r)
  ui.lastId = id
  ui.lastRect = r

proc markdownView*(md: string; height = -1; w = 0; baseDir = "";
                   key = ""): MdEvent {.discardable.} =
  ## Markdown in a framed view that scrolls (wheel, finger, scroll bar,
  ## arrows and Page keys). Returns the link or task box clicked; links to
  ## "#a-heading" scroll there themselves. Pictures load from `baseDir`.
  ## `key` tells views apart (each keeps where it is scrolled to). Arabic
  ## (Hebrew...) reads right to left: a paragraph, a list item or a quote
  ## whose first words are Arabic has its bullet, number or bar at the
  ## right, and such a table its first column at the right.
  result.task = -1
  let r = place(if w > 0: w else: 0, if height < 0: remainingH() else: height,
                fill = w <= 0)
  let id = idOf("mdview" & $height & key)
  var st = state(id)
  var hit = interact(id, r)
  let pad = dp(10)
  let inner = rect(r.x + 1, r.y + 1, r.w - SbW - 1, r.h - 2)
  let lay = layoutOf(md, max(40, inner.w - 2 * pad), baseDir)
  let maxY = max(0, lay.height + 2 * pad - inner.h)
  var y = clamp(st.scrollY, 0, maxY)
  scrollWheel(id, y, maxY, r, 3 * FontH)
  scrollPan(id, y, maxY, r)
  if hit.focused and canInput():
    case ui.key
    of KeyUp: scrollBy(id, y, -FontH, maxY); ui.keyUsed = true
    of KeyDown: scrollBy(id, y, FontH, maxY); ui.keyUsed = true
    of KeyPageUp: scrollBy(id, y, -(inner.h - FontH), maxY); ui.keyUsed = true
    of KeyPageDown, KeySpace: scrollBy(id, y, inner.h - FontH, maxY); ui.keyUsed = true
    of KeyHome: scrollTo(id, y, 0, maxY); ui.keyUsed = true
    of KeyEnd: scrollTo(id, y, maxY, maxY); ui.keyUsed = true
    of KeyC:
      if CtrlPressed in ui.mods:
        putClipboardText(md)
        ui.keyUsed = true
    else: discard
  scrollTick(id, y, maxY)
  y = clamp(y, 0, maxY)
  scrollBarFor(id + 9, id, rect(r.x + r.w - SbW, r.y, SbW, r.h), true, y,
               maxY, max(FontH, inner.h - FontH), FontH)
  fill(inner, th.field)
  fieldFrame(r)
  pushClip(inner)
  beginKeepSides(inner)          # (the text as it reads: a right-to-left interface does not mirror it)
  drawLayout(lay, inner.x + pad, inner.y + pad - y, inner, baseDir, hit.clicked, result)
  endKeepSides()
  popClip()
  if hit.focused: dots(inset(r, 1), th.text)
  if result.link.startsWith("#"):
    let a = lay.anchors.getOrDefault(result.link[1 .. ^1].toLowerAscii, -1)
    if a >= 0: scrollTo(id, y, a, maxY)          # (it glides there)
    result.link = ""
  if y != st.scrollY:
    st.scrollY = y
    ui.redraw = true
  state(id) = st
  if accessOn: mdNode(md, id, r)
  ui.lastId = id
  ui.lastRect = r

proc toggleTask*(md: var string; index: int) =
  ## Ticks (or clears) task box number `index` (``- [ ]`` / ``- [x]``) in `md`.
  var n = 0
  var pos = 0
  for line in md.split('\n'):
    let t = line.strip(trailing = false)
    var k = 0
    if t.len > 0 and t[0] in {'-', '*', '+'}: k = 1
    else:
      while k < t.len and t[k] in Digits: inc k
      if k > 0 and k < t.len and t[k] in {'.', ')'}: inc k else: k = 0
    if k > 0:
      let rest = t[k .. ^1].strip(trailing = false)
      if rest.len >= 3 and rest[0] == '[' and rest[2] == ']' and rest[1] in {' ', 'x', 'X'}:
        if n == index:
          let at = pos + (line.len - t.len) + k + (t.len - k - rest.len) + 1
          md[at] = if rest[1] == ' ': 'x' else: ' '
          return
        inc n
    pos += line.len + 1
