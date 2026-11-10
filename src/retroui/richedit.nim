## Formatted text for writing mail -- new messages, replies, signatures:
## `richEdit`, a text box of rich text with the look of `editArea` (sunken,
## white, the kit's font), and `richToolbar`, the row of buttons that
## formats it.
##
## The text is a `RichDoc`: paragraphs (plain, bulleted, numbered, quoted,
## headings; aligned, indented) made of runs of styled text (bold, italic,
## underline, strikethrough, monospace, a color, a size, a link).
##
## - make one: `richDoc` (from plain text), `richFromHtml` (a mail's HTML)
## - send it: `toHtml` (the text/html part, inline styles only) and
##   `toPlainText` (the text/plain part)
## - change it: `richBold`, `richColor`, `richList`, `richLink`,
##   `richInsert`, `richInsertDoc` (a signature)... -- on the selection, as
##   the tool bar and the keys do
## - keys: arrows, Home / End, PgUp / PgDn (Shift: select, Ctrl: by word),
##   Ctrl+B / I / U, Ctrl+K a link, Ctrl+Z / Y undo and redo, Ctrl+A / C /
##   X / V, Tab and Shift+Tab in lists, Ctrl+Shift+7 / 8 / 9 numbers,
##   bullets, quote, Ctrl with the brackets the indent, Ctrl+Backslash
##   plain text again
##
## Arabic and Hebrew paragraphs (their first letter says) go right to left,
## at the right. Only the paragraphs that changed are laid out again and
## only the lines in view are drawn: long mails stay quick.
##
## Spelling, as Outlook checks it (`RichDoc.spell`, with `retroui/spell`): a
## red wavy line under the misspelled words; a right click (a long press)
## on one offers corrections, "Ignore All" and "Add to Dictionary"; F7 goes
## to the next. AutoCorrect (`RichDoc.autoCorrect`) fixes "teh" and "الى"
## as they are typed; Ctrl+Z right after gives back what was typed.
##
## .. code-block:: nim
##   import retroui, retroui/richedit
##   var body = richFromHtml("<p>Hello <b>Sultan</b>,</p><p><br></p>")
##   body.spell = true
##   body.autoCorrect = true
##   app "Compose", 640, 480:
##     richToolbar body
##     richEdit body, placeholder = "Write your message"
##     if button("&Send"): send(toHtml(body), toPlainText(body))

import std/[strutils, hashes, tables, math, sequtils]
import std/unicode except strip   # (its strip cuts letters: docs/nim-bugs.md)
import uirelays/input
import core, widgets, business, pixelicons, nerdicons, spell
from extras import toast
from typeset import bidiInfo, visualOrderOf, plainLetters, joinsAt

template th: untyped = ui.theme

# ---- the document ---------------------------------------------------------------------------------

type
  RichStyle* = object
    ## How a run of text looks.
    bold*, italic*, underline*, strike*, mono*: bool  ## its style (`mono`: FreeMono)
    color*: Color      ## alpha 0: the normal text color
    size*: float       ## 1.0 the normal size (0 means 1.0)
    link*: string      ## a link's address, "" if none

  RichRun* = object
    ## Text in one style (no line breaks in it).
    text*: string      ## what it says (UTF-8)
    style*: RichStyle  ## how it looks

  ParaKind* = enum
    ## What a paragraph is.
    pkNormal           ## plain text
    pkBullet           ## an item of a bulleted list
    pkNumber           ## an item of a numbered list
    pkQuote            ## a quoted line (of a reply): a bar beside it
    pkHeading          ## a heading, bold and big (`level` 0, 1, 2: h1, h2, h3)

  RichPara* = object
    ## A paragraph: its runs, what it is and where it sits.
    runs*: seq[RichRun]  ## its text, run by run
    kind*: ParaKind    ## what it is
    level*: int        ## list / quote nesting, 0 first level (plain text: its indent;
                       ## a heading: 0 the biggest)
    align*: Align      ## alLeft is the paragraph's start (the right of an Arabic
                       ## one), alRight its end

  RichPos* = object
    ## A place in a `RichDoc`: byte `off` of paragraph `para`'s text.
    para*, off*: int   ## the paragraph (an index of `paras`), and the byte in its text

  EditKind = enum ekOther, ekTyping, ekDeleting

  Step = object
    ## One undo step: paragraphs `first ..< first + afterCount` were `before`.
    first, afterCount: int
    before: seq[RichPara]
    caret0, anchor0, caret1, anchor1: RichPos
    kind: EditKind
    fresh: bool          ## typing that starts a new word: a step of its own
    t: int

  Piece = object
    ## A stretch of one run on a line, drawn with one call.
    a, b: int32          ## its bytes in the paragraph's text
    x, w: int32          ## where it is (from the text area's left) and how wide
    asc: int16           ## from its top to its baseline
    run: int16
    rtl: bool            ## drawn right to left
    st: TextStyle

  LineBox = object
    a, b: int32          ## its bytes (a wrapped line's end is the next one's start)
    y, h, base: int32    ## its top in the paragraph, its height, its baseline from the top
    p0, p1: int32        ## its pieces, in the order of the text
    x0: int32            ## the caret on an empty line

  ParaLay = ref object
    ## A paragraph laid out at a width.
    src: RichPara        ## the paragraph it was made from
    text: string
    h: int
    rtl: bool
    lines: seq[LineBox]
    pieces: seq[Piece]
    textL, textR: int    ## the room of its text (from the text area's left)
    st0: TextStyle       ## its first run's look (markers, an empty line)
    badKey: int          ## what `bad` was found for (`spellKey`; 0: not looked yet)
    bad: seq[tuple[a, b: int32]]  ## its misspelled words' bytes

  RichDoc* = object
    ## Formatted text: paragraphs of styled runs. The editor's caret,
    ## selection, undo history and layout are kept in it as well.
    paras*: seq[RichPara]  ## its paragraphs, in order (at least one)
    base*: RichStyle     ## the look of text typed where there is none to follow (an
                         ## empty line): a reply in Outlook's blue, say
    spell*: bool         ## misspelled words underlined in red, corrections in the
                         ## editor's menu (`retroui/spell`)
    autoCorrect*: bool   ## AutoCorrect as one types (what it does: `autoCorrectEnable`)
    spellLang*: string   ## the language of both ("": each word's, by its letters)
    caret, anchor: RichPos
    typing: RichStyle    ## the style typing takes (toggled at a caret)
    hasTyping: bool
    undos, redos: seq[Step]
    lastTyped: char
    goalX: int           ## Up / Down keep to this x
    unit: int            ## a drag selects by characters (0), words (1), paragraphs (2)
    unitA, unitB: RichPos  ## ... from what the click selected
    scrollY: int
    viewH: int
    lays: seq[ParaLay]
    tops: seq[int]       ## each paragraph's top; the last one: the height of all
    layCache: Table[Hash, ParaLay]
    layEnv: Hash
    dirty: bool          ## changed since `richEdit` last said so
    reveal: bool         ## the caret to be scrolled into view
    focusedNow: bool
    origin: Point        ## where the text was drawn (the window's coordinates)
    box: Rect            ## (the text's box: kept as it reads in a right-to-left interface)
    caretBox: Rect
    clicked: string
    linkAsk, linkHad: bool
    linkUrl: string
    linkFrame: int
    typingWord: bool     ## the word at the caret is being typed: no red line yet
    spellHit: tuple[para, a, b: int; word: string; sugs: seq[string]]
                         ## the misspelled word the menu is for (word "": none)
    spellMenu: bool      ## F7: its menu to open where the word is

const
  MaxLevel = 8                  ## deepest lists, quotes and indents
  MaxUndo = 300                 ## undo steps kept
  HeadSizes = [2.0, 1.5, 1.0]   ## the headings' sizes (h3: bold only)
  richColors* = [
    ("Black", color(0, 0, 0)), ("Maroon", color(128, 0, 0)),
    ("Green", color(0, 128, 0)), ("Olive", color(128, 128, 0)),
    ("Navy", color(0, 0, 128)), ("Purple", color(128, 0, 128)),
    ("Teal", color(0, 128, 128)), ("Gray", color(128, 128, 128)),
    ("Silver", color(192, 192, 192)), ("Red", color(255, 0, 0)),
    ("Lime", color(0, 255, 0)), ("Yellow", color(255, 255, 0)),
    ("Blue", color(0, 0, 255)), ("Fuchsia", color(255, 0, 255)),
    ("Aqua", color(0, 255, 255)), ("White", color(255, 255, 255))]
    ## The 16 VGA colors the color button offers.
  richSizes* = [("Small", 0.85), ("Normal", 1.0), ("Large", 1.5), ("Huge", 2.0)]
    ## The sizes the size button offers.

var
  caretT: int                   ## when the caret last moved: it blinks from then
  tapFocus: Id                  ## a finger landed on an editor without the focus
  richClip: tuple[plain: string; doc: RichDoc]
    ## what this editor copied last: pasted with its formatting while the
    ## clipboard still has its text

proc sizeOf(s: RichStyle): float {.inline.} = (if s.size > 0: s.size else: 1.0)

proc norm(s: RichStyle): RichStyle =
  ## `s` in one spelling: the normal color and size as zeros.
  result = s
  if result.color.a == 0: result.color = Color()
  if result.size <= 0 or abs(result.size - 1.0) < 0.001: result.size = 0

proc paraText*(p: RichPara): string =
  ## The text of paragraph `p`: its runs one after the other.
  for r in p.runs: result.add r.text

proc paraLen(p: RichPara): int =
  for r in p.runs: result += r.text.len

proc `<`*(a, b: RichPos): bool =
  ## `a` comes before `b`.
  a.para < b.para or (a.para == b.para and a.off < b.off)

proc `<=`*(a, b: RichPos): bool =
  ## `a` comes before `b` or is `b`.
  not (b < a)

proc tidy(p: var RichPara) =
  ## Runs of one style joined, empty ones left out (an empty paragraph keeps
  ## one: the style typing there takes).
  var keep: seq[RichRun]
  let first = if p.runs.len > 0: p.runs[0].style else: RichStyle()
  for r in p.runs.mitems:
    if r.text.len == 0: continue
    let s = norm(r.style)
    if keep.len > 0 and keep[^1].style == s: keep[^1].text.add r.text
    else: keep.add RichRun(text: move r.text, style: s)
  if keep.len == 0: keep.add RichRun(style: norm(first))
  p.runs = keep
  p.level = clamp(p.level, 0, MaxLevel)

proc cleanText(s: string): string =
  ## Text as paragraphs take it: line ends as '\n', tabs as spaces, no
  ## control characters.
  var i = 0
  while i < s.len:
    let c = s[i]
    if c == '\r':
      result.add '\n'
      if i + 1 < s.len and s[i + 1] == '\n': inc i
    elif c == '\t': result.add "    "
    elif c == '\n' or c.uint8 >= 32 and c != '\x7F': result.add c
    inc i

proc richDoc*(text = ""): RichDoc =
  ## A document of plain `text`: a paragraph for each of its lines.
  for ln in cleanText(text).split('\n'):
    result.paras.add RichPara(runs: @[RichRun(text: ln)])

proc runeBefore(s: string; i: int): int =
  var j = min(i, s.len) - 1
  while j > 0 and (s[j].uint8 and 0xC0) == 0x80: dec j
  max(0, j)

proc runeAfter(s: string; i: int): int =
  if i >= s.len: return s.len
  var j = i + 1
  while j < s.len and (s[j].uint8 and 0xC0) == 0x80: inc j
  j

proc wordChar(c: char): bool = c.isAlphaNumeric or c == '_' or c.uint8 >= 0x80

proc wordLeft(s: string; i: int): int =
  result = i
  while result > 0 and not wordChar(s[result - 1]): dec result
  while result > 0 and wordChar(s[result - 1]): dec result

proc wordRight(s: string; i: int): int =
  result = i
  while result < s.len and wordChar(s[result]): inc result
  while result < s.len and not wordChar(s[result]): inc result

proc clampPos(d: RichDoc; p: RichPos): RichPos =
  result.para = clamp(p.para, 0, max(0, d.paras.high))
  if d.paras.len == 0: result = RichPos(); return
  let n = paraLen(d.paras[result.para])
  result.off = clamp(p.off, 0, n)
  if result.off > 0 and result.off < n:
    # (on a character's first byte)
    var k = 0
    var pos = 0
    for r in d.paras[result.para].runs:
      if result.off < pos + r.text.len:
        k = result.off - pos
        while k > 0 and (r.text[k].uint8 and 0xC0) == 0x80:
          dec k
          dec result.off
        break
      pos += r.text.len

proc fixup(d: var RichDoc) =
  ## Never empty: a paragraph at least, a run in each; the caret in the text.
  if d.paras.len == 0: d.paras.add RichPara(runs: @[RichRun()])
  for p in d.paras.mitems:
    if p.runs.len == 0: p.runs.add RichRun()
  d.caret = clampPos(d, d.caret)
  d.anchor = clampPos(d, d.anchor)

proc selRange(d: RichDoc): (RichPos, RichPos) =
  let c = clampPos(d, d.caret)
  let a = clampPos(d, d.anchor)
  if a < c: (a, c) else: (c, a)

proc docEnd(d: RichDoc): RichPos =
  RichPos(para: d.paras.high, off: paraLen(d.paras[^1]))

proc splitAt(p: var RichPara; off: int): int =
  ## A run boundary at byte `off`: the index of the run that starts there
  ## (`runs.len` at the end).
  var pos = 0
  for i in 0 ..< p.runs.len:
    let n = p.runs[i].text.len
    if off <= pos: return i
    if off < pos + n:
      let r = p.runs[i]
      p.runs[i].text = r.text[0 ..< off - pos]
      p.runs.insert(RichRun(text: r.text[off - pos .. ^1], style: r.style), i + 1)
      return i + 1
    pos += n
  p.runs.len

proc styleBefore(p: RichPara; off: int): RichStyle =
  ## The style of the character before byte `off` (at the start: the first's).
  if p.runs.len == 0: return
  var pos = 0
  for r in p.runs:
    if off > pos and off <= pos + r.text.len: return r.style
    pos += r.text.len
  if off <= 0: p.runs[0].style else: p.runs[^1].style

proc styleAfter(p: RichPara; off: int; found: var bool): RichStyle =
  ## The style of the character at byte `off`.
  var pos = 0
  for r in p.runs:
    if off >= pos and off < pos + r.text.len:
      found = true
      return r.style
    pos += r.text.len

proc typingStyleAt(d: RichDoc; at: RichPos): RichStyle =
  ## What typing at `at` looks like: the character before it -- a link only
  ## inside one (not at its ends); on an empty line, the doc's `base`.
  let p = d.paras[at.para]
  var empty = true
  for r in p.runs:
    if r.text.len > 0:
      empty = false
      break
  if empty:
    result = d.base
    result.link = ""
    return
  result = styleBefore(p, at.off)
  if result.link.len > 0:
    var found = false
    let after = styleAfter(p, at.off, found)
    if at.off == 0 or not found or after.link != result.link: result.link = ""

proc typingStyle(d: RichDoc): RichStyle =
  if d.hasTyping and d.caret == d.anchor: d.typing
  else: typingStyleAt(d, clampPos(d, d.caret))

# ---- undo -----------------------------------------------------------------------------------------

proc pushStep(d: var RichDoc; s: sink Step) =
  d.redos.setLen(0)
  if d.undos.len > 0 and s.kind != ekOther and not s.fresh:
    let p = addr d.undos[^1]
    if p.kind == s.kind and p.first == s.first and p.afterCount == 1 and
       s.afterCount == 1 and s.before.len == 1 and p.caret1 == s.caret0 and
       p.anchor1 == s.anchor0:
      p.caret1 = s.caret1
      p.anchor1 = s.anchor1
      p.t = s.t
      return
  d.undos.add s
  if d.undos.len > MaxUndo: d.undos.delete(0)

template recording(d: var RichDoc; fromPara, toPara: int; ek: EditKind; isFresh: bool;
                   body: untyped) =
  ## `body` changes paragraphs `fromPara .. toPara` (and may add or take
  ## some): one undo step.
  let f0 = fromPara
  let l0 = toPara
  let n0 = d.paras.len
  var st0 = Step(first: f0, before: d.paras[f0 .. l0], caret0: d.caret,
                 anchor0: d.anchor, kind: ek, fresh: isFresh, t: ui.now)
  body
  if d.paras.len == 0: d.paras.add RichPara(runs: @[RichRun()])
  st0.afterCount = l0 - f0 + 1 + d.paras.len - n0
  st0.caret1 = d.caret
  st0.anchor1 = d.anchor
  pushStep(d, st0)
  d.dirty = true
  d.reveal = true

proc swapIn(d: var RichDoc; s: var Step): bool =
  ## What the step made, back as it was before (`s` then holds what was taken
  ## out: the same call undoes it again).
  if s.first < 0 or s.afterCount < 0 or s.first + s.afterCount > d.paras.len: return false
  let taken = d.paras[s.first ..< s.first + s.afterCount]
  if s.afterCount > 0: d.paras.delete(s.first ..< s.first + s.afterCount)
  d.paras.insert(s.before, s.first)
  s.afterCount = s.before.len
  s.before = taken
  true

proc richCanUndo*(d: RichDoc): bool = d.undos.len > 0
  ## There is something to undo.

proc richCanRedo*(d: RichDoc): bool = d.redos.len > 0
  ## There is something to redo.

proc richUndo*(d: var RichDoc) =
  ## Takes back the last change (typing comes back a word at a time).
  if d.undos.len == 0: return
  var s = d.undos.pop()
  if not swapIn(d, s):
    d.undos.setLen(0)
    d.redos.setLen(0)
    return
  fixup(d)
  d.caret = clampPos(d, s.caret0)
  d.anchor = clampPos(d, s.anchor0)
  d.hasTyping = false
  d.typingWord = false
  d.redos.add s
  d.dirty = true
  d.reveal = true

proc richRedo*(d: var RichDoc) =
  ## Does again what `richUndo` took back.
  if d.redos.len == 0: return
  var s = d.redos.pop()
  if not swapIn(d, s):
    d.undos.setLen(0)
    d.redos.setLen(0)
    return
  fixup(d)
  d.caret = clampPos(d, s.caret1)
  d.anchor = clampPos(d, s.anchor1)
  d.hasTyping = false
  d.typingWord = false
  d.undos.add s
  d.dirty = true
  d.reveal = true

# ---- changes (no undo steps of their own) ----------------------------------------------------------

proc insertRuns(p: var RichPara; off: int; runs: openArray[RichRun]) =
  let i = splitAt(p, off)
  var k = i
  for r in runs:
    if r.text.len > 0:
      p.runs.insert(r, k)
      inc k
  tidy(p)

proc deleteRange(d: var RichDoc; a, b: RichPos) =
  ## The text from `a` to `b` taken out (paragraphs between joined). An
  ## emptied paragraph keeps the style of what was taken.
  if not (a < b): return
  var found = false
  var st = styleAfter(d.paras[a.para], a.off, found)
  if not found: st = styleBefore(d.paras[a.para], a.off)
  if a.para == b.para:
    template p: untyped = d.paras[a.para]
    let i = splitAt(p, a.off)
    let j = splitAt(p, b.off)
    if j > i: p.runs.delete(i ..< j)
  else:
    var head = d.paras[a.para]
    head.runs.setLen(splitAt(head, a.off))
    var tail = d.paras[b.para]
    let j = splitAt(tail, b.off)
    for k in j ..< tail.runs.len: head.runs.add tail.runs[k]
    d.paras[a.para] = head
    d.paras.delete(a.para + 1 .. b.para)
  if paraLen(d.paras[a.para]) == 0: d.paras[a.para].runs = @[RichRun(style: st)]
  tidy(d.paras[a.para])

proc splitPara(d: var RichDoc; at: RichPos) =
  ## A paragraph break at `at`: what follows goes into a new paragraph of
  ## the same kind (after a heading's end: plain text).
  var p = d.paras[at.para]
  let st = typingStyleAt(d, at)
  let first = if p.runs.len > 0: p.runs[0].style else: RichStyle()
  let i = splitAt(p, at.off)
  var q = RichPara(kind: p.kind, level: p.level, align: p.align, runs: p.runs[i .. ^1])
  p.runs.setLen(i)
  if p.runs.len == 0: p.runs = @[RichRun(style: first)]
  if q.runs.len == 0 or paraLen(q) == 0:
    q.runs = @[RichRun(style: st)]
    if p.kind == pkHeading:
      q.kind = pkNormal
      q.level = 0
  tidy(p)
  tidy(q)
  d.paras[at.para] = p
  d.paras.insert(q, at.para + 1)

proc restyle(d: var RichDoc; a, b: RichPos; f: proc (s: var RichStyle)) =
  ## `f` applied to the style of the text from `a` to `b` (an empty
  ## paragraph among: to the style it keeps).
  for pi in a.para .. b.para:
    template p: untyped = d.paras[pi]
    let n = paraLen(p)
    let s = if pi == a.para: a.off else: 0
    let e = if pi == b.para: b.off else: n
    if n == 0:
      f(p.runs[0].style)
    elif e > s:
      let i = splitAt(p, s)
      let j = splitAt(p, e)
      for k in i ..< j: f(p.runs[k].style)
    tidy(p)

proc allOf(d: RichDoc; a, b: RichPos; get: proc (s: RichStyle): bool): bool =
  ## Every character from `a` to `b` has it.
  for pi in a.para .. b.para:
    let s = if pi == a.para: a.off else: 0
    let e = if pi == b.para: b.off else: high(int)
    var pos = 0
    for r in d.paras[pi].runs:
      let ra = pos
      let rb = pos + r.text.len
      pos = rb
      if rb > s and ra < e and not get(r.style): return false
  true

proc wordAround(d: RichDoc; at: RichPos): tuple[ok: bool; a, b: int] =
  ## The word the caret is in (not at its ends).
  let t = paraText(d.paras[at.para])
  if at.off > 0 and at.off < t.len and wordChar(t[at.off - 1]) and wordChar(t[at.off]):
    result.ok = true
    result.a = at.off
    while result.a > 0 and wordChar(t[result.a - 1]): dec result.a
    result.b = at.off
    while result.b < t.len and wordChar(t[result.b]): inc result.b

proc linkAround(d: RichDoc; at: RichPos): tuple[ok: bool; a, b: int; url: string] =
  ## The link the caret is in or at.
  let p = d.paras[at.para]
  var found = false
  var s = styleAfter(p, at.off, found)
  if not found or s.link.len == 0: s = styleBefore(p, at.off)
  if at.off == 0 and not found: return
  if s.link.len == 0: return
  # the runs of that link around the caret
  var pos = 0
  var starts: seq[int]
  for r in p.runs:
    starts.add pos
    pos += r.text.len
  var k = -1
  for i, r in p.runs:
    let ra = starts[i]
    let rb = ra + r.text.len
    if r.style.link == s.link and at.off >= ra and at.off <= rb:
      k = i
      break
  if k < 0: return
  var i0 = k
  while i0 > 0 and p.runs[i0 - 1].style.link == s.link: dec i0
  var i1 = k
  while i1 < p.runs.high and p.runs[i1 + 1].style.link == s.link: inc i1
  (true, starts[i0], starts[i1] + p.runs[i1].text.len, s.link)

proc target(d: RichDoc): tuple[a, b: RichPos; ok: bool] =
  ## What a command formats: the selection, else the caret's word.
  let (a, b) = selRange(d)
  if a != b: return (a, b, true)
  let w = wordAround(d, a)
  if w.ok: return (RichPos(para: a.para, off: w.a), RichPos(para: a.para, off: w.b), true)
  (a, b, false)

proc fragment(d: RichDoc; a, b: RichPos): RichDoc =
  ## A copy of the text from `a` to `b`.
  for pi in a.para .. b.para:
    var p = d.paras[pi]
    let n = paraLen(p)
    let s = if pi == a.para: a.off else: 0
    let e = if pi == b.para: b.off else: n
    if e < n: p.runs.setLen(splitAt(p, e))
    if s > 0:
      let i = splitAt(p, s)
      p.runs = p.runs[i .. ^1]
    if p.runs.len == 0: p.runs = @[RichRun(style: styleBefore(d.paras[pi], s))]
    tidy(p)
    result.paras.add p

proc charsAt(d: RichDoc; p: RichPos): int =
  ## (where `p` is in the text a screen reader has, in characters)
  for i in 0 ..< min(p.para, d.paras.len):
    result += paraText(d.paras[i]).runeLen + 1
  if p.para < d.paras.len:
    let t = paraText(d.paras[p.para])
    result += t[0 ..< clamp(p.off, 0, t.len)].runeLen

proc plainOf(f: RichDoc): string =
  for i, p in f.paras:
    if i > 0: result.add '\n'
    result.add paraText(p)

proc insertDocAt(d: var RichDoc; src0: seq[RichPara]) =
  ## `src0` in place of the selection (the caret after it). Its first and
  ## last paragraphs join the text before and after the caret.
  if src0.len == 0: return
  var src = src0
  for p in src.mitems:
    if p.runs.len == 0: p.runs.add RichRun()
    for r in p.runs.mitems:
      if '\n' in r.text or '\r' in r.text or '\t' in r.text:
        r.text = cleanText(r.text).replace('\n', ' ')
    tidy(p)
  let (a, b) = selRange(d)
  recording(d, a.para, b.para, ekOther, true):
    if a != b: deleteRange(d, a, b)
    if src.len == 1:
      insertRuns(d.paras[a.para], a.off, src[0].runs)
      d.caret = RichPos(para: a.para, off: a.off + paraLen(src[0]))
    else:
      var p = d.paras[a.para]
      let wasEmptyHead = a.off == 0
      let i = splitAt(p, a.off)
      let tailRuns = p.runs[i .. ^1]
      p.runs.setLen(i)
      for r in src[0].runs: p.runs.add r
      if wasEmptyHead:
        p.kind = src[0].kind
        p.level = src[0].level
        p.align = src[0].align
      tidy(p)
      var last = src[^1]
      let lastLen = paraLen(last)
      for r in tailRuns: last.runs.add r
      tidy(last)
      d.paras[a.para] = p
      var rest = src[1 ..< src.high]
      rest.add last
      d.paras.insert(rest, a.para + 1)
      d.caret = RichPos(para: a.para + src.high, off: lastLen)
    d.anchor = d.caret
  d.hasTyping = false

# ---- commands ----------------------------------------------------------------------------------

proc styleCmd(d: var RichDoc; get: proc (s: RichStyle): bool;
              put: proc (s: var RichStyle; on: bool)) =
  ## A switch (bold...): on for the selection or the caret's word unless
  ## all of it has it; at a caret between words, for what is typed next.
  fixup(d)
  let t = target(d)
  if not t.ok:
    d.typing = typingStyle(d)
    put(d.typing, not get(d.typing))
    d.hasTyping = true
    return
  let on = not allOf(d, t.a, t.b, get)
  recording(d, t.a.para, t.b.para, ekOther, true):
    restyle(d, t.a, t.b, proc (s: var RichStyle) = put(s, on))

proc setCmd(d: var RichDoc; put: proc (s: var RichStyle)) =
  ## A value (a color, a size) for the selection, the caret's word, or what
  ## is typed next.
  fixup(d)
  let t = target(d)
  if not t.ok:
    d.typing = typingStyle(d)
    put(d.typing)
    d.hasTyping = true
    return
  recording(d, t.a.para, t.b.para, ekOther, true):
    restyle(d, t.a, t.b, put)

proc richBold*(d: var RichDoc) =
  ## Bold on or off: the selection, the caret's word, or what is typed next.
  styleCmd(d, proc (s: RichStyle): bool = s.bold, proc (s: var RichStyle; on: bool) = s.bold = on)

proc richItalic*(d: var RichDoc) =
  ## Italic on or off (as `richBold`).
  styleCmd(d, proc (s: RichStyle): bool = s.italic, proc (s: var RichStyle; on: bool) = s.italic = on)

proc richUnderline*(d: var RichDoc) =
  ## Underline on or off (as `richBold`).
  styleCmd(d, proc (s: RichStyle): bool = s.underline,
           proc (s: var RichStyle; on: bool) = s.underline = on)

proc richStrike*(d: var RichDoc) =
  ## Strikethrough on or off (as `richBold`).
  styleCmd(d, proc (s: RichStyle): bool = s.strike, proc (s: var RichStyle; on: bool) = s.strike = on)

proc richMono*(d: var RichDoc) =
  ## Monospaced (code) on or off (as `richBold`).
  styleCmd(d, proc (s: RichStyle): bool = s.mono, proc (s: var RichStyle; on: bool) = s.mono = on)

proc richColor*(d: var RichDoc; c: Color) =
  ## The text's color (alpha 0: the normal one), as `richBold` chooses what.
  let c = if c.a == 0: Color() else: c
  setCmd(d, proc (s: var RichStyle) = s.color = c)

proc richSize*(d: var RichDoc; size: float) =
  ## The text's size (1.0 normal; see `richSizes`), as `richBold` chooses what.
  let k = if size <= 0: 0.0 else: clamp(size, 0.5, 3.0)
  setCmd(d, proc (s: var RichStyle) = s.size = k)

proc cleanUrl(url: string): string =
  ## An address as a link takes it: an e-mail address as "mailto:", "www."
  ## as "https://"; scripts not at all.
  result = url.strip
  var scheme = ""
  for c in result:
    if c == ':': break
    if c notin {' ', '\t'}: scheme.add c.toLowerAscii
    if scheme.len > 12: break
  if ':' in result and scheme in ["javascript", "vbscript", "data"]: result = ""; return
  if result.len == 0: return
  if ':' notin result and '@' in result and '/' notin result and ' ' notin result:
    result = "mailto:" & result
  elif result.toLowerAscii.startsWith("www."):
    result = "https://" & result

proc richLink*(d: var RichDoc; url: string) =
  ## Makes the selection (or the caret's word, or the link the caret is in)
  ## a link to `url`; "" takes the link away. With nothing to link, the
  ## address itself goes in as one.
  fixup(d)
  let u = cleanUrl(url)
  var (a, b) = selRange(d)
  if a == b:
    let lk = linkAround(d, a)
    if lk.ok:
      a = RichPos(para: a.para, off: lk.a)
      b = RichPos(para: a.para, off: lk.b)
    elif u.len > 0:
      let w = wordAround(d, a)
      if w.ok:
        a = RichPos(para: a.para, off: w.a)
        b = RichPos(para: a.para, off: w.b)
      else:
        var st = typingStyle(d)
        st.link = u
        let shown = if u.startsWith("mailto:"): u[7 .. ^1] else: u
        recording(d, a.para, a.para, ekOther, true):
          insertRuns(d.paras[a.para], a.off, [RichRun(text: shown, style: st)])
          d.caret = RichPos(para: a.para, off: a.off + shown.len)
          d.anchor = d.caret
        d.hasTyping = false
        return
    else: return
  recording(d, a.para, b.para, ekOther, true):
    restyle(d, a, b, proc (s: var RichStyle) = s.link = u)

proc richClearFormat*(d: var RichDoc) =
  ## Plain text again: the selection's (or the caret's word's) bold, colors,
  ## sizes... gone (links stay); its headings become plain paragraphs and
  ## their alignment the usual.
  fixup(d)
  let t = target(d)
  if not t.ok:
    d.typing = RichStyle(link: "")
    d.hasTyping = true
  recording(d, t.a.para, t.b.para, ekOther, true):
    if t.ok:
      restyle(d, t.a, t.b, proc (s: var RichStyle) = s = RichStyle(link: s.link))
    for pi in t.a.para .. t.b.para:
      if d.paras[pi].kind == pkHeading:
        d.paras[pi].kind = pkNormal
        d.paras[pi].level = 0
      d.paras[pi].align = alLeft

proc richList*(d: var RichDoc; kind: ParaKind) =
  ## Toggles the selected paragraphs between `kind` (bullets, numbers, a
  ## quote, a heading) and plain text.
  fixup(d)
  let (a, b) = selRange(d)
  var all = true
  for pi in a.para .. b.para:
    if d.paras[pi].kind != kind: all = false
  recording(d, a.para, b.para, ekOther, true):
    for pi in a.para .. b.para:
      template p: untyped = d.paras[pi]
      if all or kind == pkNormal:
        p.kind = pkNormal
        p.level = 0
      elif p.kind != kind:
        let keepLevel = kind in {pkBullet, pkNumber} and p.kind in {pkBullet, pkNumber}
        p.kind = kind
        if not keepLevel: p.level = 0

proc richAlign*(d: var RichDoc; a: Align) =
  ## The selected paragraphs' alignment (alLeft: their start side).
  fixup(d)
  let (x, y) = selRange(d)
  recording(d, x.para, y.para, ekOther, true):
    for pi in x.para .. y.para: d.paras[pi].align = a

proc richIndent*(d: var RichDoc; delta: int) =
  ## The selected paragraphs `delta` levels deeper (a list item, a quote, a
  ## plain paragraph's indent); headings stay.
  fixup(d)
  let (a, b) = selRange(d)
  recording(d, a.para, b.para, ekOther, true):
    for pi in a.para .. b.para:
      if d.paras[pi].kind != pkHeading:
        d.paras[pi].level = clamp(d.paras[pi].level + delta, 0, MaxLevel)

proc richInsert*(d: var RichDoc; text: string) =
  ## Plain `text` at the caret, in place of the selection, in the typing
  ## style; its lines become paragraphs like the caret's.
  fixup(d)
  let t = cleanText(text)
  if t.len == 0:
    let (a, b) = selRange(d)
    if a != b:
      recording(d, a.para, b.para, ekOther, true):
        deleteRange(d, a, b)
        d.caret = a
        d.anchor = a
    return
  let st = typingStyle(d)
  let cur = d.paras[d.caret.para]
  var src: seq[RichPara]
  for ln in t.split('\n'):
    src.add RichPara(runs: @[RichRun(text: ln, style: st)], kind: cur.kind,
                     level: cur.level, align: cur.align)
  insertDocAt(d, src)

proc richInsertDoc*(d: var RichDoc; other: RichDoc) =
  ## Formatted text at the caret, in place of the selection: a signature, a
  ## template. Its first paragraph joins the caret's.
  fixup(d)
  insertDocAt(d, other.paras)

proc richState*(d: RichDoc): RichStyle =
  ## The style at the caret (what typing takes), or of the selection: bold
  ## and the others when all of it is; the color, size and link of its
  ## start. For the tool bar's pressed buttons.
  if d.paras.len == 0: return
  let (a, b) = selRange(d)
  if a == b: return typingStyle(d)
  var first = true
  for pi in a.para .. b.para:
    let s = if pi == a.para: a.off else: 0
    let e = if pi == b.para: b.off else: high(int)
    var pos = 0
    for r in d.paras[pi].runs:
      let ra = pos
      let rb = pos + r.text.len
      pos = rb
      if rb > s and ra < e:
        if first:
          result = r.style
          first = false
        else:
          result.bold = result.bold and r.style.bold
          result.italic = result.italic and r.style.italic
          result.underline = result.underline and r.style.underline
          result.strike = result.strike and r.style.strike
          result.mono = result.mono and r.style.mono
  if first: result = typingStyleAt(d, a)

proc richParaKind*(d: RichDoc): ParaKind =
  ## What the caret's paragraph is.
  if d.paras.len == 0: pkNormal else: d.paras[clampPos(d, d.caret).para].kind

proc richAlignment*(d: RichDoc): Align =
  ## The caret's paragraph's alignment.
  if d.paras.len == 0: alLeft else: d.paras[clampPos(d, d.caret).para].align

proc richSelection*(d: RichDoc): tuple[a, b: RichPos] =
  ## The selection, its start first (the same place twice: the caret).
  let (a, b) = selRange(d)
  (a, b)

proc richCaret*(d: RichDoc): RichPos =
  ## Where the caret is (the moving end of the selection).
  clampPos(d, d.caret)

proc richSelect*(d: var RichDoc; anchor, caret: RichPos) =
  ## Selects from `anchor` to `caret` (the same: puts the caret there).
  fixup(d)
  d.anchor = clampPos(d, anchor)
  d.caret = clampPos(d, caret)
  d.hasTyping = false
  d.typingWord = false
  d.reveal = true
  caretT = ui.now

proc richSelectAll*(d: var RichDoc) =
  ## Selects all the text.
  fixup(d)
  d.anchor = RichPos()
  d.caret = docEnd(d)
  d.hasTyping = false
  d.reveal = true

proc richSelectedText*(d: RichDoc): string =
  ## The selected text, plain (paragraphs on lines of their own).
  if d.paras.len == 0: return
  let (a, b) = selRange(d)
  if a == b: "" else: plainOf(fragment(d, a, b))

proc isEmpty*(d: RichDoc): bool =
  ## Nothing written: no paragraph has more than spaces.
  for p in d.paras:
    for r in p.runs:
      for c in r.text:
        if c != ' ': return false
  true

# ---- spelling and AutoCorrect ----------------------------------------------------------------------

proc unchecked(p: RichPara): seq[(int, int)] =
  ## The bytes of `p` spelling leaves alone: links and code.
  var pos = 0
  for r in p.runs:
    if r.style.link.len > 0 or r.style.mono:
      if result.len > 0 and result[^1][1] == pos: result[^1][1] = pos + r.text.len
      else: result.add (pos, pos + r.text.len)
    pos += r.text.len

proc overlaps(spans: seq[(int, int)]; a, b: int): bool =
  for (x, y) in spans:
    if x < b and a < y: return true

proc findBad(p: RichPara; text, lang: string): seq[tuple[a, b: int32]] =
  ## The misspelled words of paragraph `p` (its `text`), not in links or code.
  let skip = unchecked(p)
  for (a, b) in spellWords(text):
    if not overlaps(skip, a, b) and isMisspelled(text[a ..< b], lang):
      result.add (int32(a), int32(b))

proc spellKey(d: RichDoc): int =
  ## What the verdicts depend on: the words ignored and added, the language.
  (spellGeneration() * 1_000_003 + int(hash(d.spellLang) and 0xFFFFF)) or 1

proc badIn(d: RichDoc; pi: int): seq[tuple[a, b: int32]] =
  ## The misspelled words of paragraph `pi`: kept with its layout when there
  ## is one for it.
  if pi < d.lays.len and d.lays[pi] != nil and d.lays[pi].src == d.paras[pi]:
    let l = d.lays[pi]
    let k = spellKey(d)
    if l.badKey != k:
      l.bad = findBad(d.paras[pi], l.text, d.spellLang)
      l.badKey = k
    return l.bad
  findBad(d.paras[pi], paraText(d.paras[pi]), d.spellLang)

proc richMisspelled*(d: RichDoc; para: int): seq[tuple[a, b: int]] =
  ## The misspelled words of paragraph `para` (bytes of its text, `b` past
  ## the end), as the red lines show them: words in links and code left out.
  if para < 0 or para >= d.paras.len: return
  for (a, b) in badIn(d, para): result.add (int(a), int(b))

proc replaceIn(d: var RichDoc; pi, a, b: int; text: string; selectAfter: bool) =
  ## Bytes `a ..< b` of paragraph `pi` become `text`, in the style of their
  ## first character: one undo step. The caret goes after it
  ## (`selectAfter`) or stays where it was in the text.
  let p = d.paras[pi]
  var found = false
  var st = styleAfter(p, a, found)
  if not found: st = styleBefore(p, a)
  let delta = text.len - (b - a)
  let c0 = d.caret
  recording(d, pi, pi, ekOther, true):
    deleteRange(d, RichPos(para: pi, off: a), RichPos(para: pi, off: b))
    insertRuns(d.paras[pi], a, [RichRun(text: text, style: st)])
    if selectAfter: d.caret = RichPos(para: pi, off: a + text.len)
    elif c0.para == pi and c0.off >= b: d.caret = RichPos(para: pi, off: c0.off + delta)
    d.anchor = d.caret
  d.hasTyping = false
  d.typingWord = false

proc richReplace*(d: var RichDoc; a, b: RichPos; text: string) =
  ## Puts `text` in place of the text from `a` to `b`, in the style of its
  ## first character, the caret after it: one undo step (a spelling
  ## correction, a find and replace). Its lines become paragraphs.
  fixup(d)
  var x = clampPos(d, a)
  var y = clampPos(d, b)
  if y < x: swap(x, y)
  let t = cleanText(text)
  if x.para == y.para and '\n' notin t:
    replaceIn(d, x.para, x.off, y.off, t, true)
  else:
    d.anchor = x
    d.caret = y
    d.hasTyping = false
    richInsert(d, t)

proc richNextMisspelled*(d: var RichDoc): bool =
  ## Selects the next misspelled word after the caret (from the top again
  ## at the end); false when there is none.
  fixup(d)
  let (_, s) = selRange(d)
  for round in 0 .. 1:
    let first = if round == 0: s.para else: 0
    let last = if round == 0: d.paras.high else: s.para
    for pi in first .. last:
      for (a, b) in badIn(d, pi):
        if round == 0 and pi == s.para and a < s.off: continue
        if round == 1 and pi == s.para and a >= s.off: continue
        d.anchor = RichPos(para: pi, off: int(a))
        d.caret = RichPos(para: pi, off: int(b))
        d.hasTyping = false
        d.typingWord = false
        d.reveal = true
        return true
  false

proc autoFix(d: var RichDoc; enter = false) =
  ## AutoCorrect on what was just typed before the caret (`enter`: the
  ## paragraph before the caret's just ended), as an undo step of its own.
  if not d.autoCorrect: return
  let (a0, b0) = selRange(d)
  if a0 != b0: return
  let pi = if enter: a0.para - 1 else: a0.para
  if pi < 0 or (enter and a0.off != 0): return
  let p = d.paras[pi]
  let full = paraText(p)
  let upto = if enter: full.len else: a0.off
  let fix = if enter: autoCorrect(full & "\n", full.len + 1, d.spellLang)
            else: autoCorrect(full[0 ..< upto], upto, d.spellLang)
  if fix.replacement.len == 0 or fix.b > full.len or fix.a >= fix.b: return
  if overlaps(unchecked(p), fix.a, max(fix.b, upto)): return     # (links and code as typed)
  replaceIn(d, pi, fix.a, fix.b, fix.replacement, false)
  d.lastTyped = ' '

# ---- layout ------------------------------------------------------------------------------------

proc headK(p: RichPara): float32 =
  if p.kind == pkHeading: float32(HeadSizes[clamp(p.level, 0, HeadSizes.high)]) else: 1

proc textStyleOf(s: RichStyle; k: float32; heading: bool): TextStyle =
  TextStyle(bold: s.bold or heading, italic: s.italic, mono: s.mono,
            underline: s.underline or s.link.len > 0, strike: s.strike,
            size: float32(sizeOf(s)) * k)

proc ascOf(st: TextStyle): int =
  ## From a line's top to its baseline, in style `st`.
  (lineHeight(st) * FontAscent + FontH div 2) div max(1, FontH)

proc listStep(): int = dp(24)
proc quoteStep(): int = dp(12)

proc indentOf(p: RichPara): int =
  ## How far the text of `p` starts from its start side.
  case p.kind
  of pkBullet, pkNumber: (p.level + 1) * listStep()
  of pkQuote: (p.level + 1) * quoteStep() + dp(2)
  of pkNormal: p.level * listStep()
  of pkHeading: 0

proc anyRtl(s: string): bool =
  ## Some letter of `s` reads right to left (or an Arabic number, or an
  ## explicit direction control: the bidi algorithm has work to do).
  var high = false
  for c in s:
    if c.uint8 >= 0xC0:
      high = true
      break
  if not high: return false
  for r in s.runes:
    let c = int(r)
    if c in 0x0590 .. 0x08FF or c in 0xFB1D .. 0xFDFF or c in 0xFE70 .. 0xFEFE or
       c == 0x200F or c in 0x202A .. 0x202E or c in 0x2066 .. 0x2069 or
       c in 0x10800 .. 0x10FFF or c in 0x1E800 .. 0x1EFFF:
      return true

proc pieceText(t: string; a, b: int): string =
  ## Bytes `a ..< b` of paragraph text `t` to measure or draw on their own:
  ## where an Arabic word goes on past either end (a style changing in it),
  ## a zero width joiner, so its letters keep their joined forms.
  result = t[a ..< b]
  if joinsAt(t, a): result = "\u200D" & result
  if joinsAt(t, b): result.add "\u200D"

type Seg = object
  a, b, run: int
  space, brk: bool       ## spaces; a piece of a word too long for a line (a break before it)
  lvl: int8
  w: int

proc layoutPara(p: RichPara; w: int): ParaLay =
  ## `p` laid out in a text area `w` pixels wide: its lines, each line's
  ## pieces where they go (right to left ones reordered).
  result = ParaLay(src: p)
  var text = ""
  var starts: seq[int]
  for r in p.runs:
    starts.add text.len
    text.add r.text
  result.text = text
  let k = headK(p)
  var sts: seq[TextStyle]
  for r in p.runs: sts.add textStyleOf(r.style, k, p.kind == pkHeading)
  if sts.len == 0: sts.add textStyleOf(RichStyle(), k, p.kind == pkHeading)
  result.st0 = sts[0]
  let rtl = textIsRtl(text)
  result.rtl = rtl
  let paraLevel = int8(ord(rtl))
  let bidi = rtl or anyRtl(text)
  # each byte's bidi level (odd: right to left)
  var levels: seq[int8]
  if bidi:
    let info = bidiInfo(text, ord(rtl))
    levels = newSeq[int8](text.len)
    var ri = 0
    var i = 0
    while i < text.len:
      let j = runeAfter(text, i)
      let lv = if ri < info.levels.len: info.levels[ri] else: paraLevel
      for x in i ..< j: levels[x] = lv
      inc ri
      i = j
  let ind = indentOf(p)
  let avail = max(dp(16), w - ind)
  result.textL = if rtl: 0 else: ind
  result.textR = if rtl: w - ind else: w
  # segments: words and spaces, cut at the runs and at the changes of direction
  var segs: seq[Seg]
  for ri, r in p.runs:
    var i = 0
    while i < r.text.len:
      let sp = r.text[i] == ' '
      let lv = if bidi: levels[starts[ri] + i] else: 0'i8
      var j = i
      while j < r.text.len and (r.text[j] == ' ') == sp and
            (not bidi or levels[starts[ri] + j] == lv):
        j = runeAfter(r.text, j)
      segs.add Seg(a: starts[ri] + i, b: starts[ri] + j, run: ri, space: sp, lvl: lv)
      i = j
  proc measure(a, b, run: int; lvl: int8): int =
    var st = sts[run]
    st.rtl = (lvl and 1) == 1
    textWidth(pieceText(text, a, b), st)
  # a word wider than the line: cut where it is full
  var cut: seq[Seg]
  for s in segs.mitems:
    s.w = measure(s.a, s.b, s.run, s.lvl)
    if s.space or s.w <= avail:
      cut.add s
      continue
    var a = s.a
    var first = true
    while a < s.b:
      var b = runeAfter(text, a)
      while b < s.b:
        let nb = runeAfter(text, b)
        if measure(a, nb, s.run, s.lvl) > avail: break
        b = nb
      cut.add Seg(a: a, b: b, run: s.run, space: false, brk: not first, lvl: s.lvl,
                  w: measure(a, b, s.run, s.lvl))
      first = false
      a = b
  # (swapped, not assigned: Nim 2.2 takes `segs = cut` here for the first
  # value of `segs` and loses the pieces it held)
  swap(segs, cut)
  # lines: words while they fit (the spaces after one hang past the end)
  var lineSegs: seq[(int, int)]
  var s0 = 0
  var x = 0
  var k0 = 0
  while k0 < segs.len:
    var m = k0
    var ww = 0
    if not segs[k0].space:
      while m < segs.len and not segs[m].space and (m == k0 or not segs[m].brk):
        ww += segs[m].w
        inc m
    var n = m
    var sw = 0
    while n < segs.len and segs[n].space:
      sw += segs[n].w
      inc n
    if k0 > s0 and x + ww > avail:
      lineSegs.add (s0, k0)
      s0 = k0
      x = 0
    x += ww + sw
    k0 = n
  lineSegs.add (s0, segs.len)
  # pieces, where each goes
  var y = 0
  let lh0 = lineHeight(result.st0)
  let asc0 = ascOf(result.st0)
  for li, (f, e) in lineSegs:
    var ln = LineBox(a: int32(if f < e: segs[f].a else: 0),
                     b: int32(if f < e: segs[e - 1].b else: 0), y: int32(y))
    if f >= e and li > 0:
      ln.a = int32(text.len)
      ln.b = int32(text.len)
    # (L1: spaces at a line's end go the paragraph's way)
    var t = e
    var trailW = 0
    while t > f and segs[t - 1].space:
      segs[t - 1].lvl = paraLevel
      trailW += segs[t - 1].w
      dec t
    ln.p0 = int32(result.pieces.len)
    var levs: seq[int8]
    for kk in f ..< e:
      let s = segs[kk]
      if result.pieces.len > ln.p0 and result.pieces[^1].run == s.run and
         levs[^1] == s.lvl:
        result.pieces[^1].b = int32(s.b)
      else:
        result.pieces.add Piece(a: int32(s.a), b: int32(s.b), run: int16(s.run),
                                rtl: (s.lvl and 1) == 1)
        levs.add s.lvl
    ln.p1 = int32(result.pieces.len)
    var asc = 0
    var desc = 0
    var total = 0
    for pi in ln.p0 ..< ln.p1:
      template pc: untyped = result.pieces[pi]
      var st = sts[pc.run]
      st.rtl = pc.rtl
      pc.st = st
      pc.w = int32(textWidth(pieceText(text, pc.a, pc.b), st))
      pc.asc = int16(ascOf(st))
      asc = max(asc, int(pc.asc))
      desc = max(desc, lineHeight(st) - int(pc.asc))
      total += pc.w
    if ln.p1 == ln.p0:
      asc = asc0
      desc = lh0 - asc0
    # where the line starts: its alignment, the hanging spaces left out
    let contentW = max(0, total - trailW)
    let lead = if rtl: trailW else: 0
    let room = result.textR - result.textL
    let startSide = p.align == alLeft
    let cl =
      if p.align == alCenter: result.textL + (room - contentW) div 2
      elif startSide != rtl: result.textL
      else: result.textR - contentW
    var px = cl - lead
    let order = if bidi: visualOrderOf(levs) else: toSeq(0 ..< levs.len)
    for o in order:
      template pc: untyped = result.pieces[int(ln.p0) + o]
      pc.x = int32(px)
      px += pc.w
    ln.x0 = int32(cl)
    ln.base = int32(asc)
    ln.h = int32(max(1, asc + desc))
    y += ln.h
    result.lines.add ln
  # (an empty paragraph: one empty line)
  if result.lines.len == 0:
    result.lines.add LineBox(h: int32(lh0), base: int32(asc0),
                             x0: int32(if rtl: result.textR else: result.textL))
    y = lh0
  result.h = y

proc paraKey(p: RichPara): Hash =
  var h: Hash = 0
  h = h !& ord(p.kind)
  h = h !& p.level
  h = h !& ord(p.align)
  for r in p.runs:
    h = h !& hash(r.text)
    let s = r.style
    h = h !& (ord(s.bold) or ord(s.italic) shl 1 or ord(s.underline) shl 2 or
              ord(s.strike) shl 3 or ord(s.mono) shl 4)
    h = h !& hashF(s.size)
    h = h !& hash(s.link)
  !$h

proc ensureLayout(d: var RichDoc; w: int) =
  ## Every paragraph laid out at width `w`. A paragraph still the same as
  ## the one its layout was made from keeps it (paragraphs put in or taken
  ## out before it move it along); others are looked for in the cache, and
  ## only what is not there is laid out.
  var env: Hash = 0
  env = env !& w
  env = env !& FontH
  env = env !& FontAscent
  env = env !& pxScale
  env = env !& ord(uiFont())
  env = env !& hashF(textSize())
  env = env !& hashF(ui.k)
  env = !$env
  var old = move d.lays
  if env != d.layEnv:
    d.layCache.clear()
    d.layEnv = env
    old.setLen(0)
  let delta = d.paras.len - old.len
  d.lays.setLen(d.paras.len)
  d.tops.setLen(d.paras.len + 1)
  var y = 0
  for i in 0 ..< d.paras.len:
    var l: ParaLay = nil
    if i < old.len and old[i] != nil and old[i].src == d.paras[i]: l = old[i]
    elif i - delta >= 0 and i - delta < old.len and old[i - delta] != nil and
         old[i - delta].src == d.paras[i]:
      l = old[i - delta]
    else:
      let k = paraKey(d.paras[i])
      l = d.layCache.getOrDefault(k)
      if l == nil or l.src != d.paras[i]:
        l = layoutPara(d.paras[i], w)
        d.layCache[k] = l
    d.lays[i] = l
    d.tops[i] = y
    y += l.h
  d.tops[^1] = y
  if d.layCache.len > 2 * d.paras.len + 64:
    var keep: Table[Hash, ParaLay]
    for i in 0 ..< d.paras.len: keep[paraKey(d.paras[i])] = d.lays[i]
    d.layCache = keep

proc lineAt(l: ParaLay; off: int): int =
  ## The line the caret at byte `off` is on (a wrapped line's end: the next).
  for i in 0 ..< l.lines.len:
    if off < l.lines[i].b or i == l.lines.high: return i
  0

proc pieceX(l: ParaLay; pc: Piece; off: int): int =
  let o = clamp(off, pc.a, pc.b)
  let tw = if o == pc.a: 0 else: textWidth(pieceText(l.text, pc.a, o), pc.st)
  if pc.rtl: pc.x + pc.w - tw else: pc.x + tw

proc caretX(l: ParaLay; li, off: int): int =
  ## Where the caret at byte `off` of line `li` is: just after the
  ## character before it -- where the next one typed goes, when Latin and
  ## Arabic meet --, at the line's start before its first.
  let ln = l.lines[li]
  if ln.p0 == ln.p1: return ln.x0
  if off > ln.a:
    for k in ln.p0 ..< ln.p1:
      let pc = l.pieces[k]
      if off > pc.a and off <= pc.b: return pieceX(l, pc, off)
  for k in ln.p0 ..< ln.p1:
    let pc = l.pieces[k]
    if off >= pc.a and off < pc.b: return pieceX(l, pc, off)
  pieceX(l, l.pieces[ln.p1 - 1], off)

proc hitLine(l: ParaLay; li, x: int): int =
  ## The character boundary of line `li` nearest to `x`.
  let ln = l.lines[li]
  if ln.p0 == ln.p1: return ln.a
  var best = -1
  var bestD = high(int)
  for k in ln.p0 ..< ln.p1:
    let pc = l.pieces[k]
    let dd = if x < pc.x: pc.x - x elif x >= pc.x + pc.w: x - (pc.x + pc.w) + 1 else: 0
    if dd < bestD:
      bestD = dd
      best = k
  let pc = l.pieces[best]
  let rel = if pc.rtl: pc.x + pc.w - x else: x - pc.x
  var o = int(pc.a)
  var prevW = 0
  result = int(pc.b)
  while o < pc.b:
    let n = min(int(pc.b), clusterAfter(l.text, o))
    let wn = textWidth(pieceText(l.text, pc.a, n), pc.st)
    if rel * 2 < prevW + wn:          # nearer to `o` than to the next boundary
      result = o
      break
    prevW = wn
    o = n
  if result >= ln.b and li < l.lines.high and ln.b > ln.a:
    result = runeBefore(l.text, ln.b)

proc posAt(d: RichDoc; cx, cy: int): RichPos =
  ## The place nearest to the point `cx`, `cy` of the text (its own coordinates).
  if d.lays.len == 0: return
  var pi = 0
  if cy >= d.tops[^1]: pi = d.paras.high
  elif cy > 0:
    var lo = 0
    var hi = d.paras.high
    while lo < hi:
      let m = (lo + hi + 1) shr 1
      if d.tops[m] <= cy: lo = m else: hi = m - 1
    pi = lo
  let l = d.lays[pi]
  var li = 0
  if cy >= d.tops[^1]: li = l.lines.high
  else:
    while li < l.lines.high and cy - d.tops[pi] >= l.lines[li].y + l.lines[li].h: inc li
  RichPos(para: pi, off: hitLine(l, li, cx))

proc caretGeo(d: RichDoc; at: RichPos): tuple[x, y, h: int] =
  ## Where the caret at `at` is drawn: its x, top and height in the text.
  let l = d.lays[at.para]
  let li = lineAt(l, at.off)
  (caretX(l, li, at.off), d.tops[at.para] + l.lines[li].y, int(l.lines[li].h))

# ---- moving about ---------------------------------------------------------------------------------

proc nextPos(d: RichDoc; p: RichPos): RichPos =
  ## (a letter and its marks are one step: `clusterAfter`)
  let t = d.lays[p.para].text
  if p.off < t.len: RichPos(para: p.para, off: clusterAfter(t, p.off))
  elif p.para < d.paras.high: RichPos(para: p.para + 1, off: 0)
  else: p

proc prevPos(d: RichDoc; p: RichPos): RichPos =
  if p.off > 0: RichPos(para: p.para, off: clusterBefore(d.lays[p.para].text, p.off))
  elif p.para > 0: RichPos(para: p.para - 1, off: d.lays[p.para - 1].text.len)
  else: p

proc wordNext(d: RichDoc; p: RichPos): RichPos =
  let t = d.lays[p.para].text
  if p.off < t.len: RichPos(para: p.para, off: wordRight(t, p.off))
  elif p.para < d.paras.high: RichPos(para: p.para + 1, off: 0)
  else: p

proc wordPrev(d: RichDoc; p: RichPos): RichPos =
  if p.off > 0: RichPos(para: p.para, off: wordLeft(d.lays[p.para].text, p.off))
  elif p.para > 0: RichPos(para: p.para - 1, off: d.lays[p.para - 1].text.len)
  else: p

proc wordSpan(d: RichDoc; at: RichPos): tuple[a, b: RichPos] =
  ## What a double click at `at` selects: the word and the spaces after it
  ## (between words: one character).
  let t = d.lays[at.para].text
  var a = at.off
  var b = at.off
  if b < t.len and wordChar(t[b]) or a > 0 and wordChar(t[a - 1]):
    while a > 0 and wordChar(t[a - 1]): dec a
    while b < t.len and wordChar(t[b]): inc b
    while b < t.len and t[b] == ' ': inc b
  elif b < t.len: b = runeAfter(t, b)
  (RichPos(para: at.para, off: a), RichPos(para: at.para, off: b))

proc lineStep(d: RichDoc; p: RichPos; dir, x: int): RichPos =
  ## A line up (`dir` -1) or down, as near to `x` as there is.
  var pi = p.para
  var li = lineAt(d.lays[pi], p.off) + dir
  if li < 0:
    if pi == 0: return RichPos()
    dec pi
    li = d.lays[pi].lines.high
  elif li > d.lays[pi].lines.high:
    if pi == d.paras.high: return docEnd(d)
    inc pi
    li = 0
  RichPos(para: pi, off: hitLine(d.lays[pi], li, x))

proc lineHome(d: RichDoc; p: RichPos): RichPos =
  let l = d.lays[p.para]
  RichPos(para: p.para, off: int(l.lines[lineAt(l, p.off)].a))

proc lineEndOf(d: RichDoc; p: RichPos): RichPos =
  let l = d.lays[p.para]
  let li = lineAt(l, p.off)
  let ln = l.lines[li]
  var e = int(ln.b)
  if li < l.lines.high and ln.b > ln.a: e = runeBefore(l.text, int(ln.b))
  RichPos(para: p.para, off: e)

# ---- the keys' work ------------------------------------------------------------------------------

proc typeIn(d: var RichDoc; t: string) =
  ## Typed text in place of the selection, in the typing style.
  let (a, b) = selRange(d)
  let st = typingStyle(d)
  let fresh = a != b or (t[0] != ' ' and d.lastTyped == ' ')
  recording(d, a.para, b.para, ekTyping, fresh):
    if a != b: deleteRange(d, a, b)
    insertRuns(d.paras[a.para], a.off, [RichRun(text: t, style: st)])
    d.caret = RichPos(para: a.para, off: a.off + t.len)
    d.anchor = d.caret
  d.lastTyped = t[^1]
  d.hasTyping = false
  d.typingWord = true

proc deleteSel(d: var RichDoc) =
  let (a, b) = selRange(d)
  if a == b: return
  recording(d, a.para, b.para, ekOther, true):
    deleteRange(d, a, b)
    d.caret = a
    d.anchor = a
  d.hasTyping = false

proc enterKey(d: var RichDoc) =
  ## Enter: a new paragraph. On an empty list item or quote line: out of
  ## the list or the quote (a level at a time).
  let (a, b) = selRange(d)
  let p = d.paras[a.para]
  if a == b and paraLen(p) == 0 and p.kind in {pkBullet, pkNumber, pkQuote}:
    recording(d, a.para, a.para, ekOther, true):
      if d.paras[a.para].level > 0: dec d.paras[a.para].level
      else: d.paras[a.para].kind = pkNormal
    return
  recording(d, a.para, b.para, ekOther, true):
    if a != b: deleteRange(d, a, b)
    splitPara(d, a)
    d.caret = RichPos(para: a.para + 1, off: 0)
    d.anchor = d.caret
  d.lastTyped = ' '
  d.typingWord = false

proc backspaceKey(d: var RichDoc; word: bool) =
  ## Backspace: the selection, or the character (word) before the caret --
  ## a mark on its own, so an Arabic vowel comes off its letter --; at a
  ## list item's start its bullet first, then its indent, then the
  ## paragraph joins the one before.
  let (a, b) = selRange(d)
  if a != b:
    deleteSel(d)
    return
  let c = a
  let p = d.paras[c.para]
  if c.off == 0:
    if p.kind in {pkBullet, pkNumber, pkQuote}:
      recording(d, c.para, c.para, ekOther, true):
        d.paras[c.para].kind = pkNormal
        if p.kind == pkQuote: d.paras[c.para].level = 0
    elif p.kind == pkNormal and p.level > 0:
      recording(d, c.para, c.para, ekOther, true):
        dec d.paras[c.para].level
    elif c.para > 0:
      let prev = d.paras[c.para - 1]
      if paraLen(prev) == 0:
        # (an empty paragraph before: it goes, this one keeps its kind)
        recording(d, c.para - 1, c.para, ekOther, true):
          d.paras.delete(c.para - 1)
          d.caret = RichPos(para: c.para - 1, off: 0)
          d.anchor = d.caret
      else:
        let to = RichPos(para: c.para - 1, off: paraLen(prev))
        recording(d, c.para - 1, c.para, ekOther, true):
          deleteRange(d, to, c)
          d.caret = to
          d.anchor = to
    return
  let t = paraText(p)
  let from0 = RichPos(para: c.para, off: if word: wordLeft(t, c.off) else: runeBefore(t, c.off))
  recording(d, c.para, c.para, ekDeleting, word):
    deleteRange(d, from0, c)
    d.caret = from0
    d.anchor = from0
  d.hasTyping = false
  d.typingWord = true

proc deleteKey(d: var RichDoc; word: bool) =
  ## Delete: the selection, or the letter (with its marks) or word after
  ## the caret; at a paragraph's end the next one joins it.
  let (a, b) = selRange(d)
  if a != b:
    deleteSel(d)
    return
  let c = a
  let p = d.paras[c.para]
  let t = paraText(p)
  if c.off >= t.len:
    if c.para >= d.paras.high: return
    if t.len == 0:
      recording(d, c.para, c.para + 1, ekOther, true):
        d.paras.delete(c.para)
    else:
      recording(d, c.para, c.para + 1, ekOther, true):
        deleteRange(d, c, RichPos(para: c.para + 1, off: 0))
    return
  let to = RichPos(para: c.para, off: if word: wordRight(t, c.off) else: clusterAfter(t, c.off))
  recording(d, c.para, c.para, ekDeleting, word):
    deleteRange(d, c, to)
  d.hasTyping = false

proc copySel(d: RichDoc) =
  let (a, b) = selRange(d)
  if a == b: return
  let f = fragment(d, a, b)
  richClip = (plainOf(f), f)
  putClipboardText(richClip.plain)

proc pasteHere(d: var RichDoc) =
  let t = cleanText(plainLetters(getClipboardText()))
  if t.len > 0 and t == richClip.plain: richInsertDoc(d, richClip.doc)
  else: richInsert(d, t)

proc askLink(d: var RichDoc) =
  ## Opens the link dialog for the selection.
  fixup(d)
  let (a, _) = selRange(d)
  let lk = linkAround(d, a)
  let s = richState(d)
  d.linkUrl = if lk.ok: lk.url elif s.link.len > 0: s.link else: ""
  d.linkHad = d.linkUrl.len > 0
  d.linkAsk = true
  focusFirstText(inDialog = true)

proc richAskLink*(d: var RichDoc) =
  ## Opens the small dialog that asks for a link's address (as Ctrl+K and
  ## the tool bar's button do); the editor draws it.
  askLink(d)

proc linkDialog(d: var RichDoc) =
  ## The dialog `askLink` opened (drawn once a frame, by the editor or the
  ## tool bar, whichever comes first).
  if not d.linkAsk or d.linkFrame == ui.frameNo: return
  d.linkFrame = ui.frameNo
  var ok, remove = false
  dialog(d.linkAsk, "Link", 400):
    label "&Address (a web page, or an e-mail address):"
    edit d.linkUrl
    row:
      spring()
      if button("OK", isDefault = true, w = dp(80)): ok = true
      if d.linkHad and button("&Remove", w = dp(80)): remove = true
      if button("Cancel", w = dp(80)): d.linkAsk = false
  if ok or remove:
    d.linkAsk = false
    richLink(d, if remove: "" else: d.linkUrl)

# ---- drawing ----------------------------------------------------------------------------------------

proc inkOf(s: RichStyle; enabled: bool): Color =
  ## A run's color on the field (a dark field: dark colors lightened).
  if not enabled: return th.gray
  if s.color.a != 0:
    let f = lumaOfColor(th.field)
    if f < 128 and abs(lumaOfColor(s.color) - f) < 80:
      return mixColor(s.color, th.fieldText, 0.6)
    return s.color
  if s.link.len > 0: th.link else: th.fieldText

proc numbering(d: RichDoc): seq[int] =
  ## Each numbered item's number (lists restart after other paragraphs).
  result = newSeq[int](d.paras.len)
  var counters: array[MaxLevel + 1, int]
  for i, p in d.paras:
    case p.kind
    of pkNumber, pkBullet:
      let lv = clamp(p.level, 0, MaxLevel)
      for k in lv + 1 .. MaxLevel: counters[k] = 0
      if p.kind == pkNumber:
        inc counters[lv]
        result[i] = counters[lv]
      else: counters[lv] = 0
    else:
      for c in counters.mitems: c = 0

proc drawMarker(p: RichPara; l: ParaLay; x0, py, num: int; ink: Color) =
  ## A list item's bullet or number.
  let ln = l.lines[0]
  let st = TextStyle(size: l.st0.size, bold: p.kind == pkHeading)
  let gap = dp(6)
  if p.kind == pkNumber:
    let s = if l.rtl: "." & $num else: $num & "."
    let tw = textWidth(s, st)
    let x = if l.rtl: x0 + l.textR + gap else: x0 + l.textL - gap - tw
    text(x, py + ln.base - ascOf(st), s, ink, st)
  else:
    let asc = ascOf(st)
    let r = max(2.0, float(lineHeight(st)) / 7.0)
    let cx = float(if l.rtl: x0 + l.textR + gap + dp(4) else: x0 + l.textL - gap - dp(4))
    let cy = float(py + ln.base) - float(asc) * 0.36
    case p.level mod 3
    of 0: disc(cx, cy, r, ink)
    of 1: ring(cx, cy, r, max(1.0, r / 2.5), ink)
    else:
      let s = int(r * 1.6)
      fill(rect(int(cx) - s div 2, int(cy) - s div 2, s, s), ink)

proc squiggle(x, y, w: int; c: Color; clip: Rect) =
  ## Word's wavy line under `w` pixels from `x` (its top at `y`); the waves
  ## keep their places on the screen, so pieces of a word join up.
  if w <= 0: return
  let s = max(2, dp(2))
  let r = intersect(rect(x, y, w, s + 1), clip)
  if r.w <= 0 or r.h <= 0: return
  pushClip(r)
  var px = (x div s) * s
  var up = ((px div s) and 1) == 0
  while px < x + w:
    line(px, (if up: y + s else: y), px + s, (if up: y else: y + s), c)
    px += s
    up = not up
  popClip()

proc drawPara(d: RichDoc; pi: int; x0, py: int; clipR: Rect; num: int;
              selA, selB: RichPos; focused, enabled, spellOn: bool; typingAt: RichPos) =
  ## Paragraph `pi` at `x0`, `py`; `spellOn`: red lines under its misspelled
  ## words, but the one being typed at `typingAt`.
  let l = d.lays[pi]
  template p: untyped = d.paras[pi]
  let ink = if enabled: th.fieldText else: th.gray
  case p.kind
  of pkBullet, pkNumber: drawMarker(p, l, x0, py, num, ink)
  of pkQuote:
    let bar = mixColor(th.field, th.fieldText, 0.45)
    let bw = max(2, dp(2))
    let right = x0 + l.textR + indentOf(p)       # (an Arabic quote: bars at the right)
    for k in 0 .. p.level:
      let x = if l.rtl: right - k * quoteStep() - dp(1) - bw
              else: x0 + k * quoteStep() + dp(1)
      fill(rect(x, py, bw, l.h), bar)
  else: discard
  # the selection in this paragraph
  var sa, sb = -1
  var pastEnd = false
  if selA != selB and selA.para <= pi and pi <= selB.para:
    sa = if pi == selA.para: selA.off else: 0
    sb = if pi == selB.para: selB.off else: l.text.len
    pastEnd = pi < selB.para
  let selBg = if focused: th.select else: mixColor(th.field, th.select, 0.22)
  let bad = if spellOn: badIn(d, pi) else: @[]
  let red = if lumaOfColor(th.field) < 128: color(255, 96, 96) else: color(255, 0, 0)
  for li, ln in l.lines:
    let ly = py + ln.y
    if ly + ln.h < clipR.y or ly > clipR.y + clipR.h: continue
    var spans: seq[Rect]
    if sa >= 0:
      for k in ln.p0 ..< ln.p1:
        let pc = l.pieces[k]
        let oa = max(int(pc.a), sa)
        let ob = min(int(pc.b), sb)
        if ob > oa:
          let xa = x0 + pieceX(l, pc, oa)
          let xb = x0 + pieceX(l, pc, ob)
          let r = rect(min(xa, xb), ly, abs(xb - xa), int(ln.h))
          fill(r, selBg)
          spans.add r
      if pastEnd and li == l.lines.high:
        let ex = x0 + (if ln.p0 == ln.p1: int(ln.x0) else: caretX(l, li, l.text.len))
        fill(rect(if l.rtl: ex - dp(5) else: ex, ly, dp(5), int(ln.h)), selBg)
    for k in ln.p0 ..< ln.p1:
      let pc = l.pieces[k]
      let s = pieceText(l.text, pc.a, pc.b)
      let col = inkOf(p.runs[pc.run].style, enabled)
      text(x0 + pc.x, ly + ln.base - pc.asc, s, col, pc.st)
      if focused and spans.len > 0:
        for r in spans:
          let c = intersect(r, rect(x0 + pc.x, ly, pc.w, int(ln.h)))
          if c.w > 0:
            pushClip(intersect(c, clipR))
            text(x0 + pc.x, ly + ln.base - pc.asc, s, th.selectText, pc.st)
            popClip()
    # the misspelled words' red lines (right to left pieces measure from their right)
    for (wa, wb) in bad:
      if wb <= ln.a or wa >= max(ln.b, ln.a + 1): continue
      if typingAt.para == pi and wa < typingAt.off and typingAt.off <= wb: continue
      for k in ln.p0 ..< ln.p1:
        let pc = l.pieces[k]
        let oa = max(pc.a, wa)
        let ob = min(pc.b, wb)
        if ob > oa:
          let xa = x0 + pieceX(l, pc, int(oa))
          let xb = x0 + pieceX(l, pc, int(ob))
          squiggle(min(xa, xb), ly + ln.base + 1, abs(xb - xa), red, clipR)

# ---- the editor ---------------------------------------------------------------------------------

proc linkAt(d: RichDoc; x, y: int): string =
  ## (the link at `x`, `y` of the text's box as drawn: kept as it reads)
  if d.lays.len != d.paras.len or d.lays.len == 0: return
  let cx = x - d.origin.x
  let cy = y - d.origin.y
  if cy < 0 or cy >= d.tops[^1]: return
  let at = posAt(d, cx, cy)
  let l = d.lays[at.para]
  let li = lineAt(l, at.off)
  let ln = l.lines[li]
  for k in ln.p0 ..< ln.p1:
    let pc = l.pieces[k]
    if cx >= pc.x and cx < pc.x + pc.w:
      return d.paras[at.para].runs[pc.run].style.link

proc richLinkAt*(d: RichDoc; x, y: int): string =
  ## The address of the link at the window's point `x`, `y` in the editor
  ## drawn last ("" when there is none).
  let lx = if ui.rtl and d.box.w > 0: 2 * d.box.x + d.box.w - 1 - x else: x
  linkAt(d, lx, y)

proc richClickedLink*(d: RichDoc): string =
  ## The link Ctrl+clicked (or chosen with "Open link" in the editor's
  ## menu) this frame: its address, for the app to open; "" when none.
  d.clicked

proc richCaretRect*(d: RichDoc): Rect =
  ## Where the caret was drawn last (the window's coordinates): for a
  ## suggestion list under it.
  d.caretBox

proc richFocused*(d: RichDoc): bool =
  ## The editor of `d` had the keyboard focus when drawn last.
  d.focusedNow

proc enterAndFix(d: var RichDoc) =
  ## Enter, then AutoCorrect on the paragraph it ended.
  let n0 = d.paras.len
  let (a, b) = selRange(d)
  enterKey(d)
  if a == b and d.paras.len == n0 + 1: autoFix(d, enter = true)

proc completeChar(t: string): bool =
  ## `t` ends with a whole character (typed text comes a byte at a time).
  var k = t.len - 1
  while k > 0 and (t[k].uint8 and 0xC0) == 0x80: dec k
  let b = t[k].uint8
  let n = if b < 0x80: 1 elif b >= 0xF0: 4 elif b >= 0xE0: 3 elif b >= 0xC0: 2 else: 1
  k + n == t.len

proc pickSpell(d: var RichDoc; at: RichPos) =
  ## The misspelled word at `at` for the menu, with its suggestions.
  d.spellHit = (-1, 0, 0, "", @[])
  if not d.spell or at.para < 0 or at.para >= d.paras.len: return
  for (a, b) in badIn(d, at.para):
    if a <= at.off and at.off <= b:
      let word = paraText(d.paras[at.para])[a ..< b]
      d.spellHit = (at.para, int(a), int(b), word, spellSuggest(word, d.spellLang))
      return

proc spellFix(d: var RichDoc; by: string) =
  ## The menu's word becomes `by` (when it is still there).
  let h = d.spellHit
  d.spellHit.word = ""
  if h.word.len == 0 or h.para >= d.paras.len: return
  let t = paraText(d.paras[h.para])
  if h.b <= t.len and t[h.a ..< h.b] == h.word:
    replaceIn(d, h.para, h.a, h.b, by, true)

proc richEdit*(d: var RichDoc; height = -1; key = ""; placeholder = "";
               enabled = true): bool {.discardable.} =
  ## The rich text editor, `height` pixels high (-1: the height left in the
  ## window), bound to `d`: true when its text (or its formatting) changed
  ## this frame. `placeholder` shows while it is empty; `key` tells editors
  ## of the same document apart. Its menu (a right click, a long press):
  ## Undo, Cut, Copy, Paste, Link, Select all. In a right-to-left
  ## interface each paragraph keeps its own direction (Arabic at the right,
  ## English at the left), not mirrored with the frame.
  fixup(d)
  d.clicked = ""
  let minH = FontH + dp(16)
  let h = max(minH, if height < 0: remainingH() else: height)
  let r = place(0, h, fill = true)
  let id = if key.len > 0: idOf("richedit:" & key) else: idOf(d, "richedit")
  let area = rect(r.x, r.y, r.w - SbW, r.h)
  let inner = rect(area.x + 2, area.y + 2, max(1, area.w - 3), max(1, area.h - 3))
  let pad = dp(6)
  let cw = max(dp(40), inner.w - 2 * pad)
  ensureLayout(d, cw)
  let viewH = inner.h
  d.viewH = viewH
  template maxOff: int = max(0, d.tops[^1] + 2 * pad - viewH)
  var sy = clamp(d.scrollY, 0, maxOff)
  scrollBarFor(id + 9, id, rect(r.x + r.w - SbW, r.y, SbW, r.h), true, sy, maxOff,
               max(FontH, viewH - FontH), FontH, enabled)
  if enabled:
    scrollWheel(id, sy, maxOff, r, 3 * FontH)
    scrollPan(id, sy, maxOff, r)
  d.scrollY = sy
  if ui.textFocusWanted and enabled and canInput() and
     (not ui.textFocusInDialog or layer() >= LayerDialog):
    ui.textFocusWanted = false
    ui.focus = id
  let focusBefore = ui.focus
  d.box = area
  beginKeepSides(area)           # (the text as it reads, the mouse with it)
  var hit = interact(id, area, enabled = enabled)
  if hit.hover and canHover(): ui.cursor = curIbeam
  var tapAt = false
  if finger() and enabled:
    # a finger landing on the editor may be scrolling the page: it takes the
    # focus (and the keyboard comes up) when lifted there without moving
    if ui.pressed and ui.active == id and focusBefore != id:
      ui.focus = focusBefore
      hit.focused = false
      tapFocus = id
    elif hit.clicked and tapFocus == id:
      ui.focus = id
      hit.focused = true
      tapAt = true
      ui.redraw = true
    if not ui.mouseDown and not hit.clicked and tapFocus == id: tapFocus = 0
  let focused = hit.focused and enabled
  if focused and not d.focusedNow: caretT = ui.now
  d.focusedNow = focused
  let ox = inner.x + pad
  template oy: int = inner.y + pad - d.scrollY
  template mousePos: RichPos = posAt(d, ui.mx - ox, ui.my - oy)
  var moved = false
  var vert = false
  let dirty0 = d.dirty
  d.dirty = false
  if focused:
    ui.takesText = true
    ui.takesEnter = true
    let shift = ShiftPressed in ui.mods
    let ctrl = CtrlPressed in ui.mods
    # the mouse; a tap puts the caret where the finger was
    if tapAt:
      d.caret = mousePos
      d.anchor = d.caret
      moved = true
    elif ui.active == id and ui.pressed:
      let at = mousePos
      let lk = if ctrl: linkAt(d, ui.mx, ui.my) else: ""
      if lk.len > 0:
        d.clicked = lk
      else:
        d.caret = at
        if not shift: d.anchor = at
        d.unit = 0
        if ui.clicks == 2:
          let w = wordSpan(d, at)
          d.anchor = w.a
          d.caret = w.b
          d.unit = 1
          markDouble(id)
        elif ui.clicks >= 3:
          d.anchor = RichPos(para: at.para)
          d.caret = RichPos(para: at.para, off: d.lays[at.para].text.len)
          d.unit = 2
        d.unitA = d.anchor
        d.unitB = d.caret
        moved = true
    elif ui.active == id and ui.mouseDown and not ui.pressed and
         (ui.mouseMoved or ui.my < inner.y or ui.my >= inner.y + inner.h):
      # a drag selects: by characters, or by the words (paragraphs) a double
      # (triple) click began with
      let at = mousePos
      var na = d.anchor
      var nc = at
      if d.unit > 0:
        let w = if d.unit == 1: wordSpan(d, at)
                else: (a: RichPos(para: at.para),
                       b: RichPos(para: at.para, off: d.lays[at.para].text.len))
        if at < d.unitA:
          na = d.unitB
          nc = w.a
        else:
          na = d.unitA
          nc = if w.b < d.unitB: d.unitB else: w.b
      if nc != d.caret or na != d.anchor:
        d.caret = nc
        d.anchor = na
        moved = true
    if ui.active == id and ui.mouseDown and (ui.my < inner.y or ui.my >= inner.y + inner.h):
      wakeIn(40)
    # typing (what was typed this frame came before its key)
    if ui.typed.len > 0 and canInput():
      # (a line end typed, as some on-screen keyboards send Enter: Enter)
      # (AutoCorrect: each character typed on its own, the word it may end
      # looked at)
      var t = ""
      for i, c in ui.typed:
        if c in {'\n', '\r'}:
          if t.len > 0: typeIn(d, t)
          t.setLen(0)
          if c == '\n' or i + 1 >= ui.typed.len or ui.typed[i + 1] != '\n':
            ensureLayout(d, cw)
            enterAndFix(d)
        elif c.uint8 >= 32 and c != '\x7F':
          t.add c
          if d.autoCorrect and completeChar(t) and not c.isAlphaNumeric:
            typeIn(d, t)
            t.setLen(0)
            autoFix(d)
      if t.len > 0: typeIn(d, t)
      if d.dirty: ensureLayout(d, cw)
    # keys
    let (a0, b0) = selRange(d)
    let some = a0 != b0
    template moveTo(p: RichPos) =
      d.caret = p
      if not shift: d.anchor = d.caret
      moved = true
      ui.keyUsed = true
    if canInput() and not ui.keyUsed and ui.key != KeyNone:
      let rtlPara = d.lays[d.caret.para].rtl
      case ui.key
      of KeyLeft, KeyRight:
        let fwd = (ui.key == KeyRight) != rtlPara
        if not shift and some: moveTo(if fwd: b0 else: a0)
        elif fwd: moveTo(if ctrl: wordNext(d, d.caret) else: nextPos(d, d.caret))
        else: moveTo(if ctrl: wordPrev(d, d.caret) else: prevPos(d, d.caret))
      of KeyUp, KeyDown:
        let dir = if ui.key == KeyUp: -1 else: 1
        if ctrl:
          if dir < 0:
            moveTo(if d.caret.off > 0: RichPos(para: d.caret.para)
                   else: RichPos(para: max(0, d.caret.para - 1)))
          else:
            moveTo(if d.caret.para < d.paras.high: RichPos(para: d.caret.para + 1)
                   else: docEnd(d))
        else:
          let x = if d.goalX >= 0: d.goalX else: caretGeo(d, d.caret).x
          moveTo(lineStep(d, d.caret, dir, x))
          d.goalX = x
          vert = true
      of KeyPageUp, KeyPageDown:
        let g = caretGeo(d, d.caret)
        let x = if d.goalX >= 0: d.goalX else: g.x
        let delta = max(FontH, viewH - FontH) * (if ui.key == KeyPageUp: -1 else: 1)
        moveTo(posAt(d, x, g.y + g.h div 2 + delta))
        scrollStop(id)
        d.scrollY = clamp(d.scrollY + delta, 0, maxOff)
        d.goalX = x
        vert = true
      of KeyHome:
        moveTo(if ctrl: RichPos() else: lineHome(d, d.caret))
      of KeyEnd:
        moveTo(if ctrl: docEnd(d) else: lineEndOf(d, d.caret))
      of KeyBackspace:
        ui.keyUsed = true
        backspaceKey(d, ctrl)
      of KeyDelete:
        ui.keyUsed = true
        if shift and some:
          copySel(d)
          deleteSel(d)
        else: deleteKey(d, ctrl)
      of KeyInsert:
        ui.keyUsed = true
        if ctrl: copySel(d)
        elif shift: pasteHere(d)
      of KeyEnter:
        ui.keyUsed = true
        enterAndFix(d)
      of KeyF7:
        # the next misspelled word, its menu open
        if d.spell:
          ui.keyUsed = true
          if richNextMisspelled(d):
            moved = true
            d.spellMenu = true
          else: toast("The spelling check is complete.")
      of KeyTab:
        if not ctrl:
          var inList = false
          for pi in a0.para .. b0.para:
            if d.paras[pi].kind in {pkBullet, pkNumber}: inList = true
          if inList:
            ui.keyUsed = true
            richIndent(d, if shift: -1 else: 1)
      of KeyA:
        if ctrl:
          ui.keyUsed = true
          richSelectAll(d)
          moved = true
      of KeyC:
        if ctrl:
          ui.keyUsed = true
          copySel(d)
      of KeyX:
        if ctrl:
          ui.keyUsed = true
          copySel(d)
          deleteSel(d)
      of KeyV:
        if ctrl:
          ui.keyUsed = true
          pasteHere(d)
      of KeyZ:
        if ctrl:
          ui.keyUsed = true
          if shift: richRedo(d) else: richUndo(d)
      of KeyY:
        if ctrl:
          ui.keyUsed = true
          richRedo(d)
      of KeyB:
        if ctrl:
          ui.keyUsed = true
          richBold(d)
      of KeyI:
        if ctrl:
          ui.keyUsed = true
          richItalic(d)
      of KeyU:
        if ctrl:
          ui.keyUsed = true
          richUnderline(d)
      of KeyK:
        if ctrl:
          ui.keyUsed = true
          askLink(d)
      of Key7, Key8, Key9:
        if ctrl and shift:
          ui.keyUsed = true
          richList(d, case ui.key
                      of Key7: pkNumber
                      of Key8: pkBullet
                      else: pkQuote)
      of KeyLeftBracket, KeyRightBracket:
        if ctrl:
          ui.keyUsed = true
          richIndent(d, if ui.key == KeyLeftBracket: -1 else: 1)
      of KeyBackslash:
        if ctrl:
          ui.keyUsed = true
          richClearFormat(d)
      else: discard
    if not vert and (moved or d.dirty): d.goalX = -1
    if moved and not d.dirty:
      d.hasTyping = false
      d.typingWord = false
  let edited = d.dirty
  d.dirty = dirty0 or edited
  if edited or moved:
    caretT = ui.now
    fixup(d)
    ensureLayout(d, cw)
  # the caret in view
  let cg = caretGeo(d, d.caret)
  if edited or moved or d.reveal:
    d.reveal = false
    let nv = clamp(clamp(d.scrollY, cg.y + cg.h + 2 * pad - viewH, cg.y), 0, maxOff)
    if nv != d.scrollY:
      scrollStop(id)
      d.scrollY = nv
  var sy2 = d.scrollY
  scrollTick(id, sy2, maxOff)
  d.scrollY = clamp(sy2, 0, maxOff)
  # draw
  fill(area, th.field)
  fieldFrame(area, enabled)
  pushClip(inner)
  let y0 = oy
  d.origin = point(ox, y0)
  let vTop = d.scrollY - pad
  let vBot = vTop + viewH
  var pi = 0
  block:
    var lo = 0
    var hi = d.paras.high
    while lo < hi:
      let m = (lo + hi + 1) shr 1
      if d.tops[m] <= max(0, vTop): lo = m else: hi = m - 1
    pi = lo
  let nums = numbering(d)
  let (sa, sb) = selRange(d)
  let spellOn = d.spell and enabled and spellAvailable()
  let typingAt = if focused and d.typingWord and sa == sb: sa else: RichPos(para: -1)
  while pi < d.paras.len and d.tops[pi] < vBot:
    drawPara(d, pi, ox, y0 + d.tops[pi], inner, nums[pi], sa, sb, focused, enabled,
             spellOn, typingAt)
    inc pi
  if placeholder.len > 0 and d.paras.len == 1 and paraLen(d.paras[0]) == 0:
    let l = d.lays[0]
    let tw = textWidth(placeholder)
    let px = if l.rtl or textIsRtl(placeholder): ox + l.textR - tw else: ox + l.textL
    text(px, y0, placeholder, th.gray)
  d.caretBox = rect(globalX(ox + cg.x), y0 + cg.y, 1, cg.h)
  if focused and ui.active31 and (ui.now - caretT >= CaretBlinkFor or
                                 ((ui.now - caretT) div 530) mod 2 == 0):
    vline(ox + cg.x, y0 + cg.y, cg.h, th.fieldText)
  popClip()
  endKeepSides()
  template inBox(px: int): int =
    # (a point of the window in the text's box as drawn, and back)
    (if ui.rtl: 2 * area.x + area.w - 1 - px else: px)
  if focused and ui.active31 and ui.now - caretT < CaretBlinkFor:
    wakeIn(min(530 - (ui.now - caretT) mod 530, CaretBlinkFor - (ui.now - caretT)))
  # a link under the mouse: its address as a tip, a hand with Ctrl
  if enabled and hit.hover and canHover():
    let lk = richLinkAt(d, ui.mx, ui.my)
    if lk.len > 0:
      if CtrlPressed in ui.mods: ui.cursor = curHand
      ui.lastRect = rect(ui.mx - 2, ui.my - 2, 4, 4)
      tooltip(lk & "  (Ctrl+click to open)")
  # its menu: a right click, a long press, the menu key
  let menuKey = "richedit-menu:" & $uint32(id)
  if enabled and canInput() and ui.rpressed and mouseIn(area):
    ui.focus = id
    # (on a misspelled word: its corrections first; the menu key: the caret's)
    pickSpell(d, if ui.menuKey: clampPos(d, d.caret)
                 else: posAt(d, inBox(ui.mx) - ox, ui.my - y0))
    openPopupMenu(menuKey, ui.mx, ui.my)
  elif d.spellMenu:
    # F7 chose a word: its menu under it
    d.spellMenu = false
    let (a1, _) = selRange(d)
    pickSpell(d, a1)
    if d.spellHit.word.len > 0:
      let g = caretGeo(d, a1)
      openPopupMenu(menuKey, inBox(ox + g.x), y0 + g.y + g.h)
  if beginPopupMenuFor(menuKey):
    let (a1, b1) = selRange(d)
    let some = a1 != b1
    let lk = linkAround(d, a1)
    if d.spellHit.word.len > 0:
      # Word's: the suggestions in bold, Ignore All, Add to Dictionary
      let sugs = d.spellHit.sugs
      if sugs.len == 0: discard menuItem("(no spelling suggestions)", enabled = false)
      let bold0 = boldMenus
      boldMenus = true
      var pick = ""
      for s in sugs:
        if menuItem(s.replace("&", "&&")): pick = s
      boldMenus = bold0
      menuSeparator()
      if menuItem("&Ignore All"):
        spellIgnore(d.spellHit.word)
        d.spellHit.word = ""
      if menuItem("&Add to Dictionary"):
        spellAdd(d.spellHit.word)
        d.spellHit.word = ""
      if sugs.len > 0:
        submenu("AutoCorr&ect"):
          # (a suggestion chosen here is used from now on as one types)
          for s in sugs:
            if menuItem(s.replace("&", "&&")):
              autoCorrectAdd(d.spellHit.word, s)
              pick = s
      menuSeparator()
      if pick.len > 0: spellFix(d, pick)
    if menuItem("&Undo", "Ctrl+Z", enabled = d.undos.len > 0): richUndo(d)
    if menuItem("&Redo", "Ctrl+Y", enabled = d.redos.len > 0): richRedo(d)
    menuSeparator()
    if menuItem("Cu&t", "Ctrl+X", enabled = some):
      copySel(d)
      deleteSel(d)
    if menuItem("&Copy", "Ctrl+C", enabled = some): copySel(d)
    if menuItem("&Paste", "Ctrl+V"): pasteHere(d)
    if menuItem("&Delete", "Del", enabled = some): deleteSel(d)
    menuSeparator()
    if menuItem("&Link...", "Ctrl+K"): askLink(d)
    if lk.ok:
      if menuItem("&Open link"): d.clicked = lk.url
      if menuItem("Remove lin&k"): richLink(d, "")
    menuSeparator()
    # (S: A is Add to Dictionary's when a word is misspelled)
    if menuItem("&Select all", "Ctrl+A", enabled = d.paras.len > 1 or paraLen(d.paras[0]) > 0):
      richSelectAll(d)
    endMenu()
  linkDialog(d)
  if accessOn:
    # (its text, the caret and the selection counted in characters)
    let (sa, sb) = selRange(d)
    accessNameOr(tr(placeholder))
    let k = accessNode(arTextArea, value = plainOf(d), id = id, r = area,
                       states = accessOff(enabled) + {asMultiLine})
    accessText(k, charsAt(d, clampPos(d, d.caret)), charsAt(d, sa), charsAt(d, sb))
  ui.lastId = id
  ui.lastRect = area
  result = d.dirty
  d.dirty = false

# ---- the tool bar --------------------------------------------------------------------------------

proc dropFace(r: Rect; down, enabled: bool) =
  buttonFace(r, down, bevel = 1, hot = enabled and hovered(r))
  if down: checker(inset(r, 2), th.light)

proc colorPopup(d: var RichDoc; id: Id; at: Rect; cur: Color) =
  ## The colors the color button drops down: Automatic and the 16 VGA ones.
  let cell = max(dp(18), FontH + dp(4))
  let cols = 4
  let autoH = ItemH + dp(2)
  let w = cols * cell + dp(8)
  let h = autoH + 4 * cell + dp(10)
  var pr = rect(at.x, at.y + at.h, w, h)
  if pr.y + pr.h > ui.h: pr.y = max(0, at.y - h)
  if pr.x + pr.w > ui.w: pr.x = max(0, ui.w - w)
  pushLayer(LayerPopup)
  ui.popupRectNow = pr
  fill(pr, th.face)
  box(pr, th.frame)
  raisedFace(inset(pr, 1), 1)
  let ar = rect(pr.x + dp(4), pr.y + dp(4), pr.w - dp(8), autoH)
  let ah = interact(id + 2, ar, focusable = false)
  let autoOn = cur.a == 0
  if ah.hover or autoOn: fill(ar, if ah.hover: th.select else: mixColor(th.face, th.light, 0.5))
  let sw = rect(ar.x + dp(3), ar.y + (ar.h - dp(10)) div 2, dp(10), dp(10))
  fill(sw, th.fieldText)
  box(sw, th.frame)
  text(sw.x + sw.w + dp(6), ar.y + (ar.h - FontH) div 2, "Automatic",
       if ah.hover: th.selectText else: th.text)
  if ah.clicked:
    richColor(d, Color())
    ui.popup = 0
  for i, (name, c) in richColors:
    let cr = rect(pr.x + dp(4) + (i mod cols) * cell,
                  pr.y + dp(6) + autoH + (i div cols) * cell, cell, cell)
    let ch = interact(id + 3 + uint32(i), cr, focusable = false)
    if cur.a != 0 and cur.r == c.r and cur.g == c.g and cur.b == c.b:
      box(cr, th.text)
      box(inset(cr, 1), th.light)
    elif ch.hover: box(cr, th.shadow)
    fill(inset(cr, 3), c)
    box(inset(cr, 3), th.frame)
    ui.lastRect = cr
    tooltip(name)
    if ch.clicked:
      richColor(d, c)
      ui.popup = 0
  if keyHit(KeyEsc): ui.popup = 0
  popLayer()

proc colorButton(d: var RichDoc; s: RichStyle) =
  ## The text color button: an "A" over a bar of the color; its arrow drops
  ## the colors down.
  let r = place(CtrlH + dp(12), CtrlH - 1)
  let id = idOf("rich-color")
  let hit = interact(id, r, focusable = false)
  let open = ui.popup == id + 1
  dropFace(r, hit.down or open, true)
  let o = if hit.down or open: 1 else: 0
  let st = style(bold = true)
  let bw = dp(14)
  let bx = r.x + dp(4) + o
  text(bx + (bw - textWidth("A", st)) div 2, r.y + dp(2) + o, "A", th.text, st)
  let c = if s.color.a == 0: th.fieldText else: s.color
  let bar = rect(bx, r.y + r.h - dp(7) + o, bw, max(3, dp(4)))
  fill(bar, c)
  box(bar, th.shadow)
  arrow(r.x + r.w - dp(6) + o, r.y + r.h div 2 + o, dDown, th.text)
  if accessOn:
    accessNode(arButton, "Text color", id = id, r = r,
               states = {asExpandable} + (if open: {asExpanded} else: {}))
  ui.lastRect = r
  tooltip("Text color")
  if hit.clicked:
    ui.popup = if open: 0 else: id + 1
    ui.menuOpen = false
    ui.redraw = true
  if ui.popup == id + 1: colorPopup(d, id + 1, r, s.color)

proc sizeButton(d: var RichDoc; s: RichStyle) =
  ## The size button: Small, Normal, Large, Huge in a menu.
  let r = place(CtrlH + dp(12), CtrlH - 1)
  let key = "rich-size"
  let id = idOf(key)
  let hit = interact(id, r, focusable = false)
  let open = popupMenuOpen(key)
  dropFace(r, hit.down or open, true)
  let o = if hit.down or open: 1 else: 0
  let st = style(size = 1.15)
  let g = nfFormatSize
  text(r.x + dp(4) + o, r.y + (r.h - lineHeight(st)) div 2 + o, g, th.text, st)
  arrow(r.x + r.w - dp(6) + o, r.y + r.h div 2 + o, dDown, th.text)
  if accessOn:
    accessNode(arButton, "Text size", id = id, r = r,
               states = {asExpandable} + (if open: {asExpanded} else: {}))
  ui.lastRect = r
  tooltip("Text size")
  if hit.clicked: openPopupMenu(key, r.x, r.y + r.h)
  popupMenu(key):
    for (name, k) in richSizes:
      if menuItem(name, checked = abs(sizeOf(s) - k) < 0.01): richSize(d, k)

proc alignFor(d: RichDoc; visual: Align): Align =
  ## The alignment a button that shows `visual` (left, center, right) means
  ## for the caret's paragraph (an Arabic one starts at the right).
  if d.paras.len == 0 or visual == alCenter: return visual
  let rtl = textIsRtl(paraText(d.paras[clampPos(d, d.caret).para]))
  if not rtl: visual
  elif visual == alLeft: alRight
  else: alLeft

proc richToolbar*(d: var RichDoc; compact = false) =
  ## A row of formatting buttons for `d`'s editor: bold, italic, underline,
  ## strikethrough, monospace, the text color and size, bullets, numbers,
  ## a quote, indents, alignment, a link (asked for in a small dialog) and
  ## plain text again; pressed for what the caret has. `compact` (phones):
  ## the most used ones, the rest in a "more" menu.
  fixup(d)
  let s = richState(d)
  let pk = richParaKind(d)
  let al = richAlignment(d)
  let gs = 1.15
  row:
    if toolButton(pxFauxBold, "Bold (Ctrl+B)", down = s.bold): richBold(d)
    if toolButton(pxFauxItalic, "Italic (Ctrl+I)", down = s.italic): richItalic(d)
    if toolButton(pxUnderline, "Underline (Ctrl+U)", down = s.underline): richUnderline(d)
    if not compact:
      if toolButton(pxStrikethrough, "Strikethrough", down = s.strike): richStrike(d)
      if toolButton(nfCode, "Monospace", down = s.mono, size = gs): richMono(d)
    colorButton(d, s)
    if not compact: sizeButton(d, s)
    toolSeparator()
    if toolButton(nfListUl, "Bullets (Ctrl+Shift+8)", down = pk == pkBullet, size = gs):
      richList(d, pkBullet)
    if not compact:
      if toolButton(nfListOl, "Numbering (Ctrl+Shift+7)", down = pk == pkNumber, size = gs):
        richList(d, pkNumber)
      if toolButton(nfQuote, "Quote (Ctrl+Shift+9)", down = pk == pkQuote, size = gs):
        richList(d, pkQuote)
      if toolButton(nfOutdent, "Decrease indent (Ctrl+[)", size = gs): richIndent(d, -1)
      if toolButton(nfIndent, "Increase indent (Ctrl+])", size = gs): richIndent(d, 1)
      toolSeparator()
      if toolButton(pxAlignLeft, "Align left", down = al == alignFor(d, alLeft)):
        richAlign(d, alignFor(d, alLeft))
      if toolButton(pxAlignCenter, "Center", down = al == alCenter): richAlign(d, alCenter)
      if toolButton(pxAlignRight, "Align right", down = al == alignFor(d, alRight)):
        richAlign(d, alignFor(d, alRight))
      toolSeparator()
    if toolButton(nfLink, "Link (Ctrl+K)", down = s.link.len > 0, size = gs): askLink(d)
    if not compact:
      if toolButton(nfEraser, "Clear formatting (Ctrl+\\)", size = gs): richClearFormat(d)
    else:
      let key = "rich-more"
      if toolButton(nfEllipsisV, "More", size = gs):
        let r = ui.lastRect
        openPopupMenu(key, r.x, r.y + r.h)
      popupMenu(key):
        if menuItem("Stri&kethrough", checked = s.strike): richStrike(d)
        if menuItem("&Monospace", checked = s.mono): richMono(d)
        submenu("&Size"):
          for (name, k) in richSizes:
            if menuItem(name, checked = abs(sizeOf(s) - k) < 0.01): richSize(d, k)
        menuSeparator()
        if menuItem("&Numbering", checked = pk == pkNumber): richList(d, pkNumber)
        if menuItem("&Quote", checked = pk == pkQuote): richList(d, pkQuote)
        if menuItem("&Increase indent"): richIndent(d, 1)
        if menuItem("&Decrease indent"): richIndent(d, -1)
        menuSeparator()
        if menuItem("Align &left", checked = al == alignFor(d, alLeft)):
          richAlign(d, alignFor(d, alLeft))
        if menuItem("&Center", checked = al == alCenter): richAlign(d, alCenter)
        if menuItem("Align &right", checked = al == alignFor(d, alRight)):
          richAlign(d, alignFor(d, alRight))
        menuSeparator()
        if menuItem("Clear &formatting"): richClearFormat(d)
        if menuItem("&Undo", enabled = d.undos.len > 0): richUndo(d)
        if menuItem("R&edo", enabled = d.redos.len > 0): richRedo(d)
  linkDialog(d)

# ---- HTML in ------------------------------------------------------------------------------------------

const
  MaxHtml = 4_000_000          ## bytes of HTML read (the rest is left out)
  MaxDepth = 96                ## elements in elements deeper than this are taken flat
  MaxTokens = 400_000
  MaxParas = 100_000
  BasePt = 11.0                ## the size "normal" text is in points (Outlook's)
  BasePx = BasePt * 96 / 72
  hBlocks = ["p", "div", "section", "article", "header", "footer", "main", "nav", "aside",
             "address", "figure", "figcaption", "center", "details", "summary", "dl", "dt",
             "dd", "fieldset", "legend", "form", "table", "caption", "thead", "tbody",
             "tfoot", "tr", "body", "html", "li", "ul", "ol", "menu", "dir", "blockquote",
             "pre", "h1", "h2", "h3", "h4", "h5", "h6", "listing", "xmp", "plaintext",
             "hgroup", "search"]
  hClosesP = ["address", "article", "aside", "blockquote", "center", "details", "div",
              "dl", "fieldset", "figcaption", "figure", "footer", "form", "h1", "h2", "h3",
              "h4", "h5", "h6", "header", "hr", "main", "nav", "ol", "p", "pre", "section",
              "summary", "table", "ul", "menu", "dir"]
  hSkip = ["head", "script", "style", "title", "template", "svg", "math", "object",
           "iframe", "noscript", "select", "textarea", "button", "xml", "noembed",
           "noframes", "applet", "canvas", "video", "audio", "map", "datalist", "option",
           "optgroup", "frameset"]
  hVoid = ["br", "img", "hr", "input", "meta", "link", "base", "col", "area", "wbr",
           "embed", "source", "track", "param", "keygen", "frame", "basefont", "isindex"]
  hRaw = ["script", "style", "title", "textarea", "xmp", "noembed", "noframes", "iframe",
          "plaintext"]
  hEntities = {"amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'",
               "nbsp": " ", "copy": "©", "reg": "®", "trade": "™", "hellip": "…",
               "mdash": "—", "ndash": "–", "lsquo": "‘", "rsquo": "’", "sbquo": "‚",
               "ldquo": "“", "rdquo": "”", "bdquo": "„", "laquo": "«", "raquo": "»",
               "bull": "•", "middot": "·", "times": "×", "divide": "÷", "deg": "°",
               "plusmn": "±", "euro": "€", "pound": "£", "yen": "¥", "cent": "¢",
               "sect": "§", "para": "¶", "shy": "", "zwnj": "‌", "zwj": "‍",
               "lrm": "‎", "rlm": "‏", "ensp": " ", "emsp": " ", "thinsp": " ",
               "larr": "←", "rarr": "→", "uarr": "↑", "darr": "↓", "hearts": "♥",
               "check": "✓", "frac12": "½", "frac14": "¼", "frac34": "¾", "iexcl": "¡",
               "iquest": "¿", "eacute": "é", "egrave": "è", "agrave": "à", "aacute": "á",
               "ccedil": "ç", "ouml": "ö", "uuml": "ü", "auml": "ä", "szlig": "ß",
               "ntilde": "ñ", "oacute": "ó", "iacute": "í", "uacute": "ú", "ecirc": "ê",
               "Eacute": "É", "Ouml": "Ö", "Uuml": "Ü", "Auml": "Ä"}.toTable
  hColors = {"black": (0, 0, 0), "white": (255, 255, 255), "red": (255, 0, 0),
             "green": (0, 128, 0), "blue": (0, 0, 255), "navy": (0, 0, 128),
             "maroon": (128, 0, 0), "purple": (128, 0, 128), "teal": (0, 128, 128),
             "olive": (128, 128, 0), "gray": (128, 128, 128), "grey": (128, 128, 128),
             "silver": (192, 192, 192), "lime": (0, 255, 0), "aqua": (0, 255, 255),
             "cyan": (0, 255, 255), "fuchsia": (255, 0, 255), "magenta": (255, 0, 255),
             "yellow": (255, 255, 0), "orange": (255, 165, 0), "brown": (165, 42, 42),
             "pink": (255, 192, 203), "darkred": (139, 0, 0), "darkblue": (0, 0, 139),
             "darkgreen": (0, 100, 0), "darkgray": (169, 169, 169),
             "darkgrey": (169, 169, 169), "lightgray": (211, 211, 211),
             "lightgrey": (211, 211, 211), "gold": (255, 215, 0), "indigo": (75, 0, 130),
             "violet": (238, 130, 238), "crimson": (220, 20, 60),
             "orangered": (255, 69, 0), "royalblue": (65, 105, 225),
             "steelblue": (70, 130, 180), "dimgray": (105, 105, 105),
             "dimgrey": (105, 105, 105), "darkorange": (255, 140, 0),
             "windowtext": (0, 0, 0)}.toTable

type
  TokKind = enum tkText, tkStart, tkEnd
  Tok = object
    kind: TokKind
    name, text: string
    attrs: seq[(string, string)]
    selfClose: bool

proc decodeEnt(t: string): string =
  ## `t` with its character references ("&amp;", "&#169;", "&#xA9;") replaced.
  if '&' notin t: return t
  var i = 0
  while i < t.len:
    let ch = t[i]
    if ch != '&':
      result.add ch
      inc i
      continue
    var j = i + 1
    if j < t.len and t[j] == '#':
      inc j
      var hex = false
      if j < t.len and t[j] in {'x', 'X'}:
        hex = true
        inc j
      var v = 0
      var n = 0
      while j < t.len and n < 8 and (if hex: t[j] in HexDigits else: t[j] in Digits):
        v = v * (if hex: 16 else: 10) +
            (if t[j] in Digits: ord(t[j]) - ord('0') else: ord(t[j].toLowerAscii) - ord('a') + 10)
        inc j
        inc n
      if n == 0:
        result.add ch
        inc i
        continue
      if j < t.len and t[j] == ';': inc j
      if v == 0 or v > 0x10FFFF or v in 0xD800 .. 0xDFFF: v = 0xFFFD
      result.add $Rune(v)
      i = j
      continue
    var name = ""
    while j < t.len and name.len < 32 and t[j].isAlphaNumeric:
      name.add t[j]
      inc j
    if hEntities.hasKey(name) and (j < t.len and t[j] == ';' or
                                   name in ["amp", "lt", "gt", "quot", "nbsp"]):
      result.add hEntities[name]
      i = if j < t.len and t[j] == ';': j + 1 else: j
    else:
      result.add ch
      inc i

proc findCI(s, what: string; start: int): int =
  ## `what` (lower case) in `s` from `start`, letters in any case.
  var i = start
  while i + what.len <= s.len:
    var k = 0
    while k < what.len and s[i + k].toLowerAscii == what[k]: inc k
    if k == what.len: return i
    inc i
  -1

proc htmlTokens(src: string): seq[Tok] =
  ## The tags and texts of `src`, as a forgiving reader takes them.
  let s = if src.len > MaxHtml: src[0 ..< MaxHtml] else: src
  var i = 0
  var textStart = 0
  template flushText(upTo: int) =
    if upTo > textStart: result.add Tok(kind: tkText, text: s[textStart ..< upTo])
  while i < s.len and result.len < MaxTokens:
    if s[i] != '<' or i + 1 >= s.len:
      inc i
      continue
    let c1 = s[i + 1]
    if s.continuesWith("<!--", i):
      flushText(i)
      let e = s.find("-->", i + 4)
      i = if e < 0: s.len else: e + 3
      textStart = i
    elif s.continuesWith("<![CDATA[", i):
      flushText(i)
      let e = s.find("]]>", i + 9)
      result.add Tok(kind: tkText, text: if e < 0: s[i + 9 .. ^1] else: s[i + 9 ..< e])
      i = if e < 0: s.len else: e + 3
      textStart = i
    elif c1 in {'!', '?'}:
      flushText(i)
      let e = s.find('>', i + 2)
      i = if e < 0: s.len else: e + 1
      textStart = i
    elif c1 == '/' and i + 2 < s.len and s[i + 2].isAlphaAscii:
      flushText(i)
      var j = i + 2
      var name = ""
      while j < s.len and (s[j].isAlphaNumeric or s[j] in {'-', ':'}) and name.len < 32:
        name.add s[j].toLowerAscii
        inc j
      let e = s.find('>', j)
      i = if e < 0: s.len else: e + 1
      result.add Tok(kind: tkEnd, name: name)
      textStart = i
    elif c1.isAlphaAscii:
      flushText(i)
      var j = i + 1
      var t = Tok(kind: tkStart)
      while j < s.len and (s[j].isAlphaNumeric or s[j] in {'-', ':'}) and t.name.len < 32:
        t.name.add s[j].toLowerAscii
        inc j
      while j < s.len:
        while j < s.len and s[j] in {' ', '\t', '\n', '\r', '\f'}: inc j
        if j >= s.len: break
        if s[j] == '>':
          inc j
          break
        if s[j] == '/':
          t.selfClose = j + 1 < s.len and s[j + 1] == '>'
          inc j
          continue
        var an = ""
        while j < s.len and s[j] notin {' ', '\t', '\n', '\r', '\f', '=', '>', '/'}:
          if an.len < 64: an.add s[j].toLowerAscii
          inc j
        if an.len == 0:
          inc j
          continue
        while j < s.len and s[j] in {' ', '\t', '\n', '\r', '\f'}: inc j
        var av = ""
        if j < s.len and s[j] == '=':
          inc j
          while j < s.len and s[j] in {' ', '\t', '\n', '\r', '\f'}: inc j
          if j < s.len and s[j] in {'"', '\''}:
            let q = s[j]
            let e = s.find(q, j + 1)
            let stop = if e < 0: s.len else: e
            av = s[j + 1 ..< stop]
            j = stop + 1
          else:
            let st = j
            while j < s.len and s[j] notin {' ', '\t', '\n', '\r', '\f', '>'}: inc j
            av = s[st ..< j]
        if t.attrs.len < 32 and av.len <= 100_000: t.attrs.add (an, decodeEnt(av))
      i = min(j, s.len)
      let name = t.name
      let raw = name in hRaw and not t.selfClose
      result.add t
      if raw:
        # its text up to its end tag, not read as HTML
        let e = findCI(s, "</" & name, i)
        result.add Tok(kind: tkText, text: if e < 0: s[i .. ^1] else: s[i ..< e])
        result.add Tok(kind: tkEnd, name: name)
        if e < 0: i = s.len
        else:
          let gt = s.find('>', e)
          i = if gt < 0: s.len else: gt + 1
      textStart = i
    else:
      inc i
  flushText(s.len)

type
  HElem = object
    name: string
    style: RichStyle
    blk, list, quote, indent, pre, skip: bool
    heading, align: int        ## -1: none (align: 0 left, 1 center, 2 right, 3 start, 4 end)
    mL, mR: int                ## indent levels its margins make
  HB = object
    paras: seq[RichPara]
    cur: RichPara
    started, lastSpace, preFresh: bool
    stack: seq[HElem]
    lists: seq[ParaKind]
    quotes, indents, pres, skips: int

proc attr(t: Tok; name: string): string =
  for (k, v) in t.attrs:
    if k == name: return v

proc topStyle(b: HB): RichStyle =
  if b.stack.len > 0: b.stack[^1].style else: RichStyle()

proc startPara(b: var HB) =
  b.cur = RichPara()
  var heading = -1
  for e in b.stack:
    if e.heading >= 0: heading = e.heading
  if b.lists.len > 0:
    b.cur.kind = b.lists[^1]
    b.cur.level = min(b.lists.len - 1, MaxLevel)
  elif heading >= 0:
    b.cur.kind = pkHeading
    b.cur.level = heading
  elif b.quotes > 0:
    b.cur.kind = pkQuote
    b.cur.level = min(b.quotes - 1, MaxLevel)
  else:
    b.cur.level = min(b.indents, MaxLevel)
  b.started = true
  b.lastSpace = false

proc addRun(b: var HB; s: string; st: RichStyle) =
  if not b.started:
    let sp = b.lastSpace
    startPara(b)
    b.lastSpace = sp
  if b.cur.runs.len > 0 and b.cur.runs[^1].style == st: b.cur.runs[^1].text.add s
  else: b.cur.runs.add RichRun(text: s, style: st)

proc flush(b: var HB; force: bool) =
  ## The paragraph being read ends (`force`: even an empty one: a `<br>`).
  if not b.started and not force: return
  if b.paras.len >= MaxParas:
    b.started = false
    return
  if not b.started:
    startPara(b)
    b.cur.runs = @[RichRun(style: topStyle(b))]
  if b.lastSpace and b.cur.runs.len > 0 and b.cur.runs[^1].text.endsWith(' '):
    b.cur.runs[^1].text.setLen(b.cur.runs[^1].text.len - 1)
  var spaces = true
  for r in b.cur.runs:
    for c in r.text:
      if c != ' ': spaces = false
  if spaces: b.cur.runs = @[RichRun(style: if b.cur.runs.len > 0: b.cur.runs[0].style else: RichStyle())]
  let rtl = textIsRtl(paraText(b.cur))
  var align = -1
  var margin = 0
  for e in b.stack:
    if e.align >= 0: align = e.align
    margin += (if rtl: e.mR else: e.mL)
  if b.cur.kind == pkNormal: b.cur.level = min(MaxLevel, b.cur.level + margin)
  b.cur.align =
    case align
    of 1: alCenter
    of 0: (if rtl: alRight else: alLeft)
    of 2: (if rtl: alLeft else: alRight)
    of 4: alRight
    else: alLeft
  tidy(b.cur)
  b.paras.add b.cur
  b.started = false
  b.lastSpace = false

proc addText(b: var HB; raw: string) =
  if b.skips > 0: return
  let t = decodeEnt(raw)
  let st = topStyle(b)
  var buf = ""
  if b.pres > 0:
    for ch in t:
      if ch == '\r': continue
      if ch == '\n':
        if b.preFresh:
          b.preFresh = false
          continue
        if buf.len > 0: addRun(b, buf, st)
        buf.setLen(0)
        flush(b, true)
        continue
      b.preFresh = false
      if ch == '\t': buf.add "    " else: buf.add ch
    if buf.len > 0: addRun(b, buf, st)
    return
  var i = 0
  while i < t.len:
    let ch = t[i]
    if ch in {' ', '\t', '\n', '\r', '\f'}:
      if (b.started or buf.len > 0) and not b.lastSpace:
        buf.add ' '
        b.lastSpace = true
      inc i
    elif ch == '\xC2' and i + 1 < t.len and t[i + 1] == '\xA0':
      buf.add ' '                 # (a no-break space: one that stays)
      b.lastSpace = false
      i += 2
    elif ch.uint8 < 32:
      inc i
    else:
      buf.add ch
      b.lastSpace = false
      inc i
  if buf.len > 0: addRun(b, buf, st)

proc cssColor(v: string; c: var Color): bool =
  ## A CSS color ("#rgb", "#rrggbb", "rgb(...)", a name) into `c`; black is
  ## taken as the normal color (most mails say it of all their text).
  let v = v.strip.toLowerAscii
  if v.len == 0: return false
  var r, g, bb = 0
  if v[0] == '#':
    let h = v[1 .. ^1]
    try:
      if h.len in [3, 4]:
        r = parseHexInt(h[0] & h[0])
        g = parseHexInt(h[1] & h[1])
        bb = parseHexInt(h[2] & h[2])
      elif h.len in [6, 8]:
        r = parseHexInt(h[0 .. 1])
        g = parseHexInt(h[2 .. 3])
        bb = parseHexInt(h[4 .. 5])
      else: return false
    except ValueError: return false
  elif v.startsWith("rgb"):
    let a = v.find('(')
    let e = v.find(')')
    if a < 0: return false
    let inside = v[a + 1 ..< (if e < 0: v.len else: e)]
    var parts: seq[string]
    for p in inside.split({',', ' ', '/'}):
      if p.len > 0: parts.add p
    if parts.len < 3: return false
    var vals: array[4, float]
    for k in 0 ..< min(4, parts.len):
      var p = parts[k]
      let pct = p.endsWith("%")
      if pct: p = p[0 ..< ^1]
      try: vals[k] = parseFloat(p)
      except ValueError: return false
      if pct: vals[k] = vals[k] * (if k < 3: 2.55 else: 0.01)
    if parts.len >= 4 and vals[3] <= 0: return false
    r = int(vals[0])
    g = int(vals[1])
    bb = int(vals[2])
  elif hColors.hasKey(v):
    (r, g, bb) = hColors[v]
  else: return false
  c = color(uint8(clamp(r, 0, 255)), uint8(clamp(g, 0, 255)), uint8(clamp(bb, 0, 255)))
  if r == 0 and g == 0 and bb == 0: c = Color()
  true

proc numPart(v: string): tuple[n: float; unit: string; ok: bool] =
  var i = 0
  while i < v.len and v[i] in {'0' .. '9', '.', '-', '+'}: inc i
  if i == 0: return
  try:
    result.n = parseFloat(v[0 ..< i])
    result.unit = v[i .. ^1].strip
    result.ok = true
  except ValueError: discard

proc cssSize(v: string; parent: float): float =
  ## A CSS font size as a size of ours (1.0 normal; 0: not understood).
  let v = v.strip.toLowerAscii
  result =
    case v
    of "xx-small": 0.6
    of "x-small": 0.7
    of "small": 0.85
    of "medium": 1.0
    of "large": 1.5
    of "x-large": 2.0
    of "xx-large": 2.5
    of "xxx-large": 3.0
    of "smaller": parent * 0.85
    of "larger": parent * 1.2
    else:
      let (n, unit, ok) = numPart(v)
      if not ok or n <= 0: 0.0
      else:
        case unit
        of "pt": n / BasePt
        of "px", "": n / BasePx
        of "em": n * parent
        of "rem": n
        of "%": parent * n / 100
        of "in": n * 72 / BasePt
        of "cm": n * 72 / 2.54 / BasePt
        of "mm": n * 72 / 25.4 / BasePt
        of "pc": n * 12 / BasePt
        else: 0.0
  if result > 0: result = round(clamp(result, 0.5, 3.0) * 1000) / 1000

proc marginLevel(v: string): int =
  ## How many indent levels a margin is (40 pixels each).
  let (n, unit, ok) = numPart(v.strip.toLowerAscii)
  if not ok or n <= 0: return 0
  let px = case unit
    of "px", "": n
    of "pt": n * 96 / 72
    of "in": n * 96
    of "cm": n * 96 / 2.54
    of "mm": n * 96 / 25.4
    of "em", "rem": n * 16
    else: 0.0
  clamp(int(round(px / 40)), 0, MaxLevel)

proc fontSizeAttr(v: string): float =
  ## `<font size>`: 1 .. 7, or +n / -n from 3.
  let v = v.strip
  if v.len == 0: return 0
  var n = 0
  try:
    n = if v[0] in {'+', '-'}: 3 + parseInt(v) else: parseInt(v)
  except ValueError: return 0
  [0.7, 0.85, 1.0, 1.5, 1.75, 2.0, 2.5][clamp(n, 1, 7) - 1]

proc isMonoFamily(v: string): bool =
  let v = v.toLowerAscii
  for m in ["mono", "courier", "consolas", "menlo", "monaco", "lucida console", "fixed"]:
    if m in v: return true

proc applyCss(e: var HElem; css: string) =
  for decl in css.split(';'):
    let k = decl.find(':')
    if k < 0: continue
    let prop = decl[0 ..< k].strip.toLowerAscii
    var v = decl[k + 1 .. ^1].strip
    let imp = v.toLowerAscii.find("!important")
    if imp >= 0: v = v[0 ..< imp].strip
    let lv = v.toLowerAscii
    case prop
    of "color":
      var c: Color
      if cssColor(lv, c): e.style.color = c
    of "font-weight":
      if lv in ["bold", "bolder"]: e.style.bold = true
      elif lv in ["normal", "lighter"]: e.style.bold = false
      else:
        let (n, _, ok) = numPart(lv)
        if ok: e.style.bold = n >= 600
    of "font-style":
      if lv in ["italic", "oblique"]: e.style.italic = true
      elif lv == "normal": e.style.italic = false
    of "text-decoration", "text-decoration-line":
      if "underline" in lv: e.style.underline = true
      if "line-through" in lv: e.style.strike = true
      if lv == "none":
        e.style.underline = false
        e.style.strike = false
    of "font-family":
      if isMonoFamily(lv): e.style.mono = true
    of "font-size":
      let f = cssSize(lv, sizeOf(e.style))
      if f > 0: e.style.size = f
    of "text-align":
      e.align = case lv
        of "left": 0
        of "center": 1
        of "right": 2
        of "start", "justify": 3
        of "end": 4
        else: e.align
    of "margin-left":
      if e.blk and not e.indent: e.mL = marginLevel(lv)
    of "margin-right":
      if e.blk and not e.indent: e.mR = marginLevel(lv)
    of "margin":
      if e.blk and not e.indent:
        let p = strutils.splitWhitespace(lv)
        case p.len
        of 2, 3:
          e.mL = marginLevel(p[1])
          e.mR = e.mL
        of 4:
          e.mL = marginLevel(p[3])
          e.mR = marginLevel(p[1])
        else: discard
    of "display":
      if lv == "none": e.skip = true
    else: discard

proc cleanHref(h: string): string =
  result = h.strip
  var scheme = ""
  for c in result:
    if c == ':': break
    if c notin {' ', '\t', '\n', '\r'}: scheme.add c.toLowerAscii
    if scheme.len > 12: break
  if ':' in result and scheme in ["javascript", "vbscript", "data"]: result = ""; return

proc popElem(b: var HB) =
  let e = b.stack[^1]
  if e.blk and b.skips == 0: flush(b, false)
  discard b.stack.pop()
  if e.list and b.lists.len > 0: discard b.lists.pop()
  if e.quote: dec b.quotes
  if e.indent: dec b.indents
  if e.pre: dec b.pres
  if e.skip: dec b.skips
  if e.name in ["td", "th"] and b.skips == 0 and b.started and not b.lastSpace:
    addRun(b, " ", topStyle(b))
    b.lastSpace = true

proc closeTo(b: var HB; names: openArray[string]; bounds: openArray[string]): bool =
  ## Closes up to the nearest open element named one of `names`, unless an
  ## element in `bounds` comes first.
  for k in countdown(b.stack.high, 0):
    let n = b.stack[k].name
    if n in names:
      while b.stack.len > k: popElem(b)
      return true
    if n in bounds: return false

proc endTag(b: var HB; n: string) =
  if n == "br":
    flush(b, not b.started)
    return
  discard closeTo(b, [n], [])

proc startTag(b: var HB; t: Tok) =
  let n = t.name
  if n == "body":
    # (a head left open: closed now)
    while b.stack.len > 0: popElem(b)
    b.skips = 0
    return
  if b.skips > 0:
    if n notin hVoid and not t.selfClose and b.stack.len < MaxDepth:
      b.stack.add HElem(name: n, style: topStyle(b), heading: -1, align: -1)
    return
  # what this one closes first
  if n in hClosesP: discard closeTo(b, ["p"], ["li", "td", "th", "blockquote", "div"])
  case n
  of "li": discard closeTo(b, ["li"], ["ul", "ol", "menu", "dir", "table"])
  of "tr": discard closeTo(b, ["tr", "td", "th"], ["table"])
  of "td", "th": discard closeTo(b, ["td", "th"], ["tr", "table"])
  of "h1", "h2", "h3", "h4", "h5", "h6":
    discard closeTo(b, ["h1", "h2", "h3", "h4", "h5", "h6"], ["div", "li", "td", "blockquote"])
  of "a": discard closeTo(b, ["a"], ["td", "th", "table"])
  else: discard
  let blk = n in hBlocks
  if blk: flush(b, false)
  case n
  of "br":
    flush(b, not b.started)
    return
  of "hr", "img": return
  else:
    if n in hVoid: return
  var e = HElem(name: n, style: topStyle(b), heading: -1, align: -1, blk: blk)
  case n
  of "b", "strong", "th": e.style.bold = true
  of "i", "em", "cite", "dfn", "var", "address": e.style.italic = true
  of "u", "ins": e.style.underline = true
  of "s", "strike", "del": e.style.strike = true
  of "code", "tt", "kbd", "samp": e.style.mono = true
  of "pre", "listing", "xmp", "plaintext":
    e.style.mono = true
    e.pre = true
    inc b.pres
    b.preFresh = true
  of "small": e.style.size = round(sizeOf(e.style) * 0.85 * 1000) / 1000
  of "big": e.style.size = round(sizeOf(e.style) * 1.2 * 1000) / 1000
  of "a":
    let h = cleanHref(t.attr("href"))
    if h.len > 0: e.style.link = h
  of "font":
    var c: Color
    if cssColor(t.attr("color"), c): e.style.color = c
    let f = fontSizeAttr(t.attr("size"))
    if f > 0: e.style.size = f
    if isMonoFamily(t.attr("face")): e.style.mono = true
  of "ul", "menu", "dir":
    e.list = true
    b.lists.add pkBullet
  of "ol":
    e.list = true
    b.lists.add pkNumber
  of "blockquote":
    let css = t.attr("style").toLowerAscii.replace(" ", "")
    if "border:none" in css or "border:0" in css:
      e.indent = true                 # (Gmail's indent)
      inc b.indents
    else:
      e.quote = true
      inc b.quotes
  of "h1", "h2", "h3", "h4", "h5", "h6": e.heading = min(2, ord(n[1]) - ord('1'))
  of "center": e.align = 1
  else: discard
  if blk:
    case t.attr("align").toLowerAscii
    of "left": e.align = 0
    of "center", "middle": e.align = 1
    of "right": e.align = 2
    else: discard
  if n in hSkip: e.skip = true
  applyCss(e, t.attr("style"))
  if e.skip: inc b.skips
  if t.selfClose and n notin ["div", "p", "span"]:
    if e.skip: dec b.skips
    if e.list: discard b.lists.pop()
    if e.quote: dec b.quotes
    if e.indent: dec b.indents
    if e.pre: dec b.pres
    return
  if b.stack.len >= MaxDepth:
    if e.skip: dec b.skips
    if e.list: discard b.lists.pop()
    if e.quote: dec b.quotes
    if e.indent: dec b.indents
    if e.pre: dec b.pres
    return
  b.stack.add e

proc richFromHtml*(html: string): RichDoc =
  ## A document from a mail's HTML: paragraphs (p, div, br), bold, italic,
  ## underline, strike, font and span styles (color, size, weight, family),
  ## links, lists (nested), quotes, headings, preformatted text; anything
  ## else gives its text, scripts and styles nothing. Never raises.
  var b = HB()
  try:
    for t in htmlTokens(html):
      case t.kind
      of tkText: addText(b, t.text)
      of tkStart: startTag(b, t)
      of tkEnd: endTag(b, t.name)
    while b.stack.len > 0: popElem(b)
    b.skips = 0
    flush(b, false)
  except Exception:
    discard
  result.paras = b.paras
  if result.paras.len == 0: result.paras.add RichPara(runs: @[RichRun()])
  fixup(result)

# ---- HTML out --------------------------------------------------------------------------------------

proc fmtNum(v: float): string =
  result = formatFloat(v, ffDecimal, 2)
  result.trimZeros()
  if result.endsWith('.'): result.setLen(result.len - 1)

proc hexOfColor(c: Color): string =
  "#" & toHex(int(c.r), 2).toLowerAscii & toHex(int(c.g), 2).toLowerAscii &
    toHex(int(c.b), 2).toLowerAscii

proc escAttr(s: string): string =
  for c in s:
    case c
    of '&': result.add "&amp;"
    of '"': result.add "&quot;"
    of '<': result.add "&lt;"
    of '>': result.add "&gt;"
    else: result.add c

proc runsHtml(p: RichPara): string =
  ## A paragraph's runs as HTML: spaces that HTML would fold kept as
  ## no-break ones, the runs of one link in one `<a>`.
  let total = paraLen(p)
  if total == 0: return "<br>"
  var pos = 0
  var prevSpace = true
  proc one(r: RichRun; pos: var int; prevSpace: var bool): string =
    var t = ""
    for c in r.text:
      case c
      of ' ':
        if prevSpace or pos == total - 1: t.add "&nbsp;" else: t.add ' '
        prevSpace = true
      of '&': t.add "&amp;"
      of '<': t.add "&lt;"
      of '>': t.add "&gt;"
      else: t.add c
      if c != ' ': prevSpace = false
      inc pos
    let s = r.style
    if s.strike: t = "<s>" & t & "</s>"
    if s.underline: t = "<u>" & t & "</u>"
    if s.italic: t = "<i>" & t & "</i>"
    if s.bold: t = "<b>" & t & "</b>"
    var css: seq[string]
    if s.color.a != 0: css.add "color:" & hexOfColor(s.color)
    if s.size > 0: css.add "font-size:" & fmtNum(s.size * BasePt) & "pt"
    if s.mono: css.add "font-family:Consolas,'Courier New',monospace"
    if css.len > 0: t = "<span style=\"" & css.join(";") & "\">" & t & "</span>"
    t
  var i = 0
  while i < p.runs.len:
    let lk = p.runs[i].style.link
    if lk.len > 0:
      result.add "<a href=\"" & escAttr(lk) & "\">"
      while i < p.runs.len and p.runs[i].style.link == lk:
        result.add one(p.runs[i], pos, prevSpace)
        inc i
      result.add "</a>"
    else:
      result.add one(p.runs[i], pos, prevSpace)
      inc i

proc alignCss(p: RichPara; rtl: bool): string =
  case p.align
  of alCenter: ";text-align:center"
  of alRight: (if rtl: ";text-align:left" else: ";text-align:right")
  else: ""

proc toHtml*(d: RichDoc): string =
  ## The document as clean HTML that mail clients show well: inline styles
  ## only, `<p style="margin:0">` paragraphs (an empty one `<br>`), `<ul>` /
  ## `<ol>` lists, `<blockquote>` quotes, `<a href>` links.
  var lists: seq[tuple[kind: ParaKind; li: bool]]
  var quotes = 0
  proc closeLists(n: int; res: var string) =
    while lists.len > n:
      if lists[^1].li: res.add "</li>"
      res.add(if lists[^1].kind == pkNumber: "</ol>\n" else: "</ul>\n")
      discard lists.pop()
  proc closeQuotes(n: int; res: var string) =
    while quotes > n:
      res.add "</blockquote>\n"
      dec quotes
  for p in d.paras:
    let rtl = textIsRtl(paraText(p))
    let dir = if rtl: " dir=\"rtl\"" else: ""
    case p.kind
    of pkBullet, pkNumber:
      closeQuotes(0, result)
      let lv = clamp(p.level, 0, MaxLevel)
      closeLists(lv + 1, result)
      if lists.len == lv + 1 and lists[^1].kind != p.kind: closeLists(lv, result)
      while lists.len < lv + 1:
        if lists.len > 0 and not lists[^1].li:
          result.add "<li style=\"list-style:none\">"
          lists[^1].li = true
        result.add(if p.kind == pkNumber: "<ol" else: "<ul")
        result.add dir & " style=\"margin-top:0;margin-bottom:0\">"
        lists.add (p.kind, false)
      if lists[^1].li: result.add "</li>\n"
      let css = alignCss(p, rtl)
      result.add "<li" & dir & (if css.len > 0: " style=\"" & css[1 .. ^1] & "\"" else: "") & ">"
      result.add runsHtml(p)
      lists[^1].li = true
    of pkQuote:
      closeLists(0, result)
      let lv = clamp(p.level, 0, MaxLevel) + 1
      closeQuotes(lv, result)
      while quotes < lv:
        result.add "<blockquote style=\"margin:0 0 0 0.8ex;border-left:2px solid #ccc;padding-left:1ex\">\n"
        inc quotes
      result.add "<p" & dir & " style=\"margin:0" & alignCss(p, rtl) & "\">" & runsHtml(p) & "</p>\n"
    of pkHeading:
      closeLists(0, result)
      closeQuotes(0, result)
      let h = "h" & $(clamp(p.level, 0, 2) + 1)
      result.add "<" & h & dir & " style=\"margin:0" & alignCss(p, rtl) & "\">" &
                 runsHtml(p) & "</" & h & ">\n"
    of pkNormal:
      closeLists(0, result)
      closeQuotes(0, result)
      var css = "margin:0"
      if p.level > 0:
        css.add(if rtl: ";margin-right:" else: ";margin-left:")
        css.add $(40 * p.level) & "px"
      css.add alignCss(p, rtl)
      result.add "<p" & dir & " style=\"" & css & "\">" & runsHtml(p) & "</p>\n"
  closeLists(0, result)
  closeQuotes(0, result)

# ---- plain text out ---------------------------------------------------------------------------

proc toPlainText*(d: RichDoc): string =
  ## The document as plain text (a mail's text/plain part): bullets as
  ## "- ", numbers as "1. ", quotes as "> ", links as "text <address>".
  let nums = numbering(d)
  for i, p in d.paras:
    if i > 0: result.add '\n'
    var t = ""
    var k = 0
    while k < p.runs.len:
      let lk = p.runs[k].style.link
      if lk.len == 0:
        t.add p.runs[k].text
        inc k
        continue
      var shown = ""
      while k < p.runs.len and p.runs[k].style.link == lk:
        shown.add p.runs[k].text
        inc k
      t.add shown
      let bare = if lk.startsWith("mailto:"): lk[7 .. ^1] else: lk
      if bare != shown and lk != shown: t.add " <" & bare & ">"
    let lv = clamp(p.level, 0, MaxLevel)
    case p.kind
    of pkBullet: result.add repeat("  ", lv) & "- " & t
    of pkNumber: result.add repeat("  ", lv) & $nums[i] & ". " & t
    of pkQuote:
      result.add repeat(">", lv + 1)
      if t.len > 0: result.add " " & t
    of pkHeading: result.add t
    of pkNormal: result.add repeat("    ", lv) & t
