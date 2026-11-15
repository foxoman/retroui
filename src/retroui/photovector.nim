## Illustrator's path tools for shape layers and paths: Merge Shape
## Components (the Pathfinder: what Combine, Subtract, Intersect and
## Exclude make, as plain outlines), Offset Path, Outline Stroke, Simplify,
## Reverse Path Direction, Join, and the Star and Spiral shapes; type made
## shapes (Convert to Shape: `textShapes`) and the shapes between two
## (Make Blend: `blendShapes`).
##
## The outlines are worked out on pixels as big as the image (finer:
## `scale`), then traced and fitted with curves -- smooth, few points.
##
## ```nim
## let L = d.layer                                   # a shape layer
## L.shape.path = mergeComponents(L.shape.path, d.w, d.h)
## let wider = offsetPath(L.shape.path, d.w, d.h, 4)  # 4 pixels out
## let simple = simplifyPath(wider, tolerance = 2)
## ```

import std/[math, algorithm]
import photo, photopaint, photoshapes, textengine

proc tracedPath*(m: seq[uint8]; w, h: int; tolerance = 0.8; scale = 1.0): Path =
  ## The outlines of a mask (`w` x `h`, 128 and over inside) as a path of
  ## curves (fitted within `tolerance` pixels), divided by `scale`.
  if m.len != w * h or w <= 0 or h <= 0: return
  let tmp = Doc(w: w, h: h)
  tmp.sel = m
  # (outlines and holes: the bigger first, holes taken away from what is
  # before them -- an island in a hole, smaller, comes after it)
  var loops: seq[tuple[area: float; sp: SubPath]]
  for loop in tmp.selectionOutlines():
    if loop.len < 3: continue
    var pts = loop
    if scale != 1.0:
      for p in pts.mitems: p = (p[0] / scale, p[1] / scale)
    var area = 0.0
    for i in 0 ..< pts.len:
      let a = pts[i]
      let b = pts[(i + 1) mod pts.len]
      area += a[0] * b[1] - b[0] * a[1]
    var sp = fitPath(pts, tolerance / scale * max(1.0, scale * 0.6), closed = true, cornerAngle = 55)
    sp.closed = true
    if sp.pts.len >= 3: loops.add (area / 2, sp)
  var outerSign = 0.0
  for l in loops:
    if abs(l.area) > abs(outerSign): outerSign = l.area
  loops.sort(proc (a, b: tuple[area: float; sp: SubPath]): int = cmp(abs(b.area), abs(a.area)))
  for l in loops:
    var sp = l.sp
    sp.op = if (l.area > 0) == (outerSign > 0): poAdd else: poSubtract
    result.subs.add sp

proc maskOf(p: Path; w, h: int; scale: float): seq[uint8] =
  var q = p
  if scale != 1.0:
    for sp in q.subs.mitems:
      for pt in sp.pts.mitems:
        pt.p = (pt.p[0] * scale, pt.p[1] * scale)
        pt.inH = (pt.inH[0] * scale, pt.inH[1] * scale)
        pt.outH = (pt.outH[0] * scale, pt.outH[1] * scale)
  shapeMask(q, int(ceil(w.float * scale)), int(ceil(h.float * scale)))

proc fineScale(w, h: int): float =
  ## (finer pixels for a small image: up to 4 times, 24 million at most)
  clamp(sqrt(24e6 / max(1.0, w.float * h.float)), 1.0, 4.0)

proc mergeComponents*(p: Path; w, h: int): Path =
  ## Merge Shape Components: the subpaths, as their operations put them
  ## together (Combine, Subtract Front, Intersect, Exclude), made one set of
  ## plain outlines (holes as holes).
  let k = fineScale(w, h)
  let m = maskOf(p, w, h, k)
  tracedPath(m, int(ceil(w.float * k)), int(ceil(h.float * k)), 0.8, k)

proc offsetPath*(p: Path; w, h: int; dist: float): Path =
  ## Offset Path: the outline moved `dist` pixels out (negative: in), its
  ## corners rounded.
  let k = fineScale(w, h)
  let sw = int(ceil(w.float * k))
  let sh = int(ceil(h.float * k))
  var m = maskOf(p, w, h, k)
  let r = abs(dist) * k
  if r >= 0.5:
    # (the distance to the edge, from a blur wide enough, thresholded: round corners)
    var f = newSeq[float32](sw * sh)
    for i, v in m: f[i] = v.float32 / 255
    let passes = 3
    let br = max(1, int(round(r / sqrt(passes.float))))
    for _ in 0 ..< passes:
      # a box blur, rows then columns
      var t = f
      for y in 0 ..< sh:
        var acc = 0'f32
        for x in -br .. br: acc += f[y * sw + clamp(x, 0, sw - 1)]
        for x in 0 ..< sw:
          t[y * sw + x] = acc / float32(2 * br + 1)
          acc += f[y * sw + min(x + br + 1, sw - 1)] - f[y * sw + max(x - br, 0)]
      for x in 0 ..< sw:
        var acc = 0'f32
        for y in -br .. br: acc += t[clamp(y, 0, sh - 1) * sw + x]
        for y in 0 ..< sh:
          f[y * sw + x] = acc / float32(2 * br + 1)
          acc += t[min(y + br + 1, sh - 1) * sw + x] - t[max(y - br, 0) * sw + x]
    # (out: anything the blur reached; in: only what stayed whole)
    let cut = if dist > 0: 0.04'f32 else: 0.96'f32
    for i in 0 ..< sw * sh: m[i] = if f[i] > cut: 255'u8 else: 0'u8
  tracedPath(m, sw, sh, 0.8, k)

proc outlineStroke*(s: ShapeData; w, h: int): Path =
  ## Outline Stroke: a shape's stroke made a shape of its own -- its
  ## outline, to fill.
  if s.strokeWidth <= 0: return
  let k = fineScale(w, h)
  var t = s
  t.fill = ShapePaint(kind: spNone)
  t.stroke = ShapePaint(kind: spColor, color: 0xFFFFFFFF'u32)
  t.strokeWidth = s.strokeWidth * k
  for sp in t.path.subs.mitems:
    for pt in sp.pts.mitems:
      pt.p = (pt.p[0] * k, pt.p[1] * k)
      pt.inH = (pt.inH[0] * k, pt.inH[1] * k)
      pt.outH = (pt.outH[0] * k, pt.outH[1] * k)
  t.dashes = s.dashes
  let sw = int(ceil(w.float * k))
  let sh = int(ceil(h.float * k))
  var px = newSeq[uint32](sw * sh)
  discard renderShape(t, px, sw, sh)
  var m = newSeq[uint8](sw * sh)
  for i, c in px: m[i] = uint8(c shr 24)
  tracedPath(m, sw, sh, 0.8, k)

proc simplifyPath*(p: Path; tolerance = 2.0): Path =
  ## Simplify: each subpath with fewer points, fitted again with curves
  ## within `tolerance` pixels of where it was.
  result.name = p.name
  for sp in p.subs:
    var pts: seq[(float, float)]
    for poly in Path(subs: @[sp]).flatten(16): pts.add poly
    if pts.len < 2:
      result.subs.add sp
      continue
    var o = fitPath(pts, tolerance, sp.closed)
    o.op = sp.op
    o.joined = sp.joined
    if o.pts.len >= 2: result.subs.add o else: result.subs.add sp

proc reversed*(sp: SubPath): SubPath =
  ## The subpath the other way round (its handles swapped).
  result = sp
  result.pts.setLen(0)
  for i in countdown(sp.pts.high, 0):
    let q = sp.pts[i]
    result.pts.add PathPoint(p: q.p, inH: q.outH, outH: q.inH)

proc reversePath*(p: Path): Path =
  ## Reverse Path Direction: every subpath the other way round.
  result = p
  for sp in result.subs.mitems: sp = sp.reversed

proc joinPaths*(p: Path; tolerance = 6.0): Path =
  ## Join: open subpaths whose ends meet (within `tolerance` pixels) made
  ## one; an open subpath whose own ends meet closed.
  result = p
  var changed = true
  while changed:
    changed = false
    for i in 0 ..< result.subs.len:
      let a = result.subs[i]
      if a.closed or a.pts.len < 2: continue
      if hypot(a.pts[0].p[0] - a.pts[^1].p[0], a.pts[0].p[1] - a.pts[^1].p[1]) <= tolerance and a.pts.len >= 3:
        result.subs[i].closed = true
        if hypot(a.pts[0].p[0] - a.pts[^1].p[0], a.pts[0].p[1] - a.pts[^1].p[1]) < 0.01:
          result.subs[i].pts[0].inH = a.pts[^1].inH
          result.subs[i].pts.setLen(a.pts.len - 1)
        changed = true
        break
      for j in 0 ..< result.subs.len:
        if j == i: continue
        var b = result.subs[j]
        if b.closed or b.pts.len < 1: continue
        let endA = a.pts[^1].p
        var hit = false
        if hypot(endA[0] - b.pts[0].p[0], endA[1] - b.pts[0].p[1]) <= tolerance: hit = true
        elif hypot(endA[0] - b.pts[^1].p[0], endA[1] - b.pts[^1].p[1]) <= tolerance:
          b = b.reversed
          hit = true
        if hit:
          var merged = a
          var first = 0
          if hypot(endA[0] - b.pts[0].p[0], endA[1] - b.pts[0].p[1]) < 0.01:
            merged.pts[^1].outH = b.pts[0].outH
            first = 1
          for k in first ..< b.pts.len: merged.pts.add b.pts[k]
          result.subs[i] = merged
          result.subs.delete(j)
          changed = true
          break
      if changed: break

proc textShapes*(t: TextData; tolerance = 0.2): seq[ShapeData] =
  ## Convert to Shape (Create Outlines): the text as shapes, one a color --
  ## its letters (and underlines) outlines of curves, fitted within
  ## `tolerance` pixels of the letters, placed as they are drawn (on a path,
  ## warped, vertical). Faux bold: a stroke of the same color.
  const k = 4.0   # (fitted four times bigger: small letters keep their shape)
  var colors: seq[(uint32, float32)]
  var shapes: seq[ShapeData]
  for o in textOutlines(t, layoutText(t), fine = true):
    if (o.color shr 24) == 0: continue
    var at = colors.find((o.color, o.embolden))
    if at < 0:
      colors.add (o.color, o.embolden)
      var s = ShapeData(fill: solidPaint(o.color), kind: "Type")
      if o.embolden > 0:
        # (as the type draws it: widened `embolden` to the right, half that up)
        let kx = ceil(o.embolden.float)
        let ky = float(int(kx) div 2)
        s.stroke = solidPaint(o.color)
        s.strokeWidth = (kx + ky) / 2
        s.align = saCenter
        s.join = ljRound
      shapes.add s
      at = shapes.high
    for poly in o.polys:
      if poly.len < 3: continue
      var pts: seq[(float, float)]
      let (dx, dy) = if o.embolden > 0: (ceil(o.embolden.float) / 2, -float(int(ceil(o.embolden)) div 2) / 2)
                     else: (0.0, 0.0)
      for v in poly: pts.add ((v[0].float + dx) * k, (v[1].float + dy) * k)
      var sp = fitPath(pts, tolerance * k, closed = true, cornerAngle = 45)
      if sp.pts.len < 3: continue
      for q in sp.pts.mitems:
        q.p = (q.p[0] / k, q.p[1] / k)
        q.inH = (q.inH[0] / k, q.inH[1] / k)
        q.outH = (q.outH[0] / k, q.outH[1] / k)
      sp.joined = shapes[at].path.subs.len > 0   # (a color's letters filled as one, nonzero)
      shapes[at].path.subs.add sp
  for s in shapes:
    if s.path.subs.len > 0: result.add s

proc resampled(sp: SubPath; n: int): seq[(float, float)] =
  ## (n points evenly along the subpath)
  var pts: seq[(float, float)]
  for poly in Path(subs: @[sp]).flatten(24): pts.add poly
  if pts.len == 0: return
  if sp.closed and pts[^1] != pts[0]: pts.add pts[0]
  var acc = @[0.0]
  for i in 1 ..< pts.len: acc.add acc[^1] + hypot(pts[i][0] - pts[i - 1][0], pts[i][1] - pts[i - 1][1])
  let total = acc[^1]
  if total <= 1e-9:
    for i in 0 ..< n: result.add pts[0]
    return
  var j = 0
  let last = if sp.closed: n else: n - 1
  for i in 0 ..< n:
    let s = total * i.float / max(1, last).float
    while j < acc.high - 1 and acc[j + 1] < s: inc j
    let seg = acc[j + 1] - acc[j]
    let u = if seg > 1e-12: clamp((s - acc[j]) / seg, 0.0, 1.0) else: 0.0
    result.add (pts[j][0] + (pts[j + 1][0] - pts[j][0]) * u, pts[j][1] + (pts[j + 1][1] - pts[j][1]) * u)

proc signedArea(p: seq[(float, float)]): float =
  for i in 0 ..< p.len:
    let a = p[i]
    let b = p[(i + 1) mod p.len]
    result += a[0] * b[1] - b[0] * a[1]

proc mixColor(a, b: uint32; t: float): uint32 =
  for sh in [24, 16, 8, 0]:
    let x = float((a shr sh) and 255)
    let y = float((b shr sh) and 255)
    result = result or (uint32(clamp(round(x + (y - x) * t), 0.0, 255.0)) shl sh)

proc mixPaint(a, b: ShapePaint; t: float): ShapePaint =
  # (a solid color to another mixed; a color from none faded in; anything else the nearer one)
  if a.kind == spColor and b.kind == spColor:
    result = a
    result.color = mixColor(a.color, b.color, t)
    let oa = if a.opacity == 0: 100 else: a.opacity
    let ob = if b.opacity == 0: 100 else: b.opacity
    result.opacity = int(round(oa.float + (ob - oa).float * t))
  elif a.kind == spColor and b.kind == spNone:
    result = a
    result.color = mixColor(a.color, a.color and 0xFFFFFF'u32, t)
  elif a.kind == spNone and b.kind == spColor:
    result = b
    result.color = mixColor(b.color and 0xFFFFFF'u32, b.color, t)
  else: result = if t < 0.5: a else: b

proc colorSteps*(a, b: ShapeData): int =
  ## Smooth Color: as many steps between the two shapes as their colors
  ## need to look smooth (a step a few levels of color), 1 for the same color.
  var most = 0
  for (p, q) in [(a.fill, b.fill), (a.stroke, b.stroke)]:
    if p.kind == spColor and q.kind == spColor:
      for sh in [24, 16, 8, 0]:
        most = max(most, abs(int((p.color shr sh) and 255) - int((q.color shr sh) and 255)))
  clamp(most div 4, 1, 256)

type
  BlendEase* = enum
    ## How a blend's steps are spaced: evenly, bunched toward its start, its
    ## end, or both ends.
    beEven = "Even", beIn = "Ease In", beOut = "Ease Out", beInOut = "Ease In and Out"

proc eased*(t: float; e: BlendEase; strength = 0.5): float =
  ## `t` (0..1) as the ease spaces it; `strength` 0..1 how much.
  let k = 1 + clamp(strength, 0.0, 1.0) * 3
  case e
  of beEven: t
  of beIn: pow(t, k)
  of beOut: 1 - pow(1 - t, k)
  of beInOut: (if t < 0.5: pow(2 * t, k) / 2 else: 1 - pow(2 * (1 - t), k) / 2)

proc blendShapes*(a, b: ShapeData; steps: int; ease = beEven; strength = 0.5; colorEase = beEven;
                  colorStrength = 0.5): seq[ShapeData] =
  ## Make Blend: `steps` shapes between `a` and `b` -- their outlines, fills,
  ## strokes and stroke widths going from the one to the other, in even
  ## steps or eased (`ease`, `strength`: the shapes bunched toward an end);
  ## the colors on their own ease (`colorEase`). Outlines of as many points of the same kinds are mixed point by
  ## point (their curves kept); others are walked along at even distances.
  ## Subpaths are paired in order (one with no partner shrinks to a point).
  let n = clamp(steps, 1, 1000)
  var same = a.path.subs.len == b.path.subs.len
  if same:
    for i in 0 ..< a.path.subs.len:
      if a.path.subs[i].pts.len != b.path.subs[i].pts.len or a.path.subs[i].closed != b.path.subs[i].closed:
        same = false
  var pa, pb: seq[seq[(float, float)]]   # (the walked-along outlines)
  var closed: seq[bool]
  if not same:
    let m = max(a.path.subs.len, b.path.subs.len)
    for i in 0 ..< m:
      let sa = if i < a.path.subs.len: a.path.subs[i] else: SubPath()
      let sb = if i < b.path.subs.len: b.path.subs[i] else: SubPath()
      let c = (if sa.pts.len > 0: sa.closed else: true) and (if sb.pts.len > 0: sb.closed else: true)
      let cnt = clamp(max(sa.pts.len, sb.pts.len) * 12, 64, 512)
      var ra = if sa.pts.len > 0: resampled(sa, cnt) else: @[]
      var rb = if sb.pts.len > 0: resampled(sb, cnt) else: @[]
      # (a missing one: a point at the middle of the other)
      proc middle(r: seq[(float, float)]): (float, float) =
        var sx, sy = 0.0
        for q in r:
          sx += q[0]
          sy += q[1]
        let n = max(1, r.len).float
        (sx / n, sy / n)
      if ra.len == 0:
        let c0 = middle(rb)
        for q in rb: ra.add c0
      if rb.len == 0:
        let c0 = middle(ra)
        for q in ra: rb.add c0
      if ra.len == 0: continue
      if c:
        # (both the same way round, from the points nearest each other)
        if signedArea(ra) * signedArea(rb) < 0: rb.reverse()
        var best = 0
        var bd = Inf
        for off in 0 ..< rb.len:
          var s = 0.0
          for j in countup(0, ra.high, max(1, ra.len div 32)):
            let q = rb[(j + off) mod rb.len]
            s += (ra[j][0] - q[0]) ^ 2 + (ra[j][1] - q[1]) ^ 2
          if s < bd:
            bd = s
            best = off
        if best != 0: rb = rb[best .. ^1] & rb[0 ..< best]
      pa.add ra
      pb.add rb
      closed.add c
  for s in 1 .. n:
    let t = eased(s.float / float(n + 1), ease, strength)
    let tc = eased(s.float / float(n + 1), colorEase, colorStrength)
    var o = if t < 0.5: a else: b
    o.kind = ""
    o.fill = mixPaint(a.fill, b.fill, tc)
    o.stroke = mixPaint(a.stroke, b.stroke, tc)
    o.strokeWidth = a.strokeWidth + (b.strokeWidth - a.strokeWidth) * t
    o.radius = 0
    o.path = Path()
    template lerp(p, q: (float, float)): (float, float) = (p[0] + (q[0] - p[0]) * t, p[1] + (q[1] - p[1]) * t)
    if same:
      for i in 0 ..< a.path.subs.len:
        var sp = a.path.subs[i]
        let q = b.path.subs[i]
        for j in 0 ..< sp.pts.len:
          sp.pts[j].p = lerp(sp.pts[j].p, q.pts[j].p)
          sp.pts[j].inH = lerp(sp.pts[j].inH, q.pts[j].inH)
          sp.pts[j].outH = lerp(sp.pts[j].outH, q.pts[j].outH)
        o.path.subs.add sp
    else:
      for i in 0 ..< pa.len:
        let own = if i < a.path.subs.len: a.path.subs[i] else: b.path.subs[i]
        var sp = SubPath(closed: closed[i], op: own.op, joined: i > 0 and own.joined)
        for j in 0 ..< pa[i].len:
          let p = lerp(pa[i][j], pb[i][j])
          sp.pts.add PathPoint(p: p, inH: p, outH: p)
        o.path.subs.add sp
    result.add o

proc starPath*(x0, y0, x1, y1: float; points = 5; indent = 50; roundness = 0): Path =
  ## The Star tool: `points` points, its inner corners `indent` % in;
  ## `roundness` % rounds them.
  polygonPath(x0, y0, x1, y1, points, star = true, indent = indent, smooth = roundness > 0)

proc spiralPath*(x0, y0, x1, y1: float; turns = 3.0; decay = 80): Path =
  ## The Spiral tool: an open spiral filling the box, `turns` times round,
  ## each turn `decay` % the size of the one outside it.
  let cx = (x0 + x1) / 2
  let cy = (y0 + y1) / 2
  let rx = abs(x1 - x0) / 2
  let ry = abs(y1 - y0) / 2
  let k = clamp(decay, 5, 99).float / 100
  let steps = max(24, int(turns * 24))
  var pts: seq[(float, float)]
  for i in 0 .. steps:
    let t = i.float / 24                     # (turns so far)
    let r = pow(k, t)
    let a = -PI / 2 + t * 2 * PI
    pts.add (cx + cos(a) * rx * r, cy + sin(a) * ry * r)
  var sp = fitPath(pts, 0.4, false)
  sp.closed = false
  result.subs.add sp

# ---- Shape Builder ------------------------------------------------------------------------------------------

proc shapeRegions*(shapes: openArray[ShapeData]; w, h: int): seq[uint64] =
  ## Shape Builder's regions: for each pixel (`w` x `h`) the set of shapes
  ## over it, a bit a shape (the first 64), 0 none -- where shapes overlap a
  ## region of its own.
  result = newSeq[uint64](w * h)
  for i, s in shapes:
    if i >= 64: break
    var fillOnly = s
    fillOnly.stroke = ShapePaint()
    fillOnly.strokeWidth = 0
    fillOnly.fill = solidPaint(0xFF000000'u32)
    var px = newSeq[uint32](w * h)
    discard renderShape(fillOnly, px, w, h)
    let bit = 1'u64 shl i
    for k in 0 ..< px.len:
      if (px[k] shr 24) >= 128: result[k] = result[k] or bit

proc buildShapes*(shapes: openArray[ShapeData]; w, h: int; merge, remove: openArray[(float, float)];
                  tolerance = 0.8): tuple[merged: Path; rest: seq[Path]] =
  ## Shape Builder: the regions under the `merge` points (where the shapes
  ## overlap, each a region) made one shape (`merged`), those under the
  ## `remove` points taken away; each shape what is left of it (`rest`, an
  ## empty path where nothing is). The outlines traced and fitted with
  ## curves within `tolerance` pixels.
  let regions = shapeRegions(shapes, w, h)
  var mk, rk: seq[uint64]
  for (x, y) in merge:
    let xi = int(x)
    let yi = int(y)
    if xi >= 0 and yi >= 0 and xi < w and yi < h and regions[yi * w + xi] != 0 and regions[yi * w + xi] notin mk:
      mk.add regions[yi * w + xi]
  for (x, y) in remove:
    let xi = int(x)
    let yi = int(y)
    if xi >= 0 and yi >= 0 and xi < w and yi < h and regions[yi * w + xi] != 0 and regions[yi * w + xi] notin rk:
      rk.add regions[yi * w + xi]
  var m = newSeq[uint8](w * h)
  for k, r in regions:
    if r != 0 and r in mk: m[k] = 255
  if mk.len > 0: result.merged = tracedPath(m, w, h, tolerance)
  for i in 0 ..< min(64, shapes.len):
    let bit = 1'u64 shl i
    var own = newSeq[uint8](w * h)
    var any = false
    for k, r in regions:
      if (r and bit) != 0 and r notin mk and r notin rk:
        own[k] = 255
        any = true
    result.rest.add(if any: tracedPath(own, w, h, tolerance) else: Path())
