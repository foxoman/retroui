# Retro Atelier -- included by photo.nim
#
# Artboards as the drawing program has them: pages of the canvas the document keeps (`Doc.boards`),
# not layers -- the artwork lies on the layers, on an artboard or round it on the canvas. Here: the
# Artboards panel (each one numbered and named, in order; picked, fitted in the window, renamed,
# sized, placed by another -- at its right or left, over or under it, touching or the gap apart --,
# made, copied, deleted, moved up and down; the artwork picked moved onto it; the artboards as
# pages: their first number, facing in spreads), the Layer > Artboards commands (Convert to
# Artboards, Rearrange All Artboards, Fit to Artwork Bounds, Fit to Selected Art, Move to Artboard,
# Page Numbers, Facing Pages), View's Fit Artboard in Window, Fit All in Window and Show Artboards,
# the next and the previous artboard, the Rearrange All Artboards and the Page Numbers dialogs.
# Type with `<#>` on an artboard shows its number, `<##>` how many (retroui/photo's
# `effectiveText`, `syncBoardNumbers` every frame). The Artboard tool's drags (in line with the
# others when near them) are in photo.nim; Artboard Options in photo/ccfeatures; Save PDF's and
# Print's artboards, spreads or whole canvas in photo/pdfexport and photo/dialogs.

var
  rearrDlg: tuple[open: bool; layout, cols, spacing: int; rtl, moveArt: bool] = (false, 0, 2, 20, false, true)
  boardPlace: tuple[side, beside: int; touch: bool] = (0, -1, false)
    ## the Artboards panel's Place: at the right (0), left (1), under (2), over (3) of artboard
    ## `beside`; touching it (a spread's pages) or the gap apart
  folioDlg: tuple[open: bool; folio, head: int; text: string; size: float; skip: bool; first: int;
                  facing: bool] = (false, 1, 0, "", 10.0, false, 1, false)

proc fitBoardInWindow(d: Doc; i: int) =
  ## View > Fit Artboard in Window: artboard `i` as big as the window shows it.
  let dw = active
  if dw == nil or dw.doc != d or i < 0 or i >= d.boards.len: return
  let b = d.boards[i].r
  dw.view.zoomToRect(d, b.x.float, b.y.float, (b.x + b.w).float, (b.y + b.h).float)
  dw.afterZoom(b.x.float + b.w / 2, b.y.float + b.h / 2, true)

proc fitAllBoards(d: Doc) =
  ## View > Fit All in Window: all the artboards in the window.
  let dw = active
  if dw == nil or dw.doc != d or d.boards.len == 0: return
  var u = d.boards[0].r
  for b in d.boards: u = union(u, b.r)
  dw.view.zoomToRect(d, u.x.float, u.y.float, (u.x + u.w).float, (u.y + u.h).float)
  dw.afterZoom(u.x.float + u.w / 2, u.y.float + u.h / 2, true)

proc goToBoard(d: Doc; i: int) =
  ## (an artboard picked -- the panel, next and previous -- and fitted in the window)
  if i < 0 or i >= d.boards.len: return
  d.boardCur = i
  fitBoardInWindow(d, i)
  status = d.artboardName(i) & "   " & $d.boards[i].r.w & " x " & $d.boards[i].r.h & " px"

proc newBoardBeside(d: Doc): int =
  ## New Artboard (the panel, the options bar): one as big as the picked one, right of them all; the
  ## first: round the whole canvas (what is on it is its artwork).
  if d.boards.len == 0: return d.addArtboard(rect(0, 0, d.w, d.h))
  let src = d.boards[clamp(d.boardCur, 0, d.boards.high)].r
  var right = src.x + src.w
  for b in d.boards: right = max(right, b.r.x + b.r.w)
  d.addArtboard(rect(right + d.boardGap, src.y, src.w, src.h))

proc duplicateBoardBeside(d: Doc): int =
  ## Duplicate Artboards (the panel): a copy of the picked one -- its artwork copied too -- right of
  ## them all.
  if d.boards.len == 0: return -1
  let c = clamp(d.boardCur, 0, d.boards.high)
  let src = d.boards[c].r
  var right = src.x + src.w
  for b in d.boards: right = max(right, b.r.x + b.r.w)
  d.duplicateArtboard(c, right + d.boardGap - src.x, 0, withArt = true)

proc boardRowName(d: Doc; i: int): string =
  ## (an artboard in the panel's list: its number and name, its size; as pages, its number when it
  ## is not its place, and which side of its spread)
  result = d.artboardName(i) & "   " & $d.boards[i].r.w & " x " & $d.boards[i].r.h
  var page = ""
  if d.boardFirst > 1: page = tr("p. ") & d.boardLabel(i)
  case d.boardSide(i)
  of -1: page.add (if page.len > 0: ", " else: "") & tr("left")
  of 1: page.add (if page.len > 0: ", " else: "") & tr("right")
  else: discard
  if page.len > 0: result.add "   (" & page & ")"

proc placeBoard(d: Doc; i: int) =
  ## (the panel's Place: artboard `i` by the one chosen, as the panel says)
  let o = boardPlace.beside
  if i < 0 or i >= d.boards.len or o < 0 or o >= d.boards.len or o == i: return
  d.beginStep("Place Artboard")
  d.placeArtboard(i, o, boardPlace.side, (if boardPlace.touch: 0 else: d.boardGap), boardMoveArt)
  d.endStep()
  goToBoard(d, i)

proc moveArtToBoard(d: Doc; i: int) =
  ## Layer > Artboards > Move to Artboard: the layers picked (the current one, when none is) onto
  ## artboard `i`, as far from its corner as they were from that of the one they were on.
  if i < 0 or i >= d.boards.len: return
  var ls: seq[Layer]
  for k in d.pickedLayers:
    if k >= 0 and k < d.layers.len: ls.add d.layers[k]
  if ls.len == 0 and d.layers.len > 0 and not d.current.background: ls.add d.current
  if ls.len == 0:
    status = tr("Move to Artboard: pick the layers to move (the Layers panel, or the Move tool)")
    return
  d.beginStep("Move to Artboard")
  d.moveToArtboard(ls, i)
  d.endStep()
  status = tr("Moved to ") & "\"" & d.artboardName(i) & "\""

proc artboardsBody() =
  ## Window > Artboards: the document's artboards in their order (the order they are exported and
  ## printed in) -- one clicked is picked and fitted in the window --, the picked one's name and size
  ## to type over, a preset; Place it by another (right, left, under, over; touching: a spread);
  ## New, Duplicate, Delete, Move Up and Move Down; Move Art Here; as pages: their first number,
  ## facing in spreads, Page Numbers; Rearrange All; Artboard Options.
  let d = cur()
  if d == nil:
    label("(no image)", color = ui.theme.gray)
    return
  if d.boards.len == 0:
    paragraph(tr("No artboards yet. With the Artboard tool (in the Move tool's place, V) drag a box on the " &
                 "canvas -- or press New: one round the whole canvas."), color = ui.theme.gray)
  else:
    var names: seq[string]
    for i in 0 ..< d.boards.len: names.add d.boardRowName(i)
    var sel = clamp(d.boardCur, 0, d.boards.high)
    let before = sel
    accessName(tr("Artboards"))
    listbox(names, sel, rows = max(3, min(10, (remainingH() - 9 * CtrlH - 9 * Gap) div ItemH)))
    if sel != before: goToBoard(d, sel)
    row([dp(48), -1]):
      label "Name:"
      boardNameField(d, sel)
    # (its size: typed, a preset, which way round)
    let b = d.boards[sel].r
    var (w, h) = (b.w, b.h)
    row([dp(48), dp(70), dp(14), dp(70), -1]):
      label "Size:"
      accessName(tr("Width"))
      if spin(w, 1, 30000, w = dp(66)):
        d.beginStep("Resize Artboard")
        d.resizeArtboard(sel, rect(b.x, b.y, w, b.h))
        d.endStep()
      label "x"
      accessName(tr("Height"))
      if spin(h, 1, 30000, w = dp(66)):
        d.beginStep("Resize Artboard")
        d.resizeArtboard(sel, rect(b.x, b.y, b.w, h))
        d.endStep()
      label unitAbbrev(ruPixels)
    row([dp(48), -1, dp(26), dp(26)]):
      label "Preset:"
      var pnames: seq[string]
      for p in BoardPresets: pnames.add p[0]
      var pk = d.presetOf(b.w, b.h)
      accessName(tr("Preset"))
      if combo(pnames, pk) and pk > 0:
        let (pw, ph) = d.presetSize(pk)
        let (nw, nh) = if b.w > b.h and pw < ph: (ph, pw) else: (pw, ph)
        d.beginStep("Artboard Size")
        d.resizeArtboard(sel, rect(b.x, b.y, nw, nh))
        d.endStep()
      if toolButton("P", "Portrait: taller than wide", down = b.h >= b.w, enabled = b.w > b.h) or
         toolButton("L", "Landscape: wider than tall", down = b.w > b.h, enabled = b.h > b.w):
        d.beginStep("Artboard Orientation")
        d.resizeArtboard(sel, rect(b.x, b.y, b.h, b.w))
        d.endStep()
    # (placed by another: its right or left, under or over it)
    if d.boards.len > 1:
      var others: seq[string]
      var idx: seq[int]
      for i in 0 ..< d.boards.len:
        if i != sel:
          others.add d.artboardName(i)
          idx.add i
      if boardPlace.beside notin idx: boardPlace.beside = idx[(if sel > 0: sel - 1 else: 0)]
      var k = idx.find(boardPlace.beside)
      row([dp(48), dp(96), -1]):
        label "Place:"
        accessName(tr("Where"))
        discard combo([tr("Right of"), tr("Left of"), tr("Below"), tr("Above")], boardPlace.side)
        accessName(tr("Beside the artboard"))
        if combo(others, k): boardPlace.beside = idx[k]
      row:
        if checkbox("Touching (a spread)", boardPlace.touch): discard
        tooltip("Touching: no room between them, as a spread's two pages; else 20 points apart")
        spring()
        if button("Place", w = dp(64)): placeBoard(d, sel)
  let c = d.boardCur
  let has = c >= 0 and c < d.boards.len
  row:
    if toolButton("New", "New Artboard: as big as the picked one, at the right"): runCommand("New Artboard")
    if toolButton("Copy", "Duplicate Artboards: the picked one and its artwork", enabled = has):
      runCommand("Duplicate Artboards")
    if toolButton("Delete", "Delete Artboard (its artwork stays on the canvas)", enabled = has):
      runCommand("Delete Artboard")
    if toolButton("Up", "Move Up: earlier in the order", enabled = has and c > 0): runCommand("Move Artboard Up")
    if toolButton("Down", "Move Down: later in the order", enabled = has and c < d.boards.high):
      runCommand("Move Artboard Down")
  if has:
    row:
      if button("Move Art Here", w = dp(116)): moveArtToBoard(d, c)
      tooltip("Move to Artboard: the layers picked onto this artboard, where they were on theirs")
  if d.boards.len > 0:
    # (the artboards as pages: their numbers -- `<#>` in type --, facing in spreads)
    var facing = d.boardFacing
    if checkbox("Facing Pages (spreads)", facing): runCommand("Facing Artboards")
    tooltip("The first alone, a right page, then two by two, left and right: printed, exported, " &
            "rearranged and numbered so")
    var first = max(1, d.boardFirst)
    row([-1, dp(70)]):
      label "First page number:"
      accessName(tr("First page number"))
      if spin(first, 1, 99999, w = dp(66)):
        d.beginStep("Artboard Numbers")
        d.touchLayers()
        d.boardFirst = first
        inc d.boardsVer
        d.endStep()
  row:
    if button("Page Numbers...", w = dp(116), enabled = d.boards.len > 0): runCommand("Artboard Page Numbers...")
    if button("Rearrange All...", w = dp(116), enabled = d.boards.len > 0): runCommand("Rearrange All Artboards...")
  row:
    if button("Options...", w = dp(80), enabled = has): runCommand("Artboard Options...")
    if button("Export...", w = dp(80), enabled = d.boards.len > 0): runCommand("Artboards to Files")

proc artboardsMenu() =
  ## The Artboards panel's menu.
  let d = cur()
  let some = d != nil
  let has = some and d.boardCur >= 0 and d.boardCur < d.boards.len
  if menuItem("New Artboard", enabled = some): runCommand("New Artboard")
  if menuItem("Duplicate Artboards", enabled = has): runCommand("Duplicate Artboards")
  if menuItem("Delete Artboard", enabled = has): runCommand("Delete Artboard")
  if menuItem("Delete Empty Artboards", enabled = some and d.boards.len > 0): runCommand("Delete Empty Artboards")
  menuSeparator()
  if menuItem("Convert to Artboards", enabled = some and d.pickedShapes.len > 0): runCommand("Convert to Artboards")
  if menuItem("Artboard Options...", enabled = has): runCommand("Artboard Options...")
  if menuItem("Rearrange All Artboards...", enabled = some and d.boards.len > 0):
    runCommand("Rearrange All Artboards...")
  menuSeparator()
  if menuItem("Move Art Here", enabled = has): moveArtToBoard(d, d.boardCur)
  if menuItem("Facing Pages (Spreads)", enabled = some and d.boards.len > 0, checked = some and d.boardFacing):
    runCommand("Facing Artboards")
  if menuItem("Page Numbers...", enabled = some and d.boards.len > 0): runCommand("Artboard Page Numbers...")

proc rearrangeDialog() =
  ## (Rearrange All Artboards, as the drawing program has it: Grid by Row or by Column, Arrange by Row
  ## or by Column; right to left; so many columns -- rows, by column --; the spacing; the artwork
  ## moved with them)
  if not rearrDlg.open: return
  let d = cur()
  if d == nil or d.boards.len == 0:
    rearrDlg.open = false
    return
  var go = false
  dialog(rearrDlg.open, "Rearrange All Artboards", 380):
    form 0:
      field "Layout:":
        discard combo(["Grid by Row", "Grid by Column", "Arrange by Row", "Arrange by Column", "Spreads"],
                      rearrDlg.layout, w = dp(170))
      if rearrDlg.layout <= 1 or rearrDlg.layout == 4:
        field (if rearrDlg.layout == 0: "Columns:" elif rearrDlg.layout == 4: "Spreads in a row:" else: "Rows:"):
          discard spin(rearrDlg.cols, 1, 100, w = dp(70))
      field "Spacing:":
        discard spin(rearrDlg.spacing, 0, 10000, w = dp(70))
    checkbox("Change to Right-to-Left Layout", rearrDlg.rtl)
    checkbox("Move Artwork with Artboard", rearrDlg.moveArt)
    paragraph(tr("In their order in the Artboards panel, from the first one's top left; the spacing in pixels."),
              color = ui.theme.gray)
    if rearrDlg.layout == 4:
      paragraph(tr("Spreads: each spread's pages touching at the spine -- with Facing Pages the first alone, " &
                   "a right page, then two by two."), color = ui.theme.gray)
    row:
      spring()
      if button("OK", isDefault = true, w = dp(80)): go = true
      if button("Cancel", w = dp(80)): rearrDlg.open = false
  if go:
    rearrDlg.open = false
    d.beginStep("Rearrange All Artboards")
    d.rearrangeArtboards(ArrangeLayout(clamp(rearrDlg.layout, 0, ord(high(ArrangeLayout)))), rearrDlg.cols,
                         rearrDlg.spacing,
                         rearrDlg.rtl, rearrDlg.moveArt)
    d.endStep()
    fitAllBoards(d)

proc applyBoardFolios(d: Doc) =
  ## (Page Numbers' OK: the numbering and facing as the dialog says, the folios and running heads
  ## made again, in a step)
  folioDlg.open = false
  d.beginStep("Page Numbers")
  d.touchLayers()
  d.boardFirst = max(1, folioDlg.first)
  d.boardFacing = folioDlg.facing
  inc d.boardsVer
  let n = d.artboardFolios(BoardFolio(clamp(folioDlg.folio, 0, ord(high(BoardFolio)))),
                           BoardHead(clamp(folioDlg.head, 0, ord(high(BoardHead)))), folioDlg.text,
                           folioDlg.size, folioDlg.skip)
  d.endStep()
  status = tr("Page numbers: ") & $n & tr(" type layers")

proc folioDialog() =
  ## (Page Numbers on artboards, as a book's: the number -- `<#>` -- and a running head in each one's
  ## margin, outside: the right of a right page, the left of a left one)
  if not folioDlg.open: return
  let d = cur()
  if d == nil or d.boards.len == 0:
    folioDlg.open = false
    return
  var go = false
  dialog(folioDlg.open, "Page Numbers", 420):
    form 0:
      field "Page number:":
        var fs: seq[string]
        for f in BoardFolio: fs.add tr($f)
        discard combo(fs, folioDlg.folio, w = dp(180))
      field "Running head:":
        var hs: seq[string]
        for h in BoardHead: hs.add tr($h)
        discard combo(hs, folioDlg.head, w = dp(180))
      field "Its text:": edit(folioDlg.text)
      field "Size:":
        row:
          discard numberEdit(folioDlg.size, decimals = 1, w = dp(70), lo = 4, hi = 144, thousands = false)
          label "pt"
    checkbox("Not on the first and the last (the covers)", folioDlg.skip)
    row:
      label "First page number:"
      discard spin(folioDlg.first, 1, 99999, w = dp(70))
    checkbox("Facing Pages (spreads)", folioDlg.facing)
    paragraph(tr("Outside: the right of a right page, the left of a left one (facing pages: the first a right " &
                 "page, then left, right...). Type layers \"Folio\" and \"Running Head\" on each artboard -- " &
                 "<#> its number, <##> how many --, made again each time."), color = ui.theme.gray)
    row:
      if button("Remove", w = dp(80)):
        folioDlg.open = false
        d.beginStep("Remove Page Numbers")
        discard d.artboardFolios(bfNone)
        d.endStep()
        status = tr("Page numbers removed")
      spring()
      if button("OK", isDefault = true, w = dp(80)): go = true
      if button("Cancel", w = dp(80)): folioDlg.open = false
  if go: applyBoardFolios(d)

# ---- artboards (and a book's pages) printed and made a PDF: each a page, in spreads, the whole canvas -------------

var
  abPages: tuple[d: Doc; what, which: int; range: string]
    ## Save PDF's and Print's artboards: `what` each a page (0), in spreads (1), the whole canvas
    ## (2); `which` all (0), the picked one (1), a range (2)
  prDlg: tuple[open: bool; d: Doc; bw: BookWin; which: int; range: string; spreads: bool]
    ## the Print dialog of a book: its pages, all, the one shown or a range, as pages or spreads

proc abPagesFor(d: Doc) =
  ## (Save PDF's and Print's artboards for `d`: in spreads when they face)
  if abPages.d != d:
    abPages.d = d
    abPages.which = 0
    abPages.range = ""
    abPages.what = if d != nil and d.boardFacing: 1 else: 0

proc abPagesList(d: Doc): seq[int] =
  ## (the artboards asked for)
  case abPages.which
  of 1: @[clamp(d.boardCur, 0, d.boards.high)]
  of 2: d.artboardList(if abPages.range.strip.len > 0: abPages.range else: $(clamp(d.boardCur, 0, d.boards.high) + 1))
  else: @[]

proc abPagesGroup(d: Doc) =
  ## (the Artboards group of Save PDF and Print: each a page, in spreads, the whole canvas; which)
  group("Artboards"):
    var w = abPages.what
    row:
      label "As:"
      if radio("Pages", w, 0) or radio("Spreads", w, 1) or radio("Whole canvas", w, 2): abPages.what = w
    if abPages.what < 2:
      var a = abPages.which
      row:
        if radio(tr("All") & " (" & $d.boards.len & ")", a, 0): abPages.which = 0
        if radio(tr("This artboard") & " (" & $(clamp(d.boardCur, 0, d.boards.high) + 1) & ")", a, 1):
          abPages.which = 1
      row:
        if radio("Range:", a, 2): abPages.which = 2
        if edit(abPages.range, w = dp(120)): abPages.which = 2
        label("1-3, 5, 8-", color = ui.theme.gray)
      if abPages.what == 1 and not d.boardFacing:
        label(tr("The artboards do not face (Layer > Artboards > Facing Pages): each one is a sheet."),
              color = ui.theme.gray)
    else:
      label(tr("The whole canvas, the artboards and what is round them, as one page."), color = ui.theme.gray)

proc abPagesNote(d: Doc): string =
  ## (how many pages: "4 pages, 3 sheets")
  if abPages.what == 2: return tr("1 page (the whole canvas)")
  let sheets = d.artboardSheets(d.abPagesList, abPages.what == 1)
  var n = 0
  for sh in sheets: n += sh.len
  result = $n & (if n == 1: tr(" page") else: tr(" pages"))
  if abPages.what == 1: result.add ", " & $sheets.len & (if sheets.len == 1: tr(" sheet") else: tr(" sheets"))

proc artboardPdfFor(docs: seq[Doc]) =
  ## (the Save PDF dialog for `docs`: one with artboards -- them, as the dialog says)
  if docs.len == 1 and docs[0].boards.len > 0 and bookOf(active) == nil:
    abPagesFor(docs[0])
  else: abPages.d = nil

proc artboardPdfGroup() =
  let d = abPages.d
  if d == nil or pdfDlg.docs.len != 1 or pdfDlg.docs[0] != d or d.boards.len == 0: return
  d.abPagesGroup()

proc artboardPdfNote(): string =
  let d = abPages.d
  if d == nil or pdfDlg.docs.len != 1 or pdfDlg.docs[0] != d or d.boards.len == 0: return ""
  d.abPagesNote()

proc artboardPdfWrite(path: string; o: PdfOptions): bool =
  ## (the Save PDF dialog's OK, for artboards: each a page or in spreads -- false: the whole canvas,
  ## or no artboards, the document as one page)
  let d = abPages.d
  if d == nil or pdfDlg.docs.len != 1 or pdfDlg.docs[0] != d or d.boards.len == 0 or abPages.what == 2:
    return false
  let n = d.saveArtboardsPdf(path, o, d.abPagesList, abPages.what == 1)
  status = tr("Saved ") & path.extractFilename & " (" & $n & (if n == 1: tr(" page") else: tr(" pages")) &
           (if abPages.what == 1: tr(", as spreads") else: "") & ")"
  true

proc printFile(name: string): string =
  ## (the PDF a print goes through, in the app's own folder)
  let dir = dataDir(AppData) / "print"
  try: createDir(dir) except OSError, IOError: discard
  var n = name
  for c in n.mitems:
    if c in {'/', '\\', ':', '*', '?', '"', '<', '>', '|', '\0' .. '\31'}: c = '_'
  dir / (if n.strip.len > 0: n else: "print") & ".pdf"

proc startPrintPages(d: Doc) =
  ## File > Print: a book's pages -- all, the one shown, a range; as pages or spreads -- or a
  ## document's artboards -- each a page, in spreads, the whole canvas --, asked first; else the
  ## image as it was (Page Setup's).
  let bw = curBook()
  if bw != nil and bw.master == 0:
    endModes()
    prDlg = (true, d, bw, 0, "", bw.book.setup.facing)
  elif d.boards.len > 0:
    abPagesFor(d)
    prDlg = (true, d, nil, 0, "", false)
  else: printDoc(d)

proc printPagesDialog() =
  if not prDlg.open: return
  let d = prDlg.d
  let bw = prDlg.bw
  if d == nil or (bw != nil and bw notin books) or (bw == nil and (d != cur() or d.boards.len == 0)):
    prDlg.open = false
    return
  var go = false
  dialog(prDlg.open, "Print", 430):
    var note = ""
    if bw != nil:
      let b = bw.book
      group("Pages"):
        var a = prDlg.which
        row:
          if radio(tr("All") & " (" & $b.pages.len & ")", a, 0): prDlg.which = 0
          if radio(tr("This page") & " (" & $(bw.page + 1) & ")", a, 1): prDlg.which = 1
        row:
          if radio("Range:", a, 2): prDlg.which = 2
          if edit(prDlg.range, w = dp(120)): prDlg.which = 2
          label("1-3, 5, 8-", color = ui.theme.gray)
        var sp = if prDlg.spreads: 1 else: 0
        row:
          label "As:"
          if radio("Pages", sp, 0) or radio("Spreads", sp, 1): prDlg.spreads = sp == 1
        if prDlg.spreads and not b.setup.facing:
          label("The pages do not face (Document Setup): each is a sheet of its own.", color = ui.theme.gray)
      let range = case prDlg.which
                  of 1: $(bw.page + 1)
                  of 2: (if prDlg.range.strip.len > 0: prDlg.range else: $(bw.page + 1))
                  else: ""
      let sheets = b.exportSheets(b.pageList(range), prDlg.spreads)
      var n = 0
      for sh in sheets: n += sh.len
      note = $n & (if n == 1: tr(" page") else: tr(" pages")) &
             (if prDlg.spreads: ", " & $sheets.len & (if sheets.len == 1: tr(" sheet") else: tr(" sheets")) else: "")
    else:
      d.abPagesGroup()
      note = d.abPagesNote()
    paragraph(tr("A spread prints as one sheet, its pages side by side; in the printer's dialog choose a paper " &
                 "that takes it (landscape for two portrait pages)."), color = ui.theme.gray)
    row:
      label(note, color = ui.theme.gray)
      spring()
      if button("Print...", isDefault = true, w = dp(86)): go = true
      if button("Cancel", w = dp(80)): prDlg.open = false
  if go:
    prDlg.open = false
    let o = pdfPreset(ppPrint)
    try:
      if bw != nil:
        let b = bw.book
        let range = case prDlg.which
                    of 1: $(bw.page + 1)
                    of 2: (if prDlg.range.strip.len > 0: prDlg.range else: $(bw.page + 1))
                    else: ""
        let path = printFile(b.name)
        let e = BookExport(kind: exPdf, pages: range, spreads: prDlg.spreads, pdf: o)
        discard b.exportBook(path, e, bw.keepOf)
        let res = printPdf(path, b.name, "", b.exportSheets(b.pageList(range), prDlg.spreads).len)
        status = if res.ok: tr("Sent to the printer") else: res.message
      elif abPages.what == 2: printDoc(d)
      else:
        let path = printFile(d.name)
        let n = d.saveArtboardsPdf(path, o, d.abPagesList, abPages.what == 1)
        let res = printPdf(path, d.name, "", n)
        status = if res.ok: tr("Sent to the printer") else: res.message
    except CatchableError:
      status = tr("Could not print: ") & getCurrentExceptionMsg()

proc artboardsDialogs() =
  rearrangeDialog()
  folioDialog()
  printPagesDialog()

proc artboardsCommand(name: string): bool =
  ## The artboard commands (true: done here).
  let d = cur()
  result = true
  if name == "Clear" and tool == tMove and moveKind == 1 and d != nil and not d.hasSelection and
     d.boardCur >= 0 and d.boardCur < d.boards.len:
    # (Delete with the Artboard tool: the picked artboard, as the drawing program has it)
    d.beginStep("Delete Artboard")
    d.deleteArtboard(d.boardCur)
    d.endStep()
    status = tr("Artboard deleted: its artwork stays on the canvas")
    return
  case name
  of "Artboards": togglePanel("artboards")
  of "Show Artboards", "Hide Artboards":
    boardsShown = not boardsShown
    status = if boardsShown: tr("Artboards shown") else: tr("Artboards hidden (their edges and names)")
  else:
    if d == nil: return name in ["New Artboard", "Duplicate Artboards", "Delete Artboard", "Delete Empty Artboards",
                                 "Move Artboard Up", "Move Artboard Down", "Rearrange All Artboards...",
                                 "Fit to Artwork Bounds", "Fit to Selected Art", "Convert to Artboards",
                                 "Fit Artboard in Window", "Fit All in Window", "Next Artboard",
                                 "Previous Artboard", "Facing Artboards", "Artboard Page Numbers..."] or
                        name.startsWith("Move to Artboard ")
    let c = d.boardCur
    let has = c >= 0 and c < d.boards.len
    case name
    of "New Artboard":
      d.beginStep("New Artboard")
      let n = d.newBoardBeside()
      d.endStep()
      if n >= 0: goToBoard(d, n)
    of "Duplicate Artboards":
      if has:
        d.beginStep("Duplicate Artboards")
        let n = d.duplicateBoardBeside()
        d.endStep()
        if n >= 0: goToBoard(d, n)
    of "Delete Artboard":
      if has:
        d.beginStep("Delete Artboard")
        d.deleteArtboard(c)
        d.endStep()
        status = tr("Artboard deleted: its artwork stays on the canvas")
    of "Delete Empty Artboards":
      d.beginStep("Delete Empty Artboards")
      let n = d.deleteEmptyArtboards()
      d.endStep()
      status = $n & tr(" empty artboards deleted")
    of "Move Artboard Up", "Move Artboard Down":
      if has:
        d.beginStep("Reorder Artboards")
        d.reorderArtboard(c, if name == "Move Artboard Up": c - 1 else: c + 1)
        d.endStep()
    of "Rearrange All Artboards...":
      if d.boards.len > 0:
        rearrDlg.open = true
        rearrDlg.moveArt = boardMoveArt
    of "Fit to Artwork Bounds", "Fit to Selected Art":
      let i = if has: c else: -1
      if i < 0:
        status = tr("There is no artboard: make one with the Artboard tool")
      else:
        var ls: seq[Layer]
        if name == "Fit to Selected Art":
          for k in d.pickedLayers:
            if k >= 0 and k < d.layers.len: ls.add d.layers[k]
          if ls.len == 0 and not d.current.background: ls.add d.current
        d.beginStep(name)
        d.fitArtboardTo(i, ls)
        d.endStep()
    of "Convert to Artboards":
      let ss = d.pickedShapes
      if ss.len == 0:
        status = tr("Convert to Artboards: pick the rectangles (shapes) to make artboards of")
      else:
        d.beginStep("Convert to Artboards")
        let made = d.convertToArtboards(ss)
        d.endStep()
        status = tr("Convert to Artboards: ") & $made.len
    of "Fit Artboard in Window":
      if has: fitBoardInWindow(d, c)
      elif active != nil: active.view.fit(d)
    of "Fit All in Window":
      if d.boards.len > 0: fitAllBoards(d)
      elif active != nil: active.view.fit(d)
    of "Next Artboard":
      if d.boards.len > 0: goToBoard(d, (if has: (c + 1) mod d.boards.len else: 0))
    of "Previous Artboard":
      if d.boards.len > 0: goToBoard(d, (if has: (c + d.boards.len - 1) mod d.boards.len else: 0))
    of "Facing Artboards":
      # (the artboards as facing pages -- the first alone, a right page, then in spreads -- or not)
      if d.boards.len > 0:
        d.beginStep("Facing Pages")
        d.touchLayers()
        d.boardFacing = not d.boardFacing
        inc d.boardsVer
        d.endStep()
        status = if d.boardFacing: tr("Facing pages: the artboards in spreads (Rearrange All > Spreads lays them so)")
                 else: tr("Facing pages off: each artboard a page of its own")
    of "Artboard Page Numbers...":
      if d.boards.len > 0:
        folioDlg.open = true
        folioDlg.first = max(1, d.boardFirst)
        folioDlg.facing = d.boardFacing
    else:
      if name.startsWith("Move to Artboard "):
        let k = (try: parseInt(name["Move to Artboard ".len .. ^1].strip) - 1 except ValueError: -1)
        moveArtToBoard(d, k)
      else: result = false
