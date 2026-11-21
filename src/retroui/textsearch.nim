## Find and Change in text: plain words, or patterns as a layout
## program's GREP writes them -- in letters of any script, Arabic and
## Hebrew too -- and changes that keep each text's styles.
##
## Patterns: a letter stands for itself (`\` before one of `.^$|?*+()[]{}\`
## too); `.` any character but a new line; `[abc]`, `[a-z]`, `[^0-9]` one
## of them (or none of them); `\d` a digit (Arabic-Indic too), `\w` a
## letter, a digit or `_`, `\s` a space, a tab or a new line (`\D`, `\W`,
## `\S` what they are not); `\b` a word's edge; `\t`, `\n`; `^`, `$` a
## line's start and end; `(...)` a group (`(?:...)` one not kept), `a|b`
## either; `*`, `+`, `?`, `{2}`, `{2,}`, `{2,5}` so many times (most it
## can; a `?` after: fewest). A change says `$0` for what was found, `$1`
## .. `$9` for a group's.
##
## - `compilePattern`, `find`: where a pattern is in a text (characters,
##   not bytes).
## - `findIn`: each match in a `TextData`; `changeIn`: each changed, the
##   letters around keeping their styles, the change in the style of what
##   it changes.
## - `editPlain`: a text's words made another's (a story editor's): only
##   what changed changes, the styles of the rest kept.
## - `arabicFold`, `findFolded`: Arabic as written either way -- with or
##   without harakat and the other marks, tatweel, hamza's seats (أ إ آ ٱ
##   as ا, ؤ as و, ئ as ي), ى as ي and ة as ه -- found as the same; `findIn`
##   and `changeIn` take it as `arabic`.
## - `findGlyph`, `changeGlyph`: Find/Change's Glyph search -- a character
##   in a font (or any), changed to another, in a font of its own.
## - `SavedQuery`, `builtInQueries`, `queriesToJson`, `queriesFrom`:
##   Find/Change's saved queries, and the ones it comes with.
##
## .. code-block:: nim
##   import retroui/[textengine, textsearch]
##   var t = newText("Call 555-1234 or 555-9876")
##   let n = t.changeIn(r"(\d{3})-(\d{4})", "$1 $2", patterns = true)   # 2
##
## Developed by Sultan Al Isaiee @foxoman -- www.foxoman.net -- sultan@foxoman.net

import std/[strutils, json]
import std/unicode except strip
import textengine

type
  PatternError* = object of ValueError
    ## A pattern that cannot be read (a bracket not closed...).

  NodeKind = enum
    nkChar, nkAny, nkClass, nkStart, nkEnd, nkWordEdge, nkNotWordEdge, nkGroup, nkAlt, nkRepeat, nkSeq
  Node = ref object
    case kind: NodeKind
    of nkChar: c: int
    of nkClass:
      ranges: seq[(int, int)]
      named: seq[char]           # (\d \w \s and their opposites: 'd' 'w' 's' 'D' 'W' 'S')
      negate: bool
    of nkGroup:
      inner: Node
      index: int                 # (0: not kept)
    of nkAlt, nkSeq: items: seq[Node]
    of nkRepeat:
      sub: Node
      lo, hi: int                # (hi -1: no end)
      lazy: bool
    else: discard

  Pattern* = object
    ## A pattern read (`compilePattern`).
    root: Node
    groups: int
    ignoreCase: bool

  Match* = object
    ## Where a pattern was found: characters `a` ..< `b`, and its groups'.
    a*, b*: int
    groups*: seq[(int, int)]     ## (-1, -1): a group that took part in nothing

proc isDigitRune(c: int): bool = c in int('0') .. int('9') or c in 0x0660 .. 0x0669 or c in 0x06F0 .. 0x06F9
proc isWordRune(c: int): bool =
  c == int('_') or isDigitRune(c) or (c >= 128 and Rune(c).isAlpha) or c in int('a') .. int('z') or
    c in int('A') .. int('Z') or c in 0x064B .. 0x065F   # (Arabic's marks are a word's)
proc isSpaceRune(c: int): bool = c in [9, 10, 11, 12, 13, 32, 0xA0, 0x2009, 0x200A, 0x202F, 0x3000]

proc lower(c: int): int = (if c < 128: ord(toLowerAscii(char(c))) else: int(toLower(Rune(c))))

# ---- reading a pattern -------------------------------------------------------------------------------------

type Reader = object
  cps: seq[int]
  i: int
  groups: int

proc peek(r: Reader): int = (if r.i < r.cps.len: r.cps[r.i] else: -1)

proc fail(msg: string) {.noreturn.} = raise newException(PatternError, msg)

proc parseAlt(r: var Reader): Node

proc escapeNode(c: int): Node =
  case char(min(c, 255))
  of 'd', 'w', 's', 'D', 'W', 'S': Node(kind: nkClass, named: @[char(c)])
  of 'b': Node(kind: nkWordEdge)
  of 'B': Node(kind: nkNotWordEdge)
  of 't': Node(kind: nkChar, c: 9)
  of 'n': Node(kind: nkChar, c: 10)
  of 'r': Node(kind: nkChar, c: 13)
  else: Node(kind: nkChar, c: c)

proc parseClass(r: var Reader): Node =
  result = Node(kind: nkClass)
  if r.peek == int('^'):
    result.negate = true
    inc r.i
  var first = true
  while true:
    let c = r.peek
    if c < 0: fail("a [ is not closed")
    if c == int(']') and not first:
      inc r.i
      break
    first = false
    inc r.i
    var lo = c
    if c == int('\\'):
      let e = r.peek
      if e < 0: fail("a \\ ends the pattern")
      inc r.i
      if char(min(e, 255)) in {'d', 'w', 's', 'D', 'W', 'S'}:
        result.named.add char(e)
        continue
      lo = if e == int('t'): 9 elif e == int('n'): 10 else: e
    if r.peek == int('-') and r.i + 1 < r.cps.len and r.cps[r.i + 1] != int(']'):
      inc r.i
      var hi = r.peek
      inc r.i
      if hi == int('\\'):
        hi = r.peek
        inc r.i
      if hi < lo: fail("a range backwards")
      result.ranges.add (lo, hi)
    else: result.ranges.add (lo, lo)

proc parseAtom(r: var Reader): Node =
  let c = r.peek
  inc r.i
  case c
  of int('.'): Node(kind: nkAny)
  of int('^'): Node(kind: nkStart)
  of int('$'): Node(kind: nkEnd)
  of int('['): parseClass(r)
  of int('('):
    var idx = 0
    if r.peek == int('?') and r.i + 1 < r.cps.len and r.cps[r.i + 1] == int(':'):
      r.i += 2
    else:
      inc r.groups
      idx = r.groups
    let inner = parseAlt(r)
    if r.peek != int(')'): fail("a ( is not closed")
    inc r.i
    Node(kind: nkGroup, inner: inner, index: idx)
  of int('\\'):
    let e = r.peek
    if e < 0: fail("a \\ ends the pattern")
    inc r.i
    escapeNode(e)
  else: Node(kind: nkChar, c: c)

proc parseNumber(r: var Reader): int =
  result = -1
  while r.peek in int('0') .. int('9'):
    result = max(0, result) * 10 + r.peek - int('0')
    if result > 100_000: fail("a count too big")
    inc r.i

proc parseSeq(r: var Reader): Node =
  result = Node(kind: nkSeq)
  while r.i < r.cps.len and r.peek != int('|') and r.peek != int(')'):
    if r.peek in [int('*'), int('+'), int('?')] or (r.peek == int('{') and result.items.len == 0):
      fail("nothing before a " & $Rune(r.peek))
    var atom = parseAtom(r)
    while true:
      var lo, hi = -2
      let c = r.peek
      if c == int('*'): (lo, hi) = (0, -1)
      elif c == int('+'): (lo, hi) = (1, -1)
      elif c == int('?'): (lo, hi) = (0, 1)
      elif c == int('{'):
        let save = r.i
        inc r.i
        let a = parseNumber(r)
        if a < 0:
          r.i = save
          break
        var b = a
        if r.peek == int(','):
          inc r.i
          b = parseNumber(r)
        if r.peek != int('}'):
          r.i = save
          break
        (lo, hi) = (a, b)
        if hi >= 0 and hi < lo: fail("a count backwards")
      else: break
      inc r.i
      var lazy = false
      if r.peek == int('?'):
        lazy = true
        inc r.i
      atom = Node(kind: nkRepeat, sub: atom, lo: lo, hi: hi, lazy: lazy)
    result.items.add atom

proc parseAlt(r: var Reader): Node =
  result = Node(kind: nkAlt)
  result.items.add parseSeq(r)
  while r.peek == int('|'):
    inc r.i
    result.items.add parseSeq(r)
  if result.items.len == 1: result = result.items[0]

proc compilePattern*(pattern: string; ignoreCase = false): Pattern =
  ## `pattern` read (raises `PatternError` when it cannot be).
  var r = Reader()
  for ru in pattern.runes: r.cps.add int(ru)
  result.root = parseAlt(r)
  if r.i < r.cps.len: fail("a ) without its (")
  result.groups = r.groups
  result.ignoreCase = ignoreCase

proc literalPattern*(words: string; ignoreCase = false; wholeWord = false): Pattern =
  ## A pattern that is `words` as they are (`wholeWord`: not inside a longer word).
  var seqN = Node(kind: nkSeq)
  if wholeWord: seqN.items.add Node(kind: nkWordEdge)
  for ru in words.runes: seqN.items.add Node(kind: nkChar, c: int(ru))
  if wholeWord: seqN.items.add Node(kind: nkWordEdge)
  Pattern(root: seqN, ignoreCase: ignoreCase)

# ---- matching ------------------------------------------------------------------------------------------

type Matcher = ref object
  cps: seq[int]
  ic: bool
  caps: seq[(int, int)]
  steps: int

proc inClass(m: Matcher; n: Node; c: int): bool =
  var hit = false
  let cl = if m.ic: lower(c) else: c
  for (lo, hi) in n.ranges:
    if (c >= lo and c <= hi) or (m.ic and ((cl >= lower(lo) and cl <= lower(hi)) or
                                           (lower(c) != c and false))):
      hit = true
      break
    if m.ic and lo == hi and lower(lo) == cl:
      hit = true
      break
  if not hit:
    for k in n.named:
      let h = case k
              of 'd': isDigitRune(c)
              of 'D': not isDigitRune(c)
              of 'w': isWordRune(c)
              of 'W': not isWordRune(c)
              of 's': isSpaceRune(c)
              else: not isSpaceRune(c)
      if h:
        hit = true
        break
  hit != n.negate

proc atWordEdge(m: Matcher; i: int): bool =
  let before = i > 0 and isWordRune(m.cps[i - 1])
  let after = i < m.cps.len and isWordRune(m.cps[i])
  before != after

proc matchNode(m: Matcher; n: Node; i: int; k: proc (j: int): bool): bool

proc matchSeq(m: Matcher; items: seq[Node]; at, i: int; k: proc (j: int): bool): bool =
  if at >= items.len: return k(i)
  matchNode(m, items[at], i, proc (j: int): bool = matchSeq(m, items, at + 1, j, k))

proc matchRepeat(m: Matcher; n: Node; count, i: int; k: proc (j: int): bool): bool =
  inc m.steps
  if m.steps > 2_000_000: raise newException(PatternError, "the pattern takes too long here")
  let more = n.hi < 0 or count < n.hi
  let enough = count >= n.lo
  template again(): bool =
    more and matchNode(m, n.sub, i, proc (j: int): bool =
      j != i and matchRepeat(m, n, count + 1, j, k))   # (a step that takes nothing: not again)
  if n.lazy:
    if enough and k(i): return true
    return again()
  if again(): return true
  enough and k(i)

proc matchNode(m: Matcher; n: Node; i: int; k: proc (j: int): bool): bool =
  case n.kind
  of nkChar:
    i < m.cps.len and (m.cps[i] == n.c or (m.ic and lower(m.cps[i]) == lower(n.c))) and k(i + 1)
  of nkAny: i < m.cps.len and m.cps[i] != 10 and k(i + 1)
  of nkClass: i < m.cps.len and inClass(m, n, m.cps[i]) and k(i + 1)
  of nkStart: (i == 0 or m.cps[i - 1] == 10) and k(i)
  of nkEnd: (i == m.cps.len or m.cps[i] == 10) and k(i)
  of nkWordEdge: atWordEdge(m, i) and k(i)
  of nkNotWordEdge: not atWordEdge(m, i) and k(i)
  of nkSeq: matchSeq(m, n.items, 0, i, k)
  of nkAlt:
    for it in n.items:
      if matchNode(m, it, i, k): return true
    false
  of nkGroup:
    if n.index == 0: matchNode(m, n.inner, i, k)
    else:
      let old = m.caps[n.index]
      if matchNode(m, n.inner, i, proc (j: int): bool =
          let was = m.caps[n.index]
          m.caps[n.index] = (i, j)
          if k(j): return true
          m.caps[n.index] = was
          false):
        return true
      m.caps[n.index] = old
      false
  of nkRepeat: matchRepeat(m, n, 0, i, k)

proc find*(p: Pattern; cps: seq[int]; start = 0): Match =
  ## The first place at or after character `start` of `cps` where `p` is (`a` -1: nowhere).
  result = Match(a: -1, b: -1)
  var m = Matcher(cps: cps, ic: p.ignoreCase)
  for s in start .. cps.len:
    m.caps = newSeq[(int, int)](p.groups + 1)
    for c in m.caps.mitems: c = (-1, -1)
    var e = -1
    if matchNode(m, p.root, s, proc (j: int): bool = (e = j; true)):
      result = Match(a: s, b: e, groups: m.caps)
      result.groups[0] = (s, e)
      return

proc runesOf(s: string): seq[int] =
  for r in s.runes: result.add int(r)

proc findAll*(p: Pattern; s: string): seq[Match] =
  ## Every place `p` is in `s`, one after another, not overlapping (characters).
  let cps = runesOf(s)
  var at = 0
  while at <= cps.len:
    let m = p.find(cps, at)
    if m.a < 0: break
    result.add m
    at = if m.b > m.a: m.b else: m.a + 1

proc expand*(change: string; m: Match; cps: seq[int]): string =
  ## A change with `$0`..`$9` (what was found, its groups), `\n`, `\t` written out.
  var i = 0
  while i < change.len:
    let c = change[i]
    if c == '$' and i + 1 < change.len and change[i + 1] in '0' .. '9':
      let g = ord(change[i + 1]) - ord('0')
      if g < m.groups.len and m.groups[g][0] >= 0:
        for k in m.groups[g][0] ..< m.groups[g][1]: result.add $Rune(cps[k])
      i += 2
    elif c == '\\' and i + 1 < change.len and change[i + 1] in {'n', 't', '\\', '$'}:
      let e = change[i + 1]
      result.add(if e == 'n': "\n" elif e == 't': "\t" elif e == '$': "$" else: "\\")
      i += 2
    else:
      result.add c
      inc i

# ---- Arabic as written either way ----------------------------------------------------------------------

proc arabicLeftOut*(c: int): bool =
  ## Left out when Arabic is matched as written either way: the harakat and the Quran's marks (all
  ## combining marks of the Arabic block), tatweel.
  c in 0x0610 .. 0x061A or c in 0x064B .. 0x065F or c == 0x0670 or c in 0x06D6 .. 0x06DC or
    c in 0x06DF .. 0x06E4 or c in 0x06E7 .. 0x06E8 or c in 0x06EA .. 0x06ED or c in 0x08D3 .. 0x08FF or
    c == 0x0640

proc arabicBase*(c: int): int =
  ## A letter as Arabic matched either way has it: hamza's seats as the letter (أ إ آ ٱ ا, ؤ و,
  ## ئ ي), ى as ي, ة as ه; the rest as it is.
  case c
  of 0x0622, 0x0623, 0x0625, 0x0671, 0x0672, 0x0673: 0x0627
  of 0x0624: 0x0648
  of 0x0626, 0x0649, 0x06CC: 0x064A
  of 0x0629: 0x0647
  else: c

proc arabicFold*(cps: openArray[int]): tuple[cps: seq[int]; at: seq[int]] =
  ## `cps` as Arabic is matched either way (`arabicLeftOut` gone, each letter its `arabicBase`),
  ## and where each of what is left came from.
  for i, c in cps:
    if arabicLeftOut(c): continue
    result.cps.add arabicBase(c)
    result.at.add i

proc arabicFolded*(s: string): string =
  ## A string as Arabic is matched either way.
  for r in s.runes:
    let c = int(r)
    if not arabicLeftOut(c): result.add $Rune(arabicBase(c))

proc findFolded*(p: Pattern; cps: seq[int]; start = 0): Match =
  ## As `find`, Arabic matched as written either way (`p` made from an `arabicFolded` search): the
  ## places in `cps` as they are -- a letter's marks after it with it.
  result = Match(a: -1, b: -1)
  let (f, at) = arabicFold(cps)
  var s0 = 0
  while s0 < at.len and at[s0] < start: inc s0
  let m = p.find(f, s0)
  if m.a < 0: return
  template back(j: int): int = (if j >= at.len: cps.len else: at[j])
  result = Match(a: back(m.a), b: (if m.b > m.a: back(m.b) else: back(m.a)))
  for g in m.groups:
    result.groups.add(if g[0] < 0: (-1, -1) else: (back(g[0]), back(g[1])))

# ---- in a text, keeping its styles ----------------------------------------------------------------------

proc patternOf*(what: string; patterns, matchCase, wholeWord: bool): Pattern =
  ## (the search Find/Change asks for: a pattern, or the words as they are)
  if patterns:
    var src = what
    if wholeWord: src = "\\b(?:" & src & ")\\b"
    compilePattern(src, ignoreCase = not matchCase)
  else: literalPattern(what, ignoreCase = not matchCase, wholeWord = wholeWord)

proc findIn*(t: TextData; what: string; patterns = false; matchCase = false; wholeWord = false;
             arabic = false): seq[Match] =
  ## Each place `what` is in the text (characters); `arabic`: Arabic matched as written either way
  ## (`findFolded`).
  if what.len == 0: return
  if not arabic: return patternOf(what, patterns, matchCase, wholeWord).findAll(t.plainText)
  let p = patternOf(arabicFolded(what), patterns, matchCase, wholeWord)
  let cps = runesOf(t.plainText)
  var at = 0
  while at <= cps.len:
    let m = p.findFolded(cps, at)
    if m.a < 0: break
    result.add m
    at = if m.b > m.a: m.b else: m.a + 1

proc changeIn*(t: var TextData; what, change: string; patterns = false; matchCase = false;
               wholeWord = false; arabic = false): int =
  ## Each place `what` is in the text changed to `change` (its groups in it); the rest keeps its
  ## styles, each change takes the style of the first letter it replaces. How many changed.
  ## `arabic`: Arabic matched as written either way.
  if what.len == 0: return 0
  let cps = runesOf(t.plainText)
  let found = t.findIn(what, patterns, matchCase, wholeWord, arabic)
  for k in countdown(found.high, 0):
    let m = found[k]
    let st = t.styleAt(m.a)
    let s = expand(change, m, cps)
    t.deleteText(m.a, m.b)
    if s.len > 0: t.insertText(m.a, s, st)
  found.len

proc editPlain*(t: var TextData; words: string) =
  ## The text made to say `words`: what is the same at its start and its end kept as it is,
  ## with its styles; what is between replaced (in the style of the first letter it replaces).
  let a = runesOf(t.plainText)
  let b = runesOf(words)
  var pre = 0
  while pre < a.len and pre < b.len and a[pre] == b[pre]: inc pre
  var suf = 0
  while suf < a.len - pre and suf < b.len - pre and a[a.len - 1 - suf] == b[b.len - 1 - suf]: inc suf
  if pre == a.len and pre == b.len: return
  let st = t.styleAt(pre)
  t.deleteText(pre, a.len - suf)
  var mid = ""
  for k in pre ..< b.len - suf: mid.add $Rune(b[k])
  if mid.len > 0: t.insertText(pre, mid, st)

# ---- glyphs --------------------------------------------------------------------------------------------

proc glyphOf*(s: string): int =
  ## A glyph as Find/Change's Glyph search is told it: the character itself ("é"), or its code
  ## point -- "U+00E9", "0xE9", "\u00e9" (-1: neither).
  let t = s.strip
  if t.len == 0: return -1
  for pre in ["U+", "u+", "0x", "0X", "\\u", "\\U"]:
    if t.startsWith(pre) and t.len > pre.len:
      try: return clamp(parseHexInt(t[pre.len .. ^1]), 0, 0x10FFFF) except ValueError: return -1
  let rs = t.toRunes
  if rs.len == 1: int(rs[0]) else: -1

proc sameFamily(a, b: string): bool =
  ## (a font family as a text names it: "" is FreeSans)
  cmpIgnoreCase(if a.len > 0: a else: "FreeSans", if b.len > 0: b else: "FreeSans") == 0

proc findGlyph*(t: TextData; cp: int; family = ""): seq[Match] =
  ## Find/Change's Glyph search: each place character `cp` is in the text, in font `family`
  ## ("": in any font), as characters.
  var at = 0
  for sp in t.spans:
    for r in sp.text.runes:
      if int(r) == cp and (family.len == 0 or sameFamily(sp.style.family, family)):
        result.add Match(a: at, b: at + 1, groups: @[(at, at + 1)])
      inc at

proc changeGlyph*(t: var TextData; cp: int; family: string; toCp: int; toFamily = ""; toStyle = ""): int =
  ## Find/Change's Glyph search, Change All: each `cp` (in font `family`; "": any) made `toCp`,
  ## in font `toFamily` and its style `toStyle` ("": the letter's own) -- the rest of its look
  ## kept. How many changed.
  if toCp < 0: return 0
  var spans: seq[TextSpan]
  for sp in t.spans:
    if family.len > 0 and not sameFamily(sp.style.family, family):
      spans.add sp
      continue
    var st2 = sp.style
    if toFamily.len > 0: st2.family = toFamily
    if toStyle.len > 0: st2.style = toStyle
    let own = st2 != sp.style
    var run = ""
    for r in sp.text.runes:
      if int(r) == cp:
        inc result
        if own:
          if run.len > 0: spans.add TextSpan(text: run, style: sp.style)
          run = ""
          if spans.len > 0 and spans[^1].style == st2: spans[^1].text.add $Rune(toCp)
          else: spans.add TextSpan(text: $Rune(toCp), style: st2)
        else: run.add $Rune(toCp)
      else: run.add $r
    if run.len > 0: spans.add TextSpan(text: run, style: sp.style)
  if result > 0: t.spans = spans

# ---- saved queries ---------------------------------------------------------------------------------------

type
  QueryKind* = enum
    ## Find/Change's searches (its tabs).
    qkText = "Text", qkGrep = "GREP", qkGlyph = "Glyph", qkObject = "Object"
  SavedQuery* = object
    ## A Find/Change search kept by name (the Query menu): what it finds and changes it to.
    name*: string
    kind*: QueryKind
    what*, change*: string     ## text, GREP: the words or the pattern; Glyph: the glyphs (`glyphOf`)
    matchCase*, wholeWord*: bool
    font*, toFont*: string     ## Glyph: the fonts ("": any; the letter's own)
    extra*: JsonNode           ## Object: the formats found and changed to (the program's own), nil

const builtInQueryList = [
  ("Multiple Space to Single Space", qkGrep, " {2,}", " "),
  ("Multiple Return to Single Return", qkGrep, "\\n{2,}", "\\n"),
  ("Remove Trailing Whitespace", qkGrep, "[ \\t]+$", ""),
  ("Remove Leading Whitespace", qkGrep, "^[ \\t]+", ""),
  ("Dash to En Dash (between numbers)", qkGrep, "(\\d) ?- ?(\\d)", "$1\u2013$2"),
  ("Straight Quotes to Typographer's", qkGrep, "\"([^\"\\n]*)\"", "\u201C$1\u201D"),
  ("Phone Number Conversion", qkGrep, "\\(?(\\d\\d\\d)\\)?[-. ]?(\\d\\d\\d)[-. ]?(\\d\\d\\d\\d)", "$1.$2.$3"),
  ("Remove Tatweel (Kashida)", qkGrep, "\u0640+", ""),
  ("Latin Comma to Arabic Comma (after Arabic)", qkGrep, "([\u0600-\u06FF]),", "$1\u060C"),
  ("Latin Question Mark to Arabic (after Arabic)", qkGrep, "([\u0600-\u06FF]) ?\\?", "$1\u061F")]

proc builtInQueries*(): seq[SavedQuery] =
  ## The queries Find/Change comes with: spaces and returns made single, whitespace at the lines'
  ## ends taken away, dashes, quotes, phone numbers -- and Arabic's: tatweel taken away, its comma
  ## and question mark.
  for (n, k, w, c) in builtInQueryList:
    result.add SavedQuery(name: n, kind: k, what: w, change: c)

proc queriesToJson*(qs: seq[SavedQuery]): JsonNode =
  ## Saved queries as JSON (kept with the program's settings).
  result = newJArray()
  for q in qs:
    var o = %*{"name": q.name, "kind": $q.kind, "what": q.what, "change": q.change}
    if q.matchCase: o["matchCase"] = %true
    if q.wholeWord: o["wholeWord"] = %true
    if q.font.len > 0: o["font"] = %q.font
    if q.toFont.len > 0: o["toFont"] = %q.toFont
    if q.extra != nil: o["extra"] = q.extra
    result.add o

proc queriesFrom*(j: JsonNode): seq[SavedQuery] =
  ## Saved queries from their JSON (`queriesToJson`); what cannot be read left out.
  if j == nil or j.kind != JArray: return
  for o in j.elems:
    if o.kind != JObject or o{"name"}.getStr.len == 0: continue
    var q = SavedQuery(name: o{"name"}.getStr, what: o{"what"}.getStr, change: o{"change"}.getStr,
                       matchCase: o{"matchCase"}.getBool, wholeWord: o{"wholeWord"}.getBool,
                       font: o{"font"}.getStr, toFont: o{"toFont"}.getStr, extra: o{"extra"})
    for k in QueryKind:
      if o{"kind"}.getStr == $k: q.kind = k
    if result.len < 500: result.add q

proc grepMatches(pattern: string; cps: seq[int]): seq[(int, int)] =
  ## (where a GREP style's pattern matches in a paragraph: `textengine.grepHook`)
  let p = try: compilePattern(pattern) except CatchableError: return
  var at = 0
  while at <= cps.len:
    let m = p.find(cps, at)
    if m.a < 0: break
    result.add (m.a, m.b)
    at = if m.b > m.a: m.b else: m.a + 1

grepHook = grepMatches
