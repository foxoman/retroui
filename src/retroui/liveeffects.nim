## Live effects on a shape's path, as a drawing program's Effect menu has
## them: Distort & Transform (Free Distort, Pucker & Bloat, Roughen,
## Transform, Tweak, Twist, Zig Zag), Warp (its 15 styles), Offset Path,
## and Repeat (Radial, Grid, Mirror: change the one, all follow); Stylize's
## Round Corners and Scribble; Envelope Distort (a mesh of points, or the outline of the object
## on top -- Make with Warp is Warp).
## A shape keeps its path as it was drawn and its effects in
## `ShapeData.effects`; each time it is drawn they are done to the path, in
## order (importing this module turns that on: `photoshapes.liveEffectsHook`).
##
## ```nim
## L.shape.effects.add LiveEffect(kind: leZigZag, amount: 6, detail: 4)
## L.shape.effects.add LiveEffect(kind: leWarp, style: 0, amount: 50)    # Arc, bent 50 %
## d.setShape(L, L.shape)
## ```
##
## Developed by Sultan Al Isaiee @foxoman -- www.foxoman.net -- sultan@foxoman.net

import std/[math, algorithm]
import photo, photopaint, photoshapes, photovector, textengine

const WarpStyles* = ["Arc", "Arc Lower", "Arc Upper", "Arch", "Bulge", "Shell Lower", "Shell Upper", "Flag",
                     "Wave", "Fish", "Rise", "Fisheye", "Inflate", "Squeeze", "Twist"]
  ## Warp's styles, by `LiveEffect.style`.

type Pt = (float, float)

proc lerp(a, b: Pt; t: float): Pt {.inline.} = (a[0] + (b[0] - a[0]) * t, a[1] + (b[1] - a[1]) * t)

proc bounds(p: Path): (float, float, float, float) =
  ## (its anchors' box: as a drawing program measures what it distorts)
  result = (1e18, 1e18, -1e18, -1e18)
  for sp in p.subs:
    for q in sp.pts:
      result[0] = min(result[0], q.p[0]); result[1] = min(result[1], q.p[1])
      result[2] = max(result[2], q.p[0]); result[3] = max(result[3], q.p[1])
  if result[0] > result[2]: result = (0.0, 0.0, 0.0, 0.0)

proc splitSeg(a, b: PathPoint; t: float): tuple[a, m, b: PathPoint] =
  ## (a segment cut at `t`, the curve kept: its ends' handles shortened, the
  ## point between)
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

proc subdivided*(p: Path; n: int): Path =
  ## Each segment cut in `n` (the curves kept as they were): finer, for an
  ## effect that bends the space it is in.
  result = p
  if n <= 1: return
  for sp in result.subs.mitems:
    let m = sp.pts.len
    if m < 2: continue
    let segs = if sp.closed: m else: m - 1
    var pts = sp.pts
    var o: seq[PathPoint]
    for k in 0 ..< segs:
      var a = pts[k]
      var b = pts[(k + 1) mod m]
      for j in 1 ..< n:
        let (a2, mid, b2) = splitSeg(a, b, 1 / float(n - j + 1))
        o.add a2
        a = mid
        b = b2
      o.add a
      pts[(k + 1) mod m] = b
    if sp.closed: o[0].inH = pts[0].inH
    else: o.add pts[m - 1]
    sp.pts = o

proc mapped(p: Path; f: proc (x, y: float): Pt): Path =
  ## Every point and handle moved by `f`.
  result = p
  for sp in result.subs.mitems:
    for q in sp.pts.mitems:
      q.p = f(q.p[0], q.p[1])
      q.inH = f(q.inH[0], q.inH[1])
      q.outH = f(q.outH[0], q.outH[1])

proc hashRnd(i, seed: int): float =
  ## A number -1 .. 1 for `i`: the same each time (an effect that stays put).
  var h = uint32(i) * 2654435761'u32 + uint32(seed) * 40503'u32 + 12345'u32
  h = (h xor (h shr 15)) * 2246822519'u32
  h = h xor (h shr 13)
  float(h and 0xFFFF) / 32767.5 - 1

proc straightHandles(p: Path): Path =
  ## (a straight piece's handles put a third of the way along it: the
  ## effects that move handles bend it then)
  result = p
  for sp in result.subs.mitems:
    let m = sp.pts.len
    let segs = if sp.closed: m else: m - 1
    for k in 0 ..< segs:
      let j = (k + 1) mod m
      if sp.pts[k].outH == sp.pts[k].p and sp.pts[j].inH == sp.pts[j].p:
        sp.pts[k].outH = lerp(sp.pts[k].p, sp.pts[j].p, 1 / 3)
        sp.pts[j].inH = lerp(sp.pts[k].p, sp.pts[j].p, 2 / 3)

# ---- the effects ---------------------------------------------------------------------------------------

proc puckerBloat*(p: Path; amount: float): Path =
  ## Pucker & Bloat (`amount` -200 .. 200 %): the curves between the points
  ## pulled in toward the middle (pucker: spikes) or pushed out from it
  ## (bloat: puffs), the points where they are.
  let (x0, y0, x1, y1) = bounds(p)
  let c = ((x0 + x1) / 2, (y0 + y1) / 2)
  let k = clamp(amount, -200.0, 200.0) / 100
  result = straightHandles(p)
  for sp in result.subs.mitems:
    for q in sp.pts.mitems:
      q.inH = (q.inH[0] + (q.inH[0] - c[0]) * k, q.inH[1] + (q.inH[1] - c[1]) * k)
      q.outH = (q.outH[0] + (q.outH[0] - c[0]) * k, q.outH[1] + (q.outH[1] - c[1]) * k)

proc roughen*(p: Path; size, detail: float; smooth: bool; seed = 1): Path =
  ## Roughen: points put along the path (`detail` an inch of 72 pixels) and
  ## each moved at random up to `size` % of the shape's size; smooth or
  ## corners.
  let (x0, y0, x1, y1) = bounds(p)
  let reach = clamp(size, 0.0, 100.0) / 100 * hypot(x1 - x0, y1 - y0) / 2
  result = Path(name: p.name)
  var idx = 0
  for sp in p.subs:
    let m = sp.pts.len
    if m < 2:
      result.subs.add sp
      continue
    let segs = if sp.closed: m else: m - 1
    # (each segment cut by how long it is: `detail` points an inch)
    var o = SubPath(closed: sp.closed, op: sp.op, joined: sp.joined)
    for k in 0 ..< segs:
      let a = sp.pts[k]
      let b = sp.pts[(k + 1) mod m]
      let one = Path(subs: @[SubPath(pts: @[a, b])])
      var l = 0.0
      for poly in one.flatten(8):
        for i in 1 ..< poly.len: l += hypot(poly[i][0] - poly[i - 1][0], poly[i][1] - poly[i - 1][1])
      let n = max(1, int(round(l / 72 * clamp(detail, 0.0, 100.0))))
      let piece = subdivided(one, n)
      for i in 0 ..< piece.subs[0].pts.len - 1: o.pts.add piece.subs[0].pts[i]
      if k == segs - 1 and not sp.closed: o.pts.add piece.subs[0].pts[^1]
    for q in o.pts.mitems:
      let dx = hashRnd(idx * 2, seed) * reach
      let dy = hashRnd(idx * 2 + 1, seed) * reach
      inc idx
      q.p = (q.p[0] + dx, q.p[1] + dy)
      q.inH = q.p
      q.outH = q.p
    if smooth: o.smoothThrough()
    result.subs.add o

proc transformEffect*(p: Path; sx, sy, dx, dy, angle: float; copies: int): Path =
  ## Transform: scaled (`sx`, `sy` %), moved (`dx`, `dy`) and turned
  ## (`angle` degrees) about its middle; `copies` more, each transformed
  ## again from the one before (the original kept with them).
  let (x0, y0, x1, y1) = bounds(p)
  let c = ((x0 + x1) / 2, (y0 + y1) / 2)
  let a = degToRad(angle)
  let ca = cos(a)
  let sa = sin(a)
  let kx = (if sx == 0: 100.0 else: sx) / 100
  let ky = (if sy == 0: 100.0 else: sy) / 100
  proc once(q: Path; cx, cy: float): Path =
    mapped(q, proc (x, y: float): Pt =
      let u = (x - cx) * kx
      let v = (y - cy) * ky
      (cx + u * ca - v * sa + dx, cy + u * sa + v * ca + dy))
  if copies <= 0: return once(p, c[0], c[1])
  result = p
  var cur = p
  var cc = c
  for k in 1 .. min(copies, 200):
    cur = once(cur, cc[0], cc[1])
    cc = (cc[0] + dx, cc[1] + dy)
    for sp in cur.subs: result.subs.add sp

proc tweak*(p: Path; h, v: float; seed = 1): Path =
  ## Tweak: each point and its handles moved at random, up to `h` % of the
  ## shape's width across and `v` % of its height down.
  let (x0, y0, x1, y1) = bounds(p)
  let rx = (x1 - x0) * clamp(h, 0.0, 100.0) / 100
  let ry = (y1 - y0) * clamp(v, 0.0, 100.0) / 100
  result = p
  var i = 0
  for sp in result.subs.mitems:
    for q in sp.pts.mitems:
      let ddx = hashRnd(i * 3, seed) * rx
      let ddy = hashRnd(i * 3 + 1, seed) * ry
      q.p = (q.p[0] + ddx, q.p[1] + ddy)
      q.inH = (q.inH[0] + ddx + hashRnd(i * 3 + 2, seed) * rx * 0.3, q.inH[1] + ddy)
      q.outH = (q.outH[0] + ddx, q.outH[1] + ddy + hashRnd(i * 3 + 2, seed + 7) * ry * 0.3)
      inc i

proc twist*(p: Path; angle: float): Path =
  ## Twist: turned `angle` degrees at its middle, less toward its edges.
  let (x0, y0, x1, y1) = bounds(p)
  let c = ((x0 + x1) / 2, (y0 + y1) / 2)
  let reach = max(1e-6, hypot(x1 - x0, y1 - y0) / 2)
  let a = degToRad(angle)
  mapped(subdivided(straightHandles(p), 4), proc (x, y: float): Pt =
    let r = hypot(x - c[0], y - c[1])
    let t = a * max(0.0, 1 - r / reach)
    let u = x - c[0]
    let v = y - c[1]
    (c[0] + u * cos(t) - v * sin(t), c[1] + u * sin(t) + v * cos(t)))

proc zigZag*(p: Path; size, ridges: float; smooth: bool): Path =
  ## Zig Zag: each segment made `ridges` waves of `size` pixels either side
  ## of it, sharp or smooth.
  let n = clamp(int(round(ridges)), 0, 100)
  result = Path(name: p.name)
  for sp in p.subs:
    let m = sp.pts.len
    if m < 2 or n <= 0:
      result.subs.add sp
      continue
    let segs = if sp.closed: m else: m - 1
    var o = SubPath(closed: sp.closed, op: sp.op, joined: sp.joined)
    var corners: seq[bool]                # (the path's own points stay corners)
    var side = 1.0
    for k in 0 ..< segs:
      let piece = subdivided(Path(subs: @[SubPath(pts: @[sp.pts[k], sp.pts[(k + 1) mod m]])]), 2 * (n + 1))
      let pts = piece.subs[0].pts
      for i in 0 ..< pts.len:
        if i == pts.len - 1 and (sp.closed or k < segs - 1): break
        var q = pts[i]
        if i > 0 and i < pts.len - 1:
          # (across the line here)
          let a = pts[i - 1].p
          let b = pts[i + 1].p
          let l = max(1e-9, hypot(b[0] - a[0], b[1] - a[1]))
          let nx = -(b[1] - a[1]) / l
          let ny = (b[0] - a[0]) / l
          q.p = (q.p[0] + nx * size * side, q.p[1] + ny * size * side)
          side = -side
        q.inH = q.p
        q.outH = q.p
        o.pts.add q
        corners.add(i == 0 or i == pts.len - 1)
    if smooth: o.smoothThrough(corners)
    result.subs.add o

proc freeDistort*(p: Path; corners: array[4, (float, float)]): Path =
  ## Free Distort: its box's corners (top left, top right, bottom right,
  ## bottom left) moved by `corners`, everything in it with them.
  let (x0, y0, x1, y1) = bounds(p)
  let w = max(1e-9, x1 - x0)
  let h = max(1e-9, y1 - y0)
  let q0 = (x0 + corners[0][0], y0 + corners[0][1])
  let q1 = (x1 + corners[1][0], y0 + corners[1][1])
  let q2 = (x1 + corners[2][0], y1 + corners[2][1])
  let q3 = (x0 + corners[3][0], y1 + corners[3][1])
  mapped(subdivided(p, 3), proc (x, y: float): Pt =
    let u = (x - x0) / w
    let v = (y - y0) / h
    let top = lerp(q0, q1, u)
    let bottom = lerp(q3, q2, u)
    lerp(top, bottom, v))

proc warpEffect*(p: Path; style: int; bend, hDist, vDist: float; vertical = false): Path =
  ## Warp: bent into one of `WarpStyles` (`bend` -100 .. 100 %, the
  ## distortions across and down -100 .. 100 %), as Warp Text bends type.
  let (x0, y0, x1, y1) = bounds(p)
  let cx = (x0 + x1) / 2
  let cy = (y0 + y1) / 2
  let hw = max(1e-9, (x1 - x0) / 2)
  let hh = max(1e-9, (y1 - y0) / 2)
  let w = TextWarp(style: WarpStyle(clamp(style, 0, 14) + 1), bend: int(round(clamp(bend, -100.0, 100.0))),
                   hDistort: int(round(clamp(hDist, -100.0, 100.0))), vDistort: int(round(clamp(vDist, -100.0, 100.0))),
                   vertical: vertical)
  let aspect = hh / hw
  mapped(subdivided(straightHandles(p), 4), proc (x, y: float): Pt =
    let (u, v) = warpPoint(w, (x - cx) / hw, (cy - y) / hh, aspect)
    (cx + u * hw, cy - v * hh))

proc offsetEffect*(p: Path; dist: float): Path =
  ## Offset Path as an effect: the outline `dist` pixels out (or in).
  let (x0, y0, x1, y1) = pathBounds(p)
  if x0 > x1: return p
  let m = abs(dist) + 4
  let ox = floor(x0 - m)
  let oy = floor(y0 - m)
  let bw = int(ceil(x1 + m - ox))
  let bh = int(ceil(y1 + m - oy))
  if bw <= 0 or bh <= 0 or bw * bh > 40_000_000: return p
  translated(offsetPath(translated(p, -ox, -oy), bw, bh, dist), ox, oy)

proc repeatRadial*(p: Path; instances: int; radius, startAngle: float): Path =
  ## Repeat > Radial: `instances` of it round a circle `radius` pixels below
  ## its middle, each turned with it (as the drawing program's Repeat).
  let (x0, y0, x1, y1) = bounds(p)
  let c = ((x0 + x1) / 2, (y0 + y1) / 2 + radius)
  let n = clamp(instances, 1, 360)
  for k in 0 ..< n:
    let a = degToRad(startAngle + 360 * k.float / n.float)
    let ca = cos(a)
    let sa = sin(a)
    let q = mapped(p, proc (x, y: float): Pt =
      let u = x - c[0]
      let v = y - c[1]
      (c[0] + u * ca - v * sa, c[1] + u * sa + v * ca))
    for sp in q.subs: result.subs.add sp

proc repeatGrid*(p: Path; cols, rows: int; hGap, vGap: float): Path =
  ## Repeat > Grid: `cols` x `rows` of it, `hGap`, `vGap` pixels between.
  let (x0, y0, x1, y1) = bounds(p)
  let w = x1 - x0 + hGap
  let h = y1 - y0 + vGap
  for j in 0 ..< clamp(rows, 1, 200):
    for i in 0 ..< clamp(cols, 1, 200):
      for sp in translated(p, i.float * w, j.float * h).subs: result.subs.add sp

proc repeatMirror*(p: Path; axisAngle, offset: float): Path =
  ## Repeat > Mirror: it and its mirror image across an axis `offset`
  ## pixels past its right edge, turned `axisAngle` degrees from upright.
  let (x0, y0, x1, y1) = bounds(p)
  let ax = (x1 + offset, (y0 + y1) / 2)
  let a = degToRad(90 + axisAngle)
  let ux = cos(a)
  let uy = sin(a)
  result = p
  let m = mapped(p, proc (x, y: float): Pt =
    # (reflected across the line through `ax` along (ux, uy))
    let dx = x - ax[0]
    let dy = y - ax[1]
    let along = dx * ux + dy * uy
    (ax[0] + 2 * along * ux - dx, ax[1] + 2 * along * uy - dy))
  for sp in m.subs:
    var r = sp
    # (a mirror image goes round the other way: put back, so the fill keeps its holes)
    r.pts.reverse()
    for q in r.pts.mitems: swap(q.inH, q.outH)
    result.subs.add r

proc roundCorners*(p: Path; radius: float): Path =
  ## Stylize > Round Corners on any path: each corner (a point with no handles) cut back along its
  ## two sides by `radius` (at most half of each) and a curve put in between -- smooth points
  ## and curves as they are.
  result = p
  if radius <= 0: return
  const Kappa = 0.5522847498
  for s in result.subs.mitems:
    let n = s.pts.len
    if n < 3: continue
    var o: seq[PathPoint]
    for i in 0 ..< n:
      let q = s.pts[i]
      let atEnd = not s.closed and (i == 0 or i == n - 1)
      if atEnd or q.inH != q.p or q.outH != q.p:
        o.add q
        continue
      let a = s.pts[(i + n - 1) mod n].p
      let b = s.pts[(i + 1) mod n].p
      let la = hypot(a[0] - q.p[0], a[1] - q.p[1])
      let lb = hypot(b[0] - q.p[0], b[1] - q.p[1])
      if la < 1e-6 or lb < 1e-6:
        o.add q
        continue
      let r = min(radius, min(la, lb) / 2)
      let ua = ((a[0] - q.p[0]) / la, (a[1] - q.p[1]) / la)
      let ub = ((b[0] - q.p[0]) / lb, (b[1] - q.p[1]) / lb)
      let p1 = (q.p[0] + ua[0] * r, q.p[1] + ua[1] * r)
      let p2 = (q.p[0] + ub[0] * r, q.p[1] + ub[1] * r)
      let k = r * (1 - Kappa)
      o.add PathPoint(p: p1, inH: p1, outH: (p1[0] - ua[0] * k, p1[1] - ua[1] * k))
      o.add PathPoint(p: p2, inH: (p2[0] - ub[0] * k, p2[1] - ub[1] * k), outH: p2)
    s.pts = o

const CornerShapes* = ["Rounded", "Inverse Rounded", "Inset", "Bevel", "Fancy"]
  ## Corner Options' shapes, by `LiveEffect.style`.

proc cornerEffect*(p: Path; size: float; shape: int): Path =
  ## Object > Corner Options on any path: each corner (a point with no handles, not an open path's
  ## end) cut back along its two sides by `size` (at most half of each) and joined by the shape
  ## asked for -- 0 rounded (out), 1 inverse rounded (a round bite, its middle at the corner), 2
  ## inset (a square bite), 3 bevel (a straight cut), 4 fancy (a small step and a curl). Smooth
  ## points and curves stay as they are.
  result = p
  if size <= 0: return
  const Kappa = 0.5522847498
  for s in result.subs.mitems:
    let n = s.pts.len
    if n < 3: continue
    var o: seq[PathPoint]
    template sharp(q: Pt): PathPoint = PathPoint(p: q, inH: q, outH: q)
    for i in 0 ..< n:
      let q = s.pts[i]
      let atEnd = not s.closed and (i == 0 or i == n - 1)
      if atEnd or q.inH != q.p or q.outH != q.p:
        o.add q
        continue
      let a = s.pts[(i + n - 1) mod n].p
      let b = s.pts[(i + 1) mod n].p
      let la = hypot(a[0] - q.p[0], a[1] - q.p[1])
      let lb = hypot(b[0] - q.p[0], b[1] - q.p[1])
      if la < 1e-6 or lb < 1e-6:
        o.add q
        continue
      let r = min(size, min(la, lb) / 2)
      let ua = ((a[0] - q.p[0]) / la, (a[1] - q.p[1]) / la)
      let ub = ((b[0] - q.p[0]) / lb, (b[1] - q.p[1]) / lb)
      let p1 = (q.p[0] + ua[0] * r, q.p[1] + ua[1] * r)
      let p2 = (q.p[0] + ub[0] * r, q.p[1] + ub[1] * r)
      case shape
      of 1:
        # an arc round the corner itself, from one side to the other (it bites in)
        let dot = clamp(ua[0] * ub[0] + ua[1] * ub[1], -1.0, 1.0)
        let theta = arccos(dot)
        let h = r * 4 / 3 * tan(theta / 4)
        var t1 = (ub[0] - dot * ua[0], ub[1] - dot * ua[1])
        var t2 = (ua[0] - dot * ub[0], ua[1] - dot * ub[1])
        let l1 = max(1e-9, hypot(t1[0], t1[1]))
        let l2 = max(1e-9, hypot(t2[0], t2[1]))
        t1 = (t1[0] / l1, t1[1] / l1)
        t2 = (t2[0] / l2, t2[1] / l2)
        o.add PathPoint(p: p1, inH: p1, outH: (p1[0] + t1[0] * h, p1[1] + t1[1] * h))
        o.add PathPoint(p: p2, inH: (p2[0] + t2[0] * h, p2[1] + t2[1] * h), outH: p2)
      of 2:
        # a square bite: in from each side, meeting inside the corner
        o.add sharp(p1)
        o.add sharp((q.p[0] + (ua[0] + ub[0]) * r, q.p[1] + (ua[1] + ub[1]) * r))
        o.add sharp(p2)
      of 3:
        o.add sharp(p1)
        o.add sharp(p2)
      of 4:
        # fancy: a short step in from each side, a curl between the steps
        let m1 = (q.p[0] + ua[0] * r + ub[0] * r * 0.35, q.p[1] + ua[1] * r + ub[1] * r * 0.35)
        let m2 = (q.p[0] + ub[0] * r + ua[0] * r * 0.35, q.p[1] + ub[1] * r + ua[1] * r * 0.35)
        let c = (q.p[0] + (ua[0] + ub[0]) * r * 0.15, q.p[1] + (ua[1] + ub[1]) * r * 0.15)
        o.add sharp(p1)
        o.add PathPoint(p: m1, inH: m1, outH: (m1[0] - ua[0] * r * 0.5, m1[1] - ua[1] * r * 0.5))
        o.add PathPoint(p: c, inH: (c[0] + ua[0] * r * 0.25, c[1] + ua[1] * r * 0.25),
                        outH: (c[0] + ub[0] * r * 0.25, c[1] + ub[1] * r * 0.25))
        o.add PathPoint(p: m2, inH: (m2[0] - ub[0] * r * 0.5, m2[1] - ub[1] * r * 0.5), outH: m2)
        o.add sharp(p2)
      else:
        let k = r * (1 - Kappa)
        o.add PathPoint(p: p1, inH: p1, outH: (p1[0] - ua[0] * k, p1[1] - ua[1] * k))
        o.add PathPoint(p: p2, inH: (p2[0] - ub[0] * k, p2[1] - ub[1] * k), outH: p2)
    s.pts = o

proc scribble*(p: Path; spacing, width, angle, variation: float; seed = 1): Path =
  ## Stylize > Scribble: the shape's inside as lines drawn back and forth across it at `angle`
  ## degrees, `spacing` apart, each `width` wide (`variation` %: their spacing and ends loose),
  ## as a filled outline -- the fill's color draws them, as the drawing program's scribbled fill.
  result = Path()
  let polys = flatten(p, 12)
  if polys.len == 0 or spacing <= 0.2: return
  let a = degToRad(angle)
  let (ux, uy) = (cos(a), sin(a))          # (along the lines)
  let (vx, vy) = (-uy, ux)                 # (across them)
  var lo = Inf
  var hi = -Inf
  var alo = Inf
  var ahi = -Inf
  for poly in polys:
    for q in poly:
      lo = min(lo, q[0] * vx + q[1] * vy)
      hi = max(hi, q[0] * vx + q[1] * vy)
      alo = min(alo, q[0] * ux + q[1] * uy)
      ahi = max(ahi, q[0] * ux + q[1] * uy)
  if hi - lo > 1e5: return
  var rnd = uint32(seed) * 2654435761'u32 + 1
  proc jitter(): float =
    rnd = rnd xor (rnd shl 13); rnd = rnd xor (rnd shr 17); rnd = rnd xor (rnd shl 5)
    float(rnd and 0xFFFF) / 65535 - 0.5
  let hw = max(0.25, width / 2)
  var c = lo + spacing / 2
  while c < hi:
    let cc = c + jitter() * spacing * variation / 100
    # (where the line across at `cc` is inside: its crossings with the outline, paired)
    var xs: seq[float]
    for poly in polys:
      for i in 0 ..< poly.len:
        let p0 = poly[i]
        let p1 = poly[(i + 1) mod poly.len]
        let s0 = p0[0] * vx + p0[1] * vy - cc
        let s1 = p1[0] * vx + p1[1] * vy - cc
        if (s0 < 0) != (s1 < 0):
          let t = s0 / (s0 - s1)
          xs.add (p0[0] + (p1[0] - p0[0]) * t) * ux + (p0[1] + (p1[1] - p0[1]) * t) * uy
    xs.sort()
    var k = 0
    while k + 1 < xs.len:
      let e = spacing * variation / 200
      let t0 = xs[k] - jitter() * e
      let t1 = xs[k + 1] + jitter() * e
      if t1 - t0 > 0.5:
        proc pt(t, off: float): (float, float) = (ux * t + vx * (cc + off), uy * t + vy * (cc + off))
        var sp = SubPath(closed: true)
        for q in [pt(t0, -hw), pt(t1, -hw), pt(t1, hw), pt(t0, hw)]: sp.pts.add PathPoint(p: q, inH: q, outH: q)
        result.subs.add sp
      k += 2
    c += spacing

proc envelopeMesh*(p: Path; cols, rows: int; moved: openArray[(float, float)]): Path =
  ## Envelope Distort, Make with Mesh: its box cut in `cols` x `rows`, each point of that grid
  ## moved by `moved` ((cols + 1) x (rows + 1), row by row), everything in a cell with its corners.
  let (x0, y0, x1, y1) = bounds(p)
  let w = max(1e-9, x1 - x0)
  let h = max(1e-9, y1 - y0)
  let c = max(1, cols)
  let r = max(1, rows)
  if moved.len != (c + 1) * (r + 1): return p
  var pts = newSeq[Pt](moved.len)
  for j in 0 .. r:
    for i in 0 .. c:
      let k = j * (c + 1) + i
      pts[k] = (x0 + w * float(i) / float(c) + moved[k][0], y0 + h * float(j) / float(r) + moved[k][1])
  mapped(subdivided(straightHandles(p), max(3, 2 * max(c, r))), proc (x, y: float): Pt =
    let u = clamp((x - x0) / w, 0.0, 1.0) * float(c)
    let v = clamp((y - y0) / h, 0.0, 1.0) * float(r)
    let i = min(c - 1, int(u))
    let j = min(r - 1, int(v))
    let fu = u - float(i)
    let fv = v - float(j)
    let a = pts[j * (c + 1) + i]
    let b = pts[j * (c + 1) + i + 1]
    let cc = pts[(j + 1) * (c + 1) + i + 1]
    let d = pts[(j + 1) * (c + 1) + i]
    lerp(lerp(a, b, fu), lerp(d, cc, fu), fv))

proc envelopeTop*(p: Path; outlinePts: openArray[(float, float)]): Path =
  ## Envelope Distort, Make with Top Object: everything in its box fitted into `outlinePts` (a
  ## closed polygon) -- the box's top edge along the outline's top, its sides down its sides
  ## (a Coons patch between the four).
  if outlinePts.len < 3: return p
  let outline = @outlinePts
  let (x0, y0, x1, y1) = bounds(p)
  let w = max(1e-9, x1 - x0)
  let h = max(1e-9, y1 - y0)
  # (the outline's corners: its points nearest the corners of its own box)
  var ox0, oy0 = 1e18
  var ox1, oy1 = -1e18
  for q in outline:
    ox0 = min(ox0, q[0]); oy0 = min(oy0, q[1]); ox1 = max(ox1, q[0]); oy1 = max(oy1, q[1])
  let n = outline.len
  proc nearest(cx, cy: float): int =
    var best = 1e30
    for k, q in outline:
      let dd = (q[0] - cx) * (q[0] - cx) + (q[1] - cy) * (q[1] - cy)
      if dd < best:
        best = dd
        result = k
  let ktl = nearest(ox0, oy0)
  let ktr = nearest(ox1, oy0)
  let kbr = nearest(ox1, oy1)
  let kbl = nearest(ox0, oy1)
  # (a chain of the outline from one corner to another, going round as its points are ordered,
  # whichever way round the corner after reaches first)
  var dirSign = 1
  block:
    var k = ktl
    var steps = 0
    while k != ktr and k != kbl and steps < n:
      k = (k + 1) mod n
      inc steps
    if k == kbl: dirSign = -1
  proc chain(a, b: int): seq[Pt] =
    var k = a
    result.add outline[k]
    var guard = 0
    while k != b and guard <= n:
      k = (k + dirSign + n) mod n
      result.add outline[k]
      inc guard
  proc along(c: seq[Pt]; t: float): Pt =
    ## (the point `t` of the way along a chain, by length)
    if c.len == 1: return c[0]
    var total = 0.0
    for k in 1 ..< c.len: total += hypot(c[k][0] - c[k - 1][0], c[k][1] - c[k - 1][1])
    var want = clamp(t, 0.0, 1.0) * total
    for k in 1 ..< c.len:
      let seg = hypot(c[k][0] - c[k - 1][0], c[k][1] - c[k - 1][1])
      if want <= seg or k == c.high:
        return lerp(c[k - 1], c[k], if seg > 0: clamp(want / seg, 0.0, 1.0) else: 0.0)
      want -= seg
    c[^1]
  let top = chain(ktl, ktr)
  let right = chain(ktr, kbr)
  var bottom = chain(kbr, kbl)
  bottom.reverse()
  var left = chain(kbl, ktl)
  left.reverse()
  let p00 = outline[ktl]
  let p10 = outline[ktr]
  let p11 = outline[kbr]
  let p01 = outline[kbl]
  mapped(subdivided(straightHandles(p), 6), proc (x, y: float): Pt =
    let u = clamp((x - x0) / w, 0.0, 1.0)
    let v = clamp((y - y0) / h, 0.0, 1.0)
    let c0 = along(top, u)
    let c1 = along(bottom, u)
    let d0 = along(left, v)
    let d1 = along(right, v)
    (((1 - v) * c0[0] + v * c1[0]) + ((1 - u) * d0[0] + u * d1[0]) -
       ((1 - u) * (1 - v) * p00[0] + u * (1 - v) * p10[0] + (1 - u) * v * p01[0] + u * v * p11[0]),
     ((1 - v) * c0[1] + v * c1[1]) + ((1 - u) * d0[1] + u * d1[1]) -
       ((1 - u) * (1 - v) * p00[1] + u * (1 - v) * p10[1] + (1 - u) * v * p01[1] + u * v * p11[1])))

proc applyEffects*(p: Path; es: seq[LiveEffect]): Path =
  ## A path with live effects done to it, in order (those turned off skipped).
  result = p
  for e in es:
    if e.off or result.subs.len == 0: continue
    result = case e.kind
             of lePuckerBloat: puckerBloat(result, e.amount)
             of leRoughen: roughen(result, e.amount, e.detail, e.smooth, e.seed)
             of leTransform: transformEffect(result, e.sx, e.sy, e.dx, e.dy, e.angle, e.copies)
             of leTweak: tweak(result, e.sx, e.sy, e.seed)
             of leTwist: twist(result, e.amount)
             of leZigZag: zigZag(result, e.amount, e.detail, e.smooth)
             of leFreeDistort: freeDistort(result, e.corners)
             of leWarp: warpEffect(result, e.style, e.amount, e.sx, e.sy, e.vertical)
             of leOffset: offsetEffect(result, e.amount)
             of leRepeatRadial: repeatRadial(result, e.copies, e.amount, e.angle)
             of leRepeatGrid: repeatGrid(result, e.copies, int(e.detail), e.dx, e.dy)
             of leRepeatMirror: repeatMirror(result, e.angle, e.dx)
             of leRoundCorners: roundCorners(result, e.amount)
             of leScribble: scribble(result, e.amount, e.detail, e.angle, e.sx, e.seed)
             of leEnvelope:
               if e.envelope.len >= 3: envelopeTop(result, e.envelope)
               else: envelopeMesh(result, e.copies, int(e.detail), e.mesh)
             of leCornerOptions: cornerEffect(result, e.amount, e.style)

proc defaultLiveEffect*(k: LiveEffectKind): LiveEffect =
  ## An effect with the settings it starts with (as the drawing program's boxes open).
  case k
  of lePuckerBloat: LiveEffect(kind: k, amount: -30)
  of leRoughen: LiveEffect(kind: k, amount: 5, detail: 10, smooth: false, seed: 1)
  of leTransform: LiveEffect(kind: k, sx: 100, sy: 100, copies: 0)
  of leTweak: LiveEffect(kind: k, sx: 10, sy: 10, seed: 1)
  of leTwist: LiveEffect(kind: k, amount: 45)
  of leZigZag: LiveEffect(kind: k, amount: 10, detail: 4, smooth: false)
  of leFreeDistort: LiveEffect(kind: k)
  of leWarp: LiveEffect(kind: k, style: 0, amount: 50)
  of leOffset: LiveEffect(kind: k, amount: 10)
  of leRepeatRadial: LiveEffect(kind: k, copies: 8, amount: 100)
  of leRepeatGrid: LiveEffect(kind: k, copies: 3, detail: 3, dx: 10, dy: 10)
  of leRepeatMirror: LiveEffect(kind: k, dx: 10)
  of leRoundCorners: LiveEffect(kind: k, amount: 10)
  of leScribble: LiveEffect(kind: k, amount: 6, detail: 2, angle: 30, sx: 20, seed: 1)
  of leEnvelope: LiveEffect(kind: k, copies: 4, detail: 4, mesh: newSeq[(float, float)](25))
  of leCornerOptions: LiveEffect(kind: k, amount: 12, style: 0)

liveEffectsHook = applyEffects
