# (included by photo.nim) The drawing and layout programs' object and type commands that the others
# here did not have: Compound Path, Add and Remove Anchor Points, Divide Objects Below, Split Into
# Grid, Clean Up, Stray Points, Create Object Mosaic, Create Trim Marks, Flatten Transparency, Make
# Pixel Perfect, Objects on Path, Reverse Spine and Front to Back (the artboards' commands: photo/
# artboards), Outline Object, Soft Mix, Convert Shape, Open and Close
# Path, Step and Repeat, Perceptual and Hatch fills; Change Case, Smart Punctuation, Fit Headline,
# Type on a Path Options, Dynamic Text. Each is one step to undo.

from std/unicode import runes, toUpper, toLower, isAlpha, isWhiteSpace, Rune, runeLen, toUTF8

var
  splitGridDlg: tuple[open: bool; rows, cols: int; gutterX, gutterY: float32]
  mosaicDlg: tuple[open: bool; cols, rows: int; gap: float32]
  cleanDlg: tuple[open: bool; stray, unpainted, emptyText: bool] = (false, true, true, true)
  stepDlg: tuple[open: bool; count: int; dx, dy: float32; grid: bool; rows, cols: int] =
    (false, 3, 20, 0, false, 3, 3)
  smartDlg: tuple[open: bool; quotes, dashes, ellipsis, fractions, symbols, spaces, whole: bool] =
    (false, true, true, true, true, true, true, false)
  pathTypeDlg: tuple[open: bool; effect: int; flip: bool]
  hatchDlg: tuple[open: bool; angle, spacing, width: int; cross: bool]= (false, 45, 10, 2, false)
  softMixDlg: tuple[open: bool; mix: int] = (false, 50)

proc pickedShapes(d: Doc): seq[Layer] =
  ## (the shape layers picked, else the current one if it is one; bottom first)
  for i in d.pickedLayers:
    if i >= 0 and i < d.layers.len and d.layers[i].isShape: result.add d.layers[i]
  if result.len == 0 and d.current != nil and d.current.isShape: result.add d.current

proc rectPathF(x0, y0, x1, y1: float): Path =
  var sp = SubPath(closed: true)
  for q in [(x0, y0), (x1, y0), (x1, y1), (x0, y1)]: sp.pts.add PathPoint(p: q, inH: q, outH: q)
  Path(subs: @[sp])

proc splitBezier(a, b: PathPoint): (PathPoint, PathPoint, PathPoint) =
  ## (the curve from `a` to `b` cut in half: `a` and `b` with their handles shortened, the point between)
  template lerp(p, q: (float, float); t: float): (float, float) = (p[0] + (q[0] - p[0]) * t, p[1] + (q[1] - p[1]) * t)
  let p0 = a.p
  let p1 = a.outH
  let p2 = b.inH
  let p3 = b.p
  let q0 = lerp(p0, p1, 0.5)
  let q1 = lerp(p1, p2, 0.5)
  let q2 = lerp(p2, p3, 0.5)
  let r0 = lerp(q0, q1, 0.5)
  let r1 = lerp(q1, q2, 0.5)
  let m = lerp(r0, r1, 0.5)
  var na = a
  na.outH = q0
  var nb = b
  nb.inH = q2
  (na, PathPoint(p: m, inH: r0, outH: r1), nb)

# ---- the commands ----------------------------------------------------------------------------------------------

proc compoundMake(d: Doc) =
  ## Compound Path > Make: the shapes picked made one, where they overlap a hole (as the drawing
  ## program's even-odd): the lowest keeps its paint.
  let ss = d.pickedShapes
  if ss.len < 2:
    status = tr("Compound Path: pick two shapes or more")
    return
  d.beginStep("Make Compound Path")
  d.touchLayers()
  var s = ss[0].shape
  for k in 1 ..< ss.len:
    for sp in ss[k].shape.path.subs:
      var x = sp
      x.op = poExclude
      x.joined = true
      s.path.subs.add x
  d.setShape(ss[0], s)
  for k in countdown(ss.high, 1):
    let i = d.layers.find(ss[k])
    if i >= 0: d.deleteLayer(i)
  d.cur = d.layers.find(ss[0])
  d.endStep()

proc compoundRelease(d: Doc) =
  ## Compound Path > Release: each of its outlines a shape of its own, with its paint.
  let L = d.current
  if L == nil or not L.isShape or L.shape.path.subs.len < 2: return
  d.beginStep("Release Compound Path")
  d.touchLayers()
  let s0 = L.shape
  var first = s0
  first.path.subs = @[s0.path.subs[0]]
  first.path.subs[0].op = poAdd
  d.setShape(L, first)
  var at = d.layers.find(L)
  for k in 1 ..< s0.path.subs.len:
    var s = s0
    var sp = s0.path.subs[k]
    sp.op = poAdd
    sp.joined = false
    s.path.subs = @[sp]
    let M = d.addShapeLayer(s, name = L.name & " " & $(k + 1), above = at)
    at = d.layers.find(M)
  d.endStep()

proc addAnchorPoints(d: Doc) =
  ## Add Anchor Points: a point in the middle of every segment (the shape unchanged).
  let ss = d.pickedShapes
  if ss.len == 0: return
  d.beginStep("Add Anchor Points")
  d.touchLayers()
  for L in ss:
    var s = L.shape
    for sp in s.path.subs.mitems:
      var np: seq[PathPoint]
      let n = sp.pts.len
      let segs = if sp.closed: n else: n - 1
      if n < 2: continue
      var cur = sp.pts[0]
      for i in 0 ..< segs:
        let nx = sp.pts[(i + 1) mod n]
        let (a, m, b) = splitBezier(cur, nx)
        np.add a
        np.add m
        cur = b
        if i == segs - 1:
          if sp.closed: np[0].inH = b.inH
          else: np.add b
      sp.pts = np
    d.setShape(L, s)
  d.endStep()

proc removeAnchorPoints(d: Doc) =
  ## Remove Anchor Points: those the Lasso (Points) picked taken out; none picked, the points that
  ## change the outline least (it made a little simpler).
  let L = d.current
  if L == nil or not L.isShape: return
  d.beginStep("Remove Anchor Points")
  d.touchLayers()
  var s = L.shape
  if vecPts.layer == L and vecPts.pts.len > 0:
    var byIdx = vecPts.pts
    byIdx.sort(proc (a, b: tuple[sub, i: int]): int = cmp(b.i, a.i))
    for (sub, i) in byIdx:
      if sub < s.path.subs.len and i < s.path.subs[sub].pts.len and s.path.subs[sub].pts.len > 2:
        s.path.subs[sub].pts.delete(i)
    vecPts.pts = @[]
  else:
    s.path = simplifyPath(s.path, 1.2)
  d.setShape(L, s)
  d.endStep()

proc divideBelow(d: Doc) =
  ## Divide Objects Below: the shape on top cuts each shape under it that it overlaps into the part
  ## inside it and the part outside; it goes.
  let T = d.current
  if T == nil or not T.isShape:
    status = tr("Divide Objects Below: pick the shape that cuts")
    return
  let ti = d.layers.find(T)
  let tb = pathBounds(T.shape.path)
  d.beginStep("Divide Objects Below")
  d.touchLayers()
  var n = 0
  for i in countdown(ti - 1, 0):
    let S = d.layers[i]
    if not S.isShape or not S.visible or S.locked: continue
    let sb = pathBounds(S.shape.path)
    if sb[2] < tb[0] or sb[0] > tb[2] or sb[3] < tb[1] or sb[1] > tb[3]: continue
    var inside = S.shape
    var outside = S.shape
    for sp in T.shape.path.subs:
      var a = sp
      a.op = poIntersect
      a.joined = true
      inside.path.subs.add a
      var b = sp
      b.op = poSubtract
      b.joined = true
      outside.path.subs.add b
    d.setShape(S, outside)
    discard d.addShapeLayer(inside, name = S.name & " " & tr("(inside)"), above = d.layers.find(S))
    inc n
  let k = d.layers.find(T)
  if k >= 0: d.deleteLayer(k)
  d.endStep()
  status = tr("Divide Objects Below: ") & $n & tr(" shape(s) cut")

proc splitIntoGrid(d: Doc) =
  let L = d.current
  if L == nil: return
  let b = d.objectBox(L)
  if not b.ok: return
  let rows = max(1, splitGridDlg.rows)
  let cols = max(1, splitGridDlg.cols)
  let gx = splitGridDlg.gutterX.float
  let gy = splitGridDlg.gutterY.float
  let cw = (b.x1 - b.x0 - gx * float(cols - 1)) / float(cols)
  let ch = (b.y1 - b.y0 - gy * float(rows - 1)) / float(rows)
  if cw < 1 or ch < 1:
    status = tr("Split Into Grid: the gutters leave no room")
    return
  d.beginStep("Split Into Grid")
  d.touchLayers()
  var s = if L.isShape: L.shape else: ShapeData(fill: solidPaint(fg or 0xFF000000'u32))
  var made: seq[int]
  var at = d.layers.find(L)
  for r in 0 ..< rows:
    for c in 0 ..< cols:
      let x = b.x0 + float(c) * (cw + gx)
      let y = b.y0 + float(r) * (ch + gy)
      s.path = rectPathF(x, y, x + cw, y + ch)
      s.kind = "Rectangle"
      let M = d.addShapeLayer(s, name = "Grid " & $(r + 1) & "," & $(c + 1), above = at)
      at = d.layers.find(M)
      made.add at
  if L.isShape:
    d.deleteLayer(d.layers.find(L))
    for k in made.mitems: dec k
  discard d.groupLayers(made, "Grid")
  d.endStep()

proc cleanUp(d: Doc) =
  ## Clean Up: points standing alone, shapes with no fill or stroke, empty type layers -- gone.
  var gone: seq[int]
  for i in countdown(d.layers.high, 0):
    let L = d.layers[i]
    if L.locked or L.background: continue
    if L.isShape:
      var pts = 0
      for sp in L.shape.path.subs: pts += sp.pts.len
      if cleanDlg.stray and pts <= 1: gone.add i
      elif cleanDlg.unpainted and L.shape.fill.kind == spNone and L.shape.stroke.kind == spNone and
           L.shape.appearance.len == 0 and L.wrap == 0: gone.add i
    elif L.isText and cleanDlg.emptyText and L.text.plainText.strip.len == 0: gone.add i
  if gone.len == 0:
    status = tr("Clean Up: nothing to clean up")
    return
  d.beginStep("Clean Up")
  d.touchLayers()
  for i in gone: d.deleteLayer(i)
  d.endStep()
  status = tr("Clean Up: ") & $gone.len & tr(" taken away")

proc selectStrayPoints(d: Doc) =
  d.clearPicks()
  var n = 0
  for L in d.layers:
    if L.isShape:
      var pts = 0
      for sp in L.shape.path.subs: pts += sp.pts.len
      if pts <= 1:
        L.picked = true
        inc n
  inc d.ver
  status = tr("Stray Points: ") & $n

proc objectMosaic(d: Doc) =
  ## Create Object Mosaic: the layer's picture as a grid of colored rectangles, each the mean of the
  ## pixels under it, in a group.
  let L = d.current
  if L == nil or L.px.len != d.w * d.h or L.isShape or L.isText: return
  let r = d.layerBox(L)
  if r.w < 2 or r.h < 2: return
  let cols = clamp(mosaicDlg.cols, 1, 400)
  let rows = clamp(mosaicDlg.rows, 1, 400)
  let gap = mosaicDlg.gap.float
  d.beginStep("Create Object Mosaic")
  d.touchLayers()
  var made: seq[int]
  var at = d.layers.find(L)
  for j in 0 ..< rows:
    for i in 0 ..< cols:
      let x0 = r.x + r.w * i div cols
      let x1 = r.x + r.w * (i + 1) div cols
      let y0 = r.y + r.h * j div rows
      let y1 = r.y + r.h * (j + 1) div rows
      var acc = [0, 0, 0, 0]
      var n = 0
      for y in y0 ..< y1:
        for x in x0 ..< x1:
          let p = L.px[y * d.w + x]
          acc[0] += aOf(p); acc[1] += rOf(p); acc[2] += gOf(p); acc[3] += bOf(p)
          inc n
      if n == 0 or acc[0] div n < 8: continue
      let c = argb(255, acc[1] div n, acc[2] div n, acc[3] div n)
      let M = d.addShapeLayer(ShapeData(path: rectPathF(float(x0) + gap / 2, float(y0) + gap / 2, float(x1) - gap / 2,
                                                        float(y1) - gap / 2), fill: solidPaint(c), kind: "Rectangle"),
                              name = "Tile", above = at)
      at = d.layers.find(M)
      made.add at
  if made.len > 0: discard d.groupLayers(made, "Mosaic")
  L.visible = false
  d.endStep()
  status = tr("Create Object Mosaic: ") & $made.len & tr(" tiles; the picture hidden")

proc trimMarks(d: Doc) =
  ## Create Trim Marks: the printer's marks at the corners of what is picked, as lines.
  var idx = d.pickedLayers
  if idx.len == 0: idx = @[d.cur]
  var x0, y0 = 1e18
  var x1, y1 = -1e18
  for i in idx:
    let b = d.objectBox(d.layers[i])
    if b.ok:
      x0 = min(x0, b.x0); y0 = min(y0, b.y0); x1 = max(x1, b.x1); y1 = max(y1, b.y1)
  if x1 <= x0: return
  let gap = d.dpi / 72 * 9      # (9 points off the corner)
  let len = d.dpi / 72 * 18
  d.beginStep("Create Trim Marks")
  d.touchLayers()
  var made: seq[int]
  for (x, y, sx, sy) in [(x0, y0, -1.0, -1.0), (x1, y0, 1.0, -1.0), (x1, y1, 1.0, 1.0), (x0, y1, -1.0, 1.0)]:
    for horiz in [true, false]:
      let a = if horiz: (x + sx * gap, y) else: (x, y + sy * gap)
      let b = if horiz: (x + sx * (gap + len), y) else: (x, y + sy * (gap + len))
      let M = d.addShapeLayer(ShapeData(path: Path(subs: @[SubPath(pts: @[PathPoint(p: a, inH: a, outH: a),
                                                                            PathPoint(p: b, inH: b, outH: b)])]),
                                        stroke: solidPaint(0xFF000000'u32), strokeWidth: max(0.5, d.dpi / 72 * 0.25),
                                        fill: ShapePaint(kind: spNone), kind: "Line"), name = "Trim Mark")
      made.add d.layers.find(M)
  discard d.groupLayers(made, "Trim Marks")
  d.endStep()

proc pixelPerfect(d: Doc) =
  ## Make Pixel Perfect: each point and handle on whole pixels (a stroke of an odd width: on
  ## pixels' middles), so straight edges are crisp.
  let ss = d.pickedShapes
  if ss.len == 0: return
  d.beginStep("Make Pixel Perfect")
  d.touchLayers()
  for L in ss:
    var s = L.shape
    let half = s.stroke.kind != spNone and int(round(s.strokeWidth)) mod 2 == 1
    let off = if half: 0.5 else: 0.0
    template snap(q: (float, float)): (float, float) = (round(q[0] - off) + off, round(q[1] - off) + off)
    for sp in s.path.subs.mitems:
      for q in sp.pts.mitems:
        let p0 = q.p
        q.p = snap(q.p)
        let dx = q.p[0] - p0[0]
        let dy = q.p[1] - p0[1]
        q.inH = (q.inH[0] + dx, q.inH[1] + dy)
        q.outH = (q.outH[0] + dx, q.outH[1] + dy)
    if half: s.strokeWidth = float(int(round(s.strokeWidth)))
    d.setShape(L, s)
  d.endStep()

proc objectsOnPath(d: Doc) =
  ## Objects on Path: the objects picked set along the path picked (the topmost shape that is an open
  ## path, else the current path), evenly, in the order they are stacked.
  var idx = d.pickedLayers
  if idx.len < 2:
    status = tr("Objects on Path: pick the objects and a path")
    return
  var spineI = -1
  for i in countdown(idx.high, 0):
    let L = d.layers[idx[i]]
    if L.isShape and L.shape.path.subs.len > 0 and not L.shape.path.subs[0].closed:
      spineI = idx[i]
      break
  if spineI < 0: spineI = idx[^1]
  let spine = d.layers[spineI].shape.path
  let polys = flatten(spine, 24)
  if polys.len == 0 or polys[0].len < 2: return
  let pts = polys[0]
  var acc = @[0.0]
  for i in 1 ..< pts.len:
    let next = acc[^1] + hypot(pts[i][0] - pts[i - 1][0], pts[i][1] - pts[i - 1][1])
    acc.add next
  let total = acc[^1]
  var objs: seq[Layer]
  for i in idx:
    if i != spineI: objs.add d.layers[i]
  d.beginStep("Objects on Path")
  d.touchLayers()
  for k, L in objs:
    let at = if objs.len == 1: total / 2 else: total * float(k) / float(objs.len - 1)
    var seg = 1
    while seg < acc.high and acc[seg] < at: inc seg
    let t = clamp((at - acc[seg - 1]) / max(1e-9, acc[seg] - acc[seg - 1]), 0, 1)
    let px = pts[seg - 1][0] + (pts[seg][0] - pts[seg - 1][0]) * t
    let py = pts[seg - 1][1] + (pts[seg][1] - pts[seg - 1][1]) * t
    let b = d.objectBox(L)
    if not b.ok: continue
    let dx = int(round(px - (b.x0 + b.x1) / 2))
    let dy = int(round(py - (b.y0 + b.y1) / 2))
    if L.isShape:
      var s = L.shape
      s.path = s.path.translated(dx.float, dy.float)
      d.setShape(L, s)
    else: d.shiftLayers(@[L], dx, dy)
  d.endStep()

proc blendGroupMembers(d: Doc): tuple[g: Layer; members: seq[Layer]] =
  ## (the blend the current layer is, or is in: its group and its shapes, bottom first)
  var gi = d.cur
  while gi >= 0 and gi < d.layers.len and not (d.layers[gi].group and "\"blend\"" in d.layers[gi].meta):
    var j = gi + 1
    while j < d.layers.len and d.layers[j].depth >= d.layers[gi].depth: inc j
    if j >= d.layers.len: return
    gi = j
  if gi < 0 or gi >= d.layers.len: return
  result.g = d.layers[gi]
  for j in d.blockStart(gi) ..< gi:
    if d.layers[j].isShape and d.layers[j].depth == result.g.depth + 1: result.members.add d.layers[j]

proc reverseSpine(d: Doc; frontToBack: bool) =
  ## Blend > Reverse Spine: its shapes go the other way along it (each where its opposite was);
  ## Reverse Front to Back: the one at the back comes to the front.
  let (g, ms) = d.blendGroupMembers
  if g == nil or ms.len < 2:
    status = tr("Pick a blend (Object > Blend > Make)")
    return
  d.beginStep(if frontToBack: "Reverse Front to Back" else: "Reverse Spine")
  d.touchLayers()
  if frontToBack:
    var idxs: seq[int]
    for M in ms: idxs.add d.layers.find(M)
    let saved = ms
    for k, i in idxs: d.layers[i] = saved[saved.high - k]
  else:
    var centers: seq[(float, float)]
    for M in ms:
      let b = pathBounds(M.shape.path)
      centers.add ((b[0] + b[2]) / 2, (b[1] + b[3]) / 2)
    for k, M in ms:
      let to = centers[centers.high - k]
      var s = M.shape
      s.path = s.path.translated(to[0] - centers[k][0], to[1] - centers[k][1])
      d.setShape(M, s)
  d.markAll()
  d.endStep()

proc softMix(d: Doc) =
  ## Soft Mix: two shapes overlapping -- where they meet, their colors mixed as see-through inks would
  ## (`softMixDlg.mix` %); each keeps the part that is its own.
  let ss = d.pickedShapes
  if ss.len != 2:
    status = tr("Soft Mix: pick two shapes")
    return
  let A = ss[0]
  let B = ss[1]
  d.beginStep("Soft Mix")
  d.touchLayers()
  var both = A.shape
  var aOnly = A.shape
  var bOnly = B.shape
  for sp in B.shape.path.subs:
    var x = sp
    x.op = poIntersect
    x.joined = true
    both.path.subs.add x
    var y = sp
    y.op = poSubtract
    y.joined = true
    aOnly.path.subs.add y
  for sp in A.shape.path.subs:
    var y = sp
    y.op = poSubtract
    y.joined = true
    bOnly.path.subs.add y
  let ca = if A.shape.fill.kind == spColor: A.shape.fill.color else: 0xFFFFFFFF'u32
  let cb = if B.shape.fill.kind == spColor: B.shape.fill.color else: 0xFFFFFFFF'u32
  # (as inks: what both let through, then toward the top one by so much)
  let ink = argb(255, rOf(ca) * rOf(cb) div 255, gOf(ca) * gOf(cb) div 255, bOf(ca) * bOf(cb) div 255)
  both.fill = solidPaint(mix(ink, cb, 1 - softMixDlg.mix / 100))
  d.setShape(A, aOnly)
  d.setShape(B, bOnly)
  discard d.addShapeLayer(both, name = tr("Soft Mix"), above = d.layers.find(B))
  d.endStep()

proc convertShape(d: Doc; kind: string) =
  ## Object > Convert Shape: the shape picked made another in the same box, keeping its paint.
  let ss = d.pickedShapes
  if ss.len == 0: return
  d.beginStep("Convert Shape")
  d.touchLayers()
  for L in ss:
    var s = L.shape
    let (x0, y0, x1, y1) = pathBounds(s.path)
    let m = min(x1 - x0, y1 - y0)
    case kind
    of "Rectangle":
      s.path = rectPathF(x0, y0, x1, y1)
      s.kind = "Rectangle"
    of "Rounded Rectangle":
      var p = defaultParams(lsRoundRect)
      for k in 0 .. 3: p.v[k] = 20
      s.path = liveShapePath(p, x0, y0, x1, y1)
      s.kind = "Rounded Rectangle"
    of "Beveled Rectangle":
      let c = m * 0.15
      var sp = SubPath(closed: true)
      for q in [(x0 + c, y0), (x1 - c, y0), (x1, y0 + c), (x1, y1 - c), (x1 - c, y1), (x0 + c, y1), (x0, y1 - c),
                (x0, y0 + c)]:
        sp.pts.add PathPoint(p: q, inH: q, outH: q)
      s.path = Path(subs: @[sp])
    of "Inverse Rounded Rectangle":
      let c = m * 0.15
      const k = 0.5523
      var sp = SubPath(closed: true)
      # (each corner a quarter circle cut in)
      for (cx, cy, ax, ay, bx, by) in [(x0, y0, x0, y0 + c, x0 + c, y0), (x1, y0, x1 - c, y0, x1, y0 + c),
                                       (x1, y1, x1, y1 - c, x1 - c, y1), (x0, y1, x0 + c, y1, x0, y1 - c)]:
        let a = (ax, ay)
        let b = (bx, by)
        sp.pts.add PathPoint(p: a, inH: a, outH: (a[0] + (cx + (ax - cx) + (bx - cx) - a[0]) * k * 0.0 + (bx - cx) * k * 0, a[1]))
        sp.pts[^1].outH = (a[0] + (bx - cx) * k, a[1] + (by - cy) * k)
        sp.pts.add PathPoint(p: b, inH: (b[0] + (ax - cx) * k, b[1] + (ay - cy) * k), outH: b)
      s.path = Path(subs: @[sp])
    of "Ellipse":
      var p = defaultParams(lsPolygon)
      p.v[0] = 3
      s.path = Path()
      const k = 0.5523
      let cx = (x0 + x1) / 2
      let cy = (y0 + y1) / 2
      let rx = (x1 - x0) / 2
      let ry = (y1 - y0) / 2
      var sp = SubPath(closed: true)
      for (q, a, b) in [((cx + rx, cy), (0.0, -ry * k), (0.0, ry * k)), ((cx, cy + ry), (rx * k, 0.0), (-rx * k, 0.0)),
                        ((cx - rx, cy), (0.0, ry * k), (0.0, -ry * k)), ((cx, cy - ry), (-rx * k, 0.0), (rx * k, 0.0))]:
        sp.pts.add PathPoint(p: q, inH: (q[0] + a[0], q[1] + a[1]), outH: (q[0] + b[0], q[1] + b[1]))
      s.path.subs.add sp
      s.kind = "Ellipse"
    of "Triangle":
      s.path = liveShapePath(defaultParams(lsTriangle), x0, y0, x1, y1)
    of "Polygon":
      s.path = liveShapePath(defaultParams(lsPolygon), x0, y0, x1, y1)
    of "Line":
      s.path = Path(subs: @[SubPath(pts: @[PathPoint(p: (x0, y0), inH: (x0, y0), outH: (x0, y0)),
                                           PathPoint(p: (x1, y1), inH: (x1, y1), outH: (x1, y1))])])
      if s.stroke.kind == spNone: s.stroke = s.fill
      s.fill = ShapePaint(kind: spNone)
      s.kind = "Line"
    of "Orthogonal Line":
      let horiz = x1 - x0 >= y1 - y0
      let cy = (y0 + y1) / 2
      let cx = (x0 + x1) / 2
      let a = if horiz: (x0, cy) else: (cx, y0)
      let b = if horiz: (x1, cy) else: (cx, y1)
      s.path = Path(subs: @[SubPath(pts: @[PathPoint(p: a, inH: a, outH: a), PathPoint(p: b, inH: b, outH: b)])])
      if s.stroke.kind == spNone: s.stroke = s.fill
      s.fill = ShapePaint(kind: spNone)
      s.kind = "Line"
    else: discard
    d.setShape(L, s)
  d.endStep()

proc openClosePath(d: Doc; close: bool) =
  let ss = d.pickedShapes
  if ss.len == 0: return
  d.beginStep(if close: "Close Path" else: "Open Path")
  d.touchLayers()
  for L in ss:
    var s = L.shape
    for sp in s.path.subs.mitems:
      if close: sp.closed = true
      elif sp.closed and sp.pts.len > 1:
        sp.closed = false
        sp.pts.add sp.pts[0]       # (open where it began: the first point twice, one end each)
    d.setShape(L, s)
  d.endStep()

proc stepAndRepeat(d: Doc) =
  ## Step and Repeat: copies of what is picked, each so far from the last -- or a grid of them.
  var idx = d.pickedLayers
  if idx.len == 0: idx = @[d.cur]
  var srcs: seq[Layer]
  for i in idx:
    if i >= 0 and i < d.layers.len and not d.layers[i].background: srcs.add d.layers[i]
  if srcs.len == 0: return
  d.beginStep("Step and Repeat")
  d.touchLayers()
  var copies: seq[(int, int)]
  if stepDlg.grid:
    for r in 0 ..< max(1, stepDlg.rows):
      for c in 0 ..< max(1, stepDlg.cols):
        if r == 0 and c == 0: continue
        copies.add (c, r)
  else:
    for k in 1 .. max(1, stepDlg.count): copies.add (k, k)
  for (cx, cy) in copies:
    let dx = if stepDlg.grid: int(round(stepDlg.dx * float32(cx))) else: int(round(stepDlg.dx * float32(cx)))
    let dy = if stepDlg.grid: int(round(stepDlg.dy * float32(cy))) else: int(round(stepDlg.dy * float32(cy)))
    for L in srcs:
      let i = d.layers.find(L)
      d.cur = i
      let C = d.duplicateLayer(i)
      if C == nil: continue
      if C.isShape:
        var s = C.shape
        s.path = s.path.translated(dx.float, dy.float)
        d.setShape(C, s)
      elif C.isText:
        var t = C.text
        t.x += float32(dx)
        t.y += float32(dy)
        C.text = t
        d.drawText(C)
      else: d.shiftLayers(@[C], dx, dy)
  d.markAll()
  d.endStep()
  status = tr("Step and Repeat: ") & $(copies.len * srcs.len) & tr(" copies")

proc perceptualGradient(d: Doc) =
  ## Make Gradient Perceptual: the shape's gradient carried through even steps of lightness and
  ## color (Oklab) -- no muddy middle between two bright colors -- by stops put between its own.
  let ss = d.pickedShapes
  if ss.len == 0: return
  proc toLin(c: int): float =
    let v = c / 255
    if v <= 0.04045: v / 12.92 else: pow((v + 0.055) / 1.055, 2.4)
  proc toSrgb(v: float): int =
    let x = clamp(v, 0.0, 1.0)
    int(round((if x <= 0.0031308: x * 12.92 else: 1.055 * pow(x, 1 / 2.4) - 0.055) * 255))
  proc oklab(p: uint32): array[3, float] =
    let r = toLin(rOf(p))
    let g = toLin(gOf(p))
    let b = toLin(bOf(p))
    let l = cbrt(0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b)
    let m = cbrt(0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b)
    let s = cbrt(0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b)
    [0.2104542553 * l + 0.7936177850 * m - 0.0040720468 * s, 1.9779984951 * l - 2.4285922050 * m + 0.4505937099 * s,
     0.0259040371 * l + 0.7827717662 * m - 0.8086757660 * s]
  proc fromOklab(c: array[3, float]; a: int): uint32 =
    let l = (c[0] + 0.3963377774 * c[1] + 0.2158037573 * c[2]) ^ 3
    let m = (c[0] - 0.1055613458 * c[1] - 0.0638541728 * c[2]) ^ 3
    let s = (c[0] - 0.0894841775 * c[1] - 1.2914855480 * c[2]) ^ 3
    argb(a, toSrgb(4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s),
         toSrgb(-1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s),
         toSrgb(-0.0041960863 * l - 0.7034186147 * m + 1.7076147010 * s))
  d.beginStep("Make Gradient Perceptual")
  d.touchLayers()
  for L in ss:
    var s = L.shape
    if s.fill.kind != spGradient: continue
    var stops = s.fill.stops
    if stops.len < 2:
      stops = @[GradientStop(at: 0, color: s.fill.color), GradientStop(at: 1, color: s.fill.color2)]
    var ns: seq[GradientStop]
    for k in 0 ..< stops.len - 1:
      let a = stops[k]
      let b = stops[k + 1]
      let la = oklab(a.color)
      let lb = oklab(b.color)
      ns.add a
      for j in 1 .. 7:
        let t = float(j) / 8
        let c = [la[0] + (lb[0] - la[0]) * t, la[1] + (lb[1] - la[1]) * t, la[2] + (lb[2] - la[2]) * t]
        let al = int(round(float(aOf(a.color)) + float(aOf(b.color) - aOf(a.color)) * t))
        ns.add GradientStop(at: a.at + (b.at - a.at) * t, color: fromOklab(c, al))
    ns.add stops[^1]
    s.fill.stops = ns
    d.setShape(L, s)
  d.endStep()

proc hatchFill(d: Doc) =
  ## Hatch Fill: the shape filled with lines (Affinity's hatch fills) -- so far apart, so thick, at
  ## an angle of 0, 45, 90 or 135°, crossed if you like -- in the foreground color.
  let ss = d.pickedShapes
  if ss.len == 0: return
  let sp = max(2, hatchDlg.spacing)
  let wd = clamp(hatchDlg.width, 1, sp)
  let ang = ((hatchDlg.angle mod 180) + 180) mod 180
  let diag = ang == 45 or ang == 135
  let n = if diag: sp * 2 else: sp
  var tile = newSeq[uint32](n * n)
  let c = fg or 0xFF000000'u32
  for y in 0 ..< n:
    for x in 0 ..< n:
      var on = false
      for a in (if hatchDlg.cross: @[ang, (ang + 90) mod 180] else: @[ang]):
        case a
        of 0: on = on or (y mod sp) < wd
        of 90: on = on or (x mod sp) < wd
        of 45: on = on or ((x + y) mod sp) < wd
        else: on = on or ((x - y + n * 4) mod sp) < wd
      if on: tile[y * n + x] = c
  d.beginStep("Hatch Fill")
  d.touchLayers()
  for L in ss:
    var s = L.shape
    s.fill = ShapePaint(kind: spPattern, pattern: tile, pw: n, ph: n, scale: 100)
    d.setShape(L, s)
  d.endStep()

# ---- type -------------------------------------------------------------------------------------------------------

proc pickedTypes(d: Doc): seq[Layer] =
  for i in d.pickedLayers:
    if i >= 0 and i < d.layers.len and d.layers[i].isText: result.add d.layers[i]
  if result.len == 0 and d.current != nil and d.current.isText: result.add d.current

proc changeCase(d: Doc; how: string) =
  ## Type > Change Case: UPPERCASE, lowercase, Title Case, Sentence case -- the text picked (being
  ## typed: what is selected), its styles kept.
  let ts = d.pickedTypes
  if ts.len == 0: return
  proc conv(s: string; startOfSentence: var bool; startOfWord: var bool): string =
    for r in s.runes:
      var o = r
      case how
      of "UPPERCASE": o = r.toUpper
      of "lowercase": o = r.toLower
      of "Title Case":
        o = if startOfWord: r.toUpper else: r.toLower
      else:
        o = if startOfSentence and r.isAlpha: r.toUpper else: r.toLower
      if r.isAlpha:
        startOfSentence = false
        startOfWord = false
      elif r == Rune('.') or r == Rune('!') or r == Rune('?') or r == Rune('\n'):
        startOfSentence = true
        startOfWord = true
      elif r.isWhiteSpace or r == Rune('-'):
        startOfWord = true
      result.add o.toUTF8
  d.beginStep("Change Case")
  d.touchLayers()
  for L in ts:
    var t = L.text
    var sos = true
    var sow = true
    for sp in t.spans.mitems: sp.text = conv(sp.text, sos, sow)
    L.text = t
    d.drawText(L)
  d.markAll()
  d.endStep()

proc smartPunctuation(d: Doc) =
  ## Type > Smart Punctuation: straight quotes made curly, -- and --- dashes, ... an ellipsis, 1/2 a
  ## fraction, (c) (r) (tm) their signs, two spaces after a full stop one -- in the type picked, or in
  ## every type layer.
  var ts = if smartDlg.whole: d.layers.filterIt(it.isText) else: d.pickedTypes
  if ts.len == 0: return
  proc fix(s: string): string =
    result = s
    if smartDlg.dashes:
      result = result.replace("---", "—").replace("--", "–")
    if smartDlg.ellipsis: result = result.replace("...", "…")
    if smartDlg.fractions:
      for (a, b) in [("1/2", "½"), ("1/4", "¼"), ("3/4", "¾"), ("1/3", "⅓"), ("2/3", "⅔")]:
        result = result.replace(a, b)
    if smartDlg.symbols:
      for (a, b) in [("(c)", "©"), ("(C)", "©"), ("(r)", "®"), ("(R)", "®"), ("(tm)", "™"),
                     ("(TM)", "™")]:
        result = result.replace(a, b)
    if smartDlg.spaces:
      while ".  " in result: result = result.replace(".  ", ". ")
    if smartDlg.quotes:
      var o = ""
      var prev = ' '
      for ch in result:
        if ch == '"':
          o.add(if prev in {' ', '\n', '\t', '(', '['}: "“" else: "”")
        elif ch == '\'':
          o.add(if prev in {' ', '\n', '\t', '(', '['}: "‘" else: "’")
        else: o.add ch
        prev = ch
      result = o
  d.beginStep("Smart Punctuation")
  d.touchLayers()
  for L in ts:
    var t = L.text
    for sp in t.spans.mitems: sp.text = fix(sp.text)
    L.text = t
    d.drawText(L)
  d.markAll()
  d.endStep()

proc fitHeadline(d: Doc) =
  ## Type > Fit Headline: a line of type in a box spread to the box's width (its tracking).
  let L = d.current
  if L == nil or not L.isText or L.text.boxW <= 0:
    status = tr("Fit Headline: pick a type box with a line of text")
    return
  d.beginStep("Fit Headline")
  d.touchLayers()
  var t = L.text
  for sp in t.spans.mitems: sp.style.tracking = 0
  var lay = layoutText(t)
  let n = max(1, t.plainText.runeLen - 1)
  let w = if lay.lines.len > 0: float(lay.lines[0].x1 - lay.lines[0].x0) else: 0.0
  let size = if t.spans.len > 0: max(1.0, float(t.spans[0].style.size)) else: 12.0
  let extra = (float(t.boxW) - w) / float(n)
  let tr = int(round(extra / size * 1000))
  for sp in t.spans.mitems: sp.style.tracking = clamp(tr, -400, 5000)
  # (a second look: the spaces' share of it as laid out)
  lay = layoutText(t)
  if lay.lines.len > 0:
    let w2 = float(lay.lines[0].x1 - lay.lines[0].x0)
    let adj = int(round((float(t.boxW) - w2) / float(n) / size * 1000))
    for sp in t.spans.mitems: sp.style.tracking = clamp(sp.style.tracking + adj, -400, 5000)
  L.text = t
  d.drawText(L)
  d.markAll()
  d.endStep()

proc dynamicText(d: Doc; how: string) =
  ## Type > Dynamic Text (Photoshop's): the type picked bent into a circle, an arch or a bow in one
  ## go, its size kept to what it had.
  let L = d.current
  if L == nil or not L.isText: return
  d.beginStep("Dynamic Text")
  d.touchLayers()
  var t = L.text
  case how
  of "Circle":
    # (round a circle as long as the line, from its top, clockwise)
    let lay = layoutText(t)
    let w = if lay.lines.len > 0: float(lay.lines[0].x1 - lay.lines[0].x0) else: 100.0
    let r = max(8.0, w / (2 * PI) * 1.08)
    let cx = float(t.x) + w / 2
    let cy = float(t.y) + r
    var pts: seq[(float32, float32)]
    for k in 0 .. 96:
      let a = -PI + float(k) / 96 * 2 * PI
      pts.add (float32(cx + r * cos(a)), float32(cy + r * sin(a)))
    t.path = pts
    t.pathOffset = 0
    t.warp = TextWarp()
  of "Arch":
    t.warp = TextWarp(style: wsArch, bend: 60)
  else:
    t.warp = TextWarp(style: wsBulge, bend: 45)
  L.text = t
  d.drawText(L)
  d.markAll()
  d.endStep()

# ---- the dialogs -------------------------------------------------------------------------------------------------

proc objectDialogs() =
  let d = cur()
  if d == nil: return
  if splitGridDlg.open:
    var go = false
    dialog(splitGridDlg.open, "Split Into Grid", 320):
      row([110, -1]):
        label "Rows:"
        spin(splitGridDlg.rows, 1, 200, w = dp(70))
      row([110, -1]):
        label "Columns:"
        spin(splitGridDlg.cols, 1, 200, w = dp(70))
      row([110, -1]):
        label "Gutter across:"
        discard d.lengthField(splitGridDlg.gutterX, dp(80))
      row([110, -1]):
        label "Gutter down:"
        discard d.lengthField(splitGridDlg.gutterY, dp(80))
      row:
        spring()
        if button("OK", isDefault = true, w = dp(80)): go = true
        if button("Cancel", w = dp(80)): splitGridDlg.open = false
    if go:
      splitGridDlg.open = false
      d.splitIntoGrid()
  if mosaicDlg.open:
    var go = false
    dialog(mosaicDlg.open, "Create Object Mosaic", 320):
      row([110, -1]):
        label "Tiles across:"
        spin(mosaicDlg.cols, 1, 400, w = dp(70))
      row([110, -1]):
        label "Tiles down:"
        spin(mosaicDlg.rows, 1, 400, w = dp(70))
      row([110, -1]):
        label "Spacing:"
        discard d.lengthField(mosaicDlg.gap, dp(80))
      row:
        spring()
        if button("OK", isDefault = true, w = dp(80)): go = true
        if button("Cancel", w = dp(80)): mosaicDlg.open = false
    if go:
      mosaicDlg.open = false
      d.objectMosaic()
  if cleanDlg.open:
    var go = false
    dialog(cleanDlg.open, "Clean Up", 320):
      checkbox("Stray Points", cleanDlg.stray)
      checkbox("Unpainted Objects", cleanDlg.unpainted)
      checkbox("Empty Text Paths", cleanDlg.emptyText)
      row:
        spring()
        if button("OK", isDefault = true, w = dp(80)): go = true
        if button("Cancel", w = dp(80)): cleanDlg.open = false
    if go:
      cleanDlg.open = false
      d.cleanUp()
  if stepDlg.open:
    var go = false
    dialog(stepDlg.open, "Step and Repeat", 340):
      checkbox("Create as a grid", stepDlg.grid)
      if stepDlg.grid:
        row([110, -1]):
          label "Rows:"
          spin(stepDlg.rows, 1, 200, w = dp(70))
        row([110, -1]):
          label "Columns:"
          spin(stepDlg.cols, 1, 200, w = dp(70))
      else:
        row([110, -1]):
          label "Count:"
          spin(stepDlg.count, 1, 500, w = dp(70))
      row([110, -1]):
        label "Offset across:"
        discard d.lengthField(stepDlg.dx, dp(80), lo = -99999)
      row([110, -1]):
        label "Offset down:"
        discard d.lengthField(stepDlg.dy, dp(80), lo = -99999)
      row:
        spring()
        if button("OK", isDefault = true, w = dp(80)): go = true
        if button("Cancel", w = dp(80)): stepDlg.open = false
    if go:
      stepDlg.open = false
      d.stepAndRepeat()
  if smartDlg.open:
    var go = false
    dialog(smartDlg.open, "Smart Punctuation", 340):
      checkbox("Smart Quotes (\" \" ' ')", smartDlg.quotes)
      checkbox("En and Em Dashes (-- ---)", smartDlg.dashes)
      checkbox("Ellipsis (...)", smartDlg.ellipsis)
      checkbox("Expert Fractions (1/2)", smartDlg.fractions)
      checkbox("Symbols ((c) (r) (tm))", smartDlg.symbols)
      checkbox("Space After Period", smartDlg.spaces)
      label("Replace In:", bold = true)
      var k = if smartDlg.whole: 1 else: 0
      if radio("Selected Text Only", k, 0): smartDlg.whole = false
      if radio("Entire Document", k, 1): smartDlg.whole = true
      row:
        spring()
        if button("OK", isDefault = true, w = dp(80)): go = true
        if button("Cancel", w = dp(80)): smartDlg.open = false
    if go:
      smartDlg.open = false
      d.smartPunctuation()
  if pathTypeDlg.open:
    var go = false
    dialog(pathTypeDlg.open, "Type on a Path Options", 320):
      row([90, -1]):
        label "Effect:"
        combo(["Rainbow", "Skew", "3D Ribbon", "Stair Step", "Gravity"], pathTypeDlg.effect, w = dp(140))
      checkbox("Flip", pathTypeDlg.flip)
      row:
        spring()
        if button("OK", isDefault = true, w = dp(80)): go = true
        if button("Cancel", w = dp(80)): pathTypeDlg.open = false
    if go:
      pathTypeDlg.open = false
      let L = d.current
      if L != nil and L.isText and L.text.path.len >= 2:
        d.beginStep("Type on a Path Options")
        d.touchLayers()
        var t = L.text
        t.pathEffect = PathTypeEffect(clamp(pathTypeDlg.effect, 0, ord(PathTypeEffect.high)))
        if pathTypeDlg.flip:
          var rev: seq[(float32, float32)]
          for i in countdown(t.path.high, 0): rev.add t.path[i]
          t.path = rev
        L.text = t
        d.drawText(L)
        d.markAll()
        d.endStep()
  if hatchDlg.open:
    var go = false
    dialog(hatchDlg.open, "Hatch Fill", 320):
      row([110, -1]):
        label "Angle:"
        var k = [0, 45, 90, 135].find(hatchDlg.angle)
        if k < 0: k = 1
        if combo(["0°", "45°", "90°", "135°"], k, w = dp(80)): hatchDlg.angle = [0, 45, 90, 135][k]
      row([110, -1]):
        label "Spacing:"
        spin(hatchDlg.spacing, 2, 200, w = dp(70))
      row([110, -1]):
        label "Line Width:"
        spin(hatchDlg.width, 1, 100, w = dp(70))
      checkbox("Crosshatch", hatchDlg.cross)
      paragraph("In the foreground color.", color = ui.theme.gray)
      row:
        spring()
        if button("OK", isDefault = true, w = dp(80)): go = true
        if button("Cancel", w = dp(80)): hatchDlg.open = false
    if go:
      hatchDlg.open = false
      d.hatchFill()
  if softMixDlg.open:
    var go = false
    dialog(softMixDlg.open, "Soft Mix", 300):
      optSlider("Mixing Rate:", softMixDlg.mix, 0, 100)
      row:
        spring()
        if button("OK", isDefault = true, w = dp(80)): go = true
        if button("Cancel", w = dp(80)): softMixDlg.open = false
    if go:
      softMixDlg.open = false
      d.softMix()

proc objectCommand(name: string): bool =
  ## The commands above (true: done here).
  let d = cur()
  result = true
  if d == nil:
    return name in ["Make Compound Path", "Release Compound Path", "Add Anchor Points", "Remove Anchor Points"]
  if name.startsWith("Convert Shape: "):
    d.convertShape(name["Convert Shape: ".len .. ^1])
    return
  if name.startsWith("Change Case: "):
    d.changeCase(name["Change Case: ".len .. ^1])
    return
  if name.startsWith("Dynamic Text: "):
    d.dynamicText(name["Dynamic Text: ".len .. ^1])
    return
  case name
  of "Make Compound Path": d.compoundMake()
  of "Release Compound Path": d.compoundRelease()
  of "Add Anchor Points": d.addAnchorPoints()
  of "Remove Anchor Points": d.removeAnchorPoints()
  of "Divide Objects Below": d.divideBelow()
  of "Split Into Grid...":
    splitGridDlg.open = true
    if splitGridDlg.rows == 0: splitGridDlg = (true, 2, 2, 10'f32, 10'f32)
  of "Clean Up...": cleanDlg.open = true
  of "Stray Points": d.selectStrayPoints()
  of "Create Object Mosaic...":
    mosaicDlg.open = true
    if mosaicDlg.cols == 0: mosaicDlg = (true, 20, 20, 0'f32)
  of "Create Trim Marks": d.trimMarks()
  of "Make Pixel Perfect": d.pixelPerfect()
  of "Objects on Path": d.objectsOnPath()
  of "Reverse Spine": d.reverseSpine(false)
  of "Reverse Front to Back": d.reverseSpine(true)
  of "Outline Object", "Create Outlines": runCommand("Convert to Shape")
  of "Soft Mix...": softMixDlg.open = true
  of "Open Path": d.openClosePath(false)
  of "Close Path": d.openClosePath(true)
  of "Step and Repeat...": stepDlg.open = true
  of "Make Gradient Perceptual": d.perceptualGradient()
  of "Hatch Fill...": hatchDlg.open = true
  of "Smart Punctuation...": smartDlg.open = true
  of "Fit Headline": d.fitHeadline()
  of "Type on a Path Options...":
    if d.current.isText and d.current.text.path.len >= 2:
      pathTypeDlg = (true, ord(d.current.text.pathEffect), false)
    else: status = tr("Type on a Path Options: pick type on a path")
  else: result = false
