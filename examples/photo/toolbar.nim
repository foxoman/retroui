# Retro Atelier -- included by photo.nim
#
# The toolbar as today's editors have it today: one column (two with the arrows at
# its top), the tools in groups -- a group shows the one last used, a small
# triangle when it holds more; holding it down (or a right click, a long
# press) opens the group, its tools with their names and keys. A letter
# picks the group, Shift and the letter the next tool in it. "..." holds
# the groups taken off (Edit Toolbar). At the bottom: the colors, Quick
# Mask, the screen modes. (Drawn as a 1994 toolbox: raised buttons, the
# tool down.)

type
  ModeVar = enum
    ## (which of a tool's settings an item of a group sets)
    mvNone, mvMarquee, mvLasso, mvWand, mvHeal, mvBrush, mvStamp, mvPattern, mvHistory, mvBlur,
    mvDodge, mvPen, mvType, mvShape, mvDrop, mvErase, mvCrop, mvMove, mvHand, mvVector, mvFrame
  ToolItem = object
    name: string             ## "Rectangular Marquee Tool"
    tool: Tool
    mv: ModeVar
    mode: int
    glyph: string
  ToolGroup = object
    name: string             ## (Edit Toolbar)
    key: char                ## the usual letter
    items: seq[ToolItem]

proc ti(name: string; t: Tool; glyph: string; mv = mvNone; mode = 0): ToolItem =
  ToolItem(name: name, tool: t, mv: mv, mode: mode, glyph: glyph)

let toolGroups = @[
  ToolGroup(name: "Move", key: 'V', items: @[ti("Move Tool", tMove, pxMoveTool, mvMove, 0),
                                              ti("Artboard Tool", tMove, pxNew, mvMove, 1)]),
  ToolGroup(name: "Marquee", key: 'M', items: @[
    ti("Rectangular Marquee Tool", tMarquee, pxMarqueeRect, mvMarquee, 0),
    ti("Elliptical Marquee Tool", tMarquee, pxMarqueeEllipse, mvMarquee, 1),
    ti("Single Row Marquee Tool", tMarquee, pxMarqueeRow, mvMarquee, 2),
    ti("Single Column Marquee Tool", tMarquee, pxMarqueeColumn, mvMarquee, 3)]),
  ToolGroup(name: "Lasso", key: 'L', items: @[
    ti("Lasso Tool", tLasso, pxLasso, mvLasso, 0),
    ti("Polygonal Lasso Tool", tLasso, pxPolyLasso, mvLasso, 1),
    ti("Magnetic Lasso Tool", tLasso, pxLasso, mvLasso, 2)]),
  ToolGroup(name: "Selection", key: 'W', items: @[
    ti("Object Selection Tool", tWand, pxObjectSelect, mvWand, 2),
    ti("Quick Selection Tool", tWand, pxQuickSelect, mvWand, 1),
    ti("Selection Brush Tool", tWand, pxSelectionBrush, mvWand, 3),
    ti("Magic Wand Tool", tWand, pxMagicWand, mvWand, 0)]),
  ToolGroup(name: "Crop", key: 'C', items: @[
    ti("Crop Tool", tCrop, pxCrop, mvCrop, 0),
    ti("Perspective Crop Tool", tCrop, pxPerspCrop, mvCrop, 1),
    ti("Slice Tool", tCrop, pxSlice, mvCrop, 3),
    ti("Slice Select Tool", tCrop, pxSlice, mvCrop, 4)]),
  ToolGroup(name: "Frame", key: 'K', items: @[ti("Rectangle Frame Tool", tCrop, pxMarqueeRect, mvFrame, 0),
                                               ti("Ellipse Frame Tool", tCrop, pxMarqueeEllipse, mvFrame, 1),
                                               ti("Polygon Frame Tool", tCrop, pxPolygonShape, mvFrame, 2)]),
  ToolGroup(name: "Eyedropper", key: 'I', items: @[
    ti("Eyedropper Tool", tEyedropper, pxEyedropper, mvDrop, 0),
    ti("Color Sampler Tool", tEyedropper, pxSelect, mvDrop, 1),
    ti("Ruler Tool", tEyedropper, pxGuides, mvDrop, 2),
    ti("Note Tool", tEyedropper, pxNote, mvDrop, 3),
    ti("Count Tool", tEyedropper, pxCount, mvDrop, 4)]),
  ToolGroup(name: "Healing", key: 'J', items: @[
    ti("Spot Healing Brush Tool", tHeal, pxSpotHeal, mvHeal, 0),
    ti("Remove Tool", tHeal, pxRemoveTool, mvHeal, 3),
    ti("Healing Brush Tool", tHeal, pxHeal, mvHeal, 1),
    ti("Patch Tool", tHeal, pxPatch, mvHeal, 2),
    ti("Content-Aware Move Tool", tHeal, pxContentMove, mvHeal, 4),
    ti("Red Eye Tool", tRedEye, pxRedEye)]),
  ToolGroup(name: "Brush", key: 'B', items: @[
    ti("Brush Tool", tBrush, pxBrush, mvBrush, 0),
    ti("Pencil Tool", tPencil, pxPencil),
    ti("Color Replacement Tool", tBrush, pxColorReplace, mvBrush, 2),
    ti("Mixer Brush Tool", tBrush, pxMixerBrush, mvBrush, 1),
    ti("Adjustment Brush Tool", tBrush, pxAdjustBrush, mvBrush, 3),
    ti("Airbrush Tool", tAirbrush, pxAirbrush)]),
  ToolGroup(name: "Stamp", key: 'S', items: @[
    ti("Clone Stamp Tool", tStamp, pxStamp, mvStamp, 0),
    ti("Pattern Stamp Tool", tStamp, pxPatternStamp, mvPattern, 2)]),
  ToolGroup(name: "History Brush", key: 'Y', items: @[
    ti("History Brush Tool", tStamp, pxHistoryBrush, mvHistory, 1),
    ti("Art History Brush Tool", tStamp, pxArtHistory, mvHistory, 2)]),
  ToolGroup(name: "Eraser", key: 'E', items: @[
    ti("Eraser Tool", tEraser, pxEraser, mvErase, 0),
    ti("Background Eraser Tool", tEraser, pxBgEraser, mvErase, 2),
    ti("Magic Eraser Tool", tEraser, pxMagicWand, mvErase, 1),
    ti("Eraser Tool (Shapes)", tVector, pxBgEraser, mvVector, 8),
    ti("Scissors Tool", tVector, pxCut, mvVector, 9),
    ti("Knife Tool", tVector, pxSlice, mvVector, 10)]),
  ToolGroup(name: "Gradient", key: 'G', items: @[
    ti("Gradient Tool", tGradient, pxGradient),
    ti("Paint Bucket Tool", tBucket, pxBucket)]),
  ToolGroup(name: "Blur", key: 'R', items: @[
    ti("Blur Tool", tBlur, pxBlur, mvBlur, 0),
    ti("Sharpen Tool", tBlur, pxSharpen, mvBlur, 1),
    ti("Smudge Tool", tSmudge, pxSmudge)]),
  ToolGroup(name: "Dodge", key: 'O', items: @[
    ti("Dodge Tool", tDodge, pxDodge, mvDodge, 0),
    ti("Burn Tool", tDodge, pxBurn, mvDodge, 1),
    ti("Sponge Tool", tDodge, pxSponge, mvDodge, 2)]),
  ToolGroup(name: "Pen", key: 'P', items: @[
    ti("Pen Tool", tPen, pxPen, mvPen, 1),
    ti("Freeform Pen Tool", tPen, pxFreeformPen, mvPen, 6),
    ti("Curvature Pen Tool", tPen, pxCurvaturePen, mvPen, 7),
    ti("Content-Aware Tracing Tool", tPen, pxContentTrace, mvPen, 8),
    ti("Add Anchor Point Tool", tPen, pxPenAdd, mvPen, 2),
    ti("Delete Anchor Point Tool", tPen, pxPenRemove, mvPen, 3),
    ti("Convert Point Tool", tPen, pxConvertPoint, mvPen, 4)]),
  ToolGroup(name: "Type", key: 'T', items: @[
    ti("Horizontal Type Tool", tType, pxTypeTool, mvType, 0),
    ti("Vertical Type Tool", tType, pxTypeTool, mvType, 2),
    ti("Vertical Type Mask Tool", tType, pxTypeMask, mvType, 3),
    ti("Horizontal Type Mask Tool", tType, pxTypeMask, mvType, 1)]),
  ToolGroup(name: "Path Selection", key: 'A', items: @[
    ti("Path Selection Tool", tPen, pxPathSelect, mvPen, 5),
    ti("Direct Selection Tool", tPen, pxPathArrow, mvPen, 0),
    ti("Group Selection Tool", tVector, pxPathSelect, mvVector, 0),
    ti("Magic Wand Tool (Shapes)", tVector, pxMagicWand, mvVector, 1),
    ti("Lasso Tool (Points)", tVector, pxPolyLasso, mvVector, 2)]),
  ToolGroup(name: "Paintbrush (Vector)", key: 'N', items: @[
    ti("Paintbrush Tool (Vector)", tVector, pxBrush, mvVector, 3),
    ti("Blob Brush Tool", tVector, pxPaint, mvVector, 4),
    ti("Smooth Tool", tVector, pxCurvaturePen, mvVector, 5),
    ti("Path Eraser Tool", tVector, pxEraser, mvVector, 6),
    ti("Join Tool", tVector, pxConvertPoint, mvVector, 7)]),
  ToolGroup(name: "Width", key: ' ', items: @[
    ti("Width Tool", tVector, pxWarp, mvVector, 11),
    ti("Mesh Tool", tVector, pxGrid, mvVector, 12),
    ti("Perspective Selection Tool", tVector, pxPerspCrop, mvVector, 13),
    ti("Shape Builder Tool", tVector, pxBucket, mvVector, 14)]),
  ToolGroup(name: "Shape", key: 'U', items: @[
    ti("Rectangle Tool", tShape, pxRectShape, mvShape, 0),
    ti("Rounded Rectangle Tool", tShape, pxRoundRectShape, mvShape, 1),
    ti("Ellipse Tool", tShape, pxEllipseShape, mvShape, 2),
    ti("Triangle Tool", tShape, pxPolygonShape, mvShape, 8),
    ti("Polygon Tool", tShape, pxPolygonShape, mvShape, 3),
    ti("Line Tool", tShape, pxLineTool, mvShape, 4),
    ti("Star Tool", tShape, pxStarShape, mvShape, 6),
    ti("Spiral Tool", tShape, pxSpiral, mvShape, 7),
    ti("Arc Tool", tShape, pxSpiral, mvShape, 9),
    ti("Rectangular Grid Tool", tShape, pxGrid, mvShape, 10),
    ti("Polar Grid Tool", tShape, pxEllipseShape, mvShape, 11),
    ti("Flare Tool", tShape, pxStar, mvShape, 12),
    ti("Custom Shape Tool", tShape, pxCustomShape, mvShape, 5)]),
  ToolGroup(name: "Hand", key: 'H', items: @[ti("Hand Tool", tHand, pxHandTool, mvHand, 0),
                                              ti("Rotate View Tool", tHand, pxRotateView, mvHand, 1)]),
  ToolGroup(name: "Zoom", key: 'Z', items: @[ti("Zoom Tool", tZoom, pxZoomTool)])]
  ## The tools, grouped as the usual toolbar groups them (with its keys).

var
  groupShown = newSeq[int](toolGroups.len)   ## the tool each group shows (the one used last)
  toolFly = -1                   ## the group whose tools are open beside it (-1: none; -2: "...")
  toolPress: tuple[g, at: int; opened: bool]   ## a group's button held down
  polyLasso: tuple[on: bool; dw: DocWin; pts: seq[(float, float)]; op: SelOp]
    ## the Polygonal Lasso's corners clicked so far

proc modeOf(mv: ModeVar): int =
  case mv
  of mvNone: 0
  of mvMarquee: marqueeShape
  of mvLasso: lassoMode
  of mvWand: wandMode
  of mvHeal: healMode
  of mvBrush: brushTool
  of mvStamp: (if stampTool == 0 and stampMode notin {2, 3}: 0 else: -1)
  of mvPattern: (if stampTool == 0 and stampMode in {2, 3}: 2 else: -1)
  of mvHistory: stampTool
  of mvBlur: blurMode
  of mvDodge: dodgeMode
  of mvPen: penMode
  of mvType: ord(typeMaskMode) + (if typeVertical: 2 else: 0)
  of mvShape: shapeKind
  of mvDrop: dropKind
  of mvErase: eraseKind
  of mvCrop: cropKind
  of mvMove: moveKind
  of mvHand: handKind
  of mvVector: vecMode
  of mvFrame: (if cropKind == 2: frameShape else: -1)

proc itemOn(it: ToolItem): bool =
  ## (the tool in use is this one)
  tool == it.tool and (it.mv == mvNone or modeOf(it.mv) == it.mode)

proc groupOf(t: Tool): int =
  ## (the group showing the tool in use; -1 none)
  for g, grp in toolGroups:
    for it in grp.items:
      if itemOn(it): return g
  -1

proc shownItem(g: int): int =
  ## (the tool a group's button shows: the one in use, else the last used)
  for k, it in toolGroups[g].items:
    if itemOn(it): return k
  clamp(groupShown[g], 0, toolGroups[g].items.high)

proc pickTool(g, k: int) =
  ## Chooses tool `k` of group `g` (and remembers it for the group).
  let it = toolGroups[g].items[k]
  groupShown[g] = k
  selectTool(it.tool)
  case it.mv
  of mvNone: discard
  of mvMarquee: marqueeShape = it.mode
  of mvLasso: lassoMode = it.mode
  of mvWand: wandMode = it.mode
  of mvHeal: healMode = it.mode
  of mvMove: moveKind = it.mode
  of mvHand: handKind = it.mode
  of mvBrush: brushTool = it.mode
  of mvStamp:
    stampTool = 0
    if stampMode in {2, 3}: stampMode = 0
  of mvPattern:
    stampTool = 0
    if stampMode notin {2, 3}: stampMode = 2
  of mvHistory: stampTool = it.mode
  of mvBlur: blurMode = it.mode
  of mvDodge: dodgeMode = it.mode
  of mvPen: penMode = it.mode
  of mvType:
    typeMaskMode = it.mode in {1, 3}
    typeVertical = it.mode >= 2
  of mvShape: shapeKind = it.mode
  of mvDrop: dropKind = it.mode
  of mvErase: eraseKind = it.mode
  of mvCrop:
    if cropKind != it.mode: pendingCrop.on = false
    cropKind = it.mode
  of mvVector: vecMode = it.mode
  of mvFrame:
    if cropKind != 2: pendingCrop.on = false
    cropKind = 2
    frameShape = it.mode
  status = ""

proc groupHidden(g: int): bool = ("," & toolGroups[g].name & ",") in ("," & prefs.toolHidden & ",")

proc toolKeyPressed(k: KeyCode; shift: bool): bool =
  ## the usual letters: a group's tool; with Shift, the next tool of the
  ## group. True when a group took it. (R: Rotate View, as today's
  ## today's editors have it -- Shift+R the Blur tools; the 1994 keys: R the Blur
  ## tools.)
  if k == KeyR and not shift and prefs.keySet == 0:
    for g, grp in toolGroups:
      if grp.name == "Hand":
        pickTool(g, 1)
        return true
  for g, grp in toolGroups:
    if grp.key in {'A' .. 'Z'} and k == KeyCode(ord(KeyA) + ord(grp.key) - ord('A')):
      let cur = shownItem(g)
      if shift and grp.items.len > 1 and groupOf(tool) == g:
        pickTool(g, (cur + 1) mod grp.items.len)
      else: pickTool(g, cur)
      return true
  false

proc toolCell(): (int, int) = (dp(27), dp(25))

proc toolColumns(): int =
  ## Two columns (the usual, side by side), or one (the arrows at its top);
  ## a third when the screen is too short for two.
  let (_, ch) = toolCell()
  var n = 1
  for g in 0 ..< toolGroups.len:
    if not groupHidden(g): inc n
  let room = ui.h - MenuH - CtrlH - dp(190)        # (the menus, the options bar, the colors, the modes)
  let want = if prefs.toolCols == 1: 1 else: 2
  for cols in want .. 3:
    if ((n + cols - 1) div cols) * ch <= room: return cols
  3

var toolboxBodyH = 0              ## (the toolbar's tools, colors and modes: as tall as they came out)

proc toolboxSize(): (int, int) =
  ## The toolbar's size: its header (as the docked panels'), the tools in
  ## one column or two, the colors, the modes, a frame round them.
  let (cw, ch) = toolCell()
  let cols = toolColumns()
  var n = 1                                   # (with "...")
  for g in 0 ..< toolGroups.len:
    if not groupHidden(g): inc n
  let rows = (n + cols - 1) div cols
  let colorH = if cols >= 2: dp(44) else: cw
  let modesH = 2 * (ch + 1)
  let body = if toolboxBodyH > 0: toolboxBodyH
             else: rows * ch + 1 + dp(4) + colorH + dp(4) + modesH + 6 * Gap
  (cols * cw + 1 + 2 * dp(3) + 2, 1 + panelHeaderH() + dp(3) + body + dp(3) + 1)

proc finishPolyLasso(ok: bool) =
  ## The Polygonal Lasso's corners made a selection (or let go).
  if not polyLasso.on: return
  polyLasso.on = false
  let dw = polyLasso.dw
  if ok and polyLasso.pts.len >= 3 and dw in docs:
    let d = dw.doc
    var m = d.polygonMask(polyLasso.pts, lassoAA)
    drag.op = polyLasso.op
    finishSelection(d, m, lassoFeather, "Polygonal Lasso")
  polyLasso.pts.setLen(0)

proc magneticLive(dw: DocWin; tx, ty: float): seq[(float, float)] =
  ## (the Magnetic Lasso's side from its last point to `tx`, `ty`, along the
  ## edges -- worked out again only when they moved)
  let a = polyLasso.pts[^1]
  let key = $a & "/" & $(int(tx), int(ty)) & "/" & $magWidth & "/" & $magContrast & "/" & $dw.doc.ver
  if magLive.key != key:
    magLive = (key, dw.doc.magneticPath(a[0], a[1], tx, ty, magWidth, magContrast))
  magLive.pts

proc at45(x0, y0, x, y: float): (float, float) =
  ## (`x`, `y` put on the line from `x0`, `y0` at the nearest 45 degrees:
  ## Shift with the Polygonal Lasso, the Gradient, the Line)
  let a = round(arctan2(y - y0, x - x0) / (PI / 4)) * (PI / 4)
  let l = hypot(x - x0, y - y0)
  (x0 + l * cos(a), y0 + l * sin(a))

proc polyLassoOn(dw: DocWin): bool =
  ## (a Polygonal or Magnetic Lasso being drawn on `dw`)
  polyLasso.on and polyLasso.dw == dw

proc polyLassoClick(dw: DocWin; ev: PhotoEvent; op: SelOp) =
  ## A click with the Polygonal Lasso: a corner; on the first corner (or a
  ## double-click) the selection is made. (The Magnetic Lasso: the side
  ## along the edges to the click; Alt+click: a straight one.)
  var p = (ev.x, ev.y)
  if polyLasso.on and polyLasso.dw == dw and ev.shift and lassoMode == 1 and polyLasso.pts.len > 0:
    p = at45(polyLasso.pts[^1][0], polyLasso.pts[^1][1], ev.x, ev.y)     # (Shift: at 45 degrees)
  if not polyLasso.on or polyLasso.dw != dw:
    polyLasso = (true, dw, @[p], op)
    magLive.key = ""
    return
  let first = polyLasso.pts[0]
  let (fx, fy) = dw.view.toScreen(dw.doc, first[0], first[1])
  let closing = polyLasso.pts.len >= 3 and abs(fx - ui.mx) <= dp(6) and abs(fy - ui.my) <= dp(6)
  if lassoMode == 2 and not ev.alt:
    let side = dw.magneticLive(if closing: first[0] else: ev.x, if closing: first[1] else: ev.y)
    for i in 1 ..< side.len: polyLasso.pts.add side[i]
  if ev.clicks >= 2 or closing:
    finishPolyLasso(true)
  elif not (lassoMode == 2 and not ev.alt):
    polyLasso.pts.add p

proc polyLassoOverlay(dw: DocWin; ev: PhotoEvent) =
  ## (its sides so far, and the one to the mouse)
  if not polyLasso.on or polyLasso.dw != dw: return
  let d = dw.doc
  let v = dw.view
  for i in 1 ..< polyLasso.pts.len:
    let (a, b) = v.toScreen(d, polyLasso.pts[i - 1][0], polyLasso.pts[i - 1][1])
    let (c, e) = v.toScreen(d, polyLasso.pts[i][0], polyLasso.pts[i][1])
    dashedLine(a, b, c, e)
  if ev.over and polyLasso.pts.len > 0 and lassoMode == 2 and AltPressed notin ui.mods:
    # (the Magnetic Lasso: its side along the edges to the mouse; long
    # enough, a point is put down by itself, as the usual)
    let side = dw.magneticLive(ev.x, ev.y)
    for i in 1 ..< side.len:
      let (a, b) = v.toScreen(d, side[i - 1][0], side[i - 1][1])
      let (c, e) = v.toScreen(d, side[i][0], side[i][1])
      dashedLine(a, b, c, e)
    var length = 0.0
    for i in 1 ..< side.len: length += hypot(side[i][0] - side[i - 1][0], side[i][1] - side[i - 1][1])
    let every = (120 - magFrequency).float * 1.2 / max(0.05, v.scaleOf)
    if magFrequency > 0 and length > every and side.len > 4:
      for i in 1 .. side.len * 2 div 3: polyLasso.pts.add side[i]
      magLive.key = ""
  elif ev.over and polyLasso.pts.len > 0:
    let (a, b) = v.toScreen(d, polyLasso.pts[^1][0], polyLasso.pts[^1][1])
    if ShiftPressed in ui.mods and lassoMode == 1:
      let (qx, qy) = at45(polyLasso.pts[^1][0], polyLasso.pts[^1][1], ev.x, ev.y)
      let (c, e) = v.toScreen(d, qx, qy)
      dashedLine(a, b, c, e)
    else: dashedLine(a, b, ui.mx, ui.my)
    if polyLasso.pts.len >= 3:
      # (over the first corner: a ring, it closes there)
      let (fx, fy) = v.toScreen(d, polyLasso.pts[0][0], polyLasso.pts[0][1])
      if abs(fx - ui.mx) <= dp(6) and abs(fy - ui.my) <= dp(6):
        ellipseOnScreen(fx - dp(4), fy - dp(4), fx + dp(4), fy + dp(4), color(0, 0, 0))

proc polyLassoKeys(): bool =
  ## Enter closes it, Esc lets it go, Backspace takes the last corner back.
  if not polyLasso.on: return false
  case ui.key
  of KeyEnter:
    finishPolyLasso(true)
  of KeyEsc:
    finishPolyLasso(false)
  of KeyBackspace, KeyDelete:
    if polyLasso.pts.len > 1: polyLasso.pts.setLen(polyLasso.pts.len - 1)
    else: finishPolyLasso(false)
  else: return false
  ui.keyUsed = true
  true

proc toolFace(cr: Rect; glyph: string; down, on, more: bool) =
  ## (a tool's button: raised, or down with the 1994 checker when chosen;
  ## a small triangle at its corner when its group holds more)
  buttonFace(cr, down or on, bevel = 1)
  if on and not down: checker(inset(cr, 2), ui.theme.light)
  let ic = glyphIcon(glyph, ui.theme.text, dp(16))
  let o = if on or down: 1 else: 0
  image(cr.x + (cr.w - ic.w) div 2 + o, cr.y + (cr.h - ic.h) div 2 + o, ic)
  if more:
    let s = max(3, dp(4))
    let x1 = cr.x + cr.w - 3 + o
    let y1 = cr.y + cr.h - 3 + o
    polygon(@[(x1.float, (y1 - s).float), (x1.float, y1.float), ((x1 - s).float, y1.float)], ui.theme.text)

proc toolboxContent()

proc toolboxBody() =
  ## The toolbar, docked at the left edge: a frame, the header strip of the
  ## docked panels (its arrows: one column or two), then the tools.
  let cols = toolColumns()
  let a = mdiAreaRect("ws")
  let whole = rect(a.x + toolbox.r.x, a.y + toolbox.r.y, toolbox.r.w, toolbox.r.h)
  fill(whole, ui.theme.face)
  box(whole, ui.theme.frame)
  let hr = rect(whole.x + 1, whole.y + 1, whole.w - 2, panelHeaderH())
  if panelHeader(hr, idOf("toolcols"), (if cols == 1: dRight else: dLeft),
                 (if cols == 1: "Two Columns" else: "One Column"), hsLeft):
    prefs.toolCols = if cols == 1: 2 else: 1
    toolboxBodyH = 0
    let (tw, th2) = toolboxSize()
    toolbox.r.w = tw
    toolbox.r.h = th2
    savePrefs()
  let m = dp(3)
  pushFrame(rect(whole.x + 1 + m, hr.y + hr.h + m, whole.w - 2 - 2 * m, 0))
  toolboxContent()
  let used = popFrame()
  if used > 0 and used != toolboxBodyH:
    toolboxBodyH = used
    ui.redraw = true

proc toolboxContent() =
  let (cw, ch) = toolCell()
  let cols = toolColumns()
  var shown: seq[int]
  for g in 0 ..< toolGroups.len:
    if not groupHidden(g): shown.add g
  shown.add -2                                  # ("...")
  let rows = (shown.len + cols - 1) div cols
  let r = place(cols * cw + 1, rows * ch + 1)
  fill(r, ui.theme.face)
  let cur = groupOf(tool)
  for idx, g in shown:
    let cr = rect(r.x + (idx mod cols) * cw, r.y + (idx div cols) * ch, cw + 1, ch + 1)
    if g == -2:
      # "...": the groups taken off, Edit Toolbar
      let hit = interact(idOf("tool:more"), cr, focusable = false)
      toolFace(cr, pxMoreTools, hit.down, false, false)
      tooltip("More tools, Edit Toolbar...")
      if hit.clicked or (hit.hover and ui.rpressed):
        toolFly = -2
        openPopupMenu("toolfly", cr.x + cr.w + 1, cr.y)
      continue
    let grp = toolGroups[g]
    let k = shownItem(g)
    let it = grp.items[k]
    let hit = interact(idOf("tool:" & grp.name), cr, focusable = false)
    toolFace(cr, it.glyph, hit.down, cur == g, grp.items.len > 1)
    # the usual tooltip: the tool's name and its key
    tooltip(it.name & (if grp.key in {'A' .. 'Z'}: " (" & grp.key & ")" else: ""))
    if hit.down and ui.pressed:
      toolPress = (g, ui.now, false)
      if AltPressed in ui.mods and grp.items.len > 1:
        # (Alt+click: the next tool of the group, as is usual)
        pickTool(g, (k + 1) mod grp.items.len)
        toolPress.opened = true
      elif ui.clicks >= 2:
        # double-click: the tool's options (and for some, an action)
        pickTool(g, k)
        showPanel("options")
        case it.tool
        of tHand:
          if active != nil:
            if handKind == 1: active.view.angle = 0       # (Rotate View: straight again)
            else: active.view.fit(active.doc)
        of tZoom:
          if active != nil: active.view.setZoom(active.doc, 1)
        else: discard
        toolPress.opened = true
    if hit.down and toolPress.g == g and not toolPress.opened and grp.items.len > 1:
      # held down: the group opens beside it
      if ui.now - toolPress.at >= 350:
        toolPress.opened = true
        toolFly = g
        openPopupMenu("toolfly", cr.x + cr.w + 1, cr.y)
      else: wakeIn(60)
    if hit.hover and ui.rpressed and grp.items.len > 1:
      toolFly = g
      openPopupMenu("toolfly", cr.x + cr.w + 1, cr.y)
    if hit.clicked and not toolPress.opened: pickTool(g, k)
  # the group's tools, each with its name and key
  popupMenu("toolfly"):
    if toolFly >= 0 and toolFly < toolGroups.len:
      let grp = toolGroups[toolFly]
      for k, it in grp.items:
        if menuItem(it.glyph & "  " & it.name, (if grp.key in {'A' .. 'Z'}: $grp.key else: ""), checked = itemOn(it)): pickTool(toolFly, k)
    elif toolFly == -2:
      var any = false
      for g, grp in toolGroups:
        if not groupHidden(g): continue
        for k, it in grp.items:
          any = true
          if menuItem(it.glyph & "  " & it.name, (if grp.key in {'A' .. 'Z'}: $grp.key else: ""), checked = itemOn(it)): pickTool(g, k)
      if any: menuSeparator()
      if menuItem("Edit Toolbar..."): editToolbarOpen = true
      if menuItem("One Column", checked = cols == 1):
        prefs.toolCols = 1
        savePrefs()
      if menuItem("Two Columns", checked = cols == 2):
        prefs.toolCols = 2
        savePrefs()
  space(dp(4))
  # the colors: the foreground over the background (small in one column)
  row:
    if cols >= 2: space(dp(6))
    case colorPair(fg, bg, if cols >= 2: dp(44) else: cw - dp(1))
    of cpFg:
      showFgPicker = true
    of cpBg:
      showBgPicker = true
    of cpSwap: swap(fg, bg)
    of cpDefault:
      fg = black
      bg = white
    else: discard
  space(dp(4))
  let qm = cur() != nil and cur().quickMask
  if cols >= 2:
    # the two mask modes, the three screen modes: buttons side by side
    proc strip(n: int; glyphs: openArray[string]; tips: openArray[string]; on: proc (k: int): bool): int =
      result = -1
      let w = cols * cw + 1
      let r = place(w, ch + 1)
      for k in 0 ..< n:
        let x0 = r.x + k * w div n
        let x1 = r.x + (k + 1) * w div n
        let br = rect(x0, r.y, x1 - x0 + (if k < n - 1: 1 else: 0), ch + 1)
        let hit = interact(idOf("strip:" & tips[k]), br, focusable = false)
        toolFace(br, glyphs[k], hit.down, on(k), false)
        tooltip(tips[k])
        if hit.clicked: result = k
        if hit.down and ui.pressed and ui.clicks >= 2: result = 10 + k    # (a double-click)
    let m = strip(2, [pxStandardMode, pxQuickMask], ["Standard mode (Q)", "Quick Mask mode (Q)"],
                  proc (k: int): bool = (k == 1) == qm)
    if m >= 10: startQuickMaskOptions()
    elif m >= 0 and cur() != nil:
      if m == 1: cur().enterQuickMask() else: cur().leaveQuickMask()
    let sm = strip(3, [pxScreenWindow, pxScreenFullMenu, pxScreenFull],
                   ["Standard screen mode (F)", "Full screen with menu bar (F)", "Full screen (F)"],
                   proc (k: int): bool = k == screenMode)
    if sm >= 0:
      screenMode = sm mod 10
      if active != nil: active.win.maximized = screenMode > 0
  else:
    # one column: Quick Mask on and off; the screen mode, its others when held
    let qr = place(cw + 1, ch + 1)
    let qh = interact(idOf("tool:quickmask"), qr, focusable = false)
    toolFace(qr, if qm: pxQuickMask else: pxStandardMode, qh.down, qm, false)
    tooltip(if qm: "Edit in Standard mode (Q)" else: "Edit in Quick Mask mode (Q)")
    if qh.down and ui.pressed and ui.clicks >= 2: startQuickMaskOptions()
    elif qh.clicked and cur() != nil:
      if qm: cur().leaveQuickMask() else: cur().enterQuickMask()
    let sr = place(cw + 1, ch + 1)
    let sh = interact(idOf("tool:screen"), sr, focusable = false)
    toolFace(sr, [pxScreenWindow, pxScreenFullMenu, pxScreenFull][clamp(screenMode, 0, 2)], sh.down, false, true)
    tooltip("Change Screen Mode (F)")
    if sh.clicked or (sh.hover and ui.rpressed):
      openPopupMenu("screenfly", sr.x + sr.w + 1, sr.y)
    popupMenu("screenfly"):
      for k, (g, n) in [(pxScreenWindow, "Standard Screen Mode"), (pxScreenFullMenu, "Full Screen Mode With Menu Bar"),
                        (pxScreenFull, "Full Screen Mode")]:
        if menuItem(g & "  " & n, "F", checked = screenMode == k):
          screenMode = k
          if active != nil: active.win.maximized = screenMode > 0

proc editToolbarDialog() =
  ## Edit Toolbar: which groups the toolbar shows (the others under "...").
  if not editToolbarOpen: return
  dialog(editToolbarOpen, "Customize Toolbar", 420):
    label("Drag nothing, tick what shows; the rest is under \"...\" at the bottom.", color = ui.theme.gray)
    var hidden: seq[string]
    for g, grp in toolGroups:
      var showIt = not groupHidden(g)
      row:
        if checkbox(grp.items[shownItem(g)].glyph & "  " & grp.name & (if grp.key in {'A' .. 'Z'}: " (" & grp.key & ")" else: ""), showIt):
          discard
      if not showIt: hidden.add grp.name
    let now = hidden.join(",")
    if now != prefs.toolHidden:
      prefs.toolHidden = now
      let (tw, th2) = toolboxSize()
      toolbox.r.w = tw
      toolbox.r.h = th2
    row:
      if button("Restore Defaults", w = dp(130)):
        prefs.toolHidden = ""
        prefs.toolCols = 2
        let (tw, th2) = toolboxSize()
        toolbox.r.w = tw
        toolbox.r.h = th2
      spring()
      if button("Done", isDefault = true, w = dp(80)):
        editToolbarOpen = false
        savePrefs()
