## Reports and business documents -- invoices, statements, lists, letters
## -- laid out on pages and saved as PDF, PNG pages, shown on screen or
## printed. Write them with Nim procs that read like the document, or from
## an HTML template and some data.
##
## .. code-block:: nim
##   import retroui/report
##   var doc = newReport("Invoice 42", author = "Acme Trading LLC")
##   doc.header("Acme Trading LLC", "", "Invoice 42")
##   doc.footer("", "Page {page} of {pages}", "")
##   doc.heading("Invoice 42")
##   doc.paragraph([span("Bill to: "), span("Sohar Steel", bold = true)])
##   var t = newTable(["Item", "Qty", "Price"], widths = [-3.0, -1, -1],
##                    aligns = [alLeft, alRight, alRight])
##   t.addRow(["Paper A4", "10", "4.50"])
##   t.addTotals(["Total", "", "45.00"])
##   doc.table(t)
##   doc.savePdf("invoice.pdf")
##
## From HTML: `reportFromHtml(renderTemplate(tpl, data))` (see
## `reportFromHtml` for the HTML it reads and `retroui/templates` for the
## templates). On screen: `reportView(doc)`. On paper: `printReport(doc)`.
##
## Pages flow by themselves: a table's header row comes again at the top of
## each page, rows are never cut, headings stay with what follows, and
## `keepTogether` keeps a group on one page. Arabic paragraphs run right to
## left. Sizes are points (1/72 inch; `mm` converts).

import std/[strutils, tables, math, unicode, os, streams]
import uirelays/target   # (androidApp: an APK, not a program in Termux)
when not androidApp and not defined(ios) and not defined(windows):
  import std/osproc
import gfx, core, widgets, business, typeset, ttf, imaging, pdf, templates, nerdicons, uirelays
when defined(windows): import std/dynlib
when androidApp or defined(wasm): import uirelays/services
export pdf, templates, Align, Color, color

# ---- the document ------------------------------------------------------------------------------------

type
  Span* = object
    ## A piece of text with its style, for `paragraph` and table cells.
    text*: string              ## what it says
    bold*, italic*, mono*, underline*: bool  ## its style (`mono`: FreeMono)
    color*: Color              ## alpha 0: the document's text color
    size*: float               ## 0: the paragraph's size
    link*: string              ## a web address: the text becomes a link

  Cell* = object
    ## A cell of a `ReportTable`.
    spans*: seq[Span]          ## its text
    align*: Align              ## where its text goes (see `alignSet`)
    alignSet*: bool            ## `align` given (else the column's)
    colspan*: int              ## columns it takes (1 by default)
    fill*: Color               ## its background (alpha 0: none)
    image*: Bitmap             ## a picture above its text (nil: none)
    imageW*, imageH*: float    ## its size in points (0: from the picture;
                               ## never wider than the cell)

  RowKind = enum rkHeader, rkBody, rkTotal
  TRow = object
    cells: seq[Cell]
    kind: RowKind

  ReportTable* = object
    ## A table: build it with `newTable`, `addRow`, `addTotals`, then add
    ## it with `table`.
    widths*: seq[float]        ## per column: > 0 points, < 0 a share of the room
                               ## left (-2 is twice -1), 0 a share of 1
    aligns*: seq[Align]        ## per column: where the text goes
    grid*: bool                ## lines around every cell (else between rows)
    zebra*: bool               ## every other row shaded
    plain*: bool               ## no lines and no shading: a table that only
                               ## places things side by side
    size*: float               ## its text size (0: a little under the body's)
    headerFill*: Color         ## the header row's background
    rows: seq[TRow]

  BlockKind = enum bPara, bHeading, bTable, bImage, bRule, bSpace, bBreak, bKeep
  Block = object
    kind: BlockKind
    spans: seq[Span]
    align: Align
    alignSet: bool
    rtl: int
    size: float
    indent: float
    level: int
    bullet: string
    table: ReportTable
    image: Bitmap
    w, h: float
    kids: seq[Block]

  OpKind = enum oText, oRect, oLine, oImage, oLink
  Op = object
    kind: OpKind
    x, y, w, h: float
    text: string
    size: float
    bold, italic, mono: bool
    rtl: int8
    color, fill: Color
    width: float
    image: Bitmap
    uri: string

  Report* = ref object
    ## A document of pages. Its fields can be changed at any time; it is
    ## laid out again when needed.
    title*, author*: string    ## also the PDF's title and author
    page*: PageSize            ## A4 unless set (`Letter`, `landscape(A4)`...)
    margins*: tuple[top, right, bottom, left: float]   ## points (2 cm, 1.8 cm)
    size*: float               ## the body text's size (10 pt; 1 to 200)
    color*: Color              ## the text's color
    headers, footers: array[3, string]
    background: Bitmap         ## drawn under every page (a letterhead)
    blocks: seq[Block]
    keepFrom: seq[int]
    version: int
    laid: seq[seq[Op]]
    laidVersion: int
    laidFor: tuple[page: PageSize; margins: tuple[top, right, bottom, left: float];
                   size: float; color: Color; title: string]
    layouts: int               ## how many times it was laid out

const
  Black = Color(r: 0, g: 0, b: 0, a: 255)
  LinkBlue = Color(r: 0, g: 0, b: 200, a: 255)
  MaxBlocks = 200_000

proc touch(r: Report) {.inline.} = inc r.version

proc newReport*(title = ""; author = ""; page = A4): Report =
  ## An empty document with 2 cm margins and 10 pt text.
  Report(title: title, author: author, page: page,
         margins: (mm(20), mm(18), mm(20), mm(18)), size: 10, color: Black,
         laidVersion: -1)

proc span*(text: string; bold = false; italic = false; mono = false; underline = false;
           color = Color(); size = 0.0; link = ""): Span =
  ## A piece of text with a style: `span("Total", bold = true)`.
  Span(text: text, bold: bold, italic: italic, mono: mono, underline: underline,
       color: color, size: size, link: link)

proc add(r: Report; b: Block) =
  if r.blocks.len < MaxBlocks:
    r.blocks.add b
    r.touch()

proc setBackground*(r: Report; b: Bitmap) =
  ## A picture drawn under every page, stretched to the whole page: a
  ## letterhead (its logo, address and lines), as a scan or a design
  ## exported as an image. Set the `margins` so the text keeps clear of it.
  r.background = b
  r.touch()

proc header*(r: Report; left = ""; center = ""; right = "") =
  ## The text at the top of every page, at the left, middle and right.
  ## `{page}`, `{pages}`, `{title}` and `{date}` are filled in.
  r.headers = [left, center, right]
  r.touch()

proc footer*(r: Report; left = ""; center = ""; right = "") =
  ## The text at the bottom of every page (see `header`):
  ## `doc.footer("", "Page {page} of {pages}", "")`.
  r.footers = [left, center, right]
  r.touch()

proc heading*(r: Report; text: string; level = 1; align = alLeft; color = Color()) =
  ## A title, level 1 (largest) to 4. It never ends a page alone: it moves
  ## to the next page with what follows it.
  r.add Block(kind: bHeading, spans: @[span(text, bold = true, color = color)],
              level: clamp(level, 1, 4), align: align, alignSet: align != alLeft, rtl: -1)

proc paragraph*(r: Report; spans: openArray[Span]; align = alLeft; size = 0.0;
                rtl = -1; indent = 0.0) =
  ## A paragraph of styled pieces, wrapped to the page's width; `\n` in a
  ## piece starts a new line. `rtl` 1: right to left, 0 left to right,
  ## -1 from its first letter. Right-to-left (Arabic) paragraphs sit at the
  ## right with `alLeft` (the default) as with `alRight`; `alCenter`
  ## centers them. `indent`: points of space at the left.
  r.add Block(kind: bPara, spans: @spans, align: align, alignSet: align != alLeft,
              size: size, rtl: rtl, indent: max(0.0, indent))

proc paragraph*(r: Report; text: string; align = alLeft; size = 0.0; bold = false;
                italic = false; color = Color(); rtl = -1) =
  ## A paragraph of plain text (see the other `paragraph`).
  r.paragraph([span(text, bold = bold, italic = italic, color = color)], align, size, rtl)

proc list*(r: Report; items: openArray[string]; numbered = false) =
  ## A bulleted (or numbered) list, one paragraph per item.
  for i, it in items:
    r.add Block(kind: bPara, spans: @[span(it)], rtl: -1, indent: 18,
                bullet: if numbered: $(i + 1) & "." else: "•")

proc rule*(r: Report; color = Color(r: 160, g: 160, b: 160, a: 255)) =
  ## A thin line across the page.
  r.add Block(kind: bRule, spans: @[span("", color = color)])

proc space*(r: Report; h: float) =
  ## Empty space, `h` points high.
  r.add Block(kind: bSpace, h: max(0.0, h))

proc pageBreak*(r: Report) =
  ## What follows starts on a new page.
  r.add Block(kind: bBreak)

proc image*(r: Report; b: Bitmap; w = 0.0; h = 0.0; align = alLeft) =
  ## A picture, `w` x `h` points (0: from its size; it never gets wider
  ## than the page).
  if b == nil or b.w <= 0 or b.h <= 0: return
  r.add Block(kind: bImage, image: b, w: w, h: h, align: align)

proc imageFile*(r: Report; path: string; w = 0.0; h = 0.0; align = alLeft): bool {.discardable.} =
  ## A picture from a PNG, JPEG or BMP file; false when it cannot be read.
  let b = loadPicture(path)
  if b == nil: return false
  r.image(b, w, h, align)
  true

proc beginKeep*(r: Report) =
  ## What is added until `endKeep` stays on one page (when it fits on one).
  r.keepFrom.add r.blocks.len

proc endKeep*(r: Report) =
  ## Ends what `beginKeep` began (see `keepTogether`).
  if r.keepFrom.len == 0: return
  let at = r.keepFrom.pop()
  if at >= r.blocks.len: return
  var k = Block(kind: bKeep)
  k.kids = r.blocks[at .. ^1]
  r.blocks.setLen(at)
  r.add k

template keepTogether*(r: Report; body: untyped) =
  ## `doc.keepTogether: doc.heading("Totals"); doc.table(t)` -- the group
  ## moves to the next page rather than being split.
  r.beginKeep()
  body
  r.endKeep()

# ---- tables -------------------------------------------------------------------------------------------

proc cell*(text: string; bold = false; align = alLeft; colspan = 1; fill = Color();
           color = Color()): Cell =
  ## A table cell with its own style: `t.addRow([cell("Subtotal", bold = true,
  ## colspan = 3), cell("45.00")])`.
  Cell(spans: @[span(text, bold = bold, color = color)], align: align,
       alignSet: align != alLeft, colspan: max(1, colspan), fill: fill)

proc imageCell*(b: Bitmap; w = 0.0; h = 0.0; align = alLeft; text = ""): Cell =
  ## A table cell showing a picture (a logo, a photo of the item), `w` x
  ## `h` points (0: from its size), with `text` under it.
  Cell(spans: if text.len > 0: @[span(text)] else: @[], image: b, imageW: w, imageH: h,
       align: align, alignSet: align != alLeft, colspan: 1)

proc newTable*(headers: openArray[string] = []; widths: openArray[float] = [];
               aligns: openArray[Align] = []; grid = false; zebra = true): ReportTable =
  ## A table with a header row of `headers` (repeated on every page; none
  ## when empty). `widths`: > 0 points, < 0 shares (`[-3.0, -1, -1]`: the
  ## first column three times as wide), `aligns` per column.
  result = ReportTable(widths: @widths, aligns: @aligns, grid: grid, zebra: zebra,
                       headerFill: Color(r: 230, g: 230, b: 230, a: 255))
  if headers.len > 0:
    var row = TRow(kind: rkHeader)
    for i, h in headers:
      row.cells.add Cell(spans: @[span(h, bold = true)], colspan: 1,
                         align: if i < aligns.len: aligns[i] else: alLeft)
    result.rows.add row

proc addRow*(t: var ReportTable; cells: openArray[string]) =
  ## A row of plain cells.
  var row = TRow(kind: rkBody)
  for c in cells: row.cells.add Cell(spans: @[span(c)], colspan: 1)
  t.rows.add row

proc addRow*(t: var ReportTable; cells: openArray[Cell]) =
  ## A row of cells made with `cell`.
  t.rows.add TRow(kind: rkBody, cells: @cells)

proc addHeader*(t: var ReportTable; cells: openArray[string]) =
  ## One more header row (repeated on every page too).
  var row = TRow(kind: rkHeader)
  for c in cells: row.cells.add Cell(spans: @[span(c, bold = true)], colspan: 1)
  t.rows.add row

proc addTotals*(t: var ReportTable; cells: openArray[string]) =
  ## A totals row: bold, with a line above it.
  var row = TRow(kind: rkTotal)
  for c in cells: row.cells.add Cell(spans: @[span(c, bold = true)], colspan: 1)
  t.rows.add row

proc table*(r: Report; t: ReportTable) =
  ## Adds the table to the document.
  r.add Block(kind: bTable, table: t)

proc rowCount*(t: ReportTable): int = t.rows.len
  ## How many rows the table has (header and totals rows too).

# ---- laying out ---------------------------------------------------------------------------------------

type
  Piece = object
    text: string
    sp: Span
    size: float
    w, space: float
    hard: bool                 ## a line break after it
  Ctx = object
    r: Report
    pages: seq[seq[Op]]
    y, top, bottom, left, width: float
    measuring: bool

proc faceOf(sp: Span): FaceId = pdfFace(sp.bold, sp.mono, sp.italic)

var runeWidths: Table[int, float]

proc runeEm(r: Rune; bold, mono, italic: bool): float =
  ## The width of the letter `r` alone, in ems (kept).
  let key = (int(r) shl 3) or (ord(italic) shl 2) or (ord(bold) shl 1) or ord(mono)
  result = runeWidths.getOrDefault(key, -1.0)
  if result < 0:
    result = pdfTextWidth(r.toUTF8, 1.0, bold, mono, italic = italic)
    if runeWidths.len < 20_000: runeWidths[key] = result

proc pieces(spans: openArray[Span]; size: float; rtl: int; maxW: float): seq[Piece] =
  for sp in spans:
    let sz = if sp.size > 0 and sp.size.classify == fcNormal: min(sp.size, 400.0) else: size
    let spaceW = pdfTextWidth(" ", sz, sp.bold, sp.mono, italic = sp.italic)
    let lines = sp.text.replace('\t', ' ').replace("\r", "").split('\n')
    for li, line in lines:
      if li > 0:
        if result.len > 0: result[^1].hard = true
        else: result.add Piece(sp: sp, size: sz, hard: true)
      let words = line.split(' ')
      for wi, word in words:
        if word.len > 0:
          var wtxt = word
          var w = pdfTextWidth(wtxt, sz, sp.bold, sp.mono, rtl, sp.italic)
          # a word longer than the line: broken where it must (by the
          # letters' own widths, then measured whole)
          if w > maxW and wtxt.runeLen > 1:
            let runes = wtxt.toRunes
            var start = 0
            while start < runes.len:
              var acc = 0.0
              var k = start
              while k < runes.len:
                let cw = runeEm(runes[k], sp.bold, sp.mono, sp.italic) * sz
                if k > start and acc + cw > maxW: break
                acc += cw
                inc k
              let part = $runes[start ..< k]
              if k < runes.len:
                result.add Piece(text: part, sp: sp, size: sz,
                                 w: pdfTextWidth(part, sz, sp.bold, sp.mono, rtl, sp.italic), hard: true)
              else:
                wtxt = part
                w = pdfTextWidth(part, sz, sp.bold, sp.mono, rtl, sp.italic)
              start = k
          result.add Piece(text: wtxt, sp: sp, size: sz, w: w)
        if wi < words.high and result.len > 0 and not result[^1].hard:
          result[^1].space += spaceW

proc sameStyle(a, b: Span): bool =
  a.bold == b.bold and a.italic == b.italic and a.mono == b.mono and
    a.underline == b.underline and a.color == b.color and a.size == b.size and a.link == b.link

proc lineH(size: float): float = pdfLineHeight(size) * 1.12

proc newPage(c: var Ctx) =
  c.pages.add @[]
  c.y = c.top

proc emit(c: var Ctx; op: Op) =
  if not c.measuring and c.pages.len > 0: c.pages[^1].add op

proc paraHeight(pcs: seq[Piece]; maxW: float): float

proc placeText(c: var Ctx; spans: openArray[Span]; x, maxW, size: float;
               align: Align; alignSet: bool; rtlIn: int; color: Color;
               bullet = ""; breakPages = true): float {.discardable.} =
  ## Lays out a paragraph at `c.y` (moving down); returns its height.
  ## `breakPages`: lines that do not fit go to the next page.
  var plain = ""
  for sp in spans: plain.add sp.text
  let rtl = if rtlIn >= 0: rtlIn == 1 else: textIsRtl(plain)
  let rtlFlag = int8(if rtl: 1 else: 0)
  let al = if alignSet: align elif rtl: alRight else: align
  let pcs = pieces(spans, size, ord(rtl), maxW)
  let y0 = c.y
  var i = 0
  var first = true
  if pcs.len == 0:
    let h = lineH(size)
    if breakPages and c.y + h > c.bottom and c.y > c.top: c.newPage()
    c.y += h
    return c.y - y0
  while i < pcs.len:
    # the pieces of this line
    var j = i
    var w = 0.0
    while j < pcs.len:
      let add = (if j > i: pcs[j - 1].space else: 0.0) + pcs[j].w
      if j > i and w + add > maxW: break
      w += add
      inc j
      if pcs[j - 1].hard: break
    if j == i: j = i + 1
    var lh = 0.0
    var asc = 0.0
    for k in i ..< j:
      lh = max(lh, lineH(pcs[k].size))
      asc = max(asc, float(ascentFactor()) * pcs[k].size)
    if breakPages and c.y + lh > c.bottom and c.y > c.top:
      c.newPage()
    let off = case al
              of alLeft: 0.0
              of alCenter: (maxW - w) / 2
              of alRight: maxW - w
    if first and bullet.len > 0:
      let bw = pdfTextWidth(bullet, size)
      let bx = if rtl: x + maxW + 6 else: x - bw - 6
      c.emit Op(kind: oText, x: bx, y: c.y + asc - float(ascentFactor()) * size, text: bullet,
                size: size, color: color)
    first = false
    var px = if rtl: x + off + w else: x + off
    var k = i
    while k < j:
      # the words of one style go out as one piece of text (spaces in it)
      var e = k + 1
      var gw = pcs[k].w
      var txt = pcs[k].text
      while e < j and pcs[e].text.len > 0 and txt.len > 0 and pcs[e - 1].space > 0 and
            sameStyle(pcs[e].sp, pcs[k].sp) and pcs[e].size == pcs[k].size:
        gw += pcs[e - 1].space + pcs[e].w
        txt.add ' '
        txt.add pcs[e].text
        inc e
      let p = pcs[k]
      if rtl: px -= gw
      let py = c.y + asc - float(ascentFactor()) * p.size
      if txt.len > 0:
        let col = if p.sp.color.a != 0: p.sp.color elif p.sp.link.len > 0: LinkBlue else: color
        # (a space between styles goes with the text, so text taken out of a
        # PDF keeps its words apart)
        let tail = if not rtl and e < j and pcs[e - 1].space > 0: " " else: ""
        c.emit Op(kind: oText, x: px, y: py, text: txt & tail, size: p.size,
                  bold: p.sp.bold, italic: p.sp.italic, mono: p.sp.mono, rtl: rtlFlag,
                  color: col)
        if p.sp.underline or p.sp.link.len > 0:
          let uy = py + float(ascentFactor()) * p.size + p.size * 0.12
          c.emit Op(kind: oLine, x: px, y: uy, w: gw, h: 0, color: col,
                    width: max(0.4, p.size * 0.06))
        if p.sp.link.len > 0:
          c.emit Op(kind: oLink, x: px, y: py, w: gw, h: pdfLineHeight(p.size), uri: p.sp.link)
      let sp = pcs[e - 1].space
      if rtl: px -= sp
      else: px += gw + sp
      k = e
    c.y += lh
    i = j
  c.y - y0

proc lineRanges(pcs: seq[Piece]; maxW: float): seq[tuple[i, j: int; h: float]] =
  ## The lines the pieces make in `maxW`: pieces i ..< j, and the height.
  var i = 0
  while i < pcs.len:
    var j = i
    var w = 0.0
    while j < pcs.len:
      let add = (if j > i: pcs[j - 1].space else: 0.0) + pcs[j].w
      if j > i and w + add > maxW: break
      w += add
      inc j
      if pcs[j - 1].hard: break
    if j == i: j = i + 1
    var lh = 0.0
    for k in i ..< j: lh = max(lh, lineH(pcs[k].size))
    result.add (i, j, lh)
    i = j

proc paraHeight(pcs: seq[Piece]; maxW: float): float =
  for l in lineRanges(pcs, maxW): result += l.h

proc headingSize(r: Report; level: int): float =
  r.size * (case level
            of 1: 2.0
            of 2: 1.6
            of 3: 1.3
            else: 1.1)

proc colWidths(t: ReportTable; width: float): seq[float] =
  var n = t.widths.len
  for row in t.rows:
    var k = 0
    for c in row.cells: k += max(1, c.colspan)
    n = max(n, k)
  if n == 0: return
  var fixed = 0.0
  var shares = 0.0
  for i in 0 ..< n:
    let w = if i < t.widths.len and t.widths[i].classify in {fcNormal, fcZero}: t.widths[i] else: 0.0
    if w > 0: fixed += w
    else: shares += (if w < 0: -w else: 1.0)
  let scale = if fixed > width: width / fixed else: 1.0
  let room = max(0.0, width - fixed * scale)
  for i in 0 ..< n:
    let w = if i < t.widths.len and t.widths[i].classify in {fcNormal, fcZero}: t.widths[i] else: 0.0
    if w > 0: result.add w * scale
    else: result.add room * (if w < 0: -w else: 1.0) / max(shares, 1e-9)

const PadX = 4.0
const PadY = 3.0

proc imageSize(cell: Cell; room: float): tuple[w, h: float] =
  ## The size a cell's picture takes, kept inside `room` points wide.
  let b = cell.image
  if b == nil or b.w <= 0 or b.h <= 0: return
  let wSet = cell.imageW > 0 and cell.imageW.classify == fcNormal
  let hSet = cell.imageH > 0 and cell.imageH.classify == fcNormal
  # (one of the two given: the other keeps the picture's proportions)
  var w = if wSet: cell.imageW
          elif hSet: cell.imageH * float(b.w) / float(b.h)
          else: float(b.w) * 0.75
  var h = if hSet: cell.imageH
          else: w * float(b.h) / float(b.w)
  if w > room:
    h = h * room / w
    w = room
  if h > 2000:
    w = w * 2000 / h
    h = 2000
  (w, h)

const ImageGap = 3.0           ## between a cell's picture and its text

proc cellText(c: var Ctx; cell: Cell; x, y, w, size: float; align: Align; alignGiven: bool;
              bold: bool): float =
  ## Lays out a cell (its picture, then its text) at x, y in width w; its
  ## height.
  let room = max(1.0, w - 2 * PadX)
  let (iw, ih) = imageSize(cell, room)
  var y = y
  if ih > 0:
    let ix = case align
             of alLeft: x + PadX
             of alCenter: x + PadX + (room - iw) / 2
             of alRight: x + w - PadX - iw
    c.emit Op(kind: oImage, x: ix, y: y, w: iw, h: ih, image: cell.image)
    y += ih + (if cell.spans.len > 0: ImageGap else: 0.0)
  if cell.spans.len == 0: return ih
  var spans = cell.spans
  if bold:
    for s in spans.mitems: s.bold = true
  let saved = c.y
  c.y = y
  let h = c.placeText(spans, x + PadX, room, size, align, alignGiven, -1,
                      c.r.color, breakPages = false)
  c.y = saved
  h + (if ih > 0: ih + ImageGap else: 0.0)

iterator cellPieces(row: TRow; cols: seq[float]; size: float):
    tuple[pcs: seq[Piece]; w, imageH: float] =
  ## Each cell of `row` as pieces of text, with the width they wrap in and
  ## the height of its picture (with the gap under it).
  var col = 0
  for cell in row.cells:
    let span = max(1, cell.colspan)
    var w = 0.0
    for k in col ..< min(cols.len, col + span): w += cols[k]
    var spans = cell.spans
    if row.kind != rkBody:
      for s in spans.mitems: s.bold = true
    let room = max(1.0, w - 2 * PadX)
    let ih = imageSize(cell, room).h
    yield (pieces(spans, size, -1, room), room,
           if ih > 0: ih + (if spans.len > 0: ImageGap else: 0.0) else: 0.0)
    col += span

proc rowHeight(c: var Ctx; t: ReportTable; row: TRow; cols: seq[float]; size: float): float =
  for (pcs, room, ih) in cellPieces(row, cols, size):
    result = max(result, ih + paraHeight(pcs, room))
  result = max(result, lineH(size)) + 2 * PadY

proc spansOf(pcs: seq[Piece]; lines: seq[tuple[i, j: int; h: float]]; a, b: int): seq[Span] =
  ## Lines a ..< b of a cell as spans again (a row cut over two pages).
  for li in a ..< b:
    let (i, j, _) = lines[li]
    for k in i ..< j:
      var sp = pcs[k].sp
      sp.text = pcs[k].text
      if k < j - 1 and pcs[k].space > 0: sp.text.add ' '
      result.add sp
    if li < b - 1: result.add Span(text: "\n")

proc placeRow(c: var Ctx; t: ReportTable; row: TRow; cols: seq[float]; size, h: float;
              zebraOn: bool; lineAbove = true) =
  let x0 = c.left
  var tw = 0.0
  for w in cols: tw += w
  # backgrounds
  if t.plain: discard
  elif row.kind == rkHeader and t.headerFill.a != 0:
    c.emit Op(kind: oRect, x: x0, y: c.y, w: tw, h: h, fill: t.headerFill)
  elif zebraOn:
    c.emit Op(kind: oRect, x: x0, y: c.y, w: tw, h: h, fill: Color(r: 245, g: 245, b: 245, a: 255))
  var col = 0
  var x = x0
  for cell in row.cells:
    let span = max(1, cell.colspan)
    var w = 0.0
    for k in col ..< min(cols.len, col + span): w += cols[k]
    if cell.fill.a != 0:
      c.emit Op(kind: oRect, x: x, y: c.y, w: w, h: h, fill: cell.fill)
    let given = cell.alignSet or col < t.aligns.len
    let al = if cell.alignSet: cell.align
             elif col < t.aligns.len: t.aligns[col]
             else: cell.align
    discard c.cellText(cell, x, c.y + PadY, w, size, al, given, row.kind != rkBody)
    if t.grid:
      c.emit Op(kind: oRect, x: x, y: c.y, w: w, h: h,
                fill: Color(), color: Color(r: 128, g: 128, b: 128, a: 255), width: 0.5)
    x += w
    col += span
  if not t.grid and not t.plain:
    case row.kind
    of rkHeader:
      c.emit Op(kind: oLine, x: x0, y: c.y + h, w: tw, color: Color(r: 60, g: 60, b: 60, a: 255),
                width: 0.75)
    of rkTotal:
      if lineAbove: c.emit Op(kind: oLine, x: x0, y: c.y, w: tw, color: Color(r: 60, g: 60, b: 60, a: 255),
                width: 0.9)
    of rkBody:
      c.emit Op(kind: oLine, x: x0, y: c.y + h, w: tw, color: Color(r: 210, g: 210, b: 210, a: 255),
                width: 0.25)

proc placeTable(c: var Ctx; t: ReportTable) =
  let cols = colWidths(t, c.width)
  if cols.len == 0: return
  let size = if t.size > 0 and t.size.classify == fcNormal: min(t.size, 400.0)
             else: c.r.size * 0.95
  # every row's height, once
  var heights = newSeq[float](t.rows.len)
  var headers: seq[int]
  var headH = 0.0
  var firstBody = -1
  for i, row in t.rows:
    heights[i] = c.rowHeight(t, row, cols, size)
    if row.kind == rkHeader:
      headers.add i
      headH += heights[i]
    elif firstBody < 0: firstBody = i
  template putHeaders() =
    for hi in headers:
      c.placeRow(t, t.rows[hi], cols, size, heights[hi], false)
      c.y += heights[hi]
  # the header with at least one row under it
  let firstH = if firstBody >= 0: heights[firstBody] else: 0.0
  if c.y + headH + firstH > c.bottom and c.y > c.top: c.newPage()
  putHeaders()
  var body = 0
  var onPage = 0                 # rows (not headers) on this page
  var prevKind = rkHeader
  for i, row in t.rows:
    if row.kind == rkHeader: continue
    let h = heights[i]
    if h > c.bottom - c.top - headH and not c.measuring:
      # a row taller than a page: its lines go on over the pages
      var parts: seq[tuple[pcs: seq[Piece]; lines: seq[tuple[i, j: int; h: float]]; ih: float]]
      for (pcs, room, ih) in cellPieces(row, cols, size): parts.add (pcs, lineRanges(pcs, room), ih)
      var at = newSeq[int](parts.len)
      var first = true
      while true:
        let avail0 = c.bottom - c.y - 2 * PadY
        var sub = TRow(kind: row.kind, cells: row.cells)
        var subH = 0.0
        var left = false
        var took = false
        for ci in 0 ..< parts.len:
          let ls = parts[ci].lines
          let ih = if first: parts[ci].ih else: 0.0
          if not first: sub.cells[ci].image = nil
          let avail = avail0 - ih
          var e = at[ci]
          var hs = ih
          while e < ls.len and (hs + ls[e].h <= avail or (e == at[ci] and onPage == 0)):
            hs += ls[e].h
            inc e
          if e > at[ci] or ih > 0: took = true
          sub.cells[ci].spans = spansOf(parts[ci].pcs, ls, at[ci], e)
          subH = max(subH, hs)
          at[ci] = e
          if e < ls.len: left = true
        if took:
          let rh = max(subH, lineH(size)) + 2 * PadY
          c.placeRow(t, sub, cols, size, rh, t.zebra and row.kind == rkBody and body mod 2 == 1,
                     lineAbove = prevKind != rkTotal or onPage == 0)
          c.y += rh
          inc onPage
        first = false
        if not left: break
        c.newPage()
        onPage = 0
        putHeaders()
      prevKind = row.kind
      if row.kind == rkBody: inc body
      continue
    if c.y + h > c.bottom and onPage > 0:
      c.newPage()
      onPage = 0
      putHeaders()
    c.placeRow(t, row, cols, size, h, t.zebra and row.kind == rkBody and body mod 2 == 1,
               lineAbove = prevKind != rkTotal or onPage == 0)
    prevKind = row.kind
    if row.kind == rkBody: inc body
    inc onPage
    c.y += h
  c.y += size * 0.8

proc placeBlocks(c: var Ctx; blocks: openArray[Block])

proc measureBlocks(c: Ctx; blocks: openArray[Block]): float =
  var m = Ctx(r: c.r, top: 0, bottom: Inf, left: c.left, width: c.width, measuring: true)
  m.pages = @[@[]]
  m.placeBlocks(blocks)
  m.y

proc placeBlocks(c: var Ctx; blocks: openArray[Block]) =
  let r = c.r
  for b in blocks:
    case b.kind
    of bPara:
      let size = if b.size > 0 and b.size.classify == fcNormal: min(b.size, 400.0) else: r.size
      c.placeText(b.spans, c.left + b.indent, max(10.0, c.width - b.indent), size, b.align,
                  b.alignSet, b.rtl, r.color, b.bullet)
      c.y += size * 0.45
    of bHeading:
      let size = r.headingSize(b.level)
      if c.y > c.top: c.y += size * 0.5
      # with at least two lines of what follows
      let need = lineH(size) + 2 * lineH(r.size)
      if c.y + need > c.bottom and c.y > c.top: c.newPage()
      c.placeText(b.spans, c.left, c.width, size, b.align, b.alignSet, b.rtl, r.color)
      c.y += size * 0.3
    of bTable: c.placeTable(b.table)
    of bImage:
      var w = if b.w > 0 and b.w.classify == fcNormal: b.w else: float(b.image.w) * 0.75
      var h = if b.h > 0 and b.h.classify == fcNormal: b.h
              else: w * float(b.image.h) / float(max(1, b.image.w))
      if b.w > 0 and b.h <= 0: h = w * float(b.image.h) / float(max(1, b.image.w))
      if b.h > 0 and b.w <= 0: w = h * float(b.image.w) / float(max(1, b.image.h))
      if w > c.width:
        h = h * c.width / w
        w = c.width
      let pageRoom = c.bottom - c.top
      if h > pageRoom:
        w = w * pageRoom / h
        h = pageRoom
      if c.y + h > c.bottom and c.y > c.top: c.newPage()
      let x = case b.align
              of alLeft: c.left
              of alCenter: c.left + (c.width - w) / 2
              of alRight: c.left + c.width - w
      c.emit Op(kind: oImage, x: x, y: c.y, w: w, h: h, image: b.image)
      c.y += h + r.size * 0.5
    of bRule:
      if c.y + 8 > c.bottom and c.y > c.top: c.newPage()
      c.y += 4
      let col = if b.spans.len > 0 and b.spans[0].color.a != 0: b.spans[0].color
                else: Color(r: 160, g: 160, b: 160, a: 255)
      c.emit Op(kind: oLine, x: c.left, y: c.y, w: c.width, color: col, width: 0.6)
      c.y += 6
    of bSpace:
      c.y += min(b.h, c.bottom - c.top)
      if c.y > c.bottom: c.newPage()
    of bBreak:
      if c.y > c.top or (c.pages.len > 0 and c.pages[^1].len > 0): c.newPage()
    of bKeep:
      if not c.measuring:
        let h = c.measureBlocks(b.kids)
        if c.y + h > c.bottom and c.y > c.top and h <= c.bottom - c.top: c.newPage()
      c.placeBlocks(b.kids)

proc fillIn(s: string; r: Report; page, pages: int): string =
  s.multiReplace(("{page}", $page), ("{pages}", $pages), ("{title}", r.title),
                 ("{date}", $today()))

proc pageSizeOf(r: Report): PageSize =
  result = A4
  if r.page.w.classify == fcNormal and r.page.w > 72: result.w = min(r.page.w, 14400.0)
  if r.page.h.classify == fcNormal and r.page.h > 72: result.h = min(r.page.h, 14400.0)

proc layoutPages(r: Report): lent seq[seq[Op]] =
  ## The pages of `r` as drawing operations (kept until `r` changes).
  if r.size.classify != fcNormal or r.size < 1 or r.size > 200: r.size = 10
  let params = (r.page, r.margins, r.size, r.color, r.title)
  if r.laidVersion != r.version or r.laid.len == 0 or params != r.laidFor:
    r.laidFor = params
    inc r.layouts
    let (pw, ph) = r.pageSizeOf
    proc margin(v, room: float): float = (if v.isNaN: 0.0 else: clamp(v, 0.0, room / 3))
    let left = margin(r.margins.left, pw)
    let right = margin(r.margins.right, pw)
    let top = margin(r.margins.top, ph)
    let bottom = margin(r.margins.bottom, ph)
    var c = Ctx(r: r, top: top, bottom: ph - bottom, left: left, width: pw - left - right)
    c.newPage()
    c.placeBlocks(r.blocks)
    # headers and footers, now that the pages are counted
    let hs = r.size * 0.8
    let gray = Color(r: 90, g: 90, b: 90, a: 255)
    for i in 0 ..< c.pages.len:
      for (texts, y) in [(r.headers, max(4.0, top / 2 - pdfLineHeight(hs) / 2)),
                         (r.footers, ph - max(4.0, bottom / 2 + pdfLineHeight(hs) / 2))]:
        for k in 0 .. 2:
          if texts[k].len == 0: continue
          let s = fillIn(texts[k], r, i + 1, c.pages.len)
          let w = pdfTextWidth(s, hs)
          let x = case k
                  of 0: left
                  of 1: (pw - w) / 2
                  else: pw - right - w
          c.pages[i].add Op(kind: oText, x: x, y: y, text: s, size: hs, color: gray, rtl: -1)
    # the letterhead under everything
    if r.background != nil and r.background.w > 0:
      for i in 0 ..< c.pages.len:
        c.pages[i].insert(Op(kind: oImage, x: 0, y: 0, w: pw, h: ph, image: r.background), 0)
    r.laid = move c.pages
    r.laidVersion = r.version
  r.laid

proc pageCount*(r: Report): int =
  ## How many pages the document takes.
  r.layoutPages().len

type
  PageText* = object
    ## A piece of text on a page and where it is (points from the page's
    ## top-left corner): see `pageTexts`.
    x*, y*, w*, size*: float ## where it starts (its line's top), how wide it is, its size (points)
    text*: string            ## what it says
    bold*, italic*, mono*: bool  ## its style
    color*: Color            ## its color
    link*: string            ## the address when it is a link

proc pageTexts*(r: Report; index: int): seq[PageText] =
  ## The text on page `index` (from 0), piece by piece in the order it was
  ## laid out, the header and footer last: for searching a document, or
  ## checking where things went.
  let pages = r.layoutPages()
  if index < 0 or index >= pages.len: return
  for op in pages[index]:
    if op.kind == oText:
      result.add PageText(x: op.x, y: op.y, size: op.size, text: op.text, bold: op.bold,
                          italic: op.italic, mono: op.mono, color: op.color,
                          w: pdfTextWidth(op.text, op.size, op.bold, op.mono, int(op.rtl), op.italic))
    elif op.kind == oLink:
      for t in result.mitems:
        if t.link.len == 0 and abs(t.x - op.x) < 0.01 and abs(t.y - op.y) < 0.01: t.link = op.uri

# ---- PDF -----------------------------------------------------------------------------------------------

proc toPdf*(r: Report): PdfDoc =
  ## The document as a `PdfDoc` (to add to, or `render`).
  result = newPdf(r.title, r.author)
  let size = r.pageSizeOf
  for ops in r.layoutPages():
    let p = result.addPage(size)
    for op in ops:
      case op.kind
      of oText:
        discard p.text(op.x, op.y, op.text, op.size, op.color, op.bold, op.italic, op.mono,
                       int(op.rtl))
      of oRect:
        p.box(op.x, op.y, op.w, op.h, fill = op.fill, stroke = op.color, width = op.width)
      of oLine:
        p.line(op.x, op.y, op.x + op.w, op.y + op.h, op.color, op.width)
      of oImage: p.image(op.image, op.x, op.y, op.w, op.h)
      of oLink: p.link(op.x, op.y, op.w, op.h, op.uri)

proc pdfBytes*(r: Report): string =
  ## The bytes of the document's PDF file.
  r.toPdf().render()

proc savePdf*(r: Report; path: string) =
  ## Writes the document as a PDF file -- first to a temporary file next to
  ## it, then moved into place, so a reader never sees half a file. Raises
  ## `IOError` (or `OSError`) when it cannot.
  let part = path & ".part"
  writeFile(part, r.pdfBytes())
  try:
    moveFile(part, path)
  except OSError as e:
    removeFile(part)
    raise e

# ---- pages as pictures -----------------------------------------------------------------------------

var masks: Table[uint64, Mask]

proc blendPx(b: Bitmap; x, y: int; c: Color; cov: int) {.inline.} =
  if x < 0 or y < 0 or x >= b.w or y >= b.h or cov <= 0: return
  let a = cov * int(c.a) div 255
  if a <= 0: return
  let i = y * b.w + x
  let d = b.px[i]
  let dr = int((d shr 16) and 0xFF)
  let dg = int((d shr 8) and 0xFF)
  let db = int(d and 0xFF)
  let r = dr + (int(c.r) - dr) * a div 255
  let g = dg + (int(c.g) - dg) * a div 255
  let bl = db + (int(c.b) - db) * a div 255
  b.px[i] = 0xFF000000'u32 or (uint32(r) shl 16) or (uint32(g) shl 8) or uint32(bl)

proc pix(v: float; hi: int): int =
  ## `v` as a pixel index kept to -1 .. hi + 1 (NaN: -1), never overflowing.
  if v.isNaN or v < -1: -1
  elif v > float(hi + 1): hi + 1
  else: int(floor(v))

proc fillRectPx(b: Bitmap; x0, y0, x1, y1: float; c: Color) =
  ## Fills x0..x1, y0..y1 (pixels, fractions blended at the edges).
  if c.a == 0: return
  let ix0 = max(0, pix(x0, b.w))
  let iy0 = max(0, pix(y0, b.h))
  let ix1 = min(b.w, pix(ceil(x1), b.w))
  let iy1 = min(b.h, pix(ceil(y1), b.h))
  for y in iy0 ..< iy1:
    let cy = min(float(y + 1), y1) - max(float(y), y0)
    if cy <= 0: continue
    for x in ix0 ..< ix1:
      let cx = min(float(x + 1), x1) - max(float(x), x0)
      if cx <= 0: continue
      b.blendPx(x, y, c, int(cx * cy * 255 + 0.5))

proc drawGlyphs(b: Bitmap; op: Op; scale: float) =
  let face0 = pdfFace(op.bold, op.mono, op.italic)
  let run = shape(op.text, face0, int(op.rtl))
  let sizePx = op.size * scale
  if not (sizePx >= 1 and sizePx <= 1000): return
  let base = (op.y + float(ascentFactor()) * op.size) * scale
  if base.isNaN or op.x.isNaN or base < -sizePx * 2 or base > float(b.h) + sizePx * 2: return
  for g in run.glyphs:
    let gx = op.x * scale + float(g.x) * sizePx
    let gy = base - float(g.y) * sizePx
    if gx < -sizePx * 2 or gx > float(b.w) + sizePx: continue
    let ix = int(floor(gx))
    let frac = int((gx - float(ix)) * 4) and 3
    let key = (uint64(ord(g.face)) shl 56) or (uint64(g.gid) shl 40) or
              (uint64(int(sizePx * 4) and 0xFFFFF) shl 8) or (uint64(frac) shl 2)
    if not masks.hasKey(key):
      if masks.len > 6000: masks.clear()
      masks[key] = renderGlyph(g.face, int(g.gid), float32(sizePx), float32(frac) / 4)
    let m = masks[key]
    let iy = int(round(gy))
    for yy in 0 ..< m.h:
      for xx in 0 ..< m.w:
        let a = int(m.a[yy * m.w + xx])
        if a > 0: b.blendPx(ix + m.left + xx, iy + m.top + yy, op.color, a)

proc drawImagePx(b: Bitmap; src: Bitmap; x, y, w, h: float) =
  if src == nil or src.w <= 0 or src.h <= 0 or not (w > 0) or not (h > 0): return
  let x0 = max(0, pix(x, b.w))
  let y0 = max(0, pix(y, b.h))
  let x1 = min(b.w, pix(ceil(x + w), b.w))
  let y1 = min(b.h, pix(ceil(y + h), b.h))
  let sx = float(src.w) / w
  let sy = float(src.h) / h
  for py in y0 ..< y1:
    let fy0 = (float(py) - y) * sy
    let fy1 = fy0 + sy
    for px in x0 ..< x1:
      let fx0 = (float(px) - x) * sx
      let fx1 = fx0 + sx
      # the average of the source pixels under this one (a box filter)
      var ra, ga, ba, aa, n = 0
      let ys = clamp(int(fy0), 0, src.h - 1)
      let ye = clamp(max(int(ceil(fy1)) - 1, ys), 0, src.h - 1)
      let xs = clamp(int(fx0), 0, src.w - 1)
      let xe = clamp(max(int(ceil(fx1)) - 1, xs), 0, src.w - 1)
      let stepY = max(1, (ye - ys + 1) div 4)
      let stepX = max(1, (xe - xs + 1) div 4)
      var yy = ys
      while yy <= ye:
        var xx = xs
        while xx <= xe:
          let p = src.px[yy * src.w + xx]
          let pa = int(p shr 24)
          ra += int((p shr 16) and 0xFF) * pa
          ga += int((p shr 8) and 0xFF) * pa
          ba += int(p and 0xFF) * pa
          aa += pa
          inc n
          xx += stepX
        yy += stepY
      if aa == 0: continue
      let c = Color(r: uint8(ra div aa), g: uint8(ga div aa), b: uint8(ba div aa), a: 255)
      b.blendPx(px, py, c, aa div max(1, n))

proc renderPage*(r: Report; index: int; scale = 1.0): Bitmap =
  ## Page `index` (from 0) as a picture, `scale` pixels per point (1.0: 72
  ## dpi; 150 / 72.0: 150 dpi). nil when there is no such page.
  let pages = r.layoutPages()
  if index < 0 or index >= pages.len: return nil
  let sc = if scale.classify == fcNormal: clamp(scale, 0.05, 8.0) else: 1.0
  let size = r.pageSizeOf
  result = newBitmap(max(1, int(size.w * sc + 0.5)), max(1, int(size.h * sc + 0.5)),
                     0xFFFFFFFF'u32)
  for op in pages[index]:
    case op.kind
    of oRect:
      if op.fill.a != 0:
        result.fillRectPx(op.x * sc, op.y * sc, (op.x + op.w) * sc, (op.y + op.h) * sc, op.fill)
      if op.color.a != 0:
        let t = max(1.0, op.width * sc)
        let (x0, y0, x1, y1) = (op.x * sc, op.y * sc, (op.x + op.w) * sc, (op.y + op.h) * sc)
        result.fillRectPx(x0 - t / 2, y0 - t / 2, x1 + t / 2, y0 + t / 2, op.color)
        result.fillRectPx(x0 - t / 2, y1 - t / 2, x1 + t / 2, y1 + t / 2, op.color)
        result.fillRectPx(x0 - t / 2, y0 + t / 2, x0 + t / 2, y1 - t / 2, op.color)
        result.fillRectPx(x1 - t / 2, y0 + t / 2, x1 + t / 2, y1 - t / 2, op.color)
    of oLine:
      let t = max(1.0, op.width * sc)
      if abs(op.h) < 1e-6:
        result.fillRectPx(op.x * sc, op.y * sc - t / 2, (op.x + op.w) * sc, op.y * sc + t / 2,
                          op.color)
      elif abs(op.w) < 1e-6:
        result.fillRectPx(op.x * sc - t / 2, op.y * sc, op.x * sc + t / 2, (op.y + op.h) * sc,
                          op.color)
      else:
        let len = max(abs(op.w), abs(op.h)) * sc
        let n = if len.isNaN: 0 else: int(min(len, 20000.0)) + 1
        for k in 0 .. n:
          let f = float(k) / float(n)
          let px = (op.x + op.w * f) * sc
          let py = (op.y + op.h * f) * sc
          result.fillRectPx(px - t / 2, py - t / 2, px + t / 2, py + t / 2, op.color)
    of oImage: result.drawImagePx(op.image, op.x * sc, op.y * sc, op.w * sc, op.h * sc)
    of oText: result.drawGlyphs(op, sc)
    of oLink: discard
  result.changed()

proc savePng*(r: Report; index: int; path: string; dpi = 150.0): bool {.discardable.} =
  ## Writes page `index` (from 0) as a PNG picture at `dpi`.
  let b = r.renderPage(index, dpi / 72)
  if b == nil: return false
  try:
    writeFile(path, encodePng(b))
    true
  except IOError, OSError:
    false

# ---- printing ----------------------------------------------------------------------------------------

when not androidApp and not defined(ios) and not defined(windows):
  proc runOut(exe: string; args: openArray[string]): tuple[code: int; output: string] =
    ## Runs `exe` and returns its exit code and output (-1: it did not run).
    try:
      let p = startProcess(exe, args = args, options = {poStdErrToStdOut})
      result.output = p.outputStream.readAll().strip
      result.code = p.waitForExit()
      p.close()
    except OSError, IOError:
      result = (-1, "")

proc printPdf*(path: string; jobName = ""; printer = ""; pages = 0): tuple[ok: bool; message: string] =
  ## Sends the PDF file `path` to a printer, and says what happened (or why
  ## it could not) in `message`:
  ##
  ## - Linux, the BSDs, macOS: through CUPS (`lp`) to `printer`, or the
  ##   default one; it fails cleanly when no printer is set up.
  ## - Windows: to the app that prints PDF files (the "print" verb), so a
  ##   PDF reader must be installed (Acrobat Reader, SumatraPDF, Foxit...).
  ## - Android: the system's print dialog (its printers, Save as PDF);
  ##   `pages` (if known) shows there.
  ## - iOS: not available yet.
  ## - A web page: the browser's print dialog, with the PDF in it (its
  ##   printers, Save as PDF).
  if not fileExists(path): return (false, "There is no file " & path & ".")
  when defined(wasm):
    return if systemCall("print", path) == "1": (true, "Printing (the browser's print dialog).")
           else: (false, "This browser cannot print the document; save it as PDF instead.")
  let job = if jobName.len > 0: jobName else: path.extractFilename
  when androidApp:
    let res = systemCall("print.pdf", absolutePath(path) & "\t" & job & "\t" &
                         (if pages > 0: $pages else: ""))
    if res == "1": (true, "Opened the print dialog for " & job & ".")
    else: (false, "Printing is not available on this device.")
  elif defined(ios):
    (false, "Printing is not available on iOS yet.")
  elif defined(windows):
    type ShellExecuteW = proc (hwnd: pointer; op, file, params, dir: WideCString;
                               show: int32): int {.stdcall.}
    let lib = loadLib("shell32.dll")
    if lib == nil: return (false, "Cannot reach the Windows shell.")
    let fn = cast[ShellExecuteW](lib.symAddr("ShellExecuteW"))
    if fn == nil: return (false, "Cannot reach the Windows shell.")
    let r = fn(nil, newWideCString("print"), newWideCString(absolutePath(path)), nil, nil, 0)
    if r > 32: (true, "Sent " & job & " to the default printer.")
    else: (false, "Windows has no app that prints PDF files: install a PDF reader " &
                  "(Acrobat Reader, SumatraPDF...), or open the file and print it from there.")
  else:
    let lp = findExe("lp")
    if lp.len == 0:
      return (false, "There is no printing system here (CUPS's lp): install CUPS, or " &
                     "open the PDF and print it from its reader.")
    if printer.len == 0:
      let stat = findExe("lpstat")
      if stat.len > 0:
        let d = runOut(stat, ["-d"])
        if d.code == 0 and d.output.toLowerAscii.contains("no system default"):
          let ps = runOut(stat, ["-p"])
          if ps.code != 0 or not ps.output.contains("printer "):
            return (false, "No printer is set up.")
    var args = @["-t", job]
    if printer.len > 0: args.add ["-d", printer]
    args.add path
    let res = runOut(lp, args)
    if res.code == 0: (true, if res.output.len > 0: res.output else: "Sent " & job & " to the printer.")
    elif res.code < 0: (false, "lp could not be started.")
    else: (false, if res.output.len > 0: res.output else: "lp could not print " & job & ".")

proc printReport*(r: Report; jobName = ""; printer = ""): tuple[ok: bool; message: string] =
  ## Prints the document (see `printPdf` for each system): it is written as
  ## a PDF file in a temporary folder first.
  let dir = when androidApp: dataDir("retro-print") else: getTempDir() / "retro-print"
  try: createDir(dir) except OSError, IOError: discard
  var name = (if r.title.len > 0: r.title else: "document")
  for c in name.mitems:
    if c in {'/', '\\', ':', '*', '?', '"', '<', '>', '|', '\0' .. '\31'}: c = '_'
  if name.runeLen > 80: name = name.runeSubStr(0, 80)
  let path = dir / name & ".pdf"
  try: r.savePdf(path)
  except IOError, OSError: return (false, "Cannot write " & path & ".")
  printPdf(path, if jobName.len > 0: jobName else: r.title, printer, r.pageCount)

# ---- from HTML ----------------------------------------------------------------------------------------

proc parseCssColor(s: string): Color =
  let t = s.strip.toLowerAscii
  if t.startsWith("rgb"):
    let a = t.find('(')
    let b = t.find(')')
    if a > 0 and b > a:
      let parts = t[a + 1 ..< b].split(',')
      if parts.len >= 3:
        try:
          return color(uint8(clamp(parseInt(parts[0].strip), 0, 255)),
                       uint8(clamp(parseInt(parts[1].strip), 0, 255)),
                       uint8(clamp(parseInt(parts[2].strip), 0, 255)))
        except ValueError: return Color()
  namedColor(t)

proc parseLength(s: string; base: float): float =
  ## "12px" (as points: 0.75 each), "10pt", "1.2em", "50%" (of `base`).
  let t = s.strip.toLowerAscii
  try:
    if t.endsWith("px"): parseFloat(t[0 ..< ^2]) * 0.75
    elif t.endsWith("pt"): parseFloat(t[0 ..< ^2])
    elif t.endsWith("em"): parseFloat(t[0 ..< ^2]) * base
    elif t.endsWith("mm"): mm(parseFloat(t[0 ..< ^2]))
    elif t.endsWith("%"): parseFloat(t[0 ..< ^1]) / 100 * base
    elif t.len > 0: parseFloat(t) * 0.75
    else: 0.0
  except ValueError: 0.0

proc decodeEntities(s: string): string =
  var i = 0
  while i < s.len:
    if s[i] == '&':
      let e = s.find(';', i)
      if e > i and e - i <= 10:
        let ent = s[i + 1 ..< e]
        var rep = ""
        case ent
        of "amp": rep = "&"
        of "lt": rep = "<"
        of "gt": rep = ">"
        of "quot": rep = "\""
        of "apos", "#39": rep = "'"
        of "nbsp": rep = " "
        of "copy": rep = "©"
        of "reg": rep = "®"
        of "euro": rep = "€"
        of "pound": rep = "£"
        of "mdash": rep = "—"
        of "ndash": rep = "–"
        of "hellip": rep = "…"
        of "bull": rep = "•"
        of "times": rep = "×"
        of "middot": rep = "\u00B7"
        of "laquo": rep = "\u00AB"
        of "raquo": rep = "\u00BB"
        of "lsquo": rep = "\u2018"
        of "rsquo": rep = "\u2019"
        of "ldquo": rep = "\u201C"
        of "rdquo": rep = "\u201D"
        of "deg": rep = "\u00B0"
        of "plusmn": rep = "\u00B1"
        of "divide": rep = "\u00F7"
        of "trade": rep = "\u2122"
        of "sect": rep = "\u00A7"
        of "yen": rep = "\u00A5"
        of "cent": rep = "\u00A2"
        of "shy": rep = "\u00AD"
        of "zwnj": rep = "\u200C"
        of "zwj": rep = "\u200D"
        of "lrm": rep = "\u200E"
        of "rlm": rep = "\u200F"
        else:
          if ent.len > 1 and ent[0] == '#':
            try:
              let v = if ent[1] in {'x', 'X'}: parseHexInt(ent[2 .. ^1]) else: parseInt(ent[1 .. ^1])
              if v > 0 and v < 0x110000 and v notin 0xD800 .. 0xDFFF: rep = Rune(v).toUTF8
            except ValueError: discard
        if rep.len > 0 or ent in ["amp"]:
          result.add rep
          i = e + 1
          continue
    result.add s[i]
    inc i

type
  Tok = object
    kind: int               ## 0 text, 1 start, 2 end
    name, text: string
    attrs: Table[string, string]
    selfClose: bool

proc tokens(html: string): seq[Tok] =
  var i = 0
  let n = html.len
  var text = ""
  template flush() =
    if text.len > 0:
      result.add Tok(kind: 0, text: decodeEntities(text))
      text = ""
  var skipUntil = ""
  while i < n and result.len < 2_000_000:
    if html[i] == '<':
      if html.continuesWith("<!--", i):
        let e = html.find("-->", i + 4)
        i = if e < 0: n else: e + 3
        continue
      if i + 1 < n and html[i + 1] in {'!', '?'}:
        let e = html.find('>', i)
        i = if e < 0: n else: e + 1
        continue
      let e = html.find('>', i)
      if e < 0:
        text.add html[i .. ^1]
        break
      var tag = html[i + 1 ..< e]
      i = e + 1
      var isEnd = false
      if tag.startsWith("/"):
        isEnd = true
        tag = tag[1 .. ^1]
      var selfClose = tag.endsWith("/")
      if selfClose: tag = tag[0 ..< ^1]
      var k = 0
      while k < tag.len and tag[k] notin Whitespace: inc k
      let name = tag[0 ..< k].toLowerAscii
      if name.len == 0:
        text.add "<" & tag & ">"
        continue
      if skipUntil.len > 0:
        if isEnd and name == skipUntil: skipUntil = ""
        continue
      flush()
      var t = Tok(kind: if isEnd: 2 else: 1, name: name, selfClose: selfClose)
      # attributes: name="v", name='v', name=v, name
      var j = k
      while j < tag.len:
        while j < tag.len and tag[j] in Whitespace: inc j
        var a = j
        while j < tag.len and tag[j] notin Whitespace + {'='}: inc j
        let an = tag[a ..< j].toLowerAscii
        while j < tag.len and tag[j] in Whitespace: inc j
        var av = ""
        if j < tag.len and tag[j] == '=':
          inc j
          while j < tag.len and tag[j] in Whitespace: inc j
          if j < tag.len and tag[j] in {'"', '\''}:
            let q = tag[j]
            let qe = tag.find(q, j + 1)
            av = if qe < 0: tag[j + 1 .. ^1] else: tag[j + 1 ..< qe]
            j = if qe < 0: tag.len else: qe + 1
          else:
            a = j
            while j < tag.len and tag[j] notin Whitespace: inc j
            av = tag[a ..< j]
        if an.len > 0 and t.attrs.len < 64: t.attrs[an] = decodeEntities(av)
        if j == a: inc j
      if not isEnd and name in ["script", "style", "head"]:
        skipUntil = name
        if name == "head": skipUntil = ""          # (its title is read)
        if name != "head": continue
      result.add t
    else:
      if skipUntil.len == 0: text.add html[i]
      inc i
  flush()

proc styleOf(attrs: Table[string, string]): Table[string, string] =
  for decl in attrs.getOrDefault("style").split(';'):
    let c = decl.find(':')
    if c > 0: result[decl[0 ..< c].strip.toLowerAscii] = decl[c + 1 .. ^1].strip.toLowerAscii

proc reportFromHtml*(html: string; baseDir = ""; title = ""): Report =
  ## A document from HTML -- typically a filled-in template
  ## (`reportFromHtml(renderTemplate(tpl, data))`). It reads:
  ##
  ## - `h1`-`h4` (titles), `p`, `div`, `br`, `hr`, `pre`, `blockquote`,
  ##   `ul` / `ol` / `li`
  ## - `b` / `strong`, `i` / `em`, `u`, `code` / `tt` / `kbd`, `small`,
  ##   `a href` (links), `span` and `font` with `style="color: #c00;
  ##   font-weight: bold; font-style: italic; font-size: 14px"`
  ## - `table` (`border="1"`: lines around every cell), `thead` / `tbody` / `tfoot`
  ##   (totals), `tr`, `th`, `td`
  ##   with `colspan`, `align`, `width` (px, pt or %) and a background
  ##   (`bgcolor`, `style="background: ..."`); a header cell's `align` is
  ##   its column's; `class="plain"`: no lines or shading (for layout)
  ## - `img src width height` (PNG, JPEG, BMP files, relative to
  ##   `baseDir`; in a table cell, above the cell's text)
  ## - `style="text-align: center | right"` and `dir="rtl"` on blocks,
  ##   `style="page-break-before: always"` (or `class="page-break"`) for a
  ##   new page
  ## - `<header>` and `<footer>`: the text of every page's top and bottom;
  ##   with spans in them, the first goes left, the last right
  ##   (`{page}` and `{pages}` are filled in); `<title>`: the title
  ##
  ## Scripts, styles and forms are left out. Anything else shows its text.
  result = newReport(title)
  let doc = result
  type Inline = object
    bold, italic, under, mono: bool
    color: Color
    size: float
    link: string
  var st = @[Inline()]
  var spans: seq[Span]
  var align = alLeft
  var alignSet = false
  var rtl = -1
  var heading = 0
  var listStack: seq[tuple[numbered: bool; n: int]]
  var bullet = ""
  var indent = 0.0
  var pre = 0
  var inTitle = false
  var hdrSpans: seq[string]
  var inHeaderFooter = 0                   # 1 header, 2 footer
  var hfText = ""
  # tables
  var inTable = false
  var tbl: ReportTable
  var section = rkBody
  var row: TRow
  var inRow = false
  var cellOpen = false
  var cur: Cell
  var cellIsHead = false
  var colIndex = 0
  var tableDepth = 0
  var lastSpace = true                     # the text so far ends with a space
  proc addText(s: string) =
    var t = s
    if pre == 0:
      # white space folds, as in a browser
      var o = ""
      for c in t:
        if c in {' ', '\t', '\n', '\r'}:
          if not lastSpace: o.add ' '
          lastSpace = true
        else:
          o.add c
          lastSpace = false
      t = o
    else: lastSpace = false
    if t.len == 0: return
    let s = st[^1]
    let sp = Span(text: t, bold: s.bold or heading > 0 or (cellOpen and cellIsHead),
                  italic: s.italic, mono: s.mono or pre > 0, underline: s.under,
                  color: s.color, size: s.size, link: s.link)
    if inHeaderFooter > 0: hfText.add t
    elif cellOpen: cur.spans.add sp
    else: spans.add sp
  proc addBreak() =
    lastSpace = true
    if inHeaderFooter > 0: hfText.add ' '
    elif cellOpen: cur.spans.add Span(text: "\n")
    else: spans.add Span(text: "\n")
  proc trimmed(ss: seq[Span]): seq[Span] =
    result = ss
    while result.len > 0 and result[0].text.strip.len == 0 and result[0].text.find('\n') < 0:
      result.delete(0)
    if result.len > 0: result[0].text = result[0].text.strip(trailing = false)
    while result.len > 0 and result[^1].text.strip.len == 0 and result[^1].text.find('\n') < 0:
      result.setLen(result.len - 1)
    if result.len > 0: result[^1].text = result[^1].text.strip(leading = false)
  proc flushPara() =
    lastSpace = true
    let ss = trimmed(spans)
    spans.setLen(0)
    if ss.len == 0: return
    if heading > 0:
      var t = ""
      for s in ss: t.add s.text
      doc.add Block(kind: bHeading, spans: ss, level: heading, align: align,
                    alignSet: alignSet, rtl: rtl)
    else:
      doc.add Block(kind: bPara, spans: ss, align: align, alignSet: alignSet, rtl: rtl,
                    indent: indent, bullet: bullet)
    bullet = ""
  proc closeCell() =
    if not cellOpen: return
    cur.spans = trimmed(cur.spans)
    row.cells.add cur
    colIndex += max(1, cur.colspan)
    cellOpen = false
  proc closeRow() =
    closeCell()
    if inRow and row.cells.len > 0 and tbl.rows.len < 1_000_000: tbl.rows.add row
    inRow = false
  proc finishTable() =
    closeRow()
    inTable = false
    # widths in % are shares; the columns without one share what is left
    var pct = 0.0
    var free = 0
    var cols = 0
    for r in tbl.rows:
      var k = 0
      for c in r.cells: k += max(1, c.colspan)
      cols = max(cols, k)
    while tbl.widths.len < cols: tbl.widths.add 0
    for w in tbl.widths:
      if w < 0: pct += -w
      elif w == 0: inc free
    if pct > 0 and free > 0:
      let each = max(100.0 - pct, 5.0 * float(free)) / float(free)
      for w in tbl.widths.mitems:
        if w == 0: w = -each
    if tbl.rows.len > 0: doc.table(tbl)
  proc blockAttrs(t: Tok) =
    let css = styleOf(t.attrs)
    var a = t.attrs.getOrDefault("align", css.getOrDefault("text-align"))
    case a.toLowerAscii
    of "center": align = alCenter; alignSet = true
    of "right": align = alRight; alignSet = true
    of "left": align = alLeft; alignSet = true
    else: discard
    let d = t.attrs.getOrDefault("dir", css.getOrDefault("direction")).toLowerAscii
    if d == "rtl": rtl = 1
    elif d == "ltr": rtl = 0
    if css.getOrDefault("page-break-before") == "always" or
       "page-break" in t.attrs.getOrDefault("class"):
      doc.pageBreak()
  proc resetBlock() =
    align = alLeft
    alignSet = false
    rtl = -1
  for t in tokens(html):
    case t.kind
    of 0:
      if inTitle:
        if doc.title.len == 0: doc.title = t.text.strip
      else: addText(t.text)
    of 1:
      let css = styleOf(t.attrs)
      if tableDepth > 1 and t.name in ["thead", "tbody", "tfoot", "tr", "th", "td"]:
        # a table in a table: its cells become lines of text
        if t.name == "tr" and cur.spans.len > 0: addBreak()
        elif t.name in ["td", "th"]: addText(" ")
        continue
      case t.name
      of "title": inTitle = true
      of "header", "footer":
        flushPara()
        inHeaderFooter = if t.name == "header": 1 else: 2
        hdrSpans.setLen(0)
        hfText = ""
      of "h1", "h2", "h3", "h4", "h5", "h6":
        let level = min(4, ord(t.name[1]) - ord('0'))
        if cellOpen:
          # a title in a cell: bigger bold text on a line of its own
          if cur.spans.len > 0: addBreak()
          var s = st[^1]
          s.bold = true
          s.size = doc.headingSize(level)
          if st.len < 256: st.add s
        else:
          flushPara()
          resetBlock()
          blockAttrs(t)
          heading = level
      of "p", "div", "blockquote", "center", "section", "article":
        if not cellOpen:
          flushPara()
          resetBlock()
          blockAttrs(t)
          if t.name == "center":
            align = alCenter
            alignSet = true
          if t.name == "blockquote": indent += 18
      of "pre":
        flushPara()
        resetBlock()
        inc pre
      of "br": addBreak()
      of "hr":
        flushPara()
        doc.rule()
      of "ul", "ol":
        flushPara()
        listStack.add (t.name == "ol", 0)
        indent = 18.0 * float(listStack.len)
      of "li":
        flushPara()
        resetBlock()
        if listStack.len > 0:
          inc listStack[^1].n
          bullet = if listStack[^1].numbered: $listStack[^1].n & "." else: "•"
        else: bullet = "•"
      of "b", "strong", "i", "em", "u", "ins", "code", "tt", "kbd", "samp", "small", "big",
         "span", "font", "a", "mark":
        var s = st[^1]
        case t.name
        of "b", "strong": s.bold = true
        of "i", "em": s.italic = true
        of "u", "ins": s.under = true
        of "code", "tt", "kbd", "samp": s.mono = true
        of "small": s.size = (if s.size > 0: s.size else: doc.size) * 0.85
        of "big": s.size = (if s.size > 0: s.size else: doc.size) * 1.2
        of "a": s.link = t.attrs.getOrDefault("href")
        else: discard
        let c = parseCssColor(t.attrs.getOrDefault("color", css.getOrDefault("color")))
        if c.a != 0: s.color = c
        let fw = css.getOrDefault("font-weight")
        if fw in ["bold", "bolder", "600", "700", "800", "900"]: s.bold = true
        elif fw in ["normal", "400"]: s.bold = false
        if css.getOrDefault("font-style") == "italic": s.italic = true
        if css.hasKey("font-size"):
          let z = parseLength(css["font-size"], doc.size)
          if z > 0: s.size = min(z, 200.0)
        if css.getOrDefault("text-decoration").contains("underline"): s.under = true
        if st.len < 256: st.add s
      of "img":
        let src = t.attrs.getOrDefault("src")
        if src.len > 0 and not src.contains("://"):
          let path = if src.isAbsolute or baseDir.len == 0: src else: baseDir / src
          let b = try: loadPicture(path) except CatchableError: nil
          if b != nil:
            let w = parseLength(t.attrs.getOrDefault("width", css.getOrDefault("width")), 0)
            let h = parseLength(t.attrs.getOrDefault("height", css.getOrDefault("height")), 0)
            if cellOpen:
              # a picture in a table cell: above the cell's text
              if cur.image == nil:
                cur.image = b
                cur.imageW = w
                cur.imageH = h
              continue
            flushPara()
            var al = alLeft
            if t.attrs.getOrDefault("align").toLowerAscii == "center" or alignSet and align == alCenter:
              al = alCenter
            elif t.attrs.getOrDefault("align").toLowerAscii == "right" or alignSet and align == alRight:
              al = alRight
            doc.image(b, w, h, al)
        elif t.attrs.hasKey("alt"): addText(t.attrs["alt"])
      of "table":
        inc tableDepth
        if tableDepth == 1:
          flushPara()
          inTable = true
          tbl = ReportTable(zebra: "plain" notin t.attrs.getOrDefault("class") and
                                   not t.attrs.hasKey("border"),
                            plain: "plain" in t.attrs.getOrDefault("class"),
                            grid: t.attrs.getOrDefault("border", "0") notin ["", "0"],
                            headerFill: if "plain" in t.attrs.getOrDefault("class"): Color()
                                        else: Color(r: 230, g: 230, b: 230, a: 255))
          section = rkBody
      of "thead": section = rkHeader
      of "tbody": section = rkBody
      of "tfoot": section = rkTotal
      of "tr":
        if inTable:
          closeRow()
          inRow = true
          row = TRow(kind: section)
          colIndex = 0
      of "th", "td":
        if inTable:
          if not inRow:
            inRow = true
            row = TRow(kind: section)
            colIndex = 0
          closeCell()
          cellOpen = true
          cellIsHead = t.name == "th" or section != rkBody
          if t.name == "th" and section == rkBody and tbl.rows.len == 0: row.kind = rkHeader
          cur = Cell(colspan: 1)
          try: cur.colspan = clamp(parseInt(t.attrs.getOrDefault("colspan", "1")), 1, 64)
          except ValueError: discard
          let a = t.attrs.getOrDefault("align", css.getOrDefault("text-align")).toLowerAscii
          case a
          of "center": cur.align = alCenter; cur.alignSet = true
          of "right": cur.align = alRight; cur.alignSet = true
          of "left": cur.align = alLeft; cur.alignSet = true
          else: discard
          let bg = parseCssColor(t.attrs.getOrDefault("bgcolor",
                     css.getOrDefault("background-color", css.getOrDefault("background"))))
          if bg.a != 0: cur.fill = bg
          let w = t.attrs.getOrDefault("width", css.getOrDefault("width")).strip
          if w.len > 0 and cur.colspan == 1:
            while tbl.widths.len <= colIndex: tbl.widths.add 0
            if tbl.widths[colIndex] == 0:
              if w.endsWith("%"):
                try: tbl.widths[colIndex] = -max(0.1, parseFloat(w[0 ..< ^1]))
                except ValueError: discard
              else:
                let v = parseLength(w, 0)
                if v > 0: tbl.widths[colIndex] = v
          # a header cell's alignment is its column's
          if cur.alignSet and row.kind == rkHeader and cur.colspan == 1:
            while tbl.aligns.len <= colIndex: tbl.aligns.add alLeft
            tbl.aligns[colIndex] = cur.align
      else: discard
    else:
      case t.name
      of "title": inTitle = false
      of "header", "footer":
        let which = inHeaderFooter
        inHeaderFooter = 0
        let parts = if hdrSpans.len > 0: hdrSpans else: @[hfText.strip]
        var trip = ["", "", ""]
        case parts.len
        of 0: discard
        of 1: trip[1] = parts[0]
        of 2: trip = [parts[0], "", parts[1]]
        else: trip = [parts[0], parts[1], parts[^1]]
        if which == 1: doc.header(trip[0], trip[1], trip[2])
        else: doc.footer(trip[0], trip[1], trip[2])
      of "h1", "h2", "h3", "h4", "h5", "h6":
        if cellOpen:
          if st.len > 1: discard st.pop()
          addBreak()
        else:
          flushPara()
          heading = 0
          resetBlock()
      of "p", "div", "blockquote", "center", "section", "article":
        if not cellOpen:
          flushPara()
          if t.name == "blockquote": indent = max(0.0, indent - 18)
          resetBlock()
        elif cur.spans.len > 0: addBreak()
      of "pre":
        flushPara()
        pre = max(0, pre - 1)
      of "li": flushPara()
      of "ul", "ol":
        flushPara()
        if listStack.len > 0: discard listStack.pop()
        indent = 18.0 * float(listStack.len)
      of "b", "strong", "i", "em", "u", "ins", "code", "tt", "kbd", "samp", "small", "big",
         "span", "font", "a", "mark":
        if inHeaderFooter > 0 and t.name == "span":
          hdrSpans.add hfText.strip
          hfText = ""
        if st.len > 1: discard st.pop()
      of "th", "td":
        if tableDepth == 1: closeCell()
      of "tr":
        if tableDepth == 1: closeRow()
      of "thead", "tfoot":
        if tableDepth == 1:
          closeRow()
          section = rkBody
      of "table":
        if tableDepth == 1 and inTable: finishTable()
        tableDepth = max(0, tableDepth - 1)
      else: discard
  if inTable: finishTable()
  flushPara()

# ---- on screen ---------------------------------------------------------------------------------------

type
  ReportViewEvent* = object
    ## What happened in a `reportView` this frame.
    page*: int               ## the page shown (from 0)
    pages*: int              ## how many there are
    link*: string            ## a link clicked or tapped ("" none)
  ViewCache = ref object
    zoomSel: int             ## 0 fit width, 1 whole page, then the fixed zooms
    sx, sy: float            ## scrolled, in logical pixels
    page: int
    toPage: int              ## the page a glide is on its way to (else `page`)
    bitmaps: Table[int, tuple[scale: float; b: Bitmap]]
    used: seq[int]
    forReport: Report
    forVersion: int
    dragX, dragY: int
    dragged: bool

const
  zoomNames = ["Fit width", "Whole page", "50%", "75%", "100%", "125%", "150%", "200%"]
  zoomValues = [0.0, 0.0, 0.5, 0.75, 1.0, 1.25, 1.5, 2.0]

var views: Table[string, ViewCache]

proc zoomStep(sel, by: int): int =
  ## The next fixed zoom up or down (from "fit" it starts at 100%).
  clamp((if sel < 2: 4 else: sel) + by, 2, zoomValues.high)

proc reportView*(r: Report; height = -1; key = ""): ReportViewEvent {.discardable.} =
  ## The pages of `r` on a gray desk, one under the other, with page
  ## buttons and a zoom list above them (fit the width, the whole page, 50%
  ## to 200%; 100% is the paper's real size on a 96 dpi screen). The wheel
  ## and the standard scroll bars move through the pages (Shift + the wheel
  ## sideways, Ctrl + the wheel zooms); a finger or a mouse drag moves them;
  ## with the keyboard focus: arrows, Page Up / Page Down, Home / End, + and
  ## -. A click on a link reports it in `link`. `height` -1 takes the room
  ## left; `key` tells two views apart. Pages are drawn once per zoom and
  ## kept (the last 6), so scrolling is quick.
  if r == nil: return
  var v = views.getOrDefault(key, nil)
  if v == nil:
    v = ViewCache()
    views[key] = v
  let pages = r.layoutPages()
  if v.forReport != r or v.forVersion != r.layouts:
    v.bitmaps.clear()
    v.used.setLen(0)
    v.forReport = r
    v.forVersion = r.layouts
  let n = pages.len
  result.pages = n
  let size = r.pageSizeOf
  pushId("reportview:" & key)
  defer: popId()
  # the bar: pages and zoom
  var goPage = -1
  v.page = clamp(v.page, 0, max(0, n - 1))
  # (the buttons go on from the page a glide is going to: quick clicks add up)
  v.toPage = clamp(v.toPage, 0, max(0, n - 1))
  row:
    if toolButton(nfStepBackward, "First page", enabled = v.toPage > 0): goPage = 0
    if toolButton(nfChevronLeft, "Previous page", enabled = v.toPage > 0): goPage = v.toPage - 1
    label("Page " & $(v.page + 1) & " of " & $n)
    if toolButton(nfChevronRight, "Next page", enabled = v.toPage < n - 1): goPage = v.toPage + 1
    if toolButton(nfStepForward, "Last page", enabled = v.toPage < n - 1): goPage = n - 1
    if combo(zoomNames, v.zoomSel, w = dp(110)): ui.redraw = true
  let id = idOf("desk")
  let gap = dp(12)
  let deskH = max(dp(80), if height < 0: remainingH() else: height)
  let desk = place(0, deskH, fill = true)
  # the zoom: logical pixels per point
  let sb = SbW
  let z = case v.zoomSel
          of 0: max(0.05, float(desk.w - 2 * gap - sb) / size.w)
          of 1: max(0.05, min(float(desk.w - 2 * gap - sb) / size.w,
                              float(desk.h - 2 * gap) / size.h))
          else: zoomValues[clamp(v.zoomSel, 2, zoomValues.high)] * dpf(96 / 72)
  let pw = size.w * z
  let ph = size.h * z
  let stride = ph + float(gap)
  let totalH = float(n) * stride + float(gap)
  let totalW = pw + 2 * float(gap)
  let vBar = totalH > float(desk.h)
  let hBar = totalW > float(desk.w - (if vBar: sb else: 0))
  let viewW = desk.w - (if vBar: sb else: 0)
  let viewH = desk.h - (if hBar: sb else: 0)
  let maxY = max(0.0, totalH - float(viewH))
  let maxX = max(0.0, totalW - float(viewW))
  let view = rect(desk.x, desk.y, viewW, viewH)
  let hit = interact(id, view)
  var sy = clamp(v.sy, 0.0, maxY)
  var sx = clamp(v.sx, 0.0, maxX)
  let left0 = if totalW <= float(viewW): (float(viewW) - pw) / 2 else: float(gap)
  proc pageAt(y: float): int = clamp(int(y / stride), 0, max(0, n - 1))
  # the wheel, the keys and the page buttons glide, a flick goes on (the
  # scrollers work in whole pixels: `iy`, `ix`)
  let syId = id + 501
  let sxId = id + 502
  let hiY = int(maxY)
  let hiX = int(maxX)
  var iy = int(round(sy))
  var ix = int(round(sx))
  if goPage >= 0:
    scrollTo(syId, iy, int(float(clamp(goPage, 0, max(0, n - 1))) * stride), hiY)
  if canInput():
    if mouseIn(view) and ui.wheel != 0 and not ui.wheelUsed and CtrlPressed in ui.mods:
      ui.wheelUsed = true
      v.zoomSel = zoomStep(v.zoomSel, if ui.wheel > 0: 1 else: -1)
    scrollWheel(sxId, ix, hiX, view, dp(48), sideways = true)
    scrollWheel(syId, iy, hiY, view, dp(48))
    if mouseIn(view) and ui.wheel != 0 and not ui.wheelUsed: ui.wheelUsed = true
    scrollPan2(syId, iy, hiY, sxId, ix, hiX, view)
  sy = float(iy)
  sx = float(ix)
  if canInput():
    # a mouse drag moves the pages too (a click without moving opens a link)
    if hit.down and ui.pressed:
      v.dragX = ui.mx
      v.dragY = ui.my
      v.dragged = false
    if ui.active == id and ui.mouseDown and not finger():
      let dx = ui.mx - v.dragX
      let dy = ui.my - v.dragY
      if not v.dragged and abs(dx) + abs(dy) > dp(4): v.dragged = true
      if v.dragged:
        scrollStop(syId)
        scrollStop(sxId)
        sx -= float(dx)
        sy -= float(dy)
        v.dragX = ui.mx
        v.dragY = ui.my
      if canHover(): ui.cursor = curHand
    if hit.clicked and not v.dragged:
      let px = float(ui.mx - view.x) + sx - left0
      let py = float(ui.my - view.y) + sy - float(gap)
      let pi = pageAt(py)
      let lx = px / z
      let ly = (py - float(pi) * stride) / z
      if pi in 0 ..< n:
        for op in pages[pi]:
          if op.kind == oLink and lx >= op.x and lx <= op.x + op.w and ly >= op.y and
             ly <= op.y + op.h:
            result.link = op.uri
    elif hit.hover and canHover() and ui.active != id:
      # the hand over links
      let px = float(ui.mx - view.x) + sx - left0
      let py = float(ui.my - view.y) + sy - float(gap)
      let pi = pageAt(py)
      if pi in 0 ..< n:
        let lx = px / z
        let ly = (py - float(pi) * stride) / z
        for op in pages[pi]:
          if op.kind == oLink and lx >= op.x and lx <= op.x + op.w and ly >= op.y and
             ly <= op.y + op.h:
            ui.cursor = curHand
            break
    if hit.focused and not ui.keyUsed:
      let step = dp(40)
      var used = true
      iy = int(round(sy))
      ix = int(round(sx))
      case ui.key
      of KeyDown: scrollBy(syId, iy, step, hiY)
      of KeyUp: scrollBy(syId, iy, -step, hiY)
      of KeyPageDown, KeySpace: scrollBy(syId, iy, viewH - step, hiY)
      of KeyPageUp: scrollBy(syId, iy, -(viewH - step), hiY)
      of KeyHome: scrollTo(syId, iy, 0, hiY)
      of KeyEnd: scrollTo(syId, iy, hiY, hiY)
      of KeyRight:
        if maxX > 0: scrollBy(sxId, ix, step, hiX)
        else: scrollTo(syId, iy, int(float(min(n - 1, v.toPage + 1)) * stride), hiY)
      of KeyLeft:
        if maxX > 0: scrollBy(sxId, ix, -step, hiX)
        else: scrollTo(syId, iy, int(float(max(0, v.toPage - 1)) * stride), hiY)
      of KeyPlus, KeyEqual:
        if CtrlPressed notin ui.mods: v.zoomSel = zoomStep(v.zoomSel, 1) else: used = false
      of KeyMinus:
        if CtrlPressed notin ui.mods: v.zoomSel = zoomStep(v.zoomSel, -1) else: used = false
      else: used = false
      if used: ui.keyUsed = true
  # where the glides and flicks are now; the standard scroll bars
  iy = int(round(sy))
  ix = int(round(sx))
  scrollTick(syId, iy, hiY)
  scrollTick(sxId, ix, hiX)
  if vBar:
    scrollBarFor(idOf("vbar"), syId, rect(desk.x + desk.w - sb, desk.y, sb, viewH), true, iy,
                 hiY, max(ItemH, viewH - ItemH), dp(40))
  if hBar:
    scrollBarFor(idOf("hbar"), sxId, rect(desk.x, desk.y + desk.h - sb, viewW, sb), false, ix,
                 hiX, max(ItemH, viewW - ItemH), dp(40))
  if iy != int(round(sy)): sy = float(iy)
  if ix != int(round(sx)): sx = float(ix)
  sy = clamp(sy, 0.0, maxY)
  sx = clamp(sx, 0.0, maxX)
  if sy != v.sy or sx != v.sx: ui.redraw = true
  v.sy = sy
  v.sx = sx
  # the page shown: the one at the top third of the view (the last at the end)
  v.page = if sy >= maxY and maxY > 0: n - 1 else: pageAt(sy + float(viewH) / 3)
  v.page = clamp(v.page, 0, max(0, n - 1))
  result.page = v.page
  let ty = float(scrollTarget(syId, iy))
  v.toPage = clamp(if ty >= maxY and maxY > 0: n - 1 else: pageAt(ty + float(viewH) / 3),
                   0, max(0, n - 1))
  # the desk and the pages on it
  fill(view, color(128, 128, 128))
  if vBar and hBar: fill(rect(desk.x + viewW, desk.y + viewH, sb, sb), ui.theme.face)
  pushClip(view)
  let left = float(view.x) + left0 - (if totalW > float(viewW): sx else: 0.0)
  let scale = z * float(pxScale)
  for i in 0 ..< n:
    let top = float(view.y) + float(gap) + float(i) * stride - sy
    if top > float(view.y + viewH) or top + ph < float(view.y): continue
    let pr = rect(int(left), int(top), max(1, int(pw)), max(1, int(ph)))
    fill(rect(pr.x + 3, pr.y + 3, pr.w, pr.h), color(80, 80, 80))
    fill(pr, color(255, 255, 255))
    var bm: Bitmap = nil
    if v.bitmaps.hasKey(i) and abs(v.bitmaps[i].scale - scale) < 1e-9:
      bm = v.bitmaps[i].b
    else:
      bm = r.renderPage(i, scale)
      v.bitmaps[i] = (scale, bm)
      v.used.add i
      while v.used.len > 6:
        let old = v.used[0]
        v.used.delete(0)
        if old notin v.used: v.bitmaps.del old
    if bm != nil: drawBitmap(pr, bm)
  popClip()
  if hit.focused: dots(inset(view, 2), color(255, 255, 255))
  if accessOn:
    accessNode(arImage, (if r.title.len > 0: r.title else: "Report"), id = id, r = desk,
               help = $r.pageCount & " pages")
  ui.lastId = id
  ui.lastRect = desk

proc reportViewPage*(key = ""): int =
  ## The page the `reportView` with `key` shows (from 0).
  let v = views.getOrDefault(key, nil)
  if v == nil: 0 else: v.page
