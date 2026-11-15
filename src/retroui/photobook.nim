## Books and magazines: a document of pages, for the image editor's engine
## (`retroui/photo`). A `Book` is its pages, each a `Doc` of the same size
## -- with all a document has: layers, type, shapes, pictures, effects --
## and what makes them a book:
##
## - **pages** added, taken out, moved and copied; single, or **facing**
##   (a left and a right page side by side), bound on the left (read left
##   to right) or on the right (Arabic, Hebrew: `bindRight`);
## - **margins** (inside and outside swap on facing pages) and the columns
##   new text boxes get;
## - **master pages**: what is on a master is on every page that has it
##   (a running head, a folio, a rule) -- a left and a right one for
##   facing pages; change the master and the pages follow;
## - **page numbers**: `<#>` in any text is the page's number and `<##>`
##   the number of pages; counted from `firstNumber`, started again where
##   a page says so (`restart`), written as digits, Arabic-Indic or
##   Persian digits, Roman numerals, letters or abjad;
## - **text that goes on from page to page**: a box takes what did not fit
##   a box of another page (`flowOnto`), and `autoflow` adds pages until a
##   long text is all set;
## - one file (".rpb": a zip of the pages as ".rpd" documents and a
##   description), and a PDF of all pages (`saveBookPdf`).
##
## A page's document is worked on as any document is. The book sees what
## changed by the document's `ver` (it goes up with `markDirty`,
## `markAll`, a step that ends: whatever draws it again); a change that
## draws nothing is told with `touch`.
##
## Only the pages looked at are in memory: the others are kept as files in
## a folder of the book's own (`park`), so a book may be long.
##
## ```nim
## var s = bookSetup(148, 210, dpi = 150, facing = true)       # A5
## let b = newBook(s, pages = 1)
## let m = b.addMaster("A")
## for side in [psLeft, psRight]:                              # a folio on each side
##   let md = b.masterDoc(m, side)
##   var t = newText("<#>", defaultStyle(), 0, 0)
##   let box = b.marginBox(side)
##   t.x = box.x.float32; t.y = float32(box.y + box.h + 10); t.boxW = box.w.float32; t.boxH = 40
##   t.para.align = if side == psLeft: textLeft else: textRight
##   discard md.addTextLayer(t)
## b.setMaster(0, m.id)
## let d = b.doc(0)                                            # the first page, to work on
## var story = newText(longText, defaultStyle(), 0, 0)
## let L = d.addTextLayer(b.boxed(story, 0))                   # in the page's margins
## echo b.autoflow(0, L), " pages added"
## b.saveBook("novel.rpb")
## b.saveBookPdf("novel.pdf", pdfPreset(ppPress))
## b.close()
## ```
##
## Developed by Sultan Al Isaiee @foxoman -- www.foxoman.net -- sultan@foxoman.net

import std/[os, json, tables, strutils, hashes]
import gfx, imaging, photo, photopdf, pdf, textengine, zip

type
  Binding* = enum
    ## The side a book is bound on.
    bindLeft = "Left to Right"       ## bound on the left: its first page is a right page
    bindRight = "Right to Left"      ## bound on the right (Arabic, Hebrew): its first page is a left page
  NumberStyle* = enum
    ## How page numbers are written.
    nsDigits = "1, 2, 3", nsArabicIndic = "١, ٢, ٣", nsPersian = "۱, ۲, ۳", nsRomanLower = "i, ii, iii",
    nsRomanUpper = "I, II, III", nsLetterLower = "a, b, c", nsLetterUpper = "A, B, C", nsAbjad = "أ, ب, ج"
  PageSide* = enum
    ## Where a page is in its spread.
    psSingle,                        ## pages that do not face each other
    psLeft, psRight
  BookSetup* = object
    ## What all pages of a book share (File > Document Setup).
    w*, h*: int                      ## a page's size in pixels
    dpi*: float                      ## pixels per inch
    facing*: bool                    ## facing pages: a left and a right one side by side
    binding*: Binding
    top*, bottom*: int               ## the margins, in pixels
    inside*, outside*: int           ## ... at the spine and at the outer edge (not facing: left, right)
    columns*: int                    ## the columns a new text box in the margins gets (0, 1: one)
    gutter*: int                     ## ... and the room between them
    firstNumber*: int                ## the first page's number (0: 1)
    numbers*: NumberStyle
    paper*: uint32                   ## the paper's color (0: white)
  BookPage* = ref object
    ## A page of a book (or a side of a master).
    id*: int                         ## who it is, wherever it is moved to
    master*: int                     ## its master (`Master.id`; 0: none)
    restart*: int                    ## > 0: page numbers start again here, at this number
    doc: Doc                         # (in memory; nil: parked in `file`)
    file: string
    dirty: bool                      # (changed since it was written to `file`)
    seenVer: int                     # (its document's `ver` when it was last looked at)
    settledVer: int                  # (... when what leaves it was last worked out; -1: not yet)
    fresh: bool                      # (just read back from its file)
    storedWith: Hash                 # (the number, master and incoming text its file was drawn with)
    applied: string                  # (the master, side and version its master layers are of)
    outText: Table[int, TextData]    # (what does not fit each box that goes on to another page)
    outSig: Table[int, Hash]
    ins: seq[(int, int)]             # (the boxes its boxes go on from: page id, layer uid)
    inSig: Hash                      # (... and what they gave when it was last drawn)
    flowsOut: bool
    thumb: Bitmap
    thumbStale: bool
  Master* = ref object
    ## A master page: what is on it is on every page that has it.
    id*: int
    name*: string                    ## "A"
    sides: array[2, BookPage]        # (left, right; not facing: the right one only)
    ver: int
  Book* = ref object
    setup*: BookSetup
    name*: string                    ## "Untitled Book"
    path*: string                    ## its file ("": not saved yet)
    modified*: bool                  ## changed since saved (see `changed`)
    pages*: seq[BookPage]            ## in order
    masters*: seq[Master]
    nextId: int
    dir: string                      # (where parked pages are)

const
  BookPapers* = [("A4", 210.0, 297.0), ("A5", 148.0, 210.0), ("A3", 297.0, 420.0), ("B5", 176.0, 250.0),
                 ("Letter", 215.9, 279.4), ("Legal", 215.9, 355.6), ("Tabloid", 279.4, 431.8),
                 ("Pocket Book", 110.0, 178.0), ("Square", 210.0, 210.0)]
    ## Page sizes to offer: a name, width and height in millimeters.
  MaxBookPages* = 2000

var bookCount = 0

# ---- numbers -----------------------------------------------------------------------------

proc roman(n: int): string =
  const parts = [(1000, "m"), (900, "cm"), (500, "d"), (400, "cd"), (100, "c"), (90, "xc"), (50, "l"),
                 (40, "xl"), (10, "x"), (9, "ix"), (5, "v"), (4, "iv"), (1, "i")]
  var n = n
  for (v, s) in parts:
    while n >= v:
      result.add s
      n -= v

proc formatNumber*(n: int; style: NumberStyle): string =
  ## A page number written in a style: 7 is "7", "٧", "vii", "g"... (Roman
  ## numerals and letters from 1 on; below 1, and Roman above 3999: digits.)
  const abjad = ["أ", "ب", "ج", "د", "ه", "و", "ز", "ح", "ط", "ي", "ك", "ل", "م", "ن", "س", "ع", "ف", "ص",
                 "ق", "ر", "ش", "ت", "ث", "خ", "ذ", "ض", "ظ", "غ"]
  # (what counts from 1 -- and Roman numerals, to 3999 -- written as digits past that)
  let asDigits = style in {nsRomanLower, nsRomanUpper, nsLetterLower, nsLetterUpper, nsAbjad} and
                 (n < 1 or (style in {nsRomanLower, nsRomanUpper} and n > 3999))
  case (if asDigits: nsDigits else: style)
  of nsDigits: result = $n
  of nsArabicIndic, nsPersian:
    let zero = if style == nsPersian: 0x06F0 else: 0x0660
    for c in $n:
      if c in '0' .. '9':
        let cp = zero + ord(c) - ord('0')
        result.add char(0xC0 or (cp shr 6))
        result.add char(0x80 or (cp and 0x3F))
      else: result.add c
  of nsRomanLower: result = roman(n)
  of nsRomanUpper: result = roman(n).toUpperAscii
  of nsLetterLower, nsLetterUpper:
    var k = n
    while k > 0:
      dec k
      result.insert($char(ord(if style == nsLetterUpper: 'A' else: 'a') + k mod 26), 0)
      k = k div 26
  of nsAbjad:
    # (past the 28 letters: the letter again, as often as it has come round)
    for _ in 0 .. (n - 1) div 28: result.add abjad[(n - 1) mod 28]

# ---- the setup ---------------------------------------------------------------------------

proc bookSetup*(wMm, hMm: float; dpi = 150.0; facing = true; binding = bindLeft; marginMm = 15.0): BookSetup =
  ## A setup from a page size in millimeters: the margins all `marginMm`
  ## (the inside one a third more on facing pages), one column.
  let k = dpi / 25.4
  let m = int(marginMm * k + 0.5)
  BookSetup(w: max(1, int(wMm * k + 0.5)), h: max(1, int(hMm * k + 0.5)), dpi: dpi, facing: facing,
            binding: binding, top: m, bottom: m, inside: (if facing: m * 4 div 3 else: m), outside: m,
            columns: 1, gutter: int(4.2 * k + 0.5), firstNumber: 1, paper: 0xFFFFFFFF'u32)

proc paperOf(s: BookSetup): uint32 = (if s.paper == 0: 0xFFFFFFFF'u32 else: s.paper or 0xFF000000'u32)

proc sideOf*(b: Book; i: int): PageSide =
  ## The side page `i` is on: the first page of a book bound on the left
  ## is a right page, alone; then left and right in turn (bound on the
  ## right: the other way round).
  if not b.setup.facing: psSingle
  elif (i mod 2 == 0) == (b.setup.binding == bindLeft): psRight
  else: psLeft

proc partner*(b: Book; i: int): int =
  ## The page that faces page `i` (-1: none -- the first page, a last page
  ## alone, pages that do not face).
  if not b.setup.facing or i <= 0 or i >= b.pages.len: return -1
  let j = if i mod 2 == 1: i + 1 else: i - 1
  if j < b.pages.len: j else: -1

proc spreadOf*(b: Book; i: int): seq[int] =
  ## The pages seen together with page `i`, from left to right.
  let j = b.partner(i)
  if j < 0: return @[i]
  if b.sideOf(i) == psLeft: @[i, j] else: @[j, i]

proc marginBox*(b: Book; side: PageSide): Rect =
  ## What is inside the margins of a page on that side.
  let s = b.setup
  let left = if side == psLeft: s.outside else: s.inside
  let right = if side == psLeft: s.inside else: s.outside
  rect(left, s.top, max(1, s.w - left - right), max(1, s.h - s.top - s.bottom))

proc marginBox*(b: Book; i: int): Rect = b.marginBox(b.sideOf(i))
  ## What is inside the margins of page `i`.

proc columnBoxes*(b: Book; i: int): seq[Rect] =
  ## The setup's columns in page `i`'s margins, from left to right.
  let m = b.marginBox(i)
  let n = max(1, b.setup.columns)
  let g = if n > 1: b.setup.gutter else: 0
  let cw = (m.w - g * (n - 1)) div n
  for c in 0 ..< n: result.add rect(m.x + c * (cw + g), m.y, cw, m.h)

proc label*(b: Book; i: int): string =
  ## Page `i`'s number as it is printed.
  var k = i
  while k > 0 and b.pages[k].restart <= 0: dec k
  let first = if k >= 0 and k < b.pages.len and b.pages[k].restart > 0: b.pages[k].restart
              else: (if b.setup.firstNumber == 0: 1 else: b.setup.firstNumber)
  formatNumber(first + i - k, b.setup.numbers)

proc pageOfId*(b: Book; id: int): BookPage =
  ## The page that is `id` (nil: none).
  for pg in b.pages:
    if pg.id == id: return pg

proc indexOfId*(b: Book; id: int): int =
  ## Where the page that is `id` is (-1: nowhere).
  for i, pg in b.pages:
    if pg.id == id: return i
  -1

proc masterOf*(b: Book; id: int): Master =
  ## The master that is `id` (nil: none).
  for m in b.masters:
    if m.id == id: return m

proc isOpen*(b: Book; i: int): bool = b.pages[i].doc != nil
  ## Page `i` is in memory.

# ---- pages in memory and parked ----------------------------------------------------------

proc folder(b: Book): string =
  if b.dir.len == 0:
    inc bookCount
    b.dir = (if scratchDir.len > 0: scratchDir else: getTempDir()) / ("retro-book-" & $getCurrentProcessId() & "-" & $bookCount)
    createDir(b.dir)
  b.dir

proc blank(b: Book; name: string; paper: bool): Doc =
  result = newDoc(b.setup.w, b.setup.h, (if paper: b.setup.paperOf else: 0'u32), dpi = b.setup.dpi, name = name)
  result.clearHistory()
  result.modified = false

proc newPage(b: Book): BookPage =
  inc b.nextId
  BookPage(id: b.nextId, dirty: true, thumbStale: true, settledVer: -1)

proc load(b: Book; pg: BookPage; name: string; paper = true): Doc =
  if pg.doc == nil:
    if pg.file.len > 0 and fileExists(pg.file):
      let d = loadRpd(pg.file)
      if d.w != b.setup.w or d.h != b.setup.h: raise newException(IOError, "a page of another size")
      d.clearHistory()
      d.modified = false
      d.path = ""
      pg.doc = d
      pg.dirty = false
      pg.fresh = true
    else:
      pg.doc = b.blank(name, paper)
      pg.dirty = true
    pg.doc.name = name
    pg.seenVer = pg.doc.ver
    pg.settledVer = -1               # (another document: its `ver` counts from the start again)
  pg.doc

proc noted(b: Book; pg: BookPage): bool =
  ## (what was done to a page's document since -- its `ver` went up, as
  ## it does when anything of it is drawn again: taken note of)
  if pg.doc != nil and pg.doc.ver != pg.seenVer:
    pg.seenVer = pg.doc.ver
    pg.dirty = true
    pg.thumbStale = true
    b.modified = true
    result = true

proc noteMasters(b: Book) =
  for m in b.masters:
    var any = false
    for s in m.sides:
      if s != nil and b.noted(s): any = true
    if any: inc m.ver

proc touch*(b: Book; i: int) =
  ## Page `i` was changed in a way that draws nothing again (a layer's
  ## setting): it is written out when it is parked, and the book has
  ## changes to save. What is drawn again is seen by itself.
  b.pages[i].dirty = true
  b.pages[i].thumbStale = true
  b.modified = true

proc changed*(b: Book): bool =
  ## The book has changes that are not saved.
  b.noteMasters()
  for pg in b.pages: discard b.noted(pg)
  b.modified

proc masterDoc*(b: Book; m: Master; side: PageSide): Doc =
  ## A master's page to work on: its left or its right one (pages that do
  ## not face have the right one only). `<#>` shows as "#" on it.
  let k = if side == psLeft and b.setup.facing: 0 else: 1
  if m.sides[k] == nil: m.sides[k] = b.newPage()
  result = b.load(m.sides[k], m.name & (if not b.setup.facing: "-Master" elif k == 0: "-Master, left"
                                         else: "-Master, right"), paper = false)
  result.pageLabel = "#"
  result.pageTotal = "#"

proc addMaster*(b: Book; name = ""): Master =
  ## A new, empty master ("A", "B"... when it is given no name).
  inc b.nextId
  result = Master(id: b.nextId, name: (if name.len > 0: name else: $char(ord('A') + b.masters.len mod 26)), ver: 1)
  b.masters.add result
  b.modified = true

proc removeMaster*(b: Book; id: int) =
  ## A master taken out; the pages that had it have none.
  for i in countdown(b.masters.high, 0):
    if b.masters[i].id == id:
      for s in b.masters[i].sides:
        if s != nil and s.file.len > 0: (try: removeFile(s.file) except OSError: discard)
      b.masters.delete(i)
  for pg in b.pages:
    if pg.master == id: pg.master = 0
  b.modified = true

proc setMaster*(b: Book; i, masterId: int) =
  ## Page `i` given a master (0: none); it shows when the page is next
  ## asked for (`doc`).
  if b.pages[i].master != masterId:
    b.pages[i].master = masterId
    b.modified = true

proc hasMarker(t: TextData): bool =
  for s in t.spans:
    if "<#" in s.text: return true

proc emptyText(): TextData =
  result.antialias = true

proc dress(b: Book; i: int) =
  ## (a page's document made what its place in the book makes it: its
  ## master's layers, its number, the text that comes to it)
  let pg = b.pages[i]
  let d = pg.doc
  b.noteMasters()
  discard b.noted(pg)
  let wasModified = d.modified
  # its master's layers, under its own
  let side = b.sideOf(i)
  let m = b.masterOf(pg.master)
  let want = if m == nil: "" else: $m.id & ":" & $ord(side) & ":" & $m.ver
  var relabel = false
  var remastered = false
  if pg.applied != want:
    var curL = if d.cur >= 0 and d.cur < d.layers.len: d.layers[d.cur] else: nil
    for k in countdown(d.layers.high, 0):
      if d.layers[k].fromMaster != 0: d.layers.delete(k)
    if m != nil:
      let md = b.masterDoc(m, side)
      var at = if d.layers.len > 0 and d.layers[0].background: 1 else: 0
      for L in md.layers:
        if L.background or L.px.len != d.w * d.h: continue
        # (a layer with nothing on it -- a new master's "Layer 1" -- stays there)
        if not L.isText and md.contentBounds(L).w <= 0: continue
        let c = cloneLayer(L)
        c.depth = 0
        c.fromMaster = m.id
        c.uid = 0
        c.flowFrom = 0
        c.flowPage = 0
        c.flowOut = false
        c.locked = true
        d.layers.insert(c, at)
        inc at
    if curL != nil and curL.fromMaster != 0: curL = nil
    d.cur = max(0, if curL != nil: d.layers.find(curL) else: d.layers.high)
    pg.applied = want
    pg.dirty = true
    pg.thumbStale = true
    relabel = true
    remastered = true
    d.clearHistory()
    d.markAll()
  # its number
  let lab = b.label(i)
  let total = formatNumber(b.pages.len, b.setup.numbers)
  if d.pageLabel != lab or d.pageTotal != total:
    d.pageLabel = lab
    d.pageTotal = total
    relabel = true
  # the text that comes to it from other pages
  pg.ins = @[]
  var sig: Hash
  for L in d.layers:
    if L.isText and L.flowFrom != 0 and L.flowPage != 0:
      pg.ins.add (L.flowPage, L.flowFrom)
      let src = b.pageOfId(L.flowPage)
      sig = sig !& (if src != nil and src.outText.hasKey(L.flowFrom): src.outSig.getOrDefault(L.flowFrom) else: Hash(0))
  pg.inSig = !$sig
  # (just read back, and its number, its master and the text that comes to it are what its
  # file was drawn with: its pixels are right as they are -- nothing is set again)
  let asStored = pg.fresh and not remastered and pg.file.len > 0 and
                 hash((lab, total, pg.applied, pg.inSig)) == pg.storedWith
  pg.fresh = false
  var redrawn = false
  for L in d.layers:
    if not L.isText or L.px.len != d.w * d.h: continue
    var again = relabel and (L.text.hasMarker or L.flowFrom != 0)
    if L.flowFrom != 0 and L.flowPage != 0:
      let src = b.pageOfId(L.flowPage)
      let has = src != nil and src.outText.hasKey(L.flowFrom)
      let hs = if has: src.outSig.getOrDefault(L.flowFrom) else: hash($emptyText().toJson)
      let uid = uidOf(L)
      if not d.flowIn.hasKey(uid) or hash($d.flowIn[uid].toJson) != hs:
        d.flowIn[uid] = if has: src.outText[L.flowFrom] else: emptyText()
        again = true
    if again and not asStored:
      d.drawText(L)
      redrawn = true
  if relabel and not asStored: d.rewrap()
  # (drawn again as its file has it -- a page read back, its number and the text that
  # comes to it what they were: nothing to write)
  if redrawn and (pg.file.len == 0 or hash((d.pageLabel, d.pageTotal, pg.applied, pg.inSig)) != pg.storedWith):
    pg.dirty = true
    pg.thumbStale = true
  # (the book's own doing, not the user's)
  pg.seenVer = d.ver
  d.modified = wasModified
  # (read back as it was parked: what leaves it is what was worked out then)
  if pg.settledVer == -1 and not pg.dirty and pg.file.len > 0: pg.settledVer = d.ver

proc doc*(b: Book; i: int): Doc =
  ## Page `i`'s document, to look at and work on: read back when it was
  ## parked, with its master's layers (locked, under its own), its page
  ## number and the text that comes to it from other pages. Raises
  ## `IOError` when it cannot be read back.
  discard b.load(b.pages[i], "Page " & $(i + 1))
  b.dress(i)
  b.pages[i].doc

proc settle*(b: Book; i: int): bool =
  ## What does not fit page `i`'s boxes that go on to other pages, worked
  ## out again (the page is opened when it is not). True when it changed:
  ## the pages that take it show it when they are next asked for.
  let pg = b.pages[i]
  let d = b.doc(i)
  var keep: seq[int]
  # (nothing of it drawn again since, the same boxes go on: as it was)
  var outs = 0
  var known = true
  for L in d.layers:
    if L.isText and L.flowOut:
      inc outs
      if not pg.outText.hasKey(L.uid): known = false
  if d.ver == pg.settledVer and known and outs == pg.outText.len: return false
  pg.flowsOut = false
  for L in d.layers:
    if not L.isText or not L.flowOut: continue
    pg.flowsOut = true
    let uid = uidOf(L)
    keep.add uid
    var st = d.effectiveText(L)
    st.clipOverflow = true
    let lay = layoutText(st)
    var rem = if lay.overflow >= 0: st.remainder(lay.overflow) else: st.remainder(int.high)
    rem.holes = @[]
    let h = hash($rem.toJson)
    if not pg.outSig.hasKey(uid) or pg.outSig[uid] != h:
      pg.outText[uid] = rem
      pg.outSig[uid] = h
      result = true
  var gone: seq[int]
  for uid in pg.outText.keys:
    if uid notin keep: gone.add uid
  for uid in gone:
    pg.outText.del uid
    pg.outSig.del uid
    result = true
  pg.settledVer = d.ver

proc stow(b: Book; pg: BookPage) =
  ## (a page in memory written to its file when it changed)
  if pg.doc == nil: return
  discard b.noted(pg)
  if pg.dirty or pg.file.len == 0 or not fileExists(pg.file):
    if pg.file.len == 0: pg.file = b.folder / ("p" & $pg.id & ".rpd")
    pg.doc.saveRpd(pg.file)
    pg.dirty = false
    pg.storedWith = hash((pg.doc.pageLabel, pg.doc.pageTotal, pg.applied, pg.inSig))

proc park*(b: Book; keep: openArray[int] = []; masters = true) =
  ## The pages in memory written to the book's folder and let go of, but
  ## for those at `keep` (the ones looked at); the masters too, unless
  ## `masters` is false (one is being worked on). Call it when another
  ## page is turned to: a document let go of must not be used again -- ask
  ## for it with `doc`.
  b.noteMasters()
  for i, pg in b.pages:
    if pg.doc == nil or i in keep: continue
    discard b.settle(i)
    b.stow(pg)
    pg.doc = nil
  if masters:
    for m in b.masters:
      for s in m.sides:
        if s != nil and s.doc != nil:
          b.stow(s)
          s.doc = nil

proc reflow*(b: Book; keep: openArray[int] = []) =
  ## The text that goes from page to page set again through the whole
  ## book, in order (pages no text comes to or leaves are not opened; the
  ## ones opened for it are parked again, but for those at `keep`). Before
  ## a book is saved or made a PDF, and after its text changed much.
  for pass in 0 ..< 3:
    var any = false
    for i, pg in b.pages:
      let was = pg.doc != nil
      if not was:
        # (parked: what leaves it was worked out then, and is still so
        # unless what comes to it is no longer what it was drawn with)
        if pg.ins.len == 0: continue
        var sig: Hash
        for (p, u) in pg.ins:
          let src = b.pageOfId(p)
          sig = sig !& (if src != nil and src.outText.hasKey(u): src.outSig.getOrDefault(u) else: Hash(0))
        if !$sig == pg.inSig: continue
      if b.settle(i): any = true
      if not was and i notin keep:
        b.stow(pg)
        pg.doc = nil
    if not any: break

# ---- pages added, taken out, moved --------------------------------------------------------

proc insertPage*(b: Book; at = -1; master = -1): BookPage =
  ## A new, empty page before page `at` (-1: at the end), with the master
  ## of the page before it (or `master`). Raises `ValueError` past
  ## `MaxBookPages`.
  if b.pages.len >= MaxBookPages: raise newException(ValueError, "too many pages")
  let k = if at < 0: b.pages.len else: clamp(at, 0, b.pages.len)
  result = b.newPage()
  result.master = if master >= 0: master elif k > 0: b.pages[k - 1].master else: 0
  b.pages.insert(result, k)
  b.modified = true

proc deletePage*(b: Book; i: int) =
  ## Page `i` taken out (a book keeps one page).
  if b.pages.len <= 1 or i < 0 or i >= b.pages.len: return
  let pg = b.pages[i]
  if pg.file.len > 0: (try: removeFile(pg.file) except OSError: discard)
  b.pages.delete(i)
  b.modified = true

proc movePage*(b: Book; i, to: int) =
  ## Page `i` moved to be page `to`.
  if i < 0 or i >= b.pages.len: return
  let k = clamp(to, 0, b.pages.high)
  if k == i: return
  let pg = b.pages[i]
  b.pages.delete(i)
  b.pages.insert(pg, k)
  b.modified = true

proc duplicatePage*(b: Book; i: int): BookPage =
  ## A copy of page `i` after it.
  if b.pages.len >= MaxBookPages: raise newException(ValueError, "too many pages")
  let pg = b.pages[i]
  discard b.doc(i)
  b.stow(pg)
  result = b.newPage()
  result.master = pg.master
  result.file = b.folder / ("p" & $result.id & ".rpd")
  copyFile(pg.file, result.file)
  result.dirty = false
  b.pages.insert(result, i + 1)
  b.modified = true

proc setSetup*(b: Book; s: BookSetup) =
  ## The book's setup changed: facing, binding, margins, columns and
  ## numbers; the page size stays (a book's pages are made at one size).
  var s = s
  s.w = b.setup.w
  s.h = b.setup.h
  s.dpi = b.setup.dpi
  b.setup = s
  b.modified = true

# ---- text from page to page ----------------------------------------------------------------

proc boxed*(b: Book; t: TextData; i: int): TextData =
  ## `t` as text in a box that fills page `i`'s margins, in the setup's
  ## columns.
  result = t
  let m = b.marginBox(i)
  result.x = m.x.float32
  result.y = m.y.float32
  result.boxW = m.w.float32
  result.boxH = m.h.float32
  result.path = @[]
  result.warp = TextWarp()
  result.fit = false
  if b.setup.columns > 1:
    result.columns = b.setup.columns
    result.gutter = b.setup.gutter.float32

proc follower*(b: Book; i: int; L: Layer): tuple[page: int; layer: Layer] =
  ## The box that takes what does not fit `L` of page `i`: its page and
  ## the layer (page -1: none). The page is opened.
  let pid = b.pages[i].id
  let uid = uidOf(L)
  for j, q in b.pages:
    if j == i: continue
    if q.doc == nil and (pid, uid) notin q.ins: continue
    let d = b.doc(j)
    for M in d.layers:
      if M.isText and M.flowPage == pid and M.flowFrom == uid: return (j, M)
  (-1, nil)

proc flowOnto*(b: Book; i: int; L: Layer; j: int): Layer =
  ## A new text box on page `j`, in its margins, that takes what does not
  ## fit the box `L` of page `i` (as `L` is set: its columns, its
  ## direction). Nil when `L` is not text in a box or `j` is page `i`.
  if i == j or not L.isText or L.text.boxW <= 0: return nil
  let d = b.doc(i)
  var u = b.boxed(L.text, j)
  u.spans = @[]
  u.holes = @[]
  if u.columns <= 1: u.columns = L.text.columns
  let d2 = b.doc(j)
  result = d2.addTextLayer(u)
  result.name = "Text (continued)"
  result.flowFrom = uidOf(L)
  result.flowPage = b.pages[i].id
  L.flowOut = true
  b.touch(i)
  b.touch(j)
  discard b.settle(i)
  b.dress(j)

proc unlinkPages*(b: Book; i: int; L: Layer) =
  ## The box `L` of page `i` no longer takes text from another page: it
  ## keeps what it showed as its own (and the box before it stops there).
  if L.flowPage == 0: return
  let d = b.doc(i)
  let shown = d.effectiveText(L)
  let src = b.indexOfId(L.flowPage)
  let from0 = L.flowFrom
  L.flowFrom = 0
  L.flowPage = 0
  L.text.spans = shown.spans
  d.flowIn.del L.uid
  d.drawText(L)
  b.touch(i)
  if src >= 0:
    let sd = b.doc(src)
    let S = sd.layerOfUid(from0)
    if S != nil:
      S.flowOut = false
      sd.drawText(S)
      b.touch(src)
    discard b.settle(src)

proc autoflow*(b: Book; i: int; L: Layer; most = 500; keep: openArray[int] = []): int =
  ## The text box `L` of page `i` goes on through the pages after it until
  ## all its text is set: into the boxes that already take it, then onto
  ## new pages (with page `i`'s master), each with a box in its margins.
  ## The number of pages added (`most` at most). The pages it opens are
  ## parked again, but for page `i` and those at `keep`.
  if not L.isText or L.text.boxW <= 0: return 0
  var at = i
  var box = L
  var visited = 0
  var left = int.high
  var stuck = 0
  while result < most and visited < MaxBookPages:
    inc visited
    box.flowOut = true
    discard b.settle(at)
    let rest = b.pages[at].outText.getOrDefault(uidOf(box), emptyText())
    var (j, next) = b.follower(at, box)
    let n = rest.plainText.strip.len
    # (a box that holds nothing of it -- a letter bigger than the page --
    # would go on for ever)
    if n >= left: inc stuck else: stuck = 0
    left = n
    if (n == 0 or stuck >= 2) and j < 0:
      # (all set: nothing goes on from here)
      box.flowOut = false
      discard b.settle(at)
      break
    if j < 0:
      if b.pages.len >= MaxBookPages: break
      j = at + 1
      discard b.insertPage(j, b.pages[at].master)
      next = b.flowOnto(at, box, j)
      inc result
      if next == nil: break
    else:
      discard b.doc(j)
    b.touch(at)
    if at != i and at notin keep:
      b.stow(b.pages[at])
      b.pages[at].doc = nil
    at = j
    box = next
  if at != i and at notin keep and b.pages[at].doc != nil:
    discard b.settle(at)
    b.stow(b.pages[at])
    b.pages[at].doc = nil

# ---- pictures of pages ---------------------------------------------------------------------

template quietly(b: Book; pg: BookPage; body: untyped) =
  ## (what only looks at a page's document may still count its `ver` up --
  ## making its picture, its PDF: that is not a change to the page)
  let was = pg.doc != nil and pg.doc.ver == pg.seenVer
  let wasModified = pg.doc != nil and pg.doc.modified
  body
  if was and pg.doc != nil:
    pg.seenVer = pg.doc.ver
    pg.doc.modified = wasModified

proc thumb*(b: Book; i: int; size = 160; fresh = true): Bitmap =
  ## A small picture of page `i` (for a list of pages): from its document
  ## when it is in memory, else from its file. Nil for a page never drawn.
  ## Not `fresh`: the one made last, as it is, when there is one (while a
  ## page is painted on, a list need not follow every frame).
  let pg = b.pages[i]
  if not fresh and pg.thumb != nil: return pg.thumb
  if pg.doc != nil: discard b.noted(pg)
  if pg.thumb != nil and not pg.thumbStale and max(pg.thumb.w, pg.thumb.h) >= min(size, max(b.setup.w, b.setup.h)):
    return pg.thumb
  if pg.doc != nil:
    b.quietly(pg): pg.thumb = pg.doc.toBitmap(b.setup.paperOf).thumbnail(size, size)
  elif pg.file.len > 0:
    let p = rpdPreview(pg.file, size, size)
    pg.thumb = if p != nil: p.thumbnail(size, size) else: nil
  else:
    pg.thumb = nil
  pg.thumbStale = false
  pg.thumb

proc pagePicture*(b: Book; i: int): Bitmap =
  ## Page `i` as a picture, on its paper (the page is opened, and stays so).
  let d = b.doc(i)
  b.quietly(b.pages[i]): result = d.toBitmap(b.setup.paperOf)

proc spreadPicture*(b: Book; i: int; keep: openArray[int] = []): Bitmap =
  ## The pages seen together with page `i` as one picture, side by side.
  let pages = b.spreadOf(i)
  result = newBitmap(b.setup.w * pages.len, b.setup.h)
  for k, p in pages:
    let was = b.pages[p].doc != nil
    let pic = b.pagePicture(p)
    for y in 0 ..< b.setup.h:
      copyMem(addr result.px[y * result.w + k * b.setup.w], addr pic.px[y * pic.w], b.setup.w * 4)
    if not was and p notin keep:
      b.stow(b.pages[p])
      b.pages[p].doc = nil

# ---- the book -------------------------------------------------------------------------------

proc newBook*(setup: BookSetup; pages = 1; name = "Untitled Book"): Book =
  ## A new book of empty pages. Raises `ValueError` when a page is too big.
  if not sizeOk(setup.w, setup.h): raise newException(ValueError, "the page is too big")
  result = Book(setup: setup, name: name)
  for _ in 0 ..< clamp(pages, 1, MaxBookPages): discard result.insertPage()
  result.modified = false

proc close*(b: Book) =
  ## The book let go of: its pages in memory, and its folder of parked
  ## pages (what was not saved is lost).
  for pg in b.pages: pg.doc = nil
  for m in b.masters:
    for s in m.sides:
      if s != nil: s.doc = nil
  if b.dir.len > 0:
    try: removeDir(b.dir) except OSError: discard
    b.dir = ""

proc hashOf(v: BiggestInt): Hash =
  ## (a mark kept in a book's file, read on any system: one written by a
  ## 64-bit program is cut to fit a 32-bit one's -- it then matches
  ## nothing, and the page is drawn again)
  cast[Hash](cast[uint](cast[uint64](v) and uint64(high(uint))))

proc setupJson(s: BookSetup): JsonNode =
  %*{"w": s.w, "h": s.h, "dpi": s.dpi, "facing": s.facing, "binding": ord(s.binding), "top": s.top,
     "bottom": s.bottom, "inside": s.inside, "outside": s.outside, "columns": s.columns, "gutter": s.gutter,
     "firstNumber": s.firstNumber, "numbers": ord(s.numbers), "paper": int64(s.paper)}

proc pageJson(pg: BookPage): JsonNode =
  result = %*{"id": pg.id, "master": pg.master, "restart": pg.restart, "applied": pg.applied,
              "storedWith": int64(pg.storedWith), "inSig": int64(pg.inSig)}
  if pg.outText.len > 0:
    var o = newJObject()
    for uid, t in pg.outText: o[$uid] = t.toJson
    result["out"] = o
  if pg.ins.len > 0:
    var a = newJArray()
    for (p, u) in pg.ins: a.add %*[p, u]
    result["ins"] = a

proc saveBook*(b: Book; path: string; keep: openArray[int] = []) =
  ## The book saved as one file (".rpb"): its text set through its pages
  ## first (`reflow`). The pages in memory stay so. Raises `IOError` /
  ## `OSError` when it cannot be written.
  b.reflow(keep)
  b.noteMasters()
  var z = newZipWriter()
  var pages = newJArray()
  var masters = newJArray()
  template put(pg: BookPage; name: string) =
    b.stow(pg)
    if pg.file.len > 0 and fileExists(pg.file): z.addFile(name, readFile(pg.file), compress = false)
  for i, pg in b.pages:
    if pg.doc != nil: discard b.settle(i)
    if pg.doc == nil and pg.file.len == 0: discard b.doc(i)       # (never drawn: an empty page)
    put(pg, "pages/" & $pg.id & ".rpd")
    pages.add pageJson(pg)
    let t = b.thumb(i, 200)
    if t != nil: z.addFile("thumbs/" & $pg.id & ".png", t.encodePng(), compress = false)
  for m in b.masters:
    var sides = newJArray()
    for k, s in m.sides:
      if s == nil:
        sides.add %0
      else:
        if s.doc == nil and s.file.len == 0: discard b.load(s, m.name, paper = false)
        put(s, "masters/" & $s.id & ".rpd")
        sides.add %s.id
    masters.add %*{"id": m.id, "name": m.name, "ver": m.ver, "sides": sides}
  let j = %*{"retroBook": 1, "name": b.name, "setup": setupJson(b.setup), "pages": pages, "masters": masters,
             "nextId": b.nextId}
  z.addFile("book.json", $j)
  let tmp = path & ".part"
  writeFile(tmp, z.finish())
  moveFile(tmp, path)
  b.path = path
  b.name = path.splitFile.name
  b.modified = false

proc loadBook*(path: string): Book =
  ## Opens a book (".rpb"). Raises `IOError` when it is not one or is
  ## damaged. Its pages are read as they are turned to.
  var files: Table[string, ZipEntry]
  try:
    for e in zipEntries(path): files[e.name] = e
  except CatchableError: raise newException(IOError, "not a Retro Photo book")
  if not files.hasKey("book.json"): raise newException(IOError, "not a Retro Photo book")
  let j = try: parseJson(readEntry(path, files["book.json"]))
          except CatchableError: raise newException(IOError, "damaged book")
  if j.kind != JObject or j{"retroBook"}.getInt(0) < 1: raise newException(IOError, "not a Retro Photo book")
  let sj = j{"setup"}
  var s = BookSetup(w: sj{"w"}.getInt(0), h: sj{"h"}.getInt(0), dpi: sj{"dpi"}.getFloat(72),
                    facing: sj{"facing"}.getBool(false),
                    binding: (if sj{"binding"}.getInt(0) == 1: bindRight else: bindLeft),
                    top: max(0, sj{"top"}.getInt(0)), bottom: max(0, sj{"bottom"}.getInt(0)),
                    inside: max(0, sj{"inside"}.getInt(0)), outside: max(0, sj{"outside"}.getInt(0)),
                    columns: clamp(sj{"columns"}.getInt(1), 1, 12), gutter: clamp(sj{"gutter"}.getInt(0), 0, 10_000),
                    firstNumber: sj{"firstNumber"}.getInt(1),
                    numbers: NumberStyle(clamp(sj{"numbers"}.getInt(0), 0, ord(high(NumberStyle)))),
                    paper: uint32(sj{"paper"}.getBiggestInt(0xFFFFFFFF'i64) and 0xFFFFFFFF'i64))
  if not sizeOk(s.w, s.h): raise newException(IOError, "damaged book")
  if s.dpi < 1 or s.dpi > 10_000: s.dpi = 72
  result = Book(setup: s, name: path.splitFile.name, path: path)
  let b = result
  var seen: seq[int]
  proc take(id: int; where: string): BookPage =
    # (a page of the file put into the book's folder; an id comes once)
    if id <= 0 or id in seen: return nil
    seen.add id
    result = BookPage(id: id, thumbStale: true, settledVer: -1)
    let name = where & "/" & $id & ".rpd"
    if files.hasKey(name):
      result.file = b.folder / ((if where == "pages": "p" else: "m") & $id & ".rpd")
      try: writeFile(result.file, readEntry(path, files[name]))
      except CatchableError:
        b.close()
        raise newException(IOError, "damaged book")
    b.nextId = max(b.nextId, id)
  for pj in j{"pages"}.getElems:
    if b.pages.len >= MaxBookPages: break
    let pg = take(pj{"id"}.getInt(0), "pages")
    if pg == nil: continue
    pg.master = pj{"master"}.getInt(0)
    pg.restart = pj{"restart"}.getInt(0)
    pg.applied = pj{"applied"}.getStr("")
    pg.storedWith = hashOf(pj{"storedWith"}.getBiggestInt(0))
    if pj{"out"} != nil and pj["out"].kind == JObject:
      for k, v in pj["out"]:
        let uid = try: parseInt(k) except ValueError: 0
        if uid != 0:
          pg.outText[uid] = textFrom(v)
          pg.outSig[uid] = hash($pg.outText[uid].toJson)
          pg.flowsOut = true
    for e in pj{"ins"}.getElems:
      if e.kind == JArray and e.len == 2: pg.ins.add (e[0].getInt(0), e[1].getInt(0))
    pg.inSig = hashOf(pj{"inSig"}.getBiggestInt(0))
    let tn = "thumbs/" & $pg.id & ".png"
    if files.hasKey(tn):
      try:
        pg.thumb = decodePng(readEntry(path, files[tn]))
        pg.thumbStale = pg.thumb == nil
      except CatchableError: pg.thumb = nil
    b.pages.add pg
  if b.pages.len == 0: discard b.insertPage()
  for mj in j{"masters"}.getElems:
    if b.masters.len >= 64: break
    let id = mj{"id"}.getInt(0)
    if id <= 0 or id in seen: continue
    seen.add id
    let m = Master(id: id, name: mj{"name"}.getStr("A"), ver: max(1, mj{"ver"}.getInt(1)))
    let sides = mj{"sides"}.getElems
    for k in 0 ..< min(2, sides.len):
      let sid = sides[k].getInt(0)
      if sid > 0: m.sides[k] = take(sid, "masters")
    b.nextId = max(b.nextId, id)
    b.masters.add m
  b.nextId = max(b.nextId, j{"nextId"}.getInt(0))
  for pg in b.pages:
    if pg.master != 0 and b.masterOf(pg.master) == nil: pg.master = 0
  b.modified = false

proc saveBookPdf*(b: Book; path: string; o: PdfOptions; keep: openArray[int] = []; first = 0; last = -1) =
  ## The book as a PDF, a page each, in order (pages `first` to `last`;
  ## -1: the last): type as type, shapes as shapes. The pages opened for
  ## it are parked again, but for those at `keep`.
  b.reflow(keep)
  let pdf = newPressPdf(o, b.name)
  let hi = if last < 0: b.pages.high else: min(last, b.pages.high)
  for i in max(0, first) .. hi:
    let was = b.pages[i].doc != nil
    let d = b.doc(i)
    b.quietly(b.pages[i]): pdf.addDocPage(d, o)
    if not was and i notin keep:
      b.stow(b.pages[i])
      b.pages[i].doc = nil
  pdf.save(path)
