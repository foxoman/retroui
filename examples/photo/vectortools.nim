# (included by photo.nim) The drawing program's tools on shapes and paths (retroui/pathtools,
# liveeffects, pathbrush): Group Selection, the Magic Wand and the Lasso for shapes and their
# points; the vector Paintbrush (its brush live: Calligraphic, Art, Pattern, Scatter), the Blob
# Brush, Smooth, Path Eraser, Join; the Eraser on shapes, Scissors, Knife; the Width tool. Then the
# Brushes (vector) and Appearance panels and the live effects (Layer > Live Effects), each in a
# box that shows it on the shape as it is set. They work as the drawing program's: what a drag
# makes is one step, undone as one.

var
  vd: tuple[on: bool; dw: DocWin; pts: seq[(float, float)]; pressures: seq[float]; layer: Layer;
            moving: bool; x0, y0: float; shapes0: seq[(Layer, ShapeData)]]
  meshDrag: tuple[on: bool; layer: Layer; idx: int; box: (float, float, float, float)]
    ## (the Mesh tool: the point being moved, in the shape's box as it was when pressed)
  persDrag: tuple[on: bool; layer: Layer; path: Path; u0, v0: float]
    ## (Perspective Selection: the shape moved along the active plane, its path as it was)
    ## (a drag of the tool under way: where it went, and what it moves)
  vecPts: tuple[d: Doc; layer: Layer; pts: seq[tuple[sub, i: int]]]
    ## the points the Lasso (Points) picked: Delete takes them out, a drag on one moves them all
  vecGroupClick: tuple[d: Doc; layer: Layer]   ## (Group Selection: the layer the last click picked)
  wandBy: set[WandBy] = {wbFill}               ## the Magic Wand (Shapes): what it compares
  vWandTol = 32                                ## ... how near, levels (or %, or tenths of a pixel)
  vbrush = StrokeBrush(kind: sbCalligraphic, name: "5 pt. Oval", angle: 45, roundness: 40)
    ## the Paintbrush (Vector)'s brush (the Brushes panel picks it)
  vbrushW = 6                                  ## ... its width, pixels
  vbrushFit = 4                                ## ... how far the curve may stray from the hand, pixels
  vbrushFill = false                           ## ... the strokes filled too (Fill New Brush Strokes)
  blobSize = 16                                ## the Blob Brush's size
  vEraserSize = 16                             ## the Eraser (Shapes)'s size
  pathEraserSize = 8                           ## the Path Eraser's and Smooth's reach
  widthDrag: tuple[on: bool; layer: Layer; t: float; idx: int; s0: ShapeData]
    ## (the Width tool: the width point being pulled)
  userBrushes: seq[StrokeBrush]                ## brushes made from shapes (New Brush in the panel)

var widthProfiles: seq[tuple[name: string; ws: seq[WidthPoint]]] = @[
  ("Uniform", newSeq[WidthPoint]()),
  ("Width Profile 1", @[WidthPoint(t: 0, w: 0), WidthPoint(t: 0.5, w: 1), WidthPoint(t: 1, w: 0)]),
  ("Width Profile 2", @[WidthPoint(t: 0, w: 1), WidthPoint(t: 1, w: 0)]),
  ("Width Profile 3", @[WidthPoint(t: 0, w: 0), WidthPoint(t: 1, w: 1)]),
  ("Width Profile 4", @[WidthPoint(t: 0, w: 1), WidthPoint(t: 0.5, w: 0.3), WidthPoint(t: 1, w: 1)]),
  ("Width Profile 5", @[WidthPoint(t: 0, w: 0), WidthPoint(t: 0.2, w: 1), WidthPoint(t: 0.8, w: 1), WidthPoint(t: 1, w: 0)]),
  ("Width Profile 6", @[WidthPoint(t: 0, w: 1), WidthPoint(t: 0.25, w: 0.2), WidthPoint(t: 0.5, w: 1),
                        WidthPoint(t: 0.75, w: 0.2), WidthPoint(t: 1, w: 1)])]
  ## the width profiles: those it comes with, then the ones saved (the Width tool's options)
var widthProfilePick = 0

# (the Gap tool, the Content Collector and Placer)
type ConveyorItem = object
  name: string
  layers: seq[Layer]           ## copies, each `w` x `h`: the box they were in, its top left their 0, 0
  w, h: int

var
  gapDrag: tuple[on: bool; dw: DocWin; g: GapInfo; x0, y0: float; kind: GapKind; used: float]
  conveyor: seq[ConveyorItem]  ## the Content Collector's conveyor (as long as the app is open)
  conveyorAt = 0               ## the one the Content Placer puts down
  placeMode = 0                ## after it: 0 taken off and the next loaded, 1 kept and the next loaded, 2 kept

proc gapKindOf(ev: PhotoEvent): GapKind =
  if ev.ctrl and ev.alt: gkSpread
  elif ev.ctrl: gkResize
  elif ev.alt: gkMoveObjects
  else: gkMove

proc collect(d: Doc; layers: seq[Layer]) =
  ## (the Content Collector: copies of `layers` -- their box's pixels -- on the conveyor, the
  ## Content Placer to put down next)
  var x0, y0 = 1e18
  var x1, y1 = -1e18
  var ls: seq[Layer]
  for L in layers:
    let b = d.objectBox(L)
    if not b.ok: continue
    ls.add L
    x0 = min(x0, b.x0); y0 = min(y0, b.y0); x1 = max(x1, b.x1); y1 = max(y1, b.y1)
  if ls.len == 0: return
  let bx = int(floor(x0))
  let by = int(floor(y0))
  let w = clamp(int(ceil(x1)) - bx, 1, 16384)
  let h = clamp(int(ceil(y1)) - by, 1, 16384)
  var item = ConveyorItem(name: (if ls.len == 1: ls[0].name else: $ls.len & tr(" objects")), w: w, h: h)
  for L in ls: item.layers.add layerFor(L, d.w, d.h, w, h, -bx, -by)
  conveyor.add item
  conveyorAt = conveyor.high
  status = tr("Content Collector: on the conveyor -- ") & item.name & " (" & $conveyor.len & ")"

proc placeConveyor(d: Doc; x, y: float) =
  ## (the Content Placer: the conveyor's item put down with its top left at `x, y`)
  if conveyor.len == 0:
    status = "Content Placer: the conveyor is empty -- collect objects with the Content Collector first"
    return
  conveyorAt = clamp(conveyorAt, 0, conveyor.high)
  let it = conveyor[conveyorAt]
  var copies: seq[Layer]
  for L in it.layers: copies.add layerFor(L, it.w, it.h, d.w, d.h, int(round(x)), int(round(y)))
  if te.on: commitType()
  d.beginStep("Content Placer")
  d.touchLayers()
  discard d.placeLayers(copies)
  d.endStep()
  status = tr("Content Placer: put down -- ") & it.name
  case placeMode
  of 0:
    conveyor.delete(conveyorAt)
    if conveyorAt > conveyor.high: conveyorAt = 0
  of 1:
    conveyorAt = (conveyorAt + 1) mod conveyor.len
  else: discard

const calligraphicPresets = [("3 pt. Round", 0.0, 100.0, 3), ("5 pt. Oval", 45.0, 40.0, 5),
                             ("10 pt. Flat", 30.0, 10.0, 10), ("15 pt. Oval", 60.0, 50.0, 15),
                             ("20 pt. Flat", 0.0, 8.0, 20)]
  ## (the Calligraphic brushes it comes with: name, angle, roundness, size)

proc allBrushes(): seq[tuple[b: StrokeBrush; size: int]] =
  ## The Brushes panel's brushes: Basic, the calligraphic ones, the artwork ones, the user's.
  result.add (StrokeBrush(kind: sbNone, name: "Basic"), 0)
  for (n, a, r, s) in calligraphicPresets:
    result.add (StrokeBrush(kind: sbCalligraphic, name: n, angle: a, roundness: r), s)
  for n in BuiltinBrushes: result.add (strokeBrushOf(n), 0)
  for b in userBrushes: result.add (b, 0)

proc vecShapeAt(d: Doc; x, y: float; radius: int): Layer =
  ## (the top shape layer under the point -- its fill or near its outline)
  for i in d.layersUnder(int(floor(x)), int(floor(y)), radius):
    if d.layers[i].isShape: return d.layers[i]
  for i in countdown(d.layers.high, 0):
    let L = d.layers[i]
    if L.isShape and L.visible and L.shape.path.nearestSegment(x, y, radius.float).sub >= 0: return L

proc vecTargets(d: Doc): seq[Layer] =
  ## (the shape layers a tool works on: those picked, else the current one)
  for i in d.pickedLayers:
    if d.layers[i].isShape: result.add d.layers[i]
  if result.len == 0 and d.current.isShape: result.add d.current

proc lengthFraction(sp: SubPath; at: float): float =
  ## (how far along a subpath, 0..1 of its length, place `at` is: as width points are kept)
  let n = sp.pts.len
  let segs = if sp.closed: n else: n - 1
  if segs <= 0: return 0
  var total = 0.0
  var before = 0.0
  for k in 0 ..< segs:
    let one = Path(subs: @[SubPath(pts: @[sp.pts[k], sp.pts[(k + 1) mod n]])])
    var l = 0.0
    for poly in one.flatten(8):
      for i in 1 ..< poly.len: l += hypot(poly[i][0] - poly[i - 1][0], poly[i][1] - poly[i - 1][1])
    if k < int(floor(at)): before += l
    elif k == int(floor(at)): before += l * (at - floor(at))
    total += l
  if total <= 1e-9: 0.0 else: clamp(before / total, 0.0, 1.0)

proc newShapeLike(d: Doc; L: Layer; p: Path; name = ""): Layer =
  ## (a shape layer more, as `L` is but its path, over it)
  var s = L.shape
  s.path = p
  result = d.addShapeLayer(s, name = (if name.len > 0: name else: L.name), above = d.layers.find(L))
  result.opacity = L.opacity
  result.mode = L.mode
  result.fx = L.fx

# ---- the tools on the image ------------------------------------------------------------------------------

proc vecRelease(dw: DocWin; ev: PhotoEvent)

proc vectorEvents(dw: DocWin; ev: PhotoEvent): bool =
  ## A press, drag and release of the drawing program's tools; true when the tool took it.
  if tool != tVector or ev.right: return false
  let d = dw.doc
  let r = dw.pickRadius
  if gapDrag.on and gapDrag.dw == dw:
    # (the Gap tool: the gap dragged -- the objects about it as they were, then as far as it went)
    let delta = if gapDrag.g.vertical: ev.x - gapDrag.x0 else: ev.y - gapDrag.y0
    if ev.down and ev.moved:
      if d.stepOpen: d.cancelStep()
      d.beginStep("Gap Tool")
      d.touchLayers()
      gapDrag.used = d.applyGap(gapDrag.g, delta, gapDrag.kind)
    if ev.released or not ui.mouseDown:
      gapDrag.on = false
      if d.stepOpen:
        if abs(gapDrag.used) < 0.5: d.cancelStep() else: d.endStep()
    return true
  if vd.on and vd.dw == dw:
    if ev.down and ev.moved:
      if vd.pts.len == 0 or hypot(ev.x - vd.pts[^1][0], ev.y - vd.pts[^1][1]) >= 0.75:
        vd.pts.add (ev.x, ev.y)
        vd.pressures.add ui.pressure
      if vd.moving:
        # (picked shapes, or picked points, dragged: from where they were)
        let dx = ev.x - vd.x0
        let dy = ev.y - vd.y0
        for (L, s0) in vd.shapes0:
          var s = s0
          if vecPts.layer == L and vecPts.pts.len > 0:
            for (sub, i) in vecPts.pts:
              if sub < s.path.subs.len and i < s.path.subs[sub].pts.len:
                var q = s.path.subs[sub].pts[i]
                q.p = (q.p[0] + dx, q.p[1] + dy)
                q.inH = (q.inH[0] + dx, q.inH[1] + dy)
                q.outH = (q.outH[0] + dx, q.outH[1] + dy)
                s.path.subs[sub].pts[i] = q
          else:
            s.path = translated(s0.path, dx, dy)
          d.setShape(L, s)
      if meshDrag.on and meshDrag.layer != nil and meshDrag.layer.isShape:
        var s = meshDrag.layer.shape
        let b = meshDrag.box
        if meshDrag.idx >= 0 and meshDrag.idx < s.fill.points.len:
          s.fill.points[meshDrag.idx].x = (ev.x - b[0]) / max(1e-9, b[2] - b[0])
          s.fill.points[meshDrag.idx].y = (ev.y - b[1]) / max(1e-9, b[3] - b[1])
          d.setShape(meshDrag.layer, s)
      if persDrag.on and persDrag.layer != nil and persDrag.layer.isShape:
        let pl = vpPlane(d.pgOf.planeQuad(d.pgOf.active))
        if pl.ok and pl.onFront(ev.x, ev.y):
          let (u1, v1) = pl.toPlane(ev.x, ev.y)
          let du = u1 - persDrag.u0
          let dv = v1 - persDrag.v0
          var s = persDrag.layer.shape
          var np = persDrag.path
          np.mapPoints(proc (x, y: float): (float, float) =
            let (u, v) = pl.toPlane(x, y)
            pl.toImage(u + du, v + dv))
          s.path = np
          d.setShape(persDrag.layer, s)
      if widthDrag.on and widthDrag.layer != nil:
        # (the width point pulled: the stroke this wide at it, twice the pointer's distance)
        var s = widthDrag.s0
        var dist = 0.0
        block:
          # (the distance from the place on the path where the drag began)
          let hp = s.path.nearestSegment(vd.x0, vd.y0, 1e9)
          if hp.sub >= 0:
            let sp = s.path.subs[hp.sub]
            let a = sp.pts[hp.i]
            let b = sp.pts[(hp.i + 1) mod sp.pts.len]
            let t = hp.t
            let mt = 1 - t
            let px = mt * mt * mt * a.p[0] + 3 * mt * mt * t * a.outH[0] + 3 * mt * t * t * b.inH[0] + t * t * t * b.p[0]
            let py = mt * mt * mt * a.p[1] + 3 * mt * mt * t * a.outH[1] + 3 * mt * t * t * b.inH[1] + t * t * t * b.p[1]
            dist = hypot(ev.x - px, ev.y - py)
        let w = clamp(2 * dist / max(0.5, s.strokeWidth), 0.0, 50.0)
        if widthDrag.idx >= 0 and widthDrag.idx < s.widths.len: s.widths[widthDrag.idx].w = w
        d.setShape(widthDrag.layer, s)
    if ev.released or not ui.mouseDown:
      vd.on = false
      widthDrag.on = false
      meshDrag.on = false
      persDrag.on = false
      dw.vecRelease(ev)
    return true
  if not ev.pressed or not ev.over: return false
  vd = (true, dw, @[(ev.x, ev.y)], @[ui.pressure], d.current, false, ev.x, ev.y, @[])
  case vecMode
  of 0:
    # Group Selection: a click picks the shape (or any layer) under it; a second click on it, its group
    let i = d.layerAt(int(floor(ev.x)), int(floor(ev.y)), r)
    if i < 0:
      d.clearPicks()
      vecGroupClick = (nil, nil)
      inc d.ver
      vd.on = false
      return true
    let L = d.layers[i]
    var pick = @[L]
    if vecGroupClick.d == d and vecGroupClick.layer == L and not ev.shift:
      pick = d.groupOfLayer(L)
      status = "Group Selection: the group (" & $pick.len & " layers)"
    else: status = "Group Selection: " & L.name & " (click again: its group)"
    vecGroupClick = (d, L)
    if not ev.shift: d.clearPicks()
    for M in pick: M.picked = true
    d.cur = i
    d.editMask = false
    inc d.ver
    # (dragged: the picked shapes move)
    d.beginStep("Group Selection")
    d.touchLayers()
    for k in d.pickedLayers:
      let M = d.layers[k]
      if M.isShape: vd.shapes0.add (M, M.shape)
    if L.isShape and L notin pick: vd.shapes0.add (L, L.shape)
    vd.moving = vd.shapes0.len > 0
  of 1:
    # the Magic Wand (Shapes): the shapes like the one clicked; Shift adds, Alt takes away
    let L = d.vecShapeAt(ev.x, ev.y, r)
    if L == nil:
      if not ev.shift and not ev.alt: d.clearPicks()
      status = "Magic Wand (Shapes): click a shape"
    else:
      let like = d.similarShapes(L, wandBy, vWandTol)
      if not ev.shift and not ev.alt: d.clearPicks()
      for M in like: M.picked = not ev.alt
      if not ev.alt: d.cur = d.layers.find(L)
      status = "Magic Wand (Shapes): " & $d.pickedLayers.len & " shapes picked"
    inc d.ver
    vd.on = false
  of 2:
    # the Lasso (Points): a press on a picked point drags them all; else a loop round the points to pick
    if vecPts.d == d and vecPts.layer != nil and vecPts.layer in d.layers and vecPts.pts.len > 0:
      let p = vecPts.layer.shape.path
      let h = p.hitPoint(ev.x, ev.y, r.float, handles = false)
      if h.sub >= 0 and (h.sub, h.i) in vecPts.pts:
        d.beginStep("Move Points")
        d.touchLayers()
        vd.shapes0 = @[(vecPts.layer, vecPts.layer.shape)]
        vd.moving = true
  of 3, 4, 5, 6, 7, 8, 10, 14:
    discard                                     # (the line drawn: made when it ends)
  of 15:
    # the Gap tool: the gap under the pointer taken (Shift: between the two nearest only)
    vd.on = false
    let (ok, g) = d.gapAt(ev.x, ev.y, nearest = ev.shift)
    if not ok:
      status = "Gap Tool: point at the space between objects, or between one and the page's edge"
      return true
    gapDrag = (true, dw, g, ev.x, ev.y, gapKindOf(ev), 0.0)
    status = tr("Gap Tool: ") & tr($gapDrag.kind)
  of 16:
    # the Content Collector: the object clicked on the conveyor (with others picked: those)
    vd.on = false
    let i = d.layerAt(int(floor(ev.x)), int(floor(ev.y)), r)
    if i < 0:
      status = "Content Collector: click an object to put a copy of it on the conveyor"
      return true
    let L = d.layers[i]
    var ls = @[L]
    if L.picked:
      ls = @[]
      for k in d.pickedLayers: ls.add d.layers[k]
    d.collect(ls)
  of 17:
    # the Content Placer: the conveyor's item put down where it is clicked
    vd.on = false
    d.placeConveyor(ev.x, ev.y)
  of 9:
    # Scissors: the path cut where it is clicked
    let L = d.vecShapeAt(ev.x, ev.y, r)
    vd.on = false
    if L == nil:
      status = "Scissors: click on a shape's outline"
      return true
    let at = L.shape.path.nearestPlace(ev.x, ev.y, r.float * 2)
    if at.sub < 0:
      status = "Scissors: click on the outline itself"
      return true
    let wasClosed = L.shape.path.subs[at.sub].closed
    let cut = cutAt(L.shape.path, at.sub, at.at)
    d.beginStep("Scissors")
    d.touchLayers()
    var s = L.shape
    if wasClosed or cut.subs.len == L.shape.path.subs.len:
      s.path = cut
      d.setShape(L, s)
    else:
      # (an open path in two: the second part a shape of its own, as the drawing program leaves it)
      var first = cut
      first.subs.delete(at.sub + 1)
      s.path = first
      d.setShape(L, s)
      discard d.newShapeLike(L, Path(subs: @[cut.subs[at.sub + 1]]))
    d.endStep()
    status = if wasClosed: "Scissors: the outline opened there" else: "Scissors: the path cut in two"
  of 11:
    # the Width tool: a press on the stroke pulls a width point (Alt+click one: taken away)
    let L = d.vecShapeAt(ev.x, ev.y, r)
    if L == nil or L.shape.stroke.kind == spNone or L.shape.strokeWidth <= 0:
      vd.on = false
      status = "Width: press on a stroked shape's outline and drag across it"
      return true
    let at = L.shape.path.nearestPlace(ev.x, ev.y, max(r.float, L.shape.strokeWidth))
    if at.sub < 0:
      vd.on = false
      return true
    let t = lengthFraction(L.shape.path.subs[at.sub], at.at)
    var s = L.shape
    var idx = -1
    for k, wp in s.widths:
      if abs(wp.t - t) < 0.02: idx = k
    d.beginStep("Width")
    d.touchLayers()
    if ev.alt:
      if idx >= 0:
        s.widths.delete(idx)
        d.setShape(L, s)
      vd.on = false
      d.endStep()
      return true
    if idx < 0:
      # (a new width point, as wide as the stroke is there)
      let here = widthAt(s.widths, t)
      if s.widths.len == 0: s.widths = @[WidthPoint(t: 0, w: 1), WidthPoint(t: 1, w: 1)]
      s.widths.add WidthPoint(t: t, w: here)
      s.widths.sort(proc (a, b: WidthPoint): int = cmp(a.t, b.t))
      for k, wp in s.widths:
        if wp.t == t: idx = k
      d.setShape(L, s)
    widthDrag = (true, L, t, idx, s)
    d.cur = d.layers.find(L)
  of 12:
    # the Mesh tool: a click in a shape puts a line across and down through it (its point the
    # foreground color); a point dragged moves, its colors bending with it; Shift+click a point:
    # the foreground color; Alt+click: it goes with its lines
    var L = d.vecShapeAt(ev.x, ev.y, r)
    if L == nil and d.current.isShape: L = d.current
    if L == nil:
      vd.on = false
      status = "Mesh: click inside a shape"
      return true
    var s = L.shape
    let b = pathBounds(s.path)
    let bw = max(1e-9, b[2] - b[0])
    let bh = max(1e-9, b[3] - b[1])
    let u = (ev.x - b[0]) / bw
    let v = (ev.y - b[1]) / bh
    d.beginStep("Mesh")
    d.touchLayers()
    if not (s.fill.kind == spGradient and s.fill.style == 6 and s.fill.meshCols >= 2):
      # (a shape with no mesh yet: one of its fill's color, four corners)
      let c = if s.fill.kind == spColor: s.fill.color else: 0xFFFFFFFF'u32
      s.fill = meshPaint(1, 1, [c])
    let reach = r.float / min(bw, bh) * 1.5
    var idx = meshNearest(s.fill, u, v, reach)
    if idx >= 0 and ev.alt:
      s.fill.meshRemoveAt(idx)
      idx = -1
    elif idx >= 0 and ev.shift:
      s.fill.points[idx].color = fg or 0xFF000000'u32
    elif idx < 0 and not ev.alt:
      idx = s.fill.meshAddLines(u, v, fg or 0xFF000000'u32)
    d.setShape(L, s)
    d.cur = d.layers.find(L)
    meshDrag = (idx >= 0 and not ev.shift, L, idx, b)
    vd.moving = false
  of 13:
    # Perspective Selection: a shape dragged along the grid's active plane -- smaller as it goes back
    let g = d.pgOf
    if not g.shown or g.noActive:
      vd.on = false
      status = "Perspective Selection: show the grid (View > Perspective Grid) and pick a plane in its widget"
      return true
    let L = d.vecShapeAt(ev.x, ev.y, r)
    let pl = vpPlane(g.planeQuad(g.active))
    if L == nil or not pl.ok or not pl.onFront(ev.x, ev.y):
      vd.on = false
      status = "Perspective Selection: press on a shape on the plane and drag it along"
      return true
    let (u0, v0) = pl.toPlane(ev.x, ev.y)
    d.beginStep("Perspective Selection")
    d.touchLayers()
    d.cur = d.layers.find(L)
    persDrag = (true, L, L.shape.path, u0, v0)
  else: vd.on = false
  true

proc vecRelease(dw: DocWin; ev: PhotoEvent) =
  ## (a drag of the tool ended: what it makes)
  let d = dw.doc
  let pts = vd.pts
  if vd.moving:
    vd.moving = false
    if d.stepOpen:
      if hypot(ev.x - vd.x0, ev.y - vd.y0) < 0.5: d.cancelStep() else: d.endStep()
    return
  if vecMode in {11, 12, 13}:
    if d.stepOpen: d.endStep()
    return
  case vecMode
  of 2:
    # the loop: the points inside it picked (on the shape picked, else on every shape it holds)
    if pts.len < 3:
      vecPts = (d, nil, @[])
      inc d.ver
      return
    var best: tuple[L: Layer; pts: seq[tuple[sub, i: int]]]
    for L in d.vecTargets & d.layers:
      if not L.isShape or not L.visible: continue
      let inside = anchorsIn(L.shape.path, pts)
      if inside.len > best.pts.len: best = (L, inside)
      if inside.len > 0 and L in d.vecTargets: break
    vecPts = (d, best.L, best.pts)
    status = if best.L == nil: "Lasso (Points): no points inside" else: $best.pts.len & " points picked on " & best.L.name &
             " (drag one to move them, Delete to take them out)"
    if best.L != nil: d.cur = d.layers.find(best.L)
    inc d.ver
  of 3:
    # the Paintbrush (Vector): the line fitted with curves, stroked with the brush
    if pts.len < 2: return
    let sp = fitPath(pts, vbrushFit.float)
    if sp.pts.len < 2: return
    var s = ShapeData(path: Path(subs: @[sp]), fill: (if vbrushFill: solidPaint(bg) else: ShapePaint(kind: spNone)),
                      stroke: solidPaint(fg), strokeWidth: vbrushW.float, cap: lcRound, join: ljRound,
                      align: saCenter, brush: vbrush)
    # (a pen's pressure: the stroke's width along it)
    var lo = 1.0
    var hi = 0.0
    for p in vd.pressures:
      lo = min(lo, p)
      hi = max(hi, p)
    if hi - lo > 0.05 and vd.pressures.len == pts.len:
      var total = 0.0
      var at = @[0.0]
      for i in 1 ..< pts.len:
        total += hypot(pts[i][0] - pts[i - 1][0], pts[i][1] - pts[i - 1][1])
        at.add total
      let step = max(1, pts.len div 12)
      var i = 0
      while i < pts.len:
        s.widths.add WidthPoint(t: (if total > 0: at[i] / total else: 0.0), w: max(0.05, vd.pressures[i] * 1.5))
        i += step
    d.beginStep("Paintbrush")
    d.touchLayers()
    d.editMask = false
    discard d.addShapeLayer(s, name = (if vbrush.kind == sbNone: "Brush Stroke" else: vbrush.name))
    d.endStep()
  of 4:
    # the Blob Brush: a filled shape, one with the shape of its color under it
    if pts.len < 1: return
    let L = d.current
    let merge = L.isShape and L.shape.fill.kind == spColor and L.shape.fill.color == fg and
                L.shape.stroke.kind == spNone and L.shape.effects.len == 0
    d.beginStep("Blob Brush")
    d.touchLayers()
    d.editMask = false
    if merge:
      var s = L.shape
      s.path = blobMerge(L.shape.path, pts, blobSize / 2)
      s.kind = ""
      d.setShape(L, s)
    else:
      let p = blobMerge(Path(), pts, blobSize / 2)
      if p.subs.len > 0:
        discard d.addShapeLayer(ShapeData(path: p, fill: solidPaint(fg), stroke: ShapePaint(kind: spNone)),
                                name = "Blob")
    d.endStep()
  of 5, 6:
    # Smooth, Path Eraser: on the picked shapes' outlines (or the work path)
    let ts = d.vecTargets
    if ts.len == 0 and (d.curPath < 0 or d.curPath >= d.paths.len):
      status = vecToolNames[vecMode] & ": pick a shape first"
      return
    d.beginStep(vecToolNames[vecMode])
    d.touchLayers()
    var changed = false
    if ts.len == 0:
      d.touchPaths()
      let p = d.paths[d.curPath]
      let np = if vecMode == 5: smoothPath(p, pts, pathEraserSize.float) else: erasePath(p, pts, pathEraserSize.float)
      if np != p:
        d.paths[d.curPath] = np
        changed = true
        inc d.ver
    for L in ts:
      let p = L.shape.path
      let np = if vecMode == 5: smoothPath(p, pts, pathEraserSize.float) else: erasePath(p, pts, pathEraserSize.float)
      if np == p: continue
      changed = true
      if np.subs.len == 0:
        d.deleteLayer(d.layers.find(L))
      else:
        var s = L.shape
        s.path = np
        s.kind = ""
        d.setShape(L, s)
    if changed: d.endStep() else: d.cancelStep()
  of 7:
    # Join: the two open ends nearest where the scrub began and ended
    let reach = max(dw.pickRadius.float * 3, 8.0)
    var ends: seq[tuple[L: Layer; sub: int; atEnd: bool; pt: (float, float)]]
    for L in d.layers:
      if not L.isShape or not L.visible: continue
      for e in openEnds(L.shape.path): ends.add (L, e.sub, e.atEnd, e.pt)
    proc nearest(p: (float, float); skip: int): int =
      result = -1
      var best = reach
      for k, e in ends:
        if k == skip: continue
        let dd = hypot(e.pt[0] - p[0], e.pt[1] - p[1])
        if dd < best:
          best = dd
          result = k
    let a = nearest(pts[0], -1)
    let b = nearest(pts[^1], a)
    if a < 0 or b < 0:
      status = "Join: drag from one open end to another (or over a gap)"
      return
    let ea = ends[a]
    let eb = ends[b]
    d.beginStep("Join")
    d.touchLayers()
    if ea.L == eb.L and ea.sub == eb.sub:
      var s = ea.L.shape
      s.path = joinEnds(s.path, ea.sub, ea.atEnd, Path(), -1, false).path
      d.setShape(ea.L, s)
      status = "Join: the path closed"
    elif ea.L == eb.L:
      var s = ea.L.shape
      let joined = joinEnds(s.path, ea.sub, ea.atEnd, s.path, eb.sub, eb.atEnd).path
      var np = joined
      np.subs.delete(eb.sub)
      s.path = np
      d.setShape(ea.L, s)
      status = "Join: two paths made one"
    else:
      var s = ea.L.shape
      s.path = joinEnds(s.path, ea.sub, ea.atEnd, eb.L.shape.path, eb.sub, eb.atEnd).path
      d.setShape(ea.L, s)
      var rest = eb.L.shape
      rest.path.subs.delete(eb.sub)
      if rest.path.subs.len == 0: d.deleteLayer(d.layers.find(eb.L))
      else: d.setShape(eb.L, rest)
      d.cur = d.layers.find(ea.L)
      status = "Join: two paths made one"
    d.endStep()
  of 8:
    # the Eraser (Shapes): what it went over taken out of the picked filled shapes
    let ts = d.vecTargets
    if ts.len == 0:
      status = "Eraser (Shapes): pick the shapes to erase first"
      return
    d.beginStep("Eraser (Shapes)")
    d.touchLayers()
    for L in ts:
      let np = eraseShape(L.shape.path, pts, vEraserSize / 2)
      if np.subs.len == 0: d.deleteLayer(d.layers.find(L))
      else:
        var s = L.shape
        s.path = np
        s.kind = ""
        d.setShape(L, s)
    d.endStep()
  of 10:
    # the Knife: the filled shapes it went across cut along its line, each piece a shape
    if pts.len < 2: return
    var cutAny = false
    d.beginStep("Knife")
    d.touchLayers()
    var ts = d.vecTargets
    if ts.len == 0 or (ts.len == 1 and ts[0] == d.current and d.pickedLayers.len == 0):
      ts = @[]
      for L in d.layers:
        if L.isShape and L.visible and L.shape.fill.kind != spNone: ts.add L
    for L in ts:
      let pieces = knifeCut(L.shape.path, pts)
      if pieces.len <= 1: continue
      cutAny = true
      var s = L.shape
      s.path = pieces[0]
      s.kind = ""
      d.setShape(L, s)
      for k in 1 ..< pieces.len: discard d.newShapeLike(L, pieces[k])
    if cutAny:
      d.endStep()
      status = "Knife: cut"
    else:
      d.cancelStep()
      status = "Knife: drag right across a filled shape"
  of 14:
    # the Shape Builder Tool: the regions dragged across one shape (Alt: taken away)
    if pts.len < 1: return
    if d.shapeBuilderDrag(pts, ev.alt):
      status = if ev.alt: "Shape Builder: the regions taken away" else: "Shape Builder: the regions made one shape"
    else:
      status = "Shape Builder: drag across the parts of overlapping shapes (Alt+drag takes them away)"
  else: discard

proc deletePickedPoints(): bool =
  ## Delete with points picked by the Lasso (Points): they go (a subpath left with one, with it).
  let d = cur()
  if d == nil or tool != tVector or vecPts.d != d or vecPts.layer == nil or vecPts.layer notin d.layers or
     vecPts.pts.len == 0:
    return false
  var s = vecPts.layer.shape
  var byPath = vecPts.pts
  byPath.sort(proc (a, b: tuple[sub, i: int]): int = (if a.sub != b.sub: cmp(b.sub, a.sub) else: cmp(b.i, a.i)))
  d.beginStep("Delete Points")
  d.touchLayers()
  for (sub, i) in byPath: s.path.deletePoint(sub, i)
  for k in countdown(s.path.subs.high, 0):
    if s.path.subs[k].pts.len < 2: s.path.subs.delete(k)
  if s.path.subs.len == 0: d.deleteLayer(d.layers.find(vecPts.layer))
  else:
    s.kind = ""
    d.setShape(vecPts.layer, s)
  d.endStep()
  vecPts = (nil, nil, @[])
  true

proc vectorOverlay(dw: DocWin; ev: PhotoEvent) =
  ## What the tools show: the line being drawn, the brush's size, the points picked, the width points.
  if tool != tVector: return
  let d = dw.doc
  let v = dw.view
  if vd.on and vd.dw == dw and vd.pts.len > 1 and not vd.moving and vecMode notin {0, 11}:
    let c = if vecMode in {3, 4}: color(40, 40, 40) else: color(0, 120, 255)
    for k in 1 ..< vd.pts.len:
      let (ax, ay) = v.toScreen(d, vd.pts[k - 1][0], vd.pts[k - 1][1])
      let (bx, by) = v.toScreen(d, vd.pts[k][0], vd.pts[k][1])
      line(ax, ay, bx, by, c)
    if vecMode == 2:
      let (ax, ay) = v.toScreen(d, vd.pts[^1][0], vd.pts[^1][1])
      let (bx, by) = v.toScreen(d, vd.pts[0][0], vd.pts[0][1])
      line(ax, ay, bx, by, color(0, 120, 255, 120))
  # the Gap tool: the gap under the pointer (or the one dragged, where it is now) shaded
  if vecMode == 15 and (ev.over or gapDrag.on):
    var g: GapInfo
    var ok = false
    if gapDrag.on and gapDrag.dw == dw:
      g = gapDrag.g
      ok = true
      let u = gapDrag.used
      case gapDrag.kind
      of gkMove, gkMoveObjects:
        g.a += u
        g.b += u
      of gkResize, gkSpread:
        g.a -= u / 2
        g.b += u / 2
    else: (ok, g) = d.gapAt(ev.x, ev.y, nearest = ev.shift)
    if ok:
      let (x0, y0, x1, y1) = if g.vertical: (g.a, g.lo, g.b, g.hi) else: (g.lo, g.a, g.hi, g.b)
      let (sx0, sy0) = v.toScreen(d, x0, y0)
      let (sx1, sy1) = v.toScreen(d, x1, y1)
      let gr = rect(min(sx0, sx1), min(sy0, sy1), max(1, abs(sx1 - sx0)), max(1, abs(sy1 - sy0)))
      fill(gr, color(128, 128, 128, 110))
      box(gr, color(90, 90, 90))
      ui.cursor = if g.vertical: curSizeWE else: curSizeNS
  # the Content Collector: the object it would take; the Placer: where the item goes
  if ev.over and vecMode == 16:
    let i = d.layerAt(int(floor(ev.x)), int(floor(ev.y)), dw.pickRadius)
    if i >= 0:
      let b = d.objectBox(d.layers[i])
      if b.ok:
        let (sx0, sy0) = v.toScreen(d, b.x0, b.y0)
        let (sx1, sy1) = v.toScreen(d, b.x1, b.y1)
        box(rect(sx0, sy0, max(1, sx1 - sx0), max(1, sy1 - sy0)), color(0, 120, 255))
  if ev.over and vecMode == 17 and conveyor.len > 0:
    let it = conveyor[clamp(conveyorAt, 0, conveyor.high)]
    let (sx0, sy0) = v.toScreen(d, ev.x, ev.y)
    let (sx1, sy1) = v.toScreen(d, ev.x + it.w.float, ev.y + it.h.float)
    box(rect(sx0, sy0, max(1, sx1 - sx0), max(1, sy1 - sy0)), color(0, 120, 255))
    text(sx0 + dp(4), sy0 + dp(3), it.name, color(0, 90, 220))
  # the size of what paints or erases, round the pointer
  if ev.over and vecMode in {4, 5, 6, 8}:
    let size = case vecMode
               of 4: blobSize.float
               of 8: vEraserSize.float
               else: pathEraserSize.float * 2
    let k = v.scaleOf / pxScale.float
    let rr = size * k / 2
    ellipseOnScreen(int(ui.mx.float - rr), int(ui.my.float - rr), int(ui.mx.float + rr), int(ui.my.float + rr),
                    color(0, 0, 0))
  # the points the Lasso picked
  if vecPts.d == d and vecPts.layer != nil and vecPts.layer in d.layers:
    let p = vecPts.layer.shape.path
    for (sub, i) in vecPts.pts:
      if sub < p.subs.len and i < p.subs[sub].pts.len:
        let (sx, sy) = v.toScreen(d, p.subs[sub].pts[i].p[0], p.subs[sub].pts[i].p[1])
        fill(rect(sx - dp(3), sy - dp(3), dp(6), dp(6)), color(0, 120, 255))
  # the Mesh tool: the current shape's mesh, its lines and points
  if vecMode == 12 and d.current.isShape and d.current.shape.fill.style == 6 and d.current.shape.fill.meshCols >= 2:
    let s = d.current.shape
    let b = pathBounds(s.path)
    let nc = s.fill.meshCols
    let nr = s.fill.meshRows
    proc at(i: int): (int, int) =
      let q = s.fill.points[i]
      v.toScreen(d, b[0] + q.x * (b[2] - b[0]), b[1] + q.y * (b[3] - b[1]))
    for rr in 0 ..< nr:
      for c in 0 ..< nc:
        let (ax, ay) = at(rr * nc + c)
        if c + 1 < nc:
          let (bx, by) = at(rr * nc + c + 1)
          line(ax, ay, bx, by, color(0, 120, 255))
        if rr + 1 < nr:
          let (bx, by) = at((rr + 1) * nc + c)
          line(ax, ay, bx, by, color(0, 120, 255))
    for i in 0 ..< s.fill.points.len:
      let (ax, ay) = at(i)
      fill(rect(ax - dp(3), ay - dp(3), dp(6), dp(6)), color(255, 255, 255))
      box(rect(ax - dp(3), ay - dp(3), dp(6), dp(6)), color(0, 90, 220))
  # the Width tool: the width points of the shape under the pointer (or the current one)
  if vecMode == 11:
    var L = if widthDrag.on: widthDrag.layer else: d.vecShapeAt(ev.x, ev.y, dw.pickRadius)
    if L == nil and d.current.isShape: L = d.current
    if L != nil and L.isShape and L.shape.path.subs.len > 0:
      let sp = L.shape.path.subs[0]
      var poly: seq[(float, float)]
      for pl in Path(subs: @[sp]).flatten(8): poly.add pl
      if poly.len > 1:
        var lens = @[0.0]
        for k in 1 ..< poly.len: lens.add lens[^1] + hypot(poly[k][0] - poly[k - 1][0], poly[k][1] - poly[k - 1][1])
        for wp in L.shape.widths:
          let want = wp.t * lens[^1]
          var k = 0
          while k < lens.high and lens[k + 1] < want: inc k
          let (sx, sy) = v.toScreen(d, poly[k][0], poly[k][1])
          fill(rect(sx - dp(3), sy - dp(3), dp(6), dp(6)), color(255, 255, 255))
          box(rect(sx - dp(3), sy - dp(3), dp(6), dp(6)), color(0, 90, 220))
      if ev.over and not widthDrag.on:
        let at = L.shape.path.nearestPlace(ev.x, ev.y, max(dw.pickRadius.float, L.shape.strokeWidth))
        if at.sub >= 0: ui.cursor = curCrosshair

# ---- the options bar --------------------------------------------------------------------------------------

proc vectorBar() =
  ## The options of the drawing program's tools.
  for k in 0 .. vecToolNames.high:
    if barIcon(vecToolGlyphs[k], vecToolNames[k], down = vecMode == k): vecMode = k
  toolSeparator()
  case vecMode
  of 1:
    for w in WandBy:
      var on = w in wandBy
      if barCheck($w, on):
        if on: wandBy.incl w else: wandBy.excl w
    label "Tolerance:"
    spin(vWandTol, 0, 255, w = dp(56))
  of 3:
    var names: seq[string]
    var k = 0
    for i, (b, _) in allBrushes():
      names.add tr(b.name)
      if b.name == vbrush.name: k = i
    label "Brush:"
    if combo(names, k, w = dp(150)):
      let (b, size) = allBrushes()[k]
      vbrush = b
      if size > 0: vbrushW = size
    label "Width:"
    spin(vbrushW, 1, 500, w = dp(56))
    label "px"
    label "Fidelity:"
    spin(vbrushFit, 1, 20, w = dp(48))
    barCheck("Fill New Brush Strokes", vbrushFill)
    if toolButton("Brushes...", "The Brushes (Vector) panel"): togglePanel("vbrushes")
  of 4:
    label "Size:"
    spin(blobSize, 1, 1000, w = dp(60))
    label("Paints in the foreground color, one shape with the shape of that color under it", color = ui.theme.gray)
  of 5, 6:
    label "Reach:"
    spin(pathEraserSize, 1, 200, w = dp(56))
    label "px"
  of 8:
    label "Size:"
    spin(vEraserSize, 1, 1000, w = dp(60))
  of 0: label("Click a shape; again: its group. Drag: the shapes picked move", color = ui.theme.gray)
  of 2: label("Draw round points to pick them; drag one: they all move; Delete: they go", color = ui.theme.gray)
  of 7: label("Drag from one open end to another (or over a gap)", color = ui.theme.gray)
  of 9: label("Click on an outline to cut it there", color = ui.theme.gray)
  of 12: label("Click in a shape: a mesh line each way (its point the foreground color); drag a point; " &
               "Shift+click: its color; Alt+click: it goes", color = ui.theme.gray)
  of 13: label("Drag a shape along the perspective grid's active plane", color = ui.theme.gray)
  of 10: label("Drag right across filled shapes to cut them", color = ui.theme.gray)
  of 14: label("Drag across the parts of overlapping shapes: one shape; Alt+drag: they go", color = ui.theme.gray)
  of 15: label("Drag the space between objects: they grow and shrink with it. Shift: the two nearest only; " &
               "Ctrl: size the gap; Alt: move the objects; Ctrl+Alt: spread them", color = ui.theme.gray)
  of 16, 17:
    label(tr("Conveyor:") & " " & $conveyor.len)
    if conveyor.len > 0:
      conveyorAt = clamp(conveyorAt, 0, conveyor.high)
      if button("<", w = dp(26)): conveyorAt = (conveyorAt + conveyor.len - 1) mod conveyor.len
      label($(conveyorAt + 1) & ": " & conveyor[conveyorAt].name)
      if button(">", w = dp(26)): conveyorAt = (conveyorAt + 1) mod conveyor.len
    if vecMode == 16:
      let d = cur()
      if button("Collect the Picked", w = dp(140), enabled = d != nil and d.pickedLayers.len > 0):
        var ls: seq[Layer]
        for k in d.pickedLayers: ls.add d.layers[k]
        d.collect(ls)
      label("Click an object: a copy of it on the conveyor", color = ui.theme.gray)
    else:
      combo(["Put down, take off, load the next", "Put down, keep, load the next", "Put down again and again"],
            placeMode, w = dp(240))
      if button("Take Off", w = dp(80), enabled = conveyor.len > 0):
        conveyor.delete(clamp(conveyorAt, 0, conveyor.high))
        if conveyorAt > conveyor.high: conveyorAt = 0
    if button("Empty the Conveyor", w = dp(130), enabled = conveyor.len > 0):
      conveyor.setLen(0)
      conveyorAt = 0
  of 11:
    let d = cur()
    var names: seq[string]
    for (n, _) in widthProfiles: names.add tr(n)
    label "Profile:"
    if combo(names, widthProfilePick, w = dp(150)) and d != nil and d.vecTargets.len > 0:
      d.beginStep("Width Profile")
      d.touchLayers()
      for L in d.vecTargets:
        var s = L.shape
        s.widths = widthProfiles[widthProfilePick].ws
        d.setShape(L, s)
      d.endStep()
    if toolButton("Save Profile", "The picked shape's widths kept as a profile",
                  enabled = d != nil and d.current.isShape and d.current.shape.widths.len > 0):
      widthProfiles.add ("Width Profile " & $widthProfiles.len, d.current.shape.widths)
      widthProfilePick = widthProfiles.high
    label("Drag across a stroke to widen it there; Alt+click a width point: it goes", color = ui.theme.gray)
  else: discard

# ---- the Brushes (vector) panel ---------------------------------------------------------------------------

var brushThumbs: tuple[n, size: int; bmps: seq[Bitmap]]

proc brushThumb(b: StrokeBrush; size: int; w, h: int): Bitmap =
  ## (a stroke drawn with the brush, an S across the box)
  var sp = SubPath()
  sp.pts.add PathPoint(p: (6.0, h.float * 0.7), inH: (6.0, h.float * 0.7), outH: (w.float * 0.45, h.float * 0.05))
  sp.pts.add PathPoint(p: (w.float - 6, h.float * 0.3), inH: (w.float * 0.55, h.float * 0.95),
                       outH: (w.float - 6, h.float * 0.3))
  let s = ShapeData(path: Path(subs: @[sp]), fill: ShapePaint(kind: spNone), stroke: solidPaint(0xFF202020'u32),
                    strokeWidth: (if size > 0: min(h.float * 0.4, size.float) else: h.float * 0.3),
                    cap: lcRound, join: ljRound, brush: b)
  var px = newSeq[uint32](w * h)
  discard renderShape(s, px, w, h)
  result = newBitmap(w, h)
  for i in 0 ..< px.len: result.px[i] = blendPx(0xFFFFFFFF'u32, px[i], 255, bmNormal)
  result.changed()

proc vectorBrushesBody() =
  ## Window > Brushes (Vector): click one -- the picked shapes are stroked with it, and the
  ## Paintbrush (Vector) paints with it.
  let all = allBrushes()
  let tw = dp(120)
  let th = dp(28)
  if brushThumbs.n != all.len or brushThumbs.size != tw:
    brushThumbs = (all.len, tw, newSeq[Bitmap]())
    for (b, size) in all: brushThumbs.bmps.add brushThumb(b, size, tw * pxScale, th * pxScale)
  let d = cur()
  for i, (b, size) in all:
    row([tw + 8, -1]):
      let r = place(tw, th)
      drawBitmap(r, brushThumbs.bmps[i])
      let on = vbrush.name == b.name
      box(r, if on: ui.theme.text else: ui.theme.frame)
      let hit = interact(idOf("vbrush" & $i), r, focusable = false)
      if listRow(b.name, on, "vbrushname" & $i, dp(150)) or hit.clicked:
        vbrush = b
        if size > 0: vbrushW = size
        if d != nil:
          let ts = d.vecTargets
          if ts.len > 0:
            d.beginStep("Apply Brush")
            d.touchLayers()
            for L in ts:
              var s = L.shape
              s.brush = b
              if s.stroke.kind == spNone: s.stroke = solidPaint(fg)
              if s.strokeWidth <= 0: s.strokeWidth = (if size > 0: size.float else: vbrushW.float)
              d.setShape(L, s)
            d.endStep()
            status = "Brush \"" & b.name & "\" on " & $ts.len & " shapes (the paths stay as they are)"
  row:
    if button("New Brush", w = dp(90), enabled = d != nil and d.current.isShape and d.current.shape.path.subs.len > 0):
      # (the shape picked: its outline the artwork of an Art brush)
      let L = d.current
      userBrushes.add StrokeBrush(kind: sbArt, name: L.name & " Brush", art: L.shape.path)
      brushThumbs.n = -1
      status = "New brush \"" & L.name & " Brush\": an Art brush of its outline"
    if button("Remove Brush", w = dp(110), enabled = d != nil and d.vecTargets.len > 0):
      d.beginStep("Remove Brush Stroke")
      d.touchLayers()
      for L in d.vecTargets:
        var s = L.shape
        s.brush = StrokeBrush()
        d.setShape(L, s)
      d.endStep()

# ---- the Appearance panel ---------------------------------------------------------------------------------

proc appearanceBody() =
  ## Window > Appearance: the picked shape's fills and strokes, each with its opacity and mode, its
  ## effects; more of them added, taken away, turned off, moved under or over its own.
  let d = cur()
  if d == nil or not d.current.isShape:
    label("Pick a shape layer", color = ui.theme.gray)
    return
  let L = d.current
  var s = L.shape
  var changed = false
  label(L.name, bold = true)
  # its effects
  if s.effects.len > 0:
    label("Effects", bold = true)
    var gone = -1
    for k in 0 ..< s.effects.len:
      row([22, -1, 60, 40]):
        var on = not s.effects[k].off
        pushId("apfx" & $k)
        if checkbox("", on):
          s.effects[k].off = not on
          changed = true
        label tr($s.effects[k].kind).replace("&", "&&")   # ("Pucker & Bloat": no mnemonic)
        if button("Edit", w = dp(56)): startLiveEffect(s.effects[k].kind, k)
        if button("x", w = dp(32)): gone = k
        popId()
    if gone >= 0:
      s.effects.delete(gone)
      changed = true
  template itemRow(label0: string; a: var Appearance; k: int) =
    row([22, 60, 40, -1, 40]):
      var on = not a.off
      pushId("ap" & $k)
      if checkbox("", on):
        a.off = not on
        changed = true
      label tr(label0)
      if colorWell(a.paint.color, "apc" & $k, dp(32)):
        a.paint.kind = spColor
        changed = true
      var op = a.opacity
      if spin(op, 0, 100, w = dp(56)):
        a.opacity = op
        changed = true
      if button(if a.below: "Under" else: "Over", w = dp(56)):
        a.below = not a.below
        changed = true
      popId()
  var gone = -1
  for k in 0 ..< s.appearance.len:
    var a = s.appearance[k]
    itemRow($a.kind, a, k)
    if a.kind == apStroke:
      row([82, -1]):
        label ""
        var wv = int(round(a.width))
        pushId("apw" & $k)
        if spin(wv, 0, 500, w = dp(60)):
          a.width = wv.float
          changed = true
        popId()
    row([82, -1, 40]):
      label ""
      var m = max(0, LayerModes.find(a.mode))
      pushId("apm" & $k)
      if combo(layerModeNames(), m, w = dp(110)):
        a.mode = LayerModes[m]
        changed = true
      if button("x", w = dp(32)): gone = k
      popId()
    s.appearance[k] = a
  if gone >= 0:
    s.appearance.delete(gone)
    changed = true
  # its own fill and stroke, as the panel shows them
  row([82, -1]):
    label "Stroke:"
    label(if s.stroke.kind == spNone: tr("None") else: $int(round(s.strokeWidth)) & " px" &
          (if s.brush.kind != sbNone: " " & s.brush.name else: ""))
  row([82, -1]):
    label "Fill:"
    label(if s.fill.kind == spNone: tr("None") else: tr($s.fill.kind))
  row:
    if button("Add Fill", w = dp(80)):
      s.appearance.add Appearance(kind: apFill, paint: solidPaint(fg), opacity: 100, below: true)
      changed = true
    if button("Add Stroke", w = dp(90)):
      s.appearance.add Appearance(kind: apStroke, paint: solidPaint(fg), width: max(2.0, s.strokeWidth * 2),
                                  align: saCenter, opacity: 100, below: true)
      changed = true
    if button("Clear", w = dp(60), enabled = s.appearance.len > 0 or s.effects.len > 0):
      s.appearance = @[]
      s.effects = @[]
      changed = true
  if changed:
    d.stepOnce("Appearance", proc () = d.setShape(L, s))

# ---- live effects: Layer > Live Effects ---------------------------------------------------------------------

var leDlg: tuple[open: bool; layer: Layer; idx: int; e: LiveEffect; s0: ShapeData; shown: string]
  ## (the box of a live effect: on which shape, which of its effects -- -1 a new one --, as set)
var lePending = false     ## (its step open: the box closed from outside takes it back, as Cancel)

proc startLiveEffect(k: LiveEffectKind; idx = -1) =
  ## A live effect's box: a new effect on the picked shape (`idx` -1), or one of its own changed.
  let d = cur()
  if d == nil or not d.current.isShape:
    status = tr($k) & ": pick a shape layer first (effects are done to its path, which stays as it is)"
    return
  let L = d.current
  var e = if idx >= 0 and idx < L.shape.effects.len: L.shape.effects[idx] else: defaultLiveEffect(k)
  if idx < 0 and k == leWarp: e.style = 0
  leDlg = (true, L, idx, e, L.shape, "")
  lePending = true
  d.beginStep(tr($k))
  d.touchLayers()

proc liveEffectCommand(name: string): bool =
  ## Layer > Live Effects: the effects by their names (Warp: "Warp: Arc"...).
  result = true
  if name.startsWith("Warp: "):
    let st = WarpStyles.find(name[6 .. ^1].strip(chars = {'.'}))
    if st >= 0:
      startLiveEffect(leWarp)
      if leDlg.open: leDlg.e.style = st
      return
  case name
  of "Free Distort...": startLiveEffect(leFreeDistort)
  of "Pucker & Bloat...": startLiveEffect(lePuckerBloat)
  of "Roughen...": startLiveEffect(leRoughen)
  of "Transform Effect...": startLiveEffect(leTransform)
  of "Tweak...": startLiveEffect(leTweak)
  of "Twist...": startLiveEffect(leTwist)
  of "Zig Zag...": startLiveEffect(leZigZag)
  of "Offset Path Effect...": startLiveEffect(leOffset)
  of "Radial Repeat...": startLiveEffect(leRepeatRadial)
  of "Grid Repeat...": startLiveEffect(leRepeatGrid)
  of "Mirror Repeat...": startLiveEffect(leRepeatMirror)
  of "Round Corners...": startLiveEffect(leRoundCorners)
  of "Scribble...": startLiveEffect(leScribble)
  of "Transform Each...": startTransformEach()
  of "Expand Appearance":
    let d = cur()
    if d == nil or not d.current.isShape: return
    let L = d.current
    # (what it draws made shapes of their own: effects done, brush outlined, fills and strokes apart)
    d.beginStep("Expand Appearance")
    d.touchLayers()
    let parts = expanded(L.shape)
    var made: seq[int]
    let at = d.layers.find(L)
    for k, (part, op, mode) in parts:
      let M = d.addShapeLayer(part, name = L.name & (if k > 0: " " & $(k + 1) else: ""), above = at + k)
      M.opacity = op
      M.mode = mode
      made.add d.layers.find(M)
    d.deleteLayer(d.layers.find(L))
    d.endStep()
    status = "Expanded: " & $parts.len & " shapes"
  of "Brushes (Vector)": togglePanel("vbrushes")
  of "Appearance": togglePanel("appearance")
  else: result = false

proc liveEffectDialog() =
  let d = cur()
  if not leDlg.open:
    if lePending:
      lePending = false
      if d != nil and d.stepOpen:
        d.cancelStep()
        d.markAll()
    return
  let L = leDlg.layer
  if d == nil or L == nil or L notin d.layers:
    leDlg.open = false
    return
  var ok, cancel = false
  var open = true
  var e = leDlg.e
  dialog(open, tr($e.kind), 420):
    template num(lab: string; v: var float; lo, hi: float; unit = "") =
      row([140, -1, 50]):
        label lab
        var iv = int(round(v))
        pushId(lab)
        if slider(iv, int(lo), int(hi), ticks = 0): v = iv.float
        popId()
        label($int(round(v)) & unit)
    case e.kind
    of lePuckerBloat:
      num("Pucker / Bloat:", e.amount, -200, 200, "%")
    of leRoughen:
      num("Size:", e.amount, 0, 100, "%")
      num("Detail (an inch):", e.detail, 0, 100)
      checkbox("Smooth", e.smooth)
      var sd = float(e.seed)
      num("Variation:", sd, 0, 100)
      e.seed = int(sd)
    of leTransform:
      num("Scale Horizontal:", e.sx, 0, 400, "%")
      num("Scale Vertical:", e.sy, 0, 400, "%")
      num("Move Horizontal:", e.dx, -500, 500, " px")
      num("Move Vertical:", e.dy, -500, 500, " px")
      num("Angle:", e.angle, -180, 180, "°")
      var c = float(e.copies)
      num("Copies:", c, 0, 50)
      e.copies = int(c)
    of leTweak:
      num("Horizontal:", e.sx, 0, 100, "%")
      num("Vertical:", e.sy, 0, 100, "%")
      var sd = float(e.seed)
      num("Variation:", sd, 0, 100)
      e.seed = int(sd)
    of leTwist: num("Angle:", e.amount, -720, 720, "°")
    of leZigZag:
      num("Size:", e.amount, 0, 100, " px")
      num("Ridges per Segment:", e.detail, 0, 100)
      checkbox("Smooth", e.smooth)
    of leFreeDistort:
      paragraph("Each corner of the shape's box moved by:", color = ui.theme.gray)
      for k, n in ["Top Left", "Top Right", "Bottom Right", "Bottom Left"]:
        var x = e.corners[k][0]
        var y = e.corners[k][1]
        num(n & " ←→:", x, -500, 500, " px")
        num(n & " ↑↓:", y, -500, 500, " px")
        e.corners[k] = (x, y)
    of leWarp:
      row([140, -1]):
        label "Style:"
        var names: seq[string]
        for n in WarpStyles: names.add tr(n)
        combo(names, e.style, w = dp(160))
      row:
        var v = ord(e.vertical)
        radio("Horizontal", v, 0)
        radio("Vertical", v, 1)
        e.vertical = v == 1
      num("Bend:", e.amount, -100, 100, "%")
      num("Horizontal Distortion:", e.sx, -100, 100, "%")
      num("Vertical Distortion:", e.sy, -100, 100, "%")
    of leOffset: num("Offset:", e.amount, -200, 200, " px")
    of leRepeatRadial:
      var c = float(e.copies)
      num("Instances:", c, 1, 100)
      e.copies = int(c)
      num("Radius:", e.amount, 0, 2000, " px")
      num("Start Angle:", e.angle, -180, 180, "°")
    of leRepeatGrid:
      var c = float(e.copies)
      num("Columns:", c, 1, 50)
      e.copies = int(c)
      num("Rows:", e.detail, 1, 50)
      num("Horizontal Spacing:", e.dx, -500, 500, " px")
      num("Vertical Spacing:", e.dy, -500, 500, " px")
    of leRepeatMirror:
      num("Axis Angle:", e.angle, -90, 90, "°")
      num("Axis Offset:", e.dx, -500, 500, " px")
    of leRoundCorners: num("Radius:", e.amount, 0, 1000, " px")
    of leScribble:
      num("Angle:", e.angle, -180, 180, "°")
      num("Stroke Width:", e.detail, 0.1, 100, " px")
      num("Spacing:", e.amount, 0.5, 200, " px")
      num("Variation:", e.sx, 0, 100, "%")
      var sd = float(e.seed)
      num("Seed:", sd, 1, 1000)
      e.seed = int(sd)
    of leEnvelope:
      paragraph("An envelope: Layer > Envelope Distort > Make with Mesh changes its grid; Release takes it " &
                "away.", color = ui.theme.gray)
    paragraph("The path stays as it was drawn: the effect is done each time it is drawn (the Appearance panel " &
              "keeps it, to change or take away).", color = ui.theme.gray)
    row:
      spring()
      if button("OK", isDefault = true, w = dp(80)): ok = true
      if button("Cancel", w = dp(80)): cancel = true
  leDlg.e = e
  let key = $e
  if key != leDlg.shown and not cancel and open:
    leDlg.shown = key
    var s = leDlg.s0
    if leDlg.idx >= 0 and leDlg.idx < s.effects.len: s.effects[leDlg.idx] = e
    else: s.effects.add e
    d.setShape(L, s)
  if ok:
    leDlg.open = false
    lePending = false
    if d.stepOpen: d.endStep()
  elif cancel or not open:
    leDlg.open = false
    lePending = false
    if d.stepOpen:
      d.cancelStep()
      d.markAll()

# ---- Transform Each ----------------------------------------------------------------------------------------

var teDlg: tuple[open: bool; sx, sy, dx, dy, angle: float; flipX, flipY, random: bool; seed: int;
                 shapes0: seq[(Layer, ShapeData)]; shown: string]
var tePending = false

proc startTransformEach() =
  ## Layer > Path Operations > Transform Each: each picked shape scaled, moved and turned about its
  ## own middle (Random: each by a part of it, as the drawing program's).
  let d = cur()
  if d == nil: return
  let ts = d.vecTargets
  if ts.len == 0:
    status = "Transform Each: pick shapes first (Shift+click, or the Magic Wand (Shapes))"
    return
  var shapes0: seq[(Layer, ShapeData)]
  for L in ts: shapes0.add (L, L.shape)
  teDlg = (true, 100.0, 100.0, 0.0, 0.0, 0.0, false, false, false, 1, shapes0, "")
  tePending = true
  d.beginStep("Transform Each")
  d.touchLayers()

proc transformEachDialog() =
  let d = cur()
  if not teDlg.open:
    if tePending:
      tePending = false
      if d != nil and d.stepOpen:
        d.cancelStep()
        d.markAll()
    return
  if d == nil:
    teDlg.open = false
    return
  var ok, cancel = false
  var open = true
  dialog(open, "Transform Each", 420):
    template num(lab: string; v: var float; lo, hi: float; unit = "") =
      row([140, -1, 56]):
        label lab
        var iv = int(round(v))
        pushId(lab)
        if slider(iv, int(lo), int(hi), ticks = 0): v = iv.float
        popId()
        label($int(round(v)) & unit)
    label("Scale", bold = true)
    num("Horizontal:", teDlg.sx, 0, 400, "%")
    num("Vertical:", teDlg.sy, 0, 400, "%")
    label("Move", bold = true)
    num("Horizontal:", teDlg.dx, -1000, 1000, " px")
    num("Vertical:", teDlg.dy, -1000, 1000, " px")
    label("Rotate", bold = true)
    num("Angle:", teDlg.angle, -180, 180, "°")
    row:
      checkbox("Reflect X", teDlg.flipX)
      checkbox("Reflect Y", teDlg.flipY)
      checkbox("Random", teDlg.random)
    row:
      spring()
      if button("OK", isDefault = true, w = dp(80)): ok = true
      if button("Cancel", w = dp(80)): cancel = true
  let key = $(teDlg.sx, teDlg.sy, teDlg.dx, teDlg.dy, teDlg.angle, teDlg.flipX, teDlg.flipY, teDlg.random)
  if key != teDlg.shown and not cancel and open:
    teDlg.shown = key
    for k, (L, s0) in teDlg.shapes0:
      if L notin d.layers: continue
      # (Random: each by a part of the amounts, the same part each time it is shown)
      let f = if teDlg.random: 0.5 + 0.5 * abs(sin(float(k * 7919 + teDlg.seed) * 12.9898)) else: 1.0
      let (x0, y0, x1, y1) = pathBounds(s0.path)
      let cx = (x0 + x1) / 2
      let cy = (y0 + y1) / 2
      let kx = (1 + (teDlg.sx / 100 - 1) * f) * (if teDlg.flipX: -1.0 else: 1.0)
      let ky = (1 + (teDlg.sy / 100 - 1) * f) * (if teDlg.flipY: -1.0 else: 1.0)
      let a = degToRad(teDlg.angle * f)
      let ca = cos(a)
      let sa = sin(a)
      let mx = teDlg.dx * f
      let my = teDlg.dy * f
      var s = s0
      s.path.mapPoints(proc (x, y: float): (float, float) =
        let u = (x - cx) * kx
        let v = (y - cy) * ky
        (cx + u * ca - v * sa + mx, cy + u * sa + v * ca + my))
      if teDlg.flipX != teDlg.flipY:
        # (a mirror image goes round the other way: put back, the fill keeps its holes)
        for sp in s.path.subs.mitems:
          sp.pts.reverse()
          for q in sp.pts.mitems: swap(q.inH, q.outH)
      d.setShape(L, s)
  if ok:
    teDlg.open = false
    tePending = false
    if d.stepOpen: d.endStep()
  elif cancel or not open:
    teDlg.open = false
    tePending = false
    if d.stepOpen:
      d.cancelStep()
      d.markAll()

# ---- the Eyedropper, taking a shape's look ----------------------------------------------------------------

proc appearancePick(dw: DocWin; ev: PhotoEvent): bool =
  ## The Eyedropper set to Appearance: a click on a shape gives its look -- fill, stroke and how it is
  ## drawn, brush, width profile, more fills and strokes, effects, layer style, opacity, mode -- to
  ## the picked shapes (or the current one), as the drawing program's eyedropper does.
  if tool != tEyedropper or dropKind != 0 or not eyeAppearance or not ev.pressed or ev.right: return false
  let d = dw.doc
  let src = d.vecShapeAt(ev.x, ev.y, dw.pickRadius)
  if src == nil:
    status = "Eyedropper (Appearance): click a shape to take its look"
    return true
  var ts: seq[Layer]
  for L in d.vecTargets:
    if L != src: ts.add L
  if ts.len == 0:
    status = "Eyedropper (Appearance): pick the shapes to give the look to first, then click the one to take it from"
    return true
  d.beginStep("Eyedropper")
  d.touchLayers()
  for L in ts:
    var s = L.shape
    let o = src.shape
    s.fill = o.fill
    s.stroke = o.stroke
    s.strokeWidth = o.strokeWidth
    s.align = o.align
    s.cap = o.cap
    s.join = o.join
    s.dashes = o.dashes
    s.brush = o.brush
    s.widths = o.widths
    s.appearance = o.appearance
    s.effects = o.effects
    d.setShape(L, s)
    L.fx = src.fx
    L.opacity = src.opacity
    L.mode = src.mode
  d.markAll()
  d.endStep()
  status = "The look of " & src.name & " given to " & $ts.len & (if ts.len == 1: " shape" else: " shapes")
  true
