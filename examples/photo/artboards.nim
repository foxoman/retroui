# Retro Atelier -- included by photo.nim
#
# Artboards as the drawing program has them: pages of the canvas the document keeps (`Doc.boards`),
# not layers -- the artwork lies on the layers, on an artboard or round it on the canvas. Here: the
# Artboards panel (each one numbered and named, in order; picked, fitted in the window, renamed,
# made, copied, deleted, moved up and down), the Object > Artboards commands (Convert to Artboards,
# Rearrange All Artboards, Fit to Artwork Bounds, Fit to Selected Art), View's Fit Artboard in
# Window, Fit All in Window and Show Artboards, the next and the previous artboard, and the
# Rearrange All Artboards dialog. The Artboard tool's drags are in photo.nim; Artboard Options in
# photo/ccfeatures.

var
  rearrDlg: tuple[open: bool; layout, cols, spacing: int; rtl, moveArt: bool] = (false, 0, 2, 20, false, true)

proc boardGap(d: Doc): int =
  ## (the room between artboards made beside one another: 20 points)
  max(4, int(round(20 * d.dpi / 72)))

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

proc artboardsBody() =
  ## Window > Artboards: the document's artboards in their order (the order they are exported and
  ## printed in) -- one clicked is picked and fitted in the window --, the picked one's name to type
  ## over; New, Duplicate, Delete, Move Up and Move Down; Rearrange All; Artboard Options.
  let d = cur()
  if d == nil:
    label("(no image)", color = ui.theme.gray)
    return
  if d.boards.len == 0:
    paragraph(tr("No artboards yet. With the Artboard tool (in the Move tool's place, V) drag a box on the " &
                 "canvas -- or press New: one round the whole canvas."), color = ui.theme.gray)
  else:
    var names: seq[string]
    for i in 0 ..< d.boards.len:
      names.add d.artboardName(i) & "   " & $d.boards[i].r.w & " x " & $d.boards[i].r.h
    var sel = clamp(d.boardCur, 0, d.boards.high)
    let before = sel
    accessName(tr("Artboards"))
    listbox(names, sel, rows = max(3, min(10, (remainingH() - 3 * CtrlH - 3 * Gap) div ItemH)))
    if sel != before: goToBoard(d, sel)
    row([dp(48), -1]):
      label "Name:"
      boardNameField(d, sel)
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
  row:
    if button("Rearrange All...", w = dp(116), enabled = d.boards.len > 0): runCommand("Rearrange All Artboards...")
    if button("Options...", w = dp(80), enabled = has): runCommand("Artboard Options...")

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
        discard combo(["Grid by Row", "Grid by Column", "Arrange by Row", "Arrange by Column"], rearrDlg.layout,
                      w = dp(170))
      if rearrDlg.layout <= 1:
        field (if rearrDlg.layout == 0: "Columns:" else: "Rows:"):
          discard spin(rearrDlg.cols, 1, 100, w = dp(70))
      field "Spacing:":
        discard spin(rearrDlg.spacing, 0, 10000, w = dp(70))
    checkbox("Change to Right-to-Left Layout", rearrDlg.rtl)
    checkbox("Move Artwork with Artboard", rearrDlg.moveArt)
    paragraph(tr("In their order in the Artboards panel, from the first one's top left; the spacing in pixels."),
              color = ui.theme.gray)
    row:
      spring()
      if button("OK", isDefault = true, w = dp(80)): go = true
      if button("Cancel", w = dp(80)): rearrDlg.open = false
  if go:
    rearrDlg.open = false
    d.beginStep("Rearrange All Artboards")
    d.rearrangeArtboards(ArrangeLayout(clamp(rearrDlg.layout, 0, 3)), rearrDlg.cols, rearrDlg.spacing,
                         rearrDlg.rtl, rearrDlg.moveArt)
    d.endStep()
    fitAllBoards(d)

proc artboardsDialogs() =
  rearrangeDialog()

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
                                 "Previous Artboard"]
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
    else: result = false
