# (included by photo.nim) Books and magazines (retroui/photobook): a
# document of pages in one window -- the page worked on is that window's
# document, the others are parked by the book. The Layout menu, the Pages
# panel, the New Book and Document Setup dialogs, master pages, page
# numbers, text that goes on from page to page, Text Wrap, the margins and
# the facing page drawn round the canvas; and the workspaces (Photo,
# Drawing, Layout) that set the panels and tools out for the work.

type BookWin = ref object
  book: Book
  dw: DocWin
  page: int                      ## the page shown
  master: int                    ## > 0: a master is worked on (its id), not a page
  side: PageSide                 ## ... its left or right page
  thumbAt: int                   ## (when the shown page's small picture was last made)

var
  books: seq[BookWin]
  showMargins = true             ## the margins and columns drawn over a page
  showFacing = true              ## the facing page drawn beside it
  showBaseline = false           ## the baseline grid drawn over a page
  bookDlg: tuple[open, setup: bool; paper, dpi, pages: int; w, h: int; facing: bool; binding: int;
                 top, bottom, inside, outside: int; columns, gutter: int; numbers, first: int;
                 grid: int] =
    (false, false, 0, 1, 8, 210, 297, true, 0, 15, 15, 20, 15, 1, 5, 0, 1, 0)
    ## New Book and Document Setup (sizes in millimeters)
  bookSavePick = false
  bookIdmlPick = false
  bookPdfPick = false
  bookPath = ""
  bookPdf: BookWin               ## the book the Save PDF dialog is for
  bookGo: tuple[open: bool; n: int; what: int]     ## Go to Page / Move Page / Start Numbering
  wrapDlg = false
  shapesDlg: tuple[open: bool; word: string; key: string; pics: seq[Bitmap]]

const bookDpis = [96, 150, 200, 300]

proc bookOf(dw: DocWin): BookWin =
  for bw in books:
    if bw.dw == dw: return bw

proc curBook(): BookWin = (if active != nil: bookOf(active) else: nil)

proc isBookWin(dw: DocWin): bool = bookOf(dw) != nil

proc endModes() =
  ## (what is under way on the page is done before it is left)
  if xf.on: finishTransform(true)
  if wm.kind != wkNone: modeFinish(true)
  if te.on: commitType()
  if drag.on: drag = Drag()

proc nameDoc(bw: BookWin) =
  let b = bw.book
  if bw.master > 0:
    let m = b.masterOf(bw.master)
    bw.dw.doc.name = b.name & ": " & (if m != nil: m.name else: "?") & "-Master" &
                     (if not b.setup.facing: "" elif bw.side == psLeft: " (left)" else: " (right)")
  else:
    bw.dw.doc.name = b.name & ": page " & b.label(bw.page) & " of " & $b.pages.len

proc nameOf(bw: BookWin): string = bw.dw.doc.name

proc showPage(bw: BookWin; i: int) =
  ## Page `i` of the book is the window's document; the others are parked.
  endModes()
  let b = bw.book
  let k = clamp(i, 0, b.pages.high)
  try:
    let d = b.doc(k)
    bw.master = 0
    bw.page = k
    bw.dw.doc = d
    b.park([k])
    bw.nameDoc()
    releaseGpuComposite()            # (the page before's layers: their textures let go)
  except CatchableError:
    status = "Could not read page " & $(k + 1) & ": " & getCurrentExceptionMsg()

proc editMaster(bw: BookWin; id: int; side: PageSide) =
  ## A master's page is the window's document, until a page is turned to.
  endModes()
  let b = bw.book
  let m = b.masterOf(id)
  if m == nil: return
  try:
    let d = b.masterDoc(m, side)
    bw.dw.doc = d
    bw.master = id
    bw.side = if b.setup.facing: side else: psRight
    b.park([], masters = false)
    bw.nameDoc()
    releaseGpuComposite()
    status = "The master " & m.name & ": what is on it is on every page that has it. <#> is the page number. " &
             "Layout > Back to the Page when done."
  except CatchableError:
    status = "Could not read the master: " & getCurrentExceptionMsg()

proc addBook(b: Book) =
  bookSmartFilter = smartFilterFn      # (a placed picture's part on the facing page: with its Smart Filters)
  let d = b.doc(0)
  addDoc(d)
  let bw = BookWin(book: b, dw: active, page: 0)
  books.add bw
  bw.nameDoc()
  active.fitWindow()
  showPanel("pages")

proc openBook(path: string) =
  for bw in books:
    if bw.book.path == path:
      bw.dw.showDoc()
      return
  try:
    beginBusy("Opening " & path.extractFilename)
    try: addBook(if path.toLowerAscii.endsWith(".idml"): readIdml(path) else: loadBook(path))
    finally: endBusy()
    rememberFile(path)
    status = ""
  except CatchableError:
    status = "Could not open " & path.extractFilename & ": " & getCurrentExceptionMsg()

proc keepOf(bw: BookWin): seq[int] = (if bw.master > 0: @[] else: @[bw.page])

proc writeBook(bw: BookWin; path: string) =
  endModes()
  try:
    beginBusy("Saving " & path.extractFilename)
    try: bw.book.saveBook(path, bw.keepOf)
    finally: endBusy()
    bw.nameDoc()
    rememberFile(path)
    status = "Saved " & path.extractFilename & " (" & $bw.book.pages.len & " pages)"
  except CatchableError:
    status = "Could not save " & path.extractFilename & ": " & getCurrentExceptionMsg()

proc bookSave(dw: DocWin; saveAs = false): bool =
  ## File > Save and Save As for a book's window (false: not a book).
  let bw = bookOf(dw)
  if bw == nil: return false
  result = true
  if bw.book.path.len > 0 and not saveAs:
    bw.writeBook(bw.book.path)
    return
  proc go() =
    let dir = if bw.book.path.len > 0 and dirExists(bw.book.path.parentDir): bw.book.path.parentDir
              else: picturesDir()
    bookPath = dir / bw.book.name & ".rpb"
    bookSavePick = true
  if storageFor(go): go()

proc bookPdfWrite(path: string; o: PdfOptions): bool =
  ## (the Save PDF dialog's OK, when it is for a book)
  let bw = bookPdf
  if bw == nil or bw notin books: return false
  bookPdf = nil
  endModes()
  bw.book.saveBookPdf(path, o, bw.keepOf)
  status = "Saved " & path.extractFilename & " (" & $bw.book.pages.len & " pages)"
  true

proc setupOf(): BookSetup =
  ## (the dialog's millimeters as a setup)
  let dpi = bookDpis[clamp(bookDlg.dpi, 0, bookDpis.high)].float
  let k = dpi / 25.4
  proc px(mm: int): int = int(mm.float * k + 0.5)
  BookSetup(w: max(8, px(bookDlg.w)), h: max(8, px(bookDlg.h)), dpi: dpi, facing: bookDlg.facing,
            binding: (if bookDlg.binding == 1: bindRight else: bindLeft), top: px(bookDlg.top),
            bottom: px(bookDlg.bottom), inside: px(bookDlg.inside), outside: px(bookDlg.outside),
            columns: clamp(bookDlg.columns, 1, 12), gutter: px(bookDlg.gutter),
            firstNumber: max(1, bookDlg.first), numbers: NumberStyle(clamp(bookDlg.numbers, 0, ord(high(NumberStyle)))),
            paper: 0xFFFFFFFF'u32, baseline: bookDlg.grid.float / 72 * dpi)

proc startBookSetup(bw: BookWin) =
  let s = bw.book.setup
  let k = 25.4 / s.dpi
  proc mm(px: int): int = int(px.float * k + 0.5)
  bookDlg.setup = true
  bookDlg.open = true
  bookDlg.w = mm(s.w)
  bookDlg.h = mm(s.h)
  bookDlg.dpi = max(0, bookDpis.find(int(s.dpi)))
  bookDlg.facing = s.facing
  bookDlg.binding = ord(s.binding)
  bookDlg.top = mm(s.top)
  bookDlg.bottom = mm(s.bottom)
  bookDlg.inside = mm(s.inside)
  bookDlg.outside = mm(s.outside)
  bookDlg.columns = max(1, s.columns)
  bookDlg.gutter = mm(s.gutter)
  bookDlg.numbers = ord(s.numbers)
  bookDlg.first = max(1, s.firstNumber)
  bookDlg.grid = int(s.baseline * 72 / s.dpi + 0.5)

proc bookGrid(dw: DocWin): tuple[step, start: float32] =
  ## (the baseline grid of the book page in `dw`: its step and first line; 0: none)
  let bw = bookOf(dw)
  if bw != nil and bw.book.setup.baseline >= 2:
    result = (bw.book.setup.baseline.float32, float32(bw.book.setup.top.float + bw.book.setup.baselineStart))

proc bookSnapLines(dw: DocWin): tuple[xs, ys: seq[float]] =
  ## (where boxes on the book page in `dw` snap: margins, columns, the baseline grid)
  let bw = bookOf(dw)
  if bw == nil: return
  let b = bw.book
  let side = if bw.master > 0: (if b.setup.facing: bw.side else: psSingle) else: b.sideOf(bw.page)
  b.snapLines(side)

proc bookFields(setup: bool; withPaper = true) =
  ## (the book's setup as fields: its size, resolution and pages when it is new -- with a
  ## list of page sizes unless `withPaper` is false -- then facing, binding, margins, columns,
  ## numbers)
  if not setup:
    if withPaper:
      var names: seq[string]
      for (n, w, h) in BookPapers: names.add n & "  (" & $int(w) & " x " & $int(h) & " mm)"
      names.add "Custom"
      row:
        label "Page size:"
        if combo(names, bookDlg.paper, w = dp(230)) and bookDlg.paper < BookPapers.len:
          bookDlg.w = int(BookPapers[bookDlg.paper][1] + 0.5)
          bookDlg.h = int(BookPapers[bookDlg.paper][2] + 0.5)
    row:
      label "Width:"
      if spin(bookDlg.w, 20, 2000, w = dp(70)): bookDlg.paper = BookPapers.len
      label "Height:"
      if spin(bookDlg.h, 20, 2000, w = dp(70)): bookDlg.paper = BookPapers.len
      label "mm"
    row:
      label "Resolution:"
      combo(["96 ppi (screen)", "150 ppi (proofs, e-books)", "200 ppi", "300 ppi (print)"], bookDlg.dpi, w = dp(190))
    row:
      label "Pages:"
      spin(bookDlg.pages, 1, 500, w = dp(70))
  row:
    checkbox("Facing pages", bookDlg.facing)
    label "Binding:"
    combo(["Left to right", "Right to left (Arabic)"], bookDlg.binding, w = dp(170))
  label("Margins (mm):", bold = true)
  row:
    label "Top:"
    spin(bookDlg.top, 0, 500, w = dp(56))
    label "Bottom:"
    spin(bookDlg.bottom, 0, 500, w = dp(56))
  row:
    label(if bookDlg.facing: "Inside:" else: "Left:")
    spin(bookDlg.inside, 0, 500, w = dp(56))
    label(if bookDlg.facing: "Outside:" else: "Right:")
    spin(bookDlg.outside, 0, 500, w = dp(56))
  row:
    label "Columns:"
    spin(bookDlg.columns, 1, 12, w = dp(56))
    label "Gutter:"
    spin(bookDlg.gutter, 0, 100, w = dp(56))
    label "mm"
  row:
    label "Baseline grid:"
    spin(bookDlg.grid, 0, 200, w = dp(56))
    label(if bookDlg.grid == 0: "pt (0: none)" else: "pt apart, from the top margin")
  row:
    label "Page numbers:"
    var styles: seq[string]
    for s in NumberStyle: styles.add $s
    combo(styles, bookDlg.numbers, w = dp(110))
    label "from"
    spin(bookDlg.first, 1, 99999, w = dp(64))

proc bookSetupDialog() =
  if not bookDlg.open: return
  let setup = bookDlg.setup
  dialog(bookDlg.open, (if setup: "Document Setup" else: "New Book"), 430):
    bookFields(setup)
    if not setup:
      let s = setupOf()
      let mb = s.w.float * s.h.float * 4 / 1e6
      paragraph("A page is " & $s.w & " x " & $s.h & " pixels: " & formatFloat(mb, ffDecimal, 0) &
                " MB a layer while it is worked on. Type and shapes are sharp in the PDF at any resolution; " &
                "pictures are as fine as the page.", color = ui.theme.gray)
    row:
      spring()
      if button("OK", isDefault = true, w = dp(80)):
        bookDlg.open = false
        let s = setupOf()
        if setup:
          let bw = curBook()
          if bw != nil:
            bw.book.setSetup(s)
            if bw.master == 0: bw.showPage(bw.page) else: bw.nameDoc()
        else:
          try:
            inc untitled
            addBook(newBook(s, bookDlg.pages, "Untitled Book " & $untitled))
          except CatchableError:
            status = "Could not make the book: " & getCurrentExceptionMsg()
      if button("Cancel", w = dp(80)): bookDlg.open = false

# ---- Text Wrap --------------------------------------------------------------------------------------------

proc setWrap(d: Doc; L: Layer; wrap, side, gap: int) =
  if L.wrap == wrap and L.wrapSide == side and L.wrapGap == gap: return
  d.beginStep("Text Wrap")
  d.touchLayers()
  L.wrap = wrap
  L.wrapSide = side
  L.wrapGap = gap
  d.endStep()
  d.markAll()
  let bw = curBook()
  if bw != nil and bw.master == 0: bw.book.touch(bw.page)

proc textWrapDialog() =
  if not wrapDlg: return
  let d = cur()
  if d == nil:
    wrapDlg = false
    return
  dialog(wrapDlg, "Text Wrap", 380):
    let L = d.current
    label("\"" & L.name & "\"", bold = true)
    var wrap = L.wrap
    var side = L.wrapSide
    var gap = L.wrapGap
    radio("No wrap: text runs over it", wrap, 0)
    radio("Round its box", wrap, 1)
    radio("Round its shape (what is drawn on it)", wrap, 2)
    radio("Jump over it: no text beside it", wrap, 3)
    row:
      label "Text goes:"
      combo(["On both sides", "At its left only", "At its right only", "On the side with more room"], side,
            w = dp(210), enabled = wrap in {1, 2})
    row:
      label "Stays away:"
      spin(gap, 0, 2000, w = dp(64))
      label "pixels"
    if L.isText:
      var ig = L.ignoreWrap
      if checkbox("This text ignores Text Wrap (a caption on a picture, a quote on its panel)", ig):
        d.beginStep("Ignore Text Wrap")
        d.touchLayers()
        L.ignoreWrap = ig
        d.endStep()
        d.drawText(L)
        d.markAll()
    paragraph("Text in a box keeps out of this layer. To wrap round a shape of your own, draw it with the Pen " &
              "or a shape tool on a layer, give that layer Round its shape, and set its Opacity to 0: it does " &
              "not show, the text still keeps out of it.", color = ui.theme.gray)
    d.setWrap(L, wrap, side, gap)
    row:
      spring()
      if button("Close", isDefault = true, w = dp(80)): wrapDlg = false

# ---- the shapes of a word (the font's alternates) ---------------------------------------------------------

proc wordForShapes(): string =
  ## (the letters selected; none: the word the caret is in, or the text's first)
  var s = ""
  if te.on:
    s = selectedText()
    if s.len == 0:
      let t = te.layer.text
      let a = t.wordLeft(te.caret)
      let b = t.wordRight(te.caret)
      if b > a: s = t.textSlice(a, b)
  if s.strip.len == 0:
    let L = typeTarget()
    if L != nil: s = L.text.plainText
  s = s.strip
  let cut = s.find({'\n', ' '})
  if cut > 0: s = s[0 ..< cut]
  var n = 0
  for r in s.runes:
    inc n
    if n > 24: break
    result.add r.toUTF8

proc shapePicture(word: string; st: CharStyle; w, h: int): Bitmap =
  var s = st
  s.size = h.float32 * 0.5
  s.color = 0xFF000000'u32
  s.baselineShift = 0
  var t = newText(word, s, w.float32 / 2, h.float32 * 0.66)
  t.para.align = textCenter
  result = newBitmap(w, h)
  try: result.px = renderText(t, w, h)
  except CatchableError: discard

proc wordShapesDialog() =
  if not shapesDlg.open: return
  dialog(shapesDlg.open, "Word Shapes", 420):
    let st = shownStyle()
    let word = shapesDlg.word
    let alts = alternatesFor(word, st)
    label(st.family & " " & st.style & ": \"" & word & "\"", color = ui.theme.gray)
    if alts.len == 0:
      paragraph("This font has no other shapes for these letters. Fonts made for it have them: stylistic " &
                "sets, swashes, and for Arabic the other forms of a letter and of its joins (try Amiri, " &
                "Aref Ruqaa, Noto Nastaliq Urdu: Type > Get Google Fonts).", color = ui.theme.gray)
    else:
      let key = word & "|" & st.family & "|" & st.style & "|" & st.features
      let pw = dp(180) * pxScale
      let ph = dp(44) * pxScale
      if shapesDlg.key != key:
        shapesDlg.key = key
        shapesDlg.pics = @[]
        for a in alts:
          var s2 = st
          s2.features = withFeature(st.features, a.tag, not a.on)
          shapesDlg.pics.add shapePicture(word, s2, pw, ph)
      paragraph("Click a shape to have it, again to go back. It is set on the letters selected (none: on " &
                "all the text).", color = ui.theme.gray)
      beginScroll(min(dp(300), alts.len * (dp(44) + dp(8)) + dp(8)), "wordshapes")
      for i, a in alts:
        row:
          let r = place(dp(180), dp(44))
          let id = idOf("wshape:" & a.tag)
          let hit = interact(id, r, focusable = false)
          fill(r, color(255, 255, 255))
          if i < shapesDlg.pics.len and shapesDlg.pics[i] != nil: drawBitmap(r, shapesDlg.pics[i])
          box(r, if hit.hover: ui.theme.select else: ui.theme.edge)
          label((if a.on: "On: " else: "") & a.name & "  (" & a.tag & ")")
          if hit.clicked:
            let tag = a.tag
            let v = not a.on
            applyChar("Word Shape", proc (x: var CharStyle) = x.features = withFeature(x.features, tag, v))
            shapesDlg.key = ""
      endScroll()
    row:
      spring()
      if button("Close", isDefault = true, w = dp(80)): shapesDlg.open = false

# ---- text from page to page -------------------------------------------------------------------------------

proc flowBox(bw: BookWin): Layer =
  ## (the text box the page-to-page commands are for: the current layer)
  let d = bw.dw.doc
  if bw.master > 0:
    status = "A master's text does not go on to other pages: do it on a page."
    return nil
  if not d.current.isText or d.current.text.boxW <= 0:
    status = "Pick a text box first (text typed in a box dragged with the Type tool)."
    return nil
  d.current

proc flowNext(bw: BookWin; auto: bool) =
  let L = bw.flowBox()
  if L == nil: return
  let b = bw.book
  endModes()
  try:
    beginBusy(if auto: "Setting the text through the pages" else: "Flowing the text on")
    try:
      if auto:
        let n = b.autoflow(bw.page, L, keep = [bw.page])
        status = if n > 0: $n & (if n == 1: " page" else: " pages") & " added: the text is all set (" &
                           $b.pages.len & " pages)"
                 else: "The text is all set: no page was needed"
      else:
        if bw.page == b.pages.high: discard b.insertPage(-1, b.pages[bw.page].master)
        let had = b.follower(bw.page, L)
        if had.page >= 0:
          status = "This box already goes on, on page " & $(had.page + 1)
        else:
          discard b.flowOnto(bw.page, L, bw.page + 1)
          status = "What does not fit goes on in a box on page " & $(bw.page + 2) & " (Shift+Page Down turns to it)"
        b.park([bw.page])
    finally: endBusy()
    bw.nameDoc()
  except CatchableError:
    status = "Could not flow the text: " & getCurrentExceptionMsg()

# ---- the commands -----------------------------------------------------------------------------------------

proc setWorkspace(kind: int)

proc bookCommand(name: string): bool =
  ## The Layout menu's commands and the book's own in File (true: done here).
  result = true
  let bw = curBook()
  let d = cur()
  template need(body: untyped) =
    if bw == nil: status = "This is for a book: File > New Book..."
    else: body
  case name
  of "New Book...": startNewBook()
  of "Save Book As...":
    need:
      discard bookSave(bw.dw, saveAs = true)
  of "Save Book as IDML...":
    need:
      proc go() =
        let dir = if bw.book.path.len > 0 and dirExists(bw.book.path.parentDir): bw.book.path.parentDir
                  else: picturesDir()
        bookPath = dir / bw.book.name & ".idml"
        bookIdmlPick = true
      if storageFor(go): go()
  of "Export Book as PDF...", "Export...", "Export Book...":
    need:
      let asBefore = name != "Export Book as PDF..."
      proc go() = startBookExport(exPdf, asBefore)
      if storageFor(go): go()
  of "Document Setup...":
    need:
      startBookSetup(bw)
  of "Add Page":
    need:
      let at = if bw.master > 0: bw.book.pages.len else: bw.page + 1
      try:
        discard bw.book.insertPage(at)
        bw.showPage(at)
      except ValueError: status = "A book has " & $MaxBookPages & " pages at most."
  of "Duplicate Page":
    need:
      if bw.master == 0:
        try:
          endModes()
          discard bw.book.duplicatePage(bw.page)
          bw.showPage(bw.page + 1)
        except CatchableError: status = "Could not copy the page: " & getCurrentExceptionMsg()
  of "Delete Page":
    need:
      if bw.master == 0 and bw.book.pages.len > 1:
        endModes()
        let i = bw.page
        # (the window is given another page before this one goes)
        bw.book.deletePage(i)
        bw.dw.doc = bw.book.doc(min(i, bw.book.pages.high))
        bw.showPage(min(i, bw.book.pages.high))
      else: status = "A book keeps one page."
  of "Next Page":
    need:
      bw.showPage(if bw.master > 0: bw.page else: bw.page + 1)
  of "Previous Page":
    need:
      bw.showPage(if bw.master > 0: bw.page else: bw.page - 1)
  of "First Page":
    need:
      bw.showPage(0)
  of "Last Page":
    need:
      bw.showPage(bw.book.pages.high)
  of "Back to the Page":
    need:
      bw.showPage(bw.page)
  of "Go to Page...":
    need:
      bookGo = (true, bw.page + 1, 0)
  of "Move Page...":
    need:
      bookGo = (true, bw.page + 1, 1)
  of "Start Page Numbers Again Here...":
    need:
      bookGo = (true, max(1, bw.book.pages[bw.page].restart), 2)
  of "Page Numbers Go On Here":
    need:
      bw.book.pages[bw.page].restart = 0
      bw.book.touch(bw.page)
      bw.showPage(bw.page)
  of "New Master":
    need:
      let m = bw.book.addMaster()
      bw.editMaster(m.id, psRight)
  of "Edit Master: Left Page", "Edit Master: Right Page", "Edit Master":
    need:
      var id = if bw.master > 0: bw.master else: bw.book.pages[bw.page].master
      if id == 0 and bw.book.masters.len > 0: id = bw.book.masters[0].id
      if id == 0: id = bw.book.addMaster().id
      bw.editMaster(id, if name.endsWith("Left Page"): psLeft else: psRight)
  of "No Master":
    need:
      if bw.master == 0:
        bw.book.setMaster(bw.page, 0)
        bw.showPage(bw.page)
  of "Delete Master":
    need:
      let id = if bw.master > 0: bw.master else: bw.book.pages[bw.page].master
      if id != 0:
        bw.book.removeMaster(id)
        bw.showPage(bw.page)
  of "Flow Onto the Next Page":
    need:
      bw.flowNext(false)
  of "Autoflow Through New Pages":
    need:
      bw.flowNext(true)
  of "Unlink From the Page Before":
    need:
      if bw.master == 0 and d.current.isText and d.current.flowPage != 0:
        endModes()
        bw.book.unlinkPages(bw.page, d.current)
        bw.book.park([bw.page])
      else: status = "This box does not go on from another page."
  of "Text Wrap...":
    if d != nil: wrapDlg = true
  of "Word Shapes...":
    shapesDlg.word = wordForShapes()
    if shapesDlg.word.len == 0: status = "Select a word (or pick a type layer) first."
    else:
      shapesDlg.key = ""
      shapesDlg.open = true
  of "Margins and Columns": showMargins = not showMargins
  of "Facing Page": showFacing = not showFacing
  of "Baseline Grid": showBaseline = not showBaseline
  of "Pages": togglePanel("pages")
  of "Workspace: Photo": setWorkspace(0)
  of "Workspace: Drawing": setWorkspace(1)
  of "Workspace: Layout": setWorkspace(2)
  else:
    if name.startsWith("Master: "):
      need:
        for m in bw.book.masters:
          if m.name == name["Master: ".len .. ^1] and bw.master == 0:
            bw.book.setMaster(bw.page, m.id)
            bw.showPage(bw.page)
    elif name.startsWith("Master for All Pages: "):
      need:
        for m in bw.book.masters:
          if m.name == name["Master for All Pages: ".len .. ^1]:
            for i in 0 ..< bw.book.pages.len: bw.book.setMaster(i, m.id)
            if bw.master == 0: bw.showPage(bw.page)
    else: result = false

proc layoutMenu() =
  ## The Layout menu's items (in both sets of menus).
  let bw = curBook()
  let d = cur()
  let some = d != nil
  let isBook = bw != nil
  let onPage = isBook and bw.master == 0
  let box = some and d.current.isText and d.current.text.boxW > 0
  ci("&New Book...", "New Book...")
  ci("Document &Setup...", "Document Setup...", enabled = isBook)
  sep()
  ci("Insert &Table...", "Insert Table...", enabled = some)
  ci("Insert C&hart...", "Insert Chart...", enabled = some)
  ci("Insert Ma&p...", "Insert Map...", enabled = some)
  ci("Edit Chart or Ma&p...", "Edit Chart or Map...", enabled = some and igOf(d) != nil)
  ci("Photo &Grid...", "Photo Grid...", enabled = some)
  sep()
  ci("Resi&ze for...", "Resize for...", enabled = some)
  ci("&Brand Kit...", "Brand Kit...")
  ci("&Recolor Design...", "Recolor Design...", enabled = some)
  ci("Chec&k Document...", "Check Document...", enabled = some)
  sep()
  ci("&Add Page", "Add Page", enabled = isBook)
  ci("&Duplicate Page", "Duplicate Page", enabled = onPage)
  ci("D&elete Page", "Delete Page", enabled = onPage and bw.book.pages.len > 1)
  ci("&Move Page...", "Move Page...", enabled = onPage and bw.book.pages.len > 1)
  sep()
  ci("Ne&xt Page", "Next Page", enabled = onPage and bw.page < bw.book.pages.high, shortcut = "Shift+PgDn")
  ci("&Previous Page", "Previous Page", enabled = onPage and bw.page > 0, shortcut = "Shift+PgUp")
  ci("&First Page", "First Page", enabled = isBook)
  ci("&Last Page", "Last Page", enabled = isBook)
  ci("&Go to Page...", "Go to Page...", enabled = isBook)
  sep()
  psSub "Ma&sters":
    ci("&New Master", "New Master", enabled = isBook)
    ci("Edit Master: &Left Page", "Edit Master: Left Page", enabled = isBook and bw.book.setup.facing)
    ci("Edit Master: &Right Page", "Edit Master: Right Page", enabled = isBook)
    ci("&Back to the Page", "Back to the Page", enabled = isBook and bw.master > 0)
    ci("&Delete Master", "Delete Master",
       enabled = isBook and (bw.master > 0 or bw.book.pages[bw.page].master != 0))
    sep()
    ci("No &Master on This Page", "No Master", enabled = onPage, checked = onPage and bw.book.pages[bw.page].master == 0)
    live:
      if isBook:
        for m in bw.book.masters:
          if menuItem("This Page: " & m.name, checked = onPage and bw.book.pages[bw.page].master == m.id, enabled = onPage):
            runCommand("Master: " & m.name)
        for m in bw.book.masters:
          if menuItem("All Pages: " & m.name): runCommand("Master for All Pages: " & m.name)
  psSub "Page N&umbers":
    ci("&Insert Page Number", "Insert Page Number", enabled = some)
    ci("Insert &Number of Pages", "Insert Number of Pages", enabled = some)
    sep()
    ci("&Start Again Here...", "Start Page Numbers Again Here...", enabled = onPage)
    ci("&Go On Here", "Page Numbers Go On Here", enabled = onPage and bw.book.pages[bw.page].restart > 0)
  sep()
  ci("Text &Wrap...", "Text Wrap...", enabled = some)
  ci("Flow &Onto the Next Page", "Flow Onto the Next Page", enabled = onPage and box)
  ci("Auto&flow Through New Pages", "Autoflow Through New Pages", enabled = onPage and box)
  ci("&Unlink From the Page Before", "Unlink From the Page Before", enabled = onPage and some and d.current.flowPage != 0)
  sep()
  ci("Mar&gins and Columns", "Margins and Columns", checked = showMargins)
  ci("Fa&cing Page", "Facing Page", checked = showFacing)
  ci("&Baseline Grid", "Baseline Grid", checked = showBaseline, enabled = isBook and bw.book.setup.baseline >= 2)
  ci("Pages Pane&l", "Pages", checked = panelShown("pages"))
  sep()
  ci("Save Boo&k As...", "Save Book As...", enabled = isBook)
  ci("&Export...", "Export Book...", enabled = isBook)
  ci("Export Book as &PDF...", "Export Book as PDF...", enabled = isBook)
  ci("Save Book as &IDML...", "Save Book as IDML...", enabled = isBook)

# ---- the Pages panel --------------------------------------------------------------------------------------

proc pageCell(bw: BookWin; i: int; w, h: int) =
  ## (a page's small picture, its number under it; a click turns to it)
  let b = bw.book
  let lh = lineHeight(style(size = 0.85))
  let r = place(w, h + lh + dp(2))
  let id = idOf("bookpage:" & $b.pages[i].id)
  let hit = interact(id, r, focusable = false)
  let pr = rect(r.x, r.y, w, h)
  let on = bw.master == 0 and bw.page == i
  fill(pr, color(255, 255, 255))
  # (the page worked on: its picture made again twice a second at most, not while the mouse is down)
  let fresh = not on or (not ui.mouseDown and ui.now - bw.thumbAt > 500)
  if on and fresh: bw.thumbAt = ui.now
  let t = (try: b.thumb(i, 200, fresh) except CatchableError: nil)
  if t != nil and t.w > 0: drawBitmap(pr, t)
  box(pr, (if on: ui.theme.select elif hit.hover: ui.theme.text else: ui.theme.edge), (if on: 2 else: 1))
  let st = style(size = 0.85, bold = on)
  let lab = b.label(i) & (if b.pages[i].master != 0 and b.masterOf(b.pages[i].master) != nil:
                            "  " & b.masterOf(b.pages[i].master).name else: "")
  text(r.x + (w - textWidth(lab, st)) div 2, r.y + h + dp(2), lab, ui.theme.text, st)
  if hit.clicked: bw.showPage(i)

proc pagesBody() =
  let bw = curBook()
  if bw == nil:
    paragraph("Pages of a book or magazine: single or facing, with master pages, page numbers and text " &
              "that goes on from page to page.", color = ui.theme.gray)
    if button("New Book...", w = dp(110)): runCommand("New Book...")
    return
  let b = bw.book
  row:
    if button("+", w = dp(26)): runCommand("Add Page")
    tooltip("Add a page after this one")
    if button("Copy", w = dp(48)): runCommand("Duplicate Page")
    if button("Delete", w = dp(56)): runCommand("Delete Page")
    if button("Setup", w = dp(52)): runCommand("Document Setup...")
  # the masters
  row:
    label "Masters:"
    for m in b.masters:
      if button(m.name & (if bw.master == m.id: " *" else: ""), w = dp(30)):
        bw.editMaster(m.id, if b.setup.facing and bw.master == m.id and bw.side == psRight: psLeft else: psRight)
      tooltip("Work on the master " & m.name & " (again: its other page)")
    if button("New", w = dp(40)): runCommand("New Master")
  if bw.master > 0:
    row:
      label(nameOf(bw), color = ui.theme.gray)
      if button("Back", w = dp(48)): runCommand("Back to the Page")
  # the pages, as they lie: spreads side by side
  let facing = b.setup.facing
  beginScroll(max(dp(80), remainingH() - dp(4)), "bookpages", framed = false)
  # (two pages side by side in the room the list itself has)
  let cw = clamp((available() - 3 * Gap) div (if facing: 2 else: 1), dp(36), dp(110))
  let ch = max(dp(20), cw * b.setup.h div max(1, b.setup.w))
  var i = 0
  while i < b.pages.len:
    let sp = b.spreadOf(i)
    row:
      if facing and sp.len == 1:
        # (a page alone keeps its side)
        if b.sideOf(sp[0]) == psRight:
          discard place(cw, ch)
          bw.pageCell(sp[0], cw, ch)
        else:
          bw.pageCell(sp[0], cw, ch)
      else:
        for p in sp: bw.pageCell(p, cw, ch)
    space(dp(4))
    i += sp.len
  endScroll()

# ---- round the canvas -------------------------------------------------------------------------------------

proc ghostRect(bw: BookWin): tuple[page: int; r: Rect] =
  ## (where the facing page is drawn: beside the page shown)
  result.page = -1
  if not showFacing or bw.master > 0: return
  let b = bw.book
  let j = b.partner(bw.page)
  if j < 0: return
  let d = bw.dw.doc
  let v = bw.dw.view
  let left = b.spreadOf(bw.page)[0] == j
  let x0 = if left: -d.w.float else: d.w.float
  let (ax, ay) = v.toScreen(d, x0, 0)
  let (bx, by) = v.toScreen(d, x0 + d.w.float, d.h.float)
  (j, rect(ax, ay, bx - ax, by - ay))

proc bookGhostPress(dw: DocWin): bool =
  ## A press on the facing page turns to it.
  let bw = bookOf(dw)
  if bw == nil or dw.view.angle != 0: return false
  let g = bw.ghostRect()
  if g.page >= 0 and mouseIn(g.r):
    bw.showPage(g.page)
    return true

proc bookOverlay(dw: DocWin) =
  ## The margins and columns over a page, the facing page beside it.
  let bw = bookOf(dw)
  if bw == nil or dw.view.angle != 0: return
  let b = bw.book
  let d = dw.doc
  let v = dw.view
  let side = if bw.master > 0: (if b.setup.facing: bw.side else: psSingle) else: b.sideOf(bw.page)
  if showMargins:
    let m = b.marginBox(side)
    let (ax, ay) = v.toScreen(d, m.x.float, m.y.float)
    let (bx, by) = v.toScreen(d, float(m.x + m.w), float(m.y + m.h))
    box(rect(ax, ay, max(1, bx - ax), max(1, by - ay)), color(230, 60, 200))
    let n = max(1, b.setup.columns)
    if n > 1:
      let cwid = (m.w - b.setup.gutter * (n - 1)) div n
      for c in 1 ..< n:
        for x in [m.x + c * (cwid + b.setup.gutter) - b.setup.gutter, m.x + c * (cwid + b.setup.gutter)]:
          let (sx, _) = v.toScreen(d, x.float, 0)
          line(sx, ay, sx, by, color(150, 90, 230))
  if showBaseline:
    let m = b.marginBox(side)
    let (ax, _) = v.toScreen(d, m.x.float, 0)
    let (bx, _) = v.toScreen(d, float(m.x + m.w), 0)
    var last = -100
    for y in b.gridLines:
      let (_, sy) = v.toScreen(d, 0, y)
      if sy - last < dp(3): continue          # (too close together to show at this zoom)
      last = sy
      line(ax, sy, bx, sy, color(120, 190, 235))
  let g = bw.ghostRect()
  if g.page >= 0 and g.r.w > 4:
    let t = (try: b.thumb(g.page, 1024) except CatchableError: nil)
    fill(g.r, color(255, 255, 255))
    if t != nil and t.w > 0: drawBitmap(g.r, t)
    box(g.r, ui.theme.shadow)
    let st = style(size = 0.85)
    let lab = "Page " & b.label(g.page) & ": click to turn to it"
    if g.r.w > textWidth(lab, st) + dp(8):
      text(g.r.x + dp(4), g.r.y + g.r.h + dp(2), lab, ui.theme.text, st)

# ---- the workspaces ---------------------------------------------------------------------------------------

proc setWorkspace(kind: int) =
  ## The panels and the toolbar set out for the work: photos (all of it,
  ## as Essentials), drawing (vectors: the Pen, shapes, paths, type), or
  ## layout (pages, type, styles, wrap).
  dock = newDock()
  template grp(col: int; share: int; ks: openArray[string]) =
    var ps: seq[DockPanel]
    for k in ks: ps.add pdef(k)
    discard dock.addGroup(col, ps, share)
  var shown: seq[string]
  discard dock.addColumn()
  case kind
  of 1:
    grp(0, 24, ["color", "swatches", "gradients"])
    grp(0, 30, ["properties", "shapes", "styles"])
    grp(0, 46, ["layers", "paths"])
    discard dock.addColumn(iconic = true)
    grp(1, 100, ["character", "paragraph", "glyphs"])
    grp(1, 100, ["brushes", "brushsettings"])
    grp(1, 100, ["history", "navigator"])
    grp(1, 100, ["patterns", "libraries"])
    shown = @["color", "swatches", "gradients", "properties", "shapes", "styles", "layers", "paths", "character",
              "paragraph", "glyphs", "brushes", "brushsettings", "history", "navigator", "patterns", "libraries"]
    prefs.toolHidden = "Healing,Stamp,History Brush,Blur,Dodge,Frame"
  of 2:
    grp(0, 34, ["pages", "layers"])
    grp(0, 36, ["character", "paragraph", "opentype"])
    grp(0, 30, ["charstyles", "parastyles", "swatches"])
    discard dock.addColumn(iconic = true)
    grp(1, 100, ["properties", "glyphs"])
    grp(1, 100, ["color", "gradients"])
    grp(1, 100, ["history", "navigator"])
    grp(1, 100, ["libraries", "shapes", "styles"])
    shown = @["pages", "layers", "character", "paragraph", "opentype", "charstyles", "parastyles", "swatches",
              "properties", "glyphs", "color", "gradients", "history", "navigator", "libraries", "shapes", "styles"]
    prefs.toolHidden = "Lasso,Selection,Healing,Brush,Stamp,History Brush,Eraser,Blur,Dodge"
    for dwin in docs: dwin.view.rulers = true
  else:
    defaultDock()
    prefs.toolHidden = ""
    palettesPlaced = false
    status = "The Photo workspace: every panel and tool"
    return
  for (k, t, ic) in panelList:
    if k notin shown: dock.closed.add (pdef(k), 0, 0)
  palettesPlaced = false
  status = if kind == 1: "The Drawing workspace: the Pen, shapes, paths and type (the retouching tools are under \"...\")"
           else: "The Layout workspace: pages, type and styles (the painting tools are under \"...\"; " &
                 "File > New Book for a document of pages)"

# ---- each frame -------------------------------------------------------------------------------------------

proc bookFrame() =
  ## The books whose windows are gone let go of; a book's changes shown as
  ## its window's; Shift+Page Down and Up turn the pages.
  for i in countdown(books.high, 0):
    let bw = books[i]
    if bw.dw notin docs:
      bw.book.close()
      books.delete(i)
      continue
    if bw.dw.doc != nil and not bw.dw.doc.stepOpen:
      bw.dw.doc.modified = bw.book.changed
  let bw = curBook()
  # (the spread kept one: what reaches past the spine goes on, on the facing page -- looked
  # at when nothing is under way)
  if bw != nil and bw.master == 0 and not ui.mouseDown and not te.on and not xf.on and wm.kind == wkNone and
     not drag.on and not bw.dw.doc.stepOpen:
    try:
      let r = bw.book.syncSpread(bw.page)
      if r.moved > 0:
        let j = bw.book.partner(bw.page)
        status = (if r.moved == 1: "The object is" else: $r.moved & " objects are") & " on page " &
                 bw.book.label(j) & " now (wholly past the spine): click that page to work on " &
                 (if r.moved == 1: "it" else: "them")
      elif r.changed:
        status = "What reaches past the spine goes on, on the facing page"
    except CatchableError:
      status = "Could not read the facing page: " & getCurrentExceptionMsg()
  if bw != nil and bw.master == 0 and canInput() and not ui.keyUsed and not te.on and
     ShiftPressed in ui.mods and CtrlPressed notin ui.mods:
    if ui.key == KeyPageDown and bw.page < bw.book.pages.high:
      ui.keyUsed = true
      bw.showPage(bw.page + 1)
    elif ui.key == KeyPageUp and bw.page > 0:
      ui.keyUsed = true
      bw.showPage(bw.page - 1)
  let note = systemFilesNote()
  if note.len > 0: status = note

proc bookDialogs() =
  bookSetupDialog()
  bookExportDialog()
  textWrapDialog()
  wordShapesDialog()
  if filePicker(bookSavePick, bookPath, fmSave, ["*.rpb"], "Save Book As"):
    let bw = curBook()
    if bw != nil:
      var p = bookPath
      if p.splitFile.ext.toLowerAscii != ".rpb": p.add ".rpb"
      bw.writeBook(p)
  if filePicker(bookIdmlPick, bookPath, fmSave, ["*.idml"], "Save Book as IDML"):
    let bw = curBook()
    if bw != nil:
      var p = bookPath
      if p.splitFile.ext.toLowerAscii != ".idml": p.add ".idml"
      try:
        beginBusy("Saving " & p.extractFilename)
        try: bw.book.saveBookIdml(p, bw.keepOf)
        finally: endBusy()
        rememberFile(p)
        status = "Saved " & p.extractFilename & " (IDML: the layout program opens it; pictures in " &
                 p.changeFileExt("").extractFilename & "-links)"
      except CatchableError: status = "Could not save " & p.extractFilename & ": " & getCurrentExceptionMsg()
  if filePicker(bookPdfPick, bookPath, fmSave, ["*.pdf"], "Export Book as PDF"):
    let bw = curBook()
    if bw != nil:
      var p = bookPath
      if p.splitFile.ext.toLowerAscii != ".pdf": p.add ".pdf"
      bookPdf = bw
      startPdfOptions(@[bw.dw.doc], p)
      pdfDlg.o.title = bw.book.name
  if bookGo.open:
    let bw = curBook()
    if bw == nil:
      bookGo.open = false
      return
    let title = ["Go to Page", "Move Page", "Start Page Numbers Again"][clamp(bookGo.what, 0, 2)]
    dialog(bookGo.open, title, 300):
      row:
        label(["Page (1 to " & $bw.book.pages.len & "):", "To be page:", "This page's number:"][clamp(bookGo.what, 0, 2)])
        spin(bookGo.n, 1, (if bookGo.what == 2: 99999 else: bw.book.pages.len), w = dp(72))
      row:
        spring()
        if button("OK", isDefault = true, w = dp(80)):
          bookGo.open = false
          case bookGo.what
          of 0: bw.showPage(bookGo.n - 1)
          of 1:
            endModes()
            bw.book.movePage(bw.page, bookGo.n - 1)
            bw.showPage(bookGo.n - 1)
          else:
            bw.book.pages[bw.page].restart = bookGo.n
            bw.book.touch(bw.page)
            bw.showPage(bw.page)
        if button("Cancel", w = dp(80)): bookGo.open = false
