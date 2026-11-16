## Brushes along a path, as a drawing program has them: a piece of artwork
## (a shape's outline) laid along a path instead of a plain stroke --
##
## - Art: the artwork stretched along the whole path, bent with it (a taper,
##   a brush stroke, an arrow);
## - Pattern: copies of it one after another along the path, each bent with
##   it (a rope, a chain, a zigzag);
## - Scatter: copies of it set along the path, each turned with it but not
##   bent (leaves, dots, stars).
##
## The artwork's box lies along the path: its left end at the path's start,
## its height across the path (`width` pixels). The result is a path of
## outlines, to fill (`brushedPath`).
##
## .. code-block:: nim
##   import retroui/[photo, photoshapes, pathbrush]
##   let b = builtinBrush("Taper", width = 18)
##   discard d.addShapeLayer(ShapeData(path: brushedPath(line, b), fill: solidPaint(ink)))
##
## Developed by Sultan Al Isaiee @foxoman -- www.foxoman.net -- sultan@foxoman.net

import std/math
import photo, photopaint, photoshapes, photovector

type
  PathBrushKind* = enum
    ## How the artwork goes along the path.
    pbArt = "Art", pbPattern = "Pattern", pbScatter = "Scatter"

  PathBrush* = object
    ## A brush made of artwork.
    kind*: PathBrushKind
    art*: Path                 ## its artwork (where it is does not matter: its box is taken)
    width*: float              ## how wide across the path, pixels (the artwork's height scaled to it)
    spacing*: float            ## Pattern, Scatter: the room between copies, a fraction of a copy's length
    flip*: bool                ## the artwork mirrored across the path

  Track = object
    pts: seq[(float, float)]
    at: seq[float]             # (how far along each point is)

proc track(poly: seq[(float, float)]; closed: bool): Track =
  ## (a polyline with its lengths)
  for p in poly:
    if result.pts.len > 0 and hypot(p[0] - result.pts[^1][0], p[1] - result.pts[^1][1]) < 1e-9: continue
    result.pts.add p
  if closed and result.pts.len > 2: result.pts.add result.pts[0]
  result.at = newSeq[float](result.pts.len)
  for i in 1 ..< result.pts.len:
    result.at[i] = result.at[i - 1] + hypot(result.pts[i][0] - result.pts[i - 1][0],
                                            result.pts[i][1] - result.pts[i - 1][1])

proc length(t: Track): float = (if t.at.len > 0: t.at[^1] else: 0.0)

proc frameAt(t: Track; s: float): tuple[p, n: (float, float)] =
  ## (the point `s` along, and the path's left-hand normal there; past the ends: straight on)
  let n = t.pts.len
  var i = 1
  var lo = 1
  var hi = n - 1
  while lo < hi:
    let mid = (lo + hi) div 2
    if t.at[mid] < s: lo = mid + 1 else: hi = mid
  i = clamp(lo, 1, n - 1)
  let a = t.pts[i - 1]
  let b = t.pts[i]
  let seg = max(1e-12, t.at[i] - t.at[i - 1])
  let u = (s - t.at[i - 1]) / seg
  let dx = (b[0] - a[0]) / seg
  let dy = (b[1] - a[1]) / seg
  # (the normal smoothed over the corner: half from each piece near a joint)
  var nx = -dy
  var ny = dx
  if u < 0.5 and i >= 2:
    let c = t.pts[i - 2]
    let s2 = max(1e-12, t.at[i - 1] - t.at[i - 2])
    let w = 0.5 - u
    nx = nx * (1 - w) + (-(a[1] - c[1]) / s2) * w
    ny = ny * (1 - w) + ((a[0] - c[0]) / s2) * w
  elif u > 0.5 and i + 1 < n:
    let c = t.pts[i + 1]
    let s2 = max(1e-12, t.at[i + 1] - t.at[i])
    let w = u - 0.5
    nx = nx * (1 - w) + (-(c[1] - b[1]) / s2) * w
    ny = ny * (1 - w) + ((c[0] - b[0]) / s2) * w
  let l = max(1e-12, hypot(nx, ny))
  ((a[0] + (b[0] - a[0]) * u, a[1] + (b[1] - a[1]) * u), (nx / l, ny / l))

proc densePolys(art: Path; pieces: int): seq[tuple[pts: seq[(float, float)]; closed: bool; op: PathOp;
                                                  joined: bool]] =
  ## (the artwork as polygons, each side cut so it bends smoothly)
  let (x0, _, x1, _) = pathBounds(art)
  let maxLen = max(1e-6, (x1 - x0) / max(1, pieces).float)
  let polys = flatten(art, 24)
  var k = 0
  for s in art.subs:
    if s.pts.len == 0: continue
    if k >= polys.len: break
    let poly = polys[k]
    inc k
    var dense: seq[(float, float)]
    let n = poly.len
    let segs = if s.closed: n else: n - 1
    if n > 0: dense.add poly[0]
    for i in 0 ..< segs:
      let a = poly[i]
      let b = poly[(i + 1) mod n]
      let m = max(1, int(ceil(abs(b[0] - a[0]) / maxLen)))
      for j in 1 .. m:
        let u = j / m
        dense.add (a[0] + (b[0] - a[0]) * u, a[1] + (b[1] - a[1]) * u)
    if s.closed and dense.len > 1: dense.setLen(dense.len - 1)
    result.add (dense, s.closed, s.op, s.joined)

proc toSub(pts: seq[(float, float)]; closed: bool; op = poAdd; joined = false): SubPath =
  result = SubPath(closed: closed, op: op, joined: joined)
  for p in pts: result.pts.add PathPoint(p: p, inH: p, outH: p)

proc brushedPath*(path: Path; b: PathBrush): Path =
  ## `b` laid along each subpath of `path`: the outlines it makes (to fill). Empty when the
  ## brush has no artwork or the path no length.
  if b.art.subs.len == 0: return
  let (ax0, ay0, ax1, ay1) = pathBounds(b.art)
  let aw = max(1e-6, ax1 - ax0)
  let ah = max(1e-6, ay1 - ay0)
  let my = (ay0 + ay1) / 2
  let across = b.width / ah * (if b.flip: -1.0 else: 1.0)
  let polys = densePolys(b.art, 120)
  let lines = flatten(path, 24)
  var k = 0
  for s in path.subs:
    if s.pts.len == 0: continue
    if k >= lines.len: break
    let t = track(lines[k], s.closed)
    inc k
    let total = t.length
    if total < 1e-6 or t.pts.len < 2: continue
    case b.kind
    of pbArt:
      for (pts, closed, op, joined) in polys:
        var o: seq[(float, float)]
        for (x, y) in pts:
          let f = t.frameAt((x - ax0) / aw * total)
          let d = (y - my) * across
          o.add (f.p[0] + f.n[0] * d, f.p[1] + f.n[1] * d)
        result.subs.add toSub(o, closed, op, joined)
    of pbPattern, pbScatter:
      # (copies as long as the width makes them, a whole number of them along the path)
      let copyLen = aw * abs(across) * (1 + max(0.0, b.spacing))
      let n = max(1, int(round(total / max(1e-6, copyLen))))
      let step = total / n.float
      let artLen = step / (1 + max(0.0, b.spacing))
      for c in 0 ..< n:
        let s0 = c.float * step + (step - artLen) / 2
        if b.kind == pbPattern:
          for (pts, closed, op, joined) in polys:
            var o: seq[(float, float)]
            for (x, y) in pts:
              let f = t.frameAt(s0 + (x - ax0) / aw * artLen)
              let d = (y - my) * across
              o.add (f.p[0] + f.n[0] * d, f.p[1] + f.n[1] * d)
            result.subs.add toSub(o, closed, op, joined)
        else:
          # (not bent: turned with the path at its middle)
          let f = t.frameAt(s0 + artLen / 2)
          let tx = f.n[1]                    # (the direction along: the normal turned back)
          let ty = -f.n[0]
          let kx = artLen / aw
          for sp in b.art.subs:
            var q = sp
            for pp in q.pts.mitems:
              for h in [addr pp.p, addr pp.inH, addr pp.outH]:
                let lx = (h[][0] - (ax0 + ax1) / 2) * kx
                let ly = (h[][1] - my) * across
                h[] = (f.p[0] + tx * lx + f.n[0] * ly, f.p[1] + ty * lx + f.n[1] * ly)
            result.subs.add q

proc builtinBrush*(name: string; width = 12.0): PathBrush =
  ## A brush of those a drawing program comes with: "Taper" (pointed at both ends), "Brush
  ## Stroke" (a dry brush's uneven edge), "Arrow", "Zigzag" (a pattern), "Chain" (a pattern of
  ## links), "Dots", "Leaves", "Stars" (scattered). An empty brush for another name.
  result.width = width
  case name
  of "Taper":
    result.kind = pbArt
    result.art = ellipsePath(0, 0, 100, 10)
  of "Brush Stroke":
    result.kind = pbArt
    var sp = SubPath(closed: true)
    let top = [(0.0, 5.0), (8.0, 2.2), (20.0, 1.0), (35.0, 1.8), (50.0, 0.6), (65.0, 1.6), (80.0, 0.9),
               (92.0, 2.4), (100.0, 4.6)]
    let bottom = [(97.0, 6.4), (85.0, 8.6), (70.0, 9.2), (55.0, 8.4), (40.0, 9.4), (25.0, 8.8), (10.0, 7.6),
                  (2.0, 6.0)]
    for p in top: sp.pts.add PathPoint(p: p, inH: p, outH: p)
    for p in bottom: sp.pts.add PathPoint(p: p, inH: p, outH: p)
    result.art = Path(subs: @[sp])
  of "Arrow":
    result.kind = pbArt
    var sp = SubPath(closed: true)
    for p in [(0.0, 4.0), (80.0, 4.0), (80.0, 0.0), (100.0, 5.0), (80.0, 10.0), (80.0, 6.0), (0.0, 6.0)]:
      sp.pts.add PathPoint(p: p, inH: p, outH: p)
    result.art = Path(subs: @[sp])
  of "Zigzag":
    result.kind = pbPattern
    var sp = SubPath(closed: true)
    for p in [(0.0, 8.0), (5.0, 0.0), (10.0, 8.0), (10.0, 10.0), (5.0, 2.0), (0.0, 10.0)]:
      sp.pts.add PathPoint(p: p, inH: p, outH: p)
    result.art = Path(subs: @[sp])
  of "Chain":
    result.kind = pbPattern
    result.spacing = -0.15
    var outer = ellipsePath(0, 0, 20, 10)
    var inner = ellipsePath(4, 3, 16, 7)
    inner.subs[0].op = poSubtract
    result.art = Path(subs: @[outer.subs[0], inner.subs[0]])
  of "Dots":
    result.kind = pbScatter
    result.spacing = 0.8
    result.art = ellipsePath(0, 0, 10, 10)
  of "Leaves":
    result.kind = pbScatter
    result.spacing = 0.3
    var sp = SubPath(closed: true)
    sp.pts.add PathPoint(p: (0.0, 5.0), inH: (0.0, 5.0), outH: (6.0, -1.0))
    sp.pts.add PathPoint(p: (20.0, 5.0), inH: (14.0, -1.0), outH: (14.0, 11.0))
    sp.pts[0].inH = (6.0, 11.0)
    result.art = Path(subs: @[sp])
  of "Stars":
    result.kind = pbScatter
    result.spacing = 0.6
    result.art = starPath(0, 0, 10, 10, 5, 50, 0)
  else: discard

const BuiltinBrushes* = ["Taper", "Brush Stroke", "Arrow", "Zigzag", "Chain", "Dots", "Leaves", "Stars"]
  ## The names `builtinBrush` knows, in the order a Brushes panel shows them.

proc strokeBrushOutline(p: Path; b: StrokeBrush; width: float): Path =
  ## (a shape's stroke brush, live: `photoshapes.brushOutlineHook`)
  var pb = if b.art.subs.len > 0: PathBrush(art: b.art)
           else: builtinBrush(if b.name in BuiltinBrushes: b.name else: "Taper", width)
  pb.kind = case b.kind
            of sbPattern: pbPattern
            of sbScatter: pbScatter
            else: pbArt
  pb.width = width
  if b.kind != sbArt: pb.spacing = b.spacing / 100
  pb.flip = b.flip
  brushedPath(p, pb)

proc strokeBrushOf*(name: string; kind = sbNone): StrokeBrush =
  ## One of the brushes that come with it (`BuiltinBrushes`) as a shape's
  ## stroke brush, its own way along the path unless `kind` says.
  let b = builtinBrush(name)
  result = StrokeBrush(name: name, art: b.art, spacing: b.spacing * 100,
                       kind: (if kind != sbNone: kind
                              else:
                                case b.kind
                                of pbPattern: sbPattern
                                of pbScatter: sbScatter
                                else: sbArt))

brushOutlineHook = strokeBrushOutline
