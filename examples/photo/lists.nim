# (included by photo.nim) A book's table of contents and index (retroui/booklists): Layout >
# Table of Contents takes the headings -- the text boxes in the paragraph styles picked, or
# the text at a size and up -- with their pages; Layout > Index takes the words asked for and
# finds their pages. Each is placed as a text box on a page of its own (or on this one), and
# keeps how it was made (`Layer.meta`): Update Table of Contents, Update Index make it again
# as the pages are now. A table of contents as the layout program sets it: the page number
# after the entry, before it or none, what is between them, the leader, the entries sorted, a
# paragraph style's letters for each level, text on hidden layers, PDF bookmarks for its
# entries, the one there is replaced; its settings kept by name in the book (TOC Styles).

var
  listDlg: tuple[open, index: bool; title: string; styles: seq[string]; picked: seq[bool];
                 minSize: int; words: string; letters, newPage: bool; numbers, leader: int; between: string;
                 sorted, hidden, bookmarks, replace: bool; levelStyles: seq[string]; tocStyle: int;
                 saveName: string]

proc bookStyles(b: Book): seq[string] =
  ## (the paragraph styles the book's text boxes are in)
  for i in 0 ..< b.pages.len:
    let was = b.isOpen(i)
    let d = b.doc(i)
    for L in d.layers:
      if not L.isText: continue
      for f in @[L.text.para] & L.text.paraFmts:
        if f.styleName.len > 0 and f.styleName notin result: result.add f.styleName
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
  listDlg.replace = true
  listDlg.tocStyle = 0
  listDlg.levelStyles = newSeq[string](listDlg.styles.len)

const tocLeaders = [". ", "- ", "_", " "]   ## (dots, dashes, a line, none)

proc listSettings(): JsonNode =
  var picked, looks: seq[string]
  for i, s in listDlg.styles:
    if listDlg.picked[i]:
      picked.add s
      looks.add (if i < listDlg.levelStyles.len: listDlg.levelStyles[i] else: "")
  result = %*{(if listDlg.index: "index" else: "toc"): {"title": listDlg.title, "styles": picked,
      "minSize": listDlg.minSize, "words": listDlg.words, "letters": listDlg.letters}}
  if not listDlg.index:
    let o = result["toc"]
    o["numbers"] = %listDlg.numbers
    o["between"] = %listDlg.between
    o["leader"] = %tocLeaders[clamp(listDlg.leader, 0, tocLeaders.high)]
    o["sorted"] = %listDlg.sorted
    o["hidden"] = %listDlg.hidden
    o["bookmarks"] = %listDlg.bookmarks
    o["levelStyles"] = %looks

proc takeTocStyle(j: JsonNode) =
  ## (a kept TOC Style's settings into the dialog)
  let o = j{"toc"}
  if o == nil: return
  listDlg.title = o{"title"}.getStr(listDlg.title)
  var want: seq[string]
  for s in o{"styles"}.getElems: want.add s.getStr
  var looks: seq[string]
  for s in o{"levelStyles"}.getElems: looks.add s.getStr
  for i, s in listDlg.styles:
    let k = want.find(s)
    listDlg.picked[i] = k >= 0
    listDlg.levelStyles[i] = if k >= 0 and k < looks.len: looks[k] else: ""
  listDlg.minSize = o{"minSize"}.getInt(listDlg.minSize)
  listDlg.numbers = clamp(o{"numbers"}.getInt(0), 0, 2)
  listDlg.between = o{"between"}.getStr
  listDlg.leader = max(0, tocLeaders.find(o{"leader"}.getStr(". ")))
  listDlg.sorted = o{"sorted"}.getBool
  listDlg.hidden = o{"hidden"}.getBool
  listDlg.bookmarks = o{"bookmarks"}.getBool

proc makeList(bw: BookWin; j: JsonNode; into: Layer = nil) =
  ## (the table of contents or the index made from `j`, placed -- or put in `into`, made again)
  let b = bw.book
  let index = j.hasKey("index")
  let o = j[if index: "index" else: "toc"]
  let m = b.marginBox(bw.page)
  var st = typeStyle.scaledStyle(typeScale())
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
    let toc = b.tocEntries(styles, (if styles.len == 0: o{"minSize"}.getInt(24).float32 else: 0), keep = [bw.page],
                           hidden = o{"hidden"}.getBool)
    # (each level in a paragraph style's letters -- the page's styles --, at the list's size)
    var opts = TocOptions(numbers: TocNumbers(clamp(o{"numbers"}.getInt(0), 0, 2)), between: o{"between"}.getStr,
                          leader: o{"leader"}.getStr, sorted: o{"sorted"}.getBool)
    let page = bw.dw.doc
    for ls in o{"levelStyles"}.getElems:
      var look = CharStyle()
      for def in page.paraStyles:
        if def.name == ls.getStr and ls.getStr.len > 0:
          look = def.char
          if look.size <= 0: look.size = st.size
      opts.levelStyles.add look
    t = tocText(toc, o{"title"}.getStr, st, m.w.float32, rtl, opts)
    if o{"bookmarks"}.getBool:
      # (PDF bookmarks: each entry one, on its page -- those an earlier table made taken away first)
      var made = newJArray()
      if into != nil:
        try:
          for e in parseJson(into.meta){"toc"}{"made"}.getElems:
            if e.kind == JArray and e.len == 2 and e[0].getInt(-1) in 0 .. b.pages.high:
              let pd = b.doc(e[0].getInt)
              for k in countdown(pd.bookmarks.high, 0):
                if pd.bookmarks[k].title == e[1].getStr and pd.bookmarks[k].dest.len == 0: pd.bookmarks.delete(k)
        except CatchableError: discard
      for e in toc:
        let pd = b.doc(e.page)
        pd.bookmarks.add DocBookmark(title: e.text, level: e.level)
        b.touch(e.page)
        made.add %*[e.page, e.text]
      o["made"] = made
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
    into.meta = $j
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
  if not listDlg.index and listDlg.replace:
    # (Replace Existing Table of Contents: the one there is, made again as this says)
    let b = bw.book
    for i in 0 ..< b.pages.len:
      let d = b.doc(i)
      for L in d.layers:
        if L.isText and L.meta.startsWith("{\"toc\""):
          if i != bw.page: bw.showPage(i)
          makeList(bw, j, L)
          return
      if i != bw.page: b.park([bw.page])
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
      let b = bw.book
      row([90, -1, 90]):
        label "TOC Style:"
        var names = @[tr("[Default]")]
        for (n, _) in b.tocStyles: names.add n
        if combo(names, listDlg.tocStyle, w = dp(200)) and listDlg.tocStyle > 0:
          try: takeTocStyle(parseJson(b.tocStyles[listDlg.tocStyle - 1].settings))
          except CatchableError: discard
      if listDlg.styles.len > 0:
        label "The headings: text boxes in these paragraph styles (the first picked the highest level), each in:"
        var looks = @[tr("[As the list]")]
        for def in bw.dw.doc.paraStyles: looks.add def.name
        for i, s in listDlg.styles:
          row([200, -1]):
            checkbox(s, listDlg.picked[i])
            if listDlg.picked[i]:
              var k = max(0, looks.find(listDlg.levelStyles[i]))
              if combo(looks, k, w = dp(180)): listDlg.levelStyles[i] = if k <= 0: "" else: looks[k]
      var any = false
      for p in listDlg.picked: any = any or p
      if not any:
        row([210, -1]):
          label "Or the text set at, and over:"
          let (minSet, ms) = cur().typeField(float32(listDlg.minSize), dp(70), "tocmin", 1, 2000, size = true)
          if minSet: listDlg.minSize = max(4, int(round(ms)))
        label("(the headings by their size)", color = ui.theme.gray)
      group("Page Number"):
        row([120, -1]):
          label ""
          var nk = listDlg.numbers
          if combo([tr("After Entry"), tr("Before Entry"), tr("No Page Number")], nk, w = dp(170)):
            listDlg.numbers = nk
        if listDlg.numbers != 2:
          row([120, -1]):
            label "Between:"
            edit(listDlg.between, w = dp(120))
          if listDlg.numbers == 0 and listDlg.between.len == 0:
            row([120, -1]):
              label "Leader:"
              discard combo([tr("Dots"), tr("Dashes"), tr("A line"), tr("None")], listDlg.leader, w = dp(120))
          label(if listDlg.numbers == 0: "Empty: a tab to the far edge, the leader before the number."
                else: "Empty: two spaces.", color = ui.theme.gray)
      checkbox("Sort Entries in Alphabetical Order", listDlg.sorted)
      checkbox("Include Text on Hidden Layers", listDlg.hidden)
      checkbox("Create PDF Bookmarks", listDlg.bookmarks)
      checkbox("Replace Existing Table of Contents", listDlg.replace)
      row([90, -1, 110]):
        label "Save as:"
        edit(listDlg.saveName, w = dp(160))
        if button("Save Style", w = dp(100), enabled = listDlg.saveName.strip.len > 0):
          let n = listDlg.saveName.strip
          let v = $listSettings()
          var found = false
          for e in b.tocStyles.mitems:
            if e.name == n:
              e.settings = v
              found = true
          if not found: b.tocStyles.add (n, v)
          b.modified = true
          status = tr("TOC Style kept: ") & n
    checkbox(if listDlg.index: "On a new page (else on this one)"
             else: "On a new page when there is none to replace (else on this one)", listDlg.newPage)
    row:
      spring()
      if button("OK", isDefault = true, w = dp(80)): ok = true
      if button("Cancel", w = dp(80)): listDlg.open = false
  if ok: listOk()
