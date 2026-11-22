## A perspective grid, as a drawing program has one: a horizon, one, two or
## three vanishing points (the third the walls' uprights meet at, above or
## below), and the planes they make -- a wall to the left, a wall to the
## right, the floor (and, with one point, the wall facing) -- with lines on
## them to draw by. Or an isometric grid (Affinity's isometric planes): no
## vanishing point, the walls going back at 30 degrees either way, a cube's
## sides as long as each other. A flat shape is put on a plane where it is:
## the corners of its box stay, the rest follows the plane -- smaller as it
## goes back.
##
## - `PerspectiveGrid`, `defaultGrid`: the grid, set in pixels of the image.
## - `planeQuad`: a plane's four corners (`VpPlane` of `retroui/photovp`
##   maps between it and a flat square).
## - `gridLines`: the lines to show (each plane's, the horizon).
## - `ontoPlane`, `pixelsOntoPlane`: a path, a painted layer, laid on a
##   plane where it is.
##
## .. code-block:: nim
##   import retroui/[photo, photoshapes, perspectivegrid]
##   let g = defaultGrid(d.w, d.h)
##   var s = d.current.shape
##   s.path = ontoPlane(s.path, g, ppLeft)
##   d.setShape(d.current, s)
##
## Developed by Sultan Al Isaiee @foxoman -- www.foxoman.net -- sultan@foxoman.net

import std/[math, json]
import gfx, photo, photoshapes, photovp, textengine

type
  PerspectiveKind* = enum
    ## How many vanishing points.
    pkOnePoint = "One-Point", pkTwoPoint = "Two-Point", pkThreePoint = "Three-Point",
    pkIsometric = "Isometric"   ## none: the planes' sides parallel, at 30 degrees

  PerspectivePlane* = enum
    ## The planes of a grid.
    ppLeft = "Left Wall", ppRight = "Right Wall", ppFloor = "Floor", ppFacing = "Facing Wall"

  PerspectiveGrid* = object
    ## A perspective grid, in the image's pixels.
    kind*: PerspectiveKind
    horizon*: float              ## the horizon's height (y)
    leftX*, rightX*: float       ## the vanishing points on it (one point: `leftX`)
    nearX*: float                ## two points: the nearest corner, where the walls meet (x); one
                                 ## point: the facing wall's left side
    nearW*: float                ## one point: the facing wall's width; isometric: how far the walls go
                                 ## back (their bottom edges' length, before `depth`)
    ground*, top*: float         ## the near corner's (the facing wall's) foot and top (y)
    depth*: float                ## how far the planes reach toward their points (0..1)
    vertY*: float                ## three points: where the walls' uprights meet (y, under the near
                                 ## corner: below the ground looking down, above the top looking up)
    cells*: int                  ## lines on a plane, each way
    shown*: bool                 ## shown over the picture (View > Perspective Grid > Show Grid)
    locked*: bool                ## its handles do not move it
    active*: PerspectivePlane    ## the plane drawn on (the Plane Switching Widget's)...
    noActive*: bool              ## ... or none: shapes drawn flat
    opacity*: int                ## how strongly its lines are shown, % (0: 50)

proc defaultGrid*(w, h: int): PerspectiveGrid =
  ## A two-point grid for an image `w` x `h`: the horizon a third of the way down, its points
  ## outside the sides, the walls' corner in the middle.
  PerspectiveGrid(kind: pkTwoPoint, horizon: h.float * 0.38, leftX: -w.float * 0.35, rightX: w.float * 1.35,
                  nearX: w.float * 0.5, nearW: w.float * 0.3, ground: h.float * 0.88, top: h.float * 0.12,
                  depth: 0.6, cells: 8, opacity: 50)

proc onePoint*(w, h: int): PerspectiveGrid =
  ## A one-point grid for an image `w` x `h`: the point in the middle of the horizon, a wall
  ## facing across the middle, the side walls and the floor going back to it.
  PerspectiveGrid(kind: pkOnePoint, horizon: h.float * 0.42, leftX: w.float * 0.5, rightX: w.float * 0.5,
                  nearX: w.float * 0.18, nearW: w.float * 0.64, ground: h.float * 0.92, top: h.float * 0.08,
                  depth: 0.55, cells: 8, opacity: 50)

proc threePoint*(w, h: int): PerspectiveGrid =
  ## A three-point grid for an image `w` x `h`: as `defaultGrid`, the walls' uprights meeting at a
  ## point far below (looking down on what is drawn).
  result = defaultGrid(w, h)
  result.kind = pkThreePoint
  result.vertY = h.float * 2.6

proc isometric*(w, h: int): PerspectiveGrid =
  ## An isometric grid for an image `w` x `h`: the near corner low in the middle, the walls going back
  ## up at 30 degrees to the left and the right, as high as they are deep (a cube's sides).
  PerspectiveGrid(kind: pkIsometric, horizon: h.float * 0.38, leftX: 0, rightX: w.float, nearX: w.float * 0.5,
                  nearW: min(w.float * 0.45, h.float * 0.55), ground: h.float * 0.9,
                  top: h.float * 0.9 - min(w.float * 0.45, h.float * 0.55) * 0.6, depth: 0.6, cells: 8,
                  opacity: 50)

proc gridToJson*(g: PerspectiveGrid): string =
  ## The grid as JSON (what a document keeps of it).
  $(%*{"kind": $g.kind, "horizon": g.horizon, "leftX": g.leftX, "rightX": g.rightX, "nearX": g.nearX,
       "nearW": g.nearW, "ground": g.ground, "top": g.top, "depth": g.depth, "vertY": g.vertY, "cells": g.cells,
       "shown": g.shown, "locked": g.locked, "active": $g.active, "noActive": g.noActive,
       "opacity": g.opacity})

proc gridFrom*(s: string; w, h: int): PerspectiveGrid =
  ## The grid `gridToJson` wrote; `defaultGrid(w, h)`, not shown, when there is none.
  result = defaultGrid(w, h)
  if s.len == 0: return
  try:
    let j = parseJson(s)
    result.kind = if j{"kind"}.getStr == $pkOnePoint: pkOnePoint
                  elif j{"kind"}.getStr == $pkThreePoint: pkThreePoint
                  elif j{"kind"}.getStr == $pkIsometric: pkIsometric
                  else: pkTwoPoint
    template f(name: string; field: untyped) =
      if j.hasKey(name): field = j[name].getFloat(field)
    f("horizon", result.horizon)
    f("leftX", result.leftX)
    f("rightX", result.rightX)
    f("nearX", result.nearX)
    f("nearW", result.nearW)
    f("ground", result.ground)
    f("top", result.top)
    f("depth", result.depth)
    f("vertY", result.vertY)
    if result.kind == pkThreePoint and abs(result.vertY - result.ground) < 1: result.vertY = h.float * 2.6
    result.cells = clamp(j{"cells"}.getInt(8), 1, 64)
    result.shown = j{"shown"}.getBool
    result.locked = j{"locked"}.getBool
    for pl in PerspectivePlane:
      if j{"active"}.getStr == $pl: result.active = pl
    result.noActive = j{"noActive"}.getBool
    result.opacity = clamp(j{"opacity"}.getInt(50), 0, 100)
  except CatchableError: discard

proc along(a, b: (float, float); t: float): (float, float) = (a[0] + (b[0] - a[0]) * t, a[1] + (b[1] - a[1]) * t)

proc crossing(a1, a2, b1, b2: (float, float)): (float, float) =
  ## (where line a1-a2 meets line b1-b2; a2 when they do not)
  let d = (a2[0] - a1[0]) * (b2[1] - b1[1]) - (a2[1] - a1[1]) * (b2[0] - b1[0])
  if abs(d) < 1e-9: return a2
  let t = ((b1[0] - a1[0]) * (b2[1] - b1[1]) - (b1[1] - a1[1]) * (b2[0] - b1[0])) / d
  (a1[0] + (a2[0] - a1[0]) * t, a1[1] + (a2[1] - a1[1]) * t)

proc planeQuad*(g: PerspectiveGrid; plane: PerspectivePlane): Quad =
  ## A plane's corners: top left, top right, bottom right, bottom left as it is seen (the near
  ## side first for the walls).
  let f = clamp(g.depth, 0.05, 0.98)
  case g.kind
  of pkIsometric:
    # (no point: each plane's sides parallel, going back at 30 degrees)
    let len = max(1.0, g.nearW) * f / 0.6
    let dl = (-len * cos(PI / 6), -len * sin(PI / 6))
    let dr = (len * cos(PI / 6), -len * sin(PI / 6))
    let nt = (g.nearX, g.top)
    let nb = (g.nearX, g.ground)
    proc add(a, b: (float, float)): (float, float) = (a[0] + b[0], a[1] + b[1])
    case plane
    of ppLeft, ppFacing: [add(nt, dl), nt, nb, add(nb, dl)]
    of ppRight: [nt, add(nt, dr), add(nb, dr), nb]
    of ppFloor: [add(add(nb, dl), dr), add(nb, dr), nb, add(nb, dl)]
  of pkThreePoint:
    # (as two points, but the walls' far sides go up to the third point: their uprights meet there)
    let vl = (g.leftX, g.horizon)
    let vr = (g.rightX, g.horizon)
    let v3 = (g.nearX, g.vertY)
    let nt = (g.nearX, g.top)
    let nb = (g.nearX, g.ground)
    case plane
    of ppLeft, ppFacing:
      let ft = along(nt, vl, f)
      [ft, nt, nb, crossing(nb, vl, ft, v3)]
    of ppRight:
      let ft = along(nt, vr, f)
      [nt, ft, crossing(nb, vr, ft, v3), nb]
    of ppFloor:
      let l = along(nb, vl, f)
      let r = along(nb, vr, f)
      let far = crossing(l, vr, r, vl)
      [far, r, nb, l]
  of pkTwoPoint:
    let vl = (g.leftX, g.horizon)
    let vr = (g.rightX, g.horizon)
    let nt = (g.nearX, g.top)
    let nb = (g.nearX, g.ground)
    case plane
    of ppLeft, ppFacing: [along(nt, vl, f), nt, nb, along(nb, vl, f)]
    of ppRight: [nt, along(nt, vr, f), along(nb, vr, f), nb]
    of ppFloor:
      let l = along(nb, vl, f)
      let r = along(nb, vr, f)
      let far = crossing(l, vr, r, vl)
      [far, r, nb, l]
  of pkOnePoint:
    let vp = (g.leftX, g.horizon)
    let tl = (g.nearX, g.top)
    let tr = (g.nearX + g.nearW, g.top)
    let br = (g.nearX + g.nearW, g.ground)
    let bl = (g.nearX, g.ground)
    # (the facing wall near; the walls and the floor going back toward the point)
    case plane
    of ppFacing: [tl, tr, br, bl]
    of ppLeft: [along(tl, vp, f), tl, bl, along(bl, vp, f)]
    of ppRight: [tr, along(tr, vp, f), along(br, vp, f), br]
    of ppFloor: [along(bl, vp, f), along(br, vp, f), br, bl]

proc planes*(g: PerspectiveGrid): seq[PerspectivePlane] =
  ## The planes the grid has.
  if g.kind == pkOnePoint: @[ppFacing, ppLeft, ppRight, ppFloor] else: @[ppLeft, ppRight, ppFloor]

proc gridLines*(g: PerspectiveGrid; w, h: int): seq[tuple[a, b: (float, float); plane: int]] =
  ## The lines to show: the horizon (plane -1; an isometric grid has none) and each plane's (its
  ## index in `planes`).
  if g.kind != pkIsometric: result.add ((-w.float, g.horizon), (2 * w.float, g.horizon), -1)
  for i, pl in g.planes:
    let p = vpPlane(g.planeQuad(pl))
    if not p.ok: continue
    for (a, b) in p.gridLines(max(1, g.cells)): result.add (a, b, i)

proc splitCurves(path: Path): Path =
  ## (a straight side stays straight in perspective; a curve is cut in four, so that its
  ## handles, moved as points, still follow it)
  result = path
  for s in result.subs.mitems:
    let n = s.pts.len
    if n < 2: continue
    var pts: seq[PathPoint]
    let last = if s.closed: n else: n - 1
    for i in 0 ..< last:
      let j = (i + 1) mod n
      var a = s.pts[i]
      var b = s.pts[j]
      if pts.len == 0: pts.add a
      if a.outH == a.p and b.inH == b.p:
        if j != 0 or not s.closed: pts.add b
        continue
      for k in 0 ..< 4:
        let t = 1.0 / float(4 - k)
        let p01 = along(a.p, a.outH, t)
        let p12 = along(a.outH, b.inH, t)
        let p23 = along(b.inH, b.p, t)
        let q0 = along(p01, p12, t)
        let q1 = along(p12, p23, t)
        let m = along(q0, q1, t)
        pts[^1].outH = p01
        if k < 3:
          pts.add PathPoint(p: m, inH: q0, outH: q1)
          a = PathPoint(p: m, inH: q0, outH: q1)
          b.inH = p23
        elif j != 0 or not s.closed:
          pts.add PathPoint(p: b.p, inH: q0, outH: b.outH)
        else:
          pts[0].inH = q0
    s.pts = pts

proc planeSpan(p: VpPlane; x0, y0, x1, y1: float): tuple[ok: bool; u0, v0, u1, v1: float] =
  ## (where the box's top left and bottom right are on the plane; not ok across its horizon)
  for (x, y) in [(x0, y0), (x1, y0), (x1, y1), (x0, y1)]:
    if not p.onFront(x, y): return (false, 0.0, 0.0, 0.0, 0.0)
  let (u0, v0) = p.toPlane(x0, y0)
  let (u1, v1) = p.toPlane(x1, y1)
  for c in [u0, v0, u1, v1]:
    if c != c or abs(c) > 50: return (false, 0.0, 0.0, 0.0, 0.0)
  if abs(u1 - u0) < 1e-9 or abs(v1 - v0) < 1e-9: return (false, 0.0, 0.0, 0.0, 0.0)
  (true, u0, v0, u1, v1)

proc ontoPlane*(path: Path; g: PerspectiveGrid; plane: PerspectivePlane): Path =
  ## `path` laid on `plane` where it is, as a drawing program puts a shape on its grid: the
  ## corners of its box (top left, bottom right) stay, the rest follows the plane -- the far
  ## side smaller, its sides toward the vanishing point. Unchanged when the plane cannot hold
  ## it there (it reaches over the plane's horizon).
  if path.subs.len == 0: return path
  let p = vpPlane(g.planeQuad(plane))
  if not p.ok: return path
  let (bx0, by0, bx1, by1) = pathBounds(path)
  if bx1 - bx0 < 1e-6 and by1 - by0 < 1e-6: return path
  let x1 = max(bx1, bx0 + 1e-3)
  let y1 = max(by1, by0 + 1e-3)
  let sp = planeSpan(p, bx0, by0, x1, y1)
  if not sp.ok: return path
  let bw = x1 - bx0
  let bh = y1 - by0
  result = splitCurves(path)
  result.mapPoints(proc (x, y: float): (float, float) =
    p.toImage(sp.u0 + (x - bx0) / bw * (sp.u1 - sp.u0), sp.v0 + (y - by0) / bh * (sp.v1 - sp.v0)))

proc textOntoPlane*(d: Doc; L: Layer; g: PerspectiveGrid; plane: PerspectivePlane): bool =
  ## A type layer laid on `plane` where it is, as the drawing program puts type on its grid: the
  ## corners of its box (a box's, or where its letters are) stay, the rest follows the plane --
  ## and it stays type: set flat and drawn through the plane (`TextData.persp`), editable. False
  ## when the plane cannot hold it there. Undoable in a step.
  if not L.isText: return false
  var t = L.text
  var box: array[4, float32]
  if t.boxW > 0 and t.boxH > 0:
    box = [t.x, t.y, t.x + t.boxW, t.y + t.boxH]
  else:
    let lay = layoutText(d.effectiveText(L))
    if lay.x1 <= lay.x0 or lay.y1 <= lay.y0: return false
    box = [lay.x0 - 2, lay.y0 - 2, lay.x1 + 2, lay.y1 + 2]
  if t.perspOn:
    # (on a plane already: from where it was, flat)
    box = t.perspBox
  let flatPath = rectPath(box[0].float, box[1].float, box[2].float, box[3].float)
  let on = flatPath.ontoPlane(g, plane)
  if on == flatPath or on.subs.len == 0 or on.subs[0].pts.len < 4: return false
  # (the box's corners, as rectPath has them: top left, top right, bottom right, bottom left)
  var corners: array[4, (float32, float32)]
  let pts = on.subs[0].pts
  for i in 0 .. 3:
    corners[i] = (float32(pts[i].p[0]), float32(pts[i].p[1]))
  t.perspOn = true
  t.persp = corners
  t.perspBox = box
  d.touchLayers()
  d.touch(L, d.bounds)
  d.setText(L, t)
  true

proc textOffPlane*(d: Doc; L: Layer): bool =
  ## Release with Perspective: a type layer on a plane set flat again where it was. Undoable in a
  ## step.
  if not L.isText or not L.text.perspOn: return false
  var t = L.text
  t.perspOn = false
  d.touchLayers()
  d.touch(L, d.bounds)
  d.setText(L, t)
  true

proc pixelsOntoPlane*(d: Doc; L: Layer; g: PerspectiveGrid; plane: PerspectivePlane): bool =
  ## A painted layer's pixels laid on `plane` where they are, as `ontoPlane` lays a path:
  ## the corners of what is on it stay, the rest follows the plane (each pixel read through the
  ## perspective). False when there is nothing on it or the plane cannot hold it there.
  ## Undoable in a step.
  if L.px.len != d.w * d.h: return false
  let r = d.contentBounds(L)
  if r.w <= 0 or r.h <= 0: return false
  let p = vpPlane(g.planeQuad(plane))
  if not p.ok: return false
  let sp = planeSpan(p, r.x.float, r.y.float, float(r.x + r.w), float(r.y + r.h))
  if not sp.ok: return false
  var x0, y0 = 1e18
  var x1, y1 = -1e18
  for (u, v) in [(sp.u0, sp.v0), (sp.u1, sp.v0), (sp.u1, sp.v1), (sp.u0, sp.v1)]:
    let (x, y) = p.toImage(u, v)
    x0 = min(x0, x); y0 = min(y0, y); x1 = max(x1, x); y1 = max(y1, y)
  let t = d.clip(rect(int(x0) - 1, int(y0) - 1, int(x1 - x0) + 3, int(y1 - y0) + 3))
  # (what was there, kept to read from; the layer cleared where it was and where it goes)
  var src = newSeq[uint32](r.w * r.h)
  for y in 0 ..< r.h:
    for x in 0 ..< r.w: src[y * r.w + x] = L.px[(r.y + y) * d.w + r.x + x]
  let all = union(r, t)
  d.touch(L, all)
  for y in r.y ..< r.y + r.h:
    zeroMem(addr L.px[y * d.w + r.x], r.w * 4)
  for y in t.y ..< t.y + t.h:
    for x in t.x ..< t.x + t.w:
      let (u, v) = p.toPlane(x.float + 0.5, y.float + 0.5)
      let fx = (u - sp.u0) / (sp.u1 - sp.u0) * r.w.float - 0.5
      let fy = (v - sp.v0) / (sp.v1 - sp.v0) * r.h.float - 0.5
      if fx < -0.5 or fy < -0.5 or fx > r.w.float - 0.5 or fy > r.h.float - 0.5: continue
      # (bilinear, the colors weighed by their alpha)
      let ix = int(floor(fx))
      let iy = int(floor(fy))
      let ax = fx - ix.float
      let ay = fy - iy.float
      var acc = [0.0, 0.0, 0.0, 0.0]
      for (dx, dy, wt) in [(0, 0, (1 - ax) * (1 - ay)), (1, 0, ax * (1 - ay)), (0, 1, (1 - ax) * ay),
                           (1, 1, ax * ay)]:
        let sx = ix + dx
        let sy = iy + dy
        if wt <= 0 or sx < 0 or sy < 0 or sx >= r.w or sy >= r.h: continue
        let c = src[sy * r.w + sx]
        let a = float(c shr 24) * wt
        acc[0] += a
        acc[1] += float((c shr 16) and 255) * a
        acc[2] += float((c shr 8) and 255) * a
        acc[3] += float(c and 255) * a
      if acc[0] < 0.5: continue
      L.px[y * d.w + x] = (uint32(min(255.0, acc[0] + 0.5)) shl 24) or
                          (uint32(min(255.0, acc[1] / acc[0] + 0.5)) shl 16) or
                          (uint32(min(255.0, acc[2] / acc[0] + 0.5)) shl 8) or
                          uint32(min(255.0, acc[3] / acc[0] + 0.5))
  inc L.ver
  d.markDirty(all)
  true
