## Retro Designer's source: the .nim file being designed, read with Nim's
## own parser, and every change the designer makes to it -- an argument
## set or taken away, a statement inserted, deleted, moved, put in a row or
## a group, a name changed, an event added. A change touches only the text
## it is about: the rest of the file (its spacing, its comments, the code
## under the buttons) stays as it was written. Every change is read again
## before it is kept; one that would not parse is refused.
##
## Developed by Sultan Al Isaiee @foxoman -- www.foxoman.net -- sultan@foxoman.net

import std/[strutils, algorithm, sequtils]
import compiler/[parser, ast, idents, options, lineinfos, llstream, pathutils]

when defined(android):
  # (Android before 9 has no glob(), which the compiler's options call: its
  #  declarations and a stand-in -- the designer never uses it)
  {.passC: "-include " & currentSourcePath().substr(0, currentSourcePath().rfind('/')) &
           "androidglob.h".}
  {.compile: "androidglob.c".}

type
  ParseError* = tuple[line, col: int; msg: string]
  Src* = ref object
    text*: string
    lineStart*: seq[int]           ## where each line starts (index 0 is line 1)
    tree*: PNode
    errors*: seq[ParseError]
    unit*: int                     ## the file's indentation step (2 when it has none)
  DesignError* = object of CatchableError
    ## A change the designer cannot make (the message says why).
  Edit* = tuple[a, b: int; text: string]   ## text[a ..< b] becomes `text`
  Lines* = tuple[first, last, indent: int; whole: bool]
    ## A statement's lines (1-based, its comments above it in), how far
    ## it is indented, and whether it has its lines to itself.

proc fail(msg: string) {.noreturn.} = raise newException(DesignError, msg)

# ---- reading -------------------------------------------------------------------------------------

proc computeLines(s: Src) =
  s.lineStart = @[0]
  for i, c in s.text:
    if c == '\n': s.lineStart.add i + 1

proc lineCount*(s: Src): int = s.lineStart.len

proc lineText*(s: Src; line: int): string =
  ## Line `line` (1-based) without its end.
  if line < 1 or line > s.lineStart.len: return ""
  let a = s.lineStart[line - 1]
  var b = if line < s.lineStart.len: s.lineStart[line] - 1 else: s.text.len
  if b > a and s.text[b - 1] == '\r': dec b
  s.text[a ..< b]

proc indentOf*(l: string): int =
  while result < l.len and l[result] == ' ': inc result

proc blank(l: string): bool = l.strip.len == 0
proc commentLine(l: string): bool = l.strip.startsWith("#")

proc parseSrc*(text: string): Src =
  ## The file read: its tree, and the errors if it does not parse.
  let s = Src(text: text)
  s.computeLines()
  let conf = newConfigRef()
  conf.errorMax = high(int)
  conf.writelnHook = proc (msg: string) = discard
  var errs: seq[ParseError]
  conf.structuredErrorHook = proc (config: ConfigRef; info: TLineInfo; msg: string;
                                   severity: Severity) {.gcsafe.} =
    if severity == Severity.Error: errs.add (int(info.line), int(info.col), msg)
  let cache = newIdentCache()
  var p: Parser
  openParser(p, AbsoluteFile("designed.nim"), llStreamOpen(text), cache, conf)
  s.tree = parseAll(p)
  closeParser(p)
  s.errors = errs
  # (the indentation step: the smallest one the file uses)
  var unit = 0
  for i in 1 .. s.lineCount:
    let l = s.lineText(i)
    if l.blank: continue
    let ind = l.indentOf
    if ind > 0 and (unit == 0 or ind < unit): unit = ind
  s.unit = if unit in 1 .. 8: unit else: 2
  s

proc ok*(s: Src): bool = s.errors.len == 0

# ---- tokens --------------------------------------------------------------------------------------

const
  IdStart = {'a'..'z', 'A'..'Z', '_', '\x80'..'\xFF'}
  IdChars = IdStart + {'0'..'9'}
  OpChars = {'+', '-', '*', '/', '\\', '<', '>', '!', '?', '^', '.', '|', '=', '%', '&',
             '$', '@', '~', ':'}

proc strEnd(t: string; i: int; raw: bool): int =
  ## After the string literal whose quote is at `i`.
  if i + 2 < t.len and t[i + 1] == '"' and t[i + 2] == '"':
    var k = i + 3
    while k + 2 < t.len:
      if t[k] == '"' and t[k + 1] == '"' and t[k + 2] == '"':
        k += 3
        while k < t.len and t[k] == '"': inc k
        return k
      inc k
    return t.len
  var k = i + 1
  while k < t.len:
    let c = t[k]
    if c == '\\' and not raw: k += 2
    elif c == '"':
      if raw and k + 1 < t.len and t[k + 1] == '"': k += 2
      else: return k + 1
    elif c == '\n': return k
    else: inc k
  t.len

proc tokenEnd*(t: string; i: int): int =
  ## After the token that starts at `i`.
  if i >= t.len: return t.len
  let c = t[i]
  var j = i
  if c in IdStart:
    while j < t.len and t[j] in IdChars: inc j
    if j < t.len and t[j] == '"': return strEnd(t, j, true)
    return j
  if c == '"': return strEnd(t, i, false)
  if c == '\'':
    j = i + 1
    if j < t.len and t[j] == '\\': j += 2
    else: inc j
    while j < t.len and t[j] != '\'' and t[j] != '\n': inc j
    return min(t.len, j + 1)
  if c in {'0'..'9'}:
    while j < t.len:
      if t[j] in IdChars or t[j] == '\'': inc j
      elif t[j] == '.' and j + 1 < t.len and t[j + 1] in {'0'..'9'}: inc j
      elif t[j] in {'+', '-'} and t[j - 1] in {'e', 'E'} and not t[i .. j].startsWith("0x"): inc j
      else: break
    return j
  if c == '`':
    j = i + 1
    while j < t.len and t[j] != '`': inc j
    return min(t.len, j + 1)
  if c in {'(', ')', '[', ']', '{', '}', ',', ';'}: return i + 1
  if c in OpChars:
    while j < t.len and t[j] in OpChars: inc j
    return j
  i + 1

proc skipTrivia*(t: string; i: int; lines = true): int =
  ## After the spaces (and line ends, with `lines`) and comments from `i`.
  var k = i
  while k < t.len:
    let c = t[k]
    if c == ' ' or c == '\t' or c == '\r' or (lines and c == '\n'): inc k
    elif c == '#':
      if k + 1 < t.len and t[k + 1] == '[':
        var depth = 0
        while k < t.len:
          if t[k] == '#' and k + 1 < t.len and t[k + 1] == '[':
            inc depth
            k += 2
          elif t[k] == ']' and k + 1 < t.len and t[k + 1] == '#':
            dec depth
            k += 2
            if depth == 0: break
          else: inc k
      else:
        while k < t.len and t[k] != '\n': inc k
    else: break
  k

proc nextToken(t: string; i: int): tuple[a, b: int] =
  let a = skipTrivia(t, i)
  (a, tokenEnd(t, a))

# ---- where a node is -----------------------------------------------------------------------------

proc off*(s: Src; info: TLineInfo): int =
  let l = int(info.line)
  if l < 1 or l > s.lineStart.len: return -1
  s.lineStart[l - 1] + int(info.col)

proc lineOf*(s: Src; offset: int): int =
  ## The line (1-based) of a place in the text.
  var lo = 0
  var hi = s.lineStart.high
  while lo < hi:
    let mid = (lo + hi + 1) div 2
    if s.lineStart[mid] <= offset: lo = mid else: hi = mid - 1
  lo + 1

proc nodeStart(s: Src; n: PNode): int =
  result = high(int)
  if n == nil: return -1
  if n.kind != nkEmpty and n.info.line > 0:
    result = s.off(n.info)
  for i in 0 ..< n.safeLen:
    let c = s.nodeStart(n[i])
    if c >= 0 and c < result: result = c
  if result == high(int): result = -1

const StmtKinds = {nkForStmt, nkWhileStmt, nkIfStmt, nkWhenStmt, nkCaseStmt, nkTryStmt,
                   nkBlockStmt, nkStaticStmt, nkDiscardStmt, nkReturnStmt, nkRaiseStmt,
                   nkYieldStmt, nkBreakStmt, nkContinueStmt, nkVarSection, nkLetSection,
                   nkConstSection, nkTypeSection, nkProcDef, nkFuncDef, nkIteratorDef,
                   nkTemplateDef, nkMacroDef, nkMethodDef, nkConverterDef, nkDefer,
                   nkImportStmt, nkFromStmt, nkIncludeStmt, nkExportStmt, nkAsmStmt,
                   nkUsingStmt, nkMixinStmt, nkBindStmt, nkPragmaBlock}

proc startOff*(s: Src; n: PNode): int =
  ## Where `n`'s text starts (a statement's keyword in: `for`, `if`).
  result = s.nodeStart(n)
  if result < 0 or n.kind notin StmtKinds: return
  # (the keyword before the first node, on its line: `for i in x`)
  var k = result
  while k > 0 and s.text[k - 1] == ' ': dec k
  var w = k
  while w > 0 and s.text[w - 1] in IdChars: dec w
  if w < k:
    var b = w
    while b > 0 and s.text[b - 1] == ' ': dec b
    if b == 0 or s.text[b - 1] == '\n': return w
    # (`proc name*` and the like: two words)
    var w2 = b
    while w2 > 0 and s.text[w2 - 1] in IdChars: dec w2
    if w2 < b and (w2 == 0 or s.text[w2 - 1] in {' ', '\n'}):
      var b2 = w2
      while b2 > 0 and s.text[b2 - 1] == ' ': dec b2
      if b2 == 0 or s.text[b2 - 1] == '\n': return w2

proc rawEnd(s: Src; n: PNode): int =
  result = -1
  if n == nil or n.kind == nkEmpty: return
  if n.info.line > 0:
    let o = s.off(n.info)
    if o >= 0:
      # (a negative number is one token: `-1`)
      if n.kind in {nkCharLit..nkFloat128Lit} and o + 1 < s.text.len and s.text[o] == '-':
        result = tokenEnd(s.text, o + 1)
      else: result = tokenEnd(s.text, o)
  for i in 0 ..< n.safeLen:
    result = max(result, s.rawEnd(n[i]))

proc endOff*(s: Src; n: PNode): int =
  ## Where `n`'s text ends (its closing brackets in).
  let a = s.nodeStart(n)
  var b = s.rawEnd(n)
  if a < 0 or b < 0: return b
  var depth = 0
  var k = a
  while k < b:
    k = skipTrivia(s.text, k)
    if k >= b: break
    let e = tokenEnd(s.text, k)
    case s.text[k]
    of '(', '[', '{': inc depth
    of ')', ']', '}': dec depth
    else: discard
    k = e
  while depth > 0:
    let (ta, tb) = nextToken(s.text, b)
    if ta >= s.text.len: break
    case s.text[ta]
    of ')', ']', '}': dec depth
    of '(', '[', '{': inc depth
    else: discard
    b = tb
  b

proc span*(s: Src; n: PNode): tuple[a, b: int] = (s.startOff(n), s.endOff(n))
proc textOf*(s: Src; n: PNode): string =
  let (a, b) = s.span(n)
  if a < 0 or b < a: "" else: s.text[a ..< b]

proc lineOfNode*(s: Src; n: PNode): int =
  let a = s.startOff(n)
  if a < 0: 0 else: s.lineOf(a)

proc stmtLines*(s: Src; n: PNode; withComments = true): Lines =
  ## The lines statement `n` takes: from its comments above it to its last
  ## line (and the comments that end its body).
  let a = s.startOff(n)
  let b = s.endOff(n)
  if a < 0: return (0, 0, 0, false)
  var first = s.lineOf(a)
  var last = s.lineOf(max(a, b - 1))
  let ind = a - s.lineStart[first - 1]
  var whole = s.lineText(first)[0 ..< ind].blank
  let rest = s.lineText(last)
  let restStart = b - s.lineStart[last - 1]
  if restStart < rest.len:
    let tail = rest[restStart .. ^1].strip
    if tail.len > 0 and not tail.startsWith("#"): whole = false
  if whole and withComments:
    # (its own comments above it; a `##` is the doc comment of the body it
    #  is in, which stays)
    while first > 1:
      let l = s.lineText(first - 1)
      if l.commentLine and l.indentOf == ind and not l.strip.startsWith("##"): dec first
      else: break
    var k = last + 1
    while k <= s.lineCount:
      let l = s.lineText(k)
      if l.blank:
        # (a blank line, then more of this body's comments)
        var m = k + 1
        while m <= s.lineCount and s.lineText(m).blank: inc m
        if m <= s.lineCount and s.lineText(m).commentLine and s.lineText(m).indentOf > ind:
          k = m
          continue
        break
      if l.commentLine and l.indentOf > ind:
        last = k
        inc k
      else: break
  (first, last, ind, whole)

# ---- changing the text ---------------------------------------------------------------------------

proc apply*(text: string; edits: openArray[Edit]): string =
  ## The text with the edits made (they must not overlap).
  var es = @edits
  es.sort(proc (x, y: Edit): int = cmp(y.a, x.a))
  result = text
  for e in es:
    result = result[0 ..< e.a] & e.text & result[e.b .. ^1]

proc lineSpan(s: Src; first, last: int): tuple[a, b: int] =
  ## The text of lines first..last with their line ends.
  let a = s.lineStart[first - 1]
  let b = if last < s.lineCount: s.lineStart[last] else: s.text.len
  (a, b)

proc tripleStringLines(s: Src): seq[bool] =
  ## For each line: inside a """ string (not to be indented again).
  result = newSeq[bool](s.lineCount + 1)
  var k = 0
  let t = s.text
  while k < t.len:
    let c = t[k]
    if c == '#': k = skipTrivia(t, k, false)
    elif c == '"' or (c in IdStart):
      let e = tokenEnd(t, k)
      if e > k + 6 and t[e - 1] == '"' and t.find("\"\"\"", k) in k ..< e:
        let l1 = s.lineOf(k)
        let l2 = s.lineOf(e - 1)
        for l in l1 + 1 .. l2: result[l] = true
      k = max(e, k + 1)
    elif c == '\'': k = tokenEnd(t, k)
    else: inc k

proc reindent(lines: seq[string]; delta: int; keep: seq[bool] = @[]): seq[string] =
  for i, l in lines:
    if i < keep.len and keep[i]: result.add l
    elif l.blank: result.add ""
    elif delta >= 0: result.add repeat(' ', delta) & l
    else: result.add l[min(-delta, l.indentOf) .. ^1]

proc blockOf(s: Src; ln: Lines): seq[string] =
  for i in ln.first .. ln.last: result.add s.lineText(i)

proc keepOf(s: Src; ln: Lines): seq[bool] =
  let t = s.tripleStringLines
  for i in ln.first .. ln.last: result.add t[i]

proc codeLines(code: string; indent: int): seq[string] =
  ## Code written at column 0 (as the Widget Box has it), at `indent`.
  var ls = code.strip(leading = false).split('\n')
  while ls.len > 0 and ls[0].blank: ls.delete(0)
  var m = high(int)
  for l in ls:
    if not l.blank: m = min(m, l.indentOf)
  if m == high(int): m = 0
  for l in ls:
    result.add(if l.blank: "" else: repeat(' ', indent) & l[m .. ^1])

proc joinLines(ls: seq[string]): string = ls.join("\n") & "\n"

# ---- bodies (statement lists) --------------------------------------------------------------------

proc bodyOf*(n: PNode): PNode =
  ## The statements under `n` (a call with a body, a branch), else nil.
  if n == nil: return nil
  case n.kind
  of nkCall, nkCommand:
    if n.len > 1 and n[^1].kind == nkStmtList: return n[^1]
    if n.len > 1 and n[^1].kind == nkDo and n[^1].len > 0: return n[^1][^1]
  of nkElifBranch, nkElse, nkOfBranch, nkElifExpr, nkElseExpr, nkWhileStmt, nkForStmt,
     nkBlockStmt, nkWhenStmt:
    if n.len > 0: return n[^1]
  of nkProcDef, nkFuncDef, nkTemplateDef, nkMethodDef:
    if n.len > bodyPos: return n[bodyPos]
  else: discard
  nil

proc stmts*(list: PNode): seq[PNode] =
  ## The statements of a body (one statement when it is not a list).
  if list == nil: return
  if list.kind in {nkStmtList, nkStmtListExpr}:
    for c in list:
      if c.kind != nkEmpty: result.add c
  else: result.add list

proc bodyIndent(s: Src; list: PNode; owner: PNode): int =
  let its = list.stmts
  if its.len > 0:
    let ln = s.stmtLines(its[0], false)
    if ln.whole: return ln.indent
  s.stmtLines(owner, false).indent + s.unit

proc inlineBody*(s: Src; list: PNode): bool =
  ## The body is on its owner's line (`if x: quitApp()`).
  let its = list.stmts
  its.len > 0 and not s.stmtLines(its[0], false).whole

proc splitInline*(s: Src; list: PNode; owner: PNode): string =
  ## The text with an inline body put on its own lines.
  let its = list.stmts
  if its.len == 0: return s.text
  let a = s.startOff(its[0])
  let ind = s.stmtLines(owner, false).indent + s.unit
  var k = a
  while k > 0 and s.text[k - 1] == ' ': dec k
  apply(s.text, [(k, a, "\n" & repeat(' ', ind))])

proc onlyDiscard(list: PNode): bool =
  let its = list.stmts
  its.len == 1 and its[0].kind == nkDiscardStmt and (its[0].len == 0 or its[0][0].kind == nkEmpty)

# ---- statements: insert, delete, move, wrap, unwrap ----------------------------------------------

proc insertAt*(s: Src; list, owner: PNode; index: int; code: string): string =
  ## `code` (written at column 0) inserted as statement `index` of the body.
  if s.inlineBody(list): fail "the body is on one line with its owner"
  let its = list.stmts
  let ind = s.bodyIndent(list, owner)
  let ls = codeLines(code, ind)
  if onlyDiscard(list):
    let ln = s.stmtLines(its[0], false)
    let (a, b) = s.lineSpan(ln.first, ln.last)
    return apply(s.text, [(a, b, ls.joinLines)])
  if index < its.len:
    let ln = s.stmtLines(its[index])
    let a = s.lineStart[ln.first - 1]
    return apply(s.text, [(a, a, ls.joinLines)])
  let ln = s.stmtLines(its[^1])
  let (_, b) = s.lineSpan(ln.first, ln.last)
  var pre = ""
  if b > 0 and s.text[b - 1] != '\n': pre = "\n"
  apply(s.text, [(b, b, pre & ls.joinLines)])

proc deleteStmt*(s: Src; n: PNode; list: PNode): string =
  ## Statement `n` taken away (the last of a body becomes `discard`).
  let ln = s.stmtLines(n)
  if not ln.whole: fail "it shares its line with other code"
  let (a, b) = s.lineSpan(ln.first, ln.last)
  var others = 0
  for x in list.stmts:
    if x != n and x.kind != nkCommentStmt: inc others
  if list != nil and others == 0:
    return apply(s.text, [(a, b, repeat(' ', ln.indent) & "discard\n")])
  apply(s.text, [(a, b, "")])

proc writeTabIndexes*(s: Src; drop: openArray[PNode]; add: openArray[tuple[n: PNode; k: int]]): string =
  ## The statements `drop` (the `tabIndex` lines there were) taken away and
  ## `tabIndex k` written before each statement of `add`, in one change.
  var edits: seq[Edit]
  for n in drop:
    let ln = s.stmtLines(n, false)
    if not ln.whole: fail "a tabIndex shares its line with other code (line " & $ln.first & ")"
    let (a, b) = s.lineSpan(ln.first, ln.last)
    edits.add (a, b, "")
  for (n, k) in add:
    let ln = s.stmtLines(n)
    if not ln.whole: fail "a control shares its line with other code (line " & $ln.first & ")"
    let a = s.lineStart[ln.first - 1]
    edits.add (a, a, repeat(' ', ln.indent) & "tabIndex " & $k & "\n")
  apply(s.text, edits)

proc stmtText*(s: Src; n: PNode): string =
  ## Statement `n`'s lines (its comments in) at column 0.
  let ln = s.stmtLines(n)
  if not ln.whole: fail "it shares its line with other code"
  reindent(s.blockOf(ln), -ln.indent, s.keepOf(ln)).joinLines

proc moveStmt*(s: Src; n, fromList: PNode; toList, toOwner: PNode; index: int): string =
  ## Statement `n` moved to `index` of another body (or the same one).
  let ln = s.stmtLines(n)
  if not ln.whole: fail "it shares its line with other code"
  if s.inlineBody(toList): fail "the body is on one line with its owner"
  # (not into itself)
  let (na, nb) = s.span(n)
  let (ta, _) = s.span(toList)
  if toList != fromList and ta >= na and ta < nb: fail "a control cannot go inside itself"
  let code = reindent(s.blockOf(ln), -ln.indent, s.keepOf(ln))
  let tIts = toList.stmts
  let ind = s.bodyIndent(toList, toOwner)
  let moved = reindent(code, ind, s.keepOf(ln)).joinLines
  var edits: seq[Edit]
  let (a, b) = s.lineSpan(ln.first, ln.last)
  let srcOnly = fromList != nil and fromList != toList and
                fromList.stmts.countIt(it != n and it.kind != nkCommentStmt) == 0
  edits.add (a, b, if srcOnly: repeat(' ', ln.indent) & "discard\n" else: "")
  if onlyDiscard(toList):
    let dl = s.stmtLines(tIts[0], false)
    let (da, db) = s.lineSpan(dl.first, dl.last)
    edits.add (da, db, moved)
  elif index < tIts.len:
    let tl = s.stmtLines(tIts[index])
    let at = s.lineStart[tl.first - 1]
    if at > a and at < b: fail "it is already there"
    edits.add (at, at, moved)
  else:
    let tl = s.stmtLines(tIts[^1])
    let (_, at) = s.lineSpan(tl.first, tl.last)
    if at > a and at < b: fail "it is already there"
    var pre = ""
    if at > 0 and s.text[at - 1] != '\n': pre = "\n"
    edits.add (at, at, pre & moved)
  apply(s.text, edits)

proc wrapStmts*(s: Src; nodes: seq[PNode]; header: string): string =
  ## The statements (siblings, in order) put under a new `header` line
  ## (`row:`, `group "Group":`).
  if nodes.len == 0: fail "nothing chosen"
  let l1 = s.stmtLines(nodes[0])
  let l2 = s.stmtLines(nodes[^1])
  if not l1.whole or not l2.whole: fail "it shares its line with other code"
  let all: Lines = (l1.first, l2.last, l1.indent, true)
  let body = reindent(s.blockOf(all), s.unit, s.keepOf(all))
  let (a, b) = s.lineSpan(all.first, all.last)
  apply(s.text, [(a, b, (@[repeat(' ', l1.indent) & header] & body).joinLines)])

proc unwrap*(s: Src; n: PNode): string =
  ## A container's statements put where it was, without it.
  let body = n.bodyOf
  if body == nil: fail "it has nothing inside"
  if s.inlineBody(body): fail "the body is on one line with its owner"
  let ln = s.stmtLines(n)
  if not ln.whole: fail "it shares its line with other code"
  let its = body.stmts
  let b1 = s.stmtLines(its[0])
  let b2 = s.stmtLines(its[^1])
  let inner: Lines = (b1.first, b2.last, b1.indent, true)
  let code = reindent(s.blockOf(inner), ln.indent - b1.indent, s.keepOf(inner))
  var keep = code
  if onlyDiscard(body): keep = @[]
  let (a, b) = s.lineSpan(ln.first, ln.last)
  # (the container's own comments above it stay)
  var head: seq[string]
  let own = s.stmtLines(n, false)
  for i in ln.first ..< own.first: head.add s.lineText(i)
  apply(s.text, [(a, b, if head.len + keep.len > 0: (head & keep).joinLines else: "")])

# ---- arguments ----------------------------------------------------------------------------------

proc nimLit*(v: string): string =
  ## `v` as a Nim string literal (its letters as they are: Arabic stays Arabic).
  result = "\""
  for c in v:
    case c
    of '\\': result.add "\\\\"
    of '"': result.add "\\\""
    of '\n': result.add "\\n"
    of '\t': result.add "\\t"
    of '\r': result.add "\\r"
    elif ord(c) < 32: result.add "\\x" & toHex(ord(c), 2)
    else: result.add c
  result.add '"'

proc isCallNode*(n: PNode): bool =
  n != nil and n.kind in {nkCall, nkCommand, nkCallStrLit} and n.len > 0

proc callee*(n: PNode): string =
  ## The name called (`button` in `button("OK")`), else "".
  if n == nil: return ""
  case n.kind
  of nkIdent: n.ident.s
  of nkCall, nkCommand, nkCallStrLit:
    if n.len > 0:
      case n[0].kind
      of nkIdent: n[0].ident.s
      of nkAccQuoted: (if n[0].len > 0 and n[0][0].kind == nkIdent: n[0][0].ident.s else: "")
      else: ""
    else: ""
  else: ""

proc args*(n: PNode): seq[PNode] =
  ## A call's arguments, its body not among them.
  if not n.isCallNode: return
  for i in 1 ..< n.len:
    # (a body is a statement list; `(if a: b else: c)` is a list too, but
    #  an expression: an argument)
    if n[i].kind in {nkStmtList, nkDo}: continue
    result.add n[i]

proc namedArg*(n: PNode; name: string): PNode =
  for a in n.args:
    if a.kind == nkExprEqExpr and a[0].kind == nkIdent and
       cmpIgnoreStyle(a[0].ident.s, name) == 0: return a
  nil

proc positional*(n: PNode): seq[PNode] =
  for a in n.args:
    if a.kind != nkExprEqExpr: result.add a

proc callParens(s: Src; n: PNode): tuple[open, close: int] =
  ## Where a call's `(` and `)` are (-1: none: a command).
  if n.kind != nkCall: return (-1, -1)
  let calleeEnd = s.endOff(n[0])
  let (ta, _) = nextToken(s.text, calleeEnd)
  if ta >= s.text.len or s.text[ta] != '(': return (-1, -1)
  var depth = 0
  var k = ta
  while k < s.text.len:
    k = skipTrivia(s.text, k)
    if k >= s.text.len: break
    case s.text[k]
    of '(', '[', '{': inc depth
    of ')', ']', '}':
      dec depth
      if depth == 0: return (ta, k)
    else: discard
    k = tokenEnd(s.text, k)
  (ta, -1)

proc setArg*(s: Src; call: PNode; index: int; name, value: string; target: PNode = nil): string =
  ## Argument `name` (parameter `index`) of `call` set to `value` (Nim
  ## source text): changed where it is, else added by its name.
  var at = target
  if at == nil:
    at = call.namedArg(name)
    if at == nil:
      let pos = call.positional
      if index < pos.len: at = pos[index]
  if at != nil:
    let node = if at.kind == nkExprEqExpr: at[1] else: at
    let (a, b) = s.span(node)
    return apply(s.text, [(a, b, value)])
  let piece = name & " = " & value
  if call.kind == nkIdent:
    let (a, b) = s.span(call)
    return apply(s.text, [(a, b, s.text[a ..< b] & "(" & piece & ")")])
  let (po, pc) = s.callParens(call)
  let existing = call.args
  if po >= 0 and pc >= 0:
    return apply(s.text, [(pc, pc, (if existing.len > 0: ", " else: "") & piece)])
  if existing.len > 0:
    let b = s.endOff(existing[^1])
    return apply(s.text, [(b, b, ", " & piece)])
  # (a command or a call with only a body: `row:`)
  let b = s.endOff(call[0])
  apply(s.text, [(b, b, "(" & piece & ")")])

proc removeArg*(s: Src; call: PNode; arg: PNode): string =
  ## Argument `arg` taken out of `call` (with its comma).
  let its = call.args
  let k = its.find(arg)
  if k < 0: fail "no such argument"
  let (a, b) = s.span(arg)
  if k > 0:
    # (from the end of the one before: ", name = value")
    let pb = s.endOff(its[k - 1])
    return apply(s.text, [(pb, b, "")])
  if its.len > 1:
    let na = s.startOff(its[1])
    return apply(s.text, [(a, na, "")])
  # the only argument: `f(x)` -> `f()`; a command `label x` -> `label`
  let (po, pc) = s.callParens(call)
  if po >= 0 and pc >= 0:
    return apply(s.text, [(po + 1, pc, "")])
  let ce = s.endOff(call[0])
  apply(s.text, [(ce, b, "")])

proc asCall*(s: Src; call: PNode): string =
  ## The call's text in parentheses (`label("x", bold = true)`), whatever
  ## way the file has it.
  if call.kind == nkCall: return s.textOf(call)
  if call.kind == nkIdent: return s.textOf(call) & "()"
  var parts: seq[string]
  for a in call.args: parts.add s.textOf(a)
  s.textOf(call[0]) & "(" & parts.join(", ") & ")"

proc makeEvent*(s: Src; n: PNode; call: PNode): string =
  ## A control statement made into `if control(...):` with `discard` under
  ## it -- the place for the code its event runs.
  let ln = s.stmtLines(n, false)
  if not ln.whole: fail "it shares its line with other code"
  let (a, b) = s.span(n)
  let txt = "if " & s.asCall(call) & ":\n" & repeat(' ', ln.indent + s.unit) & "discard"
  apply(s.text, [(a, b, txt)])

proc renameIdent*(s: Src; old, new: string): string =
  ## Every use of name `old` (as Nim reads names: `my_name` is `myName`)
  ## becomes `new` -- a name, not a field of the same name: `x.old`,
  ## `T(old: 1)`, `f(old = 1)` and an object's `old: int` stay.
  var edits: seq[Edit]
  proc same(n: PNode): bool =
    n != nil and n.kind == nkIdent and cmpIgnoreStyle(n.ident.s, old) == 0 and
      (old.len == 0 or n.ident.s[0] == old[0])
  proc declares(n: PNode): bool =
    ## (a routine with a parameter, variable or loop variable named `old`:
    ##  its uses are that one's, not the file's)
    if n == nil: return false
    case n.kind
    of nkIdentDefs, nkVarTuple:
      for i in 0 ..< max(0, n.len - 2):
        var x = n[i]
        if x.kind == nkPragmaExpr: x = x[0]
        if x.kind == nkPostfix: x = x[1]
        if same(x): return true
    of nkForStmt:
      for i in 0 ..< max(0, n.len - 2):
        if same(n[i]): return true
    else: discard
    for i in 0 ..< n.safeLen:
      if declares(n[i]): return true
    false
  proc walk(n: PNode; inObject = false) =
    if n == nil: return
    if n.kind in {nkProcDef, nkFuncDef, nkMethodDef, nkIteratorDef, nkTemplateDef, nkMacroDef,
                  nkConverterDef, nkLambda, nkDo} and n.len > bodyPos and
       (declares(n[paramsPos]) or declares(n[bodyPos])):
      return
    if same(n):
      let a = s.off(n.info)
      if a >= 0: edits.add (a, tokenEnd(s.text, a), new)
      return
    case n.kind
    of nkDotExpr:
      if n.len == 2:
        walk(n[0], inObject)
        if not same(n[1]): walk(n[1], inObject)
        return
    of nkExprColonExpr, nkExprEqExpr:
      # (a label: a field's or an argument's name)
      if n.len == 2:
        if not same(n[0]): walk(n[0], inObject)
        walk(n[1], inObject)
        return
    of nkObjectTy, nkRecList:
      for i in 0 ..< n.safeLen: walk(n[i], true)
      return
    of nkIdentDefs:
      if inObject:
        # (the fields' names stay; their types and defaults are walked)
        for i in 0 ..< n.len:
          if i < n.len - 2:
            var x = n[i]
            if x.kind == nkPragmaExpr: x = x[0]
            if x.kind == nkPostfix: x = x[1]
            if same(x): continue
          walk(n[i], inObject)
        return
    else: discard
    for i in 0 ..< n.safeLen: walk(n[i], inObject)
  walk(s.tree)
  if edits.len == 0: fail "the name is not used"
  # (one place once: a node seen twice)
  edits.sort(proc (x, y: Edit): int = cmp(x.a, y.a))
  var uniq: seq[Edit]
  for e in edits:
    if uniq.len == 0 or uniq[^1].a != e.a: uniq.add e
  apply(s.text, uniq)

proc insertLinesAt*(s: Src; line: int; code: string): string =
  ## Lines inserted before line `line` (after the last line when it is past it).
  let a = if line <= s.lineCount: s.lineStart[line - 1] else: s.text.len
  var pre = ""
  if a > 0 and a == s.text.len and s.text[a - 1] != '\n': pre = "\n"
  apply(s.text, [(a, a, pre & code.strip(leading = false) & "\n")])

proc names*(s: Src): seq[string] =
  ## Every name the file uses (to make new ones that are not taken).
  proc walk(n: PNode; acc: var seq[string]) =
    if n == nil: return
    if n.kind == nkIdent: acc.add n.ident.s
    for i in 0 ..< n.safeLen: walk(n[i], acc)
  walk(s.tree, result)

proc freeName*(s: Src; base: string; taken: seq[string] = @[]): string =
  ## `base` if no name in the file is it, else `base2`, `base3`...
  let all = s.names & taken
  proc used(x: string): bool =
    for n in all:
      if cmpIgnoreStyle(n, x) == 0 and n.len > 0 and x.len > 0 and n[0] == x[0]: return true
  if not used(base): return base
  var k = 2
  while used(base & $k): inc k
  base & $k
