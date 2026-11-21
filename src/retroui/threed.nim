## 3D on a shape, live: its outline extruded (with a bevel), revolved round its left edge, or
## inflated, turned in three dimensions, seen with or without perspective, lit by a light and
## shaded as a matte or a shiny material -- drawn as flat faces, vectors, each in its shade
## (SVG and PDF get them as they are). The shape keeps its outline and its 3D settings
## (`ShapeData.threeD`): change either and it is made again. Importing this module turns it on
## (`photoshapes.threeDHook`).
##
## ```nim
## L.shape.threeD = ThreeD(kind: tdExtrude, depth: 40, rx: -20, ry: 30)
## d.setShape(L, L.shape)
## ```
##
## Developed by Sultan Al Isaiee @foxoman -- www.foxoman.net -- sultan@foxoman.net

import std/[math, algorithm]
import photo, photoshapes

type
  V3 = tuple[x, y, z: float]
  Face = object
    pts: seq[V3]               # (turned and seen: x, y on the page, z toward the eye)
    normal: V3
    depth: float
    holes: seq[seq[V3]]

proc defaultThreeD*(k: ThreeDKind): ThreeD =
  ## The settings a kind of 3D starts with.
  case k
  of tdNone: ThreeD()
  of tdExtrude: ThreeD(kind: k, depth: 50, bevel: 0, rx: -18, ry: 26, rz: 0, lightAngle: 315, lightHeight: 45,
                       intensity: 100, ambient: 25, highlight: 60, shading: 1)
  of tdRevolve: ThreeD(kind: k, rx: -18, ry: 0, angle: 360, segments: 36, lightAngle: 315, lightHeight: 45,
                       intensity: 100, ambient: 25, highlight: 60, shading: 1)
  of tdInflate: ThreeD(kind: k, depth: 30, rx: -14, ry: 18, lightAngle: 315, lightHeight: 50, intensity: 100,
                       ambient: 25, highlight: 70, shading: 1, segments: 8)

proc sub(a, b: V3): V3 = (a.x - b.x, a.y - b.y, a.z - b.z)
proc cross(a, b: V3): V3 = (a.y * b.z - a.z * b.y, a.z * b.x - a.x * b.z, a.x * b.y - a.y * b.x)
proc dot(a, b: V3): float = a.x * b.x + a.y * b.y + a.z * b.z
proc norm(a: V3): V3 =
  let l = sqrt(dot(a, a))
  if l < 1e-12: (0.0, 0.0, 1.0) else: (a.x / l, a.y / l, a.z / l)

proc flatPoly(sp: SubPath): seq[(float, float)] =
  ## (a subpath's outline as straight pieces: its curves cut in eight)
  let n = sp.pts.len
  if n == 0: return
  result.add sp.pts[0].p
  let segs = if sp.closed: n else: n - 1
  for i in 0 ..< segs:
    let a = sp.pts[i]
    let b = sp.pts[(i + 1) mod n]
    if a.outH == a.p and b.inH == b.p:
      result.add b.p
      continue
    for k in 1 .. 8:
      let t = k / 8
      let mt = 1 - t
      result.add (mt * mt * mt * a.p[0] + 3 * mt * mt * t * a.outH[0] + 3 * mt * t * t * b.inH[0] + t * t * t * b.p[0],
                  mt * mt * mt * a.p[1] + 3 * mt * mt * t * a.outH[1] + 3 * mt * t * t * b.inH[1] + t * t * t * b.p[1])
  if sp.closed and result.len > 1 and result[0] == result[^1]: discard result.pop

proc area(p: seq[(float, float)]): float =
  for i in 0 ..< p.len:
    let a = p[i]
    let b = p[(i + 1) mod p.len]
    result += a[0] * b[1] - b[0] * a[1]
  result /= 2

proc inset(p: seq[(float, float)]; d: float): seq[(float, float)] =
  ## (a polygon moved in by `d` -- out when negative -- each corner along its two sides' normals)
  let n = p.len
  let s = if area(p) >= 0: 1.0 else: -1.0       # (which side is in, by how it turns: y down)
  for i in 0 ..< n:
    let a = p[(i + n - 1) mod n]
    let b = p[i]
    let c = p[(i + 1) mod n]
    var n1 = (-(b[1] - a[1]), b[0] - a[0])
    var n2 = (-(c[1] - b[1]), c[0] - b[0])
    let l1 = max(1e-9, hypot(n1[0], n1[1]))
    let l2 = max(1e-9, hypot(n2[0], n2[1]))
    n1 = (n1[0] / l1 * s, n1[1] / l1 * s)
    n2 = (n2[0] / l2 * s, n2[1] / l2 * s)
    var m = (n1[0] + n2[0], n1[1] + n2[1])
    let lm = hypot(m[0], m[1])
    if lm < 1e-9: m = n1
    else: m = (m[0] / lm, m[1] / lm)
    let cosHalf = max(0.25, m[0] * n1[0] + m[1] * n1[1])   # (sharp corners not sent far)
    result.add (b[0] + m[0] * d / cosHalf, b[1] + m[1] * d / cosHalf)

type Seeing = object
  ## (how a shape is turned -- sines and cosines about x, y, z -- and seen: the eye's distance, 0
  ## none, and the middle it is put back round)
  sx, cxr, sy, cyr, sz, czr: float
  focal, cx, cy: float

proc turn(w: Seeing; v: V3): V3 =
  ## (turned: x, then y, then z; z toward the eye, y down)
  var (x, y, z) = v
  (y, z) = (y * w.cxr - z * w.sx, y * w.sx + z * w.cxr)
  (x, z) = (x * w.cyr + z * w.sy, -x * w.sy + z * w.cyr)
  (x, y) = (x * w.czr - y * w.sz, x * w.sz + y * w.czr)
  (x, y, z)

proc seen(w: Seeing; v: V3): V3 =
  ## (seen from the front, with perspective when the eye is near)
  if w.focal <= 0: return (v.x + w.cx, v.y + w.cy, v.z)
  let k = w.focal / max(1e-6, w.focal - v.z)
  (v.x * k + w.cx, v.y * k + w.cy, v.z)

proc shadeOf(base: uint32; n: V3; t: ThreeD): uint32 =
  ## (a face's color: the base dimmed by the light on it, a highlight on a shiny one)
  let la = degToRad(t.lightAngle)
  let lh = degToRad(clamp(t.lightHeight, 0, 90))
  # (the light: from its angle round the page -- 0 the right, 90 the top -- and its height
  # over it; y down on the page)
  let L = norm((cos(la) * cos(lh), -sin(la) * cos(lh), sin(lh)))
  let amb = clamp(t.ambient, 0, 100) / 100
  let kd = clamp(t.intensity, 0, 200) / 100
  let diff = max(0.0, dot(n, L))
  var k = if t.shading == 2: 1.0 else: amb + (1 - amb) * kd * diff
  var spec = 0.0
  if t.shading == 1:
    let h = norm((L.x, L.y, L.z + 1))
    spec = pow(max(0.0, dot(n, h)), 48) * clamp(t.highlight, 0, 100) / 100 * 0.55
  template ch(sh: int): uint32 =
    uint32(clamp(int(float((base shr sh) and 255) * k + 255 * spec + 0.5), 0, 255)) shl sh
  (base and 0xFF000000'u32) or ch(16) or ch(8) or ch(0)

proc threeDParts*(s: ShapeData): seq[ShapeData] =
  ## The shape's 3D as flat faces (back to front), each a plain shape filled in its shade (and
  ## stroked a hair in it, so no seam shows between faces); none when it has no 3D.
  let t = s.threeD
  if t.kind == tdNone: return
  var polys: seq[seq[(float, float)]]
  for sp in s.path.subs:
    let p = flatPoly(sp)
    if p.len >= (if t.kind == tdRevolve: 2 else: 3): polys.add p
  if polys.len == 0: return
  let base = if s.fill.kind != spNone: (if s.fill.kind == spColor: s.fill.color else: s.fill.color or 0xFF000000'u32)
             elif s.stroke.kind != spNone: s.stroke.color
             else: 0xFF808080'u32
  var x0, y0 = 1e18
  var x1, y1 = -1e18
  for p in polys:
    for q in p:
      x0 = min(x0, q[0]); y0 = min(y0, q[1]); x1 = max(x1, q[0]); y1 = max(y1, q[1])
  let cx = (x0 + x1) / 2
  let cy = (y0 + y1) / 2
  # (turned: x, then y, then z; seen from the front, with perspective when asked)
  let (sx, cxr) = (sin(degToRad(t.rx)), cos(degToRad(t.rx)))
  let (sy, cyr) = (sin(degToRad(t.ry)), cos(degToRad(t.ry)))
  let (sz, czr) = (sin(degToRad(t.rz)), cos(degToRad(t.rz)))
  let span = max(x1 - x0, y1 - y0)
  let focal = if t.perspective > 0: span / (2 * tan(degToRad(clamp(t.perspective, 1, 160)) / 2)) else: 0.0
  let w = Seeing(sx: sx, cxr: cxr, sy: sy, cyr: cyr, sz: sz, czr: czr, focal: focal, cx: cx, cy: cy)
  var faces: seq[Face]
  proc addFace(pts: seq[V3]; holes: seq[seq[V3]] = @[]) =
    # (turned, its normal from its first three distinct corners; seen)
    if pts.len < 3: return
    var tp: seq[V3]
    for p in pts: tp.add w.turn(p)
    var n: V3 = (0.0, 0.0, 0.0)
    # (Newell: robust for any polygon)
    for i in 0 ..< tp.len:
      let a = tp[i]
      let b = tp[(i + 1) mod tp.len]
      n.x += (a.y - b.y) * (a.z + b.z)
      n.y += (a.z - b.z) * (a.x + b.x)
      n.z += (a.x - b.x) * (a.y + b.y)
    n = norm(n)
    var sp: seq[V3]
    var dsum = 0.0
    for p in tp:
      sp.add w.seen(p)
      dsum += p.z
    var hs: seq[seq[V3]]
    for h in holes:
      var q: seq[V3]
      for p in h: q.add w.seen(w.turn(p))
      hs.add q
    faces.add Face(pts: sp, normal: n, depth: dsum / tp.len.float, holes: hs)
  proc v(p: (float, float); z: float): V3 = (p[0] - cx, p[1] - cy, z)
  case t.kind
  of tdExtrude:
    let d = max(0.0, t.depth)
    let bv = clamp(t.bevel, 0, span / 4)
    let zf = d / 2           # (the front; the back at -d/2)
    let zb = -d / 2
    # (the outer outlines and the holes in them: by their area's sign, the first's the outer's)
    let outerSign = if area(polys[0]) >= 0: 1.0 else: -1.0
    var front, back: seq[V3]
    for k, p in polys:
      let isHole = k > 0 and (area(p) >= 0) != (outerSign > 0)
      # (the bevel into the solid: an outline in, a hole out)
      let fp = if bv > 0: inset(p, if isHole: -bv else: bv) else: p
      var f, b: seq[V3]
      for q in fp: f.add v(q, zf)
      for i in countdown(p.high, 0): b.add v(p[i], zb)
      # (each outline its sides; the front and back faces with their holes)
      for i in 0 ..< p.len:
        let a = p[i]
        let c = p[(i + 1) mod p.len]
        let zt = if bv > 0: zf - bv else: zf
        addFace(@[v(a, zt), v(a, zb), v(c, zb), v(c, zt)])
        if bv > 0:
          let ia = fp[i]
          let ic = fp[(i + 1) mod p.len]
          addFace(@[v(ia, zf), v(a, zt), v(c, zt), v(ic, zf)])
      if not isHole:
        front = f
        back = b
        var fh, bh: seq[seq[V3]]
        for k2, p2 in polys:
          if k2 == k: continue
          let h2 = k2 > 0 and (area(p2) >= 0) != (outerSign > 0)
          if not h2: continue
          let fp2 = if bv > 0: inset(p2, -bv) else: p2
          var hf, hb: seq[V3]
          for q in fp2: hf.add v(q, zf)
          for i in countdown(p2.high, 0): hb.add v(p2[i], zb)
          fh.add hf
          bh.add hb
        addFace(front, fh)
        addFace(back, bh)
  of tdRevolve:
    # (the first outline as the profile: its distance from the shape's left edge round a line
    # down that edge)
    let prof = polys[0]
    let segs = clamp(t.segments, 6, 180)
    let ang = degToRad(clamp(if t.angle <= 0: 360.0 else: t.angle, 1, 360))
    let closedProfile = s.path.subs[0].closed
    let axisX = x0
    let m = if closedProfile: prof.len else: prof.len - 1
    for k in 0 ..< segs:
      let a0 = ang * k.float / segs.float
      let a1 = ang * (k + 1).float / segs.float
      for i in 0 ..< m:
        let p = prof[i]
        let q = prof[(i + 1) mod prof.len]
        proc at(pt: (float, float); a: float): V3 =
          let r = pt[0] - axisX
          (r * cos(a) + axisX - cx, pt[1] - cy, r * sin(a))
        addFace(@[at(p, a0), at(q, a0), at(q, a1), at(p, a1)])
  of tdInflate:
    # (rings going in, each a little higher -- the edge of a cushion -- then the top)
    let n = clamp(if t.segments <= 0: 8 else: t.segments, 2, 24)
    let h = max(0.0, t.depth)
    let reach = span / 4
    for p in polys:
      var rings: seq[seq[(float, float)]]
      var zs: seq[float]
      for k in 0 .. n:
        let th = k.float / n.float * PI / 2
        rings.add(if k == 0: p else: inset(p, reach * (1 - cos(th))))
        zs.add h * sin(th)
      for k in 0 ..< n:
        let a = rings[k]
        let b = rings[k + 1]
        for i in 0 ..< p.len:
          let j = (i + 1) mod p.len
          addFace(@[v(a[i], zs[k]), v(a[j], zs[k]), v(b[j], zs[k + 1]), v(b[i], zs[k + 1])])
      var top: seq[V3]
      for q in rings[^1]: top.add v(q, zs[^1])
      addFace(top)
      var bottom: seq[V3]
      for i in countdown(p.high, 0): bottom.add v(p[i], 0)
      addFace(bottom)
  of tdNone: discard
  # (back to front; those facing away left out -- but where a face's turn is unclear, kept)
  faces.sort(proc (a, b: Face): int = cmp(a.depth, b.depth))
  for f in faces:
    var nrm = f.normal
    if nrm.z <= 1e-6 and t.kind != tdRevolve: continue      # (facing away, or seen edge on)
    if nrm.z < 0: nrm = (-nrm.x, -nrm.y, -nrm.z)       # (a revolved surface: seen from inside too)
    let c = shadeOf(base, nrm, t)
    var path = Path()
    var sp = SubPath(closed: true)
    for p in f.pts: sp.pts.add PathPoint(p: (p.x, p.y), inH: (p.x, p.y), outH: (p.x, p.y))
    path.subs.add sp
    for hole in f.holes:
      var hs = SubPath(closed: true, joined: true)
      for p in hole: hs.pts.add PathPoint(p: (p.x, p.y), inH: (p.x, p.y), outH: (p.x, p.y))
      path.subs.add hs
    result.add ShapeData(path: path, fill: solidPaint(c), stroke: solidPaint(c), strokeWidth: 0.6, align: saCenter,
                         join: ljRound)

threeDHook = threeDParts
