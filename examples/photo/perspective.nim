# (included by photo.nim) View > Perspective Grid (retroui/perspectivegrid), as a drawing
# program has it: one or two vanishing points, the planes drawn over the image in their colors
# (the left wall blue, the right orange, the floor green), the Plane Switching Widget at the
# view's corner -- the plane clicked there is the one drawn on -- and handles to move the
# points, the horizon, the grid's corner and its depth (the Move and the Shape tools; Lock Grid
# keeps it still). With a plane active, what the Shape tools draw lies on it (the two corners
# dragged where they were dragged); Layer > Perspective > Attach to Active Plane lays a shape
# or what is painted on a layer on it, where it is. The grid is kept with the document.

var
  pgCache: tuple[d: Doc; s: string; g: PerspectiveGrid]
  pgDrag: tuple[on: bool; dw: DocWin; handle: int; x0, y0: float; g0: PerspectiveGrid]
  pgDlg: tuple[open, live: bool; orig: string; kind, horizon, leftX, rightX, nearX, nearW, top, ground,
               depth, cells, opacity: int]

const
  pgColors = [ppLeft: (40, 90, 230), ppRight: (230, 110, 30), ppFloor: (40, 160, 70),
              ppFacing: (150, 70, 200)]

proc pgOf(d: Doc): PerspectiveGrid =
  ## (the document's grid; read again only when it changed)
  if pgCache.d != d or pgCache.s != d.perspective:
    pgCache = (d, d.perspective, gridFrom(d.perspective, d.w, d.h))
  pgCache.g

proc pgSet(d: Doc; g: PerspectiveGrid) =
  let s = gridToJson(g)
  if s == d.perspective: return
  d.perspective = s
  d.modified = true
  inc d.ver

proc pgActive(d: Doc): bool =
  ## (shapes are drawn on a plane: the grid shown, a plane active)
  if d == nil: return false
  let g = d.pgOf
  g.shown and not g.noActive and g.active in g.planes

proc pgShape(d: Doc; p: Path): Path =
  ## A shape the Shape tools draw: on the active plane, when there is one.
  if not d.pgActive: return p
  let g = d.pgOf
  p.ontoPlane(g, g.active)

proc pgColor(pl: PerspectivePlane; strong: bool; opacity: int): Color =
  let (r, g, b) = pgColors[pl]
  # (the plane not drawn on: paler, as the opacity says)
  let k = (if strong: 1.0 else: 0.55) * clamp(opacity, 10, 100).float / 100 + (if strong: 0.0 else: 0.15)
  let m = clamp(k, 0.2, 1.0)
  color(uint8(255 - (255 - r).float * m), uint8(255 - (255 - g).float * m), uint8(255 - (255 - b).float * m))

proc clipSeg(a, b: (float, float); r: Rect): (bool, (float, float), (float, float)) =
  ## (the part of the line from `a` to `b` inside `r`: Liang-Barsky)
  var t0 = 0.0
  var t1 = 1.0
  let dx = b[0] - a[0]
  let dy = b[1] - a[1]
  for (p, q) in [(-dx, a[0] - r.x.float), (dx, float(r.x + r.w) - a[0]), (-dy, a[1] - r.y.float),
                 (dy, float(r.y + r.h) - a[1])]:
    if abs(p) < 1e-12:
      if q < 0: return (false, a, b)
    else:
      let t = q / p
      if p < 0:
        if t > t1: return (false, a, b)
        t0 = max(t0, t)
      else:
        if t < t0: return (false, a, b)
        t1 = min(t1, t)
  (true, (a[0] + dx * t0, a[1] + dy * t0), (a[0] + dx * t1, a[1] + dy * t1))

proc pgLine(dw: DocWin; a, b: (float, float); c: Color) =
  let d = dw.doc
  let sa = dw.view.toScreenF(d, a[0], a[1])
  let sb = dw.view.toScreenF(d, b[0], b[1])
  let (ok, p, q) = clipSeg(sa, sb, dw.view.view)
  if ok: line(int(p[0]), int(p[1]), int(q[0]), int(q[1]), c)

proc pgHandles(g: PerspectiveGrid): seq[tuple[id: int; p: (float, float); tip: string]] =
  ## (the grid's handles, in the image's pixels: what each moves)
  result.add (0, (g.leftX, g.horizon), "The vanishing point: drag along the horizon")
  if g.kind == pkTwoPoint: result.add (1, (g.rightX, g.horizon), "The right vanishing point: drag along the horizon")
  let mid = if g.kind == pkTwoPoint: g.nearX else: g.nearX + g.nearW / 2
  result.add (2, (mid, g.horizon), "The horizon: drag it up or down")
  result.add (3, (g.nearX, g.ground), "The ground: drag to move the whole grid")
  result.add (4, (g.nearX, g.top), "The grid's height: drag up or down")
  let fl = g.planeQuad(ppFloor)
  result.add (5, (if g.kind == pkTwoPoint: fl[3] else: fl[0]), "How far the planes reach: drag toward the point")
  if g.kind == pkOnePoint: result.add (6, (g.nearX + g.nearW, g.ground), "The facing wall's width: drag sideways")

proc pgWidget(dw: DocWin): seq[tuple[r: Rect; plane: int; label: string]] =
  ## (the Plane Switching Widget: a button a plane, and No Active Grid)
  let d = dw.doc
  let g = d.pgOf
  let v = dw.view.view
  var x = v.x + dp(8)
  let y = v.y + dp(8)
  let bw = dp(44)
  let bh = dp(20)
  for pl in g.planes:
    let lab = case pl
              of ppLeft: "Left"
              of ppRight: "Right"
              of ppFloor: "Floor"
              of ppFacing: "Front"
    result.add (rect(x, y, bw, bh), ord(pl), lab)
    x += bw + 1
  result.add (rect(x, y, bw, bh), -1, "None")

proc pgOverlay(dw: DocWin; ev: PhotoEvent) =
  ## The grid over the image, its handles, the widget.
  let d = dw.doc
  let g = d.pgOf
  if not g.shown: return
  let strong = proc (pl: PerspectivePlane): bool = not g.noActive and g.active == pl
  # (the inactive planes first, the one drawn on over them)
  let lines = g.gridLines(d.w, d.h)
  let pls = g.planes
  for pass in 0 .. 1:
    for ln in lines:
      if ln.plane < 0:
        if pass == 0: dw.pgLine(ln.a, ln.b, color(70, 120, 200))
        continue
      let pl = pls[ln.plane]
      if strong(pl) != (pass == 1): continue
      dw.pgLine(ln.a, ln.b, pgColor(pl, strong(pl), g.opacity))
  if not g.locked and tool in {tMove, tShape}:
    let hs = dp(4)
    for h in g.pgHandles:
      let (sx, sy) = dw.view.toScreen(d, h.p[0], h.p[1])
      let r = rect(sx - hs, sy - hs, hs * 2 + 1, hs * 2 + 1)
      fill(r, color(255, 255, 255))
      box(r, if pgDrag.on and pgDrag.handle == h.id: color(230, 40, 40) else: color(40, 40, 40))
      if ev.over and mouseIn(r): ui.tip = h.tip
  # the Plane Switching Widget
  let st = style(size = 0.8)
  for b in dw.pgWidget:
    let on = (b.plane < 0 and g.noActive) or (b.plane >= 0 and not g.noActive and ord(g.active) == b.plane)
    let c = if b.plane >= 0: pgColor(PerspectivePlane(b.plane), true, 100) else: color(120, 120, 120)
    fill(b.r, if on: c else: color(250, 250, 250))
    box(b.r, c)
    let lab = tr(b.label)
    let tw = textWidth(lab, st)
    text(b.r.x + (b.r.w - tw) div 2, b.r.y + (b.r.h - lineHeight(st)) div 2, lab,
         if on: color(255, 255, 255) else: c, st)
    if ev.over and mouseIn(b.r):
      ui.tip = if b.plane < 0: "No active plane: shapes are drawn flat"
               else: tr("Draw on the ") & tr($PerspectivePlane(b.plane)) & tr(" (the Shape tools lay what they draw on it)")

proc canvasExtras(dw: DocWin; ev: PhotoEvent): bool =
  ## What a press on the image takes before the tools: a text frame's ports and the loaded text
  ## (textframes), the perspective grid's widget and handles. True when it took it.
  if dw.threadPress(ev): return true
  let d = dw.doc
  let g = d.pgOf
  if pgDrag.on and pgDrag.dw == dw:
    if ev.down or ev.released:
      var n = pgDrag.g0
      let dx = ev.x - pgDrag.x0
      let dy = ev.y - pgDrag.y0
      case pgDrag.handle
      of 0: n.leftX = pgDrag.g0.leftX + dx
      of 1: n.rightX = pgDrag.g0.rightX + dx
      of 2: n.horizon = min(pgDrag.g0.horizon + dy, n.ground - 4)
      of 3:
        # (the whole grid moved)
        n.leftX += dx; n.rightX += dx; n.nearX += dx
        n.horizon += dy; n.ground += dy; n.top += dy
      of 4: n.top = min(pgDrag.g0.top + dy, n.ground - 4)
      of 5:
        # (how far along the line from the near corner to its point the mouse is)
        let a = (n.nearX, n.ground)
        let b = (n.leftX, n.horizon)
        let lx = b[0] - a[0]
        let ly = b[1] - a[1]
        let l2 = max(1e-9, lx * lx + ly * ly)
        n.depth = clamp(((ev.x - a[0]) * lx + (ev.y - a[1]) * ly) / l2, 0.05, 0.98)
      of 6: n.nearW = max(4.0, pgDrag.g0.nearW + dx)
      else: discard
      d.pgSet(n)
    if ev.released or not ui.mouseDown: pgDrag.on = false
    return true
  if not g.shown or not ev.pressed or ev.right: return false
  for b in dw.pgWidget:
    if mouseIn(b.r):
      var n = g
      if b.plane < 0: n.noActive = true
      else:
        n.noActive = false
        n.active = PerspectivePlane(b.plane)
      d.pgSet(n)
      status = if n.noActive: "No active plane: the Shape tools draw flat"
               else: tr("Active plane: ") & tr($n.active) & tr(" -- the Shape tools draw on it")
      return true
  if g.locked or tool notin {tMove, tShape}: return false
  let near = dp(6)
  for h in g.pgHandles:
    let (sx, sy) = dw.view.toScreen(d, h.p[0], h.p[1])
    if abs(ui.mx - sx) <= near and abs(ui.my - sy) <= near:
      pgDrag = (true, dw, h.id, ev.x, ev.y, g)
      status = h.tip
      return true
  false

proc attachToPlane() =
  ## Layer > Perspective > Attach to Active Plane.
  let d = cur()
  if d == nil: return
  let g = d.pgOf
  if not g.shown or g.noActive:
    status = "Attach to Active Plane: show the grid (View > Perspective Grid) and pick a plane in its widget first."
    return
  let L = d.current
  if L.background or L.group or L.locked:
    status = "Attach to Active Plane: pick a shape, or a layer with something painted on it."
    return
  if L.isText:
    status = "Attach to Active Plane: type is laid on a plane as a shape -- Type > Convert to Shape first."
    return
  if L.isShape:
    let p = L.shape.path.ontoPlane(g, g.active)
    if p == L.shape.path:
      status = tr("Attach to Active Plane: move it onto the ") & tr($g.active) & tr(" first (it reaches over its horizon).")
      return
    var s = L.shape
    s.path = p
    s.kind = ""
    d.beginStep("Attach to Active Plane")
    d.touchLayers()
    d.setShape(L, s)
    d.endStep()
  elif L.isSmart or L.adjust.kind.len > 0 or L.isFill:
    status = "Attach to Active Plane: rasterize the layer first (Layer > Rasterize)."
    return
  else:
    d.beginStep("Attach to Active Plane")
    if not d.pixelsOntoPlane(L, g, g.active):
      d.cancelStep()
      status = tr("Attach to Active Plane: nothing on the layer, or it reaches over the plane's horizon -- move it onto the ") &
               tr($g.active) & tr(" first.")
      return
    d.endStep()
  status = "\"" & L.name & tr("\" lies on the ") & tr($g.active)

proc startDefineGrid() =
  let d = cur()
  if d == nil: return
  let g = d.pgOf
  pgDlg = (true, true, d.perspective, ord(g.kind), int(g.horizon), int(g.leftX), int(g.rightX), int(g.nearX),
           int(g.nearW), int(g.top), int(g.ground), int(g.depth * 100), g.cells, g.opacity)

proc perspectiveCommand(name: string): bool =
  result = true
  let d = cur()
  case name
  of "Show Perspective Grid", "Hide Perspective Grid":
    if d != nil:
      var g = d.pgOf
      g.shown = not g.shown
      d.pgSet(g)
      status = if g.shown: tr("Perspective grid: pick the plane to draw on in its widget (top left); drag its handles ") &
                           tr("with the Move or a Shape tool")
               else: "Perspective grid hidden"
  of "Lock Perspective Grid":
    if d != nil:
      var g = d.pgOf
      g.locked = not g.locked
      d.pgSet(g)
  of "One Point Perspective", "Two Point Perspective":
    if d != nil:
      let was = d.pgOf
      var g = if name.startsWith("One"): onePoint(d.w, d.h) else: defaultGrid(d.w, d.h)
      g.shown = true
      g.locked = was.locked
      g.opacity = was.opacity
      if g.active notin g.planes: g.active = ppLeft
      d.pgSet(g)
  of "Define Perspective Grid...":
    startDefineGrid()
  of "Attach to Active Plane":
    attachToPlane()
  of "Perspective Plane: Left Wall", "Perspective Plane: Right Wall", "Perspective Plane: Floor",
     "Perspective Plane: Facing Wall", "Perspective Plane: None":
    if d != nil:
      var g = d.pgOf
      let what = name.split(": ")[1]
      g.noActive = what == "None"
      for pl in PerspectivePlane:
        if $pl == what: g.active = pl
      d.pgSet(g)
  else: result = false

proc perspectiveDialog() =
  let d = cur()
  if not pgDlg.open or d == nil:
    if pgDlg.live and d != nil:
      # (closed from outside: as Cancel)
      d.perspective = pgDlg.orig
      inc d.ver
    pgDlg.open = false
    pgDlg.live = false
    return
  var ok, cancel = false
  dialog(pgDlg.open, "Define Perspective Grid", 420):
    row([150, -1]):
      label "Type:"
      combo(["One-Point Perspective", "Two-Point Perspective"], pgDlg.kind, w = dp(200))
    template num(lab: string; v: untyped; lo, hi: int; unit = "px") =
      row([150, 110, -1]):
        label lab
        spin(v, lo, hi, w = dp(100))
        label unit
    let big = 4 * max(d.w, d.h)
    num("Horizon height:", pgDlg.horizon, -big, big)
    if pgDlg.kind == 1:
      num("Left vanishing point:", pgDlg.leftX, -big, big)
      num("Right vanishing point:", pgDlg.rightX, -big, big)
      num("Corner (x):", pgDlg.nearX, -big, big)
    else:
      num("Vanishing point:", pgDlg.leftX, -big, big)
      num("Facing wall (x):", pgDlg.nearX, -big, big)
      num("... its width:", pgDlg.nearW, 4, big)
    num("Top:", pgDlg.top, -big, big)
    num("Ground level:", pgDlg.ground, -big, big)
    num("Depth:", pgDlg.depth, 5, 98, "%")
    num("Gridlines:", pgDlg.cells, 1, 64, "each way")
    num("Opacity:", pgDlg.opacity, 10, 100, "%")
    row:
      spring()
      if button("OK", isDefault = true, w = dp(80)): ok = true
      if button("Cancel", w = dp(80)): cancel = true
  # (live: the grid as the box says, while it is open)
  var g = d.pgOf
  g.kind = if pgDlg.kind == 0: pkOnePoint else: pkTwoPoint
  g.horizon = pgDlg.horizon.float
  g.leftX = pgDlg.leftX.float
  g.rightX = pgDlg.rightX.float
  g.nearX = pgDlg.nearX.float
  g.nearW = pgDlg.nearW.float
  g.top = min(pgDlg.top, pgDlg.ground - 4).float
  g.ground = pgDlg.ground.float
  g.depth = pgDlg.depth / 100
  g.cells = pgDlg.cells
  g.opacity = pgDlg.opacity
  g.shown = true
  if g.active notin g.planes: g.active = ppLeft
  if ok:
    d.pgSet(g)
    pgDlg.open = false
    pgDlg.live = false
  elif cancel or not pgDlg.open:
    pgDlg.open = false
    pgDlg.live = false
    d.perspective = pgDlg.orig
    inc d.ver
  else: d.pgSet(g)
