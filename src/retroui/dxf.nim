## DXF drawings (the CAD programs' exchange format, text) opened as vectors: each layer of the
## drawing a shape layer of its outlines in their color and weight -- lines, polylines with
## their bulges (arcs), circles, arcs, ellipses, splines, solids, and blocks put in where they
## are inserted (scaled, turned) --, its text as type layers; the drawing fitted on a page, y
## up as CAD has it made y down.
##
## ```nim
## let d = importDxf(readFile("plan.dxf"), "plan")
## ```
##
## Developed by Sultan Al Isaiee @foxoman -- www.foxoman.net -- sultan@foxoman.net

import std/[strutils, math, tables]
import photo, photoshapes, textengine

type
  DxfError* = object of CatchableError

  Pair = tuple[code: int; value: string]

  DxfPath = object
    pts: seq[(float, float)]       # (a polyline: the curves already in short pieces)
    closed: bool
    filled: bool

  DxfText = object
    x, y, height, angle: float
    text: string

  Mat = array[6, float]            # (a b c d e f: x' = a x + c y + e, y' = b x + d y + f)

  Ent = object
    kind: string
    pairs: seq[Pair]

  Block = object
    baseX, baseY: float
    ents: seq[Ent]

  Drawing = object
    layerColor: Table[string, uint32]
    layerOff: Table[string, bool]
    blocks: Table[string, Block]
    ents: seq[Ent]
    paths: seq[tuple[layer: string; color: uint32; width: float; p: DxfPath]]
    texts: seq[tuple[layer: string; color: uint32; t: DxfText]]

const identity: Mat = [1.0, 0, 0, 1, 0, 0]

proc mul(m: Mat; x, y: float): (float, float) = (m[0] * x + m[2] * y + m[4], m[1] * x + m[3] * y + m[5])

proc compose(a, b: Mat): Mat =
  ## (`b` then `a`)
  [a[0] * b[0] + a[2] * b[1], a[1] * b[0] + a[3] * b[1],
   a[0] * b[2] + a[2] * b[3], a[1] * b[2] + a[3] * b[3],
   a[0] * b[4] + a[2] * b[5] + a[4], a[1] * b[4] + a[3] * b[5] + a[5]]

proc aciColor*(aci: int): uint32 =
  ## A color of the CAD programs' palette (1..255; 7 black, as on a white page).
  case aci
  of 1: 0xFFFF0000'u32
  of 2: 0xFFFFFF00'u32
  of 3: 0xFF00FF00'u32
  of 4: 0xFF00FFFF'u32
  of 5: 0xFF0000FF'u32
  of 6: 0xFFFF00FF'u32
  of 7: 0xFF000000'u32
  of 8: 0xFF808080'u32
  of 9: 0xFFC0C0C0'u32
  of 250 .. 255:
    let g = [51, 80, 105, 130, 190, 255][aci - 250]
    0xFF000000'u32 or (uint32(g) shl 16) or (uint32(g) shl 8) or uint32(g)
  of 10 .. 249:
    # (24 hues 15 degrees apart; each in five shades, full and half saturated)
    let hue = float((aci - 10) div 10) * 15
    let v = (aci - 10) mod 10
    let value = [1.0, 0.8, 0.6, 0.5, 0.3][v div 2]
    let sat = if v mod 2 == 0: 1.0 else: 0.5
    let c = value * sat
    let hp = hue / 60
    let x = c * (1 - abs(hp mod 2 - 1))
    var (r, g, b) = case int(hp)
                    of 0: (c, x, 0.0)
                    of 1: (x, c, 0.0)
                    of 2: (0.0, c, x)
                    of 3: (0.0, x, c)
                    of 4: (x, 0.0, c)
                    else: (c, 0.0, x)
    let m = value - c
    r += m; g += m; b += m
    0xFF000000'u32 or (uint32(round(r * 255)) shl 16) or (uint32(round(g * 255)) shl 8) or uint32(round(b * 255))
  else: 0xFF000000'u32

proc pairsOf(data: string): seq[Pair] =
  var lines = data.splitLines
  var i = 0
  while i + 1 < lines.len:
    let c = lines[i].strip
    if c.len == 0:
      inc i
      continue
    let code = try: parseInt(c) except ValueError: raise newException(DxfError, "not a DXF file (line " & $(i + 1) & ")")
    result.add (code, lines[i + 1].strip(leading = false, trailing = true).strip(leading = true, trailing = false))
    i += 2

proc num(e: Ent; code: int; dflt = 0.0; nth = 0): float =
  var k = 0
  for p in e.pairs:
    if p.code == code:
      if k == nth: return (try: parseFloat(p.value) except ValueError: dflt)
      inc k
  dflt

proc str(e: Ent; code: int; dflt = ""): string =
  for p in e.pairs:
    if p.code == code: return p.value
  dflt

proc has(e: Ent; code: int): bool =
  for p in e.pairs:
    if p.code == code: return true

proc bulgeArc(a, b: (float, float); bulge: float; into: var seq[(float, float)]) =
  ## (a polyline's piece from `a` to `b` bent by its bulge -- the tangent of a quarter of the
  ## arc's angle, to the left when positive --, as short lines; `a` already there)
  if abs(bulge) < 1e-9:
    into.add b
    return
  let theta = 4 * arctan(bulge)
  let dx = b[0] - a[0]
  let dy = b[1] - a[1]
  let chord = hypot(dx, dy)
  if chord < 1e-12:
    into.add b
    return
  let r = chord / (2 * sin(theta / 2))
  # (the centre: from the chord's middle, along its normal)
  let mx = (a[0] + b[0]) / 2
  let my = (a[1] + b[1]) / 2
  let h = r * cos(theta / 2)
  let nx = -dy / chord
  let ny = dx / chord
  let cx = mx + nx * h
  let cy = my + ny * h
  let a0 = arctan2(a[1] - cy, a[0] - cx)
  let n = max(4, int(abs(theta) / (PI / 36)))
  for k in 1 .. n:
    let t = a0 + theta * k.float / n.float
    into.add (cx + abs(r) * cos(t), cy + abs(r) * sin(t))
  into[^1] = b

proc arcPts(cx, cy, rx, ry, rot, a0, a1: float): seq[(float, float)] =
  ## (an arc of an ellipse, counterclockwise from `a0` to `a1` radians, as short lines)
  var e = a1
  while e <= a0: e += 2 * PI
  let n = max(8, int((e - a0) / (PI / 48)))
  let (cr, sr) = (cos(rot), sin(rot))
  for k in 0 .. n:
    let t = a0 + (e - a0) * k.float / n.float
    let x = rx * cos(t)
    let y = ry * sin(t)
    result.add (cx + x * cr - y * sr, cy + x * sr + y * cr)

proc splinePts(e: Ent): seq[(float, float)] =
  ## (a spline: its control points as a B-spline of its degree on its knots, or its fit points)
  let deg = int(e.num(71, 3))
  var ctrl: seq[(float, float)]
  var knots: seq[float]
  var fit: seq[(float, float)]
  var xs, ys, fx, fy: seq[float]
  for p in e.pairs:
    let v = try: parseFloat(p.value) except ValueError: 0.0
    case p.code
    of 10: xs.add v
    of 20: ys.add v
    of 11: fx.add v
    of 21: fy.add v
    of 40: knots.add v
    else: discard
  for i in 0 ..< min(xs.len, ys.len): ctrl.add (xs[i], ys[i])
  for i in 0 ..< min(fx.len, fy.len): fit.add (fx[i], fy[i])
  if ctrl.len < 2: return fit
  let p = clamp(deg, 1, ctrl.len - 1)
  if knots.len != ctrl.len + p + 1:
    # (a clamped, even knot vector when it has none that fits)
    knots.setLen(0)
    for i in 0 .. ctrl.len + p:
      knots.add clamp(float(i - p), 0, float(ctrl.len - p))
  let t0 = knots[p]
  let t1 = knots[ctrl.len]
  let n = max(16, ctrl.len * 12)
  for s in 0 .. n:
    var t = t0 + (t1 - t0) * s.float / n.float
    if s == n: t = t1 - 1e-9
    # (de Boor)
    var k = p
    while k < ctrl.len - 1 and knots[k + 1] <= t: inc k
    var dpts = newSeq[(float, float)](p + 1)
    for j in 0 .. p: dpts[j] = ctrl[clamp(j + k - p, 0, ctrl.high)]
    for r in 1 .. p:
      for j in countdown(p, r):
        let i = j + k - p
        let den = knots[clamp(i + p - r + 1, 0, knots.high)] - knots[clamp(i, 0, knots.high)]
        let a = if abs(den) < 1e-12: 0.0 else: (t - knots[clamp(i, 0, knots.high)]) / den
        dpts[j] = ((1 - a) * dpts[j - 1][0] + a * dpts[j][0], (1 - a) * dpts[j - 1][1] + a * dpts[j][1])
    result.add dpts[p]

proc cleanMText(s: string): string =
  ## (MTEXT's codes taken out: \P a new line, the rest gone)
  result = ""          # (a value at once: see tools/writecheck.py)
  var i = 0
  while i < s.len:
    let c = s[i]
    if c == '\\' and i + 1 < s.len:
      let n = s[i + 1]
      case n
      of 'P', 'X':
        result.add '\n'
        i += 2
      of '\\', '{', '}':
        result.add n
        i += 2
      of 'f', 'F', 'H', 'C', 'c', 'T', 'Q', 'W', 'A', 'p', 'S':
        let e = s.find(';', i)
        i = if e < 0: s.len else: e + 1
      else: i += 2
    elif c in {'{', '}'}: inc i
    else:
      result.add c
      inc i
  result = result.replace("%%c", "⌀").replace("%%d", "°").replace("%%p", "±")

proc colorOf(dr: Drawing; e: Ent; layer: string; byBlock: uint32): uint32 =
  if e.has(420):
    let v = int(e.num(420))
    return 0xFF000000'u32 or uint32(v and 0xFFFFFF)
  let aci = int(e.num(62, 256))
  if aci == 0: return byBlock
  if aci == 256 or aci < 0: return dr.layerColor.getOrDefault(layer, 0xFF000000'u32)
  aciColor(aci)

proc addEnt(dr: var Drawing; e: Ent; m: Mat; inLayer: string; byBlock: uint32; depth: int) =
  let layer0 = e.str(8, "0")
  let layer = if layer0 == "0" and inLayer.len > 0: inLayer else: layer0
  if dr.layerOff.getOrDefault(layer, false): return
  let col = dr.colorOf(e, layer, byBlock)
  let lw = e.num(370, -1)
  let width = if lw > 0: lw / 100 else: 0.0     # (millimetres; 0: as thin as the page allows)
  template path(points: seq[(float, float)]; isClosed: bool; isFilled = false) =
    var tp: seq[(float, float)]
    for q in points: tp.add m.mul(q[0], q[1])
    if tp.len >= 2:
      dr.paths.add (layer, col, width, DxfPath(pts: tp, closed: isClosed, filled: isFilled))
  case e.kind
  of "LINE":
    path(@[(e.num(10), e.num(20)), (e.num(11), e.num(21))], false)
  of "LWPOLYLINE":
    var vs: seq[tuple[x, y, bulge: float]]
    for p in e.pairs:
      let v = try: parseFloat(p.value) except ValueError: 0.0
      case p.code
      of 10: vs.add (v, 0.0, 0.0)
      of 20:
        if vs.len > 0: vs[^1].y = v
      of 42:
        if vs.len > 0: vs[^1].bulge = v
      else: discard
    let closed = (int(e.num(70)) and 1) != 0
    if vs.len >= 2:
      var pts = @[(vs[0].x, vs[0].y)]
      for i in 0 ..< vs.len - (if closed: 0 else: 1):
        let a = vs[i]
        let b = vs[(i + 1) mod vs.len]
        bulgeArc((a.x, a.y), (b.x, b.y), a.bulge, pts)
      path(pts, closed)
  of "POLYLINE":
    # (its VERTEX entities are in its pairs, joined when it was read)
    var vs: seq[tuple[x, y, bulge: float]]
    var inV = false
    for p in e.pairs:
      if p.code == 0:
        inV = p.value == "VERTEX"
        if inV: vs.add (0.0, 0.0, 0.0)
        continue
      if not inV: continue
      let v = try: parseFloat(p.value) except ValueError: 0.0
      case p.code
      of 10: vs[^1].x = v
      of 20: vs[^1].y = v
      of 42: vs[^1].bulge = v
      else: discard
    let closed = (int(e.num(70)) and 1) != 0
    if vs.len >= 2:
      var pts = @[(vs[0].x, vs[0].y)]
      for i in 0 ..< vs.len - (if closed: 0 else: 1):
        let a = vs[i]
        let b = vs[(i + 1) mod vs.len]
        bulgeArc((a.x, a.y), (b.x, b.y), a.bulge, pts)
      path(pts, closed)
  of "CIRCLE":
    let r = e.num(40)
    if r > 0:
      var pts = arcPts(e.num(10), e.num(20), r, r, 0, 0, 2 * PI)
      discard pts.pop
      path(pts, true)
  of "ARC":
    let r = e.num(40)
    if r > 0: path(arcPts(e.num(10), e.num(20), r, r, 0, degToRad(e.num(50)), degToRad(e.num(51))), false)
  of "ELLIPSE":
    let mx = e.num(11)
    let my = e.num(21)
    let rx = hypot(mx, my)
    let ry = rx * e.num(40, 1)
    let s0 = e.num(41, 0)
    var s1 = e.num(42, 2 * PI)
    let whole = abs(s1 - s0 - 2 * PI) < 1e-6 or abs(s1 - s0) < 1e-9
    if whole: s1 = s0 + 2 * PI
    if rx > 0:
      var pts = arcPts(e.num(10), e.num(20), rx, ry, arctan2(my, mx), s0, s1)
      if whole: discard pts.pop
      path(pts, whole)
  of "SPLINE":
    path(splinePts(e), (int(e.num(70)) and 1) != 0)
  of "SOLID", "TRACE", "3DFACE":
    # (corners 1, 2, 4, 3 in that order: the third and fourth crossed, as the format has them)
    var pts = @[(e.num(10), e.num(20)), (e.num(11), e.num(21)), (e.num(13, e.num(12)), e.num(23, e.num(22))),
                (e.num(12), e.num(22))]
    if e.kind == "3DFACE": pts = @[pts[0], pts[1], pts[3], pts[2]]
    path(pts, true, e.kind != "3DFACE")
  of "TEXT", "MTEXT", "ATTRIB":
    var txt = ""
    if e.kind == "MTEXT":
      for p in e.pairs:
        if p.code in [3, 1]: txt.add p.value
      txt = cleanMText(txt)
    else: txt = cleanMText(e.str(1))
    if txt.strip.len > 0:
      let (x, y) = m.mul(e.num(10), e.num(20))
      let k = sqrt(abs(m[0] * m[3] - m[1] * m[2]))
      let ang = e.num(50) + radToDeg(arctan2(m[1], m[0]))
      dr.texts.add (layer, col, DxfText(x: x, y: y, height: e.num(40, 2.5) * k, angle: ang, text: txt))
  of "INSERT", "DIMENSION":
    if depth > 8: return
    let name = e.str(2)
    if name notin dr.blocks: return
    let b = dr.blocks[name]
    let sx = if e.kind == "DIMENSION": 1.0 else: e.num(41, 1)
    let sy = if e.kind == "DIMENSION": 1.0 else: e.num(42, 1)
    let rot = if e.kind == "DIMENSION": 0.0 else: degToRad(e.num(50))
    let ix = if e.kind == "DIMENSION": 0.0 else: e.num(10)
    let iy = if e.kind == "DIMENSION": 0.0 else: e.num(20)
    let (c, s) = (cos(rot), sin(rot))
    # (the block's base point to the insertion point, scaled and turned there)
    let local: Mat = [c * sx, s * sx, -s * sy, c * sy, ix - (c * sx * b.baseX - s * sy * b.baseY),
                      iy - (s * sx * b.baseX + c * sy * b.baseY)]
    let mm = compose(m, local)
    for be in b.ents: dr.addEnt(be, mm, layer, col, depth + 1)
  else: discard

proc readDrawing(data: string): Drawing =
  let ps = pairsOf(data)
  var i = 0
  var section = ""
  var curBlock = ""
  var inBlock = false
  while i < ps.len:
    let p = ps[i]
    if p.code != 0:
      if p.code == 2 and section == "" and i > 0 and ps[i - 1].code == 0 and ps[i - 1].value == "SECTION":
        section = p.value
      inc i
      continue
    case p.value
    of "SECTION":
      section = ""
      inc i
      continue
    of "ENDSEC":
      section = ""
      inc i
      continue
    of "EOF": break
    else: discard
    # (an entity or a table record: its pairs to the next code 0 -- a POLYLINE's to its SEQEND)
    var e = Ent(kind: p.value)
    var j = i + 1
    while j < ps.len:
      if ps[j].code == 0:
        if e.kind == "POLYLINE" and ps[j].value in ["VERTEX"]:
          e.pairs.add ps[j]
          inc j
          continue
        if e.kind == "POLYLINE" and ps[j].value == "SEQEND":
          inc j
          while j < ps.len and ps[j].code != 0: inc j
        break
      e.pairs.add ps[j]
      inc j
    i = j
    case section
    of "TABLES":
      if e.kind == "LAYER":
        let name = e.str(2)
        let c = int(e.num(62, 7))
        result.layerColor[name] = aciColor(abs(c))
        result.layerOff[name] = c < 0 or (int(e.num(70)) and 1) != 0
    of "BLOCKS":
      if e.kind == "BLOCK":
        curBlock = e.str(2)
        inBlock = true
        result.blocks[curBlock] = Block(baseX: e.num(10), baseY: e.num(20))
      elif e.kind == "ENDBLK": inBlock = false
      elif inBlock: result.blocks[curBlock].ents.add e
    of "ENTITIES": result.ents.add e
    else: discard
  for e in result.ents: result.addEnt(e, identity, "", 0xFF000000'u32, 0)

proc importDxf*(data: string; name = "Drawing"; longSide = 2000): Doc =
  ## A DXF drawing as a document: fitted on a page `longSide` pixels at its longest (a margin
  ## round it), a shape layer for each of its layers and colors -- its outlines, the solids
  ## filled -- and its text as type layers. Raises `DxfError` when it is not one or has
  ## nothing drawn.
  var dr = readDrawing(data)
  var x0, y0 = 1e300
  var x1, y1 = -1e300
  for (_, _, _, p) in dr.paths:
    for q in p.pts:
      x0 = min(x0, q[0]); y0 = min(y0, q[1]); x1 = max(x1, q[0]); y1 = max(y1, q[1])
  for (_, _, t) in dr.texts:
    x0 = min(x0, t.x); y0 = min(y0, t.y); x1 = max(x1, t.x + t.height * t.text.len.float * 0.6)
    y1 = max(y1, t.y + t.height)
  if x1 < x0: raise newException(DxfError, "nothing drawn in it")
  let span = max(max(x1 - x0, y1 - y0), 1e-9)
  let margin = 0.05 * longSide.float
  let k = (longSide.float - 2 * margin) / span
  let w = max(16, int(ceil((x1 - x0) * k + 2 * margin)))
  let h = max(16, int(ceil((y1 - y0) * k + 2 * margin)))
  result = newDoc(w, h, 0xFFFFFFFF'u32, 150, name)
  proc place(x, y: float): (float, float) = (margin + (x - x0) * k, margin + (y1 - y) * k)
  # (one shape for each layer, color, weight and fill, in the order first met)
  var order: seq[(string, uint32, float, bool)]
  var groups: Table[(string, uint32, float, bool), Path]
  for (layer, col, width, p) in dr.paths:
    let key = (layer, col, width, p.filled)
    if key notin groups:
      order.add key
      groups[key] = Path()
    var sp = SubPath(closed: p.closed or p.filled)
    for q in p.pts:
      let (x, y) = place(q[0], q[1])
      sp.pts.add PathPoint(p: (x, y), inH: (x, y), outH: (x, y))
    groups[key].subs.add sp
  for key in order:
    let (layer, col, width, filled) = key
    var s = ShapeData(kind: "Path", path: groups[key])
    if filled: s.fill = solidPaint(col)
    else:
      s.stroke = solidPaint(col)
      # (its weight in millimetres at 150 ppi, at least a pixel and a half)
      s.strokeWidth = max(1.5, width * 150 / 25.4)
      s.align = saCenter
      s.cap = lcRound
      s.join = ljRound
    discard result.addShapeLayer(s, layer)
  for (layer, col, t) in dr.texts:
    let (x, y) = place(t.x, t.y)
    let size = max(4.0, t.height * k)
    # (turned type is set straight, where it starts)
    let td = newText(t.text, CharStyle(size: float32(size), color: col, hScale: 1, vScale: 1),
                     float32(x), float32(y))
    let L = result.addTextLayer(td)
    L.name = layer & ": " & t.text.splitLines[0]
  result.cur = result.layers.high
  result.modified = false
