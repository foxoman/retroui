## The layout engine of the HTML views: a page read (`htmldom`) and styled
## (`htmlcss`) becomes boxes once (`buildDoc`), and the boxes a list of
## things to draw at a width (`layoutDoc`): rectangles with their
## backgrounds and borders, words, pictures, list markers, link areas,
## anchors -- in page coordinates, in the order they are painted. Drawing
## and input are `htmlview`'s.
##
## What it lays out: blocks with margins (collapsing as in browsers),
## padding, borders and backgrounds; lines of words in mixed styles with
## links and inline pictures, wrapped at the spaces (a word wider than the
## line is broken), aligned left, right or centered, right to left when
## the paragraph reads so (runs of other words keep their order); inline
## blocks; floats (pictures and tables aligned left or right, text around
## them); lists, numbered and not, nested; tables with the column widths
## browsers give (the least and most each column's content needs, widths
## in pixels and percents, colspan, rowspan, cellpadding and cellspacing,
## collapsed borders, cells aligned top, middle or bottom), nested as deep
## as newsletters nest them; flexible boxes (display: flex -- rows,
## wrapped or not, and columns; the room shared as flex-grow and -shrink
## say from each box's basis, width or content; justify-content,
## align-items and -self, gap, order, right to left too) and grids (the
## columns of grid-template-columns, boxes over several with
## grid-column: span). Pictures keep their aspect and are made smaller to
## fit.
##
## Sizes: CSS pixels are `dp` pixels, the text the UI's font (12 CSS
## pixels: the UI's own text size) -- times the page's `zoom`, as a
## browser zooms: text, lengths and pictures together, laid out again (what
## is then wider than the view is made to fit).
##
## `htmlView` uses it; use it directly to draw a page somewhere else (a
## printout, a picture):
##
## ```nim
## let d = buildDoc("<h1>Report</h1><p>All is well.</p>")
## let page = layoutDoc(d, 600, proc (src: string): Bitmap = nil)
## for it in page.items:
##   if it.kind == dkText: echo it.x, ",", it.y, " ", it.text
## ```

import std/[strutils, tables, math, hashes, sets, algorithm]
import std/unicode except strip   # (its strip cuts letters: docs/nim-bugs.md)
import gfx, htmldom, htmlcss
from core import ui

type
  PicSource* = proc (src: string): Bitmap {.closure.}
    ## A picture for an `<img src>` while laying out, or nil when there is none.

  ItemKind = enum
    ikText, ikBreak, ikAtomic, ikOpen, ikClose, ikFloat, ikAnchor

  Item = object
    ## A piece of a paragraph: a word, a line break, a picture or inline
    ## block, the start or end of an inline element with a box.
    kind: ItemKind
    space: bool                ## white space before it (a break may come there)
    glue: bool                 ## no break before it
    sty: int32                 ## text: its text style; open, close: the element's style
    link: int32
    text: string               ## text: the word; anchor: the name
    box: Box                   ## atomic, float
    w: int32                   ## text: width; open, close: margin + border + padding
    tsi: int32                 ## open, close: the element's text style

  BoxKind = enum
    bxBlock, bxTable, bxImage

  TCell = object
    box: Box
    row, col, rs, cs: int32

  Box = ref object
    kind: BoxKind
    st: int32                  ## its computed style
    tst: int32                 ## the text style of its own text (the line's strut)
    anon: bool                 ## an anonymous block: lines only, no box of its own
    cell, canvas, isLink: bool
    inl: bool                  ## inline content (`items`), else blocks (`kids`)
    rtl: bool                  ## its lines read right to left
    kids: seq[Box]
    items: seq[Item]
    link: int32
    anchor: string
    listItem: bool
    marker: string             ## a numbered item's number ("3."); "" a bullet
    markerStyle: ListStyle
    tag: string
    # pictures
    src, alt: string
    attrW, attrH: float32      ## its width and height attributes (their aspect)
    pic: Bitmap
    picStamp: int
    # tables
    cells: seq[TCell]
    rowSts: seq[int32]
    nrows, ncols: int
    colSpec: seq[Len]
    caption: Box
    before: seq[Box]
    colMin, colMax, colFix: seq[int32]
    colPct: seq[float32]
    colStamp: int
    # the least and most room its content needs (border box)
    iMin, iMax: int32
    iStamp: int

  TStyle = object
    fontPx: float32
    bold, italic, mono, serif, underline, strike, invisible: bool
    color: uint32
    lhKind: LineH
    lhVal: float32
    valign: VAlign
    # measured for the screen's fonts
    ts: TextStyle
    lh, fh, asc, spaceW: int32
    tiny: bool                 ## too small to show (a hidden preheader's 1px text)

  Doc* = ref object
    ## A page read, styled and made boxes: laid out at any width by `layoutDoc`.
    root: Box
    styles: seq[CStyle]
    tstyles: seq[TStyle]
    tsIndex: Table[Hash, seq[int32]]
    links*: seq[string]        ## the addresses of its links
    title*: string             ## its <title>
    bg*: uint32                ## the color of the page (its body's)
    stamp: int                 ## what its sizes were measured for
    nodes*: int                ## elements and texts read

  DKind* = enum
    ## What a `DItem` is.
    dkBox, dkText, dkImage, dkMissing, dkAnchor, dkMarker, dkLinkArea

  DItem* = object
    ## A thing to draw, in page coordinates.
    kind*: DKind               ## what it is
    x*, y*, w*, h*: int        ## where
    color*: uint32             ## text, marker: its color; box: its background
    text*: string              ## text; a marker's; a missing picture's alt; an anchor's name
    ts*: TextStyle             ## text: its style
    link*: int32               ## the link it is part of, -1 none
    sep*: int8                 ## what comes before it in the text: 0 nothing, 1 a space,
                               ## 2 a tab, 3 a line break, 4 a blank line
    pic*: Bitmap               ## picture: its pixels (nil while it is not there)
    src*: string               ## picture: its src
    bw*: array[4, int16]       ## box: border widths (top, right, bottom, left)
    bc*: array[4, uint32]      ## ... and colors
    bs*: array[4, uint8]       ## ... and styles (htmlcss)
    radius*: int16             ## ... its corners' radius
    mk*: ListStyle             ## marker: which

  Page* = object
    ## A page laid out at one width.
    serial*: int               ## which layout it is (each has its own)
    items*: seq[DItem]         ## what to draw, in the order it is painted
    height*: int               ## its content's height
    right*: int                ## where its widest content ends
    links*: seq[string]        ## the links' addresses (`DItem.link` is an index)
    wanted*: seq[string]       ## pictures it has no picture for (not `data:`)
    anchors*: Table[string, int]   ## ids and names, and where they are
    bg*: uint32                ## the page's color (0: the view's)

const
  MaxCols = 200
  MaxRows = 20_000
  MaxSpan = 100

# ---- building the boxes ---------------------------------------------------------------------------

type
  Run = object
    items: seq[Item]
    pendingSpace: bool
    breakNext: bool
    any: bool
  Builder = object
    d: Doc
    sh: StyleSheet

proc tsOf(b: var Builder; si: int32): int32 =
  ## The text style of style `si` (the same ones shared).
  let s = addr b.d.styles[si]
  var t = TStyle(fontPx: s.fontPx, bold: s.bold, italic: s.italic, mono: s.mono, serif: s.serif,
                 underline: s.underline, strike: s.strike, invisible: s.invisible,
                 color: s.color, lhKind: s.lhKind, lhVal: s.lhVal,
                 valign: (if s.valign in {vaSub, vaSuper}: s.valign else: vaBaseline))
  var h = hash(t.fontPx) !& hash(t.bold) !& hash(t.italic) !& hash(t.mono) !& hash(t.serif) !&
          hash(t.underline) !& hash(t.strike) !& hash(t.invisible) !& hash(t.color) !&
          hash(ord(t.lhKind)) !& hash(t.lhVal) !& hash(ord(t.valign))
  h = !$h
  b.d.tsIndex.withValue(h, lst):
    for i in lst[]:
      let o = addr b.d.tstyles[i]
      if o.fontPx == t.fontPx and o.bold == t.bold and o.italic == t.italic and
         o.mono == t.mono and o.serif == t.serif and o.underline == t.underline and o.strike == t.strike and
         o.invisible == t.invisible and o.color == t.color and o.lhKind == t.lhKind and
         o.lhVal == t.lhVal and o.valign == t.valign:
        return i
  result = int32(b.d.tstyles.len)
  b.d.tstyles.add t
  b.d.tsIndex.mgetOrPut(h, @[]).add result

proc addStyle(b: var Builder; s: sink CStyle): int32 =
  result = int32(b.d.styles.len)
  b.d.styles.add s

proc isCjk(cp: int): bool {.inline.} =
  cp in 0x3040 .. 0x30FF or cp in 0x3400 .. 0x4DBF or cp in 0x4E00 .. 0x9FFF or
    cp in 0xAC00 .. 0xD7AF or cp in 0xF900 .. 0xFAFF or cp in 0xFF00 .. 0xFFEF or
    cp in 0x3000 .. 0x303F

proc transformed(w: string; t: Transform): string =
  case t
  of ttNone: w
  of ttUpper: unicode.toUpper(w)
  of ttLower: unicode.toLower(w)
  of ttCapitalize:
    if w.len == 0: w
    else:
      let r = w.runeAt(0)
      $r.toUpper & w[r.size .. ^1]

proc addWord(r: var Run; word: string; tsi, link: int32; nowrap: bool) =
  r.items.add Item(kind: ikText, text: word, sty: tsi, link: link,
                   space: r.pendingSpace and r.any,
                   glue: r.any and ((not r.pendingSpace and not r.breakNext) or nowrap))
  r.pendingSpace = false
  r.breakNext = false
  r.any = true

proc addBreak(r: var Run) =
  r.items.add Item(kind: ikBreak)
  r.pendingSpace = false
  r.breakNext = true
  r.any = true

proc addText(r: var Run; s: string; st: CStyle; tsi, link: int32) =
  ## A text's words into the run, its white space collapsed (or kept, in
  ## `pre`). Text too small to show takes no room at all.
  if st.fontPx < 3 or st.invisible and st.fontPx < 5: return
  let nowrap = st.white == wsNowrap
  var word = ""
  template flush() =
    if word.len > 0:
      r.addWord(transformed(word, st.transform), tsi, link, nowrap)
      word.setLen(0)
  if st.white == wsPre:
    # lines kept, each cut after its spaces (it wraps where it must)
    var col = 0
    var i = 0
    var afterSpace = false
    while i < s.len:
      let c = s[i]
      if c == '\r':
        inc i
        continue
      if c == '\n':
        flush()
        r.addBreak()
        col = 0
        afterSpace = false
        inc i
        continue
      if c == '\t' or c == ' ':
        let n = if c == '\t': 8 - col mod 8 else: 1
        for _ in 0 ..< n: word.add ' '
        col += n
        afterSpace = true
        inc i
        continue
      if afterSpace and word.len > 0:
        let w = word
        word.setLen(0)
        r.items.add Item(kind: ikText, text: w, sty: tsi, link: link, glue: false)
        r.any = true
        r.breakNext = false
      afterSpace = false
      let n = max(1, runeLenAt(s, i))
      word.add s[i ..< min(s.len, i + n)]
      inc col
      i += n
    if word.len > 0:
      r.items.add Item(kind: ikText, text: word, sty: tsi, link: link, glue: r.any and not afterSpace)
      r.any = true
      word.setLen(0)
    return
  for rune in s.runes:
    let cp = int(rune)
    case cp
    of 9, 10, 12, 13, 32:
      flush()
      if cp == 10 and st.white == wsPreLine: r.addBreak()
      elif r.any: r.pendingSpace = true
    of 0x200B:
      flush()
      r.breakNext = true
    of 0x200C, 0x200D:
      word.add rune           # (the joiners stay in their word: they steer Arabic joining)
    of 0xAD, 0x034F, 0xFEFF, 0x2060, 0x200E, 0x200F, 0x202A .. 0x202E,
       0x2066 .. 0x2069, 0x180E:
      discard
    of 0xA0, 0x2007, 0x202F:
      word.add ' '
    of 0x2000 .. 0x2006, 0x2008 .. 0x200A, 0x205F, 0x3000:
      flush()
      if r.any: r.pendingSpace = true
    else:
      if cp < 32 or cp == 0x7F: continue
      if isCjk(cp):
        flush()
        word.add rune
        flush()
        r.breakNext = true
      else:
        word.add rune
  flush()

proc usableLink(h: string): string =
  ## The address a link may take ("" for scripts and nothing).
  var t = ""
  for c in h:
    if c notin {'\0'..'\x1F', '\x7F'}: t.add c
  t = t.strip
  if t.len == 0: return ""
  var scheme = ""
  for c in t:
    if c in {' ', '\t'}: continue
    if c == ':': break
    scheme.add c.toLowerAscii
    if scheme.len > 12: break
  if scheme in ["javascript", "vbscript", "data"] and ':' in t: return ""
  t

proc firstStrong(items: seq[Item]): int =
  ## The direction of the first letter that has one (0 left to right, 1
  ## right to left, -1 none).
  for it in items:
    if it.kind == ikText:
      let d = strongDir(it.text)
      if d in {0, 1}: return d
    elif it.kind == ikAtomic and it.box.kind == bxBlock:
      if it.box.inl:
        let d = firstStrong(it.box.items)
        if d >= 0: return d
  -1

proc subtreeDir(b: Box; budget: var int): int =
  if b == nil or budget <= 0: return -1
  dec budget
  if b.inl: return firstStrong(b.items)
  for k in b.kids:
    let d = subtreeDir(k, budget)
    if d >= 0: return d
  for c in b.cells:
    let d = subtreeDir(c.box, budget)
    if d >= 0: return d
  -1

proc newBlock(b: var Builder; si: int32; link: int32): Box =
  Box(kind: bxBlock, st: si, tst: b.tsOf(si), link: link)

proc finishInline(b: var Builder; box: Box) =
  let st = addr b.d.styles[box.st]
  box.rtl = if st.dir == dirRtl: true
            elif st.dir == dirLtr: false
            else: firstStrong(box.items) == 1

proc flushRun(b: var Builder; box: Box; r: var Run) =
  if r.items.len > 0:
    let a = Box(kind: bxBlock, st: box.st, tst: box.tst, anon: true, inl: true, link: box.link)
    a.items = move r.items
    b.finishInline(a)
    box.kids.add a
  r = Run()

proc buildBlock(b: var Builder; n: HNode; si: int32; link: int32; depth: int): Box
proc buildTable(b: var Builder; n: HNode; si: int32; link: int32; depth: int): Box

proc imageBox(b: var Builder; n: HNode; si: int32; link: int32): Box =
  result = Box(kind: bxImage, st: si, tst: b.tsOf(si), link: link, tag: "img")
  result.src = n.attr("src").strip
  result.alt = strutils.splitWhitespace(n.attr("alt")).join(" ")
  if result.alt.len > 200: result.alt.setLen(200)
  let aw = attrLen(n.attr("width"))
  let ah = attrLen(n.attr("height"))
  if aw.k == lkPx and ah.k == lkPx and aw.v > 0 and ah.v > 0:
    result.attrW = aw.v
    result.attrH = ah.v

proc decorated(s: CStyle): bool =
  s.bg != 0 or s.bw[1] > 0 or s.bw[3] > 0 or s.bw[0] > 0 or s.bw[2] > 0 or
    (s.padding[1].k == lkPx and s.padding[1].v > 0) or
    (s.padding[3].k == lkPx and s.padding[3].v > 0) or
    (s.margin[1].k == lkPx and s.margin[1].v != 0) or
    (s.margin[3].k == lkPx and s.margin[3].v != 0)

proc romanOf(n: int): string =
  const vals = [1000, 900, 500, 400, 100, 90, 50, 40, 10, 9, 5, 4, 1]
  const syms = ["m", "cm", "d", "cd", "c", "xc", "l", "xl", "x", "ix", "v", "iv", "i"]
  var v = clamp(n, 1, 3999)
  for k, x in vals:
    while v >= x:
      result.add syms[k]
      v -= x

proc alphaOf(n: int): string =
  var v = max(1, n)
  while v > 0:
    dec v
    result.insert($char(ord('a') + v mod 26))
    v = v div 26

proc markerText(ls: ListStyle; n: int): string =
  case ls
  of lsDecimal: $n & "."
  of lsLowerAlpha: alphaOf(n) & "."
  of lsUpperAlpha: alphaOf(n).toUpperAscii & "."
  of lsLowerRoman: romanOf(n) & "."
  of lsUpperRoman: romanOf(n).toUpperAscii & "."
  else: ""

proc walkInto(b: var Builder; box: Box; r: var Run; n: HNode; si: int32; link: int32;
              depth: int) =
  ## The content of `n` (style `si`) into block `box`: words and inline
  ## things into the run, blocks as children of `box`.
  var counter = 1
  if n.tag == "ol":
    try: counter = parseInt(n.attr("start").strip)
    except ValueError: discard
  let isList = n.tag in ["ul", "ol", "menu", "dir"]
  # (a flexible box's or a grid's children: each a box of its own, one of
  # its cells -- an inline one, a link, a picture too; text between them
  # one box)
  let flexed = b.d.styles[si].flow != bfNormal and box.st == si
  for k in n.kids:
    if k.tag.len == 0:
      if k.text.len > 0:
        let tsi = b.tsOf(si)
        r.addText(k.text, b.d.styles[si], tsi, link)
      continue
    case k.tag
    of "br":
      r.addBreak()
      continue
    of "wbr":
      r.breakNext = true
      continue
    else: discard
    var ks = cascade(k, b.d.styles[si], b.sh)
    if ks.hidden: continue
    var disp = ks.display
    if flexed:
      ks.floatSide = 0
      if disp in {dsInline, dsInlineBlock}: disp = dsBlock
      elif disp == dsInlineTable: disp = dsTable
    if disp in {dsNone, dsColumn, dsColumnGroup}: continue
    var klink = link
    if k.tag == "a":
      let h = usableLink(k.attr("href"))
      if h.len > 0:
        klink = int32(b.d.links.len)
        b.d.links.add h
    var anchor = k.id
    if anchor.len == 0 and k.tag == "a": anchor = k.attr("name")
    let isLi = disp == dsListItem
    var marker = ""
    if isLi:
      var v = counter
      let va = k.attr("value").strip
      if va.len > 0:
        try:
          v = parseInt(va)
          counter = v
        except ValueError: discard
      marker = markerText(ks.listStyle, v)
      inc counter
    let ksi = b.addStyle(ks)
    case disp
    of dsInline:
      if anchor.len > 0: r.items.add Item(kind: ikAnchor, text: anchor)
      if k.tag == "img":
        let ib = b.imageBox(k, ksi, klink)
        if ks.floatSide != 0 and r.any:
          r.items.add Item(kind: ikFloat, box: ib)
        elif ks.floatSide != 0:
          b.flushRun(box, r)
          box.kids.add ib
        else:
          r.items.add Item(kind: ikAtomic, box: ib, link: klink,
                           space: r.pendingSpace and r.any,
                           glue: r.any and b.d.styles[si].white == wsNowrap)
          r.pendingSpace = false
          r.breakNext = true
          r.any = true
      elif k.tag == "input":
        if k.attr("type").toLowerAscii == "checkbox":
          r.addWord(if k.hasAttr("checked"): "☑" else: "☐", b.tsOf(ksi), klink, false)
      else:
        let deco = decorated(ks) or (klink != link)
        if deco:
          # (a space before it is outside its box)
          r.items.add Item(kind: ikOpen, sty: ksi, link: klink, tsi: b.tsOf(ksi),
                           space: r.pendingSpace and r.any)
          if r.pendingSpace and r.any:
            r.pendingSpace = false
            r.breakNext = true
        if depth < MaxDepth + 8:
          b.walkInto(box, r, k, ksi, klink, depth + 1)
        if deco:
          r.items.add Item(kind: ikClose, sty: ksi, link: klink, tsi: b.tsOf(ksi))
    of dsInlineBlock, dsInlineTable:
      if anchor.len > 0: r.items.add Item(kind: ikAnchor, text: anchor)
      let ab = if disp == dsInlineTable or k.tag == "table": b.buildTable(k, ksi, klink, depth + 1)
               elif k.tag == "img": b.imageBox(k, ksi, klink)
               else: b.buildBlock(k, ksi, klink, depth + 1)
      ab.isLink = klink != link
      if ks.floatSide != 0 and r.any:
        r.items.add Item(kind: ikFloat, box: ab)
      elif ks.floatSide != 0:
        b.flushRun(box, r)
        box.kids.add ab
      else:
        r.items.add Item(kind: ikAtomic, box: ab, link: klink,
                         space: r.pendingSpace and r.any,
                         glue: r.any and b.d.styles[si].white == wsNowrap)
        r.pendingSpace = false
        r.breakNext = true
        r.any = true
    else:
      let bb =
        if disp == dsTable or (k.tag == "table" and disp notin {dsBlock, dsListItem}):
          b.buildTable(k, ksi, klink, depth + 1)
        elif k.tag == "img": b.imageBox(k, ksi, klink)
        else: b.buildBlock(k, ksi, klink, depth + 1)
      bb.isLink = klink != link
      bb.anchor = anchor
      if isLi or (isList and k.tag == "li"):
        bb.listItem = true
        bb.marker = marker
        bb.markerStyle = ks.listStyle
      if ks.floatSide != 0 and r.any:
        r.items.add Item(kind: ikFloat, box: bb)
      else:
        b.flushRun(box, r)
        box.kids.add bb

proc buildBlock(b: var Builder; n: HNode; si: int32; link: int32; depth: int): Box =
  result = b.newBlock(si, link)
  result.tag = n.tag
  var r = Run()
  b.walkInto(result, r, n, si, link, depth)
  if result.kids.len == 0 and b.d.styles[si].flow == bfNormal:
    result.inl = true
    result.items = move r.items
    b.finishInline(result)
  else:
    b.flushRun(result, r)
  # lists and quotes of a right-to-left text indent at the right
  let st = addr b.d.styles[si]
  if st.dir == dirAuto and n.tag in ["ul", "ol", "blockquote", "dd", "menu", "dir"]:
    var budget = 200
    if subtreeDir(result, budget) == 1:
      swap(st.padding[1], st.padding[3])
      swap(st.margin[1], st.margin[3])
      swap(st.bw[1], st.bw[3])
      swap(st.bs[1], st.bs[3])
      swap(st.bc[1], st.bc[3])
      st.dir = dirRtl

proc spanOf(v: string; lo, hi: int; dflt: int): int =
  try: clamp(parseInt(v.strip), lo, hi)
  except ValueError: dflt

proc buildTable(b: var Builder; n: HNode; si: int32; link: int32; depth: int): Box =
  result = Box(kind: bxTable, st: si, tst: b.tsOf(si), link: link, tag: "table")
  let t = result
  type RawCell = tuple[box: Box; cs, rs: int]
  var rows: seq[tuple[st: int32; cells: seq[RawCell]]]
  var foot: seq[tuple[st: int32; cells: seq[RawCell]]]
  var loose: seq[RawCell]
  var fosterRun = Run()
  let fosterBox = b.newBlock(si, link)
  proc cellOf(b: var Builder; k: HNode; ks: sink CStyle; link: int32; depth: int): RawCell =
    let ksi = b.addStyle(ks)
    let cb = b.buildBlock(k, ksi, link, depth + 1)
    cb.cell = true
    cb.anchor = k.id
    (cb, spanOf(k.attr("colspan"), 1, MaxSpan, 1), spanOf(k.attr("rowspan"), 0, MaxRows, 1))
  proc rowOf(b: var Builder; rn: HNode; rsi: int32; link: int32; depth: int;
             foster: var Run; fosterBox: Box): seq[RawCell] =
    for k in rn.kids:
      if k.tag.len == 0:
        if k.text.strip.len > 0: foster.addText(k.text, b.d.styles[rsi], b.tsOf(rsi), link)
        continue
      let ks = cascade(k, b.d.styles[rsi], b.sh)
      if ks.hidden: continue
      if ks.display == dsCell or k.tag in ["td", "th"]:
        result.add b.cellOf(k, ks, link, depth)
      elif ks.display notin {dsNone, dsColumn, dsColumnGroup}:
        b.flushRun(fosterBox, foster)
        let ksi = b.addStyle(ks)
        fosterBox.kids.add b.buildBlock(k, ksi, link, depth + 1)
  for k in n.kids:
    if k.tag.len == 0:
      if k.text.strip.len > 0: fosterRun.addText(k.text, b.d.styles[si], b.tsOf(si), link)
      continue
    let ks = cascade(k, b.d.styles[si], b.sh)
    if ks.hidden: continue
    case ks.display
    of dsCaption:
      if t.caption == nil:
        let ksi = b.addStyle(ks)
        t.caption = b.buildBlock(k, ksi, link, depth + 1)
    of dsColumnGroup, dsColumn:
      let w = ks.width
      if k.tag == "colgroup" and k.kids.len > 0:
        for c in k.kids:
          if c.tag == "col":
            let cs = cascade(c, ks, b.sh)
            for _ in 0 ..< spanOf(c.attr("span"), 1, MaxSpan, 1):
              if t.colSpec.len < MaxCols: t.colSpec.add cs.width
      else:
        for _ in 0 ..< spanOf(k.attr("span"), 1, MaxSpan, 1):
          if t.colSpec.len < MaxCols: t.colSpec.add w
    of dsRowGroup:
      if loose.len > 0:
        rows.add (si, loose)
        loose = @[]
      let gsi = b.addStyle(ks)
      for rn in k.kids:
        if rn.tag.len == 0: continue
        let rs = cascade(rn, b.d.styles[gsi], b.sh)
        if rs.hidden: continue
        if rs.display == dsRow or rn.tag == "tr":
          let rsi = b.addStyle(rs)
          let cells = b.rowOf(rn, rsi, link, depth, fosterRun, fosterBox)
          if k.tag == "tfoot": foot.add (rsi, cells)
          else: rows.add (rsi, cells)
        elif rs.display == dsCell or rn.tag in ["td", "th"]:
          rows.add (gsi, @[b.cellOf(rn, rs, link, depth)])
        if rows.len >= MaxRows: break
    of dsRow:
      if loose.len > 0:
        rows.add (si, loose)
        loose = @[]
      let rsi = b.addStyle(ks)
      rows.add (rsi, b.rowOf(k, rsi, link, depth, fosterRun, fosterBox))
    of dsCell:
      loose.add b.cellOf(k, ks, link, depth)
    else:
      if k.tag == "tr":
        let rsi = b.addStyle(ks)
        rows.add (rsi, b.rowOf(k, rsi, link, depth, fosterRun, fosterBox))
      elif k.tag in ["td", "th"]:
        loose.add b.cellOf(k, ks, link, depth)
      else:
        # what is in a table outside its cells: before it, as browsers show it
        b.flushRun(fosterBox, fosterRun)
        let ksi = b.addStyle(ks)
        if ks.display == dsInline:
          var r = Run()
          let holder = b.newBlock(ksi, link)
          b.walkInto(holder, r, k, ksi, link, depth + 1)
          b.flushRun(holder, r)
          for h in holder.kids: fosterBox.kids.add h
        else:
          fosterBox.kids.add b.buildBlock(k, ksi, link, depth + 1)
    if rows.len >= MaxRows: break
  if loose.len > 0: rows.add (si, loose)
  rows.add foot
  b.flushRun(fosterBox, fosterRun)
  if fosterBox.kids.len > 0: t.before = fosterBox.kids
  # the grid: where each cell is, rowspans and colspans taken into account
  var spanLeft: seq[int]
  for r, row in rows:
    var c = 0
    for cell in row.cells:
      while c < spanLeft.len and spanLeft[c] > 0: inc c
      if c >= MaxCols: break
      let cs = min(cell.cs, MaxCols - c)
      var rs = if cell.rs == 0: rows.len - r else: min(cell.rs, rows.len - r)
      rs = max(1, rs)
      t.cells.add TCell(box: cell.box, row: int32(r), col: int32(c), rs: int32(rs), cs: int32(cs))
      while spanLeft.len < c + cs: spanLeft.add 0
      for j in c ..< c + cs: spanLeft[j] = rs
      c += cs
      t.ncols = max(t.ncols, c)
    for j in 0 ..< spanLeft.len:
      if spanLeft[j] > 0: dec spanLeft[j]
    t.rowSts.add row.st
  t.nrows = rows.len
  t.ncols = max(t.ncols, min(t.colSpec.len, MaxCols))

proc buildDoc*(html: string): Doc =
  ## `html` read, styled and made boxes.
  let hd = parseHtml(html)
  var b = Builder(d: Doc(title: hd.title, nodes: hd.nodes), sh: sheetOf(hd))
  let rsi = b.addStyle(initialStyle())
  let root = b.newBlock(rsi, -1)
  root.tag = "#root"
  root.cell = true              # (its first and last margins left out, as mail apps do)
  var r = Run()
  b.walkInto(root, r, hd.root, rsi, -1, 0)
  if root.kids.len == 0:
    root.inl = true
    root.items = move r.items
    b.finishInline(root)
  else:
    b.flushRun(root, r)
  b.d.root = root
  # the page's color: its body's (or html's)
  proc canvasOf(d: Doc; box: Box; depth: int) =
    if depth > 3: return
    for k in box.kids:
      if k.tag in ["html", "body"]:
        let bg = d.styles[k.st].bg
        if bg != 0 and not isRole(bg):
          d.bg = bg
          k.canvas = true
        canvasOf(d, k, depth + 1)
  canvasOf(b.d, root, 0)
  b.d

proc title*(d: Doc): string = d.title
  ## The page's `<title>`.

# ---- measuring --------------------------------------------------------------------------------------

type
  MC = object
    ## Margins that meet: the largest and the most negative.
    pos, neg: int

  FloatR = object
    left: bool
    x0, x1, y0, y1: int

  Lay = object
    d: Doc
    p: ptr Page
    k: float                   ## logical pixels per CSS pixel
    fk: float                  ## ... per CSS pixel of text
    zoom: float                ## the page's zoom (1: as the UI's text)
    stamp: int
    pics: PicSource
    sep: int8
    floats: seq[FloatR]
    wantedSet: HashSet[string]
    lastBaseline: int
    # a list item's marker, until its first line
    mPending: bool
    mBox: Box
    mX, mRight: int
    mRtl: bool

  LI = object
    it: int32
    kind: ItemKind
    x, w, gap: int
    a, d: int
    vx: int
    text: string
    part: bool
    ah, aw: int                ## atomic: height, width (border box)
    ml, mt: int                ## ... margins
    ra, rb: int                ## ... what it drew (inline blocks)
    base: int                  ## ... its baseline from its top
    pic: Bitmap

proc add(m: var MC; v: int) {.inline.} =
  if v > 0: m.pos = max(m.pos, v) else: m.neg = min(m.neg, v)

proc total(m: MC): int {.inline.} = m.pos + m.neg

proc S(c: Lay; i: int32): ptr CStyle {.inline.} = addr c.d.styles[i]
proc T(c: Lay; i: int32): ptr TStyle {.inline.} = addr c.d.tstyles[i]

proc lp(c: Lay; v: float32): int {.inline.} =
  ## CSS pixels as logical pixels (absurd ones clamped).
  int(round(clamp(float(v), -100_000.0, 100_000.0) * c.k))

proc lenPx(c: Lay; l: Len; base: int): int =
  ## A length (auto: 0) against `base` for percentages.
  case l.k
  of lkPx: c.lp(l.v)
  of lkPct: int(round(clamp(float(l.v), -1000.0, 1000.0) * float(base) / 100))
  else: 0

proc measureStyles(c: var Lay) =
  for t in c.d.tstyles.mitems:
    var size = float(t.fontPx) / RootPx * c.zoom
    t.tiny = t.fontPx < 3
    size = clamp(size, 0.3, 12)
    let ts = style(bold = t.bold, italic = t.italic, mono = t.mono, size = size,
                   underline = t.underline, strike = t.strike, serif = t.serif)
    t.ts = ts
    t.fh = int32(lineHeight(ts))
    t.asc = int32(round(float(FontAscent) * float(t.fh) / float(max(1, FontH))))
    t.spaceW = int32(textWidth(" ", ts))
    let lh = case t.lhKind
      of lhNormal: int(t.fh) + max(1, int(t.fh) div 8)
      of lhFactor: int(round(clamp(float(t.lhVal), 0.0, 20.0) * float(t.fontPx) * c.fk))
      of lhPx: int(round(clamp(float(t.lhVal), 0.0, 2000.0) * c.fk))
    t.lh = int32(max(lh, int(round(float(t.fh) * 0.85))))

proc measureItems(c: var Lay; b: Box) =
  for it in b.items.mitems:
    case it.kind
    of ikText:
      let t = c.T(it.sty)
      it.w = int32(textWidth(it.text, t.ts))
    of ikOpen:
      let s = c.S(it.sty)
      it.w = int32(c.lenPx(s.margin[3], 0) + int(round(float(s.bw[3]) * c.k)) +
                   c.lenPx(s.padding[3], 0))
    of ikClose:
      let s = c.S(it.sty)
      it.w = int32(c.lenPx(s.margin[1], 0) + int(round(float(s.bw[1]) * c.k)) +
                   c.lenPx(s.padding[1], 0))
    else: discard

proc measureAll(c: var Lay; b: Box) =
  if b == nil: return
  if b.inl:
    c.measureItems(b)
    for it in b.items:
      if it.box != nil: c.measureAll(it.box)
  for k in b.kids: c.measureAll(k)
  for cell in b.cells: c.measureAll(cell.box)
  c.measureAll(b.caption)
  for k in b.before: c.measureAll(k)

proc bw(c: Lay; s: ptr CStyle; side: int): int {.inline.} =
  if s.bw[side] <= 0 or s.bs[side] == 0: 0 else: max(1, int(round(float(s.bw[side]) * c.k)))

proc hEdges(c: Lay; s: ptr CStyle; base: int): int =
  ## Left and right border and padding.
  c.bw(s, 1) + c.bw(s, 3) + c.lenPx(s.padding[1], base) + c.lenPx(s.padding[3], base)

# ---- pictures ------------------------------------------------------------------------------------

proc picOf(c: var Lay; b: Box): Bitmap =
  if b.picStamp != c.stamp:
    b.picStamp = c.stamp
    b.pic = nil
    if b.src.len > 0 and c.pics != nil:
      let p = c.pics(b.src)
      if p != nil and p.w > 0 and p.h > 0: b.pic = p
  if b.pic == nil and b.src.len > 0 and not b.src.toLowerAscii.startsWith("data:") and
     b.src notin c.wantedSet:
    c.wantedSet.incl b.src
    c.p.wanted.add b.src
  b.pic

proc imageSize(c: var Lay; b: Box; cbW: int): tuple[w, h: int] =
  ## A picture's size: as the page asks, else its own, made smaller to fit
  ## `cbW` (its aspect kept); a picture not there: its alt text's.
  let s = c.S(b.st)
  let pic = c.picOf(b)
  let nw = if pic != nil: pic.w else: 0
  let nh = if pic != nil: pic.h else: 0
  var w = case s.width.k
          of lkPx: c.lp(s.width.v)
          of lkPct: int(float(s.width.v) * float(cbW) / 100)
          else: -1
  var h = if s.height.k == lkPx: c.lp(s.height.v) else: -1
  let t = c.T(b.tst)
  let altW = if b.alt.len > 0: min(textWidth(b.alt, t.ts) + 10, max(cbW, 40)) else: 0
  let altH = if b.alt.len > 0: int(t.fh) + 6 else: 0
  # (no picture yet: the aspect its attributes give, as browsers keep it)
  let aspect = b.attrW > 0 and b.attrH > 0
  if w < 0 and h < 0:
    if pic != nil: (w, h) = (c.lp(float32(nw)), c.lp(float32(nh)))
    elif aspect: (w, h) = (c.lp(b.attrW), c.lp(b.attrH))
    else: (w, h) = (altW, altH)
  elif w < 0:
    w = if pic != nil: h * nw div max(1, nh)
        elif aspect: int(float(h) * float(b.attrW) / float(b.attrH))
        else: max(altW, h)
  elif h < 0:
    h = if pic != nil: w * nh div max(1, nw)
        elif aspect: int(float(w) * float(b.attrH) / float(b.attrW))
        else: altH
  # made smaller to fit, its aspect kept
  if s.maxW.k == lkPx and w > c.lp(s.maxW.v) and w > 0:
    let m = c.lp(s.maxW.v)
    h = h * m div w
    w = m
  if w > cbW and w > 0 and cbW > 0:
    h = h * cbW div w
    w = cbW
  if s.maxH.k == lkPx and h > c.lp(s.maxH.v) and h > 0:
    let m = c.lp(s.maxH.v)
    w = w * m div h
    h = m
  (clamp(w, 0, 20_000), clamp(h, 0, 20_000))

# ---- the room content needs ----------------------------------------------------------------------

proc intrinsic(c: var Lay; b: Box): tuple[mn, mx: int]
proc columns(c: var Lay; t: Box)

proc inlineIntrinsic(c: var Lay; b: Box): tuple[mn, mx: int] =
  # (a word longer than this is broken where room is short -- a long
  # address must not make a table wider than the view)
  let cap = c.lp(120)
  var chain, line = 0
  for i, it in b.items:
    case it.kind
    of ikText:
      let t = c.T(it.sty)
      let w = min(int(it.w), cap)
      if it.glue:
        chain += w + (if it.space: int(t.spaceW) else: 0)
      else:
        result.mn = max(result.mn, chain)
        chain = w
      line += int(it.w) + (if it.space: int(t.spaceW) else: 0)
    of ikBreak:
      result.mn = max(result.mn, chain)
      result.mx = max(result.mx, line)
      chain = 0
      line = 0
    of ikAtomic, ikFloat:
      let (mn, mx) = c.intrinsic(it.box)
      let s = c.S(it.box.st)
      let m = c.lenPx(s.margin[1], 0) + c.lenPx(s.margin[3], 0)
      result.mn = max(result.mn, chain)
      result.mn = max(result.mn, mn + m)
      chain = if it.glue: chain + mx + m else: 0
      line += mx + m
    of ikOpen, ikClose:
      chain += int(it.w)
      line += int(it.w)
    of ikAnchor: discard
  result.mn = max(result.mn, chain)
  result.mx = max(result.mx, line)

proc intrinsic(c: var Lay; b: Box): tuple[mn, mx: int] =
  ## The least and the most width `b`'s border box takes (its content
  ## unbroken, or broken at every chance).
  if b.iStamp == c.stamp: return (int(b.iMin), int(b.iMax))
  b.iStamp = c.stamp
  let s = c.S(b.st)
  case b.kind
  of bxImage:
    let (w, _) = c.imageSize(b, 100_000)
    let ew = c.bw(s, 1) + c.bw(s, 3)
    result = (min(w, max(c.lp(48), 0)) + ew, w + ew)
    if s.width.k == lkPct: result.mn = 0
  of bxTable:
    c.columns(b)
    let sp = if s.collapse: 0 else: c.lp(s.spacing)
    let edges = c.hEdges(s, 0) + sp * (b.ncols + 1)
    var mn, mx = 0
    for v in b.colMin: mn += int(v)
    for v in b.colMax: mx += int(v)
    result = (mn + edges, mx + edges)
    if s.width.k == lkPx: result.mx = max(result.mn, max(result.mx, c.lp(s.width.v)))
    if b.caption != nil:
      let (cm, _) = c.intrinsic(b.caption)
      result.mn = max(result.mn, cm)
  of bxBlock:
    let edges = if b.anon: 0 else: c.hEdges(s, 0)
    if not b.anon and s.width.k == lkPx and not b.cell:
      let w = c.lp(s.width.v) + (if s.borderBox: 0 else: edges)
      result = (w, w)
    else:
      var inner: tuple[mn, mx: int]
      if b.inl: inner = c.inlineIntrinsic(b)
      elif not b.anon and s.flow != bfNormal and not (s.flow == bfFlex and s.column):
        # (a row: its boxes side by side -- the least, one under another
        # when it wraps; a grid: its widest box in every column)
        let gap = max(0, c.lenPx(s.gapCol, 0))
        var cols = 1
        if s.flow == bfGrid:
          cols = max(1, s.tracks.len)
          for tr in s.tracks:
            if tr.k == gtFill: cols = 1
        var widest = 0
        for i, k in b.kids:
          let (mn, mx) = c.intrinsic(k)
          let ks = c.S(k.st)
          let m = if k.anon: 0 else: c.lenPx(ks.margin[1], 0) + c.lenPx(ks.margin[3], 0)
          widest = max(widest, mx + m)
          if s.flow == bfFlex:
            inner.mn = if s.wrap: max(inner.mn, mn + m) else: inner.mn + mn + m + (if i > 0: gap else: 0)
            inner.mx += mx + m + (if i > 0: gap else: 0)
          else: inner.mn = max(inner.mn, mn + m)
        if s.flow == bfGrid: inner.mx = widest * min(cols, max(1, b.kids.len)) + gap * (min(cols, b.kids.len) - 1)
      else:
        for k in b.kids:
          let (mn, mx) = c.intrinsic(k)
          let ks = c.S(k.st)
          let m = if k.anon: 0 else: c.lenPx(ks.margin[1], 0) + c.lenPx(ks.margin[3], 0)
          inner.mn = max(inner.mn, mn + m)
          inner.mx = max(inner.mx, mx + m)
      result = (inner.mn + edges, inner.mx + edges)
      if not b.anon:
        if s.maxW.k == lkPx:
          let m = c.lp(s.maxW.v) + (if s.borderBox: 0 else: edges)
          result.mx = min(result.mx, max(m, result.mn))
        if s.minW.k == lkPx:
          let m = c.lp(s.minW.v) + (if s.borderBox: 0 else: edges)
          result.mn = max(result.mn, m)
          result.mx = max(result.mx, m)
  result.mx = max(result.mx, result.mn)
  b.iMin = int32(min(result.mn, 1_000_000))
  b.iMax = int32(min(result.mx, 1_000_000))

proc columns(c: var Lay; t: Box) =
  ## Each column's least and most width, its fixed width and percentage.
  if t.colStamp == c.stamp: return
  t.colStamp = c.stamp
  let n = t.ncols
  t.colMin = newSeq[int32](n)
  t.colMax = newSeq[int32](n)
  t.colFix = newSeq[int32](n)
  t.colPct = newSeq[float32](n)
  let ts = c.S(t.st)
  let sp = if ts.collapse: 0 else: c.lp(ts.spacing)
  for i in 0 ..< min(n, t.colSpec.len):
    let l = t.colSpec[i]
    if l.k == lkPx: t.colFix[i] = int32(c.lp(l.v))
    elif l.k == lkPct: t.colPct[i] = l.v
  var spans: seq[int]
  for k, cell in t.cells:
    if cell.cs > 1:
      spans.add k
      continue
    let (mn, mx) = c.intrinsic(cell.box)
    let col = cell.col
    t.colMin[col] = max(t.colMin[col], int32(mn))
    t.colMax[col] = max(t.colMax[col], int32(mx))
    let s = c.S(cell.box.st)
    if s.width.k == lkPx:
      let w = c.lp(s.width.v) + (if s.borderBox: 0 else: c.hEdges(s, 0))
      t.colFix[col] = max(t.colFix[col], int32(w))
    elif s.width.k == lkPct:
      t.colPct[col] = max(t.colPct[col], s.width.v)
  for i in 0 ..< n:
    t.colMax[i] = max(t.colMax[i], t.colMin[i])
    if t.colFix[i] > 0: t.colMax[i] = max(t.colMin[i], t.colFix[i])
  # cells over several columns: what their columns lack, shared out
  proc spread(vals: var seq[int32]; weights: seq[int32]; a, b: int; extra: int) =
    var tot = 0
    for j in a ..< b: tot += int(weights[j])
    var given = 0
    for j in a ..< b:
      let part = if tot > 0: extra * int(weights[j]) div tot else: extra div (b - a)
      vals[j] += int32(part)
      given += part
    vals[b - 1] += int32(extra - given)
  spans.sort(proc (x, y: int): int = cmp(t.cells[x].cs, t.cells[y].cs))
  for k in spans:
    let cell = t.cells[k]
    let a = int(cell.col)
    let b = min(n, a + int(cell.cs))
    if b <= a: continue
    let (mn, mx) = c.intrinsic(cell.box)
    var curMin, curMax = sp * (b - a - 1)
    for j in a ..< b:
      curMin += int(t.colMin[j])
      curMax += int(t.colMax[j])
    if mn > curMin: spread(t.colMin, t.colMax, a, b, mn - curMin)
    let s = c.S(cell.box.st)
    var want = mx
    if s.width.k == lkPx:
      want = max(mn, c.lp(s.width.v) + (if s.borderBox: 0 else: c.hEdges(s, 0)))
    if want > curMax: spread(t.colMax, t.colMax, a, b, want - curMax)
    for j in a ..< b: t.colMax[j] = max(t.colMax[j], t.colMin[j])

# ---- the display list ------------------------------------------------------------------------------

proc reserveBox(c: var Lay; s: ptr CStyle): int =
  ## A place for a box's background and border (drawn before its content),
  ## or -1 when it has neither.
  if s.invisible or s.bg == 0 and c.bw(s, 0) == 0 and c.bw(s, 1) == 0 and c.bw(s, 2) == 0 and
     c.bw(s, 3) == 0:
    return -1
  result = c.p.items.len
  var d = DItem(kind: dkBox, color: s.bg, link: -1, radius: int16(min(c.lp(s.radius), 200)))
  for k in 0 .. 3:
    d.bw[k] = int16(min(c.bw(s, k), 200))
    d.bc[k] = if s.bc[k] == 0: s.color else: s.bc[k]
    d.bs[k] = s.bs[k]
  c.p.items.add d

proc patch(c: var Lay; slot: int; x, y, w, h: int) =
  if slot < 0: return
  let d = addr c.p.items[slot]
  d.x = x
  d.y = y
  d.w = max(0, w)
  d.h = max(0, h)

proc shift(c: var Lay; a, b: int; dx, dy: int) =
  ## What was drawn from `a` to `b` moved.
  if dx == 0 and dy == 0: return
  for i in a ..< min(b, c.p.items.len):
    c.p.items[i].x += dx
    c.p.items[i].y += dy

proc boundary(c: var Lay; v: int8) {.inline.} =
  if v > c.sep: c.sep = v

proc colorOfText(t: ptr TStyle): uint32 {.inline.} = t.color

proc emitText(c: var Lay; x, y, w: int; text: string; t: ptr TStyle; link: int32;
              rtl: bool; sep: int8) =
  var ts = t.ts
  ts.rtl = rtl
  c.p.items.add DItem(kind: dkText, x: (x), y: (y), w: (w), h: t.fh,
                      color: colorOfText(t), text: text, ts: ts, link: link, sep: sep)
  c.p.right = max(c.p.right, x + w)

proc emitMarker(c: var Lay; baseline: int) =
  ## The pending list marker, at a line whose baseline is at `baseline`.
  if not c.mPending: return
  c.mPending = false
  let b = c.mBox
  let t = c.T(b.tst)
  let s = c.S(b.st)
  if s.listStyle == lsNone and b.marker.len == 0: return
  var d = DItem(kind: dkMarker, link: -1, color: t.color, ts: t.ts, mk: b.markerStyle, sep: c.sep)
  c.sep = 1
  if b.marker.len > 0 and b.markerStyle notin {lsDisc, lsCircle, lsSquare, lsNone}:
    d.text = b.marker
    d.w = textWidth(b.marker, t.ts)
    d.h = t.fh
  else:
    if b.markerStyle == lsNone: return
    d.text = "-"
    let sz = max(4, int(t.fh) * 2 div 5)
    d.w = sz
    d.h = sz
  let gap = max(4, int(t.spaceW) * 2)
  d.x = (if c.mRtl: c.mRight + gap else: c.mX - gap - int(d.w))
  d.y = (if d.text.len > 0 and d.text != "-": baseline - int(t.asc)
              else: baseline - int(t.asc) div 2 - int(d.h) div 2 - 1)
  if d.text == "-": d.text = ""
  c.p.items.add d

# ---- lines --------------------------------------------------------------------------------------

proc band(c: Lay; y, h, x0, x1: int): (int, int) =
  ## The room floats leave at `y` .. `y + h` between `x0` and `x1`.
  result = (x0, x1)
  for f in c.floats:
    if f.y1 > y and f.y0 < y + max(1, h):
      if f.left: result[0] = max(result[0], f.x1)
      else: result[1] = min(result[1], f.x0)

proc floatsBottom(c: Lay; side = 3): int =
  for f in c.floats:
    if (f.left and (side and 1) != 0) or (not f.left and (side and 2) != 0):
      result = max(result, f.y1)

proc nextFloatBottom(c: Lay; y: int): int =
  result = high(int)
  for f in c.floats:
    if f.y1 > y: result = min(result, f.y1)

proc layoutBox(c: var Lay; b: Box; x, w: int; y: var int): tuple[w, h: int]
proc placeFloat(c: var Lay; b: Box; x0, x1, y: int)
proc shrinkWidth(c: var Lay; b: Box; avail: int): int

proc layoutAtomic(c: var Lay; li: var LI; b: Box; avail: int) =
  ## A picture or inline block of a line, laid out at the origin (moved
  ## to its place when the line is done).
  let s = c.S(b.st)
  li.ml = (c.lenPx(s.margin[3], avail))
  let mr = c.lenPx(s.margin[1], avail)
  li.mt = (c.lenPx(s.margin[0], avail))
  let mb = c.lenPx(s.margin[2], avail)
  if b.kind == bxImage:
    let ew = c.bw(s, 1) + c.bw(s, 3)
    let eh = c.bw(s, 0) + c.bw(s, 2)
    let (w, h) = c.imageSize(b, max(1, avail - int(li.ml) - mr - ew))
    li.aw = (w + ew)
    li.ah = (h + eh)
    li.pic = b.pic
    li.base = li.ah
  else:
    li.ra = (c.p.items.len)
    c.lastBaseline = -1
    var yy = 0
    let bw = c.shrinkWidth(b, max(0, avail - int(li.ml) - mr))
    let savedMarker = c.mPending
    c.mPending = false
    let (ww, hh) = c.layoutBox(b, 0, bw, yy)
    c.mPending = savedMarker
    li.aw = (ww)
    li.ah = (hh)
    li.rb = (c.p.items.len)
    li.base = (if c.lastBaseline >= 0: c.lastBaseline else: hh)
    c.lastBaseline = -1
  li.w = li.aw + li.ml + mr
  li.base += li.mt
  li.ah += li.mt + mb

proc bidiOrder(lis: seq[LI]; order: var seq[int]; levels: var seq[int8]; rtlPara: bool) =
  ## The order the line's pieces are shown in, left to right (words of the
  ## other direction keep their own order).
  let n = lis.len
  order.setLen(n)
  for i in 0 ..< n: order[i] = i
  levels.setLen(n)
  var anyOther = false
  for i, l in lis:
    var lv: int8 = -1
    if l.kind == ikText:
      case strongDir(l.text)
      of 0: lv = if rtlPara: 2 else: 0
      of 1: lv = 1
      of 2: lv = if rtlPara: 2 else: 0
      else: lv = -1
    elif l.kind == ikAtomic: lv = if rtlPara: 1 else: 0
    levels[i] = lv
    if lv == 1 and not rtlPara: anyOther = true
    if lv != 1 and lv != -1 and rtlPara: anyOther = true
  if not rtlPara and not anyOther:
    for i in 0 ..< n: levels[i] = 0
    return
  # neutral pieces take the direction of what is around them
  let base: int8 = if rtlPara: 1 else: 0
  for i in 0 ..< n:
    if levels[i] == -1:
      var a = i - 1
      while a >= 0 and levels[a] == -1: dec a
      var b = i + 1
      while b < n and levels[b] == -1: inc b
      let la = if a >= 0: levels[a] else: base
      let lb = if b < n: levels[b] else: base
      levels[i] = if la == lb: la else: base
  for level in [2'i8, 1'i8]:
    var i = 0
    while i < n:
      if levels[order[i]] >= level:
        var j = i
        while j < n and levels[order[j]] >= level: inc j
        var (a, b) = (i, j - 1)
        while a < b:
          swap(order[a], order[b])
          inc a
          dec b
        i = j
      else: inc i

proc endOf(s: string; start, n: int): int =
  ## The byte after `n` letters of `s` from byte `start` (or `s.len`).
  result = start
  var k = 0
  while result < s.len and k < n:
    result += max(1, runeLenAt(s, result))
    inc k

proc layoutLines(c: var Lay; b: Box; x, w: int; y: var int) =
  ## A block's lines: its items wrapped to width `w` at `x`, from `y`.
  let bs = c.S(b.st)
  let strut = c.T(b.tst)
  let items = addr b.items
  let n = items[].len
  if n == 0: return
  # pictures and inline blocks first (their size, what they draw)
  var atoms = newSeq[LI](0)
  var atomAt = newSeq[int32](0)
  var anyAtomic = false
  for it in items[]:
    if it.kind == ikAtomic:
      anyAtomic = true
      break
  if anyAtomic:
    atomAt = newSeq[int32](n)
    for i in 0 ..< n:
      atomAt[i] = -1
      if items[i].kind == ikAtomic:
        var li = LI(it: int32(i), kind: ikAtomic)
        c.layoutAtomic(li, items[i].box, w)
        atomAt[i] = int32(atoms.len)
        atoms.add li
  template itemW(i: int): int =
    (if items[i].kind == ikAtomic: int(atoms[atomAt[i]].w) else: int(items[i].w))
  # how wide each unbreakable stretch is, from each item
  var chain = newSeq[int32](n)
  for i in countdown(n - 1, 0):
    let it = addr items[i]
    var v = if it.kind in {ikText, ikAtomic, ikOpen, ikClose}: itemW(i) else: 0
    if i + 1 < n and items[i + 1].glue and items[i + 1].kind in {ikText, ikAtomic, ikOpen, ikClose}:
      let nx = addr items[i + 1]
      v += int(chain[i + 1]) + (if nx.space and nx.kind == ikText: int(c.T(nx.sty).spaceW) else: 0)
    elif i + 1 < n and items[i + 1].kind in {ikOpen, ikClose} and not items[i + 1].space:
      v += int(chain[i + 1])
    chain[i] = int32(min(v, 1_000_000))
  let align0 = bs.align
  let rtl = b.rtl
  var i = 0
  var off = 0                    # (a word broken: where its rest begins)
  var pendingFloats: seq[Box]
  var opens: seq[int32]          # inline boxes still open (their items)
  var first = true
  var lis: seq[LI]
  var order: seq[int]
  var levels: seq[int8]
  while i < n:
    # the room on this line
    let (l, r) = c.band(y, int(strut.lh), x, x + w)
    let avail = max(1, r - l)
    lis.setLen(0)
    var lw = 0
    var content = false
    var forced = false
    var brokeAtSpace = false
    let startOpens = opens
    let emergency = int(chain[i]) > avail
    while i < n:
      let it = addr items[i]
      case it.kind
      of ikBreak:
        inc i
        forced = true
        break
      of ikAnchor:
        c.p.items.add DItem(kind: dkAnchor, x: (l), y: (y), text: it.text, link: -1)
        inc i
        continue
      of ikFloat:
        if not content:
          c.placeFloat(it.box, x, x + w, y)
          inc i
          break           # (the room of the line changed)
        pendingFloats.add it.box
        inc i
        continue
      of ikOpen, ikClose:
        var gap = 0
        if it.space and content:
          gap = int(strut.spaceW)
          if int(chain[i]) + gap > avail - lw:
            brokeAtSpace = true
            break
        lis.add LI(it: int32(i), kind: it.kind, x: lw + gap, w: it.w, gap: gap)
        lw += gap + int(it.w)
        if it.kind == ikOpen: opens.add int32(i)
        else:
          for k in countdown(opens.high, 0):
            if items[opens[k]].sty == it.sty:
              opens.delete(k)
              break
        inc i
        continue
      of ikText, ikAtomic:
        let t = if it.kind == ikText: c.T(it.sty) else: strut
        if it.kind == ikText and t.tiny:
          inc i
          continue
        let gap = if it.space and content: int(t.spaceW) else: 0
        # (the rest of a broken word: measured only when it can fit -- a word
        # of a million letters costs what its lines cost)
        var iw = itemW(i)
        if off > 0:
          iw = if endOf(it.text, off, 4 * avail + 4) < it.text.len: 2 * avail + 1
               else: textWidth(it.text[off .. ^1], t.ts)
        let room = avail - lw - gap
        if content and (not it.glue or emergency) and
           (if it.glue: iw > room else: (if off > 0: iw else: int(chain[i])) > room):
          brokeAtSpace = it.space
          break
        if it.kind == ikText and iw > avail - lw - gap and (not content or emergency):
          # a word wider than the line: as much of it as fits
          let s = it.text
          let room2 = max(1, avail - lw - gap)
          var lo = 1
          var hi = 0
          var p = off
          while p < s.len and hi <= room2:
            p += max(1, runeLenAt(s, p))
            inc hi
          if p >= s.len: dec hi           # (all of it does not fit)
          hi = max(1, min(hi, room2))
          while lo < hi:
            let mid = (lo + hi + 1) div 2
            if textWidth(s[off ..< endOf(s, off, mid)], t.ts) <= avail - lw - gap: lo = mid
            else: hi = mid - 1
          if content and textWidth(s[off ..< endOf(s, off, lo)], t.ts) > avail - lw - gap:
            break
          let e = endOf(s, off, lo)
          let part = s[off ..< e]
          let pw = textWidth(part, t.ts)
          lis.add LI(it: int32(i), kind: ikText, x: (lw + gap), w: pw, gap: gap,
                      text: part, part: true)
          lw += gap + pw
          content = true
          if e >= s.len:
            off = 0
            inc i
          else:
            off = e
          break
        var li = if it.kind == ikAtomic: atoms[atomAt[i]] else: LI(it: int32(i), kind: ikText)
        li.x = (lw + gap)
        li.gap = (gap)
        if it.kind == ikText:
          li.w = (iw)
          if off > 0:
            li.text = it.text[off .. ^1]
            li.part = true
            off = 0
        lis.add li
        lw += gap + int(li.w)
        content = true
        inc i
    if not content and not forced and lis.len == 0:
      # floats, anchors only
      for f in pendingFloats: c.placeFloat(f, x, x + w, y)
      pendingFloats.setLen(0)
      continue
    # the line's height: its tallest pieces above and below the baseline
    var maxA, maxD = 0
    var hasText = false
    for li in lis.mitems:
      if li.kind == ikText:
        hasText = true
        let t = c.T(items[li.it].sty)
        li.a = t.asc + (t.lh - t.fh) div 2
        li.d = t.lh - li.a
        if t.valign == vaSub:
          let s = t.fh div 4
          li.a -= (s)
          li.d += (s)
        elif t.valign == vaSuper:
          let s = t.fh div 3
          li.a += (s)
          li.d -= (s)
        maxA = max(maxA, int(li.a))
        maxD = max(maxD, int(li.d))
    let sA = int(strut.asc) + (int(strut.lh) - int(strut.fh)) div 2
    let sD = int(strut.lh) - sA
    let onlyAtoms = not hasText and lis.len > 0
    if not onlyAtoms and not strut.tiny:
      maxA = max(maxA, sA)
      maxD = max(maxD, sD)
    for li in lis.mitems:
      if li.kind == ikAtomic:
        let s = c.S(items[li.it].box.st)
        case s.valign
        of vaMiddle:
          let mid = int(strut.asc) div 3
          li.a = (int(li.ah) div 2 + mid)
          li.d = li.ah - li.a
        of vaTop, vaTextTop:
          li.a = (max(maxA, min(int(li.ah), sA)))
          li.d = li.ah - li.a
        else:
          li.a = li.base
          li.d = li.ah - li.base
        maxA = max(maxA, int(li.a))
        maxD = max(maxD, int(li.d))
    var lineH = maxA + maxD
    if lis.len == 0 and forced: lineH = int(strut.lh)
    # where the line starts: its alignment, its direction
    let align = case align0
      of taStart: (if rtl: taRight else: taLeft)
      of taEnd: (if rtl: taLeft else: taRight)
      else: align0
    var indent = 0
    if first and bs.textIndent != 0 and not b.anon: indent = c.lp(bs.textIndent)
    let free = avail - lw - indent
    var x0 = l + (if rtl: 0 else: indent)
    case align
    of taRight: x0 += free
    of taCenter: x0 += free div 2
    else: discard
    bidiOrder(lis, order, levels, rtl)
    var vx = x0
    for k in 0 ..< order.len:
      let li = addr lis[order[k]]
      if k > 0:
        let prev = order[k - 1]
        let cur = order[k]
        vx += (if abs(prev - cur) == 1: int(lis[max(prev, cur)].gap)
               elif li.kind == ikText: int(strut.spaceW) else: 0)
      li.vx = (vx)
      vx += int(li.w)
    let baseline = y + maxA
    # the boxes of inline elements open on this line (backgrounds, borders)
    if opens.len > 0 or startOpens.len > 0 or lis.len > 0:
      var spans: seq[tuple[sty, link: int32; a, b: int]]
      for o in startOpens:
        spans.add (items[o].sty, items[o].link, -1, -1)
      for k, li in lis:
        if li.kind == ikOpen:
          spans.add (items[li.it].sty, items[li.it].link, k, -1)
        elif li.kind == ikClose:
          for sIdx in countdown(spans.high, 0):
            if spans[sIdx].sty == items[li.it].sty and spans[sIdx].b == -1:
              spans[sIdx].b = k
              break
      for sp in spans:
        let a = if sp.a < 0: 0 else: sp.a
        let ts0 = if sp.a >= 0: items[lis[sp.a].it].tsi
                  elif sp.b >= 0: items[lis[sp.b].it].tsi
                  else: b.tst
        let e = if sp.b < 0: lis.high else: sp.b
        if e < a or lis.len == 0: continue
        var minX = high(int)
        var maxX = low(int)
        for k in a .. e:
          let li = lis[k]
          minX = min(minX, int(li.vx))
          maxX = max(maxX, int(li.vx) + int(li.w))
        if minX > maxX: continue
        let s = c.S(sp.sty)
        let t = c.T(ts0)
        # (its own font's box, with its padding)
        let ml = if sp.a >= 0: c.lenPx(s.margin[3], 0) else: 0
        let mr = if sp.b >= 0: c.lenPx(s.margin[1], 0) else: 0
        let pt = c.lenPx(s.padding[0], 0) + c.bw(s, 0)
        let pb = c.lenPx(s.padding[2], 0) + c.bw(s, 2)
        let fhh = int(t.fh)
        let top = baseline - int(t.asc) - pt
        if s.bg != 0 or s.bw[0] > 0 or s.bw[1] > 0 or s.bw[2] > 0 or s.bw[3] > 0:
          let slot = c.reserveBox(s)
          if slot >= 0:
            if sp.a < 0: c.p.items[slot].bw[3] = 0
            if sp.b < 0: c.p.items[slot].bw[1] = 0
            c.patch(slot, minX + ml, top, maxX - minX - ml - mr, fhh + pt + pb)
        if sp.link >= 0:
          c.p.items.add DItem(kind: dkLinkArea, x: (minX + ml), y: (top),
                              w: (maxX - minX - ml - mr), h: (fhh + pt + pb),
                              link: sp.link)
    # the marker of a list item
    if c.mPending: c.emitMarker(baseline)
    # the words (pieces of the same look together), pictures, inline blocks
    var k = 0
    var lineSep = c.sep
    var firstText = true
    c.sep = 0
    while k < lis.len:
      let li = addr lis[k]
      case li.kind
      of ikText:
        let it = addr items[li.it]
        let t = c.T(it.sty)
        let lv = levels[k]
        let isRtl = lv == 1
        var text = if li.part: li.text else: it.text
        var x0 = int(li.vx)
        var x1 = int(li.vx) + int(li.w)
        var j = k + 1
        while j < lis.len:
          let nx = addr lis[j]
          if nx.kind != ikText: break
          let nit = addr items[nx.it]
          if nit.sty != it.sty or nit.link != it.link or levels[j] != lv: break
          let adj = if isRtl: abs(int(nx.vx) + int(nx.w) + int(nx.gap) - x0) <= 1
                    else: abs(x1 + int(nx.gap) - int(nx.vx)) <= 1
          if not adj: break
          if nx.gap > 0: text.add ' '
          text.add(if nx.part: nx.text else: nit.text)
          x0 = min(x0, int(nx.vx))
          x1 = max(x1, int(nx.vx) + int(nx.w))
          inc j
        if not t.invisible:
          let sep = if firstText: lineSep elif li.gap > 0: 1'i8 else: 0'i8
          firstText = false
          var yy = baseline - int(t.asc)
          if t.valign == vaSub: yy += int(t.fh) div 4
          elif t.valign == vaSuper: yy -= int(t.fh) div 3
          c.emitText(x0, yy, x1 - x0, text, t, it.link, isRtl, sep)
        k = j
        continue
      of ikAtomic:
        let it = addr items[li.it]
        let bx = it.box
        let top = baseline - int(li.a) + int(li.mt)
        let left = int(li.vx) + int(li.ml)
        if bx.kind == bxImage:
          let s = c.S(bx.st)
          let ew = c.bw(s, 1) + c.bw(s, 3)
          let eh = c.bw(s, 0) + c.bw(s, 2)
          let iw = int(li.aw) - ew
          let picH = int(li.ah) - int(li.mt) - c.lenPx(s.margin[2], 0) - eh
          if ew > 0 or eh > 0:
            let slot = c.reserveBox(s)
            c.patch(slot, left, top, int(li.aw), picH + eh)
          let ix = left + c.bw(s, 3)
          let iy = top + c.bw(s, 0)
          if li.pic != nil:
            c.p.items.add DItem(kind: dkImage, x: (ix), y: (iy), w: (iw),
                                h: (picH), pic: li.pic, link: it.link, src: bx.src,
                                sep: (if k == 0: lineSep else: 0))
          elif iw >= 4 and picH >= 4:
            c.p.items.add DItem(kind: dkMissing, x: (ix), y: (iy), w: (iw),
                                h: (picH), text: bx.alt, link: it.link, ts: c.T(bx.tst).ts,
                                src: bx.src)
          c.p.right = max(c.p.right, left + int(li.aw))
        else:
          c.shift(int(li.ra), int(li.rb), left, top)
          if bx.isLink and it.link >= 0:
            c.p.items.add DItem(kind: dkLinkArea, x: (left), y: (top),
                                w: li.aw, h: (int(li.ah) - int(li.mt)), link: it.link)
      else: discard
      inc k
    c.lastBaseline = baseline
    y += lineH
    first = false
    # (an empty line is a blank line in the text)
    c.sep = if forced and lis.len == 0 and lineSep >= 3: 4'i8
            elif forced: 3 elif brokeAtSpace: 1 else: 0
    for f in pendingFloats: c.placeFloat(f, x, x + w, y)
    pendingFloats.setLen(0)
  for f in pendingFloats: c.placeFloat(f, x, x + w, y)

# ---- blocks ------------------------------------------------------------------------------------

proc topEdge(c: Lay; s: ptr CStyle; base: int): bool =
  c.bw(s, 0) > 0 or c.lenPx(s.padding[0], base) > 0

proc bfcRoot(c: Lay; b: Box): bool =
  let s = c.S(b.st)
  b.cell or s.overflowHidden or s.floatSide != 0 or s.display in {dsInlineBlock, dsInlineTable} or
    b.kind != bxBlock or (s.flow != bfNormal and not b.anon)

proc firstChild(b: Box): Box =
  for k in b.kids:
    return k
  nil

proc addFirstChain(c: var Lay; b: Box; mc: var MC; base: int) =
  ## The top margins of a block's first children that meet its own.
  if b.inl or b.kids.len == 0: return
  let f = firstChild(b)
  if f == nil or f.anon: return
  let fs = c.S(f.st)
  if fs.floatSide != 0: return
  mc.add(c.lenPx(fs.margin[0], base))
  if f.kind == bxBlock and not c.topEdge(fs, base) and not c.bfcRoot(f):
    c.addFirstChain(f, mc, base)

proc sepOf(c: Lay; b: Box; s: ptr CStyle): int8 =
  if b.cell: 0
  elif b.anon: 3
  elif (s.margin[0].k == lkPx and s.margin[0].v > 0) or (s.margin[2].k == lkPx and s.margin[2].v > 0) or
       b.tag in ["blockquote", "table", "pre"]: 4
  else: 3

proc flowKids(c: var Lay; b: Box; x, w: int; y: var int; mc: var MC; chainDone: bool)
proc flowChild(c: var Lay; b: Box; parent: int32; x, cbW: int; y: var int; mc: var MC;
               chainDone: bool)

proc layoutTable(c: var Lay; t: Box; x, cbW: int; y: var int; parent: int32): tuple[w, h: int]

# ---- flexible boxes and grids ----------------------------------------------------------------

proc cellBox(c: var Lay; k: Box; x, w, y: int): int =
  ## (one box of a flexible row or column or of a grid, `w` wide at `x`,
  ## `y`, its margins outside: its height)
  var yy = y
  if k.anon:
    c.layoutLines(k, x, w, yy)
    return yy - y
  c.layoutBox(k, x, w, yy).h

proc stretchBox(c: var Lay; a, x, top, h: int) =
  ## (the background and border of a box laid out from item `a` at `x`,
  ## `top`: made `h` high -- a row's boxes stretched to the row)
  if a < c.p.items.len and c.p.items[a].kind == dkBox and c.p.items[a].x == x and c.p.items[a].y == top:
    c.p.items[a].h = max(c.p.items[a].h, h)

proc alignOf(c: Lay; k: Box; s: ptr CStyle): FlexAlign =
  if k.anon: s.alignItems
  else:
    let a = c.S(k.st).alignSelf
    if a == faAuto: s.alignItems else: a

proc cellsInOrder(c: Lay; b: Box; reverse: bool): seq[Box] =
  ## (a flexible box's or grid's children, by their `order`)
  result = b.kids
  var any = false
  for k in result:
    if not k.anon and c.S(k.st).order != 0: any = true
  if any:
    var key = newSeq[(int, int)](result.len)
    for i, k in result: key[i] = ((if k.anon: 0 else: int(c.S(k.st).order)), i)
    key.sort()
    let was = result
    for i, (_, j) in key: result[i] = was[j]
  if reverse: result.reverse()

proc placeRow(c: var Lay; s: ptr CStyle; boxes: seq[Box]; xs, ws, mts, mbs: seq[int];
              top: int; rtl: bool; x, w: int): int =
  ## (a row of boxes laid out at `xs` (from the row's left), `ws` wide,
  ## then put in their places across it: its height)
  var at, h: seq[int]
  var lineH = 0
  for i, k in boxes:
    let bx = if rtl: x + w - xs[i] - ws[i] else: x + xs[i]
    at.add c.p.items.len
    let hh = c.cellBox(k, bx, ws[i], top + mts[i])
    h.add hh
    lineH = max(lineH, mts[i] + hh + mbs[i])
  for i, k in boxes:
    let e = if i + 1 < boxes.len: at[i + 1] else: c.p.items.len
    let room = lineH - mts[i] - h[i] - mbs[i]
    case c.alignOf(k, s)
    of faCenter: c.shift(at[i], e, 0, room div 2)
    of faEnd: c.shift(at[i], e, 0, room)
    of faStretch, faAuto:
      if not k.anon and c.S(k.st).height.k == lkAuto:
        let bx = if rtl: x + w - xs[i] - ws[i] else: x + xs[i]
        c.stretchBox(at[i], bx, top + mts[i], lineH - mts[i] - mbs[i])
    of faStart: discard
  lineH

proc flexFlow(c: var Lay; b: Box; x, w: int; y: var int) =
  ## A flexible box's children: in a row (wrapped into more when `wrap`),
  ## sized from their basis or content, sharing the room left as `grow`
  ## and `shrink` say, placed along it as `justify` and across it as
  ## `align`; or in a column.
  let s = c.S(b.st)
  let boxes = c.cellsInOrder(b, s.reverse)
  if boxes.len == 0: return
  let gapC = max(0, c.lenPx(s.gapCol, w))
  let gapR = max(0, c.lenPx(s.gapRow, w))
  let rtl = s.dir == dirRtl
  if s.column:
    for i, k in boxes:
      if i > 0: y += gapR
      let ks = c.S(k.st)
      let ml = if k.anon: 0 else: c.lenPx(ks.margin[3], w)
      let mr = if k.anon: 0 else: c.lenPx(ks.margin[1], w)
      let mt = if k.anon: 0 else: c.lenPx(ks.margin[0], w)
      let mb = if k.anon: 0 else: c.lenPx(ks.margin[2], w)
      let avail = max(0, w - ml - mr)
      let al = c.alignOf(k, s)
      let kw = if k.anon or (al in {faStretch, faAuto} and ks.width.k == lkAuto): avail
               else: c.shrinkWidth(k, avail)
      var off = case al
                of faCenter: (avail - kw) div 2
                of faEnd: avail - kw
                else: 0
      if rtl: off = avail - kw - off
      y += mt + c.cellBox(k, x + ml + off, kw, y + mt) + mb
    return
  # each box's size before the room is shared: its basis, its width, else its content's
  var base, least, ml, mr, mt, mb: seq[int]
  var grow, shrink: seq[float32]
  for k in boxes:
    let ks = c.S(k.st)
    let l = if k.anon: 0 else: c.lenPx(ks.margin[3], w)
    let r = if k.anon: 0 else: c.lenPx(ks.margin[1], w)
    ml.add l
    mr.add r
    mt.add(if k.anon: 0 else: c.lenPx(ks.margin[0], w))
    mb.add(if k.anon: 0 else: c.lenPx(ks.margin[2], w))
    let avail = max(0, w - l - r)
    let (mn, mx) = c.intrinsic(k)
    var bs: int
    if k.anon: bs = min(mx, avail)
    elif ks.basis.k in {lkPx, lkPct}:
      bs = c.lenPx(ks.basis, w) + (if ks.borderBox or k.kind != bxBlock: 0 else: c.hEdges(ks, w))
    else: bs = c.shrinkWidth(k, avail)
    base.add max(0, bs)
    least.add(if not k.anon and ks.width.k == lkPx: bs else: min(mn, avail))
    grow.add(if k.anon: 0'f32 else: ks.grow)
    shrink.add(if k.anon: 1'f32 else: ks.shrink)
  # the rows
  var rows: seq[(int, int)]
  var first = 0
  var used = 0
  for i in 0 ..< boxes.len:
    let outer = base[i] + ml[i] + mr[i]
    if s.wrap and i > first and used + gapC + outer > w:
      rows.add (first, i)
      first = i
      used = 0
    used += (if i > first: gapC else: 0) + outer
  rows.add (first, boxes.len)
  for ri, (a, e) in rows:
    if ri > 0: y += gapR
    let n = e - a
    var ws = base[a ..< e]
    var sum = 0
    for i in a ..< e: sum += base[i] + ml[i] + mr[i]
    var free = w - sum - gapC * (n - 1)
    if free > 0:
      var g = 0'f32
      for i in a ..< e: g += grow[i]
      if g > 0:
        var given = 0
        for i in a ..< e:
          let add = int(float32(free) * grow[i] / g)
          ws[i - a] += add
          given += add
        # (what rounding left, to the last that grows)
        for i in countdown(e - 1, a):
          if grow[i] > 0:
            ws[i - a] += free - given
            break
        free = 0
    elif free < 0:
      var weight = 0'f32
      for i in a ..< e: weight += shrink[i] * float32(base[i])
      if weight > 0:
        for i in a ..< e:
          let cut = int(float32(-free) * shrink[i] * float32(base[i]) / weight + 0.5)
          ws[i - a] = max(least[i], base[i] - cut)
      free = w - gapC * (n - 1)
      for i in a ..< e: free -= ws[i - a] + ml[i] + mr[i]
    for i in a ..< e:
      let ks = c.S(boxes[i].st)
      if not boxes[i].anon:
        if ks.maxW.k == lkPx: ws[i - a] = min(ws[i - a], c.lp(ks.maxW.v) + (if ks.borderBox: 0 else: c.hEdges(ks, w)))
        if ks.minW.k == lkPx: ws[i - a] = max(ws[i - a], c.lp(ks.minW.v) + (if ks.borderBox: 0 else: c.hEdges(ks, w)))
    # along the row: where the room left goes
    var left = w - gapC * (n - 1)
    for i in a ..< e: left -= ws[i - a] + ml[i] + mr[i]
    left = max(0, left)
    var start = 0
    var step = 0
    case s.justify
    of fjEnd: start = left
    of fjCenter: start = left div 2
    of fjBetween: step = (if n > 1: left div (n - 1) else: 0)
    of fjAround:
      step = left div n
      start = step div 2
    of fjEvenly:
      step = left div (n + 1)
      start = step
    of fjStart: discard
    var xs: seq[int]
    var cx = start
    for i in a ..< e:
      cx += ml[i]
      xs.add cx
      cx += ws[i - a] + mr[i] + gapC + step
    y += c.placeRow(s, boxes[a ..< e], xs, ws, mt[a ..< e], mb[a ..< e], y, rtl, x, w)

proc gridFlow(c: var Lay; b: Box; x, w: int; y: var int) =
  ## A grid's children, row by row in its columns (grid-template-columns:
  ## pixels, percents, shares of what is left, as many as fit), each as
  ## many columns wide as its `grid-column` says.
  let s = c.S(b.st)
  let boxes = c.cellsInOrder(b, false)
  if boxes.len == 0: return
  let gapC = max(0, c.lenPx(s.gapCol, w))
  let gapR = max(0, c.lenPx(s.gapRow, w))
  var tracks = s.tracks
  for t in s.tracks:
    if t.k == gtFill:
      let least = max(1, c.lp(t.v))
      let n = clamp((w + gapC) div (least + gapC), 1, 100)
      tracks = newSeq[GridTrack](n)
      for tr in tracks.mitems: tr = GridTrack(k: gtFr, v: 1)
      break
  if tracks.len == 0: tracks = @[GridTrack(k: gtFr, v: 1)]
  let n = tracks.len
  let avail = max(0, w - gapC * (n - 1))
  var cols = newSeq[int](n)
  var fixed = 0
  var fr = 0'f32
  for i, t in tracks:
    case t.k
    of gtPx: cols[i] = c.lp(t.v)
    of gtPct: cols[i] = int(float32(avail) * t.v / 100)
    else: fr += max(0.01'f32, t.v)
    fixed += cols[i]
  let rest = max(0, avail - fixed)
  for i, t in tracks:
    if t.k in {gtFr, gtAuto, gtFill}: cols[i] = int(float32(rest) * max(0.01'f32, t.v) / fr)
  var colX = newSeq[int](n)
  var cx = 0
  for i in 0 ..< n:
    colX[i] = cx
    cx += cols[i] + gapC
  # rows of boxes, each in the next columns free
  var i = 0
  var firstRow = true
  while i < boxes.len:
    var row: seq[Box]
    var xs, ws, mts, mbs: seq[int]
    var col = 0
    while i < boxes.len:
      let k = boxes[i]
      let ks = c.S(k.st)
      let span = if k.anon: 1 else: clamp(int(ks.colSpan), 1, n)
      if col > 0 and col + span > n: break
      var cw = 0
      for j in col ..< min(n, col + span): cw += cols[j]
      cw += gapC * (min(n, col + span) - col - 1)
      let ml = if k.anon: 0 else: c.lenPx(ks.margin[3], w)
      let mr = if k.anon: 0 else: c.lenPx(ks.margin[1], w)
      row.add k
      xs.add colX[col] + ml
      ws.add max(0, cw - ml - mr)
      mts.add(if k.anon: 0 else: c.lenPx(ks.margin[0], w))
      mbs.add(if k.anon: 0 else: c.lenPx(ks.margin[2], w))
      col += span
      inc i
      if col >= n: break
    if not firstRow: y += gapR
    firstRow = false
    y += c.placeRow(s, row, xs, ws, mts, mbs, y, s.dir == dirRtl, x, w)

proc contentFlow(c: var Lay; b: Box; x, w: int; y: var int; mc: var MC; chainDone: bool) =
  ## A block's content: its lines, or its children.
  if not b.anon and not b.inl and c.S(b.st).flow != bfNormal:
    y += mc.total
    mc = MC()
    if c.S(b.st).flow == bfFlex: c.flexFlow(b, x, w, y) else: c.gridFlow(b, x, w, y)
    return
  if b.inl:
    y += mc.total
    mc = MC()
    if c.mPending and b.items.len == 0: c.emitMarker(y + int(c.T(b.tst).asc))
    c.layoutLines(b, x, w, y)
  else:
    c.flowKids(b, x, w, y, mc, chainDone)

proc flowKids(c: var Lay; b: Box; x, w: int; y: var int; mc: var MC; chainDone: bool) =
  var first = true
  for k in b.kids:
    let isFloat = c.S(k.st).floatSide != 0 and not k.anon and not k.cell
    c.flowChild(k, b.st, x, w, y, mc, chainDone and first)
    if not isFloat: first = false

proc blockWidth(c: Lay; b: Box; s: ptr CStyle; cbW: int; ml, mr: int): int =
  ## A block's content width in a containing block `cbW` wide.
  let edges = c.hEdges(s, cbW)
  let avail = cbW - ml - mr - edges
  var w = avail
  if s.width.k in {lkPx, lkPct}:
    w = c.lenPx(s.width, cbW) - (if s.borderBox: edges else: 0)
    w = min(w, avail)              # (wider than the room: made to fit, as mail apps do)
  if s.maxW.k in {lkPx, lkPct}:
    w = min(w, c.lenPx(s.maxW, cbW) - (if s.borderBox: edges else: 0))
  if s.minW.k in {lkPx, lkPct}:
    w = max(w, min(avail, c.lenPx(s.minW, cbW) - (if s.borderBox: edges else: 0)))
  max(0, w)

proc blockX(c: Lay; s, ps: ptr CStyle; x, cbW, outerW, ml, mr: int; rtlParent: bool): int =
  ## Where a block of width `outerW` (border box) starts: auto margins
  ## and old align attributes center it or put it at the right.
  let free = cbW - outerW - ml - mr
  if free <= 0: return x + ml
  let autoL = s.margin[3].k == lkAuto
  let autoR = s.margin[1].k == lkAuto
  if autoL and autoR: return x + ml + free div 2
  if autoL: return x + ml + free
  if autoR: return x + ml
  if ps.alignBlocks:
    if ps.align == taCenter: return x + ml + free div 2
    if ps.align == taRight: return x + ml + free
  if rtlParent and (s.width.k != lkAuto or s.maxW.k in {lkPx, lkPct}): return x + ml + free
  x + ml

proc layoutBox(c: var Lay; b: Box; x, w: int; y: var int): tuple[w, h: int] =
  ## A box that holds its floats and margins (an inline block, a float, a
  ## cell's content) laid out `w` wide (border box) at `x`, `y`: its size.
  let s = c.S(b.st)
  let top = y
  case b.kind
  of bxTable:
    let r = c.layoutTable(b, x, w, y, b.st)
    return r
  of bxImage:
    let (iw, ih) = c.imageSize(b, w)
    let ew = c.bw(s, 1) + c.bw(s, 3)
    let eh = c.bw(s, 0) + c.bw(s, 2)
    let slot = c.reserveBox(s)
    c.patch(slot, x, y, iw + ew, ih + eh)
    let pic = b.pic
    if pic != nil:
      c.p.items.add DItem(kind: dkImage, x: (x + c.bw(s, 3)), y: (y + c.bw(s, 0)),
                          w: (iw), h: (ih), pic: pic, link: b.link, src: b.src)
    elif iw >= 4 and ih >= 4:
      c.p.items.add DItem(kind: dkMissing, x: (x + c.bw(s, 3)), y: (y + c.bw(s, 0)),
                          w: (iw), h: (ih), text: b.alt, link: b.link,
                          ts: c.T(b.tst).ts, src: b.src)
    y += ih + eh
    return (iw + ew, ih + eh)
  of bxBlock:
    let slot = if b.cell: -1 else: c.reserveBox(s)
    let pt = c.lenPx(s.padding[0], w) + c.bw(s, 0)
    let pb = c.lenPx(s.padding[2], w) + c.bw(s, 2)
    let pl = c.lenPx(s.padding[3], w) + c.bw(s, 3)
    let pr = c.lenPx(s.padding[1], w) + c.bw(s, 1)
    let saved = move c.floats
    c.floats = @[]
    y += pt
    var mc = MC()
    c.boundary(c.sepOf(b, s))
    if b.anchor.len > 0:
      c.p.items.add DItem(kind: dkAnchor, x: (x), y: (top), text: b.anchor, link: -1)
    let inner = max(0, w - pl - pr)
    c.contentFlow(b, x + pl, inner, y, mc, chainDone = b.cell)
    if not b.cell: y += mc.total
    y = max(y, c.floatsBottom())
    var h = y - top + pb
    if s.height.k == lkPx:
      h = max(h, c.lp(s.height.v) + (if s.borderBox or b.cell: 0 else: pt + pb))
    if s.minH.k == lkPx: h = max(h, c.lp(s.minH.v) + (if s.borderBox: 0 else: pt + pb))
    c.floats = saved
    y = top + h
    if not b.canvas: c.patch(slot, x, top, w, h)
    if b.isLink and b.link >= 0:
      c.p.items.add DItem(kind: dkLinkArea, x: (x), y: (top), w: (w), h: (h),
                          link: b.link)
    c.boundary(c.sepOf(b, s))
    return (w, h)

proc shrinkWidth(c: var Lay; b: Box; avail: int): int =
  ## The border-box width of an inline block or float: as asked, else as
  ## narrow as its content allows in `avail`.
  let s = c.S(b.st)
  if b.kind == bxImage:
    let (iw, _) = c.imageSize(b, avail)
    return iw + c.bw(s, 1) + c.bw(s, 3)
  let edges = c.hEdges(s, avail)
  let add = if s.borderBox or b.kind == bxTable: 0 else: edges
  if s.width.k in {lkPx, lkPct}:
    var w = c.lenPx(s.width, avail) + add
    if s.maxW.k in {lkPx, lkPct}: w = min(w, c.lenPx(s.maxW, avail) + add)
    return clamp(w, 0, max(0, avail))
  let (mn, mx) = c.intrinsic(b)
  result = min(max(mn, avail), mx)
  if s.maxW.k == lkPct: result = min(result, c.lenPx(s.maxW, avail) + edges)

proc placeFloat(c: var Lay; b: Box; x0, x1, y: int) =
  ## A float laid out and put at the left or right, as high as it fits
  ## from `y`; lines and floats after it go around it.
  let s = c.S(b.st)
  let cbW = x1 - x0
  let ml = c.lenPx(s.margin[3], cbW)
  let mr = c.lenPx(s.margin[1], cbW)
  let mt = c.lenPx(s.margin[0], cbW)
  let mb = c.lenPx(s.margin[2], cbW)
  let bw = c.shrinkWidth(b, max(0, cbW - ml - mr))
  let a = c.p.items.len
  var yy = 0
  let savedSep = c.sep
  let savedMarker = c.mPending
  c.mPending = false
  let (fw, fh) = c.layoutBox(b, 0, bw, yy)
  c.mPending = savedMarker
  c.sep = max(savedSep, 3)
  let e = c.p.items.len
  let ow = fw + ml + mr
  let oh = fh + mt + mb
  var fy = y
  for f in c.floats: fy = max(fy, f.y0)       # (not above a float before it)
  var guard = 0
  while guard < 200:
    inc guard
    let (l, r) = c.band(fy, oh, x0, x1)
    if r - l >= ow or (l == x0 and r == x1): break
    let nb = c.nextFloatBottom(fy)
    if nb == high(int): break
    fy = nb
  let (l, r) = c.band(fy, oh, x0, x1)
  let left = s.floatSide == 1
  let fx = if left: l else: max(l, r - ow)
  c.shift(a, e, fx + ml, fy + mt)
  c.floats.add FloatR(left: left, x0: fx, x1: fx + ow, y0: fy, y1: fy + oh)
  c.p.right = max(c.p.right, fx + ow)

proc flowChild(c: var Lay; b: Box; parent: int32; x, cbW: int; y: var int; mc: var MC;
               chainDone: bool) =
  ## One block among its siblings: its margins meeting theirs, then it.
  let s = c.S(b.st)
  let ps = c.S(parent)
  if b.anon:
    y += mc.total
    mc = MC()
    c.boundary(3)
    c.layoutLines(b, x, cbW, y)
    c.boundary(3)
    return
  if s.floatSide != 0 and not b.cell:
    c.placeFloat(b, x, x + cbW, y + mc.total)
    return
  var mt = c.lenPx(s.margin[0], cbW)
  let mb = c.lenPx(s.margin[2], cbW)
  if chainDone: mt = 0
  # a list item's marker waits for its first line
  if b.listItem:
    if c.mPending: c.emitMarker(y + mc.total + int(c.T(b.tst).asc))
  if s.clear != 0:
    let fb = c.floatsBottom(s.clear)
    if fb > y + mc.total:
      y = fb
      mc = MC()
  c.boundary(c.sepOf(b, s))
  case b.kind
  of bxTable, bxImage:
    mc.add(mt)
    y += mc.total
    mc = MC()
    if b.anchor.len > 0:
      c.p.items.add DItem(kind: dkAnchor, x: (x), y: (y), text: b.anchor, link: -1)
    if b.kind == bxTable:
      discard c.layoutTable(b, x, cbW, y, parent)
    else:
      let ml = c.lenPx(s.margin[3], cbW)
      let mr = c.lenPx(s.margin[1], cbW)
      let ew = c.bw(s, 1) + c.bw(s, 3)
      let (iw, _) = c.imageSize(b, max(1, cbW - ml - mr - ew))
      let bx = c.blockX(s, ps, x, cbW, iw + ew, ml, mr, ps.dir == dirRtl)
      if c.mPending: c.emitMarker(y + int(c.T(b.tst).asc))
      discard c.layoutBox(b, bx, iw + ew, y)
      c.p.right = max(c.p.right, bx + iw + ew)
    mc.add(mb)
    c.boundary(c.sepOf(b, s))
    return
  of bxBlock: discard
  let ml = c.lenPx(s.margin[3], cbW)
  let mr = c.lenPx(s.margin[1], cbW)
  let root = c.bfcRoot(b)
  let hasTop = c.topEdge(s, cbW) or root
  mc.add(mt)
  if not hasTop and not chainDone: c.addFirstChain(b, mc, cbW)
  y += mc.total
  mc = MC()
  # beside floats: a block that holds its own floats goes where it fits
  var bxx = x
  var bw0 = cbW
  if root and c.floats.len > 0:
    let (l, r) = c.band(y, 1, x, x + cbW)
    if l > x or r < x + cbW:
      bxx = l
      bw0 = r - l
  let cw = c.blockWidth(b, s, bw0, ml, mr)
  let edges = c.hEdges(s, bw0)
  let outer = cw + edges
  let bx = c.blockX(s, ps, bxx, bw0, outer, ml, mr, ps.dir == dirRtl)
  let top = y
  if b.anchor.len > 0:
    c.p.items.add DItem(kind: dkAnchor, x: (bx), y: (top), text: b.anchor, link: -1)
  let slot = c.reserveBox(s)
  let pt = c.lenPx(s.padding[0], cbW) + c.bw(s, 0)
  let pb = c.lenPx(s.padding[2], cbW) + c.bw(s, 2)
  let pl = c.lenPx(s.padding[3], cbW) + c.bw(s, 3)
  y += pt
  if b.listItem:
    c.mPending = true
    c.mBox = b
    c.mX = bx + pl
    c.mRight = bx + pl + cw
    c.mRtl = s.dir == dirRtl or (s.dir == dirAuto and b.inl and b.rtl)
  var saved: seq[FloatR]
  if root:
    saved = move c.floats
    c.floats = @[]
  var cmc = MC()
  c.contentFlow(b, bx + pl, cw, y, cmc, chainDone = not hasTop)
  if b.listItem and c.mPending and c.mBox == b: c.emitMarker(top + pt + int(c.T(b.tst).asc))
  let hasBottom = c.bw(s, 2) > 0 or c.lenPx(s.padding[2], cbW) > 0 or root or
                  s.height.k == lkPx or s.minH.k == lkPx
  if hasBottom:
    y += cmc.total
    cmc = MC()
  if root:
    y = max(y, c.floatsBottom())
    c.floats = saved
  var h = y - top + pb
  if s.height.k == lkPx:
    h = max(h, c.lp(s.height.v) + (if s.borderBox: 0 else: pt + pb))
  if s.minH.k == lkPx:
    h = max(h, c.lp(s.minH.v) + (if s.borderBox: 0 else: pt + pb))
  y = top + h
  if not b.canvas: c.patch(slot, bx, top, outer, h)
  if b.isLink and b.link >= 0:
    c.p.items.add DItem(kind: dkLinkArea, x: (bx), y: (top), w: (outer),
                        h: (h), link: b.link)
  c.p.right = max(c.p.right, bx + outer)
  mc = cmc
  mc.add(mb)
  c.boundary(c.sepOf(b, s))

# ---- tables --------------------------------------------------------------------------------------

proc distribute(t: Box; avail: int): seq[int] =
  ## The columns' widths in `avail` pixels: each its least, then the
  ## percentages, the fixed widths, what the others would like, and what
  ## is left to the columns without a width.
  let n = t.ncols
  result = newSeq[int](n)
  var rem = avail
  for i in 0 ..< n:
    result[i] = int(t.colMin[i])
    rem -= result[i]
  if rem <= 0: return
  # percentages (of the whole; more than 100 in all: scaled down)
  var pctSum = 0.0
  for p in t.colPct: pctSum += float(p)
  let pk = if pctSum > 100: 100 / pctSum else: 1.0
  for i in 0 ..< n:
    if t.colPct[i] > 0 and rem > 0:
      let want = int(float(t.colPct[i]) * pk * float(avail) / 100) - result[i]
      if want > 0:
        let g = min(want, rem)
        result[i] += g
        rem -= g
  # fixed widths
  var wantSum = 0
  for i in 0 ..< n:
    if t.colPct[i] == 0 and t.colFix[i] > 0: wantSum += max(0, int(t.colFix[i]) - result[i])
  if wantSum > 0 and rem > 0:
    let give = min(rem, wantSum)
    var given = 0
    for i in 0 ..< n:
      if t.colPct[i] == 0 and t.colFix[i] > 0:
        let wnt = max(0, int(t.colFix[i]) - result[i])
        let g = wnt * give div wantSum
        result[i] += g
        given += g
    rem -= given
  # the others, toward what their content would like
  wantSum = 0
  for i in 0 ..< n:
    if t.colPct[i] == 0 and t.colFix[i] == 0: wantSum += max(0, int(t.colMax[i]) - result[i])
  if wantSum > 0 and rem > 0:
    let give = min(rem, wantSum)
    var given = 0
    for i in 0 ..< n:
      if t.colPct[i] == 0 and t.colFix[i] == 0:
        let wnt = max(0, int(t.colMax[i]) - result[i])
        let g = int(int64(wnt) * int64(give) div int64(wantSum))
        result[i] += g
        given += g
    rem -= given
  if rem <= 0: return
  # what is left: to the columns without a width, as their content is wide
  var autos: seq[int]
  for i in 0 ..< n:
    if t.colPct[i] == 0 and t.colFix[i] == 0: autos.add i
  if autos.len == 0:
    for i in 0 ..< n: autos.add i
  var tot = 0
  for i in autos: tot += max(0, int(t.colMax[i]))
  var given = 0
  for i in autos:
    let g = if tot > 0: int(int64(rem) * int64(max(0, int(t.colMax[i]))) div int64(tot))
            else: rem div autos.len
    result[i] += g
    given += g
  if autos.len > 0: result[autos[^1]] += rem - given

proc layoutTable(c: var Lay; t: Box; x, cbW: int; y: var int; parent: int32): tuple[w, h: int] =
  ## A table at `x`, `y` in a containing block `cbW` wide: its border box's size.
  let s = c.S(t.st)
  let ps = c.S(parent)
  c.columns(t)
  for bb in t.before:
    var mc = MC()
    c.flowChild(bb, t.st, x, cbW, y, mc, false)
    y += mc.total
  let n = t.ncols
  let sp = if s.collapse: 0 else: c.lp(s.spacing)
  let bl = c.bw(s, 3)
  let br = c.bw(s, 1)
  let bt = c.bw(s, 0)
  let bb = c.bw(s, 2)
  let pl = c.lenPx(s.padding[3], cbW)
  let pr = c.lenPx(s.padding[1], cbW)
  let pt = c.lenPx(s.padding[0], cbW)
  let pb = c.lenPx(s.padding[2], cbW)
  let edges = bl + br + pl + pr + sp * (n + 1)
  var sumMin, sumMax = 0
  for v in t.colMin: sumMin += int(v)
  for v in t.colMax: sumMax += int(v)
  let ml = c.lenPx(s.margin[3], cbW)
  let mr = c.lenPx(s.margin[1], cbW)
  # beside floats: where it fits
  var tx = x
  var room = cbW - ml - mr
  if c.floats.len > 0:
    var guard = 0
    while guard < 100:
      inc guard
      let (l, r) = c.band(y, 1, x, x + cbW)
      if r - l - ml - mr >= sumMin + edges or (l == x and r == x + cbW):
        tx = l
        room = r - l - ml - mr
        break
      let nb = c.nextFloatBottom(y)
      if nb == high(int): break
      y = nb
  var W: int
  if s.width.k in {lkPx, lkPct}:
    W = min(c.lenPx(s.width, room), room)
    W = max(W, sumMin + edges)
  else:
    W = max(sumMin + edges, min(sumMax + edges, room))
  if s.minW.k == lkPx: W = max(W, min(room, c.lp(s.minW.v)))
  let avail = max(0, W - edges)
  let colW = distribute(t, avail)
  let tableX = c.blockX(s, ps, tx, room + ml + mr, W, ml, mr, ps.dir == dirRtl)
  let top = y
  let slot = c.reserveBox(s)
  # the caption, above
  var cy = top
  if t.caption != nil:
    var yy = cy
    discard c.layoutBox(t.caption, tableX, W, yy)
    cy = yy
  let gridTop = cy
  cy += bt + pt + sp
  # where each column starts (right to left in a right-to-left table)
  let rtl = s.dir == dirRtl
  let innerX = tableX + bl + pl
  let innerW = W - bl - br - pl - pr
  var colX = newSeq[int](n + 1)
  var cx = innerX + sp
  for i in 0 ..< n:
    colX[i] = cx
    cx += colW[i] + sp
  colX[n] = cx
  # rows' backgrounds first (under every cell, rowspans too)
  let nrows = t.nrows
  var rowSlot = newSeq[int](nrows)
  for r in 0 ..< nrows:
    rowSlot[r] = c.reserveBox(c.S(t.rowSts[r]))
  # every cell laid out (at the top; moved down when the rows are known)
  type Done = tuple[a, e, slot, h, x, w: int]
  var done = newSeq[Done](t.cells.len)
  var rowH = newSeq[int](nrows)
  for r in 0 ..< nrows:
    let rs = c.S(t.rowSts[r])
    if rs.height.k == lkPx: rowH[r] = c.lp(rs.height.v)
  # collapsed borders: each line between two cells drawn once, the
  # stronger of the two
  type Edge = tuple[w: int16; c: uint32; s: uint8]
  var eff: seq[array[4, Edge]]
  if s.collapse:
    eff = newSeq[array[4, Edge]](t.cells.len)
    var owner = newSeq[int32](nrows * n)
    for v in owner.mitems: v = -1
    for k, cell in t.cells:
      let cs = c.S(cell.box.st)
      for side in 0 .. 3:
        eff[k][side] = (int16(min(c.bw(cs, side), 200)),
                        (if cs.bc[side] == 0: cs.color else: cs.bc[side]), cs.bs[side])
      for r in int(cell.row) ..< min(nrows, int(cell.row + cell.rs)):
        for col in int(cell.col) ..< min(n, int(cell.col + cell.cs)):
          owner[r * n + col] = int32(k)
    let (mine, theirs) = if rtl: (3, 1) else: (1, 3)
    for k, cell in t.cells:
      let a1 = int(cell.col + cell.cs)
      if a1 < n:
        let j = owner[int(cell.row) * n + a1]
        if j >= 0 and j != k:
          if eff[j][theirs].w > eff[k][mine].w: eff[k][mine] = eff[j][theirs]
          eff[j][theirs].w = 0
      let r1 = int(cell.row + cell.rs)
      if r1 < nrows:
        let j = owner[r1 * n + int(cell.col)]
        if j >= 0 and j != k:
          if eff[j][0].w > eff[k][2].w: eff[k][2] = eff[j][0]
          eff[j][0].w = 0
  var rowFirst = -1
  for k, cell in t.cells:
    let cs = c.S(cell.box.st)
    let a0 = int(cell.col)
    let a1 = min(n, a0 + int(cell.cs))
    var cw = colX[a1] - sp - colX[a0]
    var cxx = colX[a0]
    if rtl: cxx = innerX + innerW - (cxx - innerX) - cw
    c.boundary(if int(cell.row) != rowFirst: 3'i8 else: 2'i8)
    rowFirst = int(cell.row)
    let a = c.p.items.len
    let cslot = c.reserveBox(cs)
    if cslot >= 0 and s.collapse:
      for side in 0 .. 3:
        c.p.items[cslot].bw[side] = eff[k][side].w
        c.p.items[cslot].bc[side] = eff[k][side].c
        c.p.items[cslot].bs[side] = eff[k][side].s
    var yy = 0
    let savedMarker = c.mPending
    c.mPending = false
    let (_, h) = c.layoutBox(cell.box, cxx, cw, yy)
    c.mPending = savedMarker
    var hh = h
    if cs.height.k == lkPx: hh = max(hh, c.lp(cs.height.v))
    done[k] = (a, c.p.items.len, cslot, hh, cxx, cw)
    if cell.rs == 1: rowH[cell.row] = max(rowH[cell.row], hh)
  # rowspans: the last row they cover grows if they need more
  for k, cell in t.cells:
    if cell.rs > 1:
      let r0 = int(cell.row)
      let r1 = min(nrows, r0 + int(cell.rs))
      var span = sp * (r1 - r0 - 1)
      for r in r0 ..< r1: span += rowH[r]
      if done[k].h > span: rowH[r1 - 1] += done[k].h - span
  var rowY = newSeq[int](nrows + 1)
  var ry = cy
  for r in 0 ..< nrows:
    rowY[r] = ry
    ry += rowH[r] + sp
  rowY[nrows] = ry
  # each cell where it goes, its content top, middle or bottom
  for k, cell in t.cells:
    let r0 = int(cell.row)
    let r1 = min(nrows, r0 + int(cell.rs))
    let cellH = rowY[r1] - sp - rowY[r0]
    let cs = c.S(cell.box.st)
    let free = max(0, cellH - done[k].h)
    let off = case cs.valign
      of vaMiddle: free div 2
      of vaBottom: free
      else: 0
    let d = done[k]
    # (the cell's box itself the whole height; its content moved)
    let contentStart = if d.slot >= 0: d.slot + 1 else: d.a
    c.shift(contentStart, d.e, 0, rowY[r0] + off)
    c.patch(d.slot, d.x, rowY[r0], d.w, cellH)
  for r in 0 ..< nrows:
    c.patch(rowSlot[r], innerX + sp, rowY[r], innerW - 2 * sp, rowH[r])
  var bottom = rowY[nrows] + pb + bb
  if nrows == 0: bottom = cy + pb + bb
  var h = bottom - top
  if s.height.k == lkPx: h = max(h, c.lp(s.height.v))
  c.patch(slot, tableX, gridTop, W, top + h - gridTop)
  y = top + h
  c.p.right = max(c.p.right, tableX + W)
  (W, h)

# ---- the page ----------------------------------------------------------------------------------

proc stampOf(imgVersion: int; zoom: float): int =
  ## What sizes depend on: the text size, the scale, the font, the zoom,
  ## the pictures.
  var h = hashF(textSize()) !& hashF(ui.k) !& hash(ord(uiFont())) !& hash(pxScale) !&
          hash(hdText()) !& hashF(zoom) !& hash(imgVersion)
  !$h

var layoutSerial = 0

const
  MinPageZoom* = 0.5           ## the smallest zoom of a page
  MaxPageZoom* = 3.0           ## ... and the largest

proc layoutDoc*(d: Doc; width: int; pics: PicSource; imgVersion = 0; picKey = 0;
                zoom = 1.0): Page =
  ## `d` laid out `width` pixels wide: what to draw, in order, in page
  ## coordinates from the top left of its content. `picKey` tells the
  ## places pictures come from apart (a folder, an app's pictures). `zoom`
  ## (`MinPageZoom` .. `MaxPageZoom`) makes the page larger or smaller, text and all.
  let z = if zoom > 0: clamp(zoom, MinPageZoom, MaxPageZoom) else: 1.0     # (NaN, 0: 1)
  var c = Lay(d: d, k: ui.k * z, fk: textSize() / RootPx * z, zoom: z, pics: pics)
  c.p = addr result
  inc layoutSerial
  result.serial = layoutSerial
  c.stamp = stampOf(imgVersion + 1, z) !& picKey
  result.links = d.links
  result.bg = d.bg
  let fontStamp = stampOf(0, z)
  if d.stamp != fontStamp:
    c.measureStyles()
    c.measureAll(d.root)
    d.stamp = fontStamp
  var y = 0
  let w = max(20, width)
  discard c.layoutBox(d.root, 0, w, y)
  result.height = max(y, c.floatsBottom())
  result.right = max(result.right, 0)
  for it in result.items:
    if it.kind == dkAnchor and it.text notin result.anchors:
      result.anchors[it.text] = int(it.y)
  c.p = nil

# ---- the page as plain text --------------------------------------------------------------------

type TextOut = object
  lines: seq[string]
  cur: string
  quote: int
  want: int                  ## 0 nothing, 1 a space, 2 a tab, 3 a new line, 4 a blank line
  any: bool
  cellStart: bool            ## a cell's content begins: its blocks start at its tab

proc prefix(o: TextOut): string =
  for _ in 0 ..< o.quote: result.add "> "

proc endLine(o: var TextOut) =
  var t = o.cur
  while t.endsWith(" "): t.setLen(t.len - 1)
  o.lines.add(o.prefix & t)
  o.cur = ""

proc put(o: var TextOut; s: string) =
  if s.len == 0: return
  if o.any:
    case o.want
    of 1:
      if not o.cur.endsWith(" ") and o.cur.len > 0: o.cur.add ' '
    of 2: o.cur.add '\t'
    of 3: o.endLine()
    of 4:
      o.endLine()
      if o.lines.len > 0 and o.lines[^1].strip(chars = {' ', '>'}).len > 0: o.lines.add(o.prefix.strip(leading = false))
    else: discard
  o.want = 0
  o.cellStart = false
  o.cur.add s
  o.any = true

proc want(o: var TextOut; v: int) {.inline.} =
  if v > o.want: o.want = v

proc walkBox(d: Doc; b: Box; o: var TextOut)

proc textOfItems(d: Doc; items: seq[Item]; o: var TextOut) =
  var curLink = -1'i32
  var linkText = ""
  template closeLink() =
    if curLink >= 0:
      let url = d.links[curLink]
      var shown = linkText.strip
      let bare = if url.toLowerAscii.startsWith("mailto:"): url[7 .. ^1].split('?')[0] else: url
      if not url.startsWith("#") and shown != url and shown != bare and
         shown & "/" != url and "<" & url & ">" notin shown:
        o.put(" <" & url & ">")
      curLink = -1
      linkText = ""
  for it in items:
    if it.link != curLink and (it.kind == ikText or it.kind == ikAtomic and it.box.kind == bxImage):
      closeLink()
      if it.link >= 0:
        curLink = it.link
    case it.kind
    of ikText:
      if d.tstyles[it.sty].invisible or d.tstyles[it.sty].tiny or d.tstyles[it.sty].fontPx < 3: continue
      if it.space: o.want(1)
      o.put(it.text)
      if curLink >= 0: linkText.add((if it.space: " " else: "") & it.text)
    of ikBreak:
      closeLink()
      o.want(if o.want >= 3 or (o.cur.len == 0 and o.any): 4 else: 3)
    of ikAtomic:
      let b = it.box
      if b.kind == bxImage:
        if curLink >= 0 and b.alt.len > 0 and linkText.len == 0:
          if it.space: o.want(1)
          o.put(b.alt)
          linkText.add b.alt
      else:
        closeLink()
        o.want(3)
        walkBox(d, b, o)
        o.want(3)
    of ikFloat:
      var sub = TextOut()
      walkBox(d, it.box, sub)
      if sub.cur.len > 0: sub.endLine()
      let t = sub.lines.join(" ").strip
      if t.len > 0: o.put(t)
    else: discard
  closeLink()

proc walkBox(d: Doc; b: Box; o: var TextOut) =
  if b == nil: return
  let s = d.styles[b.st]
  if s.invisible and b.kind != bxBlock: return
  let quote = b.tag == "blockquote"
  let para = (s.margin[0].k == lkPx and s.margin[0].v > 0) or
             (s.margin[2].k == lkPx and s.margin[2].v > 0) or
             b.tag in ["blockquote", "table", "pre"]
  if not b.anon and not b.cell and not o.cellStart: o.want(if para: 4 else: 3)
  if quote:
    if o.cur.len > 0: o.endLine()
    if o.lines.len > 0 and o.lines[^1].strip(chars = {' ', '>'}).len > 0:
      o.lines.add(o.prefix.strip(leading = false))
    inc o.quote
    o.any = false
    o.want = 0
  if b.listItem:
    o.want(3)
    o.put(if b.marker.len > 0: b.marker else: "-")
    o.want(1)
  case b.kind
  of bxImage: discard
  of bxTable:
    for bb in b.before: walkBox(d, bb, o)
    if b.caption != nil:
      walkBox(d, b.caption, o)
      o.want(3)
    var row = -1
    for cell in b.cells:
      if cell.row != row:
        o.want(3)
        row = cell.row
      else:
        if o.want != 3 or o.any: o.want = min(o.want, 2)
        o.want(2)
      o.cellStart = true
      walkBox(d, cell.box, o)
      o.cellStart = false
      o.want = min(o.want, 1)
    o.want(4)
  of bxBlock:
    if b.inl: textOfItems(d, b.items, o)
    else:
      for k in b.kids: walkBox(d, k, o)
  if not b.anon and not b.cell: o.want(if para: 4 else: 3)
  if quote:
    if o.cur.len > 0: o.endLine()
    dec o.quote
    o.want = 4
    o.any = true

proc plainText*(d: Doc): string =
  ## The page's text as a plain-text mail has it: paragraphs, "- " before
  ## list items, links as "text <address>", quotes with "> ", what is
  ## hidden left out.
  var o = TextOut()
  walkBox(d, d.root, o)
  if o.cur.len > 0: o.endLine()
  # (no more than one blank line in a row; none at the ends)
  var res: seq[string]
  for l in o.lines:
    let blank = l.strip(chars = {' ', '>', '\t'}).len == 0
    if blank and (res.len == 0 or res[^1].strip(chars = {' ', '>', '\t'}).len == 0): continue
    res.add(if blank: l.strip(leading = false, chars = {' '}) else: l)
  while res.len > 0 and res[^1].strip(chars = {' ', '>', '\t'}).len == 0: res.setLen(res.len - 1)
  for l in res.mitems:
    l = l.strip(leading = false)
  res.join("\n")
