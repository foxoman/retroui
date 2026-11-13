## A code editor: `codeEdit(source)` -- the text in a monospaced font with
## its line numbers, the language's colors (Nim, Python, C and its kin,
## JSON, shell), indentation kept on Enter and made by Tab, comments by
## Ctrl+/, its own undo, and what `find` names shown and found (F3).
##
## .. code-block:: nim
##   var src = "proc hello() =\n  echo \"Hello\"\n"
##   var needle = ""
##   app "Script", 520, 360:
##     row([60, -1]):
##       label "&Find:"
##       edit needle
##     if codeEdit(src, lines = -1, lang = clNim, find = needle): saved = false
##
## Keys: the arrows (with Shift: a selection; with Ctrl: by words), Home
## (the line's first letter, then its start), End, Page Up and Down,
## Ctrl+Home and End; Enter (the line's indentation kept, one more after
## ":" or "{"), Tab and Shift+Tab (the lines selected moved in and out),
## Ctrl+/ (comment or uncomment them), Ctrl+A, C, X, V, Z and Y (Shift+Z),
## F3 and Shift+F3 (the next and the last `find`). A double click picks a
## word; the wheel and the scroll bars scroll.
##
## Developed by Sultan Al Isaiee @foxoman -- www.foxoman.net -- sultan@foxoman.net

import std/[strutils, tables]
import gfx, core, widgets
import uirelays/[input, access]

template th: untyped = ui.theme

type
  CodeLang* = enum
    ## How the code is colored.
    clNone = "Text"
    clNim = "Nim"
    clPython = "Python"
    clC = "C"            ## C, C++, Java, JavaScript, Go, Rust, Swift: // and /* */
    clJson = "JSON"
    clShell = "Shell"

  TokKind = enum tkText, tkKeyword, tkType, tkString, tkComment, tkNumber, tkPragma

  CodeMemo = object
    undo, redo: seq[tuple[s: string; caret: int]]
    lastEdit: int
    dragging: bool

const
  nimWords = ["addr", "and", "as", "asm", "bind", "block", "break", "case", "cast",
              "concept", "const", "continue", "converter", "defer", "discard", "distinct",
              "div", "do", "elif", "else", "end", "enum", "except", "export", "finally",
              "for", "from", "func", "if", "import", "in", "include", "interface", "is",
              "isnot", "iterator", "let", "macro", "method", "mixin", "mod", "nil", "not",
              "notin", "object", "of", "or", "out", "proc", "ptr", "raise", "ref", "return",
              "shl", "shr", "static", "template", "try", "tuple", "type", "using", "var",
              "when", "while", "xor", "yield", "true", "false", "result"]
  pyWords = ["and", "as", "assert", "async", "await", "break", "class", "continue", "def",
             "del", "elif", "else", "except", "finally", "for", "from", "global", "if",
             "import", "in", "is", "lambda", "nonlocal", "not", "or", "pass", "raise",
             "return", "try", "while", "with", "yield", "True", "False", "None", "self"]
  cWords = ["auto", "break", "case", "catch", "char", "class", "const", "continue",
            "default", "delete", "do", "double", "else", "enum", "extern", "false", "float",
            "for", "func", "function", "go", "if", "import", "int", "interface", "let",
            "long", "new", "null", "nullptr", "package", "private", "protected", "public",
            "return", "short", "signed", "static", "struct", "switch", "this", "throw",
            "true", "try", "typedef", "union", "unsigned", "var", "void", "volatile",
            "while", "fn", "impl", "mut", "pub", "use", "match", "const", "export"]
  shWords = ["if", "then", "else", "elif", "fi", "for", "while", "do", "done", "case",
             "esac", "in", "function", "return", "export", "local", "echo", "exit", "set"]

var memos: Table[Id, CodeMemo]

proc wordsOf(lang: CodeLang): seq[string] =
  case lang
  of clNim: @nimWords
  of clPython: @pyWords
  of clC: @cWords
  of clShell: @shWords
  of clJson: @["true", "false", "null"]
  of clNone: @[]

proc lineComment(lang: CodeLang): string =
  case lang
  of clNim, clPython, clShell: "#"
  of clC: "//"
  else: ""

proc tokens(line: string; lang: CodeLang; inBlock: var bool):
    seq[tuple[a, b: int; k: TokKind]] =
  ## The colored parts of `line` (`inBlock`: a block comment or a long
  ## string goes on from the line before, and on to the next).
  if lang == clNone: return
  let words = wordsOf(lang)
  var i = 0
  let n = line.len
  template add(a0, b0: int; k0: TokKind) = result.add (a0, b0, k0)
  if inBlock:
    let close = case lang
                of clNim: (if line.find("\"\"\"") >= 0: "\"\"\"" else: "]#")
                of clPython: "\"\"\""
                of clC: "*/"
                else: ""
    let e = if close.len > 0: line.find(close) else: -1
    if e < 0:
      add(0, n, (if close == "\"\"\"": tkString else: tkComment))
      return
    add(0, e + close.len, (if close == "\"\"\"": tkString else: tkComment))
    i = e + close.len
    inBlock = false
  while i < n:
    let c = line[i]
    if lang == clNim and line.continuesWith("#[", i):
      let e = line.find("]#", i + 2)
      if e < 0:
        add(i, n, tkComment); inBlock = true; return
      add(i, e + 2, tkComment); i = e + 2; continue
    if lang == clC and line.continuesWith("/*", i):
      let e = line.find("*/", i + 2)
      if e < 0:
        add(i, n, tkComment); inBlock = true; return
      add(i, e + 2, tkComment); i = e + 2; continue
    let lc = lineComment(lang)
    if lc.len > 0 and line.continuesWith(lc, i):
      add(i, n, tkComment); return
    if lang in {clNim, clPython} and line.continuesWith("\"\"\"", i):
      let e = line.find("\"\"\"", i + 3)
      if e < 0:
        add(i, n, tkString); inBlock = true; return
      add(i, e + 3, tkString); i = e + 3; continue
    if lang == clNim and line.continuesWith("{.", i):
      let e = line.find(".}", i + 2)
      let b = if e < 0: n else: e + 2
      add(i, b, tkPragma); i = b; continue
    if c == '"' or (c == '\'' and lang != clNim) or (c == '\'' and i + 2 < n and line[i + 2] == '\''):
      var j = i + 1
      while j < n and line[j] != c:
        if line[j] == '\\': inc j
        inc j
      let b = min(n, j + 1)
      add(i, b, tkString); i = b; continue
    if c.isDigit and (i == 0 or line[i - 1] notin IdentChars):
      var j = i
      while j < n and (line[j] in HexDigits + {'x', 'X', '_', '.', '\''} or
                       line[j] in {'u', 'i', 'f'} and j > i): inc j
      add(i, j, tkNumber); i = j; continue
    if c in IdentStartChars:
      var j = i
      while j < n and line[j] in IdentChars: inc j
      let w = line[i ..< j]
      if w in words: add(i, j, tkKeyword)
      elif lang in {clNim, clC} and w[0].isUpperAscii: add(i, j, tkType)
      i = j
      continue
    inc i

proc tokColor(k: TokKind; dark: bool): Color =
  if dark:
    case k
    of tkKeyword: color(110, 170, 255)
    of tkType: color(80, 200, 190)
    of tkString: color(230, 160, 110)
    of tkComment: color(120, 180, 110)
    of tkNumber: color(200, 150, 240)
    of tkPragma: color(150, 150, 150)
    of tkText: th.fieldText
  else:
    case k
    of tkKeyword: color(0, 0, 160)
    of tkType: color(0, 120, 120)
    of tkString: color(160, 0, 0)
    of tkComment: color(0, 128, 0)
    of tkNumber: color(128, 0, 128)
    of tkPragma: color(110, 110, 110)
    of tkText: th.fieldText

proc lineStarts(s: string): seq[int] =
  result.add 0
  for i, c in s:
    if c == '\n': result.add i + 1

proc lineOfPos(starts: seq[int]; p: int): int =
  var lo = 0
  var hi = starts.high
  while lo < hi:
    let m = (lo + hi + 1) div 2
    if starts[m] <= p: lo = m else: hi = m - 1
  lo

proc lineText(s: string; starts: seq[int]; k: int): string =
  let a = starts[k]
  let b = if k < starts.high: starts[k + 1] - 1 else: s.len
  s[a ..< b]

proc indentOf(line: string): int =
  while result < line.len and line[result] == ' ': inc result

proc codeEdit*(s: var string; lines = 12; lang = clNim; w = 0; readOnly = false;
               lineNumbers = true; find = ""; tabSize = 2): bool {.discardable.} =
  ## A code editor bound to `s` (see the module's notes), `lines` lines
  ## high (-1: the height left); true when the text changed.
  let mono = TextStyle(mono: true)
  let lh = FontH
  let h = if lines < 0: remainingH() else: lines * lh + 6
  let r = place(if w > 0: w else: 0, h, fill = w <= 0)
  let id = idOf(s, "code")
  var st = state(id)
  var memo = memos.getOrDefault(id)
  let dark = themeIsDark(ui.theme)
  let hit = interact(id, r)
  var starts = lineStarts(s)
  let cw = max(1, textWidth("M", mono))
  let gutter = if lineNumbers: textWidth($starts.len, mono) + dp(12) else: dp(4)
  let sb = SbW
  let inner = rect(r.x + 2, r.y + 2, r.w - 4 - sb, r.h - 4)
  let textX = inner.x + gutter
  let viewW = max(1, inner.w - gutter - dp(4))
  let visLines = max(1, inner.h div lh)
  var changed = false
  var moved = false
  st.caret = clamp(st.caret, 0, s.len)
  st.anchor = clamp(st.anchor, 0, s.len)

  template caretLine(): int = lineOfPos(starts, st.caret)
  template xOfPos(p: int): int =
    (let k = lineOfPos(starts, p); textWidth(s[starts[k] ..< p], mono))
  template posAt(mx, my: int): int =
    (block:
      let k = clamp((my - inner.y + st.scrollY) div lh, 0, starts.high)
      let ln = lineText(s, starts, k)
      let want = mx - textX + st.scrollX
      var c = 0
      while c < ln.len and textWidth(ln[0 ..< c + 1], mono) - cw div 2 < want: inc c
      starts[k] + c)
  template keep(): untyped =
    if memo.undo.len == 0 or ui.now - memo.lastEdit > 1000:
      memo.undo.add (s, st.caret)
      if memo.undo.len > 200: memo.undo.delete(0)
    memo.redo.setLen(0)
    memo.lastEdit = ui.now
  template replaceRange(a, b: int; t: string) =
    if not readOnly:
      keep()
      s = s[0 ..< a] & t & s[b .. ^1]
      st.caret = a + t.len
      st.anchor = st.caret
      starts = lineStarts(s)
      changed = true
      moved = true
  template replaceSel(t: string) =
    replaceRange(min(st.caret, st.anchor), max(st.caret, st.anchor), t)
  template moveTo(p: int; sel: bool) =
    st.caret = clamp(p, 0, s.len)
    if not sel: st.anchor = st.caret
    moved = true
  template selLines(): (int, int) =
    (lineOfPos(starts, min(st.caret, st.anchor)),
     lineOfPos(starts, max(st.caret, max(st.anchor - 1, min(st.caret, st.anchor)))))
  template eachLine(k0, k1: int; body: untyped) =
    # (each line from k0 to k1 changed by `body` on `ln`; the selection kept
    # over them)
    if not readOnly:
      keep()
      var outL: seq[string]
      for k in 0 .. starts.high:
        var ln {.inject.} = lineText(s, starts, k)
        if k in k0 .. k1: body
        outL.add ln
      s = outL.join("\n")
      starts = lineStarts(s)
      st.anchor = starts[k0]
      st.caret = if k1 < starts.high: starts[k1 + 1] - 1 else: s.len
      changed = true
      moved = true

  # the mouse
  if hit.down or (ui.active == id and ui.mouseDown):
    if ui.pressed and mouseIn(inner):
      ui.focus = id
      let p = posAt(ui.mx, ui.my)
      if ui.clicks >= 2:
        var a = p
        var b = p
        while a > 0 and s[a - 1] in IdentChars: dec a
        while b < s.len and s[b] in IdentChars: inc b
        st.anchor = a
        st.caret = b
      else:
        moveTo(p, ShiftPressed in ui.mods)
      memo.dragging = true
    elif memo.dragging and ui.mouseDown:
      moveTo(posAt(ui.mx, ui.my), true)
  if not ui.mouseDown: memo.dragging = false
  if hit.hover and canInput() and ui.wheel != 0 and not ui.wheelUsed:
    ui.wheelUsed = true
    st.scrollY -= ui.wheel * lh * 3

  # the keys
  let focused = ui.focus == id
  if focused and canInput() and not ui.keyUsed:
    let shift = ShiftPressed in ui.mods
    let ctrl = CtrlPressed in ui.mods
    let a0 = min(st.caret, st.anchor)
    let b0 = max(st.caret, st.anchor)
    var used = true
    case ui.key
    of KeyLeft:
      if not shift and a0 != b0: moveTo(a0, false)
      elif ctrl:
        var p = st.caret
        while p > 0 and s[p - 1] notin IdentChars: dec p
        while p > 0 and s[p - 1] in IdentChars: dec p
        moveTo(p, shift)
      else: moveTo(st.caret - (if st.caret > 0 and (s[st.caret - 1].uint8 and 0xC0) == 0x80: 2 else: 1), shift)
    of KeyRight:
      if not shift and a0 != b0: moveTo(b0, false)
      elif ctrl:
        var p = st.caret
        while p < s.len and s[p] in IdentChars: inc p
        while p < s.len and s[p] notin IdentChars and s[p] != '\n': inc p
        moveTo(p, shift)
      else:
        var p = min(s.len, st.caret + 1)
        while p < s.len and (s[p].uint8 and 0xC0) == 0x80: inc p
        moveTo(p, shift)
    of KeyUp, KeyDown, KeyPageUp, KeyPageDown:
      let k = caretLine()
      let x = xOfPos(st.caret)
      let d = case ui.key
              of KeyUp: -1
              of KeyDown: 1
              of KeyPageUp: -visLines
              else: visLines
      let t = clamp(k + d, 0, starts.high)
      let ln = lineText(s, starts, t)
      var c = 0
      while c < ln.len and textWidth(ln[0 ..< c + 1], mono) - cw div 2 < x: inc c
      moveTo(starts[t] + c, shift)
    of KeyHome:
      if ctrl: moveTo(0, shift)
      else:
        let k = caretLine()
        let first = starts[k] + indentOf(lineText(s, starts, k))
        moveTo(if st.caret == first: starts[k] else: first, shift)
    of KeyEnd:
      if ctrl: moveTo(s.len, shift)
      else:
        let k = caretLine()
        moveTo(starts[k] + lineText(s, starts, k).len, shift)
    of KeyBackspace:
      if a0 != b0: replaceSel("")
      elif st.caret > 0:
        let k = caretLine()
        let col = st.caret - starts[k]
        let ln = lineText(s, starts, k)
        if col > 0 and indentOf(ln) >= col:
          # (in the indentation: back to the last tab stop)
          let back = ((col - 1) mod tabSize) + 1
          replaceRange(st.caret - back, st.caret, "")
        else:
          var p = st.caret - 1
          while p > 0 and (s[p].uint8 and 0xC0) == 0x80: dec p
          replaceRange(p, st.caret, "")
    of KeyDelete:
      if a0 != b0: replaceSel("")
      elif st.caret < s.len:
        var p = st.caret + 1
        while p < s.len and (s[p].uint8 and 0xC0) == 0x80: inc p
        replaceRange(st.caret, p, "")
    of KeyEnter:
      let k = caretLine()
      let ln = lineText(s, starts, k)
      var ind = indentOf(ln)
      let before = ln[0 ..< clamp(st.caret - starts[k], 0, ln.len)].strip(leading = false)
      if before.len > 0 and (before[^1] == ':' and lang in {clNim, clPython} or
                             before[^1] == '{' and lang in {clC, clJson} or
                             before.endsWith("=") and lang == clNim):
        ind += tabSize
      replaceSel("\n" & spaces(ind))
    of KeyTab:
      let (k0, k1) = selLines()
      if a0 != b0 and k1 > k0 or shift:
        if shift:
          eachLine(k0, k1):
            ln = ln[min(indentOf(ln), tabSize) .. ^1]
        else:
          eachLine(k0, k1):
            if ln.len > 0: ln = spaces(tabSize) & ln
      else:
        let col = st.caret - starts[caretLine()]
        replaceSel(spaces(tabSize - col mod tabSize))
    of KeySlash:
      if ctrl and lineComment(lang).len > 0:
        let lc = lineComment(lang)
        let (k0, k1) = selLines()
        var all = true
        for k in k0 .. k1:
          let ln = lineText(s, starts, k)
          if ln.strip.len > 0 and not ln.strip.startsWith(lc): all = false
        eachLine(k0, k1):
          let i = indentOf(ln)
          if all:
            if ln.continuesWith(lc & " ", i): ln = ln[0 ..< i] & ln[i + lc.len + 1 .. ^1]
            elif ln.continuesWith(lc, i): ln = ln[0 ..< i] & ln[i + lc.len .. ^1]
          elif ln.strip.len > 0:
            ln = ln[0 ..< i] & lc & " " & ln[i .. ^1]
      else: used = false
    of KeyA:
      if ctrl: (st.anchor = 0; st.caret = s.len)
      else: used = false
    of KeyC:
      if ctrl and a0 != b0: putClipboardText(s[a0 ..< b0])
      else: used = ctrl
    of KeyX:
      if ctrl and a0 != b0:
        putClipboardText(s[a0 ..< b0])
        replaceSel("")
      else: used = ctrl
    of KeyV:
      if ctrl: replaceSel(getClipboardText().replace("\r\n", "\n").replace("\t", spaces(tabSize)))
      else: used = false
    of KeyZ:
      if ctrl and not shift and memo.undo.len > 0 and not readOnly:
        memo.redo.add (s, st.caret)
        let u = memo.undo.pop()
        s = u.s
        moveTo(u.caret, false)
        starts = lineStarts(s)
        changed = true
        memo.lastEdit = 0
      elif ctrl and shift and memo.redo.len > 0 and not readOnly:
        memo.undo.add (s, st.caret)
        let u = memo.redo.pop()
        s = u.s
        moveTo(u.caret, false)
        starts = lineStarts(s)
        changed = true
        memo.lastEdit = 0
      else: used = ctrl
    of KeyY:
      if ctrl and memo.redo.len > 0 and not readOnly:
        memo.undo.add (s, st.caret)
        let u = memo.redo.pop()
        s = u.s
        moveTo(u.caret, false)
        starts = lineStarts(s)
        changed = true
        memo.lastEdit = 0
      else: used = ctrl
    of KeyF3:
      if find.len > 0:
        let back = shift
        var p = if back: s.rfind(find, 0, max(0, a0 - 1)) else: s.find(find, b0)
        if p < 0: p = if back: s.rfind(find) else: s.find(find)     # (round again)
        if p >= 0:
          st.anchor = p
          st.caret = p + find.len
          moved = true
      else: used = false
    else: used = false
    if used: ui.keyUsed = true
    if ui.typed.len > 0 and not ctrl:
      var t = ""
      for ch in ui.typed:
        if ch >= ' ' or ch.uint8 >= 0x80: t.add ch
      if t.len > 0: replaceSel(t)

  # the caret in view
  let ck = caretLine()
  let maxY = max(0, starts.len * lh - inner.h + lh div 2)
  if moved:
    if ck * lh < st.scrollY: st.scrollY = ck * lh
    if (ck + 1) * lh > st.scrollY + inner.h: st.scrollY = (ck + 1) * lh - inner.h
    let cx = xOfPos(st.caret)
    if cx < st.scrollX: st.scrollX = max(0, cx - viewW div 4)
    if cx > st.scrollX + viewW - cw: st.scrollX = cx - viewW + viewW div 4
  st.scrollY = clamp(st.scrollY, 0, maxY)

  # draw: the field, the gutter, the lines in their colors
  fill(r, th.field)
  fieldFrame(r, true)
  let gutterBg = mixColor(th.field, th.face, 0.5)
  if lineNumbers: fill(rect(inner.x, inner.y, gutter - dp(4), inner.h), gutterBg)
  let a0 = min(st.caret, st.anchor)
  let b0 = max(st.caret, st.anchor)
  let first = clamp(st.scrollY div lh, 0, starts.high)
  var inBlock = false
  if lang != clNone:
    for k in 0 ..< first: discard tokens(lineText(s, starts, k), lang, inBlock)
  pushClip(inner)
  for k in first .. min(starts.high, first + visLines + 1):
    let y = inner.y + k * lh - st.scrollY
    let ln = lineText(s, starts, k)
    let la = starts[k]
    if lineNumbers:
      let num = $(k + 1)
      text(inner.x + gutter - dp(8) - textWidth(num, mono), y, num,
           if k == ck and focused: th.fieldText else: th.gray, mono)
    pushClip(rect(textX, inner.y, viewW + dp(4), inner.h))
    let x0 = textX - st.scrollX
    if focused and k == ck and a0 == b0:
      fill(rect(textX, y, viewW + dp(4), lh), mixColor(th.field, th.select, 0.08))
    # what `find` names, marked
    if find.len > 0:
      # (a soft yellow; a dark amber in dark schemes: the letters stay read)
      let mark = if dark: color(110, 85, 10) else: color(255, 230, 120)
      var p = ln.find(find)
      while p >= 0:
        fill(rect(x0 + textWidth(ln[0 ..< p], mono), y,
                  textWidth(find, mono), lh), mark)
        p = ln.find(find, p + find.len)
    # the selection under the letters
    if b0 > a0 and b0 >= la and a0 <= la + ln.len:
      let sa = clamp(a0 - la, 0, ln.len)
      let sbb = clamp(b0 - la, 0, ln.len)
      var sw = textWidth(ln[sa ..< sbb], mono)
      if b0 > la + ln.len: sw += cw div 2
      fill(rect(x0 + textWidth(ln[0 ..< sa], mono), y, sw, lh), th.select)
    # the letters, part by part in their colors
    let toks = tokens(ln, lang, inBlock)
    var p = 0
    var x = x0
    template part(e: int; c: Color) =
      if e > p:
        let piece = ln[p ..< e]
        text(x, y, piece, c, mono)
        x += textWidth(piece, mono)
        p = e
    for t in toks:
      part(t.a, th.fieldText)
      part(t.b, tokColor(t.k, dark))
    part(ln.len, th.fieldText)
    # the selected letters again, in the selection's color
    if b0 > a0 and b0 >= la and a0 <= la + ln.len:
      let sa = clamp(a0 - la, 0, ln.len)
      let sbb = clamp(b0 - la, 0, ln.len)
      if sbb > sa:
        text(x0 + textWidth(ln[0 ..< sa], mono), y, ln[sa ..< sbb], th.selectText, mono)
    if focused and ui.active31 and k == ck and
       ((ui.now div 530) mod 2 == 0 or moved or changed):
      vline(x0 + textWidth(ln[0 ..< clamp(st.caret - la, 0, ln.len)], mono), y, lh, th.fieldText)
    popClip()
  popClip()
  if focused: wakeIn(530 - ui.now mod 530)
  if focused:
    noteTextCaret(rect(globalX(textX - st.scrollX + xOfPos(st.caret)),
                       inner.y + ck * lh - st.scrollY, 1, lh))

  # the scroll bar
  var sy = st.scrollY
  if scrollbarAt(Id(uint32(id) xor 0x5c0de000'u32), rect(r.x + r.w - 2 - sb, r.y + 2, sb, r.h - 4),
                 true, sy, 0, maxY, max(lh, inner.h - lh), step = lh):
    st.scrollY = sy
  if accessOn:
    discard accessNode(arTextArea, value = s, id = id, r = r,
                       states = (if readOnly: {asReadOnly} else: {}) + {asMultiLine})
  state(id) = st
  memos[id] = memo
  changed
