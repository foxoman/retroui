# (included by photo.nim) The "pro" parts of Retro Atelier: aligning and
# distributing layers, Smart Objects, the History, Actions, Navigator and
# Properties palettes, guides and the grid.

var navThumb: tuple[key: string; b: Bitmap]

proc actionsMenu()
proc actionsBody(d: Doc)
proc propertiesBody(d: Doc)
proc quickActions(d: Doc): seq[(string, string)]

var
  alignToKind = atSelection          ## what Align lines layers up with (the key object: the current layer)
  spacingPx = 20'f32                 ## Distribute Spacing's room between them, pixels

proc alignNow(d: Doc; how: AlignHow) =
  ## (the picked layers lined up as Align To says)
  let idxs = d.pickedLayers
  let to = d.alignBox(idxs, alignToKind, d.current)
  d.layersChange("Align " & $how): d.alignLayers(idxs, how, to)

proc layoutModesOverlay(dw: DocWin) =
  ## (Isolation Mode: the rest washed out, a strip naming what is isolated; the key object
  ## outlined thick; Draw Behind or Inside said at the canvas's corner)
  let d = dw.doc
  let v = dw.view
  proc scr(x0, y0, x1, y1: float): Rect =
    let (a, b) = v.toScreen(d, x0, y0)
    let (c, e) = v.toScreen(d, x1, y1)
    rect(min(a, c), min(b, e), max(1, abs(c - a)), max(1, abs(e - b)))
  if d.isolated.len > 0:
    var keep: seq[Rect]
    for L in d.layers:
      if L.visible and not L.group and d.inIsolation(L):
        let b = d.objectBox(L)
        if b.ok: keep.add scr(b.x0, b.y0, b.x1, b.y1)
    let wash = color(255, 255, 255, 150)
    for L in d.layers:
      if not L.visible or L.group or d.inIsolation(L): continue
      let b = if L.background: (ok: true, x0: 0.0, y0: 0.0, x1: d.w.float, y1: d.h.float) else: d.objectBox(L)
      if not b.ok: continue
      # (what is isolated is not washed, where it is: the rest of the box in up to four pieces)
      var parts = @[scr(b.x0, b.y0, b.x1, b.y1)]
      for k in keep:
        var next: seq[Rect]
        for p in parts:
          let i = intersect(p, k)
          if i.w <= 0 or i.h <= 0:
            next.add p
            continue
          if i.y > p.y: next.add rect(p.x, p.y, p.w, i.y - p.y)
          if i.y + i.h < p.y + p.h: next.add rect(p.x, i.y + i.h, p.w, p.y + p.h - i.y - i.h)
          if i.x > p.x: next.add rect(p.x, i.y, i.x - p.x, i.h)
          if i.x + i.w < p.x + p.w: next.add rect(i.x + i.w, i.y, p.x + p.w - i.x - i.w, i.h)
        parts = next
      for p in parts: fill(p, wash)
    let nm = block:
      var s = ""
      for L in d.layers:
        if L.uid != 0 and L.uid in d.isolated and (s.len == 0 or L.group): s = L.name
      s
    let t = tr("Isolation Mode: ") & nm & tr(" (Esc leaves)")
    let r = rect(v.view.x + dp(6), v.view.y + dp(6), textWidth(t) + dp(12), FontH + dp(8))
    fill(r, color(255, 255, 210))
    box(r, color(120, 120, 80))
    text(r.x + dp(6), r.y + dp(4), t, color(40, 40, 20))
  if alignToKind == atKeyObject and d.pickedLayers.len >= 2 and d.current.picked:
    let b = d.objectBox(d.current)
    if b.ok:
      box(scr(b.x0, b.y0, b.x1, b.y1), color(0, 90, 220), dp(3))
  if d.drawMode != dmNormal:
    let t = tr($d.drawMode)
    let r = rect(v.view.x + v.view.w - textWidth(t) - dp(18), v.view.y + dp(6), textWidth(t) + dp(12), FontH + dp(8))
    fill(r, color(220, 235, 255))
    box(r, color(60, 90, 140))
    text(r.x + dp(6), r.y + dp(4), t, color(20, 40, 80))

proc spaceNow(d: Doc; horizontal: bool) =
  ## (Distribute Spacing: the picked layers `spacingPx` apart, out from the key object)
  if d == nil or d.pickedLayers.len < 2: return
  d.layersChange("Distribute Spacing"):
    d.distributeSpacing(d.pickedLayers, spacingPx, horizontal, (if alignToKind == atKeyObject: d.current else: nil))

proc alignItems(d: Doc) =
  ## Layer > Align: the picked layers lined up (with the selection when
  ## there is one; one layer alone: with the canvas), the key object or the artboard.
  let some = d != nil and not d.current.background
  for (how, icon) in [(alTop, pxAlignEdgeTop), (alVCenter, pxAlignEdgeVCenter), (alBottom, pxAlignEdgeBottom),
                      (alLeft, pxAlignEdgeLeft), (alHCenter, pxAlignEdgeHCenter), (alRight, pxAlignEdgeRight)]:
    if menuItem(icon & " " & $how, enabled = some): d.alignNow(how)
  menuSeparator()
  for k in AlignTo:
    if menuItem($k, checked = alignToKind == k): alignToKind = k

proc distributeItems(d: Doc) =
  ## Layer > Distribute: three or more picked layers spaced evenly; two or more a set room apart.
  let some = d != nil and d.pickedLayers.len >= 3
  for how in DistributeHow:
    if menuItem($how, enabled = some):
      d.layersChange("Distribute " & $how): d.distributeLayers(d.pickedLayers, how)
  menuSeparator()
  let two = d != nil and d.pickedLayers.len >= 2
  if menuItem("Distribute Spacing Across", enabled = two): d.spaceNow(true)
  if menuItem("Distribute Spacing Down", enabled = two): d.spaceNow(false)

# ---- the History palette -----------------------------------------------------------------------------------

var histPick: tuple[snap: bool; idx: int] = (false, -1)  ## the row last clicked

proc historyBody(d: Doc) =
  if d == nil:
    label("(no image)", color = ui.theme.gray)
    return
  let rowH = dp(22)
  let states = d.historyStates
  let at = d.historyAt
  if histSource.snap and histSource.idx >= d.snapshots.len: histSource = (false, 0)
  if not histSource.snap and histSource.idx >= states.len: histSource = (false, 0)
  let n = d.snapshots.len + states.len
  let listH = max(rowH, remainingH() - (CtrlH + 1) - Gap - 1)
  beginScroll(listH, "histlist")
  let r = place(available(), max(rowH, n * rowH + dp(3)))
  fill(r, ui.theme.window)
  let srcW = dp(20)
  var y = r.y
  var clicked = -1
  var srcClicked = -1
  let hid = idOf("historyrows")
  let hit = interact(hid, r, focusable = false)
  for k in 0 ..< n:
    let snap = k < d.snapshots.len
    let i = if snap: k else: k - d.snapshots.len
    let rr = rect(r.x, y, r.w, rowH)
    let sc = rect(rr.x, rr.y, srcW, rowH)
    fill(sc, ui.theme.face)
    vline(sc.x + sc.w, rr.y, rowH, ui.theme.shadow)
    if histSource.snap == snap and histSource.idx == i:
      image(sc.x + (sc.w - dp(16)) div 2, sc.y + (rowH - dp(16)) div 2,
            glyphIcon(pxHistoryBrush, ui.theme.text, dp(16)))
    let body = rect(sc.x + srcW + 1, rr.y, rr.w - srcW - 1, rowH)
    let current = not snap and i == at
    let undone = not snap and i > at
    if current: fill(body, ui.theme.select)
    let fg = if current: ui.theme.selectText elif undone: ui.theme.gray else: ui.theme.text
    let icon = if snap: pxSnapshot elif i == 0: pxImage else: pxHistory
    image(body.x + dp(3), body.y + (rowH - dp(16)) div 2, glyphIcon(icon, fg, dp(16)))
    let name = if snap: d.snapshots[i].name elif i == 0 and not d.historyCut: d.name else: states[i]
    text(body.x + dp(23), body.y + (rowH - FontH) div 2, ellipsize(name, body.w - dp(26)), fg, current)
    hline(rr.x, rr.y + rowH - 1, rr.w, ui.theme.face)
    if hit.down and ui.pressed and mouseIn(rr):
      if mouseIn(sc): srcClicked = k else: clicked = k
    y += rowH
    if snap and k == d.snapshots.high:
      hline(r.x, y, r.w, ui.theme.text)
      y += dp(3)
  endScroll()
  if srcClicked >= 0:
    let snap = srcClicked < d.snapshots.len
    histSource = (snap, if snap: srcClicked else: srcClicked - d.snapshots.len)
  if clicked >= 0:
    let snap = clicked < d.snapshots.len
    let i = if snap: clicked else: clicked - d.snapshots.len
    histPick = (snap, i)
    if te.on: commitType()
    if snap:
      beginBusy("Snapshot")
      try: d.revertToSnapshot(i)
      finally: endBusy()
    elif i != at:
      beginBusy(if i < at: "Undo" else: "Redo")
      try: d.goToHistory(i)
      finally: endBusy()
  row:
    if toolButton(glyphIcon(pxSnapshot, ui.theme.text, dp(16)), "New Snapshot"):
      runCommand("New Snapshot")
    if toolButton(glyphIcon(pxNew, ui.theme.text, dp(16)), "New Document from the Image as It Is"):
      runCommand("New Document from State")
    if toolButton(glyphIcon(pxTrash, ui.theme.text, dp(16)), "Delete the Snapshot",
                  enabled = histPick.snap and histPick.idx < d.snapshots.len):
      d.deleteSnapshot(histPick.idx)
      if histSource.snap: histSource = (false, 0)
      histPick = (false, -1)

# ---- the Navigator --------------------------------------------------------------------------------------

proc navigatorBody(dw: DocWin) =
  if dw == nil:
    label("(no image)", color = ui.theme.gray)
    return
  let d = dw.doc
  let boxW = available()
  let boxH = max(dp(60), remainingH() - CtrlH - Gap - dp(2))
  # (a small copy of the image: from the zoomed-out copies, fast)
  let k = max(d.w.float / boxW.float / pxScale.float, d.h.float / boxH.float / pxScale.float)
  var level = 0
  while (1 shl (level + 1)).float <= k and level < 12: inc level
  # (while something is shown live the image is not made again for it)
  let (mp, mw, mh) = if d.live.len > 0 and navThumb.b != nil: (nil, 0, 0) else: d.mipLevel(level)
  let key = $d.ver & "/" & $level & "/" & $mw & "x" & $mh
  if (navThumb.key != key or navThumb.b == nil) and not (d.live.len > 0 and navThumb.b != nil):
    var src = newSeq[uint32](mw * mh)
    if mp != nil: copyMem(addr src[0], mp, src.len * 4)
    navThumb.b = thumbnailOf(src, mw, mh, boxW * pxScale, boxH * pxScale)
    navThumb.key = key
  let pb = pictureBox("navigator", navThumb.b, boxW - 2, boxH - 2)
  beginKeepSides(pb.box)           # (the view's box drawn over it as it is, right to left too)
  defer: endKeepSides()
  if pb.pic.w > 0:
    # the part shown: a red frame; a click or a drag shows another part
    let (vx, vy, vw, vh) = dw.view.visibleRect(d)
    let fx = pb.pic.x + int(vx / d.w.float * pb.pic.w.float)
    let fy = pb.pic.y + int(vy / d.h.float * pb.pic.h.float)
    let fw = max(3, int(vw / d.w.float * pb.pic.w.float))
    let fh = max(3, int(vh / d.h.float * pb.pic.h.float))
    pushClip(inset(pb.box, 1))
    box(rect(fx, fy, fw, fh), color(255, 0, 0))
    box(rect(fx + 1, fy + 1, fw - 2, fh - 2), color(255, 0, 0))
    popClip()
    if pb.dragging:
      let (ix, iy) = toPicture(pb.pic, d.w, d.h, ui.mx, ui.my)
      dw.view.centerOn(d, ix, iy)
  row([26, -1, 26, 52]):
    if toolButton(glyphIcon(pxZoomOut, ui.theme.text, dp(16)), "Zoom Out"): dw.view.zoomOut(d)
    var zi = max(0, zoomSteps.find(dw.view.zoom))
    if slider(zi, 0, zoomSteps.high, ticks = 0) and zoomSteps[zi] != dw.view.zoom:
      dw.view.setZoom(d, zoomSteps[zi])
    if toolButton(glyphIcon(pxZoomIn, ui.theme.text, dp(16)), "Zoom In"): dw.view.zoomIn(d)
    label zoomPercent(dw.view.zoom)

proc histMenuItems(tab: int) =
  ## The menus of Navigator, History, Actions, Histogram.
  let d = cur()
  case tab
  of 1:
    if menuItem("New Snapshot", enabled = d != nil): runCommand("New Snapshot")
    if menuItem("New Document from State", enabled = d != nil): runCommand("New Document from State")
    if menuItem("Clear History", enabled = d != nil and (d.canUndo or d.canRedo)): runCommand("Undo History")
  of 2: actionsMenu()
  else:
    if menuItem("Zoom In", enabled = d != nil): runCommand("Zoom In")
    if menuItem("Zoom Out", enabled = d != nil): runCommand("Zoom Out")
    if menuItem("Fit on Screen", enabled = d != nil): runCommand("Fit on Screen")

# ---- Actions: playing them -------------------------------------------------------------------------------

proc stepTitle(s: ActStep): string =
  ## A step as the Actions palette lists it.
  case s.kind
  of acCommand: commandTitle(s.name)
  of acFilter:
    var parts: seq[string]
    if filters.hasKey(s.name):
      let ps = filters[s.name].params
      for i, v in s.vals:
        if i >= ps.len: break
        let p = ps[i]
        if p.choices.len > 0: parts.add p.choices[clamp(int(v), 0, p.choices.high)]
        else: parts.add p.label.strip(chars = {':', ' '}) & " " & fmtNum(v) & p.unit.replace("pixels", "px")
    s.name & (if parts.len > 0: " (" & parts.join(", ") & ")" else: "")
  of acAdjust: s.name
  of acAdjustLayer: "New " & s.name & " Layer"
  of acImageSize: "Image Size: " & fmtNum(s.vals[0]) & " x " & fmtNum(s.vals[1])
  of acFitImage: "Fit Image: " & fmtNum(s.vals[0]) & " x " & fmtNum(s.vals[1])
  of acCanvasSize: "Canvas Size: " & fmtNum(s.vals[0]) & " x " & fmtNum(s.vals[1])
  of acRotate: "Rotate Canvas " & fmtNum(s.vals[0]) & "°"
  of acSelect: s.name & ": " & fmtNum(s.vals[0]) & " px"
  of acFill:
    "Fill: " & ["Foreground", "Background", "Pattern", "Black", "50% Gray", "White", "Color"][
      clamp(int(s.vals[0]), 0, 6)] & (if s.vals.len > 1 and s.vals[1] < 100: ", " & fmtNum(s.vals[1]) & "%" else: "")
  of acLayerProps: "Layer: " & s.name & ", " & fmtNum(if s.vals.len > 1: s.vals[1] else: 100) & "%"
  of acNewLayer: "New Layer" & (if s.name.len > 0: " \"" & s.name & "\"" else: "")
  of acStop: "Stop: " & s.name

proc fitImage(d: Doc; w, h: int; noEnlarge: bool) =
  ## File > Automate > Fit Image: the image as big as fits in `w` x `h`.
  let k = min(w.float / d.w.float, h.float / d.h.float)
  if k <= 0 or (noEnlarge and k >= 1): return
  let nw = max(1, int(round(d.w.float * k)))
  let nh = max(1, int(round(d.h.float * k)))
  if nw == d.w and nh == d.h: return
  d.snapStep("Fit Image")
  try:
    d.imageSize(nw, nh, rsBicubic, d.dpi)
    d.endStep()
  except ValueError:
    d.cancelStep()
    status = "Too big"

proc trimRect(d: Doc): Rect =
  ## Image > Trim: the part that is not transparent (an image with no
  ## transparency: the part that is not the color of its top left pixel).
  d.updateComposite()
  let p = d.compPtr
  var clear = false
  for i in 0 ..< d.w * d.h:
    if (p[i] shr 24) < 255:
      clear = true
      break
  let corner = p[0]
  var x0 = d.w
  var y0 = d.h
  var x1 = -1
  var y1 = -1
  for y in 0 ..< d.h:
    for x in 0 ..< d.w:
      let v = p[y * d.w + x]
      let keep = if clear: (v shr 24) != 0 else: v != corner
      if keep:
        x0 = min(x0, x); x1 = max(x1, x)
        y0 = min(y0, y); y1 = max(y1, y)
  if x1 < 0: return rect(0, 0, d.w, d.h)
  rect(x0, y0, x1 - x0 + 1, y1 - y0 + 1)

proc playStep(s: ActStep): bool =
  ## Does step `s` to the current image; false: stop playing.
  let d = cur()
  if d == nil: return false
  result = true
  case s.kind
  of acCommand: runCommand(s.name)
  of acFilter:
    if not filters.hasKey(s.name):
      status = "No filter \"" & s.name & "\""
      return false
    if not d.needPixels(s.name): return false
    runFilter(s.name, s.vals)
  of acAdjust:
    let f = adjustmentFn(Adjustment(kind: s.name, args: s.vals, data: s.data))
    if f == nil: return
    if not d.needPixels(s.name): return false
    d.beginStep(s.name)
    d.applyFilter(0, f)
    d.endStep()
  of acAdjustLayer:
    d.beginStep("New Adjustment Layer")
    discard d.newAdjustmentLayer(Adjustment(kind: s.name, args: s.vals, data: s.data))
    d.endStep()
  of acImageSize:
    let nw = int(s.vals[0])
    let nh = int(s.vals[1])
    if nw != d.w or nh != d.h:
      d.snapStep("Image Size")
      try:
        if s.vals.len > 2 and int(s.vals[2]) == 4: d.enlarge(nw, nh, int(s.vals[4]), s.vals[3])
        else: d.imageSize(nw, nh, Resample(clamp(int(s.vals[2]), 0, 3)), (if s.vals.len > 3: s.vals[3] else: d.dpi))
        d.endStep()
      except ValueError:
        d.cancelStep()
        status = "Too big"
        return false
  of acFitImage: d.fitImage(int(s.vals[0]), int(s.vals[1]), s.vals.len > 2 and s.vals[2] != 0)
  of acCanvasSize:
    d.snapStep("Canvas Size")
    d.canvasSize(int(s.vals[0]), int(s.vals[1]), int(s.vals[2]), int(s.vals[3]), bg)
    d.endStep()
  of acRotate:
    d.snapStep("Rotate Canvas")
    try:
      d.rotateArbitrary(s.vals[0], bg)
      d.endStep()
    except ValueError:
      d.cancelStep()
      return false
  of acSelect:
    if d.hasSelection:
      let n = int(s.vals[0])
      d.beginStep(s.name)
      d.touchSel()
      case s.name
      of "Feather": d.feather(n.float)
      of "Border": d.borderSelection(n)
      of "Smooth": d.smoothSelection(n)
      of "Expand": d.expandSelection(n)
      of "Contract": d.contractSelection(n)
      of "Grow": d.growSelection(n)
      of "Similar": d.growSelection(n, similar = true)
      else: discard
      d.endStep()
  of acFill:
    if not d.needPixels("Fill"): return false
    let use = clamp(int(s.vals[0]), 0, 6)
    let op = clamp(int(s.vals[1]), 0, 100)
    let m = PaintModes[clamp(int(s.vals[2]), 0, PaintModes.high)]
    d.beginStep("Fill")
    if use == 2 and pattern.len > 0:
      let o = PaintOpts(pattern: pattern, pw: patternW, ph: patternH)
      let a = op * 255 div 100
      d.mapPixels(d.layer, d.bounds, proc (p: uint32; x, y: int): uint32 =
        blendPx(p, patternAt(o, x, y), a, m, x, y))
    else:
      let own = if s.vals.len > 3: uint32(s.vals[3]) else: fg
      d.fillSelection([fg, bg, fg, black, 0xFF808080'u32, white, own][use], op, m)
    d.endStep()
  of acLayerProps:
    if d.cur > 0 or not d.current.background:
      let L = d.current
      d.layersChange("Layer Options"):
        L.mode = LayerModes[clamp(int(s.vals[0]), 0, LayerModes.high)]
        if s.vals.len > 1: L.opacity = clamp(int(s.vals[1]), 0, 100)
        d.markAll()
  of acNewLayer:
    d.snapStep("New Layer")
    discard d.addLayer(s.name)
    d.endStep()
  of acStop:
    status = s.name
    return false

proc playAction(i: int; first = 0; only = false) =
  ## Plays action `i` on the current image (from step `first`; `only`: that
  ## step alone).
  if i notin 0 .. actions.high or cur() == nil: return
  let a = actions[i]
  playing = true
  beginBusy(a.name)
  try:
    for k in max(0, first) .. a.steps.high:
      let s = a.steps[k]
      if s.on or only:
        if not playStep(s): break
      if only: break
  finally:
    endBusy()
    playing = false

# ---- the Actions palette ------------------------------------------------------------------------------------

var
  actNameOpen = false
  actNameMode = 0                ## 0 a new action, 1 renaming it, 2 a stop's message
  actNameText = ""
  actFilePick = false
  actFileSave = false
  actFilePath = ""
  batchOpen = false
  batchAction = 0
  batchSrc = ""
  batchDst = ""
  batchSubfolders = false
  batchFormat = 0                ## JPEG, PNG, TIFF, PSD, Retro Atelier
  batchQuality = 85
  batchSuffix = ""
  batchPickSrc = false
  batchPickDst = false
  batchLog: seq[string]
  fitOpen = false
  fitW = 1200
  fitH = 1200
  fitNoEnlarge = true

proc newAction(name: string; record = true) =
  actions.add Action(name: name, open: true)
  actSel = actions.high
  actStepSel = -1
  recording = record
  saveActions()

proc actionsMenu() =
  if not actionsLoaded: loadActions()
  let some = actSel in 0 .. actions.high
  if menuItem("New Action..."):
    actNameMode = 0
    actNameText = "Action " & $(actions.len + 1)
    actNameOpen = true
    typeFirst()
  if menuItem("Duplicate", enabled = some):
    var a = actions[actSel]
    a.name &= " copy"
    actions.insert(a, actSel + 1)
    inc actSel
    saveActions()
  if menuItem("Delete", enabled = some):
    if actStepSel >= 0 and actStepSel < actions[actSel].steps.len:
      actions[actSel].steps.delete(actStepSel)
      actStepSel = min(actStepSel, actions[actSel].steps.high)
    else:
      actions.delete(actSel)
      actSel = clamp(actSel, 0, max(0, actions.high))
      recording = false
    saveActions()
  if menuItem("Play", enabled = some and cur() != nil):
    playAction(actSel, max(0, actStepSel))
  menuSeparator()
  if menuItem("Start Recording", enabled = some and not recording): recording = true
  if menuItem("Stop Recording", enabled = recording): recording = false
  if menuItem("Insert Stop...", enabled = some):
    actNameMode = 2
    actNameText = ""
    actNameOpen = true
    typeFirst()
  if menuItem("Action Options...", enabled = some):
    actNameMode = 1
    actNameText = actions[actSel].name
    actNameOpen = true
    typeFirst()
  menuSeparator()
  if menuItem("Batch..."): runCommand("Batch...")
  menuSeparator()
  if menuItem("Load Actions..."):
    proc go() =
      if actFilePath.len == 0: actFilePath = picturesDir()
      actFileSave = false
      actFilePick = true
    if storageFor(go): go()
  if menuItem("Save Actions...", enabled = actions.len > 0):
    proc go() =
      actFilePath = picturesDir() / "Retro Atelier.actions"
      actFileSave = true
      actFilePick = true
    if storageFor(go): go()
  if menuItem("Reset Actions"):
    actions = defaultActions()
    actSel = 0
    actStepSel = -1
    recording = false
    saveActions()
  if menuItem("Clear All Actions", enabled = actions.len > 0):
    actions.setLen(0)
    actSel = 0
    actStepSel = -1
    recording = false
    saveActions()

proc actionsBody(d: Doc) =
  if not actionsLoaded: loadActions()
  let rowH = dp(22)
  var n = 0
  for a in actions:
    inc n
    if a.open: n += a.steps.len
  let listH = max(rowH, remainingH() - (CtrlH + 1) - Gap - 1)
  beginScroll(listH, "actlist")
  let r = place(available(), max(rowH, n * rowH + dp(3)))
  fill(r, ui.theme.window)
  let chkW = dp(20)
  let hid = idOf("actionrows")
  let hit = interact(hid, r, focusable = false)
  var y = r.y
  var changed = false
  for i in 0 .. actions.high:
    for k in -1 .. (if actions[i].open: actions[i].steps.high else: -1):
      let rr = rect(r.x, y, r.w, rowH)
      let ck = rect(rr.x, rr.y, chkW, rowH)
      fill(ck, ui.theme.face)
      vline(ck.x + ck.w, rr.y, rowH, ui.theme.shadow)
      let on = if k < 0: (block:
                            var all = true
                            for s in actions[i].steps: all = all and s.on
                            all)
               else: actions[i].steps[k].on
      # the check: played or not
      if on:
        let cx = ck.x + (chkW - dp(9)) div 2
        let cy = rr.y + (rowH - dp(9)) div 2
        for t in 0 .. 1:
          for j in 0 .. dp(3):
            fill(cx + j, cy + dp(4) + j + t, 1, 1, ui.theme.text)
          for j in 0 .. dp(5):
            fill(cx + dp(3) + j, cy + dp(7) - j + t, 1, 1, ui.theme.text)
      let body = rect(ck.x + chkW + 1, rr.y, rr.w - chkW - 1, rowH)
      let picked = i == actSel and k == actStepSel
      if picked: fill(body, ui.theme.select)
      let fg2 = if picked: ui.theme.selectText else: ui.theme.text
      var x = body.x + dp(3)
      if k < 0:
        # the action: its triangle, its icon, its name (red while recording)
        let tri = rect(x, rr.y, dp(12), rowH)
        arrow(tri.x + dp(5), tri.y + rowH div 2, if actions[i].open: dDown else: dRight, fg2)
        x += dp(14)
        image(x, body.y + (rowH - dp(16)) div 2, glyphIcon(pxActions, fg2, dp(16)))
        x += dp(20)
        let rec = recording and i == actSel
        text(x, body.y + (rowH - FontH) div 2, ellipsize(actions[i].name, body.x + body.w - x - dp(4)),
             if rec and not picked: color(192, 0, 0) else: fg2, rec)
        if hit.down and ui.pressed and mouseIn(tri):
          actions[i].open = not actions[i].open
          changed = true
      else:
        x += dp(28)
        text(x, body.y + (rowH - FontH) div 2,
             ellipsize(stepTitle(actions[i].steps[k]), body.x + body.w - x - dp(4)), fg2)
      hline(rr.x, rr.y + rowH - 1, rr.w, ui.theme.face)
      if hit.down and ui.pressed and mouseIn(rr):
        if mouseIn(ck):
          if k < 0:
            let all = not on
            for s in actions[i].steps.mitems: s.on = all
          else: actions[i].steps[k].on = not on
          changed = true
        elif not (k < 0 and mouseIn(rect(body.x, rr.y, dp(17), rowH))):
          if actSel != i: recording = false
          actSel = i
          actStepSel = k
      if hit.down and ui.pressed and ui.clicks >= 2 and mouseIn(body) and k < 0:
        actNameMode = 1
        actNameText = actions[i].name
        actNameOpen = true
        typeFirst()
      y += rowH
  endScroll()
  if changed: saveActions()
  row:
    let some = actSel in 0 .. actions.high
    if toolButton(glyphIcon(pxStop, ui.theme.text, dp(16)), "Stop Recording", enabled = recording):
      recording = false
    if toolButton(glyphIcon(pxRecord, ui.theme.text, dp(16)), "Begin Recording", down = recording):
      if recording: recording = false
      elif some: recording = true
      else: newAction("Action " & $(actions.len + 1))
    if toolButton(glyphIcon(pxPlay, ui.theme.text, dp(16)), "Play the Action (from the step picked)",
                  enabled = some and d != nil and not recording):
      playAction(actSel, max(0, actStepSel))
    if toolButton(glyphIcon(pxNew, ui.theme.text, dp(16)), "New Action"):
      actNameMode = 0
      actNameText = "Action " & $(actions.len + 1)
      actNameOpen = true
      typeFirst()
    if toolButton(glyphIcon(pxTrash, ui.theme.text, dp(16)), "Delete the Action or Step", enabled = some):
      if actStepSel >= 0 and actStepSel < actions[actSel].steps.len:
        actions[actSel].steps.delete(actStepSel)
        actStepSel = min(actStepSel, actions[actSel].steps.high)
      else:
        actions.delete(actSel)
        actSel = clamp(actSel, 0, max(0, actions.high))
        actStepSel = -1
        recording = false
      saveActions()

proc actionDialogs() =
  if actNameOpen:
    let title = ["New Action", "Action Options", "Insert Stop"][actNameMode]
    dialog(actNameOpen, title, 360):
      form 0:
        field (if actNameMode == 2: "Message:" else: "Name:"): edit(actNameText)
      if actNameMode == 0:
        label("Recording begins: what you do now goes into it.", color = ui.theme.gray)
      row:
        spring()
        if button(if actNameMode == 0: "Record" else: "OK", isDefault = true, w = dp(80)):
          actNameOpen = false
          let t = actNameText.strip
          case actNameMode
          of 0: newAction(if t.len > 0: t else: "Action " & $(actions.len + 1))
          of 1:
            if actSel in 0 .. actions.high and t.len > 0:
              actions[actSel].name = t
              saveActions()
          else:
            if actSel in 0 .. actions.high:
              let at = if actStepSel >= 0: actStepSel + 1 else: actions[actSel].steps.len
              actions[actSel].steps.insert(ActStep(kind: acStop, name: (if t.len > 0: t else: "Stop"),
                                                   on: true), at)
              actions[actSel].open = true
              actStepSel = at
              saveActions()
        if button("Cancel", w = dp(80)): actNameOpen = false
  if filePicker(actFilePick, actFilePath, (if actFileSave: fmSave else: fmOpen), ["*.actions", "*.txt"],
                if actFileSave: "Save Actions" else: "Load Actions"):
    try:
      if actFileSave:
        var p = actFilePath
        if p.splitFile.ext.len == 0: p &= ".actions"
        writeFile(p, actionsText(actions))
        status = tr("Saved ") & p.extractFilename
      else:
        let got = parseActions(readFile(actFilePath))
        if got.len == 0: status = "No actions in " & actFilePath.extractFilename
        else:
          for a in got: actions.add a
          actSel = actions.len - got.len
          actStepSel = -1
          saveActions()
          status = $got.len & " actions loaded"
    except CatchableError:
      status = "Could not " & (if actFileSave: "save " else: "read ") & actFilePath.extractFilename

# ---- File > Automate: Batch, Fit Image ----------------------------------------------------------------------

const batchExts = [".rpd", ".rp3", ".psd", ".psb", ".png", ".jpg", ".jpeg", ".tif", ".tiff", ".bmp", ".gif", ".tga"]

proc batchFiles(dir: string; sub: bool): seq[string] =
  ## The pictures in `dir` (and its folders), in name order. (walkDir:
  ## Android before 9 has no glob.)
  try:
    for kind, f in walkDir(dir):
      if kind in {pcFile, pcLinkToFile} and f.splitFile.ext.toLowerAscii in batchExts: result.add f
      elif sub and kind == pcDir and not f.extractFilename.startsWith("."): result.add batchFiles(f, true)
  except OSError: discard
  result.sort(proc (a, b: string): int = cmp(a.toLowerAscii, b.toLowerAscii))

proc runBatch() =
  ## Batch: the action played on every picture of the folder, each saved in
  ## the destination.
  let files = batchFiles(batchSrc, batchSubfolders)
  batchLog.setLen(0)
  if files.len == 0:
    status = "No pictures in " & batchSrc
    return
  let ext = [".jpg", ".png", ".tif", ".psd", ".rpd"][clamp(batchFormat, 0, 4)]
  let dst = if batchDst.len > 0: batchDst else: batchSrc
  let suffix = if batchSuffix.len == 0 and dst == batchSrc: "-edited" else: batchSuffix
  try: createDir(dst)
  except OSError: discard
  let before = active
  var done = 0
  beginBusy("Batch", cancel = true)
  try:
    for i, f in files:
      busyLabel = "Batch: " & f.extractFilename & " (" & $(i + 1) & " of " & $files.len & ")"
      busyFraction = i / files.len
      busyTick()
      var doc: Doc
      try: doc = openPicture(f)
      except CatchableError:
        batchLog.add f.extractFilename & ": could not be read"
        continue
      addDoc(doc)
      let dw = active
      try:
        playAction(batchAction)
        let rel = if batchSubfolders: f.parentDir.relativePath(batchSrc) else: ""
        let outDir = if rel.len > 0 and rel != ".": dst / rel else: dst
        createDir(outDir)
        let p = outDir / f.splitFile.name & suffix & ext
        let d = dw.doc
        case ext
        of ".rpd": d.saveRpd(p)
        of ".psd": d.savePsd(p)
        else:
          var o = defaultExport(case ext
                                of ".jpg": efJpeg
                                of ".png": efPng
                                else: efTiff)
          o.quality = batchQuality
          d.exportPicture(p, o)
        inc done
      except BusyCancelled:
        closeDoc(dw)
        raise
      except CatchableError:
        batchLog.add f.extractFilename & ": " & getCurrentExceptionMsg()
      closeDoc(dw)
  except BusyCancelled:
    batchLog.add "Stopped."
  finally:
    endBusy(cancel = true)
    if before in docs: active = before
  status = "Batch: " & $done & " of " & $files.len & " pictures done" &
           (if batchLog.len > 0: " (" & $batchLog.len & " problems)" else: "")

proc batchDialog() =
  if batchOpen:
    if not actionsLoaded: loadActions()
    dialog(batchOpen, "Batch", 470):
      group("Play"):
        var names: seq[string]
        for a in actions: names.add a.name
        if names.len == 0: names.add "(no actions)"
        row:
          label "Action:"
          combo(names, batchAction, w = dp(260))
      group("Source"):
        row([-1, 90]):
          label(if batchSrc.len > 0: ellipsize(batchSrc, available()) else: "(a folder)",
                color = if batchSrc.len > 0: ui.theme.text else: ui.theme.gray)
          if button("Choose...", w = dp(86)):
            proc go() =
              if batchSrc.len == 0: batchSrc = picturesDir()
              batchPickSrc = true
            if storageFor(go): go()
        checkbox("Include All Subfolders", batchSubfolders)
        if batchSrc.len > 0:
          label($batchFiles(batchSrc, batchSubfolders).len & " pictures", color = ui.theme.gray)
      group("Destination"):
        row([-1, 90]):
          label(if batchDst.len > 0: ellipsize(batchDst, available()) else: "(the same folder)",
                color = if batchDst.len > 0: ui.theme.text else: ui.theme.gray)
          if button("Choose...", w = dp(86)):
            proc go() =
              if batchDst.len == 0: batchDst = if batchSrc.len > 0: batchSrc else: picturesDir()
              batchPickDst = true
            if storageFor(go): go()
        row:
          label "Save As:"
          combo(["JPEG", "PNG", "TIFF", "PSD", "Retro Atelier"], batchFormat, w = dp(120))
          if batchFormat == 0:
            label "Quality:"
            spin(batchQuality, 1, 100, w = dp(60))
        row:
          label "Name: (the picture's) +"
          edit(batchSuffix, w = dp(110))
        label("Pictures of the same name there are replaced.", color = ui.theme.gray)
      if batchLog.len > 0:
        group("The last batch"):
          for l in batchLog[0 ..< min(batchLog.len, 5)]: label(l, color = color(160, 0, 0))
      row:
        spring()
        if button("OK", isDefault = true, w = dp(80),
                  enabled = batchSrc.len > 0 and batchAction in 0 .. actions.high):
          batchOpen = false
          runBatch()
        if button("Cancel", w = dp(80)): batchOpen = false
  if filePicker(batchPickSrc, batchSrc, fmFolder, [], "Batch: Source Folder"): discard
  if filePicker(batchPickDst, batchDst, fmFolder, [], "Batch: Destination Folder"): discard
  if fitOpen:
    dialog(fitOpen, "Fit Image", 320):
      label("The image made as big as fits in:", color = ui.theme.gray)
      form 0:
        field "Width:":
          row:
            spin(fitW, 1, 30000, w = dp(80))
            label "pixels"
        field "Height:":
          row:
            spin(fitH, 1, 30000, w = dp(80))
            label "pixels"
      checkbox("Don't Enlarge", fitNoEnlarge)
      row:
        spring()
        if button("OK", isDefault = true, w = dp(80)):
          fitOpen = false
          let d = cur()
          if d != nil:
            d.fitImage(fitW, fitH, fitNoEnlarge)
            if active != nil: active.fitWindow()
            if recording:
              record(ActStep(kind: acFitImage, name: "Fit Image",
                             vals: @[fitW.float, fitH.float, (if fitNoEnlarge: 1.0 else: 0.0)]))
        if button("Cancel", w = dp(80)): fitOpen = false

# ---- Select and Mask ----------------------------------------------------------------------------------------

var
  smOpen = false
  smView = 1                   ## Marching Ants, Overlay, On Black, On White, Black & White
  smRadius = 3
  smSmart = true
  smColor = true                 ## Select and Mask: guided by the colors (Object Aware), not only lightness
  smSmooth = 0
  smFeather = 0
  smContrast = 0
  smShift = 0
  smDecon = false
  smDeconAmount = 50
  smOutput = 0                 ## Selection, Layer Mask, New Layer, New Layer with Layer Mask
  smProxy: tuple[img: Img; mask: seq[uint8]; k: float]
  smPreview: Bitmap
  smKey = ""
  smHair = false               ## Refine Hair (the strands followed where the edge is fine)

proc startSelectAndMask() =
  ## Select > Select and Mask: the selection's edge made better.
  let d = cur()
  if d == nil: return
  if not d.hasSelection:
    status = "Select something first (the Quick Selection tool, Select > Subject...)"
    return
  d.updateComposite()
  # (a small copy to see it on, quickly)
  let side = 420
  let k = min(1.0, side.float / max(d.w, d.h).float)
  let pw = max(1, int(d.w.float * k))
  let ph = max(1, int(d.h.float * k))
  let comp = d.compCopy
  let small = thumbnailOf(comp, d.w, d.h, pw, ph, checker = false)
  var m = newSeq[uint8](pw * ph)
  for y in 0 ..< ph:
    for x in 0 ..< pw:
      m[y * pw + x] = d.sel[min(d.h - 1, int(y.float / k)) * d.w + min(d.w - 1, int(x.float / k))]
  smProxy = (Img(w: small.w, h: small.h, px: small.px), m, k)
  smKey = ""
  smOpen = true

proc smRefined(img: Img; mask: seq[uint8]; k: float): seq[uint8] =
  let m = if smHair: refineHair(img, mask) else: mask
  refineEdge(img, m, smRadius.float * k, int(round(smSmooth.float * k)), smFeather.float * k, smContrast,
             smShift, smSmart, smColor)

proc selectAndMaskDialog() =
  if not smOpen: return
  let d = cur()
  if d == nil:
    smOpen = false
    return
  var go = false
  proc preview(w, h: int) =
    let key = $smView & $smRadius & $smSmart & $smColor & $smSmooth & $smFeather & $smContrast & $smShift &
              $smDecon & $smDeconAmount & $smHair
    if key != smKey:
      let im = smProxy.img
      let m = smRefined(im, smProxy.mask, smProxy.k)
      var shown = im
      if smDecon: decontaminate(shown, m, smDeconAmount)
      let b = newBitmap(im.w, im.h)
      for i in 0 ..< im.px.len:
        let a = int(m[i])
        let p = shown.px[i]
        b.px[i] = case smView
                  of 1: (if a >= 255: p else: mix(blendPx(p, 0xFFFF0000'u32, 128, bmNormal), p, a / 255))
                  of 2: mix(0xFF000000'u32, p or 0xFF000000'u32, a / 255)
                  of 3: mix(0xFFFFFFFF'u32, p or 0xFF000000'u32, a / 255)
                  of 4: grayPx(a)
                  else: (if a >= 128: p else: mix(p, 0xFF808080'u32, 0.6))
      b.changed()
      smPreview = b
      smKey = key
    discard pictureBox("smpreview", smPreview, w, h)
  proc controls() =
    row:
      label "View:"
      combo(@["Marching Ants", "Overlay", "On Black", "On White", "Black & White"], smView, w = dp(130))
    group("Edge Detection"):
      discard fxSlider("Radius:", smRadius, 0, 250, " px")
      checkbox("Smart Radius", smSmart)
      checkbox("Color Aware (hair)", smColor)
      tooltip("Color Aware: for hair and fur on a busy background")
      if button(if smHair: "Refine Hair: On" else: "Refine Hair", w = dp(140)): smHair = not smHair
    group("Global Refinements"):
      discard fxSlider("Smooth:", smSmooth, 0, 100, "")
      discard fxSlider("Feather:", smFeather, 0, 250, " px")
      discard fxSlider("Contrast:", smContrast, 0, 100, "%")
      discard fxSlider("Shift Edge:", smShift, -100, 100, "%")
    group("Output"):
      checkbox("Decontaminate Colors", smDecon)
      if smDecon: discard fxSlider("Amount:", smDeconAmount, 0, 100, "%")
      row:
        label "To:"
        combo(@["Selection", "Layer Mask", "New Layer", "New Layer with Layer Mask"], smOutput, w = dp(170))
  # (the preview at the left and the settings at the right when the dialog
  # has the room -- on a narrow screen, one over the other)
  dialog(smOpen, "Select and Mask", 780):
    if available() >= dp(430 + 300):
      row([430, -1]):
        col: preview(dp(424), dp(330))
        col: controls()
    else:
      let w = available()
      preview(w, min(w * 3 div 4, max(dp(160), ui.h div 3)))
      controls()
    row:
      spring()
      if button("OK", isDefault = true, w = dp(80)): go = true
      if button("Cancel", w = dp(80)): smOpen = false
  if go:
    smOpen = false
    beginBusy("Select and Mask")
    try:
      d.updateComposite()
      var src = Img(w: d.w, h: d.h, px: (if smOutput >= 2: d.current.px else: d.compCopy))
      let m = smRefined(Img(w: d.w, h: d.h, px: d.compCopy), d.sel, 1.0)
      case smOutput
      of 0:
        d.beginStep("Select and Mask")
        d.touchSel()
        d.setSelection(m)
        d.endStep()
      of 1:
        d.layersChange("Select and Mask"):
          let L = d.current
          if L.mask == nil and not L.background and L.adjust.kind.len == 0 and not L.group:
            d.addLayerMask(mfRevealAll)
          if L.mask != nil:
            d.touch(L.mask, d.bounds)
            for i in 0 ..< m.len: L.mask.px[i] = grayPx(int(m[i]))
            inc L.mask.ver
            if smDecon:
              d.touch(L, d.bounds)
              var im = Img(w: d.w, h: d.h, px: L.px)
              decontaminate(im, m, smDeconAmount)
              L.px = im.px
              inc L.ver
          d.markAll()
      else:
        # a new layer: what is selected (with the mask as its edge, or as its mask)
        if smDecon: decontaminate(src, m, smDeconAmount)
        d.layersChange("Select and Mask"):
          let L = d.newLayer(d.current.name & " (refined)")
          if smOutput == 2:
            for i in 0 ..< m.len: L.px[i] = withAlpha(src.px[i], aOf(src.px[i]) * int(m[i]) div 255)
          else:
            L.px = src.px
            L.mask = Layer(name: "Layer Mask", pxRaw: newSeq[uint32](m.len), opacity: 100, visible: true, gray: true)
            for i in 0 ..< m.len: L.mask.px[i] = grayPx(int(m[i]))
          d.insertLayer(L)
          d.touchSel()
          d.selectNone()
    finally: endBusy()

# ---- guides and the grid ------------------------------------------------------------------------------------

var
  ngOpen = false
  ngVertical = 0
  ngPos = 0.0
  gsOpen = false

proc newGuideDialog() =
  if not ngOpen: return
  let d = cur()
  dialog(ngOpen, "New Guide", 300):
    row:
      label "Orientation:"
      radio("Horizontal", ngVertical, 0)
      radio("Vertical", ngVertical, 1)
    row:
      label "Position:"
      var v = float32(ngPos)
      if d.lengthField(v, dp(80), -30000, 30000): ngPos = v.float
      label unitShort()
    row:
      spring()
      if button("OK", isDefault = true, w = dp(80)):
        ngOpen = false
        if d != nil:
          d.guides.add Guide(vertical: ngVertical == 1, pos: ngPos)
          inc d.ver
          if active != nil: active.view.showGuides = true
      if button("Cancel", w = dp(80)): ngOpen = false

proc gridDialog() =
  ## (View › Grid Settings: the Preferences' Guides & Grid page, the grid part)
  if not gsOpen: return
  dialog(gsOpen, "Grid", 340):
    gridPrefsRows()
    row:
      spring()
      if button("OK", isDefault = true, w = dp(80)):
        gsOpen = false
        savePrefs()

# ---- the Properties palette ---------------------------------------------------------------------------------

var propBounds: tuple[key: string; r: Rect]     ## (the current layer's bounds, worked out once a change)

proc layerKindName(L: Layer): (string, string) =
  ## What the current layer is: its icon and its name.
  if L.group: (pxFolder, "Group")
  elif L.adjust.kind.len > 0: (pxAdjustLayer, L.adjust.kind & " Adjustment")
  elif L.isFill: (pxFillLayer, "Fill Layer")
  elif L.isText: (pxTypeTool, "Type Layer")
  elif L.isShape: (pxShapeLayer, "Shape Layer")
  elif L.isSmart: (pxSmartObject, "Smart Object")
  elif L.background: (pxImage, "Background")
  else: (pxImage, "Pixel Layer")

proc propSlider(lab: string; v: var int; lo, hi: int): bool =
  row([64, -1, 60]):
    label lab
    result = slider(v, lo, hi, ticks = 0)
    result = spin(v, lo, hi, w = dp(58)) or result

proc twoButtons(a, b: string; enabledA = true; enabledB = true): (bool, bool) =
  ## Two buttons side by side, as wide as there is room for.
  let bw = max(dp(60), (available() - Gap) div 2)
  row:
    result[0] = button(a, w = bw, enabled = enabledA)
    result[1] = button(b, w = bw, enabled = enabledB)

proc documentProps(d: Doc) =
  group("Canvas"):
    label($d.w & " x " & $d.h & tr(" px, ") & $int(round(d.dpi)) & tr(" ppi"))
    label(tr($d.mode) & tr(", ") & $d.layers.len & (if d.layers.len == 1: tr(" layer") else: tr(" layers")),
          color = ui.theme.gray)
    label(d.profileName, color = ui.theme.gray)
    let (a, b) = twoButtons("Image Size", "Canvas Size")
    if a: runCommand("Image Size...")
    if b: runCommand("Canvas Size...")
    let (c, e) = twoButtons("Trim", "Fit Image")
    if c: runCommand("Trim")
    if e: runCommand("Fit Image...")
  if active != nil:
    group("Rulers and Grids"):
      var g = active.view.showGuides
      if checkbox("Guides", g): runCommand("Show Guides")
      var gr = active.view.showGrid
      if checkbox("Grid", gr): runCommand("Show Grid")
      var ru = active.view.rulers
      if checkbox("Rulers", ru): runCommand("Show Rulers")
      let (a, b) = twoButtons("New Guide", "Clear", enabledB = d.guides.len > 0)
      if a: runCommand("New Guide...")
      if b: runCommand("Clear Guides")

var liveRadius = 0                   ## the Live Shape's corner radius as typed

proc liveShape(d: Doc; L: Layer) =
  ## Properties > Live Shape: the shape's size (W, H), a rectangle's
  ## corner radius, flipped, turned -- the shape stays a shape.
  let (x0, y0, x1, y1) = pathBounds(L.shape.path)
  if x1 <= x0 or y1 <= y0: return
  group("Live Shape"):
    var w = int(round(x1 - x0))
    var h = int(round(y1 - y0))
    var nw = w
    var nh = h
    row:
      label "W:"
      discard spin(nw, 1, 30000, w = dp(64))
      label "H:"
      discard spin(nh, 1, 30000, w = dp(64))
    var s = L.shape
    var step = ""
    if nw != w or nh != h:
      # (stretched from its top left corner)
      let kx = nw.float / max(1.0, x1 - x0)
      let ky = nh.float / max(1.0, y1 - y0)
      s.path.mapPoints(proc (px, py: float): (float, float) = (x0 + (px - x0) * kx, y0 + (py - y0) * ky))
      step = "Live Shape Size"
    if s.kind in ["Rectangle", "Rounded Rectangle"]:
      liveRadius = int(round(s.radius))
      var r = liveRadius
      row:
        label "Corner Radius:"
        discard spin(r, 0, max(0, min(w, h) div 2), w = dp(64))
        label "px"
      if r != liveRadius:
        s.radius = r.float
        s.kind = if r > 0: "Rounded Rectangle" else: "Rectangle"
        s.path = rectPath(x0, y0, x1, y1, r.float)
        step = "Live Shape Corners"
    row:
      let cx = (x0 + x1) / 2
      let cy = (y0 + y1) / 2
      if button("Flip H", w = dp(64)):
        s.path.mapPoints(proc (px, py: float): (float, float) = (2 * cx - px, py))
        step = "Flip Shape Horizontal"
      if button("Flip V", w = dp(64)):
        s.path.mapPoints(proc (px, py: float): (float, float) = (px, 2 * cy - py))
        step = "Flip Shape Vertical"
      if button("Rotate 90°", w = dp(84)):
        s.path.mapPoints(proc (px, py: float): (float, float) = (cx - (py - cy), cy + (px - cx)))
        step = "Rotate Shape"
    if step.len > 0:
      d.beginStep(step)
      d.touchLayers()
      d.setShape(L, s)
      d.endStep()

proc scaleLayersTo(d: Doc; to: Rect) =
  ## (Properties: W and H of several layers -- them all stretched into `to`,
  ## each as what it is; in the step open)
  let shots = d.shotsOf(d.transformLayersOf)
  let r = shotsBox(shots)
  if r.w <= 0 or r.h <= 0 or to.w <= 0 or to.h <= 0: return
  for s in shots:
    if s.kind != skPixels: d.touch(s.layer, d.bounds)
  d.carryShots(shots, r, quadOf(to), proc (L: Layer) = d.renderSmartLayer(L), prefs.scaleStrokes)
  d.putDownShots(shots, r, quadOf(to))

proc severalProps(d: Doc) =
  ## Properties with several layers picked (as the photo editor shows them):
  ## how many, where they are together -- W, H, X, Y set them all -- and
  ## Align and Distribute.
  let idxs = d.pickedLayers
  row:
    let ir = place(dp(16), dp(16))
    image(ir.x, ir.y, glyphIcon(pxLayers, ui.theme.text, dp(16)))
    label($idxs.len & tr(" Layers"), bold = true)
  let b = d.pickedBox
  let locked = d.transformLayersOf.allIt(it.locked or it.lockPosition)
  if b.w > 0 and b.h > 0:
    group("Transform"):
      var w = b.w
      var h = b.h
      var x = b.x
      var y = b.y
      row:
        label "W:"
        let cw = spin(w, 1, 30000, w = dp(70), enabled = not locked)
        label "H:"
        let ch = spin(h, 1, 30000, w = dp(70), enabled = not locked)
        if cw or ch:
          let to = rect(b.x, b.y, w, h)
          d.stepOnce("Scale", proc () = d.scaleLayersTo(to))
      row:
        label "X:"
        let mx = spin(x, -30000, 30000, w = dp(70), enabled = not locked)
        label "Y:"
        let my = spin(y, -30000, 30000, w = dp(70), enabled = not locked)
        if mx or my:
          let dx = x - b.x
          let dy = y - b.y
          let ls = d.transformLayersOf.filterIt(not it.locked and not it.lockPosition and not it.background)
          d.stepOnce("Move", proc () = d.shiftLayers(ls, dx, dy))
  group("Align"):
    row:
      for (how, icon) in [(AlignHow.alLeft, pxAlignEdgeLeft), (alHCenter, pxAlignEdgeHCenter), (AlignHow.alRight, pxAlignEdgeRight),
                          (alTop, pxAlignEdgeTop), (alVCenter, pxAlignEdgeVCenter), (alBottom, pxAlignEdgeBottom)]:
        if toolButton(glyphIcon(icon, ui.theme.text, dp(16)), "Align " & $how): d.alignNow(how)
    var k = ord(alignToKind)
    var names: seq[string]
    for a in AlignTo: names.add tr($a)
    if combo(names, k, w = dp(190)): alignToKind = AlignTo(k)
    if alignToKind == atKeyObject:
      label(tr("The key object: the current layer") & " (" & d.current.name & ")", color = ui.theme.gray)
    row:
      label "Spacing:"
      discard d.lengthField(spacingPx, dp(60), 0, 20000)
      label unitShort()
      if button("Space Across", w = dp(96), enabled = idxs.len >= 2): d.spaceNow(true)
      if button("Space Down", w = dp(90), enabled = idxs.len >= 2): d.spaceNow(false)
  if idxs.len >= 3:
    group("Distribute"):
      for how in [dsHSpace, dsVSpace, dsHCenter, dsVCenter]:
        if button($how, w = dp(150)):
          d.layersChange("Distribute " & $how): d.distributeLayers(idxs, how)
  row:
    if button("Group", w = dp(70)): runCommand("Group Layers")
    if button("Merge", w = dp(70)): runCommand("Merge Layers")

proc propertiesBody(d: Doc) =
  if d == nil:
    label("(no image)", color = ui.theme.gray)
    return
  if d.severalPicked and not d.hasSelection and not d.quickMask:
    severalProps(d)
    return
  let L = d.current
  beginScroll(remainingH(), "propscroll")
  let (icon, kind) = layerKindName(L)
  row:
    let ir = place(dp(16), dp(16))
    image(ir.x, ir.y, glyphIcon(icon, ui.theme.text, dp(16)))
    label(ellipsize(tr(kind) & (if L.background: "" else: ": " & L.name), available()), bold = true,
          literal = true)                 # (its kind in the app's language, its name as it is)
  if L.background and d.layers.len == 1 or (L.background and L.mask == nil):
    documentProps(d)
  if not L.background:
    # where it is: its bounds; X and Y move it
    let key = $d.ver & "/" & $cast[int](L) & "/" & $L.ver
    if propBounds.key != key:
      # (type and shapes: their whole box, off the image too -- X and Y bring them back)
      propBounds = (key, if L.isText or L.isShape or L.isSmart: d.layerBox(L) else: d.contentBounds(L))
    let b = propBounds.r
    if b.w > 0 and L.adjust.kind.len == 0:
      group("Transform"):
        var x = b.x
        var y = b.y
        row:
          label "W:"
          label($b.w & " px", color = ui.theme.gray)
          label "H:"
          label($b.h & " px", color = ui.theme.gray)
        row:
          label "X:"
          let mx = spin(x, -30000, 30000, w = dp(70), enabled = not L.locked)
          label "Y:"
          let my = spin(y, -30000, 30000, w = dp(70), enabled = not L.locked)
          if mx or my:
            let dx = x - b.x
            let dy = y - b.y
            var ls: seq[Layer]
            let k = d.layers.find(L)
            if L.group:
              for j in d.blockStart(k) .. k: ls.add d.layers[j]
            else: ls.add L
            d.stepOnce("Move", proc () = d.shiftLayers(ls, dx, dy))
  # how text keeps out of it (the Text Wrap panel has the rest)
  if not L.background and not L.group and L.adjust.kind.len == 0:
    group("Text Wrap"):
      # (its way on a line of its own, the button under it at the right: a narrow panel has room
      # for both)
      label(["None: text runs over it", "Round its box", "Round its shape", "Jump over it",
             "To the next column"][clamp(L.wrap, 0, 4)], color = ui.theme.gray)
      row:
        spring()
        if button("Text Wrap...", w = dp(104)): showPanel("textwrap")
      tooltip("The Text Wrap panel (Ctrl+Shift+W): how text keeps out of this layer, how far")
  # on an artboard: how it follows the board's size (Constraints)
  block constraints:
    let k = d.layers.find(L)
    var onBoard = false
    for i in d.artboards:
      if i != k and d.blockStart(i) <= k and k < i and L.depth == d.layers[i].depth + 1: onBoard = true
    if onBoard:
      group("Constraints"):
        var pins = L.pins
        row:
          for (p, lab) in [(lpLeft, "Left"), (lpRight, "Right"), (lpTop, "Top"), (lpBottom, "Bottom")]:
            var on = p in pins
            if checkbox(lab, on):
              if on: pins.incl p else: pins.excl p
        row:
          for (p, lab) in [(lpCenterX, "Center Across"), (lpCenterY, "Center Down"), (lpScale, "Scale")]:
            var on = p in pins
            if checkbox(lab, on):
              if on: pins.incl p else: pins.excl p
        if pins != L.pins:
          d.layersChange("Constraints"): L.pins = pins
        label(if L.pins == {}: "None: it stays where it is when the artboard changes size."
              else: "When the artboard changes size it follows (both sides: it stretches).", color = ui.theme.gray)
  # what the kind of layer has
  if L.group:
    group("Group"):
      var m = if L.passThrough: 0 else: 1 + max(0, LayerModes.find(L.mode))
      row:
        label "Mode:"
        if combo(groupModeNames(), m, w = dp(130)): d.setLayerMode(L, m)
      if button("Ungroup", w = dp(104)): runCommand("Ungroup Layers")
  elif L.adjust.kind in ["Clarity", "Dehaze", "Grain"]:
    group(L.adjust.kind):
      let names = case L.adjust.kind
                  of "Grain": @["Amount:", "Size:", "Roughness:"]
                  else: @["Amount:"]
      let los = if L.adjust.kind == "Grain": @[0, 0, 0] else: @[-100]
      let dflt = case L.adjust.kind
                 of "Grain": @[25.0, 25, 50, 1]
                 of "Dehaze": @[30.0]
                 else: @[30.0]
      var args = L.adjust.args
      while args.len < dflt.len: args.add dflt[args.len]
      var changed = false
      for i, n in names:
        var v = int(args[i])
        if propSlider(n, v, los[i], 100):
          args[i] = v.float
          changed = true
      if changed:
        let a = Adjustment(kind: L.adjust.kind, args: args)
        d.stepOnce(L.adjust.kind, proc () = d.setAdjustment(L, a))
      label(case L.adjust.kind
            of "Clarity": "Contrast in the midtones, where details are (negative: softer)."
            of "Dehaze": "Haze taken away (negative: added)."
            else: "Film grain over what is under it.", color = ui.theme.gray)
  elif L.adjust.kind.len > 0:
    group("Adjustment"):
      label(L.adjust.kind, bold = true)
      if L.adjust.kind != "Invert":
        if button("Edit Settings...", w = dp(130)): editAdjustLayer(L)
      label("Double-click its thumbnail (Layers) does it too.", color = ui.theme.gray)
  elif L.isFill:
    group("Fill"):
      let f = L.shape.fill
      label(case f.kind
            of spColor: "Solid Color"
            of spGradient: "Gradient"
            of spPattern: "Pattern"
            else: "None")
      if f.kind == spColor:
        var c = f.color or 0xFF000000'u32
        if colorWell(c, "propfill", dp(60)):
          var s = L.shape
          s.fill.color = c
          let cc = s
          d.stepOnce("Fill Color", proc () = d.setShape(L, cc))
      if button("Edit Fill...", w = dp(104)): startFillLayer(f.kind, L)
  elif L.isText:
    group("Character"):
      fontRows(true)
    group("Paragraph"):
      row: alignButtons(curPara().align, true)
  elif L.isLine:
    group("Line"):
      # (its color, weight and ends; its ends dragged with the Move tool)
      if L != shapeSynced:
        shapeSynced = L
        syncShapeOptions(L)
      row: lineOptions(false)
      label("Drag its ends with the Move tool (Shift: at 45 degrees).", color = ui.theme.gray)
    liveShape(d, L)
  elif L.isShape:
    group("Appearance"):
      if L != shapeSynced:
        shapeSynced = L
        syncShapeOptions(L)
      var changed = false
      row:
        label "Fill:"
        if combo(["No Color", "Solid Color", "Gradient"], shapeFillKind, w = dp(96)): changed = true
        if shapeFillKind > 0:
          if colorWell(shapeFill, "propshapefill", dp(26)): changed = true
      row:
        label "Stroke:"
        if combo(["No Color", "Solid Color", "Gradient"], shapeStrokeKind, w = dp(96)): changed = true
        if shapeStrokeKind > 0:
          if colorWell(shapeStroke, "propshapestroke", dp(26)): changed = true
        if shapeStrokeKind == 2:
          if colorWell(shapeStroke2, "propshapestroke2", dp(26)): changed = true
      if shapeStrokeKind == 2:
        row:
          label "Gradient:"
          if combo(["Within the stroke", "Along the stroke", "Across the stroke"], shapeStrokeOn, w = dp(150)):
            changed = true
      if shapeStrokeKind > 0:
        row:
          label "Width:"
          if spin(shapeStrokeW, 1, 500, w = dp(56)): changed = true
          label "px"
          if combo(["Inside", "Center", "Outside"], shapeAlign, w = dp(80)): changed = true
      if changed: applyShapeOptions()
    liveShape(d, L)
  elif L.isSmart:
    group("Smart Object"):
      label(if L.smart.name.len > 0: L.smart.name else: "Embedded")
      label($L.smart.w & " x " & $L.smart.h & tr(" pixels inside"), color = ui.theme.gray)
      if L.smart.filters.len > 0:
        label("Smart Filters:", bold = true)
        var fs = L.smart.filters
        var changed = false
        var del = -1
        for k in countdown(fs.high, 0):
          row([-1, 24, 24]):
            var on = not fs[k].off
            if checkbox(ellipsize(fs[k].name, available() - dp(24)), on):
              fs[k].off = not on
              changed = true
            if toolButton(glyphIcon(pxProperties, ui.theme.text, dp(16)), "Change " & fs[k].name):
              editSmartFilter(d, L, k)
            if toolButton(glyphIcon(pxTrash, ui.theme.text, dp(16)), "Delete " & fs[k].name): del = k
        if del >= 0:
          fs.delete(del)
          changed = true
        if changed:
          let nf = fs
          d.layersChange("Smart Filters"):
            L.smart = L.smart.withFilters(nf)
            d.renderSmartLayer(L)
      else:
        label("Filters on it are Smart Filters: changed or taken off later.", color = ui.theme.gray)
      let (a, b) = twoButtons("Edit Contents", "Rasterize")
      if a: editSmartContents(d, L)
      if b: runCommand("Rasterize Smart Object")
  # its mask
  if L.mask != nil:
    group("Layer Mask"):
      var dens = L.maskDensity
      if propSlider("Density:", dens, 0, 100):
        let v = dens
        d.stepOnce("Mask Density", proc () = (L.maskDensity = v; d.markAll()))
      var fe = int(round(L.maskFeather))
      if propSlider("Feather:", fe, 0, 250):
        let v = fe.float
        d.stepOnce("Mask Feather", proc () = (L.maskFeather = v; d.markAll()))
      let (inv, off) = twoButtons("Invert", if L.maskOff: "Enable" else: "Disable")
      if inv:
        d.layersChange("Invert Mask"):
          d.touch(L.mask, d.bounds)
          for v in L.mask.px.mitems: v = (v and 0xFF000000'u32) or (not v and 0x00FFFFFF'u32)
          inc L.mask.ver
          d.markAll()
      if off:
        d.layersChange("Layer Mask"):
          L.maskOff = not L.maskOff
          d.markAll()
      let (ap, de) = twoButtons("Apply", "Delete")
      if ap:
        d.layersChange("Apply Layer Mask"): d.removeLayerMask(apply = true)
      if de:
        d.layersChange("Delete Layer Mask"): d.removeLayerMask()
      if button("Select and Mask...", w = available()):
        # (the mask as the selection, refined, back into the mask)
        smOutput = 1
        d.beginStep("Load Selection")
        d.touchSel()
        var m = newSeq[uint8](d.w * d.h)
        for i, v in L.mask.px: m[i] = uint8(v and 255)
        d.setSelection(m, soReplace)
        d.endStep()
        runCommand("Select and Mask...")
  elif not L.background and L.adjust.kind.len == 0 and not L.group:
    if button("Add Layer Mask", w = dp(130)):
      d.layersChange("Add Layer Mask"):
        d.addLayerMask(if d.hasSelection: mfRevealSelection else: mfRevealAll)
        d.editMask = true
  # Quick Actions: what is done most often with what is picked, a click away
  let qa = quickActions(d)
  if qa.len > 0:
    group("Quick Actions"):
      # (two a row when their words fit -- else one a row, as wide as the panel)
      let bw = max(dp(60), (available() - Gap) div 2)
      var widest = 0
      for (l, _) in qa: widest = max(widest, textWidth(l) + dp(16))
      let per = if widest <= bw: 2 else: 1
      var i = 0
      while i < qa.len:
        row:
          for k in i ..< min(i + per, qa.len):
            if button(qa[k][0], w = (if per == 2: bw else: available())):
              if qa[k][1] == "\1warp": startWarp() else: runCommand(qa[k][1])
        i += per
  endScroll()

proc quickActions(d: Doc): seq[(string, string)] =
  ## (label, command) of the Properties panel's Quick Actions, for what is
  ## picked: a selection, type, a shape, an adjustment, a picture.
  let L = d.current
  if d.hasSelection:
    @[("Select and Mask", "Select and Mask..."), ("Content-Aware Fill", "Content-Aware Fill"),
      ("Layer via Copy", "Layer via Copy"), ("Feather", "Feather..."), ("Invert", "Inverse"),
      ("Deselect", "None")]
  elif L.isText:
    @[("Warp Text", "\1warp"), ("Rasterize Type", "Rasterize Type"),
      ("Smart Object", "Convert to Smart Object"), ("Free Transform", "Free Transform")]
  elif L.isShape:
    @[("Rasterize", "Rasterize Shape"), ("Merge Shapes", "Merge Shape Components"),
      ("Smart Object", "Convert to Smart Object"), ("Free Transform", "Free Transform")]
  elif L.group or L.adjust.kind.len > 0:
    @[]
  else:
    var r = @[("Remove Background", "Remove Background"), ("Select Subject", "Subject")]
    if d.cur > 0 and not L.background: r.add ("Harmonize", "Harmonize...")
    r.add [("Auto Tone", "Auto Tone"), ("Auto Color", "Auto Color"),
           ("Smart Object", "Convert to Smart Object"), ("Free Transform", "Free Transform")]
    r

# ---- color profiles: Edit > Assign Profile, Convert to Profile ---------------------------------------------------

var
  profOpen = false
  profConvert = false            ## Convert (the pixels changed) or Assign (only the profile)
  profPick = 0

proc startProfile(convert: bool) =
  let d = cur()
  if d == nil: return
  if d.mode notin {cmRGB, cmIndexed}:
    status = "Profiles are for RGB images"
    return
  profConvert = convert
  profPick = max(0, builtInProfileNames.find(d.profileName))
  profOpen = true

proc profileDialog() =
  if not profOpen: return
  let d = cur()
  if d == nil:
    profOpen = false
    return
  dialog(profOpen, if profConvert: "Convert to Profile" else: "Assign Profile", 400):
    group("Source Space"):
      label(tr("Profile: ") & d.profileName)
    group(if profConvert: "Destination Space" else: "Assign Profile"):
      row:
        label "Profile:"
        combo(builtInProfileNames, profPick, w = dp(220))
    label(if profConvert: "The colors stay as they look; the numbers change to the new profile's."
          else: "The numbers stay; the colors look as the profile says they are.", color = ui.theme.gray)
    row:
      spring()
      if button("OK", isDefault = true, w = dp(80)):
        profOpen = false
        let to = builtInProfile(builtInProfileNames[clamp(profPick, 0, builtInProfileNames.high)])
        if profConvert:
          beginBusy("Convert to Profile")
          try:
            d.snapStep("Convert to Profile")
            d.convertProfile(to)
            d.endStep()
          finally: endBusy()
        else:
          d.snapStep("Assign Profile")
          d.icc = if to.isSrgbLike: "" else: to.data
          inc d.ver
          d.markAll()
          d.endStep()
        status = tr("Profile: ") & d.profileName
      if button("Cancel", w = dp(80)): profOpen = false

proc brushFiles() =
  if filePicker(brushFilePick, brushFilePath, (if brushFileSave: fmSave else: fmOpen),
                ["*.abr", "*.gbr", "*.json"], if brushFileSave: "Export Brushes" else: "Import Brushes"):
    try:
      if brushFileSave:
        var p = brushFilePath
        if p.splitFile.ext.len == 0: p &= ".abr"
        if p.splitFile.ext.toLowerAscii == ".json":
          writeFile(p, presetsToJson(presets))
          status = $presets.len & " brushes saved in " & p.extractFilename
        else:
          # (.abr: the sampled tips, which other programs read)
          var custom: seq[BrushTip]
          for b in presets:
            if b.tip.custom.len > 0:
              var t = b.tip
              t.name = b.name
              custom.add t
          writeFile(p, writeAbr(custom))
          status = $custom.len & " brushes saved in " & p.extractFilename
      else:
        let data = readFile(brushFilePath)
        var got: seq[BrushPreset]
        let folder = brushFilePath.splitFile.name
        if brushFilePath.toLowerAscii.endsWith(".json"):
          got = presetsFromJson(data)
        else:
          for t in readBrushes(brushFilePath, data):
            got.add BrushPreset(name: t.name, folder: folder, tip: t)
        if got.len == 0: status = "No brushes we can use in " & brushFilePath.extractFilename
        else:
          for b in got: presets.add b
          savePresets()
          applyPreset(presets[presets.len - got.len])
          status = $got.len & " brushes loaded from " & brushFilePath.extractFilename
    except CatchableError:
      status = "Could not " & (if brushFileSave: "save " else: "read ") & brushFilePath.extractFilename & ": " &
               getCurrentExceptionMsg()

proc proDialogs() =
  brushFiles()
  presetDialog()
  profileDialog()
  actionDialogs()
  batchDialog()
  selectAndMaskDialog()
  newGuideDialog()
  gridDialog()
