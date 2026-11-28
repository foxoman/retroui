## NIF, Nim's own interchange format (Nim 2.4's compiler writes its intermediate code in it), as
## the kit's way to keep an app's state: readable text, one tree of `(tag ...)`, quick to write and
## to read back. `toNif` turns a value -- numbers, strings, enums, objects, tuples, seqs, arrays,
## tables, sets, options, the persistent collections of retroui/persist -- into NIF text,
## `fromNif` makes the value again; `saveNif` and `loadNif` do it with a file (written whole to
## a new file, then put in its place: a crash leaves the old one). The text starts with the
## `(.nif27)` header Nim's own reader (nifreader) expects.
##
## ```nim
## type Song = object
##   title: string
##   seconds: int
## var queue = @[Song(title: "Intro", seconds: 74)]
## saveNif(dataDir() / "queue.nif", queue)
## queue = loadNif(dataDir() / "queue.nif", seq[Song])
## ```
##
## Objects are written field by field, `(Song (title "Intro") (seconds 74))`; a field missing
## from the file (an older version of the app) keeps its default, one the type no longer has is
## left out. Refs are written as what they point at (no cycles); case objects with their
## discriminator first.
##
## Developed by Sultan Al Isaiee @foxoman -- www.foxoman.net -- sultan@foxoman.net

import std/[strutils, tables, sets, options, os, parseutils, math]

type
  NifKind* = enum
    ## A node of NIF read back (`parseNif`).
    nifTree,     ## `(tag kids...)`
    nifIdent,    ## a bare word: `true`, an enum's name
    nifStr,      ## `"text"`
    nifInt,      ## `-12`
    nifUInt,     ## `12u`
    nifFloat,    ## `1.5`, `2.0E-3`
    nifChar,     ## `'a'`
    nifEmpty     ## `.`

  NifNode* = object
    ## A node of NIF read back.
    case kind*: NifKind
    of nifTree:
      tag*: string
      kids*: seq[NifNode]
    of nifIdent, nifStr: s*: string
    of nifInt: i*: int64
    of nifUInt: u*: uint64
    of nifFloat: f*: float
    of nifChar: c*: char
    of nifEmpty: discard

  NifError* = object of ValueError
    ## NIF that can't be read, or isn't the type asked for.

const ControlChars = {'(', ')', '[', ']', '{', '}', '~', '#', '\'', '"', '\\', ':', '@'}

# ---- writing ------------------------------------------------------------------------------------

type NifWriter* = object
  ## NIF being written (`toNif` uses one).
  s*: string
  depth: int
  first: bool          # (nothing in the tree open yet: no space before what comes)

proc sep(w: var NifWriter) {.inline.} =
  if not w.first: w.s.add ' '
  w.first = false

proc escapeTo(w: var NifWriter; c: char) =
  const Hex = "0123456789ABCDEF"
  w.s.add '\\'
  w.s.add Hex[(ord(c) shr 4) and 15]
  w.s.add Hex[ord(c) and 15]

proc open*(w: var NifWriter; tag: string) =
  ## Starts a tree `(tag`; close it with `close`.
  if w.depth > 0:
    w.s.add '\n'
    for i in 0 ..< w.depth: w.s.add ' '
  w.s.add '('
  w.s.add tag
  inc w.depth
  w.first = false

proc close*(w: var NifWriter) =
  ## Ends the tree `open` started.
  w.s.add ')'
  dec w.depth
  w.first = false

proc identLit*(w: var NifWriter; s: string) =
  ## A bare word (an enum's name, `true`).
  w.sep
  for i, c in s:
    if c < ' ' or c in ControlChars or (i == 0 and c in {'.', '0'..'9', '+', '-', '~'}) or c == ' ':
      w.escapeTo c
    else: w.s.add c

proc strLit*(w: var NifWriter; s: string) =
  ## A string literal.
  w.sep
  w.s.add '"'
  for c in s:
    if c < ' ' or c in ControlChars: w.escapeTo c
    else: w.s.add c
  w.s.add '"'

proc intLit*(w: var NifWriter; i: int64) =
  ## A signed integer.
  w.sep
  w.s.addInt i

proc uintLit*(w: var NifWriter; u: uint64) =
  ## An unsigned integer (`12u`).
  w.sep
  w.s.add $u
  w.s.add 'u'

proc floatLit*(w: var NifWriter; f: float) =
  ## A float: `(inf)`, `(neginf)`, `(nan)` for those.
  case classify(f)
  of fcInf: (w.open("inf"); w.close())
  of fcNegInf: (w.open("neginf"); w.close())
  of fcNan: (w.open("nan"); w.close())
  else:
    w.sep
    var t = ""
    t.addFloat f
    if '.' notin t and 'e' notin t and 'E' notin t and 'n' notin t: t.add ".0"
    w.s.add t.replace('e', 'E')

proc charLit*(w: var NifWriter; c: char) =
  ## A character literal.
  w.sep
  w.s.add '\''
  if c < ' ' or c in ControlChars: w.escapeTo c
  else: w.s.add c
  w.s.add '\''

proc emptyLit*(w: var NifWriter) =
  ## `.`: nothing (a nil ref, `none`).
  w.sep
  w.s.add '.'

# ---- reading ------------------------------------------------------------------------------------

proc fail(msg: string) {.noreturn.} = raise newException(NifError, msg)

proc unhex(c: char): int =
  case c
  of '0'..'9': ord(c) - ord('0')
  of 'A'..'F': ord(c) - ord('A') + 10
  of 'a'..'f': ord(c) - ord('a') + 10
  else: fail("NIF: a bad escape")

proc parseNif*(s: string): NifNode =
  ## The tree of NIF text `s` (its `(.nif27)` header and other directives skipped): the first
  ## tree after them, or the one atom.
  var i = 0
  proc skip() =
    while i < s.len:
      if s[i] in {' ', '\t', '\n', '\r'}: inc i
      elif s[i] == '#':            # (a comment, to the line's end)
        while i < s.len and s[i] != '\n': inc i
      else: break
  proc readEsc(): char =
    if i + 2 >= s.len: fail("NIF: a cut escape")
    result = chr(unhex(s[i + 1]) * 16 + unhex(s[i + 2]))
    i += 3
  proc node(): NifNode =
    skip()
    if i >= s.len: fail("NIF: ends too soon")
    let c = s[i]
    case c
    of '(':
      inc i
      var tag = ""
      while i < s.len and s[i] notin {' ', '\t', '\n', '\r', '(', ')'}:
        if s[i] == '\\': tag.add readEsc()
        else:
          tag.add s[i]
          inc i
      result = NifNode(kind: nifTree, tag: tag)
      while true:
        skip()
        if i >= s.len: fail("NIF: a tree not closed")
        if s[i] == ')':
          inc i
          break
        result.kids.add node()
    of '"':
      inc i
      var t = ""
      while i < s.len and s[i] != '"':
        if s[i] == '\\': t.add readEsc()
        else:
          t.add s[i]
          inc i
      if i >= s.len: fail("NIF: a string not closed")
      inc i
      result = NifNode(kind: nifStr, s: t)
    of '\'':
      inc i
      var ch: char
      if i < s.len and s[i] == '\\': ch = readEsc()
      elif i < s.len:
        ch = s[i]
        inc i
      if i >= s.len or s[i] != '\'': fail("NIF: a character not closed")
      inc i
      result = NifNode(kind: nifChar, c: ch)
    of '.':
      if i + 1 < s.len and s[i + 1] in {'0'..'9'}: fail("NIF: a number can't start with '.'")
      inc i
      result = NifNode(kind: nifEmpty)
    of '-', '+', '0'..'9':
      var j = i
      if s[j] in {'-', '+'}: inc j
      while j < s.len and s[j] in {'0'..'9', '.', 'E', 'e', '-', '+'}:
        if s[j] in {'-', '+'} and s[j - 1] notin {'E', 'e'}: break
        inc j
      let t = s[i ..< j]
      if j < s.len and s[j] == 'u':
        var u: uint64
        if parseBiggestUInt(t, u) != t.len: fail("NIF: a bad number")
        result = NifNode(kind: nifUInt, u: u)
        inc j
      elif '.' in t or 'E' in t or 'e' in t:
        var f: float
        if parseFloat(t, f) != t.len: fail("NIF: a bad number")
        result = NifNode(kind: nifFloat, f: f)
      else:
        var n: BiggestInt
        if parseBiggestInt(t, n) != t.len: fail("NIF: a bad number")
        result = NifNode(kind: nifInt, i: n)
      # (a line-info suffix -- @... -- is skipped)
      while j < s.len and s[j] notin {' ', '\t', '\n', '\r', '(', ')'}: inc j
      i = j
    of ')': fail("NIF: a ')' with no tree open")
    else:
      var t = ""
      while i < s.len and s[i] notin {' ', '\t', '\n', '\r', '(', ')'}:
        if s[i] == '\\': t.add readEsc()
        else:
          t.add s[i]
          inc i
      result = NifNode(kind: nifIdent, s: t)
  while true:
    let n = node()
    if n.kind == nifTree and n.tag.len > 0 and n.tag[0] == '.': continue   # (directives)
    return n

# ---- values to NIF and back ---------------------------------------------------------------------

proc writeNif*[T](w: var NifWriter; v: T) =
  ## `v` written to `w` as NIF (see `toNif`).
  mixin writeNifOf
  when T is bool: w.identLit(if v: "true" else: "false")
  elif T is enum: w.identLit($v)
  elif T is SomeSignedInt: w.intLit(int64(v))
  elif T is SomeUnsignedInt: w.uintLit(uint64(v))
  elif T is SomeFloat: w.floatLit(float(v))
  elif T is char: w.charLit(v)
  elif T is string: w.strLit(v)
  elif T is cstring: w.strLit($v)
  elif T is Option:
    if v.isSome:
      w.open("some")
      w.writeNif(v.get)
      w.close()
    else: w.emptyLit()
  elif T is ref:
    if v == nil: w.emptyLit()
    else: w.writeNif(v[])
  elif T is (seq or array):
    w.open("list")
    for x in v: w.writeNif(x)
    w.close()
  elif T is (set or HashSet or OrderedSet):
    w.open("set")
    for x in v: w.writeNif(x)
    w.close()
  elif T is (Table or OrderedTable):
    w.open("table")
    for k, x in v.pairs:
      w.open("kv")
      w.writeNif(k)
      w.writeNif(x)
      w.close()
    w.close()
  elif T is tuple:
    w.open("tuple")
    for x in v.fields: w.writeNif(x)
    w.close()
  elif compiles(writeNifOf(w, v)):
    writeNifOf(w, v)                 # (a type of its own: the persistent collections)
  elif T is object:
    w.open(($T).split({'[', ':'})[0])
    for name, x in v.fieldPairs:
      w.open(name)
      w.writeNif(x)
      w.close()
    w.close()
  else:
    {.error: "toNif: no way to write " & $T.}

proc toNif*[T](v: T; header = true): string =
  ## `v` as NIF text, headed by `(.nif27)` (`header`).
  var w = NifWriter(first: true)
  if header: w.s.add "(.nif27)\n"
  w.writeNif(v)
  w.s.add '\n'
  w.s

proc want(n: NifNode; k: NifKind; what: string) =
  if n.kind != k: fail("NIF: " & what & " expected")

proc readNif*[T](n: NifNode; v: var T) =
  ## `v` made from the NIF node `n` (see `fromNif`).
  mixin readNifOf
  when T is bool:
    n.want(nifIdent, "true or false")
    v = n.s == "true"
  elif T is enum:
    n.want(nifIdent, "a name of " & $T)
    var found = false
    for e in T:
      if $e == n.s:
        v = e
        found = true
    if not found: fail("NIF: " & n.s & " is no " & $T)
  elif T is SomeSignedInt:
    case n.kind
    of nifInt: v = T(n.i)
    of nifUInt: v = T(n.u)
    else: fail("NIF: an integer expected")
  elif T is SomeUnsignedInt:
    case n.kind
    of nifUInt: v = T(n.u)
    of nifInt: v = T(n.i)
    else: fail("NIF: an integer expected")
  elif T is SomeFloat:
    case n.kind
    of nifFloat: v = T(n.f)
    of nifInt: v = T(n.i)
    of nifTree:
      case n.tag
      of "inf": v = T(Inf)
      of "neginf": v = T(NegInf)
      of "nan": v = T(NaN)
      else: fail("NIF: a number expected")
    else: fail("NIF: a number expected")
  elif T is char:
    n.want(nifChar, "a character")
    v = n.c
  elif T is string:
    n.want(nifStr, "a string")
    v = n.s
  elif T is Option:
    if n.kind == nifEmpty: v = none(typeof(v.get))
    else:
      n.want(nifTree, "(some ...)")
      var x: typeof(v.get)
      if n.kids.len > 0: readNif(n.kids[0], x)
      v = some(x)
  elif T is ref:
    if n.kind == nifEmpty: v = nil
    else:
      new(v)
      readNif(n, v[])
  elif T is seq:
    n.want(nifTree, "(list ...)")
    v.setLen(n.kids.len)
    for i, k in n.kids: readNif(k, v[i])
  elif T is array:
    n.want(nifTree, "(list ...)")
    var i = 0
    for x in v.mitems:
      if i < n.kids.len: readNif(n.kids[i], x)
      inc i
  elif T is set:
    n.want(nifTree, "(set ...)")
    v = {}
    for k in n.kids:
      var x: typeof(for e in v: e)
      readNif(k, x)
      v.incl x
  elif T is (HashSet or OrderedSet):
    n.want(nifTree, "(set ...)")
    v.clear()
    for k in n.kids:
      var x: typeof(for e in v: e)
      readNif(k, x)
      v.incl x
  elif T is (Table or OrderedTable):
    n.want(nifTree, "(table ...)")
    v.clear()
    for kv in n.kids:
      kv.want(nifTree, "(kv key value)")
      if kv.kids.len < 2: fail("NIF: (kv key value) expected")
      var k: typeof((for kk in v.keys: kk))
      var x: typeof((for vv in v.values: vv))
      readNif(kv.kids[0], k)
      readNif(kv.kids[1], x)
      v[k] = x
  elif T is tuple:
    n.want(nifTree, "(tuple ...)")
    var i = 0
    for x in v.fields:
      if i < n.kids.len: readNif(n.kids[i], x)
      inc i
  elif compiles(readNifOf(n, v)):
    readNifOf(n, v)
  elif T is object:
    n.want(nifTree, "(" & $T & " ...)")
    for name, x in v.fieldPairs:
      for f in n.kids:
        if f.kind == nifTree and f.tag == name and f.kids.len > 0:
          readNif(f.kids[0], x)
          break
  else:
    {.error: "fromNif: no way to read " & $T.}

proc fromNif*[T](s: string; t: typedesc[T]): T =
  ## The value of type `T` NIF text `s` was made from (`toNif`); `NifError` when it can't be.
  readNif(parseNif(s), result)

proc saveNif*[T](path: string; v: T) =
  ## Writes `v` to the file `path` as NIF: whole to a new file beside it, then put in its place --
  ## a crash or a full disk leaves the old one as it was.
  let tmp = path & ".new"
  createDir(parentDir(path))
  writeFile(tmp, toNif(v))
  moveFile(tmp, path)

proc loadNif*[T](path: string; t: typedesc[T]; default: T = default(T)): T =
  ## The value kept in the NIF file `path` (`saveNif`); `default` when there is none, or it can't
  ## be read (an older app's that no longer fits).
  if not fileExists(path): return default
  try: fromNif(readFile(path), T)
  except NifError, IOError, ValueError: default
