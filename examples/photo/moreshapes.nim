# (included by photo.nim) Shapes that keep their settings (retroui/
# liveshapes): Layer > New Shape (More Shapes...) shows them all; one
# clicked is drawn on the page; Shape Options changes its numbers (points,
# depth, roundness, corners each apart...), its fill, stroke and width,
# live -- the shape drawn again where it is, however it was moved or sized.

var
  msDlg = false                  ## More Shapes: the gallery
  lsOpt = false                  ## Shape Options
  lsPics: Table[string, Bitmap]
  lsStart: ShapeData             ## (Shape Options: the shape as it was, for Cancel)
  lsPending = false              ## (Shape Options' step is open: OK ends it, anything else lets it go)

proc lsPicture(k: LiveShape): Bitmap =
  let key = $k
  if key in lsPics: return lsPics[key]
  let d = newDoc(96, 72, 0'u32)
  discard d.addShapeLayer(ShapeData(path: liveShapePath(defaultParams(k), 6, 6, 90, 66),
                                    fill: solidPaint(0xFF2A9D8F'u32), stroke: solidPaint(0xFF1B4D45'u32),
                                    strokeWidth: 1.5))
  result = d.toBitmap(0xFFFFFFFF'u32)
  lsPics[key] = result

proc liveOf(L: Layer): tuple[ok: bool; p: ShapeParams; box, drawn: array[4, float]] =
  ## (a live shape layer's settings: its kind and numbers, the box it was drawn in, where its
  ## outline was then)
  if L == nil or not L.isShape or not L.meta.startsWith("{\"live\""): return
  try:
    let j = parseJson(L.meta)
    let (ok, p) = paramsFrom(j)
    if not ok: return
    result.ok = true
    result.p = p
    let b = j{"box"}.getElems
    let dr = j{"drawn"}.getElems
    if b.len == 4 and dr.len == 4:
      for i in 0 .. 3:
        result.box[i] = b[i].getFloat
        result.drawn[i] = dr[i].getFloat
  except CatchableError: discard

proc liveMeta(p: ShapeParams; box: array[4, float]; path: Path): string =
  var j = p.toJson
  j["box"] = %box
  let (x0, y0, x1, y1) = pathBounds(path)
  j["drawn"] = %[x0, y0, x1, y1]
  $j

proc redrawLive(d: Doc; L: Layer; p: ShapeParams) =
  ## (the shape drawn again with `p`, in its box as the layer was moved or sized since)
  let lv = liveOf(L)
  if not lv.ok: return
  var box = lv.box
  let (cx0, cy0, cx1, cy1) = pathBounds(L.shape.path)
  let (dx0, dy0, dx1, dy1) = (lv.drawn[0], lv.drawn[1], lv.drawn[2], lv.drawn[3])
  if dx1 > dx0 and dy1 > dy0 and cx1 > cx0 and cy1 > cy0:
    # (moved or sized since: the box goes with it)
    let kx = (cx1 - cx0) / (dx1 - dx0)
    let ky = (cy1 - cy0) / (dy1 - dy0)
    box = [cx0 + (box[0] - dx0) * kx, cy0 + (box[1] - dy0) * ky, cx0 + (box[2] - dx0) * kx, cy0 + (box[3] - dy0) * ky]
  var sh = L.shape
  sh.path = liveShapePath(p, box[0], box[1], box[2], box[3])
  sh.kind = $p.kind
  d.setShape(L, sh)
  L.meta = liveMeta(p, box, sh.path)

proc insertLiveShape(k: LiveShape) =
  let d = cur()
  if d == nil: return
  let side = min(d.w, d.h).float * 0.3
  var box = [(d.w.float - side * 1.3) / 2, (d.h.float - side) / 2, (d.w.float + side * 1.3) / 2,
             (d.h.float + side) / 2]
  if d.hasSelection:
    let r = d.clip(d.selBounds)
    box = [r.x.float, r.y.float, float(r.x + r.w), float(r.y + r.h)]
  let p = defaultParams(k)
  let path = liveShapePath(p, box[0], box[1], box[2], box[3])
  d.beginStep("New " & $k)
  d.touchLayers()
  let L = d.addShapeLayer(ShapeData(path: path, fill: solidPaint(fg or 0xFF000000'u32), kind: $k), $k)
  L.meta = liveMeta(p, box, path)
  d.cur = d.layers.find(L)
  d.endStep()
  d.markAll()
  status = $k & ": Layer > Shape Options changes its settings (Move tool and Free Transform keep them)"

proc startMoreShapes() = msDlg = true

proc startShapeOptions() =
  let d = cur()
  if d == nil or not liveOf(d.current).ok:
    status = "Shape Options: pick a shape made from More Shapes."
    return
  lsStart = d.current.shape
  d.beginStep("Shape Options")
  d.touchLayers()
  d.touch(d.current, d.bounds)
  lsOpt = true
  lsPending = true

proc moreShapesDialogs() =
  if not lsOpt and lsPending:
    # (Shape Options closed from outside it: as Cancel)
    lsPending = false
    let d = cur()
    if d != nil and d.stepOpen:
      d.cancelStep()
      d.markAll()
  if msDlg:
    var pick = -1
    dialog(msDlg, "More Shapes", 600):
      label("A shape keeps its settings: Layer > Shape Options changes them later.", color = ui.theme.gray)
      adaptive(104):
        for k in LiveShape:
          let r = place(dp(100), dp(76) + lineHeight())
          let hit = interact(idOf("lsh:" & $k), r, focusable = false)
          if hit.hover: fill(r, hoverColor())
          drawBitmap(rect(r.x + dp(2), r.y + dp(2), dp(96), dp(72)), lsPicture(k))
          text(r.x + dp(2), r.y + dp(76), tr($k), ui.theme.text, style(size = 0.85))
          if hit.clicked: pick = ord(k)
      row:
        spring()
        if button("Close", w = dp(80)): msDlg = false
    if pick >= 0:
      msDlg = false
      insertLiveShape(LiveShape(pick))
  if lsOpt:
    let d = cur()
    let L = if d != nil: d.current else: nil
    let lv = liveOf(L)
    if not lv.ok:
      lsOpt = false
      lsPending = false
      if d != nil and d.stepOpen: d.endStep()
      return
    var p = lv.p
    var sh = L.shape
    var ok, cancel = false
    dialog(lsOpt, "Shape Options: " & tr($p.kind), 380):
      for i, prm in paramsOf(p.kind):
        row([130, -1, 50]):
          label tr(prm.name) & ":"
          var v = int(round(p.v[i]))
          if slider(v, int(prm.lo), int(prm.hi), ticks = 0): p.v[i] = v.float
          var e = v
          if spin(e, int(prm.lo), int(prm.hi), w = dp(56)): p.v[i] = e.float
      group("Fill and Stroke"):
        row:
          var fillOn = sh.fill.kind != spNone
          if checkbox("Fill", fillOn): sh.fill = if fillOn: solidPaint(fg or 0xFF000000'u32) else: ShapePaint()
          if sh.fill.kind == spColor:
            var c = sh.fill.color
            if colorWell(c, "lsfill", dp(40), alpha = true): sh.fill.color = c
          var strokeOn = sh.stroke.kind != spNone and sh.strokeWidth > 0
          if checkbox("Stroke", strokeOn):
            if strokeOn:
              sh.stroke = solidPaint(bg or 0xFF000000'u32)
              if sh.strokeWidth <= 0: sh.strokeWidth = 3
            else: sh.stroke = ShapePaint()
          if sh.stroke.kind == spColor:
            var c = sh.stroke.color
            if colorWell(c, "lsstroke", dp(40), alpha = true): sh.stroke.color = c
            var sw = int(round(sh.strokeWidth))
            if spin(sw, 0, 500, w = dp(56)): sh.strokeWidth = sw.float
            label "px"
      row:
        if button("Reset", w = dp(80)): p = defaultParams(p.kind)
        spring()
        if button("OK", isDefault = true, w = dp(80)): ok = true
        if button("Cancel", w = dp(80)): cancel = true
    if (p != lv.p or sh.fill != L.shape.fill or sh.stroke != L.shape.stroke or sh.strokeWidth != L.shape.strokeWidth) and
       not cancel:
      var s2 = L.shape
      s2.fill = sh.fill
      s2.stroke = sh.stroke
      s2.strokeWidth = sh.strokeWidth
      d.setShape(L, s2)
      d.redrawLive(L, p)
    if cancel or (not lsOpt and not ok):
      lsOpt = false
      lsPending = false
      if d.stepOpen: d.cancelStep()
      d.markAll()
    elif ok:
      lsOpt = false
      lsPending = false
      if d.stepOpen: d.endStep()
