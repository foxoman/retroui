# (included by photo.nim) More of the layout program's help: Layout > Booklet -- a booklet's format
# (A5 or B5 saddle stitch, an A4 sheet), its grid in millimeters, its folios and running heads on the
# outside, the pages seen one at a time, in spreads or on the printer's sheets; File > Print Booklet -- a book's
# pages on printer's spreads (2-up saddle stitch, or perfect bound in signatures), the space
# between a spread's pages and the paper's creep made up for, into a PDF that prints both sides
# and folds into the book in order (retroui/photobook's `saveBookletPdf`); Type > Find Font -- the
# fonts the type is set in, each changed for another everywhere (`fontsUsed`, `replaceFontAll`),
# in a book on every page.

var
  blDlg: tuple[open: bool; bw: BookWin; bl: Booklet; sig: int]
  blPick = false
  blPath = ""
  fontFind: tuple[open: bool; fonts: seq[tuple[family, style: string; chars, layers: int]]; pick: int;
               toFamily, toStyle: int; key: string]

const blSignatures = [4, 8, 12, 16, 32]

proc startPrintBooklet() =
  let bw = curBook()
  if bw == nil:
    status = tr("Print Booklet: open a book first (File > New Book)")
    return
  endModes()
  blDlg.bw = bw
  blDlg.open = true

proc printBookletDialog() =
  if blDlg.open:
    if blDlg.bw == nil or blDlg.bw notin books:
      blDlg.open = false
      return
    let b = blDlg.bw.book
    var go = false
    dialog(blDlg.open, "Print Booklet", 460):
      var k = ord(blDlg.bl.kind)
      var names: seq[string]
      for x in BookletKind: names.add tr($x)
      row([170, -1]):
        label "Booklet Type:"
        if combo(names, k, w = dp(200)): blDlg.bl.kind = BookletKind(k)
      if blDlg.bl.kind == bkPerfect:
        row([170, -1]):
          label "Pages a signature:"
          var sn: seq[string]
          for s in blSignatures: sn.add $s
          if combo(sn, blDlg.sig, w = dp(80)): discard
          blDlg.bl.signature = blSignatures[clamp(blDlg.sig, 0, blSignatures.high)]
      row([170, 90, -1]):
        label "Space between pages:"
        discard numberEdit(blDlg.bl.space, decimals = 1, w = dp(80), lo = 0, hi = 720, thousands = false)
        label "pt"
      row([170, 90, -1]):
        label "Creep:"
        discard numberEdit(blDlg.bl.creep, decimals = 1, w = dp(80), lo = -720, hi = 720, thousands = false)
        label "pt"
      paragraph(tr("Creep makes up for the paper's thickness: below 0 the inner sheets' pages move toward " &
                   "the fold (the cover stays), above 0 the outer sheets' away from it."),
                color = ui.theme.gray)
      let spreads = bookletSpreads(b.pages.len, blDlg.bl)
      var blanks = 0
      for (l, r, _) in spreads:
        if l < 0: inc blanks
        if r < 0: inc blanks
      label($b.pages.len & tr(" pages: ") & $spreads.len & tr(" printer's spreads on ") & $(spreads.len div 2) &
            tr(" sheets") & (if blanks > 0: ", " & $blanks & tr(" blank pages added") else: ""),
            color = ui.theme.gray)
      # (the first spreads, as they print)
      var shown = ""
      for n, (l, r, _) in spreads:
        if n >= 6: break
        let ln = if l < 0: "-" else: b.label(l)
        let rn = if r < 0: "-" else: b.label(r)
        shown.add (if shown.len > 0: "   " else: "") & ln & "|" & rn
      label(shown & (if spreads.len > 6: "  ..." else: ""), literal = true)
      row:
        spring()
        if button("Save PDF...", isDefault = true, w = dp(100), enabled = spreads.len > 0): go = true
        if button("Cancel", w = dp(80)): blDlg.open = false
    if go:
      blDlg.open = false
      let dir = if b.path.len > 0 and dirExists(b.path.parentDir): b.path.parentDir else: picturesDir()
      blPath = dir / (b.name & " booklet.pdf")
      blPick = true
  if blPick:
    if filePicker(blPick, blPath, fmSave, ["*.pdf"], "Print Booklet"):
      let bw = blDlg.bw
      if bw != nil and bw in books:
        var p = blPath
        if p.splitFile.ext.toLowerAscii != ".pdf": p.add ".pdf"
        try:
          beginBusy("Print Booklet")
          try: bw.book.saveBookletPdf(p, blDlg.bl, pdfPreset(ppPrint), bw.keepOf)
          finally: endBusy()
          rememberFile(p)
          status = tr("Booklet saved: ") & p.extractFilename
        except CatchableError:
          status = tr("Could not save the booklet: ") & getCurrentExceptionMsg()

# ---- Layout > Booklet: a booklet's format, its grid in millimeters, its folios and running heads, its
# pages as they are seen -- one, in spreads, or on the printer's sheets ---------------------------------------

type BookletPreset = tuple[name: string; w, h: float; facing: bool; pages, cols: int;
                           gutter, top, bottom, inside, outside: float]

const
  BookletPresets: array[3, BookletPreset] = [
    ("A5 Saddle Stitch", 148.0, 210.0, true, 12, 12, 3.0, 7.5, 7.0, 5.0, 4.2),
    ("B5 Saddle Stitch", 182.0, 257.0, true, 12, 12, 4.0, 10.0, 9.0, 7.0, 5.5),
    ("A4 Sheet", 210.0, 297.0, false, 1, 12, 4.0, 12.0, 12.0, 10.0, 10.0)]
    ## (each one's page, pages and grid, in millimeters)
  FolioPlaces = ["None", "Bottom, outside", "Bottom, middle", "Top, outside"]
  HeadPlaces = ["None", "Top, outside", "Top, inside", "Bottom, inside"]

var bk: tuple[open: bool; bw: BookWin; preset, view, folio, head, cols: int;
              gutter, top, bottom, inside, outside, size: float; headText: string; skip: bool]

proc mmPx(b: Book; mm: float): int = int(mm / 25.4 * b.setup.dpi + 0.5)
proc pxMm(b: Book; px: int): float = round(float(px) * 25.4 / b.setup.dpi * 10) / 10

proc bookletGrid(p: BookletPreset) =
  bk.cols = p.cols
  bk.gutter = p.gutter
  bk.top = p.top
  bk.bottom = p.bottom
  bk.inside = p.inside
  bk.outside = p.outside

proc startBooklet() =
  let bw = curBook()
  bk.bw = bw
  if bw != nil:
    let st = bw.book.setup
    bk.cols = max(1, st.columns)
    bk.gutter = pxMm(bw.book, st.gutter)
    bk.top = pxMm(bw.book, st.top)
    bk.bottom = pxMm(bw.book, st.bottom)
    bk.inside = pxMm(bw.book, st.inside)
    bk.outside = pxMm(bw.book, st.outside)
  else: bookletGrid(BookletPresets[bk.preset])
  if bk.size <= 0:
    bk.size = 8
    bk.skip = true
  bk.view = if showFacing: 1 else: 0
  endModes()
  bk.open = true

proc applyGrid(b: Book) =
  b.setup.columns = max(1, bk.cols)
  b.setup.gutter = mmPx(b, bk.gutter)
  b.setup.top = mmPx(b, bk.top)
  b.setup.bottom = mmPx(b, bk.bottom)
  b.setup.inside = mmPx(b, bk.inside)
  b.setup.outside = mmPx(b, bk.outside)
  b.modified = true

proc applyFolios(b: Book) =
  ## The folio (the page's number) and the running head on the first master's pages, where the
  ## dialog says: the outside on the right of odd pages, the left of even ones; not on the cover,
  ## the blank pages and the back cover when asked.
  let m = if b.masters.len > 0: b.masters[0] else: b.addMaster("A")
  for i in 0 ..< b.pages.len:
    if b.pages[i].master == 0: b.setMaster(i, m.id)
  let sides = if b.setup.facing: @[psLeft, psRight] else: @[psRight]
  let px = bk.size / 72 * b.setup.dpi
  for side in sides:
    let md = b.masterDoc(m, side)
    # (what a Booklet put there before goes first)
    for k in countdown(md.layers.high, 0):
      if md.layers[k].name in ["Folio", "Running Head"]: md.deleteLayer(k)
    let box = b.marginBox(m, side)
    let gap = float(min(b.setup.bottom, b.setup.top)) * 0.35
    let lineH = px * 1.4
    let outside = if side == psLeft: textLeft else: textRight
    let inside = if side == psLeft: textRight else: textLeft
    proc put(what, name: string; atTop: bool; align: TextAlign) =
      var st = defaultStyle()
      st.size = float32(px)
      var t = newText(what, st, 0, 0)
      t.x = float32(box.x)
      t.y = float32(if atTop: float(box.y) - gap - lineH else: float(box.y + box.h) + gap)
      t.boxW = float32(box.w)
      t.boxH = float32(lineH)
      t.para.align = align
      let L = md.addTextLayer(t)
      L.name = name
    case bk.folio
    of 1: put("<#>", "Folio", false, outside)
    of 2: put("<#>", "Folio", false, textCenter)
    of 3: put("<#>", "Folio", true, outside)
    else: discard
    if bk.headText.strip.len > 0:
      case bk.head
      of 1: put(bk.headText, "Running Head", true, outside)
      of 2: put(bk.headText, "Running Head", true, inside)
      of 3: put(bk.headText, "Running Head", false, inside)
      else: discard
  # (the cover, the blank pages and the back cover: without them)
  if bk.skip:
    for i in 0 ..< b.pages.len:
      var blank = true
      let d = (try: b.doc(i) except CatchableError: nil)
      if d != nil:
        for k, L in d.layers:
          # (a page's own layer with something on it -- not its paper, the background under all)
          if k == 0 and L.name == "Background": continue
          if L.fromMaster == 0 and L.visible and d.contentBounds(L).w > 0: blank = false
      if i == 0 or (i == b.pages.high and b.pages.len > 1) or blank: b.pages[i].hideMaster = true
  b.modified = true

proc impositionView(b: Book) =
  ## (the pages as they print: each sheet's front and back, two pages side by side)
  let bl = Booklet(kind: bkSaddle)
  let spreads = bookletSpreads(b.pages.len, bl)
  label($b.pages.len & tr(" pages on ") & $(spreads.len div 2) & tr(" sheets, folded and stapled"),
        color = ui.theme.gray)
  beginScroll(dp(230), "imposition", framed = true)
  let cw = dp(62)
  let ch = max(dp(30), cw * b.setup.h div max(1, b.setup.w))
  for n, (l, r, _) in spreads:
    row([dp(110), cw, cw]):
      label(tr("Sheet ") & $(n div 2 + 1) & (if n mod 2 == 0: tr(", front") else: tr(", back")))
      for p in [l, r]:
        let pr = place(cw, ch)
        fill(pr, color(255, 255, 255))
        if p >= 0:
          let t = (try: b.thumb(p, 160, false) except CatchableError: nil)
          if t != nil and t.w > 0: drawBitmap(pr, t)
          text(pr.x + dp(3), pr.y + pr.h - FontH - dp(2), b.label(p), color(120, 120, 120))
        box(pr, ui.theme.edge)
  endScroll()

proc bookletDialog() =
  if not bk.open: return
  if bk.bw != nil and bk.bw notin books: bk.bw = nil
  var make, apply = false
  dialog(bk.open, "Booklet", 520):
    var names: seq[string]
    for p in BookletPresets: names.add tr(p.name)
    row([150, -1]):
      label "Format:"
      if combo(names, bk.preset, w = dp(200)): bookletGrid(BookletPresets[bk.preset])
    if bk.bw != nil:
      row([150, -1]):
        label "View:"
        if segmented(["1 Page", "Spreads", "Imposition"], bk.view):
          if bk.view < 2:
            showFacing = bk.view == 1
            invalidate()
    if bk.view == 2 and bk.bw != nil:
      impositionView(bk.bw.book)
    group "Grid":
      row([150, 80, 80, 80, -1]):
        label "Columns, gutter:"
        discard intEdit(bk.cols, w = dp(70), lo = 1, hi = 24)
        discard numberEdit(bk.gutter, decimals = 1, w = dp(70), lo = 0, hi = 100, thousands = false)
        label "mm"
      row([150, 80, 80, 80, -1]):
        label "Margins, top, bottom:"
        discard numberEdit(bk.top, decimals = 1, w = dp(70), lo = 0, hi = 200, thousands = false)
        discard numberEdit(bk.bottom, decimals = 1, w = dp(70), lo = 0, hi = 200, thousands = false)
        label "mm"
      row([150, 80, 80, 80, -1]):
        label "Inside, outside:"
        discard numberEdit(bk.inside, decimals = 1, w = dp(70), lo = 0, hi = 200, thousands = false)
        discard numberEdit(bk.outside, decimals = 1, w = dp(70), lo = 0, hi = 200, thousands = false)
        label "mm"
      if link(tr("Back to the format's values")): bookletGrid(BookletPresets[bk.preset])
    group "Folios and Running Heads":
      row([150, -1]):
        label "Folio:"
        discard combo(FolioPlaces, bk.folio, w = dp(180))
      row([150, -1]):
        label "Running head:"
        discard combo(HeadPlaces, bk.head, w = dp(180))
      row([150, -1]):
        label "Its text:"
        edit(bk.headText)
      row([150, 80, -1]):
        label "Size:"
        discard numberEdit(bk.size, decimals = 1, w = dp(70), lo = 4, hi = 72, thousands = false)
        label "pt"
      checkbox("Not on the cover, the blank pages and the back cover", bk.skip)
      paragraph(tr("On the outside: the right of odd pages, the left of even ones. They go on the master, " &
                   "on every page that has it."), color = ui.theme.gray)
    row:
      spring()
      if button("New Booklet", w = dp(110)): make = true
      if button("Apply", isDefault = true, w = dp(80), enabled = bk.bw != nil): apply = true
      if button("Close", w = dp(80)): bk.open = false
  if make:
    let p = BookletPresets[bk.preset]
    var st = bookSetup(p.w, p.h, dpi = 300, facing = p.facing)
    addBook(newBook(st, p.pages, tr(p.name)))
    bk.bw = curBook()
    apply = bk.bw != nil
  if apply and bk.bw != nil:
    let b = bk.bw.book
    beginBusy("Booklet")
    try:
      applyGrid(b)
      applyFolios(b)
    finally: endBusy()
    invalidate()
    status = tr("Booklet: the grid, the folios and the running heads set")

# ---- Find Font ----------------------------------------------------------------------------------------------

proc fontFindDocs(): seq[Doc] =
  ## (the documents Find Font looks through: a book's pages, else the picture in front)
  let bw = curBook()
  if bw != nil:
    for i in 0 ..< bw.book.pages.len:
      try: result.add bw.book.doc(i)
      except CatchableError: discard
  elif cur() != nil: result.add cur()

proc fontFindScan() =
  fontFind.fonts.setLen(0)
  for d in fontFindDocs():
    for (f, s, n, ls) in d.fontsUsed:
      var found = false
      for x in fontFind.fonts.mitems:
        if x.family == f and x.style == s:
          x.chars += n
          x.layers += ls
          found = true
      if not found: fontFind.fonts.add (f, s, n, ls)
  fontFind.fonts.sort(proc (a, b: tuple[family, style: string; chars, layers: int]): int = cmp(b.chars, a.chars))

proc startFindFont() =
  if cur() == nil:
    status = tr("Find Font: open a picture or a book first")
    return
  if te.on: commitType()
  fontFindScan()
  fontFind.pick = 0
  fontFind.open = true

proc fontShown(f: string): string = (if f.len == 0: "FreeSans" else: f)

proc findFontDialog() =
  if not fontFind.open: return
  var change = false
  let fams = fontFamilies()
  dialog(fontFind.open, "Find Font", 520):
    label(tr("Fonts in the document:"), bold = true)
    var items: seq[string]
    for x in fontFind.fonts:
      let missing = x.family.len > 0 and x.family notin fams
      items.add fontShown(x.family) & " " & x.style & "  (" & $x.chars & tr(" characters, ") & $x.layers &
                tr(" layers") & ")" & (if missing: tr("  -- missing") else: "")
    if items.len == 0: label(tr("No type in it."), color = ui.theme.gray)
    else: discard listbox(items, fontFind.pick, rows = 7)
    group("Replace With"):
      var fn = @["FreeSans"]
      for f in fams:
        if f != "FreeSans": fn.add f
      row([110, -1]):
        label "Font Family:"
        if combo(fn, fontFind.toFamily, w = dp(260)): fontFind.toStyle = 0
      var sn: seq[string]
      let fam = fn[clamp(fontFind.toFamily, 0, fn.high)]
      for s in fontStyles(if fam == "FreeSans": "" else: fam): sn.add s
      if sn.len == 0: sn = @["Regular"]
      row([110, -1]):
        label "Font Style:"
        discard combo(sn, fontFind.toStyle, w = dp(160))
      fontFind.key = fam & "\t" & sn[clamp(fontFind.toStyle, 0, sn.high)]
    row:
      spring()
      if button("Change All", isDefault = true, w = dp(100), enabled = fontFind.fonts.len > 0): change = true
      if button("Done", w = dp(80)): fontFind.open = false
  if change and fontFind.pick in 0 .. fontFind.fonts.high:
    let src = fontFind.fonts[fontFind.pick]
    let parts = fontFind.key.split('\t')
    let toF = if parts[0] == "FreeSans": "" else: parts[0]
    let toS = if parts.len > 1: parts[1] else: ""
    var n = 0
    let bw = curBook()
    if bw != nil:
      for i in 0 ..< bw.book.pages.len:
        let d = (try: bw.book.doc(i) except CatchableError: nil)
        if d == nil: continue
        d.beginStep("Find Font")
        d.touchLayers()
        let k = d.replaceFontAll(src.family, src.style, toF, toS)
        if k > 0:
          d.endStep()
          bw.book.touch(i)
          n += k
        else: d.cancelStep()
    elif cur() != nil:
      let d = cur()
      d.beginStep("Find Font")
      d.touchLayers()
      n = d.replaceFontAll(src.family, src.style, toF, toS)
      if n > 0: d.endStep() else: d.cancelStep()
    status = $n & tr(" type layers now in ") & fontShown(toF) & " " & toS
    fontFindScan()
    fontFind.pick = clamp(fontFind.pick, 0, max(0, fontFind.fonts.high))

# ---- Islamic patterns --------------------------------------------------------------------------------------
# Layout > Islamic Pattern: eight-pointed stars and crosses, six-pointed stars, octagons with stars,
# or a border of stars along the edges (`retroui/geopatterns`) -- a shape layer over the selection
# (else the whole picture), filled with the foreground color and stroked with the background's.

var gpDlg: tuple[open: bool; kind: int; cell: int; stroke: int]

proc startGeoPattern() =
  if cur() == nil:
    status = tr("Islamic Pattern: open a picture or a book first")
    return
  if gpDlg.cell <= 0: gpDlg = (true, 0, 0, 2)
  if gpDlg.cell <= 0: gpDlg.cell = max(16, min(cur().w, cur().h) div 8)
  gpDlg.open = true

proc geoPatternDialog() =
  if not gpDlg.open: return
  var go = false
  dialog(gpDlg.open, "Islamic Pattern", 420):
    var names: seq[string]
    for k in GeoPattern: names.add tr($k)
    names.add tr("A Border of Stars")
    row([130, -1]):
      label "Pattern:"
      discard combo(names, gpDlg.kind, w = dp(250))
    row([130, 90, -1]):
      label(if gpDlg.kind == names.high: "Border width:" else: "Cell size:")
      discard spin(gpDlg.cell, 8, 4000, w = dp(80))
      label "px"
    row([130, 90, -1]):
      label "Stroke:"
      discard spin(gpDlg.stroke, 0, 200, w = dp(80))
      label "px"
    paragraph(tr("Over the selection, else the whole picture: filled with the foreground color, " &
                 "stroked with the background's. Put it inside a frame to cut it to the frame's edge."),
              color = ui.theme.gray)
    row:
      spring()
      if button("OK", isDefault = true, w = dp(80)): go = true
      if button("Cancel", w = dp(80)): gpDlg.open = false
  if go:
    gpDlg.open = false
    let d = cur()
    if d == nil: return
    let r = if d.hasSelection: d.selBounds else: rect(0, 0, d.w, d.h)
    let border = gpDlg.kind > ord(high(GeoPattern))
    let p = if border: geoBorder(r.x.float, r.y.float, (r.x + r.w).float, (r.y + r.h).float, gpDlg.cell.float)
            else: geoPattern(GeoPattern(gpDlg.kind), r.x.float, r.y.float, (r.x + r.w).float, (r.y + r.h).float,
                             gpDlg.cell.float)
    var sd = ShapeData(path: p, fill: solidPaint(fg or 0xFF000000'u32), strokeWidth: gpDlg.stroke.float)
    if gpDlg.stroke > 0: sd.stroke = solidPaint(bg or 0xFF000000'u32)
    let nm = if border: tr("A Border of Stars") else: tr($GeoPattern(gpDlg.kind))
    d.stepOnce("Islamic Pattern", proc () = discard d.addShapeLayer(sd, nm))
    status = nm & ": " & $p.subs.len & tr(" shapes")
