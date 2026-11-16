## Live effects on a shape's path, as a drawing program's Effect menu has
## them: Distort & Transform (Free Distort, Pucker & Bloat, Roughen,
## Transform, Tweak, Twist, Zig Zag), Warp (its 15 styles), Offset Path,
## and Repeat (Radial, Grid, Mirror: change the one, all follow).
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

liveEffectsHook = applyEffects
