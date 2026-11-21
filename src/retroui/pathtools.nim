## Illustrator's tools that edit paths and pick shapes, for shape layers
## and paths: Scissors (cut at a point), Knife (cut shapes along a line),
## Path Eraser and Smooth (along where the pointer went), Join (two open
## ends), the Eraser and the Blob Brush on filled shapes, the Magic Wand's
## and Group Selection's picking, anchors inside a lasso; the Arc,
## Rectangular Grid, Polar Grid and Flare.
##
## Places along a subpath are numbers: the segment from point `k` to the
## next is `k .. k + 1` (`k + t` part way along it).
##
## ```nim
## let cut = cutAt(L.shape.path, sub = 0, at = 1.5)       # the Scissors
## let rest = erasePath(path, stroke, radius = 6)         # the Path Eraser
## let pieces = knifeCut(L.shape.path, line)              # the Knife: one path a piece
## ```
##
## Developed by Sultan Al Isaiee @foxoman -- www.foxoman.net -- sultan@foxoman.net

import std/[math, algorithm]
import gfx, photo, photopaint, photoshapes, photovector

type Pt = (float, float)

proc lerp(a, b: Pt; t: float): Pt {.inline.} = (a[0] + (b[0] - a[0]) * t, a[1] + (b[1] - a[1]) * t)

proc bez(a, b: PathPoint; t: float): Pt =
  let mt = 1 - t
  (mt * mt * mt * a.p[0] + 3 * mt * mt * t * a.outH[0] + 3 * mt * t * t * b.inH[0] + t * t * t * b.p[0],
   mt * mt * mt * a.p[1] + 3 * mt * mt * t * a.outH[1] + 3 * mt * t * t * b.inH[1] + t * t * t * b.p[1])

proc split(a, b: PathPoint; t: float): tuple[a, m, b: PathPoint] =
  ## (the segment from `a` to `b` cut at `t`, the curve kept)
  let ab = lerp(a.p, a.outH, t)
  let bc = lerp(a.outH, b.inH, t)
  let cd = lerp(b.inH, b.p, t)
  let abc = lerp(ab, bc, t)
  let bcd = lerp(bc, cd, t)
  var a2 = a
  a2.outH = ab
  var b2 = b
  b2.inH = cd
  (a2, PathPoint(p: lerp(abc, bcd, t), inH: abc, outH: bcd), b2)

proc segCount(sp: SubPath): int = (if sp.closed: sp.pts.len else: max(0, sp.pts.len - 1))

proc piece*(sp: SubPath; u0, u1: float): SubPath =
  ## The part of a subpath from place `u0` to `u1` (an open subpath; on a
  ## closed one `u1` may pass its end and go on round).
  let n = sp.pts.len
  if n < 2 or u1 <= u0: return
  template pt(k: int): PathPoint = sp.pts[((k mod n) + n) mod n]
  var k0 = int(floor(u0))
  var t0 = u0 - k0.float
  var k1 = int(floor(u1))
  var t1 = u1 - k1.float
  if t1 < 1e-9 and k1 > k0:
    dec k1
    t1 = 1
  if k0 == k1:
    # (within one segment: cut at the end, then the start)
    let (l, e, _) = split(pt(k0), pt(k0 + 1), t1)
    let (_, s, e2) = split(l, e, if t1 > 1e-12: t0 / t1 else: 0.0)
    var a = s
    a.inH = a.p
    var b = e2
    b.outH = b.p
    return SubPath(pts: @[a, b])
  # the first segment's end of it
  let (_, s0, b0) = split(pt(k0), pt(k0 + 1), t0)
  var first = s0
  first.inH = first.p
  result.pts.add first
  var next = pt(k0 + 1)
  next.inH = b0.inH
  # the whole segments between
  for k in k0 + 1 ..< k1:
    result.pts.add next
    next = pt(k + 1)
  # the last segment's start of it
  let (a1, e1, _) = split(next, pt(k1 + 1), t1)
  result.pts.add a1
  var last = e1
  last.outH = last.p
  result.pts.add last

proc joinTo(a: var SubPath; b: SubPath) =
  ## (`b` goes on from `a`'s end: where they meet one point)
  if b.pts.len == 0: return
  if a.pts.len == 0:
    a = b
    return
  let q = b.pts[0]
  if hypot(a.pts[^1].p[0] - q.p[0], a.pts[^1].p[1] - q.p[1]) < 1e-6:
    a.pts[^1].outH = q.outH
    for i in 1 ..< b.pts.len: a.pts.add b.pts[i]
  else:
    for p in b.pts: a.pts.add p

proc reversed*(sp: SubPath): SubPath =
  ## The subpath the other way round (its handles swapped).
  result = sp
  result.pts.reverse()
  for q in result.pts.mitems: swap(q.inH, q.outH)

# ---- where the pointer went -------------------------------------------------------------------------

proc distToStroke(p: Pt; stroke: seq[Pt]): float =
  ## (how far `p` is from the line through the points of `stroke`)
  result = 1e18
  if stroke.len == 1: return hypot(p[0] - stroke[0][0], p[1] - stroke[0][1])
  for i in 0 ..< stroke.len - 1:
    let a = stroke[i]
    let b = stroke[i + 1]
    let dx = b[0] - a[0]
    let dy = b[1] - a[1]
    let l2 = dx * dx + dy * dy
    let t = if l2 < 1e-12: 0.0 else: clamp(((p[0] - a[0]) * dx + (p[1] - a[1]) * dy) / l2, 0.0, 1.0)
    result = min(result, hypot(p[0] - (a[0] + dx * t), p[1] - (a[1] + dy * t)))

const Samples = 48      ## (places looked at along a segment)

proc touched(sp: SubPath; stroke: seq[Pt]; radius: float): seq[bool] =
  ## (for each place looked at along the subpath -- `Samples` a segment and
  ## its end -- within `radius` of the stroke)
  let n = sp.pts.len
  let segs = segCount(sp)
  result = newSeq[bool](segs * Samples + 1)
  for k in 0 ..< segs:
    for j in 0 .. Samples:
      let q = bez(sp.pts[k], sp.pts[(k + 1) mod n], j / Samples)
      if distToStroke(q, stroke) <= radius: result[k * Samples + j] = true

proc runsOf(flags: seq[bool]; want: bool): seq[(int, int)] =
  ## (the runs of places that are `want`, first and last, both in)
  var i = 0
  while i < flags.len:
    if flags[i] != want:
      inc i
      continue
    let a = i
    while i < flags.len and flags[i] == want: inc i
    result.add (a, i - 1)

proc erasePath*(p: Path; stroke: seq[Pt]; radius: float): Path =
  ## The Path Eraser: what of the path is within `radius` of the pointer's
  ## way (`stroke`) taken out -- a closed subpath opens there, an open one
  ## may become two.
  result.name = p.name
  for sp in p.subs:
    if sp.pts.len < 2 or stroke.len == 0:
      result.subs.add sp
      continue
    let f = touched(sp, stroke, radius)
    var any = false
    for v in f:
      if v: any = true
    if not any:
      result.subs.add sp
      continue
    let s = Samples.float
    if sp.closed:
      # (round from the end of the first gap: what is kept, open)
      var all = f[0 ..< f.len - 1]
      let total = all.len
      var start = -1
      for i in 0 ..< total:
        if all[i] and not all[(i + 1) mod total]:
          start = i
          break
      if start < 0: continue                      # (all of it erased)
      var rot = newSeq[bool](total + 1)
      for i in 0 .. total: rot[i] = all[(start + i) mod total]
      for (a, b) in runsOf(rot, false):
        let u0 = (start + a).float / s
        let u1 = (start + b).float / s
        if u1 - u0 > 0.5 / s:
          var q = piece(sp, u0, u1)
          q.op = sp.op
          result.subs.add q
    else:
      for (a, b) in runsOf(f, false):
        let u0 = a.float / s
        let u1 = b.float / s
        if u1 - u0 > 0.5 / s:
          var q = piece(sp, u0, u1)
          q.op = sp.op
          result.subs.add q

proc smoothPath*(p: Path; stroke: seq[Pt]; radius: float; tolerance = 0.0): Path =
  ## The Smooth tool: the part of each subpath the pointer went along
  ## (within `radius`) fitted again with fewer, smoother curves (within
  ## `tolerance` pixels; 0: a quarter of the radius); the rest as it was.
  result.name = p.name
  let tol = if tolerance > 0: tolerance else: max(1.0, radius / 4)
  for sp in p.subs:
    if sp.pts.len < 3 or stroke.len == 0:
      result.subs.add sp
      continue
    let f = touched(sp, stroke, radius)
    let s = Samples.float
    let runs = runsOf(f, true)
    if runs.len == 0:
      result.subs.add sp
      continue
    # (the first run the pointer covered: the longest)
    var best = runs[0]
    for r in runs:
      if r[1] - r[0] > best[1] - best[0]: best = r
    let segs = segCount(sp)
    var u0 = best[0].float / s
    var u1 = best[1].float / s
    if u1 - u0 < 0.25:
      result.subs.add sp
      continue
    proc refit(q: SubPath; closed: bool): SubPath =
      # (its line evened out first -- each place the mean of those about as far as the radius
      # round it -- then fitted with few curves, only the sharpest turns left corners)
      var pts = block:
        var all: seq[Pt]
        for poly in Path(subs: @[q]).flatten(24): all.add poly
        all
      if pts.len > 4:
        var l = 0.0
        for i in 1 ..< pts.len: l += hypot(pts[i][0] - pts[i - 1][0], pts[i][1] - pts[i - 1][1])
        let win = clamp(int(round(radius / max(0.5, l / pts.len.float) / 2)), 1, pts.len div 3 + 1)
        var even = pts
        for i in 0 ..< pts.len:
          if not closed and (i == 0 or i == pts.high): continue
          var sx, sy = 0.0
          var n = 0
          for j in i - win .. i + win:
            let jj = if closed: ((j mod pts.len) + pts.len) mod pts.len else: clamp(j, 0, pts.high)
            sx += pts[jj][0]
            sy += pts[jj][1]
            inc n
          even[i] = (sx / n.float, sy / n.float)
        pts = even
      result = fitPath(pts, tol, closed, cornerAngle = 160)
    if sp.closed and u0 <= 0.01 and u1 >= segs.float - 0.01:
      var o = refit(sp, true)
      o.closed = true
      o.op = sp.op
      o.joined = sp.joined
      result.subs.add o
      continue
    var mid = refit(piece(sp, u0, u1), false)
    if mid.pts.len < 2:
      result.subs.add sp
      continue
    # (the ends of the new curve where the old one was cut: the rest joins them exactly)
    let a = piece(sp, u0, u0 + 1e-6)
    let b = piece(sp, u1 - 1e-6, u1)
    if a.pts.len > 0: mid.pts[0].p = a.pts[0].p
    if b.pts.len > 0: mid.pts[^1].p = b.pts[^1].p
    var o = SubPath(op: sp.op, joined: sp.joined)
    if sp.closed:
      o = piece(sp, u1, u0 + segs.float)
      o.joinTo(mid)
      # (where they meet at the start: one point)
      if o.pts.len > 2 and hypot(o.pts[0].p[0] - o.pts[^1].p[0], o.pts[0].p[1] - o.pts[^1].p[1]) < 1e-6:
        o.pts[0].inH = o.pts[^1].inH
        o.pts.setLen(o.pts.len - 1)
      o.closed = true
    else:
      if u0 > 1e-6: o = piece(sp, 0, u0)
      o.joinTo(mid)
      if u1 < segs.float - 1e-6: o.joinTo(piece(sp, u1, segs.float))
    o.op = sp.op
    o.joined = sp.joined
    result.subs.add o

proc cutAt*(p: Path; sub: int; at: float): Path =
  ## The Scissors: subpath `sub` cut at place `at` -- a closed one opens
  ## there (both its ends there), an open one becomes two.
  result = p
  if sub < 0 or sub >= p.subs.len: return
  let sp = p.subs[sub]
  let segs = segCount(sp)
  if segs <= 0: return
  let u = clamp(at, 0.0, segs.float)
  if sp.closed:
    var o = piece(sp, u, u + segs.float)
    o.op = sp.op
    result.subs[sub] = o
  else:
    if u <= 1e-6 or u >= segs.float - 1e-6: return
    var a = piece(sp, 0, u)
    var b = piece(sp, u, segs.float)
    a.op = sp.op
    b.op = sp.op
    result.subs[sub] = a
    result.subs.insert(b, sub + 1)

proc nearestPlace*(p: Path; x, y, radius: float): tuple[sub: int; at, dist: float] =
  ## The place on `p` nearest to (`x`, `y`) within `radius` (`sub` -1: none).
  let h = p.nearestSegment(x, y, radius)
  if h.sub < 0: return (-1, 0.0, radius)
  (h.sub, h.i.float + h.t, h.dist)

proc openEnds*(p: Path): seq[tuple[sub: int; atEnd: bool; pt: Pt]] =
  ## The ends of a path's open subpaths.
  for si, sp in p.subs:
    if sp.closed or sp.pts.len == 0: continue
    result.add (si, false, sp.pts[0].p)
    if sp.pts.len > 1: result.add (si, true, sp.pts[^1].p)

proc joinEnds*(a: Path; subA: int; endA: bool; b: Path; subB: int; endB: bool): tuple[path: Path; closed: bool] =
  ## The Join tool: an open end of `a` and one of `b` (the same path, or
  ## another) joined -- the two ends of one subpath close it; ends close
  ## together become one point, else a straight piece joins them. The
  ## path made holds `a`'s subpaths (and, from another path, the one
  ## joined from `b`, taken in).
  result.path = a
  if subA < 0 or subA >= a.subs.len: return
  if subB < 0:
    var sp = a.subs[subA]
    if sp.pts.len >= 2:
      let d = hypot(sp.pts[0].p[0] - sp.pts[^1].p[0], sp.pts[0].p[1] - sp.pts[^1].p[1])
      if d < 1.5:
        sp.pts[0].inH = sp.pts[^1].inH
        sp.pts.setLen(sp.pts.len - 1)
      sp.closed = true
      result.path.subs[subA] = sp
      result.closed = true
    return
  if subB >= b.subs.len: return
  var first = a.subs[subA]
  if not endA: first = reversed(first)          # (the end joined at the end)
  var second = b.subs[subB]
  if endB: second = reversed(second)            # (... and the other from its start)
  let d = hypot(first.pts[^1].p[0] - second.pts[0].p[0], first.pts[^1].p[1] - second.pts[0].p[1])
  if d < 1.5:
    first.pts[^1].outH = second.pts[0].outH
    for i in 1 ..< second.pts.len: first.pts.add second.pts[i]
  else:
    for q in second.pts: first.pts.add q
  result.path.subs[subA] = first

proc anchorsIn*(p: Path; poly: seq[Pt]): seq[tuple[sub, i: int]] =
  ## The points of `p` inside the loop `poly` (the Lasso, picking points).
  if poly.len < 3: return
  for si, sp in p.subs:
    for i, q in sp.pts:
      var inside = false
      let (x, y) = q.p
      for k in 0 ..< poly.len:
        let a = poly[k]
        let b = poly[(k + 1) mod poly.len]
        if (a[1] > y) != (b[1] > y) and x < (b[0] - a[0]) * (y - a[1]) / (b[1] - a[1] + 1e-12) + a[0]:
          inside = not inside
      if inside: result.add (si, i)

# ---- on filled shapes: through their pixels -----------------------------------------------------------

proc boxOf(paths: openArray[Path]; extra: float): Rect =
  var x0 = 1e18
  var y0 = 1e18
  var x1 = -1e18
  var y1 = -1e18
  for p in paths:
    let b = pathBounds(p)
    if b[0] > b[2]: continue
    x0 = min(x0, b[0]); y0 = min(y0, b[1]); x1 = max(x1, b[2]); y1 = max(y1, b[3])
  if x0 > x1: return rect(0, 0, 0, 0)
  rect(int(floor(x0 - extra)), int(floor(y0 - extra)), int(ceil(x1 - x0 + 2 * extra)) + 1,
       int(ceil(y1 - y0 + 2 * extra)) + 1)

proc fineOf(r: Rect): float = clamp(sqrt(8e6 / max(1.0, r.w.float * r.h.float)), 1.0, 4.0)

proc maskIn(p: Path; r: Rect; k: float): seq[uint8] =
  ## (the shape's coverage over `r`, `k` times finer)
  var q = translated(p, -r.x.float, -r.y.float)
  for sp in q.subs.mitems:
    for pt in sp.pts.mitems:
      pt.p = (pt.p[0] * k, pt.p[1] * k)
      pt.inH = (pt.inH[0] * k, pt.inH[1] * k)
      pt.outH = (pt.outH[0] * k, pt.outH[1] * k)
  shapeMask(q, int(ceil(r.w.float * k)), int(ceil(r.h.float * k)))

proc strokeMaskIn(stroke: seq[Pt]; radius: float; r: Rect; k: float): seq[uint8] =
  ## (where a round brush `radius` big went, over `r`, `k` times finer)
  var sp = SubPath()
  for q in stroke:
    let pq = ((q[0] - r.x.float) * k, (q[1] - r.y.float) * k)
    sp.pts.add PathPoint(p: pq, inH: pq, outH: pq)
  let w = int(ceil(r.w.float * k))
  let h = int(ceil(r.h.float * k))
  var px = newSeq[uint32](w * h)
  discard renderShape(ShapeData(path: Path(subs: @[sp]), fill: ShapePaint(kind: spNone),
                                stroke: solidPaint(0xFFFFFFFF'u32), strokeWidth: 2 * radius * k,
                                cap: lcRound, join: ljRound), px, w, h)
  result = newSeq[uint8](w * h)
  for i, c in px: result[i] = uint8(c shr 24)

proc traced(m: seq[uint8]; r: Rect; k: float): Path =
  translated(tracedPath(m, int(ceil(r.w.float * k)), int(ceil(r.h.float * k)), 0.7, k), r.x.float, r.y.float)

proc eraseShape*(p: Path; stroke: seq[Pt]; radius: float): Path =
  ## The Eraser on a filled shape: where a round eraser `radius` big went
  ## taken out of it (its outline traced again).
  let r = boxOf([p], 2)
  if r.w <= 0 or r.h <= 0: return p
  let k = fineOf(r)
  var m = maskIn(p, r, k)
  let e = strokeMaskIn(stroke, radius, r, k)
  for i in 0 ..< m.len: m[i] = uint8(int(m[i]) * (255 - int(e[i])) div 255)
  traced(m, r, k)

proc blobMerge*(p: Path; stroke: seq[Pt]; radius: float): Path =
  ## The Blob Brush: where a round brush `radius` big went, filled, and
  ## made one shape with `p` (an empty path: the stroke alone).
  var sp = SubPath()
  for q in stroke: sp.pts.add PathPoint(p: q, inH: q, outH: q)
  let r = boxOf([p, Path(subs: @[sp])], radius + 2)
  if r.w <= 0 or r.h <= 0: return p
  let k = fineOf(r)
  var m = if p.subs.len > 0: maskIn(p, r, k) else: newSeq[uint8](int(ceil(r.w.float * k)) * int(ceil(r.h.float * k)))
  let e = strokeMaskIn(stroke, radius, r, k)
  for i in 0 ..< m.len: m[i] = max(m[i], e[i])
  traced(m, r, k)

proc knifeCut*(p: Path; line: seq[Pt]): seq[Path] =
  ## The Knife: a filled shape cut along the line drawn across it -- each
  ## piece left a path of its own (biggest first). Not cut through: the
  ## shape as it was, one piece.
  let r = boxOf([p], 2)
  if r.w <= 0 or r.h <= 0 or line.len < 2: return @[p]
  let k = fineOf(r)
  var m = maskIn(p, r, k)
  let cut = strokeMaskIn(line, 0.6 / k + 0.25, r, k)
  for i in 0 ..< m.len:
    if cut[i] > 40: m[i] = 0
  # the pieces: each part that holds together (4 ways)
  let w = int(ceil(r.w.float * k))
  let h = int(ceil(r.h.float * k))
  var label = newSeq[int32](w * h)
  var n = 0
  var stack: seq[int]
  for i0 in 0 ..< w * h:
    if m[i0] < 128 or label[i0] != 0: continue
    inc n
    label[i0] = int32(n)
    stack.add i0
    while stack.len > 0:
      let i = stack.pop()
      let x = i mod w
      let y = i div w
      for (nx, ny) in [(x - 1, y), (x + 1, y), (x, y - 1), (x, y + 1)]:
        if nx < 0 or ny < 0 or nx >= w or ny >= h: continue
        let j = ny * w + nx
        if m[j] >= 128 and label[j] == 0:
          label[j] = int32(n)
          stack.add j
  if n <= 1: return @[p]
  var pieces: seq[(int, Path)]
  for c in 1 .. n:
    var pm = newSeq[uint8](w * h)
    var area = 0
    for i in 0 ..< w * h:
      # (the cut's own pixels go to the piece beside them, half each: no gap is left)
      if label[i] == int32(c):
        pm[i] = 255
        inc area
      elif cut[i] > 40 and m[i] == 0:
        let x = i mod w
        let y = i div w
        var nearIt = false
        for (nx, ny) in [(x - 1, y), (x + 1, y), (x, y - 1), (x, y + 1)]:
          if nx >= 0 and ny >= 0 and nx < w and ny < h and label[ny * w + nx] == int32(c): nearIt = true
        if nearIt: pm[i] = 128
    if area.float / (k * k) < 2: continue          # (a speck)
    pieces.add (area, traced(pm, r, k))
  pieces.sort(proc (a, b: (int, Path)): int = cmp(b[0], a[0]))
  for (_, q) in pieces: result.add q
  if result.len == 0: result = @[p]

# ---- picking shapes ------------------------------------------------------------------------------------

type WandBy* = enum
  ## What the vector Magic Wand compares.
  wbFill = "Fill Color", wbStroke = "Stroke Color", wbWidth = "Stroke Weight", wbOpacity = "Opacity",
  wbMode = "Blending Mode"

proc colorNear(a, b: uint32; tol: int): bool =
  abs(int((a shr 16) and 255) - int((b shr 16) and 255)) <= tol and
    abs(int((a shr 8) and 255) - int((b shr 8) and 255)) <= tol and abs(int(a and 255) - int(b and 255)) <= tol

proc paintNear(a, b: ShapePaint; tol: int): bool =
  if a.kind != b.kind: return false
  case a.kind
  of spNone: true
  of spColor: colorNear(a.color, b.color, tol)
  else: colorNear(a.color, b.color, tol) and colorNear(a.color2, b.color2, tol)

proc similarShapes*(d: Doc; L: Layer; by: set[WandBy] = {wbFill}; tolerance = 32): seq[Layer] =
  ## The vector Magic Wand: the shape layers like `L` in what `by` says
  ## (its fill color within `tolerance` levels, its stroke's, its stroke's
  ## weight within a tenth of `tolerance` pixels, its opacity within
  ## `tolerance` %, its blend mode), `L` among them.
  if L == nil or not L.isShape: return
  for M in d.layers:
    if not M.isShape or not M.visible: continue
    var ok = true
    if wbFill in by and not paintNear(M.shape.fill, L.shape.fill, tolerance): ok = false
    if wbStroke in by and not paintNear(M.shape.stroke, L.shape.stroke, tolerance): ok = false
    if wbWidth in by and abs(M.shape.strokeWidth - L.shape.strokeWidth) > max(0.01, tolerance / 10): ok = false
    if wbOpacity in by and abs(M.opacity - L.opacity) > tolerance * 100 div 255: ok = false
    if wbMode in by and M.mode != L.mode: ok = false
    if ok: result.add M

type SameBy* = enum
  ## What Select > Same compares (`selectSame`).
  sbFillAndStroke = "Fill & Stroke", sbFillColor = "Fill Color", sbStrokeColor = "Stroke Color",
  sbStrokeWeight = "Stroke Weight", sbOpacity = "Opacity", sbBlendMode = "Blending Mode",
  sbAppearance = "Appearance", sbObjectStyle = "Object Style", sbFont = "Font", sbShapeKind = "Shape Kind",
  sbLayerKind = "Kind of Layer"

proc fillOf(L: Layer): ShapePaint =
  ## (what a layer is filled with, as Select > Same sees it: a shape's fill, type's color)
  if L.isShape: return L.shape.fill
  if L.isText and L.text.spans.len > 0:
    return ShapePaint(kind: spColor, color: L.text.spans[0].style.color)
  ShapePaint(kind: spNone)

proc kindOf(L: Layer): int =
  if L.isText: 1
  elif L.isShape: 2
  elif L.smart != nil: 3
  elif L.adjust.kind.len > 0: 4
  else: 0

proc selectSame*(d: Doc; L: Layer; by: SameBy): seq[Layer] =
  ## Select > Same: the layers like `L` in what `by` says -- exactly, not near -- `L` among
  ## them: shapes and type (their color), the font of type, the kind of shape ("Rectangle",
  ## "Ellipse"...), the Object Style; hidden, locked, groups and the Background left out.
  if L == nil or L notin d.layers: return
  for M in d.layers:
    if not M.visible or M.locked or M.group or M.background: continue
    if not d.inIsolation(M): continue
    let ok = case by
      of sbFillAndStroke:
        M.isShape and L.isShape and paintNear(M.shape.fill, L.shape.fill, 0) and
          paintNear(M.shape.stroke, L.shape.stroke, 0) and M.shape.strokeWidth == L.shape.strokeWidth
      of sbFillColor: (M.isShape or M.isText) and paintNear(M.fillOf, L.fillOf, 0)
      of sbStrokeColor:
        M.isShape and L.isShape and paintNear(M.shape.stroke, L.shape.stroke, 0) and
          M.shape.stroke.kind != spNone
      of sbStrokeWeight:
        M.isShape and L.isShape and M.shape.stroke.kind != spNone and L.shape.stroke.kind != spNone and
          abs(M.shape.strokeWidth - L.shape.strokeWidth) < 0.01
      of sbOpacity: M.opacity == L.opacity
      of sbBlendMode: M.mode == L.mode
      of sbAppearance:
        M.kindOf == L.kindOf and M.opacity == L.opacity and M.mode == L.mode and M.fx == L.fx and
          (not M.isShape or (paintNear(M.shape.fill, L.shape.fill, 0) and
                             paintNear(M.shape.stroke, L.shape.stroke, 0) and
                             M.shape.strokeWidth == L.shape.strokeWidth))
      of sbObjectStyle: L.objectStyle.len > 0 and M.objectStyle == L.objectStyle
      of sbFont:
        M.isText and L.isText and M.text.spans.len > 0 and L.text.spans.len > 0 and
          M.text.spans[0].style.family == L.text.spans[0].style.family
      of sbShapeKind: M.isShape and L.isShape and M.shape.kind == L.shape.kind
      of sbLayerKind: M.kindOf == L.kindOf
    if ok: result.add M
  if L notin result and not L.background and not L.group: result.insert(L, 0)

proc groupOfLayer*(d: Doc; L: Layer): seq[Layer] =
  ## Group Selection's second click: the layers of the group `L` is in
  ## (its innermost), or `L` alone when it is in none.
  let i = d.layers.find(L)
  if i < 0: return
  for g in i + 1 .. d.layers.high:
    if d.layers[g].group:
      let s = d.blockStart(g)
      if s <= i:
        for k in s ..< g: result.add d.layers[k]
        return
  @[L]

# ---- Illustrator's shapes: Arc, Rectangular and Polar Grid, Flare -------------------------------------------

proc arcPath*(x0, y0, x1, y1: float; concave = false; closed = false): Path =
  ## The Arc tool: a quarter of an ellipse from (`x0`, `y0`) to (`x1`,
  ## `y1`), bulging out (or in: `concave`); `closed`: with the two sides to
  ## the corner between, a slice.
  let k = 0.5523
  let c = if concave: (x0, y1) else: (x1, y0)
  # (the handles along the box's sides, from each end toward the corner)
  let h0 = lerp((x0, y0), c, k)
  let h1 = lerp((x1, y1), c, k)
  var sp = SubPath(pts: @[PathPoint(p: (x0, y0), inH: (x0, y0), outH: h0),
                          PathPoint(p: (x1, y1), inH: h1, outH: (x1, y1))])
  if closed:
    let other = if concave: (x1, y0) else: (x0, y1)
    sp.pts.add PathPoint(p: other, inH: other, outH: other)
    sp.closed = true
  Path(name: "Arc", subs: @[sp])

proc linePt(a, b: Pt): SubPath =
  SubPath(pts: @[PathPoint(p: a, inH: a, outH: a), PathPoint(p: b, inH: b, outH: b)])

proc rectGridPath*(x0, y0, x1, y1: float; cols, rows: int; frame = true): Path =
  ## The Rectangular Grid tool: `cols` x `rows` cells, their lines open
  ## subpaths, the frame round them a closed one.
  let (a, b) = (min(x0, x1), max(x0, x1))
  let (c, e) = (min(y0, y1), max(y0, y1))
  result.name = "Rectangular Grid"
  if frame: result.subs.add rectPath(a, c, b, e).subs[0]
  let nc = max(1, cols)
  let nr = max(1, rows)
  for i in 1 ..< nc:
    let x = a + (b - a) * i.float / nc.float
    result.subs.add linePt((x, c), (x, e))
  for j in 1 ..< nr:
    let y = c + (e - c) * j.float / nr.float
    result.subs.add linePt((a, y), (b, y))

proc polarGridPath*(x0, y0, x1, y1: float; rings, dividers: int): Path =
  ## The Polar Grid tool: `rings` ellipses one in another (the outer one the
  ## box's) and `dividers` lines from the middle out.
  let (a, b) = (min(x0, x1), max(x0, x1))
  let (c, e) = (min(y0, y1), max(y0, y1))
  let cx = (a + b) / 2
  let cy = (c + e) / 2
  let rx = (b - a) / 2
  let ry = (e - c) / 2
  result.name = "Polar Grid"
  let n = max(1, rings + 1)
  for k in 1 .. n:
    let f = k.float / n.float
    var sp = ellipsePath(cx - rx * f, cy - ry * f, cx + rx * f, cy + ry * f).subs[0]
    sp.op = poAdd
    result.subs.add sp
  for k in 0 ..< max(0, dividers):
    let t = -PI / 2 + 2 * PI * k.float / dividers.float
    result.subs.add linePt((cx, cy), (cx + rx * cos(t), cy + ry * sin(t)))

proc flareShapes*(cx, cy, ex, ey, radius: float; rays = 15; rings = 10; color = 0xFFFFFFFF'u32): seq[ShapeData] =
  ## The Flare tool: a lens flare as shapes -- the glow round its center, a
  ## halo, `rays` rays out from it, and `rings` circles along the line from
  ## (`cx`, `cy`) to (`ex`, `ey`). Each in `color`, see-through.
  let c = color and 0x00FFFFFF'u32
  proc see(a: int): uint32 = c or (uint32(clamp(a, 0, 255)) shl 24)
  # the halo: a radial gradient, clear at its edge
  result.add ShapeData(path: ellipsePath(cx - radius * 2.2, cy - radius * 2.2, cx + radius * 2.2, cy + radius * 2.2),
                       fill: ShapePaint(kind: spGradient, style: 1, stops: @[GradientStop(at: 0, color: see(150)),
                                        GradientStop(at: 0.45, color: see(60)), GradientStop(at: 1, color: see(0))]),
                       stroke: ShapePaint(kind: spNone), kind: "Flare")
  # the rays: thin spikes of different lengths
  var star = SubPath(closed: true)
  let n = max(3, rays)
  for k in 0 ..< n * 2:
    let t = PI * k.float / n.float
    let l = if k mod 2 == 0: radius * (2.5 + 1.8 * abs(sin(k.float * 12.9898) * 0.5 + cos(k.float * 3.7) * 0.5))
            else: radius * 0.18
    let q = (cx + cos(t) * l, cy + sin(t) * l)
    star.pts.add PathPoint(p: q, inH: q, outH: q)
  result.add ShapeData(path: Path(subs: @[star]),
                       fill: ShapePaint(kind: spGradient, style: 1, stops: @[GradientStop(at: 0, color: see(200)),
                                        GradientStop(at: 1, color: see(0))]),
                       stroke: ShapePaint(kind: spNone), kind: "Flare")
  # the center
  result.add ShapeData(path: ellipsePath(cx - radius * 0.5, cy - radius * 0.5, cx + radius * 0.5, cy + radius * 0.5),
                       fill: ShapePaint(kind: spGradient, style: 1, stops: @[GradientStop(at: 0, color: see(255)),
                                        GradientStop(at: 1, color: see(0))]),
                       stroke: ShapePaint(kind: spNone), kind: "Flare")
  # the rings, along the line, smaller and fainter as they go
  for k in 0 ..< max(0, rings):
    let t = (k.float + 1) / max(1, rings).float
    let q = lerp((cx, cy), (ex, ey), t)
    let r = radius * (0.2 + 0.6 * abs(sin(k.float * 2.3 + 1)))
    result.add ShapeData(path: ellipsePath(q[0] - r, q[1] - r, q[0] + r, q[1] + r),
                         fill: solidPaint(see(30 + (k * 37) mod 40)), stroke: ShapePaint(kind: spNone),
                         kind: "Flare")

# ---- the Mesh tool: a gradient mesh's lines and points ---------------------------------------------------------

proc meshRows*(p: ShapePaint): int = (if p.meshCols > 0: p.points.len div p.meshCols else: 0)
  ## A gradient mesh's rows of points.

proc meshNearest*(p: ShapePaint; u, v, reach: float): int =
  ## The mesh point nearest (`u`, `v`) of the shape's box, within `reach` of it (-1: none).
  result = -1
  var best = reach
  for i, q in p.points:
    let dd = hypot(q.x - u, q.y - v)
    if dd <= best:
      best = dd
      result = i

proc mixColor(a, b: uint32; t: float): uint32 =
  template ch(sh: int): uint32 =
    uint32(clamp(int(round(float((a shr sh) and 255) * (1 - t) + float((b shr sh) and 255) * t)), 0, 255)) shl sh
  ch(24) or ch(16) or ch(8) or ch(0)

proc meshAddLines*(p: var ShapePaint; u, v: float; color: uint32): int =
  ## The Mesh tool's click: a line across the mesh and a line down it through (`u`, `v`) of the
  ## shape's box -- new points on every row and column, between those there, their colors
  ## between theirs -- the point where they cross given `color`. Its index (-1: outside the mesh).
  let nc = p.meshCols
  let nr = p.meshRows
  if nc < 2 or nr < 2 or u <= 0 or u >= 1 or v <= 0 or v >= 1: return -1
  # (the row nearest the click: which columns the new one goes between)
  var rowAt = 0
  var best = 1e18
  for r in 0 ..< nr:
    var mean = 0.0
    for c in 0 ..< nc: mean += p.points[r * nc + c].y
    let dd = abs(mean / nc.float - v)
    if dd < best:
      best = dd
      rowAt = r
  var ci = 0
  while ci < nc - 2 and p.points[rowAt * nc + ci + 1].x < u: inc ci
  # a column between ci and ci + 1, on every row
  var pts: seq[tuple[x, y: float; color: uint32]]
  for r in 0 ..< nr:
    let a = p.points[r * nc + ci]
    let b = p.points[r * nc + ci + 1]
    let t = if r == rowAt and abs(b.x - a.x) > 1e-9: clamp((u - a.x) / (b.x - a.x), 0.05, 0.95)
            else:
              let ra = p.points[rowAt * nc + ci]
              let rb = p.points[rowAt * nc + ci + 1]
              if abs(rb.x - ra.x) > 1e-9: clamp((u - ra.x) / (rb.x - ra.x), 0.05, 0.95) else: 0.5
    for c in 0 ..< nc:
      pts.add p.points[r * nc + c]
      if c == ci: pts.add (a.x + (b.x - a.x) * t, a.y + (b.y - a.y) * t, mixColor(a.color, b.color, t))
  let nc2 = nc + 1
  # (the column nearest the click: which rows the new one goes between)
  let colAt = ci + 1
  var ri = 0
  while ri < nr - 2 and pts[(ri + 1) * nc2 + colAt].y < v: inc ri
  var res: seq[tuple[x, y: float; color: uint32]]
  let ca = pts[ri * nc2 + colAt]
  let cb = pts[(ri + 1) * nc2 + colAt]
  let tr = if abs(cb.y - ca.y) > 1e-9: clamp((v - ca.y) / (cb.y - ca.y), 0.05, 0.95) else: 0.5
  for r in 0 ..< nr:
    for c in 0 ..< nc2: res.add pts[r * nc2 + c]
    if r == ri:
      for c in 0 ..< nc2:
        let a = pts[r * nc2 + c]
        let b = pts[(r + 1) * nc2 + c]
        res.add (a.x + (b.x - a.x) * tr, a.y + (b.y - a.y) * tr, mixColor(a.color, b.color, tr))
  result = (ri + 1) * nc2 + colAt
  res[result].x = u
  res[result].y = v
  res[result].color = color
  p.points = res
  p.meshCols = nc2

proc meshRemoveAt*(p: var ShapePaint; idx: int) =
  ## A mesh point taken away with its row and its column (a mesh keeps two of each).
  let nc = p.meshCols
  let nr = p.meshRows
  if idx < 0 or idx >= p.points.len or nc <= 2 or nr <= 2: return
  let r0 = idx div nc
  let c0 = idx mod nc
  if r0 == 0 or r0 == nr - 1 or c0 == 0 or c0 == nc - 1: return      # (its edges stay)
  var res: seq[tuple[x, y: float; color: uint32]]
  for r in 0 ..< nr:
    if r == r0: continue
    for c in 0 ..< nc:
      if c != c0: res.add p.points[r * nc + c]
  p.points = res
  p.meshCols = nc - 1

# ---- snapping to tangent and perpendicular --------------------------------------------------------------

proc snapTangentPerp*(paths: openArray[Path]; anchor, p: (float, float);
                      reach: float): tuple[p: (float, float); kind: string] =
  ## Smart Guides for a line drawn from `anchor` (the Line tool, the Pen's next segment), as the
  ## drawing program snaps one: where the pointer `p` is within `reach` of a place on one of
  ## `paths` that the line would meet at a right angle ("perpendicular") or just touch
  ## ("tangent"), the end taken there. `kind` "" (and `p` as it was) when there is none.
  result = (p, "")
  var best = reach
  for path in paths:
    for poly0 in flatten(path, 24):
      let poly = poly0
      let n = poly.len
      if n < 2: continue
      # (perpendicular: the foot of the line from the anchor on each straight piece)
      for i in 0 ..< n - 1:
        let a = poly[i]
        let b = poly[i + 1]
        let ux = b[0] - a[0]
        let uy = b[1] - a[1]
        let ll = ux * ux + uy * uy
        if ll < 1e-9: continue
        let t = ((anchor[0] - a[0]) * ux + (anchor[1] - a[1]) * uy) / ll
        if t < 0 or t > 1: continue
        let f = (a[0] + ux * t, a[1] + uy * t)
        if hypot(f[0] - anchor[0], f[1] - anchor[1]) < 1e-3: continue
        let dd = hypot(f[0] - p[0], f[1] - p[1])
        if dd <= best:
          best = dd
          result = (f, "perpendicular")
      # (tangent: where the direction from the anchor turns from one side of the outline to the
      # other -- between two of its points, the crossing found)
      if n >= 3:
        proc side(i: int): float =
          let a = poly[max(0, i - 1)]
          let b = poly[min(n - 1, i + 1)]
          let tx = b[0] - a[0]
          let ty = b[1] - a[1]
          (poly[i][0] - anchor[0]) * ty - (poly[i][1] - anchor[1]) * tx
        for i in 1 ..< n - 2:
          let s0 = side(i)
          let s1 = side(i + 1)
          if (s0 < 0) == (s1 < 0) or abs(s0 - s1) < 1e-12: continue
          let t = s0 / (s0 - s1)
          let q = (poly[i][0] + (poly[i + 1][0] - poly[i][0]) * t, poly[i][1] + (poly[i + 1][1] - poly[i][1]) * t)
          let dd = hypot(q[0] - p[0], q[1] - p[1])
          if dd <= best:
            best = dd
            result = (q, "tangent")

# ---- Release to Layers ---------------------------------------------------------------------------------

proc releaseToLayers*(d: Doc; L: Layer; build = false): seq[Layer] =
  ## Release to Layers: each part of a shape (each of its subpaths) a shape layer of its own, in
  ## the shape's place, the first lowest, the shape itself gone -- `build`: each holding the parts
  ## before it too, one more each (an animation's frames built up, a layer each). The layers
  ## made (none when it is not a shape of two parts or more). (An undoable change:
  ## `touchLayers` first.)
  if L == nil or not L.isShape or L.shape.path.subs.len < 2: return
  let at = d.layers.find(L)
  if at < 0: return
  let n = L.shape.path.subs.len
  var below = at
  for k in 0 ..< n:
    var s = L.shape
    s.path = Path(subs: (if build: L.shape.path.subs[0 .. k] else: @[L.shape.path.subs[k]]))
    let M = d.addShapeLayer(s, L.name & " " & $(k + 1), above = below)
    M.depth = L.depth
    M.opacity = L.opacity
    M.mode = L.mode
    M.fx = L.fx
    below = d.layers.find(M)
    result.add M
  let i = d.layers.find(L)
  if i >= 0: d.layers.delete(i)
  d.cur = d.layers.find(result[^1])
  d.markAll()

