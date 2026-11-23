# (included by photo.nim) The tools of today's drawing, layout and photo programs that the others
# here did not have -- the drawing program's Rotate, Reflect, Scale, Shear, Reshape, Free
# Transform and Puppet Warp tools; Warp, Twirl, Pucker, Bloat, Scallop, Crystallize and Wrinkle on
# shapes; Blend; Live Paint Bucket and Selection; the eight Symbolism tools; the nine Graph
# tools; Print Tiling; the Shaper; the layout program's Page, Gradient Feather and Color Theme
# tools; Affinity's Corner, Point Transform, Contour, Vector Crop, Transparency, Fill, Area, Mesh
# Warp and Deform tools; Touch Type, Area Type, Type on a Path and their vertical kin. Each is a
# mode of the drawing tools (`vecMode` from `vecMoreFirst`); what a drag does is one step.

import std/random
from std/unicode import runeLen

const vecMoreFirst = 19
  ## (the first of these in `vecToolNames`)

type VecFamily = tuple[name: string; first, last: int]
import retroui/lorem

const vecFamilies: array[17, VecFamily] = [
  ("Rotate", 19, 20), ("Scale", 21, 23), ("Free Transform", 24, 25), ("Warp", 26, 32), ("Blend", 33, 33),
  ("Live Paint", 34, 35), ("Symbol Sprayer", 36, 43), ("Graph", 44, 52), ("Print Tiling", 53, 53),
  ("Shaper", 54, 54), ("Page", 55, 55), ("Feather", 56, 57), ("Corner", 58, 60), ("Vector Crop", 61, 61),
  ("Fill", 62, 64), ("Mesh Warp", 65, 66), ("Type", 67, 71)]
  ## (the tools shown together in the options bar)

var
  tt: tuple[pivot: (float, float); pivotFor: Layer; on, started: bool; start: (float, float); dw: DocWin]
    ## (the transform tools: their reference point, the drag)
  ttDlg: tuple[open: bool; mode: int; angle, sx, sy: float; uniform: bool; axis: int]
    ## (the transform tools' box, Alt+click: the numbers)
  liq: tuple[on: bool; dw: DocWin; layer: Layer; path: Path; last: (float, float); t0: int]
    ## (the warp tools: the shape as it is being pushed, its points close together)
  liqSize = 50                   ## the warp tools' brush, pixels across
  liqIntensity = 50              ## ... how strongly, %
  liqDetail = 3                  ## ... how close its points are made, pixels
  reshape: tuple[on: bool; layer: Layer; s0: ShapeData; x0, y0: float]
  reshapeReach = 80              ## the Reshape tool's reach, pixels
  blendFirst: Layer              ## (the Blend tool: the first shape clicked)
  symDensity = 5                 ## the Symbol Sprayer: how close together, 1..10
  symSize = 60                   ## ... the Symbolism tools' brush, pixels across
  symIntensity = 50              ## ... how strongly, %
  symSprayed: tuple[on: bool; last: (float, float)]
  graphDrag: tuple[on: bool; x0, y0, x1, y1: float]
  tileOrigin: Table[pointer, (float, float)]   ## Print Tiling: where each document's tiles start
  shaperPts: seq[(float, float)]
  pageDrag: tuple[on: bool; edge: int; x0, y0: float; w0, h0: int]
  featherDrag: tuple[on: bool; x0, y0, x1, y1: float; layer: Layer]
  themeColors: seq[uint32]       ## the Color Theme tool's last theme
  cornerDrag: tuple[on: bool; layer: Layer; s0: ShapeData; sub, i: int; x0, y0: float]
  ptDrag: tuple[on: bool; from0: (float, float); layers: seq[(Layer, ShapeData)]; dx, dy: float]
  contourDrag: tuple[on: bool; layer: Layer; s0: ShapeData; x0, y0: float; dist: float]
  contourJoin = 0                ## the Contour tool: 0 round, 1 mitre, 2 bevel
  cropDrag: tuple[on: bool; x0, y0, x1, y1: float; layer: Layer]
  gradDrag: tuple[on: bool; x0, y0, x1, y1: float; layer: Layer; s0: ShapeData]
  areaPts: seq[(float, float)]   ## the Area tool's corners clicked so far
  meshW: tuple[on: bool; layer: Layer; cols, rows: int; box: Rect; pts: seq[(float, float)]; grab: int]
  meshCols = 4                   ## Mesh Warp's grid
  meshRows = 4
  bones: tuple[layer: Layer; joints: seq[(float, float)]; rest: seq[(float, float)]; grab: int]
    ## (the Deform tool: its chain of joints, as placed and as moved)
  touch: tuple[on: bool; layer: Layer; idx: int; mode: int; x0, y0: float; t0: TextData]

proc vecFamilyOf(m: int): VecFamily =
  for f in vecFamilies:
    if m >= f.first and m <= f.last: return f
  ("", 0, vecMoreFirst - 1)

# ---- shared ----------------------------------------------------------------------------------------------

proc targetBox(d: Doc): tuple[ok: bool; x0, y0, x1, y1: float] =
  ## (what the transform tools turn: the picked layers' box, else the current layer's)
  var idx = d.pickedLayers
  if idx.len == 0: idx = @[d.cur]
  result = (false, 1e18, 1e18, -1e18, -1e18)
  for i in idx:
    if i < 0 or i >= d.layers.len: continue
    let b = d.objectBox(d.layers[i])
    if not b.ok: continue
    result.ok = true
    result.x0 = min(result.x0, b.x0); result.y0 = min(result.y0, b.y0)
    result.x1 = max(result.x1, b.x1); result.y1 = max(result.y1, b.y1)

proc affineAbout(px, py: float; m: array[4, float]): proc (x, y: float): (float, float) =
  ## (the 2x2 matrix `m` -- a, b, c, d -- applied about the point px, py)
  result = proc (x, y: float): (float, float) =
    let dx = x - px
    let dy = y - py
    (px + m[0] * dx + m[1] * dy, py + m[2] * dx + m[3] * dy)

proc ttMatrix(mode: int; pv, a, b: (float, float); shift: bool): array[4, float] =
  ## (the transform a drag from `a` to `b` makes, about `pv`: 0 rotate, 1 reflect, 2 scale, 3 shear)
  case mode
  of 0:
    var ang = arctan2(b[1] - pv[1], b[0] - pv[0]) - arctan2(a[1] - pv[1], a[0] - pv[0])
    if shift: ang = round(ang / (PI / 4)) * (PI / 4)
    [cos(ang), -sin(ang), sin(ang), cos(ang)]
  of 1:
    var ang = arctan2(b[1] - pv[1], b[0] - pv[0])
    if shift: ang = round(ang / (PI / 4)) * (PI / 4)
    [cos(2 * ang), sin(2 * ang), sin(2 * ang), -cos(2 * ang)]
  of 2:
    let ax = a[0] - pv[0]
    let ay = a[1] - pv[1]
    var sx = if abs(ax) > 1: (b[0] - pv[0]) / ax else: 1.0
    var sy = if abs(ay) > 1: (b[1] - pv[1]) / ay else: 1.0
    if shift:
      let s = hypot(b[0] - pv[0], b[1] - pv[1]) / max(1.0, hypot(ax, ay))
      sx = s
      sy = s
    [sx, 0.0, 0.0, sy]
  else:
    let ay = a[1] - pv[1]
    let ax = a[0] - pv[0]
    if shift or abs(ay) < 1:
      let k = if abs(ax) > 1: (b[1] - a[1]) / ax else: 0.0
      [1.0, 0.0, k, 1.0]
    else:
      [1.0, (b[0] - a[0]) / ay, 0.0, 1.0]

proc ttApply(m: array[4, float]; pv: (float, float)) =
  ## (the box the Free Transform holds made `m` about `pv`, shown)
  if not xf.on: return
  let f = affineAbout(pv[0], pv[1], m)
  for k in 0 .. 3: xf.quad[k] = f(xf.quad0[k][0], xf.quad0[k][1])
  xfApply()

proc ttRun(mode: int; m: array[4, float]; copy: bool) =
  ## (the transform tools' box: done at once, on a copy when asked)
  let dw = active
  if dw == nil: return
  let d = dw.doc
  if copy:
    d.beginStep("Duplicate Layer")
    discard d.duplicateLayer()
    d.endStep()
  startTransform(xkDistort)
  if not xf.on: return
  ttApply(m, tt.pivot)
  finishTransform(true)

proc ttDialog() =
  if not ttDlg.open: return
  var go, copy = false
  let title = ["Rotate", "Reflect", "Scale", "Shear"][clamp(ttDlg.mode, 0, 3)]
  dialog(ttDlg.open, title, 340):
    case ttDlg.mode
    of 0:
      row([90, -1]):
        label "Angle:"
        discard numberEdit(ttDlg.angle, decimals = 1, w = dp(80), lo = -360, hi = 360)
    of 1:
      label("Axis:", bold = true)
      radio("Horizontal", ttDlg.axis, 0)
      radio("Vertical", ttDlg.axis, 1)
      radio("Angle:", ttDlg.axis, 2)
      discard numberEdit(ttDlg.angle, decimals = 1, w = dp(80), lo = -360, hi = 360)
    of 2:
      checkbox("Uniform", ttDlg.uniform)
      row([90, -1]):
        label(if ttDlg.uniform: "Scale:" else: "Horizontal:")
        discard numberEdit(ttDlg.sx, decimals = 1, w = dp(80), lo = -10000, hi = 10000)
      if not ttDlg.uniform:
        row([90, -1]):
          label "Vertical:"
          discard numberEdit(ttDlg.sy, decimals = 1, w = dp(80), lo = -10000, hi = 10000)
      if checkbox("Scale Strokes && Effects", prefs.scaleStrokes): savePrefs()
    else:
      row([90, -1]):
        label "Shear Angle:"
        discard numberEdit(ttDlg.angle, decimals = 1, w = dp(80), lo = -89, hi = 89)
      radio("Horizontal", ttDlg.axis, 0)
      radio("Vertical", ttDlg.axis, 1)
    row:
      spring()
      if button("Copy", w = dp(70)): copy = true
      if button("OK", isDefault = true, w = dp(70)): go = true
      if button("Cancel", w = dp(70)): ttDlg.open = false
  if go or copy:
    ttDlg.open = false
    let a = degToRad(ttDlg.angle)
    let m = case ttDlg.mode
            of 0: [cos(a), sin(a), -sin(a), cos(a)]     # (counterclockwise as it shows: y runs down)
            of 1:
              let ax = case ttDlg.axis
                       of 0: 0.0
                       of 1: PI / 2
                       else: -a
              [cos(2 * ax), sin(2 * ax), sin(2 * ax), -cos(2 * ax)]
            of 2:
              let sx = ttDlg.sx / 100
              let sy = if ttDlg.uniform: sx else: ttDlg.sy / 100
              [sx, 0.0, 0.0, sy]
            else:
              if ttDlg.axis == 0: [1.0, -tan(a), 0.0, 1.0] else: [1.0, 0.0, -tan(a), 1.0]
    ttRun(ttDlg.mode, m, copy)

# ---- the warp tools on shapes -----------------------------------------------------------------------------------

proc densePath(p: Path; step: float): Path =
  ## (a path as close points -- straight between them -- so a brush can push each)
  for sp in p.subs:
    var poly: seq[(float, float)]
    let one = Path(subs: @[sp])
    let ls = flatten(one, 24)
    if ls.len == 0: continue
    var src = ls[0]
    # (evenly: a point every `step` pixels)
    poly.add src[0]
    var carry = 0.0
    for i in 1 ..< src.len:
      var a = src[i - 1]
      let b = src[i]
      var seg = hypot(b[0] - a[0], b[1] - a[1])
      while carry + seg >= step and seg > 0:
        let t = (step - carry) / seg
        a = (a[0] + (b[0] - a[0]) * t, a[1] + (b[1] - a[1]) * t)
        poly.add a
        seg = hypot(b[0] - a[0], b[1] - a[1])
        carry = 0
      carry += seg
    if not sp.closed and (poly.len == 0 or poly[^1] != src[^1]): poly.add src[^1]
    var ns = SubPath(closed: sp.closed, op: sp.op, joined: sp.joined)
    for q in poly: ns.pts.add PathPoint(p: q, inH: q, outH: q)
    result.subs.add ns

proc liqPush(p: var Path; mode: int; cx, cy, dx, dy, radius, strength: float; tick: int) =
  ## (the points within `radius` of cx, cy moved as the tool says, more near the middle)
  let r2 = radius * radius
  var k = 0
  for sp in p.subs.mitems:
    for q in sp.pts.mitems:
      inc k
      let ox = q.p[0] - cx
      let oy = q.p[1] - cy
      let dd = ox * ox + oy * oy
      if dd >= r2: continue
      let f = (1 - dd / r2) * (1 - dd / r2) * strength
      var nx = q.p[0]
      var ny = q.p[1]
      let dist = sqrt(dd)
      case mode
      of 0:                                              # Warp: along with the drag
        nx += dx * f
        ny += dy * f
      of 1:                                              # Twirl: round the middle
        let a = 0.12 * f
        nx = cx + ox * cos(a) - oy * sin(a)
        ny = cy + ox * sin(a) + oy * cos(a)
      of 2:                                              # Pucker: toward it
        nx -= ox * 0.12 * f
        ny -= oy * 0.12 * f
      of 3:                                              # Bloat: away
        if dist > 1e-6:
          nx += ox / dist * radius * 0.06 * f
          ny += oy / dist * radius * 0.06 * f
      of 4:                                              # Scallop: toward it in arcs
        let w = sin(float(k) * 0.9) * 0.5 + 0.5
        nx -= ox * 0.1 * f * (0.4 + w)
        ny -= oy * 0.1 * f * (0.4 + w)
      of 5:                                              # Crystallize: spikes outward
        if dist > 1e-6:
          let spike = if k mod 3 == 0: 1.0 else: 0.15
          nx += ox / dist * radius * 0.08 * f * spike
          ny += oy / dist * radius * 0.08 * f * spike
      else:                                              # Wrinkle: shaken across
        let h = float((k * 7919 + tick * 104729) mod 1000) / 500 - 1
        let v = float((k * 6007 + tick * 7151) mod 1000) / 500 - 1
        nx += h * radius * 0.03 * f
        ny += v * radius * 0.015 * f
      q.p = (nx, ny)
      q.inH = q.p
      q.outH = q.p

# ---- shaper: a rough drawing made a shape ---------------------------------------------------------------------

proc rdp(pts: seq[(float, float)]; eps: float): seq[(float, float)] =
  ## (Ramer-Douglas-Peucker: the corners of a hand-drawn line)
  if pts.len < 3: return pts
  var keep = newSeq[bool](pts.len)
  keep[0] = true
  keep[^1] = true
  var stack = @[(0, pts.high)]
  while stack.len > 0:
    let (a, b) = stack.pop()
    var best = -1.0
    var bi = -1
    let (ax, ay) = pts[a]
    let (bx, by) = pts[b]
    let L = max(1e-9, hypot(bx - ax, by - ay))
    for i in a + 1 ..< b:
      let d = abs((bx - ax) * (ay - pts[i][1]) - (ax - pts[i][0]) * (by - ay)) / L
      if d > best:
        best = d
        bi = i
    if best > eps and bi > 0:
      keep[bi] = true
      stack.add (a, bi)
      stack.add (bi, b)
  for i, k in keep:
    if k: result.add pts[i]

proc shaperFinish(d: Doc) =
  ## (the Shaper's drawing: a rectangle, an ellipse, a triangle, a polygon or a line -- or, a scribble
  ## over shapes, those shapes taken away)
  let pts = shaperPts
  shaperPts = @[]
  if pts.len < 4: return
  var x0, y0 = 1e18
  var x1, y1 = -1e18
  var length = 0.0
  for i, p in pts:
    x0 = min(x0, p[0]); y0 = min(y0, p[1]); x1 = max(x1, p[0]); y1 = max(y1, p[1])
    if i > 0: length += hypot(p[0] - pts[i - 1][0], p[1] - pts[i - 1][1])
  let w = x1 - x0
  let h = y1 - y0
  let size = max(w, h)
  if size < 6: return
  # (a scribble: back and forth many times -- what it went over goes)
  var turns = 0
  for i in 2 ..< pts.len:
    let ax = pts[i - 1][0] - pts[i - 2][0]
    let ay = pts[i - 1][1] - pts[i - 2][1]
    let bx = pts[i][0] - pts[i - 1][0]
    let by = pts[i][1] - pts[i - 1][1]
    if ax * bx + ay * by < -0.3 * hypot(ax, ay) * hypot(bx, by): inc turns
  if turns >= 6 and length > 3 * (w + h):
    var gone: seq[int]
    for i in countdown(d.layers.high, 0):
      let L = d.layers[i]
      if not L.isShape or not L.visible or L.locked: continue
      let b = d.objectBox(L)
      if not b.ok: continue
      var hits = 0
      for p in pts:
        if p[0] >= b.x0 and p[0] <= b.x1 and p[1] >= b.y0 and p[1] <= b.y1: inc hits
      if hits > pts.len div 3: gone.add i
    if gone.len > 0:
      d.beginStep("Shaper")
      d.touchLayers()
      for i in gone: d.deleteLayer(i)
      d.endStep()
      status = tr("Shaper: the scribble took away ") & $gone.len & tr(" shape(s)")
    return
  let closed = hypot(pts[^1][0] - pts[0][0], pts[^1][1] - pts[0][1]) < size * 0.25
  var s = ShapeData(fill: solidPaint(fg or 0xFF000000'u32), strokeWidth: 0)
  var name = ""
  if not closed:
    # (a line: from its start to its end)
    s.path.subs.add SubPath(pts: @[PathPoint(p: pts[0], inH: pts[0], outH: pts[0]),
                                   PathPoint(p: pts[^1], inH: pts[^1], outH: pts[^1])])
    s.fill = ShapePaint(kind: spNone)
    s.stroke = solidPaint(fg or 0xFF000000'u32)
    s.strokeWidth = max(1.0, shapeStrokeW.float)
    s.kind = "Line"
    name = "Line"
  else:
    let corners = rdp(pts & @[pts[0]], size * 0.12)
    let n = corners.len - 1
    # (round: how far its points stray from the ellipse in its box)
    var off = 0.0
    let cx = (x0 + x1) / 2
    let cy = (y0 + y1) / 2
    for p in pts:
      let u = (p[0] - cx) / max(1.0, w / 2)
      let v = (p[1] - cy) / max(1.0, h / 2)
      off += abs(sqrt(u * u + v * v) - 1)
    off /= float(pts.len)
    if off < 0.12 or n > 6:
      s.path = liveShapePath(defaultParams(lsPolygon), x0, y0, x1, y1)
      s.path = Path(subs: @[])
      const k = 0.5523
      let rx = w / 2
      let ry = h / 2
      var sp = SubPath(closed: true)
      for (p, a, b) in [((cx + rx, cy), (0.0, -ry * k), (0.0, ry * k)), ((cx, cy + ry), (rx * k, 0.0), (-rx * k, 0.0)),
                        ((cx - rx, cy), (0.0, ry * k), (0.0, -ry * k)), ((cx, cy - ry), (-rx * k, 0.0), (rx * k, 0.0))]:
        sp.pts.add PathPoint(p: p, inH: (p[0] + a[0], p[1] + a[1]), outH: (p[0] + b[0], p[1] + b[1]))
      s.path.subs.add sp
      s.kind = "Ellipse"
      name = "Ellipse"
    elif n == 3:
      var sp = SubPath(closed: true)
      for i in 0 ..< 3: sp.pts.add PathPoint(p: corners[i], inH: corners[i], outH: corners[i])
      s.path.subs.add sp
      name = "Triangle"
    elif n == 4:
      # (a rectangle: straight when it nearly is)
      var sp = SubPath(closed: true)
      for q in [(x0, y0), (x1, y0), (x1, y1), (x0, y1)]: sp.pts.add PathPoint(p: q, inH: q, outH: q)
      s.path.subs.add sp
      s.kind = "Rectangle"
      name = "Rectangle"
    else:
      var p = defaultParams(lsPolygon)
      p.v[0] = float(max(5, n))
      s.path = liveShapePath(p, x0, y0, x1, y1)
      name = "Polygon"
  d.beginStep("Shaper")
  d.touchLayers()
  discard d.addShapeLayer(s, name = name)
  d.endStep()
  status = tr("Shaper: ") & tr(name)

# ---- the Color Theme tool ---------------------------------------------------------------------------------------

proc colorTheme(d: Doc; cx, cy: int; n = 5): seq[uint32] =
  ## (the main colors of the picture round a point -- or all of it: k-means on a sample)
  d.updateComposite()
  let c = d.compPtr
  let reach = max(d.w, d.h) div 6
  var sample: seq[(float, float, float)]
  var step = max(1, (reach * 2) div 90)
  for y in countup(max(0, cy - reach), min(d.h - 1, cy + reach), step):
    for x in countup(max(0, cx - reach), min(d.w - 1, cx + reach), step):
      let p = c[y * d.w + x]
      if aOf(p) < 128: continue
      sample.add (rOf(p).float, gOf(p).float, bOf(p).float)
  if sample.len == 0: return
  var cents: seq[(float, float, float)]
  for k in 0 ..< n: cents.add sample[(k * sample.len) div n + (sample.len div (2 * n))]
  for iter in 0 ..< 12:
    var acc = newSeq[(float, float, float, int)](n)
    for s in sample:
      var best = 0
      var bd = 1e18
      for k, ce in cents:
        let dd = (s[0] - ce[0]) ^ 2 + (s[1] - ce[1]) ^ 2 + (s[2] - ce[2]) ^ 2
        if dd < bd:
          bd = dd
          best = k
      acc[best] = (acc[best][0] + s[0], acc[best][1] + s[1], acc[best][2] + s[2], acc[best][3] + 1)
    for k in 0 ..< n:
      if acc[k][3] > 0:
        cents[k] = (acc[k][0] / acc[k][3].float, acc[k][1] / acc[k][3].float, acc[k][2] / acc[k][3].float)
  for ce in cents: result.add argb(255, int(ce[0]), int(ce[1]), int(ce[2]))
  # (light to dark, as a theme is shown)
  result.sort(proc (a, b: uint32): int = cmp(lumaOf(b), lumaOf(a)))

# ---- the corner tool ------------------------------------------------------------------------------------------

proc roundCorner(s0: ShapeData; sub, i: int; r: float): ShapeData =
  ## (a shape with its corner `i` of `sub` rounded by `r` pixels: two points and an arc between)
  result = s0
  if sub >= result.path.subs.len: return
  var sp = result.path.subs[sub]
  let n = sp.pts.len
  if n < 2 or i >= n: return
  if not sp.closed and (i == 0 or i == n - 1): return
  let p = sp.pts[i].p
  let a = sp.pts[(i + n - 1) mod n].p
  let b = sp.pts[(i + 1) mod n].p
  let la = hypot(a[0] - p[0], a[1] - p[1])
  let lb = hypot(b[0] - p[0], b[1] - p[1])
  let rr = clamp(r, 0.0, min(la, lb) * 0.5)
  if rr < 0.5 or la < 1e-6 or lb < 1e-6: return
  const k = 0.5523
  let s = (p[0] + (a[0] - p[0]) * rr / la, p[1] + (a[1] - p[1]) * rr / la)
  let e = (p[0] + (b[0] - p[0]) * rr / lb, p[1] + (b[1] - p[1]) * rr / lb)
  var ps = PathPoint(p: s, inH: s, outH: (s[0] + (p[0] - s[0]) * k, s[1] + (p[1] - s[1]) * k))
  var pe = PathPoint(p: e, inH: (e[0] + (p[0] - e[0]) * k, e[1] + (p[1] - e[1]) * k), outH: e)
  ps.inH = (s[0] + (sp.pts[i].inH[0] - p[0]) * 0, s[1])   # (straight in)
  ps.inH = s
  sp.pts[i] = ps
  sp.pts.insert(pe, i + 1)
  result.path.subs[sub] = sp

# ---- Mesh Warp --------------------------------------------------------------------------------------------------

proc meshWarpApply(d: Doc) =
  ## (the layer's pixels in the mesh's box drawn again cell by cell into where the cell's corners went)
  let L = meshW.layer
  if L == nil or L.px.len != d.w * d.h: return
  let r = meshW.box
  let cols = meshW.cols
  let rows = meshW.rows
  var res = d.vacatedCopy(L.px, r, 0'u32)
  let src = L.px
  for j in 0 ..< rows:
    for i in 0 ..< cols:
      let cx0 = r.x + r.w * i div cols
      let cx1 = r.x + r.w * (i + 1) div cols
      let cy0 = r.y + r.h * j div rows
      let cy1 = r.y + r.h * (j + 1) div rows
      let cell = rect(cx0, cy0, max(1, cx1 - cx0), max(1, cy1 - cy0))
      let k = j * (cols + 1) + i
      let q: Quad = [meshW.pts[k], meshW.pts[k + 1], meshW.pts[k + cols + 2], meshW.pts[k + cols + 1]]
      d.warpOnto(res, cast[ptr UncheckedArray[uint32]](unsafeAddr src[cell.y * d.w + cell.x]), d.w, cell, q)
  discard d.touchWhole(L)
  L.px = move(res)
  inc L.ver
  d.markAll()

proc meshWarpStart(d: Doc) =
  let L = d.current
  if L == nil or L.px.len != d.w * d.h or L.isShape or L.isText or L.group:
    status = tr("Mesh Warp: pick a layer of pixels")
    return
  var r = d.layerBox(L)
  if d.hasSelection: r = d.clip(d.selBounds)
  if r.w < 4 or r.h < 4: return
  meshW = (true, L, meshCols, meshRows, r, newSeq[(float, float)](), -1)
  for j in 0 .. meshRows:
    for i in 0 .. meshCols:
      meshW.pts.add (float(r.x) + float(r.w) * float(i) / float(meshCols),
                     float(r.y) + float(r.h) * float(j) / float(meshRows))
  status = tr("Mesh Warp: drag the mesh's points; Enter to apply, Esc to leave it")

# ---- Deform: bones -------------------------------------------------------------------------------------------

proc deformApply(d: Doc) =
  ## (the layer bent as its bones were moved: each pixel carried by the bones near it, weighed by
  ## how near -- linear blend skinning)
  let L = bones.layer
  if L == nil or L.px.len != d.w * d.h or bones.joints.len < 2: return
  let n = bones.joints.len
  # (each bone: its turn and its move, from rest to now)
  var rot: seq[(float, float, float, float)]     # cos, sin, the rest start, then the moved start
  for k in 0 ..< n - 1:
    let a0 = bones.rest[k]
    let a1 = bones.rest[k + 1]
    let b0 = bones.joints[k]
    let b1 = bones.joints[k + 1]
    let ang = arctan2(b1[1] - b0[1], b1[0] - b0[0]) - arctan2(a1[1] - a0[1], a1[0] - a0[0])
    rot.add (cos(ang), sin(ang), 0.0, 0.0)
  let r = d.layerBox(L)
  if r.w <= 0 or r.h <= 0: return
  var res = d.vacatedCopy(L.px, r, 0'u32)
  let src = L.px
  let grow = max(r.w, r.h) div 4
  let out0 = d.clip(rect(r.x - grow, r.y - grow, r.w + 2 * grow, r.h + 2 * grow))
  # (backward: for each pixel of the result, where it came from -- inverted bone by bone, weighed)
  for y in out0.y ..< out0.y + out0.h:
    for x in out0.x ..< out0.x + out0.w:
      var sx, sy, ws = 0.0
      for k in 0 ..< n - 1:
        let b0 = bones.joints[k]
        let b1 = bones.joints[k + 1]
        let vx = b1[0] - b0[0]
        let vy = b1[1] - b0[1]
        let L2 = max(1e-6, vx * vx + vy * vy)
        let t = clamp(((float(x) - b0[0]) * vx + (float(y) - b0[1]) * vy) / L2, 0, 1)
        let dd = hypot(float(x) - (b0[0] + vx * t), float(y) - (b0[1] + vy * t))
        let w = 1 / (1 + (dd / 30) ^ 3)
        let (c, s, _, _) = rot[k]
        # (back from the moved bone to the bone at rest)
        let ox = float(x) - b0[0]
        let oy = float(y) - b0[1]
        let rx = bones.rest[k][0] + ox * c + oy * s
        let ry = bones.rest[k][1] - ox * s + oy * c
        sx += rx * w
        sy += ry * w
        ws += w
      if ws <= 0: continue
      sx /= ws
      sy /= ws
      let ix = int(round(sx))
      let iy = int(round(sy))
      if ix >= r.x and iy >= r.y and ix < r.x + r.w and iy < r.y + r.h:
        res[y * d.w + x] = src[iy * d.w + ix]
  discard d.touchWhole(L)
  L.px = move(res)
  inc L.ver
  d.markAll()

# ---- measurements: the Area tool's, the Ruler's and the Count tool's, kept (Image > Analysis) ----------------

var measureLog: seq[tuple[label, doc, at: string; area, perimeter, length, angle: float; count: int]]
  ## (Window > Measurement Log: each measurement recorded, in the order taken)

proc lengthText(d: Doc; px: float): string =
  ## (a length in the rulers' unit, with it)
  let u = viewPrefs.rulerUnit
  let per = unitPixels(u, d.dpi, d.w)
  formatFloat(px / per, ffDecimal, unitDecimalsOf(u)) & " " & unitShort()

proc areaText(d: Doc; px2: float): string =
  ## (an area in the rulers' unit squared)
  let u = viewPrefs.rulerUnit
  let per = unitPixels(u, d.dpi, d.w)
  formatFloat(px2 / (per * per), ffDecimal, unitDecimalsOf(u)) & " " & unitShort() & "²"

proc logMeasurement(d: Doc; label: string; area, perimeter: float; count: int; length = 0.0; angle = 0.0) =
  measureLog.add (label, d.name, now().format("yyyy-MM-dd HH:mm:ss"), area, perimeter, length, angle, count)

# ---- Touch Type's letters ------------------------------------------------------------------------------------

proc charAt(d: Doc; L: Layer; x, y: float): int =
  ## (the letter of type layer `L` drawn at `x`, `y`: -1 none)
  let t = d.effectiveText(L)
  let lay = layoutText(t)
  if lay.lines.len == 0: return -1
  let k = t.charAtDrawn(lay, float32(x), float32(y))
  if k >= t.plainText.runeLen: max(0, k - 1) else: k

proc applyToChar(t: var TextData; i: int; change: proc (st: var CharStyle)) =
  ## (one letter's style changed: it gets a style of its own)
  t.restyle(i, i + 1, change)

# ---- type in a shape, type on a path ----------------------------------------------------------------------------

proc makeAreaType(d: Doc; S: Layer; vertical = false) =
  ## (Area Type: a type layer in the shape's box, kept inside its outline -- the shape becomes its
  ## frame: it keeps no fill or stroke, and its outline holds this text only)
  let b = pathBounds(S.shape.path)
  if b[2] - b[0] < 4 or b[3] - b[1] < 4: return
  d.beginStep("Area Type")
  d.touchLayers()
  var t = newText(lorem(1), typingStyle())
  t.x = float32(b[0])
  t.y = float32(b[1])
  t.boxW = float32(b[2] - b[0])
  t.boxH = float32(b[3] - b[1])
  t.vertical = vertical
  let T = d.addTextLayer(t, above = d.layers.find(S))
  var s = S.shape
  s.fill = ShapePaint(kind: spNone)
  s.stroke = ShapePaint(kind: spNone)
  d.setShape(S, s)
  S.wrap = 1
  S.wrapOpts.invert = true
  S.wrapOpts.frameOf = T.uidOf
  d.cur = d.layers.find(T)
  d.rewrap()
  d.endStep()
  status = tr("Area Type: the text flows inside the shape -- type over it with the Type tool")

proc makePathType(d: Doc; p: Path; at: (float, float); vertical = false) =
  ## (Type on a Path: a type layer whose text runs along the path from where it was clicked; vertical,
  ## each letter standing across it)
  let polys = flatten(p, 16)
  if polys.len == 0 or polys[0].len < 2: return
  var pts: seq[(float32, float32)]
  for q in polys[0]: pts.add (float32(q[0]), float32(q[1]))
  # (where along it the click was)
  var best = 1e18
  var along = 0.0
  var run = 0.0
  for i in 1 ..< pts.len:
    let a = pts[i - 1]
    let b = pts[i]
    let seg = hypot(float(b[0] - a[0]), float(b[1] - a[1]))
    let dd = hypot(float(a[0]) - at[0], float(a[1]) - at[1])
    if dd < best:
      best = dd
      along = run
    run += seg
  d.beginStep("Type on a Path")
  d.touchLayers()
  var st = typingStyle()
  if vertical: st.rotation = 90
  var t = newText(tr("Type on a path"), st)
  t.path = pts
  t.pathOffset = float32(along)
  let T = d.addTextLayer(t)
  d.cur = d.layers.find(T)
  d.endStep()
  status = tr("Type on a Path: type over it with the Type tool")

# ---- the events ------------------------------------------------------------------------------------------------

proc moreVectorEvents(dw: DocWin; ev: PhotoEvent): bool =
  ## The press, drag and release of these tools; true when one took it.
  let d = dw.doc
  let m = vecMode
  let rad = dw.pickRadius
  case m
  of 19 .. 22:
    # Rotate, Reflect, Scale, Shear: about the reference point (a click sets it; Alt+click: the box)
    let mode = m - 19
    if ev.pressed and ev.over:
      let tb = d.targetBox
      if not tb.ok:
        status = tr("Pick a layer to transform")
        return true
      if tt.pivotFor != d.current:
        tt.pivot = ((tb.x0 + tb.x1) / 2, (tb.y0 + tb.y1) / 2)
        tt.pivotFor = d.current
      if ev.alt:
        tt.pivot = (ev.x, ev.y)
        ttDlg = (true, mode, (if mode == 3: 20.0 else: 45.0), 100.0, 100.0, true, (if mode == 1: 1 else: 0))
        return true
      tt.on = true
      tt.started = false
      tt.start = (ev.x, ev.y)
      tt.dw = dw
      return true
    if tt.on and tt.dw == dw:
      if ev.down and ev.moved:
        if not tt.started and hypot(ev.x - tt.start[0], ev.y - tt.start[1]) * dw.view.scaleOf > 3:
          startTransform(xkDistort)
          tt.started = xf.on
          toolXf = xf.on
        if tt.started: ttApply(ttMatrix(mode, tt.pivot, tt.start, (ev.x, ev.y), ev.shift), tt.pivot)
      if ev.released or not ui.mouseDown:
        tt.on = false
        if tt.started:
          toolXf = false
          finishTransform(true)
        else:
          tt.pivot = tt.start          # (a click: the reference point there)
          tt.pivotFor = d.current
          status = tr("The reference point is set: drag to ") & tr(["rotate", "reflect", "scale", "shear"][mode])
      return true
  of 23:
    # Reshape: a place on the outline pulled, the curve round it following
    if ev.pressed and ev.over:
      let i = d.layerAt(int(ev.x), int(ev.y), rad)
      let L = if i >= 0 and d.layers[i].isShape: d.layers[i] elif d.current.isShape: d.current else: nil
      if L == nil:
        status = tr("Reshape: drag a shape's outline")
        return true
      d.beginStep("Reshape")
      d.touchLayers()
      reshape = (true, L, L.shape, ev.x, ev.y)
      return true
    if reshape.on:
      if ev.down and ev.moved:
        var s = reshape.s0
        let dx = ev.x - reshape.x0
        let dy = ev.y - reshape.y0
        let rr = reshapeReach.float
        for sp in s.path.subs.mitems:
          for q in sp.pts.mitems:
            let dd = hypot(q.p[0] - reshape.x0, q.p[1] - reshape.y0)
            let w = exp(-(dd / rr) ^ 2 * 2)
            q.p = (q.p[0] + dx * w, q.p[1] + dy * w)
            q.inH = (q.inH[0] + dx * w, q.inH[1] + dy * w)
            q.outH = (q.outH[0] + dx * w, q.outH[1] + dy * w)
        d.setShape(reshape.layer, s)
      if ev.released or not ui.mouseDown:
        reshape.on = false
        if d.stepOpen: d.endStep()
      return true
  of 24:
    if ev.pressed and ev.over and not xf.on:
      runCommand("Free Transform")
      return true
  of 25:
    if ev.pressed and ev.over:
      runCommand("Puppet Warp")
      return true
  of 26 .. 32:
    # the warp tools: the shape under the brush pushed about
    if ev.pressed and ev.over:
      var L = d.current
      if L == nil or not L.isShape:
        let i = d.layerAt(int(ev.x), int(ev.y), liqSize div 2)
        if i >= 0 and d.layers[i].isShape:
          L = d.layers[i]
          d.cur = i
      if L == nil or not L.isShape:
        status = tr("Pick a shape to work it with the brush")
        return true
      d.beginStep(vecToolNames[m])
      d.touchLayers()
      liq = (true, dw, L, densePath(L.shape.path, max(1.0, liqDetail.float)), (ev.x, ev.y), ui.now)
      return true
    if liq.on and liq.dw == dw:
      if ev.down:
        let held = m in {27, 28, 29, 30, 31, 32}
        if ev.moved or held:
          liq.path.liqPush(m - 26, ev.x, ev.y, ev.x - liq.last[0], ev.y - liq.last[1], liqSize.float / 2,
                           liqIntensity.float / 100, ui.now div 30)
          liq.last = (ev.x, ev.y)
          var s = liq.layer.shape
          s.path = liq.path
          d.setShape(liq.layer, s)
          if held: wakeIn(30)
      if ev.released or not ui.mouseDown:
        liq.on = false
        # (the close points made curves again)
        var s = liq.layer.shape
        s.path = simplifyPath(liq.path, max(0.4, liqDetail.float / 4))
        d.setShape(liq.layer, s)
        if d.stepOpen: d.endStep()
      return true
  of 33:
    # Blend: a shape clicked, then another: the blend between them
    if ev.pressed and ev.over:
      let i = d.layerAt(int(ev.x), int(ev.y), rad)
      if i < 0 or not d.layers[i].isShape:
        status = tr("Blend: click a shape, then another")
        return true
      let L = d.layers[i]
      if blendFirst == nil or blendFirst notin d.layers or blendFirst == L:
        blendFirst = L
        status = tr("Blend: now click the shape to blend it into")
      else:
        blendPair = (blendFirst, L)
        blendFirst = nil
        makeBlend()
      return true
  of 34:
    return false                       # (the Live Paint Bucket's own click: photo/makers)
  of 35:
    # Live Paint Selection: a face clicked is selected; Alt+click empties it, Ctrl+click fills it
    if ev.pressed and ev.over:
      let P = d.current
      let (on, lp0) = P.livePaintOf
      if not on:
        status = tr("Live Paint Selection: pick a Live Paint group (Object > Live Paint > Make)")
        return true
      let x = int(ev.x)
      let y = int(ev.y)
      let here = d.faceMask(lp0, x, y)
      if here.len == 0: return true
      if ev.alt or ev.ctrl:
        var lp = lp0
        var keep: seq[LivePaintFace]
        for f in lp.faces:
          if f.x >= 0 and f.y >= 0 and f.x < d.w and f.y < d.h and here[f.y * d.w + f.x] >= 128: continue
          keep.add f
        lp.faces = keep
        if ev.ctrl: lp.fillFace(x, y, fg or 0xFF000000'u32)
        d.layersChange("Live Paint Selection"): P.setLivePaint(lp)
      else:
        d.beginStep("Live Paint Selection")
        d.touchSel()
        if not ev.shift: d.sel = newSeq[uint8](d.w * d.h)
        elif d.sel.len != d.w * d.h: d.sel = newSeq[uint8](d.w * d.h)
        for k in 0 ..< min(here.len, d.sel.len): d.sel[k] = max(d.sel[k], here[k])
        inc d.selVer
        d.endStep()
        status = tr("A face selected: Alt+click empties it, Ctrl+click fills it with the foreground color")
      return true
  of 36:
    # Symbol Sprayer: instances of the current symbol sprayed along the drag
    let syms = d.symbols
    if ev.pressed and ev.over:
      if syms.len == 0:
        status = tr("Symbol Sprayer: make a symbol first (Layer > Symbols > Create Symbol)")
        return true
      d.beginStep("Symbol Sprayer")
      d.touchLayers()
      symSprayed = (true, (-1e9, -1e9))
    if symSprayed.on:
      if ev.down and syms.len > 0:
        let gap = float(symSize) / float(clamp(symDensity, 1, 10))
        if hypot(ev.x - symSprayed.last[0], ev.y - symSprayed.last[1]) >= gap:
          var id = syms[0].id
          let curSym = d.current.symbolOf
          if curSym.id != 0: id = curSym.id
          let ins = d.symbolInstances(id)
          if ins.len > 0:
            let b = d.objectBox(d.layers[ins[^1]])
            if b.ok:
              let jx = (rand(1.0) - 0.5) * float(symSize) * 0.6
              let jy = (rand(1.0) - 0.5) * float(symSize) * 0.6
              let dx = int(round(ev.x + jx - (b.x0 + b.x1) / 2))
              let dy = int(round(ev.y + jy - (b.y0 + b.y1) / 2))
              discard d.insertSymbol(id, dx, dy)
          symSprayed.last = (ev.x, ev.y)
      if ev.released or not ui.mouseDown:
        symSprayed.on = false
        if d.stepOpen: d.endStep()
      return true
  of 37 .. 43:
    # the other Symbolism tools: on the instances under the brush
    if ev.pressed and ev.over:
      d.beginStep(vecToolNames[m])
      d.touchLayers()
      symSprayed = (true, (ev.x, ev.y))
    if symSprayed.on:
      if ev.down:
        let r = float(symSize) / 2
        let k = float(symIntensity) / 100
        for s in d.symbols:
          for gi in s.instances:
            if gi >= d.layers.len: continue
            let g = d.layers[gi]
            let b = d.objectBox(g)
            if not b.ok: continue
            let cx = (b.x0 + b.x1) / 2
            let cy = (b.y0 + b.y1) / 2
            let dd = hypot(cx - ev.x, cy - ev.y)
            if dd > r: continue
            let f = (1 - dd / r) * k
            var parts: seq[Layer]
            for j in d.blockStart(gi) ..< gi:
              if d.layers[j].depth > g.depth: parts.add d.layers[j]
            case m
            of 37:                     # Shifter: along with the drag
              let dx = int(round((ev.x - symSprayed.last[0]) * f))
              let dy = int(round((ev.y - symSprayed.last[1]) * f))
              if dx != 0 or dy != 0:
                for P in parts:
                  if P.isShape:
                    var sh = P.shape
                    sh.path = sh.path.translated(dx.float, dy.float)
                    d.setShape(P, sh)
                  elif not P.group: d.shiftLayers(@[P], dx, dy)
            of 38, 39, 40:             # Scruncher (toward the brush), Sizer (bigger), Spinner (turned)
              let mm = case m
                       of 38:
                         let pull = (if ev.alt: -0.03 else: 0.03) * f
                         let dx = int(round((ev.x - cx) * pull))
                         let dy = int(round((ev.y - cy) * pull))
                         if dx != 0 or dy != 0:
                           for P in parts:
                             if P.isShape:
                               var sh = P.shape
                               sh.path = sh.path.translated(dx.float, dy.float)
                               d.setShape(P, sh)
                             elif not P.group: d.shiftLayers(@[P], dx, dy)
                         [1.0, 0.0, 0.0, 1.0]
                       of 39:
                         let s = if ev.alt: 1 - 0.03 * f else: 1 + 0.03 * f
                         [s, 0.0, 0.0, s]
                       else:
                         let a = 0.06 * f * (if ev.alt: -1.0 else: 1.0)
                         [cos(a), -sin(a), sin(a), cos(a)]
              if m != 38:
                let fn = affineAbout(cx, cy, mm)
                for P in parts:
                  if P.isShape:
                    var sh = P.shape
                    sh.path.mapPoints(fn)
                    d.setShape(P, sh)
            of 41:                     # Stainer: tinted toward the foreground color
              for P in parts:
                if P.isShape:
                  var sh = P.shape
                  if sh.fill.kind == spColor:
                    sh.fill.color = mix(sh.fill.color, fg or 0xFF000000'u32, 0.08 * f * (if ev.alt: -1.0 else: 1.0))
                  d.setShape(P, sh)
            of 42:                     # Screener: more see-through (Alt: less)
              g.opacity = clamp(g.opacity + (if ev.alt: 2 else: -2), 5, 100)
              inc g.ver
            else:                      # Styler: the current layer's style (a style's, else the first preset)
              let sty = if d.current.hasFx: d.current.fx else: stylePresets()[0].fx
              for P in parts:
                if not P.group: P.fx = sty
                inc P.ver
        symSprayed.last = (ev.x, ev.y)
        d.markAll()
        wakeIn(40)
      if ev.released or not ui.mouseDown:
        symSprayed.on = false
        if d.stepOpen: d.endStep()
      return true
  of 44 .. 52:
    # the Graph tools: a box dragged, the chart's numbers asked for
    if ev.pressed and ev.over:
      graphDrag = (true, ev.x, ev.y, ev.x, ev.y)
      return true
    if graphDrag.on:
      graphDrag.x1 = ev.x
      graphDrag.y1 = ev.y
      if ev.released or not ui.mouseDown:
        graphDrag.on = false
        startInfographic(false)
        if igDlg.open:
          igDlg.chart.kind = case m
                             of 44: ckColumn
                             of 45: ckStackedColumn
                             of 46: ckBar
                             of 47: ckStackedBar
                             of 48: ckLine
                             of 49: ckArea
                             of 50: ckScatter
                             of 51: ckPie
                             else: ckRadar
          let x0 = min(graphDrag.x0, graphDrag.x1)
          let y0 = min(graphDrag.y0, graphDrag.y1)
          let w = abs(graphDrag.x1 - graphDrag.x0)
          let h = abs(graphDrag.y1 - graphDrag.y0)
          if w >= 20 and h >= 20: igDlg.box = rect(int(x0), int(y0), int(w), int(h))
          else: igDlg.box = rect(int(ev.x), int(ev.y), igDlg.box.w, igDlg.box.h)
          igDlg.key = ""
      return true
  of 53:
    # Print Tiling: where the printed pages' tiles start
    if ev.pressed and ev.over:
      tileOrigin[cast[pointer](d)] = (ev.x, ev.y)
      status = tr("Print Tiling: the pages start here (File > Print, Tile)")
      return true
    if ev.down and ui.mouseDown:
      tileOrigin[cast[pointer](d)] = (ev.x, ev.y)
      return true
  of 54:
    if ev.pressed and ev.over:
      shaperPts = @[(ev.x, ev.y)]
      return true
    if shaperPts.len > 0:
      if ev.down and ev.moved and hypot(ev.x - shaperPts[^1][0], ev.y - shaperPts[^1][1]) > 1.5:
        shaperPts.add (ev.x, ev.y)
      if ev.released or not ui.mouseDown: shaperFinish(d)
      return true
  of 55:
    # Page: the page (the canvas) made bigger or smaller by its right and bottom edges
    if ev.pressed and ev.over:
      let nearR = abs(ev.x - d.w.float) * dw.view.scaleOf < dp(12).float
      let nearB = abs(ev.y - d.h.float) * dw.view.scaleOf < dp(12).float
      if nearR or nearB:
        pageDrag = (true, (if nearR and nearB: 3 elif nearR: 1 else: 2), ev.x, ev.y, d.w, d.h)
      else: status = tr("Page: drag the page's right or bottom edge to change its size")
      return true
    if pageDrag.on:
      if ev.released or not ui.mouseDown:
        pageDrag.on = false
        let nw = if pageDrag.edge in {1, 3}: max(1, int(round(ev.x))) else: d.w
        let nh = if pageDrag.edge in {2, 3}: max(1, int(round(ev.y))) else: d.h
        if nw != d.w or nh != d.h:
          d.snapStep("Page Size")
          try: d.canvasSize(nw, nh, 0, 0, 0'u32)
          except ValueError: discard
          d.endStep()
          status = tr("Page: ") & $nw & " x " & $nh
      return true
  of 56:
    # Gradient Feather: dragged across the layer
    if ev.pressed and ev.over and not d.current.background and not d.current.group:
      featherDrag = (true, ev.x, ev.y, ev.x, ev.y, d.current)
      d.beginStep("Gradient Feather")
      d.touchLayers()
      return true
    if featherDrag.on:
      featherDrag.x1 = ev.x
      featherDrag.y1 = ev.y
      let L = featherDrag.layer
      let b = d.objectBox(L)
      if b.ok and hypot(ev.x - featherDrag.x0, ev.y - featherDrag.y0) > 2:
        let ang = arctan2(-(featherDrag.y1 - featherDrag.y0), featherDrag.x1 - featherDrag.x0)
        let ux = cos(ang)
        let uy = -sin(ang)
        var lo = 1e18
        var hi = -1e18
        for (x, y) in [(b.x0, b.y0), (b.x1, b.y0), (b.x1, b.y1), (b.x0, b.y1)]:
          let t = x * ux + y * uy
          lo = min(lo, t)
          hi = max(hi, t)
        let span = max(1.0, hi - lo)
        let s0 = (featherDrag.x0 * ux + featherDrag.y0 * uy - lo) / span
        let s1 = (featherDrag.x1 * ux + featherDrag.y1 * uy - lo) / span
        L.gradFeather = GradientFeather(on: true, angle: radToDeg(ang), startOpacity: 100, endOpacity: 0,
                                        startAt: clamp(int(round(s0 * 100)), 0, 100),
                                        endAt: clamp(int(round(s1 * 100)), 0, 100))
        inc L.ver
        d.markAll()
      if ev.released or not ui.mouseDown:
        featherDrag.on = false
        if d.stepOpen: d.endStep()
      return true
  of 57:
    # Color Theme: the picture's colors round the click, as a theme (Alt+click: the foreground color)
    if ev.pressed and ev.over:
      themeColors = d.colorTheme(int(ev.x), int(ev.y))
      if themeColors.len > 0:
        if ev.alt: fg = themeColors[0]
        else:
          for c in themeColors:
            if c notin swatches: swatches.add c
        status = tr("Color Theme: ") & $themeColors.len & tr(" colors added to the swatches")
      return true
  of 58:
    # Corner: a corner of a shape dragged round
    if ev.pressed and ev.over:
      let L = d.current
      if L != nil and L.isShape:
        let h = L.shape.path.hitPoint(ev.x, ev.y, rad.float * 1.5, handles = false)
        if h.sub >= 0:
          d.beginStep("Corner")
          d.touchLayers()
          cornerDrag = (true, L, L.shape, h.sub, h.i, ev.x, ev.y)
          return true
      status = tr("Corner: drag a corner of the shape picked")
      return true
    if cornerDrag.on:
      if ev.down and ev.moved:
        let r = hypot(ev.x - cornerDrag.x0, ev.y - cornerDrag.y0)
        d.setShape(cornerDrag.layer, roundCorner(cornerDrag.s0, cornerDrag.sub, cornerDrag.i, r))
      if ev.released or not ui.mouseDown:
        cornerDrag.on = false
        if d.stepOpen: d.endStep()
      return true
  of 59:
    # Point Transform: what is picked moved by one of its points onto another point (snapped)
    if ev.pressed and ev.over:
      var idx = d.pickedLayers
      if idx.len == 0: idx = @[d.cur]
      var shapes: seq[(Layer, ShapeData)]
      var from0 = (ev.x, ev.y)
      var best = rad.float * 2
      for i in idx:
        let L = d.layers[i]
        if not L.isShape: continue
        shapes.add (L, L.shape)
        for sp in L.shape.path.subs:
          for q in sp.pts:
            let dd = hypot(q.p[0] - ev.x, q.p[1] - ev.y)
            if dd < best:
              best = dd
              from0 = q.p
      if shapes.len == 0:
        status = tr("Point Transform: pick shapes, then drag one of their points")
        return true
      d.beginStep("Point Transform")
      d.touchLayers()
      ptDrag = (true, from0, shapes, 0.0, 0.0)
      return true
    if ptDrag.on:
      if ev.down and ev.moved:
        # (onto the nearest point of another shape, when one is near)
        var to = (ev.x, ev.y)
        var best = rad.float * 2
        for L in d.layers:
          if not L.isShape or not L.visible or ptDrag.layers.anyIt(it[0] == L): continue
          for sp in L.shape.path.subs:
            for q in sp.pts:
              let dd = hypot(q.p[0] - ev.x, q.p[1] - ev.y)
              if dd < best:
                best = dd
                to = q.p
        let dx = to[0] - ptDrag.from0[0]
        let dy = to[1] - ptDrag.from0[1]
        for (L, s0) in ptDrag.layers:
          var s = s0
          s.path = s0.path.translated(dx, dy)
          d.setShape(L, s)
      if ev.released or not ui.mouseDown:
        ptDrag.on = false
        if d.stepOpen: d.endStep()
      return true
  of 60:
    # Contour: the outline grown or shrunk by the drag
    if ev.pressed and ev.over:
      let L = d.current
      if L == nil or not L.isShape:
        status = tr("Contour: pick a shape, then drag out (bigger) or in (smaller)")
        return true
      d.beginStep("Contour")
      d.touchLayers()
      contourDrag = (true, L, L.shape, ev.x, ev.y, 0.0)
      return true
    if contourDrag.on:
      if ev.down and ev.moved:
        let b = pathBounds(contourDrag.s0.path)
        let cx = (b[0] + b[2]) / 2
        let cy = (b[1] + b[3]) / 2
        let d0 = hypot(contourDrag.x0 - cx, contourDrag.y0 - cy)
        let d1 = hypot(ev.x - cx, ev.y - cy)
        contourDrag.dist = d1 - d0
        status = tr("Contour: ") & $int(round(contourDrag.dist)) & " px"
      if ev.released or not ui.mouseDown:
        contourDrag.on = false
        if abs(contourDrag.dist) >= 0.5:
          var s = contourDrag.s0
          s.path = offsetPath(s.path, d.w, d.h, contourDrag.dist)
          d.setShape(contourDrag.layer, s)
          if d.stepOpen: d.endStep()
        elif d.stepOpen: d.cancelStep()
      return true
  of 61:
    # Vector Crop: a box dragged: the layer shown only in it (its vector mask; again: a new box)
    if ev.pressed and ev.over and not d.current.background:
      cropDrag = (true, ev.x, ev.y, ev.x, ev.y, d.current)
      return true
    if cropDrag.on:
      cropDrag.x1 = ev.x
      cropDrag.y1 = ev.y
      if ev.released or not ui.mouseDown:
        cropDrag.on = false
        let x0 = min(cropDrag.x0, cropDrag.x1)
        let y0 = min(cropDrag.y0, cropDrag.y1)
        let x1 = max(cropDrag.x0, cropDrag.x1)
        let y1 = max(cropDrag.y0, cropDrag.y1)
        if x1 - x0 >= 2 and y1 - y0 >= 2:
          let L = cropDrag.layer
          d.beginStep("Vector Crop")
          d.touchLayers()
          if L.mask == nil and L.adjust.kind.len == 0: d.addLayerMask(mfRevealAll, d.layers.find(L))
          let mp = if L.adjust.kind.len > 0: addr L.pxRaw elif L.mask != nil: addr L.mask.pxRaw else: nil
          if mp != nil and mp[].len == d.w * d.h:
            for y in 0 ..< d.h:
              for x in 0 ..< d.w:
                let inside = float(x) + 0.5 >= x0 and float(x) + 0.5 <= x1 and float(y) + 0.5 >= y0 and float(y) + 0.5 <= y1
                mp[][y * d.w + x] = grayPx(if inside: 255 else: 0)
            if L.mask != nil: inc L.mask.ver
            inc L.ver
          d.markAll()
          d.endStep()
          status = tr("Vector Crop: the layer shown in the box only -- its pixels kept (Layer Mask > Delete shows them all)")
      return true
  of 62, 63:
    # Transparency: the layer fading along the drag (its mask a gradient); Fill: the shape's fill a
    # gradient along it
    if ev.pressed and ev.over and not d.current.background:
      gradDrag = (true, ev.x, ev.y, ev.x, ev.y, d.current, (if d.current.isShape: d.current.shape else: ShapeData()))
      d.beginStep(if m == 62: "Transparency Tool" else: "Fill Tool")
      d.touchLayers()
      return true
    if gradDrag.on:
      gradDrag.x1 = ev.x
      gradDrag.y1 = ev.y
      let L = gradDrag.layer
      let len = hypot(gradDrag.x1 - gradDrag.x0, gradDrag.y1 - gradDrag.y0)
      if len > 2:
        if m == 62:
          if L.mask == nil and L.adjust.kind.len == 0: d.addLayerMask(mfRevealAll, d.layers.find(L))
          let mpx = if L.adjust.kind.len > 0: addr L.pxRaw else: (if L.mask != nil: addr L.mask.pxRaw else: nil)
          if mpx != nil and mpx[].len == d.w * d.h:
            let ux = (gradDrag.x1 - gradDrag.x0) / len
            let uy = (gradDrag.y1 - gradDrag.y0) / len
            for y in 0 ..< d.h:
              for x in 0 ..< d.w:
                let t = clamp(((float(x) - gradDrag.x0) * ux + (float(y) - gradDrag.y0) * uy) / len, 0, 1)
                mpx[][y * d.w + x] = grayPx(int(round((1 - t) * 255)))
            if L.mask != nil: inc L.mask.ver
            inc L.ver
            d.markAll()
        elif L.isShape:
          var s = gradDrag.s0
          let b = pathBounds(s.path)
          s.fill = ShapePaint(kind: spGradient, color: fg or 0xFF000000'u32, color2: bg or 0xFF000000'u32,
                              angle: int(round(radToDeg(arctan2(-(gradDrag.y1 - gradDrag.y0), gradDrag.x1 - gradDrag.x0)))),
                              scale: clamp(int(round(len / max(1.0, max(b[2] - b[0], b[3] - b[1])) * 100)), 10, 1000))
          d.setShape(L, s)
      if ev.released or not ui.mouseDown:
        gradDrag.on = false
        if d.stepOpen: d.endStep()
      return true
  of 64:
    # Area: corners clicked, a double-click (or a click on the first) ends -- its area and perimeter
    if ev.pressed and ev.over:
      if areaPts.len >= 3 and (ev.clicks == 2 or hypot(ev.x - areaPts[0][0], ev.y - areaPts[0][1]) * dw.view.scaleOf < 8):
        var a, per = 0.0
        for i in 0 ..< areaPts.len:
          let p = areaPts[i]
          let q = areaPts[(i + 1) mod areaPts.len]
          a += p[0] * q[1] - q[0] * p[1]
          per += hypot(q[0] - p[0], q[1] - p[1])
        a = abs(a) / 2
        logMeasurement(d, "Area", a, per, areaPts.len)
        status = tr("Area: ") & areaText(d, a) & "   " & tr("Perimeter: ") & lengthText(d, per)
        areaPts = @[]
      else:
        areaPts.add (ev.x, ev.y)
      return true
  of 65:
    # Mesh Warp: the mesh's points dragged; Enter puts it down
    if not meshW.on or meshW.layer != d.current:
      if ev.pressed and ev.over: d.meshWarpStart()
      return true
    if ev.pressed and ev.over:
      var best = rad.float * 2
      meshW.grab = -1
      for k, p in meshW.pts:
        let dd = hypot(p[0] - ev.x, p[1] - ev.y)
        if dd < best:
          best = dd
          meshW.grab = k
      return true
    if meshW.grab >= 0:
      if ev.down: meshW.pts[meshW.grab] = (ev.x, ev.y)
      if ev.released or not ui.mouseDown: meshW.grab = -1
      return true
  of 66:
    # Deform: joints clicked in a chain (the bones), then one dragged: the layer bends with it
    if ev.pressed and ev.over:
      if bones.layer != d.current:
        bones = (d.current, newSeq[(float, float)](), newSeq[(float, float)](), -1)
      var best = rad.float * 2
      bones.grab = -1
      for k, p in bones.joints:
        let dd = hypot(p[0] - ev.x, p[1] - ev.y)
        if dd < best:
          best = dd
          bones.grab = k
      if bones.grab < 0:
        bones.joints.add (ev.x, ev.y)
        bones.rest.add (ev.x, ev.y)
        status = tr("Deform: ") & $bones.joints.len & tr(" joints -- drag one to bend the layer; Enter puts it down")
      return true
    if bones.grab >= 0:
      if ev.down and ev.moved:
        # (the joint turns the bones after it round the one before: a chain, as an arm)
        let k = bones.grab
        if k > 0:
          let pv = bones.joints[k - 1]
          let a0 = arctan2(bones.joints[k][1] - pv[1], bones.joints[k][0] - pv[0])
          let a1 = arctan2(ev.y - pv[1], ev.x - pv[0])
          let da = a1 - a0
          for j in k ..< bones.joints.len:
            let ox = bones.joints[j][0] - pv[0]
            let oy = bones.joints[j][1] - pv[1]
            bones.joints[j] = (pv[0] + ox * cos(da) - oy * sin(da), pv[1] + ox * sin(da) + oy * cos(da))
        else:
          let dx = ev.x - bones.joints[0][0]
          let dy = ev.y - bones.joints[0][1]
          for j in 0 ..< bones.joints.len: bones.joints[j] = (bones.joints[j][0] + dx, bones.joints[j][1] + dy)
      if ev.released or not ui.mouseDown: bones.grab = -1
      return true
  of 67:
    # Touch Type: a letter of the type layer clicked, then moved (drag), sized (Shift+drag) or
    # turned (Alt+drag) on its own
    if ev.pressed and ev.over:
      let L = d.current
      if L == nil or not L.isText:
        status = tr("Touch Type: pick a type layer, then drag one of its letters")
        return true
      let k = d.charAt(L, ev.x, ev.y)
      if k < 0: return true
      d.beginStep("Touch Type")
      d.touchLayers()
      touch = (true, L, k, (if ev.alt: 2 elif ev.shift: 1 else: 0), ev.x, ev.y, L.text)
      return true
    if touch.on:
      if ev.down and ev.moved:
        let dx = ev.x - touch.x0
        let dy = ev.y - touch.y0
        let mode = touch.mode
        var t = touch.t0
        t.applyToChar(touch.idx, proc (st: var CharStyle) =
          case mode
          of 0:
            st.baselineShift -= float32(dy)
            st.tracking += int(round(dx / max(1.0, st.size.float) * 1000))
          of 1:
            let k = clamp(1 + dx / 100, 0.2, 5.0)
            st.hScale = float32((if st.hScale <= 0: 1.0 else: st.hScale.float) * k)
            st.vScale = float32((if st.vScale <= 0: 1.0 else: st.vScale.float) * k)
          else:
            st.rotation += float32(-dx))
        touch.layer.text = t
        d.drawText(touch.layer)
        d.markAll()
      if ev.released or not ui.mouseDown:
        touch.on = false
        if d.stepOpen: d.endStep()
      return true
  of 68, 70:
    # Area Type: a closed shape clicked becomes the frame text flows in
    if ev.pressed and ev.over:
      let i = d.layerAt(int(ev.x), int(ev.y), rad)
      if i < 0 or not d.layers[i].isShape or d.layers[i].shape.path.subs.len == 0 or
         not d.layers[i].shape.path.subs[0].closed:
        status = tr("Area Type: click a closed shape -- the text flows inside it")
        return true
      d.makeAreaType(d.layers[i], vertical = m == 70)
      return true
  of 69, 71:
    # Type on a Path: a path or a shape's outline clicked, the text runs along it
    if ev.pressed and ev.over:
      let i = d.layerAt(int(ev.x), int(ev.y), rad)
      var path: Path
      if i >= 0 and d.layers[i].isShape: path = d.layers[i].shape.path
      elif d.curPath >= 0 and d.curPath < d.paths.len: path = d.paths[d.curPath]
      if path.subs.len == 0:
        status = tr("Type on a Path: click a path or a shape's outline")
        return true
      d.makePathType(path, (ev.x, ev.y), vertical = m == 71)
      return true
  else: discard
  false

proc moreVectorKeys(d: Doc): bool =
  ## Enter and Esc for the tools that wait for them (Mesh Warp, Deform, the Area tool).
  if vecMode == 65 and meshW.on:
    if keyHit(KeyEnter):
      d.beginStep("Mesh Warp")
      d.meshWarpApply()
      d.endStep()
      meshW.on = false
      return true
    if keyHit(KeyEsc):
      meshW.on = false
      return true
  if vecMode == 66 and bones.joints.len > 0:
    if keyHit(KeyEnter):
      d.beginStep("Deform")
      d.deformApply()
      d.endStep()
      bones = (nil, newSeq[(float, float)](), newSeq[(float, float)](), -1)
      return true
    if keyHit(KeyEsc):
      bones = (nil, newSeq[(float, float)](), newSeq[(float, float)](), -1)
      return true
  if vecMode == 64 and areaPts.len > 0 and keyHit(KeyEsc):
    areaPts = @[]
    return true
  false

proc moreVectorOverlay(dw: DocWin; ev: PhotoEvent) =
  ## What these tools show over the image: the reference point, the brush, the mesh, the bones...
  let d = dw.doc
  let v = dw.view
  let m = vecMode
  template scr(x, y: float): (int, int) = v.toScreen(d, x, y)
  case m
  of 19 .. 22:
    let tb = d.targetBox
    if tb.ok:
      let pv = if tt.pivotFor == d.current: tt.pivot else: ((tb.x0 + tb.x1) / 2, (tb.y0 + tb.y1) / 2)
      let (sx, sy) = scr(pv[0], pv[1])
      ring(sx.float, sy.float, dp(5).float, 2, color(0, 120, 255))
      line(sx - dp(8), sy, sx + dp(8), sy, color(0, 120, 255))
      line(sx, sy - dp(8), sx, sy + dp(8), color(0, 120, 255))
  of 26 .. 32, 37 .. 43:
    if ev.over:
      let size = if m >= 37: symSize else: liqSize
      let (sx, sy) = scr(ev.x, ev.y)
      ring(sx.float, sy.float, size.float / 2 * v.scaleOf / pxScale.float, 1, color(0, 120, 255))
  of 44 .. 52, 61:
    let (on, x0, y0, x1, y1) = if m == 61: (cropDrag.on, cropDrag.x0, cropDrag.y0, cropDrag.x1, cropDrag.y1)
                               else: (graphDrag.on, graphDrag.x0, graphDrag.y0, graphDrag.x1, graphDrag.y1)
    if on:
      let (ax, ay) = scr(min(x0, x1), min(y0, y1))
      let (bx, by) = scr(max(x0, x1), max(y0, y1))
      box(rect(ax, ay, max(1, bx - ax), max(1, by - ay)), color(0, 120, 255))
  of 53:
    # (the pages' tiles over the image)
    let o = tileOrigin.getOrDefault(cast[pointer](d), (0.0, 0.0))
    let pw = d.dpi * 8.27
    let ph = d.dpi * 11.69
    var y = o[1] - ph * ceil(o[1] / ph)
    while y < d.h.float:
      var x = o[0] - pw * ceil(o[0] / pw)
      while x < d.w.float:
        let (ax, ay) = scr(x, y)
        let (bx, by) = scr(x + pw, y + ph)
        box(rect(ax, ay, max(1, bx - ax), max(1, by - ay)), color(120, 120, 120))
        x += pw
      y += ph
  of 54:
    for k in 1 ..< shaperPts.len:
      let (ax, ay) = scr(shaperPts[k - 1][0], shaperPts[k - 1][1])
      let (bx, by) = scr(shaperPts[k][0], shaperPts[k][1])
      line(ax, ay, bx, by, color(40, 40, 40))
  of 56, 62, 63:
    let (on, x0, y0, x1, y1) = if m == 56: (featherDrag.on, featherDrag.x0, featherDrag.y0, featherDrag.x1, featherDrag.y1)
                               else: (gradDrag.on, gradDrag.x0, gradDrag.y0, gradDrag.x1, gradDrag.y1)
    if on:
      let (ax, ay) = scr(x0, y0)
      let (bx, by) = scr(x1, y1)
      line(ax, ay, bx, by, color(0, 120, 255))
      disc(ax.float, ay.float, dp(4).float, color(255, 255, 255))
      disc(bx.float, by.float, dp(4).float, color(0, 0, 0))
  of 57:
    if themeColors.len > 0 and ev.over:
      let (sx, sy) = scr(ev.x, ev.y)
      for k, c in themeColors:
        fill(rect(sx + dp(12) + k * dp(14), sy + dp(12), dp(13), dp(13)), colorOf(c))
  of 64:
    for k in 0 ..< areaPts.len:
      let (ax, ay) = scr(areaPts[k][0], areaPts[k][1])
      disc(ax.float, ay.float, dp(3).float, color(0, 120, 255))
      if k > 0:
        let (bx, by) = scr(areaPts[k - 1][0], areaPts[k - 1][1])
        line(ax, ay, bx, by, color(0, 120, 255))
    if areaPts.len > 0 and ev.over:
      let (ax, ay) = scr(areaPts[^1][0], areaPts[^1][1])
      let (bx, by) = scr(ev.x, ev.y)
      line(ax, ay, bx, by, color(0, 120, 255, 120))
  of 65:
    if meshW.on and meshW.layer == d.current:
      let c = meshW.cols + 1
      for k, p in meshW.pts:
        let (ax, ay) = scr(p[0], p[1])
        if k mod c < meshW.cols:
          let (bx, by) = scr(meshW.pts[k + 1][0], meshW.pts[k + 1][1])
          line(ax, ay, bx, by, color(0, 120, 255))
        if k + c < meshW.pts.len:
          let (bx, by) = scr(meshW.pts[k + c][0], meshW.pts[k + c][1])
          line(ax, ay, bx, by, color(0, 120, 255))
        fill(rect(ax - dp(3), ay - dp(3), dp(6), dp(6)), color(255, 255, 255))
        box(rect(ax - dp(3), ay - dp(3), dp(6), dp(6)), color(0, 120, 255))
  of 66:
    for k, p in bones.joints:
      let (ax, ay) = scr(p[0], p[1])
      if k > 0:
        let (bx, by) = scr(bones.joints[k - 1][0], bones.joints[k - 1][1])
        thickLine(ax.float, ay.float, bx.float, by.float, 3, color(230, 120, 20))
      disc(ax.float, ay.float, dp(5).float, color(230, 120, 20))
      ring(ax.float, ay.float, dp(5).float, 1, color(40, 40, 40))
  else: discard

proc moreVectorBar() =
  ## The options of these tools, after the icons of their family.
  case vecMode
  of 19 .. 22:
    if vecMode == 21:
      if checkbox("Scale Strokes && Effects", prefs.scaleStrokes): savePrefs()
    label(tr("Click: the reference point; drag: ") & tr(["rotate", "reflect", "scale", "shear"][vecMode - 19]) &
          tr("; Shift: by 45° (scale: evenly); Alt+click: the numbers"))
  of 23:
    label "Reach:"
    spin(reshapeReach, 4, 2000, w = dp(60))
    label "px"
  of 26 .. 32:
    label "Size:"
    spin(liqSize, 2, 2000, w = dp(60))
    label "Intensity:"
    spin(liqIntensity, 1, 100, w = dp(56))
    label "Detail:"
    spin(liqDetail, 1, 20, w = dp(48))
  of 36 .. 43:
    label "Size:"
    spin(symSize, 4, 2000, w = dp(60))
    label "Intensity:"
    spin(symIntensity, 1, 100, w = dp(56))
    if vecMode == 36:
      label "Density:"
      spin(symDensity, 1, 10, w = dp(48))
  of 60:
    label "Join:"
    combo(["Round", "Mitre", "Bevel"], contourJoin, w = dp(90))
  of 65:
    label "Columns:"
    spin(meshCols, 1, 16, w = dp(48))
    label "Rows:"
    spin(meshRows, 1, 16, w = dp(48))
    if meshW.on and toolButton("Apply", "Put the mesh's warp down (Enter)"):
      let d = cur()
      if d != nil:
        d.beginStep("Mesh Warp")
        d.meshWarpApply()
        d.endStep()
      meshW.on = false
  of 66:
    if toolButton("Apply", "Bend the layer as the bones are (Enter)"):
      let d = cur()
      if d != nil and bones.joints.len > 1:
        d.beginStep("Deform")
        d.deformApply()
        d.endStep()
      bones = (nil, newSeq[(float, float)](), newSeq[(float, float)](), -1)
  else: discard
