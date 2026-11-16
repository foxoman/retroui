# (included by photo.nim) A book's table of contents and index (retroui/booklists): Layout >
# Table of Contents takes the headings -- the text boxes in the paragraph styles picked, or
# the text at a size and up -- with their pages; Layout > Index takes the words asked for and
# finds their pages. Each is placed as a text box on a page of its own (or on this one), and
# keeps how it was made (`Layer.meta`): Update Table of Contents, Update Index make it again
# as the pages are now.

var
  listDlg: tuple[open, index: bool; title: string; styles: seq[string]; picked: seq[bool];
                 minSize: int; words: string; letters, newPage: bool]

proc bookStyles(b: Book): seq[string] =
  ## (the paragraph styles the book's text boxes are in)
  for i in 0 ..< b.pages.len:
    let was = b.isOpen(i)
    let d = b.doc(i)
    for L in d.layers:
      if L.isText and L.text.para.styleName.len > 0 and L.text.para.styleName notin result:
        result.add L.text.para.styleName
    if not was: b.park([curBook().page])

proc arabicBook(b: Book): bool =
  ## (a book set right to left: its lists so too)
  b.setup.binding == bindRight

proc startLists(index: bool) =
  let bw = curBook()
  if bw == nil:
    status = if index: tr("The index is for a book (File > New Book).")
             else: tr("The table of contents is for a book (File > New Book).")
    return
  endModes()
  let ar = arabicBook(bw.book)
  listDlg.open = true
  listDlg.index = index
  listDlg.title = if index: (if ar: "الفهرس" else: "Index") else: (if ar: "المحتويات" else: "Contents")
  listDlg.styles = bookStyles(bw.book)
  listDlg.picked = newSeq[bool](listDlg.styles.len)
  for i, s in listDlg.styles:
    let l = s.toLowerAscii
    listDlg.picked[i] = "head" in l or "chapter" in l or "title" in l or "عنوان" in s or "فصل" in s
  if listDlg.minSize <= 0: listDlg.minSize = max(12, int(round(bw.book.setup.dpi / 72 * 18)))
  listDlg.letters = true
  listDlg.newPage = true

proc listSettings(): JsonNode =
  var picked: seq[string]
  for i, s in listDlg.styles:
    if listDlg.picked[i]: picked.add s
  %*{(if listDlg.index: "index" else: "toc"): {"title": listDlg.title, "styles": picked,
      "minSize": listDlg.minSize, "words": listDlg.words, "letters": listDlg.letters}}

proc makeList(bw: BookWin; j: JsonNode; into: Layer = nil) =
  ## (the table of contents or the index made from `j`, placed -- or put in `into`, made again)
  let b = bw.book
  let index = j.hasKey("index")
  let o = j[if index: "index" else: "toc"]
  let m = b.marginBox(bw.page)
  var st = typeStyle
  st.size = max(8'f32, float32(b.setup.dpi / 72 * 11))
  let rtl = arabicBook(b)
  var t: TextData
  if index:
    var words: seq[string]
    for w in o{"words"}.getStr.splitLines:
      if w.strip.len > 0: words.add w.strip
    let ix = b.indexEntries(words, keep = [bw.page])
    t = indexText(ix, o{"title"}.getStr, st, m.w.float32, rtl, o{"letters"}.getBool(true))
  else:
    var styles: seq[string]
    for s in o{"styles"}.getElems: styles.add s.getStr
    let toc = b.tocEntries(styles, (if styles.len == 0: o{"minSize"}.getInt(24).float32 else: 0), keep = [bw.page])
    t = tocText(toc, o{"title"}.getStr, st, m.w.float32, rtl)
  t.x = m.x.float32
  t.y = m.y.float32
  t.boxH = min(t.boxH, m.h.float32)
  let d = bw.dw.doc
  if into != nil and into in d.layers:
    d.beginStep(if index: "Update Index" else: "Update Table of Contents")
    d.touchLayers()
    d.touch(into, d.bounds)
    t.x = into.text.x
    t.y = into.text.y
    t.boxW = into.text.boxW
    t.boxH = max(t.boxH, into.text.boxH)
    d.setText(into, t)
    d.endStep()
  else:
    d.beginStep(if index: "Index" else: "Table of Contents")
    d.touchLayers()
    let L = d.addTextLayer(t)
    L.name = if index: "Index" else: "Table of Contents"
    L.meta = $j
    d.cur = d.layers.find(L)
    d.endStep()
  d.markAll()
  status = if index: tr("The index: made from the book's pages as they are now")
           else: tr("The table of contents: made from the book's pages as they are now")

proc updateList(index: bool) =
  ## Update Table of Contents, Update Index: the one on this page (or on any page) made again.
  let bw = curBook()
  if bw == nil: return
  endModes()
  let key = if index: "{\"index\"" else: "{\"toc\""
  let b = bw.book
  for i in 0 ..< b.pages.len:
    let d = b.doc(i)
    for L in d.layers:
      if L.isText and L.meta.startsWith(key):
        if i != bw.page: bw.showPage(i)
        try: makeList(bw, parseJson(L.meta), L)
        except CatchableError: status = "Could not read how it was made"
        return
    if i != bw.page: b.park([bw.page])
  status = if index: tr("There is no index in this book yet.") else: tr("There is no table of contents in this book yet.")

proc listsCommand(name: string): bool =
  ## (Layout > Table of Contents, Index and their updates; true: done here)
  result = true
  case name
  of "Table of Contents...": startLists(false)
  of "Index...": startLists(true)
  of "Update Table of Contents": updateList(false)
  of "Update Index": updateList(true)
  else: result = false

proc listOk() =
  ## (OK: the list made, on a new page -- the first for contents, the last for an index -- or
  ## on this one)
  let bw = curBook()
  listDlg.open = false
  if bw == nil: return
  let j = listSettings()
  if listDlg.newPage:
    let at = if listDlg.index: bw.book.pages.len else: 0
    try:
      discard bw.book.insertPage(at)
      bw.showPage(at)
    except ValueError:
      status = tr("A book has ") & $MaxBookPages & tr(" pages at most.")
      return
  makeList(bw, j)

proc listsDialog() =
  if not listDlg.open: return
  let bw = curBook()
  if bw == nil:
    listDlg.open = false
    return
  var ok = false
  dialog(listDlg.open, (if listDlg.index: "Index" else: "Table of Contents"), 460):
    row([90, -1]):
      label "Title:"
      edit(listDlg.title)
    if listDlg.index:
      label "The words and phrases to find, one a line:"
      editArea(listDlg.words, lines = 8)
      checkbox("A heading for each first letter", listDlg.letters)
    else:
      if listDlg.styles.len > 0:
        label "The headings: text boxes in these paragraph styles (the first picked the highest level):"
        for i, s in listDlg.styles:
          checkbox(s, listDlg.picked[i])
      var any = false
      for p in listDlg.picked: any = any or p
      if not any:
        row([210, -1]):
          label "Or the text set at, and over:"
          spin(listDlg.minSize, 4, 2000, w = dp(70))
        label("(pixels: the headings by their size)", color = ui.theme.gray)
    checkbox("On a new page (else on this one)", listDlg.newPage)
    row:
      spring()
      if button("OK", isDefault = true, w = dp(80)): ok = true
      if button("Cancel", w = dp(80)): listDlg.open = false
  if ok: listOk()
