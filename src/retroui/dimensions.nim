## Dimensions: labels that measure -- a distance between two points, an angle between two
## lines, a circle's radius -- drawn as a drawing program draws them (a line with arrowheads
## and extension lines, an arc, a radius line) with their value in the rulers' unit, and kept
## true: each point may be fixed to a place on a layer (a corner, a side's middle, the centre),
## and when that layer moves or changes size the dimension is drawn again (`updateDimensions`).
##
## A dimension is a shape layer (its lines) whose `meta` keeps what it measures, and a type
## layer over it (its label).
##
## ```nim
## let L = d.addDimension(Dimension(kind: dkDistance, a: d.anchorAt(10, 10), b: d.anchorAt(200, 10)), ruMillimeters)
## d.updateDimensions(ruMillimeters)        # after layers moved
## ```
##
## Developed by Sultan Al Isaiee @foxoman -- www.foxoman.net -- sultan@foxoman.net

import std/[json, math, strutils]
import gfx, photo, photoshapes, textengine, photowidgets

type
  DimKind* = enum
    ## What a dimension measures.
    dkDistance = "Distance", dkAngle = "Angle", dkRadius = "Radius"

  DimAnchor* = object
    ## A point a dimension measures from: on layer `uid` (0: none, the point `fx`, `fy` itself),
    ## at `fx`, `fy` of the way across and down its box -- 0, 0.5, 1 its corners, sides' middles
    ## and centre.
    uid*: int
    fx*, fy*: float

  Dimension* = object
    ## What a dimension measures and how it is drawn.
    kind*: DimKind
    a*, b*, c*: DimAnchor       ## distance: from `a` to `b`; angle: at `a`, between the lines to `b`
                                ## and `c`; radius: the circle's layer in `a` (its centre)
    offset*: float              ## distance: the line drawn this far beside the points (pixels, to the left
                                ## of a to b); angle: the arc's radius; radius: the line's angle (degrees)
    color*: uint32
    label*: int                 ## its label's layer (`uid`)

const MetaKey = "dimension:"

proc anchorPoint*(d: Doc; a: DimAnchor): (float, float) =
  ## Where an anchor is now (its layer gone: the point it was at, kept in `fx`, `fy` when made).
  if a.uid != 0:
    let L = d.layerOfUid(a.uid)
    if L != nil:
      let b = d.objectBox(L)
      if b.ok: return (b.x0 + a.fx * (b.x1 - b.x0), b.y0 + a.fy * (b.y1 - b.y0))
      let r = d.contentBounds(L)
      if r.w > 0: return (r.x.float + a.fx * r.w.float, r.y.float + a.fy * r.h.float)
  (a.fx, a.fy)

proc anchorAt*(d: Doc; x, y: float; reach = 8.0; skip: seq[Layer] = @[]): DimAnchor =
  ## An anchor for the point `x`, `y`: fixed to the corner, side's middle or centre of a layer
  ## within `reach` pixels of it (the nearest), else the point itself.
  var best = reach
  result = DimAnchor(fx: x, fy: y)
  for L in d.layers:
    if L in skip or L.meta.startsWith(MetaKey): continue
    let b = d.objectBox(L)
    if not b.ok: continue
    for fx in [0.0, 0.5, 1.0]:
      for fy in [0.0, 0.5, 1.0]:
        let px = b.x0 + fx * (b.x1 - b.x0)
        let py = b.y0 + fy * (b.y1 - b.y0)
        let dd = hypot(px - x, py - y)
        if dd <= best:
          best = dd
          result = DimAnchor(uid: L.uidOf, fx: fx, fy: fy)

proc toJson(a: DimAnchor): JsonNode = %*{"uid": a.uid, "fx": a.fx, "fy": a.fy}
proc anchorFrom(j: JsonNode): DimAnchor =
  if j == nil or j.kind != JObject: return
  DimAnchor(uid: j{"uid"}.getInt, fx: j{"fx"}.getFloat, fy: j{"fy"}.getFloat)

proc dimensionOf*(L: Layer): tuple[ok: bool; dim: Dimension] =
  ## The dimension a layer draws (not `ok`: it is no dimension).
  if L == nil or not L.meta.startsWith(MetaKey): return
  try:
    let j = parseJson(L.meta[MetaKey.len .. ^1])
    result = (true, Dimension(kind: DimKind(clamp(j{"kind"}.getInt, 0, ord(high(DimKind)))), a: anchorFrom(j{"a"}),
                              b: anchorFrom(j{"b"}), c: anchorFrom(j{"c"}), offset: j{"offset"}.getFloat,
                              color: uint32(j{"color"}.getBiggestInt(0xFF000000'i64)), label: j{"label"}.getInt))
  except CatchableError: discard

proc metaOf(dm: Dimension): string =
  MetaKey & $(%*{"kind": ord(dm.kind), "a": dm.a.toJson, "b": dm.b.toJson, "c": dm.c.toJson, "offset": dm.offset,
                 "color": int64(dm.color), "label": dm.label})

proc arrow(tip, back: (float, float); size: float): SubPath =
  ## (a filled arrowhead at `tip`, pointing away from `back`)
  let dx = tip[0] - back[0]
  let dy = tip[1] - back[1]
  let l = max(1e-9, hypot(dx, dy))
  let (ux, uy) = (dx / l, dy / l)
  let bx = tip[0] - ux * size
  let by = tip[1] - uy * size
  let w = size * 0.35
  result = SubPath(closed: true)
  for p in [tip, (bx - uy * w, by + ux * w), (bx + uy * w, by - ux * w)]:
    result.pts.add PathPoint(p: p, inH: p, outH: p)

proc line(a, b: (float, float)): SubPath =
  result = SubPath()
  for p in [a, b]: result.pts.add PathPoint(p: p, inH: p, outH: p)

proc geometry*(d: Doc; dm: Dimension; unit: RulerUnit): tuple[path: Path; text: string; at: (float, float)] =
  ## A dimension's lines, its label's text in `unit`, and where the label's middle goes.
  let size = max(6.0, d.w.float / 160)
  case dm.kind
  of dkDistance:
    let a = d.anchorPoint(dm.a)
    let b = d.anchorPoint(dm.b)
    let dx = b[0] - a[0]
    let dy = b[1] - a[1]
    let l = hypot(dx, dy)
    let (nx, ny) = if l > 1e-9: (dy / l, -dx / l) else: (0.0, -1.0)
    let o = dm.offset
    let a2 = (a[0] + nx * o, a[1] + ny * o)
    let b2 = (b[0] + nx * o, b[1] + ny * o)
    let ext = if o >= 0: size else: -size
    let gap = if o >= 0: min(3.0, o / 2) else: max(-3.0, o / 2)
    result.path.subs.add line((a[0] + nx * gap, a[1] + ny * gap), (a2[0] + nx * ext, a2[1] + ny * ext))
    result.path.subs.add line((b[0] + nx * gap, b[1] + ny * gap), (b2[0] + nx * ext, b2[1] + ny * ext))
    result.path.subs.add line(a2, b2)
    if l > size * 2.5:
      result.path.subs.add arrow(a2, b2, size)
      result.path.subs.add arrow(b2, a2, size)
    result.text = inUnits(l, unit, d.dpi, d.w)
    let side = if o >= 0: 1.0 else: -1.0
    result.at = ((a2[0] + b2[0]) / 2 + nx * size * 1.6 * side, (a2[1] + b2[1]) / 2 + ny * size * 1.6 * side)
  of dkAngle:
    let v = d.anchorPoint(dm.a)
    let b = d.anchorPoint(dm.b)
    let c = d.anchorPoint(dm.c)
    var t0 = arctan2(b[1] - v[1], b[0] - v[0])
    var t1 = arctan2(c[1] - v[1], c[0] - v[0])
    var sweep = t1 - t0
    while sweep > PI: sweep -= 2 * PI
    while sweep < -PI: sweep += 2 * PI
    let r = if dm.offset > 0: dm.offset else: 40.0
    result.path.subs.add line(v, (v[0] + cos(t0) * (r + size), v[1] + sin(t0) * (r + size)))
    result.path.subs.add line(v, (v[0] + cos(t1) * (r + size), v[1] + sin(t1) * (r + size)))
    var arc = SubPath()
    let n = max(4, int(abs(sweep) / (PI / 36)))
    for k in 0 .. n:
      let t = t0 + sweep * k.float / n.float
      let p = (v[0] + cos(t) * r, v[1] + sin(t) * r)
      arc.pts.add PathPoint(p: p, inH: p, outH: p)
    result.path.subs.add arc
    result.text = formatFloat(abs(radToDeg(sweep)), ffDecimal, 1) & "°"
    let tm = t0 + sweep / 2
    result.at = (v[0] + cos(tm) * (r + size * 2.2), v[1] + sin(tm) * (r + size * 2.2))
  of dkRadius:
    let L = d.layerOfUid(dm.a.uid)
    var cx, cy, rad = 0.0
    if L != nil:
      let bx = d.objectBox(L)
      if bx.ok:
        # (a shape's outline, not its stroke)
        let m = if L.isShape: max(0.0, L.shape.strokeWidth) / 2 else: 0.0
        cx = (bx.x0 + bx.x1) / 2
        cy = (bx.y0 + bx.y1) / 2
        rad = max(0.0, (bx.x1 - bx.x0) / 2 - m)
    let t = degToRad(dm.offset)
    let e = (cx + cos(t) * rad, cy - sin(t) * rad)
    result.path.subs.add line((cx, cy), e)
    if rad > size * 1.5: result.path.subs.add arrow(e, (cx, cy), size)
    result.text = "R " & inUnits(rad, unit, d.dpi, d.w)
    result.at = (cx + cos(t) * (rad + size * 3), cy - sin(t) * (rad + size * 3))

proc labelText(d: Doc; text: string; at: (float, float); color: uint32): TextData =
  ## (the label: its middle at `at`)
  let size = float32(max(11.0, d.w.float / 70))
  result = newText(text, CharStyle(size: size, color: color, hScale: 1, vScale: 1), 0, 0)
  let lay = layoutText(result)
  let w = lay.x1 - lay.x0
  result.x = float32(at[0]) - w / 2
  result.y = float32(at[1]) + size * 0.35

proc addDimension*(d: Doc; dm: Dimension; unit: RulerUnit): Layer =
  ## A dimension drawn: its lines (a shape layer, the current one after) and its label over them.
  ## Undoable in a step (`touchLayers` first).
  var m = dm
  if m.color == 0: m.color = 0xFF0060C0'u32
  # (points on no layer: kept where they are)
  let g = d.geometry(m, unit)
  var s = ShapeData(kind: "Dimension", path: g.path, stroke: solidPaint(m.color), fill: solidPaint(m.color),
                    strokeWidth: max(1.0, d.w.float / 900), align: saCenter, cap: lcButt, join: ljMiter)
  let L = d.addShapeLayer(s, $m.kind)
  let T = d.addTextLayer(d.labelText(g.text, g.at, m.color))
  T.name = $m.kind & ": " & g.text
  m.label = T.uidOf
  L.meta = m.metaOf
  T.meta = "dimensionlabel:" & $L.uidOf
  d.cur = d.layers.find(L)
  L

proc updateDimensions*(d: Doc; unit: RulerUnit): int {.discardable.} =
  ## Every dimension drawn again where its points are now, its label in `unit`; how many
  ## changed. In a step, undone with it (`touchLayers` first, as a step that moved them has).
  for L in d.layers:
    let (ok, dm) = dimensionOf(L)
    if not ok: continue
    let g = d.geometry(dm, unit)
    var label: Layer = nil
    if dm.label != 0: label = d.layerOfUid(dm.label)
    let moved = g.path != L.shape.path
    let retext = label != nil and label.isText and label.text.spans.len > 0 and label.text.spans[0].text != g.text
    if not moved and not retext:
      if label == nil or not label.isText: continue
      # (the label where it belongs: moved with the dimension)
      let want = d.labelText(g.text, g.at, dm.color)
      if abs(want.x - label.text.x) < 0.5 and abs(want.y - label.text.y) < 0.5: continue
    d.touchLayers()
    if moved:
      var s = L.shape
      s.path = g.path
      d.setShape(L, s)
    if label != nil and label.isText:
      var t = d.labelText(g.text, g.at, dm.color)
      t.spans[0].style = label.text.spans[0].style
      let lay = layoutText(t)
      t.x = float32(g.at[0]) - (lay.x1 - lay.x0) / 2
      d.setText(label, t)
      label.name = $dm.kind & ": " & g.text
    inc result
